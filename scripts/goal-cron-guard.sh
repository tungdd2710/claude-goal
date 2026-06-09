#!/usr/bin/env bash
# goal-cron-guard.sh — crash/completion safety for the /goal autonomy system (v1.1.0, 2026-06-09).
#
# PROBLEM (founder 2026-06-09): the durable /goal-resume cron in
# .claude/scheduled_tasks.json SURVIVES laptop crashes and keeps firing every few
# hours even after every goal is finished — re-spawning sessions that churn through
# (and sometimes RE-ACTIVATE) already-complete goals. Neither goal-update-state.sh
# (on completion) nor goal-continue.sh (the cron entry) ever removed the cron, and
# nothing pruned it on restart. A goal left with status="active" but completed_at
# set — OR with the per-goal file flipped to active while the index roster still
# marks it terminal — made the Stop hook + cron perpetuate forever.
#
# FIX — run this whenever the autonomy state changes:
#   1. SELF-HEAL: a goal whose per-goal file says active/in_progress is "finished but
#      re-opened" when EITHER it carries a completed_at OR the index roster marks it
#      terminal/parked (complete/paused/blocked). Reset the file to that resolved
#      status. A file written within RECENT_SECS is SKIPPED (it may be a legitimate
#      paused/blocked->active reactivation mid-write: goal-update-state.sh writes the
#      per-goal file ~100ms before it syncs the index, and healing in that window
#      would silently undo the reactivation; a real crash divergence is always old).
#   2. If NO goal is then genuinely active, PRUNE the /goal-resume cron(s) from
#      scheduled_tasks.json (matched PRECISELY on the "/goal resume" command, never any
#      prompt that merely contains "/goal") and clear stale session-*.goal claim files.
#
# Wired as a SessionStart hook (runs on every startup incl. post-crash) and called
# from goal-continue.sh (cron entry) + goal-update-state.sh (on terminal status).
# Idempotent + FAIL-OPEN: any error -> exit 0 (a hook must never wedge a session).
# atomic_write failures are logged to cron-guard.log (not silently swallowed).

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GOALS_DIR="$REPO_ROOT/.claude/goals"
INDEX="$GOALS_DIR/index.json"
TASKS="$REPO_ROOT/.claude/scheduled_tasks.json"
[ -f "$INDEX" ] || exit 0

python3 - "$INDEX" "$TASKS" "$GOALS_DIR" <<'PY' 2>/dev/null || exit 0
import json, sys, os, glob, tempfile, time, re
from datetime import datetime, timezone

index_path, tasks_path, goals_dir = sys.argv[1], sys.argv[2], sys.argv[3]
ACTIVE = {"active", "in_progress"}
PARKED = {"complete", "paused", "blocked"}   # index-roster terminal/parked states
RECENT_SECS = 15                              # a file written this recently may be mid-transition
LOG = os.path.join(goals_dir, "cron-guard.log")

def logline(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write("[goal-cron-guard] " + msg + "\n")
    except Exception:
        pass

def load(p):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def atomic_write(p, obj):
    d = os.path.dirname(p) or "."
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, p)
        return True
    except Exception:
        try: os.remove(tmp)
        except Exception: pass
        return False

idx = load(index_path)
if not idx or "goals" not in idx:
    sys.exit(0)

healed = []
active = []
for g in idx.get("goals", []) or []:
    gid = g.get("id")
    idx_status = g.get("status")                 # index roster's view of this goal
    gf = os.path.join(goals_dir, "goal-%s.json" % gid)
    gj = load(gf)
    status = (gj or g).get("status")             # per-goal file is authoritative for active-ness
    completed_at = (gj or g).get("completed_at")
    # HEAL a finished-but-re-opened goal: file says active AND (it carries completed_at
    # OR the index roster marks it terminal/parked). heal_to = the parked index status
    # (paused/blocked) when there is no completed_at, else "complete".
    if status in ACTIVE and (completed_at or idx_status in PARKED):
        # Don't heal a per-goal file that is still SETTLING. A legitimate paused/blocked
        # -> active reactivation writes the per-goal file ~100ms before it syncs the
        # index, so a guard firing in that window would see file=active / index=parked
        # and wrongly undo the reactivation. A real crash divergence is always old.
        # Fresh file -> treat active now; heal on a later run if it is still diverged.
        fresh = False
        if gj is not None:
            try: fresh = (time.time() - os.path.getmtime(gf)) < RECENT_SECS
            except Exception: fresh = False
        if fresh:
            active.append(gid)
            continue
        heal_to = idx_status if (idx_status in PARKED and not completed_at) else "complete"
        if gj is not None:
            gj["status"] = heal_to
            if heal_to == "complete" and not gj.get("completed_at"):
                gj["completed_at"] = datetime.now(timezone.utc).isoformat()
            if not atomic_write(gf, gj):
                logline("WARN: could not write healed %s" % os.path.basename(gf))
        g["status"] = heal_to
        healed.append(gid)
        continue
    if status in ACTIVE and not completed_at:
        active.append(gid)

if healed and not atomic_write(index_path, idx):
    logline("WARN: could not write healed index.json")

if active:
    if healed:
        logline("self-healed re-activated goals %s; %d still active -> crons kept" % (healed, len(active)))
    sys.exit(0)

# No genuinely-active goals -> prune the /goal-resume cron(s) + stale claims.
pruned = []

# Match the goal-resume cron PRECISELY on its "/goal resume" command (docs/SETUP.md), not
# any prompt that merely contains "/goal" — a user's "/goals-report" or "review /goal
# progress" or "/goal-check" cron must NOT be deleted.
_goal_cron = re.compile(r"/goal\s+resume\b")
t = load(tasks_path)
if isinstance(t, dict) and isinstance(t.get("tasks"), list):
    keep, dropped = [], []
    for c in t["tasks"]:
        if _goal_cron.search((c.get("prompt") or "").lower()):
            dropped.append("cron:%s" % c.get("id"))
        else:
            keep.append(c)
    if dropped:
        t["tasks"] = keep
        if atomic_write(tasks_path, t):
            pruned.extend(dropped)
        else:
            logline("WARN: could not prune crons from scheduled_tasks.json")

for claim in glob.glob(os.path.join(goals_dir, "session-*.goal")):
    try:
        os.remove(claim)
        pruned.append("claim:%s" % os.path.basename(claim))
    except Exception:
        pass

if healed or pruned:
    logline("no active goals — healed=%s pruned=%s" % (healed, pruned))
    msg = []
    if healed: msg.append("healed %d re-activated goal(s)" % len(healed))
    if pruned: msg.append("pruned %d stale cron/claim item(s)" % len(pruned))
    print("[goal-cron-guard] " + "; ".join(msg))
PY
exit 0

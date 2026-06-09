#!/usr/bin/env bash
# goal-cron-guard.sh — crash/completion safety for the /goal autonomy system (v1.0.0, 2026-06-09).
#
# PROBLEM: the durable cross-session resume cron (created per docs/SETUP.md) is
# stored in .claude/scheduled_tasks.json and SURVIVES restarts/crashes. Nothing
# removed it when a goal finished, so it kept firing every few hours forever —
# re-spawning sessions that churned through (and sometimes RE-ACTIVATED) already
# completed goals. A goal could also end up status="active" with completed_at set
# (finished-then-reopened), which made the Stop hook + cron perpetuate indefinitely.
#
# FIX — run this whenever the autonomy state changes:
#   1. SELF-HEAL: any goal with completed_at set but status in {active,in_progress}
#      is a finished goal that got re-opened -> reset its status to "complete".
#   2. If NO goal is then genuinely active (status active/in_progress AND no
#      completed_at), PRUNE every /goal-resume cron from scheduled_tasks.json and
#      clear stale session-*.goal claim files. Nothing is left to perpetuate.
#
# WIRE IT at three points (all installed by install.sh):
#   - SessionStart hook  -> prunes stale crons on every startup, incl. post-crash
#   - goal-continue.sh   -> the cron's own entry self-deletes the cron when it
#                           fires with nothing active
#   - goal-update-state.sh -> completing a goal removes its cron immediately
#
# Idempotent + FAIL-OPEN: any error -> exit 0. A hook must never wedge a session.

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GOALS_DIR="$REPO_ROOT/.claude/goals"
INDEX="$GOALS_DIR/index.json"
TASKS="$REPO_ROOT/.claude/scheduled_tasks.json"
[ -f "$INDEX" ] || exit 0

python3 - "$INDEX" "$TASKS" "$GOALS_DIR" <<'PY' 2>/dev/null || exit 0
import json, sys, os, glob, tempfile

index_path, tasks_path, goals_dir = sys.argv[1], sys.argv[2], sys.argv[3]
ACTIVE = {"active", "in_progress"}

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

healed, active = [], []
for g in idx.get("goals", []) or []:
    gid = g.get("id")
    gf = os.path.join(goals_dir, "goal-%s.json" % gid)   # per-goal file is authoritative
    gj = load(gf)
    status = (gj or g).get("status")
    completed_at = (gj or g).get("completed_at")
    if status in ACTIVE and completed_at:                # finished goal re-opened -> heal
        if gj is not None:
            gj["status"] = "complete"
            atomic_write(gf, gj)
        g["status"] = "complete"
        healed.append(gid)
        continue
    if status in ACTIVE and not completed_at:
        active.append(gid)

if healed:
    atomic_write(index_path, idx)

if active:
    if healed:
        try:
            open(os.path.join(goals_dir, "cron-guard.log"), "a", encoding="utf-8").write(
                "[goal-cron-guard] self-healed %s; %d still active -> crons kept\n" % (healed, len(active)))
        except Exception:
            pass
    sys.exit(0)  # genuine active work remains — leave crons + claims alone

# No genuinely-active goals -> prune /goal-resume crons + stale claims.
pruned = []
t = load(tasks_path)
if isinstance(t, dict) and isinstance(t.get("tasks"), list):
    keep = [c for c in t["tasks"] if "/goal" not in (c.get("prompt") or "").lower()]
    if len(keep) != len(t["tasks"]):
        for c in t["tasks"]:
            if "/goal" in (c.get("prompt") or "").lower():
                pruned.append("cron:%s" % c.get("id"))
        t["tasks"] = keep
        atomic_write(tasks_path, t)

for claim in glob.glob(os.path.join(goals_dir, "session-*.goal")):
    try:
        os.remove(claim)
        pruned.append("claim:%s" % os.path.basename(claim))
    except Exception:
        pass

if healed or pruned:
    try:
        open(os.path.join(goals_dir, "cron-guard.log"), "a", encoding="utf-8").write(
            "[goal-cron-guard] no active goals — healed=%s pruned=%s\n" % (healed, pruned))
    except Exception:
        pass
    parts = []
    if healed: parts.append("healed %d re-activated goal(s)" % len(healed))
    if pruned: parts.append("pruned %d stale cron/claim item(s)" % len(pruned))
    print("[goal-cron-guard] " + "; ".join(parts))
PY
exit 0

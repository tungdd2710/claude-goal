#!/usr/bin/env bash
# goal-stop-hook.sh — Stop-hook autonomy engine for /goal (v1.0.0).
#
# THE in-session never-stop engine. Wired as a `Stop` hook in
# .claude/settings.json. When a session tries to end its turn, this hook
# BLOCKS the stop and feeds the next-iteration EXECUTE instruction back into the
# SAME session (context preserved, no subprocess).
#
# PURE BLOCK — it never spawns `claude -p`. Spawning would recurse (a child -p
# fires its own Stop hooks). goal-continue.sh is the spawning cross-session
# resume; this hook only emits a {"decision":"block","reason":...} JSON.
#
# CLAIM-SCOPED + FAIL-OPEN. It only continues a session that wrote its claim file
# (.claude/goals/session-<session_id>.goal) for a goal whose status == "active".
# EVERY uncertainty path → ALLOW the stop (exit 0, no output). A Stop hook that
# failed closed would wedge every session in the repo — so the default is ALLOW.
#
# Guards (each → ALLOW):
#   - GOAL_DRIVER_ACTIVE set     → goal-loop.sh bash driver is driving; its child -p must end its turn
#   - .claude/goals/PAUSE exists → user kill-switch
#   - no session-*.goal claims   → no goal session anywhere; fast path for normal sessions
#   - no claim for THIS session  → this session isn't running a goal
#   - claimed goal not "active"   → nothing to continue
#   - any parse / read error      → fail open
#
# Harness backstop: the harness overrides a Stop hook after ~8 consecutive blocks
# (raise via CLAUDE_CODE_STOP_HOOK_BLOCK_CAP); the durable resume cron picks up
# across that boundary. This hook does not implement its own cap.

INPUT="$(cat 2>/dev/null || echo '{}')"
allow() { exit 0; }   # ALLOW the stop: exit 0, emit no block decision.

# Driver guard — the headless bash loop drives iterations; its child must stop.
[[ -n "${GOAL_DRIVER_ACTIVE:-}" ]] && allow

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GOALS_DIR="$REPO_ROOT/.claude/goals"

# User kill-switch.
[[ -f "$GOALS_DIR/PAUSE" ]] && allow

# Fast path: if no claim files exist at all, no session is running a goal.
shopt -s nullglob 2>/dev/null || true
_claims=("$GOALS_DIR"/session-*.goal)
shopt -u nullglob 2>/dev/null || true
[[ ${#_claims[@]} -eq 0 ]] && allow

# Identify THIS session.
SESSION_ID="$(printf '%s' "$INPUT" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('session_id','') or '')
except Exception: print('')" 2>/dev/null || echo '')"
[[ -z "$SESSION_ID" ]] && allow

CLAIM="$GOALS_DIR/session-${SESSION_ID}.goal"
[[ -f "$CLAIM" ]] || allow

GOAL_ID="$(tr -d '[:space:]' < "$CLAIM" 2>/dev/null || echo '')"
[[ -z "$GOAL_ID" ]] && allow

GOAL_FILE="$GOALS_DIR/goal-${GOAL_ID}.json"
[[ -f "$GOAL_FILE" ]] || allow

# Build the full {"decision":"block","reason":...} payload. Prints nothing if the
# goal is missing / not active / unparseable → caller falls through to ALLOW.
OUT="$(python3 - "$GOAL_FILE" <<'PY' 2>/dev/null || echo ''
import json, sys
try:
    g = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if g.get("status") != "active":
    sys.exit(0)
gid = g.get("id", "?"); obj = g.get("objective", "?")
b = g.get("budget", {}) or {}
used = b.get("used", 0) or 0; mx = b.get("max_iterations", 0) or 0; nxt = used + 1
cs = g.get("context_summary") or "(no context summary — read the state file)"
focus = ""
refs = g.get("reflections", []) or []
if refs:
    r = refs[-1]; nf = r.get("next_focus", {}) or {}
    files = ", ".join(nf.get("files", []) or []) or "(decide)"
    focus = "OUTCOME: %s\nFOCUS: %s on %s" % (r.get("outcome_reason", ""), nf.get("criterion", "any"), files)
    rf = r.get("research_files", []) or []
    if rf:
        focus += "\nREAD FIRST: %s" % ", ".join(rf)
crit = "\n".join(
    "bash .claude/scripts/goal-check-criterion.sh %s %s" % (json.dumps(c.get("check", "")), json.dumps(c.get("label", "")))
    for c in (g.get("success_criteria", []) or []) if c.get("check")
) or "(no criteria yet — this is iteration 1: survey + derive criteria/scope/budget, then probe-fix)"
banned = "\n".join("  - %s: %s" % (n.get("approach_tag", ""), n.get("detail", "")) for n in (g.get("negative_knowledge", []) or [])) or "(none)"
instruction = """GOAL CONTINUATION (Stop-hook) — goal %s, iteration %d/%d. DO NOT STOP, DO NOT ASK — this is /goal and the user is away.
Objective: %s
State file: .claude/goals/goal-%s.json
Where you left off: %s
%s

Step 1 ORIENT — run each criterion below, save as criteria_before. If ALL pass: run the Completion Audit (act as a user ~3 min on the real flow + grep known-bad patterns in scope), then `bash .claude/scripts/goal-update-state.sh --goal-id %s --status complete` and emit the Completion Report (the ONLY allowed prose).
%s
BANNED approach_tags (in negative_knowledge — do NOT reuse):
%s
Step 2 EXECUTE — target the FOCUS criterion/files; pick a new kebab approach_tag (not banned); edit; re-run the targeted criterion after each edit; revert if a passing criterion breaks. If next_focus spans >=5 independent units, fan out (Workflow tool / parallel sub-Agents in worktrees). Invoke any mandatory gate/skill for this boundary first (e.g. a commit-review, test, or AI-safety gate if you have one installed).
Step 3 VERIFY — re-run ALL criteria (criteria_after); `bash .claude/scripts/goal-update-state.sh --goal-id %s --iteration %d --approach "..." --approach-tag "tag" --changes "f.ts" --criteria-before-file /tmp/goal-before.json --criteria-after-file /tmp/goal-after.json`; on no_change/regression do Failure Analysis + `--add-negative "tag" "WHY: <mechanism>"`.
Step 4 REFLECT + CONTEXT + COMMIT — `--reflect /tmp/goal-reflect.json`; `--set-context-summary "Iteration %d done. <changed>. Next: <next>."`; `--update-metrics`; commit `goal(%s): iteration %d — <summary>`.
Your NEXT action is a TOOL CALL for iteration %d Step 1 — never prose.""" % (
    gid, nxt, mx, obj, gid, cs, focus, gid, crit, banned, gid, nxt, nxt, gid, nxt, nxt + 1)
# Stop hooks read ONLY top-level decision + reason (per the Claude Code hooks docs:
# the Stop "decision control" pattern is decision/reason; additionalContext is honored
# only for SessionStart/Setup/SubagentStart/UserPromptSubmit/PostToolUse — NOT Stop). So the full
# continuation brief MUST ride in `reason`, else Claude is blocked-but-unguided and re-stops every
# turn until the harness block cap fires — the exact pointless loop this hook exists to prevent.
# Headline first (what the user sees in "Stop hook feedback"), then the next-iteration brief.
print(json.dumps({
    "decision": "block",
    "reason": "/goal active (goal %s, iteration %d) — auto-continuing in-session, not stopping.\n\n%s" % (gid, nxt, instruction),
}))
PY
)"

[[ -z "$OUT" ]] && allow
printf '%s' "$OUT"
exit 0

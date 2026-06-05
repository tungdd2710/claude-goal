#!/usr/bin/env bash
# goal-no-text-reminder.sh — PostToolUse soft nudge for /goal (v1.0.0, 2026-05-29).
#
# While THIS session owns an active goal, inject a reminder after every tool call
# that the next action must be a tool call, never prose. Claim-scoped: silent for
# any session that isn't running a goal. The Stop hook is the hard engine; this is
# the soft nudge that keeps the model from drifting into a summary paragraph
# (the #1 stop-bug) between tool calls.
#
# Fail-quiet: any uncertainty → emit nothing (exit 0).

INPUT="$(cat 2>/dev/null || echo '{}')"
quiet() { exit 0; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GOALS_DIR="$REPO_ROOT/.claude/goals"

[[ -f "$GOALS_DIR/PAUSE" ]] && quiet

shopt -s nullglob 2>/dev/null || true
_claims=("$GOALS_DIR"/session-*.goal)
shopt -u nullglob 2>/dev/null || true
[[ ${#_claims[@]} -eq 0 ]] && quiet

SESSION_ID="$(printf '%s' "$INPUT" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('session_id','') or '')
except Exception: print('')" 2>/dev/null || echo '')"
[[ -z "$SESSION_ID" ]] && quiet

CLAIM="$GOALS_DIR/session-${SESSION_ID}.goal"
[[ -f "$CLAIM" ]] || quiet

GOAL_ID="$(tr -d '[:space:]' < "$CLAIM" 2>/dev/null || echo '')"
[[ -z "$GOAL_ID" ]] && quiet

GOAL_FILE="$GOALS_DIR/goal-${GOAL_ID}.json"
[[ -f "$GOAL_FILE" ]] || quiet

STATUS="$(python3 -c "import json,sys
try: print(json.load(open(sys.argv[1])).get('status','') or '')
except Exception: print('')" "$GOAL_FILE" 2>/dev/null || echo '')"
[[ "$STATUS" == "active" ]] || quiet

python3 -c "import json; print(json.dumps({'hookSpecificOutput':{'hookEventName':'PostToolUse','additionalContext':'[/goal active] Do NOT write prose to the user. Your next action MUST be another tool call advancing the goal (orient -> execute -> verify -> reflect -> next iteration). The only prose permitted in the entire goal lifecycle is the final Completion Report when status becomes complete/blocked/impossible.'}}))" 2>/dev/null || true
exit 0

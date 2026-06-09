#!/usr/bin/env bash
# goal-continue.sh — CROSS-SESSION resume (cron / manual). NOT the Stop hook.
# v0.5.0: the Stop hook is goal-stop-hook.sh (pure block, no spawn). This script spawns ONE
# fresh `claude -p` to (re)start a goal when no live session is working it — e.g. fired by the
# durable cron after the terminal was closed. The spawned session then SELF-CONTINUES via
# goal-stop-hook.sh (note: NO GOAL_DRIVER_ACTIVE here, unlike goal-loop.sh). Wiring THIS as a
# Stop hook would recurse (a -p child fires its own Stop hooks) — do NOT.
# Single active goal: resumes it. Multiple: exits (cron resumes each).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RESOLVE="$REPO_ROOT/.claude/scripts/goal-resolve.sh"
VALIDATE="$REPO_ROOT/.claude/scripts/goal-validate.sh"

# PAUSE sentinel — user kill-switch. Never resume while it exists.
[[ -f "$REPO_ROOT/.claude/goals/PAUSE" ]] && { echo "[goal] PAUSE sentinel present — not resuming."; exit 0; }

# Crash/completion safety: self-heal re-activated goals + prune stale /goal-resume
# crons when nothing is genuinely active. If this resume run has no active goal, the
# guard deletes THIS cron so it stops firing forever after a crash or once every
# goal is finished. See goal-cron-guard.sh.
bash "$REPO_ROOT/.claude/scripts/goal-cron-guard.sh" 2>/dev/null || true

# Try to resolve a single goal. If multiple or none, exit silently.
GOAL_FILE=$(bash "$RESOLVE" 2>/dev/null) || {
  # Multiple active goals or none — cron handles multi-goal resume
  ACTIVE_FILES=$(bash "$RESOLVE" --all-active 2>/dev/null || true)
  if [[ -n "$ACTIVE_FILES" ]]; then
    COUNT=$(echo "$ACTIVE_FILES" | wc -l)
    echo "[goal] $COUNT active goals. Cron will resume all."
  fi
  exit 0
}

STATUS=$(bash "$VALIDATE" "$GOAL_FILE" 2>/dev/null || echo "")
[[ "$STATUS" != "active" ]] && exit 0

GOAL_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$GOAL_FILE" 2>/dev/null || echo "unknown")
MAX_ITER=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['budget']['max_iterations'])" "$GOAL_FILE" 2>/dev/null || echo "0")
USED_ITER=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['budget']['used'])" "$GOAL_FILE" 2>/dev/null || echo "0")
OBJECTIVE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['objective'])" "$GOAL_FILE" 2>/dev/null || echo "unknown")

# Budget is a progress marker, not a hard stop — auto-extend so resume never dies on budget.
if [[ "$USED_ITER" -ge "$MAX_ITER" ]]; then
  NEWMAX=$((MAX_ITER + 5))
  bash "$REPO_ROOT/.claude/scripts/goal-update-state.sh" --goal-id "$GOAL_ID" --bump-budget "$NEWMAX" >/dev/null 2>&1 || true
  MAX_ITER="$NEWMAX"
  echo "[goal] Budget auto-extended to $MAX_ITER."
fi

NEXT_ITER=$((USED_ITER + 1))
echo "[goal] Continuing: $OBJECTIVE (goal $GOAL_ID, iteration $NEXT_ITER/$MAX_ITER)"

CTX_SUMMARY=$(python3 -c "
import json, sys
g = json.load(open(sys.argv[1]))
print(g.get('context_summary', '(no context summary)'))
" "$GOAL_FILE" 2>/dev/null || echo "(none)")

LAST_REFLECT=$(python3 -c "
import json, sys
g = json.load(open(sys.argv[1]))
refs = g.get('reflections', [])
if refs:
    r = refs[-1]
    print(f'Previous: {r.get(\"outcome_reason\",\"\")}')
    nf = r.get('next_focus', {})
    print(f'Focus: {nf.get(\"criterion\",\"any\")} on {nf.get(\"files\",[])}')
    rf = r.get('research_files', [])
    if rf: print(f'Read first: {rf}')
else:
    print('No reflection from previous iteration.')
" "$GOAL_FILE" 2>/dev/null || echo "")

SPAWNED_SESSION=true claude -p "$(cat <<PROMPT
GOAL CONTINUATION — Goal $GOAL_ID, Iteration $NEXT_ITER of $MAX_ITER
Objective: $OBJECTIVE
State file: $GOAL_FILE

**Where you left off:** $CTX_SUMMARY

$LAST_REFLECT

Follow the EXECUTE protocol:
1. ORIENT: read $GOAL_FILE, run criteria via goal-check-criterion.sh, check budget, read negative_knowledge
2. RESEARCH + EXECUTE: if reflection says read files first, do that. Target the focus criterion/files. Choose approach_tag not in negative_knowledge. Make changes. Re-check after each edit.
   ORCHESTRATE: prefer an autonomous-safe skill over hand-rolling (any commit/test/review/QA/research gate skills you have installed); for WIDE work (>=5 independent units) fan out via a Dynamic Workflow or parallel sub-Agents in worktrees; NEVER call interactive skills directly. Tier list: .claude/skills/goal/SKILL.md
3. VERIFY: run all criteria. Update state:
   bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --iteration $NEXT_ITER --approach "summary" --approach-tag "tag" --changes "f1.ts" --criteria-before-file /tmp/goal-before.json --criteria-after-file /tmp/goal-after.json
   Add negative if no_change/regression: --add-negative "tag" "reason"
4. REFLECT: write /tmp/goal-reflect.json then: goal-update-state.sh --goal-id $GOAL_ID --reflect /tmp/goal-reflect.json
5. CONTEXT: bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --set-context-summary "Iteration $NEXT_ITER done. <what changed>. Next: <what's next>."
Commit: goal($GOAL_ID): iteration $NEXT_ITER — <summary>

SAFETY: Never modify objective. Never extend budget. Never raw-Write the state file. Always use --goal-id $GOAL_ID.
PROMPT
)" --model "${GOAL_MODEL:-claude-sonnet-4-6}" --allowedTools "Edit,Read,Write,Bash,Grep,Glob,Agent,Skill" --max-turns 30

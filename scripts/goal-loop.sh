#!/usr/bin/env bash
# goal-loop.sh — Goal iteration runner (v0.4.0 — multi-goal; goal-skill 0.9.0 fan-out + skill-routing)
# Two-mode prompts: UNDERSTAND (iter 1) and EXECUTE (iter 2+).
# Reads structured reflections to guide each iteration.
#
# Usage:
#   bash .claude/scripts/goal-loop.sh [--goal-id ID] [--max N] [--model MODEL] [--max-turns N]

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
RESOLVE="$REPO_ROOT/.claude/scripts/goal-resolve.sh"
GOAL_LOGS="$REPO_ROOT/.claude/goals/logs"
VALIDATE="$REPO_ROOT/.claude/scripts/goal-validate.sh"
MAX_OVERRIDE=""
MODEL="${GOAL_MODEL:-claude-sonnet-4-6}"
MAX_TURNS=30
_GID_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --goal-id) _GID_ARG="$2"; shift 2 ;;
    --max) MAX_OVERRIDE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --max-turns) MAX_TURNS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

GOAL_FILE=$(bash "$RESOLVE" ${_GID_ARG:+--goal-id "$_GID_ARG"})

VALIDATE_EXIT=0
STATUS=$(bash "$VALIDATE" "$GOAL_FILE") || VALIDATE_EXIT=$?
if [[ $VALIDATE_EXIT -eq 1 ]]; then
  echo "No active goal. Use /goal or goal-init.sh to create one." >&2; exit 1
elif [[ $VALIDATE_EXIT -ge 2 ]]; then
  echo "Goal state corrupt. Check ${GOAL_FILE}.bak" >&2; exit 1
fi
if [[ "$STATUS" != "active" ]]; then
  echo "Goal status is '$STATUS', not 'active'. Use /goal resume." >&2; exit 1
fi

mkdir -p "$GOAL_LOGS"

GOAL_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$GOAL_FILE")
MAX_ITER=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['budget']['max_iterations'])" "$GOAL_FILE")
USED_ITER=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['budget']['used'])" "$GOAL_FILE")
OBJECTIVE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['objective'])" "$GOAL_FILE")
GOAL_FILE_REL="${GOAL_FILE#$REPO_ROOT/}"
[[ -n "$MAX_OVERRIDE" ]] && MAX_ITER="$MAX_OVERRIDE"

echo "=========================================="
echo "  GOAL LOOP v0.4.0 (multi-goal)"
echo "  ID: $GOAL_ID"
echo "  Objective: $OBJECTIVE"
echo "  Budget: $USED_ITER / $MAX_ITER iterations"
echo "  File: $GOAL_FILE_REL"
echo "  Model: $MODEL"
echo "=========================================="

STALL_COUNT=0
PREV_USED=-1

# Budget is a progress marker, NOT a hard stop (SKILL.md "no budget cap" contract).
# The loop runs until complete/blocked/paused/stalled — never until budget alone.
while true; do
  # PAUSE sentinel — the ONLY user-initiated mid-run stop (SKILL.md §contract item 4).
  if [[ -f "$REPO_ROOT/.claude/goals/PAUSE" ]]; then
    echo "=== GOAL $GOAL_ID: PAUSE sentinel (.claude/goals/PAUSE) — pausing. Delete it to resume. ==="
    bash "$REPO_ROOT/.claude/scripts/goal-update-state.sh" --goal-id "$GOAL_ID" --status paused; exit 0
  fi

  # Auto-extend when budget is reached, so the loop never stops on budget alone.
  if [[ "$USED_ITER" -ge "$MAX_ITER" ]]; then
    MAX_ITER=$((MAX_ITER + 5))
    echo "[goal] Budget reached at $USED_ITER — auto-extending +5 -> $MAX_ITER (no hard cap per contract)."
    bash "$REPO_ROOT/.claude/scripts/goal-update-state.sh" --goal-id "$GOAL_ID" --bump-budget "$MAX_ITER" >/dev/null 2>&1 || true
  fi

  ITER=$((USED_ITER + 1))
  LOG_FILE="$GOAL_LOGS/goal-${GOAL_ID}-iter-${ITER}-$(date +%s).log"
  echo ""
  echo "--- Goal $GOAL_ID — Iteration $ITER / $MAX_ITER ---"

  # Read worktree path
  WORKTREE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('worktree_path',''))" "$GOAL_FILE" 2>/dev/null || echo "")
  WORKDIR_NOTE=""
  [[ -n "$WORKTREE" && -d "$REPO_ROOT/$WORKTREE" ]] && WORKDIR_NOTE="WORKING DIRECTORY: $REPO_ROOT/$WORKTREE"

  if [[ "$ITER" -eq 1 ]]; then
    # === UNDERSTAND MODE (iteration 1) ===
    HAS_CRITERIA=$(python3 -c "import json,sys; g=json.load(open(sys.argv[1])); print('yes' if g.get('success_criteria') and len(g['success_criteria'])>0 and g['success_criteria'][0].get('check','')!='REPLACE: bash command that exits 0 on success' else 'no')" "$GOAL_FILE" 2>/dev/null || echo "no")

    PROMPT=$(cat <<'UNDERSTAND_PROMPT_HEADER'
GOAL — ITERATION 1: UNDERSTAND

You have a new goal. This is your first iteration. Your job is to RESEARCH first, then do ONE probe fix.
UNDERSTAND_PROMPT_HEADER
)
    PROMPT="$PROMPT
$WORKDIR_NOTE

Objective: $OBJECTIVE
Goal ID: $GOAL_ID
State file: $GOAL_FILE

Read the state file for full state.
"

    if [[ "$HAS_CRITERIA" == "no" ]]; then
      PROMPT="$PROMPT
**PRIORITY: Survey codebase + derive criteria (MUST complete before anything else).**

Survey: grep/read to find where this goal's problem lives. Map files + patterns.
Then derive and save criteria, scope, budget:
  bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --set-criteria '[{\"check\":\"cmd\",\"label\":\"desc\",\"auto\":true}]'
  bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --set-scope '[\"dir/\"]'
  bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --set-flex '[\"dep-dir/\"]'
  bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --bump-budget N
  bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --set-infra '{\"typecheck_clean\":true,\"tests_exist\":false}'
Criteria tips: check if a typechecker/test-runner/linter exists. Generate ONE structural grep criterion for the goal.
Budget: ceil(file_count / 5) + 1, cap 10.
"
    else
      PROMPT="$PROMPT
Criteria already set. Survey the codebase to understand the problem.
"
    fi

    PROMPT="$PROMPT
**IF TURNS REMAIN: Probe fix** — pick ONE median-complexity file, fix it, run criteria.

**BEFORE EXITING: Reflect** — write /tmp/goal-reflect.json then run:
  bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --reflect /tmp/goal-reflect.json
Format: {\"outcome_reason\":\"...\",\"next_focus\":{\"criterion\":\"...\",\"files\":[\"...\"]},\"research_files\":[]}

Commit: goal($GOAL_ID): iteration 1 — survey + probe
SAFETY: Use goal-update-state.sh --goal-id $GOAL_ID for ALL state writes. Never raw-Write the state file."

  else
    # === EXECUTE MODE (iterations 2+) ===
    CTX_SUMMARY=$(python3 -c "
import json, sys
g = json.load(open(sys.argv[1]))
cs = g.get('context_summary', '')
print(cs if cs else '(no context summary — read state file for full state)')
" "$GOAL_FILE" 2>/dev/null || echo "(could not read)")

    CRITERION_CMDS=$(python3 -c "
import json, sys
g = json.load(open(sys.argv[1]))
for c in g.get('success_criteria', []):
    check = c.get('check','')
    label = c.get('label','')
    if check: print(f'bash .claude/scripts/goal-check-criterion.sh \"{check}\" \"{label}\"')
" "$GOAL_FILE" 2>/dev/null || echo "# No criteria found")

    LAST_REFLECT=$(python3 -c "
import json, sys
g = json.load(open(sys.argv[1]))
refs = g.get('reflections', [])
if refs:
    r = refs[-1]
    print(f'OUTCOME: {r.get(\"outcome_reason\",\"none\")}')
    nf = r.get('next_focus', {})
    print(f'FOCUS CRITERION: {nf.get(\"criterion\",\"any failing\")}')
    files = nf.get('files', [])
    print(f'FOCUS FILES: {\", \".join(files) if files else \"(agent decides)\"}')
    rf = r.get('research_files', [])
    if rf:
        print(f'READ FIRST: {\", \".join(rf)}')
else:
    print('No previous reflection.')
" "$GOAL_FILE" 2>/dev/null || echo "No reflections found.")

    NEG_KNOWLEDGE=$(python3 -c "
import json, sys
g = json.load(open(sys.argv[1]))
nk = g.get('negative_knowledge', [])
if not nk: print('(none)')
else:
    for n in nk: print(f'  - TAG \"{n[\"approach_tag\"]}\": {n[\"detail\"]}')
" "$GOAL_FILE" 2>/dev/null || echo "(none)")

    PROMPT=$(cat <<EXECUTE_PROMPT
GOAL — ITERATION $ITER: EXECUTE
Goal ID: $GOAL_ID | State file: $GOAL_FILE
$WORKDIR_NOTE

**Where you left off:** $CTX_SUMMARY

**Previous reflection:**
$LAST_REFLECT

**Step 1 — Orient:**
Run these EXACT commands for criteria checks:
$CRITERION_CMDS
Save results as criteria_before. If ALL pass → bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --status complete → exit.

**BANNED approaches (do NOT reuse):**
$NEG_KNOWLEDGE

**Step 2 — Research + Execute:**
- If the reflection above says READ FIRST → read those files before coding.
- Target the FOCUS CRITERION and FOCUS FILES from the reflection.
- ORCHESTRATE: prefer an autonomous-safe skill over hand-rolling (any commit/test/review/QA/research gate skills you have installed). For WIDE work (>=5 independent units) fan out via a Dynamic Workflow or parallel sub-Agents in worktrees. NEVER call interactive skills directly. Tier list + how: .claude/skills/goal/SKILL.md
- Choose approach_tag (max 3 words, kebab-case). Must NOT match banned tags.
- Make changes. Re-run targeted criterion after each edit. Revert if passing criterion breaks.

**Step 3 — Verify:**
Run ALL criteria checks again. Save as criteria_after.
Update state (outcome computed mechanically):
  bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --iteration $ITER \\
    --approach "summary" --approach-tag "tag" --changes "f1.ts,f2.ts" \\
    --criteria-before-file /tmp/goal-before.json --criteria-after-file /tmp/goal-after.json
If no_change/regression: bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --add-negative "tag" "reason"
If ALL pass: bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --status complete

**Step 4 — Reflect:**
Write /tmp/goal-reflect.json with EXACTLY 3 fields:
  outcome_reason — WHY this iteration's outcome was what it was (one sentence, specific)
  next_focus — {criterion, files} to target next iteration
  research_files — specific paths to read before next iteration (empty if not needed)
Then: bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --reflect /tmp/goal-reflect.json

Then write a context summary (3 sentences: what's done, current state, what's next):
  bash .claude/scripts/goal-update-state.sh --goal-id $GOAL_ID --set-context-summary "Iteration $ITER done. <what changed>. Next: <what to do>."

Commit: goal($GOAL_ID): iteration $ITER — <summary>

SAFETY: Never modify objective. Never extend budget. Never raw-Write the state file. Always use --goal-id $GOAL_ID.
EXECUTE_PROMPT
)
  fi

  # SPAWNED_SESSION=true → conditional skills that honor it auto-pick recommended defaults (no AskUserQuestion).
  # GOAL_DRIVER_ACTIVE=1 → tells goal-stop-hook.sh to ALLOW the child's stop: THIS bash loop is the
  #   driver, so each per-iteration `claude -p` must end its turn (not self-continue via the Stop
  #   hook, which would double-drive). The interactive + cron paths omit this, so they DO self-continue.
  # Agent,Skill → enables fan-out (dynamic workflows / sub-Agents) + skill routing per SKILL.md.
  SPAWNED_SESSION=true GOAL_DRIVER_ACTIVE=1 claude -p "$PROMPT" \
    --model "$MODEL" \
    --allowedTools "Edit,Read,Write,Bash,Grep,Glob,Agent,Skill" \
    --max-turns "$MAX_TURNS" \
    --verbose \
    2>&1 | tee "$LOG_FILE"

  # Re-validate
  STATUS=$(bash "$VALIDATE" "$GOAL_FILE" 2>/dev/null || echo "corrupt")
  case "$STATUS" in
    complete|blocked|paused|budget_limited|cleared|impossible)
      echo ""; echo "=== GOAL $GOAL_ID: $STATUS at iteration $ITER ==="; exit 0 ;;
    corrupt)
      echo "State file corrupted. Check ${GOAL_FILE}.bak" >&2; exit 1 ;;
  esac

  NEW_USED=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['budget']['used'])" "$GOAL_FILE" 2>/dev/null || echo "")
  [[ -n "$NEW_USED" ]] && USED_ITER="$NEW_USED"

  # Stall detection: budget.used did NOT advance this iteration → the iteration
  # recorded no state (prompt didn't land / agent crashed / no --iteration call).
  # Without this, auto-extend would spin forever on a non-advancing iteration.
  if [[ "$USED_ITER" -eq "$PREV_USED" ]]; then
    STALL_COUNT=$((STALL_COUNT + 1))
    echo "[goal] WARNING: budget.used did not advance ($USED_ITER) — stall $STALL_COUNT/2."
    if [[ "$STALL_COUNT" -ge 2 ]]; then
      echo "=== GOAL $GOAL_ID: STALLED (no state progress in 2 iterations) — blocking for human review. ==="
      bash "$REPO_ROOT/.claude/scripts/goal-update-state.sh" --goal-id "$GOAL_ID" --status blocked; exit 2
    fi
  else
    STALL_COUNT=0
  fi
  PREV_USED="$USED_ITER"

  # Stuck detection: same approach_tag failing twice = block
  LAST_TAG=$(python3 -c "
import json, sys
g = json.load(open(sys.argv[1]))
logs = g.get('iteration_log', [])
if len(logs) >= 2:
    t1, t2 = logs[-1].get('approach_tag',''), logs[-2].get('approach_tag','')
    o1, o2 = logs[-1].get('outcome',''), logs[-2].get('outcome','')
    same_tag = t1 == t2 and t1 != ''
    both_fail = o1 in ('no_change','regression') and o2 in ('no_change','regression')
    print('BLOCK' if same_tag and both_fail else 'CONTINUE')
else:
    print('CONTINUE')
" "$GOAL_FILE" 2>/dev/null || echo "CONTINUE")

  if [[ "$LAST_TAG" == "BLOCK" ]]; then
    echo ""; echo "=== GOAL $GOAL_ID: SAME APPROACH FAILED TWICE — blocking ==="
    bash "$REPO_ROOT/.claude/scripts/goal-update-state.sh" --goal-id "$GOAL_ID" --status blocked; exit 2
  fi
  echo "--- Goal $GOAL_ID — Iteration $ITER done. Status: $STATUS ---"
done

# Unreachable under normal operation: the loop only exits via an explicit `exit`
# (complete / blocked / paused / stalled). Budget is auto-extended, never terminal.
echo "=== GOAL $GOAL_ID: loop exited unexpectedly ==="

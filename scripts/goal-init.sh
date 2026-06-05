#!/usr/bin/env bash
# goal-init.sh — Create a goal state file (v0.4.0 — multi-goal)
# Each goal stored as .claude/goals/goal-{id}.json + indexed in index.json.
# Multiple concurrent goals supported with scope overlap rejection.
#
# Usage:
#   bash .claude/scripts/goal-init.sh \
#     --objective "Add unit tests for auth module" \
#     --scope "src/lib/auth/" \
#     --flex "src/lib/db/" \
#     --check "npx vitest run" --label "Tests pass" \
#     --max 5

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GOALS_DIR="$REPO_ROOT/.claude/goals"
RESOLVE="$REPO_ROOT/.claude/scripts/goal-resolve.sh"
VALIDATE="$REPO_ROOT/.claude/scripts/goal-validate.sh"

OBJECTIVE=""
SCOPE=""
FLEX=""
CHECKS=()
LABELS=()
MAX_ITER=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --objective) OBJECTIVE="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --flex) FLEX="$2"; shift 2 ;;
    --check) CHECKS+=("$2"); shift 2 ;;
    --label) LABELS+=("$2"); shift 2 ;;
    --max) MAX_ITER="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$OBJECTIVE" ]]; then
  echo "Usage: goal-init.sh --objective \"...\" [--scope \"dir1,dir2\"] [--check \"cmd\" --label \"desc\"] [--max N]" >&2
  exit 1
fi

if [[ ${#CHECKS[@]} -ne ${#LABELS[@]} ]]; then
  echo "Each --check must have a matching --label" >&2
  exit 1
fi

mkdir -p "$GOALS_DIR"

# Trigger migration + ensure index.json via goal-resolve.sh
bash "$RESOLVE" --all-active >/dev/null 2>&1 || true
INDEX_FILE="$GOALS_DIR/index.json"
[[ ! -f "$INDEX_FILE" ]] && echo '{"version":1,"goals":[]}' > "$INDEX_FILE"

# Generate ID and slug
GOAL_ID=$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
SLUG=$(echo "$OBJECTIVE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)
BRANCH="goal/$SLUG"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GOAL_FILE="$GOALS_DIR/goal-${GOAL_ID}.json"

# Build scope arrays
SCOPE_JSON=$(python3 -c "
import json, sys
parts = [p.strip() for p in sys.argv[1].split(',') if p.strip()]
print(json.dumps(parts))
" "${SCOPE:-}")

FLEX_JSON="[]"
if [[ -n "${FLEX:-}" ]]; then
  FLEX_JSON=$(python3 -c "
import json, sys
parts = [p.strip() for p in sys.argv[1].split(',') if p.strip()]
print(json.dumps(parts))
" "$FLEX")
fi

# Reject scope overlap with existing active goals
python3 -c "
import json, os, sys
goals_dir = sys.argv[1]
new_scope = json.loads(sys.argv[2])
idx_file = os.path.join(goals_dir, 'index.json')
if not os.path.exists(idx_file) or not new_scope:
    sys.exit(0)
idx = json.load(open(idx_file))
for g in idx.get('goals', []):
    if g['status'] != 'active': continue
    gf = os.path.join(goals_dir, f'goal-{g[\"id\"]}.json')
    if not os.path.exists(gf): continue
    existing = json.load(open(gf))
    for es in existing.get('scope_lock', []):
        for ns in new_scope:
            es_n = es.rstrip('/')
            ns_n = ns.rstrip('/')
            if ns_n.startswith(es_n) or es_n.startswith(ns_n):
                print(f'SCOPE OVERLAP with goal {g[\"id\"]} ({g[\"objective\"][:40]}): {ns} vs {es}', file=sys.stderr)
                print('Two goals cannot edit the same directories. Pause or clear the other goal first.', file=sys.stderr)
                sys.exit(1)
" "$GOALS_DIR" "$SCOPE_JSON"

# Build criteria JSON (empty = iteration 1 will derive)
if [[ ${#CHECKS[@]} -eq 0 ]]; then
  CRITERIA_JSON="[]"
else
  # checks then labels passed as argv — newline-safe, no temp-file line protocol
  CRITERIA_JSON=$(python3 -c "
import json, sys
n = (len(sys.argv) - 1) // 2
checks, labels = sys.argv[1:1+n], sys.argv[1+n:1+2*n]
print(json.dumps([{'check': c, 'label': l, 'auto': False} for c, l in zip(checks, labels)], ensure_ascii=False))
" "${CHECKS[@]}" "${LABELS[@]}")
fi

# Use worktree if other active goals exist (isolation)
ACTIVE_COUNT=$(python3 -c "
import json, sys
idx = json.load(open(sys.argv[1]))
print(sum(1 for g in idx.get('goals', []) if g['status'] == 'active'))
" "$INDEX_FILE")

WORKTREE_PATH=""
if [[ "$ACTIVE_COUNT" -gt 0 ]]; then
  WORKTREE_PATH=".claude/goals/worktree-$GOAL_ID"
fi

# Write state file atomically
python3 -c "
import json, sys, os

goal = {
    'id': sys.argv[1],
    'objective': sys.argv[2],
    'success_criteria': json.loads(sys.argv[3]),
    'scope_lock': json.loads(sys.argv[4]),
    'scope_flex': json.loads(sys.argv[5]),
    'status': 'active',
    'budget': {'max_iterations': int(sys.argv[6]), 'used': 0},
    'iteration_log': [],
    'negative_knowledge': [],
    'reflections': [],
    'discovered_infra': {},
    'impossibility_reason': None,
    'created_at': sys.argv[7],
    'paused_at': None,
    'completed_at': None,
    'branch': sys.argv[8],
    'worktree_path': sys.argv[9],
    'context_summary': '',
    'metrics': {
        'total_iterations': 0,
        'total_tool_calls': 0,
        'total_wall_clock_seconds': 0,
        'total_tokens_estimated': 0,
        'session_count': 0,
        'commits': 0,
        'negative_knowledge_count': 0
    }
}

gf = sys.argv[10]
tmp = gf + '.tmp'
with open(tmp, 'w') as f:
    json.dump(goal, f, indent=2, ensure_ascii=False)
os.replace(tmp, gf)
" "$GOAL_ID" "$OBJECTIVE" "$CRITERIA_JSON" "$SCOPE_JSON" "$FLEX_JSON" "$MAX_ITER" "$TIMESTAMP" "$BRANCH" "$WORKTREE_PATH" "$GOAL_FILE"

# Validate
if ! bash "$VALIDATE" "$GOAL_FILE" >/dev/null 2>&1; then
  echo "Validation failed after write" >&2
  exit 1
fi

# Add to index.json atomically
python3 -c "
import json, sys, os
idx_file = sys.argv[1]
idx = json.load(open(idx_file))
idx['goals'].append({
    'id': sys.argv[2],
    'objective': sys.argv[3],
    'status': 'active',
    'branch': sys.argv[4],
    'created_at': sys.argv[5]
})
tmp = idx_file + '.tmp'
with open(tmp, 'w') as f:
    json.dump(idx, f, indent=2, ensure_ascii=False)
os.replace(tmp, idx_file)
" "$INDEX_FILE" "$GOAL_ID" "$OBJECTIVE" "$BRANCH" "$TIMESTAMP"

# Create worktree if needed
if [[ -n "$WORKTREE_PATH" ]]; then
  if git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" -b "$BRANCH" 2>/dev/null; then
    echo "Worktree: $WORKTREE_PATH"
  else
    echo "Note: worktree creation failed. Will run in main tree." >&2
    python3 -c "
import json, sys, os
gf = sys.argv[1]
g = json.load(open(gf))
g['worktree_path'] = ''
tmp = gf + '.tmp'
with open(tmp, 'w') as f:
    json.dump(g, f, indent=2, ensure_ascii=False)
os.replace(tmp, gf)
" "$GOAL_FILE"
  fi
fi

cp "$GOAL_FILE" "$GOAL_FILE.bak"

# Write THIS session's claim so the Stop-hook engine auto-continues this session
# (LOAD-BEARING — see SKILL.md §Session claiming). Without a claim the never-stop
# loop silently dies on the first turn-end. Idempotent; skipped when the env var is
# unset (e.g. headless goal-loop.sh, which drives via GOAL_DRIVER_ACTIVE instead).
if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
  echo "$GOAL_ID" > "$GOALS_DIR/session-${CLAUDE_CODE_SESSION_ID}.goal"
fi

echo ""
echo "  GOAL CREATED (v0.4.0 multi-goal)"
echo "  ID:        $GOAL_ID"
echo "  Objective: $OBJECTIVE"
echo "  Branch:    $BRANCH"
echo "  Worktree:  ${WORKTREE_PATH:-main tree}"
echo "  Budget:    0 / $MAX_ITER"
echo "  File:      goal-${GOAL_ID}.json"
echo "  Active:    $((ACTIVE_COUNT + 1)) goal(s) now active"

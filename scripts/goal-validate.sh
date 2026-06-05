#!/usr/bin/env bash
# goal-validate.sh — Validate goal state file JSON + schema
# Fix for Round 10: one corrupt JSON kills the system.
#
# Usage:
#   bash .claude/scripts/goal-validate.sh [path]
#   Default path: .claude/goals/active.json
#
# Exit codes:
#   0 — valid
#   1 — file missing
#   2 — invalid JSON
#   3 — schema violation (missing required fields)
#
# On success: prints the parsed status to stdout
# On failure: prints diagnostic to stderr

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ -z "${1:-}" ]]; then
  GOAL_FILE=$(bash "$REPO_ROOT/.claude/scripts/goal-resolve.sh" 2>/dev/null) || { echo "NO_FILE"; exit 1; }
else
  GOAL_FILE="$1"
fi

if [[ ! -f "$GOAL_FILE" ]]; then
  echo "NO_FILE"
  exit 1
fi

python3 -c "
import json, sys

try:
    with open(sys.argv[1]) as f:
        g = json.load(f)
except json.JSONDecodeError as e:
    print(f'JSON_ERROR: {e}', file=sys.stderr)
    sys.exit(2)

required = ['id','objective','success_criteria','scope_lock','status','budget','iteration_log','negative_knowledge','created_at','branch']
missing = [k for k in required if k not in g]
if missing:
    print(f'SCHEMA_ERROR: missing fields: {missing}', file=sys.stderr)
    sys.exit(3)

if not isinstance(g['budget'], dict) or 'max_iterations' not in g['budget'] or 'used' not in g['budget']:
    print('SCHEMA_ERROR: budget must have max_iterations and used', file=sys.stderr)
    sys.exit(3)

if not isinstance(g['success_criteria'], list):
    print('SCHEMA_ERROR: success_criteria must be a list', file=sys.stderr)
    sys.exit(3)

for i, c in enumerate(g['success_criteria']):
    if 'check' not in c or 'label' not in c:
        print(f'SCHEMA_ERROR: criterion {i} missing check or label', file=sys.stderr)
        sys.exit(3)

if g['status'] not in ('active','paused','complete','blocked','budget_limited','cleared','impossible'):
    print(f'SCHEMA_ERROR: invalid status: {g[\"status\"]}', file=sys.stderr)
    sys.exit(3)

# v0.3.0 fields are optional for backwards compat
# reflections, discovered_infra, criteria with auto flag

print(g['status'])
" "$GOAL_FILE"

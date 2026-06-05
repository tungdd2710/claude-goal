#!/usr/bin/env bash
# goal-list.sh — List all goals from index.json (v0.1.0)
#
# Usage:
#   bash .claude/scripts/goal-list.sh [--active-only]

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GOALS_DIR="$REPO_ROOT/.claude/goals"
INDEX_FILE="$GOALS_DIR/index.json"

ACTIVE_ONLY=false
[[ "${1:-}" == "--active-only" ]] && ACTIVE_ONLY=true

if [[ ! -f "$INDEX_FILE" ]]; then
  echo "No goals found. Use /goal to create one."
  exit 0
fi

python3 -c "
import json, os, sys

d = sys.argv[1]
active_only = sys.argv[2] == 'true'
idx = json.load(open(os.path.join(d, 'index.json')))
goals = idx.get('goals', [])

if active_only:
    goals = [g for g in goals if g['status'] == 'active']

if not goals:
    msg = 'No active goals.' if active_only else 'No goals found. Use /goal to create one.'
    print(msg)
    sys.exit(0)

print(f'  {\"ID\":<10} {\"STATUS\":<12} {\"BUDGET\":>7}  OBJECTIVE')
print('  ' + '-' * 80)

for g in goals:
    gf = os.path.join(d, f'goal-{g[\"id\"]}.json')
    budget = '?/?'
    if os.path.exists(gf):
        full = json.load(open(gf))
        b = full.get('budget', {})
        budget = f'{b.get(\"used\", 0)}/{b.get(\"max_iterations\", \"?\")}'
    obj = g.get('objective', '')[:55]
    print(f'  {g[\"id\"]:<10} {g[\"status\"]:<12} {budget:>7}  {obj}')

active_count = sum(1 for g in idx.get('goals', []) if g['status'] == 'active')
total = len(idx.get('goals', []))
print(f'\n  {active_count} active / {total} total')
" "$GOALS_DIR" "$ACTIVE_ONLY"

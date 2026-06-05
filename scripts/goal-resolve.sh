#!/usr/bin/env bash
# goal-resolve.sh — Resolve goal ID to state file path (v0.1.0)
# Multi-goal support: each goal stored as .claude/goals/goal-{id}.json
# Index at .claude/goals/index.json tracks all goals.
#
# Usage:
#   goal-resolve.sh                       # auto-detect (single active or CWD worktree match)
#   goal-resolve.sh --goal-id abc12345    # explicit goal
#   goal-resolve.sh --all-active          # print all active goal file paths (one per line)

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GOALS_DIR="$REPO_ROOT/.claude/goals"
INDEX_FILE="$GOALS_DIR/index.json"

GOAL_ID=""
ALL_ACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --goal-id) GOAL_ID="$2"; shift 2 ;;
    --all-active) ALL_ACTIVE=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$GOALS_DIR"

# Migration: legacy active.json → goal-{id}.json + index.json
if [[ -f "$GOALS_DIR/active.json" && ! -f "$INDEX_FILE" ]]; then
  python3 -c "
import json, os, sys, shutil
d = sys.argv[1]
af = os.path.join(d, 'active.json')
g = json.load(open(af))
gid = g.get('id', 'legacy')
dst = os.path.join(d, f'goal-{gid}.json')
shutil.copy2(af, dst)
idx = {'version': 1, 'goals': [{'id': gid, 'objective': g.get('objective', ''),
       'status': g.get('status', 'active'), 'branch': g.get('branch', ''),
       'created_at': g.get('created_at', '')}]}
with open(os.path.join(d, 'index.json'), 'w') as f:
    json.dump(idx, f, indent=2, ensure_ascii=False)
os.rename(af, af + '.migrated')
print(f'Migrated active.json -> goal-{gid}.json', file=sys.stderr)
" "$GOALS_DIR" 2>/dev/null || true
fi

# Ensure index exists
if [[ ! -f "$INDEX_FILE" ]]; then
  echo '{"version": 1, "goals": []}' > "$INDEX_FILE"
fi

# --all-active: list all active goal file paths
if [[ "$ALL_ACTIVE" == "true" ]]; then
  python3 -c "
import json, os, sys
d = sys.argv[1]
for g in json.load(open(os.path.join(d, 'index.json'))).get('goals', []):
    if g['status'] == 'active':
        p = os.path.join(d, f'goal-{g[\"id\"]}.json')
        if os.path.exists(p): print(p)
" "$GOALS_DIR"
  exit 0
fi

# --goal-id: explicit lookup
if [[ -n "$GOAL_ID" ]]; then
  f="$GOALS_DIR/goal-${GOAL_ID}.json"
  if [[ ! -f "$f" ]]; then
    echo "Goal not found: goal-${GOAL_ID}.json" >&2
    exit 1
  fi
  echo "$f"
  exit 0
fi

# Auto-detect: single-active fallback, then CWD worktree match
python3 -c "
import json, os, sys

d = sys.argv[1]
idx = json.load(open(os.path.join(d, 'index.json')))
active = [g for g in idx.get('goals', []) if g['status'] == 'active']

if not active:
    print('No active goals', file=sys.stderr)
    sys.exit(1)

if len(active) == 1:
    print(os.path.join(d, f'goal-{active[0][\"id\"]}.json'))
    sys.exit(0)

# Multiple active: try CWD worktree match
cwd = os.path.abspath('.').replace(os.sep, '/')
repo = os.path.dirname(d).replace(os.sep, '/')
for g in active:
    gf = os.path.join(d, f'goal-{g[\"id\"]}.json')
    if not os.path.exists(gf): continue
    goal = json.load(open(gf))
    wt = goal.get('worktree_path', '')
    if wt:
        wt_abs = os.path.normpath(os.path.join(repo, wt)).replace(os.sep, '/')
        if cwd.startswith(wt_abs):
            print(gf)
            sys.exit(0)

print(f'Ambiguous: {len(active)} active goals. Use --goal-id:', file=sys.stderr)
for g in active:
    print(f'  {g[\"id\"]}: {g[\"objective\"][:60]}', file=sys.stderr)
sys.exit(1)
" "$GOALS_DIR"

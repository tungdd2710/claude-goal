#!/usr/bin/env bash
# goal-no-ask.sh — PreToolUse hook on AskUserQuestion. While this session is BOUND to an active goal,
# BLOCK the question. The /goal contract is NEVER-ASK: the user designed the skill to set-and-walk-away,
# so making them answer mid-goal defeats it. Decide from the plan / locked specs / memory and execute.
# Fails OPEN (allow) on any uncertainty. A .claude/goals/PAUSE sentinel lets questions through.
INPUT=$(cat 2>/dev/null || echo '{}')
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-.}")"
GOALS_DIR="$REPO_ROOT/.claude/goals"
[ -f "$GOALS_DIR/PAUSE" ] && exit 0
BOUND=$(python3 -c '
import json,sys,os
gd=sys.argv[1]
try: data=json.loads(sys.argv[2])
except Exception: sys.exit(0)
sid=data.get("session_id") or ""
if not sid: sys.exit(0)
try:
    idx=json.load(open(os.path.join(gd,"index.json")))
    active=set(g["id"] for g in idx.get("goals",[]) if g.get("status")=="active")
except Exception: active=set()
if not active: sys.exit(0)
bound=False
claim=os.path.join(gd,"session-"+sid+".goal")
if os.path.exists(claim):
    try:
        if open(claim).read().strip() in active: bound=True
    except Exception: pass
if not bound:
    blog=os.path.join(gd,"session-bindings.log")
    if os.path.exists(blog):
        try:
            for ln in open(blog):
                p=ln.split()
                if len(p)>=2 and p[0]==sid and p[1] in active: bound=True; break
        except Exception: pass
print("BLOCK" if bound else "")
' "$GOALS_DIR" "$INPUT" 2>/dev/null || echo '')
if [ "$BOUND" = "BLOCK" ]; then
  echo "NEVER-ASK CONTRACT: a goal is active and bound to this session. Do NOT ask the user — that defeats /goal (set-and-walk-away). DECIDE from the plan / locked specs / memory and make the next tool call yourself. Only a genuinely irreversible + ambiguous prod mutation may pause (and even then prefer act-then-let-user-redirect)." >&2
  exit 2
fi
exit 0

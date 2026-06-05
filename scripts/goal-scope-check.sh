#!/usr/bin/env bash
# goal-scope-check.sh — PostToolUse scope-lock guard for /goal (v1.0.0 claim-scoped rewrite, 2026-05-29).
#
# Reverts the JUST-EDITED file when it falls outside the active goal's scope_lock +
# scope_flex — but ONLY for the session that CLAIMED that goal (claim-scoped, like
# goal-stop-hook.sh). FAIL-OPEN: any uncertainty (no claim, not active, path can't be
# resolved to repo-relative, parse error) → ALLOW, never revert.
#
# Two safety fixes vs the old v0.2.1 (which made it UNWIRABLE and is why it was never wired):
#  1. CLAIM-SCOPED — acts only when stdin session_id owns an `active` goal claim. A
#     normal / non-goal session (no claim file) is untouched, so this is now safe to
#     wire always-on. The old version fired for ANY session whenever ONE goal was
#     active → it would `git checkout`-revert every other session's out-of-scope edits.
#  2. ONLY the file just edited (from tool_input.file_path) is ever reverted — NOT the
#     whole `git diff`. Pre-existing / concurrent unrelated changes are never touched.
#
# Exit 0 = allow. Exit 2 = the edit was reverted; stderr is surfaced to the model.

INPUT="$(cat 2>/dev/null || echo '{}')"
ok() { exit 0; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GOALS_DIR="$REPO_ROOT/.claude/goals"

[[ -f "$GOALS_DIR/PAUSE" ]] && ok

# Fast path: no claim files → no goal session anywhere.
shopt -s nullglob 2>/dev/null || true
_claims=("$GOALS_DIR"/session-*.goal)
shopt -u nullglob 2>/dev/null || true
[[ ${#_claims[@]} -eq 0 ]] && ok

SESSION_ID="$(printf '%s' "$INPUT" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('session_id','') or '')
except Exception: print('')" 2>/dev/null || echo '')"
[[ -z "$SESSION_ID" ]] && ok

# Claim-scoped: only enforce for the session that owns a goal.
CLAIM="$GOALS_DIR/session-${SESSION_ID}.goal"
[[ -f "$CLAIM" ]] || ok

GOAL_ID="$(tr -d '[:space:]' < "$CLAIM" 2>/dev/null || echo '')"
[[ -z "$GOAL_ID" ]] && ok
GOAL_FILE="$GOALS_DIR/goal-${GOAL_ID}.json"
[[ -f "$GOAL_FILE" ]] || ok

STATUS="$(python3 -c "import json,sys
try: print(json.load(open(sys.argv[1])).get('status','') or '')
except Exception: print('')" "$GOAL_FILE" 2>/dev/null || echo '')"
[[ "$STATUS" == "active" ]] || ok

EDITED="$(printf '%s' "$INPUT" | python3 -c "import json,sys
try:
    ti=(json.load(sys.stdin).get('tool_input',{}) or {})
    print(ti.get('file_path','') or ti.get('path','') or '')
except Exception: print('')" 2>/dev/null || echo '')"
[[ -z "$EDITED" ]] && ok

# Decide. Prints 'ALLOW' or 'REVERT\t<repo-relative-path>'. Fail-open → ALLOW.
DECISION="$(python3 - "$GOAL_FILE" "$EDITED" "$REPO_ROOT" <<'PY' 2>/dev/null || echo 'ALLOW'
import json, sys, re
try:
    g = json.load(open(sys.argv[1]))
except Exception:
    print("ALLOW"); sys.exit(0)
def norm(p):
    p = p.replace("\\", "/")                 # Windows backslash -> forward slash
    m = re.match(r"^/([a-zA-Z])/(.*)$", p)   # git-bash /c/Projects -> c:/Projects
    if m:
        p = m.group(1) + ":/" + m.group(2)
    return p
edited = norm(sys.argv[2])
root = norm(sys.argv[3]).rstrip("/") + "/"
# Resolve repo-relative path; FAIL-OPEN (allow, never revert) if we cannot.
if edited.lower().startswith(root.lower()):
    rel = edited[len(root):]
else:
    print("ALLOW"); sys.exit(0)
if not rel or rel.lower().startswith(".claude/goals/"):
    print("ALLOW"); sys.exit(0)
lock = g.get("scope_lock", []) or []
flex = g.get("scope_flex", []) or []
if not lock:
    print("ALLOW"); sys.exit(0)
rl = rel.lower()
def inside(paths):
    return any(rl == s.rstrip("/").lower() or rl.startswith(s.rstrip("/").lower() + "/") for s in paths)
print("ALLOW" if (inside(lock) or inside(flex)) else "REVERT\t" + rel)
PY
)"

case "$DECISION" in
  REVERT*)
    REL="$(printf '%s' "$DECISION" | cut -f2-)"
    [[ -z "$REL" ]] && ok
    # Revert a tracked file to HEAD; if it was a brand-new untracked file, remove it.
    if git -C "$REPO_ROOT" ls-files --error-unmatch "$REL" >/dev/null 2>&1; then
      git -C "$REPO_ROOT" checkout HEAD -- "$REL" 2>/dev/null || true
    else
      rm -f "$REPO_ROOT/$REL" 2>/dev/null || true
    fi
    echo "[goal-scope] Reverted out-of-scope edit: $REL — outside goal $GOAL_ID scope_lock. Add the path to scope_flex if it is legitimately needed, then redo the edit." >&2
    exit 2
    ;;
  *) ok ;;
esac

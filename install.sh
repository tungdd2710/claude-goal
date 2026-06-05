#!/usr/bin/env bash
# install.sh — install claude-goal into a project's .claude/ directory.
#
# Usage:
#   bash install.sh [TARGET_PROJECT_DIR]   # default: current directory
#
# What it does (all idempotent — safe to re-run to upgrade):
#   1. Copies scripts + statusline       -> TARGET/.claude/scripts/
#   2. Copies the skill                  -> TARGET/.claude/skills/goal/
#   3. Creates the runtime state dir     -> TARGET/.claude/goals/
#   4. Merges the 3 core hooks + statusline into TARGET/.claude/settings.json
#      (backs up the existing file first; never duplicates an already-wired hook)
#
# The optional 4th hook (scope-lock, goal-scope-check.sh) is NOT wired by this
# installer — it auto-reverts out-of-scope edits and is opt-in. See docs/SETUP.md.
#
# Prerequisites: bash, git, python3, node (node only for the statusline), and the
# Claude Code CLI. See README.md.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$PWD}"
TARGET="$(cd "$TARGET" && pwd)"

echo "claude-goal installer"
echo "  source: $SRC"
echo "  target: $TARGET"

if [[ "$SRC" == "$TARGET" ]]; then
  echo "Refusing to install into the claude-goal repo itself. Pass your project dir:" >&2
  echo "  bash install.sh /path/to/your/project" >&2
  exit 1
fi

# Warn (don't fail) if the target isn't a git repo — /goal uses git for branches,
# worktrees, and repo-root detection; without it those features degrade to CWD.
if ! git -C "$TARGET" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "  ! WARNING: $TARGET is not a git repository. /goal uses git for branch/worktree" >&2
  echo "            isolation and repo-root detection; some features will degrade. (git init recommended.)" >&2
fi

# Source-integrity preflight — fail with a CLEAR, specific message if anything the
# installer needs is missing (e.g. a partial/corrupted clone). No silent half-installs.
SCRIPTS=("$SRC/scripts/"goal-*.sh)
_missing=()
[[ ${#SCRIPTS[@]} -gt 0 && -f "${SCRIPTS[0]}" ]] || _missing+=("scripts/goal-*.sh")
[[ -f "$SRC/scripts/goal-statusline.js" ]]        || _missing+=("scripts/goal-statusline.js")
[[ -f "$SRC/skill/SKILL.md" ]]                    || _missing+=("skill/SKILL.md")
[[ -f "$SRC/settings.example.json" ]]             || _missing+=("settings.example.json")
if [[ ${#_missing[@]} -gt 0 ]]; then
  echo "ABORT: the claude-goal source is incomplete — these required files are missing from $SRC:" >&2
  for m in "${_missing[@]}"; do echo "    - $m" >&2; done
  echo "  Re-clone the repo: git clone https://github.com/tungdd2710/claude-goal.git" >&2
  exit 1
fi

CLAUDE_DIR="$TARGET/.claude"
mkdir -p "$CLAUDE_DIR/scripts" "$CLAUDE_DIR/skills/goal" "$CLAUDE_DIR/goals"

# 1. scripts + statusline
cp "${SCRIPTS[@]}" "$CLAUDE_DIR/scripts/"
cp "$SRC/scripts/goal-statusline.js" "$CLAUDE_DIR/scripts/"
find "$CLAUDE_DIR/scripts" -name 'goal-*.sh' -exec chmod +x {} + 2>/dev/null || true
echo "  ✓ scripts -> .claude/scripts/"

# 2. skill (just SKILL.md — the skill dir stays minimal; docs live in the repo)
cp "$SRC/skill/SKILL.md" "$CLAUDE_DIR/skills/goal/SKILL.md"
echo "  ✓ skill  -> .claude/skills/goal/"

# 3. runtime state dir (keep the empty dir in git; ignore the generated artifacts)
touch "$CLAUDE_DIR/goals/.gitkeep"
cat > "$CLAUDE_DIR/goals/.gitignore" <<'EOF'
# Generated goal state — do not commit.
goal-*.json
goal-*.json.bak
goal-*.json.tmp
goal-*.json.lock/
index.json
session-*.goal
logs/
worktree-*/
PAUSE
active.json*
EOF
echo "  ✓ runtime -> .claude/goals/"

# 4. merge core hooks + statusline into settings.json (backup + dedupe)
SETTINGS="$CLAUDE_DIR/settings.json"
if [[ -f "$SETTINGS" ]]; then
  # robust backup suffix: epoch, else datetime, else python, else literal
  STAMP="$(date +%s 2>/dev/null || date +%Y%m%d%H%M%S 2>/dev/null || python3 -c 'import time;print(int(time.time()))' 2>/dev/null || echo backup)"
  cp "$SETTINGS" "$SETTINGS.bak.$STAMP" && echo "  ↩ backed up existing settings.json -> settings.json.bak.$STAMP"
fi

# The python merge exits non-zero if it could NOT wire (e.g. existing settings.json
# is invalid JSON) so we can report honestly instead of falsely claiming success.
set +e
python3 - "$SETTINGS" "$SRC/settings.example.json" <<'PY'
import json, os, sys
settings_path, example_path = sys.argv[1], sys.argv[2]

cur = {}
if os.path.exists(settings_path):
    try:
        cur = json.load(open(settings_path, encoding="utf-8"))
    except Exception:
        print("  ! existing settings.json is NOT valid JSON — not modifying it.", file=sys.stderr)
        sys.exit(3)

ex = json.load(open(example_path, encoding="utf-8"))
ex_hooks = ex.get("hooks", {})
cur.setdefault("hooks", {})

def already_wired(entries, needle):
    for e in entries:
        for h in e.get("hooks", []):
            if needle and needle in (h.get("command", "") or ""):
                return True
    return False

added = []
for event, entries in ex_hooks.items():
    cur["hooks"].setdefault(event, [])
    for entry in entries:
        # identify the goal script in this entry, to dedupe on re-install
        needle = ""
        for h in entry.get("hooks", []):
            cmd = h.get("command", "") or ""
            for s in ("goal-stop-hook", "goal-scope-check", "goal-no-text-reminder", "goal-no-ask"):
                if s in cmd:
                    needle = s
        if already_wired(cur["hooks"][event], needle):
            continue
        cur["hooks"][event].append(entry)
        added.append(event + ("/" + needle if needle else ""))

if "statusLine" not in cur and "statusLine" in ex:
    cur["statusLine"] = ex["statusLine"]
    added.append("statusLine")
elif "statusLine" in cur and cur.get("statusLine") != ex.get("statusLine"):
    print("  ! you already have a different statusLine — leaving it. To use the goal "
          "statusline, set: node .claude/scripts/goal-statusline.js", file=sys.stderr)

tmp = settings_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cur, f, indent=2, ensure_ascii=False)
os.replace(tmp, settings_path)
print("  ✓ settings.json merged (" + (", ".join(added) if added else "nothing new — already wired") + ")")
PY
MERGE_RC=$?
set -e

echo ""
if [[ $MERGE_RC -ne 0 ]]; then
  echo "  ! Hooks were NOT wired automatically (settings merge rc=$MERGE_RC)."
  echo "    Manually merge the blocks from this file into $SETTINGS :"
  echo "      $SRC/settings.example.json"
  echo ""
fi
echo "Done. Next steps:"
echo "  1. Restart Claude Code (so it reloads .claude/settings.json hooks)."
echo "  2. In your project, run:  /goal <your objective>"
echo "  3. Tailor success criteria to YOUR typecheck/test/build/deploy — see:"
echo "       $SRC/docs/TAILORING.md"
echo "       (or https://github.com/tungdd2710/claude-goal/blob/main/docs/TAILORING.md )"
echo "  4. (Optional) enable the scope-lock hook — see $SRC/docs/SETUP.md"
echo ""
echo "Kill switch at any time:  touch .claude/goals/PAUSE   (delete it to resume)"

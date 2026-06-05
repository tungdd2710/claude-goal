#!/usr/bin/env bash
# install.sh — install claude-goal into a project's .claude/ directory.
#
# Usage:
#   bash install.sh [TARGET_PROJECT_DIR]   # default: current directory
#
# What it does (all idempotent — safe to re-run to upgrade):
#   1. Copies scripts + statusline    -> TARGET/.claude/scripts/
#   2. Copies the skill               -> TARGET/.claude/skills/goal/
#   3. Creates the runtime state dir  -> TARGET/.claude/goals/
#   4. Merges the 4 hooks + statusline into TARGET/.claude/settings.json
#      (backs up the existing file first; never duplicates an already-wired hook)
#
# Prerequisites: bash, git, python3, node (node only for the statusline), and the
# Claude Code CLI (`claude`). See README.md.

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

CLAUDE_DIR="$TARGET/.claude"
mkdir -p "$CLAUDE_DIR/scripts" "$CLAUDE_DIR/skills/goal" "$CLAUDE_DIR/goals"

# 1. scripts + statusline
cp "$SRC/scripts/"goal-*.sh "$CLAUDE_DIR/scripts/"
cp "$SRC/scripts/goal-statusline.js" "$CLAUDE_DIR/scripts/"
chmod +x "$CLAUDE_DIR/scripts/"goal-*.sh 2>/dev/null || true
echo "  ✓ scripts -> .claude/scripts/"

# 2. skill
cp "$SRC/skill/SKILL.md" "$CLAUDE_DIR/skills/goal/SKILL.md"
[[ -f "$SRC/docs/SETUP.md" ]] && cp "$SRC/docs/SETUP.md" "$CLAUDE_DIR/skills/goal/SETUP.md"
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
session-bindings.log
logs/
worktree-*/
PAUSE
active.json*
EOF
echo "  ✓ runtime -> .claude/goals/"

# 4. merge hooks + statusline into settings.json (backup + dedupe)
SETTINGS="$CLAUDE_DIR/settings.json"
[[ -f "$SETTINGS" ]] && cp "$SETTINGS" "$SETTINGS.bak.$(date +%s 2>/dev/null || echo backup)" && echo "  ↩ backed up existing settings.json"

python3 - "$SETTINGS" "$SRC/settings.example.json" <<'PY'
import json, os, sys
settings_path, example_path = sys.argv[1], sys.argv[2]

cur = {}
if os.path.exists(settings_path):
    try:
        cur = json.load(open(settings_path, encoding="utf-8"))
    except Exception:
        print("  ! existing settings.json is not valid JSON — leaving it; merge manually from settings.example.json", file=sys.stderr)
        sys.exit(0)

ex = json.load(open(example_path, encoding="utf-8"))
ex_hooks = ex.get("hooks", {})

cur.setdefault("hooks", {})

def already_wired(entries, needle):
    for e in entries:
        for h in e.get("hooks", []):
            if needle in (h.get("command", "") or ""):
                return True
    return False

added = []
for event, entries in ex_hooks.items():
    cur["hooks"].setdefault(event, [])
    for entry in entries:
        # identify the goal script in this entry to dedupe
        needle = ""
        for h in entry.get("hooks", []):
            cmd = h.get("command", "") or ""
            for s in ("goal-stop-hook", "goal-scope-check", "goal-no-text-reminder", "goal-no-ask"):
                if s in cmd:
                    needle = s
        if needle and already_wired(cur["hooks"][event], needle):
            continue
        cur["hooks"][event].append(entry)
        added.append(event + ("/" + needle if needle else ""))

if "statusLine" not in cur and "statusLine" in ex:
    cur["statusLine"] = ex["statusLine"]
    added.append("statusLine")

tmp = settings_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cur, f, indent=2, ensure_ascii=False)
os.replace(tmp, settings_path)
print("  ✓ settings.json merged (" + (", ".join(added) if added else "nothing new — already wired") + ")")
PY

echo ""
echo "Done. Next steps:"
echo "  1. Restart Claude Code (so it reloads .claude/settings.json hooks)."
echo "  2. In your project, run:  /goal <your objective>"
echo "  3. Read docs/TAILORING.md to point the success criteria at YOUR typecheck/test/build/deploy."
echo ""
echo "Kill switch at any time:  touch .claude/goals/PAUSE   (delete it to resume)"

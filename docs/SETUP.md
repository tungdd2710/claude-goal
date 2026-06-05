# Setup & quick reference

This is the hands-on setup/reference for `claude-goal`. For *what it is and why*, see the
[README](../README.md); for *how the engine works*, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Install

```bash
git clone https://github.com/tungdd2710/claude-goal.git
cd claude-goal
bash install.sh /path/to/your/project    # omit the path to install into the current dir
```

`install.sh` is idempotent (safe to re-run to upgrade). It:

1. copies the scripts → `your-project/.claude/scripts/`
2. copies the skill → `your-project/.claude/skills/goal/SKILL.md`
3. creates the runtime dir → `your-project/.claude/goals/` (with a `.gitignore` for generated state)
4. merges the **three core hooks + status line** into `your-project/.claude/settings.json`
   (backs up any existing file; never double-wires)

Then **restart Claude Code** so it reloads the hooks. Verify with `/goal list` (should say "no goals").

## What gets wired

| Event | Script | Role |
|---|---|---|
| `Stop` | `goal-stop-hook.sh` | The autonomy engine — blocks the turn-end and feeds the next iteration back in-session. Claim-scoped, fail-open. |
| `PreToolUse` (matcher `AskUserQuestion`) | `goal-no-ask.sh` | Blocks the agent from asking you questions mid-goal. |
| `PostToolUse` (matcher `*`) | `goal-no-text-reminder.sh` | Nudges the agent to keep calling tools instead of writing prose. |
| `statusLine` | `goal-statusline.js` | Shows the goal this session owns + iteration count. |

> Matchers match the **tool name only** (`AskUserQuestion`, `Edit|Write`, `*`). Argument-glob matchers
> like `Edit:*` or `Bash:*rm*` never fire — that's why filtering happens inside the scripts.

## Manual wiring (if you don't use install.sh)

1. Copy `scripts/*` into `your-project/.claude/scripts/` and `skill/SKILL.md` into
   `your-project/.claude/skills/goal/`.
2. Merge the `hooks` + `statusLine` blocks from [`settings.example.json`](../settings.example.json)
   into `your-project/.claude/settings.json`.
3. Restart Claude Code.

## Optional: enable the scope-lock hook (opt-in)

`goal-scope-check.sh` auto-**reverts** any edit outside the active goal's `scope_lock` + `scope_flex`
(even edits from fanned-out subagents). It's powerful but a too-narrow scope can discard real work, so
it is **not** wired by default. To enable it, add this PostToolUse entry to your `.claude/settings.json`
(alongside the `*` reminder hook):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "cd \"${CLAUDE_PROJECT_DIR:-.}\" 2>/dev/null; bash .claude/scripts/goal-scope-check.sh 2>/dev/null || true" }
        ]
      }
    ]
  }
}
```

It is claim-scoped + fail-open, so a session that isn't running a goal is never touched. Keep
`scope_flex` accurate to avoid reverting legitimate edits.

## Kill switch & disable

- **Pause all goals instantly:** `touch .claude/goals/PAUSE` (delete the file to resume). Every
  session's Stop hook honors `PAUSE` before any goal logic.
- **Disable the engine entirely:** remove the `Stop` block from `.claude/settings.json`.

> Do NOT wire `goal-continue.sh` as a Stop hook — it spawns `claude -p`, whose child fires its own Stop
> hooks → runaway recursion. It is the **cron / manual cross-session resume** target only.

## Cross-session resume cron (multi-day goals)

Schedule once, from inside Claude Code, when you start a long goal:

```
CronCreate(cron: "17 */2 * * *", durable: true, recurring: true,
  prompt: "/goal resume -- check .claude/goals/index.json for all active goals, resume each")
```

It only acts if a goal is unclaimed/unfinished. Delete it when the goal completes. Within a running
session you don't need it — the Stop hook drives the loop.

## Usage

### Minimal (walk-away)
```
/goal Fix all N+1 queries in the dashboard
```
The agent surveys the codebase, derives criteria, sets scope, does a probe fix, then loops.

### Explicit (headless / overrides)
```bash
bash .claude/scripts/goal-init.sh \
  --objective "Add auth tests to 80% coverage" \
  --scope "src/lib/auth/" \
  --check "npx vitest run src/lib/auth/" --label "Auth tests pass" \
  --max 5
bash .claude/scripts/goal-loop.sh
```

### Loop runner options
- `--max N` — override the initial iteration budget (auto-extends anyway)
- `--model MODEL` — model id (default: `claude-sonnet-4-6`; or set `GOAL_MODEL`)
- `--max-turns N` — tool calls per iteration (default: 30)

See [TAILORING.md](TAILORING.md) to point criteria, the coverage gate, and deploy verification at your
own stack.

## How reflection works

Each iteration ends with a structured 3-field JSON written via `goal-update-state.sh --reflect`:
```json
{
  "outcome_reason": "Why this iteration's outcome was what it was",
  "next_focus": {"criterion": "label", "files": ["specific/paths"]},
  "research_files": ["files/to/read/before/next/iteration"]
}
```
The next iteration reads this to know what to do. If `research_files` is non-empty, the agent reads
those files before editing. This replaces rigid multi-iteration plans that rot — each iteration plans
only the next one.

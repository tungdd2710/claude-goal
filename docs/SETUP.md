# /goal Setup Guide (for goal-skill v0.10.0)

## What changed from v0.2

- **Walk-away mode**: just provide a goal string. Agent derives criteria, scope, and budget.
- **Two-mode iterations**: iter 1 = UNDERSTAND (research + probe fix). Iter 2+ = EXECUTE.
- **Structured reflections**: each iteration ends with 3-field JSON that guides the next.
- **Auto-criteria**: agent discovers what verification infra exists and generates criteria from that.

## Installation

### Scripts (in `.claude/scripts/`) + hooks (in `.claude/hooks/`)
- `goal-validate.sh` — JSON + schema validation
- `goal-update-state.sh` — atomic state mutation (lockdir + backup); `--update-metrics`, criterion linter, numeric outcome
- `goal-check-criterion.sh` — structured criterion runner (timeout + numeric `value` extraction)
- `goal-resolve.sh` / `goal-list.sh` / `goal-init.sh` — resolve / list / create goals
- `goal-loop.sh` — standalone headless loop runner (budget auto-extends; sets `GOAL_DRIVER_ACTIVE`)
- `goal-continue.sh` — CRON / manual cross-session resume (NOT a Stop hook)
- `goal-no-text-reminder.sh` (hooks/) — PostToolUse soft nudge **[WIRED]**
- `goal-stop-hook.sh` (hooks/) — Stop-hook autonomy engine: claim-scoped, fail-open **[WIRED]**

### Hooks

**Already wired in `.claude/settings.json`** (no action needed):
- **PostToolUse** → `goal-no-text-reminder.sh` — soft "don't write text, call a tool" nudge while a goal is active.
- **Stop** → `goal-stop-hook.sh` — the autonomy engine. Claim-scoped + fail-open: blocks the stop and
  continues IN-SESSION only for the session that wrote `.claude/goals/session-$CLAUDE_CODE_SESSION_ID.goal`,
  and only while that goal is `active`. Guards: `stop_hook_active` (anti-runaway), `PAUSE` sentinel,
  `GOAL_DRIVER_ACTIVE` (goal-loop.sh sets it so its `-p` children don't double-drive).

> ⚠️ Do NOT wire `goal-continue.sh` as a Stop hook — it spawns `claude -p`, whose child fires its own
> Stop hooks → runaway recursion. `goal-continue.sh` is for **cron / manual cross-session resume** only.

**Optional opt-in** — add to `.claude/settings.local.json` for scope-lock auto-revert (reverts any edit
outside `scope_lock`/`scope_flex`; a too-narrow scope silently discards real work, so use deliberately):
```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Edit:*|Write:*",
      "hooks": [{"type": "command", "command": "bash .claude/scripts/goal-scope-check.sh"}]
    }]
  }
}
```

**Cross-session resume cron** (for multi-day goals — schedule once when you start one):
```
CronCreate(cron: "17 */2 * * *", durable: true, recurring: true,
  prompt: "/goal resume -- check .claude/goals/index.json for all active goals, resume each")
```

To pause everything: `touch .claude/goals/PAUSE` (delete to resume). To disable the engine entirely:
remove the `Stop` block from `.claude/settings.json`.

## Usage

### Minimal (walk-away)
```
/goal Fix all N+1 queries in the dashboard
```
Agent surveys codebase, generates criteria, sets scope, does probe fix, then loops.

### Explicit (with overrides)
```bash
bash .claude/scripts/goal-init.sh \
  --objective "Add auth tests to 80% coverage" \
  --scope "src/lib/auth/" \
  --check "npx vitest run src/lib/auth/" --label "Auth tests pass" \
  --max 5
bash .claude/scripts/goal-loop.sh
```

### Loop runner options
- `--max N` — override iteration budget
- `--model MODEL` — model selection (default: claude-sonnet-4-6)
- `--max-turns N` — tool calls per iteration (default: 30)

## How Reflection Works

Each iteration ends with a structured 3-field JSON:
```json
{
  "outcome_reason": "Why this iteration's outcome was what it was",
  "next_focus": {"criterion": "label", "files": ["specific/paths"]},
  "research_files": ["files/to/read/before/next/iteration"]
}
```

The next iteration reads this to know what to do. If `research_files` is non-empty,
the agent reads those files before making changes. This replaces the rigid
multi-iteration planning that rots — each iteration plans only the next one.

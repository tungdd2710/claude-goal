# Architecture

How `claude-goal` actually works, end to end. Read this if you want to understand, debug, or extend the
engine. The skill body (`skill/SKILL.md`) is the agent-facing contract; this doc is the
implementer-facing explanation.

---

## 1. The big picture

```
  /goal <objective>
        │
        ▼
  goal-init.sh ──► writes goal-<id>.json + index.json + session-<id>.goal claim
        │                       (optionally a git worktree on branch goal/<slug>)
        ▼
  ITERATION 1 (UNDERSTAND): survey code → derive criteria/scope/budget → probe-fix → reflect
        │
        ▼
  ITERATION 2..N (EXECUTE): orient → execute → verify → reflect → commit ── loops ──┐
        ▲                                                                            │
        └──────────────── the Stop hook refuses the turn-end and re-injects ◄────────┘
                          the next iteration into the SAME session
```

Three things make the loop *continuous*:

1. **The `Stop` hook** (`goal-stop-hook.sh`) — refuses voluntary turn-ends in-session.
2. **The `context_summary`** — refreshed every iteration so the loop survives auto-compaction.
3. **The optional cron** (`goal-continue.sh`) — restarts an unfinished goal after the session dies.

Plus three reinforcing hooks — no-ask and no-narration (wired by default) and scope-lock (opt-in) — that
stop the agent from drifting out of the loop in other ways.

---

## 2. Claude Code hook semantics (what the engine relies on)

The engine is built on Claude Code's hook system. The behaviors it depends on (verified against the
Claude Code hooks docs):

- **`Stop` hook** can *block* a turn-end by emitting, on **exit 0**, JSON:
  `{"decision":"block","reason":"<text>"}`. The `reason` is fed back to the model as the instruction
  for what to do instead of stopping. (For `Stop`, the continuation instruction must ride in `reason` —
  `additionalContext` is **not** honored for the `Stop` event, only for `SessionStart` / `UserPromptSubmit`
  / `PostToolUse` / etc.)
- **`PreToolUse` hook** can *block* a tool call by exiting **2** (exit 1 does **not** block). The
  no-ask hook uses this to veto `AskUserQuestion`.
- **`PostToolUse` hook** cannot block; exit 2 only surfaces stderr to the model. The no-narration nudge
  and scope-lock use `PostToolUse` — the nudge injects `additionalContext`; the scope-lock reverts the
  file itself (a side effect) and surfaces a message.
- **Matchers match the tool *name* only** (`Edit|Write`, `Bash`, `*`). Argument patterns like
  `Bash:*rm -rf*` do **not** match — argument filtering must be done *inside* the hook script.
- **Anti-runaway:** Claude Code overrides a `Stop` hook after roughly 8 consecutive blocks
  (configurable via `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`). Past that boundary, the cron resumes the goal.

---

## 3. The Stop hook — the autonomy engine

`goal-stop-hook.sh` is the heart of the system. Its design rules:

- **Pure block, never spawn.** It only emits a `{"decision":"block",…}` JSON. It never runs
  `claude -p`, because a spawned child fires its *own* Stop hooks → infinite recursion. (That spawning
  behavior lives in `goal-continue.sh`, which is the cron path, never wired as a Stop hook.)
- **Claim-scoped.** It reads the `session_id` from the hook's stdin JSON and only continues a session
  that wrote `.claude/goals/session-<session_id>.goal` pointing at a goal whose `status == "active"`.
  A session that never started a goal has no claim → it's never blocked.
- **Fail-open.** Every uncertain path → `allow()` (exit 0, no output, i.e. let the stop happen):
  `GOAL_DRIVER_ACTIVE` is set (the head-less loop is driving) · a `PAUSE` file exists · no claim files
  at all · no claim for this session · the claimed goal isn't `active` · any parse/read error. A Stop
  hook that failed *closed* would wedge every session in the repo, so the default is always ALLOW.

When it *does* block, it builds the full next-iteration brief (objective, state-file path,
`context_summary`, the last reflection's focus, the exact criterion commands to run, the banned
`approach_tag`s from `negative_knowledge`, and the 4-step EXECUTE protocol) and ships it inside
`reason`.

```
INPUT (stdin JSON from Claude Code)  ──►  goal-stop-hook.sh
   guards (driver / PAUSE / claim / active?) ── any fail ─►  exit 0, no output  (ALLOW stop)
                       │ all pass
                       ▼
   build next-iteration brief from goal-<id>.json
                       ▼
   print {"decision":"block","reason":"<brief>"}  ──►  Claude Code re-prompts the SAME session
```

---

## 4. The other three hooks

| Hook | Event / matcher | Mechanism |
|---|---|---|
| `goal-no-ask.sh` | `PreToolUse` / `AskUserQuestion` | If this session is bound to an active goal, **exit 2** → the `AskUserQuestion` is blocked and the agent is told to decide itself. Fail-open (exit 0) otherwise. A `PAUSE` file lets questions through. |
| `goal-no-text-reminder.sh` | `PostToolUse` / `*` | If this session owns an active goal, emit `additionalContext` reminding the agent its next action must be a tool call, not prose. Pure nudge — cannot block. Silent for non-goal sessions. |
| `goal-scope-check.sh` | `PostToolUse` / `Edit\|Write` | If this session owns an active goal and the just-edited file (`tool_input.file_path`) is outside `scope_lock`+`scope_flex`, revert it (`git checkout HEAD --` for tracked, `rm` for new) and **exit 2** to surface why. Normalizes Windows/Git-Bash paths. Fail-open. |

All four hooks share the same claim-scoped + fail-open spine. `install.sh` wires the first three by
default; the scope-lock hook is **opt-in** (enable it per [SETUP.md](SETUP.md)). A session that isn't
running a goal is invisible to all of them.

---

## 5. State files

```
.claude/goals/
├── index.json                 # registry of every goal {id, objective, status, branch, created_at}
├── goal-<id>.json             # full state for one goal
├── goal-<id>.json.bak         # atomic backup (restored automatically if the live file corrupts)
├── goal-<id>.json.lock/       # lockdir (mkdir is atomic) for mutual exclusion on writes
├── session-<session_id>.goal  # claim: which goal THIS CLI session owns (the hooks key off this)
├── logs/                      # head-less loop logs
└── worktree-<id>/             # git worktree for a goal (created when other goals are active)
```

### `goal-<id>.json` (the important fields)

| Field | Meaning |
|---|---|
| `objective` | The goal string. **Immutable** after creation. |
| `success_criteria[]` | `{check, label, auto, target?, direction?}`. **Frozen** after iteration 1. |
| `scope_lock[]` / `scope_flex[]` | Directories the goal may edit / its dependency dirs. |
| `coverage` | `{covered_cmd, total_cmd}` — the live-recomputed gate for "all/every" goals. |
| `status` | `active` / `paused` / `complete` / `blocked` / `impossible` / `cleared`. |
| `budget` | `{max_iterations, used}` — a progress counter, **auto-extends**, never a hard stop. |
| `iteration_log[]` | Per-iteration record: approach, tag, changes, criteria before/after, computed `outcome`. |
| `negative_knowledge[]` | Append-only banned approaches with the *mechanism* of failure. |
| `reflections[]` | Per-iteration `{outcome_reason, next_focus, research_files, brainstorm_candidates?}`. |
| `context_summary` | 3-sentence "where I am" — the compaction-survival memory. |
| `metrics` | Derived counters for the completion report. |

All mutations go through `goal-update-state.sh` (never raw-write the file).

---

## 6. `goal-update-state.sh` — the guards

This script is where "honest completion" is enforced. Every mutation: acquire lockdir → validate
current state (restore from `.bak` if corrupt) → back up → apply → re-validate → atomic rename → sync
`index.json`. The guards:

- **Completion guard.** `--status complete` is refused unless the *latest* `iteration_log` entry's
  `criteria_after` passes **every** criterion (threshold-aware for numeric criteria). You can't declare
  done while a check is failing.
- **Coverage gate.** If the objective says all/every/entire/fix-all/comprehensive, completion also
  requires a coverage gate (`--set-coverage COVERED_CMD TOTAL_CMD`) and re-runs **both commands live**
  at completion; `covered < total` → blocked. This is what stops "make all X work" from being declared
  done on a subset — the denominator is recomputed from the codebase, not stored.
- **Criteria freeze.** `--set-criteria` is rejected once `budget.used >= 1` and real criteria exist —
  you can't move the goalposts mid-goal to make a failing run "pass".
- **Criteria linter.** Rejects file-existence-only checks (`test -f …`) and warns on unauthenticated
  status-code curls — because "the file exists" and "the server booted" don't prove the feature works.
- **Cross-CLI guard.** A terminal status (`complete`/`blocked`/`impossible`) is refused while a
  *different* live session (claim < 4h old) owns the goal — one CLI can't stomp another's goal.
- **Mechanical outcome.** The iteration outcome (`progress`/`regression`/`no_change`) is **computed**
  from criteria before/after, not supplied by the agent. Numeric criteria with a `target` count a climb
  toward target as `progress` even before it passes — so a metric plateau reads as exploration, not
  failure.

---

## 7. Three ways the loop is driven

| Driver | When | Self-continues? |
|---|---|---|
| **In-session Stop hook** | Normal interactive `/goal` use | Yes — blocks turn-ends until complete/blocked/paused, or the ~8-block cap. |
| **`goal-loop.sh`** | Head-less terminal runner | The bash `while` loop drives; each iteration is a `claude -p` with `GOAL_DRIVER_ACTIVE=1` set so the child's Stop hook *allows* its stop (the loop, not the hook, is the driver). |
| **`goal-continue.sh`** | Cron / manual cross-session resume | Spawns one fresh `claude -p` (no `GOAL_DRIVER_ACTIVE`) so the spawned session then self-continues via its Stop hook. Never wire this as a Stop hook (recursion). |

`SPAWNED_SESSION=true` is exported by both runners so any conditional skills they invoke take their
non-interactive path.

---

## 8. The iteration protocol

**Iteration 1 — UNDERSTAND:** survey the code; derive `success_criteria` (typecheck if present; tests
if present; one structural grep; **at least one user-facing check**); set `scope_lock`/`scope_flex` and
a budget (`ceil(file_count/5)+1`, cap 10); register a coverage gate if the objective says "all"; do one
probe fix on a median-complexity file; reflect.

**Iterations 2..N — EXECUTE:** orient (run all criteria → `criteria_before`; if all pass, run the
Completion Audit then mark complete); execute (follow the last reflection's `next_focus`; fan out if
≥5 independent units; pick a non-banned `approach_tag`); verify (run all criteria → `criteria_after`;
update state); on `no_change`/`regression`, do Failure Analysis (diagnose the mechanism → write
`negative_knowledge` → brainstorm 3 structurally-different approaches → pick the highest-leverage one);
reflect + refresh `context_summary` + `--update-metrics`; commit; **immediately** start the next
iteration.

Blocking happens only when the **same** `approach_tag` fails twice consecutively (a real retry), or
every reasonable approach is in `negative_knowledge`. Different tags at the same metric = plateau
*exploration*, which continues.

---

## 9. Multi-goal & worktrees

Each goal after the first gets a git worktree (`.claude/goals/worktree-<id>`) on its own `goal/<slug>`
branch, so concurrent goals never share a working tree. `goal-init.sh` rejects a new goal whose
`scope_lock` overlaps an active goal's (two goals can't edit the same directories). Scripts take an
optional `--goal-id`; without it, `goal-resolve.sh` auto-detects (single active goal, or match by the
current worktree).

> ⚠️ Concurrency is resource-heavy — see [PRINCIPLES.md](PRINCIPLES.md) → *Concurrency has a cost*.
> One `touch .claude/goals/PAUSE` halts all goals across all sessions.

---

## 10. Script reference

| Script | Role |
|---|---|
| `goal-init.sh` | Create goal state + index entry + (optional) worktree. |
| `goal-loop.sh` | Head-less iteration runner (budget auto-extends; sets `GOAL_DRIVER_ACTIVE`). |
| `goal-continue.sh` | Cron / manual cross-session resume (spawns one `claude -p`). |
| `goal-update-state.sh` | All state mutation + the guards in §6. |
| `goal-check-criterion.sh` | Run one criterion → JSON `{pass, value, exit_code, …}` (60s timeout, danger-block). |
| `goal-resolve.sh` | Resolve `--goal-id` (or auto-detect) → state-file path; migrates legacy `active.json`. |
| `goal-list.sh` | Tabular list of all goals. |
| `goal-validate.sh` | Validate state JSON + schema (exit codes 0/1/2/3). |
| `goal-stop-hook.sh` | **Stop hook** — the autonomy engine (§3). |
| `goal-no-ask.sh` | **PreToolUse** — block `AskUserQuestion` (§4). |
| `goal-no-text-reminder.sh` | **PostToolUse** — anti-narration nudge (§4). |
| `goal-scope-check.sh` | **PostToolUse** — scope-lock revert (§4). |
| `goal-statusline.js` | Status line showing this session's goal + iteration. |

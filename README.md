# claude-goal

**Set a goal. Walk away. Come back when it's done.**

`claude-goal` is a [Claude Code](https://claude.com/claude-code) skill + a set of hooks that turn the
agent into a *persistent, autonomous goal-runner*. You give it one objective in plain English; it
derives its own success criteria, scope, and plan, then **iterates continuously — without stopping to
ask you anything — until the goal is genuinely met** (or every reasonable approach is exhausted).

It is built around one hard idea: **the agent should never end its turn while a goal is unfinished.**
Claude's strong default is to do a chunk of work and then stop to report or ask "want me to continue?".
For a walk-away task that default is the enemy. `claude-goal` removes it with a `Stop` hook that
refuses the turn-end and feeds the next iteration back into the same session — surviving
context auto-compaction, and resuming across days via an optional cron.

```
/goal Fix all N+1 queries in the dashboard
```

That's it. No flags required. It surveys the code, writes criteria (typecheck clean, a structural
grep, an authenticated user-facing check), sets a coverage gate (because you said "all"), does a probe
fix, then loops — fixing, verifying, committing per unit — until **every** N+1 site is closed and all
criteria pass.

---

## Table of contents

- [What it can do](#what-it-can-do)
- [Effects & trade-offs — read this before wiring it in](#effects--trade-offs--read-this-before-wiring-it-in)
- [How it works (the engine)](#how-it-works-the-engine)
- [Install](#install)
- [Commands](#commands)
- [The hooks](#the-hooks)
- [Tailoring it to your project & deploy system](#tailoring-it-to-your-project--deploy-system)
- [The rules & the memory it relies on](#the-rules--the-memory-it-relies-on)
- [Safety & the kill switch](#safety--the-kill-switch)
- [Maturity, evaluation & limitations](#maturity-evaluation--limitations)
- [Requirements](#requirements)
- [Repository layout](#repository-layout)
- [FAQ](#faq)
- [Credits & license](#credits--license)

---

## What it can do

| Capability | What it means |
|---|---|
| **Walk-away autonomy** | One objective string in; the agent derives criteria, scope, budget, and a plan. No back-and-forth. |
| **Never-stop loop** | A `Stop` hook blocks voluntary turn-ends and injects the next iteration in-session — so it keeps going on its own. |
| **Never-ask contract** | A `PreToolUse` hook blocks `AskUserQuestion` while a goal is active. The agent decides from the plan/specs/memory instead of pausing for you. |
| **Survives auto-compaction** | A 3-sentence `context_summary` is refreshed every iteration, so when Claude Code compacts the conversation the loop orients from state and continues. |
| **Cross-session resume** | An optional durable cron resumes any unfinished goal after you close the terminal or the machine sleeps. |
| **Honest completion** | It can't mark a goal "complete" unless the *latest* criteria run actually passes — and for "fix all / every / entire" goals, a **coverage gate** recomputes the live denominator so it can't declare victory on a subset. |
| **Numeric-target goals** | Criteria can carry a `target` + `direction` (e.g. `accuracy ≥ 0.90`); a metric climbing toward target counts as *progress* even before it passes, so plateaus don't trip the block rule. |
| **Learns from failure** | Every failed approach is written to `negative_knowledge` with the *mechanism* of failure; the same approach can't be retried, and each failure triggers a diagnose → brainstorm-3 → pick-highest-leverage step. |
| **Parallel fan-out** | When an iteration touches ≥5 independent units, it fans the work out to many subagents (via the Workflow tool or parallel Agents in worktrees), then converges and verifies. |
| **Skill routing** | It orchestrates rather than hand-rolls: it routes subtasks to whatever specialized skills you have installed, using a three-tier safety model so an interactive skill can never freeze the loop. |
| **Multi-goal** | Several goals run concurrently, each in its own git worktree with non-overlapping scope, its own criteria/budget/knowledge. |
| **Scope lock** | An optional `PostToolUse` hook reverts edits that stray outside the goal's declared scope — even edits made by fanned-out subagents. |
| **Self-tracking status line** | The footer shows the goal this session owns and the iteration count. |

### Good fits

Large mechanical sweeps ("migrate every component to the new token", "add the missing tenant filter
to all 40 endpoints"), long benchmark/optimization climbs toward a numeric target, comprehensive
audits-and-fixes, test-coverage pushes — anything where the work is well-defined, verifiable, and
*long enough that babysitting it is the real cost.*

### Poor fits

Vague creative work with no verifiable "done", irreversible one-shot operations, or anything where you
actually *want* to be consulted at each step. For those, use Claude Code normally.

---

## Effects & trade-offs — read this before wiring it in

This skill deliberately changes the agent's behavior at the session level. Know what you're turning on.

- **It changes *stopping* behavior for the whole session.** Once a goal is active and claimed by a
  session, the `Stop` hook will keep refusing that session's turn-ends. This is the point — but it
  means the agent won't naturally hand control back until the goal completes, blocks, or you pause it.
  *(The hook is claim-scoped and fail-open: sessions that didn't start a goal are never affected, and
  any uncertainty defaults to allowing the stop. See [the engine](#how-it-works-the-engine).)*

- **It will spend tokens — potentially a lot.** There is **no budget cap** by design; the budget
  counter auto-extends rather than stopping the loop. A goal can run for many iterations across hours.
  Fan-out multiplies this (many subagents at once). Treat a `/goal` like starting a long job, not
  sending a message.

- **It commits on its own.** The loop commits per unit of work (`goal(<id>): iteration N — …`). It
  works on a `goal/<slug>` branch (and an isolated worktree when other goals are active), so it
  doesn't clobber your working tree — but it *is* writing code and git history autonomously.

- **It won't ask you mid-goal.** That's the contract. The only sanctioned pause is a genuinely
  irreversible + ambiguous action (a prod deploy, a schema migration, a data deletion). Everything
  reversible, it just does. If you need a decision made a certain way, put it in the objective.

- **Concurrency has a real cost.** Running several autonomous `/goal` CLIs at once on one machine
  stacks RAM/CPU (each spins typecheck/test/bench work) and can lock a laptop. The brake is one file:
  `touch .claude/goals/PAUSE`. Prefer one goal at a time on modest hardware.

- **Verification is only as good as your criteria.** The loop is honest about *its* criteria — but if
  your criteria are weak (e.g. "server returns 200"), "complete" will be weak too. The skill bans the
  worst criteria patterns and *requires* at least one user-facing check, but you should still point the
  criteria at things that prove real success on **your** stack (see
  [Tailoring](#tailoring-it-to-your-project--deploy-system)).

In short: you trade *control at each step* for *not having to be there.* That's a great trade for the
right task and a bad one for the wrong task.

> For a full, evidence-labelled assessment — what's **verified** vs **inherited design claim**, every
> failure mode, and how to evaluate it on your own setup — see **[docs/EVALUATION.md](docs/EVALUATION.md)**.

---

## How it works (the engine)

The whole system is four hooks (three wired by default, scope-lock opt-in), ~13 small bash/python scripts, and a JSON state file per goal. The
load-bearing piece is the **`Stop` hook** (`goal-stop-hook.sh`):

1. When a session's turn is about to end, Claude Code runs the `Stop` hook.
2. The hook checks whether *this* session has a claim file (`.claude/goals/session-<id>.goal`)
   pointing at a goal whose `status == "active"`.
3. If so, it returns `{"decision":"block","reason":"…"}` — which tells Claude Code **not** to stop, and
   feeds the entire next-iteration instruction (orient → execute → verify → reflect) back into the
   *same* session, with context intact. No subprocess, no new conversation.
4. On **any** uncertainty — no claim, goal not active, parse error, a `PAUSE` file present — it exits 0
   with no output, i.e. it **allows** the stop. A `Stop` hook that failed *closed* would wedge every
   session in the repo; this one fails *open*.

Two boundaries the in-session loop can't cross by itself — Claude Code overrides a `Stop` hook after
~8 consecutive blocks, and auto-compaction — are bridged by the `context_summary` (for compaction) and
the optional resume **cron** (for session death). Inside those boundaries the agent simply never ends
its turn while the goal is active.

Two more hooks reinforce it by default — a `PreToolUse` hook that blocks `AskUserQuestion` (never-ask)
and a `PostToolUse` "nudge" that keeps the agent making tool calls instead of writing prose. A fourth,
opt-in `PostToolUse` scope-lock hook reverts out-of-scope edits when you enable it.

> Full mechanics — state-file schema, the completion/coverage guards in `goal-update-state.sh`, the
> Stop-hook output schema, the iteration protocol — are in **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**
> and in the skill itself (**[skill/SKILL.md](skill/SKILL.md)**).

---

## Install

**Prerequisites:** `bash`, `git`, `python3`, `node` (for the status line), and the Claude Code CLI.

```bash
git clone https://github.com/tungdd2710/claude-goal.git
cd claude-goal
bash install.sh /path/to/your/project     # omit the path to install into the current dir
```

The installer copies the scripts to `your-project/.claude/scripts/`, the skill to
`your-project/.claude/skills/goal/`, creates the runtime dir `your-project/.claude/goals/`, and
**merges** the three core hooks + status line into `your-project/.claude/settings.json` (backing up any
existing file and never double-wiring). Then **restart Claude Code** so it reloads the hooks.

Prefer to wire it by hand? Copy `scripts/` into `.claude/scripts/`, copy `skill/SKILL.md` into
`.claude/skills/goal/`, and merge `settings.example.json` into your `.claude/settings.json` yourself.

---

## Commands

| Command | Does |
|---|---|
| `/goal <objective>` | Create a goal and start iterating immediately. |
| `/goal <objective> --scope <dir> --max <n>` | Same, with explicit scope and an initial budget. |
| `/goal list` | Show all goals (active / complete / blocked / paused). |
| `/goal status [id]` | Show state + run the criteria checks for a goal. |
| `/goal resume [id]` | Resume a goal (auto-picks the sole unclaimed active goal if no id). |
| `/goal pause [id]` | Pause a goal (saves state). |
| `/goal clear [id]` | Abandon a goal (archives state, removes from the index). |
| `/goal check [id]` | Run criteria once without iterating. |

You can also drive it head-less without the chat UI:

```bash
bash .claude/scripts/goal-init.sh --objective "Add auth tests to 80% coverage" \
  --scope "src/lib/auth/" --check "npx vitest run src/lib/auth/" --label "Auth tests pass" --max 5
bash .claude/scripts/goal-loop.sh        # runs the iteration loop in the terminal
```

---

## The hooks

| Hook | Event | File | Effect |
|---|---|---|---|
| **Autonomy engine** | `Stop` | `goal-stop-hook.sh` | Blocks the turn-end and injects the next iteration in-session. Claim-scoped, fail-open. **This is the engine.** |
| **No-ask** | `PreToolUse` (`AskUserQuestion`) | `goal-no-ask.sh` | Blocks the agent from asking you questions while a goal bound to this session is active. |
| **No-narration nudge** | `PostToolUse` (`*`) | `goal-no-text-reminder.sh` | Soft reminder after every tool call: don't write prose, call the next tool. Kills the "summary paragraph" stop-drift. |
| **Scope lock** *(opt-in)* | `PostToolUse` (`Edit\|Write`) | `goal-scope-check.sh` | Reverts the just-edited file if it's outside the goal's `scope_lock` + `scope_flex`. Claim-scoped, fail-open. **Not wired by default** — see [docs/SETUP.md](docs/SETUP.md). |

All four are **claim-scoped** (they only act for the session that started a goal) and **fail-open**
(any error or uncertainty → do nothing), so they are safe to leave wired permanently — a normal
session that never runs a goal is never affected. `install.sh` wires the first three by default; the
scope-lock hook is **opt-in** (auto-revert is powerful, but a too-narrow scope can discard work) — see
[docs/SETUP.md](docs/SETUP.md) to enable it.

---

## Tailoring it to your project & deploy system

The skill ships with sensible *defaults*, but the criteria, gates, model, and especially the
**deploy-verification** steps should point at **your** stack. This is the single most important thing
to customize, and it has its own guide:

➡️ **[docs/TAILORING.md](docs/TAILORING.md)** — how to set:
- success criteria for your typechecker / test runner / linter / build;
- a **coverage gate** with your live denominator command;
- the model (`GOAL_MODEL`) and per-iteration turn budget;
- skill-routing / gates onto whatever skills you actually have installed;
- **deploy verification** — the "act as a user / curl prod health / restart the process / exercise the
  endpoint" steps that turn "deployed" into "verified running", mapped to your hosting (SSH, PM2,
  Docker, serverless, etc.);
- long bench/GPU runs with the early-kill gate.

---

## The rules & the memory it relies on

`claude-goal` is more than scripts — it encodes an *operating philosophy*. The Stop-hook literally
tells the agent to "decide from the plan / locked specs / **memory**." Two companion docs make that
real and are part of this release:

- **[docs/PRINCIPLES.md](docs/PRINCIPLES.md)** — the de-branded operating *rules* the loop assumes:
  never-stop / never-ask, build-don't-survey, verify-before-claiming, failures-are-data,
  row-counts-aren't-quality, rules-as-code, and more. These are *why* the loop behaves the way it does.
- **[memory/](memory/)** — a small starter pack of skill-related **memory** files (the same
  file-per-fact convention Claude Code memory uses), de-branded, that pre-load the agent with the
  goal-runner discipline. **[docs/MEMORY.md](docs/MEMORY.md)** explains the convention and how to add
  your own.

---

## Safety & the kill switch

- **Pause everything instantly:** `touch .claude/goals/PAUSE` — every session's Stop hook sees the file
  and allows the stop *before* any goal logic runs. Delete the file to resume. (It stops the *next*
  continuation, not a tool call already in flight.)
- **Disable the engine entirely:** remove the `Stop` block from `.claude/settings.json`.
- **It won't terminate another live CLI's goal**, won't change a goal's immutable objective, and
  freezes criteria after iteration 1 (so it can't "move the goalposts" to declare victory).
- **It won't mark complete with criteria failing** or with a coverage gate unmet.
- Criterion commands run with a 60s timeout and a **best-effort** dangerous-pattern block (`rm -rf`, `mkfs`, `dd`, fork-bombs, `sudo`, force-push, …). This is **not a security boundary**: criteria you set run arbitrary shell under your account, so only put commands you trust into a goal's criteria.

---

## Maturity, evaluation & limitations

`claude-goal` is an **extraction** from a private production codebase where the engine ran real
multi-hour goals — not a from-scratch release. Be honest with yourself about what that means:

- **Verified here:** the scripts/hooks/install/guards work at the unit level (they parse; the installer
  wires correctly; the completion/coverage guards fire; the danger filter blocks footguns; the
  statusline + state mutations work). Reproduction commands are in [docs/EVALUATION.md](docs/EVALUATION.md).
- **Not benchmarked here:** there is **no success-rate data** for "given N real objectives, M completed
  correctly unattended" in this de-branded packaging. Treat early runs as experiments.
- **Biggest dependency:** the never-stop engine relies on a claim file matching Claude Code's session id
  (`CLAUDE_CODE_SESSION_ID`). `goal-init.sh` writes it automatically, but **verify on your setup** that
  `.claude/goals/session-*.goal` appears after `/goal`.
- **"Complete" is only as honest as your criteria**, there is **no budget cap** (real cost), it
  **commits autonomously**, and the criterion sandbox is **not a security boundary**.

➡️ Read **[docs/EVALUATION.md](docs/EVALUATION.md)** before trusting it with a long unattended run — it
covers every limitation, when *not* to use it, and a "evaluate it yourself" checklist.

---

## Requirements

- **Claude Code** (CLI / desktop / IDE) — this is a Claude Code skill.
- **bash** — the scripts are bash (works on macOS, Linux, and Windows via Git Bash / WSL).
- **python3** — used for all JSON state mutation and validation.
- **git** — branches, worktrees, and the commit rhythm; `git rev-parse` is how scripts find the repo root.
- **node** (v18+, which Claude Code already requires) — only for the status line (`goal-statusline.js`). Everything else works without it.

---

## Repository layout

```
claude-goal/
├── README.md
├── LICENSE                     # MIT
├── install.sh                  # one-command installer (copy + merge settings)
├── settings.example.json       # the 3 core hooks + statusLine, ready to merge
├── skill/
│   └── SKILL.md                # the /goal skill (the brain — full contract + protocol)
├── scripts/                    # → installs to <project>/.claude/scripts/
│   ├── goal-init.sh            # create a goal
│   ├── goal-loop.sh            # head-less iteration runner
│   ├── goal-continue.sh        # cron / manual cross-session resume
│   ├── goal-update-state.sh    # atomic state mutation + completion/coverage guards
│   ├── goal-check-criterion.sh # run one criterion → JSON (+ numeric value)
│   ├── goal-resolve.sh         # resolve goal id → state file
│   ├── goal-list.sh            # list goals
│   ├── goal-validate.sh        # validate state JSON
│   ├── goal-stop-hook.sh       # ★ Stop hook — the autonomy engine
│   ├── goal-no-ask.sh          # PreToolUse — blocks AskUserQuestion
│   ├── goal-no-text-reminder.sh# PostToolUse — anti-narration nudge
│   ├── goal-scope-check.sh     # PostToolUse — scope-lock revert
│   └── goal-statusline.js      # status line
├── docs/
│   ├── ARCHITECTURE.md         # how the engine + state + hooks work, in depth
│   ├── PRINCIPLES.md           # the operating rules the loop relies on
│   ├── TAILORING.md            # adapt criteria / gates / model / DEPLOY to your stack
│   ├── MEMORY.md               # the memory convention
│   ├── SETUP.md                # hands-on setup + quick reference
│   └── EVALUATION.md           # honest assessment: limitations, failure modes, what's verified
└── memory/                     # de-branded skill-related memory starter pack
```

---

## FAQ

**Does it work on Windows?** Yes — via Git Bash or WSL. The scripts normalize Windows paths and the
hooks are tested on Git Bash. `python3` and `git` must be on `PATH`.

**Will it touch files outside what I asked?** Only if you let it. Set `scope_lock` (and `scope_flex`
for dependencies). With the scope-lock hook wired, out-of-scope edits are auto-reverted.

**What if a criterion is wrong?** Criteria are auto-derived in iteration 1 and then *frozen* — but you
can `/goal clear` and restart, or pause and edit the state file before iteration 1 completes. The
freeze exists so the agent can't quietly weaken criteria to "pass."

**How do I stop it?** `touch .claude/goals/PAUSE`. Or `/goal pause`. Or remove the `Stop` hook.

**Does it need the cron?** No — within a running session it never relies on cron. The cron is only a
safety net for resuming after the terminal closes or the machine sleeps.

---

## Credits & license

`claude-goal` is the de-branded, general-purpose extraction of a `/goal` skill developed for a
production codebase. The hard-won lessons baked into the contract (build-don't-survey, plateaus are
progress, verify-before-claiming, failures-are-data) came from running long autonomous jobs and
watching where they broke.

MIT licensed — see [LICENSE](LICENSE). Contributions and forks welcome.

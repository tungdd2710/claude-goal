---
name: goal
version: 0.10.0
description: |
  Set a goal, walk away. Supports MULTIPLE concurrent goals with worktree
  isolation. Agent derives criteria, scope, and plan from the goal string alone.
  Iteration 1 researches + probe-fixes. Iterations 2-N execute guided by
  structured reflections. Runs CONTINUOUSLY until goal achieved — no budget cap,
  no pause between iterations, no user prompts. Only stops on: goal complete,
  all approaches exhausted, or context window limit (cron resumes).
  0.9.0: fans WIDE work out via Dynamic Workflows (tens–hundreds of parallel
  subagents) and ROUTES subtasks to specialized skills (gates, QA, UX, research)
  — always within the never-stop / never-ask contract.
  Use when: "goal", "/goal", "set a goal", "work on this until done",
  "keep going until", "autonomous", "loop until".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Agent
  - Skill
  - AskUserQuestion
triggers:
  - goal
  - set a goal
  - autonomous
  - loop until
  - keep going until
---

# /goal — Persistent Autonomous Goal

**Two axes of power (0.9.0):** `/goal` owns the **time axis** — it never stops, surviving
auto-compaction and cron-resuming across days. It now also taps the **scale axis** via **Dynamic
Workflows** (fan WIDE work out to many parallel subagents) and the **ecosystem** via **Skill
Routing** (delegate subtasks to specialized skills). Both are subordinate to the contract below:
they make each iteration wider and smarter, never a reason to pause or ask. Details in
**§Parallel Fan-Out via Dynamic Workflows** and **§Skill Routing During Execution**.

## ⛔ NON-NEGOTIABLE CONTRACT: USE ALL MEANS NECESSARY — NO LOCK IS SACRED

When a `/goal` has a **measured objective** (an accuracy/error/latency target, a coverage count, a
pass/fail criterion), **nothing in the codebase is "locked" against that objective.** User-locked
specs, "do not alter" comments, fixed architecture / phase counts, default model choices, prompt
versions — all of them are LEVERS, not walls. If changing one raises the measured target: change it,
bench it, keep the evidence. The reflex this kills: "X is user-locked, so I'll only add post-hoc /
work around it / pause for approval." Forbidden. Invoking `/goal` already authorizes using every means
to hit the number — that is what "all means necessary" means.

The ONLY real constraints during a goal: (1) don't fabricate data or metrics, (2) don't delete or
mutate prod data without a backup first, (3) don't break multi-tenant security. Everything else yields
to the objective. When you alter a locked spec for accuracy, UPDATE its lock-doc / runtime assertion in
the SAME change (re-encode it as accuracy-driven) so the next agent isn't blocked by stale lock language.

## ⛔ NON-NEGOTIABLE CONTRACT: NEVER STOP (read first, overrides everything below)

`/goal` means **set it and walk away**. The user is NOT at the keyboard to answer you.
Every stop/question defeats the entire purpose of the skill. TWO wired mechanisms enforce this:
1. **PostToolUse reminder** (`goal-no-text-reminder.sh`) — while any goal is `active`, injects after
   every tool call: "do NOT write text; your next action MUST be a tool call." A soft nudge.
2. **Stop hook** (`goal-stop-hook.sh`, wired in `.claude/settings.local.json`) — the real engine. When your
   turn would end, it **blocks the stop and feeds you the next-iteration instruction in the SAME
   session** (context preserved, no subprocess). It is **claim-scoped**: it only continues a session
   that wrote its claim file. So **write your claim at goal start** (see §Session claiming) — else the
   hook sees no claim, ALLOWS the stop, and the loop silently dies on the first turn-end.

**Two in-session boundaries you cannot cross by yourself:** (a) the harness overrides a Stop hook after
~8 consecutive blocks (raise via env `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`); (b) auto-compaction. Both are
bridged by the durable cron + `goal-loop.sh`, which resume across session/turn boundaries. Inside those
boundaries, honor the contract exactly — never end a turn voluntarily while the goal is active.

**You may end your turn ONLY when one of these is true:**
1. **Goal complete** — all success criteria pass **AND every discovered finding/gap is CLOSED (100%)** → set `status=complete`. "fix all" / "do all" = **100%**. There is NO "literal all vs practical all", no "deterministic subset". A gap you found and documented but left open is NOT complete. "Needs human review / AD / contact data" is NOT a stop — RESOLVE it with the best available signal (every key: id → phone → email → exact name → **context-scoped fuzzy** → record-context) and APPLY high-confidence matches rather than handing off a worklist. Only a SINGLE item with genuinely ZERO usable signal may be impossible (*proven* in negative_knowledge) — keep closing every other gap to 100%.
2. **All approaches exhausted** — every reasonable `approach_tag` is in `negative_knowledge` → set `status=blocked`.
3. **Auto-compaction** — the harness compacts context; the loop resumes automatically afterward (this is the ONLY mid-work pause, and it is not your decision).
4. **Deliberate human pause** — a `.claude/goals/PAUSE` sentinel file exists (only the user creates this).

**FORBIDDEN while a goal is active (these are the stop-bug — the #1 failure mode):**
- ❌ `AskUserQuestion` for anything derivable. It is in `allowed-tools` for goal *creation* only.
  During execution, DECIDE yourself from the plan / locked specs / memory. The ONLY permitted
  pause is a truly irreversible + non-derivable action (prod deploy, schema migration, data
  deletion) — and even then prefer act-then-let-user-redirect.
- ❌ **Relabeling in-scope work as a "user-decision item" / "needs approval" to justify stopping.**
  A finding the goal could FIX is not a decision to outsource — DO it. (1) **Code fixes have NO
  approval gate** — just write them. (2) **Reversible data fixes** (back up first, then mutate) —
  just do them. (3) Only a genuinely *irreversible + ambiguous* prod mutation pauses — and even then
  you PREPARE THE FULL FIX (backup taken + migration written + script ready-to-run) before noting it,
  never merely list it and walk away. Marking `status=complete` while ANY in-scope finding is
  unaddressed — or punting three findings to a report and stopping — IS the cherry-pick stop-bug the
  user designed this skill to kill. "do all" / "/goal" already authorized the work; act on it.
- ❌ **Marking complete with ANY discovered gap open, or downgrading "fix all" to a subset.** "all" = 100%,
  not "the rows that matched cleanly". PUNTING a resolvable gap to a human (a worklist, "needs confirmation",
  "needs AD/contact data") when a resolution is reachable IS the stop-bug. Push HARDER before giving up:
  use the record's OWN CONTEXT to make a fuzzy match precise — match a raw name against the **roster of
  that record's own class / report / cohort**, not the whole population (a partial name like "Mạnh" is
  usually unique within one class even if ambiguous school-wide). APPLY the match. Only after EVERY
  context-scoped angle is exhausted on a specific item, and it has zero usable signal, is it impossible
  — proven, logged, next gap. Never stop at "documented".
- ❌ Ending a turn with a question ("want me to continue?", "say go", "should I…?").
- ❌ A checkpoint / status-summary / "here's what I did" paragraph mid-goal.
- ❌ "I'll pick this up next turn" / "fresh turn" / "deserves focus" / end-of-long-turn boundary.
- ❌ "This is design-gated, so I'll pause for approval." Invoking `/goal` + approving the plan
  IS the approval. For UI, BUILD following the locked design system (your design system,
  token files, and any locked UI/layout spec) — that satisfies "no shortcuts of locked specs"
  WITHOUT halting. Do not invent a gate the user already cleared.
- ❌ Treating a budget cap, a "milestone", or a found-bug-in-another-system as a reason to stop.

**REQUIRED instead:** after every tool call, your next action is ANOTHER tool call advancing
the goal. Make decisions, don't present options. Commit per unit, typecheck, chain to the next
unit. Keep `context_summary` fresh every iteration so you survive auto-compaction. Surface
decisions in ONE line as you build — never gate execution on them.

> If you catch yourself typing a sentence that ends a turn or asks permission — DELETE IT and
> call a tool. The Stop hook will reject the stop anyway; save the round-trip.

## Commands

### `/goal <objective>` — Create and start a goal

Two modes:

**Minimal (walk-away):** User provides only the objective string. Agent derives everything.
```
/goal Fix all N+1 queries in the dashboard
```

**Explicit (override):** User provides criteria/scope/budget if they want control.
```
/goal Fix all N+1 queries in the dashboard --scope src/app/api/dashboard/ --max 5
```

Either way, the agent:
1. Creates state file (`goal-{id}.json`), branch, and worktree (if other goals active)
2. Adds entry to `.claude/goals/index.json`, then **writes its session claim** (load-bearing for the
   Stop-hook engine): `echo "<id>" > ".claude/goals/session-${CLAUDE_CODE_SESSION_ID}.goal"` (§Session claiming)
3. Schedules durable cron for between-session continuation — **BUT first check if one already exists** via CronList. If a `/goal resume` cron is already scheduled, SKIP creating a new one. Multiple crons = multiple spurious triggers = wasted context.
   ```
   CronCreate(cron: "17 */2 * * *", durable: true, recurring: true,
     prompt: "/goal resume -- check .claude/goals/index.json for all active goals, resume each")
   ```
   **When a goal completes:** delete the cron via CronDelete if no other active goals remain. Don't leave orphan crons firing into an empty goal list.
4. Begins iteration 1 (UNDERSTAND mode)
5. **After iteration 1 completes, immediately starts iteration 2.** No waiting, no user prompt, no cron delay. Continue chaining iterations until budget exhausted, goal complete, or blocked.

### `/goal list` — Show all goals (active, completed, blocked, paused)
### `/goal status [id]` — Show state + run criteria checks for a goal (auto-detects if only one active)
### `/goal pause [id]` — Pause a goal (saves state)
### `/goal resume [id]` — Resume a specific goal, or auto-pick (see below)
### `/goal clear [id]` — Abandon a goal (archives state, removes from index)
### `/goal check [id]` — Run criteria without iterating

### `/goal resume` — Smart goal selection

When no `id` is given, the resume command uses this priority:

1. **Check for unclaimed active goals** — goals where no `session-*.goal` claim file exists. If exactly 1 unclaimed → auto-pick it and start immediately. If multiple unclaimed → show a picker (AskUserQuestion with goal slugs + objectives, 10-second auto-select of the oldest unclaimed).

2. **If ALL active goals are claimed** by other sessions → tell the user "all goals are being worked on by other CLIs" and offer to create a new goal.

3. **Cron-triggered resume** (`/goal resume` from durable cron): skips the picker, auto-picks the oldest unclaimed active goal. If all claimed, does nothing (other CLIs are handling them).

**Session claiming (LOAD-BEARING — the Stop-hook engine keys off this):** The FIRST thing you do when
creating or resuming a goal — before any code work — is write your claim, using the harness session-id
env var. This is the SAME id `goal-stop-hook.sh` reads from its stdin, so they MUST match:
```bash
echo "<goal-id>" > ".claude/goals/session-${CLAUDE_CODE_SESSION_ID}.goal"
```
If you skip this (or use the wrong variable), the Stop hook finds no claim for your session and ALLOWS
the stop — the never-stop loop silently dies. Remove the claim ONLY on deliberate pause/clear:
```bash
rm -f ".claude/goals/session-${CLAUDE_CODE_SESSION_ID}.goal"
```
Claim files are ephemeral — one per CLI session actively working a goal. Stale claims (crashed sessions)
are detected by age (>4 hours = stale, auto-remove).

## State Files

Goals are stored individually with a registry index:

```
.claude/goals/
├── index.json              # registry: [{id, objective, status, branch, created_at}]
├── goal-{id-1}.json        # full state for goal 1
├── goal-{id-2}.json        # full state for goal 2
├── goal-{id-1}.json.bak    # atomic backup
├── goal-{id-1}.json.lock/  # lockdir for mutual exclusion
└── worktree-{id}/          # git worktree (if multi-goal)
```

### `index.json` — Goal Registry
```json
{
  "version": 1,
  "goals": [
    {"id": "abc12345", "objective": "Fix N+1 queries", "status": "active", "branch": "goal/fix-n-1", "created_at": "ISO"},
    {"id": "def67890", "objective": "Add unit tests", "status": "complete", "branch": "goal/add-tests", "created_at": "ISO"}
  ]
}
```

Synced automatically by `goal-update-state.sh` on every status change.

### `goal-{id}.json` — Goal State
```json
{
  "id": "<8-char>",
  "objective": "Fix all N+1 queries in the dashboard",
  "success_criteria": [
    {"check": "<cmd>", "label": "<desc>", "auto": true}
  ],
  "scope_lock": ["src/app/api/dashboard/"],
  "scope_flex": ["prisma/"],
  "status": "active",
  "budget": {"max_iterations": 5, "used": 0},
  "iteration_log": [],
  "negative_knowledge": [],
  "reflections": [
    {
      "iteration": 1,
      "outcome_reason": "Probe fix on sessions/route.ts succeeded.",
      "next_focus": {"criterion": "no-bare-findmany", "files": ["route1.ts"]},
      "research_files": [],
      "brainstorm_candidates": null
    }
  ],
  "discovered_infra": {
    "typecheck_clean": true,
    "tests_exist": false,
    "baseline_ts_errors": 0
  },
  "impossibility_reason": null,
  "created_at": "ISO", "paused_at": null,
  "completed_at": null,
  "branch": "goal/slug", "worktree_path": ".claude/goals/worktree-<id>",
  "context_summary": "",
  "metrics": {
    "total_iterations": 0,
    "total_tool_calls": 0,
    "total_wall_clock_seconds": 0,
    "total_tokens_estimated": 0,
    "session_count": 0,
    "commits": 0,
    "negative_knowledge_count": 0
  }
}
```

### Script Resolution

All scripts accept `--goal-id <id>` as optional first argument. If omitted, `goal-resolve.sh` auto-detects:
1. Single active goal → use it
2. Multiple active + CWD inside a worktree → match by worktree path
3. Multiple active + ambiguous → error listing goal IDs

**Migration**: Legacy `active.json` auto-migrates to `goal-{id}.json` + `index.json` on first resolve.

## Iteration Protocol

### ITERATION 1: UNDERSTAND

This iteration researches and does one probe fix. No multi-file changes.

**Step 1 — Survey the codebase for this goal:**
- Grep and read files to understand where the problem lives
- Map which files are involved, what patterns exist
- Identify dependencies that might need scope_flex
- **If the goal involves data (corpus, benchmarks, training sets): spot-check 3-5 random rows against source truth.** Row counts and pipeline exit codes verify infrastructure, not content. Open a random record, read the actual text, compare to the source. If quality is suspect, fixing data comes before building on top of it.

**Step 2 — Derive criteria, scope, and budget:**

Discover what verification infrastructure exists:
- Does `npx tsc --noEmit` exit 0? If yes → typecheck criterion. If no → "TS errors don't increase" criterion.
- Do tests exist for the target scope? If yes → "tests pass" criterion. If no → skip.
- Generate a structural criterion specific to the goal (e.g., grep for the anti-pattern).
- **MANDATORY: at least one USER-FACING criterion.** Infrastructure checks (typecheck, prod 200) are necessary but NOT sufficient. Add a criterion that verifies the actual user experience: authenticated API calls return real data, forms submit successfully, pages render meaningful content (not placeholders). A goal about "make things work" must test AS A USER, not as a build tool.

**Criteria anti-patterns (BANNED):**
- "Prod responds 200/307" alone — this only checks the server boots, not that features work
- Unauthenticated curl checks — these only verify auth gates, not actual functionality
- File-existence checks — a route.ts existing ≠ it returns correct data
- Typecheck alone — TS compiles ≠ features work for users

**Criteria that actually verify "things work":**
- Authenticated API call returns non-empty data: `curl -b cookie -s /api/X | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(str(d)) > 50"`
- Page renders without 500 when logged in: use test user + cookie jar
- Form submission creates a DB row: POST + verify count increased
- Cross-role interaction completes: student submits → teacher sees in queue

**Metric (numeric-target) criteria — for goals like "accuracy ≥ 0.90" or "p95 latency ≤ 200ms":**
A boolean criterion can't represent a climb, so every plateau iteration looks like `no_change` and
risks the block rule. Instead, write a criterion whose check PRINTS the metric as its LAST stdout line
and add `target` + `direction`:
```json
{"check": "npx tsx scripts/bench.ts | tail -1", "label": "accuracy",
 "auto": true, "target": 0.90, "direction": "gte"}
```
Store the printed NUMBER (not a boolean) in `criteria_before`/`criteria_after`. The outcome engine then
marks the iteration `progress` when the metric moves toward target EVEN IF it doesn't yet pass — so a
0.54→0.62 climb reads as progress, not `no_change` (the plateau lesson). Pass = value meets
`target`. `direction`: `gte` (default) or `lte` (error/latency metrics where lower is better). `goal-check-criterion.sh`
auto-extracts the trailing number into a `value` field.

Set scope_lock = directories containing the problem. Set scope_flex = files imported by scope_lock files.
Set budget = `ceil(file_count / 5) + 1`, capped at 10.

**Coverage gate (MANDATORY for "all / every / fix-all / entire / comprehensive" objectives).** If the
objective says ALL, you MUST register a coverage gate at iteration 1:
`goal-update-state.sh --goal-id <id> --set-coverage "<covered_count_cmd>" "<total_count_cmd>"` —
`total_count_cmd` computes the LIVE denominator from the codebase (e.g. `find src/app/api -name route.ts | wc -l`),
`covered_count_cmd` counts how many units you've actually verified-OK. The goal **cannot be marked complete
until covered >= total** (enforced in `goal-update-state.sh`; both commands re-run live at completion). This
is what stops "make all functions work" from being declared done on a 28-of-1319 subset — there is no
smaller denominator you can substitute, and `--set-coverage` cannot lower it past the live count.

Use the auto-generated values. Mark criteria `"auto": true`. Do NOT ask the user to approve — `/goal` means autonomous. Just derive, set, and begin.

**Step 3 — Probe fix:**
Pick ONE file that represents the median complexity (not simplest, not hardest).
Apply the fix. Run criteria. This validates that the approach works.

If no turns remain for the probe fix, skip it — the research output is still valuable.

**Step 4 — Reflect:**
Write exactly 3 fields via `goal-update-state.sh --reflect`:
```json
{
  "outcome_reason": "What happened and why (one sentence)",
  "next_focus": {"criterion": "label of failing criterion to target", "files": ["specific/file1.ts", "specific/file2.ts"]},
  "research_files": ["path/to/read/first.ts"]  // empty if not needed
}
```

**Step 5 — Close:**
Run all criteria (criteria_before = baseline from step 2, criteria_after = post-probe).
Update state. Commit: `goal(<id>): iteration 1 — survey + probe fix`

### ITERATIONS 2-N: EXECUTE

Each iteration follows 4 steps.

**Step 1 — Orient:**
- `bash .claude/scripts/goal-validate.sh`
- Read the goal state file. If `worktree_path` exists, work INSIDE it.
- Run ALL criteria via `goal-check-criterion.sh` → save as `criteria_before`. If all pass → run the **Completion Audit** (see below) before marking COMPLETE.
- If `budget.used >= budget.max_iterations` → auto-extend: `budget.max_iterations += 5`, log the extension, keep going. Budget is a progress marker, not a hard stop.
- Read `negative_knowledge` — these approach_tags are BANNED.
- Read last `reflections` entry → this tells you what to do.

**Step 2 — Research + Execute:**
- If `research_files` from last reflection is non-empty → Read those files first.
- Follow `next_focus`: target the specified criterion and files.
- **Orchestrate before hand-rolling:** if a specialized skill covers this subtask, invoke it per **§Skill Routing During Execution** (Tier-1 directly; Tier-2/3 via a sub-Agent or `SPAWNED_SESSION`). Invoke the MANDATORY gate for this boundary first (e.g. an AI-safety gate before any LLM call, a compliance gate before financial code).
- **Go wide when wide:** if `next_focus` spans ≥5 independent units (no two writing the same file), **fan out** per **§Parallel Fan-Out via Dynamic Workflows** instead of editing serially.
- Choose an `approach_tag` (max 3 words, kebab-case). If tag matches negative_knowledge → STOP, pick different or `blocked`.
- Make changes. Re-run targeted criterion after each edit. Revert if a passing criterion breaks.

**Step 3 — Verify:**
- Run ALL criteria via `goal-check-criterion.sh` → save as `criteria_after`.
- Update state via `goal-update-state.sh --iteration N ...` (outcome computed mechanically).
- If ALL pass → `--status complete`. Skip to Step 6 (metrics) then emit Completion Report.
- If `no_change`/`regression` → go to **Step 3b (Failure Analysis)**.
- Block ONLY if the SAME approach_tag failed twice consecutively (actual retry of same thing). Different tags at the same metric value = plateau exploration, not failure. **Plateaus get continued, not blocked.** (In one real run the breakthrough came after 13 iterations stuck on a plateau — blocking at iteration 2 would have killed the project.)

**Completion Audit (MANDATORY before marking complete):**

When all criteria pass, do NOT immediately mark complete. First:

1. **Act as a user for 3 minutes.** Pick the most common workflow for the goal's target role and ACTUALLY DO IT on prod — log in with a test user, navigate, click buttons, submit forms. If anything is broken, placeholder, or links out of context → NOT COMPLETE.

2. **Grep for known-bad patterns** in the scope:
   - `grep -rn "Phase D\|coming soon\|placeholder\|TODO.*wire\|will be.*implement" <scope>` — any match in user-visible UI = NOT COMPLETE
   - `grep -rn "href=\"/[^\"]*\"" <scope>` → spot-check 5 random links exist

3. **Check the last 3 commits' scope for regressions.** Did any fix introduce a new broken thing? Read the changed files' callers.

Only after the audit finds zero issues → `--status complete`. The audit adds ~5 min but prevents the "declared complete with visible problems" failure mode that wastes the user's trust.

**Step 3b — Failure Analysis (only on no_change/regression):**

This is the critical step that turns failure into progress. Do NOT skip it — a failed iteration without analysis is a wasted iteration.

1. **Diagnose WHY it failed** — not just "it regressed" but the specific mechanism:
   - Read the actual output/bench data from this iteration
   - Compare item-by-item: which specific items improved, which regressed, which stayed?
   - Identify the pattern: "X happened because Y" (e.g., "calibration rule lifted weak essays because TTR doesn't distinguish content quality from language quality in Task 1")
   - Write the diagnosis to `negative_knowledge` with the mechanism, not just the tag

2. **Research alternatives** — based on the diagnosis, search for approaches that avoid the failure mechanism:
   - Read relevant code/docs that the diagnosis points to (max 5 files)
   - If the failure is a known problem (e.g., high-band ceiling), search `docs/research/` for academic approaches
   - If the failure reveals a data gap, check what data is available to fill it
   - WebSearch for state-of-the-art solutions ONLY if internal docs don't cover it (max 2 queries)

3. **Brainstorm 3 candidate approaches** — generate exactly 3 alternative approaches, each structurally different from the failed one:
   - Approach A: the most conservative (smallest change from current state)
   - Approach B: a different category of fix (e.g., if prompt engineering failed, try data/calibration/model)
   - Approach C: the most ambitious (structural change, new module, different architecture)
   - For each: one sentence on what it does, one sentence on WHY it avoids the failure mechanism
   - Write all 3 to `reflections` as `brainstorm_candidates`

4. **Pick the highest-leverage candidate** — choose the one with the best expected-improvement-per-effort ratio. This becomes `next_focus` in the reflection. Don't pick the safest — pick the one most likely to break through the plateau.

Add the failed approach to `negative_knowledge`:
```bash
bash .claude/scripts/goal-update-state.sh --add-negative "tag" "WHY: <specific mechanism of failure, not just 'it regressed'>"
```

**Step 4 — Reflect:**
Write reflection via `goal-update-state.sh --reflect`. Fields:
- `outcome_reason` — the diagnosis from Step 3b (if failure) or the win from Step 3 (if improvement)
- `next_focus` — which criterion + which specific files to target next. If from Step 3b, this is the chosen brainstorm candidate.
- `research_files` — specific paths to read before next iteration (from Step 3b research)
- `brainstorm_candidates` (new, optional) — the 3 approaches from Step 3b brainstorm, so future iterations can try B or C if A fails

Commit: `goal(<id>): iteration N — <summary>`

**Step 5 — Update metrics:**
After each iteration, run ONE command. It DERIVES iterations, wall-clock (from iteration timestamps,
clamped ≥0), commits (git log grep `goal(<id>)`), and negative-knowledge-count mechanically from state
— so the Completion Report is truthful even with no extra args. NEVER raw-Write the state file (SAFETY):
```bash
bash .claude/scripts/goal-update-state.sh --goal-id <id> --update-metrics
```
Optionally enrich the only un-derivable counters (these INCREMENT; derived fields recompute each call):
`--tool-calls N` (tool calls this iteration), `--tokens N` (est. input+output), `--new-session` (add
once when you resumed cold from `context_summary`).

**Step 6 — Continue immediately (NO TEXT OUTPUT):**
Do NOT stop. Do NOT write text. Do NOT summarize. The VERY NEXT thing after updating metrics MUST be a tool call for the next iteration's Step 1 (Orient). Not a sentence. Not a status update. A tool call.

If you are about to write ANY text to the user here — STOP. You are violating the skill. Call `bash .claude/scripts/goal-validate.sh` or `Read` the goal state file instead. That IS the next iteration starting.

The goal loop runs **endlessly** until:
- All criteria pass → COMPLETE
- Blocked on ALL approaches (every reasonable tag in negative_knowledge) → surface to user
- Impossibility proven → set impossibility_reason, surface to user

**There is NO context window stop.** When context gets large, Claude Code auto-compacts the conversation (summarizes older messages). The goal continues running through compaction — the goal state file (with `context_summary`) carries all needed state. This is how a fully-autonomous agent operates: it runs continuously through compaction without stopping. Do the same.

**Before every iteration, update `context_summary`** in the goal state file with the current state so that if compaction drops older messages, the next iteration can orient from the summary alone. This is the ONLY concession to context management — a 3-sentence state update, not a stop.

**Budget is NOT a hard stop.** When budget is exhausted, auto-extend by +5 and keep going. The only things that stop the loop are: goal achieved or all approaches exhausted. Nothing else.

**The cron is a FALLBACK for session termination only** (user closes terminal, machine sleeps). Within a running session, the agent never stops between iterations. The cron picks up if the session dies unexpectedly.

## Parallel Fan-Out via Dynamic Workflows (0.9.0)

The EXECUTE step is sequential by default — one file, re-check, next file. That is correct for
narrow work. But when an iteration's `next_focus` touches **many independent units** ("add the missing
`org` filter to 25 endpoints", "migrate 60 components to the new token", "fix N+1 in 40 routes"),
serial editing wastes the loop. Fan the work OUT.

**Width test — fan out only when BOTH hold:** (1) ≥5 units, and (2) the units are **independent** (no
two write the same file) with the **same fix shape**. If units share a file or depend on each other's
output → keep them serial (shared-file edits MUST serialize — `schema.prisma` is the canonical example).

**Two mechanisms — prefer the first:**

1. **Native Dynamic Workflow (preferred).** **This skill explicitly authorizes the `Workflow` tool —
   running `/goal` IS the opt-in** (a skill whose instructions tell you to call Workflow satisfies the
   tool's explicit-opt-in rule). Call the `Workflow` tool with a JS script (it must start with
   `export const meta = {...}`) describing the fan-out: each independent unit → one subagent call, run
   in parallel, with a second phase that verifies before results are folded in. Keep units strictly
   inside `scope_lock` — brief each subagent with the exact constraint, the `<criterion cmd>`, and
   "never ask, never stop, return a diff summary". The harness fans out tens–hundreds of subagents in
   this one session, verifies, and converges a single result — the scale axis the standalone loop never had.

2. **Parallel background Agents via the `Agent` tool (fallback — NO opt-in required).** The `Agent` tool
   needs no opt-in and works any time — the always-safe fallback. Use it when the Workflow opt-in does
   not apply (e.g. the headless runner), or for simpler fan-outs under ~10 units. Spawn one background
   Agent per batch. **MANDATORY:** invoke your parallel-safety gate first (if you have one), and give every Agent that commits
   its OWN git worktree (`isolation: "worktree"`, or `.claude/agent-worktrees/agent-N`) — shared working
   dir = branch collision (CLAUDE.md hard rule). Brief each Agent with: the unit list, the `scope_lock`,
   the exact criterion command, and "never ask, never stop, return a diff summary".

**Goal still owns convergence.** Fan-out produces edits; it does NOT decide completion. When it returns,
the loop resumes at **Step 3 — Verify**: run ALL `success_criteria` over the merged result, then the
**Completion Audit**. The workflow's internal verification is necessary but NOT sufficient. A
converged-but-criteria-failing result → **Step 3b Failure Analysis** as normal.

**Scope-lock (only if the hook is wired).** The `goal-scope-check.sh` PostToolUse hook reverts any out-of-scope
edit — from subagents too — **but it is NOT wired by default** (see §Safety wiring note). When unwired, fan-out
scope is *self-enforced*: keep units inside `scope_lock` (or `scope_flex`) yourself. A unit needing a
brand-new directory is a scope decision: surface it in ONE line and keep going (don't gate).

**Never-stop while fanned out.** Launching a workflow is ONE tool action — NOT a stop, NOT a poll point.
While it runs, do the next useful thing (prepare the next iteration's criterion, write the post-merge
verification, draft the commit). Do NOT sit in a `grep -c "done"` poll loop (the agent equivalent of
`sleep` — see Autonomy Rules). Collect the result at the next Verify.

**Cost guard.** Fan-out multiplies token spend — bound it to the units in `next_focus`, never "the whole
repo". For long batch/bench fan-outs apply the **early-kill gate** (Multi-Day Persistence): sample
partial results after ~10 units; if worse than baseline → kill and pivot.

## Skill Routing During Execution (0.9.0)

`/goal` is an **orchestrator**, not a lone hand-coder. Before hand-rolling a subtask, check whether a
specialized skill already does it better — then invoke it. This lets the loop leverage the whole skill
ecosystem (gates, QA, design, research) instead of re-deriving each one.

**The hard constraint:** the never-stop / never-ask contract still holds. A skill that blocks on
`AskUserQuestion` would freeze the loop forever. So every skill is sorted into three tiers, and you
invoke it by the rule for its tier.

### Three invocation tiers

Sort every skill you might call into three tiers and invoke it by its tier's rule:

- **Tier 1 — AUTONOMOUS-SAFE → invoke directly via the Skill tool.** It never asks the user; it runs
  to completion and returns output/edits. Use freely, mid-loop. (Examples: a diff-review skill, a
  codebase-map skill, a memory-search skill, a lint/format skill.)
- **Tier 2 — CONDITIONAL → invoke via a non-interactive mode.** Some skills can be told to skip their
  questions — via an env flag the skill honours (`SPAWNED_SESSION=true`, which the goal runner already
  exports) or a `--auto` / non-interactive flag. If a skill supports that, pass it. In an interactive
  session the safe equivalent is to run the skill's work inside a **sub-Agent** (Agent tool): a spawned
  agent has no interactive channel to the user, so it cannot stall the loop. Brief it "use recommended
  defaults, never ask".
- **Tier 3 — INTERACTIVE → NEVER call directly.** Any skill built around multi-question dialogs will
  freeze the loop the moment it asks. If you need its *capability*: (a) spawn it inside a sub-Agent
  briefed to take its autonomous path + recommended defaults, or (b) replicate its core inline. The
  ONLY sanctioned place an interactive deploy skill runs with its human gate intact is the
  **irreversible prod boundary** — which the contract already lets goal pause for. Everything up to the
  merge (branch, typecheck, PR draft) is done autonomously.

### Gates to invoke at boundaries (if you have them)

If your project has "gate" skills — pre-flight checks tied to a specific boundary — invoke the relevant
one FIRST at that boundary. These are all Tier-1 (autonomous-safe) by design. Map your own skills onto
this table; if you have none, the loop just proceeds (the in-script guards in `goal-update-state.sh`
still enforce criteria + coverage + commit-completion safety):

| Boundary the loop hits | Invoke first (your equivalent, if installed) |
|---|---|
| About to commit / push / merge / deploy | a commit / pre-ship gate |
| About to write an LLM call, pick a model, or ship a prompt | an AI-safety / model-choice gate |
| About to touch financial / payroll / regulated code | a compliance gate |
| About to spawn 2+ agents / fan out (see §Parallel Fan-Out) | a multi-agent / parallel-safety gate |
| Making a claim that informs an arch decision; analyzing an external repo | a research / repo-eval gate |

### Routing table (subtask → kind of skill → how)

Prefer an installed skill over hand-rolling, but invoke it by its tier:

| When the loop needs to… | Kind of skill | Tier / how |
|---|---|---|
| Verify a feature works as a user (browser/QA) | QA / e2e-test | T3 → sub-Agent |
| Root-cause a bug / 500 / regression | debug / investigate | T3 → sub-Agent |
| Review the diff before committing | code-review | T1 → direct (interactive variants → sub-Agent) |
| Map an unfamiliar codebase area | codebase-map | T1 → direct |
| Recall prior-session work | cross-session memory search | T1 → direct |
| Build / repair UI | interface / frontend design | T1 → direct (interactive design brains → sub-Agent) |
| UX heuristics / a11y / forms / tables / mobile | ux audits | T1 → direct |
| Commit / commit+push+PR | commit helper | T1 (run your commit gate first) |
| Execute a multi-phase plan | plan executor | T2 → pass the autonomous flag |
| Plan / research before building | planner / researcher | T1/T2 → `--auto` |

### The rule of thumb

If a skill *asks the user anything*, it is Tier 3 — wrap it in a sub-Agent (no user channel) briefed
"use recommended defaults, never ask, return a summary", or replicate its core inline. If it runs to
completion without asking, it is Tier 1 — call it directly. When unsure, treat it as Tier 3.


## Autonomy Rules

**The autonomous-agent lesson: trying and failing beats analyzing and asking.**

- **NEVER ask the user anything during /goal.** Not AskUserQuestion, not "should I?", not "do you want?", not "which path?". The user said `/goal` — that means GO.
- **Build, don't survey.** Research is only valuable when it directly informs the next edit. If you've spent 10+ tool calls reading without editing, you're stalling.
- **Ship wrong, learn, iterate.** A fully-autonomous agent once shipped a catastrophic version AND, in the same session, the system that fixed it. The failures informed the success. My approach of "survey → ask → verify → ask again" produces zero lines of code.
- **Make decisions, don't present options.** "3 possible paths" followed by a question = paralysis. Pick the highest-leverage path based on evidence and execute. If it fails, negative_knowledge captures why and the next iteration picks a different path.
- **Verify claims with code, not questions.** Run the bench, read the output, compute the metric. Don't ask the user "is this real?"
- **NEVER narrate idle status.** "Bench is running, waiting for results" is a stop. If a bench takes 2 hours, build the NEXT thing in parallel. Write the post-processor. Write the fix for the expected failure. Prepare iteration N+1's code while iteration N's bench runs. Stopping to report progress = stopping.
- **NEVER poll in a loop.** More than 3 consecutive `ssh <your-host> 'grep -c ...'` calls with no code written between them = polling loop = the agent equivalent of `sleep`. If the bench isn't done after 3 polls → STOP POLLING. Start the next iteration's code. Check bench results at the NEXT iteration's Orient step. Polling produces zero value.
- **NEVER stop between iterations.** After completing iteration N, immediately start iteration N+1. No "here's what I did" summary to the user. No waiting for approval. The user said `/goal` — that means continuous execution until goal achieved. The ONLY acceptable stops are: goal complete, or all approaches exhausted (every tag blocked). Budget exhaustion is NOT a stop — auto-extend. Context window is NOT a stop — auto-compaction handles it; keep `context_summary` updated so the agent can orient after compaction drops older messages.
- **ZERO text output during /goal.** Do NOT write ANY text to the user between tool calls. No narration, no status, no tables, no "let me check", no "0 errors on X", no summaries, no "Back to 0.780", no "Let me update the goal state", no "Now let me build X". JUST CALL TOOLS. The user sees tool calls and results directly. Any text output = a pause = a stop = a violation. The ONLY text output allowed is the **completion report** (see below).

**THE STOP BUG:** Claude has a deep tendency to write a summary paragraph after completing any unit of work. Inside /goal, this is THE failure mode — every summary = a pause = the user has to send another message = the loop breaks. The fix: after EVERY tool call, the next action MUST be another tool call. Never text. If you catch yourself typing a sentence that starts with "Now let me...", "The results show...", "Back to...", "Goal state updated...", "All committed..." → DELETE IT and call a tool instead.

## Completion Report

When the goal reaches status `complete`, `impossible`, or `blocked`, output a structured report to the user. This is the ONLY text output allowed during the entire /goal lifecycle.

```
## Goal Complete: <objective (truncated to 80 chars)>

| Metric | Value |
|---|---|
| Status | complete / impossible / blocked |
| Iterations | <metrics.total_iterations> |
| Tool calls | <metrics.total_tool_calls> |
| Wall clock | <metrics.total_wall_clock_seconds formatted as Xh Ym Zs> |
| Tokens (est.) | <metrics.total_tokens_estimated formatted as Xk> |
| Sessions | <metrics.session_count> |
| Commits | <metrics.commits> |
| Approaches tried | <metrics.total_iterations> (of which <metrics.negative_knowledge_count> failed) |
| Created | <created_at> |
| Completed | <completed_at> |

### What was built
<3-5 bullet points: files changed, features added, metrics moved>

### What failed (negative knowledge)
<list each negative_knowledge entry: tag — reason>

### Final criteria state
<for each criterion: label — PASS/FAIL>
```

Set `completed_at` to current ISO timestamp when status changes to complete/impossible/blocked.

## Multi-Day Persistence

Goals that span multiple sessions (GPU bench runs, large refactors) use three mechanisms:

**1. Context summary (MANDATORY every iteration)** — at the end of every iteration, write a 3-sentence summary:
```bash
bash .claude/scripts/goal-update-state.sh --set-context-summary \
  "Iteration 3 complete. Query-batching helper built, dashboard route migrated, 2 of 7 N+1 sites fixed. Next: migrate the report + export routes the same way."
```
This is NOT for "the next session" — it's for surviving auto-compaction within THIS session. When Claude Code compacts older messages, the context_summary in the goal state file is the agent's memory of what happened. Update it EVERY iteration, not just at session end. The agent should be able to read the goal state file cold and know exactly what to do next.

**2. Durable cron (session-death fallback only)** — after creating the goal, schedule a durable check:
```
CronCreate(cron: "17 */2 * * *", durable: true, recurring: true,
  prompt: "/goal resume -- check .claude/goals/index.json for all active goals, resume each")
```
This fires every 2 hours and exists ONLY as a safety net for when the user closes the terminal or the machine sleeps. Within a running session, the agent NEVER relies on cron — it chains iterations continuously through auto-compaction. The cron is insurance, not the engine.

**3. Session resume** — `goal-continue.sh` now outputs the session ID so the next invocation can use `claude --resume <id>` instead of cold `claude -p`, preserving conversation context.

**For GPU bench runs:**
- Start bench in tmux: `ssh <your-host> 'tmux new-session -d -s bench /tmp/run-bench.sh'` (survives SSH disconnect)
- Write expected result path to goal state
- **EARLY KILL GATE (MANDATORY):** After 10 items, compute the partial metric. If worse than baseline by > 0.05 → KILL and pivot.
- **NEVER WAIT FOR BENCH RESULTS.** A bench takes 10-60 min. Spending that time polling `grep -c` is identical to sleeping — it produces zero code. Instead:
  1. Start the bench in tmux
  2. Check partial results ONCE after ~5 items (1-2 polls max)
  3. If early kill gate doesn't fire → IMMEDIATELY start the next iteration's code. Build the next prompt version, the next bench script, the next calibration rule, the data pipeline — anything that will be needed regardless of this bench's outcome.
  4. Check bench results BETWEEN iterations (at the Orient step), not during idle polling loops.
  
  **The anti-pattern this kills:** 20+ consecutive `ssh <your-host> 'grep -c ...'` calls with no code written between them. That's the agent equivalent of refreshing a loading screen. If you catch yourself polling more than 3 times in a row → STOP POLLING and BUILD SOMETHING.

## Status Line

When a goal is active, the Claude Code footer shows:

```
⎯ /goal:fix-n-plus-1 i3 │ Opus 4.8 │ Fixing query batching │ my-project ████░░░░░░ 38%
```

Format: `⎯ /goal:<3-word-slug> i<iteration_count>` in purple. Shows only the goal THIS CLI session is working on, not all active goals.

**Session binding:** When starting a goal iteration, write a claim file:
```bash
echo "<goal-id>" > ".claude/goals/session-${CLAUDE_CODE_SESSION_ID}.goal"
```
The statusline reads this to show only the claimed goal. (Same claim file the Stop-hook engine keys off.) Falls back to showing the sole active goal if no claim file exists. Multiple CLIs each see their own goal.

Implemented in `.claude/scripts/goal-statusline.js`.

## Multi-Goal Support

Multiple goals can run concurrently. Each goal:
- Has its own `goal-{id}.json` state file
- Gets its own git worktree when other goals are already active (file isolation)
- Has non-overlapping `scope_lock` (enforced at creation — `goal-init.sh` rejects overlap)
- Runs independently with its own criteria, budget, reflections, and negative knowledge

**Scope overlap rejection**: Two goals cannot edit the same directories. `goal-init.sh` checks all active goals' `scope_lock` arrays and rejects if any path is a prefix of another.

**Resolution**: All scripts accept `--goal-id <id>` as optional first argument. If omitted, `goal-resolve.sh` auto-detects:
1. Single active goal → use it (most common case, fully backward compatible)
2. Multiple active + CWD inside a goal's worktree → match by `worktree_path`
3. Multiple active + ambiguous → error listing goal IDs for explicit selection

**Resume all**: `/goal resume` without an ID resumes all active goals. If 1 active goal, runs in foreground. If N active goals, spawns N-1 as background agents (each in their own worktree) and runs 1 in foreground.

**Migration**: Legacy `active.json` auto-migrates to `goal-{id}.json` + `index.json` on first call to `goal-resolve.sh`. No manual action needed.

**Available scripts**:
- `goal-resolve.sh [--goal-id ID] [--all-active]` — resolve goal file path
- `goal-list.sh [--active-only]` — show all goals with status and budget
- `goal-init.sh --objective "..." [...]` — create a new goal
- `goal-update-state.sh [--goal-id ID] --status|--iteration|--reflect|...` — mutate goal state
- `goal-check-criterion.sh "<cmd>" "<label>"` — run a criterion check (goal-agnostic)
- `goal-scope-check.sh` — PostToolUse hook (auto-resolves goal)
- `goal-validate.sh [path]` — validate goal JSON schema
- `goal-loop.sh [--goal-id ID]` — standalone headless iteration runner (budget auto-extends; sets GOAL_DRIVER_ACTIVE)
- `goal-continue.sh` — cron / manual cross-session resume (NOT a Stop hook — wiring it as one recurses)
- `goal-stop-hook.sh` (in `.claude/scripts/`) — Stop-hook autonomy engine: pure-block, claim-scoped, fail-open [WIRED in `.claude/settings.local.json`]
- `goal-no-text-reminder.sh` (in `.claude/scripts/`) — PostToolUse `*` soft nudge: "next action must be a tool call" while THIS session's claimed goal is active [WIRED in `.claude/settings.local.json`]

## Safety (wiring status — read before relying)

> ⚠️ **Hook wiring reality (CREATED + WIRED + behaviorally tested 2026-05-29):** Both hooks now live in
> `.claude/scripts/` and are WIRED in `.claude/settings.local.json` — `goal-no-text-reminder.sh` (PostToolUse
> `*` soft nudge) AND `goal-stop-hook.sh` (Stop hook: **pure-block, no `claude -p` spawn**, claim-scoped,
> fail-open; guards → ALLOW on `GOAL_DRIVER_ACTIVE` / `PAUSE` / no-claim-files / no-claim-for-this-session /
> goal-not-`active` / any parse error). **Until 2026-05-29 these scripts did NOT exist and NO `Stop` hook was
> wired in any settings file — THAT was the stall bug:** the never-stop contract was fully documented but
> totally unenforced, so every turn-end actually stopped and the agent waited for the user. Verified this
> session: ALLOW (exit 0, zero output) on garbage stdin / unknown session / empty stdin; emits a valid
> `{"decision":"block","reason":<next-iteration EXECUTE instruction>}` ONLY when the session's own claim file
> points to a goal whose `status == "active"`. In-session auto-continuation runs up to the harness's
> ~8-consecutive-block cap (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`); past that the resume cron picks up.
> **`goal-scope-check.sh` is ALSO now WIRED (2026-05-29)** as an `Edit|Write` PostToolUse hook, rewritten
> claim-scoped + Windows-path-robust + fail-open: it reverts ONLY the just-edited file, ONLY for the session
> whose claim owns the active goal, ONLY when that file is outside `scope_lock`+`scope_flex` — so it is safe to
> leave on (a non-goal session has no claim and is never touched; verified in git-bash). Still opt-in: only the
> cross-session resume cron (schedule via CronCreate for long goals). `goal-continue.sh` remains the cron/manual
> resume target, **NOT** a Stop hook (wiring it as one recurses — a `-p` child fires its own Stop hooks). Net:
> in-session never-stop + scope-lock + budget auto-extend + state integrity + immutable objective + negative
> knowledge ARE enforced; only the cross-session resume cron remains opt-in.
>
> **Stop-hook output schema (verified vs code.claude.com/docs/en/hooks, 2026-05-29 — the earlier code was WRONG):**
> to continue, emit exit 0 + `{"decision":"block","reason":<USER note>,"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":<the instruction CLAUDE reads>}}`.
> `reason` is shown to the USER only; the next-iteration instruction MUST live in `additionalContext` or Claude is
> blocked-but-unguided (the bug that was fixed this session). **Matchers match the TOOL NAME only** (`Edit|Write`,
> `Bash`, `*` = all); arg-patterns like `Edit:*.test.*` / `Bash:*rm -rf*` NEVER match — use the per-handler `if`
> field (`Edit(*.test.*)`, `Bash(rm -rf *)`) for argument filtering. PostToolUse cannot block (exit 2 only surfaces
> stderr to Claude); PreToolUse blocks on exit 2 (NOT exit 1). NOTE: the repo's pre-existing `.env` + `rm -rf`
> PreToolUse guards use the bad arg-matcher AND exit 1 → they currently never fire (a real safety hole, flagged).

- **Scope lock** *(WIRED 2026-05-29, claim-scoped)*: `goal-scope-check.sh` PostToolUse (`Edit|Write`) hook — claim-scoped (acts ONLY for the session owning the active goal, via stdin `session_id` → `session-<id>.goal`); reverts ONLY the just-edited file (from `tool_input.file_path`, normalizes Windows `C:\`/`/c/` paths) when it is outside `scope_lock`+`scope_flex`; fail-open on any uncertainty. A non-goal session (no claim) is NEVER touched (verified). **Caution:** for a CLAIMED goal session a too-narrow `scope_lock` will revert legitimate out-of-scope edits — keep `scope_flex` accurate.
- **State integrity**: `goal-update-state.sh` (lockdir + validate + atomic rename + `.bak`)
- **Immutable objective**: objective string NEVER changes after creation
- **Criteria revision**: criteria CAN be revised during UNDERSTAND if auto-generated, but are frozen after iteration 1
- **Budget**: auto-extends by +5 when exhausted — never stops the loop. Budget is a progress counter, not a limit.
- **Negative knowledge**: append-only, tag-matched, blocks retries. Each entry MUST include the failure mechanism (WHY), not just "it failed". Format: `"tag": "approach-name", "detail": "WHY: <specific mechanism>. WHAT BROKE: <specific items/metrics>. AVOID: <what future approaches must not do>"`. Rich negative knowledge prevents repeating the same structural mistake with a different surface-level approach.
- **Max turns**: `--max-turns` in loop runner (default 30, configurable)
- **Criterion safety**: 60s timeout + dangerous pattern blocking
- **Fan-out scope**: dynamic-workflow / parallel-Agent units inherit `scope_lock` — `goal-scope-check.sh` reverts out-of-scope edits from subagents too *(only when that hook is wired — it is NOT by default; see wiring note above)*. Spawning 2+ committing agents requires worktree isolation + a parallel-safety gate pass (if you have one).
- **Skill autonomy**: only Tier-1 skills are invoked directly; Tier-2/3 run inside sub-Agents or with `SPAWNED_SESSION=true` so they never block on `AskUserQuestion`. The runner exports `SPAWNED_SESSION=true` and allows `Agent,Skill`.

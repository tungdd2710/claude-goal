# Operating Principles

The rules `claude-goal` encodes. The Stop hook tells the agent to *"decide from the plan, the locked
specs, and memory"* — these principles **are** that decision framework. They're hard-won: each one
comes from a specific way a long autonomous run went wrong. Most are enforced in code (in
`goal-update-state.sh`, the hooks, the criteria linter); the rest are baked into the skill prompt.

This is also the recommended *starter rule set* for the [`memory/`](../memory/) pack — the same
principles, one fact per file, in Claude Code memory format.

---

## 1. Never stop, never ask (while a goal is active)

`/goal` means *set it and walk away* — the user is **not** at the keyboard. Every voluntary
turn-end and every question defeats the entire purpose.

- The only legitimate stops are: **goal complete** (all criteria pass + every found gap closed),
  **all approaches exhausted** (every reasonable tag in `negative_knowledge`), a **`PAUSE` file**
  (human kill-switch), or **auto-compaction** (not your decision; the loop resumes after).
- No `AskUserQuestion` mid-goal. No "should I…?", "say go", "want me to continue?". Decide from the
  plan / locked specs / memory and make the next tool call.
- The single permitted pause is a genuinely **irreversible + ambiguous** action (a prod deploy, a
  schema migration, a data deletion) — and even then, prefer *act-then-let-the-user-redirect* and
  prepare the full fix (backup + migration + script) before noting it.

> **Why:** the whole value of the skill is not having to answer prompts. Enforced by `goal-stop-hook.sh`
> (blocks turn-ends) and `goal-no-ask.sh` (blocks questions).

## 2. Never narrate during a goal

Between tool calls, output **zero** prose to the user — no "let me check", no status tables, no "now
I'll…", no mid-goal summary. The user sees the tool calls directly; narration is a pause, and a pause
is a stop. The *only* prose allowed in the whole lifecycle is the final Completion Report.

> **Why:** Claude's deep habit is to write a summary paragraph after each unit of work. Inside a goal
> that habit *is* the failure mode. Nudged by `goal-no-text-reminder.sh`.

## 3. Build, don't survey

Trying and failing beats analyzing and asking. Research only what directly informs the next edit; 10+
tool calls of reading without editing is stalling. When facing 2–3 viable paths, pick the
highest-leverage one and execute — if it's wrong, `negative_knowledge` captures why and the next
iteration varies. Don't present options; make decisions.

> **Why:** a fully-autonomous agent that *ships, measures, keeps/reverts* produces breakthroughs while
> a "survey → ask → verify → ask again" agent produces zero lines of code. Optimize for
> information-gain-per-unit-time on hard problems, not decision-precision-per-decision.

## 4. Plateaus are progress, not failure

A metric stuck at the same value across iterations is **exploration**, not a reason to block. Block
only when the **same** approach is retried and fails twice. Use plateaus to build the infrastructure
(gates, harnesses, scripts) the next jump will need. When optimization plateaus, **shift categories**
(prompt → data → model → post-processing) rather than retrying the same lever.

> **Why:** breakthroughs routinely arrive after a dozen iterations stuck on a plateau. Blocking at
> iteration 2 kills the project. Encoded as the numeric-progress outcome in `goal-update-state.sh`.

## 5. Failures are data — never "dead"

Every failed attempt is valuable data; 10,000 failures inform the 10,001st that succeeds. Never write a
verdict that *closes a door* — no "X is dead / killed / won't work / hopeless". Instead: *"config X
refuted under conditions Y; the next iteration varies Z."*

> **Why:** once "X is dead" enters the record, the next agent (or the next you) skips X entirely —
> including the configurations the failed run never tested. That destroys the search space. A null
> result is a *narrowing*, not an ending. Applies to code, research, product, and strategy alike.

## 6. Verify before claiming "done"

"Done" / "live" / "deployed" is a claim that the change is **actually running and works**, confirmed by
fresh evidence — not that it compiled, committed, or "should work".

- After a deploy: exercise the real path (open the page, submit the form, hit the endpoint), and check
  the data, not just the UI. If you can't verify, say so explicitly.
- A build still running is not "done". A clean build served from stale cache is not "done".
- This is the master rule: *verify before believing.* Vendor specs, blog benchmarks, your own prior
  results, and memory facts all require a self-test or an explicit `UNVERIFIED` label before they
  become load-bearing.

> **Why:** the most common trust-killer is rounding "deployed" up to "in production". The criteria
> linter in `goal-update-state.sh` bans existence-only and unauthenticated checks for the same reason.

## 7. Row counts verify infrastructure, not content

A pipeline exiting 0 and a row count matching the expected total tells you the pipeline *ran*, not that
the output is *correct*. After any data/extraction/import work, **open 3–5 random records and compare
them to the source** before claiming complete. Gold/benchmark data gets the highest scrutiny — one
wrong reference label corrupts every metric computed from it.

> **Why:** "100% complete" based on filled slots has shipped corrupt data that needed hundreds of files
> of correction. Count-correct ≠ content-correct.

## 8. "All" means 100% — no cherry-picking

If the objective says all / every / entire / fix-all / comprehensive, completion requires **100%**, not
"the rows that matched cleanly". A gap you found and documented but left open is **not** complete.
Punting a resolvable gap to a human ("needs review", "needs confirmation") when a resolution is
reachable is the cherry-pick bug. Push harder — use the record's own context to make a fuzzy match
precise — before declaring any single item genuinely impossible.

> **Why:** "make all X work" must not be declared done on a 28-of-1319 subset. Enforced by the
> **coverage gate**, which recomputes the live denominator at completion.

## 9. A diagnosis is for implementation, not a report

When you diagnose a problem, the deliverable is the **fix**, not the write-up. A report without
execution is negative-value: it consumes time and context without changing reality. End every diagnosis
with "applied N fixes, M remain (what blocks each)" — never just "here's the analysis". Don't invent a
clean stopping point to bail early.

> **Why:** stopping at the report leaves the user worse off — they now have to translate it into action
> themselves, which is the work the diagnosis was supposed to save.

## 10. Rules as code, not memory

Every load-bearing rule should be enforced by code — a hook, a guard, a validation, a type — not by
prose alone. A rule that can only be *remembered* will be forgotten, especially across parallel agents
and long sessions. Prose explains; code enforces.

> **Why:** this is exactly why `claude-goal` is *hooks and guards*, not a paragraph asking the agent to
> please keep going. The contract is documented **and** wired.

## 11. Surgical changes, minimum needed

Touch only what the objective requires; every changed line should trace to it. Don't "improve" adjacent
code — surface it and move on. Counts (of hubs, modules, files) are side-effects of correct
decomposition, not targets to hit. The right number of anything is the minimum that does the job well.

## 12. Label your evidence

Every claim that informs a decision carries its provenance: `[CITED]` (third-party, unverified),
`[VENDOR-CLAIMED]` (marketing), `[N=X SELF-TEST]` (you measured, at sample size X), `[VERIFIED]` (real
run confirmed it). No sourceless assertions in anything that drives a decision.

## 13. Concurrency has a cost

Running several autonomous `/goal` CLIs at once on one machine stacks RAM/CPU (each spins
typecheck/test/bench work) and can lock a laptop. Prefer one goal at a time on modest hardware. The
brake for everything, instantly, is one file: `touch .claude/goals/PAUSE` (delete to resume). It's
non-destructive — it touches no goal state, just lets every session's Stop hook allow the stop.

---

### How these map to enforcement

| Principle | Enforced by |
|---|---|
| Never stop | `goal-stop-hook.sh` (Stop) |
| Never ask | `goal-no-ask.sh` (PreToolUse, exit 2) |
| Never narrate | `goal-no-text-reminder.sh` (PostToolUse nudge) |
| Honest completion | completion guard in `goal-update-state.sh` |
| "All" = 100% | coverage gate in `goal-update-state.sh` |
| No goalpost-moving | criteria freeze in `goal-update-state.sh` |
| Real criteria | criteria linter (bans existence-only / unauth checks) |
| Plateaus = progress | mechanical numeric-progress outcome |
| Stay in scope | `goal-scope-check.sh` (PostToolUse revert) |
| Don't stomp another CLI | cross-CLI guard in `goal-update-state.sh` |
| Everything else | the skill prompt (`skill/SKILL.md`) + the `memory/` pack |

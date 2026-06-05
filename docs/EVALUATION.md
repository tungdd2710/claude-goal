# Honest evaluation & limitations

A clear-eyed assessment of `claude-goal` — what works, what's fragile, what's unverified, and when
**not** to use it. This applies the repo's own principles ([label your evidence / verify before
believing](PRINCIPLES.md)) to the skill itself. If you only read one doc before trusting this with a
long autonomous run, read this one.

## Evidence labels used below

- **[VERIFIED]** — tested in this repo during development (syntax, functional smoke tests, fresh
  install). Reproducible from the commands in this doc.
- **[DESIGN-CLAIM]** — the mechanism is implemented and reasoned-through, but **not** benchmarked in
  this de-branded packaging. It worked in the production codebase this was extracted from; it has not
  been re-measured here across many goals.
- **[UNVERIFIED]** — depends on your environment / Claude Code internals and should be confirmed on
  your setup.

## Maturity

This is an **extraction**, not a from-scratch release. The engine ran real multi-hour, multi-session
goals in a private production codebase. In this public, de-branded form:

- The scripts, hooks, install, and guards are **[VERIFIED]** at the unit level (they parse; the
  installer wires correctly and is idempotent; the criteria/coverage/completion guards fire; the danger
  filter blocks footguns while allowing safe criteria; the statusline and state mutations work).
- The **end-to-end autonomous loop completing a real goal on a fresh install of this repo** is
  **[DESIGN-CLAIM]** — it has not been benchmarked here. There is **no success-rate data** for "given N
  real objectives, M completed correctly unattended." Treat early runs as experiments: small, well-scoped
  goals with strong criteria, watched for the first few iterations.

## What it does well

- **[VERIFIED] Removes the stop-to-ask reflex.** The Stop hook + no-ask + no-narration hooks genuinely
  change session behavior so the agent keeps working instead of pausing. This is the core value and it
  is real and testable.
- **[VERIFIED] Honest-completion guards.** It cannot mark a goal complete with failing criteria, with
  zero criteria, or (for "all/every" goals) below a live-recomputed coverage denominator. These are
  enforced in code, not prose — you can't talk it into declaring victory.
- **[VERIFIED] Safe to wire globally.** Every hook is claim-scoped + fail-open: a session that never
  started a goal is untouched, and any uncertainty defaults to *allowing* the stop. A non-goal session
  cannot be wedged.
- **[DESIGN-CLAIM] Survives compaction and resumes across sessions** via `context_summary` + the cron.
- **[DESIGN-CLAIM] Plateau-aware progress** keeps long numeric-target climbs from false-blocking.

## Limitations & failure modes (read these)

1. **[UNVERIFIED] Claim-file fragility — the single biggest dependency.** The Stop hook only
   auto-continues a session whose `.claude/goals/session-<id>.goal` claim matches the `session_id` the
   hook receives on stdin. That requires `CLAUDE_CODE_SESSION_ID` to be exported into the agent's shell
   **and** to equal the hook's stdin session id. `goal-init.sh` now writes the claim automatically to
   harden this, but if your Claude Code build doesn't export that variable, the in-session never-stop
   loop won't engage (you fall back to the cron, which is coarser). **Verify on your setup:** start a
   goal, then check that `.claude/goals/session-*.goal` exists.

2. **[VERIFIED] In-session continuity is bounded.** Claude Code overrides a Stop hook after ~8
   consecutive blocks (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`). Past that, continuation relies on the
   resume cron — so true multi-hour autonomy depends on the cron being scheduled, not just the hook.

3. **"Honest completion" is only as honest as your criteria.** The guards prevent *talking past*
   criteria, but they can't make weak criteria strong. If your criteria are shallow ("server returns
   200"), "complete" is shallow. The skill mitigates (bans existence-only/unauthenticated checks,
   requires ≥1 user-facing check) but **cannot guarantee** your criteria actually prove success — that's
   on you (see [TAILORING.md](TAILORING.md)).

4. **[VERIFIED] No budget cap = real cost.** By design the budget auto-extends; a goal can run for many
   iterations across hours, and fan-out multiplies token spend. There is no built-in spend ceiling.
   Treat `/goal` as launching a long job. The only hard stop is you (`PAUSE`) or genuine completion.

5. **It writes code and git history autonomously.** Per-unit commits on a `goal/<slug>` branch. Good
   for traceability, but it *is* unattended commit activity — review the branch before merging.

6. **[VERIFIED] Concurrency is resource-heavy.** Several autonomous goals on one machine stack
   typecheck/test/bench load and can lock a laptop. Prefer one at a time on modest hardware.

7. **[VERIFIED] The criterion sandbox is not a security boundary.** Criteria run arbitrary shell under
   your account; the danger-pattern filter is best-effort (catches `rm -rf`, `mkfs`, fork-bombs,
   `sudo`, force-push, …) but a determined or unlucky command can slip past. Only put commands you
   trust into a goal's criteria.

8. **[UNVERIFIED] Tied to Claude Code hook semantics.** The engine depends on the documented behavior
   of `Stop`/`PreToolUse`/`PostToolUse` hooks (block schema, exit codes, matcher = tool-name-only). If
   a future Claude Code version changes these, the engine needs updating. Verified against the hooks
   docs at extraction time; re-check after major Claude Code upgrades.

9. **[VERIFIED] Scope-lock has rough edges (which is why it's opt-in).** A too-narrow `scope_lock`
   reverts legitimate edits; path normalization handles Git-Bash `/c/...` but WSL `/mnt/c/...` falls
   through to fail-open (no revert) rather than enforcing. Enable it deliberately, keep `scope_flex`
   accurate.

10. **No telemetry / no guarantee of "good" work.** The loop verifies *criteria*, not *taste*. It can
    satisfy every criterion and still produce code you'd reject in review. It is a control harness, not
    a quality oracle.

## When NOT to use it

- Vague creative work with no verifiable "done".
- Irreversible one-shot operations (the contract pauses for these, but don't rely on the loop's judgment
  of what's irreversible — keep prod migrations/deletes out of the autonomous path).
- Anything where you actually want to be consulted each step.
- Cost-sensitive contexts without supervision (no budget cap).

## How to evaluate it yourself (recommended)

1. Install into a throwaway/test project. Confirm the claim file appears (`.claude/goals/session-*.goal`)
   after `/goal` — that proves the engine will engage on your setup (limitation #1).
2. Start with a **small, well-scoped** goal with **strong, user-facing criteria** (see TAILORING.md).
3. Watch the first 3–4 iterations. Confirm it (a) doesn't stop to ask, (b) commits per unit, (c) the
   completion guard actually blocks a premature complete.
4. Keep `touch .claude/goals/PAUSE` ready as the kill switch.
5. Only after you trust it on small goals should you hand it a long unattended run — and even then,
   review the `goal/<slug>` branch before merging.

## Reproducing the [VERIFIED] claims

From a clone:
```bash
for f in scripts/*.sh install.sh; do bash -n "$f"; done   # all parse
node --check scripts/goal-statusline.js                   # statusline valid
bash scripts/goal-check-criterion.sh "rm -rf ~" d         # exit_code -2 (blocked)
bash scripts/goal-check-criterion.sh "echo 0.9" m         # value 0.9 extracted
bash install.sh /tmp/throwaway-git-repo                    # wires 3 core hooks + statusline
```

## Bottom line

`claude-goal` is a **solid, code-enforced control harness** for autonomous goal loops, honestly built
and honestly guarded — but it is an **extraction without fresh end-to-end benchmarks**, its core
autonomy depends on a Claude-Code-specific env/claim mechanism you should verify on your setup, and its
"completion" is only as trustworthy as the criteria you give it. Use it the way you'd use any powerful
unattended automation: start small, verify on your stack, keep the kill switch in reach.

---
name: concurrent-goals-pause-brake
description: Multiple concurrent autonomous /goal CLIs on one machine stack RAM/CPU (each spins typecheck/test/bench work) and can lock it. The brake is one file — touch .claude/goals/PAUSE — which every session's Stop hook honors before any goal logic.
metadata:
  type: feedback
---

Running 2+ autonomous `/goal` CLIs at once on a single machine combines their load (each loop spins
typecheck / test / benchmark work + may spawn subagents) and can lock the machine. Prefer one goal at a
time on modest hardware.

**Why:** the culprit processes die with the session that spawned them, so a post-hang scan looks
misleadingly calm — but any *other* still-live CLI keeps loading the machine and will re-hang it.

**How to apply (recovery runbook):**
1. **Brake first:** `touch .claude/goals/PAUSE`. Every session's Stop hook checks for `PAUSE` *before*
   any goal logic → all auto-continuation halts. Non-destructive; `rm` it to resume. It stops the next
   continuation, not a tool call already in flight.
2. The Stop hook is claim-scoped + fail-open: a fresh recovery session has no claim and never
   auto-continues; the risk is only the other live CLIs.
3. `index.json` can drift from `goal-<id>.json` after crashes — reconcile, but don't flip a goal a
   concurrent live CLI still claims.
4. Reduce concurrency — closing extra terminals is the fix, not more code.

Related: [[goal-means-never-stop-never-ask]]

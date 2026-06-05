---
name: all-means-100-percent
description: "fix all / every / entire / comprehensive" means 100%, not "the rows that matched cleanly". A gap you found and documented but left open is NOT complete. Punting a resolvable gap to a human is the cherry-pick bug. The coverage gate enforces the live denominator.
metadata:
  type: feedback
---

When the objective says all / every / entire / fix-all / comprehensive, completion requires **100%** —
not a clean subset. A gap you found and documented but left open is **not** complete. Punting a
resolvable gap to a human ("needs review", "needs confirmation") when a resolution is reachable is the
cherry-pick stop-bug.

**Why:** "make all X work" must not be declared done on a small subset of the real population. The
coverage gate recomputes the live denominator from the codebase at completion, so the count can't be
substituted with a smaller one.

**How to apply:**
- Register a coverage gate at iteration 1 for any "all" objective: `--set-coverage COVERED_CMD TOTAL_CMD`
  where TOTAL_CMD computes the live denominator.
- Push harder before giving up on a gap — use the record's own context to make a fuzzy match precise.
  Only a single item with genuinely zero usable signal may be proven impossible (and logged as such).
- Never stop at "documented" when the goal could fix it.

Related: [[goal-means-never-stop-never-ask]], [[rules-as-code]]

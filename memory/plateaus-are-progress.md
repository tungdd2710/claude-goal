---
name: plateaus-are-progress
description: A metric stuck flat across iterations is exploration, not failure. Block only when the SAME approach fails twice. Use plateaus to build infrastructure; when optimization plateaus, shift categories.
metadata:
  type: feedback
---

A numeric goal that isn't moving yet is on a **plateau**, which is exploration — not a reason to block.
Block only when the *same* `approach_tag` is retried and fails twice. Different approaches at the same
metric value = legitimate search.

**Why:** breakthroughs routinely arrive after many iterations stuck at the same number. Blocking at
iteration 2 kills the project before the jump. (The mechanical outcome engine counts a climb toward
target as `progress` even before it passes, for exactly this reason.)

**How to apply:**
- During a plateau, build the infrastructure the next jump needs (gates, harnesses, scripts, data) —
  that is real progress even when the metric is flat.
- When one category of approach plateaus, **shift category**: prompt → data → model → post-processing.
  Don't keep retrying the same lever.
- Try two different things minutes apart instead of analyzing which to try.

Related: [[build-dont-survey]], [[failures-are-data]]

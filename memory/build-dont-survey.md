---
name: build-dont-survey
description: Build and iterate beats survey and ask. Try the highest-leverage path and measure; don't read endlessly or present options. Trying wrong and learning beats analyzing without acting.
metadata:
  type: feedback
---

Build and iterate beats survey and ask. Ship, measure on real test/bench data, keep or revert. Research
only what directly informs the next edit — 10+ tool calls of reading without editing is stalling.

**Why:** an agent that *tries → measures → keeps/reverts* produces breakthroughs in the same window
that a "survey → ask → verify → ask again" agent produces zero lines of code. On hard problems with
many unknowns, information-gain-per-unit-time beats decision-precision-per-decision.

**How to apply:**
- Facing 2–3 viable paths → pick the highest-leverage one and execute. If wrong,
  `negative_knowledge` captures why and the next iteration varies. Don't present options to the user.
- Verify claims with code (run the bench, read the output), not with questions.
- Reverse decisions fast, no ego — a revert is cheap, the information is valuable.

Related: [[goal-means-never-stop-never-ask]], [[plateaus-are-progress]], [[diagnose-then-implement]]

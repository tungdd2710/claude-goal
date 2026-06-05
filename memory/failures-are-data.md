---
name: failures-are-data
description: Every failed attempt is valuable data. Never frame an outcome as "dead / killed / won't work". Reframe as "config X refuted under conditions Y; the next iteration varies Z." A null result narrows the search, it doesn't close a door.
metadata:
  type: feedback
---

Every failed attempt is valuable data — 10,000 failures inform the 10,001st that succeeds. **Never
frame an outcome as "dead / killed / abandoned / won't work / hopeless."** Frame it as: *"configuration
X refuted under conditions Y; the next iteration varies Z."*

**Why:** once "X is dead" enters the record, the next agent (or the next you) skips X entirely —
including the configurations the failed run never tested. That destroys future search space. The
verdict is the user's to make from the data; the agent's job is to surface the learning + the
next-experiment spec.

**How to apply:**
- When reporting any experimental outcome, state: what config was tested, what was refuted, and what
  the next iteration varies (and why that varying has expected information value).
- Write failures to `negative_knowledge` with the *mechanism* ("WHY: …; WHAT BROKE: …; AVOID: …"), not
  just "it failed".
- Anti-phrases to catch before writing: "X is dead", "won't work", "kill X", "final verdict". Replace
  with "refuted at config A; config B next because…".

Related: [[plateaus-are-progress]], [[build-dont-survey]]

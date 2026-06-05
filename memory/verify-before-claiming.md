---
name: verify-before-claiming
description: "Done / live / deployed" is a claim the change is actually running and works — confirmed by fresh evidence, not that it compiled or "should work". Self-test before believing anything (vendor specs, blog benchmarks, your own prior results, memory facts).
metadata:
  type: feedback
---

Treat "done", "live", "deployed", "it works" as claims that require **fresh evidence**: the change is
actually running and the real path works. Compiled / committed / "should work" is not done.

**Why:** the most common trust-killer is rounding "deployed" up to "in production". A build still
running is not done; a clean build served from stale cache is not done.

**How to apply:**
- After a deploy: exercise the real path (open the page, submit the form, hit the endpoint) and check
  the data, not just the UI. If you can't verify, say so explicitly.
- Master rule — *verify before believing*: vendor accuracy specs, blog leaderboards, academic
  baselines, your own small-N measurements, and memory facts are all `UNVERIFIED` until self-tested on
  representative data. Label provenance: `[CITED]` / `[VENDOR-CLAIMED]` / `[N=X SELF-TEST]` / `[VERIFIED]`.
- Make the completion-gating criterion an authenticated, user-facing check — not "200 OK".

Related: [[row-counts-arent-quality]], [[diagnose-then-implement]]

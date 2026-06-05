---
name: row-counts-arent-quality
description: Pipeline exit-0 and row counts verify infrastructure, not content. Spot-check 3-5 random records against source truth before claiming an extraction/import/data task complete. Gold/benchmark data gets the highest scrutiny.
metadata:
  type: feedback
---

A pipeline exiting 0 and a count matching the expected total tells you the pipeline *ran* — it says
nothing about whether the content is *correct*. After any data / extraction / import / corpus task,
open 3–5 random records and compare them to the source before claiming complete.

**Why:** "100% complete" based on filled slots has shipped mismatched answers, typos, and wrong content
types that needed hundreds of files of correction. Count-correct ≠ content-correct.

**How to apply:**
- Sample random records, read the actual text, compare to source. "Count matches" is necessary, never
  sufficient.
- Gold / benchmark / reference data gets the highest verification standard — one wrong reference label
  corrupts every metric computed from it.
- If verification would "slow the milestone", do it anyway — a fast wrong result costs more than a slow
  right one.

Related: [[verify-before-claiming]], [[diagnose-then-implement]]

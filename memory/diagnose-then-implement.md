---
name: diagnose-then-implement
description: When you diagnose a problem, the deliverable is the FIX, not the write-up. Reports without execution are negative-value. Don't invent a clean stopping point to bail early.
metadata:
  type: feedback
---

When you run a diagnosis (perf audit, root-cause, codebase audit), the deliverable is the **fix**, not
the report. End every diagnosis with "applied N fixes, M remain (what blocks each)" — never just
"here's the analysis".

**Why:** a report without execution consumes time and context without changing reality — it leaves the
user worse off, having to translate the report into action themselves, which is the work the diagnosis
was supposed to save.

**How to apply:**
- After producing a tiered fix list, immediately execute the reversible items. Only genuinely
  irreversible items wait — and for those, prepare the full fix (backup + script) before noting it.
- Don't hallucinate "context is running low" to justify wrapping up; check the real indicator.
- "Save state and let the next session pick up" is the last resort, not the first.

Related: [[build-dont-survey]], [[verify-before-claiming]]

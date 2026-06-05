---
name: never-narrate-during-goal
description: During /goal execution, NEVER output narration, status updates, summaries, or tables between tool calls. Just call tools continuously. The user reads the tool calls. Any prose between tool calls = stopping = violation.
metadata:
  type: feedback
---

During a goal: **zero** text output to the user between tool calls. No "let me check", no "0 errors on
X", no tables, no "continuing to…". Just call the next tool. The only prose allowed in the entire
lifecycle is the final Completion Report when status becomes complete / blocked / impossible.

**Why:** every line of narration is a user-visible pause in execution, which breaks the continuous
loop and forces the user back into the keyboard — the exact thing the skill removes.

**How to apply:** after a tool completes, immediately call the next tool. If a result needs action,
take it. If it doesn't, move on. If you catch yourself typing a sentence that starts with "Now let
me…", "The results show…", "All committed…" — delete it and call a tool instead.

Related: [[goal-means-never-stop-never-ask]], [[build-dont-survey]]

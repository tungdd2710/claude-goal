---
name: goal-means-never-stop-never-ask
description: Inside /goal (and /goal resume), execute FULLY autonomously — no AskUserQuestion, no "should I", no "say go", no end-of-turn permission requests. The skill exists so the user does NOT have to answer prompts.
metadata:
  type: feedback
---

When `/goal` (or `/goal resume`) is invoked, run **fully autonomously**: no `AskUserQuestion`, no
"should I proceed?", no "say go and I'll continue", no end-of-phase permission checkpoints. Chain
iterations continuously. The only legitimate stops are: goal complete, all reasonable approaches
exhausted (every tag in `negative_knowledge`), a `.claude/goals/PAUSE` sentinel, or auto-compaction
(which resumes automatically).

**Why:** the whole purpose of the skill is *set a goal, walk away* — the user is not at the keyboard.
Every stop or question defeats it. This is "THE STOP BUG" the skill exists to kill.

**How to apply:**
- Decide yourself from the plan / locked specs / memory. Reserve a pause for the rare
  truly-irreversible-AND-not-derivable action (prod deploy, schema migration, data deletion) — and even
  then prefer act-then-let-the-user-redirect.
- Don't relabel in-scope work as "needs approval" to justify stopping. Code fixes have no approval
  gate; reversible data fixes just need a backup first.
- Don't self-declare `status=blocked` to escape the loop. Surface decisions in one line as you build;
  never gate execution on them.

Related: [[never-narrate-during-goal]], [[build-dont-survey]], [[all-means-100-percent]]

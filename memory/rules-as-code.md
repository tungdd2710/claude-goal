---
name: rules-as-code
description: Every load-bearing rule must be enforced by code (hook / guard / check / type), not by prose alone. A rule that can only be remembered will be forgotten — especially across parallel agents and long sessions.
metadata:
  type: feedback
---

Every load-bearing rule must be enforced by something other than human discipline — a hook, a CI gate,
a runtime guard, a type, a test fixture. Prose explains the rule; code enforces it.

**Why:** prose-only rules don't survive contact with parallel agents and multi-session work. Documenting
a rule in a doc and treating it as "shipped" is the anti-pattern — it isn't shipped until it's wired.

**How to apply:**
- For every new rule that emerges from a correction: identify the enforcement vector first (pre-commit
  hook? validation? assert? linter?). Implement that. Then add prose for context.
- This is why `claude-goal` is hooks + guards, not a paragraph asking the agent to keep going: the
  never-stop / never-ask / honest-completion / scope-lock rules are all wired, not just written.

Related: [[goal-means-never-stop-never-ask]], [[all-means-100-percent]]

# The memory convention

The Stop hook tells the agent to *"decide from the plan, the locked specs, and **memory**."* That
"memory" is Claude Code's file-based persistent memory — a directory of small Markdown files, one fact
each, that get recalled into future sessions. `claude-goal` ships a small **starter pack** of
skill-related memories (in [`../memory/`](../memory/)) so a fresh install already knows how a
goal-runner should behave.

This doc explains the convention so you can keep, extend, or replace the pack.

---

## The format

Each memory is **one file = one fact**, with YAML frontmatter:

```markdown
---
name: <short-kebab-case-slug>
description: <one-line summary — used to decide relevance during recall>
metadata:
  type: user | feedback | project | reference
---

<the fact. For feedback/project, follow with **Why:** and **How to apply:** lines.>

Related: [[other-memory-slug]]
```

- **`name`** — a stable kebab-case slug. Links between memories use `[[name]]`.
- **`description`** — the one-liner the agent scans to decide if this memory is relevant *right now*.
  Make it specific; this is what gets matched during recall.
- **`metadata.type`**:
  - `user` — who the user is (role, preferences, expertise).
  - `feedback` — how the agent should work (corrections and confirmed approaches). **Include the why.**
    The whole `claude-goal` starter pack is this type.
  - `project` — ongoing work/goals/constraints not derivable from the code or git history.
  - `reference` — pointers to external resources (URLs, dashboards, tickets).
- **`[[links]]`** — link related memories liberally. A link to a not-yet-written memory is fine; it
  marks something worth writing later.

## The index

`memory/MEMORY.md` is a flat index — **one line per memory**, no frontmatter, never any memory content
inline. It's the cheap-to-load table of contents that gets pulled into context each session:

```markdown
- [Title](slug.md) — one-line hook
```

## How the goal loop uses it

When the never-ask contract forbids stopping to ask, the agent's decision sources are, in order: the
**plan** (the goal's criteria/scope/reflections), any **locked specs** in your repo, and **memory**.
The starter pack pre-loads the goal-runner discipline (build-don't-survey, plateaus-are-progress,
verify-before-claiming, …) so the agent makes the *right* autonomous calls instead of guessing.

## Installing & extending the pack

The starter memories are plain Markdown — drop them into wherever your Claude Code keeps project
memory, and add a line per file to your `MEMORY.md` index. Then:

- **Add your own** as you correct the agent: when a `/goal` run does something you don't want, write a
  `feedback` memory capturing the *why*, and the next run won't repeat it.
- **Prefer rules-as-code:** if a rule is load-bearing, also encode it as a hook/guard/check — a memory
  alone will eventually be forgotten (see [`../memory/rules-as-code.md`](../memory/rules-as-code.md)).
- **Memories rot:** they reflect what was true when written. Before acting on one that names a file,
  flag, or number, verify it still holds.

> The pack is intentionally small and **skill-related only** — the discipline a goal-runner needs. It is
> not a dump of project-specific facts (those belong in *your* memory, not a shared tool).

# Tailoring claude-goal to your project & deploy system

`claude-goal` ships with sensible defaults, but the **criteria, gates, model, and deploy-verification
steps must point at *your* stack** to be worth anything. This is the most important customization — a
goal is only as honest as the criteria it checks itself against.

Nothing here requires editing the scripts. You tailor a goal through its **objective string**, its
**success criteria**, its **coverage gate**, a few **env vars**, and your **settings.json**.

---

## 1. Success criteria — make "done" mean done on YOUR stack

Iteration 1 auto-derives criteria, but you can (and for anything important, should) set them explicitly
at creation. Each criterion is a shell command that **exits 0 on success**.

```bash
bash .claude/scripts/goal-init.sh \
  --objective "Harden the billing API" \
  --scope "src/api/billing/" \
  --check "npx tsc --noEmit"                         --label "typecheck clean" \
  --check "npx vitest run src/api/billing"           --label "billing tests pass" \
  --check "curl -fsS -b ./cookie.txt localhost:3000/api/billing | python3 -c 'import json,sys; assert len(json.load(sys.stdin))>0'" --label "billing returns data (authed)" \
  --max 6
```

**Pick the right commands for your toolchain:**

| Check kind | Examples (swap in yours) |
|---|---|
| Typecheck | `npx tsc --noEmit` · `mypy .` · `go vet ./...` · `cargo check` |
| Tests | `npx vitest run <dir>` · `pytest tests/x` · `go test ./...` · `cargo test` |
| Lint / format | `npx eslint <dir>` · `ruff check .` · `golangci-lint run` |
| Build | `npm run build` · `cargo build --release` · `docker build .` |
| Structural grep (anti-pattern gone) | `! grep -rn "TODO: wire" src/` · `[ $(grep -rc "db.query(" src/ \| paste -sd+ \| bc) -eq 0 ]` |
| **User-facing (required)** | an **authenticated** request that asserts real content; a form POST that increases a DB row count; a page render that contains expected text |

**Banned by the criteria linter** (they pass without proving anything works):
- file-existence-only checks (`test -f route.ts`),
- unauthenticated status-code curls (`curl -o /dev/null -w '%{http_code}'`) — they only prove the
  server booted.

Always include **at least one user-facing criterion**. Typecheck + "200 OK" is necessary but never
sufficient.

### Numeric-target goals (climb toward a number)

For "accuracy ≥ 0.90", "p95 latency ≤ 200ms", "bundle ≤ 250KB", make the check **print the number as
its last stdout line** and add `target` + `direction`:

```bash
bash .claude/scripts/goal-update-state.sh --goal-id <id> --set-criteria \
  '[{"check":"node scripts/bench.js | tail -1","label":"accuracy","auto":true,"target":0.90,"direction":"gte"}]'
```

`direction`: `gte` (higher is better, default) or `lte` (lower is better — latency, error, size). A
climb toward target counts as *progress* even before it passes, so plateaus don't trip the block rule.

---

## 2. Coverage gate — for "fix all / every / entire" goals

If your objective says "all", register a coverage gate so completion requires 100%, recomputed live:

```bash
bash .claude/scripts/goal-update-state.sh --goal-id <id> --set-coverage \
  "grep -rLc 'orgId' src/api --include=route.ts | wc -l" \
  "find src/api -name route.ts | wc -l"
```

- **TOTAL_CMD** prints the live denominator from the codebase (e.g. *all* route files).
- **COVERED_CMD** prints how many you've verified-OK.
- Both re-run at completion; `covered < total` → can't complete. The denominator can't be faked.

---

## 3. Model & turns

| Knob | How | Default |
|---|---|---|
| Model | `export GOAL_MODEL=<model-id>` before `goal-loop.sh` / `goal-continue.sh`, or `--model <id>` | `claude-sonnet-4-6` |
| Turns per iteration | `goal-loop.sh --max-turns N` | 30 |
| Initial budget | `goal-init.sh --max N` (auto-extends anyway) | 5 |
| Block cap (in-session) | `export CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=<n>` | Claude Code default (~8) |

Use a stronger model for architecture/root-cause goals, a cheaper one for mechanical sweeps.

---

## 4. Deploy verification — the part most worth tailoring

The skill's **Completion Audit** says "act as a user for ~3 minutes on the real flow" and "verify the
deployed code path." That's deliberately stack-agnostic. Encode *your* deploy + verify as **criteria**
so the goal can't complete until the change is actually live and working. The shape is always:

> **build → push the new code to where it runs → restart/reload so the process picks it up → curl
> health (never 500) → exercise the real endpoint/page → only then: complete.**

Pick the row that matches your hosting and turn it into criterion commands:

### SSH + process manager (PM2 / systemd / supervisor)

```bash
# criterion: deploy + health
--check "ssh prod 'cd /srv/app && git pull && npm ci && npm run build && pm2 restart app --update-env' \
         && sleep 3 && curl -fsS -o /dev/null -w '%{http_code}' https://app.example.com/health | grep -qE '200|307'" \
--label "deployed + health green"

# criterion: the feature actually works (authenticated)
--check "curl -fsS -b ./prod-cookie.txt https://app.example.com/api/thing | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"ok\"]'" \
--label "feature works on prod"
```

> Tip: serialize prod SSH and builds if multiple agents/CLIs deploy (wrap the deploy in your own lock),
> and **grep a known string literal in the built artifact** to confirm the new code is actually served
> (a stale build cache can serve old bundles even after a "successful" deploy).

### Docker / docker-compose

```bash
--check "docker compose build app && docker compose up -d app && sleep 5 \
         && curl -fsS -o /dev/null -w '%{http_code}' localhost:8080/health | grep -q 200" \
--label "container rebuilt + healthy"
```

### Serverless (Vercel / Netlify / Cloud Functions)

```bash
--check "vercel deploy --prod --yes >/tmp/d.txt 2>&1 && url=$(grep -oE 'https://[^ ]+' /tmp/d.txt | tail -1) \
         && curl -fsS -o /dev/null -w '%{http_code}' \"$url/api/health\" | grep -q 200" \
--label "prod deploy healthy"
```

### Kubernetes

```bash
--check "kubectl apply -f k8s/ && kubectl rollout status deploy/app --timeout=120s \
         && curl -fsS -o /dev/null -w '%{http_code}' https://app.example.com/health | grep -q 200" \
--label "rollout complete + healthy"
```

**Two cautions baked into the principles:**
- A `migrate deploy` / destructive DB op is exactly the *irreversible* action the never-stop contract
  lets a goal pause for — gate it behind a backup, or keep it out of the autonomous criteria entirely.
- "deployed" ≠ "in production". Make the *user-facing* criterion (real authed request) the one that
  gates completion, not the health curl.

---

## 5. Long bench / GPU runs

For multi-minute benchmark or training iterations, follow the skill's `Multi-Day Persistence` guidance:

```bash
ssh <your-host> 'tmux new-session -d -s bench /tmp/run-bench.sh'   # survives disconnect
```

- **Early-kill gate (do it):** after ~10 items compute the partial metric; if worse than baseline by a
  meaningful margin → kill and pivot. Don't burn an hour on a known-bad config.
- **Don't poll in a loop.** Start the bench, check partial results once, then **build the next
  iteration's code** while it runs. Check the result at the next Orient step, not in a `grep -c` spin.

---

## 6. Gates & skill routing — map to what you have installed

The skill's routing tables are written generically ("a commit gate", "a QA skill"). Map them onto your
actual skills:

- Have a pre-commit/review gate skill? Invoke it before the loop commits.
- Have a QA / browser-test skill? It's interactive → the loop wraps it in a sub-Agent automatically.
- Have nothing? The loop just proceeds — the in-script guards still enforce criteria, coverage, and
  honest completion.

The rule is mechanical: a skill that **asks the user anything** is Tier 3 → wrapped in a sub-Agent
(which has no user channel, so it can't freeze the loop). A skill that **runs to completion** is Tier 1
→ called directly. See `skill/SKILL.md` → *Skill Routing During Execution*.

---

## 7. Cross-session resume (cron) — for multi-day goals

Schedule the durable resume once when you start a long goal, from inside Claude Code:

```
CronCreate(cron: "17 */2 * * *", durable: true, recurring: true,
  prompt: "/goal resume -- check .claude/goals/index.json for all active goals, resume each")
```

It fires every 2 hours and only acts if a goal is unclaimed/unfinished. Delete it when the goal
completes so it doesn't fire into an empty list. Within a running session you don't need it — the Stop
hook drives the loop.

---

## 8. Scope — keep edits where you want them

```bash
--scope "src/api/billing/,src/lib/money/"   # scope_lock: dirs the goal may edit
--flex  "src/lib/db/"                        # scope_flex: dependency dirs it may also touch
```

With `goal-scope-check.sh` wired, any edit outside `scope_lock`+`scope_flex` (including from
fanned-out subagents) is reverted. If a goal legitimately needs a new directory, add it to `scope_flex`
and redo the edit. Multiple concurrent goals **must** have non-overlapping `scope_lock`.

---

## Quick checklist

- [ ] Criteria use **your** typecheck/test/lint/build commands.
- [ ] At least one **authenticated, user-facing** criterion.
- [ ] Numeric goals print the metric + set `target`/`direction`.
- [ ] "All/every" goals have a **coverage gate** with a live denominator.
- [ ] Deploy verification (build → ship → restart → health → exercise) encoded as criteria for **your**
      hosting.
- [ ] Irreversible DB/prod ops kept behind a backup or out of the autonomous path.
- [ ] `GOAL_MODEL` set if you don't want the default.
- [ ] `scope_lock` / `scope_flex` set to your directories.
- [ ] Cron scheduled if the goal spans days.

#!/usr/bin/env bash
# goal-update-state.sh — Script-based state updates with validation + atomic backup
# v0.2.1: Added lockdir mutual exclusion + mechanical outcome computation.
#
# Usage:
#   bash .claude/scripts/goal-update-state.sh --status active
#   bash .claude/scripts/goal-update-state.sh --iteration 3 --approach "Added test for login" --approach-tag "add-login-test" --changes "src/auth.ts,src/auth.test.ts" --criteria-before '{"cov":false,"tests":true}' --criteria-after '{"cov":true,"tests":true}'
#   bash .claude/scripts/goal-update-state.sh --add-negative "middleware-wrapper" "Import cycle prevents wrapping"
#   bash .claude/scripts/goal-update-state.sh --status impossible --impossibility-reason "SDK cannot be mocked"
#   bash .claude/scripts/goal-update-state.sh --bump-budget 8
#
# Outcome is computed mechanically from criteria-before/after (not caller-supplied).
# Always validates before writing. Keeps .bak copy. Uses lockdir for mutual exclusion.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RESOLVE="$REPO_ROOT/.claude/scripts/goal-resolve.sh"
VALIDATE="$REPO_ROOT/.claude/scripts/goal-validate.sh"

# Extract --goal-id if first arg (before passing remaining args to python)
_GID_ARG=""
if [[ "${1:-}" == "--goal-id" ]]; then
  _GID_ARG="$2"
  shift 2
fi

GOAL_FILE=$(bash "$RESOLVE" ${_GID_ARG:+--goal-id "$_GID_ARG"})
BACKUP_FILE="${GOAL_FILE}.bak"
LOCKDIR="${GOAL_FILE}.lock"

# Acquire lock (mkdir is atomic on all platforms)
LOCK_ATTEMPTS=0
while ! mkdir "$LOCKDIR" 2>/dev/null; do
  LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
  if [[ $LOCK_ATTEMPTS -ge 100 ]]; then
    echo "Could not acquire lock after 100 attempts. Stale lock? rm -rf $LOCKDIR" >&2
    exit 1
  fi
  sleep 0.1
done
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

# Validate current state first
if ! bash "$VALIDATE" "$GOAL_FILE" >/dev/null 2>&1; then
  if [[ -f "$BACKUP_FILE" ]]; then
    echo "State file corrupt. Restoring from backup." >&2
    cp "$BACKUP_FILE" "$GOAL_FILE"
    if ! bash "$VALIDATE" "$GOAL_FILE" >/dev/null 2>&1; then
      echo "Backup also corrupt. Manual intervention required." >&2
      exit 1
    fi
  else
    echo "State file corrupt and no backup. Manual intervention required." >&2
    exit 1
  fi
fi

# Atomic backup before any mutation
cp "$GOAL_FILE" "$BACKUP_FILE"

# COVERAGE GATE (bash — runs count commands natively; this Python cannot spawn bash reliably on Windows).
# An all/every objective CANNOT be marked complete on a subset: covered must be >= the LIVE total.
_WANT_COMPLETE=0; _PREV=""
for _a in "$@"; do [ "$_PREV" = "--status" ] && [ "$_a" = "complete" ] && _WANT_COMPLETE=1; _PREV="$_a"; done
if [ "$_WANT_COMPLETE" = "1" ]; then
  _COVINFO=$(python3 -c "
import json,sys
g=json.load(open(sys.argv[1]))
obj=(g.get('objective') or '').lower()
allg = obj.startswith('all ') or any(t in obj for t in ('all function','make all','fix all','do all','every ','each ','entire','comprehensive',' all '))
cov=g.get('coverage') or {}
print('ALL' if allg else 'NOTALL')
print(cov.get('covered_cmd') or '')
print(cov.get('total_cmd') or '')
" "$GOAL_FILE")
  _ISALL=$(printf '%s' "$_COVINFO" | sed -n 1p)
  _COVCMD=$(printf '%s' "$_COVINFO" | sed -n 2p)
  _TOTCMD=$(printf '%s' "$_COVINFO" | sed -n 3p)
  if [ "$_ISALL" = "ALL" ]; then
    if [ -z "$_COVCMD" ] || [ -z "$_TOTCMD" ]; then
      echo "CANNOT COMPLETE: objective says ALL/EVERY but no COVERAGE GATE set. Define: goal-update-state.sh --set-coverage COVERED_CMD TOTAL_CMD (total computed live from the codebase). Completion needs covered >= total — no subset." >&2
      exit 1
    fi
    _COVN=$(bash -c "$_COVCMD" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    _TOTN=$(bash -c "$_TOTCMD" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    if [ -z "$_COVN" ] || [ -z "$_TOTN" ]; then
      echo "CANNOT COMPLETE: coverage gate command produced no number (covered=$_COVN total=$_TOTN)." >&2
      exit 1
    fi
    if [ "$_COVN" -lt "$_TOTN" ]; then
      echo "COVERAGE CHERRY-PICK BLOCKED: covered $_COVN of $_TOTN. Objective says ALL — verify/fix the remaining $((_TOTN-_COVN)) before completing. No subset." >&2
      exit 1
    fi
  fi
fi

# Parse args and apply mutation
python3 -c "
import json, sys, os
from datetime import datetime, timezone

goal_file = sys.argv[1]
args = sys.argv[2:]

with open(goal_file) as f:
    g = json.load(f)

i = 0
while i < len(args):
    flag = args[i]

    if flag == '--status':
        if i+1 >= len(args): print('--status requires value', file=sys.stderr); sys.exit(1)
        new_status = args[i+1]
        # COMPLETION GUARD: refuse 'complete' unless the LATEST recorded criteria check passes ALL
        # success_criteria. Kills the cherry-pick where a goal is declared done while found problems
        # remain. (impossible/blocked are honest non-completions — they skip this.)
        if new_status == 'complete':
            crits = g.get('success_criteria', [])
            logs = g.get('iteration_log', [])
            after = logs[-1].get('criteria_after', {}) if logs else {}
            cmap = {c.get('label'): c for c in crits}
            def _cpass(label):
                v = after.get(label); c = cmap.get(label, {})
                if isinstance(v, (int, float)) and not isinstance(v, bool) and 'target' in c:
                    return v >= c['target'] if c.get('direction', 'gte') == 'gte' else v <= c['target']
                return bool(v)
            unmet = [c.get('label') for c in crits if not _cpass(c.get('label'))]
            if not crits:
                print('CANNOT COMPLETE: no success_criteria defined. Derive criteria in iteration 1 '
                      '(survey + --set-criteria) before completing, or use --status blocked.', file=sys.stderr)
                sys.exit(1)
            if crits and unmet:
                print('CANNOT COMPLETE: criteria not passing in the latest iteration: ' + ', '.join(map(str, unmet)) +
                      '. Make them pass (fix the REAL problem) or use --status blocked with negative_knowledge. '
                      'Revising criteria to pass is blocked — they freeze after iteration 1.', file=sys.stderr)
                sys.exit(1)
            # (coverage gate for all/every objectives is enforced in the bash wrapper above — it
            #  runs the count commands natively, since this Python cannot spawn bash reliably on Windows)
        # CROSS-CLI GUARD: refuse a TERMINAL status (blocked/complete/impossible)
        # while a DIFFERENT live session (<4h claim) is actively working this goal. Stops one CLI from
        # stomping another CLI's goal — killing its bench + marking it blocked — which happened this
        # session. Only the OWNING session may terminate a goal. A session with its own claim skips itself.
        if new_status in ('complete', 'impossible', 'blocked'):
            import glob, time
            _gdir = os.path.dirname(os.path.abspath(goal_file))
            _me = os.environ.get('CLAUDE_CODE_SESSION_ID', '')
            _gid = g.get('id', '')
            _foreign = []
            # Only enforce if we can identify THIS session. With CLAUDE_CODE_SESSION_ID unset we
            # cannot tell our own claim from a peer's, so skip (fail-open) rather than refuse the owner.
            for _cf in (glob.glob(os.path.join(_gdir, 'session-*.goal')) if _me else []):
                _sid = os.path.basename(_cf)[len('session-'):-len('.goal')]
                if _sid == _me:
                    continue  # my own claim — never blocks me
                try:
                    _claimed = open(_cf).read().strip()
                    _age_h = (time.time() - os.path.getmtime(_cf)) / 3600.0
                except Exception:
                    continue
                if _claimed == _gid and _age_h < 4:
                    _foreign.append(_sid[:8] + '(' + str(round(_age_h, 1)) + 'h)')
            if _foreign:
                print('REFUSED --status ' + new_status + ': goal ' + _gid + ' is claimed by another LIVE CLI ('
                      + ', '.join(_foreign) + '). A goal another session is actively working CANNOT be terminated '
                      'by you. Only the owning session may block/complete it. Resume a DIFFERENT unclaimed goal.',
                      file=sys.stderr)
                sys.exit(1)
        g['status'] = new_status
        if new_status == 'paused':
            g['paused_at'] = datetime.now(timezone.utc).isoformat()
        elif new_status == 'active':
            g['paused_at'] = None
            # Re-activation clears the terminal stamp. A paused/blocked goal carries a
            # completed_at (blocked stamps it below); without clearing it on the way back
            # to active, goal-cron-guard would see status=active + completed_at and re-heal
            # the goal straight to 'complete', silently undoing the reactivation.
            g['completed_at'] = None
        elif new_status in ('complete', 'impossible', 'blocked'):
            # terminal states stamp completed_at (SKILL.md Completion Report needs it)
            g['completed_at'] = datetime.now(timezone.utc).isoformat()
        i += 2

    elif flag == '--impossibility-reason':
        g['impossibility_reason'] = args[i+1]
        i += 2

    elif flag == '--iteration':
        iteration_num = int(args[i+1])
        i += 2
        entry = {
            'iteration': iteration_num,
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'approach': '',
            'approach_tag': '',
            'changes': [],
            'criteria_before': {},
            'criteria_after': {},
            'outcome': 'no_change'
        }
        while i < len(args) and args[i] in ('--approach','--approach-tag','--changes','--criteria-before','--criteria-after','--criteria-before-file','--criteria-after-file'):
            if args[i] == '--approach':
                if i+1 >= len(args): print('--approach requires value', file=sys.stderr); sys.exit(1)
                entry['approach'] = args[i+1]
                i += 2
            elif args[i] == '--approach-tag':
                if i+1 >= len(args): print('--approach-tag requires value', file=sys.stderr); sys.exit(1)
                entry['approach_tag'] = args[i+1]
                i += 2
            elif args[i] == '--changes':
                if i+1 >= len(args): print('--changes requires value', file=sys.stderr); sys.exit(1)
                entry['changes'] = args[i+1].split(',')
                i += 2
            elif args[i] == '--criteria-before':
                if i+1 >= len(args): print('--criteria-before requires JSON value', file=sys.stderr); sys.exit(1)
                entry['criteria_before'] = json.loads(args[i+1])
                i += 2
            elif args[i] == '--criteria-after':
                if i+1 >= len(args): print('--criteria-after requires JSON value', file=sys.stderr); sys.exit(1)
                entry['criteria_after'] = json.loads(args[i+1])
                i += 2
            elif args[i] == '--criteria-before-file':
                if i+1 >= len(args): print('--criteria-before-file requires path', file=sys.stderr); sys.exit(1)
                entry['criteria_before'] = json.load(open(args[i+1]))
                i += 2
            elif args[i] == '--criteria-after-file':
                if i+1 >= len(args): print('--criteria-after-file requires path', file=sys.stderr); sys.exit(1)
                entry['criteria_after'] = json.load(open(args[i+1]))
                i += 2
        # Mechanical outcome: threshold-aware + numeric-progress-aware.
        # Boolean criteria -> pass-count diff (unchanged). Metric criteria (criterion def
        # carries 'target'/'direction', value stored as a number) -> a climb toward target
        # counts as 'progress' even if no boolean flipped. Fixes the plateau trap:
        # e.g. a metric climbing 0.54->0.62 is progress, not no_change (the plateau lesson).
        crit_by_label = {c.get('label'): c for c in g.get('success_criteria', [])}
        def _num(v):
            return isinstance(v, (int, float)) and not isinstance(v, bool)
        def _passes(label, val):
            c = crit_by_label.get(label, {})
            if _num(val) and 'target' in c:
                return val >= c['target'] if c.get('direction', 'gte') == 'gte' else val <= c['target']
            return bool(val)
        before = entry['criteria_before']; after = entry['criteria_after']
        before_pass = sum(1 for k, v in before.items() if _passes(k, v))
        after_pass = sum(1 for k, v in after.items() if _passes(k, v))
        numeric_progress = False
        for k, a in after.items():
            c = crit_by_label.get(k, {})
            b = before.get(k)
            if 'target' in c and _num(a) and _num(b):
                d = c.get('direction', 'gte')
                if (d == 'gte' and a > b) or (d == 'lte' and a < b):
                    numeric_progress = True
        if after_pass > before_pass:
            entry['outcome'] = 'progress'
        elif after_pass < before_pass:
            entry['outcome'] = 'regression'
        elif numeric_progress:
            entry['outcome'] = 'progress'
        else:
            entry['outcome'] = 'no_change'
        g['iteration_log'].append(entry)
        g['budget']['used'] = iteration_num
        continue  # skip the i += at bottom

    elif flag == '--add-negative':
        if i+2 >= len(args): print('--add-negative requires TAG and REASON', file=sys.stderr); sys.exit(1)
        tag = args[i+1]
        reason = args[i+2]
        g['negative_knowledge'].append({
            'approach_tag': tag,
            'detail': reason,
            'added_at': datetime.now(timezone.utc).isoformat()
        })
        i += 3
        continue

    elif flag == '--bump-budget':
        if i+1 >= len(args): print('--bump-budget requires value', file=sys.stderr); sys.exit(1)
        g['budget']['max_iterations'] = int(args[i+1])
        i += 2

    elif flag == '--set-context-summary':
        if i+1 >= len(args): print('--set-context-summary requires value', file=sys.stderr); sys.exit(1)
        g['context_summary'] = args[i+1]
        i += 2

    elif flag == '--reflect':
        if i+1 >= len(args): print('--reflect requires JSON value or file path', file=sys.stderr); sys.exit(1)
        val = args[i+1]
        try:
            reflection = json.loads(val)
        except json.JSONDecodeError:
            reflection = json.load(open(val))
        required_keys = ['outcome_reason', 'next_focus', 'research_files']
        missing_r = [k for k in required_keys if k not in reflection]
        if missing_r:
            print(f'Reflection missing keys: {missing_r}', file=sys.stderr)
            sys.exit(1)
        if 'reflections' not in g:
            g['reflections'] = []
        reflection['iteration'] = g['budget']['used']
        g['reflections'].append(reflection)
        i += 2

    elif flag == '--set-infra':
        if i+1 >= len(args): print('--set-infra requires JSON', file=sys.stderr); sys.exit(1)
        g['discovered_infra'] = json.loads(args[i+1])
        i += 2

    elif flag == '--set-criteria':
        if i+1 >= len(args): print('--set-criteria requires JSON array', file=sys.stderr); sys.exit(1)
        import re as _re
        new_criteria = json.loads(args[i+1])
        # FREEZE GUARD: criteria lock after iteration 1. Revising the bar mid-goal is the exact
        # cherry-pick that lets a goal "complete" while found problems go unfixed. Allowed only during
        # UNDERSTAND (budget.used == 0) or before any real criteria exist.
        _existing = [c for c in g.get('success_criteria', []) if c.get('check') and not str(c.get('check')).startswith('REPLACE:')]
        if g.get('budget', {}).get('used', 0) >= 1 and _existing:
            print('CRITERIA FROZEN: success_criteria lock after iteration 1 (budget.used=' +
                  str(g['budget']['used']) + '). You cannot move the goalposts mid-goal. Make the existing '
                  'criteria pass, or --status blocked. (Revising criteria to pass = declaring victory while errors remain.)', file=sys.stderr)
            sys.exit(1)
        for c in new_criteria:
            chk = c.get('check', '')
            label = c.get('label', '?')
            # HARD REJECT: file-existence-only criteria (SKILL.md BANS them: existence != works).
            stripped = _re.sub(r'(test|\[)\s+-[a-z]+\s+[^\s&|;)]+\s*(\])?', '', chk)
            stripped = _re.sub(r'[\s&|;()]+', '', stripped)
            if chk and stripped == '':
                print('CRITERIA REJECTED: \"' + label + '\" is file-existence-only (BANNED). '
                      'A file existing != the feature works. Add a content assertion, e.g. '
                      '\"... && grep -q PATTERN file\" or a row/line-count threshold.', file=sys.stderr)
                sys.exit(1)
            # WARN: bare status-code / unauthenticated curl (necessary but not sufficient).
            if _re.search(r'curl', chk) and _re.search(r'(http_code|200|307| -o /dev/null)', chk) \
               and not _re.search(r'(-b |--cookie|[Aa]uthorization|[Cc]ookie:)', chk):
                print('CRITERIA WARNING: \"' + label + '\" looks like an unauthenticated status-code '
                      'check (only verifies the server boots). Prefer an authenticated content assertion.',
                      file=sys.stderr)
        g['success_criteria'] = new_criteria
        i += 2

    elif flag == '--set-coverage':
        # COVERED_CMD prints how many units are verified-OK; TOTAL_CMD prints the live denominator
        # count from the codebase. Completion of an all/every goal requires covered >= total.
        # Both commands re-run live at completion, so the denominator cannot be faked.
        if i+2 >= len(args): print('--set-coverage requires COVERED_CMD TOTAL_CMD', file=sys.stderr); sys.exit(1)
        g['coverage'] = {'covered_cmd': args[i+1], 'total_cmd': args[i+2]}
        i += 3

    elif flag == '--set-scope':
        if i+1 >= len(args): print('--set-scope requires JSON array', file=sys.stderr); sys.exit(1)
        g['scope_lock'] = json.loads(args[i+1])
        i += 2

    elif flag == '--set-flex':
        if i+1 >= len(args): print('--set-flex requires JSON array', file=sys.stderr); sys.exit(1)
        g['scope_flex'] = json.loads(args[i+1])
        i += 2

    elif flag == '--update-metrics':
        # Derive everything computable from state, so metrics are TRUTHFUL even when the
        # agent passes no extra args (fixes the all-zeros Completion Report). Optional
        # increments cover the only un-derivable counters (tool calls, tokens, sessions).
        import subprocess as _sp
        m = g.get('metrics') or {}
        m['total_iterations'] = g['budget']['used']
        m['negative_knowledge_count'] = len(g.get('negative_knowledge', []))
        def _ts(s):
            try: return datetime.fromisoformat(str(s).replace('Z', '+00:00'))
            except Exception: return None
        stamps = [t for t in (_ts(e.get('timestamp')) for e in g.get('iteration_log', [])) if t]
        created = _ts(g.get('created_at'))
        start = created or (stamps[0] if stamps else None)
        if start is not None:
            # clamp: never report a negative duration (clock skew / bad timestamp)
            m['total_wall_clock_seconds'] = max(0, int((datetime.now(timezone.utc) - start).total_seconds()))
        try:
            # commits are tagged goal(<id>) by the loop scripts, but in-session runs may use a
            # human slug — so grep the id OR the branch slug (multiple --grep = OR in git log).
            slug = (g.get('branch', '') or '').split('/', 1)[-1]
            pats = ['--grep', 'goal(' + g['id'] + ')']
            if slug:
                pats += ['--grep', 'goal(' + slug + ')']
            r = _sp.run(['git', 'log', '--all', '--oneline'] + pats,
                        capture_output=True, text=True, timeout=10)
            m['commits'] = len([ln for ln in r.stdout.splitlines() if ln.strip()])
        except Exception:
            pass
        i += 1
        while i < len(args) and args[i] in ('--tool-calls', '--tokens', '--new-session'):
            if args[i] == '--tool-calls':
                if i+1 >= len(args): print('--tool-calls requires value', file=sys.stderr); sys.exit(1)
                m['total_tool_calls'] = m.get('total_tool_calls', 0) + int(args[i+1]); i += 2
            elif args[i] == '--tokens':
                if i+1 >= len(args): print('--tokens requires value', file=sys.stderr); sys.exit(1)
                m['total_tokens_estimated'] = m.get('total_tokens_estimated', 0) + int(args[i+1]); i += 2
            elif args[i] == '--new-session':
                m['session_count'] = m.get('session_count', 0) + 1; i += 1
        g['metrics'] = m
        continue

    else:
        print(f'Unknown flag: {flag}', file=sys.stderr)
        sys.exit(1)

# Validate before writing
required = ['id','objective','success_criteria','scope_lock','status','budget','iteration_log','negative_knowledge','created_at','branch']
missing = [k for k in required if k not in g]
if missing:
    print(f'Post-mutation validation failed: missing {missing}', file=sys.stderr)
    sys.exit(1)

# Atomic write: write to temp, then rename
tmp = goal_file + '.tmp'
with open(tmp, 'w') as f:
    json.dump(g, f, indent=2, ensure_ascii=False)
os.replace(tmp, goal_file)
print(f'OK: status={g[\"status\"]} budget={g[\"budget\"][\"used\"]}/{g[\"budget\"][\"max_iterations\"]}')
" "$GOAL_FILE" "$@"

# Sync status to index.json (keeps registry in sync with goal files)
python3 -c "
import json, os, sys
gf = sys.argv[1]
g = json.load(open(gf))
idx_file = os.path.join(os.path.dirname(gf), 'index.json')
if not os.path.exists(idx_file): sys.exit(0)
idx = json.load(open(idx_file))
for entry in idx.get('goals', []):
    if entry['id'] == g['id']:
        entry['status'] = g['status']
        break
tmp = idx_file + '.tmp'
with open(tmp, 'w') as f:
    json.dump(idx, f, indent=2, ensure_ascii=False)
os.replace(tmp, idx_file)
" "$GOAL_FILE"

# Crash/completion safety: after any state change, prune stale /goal-resume crons +
# self-heal re-activated goals when nothing is genuinely active. So marking a goal
# complete here ALSO removes its durable cron. See goal-cron-guard.sh.
_GUARD_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
bash "$_GUARD_ROOT/.claude/scripts/goal-cron-guard.sh" 2>/dev/null || true

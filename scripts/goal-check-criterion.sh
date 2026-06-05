#!/usr/bin/env bash
# goal-check-criterion.sh — Run a success criterion with structured JSON output
# v0.2.1: Added timeout (60s default) + basic command sanitization.
#
# Usage:
#   bash .claude/scripts/goal-check-criterion.sh "<check_command>" "<label>" [timeout_seconds]
#
# Output (always valid JSON to stdout, always exits 0):
#   {"pass": true, "label": "...", "exit_code": 0, "stdout_tail": "...", "stderr_tail": "...", "duration_ms": 1234}

set -uo pipefail

CHECK_CMD="${1:-}"
LABEL="${2:-unnamed}"
TIMEOUT_SEC="${3:-60}"

if [[ -z "$CHECK_CMD" ]]; then
  echo '{"pass": false, "label": "ERROR", "exit_code": -1, "stdout_tail": "", "stderr_tail": "missing check command", "duration_ms": 0}'
  exit 0
fi

# Basic sanitization: reject obviously dangerous patterns
# Not a security boundary (determined attacker bypasses), but catches accidental injection
DANGEROUS_PATTERNS='(rm[[:space:]]+-[A-Za-z]*[rf][A-Za-z]*[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(/|~|\*|\.([[:space:]]|$))|mkfs|dd[[:space:]]+if=|chmod[[:space:]]+-R[[:space:]]+777|curl[^|]*\|[[:space:]]*(ba)?sh|wget[^|]*\|[[:space:]]*(ba)?sh|>[[:space:]]*/etc/|:\(\)[[:space:]]*\{|git[[:space:]]+push[[:space:]][^|&;]*(--force|-f([[:space:]]|$))|(^|[[:space:]])sudo[[:space:]]|shred[[:space:]]|wipefs)'
if echo "$CHECK_CMD" | grep -qE "$DANGEROUS_PATTERNS" 2>/dev/null; then
  echo "{\"pass\": false, \"label\": \"$LABEL\", \"exit_code\": -2, \"stdout_tail\": \"\", \"stderr_tail\": \"BLOCKED: command matches dangerous pattern\", \"duration_ms\": 0}"
  exit 0
fi

TMPOUT=$(mktemp)
TMPERR=$(mktemp)
trap 'rm -f "$TMPOUT" "$TMPERR"' EXIT

# Portable millisecond clock (python3 is a required dependency; macOS `date` lacks %N).
_now_ms() { python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0; }
START_MS=$(_now_ms)

# Run the check under a timeout. Prefer GNU `timeout`/`gtimeout`; stock macOS has
# neither, so fall back to a python3 timeout (python3 is already required).
if command -v timeout >/dev/null 2>&1; then
  timeout "$TIMEOUT_SEC" bash -c "$CHECK_CMD" >"$TMPOUT" 2>"$TMPERR"; EXIT_CODE=$?
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout "$TIMEOUT_SEC" bash -c "$CHECK_CMD" >"$TMPOUT" 2>"$TMPERR"; EXIT_CODE=$?
else
  python3 - "$TIMEOUT_SEC" "$CHECK_CMD" >"$TMPOUT" 2>"$TMPERR" <<'PYTO'
import subprocess, sys
secs = float(sys.argv[1]); cmd = sys.argv[2]
try:
    sys.exit(subprocess.run(["bash", "-c", cmd], timeout=secs).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PYTO
  EXIT_CODE=$?
fi
if [[ $EXIT_CODE -eq 124 ]]; then
  echo "TIMEOUT after ${TIMEOUT_SEC}s" >> "$TMPERR"
fi

END_MS=$(_now_ms)
DURATION=$((END_MS - START_MS))

STDOUT_TAIL=$(tail -5 "$TMPOUT" 2>/dev/null | head -c 500 || echo "")
STDERR_TAIL=$(tail -5 "$TMPERR" 2>/dev/null | head -c 500 || echo "")

PASS="false"
if [[ $EXIT_CODE -eq 0 ]]; then
  PASS="true"
fi

python3 -c "
import json, sys, re
stdout_tail = sys.argv[4]
# Extract a trailing numeric value if the check prints one (metric criteria, e.g. an accuracy/coverage/score number).
# Harmless for boolean criteria — value stays null and is ignored unless the criterion
# def carries a 'target'. Enables numeric-progress detection (plateau climbing).
nums = re.findall(r'-?\d+\.?\d*', stdout_tail)
value = None
if nums:
    value = float(nums[-1])
    if value == int(value): value = int(value)
result = {
    'pass': sys.argv[1] == 'true',
    'label': sys.argv[2],
    'exit_code': int(sys.argv[3]),
    'value': value,
    'stdout_tail': stdout_tail,
    'stderr_tail': sys.argv[5],
    'duration_ms': int(sys.argv[6])
}
print(json.dumps(result, ensure_ascii=False))
" "$PASS" "$LABEL" "$EXIT_CODE" "$STDOUT_TAIL" "$STDERR_TAIL" "$DURATION"

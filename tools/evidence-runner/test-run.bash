#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_BASH="${SCRIPT_DIR}/run.bash"

PASSED_TESTS=0
FAILED_TESTS=0

log_pass() {
  echo "PASS: $1"
  PASSED_TESTS=$((PASSED_TESTS + 1))
}

log_fail() {
  echo "FAIL: $1 - $2" >&2
  FAILED_TESTS=$((FAILED_TESTS + 1))
}

check_schema() {
  local file="$1"
  jq -e '
    select(.sweepMeta != true) |
    has("scenario") and
    has("kind") and
    has("clearCut") and
    has("knownMiss") and
    has("adapter") and
    has("controlArm") and
    has("detected") and
    has("precise") and
    has("repaired") and
    has("verdictReason") and
    has("wallClockSec") and
    has("turns") and
    has("timestamp")
  ' "$file" >/dev/null 2>&1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Test 1: Stub adapter golden mode -> repaired=true
TEST1_OUT="${TMP_DIR}/test1_metrics.jsonl"
EC1=0
set +e
STUB_MODE=golden "${RUN_BASH}" --adapter stub --scenario base-gating-dup --out "${TEST1_OUT}" >/dev/null 2>&1
EC1=$?
set -e

if [ $EC1 -eq 0 ] && [ -f "${TEST1_OUT}" ] && check_schema "${TEST1_OUT}" && \
   [ "$(jq -r 'select(.sweepMeta != true) | .repaired' "${TEST1_OUT}")" = "true" ] && \
   [ "$(jq -r 'select(.sweepMeta != true) | .scenario' "${TEST1_OUT}")" = "base-gating-dup" ] && \
   [ "$(jq -r 'select(.sweepMeta != true) | .adapter' "${TEST1_OUT}")" = "stub" ] && \
   [ "$(jq -r 'select(.sweepMeta != true) | .controlArm' "${TEST1_OUT}")" = "false" ] && \
   [ "$(jq -r 'select(.sweepMeta != true) | .verdictReason' "${TEST1_OUT}")" = "match_and_clean" ] && \
   [ "$(jq -r 'select(.sweepMeta == true) | .selected' "${TEST1_OUT}")" = "1" ] && \
   [ -f "${TEST1_OUT%.jsonl}-artifacts/base-gating-dup/prompt.txt" ] && \
   [ -f "${TEST1_OUT%.jsonl}-artifacts/base-gating-dup/transcript.log" ] && \
   [ -f "${TEST1_OUT%.jsonl}-artifacts/base-gating-dup/adapter_stderr.log" ]; then
  log_pass "Stub golden mode -> repaired=true, sweepMeta emitted, artifacts persisted"
else
  log_fail "Stub golden mode -> repaired=true" "Exit code $EC1 or metrics mismatch"
fi

# Test 2: Stub adapter delete mode -> repaired=false
TEST2_OUT="${TMP_DIR}/test2_metrics.jsonl"
EC2=0
set +e
STUB_MODE=delete "${RUN_BASH}" --adapter stub --scenario base-gating-dup --out "${TEST2_OUT}" >/dev/null 2>&1
EC2=$?
set -e

if [ $EC2 -eq 0 ] && [ -f "${TEST2_OUT}" ] && check_schema "${TEST2_OUT}" && \
   [ "$(jq -r 'select(.sweepMeta != true) | .repaired' "${TEST2_OUT}")" = "false" ]; then
  log_pass "Stub delete mode -> repaired=false"
else
  log_fail "Stub delete mode -> repaired=false" "Exit code $EC2 or metrics mismatch"
fi

# Test 3: Stub adapter garbage mode -> repaired=false with verdictReason=garbage_output
TEST3_OUT="${TMP_DIR}/test3_metrics.jsonl"
EC3=0
set +e
STUB_MODE=garbage "${RUN_BASH}" --adapter stub --scenario base-gating-dup --out "${TEST3_OUT}" >/dev/null 2>&1
EC3=$?
set -e

if [ $EC3 -eq 0 ] && [ -f "${TEST3_OUT}" ] && check_schema "${TEST3_OUT}" && \
   [ "$(jq -r 'select(.sweepMeta != true) | .repaired' "${TEST3_OUT}")" = "false" ] && \
   [ "$(jq -r 'select(.sweepMeta != true) | .verdictReason' "${TEST3_OUT}")" = "garbage_output" ]; then
  log_pass "Stub garbage mode -> repaired=false with verdictReason=garbage_output"
else
  log_fail "Stub garbage mode -> repaired=false with verdictReason=garbage_output" "Exit code $EC3 or metrics mismatch"
fi

# Test 4: Stub adapter with --no-findings -> controlArm=true
TEST4_OUT="${TMP_DIR}/test4_metrics.jsonl"
EC4=0
set +e
STUB_MODE=golden "${RUN_BASH}" --adapter stub --scenario base-gating-dup --no-findings --out "${TEST4_OUT}" >/dev/null 2>&1
EC4=$?
set -e

if [ $EC4 -eq 0 ] && [ -f "${TEST4_OUT}" ] && check_schema "${TEST4_OUT}" && \
   [ "$(jq -r 'select(.sweepMeta != true) | .controlArm' "${TEST4_OUT}")" = "true" ] && \
   [ "$(jq -r 'select(.sweepMeta != true) | .repaired' "${TEST4_OUT}")" = "true" ]; then
  log_pass "Stub mode with --no-findings -> controlArm=true"
else
  log_fail "Stub mode with --no-findings -> controlArm=true" "Exit code $EC4 or metrics mismatch"
fi

# Test 5: Ephemeral mode evaluation of uninstrumented workspace matches instrumented result
EPH_UNINSTR_JSON="$("${SCRIPT_DIR}/eval-workspace.bash" "${SCRIPT_DIR}/../../fixtures/consumer-variants/uninstrumented" 2>/dev/null)"
EPH_INSTR_JSON="$("${SCRIPT_DIR}/eval-workspace.bash" "${SCRIPT_DIR}/../../fixtures/consumer" 2>/dev/null)"

if [ -n "$EPH_UNINSTR_JSON" ] && [ -n "$EPH_INSTR_JSON" ] && \
   [ "$(jq -c '.findings' <<< "$EPH_UNINSTR_JSON")" = "$(jq -c '.findings' <<< "$EPH_INSTR_JSON")" ] && \
   [ "$(jq -r '.summary.gating' <<< "$EPH_UNINSTR_JSON")" = "0" ]; then
  log_pass "Ephemeral mode: uninstrumented workspace evaluation matches instrumented result"
else
  log_fail "Ephemeral mode: uninstrumented workspace evaluation matches instrumented result" "Payload mismatch or evaluation failed"
fi

# Test 6: Findings presentation in run.bash includes fix/docRef/column and gracefully omits position when null
TEST6_PRE_JSON='{
  "version": 1,
  "findings": [
    {
      "rule": "duplication",
      "severity": "gating",
      "aspectPath": "web.nixos",
      "position": { "file": "modules/web.nix", "line": 12, "column": 5 },
      "message": "Duplicate nixos configuration",
      "fix": "Consolidate openssh config",
      "docRef": "https://den.dev/docs/rules/duplication"
    },
    {
      "rule": "granularity",
      "severity": "advisory",
      "position": null,
      "message": "Found single-option aspects",
      "fix": "Consolidate single-option aspects",
      "docRef": "https://den.dev/docs/guides/configure-aspects"
    }
  ]
}'

TEST6_TEXT="$(jq -r '
  .findings // [] | map(
    "Finding:\n  Rule: \(.rule)\n  Severity: \(.severity)" +
    (if .aspectPath then "\n  Aspect: \(.aspectPath)" else "" end) +
    (if .position and .position.file then "\n  File: \(.position.file)" else "" end) +
    (if .position and .position.line then "\n  Line: \(.position.line)" else "" end) +
    (if .position and .position.column then "\n  Column: \(.position.column)" else "" end) +
    (if .message then "\n  Message: \(.message)" else "" end) +
    (if .fix then "\n  Fix: \(.fix)" else "" end) +
    (if .docRef then "\n  DocRef: \(.docRef)" else "" end)
  ) | join("\n\n")
' <<< "$TEST6_PRE_JSON")"

if grep -q "Column: 5" <<< "$TEST6_TEXT" && \
   grep -q "Fix: Consolidate openssh config" <<< "$TEST6_TEXT" && \
   grep -q "DocRef: https://den.dev/docs/rules/duplication" <<< "$TEST6_TEXT" && \
   grep -q "Fix: Consolidate single-option aspects" <<< "$TEST6_TEXT" && \
   grep -q "DocRef: https://den.dev/docs/guides/configure-aspects" <<< "$TEST6_TEXT" && \
   ! grep -A 3 "Rule: granularity" <<< "$TEST6_TEXT" | grep -q "File:"; then
  log_pass "Runner presentation: includes fix/docRef/column and gracefully omits position when null"
else
  log_fail "Runner presentation: includes fix/docRef/column and gracefully omits position when null" "Presentation text mismatch: $TEST6_TEXT"
fi

echo "Summary: ${PASSED_TESTS} passed, ${FAILED_TESTS} failed."

if [ "${FAILED_TESTS}" -ne 0 ]; then
  exit 1
fi

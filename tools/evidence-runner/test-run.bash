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
   [ "$(jq -r '.repaired' "${TEST1_OUT}")" = "true" ] && \
   [ "$(jq -r '.scenario' "${TEST1_OUT}")" = "base-gating-dup" ] && \
   [ "$(jq -r '.adapter' "${TEST1_OUT}")" = "stub" ] && \
   [ "$(jq -r '.controlArm' "${TEST1_OUT}")" = "false" ] && \
   [ "$(jq -r '.verdictReason' "${TEST1_OUT}")" = "match_and_clean" ]; then
  log_pass "Stub golden mode -> repaired=true"
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
   [ "$(jq -r '.repaired' "${TEST2_OUT}")" = "false" ]; then
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
   [ "$(jq -r '.repaired' "${TEST3_OUT}")" = "false" ] && \
   [ "$(jq -r '.verdictReason' "${TEST3_OUT}")" = "garbage_output" ]; then
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
   [ "$(jq -r '.controlArm' "${TEST4_OUT}")" = "true" ] && \
   [ "$(jq -r '.repaired' "${TEST4_OUT}")" = "true" ]; then
  log_pass "Stub mode with --no-findings -> controlArm=true"
else
  log_fail "Stub mode with --no-findings -> controlArm=true" "Exit code $EC4 or metrics mismatch"
fi

echo "Summary: ${PASSED_TESTS} passed, ${FAILED_TESTS} failed."

if [ "${FAILED_TESTS}" -ne 0 ]; then
  exit 1
fi

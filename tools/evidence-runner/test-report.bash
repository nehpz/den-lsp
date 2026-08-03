#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_BASH="${SCRIPT_DIR}/report.bash"

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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Test 1: AE5 - One clear-cut row with detected=false -> NO-GO + triage section, exit 0 for render
TEST1_FILE="${TMP_DIR}/ae5_metrics.jsonl"
cat << 'EOF' > "${TEST1_FILE}"
{"scenario":"s1","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":false,"precise":true,"repaired":true,"verdictReason":"detected_miss","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s2","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s3","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s4","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s5","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
EOF

OUT1=""
EC1=0
set +e
OUT1="$("${REPORT_BASH}" --in "${TEST1_FILE}" 2>&1)"
EC1=$?
set -e

if [ $EC1 -eq 0 ] && grep -q "NO-GO" <<< "$OUT1" && grep -q "Tool-Bug Triage" <<< "$OUT1" && grep -q "s1" <<< "$OUT1"; then
  log_pass "AE5 detected=false produces NO-GO + triage section with exit 0"
else
  log_fail "AE5 detected=false" "exit code $EC1, output: $OUT1"
fi

# Test 2: Refusal Gate - 4 clear-cut rows -> nonzero exit + message naming 4 < 5
TEST2_FILE="${TMP_DIR}/refusal_metrics.jsonl"
cat << 'EOF' > "${TEST2_FILE}"
{"scenario":"s1","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s2","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s3","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s4","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
EOF

OUT2=""
EC2=0
set +e
OUT2="$("${REPORT_BASH}" --in "${TEST2_FILE}" 2>&1)"
EC2=$?
set -e

if [ $EC2 -ne 0 ] && grep -q "below R17 floor of 5" <<< "$OUT2" && grep -q "4" <<< "$OUT2"; then
  log_pass "Refusal gate for 4 clear-cut scenarios produces nonzero exit and names count (4 < 5)"
else
  log_fail "Refusal gate" "exit code $EC2, output: $OUT2"
fi

# Test 3: Clean 8-row file with knownMiss and controlArm -> 100% metrics, field-readiness framing, appendices rendered
TEST3_FILE="${TMP_DIR}/clean8_metrics.jsonl"
cat << 'EOF' > "${TEST3_FILE}"
{"scenario":"s1","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s2","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s3","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s4","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s5","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s6","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s7","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s8","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"km1","kind":"finding","clearCut":false,"knownMiss":true,"adapter":"stub","controlArm":false,"detected":false,"precise":true,"repaired":false,"verdictReason":"known_miss","wallClockSec":5,"turns":null,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"ca1","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":true,"detected":true,"precise":true,"repaired":false,"verdictReason":"golden_mismatch","wallClockSec":15,"turns":2,"timestamp":"2026-08-03T00:00:00Z"}
EOF

OUT3=""
EC3=0
set +e
OUT3="$("${REPORT_BASH}" --in "${TEST3_FILE}" 2>&1)"
EC3=$?
set -e

if [ $EC3 -eq 0 ] && \
   grep -q "Catch Rate (detected): 8/8 (100%)" <<< "$OUT3" && \
   grep -q "Finding Precision: 8/8 (100%)" <<< "$OUT3" && \
   grep -q "AUTHORIZES ENTRY INTO FIELD READINESS" <<< "$OUT3" && \
   grep -q "km1" <<< "$OUT3" && \
   grep -q "ca1" <<< "$OUT3"; then
  log_pass "Clean 8-row sweep renders 100/100, field readiness framing, and appendices"
else
  log_fail "Clean 8-row sweep" "exit code $EC3, output: $OUT3"
fi

# Test 4: Median wall-clock calculation for odd-count fixture (values: 10, 30, 20, 50, 40 -> median 30)
TEST4_FILE="${TMP_DIR}/median_metrics.jsonl"
cat << 'EOF' > "${TEST4_FILE}"
{"scenario":"s1","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s2","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":30,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s3","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":20,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s4","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":50,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s5","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":40,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
EOF

OUT4=""
EC4=0
set +e
OUT4="$("${REPORT_BASH}" --in "${TEST4_FILE}" 2>&1)"
EC4=$?
set -e

if [ $EC4 -eq 0 ] && grep -q "median 30s" <<< "$OUT4"; then
  log_pass "Median wall-clock calculated correctly (30s for odd-count set 10,20,30,40,50)"
else
  log_fail "Median wall-clock" "exit code $EC4, output: $OUT4"
fi

# Test 5: Failure rows (timeout) -> footnote rendered
TEST5_FILE="${TMP_DIR}/failure_metrics.jsonl"
cat << 'EOF' > "${TEST5_FILE}"
{"scenario":"s1","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":false,"verdictReason":"timeout","wallClockSec":600,"turns":null,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s2","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s3","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s4","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s5","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
EOF

OUT5=""
EC5=0
set +e
OUT5="$("${REPORT_BASH}" --in "${TEST5_FILE}" 2>&1)"
EC5=$?
set -e

if [ $EC5 -eq 0 ] && grep -q "Footnote: Adapter failure rows" <<< "$OUT5" && grep -q "4/5 (80%)" <<< "$OUT5"; then
  log_pass "Failure rows count as repaired=false with footnote rendered"
else
  log_fail "Failure rows footnote" "exit code $EC5, output: $OUT5"
fi
# Test 6: Malformed JSONL lines -> tolerated, skipped lines footnote rendered
TEST6_FILE="${TMP_DIR}/malformed_metrics.jsonl"
cat << 'EOF' > "${TEST6_FILE}"
{"scenario":"s1","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
THIS_IS_MALFORMED_JSON
{"scenario":"s2","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s3","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s4","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
{"scenario":"s5","kind":"finding","clearCut":true,"knownMiss":false,"adapter":"stub","controlArm":false,"detected":true,"precise":true,"repaired":true,"verdictReason":"match_and_clean","wallClockSec":10,"turns":1,"timestamp":"2026-08-03T00:00:00Z"}
EOF

OUT6=""
EC6=0
set +e
OUT6="$("${REPORT_BASH}" --in "${TEST6_FILE}" 2>&1)"
EC6=$?
set -e

if [ $EC6 -eq 0 ] && grep -q "Skipped 1 malformed JSONL line" <<< "$OUT6" && grep -q "Scenarios Evaluated (Clear-Cut): 5" <<< "$OUT6"; then
  log_pass "Malformed JSONL lines tolerated with footnote rendered"
else
  log_fail "Malformed JSONL lines test failed" "Output:\n${OUT6}"
fi

echo "Summary: ${PASSED_TESTS} passed, ${FAILED_TESTS} failed."

if [ "${FAILED_TESTS}" -ne 0 ]; then
  exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPAIRED_DIR="${1:-}"
GOLDEN_DIR="${2:-}"
# $3 is unused scenario_kind (callers pass it; comparison does not branch on it)
EXPECTED_RULES=("${@:4}")

if [ -z "$REPAIRED_DIR" ] || [ -z "$GOLDEN_DIR" ]; then
  echo "Usage: compare.bash <repaired_dir> <golden_dir> [scenario_kind] [expected_rule1 ...]" >&2
  exit 1
fi

EVAL_SCRIPT="${SCRIPT_DIR}/eval-workspace.bash"

emit_fail_json() {
  local reason="$1"
  jq -c -n \
    --argjson match false \
    --argjson cleanReanalysis false \
    --arg verdict "FAIL" \
    --arg reason "$reason" \
    '{match: $match, cleanReanalysis: $cleanReanalysis, verdict: $verdict, reason: $reason}'
  exit 1
}

# Step 1: Evaluate Repaired Workspace
REPAIRED_RAW=""
set +e
REPAIRED_RAW="$("${EVAL_SCRIPT}" "${REPAIRED_DIR}" 2>/dev/null)"
REPAIRED_EC=$?
set -e

if [ "${REPAIRED_EC}" -ne 0 ] || [ -z "${REPAIRED_RAW}" ]; then
  emit_fail_json "Repaired workspace failed evaluation"
fi

# Step 2: Evaluate Golden Workspace
set +e
GOLDEN_RAW="$("${EVAL_SCRIPT}" "${GOLDEN_DIR}" 2>/dev/null)"
GOLDEN_EC=$?
set -e

if [ "${GOLDEN_EC}" -ne 0 ] || [ -z "${GOLDEN_RAW}" ]; then
  emit_fail_json "Golden workspace failed evaluation"
fi
# Step 3: Normalization (KTD6)
NORM_JQ='
def is_wrapper:
  type == "object" and has("imports") and (.imports | type == "array") and (keys | all(. == "imports" or . == "_file" or . == "key"));

def norm:
  if type == "object" then
    if is_wrapper then
      if (.imports | length) == 1 then
        .imports[0] | norm
      else
        { imports: (.imports | map(norm)) }
      end
    else
      del(.position, .__loc)
      | to_entries
      | map(.value |= norm | select(.value != null))
      | sort_by(.key)
      | from_entries
    end
  elif type == "array" then
    map(norm) | sort_by(tostring)
  elif type == "string" then
    gsub("/nix/store/[a-z0-9]{32}-[^\"]*"; "<store-path>")
  else
    .
  end;

norm
'

REPAIRED_NORM="$(jq "$NORM_JQ" <<< "${REPAIRED_RAW}")"
GOLDEN_NORM="$(jq "$NORM_JQ" <<< "${GOLDEN_RAW}")"

# Step 4: Structural Equality (match)
MATCH="$(jq -n --argjson r "${REPAIRED_NORM}" --argjson g "${GOLDEN_NORM}" '$r == $g')"

# Step 5: Clean Re-Analysis (cleanReanalysis)
# (a) No findings of any severity in repaired analysis (advisory included) -
#     matches the hermetic tier's zero-findings golden discipline.
FINDING_COUNT="$(jq '.findings | length' <<< "${REPAIRED_RAW}")"

# (b) None of the scenario expected finding rules still firing in repaired analysis
EXPECTED_RULES_JSON="$(jq -c -n '$ARGS.positional' --args "${EXPECTED_RULES[@]+"${EXPECTED_RULES[@]}"}")"
EXPECTED_FIRING="$(jq -r --argjson rules "${EXPECTED_RULES_JSON}" '
  [.findings[]? | select(.rule as $r | $rules | index($r))] | length
' <<< "${REPAIRED_RAW}")"

CLEAN_REANALYSIS=false
if [ "${FINDING_COUNT}" -eq 0 ] && [ "${EXPECTED_FIRING}" -eq 0 ]; then
  CLEAN_REANALYSIS=true
fi

# Step 6: Verdict (R9)
VERDICT="FAIL"
EXIT_CODE=1

if [ "${MATCH}" = "true" ] && [ "${CLEAN_REANALYSIS}" = "true" ]; then
  VERDICT="PASS"
  EXIT_CODE=0
fi

# Output one-line machine-parseable JSON
jq -c -n \
  --argjson match "${MATCH}" \
  --argjson cleanReanalysis "${CLEAN_REANALYSIS}" \
  --arg verdict "${VERDICT}" \
  '{match: $match, cleanReanalysis: $cleanReanalysis, verdict: $verdict}'

exit "${EXIT_CODE}"

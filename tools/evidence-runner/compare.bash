#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPAIRED_DIR=""
GOLDEN_DIR=""
SCENARIO_KIND="finding"
EXPECTED_RULES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repaired)
      REPAIRED_DIR="$2"
      shift 2
      ;;
    --golden)
      GOLDEN_DIR="$2"
      shift 2
      ;;
    --kind)
      SCENARIO_KIND="$2"
      shift 2
      ;;
    --expected-rules)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
        EXPECTED_RULES+=("$1")
        shift
      done
      ;;
    *)
      if [ -z "$REPAIRED_DIR" ]; then
        REPAIRED_DIR="$1"
      elif [ -z "$GOLDEN_DIR" ]; then
        GOLDEN_DIR="$1"
      elif [ -z "$SCENARIO_KIND" ]; then
        SCENARIO_KIND="$1"
      else
        EXPECTED_RULES+=("$1")
      fi
      shift
      ;;
  esac
done

if [ -z "$REPAIRED_DIR" ] || [ -z "$GOLDEN_DIR" ]; then
  echo "Usage: compare.bash <repaired_dir> <golden_dir> [scenario_kind] [expected_rule1 ...]" >&2
  exit 1
fi

EVAL_SCRIPT="${SCRIPT_DIR}/eval-workspace.bash"

# Step 1: Evaluate Repaired Workspace
REPAIRED_RAW=""
set +e
REPAIRED_RAW="$("${EVAL_SCRIPT}" "${REPAIRED_DIR}" 2>/dev/null)"
REPAIRED_EC=$?
set -e

if [ "${REPAIRED_EC}" -ne 0 ] || [ -z "${REPAIRED_RAW}" ]; then
  jq -c -n \
    --argjson match false \
    --argjson cleanReanalysis false \
    --arg verdict "FAIL" \
    --arg reason "Repaired workspace failed evaluation" \
    '{match: $match, cleanReanalysis: $cleanReanalysis, verdict: $verdict, reason: $reason}'
  exit 1
fi

# Step 2: Evaluate Golden Workspace
set +e
GOLDEN_RAW="$("${EVAL_SCRIPT}" "${GOLDEN_DIR}" 2>/dev/null)"
GOLDEN_EC=$?
set -e

if [ "${GOLDEN_EC}" -ne 0 ] || [ -z "${GOLDEN_RAW}" ]; then
  jq -c -n \
    --argjson match false \
    --argjson cleanReanalysis false \
    --arg verdict "FAIL" \
    --arg reason "Golden workspace failed evaluation" \
    '{match: $match, cleanReanalysis: $cleanReanalysis, verdict: $verdict, reason: $reason}'
  exit 1
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
# (a) No gating findings in repaired analysis
GATING_COUNT="$(jq '.summary.gating // 0' <<< "${REPAIRED_RAW}")"

# (b) None of the scenario expected finding rules still firing in repaired analysis
EXPECTED_RULES_JSON="$(jq -c -n '$ARGS.positional' --args "${EXPECTED_RULES[@]+"${EXPECTED_RULES[@]}"}")"
EXPECTED_FIRING="$(jq -r --argjson rules "${EXPECTED_RULES_JSON}" '
  [.findings[]? | select(.rule as $r | $rules | index($r))] | length
' <<< "${REPAIRED_RAW}")"

CLEAN_REANALYSIS=false
if [ "${GATING_COUNT}" -eq 0 ] && [ "${EXPECTED_FIRING}" -eq 0 ]; then
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

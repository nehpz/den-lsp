#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPAIRED_DIR=""
GOLDEN_DIR=""
SCENARIO_KIND="finding"
EXPECTED_RULES=()
POSITIONAL_COUNT=0

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
      case "$POSITIONAL_COUNT" in
        0)
          REPAIRED_DIR="$1"
          ;;
        1)
          GOLDEN_DIR="$1"
          ;;
        2)
          SCENARIO_KIND="$1"
          ;;
        *)
          EXPECTED_RULES+=("$1")
          ;;
      esac
      POSITIONAL_COUNT=$((POSITIONAL_COUNT + 1))
      shift
      ;;
  esac
done

if [ -z "$REPAIRED_DIR" ] || [ -z "$GOLDEN_DIR" ]; then
  echo "Usage: compare.bash <repaired_dir> <golden_dir> [scenario_kind] [expected_rule1 ...]" >&2
  exit 1
fi

EVAL_SCRIPT="${EVAL_WORKSPACE_SCRIPT:-${SCRIPT_DIR}/eval-workspace.bash}"

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

IS_REPAIRED_ERR=false
if [ "${REPAIRED_EC}" -eq 0 ] && [ -n "${REPAIRED_RAW}" ] && jq -e . >/dev/null 2>&1 <<< "${REPAIRED_RAW}"; then
  if jq -e '.error != null' >/dev/null 2>&1 <<< "${REPAIRED_RAW}"; then
    IS_REPAIRED_ERR=true
  fi
fi

if [ "${REPAIRED_EC}" -ne 0 ] || [ -z "${REPAIRED_RAW}" ] || [ "${IS_REPAIRED_ERR}" = "true" ]; then
  if [ "${IS_REPAIRED_ERR}" = "true" ]; then
    ERR_KIND="$(jq -r '.error.kind // "eval-error"' <<< "${REPAIRED_RAW}")"
    ERR_MSG="$(jq -r '.error.message // ""' <<< "${REPAIRED_RAW}")"
    if [ -n "$ERR_MSG" ]; then
      emit_fail_json "eval_error: ${ERR_KIND}: ${ERR_MSG}"
    else
      emit_fail_json "eval_error: ${ERR_KIND}"
    fi
  else
    emit_fail_json "Repaired workspace failed evaluation"
  fi
fi

# Step 2: Evaluate Golden Workspace
set +e
GOLDEN_RAW="$("${EVAL_SCRIPT}" "${GOLDEN_DIR}" 2>/dev/null)"
GOLDEN_EC=$?
set -e

IS_GOLDEN_ERR=false
if [ "${GOLDEN_EC}" -eq 0 ] && [ -n "${GOLDEN_RAW}" ] && jq -e . >/dev/null 2>&1 <<< "${GOLDEN_RAW}"; then
  if jq -e '.error != null' >/dev/null 2>&1 <<< "${GOLDEN_RAW}"; then
    IS_GOLDEN_ERR=true
  fi
fi

if [ "${GOLDEN_EC}" -ne 0 ] || [ -z "${GOLDEN_RAW}" ] || [ "${IS_GOLDEN_ERR}" = "true" ]; then
  if [ "${IS_GOLDEN_ERR}" = "true" ]; then
    ERR_KIND="$(jq -r '.error.kind // "eval-error"' <<< "${GOLDEN_RAW}")"
    ERR_MSG="$(jq -r '.error.message // ""' <<< "${GOLDEN_RAW}")"
    if [ -n "$ERR_MSG" ]; then
      emit_fail_json "eval_error: ${ERR_KIND}: ${ERR_MSG}"
    else
      emit_fail_json "eval_error: ${ERR_KIND}"
    fi
  else
    emit_fail_json "Golden workspace failed evaluation"
  fi
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

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${REPO_DIR:-}" ] || [ ! -f "${REPO_DIR}/fixtures/scenarios/lib.nix" ]; then
  if [ -f "${SCRIPT_DIR}/../../fixtures/scenarios/lib.nix" ]; then
    REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
  elif [ -f "./fixtures/scenarios/lib.nix" ]; then
    REPO_DIR="$(pwd)"
  elif git rev-parse --show-toplevel >/dev/null 2>&1 && [ -f "$(git rev-parse --show-toplevel)/fixtures/scenarios/lib.nix" ]; then
    REPO_DIR="$(git rev-parse --show-toplevel)"
  else
    echo "Error: Could not locate repo directory containing fixtures/scenarios/lib.nix" >&2
    exit 1
  fi
fi
export REPO_DIR="${REPO_DIR}"
# Ensure PATH includes host directories for agent CLIs (e.g. claude, omp)
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin:$HOME/.nix-profile/bin:$HOME/.cargo/bin"

TARGET_SCENARIO=""
SET_NAME="clear-cut"
ADAPTER_NAME=""
NO_FINDINGS=false
OUT_FILE="./evidence-metrics.jsonl"
TIMEOUT_SEC=600
MAX_TURNS=25

usage() {
  cat <<EOF
Usage: run.bash [command] [options]

Commands:
  run                Run metrics sweep (default command)
  report             Render go/no-go readout report

Options for run:
  --adapter <name>   Required. Adapter script name (e.g. stub, claude)
  --scenario <name>  Run a single scenario by name
  --set <name>       Target scenario set: clear-cut (default)
  --no-findings      Withhold findings from prompt (control arm, R10)
  --out <file>       Metrics output file (default: ./evidence-metrics.jsonl)
  --timeout <sec>    Wall-clock timeout per scenario in seconds (default: 600)
  --max-turns <n>    Maximum turns per scenario (default: 25)
  --help, -h         Show this help message

Options for report:
  --in <file>        Metrics JSON-lines input file (default: ./evidence-metrics.jsonl)
  --out <file>       Optional output markdown file
  --help, -h         Show this help message
EOF
}

if [ "${1:-}" = "report" ]; then
  shift
  if [ -f "${SCRIPT_DIR}/report.bash" ]; then
    exec "${SCRIPT_DIR}/report.bash" "$@"
  elif [ -f "${REPO_DIR}/tools/evidence-runner/report.bash" ]; then
    exec "${REPO_DIR}/tools/evidence-runner/report.bash" "$@"
  else
    exec "${SCRIPT_DIR}/report.bash" "$@"
  fi
elif [ "${1:-}" = "run" ]; then
  shift
fi


while [[ $# -gt 0 ]]; do
  case "$1" in
    --adapter)
      ADAPTER_NAME="$2"
      shift 2
      ;;
    --scenario)
      TARGET_SCENARIO="$2"
      shift 2
      ;;
    --set)
      SET_NAME="$2"
      shift 2
      ;;
    --no-findings)
      NO_FINDINGS=true
      shift
      ;;
    --out)
      OUT_FILE="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    --max-turns)
      MAX_TURNS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done
OUT_FILE="$(mkdir -p "$(dirname "$OUT_FILE")" && cd "$(dirname "$OUT_FILE")" && pwd)/$(basename "$OUT_FILE")"
if [ -z "$ADAPTER_NAME" ]; then
  echo "Error: --adapter <name> is required." >&2
  usage
  exit 1
fi

ADAPTER_SCRIPT="${SCRIPT_DIR}/adapters/${ADAPTER_NAME}.bash"
if [ ! -f "$ADAPTER_SCRIPT" ]; then
  echo "Error: Adapter script '${ADAPTER_SCRIPT}' not found." >&2
  exit 1
fi

# Enumerate scenarios via nix eval
DEN_DIR_OVERRIDE=()
if [ -n "${DEN_DIR:-}" ]; then
  DEN_DIR_OVERRIDE=(--override-input den "${DEN_DIR}")
fi

SCENARIOS_JSON="$(nix eval --json --impure "${DEN_DIR_OVERRIDE[@]}" --expr "let s = import ${REPO_DIR}/fixtures/scenarios/lib.nix {}; in s.scenarios" 2>/dev/null | sed -n '/^{/,$p')"
# Filter scenarios into a JSON array
if [ -n "$TARGET_SCENARIO" ]; then
  FILTER_JQ="[ .[\"${TARGET_SCENARIO}\"] | select(. != null) ]"
elif [ "$SET_NAME" = "clear-cut" ]; then
  FILTER_JQ="[ .[] | select(.clearCut == true and .goldenable == true) ] | sort_by(.name)"
else
  echo "Error: Unknown --set '${SET_NAME}'" >&2
  exit 1
fi

SELECTED_SCENARIOS="$(jq -c "$FILTER_JQ" <<< "$SCENARIOS_JSON")"
NUM_SELECTED="$(jq 'length' <<< "$SELECTED_SCENARIOS")"

if [ "$NUM_SELECTED" -eq 0 ]; then
  if [ -n "$TARGET_SCENARIO" ]; then
    echo "Error: Scenario '${TARGET_SCENARIO}' not found." >&2
  else
    echo "Error: No scenarios matched set '${SET_NAME}'." >&2
  fi
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

run_with_timeout() {
  local timeout_sec="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_sec" "$@"
  else
    "$@" &
    local pid=$!
    (
      sleep "$timeout_sec"
      kill -9 "$pid" 2>/dev/null || true
    ) &
    local watcher_pid=$!
    set +e
    wait "$pid" 2>/dev/null
    local ec=$?
    kill -9 "$watcher_pid" 2>/dev/null || true
    set -e
    return "$ec"
  fi
}

# Process each scenario sequentially
SCENARIO_COUNT="$(jq 'length' <<< "$SELECTED_SCENARIOS")"
for ((i=0; i<SCENARIO_COUNT; i++)); do
  SCENARIO_OBJ="$(jq -c ".[$i]" <<< "$SELECTED_SCENARIOS")"
  NAME="$(jq -r '.name' <<< "$SCENARIO_OBJ")"
  KIND="$(jq -r '.kind' <<< "$SCENARIO_OBJ")"
  CLEAR_CUT="$(jq -r '.clearCut' <<< "$SCENARIO_OBJ")"
  KNOWN_MISS="$(jq -r '.knownMiss' <<< "$SCENARIO_OBJ")"
  GOLDENABLE="$(jq -r '.goldenable' <<< "$SCENARIO_OBJ")"
  TASK="$(jq -r '.task' <<< "$SCENARIO_OBJ")"

  # Step 1: Materialize workspace
  TEMP_PARENT="$(cd "$(mktemp -d)" && pwd -P)"
  TEMP_WORKSPACE="${TEMP_PARENT}/workspace"
  mkdir -p "${TEMP_WORKSPACE}"

  SCENARIO_SRC_DIR="${REPO_DIR}/fixtures/scenarios/${NAME}"
  cp -Rf "${SCENARIO_SRC_DIR}/workspace/." "${TEMP_WORKSPACE}/"

  (
    cd "${TEMP_WORKSPACE}"
    git init -q
    git config user.name "Evidence Runner"
    git config user.email "runner@example.com"
    git add -A
    git commit -qm baseline
  )

  # Step 2: Pre-repair findings / eval payload (KTD5, KTD10)
  DETECTED=false
  PRECISE=false
  FINDINGS_TEXT=""

  if [ "$KIND" = "finding" ]; then
    PRE_EVAL_JSON=""
    set +e
    PRE_EVAL_JSON="$("${SCRIPT_DIR}/eval-workspace.bash" "${TEMP_WORKSPACE}" 2>/dev/null | sed -n '/^{/,$p')"
    PRE_EC=$?
    set -e
    EXPECTED_FINDINGS_JSON="$(jq -c '.expectedFindings // []' <<< "$SCENARIO_OBJ" 2>/dev/null || echo "[]")"
    [ -z "$EXPECTED_FINDINGS_JSON" ] && EXPECTED_FINDINGS_JSON="[]"
    ACTUAL_FINDINGS_JSON="$(jq -c '.findings // []' <<< "$PRE_EVAL_JSON" 2>/dev/null || echo "[]")"
    [ -z "$ACTUAL_FINDINGS_JSON" ] && ACTUAL_FINDINGS_JSON="[]"

    DETECTED_PRECISE_JSON="$(jq -n \
      --argjson expected "${EXPECTED_FINDINGS_JSON}" \
      --argjson actual "${ACTUAL_FINDINGS_JSON}" \
      '{
        detected: ($expected | all(.[]; . as $e | $actual | any(.[]; .rule == $e.rule and .severity == $e.severity))),
        precise: ($actual | all(.[]; . as $a | $expected | any(.[]; .rule == $a.rule and .severity == $a.severity)))
      }')"

    DETECTED="$(jq -r '.detected // "false"' <<< "$DETECTED_PRECISE_JSON")"
    PRECISE="$(jq -r '.precise // "false"' <<< "$DETECTED_PRECISE_JSON")"

    if [ "$NO_FINDINGS" = "false" ] && [ -n "$PRE_EVAL_JSON" ]; then
      FINDINGS_TEXT="$(jq -r '
        .findings // [] | map(
          "Finding:\n  Rule: \(.rule)\n  Severity: \(.severity)" +
          (if .aspectPath then "\n  Aspect: \(.aspectPath)" else "" end) +
          (if .message then "\n  Message: \(.message)" else "" end)
        ) | join("\n\n")
      ' <<< "$PRE_EVAL_JSON")"
    fi

  elif [ "$KIND" = "eval-error" ]; then
    EXPECTED_ERROR="$(jq -r '.expectedError // ""' <<< "$SCENARIO_OBJ")"
    PRE_EVAL_ERR=""
    set +e
    PRE_EVAL_ERR="$("${SCRIPT_DIR}/eval-workspace.bash" "${TEMP_WORKSPACE}" 2>&1)"
    PRE_EC=$?
    set -e

    if [ $PRE_EC -ne 0 ] && [[ "$PRE_EVAL_ERR" == *"$EXPECTED_ERROR"* ]]; then
      DETECTED=true
      PRECISE=true
    fi

    if [ "$NO_FINDINGS" = "false" ]; then
      FINDINGS_TEXT="$(grep -E "^error:" <<< "$PRE_EVAL_ERR" || echo "$PRE_EVAL_ERR")"
    fi
  fi

  # Step 3: Write Prompt
  PROMPT_FILE="${TEMP_PARENT}/prompt.txt"
  {
    echo "Task: ${TASK}"
    if [ -n "$FINDINGS_TEXT" ]; then
      echo ""
      echo "Pre-repair Report:"
      echo "${FINDINGS_TEXT}"
    fi
    echo ""
    echo "Please repair the defect in place within the workspace."
  } > "${PROMPT_FILE}"

  # Step 4: Invoke Adapter (KTD4, KTD9)
  START_TIME="$(date +%s)"

  export WORKSPACE_DIR="${TEMP_WORKSPACE}"
  export PROMPT_FILE="${PROMPT_FILE}"
  export MAX_TURNS="${MAX_TURNS}"
  export TRANSCRIPT_FILE="${TEMP_PARENT}/transcript.log"

  GOLDEN_DIR_PATH="${SCENARIO_SRC_DIR}/golden"
  if [ "$ADAPTER_NAME" = "stub" ]; then
    export GOLDEN_DIR="${GOLDEN_DIR_PATH}"
  else
    unset GOLDEN_DIR
  fi

  ADAPTER_OUT=""
  set +e
  ADAPTER_OUT=$(run_with_timeout "$TIMEOUT_SEC" "$ADAPTER_SCRIPT" 2>"${TEMP_PARENT}/adapter_stderr.log")
  ADAPTER_EC=$?
  set -e
  END_TIME="$(date +%s)"
  WALL_CLOCK_SEC=$((END_TIME - START_TIME))

  ADAPTER_STATUS=""
  ADAPTER_TURNS="null"

  if [ $ADAPTER_EC -eq 124 ] || [ $ADAPTER_EC -eq 137 ] || [ $ADAPTER_EC -eq 143 ]; then
    ADAPTER_STATUS="timeout"
  elif [ $ADAPTER_EC -ne 0 ]; then
    ADAPTER_STATUS="failed"
  else
    if jq -e . >/dev/null 2>&1 <<< "$ADAPTER_OUT"; then
      ADAPTER_STATUS="$(jq -r '.status // "failed"' <<< "$ADAPTER_OUT")"
      PARSED_TURNS="$(jq -r '.turns' <<< "$ADAPTER_OUT")"
      if [ "$PARSED_TURNS" != "null" ] && [[ "$PARSED_TURNS" =~ ^[0-9]+$ ]]; then
        ADAPTER_TURNS="$PARSED_TURNS"
      fi
    else
      ADAPTER_STATUS="garbage"
    fi
  fi

  # Step 5: Post-run Evaluation & Comparison (KTD6, R9)
  REPAIRED=false
  VERDICT_REASON=""

  if [ "$ADAPTER_STATUS" = "completed" ]; then
    if [ "$GOLDENABLE" = "true" ]; then
      COMPARE_OUT=""
      set +e
      COMPARE_OUT="$("${SCRIPT_DIR}/compare.bash" --repaired "${TEMP_WORKSPACE}" --golden "${GOLDEN_DIR_PATH}" --kind "${KIND}")"
      COMPARE_EC=$?
      set -e

      VERDICT="$(jq -r '.verdict // "FAIL"' <<< "$COMPARE_OUT")"
      MATCH="$(jq -r '.match // false' <<< "$COMPARE_OUT")"
      CLEAN="$(jq -r '.cleanReanalysis // false' <<< "$COMPARE_OUT")"

      if [ "$VERDICT" = "PASS" ]; then
        REPAIRED=true
        VERDICT_REASON="match_and_clean"
      else
        REPAIRED=false
        if [ "$MATCH" = "false" ] && [ "$CLEAN" = "true" ]; then
          VERDICT_REASON="golden_mismatch"
        elif [ "$MATCH" = "true" ] && [ "$CLEAN" = "false" ]; then
          VERDICT_REASON="unclean_reanalysis"
        else
          VERDICT_REASON="mismatch_and_unclean"
        fi
      fi
    else
      REPAIRED=false
      VERDICT_REASON="not_goldenable"
    fi
  else
    REPAIRED=false
    ADAPTER_TURNS="null"
    if [ "$ADAPTER_STATUS" = "timeout" ]; then
      VERDICT_REASON="timeout"
    elif [ "$ADAPTER_STATUS" = "garbage" ]; then
      VERDICT_REASON="garbage_output"
    else
      VERDICT_REASON="adapter_failed"
    fi
  fi
  TIMESTAMP_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Ensure safe defaults for jq argjson
  CLEAR_CUT="${CLEAR_CUT:-false}"
  KNOWN_MISS="${KNOWN_MISS:-false}"
  NO_FINDINGS="${NO_FINDINGS:-false}"
  DETECTED="${DETECTED:-false}"
  PRECISE="${PRECISE:-false}"
  REPAIRED="${REPAIRED:-false}"
  WALL_CLOCK_SEC="${WALL_CLOCK_SEC:-0}"
  ADAPTER_TURNS="${ADAPTER_TURNS:-null}"
  [ -z "$ADAPTER_TURNS" ] && ADAPTER_TURNS="null"

  # Step 6: Emit JSON metrics row
  jq -c -n \
    --arg scenario "$NAME" \
    --arg kind "$KIND" \
    --argjson clearCut "$CLEAR_CUT" \
    --argjson knownMiss "$KNOWN_MISS" \
    --arg adapter "$ADAPTER_NAME" \
    --argjson controlArm "$NO_FINDINGS" \
    --argjson detected "$DETECTED" \
    --argjson precise "$PRECISE" \
    --argjson repaired "$REPAIRED" \
    --arg verdictReason "$VERDICT_REASON" \
    --argjson wallClockSec "$WALL_CLOCK_SEC" \
    --argjson turns "$ADAPTER_TURNS" \
    --arg timestamp "$TIMESTAMP_ISO" \
    '{
      scenario: $scenario,
      kind: $kind,
      clearCut: $clearCut,
      knownMiss: $knownMiss,
      adapter: $adapter,
      controlArm: $controlArm,
      detected: $detected,
      precise: $precise,
      repaired: $repaired,
      verdictReason: $verdictReason,
      wallClockSec: $wallClockSec,
      turns: $turns,
      timestamp: $timestamp
    }' >> "$OUT_FILE"

  rm -rf "${TEMP_PARENT}"
done

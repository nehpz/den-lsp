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
# Host directories for agent CLIs (e.g. claude, omp), applied only to adapter invocation
ADAPTER_PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$HOME/.nix-profile/bin:$HOME/.local/bin:$HOME/.cargo/bin"

NIX_ERR_FILE=""
CURRENT_TEMP_PARENT=""

cleanup() {
  if [ -n "${NIX_ERR_FILE:-}" ] && [ -f "${NIX_ERR_FILE}" ]; then
    rm -f "${NIX_ERR_FILE}"
  fi
  if [ -n "${CURRENT_TEMP_PARENT:-}" ] && [ -d "${CURRENT_TEMP_PARENT}" ]; then
    rm -rf "${CURRENT_TEMP_PARENT}"
  fi
}
trap cleanup EXIT INT TERM

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

NIX_ERR_FILE="$(mktemp)"
set +e
SCENARIOS_JSON="$(nix eval --json --impure "${DEN_DIR_OVERRIDE[@]}" --expr "let s = import ${REPO_DIR}/fixtures/scenarios/lib.nix {}; in s.scenarios" 2>"$NIX_ERR_FILE" | sed -n '/^{/,$p')"
NIX_EC=$?
set -e

if [ $NIX_EC -ne 0 ] || [ -z "$SCENARIOS_JSON" ]; then
  echo "Error: Failed to evaluate scenarios via nix eval (exit code $NIX_EC):" >&2
  cat "$NIX_ERR_FILE" >&2
  rm -f "$NIX_ERR_FILE"
  exit 1
fi
rm -f "$NIX_ERR_FILE"
# Filter scenarios into a JSON array
if [ -n "$TARGET_SCENARIO" ]; then
  FILTER_JQ="[ .[\"${TARGET_SCENARIO}\"] | select(. != null) ]"
elif [ "$SET_NAME" = "clear-cut" ]; then
  FILTER_JQ="[ .[] | select(.clearCut == true and .goldenable == true and .knownMiss == false) ] | sort_by(.name)"
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
    local watcher_pid
    set -m
    "$@" &
    local pid=$!
    set +m
    (
      sleep "$timeout_sec" &
      local sleep_pid=$!
      trap 'kill -9 "$sleep_pid" 2>/dev/null || true' EXIT
      wait "$sleep_pid" 2>/dev/null || true
      kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    ) 2>/dev/null &
    watcher_pid=$!
    set +e
    wait "$pid" 2>/dev/null
    local ec=$?
    pkill -P "$watcher_pid" 2>/dev/null || true
    kill -9 "$watcher_pid" 2>/dev/null || true
    set -e
    return "$ec"
  fi
}

# Start each sweep from a clean slate: stale rows from a previous run would
# double-count scenarios in the readout and can flip its verdict.
: > "$OUT_FILE"
ARTIFACTS_DIR="${OUT_FILE%.jsonl}-artifacts"
rm -rf "${ARTIFACTS_DIR}"
mkdir -p "${ARTIFACTS_DIR}"

jq -c -n \
  --argjson selected "$NUM_SELECTED" \
  --arg adapter "$ADAPTER_NAME" \
  --arg set "$SET_NAME" \
  '{sweepMeta: true, selected: $selected, adapter: $adapter, set: $set}' >> "$OUT_FILE"
# Process each scenario sequentially
SCENARIO_COUNT="$(jq 'length' <<< "$SELECTED_SCENARIOS")"
for ((i=0; i<SCENARIO_COUNT; i++)); do
  SCENARIO_OBJ="$(jq -c ".[$i]" <<< "$SELECTED_SCENARIOS")"
  IFS=$'\t' read -r NAME KIND CLEAR_CUT KNOWN_MISS GOLDENABLE TASK <<< "$(jq -r '[.name, .kind, .clearCut, .knownMiss, .goldenable, .task] | @tsv' <<< "$SCENARIO_OBJ")"

  # Step 1: Materialize workspace
  TEMP_PARENT="$(cd "$(mktemp -d)" && pwd -P)"
  CURRENT_TEMP_PARENT="${TEMP_PARENT}"
  TEMP_WORKSPACE="${TEMP_PARENT}/workspace"
  mkdir -p "${TEMP_WORKSPACE}"

  SCENARIO_SRC_DIR="${REPO_DIR}/fixtures/scenarios/${NAME}"
  cp -Rf "${SCENARIO_SRC_DIR}/workspace/." "${TEMP_WORKSPACE}/"

  # Step 2: Pre-repair findings / eval payload (KTD5, KTD10)
  DETECTED=false
  PRECISE=false
  FINDINGS_TEXT=""
  EMPTY_EXPECTED_GUARD=false
  PRE_EVAL_FAILED=false

  if [ "$KIND" = "finding" ]; then
    PRE_EVAL_JSON=""
    set +e
    PRE_EVAL_JSON="$("${SCRIPT_DIR}/eval-workspace.bash" "${TEMP_WORKSPACE}" 2>/dev/null)"
    PRE_EC=$?
    set -e
    EXPECTED_FINDINGS_JSON="$(jq -c '.expectedFindings // []' <<< "$SCENARIO_OBJ" 2>/dev/null || echo "[]")"
    [ -z "$EXPECTED_FINDINGS_JSON" ] && EXPECTED_FINDINGS_JSON="[]"

    if [ $PRE_EC -ne 0 ] || [ -z "$PRE_EVAL_JSON" ] || ! jq -e . >/dev/null 2>&1 <<< "$PRE_EVAL_JSON"; then
      DETECTED=false
      PRECISE=false
      PRE_EVAL_FAILED=true
    else
      ACTUAL_FINDINGS_JSON="$(jq -c '.findings // []' <<< "$PRE_EVAL_JSON" 2>/dev/null || echo "[]")"
      [ -z "$ACTUAL_FINDINGS_JSON" ] && ACTUAL_FINDINGS_JSON="[]"

      if [ "$EXPECTED_FINDINGS_JSON" = "[]" ]; then
        DETECTED=false
        if [ "$KNOWN_MISS" = "false" ]; then
          PRECISE=false
          EMPTY_EXPECTED_GUARD=true
        else
          if [ "$ACTUAL_FINDINGS_JSON" = "[]" ]; then
            PRECISE=true
          else
            PRECISE=false
          fi
        fi
      else
        DETECTED_PRECISE_JSON="$(jq -n \
          --argjson expected "${EXPECTED_FINDINGS_JSON}" \
          --argjson actual "${ACTUAL_FINDINGS_JSON}" \
          '{
            detected: (($expected | map({rule, severity})) as $exp | ($actual | map({rule, severity})) as $act | (($exp | length > 0) and ($exp | group_by(.) | all(.[0] as $item | (length <= ($act | map(select(. == $item)) | length)))))),
            precise: (($expected | map({rule, severity})) as $exp | ($actual | map({rule, severity})) as $act | ($act | group_by(.) | all(.[0] as $item | (length <= ($exp | map(select(. == $item)) | length)))))
          }')"

        DETECTED="$(jq -r '.detected // "false"' <<< "$DETECTED_PRECISE_JSON")"
        PRECISE="$(jq -r '.precise // "false"' <<< "$DETECTED_PRECISE_JSON")"
      fi

      if [ "$NO_FINDINGS" = "false" ] && [ -n "$PRE_EVAL_JSON" ]; then
        FINDINGS_TEXT="$(jq -r '
          .findings // [] | map(
            "Finding:\n  Rule: \(.rule)\n  Severity: \(.severity)" +
            (if .aspectPath then "\n  Aspect: \(.aspectPath)" else "" end) +
            (if .position and .position.file then "\n  File: \(.position.file)" else "" end) +
            (if .position and .position.line then "\n  Line: \(.position.line)" else "" end) +
            (if .message then "\n  Message: \(.message)" else "" end)
          ) | join("\n\n")
        ' <<< "$PRE_EVAL_JSON")"
      fi
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
      FINDINGS_TEXT="$PRE_EVAL_ERR"
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
  cp "${PROMPT_FILE}" "${TEMP_WORKSPACE}/TASK.md"

  (
    cd "${TEMP_WORKSPACE}"
    git init -q
    git config user.name "Evidence Runner"
    git config user.email "runner@example.com"
    git add -A
    git commit -qm baseline
  )


  # Step 4: Invoke Adapter (KTD4, KTD9)
  START_TIME="$(date +%s)"

  export WORKSPACE_DIR="${TEMP_WORKSPACE}"
  export PROMPT_FILE="${PROMPT_FILE}"
  export MAX_TURNS="${MAX_TURNS}"
  export TRANSCRIPT_FILE="${TEMP_PARENT}/transcript.log"
  touch "${TRANSCRIPT_FILE}"

  GOLDEN_DIR_PATH="${SCENARIO_SRC_DIR}/golden"
  if [ "$ADAPTER_NAME" = "stub" ]; then
    export GOLDEN_DIR="${GOLDEN_DIR_PATH}"
  else
    unset GOLDEN_DIR
  fi

  ADAPTER_OUT=""
  set +e
  if [ "$ADAPTER_NAME" = "stub" ]; then
    ADAPTER_OUT=$(run_with_timeout "$TIMEOUT_SEC" env PATH="$ADAPTER_PATH" "$ADAPTER_SCRIPT" 2>"${TEMP_PARENT}/adapter_stderr.log")
  else
    ADAPTER_OUT=$(run_with_timeout "$TIMEOUT_SEC" env -u REPO_DIR -u GOLDEN_DIR PATH="$ADAPTER_PATH" "$ADAPTER_SCRIPT" 2>"${TEMP_PARENT}/adapter_stderr.log")
  fi
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

  if [ "${PRE_EVAL_FAILED:-false}" = "true" ]; then
    REPAIRED=false
    VERDICT_REASON="pre_eval_failed"
  elif [ "$ADAPTER_STATUS" = "completed" ]; then
    if [ "${EMPTY_EXPECTED_GUARD:-false}" = "true" ]; then
      REPAIRED=false
      VERDICT_REASON="empty_expected"
    elif [ "$GOLDENABLE" = "true" ]; then
      EXPECTED_RULES=()
      if [ "$KIND" = "finding" ]; then
        mapfile -t EXPECTED_RULES < <(jq -r '.expectedFindings[]?.rule // empty' <<< "$SCENARIO_OBJ")
      fi

      COMPARE_OUT=""
      set +e
      COMPARE_OUT="$("${SCRIPT_DIR}/compare.bash" --repaired "${TEMP_WORKSPACE}" --golden "${GOLDEN_DIR_PATH}" --kind "${KIND}" ${EXPECTED_RULES[@]+--expected-rules "${EXPECTED_RULES[@]}"})"
      COMPARE_EC=$?
      set -e

      if jq -e . >/dev/null 2>&1 <<< "$COMPARE_OUT"; then
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
        VERDICT="FAIL"
        MATCH=false
        CLEAN=false
        VERDICT_REASON="compare_failed"
        REPAIRED=false
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
  GOLDENABLE="${GOLDENABLE:-false}"
  NO_FINDINGS="${NO_FINDINGS:-false}"
  DETECTED="${DETECTED:-false}"
  PRECISE="${PRECISE:-false}"
  REPAIRED="${REPAIRED:-false}"
  WALL_CLOCK_SEC="${WALL_CLOCK_SEC:-0}"
  ADAPTER_TURNS="${ADAPTER_TURNS:-null}"

  # Step 6: Emit JSON metrics row
  jq -c -n \
    --arg scenario "$NAME" \
    --arg kind "$KIND" \
    --argjson clearCut "$CLEAR_CUT" \
    --argjson knownMiss "$KNOWN_MISS" \
    --argjson goldenable "$GOLDENABLE" \
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
      goldenable: $goldenable,
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
  SCENARIO_ARTIFACTS_DIR="${OUT_FILE%.jsonl}-artifacts/${NAME}"
  mkdir -p "${SCENARIO_ARTIFACTS_DIR}"
  for artifact_file in prompt.txt transcript.log adapter_stderr.log; do
    if [ -f "${TEMP_PARENT}/${artifact_file}" ]; then
      cp "${TEMP_PARENT}/${artifact_file}" "${SCENARIO_ARTIFACTS_DIR}/${artifact_file}"
    fi
  done

  rm -rf "${TEMP_PARENT}"
  CURRENT_TEMP_PARENT=""
done

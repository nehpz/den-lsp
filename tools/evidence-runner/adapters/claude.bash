#!/usr/bin/env bash
set -euo pipefail

# Adapter for Claude-family CLI (e.g. claude or omp)
# Best-effort real adapter.
# Runtime flag discovery during bring-up: probes --help at runtime and degrades gracefully.
# DO NOT fabricate flags.
#
# Environment inputs:
# WORKSPACE_DIR   - target materialized workspace
# PROMPT_FILE     - text prompt file path
# MAX_TURNS       - turn cap
# TRANSCRIPT_FILE - log output path
# Note: GOLDEN_DIR is intentionally NOT provided (golden leakage guard per KTD7).

WORKSPACE_DIR="${WORKSPACE_DIR:?WORKSPACE_DIR must be set}"
PROMPT_FILE="${PROMPT_FILE:?PROMPT_FILE must be set}"
MAX_TURNS="${MAX_TURNS:-25}"
TRANSCRIPT_FILE="${TRANSCRIPT_FILE:-/dev/null}"

# Discover CLI binary
CLI_BIN=""
if command -v claude >/dev/null 2>&1; then
  CLI_BIN="claude"
elif command -v omp >/dev/null 2>&1; then
  CLI_BIN="omp"
fi

if [ -z "$CLI_BIN" ]; then
  echo "claude.bash: neither 'claude' nor 'omp' binary found in PATH" >&2
  echo '{"status":"failed","turns":null}'
  exit 1
fi

# Probe --help output at runtime
HELP_TEXT=""
set +e
HELP_TEXT="$("$CLI_BIN" --help 2>&1)"
set -e

# Inspect HELP_TEXT for supported flags without fabricating flags
INVOCATION=()
if [[ "$HELP_TEXT" == *"--prompt-file"* ]]; then
  INVOCATION=("$CLI_BIN" --prompt-file "$PROMPT_FILE")
elif [[ "$HELP_TEXT" == *"-p "* ]] || [[ "$HELP_TEXT" == *"--prompt "* ]]; then
  PROMPT_TEXT="$(cat "$PROMPT_FILE")"
  INVOCATION=("$CLI_BIN" -p "$PROMPT_TEXT")
else
  # Fallback: flag discovery did not match known shapes
  echo "claude.bash: no known CLI prompt flag pattern found in '$CLI_BIN --help'" >&2
  echo '{"status":"failed","turns":null}'
  exit 1
fi

if [[ "$HELP_TEXT" == *"--max-turns"* ]]; then
  INVOCATION+=("--max-turns" "$MAX_TURNS")
else
  echo "claude.bash: turn cap is enforced only by runner's wall-clock timeout because '$CLI_BIN' does not advertise --max-turns" >&2
fi

# Execute CLI in WORKSPACE_DIR
set +e
(
  cd "$WORKSPACE_DIR"
  "${INVOCATION[@]}"
) >"$TRANSCRIPT_FILE" 2>&1
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
  echo "claude.bash: $CLI_BIN exited with code $EXIT_CODE" >&2
  echo '{"status":"failed","turns":null}'
  exit 1
fi

# Best-effort turn count parsing from transcript
TURNS="null"
if [ -f "$TRANSCRIPT_FILE" ]; then
  PARSED_TURNS="$(grep -Eo '"turns":[0-9]+' "$TRANSCRIPT_FILE" | head -n 1 | cut -d: -f2 || true)"
  if [ -n "$PARSED_TURNS" ]; then
    TURNS="$PARSED_TURNS"
  fi
fi

jq -c -n --arg status "completed" --argjson turns "$TURNS" '{status: $status, turns: $turns}'

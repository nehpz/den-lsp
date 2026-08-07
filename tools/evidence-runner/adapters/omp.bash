#!/usr/bin/env bash
set -euo pipefail

# Adapter for the omp CLI, isolated from the user's default profile.
#
# Environment inputs (runner contract):
#   WORKSPACE_DIR   - target materialized workspace
#   PROMPT_FILE     - text prompt file path
#   MAX_TURNS       - turn cap (advisory: omp has no --max-turns; the runner's
#                     wall-clock timeout is the enforced cap)
#   TRANSCRIPT_FILE - log output path
# Note: GOLDEN_DIR is intentionally NOT provided (golden leakage guard per KTD7).
#
# Adapter knobs:
#   OMP_MODEL             - model for the run (required; recorded in the metrics row)
#   OMP_THINKING          - thinking level (optional: off|minimal|low|medium|high|xhigh|max|auto)
#   OMP_EVIDENCE_PROFILE  - isolated omp profile name (default: evidence-runner)
#   OMP_AUTH_BROKER_URL   - auth broker URL (default: http://127.0.0.1:8765)
#   OMP_AUTH_BROKER_TOKEN - broker bearer (default: contents of ~/.omp/auth-broker.token)

WORKSPACE_DIR="${WORKSPACE_DIR:?WORKSPACE_DIR must be set}"
PROMPT_FILE="${PROMPT_FILE:?PROMPT_FILE must be set}"
TRANSCRIPT_FILE="${TRANSCRIPT_FILE:-/dev/null}"

fail() {
  echo "omp.bash: $1" >&2
  jq -c -n --arg m "${OMP_MODEL:-}" --arg t "${OMP_THINKING:-}" \
    '{status: "failed", turns: null, model: (if $m == "" then null else $m end), thinking: (if $t == "" then null else $t end)}'
  exit 1
}

command -v omp >/dev/null 2>&1 || fail "'omp' binary not found in PATH"
command -v jq >/dev/null 2>&1 || { echo "omp.bash: jq not found" >&2; echo '{"status":"failed","turns":null}'; exit 1; }
[ -n "${OMP_MODEL:-}" ] || fail "OMP_MODEL must be set: the model choice is part of the readout's provenance"

# Hard isolation wall: a named profile relocates the whole agent state dir
# (sessions, memory, skills, settings, agent.db) to
# ~/.omp/profiles/<name>/agent, so benchmark runs never write into the
# user's ~/.omp/agent.
export OMP_PROFILE="${OMP_EVIDENCE_PROFILE:-evidence-runner}"

# The isolated profile holds no credentials; resolve auth through the
# already-running auth broker (env wins over any profile config).
export OMP_AUTH_BROKER_URL="${OMP_AUTH_BROKER_URL:-http://127.0.0.1:8765}"
if [ -z "${OMP_AUTH_BROKER_TOKEN:-}" ]; then
  if [ -f "$HOME/.omp/auth-broker.token" ]; then
    OMP_AUTH_BROKER_TOKEN="$(cat "$HOME/.omp/auth-broker.token")"
    export OMP_AUTH_BROKER_TOKEN
  else
    fail "no OMP_AUTH_BROKER_TOKEN and $HOME/.omp/auth-broker.token not found; is the auth broker set up?"
  fi
fi

# Vanilla-agent loadout: no personal skills/extensions/rules. The fresh
# profile already defaults memory to off; the flags make the benchmark
# surface explicit rather than config-dependent. Sessions are kept (inside
# the isolated profile) so failed runs can be rendered with
# `omp --export <session.jsonl>` or interrogated with
# `OMP_PROFILE=<profile> omp --resume <id>` during repair-rate tuning.
ARGS=(-p --mode json --model "$OMP_MODEL" --no-skills --no-extensions --no-rules --auto-approve)
if [ -n "${OMP_THINKING:-}" ]; then
  ARGS+=(--thinking "$OMP_THINKING")
fi

echo "omp.bash: profile=$OMP_PROFILE model=$OMP_MODEL thinking=${OMP_THINKING:-default}" >&2
echo "omp.bash: turn cap (MAX_TURNS=${MAX_TURNS:-unset}) is enforced only by the runner's wall-clock timeout; omp advertises no --max-turns" >&2

PROMPT_TEXT="$(cat "$PROMPT_FILE")"

set +e
(
  cd "$WORKSPACE_DIR"
  omp "${ARGS[@]}" "$PROMPT_TEXT"
) >"$TRANSCRIPT_FILE" 2>&1
EXIT_CODE=$?
set -e

[ $EXIT_CODE -eq 0 ] || fail "omp exited with code $EXIT_CODE (transcript: $TRANSCRIPT_FILE)"

# Turn count from --mode json output: one turn_end event per agent turn
# (verified against omp 17.2.10 event stream).
TURNS="null"
if [ -f "$TRANSCRIPT_FILE" ]; then
  TURN_END_COUNT="$(grep -c '"type":"turn_end"' "$TRANSCRIPT_FILE" 2>/dev/null || true)"
  if [ -n "$TURN_END_COUNT" ] && [ "$TURN_END_COUNT" -gt 0 ] 2>/dev/null; then
    TURNS="$TURN_END_COUNT"
  fi
fi

# LLM cost and token usage: sum per-assistant-message usage from the event
# stream (message_end is emitted once per assistant message; skips non-JSON
# stderr lines mixed into the transcript).
COST="null"
TOKENS="null"
if [ -f "$TRANSCRIPT_FILE" ]; then
  USAGE_JSON="$(jq -Rrs -c '[split("\n")[] | fromjson? | select(.type=="message_end" and .message.role=="assistant")] | if length == 0 then {cost: null, tokens: null} else {cost: ([.[] | .message.usage.cost.total // 0] | add), tokens: ([.[] | .message.usage.totalTokens // 0] | add)} end' "$TRANSCRIPT_FILE" 2>/dev/null || echo '{"cost":null,"tokens":null}')"
  COST="$(jq -r '.cost // "null"' <<< "$USAGE_JSON")"
  TOKENS="$(jq -r '.tokens // "null"' <<< "$USAGE_JSON")"
fi

jq -c -n \
  --argjson turns "$TURNS" \
  --arg model "$OMP_MODEL" \
  --arg thinking "${OMP_THINKING:-}" \
  --argjson cost "$COST" \
  --argjson tokens "$TOKENS" \
  '{status: "completed", turns: $turns, model: $model, thinking: (if $thinking == "" then null else $thinking end), cost: $cost, tokens: $tokens}'

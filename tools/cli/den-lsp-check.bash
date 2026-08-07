#!/usr/bin/env bash
set -euo pipefail

# den-lsp-check — Runtime evaluation CLI for Den consumer flakes (R4, R5, R6, R7).
#
# Usage: den-lsp-check [--json] [--draft|--gate] [--timeout <seconds>] [workspace]
#
# Contracts (KTD3, KTD4, KTD5):
#   - Evaluates target workspace at invocation time via the U1 ephemeral wrapper (nix/ephemeral.nix).
#   - Workspace default is cwd.
#   - Exit taxonomy:
#       0 = pass (clean, advisory-only, or gating under --draft)
#       1 = gating findings under --gate (default mode)
#       2 = evaluation failure (kind: eval-error) OR unsupported target (kind: unsupported)
#       3 = timeout (kind: timeout)
#      64 = usage error (unknown flag / invalid options; nothing on stdout)
#   - Output:
#       Default: human text rendered per nix/engine/render.nix.
#       --json: JSON document or error envelope verbatim on stdout.
#       ALL diagnostics/human chatter to stderr.
#       stdout in --json mode is ALWAYS exactly one valid JSON value.

JSON_MODE=false
MODE="gate"
TIMEOUT=120
POS_WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=true
      shift
      ;;
    --draft)
      MODE="draft"
      shift
      ;;
    --gate)
      MODE="gate"
      shift
      ;;
    --timeout)
      if [[ $# -lt 2 ]]; then
        echo "error: --timeout requires a seconds argument" >&2
        exit 64
      fi
      TIMEOUT="$2"
      shift 2
      ;;
    --timeout=*)
      TIMEOUT="${1#*=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown flag '$1'" >&2
      exit 64
      ;;
    *)
      if [[ -n "${POS_WORKSPACE}" ]]; then
        echo "error: unexpected extra argument '$1'" >&2
        exit 64
      fi
      POS_WORKSPACE="$1"
      shift
      ;;
  esac
done

if ! [[ "$TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "error: invalid timeout value '$TIMEOUT'" >&2
  exit 64
fi

RAW_WORKSPACE="${POS_WORKSPACE:-.}"
if [[ "$RAW_WORKSPACE" =~ ^(github:|git:|path:) ]]; then
  WORKSPACE="$RAW_WORKSPACE"
elif [ -d "$RAW_WORKSPACE" ]; then
  WORKSPACE="$(cd "$RAW_WORKSPACE" && pwd)"
elif [ -f "$RAW_WORKSPACE" ]; then
  WORKSPACE="$(cd "$(dirname "$RAW_WORKSPACE")" && pwd)/$(basename "$RAW_WORKSPACE")"
else
  WORKSPACE="$RAW_WORKSPACE"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_EPHEMERAL="${SCRIPT_DIR}/../../nix/ephemeral.nix"
DEFAULT_DEN_LSP="${SCRIPT_DIR}/../.."

EPHEMERAL_NIX="${EPHEMERAL_NIX:-$DEFAULT_EPHEMERAL}"
DEN_LSP_FLAKE="${DEN_LSP_FLAKE:-$DEFAULT_DEN_LSP}"

NIX_ARGS=()
if [ -n "${DEN_LSP_CHECK_NIX_ARGS:-}" ]; then
  read -r -a NIX_ARGS <<< "$DEN_LSP_CHECK_NIX_ARGS"
fi

NIX_STDOUT="$(mktemp)"
NIX_STDERR="$(mktemp)"
trap 'rm -f "$NIX_STDOUT" "$NIX_STDERR"' EXIT

NIX_EXPR="import ${EPHEMERAL_NIX} { workspace = \"${WORKSPACE}\"; den-lsp = ${DEN_LSP_FLAKE}; }"

set +e
timeout "${TIMEOUT}s" nix eval --impure --json ${NIX_ARGS+"${NIX_ARGS[@]}"} --expr "$NIX_EXPR" >"$NIX_STDOUT" 2>"$NIX_STDERR"
EVAL_EXIT=$?
set -e

if [ "$EVAL_EXIT" -eq 124 ] || [ "$EVAL_EXIT" -eq 137 ]; then
  cat "$NIX_STDERR" >&2
  if [ "$JSON_MODE" = true ]; then
    jq -n --arg sec "$TIMEOUT" '{"version":1,"error":{"kind":"timeout","message":("Evaluation timed out after " + $sec + " seconds")}}'
  else
    echo "den-lsp: error [timeout]: Evaluation timed out after ${TIMEOUT} seconds" >&2
  fi
  exit 3
fi

if [ "$EVAL_EXIT" -ne 0 ]; then
  cat "$NIX_STDERR" >&2
  if [ "$JSON_MODE" = true ]; then
    STDERR_TEXT="$(cat "$NIX_STDERR")"
    jq -n --arg msg "$STDERR_TEXT" '{"version":1,"error":{"kind":"eval-error","message":$msg}}'
  else
    echo "den-lsp: error [eval-error]: evaluation failed" >&2
  fi
  exit 2
fi

# Evaluation succeeded (nix eval exit 0)
cat "$NIX_STDERR" >&2

IS_ERROR="$(jq -r '.error != null' "$NIX_STDOUT" 2>/dev/null || echo "false")"
if [ "$IS_ERROR" = "true" ]; then
  if [ "$JSON_MODE" = true ]; then
    cat "$NIX_STDOUT"
  else
    ERR_MSG="$(jq -r '.error.message // "unsupported target"' "$NIX_STDOUT")"
    ERR_KIND="$(jq -r '.error.kind // "unsupported"' "$NIX_STDOUT")"
    echo "den-lsp: error [${ERR_KIND}]: ${ERR_MSG}" >&2
  fi
  exit 2
fi

GATING="$(jq -r '.summary.gating // 0' "$NIX_STDOUT")"

if [ "$JSON_MODE" = true ]; then
  cat "$NIX_STDOUT"
else
  jq -r '
  if .findings | length == 0 then
    "den-lsp: no findings."
  else
    "den-lsp: \(.summary.gating) gating, \(.summary.advisory) advisory finding(s).\n" +
    (.findings | map(
      (if .severity == "gating" then "✗" else "•" end) +
      " [" + .severity + "] " + .rule + " — " + .aspectPath + "\n" +
      "  " + .message + "\n" +
      "  fix: " + .fix +
      (if .position != null then "\n  at: " + .position.file + ":" + (.position.line | tostring) else "" end) + "\n" +
      "  ref: " + .docRef
    ) | join("\n"))
  end' "$NIX_STDOUT"

  if [ "$GATING" -gt 0 ] && [ "$MODE" = "gate" ]; then
    echo >&2
    echo "den-lsp: gating findings — apply the fixes above." >&2
  fi
fi

if [ "$GATING" -gt 0 ] && [ "$MODE" = "gate" ]; then
  exit 1
else
  exit 0
fi

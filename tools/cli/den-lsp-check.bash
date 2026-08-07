#!/usr/bin/env bash
set -euo pipefail

# den-lsp-check — Runtime evaluation CLI for Den consumer flakes (R4, R5, R6, R7).
#
# Usage: den-lsp-check [--json] [--draft|--gate] [--timeout <seconds>] [workspace]
#
# Contracts (KTD3, KTD4, KTD5):
#   - Evaluates target workspace at invocation time via the U1 ephemeral wrapper (nix/ephemeral.nix).
#   - Workspace default is cwd.
#       3 = timeout (kind: timeout) — coreutils timeout exit code 124
#      64 = usage error (unknown flag / invalid options; nothing on stdout)
#   - Output:
#       Default: human text rendered per nix/engine/render.nix.
#       --json: JSON document or error envelope verbatim on stdout.
#       ALL diagnostics/human chatter to stderr.
#       stdout in --json mode is ALWAYS exactly one valid JSON value.
#
# Note: DEN_LSP_CHECK_NIX_ARGS is a test/development seam that appends caller-controlled nix flags, not a hardened boundary.
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
      # Everything after -- is positional; still enforce the one-workspace contract.
      for arg in "$@"; do
        if [[ -n "${POS_WORKSPACE}" ]]; then
          echo "error: unexpected extra argument '$arg'" >&2
          exit 64
        fi
        POS_WORKSPACE="$arg"
      done
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

if ! [[ "$TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$TIMEOUT" =~ ^0+(\.0+)?$ ]]; then
  echo "error: invalid timeout value '$TIMEOUT'" >&2
  exit 64
fi

RAW_WORKSPACE="${POS_WORKSPACE:-.}"
if [[ "$RAW_WORKSPACE" =~ ^(github:|git:|path:) ]]; then
  WORKSPACE="$RAW_WORKSPACE"
elif [ -d "$RAW_WORKSPACE" ]; then
  WORKSPACE="$(cd "$RAW_WORKSPACE" && pwd)"
elif [ -f "$RAW_WORKSPACE" ]; then
  WORKSPACE="$(cd "$(dirname "$RAW_WORKSPACE")" && pwd)"
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
NIX_STDERR_CAPPED="$(mktemp)"
trap 'rm -f "$NIX_STDOUT" "$NIX_STDERR" "$NIX_STDERR_CAPPED"' EXIT

format_capped_stderr() {
  local src="$1"
  local dst="$2"
  local orig_lines orig_bytes
  orig_lines=$(wc -l < "$src")
  orig_bytes=$(wc -c < "$src")

  if [ "$orig_lines" -gt 200 ] || [ "$orig_bytes" -gt 16384 ]; then
    printf '[stderr output truncated to last 200 lines / 16KiB]\n' > "$dst"
    tail -n 200 "$src" | tail -c 16384 >> "$dst"
  else
    cat "$src" > "$dst"
  fi
}

WORKSPACE_NIX="$(printf '%s' "$WORKSPACE" | jq -Rs .)"
EPHEMERAL_NIX_JSON="$(printf '%s' "$EPHEMERAL_NIX" | jq -Rs .)"
DEN_LSP_FLAKE_JSON="$(printf '%s' "$DEN_LSP_FLAKE" | jq -Rs .)"
NIX_EXPR="import (/. + ${EPHEMERAL_NIX_JSON}) { workspace = ${WORKSPACE_NIX}; den-lsp = (/. + ${DEN_LSP_FLAKE_JSON}); }"

set +e
# ${NIX_ARGS+...}: empty-array expansion under `set -u` errors on bash < 4.4 (macOS system bash).
timeout "${TIMEOUT}s" nix eval --impure --json ${NIX_ARGS+"${NIX_ARGS[@]}"} --expr "$NIX_EXPR" >"$NIX_STDOUT" 2>"$NIX_STDERR"
EVAL_EXIT=$?
set -e

# Coreutils `timeout` returns exit status 124 when timing out.
# Exit status 137 (SIGKILL/OOM) is mapped to eval-error (exit status 2).
if [ "$EVAL_EXIT" -eq 124 ]; then
  cat "$NIX_STDERR" >&2
  if [ "$JSON_MODE" = true ]; then
    jq -n --arg sec "$TIMEOUT" '{"version":1,"error":{"kind":"timeout","message":("Evaluation timed out after " + $sec + " seconds")}}'
  else
    echo "den-lsp: error [timeout]: Evaluation timed out after ${TIMEOUT} seconds" >&2
  fi
  exit 3
fi

if [ "$EVAL_EXIT" -ne 0 ]; then
  if [ "$EVAL_EXIT" -eq 137 ] && [ ! -s "$NIX_STDERR" ]; then
    echo "evaluation process was killed (exit status 137, possibly OOM)" >"$NIX_STDERR"
  fi
  cat "$NIX_STDERR" >&2
  if [ "$JSON_MODE" = true ]; then
    format_capped_stderr "$NIX_STDERR" "$NIX_STDERR_CAPPED"
    jq -n --rawfile msg "$NIX_STDERR_CAPPED" '{"version":1,"error":{"kind":"eval-error","message":$msg}}'
  else
    echo "den-lsp: error [eval-error]: evaluation failed" >&2
  fi
  exit 2
fi

# Evaluation succeeded (nix eval exit 0)
cat "$NIX_STDERR" >&2

if ! jq empty "$NIX_STDOUT" 2>/dev/null; then
  if [ "$JSON_MODE" = true ]; then
    jq -n --arg msg "invalid JSON output from nix eval" '{"version":1,"error":{"kind":"eval-error","message":$msg}}'
  else
    echo "den-lsp: error [eval-error]: invalid JSON output from nix eval" >&2
  fi
  exit 2
fi
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

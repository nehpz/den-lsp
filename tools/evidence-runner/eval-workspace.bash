#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${REPO_DIR:-}" ] || [ ! -f "${REPO_DIR}/flake.nix" ]; then
  if [ -f "${SCRIPT_DIR}/../../flake.nix" ]; then
    REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
  elif [ -f "./flake.nix" ]; then
    REPO_DIR="$(pwd)"
  elif git rev-parse --show-toplevel >/dev/null 2>&1 && [ -f "$(git rev-parse --show-toplevel)/flake.nix" ]; then
    REPO_DIR="$(git rev-parse --show-toplevel)"
  else
    echo "Error: Could not locate repo directory containing flake.nix" >&2
    exit 1
  fi
fi
DEN_DIR="${DEN_DIR:-}"

if [ "$#" -lt 1 ]; then
  echo "Usage: eval-workspace.bash <workspace_dir>" >&2
  exit 1
fi

WORKSPACE_DIR="$(cd "$1" && pwd -P)"

# Use top-level scenario lock file for pin-parity with hermetic CI when running unlocked workspace subflakes.
LOCK_FILE="${REPO_DIR}/fixtures/scenarios/flake.lock"
OVERRIDE_ARGS=()
if [ -f "${LOCK_FILE}" ]; then
  OVERRIDE_ARGS+=(--reference-lock-file "${LOCK_FILE}")
fi
if [ -n "${DEN_DIR:-}" ]; then
  OVERRIDE_ARGS+=(--override-input den "${DEN_DIR}")
fi
OVERRIDE_ARGS+=(--override-input den-lsp "${REPO_DIR}")

nix eval --impure --json "path:${WORKSPACE_DIR}#den-lsp-analysis" "${OVERRIDE_ARGS[@]}" | sed -n '/^{/,$p'

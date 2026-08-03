#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEN_DIR="${DEN_DIR:-}"

if [ "$#" -lt 1 ]; then
  echo "Usage: eval-workspace.bash <workspace_dir>" >&2
  exit 1
fi

WORKSPACE_DIR="$(cd "$1" && pwd)"

OVERRIDE_ARGS=()
if [ -n "${DEN_DIR:-}" ]; then
  OVERRIDE_ARGS+=(--override-input den "${DEN_DIR}")
fi
OVERRIDE_ARGS+=(--override-input den-lsp "${REPO_DIR}")

nix eval --json "path:${WORKSPACE_DIR}#den-lsp-analysis" "${OVERRIDE_ARGS[@]}"

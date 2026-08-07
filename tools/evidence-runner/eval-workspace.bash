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
# Reference lock alone is insufficient because Nix reuses a locked node only when the flake's declared original ref
# matches the reference lock's original ref. Workspace/consumer fixtures declare bare github:denful/den while scenarios
# specify github:denful/den/v0.18.0 (and nixpkgs original refs also differ), causing Nix to float unpinned inputs.
LOCK_FILE="${REPO_DIR}/fixtures/scenarios/flake.lock"
OVERRIDE_ARGS=()
if [ -f "${LOCK_FILE}" ]; then
  OVERRIDE_ARGS+=(--reference-lock-file "${LOCK_FILE}")

  NIXPKGS_OVERRIDE=$(jq -r '.nodes[.root].inputs.nixpkgs as $n | .nodes[$n].locked | select(. != null) | if .type == "github" and (.owner != null and .repo != null and .rev != null) then "github:" + .owner + "/" + .repo + "/" + .rev elif (.type == "tarball" or .type == "flakehub") and (.url != null and .url != "") then .url else empty end' "${LOCK_FILE}" 2>/dev/null || true)
  if [ -n "${NIXPKGS_OVERRIDE}" ]; then
    OVERRIDE_ARGS+=(--override-input nixpkgs "${NIXPKGS_OVERRIDE}")
  else
    echo "Skipping nixpkgs override: unsupported locked type or missing URL in reference lock" >&2
  fi

  if [ -z "${DEN_DIR:-}" ]; then
    DEN_REV=$(jq -r '.nodes[.root].inputs.den as $n | .nodes[$n].locked | select(. != null) | .rev // empty' "${LOCK_FILE}" 2>/dev/null || true)
    if [ -n "${DEN_REV}" ]; then
      OVERRIDE_ARGS+=(--override-input den "github:denful/den/${DEN_REV}")
    fi
  fi
fi
if [ -n "${DEN_DIR:-}" ]; then
  OVERRIDE_ARGS+=(--override-input den "${DEN_DIR}")
fi
OVERRIDE_ARGS+=(--override-input den-lsp "${REPO_DIR}")

IS_INSTRUMENTED=false
if [ -f "${WORKSPACE_DIR}/flake.nix" ] && grep -qE 'den-lsp\.url|inputs\.den-lsp|den-lsp\.flakeModules' "${WORKSPACE_DIR}/flake.nix"; then
  IS_INSTRUMENTED=true
fi

if [ "$IS_INSTRUMENTED" = true ]; then
  nix eval --impure --json "path:${WORKSPACE_DIR}#den-lsp-analysis" "${OVERRIDE_ARGS[@]}" | sed -n '/^{/,$p'
else
  EPHEMERAL_NIX="${REPO_DIR}/nix/ephemeral.nix"
  WORKSPACE_NIX="$(printf '%s' "path:${WORKSPACE_DIR}" | jq -Rs .)"
  NIX_EXPR="import ${EPHEMERAL_NIX} { workspace = ${WORKSPACE_NIX}; den-lsp = \"path:${REPO_DIR}\"; }"
  nix eval --impure --json "${OVERRIDE_ARGS[@]}" --expr "$NIX_EXPR" | sed -n '/^{/,$p'
fi

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEN_DIR="${DEN_DIR:-}"

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
echo "Detected system: ${SYSTEM}"

# Pin parity: reference scenarios lockfile so unlocked consumer flakes use identical pinned dependencies (den, nixpkgs, flake-parts) as hermetic tests.
OVERRIDE_ARGS=()
if [ -f "${REPO_DIR}/fixtures/scenarios/flake.lock" ]; then
  echo "Using reference lock file: ${REPO_DIR}/fixtures/scenarios/flake.lock"
  OVERRIDE_ARGS+=(--reference-lock-file "${REPO_DIR}/fixtures/scenarios/flake.lock")
fi
if [ -n "${DEN_DIR:-}" ]; then
  echo "Using den repo override: ${DEN_DIR}"
  OVERRIDE_ARGS+=(--override-input den "${DEN_DIR}")
else
  echo "Using upstream den repo from flake input"
fi
echo "Using den-lsp repo override: ${REPO_DIR}"
OVERRIDE_ARGS+=(--override-input den-lsp "${REPO_DIR}")
echo

FAILED=0

# Run base fixture check (nix build)
echo "==> Testing base fixture (nix build)..."
set +e
output=$(nix build "${REPO_DIR}/fixtures/consumer#checks.${SYSTEM}.den-lsp" \
  --no-link \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -eq 0 ]; then
  echo "PASS: base build (exit 0)"
else
  echo "FAIL: base build expected exit 0 but got ${exit_code}"
  echo "${output}"
  FAILED=1
fi

# Run base fixture app (nix run .#den-lsp-check)
echo "==> Testing base fixture app (nix run)..."
set +e
output=$(nix run "${REPO_DIR}/fixtures/consumer#den-lsp-check" \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -eq 0 ]; then
  echo "PASS: base app run (exit 0)"
else
  echo "FAIL: base app run expected exit 0 but got ${exit_code}"
  echo "${output}"
  FAILED=1
fi

# Run gating-dup variant
echo "==> Testing gating-dup variant..."
set +e
output=$(nix build "${REPO_DIR}/fixtures/consumer-variants/gating-dup#checks.${SYSTEM}.den-lsp" \
  --no-link \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -ne 0 ]; then
  if echo "${output}" | grep -q "web" && echo "${output}" | grep -q "db"; then
    echo "PASS: gating-dup (exit nonzero and mentioned both 'web' and 'db')"
  else
    echo "FAIL: gating-dup exited nonzero but output did not mention both aspect names 'web' and 'db'"
    echo "${output}"
    FAILED=1
  fi
else
  echo "FAIL: gating-dup expected nonzero exit code but got 0"
  echo "${output}"
  FAILED=1
fi

# Run advisory-only variant
echo "==> Testing advisory-only variant..."
set +e
output=$(nix build "${REPO_DIR}/fixtures/consumer-variants/advisory-only#checks.${SYSTEM}.den-lsp" \
  --no-link \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -eq 0 ]; then
  echo "PASS: advisory-only (exit 0)"
else
  echo "FAIL: advisory-only expected exit 0 but got ${exit_code}"
  echo "${output}"
  FAILED=1
fi

# Run broken variant
echo "==> Testing broken variant..."
set +e
output=$(nix build "${REPO_DIR}/fixtures/consumer-variants/broken#checks.${SYSTEM}.den-lsp" \
  --no-link \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -ne 0 ]; then
  if echo "${output}" | grep -q "trigger.nix"; then
    echo "PASS: broken (exit nonzero and output referenced failing file trigger.nix)"
  else
    echo "FAIL: broken exited nonzero but output did not reference failing file trigger.nix"
    echo "${output}"
    FAILED=1
  fi
else
  echo "FAIL: broken expected exit code nonzero but got 0"
  echo "${output}"
  FAILED=1
fi

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "ALL FIXTURE CHECKS PASSED!"
  exit 0
else
  echo "SOME FIXTURE CHECKS FAILED!"
  exit 1
fi

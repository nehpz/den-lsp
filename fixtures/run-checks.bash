#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEN_DIR="${DEN_DIR:-}"

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
echo "Detected system: ${SYSTEM}"

# Pin parity: reference scenarios lockfile so unlocked consumer flakes use identical pinned dependencies (den, nixpkgs, flake-parts) as hermetic tests.
# Reference lock alone is insufficient because Nix reuses a locked node only when the flake's declared original ref
# matches the reference lock's original ref. Workspace/consumer fixtures declare bare github:denful/den while scenarios
# specify github:denful/den/v0.18.0 (and nixpkgs original refs also differ), causing Nix to float unpinned inputs.
LOCK_FILE="${REPO_DIR}/fixtures/scenarios/flake.lock"
OVERRIDE_ARGS=()
if [ -f "${LOCK_FILE}" ]; then
  echo "Using reference lock file: ${LOCK_FILE}"
  OVERRIDE_ARGS+=(--reference-lock-file "${LOCK_FILE}")

  NIXPKGS_OVERRIDE=$(jq -r '.nodes[.root].inputs.nixpkgs as $n | .nodes[$n].locked | select(. != null) | if .type == "github" and (.owner != null and .repo != null and .rev != null) then "github:" + .owner + "/" + .repo + "/" + .rev elif (.type == "tarball" or .type == "flakehub") and (.url != null and .url != "") then .url else empty end' "${LOCK_FILE}" 2>/dev/null || true)
  if [ -n "${NIXPKGS_OVERRIDE}" ]; then
    echo "Using locked nixpkgs override: ${NIXPKGS_OVERRIDE}"
    OVERRIDE_ARGS+=(--override-input nixpkgs "${NIXPKGS_OVERRIDE}")
  else
    echo "Skipping nixpkgs override: unsupported locked type or missing URL in reference lock"
  fi

  if [ -n "${DEN_DIR:-}" ]; then
    echo "Using den repo override: ${DEN_DIR}"
    OVERRIDE_ARGS+=(--override-input den "${DEN_DIR}")
  else
    DEN_REV=$(jq -r '.nodes[.root].inputs.den as $n | .nodes[$n].locked | select(. != null) | .rev // empty' "${LOCK_FILE}" 2>/dev/null || true)
    if [ -n "${DEN_REV}" ]; then
      echo "Using locked den override: github:denful/den/${DEN_REV}"
      OVERRIDE_ARGS+=(--override-input den "github:denful/den/${DEN_REV}")
    else
      echo "Using upstream den repo from flake input"
    fi
  fi
else
  if [ -n "${DEN_DIR:-}" ]; then
    echo "Using den repo override: ${DEN_DIR}"
    OVERRIDE_ARGS+=(--override-input den "${DEN_DIR}")
  else
    echo "Using upstream den repo from flake input"
  fi
fi
echo "Using den-lsp repo override: ${REPO_DIR}"
OVERRIDE_ARGS+=(--override-input den-lsp "${REPO_DIR}")
OVERRIDE_ARGS+=(--option substituters "https://cache.nixos.org")
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

echo "==> Testing CLI E2E Exit Matrix Assertions (den-lsp-check)..."

run_cli_check() {
  local stdout_file stderr_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  set +e
  DEN_LSP_CHECK_NIX_ARGS="${OVERRIDE_ARGS[*]}" "${REPO_DIR}/tools/cli/den-lsp-check.bash" "$@" >"$stdout_file" 2>"$stderr_file"
  CLI_EXIT=$?
  set -e
  CLI_STDOUT="$(cat "$stdout_file")"
  CLI_STDERR="$(cat "$stderr_file")"
  rm -f "$stdout_file" "$stderr_file"
}

# 1. Clean fixture
echo "--> CLI Assertion 1: Clean fixture"
run_cli_check --json "${REPO_DIR}/fixtures/consumer"
if [ "$CLI_EXIT" -eq 0 ] && echo "$CLI_STDOUT" | jq -e '.version == 1 and .summary.gating == 0 and .summary.advisory == 0' >/dev/null; then
  echo "PASS: CLI Clean fixture (exit 0, version 1, summary zeros)"
else
  echo "FAIL: CLI Clean fixture expected exit 0 and zero summary, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
  echo "STDERR: $CLI_STDERR"
  FAILED=1
fi

# 2. Advisory-only variant
echo "--> CLI Assertion 2: Advisory-only variant"
run_cli_check --json "${REPO_DIR}/fixtures/consumer-variants/advisory-only"
if [ "$CLI_EXIT" -eq 0 ] && echo "$CLI_STDOUT" | jq -e '.version == 1 and .summary.advisory > 0 and (.findings[0].fix != null and .findings[0].fix != "") and (.findings[0].docRef != null and .findings[0].docRef != "")' >/dev/null; then
  echo "PASS: CLI Advisory-only variant (exit 0, advisory findings with fix and docRef)"
else
  echo "FAIL: CLI Advisory-only variant expected exit 0 and advisory findings, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
  echo "STDERR: $CLI_STDERR"
  FAILED=1
fi

# 3. Gating variant default mode
echo "--> CLI Assertion 3: Gating variant default mode"
run_cli_check --json "${REPO_DIR}/fixtures/consumer-variants/gating-dup"
if [ "$CLI_EXIT" -eq 1 ] && echo "$CLI_STDOUT" | jq -e '.version == 1 and .summary.gating > 0' >/dev/null; then
  echo "PASS: CLI Gating variant default mode (exit 1, document emitted)"
else
  echo "FAIL: CLI Gating variant default mode expected exit 1 and document, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
  echo "STDERR: $CLI_STDERR"
  FAILED=1
fi

# 4. Gating variant --draft mode
echo "--> CLI Assertion 4: Gating variant --draft mode"
run_cli_check --json --draft "${REPO_DIR}/fixtures/consumer-variants/gating-dup"
if [ "$CLI_EXIT" -eq 0 ] && echo "$CLI_STDOUT" | jq -e '.version == 1 and .summary.gating > 0' >/dev/null; then
  echo "PASS: CLI Gating variant --draft mode (exit 0, same document emitted)"
else
  echo "FAIL: CLI Gating variant --draft mode expected exit 0 and document, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
  echo "STDERR: $CLI_STDERR"
  FAILED=1
fi

# 5. Broken variant
echo "--> CLI Assertion 5: Broken variant"
run_cli_check --json "${REPO_DIR}/fixtures/consumer-variants/broken"
if [ "$CLI_EXIT" -eq 2 ] && echo "$CLI_STDOUT" | jq -e '.version == 1 and .error.kind == "eval-error" and (.error.message | length > 0)' >/dev/null && echo "$CLI_STDERR" | grep -q "trigger.nix"; then
  echo "PASS: CLI Broken variant (exit 2, eval-error envelope, stderr carries trace)"
else
  echo "FAIL: CLI Broken variant expected exit 2 and eval-error envelope, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
  echo "STDERR: $CLI_STDERR"
  FAILED=1
fi

# 6. Non-den variant
echo "--> CLI Assertion 6: Non-den variant"
run_cli_check --json "${REPO_DIR}/fixtures/consumer-variants/non-den"
if [ "$CLI_EXIT" -eq 2 ] && echo "$CLI_STDOUT" | jq -e '.version == 1 and .error.kind == "unsupported" and (.error.message | length > 0)' >/dev/null; then
  echo "PASS: CLI Non-den variant (exit 2, unsupported envelope)"
else
  echo "FAIL: CLI Non-den variant expected exit 2 and unsupported envelope, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
  echo "STDERR: $CLI_STDERR"
  FAILED=1
fi

# 7. Forced timeout
echo "--> CLI Assertion 7: Forced timeout"
run_cli_check --json --timeout 0.001 "${REPO_DIR}/fixtures/consumer"
if [ "$CLI_EXIT" -eq 3 ] && echo "$CLI_STDOUT" | jq -e '.version == 1 and .error.kind == "timeout" and (.error.message | length > 0)' >/dev/null; then
  echo "PASS: CLI Forced timeout (exit 3, timeout envelope)"
else
  echo "FAIL: CLI Forced timeout expected exit 3 and timeout envelope, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
  echo "STDERR: $CLI_STDERR"
  FAILED=1
fi

# 8. Unknown flag
echo "--> CLI Assertion 8: Unknown flag"
run_cli_check --unknown-flag
if [ "$CLI_EXIT" -eq 64 ] && [ -z "$CLI_STDOUT" ]; then
  echo "PASS: CLI Unknown flag (exit 64, empty stdout)"
else
  echo "FAIL: CLI Unknown flag expected exit 64 and empty stdout, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
  echo "STDERR: $CLI_STDERR"
  FAILED=1
fi

# 9. Text-mode smoke tests
echo "--> CLI Assertion 9: Text-mode smoke tests"
run_cli_check "${REPO_DIR}/fixtures/consumer"
if [ "$CLI_EXIT" -eq 0 ] && echo "$CLI_STDOUT" | grep -q "den-lsp: no findings."; then
  echo "PASS: CLI Text-mode clean fixture (exit 0, human rendering)"
else
  echo "FAIL: CLI Text-mode clean fixture expected exit 0 and human rendering, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
  FAILED=1
fi

run_cli_check "${REPO_DIR}/fixtures/consumer-variants/gating-dup"
if [ "$CLI_EXIT" -eq 1 ] && echo "$CLI_STDOUT" | grep -q "gating"; then
  echo "PASS: CLI Text-mode gating variant (exit 1, human rendering)"
else
  echo "FAIL: CLI Text-mode gating variant expected exit 1, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
  FAILED=1
fi

run_cli_check --draft "${REPO_DIR}/fixtures/consumer-variants/gating-dup"
if [ "$CLI_EXIT" -eq 0 ] && echo "$CLI_STDOUT" | grep -q "gating"; then
  echo "PASS: CLI Text-mode gating variant --draft (exit 0, human rendering)"
else
  echo "FAIL: CLI Text-mode gating variant --draft expected exit 0, got exit $CLI_EXIT"
  echo "STDOUT: $CLI_STDOUT"
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

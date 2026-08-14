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
PIN_ARGS=()
if [ -f "${LOCK_FILE}" ]; then
  echo "Using reference lock file: ${LOCK_FILE}"
  PIN_ARGS+=(--reference-lock-file "${LOCK_FILE}")

  NIXPKGS_OVERRIDE=$(jq -r '.nodes[.root].inputs.nixpkgs as $n | .nodes[$n].locked | select(. != null) | if .type == "github" and (.owner != null and .repo != null and .rev != null) then "github:" + .owner + "/" + .repo + "/" + .rev elif (.type == "tarball" or .type == "flakehub") and (.url != null and .url != "") then .url else empty end' "${LOCK_FILE}" 2>/dev/null || true)
  if [ -n "${NIXPKGS_OVERRIDE}" ]; then
    echo "Using locked nixpkgs override: ${NIXPKGS_OVERRIDE}"
    PIN_ARGS+=(--override-input nixpkgs "${NIXPKGS_OVERRIDE}")
  else
    echo "Skipping nixpkgs override: unsupported locked type or missing URL in reference lock"
  fi

  if [ -n "${DEN_DIR:-}" ]; then
    echo "Using den repo override: ${DEN_DIR}"
    PIN_ARGS+=(--override-input den "${DEN_DIR}")
  else
    DEN_REV=$(jq -r '.nodes[.root].inputs.den as $n | .nodes[$n].locked | select(. != null) | .rev // empty' "${LOCK_FILE}" 2>/dev/null || true)
    if [ -n "${DEN_REV}" ]; then
      echo "Using locked den override: github:denful/den/${DEN_REV}"
      PIN_ARGS+=(--override-input den "github:denful/den/${DEN_REV}")
    else
      echo "Using upstream den repo from flake input"
    fi
  fi
else
  if [ -n "${DEN_DIR:-}" ]; then
    echo "Using den repo override: ${DEN_DIR}"
    PIN_ARGS+=(--override-input den "${DEN_DIR}")
  else
    echo "Using upstream den repo from flake input"
  fi
fi
echo "Using den-lsp repo override: ${REPO_DIR}"
OVERRIDE_ARGS=("${PIN_ARGS[@]+"${PIN_ARGS[@]}"}" --override-input den-lsp "${REPO_DIR}")
UNWIRED_ARGS=("${PIN_ARGS[@]+"${PIN_ARGS[@]}"}" --override-input flake-parts "${REPO_DIR}/nix" --no-write-lock-file)
echo "Using flake-parts shim override: ${REPO_DIR}/nix"
echo

FAILED=0

preflight_unwired() {
  local target="$1"
  export DEN_LSP_TARGET
  DEN_LSP_TARGET="$(realpath "${target}")"
  nix eval --impure --expr "import ${REPO_DIR}/nix/ephemeral.nix { target = /. + builtins.getEnv \"DEN_LSP_TARGET\"; }"
}

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

# --- Unwired matrix (KTD1a shim: --override-input flake-parts path:./nix) ---

echo "==> Testing unwired base (findings equal wired consumer)..."
set +e
wired_findings=$(nix eval --json "${REPO_DIR}/fixtures/consumer#den-lsp-analysis" \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}" \
  --apply 'doc: doc.findings' 2>/dev/null)
wired_ec=$?
unwired_preflight=$(preflight_unwired "${REPO_DIR}/fixtures/unwired" 2>&1)
unwired_pre_ec=$?
unwired_findings=$(nix eval --json "${REPO_DIR}/fixtures/unwired#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}" \
  --apply 'doc: doc.findings' 2>/dev/null)
unwired_ec=$?
set -e

if [ "${unwired_pre_ec}" -ne 0 ]; then
  echo "FAIL: unwired base preflight expected exit 0 but got ${unwired_pre_ec}"
  echo "${unwired_preflight}"
  FAILED=1
elif [ "${wired_ec}" -ne 0 ] || [ "${unwired_ec}" -ne 0 ]; then
  echo "FAIL: unwired base analysis expected exit 0 (wired ${wired_ec}, unwired ${unwired_ec})"
  FAILED=1
elif [ "${wired_findings}" = "${unwired_findings}" ]; then
  echo "PASS: unwired base findings equal wired consumer findings"
else
  echo "FAIL: unwired base findings differ from wired consumer"
  echo "wired: ${wired_findings}"
  echo "unwired: ${unwired_findings}"
  FAILED=1
fi

echo "==> Testing unwired gating-dup variant..."
set +e
gdup_err="$(mktemp)"
output=$(nix eval --json "${REPO_DIR}/fixtures/unwired/gating-dup#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}" 2>"${gdup_err}")
exit_code=$?
set -e

if [ "${exit_code}" -eq 0 ]; then
  if echo "${output}" | jq -e '.findings | any(.rule == "duplication" and .severity == "gating")' >/dev/null \
    && echo "${output}" | jq -e '.findings | any((.aspectPath // "") + " " + (.message // "") | test("web"))' >/dev/null \
    && echo "${output}" | jq -e '.findings | any((.aspectPath // "") + " " + (.message // "") | test("db"))' >/dev/null; then
    echo "PASS: unwired gating-dup (duplication/gating finding naming web and db)"
  else
    echo "FAIL: unwired gating-dup findings did not pin duplication/gating with web and db"
    echo "${output}"
    cat "${gdup_err}"
    FAILED=1
  fi
else
  echo "FAIL: unwired gating-dup expected exit 0 (analysis document) but got ${exit_code}"
  echo "${output}"
  cat "${gdup_err}"
  FAILED=1
fi
rm -f "${gdup_err}"

echo "==> Testing unwired advisory-only variant..."
set +e
output=$(nix eval --json "${REPO_DIR}/fixtures/unwired/advisory-only#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -eq 0 ]; then
  if echo "${output}" | grep -q '"advisory"' && echo "${output}" | grep -q '"gating":0'; then
    echo "PASS: unwired advisory-only (exit 0, advisory findings, no gating)"
  else
    echo "FAIL: unwired advisory-only document was not advisory-only"
    echo "${output}"
    FAILED=1
  fi
else
  echo "FAIL: unwired advisory-only expected exit 0 but got ${exit_code}"
  echo "${output}"
  FAILED=1
fi

echo "==> Testing unwired broken variant..."
set +e
output=$(nix eval --json "${REPO_DIR}/fixtures/unwired/broken#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -ne 0 ]; then
  if echo "${output}" | grep -q "trigger.nix"; then
    echo "PASS: unwired broken (exit nonzero and output referenced failing file trigger.nix)"
  else
    echo "FAIL: unwired broken exited nonzero but output did not reference failing file trigger.nix"
    echo "${output}"
    FAILED=1
  fi
else
  echo "FAIL: unwired broken expected exit code nonzero but got 0"
  echo "${output}"
  FAILED=1
fi

echo "==> Testing unwired inline-imports variant..."
set +e
inline_findings=$(nix eval --json "${REPO_DIR}/fixtures/unwired/inline-imports#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}" \
  --apply 'doc: doc.findings' 2>/dev/null)
inline_ec=$?
set -e

if [ "${inline_ec}" -eq 0 ] && [ "${inline_findings}" = "${wired_findings}" ]; then
  echo "PASS: unwired inline-imports findings equal wired consumer findings"
else
  echo "FAIL: unwired inline-imports expected the same findings as wired consumer (exit ${inline_ec})"
  echo "wired: ${wired_findings}"
  echo "inline: ${inline_findings}"
  FAILED=1
fi

echo "==> Testing unwired R4: no flake-parts input..."
set +e
output=$(preflight_unwired "${REPO_DIR}/fixtures/unwired/no-flake-parts" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -ne 0 ]; then
  if echo "${output}" | grep -q "no flake-parts input"; then
    echo "PASS: unwired no-flake-parts (named error)"
  else
    echo "FAIL: unwired no-flake-parts exited nonzero but message did not name missing flake-parts"
    echo "${output}"
    FAILED=1
  fi
else
  echo "FAIL: unwired no-flake-parts expected nonzero exit but got 0"
  echo "${output}"
  FAILED=1
fi

echo "==> Testing unwired R4: flake-parts under a nonstandard input name..."
set +e
output=$(preflight_unwired "${REPO_DIR}/fixtures/unwired/renamed-flake-parts" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -ne 0 ]; then
  if echo "${output}" | grep -q "nonstandard input name"; then
    echo "PASS: unwired renamed-flake-parts (named error)"
  else
    echo "FAIL: unwired renamed-flake-parts exited nonzero but message did not name nonstandard input"
    echo "${output}"
    FAILED=1
  fi
else
  echo "FAIL: unwired renamed-flake-parts expected nonzero exit but got 0"
  echo "${output}"
  FAILED=1
fi

echo "==> Testing unwired R4: no den input..."
set +e
output=$(preflight_unwired "${REPO_DIR}/fixtures/unwired/no-den" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -ne 0 ]; then
  if echo "${output}" | grep -q "no den input"; then
    echo "PASS: unwired no-den (named error)"
  else
    echo "FAIL: unwired no-den exited nonzero but message did not name missing den"
    echo "${output}"
    FAILED=1
  fi
else
  echo "FAIL: unwired no-den expected nonzero exit but got 0"
  echo "${output}"
  FAILED=1
fi

echo "==> Testing unwired R4: den below v0.18.0 floor..."
set +e
output=$(preflight_unwired "${REPO_DIR}/fixtures/unwired/old-den" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -ne 0 ]; then
  if echo "${output}" | grep -q "v0.18.0"; then
    echo "PASS: unwired old-den (named version-floor error)"
  else
    echo "FAIL: unwired old-den exited nonzero but message did not name the v0.18.0 floor"
    echo "${output}"
    FAILED=1
  fi
else
  echo "FAIL: unwired old-den expected nonzero exit but got 0"
  echo "${output}"
  FAILED=1
fi

echo "==> Testing unwired R4: den config unreachable..."
set +e
output=$(nix eval --json "${REPO_DIR}/fixtures/unwired/unreachable#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}" 2>&1)
exit_code=$?
set -e

if [ "${exit_code}" -ne 0 ]; then
  if echo "${output}" | grep -q "unreachable"; then
    echo "PASS: unwired unreachable (named error)"
  else
    echo "FAIL: unwired unreachable exited nonzero but message did not name unreachability"
    echo "${output}"
    FAILED=1
  fi
else
  echo "FAIL: unwired unreachable expected nonzero exit but got 0"
  echo "${output}"
  FAILED=1
fi

# --- Standalone CLI + agent contract (U2+U3) ---

run_cli() {
  CLI_DIR="$(mktemp -d)"
  set +e
  # Pass the hermetic pins through the CLI's internal test-harness knob so
  # CLI rows resolve the same den/nixpkgs/flake-parts as every other row
  # (field invocations rely on the target's own lock instead).
  DEN_LSP_CHECK_NIX_ARGS="${PIN_ARGS[*]+"${PIN_ARGS[*]}"}" \
    nix run "${REPO_DIR}#den-lsp-check" -- "$@" >"${CLI_DIR}/out" 2>"${CLI_DIR}/err"
  CLI_EC=$?
  set -e
  CLI_OUT="$(cat "${CLI_DIR}/out")"
  CLI_ERR="$(cat "${CLI_DIR}/err")"
}

echo "==> Testing CLI vs module app report identical (fixtures/consumer)..."
set +e
module_stdout=$(nix run "${REPO_DIR}/fixtures/consumer#den-lsp-check" \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}" 2>/dev/null)
module_ec=$?
set -e
run_cli "${REPO_DIR}/fixtures/consumer"
if [ "${module_ec}" -eq 0 ] && [ "${CLI_EC}" -eq 0 ] && [ "${module_stdout}" = "${CLI_OUT}" ]; then
  echo "PASS: CLI vs module app report identical"
else
  echo "FAIL: CLI vs module app reports differ (module exit ${module_ec}, CLI exit ${CLI_EC})"
  echo "module: ${module_stdout}"
  echo "cli: ${CLI_OUT}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing wired gating-dup finding-set pin..."
set +e
expected_wired_pairs=$(nix eval --json --impure --expr \
  "let s = import ${REPO_DIR}/fixtures/scenarios/lib.nix { }; in s.scenarios.base-gating-dup.expectedFindings" \
  2>/dev/null | jq -S 'map({rule, severity}) | sort_by(.rule, .severity)')
set -e
set +e
actual_wired_pairs=$(nix eval --json "${REPO_DIR}/fixtures/consumer-variants/gating-dup#den-lsp-analysis" \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}" 2>/dev/null \
  | jq -S '.findings | map({rule, severity}) | sort_by(.rule, .severity)')
wired_pin_ec=$?
set -e
if [ "${wired_pin_ec}" -eq 0 ] && [ -n "${expected_wired_pairs}" ] && [ "${expected_wired_pairs}" = "${actual_wired_pairs}" ]; then
  echo "PASS: wired gating-dup finding-set pin (rule/severity pairs match base-gating-dup)"
else
  echo "FAIL: wired gating-dup finding-set pin mismatch (exit ${wired_pin_ec})"
  echo "expected: ${expected_wired_pairs}"
  echo "actual: ${actual_wired_pairs}"
  FAILED=1
fi

echo "==> Testing CLI unwired base (exit 0 report)..."
run_cli "${REPO_DIR}/fixtures/unwired"
if [ "${CLI_EC}" -eq 0 ] && [ "${CLI_OUT}" = "den-lsp: no findings." ]; then
  echo "PASS: CLI unwired base (exit 0, den-lsp: no findings.)"
else
  echo "FAIL: CLI unwired base expected exit 0 with exact 'den-lsp: no findings.' but got ${CLI_EC}"
  echo "${CLI_OUT}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI unwired gating-dup (exit 1 naming web+db)..."
run_cli "${REPO_DIR}/fixtures/unwired/gating-dup"
if [ "${CLI_EC}" -eq 1 ] && echo "${CLI_OUT}" | grep -q "web" && echo "${CLI_OUT}" | grep -q "db"; then
  echo "PASS: CLI unwired gating-dup (exit 1 naming web+db)"
else
  echo "FAIL: CLI unwired gating-dup expected exit 1 naming web+db but got ${CLI_EC}"
  echo "${CLI_OUT}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI --draft on gating (exit 0, findings still shown)..."
run_cli --draft "${REPO_DIR}/fixtures/unwired/gating-dup"
if [ "${CLI_EC}" -eq 0 ] && echo "${CLI_OUT}" | grep -q "web" && echo "${CLI_OUT}" | grep -q "db"; then
  echo "PASS: CLI --draft on gating (exit 0, findings still shown)"
else
  echo "FAIL: CLI --draft on gating expected exit 0 with findings but got ${CLI_EC}"
  echo "${CLI_OUT}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI --json on gating (stdout JSON v1 + duplication, stderr text)..."
run_cli --json "${REPO_DIR}/fixtures/unwired/gating-dup"
if [ "${CLI_EC}" -eq 1 ] \
  && jq -e '.version == 1 and any(.findings[]; .rule == "duplication" and .severity == "gating")' "${CLI_DIR}/out" >/dev/null \
  && echo "${CLI_ERR}" | grep -q "den-lsp:" \
  && jq -e . "${CLI_DIR}/out" >/dev/null; then
  echo "PASS: CLI --json on gating (JSON v1 duplication, stderr text, stdout is JSON)"
else
  echo "FAIL: CLI --json on gating did not match the contract (exit ${CLI_EC})"
  echo "stdout: ${CLI_OUT}"
  echo "stderr: ${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI broken + --json (empty stdout, exit 2)..."
run_cli --json "${REPO_DIR}/fixtures/unwired/broken"
if [ "${CLI_EC}" -eq 2 ] && [ ! -s "${CLI_DIR}/out" ] && echo "${CLI_ERR}" | grep -q "trigger.nix"; then
  echo "PASS: CLI broken + --json (empty stdout, exit 2, stderr names trigger.nix)"
else
  echo "FAIL: CLI broken + --json expected empty stdout, exit 2, and trigger.nix on stderr but got ${CLI_EC}"
  echo "stdout: ${CLI_OUT}"
  echo "stderr: ${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI R4: no-flake-parts (exit 2, named message)..."
run_cli "${REPO_DIR}/fixtures/unwired/no-flake-parts"
if [ "${CLI_EC}" -eq 2 ] && echo "${CLI_ERR}" | grep -q "no flake-parts input"; then
  echo "PASS: CLI R4 no-flake-parts (exit 2, named message)"
else
  echo "FAIL: CLI R4 no-flake-parts expected exit 2 with no flake-parts input but got ${CLI_EC}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI R4: renamed-flake-parts (exit 2, named message)..."
run_cli "${REPO_DIR}/fixtures/unwired/renamed-flake-parts"
if [ "${CLI_EC}" -eq 2 ] && echo "${CLI_ERR}" | grep -q "nonstandard input name"; then
  echo "PASS: CLI R4 renamed-flake-parts (exit 2, named message)"
else
  echo "FAIL: CLI R4 renamed-flake-parts expected exit 2 with nonstandard input name but got ${CLI_EC}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI R4: no-den (exit 2, named message)..."
run_cli "${REPO_DIR}/fixtures/unwired/no-den"
if [ "${CLI_EC}" -eq 2 ] && echo "${CLI_ERR}" | grep -q "no den input"; then
  echo "PASS: CLI R4 no-den (exit 2, named message)"
else
  echo "FAIL: CLI R4 no-den expected exit 2 with no den input but got ${CLI_EC}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI R4: old-den (exit 2, named message)..."
run_cli "${REPO_DIR}/fixtures/unwired/old-den"
if [ "${CLI_EC}" -eq 2 ] && echo "${CLI_ERR}" | grep -q "v0.18.0"; then
  echo "PASS: CLI R4 old-den (exit 2, named message)"
else
  echo "FAIL: CLI R4 old-den expected exit 2 naming the v0.18.0 floor but got ${CLI_EC}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI unwired advisory-only --json (exit 0, advisory, gating==0)..."
run_cli --json "${REPO_DIR}/fixtures/unwired/advisory-only"
if [ "${CLI_EC}" -eq 0 ] \
  && jq -e '.findings | any(.severity == "advisory")' "${CLI_DIR}/out" >/dev/null \
  && jq -e '.summary.gating == 0' "${CLI_DIR}/out" >/dev/null; then
  echo "PASS: CLI unwired advisory-only --json (exit 0, advisory present, gating==0)"
else
  echo "FAIL: CLI unwired advisory-only --json did not match (exit ${CLI_EC})"
  echo "stdout: ${CLI_OUT}"
  echo "stderr: ${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI wired gating-dup text (exit 1)..."
run_cli "${REPO_DIR}/fixtures/consumer-variants/gating-dup"
if [ "${CLI_EC}" -eq 1 ] && echo "${CLI_OUT}" | grep -q "web" && echo "${CLI_OUT}" | grep -q "db"; then
  echo "PASS: CLI wired gating-dup text (exit 1 naming web+db)"
else
  echo "FAIL: CLI wired gating-dup text expected exit 1 naming web+db but got ${CLI_EC}"
  echo "${CLI_OUT}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI wired advisory-only text (exit 0)..."
run_cli "${REPO_DIR}/fixtures/consumer-variants/advisory-only"
if [ "${CLI_EC}" -eq 0 ] && echo "${CLI_OUT}" | grep -q "advisory"; then
  echo "PASS: CLI wired advisory-only text (exit 0)"
else
  echo "FAIL: CLI wired advisory-only text expected exit 0 with advisory findings but got ${CLI_EC}"
  echo "${CLI_OUT}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI near-zero deadline (exit 3, empty stdout)..."
run_cli --json --deadline 0 "${REPO_DIR}/fixtures/unwired"
if [ "${CLI_EC}" -eq 3 ] && [ ! -s "${CLI_DIR}/out" ]; then
  echo "PASS: CLI near-zero deadline (exit 3, empty stdout)"
else
  echo "FAIL: CLI near-zero deadline expected exit 3 empty stdout but got ${CLI_EC}"
  echo "stdout: ${CLI_OUT}"
  echo "stderr: ${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI --draft --gate (exit 64)..."
run_cli --draft --gate "${REPO_DIR}/fixtures/unwired"
if [ "${CLI_EC}" -eq 64 ] && echo "${CLI_ERR}" | grep -qi "usage"; then
  echo "PASS: CLI --draft --gate (exit 64)"
else
  echo "FAIL: CLI --draft --gate expected exit 64 with usage but got ${CLI_EC}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI no path (exit 64)..."
run_cli
if [ "${CLI_EC}" -eq 64 ] && echo "${CLI_ERR}" | grep -qi "usage"; then
  echo "PASS: CLI no path (exit 64)"
else
  echo "FAIL: CLI no path expected exit 64 with usage but got ${CLI_EC}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI unknown flag (exit 64)..."
run_cli --unknown "${REPO_DIR}/fixtures/unwired"
if [ "${CLI_EC}" -eq 64 ] && echo "${CLI_ERR}" | grep -qi "usage"; then
  echo "PASS: CLI unknown flag (exit 64)"
else
  echo "FAIL: CLI unknown flag expected exit 64 with usage but got ${CLI_EC}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo "==> Testing CLI --json determinism (two runs byte-identical)..."
run_cli --json "${REPO_DIR}/fixtures/unwired/gating-dup"
first_json_dir="${CLI_DIR}"
first_ec="${CLI_EC}"
run_cli --json "${REPO_DIR}/fixtures/unwired/gating-dup"
if [ "${first_ec}" -eq 1 ] && [ "${CLI_EC}" -eq 1 ] && cmp -s "${first_json_dir}/out" "${CLI_DIR}/out"; then
  echo "PASS: CLI --json determinism (byte-identical stdout across two runs)"
else
  echo "FAIL: CLI --json stdout differed across two runs (exits ${first_ec}/${CLI_EC})"
  diff "${first_json_dir}/out" "${CLI_DIR}/out" || true
  FAILED=1
fi
rm -rf "${first_json_dir}" "${CLI_DIR}"

echo "==> Testing CLI --json against eval-corpus scenario (base-gating-dup workspace)..."
# Evidence-runner leg (U5): one eval-corpus scenario end-to-end through the
# zero-touch CLI, findings compared against the scenario manifest's own
# expectedFindings (rule/severity pairs) — the hermetic tier's pins.
set +e
expected_pairs=$(nix eval --json --impure --expr \
  "let s = import ${REPO_DIR}/fixtures/scenarios/lib.nix { }; in s.scenarios.base-gating-dup.expectedFindings" \
  2>/dev/null | jq -S 'map({rule, severity}) | sort_by(.rule, .severity)')
set -e
run_cli --json --draft "${REPO_DIR}/fixtures/scenarios/base-gating-dup/workspace"
actual_pairs=$(jq -S '.findings | map({rule, severity}) | sort_by(.rule, .severity)' "${CLI_DIR}/out" 2>/dev/null || echo '[]')
if [ "${CLI_EC}" -eq 0 ] && [ -n "${expected_pairs}" ] && [ "${expected_pairs}" = "${actual_pairs}" ]; then
  echo "PASS: CLI --json scenario leg (findings match base-gating-dup expectedFindings)"
else
  echo "FAIL: CLI --json scenario leg mismatch (exit ${CLI_EC})"
  echo "expected: ${expected_pairs}"
  echo "actual: ${actual_pairs}"
  echo "${CLI_ERR}"
  FAILED=1
fi
rm -rf "${CLI_DIR}"

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "ALL FIXTURE CHECKS PASSED!"
  exit 0
else
  echo "SOME FIXTURE CHECKS FAILED!"
  exit 1
fi

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

WS_GATING="${REPO_DIR}/fixtures/scenarios/base-gating-dup/workspace"
WS_ADVISORY="${REPO_DIR}/fixtures/scenarios/base-advisory-only/workspace"
WS_BROKEN="${REPO_DIR}/fixtures/scenarios/base-broken/workspace"
UNWIRED_GATING="${REPO_DIR}/fixtures/unwired/gating-dup"
UNWIRED_ADVISORY="${REPO_DIR}/fixtures/unwired/advisory-only"
UNWIRED_BROKEN="${REPO_DIR}/fixtures/unwired/broken"

FAILED=0

preflight_unwired() {
  local target="$1"
  export DEN_LSP_TARGET
  DEN_LSP_TARGET="$(realpath "${target}")"
  nix eval --impure --expr "import ${REPO_DIR}/nix/ephemeral.nix { target = /. + builtins.getEnv \"DEN_LSP_TARGET\"; }"
}

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

# assert_check TITLE PASS_MSG FAIL_MSG PRED [--note LINE]... [--cli args... | -- cmd...]
# FAIL_MSG is eval'd after the command so ${exit_code}/${CLI_EC} interpolate.
# With -- or --cli, prints TITLE then runs the command. Without, TITLE is not
# reprinted (caller already printed it) and existing output/exit_code/CLI_* are used.
# Optional ASSERT_FAIL_BODY is eval'd on failure instead of the default dump.
assert_check() {
  local title="$1"
  local pass_msg="$2"
  local fail_msg="$3"
  local pred="$4"
  shift 4
  local dump="${ASSERT_FAIL_BODY:-}"
  ASSERT_FAIL_BODY=""
  if [ "${1:-}" = "--note" ] || [ "${1:-}" = "--cli" ] || [ "${1:-}" = "--" ]; then
    echo "==> Testing ${title}..."
    while [ "${1:-}" = "--note" ]; do
      printf '%s\n' "$2"
      shift 2
    done
  fi
  if [ "${1:-}" = "--cli" ]; then
    shift
    run_cli "$@"
    exit_code="${CLI_EC}"
    output="${CLI_OUT}"
    if [ -z "${dump}" ]; then
      dump='echo "${CLI_OUT}"; echo "${CLI_ERR}"'
    fi
  elif [ "${1:-}" = "--" ]; then
    shift
    set +e
    output=$("$@" 2>&1)
    exit_code=$?
    set -e
    if [ -z "${dump}" ]; then
      dump='echo "${output}"'
    fi
  else
    if [ -z "${dump}" ]; then
      dump='echo "${output}"'
    fi
  fi
  if eval "${pred}"; then
    echo "PASS: ${pass_msg}"
  else
    echo -n "FAIL: "
    eval echo "$fail_msg"
    eval "${dump}"
    FAILED=1
  fi
  if [ "${ASSERT_KEEP_CLI:-}" != 1 ]; then
    rm -rf "${CLI_DIR:-}"
    CLI_DIR=""
  fi
  ASSERT_KEEP_CLI=""
  return 0
}

assert_check \
  "base fixture (nix build)" \
  "base build (exit 0)" \
  'base build expected exit 0 but got ${exit_code}' \
  '[ "${exit_code}" -eq 0 ]' \
  -- nix build "${REPO_DIR}/fixtures/consumer#checks.${SYSTEM}.den-lsp" \
  --no-link \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}"

assert_check \
  "base fixture app (nix run)" \
  "base app run (exit 0)" \
  'base app run expected exit 0 but got ${exit_code}' \
  '[ "${exit_code}" -eq 0 ]' \
  -- nix run "${REPO_DIR}/fixtures/consumer#den-lsp-check" \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}"

# Negative test: the 'den-lsp-check' derivation build fails by design to prove
# the CI gate blocks gating findings — the failed drv is why green runs still
# show a red "Build logs from 1 failure" block in the Determinate nix action's
# post-job summary.
assert_check \
  "gating-dup variant" \
  "gating-dup (exit nonzero and mentioned both 'web' and 'db')" \
  '$(if [ "${exit_code}" -eq 0 ]; then echo "gating-dup expected nonzero exit code but got 0"; else echo "gating-dup exited nonzero but output did not mention both aspect names '\''web'\'' and '\''db'\''"; fi)' \
  '[ "${exit_code}" -ne 0 ] && echo "${output}" | grep -q "web" && echo "${output}" | grep -q "db"' \
  --note "    (expected failure: the 'den-lsp-check' build below fails by design;" \
  --note "     it reappears in the post-job 'Build logs from 1 failure' summary)" \
  -- nix build "${WS_GATING}#checks.${SYSTEM}.den-lsp" \
  --no-link \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}"

assert_check \
  "advisory-only variant" \
  "advisory-only (exit 0)" \
  'advisory-only expected exit 0 but got ${exit_code}' \
  '[ "${exit_code}" -eq 0 ]' \
  -- nix build "${WS_ADVISORY}#checks.${SYSTEM}.den-lsp" \
  --no-link \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}"

assert_check \
  "broken variant" \
  "broken (exit nonzero and output referenced failing file trigger.nix)" \
  '$(if [ "${exit_code}" -eq 0 ]; then echo "broken expected exit code nonzero but got 0"; else echo "broken exited nonzero but output did not reference failing file trigger.nix"; fi)' \
  '[ "${exit_code}" -ne 0 ] && echo "${output}" | grep -q "trigger.nix"' \
  -- nix build "${WS_BROKEN}#checks.${SYSTEM}.den-lsp" \
  --no-link \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}"

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
output="${unwired_preflight}"
if [ "${unwired_pre_ec}" -ne 0 ]; then
  ASSERT_FAIL_BODY='echo "${unwired_preflight}"'
  fail_msg="unwired base preflight expected exit 0 but got ${unwired_pre_ec}"
  pred='false'
elif [ "${wired_ec}" -ne 0 ] || [ "${unwired_ec}" -ne 0 ]; then
  ASSERT_FAIL_BODY=':'
  fail_msg="unwired base analysis expected exit 0 (wired ${wired_ec}, unwired ${unwired_ec})"
  pred='false'
else
  ASSERT_FAIL_BODY='echo "wired: ${wired_findings}"; echo "unwired: ${unwired_findings}"'
  fail_msg="unwired base findings differ from wired consumer"
  pred='[ "${wired_findings}" = "${unwired_findings}" ]'
fi
assert_check \
  "unwired base (findings equal wired consumer)" \
  "unwired base findings equal wired consumer findings" \
  "${fail_msg}" \
  "${pred}"

echo "==> Testing unwired gating-dup variant..."
gdup_err="$(mktemp)"
set +e
output=$(nix eval --json "${UNWIRED_GATING}#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}" 2>"${gdup_err}")
exit_code=$?
set -e
ASSERT_FAIL_BODY='echo "${output}"; cat "${gdup_err}"'
if [ "${exit_code}" -eq 0 ]; then
  fail_msg="unwired gating-dup findings did not pin duplication/gating with web and db"
  pred='echo "${output}" | jq -e '\''.findings | any(.rule == "duplication" and .severity == "gating")'\'' >/dev/null && echo "${output}" | jq -e '\''.findings | any((.aspectPath // "") + " " + (.message // "") | test("web"))'\'' >/dev/null && echo "${output}" | jq -e '\''.findings | any((.aspectPath // "") + " " + (.message // "") | test("db"))'\'' >/dev/null'
else
  fail_msg="unwired gating-dup expected exit 0 (analysis document) but got ${exit_code}"
  pred='false'
fi
assert_check \
  "unwired gating-dup variant" \
  "unwired gating-dup (duplication/gating finding naming web and db)" \
  "${fail_msg}" \
  "${pred}"
rm -f "${gdup_err}"

assert_check \
  "unwired advisory-only variant" \
  "unwired advisory-only (exit 0, advisory findings, no gating)" \
  '$(if [ "${exit_code}" -eq 0 ]; then echo "unwired advisory-only document was not advisory-only"; else echo "unwired advisory-only expected exit 0 but got ${exit_code}"; fi)' \
  '[ "${exit_code}" -eq 0 ] && echo "${output}" | grep -q '\''"advisory"'\'' && echo "${output}" | grep -q '\''"gating":0'\''' \
  -- nix eval --json "${UNWIRED_ADVISORY}#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}"

assert_check \
  "unwired broken variant" \
  "unwired broken (exit nonzero and output referenced failing file trigger.nix)" \
  '$(if [ "${exit_code}" -eq 0 ]; then echo "unwired broken expected exit code nonzero but got 0"; else echo "unwired broken exited nonzero but output did not reference failing file trigger.nix"; fi)' \
  '[ "${exit_code}" -ne 0 ] && echo "${output}" | grep -q "trigger.nix"' \
  -- nix eval --json "${UNWIRED_BROKEN}#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}"

echo "==> Testing unwired inline-imports variant..."
set +e
inline_findings=$(nix eval --json "${REPO_DIR}/fixtures/unwired/inline-imports#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}" \
  --apply 'doc: doc.findings' 2>/dev/null)
inline_ec=$?
set -e
output="${inline_findings}"
ASSERT_FAIL_BODY='echo "wired: ${wired_findings}"; echo "inline: ${inline_findings}"'
assert_check \
  "unwired inline-imports variant" \
  "unwired inline-imports findings equal wired consumer findings" \
  'unwired inline-imports expected the same findings as wired consumer (exit ${inline_ec})' \
  '[ "${inline_ec}" -eq 0 ] && [ "${inline_findings}" = "${wired_findings}" ]'

assert_check \
  "unwired R4: no flake-parts input" \
  "unwired no-flake-parts (named error)" \
  '$(if [ "${exit_code}" -eq 0 ]; then echo "unwired no-flake-parts expected nonzero exit but got 0"; else echo "unwired no-flake-parts exited nonzero but message did not name missing flake-parts"; fi)' \
  '[ "${exit_code}" -ne 0 ] && echo "${output}" | grep -q "no flake-parts input"' \
  -- preflight_unwired "${REPO_DIR}/fixtures/unwired/no-flake-parts"

assert_check \
  "unwired R4: flake-parts under a nonstandard input name" \
  "unwired renamed-flake-parts (named error)" \
  '$(if [ "${exit_code}" -eq 0 ]; then echo "unwired renamed-flake-parts expected nonzero exit but got 0"; else echo "unwired renamed-flake-parts exited nonzero but message did not name nonstandard input"; fi)' \
  '[ "${exit_code}" -ne 0 ] && echo "${output}" | grep -q "nonstandard input name"' \
  -- preflight_unwired "${REPO_DIR}/fixtures/unwired/renamed-flake-parts"

assert_check \
  "unwired R4: no den input" \
  "unwired no-den (named error)" \
  '$(if [ "${exit_code}" -eq 0 ]; then echo "unwired no-den expected nonzero exit but got 0"; else echo "unwired no-den exited nonzero but message did not name missing den"; fi)' \
  '[ "${exit_code}" -ne 0 ] && echo "${output}" | grep -q "no den input"' \
  -- preflight_unwired "${REPO_DIR}/fixtures/unwired/no-den"

assert_check \
  "unwired R4: den below v0.18.0 floor" \
  "unwired old-den (named version-floor error)" \
  '$(if [ "${exit_code}" -eq 0 ]; then echo "unwired old-den expected nonzero exit but got 0"; else echo "unwired old-den exited nonzero but message did not name the v0.18.0 floor"; fi)' \
  '[ "${exit_code}" -ne 0 ] && echo "${output}" | grep -q "v0.18.0"' \
  -- preflight_unwired "${REPO_DIR}/fixtures/unwired/old-den"

assert_check \
  "unwired R4: den config unreachable" \
  "unwired unreachable (named error)" \
  '$(if [ "${exit_code}" -eq 0 ]; then echo "unwired unreachable expected nonzero exit but got 0"; else echo "unwired unreachable exited nonzero but message did not name unreachability"; fi)' \
  '[ "${exit_code}" -ne 0 ] && echo "${output}" | grep -q "unreachable"' \
  -- nix eval --json "${REPO_DIR}/fixtures/unwired/unreachable#den-lsp-analysis" \
  "${UNWIRED_ARGS[@]+"${UNWIRED_ARGS[@]}"}"

# --- Standalone CLI + agent contract (U2+U3) ---

echo "==> Testing CLI vs module app report identical (fixtures/consumer)..."
set +e
module_stdout=$(nix run "${REPO_DIR}/fixtures/consumer#den-lsp-check" \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}" 2>/dev/null)
module_ec=$?
set -e
run_cli "${REPO_DIR}/fixtures/consumer"
ASSERT_FAIL_BODY='echo "module: ${module_stdout}"; echo "cli: ${CLI_OUT}"; echo "${CLI_ERR}"'
assert_check \
  "CLI vs module app report identical (fixtures/consumer)" \
  "CLI vs module app report identical" \
  'CLI vs module app reports differ (module exit ${module_ec}, CLI exit ${CLI_EC})' \
  '[ "${module_ec}" -eq 0 ] && [ "${CLI_EC}" -eq 0 ] && [ "${module_stdout}" = "${CLI_OUT}" ]'

echo "==> Testing wired gating-dup finding-set pin..."
set +e
expected_wired_pairs=$(nix eval --json --impure --expr \
  "let s = import ${REPO_DIR}/fixtures/scenarios/lib.nix { }; in s.scenarios.base-gating-dup.expectedFindings" \
  2>/dev/null | jq -S 'map({rule, severity}) | sort_by(.rule, .severity)')
set -e
set +e
actual_wired_pairs=$(nix eval --json "${WS_GATING}#den-lsp-analysis" \
  "${OVERRIDE_ARGS[@]+"${OVERRIDE_ARGS[@]}"}" 2>/dev/null \
  | jq -S '.findings | map({rule, severity}) | sort_by(.rule, .severity)')
wired_pin_ec=$?
set -e
output="${actual_wired_pairs}"
ASSERT_FAIL_BODY='echo "expected: ${expected_wired_pairs}"; echo "actual: ${actual_wired_pairs}"'
assert_check \
  "wired gating-dup finding-set pin" \
  "wired gating-dup finding-set pin (rule/severity pairs match base-gating-dup)" \
  'wired gating-dup finding-set pin mismatch (exit ${wired_pin_ec})' \
  '[ "${wired_pin_ec}" -eq 0 ] && [ -n "${expected_wired_pairs}" ] && [ "${expected_wired_pairs}" = "${actual_wired_pairs}" ]'

assert_check \
  "CLI unwired base (exit 0 report)" \
  "CLI unwired base (exit 0, den-lsp: no findings.)" \
  'CLI unwired base expected exit 0 with exact '\''den-lsp: no findings.'\'' but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 0 ] && [ "${CLI_OUT}" = "den-lsp: no findings." ]' \
  --cli "${REPO_DIR}/fixtures/unwired"

assert_check \
  "CLI unwired gating-dup (exit 1 naming web+db)" \
  "CLI unwired gating-dup (exit 1 naming web+db)" \
  'CLI unwired gating-dup expected exit 1 naming web+db but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 1 ] && echo "${CLI_OUT}" | grep -q "web" && echo "${CLI_OUT}" | grep -q "db"' \
  --cli "${UNWIRED_GATING}"

assert_check \
  "CLI --draft on gating (exit 0, findings still shown)" \
  "CLI --draft on gating (exit 0, findings still shown)" \
  'CLI --draft on gating expected exit 0 with findings but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 0 ] && echo "${CLI_OUT}" | grep -q "web" && echo "${CLI_OUT}" | grep -q "db"' \
  --cli --draft "${UNWIRED_GATING}"

ASSERT_FAIL_BODY='echo "stdout: ${CLI_OUT}"; echo "stderr: ${CLI_ERR}"'
assert_check \
  "CLI --json on gating (stdout JSON v1 + duplication, stderr text)" \
  "CLI --json on gating (JSON v1 duplication, stderr text, stdout is JSON)" \
  'CLI --json on gating did not match the contract (exit ${CLI_EC})' \
  '[ "${CLI_EC}" -eq 1 ] && jq -e '\''.version == 1 and any(.findings[]; .rule == "duplication" and .severity == "gating")'\'' "${CLI_DIR}/out" >/dev/null && echo "${CLI_ERR}" | grep -q "den-lsp:" && jq -e . "${CLI_DIR}/out" >/dev/null' \
  --cli --json "${UNWIRED_GATING}"

ASSERT_FAIL_BODY='echo "stdout: ${CLI_OUT}"; echo "stderr: ${CLI_ERR}"'
assert_check \
  "CLI broken + --json (empty stdout, exit 2)" \
  "CLI broken + --json (empty stdout, exit 2, stderr names trigger.nix)" \
  'CLI broken + --json expected empty stdout, exit 2, and trigger.nix on stderr but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 2 ] && [ ! -s "${CLI_DIR}/out" ] && echo "${CLI_ERR}" | grep -q "trigger.nix"' \
  --cli --json "${UNWIRED_BROKEN}"

ASSERT_FAIL_BODY='echo "${CLI_ERR}"'
assert_check \
  "CLI R4: no-flake-parts (exit 2, named message)" \
  "CLI R4 no-flake-parts (exit 2, named message)" \
  'CLI R4 no-flake-parts expected exit 2 with no flake-parts input but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 2 ] && echo "${CLI_ERR}" | grep -q "no flake-parts input"' \
  --cli "${REPO_DIR}/fixtures/unwired/no-flake-parts"

ASSERT_FAIL_BODY='echo "${CLI_ERR}"'
assert_check \
  "CLI R4: renamed-flake-parts (exit 2, named message)" \
  "CLI R4 renamed-flake-parts (exit 2, named message)" \
  'CLI R4 renamed-flake-parts expected exit 2 with nonstandard input name but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 2 ] && echo "${CLI_ERR}" | grep -q "nonstandard input name"' \
  --cli "${REPO_DIR}/fixtures/unwired/renamed-flake-parts"

ASSERT_FAIL_BODY='echo "${CLI_ERR}"'
assert_check \
  "CLI R4: no-den (exit 2, named message)" \
  "CLI R4 no-den (exit 2, named message)" \
  'CLI R4 no-den expected exit 2 with no den input but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 2 ] && echo "${CLI_ERR}" | grep -q "no den input"' \
  --cli "${REPO_DIR}/fixtures/unwired/no-den"

ASSERT_FAIL_BODY='echo "${CLI_ERR}"'
assert_check \
  "CLI R4: old-den (exit 2, named message)" \
  "CLI R4 old-den (exit 2, named message)" \
  'CLI R4 old-den expected exit 2 naming the v0.18.0 floor but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 2 ] && echo "${CLI_ERR}" | grep -q "v0.18.0"' \
  --cli "${REPO_DIR}/fixtures/unwired/old-den"

ASSERT_FAIL_BODY='echo "stdout: ${CLI_OUT}"; echo "stderr: ${CLI_ERR}"'
assert_check \
  "CLI unwired advisory-only --json (exit 0, advisory, gating==0)" \
  "CLI unwired advisory-only --json (exit 0, advisory present, gating==0)" \
  'CLI unwired advisory-only --json did not match (exit ${CLI_EC})' \
  '[ "${CLI_EC}" -eq 0 ] && jq -e '\''.findings | any(.severity == "advisory")'\'' "${CLI_DIR}/out" >/dev/null && jq -e '\''.summary.gating == 0'\'' "${CLI_DIR}/out" >/dev/null' \
  --cli --json "${UNWIRED_ADVISORY}"

assert_check \
  "CLI wired gating-dup text (exit 1)" \
  "CLI wired gating-dup text (exit 1 naming web+db)" \
  'CLI wired gating-dup text expected exit 1 naming web+db but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 1 ] && echo "${CLI_OUT}" | grep -q "web" && echo "${CLI_OUT}" | grep -q "db"' \
  --cli "${WS_GATING}"

assert_check \
  "CLI wired advisory-only text (exit 0)" \
  "CLI wired advisory-only text (exit 0)" \
  'CLI wired advisory-only text expected exit 0 with advisory findings but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 0 ] && echo "${CLI_OUT}" | grep -q "advisory"' \
  --cli "${WS_ADVISORY}"

ASSERT_FAIL_BODY='echo "stdout: ${CLI_OUT}"; echo "stderr: ${CLI_ERR}"'
assert_check \
  "CLI near-zero deadline (exit 3, empty stdout)" \
  "CLI near-zero deadline (exit 3, empty stdout)" \
  'CLI near-zero deadline expected exit 3 empty stdout but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 3 ] && [ ! -s "${CLI_DIR}/out" ]' \
  --cli --json --deadline 0 "${REPO_DIR}/fixtures/unwired"

ASSERT_FAIL_BODY='echo "${CLI_ERR}"'
assert_check \
  "CLI --draft --gate (exit 64)" \
  "CLI --draft --gate (exit 64)" \
  'CLI --draft --gate expected exit 64 with usage but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 64 ] && echo "${CLI_ERR}" | grep -qi "usage"' \
  --cli --draft --gate "${REPO_DIR}/fixtures/unwired"

ASSERT_FAIL_BODY='echo "${CLI_ERR}"'
assert_check \
  "CLI no path (exit 64)" \
  "CLI no path (exit 64)" \
  'CLI no path expected exit 64 with usage but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 64 ] && echo "${CLI_ERR}" | grep -qi "usage"' \
  --cli

ASSERT_FAIL_BODY='echo "${CLI_ERR}"'
assert_check \
  "CLI unknown flag (exit 64)" \
  "CLI unknown flag (exit 64)" \
  'CLI unknown flag expected exit 64 with usage but got ${CLI_EC}' \
  '[ "${CLI_EC}" -eq 64 ] && echo "${CLI_ERR}" | grep -qi "usage"' \
  --cli --unknown "${REPO_DIR}/fixtures/unwired"

echo "==> Testing CLI --json determinism (two runs byte-identical)..."
run_cli --json "${UNWIRED_GATING}"
first_json_dir="${CLI_DIR}"
first_ec="${CLI_EC}"
run_cli --json "${UNWIRED_GATING}"
ASSERT_KEEP_CLI=1
ASSERT_FAIL_BODY='diff "${first_json_dir}/out" "${CLI_DIR}/out" || true'
assert_check \
  "CLI --json determinism (two runs byte-identical)" \
  "CLI --json determinism (byte-identical stdout across two runs)" \
  'CLI --json stdout differed across two runs (exits ${first_ec}/${CLI_EC})' \
  '[ "${first_ec}" -eq 1 ] && [ "${CLI_EC}" -eq 1 ] && cmp -s "${first_json_dir}/out" "${CLI_DIR}/out"'
rm -rf "${first_json_dir}" "${CLI_DIR}"
CLI_DIR=""

echo "==> Testing CLI --json against eval-corpus scenario (base-gating-dup workspace)..."
# Evidence-runner leg (U5): one eval-corpus scenario end-to-end through the
# zero-touch CLI, findings compared against the scenario manifest's own
# expectedFindings (rule/severity pairs) — the hermetic tier's pins.
set +e
expected_pairs=$(nix eval --json --impure --expr \
  "let s = import ${REPO_DIR}/fixtures/scenarios/lib.nix { }; in s.scenarios.base-gating-dup.expectedFindings" \
  2>/dev/null | jq -S 'map({rule, severity}) | sort_by(.rule, .severity)')
set -e
run_cli --json --draft "${WS_GATING}"
actual_pairs=$(jq -S '.findings | map({rule, severity}) | sort_by(.rule, .severity)' "${CLI_DIR}/out" 2>/dev/null || echo '[]')
ASSERT_FAIL_BODY='echo "expected: ${expected_pairs}"; echo "actual: ${actual_pairs}"; echo "${CLI_ERR}"'
assert_check \
  "CLI --json against eval-corpus scenario (base-gating-dup workspace)" \
  "CLI --json scenario leg (findings match base-gating-dup expectedFindings)" \
  'CLI --json scenario leg mismatch (exit ${CLI_EC})' \
  '[ "${CLI_EC}" -eq 0 ] && [ -n "${expected_pairs}" ] && [ "${expected_pairs}" = "${actual_pairs}" ]'

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "ALL FIXTURE CHECKS PASSED!"
  exit 0
else
  echo "SOME FIXTURE CHECKS FAILED!"
  exit 1
fi

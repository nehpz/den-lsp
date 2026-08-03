#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPARE_BASH="${SCRIPT_DIR}/compare.bash"

PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
  local name="$1"
  local expected_verdict="$2"
  local expected_exit_code="$3"
  shift 3
  local cmd=("$COMPARE_BASH" "$@")

  echo "=== Running Test: ${name} ==="
  set +e
  output="$("${cmd[@]}")"
  ec=$?
  set -e

  echo "Output: ${output}"
  verdict="$(echo "${output}" | jq -r '.verdict // "NONE"')"

  if [ "${ec}" -eq "${expected_exit_code}" ] && [ "${verdict}" = "${expected_verdict}" ]; then
    echo "Result: PASS (matched expected exit ${expected_exit_code} and verdict ${expected_verdict})"
    PASSED_TESTS=$((PASSED_TESTS + 1))
  else
    echo "Result: FAIL (expected exit ${expected_exit_code} verdict ${expected_verdict}, got exit ${ec} verdict ${verdict})"
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi
  echo
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Test 1: AE1 deletion case
# Copy workspace, delete flagged duplicated config in trigger.nix -> golden mismatch even though re-analysis is clean
TEMP_CASE1="${TMP_DIR}/case1_deletion"
cp -r "${REPO_DIR}/fixtures/scenarios/base-gating-dup/workspace" "${TEMP_CASE1}"
cat << 'EOF' > "${TEMP_CASE1}/trigger.nix"
{ config, ... }:
{
  den = {
    aspects = {
      web.nixos = {
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "no";
        };
      };
      db.nixos = {};
      igloo.includes = [
        config.den.aspects.web
        config.den.aspects.db
      ];
    };
  };
}
EOF
run_test "AE1 deletion case (deletion masquerades as repair)" "FAIL" 1 \
  "${TEMP_CASE1}" "${REPO_DIR}/fixtures/scenarios/base-gating-dup/golden" finding duplication

# Test 2: Golden-as-repair
run_test "Golden-as-repair" "PASS" 0 \
  "${REPO_DIR}/fixtures/scenarios/base-gating-dup/golden" "${REPO_DIR}/fixtures/scenarios/base-gating-dup/golden" finding duplication

# Test 3: Reorder-equivalence
# Golden content with attribute/list order shuffled
TEMP_CASE3="${TMP_DIR}/case3_reorder"
cp -r "${REPO_DIR}/fixtures/scenarios/base-gating-dup/golden" "${TEMP_CASE3}"
cat << 'EOF' > "${TEMP_CASE3}/trigger.nix"
{ config, ... }:
{
  den = {
    aspects = {
      igloo.includes = [
        config.den.aspects.db
        config.den.aspects.web
      ];
      db = {
        includes = [ config.den.aspects.shared-openssh ];
      };
      web = {
        includes = [ config.den.aspects.shared-openssh ];
      };
      shared-openssh.nixos = {
        services.openssh = {
          settings.PermitRootLogin = "no";
          enable = true;
        };
      };
    };
  };
}
EOF
run_test "Reorder-equivalence" "PASS" 0 \
  "${TEMP_CASE3}" "${REPO_DIR}/fixtures/scenarios/base-gating-dup/golden" finding duplication

# Test 4: Wrapper-equivalence
# Same content wrapped in a provenance layer
TEMP_CASE4="${TMP_DIR}/case4_wrapper"
cp -r "${REPO_DIR}/fixtures/scenarios/base-gating-dup/golden" "${TEMP_CASE4}"
cat << 'EOF' > "${TEMP_CASE4}/modules/igloo.nix"
{
  _file = "/nix/store/1234567890abcdef1234567890abcdef-source/modules/igloo.nix";
  key = "modules/igloo.nix";
  imports = [
    (_: {
      den.aspects.igloo = {
        nixos =
          { pkgs, ... }:
          {
            environment.systemPackages = [ pkgs.hello ];
          };
      };
    })
  ];
}
EOF
run_test "Wrapper-equivalence" "PASS" 0 \
  "${TEMP_CASE4}" "${REPO_DIR}/fixtures/scenarios/base-gating-dup/golden" finding duplication

# Test 5: New-gating-finding case
# Repaired workspace with an EXTRA gating defect added
TEMP_CASE5="${TMP_DIR}/case5_extra_gating"
cp -r "${REPO_DIR}/fixtures/scenarios/base-gating-dup/golden" "${TEMP_CASE5}"
cat << 'EOF' > "${TEMP_CASE5}/trigger.nix"
{ config, ... }:
{
  den = {
    aspects = {
      shared-openssh.nixos = {
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "no";
        };
      };
      web = {
        includes = [ config.den.aspects.shared-openssh ];
      };
      db = {
        includes = [ config.den.aspects.shared-openssh ];
      };
      igloo = {
        includes = [
          config.den.aspects.web
          config.den.aspects.db
        ];
        unregistered-key-defect = { foo = "bar"; };
      };
    };
  };
}
EOF
run_test "New-gating-finding case (extra gating defect)" "FAIL" 1 \
  "${TEMP_CASE5}" "${REPO_DIR}/fixtures/scenarios/base-gating-dup/golden" finding duplication

# Test 6: eval-error scenario pre-repair (unrepaired workspace fails evaluation)
run_test "eval-error pre-repair failure (base-broken workspace)" "FAIL" 1 \
  "${REPO_DIR}/fixtures/scenarios/base-broken/workspace" "${REPO_DIR}/fixtures/scenarios/base-broken/golden" eval-error

# Test 7: eval-error scenario post-repair (repaired golden matches)
run_test "eval-error post-repair match (base-broken golden)" "PASS" 0 \
  "${REPO_DIR}/fixtures/scenarios/base-broken/golden" "${REPO_DIR}/fixtures/scenarios/base-broken/golden" eval-error

echo "Summary: ${PASSED_TESTS} passed, ${FAILED_TESTS} failed."

if [ "${FAILED_TESTS}" -ne 0 ]; then
  exit 1
fi

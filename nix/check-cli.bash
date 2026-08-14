# shellcheck shell=bash
# Standalone den-lsp-check body. Prefix (DEN_LSP_SRC, SHIM, EPHEMERAL,
# OUTCOME_HELPER, DEFAULT_GATING_NOTICE) is injected by nix/check-cli.nix.

usage() {
  cat <<'EOF'
Usage: den-lsp-check [options] <path>

Analyze a Den consumer flake and print findings.

Options:
  --json              Write the version-1 findings document to stdout
                      (nix eval --json passthrough). Text report and
                      progress go to stderr.
  --draft             Report all findings; exit 0 even when gating
                      findings exist.
  --gate              Fail (exit 1) when gating findings exist. Default.
  --deadline SECONDS  Bound evaluation time (default: 60, or
                      DEN_LSP_CHECK_DEADLINE). Exit 3 on timeout.
  -h, --help          Show this help.

--draft and --gate are mutually exclusive. Strictness only changes the
exit mapping, never the findings.

Exit codes:
  0   Analysis completed, nothing blocking (clean, advisory-only, or --draft)
  1   Gating findings under --gate
  2   Analysis failure (eval error, not a Den flake, unsupported den)
  3   Evaluation timed out
  64  Usage error (missing path, unknown flag, --draft and --gate together)
EOF
}

json=0
strictness=""
deadline="${DEN_LSP_CHECK_DEADLINE:-60}"
target=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      json=1
      shift
      ;;
    --draft)
      if [ "${strictness}" = "gate" ]; then
        echo "den-lsp-check: --draft and --gate are mutually exclusive" >&2
        usage >&2
        exit 64
      fi
      strictness="draft"
      shift
      ;;
    --gate)
      if [ "${strictness}" = "draft" ]; then
        echo "den-lsp-check: --draft and --gate are mutually exclusive" >&2
        usage >&2
        exit 64
      fi
      strictness="gate"
      shift
      ;;
    --deadline)
      if [ "$#" -lt 2 ]; then
        echo "den-lsp-check: --deadline requires a value" >&2
        usage >&2
        exit 64
      fi
      deadline="$2"
      shift 2
      ;;
    --deadline=*)
      deadline="${1#--deadline=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      ;;
    -*)
      echo "den-lsp-check: unknown flag: $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      if [ -n "${target}" ]; then
        echo "den-lsp-check: unexpected extra argument: $1" >&2
        usage >&2
        exit 64
      fi
      target="$1"
      shift
      ;;
  esac
done

if [ -z "${strictness}" ]; then
  strictness="gate"
fi

case "${deadline}" in
  '' | *[!0-9]*)
    echo "den-lsp-check: --deadline must be a non-negative integer" >&2
    usage >&2
    exit 64
    ;;
esac

if [ -z "${target}" ]; then
  echo "den-lsp-check: missing <path> argument" >&2
  usage >&2
  exit 64
fi

emit_timeout() {
  echo "den-lsp-check: evaluation timed out after ${deadline}s" >&2
  exit 3
}

if [ "${deadline}" -eq 0 ]; then
  emit_timeout
fi

if [ ! -d "${target}" ]; then
  echo "den-lsp-check: target is not a directory: ${target}" >&2
  exit 2
fi

abs_target="$(realpath "${target}")"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
doc_json="${workdir}/document.json"
eval_err="${workdir}/eval.err"
outcome_json="${workdir}/outcome.json"

start_ts="$(date +%s)"

remaining() {
  now_ts="$(date +%s)"
  rem=$((deadline - (now_ts - start_ts)))
  if [ "${rem}" -lt 0 ]; then
    rem=0
  fi
  echo "${rem}"
}

# Run a command with a remaining-seconds budget. Stdout/stderr go to the
# given files. Sets bound_ec: 0 on success, 124 on timeout, else the
# command's exit status. Always returns 0 so errexit stays intact.
# Portable: no GNU timeout(1) (absent on stock macOS).
run_bounded() {
  local out_file="$1"
  local err_file="$2"
  shift 2
  local rem
  rem="$(remaining)"
  if [ "${rem}" -le 0 ]; then
    bound_ec=124
    return 0
  fi
  "$@" >"${out_file}" 2>"${err_file}" &
  local cmd_pid=$!
  local elapsed=0
  while kill -0 "${cmd_pid}" 2>/dev/null; do
    if [ "${elapsed}" -ge "${rem}" ]; then
      kill "${cmd_pid}" 2>/dev/null || true
      sleep 1
      kill -9 "${cmd_pid}" 2>/dev/null || true
      wait "${cmd_pid}" 2>/dev/null || true
      bound_ec=124
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  bound_ec=0
  wait "${cmd_pid}" || bound_ec=$?
  return 0
}

classify_eval_err() {
  local err_text="$1"
  if echo "${err_text}" | grep -Eq "does not provide input 'den-lsp'|does not have input 'den-lsp'|input 'den-lsp' not found|input 'den-lsp' does not exist|has no input 'den-lsp'|non-existent input 'den-lsp'|does not match any input"; then
    echo "no-input"
  elif echo "${err_text}" | grep -Eq "does not provide attribute|attribute 'den-lsp-analysis' missing|attribute 'den-lsp' missing"; then
    echo "missing-attr"
  else
    echo "error"
  fi
}

fail_eval() {
  local reason_file="$1"
  echo "den-lsp-check: analysis failure" >&2
  if [ -s "${reason_file}" ]; then
    cat "${reason_file}" >&2
  else
    echo "den-lsp-check: nix eval failed" >&2
  fi
  exit 2
}

eval_document() {
  run_bounded "${doc_json}" "${eval_err}" nix eval --json --no-write-lock-file \
    "${abs_target}#den-lsp-analysis" "$@"
}

echo "den-lsp-check: evaluating ${abs_target}" >&2

bound_ec=0
kind="error"
eval_document --override-input den-lsp "${DEN_LSP_SRC}"
if [ "${bound_ec}" -eq 124 ]; then
  emit_timeout
elif [ "${bound_ec}" -eq 0 ]; then
  kind="wired"
else
  kind="$(classify_eval_err "$(cat "${eval_err}")")"
  if [ "${kind}" = "missing-attr" ]; then
    system="$(nix eval --impure --raw --expr builtins.currentSystem)"
    run_bounded "${doc_json}" "${eval_err}" nix eval --json --no-write-lock-file \
      "${abs_target}#checks.${system}.den-lsp.passthru.analysis" \
      --override-input den-lsp "${DEN_LSP_SRC}"
    if [ "${bound_ec}" -eq 124 ]; then
      emit_timeout
    elif [ "${bound_ec}" -eq 0 ]; then
      kind="wired"
    else
      kind="$(classify_eval_err "$(cat "${eval_err}")")"
      if [ "${kind}" = "error" ]; then
        fail_eval "${eval_err}"
      fi
      kind="unwired"
    fi
  elif [ "${kind}" = "no-input" ]; then
    kind="unwired"
  else
    fail_eval "${eval_err}"
  fi
fi

if [ "${kind}" = "unwired" ]; then
  run_bounded "${workdir}/preflight.out" "${eval_err}" nix eval --impure --expr \
    "import ${EPHEMERAL} { target = ${abs_target}; }"
  if [ "${bound_ec}" -eq 124 ]; then
    emit_timeout
  elif [ "${bound_ec}" -ne 0 ]; then
    fail_eval "${eval_err}"
  fi
  eval_document --override-input flake-parts "${SHIM}" --no-write-lock-file
  if [ "${bound_ec}" -eq 124 ]; then
    emit_timeout
  elif [ "${bound_ec}" -ne 0 ]; then
    fail_eval "${eval_err}"
  fi
fi

if [ ! -s "${doc_json}" ]; then
  echo "den-lsp-check: analysis failure: empty document" >&2
  exit 2
fi

run_bounded "${outcome_json}" "${eval_err}" nix eval --impure --json --expr \
  "import ${OUTCOME_HELPER} { jsonFile = \"${doc_json}\"; strictness = \"${strictness}\"; }"
if [ "${bound_ec}" -eq 124 ]; then
  emit_timeout
elif [ "${bound_ec}" -ne 0 ]; then
  fail_eval "${eval_err}"
fi

text="$(jq -r .text "${outcome_json}")"
mapped_exit="$(jq -r .exitCode "${outcome_json}")"
notice="$(jq -r .gatingNotice "${outcome_json}")"
if [ -z "${notice}" ] || [ "${notice}" = "null" ]; then
  notice="${DEFAULT_GATING_NOTICE}"
fi

print_text_report() {
  printf '%s\n' "${text}"
  if [ "${mapped_exit}" -eq 1 ]; then
    echo
    echo "${notice}" >&2
  fi
}

if [ "${json}" -eq 1 ]; then
  cat "${doc_json}"
  print_text_report >&2
else
  print_text_report
fi

exit "${mapped_exit}"

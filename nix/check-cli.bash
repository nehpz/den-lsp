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
  2   Analysis failure (eval error, not a Den flake, unsupported den).
      Exit-2 stderr carries stable den-lsp:-prefixed reason lines
      (the R4 vocabulary) that scripts may match.
  3   Evaluation timed out
  64  Usage error (missing or invalid path, unknown flag, --draft and
      --gate together)

The <path> argument must be an existing directory and must not contain
whitespace or the flake-ref reserved characters # and ? (Nix cannot
encode those in a flake reference); violations are usage errors.
EOF
}

json=0
strictness=""
deadline="${DEN_LSP_CHECK_DEADLINE:-60}"
target=""

# Internal (test-harness only, not part of the CLI contract): extra args
# appended to the analysis nix evals, e.g. hermetic --reference-lock-file /
# --override-input pins from fixtures/run-checks.bash. Field invocations
# leave this unset: the target's own flake.lock governs.
extra_nix_args=()
if [ -n "${DEN_LSP_CHECK_NIX_ARGS:-}" ]; then
  read -r -a extra_nix_args <<<"${DEN_LSP_CHECK_NIX_ARGS}"
fi

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
      # End of options: everything after -- is positional.
      shift
      while [ "$#" -gt 0 ]; do
        if [ -n "${target}" ]; then
          echo "den-lsp-check: unexpected extra argument: $1" >&2
          usage >&2
          exit 64
        fi
        target="$1"
        shift
      done
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
# Force base-10: a leading zero would otherwise be read as octal in later
# arithmetic (010 -> 8s; 08/09 -> abort with a misleading exit).
deadline=$((10#${deadline}))

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
  exit 64
fi

abs_target="$(realpath "${target}")"
export DEN_LSP_TARGET="${abs_target}"

cmd_pid=""
workdir="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup() {
  if [ -n "${cmd_pid:-}" ]; then
    kill "${cmd_pid}" 2>/dev/null || true
    sleep 1
    kill -9 "${cmd_pid}" 2>/dev/null || true
    wait "${cmd_pid}" 2>/dev/null || true
    cmd_pid=""
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT
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
  cmd_pid=$!
  local elapsed=0
  while kill -0 "${cmd_pid}" 2>/dev/null; do
    if [ "${elapsed}" -ge "${rem}" ]; then
      kill "${cmd_pid}" 2>/dev/null || true
      sleep 1
      kill -9 "${cmd_pid}" 2>/dev/null || true
      wait "${cmd_pid}" 2>/dev/null || true
      cmd_pid=""
      bound_ec=124
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  bound_ec=0
  wait "${cmd_pid}" || bound_ec=$?
  cmd_pid=""
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
  echo "den-lsp: analysis failure" >&2
  if [ -s "${reason_file}" ]; then
    cat "${reason_file}" >&2
  else
    echo "den-lsp: nix eval failed" >&2
  fi
  exit 2
}

# Nix flake refs cannot encode whitespace or # / ? in the directory path
# (quoted path: scheme still parses as a URL). A usage error, not an
# analysis failure.
case "${abs_target}" in
  *[[:space:]]* | *'#'* | *'?'*)
    echo "den-lsp-check: target path cannot contain whitespace or flake-ref reserved characters (#, ?)" >&2
    exit 64
    ;;
esac

eval_document() {
  # path: (not a bare dir ref): a bare ref is git-based and hides files the
  # author created but has not committed — the mid-edit --draft checkpoint
  # must see the working tree, matching the LSP server's path: evals.
  run_bounded "${doc_json}" "${eval_err}" nix eval --json --no-write-lock-file \
    "path:${abs_target}#den-lsp-analysis" "$@" \
    ${extra_nix_args[@]+"${extra_nix_args[@]}"}
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
    run_bounded "${workdir}/system.out" "${eval_err}" nix eval --impure --raw --expr builtins.currentSystem
    if [ "${bound_ec}" -eq 124 ]; then
      emit_timeout
    elif [ "${bound_ec}" -ne 0 ]; then
      fail_eval "${eval_err}"
    fi
    system="$(cat "${workdir}/system.out")"
    run_bounded "${doc_json}" "${eval_err}" nix eval --json --no-write-lock-file \
      "path:${abs_target}#checks.${system}.den-lsp.passthru.analysis" \
      --override-input den-lsp "${DEN_LSP_SRC}" \
      ${extra_nix_args[@]+"${extra_nix_args[@]}"}
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
    "import ${EPHEMERAL} { target = /. + builtins.getEnv \"DEN_LSP_TARGET\"; }"
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
  echo "den-lsp: analysis failure: empty document" >&2
  exit 2
fi

export DEN_LSP_DOC_JSON="${doc_json}"
export DEN_LSP_STRICTNESS="${strictness}"
# Values pass out-of-band via env (same rule as DEN_LSP_TARGET): never
# splice shell strings into a nix --expr, even internally generated ones.
run_bounded "${outcome_json}" "${eval_err}" nix eval --impure --json --expr \
  "import ${OUTCOME_HELPER} { jsonFile = /. + builtins.getEnv \"DEN_LSP_DOC_JSON\"; strictness = builtins.getEnv \"DEN_LSP_STRICTNESS\"; }"
if [ "${bound_ec}" -eq 124 ]; then
  emit_timeout
elif [ "${bound_ec}" -ne 0 ]; then
  fail_eval "${eval_err}"
fi

if ! text="$(jq -r .text "${outcome_json}")" \
  || ! mapped_exit="$(jq -r .exitCode "${outcome_json}")" \
  || ! notice="$(jq -r .gatingNotice "${outcome_json}")"; then
  printf '%s\n' "den-lsp: corrupted outcome JSON" >"${eval_err}"
  fail_eval "${eval_err}"
fi
case "${mapped_exit}" in
  0 | 1) ;;
  *)
    printf '%s\n' "den-lsp: corrupted outcome exitCode '${mapped_exit}'" >"${eval_err}"
    fail_eval "${eval_err}"
    ;;
esac
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

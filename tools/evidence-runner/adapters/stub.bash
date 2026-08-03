#!/usr/bin/env bash
set -euo pipefail

# Deterministic test adapter for evidence-runner (NO LLM)
# Reads STUB_MODE environment variable: golden | delete | sleep | garbage (default: golden)
# GOLDEN_DIR environment variable is passed by run.bash ONLY when adapter is "stub".

STUB_MODE="${STUB_MODE:-golden}"
WORKSPACE_DIR="${WORKSPACE_DIR:?WORKSPACE_DIR must be set}"

case "${STUB_MODE}" in
  golden)
    if [ -z "${GOLDEN_DIR:-}" ] || [ ! -d "${GOLDEN_DIR}" ]; then
      echo "stub.bash: GOLDEN_DIR not provided or does not exist for golden mode" >&2
      exit 1
    fi
    cp -Rf "${GOLDEN_DIR}/." "${WORKSPACE_DIR}/"
    echo '{"status":"completed","turns":1}'
    ;;

  delete)
    find "${WORKSPACE_DIR}" -name "trigger.nix" -delete
    echo '{"status":"completed","turns":1}'
    ;;

  sleep)
    sleep 60
    echo '{"status":"completed","turns":1}'
    ;;

  garbage)
    echo 'NOT_VALID_JSON_GARBAGE_OUTPUT'
    ;;

  *)
    echo "stub.bash: unknown STUB_MODE '${STUB_MODE}'" >&2
    exit 1
    ;;
esac

#!/usr/bin/env bash
# Run a build/test command with this checkout's isolated tools.
#   tools/local_build.sh tools/build_host.sh --configure
#   tools/local_build.sh tests/run_all.sh
# Local overrides belong in ignored out/local-build.env (see docs/building.md).
# LOG_LEVEL=debug prints selected tool paths; LOG_LEVEL=error suppresses progress.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$ROOT/out/local-build.env" ]]; then
  # Explicit caller settings take precedence over this machine's saved defaults.
  override_names=()
  override_values=()
  for name in HOST_ENV LOCAL_NODE_BIN PYTHON CC CXX JOBS DEVKITA64_IMAGE LOG_LEVEL CPM_SOURCE_CACHE PIP_CACHE_DIR; do
    if declare -p "$name" >/dev/null 2>&1; then
      override_names+=("$name")
      override_values+=("${!name}")
    fi
  done
  source "$ROOT/out/local-build.env"
  for ((i = 0; i < ${#override_names[@]}; i++)); do
    export "${override_names[i]}=${override_values[i]}"
  done
  unset override_names override_values name i
fi

log() {
  local level=$1; shift
  case "${LOG_LEVEL:-info}:$level" in
    error:INFO|error:DEBUG|info:DEBUG|warn:INFO|warn:DEBUG) return ;;
  esac
  printf '[local-build] %s %s\n' "$level" "$*" >&2
}

[[ $# -gt 0 ]] || {
  log ERROR 'Supply a command, e.g. tools/local_build.sh tools/build_host.sh --configure'
  exit 2
}
HOST_ENV="${HOST_ENV:-$ROOT/out/host-env}"
[[ -x "$HOST_ENV/bin/python3" && -x "$HOST_ENV/bin/ninja" ]] || {
  log ERROR "Missing Python/Ninja environment at $HOST_ENV; see docs/building.md"
  exit 1
}
export PATH="$HOST_ENV/bin:${LOCAL_NODE_BIN:+$LOCAL_NODE_BIN:}$PATH"
export PYTHON="${PYTHON:-$HOST_ENV/bin/python3}"
export CC="${CC:-clang}" CXX="${CXX:-clang++}"
export JOBS="${JOBS:-1}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$ROOT/out/pip-cache}"
export CPM_SOURCE_CACHE="${CPM_SOURCE_CACHE:-$ROOT/out/cpm-cache}"
log DEBUG "python=$PYTHON ninja=$(command -v ninja) node=$(command -v node || true)"
log DEBUG "CC=$CC CXX=$CXX JOBS=$JOBS"
log INFO "Running $1"
cd "$ROOT"
exec "$@"

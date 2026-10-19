#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp .cache .uv-cache ecosys-ng/.zig-cache-global
export TMPDIR="$PWD/.tmp" XDG_CACHE_HOME="$PWD/.cache" UV_CACHE_DIR="$PWD/.uv-cache"
export ZIG_GLOBAL_CACHE_DIR="$PWD/ecosys-ng/.zig-cache-global" PYTHONDONTWRITEBYTECODE=1
export PYTHONPYCACHEPREFIX="$PWD/.cache/python" HF_HOME="$PWD/.cache/huggingface"
case "${1:-pickup}" in
  pickup) shift || true; exec python3 -B ecosys-audit/scripts/pickup.py "$@" ;;
  exec) shift; exec python3 -B ecosys-audit/scripts/run_logged.py "$@" ;;
  supervise) shift; exec python3 -B ecosys-audit/scripts/worker_supervisor.py "$@" ;;
  code) shift; exec python3 -B ecosys-audit/scripts/code_nav.py "$@" ;;
  codemod) shift; exec python3 -B ecosys-audit/scripts/codemod.py "$@" ;;
  *) exec python3 -B "ecosys-audit/scripts/$1" "${@:2}" ;;
esac

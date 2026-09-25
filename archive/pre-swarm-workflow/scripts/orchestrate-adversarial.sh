#!/usr/bin/env bash
# Artifact-driven Claude editor / Pi reviewer workflow. No transcript forwarding.
set -euo pipefail
if [[ "${HERDR_ENV:-}" != 1 || -z "${HERDR_PANE_ID:-}" ]]; then
  echo 'Run inside the existing Herdr session; external session control is refused.' >&2
  exit 2
fi
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Idempotent, detached controller survives this tool/shell invocation. It never
# sends a new prompt or clears a session until the target is confirmed idle.
exec uv run ecosys-audit/scripts/herdr_cycle.py \
  --session "${ECOSYS_HERDR_SESSION:-ecosys-modernization}" ensure

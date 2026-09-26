#!/usr/bin/env bash
# Start or resume the 4-agent Ottawa qualification swarm (spec section 12; plan P1).
#   scripts/start-swarm.sh            ensure the 4 agents, then run the controller until SAGE-confirmed IDLE
#   scripts/start-swarm.sh --resume   same (kept for compatibility; an interrupted turn is always collected)
#   scripts/start-swarm.sh --agents-only
# No human decisions (D9): the controller clears halts, quarantines bad edits and asks SAGE instead.
# It still requires the one-time launch approval (given 2026-09-25):
#   uv run ecosys-audit/scripts/swarm_wrapper.py approve --by <name>
set -euo pipefail
if [[ "${HERDR_ENV:-}" != 1 ]]; then
  echo 'Run inside a Herdr pane; external session control is refused.' >&2
  exit 2
fi
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
uv run ecosys-audit/scripts/swarm_wrapper.py ensure-agents --start
[[ "${1:-}" == "--agents-only" ]] && exit 0
exec uv run ecosys-audit/scripts/swarm_wrapper.py run "$@"

#!/usr/bin/env bash
# ==============================================================================
# Start DEEPSEEK (DeepSeek Harness, local Qwen3.5-35B-A3B) in the DEEPSEEK Herdr pane
# and register it as the Herdr agent "deepseek".
# Herdr cannot detect dsh itself (no built-in integration; MSYS hides the node child from its
# foreground check), so a background reporter inside this pane reports idle/working state.
# Usage (in the DEEPSEEK pane): scripts/start-deepseek.sh [extra dsh-tui args]
# ==============================================================================
set -uo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

REPORTER=""
if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    pwsh -NoProfile -File scripts/herdr-deepseek-status.ps1 >/dev/null 2>&1 &
    REPORTER=$!
    cleanup() {
        [ -n "$REPORTER" ] && kill "$REPORTER" 2>/dev/null
        herdr pane release-agent "$HERDR_PANE_ID" --source ecosys-deepseek-harness --agent pi >/dev/null 2>&1 || true
    }
    trap cleanup EXIT
else
    echo "[!] Not inside a Herdr pane; starting dsh without Herdr agent registration."
fi

dsh dsh-tui "$@"

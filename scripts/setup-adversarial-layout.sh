#!/usr/bin/env bash
# ==============================================================================
# Setup Herdr Layout for 2-Model Adversarial Dance (CLAUDE judge & DEEPSEEK worker)
# Both agents sit side-by-side on the SAME Herdr tab ('ADVERSARIAL') in multi-pane.
# ==============================================================================
set -euo pipefail

SESSION="${ECOSYS_HERDR_SESSION:-ecosys-adversarial}"
WORKDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[*] Setting up Herdr session '$SESSION' for 2-model adversarial workflow..."

# Check if session exists or start it
if ! herdr session list | grep -q "^${SESSION}[[:space:]]"; then
    echo "[*] Initializing session $SESSION..."
fi

# Query panes in session
PANES_JSON=$(herdr --session "$SESSION" pane list 2>/dev/null || echo '{"result":{"panes":[]}}')
PANE_1=$(echo "$PANES_JSON" | grep -o '"pane_id":"[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "")

if [ -z "$PANE_1" ]; then
    echo "[*] Creating root tab 'ADVERSARIAL'..."
    TAB_INFO=$(herdr --session "$SESSION" tab create --label "ADVERSARIAL" --cwd "$WORKDIR")
    PANE_1=$(echo "$TAB_INFO" | grep -o '"root_pane":"[^"]*"' | cut -d'"' -f4)
else
    # Ensure current tab is labelled ADVERSARIAL
    herdr --session "$SESSION" pane rename "$PANE_1" "CLAUDE" 2>/dev/null || true
fi

echo "[+] Primary pane (CLAUDE): $PANE_1"
herdr --session "$SESSION" pane rename "$PANE_1" "CLAUDE" 2>/dev/null || true

# Split pane to the right for DEEPSEEK on the same tab
echo "[*] Creating split pane to right on same tab for DEEPSEEK..."
SPLIT_INFO=$(herdr --session "$SESSION" pane split --pane "$PANE_1" --direction right --cwd "$WORKDIR" --no-focus 2>/dev/null || echo "")
PANE_2=$(echo "$SPLIT_INFO" | grep -o '"pane_id":"[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "")

if [ -n "$PANE_2" ]; then
    echo "[+] Sibling pane on same tab (DEEPSEEK): $PANE_2"
    herdr --session "$SESSION" pane rename "$PANE_2" "DEEPSEEK" 2>/dev/null || true
fi

echo "================================================================="
echo "[+] Herdr Same-Tab Multi-Pane Layout Complete!"
echo "    Tab:      ADVERSARIAL"
echo "    Left:     CLAUDE (Claude Opus 5.5, reviewer/judge - final say)"
echo "    Right:    DEEPSEEK (local Qwen3.8-27B, does all the work)"
echo "================================================================="

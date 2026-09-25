#!/usr/bin/env bash
# ==============================================================================
# Setup Layout & Start Agents for 'ecosys-modernization' Session
# ==============================================================================
set -euo pipefail
if [[ "${HERDR_ENV:-}" != 1 || -z "${HERDR_PANE_ID:-}" ]]; then
    echo 'Run inside Herdr; external session control is refused.' >&2
    exit 2
fi

SESSION="ecosys-modernization"
WORKDIR="/d/ecosys-modernization"

echo "Configuring session: $SESSION with working directory $WORKDIR..."

# 1. Discover existing panes in session
PANES_JSON=$(herdr --session "$SESSION" pane list)
PANE_1=$(echo "$PANES_JSON" | grep -o '"pane_id":"[^"]*"' | head -n 1 | cut -d'"' -f4)

if [ -z "$PANE_1" ]; then
    echo "[-] Could not find root pane in session $SESSION."
    exit 1
fi

echo "[+] Target primary pane: $PANE_1"

# 2. Split pane to right for reviewer
echo "[*] Creating split pane for reviewer..."
SPLIT_JSON=$(herdr --session "$SESSION" pane split --pane "$PANE_1" --direction right --cwd "$WORKDIR" --no-focus)
PANE_2=$(echo "$SPLIT_JSON" | grep -o '"pane_id":"[^"]*"' | head -n 1 | cut -d'"' -f4)

echo "[+] Created reviewer pane: $PANE_2"

# 3. Start Claude Code as 'editor' in Pane 1 (with claude-opus-5-5 and max effort)
echo "[*] Starting Claude Code as 'editor' in pane $PANE_1..."
herdr --session "$SESSION" agent start editor --kind claude --pane "$PANE_1" -- --model claude-opus-5-5 --effort max

# 4. Start Pi as 'reviewer' in Pane 2
echo "[*] Starting Pi as 'reviewer' in pane $PANE_2..."
herdr --session "$SESSION" agent start reviewer --kind pi --pane "$PANE_2"

echo "================================================================="
echo "[+] Setup Complete!"
echo "    Editor (Claude Code): $PANE_1"
echo "    Reviewer (Pi):        $PANE_2"
echo "================================================================="

# Native project hooks register both conversations. The controller, not a model
# polling loop, dispatches scoped work and rotates only after durable checkpoints.
cd "$WORKDIR"
uv run ecosys-audit/scripts/herdr_cycle.py --session "$SESSION" ensure

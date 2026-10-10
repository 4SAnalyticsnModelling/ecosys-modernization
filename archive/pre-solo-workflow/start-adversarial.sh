#!/usr/bin/env bash
# ==============================================================================
# Start / Orchestrate the worker/judge adversarial workflow:
#   DEEPSEEK (local Qwen3.5-35B-A3B, llama.cpp) works; CLAUDE (Claude Opus 5.5) reviews and rules (final).
# Only CLAUDE-APPROVED rounds are committed and pushed. Runs continuously until complete 30-year Ottawa run with zero science gap is achieved.
# ==============================================================================
set -euo pipefail

cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Starting ecosys-ng adversarial workflow..."
exec uv run ecosys-audit/scripts/adversarial_runner.py "$@"

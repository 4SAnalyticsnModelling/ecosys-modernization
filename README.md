# ecosys-modernization

## Overview
This repository contains the modernization of the ECOSYS biogeochemical model from legacy Fortran 77 (`f77src/`) into Zig (`ecosys-ng/`).

## Project Goal
Complete the 30-year Ottawa simulation run in `ecosys-ng` with **zero science gap** against the legacy Fortran reference and produce **scientifically comparable outputs**.

## Adversarial Workflow
Work is executed via a continuous, token-frugal worker/judge workflow between two AI models hosted on the **same Herdr tab in multi-pane**:
- **Tab**: `ADVERSARIAL`
- **DEEPSEEK Pane (Right)**: `Qwen3.5-35B-A3B` (local llama.cpp at `127.0.0.1:8090`, via the DeepSeek Harness) — **does all the work**: plans rounds, investigates, implements, builds, tests, runs, self-checks and keeps the ledgers.
- **CLAUDE Pane (Left)**: `Claude Opus 5.5` — only **deep scientific diagnosis, cross-language reasoning, architecture decisions and the final scientific review**; makes the **final judgement call** and **directs and guides Qwen when needed**. CLAUDE's decision is final.

Each round, DEEPSEEK plans and does the work, escalating to CLAUDE only for deep diagnosis, cross-language or architecture questions; CLAUDE then gives the final scientific review and rules `APPROVED`, `REVISE` or `REJECTED`. The loop continues until the complete Ottawa run is achieved. There are no stopping hooks or artificial early exits.

## Autonomous Git & Continuous Delivery
- The orchestrator **commits and pushes to `main`** only after a round that CLAUDE has APPROVED.
- The local llama.cpp server must be running for DEEPSEEK; `start-adversarial.ps1 -Status` checks it.

## Token Frugality (Strict)
- Pointer citations (`file:line` + SHA256) instead of pasting bulky source or diffs.
- Simulation logs kept strictly on disk via `run_logged.py`, citing only `receipt.json`.
- Concise round debate summaries (<= 500 words).

## Operational Guide
- Control plane: `.agent/`
- Adversarial rounds log: `.agent/adversarial/`
- Current state: `.agent/state.md`
- Layout setup (Herdr multi-pane on same tab):
  ```powershell
  .\scripts\setup-adversarial-layout.ps1
  ```
- Launch adversarial runner:
  ```powershell
  .\scripts\start-adversarial.ps1 -Continuous
  ```

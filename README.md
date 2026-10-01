# ecosys-modernization

## Overview
This repository contains the modernization of the ECOSYS biogeochemical model from legacy Fortran 77 (`f77src/`) into Zig (`ecosys-ng/`).

## Project Goal
Complete the 30-year Ottawa simulation run in `ecosys-ng` with **zero science gap** against the legacy Fortran reference and produce **scientifically comparable outputs**.

## Adversarial Workflow
Work is executed via a continuous, token-frugal worker/judge workflow between two AI models hosted on the **same Herdr tab in multi-pane**:
- **Tab**: `ADVERSARIAL`
- **DEEPSEEK Pane (Right)**: `Qwen3.8-35B-A3B-Distill` (local llama.cpp at `127.0.0.1:8090`, via the DeepSeek Harness) — **main worker**: investigation, implementation, tests and runs.
- **CLAUDE Pane (Left)**: `Claude Opus 5.5` — **reviewer, critic, supervisor, idea generator, and judge**. CLAUDE's decision is final.

Each round, CLAUDE writes a directive, DEEPSEEK does the work and reports evidence, and CLAUDE rules `APPROVED`, `REVISE` or `REJECTED`. The loop continues until the complete Ottawa run is achieved. There are no stopping hooks or artificial early exits.

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

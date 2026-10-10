# Diagnose brief — parallel hypotheses for a stuck hour or a divergence

**Purpose**: when the same command/error has repeated 3×, or a failure has survived two serious hypotheses, the
parent agent is inside its own loop. Bring in fresh context to break it. You propose **independent, ranked,
falsifiable hypotheses** — you are explicitly asked *not* to endorse the parent's current theory.

**Inputs to give it**: the failing hour/substep and solver; the diagnostic packet (state, layers, thresholds,
residual/increment history, NaN, smallest pivot); what has already been ruled out (PASS/FAIL list with
`file:line`); the ReleaseSafe/Debug replay result; the outputs you were allowed to read.

## Method
1. **Coverage of causes, in this order** (one hypothesis per class, if plausible):
   science (equation/parameter differs from legacy) · translation (indexing, loop bounds, implicit typing,
   GOTO/SAVE state, update order) · binding (a variable the solver and the ledger read differently, stale or
   zero COMMON replacement) · duplication (a flux or transfer applied twice, out-of-sync state copies) ·
   floor bounds (wrong legacy floor family: `0.0` / `ZERO` / `ZERO2` / area-scaled `ZEROS*` / daily
   population-scaled `ZEROP*` / routine-local `ZEROC` 1e-32 SOLUTE vs 1e-48 STARTE) · threshold crossing ·
   degenerate stiffness · oscillation · genuine balance leak.
2. **Cheapest discriminating test for each hypothesis** — a single assertion, one bounded replay, a
   finite-difference Jacobian entry, a matched-state legacy read via `.agent/briefs/legacy-oracle.md`. Name the
   command and the number that would kill it.
3. **Order by (cost × information)**: cheapest decisive test first. Say which single test you would run now.
4. Check the boring candidates the parent may have skipped: an uninitialised layer, a restart/replay mismatch, a
   stale journal, a build that did not relink, an ignored compile warning, a deck/forcing window that differs
   from the baseline run, a units or daily-vs-hourly rescale.

## Rules
- Read-only: no edits, no git writes, no simulation campaigns. Use `f77query.py`, receipts, logs on disk, and cheap
  bounded replays only if the harness permits, and say which you ran.
- No pasted logs. Cite `file:line`, receipt paths, and numbers.
- Do not propose solver-strategy rungs (S1–S9) before the bug classes above are cleared — that is the parent's
  ladder and it starts with bugs.

## Output format (≤ 300 words)
```
H1 <class>: <one-line mechanism> — test: <command/experiment> — kills it if: <expected number>
   evidence for: ... | evidence against: ...
H2 ...
RECOMMENDED NEXT STEP: one concrete action with the exact file:line or command
THINGS THE PARENT MAY BE WRONG ABOUT: <up to 3>
```

## Toolchain and containment (non-negotiable)
- **Zig 0.17.x is the only `ecosys-ng` toolchain.** A receipt from a 0.16 build is dated history, never current
  evidence (`G1`). Check `zig version` before you repeat a build; prefer analysing existing receipts.
- **Inside the repository only.** You are read-only: create nothing, not even scratch — no `/tmp`, no `$HOME`,
  no second checkout, no external drive (gate G9, `.agent/protocol.md` §8a). Any command you run must resolve
  its paths inside the repo; `uv run ecosys-audit/scripts/preflight.py --command "<cmd>"` will tell you.

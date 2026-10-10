# Verifier brief (gate G7) — fresh-context independent re-derivation

**Purpose**: catch the errors self-review cannot catch — Fortran→Zig semantics, solver acceptance that hides a
residual, a floor that only looks right, a ledger that closes on paper. You are not a second opinion: you
**re-derive the numbers yourself** and report PASS/FAIL per gate.

**Give the sub-agent exactly this and nothing else** (no hypothesis, no conclusion from the parent agent):
1. the diff (`git diff origin/main` or the cycle's patch file),
2. the legacy ranges the change cites (`f77src/<file>.f:<lines>`, via
   `uv run ecosys-audit/scripts/f77query.py show|grep` — never bulk-read a `.f` file),
3. the receipts (`audit/runs/**/receipt.json`) and the failing-hour diagnostic packet if any,
4. the gate list and the prohibition list below,
5. the demand for a per-gate verdict in the output format at the bottom.

## Method
1. **Read the legacy lines first, then the Zig.** Write down what the Fortran actually does (`-r8 -i4` → all
   implicit reals f64; arrays often 0-based and column-major; COMMON/EQUIVALENCE aliasing; SAVE/DATA persistence;
   arithmetic IF/GOTO control flow; intrinsic precision). Only then compare with the Zig change.
2. **Floor bounds**: for every guard in the diff or on the failing path, find its legacy floor and check
   **value, scale, operator, units, placement**:
   `0.0`; `ZERO`=1e-15; `ZERO2`=1e-6; `ZEROS`=`ZERO*DH*DV`, `ZEROS2`=`ZERO2*DH*DV`;
   `ZEROP`/`ZEROQ`/`ZEROP2` plant-population-scaled and **recomputed daily from PP**; `ZEROC` **1e-32 in SOLUTE
   but 1e-48 in STARTE**. `AMAX1(ZERO,X)` is not `IF(X.GT.ZERO)`. A hard-coded `1e-15` is *not* parity evidence
   because the Ottawa cell area is 1 m².
3. **Duplication and binding**: is any flux/source/sink/transfer applied twice, or is a state copy read by the
   solver while the ledger reads another? Is any former COMMON variable mapped to stale, zero, or uninitialized
   Zig state?
4. **Acceptance honesty**: does an hour get published without its water/heat/C/N/P ledger closing? Look for
   terminal/ceiling/"best-bounded" paths, in-loop publishes, and bounds checks that use capacity instead of the
   ledger residual.
5. **Reproduce, do not speculate**: rerun the cheap test, replay the small case, or hand-compute the number.
   Report the exact command or arithmetic.

## Hard prohibitions (a hit is a FAIL, no discussion)
tolerance loosening or ceiling/iteration raises without a legacy justification · post-solve clamps · publishing a
non-converged or unclosed-ledger state · new "publish best-bounded" deviations · silent retries · unregistered
DEV-NNN · new `unreachable()` / disabled runtime safety · any edit inside `f77src/`, `f77example/`,
`ecosys-ng-prod-examples/`.

## Rules
- **Read-only.** Edit nothing, create nothing, run no git commands, start no simulation campaign.
- **Consensus is not evidence; a reproduced number is.** Disagreeing with the parent agent is the job.
- Cite `file:line`, short sha, receipt paths. Never paste logs or whole files.
- If you cannot decide a gate, say `INCONCLUSIVE` with the cheapest experiment that would decide it.

## Output format (≤ 250 words)
```
VERDICT: PASS | FAIL | INCONCLUSIVE (overall)
G1 build: PASS/FAIL — <evidence>
G2 regressions: ...
G3 conservation: ...
G4 traceability + floor parity: ... (per guard: legacy f77src/x.f:NNN ↔ zig y.zig:MMM, matched/not)
G5 parity: ...
G6 forbidden diff: ...
G7 self: (this report)
G8 sync: (report only) / G9 containment: (where did the evidence you checked land?)
FAILURES: one line each with the smallest reproducer (command + expected vs observed number)
INCONCLUSIVE: cheapest experiment that would decide it
```

## Toolchain and containment (non-negotiable)
- **Zig 0.17.x is the only `ecosys-ng` toolchain.** A receipt from a 0.16 build is dated history, never current
  evidence (`G1`). Check `zig version` before you repeat a build; prefer analysing existing receipts.
- **Inside the repository only.** You are read-only: create nothing, not even scratch — no `/tmp`, no `$HOME`,
  no second checkout, no external drive (gate G9, `.agent/protocol.md` §8a). Any command you run must resolve
  its paths inside the repo; `uv run ecosys-audit/scripts/preflight.py --command "<cmd>"` will tell you.

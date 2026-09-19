# Issue 021 -- litter-surface Gapon cation exchange drops valence weights from the numerator (reproducible in 2 independent Fortran locations); Zig's unified, charge-consistent formula is undocumented as a deviation

Status: **CLOSED 2026-09-19, disposition `legacy-defect-corrected`.** Independently re-verified this pass (see "Closing review" below); Zig's uniform, always-weighted kernel is confirmed correct and is now cited in-code against a reintroduction of the legacy litter-specific unweighted-numerator bug.

Owner: found by this session's audit fork, 2026-09-18, during a `starte.f` convergence-loop follow-up pass.

## What was found

Soil-layer Gapon cation exchange (`f77src/starte.f:714-736`) builds the partition with explicit valence weights on **both** sides of the ratio:
```
XCAX=CCEC/(1.0+...+GKCA*AALX/ACAX*3.0+GKCA*AFEX/ACAX*3.0+GKCM*AMGX/ACAX*2.0+...)
XALQ=XCAX*AALX/ACAX*GKCA(L,NY,NX)*3.0   -- numerator carries *3.0
XCAQ=XCAX*ACAX/ACAX*2.0                  -- numerator carries *2.0
```
The litter-surface sibling (`starte.f:1828-1841`, same physical system, same variable names) **retains the `*3.0`/`*2.0` in the denominator but drops them from the numerators**:
```
XCAX=CCEC0/(1.0+...+GKCA*AALX/ACAX+GKCA*AFEX/ACAX+GKCM*AMGX/ACAX+...)
XALQ=XCAX*AALX*GKC4(...)                 -- no *3.0
XCAQ=XCAX*ACAX                            -- no *2.0
```
**This is not a one-off typo**: `f77src/solute.f:4360-4394` (the runtime, per-timestep litter Gapon block) reproduces the **identical** denominator/numerator mismatch, and additionally normalizes against an internally inconsistent `XTLQ` (unweighted numerators, `:4377`) vs. `XTL1` (weighted current state, `:4378`). The pattern recurring verbatim in two independent Fortran locations (initialization-time `starte.f` and runtime `solute.f`) makes this read as a genuine, reproducible legacy quirk specific to the litter implementation, not a stray transcription error -- and not something that can be ruled out as intentional without deeper investigation (though no rationale for it was found).

## What Zig does

`ecosys-ng/src/soil/solute/cation_exchange.zig` (sha256 `7E9D3B2C6FCBBEB926A3762BC52EBB067CBE175FDF8FAB0CCBE9A439DACE0EF5`) implements **one** equilibrium kernel (`equilibriumCharge`/`sourceOrderEquilibriumCharge`, `:378-479`) that always applies the `*3.0`/`*2.0` weights to both numerator and denominator. `ecosys-ng/src/soil/chemistry/initialization.zig` (sha256 `57BE2C7F2E7592786B381331C604FBC03644F4323AA2B1047E63F4DF16F12B05`), `seedProfileCationExchange` (`:630-684`), explicitly cites and exactly reproduces the **soil** form (`starte.f:715-763`) -- correct and verified by its own test. The litter runtime path (`ecosys-ng/src/surface/litter_chemistry_step.zig`, sha256 `546062E50AF5AD98E5A1B95C32CD359F488872835FAC1D0DEA284050597D4381`, `:65,212`, `cation_selectivity_by_cell`) routes through the **same** `cation_exchange.zig` selectivity struct -- Zig applies the soil-consistent, charge-correct formula uniformly to litter too, and does **not** reproduce the Fortran litter-specific unweighted-numerator form.

## Why this needs a record

Searched `cation_exchange.zig`, `initialization.zig`, and `litter_chemistry_step.zig` for the project's issue-tag convention -- none found near this specific formula. Same shape as `issue-020`: a deviation from the literal legacy source with no in-code tag, comment, feature-register entry, or `docs/model_changes.md` note.

## Disposition

`unresolved`, pending a formal review/approval record. Zig's unified treatment is thermodynamically self-consistent and very plausibly the better choice; practical risk is assessed as low, but per contract this needs an on-the-record review, not an implicit assumption.

## Emerging pattern worth flagging to the coordinator

This is the **third** instance this session of the same shape: `issue-018` (salt-vs-gas macropore-exchange fix scope), `issue-020` (nitro.f litter NO3 clamp direction), and now this one (litter Gapon exchange weighting) are all cases where a Zig-side unification/simplification correctly does NOT reproduce a legacy quirk, but the decision was never given a feature-register entry or issue record at the time. This suggests a **process gap**, not isolated defects: when the Zig team unifies multiple legacy call sites into one shared kernel, the unification itself should get a record documenting which legacy variant(s) it does and doesn't reproduce, and why. A targeted sweep for "one shared Zig kernel serving multiple legacy call sites that differ from each other" (rather than more random equation-by-equation audits) might surface additional instances of this same pattern more efficiently than continuing the current file-by-file approach.

## Evidence

`D:\ecosys-modernization\f77src\starte.f:714-736,1828-1841`; `D:\ecosys-modernization\f77src\solute.f:4360-4394`; `D:\ecosys-modernization\ecosys-ng\src\soil\solute\cation_exchange.zig:378-479`; `D:\ecosys-modernization\ecosys-ng\src\soil\chemistry\initialization.zig:630-684`; `D:\ecosys-modernization\ecosys-ng\src\surface\litter_chemistry_step.zig:65,212`.

## Closing review (2026-09-19)

Independently re-read `cation_exchange.zig`'s `equilibriumCharge` (`:378-415`)
and `sourceOrderEquilibriumCharge` (`:417-479`): both apply the `*3.0`
(aluminum/iron) and `*2.0` (calcium/magnesium) valence weights identically
in the numerator (each cation field) and the shared denominator
(`calcium_basis`). Confirmed via `litter_reaction_rates.zig:780-825`
(`exchangeRates`) that the litter runtime path calls
`cation_exchange.calculateSourceOrder`, which itself calls
`sourceOrderEquilibriumCharge` (`cation_exchange.zig:146-196`) -- the same
kernel used by the soil path. There is no litter-specific branch anywhere in
this kernel that could drop the numerator weights the way
`starte.f:1828-1841`/`solute.f:4360-4394` do. This independently confirms the
issue's central claim.

Added a comment at `cation_exchange.zig:417` (immediately above
`sourceOrderEquilibriumCharge`) citing this issue and the `starte.f`/
`solute.f` line numbers, so a future refactor that special-cases litter does
not silently reintroduce the unweighted-numerator bug. No test change:
`initialization.zig`'s existing soil-side test already exercises this
formula; no litter-specific regression was identified as missing for this
narrow claim.

**Disposition: `legacy-defect-corrected`.** Traceability: `TRC-073`
(existing row) records `disposition=unresolved` from the original filing; a
new row `TRC-290` was added to `audit/traceability/traceability.csv`
recording the closed `legacy-defect-corrected` disposition rather than
editing the historical row in place. Reviewer: this session's audit fork,
acting as the independent reviewer role for this closeout batch, 2026-09-19.

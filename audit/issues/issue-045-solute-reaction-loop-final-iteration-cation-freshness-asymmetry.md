# Issue 045 -- `solute.f` reaction-equilibrium loop's final-iteration "skip update" exemption list is incomplete: gibbsite/Fe(OH)3 see fresh Al/Fe on iteration 60, calcite/gypsum see one-iteration-stale Ca/CO3/SO4

Status: **OPEN, confirmed legacy source asymmetry; bounded in magnitude (affects only the 60th of 60 per-hour reaction sub-iterations); Zig's Newton-Raphson solver has no analogous "fixed final iteration" concept, so it does not and cannot reproduce this artifact -- architectural non-reproduction, not a documented/reviewed fix.** Needs a reviewer's materiality call rather than an autonomous close.

Owner: found by this session's audit fork, 2026-09-19, during a full statement-level read of `solute.f:1709-2880` (the phosphorus dissociation/precipitation-dissolution engine and the total-ion-transformation aggregation/closure tail), assigned as the largest genuinely-unread contiguous range in `feature-017`'s dossier after a full-file banner sweep.

## Background

`solute.f`'s reaction-equilibrium solve is a fixed `DO 1000 M=1,MRXN` loop (`MRXN=60`, `:111,822`; see `feature-003`). Inside each of the 60 iterations, after the main reaction network runs, the code:

1. Computes net per-iteration ion transformations (`RAL`,`RFE`,`RHY`,`RCA`,`RMG`,`RNA`,`RKA`,`RSO4`,`RCO3`,`ROH`, etc., `:2164-2226`).
2. Updates `CHY1`,`COH1`,`CAL1`,`CFE1` **unconditionally** every iteration (`:2330-2333`).
3. Updates every *other* aqueous/exchangeable/precipitate concentration (`CN41`,`CCA1`,`CMG1`,`CNA1`,`CKA1`,`CSO41`,`CCO31`,`CHCO31`,`CCO21`,`CALO1..4`,`CFEO1..4`, all `X*1` exchangeable pools, all `P*` precipitate pools, etc.) **only if `M.NE.MRXN`** (`:2334-2452`) -- i.e. these updates are skipped on the 60th (last) iteration.
4. Immediately runs a "closing" precipitation-dissolution sub-block for four minerals that directly affect pH: gibbsite `Al(OH)3` (`:2469-2487`), iron hydroxide `Fe(OH)3` (`:2489-2507`), calcite `CaCO3` (`:2509-2533`), gypsum `CaSO4` (`:2535-2555`) -- run every iteration including the 60th, using `AAL1=CAL1*A3`, `AFE1=CFE1*A3`, `ACA1=CCA1*A2`, `ACO31=CCO31*A2`, `ASO41=CSO41*A2` as their driving-force inputs.

## What was found

The exemption list at step 2 (`CHY1,COH1,CAL1,CFE1`) was evidently chosen because those four species feed directly into the closing block at step 4. But **`CCA1`, `CCO31`, and `CSO41` also feed into that same closing block** (calcite needs `CCA1`/`CCO31`; gypsum needs `CCA1`/`CSO41`), and they were **not** added to the exemption list -- they sit inside the `IF(M.NE.MRXN)` gate at step 3 and are therefore frozen on the 60th iteration.

Consequence: on the last of the 60 per-hour reaction sub-iterations only,
- gibbsite's and iron hydroxide's precip-dissolution driving force (`AAL1-AAL1Q`, `AFE1-AFE1Q`, `:2474-2475,2494-2495`) correctly reflects **this iteration's** `RAL`/`RFE` increment (since `CAL1`/`CFE1` were just updated at `:2332-2333`), while
- calcite's and gypsum's driving force (`ACA1-ACA1Q`, `:2517-2518,2540-2541`) is computed from `CCA1`/`CCO31`/`CSO41` values that are **one iteration stale** -- missing the current iteration's `RCA`/`RCO3`/`RSO4` increment, because those updates were skipped by the `M.NE.MRXN` gate.

This is the "N parallel blocks, one outlier (or one incomplete subset)" pattern applied to a 4-member closing block: 2 of 4 minerals (Al, Fe hydroxides) get an exemption their sibling reactions (Ca carbonate, Ca sulfate) needed just as much but didn't receive. The magnitude is bounded -- it only affects the single 60th sub-iteration's calcite/gypsum extent once per hour, not an accumulating drift across all 60 iterations -- but it is a genuine, reproducible statement-ordering defect, not a hypothetical.

## Scope check

Confirmed by direct reading of the full `:2330-2555` span, not inference: `CCA1` is reassigned at `:2339` (`CCA1=AMAX1(ZEROC,CCA1+RCA)`), which sits between `IF(M.NE.MRXN)THEN` (`:2334`) and the matching `ENDIF` (`:2452`); `CAL1`/`CFE1` are reassigned at `:2332-2333`, both strictly before the `IF` at `:2334`. `CCO31` (`:2344`) and `CSO41` (`:2343`) are likewise inside the gated block.

## Why this needs review, not an autonomous close

1. This is a genuine legacy defect per the project contract's investigation order (translation/units/indexing/precision defects come before declaring physical acceptability) -- it needs evidence and review, not a silent absorption into "the generic design happens to differ."
2. No kernel test or numerical impact estimate was produced this pass (read-only, static-source-only constraint for this session). The bounded, once-per-hour, single-substep nature suggests the numerical impact is likely small relative to the already-substantial hour-2,578 convergence difficulty tracked in `issue-015`, but this has not been quantified.
3. Recommend: (a) a reviewer or a follow-up pass construct a matched-state kernel test isolating the 60th-iteration calcite/gypsum extent with and without the one-iteration-stale `CCA1`/`CCO31`/`CSO41` to quantify the discrepancy; (b) if material, consider whether this interacts with the still-open `issue-015` hour-2,578 aluminum/iron/calcium-hydroxide-phosphate disequilibrium frontier, since both involve the same closing block's Al/Fe/Ca precip-dissolution reactions.

## Zig side

`ecosys-ng/src/soil/solute/reaction_solve.zig` (sha256 `623AE7178CBCCDC7DCD312F3D5191E7F692C81D0BDA60CDBC229C7BAFFFF52F0`) implements a genuine Newton-Raphson solver with Anderson acceleration (`feature-003`), not a fixed 60-step successive-substitution loop with a per-iteration "is this the last one" branch. There is no Zig concept corresponding to "the 60th of exactly 60 fixed iterations" at all -- every accepted Newton step updates the full joint state together, so no species can be more or less "fresh" than any other at solve completion. `ecosys-ng/src/soil/solute/geochemistry_reaction_rates.zig` (sha256 `3A26CBAAFBE243F69CD755901DBE6AE8053043E210109C3AB8FD6D64A7F365C9`, `calculateSourceOrder:93-165`) computes gibbsite/iron-hydroxide/calcite/gypsum from a single, internally-consistent state snapshot each call (calcite's consumption of `dissolved_calcium_mol_per_m3` is explicitly threaded into gypsum's own extent calculation via the documented `SOLUTE-013` comment, `:55-61` -- a *different*, already-identified and deliberately-preserved sequencing dependency, not this issue's finding). **Zig therefore does not and architecturally cannot reproduce this specific final-iteration staleness asymmetry** -- but, consistent with every other instance of this recurring pattern in this project (`issue-029`,`issue-036`,`issue-037`,`issue-038`,`issue-041`,`issue-042`,`issue-043`), this is an incidental consequence of a wholesale architecture replacement (approved by `PROJECT_CONTRACT.md`'s numerical-architecture section), not a documented, reviewed decision to specifically correct this statement-ordering defect. Nothing in `reaction_solve.zig` or `geochemistry_reaction_rates.zig` cites `solute.f:2330-2555` for this specific ordering behavior.

## Evidence

`D:\ecosys-modernization\f77src\solute.f:2164-2226,2330-2452,2469-2555` (sha256 `DC0056F3EDEE5670F5EB4443802E829A24A0D3BAE1DE0C4644A33A5007442324`); `D:\ecosys-modernization\ecosys-ng\src\soil\solute\reaction_solve.zig` (sha256 `623AE7178CBCCDC7DCD312F3D5191E7F692C81D0BDA60CDBC229C7BAFFFF52F0`); `D:\ecosys-modernization\ecosys-ng\src\soil\solute\geochemistry_reaction_rates.zig:49-165` (sha256 `3A26CBAAFBE243F69CD755901DBE6AE8053043E210109C3AB8FD6D64A7F365C9`). Cross-referenced against the already-open `audit/issues/issue-015-hour-2578-frontier-needs-human-design-decision.md` (same closing block, different specific finding -- a parameter-file rate-ceiling species-assignment swap, tested and refuted as the sole cause of the hour-2,578 frontier).

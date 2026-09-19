# Issue 047: GROSUB annual root->stalk-reserve phosphorus transfer is capped by the nitrogen pool, not the phosphorus pool

## Impact / severity

Low-to-moderate, narrow scope. Affects only annual determinate/indeterminate
plants during the "transfer non-structural C,N,P from roots to stalk
reserves" step of grain fill (`ISTYP=0 .AND. IDAY(8)!=0`), one root soil
layer at a time. The bug loosens (does not tighten) the upper bound on the
per-hour phosphorus transfer from root nonstructural P (`PPOOLR`) to stalk
reserve P (`WTRSBP`), so in extreme cases (small `PPOOLR`, large `ZPOOLR`,
strong P gradient) the legacy Fortran can draw more P out of a root layer in
one step than that layer actually holds -- a latent mass-conservation defect
in the reference model. The Zig port has already reproduced the legacy
formula bit-for-bit (see below) and additionally guards the outcome with an
explicit runtime error rather than letting the pool go negative silently, so
production is not silently corrupted, but the discrepancy versus the
"correct" physical bound has never been given a disposition.

## First bad location

`f77src/grosub.f:5086-5089` (sha256
`FBE2EE22EAF6E91F8BC8AC0CE01C208F92BBE34662D0D4BEFA20DF886B83F674`), inside
the `DO 2050 L=NU(NY,NX),NI(NZ,NY,NX)` root-layer loop that is itself gated
by `IF(ISTYP(NZ,NY,NX).EQ.0.AND.IDAY(8,NB,NZ,NY,NX).NE.0)THEN` (line 5068),
part of subroutine `grosub`.

```fortran
      XFRN=AMAX1(0.0,AMIN1(ZPOOLR(1,L,NZ,NY,NX)
     2,FXFZ(ISTYP(NZ,NY,NX))*ZPOOLD))*XNFH
      XFRP=AMAX1(0.0,AMIN1(ZPOOLR(1,L,NZ,NY,NX)
     2,FXFZ(ISTYP(NZ,NY,NX))*PPOOLD))*XNFH
```

`XFRN` (nitrogen transfer) is correctly upper-bounded by `ZPOOLR(1,L,...)`,
the root layer's nonstructural **nitrogen** pool. `XFRP` (phosphorus
transfer) reuses the same `ZPOOLR(1,L,...)` term as its `AMIN1` upper bound
instead of `PPOOLR(1,L,...)`, the root layer's nonstructural **phosphorus**
pool. The driving concentration-gradient terms (`ZPOOLD` for N, `PPOOLD` for
P) are correctly element-specific; only the clamp variable is wrong. This is
a one-character-class copy/paste slip in a mechanically parallel N-then-P
statement pair -- the same recurring "N parallel blocks, one outlier"
pattern already documented repeatedly elsewhere in this codebase's audit.

Because root N pools are typically much larger than root P pools (`ZPOOLR >>
PPOOLR` under normal N:P stoichiometry), the erroneous clamp is usually a
no-op: it essentially never binds, so the intended protection ("never
transfer more P out of the layer than the layer holds") is not enforced by
this line. The real bound on P availability is applied later, if at all, by
whatever consumes `XFRP` -- in the unmodified Fortran, nothing else clamps
it before `PPOOLR(1,L,NZ,NY,NX)=PPOOLR(1,L,NZ,NY,NX)-XFRP` at line 5092,
so `PPOOLR` can be driven negative by this statement alone under
sufficiently extreme inputs.

## Zig status: formula faithfully reproduced, outcome explicitly guarded

`ecosys-ng/src/plant/growth/storage_remobilization.zig`
(`transferAnnualRootMobileToBranchReserve`, grosub.f 5050-5110 citation at
`:494-495`) lines 528-536:

```zig
    if (mobile_carbon_total_g_c > inputs.presence_threshold_g_c) {
        const nitrogen_difference_g_n = (inputs.root_mobile.nitrogen_g_n * reserve_after_carbon_g_c -
            inputs.branch_reserve.nitrogen_g_n * root_after_carbon_g_c) / mobile_carbon_total_g_c;
        const phosphorus_difference_g_p = (inputs.root_mobile.phosphorus_g_p * reserve_after_carbon_g_c -
            inputs.branch_reserve.phosphorus_g_p * root_after_carbon_g_c) / mobile_carbon_total_g_c;
        transfer.nitrogen_g_n = @max(0, @min(inputs.root_mobile.nitrogen_g_n, inputs.nutrient_exchange_fraction_per_h * nitrogen_difference_g_n)) * inputs.biological_timestep_h;
        // Exact source behavior: XFRP is capped by ZPOOLR, not PPOOLR.
        transfer.phosphorus_g_p = @max(0, @min(inputs.root_mobile.nitrogen_g_n, inputs.nutrient_exchange_fraction_per_h * phosphorus_difference_g_p)) * inputs.biological_timestep_h;
    }
```

`inputs.root_mobile.nitrogen_g_n` (the N pool, `ZPOOLR`) is deliberately
reused as the clamp for the phosphorus transfer, matching the source exactly,
with an inline comment flagging it. The function's closing guard (lines
539-544) then requires every output pool to be finite and non-negative and
returns `error.AnnualRootReserveExchangeWouldOverdraw` if the transfer would
drive `next_root_mobile` (root P after the transfer) negative -- i.e.
production fails loudly rather than reproducing the legacy silent-negative-
pool outcome. This satisfies the project's "runtime crashes are better than
bugs" principle but the underlying formula-level defect itself has never
been logged or given a disposition, and no regression test pins the
`ZPOOLR`-vs-`PPOOLR` substitution itself (only the general overdraw guard is
implied by the function's validation, not exercised by a dedicated test
using a P-poor/N-rich root layer).

## Hypothesis

Legacy copy/paste defect: the N-transfer statement was duplicated to produce
the P-transfer statement and one of the two `ZPOOLR` references was not
updated to `PPOOLR`. No other explanation fits -- the gradient terms
(`ZPOOLD`/`PPOOLD`), the rate constant (`FXFZ`), and the timestep scaling
(`XNFH`) are all correctly element-specific in the same two lines.

## Minimal reproducer (not executed this pass; static source read only)

Construct a root layer with `ZPOOLR` (N) large, `PPOOLR` (P) small (e.g.
typical N:P >> 10), a strong positive `PPOOLD` gradient (stalk reserve P
depleted relative to root P), and `FXFZ*PPOOLD*XNFH > PPOOLR`. The legacy
formula's `AMIN1(ZPOOLR, FXFZ*PPOOLD)` will not bind (since `ZPOOLR >>
FXFZ*PPOOLD` typically), so `XFRP` is set by the unclamped gradient term
alone and can exceed `PPOOLR`, driving `PPOOLR` negative after
`PPOOLR=PPOOLR-XFRP`. In the Zig port the equivalent inputs trigger
`error.AnnualRootReserveExchangeWouldOverdraw` from
`transferAnnualRootMobileToBranchReserve` instead of a silent negative pool.

## Disposition

`unresolved` at the formula level (legacy defect confirmed, not yet reviewed
for correction; contract requires evidence + review before either
"preserved" as an accepted legacy quirk or "legacy-defect-corrected").
Production's guarded, fail-loud reproduction of the legacy formula is sound
engineering pending that decision and is not itself blocking, but the
gate/gate-reviewer should decide: (a) leave the exact legacy formula in place
(disposition `preserved`, accepting the latent conservation risk is bounded
by the explicit runtime guard and is rarely reachable), or (b) correct the
clamp to `PPOOLR` (disposition `legacy-defect-corrected`, changing model
behavior for P-poor root layers during annual grain fill and requiring
scientific sign-off per the project's improved-physics tolerance policy).

## Recommended regression test (not added this pass)

A `storage_remobilization_test.zig` case with `root_mobile.nitrogen_g_n`
large, `root_mobile.phosphorus_g_p` small, and a phosphorus gradient large
enough that the *correct* (`PPOOLR`-based) clamp would bind but the *actual*
(`ZPOOLR`-based) clamp does not -- pinning today's faithful-reproduction
behavior (either the resulting `phosphorus_translocated`/transfer value if
inputs stay within the overdraw guard, or the explicit
`AnnualRootReserveExchangeWouldOverdraw` error if they don't) so a future
correction is a deliberate, reviewed, test-visible change rather than a
silent behavior drift.

## Evidence

Static source read only this pass (read-only, no-build/no-run constraint).
No tests executed. Cross-checked against grosub.f:5177-5198 (the parallel
`XLOCN`/`XLOCP` grain-fill-from-reserve translocation a few dozen lines
later in the same routine) and its Zig counterpart
`photosynthesis_reproductive.zig:fillGrainFromReserve` (grosub.f 5181-5183,
5191-5193 citations at lines 435-444), which correctly keep N and P
independent (`reserve_n`/`reserve_p`, no cross-substitution) -- confirming
this specific 5086-5089 substitution is a localized, not systemic, defect.

## Author / reviewer

Author: this session's audit fork, 2026-09-19 (feature-007 follow-up pass,
carboxylation + storage-remobilization ranges). Independent reviewer: not
yet done. Status: OPEN.

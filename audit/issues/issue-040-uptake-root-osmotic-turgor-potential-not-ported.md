# Issue 040 -- UPTAKE.F's root osmotic/turgor potential equation (PSIRO/PSIRG, the temperature- and nonstructural-solute-dependent Van't Hoff term) was never ported; Zig substitutes a static per-plant constant, so root turgor never responds to root water status and silently neutralizes the downstream root-extension water-stress limitation

Status: **OPEN, Tier 1 -- confirmed by 2026-09-19 scoping check to need a coordinator/scientist decision, not a simple fix; no source change made this pass.**

Owner: found by this session's audit fork, 2026-09-19, auditing the assigned range `f77src/uptake.f:1229-2003`, while characterizing the canopy-energy-balance closure/default-path block that computes root water/osmotic/turgor potentials after the TKCY convergence solve.

## What was found (Fortran side)

`uptake.f` computes root total, osmotic and turgor water potential (`PSIRT`/`PSIRO`/`PSIRG`) in three structurally parallel places, all using the **same** nonlinear, temperature- and solute-dependent Van't Hoff formula:

- `:1439-1474` (main path, `DO 4505 N / DO 4510 L`, gated on `ILYR` rooted/not-rooted):
  ```
  PSIRT(N,L,...) = MIN(0,(PSIST1(L)*RSRT(N,L)+PSILT*RSSX(N,L))/RSRS(N,L))   [ILYR=1 branch; ILYR=0 branch: PSIRT=PSIST1(L)]
  APSIRT = ABS(PSIRT(N,L,...))
  FDMR = FDMPM + 0.10*APSIRT/(0.05*APSIRT+2.0)
  CCPOLT = CCPOLR(N,L,...) + CZPOLR(N,L,...) + CPPOLR(N,L,...)
  OSWT = 36.0 + 840.0*AMAX1(0.0,CCPOLT)
  PSIRO(N,L,...) = FDMR/FDMPM*OSMO(NZ,NY,NX) - 8.3143*TKS(L,NY,NX)*FDMR*(CCPOLT/OSWT+CSALTR(N,L,...))
  PSIRG(N,L,...) = MAX(0, PSIRT(N,L,...) - PSIRO(N,L,...))
  ```
- `:1399-1411` (rare non-convergence default path, `NNM.GE.MXN`): identical `FDMR`/`OSWT`/`PSIRO`/`PSIRG` formula, `PSIRT=PSIST1(L)`.
- `:1517-1530` (canopy-too-small default path, `VHCPCP.LE.VHCPXZ .OR. FLAIP.LE.1.0E-03`): identical `FDMR`/`OSWT`/`PSIRO`/`PSIRG` formula, `PSIRT=PSIST1(L)`.

`FDMR` (root dry-matter fraction) is a **nonlinear function of the root's own current `|PSIRT|`**, and `PSIRO` depends on the root's own **temperature** (`TKS(L)`, soil/root temperature at that layer) and the root's own **nonstructural C/N/P concentration** (`CCPOLT`) and **salt concentration** (`CSALTR`) -- this is the standard ecosys osmotic-adjustment mechanism: as the root dehydrates (`|PSIRT|` rises), `FDMR` rises, concentrating solutes and driving `PSIRO` more negative, which is what keeps `PSIRG` (turgor) from simply tracking `PSIRT` 1:1. `PSIRG` is consumed by `grosub.f:6022,6480`: `WFNRT=AMIN1(1.0,AMAX1(0.0,PSIRG(N,L,...)-PSILM-RSCS2))`, the root-extension growth-rate water-stress limitation factor.

The canopy has the **exact same-shaped** equation for `PSILO`/`PSILG` (`uptake.f:957-962`/`:1391-1392`), and that one **was** ported faithfully (see `ecosys-ng/src/canopy/energy/water_osmotic_potential.zig`, header "A8a DISPOSITION: BOUND; CANOPY-TURGOR-001 closed with CANOPY-TKC-001", term-for-term match including `8.3143`, `FDMP`/`FDMPM`, `CCPOLT`/`OSWT`, `CSALTP`).

## What Zig does (root side)

`ecosys-ng/src/plant/root/water_balance.zig`, `state_updateRootHydraulicsWithCanopyPotential` (`:821-889`), computes root total potential correctly (`:853,883`, matching the `PSIST1*RSRT+PSILT*RSSX)/RSRS` weighting -- this sub-part is fine and already covered as `preserved` by this dossier's first section). But osmotic potential is then computed as:

```zig
const osmotic = leaf_osmotic_potential_at_zero_total_megapascal[plant] + root_potential;   // :854, :884
roots.turgor_water_potential_megapascal[root_state_index] = @max(0.0, root_potential - osmotic);  // :887
```

`leaf_osmotic_potential_at_zero_total_megapascal[plant]` is **not** a per-hour, per-root-layer, temperature/solute-dependent quantity -- it is a **static, per-plant PFT trait value**, set once at initialization (`ecosys_ng.zig:11714`: `owners.plant_water_workspace.?.leaf_osmotic_potential_at_zero_total_megapascal[plant] = traits.water_relations.osmotic_potential_megapascal;`) and never touched again for the rest of the run. There is no `FDMR`, no `TKS`/soil temperature, no `CCPOLR`/nonstructural-solute concentration, and no `CSALTR`/salt concentration anywhere in this computation.

Algebraically this means, for every root layer, every hour: `turgor = root_potential - (OSMO_trait + root_potential) = -OSMO_trait` -- **a constant, equal to the negative of the static PFT trait, that never varies with actual root water status, soil temperature, or nonstructural solute concentration.** (E.g. with the test fixture's `OSMO_trait = -1.5 MPa`, turgor is pinned at `+1.5 MPa` regardless of how dry the soil gets; see `water_balance.zig`'s own test at `:1102-1104`, where `total=-0.4375`, `osmotic=-1.9375=(-1.5)+(-0.4375)`, `turgor=1.5=-(-1.5)`.)

## Why this matters (not merely a naming/precision nit)

`roots.turgor_water_potential_megapascal` is read directly by `stages/root_processes_metabolism.zig:291,303`, feeding `plant_root_metabolism_respiration.zig`'s `rootEnvironmentResponses` (`:85-126`), whose `extension_water` term:

```zig
const extension_water = std.math.clamp(root_turgor_water_potential_megapascal - minimum_extension_water_potential_megapascal - scaled_resistance, 0, 1);
```

is the direct, term-for-term translation of `grosub.f:6022,6480`'s `WFNRT=AMIN1(1.0,AMAX1(0.0,PSIRG-PSILM-RSCS2))` root-extension-growth water-stress factor. Because `root_turgor_water_potential_megapascal` never actually falls as the plant dries out (it is pinned at a positive constant derived from the static `OSMO` trait), `extension_water` will sit at its ceiling (`1`, minus whatever `scaled_resistance` subtracts) far more often than the legacy model, which lets `PSIRG` fall toward zero as `|PSIRT|` grows and nonstructural solutes fail to concentrate fast enough to compensate. **This silently removes/weakens one of ecosys's designed drought-response feedbacks on root growth** -- not a cosmetic or precision-only difference.

This equation has no prior traceability row: grepping `audit/traceability/traceability.csv` for `PSIRO`/`PSIRG`/`osmotic` (root-specific) returns no prior match, and no `feature-*.md` register entry documents a deliberate simplification of the root osmotic-adjustment mechanism. This looks like a genuine translation/completeness gap, not a documented, approved feature change.

## Materiality (not resolved this pass)

Static analysis only, per this pass's read-only-audit constraint (no build/run performed). Not checked this pass:
- The magnitude of the resulting root-extension-growth difference over a growing season on the v1.0.0-scope example deck(s); requires a matched-state kernel test (feed both the legacy `FDMR`/`PSIRO` formula and the current Zig constant-turgor formula the same `PSIRT`/`TKS`/`CCPOLR`/`CSALTR` series and compare `WFNRT`/`extension_water` trajectories) or a controlled A/B production run, neither performed this pass.
- Whether any other consumer besides `rootEnvironmentResponses`' `extension_water` reads `roots.osmotic_water_potential_megapascal` or `roots.turgor_water_potential_megapascal` and would also be affected (a codebase-wide consumer sweep was not exhaustively performed beyond the grep in this file).
- Whether the missing inputs (`TKS`-equivalent soil/root temperature, `CCPOLR`/nonstructural-C,N,P concentration, `CSALTR`/root salt concentration) are even available at the `state_updateRootHydraulicsWithCanopyPotential` call site (`stages/hourly_snow_energy.zig:654`) without a larger plumbing change; not investigated this pass.

## Disposition

`unresolved`. Needs a coordinator decision: (a) port the full `FDMR`/`TKS`/`CCPOLR`/`OSWT`/`CSALTR` osmotic-adjustment formula for roots, mirroring the already-correct canopy-side `water_osmotic_potential.zig` (same functional form, root-specific inputs, one call per `(plant,domain,layer)` per hour inside the same hourly root-hydraulics pass that already computes `root_potential`); or (b) obtain explicit scope approval to treat the constant-turgor simplification as a deliberate, reviewed approximation (would need its own feature-register entry with a stated scientific rationale and envelope, since none exists today).

## Scoping check (2026-09-19)

Bounded, read-only-only triage pass (no build/run performed), done to decide
between implementing a fix this pass (the `issue-054` pattern: a simple,
unambiguous, low-risk wire-up with a clearly correct source value) versus
leaving this for a human/scientist decision (the `issue-050` pattern: a
judgment call and/or a gap that cannot be bounded by static analysis alone).
**Conclusion: this is the `issue-050` pattern, not the `issue-054` pattern.**
Two independent reasons:

1. **Not a simple wire-up -- confirmed plumbing gap, not just a missing
   formula.** Read `ecosys-ng/src/plant/root/water_balance.zig`'s
   `state_updateRootHydraulicsWithCanopyPotential` signature and body
   (`:821-889`) and its sole call site,
   `ecosys-ng/src/stages/hourly_snow_energy.zig:654`. The function's actual
   parameter list carries only `soil_total_water_potential_megapascal`,
   `canopy_water_potential_megapascal`, the two resistance arrays, and the
   static per-plant `leaf_osmotic_potential_at_zero_total_megapascal` trait --
   no per-layer temperature, no nonstructural-solute-concentration, no
   salt-concentration array is passed in today. `FDMR`/`OSWT`/`PSIRO`'s three
   missing legacy inputs (`TKS`, `CCPOLR`, `CSALTR`) are **not** simply unused
   local variables sitting one line away, unlike `issue-054`'s fix. A repo
   grep confirms the *concepts* exist elsewhere in the codebase --
   root-nonstructural-concentration-shaped state in
   `plant_root_nutrient_uptake.zig`/`plant_root_system.zig` and root-salt
   state in `plant_root_salt_exchange.zig` -- but none of it currently flows
   into this water-balance call. Threading it in is real cross-module
   plumbing (new parameters, a data source per input, and -- per the
   contract's transactional-trial-state rule -- keeping the whole staged
   `solveLivingCanopyCells`/`state_updateRootHydraulicsWithCanopyPotential`
   transaction still fully revertible on failure), not a one-field
   substitution. The issue's own "not investigated this pass" caveat on data
   availability is now confirmed true: the plumbing gap is real.
2. **Reachability/materiality cannot be bounded by static input-file
   analysis**, unlike `issue-050`/`028`/`031`/`044`/`056` (each resolved this
   session by checking a static flag or a constant-zero input field). This
   term's magnitude depends on **emergent simulated state** -- how negative
   root total water potential (`PSIRT`) actually gets under transpiration
   demand between rain events, plus per-layer root temperature and
   nonstructural-C/N/P concentration trajectories -- none of which is a
   static site/weather/management input that can be read off a file. No
   full-season run exists for this deck yet (`issue-015` blocks completion at
   hour 2,578/262,920), and this pass's read-only-first constraint precludes
   starting one to find out. A matched-state kernel test (feed both formulas
   the same `PSIRT`/temperature/solute series) could bound this without a
   full run, but was not built this pass and is itself a design choice
   (what series to feed) that benefits from coordinator sign-off given point
   1 above.

Both findings independently confirm the disposition below is unchanged and
this stays **Tier 1** (needs a coordinator/scientist decision) rather than
being promoted to a Phase-2 fix in this pass. No source file was modified;
no test was added; no build or run was performed.

## Evidence

`D:\ecosys-modernization\f77src\uptake.f:1399-1411,1439-1474,1517-1530` (sha256 `D60132510BB9AB8DD79D62D3770F8BFB9A1984D7C480E388D3F33FE4D8281B2B`); `D:\ecosys-modernization\f77src\grosub.f:6019-6025,6477-6483` (sha256 `FBE2EE22EAF6E91F8BC8AC0CE01C208F92BBE34662D0D4BEFA20DF886B83F674`); `D:\ecosys-modernization\ecosys-ng\src\plant\root\water_balance.zig:821-889,1100-1104` (sha256 `D324AE80966B1F02D629AB102981A3EBDF4812EEA3CF59A92AF20A14D8F65405`); `D:\ecosys-modernization\ecosys-ng\src\canopy\energy\water_osmotic_potential.zig` (the already-correct canopy-side sibling; sha256 `31AC214046D4DDF26C119EE8FC1B16B3BF2B9C217FA3250D976F31C5AACD88C9`); `D:\ecosys-modernization\ecosys-ng\src\stages\root_processes_metabolism.zig:285-308` (sha256 `AE91A24A5A86697C2DFEBC7C686398BFBC1348BB29D68B110554999391421C20`); `D:\ecosys-modernization\ecosys-ng\src\plant\root\plant_root_metabolism_respiration.zig:85-126` (sha256 `42AC7E1EFAB27E57802B47A0A5A6202408C530D359DBD67309AE51FEE54D6CE8`); `D:\ecosys-modernization\ecosys-ng\src\ecosys_ng.zig:11701-11724` (sha256 `E9F35F7116D8DEDE874D2E3C348385A08927C09ADC6F53069DE7C361724C6C27`); `D:\ecosys-modernization\ecosys-ng\src\stages\hourly_snow_energy.zig:654` (sha256 `30B89B131209007AF7902FF6EE0FA21887D6E067888F75A4B55E9AF916F33A87`).

# Issue 044: `trnsfr.f` subsurface-irrigation gas flux hardcodes H2 to zero while five sibling gases compute real values; Zig irrigation-chemistry schema carries no gas species at all

## Status: unresolved (flagged for reviewer judgment, not autonomously dispositioned)

## Location

`f77src/trnsfr.f:825-840` (subsurface irrigation solute flux block, inside the `DO 10 L=NU(NY,NX),NL(NY,NX)` soil-layer loop starting at `:713`).

```
      RCOFLU(L,NY,NX)=FLU(L,NY,NX)*CCOQ(NY,NX)
      RCHFLU(L,NY,NX)=FLU(L,NY,NX)*CCHQ(NY,NX)
      ROXFLU(L,NY,NX)=FLU(L,NY,NX)*COXQ(NY,NX)
      RNGFLU(L,NY,NX)=FLU(L,NY,NX)*CNNQ(NY,NX)
      RN2FLU(L,NY,NX)=FLU(L,NY,NX)*CN2Q(NY,NX)
      RHGFLU(L,NY,NX)=0.0
      RN4FLU(L,NY,NX)=FLU(L,NY,NX)*CN4Q(I,NY,NX)*VLNH4(L,NY,NX)*14.0
      ...
```

`RCOFLU`/`RCHFLU`/`ROXFLU`/`RNGFLU`/`RN2FLU` (CO2, CH4, O2, N2, N2O) each compute a real, nonzero
subsurface-irrigation gas flux from `FLU` (subsurface water flux from `watsub.f`) times an
irrigation-water gas concentration (`CCOQ`,`CCHQ`,`COXQ`,`CNNQ`,`CN2Q`). `RHGFLU` (H2), the sixth
member of this file's standard six-gas group (CO2,CH4,O2,N2,N2O,H2), is hardcoded to `0.0` in the
same statement block, immediately adjacent to its five siblings. This is the surface signature this
session calls the "issue-043 shape": a parallel block zeroing one species that siblings in the same
block compute for real.

## Investigation performed this pass

- Confirmed by exhaustive `grep` of `f77src/trnsfr.f` that no `CH2Q` (or any other H2-labeled
  irrigation/precipitation concentration variable) exists anywhere in the file. `CCOQ`,`CCHQ`,
  `COXQ`,`CNNQ`,`CN2Q` (the five sibling gas concentrations) all exist and are used consistently
  elsewhere (atmosphere-to-surface precipitation entry at `:352-371,455-509`).
- This is consistent with a second, independently confirmed finding from the same pass (see the
  feature-009 dossier addendum, "Finding 11"): H2 and NO2 are structurally absent from every
  snowpack-related state array and every atmosphere/irrigation input-concentration variable in this
  file (no `H2GW2`/`ZNO2W2` snowpack state, no `CH2R`/`CNXR`/`CH2Q`/`CNXQ` input concentrations
  anywhere). That absence was ruled out as a defect for the *snowpack* pathway because it is fully
  symmetric there (every snowpack/snow-drift-related array uniformly omits H2 and NO2, with no
  sibling block computing a real value for either species).
- **This location is different and not fully ruled out**: unlike the snowpack case, this exact
  six-gas group's *subsurface-irrigation* flux block computes real, nonzero values for five of six
  gases (CO2,CH4,O2,N2,N2O) from a real irrigation-concentration input (`CCOQ` etc.), and only H2
  lacks that input. Whether the complete absence of an H2 irrigation-concentration field in the
  legacy input-file format (and therefore in `trnsfr.f`) is:
  (a) a deliberate, physically reasonable choice (dissolved H2 is not a real-world irrigation/well-water
      water-quality parameter, unlike CO2/O2/N2 equilibrium concentrations or agricultural NH4/NO3/PO4),
      or
  (b) an overlooked legacy gap (nobody ever wired an H2 field into the input format, even though the
      code clearly intended H2 to participate symmetrically in this exact mechanism, as it does in
      every other transport pathway in this file),
  was **not resolved this pass** and needs a reviewer/domain judgment call, not an autonomous guess.

## Zig-side gap (broader than the single-species legacy asymmetry)

The only Zig counterpart located for subsurface-irrigation solute chemistry:

- `ecosys-ng/src/management/irrigation_schedule.zig`'s `WaterChemistry_g_per_m3` struct (`:6-19`):
  fields are `ph`, `ammonium_nitrogen`, `nitrate_nitrogen`, `phosphate_phosphorus`, `aluminum`,
  `iron`, `calcium`, `magnesium`, `sodium`, `potassium`, `sulfate_sulfur`, `chloride` -- **no gas
  species field at all** (no CO2/CH4/O2/N2/N2O/H2 equivalent).
- `ecosys-ng/src/management/irrigation_layer_routing.zig`'s `Loads.accumulate` (`:127-206`) routes
  water volume, the 11 dissolved (salt/nutrient) species above, and a derived `hydrogen_mol` (H+ from
  pH, unrelated to H2 gas) into `surface_*`/`subsurface_*` carriers. Its own doc comment
  (`IRRIGATION-SUBSURFACE-DEAD-CODE-001`, `:6-13,172-185`) states the surface-vs-subsurface
  *application-depth* routing is currently dead code, mirroring a *different* legacy dead-code path
  (`wthr.f`'s commented-out `WDPTHD.LE.CDPTH` depth check, which forces `PRECU`=0.0), not necessarily
  the same physical process as `trnsfr.f:825-840`'s `FLU`-driven subsurface irrigation solute flux.

If `irrigation_layer_routing.zig`/`irrigation_schedule.zig` is genuinely the counterpart of
`trnsfr.f`'s `FLU`-based mechanism, then **none** of the five real-valued legacy gas irrigation
fluxes (`RCOFLU`,`RCHFLU`,`ROXFLU`,`RNGFLU`,`RN2FLU`) are reproduced in Zig -- a broader gap than the
single-species (`RHGFLU`) legacy asymmetry, and not the same shape as this session's other
"generic Zig architecture incidentally doesn't inherit a legacy asymmetry" findings (issue-029,
issue-041, issue-042, issue-043), because here Zig's schema has no slot for the gas species at all
rather than a generic per-species loop that happens to treat all gases uniformly.

## Why this is flagged rather than dispositioned

Three open questions need reviewer/domain judgment, not an autonomous guess:

1. Is `f77src/trnsfr.f:825-840`'s `FLU` mechanism the same physical process as
   `irrigation_layer_routing.zig`'s subsurface carrier, or a distinct mechanism whose real Zig
   counterpart has not yet been located?
2. If they are the same mechanism: is the missing 5-gas (CO2/CH4/O2/N2/N2O) subsurface-irrigation
   flux contribution scientifically material enough to need porting, given it is currently dead code
   on the Zig side per `IRRIGATION-SUBSURFACE-DEAD-CODE-001` and (per that comment) intentionally
   mirrors a legacy dead-code path -- but a *different* legacy dead-code path than the one at issue
   here?
3. Is `CH2Q`'s total absence from the input-file format/legacy source a deliberate scope limitation
   (no real-world H2 irrigation-water-chemistry data source exists) or an overlooked legacy gap that
   pre-dates this migration and is out of scope to "fix" versus merely document?

## Recommended next step

A reviewer should first confirm whether `IRRIGATION-SUBSURFACE-DEAD-CODE-001`'s dead-code path and
`trnsfr.f`'s `FLU` pathway are the same mechanism (requires reading `wthr.f:300-320` and the Zig
`hourly_heat_water_solute.zig`/`hourly_gas_surface_water.zig` stage wiring, not done this pass under
the read-only/no-build constraint). No `zig build`/test/run executed this pass.

## Disposition: `unresolved`

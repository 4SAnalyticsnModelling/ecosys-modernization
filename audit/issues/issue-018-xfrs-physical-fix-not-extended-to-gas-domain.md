# Issue 018 -- macropore/micropore diffusive-exchange physical fix (SOLUTE-XFRS-PHYSICAL) applied to salts only, not to gases/dissolved nutrients, with no documented reason

Status: **OPEN, candidate gap -- needs a reviewer's judgment call, not yet confirmed as a defect.** Same shape as `issue-017`: a domain-scope inconsistency verified against real production call sites (not a stale comment), where one branch of a physically-symmetric problem got an approved fix and a parallel branch didn't, with no record of whether that's deliberate.

Owner: found by this session's audit fork, 2026-09-18, during a `trnsfr.f`/`trnsfrs.f` macropore/micropore exchange deep-dive.

## Background

Both `trnsfrs.f` (salts) and `trnsfr.f` (gases/dissolved nutrients) implement the same two-part macropore<->micropore exchange pattern within a soil layer: convective exchange (directional branch on flow sign) and diffusive exchange (concentration-gradient relaxation capped by `XFRS*VOLT`, the macropore-volume cap). Confirmed structurally identical between the two files: `trnsfrs.f:3379-3391` (salts, e.g. H+) vs. `trnsfr.f:2516-2518` (gases, e.g. O2), both of the form `DFV=XNPHX*(max(0,C1)*VOLWM - max(0,C2)*VOLWHS)/VOLWT` with `VOLWHS=min(XFRS*VOLT,VOLWHM)`.

## What was found

**Salt pathway**: `ecosys-ng/src/soil/solute/transport.zig` (sha256 `99D9896CD3AB75694A1B6F2C6A1D5DFE3F701FBA4F3E9D222A75D3006DFC17B5`, `:215-278`, `calculatePoreExchangeFlux`) does **not** literally translate the legacy `XFRS=0.05`-capped formula. It's tagged `SOLUTE-XFRS-PHYSICAL`, an approved physical replacement with explicit documented rationale: the legacy cap "moves the zero-flux point away from true concentration equality whenever macropore water exceeds `0.05*layer_volume`... in exactly the wet, macropore-rich regime that motivates having a dual-domain model at all." Replaced with an uncapped equal-concentration equilibrium relaxed at a Gerke-van Genuchten first-order rate, sharing the geometric length scale (`macropore_spacing_m`) already used for water-phase dual-domain exchange (`soil/water/solver_residual.zig:220-221`). Confirmed live: `driver/transport_step.zig` (sha256 `8561548CC1D67FCD2EBF8CE9F31706531EA5120188F2A85CA489DEC97076F7F0`, `:23-38`) wires `macropore_spacing_m`/`micropore_diffusivity_m2_per_h` through to this function in production.

**Gas/dissolved-nutrient pathway**: `ecosys-ng/src/soil/gas/aqueous_extensive_transport.zig` (sha256 `012702E6DCCEA82DF4CC19CF6A4A37E82FF2FF320A99D2F2EEA9D1EDE0EC54BC`), a separate function `poreExchange` (`:770-778`), **is a literal translation of the legacy capped `XFRS=0.05` formula** -- the exact formulation the salt-pathway's own doc comment identifies as physically flawed:
```zig
const exchanging_macro_water = @min(0.05 * bulk_volume, macro_water);
const combined_water = micro_water + exchanging_macro_water;
const exchange = fraction * (macro * micro_water - micro * exchanging_macro_water) / combined_water;
```
No `macropore_spacing_m`/`micropore_diffusivity_m2_per_h` parameters exist in this file's `Options` struct (`:8-44`). Confirmed live and production-wired via `soil/gas/dissolved_gas_transport.zig` (sha256 `E230555E9232D911A9AEBA6496187B9385C7905A599F507A633DEE674D65DE1C`, import at `:4`, calls with `pore_exchange_fraction=1` at `:180,214`) -- not dormant.

**No documentation found** explaining the scope difference: grepped `ecosys-ng/src/soil` for the issue-tag convention -- `SOLUTE-XFRS-PHYSICAL` appears only in the salt-domain files (`soil/solute/transport.zig`, `driver/transport_step.zig`), never near `aqueous_extensive_transport.zig`.

## Why this needs review, not an autonomous fix

The salt-pathway's own critique of the `0.05` cap is a physical argument about macropore-rich wet conditions in general, not something specific to salts as a species class -- on its face, the same objection would apply to dissolved O2/CO2/CH4/N2O/H2/NH3/DOC/DON/DOP/acetate transport. But there could be a legitimate reason the fix was scoped to salts only (e.g. gas-phase Henry's-law equilibration dominating and making the liquid-phase cap comparatively unimportant for gases specifically) that this session did not find documented anywhere. This is exactly the kind of domain-specific physical judgment call that needs a reviewer with the right background, not a guess.

## Disposition

`unresolved`, pending review. Not treated as confirmed -- the fork that found this was appropriately careful to distinguish "an undocumented scope difference exists" from "the gas pathway is wrong."

## Secondary, unresolved follow-up from the same pass (lower confidence, not enough budget to close)

`trnsfr.f:4396-4522`: vertical macropore-to-macropore transport nets the already-committed lateral macro-micro exchange (`R*FXS`) against the vertical flux only when flow is *from* the current cell (`FLWHM>0`, `:4411-4412`); the opposite-direction branch (`FLWHM<0`, `:4491-4521`) has no equivalent netting -- structurally the same shape as `issue-017`'s pond/soil asymmetry (one flow-direction branch carries an extra rule the other doesn't). No salt-solute equivalent was found to confirm whether this is a deliberate legacy design choice, and the Zig counterpart for this specific vertical-transport face logic was not located in the time available (likely `soil/gas/face_assembly.zig` or `transport/redistribution.zig`, unconfirmed). Flagged for a dedicated follow-up pass, not concluded here.

## Evidence

`D:\ecosys-modernization\f77src\trnsfrs.f:3147-3470,6307-6603`; `D:\ecosys-modernization\f77src\trnsfr.f:2354-2550,4396-4522`; `D:\ecosys-modernization\ecosys-ng\src\soil\solute\transport.zig:215-310`; `D:\ecosys-modernization\ecosys-ng\src\soil\gas\aqueous_extensive_transport.zig:8-44,129-141,770-778`; `D:\ecosys-modernization\ecosys-ng\src\driver\transport_step.zig:23-38,67-80`; `D:\ecosys-modernization\ecosys-ng\src\soil\gas\dissolved_gas_transport.zig:4,147,180,214`.

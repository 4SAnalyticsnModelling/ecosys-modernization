# Round 00050: Verification of DEV-021 (Band-Sliver Molarity Guard Scope)

## 1. Relayering Disconnect between Band Geometry and Solute Mass
In `f77src/redist.f`, geometry and solute mass move on fundamentally different bases:
- **Geometry Transfer (`redist.f:9498-9513`)**:
  Band dimensions (WDNHB, DPNHB) transfer via layer thickness fraction `FX` of donor vs recipient geometry boundaries:
  `FXWDNHB = AMIN1(FX*WDNHBDL, WDNHBD0)`
  `VLNHB(L0) = AMAX1(0.0, AMIN1(0.9999, WDNHB(L0)/ROWN * DPNHB(L0)/DLYR(3,L0)))`
- **Solute Mass Transfer (`redist.f:9850-9856`)**:
  Solute mass transfers via bulk water fraction `FWO = FX`:
  `IF(VLNHB(L1,NY,NX).GT.ZERO) THEN`
  `FXZNH4B = FWO * ZNH4B(L0,NY,NX)`
  `ZNH4B(L0,NY,NX) = ZNH4B(L0,NY,NX) - FXZNH4B`
- **Confirmation**: Geometry depends on WD/DP limits and layer thickness, while mass transfers via bulk water `FWO`. When geometry transfers nearly completely (`VLNHB(L0) ~ 1e-14`), donor solute mass `ZNH4B(L0)` retains a tiny non-zero sliver (e.g. 6.5e-9 g N).

## 2. Legacy Evaluation of Band Zones with Tiny VLNHB
In legacy `hour1.f:3845-3853` and `solute.f:397-414`:
- When `VLNHB <= ZERO` (`ZERO = 1.0e-15`, `starts.f:93`), band concentration is strictly zeroed:
  `IF(VLNHB(L,NY,NX).GT.ZERO) THEN CNH4B = ZNH4B / (VOLW*VLNHB) ELSE CNH4B = 0.0`
- In `solute.f:397`, when `VOLWNB = VOLW * VLNHB <= ZEROS2` (`ZEROS2 = 1.0e-6 * area`), `CN4B = 0.0` and reactions are bypassed.
- In `nitro.f:1156, 1165, 2103`, band reaction fluxes scale by `FNHBS = ZNH4BX / ZNH4T` or `FNB4 * ZNH4B * XNFH`. Because mass `ZNH4B ~ 1e-9 g` is infinitesimal, the resulting absolute reaction/uptake fluxes are virtually zero (< 1e-12 g). Legacy never aborts because it has no molarity sanity guard.

## 3. Verdict: CONFIRM DEV-021 as D2
- **Verdict**: **CONFIRM DEV-021** as category **D2** (numerical sanity guard scope; preserves exact legacy behavior with no state or inventory alteration).
- In `ecosys-ng`, the water molarity assertion was intended to catch runaway chemistry in active macroscopic soil solution, not floating-point relayering slivers where `zone_fraction < 1e-12`. Skipping zones below `1e-12` in `validateAqueousMolarity` and `nitrogen_state_update` faithfully mirrors legacy's physical absence threshold.

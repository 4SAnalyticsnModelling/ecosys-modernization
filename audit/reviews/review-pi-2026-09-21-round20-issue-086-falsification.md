# Adversarial Review Round 20: Falsification Audit of Issue-086 (Hourly Water Slot 4 Semantic Divergence)

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Falsification of Claim in Issue-086 that in the hourly water stream (`fouts.f` / `outsh.f`, $N=22$), slot 4 (`TTL_SWC`) is an extensive total water storage variable (`UVOLW * 1000 / AREA`), whereas `ecosys-ng` erroneously substituted a root water uptake flux (`root_water_uptake[mm]`).

---

### Verdict: NOT FALSIFIED

The editor's claim in Issue-086 is **FULLY CONFIRMED** across all four audit questions:
1. `UVOLW` in legacy Fortran is purely an extensive water storage pool (accumulating snowpack, surface pond/litter, canopy water, and profile soil moisture), containing zero uptake terms.
2. In the legacy Fortran soil water output editor ladder (`fouts.f:159-216`), there is **no root water uptake variable** anywhere in slots 1–50. (Root uptake is reported in the plant output editor `foutp.f:95-123` as `TRANSPN` at slot 55 and `UP_NH4` / `UP_NO3` in the nitrogen stream).
3. The previous project's authoritative audit (`docs/output_semantics_audit_2026-09-10.md`, section **F-10**) explicitly investigated this exact slot and reached the identical verdict:
   > *"Modern hourly water slot 4 is `root_water_uptake`... The legacy slot 4 is `TTL_SWC = UVOLW*1000/AREA`... total profile soil water, 800–1160 mm... the modern hourly water catalog simply assigns a different variable to that legacy slot... the map is right and the catalog is wrong. Classification: `SEMANTIC-DEFINITION` (storage variable replaced by a flux)..."*
4. `ecosys-ng` already computes the exact `UVOLW` analogue in `ecosys_ng.zig:1888-1934` for daily output (`soil_water_storage_m3`), but omitted it from the hourly stream in `ecosys_ng.zig:880-950`.

---

### Detailed Falsification Analysis

#### (1) Is `UVOLW` Really a Storage Term, or Could It Be an Accumulated Uptake?
- **Finding: It is purely a physical water storage pool.**
- **All Assignments to `UVOLW` in `f77src/`**:
  1. `hour1.f:2412`: `UVOLW(NY,NX) = 0.0` (zeroed at the start of the hourly loop).
  2. `redist.f:5475`:
     ```fortran
     DO 9785 L=1,JS
     WS=VOLSSL(L,NY,NX)+VOLWSL(L,NY,NX)+VOLVSL(L,NY,NX)+VOLISL(L,NY,NX)*DENSI
     UVOLW(NY,NX)=UVOLW(NY,NX)+WS
     ```
     (Adds snowpack solid snow, liquid water, vapor, and ice water equivalent across snow layers $L=1..\text{JS}$).
  3. `redist.f:5635`:
     ```fortran
     WSS=VOLW(0,NY,NX)+VOLV(0,NY,NX)+VOLI(0,NY,NX)*DENSI
     WSP=TVOLWC(NY,NX)+TVOLWP(NY,NX)
     UVOLW(NY,NX)=UVOLW(NY,NX)+WSS+WSP
     ```
     (Adds surface litter water/ice/vapor `WSS` plus living and dead canopy intercepted water `WSP`).
  4. `redist.f:6682`:
     ```fortran
     WS=VOLW(L,NY,NX)+VOLV(L,NY,NX)+VOLWH(L,NY,NX)+(VOLI(L,NY,NX)+VOLIH(L,NY,NX))*DENSI
     UVOLW(NY,NX)=UVOLW(NY,NX)+WS
     ```
     (Adds micropore and macropore liquid, vapor, and ice water equivalent across all soil layers $L=\text{NU}..\text{NL}$).
- **Output Expressions**:
  - `outsh.f:121`: `HEAD(M) = UVOLW(NY,NX)*1000.0/AREA(3,NU(NY,NX),NY,NX)`.
  - `outsd.f:117`: `HEAD(M) = 1000.0*UVOLW(NY,NX)/AREA(3,NU(NY,NX),NY,NX)`.
- **Verdict**: There are no other assignments to `UVOLW` anywhere in the codebase. It represents the total liquid + ice + vapor water equivalent currently stored in the snowpack, canopy, surface litter, and soil column (in $\text{m}^3$). Multiplying by $1000 / \text{AREA}$ converts $\text{m}^3\cdot\text{m}^{-2} \to \text{mm}$ of total water storage. It has no connection to root water uptake.

#### (2) Is There a Root Water Uptake Slot Anywhere in the Legacy Water Editor?
- **Finding: NO.**
- Full ladder of `f77src/fouts.f:159-216` ($N=22$, hourly water):
  - Slot 1: `EVAPN` (`TEVPGH * 1000 / AREA`)
  - Slot 2: `RUNOFF` (`-WQRH * 1000 / TAREA`)
  - Slot 3: `SEDIMENT` (`USEDOU * 1000 / TAREA`)
  - Slot 4: `TTL_SWC` (`UVOLW * 1000 / AREA`)
  - Slot 5: `DISCHG` (`HVOLO * 1000 / TAREA`)
  - Slot 6: `SNOWPACK` (`(VOLSS + VOLIS*DENSI + VOLWS) * 1000 / AREA`)
  - Slots 7–26: `WTR_1` .. `WTR_20` (`THETWZ(L)`, layer volumetric liquid water content)
  - Slot 27: `SURF_WTR` (`VOLW(0) / AREA`)
  - Slots 28–47: `ICE_1` .. `ICE_20` (`THETIZ(L)`, layer volumetric ice content)
  - Slot 48: `SURF_ICE` (`VOLI(0) / AREA`)
  - Slot 49: `ACTV_LYR` (`CDPTHZ(NL) - DPTHA`)
  - Slot 50: `WTR_TBL` (`CDPTHZ(NL) - DPTHT`)
- Root water uptake does not appear in `fouts.f` at all.

#### (3) Does Any Comment in `ecosys-ng` Justify Slot 4 as an Approved Replacement?
- **Finding: NO justification exists. It is an acknowledged defect.**
- In the predecessor project reference document (`C:\Users\symon.mezbahuddin\OneDrive - Government of Alberta\ProjectsSymon\ecosys_modernization\ecosys-ng\docs\output_semantics_audit_2026-09-10.md`), section **F-10** (lines 350–367):
  - The audit explicitly notes:
    *"Modern hourly water slot 4 is `root_water_uptake` (`src/soil/diagnostics/output_catalog.zig:21`), value 0.0 in all 2125 hours... The legacy slot 4 is `TTL_SWC` = `UVOLW*1000/AREA` (`outsh.f:121`, `fouts.f:166`), total profile soil water, 800–1160 mm... the modern hourly water catalog simply assigns a different variable to that legacy slot. The comparator map already refuses to bridge it... the map is right and the catalog is wrong... Classification: `SEMANTIC-DEFINITION` (storage variable replaced by a flux)..."*
  - In section 8 (`output_semantics_audit_2026-09-10.md:800`), it records:
    *"TTL_SWC — leave unmapped but change the note... It was never an approved feature; it was a semantic substitution error."*

#### (4) Does `ecosys-ng` Publish a Total-Soil-Water Accumulator Anywhere?
- **Finding: YES, in `ecosys_ng.zig:1888-1934`.**
- For daily output (`daily_soil_water_bank`), `ecosys_ng.zig:1888-1934` calculates `soil_water_storage_m3`:
  ```zig
  var soil_water_storage_m3: f64 = 0;
  for (0..driver_context.config.*.soil_layers) |local_layer| {
      soil_water_storage_m3 += driver_context.state.*.liquid_water_m3[layer] +
          driver_context.state.*.water_vapor_volume_m3[layer] +
          driver_context.state.*.ice_water_m3[layer];
  }
  // Adds snowpack:
  for (0..driver_context.snow_transport_state.*.layer_capacity) |snow_layer| {
      soil_water_storage_m3 += driver_context.snow_transport_state.*.solid_snow_water_equivalent_m3[snow] + ...;
  }
  // Adds surface litter and canopy intercepted water:
  soil_water_storage_m3 += driver_context.surface_precipitation_state.*.litter_water_m3[cell] + ...;
  ```
  And writes it via `soil/diagnostics/daily_output.zig:365`:
  `1000.0 * inputs.soil_water_storage_m3 / inputs.cell_area_m2`.
- In `ecosys_ng.zig:880-950` (the hourly water writer), this accumulation was simply not performed; instead, `root_water_uptake_m3` was computed from `roots.water_uptake_m3_per_h` and passed to `soil_water_output.calculateInto`.
- Therefore, the calculation of total soil water equivalent already exists and is fully implemented in the daily pipeline. Porting it to the hourly pipeline in `ecosys_ng.zig:880-950` and updating `soil/water/output.zig` and `soil/diagnostics/output_catalog.zig:21` is a direct, straightforward change.

---

### Conclusion

The claim in Issue-086 cannot be falsified. The legacy slot 4 is unambiguously total water storage (`TTL_SWC`), not root water uptake. The predecessor repository's own audit log (`output_semantics_audit_2026-09-10.md:350-367`) confirms this was an inadvertent semantic misbinding (`F-10`), and that the required calculation already exists in `ecosys-ng`'s daily water routine.

# Adversarial Review: Round 00016 — Freeze-Thaw Relayering Transfer Gate (Commit 627634a)

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target Commit**: `627634a` (`soil/profile/relayering.zig`)  
**Legacy Reference**: `f77src/redist.f:7749-7750, 8059-8088, 8132, 8186-8205`  
**Modern References**: `ecosys-ng/src/soil/profile/layer_geometry.zig:90-129`, `ecosys-ng/src/soil/profile/relayering.zig:255-275, 1095-1103`, `ecosys-ng/src/soil/profile/geometry_disturbance_transaction.zig:149-163`

---

### 1. Verification of the IFLGK Translation

1. **Direction and Meaning in Legacy**:
   In `f77src/redist.f:7735-7750`, the loop scans from the bottom of the profile upward:
   ```fortran
   DO 225 LX = NL(NY,NX), NU(NY,NX), -1
   ...
   IF (BKDS(LX,NY,NX) .LE. ZERO) IFLGJ = 1
   ...
   IFLGK(LX) = IFLGJ
   ```
   Because `LX` descends from `NL` down to `NU`, `IFLGJ = 1` latches on as soon as any encountered layer has `BKDS <= 0`. Thus, for any layer $L$, `IFLGK(L) == 1` if layer $L$ or **any layer deeper than $L$** ($LX \ge L$) is a pond/water layer (`BKDS <= 0`).
   At line 8194:
   ```fortran
   IF (BKDS(L,NY,NX) .GT. ZERO .AND. IFLGK(L) .EQ. 1) THEN
       DDLYRX(NN) = CDPTH(L,NY,NX) - CDPTHX(L,NY,NX)
   ENDIF
   ```
   Commit `627634a`'s helper (`relayering.zig:1097-1103`):
   ```zig
   for (layer..first + active) |deeper|
       if (props.bulk_density_megagrams_per_m3[cell * cap + deeper] <= 0) return true;
   ```
   scans from `layer` to `first + active - 1` (deeper layers). The scan direction and inclusive condition `deeper >= layer` is a **100% exact match** to legacy `IFLGK`.

2. **Does `ecosys-ng` ever have `BKDS <= 0` in the soil grid?**:
   No. In `ecosys-ng`, ponding is tracked in the separate surface/pond domain (`surface/pond_domain_transaction.zig`), while `grid` represents the active porous mineral/organic soil profile where `bulk_density_megagrams_per_m3` is strictly positive ($\ge 0.05\text{ Mg/m}^3$). Therefore, `freezeThawDrivesTransfer` correctly returns `false` across all standard soil profiles, preventing unphysical frost-heave/thaw-settlement mass cascades down the column.

**Verdict: ACCEPT**

---

### 2. Thirty-Year Geometry Invariance, Freeze/Thaw Drift, and Minimum Thickness

1. **Absence of DDLYRY**:
   In legacy `redist.f:8188-8201`, `DDLYRY(L) = DLYRI - DLYR1` attempted to pull the physical layer thickness back toward initial thickness $DLYRI$ during relayering. In `ecosys-ng`, geometry disturbances are decoupled into distinct physical vectors: `pond_m`, `freeze_thaw_m`, `erosion_m`, and `organic_carbon_m` (`layer_geometry.zig:95-106`).
2. **Dual Representation (`boundary_depth_m` vs `boundary_depth_without_freeze_m`)**:
   In `layer_geometry.zig:104-105`:
   - `staged_boundary_depth_m` adds all 4 disturbances (including `freeze_thaw_m`).
   - `staged_boundary_depth_without_freeze_m` tracks only irreversible/long-term disturbances (`pond + erosion + carbon`), completely excluding `freeze_thaw_m`.
   - In `layer_geometry.zig:128,166`, `validateDisturbances` asserts:
     $$\Delta z_{\text{freeze}} \ge z_{min} \quad \text{AND} \quad \Delta z_{\text{without\_freeze}} \ge z_{min}$$
   Since `ice_volume_delta_m3` in `hourly_heat_water_solute.zig:13738` integrates seasonal $\Delta \text{ice}$, complete thaw returns $\Delta \text{ice} \to 0$, causing `freeze_thaw_boundary_change_m` to return to zero. The underlying soil mineral geometry rests on `boundary_depth_without_freeze_m`, which cannot drift from freeze-thaw cycles over 30 years.

**Verdict: ACCEPT**

---

### 3. Downstream Consumers of `freeze_thaw_m`

- **Solute / Gas / Microbial Remaps**: In `relayering.zig:255-300`, all material transfers (water, heat, gas, OM, mineral nutrients) are parameterized solely by `ddlyrx`. By removing `freeze_thaw_m` from `ddlyrx` when `freezeThawDrivesTransfer == false`, all species remain strictly stationary with respect to phase-expansion boundary displacement.
- **Surface / Pond Transactions & Checkpointing**: `surface/pond_domain_transaction.zig:259` explicitly passes `zero_boundary_change_m` for freeze-thaw. Checkpoints (`soil_geometry_checkpoint.zig:471`) store both boundary vectors explicitly. No downstream module assumes extensive mass migration with seasonal ice expansion.

**Verdict: ACCEPT**

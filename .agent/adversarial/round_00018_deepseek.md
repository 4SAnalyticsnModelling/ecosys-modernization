# Adversarial Review: Round 00018 — Relayering SOC-Leg Restore & Freeze-Thaw Asymmetry

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**:  
1. `hourly_geometry_disturbance.zig:298-322`: Passing `thickness_without_freeze_m` as `current_layer_thickness_m` to `applyEndOfHourGeometry`.  
2. Root cause of layer 1 +60% volume expansion at hour 3918: DVOLI capture symmetry and ice dynamics.  
**Legacy Reference**: `f77src/redist.f:5965-5970, 7835-7975, 8186-8205`  
**Modern References**: `ecosys-ng/src/soil/profile/geometry_change_assembly.zig:155-185`, `ecosys-ng/src/stages/hourly_geometry_disturbance.zig:289-325`, `ecosys-ng/src/stages/hourly_heat_water_solute.zig:13735-13745`

---

### 1. Verification of Freeze-Free Thickness in SOC Relayering (`geometry_change_assembly.zig:170`)

1. **Legacy Equivalence**:  
   In `f77src/redist.f:7910-7911`:
   $$DDLYR(LX,4) = DDLYX(LX+1,4) + DLYRI(3,LX) - DLYR(3,LX)$$
   In legacy Fortran, $DLYR(3,LX)$ is reset every hour back toward $DLYRI$ via $DDLYRY$ (lines 8188/8199). In modern Zig, elastic freeze-thaw heave/settlement is accumulated inside `geometry.boundary_depth_m` and reflected in `geometry.layer_thickness_m`. If `geometry.layer_thickness_m` is passed to the SOC leg, any seasonal freeze-thaw dilation is treated as an organic-carbon geometry error and converted into permanent Eulerian soil mass transfer ($FX$).  
   Using `thickness_without_freeze_m` ($bnd_{without\_freeze}[l+1] - bnd_{without\_freeze}[l]$) isolates the long-term inelastic soil thickness ($DLYRI + \Delta z_{pond} + \Delta z_{erosion} + \Delta z_{SOC}$). This is **mathematically exact** to legacy's intent of isolating $DLYRI - DLYR$.

2. **Branch Interactions & Edge Cases**:
   - **Erosion leg (`7842-7858`)**: Erosion shifts boundaries via `TSEDER`; it does not have a feedback restore term $DLYRI - DLYR$. It only alters $bnd_{without\_freeze}$, which is cleanly tracked.
   - **Reset branch (`reset_organic_accumulation_by_layer`)**: Line 167 sets `bottom_boundary_change_m = 0`, bypassing the restore term entirely when a fresh organic horizon forms.
   - **Top boundary carry (line 183)**: Carries the net column surface displacement, which is decoupled from inter-layer thickness restoration.

**Verdict: ACCEPT**

---

### 2. Diagnosis of Layer-1 +60% Volume Growth at Hour 3918

1. **Is it June Ice or Heave Residual?**  
   At hour 3918 (June 1998, $T > 295\text{ K}$), liquid soil temperatures preclude real ice. The +60% volume expansion in layer 1 is a **frozen-in geometric residual** caused by an asymmetry in `ice_volume_delta_m3`.

2. **The Asymmetry in `ice_volume_delta_m3` Capture (`hourly_heat_water_solute.zig:13738-13741`)**:
   ```zig
   ws.ice_volume_delta_m3[l] =
       -accepted_soil_water_heat.grid_delta_by_layer_carrier[l * carrier_count + 7] /
       context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3;
   ```
   - Carrier `7` is **`grid.matrix_ice_water_m3` ONLY** (`liveGridStateSlice:1005`).
   - Carrier `8` is **`grid.macropore_ice_water_m3`** (`liveGridStateSlice:1006`).
   - Legacy `redist.f:5965-5966` tracks total ice change:
     $$DVOLI(L) = (VOLI1 + VOLIH1) - (VOLI + VOLIH)$$
     which includes **both matrix ice ($VOLI$) and macropore ice ($VOLIH$)**.
   - Furthermore, when snowmelt infiltrates into subfreezing soil, macropore water freezes into macropore ice. When thawing occurs, ice melts into matrix water or drains. Because carrier `7` captures only matrix ice, **freezing of infiltrated macropore water or ice phase displacement across macropores is completely omitted from the heave ledger**, but its melting/thaw in the matrix is counted!
   - This creates a **systematic non-zero seasonal net integral**:
     $$\oint \Delta \text{ice}_{matrix} \, dt \ne 0$$
     leaving an unreversed cumulative displacement in `geometry.boundary_depth_m` that permanently inflates layer 1.

**Fix**: Change carrier delta in `hourly_heat_water_solute.zig:13739` to carrier `9` (`grid.ice_water_m3`, which is matrix + macropore ice) or sum carriers `7` and `8`.

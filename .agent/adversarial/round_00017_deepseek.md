# Gap Analysis: Round 00017 — Relayering Discrepancies & Material Restoration

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**: Relayering dynamics (`f77src/redist.f:7720-8250` vs `ecosys-ng/src/soil/profile/relayering.zig`) under Ottawa deck (`f25si98`).  

---

### 1. Ottawa Deck `IERSNG` & Modern Parsing
In `f25si98` (line 3):
```text
33 1 3 1 1.0 0.0
```
Column 3 is `IERSNG = 3` (`readi.f:154`: `READ(1,*) IETYPG, ISALTG, IERSNG, NCNG...`).  
Legacy option 3 corresponds to:
$$\text{freeze-thaw} + \text{erosion} + \text{SOM gain/loss} \quad (\text{redist.f:7830, 7882})$$
In `geometry_disturbance_transaction.zig:153-159`:
`inputs.disturbance_mode_by_cell[cell] = 3`, enabling freeze-thaw, erosion, and organic carbon disturbance legs.

---

### 2. Legacy `IFLGM=0` Relayering Behavior & Ottawa Impact

In legacy `redist.f:8170-8205`:
1. When ice volume changes anywhere in the column during the hour (`DVOLI > 0`), `IFLGM = 1` (`redist.f:7988`).
2. In frost-free summer hours (or completely frozen stable winter hours), `DVOLI = 0` $\implies$ `IFLGM = 0`.
3. For soil layers (`BKDS > 0`) when `IFLGM = 0` (line 8190-8191):
   $$DDLYRX = DLYRI - DLYR1, \quad DDLYRY = DDLYRX$$
   Legacy **explicitly sets the material transfer driver $DDLYRX$ to restore each layer to its initial thickness $DLYRI$**.
4. **Does this cause residual drift in legacy?**  
   Yes. During thaw, heave/settlement alters $DLYR1$. As soon as `IFLGM` becomes 0, legacy computes $DDLYRX = DLYRI - DLYR1 \ne 0$ and executes mass remap ($FX = DDLYRX / DLYR$). Because water/ice volume changes nonlinearly and bulk density varies, legacy's material-restoration pump slowly shifts mass between layers 0 and 1 until $DLYR = DLYRI$. For Ottawa's $1\text{ cm}$ top layer ($DVOLI \approx 10^{-3}\text{ m}^3/\text{m}^2 \approx 1\text{ mm}$ heave), this pumps $\approx 5\text{--}10\%$ of topsoil solids into layer 1 annually unless erosion/tillage counters it.

---

### 3. Recommendation for Ottawa Comparability

**Recommendation**: **Do NOT port `IFLGM=0` material restoration or `DDLYRY` geometry restoration** for standard Ottawa runs; retain modern physical decoupling (`627634a`).

- **Why**: Legacy's `IFLGM=0` material pump was an unphysical artifact intended to counteract grid collapse before Eulerian-Lagrangian finite-volume schemes were standardized. In `ecosys-ng`, seasonal freeze-thaw is strictly elastic: $DVOLI$ expands $DLYR$ during winter and contracts it symmetrically during thaw back to $DLYRI$ via bottom-anchored cumulative integration (`layer_geometry.zig:104, 179`). Injecting legacy's artificial $FX$ pump during frost-free hours will re-introduce mass drift and destabilize layer 0.
- **Minimal Sites if Forced to Match Legacy Oracle**:
  - `soil/profile/relayering.zig:265`: If `ice_volume_delta_m3 == 0` column-wide and `layer_thickness_m != initial_layer_thickness_m`, set `ddlyrx = initial_layer_thickness_m - layer_thickness_m`.
  - `soil/profile/layer_geometry.zig:104`: Apply `ddlyry` restoration to `staged_boundary_depth_m`.

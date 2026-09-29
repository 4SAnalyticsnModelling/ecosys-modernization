# Adversarial Review & Challenge: Round 00019 — Ponded Water Retention vs Legacy NN=3

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**: `selectSeparatedSurfacePondTransfer` gate (`redistribution/pond/layer_transition.zig:100-125`), `hourly_sediment.zig:816-828`, `surface/runoff.zig:280-344`.  
**Legacy Sources**: `f77src/redist.f:7740-7755, 8260-8345`, `f77src/readi.f:120-125, 155`, `f77src/watsub.f:939-955, 3440-3450`  

---

### 1. Challenge & Verification: NN=3 Invariant (`f77src/redist.f:8306-8340`)

1. **Legacy Flow & Logic**:
   In `redist.f:8308-8318`:
   ```fortran
   ELSEIF(NN.EQ.3) THEN
     XVOLWP = AMAX1(0.0, VOLW(0,NY,NX) + VOLI(0,NY,NX) - VOLWD(NY,NX))
     IF (L.EQ.NU(NY,NX) .AND. CDPTH(0,NY,NX).GT.CDPTHI(NY,NX)
    2 .AND. XVOLWP.GT.VHCPNX(NY,NX)/4.19) THEN
       IF (BKDS(L,NY,NX).GT.ZERO .AND. NU(NY,NX).GT.NUI(NY,NX)) THEN
         DDLYRX(NN) = (-XVOLWP)/AREA(3,0,NY,NX)
         NU(NY,NX)  = NUI(NY,NX)
         ...
         DLYR(3,NU,NY,NX) = DLYR(3,NU,NY,NX) - DDLYRX(NN)
       ELSE
         DDLYRX(NN) = 0.0
       ENDIF
     ELSE
       DDLYRX(NN) = 0.0
     ENDIF
   ```
   - **Verification**: `DDLYRX(3)` is non-zero **only** when `BKDS(L) > 0 .AND. NU(NY,NX) > NUI(NY,NX)`.
   - `NU > NUI` occurs solely if an earlier $NN=2$ event (`redist.f:8260-8290`) evaporated an ephemeral surface pond layer and incremented `NU`. $NN=3$ is the **reappearance** of that dry pond layer over the mineral profile (`"RESET POND SURFACE LAYER NUMBER IF POND REAPPEARS"`).
   - In a standard mineral soil profile (`BKDS > 0`), `NU == NUI == 1` holds perpetually.
   - **Alternative routes?**: None. Neither $NN=1, 4, 5$ nor any other routine in legacy Fortran pushes excess ponded surface water ($XVOLWP > VOLWD$) into mineral layer `NU` as solid/layer expansion.

**Verdict on Question 1: ACCEPT** — CLAUDE's reading is 100% correct.

---

### 2. Fate of Ponded Water > VOLWD in Single-Cell Ottawa Deck

1. **Where does ponded water go?**:
   - In `ecosys-ng`, excess ponded water remains on the surface (`litter_water_m3`), where it is governed by **Manning overland runoff** in `surface_runoff.routeWithSurfaceBoundary` (`surface/runoff.zig:289-342`, invoked in `stages/hourly_gas_surface_water.zig:483-512`).
   - `excess_total = water + ice - ground_retention`. In `f25si98` (line 4):
     `0.0 1.0 1.0 0.0 10.0 ...` specifies runoff boundary flags `RCHQN=0, RCHQE=1, RCHQS=1, RCHQW=0` (`readi.f:155, 199-202`).
   - Line 5 sets `slope = 1.5%` ($0.015\text{ m/m}$).
2. **Domain Export**:
   - In `surface/runoff.zig:338-341`, on a single-cell grid ($columns = 1, rows = 1$):
     ```zig
     if (column + 1 < columns) ... else state.exported_water_m3[source] += fluxes[0]; // East
     if (row + 1 < rows) ... else state.exported_water_m3[source] += fluxes[2];       // South
     ```
   - Water exceeding retention ($VOLWD$) flows down the 1.5% slope toward the unimpeded East and South boundaries (`boundary_fraction = 1.0`) and is exported directly to `exported_water_m3` (surface runoff).
   - Surface water **will not accumulate unboundedly**; it discharges cleanly as overland runoff at the boundary.

**Verdict on Question 2: ACCEPT**

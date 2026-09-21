# Adversarial Review Round 6: Tillage Pore-Deficit Resolution (Design A vs Design B)

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Adversarial evaluation of Design A (one-shot upward cascade post-tillage) vs Design B (guard domain correction permitting transient pore deficit).

---

### D1. Preferred Design & Strongest Counterargument
**PICK: DESIGN A (Narrow, Post-Tillage Upward Relief Cascade).**
- **Strongest Counterargument Against Design A**: It creates an artificial, instantaneous pulse of hydraulic head in shallower layers that bypasses the Darcy solver. By moving the full ~8.6e-4 m³ in a single step instead of over ~12 substeps (`XNPHX`), it can shock surface water potentials, transiently distorting boundary evaporation and infiltration for the next hour.
- **Why Not Design B**: Design B touches `runtime_material_refresh.zig:245-264`, which is a global gate across every hour and process. Carrying negative pore space across hour boundaries requires checkpoint/restart schema changes, alters restart reproducibility, and risks masking real non-disturbance overfill bugs elsewhere.

### D2. Material Failure State for Design A
**YES, RISK EXISTS AT THE LITTER/SOIL BOUNDARY:**
- In legacy, layer 1 (`NUM(NY,NX)`) excess drains to the surface via `watsub.f:3680-3687` into pond/surface water (`FLQR`), which can then evaporate or run off.
- If Design A cascades water from layer 1 into layer 0 (litter), and litter has negligible pore capacity (or is saturated), a naive one-shot cascade will simply fail or overfill layer 0 instead.
- If you stop the cascade at layer 0 and error out, or if layer 0 cannot take the water, Design A fails.

### D3. Refusing a Surface Sink vs Moving the Frontier
**REFUSING A SURFACE SINK WILL LIKELY MOVE THE FRONTIER:**
- In the Ottawa deck, tillage at hour 3,252 occurs in spring. If layer 0 and layer 1 are already wet, cascading ~8.6e-4 m³ upward from layer 1 into layer 0 will exceed layer 0's capacity unless layer 0 has sufficient air space.
- Legacy explicitly provides the surface release at `watsub.f:3680-3687`:
  `FLQR = FLQR + AMIN1(0.0, AMAX1(-VOLW1N*XNPZX, VOLP1ZN))`
  pushing unabsorbable excess directly into surface ponding. If Design A refuses this legacy surface sink, it will fail loudly as soon as the topsoil profile is near saturation.

### D4. Contractual Status of Design B
**DESIGN B IS LEGITIMATE UNDER THE CONTRACT, BUT PRONE TO MASKING:**
- `PROJECT_CONTRACT.md` allows domain corrections when grounded in legacy Fortran. Because Fortran's `VOLP1Z < 0` routinely crosses hour boundaries (governed by `redist.f:12180` and `watsub.f:211`), treating pore deficit as a valid non-fatal state is technically a **domain correction**, not an arbitrary loosening.
- **However**, in practice it functions as an erosion of a structural safety invariant: Zig's design explicitly intended to enforce strict per-hour pore feasibility. Loosening it creates a permanent loophole where any solver flaw causing liquid expansion could escape detection.

### Recommendation
Proceed with **Design A**, but ensure the cascade checks available air capacity in layer 0. If layer 0 is saturated, allow routing to surface water storage (mirroring `watsub.f:3684`) rather than erroring out.

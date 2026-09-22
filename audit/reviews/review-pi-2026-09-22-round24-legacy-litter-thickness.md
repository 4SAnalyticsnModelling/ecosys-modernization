# Adversarial Review Round 24: Legacy Surface Litter Thickness (`DLYR(3,0)`) Audit

Date: 2026-09-22  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Exhaustive source audit of how legacy Fortran 77 computes surface litter thickness `DLYR(3,0,NY,NX)` across `starts.f`, `hour1.f`, and `redist.f`.

---

### Key Verdict on Question (4)

**YES, surface litter thickness in legacy Fortran directly depends on litter WATER content (liquid `VOLW` and ice `VOLI`).**

Specifically, whenever the litter water plus ice volume exceeds the litter water retention holding capacity `VOLWRX(NY,NX)`, the excess water/ice swells the litter volume and expands `DLYR(3,0,NY,NX)` linearly above its dry structural thickness:
$$\text{DLYR}(3,0,\text{NY},\text{NX}) = \frac{\text{VOLR}(\text{NY},\text{NX}) + \max(0.0, \text{VOLW}(0,\text{NY},\text{NX}) + \text{VOLI}(0,\text{NY},\text{NX}) - \text{VOLWRX}(\text{NY},\text{NX}))}{\text{AREA}(3,0,\text{NY},\text{NX})}$$

Therefore, the $0.027\text{ m}$ litter thickness difference between `ecosys-ng` and the legacy oracle is **directly coupled to the surface water/ice divergence** (`VOLW(0) + VOLI(0)`), rather than being an independent static geometry defect.

---

### Detailed Findings

#### (1) Where `DLYR(3,0,NY,NX)` is Assigned
There are four distinct assignment locations in `f77src/`:

1. **`starts.f:566` (Cold Initialization)**:
   ```fortran
   DLYRI(3,L,NY,NX) = VOLX(L,NY,NX)/AREA(3,L,NY,NX)
   DLYR(3,L,NY,NX) = DLYRI(3,L,NY,NX)
   ```
   (where for $L=0$, `VOLX(0)` was initialized at `starts.f:561` as `VOLR(NY,NX)`, the dry litter volume).

2. **`hour1.f:4382` (Active Hourly Surface Residue Update)**:
   ```fortran
   DLYR(3,0,NY,NX) = VOLX(0,NY,NX)/AREA(3,0,NY,NX)
   ```
   Enclosed in the active litter branch `IF(VOLT(0,NY,NX).GT.ZEROS(NY,NX))` at `hour1.f:4357`, executed **every hour**.

3. **`hour1.f:4537` and `:4542` (Inactive/Absent Surface Residue Branch)**:
   ```fortran
   DLYR(3,0,NY,NX) = 0.0
   ...
   DLYR(3,0,NY,NX) = VOLX(0,NY,NX)/AREA(3,0,NY,NX)
   ```
   Enclosed in the `ELSE` branch at `hour1.f:4526` (when `VOLT(0,NY,NX) <= ZEROS`), ensuring thickness is $0.0$ when no litter exists.

4. **`redist.f:8317` (Relayering When Pond Surface Layer Reappears)**:
   ```fortran
   DLYR0 = (AMAX1(0.0,VOLW(0,NY,NX)+VOLI(0,NY,NX)-VOLWRX(NY,NX)) + VOLR(NY,NX))/AREA(3,0,NY,NX)
   DLYR(3,0,NY,NX) = DLYR0 + DDLYRX(NN)
   ```
   Inside the relayering loop `DO 230 NN=1,5` at `NN=3` (ponding/surface relayering).

---

#### (2) What `DLYR(3,0)` is a Function Of

From `hour1.f:4350-4382`:
1. **Dry Structural Litter Volume (`VOLR`)**:
   `hour1.f:4354-4355`:
   $$\text{VOLR}(\text{NY},\text{NX}) = 1.0\times 10^{-6} \sum_{K \in \{0,1,2,4\}} \frac{\text{RC0}(K,\text{NY},\text{NX})}{\text{BKRS}(K)}$$
   - `RC0(K,NY,NX)`: Surface residue carbon mass (g C) for coarse woody ($K=0$), fine woody/straw ($K=1$), manure ($K=2$), and charcoal ($K=4$).
   - `BKRS`: Bulk density of residue types ($\text{Mg C}\cdot\text{m}^{-3}$): `DATA BKRS /0.100, 0.0125, 0.025, 0.025, 0.025/` (`starts.f:76`).
2. **Water Retention Holding Capacity (`VOLWRX`)**:
   `hour1.f:4350-4352`:
   $$\text{VOLWRX}(\text{NY},\text{NX}) = \sum_{K \in \{0,1,2,4\}} \text{THETRX}(K) \times \text{RC0}(K,\text{NY},\text{NX})$$
   - `THETRX`: Specific water holding capacity ($\text{m}^3\text{ water}\cdot(\text{g C})^{-1}$): `DATA THETRX /2.0E-06, 5.0E-06, 5.0E-06, 5.0E-06, 5.0E-06/` (`hour1.f:128`).
3. **Excess Ponded / Swollen Liquid and Ice Water (`TVOLG0`)**:
   `hour1.f:4353`:
   $$\text{TVOLG0} = \max(0.0, \text{VOLW}(0,\text{NY},\text{NX}) + \text{VOLI}(0,\text{NY},\text{NX}) - \text{VOLWRX}(\text{NY},\text{NX}))$$
   - `VOLW(0,NY,NX)`: Liquid water content in surface litter layer ($\text{m}^3$).
   - `VOLI(0,NY,NX)`: Ice content in surface litter layer ($\text{m}^3$).
4. **Total Expanded Litter Volume (`VOLT` / `VOLX`)**:
   `hour1.f:4356-4358`:
   $$\text{VOLT}(0,\text{NY},\text{NX}) = \text{TVOLG0} + \text{VOLR}(\text{NY},\text{NX})$$
   $$\text{VOLX}(0,\text{NY},\text{NX}) = \text{VOLT}(0,\text{NY},\text{NX})$$
5. **Horizontal Cell Area (`AREA(3,0)`)**:
   `hour1.f:4382`:
   $$\text{DLYR}(3,0,\text{NY},\text{NX}) = \frac{\text{VOLX}(0,\text{NY},\text{NX})}{\text{AREA}(3,0,\text{NY},\text{NX})}$$

---

#### (3) Recomputation Frequency
- **Recomputed Every Single Hour.**
- In `f77src/hour1.f`, the assignment at line 4382 is inside the primary grid cell loop:
  `DO 9990 NY=1,JY` (depth 1), which runs every hour $J=1..24$ of every day $I=1..365$.
- It is also dynamically adjusted during relayering in `redist.f:8317` when ponding states shift.

---

#### (4) Does It Depend on Litter Water Content?
**YES, unequivocally.**
- When $\text{VOLW}(0) + \text{VOLI}(0) > \text{VOLWRX}$, the term:
  $$\text{TVOLG0} = \text{VOLW}(0) + \text{VOLI}(0) - \text{VOLWRX}$$
  is strictly positive and adds directly to `VOLT(0) = TVOLG0 + VOLR`.
- Dividing by `AREA(3,0)` increases `DLYR(3,0)` by:
  $$\Delta \text{DLYR} = \frac{\text{VOLW}(0) + \text{VOLI}(0) - \text{VOLWRX}}{\text{AREA}(3,0)}$$
- If `ecosys-ng` has higher retained surface water or ice (e.g. from the snowpack drainage lag or surface retention differences), `TVOLG0` will be larger, which directly inflates `DLYR(3,0)` by that exact volume difference divided by area.
- Therefore, the $0.027\text{ m}$ ($27\text{ mm}$) litter thickness discrepancy is a **downstream physical consequence of the surface water/ice balance divergence**, not an erroneous uncoupled parameter.

---

## Lead editor response (2026-09-22)

**Accepted, and it independently corroborates the conclusion I reached from the other direction.**

Pi answers round 24's question (4) -- does litter thickness depend on litter water? -- with a
source audit, and its verdict matches what commit `933c2ac` and `issue-094` established from
the output side. I traced the formula as a faithful port and then found the `SURF_ELEV` error
was `<=1e-3` through day 12 before **jumping at days 68 and 90**, the snowmelt window, which
is only explicable through the excess-water term Pi identifies. Two independent routes, same
answer. That mattered because it is what refuted `issue-093`'s strong form: I had predicted
the difference was carbon-dominated (~670 g C m-2 of spurious pool-4 carbon) and it is not --
it is water-dominated.

**Two findings here are new to my record and are carried forward:**

1. **`DLYR(3,0)` has FOUR assignment sites, not two.** I had `hour1.f:4382` and
   `redist.f:8317`. Pi adds `starts.f:566` (cold initialization from the dry `VOLR`) and
   `hour1.f:4537`/`:4542` -- the **inactive-litter `ELSE` branch** at `:4526`, which sets
   thickness to `0.0` when `VOLT(0) <= ZEROS`. That branch is worth having: it is the legacy's
   own handling of a vanished litter layer, and `issue-089`'s tillage residue incorporation
   (which empties the litter 1000x) can plausibly reach it.
2. Explicit confirmation that the update runs **every hour** inside `DO 9990 NY`, plus
   dynamically during `redist.f`'s relayering.

**One correction.** Pi labels `RC0(4)` as "charcoal". The substrate legend is `K=0` woody,
`K=1` non-woody, `K=2` manure, `K=3` POC, **`K=4` humus** -- stated at `erosion.f:649-650`,
`redist.f:3010` and `nitro.f:2716`. Charcoal is the **fifth structural fraction** `OSC(M=5)`,
a different axis (`organic/initialization.zig:8-10` records the same). The conclusion is
unaffected, since the pool set `{0,1,2,4}` and the arithmetic are right either way.

**Where this leaves the cluster**: `issue-094` supersedes the litter-thickness line of enquiry.
Thickness, `WTR_1`, `SNOWPACK`, the `ICE_k` gradient and `PSI_SURF` are five readouts of one
defect -- subsurface water export near zero -- whose mechanism is recorded in `issue-096`.

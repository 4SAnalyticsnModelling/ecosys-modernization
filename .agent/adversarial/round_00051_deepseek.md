# Round 00051: Legacy Treatment of a ~1e-14 NH4 Band Zone Sliver

Legacy processes evaluated for a band zone sliver where VLNHB ~ 1e-14 > ZERO (1e-15) but VOLW * VLNHB << ZEROS2 (1e-6 * area):

## (1) TRNSFR Diffusive Exchange (Band <-> Non-Band)
- **Diffusive Mixing**: In `f77src/hour1.f:4908-4960`, band <-> non-band mixing occurs **only via physical band expansion** (DWNH4 = 0.5*sqrt(D*tau)*dt), changing VLNHB. Solute dilution is updated with geometry; no explicit Fickian aqueous diffusion flux array exists between band and non-band within a layer.
- **Inter-layer Transport Gate (`f77src/trnsfr.f:4323, 4438`)**:
  Vertical diffusion between layers is gated by `AMIN1(VLNHB(N3), VLNHB(N6))`.
  All advective and diffusive band fluxes are strictly clamped by available mass: `RN4FLB <= ZNH4B2(N3)`. The 1e-14 area factor scales flux down to <= 1e-20 g N, guaranteeing zero unphysical loss.

## (2) NITRO Nitrification & Microbial Uptake
- **Gate (`f77src/nitro.f:1156, 1164-1165, 2108`)**:
  ```fortran
  VMXB = FNHBS(L,NY,NX) * VMXX / (1.0 + CNH3B(L,NY,NX)/VHKI)
  RNNHB = AMAX1(0.0, AMIN1(VMX4B, FNB4 * ZNH4B(L,NY,NX) * XNFH)) * ZNFN4B
  RINB4 = AMIN1(FNB4X * AMAX1(0.0, (ZNH4B(L,NY,NX) - ZNHBM) * XNFH), ...)
  ```
- **Status & Bounding**: **NOT SKIPPED**, but rigorously bounded. While CNH4B is large, velocity VMXB is scaled by FNHBS = ZNH4B / ZNH4T << 1e-6, and RNNHB is clamped by available mass ZNH4B ~ 6.5e-9 g N. Flux cannot exceed available mass.

## (3) UPTAKE Root NH4 Uptake
- **Gate (`f77src/uptake.f:3043, 3095-3098`)**:
  ```fortran
  IF(FNHBS(L,NY,NX).GT.ZERO .AND. CNH4B(L,NY,NX).GT.UPMNZH(...)) THEN
  ZNHBX = AMAX1(0.0, FNHBX * (ZNH4B(L,NY,NX) - ZNHBM) * XNFH)
  RUPNHB(N,L,NZ,NY,NX) = AMIN1(ZNHBX, RUNNBP(...))
  ```
- **Status & Bounding**: **NOT SKIPPED**, but clamped by ZNHBX <= ZNH4B. Root uptake can never draw more than the available sliver inventory.

## (4) SOLUTE Speciation & Volatilization
- **Speciation Gate (`f77src/solute.f:397, 1479, 3574`)**:
  `IF(VOLWNB.GT.ZEROS2(NY,NX)) THEN ... ELSE CN4B = 0.0; CN3B = 0.0; RNHB = 0.0`
  `VOLWNB = VOLW * VLNHB`. Since VOLWNB ~ 1e-15 << ZEROS2 (1e-6), band speciation is **EXPLICITLY SKIPPED** (RNHB = 0).
- **Volatilization Gate (`f77src/trnsfr.f:3820, 5574`)**:
  `IF(VOLPMB(N6,...).GT.ZEROS2 .AND. VOLWXB(N6,...).GT.ZEROS2) THEN ... ELSE RNBDFG = 0.0`
  Band gas exchange is **EXPLICITLY SKIPPED**.

## Conclusion
Legacy **skips** SOLUTE speciation and gas exchange via `VOLWNB > ZEROS2`, while NITRO and UPTAKE clamp all fluxes to available mass ZNH4B. In ng, the 3.3e-11 g N closure failure arises because `reaction_solver` or `aqueous` chemistry attempts un-gated reactions on the sliver. Gating speciation/reactions by `VOLWNB > ZEROS2` (or VLNHB > 1e-12) restores exact legacy parity.

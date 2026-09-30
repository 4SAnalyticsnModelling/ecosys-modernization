# Round 00033 Adversarial Challenge: DEV-015 Stiff Image Acceptance in Solute Transport

## 1. Multi-Cell Coupling & Strict Validity
The 1D contraction argument $|F(x) - x^*| = \frac{|J|}{1+|J|}|r_0| < |r_0|$ assumes diagonal decoupling. For coupled cells ($F(x) = \mathbf{b} + \mathbf{A}x$ with $\mathbf{J} = \mathbf{A}$), consider a 2-cell donor-receiver system:
- Cell 1 (donor) over-drains to Cell 2 via face flux $\phi(x_1) = c x_1$ ($c > 1$):
  $F_1(x) = b_1 - c x_1, \quad F_2(x) = b_2 + c x_1$.
- Let $b_1 = 1$, $c = 100$. Root is $x_1^* = \frac{1}{101} \approx 0.0099$.
- If $x_1 = 0.0101$: $r_{0,1} = 1 - 100(0.0101) - 0.0101 = -0.0201$ (converged within tolerance).
  Image $F_1(x_1) = -0.01 \to 0$ (clamped).
- At image $x_1 = 0$: $r_{1,1} = F_1(0) - 0 = 1.0 > 0$.
  Signs flip, and $|F_1(x_1) - x_1^*| = 0.0099 < |r_{0,1}| = 0.0201$.
- **Why it holds generally**: Off-diagonal coupling strictly increases recipient inventory with donor outflow ($\partial F_j / \partial x_i \ge 0$ for $j \neq i$), while donor diagonal is strictly negative ($\partial F_i / \partial x_i \le 0$). The Jacobian is an $M$-matrix. Thus, donor drain oscillation is bounded by $[0, x^*]$ bracketed by $r_0$ and $r_1$. Coupling cannot push $F(x)$ far from $x^*$ when signs flip across a converged $r_0$.

## 2. Consistency of Face Fluxes vs Published State
`transport_solver.zig:168-181` captures face fluxes at `current` while publishing $F(\text{current})$:
- When $F(x) = 0$ while $x = 3.94\times 10^{-14}\text{ mol}$, `captureAcceptedFaceFlux` (`lines 575-582`) evaluates flux at `current` and clamps it against `accumulator` ($b$).
- Because $F(x)$ was constructed by the exact same accumulation sequence (`lines 527-534`), captured face fluxes match the step from `base` to $F(x)$ to machine precision.
- Nonnegativity is enforced by clamping $F(x) \ge 0$ (`line 527`). Both mass and per-cell closures hold exactly.

## 3. Legacy TRNSFR Handling of Donor Depletion
In legacy Fortran (`trnsfr.f:4053-4059`, `trnsfrs.f:4948-4953`, and `trnsfr.f:200` $VFLWX = XNPHX$):
- Legacy **never iterates implicitly**; it uses explicit sub-hourly steps with a fractional Courant limiter:
  `VFLW = AMAX1(0.0, AMIN1(VFLWX, FLWM / VOLWM))` (`trnsfr.f:4055-4056`).
- It caps convective flux at $VFLWX = 1 / (NPH \cdot NFH)$ of donor water and advects `VFLW * donor_solute` (`trnsfr.f:4061-4075`).
- Small negative roundoffs are floored at next step via `AMAX1(0.0, ...)` (`trnsfr.f:4061`, `trnsfrs.f:4955`). DEV-015 faithfully captures legacy's bounded explicit transfer.

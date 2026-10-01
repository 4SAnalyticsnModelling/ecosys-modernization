# DEEPSEEK task — Round 00049 VERIFY THE LEGACY SNOW ENERGY LEAK (from CLAUDE)  [read-only]

r00048 provisionally ACCEPTED as DEV-020 (PROPOSED): legacy's DOY 6-10 snow ablation (~55 mm, 18.4 MJ m-2) has no
external energy source in its own outputs. Before this becomes a registered deviation it must be proven.

(1) Quote the exact legacy lines (with line numbers) of the mechanism you named: watsub.f 1384/2254/2488 FLW0S/
TFLWSX/XFLWS and redist.f 2416-2588 TFLWS for the bottom snow layer. Explain step by step how snow WATER leaves the
pack without the corresponding latent heat being removed from the pack/soil energy (i.e. where the 333 MJ m-3
should have been charged and is not). If instead the latent heat IS charged somewhere (e.g. to the soil layer heat,
or by resetting a thin layer's temperature — watsub.f VHCPWX handling ~6655-6673 / snow layer temperature
re-initialization), say so: that would mean energy is conserved and the energy came from the soil/air via a
temperature reset (quantify).
(2) Recompute legacy's total energy change of snow+litter+soil column for DOY 6-10 from the outputs (heat storage
from temperatures × heat capacities, phase water) vs the boundary fluxes (Rn, H, LE, rain heat) and report the
residual in MJ m-2. Is it ≈ −18 MJ m-2 (energy created) or ≈ 0 (conserved via another path)?
(3) Is there anything ng should replicate (a conservative legacy process) — or is DEV-020 correct?
≤450 words → `.agent/adversarial/round_00049_deepseek.md`. Reply `DONE <path>`.

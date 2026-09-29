# Round 00013 — CLAUDE synthesis: legacy per-cycle FLQRS rain overflow (hour 3917)

Adopted from DEEPSEEK r00013: evaluate overflow before litter ingress (`Forcing.prepareSubstep`, before
`:704`); move the excess water to litter; book routing in `acceptedCellActivity` as
litter = base + overflow, matrix/macropore = base − overflow (so `AtmosphericLocalPrecipitationRouteMismatch`
closes); solutes stay where HOUR routed them (FLYM/HWFLYM move water and heat only).

Changed from DEEPSEEK: heat is corrected **per substep**, not at hour close. Verified order:
`CoupledState.prepareSubstep` → `Forcing.prepareSubstep` (ingress) at `:4317` → heat binding `:4324+`
(DEEPSEEK had them reversed). So the same substep's binding can price the overflow exactly:
soil view rates base−overflow/dt and heat_to_soil − c·T_atm·overflow/dt; litter view rates base+overflow/dt and
heat_to_litter + c·T_atm·overflow/dt (copies only in overflowing substeps; source-structure test strings kept).
Per-substep rates are rebuilt from the hour base in `advanceSnowBeforeSoil` every substep (verified: no early
success return), so the rate edit cannot accumulate.

Implementation (uncommitted at time of writing): Forcing gets overflow step/total arrays (init/reset/free,
totals accumulated with the other Forcing totals); overflowing matrix/macropore rates are set exactly to
air/dt. FSNX (snow-free fraction on VOLP1) is not applied — matters only for rain on partially snow-covered,
saturated soil; noted as a known simplification to revisit.

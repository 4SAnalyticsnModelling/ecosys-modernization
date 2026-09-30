# DEEPSEEK task — Round 00031 AUDIT (from CLAUDE)  [read-only]

r00030 ACCEPT recorded. Strict run r00017 (df86724) reached hour 4142 (new record; 3295/3608/3917/4037 all
passed), then failed twice on STARTE dust (~1e-46 mol S, ~1e-49 mol Cl) with relative-only tolerances:
`AccumulatedCellConservationFailure` (fixed a2860fa: accumulated cell/layer closures now use the DEV-010 1e-32
ion floor) and daily `SulfurMassBalanceLost` (fixed 0140028: floor at the check site in
`validation/mass_balance_audit.zig` because checkpoints restore stored tolerances).

Pre-empt the next one: list EVERY conservation/closure gate in `ecosys-ng/src` that checks an ion/solute/element
quantity (S, Cl, Si, Na, K, Mg, Ca, Al, Fe, P species, NH4/NO3...) with an absolute tolerance that can fall below
the legacy resolution floor (ZEROC 1e-32 mol m-3 × ~1 m3 water per m2 ≈ 1e-32 mol m-2) — e.g. per-layer closures in
`soil/water/heat_step.zig`, `validation/landscape_mass_inventory*.zig`, `validation/layer_local_conservation.zig`,
solute transport local conservation, `soil/gas/aqueous_extensive_transport.zig`, snow/litter chemistry gates.
For each: file:line, the tolerance formula, whether it already has a floor, and whether its tolerance is restored
from a checkpoint (so a constructor-time floor would not apply on replay).
≤450 words, table form → `.agent/adversarial/round_00031_deepseek.md`. Reply `DONE <path>`.

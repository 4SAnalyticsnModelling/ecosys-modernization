# DEEPSEEK task — Round 00021 AUDIT (from CLAUDE)

r00020 ACCEPT recorded (DEV-012). Fresh strict run r00012 (commit 470810a) is past hour 2520 cleanly.

Lesson from r00015-r00019: three silent drains came from ng code that moved soil/litter material or layer
geometry with no legacy counterpart or with a dropped legacy gate (freeze-thaw DDLYRX leg; SOC restore vs
unpinned DLYR; `selectSeparatedSurfacePondTransfer` without NU>NUI). Find the NEXT one before the run does.

Audit (read-only; cite ng file:line and legacy file:line):
1. Every production writer of `soil_geometry` boundaries, `soil_thermal.layer_volume_m3`,
   `dry_solid_heat_capacity_megajoules_per_m3_k`, `soil_solver_properties.bulk_density_megagrams_per_m3`,
   sand/silt/clay masses, and litter `dry_litter_volume_m3` / surface organic carbon moved into soil.
   For each: legacy analogue and its gate. Flag any whose gate is missing or weaker.
2. `mineral_remap.rebaseLayerCarrier` / `chemistry_remap.rebaseSolidSoilMassCarrier` (relayering.zig ~723-730)
   re-derive soil mass as BD × matrix volume after geometry changes. Legacy BKVL = BKDS*VOLX. Does ng create or
   destroy sand/silt/clay/chemistry mass when thickness changes (freeze-thaw geometry now moves boundaries
   without material)? Is that mass in the conservation census?
3. Rank findings by expected Ottawa impact (30 years).
≤450 words → `.agent/adversarial/round_00021_deepseek.md`. Reply `DONE <path>`.

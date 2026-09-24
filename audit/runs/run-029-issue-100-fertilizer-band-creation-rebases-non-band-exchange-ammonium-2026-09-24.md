# run-029 -- issue-100: 99.2% of the hour-3,276 N residual is a zone-fraction re-base of non-band exchangeable NH4 at the fertilizer publish (2026-09-24)

Task `20260924-010818-3a58d636`. Question: between the hour-start snapshot and `after_nitro`, where does the -0.0770 g N census shortfall (run-028 decomposition) appear, and in which layer-2 NH4 census term?

## Run identity

- Source: HEAD `6d2b3a8`, plus the run-028 TEMP_DIAGNOSTIC probes, plus the new `diagnostics.traceIssue100LayerAmmonium`. That helper prints every term summed by the layer-2 ammonium census (`landscape_mass_inventory_nitrogen.zig:147-186`), with the zone fractions from `fertilizer_band.scienceZoneFractionsForFlatIndex` and the census's own `landscape_soil_mass_megagrams_scratch`. It is called at the hour-start snapshot (`ecosys_ng.zig`, after `reconstructLayerMassBalanceScopes`), after the fertilizer publish, before and after `fertilizer_band_production.prepareHour`, at `before_nitro`, and at all seven post-NITRO trace points. It is gated on hour 3,276 and does logging only.
- Build receipt `audit/runs/issue-100-n100g-build/receipt.json`: exit 0, 950.7 s. exe SHA256 prefix `7268163049911392`.
- Deck: a fresh staged copy of `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/`, no checkpoints (`runottawa` `6A3691C8...`).
- Run receipt `audit/runs/issue-100-n100g-run/receipt.json`: exit 1, 2,071.3 s. stderr SHA256 `EA7E4C64ECBA09C1C026B93B4675ADF6FA0EE57F2068EFA23AC6D6CF0B076543`.
- The frontier reproduces: `census_positive_control entries=3275` and the identical cell-0 N failure row (`residual=-6.76655385993683e-2`), so the probes did not perturb the science.

## Result (exact, from `fractions.Fraction` over the printed decimals)

Unbooked change in the cell-N census (`total_n_g`) per bracket:

| Bracket | Unbooked (g N) | Moving term(s) |
|---|---|---|
| hour start -> after fertilizer publish | **-0.0671468785122** | `exch_nh4_nb_g` only (booked +1.65 lands exactly in `dry_banded_nh4_g`) |
| after publish -> before `prepareHour` | -0.0005171096915 | `aq_nh4_nb_g` -4.986e-4, `aq_nh3_nb_g` -3.4e-7, plus about -1.8e-5 in non-NH4 pools |
| `prepareHour` (before -> after) | 0 | none |
| after `prepareHour` -> before NITRO | 0 | none |
| before NITRO -> `after_nitro` | -0.0093311243094 | NH4 census unchanged (+2.1e-5); loss sits in non-NH4 pools |
| `after_post_watsub` -> `after_uptake` | +0.0093311243093 | cancels the NITRO step to 1e-13 |
| `after_uptake` -> `after_chemistry` | -1.550396e-6 | dry banded NH4 -> band exchange (0.7909 g, internally conserved) |
| `after_chemistry` -> `after_transport` | +7e-13 | booked N2 input 6.63635e-3 |
| **sum** | **-0.06766553859908** | equals the reported residual -0.0676655385994 |

## Mechanism of the dominant step (measured, not inferred)

At the hour-start snapshot and again after the fertilizer publish:

- `exch_nh4_nb_mol_per_mg` = 4.6024195228413856 -> 4.6024195228413856 (bit-identical)
- `soil_mass_mg` = 0.063359887203285684 -> same (bit-identical)
- `frac_nh4_nb` = 1 -> 0.98355260229844832; `frac_nh4_b` = 0 -> 0.016447397701551677 (sum = 1)
- `pending_nh4_nb_g` = `pending_nh4_b_g` = 0 -> 0; `exch_nh4_b_mol_per_mg` = 0 -> 0

The census values non-band exchange NH4 as `concentration * soil_mass * frac_nh4_nb`. For a pure fraction re-base with no mass transfer, the predicted change is `4.0825229456120216 * (0.98355260229844832 - 1)` = **-0.0671468785121912**. Observed: **-0.067146878512192**. So the publish **creates the band zone (the fraction moves 1 -> 0.98355) without repartitioning the 4.0825 g N of existing non-band exchangeable NH4**. It queues no pending band/non-band transfer, and the band exchange concentration stays zero. 1.645% of that inventory therefore disappears from the census. This is the concentration-vs-amount re-base class of issue-099. The mechanism the `prepareHour` comment warns about for phosphate is here triggered by the publish itself, and `prepareHour` moves nothing this hour.

## Not established

- Whether the defect is in state (the repartition is missing, so band-zone exchange NH4 is under-represented for the rest of the run) or in the census (it should not fraction-weight a concentration whose zone just changed). That needs the legacy rule for exchangeable NH4 when the band volume changes (REDIST band-fraction handling of XN4/XNB). It is the next task.
- The -0.000517 g N publish-to-prepare step and the ±0.009331 NITRO/uptake transient are recorded but not explained. The transient cancels and does not contribute to the residual.

No gate changes.

# Round 00007 — CLAUDE: root respiration carbon destroyed every hour (hour-3294 carbon row)

**Symptom:** replay (ckpt 3120) fails hour 3294 layer-2 carbon −1.53e-10 g (1.26e-9 of throughput, limit 1e-9).
**Localization (c108 stage trace retargeted to 3294):** entire residual in the interval
`after_root_gas_advance → after_uptake`: soil residue+organic C −1.41516e-7, plant +1.41363e-7; root gas and
soil gas pools bit-identical; the missing 1.534e-10 is this hour's root respiration.

**Defect (translation):** GROSUB root metabolism / nutrient-uptake cost / pre-emergence write respiration into
`roots.actual_respiration_g_c_per_h` (RCO2A) after removing it from root mobile C
(`plant_root_metabolism_state_update.zig:790-805`, `plant_root_nutrient_uptake.zig:790-795`). The next
hour's `resetHourlyFluxes()` (`ecosys_ng.zig:6899`, UPTAKE init, hour start) zeroes it BEFORE
`plant_root_gas_transport.advance` (`:95-102`) adds it to root aqueous CO2. Net: every hour's root
respiration C vanishes. Legacy: `grosub.f:379` zeroes RCO2A at GROSUB entry — after UPTAKE consumed it at
`uptake.f:2087` (`RCO2PX=-RCO2A*XNPG`). Legacy UPTAKE never writes RCO2A.
Secondary deviation: the pre-emergence path (`shoot_growth_runtime.zig:1434-1435`) credited root aqueous CO2
immediately; legacy `grosub.f:2053` books it only in RCO2A (lagged like all root respiration).

**Fix (uncommitted, strict run r00003 in progress):**
1. `plant_root_system.resetHourlyFluxes`: stop clearing `actual_respiration_g_c_per_h`.
2. `plant_root_gas_transport.advance`: after adding it to root aqueous CO2, clear it (legacy reset point).
3. Pre-emergence: no immediate aqueous CO2 credit (lagged per grosub.f:2053).
4. Census `landscape_mass_inventory_gas.aggregateRootGasRange`: count pending RCO2A as in-transit root CO2.
Field is already checkpointed (reflection over RootState []f64). End-of-hour value unchanged → daily
respiration outputs unchanged. Tests: reset test now asserts RCO2A survives; pre-emergence test asserts no
immediate aqueous credit.

**Open (for DEEPSEEK):** `respiration_unlimited_by_oxygen/carbon` (RCO2M/RCO2N) are also cleared at hour
start, but legacy UPTAKE reads them from the prior GROSUB (`uptake.f:1705` RCO2N, `:1872` ROXYP=2.667*RCO2M).
Does the Zig UPTAKE O2 demand/limitation see zeros? (science gap, not conservation-visible). Also
`symbiotic_respiration_actual_g_c_per_h` — same lag pattern?

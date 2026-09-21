//! Mass-balance reconstruction and debug census helpers.
//!
//! Extracted verbatim from `ecosys_ng.zig` so the entry point holds only
//! `main`. Declaration bodies are unchanged.

const std = @import("std");
const ecosys = @import("ecosys_ng");

/// Temporary, observation-only trace of the first wet-surface heat/O2 frontier.
/// Keep the individual canonical carriers visible; do not call a reconstruction
/// that also publishes arithmetic-provenance diagnostic globals.
///
/// The window is retargeted per investigation. It was `[2533, 2536)` for the
/// hour-2,534 surface frontier; it is now `[2656, 2659)` for
/// `SURFACE-HEAT-PONDED-LITTER-BOOKING-001`, whose fatal attempt is 2,658.
///
/// This is the measurement that investigation needs and it was already wired.
/// Eight bit-exact verifications established that every individual booking at
/// that hour is correct while the hour's surface heat closure is not, which
/// points at an ORDERING effect -- a term moving between two correct bookings.
/// That is invisible to any hour-resolved probe and visible here, because the
/// thirteen call sites bracket the substep: `substep_entry`, `after_snow`,
/// `after_forcing`, `after_recipient_heat`, `accept_entry`,
/// `after_disappearance_arm`, `after_disappearance_consume`, `after_discharge`,
/// `after_litter_soil`, `after_snow_compaction`, plus the three in
/// `hourly_sediment`. Differencing the five carriers across consecutive labels
/// localizes the move to one stage.
///
/// Three hours of tracing, so the per-substep cost that got two broader traces
/// reverted (6x and 2.3x) does not apply.
pub fn traceSurfaceFrontier(context: anytype, stage: []const u8, dt_hours: f64) !void {
    if (comptime @import("builtin").is_test) return;
    if (context.executed_weather_hours.* < 2656 or context.executed_weather_hours.* >= 2659) return;
    const oxygen = @intFromEnum(ecosys.gas_transport.Species.oxygen);
    for (0..context.grid.cell_count) |cell| {
        const component = cell * ecosys.gas_transport.species_count + oxygen;
        const gas = context.litter_gas_transport;
        const organic = try context.surface_organic.totalCarbon_g_c(cell);
        // PHOSPHORUS-SURFACE-CLOSURE-HOUR-2658-001 attribution, added here
        // rather than as a new instrument because these thirteen call sites
        // already bracket the substep across two stage files and are already
        // gated to the three-hour window. The heat case was attributed with a
        // purpose-built per-commit trace that had to be reverted for costing
        // 6x; this rides on a gate that exists.
        //
        // The interface transfer is already accounted for
        // (`surface_to_topsoil = 0.0546924352159549`), leaving
        // `1.54259794175882e-6` of booked output and `0.000109796384402863` of
        // booked input unattributed. Differencing these running totals across
        // consecutive labels names the transaction that books each. No
        // prediction attached.
        const surface_scope = context.hourly_layer_boundary_ledger.layout.index(
            .{ .kind = .surface, .cell = cell },
        ) catch continue;
        const surface_activity = context.hourly_layer_boundary_ledger.activity[surface_scope];
        std.log.info("SURFACE_FRONTIER stage={s} hour={d} dt_hours={e} cell={d} temperature_k={e} cached_capacity_megajoules_per_k={e} liquid_m3={e} ice_we_m3={e} vapor_mol={e} organic_carbon_g_c={e} oxygen_gaseous_g={e} oxygen_dissolved_g={e} oxygen_macro_g={e} oxygen_band_g={e} pending_snow_oxygen_g={e} air_m3={e} booked_phosphorus_input_g={e} booked_phosphorus_output_g={e}", .{
            stage,                                     context.executed_weather_hours.* + 1,                 dt_hours,                                              cell,
            context.grid.surface_temperature_k[cell],  context.surface_heat_capacity_megajoules_per_k[cell], context.surface_precipitation.litter_water_m3[cell],   context.surface_litter_ice_m3[cell],
            gas.water_vapor_mol[cell],                 organic,                                              gas.gaseous_mass_g[component],                         gas.dissolved_mass_g[component],
            gas.macropore_dissolved_mass_g[component], gas.band_dissolved_mass_g[component],                 context.snow_surface_discharge[cell].litter_g[oxygen], gas.air_volume_m3[cell],
            surface_activity.phosphorus_input_g,       surface_activity.phosphorus_output_g,
        });
    }
}

pub fn landscapeMassBalanceInputs(context: anytype) ecosys.landscape_mass_balance_runtime.Inputs {
    return .{
        .grid = context.grid,
        .plants = context.plants,
        .plant_canopy = if (context.detailed_canopy.*) |*canopy| canopy else null,
        .snow = context.snow_transport,
        .soil_thermal = context.soil_thermal,
        .soil_properties = context.soil_solver_properties,
        .soil_gas = context.gas_transport,
        .root_gas = if (context.plant_roots.*) |*roots| roots else null,
        .soil_organic = context.soil_organic,
        .soil_organic_transport = context.soil_organic_transport,
        .surface_organic = context.surface_organic,
        .surface_fire_exchange = context.surface_fire_exchange,
        .mineral_nitrogen = context.mineral_nitrogen_transport,
        .fertilizer_band = context.fertilizer_band,
        .soil_chemistry = context.soil_chemistry,
        .nitrogen_fertilizer = context.soil_fertilizer_inventory,
        .mineral_fertilizer = context.mineral_fertilizer_inventory,
        .suspended_constituents = context.suspended_constituents,
        .plant_litter_salt_ingress = context.plant_litter_salt_ingress,
        .micropore_solutes = context.micropore_solute_state,
        .macropore_solutes = context.macropore_solute_state,
        .surface_chemistry = context.surface_litter_chemistry,
        .surface_solutes = context.surface_solute_transport,
        .surface_fertilizer = context.surface_litter_fertilizer,
        .surface_denitrification_nitrite_g_n = context.surface_denitrification.nitrite_g_n,
        .surface = context.surface_precipitation,
        .surface_ice_water_equivalent_m3 = context.surface_litter_ice_m3,
        .surface_gas = context.litter_gas_transport,
        .surface_litter_dry_mass_megagrams = context.surface_litter_geometry.dry_mass_megagrams,
        .canopy_retention = if (context.canopy_precipitation_retention.*) |*value| value else null,
        .cell_area_m2 = context.canopy_cell_area_m2,
        .soil_mass_megagrams_scratch = context.landscape_soil_mass_megagrams_scratch,
        .parameters = .{
            .snow_ice_density_megagrams_per_m3 = context.runscript.snow_ice_density_megagrams_per_m3,
            .snow_latent_heat_of_fusion_megajoules_per_m3 = context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3,
            .snow_solid_heat_capacity_megajoules_per_m3_k = context.runscript.snow_solid_heat_capacity_megajoules_per_m3_k,
            .soil_latent_heat_of_fusion_megajoules_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
            .carbon_g_per_mol = 12,
            .nitrogen_g_per_mol = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
            .phosphorus_g_per_mol = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
            .snow_ion_molar_mass_g_per_mol = .{
                .aluminum = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.aluminum,
                .iron = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.iron,
                .calcium = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.calcium,
                .magnesium = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.magnesium,
                .sodium = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.sodium,
                .potassium = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.potassium,
                .sulfur = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.sulfur,
                .chloride = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.chloride,
            },
            .surface_physical = .{
                .dry_organic_heat_capacity_megajoules_per_g_c_k = context.runscript.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
                .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                .ice_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
                .ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
                .latent_heat_of_fusion_megajoules_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
                .pure_water_melting_temperature_k = context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
                .water_molar_mass_g_per_mol = context.runscript.soil_gas_transport_parameters.water_molar_mass_g_per_mol,
                .liquid_water_density_g_per_m3 = context.runscript.soil_gas_transport_parameters.water_density_g_per_m3,
            },
        },
    };
}

pub fn reconstructLandscapeMassBalance(context: anytype) !ecosys.mass_balance_audit.Totals {
    return ecosys.landscape_mass_balance_runtime.reconstruct(
        landscapeMassBalanceInputs(context),
        context.landscape_boundary_ledger,
    );
}

/// Uses the exact same authoritative storage-owner wiring as the landscape
/// audit, but preserves horizontal cell scope for hourly acceptance.
pub fn reconstructLandscapeMassBalanceCells(
    context: anytype,
    storage_by_cell: []ecosys.landscape_mass_inventory.Storage,
) !void {
    try ecosys.landscape_mass_balance_runtime.reconstructCells(
        landscapeMassBalanceInputs(context),
        storage_by_cell,
    );
}

/// Reconstructs every soil layer, snow layer, surface and canopy control
/// volume from the identical authoritative inputs used by the canonical cell
/// census. `reconstructScopes` also requires their fieldwise partition back to
/// `canonical_cells_scratch`, so this wrapper cannot silently drift from the
/// existing landscape/per-cell gate.
pub fn reconstructLayerMassBalanceScopes(
    context: anytype,
    layout: ecosys.layer_local_conservation.Layout,
    storage_by_scope: []ecosys.landscape_mass_inventory.Storage,
    canonical_cells_scratch: []ecosys.landscape_mass_inventory.Storage,
) !void {
    try ecosys.layer_mass_inventory.reconstructScopes(
        landscapeMassBalanceInputs(context),
        layout,
        storage_by_scope,
        canonical_cells_scratch,
    );
}

/// ISSUE-065 ninth pass: stage-boundary trace for the hour-2,894 layer-0 mass
/// loss investigation (`audit/issues/issue-065-...md`, eighth addendum's
/// closing hypothesis -- "a third, unidentified writer (most likely
/// TRNSFR/TRNSFRS/REDIST) must be mutating layer 0's chemistry state"). The
/// carrier/mutator (`water_carrier_rebase.zig`) and the SOLUTE reaction-network
/// gate (`soil_chemistry_convergence.zig`) are both execution-confirmed
/// innocent for magnitude at hour 2,894/layer 0 (third/eighth addenda). This
/// calls the SAME authoritative computation the failing gate itself uses to
/// populate `carbon_dioxide_carbon_g` for `hourly_layer_storage_before/after`
/// (`aggregateProfilePhosphorusAndIonsLayer`, `layer_mass_inventory.zig:93`) at
/// every named per-hour stage boundary, so the exact stage where the value
/// drops can be read directly from the log instead of inferred from a partial
/// domain-wide trace.
///
/// Gated to `[2888, 2896)`, cell 0, layer 0 only: at most a handful of extra
/// reconstructions per production run, matching this issue's established
/// `DRY_CARRIER_TRACE` convention (third/fourth/fifth/seventh addenda).
pub fn traceStageBoundaryLayer0Carbon(context: anytype, comptime stage: []const u8) !void {
    if (comptime @import("builtin").is_test) return;
    if (context.executed_weather_hours.* < 2888 or context.executed_weather_hours.* >= 2896) return;
    if (context.grid.cell_count == 0) return;
    try ecosys.landscape_mass_balance_runtime.deriveSoilMass(
        context.soil_solver_properties.matrix_bulk_volume_m3,
        context.soil_solver_properties.bulk_density_megagrams_per_m3,
        context.landscape_soil_mass_megagrams_scratch,
    );
    const layer0 = try ecosys.landscape_mass_inventory.aggregateProfilePhosphorusAndIonsLayer(
        context.grid,
        context.micropore_solute_state,
        context.macropore_solute_state,
        context.soil_chemistry,
        context.mineral_fertilizer_inventory,
        context.grid.matrix_liquid_water_m3,
        context.landscape_soil_mass_megagrams_scratch,
        context.fertilizer_band,
        12,
        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        context.canopy_cell_area_m2,
        0,
        0,
    );
    std.log.info(
        "DRY_CARRIER_TRACE site=stage_boundary stage={s} hour={d} cell=0 layer=0 live_water_m3={e} dry_reference_water_m3={e} soil_mass_megagrams={e} carbon_dioxide_carbon_g={e} ion_inventory_mol={e} phosphate_phosphorus_g={e}",
        .{
            stage,
            context.executed_weather_hours.* + 1,
            context.grid.matrix_liquid_water_m3[0],
            context.soil_chemistry.dry_reference_water_m3[0],
            context.landscape_soil_mass_megagrams_scratch[0],
            layer0.carbon_dioxide_carbon_g,
            layer0.ion_inventory_mol,
            layer0.phosphate_phosphorus_g,
        },
    );
    // ISSUE-065 (eleventh addendum): does nitrogen have its own water-carrier
    // round trip that `erosion_chemistry_bridge.zig`'s/`exportChemistry`'s
    // fixes did not touch? `mineral_nitrogen_transport.initializeMatrix`
    // (called via `refreshMatrixFromReactionState`/`captureHourStartMatrix`)
    // computes `amounts[...] = aqueous.* * matrix_water_volume_m3[cell] *
    // fraction` with no dry-reference substitution. Trace the matrix's own
    // extensive ammonium/nitrate amounts for layer 0 alongside the
    // authoritative `chemistry.aqueous[0]` concentrations that back them, so
    // a rerun can show whether/when this zeroes at hour 2894.
    const mineral_amounts = try context.mineral_nitrogen_transport.matrix.cellAmountsConst(0);
    std.log.info(
        "DRY_CARRIER_TRACE site=stage_boundary_nitrogen stage={s} hour={d} cell=0 layer=0 live_water_m3={e} dry_reference_water_m3={e} ammonium_non_band_conc={e} nitrate_non_band_conc={e} matrix_ammonium_non_band_mol={e} matrix_ammonium_band_mol={e} matrix_nitrate_non_band_mol={e} matrix_nitrate_band_mol={e} matrix_water_volume_m3={e}",
        .{
            stage,
            context.executed_weather_hours.* + 1,
            context.grid.matrix_liquid_water_m3[0],
            context.soil_chemistry.dry_reference_water_m3[0],
            context.soil_chemistry.aqueous[0].ammonium_non_band,
            context.soil_chemistry.aqueous[0].nitrate_non_band,
            mineral_amounts[@intFromEnum(ecosys.mineral_nitrogen_transport.Species.ammonium_non_band)],
            mineral_amounts[@intFromEnum(ecosys.mineral_nitrogen_transport.Species.ammonium_band)],
            mineral_amounts[@intFromEnum(ecosys.mineral_nitrogen_transport.Species.nitrate_non_band)],
            mineral_amounts[@intFromEnum(ecosys.mineral_nitrogen_transport.Species.nitrate_band)],
            context.mineral_nitrogen_transport.matrix.water_volume_m3[0],
        },
    );
    // ISSUE-065 (thirteenth addendum): the twelfth addendum's fix
    // (`mineral_nitrogen_transport.zig`'s `initializeMatrix`/`publishMatrix`
    // carrier substitution) execution-confirmed the `hourly_sediment.zig:988`
    // zeroing event no longer occurs, yet the gate's own nitrogen residual only
    // improved ~16.5% -- a second, distinct leak remains. The raw matrix-mol
    // trace above only watches `ammonium_non_band`/`nitrate_non_band`; it
    // cannot see a drop in ammonia, nitrite, exchange, or dry-fertilizer
    // contributions, or a drop that happens outside the twelve call sites this
    // trace already brackets. This calls the SAME authoritative aggregator the
    // gate itself uses for the cell's mineral-N total (single-cell deck, so
    // `cell=0` here is the entire gate scope, not a layer subset) at every
    // stage boundary, mirroring exactly how `phosphate_phosphorus_g` above
    // already localizes phosphorus.
    const nitrogen_cell = try ecosys.landscape_mass_inventory.aggregateProfileMineralNitrogenCell(
        context.grid,
        context.mineral_nitrogen_transport,
        context.soil_chemistry,
        context.soil_fertilizer_inventory,
        context.landscape_soil_mass_megagrams_scratch,
        context.fertilizer_band,
        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        0,
    );
    std.log.info(
        "DRY_CARRIER_TRACE site=stage_boundary_nitrogen_total stage={s} hour={d} cell=0 ammonium_nitrogen_g={e} nitrate_nitrogen_g={e} mineral_nitrogen_total_g={e} ion_inventory_mol={e}",
        .{
            stage,
            context.executed_weather_hours.* + 1,
            nitrogen_cell.ammonium_nitrogen_g,
            nitrogen_cell.nitrate_nitrogen_g,
            nitrogen_cell.ammonium_nitrogen_g + nitrogen_cell.nitrate_nitrogen_g,
            nitrogen_cell.ion_inventory_mol,
        },
    );
}

/// issue-078 (2026-09-21): a narrowly-gated, temporary trace of cell 0's own
/// layer 0/1/2 matrix pore occupancy vs. capacity, bracketing the end-of-hour
/// REDIST geometry/relayering transaction (`geometry_disturbance.finalize`,
/// which owns `soil_profile_relayering.applyEndOfHourGeometry` ->
/// `heat_layer_remap.transferLayerFractions`). This issue's diagnosis
/// hypothesizes that layer 0's hour-entry overfill has no relief path in the
/// WATSUB vertical-displacement mechanical prepass (it only ever relieves a
/// DEEPER layer by moving liquid UP into the layer above, never the reverse),
/// so any residual overfill still on layer 0 when this stage boundary is
/// reached is exactly what `transferLayerFractions`'s fx-weighted extensive
/// transfer can carry one layer deeper (layer 1), matching
/// `audit/issues/issue-078-...md`'s transmission hypothesis. Called
/// immediately before and after `geometry_disturbance.finalize` (see the two
/// call sites in `hourly_vegetation.zig`, alongside the existing
/// `traceStageBoundaryLayer0Carbon` calls), so the before/after difference at
/// each layer isolates exactly what this one stage moved. Gated to
/// `[3248, 3254]`, cell 0, layers 0-2 only -- a no-op everywhere else,
/// matching this session's established `DRY_CARRIER_TRACE`/`TEMP_DIAGNOSTIC`
/// hour-window convention.
pub fn traceIssue078SoilPoreOverfill(context: anytype, comptime stage: []const u8) !void {
    if (comptime @import("builtin").is_test) return;
    const hour = context.executed_weather_hours.* + 1;
    if (hour < 3248 or hour > 3254) return;
    if (context.grid.cell_count == 0) return;
    for ([_]usize{ 0, 1, 2 }) |layer_offset| {
        const index = context.grid.layerIndex(0, layer_offset) catch continue;
        const capacity_m3 = context.grid.matrix_pore_capacity_m3[index];
        const liquid_m3 = context.grid.matrix_liquid_water_m3[index];
        const ice_m3 = context.grid.matrix_ice_water_m3[index];
        std.log.info(
            "TEMP_DIAGNOSTIC issue-078 pore overfill stage boundary: stage={s} hour={d} cell=0 layer={d} index={d} matrix_pore_capacity_m3={e} matrix_liquid_water_m3={e} matrix_ice_water_m3={e} matrix_overfill_m3={e}",
            .{
                stage,
                hour,
                layer_offset,
                index,
                capacity_m3,
                liquid_m3,
                ice_m3,
                liquid_m3 - capacity_m3,
            },
        );
    }
}

/// ISSUE-065 (fourteenth addendum): the thirteenth addendum localized
/// phosphorus's entire hour-2,894 drop to inside `convergeHourlySoilChemistry`'s
/// scratch block, then narrowed the search to `updateFertilizerBandGeometry`
/// as the only unconditionally-running function -- but this deck's phosphate
/// band is confirmed (this pass, by reading the deck's own `plant_nutrients`
/// runscript record and its one hour-2894-relevant fertilizer event) never
/// active (`initial_phosphate_band_fraction=0`, no banded application by hour
/// 2894), so that mechanism cannot fire. Re-reading `convergeHourlySoilChemistry`
/// in full (not just its named scratch block) surfaces an earlier,
/// unconditional call this issue never traced: `materializePendingSolids`
/// (`chemistry_state.zig`), called once per active layer, every hour, using
/// the RAW `context.grid.matrix_liquid_water_m3[layer]` (no
/// `dry_reference_water_m3` substitution) as the water carrier for every
/// water-carried immobile phosphate/geochemistry-solid field. Trace the
/// exact carrier and pending/concentration totals bracketing that call for
/// cell 0/layer 0, so a rerun can show whether a nonzero pending amount is
/// being materialized against an anomalous (near-zero but nonzero, or
/// otherwise carrier-mismatched) water volume at hour 2894.
///
/// Gated identically to the established `DRY_CARRIER_TRACE` convention.
pub fn traceMaterializePendingSolidsLayer0(
    context: anytype,
    comptime site: []const u8,
    water_m3: f64,
    fractions: anytype,
) void {
    if (comptime @import("builtin").is_test) return;
    if (context.executed_weather_hours.* < 2888 or context.executed_weather_hours.* >= 2896) return;
    const chemistry = context.soil_chemistry;
    std.log.info(
        "DRY_CARRIER_TRACE site={s} hour={d} cell=0 layer=0 water_m3={e} dry_reference_water_m3={e} phosphate_non_band_fraction={e} phosphate_band_fraction={e} pending_non_band_phosphate_sum={e} pending_band_phosphate_sum={e} pending_geochemistry_solids_sum={e} non_band_phosphate_sum={e} band_phosphate_sum={e} geochemistry_solids_sum={e}",
        .{
            site,
            context.executed_weather_hours.* + 1,
            water_m3,
            chemistry.dry_reference_water_m3[0],
            fractions.phosphate_non_band,
            fractions.phosphate_band,
            sumStructFieldsF64(chemistry.pending_non_band_phosphate_mol[0]),
            sumStructFieldsF64(chemistry.pending_band_phosphate_mol[0]),
            sumStructFieldsF64(chemistry.pending_geochemistry_solids_mol[0]),
            sumStructFieldsF64(chemistry.non_band_phosphate[0]),
            sumStructFieldsF64(chemistry.band_phosphate[0]),
            sumStructFieldsF64(chemistry.geochemistry_solids[0]),
        },
    );
}

/// ISSUE-065 (fifteenth pass): the fourteenth addendum narrowed nitrogen's
/// remaining ~8.14e-3 g N residual to a possible booking mismatch inside
/// layer 0's own erosion LOCAL exchange (soil<->surface within the same
/// cell), specifically the fraction-sensitive `exchange_ammonium_mol_n`
/// sub-pool -- `erosion_chemistry_bridge.zig`'s `cationCarrier` is the only
/// cation whose packed extensive amount depends on
/// `fractions.ammonium_non_band`/`ammonium_band` rather than soil mass alone.
/// Reconstructs the exact extensive ammonium amount (concentration * carrier
/// + pending, matching `packMapped`'s own formula exactly) at layer 0, so a
/// "before pack" and "after unpack" pair of calls -- bracketing the entire
/// pack/exchange/unpack round trip -- lets a rerun compute the true applied
/// change and compare it against the flux `accumulateSuspendedLocalExchange`
/// separately books (see `traceErosionAmmoniumLocalTransferLayer0` below).
///
/// Gated identically to the established `DRY_CARRIER_TRACE` convention.
pub fn traceErosionAmmoniumExchangeLayer0(
    context: anytype,
    comptime site: []const u8,
) void {
    if (comptime @import("builtin").is_test) return;
    if (context.executed_weather_hours.* < 2888 or context.executed_weather_hours.* >= 2896) return;
    if (context.grid.cell_count == 0) return;
    const chemistry = context.soil_chemistry;
    const soil_mass = context.erosion_canonical_topsoil_mass_megagrams[0];
    const fractions = context.erosion_topsoil_zone_fractions[0];
    const conc = chemistry.cation_exchange_mol_per_megagram[0];
    const pending = chemistry.pending_cation_exchange_mol[0];
    const amount_non_band = conc.ammonium_non_band * soil_mass * fractions.ammonium_non_band + pending.ammonium_non_band;
    const amount_band = conc.ammonium_band * soil_mass * fractions.ammonium_band + pending.ammonium_band;
    std.log.info(
        "DRY_CARRIER_TRACE site={s} hour={d} cell=0 layer=0 soil_mass_megagrams={e} ammonium_non_band_fraction={e} ammonium_band_fraction={e} ammonium_non_band_conc={e} ammonium_band_conc={e} pending_ammonium_non_band_mol={e} pending_ammonium_band_mol={e} amount_ammonium_non_band_mol={e} amount_ammonium_band_mol={e} amount_ammonium_total_mol={e}",
        .{
            site,
            context.executed_weather_hours.* + 1,
            soil_mass,
            fractions.ammonium_non_band,
            fractions.ammonium_band,
            conc.ammonium_non_band,
            conc.ammonium_band,
            pending.ammonium_non_band,
            pending.ammonium_band,
            amount_non_band,
            amount_band,
            amount_non_band + amount_band,
        },
    );
}

/// ISSUE-065 (fifteenth pass): companion to `traceErosionAmmoniumExchangeLayer0`.
/// Called once, immediately after `suspended_constituents.exchangeLocal` has
/// run (and before `accumulateSuspendedLocalExchange` books it), this reads
/// the exact same two packed-component indices
/// (`chemistry_live_and_pending`'s ammonium_non_band/ammonium_band slots,
/// per `cation_exchange.Cations`' field order) that the ledger booking reads,
/// directly from `suspended_constituents`' own arrays -- the signed flux the
/// ledger will book (`local_transfer_to_suspension`) and the post-exchange
/// topsoil/suspended packed amounts, so it can be compared against the
/// before/after amounts the sibling trace reconstructs from persistent
/// chemistry state.
pub fn traceErosionAmmoniumLocalTransferLayer0(
    context: anytype,
    comptime site: []const u8,
) !void {
    if (comptime @import("builtin").is_test) return;
    if (context.executed_weather_hours.* < 2888 or context.executed_weather_hours.* >= 2896) return;
    if (context.grid.cell_count == 0) return;
    const state = context.suspended_constituents;
    const chemistry_range = try state.layout.range(.chemistry_live_and_pending);
    const idx_non_band = chemistry_range.start + 0;
    const idx_band = chemistry_range.start + 1;
    std.log.info(
        "DRY_CARRIER_TRACE site={s} hour={d} cell=0 topsoil_ammonium_non_band_mol={e} topsoil_ammonium_band_mol={e} suspended_ammonium_non_band_mol={e} suspended_ammonium_band_mol={e} local_transfer_ammonium_non_band_mol={e} local_transfer_ammonium_band_mol={e}",
        .{
            site,
            context.executed_weather_hours.* + 1,
            context.erosion_topsoil_constituent_pools[idx_non_band],
            context.erosion_topsoil_constituent_pools[idx_band],
            state.pools[idx_non_band],
            state.pools[idx_band],
            state.local_transfer_to_suspension[idx_non_band],
            state.local_transfer_to_suspension[idx_band],
        },
    );
}

/// ISSUE-065 (sixteenth pass): the fifteenth addendum proved every previously
/// checked input to the census's phosphate aggregator (water carrier,
/// soil-mass carrier, reaction-solver internals) is bit-for-bit constant
/// across the exact window (`after_uptake_growth_extract` ->
/// `after_solute_phase`) where the whole drop occurs, yet the aggregator's
/// own output changes. `mineral_fertilizer_inventory.publishWetted` (called
/// inside `convergeHourlySoilChemistry`, before its named scratch block) is a
/// genuine, not-yet-examined writer to `chemistry.non_band_phosphate[0]`'s
/// and `chemistry.band_phosphate[0]`'s `monocalcium_phosphate_solid_mol_per_m3`/
/// `hydroxyapatite_solid_mol_per_m3` fields, driven by the RAW (not
/// `dry_reference_water_m3`-substituted) `context.grid.matrix_liquid_water_m3`
/// carrier -- the same defect shape as every other fix in this issue's
/// history, just at a call site none of the prior fifteen passes traced.
/// Logs the pending (undissolved) fertilizer inventory's phosphate-relevant
/// fields alongside the persistent concentration sums, so a rerun can show
/// directly whether this call's phosphate branch is live (nonzero pending
/// inventory) at hour 2,894, or a confirmed no-op (this deck never applies
/// N/P fertilizer, so this may simply corroborate that fact directly rather
/// than by inference).
///
/// Gated identically to the established `DRY_CARRIER_TRACE` convention.
pub fn tracePublishWettedPhosphateLayer0(context: anytype, comptime site: []const u8) void {
    if (comptime @import("builtin").is_test) return;
    if (context.executed_weather_hours.* < 2888 or context.executed_weather_hours.* >= 2896) return;
    const chemistry = context.soil_chemistry;
    const pending = context.mineral_fertilizer_inventory.soil[0];
    std.log.info(
        "DRY_CARRIER_TRACE site={s} hour={d} cell=0 layer=0 live_water_m3={e} dry_reference_water_m3={e} pending_broadcast_monocalcium_phosphate_mol={e} pending_banded_monocalcium_phosphate_mol={e} pending_hydroxyapatite_mol={e} pending_calcite_mol={e} non_band_phosphate_sum={e} band_phosphate_sum={e} geochemistry_solids_sum={e}",
        .{
            site,
            context.executed_weather_hours.* + 1,
            context.grid.matrix_liquid_water_m3[0],
            chemistry.dry_reference_water_m3[0],
            pending.broadcast_monocalcium_phosphate_mol,
            pending.banded_monocalcium_phosphate_mol,
            pending.hydroxyapatite_mol,
            pending.calcite_mol,
            sumStructFieldsF64(chemistry.non_band_phosphate[0]),
            sumStructFieldsF64(chemistry.band_phosphate[0]),
            sumStructFieldsF64(chemistry.geochemistry_solids[0]),
        },
    );
}

/// ISSUE-065 (sixteenth pass): reading `updateFertilizerBandGeometry` and its
/// `fertilizer_band_nitrate_phosphate.updateGeometry` mutator shows the
/// deck's `plant_nutrients` runscript record (`plant_nutrients,0,0,0,1,1,1,1`)
/// sets `initial_phosphate_band_row_spacing_m=1` (the record's SEVENTH field,
/// per `driver/runscript.zig:369-377`) -- a value the fourteenth addendum's
/// own reading never checked, having stopped at the record's THIRD field
/// (`initial_phosphate_band_fraction=0`). `updateGeometry`'s own early-return
/// guard (`soil_chemistry_convergence.zig:664`, `fertilizer_band_nitrate_phosphate.zig:146`)
/// is driven by `phosphate_row_width_m > 0` alone, NOT by the
/// `active_by_family` flag the fourteenth addendum actually read -- these are
/// two independent gates. If row spacing is genuinely 1 m, band geometry
/// updates are NOT a confirmed dead end after all: `updateGeometry` runs its
/// full body every hour and persistently mutates
/// `context.fertilizer_band`'s own `band_volume_fraction[phosphate]`, exactly
/// the mechanism the thirteenth addendum's unconfirmed candidate named.
/// Traces both the RAW current zone fraction (`zoneFractions`, what the
/// geometry mutator just wrote) and the SYNCED science fraction
/// (`scienceZoneFractions`, what the census/materialization call sites
/// actually consult) immediately before and after the
/// `updateFertilizerBandGeometry` call, so a rerun shows directly whether the
/// fraction the census reads actually moves at hour 2,894 -- not merely
/// whether the mechanism is theoretically live.
///
/// Gated identically to the established `DRY_CARRIER_TRACE` convention.
pub fn tracePhosphateBandGeometryLayer0(context: anytype, comptime site: []const u8) !void {
    if (comptime @import("builtin").is_test) return;
    if (context.executed_weather_hours.* < 2888 or context.executed_weather_hours.* >= 2896) return;
    const chemistry = context.soil_chemistry;
    const raw = try context.fertilizer_band.zoneFractions(0, 0);
    const synced = try context.fertilizer_band.scienceZoneFractions(0, 0);
    std.log.info(
        "DRY_CARRIER_TRACE site={s} hour={d} cell=0 layer=0 live_water_m3={e} dry_reference_water_m3={e} raw_phosphate_non_band={e} raw_phosphate_band={e} synced_phosphate_non_band={e} synced_phosphate_band={e} non_band_phosphate_sum={e} band_phosphate_sum={e}",
        .{
            site,
            context.executed_weather_hours.* + 1,
            context.grid.matrix_liquid_water_m3[0],
            chemistry.dry_reference_water_m3[0],
            raw.phosphate_non_band,
            raw.phosphate_band,
            synced.phosphate_non_band,
            synced.phosphate_band,
            sumStructFieldsF64(chemistry.non_band_phosphate[0]),
            sumStructFieldsF64(chemistry.band_phosphate[0]),
        },
    );
}

/// ISSUE-065 (seventeenth pass): the sixteenth addendum's by-elimination
/// proof showed the census's phosphate aggregator
/// (`landscape_mass_inventory_phosphorus_ions.zig`'s
/// `aggregateProfilePhosphorusAndIonsRange`, `:276-380`) sums exactly three
/// additive terms for layer 0, and terms 2 (immobile/concentration-basis,
/// `chemistry.non_band_phosphate[0]`/`band_phosphate[0]`) and 3
/// (pending/extensive-mol, `chemistry.pending_non_band_phosphate_mol[0]`/
/// `pending_band_phosphate_mol[0]`) are now proven bit-for-bit frozen across
/// the ENTIRE `convergeHourlySoilChemistry` call at hour 2,894 -- so if the
/// residual is anywhere inside this call, it must be in term 1, the
/// aqueous/transport-basis dissolved-phosphate `amount_mol`
/// (`context.micropore_solute_state`/`macropore_solute_state`), which no
/// prior pass has measured directly (only inferred by elimination). This
/// isolates term 1 alone -- the sum, over every phosphate-carrier
/// `AqueousSpecies` (`transport_species.diffusivityClass(species) ==
/// .phosphate`), of `micropore.cellAmountsConst(0)[i] +
/// macropore.cellAmountsConst(0)[i]`, converted to grams P by the same
/// `phosphorus_g_per_mol` the gate itself uses (`:287-288`) -- so a rerun
/// bracketing every call inside `publishHourlyChemistry`
/// (`soil_chemistry_convergence.zig:990-1024`:
/// `validateCarrierVolumesScaled`, `refreshMatrixFromReactionState`,
/// `exportChemistry`, `consumeUndissolved`) can show exactly which one moves
/// it, rather than continuing to infer the location by elimination.
///
/// Gated identically to the established `DRY_CARRIER_TRACE` convention.
pub fn tracePhosphateAqueousTransportTermLayer0(context: anytype, comptime site: []const u8) !void {
    if (comptime @import("builtin").is_test) return;
    if (context.executed_weather_hours.* < 2888 or context.executed_weather_hours.* >= 2896) return;
    if (context.grid.cell_count == 0) return;
    const micro = context.micropore_solute_state;
    const macro = context.macropore_solute_state;
    const micro_amounts = try micro.cellAmountsConst(0);
    const macro_amounts = try macro.cellAmountsConst(0);
    const p_mass = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol;
    var micro_mol: f64 = 0;
    var macro_mol: f64 = 0;
    inline for (@typeInfo(ecosys.solute_transport_species.AqueousSpecies).@"enum".fields) |field| {
        const species: ecosys.solute_transport_species.AqueousSpecies = @enumFromInt(field.value);
        if (ecosys.solute_transport_species.diffusivityClass(species) == .phosphate) {
            micro_mol += micro_amounts[field.value];
            macro_mol += macro_amounts[field.value];
        }
    }
    std.log.info(
        "DRY_CARRIER_TRACE site={s} hour={d} cell=0 layer=0 micropore_phosphate_mol={e} macropore_phosphate_mol={e} aqueous_transport_phosphate_g={e} micropore_water_volume_m3={e} macropore_water_volume_m3={e} live_water_m3={e} dry_reference_water_m3={e}",
        .{
            site,
            context.executed_weather_hours.* + 1,
            micro_mol,
            macro_mol,
            (micro_mol + macro_mol) * p_mass,
            micro.water_volume_m3[0],
            macro.water_volume_m3[0],
            context.grid.matrix_liquid_water_m3[0],
            context.soil_chemistry.dry_reference_water_m3[0],
        },
    );
}

/// ISSUE-065 (eighteenth pass): the seventeenth addendum localized phosphorus's
/// entire hour-2,894 residual to `aqueous_transport_bridge.exportChemistry`
/// (`soil_chemistry_convergence.zig:997`) and hypothesized a WATSUB-collapse-
/// before-deferred-rebase timing gap, but that measurement only ever compared
/// the STALE `transport_state.amount_mol` (term 1, unchanged by anything except
/// `exportChemistry`/`importChemistry`/`advanceTransport`) against
/// `exportChemistry`'s own fresh recompute. It never traced the underlying
/// `chemistry_state` CONCENTRATION fields (`non_band_phosphate[0]`/
/// `band_phosphate[0]`'s dissolved species) or the fertilizer-band ZONE
/// FRACTION themselves across the hour, so it could not distinguish "the
/// concentration is already wrong before `exportChemistry` runs" from "the
/// rebase that would correct it is deferred past `exportChemistry`".
///
/// This traces the IMPLIED aqueous export `exportChemistry` would compute
/// RIGHT NOW from the current `chemistry_state` concentrations, the current
/// `context.fertilizer_band` zone fractions, and the current carrier
/// (`exportCarrierM3`'s own substitution rule, reproduced here rather than
/// imported, since it is `fn`-private to `aqueous_transport_bridge.zig`) --
/// independent of `transport_state.amount_mol` entirely. Called at every
/// `traceStageBoundaryLayer0Carbon` boundary already bracketing the hour
/// (`before_nitro`, `after_nitro`, `after_uptake_growth_extract`,
/// `after_solute_phase`, `after_transport_replay`), so a rerun shows exactly
/// which boundary the implied value first drops at, across both hour 2,893
/// (still within the `[2888, 2896)` window) and hour 2,894 -- rather than only
/// the already-known single-call attribution inside hour 2,894 alone.
pub fn traceImpliedPhosphateExportLayer0(context: anytype, comptime site: []const u8) !void {
    if (comptime @import("builtin").is_test) return;
    if (context.executed_weather_hours.* < 2888 or context.executed_weather_hours.* >= 2896) return;
    if (context.grid.cell_count == 0) return;
    const chemistry_state = context.soil_chemistry;
    const fractions = try context.fertilizer_band.scienceZoneFractionsForFlatIndex(0);
    const live_water_m3 = context.grid.matrix_liquid_water_m3[0];
    const dry_reference_water_m3 = chemistry_state.dry_reference_water_m3[0];
    const negligible_water_volume_m3 = ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[0]);
    const carrier_m3 = if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
    var non_band_conc_sum: f64 = 0;
    var band_conc_sum: f64 = 0;
    inline for (@typeInfo(ecosys.solute_transport_species.AqueousSpecies).@"enum".fields) |field| {
        const species: ecosys.solute_transport_species.AqueousSpecies = @enumFromInt(field.value);
        if (ecosys.solute_transport_species.diffusivityClass(species) == .phosphate) {
            const dissolved_mol_per_m3 = ecosys.soil_aqueous_transport_bridge.concentration(chemistry_state, 0, species);
            if (comptime std.mem.startsWith(u8, field.name, "band_")) {
                band_conc_sum += dissolved_mol_per_m3;
            } else {
                non_band_conc_sum += dissolved_mol_per_m3;
            }
        }
    }
    const p_mass = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol;
    const implied_aqueous_phosphate_g = carrier_m3 * p_mass *
        (fractions.phosphate_non_band * non_band_conc_sum + fractions.phosphate_band * band_conc_sum);
    std.log.info(
        "DRY_CARRIER_TRACE site=implied_{s} hour={d} cell=0 layer=0 implied_aqueous_phosphate_g={e} carrier_m3={e} live_water_m3={e} dry_reference_water_m3={e} phosphate_non_band_fraction={e} phosphate_band_fraction={e} non_band_conc_sum_mol_per_m3={e} band_conc_sum_mol_per_m3={e}",
        .{
            site,
            context.executed_weather_hours.* + 1,
            implied_aqueous_phosphate_g,
            carrier_m3,
            live_water_m3,
            dry_reference_water_m3,
            fractions.phosphate_non_band,
            fractions.phosphate_band,
            non_band_conc_sum,
            band_conc_sum,
        },
    );
}

fn sumStructFieldsF64(value: anytype) f64 {
    var total: f64 = 0;
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
        total += @field(value, field.name);
    }
    return total;
}

pub fn diagnosticStoredNitrogen_g(context: anytype) !f64 {
    const totals = try reconstructLandscapeMassBalance(context);
    return totals.residue_nitrogen_g + totals.organic_nitrogen_g +
        totals.dinitrogen_nitrogen_g + totals.ammonium_nitrogen_g +
        totals.nitrate_nitrogen_g;
}

pub fn diagnosticStoredCarbon_g(context: anytype) !f64 {
    const totals = try reconstructLandscapeMassBalance(context);
    return totals.residue_carbon_g + totals.organic_carbon_g +
        totals.carbon_dioxide_carbon_g + totals.plant_carbon_g;
}

/// The audited heat balance, `storage - external_in + external_out -
/// internal_production + internal_consumption`, as a running total rather than
/// a per-day deviation.
///
/// The existing `heat stage:` instrument reports the change in census *storage*
/// alone. That cannot distinguish a stage that moves enthalpy and books it
/// correctly (storage moves, ledger moves, audit unaffected) from a stage that
/// changes stored enthalpy with no booking at all (storage moves, ledger does
/// not, audit breaks). Only the second is a defect, and only the second is what
/// HEAT-001 is. Differencing this quantity across a stage isolates it: a
/// conserving stage reads ~0 however much heat it legitimately moves.
///
/// This is the same expression as `mass_balance_audit.Balance.heat_megajoules`.
pub fn diagnosticClosedHeatBalance_megajoules(context: anytype) !f64 {
    const totals = try reconstructLandscapeMassBalance(context);
    return totals.heat_storage_megajoules -
        totals.cumulative_heat_input_megajoules +
        totals.cumulative_heat_output_megajoules -
        totals.cumulative_internal_heat_production_megajoules +
        totals.cumulative_internal_heat_consumption_megajoules;
}

/// Total surface litter organic carbon across every cell.
///
/// The surface census prices litter heat capacity off this carbon
/// (`landscape_mass_inventory_surface.zig`), so a change here at fixed
/// temperature moves stored enthalpy with no process flux and must be booked by
/// `surface_litter_organic_heat_rebase`. Reporting it beside the closed heat
/// residual makes an unbooked carbon move directly attributable, not inferred.
pub fn diagnosticSurfaceOrganicCarbon_g_c(context: anytype) !f64 {
    var total: f64 = 0;
    for (0..context.surface_organic.layer_count) |cell|
        total += try context.surface_organic.totalCarbon_g_c(cell);
    return total;
}

pub fn diagnosticStoredPhosphorus_g(context: anytype) !f64 {
    const totals = try reconstructLandscapeMassBalance(context);
    return totals.residue_phosphorus_g + totals.organic_phosphorus_g +
        totals.phosphate_phosphorus_g;
}

pub fn diagnosticPhosphorusOwners_g(context: anytype) ![3]f64 {
    const totals = try reconstructLandscapeMassBalance(context);
    return .{ totals.residue_phosphorus_g, totals.organic_phosphorus_g, totals.phosphate_phosphorus_g };
}

pub fn diagnosticRelayerPhosphateOwners_g(context: anytype) ![3]f64 {
    const p_mass = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol;
    var result: [3]f64 = @splat(0);
    for (0..context.grid.layer_count) |layer| {
        const zone_fractions = try context.fertilizer_band.scienceZoneFractionsForFlatIndex(layer);
        const fractions = [2]f64{ zone_fractions.phosphate_non_band, zone_fractions.phosphate_band };
        const water = context.grid.matrix_liquid_water_m3[layer];
        const soil_mass = context.soil_solver_properties.matrix_bulk_volume_m3[layer] * context.soil_solver_properties.bulk_density_megagrams_per_m3[layer];
        const zones = [2]@TypeOf(context.soil_chemistry.non_band_phosphate[0]){ context.soil_chemistry.non_band_phosphate[layer], context.soil_chemistry.band_phosphate[layer] };
        for (zones, fractions) |zone, fraction| {
            result[0] += fraction * water * (zone.dissolved_hpo4_mol_p_per_m3 + zone.dissolved_h2po4_mol_p_per_m3) * p_mass;
            result[1] += fraction * soil_mass * (zone.adsorbed_hpo4_mol_p_per_megagram + zone.adsorbed_h2po4_mol_p_per_megagram) * p_mass;
            result[2] += fraction * water * (zone.aluminum_phosphate_solid_mol_per_m3 + zone.iron_phosphate_solid_mol_per_m3 + zone.dicalcium_phosphate_solid_mol_per_m3 + 3 * zone.hydroxyapatite_solid_mol_per_m3 + 2 * zone.monocalcium_phosphate_solid_mol_per_m3) * p_mass;
        }
    }
    return result;
}

/// SOLUTE-CARRIER-PRECIPITATION-DESYNC-001 / PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001.
///
/// Dissolved soil phosphate has two storage representations and the ledger reads
/// only one of them: `diagnosticPhosphorusOwners_g`'s phosphate owner takes
/// dissolved from the solute transport module's **extensive mol**
/// (`landscape_mass_inventory_phosphorus_ions.zig:256-272`), while
/// `diagnosticRelayerPhosphateOwners_g` takes it from
/// **concentration x water x fraction**. `phosphateImmobileInventory` never reads
/// the dissolved concentration fields at all.
///
/// Printing both at one instant compares the representations directly. The two
/// have different constant bases (soil-mass conventions differ), so read the
/// **per-stage deltas** between consecutive prints, not the absolute gap: the
/// constant basis cancels in a difference. The stage across which the two deltas
/// disagree by 1.10503606265411e-10 g P owns the defective synchronization.
///
/// This exists because four successive mechanisms for that residual were named
/// from code structure and all four were wrong. It measures which representation
/// moves instead of inferring it.
pub fn logPhosphorusRepresentation(context: anytype, comptime stage: []const u8) !void {
    const owners = try diagnosticPhosphorusOwners_g(context);
    const relayer = try diagnosticRelayerPhosphateOwners_g(context);
    // `hourly_cell_conservation.totalPhosphorus` sums FOUR lanes -- residue,
    // organic, phosphate and plant -- but `diagnosticPhosphorusOwners_g` returns
    // only the first three. Summing those three and comparing against booked flux
    // made the uptake publish look like an unbooked +8.4424e-4 g P gain, when the
    // counterpart simply lives in the plant lane. Carry it so the bracket's total
    // is the same quantity the gate audits.
    const plant_g = (try reconstructLandscapeMassBalance(context)).plant_phosphorus_g;
    // Print all three ledger owners, not just phosphate. The four-stage
    // decomposition showed the residual is a mismatch between the organic/residue
    // side (netting -8.46256201977e-4 g P) and the phosphate side (+8.462563124808641e-4):
    // a mineralization pair that must cancel and does not. Establishing that took
    // hand arithmetic over assumed splits because this helper was discarding
    // `owners[0]` and `owners[1]` -- the two values that measure it directly.
    //
    // Note the two bases have different SCOPES as well as different constant
    // offsets: `owners` is whole-landscape (soil + surface litter), while
    // `diagnosticRelayerPhosphateOwners_g` loops soil layers only. A transport
    // movement with no concentration counterpart may therefore be surface litter
    // rather than a representation divergence.
    // Carry the total matrix water with every print. `phosphateImmobileInventory`
    // scales the precipitated phosphate by `water_m3 * zone_fraction`, and that
    // term is ~1192.79 g P -- three orders larger than any flux in this hour. So a
    // purely numerical change in the water carrier re-bases it and manufactures
    // phosphorus with no transfer at all: a relative water change of 9.23e-14
    // (about 416 eps) reproduces the whole 1.1e-10 residual. Printing the carrier
    // beside the inventory makes that ratio checkable at every boundary instead of
    // assumed.
    var matrix_water_m3: f64 = 0;
    for (context.grid.matrix_liquid_water_m3) |volume_m3| matrix_water_m3 += volume_m3;
    // Carry the CELL ledger's cumulative booked phosphorus with every print.
    //
    // A conservation residual is `(after - before) - (input - output)`, so any
    // expression built only from those four cannot localize anything -- four such
    // regroupings were mistaken for attributions in this investigation. Booked
    // flux sampled at a chosen bracket is outside that set: comparing each
    // interval's booked delta against its storage delta identifies the interval
    // whose booking does not match what it moved, which no rearrangement of the
    // hour's totals can do.
    var booked_input_g: f64 = 0;
    var booked_output_g: f64 = 0;
    for (context.hourly_cell_boundary_ledger.cells) |activity| {
        booked_input_g += activity.phosphorus_input_g;
        booked_output_g += activity.phosphorus_output_g;
    }
    std.log.info(
        "phosphorus representation: {s} residue_g={e} organic_g={e} transport_basis_phosphate_g={e} plant_g={e} concentration_dissolved_g={e} concentration_adsorbed_g={e} concentration_precipitated_g={e} matrix_water_m3={e} booked_input_g={e} booked_output_g={e}",
        .{ stage, owners[0], owners[1], owners[2], plant_g, relayer[0], relayer[1], relayer[2], matrix_water_m3, booked_input_g, booked_output_g },
    );
}

/// Water-scaled phosphate mass for one soil layer, evaluated against an
/// **explicit** carrier rather than the live grid array.
///
/// The ledger integrates dissolved and precipitated phosphate as
/// `concentration * water * zone_fraction`, so its value is only meaningful when
/// the concentrations and the carrier are consistent. Between a carrier change
/// and its rebase they are not, and the ledger reads high or low by ~7e-2 g P --
/// which is the entire explanation for the mid-hour swings that misled several
/// rounds of this investigation.
///
/// A carrier rebase is supposed to preserve exactly this product: it sets
/// `C_new = C_old * old_water / new_water` so that `C * carrier` is invariant.
/// Evaluating it against the carrier each concentration is actually valid on
/// therefore isolates the rebase's true roundoff, which is the quantity
/// `previewLayerRoundoff` claims to bound.
pub fn waterScaledPhosphateForLayer(context: anytype, layer: usize, carrier_m3: f64) !f64 {
    const fractions = try context.fertilizer_band.scienceZoneFractionsForFlatIndex(layer);
    const p_mass = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol;
    var total_g: f64 = 0;
    const zones = [2]@TypeOf(context.soil_chemistry.non_band_phosphate[0]){
        context.soil_chemistry.non_band_phosphate[layer],
        context.soil_chemistry.band_phosphate[layer],
    };
    for (zones, [2]f64{ fractions.phosphate_non_band, fractions.phosphate_band }) |zone, fraction|
        total_g += fraction * carrier_m3 * p_mass *
            (zone.dissolved_hpo4_mol_p_per_m3 + zone.dissolved_h2po4_mol_p_per_m3 +
                zone.aluminum_phosphate_solid_mol_per_m3 + zone.iron_phosphate_solid_mol_per_m3 +
                zone.dicalcium_phosphate_solid_mol_per_m3 + 3 * zone.hydroxyapatite_solid_mol_per_m3 +
                2 * zone.monocalcium_phosphate_solid_mol_per_m3);
    if (!std.math.isFinite(total_g)) return error.InvalidWaterScaledPhosphateInventory;
    return total_g;
}

pub fn diagnosticAmmoniumOwners_g_n(context: anytype) ![6]f64 {
    const molar_mass = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol;
    var result: [6]f64 = @splat(0);
    for (0..context.grid.cell_count) |cell| {
        const surface = context.surface_litter_chemistry.cells[cell];
        const aqueous_carrier_m3 = try ecosys.surface_litter_chemistry_carrier_rebase.effectiveAqueousCarrierM3(
            context.surface_precipitation.litter_water_m3[cell],
            context.surface_litter_chemistry.dry_reference_water_m3[cell],
        );
        result[0] += aqueous_carrier_m3 * (surface.ammonium_mol_per_m3 + surface.ammonia_mol_per_m3) * molar_mass;
        result[1] += context.surface_litter_geometry.dry_mass_megagrams[cell] * surface.exchange.ammonium_mol_per_megagram * molar_mass;
        const fertilizer = context.surface_litter_fertilizer.cells[cell];
        result[2] += (fertilizer.ammonium_mol_n + fertilizer.ammonia_mol_n + fertilizer.urea_mol_n) * molar_mass;
    }
    for (0..context.grid.layer_count) |layer| {
        const matrix = try context.mineral_nitrogen_transport.matrix.cellAmountsConst(layer);
        const macro = try context.mineral_nitrogen_transport.macropore.cellAmountsConst(layer);
        inline for ([_]ecosys.mineral_nitrogen_transport.Species{ .ammonium_non_band, .ammonium_band, .ammonia_non_band, .ammonia_band }) |species| result[3] += (matrix[@intFromEnum(species)] + macro[@intFromEnum(species)]) * molar_mass;
        const exchange = context.soil_chemistry.cation_exchange_mol_per_megagram[layer];
        result[4] += context.soil_solver_properties.matrix_bulk_volume_m3[layer] * context.soil_solver_properties.bulk_density_megagrams_per_m3[layer] * (exchange.ammonium_non_band + exchange.ammonium_band) * molar_mass;
        const fertilizer = context.soil_fertilizer_inventory.soil[layer];
        result[5] += (fertilizer.broadcast_ammonium_mol_n + fertilizer.broadcast_ammonia_mol_n + fertilizer.broadcast_urea_mol_n + fertilizer.banded_ammonium_mol_n + fertilizer.banded_ammonia_mol_n + fertilizer.banded_urea_mol_n) * molar_mass;
    }
    return result;
}

pub fn diagnosticSnowNitrogen_g(storage: ecosys.landscape_mass_inventory.Storage) f64 {
    return storage.dinitrogen_nitrogen_g + storage.ammonium_nitrogen_g + storage.nitrate_nitrogen_g;
}

pub fn diagnosticSnowSpeciesNitrogen_g(amounts: []const f64) f64 {
    var total_g_n: f64 = 0;
    const species_count = ecosys.snow_solute_transport.species_count;
    var first: usize = 0;
    while (first < amounts.len) : (first += species_count) {
        inline for ([_]ecosys.snow_solute_transport.Species{
            .dinitrogen_nitrogen,
            .nitrous_oxide_nitrogen,
            .ammonium_nitrogen,
            .ammonia_nitrogen,
            .nitrate_nitrogen,
        }) |species| total_g_n += amounts[first + @intFromEnum(species)];
    }
    return total_g_n;
}

pub fn diagnosticSnowDischargeNitrogen_g(discharge: []const ecosys.snow_solute_transport.SurfaceDischarge) f64 {
    var total_g_n: f64 = 0;
    for (discharge) |cell| {
        total_g_n += diagnosticSnowSpeciesNitrogen_g(&cell.litter_g);
        total_g_n += diagnosticSnowSpeciesNitrogen_g(&cell.soil_nonband_g);
        total_g_n += diagnosticSnowSpeciesNitrogen_g(&cell.soil_band_g);
    }
    return total_g_n;
}

fn debugCarbonComponents(context: anytype, totals: ecosys.mass_balance_audit.Totals, label: []const u8) !void {
    const surface_organic_storage = try ecosys.landscape_mass_inventory.aggregateSurfaceOrganic(
        context.surface_organic,
    );
    const soil_organic_storage = try ecosys.landscape_mass_inventory.aggregateSoilOrganic(
        context.soil_organic,
        context.grid,
    );
    const area = totals.landscape_area_m2;
    std.log.debug("{s} components: surf_resid={e} soil_resid={e} soil_org={e} co2={e} cum_co2in={e} cum_cout={e}", .{
        label,
        surface_organic_storage.residue_carbon_g / area,
        soil_organic_storage.residue_carbon_g / area,
        soil_organic_storage.organic_carbon_g / area,
        totals.carbon_dioxide_carbon_g / area,
        totals.cumulative_carbon_dioxide_input_g / area,
        totals.cumulative_carbon_output_g / area,
    });
    // Fine-grained surface sub-pools (cell=0 only)
    const so = context.surface_organic;
    const msub = ecosys.soil_organic_initialization.microbial_substrate_count;
    const mpop = ecosys.soil_organic_initialization.microbial_population_count;
    const mfrac = ecosys.soil_organic_initialization.kinetic_fraction_count;
    const sub = ecosys.soil_organic_initialization.substrate_count;
    const rfrac = ecosys.soil_organic_initialization.residue_fraction_count;
    const sfrac = ecosys.soil_organic_initialization.structural_fraction_count;
    var surf_microbial: f64 = 0;
    for (0..msub) |s| {
        if (s == 4) continue;
        const first = (s * mpop) * mfrac;
        for (so.microbial[first .. first + mpop * mfrac]) |p| surf_microbial += p.carbon_g_c;
    }
    var surf_residue: f64 = 0;
    for (0..3) |s| {
        const first = s * rfrac;
        for (so.residue[first .. first + rfrac]) |p| surf_residue += p.carbon_g_c;
        surf_residue += so.dissolved[s].carbon_g_c + so.adsorbed[s].carbon_g_c;
        surf_residue += so.dissolved_acetate_carbon_g_c[s] + so.adsorbed_acetate_carbon_g_c[s];
    }
    var surf_structural: f64 = 0;
    for (so.structural[0 .. sub * sfrac]) |p| surf_structural += p.carbon_g_c;
    // Also log the EXCLUDED surface pools (substrate 3-4 residue/dissolved/adsorbed, substrate 4 microbial)
    var surf_excluded_resid: f64 = 0;
    for (3..sub) |s| { // substrates 3 and 4
        const first = s * rfrac;
        for (so.residue[first .. first + rfrac]) |p| surf_excluded_resid += p.carbon_g_c;
        surf_excluded_resid += so.dissolved[s].carbon_g_c + so.adsorbed[s].carbon_g_c;
        surf_excluded_resid += so.dissolved_acetate_carbon_g_c[s] + so.adsorbed_acetate_carbon_g_c[s];
    }
    var surf_microbial_sub4: f64 = 0;
    {
        const first = (4 * mpop) * mfrac;
        for (so.microbial[first .. first + mpop * mfrac]) |p| surf_microbial_sub4 += p.carbon_g_c;
    }
    std.log.debug("{s} surf subpools: microbial={e} residue_fracs={e} structural={e} excluded_resid={e} excluded_micro4={e}", .{
        label,                      surf_microbial / area,      surf_residue / area, surf_structural / area,
        surf_excluded_resid / area, surf_microbial_sub4 / area,
    });
    // Fine-grained soil microbial by substrate category (active layers only)
    const grid = context.grid;
    var soil_microbial_resid: f64 = 0;
    var soil_microbial_org: f64 = 0;
    for (0..grid.cell_count) |cell| {
        const active = grid.active_soil_layer_count[cell];
        for (0..active) |layer| {
            const layer_cell = cell * grid.soil_layer_capacity + layer;
            const first_m = layer_cell * msub * mpop * mfrac;
            for (0..msub) |s| {
                const m_first = first_m + s * mpop * mfrac;
                for (context.soil_organic.microbial[m_first .. m_first + mpop * mfrac]) |p| {
                    if (s == 4) soil_microbial_org += p.carbon_g_c else soil_microbial_resid += p.carbon_g_c;
                }
            }
        }
    }
    std.log.debug("{s} soil microbial: resid={e} org={e}", .{
        label, soil_microbial_resid / area, soil_microbial_org / area,
    });
    // Separate gas-CO2 from bicarbonate/carbonate to diagnose balance drift.
    var gas_co2_g: f64 = 0;
    var gas_ch4_g: f64 = 0;
    const gas_state_dbg = context.gas_transport;
    for (0..grid.cell_count) |cell| {
        const active = grid.active_soil_layer_count[cell];
        for (0..active) |layer| {
            const layer_cell = cell * grid.soil_layer_capacity + layer;
            const first = layer_cell * ecosys.gas_transport.species_count;
            const end = first + ecosys.gas_transport.species_count;
            const gaseous = gas_state_dbg.gaseous_mass_g[first..end];
            const dissolved = gas_state_dbg.dissolved_mass_g[first..end];
            const macropore = gas_state_dbg.macropore_dissolved_mass_g[first..end];
            const band = gas_state_dbg.band_dissolved_mass_g[first..end];
            gas_co2_g += gaseous[@intFromEnum(ecosys.gas_transport.Species.carbon_dioxide)] +
                dissolved[@intFromEnum(ecosys.gas_transport.Species.carbon_dioxide)] +
                macropore[@intFromEnum(ecosys.gas_transport.Species.carbon_dioxide)] +
                band[@intFromEnum(ecosys.gas_transport.Species.carbon_dioxide)];
            gas_ch4_g += gaseous[@intFromEnum(ecosys.gas_transport.Species.methane)] +
                dissolved[@intFromEnum(ecosys.gas_transport.Species.methane)] +
                macropore[@intFromEnum(ecosys.gas_transport.Species.methane)] +
                band[@intFromEnum(ecosys.gas_transport.Species.methane)];
        }
    }
    // Bicarbonate/carbonate from micropore + macropore solute amounts.
    var bicarbonate_g: f64 = 0;
    const micro = context.micropore_solute_state;
    const macro = context.macropore_solute_state;
    for (0..grid.cell_count) |cell| {
        const active = grid.active_soil_layer_count[cell];
        for (0..active) |layer| {
            const layer_cell = cell * grid.soil_layer_capacity + layer;
            const micro_amounts = try micro.cellAmountsConst(layer_cell);
            const macro_amounts = try macro.cellAmountsConst(layer_cell);
            inline for (@typeInfo(ecosys.solute_transport_species.AqueousSpecies).@"enum".fields) |field| {
                const species: ecosys.solute_transport_species.AqueousSpecies = @enumFromInt(field.value);
                const is_carbonate_carrier = switch (species) {
                    .carbonate,
                    .bicarbonate,
                    .calcium_carbonate,
                    .calcium_bicarbonate,
                    .magnesium_carbonate,
                    .magnesium_bicarbonate,
                    .sodium_carbonate,
                    => true,
                    else => false,
                };
                if (is_carbonate_carrier) {
                    bicarbonate_g += (micro_amounts[field.value] + macro_amounts[field.value]) * 12.0;
                }
            }
        }
    }
    // Chemistry CO2 and bicarbonate — CO2 is synced to gas_transport.dissolved after h-step,
    // bicarbonate is exported to micropore solute after h-step. Both are counted in EXEC
    // AFTER the first h-step, but at baseline (before any h-step) they are NOT yet counted.
    var chem_co2_g: f64 = 0;
    var chem_bicarb_g: f64 = 0;
    for (0..grid.cell_count) |cell| {
        const active = grid.active_soil_layer_count[cell];
        for (0..active) |layer| {
            const layer_cell = cell * grid.soil_layer_capacity + layer;
            const water_m3 = grid.matrix_liquid_water_m3[layer_cell];
            chem_co2_g += context.soil_chemistry.aqueous[layer_cell].carbon_dioxide * 12.0 * water_m3;
            chem_bicarb_g += context.soil_chemistry.aqueous[layer_cell].bicarbonate * 12.0 * water_m3;
        }
    }
    // Litter chemistry CO2 — not synced to litter_gas_transport, not in EXEC balance.
    var litter_chem_co2_g: f64 = 0;
    var litter_chem_bicarb_g: f64 = 0;
    var litter_gas_co2_g: f64 = 0;
    {
        const litter_chem = context.surface_litter_chemistry;
        const litter_water = context.surface_precipitation.litter_water_m3;
        for (0..grid.cell_count) |cell| {
            const aqueous_carrier_m3 = try ecosys.surface_litter_chemistry_carrier_rebase.effectiveAqueousCarrierM3(
                litter_water[cell],
                litter_chem.dry_reference_water_m3[cell],
            );
            litter_chem_co2_g += litter_chem.cells[cell].carbon_dioxide_mol_per_m3 * 12.0 * aqueous_carrier_m3;
            litter_chem_bicarb_g += litter_chem.cells[cell].bicarbonate_mol_per_m3 * 12.0 * aqueous_carrier_m3;
        }
    }
    {
        const litter_gas = context.litter_gas_transport;
        const co2_species = @intFromEnum(ecosys.gas_transport.Species.carbon_dioxide);
        for (0..grid.cell_count) |cell| {
            const base = cell * ecosys.gas_transport.species_count;
            litter_gas_co2_g += litter_gas.gaseous_mass_g[base + co2_species] +
                litter_gas.dissolved_mass_g[base + co2_species];
        }
    }
    std.log.debug("{s} co2 split: gas_co2={e} gas_ch4={e} bicarbonate={e} chem_co2={e} chem_bicarb={e} litter_chem_co2={e} litter_chem_bicarb={e} litter_gas_co2={e}", .{
        label,                    gas_co2_g / area,            gas_ch4_g / area,        bicarbonate_g / area, chem_co2_g / area, chem_bicarb_g / area,
        litter_chem_co2_g / area, litter_chem_bicarb_g / area, litter_gas_co2_g / area,
    });
}

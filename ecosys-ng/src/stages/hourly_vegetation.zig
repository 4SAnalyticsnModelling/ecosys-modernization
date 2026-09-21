//! `hourly_science` declarations: vegetation.
//!
//! Split out of `hourly_science.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ecosys = @import("ecosys_ng");
const biogeochemistry_batches = @import("biogeochemistry_batches.zig");
const diagnostics = @import("diagnostics.zig");
const plant_daily = @import("plant_daily.zig");
const root_processes = @import("root_processes.zig");
const soil_chemistry_convergence = @import("soil_chemistry_convergence.zig");
const surface_litter_convergence = @import("surface_litter_convergence.zig");
const tile_kernels = @import("tile_kernels.zig");
const group_support = @import("hourly_process_support.zig");
const geometry_disturbance = @import("hourly_geometry_disturbance.zig");

/// UPTAKE tail, GROSUB and EXTRACT. Living STOMATE/root hydraulics are the
/// immediately preceding post-WATSUB hook; this owner consumes that accepted
/// publication and completes plant/root state before SOLUTE/TRNSFR.
pub noinline fn advanceUptakeGrowthAndExtract(
    context: anytype,
    hour_of_day: u8,
    weather_header_by_cell: []const ecosys.weather.Header,
    plant_calendar: anytype,
) !void {
    var plant_internal_activity = try ecosys.plant_internal_root_shoot_activity.State.init(
        context.allocator,
        context.grid.cell_count,
        context.grid.soil_layer_capacity,
    );
    defer plant_internal_activity.deinit();
    try prepareCanopyAndSurfaceCarriers(&context);
    try advanceAcceptedRootUptake(&context);
    try beginRootGrowthAndSynchronizePhosphate(
        &context,
        plant_calendar,
        &plant_internal_activity,
    );
    try advanceCanopyGrowthAndExchange(
        context,
        hour_of_day,
        weather_header_by_cell,
        plant_calendar,
        &plant_internal_activity,
    );
}

/// GROSUB shoot/standing-dead combustion and the EXTRACT mineral publication
/// that immediately follows it in the legacy source. These products must be
/// present in the litter solution before SOLUTE; the later REDIST owner only
/// consumes the accepted fire ledgers and must not recompute combustion.
pub noinline fn produceCanopyStandingDeadFireBeforeSolute(context: anytype) !void {
    const any_fire_active = std.mem.indexOfScalar(bool, context.fire_active_this_hour, true) != null;
    if (!any_fire_active) return;
    const roots = if (context.plant_roots.*) |*value| value else return;
    const canopy = if (context.detailed_canopy.*) |*value| value else return;

    try ecosys.plant_shoot_fire.apply(
        canopy,
        context.canopy_layer_controls,
        roots,
        context.canopy_cell_area_m2,
        context.fire_active_this_hour,
        1,
        context.salinity_enabled_by_cell,
        context.runscript.plant_fire_combustion_parameters,
        context.current_canopy_air_temperature_k,
        context.current_canopy_oxygen_content_g_o,
        context.current_canopy_o2_umol_per_mol,
        context.current_canopy_ch4_umol_per_mol,
        context.delayed_live_canopy_combustion_heat_megajoules,
        context.delayed_standing_dead_combustion_heat_megajoules,
        context.surface_fire_exchange,
        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
    );
    for (context.fire_active_this_hour, 0..) |fire_active, cell| {
        if (!fire_active) continue;
        try context.surface_fire_exchange.publishCanopyFireSurfaceSolutes(
            cell,
            context.surface_litter_chemistry,
            context.surface_precipitation.litter_water_m3,
            context.salinity_enabled_by_cell[cell],
            context.config.physical_tolerance.waterVolume(
                context.surface_precipitation.litter_water_m3[cell],
            ),
        );
    }
    try context.landscape_boundary_ledger.accumulateAcceptedLegacyPlantSaltInput(
        canopy.branch_combustion_salt_loss_by_species_mol_per_h,
    );
}

noinline fn prepareCanopyAndSurfaceCarriers(context: anytype) !void {
    if (context.canopy_precipitation_retention.*) |*retention| {
        if (context.canopy_surface_exchange.*) |exchange|
            try ecosys.canopy_precipitation_retention.state_updateSurfaceWater(retention, exchange.intercepted_water_change_m3_per_h, context.standing_dead_evaporation_m3_per_h, 1)
        else
            try ecosys.canopy_precipitation_retention.state_updateRetention(retention, 1);
    }
    for (0..context.grid.cell_count) |cell| context.transport_hydrology.snow_surface_carrier_volume_m3[cell] = context.surface_precipitation.solid_snow_water_equivalent_m3[cell];
    // Living-canopy energy is published by the coupled TKCY/root-water
    // transaction in hourly_snow_energy before downstream biochemistry.
    if (context.detailed_canopy.*) |*canopy| {
        const angular_sample_count = try std.math.mul(usize, context.canopy_geometry.leaf_inclination_sine.len, context.canopy_geometry.leaf_azimuth_radians.len);
        const samples_per_node = try std.math.mul(usize, context.runscript.canopy_layer_count, angular_sample_count);
        try group_support.ensureCanopyGrowthNodeTopology(canopy, &context.plant_growth_stages.*.?, samples_per_node);
        var biochemistry_context: ecosys.canopy_biochemistry.ApplyContext = .{
            .canopy = canopy,
            .parameters_by_plant = context.canopy_biochemistry_parameters,
            .c4_carbon_parameters = context.runscript.c4_carbon_parameters,
            .canopy_temperature_k_by_plant = context.plants.canopy_temperature_k,
            .atmospheric_co2_umol_per_mol_by_cell = context.current_canopy_co2_umol_per_mol_by_cell,
            .dormancy = &context.plant_dormancy.*.?,
            .branch_development = &context.branch_development.*.?,
            .growth_stages = &context.plant_growth_stages.*.?,
            .dormancy_parameters_by_plant = context.development_dormancy_parameters,
            .stress_parameters = context.runscript.canopy_stress_parameters,
            .annual_termination_hours_without_grain_fill = context.runscript.root_metabolism_parameters.annual_termination_hours_without_grain_fill,
            .presence_threshold_g_per_plant = context.runscript.plant_pool_parameters.branch_structural_presence_g_per_plant,
            .timestep_h = 1,
        };
        try tile_kernels.runKernelAcrossSerialTiles(context.*, &biochemistry_context, ecosys.canopy_biochemistry.applyTile);
    }
}

noinline fn advanceAcceptedRootUptake(context: anytype) !void {
    if (context.plant_water_balance.* != null) {
        // UPTAKE computes UPWTR but does not mutate VOLW. Root gas, exudate,
        // and mineral nutrient uptake below must therefore consume WATSUB's
        // accepted carrier (`uptake.f:2855--3672`). EXTRACT only aggregates
        // TUPWTR/TUPHT; their physical publication is deferred to REDIST.
        try ecosys.plant_water_balance.updateDailyMinimumCanopyWaterPotential(&context.detailed_canopy.*.?, context.plants);
        try ecosys.plant_root_gas_exchange.refreshOxygenDemand(&context.plant_roots.*.?, context.root_gas_parameters);
    }
    // NITRO has already changed authoritative NH4/NH3/NO3/NO2. Refresh its
    // extensive matrix owner after any root-water carrier change and before
    // root gas/nutrient consumers bind transient ammonia; otherwise the
    // hour-start transport mirror can overwrite same-hour NITRO products.
    // Keep this outside the optional water-balance block: a complete root
    // state is the consumer invariant, not the presence of that workspace.
    try context.mineral_nitrogen_transport.refreshMatrixFromReactionState(
        context.soil_chemistry,
        context.soil_reactive_nitrogen,
        context.grid.matrix_liquid_water_m3,
        context.fertilizer_band,
        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        context.config.physical_tolerance.water_volume_m3,
    );
    // UPTAKE before GROSUB (`soil.f:175,182`): the root oxygen constraint
    // `WFR` must be current-hour before `applyRootMetabolism` reads
    // `roots.oxygen_process_constraint_fraction` (see
    // `docs/binding_requests/A7b_01_root_oxygen_constraint.md`). Oxygen is
    // excluded from `plant_root_gas_transport.advance`'s passive-gas loop
    // (`non_oxygen_gases`), so this competitive, demand-limited solve runs as
    // its own pass over the same cell/layer/species/domain nest and must
    // precede both `advance` (called below) and `applyRootMetabolism`.
    if (context.plant_roots.*) |*roots| if (context.plant_water_workspace.*) |*water| if (context.plant_phenology.*) |phenology| {
        _ = try ecosys.plant_root_gas_transport.advanceOxygen(
            context.allocator,
            roots,
            water,
            context.grid,
            context.soil_solver_properties,
            context.gas_transport,
            context.root_gas_parameters,
            context.root_biological_domain_count_by_plant,
            phenology.active,
            context.soil_reactive_nitrogen.previous_total_aerobic_oxygen_demand_g_o,
            .{
                .liquid_tortuosity_coefficient = context.runscript.root_nutrient_parameters.liquid_tortuosity_coefficient,
                .minimum_active_layer_thickness_m = context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
                .minimum_population_fraction = context.runscript.root_nutrient_parameters.minimum_population_uptake_fraction_multiplier,
                .oxygen_half_saturation_g_o_per_m3 = context.soil_nitrogen_parameters.oxygen_uptake.oxygen_half_saturation_g_o_per_m3,
                .significance_threshold_g_o = context.config.physical_tolerance.oxygen(blk: {
                    var scale_g_o: f64 = 0;
                    for (context.soil_reactive_nitrogen.previous_total_aerobic_oxygen_demand_g_o) |demand_g_o| scale_g_o = @max(scale_g_o, @abs(demand_g_o));
                    break :blk scale_g_o;
                }),
                .significance_threshold_fraction = context.config.physical_tolerance.fraction(1),
            },
        );
    };
    // UPTAKE 1545--2767 exchanges root gases, and 2850--3708 computes
    // exudation plus NH4/NO3/PO4 uptake. Both consume the pre-GROSUB root
    // pools and must publish before GROSUB mutates respiration, mobile pools,
    // morphology or demand. Keeping only O2 ahead of GROSUB changed all other
    // same-hour uptake inputs while still appearing superficially ordered.
    if (context.plant_roots.*) |*roots| if (context.plant_water_workspace.*) |*water| if (context.plant_phenology.*) |phenology| {
        try ecosys.soil_ammonia_phase_bridge.refreshTransientFromMineral(
            context.mineral_nitrogen_transport,
            context.gas_transport,
            context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        );
        try ecosys.plant_root_gas_transport.advance(
            roots,
            water,
            context.grid,
            context.soil_solver_properties,
            context.gas_transport,
            context.root_gas_parameters,
            context.current_atmospheric_gas_concentration_g_per_m3,
            context.root_biological_domain_count_by_plant,
            phenology.active,
            context.fertilizer_band,
            .{
                .liquid_tortuosity_coefficient = context.runscript.root_nutrient_parameters.liquid_tortuosity_coefficient,
                .minimum_aqueous_volume_m3 = context.config.physical_tolerance.waterVolume(blk: {
                    var scale_m3: f64 = 0;
                    for (roots.aqueous_volume_m3) |volume_m3| scale_m3 = @max(scale_m3, @abs(volume_m3));
                    break :blk scale_m3;
                }),
                .minimum_gaseous_volume_m3 = context.config.physical_tolerance.waterVolume(blk: {
                    var scale_m3: f64 = 0;
                    for (roots.gaseous_volume_m3) |volume_m3| scale_m3 = @max(scale_m3, @abs(volume_m3));
                    break :blk scale_m3;
                }),
                .minimum_root_surface_area_m2 = context.config.physical_tolerance.area(blk: {
                    var scale_m2: f64 = 0;
                    for (roots.root_surface_area_m2_per_plant) |area_m2| scale_m2 = @max(scale_m2, @abs(area_m2));
                    break :blk scale_m2;
                }),
                .absolute_tolerance_g_by_species = .{
                    context.config.nonlinear_tolerance.carbon_g,
                    context.config.nonlinear_tolerance.carbon_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    2 * context.config.nonlinear_tolerance.amount_mol,
                    context.config.nonlinear_tolerance.oxygen_g,
                },
                .relative_tolerance = context.config.nonlinear_tolerance.relative,
                .maximum_iterations = context.iteration_limits.gas_max_iterations,
            },
        );
        try ecosys.soil_ammonia_phase_bridge.publishTransientToMineral(
            context.mineral_nitrogen_transport,
            context.gas_transport,
            context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        );
        try context.mineral_nitrogen_transport.publishMatrix(
            context.soil_chemistry,
            context.soil_reactive_nitrogen,
            context.fertilizer_band,
            context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
            context.config.physical_tolerance.water_volume_m3,
        );
    };
    try root_processes.applyRootNutrientUptake(context.*);
}

noinline fn beginRootGrowthAndSynchronizePhosphate(
    context: anytype,
    plant_calendar: anytype,
    plant_internal_activity: *ecosys.plant_internal_root_shoot_activity.State,
) !void {
    // soil.f:175,182 orders UPTAKE before GROSUB. UPTAKE must consume the
    // preceding pass's WSRTL (`uptake.f:1679--1694`); only then does GROSUB's
    // hourly preamble clear it before rebuilding from current structural N/P
    // (`grosub.f:371--374,6412--6423,7018--7031`).
    if (context.plant_roots.*) |*roots| roots.resetGrosubProteinCarbon();
    // HFUNC branch/dormancy/development preparation already ran in the
    // post-WATSUB hook immediately before canopy UPTAKE/STOMATE. Do not
    // advance it again here. GROSUB starts only after every UPTAKE owner above
    // has committed, matching soil.f:175--182.
    try plant_daily.applyPlantStorageRemobilization(context.*, plant_calendar, plant_internal_activity);
    try root_processes.applyRootMetabolism(context.*, plant_internal_activity);
    try plant_daily.applyStorageExhaustionMortality(context.*, plant_calendar);
    // UPTAKE publishes accepted HPO4/H2PO4 withdrawals into chemistry before
    // SOLUTE. Keep the four extensive transport coordinates synchronized at
    // this ownership boundary; SOLUTE will subsequently export its accepted
    // reaction result on the same unchanged water carrier.
    for (0..context.grid.cell_count) |cell| {
        for (0..context.grid.active_soil_layer_count[cell]) |local_layer| {
            const layer = try context.grid.layerIndex(cell, local_layer);
            if (context.grid.matrix_liquid_water_m3[layer] == 0) continue;
            try ecosys.soil_aqueous_transport_bridge.synchronizeCellAfterCarrierChange(
                context.soil_chemistry,
                context.micropore_solute_state,
                layer,
                context.grid.matrix_liquid_water_m3[layer],
                &.{
                    .non_band_hpo4,
                    .non_band_h2po4,
                    .band_hpo4,
                    .band_h2po4,
                },
                context.fertilizer_band,
                ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[cell]),
            );
        }
    }
}

/// REDIST 5947--6004 is the sole owner of accepted EXTRACT TUPWTR/TUPHT.
/// UPTAKE, SOLUTE, TRNSFR/TRNSFRS, and EROSION all consume WATSUB's carrier;
/// only after they finish may root water change soil storage. The state update
/// preflights every layer before mutation, and the enclosing outer-hour
/// transaction owns both the scientific state and these same-hour ledgers.
fn addWaterRoundoffUpward(left: f64, right: f64) !f64 {
    if (!std.math.isFinite(left) or left < 0 or
        !std.math.isFinite(right) or right < 0)
        return error.InvalidWaterStorageUpdateArithmeticProvenance;
    if (left == 0) return right;
    if (right == 0) return left;
    const sum = left + right;
    if (!std.math.isFinite(sum))
        return error.InvalidWaterStorageUpdateArithmeticProvenance;
    return std.math.nextAfter(f64, sum, std.math.inf(f64));
}

fn addHeatRoundoffUpward(left: f64, right: f64) !f64 {
    if (!std.math.isFinite(left) or left < 0 or
        !std.math.isFinite(right) or right < 0)
        return error.InvalidHeatStorageUpdateArithmeticProvenance;
    if (left == 0) return right;
    if (right == 0) return left;
    const sum = left + right;
    if (!std.math.isFinite(sum))
        return error.InvalidHeatStorageUpdateArithmeticProvenance;
    return std.math.nextAfter(f64, sum, std.math.inf(f64));
}

fn applyRootWaterHeatAtRedistEntry(context: anytype) !void {
    if (context.plant_water_balance.* == null) return;

    const root_water_change_m3 = try context.allocator.alloc(f64, context.grid.layer_count);
    defer context.allocator.free(root_water_change_m3);
    const root_convective_heat_megajoules = try context.allocator.alloc(f64, context.grid.layer_count);
    defer context.allocator.free(root_convective_heat_megajoules);
    const chemistry_rebase_roundoff = try context.allocator.alloc(
        ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
        context.grid.layer_count,
    );
    defer context.allocator.free(chemistry_rebase_roundoff);
    const root_water_storage_roundoff_m3 = try context.allocator.alloc(
        f64,
        context.grid.layer_count,
    );
    defer context.allocator.free(root_water_storage_roundoff_m3);
    const root_heat_storage_roundoff_megajoules = try context.allocator.alloc(
        f64,
        context.grid.layer_count,
    );
    defer context.allocator.free(root_heat_storage_roundoff_megajoules);
    const chemistry_rebase_inventory_fractions = try context.allocator.alloc(
        ecosys.soil_chemistry_water_carrier_rebase.InventoryFractions,
        context.grid.layer_count,
    );
    defer context.allocator.free(chemistry_rebase_inventory_fractions);
    for (chemistry_rebase_inventory_fractions, 0..) |*destination, layer| {
        const fractions = try context.fertilizer_band
            .scienceZoneFractionsForFlatIndex(layer);
        destination.* = .{
            .phosphate_non_band = fractions.phosphate_non_band,
            .phosphate_band = fractions.phosphate_band,
        };
    }
    const zero_combustion_heat_megajoules = try context.allocator.alloc(f64, context.grid.layer_count);
    defer context.allocator.free(zero_combustion_heat_megajoules);
    @memset(zero_combustion_heat_megajoules, 0);
    try ecosys.plant_root_water_storage_state_update.state_update(
        &context.plant_roots.*.?,
        context.grid,
        context.soil_chemistry,
        context.soil_thermal,
        context.root_biological_domain_count_by_plant,
        chemistry_rebase_inventory_fractions,
        context.canopy_cell_area_m2,
        12.0,
        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
        context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        root_water_change_m3,
        root_convective_heat_megajoules,
        chemistry_rebase_roundoff,
        root_water_storage_roundoff_m3,
        root_heat_storage_roundoff_megajoules,
    );
    try ecosys.layer_local_conservation.accumulateAcceptedChemistryRebaseRoundoff(
        context.hourly_cell_boundary_ledger,
        context.hourly_layer_boundary_ledger,
        chemistry_rebase_roundoff,
        12.0,
        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
    );
    try context.landscape_boundary_ledger.accumulateAcceptedSubsurfaceCombustionAndRootHeat(
        context.grid.active_soil_layer_count,
        context.grid.soil_layer_capacity,
        zero_combustion_heat_megajoules,
        root_convective_heat_megajoules,
    );
    try ecosys.hourly_cell_conservation.accumulateSubsurfaceCombustionAndRootHeat(
        context.hourly_cell_boundary_ledger,
        context.grid.active_soil_layer_count,
        context.grid.soil_layer_capacity,
        zero_combustion_heat_megajoules,
        root_convective_heat_megajoules,
    );
    try ecosys.layer_local_conservation.accumulateRootWaterHeatUptake(
        context.hourly_layer_boundary_ledger,
        context.grid.active_soil_layer_count,
        root_water_change_m3,
        root_convective_heat_megajoules,
    );
    for (0..context.grid.layer_count) |layer|
        context.soil_hourly_workspace.heat_capacity_megajoules_per_k[layer] =
            context.soil_thermal.total_heat_capacity_megajoules_per_m3_k[layer] *
            context.soil_thermal.layer_volume_m3[layer];

    // The concentration owner was rebased in the atomic state update. Keep
    // every extensive amount owner's carrier and each physical derived mirror
    // coherent with the accepted REDIST storage exactly once.
    try context.transport_hydrology.syncStorage(context.grid, context.snow_transport);
    @memcpy(context.micropore_solute_state.water_volume_m3, context.grid.matrix_liquid_water_m3);
    @memcpy(context.macropore_solute_state.water_volume_m3, context.grid.macropore_liquid_water_m3);
    @memcpy(context.mineral_nitrogen_transport.matrix.water_volume_m3, context.grid.matrix_liquid_water_m3);
    @memcpy(context.mineral_nitrogen_transport.macropore.water_volume_m3, context.grid.macropore_liquid_water_m3);
    @memcpy(context.gas_transport.air_volume_m3, context.grid.air_volume_m3);
    @memcpy(context.gas_transport.temperature_k, context.grid.soil_temperature_k);
    const pending = context.hourly_layer_boundary_ledger
        .pending_water_storage_roundoff_allowance_m3_by_scope;
    const pending_heat = context.hourly_layer_boundary_ledger
        .pending_heat_storage_roundoff_allowance_megajoules_by_scope;
    if (pending.len != try context.hourly_layer_boundary_ledger.layout.scopeCount())
        return error.WaterStorageUpdateProvenanceDimensionMismatch;
    if (pending_heat.len != pending.len)
        return error.HeatStorageUpdateProvenanceDimensionMismatch;
    // Preflight the full append so no late invalid certificate can publish a
    // partial set of layer bounds.
    for (0..context.grid.cell_count) |cell| for (0..context.grid.active_soil_layer_count[cell]) |local_layer| {
        const layer = try context.grid.layerIndex(cell, local_layer);
        const scope = try context.hourly_layer_boundary_ledger.layout.index(.{
            .kind = .soil_layer,
            .cell = cell,
            .layer = local_layer,
        });
        _ = try addWaterRoundoffUpward(pending[scope], root_water_storage_roundoff_m3[layer]);
        _ = try addHeatRoundoffUpward(
            pending_heat[scope],
            root_heat_storage_roundoff_megajoules[layer],
        );
    };
    for (0..context.grid.cell_count) |cell| for (0..context.grid.active_soil_layer_count[cell]) |local_layer| {
        const layer = context.grid.layerIndex(cell, local_layer) catch unreachable;
        const scope = context.hourly_layer_boundary_ledger.layout.index(.{
            .kind = .soil_layer,
            .cell = cell,
            .layer = local_layer,
        }) catch unreachable;
        pending[scope] = addWaterRoundoffUpward(
            pending[scope],
            root_water_storage_roundoff_m3[layer],
        ) catch unreachable;
        pending_heat[scope] = addHeatRoundoffUpward(
            pending_heat[scope],
            root_heat_storage_roundoff_megajoules[layer],
        ) catch unreachable;
    };
}

/// REDIST plus end-of-hour accounting. EROSION and every transport owner have
/// completed before this function is entered.
pub fn finalizeRedistAndLedgers(
    context: anytype,
    diagnostic_first_hour: anytype,
    diagnostic_previous_p_g: anytype,
    snow_phase_change_report: anytype,
    snow_vapor_equilibrium_report: anytype,
    subsurface_irrigation_chemistry_parameters: anytype,
) !void {
    try applyRootWaterHeatAtRedistEntry(context);
    // REDIST DORGC is the source-signed accepted loss from all soil organic C owners over
    // the complete hour, including microbial, residue, dissolved, adsorbed,
    // acetate, and structural pools.
    try ecosys.soil_organic_carbon_change.publishAcceptedHourlyChange(
        context.soil_organic,
        context.soil_organic_carbon_at_hour_start_g_c,
        context.erosion_organic_carbon_net_change_g_c,
        context.soil_organic_carbon_change_g_c_per_h,
    );
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "before_geometry_disturbance_finalize");
    try diagnostics.traceIssue078SoilPoreOverfill(context, "before_geometry_disturbance_finalize");
    try geometry_disturbance.finalize(context);
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_geometry_disturbance_finalize");
    try diagnostics.traceIssue078SoilPoreOverfill(context, "after_geometry_disturbance_finalize");
    // REDIST HEATIN precipitation term. Publish only after every hourly
    // process above has accepted its state. Rainfall already includes the
    // runtime irrigation addition; using the pre-routing atmospheric depths
    // also counts canopy-retained water without double-counting snow, litter,
    // or soil ingress.
    const precipitation_heat_megajoules_by_cell = try context.allocator.alloc(f64, context.grid.cell_count);
    defer context.allocator.free(precipitation_heat_megajoules_by_cell);
    try context.landscape_boundary_ledger.accumulateAcceptedPrecipitationHeat(
        context.atmosphere.rainfall_m,
        context.atmosphere.snowfall_water_equivalent_m,
        context.canopy_cell_area_m2,
        context.atmosphere.air_temperature_k,
        .{
            .snow_latent_heat_of_fusion_megajoules_per_m3 = context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3,
            .solid_snow_heat_capacity_megajoules_per_m3_k = context.runscript.snow_solid_heat_capacity_megajoules_per_m3_k,
            .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
            .pure_water_melting_temperature_k = context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
        },
        precipitation_heat_megajoules_by_cell,
    );
    try context.hourly_cell_boundary_ledger.accumulateSignedHeat(precipitation_heat_megajoules_by_cell);
    // REDIST XHFLF0/XHFLV0 are internal phase/reference adjustments. They
    // alter the inventoried snow enthalpy without crossing the atmosphere or
    // domain boundary and therefore remain direction-separated internally.
    try context.landscape_boundary_ledger.accumulateAcceptedSignedInternalHeat(
        snow_phase_change_report.sensible_energy_change_megajoules +
            snow_vapor_equilibrium_report.sensible_energy_change_megajoules,
    );
    try context.hourly_cell_boundary_ledger.accumulateSignedInternalHeat(
        snow_phase_change_report.sensible_energy_change_megajoules_by_cell,
    );
    try context.hourly_cell_boundary_ledger.accumulateSignedInternalHeat(
        snow_vapor_equilibrium_report.sensible_energy_change_megajoules_by_cell,
    );
    const subsurface_irrigation_input =
        try ecosys.subsurface_irrigation_heat.calculate(
            context.subsurface_irrigation_water_m3,
            context.atmosphere.air_temperature_k,
            context.grid.soil_layer_capacity,
            context.runscript.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        );
    const subsurface_irrigation_input_by_cell = try context.allocator.alloc(
        ecosys.subsurface_irrigation_heat.Totals,
        context.grid.cell_count,
    );
    defer context.allocator.free(subsurface_irrigation_input_by_cell);
    try ecosys.subsurface_irrigation_heat.calculateByCell(
        subsurface_irrigation_input_by_cell,
        context.subsurface_irrigation_water_m3,
        context.atmosphere.air_temperature_k,
        context.grid.soil_layer_capacity,
        context.runscript.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
    );
    for (subsurface_irrigation_input_by_cell, 0..) |input, cell|
        try context.hourly_cell_boundary_ledger.accumulate(cell, .{
            .water_input_m3 = input.water_input_m3,
            .heat_input_megajoules = input.heat_input_megajoules,
        });
    try context.landscape_boundary_ledger.accumulateAccepted(.{
        .rain_m3 = subsurface_irrigation_input.water_input_m3,
        .heat_input_megajoules = subsurface_irrigation_input.heat_input_megajoules,
    });
    const subsurface_irrigation_solutes =
        try ecosys.subsurface_irrigation_chemistry.boundaryInput(
            context.irrigation_loads,
            subsurface_irrigation_chemistry_parameters,
        );
    const subsurface_irrigation_solutes_by_cell = try context.allocator.alloc(
        ecosys.subsurface_irrigation_chemistry.BoundaryInput,
        context.grid.cell_count,
    );
    defer context.allocator.free(subsurface_irrigation_solutes_by_cell);
    try ecosys.subsurface_irrigation_chemistry.boundaryInputByCell(
        subsurface_irrigation_solutes_by_cell,
        context.irrigation_loads,
        subsurface_irrigation_chemistry_parameters,
    );
    for (subsurface_irrigation_solutes_by_cell, 0..) |input, cell|
        try context.hourly_cell_boundary_ledger.accumulate(cell, .{
            .nitrogen_input_g = input.nitrogen_g_n,
            .phosphorus_input_g = input.phosphorus_g_p,
            .aluminum_input_mol = input.aluminum_mol,
            .iron_input_mol = input.iron_mol,
            .calcium_input_mol = input.calcium_mol,
            .magnesium_input_mol = input.magnesium_mol,
            .sodium_input_mol = input.sodium_mol,
            .potassium_input_mol = input.potassium_mol,
            .sulfur_input_mol = input.sulfur_mol,
            .chloride_input_mol = input.chloride_mol,
        });
    try context.landscape_boundary_ledger.accumulateAccepted(.{
        .nitrogen_input_g_n = subsurface_irrigation_solutes.nitrogen_g_n,
        .phosphorus_input_g_p = subsurface_irrigation_solutes.phosphorus_g_p,
        .ion_input_mol = subsurface_irrigation_solutes.ion_mol,
    });
    if (diagnostic_first_hour) {
        const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
        std.log.info("phosphorus stage: vegetation_and_final_ledgers delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
        try diagnostics.logPhosphorusRepresentation(context, "after_vegetation_and_final_ledgers");
    }
}

// Keep the end-of-hour geometry owner's focused transaction/order tests in
// the executable test graph; stage imports are otherwise test-lazy in Zig.
test {
    _ = geometry_disturbance;
}

noinline fn advanceShootGrowthAndCloseout(
    context: anytype,
    hour_of_day: u8,
    weather_header_by_cell: []const ecosys.weather.Header,
    plant_calendar: anytype,
    plant_internal_activity_ptr: anytype,
) !void {
    var plant_internal_activity = plant_internal_activity_ptr.*;
    defer plant_internal_activity_ptr.* = plant_internal_activity;
    if (context.detailed_canopy.*) |*canopy| {
        const shoot_execution_year = std.math.cast(u16, plant_calendar.current_year) orelse
            return error.InvalidShootGrowthDate;
        const litter_partition = if (context.plant_litter_partition.*) |*value| value else return error.MissingPlantLitterPartitionForShootGrowth;
        const canopy_surface_exchange_for_growth = if (context.canopy_surface_exchange.*) |*value| value else return error.MissingCanopySurfaceExchangeForShootGrowth;
        const canopy_surface_workspace_for_growth = if (context.canopy_surface_input_workspace.*) |*value| value else return error.MissingCanopySurfaceWorkspaceForShootGrowth;
        const canopy_retention_for_growth = if (context.canopy_precipitation_retention.*) |*value| value else return error.MissingCanopyRetentionForShootGrowth;
        const surface_gas_for_growth = context.surface_gas_parameters.*;
        const shoot_solar_noon_hour_by_cell = try context.allocator.alloc(u8, context.grid.cell_count);
        defer context.allocator.free(shoot_solar_noon_hour_by_cell);
        for (weather_header_by_cell, shoot_solar_noon_hour_by_cell) |header, *solar_noon_hour| {
            if (!std.math.isFinite(header.solar_noon_hour) or header.solar_noon_hour < 0 or header.solar_noon_hour > 23)
                return error.InvalidShootSolarNoonHour;
            solar_noon_hour.* = @intFromFloat(@floor(header.solar_noon_hour));
        }
        @memset(context.shoot_senescence_products_by_plant, .{});
        @memset(context.seasonal_turnover_event_by_plant, false);
        var shoot_growth_context: ecosys.shoot_growth_runtime.ApplyContext = .{
            .canopy = canopy,
            .growth_stages = &context.plant_growth_stages.*.?,
            .dormancy = &context.plant_dormancy.*.?,
            .development = &context.branch_development.*.?,
            .plant_parameters = context.shoot_growth_plant_parameters,
            .active_by_plant = context.plant_phenology.*.?.active,
            .emerged_by_plant = context.plant_phenology.*.?.emerged,
            .leaf_appearance_rate_at_25c_per_h_by_plant = context.plant_phenology.*.?.leaf_appearance_rate_at_25c_per_h,
            .sowing_depth_m_by_plant = context.plant_water_workspace.*.?.seeding_depth_m,
            .roots = &context.plant_roots.*.?,
            .soil_temperature_k = context.grid.soil_temperature_k,
            .soil_layer_capacity = context.grid.soil_layer_capacity,
            .root_growth_temperature_parameters = context.runscript.canopy_stress_parameters.growth_temperature,
            .canopy_temperature_k_by_plant = context.plants.canopy_temperature_k,
            .canopy_total_water_potential_mpa_by_plant = context.plants.canopy_water_potential_megapascal,
            .total_aerodynamic_resistance_h_per_m_by_plant = canopy_surface_exchange_for_growth.total_aerodynamic_resistance_h_per_m,
            .stomatal_resistance_h_per_m_by_plant = canopy_surface_workspace_for_growth.stomatal_resistance_h_per_m,
            .plant_radiation_fraction = canopy_retention_for_growth.living_radiation_fraction,
            .atmospheric_concentration_g_per_m3 = context.current_atmospheric_gas_concentration_g_per_m3,
            .ammonia_solubility_at_25_c = surface_gas_for_growth.solubility.reference_water_to_air[@intFromEnum(ecosys.gas_transport.Species.ammonia)],
            .canopy_ammonia_parameters = context.runscript.canopy_ammonia_exchange_parameters,
            .partition_parameters = context.runscript.organ_partition_parameters,
            .metabolism_parameters = context.runscript.shoot_metabolism_parameters,
            .phenology_parameters = context.runscript.phenology_parameters,
            .node_growth_parameters = context.runscript.shoot_node_growth_parameters,
            .branch_mobile_exchange_parameters = context.runscript.branch_mobile_exchange_parameters,
            .storage_remobilization_duration_h_by_growth_habit = context.runscript.storage_remobilization_parameters.remobilization_duration_h,
            .cell_area_m2 = context.canopy_cell_area_m2,
            .stalk_volume_m3_per_g_c = context.runscript.stalk_volume_m3_per_g_c,
            .structural_presence_threshold_g_per_plant = context.runscript.plant_pool_parameters.branch_structural_presence_g_per_plant,
            .grain_fill_detection_threshold_g_per_plant = context.runscript.plant_pool_parameters.grain_fill_detection_g_c_per_plant,
            .day_of_year = plant_calendar.day_of_year,
            .hour_of_day = hour_of_day,
            .solar_noon_hour_by_cell = shoot_solar_noon_hour_by_cell,
            .execution_year = shoot_execution_year,
            .timestep_h = 1,
            .seasonal_litterfall_rate_per_h = context.runscript.seasonal_turnover_parameters.litterfall_rate_per_h,
            .seasonal_litterfall_delay_threshold_h = context.runscript.seasonal_turnover_parameters.litterfall_delay_threshold_h,
            .dormancy_parameters_by_plant = context.development_dormancy_parameters,
            .litter_partition = litter_partition,
            .senescence_recycling = context.runscript.shoot_senescence_recycling_parameters,
            .senescence_products_by_plant = context.shoot_senescence_products_by_plant,
            .seasonal_turnover_event_by_plant = context.seasonal_turnover_event_by_plant,
            .senescence_demand_tolerance_g_c = context.config.physical_tolerance.carbon(blk: {
                var scale_g_c: f64 = 0;
                for (canopy.plant_total_shoot_carbon_g) |carbon_g| scale_g_c = @max(scale_g_c, @abs(carbon_g));
                break :blk scale_g_c;
            }),
            .leaf_area_presence_tolerance_m2 = context.config.physical_tolerance.area(blk: {
                var scale_m2: f64 = 0;
                for (canopy.branch_leaf_area_m2) |area_m2| scale_m2 = @max(scale_m2, @abs(area_m2));
                break :blk scale_m2;
            }),
            .symbiosis_parameters = context.runscript.symbiotic_fixation_parameters,
            .fire_active_this_hour = context.fire_active_this_hour,
            .symbiotic_inoculum_input_by_cell = context.symbiotic_inoculum_input_by_cell,
            .carbon_exchange = if (context.canopy_carbon_exchange.*) |*ledger| ledger else null,
            .accepted_internal_activity = &plant_internal_activity,
        };
        try tile_kernels.runKernelAcrossSerialTiles(context, &shoot_growth_context, ecosys.shoot_growth_runtime.applyTile);
        try plant_daily.applyNaturalBranchMortality(context, plant_calendar);
        for (0..canopy.cell_count) |cell| {
            var cell_products: ecosys.canopy_photosynthesis.SenescenceProducts = .{};
            const first_plant = cell * canopy.species_count;
            for (context.shoot_senescence_products_by_plant[first_plant .. first_plant + canopy.species_count]) |products|
                ecosys.canopy_photosynthesis.addSenescenceProducts(&cell_products, products);
            try ecosys.shoot_litter_bridge.state_updateCell(context.surface_organic, cell, cell_products);
        }
        try plant_daily.applyStandingDeadLitterfall(context);
        const roots = if (context.plant_roots.*) |*value| value else return error.MissingPlantRootsForShootRootExchange;
        const root_water_workspace = if (context.plant_water_workspace.*) |*value| value else return error.MissingPlantWaterWorkspaceForShootRootExchange;
        const storage_workspace = if (context.plant_storage_remobilization_workspace.*) |*value| value else return error.MissingStorageWorkspaceForShootRootExchange;
        var root_mycorrhizal_exchange_context: ecosys.plant_root_mycorrhizal_exchange.ApplyContext = .{
            .roots = roots,
            .cell_count = context.grid.cell_count,
            .species_count = canopy.species_count,
            .active_soil_layer_count_by_cell = context.grid.active_soil_layer_count,
            .active_by_plant = context.plant_phenology.*.?.active,
            .plant_parameters = context.root_metabolism_plant_parameters,
            .parameters = context.runscript.root_mycorrhizal_exchange_parameters,
            .timestep_h = 1,
            .salinity_enabled_by_cell = context.salinity_enabled_by_cell,
        };
        try tile_kernels.runKernelAcrossSerialTiles(context, &root_mycorrhizal_exchange_context, ecosys.plant_root_mycorrhizal_exchange.applyTile);
        // GROSUB 8174--8199 follows the root/mycorrhizal sweep and precedes
        // the 8230--8438 shoot-root C/N/P/salt equilibration.
        try plant_daily.applyPerennialRootSeasonalStorage(context, &plant_internal_activity);
        var shoot_root_exchange_context: ecosys.plant_shoot_root_exchange.ApplyContext = .{
            .canopy = canopy,
            .roots = roots,
            .growth_stages = &context.plant_growth_stages.*.?,
            .active_by_plant = context.plant_phenology.*.?.active,
            .root_nonwoody_fraction_by_plant = root_water_workspace.woody_root_fraction,
            .carried_total_root_carbon_g_c_by_plant = storage_workspace.carried_total_root_carbon_g_c,
            .plant_parameters = context.root_metabolism_plant_parameters,
            .parameters = context.runscript.shoot_root_exchange_parameters,
            .structural_presence_threshold_g_per_plant = context.runscript.plant_pool_parameters.branch_structural_presence_g_per_plant,
            .timestep_h = 1,
            .salinity_enabled_by_cell = context.salinity_enabled_by_cell,
            .accepted_activity = &plant_internal_activity,
        };
        try tile_kernels.runKernelAcrossSerialTiles(context, &shoot_root_exchange_context, ecosys.plant_shoot_root_exchange.applyTile);
    }
    try ecosys.layer_local_conservation.accumulatePlantInternalRootShoot(
        context.hourly_layer_boundary_ledger,
        &plant_internal_activity,
        context.grid.active_soil_layer_count,
    );
    // GROSUB WTNDI is external inoculum, not atmospheric fixation or an
    // internal host transfer. Root and canopy producers have both completed;
    // atomically consume their shared per-cell activity into the hourly gate
    // and explicit cumulative/domain C/N/P ledger before conservation checks.
    try context.landscape_boundary_ledger.accumulateAcceptedSymbioticInoculum(
        context.hourly_cell_boundary_ledger,
        context.symbiotic_inoculum_input_by_cell,
    );
}

// Compiler boundary only: these phases remain serial and preserve the exact
// GROSUB publication order before shoot growth consumes their state.
noinline fn aggregateCanopyPoolsAndAdvanceDevelopment(
    context: anytype,
    plant_calendar: anytype,
) !void {
    if (context.plant_growth_stages.*) |*growth_stages| {
        const roots = if (context.plant_roots.*) |*value| value else return error.MissingPlantRootsForPoolAggregation;
        const canopy = if (context.detailed_canopy.*) |*value| value else return error.MissingCanopyForPoolAggregation;
        var pool_context: ecosys.plant_pool_aggregation.ApplyContext = .{ .canopy = canopy, .roots = roots, .growth_stages = growth_stages, .active_by_plant = context.plant_phenology.*.?.active, .biological_domain_count_by_plant = context.root_biological_domain_count_by_plant, .salinity_enabled_by_cell = context.salinity_enabled_by_cell, .parameters = context.runscript.plant_pool_parameters };
        try ecosys.plant_pool_aggregation.validateApplyContext(&pool_context);
        try tile_kernels.runKernelAcrossSerialTiles(context, &pool_context, ecosys.plant_pool_aggregation.applyValidatedTile);
    }
    if (context.plant_growth_stages.*) |*growth_stages| {
        const canopy = if (context.detailed_canopy.*) |*value| value else return error.MissingCanopyForDevelopment;
        try context.plant_reproduction_workspace.ensureBranchCapacity(canopy.branch_node_offsets.len - 1);
        var reproduction_context: ecosys.plant_reproduction.ApplyContext = .{ .canopy = canopy, .plants = context.plants, .growth_stages = growth_stages, .controls = context.plant_reproduction_controls, .active_by_plant = context.plant_phenology.*.?.active, .minimum_turgor_potential_megapascal = context.runscript.phenology_parameters.minimum_turgor_potential_megapascal, .seed_set_parameters = context.runscript.seed_set_parameters, .structural_presence_threshold_g_per_plant = context.runscript.plant_pool_parameters.branch_structural_presence_g_per_plant, .timestep_h = 1, .workspace = context.plant_reproduction_workspace };
        try tile_kernels.runIndexedKernelAcrossSerialTiles(context, &reproduction_context, ecosys.plant_reproduction.applyOwnedCells);
    }
    // GROSUB 4182--4378: spring phenology and residue cleanup precede the
    // 4393--4409 seasonal flag reset executed by shoot_growth_runtime.
    if (context.plant_harvest) |harvest| if (context.plant_phenology.*) |*phenology_state| {
        for (phenology_state.leafout_transition_this_step, 0..) |leafout, plant| {
            if (!leafout or !phenology_state.active[plant] or context.plant_topology_controls.growth_habit_code[plant] == 0) continue;
            const branches = try context.plant_growth_stages.*.?.branchRange(plant);
            const fully_deciduous = context.canopy_layer_controls.biomass_turnover_type[plant] == 0;
            for (branches.first..branches.end) |branch| {
                context.branch_development.*.?.remobilization_progress_h[branch] = 0;
                context.branch_development.*.?.leafout_initialization_enabled[branch] = false;
                try ecosys.plant_growth_stages.resetBranchForSeasonalLeafout(
                    &context.plant_growth_stages.*.?.branches[branch],
                    plant_calendar.day_of_year,
                    fully_deciduous,
                    context.branch_development.*.?.initial_reproductive_stage[branch],
                );
            }
            if (fully_deciduous and branches.first < branches.end) {
                phenology_state.initiated_node_count[plant] = context.branch_development.*.?.initial_reproductive_stage[branches.first];
                phenology_state.appeared_leaf_count[plant] = 0;
            }
            try ecosys.plant_harvest_runtime.applyStartOfSeasonResidue(
                harvest,
                plant,
                context.canopy_layer_controls.biomass_turnover_type[plant],
                context.canopy_layer_controls.root_profile_type[plant],
            );
        }
    };
}

// Keep the topology refresh and its immediate radiation/carboxylation
// consumers together so no later phase can observe mismatched geometry.
noinline fn refreshCanopyLayersAndCarboxylation(context: anytype) !void {
    if (context.canopy_layer_distribution.*) |*layers| {
        const canopy = if (context.detailed_canopy.*) |*value| value else return error.MissingCanopyForLayerDistribution;
        const growth_stages = if (context.plant_growth_stages.*) |*value| value else return error.MissingGrowthStagesForLayerDistribution;
        const structure = if (context.canopy_structure.*) |*value| value else return error.MissingCanopyStructureForLayerDistribution;
        const water_workspace = if (context.plant_water_workspace.*) |*value| value else return error.MissingPlantWaterWorkspaceForLayerDistribution;
        try layers.refresh(canopy, growth_stages, context.canopy_layer_controls, water_workspace.seeding_depth_m, context.canopy_geometry.leaf_inclination_sine, structure.leaf_inclination_fraction, context.hourly_solar_angle_sine, 1.0e-12);
        try layers.publishNodeSamples(canopy);
        // `refresh` just rewrote every cell's layer boundary heights (ordinary
        // growth, or -- at `:115-126` above -- a mid-hour branch-driven
        // topology replacement). `canopy_interception`'s boundary
        // transmission fractions were last populated at the top of this hour
        // (`hourly_process_driver.zig`'s `refreshLayerTransmission`/
        // `refreshAtmosphericLayerAbsorption` calls) against the boundary
        // heights as they stood BEFORE this refresh, i.e. against last
        // hour's geometry. `canopy_carboxylation.applyTile` below indexes
        // that transmission array by `boundary_above`, computed from
        // `layers.layer_count` and the layer loop over the JUST-refreshed
        // boundaries, so without recomputing here a leaf sample's layer
        // index would point to a transmission value built for a different
        // height range -- the oracle's `hour1.f:1508` PAR and
        // `stomate.f:330,552` UPTAKE consumer always read the SAME,
        // single-per-hour `ZL` geometry HOUR1 just set; GROSUB, which runs
        // after, only ever reads `ZL` for the FOLLOWING hour. Recompute
        // immediately so this hour's carboxylation samples the geometry
        // `layers` now actually holds.
        if (context.canopy_interception.*) |*interception| if (context.canopy_optics.*) |*optics| {
            const canopy_burial: ecosys.canopy_interception.BurialInputs = .{
                .snow_depth_m = context.snow_depth_m,
                .surface_liquid_water_m3 = context.surface_precipitation.litter_water_m3,
                .surface_ice_m3 = context.surface_litter_ice_m3,
                .surface_water_retention_capacity_m3 = context.surface_precipitation.litter_water_capacity_m3,
                .cell_area_m2 = context.canopy_cell_area_m2,
                .soil_roughness_height_m = context.runscript.surface_aerodynamic_parameters.soil_roughness_height_m,
                .absolute_depth_tolerance_m = context.config.physical_tolerance.length_m,
                .relative_depth_tolerance = context.config.physical_tolerance.relative,
                .ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
            };
            try canopy_burial.validate(context.grid.cell_count);
            try ecosys.canopy_interception.refreshLayerTransmissionWithBurial(interception, layers, structure, context.canopy_geometry, context.direct_incidence_per_horizontal_area, context.canopy_cell_area_m2, canopy_burial);
            try ecosys.canopy_interception.refreshAtmosphericLayerAbsorptionWithBurial(interception, layers, structure, optics, context.canopy_geometry, context.canopy_radiation, context.direct_incidence_fraction, context.direct_incidence_per_horizontal_area, context.direct_scattering_direction, context.canopy_cell_area_m2, context.runscript.woody_optics_parameters, canopy_burial);
        };
        if (context.canopy_surface_input_workspace.*) |*surface_workspace| {
            var carboxylation_context: ecosys.canopy_carboxylation.ApplyContext = .{
                .canopy = canopy,
                .layers = layers,
                .interception = &context.canopy_interception.*.?,
                .optics = &context.canopy_optics.*.?,
                .geometry = context.canopy_geometry,
                .parameters_by_plant = context.canopy_biochemistry_parameters,
                .c4_carbon_parameters = context.runscript.c4_carbon_parameters,
                .direct_incidence_fraction = context.direct_incidence_fraction,
                .canopy_temperature_k_by_plant = context.plants.canopy_temperature_k,
                .stomatal_resistance_h_per_m_by_plant = surface_workspace.stomatal_resistance_h_per_m,
                .minimum_stomatal_resistance_h_per_m_by_plant = canopy.plant_minimum_water_vapor_resistance_h_per_m,
                .shallow_root_profile_by_plant = context.canopy_layer_controls.root_profile_type,
                .canopy_total_water_potential_mpa_by_plant = context.plants.canopy_water_potential_megapascal,
                // GROSUB RCMN = 10 s m-1 (the same 2.78e-3 h m-1
                // compatibility minimum used by STOMATE's RSMN calculation).
                .minimum_co2_stomatal_resistance_s_per_m = 2.78e-3 * 3600.0,
                .leaf_carbon_presence_threshold_g_c_per_plant = context.runscript.plant_pool_parameters.branch_structural_presence_g_per_plant,
                .atmospheric_co2_umol_per_mol_by_cell = context.current_canopy_co2_umol_per_mol_by_cell,
                .picard_relaxation = context.config.picard_relaxation,
                .max_iterations = context.iteration_limits.leaf_co2_max_iterations,
                .timestep_h = 1,
                .carbon_exchange = if (context.canopy_carbon_exchange.*) |*ledger| ledger else null,
            };
            try tile_kernels.runKernelAcrossSerialTiles(context, &carboxylation_context, ecosys.canopy_carboxylation.applyTile);
            // Two facts again, kept separate deliberately.
            // `canopy_carboxylation` means the kernel was DISPATCHED -- the
            // only gate above it is the presence of the surface workspace, so
            // it says nothing about whether any carbon was fixed.
            // `canopy_photosynthesis_occurred` reads the accepted ledger, so
            // it answers the science question: did this deck photosynthesize?
            context.stage_census.*.recordCurrent(.canopy_carboxylation);
            if (context.canopy_carbon_exchange.*) |*ledger| {
                for (ledger.fixed_carbon_g_c_per_h) |fixed_g_c| {
                    if (fixed_g_c != 0) {
                        context.stage_census.*.recordCurrent(.canopy_photosynthesis_occurred);
                        break;
                    }
                }
                // Symbiotic fixation is a maize-SOYBEAN question and this is
                // the accepted-ledger evidence for it: the symbiont
                // respiration term is nonzero only where a symbiont is
                // metabolically active.
                for (ledger.symbiont_respiration_g_c_per_h) |symbiont_g_c| {
                    if (symbiont_g_c != 0) {
                        context.stage_census.*.recordCurrent(.symbiotic_nitrogen_fixation);
                        break;
                    }
                }
            }
        }
    }
}

noinline fn advanceCanopyGrowthAndExchange(
    context: anytype,
    hour_of_day: u8,
    weather_header_by_cell: []const ecosys.weather.Header,
    plant_calendar: anytype,
    plant_internal_activity_ptr: anytype,
) !void {
    var plant_internal_activity = plant_internal_activity_ptr.*;
    defer plant_internal_activity_ptr.* = plant_internal_activity;
    try aggregateCanopyPoolsAndAdvanceDevelopment(context, plant_calendar);
    try refreshCanopyLayersAndCarboxylation(context);
    try advanceShootGrowthAndCloseout(
        context,
        hour_of_day,
        weather_header_by_cell,
        plant_calendar,
        &plant_internal_activity,
    );
}

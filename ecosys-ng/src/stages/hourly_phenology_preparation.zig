//! Source-order HFUNC preparation consumed by UPTAKE/STOMATE.
//!
//! `soil.f:167--175` calls HFUNC before UPTAKE. STOMATE then reads the branch
//! topology, life flags, VRNS/VRNF dormancy counters, and development state
//! that HFUNC just published (`stomate.f:110--190,207--210`). Keep only those
//! preparation mutations here; reproduction and all GROSUB state changes stay
//! in `hourly_vegetation.zig` after canopy/root energy.

const std = @import("std");
const ecosys = @import("ecosys_ng");
const tile_kernels = @import("tile_kernels.zig");

/// Advances the HFUNC state required by same-hour STOMATE exactly once. This
/// is called inside the enclosing accepted-hour transaction, so any later
/// canopy/soil failure restores these mutations with the rest of plant state.
pub fn preparePhenologyForCanopyEnergy(
    context: anytype,
    plant_calendar_by_cell: []const ecosys.plant_development.Calendar,
    plant_calendar: anytype,
) !void {
    if (context.plant_growth_stages.* == null or
        context.plant_roots.* == null or
        context.detailed_canopy.* == null or
        context.branch_development.* == null or
        context.plant_phenology.* == null or
        context.plant_dormancy.* == null)
        return;

    // Past the guard above, so the canopy-energy preparation genuinely ran for
    // this hour rather than being skipped for absent plant state.
    context.stage_census.*.recordCurrent(.canopy_energy_balance);

    const canopy = &context.detailed_canopy.*.?;
    const roots = &context.plant_roots.*.?;
    const growth_stages = &context.plant_growth_stages.*.?;
    const phenology = &context.plant_phenology.*.?;

    // HFUNC 300--326: establish same-hour emergence before HFUNC's shoot
    // branch insertion and per-branch dormancy loop.
    const water_workspace = if (context.plant_water_workspace.*) |*value| value else return error.MissingPlantWaterWorkspaceForEmergence;
    try ecosys.plant_development.refreshHypocotyledonHeight(canopy, water_workspace.seeding_depth_m);
    try ecosys.plant_development.refreshEmergence(
        canopy,
        roots,
        growth_stages,
        water_workspace.seeding_depth_m,
        plant_calendar.day_of_year,
        context.runscript.phenology_parameters.emergence_area_threshold_m2_per_plant,
        context.runscript.phenology_parameters.emergence_root_depth_margin_m,
        context.plant_phenology.*.?.emerged,
    );
    // Two distinct facts, and conflating them is the trap this census exists
    // to avoid. `plant_emergence_refresh` means the refresh RAN this hour --
    // it runs unconditionally once plant state exists, so it says nothing
    // about the plant. `plant_emergence_occurred` means at least one plant is
    // actually past emergence, which is the science question.
    context.stage_census.*.recordCurrent(.plant_emergence_refresh);
    // Three further science questions off the same two arrays, all gated on
    // ACTIVE rather than on the array merely existing: `active` is sized
    // `cell_count * species_count`, so an inactive slot is a plant that is not
    // there, and counting those would report every stage as exercised on an
    // empty deck. Species index is `index % species_count` for the same reason.
    const phenology_state = &context.plant_phenology.*.?;
    const species_count = phenology_state.species_count;
    var emergence_occurred = false;
    var pre_emergence_present = false;
    var second_species_active = false;
    for (phenology_state.active, phenology_state.emerged, 0..) |active, emerged, index| {
        if (!active) continue;
        if (emerged) emergence_occurred = true else pre_emergence_present = true;
        if (index % species_count != 0) second_species_active = true;
    }
    if (emergence_occurred)
        context.stage_census.*.recordCurrent(.plant_emergence_occurred);
    // An active plant that has NOT emerged is genuinely running the
    // pre-emergence branch this hour -- below-ground growth on seed reserves.
    // Distinct from `plant_emergence_occurred` and from its negation: with no
    // active plant at all, NEITHER fires, which is the honest answer.
    if (pre_emergence_present)
        context.stage_census.*.recordCurrent(.plant_pre_emergence);
    // The Ottawa deck is a maize-SOYBEAN rotation, so whether a second species
    // ever ran is a standing open question about this evidence. Recorded only
    // when a plant at species index >= 1 is active.
    if (second_species_active)
        context.stage_census.*.recordCurrent(.second_plant_species);

    // HFUNC 328--375: the branch must exist before the later HFUNC branch
    // loop and before UPTAKE's two STOMATE calls. Compact topology rebuilds
    // all four aligned owners atomically; dependent radiation/carbon
    // workspaces are replaced only after insertion succeeds.
    const topology_states: ecosys.plant_topology.RuntimeStates = .{
        .canopy = canopy,
        .growth_stages = growth_stages,
        .dormancy = &context.plant_dormancy.*.?,
        .branch_development = &context.branch_development.*.?,
    };
    const execution_year = std.math.cast(u16, plant_calendar.current_year) orelse
        return error.InvalidPlantTopologyDate;
    const new_shoot_branches = try ecosys.plant_topology.advanceShootBranches(.{
        .states = topology_states,
        .roots = roots,
        .controls = context.plant_topology_controls,
        .active_by_plant = phenology.active,
        .emerged_by_plant = context.plant_phenology.*.?.emerged,
        .day_of_year = plant_calendar.day_of_year,
        .execution_year = execution_year,
        .minimum_root_turgor_potential_megapascal = context.runscript.phenology_parameters.minimum_turgor_potential_megapascal,
    });
    if (new_shoot_branches > 0) {
        var replacement_layers = try ecosys.canopy_layer_distribution.State.init(
            context.allocator,
            context.grid.cell_count,
            context.config.plant_populations,
            context.runscript.canopy_layer_count,
            context.canopy_geometry.leaf_inclination_sine.len,
            context.canopy_geometry.leaf_azimuth_radians.len,
            canopy,
        );
        const replacement_carbon_exchange = ecosys.canopy_carbon_exchange.State.init(
            context.allocator,
            canopy.branch_node_offsets.len - 1,
        ) catch |err| {
            replacement_layers.deinit();
            return err;
        };
        var previous_layers = context.canopy_layer_distribution.*.?;
        context.canopy_layer_distribution.*.? = replacement_layers;
        previous_layers.deinit();
        var previous_carbon_exchange = context.canopy_carbon_exchange.*.?;
        context.canopy_carbon_exchange.*.? = replacement_carbon_exchange;
        previous_carbon_exchange.deinit();
    }

    // HFUNC 387--406: NRT is advanced in the same pre-UPTAKE pass as shoot
    // topology. UPTAKE and GROSUB both traverse the updated NRT immediately
    // (`uptake.f:498`, `grosub.f:366,381`), so delaying this mutation until
    // after root uptake/metabolism loses the new axis for the current hour and
    // evaluates its carbon threshold against post-GROSUB pools.
    _ = try ecosys.plant_topology.advanceRootAxes(.{
        .roots = roots,
        .canopy = canopy,
        .growth_stages = growth_stages,
        .branch_development = &context.branch_development.*.?,
        .active_by_plant = phenology.active,
        .root_branching_carbon_fraction = context.plant_topology_controls.root_branching_carbon_fraction,
        .minimum_root_turgor_potential_megapascal = context.runscript.phenology_parameters.minimum_turgor_potential_megapascal,
    });

    // HFUNC node/leaf rates precede its per-branch growth-stage/dormancy
    // loop. These use the hour-entry canopy/root state, matching HFUNC's
    // position before UPTAKE.
    try ecosys.plant_root_gas_exchange.fillPlantOxygenUptakeToDemandFraction(
        roots,
        context.root_biological_domain_count_by_plant,
        context.phenology_root_oxygen_fraction,
    );
    var phenology_context: ecosys.plant_phenology.AdvanceContext = .{
        .phenology = phenology,
        .plants = context.plants,
        .thermal_acclimation_offset_k = canopy.plant_thermal_adaptation_offset_c,
        .canopy_turgor_potential_megapascal = canopy.plant_canopy_turgor_potential_megapascal,
        .root_oxygen_uptake_to_demand_fraction = context.phenology_root_oxygen_fraction,
        .emerged = context.plant_phenology.*.?.emerged,
        .timestep_hours = 1,
        .parameters = context.runscript.phenology_parameters,
    };
    try tile_kernels.runKernelAcrossSerialTiles(context, &phenology_context, ecosys.plant_phenology.advanceTile);

    try ecosys.plant_development.refreshCanopyHeight(canopy, context.development_canopy_height_m);
    try ecosys.plant_development.refreshSoilWaterPotentials(
        context.grid,
        context.soil_hourly_workspace.landscape_total_water_potential_megapascal,
        context.surface_litter_water_environment.matric_plus_osmotic_water_potential_megapascal,
        context.terrain_hydrology.relative_surface_elevation_m,
        context.soil_hourly_workspace.gravitational_water_potential_mpa_per_m,
        roots,
        context.development_surface_water_potential_megapascal,
        context.development_seed_layer_water_potential_megapascal,
    );
    var development_context: ecosys.plant_development.AdvanceContext = .{
        .growth_stages = growth_stages,
        .dormancy_state = &context.plant_dormancy.*.?,
        .phenology_state = phenology,
        .branch_development = &context.branch_development.*.?,
        .species_parameters_by_plant = context.development_species_parameters,
        .dormancy_parameters_by_plant = context.development_dormancy_parameters,
        .planting_day_of_year_by_plant = context.development_planting_day_of_year,
        .planting_year_by_plant = context.development_planting_year,
        .canopy_height_m_by_plant = context.development_canopy_height_m,
        .snow_depth_m_by_cell = context.snow_depth_m,
        .canopy_temperature_k_by_plant = context.plants.canopy_temperature_k,
        .canopy_turgor_potential_mpa_by_plant = canopy.plant_canopy_turgor_potential_megapascal,
        .canopy_total_water_potential_mpa_by_plant = context.plants.canopy_water_potential_megapascal,
        .surface_soil_water_potential_mpa_by_cell = context.development_surface_water_potential_megapascal,
        .seed_layer_soil_water_potential_mpa_by_plant = context.development_seed_layer_water_potential_megapascal,
        .emerged_by_plant = context.plant_phenology.*.?.emerged,
        .calendar_by_cell = plant_calendar_by_cell,
        .timestep_h = 1,
    };
    try tile_kernels.runKernelAcrossSerialTiles(context, &development_context, ecosys.plant_development.advanceTile);
}

test "HFUNC preparation is unique and precedes final STOMATE production" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const snow = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/stages/hourly_snow_energy.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(snow);
    const heat_water = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/stages/hourly_heat_water_solute.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(heat_water);
    const preparation = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/stages/hourly_phenology_preparation.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(preparation);
    const vegetation = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/stages/hourly_vegetation.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(vegetation);
    const main = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/ecosys_ng.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(main);
    const test_position = std.mem.indexOf(u8, preparation, "test \"HFUNC preparation") orelse preparation.len;
    const production_preparation = preparation[0..test_position];

    const prepare_call = "group_phenology_preparation.preparePhenologyForCanopyEnergy(";
    const hook = std.mem.indexOf(u8, snow, "fn PostWatsubCanopyHook(") orelse return error.MissingPostWatsubCanopyHook;
    const prepare_position = std.mem.indexOfPos(u8, snow, hook, prepare_call) orelse return error.MissingPhenologyPreparation;
    const canopy_position = std.mem.indexOfPos(u8, snow, prepare_position, "advanceLivingCanopyAfterWatsub(") orelse return error.MissingPostWatsubCanopyOwner;
    try std.testing.expect(hook < prepare_position and prepare_position < canopy_position);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, snow, prepare_call));
    const accepted_watsub = std.mem.indexOf(u8, heat_water, "advanceMappedDeferred(") orelse return error.MissingAcceptedWatsub;
    const nitro = std.mem.indexOfPos(u8, heat_water, accepted_watsub, ".nitro,") orelse return error.MissingPostWatsubNitro;
    const biology = std.mem.indexOfPos(u8, heat_water, nitro, "post_watsub_biology.advance(") orelse return error.MissingPostNitroHfuncUptakeHook;
    const uptake_grosub = std.mem.indexOfPos(u8, heat_water, biology, "advanceUptakeGrowthAndExtract(") orelse return error.MissingPostHfuncUptakeGrosub;
    try std.testing.expect(accepted_watsub < nitro and nitro < biology and biology < uptake_grosub);

    const post_start = std.mem.indexOf(u8, main, "noinline fn postScienceAccounting(") orelse return error.MissingPostSciencePhase;
    const management_start = std.mem.indexOfPos(u8, main, post_start, "noinline fn postScienceManagementAndGasAccounting(") orelse return error.MissingManagementAccountingPhase;
    const canopy_wrapper_start = std.mem.indexOfPos(u8, main, management_start, "noinline fn postScienceCanopyFireAndCloseout(") orelse return error.MissingCanopyFireWrapper;
    const prepare_start = std.mem.indexOfPos(u8, main, canopy_wrapper_start, "noinline fn prepareHourlyScience(") orelse return error.MissingPrepareHourlySciencePhase;
    const advance_start = std.mem.indexOfPos(u8, main, prepare_start, "noinline fn advanceHour(") orelse return error.MissingAdvanceHourPhase;
    const timeline_start = std.mem.indexOfPos(u8, main, advance_start, "noinline fn runTimeline(") orelse return error.MissingTimelinePhase;
    const post_phase = main[post_start..management_start];
    const management_phase = main[management_start..canopy_wrapper_start];
    const prepare_phase = main[prepare_start..advance_start];
    const advance_phase = main[advance_start..timeline_start];
    _ = std.mem.indexOf(u8, prepare_phase, "plant_management_dispatch.refreshPlantActivity(") orelse return error.MissingScheduledPlantActivation;
    const prepare_phase_call = std.mem.indexOf(u8, advance_phase, "try prepareHourlyScience(driver_context,") orelse return error.MissingPreparationPhaseCall;
    const science_execution = std.mem.indexOfPos(u8, advance_phase, prepare_phase_call, "executeHourlyScience(") orelse return error.MissingHourlyScienceExecution;
    const post_call = std.mem.indexOfPos(u8, advance_phase, science_execution, "try postScienceAccounting(driver_context,") orelse return error.MissingPostScienceCall;
    const management_call = std.mem.indexOf(u8, post_phase, "try postScienceManagementAndGasAccounting(") orelse return error.MissingManagementAccountingCall;
    const canopy_wrapper_call = std.mem.indexOfPos(u8, post_phase, management_call, "try postScienceCanopyFireAndCloseout(") orelse return error.MissingCanopyFireWrapperCall;
    const automatic_self_seeding = std.mem.indexOf(u8, management_phase, "plant_harvest_runtime.applyAutomaticSelfSeedingHarvests(") orelse return error.MissingAutomaticSelfSeeding;
    const dormant_seed_activation = std.mem.indexOfPos(u8, management_phase, automatic_self_seeding, "plant_harvest_runtime.sourceOrderDormantSeedActivation(") orelse return error.MissingDormantSeedActivation;
    try std.testing.expect(prepare_phase_call < science_execution);
    try std.testing.expect(science_execution < post_call);
    try std.testing.expect(management_call < canopy_wrapper_call);
    try std.testing.expect(automatic_self_seeding < dormant_seed_activation);
    const activation_body = management_phase[dormant_seed_activation .. std.mem.indexOfPos(u8, management_phase, dormant_seed_activation, "// Tillage is a late-GROSUB transaction") orelse return error.MissingPostActivationBoundary];
    _ = std.mem.indexOf(u8, activation_body, "driver_context.plant_phenology_state.*.?.active[plant] = false") orelse return error.MissingDormantSeedInactiveStage;
    _ = std.mem.indexOf(u8, activation_body, "driver_context.plant_phenology_state.*.?.lifecycle_initialized[plant] = false") orelse return error.MissingDormantSeedLifecycleStage;
    try std.testing.expect(std.mem.indexOf(u8, activation_body, "driver_context.plant_phenology_state.*.?.reseed_pending[plant] = false") == null);
    _ = std.mem.indexOf(u8, main, "initializeRange(branch_range.first, initial_branch_end, driver_context.plant_topology_controls.*.initial_maturity_group[plant]") orelse return error.MissingCurrentMaturityGroupReconstruction;

    const emergence_position = std.mem.indexOf(u8, production_preparation, "plant_development.refreshEmergence(") orelse return error.MissingEmergencePreparation;
    const shoot_topology_position = std.mem.indexOf(u8, production_preparation, "plant_topology.advanceShootBranches(") orelse return error.MissingShootTopologyPreparation;
    const root_topology_position = std.mem.indexOf(u8, production_preparation, "plant_topology.advanceRootAxes(") orelse return error.MissingRootTopologyPreparation;
    const phenology_position = std.mem.indexOf(u8, production_preparation, "plant_phenology.advanceTile") orelse return error.MissingPhenologyAdvance;
    const development_position = std.mem.indexOf(u8, production_preparation, "plant_development.advanceTile") orelse return error.MissingDevelopmentAdvance;
    try std.testing.expect(emergence_position < shoot_topology_position);
    try std.testing.expect(shoot_topology_position < root_topology_position);
    try std.testing.expect(root_topology_position < phenology_position);
    try std.testing.expect(phenology_position < development_position);

    // A second advance in GROSUB would double every one-hour HFUNC counter.
    // The sole mutating owners must remain in this pre-UPTAKE stage.
    inline for (.{
        "plant_topology.advanceShootBranches(",
        "plant_topology.advanceRootAxes(",
        "plant_phenology.advanceTile",
        "plant_development.advanceTile",
    }) |needle| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production_preparation, needle));
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, vegetation, needle));
    }
}

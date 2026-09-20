//! `hourly_science` declarations: sediment.
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
const group_vegetation = @import("hourly_vegetation.zig");

noinline fn packSuspendedSurface(context: anytype) !void {
    const cells = context.grid.cell_count;
    const capacity = context.grid.soil_layer_capacity;
    const state = context.suspended_constituents;
    @memset(context.erosion_topsoil_constituent_pools, 0);

    try ecosys.soil_erosion_organic_bridge.packSurfaceMapped(
        context.soil_organic,
        cells,
        capacity,
        context.eroded_organic_workspace.component_count,
        context.erosion_topsoil_layer_by_cell,
        context.eroded_organic_workspace.pools,
    );
    try ecosys.suspended_constituents.packFamily(state.layout, cells, .organic_cnp, context.eroded_organic_workspace.pools, context.erosion_topsoil_constituent_pools);

    try ecosys.soil_erosion_fertilizer_bridge.packSurfaceMapped(context.soil_fertilizer_inventory, context.erosion_topsoil_layer_by_cell, context.eroded_fertilizer_workspace.pools);
    try ecosys.suspended_constituents.packFamily(state.layout, cells, .nitrogen_fertilizer, context.eroded_fertilizer_workspace.pools, context.erosion_topsoil_constituent_pools);

    try ecosys.soil_erosion_mineral_fertilizer_bridge.packSurfaceMapped(context.mineral_fertilizer_inventory, context.erosion_topsoil_layer_by_cell, context.eroded_mineral_fertilizer_workspace.pools);
    try ecosys.suspended_constituents.packFamily(state.layout, cells, .dry_mineral_fertilizer, context.eroded_mineral_fertilizer_workspace.pools, context.erosion_topsoil_constituent_pools);

    try ecosys.soil_erosion_chemistry_bridge.packMapped(
        cells,
        capacity,
        context.erosion_topsoil_layer_by_cell,
        context.erosion_canonical_topsoil_mass_megagrams,
        context.grid.matrix_liquid_water_m3,
        context.canopy_cell_area_m2,
        context.erosion_topsoil_zone_fractions,
        context.soil_chemistry,
        context.eroded_chemistry_workspace.pools,
    );
    try ecosys.suspended_constituents.packFamily(state.layout, cells, .chemistry_live_and_pending, context.eroded_chemistry_workspace.pools, context.erosion_topsoil_constituent_pools);

    const texture = try state.layout.range(.mineral_texture);
    const exchange = try state.layout.range(.exchange_capacity);
    for (0..cells) |cell| {
        const layer = cell * capacity + context.erosion_topsoil_layer_by_cell[cell];
        const first = cell * state.component_count;
        context.erosion_topsoil_constituent_pools[first + texture.start + 0] = context.soil_solver_properties.sand_mass_megagrams[layer];
        context.erosion_topsoil_constituent_pools[first + texture.start + 1] = context.soil_solver_properties.silt_mass_megagrams[layer];
        context.erosion_topsoil_constituent_pools[first + texture.start + 2] = context.soil_solver_properties.clay_mass_megagrams[layer];
        context.erosion_topsoil_constituent_pools[first + exchange.start + 0] = context.soil_solver_properties.cation_exchange_capacity_mol[layer];
        context.erosion_topsoil_constituent_pools[first + exchange.start + 1] = context.soil_solver_properties.anion_exchange_capacity_mol[layer];
    }
}

noinline fn unpackSuspendedSurface(context: anytype) !void {
    const cells = context.grid.cell_count;
    const capacity = context.grid.soil_layer_capacity;
    const state = context.suspended_constituents;
    try ecosys.suspended_constituents.unpackFamily(state.layout, cells, .organic_cnp, context.erosion_topsoil_constituent_pools, context.eroded_organic_workspace.pools);
    try ecosys.soil_erosion_organic_bridge.unpackSurfaceMapped(context.soil_organic, cells, capacity, context.eroded_organic_workspace.component_count, context.erosion_topsoil_layer_by_cell, context.eroded_organic_workspace.pools);
    try ecosys.suspended_constituents.unpackFamily(state.layout, cells, .nitrogen_fertilizer, context.erosion_topsoil_constituent_pools, context.eroded_fertilizer_workspace.pools);
    try ecosys.soil_erosion_fertilizer_bridge.unpackSurfaceMapped(context.soil_fertilizer_inventory, context.erosion_topsoil_layer_by_cell, context.eroded_fertilizer_workspace.pools);
    try ecosys.suspended_constituents.unpackFamily(state.layout, cells, .dry_mineral_fertilizer, context.erosion_topsoil_constituent_pools, context.eroded_mineral_fertilizer_workspace.pools);
    try ecosys.soil_erosion_mineral_fertilizer_bridge.unpackSurfaceMapped(context.mineral_fertilizer_inventory, context.erosion_topsoil_layer_by_cell, context.eroded_mineral_fertilizer_workspace.pools);
    try ecosys.suspended_constituents.unpackFamily(state.layout, cells, .chemistry_live_and_pending, context.erosion_topsoil_constituent_pools, context.eroded_chemistry_workspace.pools);
    try ecosys.soil_erosion_chemistry_bridge.unpackMapped(cells, capacity, context.erosion_topsoil_layer_by_cell, context.erosion_canonical_topsoil_mass_megagrams, context.grid.matrix_liquid_water_m3, context.canopy_cell_area_m2, context.erosion_topsoil_zone_fractions, context.soil_chemistry, context.eroded_chemistry_workspace.pools);

    const texture = try state.layout.range(.mineral_texture);
    const exchange = try state.layout.range(.exchange_capacity);
    for (0..cells) |cell| {
        const layer = cell * capacity + context.erosion_topsoil_layer_by_cell[cell];
        const first = cell * state.component_count;
        const canonical_mass = context.erosion_canonical_topsoil_mass_megagrams[cell];
        const sand = context.erosion_topsoil_constituent_pools[first + texture.start + 0];
        const silt = context.erosion_topsoil_constituent_pools[first + texture.start + 1];
        const clay = context.erosion_topsoil_constituent_pools[first + texture.start + 2];
        const cec = context.erosion_topsoil_constituent_pools[first + exchange.start + 0];
        const aec = context.erosion_topsoil_constituent_pools[first + exchange.start + 1];
        inline for (.{ sand, silt, clay, cec, aec, canonical_mass }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSuspendedTopsoilCandidate;
        if (canonical_mass < 0) return error.InvalidSuspendedTopsoilCandidate;
        context.soil_solver_properties.sand_mass_megagrams[layer] = sand;
        context.soil_solver_properties.silt_mass_megagrams[layer] = silt;
        context.soil_solver_properties.clay_mass_megagrams[layer] = clay;
        context.soil_solver_properties.sand_mass_fraction[layer] = if (canonical_mass > 0) sand / canonical_mass else 0;
        context.soil_solver_properties.silt_mass_fraction[layer] = if (canonical_mass > 0) silt / canonical_mass else 0;
        context.soil_solver_properties.clay_mass_fraction[layer] = if (canonical_mass > 0) clay / canonical_mass else 0;
        context.soil_solver_properties.cation_exchange_capacity_mol[layer] = cec;
        context.soil_solver_properties.anion_exchange_capacity_mol[layer] = aec;
        context.soil_solver_properties.cation_exchange_capacity_mol_per_megagram[layer] = if (canonical_mass > 0) cec / canonical_mass else 0;
        context.soil_solver_properties.anion_exchange_capacity_mol_per_megagram[layer] = if (canonical_mass > 0) aec / canonical_mass else 0;
    }
}

noinline fn copySuspendedFamilyBuffer(
    state: *const ecosys.suspended_constituents.State,
    family: ecosys.suspended_constituents.Family,
    source: []const f64,
    destination: []f64,
) !void {
    const range = try state.layout.range(family);
    if (source.len != state.pools.len or destination.len != state.cell_count * range.len)
        return error.InvalidSuspendedConstituentDimensions;
    for (0..state.cell_count) |cell| {
        const src = cell * state.component_count + range.start;
        const dst = cell * range.len;
        @memcpy(destination[dst..][0..range.len], source[src..][0..range.len]);
    }
}

noinline fn copySuspendedFamilyDiagnostics(
    state: *const ecosys.suspended_constituents.State,
    family: ecosys.suspended_constituents.Family,
    workspace: *ecosys.eroded_constituents.PackedWorkspace,
) !void {
    const range = try state.layout.range(family);
    if (workspace.cell_count != state.cell_count or workspace.component_count != range.len)
        return error.InvalidSuspendedConstituentDimensions;
    try copySuspendedFamilyBuffer(state, family, state.pools, workspace.pools);
    try copySuspendedFamilyBuffer(state, family, state.exported, workspace.exported);
    try copySuspendedFamilyBuffer(state, family, state.flux.east, workspace.flux.east);
    try copySuspendedFamilyBuffer(state, family, state.flux.west, workspace.flux.west);
    try copySuspendedFamilyBuffer(state, family, state.flux.south, workspace.flux.south);
    try copySuspendedFamilyBuffer(state, family, state.flux.north, workspace.flux.north);
}

noinline fn copySuspendedMineralDiagnostics(
    state: *const ecosys.suspended_constituents.State,
    workspace: *ecosys.eroded_constituents.PackedWorkspace,
) !void {
    const texture = try state.layout.range(.mineral_texture);
    const exchange = try state.layout.range(.exchange_capacity);
    if (workspace.cell_count != state.cell_count or workspace.component_count != texture.len + exchange.len)
        return error.InvalidSuspendedConstituentDimensions;
    const sources = .{ state.pools, state.exported, state.flux.east, state.flux.west, state.flux.south, state.flux.north };
    const destinations = .{ workspace.pools, workspace.exported, workspace.flux.east, workspace.flux.west, workspace.flux.south, workspace.flux.north };
    inline for (sources, destinations) |source, destination| for (0..state.cell_count) |cell| {
        const src = cell * state.component_count;
        const dst = cell * workspace.component_count;
        @memcpy(destination[dst..][0..texture.len], source[src + texture.start ..][0..texture.len]);
        @memcpy(destination[dst + texture.len ..][0..exchange.len], source[src + exchange.start ..][0..exchange.len]);
    };
}

noinline fn prepareErosionSurfaceExchange(context: anytype) !void {
    try ecosys.sediment_routing.route(
        &context.surface_erosion.routing,
        context.surface_erosion.transportable_sediment_megagrams,
        context.surface_runoff.total_runoff_m3_per_step,
        .{ .east_m3 = context.surface_runoff.east_runoff_m3_per_step, .west_m3 = context.surface_runoff.west_runoff_m3_per_step, .south_m3 = context.surface_runoff.south_runoff_m3_per_step, .north_m3 = context.surface_runoff.north_runoff_m3_per_step },
        .{
            .east_open = context.surface_erosion.east_boundary_open,
            .west_open = context.surface_erosion.west_boundary_open,
            .south_open = context.surface_erosion.south_boundary_open,
            .north_open = context.surface_erosion.north_boundary_open,
            .lateral_connection_mode_by_cell = context.lateral_connection_mode_by_cell,
        },
        context.runscript.surface_runoff_parameters.negligible_water_m3,
    );
    const erosion_mineral_geometry: ecosys.surface_pond_particulate_settling.MineralColumnGeometry = .{
        .cell_count = context.grid.cell_count,
        .soil_layer_capacity = context.grid.soil_layer_capacity,
        .surface_soil_layer_by_cell = context.soil_geometry.first_active_layer,
        .active_soil_layer_count_by_cell = context.soil_geometry.active_layer_count,
        .soil_bulk_density_megagrams_per_m3 = context.soil_solver_properties.bulk_density_megagrams_per_m3,
        .matrix_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3,
    };
    for (0..context.grid.cell_count) |cell| {
        const local = try ecosys.surface_pond_particulate_settling.firstMineralLayer(
            erosion_mineral_geometry,
            cell,
        );
        const top_layer = try context.grid.layerIndex(cell, local);
        const canonical_mass = context.soil_solver_properties.matrix_bulk_volume_m3[top_layer] *
            context.soil_solver_properties.bulk_density_megagrams_per_m3[top_layer];
        if (!std.math.isFinite(canonical_mass) or canonical_mass <= 0)
            return error.InvalidSurfaceChemistryErosionCarrier;
        context.erosion_topsoil_layer_by_cell[cell] = local;
        context.erosion_canonical_topsoil_mass_megagrams[cell] = canonical_mass;
        context.erosion_topsoil_zone_fractions[cell] =
            try context.fertilizer_band.scienceZoneFractionsForFlatIndex(top_layer);
    }
    try packSuspendedSurface(context);
    try ecosys.suspended_constituents.exchangeLocal(
        context.suspended_constituents,
        context.surface_erosion.surface_soil_mass_megagrams,
        context.erosion_topsoil_constituent_pools,
        context.surface_erosion.local_detachment_megagrams,
        context.erosion_topsoil_layer_by_cell,
    );
    try ecosys.layer_local_conservation.accumulateSuspendedLocalExchange(
        context.hourly_layer_boundary_ledger,
        context.suspended_constituents,
        context.soil_organic,
        context.grid.active_soil_layer_count,
        .{
            .carbon = 12.0,
            .nitrogen = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
            .phosphorus = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        },
    );
    try unpackSuspendedSurface(context);

    try copySuspendedFamilyBuffer(
        context.suspended_constituents,
        .organic_cnp,
        context.suspended_constituents.local_transfer_to_suspension,
        context.eroded_organic_workspace.pools,
    );
    try ecosys.soil_erosion_organic_bridge.publishLocalCarbonNetChangeMapped(
        context.soil_organic,
        context.grid.soil_layer_capacity,
        context.erosion_topsoil_layer_by_cell,
        context.eroded_organic_workspace.pools,
        context.erosion_organic_carbon_net_change_g_c,
    );
}

noinline fn routeSuspendedErosionAndAccumulate(context: anytype) !void {
    const directional_sediment: ecosys.suspended_constituents.DirectionalSediment = .{
        .east_megagrams = context.surface_erosion.routing.east_flux_megagrams,
        .west_megagrams = context.surface_erosion.routing.west_flux_megagrams,
        .south_megagrams = context.surface_erosion.routing.south_flux_megagrams,
        .north_megagrams = context.surface_erosion.routing.north_flux_megagrams,
    };
    try ecosys.suspended_constituents.route(
        context.suspended_constituents,
        context.config.lon_count,
        context.config.lat_count,
        directional_sediment,
    );
    try copySuspendedFamilyDiagnostics(context.suspended_constituents, .organic_cnp, context.eroded_organic_workspace);
    try copySuspendedFamilyDiagnostics(context.suspended_constituents, .nitrogen_fertilizer, context.eroded_fertilizer_workspace);
    try copySuspendedFamilyDiagnostics(context.suspended_constituents, .dry_mineral_fertilizer, context.eroded_mineral_fertilizer_workspace);
    try copySuspendedFamilyDiagnostics(context.suspended_constituents, .chemistry_live_and_pending, context.eroded_chemistry_workspace);
    try copySuspendedMineralDiagnostics(context.suspended_constituents, &context.eroded_mineral_state.workspace);

    try ecosys.soil_erosion_organic_bridge.refreshSurfaceOrganicCarbonGPerMgMapped(
        context.soil_organic,
        context.grid.soil_layer_capacity,
        context.erosion_topsoil_layer_by_cell,
        context.erosion_canonical_topsoil_mass_megagrams,
        context.soil_solver_properties.total_organic_carbon_g_per_megagram,
    );
    try ecosys.hourly_cell_conservation.accumulateErosionTransport(
        context.hourly_cell_boundary_ledger,
        context.config.lon_count,
        context.config.lat_count,
        context.soil_organic,
        context.eroded_organic_workspace,
        context.eroded_fertilizer_workspace,
        context.eroded_mineral_fertilizer_workspace,
        context.eroded_chemistry_workspace,
        &context.eroded_mineral_state.workspace,
        12,
        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        .{
            .absolute_g = 64 * std.math.floatEps(f64),
            .absolute_mol = 64 * std.math.floatEps(f64),
            .absolute_megagrams = 64 * std.math.floatEps(f64),
            .relative = 64 * std.math.floatEps(f64),
        },
    );
    try ecosys.layer_local_conservation.accumulateSurfaceErosionRoutingActivity(
        context.hourly_layer_boundary_ledger,
        context.config.lon_count,
        context.config.lat_count,
        context.soil_organic,
        context.eroded_organic_workspace,
        context.eroded_fertilizer_workspace,
        context.eroded_mineral_fertilizer_workspace,
        context.eroded_chemistry_workspace,
        &context.eroded_mineral_state.workspace,
        12,
        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        .{
            .absolute_g = 64 * std.math.floatEps(f64),
            .absolute_mol = 64 * std.math.floatEps(f64),
            .absolute_megagrams = 64 * std.math.floatEps(f64),
            .relative = 64 * std.math.floatEps(f64),
        },
    );
}

noinline fn publishAcceptedErosion(context: anytype) !void {
    const eroded_organic_export =
        try ecosys.soil_erosion_organic_bridge.exportedElements(
            context.soil_organic,
            context.eroded_organic_workspace,
        );
    const eroded_fertilizer_export =
        try ecosys.soil_erosion_fertilizer_bridge.exported(
            context.eroded_fertilizer_workspace,
            context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        );
    const eroded_chemistry_export =
        try ecosys.soil_erosion_chemistry_bridge.exported(
            context.eroded_chemistry_workspace,
            12,
            context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
            context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        );
    const eroded_mineral_fertilizer_export =
        try ecosys.soil_erosion_mineral_fertilizer_bridge.exported(
            context.eroded_mineral_fertilizer_workspace,
            12,
            context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        );
    try context.landscape_boundary_ledger.accumulateAccepted(.{
        .carbon_output_g_c = eroded_organic_export.carbon_g_c +
            eroded_chemistry_export.inorganic_carbon_g_c +
            eroded_mineral_fertilizer_export.inorganic_carbon_g_c,
        .nitrogen_output_g_n = eroded_organic_export.nitrogen_g_n +
            eroded_fertilizer_export.nitrogen_g_n +
            eroded_chemistry_export.nitrogen_g_n,
        .phosphorus_output_g_p = eroded_organic_export.phosphorus_g_p +
            eroded_chemistry_export.phosphorus_g_p +
            eroded_mineral_fertilizer_export.phosphorus_g_p,
        .ion_output_mol = eroded_fertilizer_export.ion_mol +
            eroded_chemistry_export.ion_mol +
            eroded_mineral_fertilizer_export.ion_mol,
    });
    try ecosys.soil_sediment_change.publishAcceptedNetSedimentMg(context.surface_soil_mass_at_erosion_start_megagrams, context.surface_erosion.surface_soil_mass_megagrams, context.net_sediment_megagrams_per_h);
    @memcpy(context.transport_hydrology.runoff_total_m3_per_step, context.surface_runoff.total_runoff_m3_per_step);
    @memcpy(context.transport_hydrology.runoff_east_m3_per_step, context.surface_runoff.east_runoff_m3_per_step);
    @memcpy(context.transport_hydrology.runoff_west_m3_per_step, context.surface_runoff.west_runoff_m3_per_step);
    @memcpy(context.transport_hydrology.runoff_south_m3_per_step, context.surface_runoff.south_runoff_m3_per_step);
    @memcpy(context.transport_hydrology.runoff_north_m3_per_step, context.surface_runoff.north_runoff_m3_per_step);
}

/// Explicit soil.f production phases. Multiple calls remain one atomic hour
/// because the enclosing heat/water/solute stage owns the memory snapshot.
pub const ProductionPhase = enum { nitro, solute, surface_gas, erosion_redist };

pub noinline fn routeSedimentAndErosion(
    context: anytype,
    phase: ProductionPhase,
    hour_of_day: u8,
    weather_header_by_cell: []const ecosys.weather.Header,
    plant_calendar_by_cell: []const ecosys.plant_development.Calendar,
    fertilizer_band_hour: ecosys.fertilizer_band_phase_coordinator.HourToken,
    gas_failure_report: ?ecosys.soil_gas_transport_step.FailureReportRequest,
    solute_failure_report: ?ecosys.solute_failure_reporter.Request,
    diagnostic_first_hour: anytype,
    plant_calendar: anytype,
    snow_phase_change_report: anytype,
    snow_vapor_equilibrium_report: anytype,
    subsurface_irrigation_chemistry_parameters: anytype,
    diagnostic_previous_heat_megajoules_ptr: anytype,
    diagnostic_previous_n_g_ptr: anytype,
    diagnostic_previous_p_g_ptr: anytype,
) !void {
    _ = hour_of_day;
    _ = weather_header_by_cell;
    _ = plant_calendar_by_cell;
    _ = plant_calendar;
    var diagnostic_previous_heat_megajoules = diagnostic_previous_heat_megajoules_ptr.*;
    defer diagnostic_previous_heat_megajoules_ptr.* = diagnostic_previous_heat_megajoules;
    var diagnostic_previous_n_g = diagnostic_previous_n_g_ptr.*;
    defer diagnostic_previous_n_g_ptr.* = diagnostic_previous_n_g;
    var diagnostic_previous_p_g = diagnostic_previous_p_g_ptr.*;
    defer diagnostic_previous_p_g_ptr.* = diagnostic_previous_p_g;
    var diagnostic_biogeochemistry_n_before_g: f64 = 0;
    if (phase == .erosion_redist) {
        try prepareErosionSurfaceExchange(context);
        try routeSuspendedErosionAndAccumulate(context);
        try publishAcceptedErosion(context);
        if (diagnostic_first_hour) {
            const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
            std.log.debug("nitrogen stage: erosion delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
            diagnostic_previous_n_g = current_n_g;
            const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
            std.log.info("phosphorus stage: erosion delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
            diagnostic_previous_p_g = current_p_g;
        }
    }
    try routeBiogeochemistryAndSolutes(
        context,
        phase,
        fertilizer_band_hour,
        gas_failure_report,
        solute_failure_report,
        diagnostic_first_hour,
        snow_phase_change_report,
        snow_vapor_equilibrium_report,
        subsurface_irrigation_chemistry_parameters,
        &diagnostic_biogeochemistry_n_before_g,
        &diagnostic_previous_heat_megajoules,
        &diagnostic_previous_n_g,
        &diagnostic_previous_p_g,
    );
}

fn pondDonorLayerThickness(expanded_litter_volume_m3: f64, area_m2: f64) !f64 {
    if (!std.math.isFinite(expanded_litter_volume_m3) or
        expanded_litter_volume_m3 < 0 or
        !std.math.isFinite(area_m2) or area_m2 <= 0)
        return error.InvalidSurfacePondSettlingGeometry;
    const thickness_m = expanded_litter_volume_m3 / area_m2;
    if (!std.math.isFinite(thickness_m))
        return error.InvalidSurfacePondSettlingGeometry;
    return thickness_m;
}

test "pond settling uses expanded surface-layer depth rather than free water depth" {
    // A dry litter layer still has positive DLYR(3,0) in HOUR1 and remains a
    // valid L=0 donor when the soil surface is a pond layer.
    try std.testing.expectEqual(
        @as(f64, 0.02),
        try pondDonorLayerThickness(0.2, 10),
    );
    try std.testing.expectError(
        error.InvalidSurfacePondSettlingGeometry,
        pondDonorLayerThickness(0.2, 0),
    );
}

pub fn accumulateAcceptedHydrogenTransformations(
    ledger: *ecosys.landscape_boundary_ledger.State,
    cell_ledger: *ecosys.hourly_cell_conservation.BoundaryLedger,
    active_soil_layer_count: []const usize,
    soil_layer_capacity: usize,
    process_units_per_layer: usize,
    soil_fermentation_production_g_h: []const f64,
    soil_methanogenesis_consumption_g_h: []const f64,
    surface_fermentation_production_g_h: []const f64,
    surface_autotrophic_primary_reaction: []const f64,
) !void {
    const surface_population_count = ecosys.surface_autotrophic_complex_step.active_population_count;
    // Zero-based active index 3 is source population N=5. nitro.f:1649-1664
    // converts its accepted CO2 reduction to H2 uptake (RH2GZ), and
    // nitro.f:4006-4017 publishes RH2GO = RH2GZ - TRGOH. The modern primary
    // reaction has already applied the accepted O2/cell scaling and is g H.
    const surface_hydrogenotroph_index: usize = 3;
    comptime std.debug.assert(ecosys.surface_autotrophic_complex_step.source_population_by_active[surface_hydrogenotroph_index] == 4);
    const layer_count = std.math.mul(usize, active_soil_layer_count.len, soil_layer_capacity) catch
        return error.HydrogenTransformationDimensionMismatch;
    const product_count = std.math.mul(usize, layer_count, process_units_per_layer) catch
        return error.HydrogenTransformationDimensionMismatch;
    const surface_reaction_count = std.math.mul(usize, active_soil_layer_count.len, surface_population_count) catch
        return error.HydrogenTransformationDimensionMismatch;
    if (active_soil_layer_count.len == 0 or cell_ledger.cells.len != active_soil_layer_count.len or soil_layer_capacity == 0 or process_units_per_layer == 0 or
        soil_fermentation_production_g_h.len != product_count or
        soil_methanogenesis_consumption_g_h.len != layer_count or
        surface_fermentation_production_g_h.len != active_soil_layer_count.len or
        surface_autotrophic_primary_reaction.len != surface_reaction_count)
        return error.HydrogenTransformationDimensionMismatch;

    var production_g_h: f64 = 0;
    var consumption_g_h: f64 = 0;
    for (active_soil_layer_count, 0..) |active_layers, cell| {
        if (active_layers == 0 or active_layers > soil_layer_capacity)
            return error.HydrogenTransformationDimensionMismatch;
        for (0..active_layers) |local_layer| {
            const layer = cell * soil_layer_capacity + local_layer;
            const first_unit = layer * process_units_per_layer;
            for (soil_fermentation_production_g_h[first_unit..][0..process_units_per_layer]) |value| {
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidAcceptedHydrogenTransformation;
                production_g_h += value;
            }
            const value = soil_methanogenesis_consumption_g_h[layer];
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidAcceptedHydrogenTransformation;
            consumption_g_h += value;
        }
        const value = surface_fermentation_production_g_h[cell];
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidAcceptedHydrogenTransformation;
        production_g_h += value;
        const surface_hydrogenotroph_consumption_g_h = surface_autotrophic_primary_reaction[cell * surface_population_count + surface_hydrogenotroph_index];
        if (!std.math.isFinite(surface_hydrogenotroph_consumption_g_h) or surface_hydrogenotroph_consumption_g_h < 0)
            return error.InvalidAcceptedHydrogenTransformation;
        consumption_g_h += surface_hydrogenotroph_consumption_g_h;
    }
    // Preflight each cell before either the domain or cell ledger changes.
    // Re-evaluating the already-validated source arrays below avoids a runtime
    // allocation in this accepted-hour path.
    for (active_soil_layer_count, 0..) |active_layers, cell| {
        var cell_production_g_h = surface_fermentation_production_g_h[cell];
        var cell_consumption_g_h = surface_autotrophic_primary_reaction[cell * surface_population_count + surface_hydrogenotroph_index];
        for (0..active_layers) |local_layer| {
            const layer = cell * soil_layer_capacity + local_layer;
            const first_unit = layer * process_units_per_layer;
            for (soil_fermentation_production_g_h[first_unit..][0..process_units_per_layer]) |value|
                cell_production_g_h += value;
            cell_consumption_g_h += soil_methanogenesis_consumption_g_h[layer];
        }
        if (!std.math.isFinite(cell_production_g_h) or !std.math.isFinite(cell_consumption_g_h))
            return error.InvalidAcceptedHydrogenTransformation;
        try cell_ledger.preflight(cell, .{
            .hydrogen_internal_production_g = cell_production_g_h,
            .hydrogen_internal_consumption_g = cell_consumption_g_h,
        });
    }
    try ledger.accumulateAcceptedHydrogenTransformationTotals(production_g_h, consumption_g_h);
    for (active_soil_layer_count, 0..) |active_layers, cell| {
        var cell_production_g_h = surface_fermentation_production_g_h[cell];
        var cell_consumption_g_h = surface_autotrophic_primary_reaction[cell * surface_population_count + surface_hydrogenotroph_index];
        for (0..active_layers) |local_layer| {
            const layer = cell * soil_layer_capacity + local_layer;
            const first_unit = layer * process_units_per_layer;
            for (soil_fermentation_production_g_h[first_unit..][0..process_units_per_layer]) |value|
                cell_production_g_h += value;
            cell_consumption_g_h += soil_methanogenesis_consumption_g_h[layer];
        }
        try cell_ledger.accumulate(cell, .{
            .hydrogen_internal_production_g = cell_production_g_h,
            .hydrogen_internal_consumption_g = cell_consumption_g_h,
        });
    }
}

test "accepted hourly hydrogen transformations bind active soil and surface owners once" {
    var ledger: ecosys.landscape_boundary_ledger.State = .{};
    var cell_ledger = try ecosys.hourly_cell_conservation.BoundaryLedger.init(std.testing.allocator, 2);
    defer cell_ledger.deinit();
    const checkpoint_ledger = ledger;
    const checkpoint_cells = [_]ecosys.hourly_cell_conservation.BoundaryActivity{ cell_ledger.cells[0], cell_ledger.cells[1] };
    const surface_primary = [_]f64{
        // Only active index 3 (source N=5) is H2 uptake. Large values in the
        // other populations prove they are neither misclassified nor summed.
        100, 100, 100, 2,
        100, 100, 100, 3,
    };
    try accumulateAcceptedHydrogenTransformations(
        &ledger,
        &cell_ledger,
        &.{ 1, 2 },
        2,
        2,
        // Cell 0 layer 1 is inactive and deliberately contains stale mass.
        &.{ 1, 2, 100, 100, 3, 4, 5, 6 },
        &.{ 0.5, 100, 0.25, 0.75 },
        &.{ 7, 8 },
        &surface_primary,
    );
    try std.testing.expectEqual(@as(f64, 36), ledger.cumulative_internal.hydrogen_production_g_h);
    try std.testing.expectEqual(@as(f64, 6.5), ledger.cumulative_internal.hydrogen_consumption_g_h);
    try std.testing.expectEqual(@as(f64, 10), cell_ledger.cells[0].hydrogen_internal_production_g);
    try std.testing.expectEqual(@as(f64, 26), cell_ledger.cells[1].hydrogen_internal_production_g);
    try std.testing.expectEqual(@as(f64, 2.5), cell_ledger.cells[0].hydrogen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 4), cell_ledger.cells[1].hydrogen_internal_consumption_g);
    try std.testing.expectEqual(
        ledger.cumulative_internal.hydrogen_production_g_h,
        cell_ledger.cells[0].hydrogen_internal_production_g + cell_ledger.cells[1].hydrogen_internal_production_g,
    );
    try std.testing.expectEqual(
        ledger.cumulative_internal.hydrogen_consumption_g_h,
        cell_ledger.cells[0].hydrogen_internal_consumption_g + cell_ledger.cells[1].hydrogen_internal_consumption_g,
    );

    const accepted_ledger = ledger;
    const accepted_cells = [_]ecosys.hourly_cell_conservation.BoundaryActivity{ cell_ledger.cells[0], cell_ledger.cells[1] };
    try std.testing.expectError(
        error.InvalidAcceptedHydrogenTransformation,
        accumulateAcceptedHydrogenTransformations(
            &ledger,
            &cell_ledger,
            &.{ 1, 2 },
            2,
            2,
            &.{ 1, 2, 0, 0, 3, 4, 5, 6 },
            &.{ 0.5, 0, 0.25, 0.75 },
            &.{ 7, 8 },
            &.{ 0, 0, 0, 2, 0, 0, 0, -3 },
        ),
    );
    try std.testing.expectEqualDeep(accepted_ledger, ledger);
    try std.testing.expectEqualSlices(ecosys.hourly_cell_conservation.BoundaryActivity, &accepted_cells, cell_ledger.cells);

    // An enclosing failed-hour transaction restores its checkpoint before
    // retrying. Replaying the accepted owners must reproduce one publication,
    // not retain or double the failed attempt's ledger side effects.
    ledger = checkpoint_ledger;
    @memcpy(cell_ledger.cells, &checkpoint_cells);
    try accumulateAcceptedHydrogenTransformations(
        &ledger,
        &cell_ledger,
        &.{ 1, 2 },
        2,
        2,
        &.{ 1, 2, 100, 100, 3, 4, 5, 6 },
        &.{ 0.5, 100, 0.25, 0.75 },
        &.{ 7, 8 },
        &surface_primary,
    );
    try std.testing.expectEqualDeep(accepted_ledger, ledger);
    try std.testing.expectEqualSlices(ecosys.hourly_cell_conservation.BoundaryActivity, &accepted_cells, cell_ledger.cells);
}

test "hourly production publishes accepted surface K5 hydrogen uptake once" {
    const source = @embedFile("hourly_process_driver.zig");
    const binding = "context.surface_autotrophic_complex.actual_primary_reaction,";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, binding));
    const accepted_call_tail =
        \\        context.surface_microbial_oxygen.respiration_hydrogen_g_h_per_step,
        \\        context.surface_autotrophic_complex.actual_primary_reaction,
        \\    );
    ;
    try std.testing.expect(std.mem.indexOf(u8, source, accepted_call_tail) != null);
}

noinline fn settlePondParticulatesAndRebaseHeat(
    context: anytype,
    pond_soil_dry_mass_megagrams: []f64,
    pond_zone_fractions_by_layer: []const ecosys.solute_charge_classification.ZoneFractions,
    pond_ammonium_non_band_fraction: []const f64,
    pond_phosphate_non_band_fraction: []const f64,
    pond_settling_geometry: ecosys.surface_pond_particulate_settling.SeparatedSurfaceGeometry,
    settling_carbon_before_g_c: []const f64,
) !void {
    try ecosys.surface_pond_particulate_settling.applyWithChemistryAndGeometry(.{
        .surface_organic = context.surface_organic,
        .soil_organic = context.soil_organic,
        .surface_gas = context.litter_gas_transport,
        .soil_gas = context.gas_transport,
        .surface_nitrogen_fertilizer = context.surface_litter_fertilizer,
        .soil_nitrogen_fertilizer = context.soil_fertilizer_inventory,
        .mineral_fertilizer = context.mineral_fertilizer_inventory,
    }, .{
        .surface = context.surface_litter_chemistry,
        .soil = context.soil_chemistry,
        .surface_dry_mass_megagrams = context.surface_litter_geometry.dry_mass_megagrams,
        .soil_dry_mass_megagrams = pond_soil_dry_mass_megagrams,
        .soil_matrix_water_m3 = context.grid.matrix_liquid_water_m3,
        .cell_area_m2 = context.canopy_cell_area_m2,
        .ammonium_non_band_fraction_by_cell = pond_ammonium_non_band_fraction,
        .phosphate_non_band_water_fraction_by_cell = pond_phosphate_non_band_fraction,
        .soil_properties = context.soil_solver_properties,
        .zone_fractions_by_layer = pond_zone_fractions_by_layer,
    }, .{
        .surface_sediment_megagrams = context.surface_erosion.surface_sediment_megagrams,
        .surface_soil_mass_megagrams = context.surface_erosion.surface_soil_mass_megagrams,
        .settled_sediment_megagrams = context.surface_erosion.pond_settled_sediment_megagrams,
        .accepted_sidecar = context.surface_pond_domain_workspace.particulateSidecar(),
        .accepted_soil_layer_sidecar = context.surface_pond_domain_workspace.particulateSoilLayerSidecar(),
    }, pond_settling_geometry, 1);

    const settling_carbon_after_g_c = try context.allocator.alloc(f64, context.grid.cell_count);
    defer context.allocator.free(settling_carbon_after_g_c);
    for (settling_carbon_after_g_c, 0..) |*carbon, cell|
        carbon.* = try context.surface_organic.totalCarbon_g_c(cell);
    const settling_heat_rebase_by_cell = try context.allocator.alloc(f64, context.grid.cell_count);
    defer context.allocator.free(settling_heat_rebase_by_cell);
    try ecosys.surface_litter_organic_heat_rebase.landscapeOrganicCarbonRebaseHeatMegajoulesByCell(
        settling_heat_rebase_by_cell,
        settling_carbon_before_g_c,
        settling_carbon_after_g_c,
        context.grid.surface_temperature_k,
        context.runscript.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
    );
    try publishSurfaceOrganicHeatRebase(
        context,
        settling_heat_rebase_by_cell,
        settling_carbon_before_g_c,
        settling_carbon_after_g_c,
    );
}

/// One owner for the REDIST 4318-4330 fixed-temperature surface organic heat
/// rebase. The census prices surface litter at
/// `dry_organic_heat_capacity * total_organic_carbon * T`, so any span that
/// moves or destroys surface organic carbon changes stored enthalpy at fixed
/// temperature and must publish that change to **all three** heat ledgers --
/// cell, layer, and landscape -- exactly as
/// `hourly_heat_water_solute.publishLitterSoilOrganicHeatRebase` and the
/// runoff rebase in `hourly_gas_surface_water.zig` already do.
///
/// This exists because the settling span published only to the cell and
/// landscape scopes while the surface-biogeochemistry span published to all
/// three. The layer ledger's surface scope therefore carried a
/// fixed-temperature enthalpy change it never saw booked. Routing both spans
/// through one owner makes the three-ledger rule structural rather than a
/// convention each new call site has to remember.
///
/// Callers must bracket their own mutation with the `before`/`after` carbon
/// snapshots they pass here. Spans that move carbon without touching a heat
/// carrier have no paired transfer, so this internal-heat booking is the only
/// booking and cannot double-count; spans that do move a heat carrier must
/// not route through here.
noinline fn publishSurfaceOrganicHeatRebase(
    context: anytype,
    heat_rebase_by_cell: []const f64,
    carbon_before_g_c: []const f64,
    carbon_after_g_c: []const f64,
) !void {
    try context.hourly_cell_boundary_ledger.accumulateSignedInternalHeat(heat_rebase_by_cell);
    try ecosys.layer_local_conservation.accumulateSurfaceOrganicHeatRebase(
        context.hourly_layer_boundary_ledger,
        heat_rebase_by_cell,
    );
    try context.landscape_boundary_ledger.accumulateAcceptedSignedInternalHeat(
        try ecosys.surface_litter_organic_heat_rebase.landscapeOrganicCarbonRebaseHeatMegajoules(
            carbon_before_g_c,
            carbon_after_g_c,
            context.grid.surface_temperature_k,
            context.runscript.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
        ),
    );
}

noinline fn applyPondDomainTransferAndAccumulate(
    context: anytype,
    pond_ammonium_non_band_fraction: []const f64,
    pond_nitrate_non_band_fraction: []const f64,
    pond_phosphate_non_band_fraction: []const f64,
    pond_phosphate_band_fraction: []const f64,
) !void {
    try ecosys.surface_pond_domain_transaction.apply(context.surface_pond_domain_workspace, .{
        .inventories = .{
            .surface_organic = context.surface_organic,
            .soil_organic = context.soil_organic,
            .surface_gas = context.litter_gas_transport,
            .soil_gas = context.gas_transport,
            .surface_nitrogen_fertilizer = context.surface_litter_fertilizer,
            .soil_nitrogen_fertilizer = context.soil_fertilizer_inventory,
            .mineral_fertilizer = context.mineral_fertilizer_inventory,
        },
        .surface_chemistry = context.surface_litter_chemistry,
        .soil_chemistry = context.soil_chemistry,
        .micropore_solutes = context.micropore_solute_state,
        .water_heat = .{
            .surface_liquid_water_m3 = context.surface_precipitation.litter_water_m3,
            .surface_ice_m3 = context.surface_litter_ice_m3,
            .surface_temperature_k = context.grid.surface_temperature_k,
            .surface_geometry = context.surface_litter_geometry,
            .grid = context.grid,
            .soil_thermal = context.soil_thermal,
        },
        .soil_geometry = context.soil_geometry,
        .soil_properties = context.soil_solver_properties,
        .soil_faces = context.soil_transport_faces,
        .soil_face_geometry = context.soil_face_geometry,
    }, .{
        .transitions = context.surface_pond_transition,
        .salinity_enabled_by_cell = context.salinity_enabled_by_cell,
        .water_heat_parameters = .{
            .dry_organic_heat_capacity_megajoules_per_g_c_k = context.runscript.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
            .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
            .ice_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
            .ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
            .minimum_heat_capacity_megajoules_per_k = 0,
        },
        .minimum_heat_capacity_megajoules_per_k = context.surface_pond_minimum_heat_capacity_megajoules_per_k,
        .minimum_soil_layer_thickness_m = context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
        .horizontal_cell_width_m = context.horizontal_cell_width_m,
        .vertical_cell_width_m = context.vertical_cell_width_m,
        .ammonium_non_band_water_fraction_by_cell = pond_ammonium_non_band_fraction,
        .nitrate_non_band_water_fraction_by_cell = pond_nitrate_non_band_fraction,
        .phosphate_non_band_water_fraction_by_cell = pond_phosphate_non_band_fraction,
        .phosphate_band_water_fraction_by_cell = pond_phosphate_band_fraction,
        .water_molar_mass_g_per_mol = context.runscript.soil_gas_transport_parameters.water_molar_mass_g_per_mol,
        .liquid_water_density_g_per_m3 = context.runscript.soil_gas_transport_parameters.water_density_g_per_m3,
    });
    try ecosys.layer_local_conservation.accumulatePondAcceptedTransfers(
        context.hourly_layer_boundary_ledger,
        context.grid.active_soil_layer_count,
        context.surface_pond_domain_workspace.particulateSidecar(),
        context.surface_pond_domain_workspace.particulateSoilLayerSidecar(),
        context.surface_pond_domain_workspace.domainSidecar(),
        .{
            .carbon = 12.0,
            .nitrogen = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
            .phosphorus = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        },
    );
}

noinline fn routePondSettlingAndFinalize(
    context: anytype,
    phase: ProductionPhase,
    diagnostic_first_hour: anytype,
    snow_phase_change_report: anytype,
    snow_vapor_equilibrium_report: anytype,
    subsurface_irrigation_chemistry_parameters: anytype,
    diagnostic_previous_heat_megajoules_ptr: anytype,
    diagnostic_previous_n_g_ptr: anytype,
    diagnostic_previous_p_g_ptr: anytype,
) !void {
    var diagnostic_previous_heat_megajoules = diagnostic_previous_heat_megajoules_ptr.*;
    defer diagnostic_previous_heat_megajoules_ptr.* = diagnostic_previous_heat_megajoules;
    var diagnostic_previous_n_g = diagnostic_previous_n_g_ptr.*;
    defer diagnostic_previous_n_g_ptr.* = diagnostic_previous_n_g;
    var diagnostic_previous_p_g = diagnostic_previous_p_g_ptr.*;
    defer diagnostic_previous_p_g_ptr.* = diagnostic_previous_p_g;
    if (phase == .erosion_redist) {
        try diagnostics.traceStageBoundaryLayer0Carbon(context, "before_pond_settling");
        const diagnostic_pond_before = if (diagnostic_first_hour) try diagnostics.reconstructLandscapeMassBalance(context) else undefined;
        const diagnostic_ammonium_before = if (diagnostic_first_hour) try diagnostics.diagnosticAmmoniumOwners_g_n(context) else undefined;
        // POND-VOLWD-CONFLATION-001: surface ponding capacity is ground-surface retention
        // depth (runscript parameter, m) times cell area, not litter_water_capacity_m3.
        const surface_ponding_capacity_m3 = try context.allocator.alloc(f64, context.canopy_cell_area_m2.len);
        defer context.allocator.free(surface_ponding_capacity_m3);
        for (surface_ponding_capacity_m3, context.canopy_cell_area_m2) |*cap, area| {
            const represented_capacity_m3 = context.runscript.surface_runoff_parameters.ground_surface_retention_m3_per_m2 * area;
            cap.* = @max(context.config.physical_tolerance.waterVolume(represented_capacity_m3), represented_capacity_m3);
        }
        var pond_transition_context: ecosys.surface_pond_transition_step.ApplyContext = .{
            .result = context.surface_pond_transition,
            .surface_liquid_water_m3 = context.surface_precipitation.litter_water_m3,
            .surface_ice_m3 = context.surface_litter_ice_m3,
            .surface_ponding_capacity_m3 = surface_ponding_capacity_m3,
            .surface_litter_volume_m3 = context.surface_litter_geometry.dry_litter_volume_m3,
            .surface_litter_water_capacity_m3 = context.surface_litter_geometry.water_retention_capacity_m3,
            .horizontal_area_m2 = context.canopy_cell_area_m2,
            .minimum_heat_capacity_megajoules_per_k = context.surface_pond_minimum_heat_capacity_megajoules_per_k,
            .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
            .ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
        };
        try tile_kernels.runKernelAcrossSerialTiles(context, &pond_transition_context, ecosys.surface_pond_transition_step.applyTile);
        const diagnostic_heat_before_settling_megajoules = if (diagnostic_first_hour)
            (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules
        else
            0;
        // REDIST lines 333-614: settle represented pond particulates after the
        // biological/chemical state_updates and before runoff-domain redistribution.
        // HEAT-001: unlike `surface_pond_domain_transaction` (which matches heat
        // capacity and enthalpy to the water/organic mass it moves), this transfer
        // moves surface organic carbon into a soil layer's organic pools without
        // touching any heat carrier. The census prices surface litter at
        // `dry_organic_heat_capacity * total_organic_carbon * T`
        // (`litter_organic_heat_rebase.zig`), so carbon leaving the surface pool
        // here silently changes stored enthalpy at fixed temperature, exactly the
        // REDIST 4318-4330 mechanism already booked around
        // `runSurfaceBiogeochemistryBySerialTile` above. Book it the same way.
        const settling_carbon_before_g_c = try context.allocator.alloc(f64, context.grid.cell_count);
        defer context.allocator.free(settling_carbon_before_g_c);
        for (settling_carbon_before_g_c, 0..) |*carbon, cell|
            carbon.* = try context.surface_organic.totalCarbon_g_c(cell);
        const pond_donor_bulk_density_megagrams_per_m3 = try context.allocator.alloc(f64, context.grid.cell_count);
        defer context.allocator.free(pond_donor_bulk_density_megagrams_per_m3);
        const pond_donor_layer_thickness_m = try context.allocator.alloc(f64, context.grid.cell_count);
        defer context.allocator.free(pond_donor_layer_thickness_m);
        const surface_soil_layer_by_cell = try context.allocator.alloc(usize, context.grid.cell_count);
        defer context.allocator.free(surface_soil_layer_by_cell);
        const pond_soil_dry_mass_megagrams = try context.allocator.alloc(f64, context.grid.layer_count);
        defer context.allocator.free(pond_soil_dry_mass_megagrams);
        const pond_zone_fractions_by_layer = try context.allocator.alloc(
            ecosys.solute_charge_classification.ZoneFractions,
            context.grid.layer_count,
        );
        defer context.allocator.free(pond_zone_fractions_by_layer);
        for (pond_soil_dry_mass_megagrams, 0..) |*mass, layer_cell| {
            mass.* = context.soil_solver_properties.bulk_density_megagrams_per_m3[layer_cell] *
                context.soil_solver_properties.matrix_bulk_volume_m3[layer_cell];
            // BKDS == 0 is a represented open-water layer, not malformed soil.
            // REDIST retains particulate chemistry there as extensive pending
            // ownership until a positive dry-mass carrier is available below.
            if (!std.math.isFinite(mass.*) or mass.* < 0)
                return error.InvalidSurfacePondSettlingGeometry;
            pond_zone_fractions_by_layer[layer_cell] =
                try context.fertilizer_band.scienceZoneFractionsForFlatIndex(layer_cell);
        }
        const pond_phosphate_non_band_fraction = try context.allocator.alloc(f64, context.grid.cell_count);
        defer context.allocator.free(pond_phosphate_non_band_fraction);
        const pond_phosphate_band_fraction = try context.allocator.alloc(f64, context.grid.cell_count);
        defer context.allocator.free(pond_phosphate_band_fraction);
        const pond_ammonium_non_band_fraction = try context.allocator.alloc(f64, context.grid.cell_count);
        defer context.allocator.free(pond_ammonium_non_band_fraction);
        const pond_nitrate_non_band_fraction = try context.allocator.alloc(f64, context.grid.cell_count);
        defer context.allocator.free(pond_nitrate_non_band_fraction);
        for (0..context.grid.cell_count) |cell| {
            const first_soil_layer = context.soil_geometry.first_active_layer[cell];
            const active_soil_layers = context.soil_geometry.active_layer_count[cell];
            if (active_soil_layers == 0 or
                first_soil_layer >= context.grid.soil_layer_capacity or
                active_soil_layers > context.grid.soil_layer_capacity - first_soil_layer)
                return error.InvalidSurfacePondSettlingGeometry;
            const area_m2 = context.canopy_cell_area_m2[cell];
            const expanded_litter_volume_m3 =
                context.surface_litter_geometry.expanded_total_volume_m3[cell];
            const litter_dry_mass_megagrams =
                context.surface_litter_geometry.dry_mass_megagrams[cell];
            inline for (.{ expanded_litter_volume_m3, litter_dry_mass_megagrams }) |value|
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidSurfacePondSettlingGeometry;
            // REDIST's L=0 BKDS is the litter dry mass divided by its current
            // volume. Copying terrestrial topsoil BKDS made bare pond water look
            // like mineral soil and disabled this production path. The independent
            // `BKDS(NU)<=0` special case is evaluated by `receiver` from the soil
            // density array below.
            pond_donor_bulk_density_megagrams_per_m3[cell] =
                if (expanded_litter_volume_m3 > 0)
                    litter_dry_mass_megagrams / expanded_litter_volume_m3
                else
                    0;
            // REDIST 346 tests DLYR(3,0), the full current surface-layer depth.
            // HOUR1 constructs that depth from dry litter volume plus only the
            // water/ice volume that expands the layer beyond its retention volume.
            pond_donor_layer_thickness_m[cell] = try pondDonorLayerThickness(
                expanded_litter_volume_m3,
                area_m2,
            );
            surface_soil_layer_by_cell[cell] = first_soil_layer;
        }
        const pond_settling_geometry: ecosys.surface_pond_particulate_settling.SeparatedSurfaceGeometry = .{
            .cell_count = context.grid.cell_count,
            .soil_layer_capacity = context.grid.soil_layer_capacity,
            .donor_bulk_density_megagrams_per_m3 = pond_donor_bulk_density_megagrams_per_m3,
            .donor_layer_thickness_m = pond_donor_layer_thickness_m,
            .surface_soil_layer_by_cell = surface_soil_layer_by_cell,
            .active_soil_layer_count_by_cell = context.soil_geometry.active_layer_count,
            .soil_bulk_density_megagrams_per_m3 = context.soil_solver_properties.bulk_density_megagrams_per_m3,
            .soil_layer_thickness_m = context.soil_geometry.layer_thickness_m,
            .minimum_receiver_thickness_m = context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
        };
        // Pack the exact receiver chosen by REDIST. An ineligible cell is packed
        // against its first active layer only as a no-op transaction participant.
        for (0..context.grid.cell_count) |cell| {
            const first = surface_soil_layer_by_cell[cell];
            const receiver = (try ecosys.surface_pond_particulate_settling.receivingLayer(
                pond_settling_geometry,
                cell,
            )) orelse first;
            const destination = try context.grid.layerIndex(cell, receiver);
            const zone_fractions = try context.fertilizer_band.scienceZoneFractions(cell, receiver);
            context.erosion_topsoil_layer_by_cell[cell] = receiver;
            context.erosion_canonical_topsoil_mass_megagrams[cell] =
                pond_soil_dry_mass_megagrams[destination];
            context.erosion_topsoil_zone_fractions[cell] = zone_fractions;
            pond_ammonium_non_band_fraction[cell] = zone_fractions.ammonium_non_band;
            pond_nitrate_non_band_fraction[cell] = zone_fractions.nitrate_non_band;
            pond_phosphate_non_band_fraction[cell] = zone_fractions.phosphate_non_band;
            pond_phosphate_band_fraction[cell] = zone_fractions.phosphate_band;
        }
        try settlePondParticulatesAndRebaseHeat(
            context,
            pond_soil_dry_mass_megagrams,
            pond_zone_fractions_by_layer,
            pond_ammonium_non_band_fraction,
            pond_phosphate_non_band_fraction,
            pond_settling_geometry,
            settling_carbon_before_g_c,
        );
        try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_pond_settling");
        if (diagnostic_first_hour) {
            const components = try diagnostics.reconstructLandscapeMassBalance(context);
            std.log.debug("heat stage: pre_pond_processes hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, diagnostic_heat_before_settling_megajoules - diagnostic_previous_heat_megajoules });
            std.log.debug("heat stage: particulate_settling hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, components.heat_storage_megajoules - diagnostic_heat_before_settling_megajoules });
            diagnostic_previous_heat_megajoules = components.heat_storage_megajoules;
            std.log.debug("settling nitrogen components: residue={e} organic={e} n2={e} nh4={e} no3={e}", .{ components.residue_nitrogen_g - diagnostic_pond_before.residue_nitrogen_g, components.organic_nitrogen_g - diagnostic_pond_before.organic_nitrogen_g, components.dinitrogen_nitrogen_g - diagnostic_pond_before.dinitrogen_nitrogen_g, components.ammonium_nitrogen_g - diagnostic_pond_before.ammonium_nitrogen_g, components.nitrate_nitrogen_g - diagnostic_pond_before.nitrate_nitrogen_g });
        }
        try applyPondDomainTransferAndAccumulate(
            context,
            pond_ammonium_non_band_fraction,
            pond_nitrate_non_band_fraction,
            pond_phosphate_non_band_fraction,
            pond_phosphate_band_fraction,
        );
        try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_pond_domain_transfer");
        if (diagnostic_first_hour) {
            const heat_megajoules = (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules;
            std.log.debug("heat stage: pond_domain_transaction hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, heat_megajoules - diagnostic_previous_heat_megajoules });
            diagnostic_previous_heat_megajoules = heat_megajoules;
        }
        if (diagnostic_first_hour) {
            const components = try diagnostics.reconstructLandscapeMassBalance(context);
            const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
            std.log.debug("nitrogen stage: pond_transaction delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
            const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
            std.log.info("phosphorus stage: pond_transaction delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
            diagnostic_previous_p_g = current_p_g;
            std.log.debug("pond nitrogen components: residue={e} organic={e} n2={e} nh4={e} no3={e}", .{ components.residue_nitrogen_g - diagnostic_pond_before.residue_nitrogen_g, components.organic_nitrogen_g - diagnostic_pond_before.organic_nitrogen_g, components.dinitrogen_nitrogen_g - diagnostic_pond_before.dinitrogen_nitrogen_g, components.ammonium_nitrogen_g - diagnostic_pond_before.ammonium_nitrogen_g, components.nitrate_nitrogen_g - diagnostic_pond_before.nitrate_nitrogen_g });
            const owners = try diagnostics.diagnosticAmmoniumOwners_g_n(context);
            std.log.debug("pond ammonium owners delta: surface_aq={e} surface_exchange={e} surface_fertilizer={e} soil_aq={e} soil_exchange={e} soil_fertilizer={e}", .{ owners[0] - diagnostic_ammonium_before[0], owners[1] - diagnostic_ammonium_before[1], owners[2] - diagnostic_ammonium_before[2], owners[3] - diagnostic_ammonium_before[3], owners[4] - diagnostic_ammonium_before[4], owners[5] - diagnostic_ammonium_before[5] });
            diagnostic_previous_n_g = current_n_g;
        }
        const diagnostic_pond_after = if (diagnostic_first_hour) try diagnostics.reconstructLandscapeMassBalance(context) else undefined;
        // Snow discharge, nonlinear chemistry, and pond-domain transfers update
        // the concentration owner after hourly mineral-N transport has finished.
        // Rebase its extensive matrix mirror now so end-of-hour audits and restart
        // persistence observe the accepted state rather than the hour-start copy.
        try context.mineral_nitrogen_transport.refreshMatrixFromReactionState(
            context.soil_chemistry,
            context.soil_reactive_nitrogen,
            context.grid.matrix_liquid_water_m3,
            context.fertilizer_band,
            context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        );
        // Pond and settling steps transfer surface_organic.microbial into soil_organic.microbial
        // but cannot reach soil_microbial directly.  Propagate the update now so that
        // soil_microbial and soil_organic.microbial remain in sync before the next d-step.
        try ecosys.soil_microbial_inventory_bridge.publishFromOrganic(
            context.soil_organic,
            context.soil_microbial,
        );
        try diagnostics.traceStageBoundaryLayer0Carbon(context, "before_redist_finalize");
        if (diagnostic_first_hour) {
            const components = try diagnostics.reconstructLandscapeMassBalance(context);
            const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
            std.log.debug("nitrogen stage: post_pond_microbial_refresh delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
            const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
            std.log.info("phosphorus stage: post_pond_microbial_refresh delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
            std.log.debug("phosphorus end science: stored_g={e}", .{current_p_g});
            diagnostic_previous_p_g = current_p_g;
            std.log.debug("post-pond refresh nitrogen components: residue={e} organic={e} n2={e} nh4={e} no3={e}", .{ components.residue_nitrogen_g - diagnostic_pond_after.residue_nitrogen_g, components.organic_nitrogen_g - diagnostic_pond_after.organic_nitrogen_g, components.dinitrogen_nitrogen_g - diagnostic_pond_after.dinitrogen_nitrogen_g, components.ammonium_nitrogen_g - diagnostic_pond_after.ammonium_nitrogen_g, components.nitrate_nitrogen_g - diagnostic_pond_after.nitrate_nitrogen_g });
            diagnostic_previous_n_g = current_n_g;
        }
        try group_vegetation.finalizeRedistAndLedgers(
            context,
            diagnostic_first_hour,
            diagnostic_previous_p_g,
            snow_phase_change_report,
            snow_vapor_equilibrium_report,
            subsurface_irrigation_chemistry_parameters,
        );
        try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_redist_finalize");
    }
}

noinline fn routeBiogeochemistryAndSolutes(
    context: anytype,
    phase: ProductionPhase,
    fertilizer_band_hour: ecosys.fertilizer_band_phase_coordinator.HourToken,
    gas_failure_report: ?ecosys.soil_gas_transport_step.FailureReportRequest,
    solute_failure_report: ?ecosys.solute_failure_reporter.Request,
    diagnostic_first_hour: anytype,
    snow_phase_change_report: anytype,
    snow_vapor_equilibrium_report: anytype,
    subsurface_irrigation_chemistry_parameters: anytype,
    diagnostic_biogeochemistry_n_before_g_ptr: anytype,
    diagnostic_previous_heat_megajoules_ptr: anytype,
    diagnostic_previous_n_g_ptr: anytype,
    diagnostic_previous_p_g_ptr: anytype,
) !void {
    var diagnostic_biogeochemistry_n_before_g = diagnostic_biogeochemistry_n_before_g_ptr.*;
    defer diagnostic_biogeochemistry_n_before_g_ptr.* = diagnostic_biogeochemistry_n_before_g;
    var diagnostic_previous_heat_megajoules = diagnostic_previous_heat_megajoules_ptr.*;
    defer diagnostic_previous_heat_megajoules_ptr.* = diagnostic_previous_heat_megajoules;
    var diagnostic_previous_n_g = diagnostic_previous_n_g_ptr.*;
    defer diagnostic_previous_n_g_ptr.* = diagnostic_previous_n_g;
    var diagnostic_previous_p_g = diagnostic_previous_p_g_ptr.*;
    defer diagnostic_previous_p_g_ptr.* = diagnostic_previous_p_g;
    if (phase == .nitro) {
        try diagnostics.traceSurfaceFrontier(context, "nitro_entry", 1);
        // Snow discharge and dt-scaled direct atmospheric chemistry were already
        // deposited atomically in each accepted coupled substep, before any
        // litter--soil or runoff transport. `context.snow_surface_discharge` is now
        // an hourly diagnostic flux only; there is deliberately no late consumer.
        // Earlier REDIST/transport steps mutate the fixed organic microbial
        // mirror. Refresh the runtime NITRO owner before it computes metabolism;
        // otherwise the post-NITRO mirror state_update overwrites transported CNP.
        try ecosys.soil_microbial_inventory_bridge.publishFromOrganic(
            context.soil_organic,
            context.soil_microbial,
        );
        diagnostic_biogeochemistry_n_before_g = if (diagnostic_first_hour)
            try diagnostics.diagnosticStoredNitrogen_g(context)
        else
            0;
        if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "before_soil_biogeochemistry");
        try biogeochemistry_batches.runSoilBiogeochemistryBySerialTile(context);
        if (diagnostic_first_hour) {
            const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
            std.log.debug("nitrogen stage: soil_biogeochemistry delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
            diagnostic_previous_n_g = current_n_g;
            const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
            std.log.info("phosphorus stage: soil_biogeochemistry delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
            diagnostic_previous_p_g = current_p_g;
            try diagnostics.logPhosphorusRepresentation(context, "after_soil_biogeochemistry");
        }
        {
            const surface_parameters = context.surface_gas_parameters.*;
            const old_litter_dry_mass_megagrams = try context.allocator.dupe(
                f64,
                context.surface_litter_geometry.dry_mass_megagrams,
            );
            defer context.allocator.free(old_litter_dry_mass_megagrams);
            for (0..context.grid.cell_count) |cell| {
                context.surface_charcoal_carbon_g_c[cell] = try context.surface_organic.charcoalCarbon_g_c(cell);
            }
            var litter_geometry_context: ecosys.surface_litter_geometry_step.ApplyContext = .{
                .result = context.surface_litter_geometry,
                .surface_organic = context.surface_organic,
                .water_m3 = context.surface_precipitation.litter_water_m3,
                .ice_water_equivalent_m3 = context.surface_litter_ice_m3,
                .ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
                .charcoal_carbon_g_c = context.surface_charcoal_carbon_g_c,
                .retention_mode = .accepted_hour,
                .parameters = surface_parameters.litter_geometry,
            };
            try tile_kernels.runKernelAcrossSerialTiles(context, &litter_geometry_context, ecosys.surface_litter_geometry_step.applyCell);
            const chemistry_rebase_roundoff_by_cell = try context.allocator.alloc(
                ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
                context.grid.cell_count,
            );
            defer context.allocator.free(chemistry_rebase_roundoff_by_cell);
            for (chemistry_rebase_roundoff_by_cell, 0..) |*allowance, cell| {
                const aqueous_carrier_m3 = try ecosys.surface_litter_chemistry_carrier_rebase.effectiveAqueousCarrierM3(
                    context.surface_precipitation.litter_water_m3[cell],
                    context.surface_litter_chemistry.dry_reference_water_m3[cell],
                );
                allowance.* = try ecosys.surface_litter_chemistry_carrier_rebase.previewCellDryMassRoundoff(
                    context.surface_litter_chemistry.cells[cell],
                    aqueous_carrier_m3,
                    context.surface_litter_chemistry.mineral_reference_water_m3[cell],
                    .{
                        .dry_mass_megagrams = old_litter_dry_mass_megagrams[cell],
                        .carbon_g_per_mol = 12.0,
                        .nitrogen_g_per_mol = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                        .phosphorus_g_per_mol = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                        .fertilizer_ammonium_mol_n = context.surface_litter_fertilizer.cells[cell].ammonium_mol_n,
                        .fertilizer_ammonia_mol_n = context.surface_litter_fertilizer.cells[cell].ammonia_mol_n,
                        .fertilizer_urea_mol_n = context.surface_litter_fertilizer.cells[cell].urea_mol_n,
                        .fertilizer_nitrate_mol_n = context.surface_litter_fertilizer.cells[cell].nitrate_mol_n,
                        .denitrification_nitrite_g_n = context.surface_denitrification.nitrite_g_n[cell],
                    },
                    old_litter_dry_mass_megagrams[cell],
                    context.surface_litter_geometry.dry_mass_megagrams[cell],
                );
            }
            try ecosys.surface_litter_chemistry_carrier_rebase.rebaseFromAcceptedDryMassChange(
                context.surface_litter_chemistry,
                old_litter_dry_mass_megagrams,
                context.surface_litter_geometry.dry_mass_megagrams,
            );
            try ecosys.layer_local_conservation.accumulateAcceptedSurfaceChemistryRebaseRoundoff(
                context.hourly_cell_boundary_ledger,
                context.hourly_layer_boundary_ledger,
                chemistry_rebase_roundoff_by_cell,
                12.0,
                context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
            );
            @memcpy(context.surface_precipitation.litter_water_capacity_m3, context.surface_litter_geometry.water_retention_capacity_m3);
            for (0..context.grid.cell_count) |cell| {
                context.litter_gas_transport.air_volume_m3[cell] = context.surface_litter_geometry.air_volume_m3[cell];
                context.litter_gas_transport.temperature_k[cell] = context.grid.surface_temperature_k[cell];
            }
            if (diagnostic_first_hour) {
                const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
                std.log.info("phosphorus stage: surface_litter_geometry delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
                diagnostic_previous_p_g = current_p_g;
            }
        }
    }
    if (phase == .surface_gas) {
        try diagnostics.traceSurfaceFrontier(context, "surface_gas_entry", 1);
        const surface_parameters = context.surface_gas_parameters.*;
        const diagnostic_litter_gas_n_before_g = if (diagnostic_first_hour)
            try group_support.diagnosticGasNitrogen_g(context.litter_gas_transport)
        else
            0;
        _ = try context.surface_litter_gas_transport.advanceWithFailureReport(
            context.litter_gas_transport,
            .{
                .chemistry = context.surface_litter_chemistry,
                .nitrogen_molar_mass_g_per_mol = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                .absolute_tolerance_g_n = context.config.physical_tolerance.nitrogen_g,
                .relative_tolerance = context.config.physical_tolerance.relative,
            },
            context.surface_litter_geometry,
            context.surface_precipitation.litter_water_m3,
            context.surface_litter_ice_m3,
            context.canopy_cell_area_m2,
            context.litter_atmospheric_gas_conductance_m3_per_h,
            context.current_atmospheric_gas_concentration_g_per_m3,
            surface_parameters.solubility,
            surface_parameters.exchange,
            .{
                .reference_temperature_k = context.runscript.soil_gas_transport_parameters.reference_temperature_k,
                .temperature_exponent = context.runscript.soil_gas_transport_parameters.temperature_exponent,
                .free_air_diffusivity_m2_per_h = context.runscript.soil_gas_transport_parameters.free_air_diffusivity_m2_per_h,
                .penman_tortuosity = context.runscript.soil_gas_transport_parameters.penman_tortuosity,
                .minimum_air_fraction = context.runscript.surface_gas_resistance_parameters.minimum_air_fraction,
                .ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
            },
            .{
                .absolute_tolerance_g_by_species = .{
                    context.config.nonlinear_tolerance.carbon_g,
                    context.config.nonlinear_tolerance.carbon_g,
                    context.config.nonlinear_tolerance.oxygen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    2 * context.config.nonlinear_tolerance.amount_mol,
                },
                .relative_tolerance = context.config.nonlinear_tolerance.relative,
                .picard_relaxation = context.config.picard_relaxation,
                .max_iterations = context.iteration_limits.gas_max_iterations,
                .accept_physically_conserved_ceiling = true,
            },
            gas_failure_report,
        );
        try diagnostics.traceSurfaceFrontier(context, "surface_gas_done", 1);
        if (diagnostic_first_hour) {
            var diagnostic_litter_boundary_n_g: f64 = 0;
            for (0..context.grid.cell_count) |cell| {
                const base = cell * ecosys.gas_transport.species_count;
                inline for ([_]ecosys.gas_transport.Species{ .nitrogen, .nitrous_oxide, .ammonia }) |species|
                    diagnostic_litter_boundary_n_g += context.surface_litter_gas_transport.atmospheric_flux_g_per_h[base + @intFromEnum(species)];
            }
            const diagnostic_litter_after_g = try group_support.diagnosticGasNitrogen_g(context.litter_gas_transport);
            std.log.debug("litter gas nitrogen transaction: delta_g={e} boundary_g={e} residual_g={e}", .{ diagnostic_litter_after_g - diagnostic_litter_gas_n_before_g, diagnostic_litter_boundary_n_g, diagnostic_litter_after_g - diagnostic_litter_gas_n_before_g - diagnostic_litter_boundary_n_g });
        }
        if (diagnostic_first_hour) {
            const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
            std.log.debug("nitrogen stage: litter_gas_transport delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
            diagnostic_previous_n_g = current_n_g;
            const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
            std.log.info("phosphorus stage: litter_gas_transport delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
            diagnostic_previous_p_g = current_p_g;
            const heat_megajoules = (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules;
            std.log.debug("heat stage: litter_gas_transport hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, heat_megajoules - diagnostic_previous_heat_megajoules });
            diagnostic_previous_heat_megajoules = heat_megajoules;
        }
    }
    if (phase == .nitro) {
        const surface_parameters = context.surface_gas_parameters.*;
        {
            @memset(context.surface_microbial_substrate_uptake.denitrification_respiration_g_c, 0);
            context.surface_litter_fertilizer_diagnostics.reset();
            // REDIST 4318-4330 (`VHCPO`/`HFLXO`): surface litter heat capacity is a
            // function of its SOC, so respiration and transfer change the enthalpy
            // the census stores at fixed temperature. Legacy books that change into
            // `HEATIN`; so must we, or it reads as an unexplained heat leak.
            const litter_carbon_before_g_c = try context.allocator.alloc(f64, context.grid.cell_count);
            defer context.allocator.free(litter_carbon_before_g_c);
            for (litter_carbon_before_g_c, 0..) |*carbon, cell|
                carbon.* = try context.surface_organic.totalCarbon_g_c(cell);
            try biogeochemistry_batches.runSurfaceBiogeochemistryBySerialTile(context, surface_parameters);
            {
                const litter_carbon_after_g_c = try context.allocator.alloc(f64, context.grid.cell_count);
                defer context.allocator.free(litter_carbon_after_g_c);
                for (litter_carbon_after_g_c, 0..) |*carbon, cell|
                    carbon.* = try context.surface_organic.totalCarbon_g_c(cell);
                const litter_heat_rebase_by_cell = try context.allocator.alloc(f64, context.grid.cell_count);
                defer context.allocator.free(litter_heat_rebase_by_cell);
                try ecosys.surface_litter_organic_heat_rebase.landscapeOrganicCarbonRebaseHeatMegajoulesByCell(
                    litter_heat_rebase_by_cell,
                    litter_carbon_before_g_c,
                    litter_carbon_after_g_c,
                    context.grid.surface_temperature_k,
                    context.runscript.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
                );
                // N1's remaining 3.47%. The day-89 surface residual is
                // `7.13310266409195e-9` MJ and `c_org * surface_co2_production_g_c * T`
                // at that hour's own temperature is `6.893880176060551e-9` MJ --
                // respiration accounts for 96.53% with no fitted parameter, and
                // `2.392e-10` MJ is unexplained. This rebase books
                // `c_org * (after - before) * T`, where `after - before` spans the
                // WHOLE nitro window rather than the CO2 production alone, so the
                // window-versus-CO2 difference is the right shape for that
                // remainder. Recording the four values the comparison needs, for
                // cell 0, so the failure dump can settle it without a fit: the
                // surface scope's internal terms are ~1e-6, two to three orders
                // above this ~7e-9 booking, so magnitude alone cannot confirm the
                // booking is even present.
                if (context.grid.cell_count > 0) {
                    const probe = context.diagnostic_surface_respiration_rebase;
                    probe.*[0] = litter_carbon_before_g_c[0];
                    probe.*[1] = litter_carbon_after_g_c[0];
                    probe.*[2] = context.grid.surface_temperature_k[0];
                    probe.*[3] = litter_heat_rebase_by_cell[0];
                }
                try publishSurfaceOrganicHeatRebase(
                    context,
                    litter_heat_rebase_by_cell,
                    litter_carbon_before_g_c,
                    litter_carbon_after_g_c,
                );
                // HEAT-001 lead 1 is closed: the instrument that used to live here
                // measured the litter-SOC drift occurring outside this rebase span
                // and read exactly 0e0 g C / 0e0 MJ in every hour of the Ottawa
                // scenario, with a 1e-6 g C injection control proving it was not
                // blind. The lead is dead, so the instrument is retired rather than
                // left running every hour. See commit 9248124 for the measurement.
            }
            if (diagnostic_first_hour) {
                const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
                std.log.debug("nitrogen stage: surface_biogeochemistry delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
                diagnostic_previous_n_g = current_n_g;
                const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
                std.log.info("phosphorus stage: surface_biogeochemistry delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
                diagnostic_previous_p_g = current_p_g;
                try diagnostics.logPhosphorusRepresentation(context, "after_surface_biogeochemistry");
            }
        }
        try ecosys.soil_microbial_inventory_bridge.publishToOrganic(
            context.soil_microbial,
            context.soil_organic,
        );
        if (diagnostic_first_hour) {
            const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
            std.log.debug(
                "nitrogen closed stage: biogeochemistry_and_mirror delta_g={e}",
                .{current_n_g - diagnostic_biogeochemistry_n_before_g},
            );
            // The phosphorus series attributed this publish to the NEXT logged
            // stage, `pre_chemistry_matrix_refresh` -- which only calls
            // `mineral_nitrogen_transport.refreshMatrixFromReactionState`, a
            // nitrogen-only operation that cannot move phosphorus at all. So the
            // +2.0048604974363116e-3 g P booked against that label is really this
            // mirror publish plus whatever else falls between the two prints.
            // Split the label so the attribution is honest.
            const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
            std.log.info("phosphorus stage: microbial_organic_mirror_publish delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
            diagnostic_previous_p_g = current_p_g;
            try diagnostics.logPhosphorusRepresentation(context, "after_microbial_organic_mirror_publish");
        }
    }
    if (phase == .solute) {
        try context.mineral_nitrogen_transport.refreshMatrixFromReactionState(
            context.soil_chemistry,
            context.soil_reactive_nitrogen,
            context.grid.matrix_liquid_water_m3,
            context.fertilizer_band,
            context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        );
        if (diagnostic_first_hour) {
            const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
            std.log.debug("nitrogen stage: pre_chemistry_matrix_refresh delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
            diagnostic_previous_n_g = current_n_g;
            const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
            std.log.info("phosphorus stage: pre_chemistry_matrix_refresh delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
            diagnostic_previous_p_g = current_p_g;
            try diagnostics.logPhosphorusRepresentation(context, "after_pre_chemistry_matrix_refresh");
        }
        // Legacy SOLUTE follows the soil and litter biological source/sink state_updates.
        // Converge locally once; do not repeat a full sub-hourly model cycle.
        const diagnostic_chemistry_n_before_g = if (diagnostic_first_hour)
            try diagnostics.diagnosticStoredNitrogen_g(context)
        else
            0;
        try soil_chemistry_convergence.convergeHourlySoilChemistry(
            context,
            fertilizer_band_hour,
            solute_failure_report,
        );
        if (diagnostic_first_hour) {
            const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
            std.log.info("phosphorus stage: soil_chemistry_only delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
            diagnostic_previous_p_g = current_p_g;
        }
        try surface_litter_convergence.convergeSurfaceLitterChemistry(context);
        try context.mineral_nitrogen_transport.refreshMatrixFromReactionState(
            context.soil_chemistry,
            context.soil_reactive_nitrogen,
            context.grid.matrix_liquid_water_m3,
            context.fertilizer_band,
            context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        );
        if (diagnostic_first_hour) {
            const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
            std.log.debug(
                "nitrogen closed stage: chemistry delta_g={e}",
                .{current_n_g - diagnostic_chemistry_n_before_g},
            );
        }
        if (diagnostic_first_hour) {
            const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
            std.log.debug("nitrogen stage: chemistry delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
            diagnostic_previous_n_g = current_n_g;
            const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
            std.log.info("phosphorus stage: chemistry delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
            diagnostic_previous_p_g = current_p_g;
        }
    }
    try routePondSettlingAndFinalize(
        context,
        phase,
        diagnostic_first_hour,
        snow_phase_change_report,
        snow_vapor_equilibrium_report,
        subsurface_irrigation_chemistry_parameters,
        &diagnostic_previous_heat_megajoules,
        &diagnostic_previous_n_g,
        &diagnostic_previous_p_g,
    );
}

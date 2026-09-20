//! `hourly_science` declarations: driver.
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
const group_sediment = @import("hourly_sediment.zig");

/// `starts.f:274-303`'s `IRCHG`: the compass-aspect quadrant that determines
/// which of the four lateral directions is topographically downhill and may
/// therefore export boundary runoff/sediment/drift; the other side of each
/// axis is uphill and forbidden regardless of the user-set `RCHQ*` fraction.
///
/// Verified against `watsub.f:5444-5519`'s `XN` sign convention (`XN=-1` for
/// the `NN=1` side of each axis -- east or south -- and `XN=+1` for `NN=2` --
/// west or north) combined with the discharge test at `:5598-5607`
/// (`ALT2=ALTG+DPTHW2-XN*SLOPE(N)*DLYR`, discharge toward the side with the
/// lower `ALT2`): this resolves to "`SLOPE(1)<0` favours east over west" and
/// "`SLOPE(2)<0` favours south over north", which reproduces `starts.f`'s
/// four quadrant assignments exactly (checked all four).
const TopographicDownhillGate = struct { east: bool, west: bool, south: bool, north: bool };
fn topographicDownhillGate(compass_aspect_degrees: f64) TopographicDownhillGate {
    if (compass_aspect_degrees < 90) return .{ .east = true, .west = false, .south = false, .north = true };
    if (compass_aspect_degrees < 180) return .{ .east = false, .west = true, .south = false, .north = true };
    if (compass_aspect_degrees < 270) return .{ .east = false, .west = true, .south = true, .north = false };
    return .{ .east = true, .west = false, .south = true, .north = false };
}

/// Snow drift and runoff share the same immutable site boundary mask. Refresh
/// it before WATSUB so a new process (including checkpoint resume) never feeds
/// the drift router the zero-filled RuntimeState initialization image from the
/// previous process lifetime.
pub fn refreshSurfaceBoundaryOpenFlags(context: anytype) void {
    for (0..context.grid.cell_count) |cell| {
        const column = cell % context.config.lon_count;
        const row = cell / context.config.lon_count;
        const gate = topographicDownhillGate(context.site_by_cell[cell].compass_aspect_degrees);
        context.surface_erosion.east_boundary_open[cell] =
            column + 1 == context.config.lon_count and
            context.site_by_cell[cell].surface_runoff_boundary_fraction[1] > 0 and
            gate.east;
        context.surface_erosion.west_boundary_open[cell] =
            column == 0 and
            context.site_by_cell[cell].surface_runoff_boundary_fraction[3] > 0 and
            gate.west;
        context.surface_erosion.south_boundary_open[cell] =
            row + 1 == context.config.lat_count and
            context.site_by_cell[cell].surface_runoff_boundary_fraction[2] > 0 and
            gate.south;
        context.surface_erosion.north_boundary_open[cell] =
            row == 0 and
            context.site_by_cell[cell].surface_runoff_boundary_fraction[0] > 0 and
            gate.north;
    }
}

const EquilibriumSource = struct {
    water_m3: f64,
    ph: f64,
    dissolved_gas_g_per_m3: [5]f64,
    ammonium_g_n_per_m3: f64,
    nitrate_g_n_per_m3: f64,
    phosphate_g_p_per_m3: f64,
    free_ion_g_per_m3: [8]f64,
};

const DynamicSnowInput = struct {
    primary_g: [ecosys.snow_solute_transport.species_count]f64 = @splat(0),
    salt_mol: [ecosys.snow_solute_transport.salt_species_count]f64 = @splat(0),
};

fn equilibratedDynamicInput(
    allocator: std.mem.Allocator,
    workspace: *ecosys.solute_reaction_solver.Workspace,
    rain: EquilibriumSource,
    irrigation: EquilibriumSource,
    molar_mass_g_per_mol: ecosys.soil_chemistry_initialization.ElementMolarMassesGPerMol,
    global_parameters: ecosys.soil_chemistry_parameters.Parameters,
    options: ecosys.solute_reaction_solver.Options,
    failure_report: ?ecosys.solute_failure_reporter.Request,
    global_cell_id: usize,
) !DynamicSnowInput {
    const total_water_m3 = rain.water_m3 + irrigation.water_m3;
    if (!std.math.isFinite(total_water_m3) or total_water_m3 < 0)
        return error.InvalidSnowAtmosphericInput;
    if (total_water_m3 == 0) return .{};
    inline for (.{ rain, irrigation }) |source| {
        if (!std.math.isFinite(source.water_m3) or source.water_m3 < 0 or
            !std.math.isFinite(source.ph) or source.ph < 0 or source.ph > 14)
            return error.InvalidSnowAtmosphericInput;
    }
    const rain_fraction = rain.water_m3 / total_water_m3;
    const irrigation_fraction = irrigation.water_m3 / total_water_m3;
    const hydrogen_mol_per_m3 = rain_fraction * 1000 * std.math.pow(f64, 10, -rain.ph) +
        irrigation_fraction * 1000 * std.math.pow(f64, 10, -irrigation.ph);
    if (!std.math.isFinite(hydrogen_mol_per_m3) or hydrogen_mol_per_m3 <= 0)
        return error.InvalidSnowAtmosphericInput;
    var gas_g_per_m3: [5]f64 = undefined;
    var ions_g_per_m3: [8]f64 = undefined;
    for (&gas_g_per_m3, rain.dissolved_gas_g_per_m3, irrigation.dissolved_gas_g_per_m3) |*result, rain_value, irrigation_value|
        result.* = rain_fraction * rain_value + irrigation_fraction * irrigation_value;
    for (&ions_g_per_m3, rain.free_ion_g_per_m3, irrigation.free_ion_g_per_m3) |*result, rain_value, irrigation_value|
        result.* = rain_fraction * rain_value + irrigation_fraction * irrigation_value;
    const equilibrium_inputs: ecosys.snow_chemistry_initialization.Inputs = .{
        .precipitation_ph = -std.math.log10(hydrogen_mol_per_m3 / 1000),
        .dissolved_gas_g_per_m3 = gas_g_per_m3,
        .ammonium_g_n_per_m3 = rain_fraction * rain.ammonium_g_n_per_m3 + irrigation_fraction * irrigation.ammonium_g_n_per_m3,
        .nitrate_g_n_per_m3 = rain_fraction * rain.nitrate_g_n_per_m3 + irrigation_fraction * irrigation.nitrate_g_n_per_m3,
        .phosphate_g_p_per_m3 = rain_fraction * rain.phosphate_g_p_per_m3 + irrigation_fraction * irrigation.phosphate_g_p_per_m3,
        .free_ion_g_per_m3 = ions_g_per_m3,
        .molar_mass_g_per_mol = molar_mass_g_per_mol,
    };
    var contextual_failure_report = failure_report;
    if (contextual_failure_report) |*report| {
        report.context.global_cell_id = @intCast(global_cell_id);
        report.context.soil_layer_id = 0;
        report.context.packed_cell_index = 0;
    }
    const concentrations = try ecosys.snow_chemistry_initialization.equilibrateWithWorkspaceAndFailureReport(
        allocator,
        workspace,
        equilibrium_inputs,
        global_parameters,
        options,
        contextual_failure_report,
    );
    var result: DynamicSnowInput = .{};
    for (concentrations.primary_g_per_m3, 0..) |concentration, species|
        result.primary_g[species] = concentration * total_water_m3;
    for (concentrations.salt_mol_per_m3, 0..) |concentration, species|
        result.salt_mol[species] = concentration * total_water_m3;
    return result;
}
const group_snow_energy = @import("hourly_snow_energy.zig");

/// Reads the eight rain-ion weather-header concentrations in
/// `snow_solute_transport.Species` order (`.aluminum` through `.chloride`),
/// for `atmosphericInputG`'s `rain_ions_g_per_m3` argument. PRECIP-ION-FEED-001:
/// the header declaration order and the `Species` enum order agree today, but
/// only by coincidence, so the correspondence is asserted at compile time via
/// `@field` rather than assumed positionally: if either order is ever changed
/// without the other, this fails to compile instead of silently misrouting an
/// ion into the wrong `Species` slot.
fn rainIonsGPerM3(weather_header: ecosys.weather.Header) [8]f64 {
    const Species = ecosys.snow_solute_transport.Species;
    const species_fields = @typeInfo(Species).@"enum".fields;
    const ion_offset = @intFromEnum(Species.aluminum);
    comptime {
        if (species_fields.len - ion_offset != 8)
            @compileError("PRECIP-ION-FEED-001: expected exactly eight rain-ion Species starting at .aluminum");
    }
    var result: [8]f64 = undefined;
    inline for (0..8) |index| {
        const field_name = "precipitation_" ++ species_fields[ion_offset + index].name ++ "_g_per_m3";
        result[index] = @field(weather_header, field_name);
    }
    return result;
}

fn scaledPrecipitationNitrogen(
    ammonium_g_n_per_m3: f64,
    nitrate_g_n_per_m3: f64,
    multipliers: ecosys.climate_change.PrecipitationChemistryMultipliers,
) !struct { ammonium_g_n_per_m3: f64, nitrate_g_n_per_m3: f64 } {
    // WTHR.F 483--484: always derive from the immutable weather-header
    // baselines. Scaling the already speciated NH4/NH3 products would put the
    // climate multiplier on the wrong side of precipitation pH speciation.
    const forcing = try ecosys.atmospheric_chemistry_forcing.derive(.{
        .atmospheric_co2_umol_per_mol = 0,
        .precipitation_ammonium_g_n_per_m3 = ammonium_g_n_per_m3,
        .precipitation_nitrate_g_n_per_m3 = nitrate_g_n_per_m3,
    }, .{
        .atmospheric_co2_fraction = 1,
        .precipitation_ammonium_fraction = multipliers.ammonium,
        .precipitation_nitrate_fraction = multipliers.nitrate,
    });
    return .{
        .ammonium_g_n_per_m3 = forcing.precipitation_ammonium_g_n_per_m3,
        .nitrate_g_n_per_m3 = forcing.precipitation_nitrate_g_n_per_m3,
    };
}

pub fn executeHourlyScience(
    context: anytype,
    hour_of_day: u8,
    radiation_by_cell: []const ecosys.atmospheric_radiation.Result,
    forcing_by_cell: []const ecosys.weather.HourlyForcing,
    weather_header_by_cell: []const ecosys.weather.Header,
    plant_calendar_by_cell: []const ecosys.plant_development.Calendar,
    precipitation_chemistry_multipliers: ecosys.climate_change.PrecipitationChemistryMultipliers,
    fertilizer_band_hour: ecosys.fertilizer_band_phase_coordinator.HourToken,
    gas_failure_report: ?ecosys.soil_gas_transport_step.FailureReportRequest,
    solute_failure_report: ?ecosys.solute_failure_reporter.Request,
) !void {
    const temporary_profile_active = context.executed_weather_hours.* >= 504 and
        context.executed_weather_hours.* < 512;
    const temporary_profile_start = std.Io.Clock.now(.boot, context.io);
    if (radiation_by_cell.len != context.grid.cell_count or
        forcing_by_cell.len != context.grid.cell_count or
        weather_header_by_cell.len != context.grid.cell_count or
        plant_calendar_by_cell.len != context.grid.cell_count)
        return error.HourlyEnvironmentDimensionMismatch;
    const plant_calendar = plant_calendar_by_cell[0];
    if (hour_of_day > 23) return error.InvalidHourlyScienceHour;
    // These stage-by-stage whole-domain reconstructions exist solely to feed
    // debug logs.  Production builds suppress those logs, so do not pay for
    // their scans during the first simulated day.  Physical conservation
    // acceptance is performed independently by the always-enabled hour gate.
    // PHOSPHORUS-SURFACE-CLOSURE-HOUR-2658-001. The eighteen "phosphorus stage:"
    // deltas this gate controls are a complete per-stage attribution across the
    // whole hourly pipeline, and they are exactly the instrument that defect
    // needs -- the third time in this investigation that the right measurement
    // was already wired and only mis-targeted.
    //
    // The original clause is preserved verbatim, so first-day debug behaviour is
    // unchanged. The added window matches `traceSurfaceFrontier`'s and drops the
    // debug-level requirement, because the deltas are logged at `.info` for
    // phosphorus and the acceptance runs are ReleaseSafe, where `.debug` is
    // compiled out.
    const diagnostic_first_hour = (std.log.logEnabled(.debug, .default) and
        context.executed_weather_hours.* < 24) or
        (context.executed_weather_hours.* >= 2656 and context.executed_weather_hours.* < 2659);
    var diagnostic_previous_n_g = if (diagnostic_first_hour)
        try diagnostics.diagnosticStoredNitrogen_g(context)
    else
        0;
    var diagnostic_previous_p_g = if (diagnostic_first_hour)
        try diagnostics.diagnosticStoredPhosphorus_g(context)
    else
        0;
    var diagnostic_previous_p_owners = if (diagnostic_first_hour)
        try diagnostics.diagnosticPhosphorusOwners_g(context)
    else
        @as([3]f64, @splat(0));
    var diagnostic_previous_heat_megajoules = if (diagnostic_first_hour)
        (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules
    else
        0;
    const diagnostic_relayer_phosphate_before = if (diagnostic_first_hour)
        try diagnostics.diagnosticRelayerPhosphateOwners_g(context)
    else
        @as([3]f64, @splat(0));
    context.plant_available_nutrients.resetHourlyChanges();
    try ecosys.soil_organic_carbon_change.captureHourStart(context.soil_organic, context.soil_organic_carbon_at_hour_start_g_c);
    // Derive restart-sensitive surface state from the checkpointed snow owner.
    for (0..context.grid.cell_count) |cell| context.snow_depth_m[cell] = context.snow_transport.cumulative_depth_m[(cell + 1) * context.snow_transport.layer_capacity - 1];
    // Chemistry is concentration-based while TRNSFRS is amount-based. Export
    // before water moves so dilution does not create or destroy solute mass.
    try ecosys.soil_aqueous_transport_bridge.validateCarrierVolumes(
        context.micropore_solute_state,
        context.grid.matrix_liquid_water_m3,
        blk: {
            var scale_m3: f64 = 0;
            for (context.grid.matrix_liquid_water_m3) |volume_m3| scale_m3 = @max(scale_m3, @abs(volume_m3));
            break :blk context.config.physical_tolerance.waterVolume(scale_m3);
        },
    );
    try ecosys.soil_aqueous_transport_bridge.exportChemistry(
        context.soil_chemistry,
        context.micropore_solute_state,
        context.fertilizer_band,
        context.config.physical_tolerance.water_volume_m3,
    );
    // Legacy TRNSFR copies extensive ZNH4S/ZNH4B inventories before water
    // transport. Capture mineral N at the same boundary; reconstructing
    // amount from concentration after water moves manufactures or destroys N.
    try context.mineral_nitrogen_transport.captureHourStartMatrix(
        context.soil_chemistry,
        context.soil_reactive_nitrogen,
        context.grid.matrix_liquid_water_m3,
        context.fertilizer_band,
        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
    );
    if (diagnostic_first_hour) {
        const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
        std.log.debug("nitrogen stage: mineral_capture delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
        diagnostic_previous_n_g = current_n_g;
        const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
        std.log.info("phosphorus stage: mineral_capture delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
        diagnostic_previous_p_g = current_p_g;
        // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001. `exportChemistry`
        // multiplies concentrations by the transport owner's carrier
        // (`aqueous_transport_bridge.zig:60`), while `metabolism_state_update.zig:296`
        // divides the topsoil mineral debit by the grid carrier. The two are only
        // required to agree to `validateCarrierVolumes`'s absolute tolerance, which
        // carries relative tolerance 0 and an absolute scale taken from the whole
        // profile's maximum -- so a thin topsoil layer is allowed a much larger
        // relative drift than the name suggests. Any accepted drift becomes a mass
        // error on export.
        //
        // Falsifiable: the root cause requires this ratio to be 1.0064469971e-6,
        // which is `residual / transfer` = 1.10503606265411e-10 / 1.09795753360231e-4
        // from the already-measured stage series. Zero free parameters: the number
        // is forced by the hypothesis, and this print could disagree with it.
        const carrier_grid_m3 = context.grid.matrix_liquid_water_m3[0];
        const carrier_transport_m3 = context.micropore_solute_state.water_volume_m3[0];
        std.log.info("phosphorus carrier: grid_m3={e} transport_m3={e} absolute_m3={e} relative={e}", .{
            carrier_grid_m3,
            carrier_transport_m3,
            carrier_transport_m3 - carrier_grid_m3,
            if (carrier_grid_m3 != 0) (carrier_transport_m3 - carrier_grid_m3) / carrier_grid_m3 else 0,
        });
        // Hour-start baseline. Summing the printed ledger owners across
        // `soil_biogeochemistry` gives -2.114656250431e-3 while that stage reports
        // -2.1146561402929365e-3, so 1.101380635e-10 -- 99.7% of the whole residual
        // -- is created BEFORE the `.nitro` phase begins, in the unlabelled water
        // and heat front end, and the `soil_biogeochemistry` label absorbs it. That
        // label is the third in this investigation to absorb work it did not do.
        //
        // This print closes the region: everything between here and
        // `before_soil_biogeochemistry` is now bracketed.
        try diagnostics.logPhosphorusRepresentation(context, "hour_start_after_mineral_capture");
    }
    var diagnostic_mineral_before_mol: f64 = 0;
    const diagnostic_transport_before = if (diagnostic_first_hour) try diagnostics.reconstructLandscapeMassBalance(context) else undefined;

    const diagnostic_transport_ammonium_before = if (diagnostic_first_hour) try diagnostics.diagnosticAmmoniumOwners_g_n(context) else undefined;
    if (diagnostic_first_hour) {
        for (context.mineral_nitrogen_transport.matrix.amount_mol) |amount| diagnostic_mineral_before_mol += amount;
        for (context.mineral_nitrogen_transport.macropore.amount_mol) |amount| diagnostic_mineral_before_mol += amount;
    }
    var forcing_context = ecosys.atmospheric_forcing.MappedApplyContext{ .state = context.atmosphere, .forcing_by_cell = forcing_by_cell };
    try tile_kernels.runKernelAcrossSerialTiles(context, &forcing_context, ecosys.atmospheric_forcing.applyMappedTile);
    for (0..context.grid.cell_count) |cell| {
        const irrigation_m = context.irrigation_water_depth_m[cell];
        if (!std.math.isFinite(irrigation_m) or irrigation_m < 0) return error.InvalidHourlyIrrigationDepth;
        context.atmosphere.rainfall_m[cell] += irrigation_m;
        context.atmosphere.precipitation_m[cell] += irrigation_m;
    }
    // The erosion RuntimeState starts with closed boundaries, while the snow
    // drift producer below runs before the later sediment stage. Rebind the
    // immutable site mask now so uninterrupted and resumed hours see the same
    // open-boundary topology.
    refreshSurfaceBoundaryOpenFlags(context);
    @memset(context.surface_total_canopy_area_m2, 0);
    @memset(context.surface_stalk_area_m2, 0);
    @memset(context.surface_canopy_height_m, 0);
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
    if (context.canopy_layer_distribution.*) |*layers| for (0..context.grid.cell_count) |cell| {
        const first = cell * layers.layer_count;
        for (0..layers.layer_count) |layer| {
            const stalk_area_m2 = layers.cell_stalk_area_m2[first + layer];
            context.surface_stalk_area_m2[cell] += stalk_area_m2;
            context.surface_total_canopy_area_m2[cell] +=
                layers.cell_leaf_area_m2[first + layer] + stalk_area_m2 +
                layers.cell_standing_dead_area_m2[first + layer];
        }
        const boundaries = try layers.cellBoundaries(cell);
        context.surface_canopy_height_m[cell] = @max(0, boundaries[boundaries.len - 1]);
        const surface_depth_m = canopy_burial.surfaceWaterIceDepthM(cell);
        const scale_m = @max(context.surface_canopy_height_m[cell], @max(context.snow_depth_m[cell], surface_depth_m));
        const tolerance_m = context.config.physical_tolerance.length(scale_m);
        if (context.surface_canopy_height_m[cell] < context.snow_depth_m[cell] - tolerance_m or
            context.surface_canopy_height_m[cell] < surface_depth_m - tolerance_m)
            context.surface_total_canopy_area_m2[cell] = 0;
    };
    // HOUR1 2927--2967: refresh runoff `ZM` from the accepted current topsoil,
    // litter and stalk owners. Aerodynamic `ZS/ZR` remains the independent
    // soil/snow path selected below and in hourly_snow_energy.
    try ecosys.disturbed_surface_soil_roughness.refresh(.{
        .surface_roughness_m = context.surface_runoff.surface_roughness_m,
        .soil_layer_capacity = context.grid.soil_layer_capacity,
        .first_active_layer_by_cell = context.soil_geometry.first_active_layer,
        .active_layer_count_by_cell = context.soil_geometry.active_layer_count,
        .soil_organic = context.soil_organic,
        .matrix_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3,
        .sand_mass_megagrams = context.soil_solver_properties.sand_mass_megagrams,
        .silt_mass_megagrams = context.soil_solver_properties.silt_mass_megagrams,
        .clay_mass_megagrams = context.soil_solver_properties.clay_mass_megagrams,
        .bulk_density_megagrams_per_m3 = context.soil_solver_properties.bulk_density_megagrams_per_m3,
        .surface_litter_volume_m3 = context.surface_litter_geometry.dry_litter_volume_m3,
        .grid_cell_area_m2 = context.canopy_cell_area_m2,
        .stalk_area_m2 = context.surface_stalk_area_m2,
        .canopy_height_m = context.surface_canopy_height_m,
        .tolerance = .{
            .soil_mass_absolute_megagrams = context.config.physical_tolerance.soil_mass_megagrams,
            .volume_absolute_m3 = context.config.physical_tolerance.water_volume_m3,
            .relative = context.config.physical_tolerance.relative,
        },
    });
    // HOUR1 ARLFS/AREA refresh: canopy structure must follow the live
    // layer-distributed leaf inventory each hour, not its initialization value.
    if (context.canopy_layer_distribution.*) |*layers| if (context.detailed_canopy.*) |*canopy| if (context.canopy_structure.*) |*structure| {
        try layers.publishLeafAreaIndex(canopy, context.plants, context.canopy_cell_area_m2);
        var structure_context: ecosys.canopy_structure.ApplyContext = .{ .structure = structure, .plants = context.plants };
        try tile_kernels.runKernelAcrossSerialTiles(context, &structure_context, ecosys.canopy_structure.applyLeafAreaTile);
    };
    for (weather_header_by_cell, 0..) |header, cell| context.hourly_weather_reference_height_m[cell] = header.aerodynamic_roughness_m;
    for (0..context.grid.cell_count) |cell| {
        const first_snow = cell * context.snow_transport.layer_capacity;
        const first_soil = cell * context.grid.soil_layer_capacity + context.soil_geometry.first_active_layer[cell];
        context.canopy_surface_roughness_height_m[cell] = try ecosys.surface_aerodynamics.sourceGroundSurfaceRoughnessHeightM(
            context.runscript.surface_aerodynamic_parameters,
            context.soil_solver_properties.bulk_density_megagrams_per_m3[first_soil],
            context.snow_transport.heat_capacity_megajoules_per_k[first_snow],
            context.canopy_cell_area_m2[cell],
        );
    }
    var surface_aerodynamic_context: ecosys.surface_aerodynamics.ApplyContext = .{ .state = context.surface_aerodynamics, .cell_area_m2 = context.canopy_cell_area_m2, .total_canopy_area_m2 = context.surface_total_canopy_area_m2, .canopy_height_m = context.surface_canopy_height_m, .snow_depth_m = context.snow_depth_m, .ground_surface_roughness_height_m = context.canopy_surface_roughness_height_m, .weather_reference_height_m = context.hourly_weather_reference_height_m, .wind_speed_m_per_h = context.atmosphere.wind_speed_m_per_h, .parameters = context.runscript.surface_aerodynamic_parameters };
    try tile_kernels.runKernelAcrossSerialTiles(context, &surface_aerodynamic_context, ecosys.surface_aerodynamics.applyTile);
    const ground_air_geometry_balance = try context.allocator.alloc(
        ecosys.ground_air_exchange.GeometryBalance,
        context.grid.cell_count,
    );
    defer context.allocator.free(ground_air_geometry_balance);
    try context.ground_air.refreshGeometry(
        context.canopy_cell_area_m2,
        context.surface_aerodynamics.wind_reference_height_m,
        context.runscript.ground_air_parameters,
        ground_air_geometry_balance,
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE driver geometry elapsed_ms={d}",
        .{temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds()},
    );
    for (0..context.grid.cell_count) |cell| context.ground_air_vapor_pressure_kpa[cell] = try ecosys.ground_air_exchange.vaporPressureKpa(context.ground_air.vapor_volume_fraction[cell], context.ground_air.temperature_k[cell], context.runscript.ground_air_parameters);
    for (radiation_by_cell, forcing_by_cell, 0..) |cell_radiation, cell_forcing, cell| {
        context.hourly_extraterrestrial_shortwave_megajoules_per_m2[cell] =
            cell_radiation.extraterrestrial_shortwave_megajoules_per_m2;
        context.hourly_solar_angle_sine[cell] = cell_radiation.solar_angle_sine;
        context.hourly_solar_azimuth_radians[cell] = cell_radiation.solar_azimuth_radians;
        context.hourly_adjusted_shortwave_megajoules_per_m2[cell] =
            cell_forcing.shortwave_radiation_megajoules_per_m2;
    }
    var canopy_radiation_context: ecosys.canopy_radiation.MappedApplyContext = .{ .state = context.canopy_radiation, .horizontal_shortwave_megajoules_per_m2 = context.hourly_adjusted_shortwave_megajoules_per_m2, .extraterrestrial_horizontal_shortwave_megajoules_per_m2 = context.hourly_extraterrestrial_shortwave_megajoules_per_m2, .solar_angle_sine = context.hourly_solar_angle_sine, .diffuse_sky_horizontal_projection = context.canopy_geometry.diffuse_sky_horizontal_projection };
    try tile_kernels.runKernelAcrossSerialTiles(context, &canopy_radiation_context, ecosys.canopy_radiation.applyMappedTile);
    if (context.canopy_optics.*) |*optics| {
        var optics_context: ecosys.canopy_optics.ApplyContext = .{ .state = optics, .radiation = context.canopy_radiation };
        try tile_kernels.runKernelAcrossSerialTiles(context, &optics_context, ecosys.canopy_optics.applyLeafAbsorptionTile);
    }
    try context.canopy_geometry.directSolarIncidenceMapped(
        context.hourly_solar_angle_sine,
        context.direct_incidence_fraction,
        context.direct_incidence_per_horizontal_area,
        context.direct_scattering_direction,
    );
    if (context.canopy_interception.*) |*interception| {
        if (context.canopy_layer_distribution.*) |*layers| {
            // The compact one-layer kernel is an alternative owner, not a
            // pre-pass. In particular it rewrites the bottom transmission for
            // a one-layer canopy without knowing DPTHS/DPTH0, which would
            // undo the burial-aware result immediately before absorption.
            try ecosys.canopy_interception.refreshLayerTransmissionWithBurial(interception, layers, &context.canopy_structure.*.?, context.canopy_geometry, context.direct_incidence_per_horizontal_area, context.canopy_cell_area_m2, canopy_burial);
            try ecosys.canopy_interception.refreshAtmosphericLayerAbsorptionWithBurial(interception, layers, &context.canopy_structure.*.?, &context.canopy_optics.*.?, context.canopy_geometry, context.canopy_radiation, context.direct_incidence_fraction, context.direct_incidence_per_horizontal_area, context.direct_scattering_direction, context.canopy_cell_area_m2, context.runscript.woody_optics_parameters, canopy_burial);
        } else {
            var interception_context: ecosys.canopy_interception.ApplyContext = .{ .result = interception, .structure = &context.canopy_structure.*.?, .optics = &context.canopy_optics.*.?, .geometry = context.canopy_geometry, .direct_incidence_fraction = context.direct_incidence_fraction, .direct_incidence_per_horizontal_area = context.direct_incidence_per_horizontal_area };
            try tile_kernels.runKernelAcrossSerialTiles(context, &interception_context, ecosys.canopy_interception.applySingleLayerTile);
        }
    }
    var terrain_radiation_context: ecosys.terrain_radiation.MappedDirectSolarContext = .{ .state = context.terrain_radiation, .solar_angle_sine = context.hourly_solar_angle_sine, .solar_azimuth_radians = context.hourly_solar_azimuth_radians };
    try tile_kernels.runKernelAcrossSerialTiles(context, &terrain_radiation_context, ecosys.terrain_radiation.applyMappedDirectSolarTile);
    var ground_context: ecosys.ground_radiation.ApplyContext = .{ .result = context.ground_radiation, .radiation = context.canopy_radiation, .interception = if (context.canopy_interception.*) |*interception| interception else null, .terrain = context.terrain_radiation, .snow_depth_m = context.snow_depth_m, .full_snow_cover_depth_m = context.runscript.snow_full_cover_depth_m, .snow = context.snow_transport };
    try tile_kernels.runKernelAcrossSerialTiles(context, &ground_context, ecosys.ground_radiation.applyTile);
    if (context.canopy_interception.* != null and context.canopy_layer_distribution.* != null) {
        try ecosys.canopy_interception.applyGroundReflectedUpwardSweepWithBurial(&context.canopy_interception.*.?, &context.canopy_layer_distribution.*.?, &context.canopy_structure.*.?, &context.canopy_optics.*.?, context.canopy_geometry, context.ground_radiation.reflected_shortwave_megajoules_per_m2, context.ground_radiation.reflected_par_micromol_per_m2_per_s, context.runscript.woody_optics_parameters, canopy_burial);
    }
    if (context.canopy_precipitation_retention.*) |*retention| try ecosys.canopy_precipitation_retention.refreshFromModelWithBurial(retention, &context.canopy_layer_distribution.*.?, &context.detailed_canopy.*.?, &context.canopy_interception.*.?, context.atmosphere.rainfall_m, context.canopy_cell_area_m2, context.canopy_layer_controls.root_profile_type, context.hourly_solar_angle_sine, context.ground_radiation.incident_shortwave_megajoules_per_m2, context.runscript.canopy_retention_parameters, canopy_burial);
    try ecosys.surface_precipitation.prepareFromModel(context.surface_precipitation, context.atmosphere, context.grid, if (context.canopy_precipitation_retention.*) |*retention| retention else null, context.canopy_cell_area_m2, context.snow_depth_m, context.runscript.snow_full_cover_depth_m, context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3, .{
        .solid_snow_heat_capacity_megajoules_per_m3_k = context.runscript.snow_solid_heat_capacity_megajoules_per_m3_k,
        .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
    });
    // Litter ingress is not yet in storage here. Each accepted coupled
    // substep publishes `rate * dt` and then rebases chemistry against the exact
    // new carrier; doing so here would infer a fictitious (possibly negative)
    // pre-ingress carrier.
    // The accepted soil schedule now owns atmospheric snow mass/heat,
    // conduction, vapor, phase change, melt routing and snow chemistry. These
    // zero reports preserve the downstream signature; the schedule publishes
    // its accumulated phase/vapor heat ledger only after every substep succeeds.
    const zero_phase_by_cell = try context.allocator.alloc(f64, context.grid.cell_count);
    defer context.allocator.free(zero_phase_by_cell);
    @memset(zero_phase_by_cell, 0);
    const snow_phase_change_report: ecosys.snow_phase_change.Report = .{
        .iterations = 0,
        .converged = true,
        .maximum_temperature_residual_k = 0,
        .enthalpy_change_megajoules = 0,
        .sensible_energy_change_megajoules = 0,
        .sensible_energy_change_megajoules_by_cell = zero_phase_by_cell,
    };
    const zero_vapor_by_cell = try context.allocator.alloc(f64, context.grid.cell_count);
    defer context.allocator.free(zero_vapor_by_cell);
    @memset(zero_vapor_by_cell, 0);
    const zero_vapor_by_layer = try context.allocator.alloc(f64, context.snow_transport.active.len);
    defer context.allocator.free(zero_vapor_by_layer);
    @memset(zero_vapor_by_layer, 0);
    const snow_vapor_equilibrium_report: ecosys.snow_vapor_equilibrium.Report = .{
        .maximum_vapor_residual_m3 = 0,
        .enthalpy_change_megajoules = 0,
        .sensible_energy_change_megajoules = 0,
        .sensible_energy_change_megajoules_by_cell = zero_vapor_by_cell,
        .sensible_energy_change_megajoules_by_layer = zero_vapor_by_layer,
    };
    @memset(context.snow_atmospheric_input_g, 0);
    @memset(context.snow_atmospheric_input_salt_mol, 0);
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE driver radiation elapsed_ms={d}",
        .{temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds()},
    );
    for (0..context.grid.cell_count) |cell| {
        const weather_header = weather_header_by_cell[cell];
        var rain_gas_concentration = [_]f64{0} ** 5;
        {
            const surface_parameters = context.surface_gas_parameters.*;
            const solubility = try ecosys.gas_transport.surfaceSolubilityWaterToAir(context.atmosphere.air_temperature_k[cell], surface_parameters.solubility);
            const atmospheric_first = cell * ecosys.gas_transport.species_count;
            for (0..5) |species| rain_gas_concentration[species] = context.current_atmospheric_gas_concentration_g_per_m3[atmospheric_first + species] * solubility[species];
        }
        const reaction_parameters = context.chemistry_reaction_parameters.*;
        const precipitation_nitrogen = try scaledPrecipitationNitrogen(
            weather_header.precipitation_ammonium_g_per_m3,
            weather_header.precipitation_nitrate_g_per_m3,
            precipitation_chemistry_multipliers,
        );
        const nutrients = try ecosys.precipitation_nutrient_speciation.calculate(.{ .ph = weather_header.precipitation_ph, .ammonium_g_n_per_m3 = precipitation_nitrogen.ammonium_g_n_per_m3, .nitrate_g_n_per_m3 = precipitation_nitrogen.nitrate_g_n_per_m3, .phosphate_g_p_per_m3 = weather_header.precipitation_phosphate_g_per_m3 }, reaction_parameters.aqueous_constants, reaction_parameters.phosphate_constants);
        const rain_ions_g_per_m3 = rainIonsGPerM3(weather_header);
        const area_m2 = context.canopy_cell_area_m2[cell];
        const irrigation_depth_m = context.irrigation_water_depth_m[cell];
        const irrigation_volume_m3 = irrigation_depth_m * area_m2;
        const total_liquid_volume_m3 = context.surface_precipitation.rainfall_m3_per_h[cell];
        const source_scale_m3 = @max(total_liquid_volume_m3, irrigation_volume_m3);
        const source_tolerance_m3 = context.config.physical_tolerance.waterVolume(source_scale_m3);
        if (irrigation_volume_m3 > total_liquid_volume_m3 + source_tolerance_m3)
            return error.IrrigationExceedsPreparedAtmosphericLiquid;
        const weather_rain_m3 = @max(0, total_liquid_volume_m3 - irrigation_volume_m3);
        const snowfall_m3 = context.surface_precipitation.snow_to_snow_m3_per_h[cell];
        const first_snow = cell * context.snow_transport.layer_capacity;
        const surface_thermodynamics: ecosys.surface_precipitation.ThermodynamicParameters = .{
            .solid_snow_heat_capacity_megajoules_per_m3_k = context.runscript.snow_solid_heat_capacity_megajoules_per_m3_k,
            .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        };
        const pre_redistribution_litter_m3 = try ecosys.surface_precipitation.preRedistributionLitterWaterM3PerH(
            context.surface_precipitation,
            cell,
            surface_thermodynamics,
        );
        // Exact WATSUB FLQRQ/FLQRI/FLQGQ/FLQGI owner selection.  Chemistry
        // follows the source snow-presence branch, not the fractional water
        // cover router; on dry drainage-only hours every atmospheric carrier
        // is zero and the canopy transfer remains purely internal.
        const solute_routes = try ecosys.surface_precipitation.routePrecipitationSolutes(
            snowfall_m3,
            weather_rain_m3,
            weather_rain_m3 + snowfall_m3,
            irrigation_volume_m3,
            pre_redistribution_litter_m3,
            context.snow_transport.heat_capacity_megajoules_per_k[first_snow],
            ecosys.snow_solute_transport.activation_heat_capacity_megajoules_per_m2_k * area_m2,
            1,
        );
        const rain_to_snow_m3 = if (solute_routes.remaining_destination == .snow)
            solute_routes.rain_remaining_m3
        else
            0;
        const irrigation_to_snow_m3 = if (solute_routes.remaining_destination == .snow)
            solute_routes.irrigation_remaining_m3
        else
            0;
        var irrigation_nutrients = [_]f64{0} ** 5;
        var irrigation_ions_g_per_m3 = [_]f64{0} ** 8;
        var irrigation_ph: f64 = 7;
        var irrigation_ammonium_g_n_per_m3: f64 = 0;
        var irrigation_nitrate_g_n_per_m3: f64 = 0;
        var irrigation_phosphate_g_p_per_m3: f64 = 0;
        if (irrigation_depth_m > 0) {
            const first = cell * ecosys.irrigation_management_dispatch.dissolved_species_count;
            const concentration = context.irrigation_dissolved_mass_g_per_m2[first .. first + ecosys.irrigation_management_dispatch.dissolved_species_count];
            const hydrogen_mol_per_m3 = context.irrigation_hydrogen_mol_per_m2[cell] / irrigation_depth_m;
            irrigation_ph = -std.math.log10(@max(hydrogen_mol_per_m3 / 1000.0, 1.0e-14));
            irrigation_ammonium_g_n_per_m3 = concentration[0] / irrigation_depth_m;
            irrigation_nitrate_g_n_per_m3 = concentration[1] / irrigation_depth_m;
            irrigation_phosphate_g_p_per_m3 = concentration[2] / irrigation_depth_m;
            irrigation_nutrients = try ecosys.precipitation_nutrient_speciation.calculate(.{
                .ph = irrigation_ph,
                .ammonium_g_n_per_m3 = irrigation_ammonium_g_n_per_m3,
                .nitrate_g_n_per_m3 = irrigation_nitrate_g_n_per_m3,
                .phosphate_g_p_per_m3 = irrigation_phosphate_g_p_per_m3,
            }, reaction_parameters.aqueous_constants, reaction_parameters.phosphate_constants);
            for (&irrigation_ions_g_per_m3, 0..) |*ion, index| ion.* = concentration[3 + index] / irrigation_depth_m;
        }
        var input = try ecosys.snow_solute_transport.atmosphericInputG(rain_to_snow_m3, irrigation_to_snow_m3, rain_gas_concentration, [_]f64{0} ** 5, nutrients, irrigation_nutrients, rain_ions_g_per_m3, irrigation_ions_g_per_m3);
        if (context.snow_transport.dynamic_salts_by_cell[cell] and rain_to_snow_m3 + irrigation_to_snow_m3 > 0) {
            const dynamic = try equilibratedDynamicInput(
                context.allocator,
                context.soil_chemistry_solver_workspace,
                .{
                    .water_m3 = rain_to_snow_m3,
                    .ph = weather_header.precipitation_ph,
                    .dissolved_gas_g_per_m3 = rain_gas_concentration,
                    .ammonium_g_n_per_m3 = precipitation_nitrogen.ammonium_g_n_per_m3,
                    .nitrate_g_n_per_m3 = precipitation_nitrogen.nitrate_g_n_per_m3,
                    .phosphate_g_p_per_m3 = weather_header.precipitation_phosphate_g_per_m3,
                    .free_ion_g_per_m3 = rain_ions_g_per_m3,
                },
                .{
                    .water_m3 = irrigation_to_snow_m3,
                    .ph = irrigation_ph,
                    .dissolved_gas_g_per_m3 = @splat(0),
                    .ammonium_g_n_per_m3 = irrigation_ammonium_g_n_per_m3,
                    .nitrate_g_n_per_m3 = irrigation_nitrate_g_n_per_m3,
                    .phosphate_g_p_per_m3 = irrigation_phosphate_g_p_per_m3,
                    .free_ion_g_per_m3 = irrigation_ions_g_per_m3,
                },
                context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol,
                reaction_parameters,
                .{
                    .absolute_tolerance_mol_per_m3 = context.config.nonlinear_tolerance.reaction_mol_per_m3,
                    .absolute_tolerance_mol_per_megagram = context.config.nonlinear_tolerance.reaction_mol_per_megagram,
                    .relative_tolerance = context.config.nonlinear_tolerance.relative,
                    .picard_relaxation = context.config.picard_relaxation,
                    .include_zero_rate_full_network_axes = false,
                    .rate_ranked_coordinate_head_maximum_norm = 1.0e8,
                    .max_iterations = context.iteration_limits.initial_solute_reaction_max_iterations,
                },
                solute_failure_report,
                cell,
            );
            input = dynamic.primary_g;
            @memcpy(context.snow_atmospheric_input_salt_mol[cell * ecosys.snow_solute_transport.salt_species_count ..][0..ecosys.snow_solute_transport.salt_species_count], &dynamic.salt_mol);
        }
        @memcpy(context.snow_atmospheric_input_g[cell * ecosys.snow_solute_transport.species_count ..][0..ecosys.snow_solute_transport.species_count], &input);
        context.direct_surface_solute_input[cell] = .{};
        const top_soil_zone_fractions =
            try context.fertilizer_band.zoneFractions(cell, 0);
        const rain_to_soil_m3 = if (solute_routes.remaining_destination == .soil)
            solute_routes.rain_remaining_m3
        else
            0;
        const irrigation_to_soil_m3 = if (solute_routes.remaining_destination == .soil)
            solute_routes.irrigation_remaining_m3
        else
            0;
        const direct_litter_m3 = solute_routes.rain_to_litter_m3 + solute_routes.irrigation_to_litter_m3;
        const direct_soil_m3 = rain_to_soil_m3 + irrigation_to_soil_m3;
        const direct_rain_m3 = solute_routes.rain_to_litter_m3 + rain_to_soil_m3;
        const direct_irrigation_m3 = solute_routes.irrigation_to_litter_m3 + irrigation_to_soil_m3;
        const direct_carrier_m3 = direct_litter_m3 + direct_soil_m3;
        if (direct_carrier_m3 > 0) {
            var direct_input = try ecosys.snow_solute_transport.atmosphericInputG(direct_rain_m3, direct_irrigation_m3, rain_gas_concentration, [_]f64{0} ** 5, nutrients, irrigation_nutrients, rain_ions_g_per_m3, irrigation_ions_g_per_m3);
            var direct_salt_mol = [_]f64{0} ** ecosys.snow_solute_transport.salt_species_count;
            if (context.snow_transport.dynamic_salts_by_cell[cell]) {
                const dynamic = try equilibratedDynamicInput(
                    context.allocator,
                    context.soil_chemistry_solver_workspace,
                    .{ .water_m3 = direct_rain_m3, .ph = weather_header.precipitation_ph, .dissolved_gas_g_per_m3 = rain_gas_concentration, .ammonium_g_n_per_m3 = precipitation_nitrogen.ammonium_g_n_per_m3, .nitrate_g_n_per_m3 = precipitation_nitrogen.nitrate_g_n_per_m3, .phosphate_g_p_per_m3 = weather_header.precipitation_phosphate_g_per_m3, .free_ion_g_per_m3 = rain_ions_g_per_m3 },
                    .{ .water_m3 = direct_irrigation_m3, .ph = irrigation_ph, .dissolved_gas_g_per_m3 = @splat(0), .ammonium_g_n_per_m3 = irrigation_ammonium_g_n_per_m3, .nitrate_g_n_per_m3 = irrigation_nitrate_g_n_per_m3, .phosphate_g_p_per_m3 = irrigation_phosphate_g_p_per_m3, .free_ion_g_per_m3 = irrigation_ions_g_per_m3 },
                    context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol,
                    reaction_parameters,
                    .{ .absolute_tolerance_mol_per_m3 = context.config.nonlinear_tolerance.reaction_mol_per_m3, .absolute_tolerance_mol_per_megagram = context.config.nonlinear_tolerance.reaction_mol_per_megagram, .relative_tolerance = context.config.nonlinear_tolerance.relative, .picard_relaxation = context.config.picard_relaxation, .include_zero_rate_full_network_axes = false, .rate_ranked_coordinate_head_maximum_norm = 1.0e8, .max_iterations = context.iteration_limits.initial_solute_reaction_max_iterations },
                    solute_failure_report,
                    cell,
                );
                direct_input = dynamic.primary_g;
                direct_salt_mol = dynamic.salt_mol;
            }
            const litter_fraction = direct_litter_m3 / direct_carrier_m3;
            const soil_fraction = 1 - litter_fraction;
            for (direct_input, 0..) |amount_g, species| {
                context.direct_surface_solute_input[cell].litter_g[species] = amount_g * litter_fraction;
                const band_fraction = switch (@as(ecosys.snow_solute_transport.Species, @enumFromInt(species))) {
                    .ammonium_nitrogen, .ammonia_nitrogen => top_soil_zone_fractions.ammonium_band,
                    .nitrate_nitrogen => top_soil_zone_fractions.nitrate_band,
                    .hydrogen_phosphate_phosphorus, .dihydrogen_phosphate_phosphorus => top_soil_zone_fractions.phosphate_band,
                    else => 0,
                };
                context.direct_surface_solute_input[cell].soil_nonband_g[species] = amount_g * soil_fraction * (1 - band_fraction);
                context.direct_surface_solute_input[cell].soil_band_g[species] = amount_g * soil_fraction * band_fraction;
            }
            for (direct_salt_mol, 0..) |amount_mol, species| {
                context.direct_surface_solute_input[cell].litter_salt_mol[species] = amount_mol * litter_fraction;
                const band_fraction = if (species >= @intFromEnum(ecosys.snow_solute_transport.SaltSpecies.phosphate))
                    top_soil_zone_fractions.phosphate_band
                else
                    0;
                context.direct_surface_solute_input[cell].soil_nonband_salt_mol[species] = amount_mol * soil_fraction * (1 - band_fraction);
                context.direct_surface_solute_input[cell].soil_band_salt_mol[species] = amount_mol * soil_fraction * band_fraction;
            }
        }
        context.snow_surface_partitions[cell] = .{
            .litter_cover_fraction = context.surface_precipitation.litter_cover_fraction[cell],
            .bare_soil_fraction = 1 - context.surface_precipitation.litter_cover_fraction[cell],
            .nonband_ammonium_fraction = top_soil_zone_fractions.ammonium_non_band,
            .band_ammonium_fraction = top_soil_zone_fractions.ammonium_band,
            .nonband_nitrate_fraction = top_soil_zone_fractions.nitrate_non_band,
            .band_nitrate_fraction = top_soil_zone_fractions.nitrate_band,
            .nonband_phosphate_fraction = top_soil_zone_fractions.phosphate_non_band,
            .band_phosphate_fraction = top_soil_zone_fractions.phosphate_band,
        };
    }
    const atmospheric_parameters = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol;
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE driver atmospheric_chemistry elapsed_ms={d}",
        .{temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds()},
    );
    const atmospheric_ion_molar_masses: ecosys.snow_surface_discharge.IonMolarMassesGPerMol = .{
        .aluminum = atmospheric_parameters.aluminum,
        .iron = atmospheric_parameters.iron,
        .calcium = atmospheric_parameters.calcium,
        .magnesium = atmospheric_parameters.magnesium,
        .sodium = atmospheric_parameters.sodium,
        .potassium = atmospheric_parameters.potassium,
        .sulfur = atmospheric_parameters.sulfur,
        .chloride = atmospheric_parameters.chloride,
    };
    // HFUNC is invoked by the accepted-WATSUB continuation in
    // hourly_snow_energy. Keeping it out of the HOUR1 driver preserves the
    // source sequence WATSUB -> NITRO -> HFUNC -> UPTAKE (soil.f:157--175).
    try group_snow_energy.solveSnowSurfaceEnergyAndSoilTransport(
        context,
        hour_of_day,
        weather_header_by_cell,
        plant_calendar_by_cell,
        fertilizer_band_hour,
        gas_failure_report,
        solute_failure_report,
        diagnostic_first_hour,
        diagnostic_mineral_before_mol,
        diagnostic_relayer_phosphate_before,
        diagnostic_transport_ammonium_before,
        diagnostic_transport_before,
        plant_calendar,
        ground_air_geometry_balance,
        snow_phase_change_report,
        snow_vapor_equilibrium_report,
        &diagnostic_previous_heat_megajoules,
        &diagnostic_previous_n_g,
        &diagnostic_previous_p_g,
        &diagnostic_previous_p_owners,
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE driver coupled_stage elapsed_ms={d}",
        .{temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds()},
    );
    // Atmospheric chemistry is external activity, but its snow-owned portion
    // is not accepted until the complete internal substep schedule succeeds.
    // Preflight both ledgers first so publication remains atomic.
    for (0..context.grid.cell_count) |cell|
        try context.hourly_cell_boundary_ledger.preflight(cell, try ecosys.hourly_cell_conservation.atmosphericSoluteActivity(
            cell,
            context.grid.cell_count,
            context.snow_atmospheric_input_g,
            context.snow_atmospheric_input_salt_mol,
            context.direct_surface_solute_input,
            atmospheric_ion_molar_masses,
        ));
    try context.atmospheric_solute_input_ledger.accumulateAcceptedHour(
        context.snow_atmospheric_input_g,
        context.snow_atmospheric_input_salt_mol,
        context.direct_surface_solute_input,
    );
    for (0..context.grid.cell_count) |cell|
        try context.hourly_cell_boundary_ledger.accumulate(cell, try ecosys.hourly_cell_conservation.atmosphericSoluteActivity(
            cell,
            context.grid.cell_count,
            context.snow_atmospheric_input_g,
            context.snow_atmospheric_input_salt_mol,
            context.direct_surface_solute_input,
            atmospheric_ion_molar_masses,
        ));
    // Publish internal H2 production/consumption only after every hourly
    // science stage has returned successfully. Soil fermentation is
    // process-unit indexed, methanogenesis uptake is layer indexed, and
    // surface fermentation is cell indexed, and accepted surface autotrophic
    // primary reactions are [cell][active population], with active population
    // 3 carrying source N=5 hydrogenotroph H2 uptake. The accumulator preflights
    // the complete active domain and cumulative overflow before changing either
    // ledger direction; checkpoint restore removes it on an enclosing retry.
    try group_sediment.accumulateAcceptedHydrogenTransformations(
        context.landscape_boundary_ledger,
        context.hourly_cell_boundary_ledger,
        context.grid.active_soil_layer_count,
        context.grid.soil_layer_capacity,
        context.soil_respiration_products.process_unit_count_per_layer,
        context.soil_respiration_products.hydrogen_g_h,
        context.soil_methane.hydrogen_consumption_g_h,
        context.surface_microbial_oxygen.respiration_hydrogen_g_h_per_step,
        context.surface_autotrophic_complex.actual_primary_reaction,
    );
}

test "rainIonsGPerM3 binds the eight precipitation ion fields to Species order (PRECIP-ION-FEED-001)" {
    const header = ecosys.weather.Header{
        .temporal_code = .{ 'H', 'G' },
        .integer_column_count = 0,
        .real_column_count = 0,
        .integer_variable_codes = "",
        .weather_variable_codes = "",
        .weather_unit_codes = "",
        .aerodynamic_roughness_m = 0,
        .weather_flag = 0,
        .solar_noon_hour = 12,
        .precipitation_ph = 5.6,
        .precipitation_ammonium_g_per_m3 = 0,
        .precipitation_nitrate_g_per_m3 = 0,
        .precipitation_phosphate_g_per_m3 = 0,
        .precipitation_aluminum_g_per_m3 = 1,
        .precipitation_iron_g_per_m3 = 2,
        .precipitation_calcium_g_per_m3 = 3,
        .precipitation_magnesium_g_per_m3 = 4,
        .precipitation_sodium_g_per_m3 = 5,
        .precipitation_potassium_g_per_m3 = 6,
        .precipitation_sulfate_sulfur_g_per_m3 = 7,
        .precipitation_chloride_g_per_m3 = 8,
    };
    const rain_ions_g_per_m3 = rainIonsGPerM3(header);
    // Species order is .aluminum, .iron, .calcium, .magnesium, .sodium,
    // .potassium, .sulfate_sulfur, .chloride starting at index 10; this must
    // match atmosphericInputG's `output[10 + ion]` placement exactly.
    try std.testing.expectEqualSlices(f64, &[8]f64{ 1, 2, 3, 4, 5, 6, 7, 8 }, &rain_ions_g_per_m3);
}

test "rainIonsGPerM3 output feeds atmosphericInputG's rain channel, matching the irrigation channel it mirrors" {
    const header = ecosys.weather.Header{
        .temporal_code = .{ 'H', 'G' },
        .integer_column_count = 0,
        .real_column_count = 0,
        .integer_variable_codes = "",
        .weather_variable_codes = "",
        .weather_unit_codes = "",
        .aerodynamic_roughness_m = 0,
        .weather_flag = 0,
        .solar_noon_hour = 12,
        .precipitation_ph = 5.6,
        .precipitation_ammonium_g_per_m3 = 0,
        .precipitation_nitrate_g_per_m3 = 0,
        .precipitation_phosphate_g_per_m3 = 0,
        .precipitation_aluminum_g_per_m3 = 1,
        .precipitation_iron_g_per_m3 = 0,
        .precipitation_calcium_g_per_m3 = 0,
        .precipitation_magnesium_g_per_m3 = 0,
        .precipitation_sodium_g_per_m3 = 0,
        .precipitation_potassium_g_per_m3 = 0,
        .precipitation_sulfate_sulfur_g_per_m3 = 0,
        .precipitation_chloride_g_per_m3 = 0,
    };
    const rain_ions_g_per_m3 = rainIonsGPerM3(header);
    const irrigation_ions_g_per_m3 = [_]f64{0} ** 8;
    const output = try ecosys.snow_solute_transport.atmosphericInputG(
        2, // rain_water_m3
        0, // irrigation_water_m3
        [_]f64{0} ** 5,
        [_]f64{0} ** 5,
        [_]f64{0} ** 5,
        [_]f64{0} ** 5,
        rain_ions_g_per_m3,
        irrigation_ions_g_per_m3,
    );
    const aluminum_species: usize = @intFromEnum(ecosys.snow_solute_transport.Species.aluminum);
    try std.testing.expectApproxEqAbs(@as(f64, 2), output[aluminum_species], 1e-12);
}

test "WTHR precipitation nitrogen multipliers apply to baselines before speciation" {
    const scaled = try scaledPrecipitationNitrogen(0.125, 0.2, .{
        .ammonium = 2.0,
        .nitrate = 3.0,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), scaled.ammonium_g_n_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), scaled.nitrate_g_n_per_m3, 1e-15);
}

test "WTHR precipitation nitrogen scaling rejects invalid climate carriers" {
    try std.testing.expectError(
        error.NonFiniteAtmosphericChemistryMultiplier,
        scaledPrecipitationNitrogen(0.125, 0.2, .{
            .ammonium = std.math.nan(f64),
            .nitrate = 1,
        }),
    );
}

test "production layered canopy never lets the compact owner overwrite burial transmission" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_process_driver.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const layered = std.mem.indexOf(u8, source, "if (context.canopy_layer_distribution.*) |*layers| {") orelse
        return error.MissingLayeredCanopyOwner;
    const fallback = std.mem.indexOfPos(u8, source, layered, "} else {") orelse
        return error.MissingCompactCanopyFallback;
    const compact = std.mem.indexOf(u8, source, "ecosys.canopy_interception.applySingleLayerTile") orelse
        return error.MissingCompactCanopyOwner;
    const transmission = std.mem.indexOfPos(u8, source, layered, "refreshLayerTransmissionWithBurial") orelse
        return error.MissingCanopyBurialTransmission;
    const absorption = std.mem.indexOfPos(u8, source, layered, "refreshAtmosphericLayerAbsorptionWithBurial") orelse
        return error.MissingCanopyBurialAbsorption;

    try std.testing.expect(transmission < fallback);
    try std.testing.expect(absorption < fallback);
    try std.testing.expect(compact > fallback);
}

test "production publishes source ZS before every aerodynamic consumer" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_process_driver.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    const snow_energy = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_snow_energy.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(snow_energy);

    const source_zs = std.mem.indexOf(u8, source, "sourceGroundSurfaceRoughnessHeightM(") orelse
        return error.MissingSourceGroundRoughnessOwner;
    const aerodynamic_call = std.mem.indexOfPos(u8, source, source_zs, "surface_aerodynamics.applyTile") orelse
        return error.MissingSurfaceAerodynamicConsumer;
    try std.testing.expect(source_zs < aerodynamic_call);
    try std.testing.expect(std.mem.indexOfPos(u8, source, source_zs, ".ground_surface_roughness_height_m = context.canopy_surface_roughness_height_m") != null);
    try std.testing.expect(std.mem.indexOf(u8, snow_energy, "canopy_surface_roughness_height_m[cell] = if (context.snow_depth_m[cell] > 0)") == null);
}

test "production refreshes the site boundary mask before snow drift can run" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_process_driver.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    const boundary_refresh = std.mem.indexOf(
        u8,
        source,
        "refreshSurfaceBoundaryOpenFlags(context)",
    ) orelse return error.MissingPreWatsubSurfaceBoundaryRefresh;
    const snow_energy = std.mem.indexOf(
        u8,
        source,
        "group_snow_energy.solveSnowSurfaceEnergyAndSoilTransport(",
    ) orelse return error.MissingSnowEnergyOwner;
    try std.testing.expect(boundary_refresh < snow_energy);
}

test "surface boundary mask is rebuilt from site edges without prior runtime state" {
    const Site = struct { surface_runoff_boundary_fraction: [4]f64, compass_aspect_degrees: f64 };
    var east = [_]bool{true} ** 4;
    var west = [_]bool{true} ** 4;
    var south = [_]bool{true} ** 4;
    var north = [_]bool{true} ** 4;
    // Aspects chosen so each cell's topographic gate (starts.f:274-303) does
    // not disable any direction this test already expects open, isolating
    // this test to edge/fraction detection; the dedicated gate test below
    // covers the case where the gate actually changes the outcome.
    const sites = [_]Site{
        .{ .surface_runoff_boundary_fraction = .{ 1, 1, 1, 1 }, .compass_aspect_degrees = 135 },
        .{ .surface_runoff_boundary_fraction = .{ 1, 0, 1, 1 }, .compass_aspect_degrees = 135 },
        .{ .surface_runoff_boundary_fraction = .{ 0, 1, 1, 1 }, .compass_aspect_degrees = 225 },
        .{ .surface_runoff_boundary_fraction = .{ 1, 1, 1, 1 }, .compass_aspect_degrees = 315 },
    };
    const grid = .{ .cell_count = @as(usize, 4) };
    const config = .{ .lon_count = @as(usize, 2), .lat_count = @as(usize, 2) };
    var erosion = .{
        .east_boundary_open = &east,
        .west_boundary_open = &west,
        .south_boundary_open = &south,
        .north_boundary_open = &north,
    };
    refreshSurfaceBoundaryOpenFlags(.{
        .grid = &grid,
        .config = config,
        .surface_erosion = &erosion,
        .site_by_cell = &sites,
    });
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, true }, &east);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, false }, &west);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true, true }, &south);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, false }, &north);
}

test "topographicDownhillGate matches starts.f:274-303's four aspect quadrants exactly" {
    // ASP in [0,90): IRCHG(1,1)=1,IRCHG(2,1)=0,IRCHG(1,2)=0,IRCHG(2,2)=1
    // -> east=1(enabled),west=0,south=0,north=1.
    var gate = topographicDownhillGate(45);
    try std.testing.expectEqual(TopographicDownhillGate{ .east = true, .west = false, .south = false, .north = true }, gate);
    // ASP in [90,180): IRCHG(1,1)=0,IRCHG(2,1)=1,IRCHG(1,2)=0,IRCHG(2,2)=1
    // -> east=0,west=1,south=0,north=1.
    gate = topographicDownhillGate(135);
    try std.testing.expectEqual(TopographicDownhillGate{ .east = false, .west = true, .south = false, .north = true }, gate);
    // ASP in [180,270): IRCHG(1,1)=0,IRCHG(2,1)=1,IRCHG(1,2)=1,IRCHG(2,2)=0
    // -> east=0,west=1,south=1,north=0.
    gate = topographicDownhillGate(225);
    try std.testing.expectEqual(TopographicDownhillGate{ .east = false, .west = true, .south = true, .north = false }, gate);
    // ASP in [270,360]: IRCHG(1,1)=1,IRCHG(2,1)=0,IRCHG(1,2)=1,IRCHG(2,2)=0
    // -> east=1,west=0,south=1,north=0.
    gate = topographicDownhillGate(315);
    try std.testing.expectEqual(TopographicDownhillGate{ .east = true, .west = false, .south = true, .north = false }, gate);
    gate = topographicDownhillGate(360);
    try std.testing.expectEqual(TopographicDownhillGate{ .east = true, .west = false, .south = true, .north = false }, gate);
}

test "surface boundary mask closes an uphill direction even when the user-set fraction permits it" {
    // starts.f:274-303: IRCHG.EQ.0 forbids export regardless of RCHQF. A
    // south-facing slope (aspect 225, quadrant [180,270): south enabled,
    // north forbidden) with a nonzero north fraction must still close north.
    const Site = struct { surface_runoff_boundary_fraction: [4]f64, compass_aspect_degrees: f64 };
    var east = [_]bool{false} ** 1;
    var west = [_]bool{false} ** 1;
    var south = [_]bool{false} ** 1;
    var north = [_]bool{true} ** 1;
    const sites = [_]Site{
        .{ .surface_runoff_boundary_fraction = .{ 1, 1, 1, 1 }, .compass_aspect_degrees = 225 },
    };
    const grid = .{ .cell_count = @as(usize, 1) };
    const config = .{ .lon_count = @as(usize, 1), .lat_count = @as(usize, 1) };
    var erosion = .{
        .east_boundary_open = &east,
        .west_boundary_open = &west,
        .south_boundary_open = &south,
        .north_boundary_open = &north,
    };
    refreshSurfaceBoundaryOpenFlags(.{
        .grid = &grid,
        .config = config,
        .surface_erosion = &erosion,
        .site_by_cell = &sites,
    });
    // aspect 225 -> east=false,west=true,south=true,north=false.
    try std.testing.expectEqualSlices(bool, &.{false}, &east);
    try std.testing.expectEqualSlices(bool, &.{true}, &west);
    try std.testing.expectEqualSlices(bool, &.{true}, &south);
    // The user's fraction alone (nonzero) would have kept this open; the
    // topographic gate is the only thing that can close it here.
    try std.testing.expectEqualSlices(bool, &.{false}, &north);
}

test "production suppresses first-day forensic landscape scans when debug logging is disabled" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_process_driver.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "std.log.logEnabled(.debug, .default) and context.executed_weather_hours.* < 24",
    ) != null);
}

//! `hourly_science` declarations: gas surface water.
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
const group_timestep_finalize = @import("hourly_timestep_finalize.zig");
const group_sediment = @import("hourly_sediment.zig");
const group_support = @import("hourly_process_support.zig");

/// Returns the geometric litter phase volume used by WATSUB's `TVOLWI` and
/// `XVOLT`. Runtime ice storage is liquid-water equivalent, while pore filling,
/// ponding, and cover consume physical ice volume.
pub fn litterLiquidAndPhysicalIceVolumeM3(
    liquid_water_m3: f64,
    ice_water_equivalent_m3: f64,
    ice_density_megagrams_per_m3: f64,
) !f64 {
    if (!std.math.isFinite(liquid_water_m3) or liquid_water_m3 < 0)
        return error.InvalidSurfaceLitterWaterStorage;
    const physical_ice_m3 = try ecosys.ice_units.physicalVolumeM3FromWaterEquivalent(
        ice_water_equivalent_m3,
        ice_density_megagrams_per_m3,
    );
    const total_m3 = liquid_water_m3 + physical_ice_m3;
    if (!std.math.isFinite(total_m3))
        return error.InvalidSurfaceLitterWaterStorage;
    return total_m3;
}

test "litter phase geometry converts ice water equivalent before excess threshold" {
    const density = ecosys.ice_units.reference_ice_density_megagrams_per_m3;
    const liquid_water_m3: f64 = 0.95;
    const physical_ice_m3: f64 = 0.051;
    const ice_water_equivalent_m3 = physical_ice_m3 * density;
    const retention_capacity_m3: f64 = 1;

    // WE arithmetic remains below retention, while the physical ice expansion
    // crosses it. This is the production-sensitive branch the regression owns.
    try std.testing.expect(liquid_water_m3 + ice_water_equivalent_m3 < retention_capacity_m3);
    const physical_phase_m3 = try litterLiquidAndPhysicalIceVolumeM3(
        liquid_water_m3,
        ice_water_equivalent_m3,
        density,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.001), physical_phase_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.001),
        @max(0, physical_phase_m3 - retention_capacity_m3),
        1.0e-15,
    );
}

fn residueCarbonAtLayerG(
    state: *const ecosys.soil_organic_initialization.State,
    layer: usize,
) !f64 {
    if (layer >= state.layer_count)
        return error.OrganicErosionDimensionMismatch;
    var total: f64 = 0;
    for (0..ecosys.soil_organic_initialization.substrate_count - 1) |substrate| {
        total += try state.substrateCarbon_g_c(layer, substrate);
        const charcoal_index =
            (layer * ecosys.soil_organic_initialization.substrate_count + substrate) *
            ecosys.soil_organic_initialization.structural_fraction_count +
            (ecosys.soil_organic_initialization.structural_fraction_count - 1);
        total -= state.structural[charcoal_index].carbon_g_c;
    }
    if (!std.math.isFinite(total) or total < 0)
        return error.InvalidOrganicErosionState;
    return total;
}

/// Refreshes the hourly surface conductance used by each internal coupled-gas
/// substep. The conductance remains an hourly rate; gas transport applies dt.
pub fn refreshSoilSurfaceGasConductances(context: anytype) !void {
    for (0..context.grid.cell_count) |cell|
        try refreshSoilSurfaceGasConductanceCell(context, cell);
}

fn refreshSoilSurfaceGasConductanceCell(context: anytype, cell: usize) !void {
    const snow_first = cell * context.snow_transport.layer_capacity;
    const snow_end = snow_first + context.snow_transport.layer_capacity;
    for (snow_first..snow_end) |snow_layer| {
        const snow_temperature_k = if (context.snow_transport.temperature_k[snow_layer] > 0)
            context.snow_transport.temperature_k[snow_layer]
        else
            context.atmosphere.air_temperature_k[cell];
        context.snow_layer_gas_diffusivity_m2_per_h[snow_layer] =
            context.runscript.snow_vapor_diffusion_parameters.reference_vapor_diffusivity_m2_per_h *
            std.math.pow(
                f64,
                snow_temperature_k / context.runscript.snow_vapor_diffusion_parameters.reference_temperature_k,
                context.runscript.snow_vapor_diffusion_parameters.temperature_exponent,
            );
    }
    const area_m2 = context.canopy_cell_area_m2[cell];
    const litter_volume_m3 = context.surface_litter_geometry.expanded_total_volume_m3[cell];
    const litter_air_m3 = context.surface_litter_geometry.air_volume_m3[cell];
    const litter_porosity = context.surface_litter_geometry.porosity_m3_per_m3[cell];
    const atmospheric_diffusivity_m2_per_h =
        context.runscript.soil_process_parameters.reference_water_vapor_diffusivity_m2_per_h *
        std.math.pow(
            f64,
            context.atmosphere.air_temperature_k[cell] /
                context.runscript.soil_process_parameters.vapor_diffusivity_reference_temperature_k,
            context.runscript.soil_process_parameters.vapor_diffusivity_temperature_exponent,
        );
    const litter_diffusivity_m2_per_h =
        context.runscript.soil_process_parameters.reference_water_vapor_diffusivity_m2_per_h *
        std.math.pow(
            f64,
            context.grid.surface_temperature_k[cell] /
                context.runscript.soil_process_parameters.vapor_diffusivity_reference_temperature_k,
            context.runscript.soil_process_parameters.vapor_diffusivity_temperature_exponent,
        );
    const current_litter_phase_volume_m3 = try litterLiquidAndPhysicalIceVolumeM3(
        context.surface_precipitation.litter_water_m3[cell],
        context.surface_litter_ice_m3[cell],
        context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
    );
    const current_litter_excess_m3 = @max(
        0,
        current_litter_phase_volume_m3 -
            context.surface_precipitation.litter_water_capacity_m3[cell],
    );
    const surface_capacity_m3 = context.runscript.surface_runoff_parameters.ground_surface_retention_m3_per_m2 * area_m2;
    const water_cover_fraction = if (surface_capacity_m3 > 0)
        std.math.clamp(current_litter_excess_m3 / surface_capacity_m3, 0, 1)
    else if (current_litter_excess_m3 > 0)
        @as(f64, 1)
    else
        @as(f64, 0);
    const litter_porous_resistance_h_per_m = if (litter_volume_m3 > 0 and litter_air_m3 > 0 and litter_porosity > 0) blk: {
        const air_fraction = std.math.clamp(litter_air_m3 / litter_volume_m3, 0, litter_porosity) *
            @max(0, 1 - water_cover_fraction);
        const transport_factor = @max(
            context.runscript.surface_gas_resistance_parameters.minimum_air_fraction,
            context.runscript.soil_gas_transport_parameters.penman_tortuosity *
                air_fraction * air_fraction / litter_porosity,
        );
        break :blk (litter_volume_m3 / area_m2) / litter_diffusivity_m2_per_h / transport_factor;
    } else 0;
    const total_litter_carbon_g_c = try context.surface_organic.totalCarbon_g_c(cell);
    const litter_fraction = try ecosys.ground_radiation.liveLitterCoverFraction(
        total_litter_carbon_g_c,
        area_m2,
        context.surface_heat_capacity_megajoules_per_k[cell],
        context.surface_pond_minimum_heat_capacity_megajoules_per_k[cell],
        current_litter_excess_m3,
        surface_capacity_m3,
    );
    const snow_bottom = snow_end - 1;
    const snow_fraction = (try ecosys.snow_cover_fraction.evaluate(
        context.snow_transport.cumulative_depth_m[snow_bottom],
        context.runscript.snow_full_cover_depth_m,
    )).snow_fraction;
    const snow_surface_temperature_k = if (context.snow_transport.temperature_k[snow_first] > 0)
        context.snow_transport.temperature_k[snow_first]
    else
        context.grid.surface_temperature_k[cell];
    const top = try context.grid.layerIndex(cell, 0);
    const composite_surface_temperature_k = snow_fraction * snow_surface_temperature_k +
        (1 - snow_fraction) * (litter_fraction * context.grid.surface_temperature_k[cell] +
            (1 - litter_fraction) * context.grid.soil_temperature_k[top]);
    const resistance = try ecosys.surface_gas_boundary_conductance.calculate(.{
        .cell_area_m2 = area_m2,
        .air_temperature_k = context.atmosphere.air_temperature_k[cell],
        .ground_air_temperature_k = context.ground_air.temperature_k[cell],
        .surface_temperature_k = composite_surface_temperature_k,
        .bulk_richardson_coefficient_k = context.surface_aerodynamics.bulk_richardson_coefficient_k[cell],
        .isothermal_atmospheric_resistance_h_per_m = context.surface_aerodynamics.isothermal_aerodynamic_resistance_h_per_m[cell],
        .total_canopy_area_m2 = context.surface_total_canopy_area_m2[cell],
        .canopy_height_m = context.surface_canopy_height_m[cell],
        .roughness_height_m = context.canopy_surface_roughness_height_m[cell],
        .atmospheric_vapor_diffusivity_m2_per_h = atmospheric_diffusivity_m2_per_h,
        .isothermal_ground_surface_resistance_h_per_m = ecosys.surface_gas_boundary_conductance.ground_isothermal_surface_resistance_h_per_m,
        .bare_surface_fraction = 1 - litter_fraction,
        .litter_surface_fraction = litter_fraction,
        .litter_porous_resistance_h_per_m = litter_porous_resistance_h_per_m,
        .snow_layer_thickness_m = context.snow_transport.layer_thickness_m[snow_first..snow_end],
        .snow_layer_total_volume_m3 = context.snow_transport.total_layer_volume_m3[snow_first..snow_end],
        .snow_layer_air_volume_m3 = context.snow_transport.air_filled_volume_m3[snow_first..snow_end],
        .snow_layer_vapor_diffusivity_m2_per_h = context.snow_layer_gas_diffusivity_m2_per_h[snow_first..snow_end],
    }, context.runscript.surface_gas_resistance_parameters);
    context.litter_atmospheric_gas_conductance_m3_per_h[cell] = resistance.atmospheric_litter_gas_conductance_m3_per_h;
    context.soil_atmospheric_gas_conductance_m3_per_h[cell] = resistance.atmospheric_gas_conductance_m3_per_h;
}

pub fn transportDissolvedGasAndSurfaceWater(
    context: anytype,
    hour_of_day: u8,
    weather_header_by_cell: []const ecosys.weather.Header,
    plant_calendar_by_cell: []const ecosys.plant_development.Calendar,
    fertilizer_band_hour: ecosys.fertilizer_band_phase_coordinator.HourToken,
    gas_failure_report: ?ecosys.soil_gas_transport_step.FailureReportRequest,
    solute_failure_report: ?ecosys.solute_failure_reporter.Request,
    soil_gas_already_advanced: bool,
    diagnostic_first_hour: anytype,
    plant_calendar: anytype,
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
    if (!soil_gas_already_advanced) {
        try context.soil_dissolved_gas_face_parameters.refresh(
            context.grid,
            context.soil_transport_faces,
            context.soil_face_geometry,
            context.soil_solver_properties.matrix_bulk_volume_m3,
            context.soil_solver_properties.bulk_density_megagrams_per_m3,
            1,
            .{},
        );
        // The transport transaction rolls back internally; propagate failure so
        // the hourly driver never accepts stale pre-step gas state.
        const diagnostic_dissolved_transport_n_before_g = if (diagnostic_first_hour)
            try group_support.diagnosticGasNitrogen_g(context.gas_transport)
        else
            0;
        _ = try ecosys.soil_dissolved_gas_transport.advance(
            context.allocator,
            context.soil_dissolved_gas_transport,
            context.gas_transport,
            .{
                .faces = context.soil_transport_faces,
                .micropore_conductance_m3_per_step = context.soil_dissolved_gas_face_parameters.micropore_conductance_m3_per_step,
                .macropore_conductance_m3_per_step = context.soil_dissolved_gas_face_parameters.macropore_conductance_m3_per_step,
                .micropore_water_m3 = context.grid.matrix_liquid_water_m3,
                .macropore_water_m3 = context.grid.macropore_liquid_water_m3,
                .layer_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3,
                .micropore_external_water_flux_m3_per_step = context.transport_hydrology.micropore_external_water_flux_m3_per_step,
                .macropore_external_water_flux_m3_per_step = context.transport_hydrology.macropore_external_water_flux_m3_per_step,
                .recharge_concentration_g_per_m3 = context.soil_dissolved_gas_recharge_concentration_g_per_m3,
            },
            .{
                .absolute_tolerance_by_species = &.{
                    context.config.nonlinear_tolerance.carbon_g,
                    context.config.nonlinear_tolerance.carbon_g,
                    context.config.nonlinear_tolerance.oxygen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    2 * context.config.nonlinear_tolerance.amount_mol,
                },
                .relative_tolerance = context.config.nonlinear_tolerance.relative,
                .conservation_absolute_tolerance_g_per_m2_by_species = &.{
                    context.config.mass_balance_absolute_tolerance.carbon_g_m2,
                    context.config.mass_balance_absolute_tolerance.carbon_g_m2,
                    context.config.mass_balance_absolute_tolerance.oxygen_g_m2,
                    context.config.mass_balance_absolute_tolerance.nitrogen_g_m2,
                    context.config.mass_balance_absolute_tolerance.nitrogen_g_m2,
                    context.config.mass_balance_absolute_tolerance.nitrogen_g_m2,
                    context.config.mass_balance_absolute_tolerance.hydrogen_g_m2,
                },
                .conservation_relative_tolerance = context.config.mass_balance_relative_tolerance,
                .soil_layer_capacity = context.grid.soil_layer_capacity,
                .horizontal_cell_area_m2 = context.canopy_cell_area_m2,
                .picard_relaxation = context.config.picard_relaxation,
                .max_iterations = context.iteration_limits.gas_max_iterations,
            },
        );
        if (diagnostic_first_hour) {
            var diagnostic_boundary_n_g: f64 = 0;
            for (0..context.grid.layer_count) |layer| {
                const base = layer * ecosys.gas_transport.species_count;
                inline for ([_]ecosys.gas_transport.Species{ .nitrogen, .nitrous_oxide, .ammonia }) |species|
                    diagnostic_boundary_n_g += context.soil_dissolved_gas_transport.boundary_net_flux_g[base + @intFromEnum(species)];
            }
            const diagnostic_after_g = try group_support.diagnosticGasNitrogen_g(context.gas_transport);
            std.log.debug("dissolved gas nitrogen transaction: delta_g={e} boundary_g={e} residual_g={e}", .{ diagnostic_after_g - diagnostic_dissolved_transport_n_before_g, diagnostic_boundary_n_g, diagnostic_after_g - diagnostic_dissolved_transport_n_before_g - diagnostic_boundary_n_g });
            const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
            std.log.debug("nitrogen stage: dissolved_gas_transport delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
            diagnostic_previous_n_g = current_n_g;
            const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
            std.log.info("phosphorus stage: dissolved_gas_transport delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
            diagnostic_previous_p_g = current_p_g;
            const heat_megajoules = (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules;
            std.log.debug("heat stage: dissolved_gas_transport hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, heat_megajoules - diagnostic_previous_heat_megajoules });
            diagnostic_previous_heat_megajoules = heat_megajoules;
        }
        {
            const surface_parameters = context.surface_gas_parameters.*;
            try refreshSoilSurfaceGasConductances(context);
            if (diagnostic_first_hour) {
                const heat_megajoules = (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules;
                std.log.debug("heat stage: before_coupled_gas hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, heat_megajoules - diagnostic_previous_heat_megajoules });
                diagnostic_previous_heat_megajoules = heat_megajoules;
            }
            {
                const diagnostic_n_before_g = if (context.executed_weather_hours.* < 24)
                    try group_support.diagnosticGasNitrogen_g(context.gas_transport)
                else
                    0;
                var accepted_gas_state = try context.gas_transport.clone(
                    context.allocator,
                );
                defer accepted_gas_state.deinit();
                _ = try context.soil_gas_transport.advance(.{
                    .grid = context.grid,
                    .hydrology = context.transport_hydrology,
                    .soil_faces = context.soil_transport_faces,
                    .geometry = context.soil_face_geometry,
                    .matrix_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3,
                    .total_porosity_fraction = context.soil_solver_properties.porosity_fraction,
                    .field_capacity_fraction = context.soil_field_capacity_fraction,
                    .gas_state = &accepted_gas_state,
                    .solubility_parameters = surface_parameters.solubility,
                    .exchange_parameters = surface_parameters.exchange,
                    .ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
                    .ammonium_band_fraction_provider = .{
                        .context = context.fertilizer_band,
                        .at = @TypeOf(context.fertilizer_band.*).scienceAmmoniumBandFractionForFlatIndexOpaque,
                    },
                    .surface_boundary_inputs = .{
                        .atmospheric_conductance_m3_per_step = context.soil_atmospheric_gas_conductance_m3_per_h,
                        .cell_area_m2 = context.canopy_cell_area_m2,
                        .top_layer_thickness_m = context.soil_solver_properties.layer_thickness_m,
                        .atmospheric_concentration_g_per_m3 = context.current_atmospheric_gas_concentration_g_per_m3,
                    },
                    .subsurface_boundary_inputs = .{
                        .topology = context.soil_boundary_topology,
                        .layer_thickness_m = context.soil_solver_properties.layer_thickness_m,
                        .external_concentration_g_per_m3 = context.current_atmospheric_gas_concentration_g_per_m3,
                    },
                    .parameters = context.runscript.soil_gas_transport_parameters,
                    .solver_options = .{
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
                        .transport_iteration_fraction = 1,
                        .max_iterations = context.iteration_limits.gas_max_iterations,
                        .accept_physically_conserved_ceiling = true,
                    },
                    .failure_report = gas_failure_report,
                });
                const diagnostic_n_accepted_g = if (context.executed_weather_hours.* < 24)
                    try group_support.diagnosticGasNitrogen_g(&accepted_gas_state)
                else
                    0;
                try group_timestep_finalize.state_updateHourlyGasContributionGeneration(
                    context,
                    &accepted_gas_state,
                );
                if (context.executed_weather_hours.* < 24) {
                    var diagnostic_boundary_n_g: f64 = 0;
                    inline for ([_]ecosys.gas_transport.Species{ .nitrogen, .nitrous_oxide, .ammonia }) |species| {
                        for (0..context.grid.layer_count) |layer| {
                            diagnostic_boundary_n_g += context.soil_gas_transport.atmospheric_flux_g_per_h[
                                layer * ecosys.gas_transport.species_count + @intFromEnum(species)
                            ];
                            diagnostic_boundary_n_g += context.soil_gas_transport.subsurface_flux_g_per_h[
                                layer * ecosys.gas_transport.species_count + @intFromEnum(species)
                            ];
                        }
                    }
                    std.log.debug(
                        "gas nitrogen transaction: hour={d} before={e} accepted={e} state_updateted={e} delta={e} boundary={e} residual={e}",
                        .{
                            context.executed_weather_hours.* + 1,
                            diagnostic_n_before_g,
                            diagnostic_n_accepted_g,
                            try group_support.diagnosticGasNitrogen_g(context.gas_transport),
                            diagnostic_n_accepted_g - diagnostic_n_before_g,
                            diagnostic_boundary_n_g,
                            diagnostic_n_accepted_g - diagnostic_n_before_g - diagnostic_boundary_n_g,
                        },
                    );
                }
            }
        }
    }
    if (diagnostic_first_hour) {
        const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
        std.log.debug("nitrogen stage: coupled_gas_transport delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
        diagnostic_previous_n_g = current_n_g;
        const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
        std.log.info("phosphorus stage: coupled_gas_transport delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
        try diagnostics.logPhosphorusRepresentation(context, "after_coupled_gas_transport");
        diagnostic_previous_p_g = current_p_g;
        const heat_megajoules = (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules;
        std.log.debug("heat stage: through_coupled_gas hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, heat_megajoules - diagnostic_previous_heat_megajoules });
        diagnostic_previous_heat_megajoules = heat_megajoules;
    }
    // Accepted litter ingress is already published and carrier-rebased in each
    // coupled substep. Snow is mirrored from the authoritative snow owner; a
    // late one-hour runtime ingress would double both carriers.
    // WATSUB:137 refreshes ALTG from immutable site altitude and the current
    // REDIST surface boundary before any surface hydraulic-head comparison.
    try context.terrain_hydrology.refreshCurrentSurfaceElevations(context.soil_geometry);
    for (0..context.grid.cell_count) |cell| {
        const area_m2 = context.canopy_cell_area_m2[cell];
        const recovered_energy_j_per_m2 = try ecosys.surface_precipitation.recoverRainfallImpactEnergy(
            context.surface_precipitation.cumulative_rainfall_impact_energy_j[cell],
            1,
            context.runscript.rainfall_impact_parameters.conductivity_recovery_fraction_per_h,
        );
        context.surface_precipitation.cumulative_rainfall_impact_energy_j[cell] = recovered_energy_j_per_m2;
        const top_layer = cell * context.grid.soil_layer_capacity;
        const sand_fraction = context.soil_solver_properties.sand_mass_fraction[top_layer];
        const clay_fraction = context.soil_solver_properties.clay_mass_fraction[top_layer];
        const silt_fraction = @max(0, 1 - sand_fraction - clay_fraction);
        const total_rainfall_mm_per_h = context.surface_precipitation.rainfall_m3_per_h[cell] / area_m2 * 1.0e3;
        if (total_rainfall_mm_per_h <= 0) {
            context.surface_precipitation.rainfall_impact_energy_j[cell] = 0;
            const multiplier = try ecosys.surface_precipitation.rainfallConductivityMultiplier(
                recovered_energy_j_per_m2,
                silt_fraction,
                clay_fraction,
                context.runscript.rainfall_impact_parameters.conductivity_damage_per_j_per_megagram_per_megagram,
            );
            context.surface_precipitation.saturated_hydraulic_conductivity_multiplier[cell] = multiplier;
            context.soil_solver_properties.rainfall_conductivity_multiplier[top_layer] = multiplier;
            continue;
        }
        // WATSUB:430-435 splits ground-arriving precipitation into PRECD
        // (fell through canopy gaps, never touched foliage: PRECA-TFLWCI)
        // and PRECB (touched canopy but drained off rather than being
        // retained: TFLWCI-TFLWC). This must not be re-derived from the
        // net-of-retention throughfall (PRECA-TFLWC) split by canopy
        // exposure fraction -- that is a different decomposition and only
        // coincides with PRECD/PRECB when TFLWC is exactly zero.
        const potential_interception_m3_per_h = if (context.canopy_precipitation_retention.*) |*retention|
            retention.cell_potential_interception_m3_per_h[cell]
        else
            0;
        const retention_flux_m3_per_h = if (context.canopy_precipitation_retention.*) |*retention|
            retention.cell_retention_m3_per_h[cell]
        else
            0;
        const direct_precipitation_mm_per_h = (context.surface_precipitation.rainfall_m3_per_h[cell] - potential_interception_m3_per_h) / area_m2 * 1.0e3;
        const canopy_throughfall_mm_per_h = (potential_interception_m3_per_h - retention_flux_m3_per_h) / area_m2 * 1.0e3;
        const impact = try ecosys.surface_precipitation.rainfallImpact(
            recovered_energy_j_per_m2,
            .{
                .direct_precipitation_mm_per_h = direct_precipitation_mm_per_h,
                .throughfall_mm_per_h = canopy_throughfall_mm_per_h,
                .total_precipitation_mm_per_h = total_rainfall_mm_per_h,
                .canopy_height_m = context.surface_canopy_height_m[cell],
                .excess_surface_storage_m3 = @max(0, context.surface_precipitation.litter_water_m3[cell] + context.surface_litter_ice_m3[cell] / context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3 - context.surface_precipitation.litter_water_capacity_m3[cell]),
                .ground_surface_retention_m3 = context.runscript.surface_runoff_parameters.ground_surface_retention_m3_per_m2 * area_m2,
                .surface_area_m2 = area_m2,
                .bare_soil_fraction = 1 - std.math.clamp(context.surface_precipitation.litter_cover_fraction[cell], 0, 1),
                .time_fraction = 1,
                .surface_silt_megagrams_per_megagram = silt_fraction,
                .surface_clay_megagrams_per_megagram = clay_fraction,
            },
            context.runscript.rainfall_impact_parameters,
        );
        context.surface_precipitation.rainfall_impact_energy_j[cell] = impact.incremental_energy_j;
        context.surface_precipitation.cumulative_rainfall_impact_energy_j[cell] = impact.cumulative_energy_j;
        context.surface_precipitation.saturated_hydraulic_conductivity_multiplier[cell] = impact.saturated_conductivity_multiplier;
        context.soil_solver_properties.rainfall_conductivity_multiplier[top_layer] = impact.saturated_conductivity_multiplier;
    }
    var runoff_parameters = context.runscript.surface_runoff_parameters;
    runoff_parameters.ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3;
    try ecosys.surface_runoff.routeWithSurfaceBoundary(
        context.surface_runoff,
        context.config.lon_count,
        context.config.lat_count,
        context.terrain_hydrology,
        context.canopy_cell_area_m2,
        context.surface_precipitation.litter_water_m3,
        context.surface_litter_ice_m3,
        context.surface_precipitation.litter_water_capacity_m3,
        context.lateral_connection_mode_by_cell,
        .{
            .north = context.surface_runoff_boundary_fraction_by_direction[0],
            .east = context.surface_runoff_boundary_fraction_by_direction[1],
            .south = context.surface_runoff_boundary_fraction_by_direction[2],
            .west = context.surface_runoff_boundary_fraction_by_direction[3],
        },
        runoff_parameters,
        .{
            .soil_layer_count = context.config.soil_layers,
            .bulk_density_megagrams_per_m3 = context.soil_solver_properties.bulk_density_megagrams_per_m3,
            .layer_bottom_depth_m = context.soil_solver_properties.layer_bottom_depth_m,
            .layer_thickness_m = context.soil_solver_properties.layer_thickness_m,
            .natural_water_table_depth_m = context.soil_boundary_topology.natural_water_table_depth_m,
        },
        .{
            .temperature_k = context.grid.surface_temperature_k,
            .heat_capacity_megajoules_per_k = context.surface_heat_capacity_megajoules_per_k,
            .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        },
    );
    const aqueous_amount_count = try std.math.mul(
        usize,
        context.grid.cell_count,
        ecosys.surface_aqueous_runoff_transport.species_count,
    );
    const aqueous_boundary_species = try context.allocator.alloc(f64, aqueous_amount_count);
    defer context.allocator.free(aqueous_boundary_species);
    const aqueous_boundary_components = try context.allocator.alloc(
        ecosys.surface_aqueous_runoff_transport.Components,
        context.grid.cell_count,
    );
    defer context.allocator.free(aqueous_boundary_components);
    const aqueous_intercell_debit = try context.allocator.alloc(
        ecosys.surface_aqueous_runoff_transport.Components,
        context.grid.cell_count,
    );
    defer context.allocator.free(aqueous_intercell_debit);
    const aqueous_intercell_credit = try context.allocator.alloc(
        ecosys.surface_aqueous_runoff_transport.Components,
        context.grid.cell_count,
    );
    defer context.allocator.free(aqueous_intercell_credit);
    const dissolved_nitrogen_export = try context.allocator.alloc(f64, context.grid.cell_count);
    defer context.allocator.free(dissolved_nitrogen_export);
    const dissolved_hydrogen_export = try context.allocator.alloc(f64, context.grid.cell_count);
    defer context.allocator.free(dissolved_hydrogen_export);
    const litter_salt_ion_export = try context.allocator.alloc(f64, context.grid.cell_count);
    defer context.allocator.free(litter_salt_ion_export);
    const dedicated_intercell_debit = try context.allocator.alloc(
        ecosys.surface_aqueous_runoff_transport.ElementMass,
        context.grid.cell_count,
    );
    defer context.allocator.free(dedicated_intercell_debit);
    const dedicated_intercell_credit = try context.allocator.alloc(
        ecosys.surface_aqueous_runoff_transport.ElementMass,
        context.grid.cell_count,
    );
    defer context.allocator.free(dedicated_intercell_credit);
    const runoff_boundary_activity = try context.allocator.alloc(
        ecosys.hourly_cell_conservation.BoundaryActivity,
        context.grid.cell_count,
    );
    defer context.allocator.free(runoff_boundary_activity);
    const runoff_directions: ecosys.surface_aqueous_runoff_transport.Directions = .{
        .east_m3 = context.surface_runoff.east_runoff_m3_per_step,
        .west_m3 = context.surface_runoff.west_runoff_m3_per_step,
        .south_m3 = context.surface_runoff.south_runoff_m3_per_step,
        .north_m3 = context.surface_runoff.north_runoff_m3_per_step,
    };
    // REDIST:4318-4330 rebuilds litter capacity after all SOC changes and
    // books HFLXO=dVHCP*T. TRNSFR runoff changes DOC and acetate after the
    // earlier biology/interface rebases, so it needs its own disjoint span.
    // Capture after water/heat routing: aqueous transport holds T fixed.
    const runoff_organic_heat_rebase = try context.allocator.alloc(f64, context.grid.cell_count);
    defer context.allocator.free(runoff_organic_heat_rebase);
    for (runoff_organic_heat_rebase, 0..) |*carbon, cell|
        carbon.* = try context.surface_organic.totalCarbon_g_c(cell);
    try ecosys.surface_aqueous_runoff_transport.advanceTransaction(
        context.allocator,
        .{
            .chemistry = context.surface_litter_chemistry,
            .nitrite_g_n = context.surface_denitrification.nitrite_g_n,
            .aqueous = context.surface_solute_transport,
            .organic = context.surface_organic,
            .gas = context.litter_gas_transport,
        },
        context.config.lon_count,
        context.config.lat_count,
        context.surface_precipitation.litter_water_m3,
        context.surface_runoff.water_change_m3,
        runoff_directions,
        1,
        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        12.0,
        .{
            .inorganic_nitrogen_export_g_n_by_cell = context.surface_inorganic_nitrogen_export_g_n_per_h,
            .inorganic_phosphorus_export_g_p_by_cell = context.surface_inorganic_phosphorus_export_g_p_per_h,
            .dissolved_organic_carbon_export_g_c_by_cell = context.surface_organic_carbon_export_g_c_per_h,
            .dissolved_organic_nitrogen_export_g_n_by_cell = context.surface_organic_nitrogen_export_g_n_per_h,
            .dissolved_organic_phosphorus_export_g_p_by_cell = context.surface_organic_phosphorus_export_g_p_per_h,
            .inorganic_carbon_export_g_c_by_cell = context.surface_inorganic_carbon_export_g_c_per_h,
            .dissolved_oxygen_export_g_o_by_cell = context.surface_dissolved_oxygen_export_g_o_per_h,
            .dissolved_nitrogen_export_g_n_by_cell = dissolved_nitrogen_export,
            .dissolved_hydrogen_export_g_h_by_cell = dissolved_hydrogen_export,
            .litter_salt_ion_export_mol_by_cell = litter_salt_ion_export,
            .aqueous_boundary_export_mol_by_cell_species = aqueous_boundary_species,
            .aqueous_boundary_components_by_cell = aqueous_boundary_components,
            .aqueous_intercell_debit_components_by_cell = aqueous_intercell_debit,
            .aqueous_intercell_credit_components_by_cell = aqueous_intercell_credit,
            .dedicated_intercell_debit_by_cell = dedicated_intercell_debit,
            .dedicated_intercell_credit_by_cell = dedicated_intercell_credit,
        },
    );
    try ecosys.redist_daily_litter_salt_inventory.accumulateAcceptedBoundary(
        context.daily_heat_ledger.ionic_outflow_mol,
        litter_salt_ion_export,
    );
    var runoff_organic_heat_rebase_total: f64 = 0;
    for (runoff_organic_heat_rebase, 0..) |*heat, cell| {
        heat.* = try ecosys.surface_litter_organic_heat_rebase.organicCarbonRebaseHeatMegajoules(
            heat.*,
            try context.surface_organic.totalCarbon_g_c(cell),
            context.grid.surface_temperature_k[cell],
            context.runscript.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
        );
        runoff_organic_heat_rebase_total += heat.*;
        if (!std.math.isFinite(runoff_organic_heat_rebase_total))
            return error.NonFiniteSurfaceLitterHeatRebase;
    }
    // This source-derived capacity/reference term is separate from water's
    // advected HQR and from numerical residuals. Publish it once to each
    // conservation scope inside the enclosing rollback-owned hourly attempt.
    try context.hourly_cell_boundary_ledger.accumulateSignedInternalHeat(runoff_organic_heat_rebase);
    try ecosys.layer_local_conservation.accumulateSurfaceOrganicHeatRebase(
        context.hourly_layer_boundary_ledger,
        runoff_organic_heat_rebase,
    );
    try context.landscape_boundary_ledger.accumulateAcceptedSignedInternalHeat(runoff_organic_heat_rebase_total);
    try context.landscape_boundary_ledger.accumulateAcceptedSurfaceDissolvedNitrogenHydrogenRunoff(
        dissolved_nitrogen_export,
        dissolved_hydrogen_export,
    );
    for (0..context.grid.cell_count) |cell| {
        const boundary = aqueous_boundary_components[cell];
        const debit = aqueous_intercell_debit[cell];
        const credit = aqueous_intercell_credit[cell];
        const dedicated_debit = dedicated_intercell_debit[cell];
        const dedicated_credit = dedicated_intercell_credit[cell];
        var outgoing_water_m3: f64 = 0;
        inline for (.{
            runoff_directions.east_m3[cell],
            runoff_directions.west_m3[cell],
            runoff_directions.south_m3[cell],
            runoff_directions.north_m3[cell],
        }) |value| outgoing_water_m3 += value;
        const incoming_water_m3 = context.surface_runoff.water_change_m3[cell] + outgoing_water_m3;
        if (!std.math.isFinite(incoming_water_m3) or incoming_water_m3 < 0)
            return error.InvalidSurfaceRunoffCellBoundaryActivity;
        var activity = try ecosys.hourly_cell_conservation.surfaceRunoffWaterHeatActivity(
            incoming_water_m3,
            outgoing_water_m3,
            context.surface_runoff.incoming_runoff_heat_megajoules_per_step[cell],
            context.surface_runoff.outgoing_runoff_heat_megajoules_per_step[cell],
        );
        activity = try ecosys.hourly_cell_conservation.addActivities(activity, .{
            .carbon_input_g = 12.0 * credit.carbon_mol + dedicated_credit.carbon_g,
            .carbon_output_g = 12.0 * debit.carbon_mol + dedicated_debit.carbon_g +
                context.surface_inorganic_carbon_export_g_c_per_h[cell] +
                context.surface_organic_carbon_export_g_c_per_h[cell],
            .nitrogen_input_g = dedicated_credit.nitrogen_g,
            .nitrogen_output_g = context.surface_inorganic_nitrogen_export_g_n_per_h[cell] +
                context.surface_organic_nitrogen_export_g_n_per_h[cell] +
                dissolved_nitrogen_export[cell] + dedicated_debit.nitrogen_g,
            .phosphorus_input_g = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol * credit.phosphorus_mol + dedicated_credit.phosphorus_g,
            .phosphorus_output_g = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol * debit.phosphorus_mol +
                context.surface_inorganic_phosphorus_export_g_p_per_h[cell] +
                context.surface_organic_phosphorus_export_g_p_per_h[cell] + dedicated_debit.phosphorus_g,
            .oxygen_input_g = dedicated_credit.oxygen_g,
            .oxygen_output_g = context.surface_dissolved_oxygen_export_g_o_per_h[cell] + dedicated_debit.oxygen_g,
            .hydrogen_input_g = dedicated_credit.hydrogen_g,
            .hydrogen_output_g = dissolved_hydrogen_export[cell] + dedicated_debit.hydrogen_g,
            .aluminum_input_mol = credit.aluminum_mol,
            .aluminum_output_mol = debit.aluminum_mol + boundary.aluminum_mol,
            .iron_input_mol = credit.iron_mol,
            .iron_output_mol = debit.iron_mol + boundary.iron_mol,
            .calcium_input_mol = credit.calcium_mol,
            .calcium_output_mol = debit.calcium_mol + boundary.calcium_mol,
            .magnesium_input_mol = credit.magnesium_mol,
            .magnesium_output_mol = debit.magnesium_mol + boundary.magnesium_mol,
            .sodium_input_mol = credit.sodium_mol,
            .sodium_output_mol = debit.sodium_mol + boundary.sodium_mol,
            .potassium_input_mol = credit.potassium_mol,
            .potassium_output_mol = debit.potassium_mol + boundary.potassium_mol,
            .sulfur_input_mol = credit.sulfur_mol,
            .sulfur_output_mol = debit.sulfur_mol + boundary.sulfur_mol,
            .chloride_input_mol = credit.chloride_mol,
            .chloride_output_mol = debit.chloride_mol + boundary.chloride_mol,
            .silicon_input_mol = credit.silicon_mol,
            .silicon_output_mol = debit.silicon_mol + boundary.silicon_mol,
        });
        runoff_boundary_activity[cell] = activity;
    }
    try context.hourly_cell_boundary_ledger.accumulateCells(runoff_boundary_activity);
    try ecosys.layer_local_conservation.accumulateSurfaceRunoffActivity(
        context.hourly_layer_boundary_ledger,
        runoff_boundary_activity,
    );
    var exported_runoff_heat_megajoules: f64 = 0;
    for (context.surface_runoff.exported_heat_megajoules) |heat| {
        if (!std.math.isFinite(heat) or heat < 0)
            return error.InvalidSurfaceRunoffBoundaryHeat;
        exported_runoff_heat_megajoules += heat;
        if (!std.math.isFinite(exported_runoff_heat_megajoules))
            return error.InvalidSurfaceRunoffBoundaryHeat;
    }
    try context.landscape_boundary_ledger.accumulateAccepted(.{
        .heat_output_megajoules = exported_runoff_heat_megajoules,
    });
    if (diagnostic_first_hour) {
        const heat_megajoules = (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules;
        std.log.debug("heat stage: surface_runoff_and_dissolved_gas hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, heat_megajoules - diagnostic_previous_heat_megajoules });
        diagnostic_previous_heat_megajoules = heat_megajoules;
    }
    if (diagnostic_first_hour) {
        const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
        std.log.debug("nitrogen stage: surface_runoff_transport delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
        diagnostic_previous_n_g = current_n_g;
        const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
        std.log.info("phosphorus stage: surface_runoff_transport delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
        try diagnostics.logPhosphorusRepresentation(context, "after_surface_runoff_transport");
        diagnostic_previous_p_g = current_p_g;
    }
    const erosion_mineral_geometry: ecosys.surface_pond_particulate_settling.MineralColumnGeometry = .{
        .cell_count = context.grid.cell_count,
        .soil_layer_capacity = context.grid.soil_layer_capacity,
        .surface_soil_layer_by_cell = context.soil_geometry.first_active_layer,
        .active_soil_layer_count_by_cell = context.soil_geometry.active_layer_count,
        .soil_bulk_density_megagrams_per_m3 = context.soil_solver_properties.bulk_density_megagrams_per_m3,
        .matrix_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3,
    };
    for (0..context.grid.cell_count) |cell| {
        // Open-water layers remain active in hydrology and settling, but the
        // erosion source equations require the first actual mineral carrier.
        const mineral_local = try ecosys.surface_pond_particulate_settling.firstMineralLayer(
            erosion_mineral_geometry,
            cell,
        );
        const top_layer = cell * context.grid.soil_layer_capacity + mineral_local;
        const sand_megagrams = context.soil_solver_properties.sand_mass_megagrams[top_layer];
        const silt_megagrams = context.soil_solver_properties.silt_mass_megagrams[top_layer];
        const clay_megagrams = context.soil_solver_properties.clay_mass_megagrams[top_layer];
        const total_organic_carbon_g = try context.soil_organic.totalCarbon_g_c(top_layer);
        // `hour1.f:2934--2935` splits total SOM into a plant-residue part
        // `CORRM` and the remainder `CORGH=CORGM-CORRM` (`2953`). Only CORGH
        // carries the 10 um humus diameter; residue carries 100 um (`2955--2956`)
        // and enters DETS with the opposite sign (`2988`). Passing residue=0 and
        // humus=CORGM leaves cohesion and particle density correct (both use the
        // sum) but understates D50 by 90*CORRM and overstates rainfall
        // detachability by 2.5e-6*CORRM.
        const residue_organic_carbon_g =
            try residueCarbonAtLayerG(context.soil_organic, top_layer);
        const minimum_surface_mineral_mass_megagrams =
            try context.surface_erosion.ensureMinimumSurfaceMineralMass(
                cell,
                sand_megagrams,
                silt_megagrams,
                clay_megagrams,
            );
        const canonical_matrix_soil_mass_megagrams =
            context.soil_solver_properties.matrix_bulk_volume_m3[top_layer] *
            context.soil_solver_properties.bulk_density_megagrams_per_m3[top_layer];
        const source_surface = try ecosys.soil_erosion.deriveSourceShapedSurface(.{
            .canonical_matrix_soil_mass_megagrams = canonical_matrix_soil_mass_megagrams,
            .minimum_surface_mineral_mass_megagrams = minimum_surface_mineral_mass_megagrams,
            .sand_megagrams = sand_megagrams,
            .silt_megagrams = silt_megagrams,
            .clay_megagrams = clay_megagrams,
            .total_organic_carbon_g = total_organic_carbon_g,
            .residue_organic_carbon_g = residue_organic_carbon_g,
        });
        // HOUR1 rebuilds BKVLNU from accepted geometry and immutable BKVLNM
        // before every erosion solve; the prior routed value is not a carrier.
        context.surface_erosion.surface_soil_mass_megagrams[cell] =
            source_surface.surface_soil_mass_megagrams;
        var root_length_density_m_per_m3: f64 = 0;
        if (context.plant_roots.*) |*roots| if (context.plant_water_workspace.*) |*workspace| {
            for (0..context.config.plant_populations) |species| {
                const plant = cell * context.config.plant_populations + species;
                for (0..context.root_metabolism_plant_parameters[plant].biologicalDomainCount()) |domain| {
                    root_length_density_m_per_m3 += roots.root_length_density_m_per_m3[try roots.layerIndex(plant, domain, 0)] * workspace.plant_population_count[plant] / context.canopy_cell_area_m2[cell];
                }
            }
        };
        const erosion_properties = try ecosys.soil_erosion.deriveSurfaceProperties(
            .{ .sand_mass_fraction = source_surface.sand_mass_fraction, .silt_mass_fraction = source_surface.silt_mass_fraction, .clay_mass_fraction = source_surface.clay_mass_fraction, .humus_mass_fraction = source_surface.humus_mass_fraction, .residue_mass_fraction = source_surface.residue_mass_fraction, .root_length_density_m_per_m3 = root_length_density_m_per_m3, .surface_temperature_c = context.grid.surface_temperature_k[cell] - 273.15 },
            .{
                .reference_water_viscosity_megagrams_per_m_s = context.runscript.soil_process_parameters.reference_water_viscosity_megagrams_per_m_s,
                .viscosity_temperature_intercept = context.runscript.soil_process_parameters.water_viscosity_temperature_intercept,
                .viscosity_temperature_coefficient_per_c = context.runscript.soil_process_parameters.water_viscosity_temperature_coefficient_per_c,
            },
        );
        const soil_mass_megagrams = canonical_matrix_soil_mass_megagrams;
        context.surface_soil_mass_at_erosion_start_megagrams[cell] = context.surface_erosion.surface_soil_mass_megagrams[cell];
        const local_solve =
            try ecosys.soil_erosion.calculateConvergedHourlyLocalStep(.{
                .erosion_enabled = context.site_by_cell[cell].erosionEnabled(),
                .surface_soil_bulk_density_megagrams_per_m3 = context.soil_solver_properties.bulk_density_megagrams_per_m3[top_layer],
                .surface_soil_mass_megagrams = context.surface_erosion.surface_soil_mass_megagrams[cell],
                .surface_soil_water_m3 = context.grid.matrix_liquid_water_m3[top_layer],
                .surface_soil_pore_volume_m3 = context.grid.matrix_pore_capacity_m3[top_layer],
                .excess_surface_water_m3 = context.surface_runoff.excess_surface_water_m3[cell],
                .excess_surface_ice_m3 = context.surface_runoff.excess_surface_ice_m3[cell],
                .surface_ponding_capacity_m3 = blk: {
                    const retention_m3 = context.runscript.surface_runoff_parameters.ground_surface_retention_m3_per_m2 * context.canopy_cell_area_m2[cell];
                    break :blk @max(context.config.physical_tolerance.waterVolume(retention_m3), retention_m3);
                },
                .sediment_in_surface_water_megagrams = context.surface_erosion.surface_sediment_megagrams[cell],
                .rainfall_kinetic_energy_j = context.surface_precipitation.rainfall_impact_energy_j[cell],
                .soil_rainfall_detachability_g_per_j = erosion_properties.rainfall_detachability_g_per_j,
                .soil_runoff_detachability = erosion_properties.runoff_detachability,
                .sediment_settling_velocity_m_per_h = erosion_properties.settling_velocity_m_per_h,
                .grid_cell_area_m2 = context.canopy_cell_area_m2[cell],
                .soil_matrix_fraction = std.math.clamp(context.soil_solver_properties.matrix_bulk_volume_m3[top_layer] / context.soil_solver_properties.layer_volume_m3[top_layer], 0, 1),
                .snow_free_fraction = 1 - std.math.clamp(context.surface_precipitation.snow_cover_fraction[cell], 0, 1),
                .runoff_velocity_m_per_s = context.surface_runoff.runoff_velocity_m_per_s[cell],
                .slope_sine = context.terrain_hydrology.slope_m_per_m[cell],
                .surface_particle_density_megagrams_per_m3 = erosion_properties.particle_density_megagrams_per_m3,
                .transport_capacity_coefficient = erosion_properties.transport_capacity_coefficient,
                .transport_capacity_exponent = erosion_properties.transport_capacity_exponent,
                .maximum_erodible_soil_fraction_per_step = 1,
                .water_transport_timestep_h = 1,
                .negligible_volume_m3 = context.runscript.surface_runoff_parameters.negligible_water_m3,
                .negligible_mass_megagrams = context.config.physical_tolerance.soilMass(soil_mass_megagrams),
            }, .{
                .absolute_tolerance_megagrams = context.config.nonlinear_tolerance.soil_mass_megagrams,
                .relative_tolerance = context.config.nonlinear_tolerance.relative,
                .picard_relaxation = context.config.picard_relaxation,
                .max_iterations = context.iteration_limits.erosion_max_iterations,
            });
        const local = local_solve.local;
        context.surface_erosion.local_detachment_megagrams[cell] = local.net_detachment_megagrams;
        context.surface_erosion.transportable_sediment_megagrams[cell] = if (context.site_by_cell[cell].erosionEnabled())
            try ecosys.soil_erosion.calculateDownslopeTransport_megagrams(
                context.surface_erosion.surface_sediment_megagrams[cell],
                local.net_detachment_megagrams,
                context.surface_runoff.excess_surface_water_m3[cell],
                context.surface_runoff.total_runoff_m3_per_step[cell],
                context.soil_solver_properties.bulk_density_megagrams_per_m3[top_layer],
                context.runscript.surface_runoff_parameters.negligible_water_m3,
            )
        else
            0;
    }
    try group_sediment.routeSedimentAndErosion(
        context,
        .erosion_redist,
        hour_of_day,
        weather_header_by_cell,
        plant_calendar_by_cell,
        fertilizer_band_hour,
        gas_failure_report,
        solute_failure_report,
        diagnostic_first_hour,
        plant_calendar,
        snow_phase_change_report,
        snow_vapor_equilibrium_report,
        subsurface_irrigation_chemistry_parameters,
        &diagnostic_previous_heat_megajoules,
        &diagnostic_previous_n_g,
        &diagnostic_previous_p_g,
    );
}

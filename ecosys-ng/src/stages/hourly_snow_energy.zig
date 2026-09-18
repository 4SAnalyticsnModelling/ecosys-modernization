//! `hourly_science` declarations: snow energy.
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
const group_heat_water_solute = @import("hourly_heat_water_solute.zig");
const group_phenology_preparation = @import("hourly_phenology_preparation.zig");

const LivingCanopyPublication = struct {
    coupled: ?ecosys.canopy_coupled_convergence.OuterCoupledResult = null,
    inactive: ?ecosys.inactive_water_energy.Result = null,
    canopy_water_storage_m_per_m2: f64 = 0,
    /// UPTAKE TKQY after the previous-hour HCBFCY impulse.  The surface
    /// solve and the following canopy-air exchange must start from this same
    /// temperature; applying HCBFCY later as an air-solver lateral flux
    /// reverses the source order and hides the fire heat from TKCY.
    combustion_adjusted_canopy_air_temperature_k: ?f64 = null,
};

/// Solve complete living-canopy/root-water columns into transaction-local
/// staging. The executor partitions only horizontal grid cells; species and
/// every vertical root domain within one cell retain their source order.
noinline fn solveLivingCanopyCells(
    kernel_context: anytype,
    cells: []const usize,
    _: usize,
) !void {
    for (cells) |cell| try solveLivingCanopyCell(kernel_context, cell);
}

noinline fn solveLivingCanopyCell(kernel_context: anytype, cell: usize) !void {
    const context = kernel_context.context;
    const airflow = kernel_context.airflow;
    const surface_workspace = kernel_context.surface_workspace;
    const canopy = kernel_context.canopy;
    const retention = kernel_context.retention;
    const balance = kernel_context.balance;
    const water_workspace = kernel_context.water_workspace;
    const roots = kernel_context.roots;
    const staged_publication = kernel_context.staged_publication;
    const staged_canopy_potential = kernel_context.staged_canopy_potential;
    const staged_active = kernel_context.staged_active;
    const staged_balance = kernel_context.staged_balance;
    const staged_minimum_stomatal_resistance = kernel_context.staged_minimum_stomatal_resistance;
    const stomate_boundaries = kernel_context.stomate_boundaries;
    const roots_per_plant = kernel_context.roots_per_plant;

    var total_canopy_radiation_fraction: f64 = 0;
    for (0..context.config.plant_populations) |population| {
        const index = cell * context.config.plant_populations + population;
        total_canopy_radiation_fraction += retention.living_radiation_fraction[index] + retention.standing_dead_radiation_fraction[index];
    }
    const area_m2 = context.canopy_cell_area_m2[cell];
    const air_column_height_m = @max(5.0, context.surface_aerodynamics.wind_reference_height_m[cell]);
    const canopy_air_heat_capacity_megajoules_per_k = air_column_height_m * area_m2 * context.runscript.ground_air_parameters.volumetric_air_heat_capacity_megajoules_per_m3_k;
    for (0..context.config.plant_populations) |species| {
        const plant = cell * context.config.plant_populations + species;
        var leaf_and_petiole_carbon_g_c: f64 = 0;
        var stalk_carbon_g_c: f64 = 0;
        var stalk_surface_area_m2: f64 = 0;
        const branches = try canopy.branchRange(plant);
        for (branches.first..branches.end) |branch| {
            leaf_and_petiole_carbon_g_c += canopy.branch_leaf_carbon_g[branch] + canopy.branch_sheath_carbon_g[branch];
            stalk_carbon_g_c += canopy.branch_stalk_carbon_g[branch];
            const nodes = try canopy.nodeRange(branch);
            for (nodes.first..nodes.end) |node| {
                const samples = try canopy.sampleRange(node);
                for (samples.first..samples.end) |sample| stalk_surface_area_m2 += canopy.sample_stalk_area_m2[sample];
            }
        }
        const heat_initialization = try ecosys.water_heat_initialization.calculate(.{
            .foliar_water_retention_m3_per_h = retention.living_retention_m3_per_h[plant],
            .water_flux_timestep_h = 1,
            .current_canopy_water_m3 = @max(0, context.plants.canopy_water_storage_m_per_m2[plant] * area_m2),
            .previous_hydrologically_active_carbon_g_c = 0,
            .leaf_and_petiole_carbon_g_c = leaf_and_petiole_carbon_g_c,
            .stalk_carbon_g_c = stalk_carbon_g_c,
            .sapwood_thickness_m = 0.0025,
            .stalk_surface_area_m2 = stalk_surface_area_m2,
            .stalk_volume_per_carbon_m3_per_g_c = context.runscript.stalk_volume_m3_per_g_c,
            .canopy_total_water_potential_megapascal = context.plants.canopy_water_potential_megapascal[plant],
            .minimum_dry_matter_fraction = context.runscript.canopy_ammonia_exchange_parameters.minimum_canopy_dry_matter_fraction,
            .canopy_surface_water_m3 = retention.living_surface_water_m3[plant],
            .dry_carbon_heat_capacity_megajoules_per_m3_k = 2.496,
            .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
            .high_heat_capacity_threshold_megajoules_per_m2_k = 0.838e-3,
            .low_heat_capacity_threshold_megajoules_per_m2_k = 0.838e-4,
            .cell_area_m2 = area_m2,
            .current_canopy_temperature_k = context.plants.canopy_temperature_k[plant],
            .high_capacity_temperature_step_k = 0.125,
            .low_capacity_temperature_step_k = 0.025,
            .water_volume_per_carbon_scale_m3_per_g_c = 1.0e-6,
            .dry_matter_potential_numerator = context.runscript.canopy_ammonia_exchange_parameters.water_potential_dry_matter_increment,
            .dry_matter_potential_denominator_coefficient = context.runscript.canopy_ammonia_exchange_parameters.water_potential_denominator_per_megapascal,
            .dry_matter_potential_denominator_intercept = context.runscript.canopy_ammonia_exchange_parameters.water_potential_denominator_offset,
        });
        const radiation_fraction = retention.living_radiation_fraction[plant];
        if (!water_workspace.active[plant] or heat_initialization.wet_canopy_heat_capacity_megajoules_per_k <= heat_initialization.low_heat_capacity_threshold_megajoules_per_k or radiation_fraction <= 1.0e-12) {
            // UPTAKE 1480--1516: a small/inactive living canopy has
            // explicit hourly defaults; retaining planting-time TKC,
            // PSILT, and turgor here is not scientifically neutral.
            const snow_temperature_k = if (context.snow_depth_m[cell] > 0)
                context.snow_transport.temperature_k[cell * context.snow_transport.layer_capacity]
            else
                context.atmosphere.air_temperature_k[cell];
            const canopy_snow_depth_scale_m = @max(water_workspace.canopy_height_m[plant], context.snow_depth_m[cell]);
            const inactive_temperature_k = if (water_workspace.canopy_height_m[plant] >= context.snow_depth_m[cell] - context.config.physical_tolerance.length(canopy_snow_depth_scale_m))
                context.atmosphere.air_temperature_k[cell]
            else
                snow_temperature_k;
            const planting_layer = roots.planting_layer_by_plant[plant];
            if (planting_layer >= balance.soil_layer_count) return error.InvalidInactiveCanopyPlantingLayer;
            const inactive = try ecosys.inactive_water_energy.calculate(.{
                .intercepted_water_volume_m3 = retention.living_surface_water_m3[plant],
                .foliar_water_retention_m3_per_h = retention.living_retention_m3_per_h[plant],
                .water_timestep_h_per_step = 1,
                .canopy_height_m = water_workspace.canopy_height_m[plant],
                .snow_depth_m = context.snow_depth_m[cell],
                .depth_tolerance_m = context.config.physical_tolerance.length(canopy_snow_depth_scale_m),
                .ambient_air_temperature_k = context.atmosphere.air_temperature_k[cell],
                .snow_air_temperature_k = snow_temperature_k,
                .atmospheric_vapor_concentration_m3_per_m3 = try ecosys.ground_air_exchange.vaporVolumeFraction(context.atmosphere.vapor_pressure_kpa[cell], context.atmosphere.air_temperature_k[cell], context.runscript.ground_air_parameters),
                .emissivity = context.runscript.canopy_longwave_emissivity,
                .stefan_boltzmann_megajoules_per_m2_h_k4 = 2.04e-10,
                .canopy_radiation_fraction = radiation_fraction,
                .horizontal_cell_area_m2 = area_m2,
                .energy_timestep_h_per_step = 1,
                .root_reference_soil_total_water_potential_megapascal = context.soil_hourly_workspace.root_referenced_total_water_potential_megapascal[cell * balance.soil_layer_count + planting_layer],
                .minimum_dry_matter_fraction_g_c_per_g = context.runscript.canopy_ammonia_exchange_parameters.minimum_canopy_dry_matter_fraction,
                .canopy_nonstructural_carbon_g_per_g_c = canopy.plant_mobile_carbon_concentration_g_per_g[plant],
                .canopy_nonstructural_nitrogen_g_per_g_c = canopy.plant_mobile_nitrogen_concentration_g_per_g[plant],
                .canopy_nonstructural_phosphorus_g_per_g_c = canopy.plant_mobile_phosphorus_concentration_g_per_g[plant],
                .osmotic_potential_at_zero_total_megapascal = water_workspace.leaf_osmotic_potential_at_zero_total_megapascal[plant],
                .osmotic_temperature_k = inactive_temperature_k,
                .canopy_salt_concentration_mol_per_g_c = canopy.plant_salt_concentration_mol_per_g_c[plant],
                .turgor_response_shape_per_megapascal = context.plant_reproduction_controls.stomatal_turgor_shape[plant],
                .minimum_stomatal_resistance_h_per_m = staged_minimum_stomatal_resistance[plant],
                .cuticular_resistance_h_per_m = canopy.plant_cuticular_water_vapor_resistance_h_per_m[plant],
                .biome_boundary_resistance_h_per_m = context.surface_aerodynamics.isothermal_aerodynamic_resistance_h_per_m[cell],
                .active_canopy_carbon_g = heat_initialization.hydrologically_active_carbon_g_c,
                .stalk_volume_m3_per_g_c = context.runscript.stalk_volume_m3_per_g_c,
            });
            staged_canopy_potential[plant] = inactive.canopy_total_water_potential_megapascal;
            staged_publication[plant] = .{
                .inactive = inactive,
                .canopy_water_storage_m_per_m2 = context.plants.canopy_water_storage_m_per_m2[plant],
            };
            continue;
        }
        const canopy_share = if (total_canopy_radiation_fraction > 1.0e-12) radiation_fraction / total_canopy_radiation_fraction else 0;
        const fixed_terms = try ecosys.fixed_terms.calculate(.{
            .canopy_total_water_potential_megapascal = context.plants.canopy_water_potential_megapascal[plant],
            .absorbed_shortwave_radiation_megajoules_per_h = retention.living_absorbed_shortwave_megajoules_per_m2[plant] * area_m2,
            .heat_flux_timestep_h = 1,
            .canopy_emissivity = context.runscript.canopy_longwave_emissivity,
            .stefan_boltzmann_megajoules_per_h_m2_k4 = 2.04e-10,
            .absorbed_radiation_fraction = radiation_fraction,
            .cell_area_m2 = area_m2,
            .sky_longwave_radiation_megajoules_per_h = context.atmosphere.longwave_radiation_megajoules_per_m2[cell] * area_m2,
            .lateral_longwave_radiation_megajoules_per_step = 0,
            .canopy_radiation_share = canopy_share,
            .nonstructural_carbon_concentration_g_c_per_g_c = canopy.plant_mobile_carbon_concentration_g_per_g[plant],
            .nonstructural_nitrogen_concentration_g_n_per_g_c = canopy.plant_mobile_nitrogen_concentration_g_per_g[plant],
            .nonstructural_phosphorus_concentration_g_p_per_g_c = canopy.plant_mobile_phosphorus_concentration_g_per_g[plant],
            .osmotic_molar_mass_intercept_g_per_mol = 144,
            .osmotic_molar_mass_slope_g_per_mol = 840,
            .latent_boundary_conductance_m2_per_step = airflow.latent_boundary_numerator_m2_per_h[cell],
            .sensible_boundary_conductance_megajoules_per_m_k_step = airflow.sensible_boundary_numerator_megajoules_per_m_h_k[cell],
        });
        const substep = try ecosys.substep_initialization.calculate(.{
            .canopy_air_temperature_k = canopy.plant_canopy_aerodynamic_temperature_k[plant],
            .canopy_air_heat_capacity_megajoules_per_k = canopy_air_heat_capacity_megajoules_per_k,
            .negligible_canopy_air_heat_capacity_megajoules_per_k = context.config.physical_tolerance.heat(canopy_air_heat_capacity_megajoules_per_k * canopy.plant_canopy_aerodynamic_temperature_k[plant]) / @max(1.0, canopy.plant_canopy_aerodynamic_temperature_k[plant]),
            .canopy_radiation_share = canopy_share,
            .negligible_canopy_radiation_share = 1.0e-12,
            // UPTAKE 843--855 applies previous-hour HCBFCY to TKQY
            // before the TKCY/root-water convergence. This exact initializer
            // also retains the source heat-capacity and radiation-share gates.
            .previous_combustion_heat_megajoules_per_step = context.delayed_live_canopy_combustion_heat_megajoules[plant],
            .legacy_substep_multiplier = 1,
            .canopy_surface_water_m3 = retention.living_surface_water_m3[plant],
            .retained_foliar_water_m3_per_step = heat_initialization.retained_foliar_water_m3_per_step,
            .canopy_surface_temperature_k = context.plants.canopy_temperature_k[plant],
            .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        });
        var temperature_solver_options = context.canopy_temperature_solver_options;
        var water_depth_solver_options = context.canopy_water_depth_solver_options;
        var water_potential_solver_options = context.canopy_water_potential_solver_options;
        temperature_solver_options.max_iterations = context.iteration_limits.canopy_energy_water_max_iterations;
        water_depth_solver_options.max_iterations = context.iteration_limits.canopy_energy_water_max_iterations;
        water_potential_solver_options.max_iterations = context.iteration_limits.canopy_energy_water_max_iterations;
        const root_base = plant * roots_per_plant;
        const gravitational_offset = context.soil_hourly_workspace.gravitational_water_potential_mpa_per_m * 0.8 * water_workspace.canopy_height_m[plant];
        const coupled_fixed: ecosys.canopy_coupled_convergence.OuterCoupledFixedInputs = .{
            .canopy = .{
                .heat_initialization = heat_initialization,
                .substep = substep,
                .fixed_terms = fixed_terms,
                .ground_surface_temperature_k = context.grid.surface_temperature_k[cell],
                .absorbed_radiation_fraction = radiation_fraction,
                .atmospheric_temperature_k = context.atmosphere.air_temperature_k[cell],
                .bulk_richardson_coefficient_k = context.surface_aerodynamics.bulk_richardson_coefficient_k[cell],
                .biome_isothermal_boundary_resistance_h_per_m = context.surface_aerodynamics.isothermal_aerodynamic_resistance_h_per_m[cell],
                .aerodynamic_resistance_below_biome_h_per_m = airflow.resistance_below_biome_h_per_m[cell],
                .aerodynamic_resistance_below_species_h_per_m = airflow.resistance_below_species_h_per_m[plant],
                .latent_boundary_numerator_m2_per_h = airflow.latent_boundary_numerator_m2_per_h[cell],
                .sensible_boundary_numerator_megajoules_per_m_h_k = airflow.sensible_boundary_numerator_megajoules_per_m_h_k[cell],
                .sensible_surface_resistance_h_per_m = surface_workspace.sensible_surface_resistance_h_per_m[plant],
                .latent_surface_resistance_h_per_m = surface_workspace.latent_surface_resistance_h_per_m[plant],
                .canopy_air_vapor_fraction = surface_workspace.canopy_air_vapor_fraction[plant],
                .canopy_total_water_potential_megapascal = context.plants.canopy_water_potential_megapascal[plant],
                .minimum_dry_matter_fraction_g_c_per_g = context.runscript.canopy_ammonia_exchange_parameters.minimum_canopy_dry_matter_fraction,
                .canopy_water_mass_g = heat_initialization.hydrologically_active_carbon_g_c,
                .osmotic_potential_at_zero_total_megapascal = water_workspace.leaf_osmotic_potential_at_zero_total_megapascal[plant],
                .canopy_salt_concentration_mol_per_g_c = canopy.plant_salt_concentration_mol_per_g_c[plant],
                .minimum_stomatal_resistance_h_per_m = staged_minimum_stomatal_resistance[plant],
                .cuticular_resistance_h_per_m = canopy.plant_cuticular_water_vapor_resistance_h_per_m[plant],
                .stomatal_turgor_shape_per_megapascal = context.plant_reproduction_controls.stomatal_turgor_shape[plant],
            },
            .root = .{
                .soil_water_potential_megapascal = context.soil_hourly_workspace.root_referenced_total_water_potential_megapascal[cell * balance.soil_layer_count ..][0..balance.soil_layer_count],
                .root_conductance_m_per_h_megapascal = water_workspace.root_conductance_m_per_h_megapascal[root_base..][0..roots_per_plant],
                .maximum_uptake_m = water_workspace.maximum_uptake_m[root_base..][0..roots_per_plant],
                .maximum_release_m = water_workspace.maximum_release_m[root_base..][0..roots_per_plant],
                .active_layer_count = context.grid.active_soil_layer_count[cell],
                .layer_capacity = balance.soil_layer_count,
                .root_domain_count = balance.root_domain_count,
                .canopy_gravitational_offset_megapascal = gravitational_offset,
            },
            .canopy_water_capacitance_m_per_m2_megapascal = water_workspace.canopy_water_capacitance_m_per_m2_megapascal[plant],
            .cell_area_m2 = area_m2,
            .previous_canopy_water_potential_megapascal = context.plants.canopy_water_potential_megapascal[plant],
        };
        const coupled = try ecosys.canopy_coupled_convergence.solveOuterCoupled(coupled_fixed, .{
            .canopy_settings = .{
                .heat_flux_timestep_h = 1,
                .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                .minimum_temperature_k = context.runscript.minimum_surface_temperature_k,
                .maximum_temperature_k = context.runscript.maximum_surface_temperature_k,
                .surface_exchange_parameters = context.runscript.canopy_surface_exchange_parameters,
                .solver_options = temperature_solver_options,
            },
            .water_balance_settings = .{ .minimum_canopy_water_potential_megapascal = -100, .maximum_canopy_water_potential_megapascal = 0, .solver_options = water_depth_solver_options },
            .outer_solver_options = water_potential_solver_options,
            .stomate_final_pass = stomate_boundaries[plant],
        });
        staged_minimum_stomatal_resistance[plant] = coupled.final_minimum_stomatal_resistance_h_per_m;
        const transpiration_loss_m = try ecosys.canopy_coupled_convergence.netCanopyWaterOutflowDepthM(coupled.canopy.transpiration_m3_per_step, area_m2);
        const root_inputs: ecosys.plant_water_balance.SinglePlantWaterBalanceInputs = .{
            .soil_water_potential_megapascal = coupled_fixed.root.soil_water_potential_megapascal,
            .root_conductance_m_per_h_megapascal = coupled_fixed.root.root_conductance_m_per_h_megapascal,
            .maximum_uptake_m = coupled_fixed.root.maximum_uptake_m,
            .maximum_release_m = coupled_fixed.root.maximum_release_m,
            .previous_canopy_water_potential_megapascal = coupled_fixed.previous_canopy_water_potential_megapascal,
            .canopy_water_capacitance_m_per_m2_megapascal = coupled_fixed.canopy_water_capacitance_m_per_m2_megapascal,
            .transpiration_loss_m = transpiration_loss_m,
            .active_layer_count = coupled_fixed.root.active_layer_count,
            .layer_capacity = coupled_fixed.root.layer_capacity,
            .root_domain_count = coupled_fixed.root.root_domain_count,
            .canopy_gravitational_offset_megapascal = gravitational_offset,
            .settings = .{ .minimum_canopy_water_potential_megapascal = -100, .maximum_canopy_water_potential_megapascal = 0, .solver_options = water_depth_solver_options },
        };
        try ecosys.plant_water_balance.deriveSinglePlantRootUptake(root_inputs, coupled.canopy_total_water_potential_megapascal, staged_balance.root_water_uptake_m[root_base..][0..roots_per_plant]);
        context.stage_census.*.recordCurrent(.root_water_uptake);
        const next_storage = context.plants.canopy_water_storage_m_per_m2[plant] + water_workspace.canopy_water_capacitance_m_per_m2_megapascal[plant] * (coupled.canopy_total_water_potential_megapascal - context.plants.canopy_water_potential_megapascal[plant]);
        if (!std.math.isFinite(next_storage) or next_storage < 0) return error.InvalidCoupledCanopyWaterStorage;
        staged_canopy_potential[plant] = coupled.canopy_total_water_potential_megapascal;
        staged_active[plant] = true;
        staged_publication[plant] = .{
            .coupled = coupled,
            .canopy_water_storage_m_per_m2 = next_storage,
            .combustion_adjusted_canopy_air_temperature_k = substep.canopy_air_temperature_k,
        };
        staged_balance.transpiration_loss_m[plant] = transpiration_loss_m;
        staged_balance.total_root_water_uptake_m[plant] = coupled.water.total_root_water_uptake_m;
        staged_balance.water_balance_residual_m[plant] = coupled.water.residual_m;
        staged_balance.iteration_count[plant] = coupled.water.iterations;
        staged_balance.newton_raphson_step_count[plant] = coupled.water.newton_raphson_steps;
        staged_balance.picard_step_count[plant] = coupled.water.picard_steps;
    }
}

/// Publish previous-hour HCBFCY/HCBFDY only after both canopy energy paths
/// accepted.  Failed hourly attempts retain the delayed carriers through the
/// outer-hour snapshot; successful attempts consume them exactly once.
fn publishAcceptedCanopyCombustionHeat(context: anytype) !void {
    const plant_populations = context.config.plant_populations;
    if (plant_populations == 0) return error.InvalidCanopyCombustionPlantCount;
    const plant_count = try std.math.mul(usize, context.grid.cell_count, plant_populations);
    if (context.delayed_live_canopy_combustion_heat_megajoules.len != plant_count or
        context.delayed_standing_dead_combustion_heat_megajoules.len != plant_count)
        return error.CanopyCombustionHeatDimensionMismatch;
    const heat_by_cell = try context.allocator.alloc(f64, context.grid.cell_count);
    defer context.allocator.free(heat_by_cell);
    @memset(heat_by_cell, 0);
    var total_heat: f64 = 0;
    for (0..context.grid.cell_count) |cell| {
        const first = cell * plant_populations;
        for (first..first + plant_populations) |plant| {
            inline for (.{
                context.delayed_live_canopy_combustion_heat_megajoules[plant],
                context.delayed_standing_dead_combustion_heat_megajoules[plant],
            }) |heat| {
                if (!std.math.isFinite(heat) or heat < 0)
                    return error.InvalidCanopyCombustionHeat;
                heat_by_cell[cell] += heat;
                if (!std.math.isFinite(heat_by_cell[cell]))
                    return error.InvalidCanopyCombustionHeat;
            }
        }
        total_heat += heat_by_cell[cell];
        if (!std.math.isFinite(total_heat)) return error.InvalidCanopyCombustionHeat;
    }
    try context.hourly_cell_boundary_ledger.preflightSignedInternalHeat(heat_by_cell);
    try ecosys.layer_local_conservation.accumulateCanopyCombustionHeat(
        context.hourly_layer_boundary_ledger,
        plant_populations,
        context.delayed_live_canopy_combustion_heat_megajoules,
        context.delayed_standing_dead_combustion_heat_megajoules,
    );
    try context.landscape_boundary_ledger.accumulateAcceptedHeatTransformationTotals(total_heat, 0);
    try context.hourly_cell_boundary_ledger.accumulateSignedInternalHeat(heat_by_cell);
    @memset(context.delayed_live_canopy_combustion_heat_megajoules, 0);
    @memset(context.delayed_standing_dead_combustion_heat_megajoules, 0);
}

fn PostWatsubCanopyHook(
    comptime Context: type,
    comptime PlantCalendar: type,
) type {
    return struct {
        const Self = @This();

        context: Context,
        plant_calendar_by_cell: []const ecosys.plant_development.Calendar,
        plant_calendar: PlantCalendar,

        fn advance(raw: *anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(raw));
            // soil.f:162--175: HFUNC is an accepted-WATSUB downstream owner
            // and must publish before the same-hour STOMATE/UPTAKE solve.
            try group_phenology_preparation.preparePhenologyForCanopyEnergy(
                self.context,
                self.plant_calendar_by_cell,
                self.plant_calendar,
            );
            try advanceLivingCanopyAfterWatsub(self.context);
            try publishAcceptedCanopyCombustionHeat(self.context);
        }
    };
}

pub fn solveSnowSurfaceEnergyAndSoilTransport(
    context: anytype,
    hour_of_day: u8,
    weather_header_by_cell: []const ecosys.weather.Header,
    plant_calendar_by_cell: []const ecosys.plant_development.Calendar,
    fertilizer_band_hour: ecosys.fertilizer_band_phase_coordinator.HourToken,
    gas_failure_report: ?ecosys.soil_gas_transport_step.FailureReportRequest,
    solute_failure_report: ?ecosys.solute_failure_reporter.Request,
    diagnostic_first_hour: anytype,
    diagnostic_mineral_before_mol: anytype,
    diagnostic_relayer_phosphate_before: anytype,
    diagnostic_transport_ammonium_before: anytype,
    diagnostic_transport_before: anytype,
    plant_calendar: anytype,
    ground_air_geometry_balance: []const ecosys.ground_air_exchange.GeometryBalance,
    snow_phase_change_report: anytype,
    snow_vapor_equilibrium_report: anytype,
    diagnostic_previous_heat_megajoules_ptr: anytype,
    diagnostic_previous_n_g_ptr: anytype,
    diagnostic_previous_p_g_ptr: anytype,
    diagnostic_previous_p_owners_ptr: anytype,
) !void {
    var diagnostic_previous_heat_megajoules = diagnostic_previous_heat_megajoules_ptr.*;
    defer diagnostic_previous_heat_megajoules_ptr.* = diagnostic_previous_heat_megajoules;
    var diagnostic_previous_n_g = diagnostic_previous_n_g_ptr.*;
    defer diagnostic_previous_n_g_ptr.* = diagnostic_previous_n_g;
    var diagnostic_previous_p_g = diagnostic_previous_p_g_ptr.*;
    defer diagnostic_previous_p_g_ptr.* = diagnostic_previous_p_g;
    var diagnostic_previous_p_owners = diagnostic_previous_p_owners_ptr.*;
    defer diagnostic_previous_p_owners_ptr.* = diagnostic_previous_p_owners;
    if (context.canopy_exposure.*) |*exposure| {
        // HOUR1-002. `hour1.f` 4713--4779 sums `ARLSS` over leaf, stalk
        // (`ARSTK`), and standing dead (`ARSTD`), and `DO 145`/`DO 155` form
        // `FRADT` from the per-plant `FRADP`/`FRADQ` shares. Passing the
        // retention owner's fractions retires `canopy_exposure`'s own
        // leaf-area-only derivation, which omitted stalk and standing-dead area
        // and hard-coded the `0.65` extinction and `0.05` solar-angle gate that
        // are runtime controls. This RETIRES a producer rather than adding one:
        // `canopy_exposure.State` has exactly one writer before and after, and
        // what changes is which upstream quantity that writer reads.
        //
        // Ordering verified rather than assumed, since a producer/consumer
        // inversion is what blocks BIND-REDIST-ROGOX:
        // `canopy_precipitation_retention.refreshFromModel` publishes
        // `living_radiation_fraction`/`standing_dead_radiation_fraction` at
        // line 3509 of this file, in the same hourly pass and 265 lines before
        // this call site, so the values read here are current for this hour.
        var exposure_context: ecosys.canopy_exposure.ApplyContext = .{ .result = exposure, .structure = &context.canopy_structure.*.?, .interception = &context.canopy_interception.*.?, .ground_radiation = context.ground_radiation, .solar_angle_sine_by_cell = context.hourly_solar_angle_sine, .radiation_fractions = if (context.canopy_precipitation_retention.*) |*retention| .{
            .living_radiation_fraction = retention.living_radiation_fraction,
            .standing_dead_radiation_fraction = retention.standing_dead_radiation_fraction,
            .species_count = retention.species_count,
        } else null };
        try tile_kernels.runKernelAcrossSerialTiles(context, &exposure_context, ecosys.canopy_exposure.applyTile);
    }
    var surface_energy_context: ecosys.surface_energy.ApplyContext = .{ .result = context.surface_energy, .grid = context.grid, .atmosphere = context.atmosphere, .ground_radiation = context.ground_radiation, .snow_depth_m = context.snow_depth_m, .exposure = if (context.canopy_exposure.*) |*exposure| exposure else null, .settings = context.surface_energy_settings };
    try tile_kernels.runKernelAcrossSerialTiles(context, &surface_energy_context, ecosys.surface_energy.applyTile);
    const ice_heat_capacity_per_water_equivalent_m3_k =
        try ecosys.ice_units.heatCapacityPerWaterEquivalentM3K(
            context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
            context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
        );
    for (0..context.grid.cell_count) |cell| {
        const area_m2 = context.canopy_cell_area_m2[cell];
        if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidSurfaceFireCellArea;
        context.surface_combustion_heat_megajoules_per_m2[cell] = context.delayed_surface_combustion_heat_megajoules[cell] / area_m2;
        if (!std.math.isFinite(context.surface_combustion_heat_megajoules_per_m2[cell]) or context.surface_combustion_heat_megajoules_per_m2[cell] < 0) return error.NonFiniteSurfaceCombustionHeatSource;
    }
    for (0..context.grid.cell_count) |cell| {
        const vapor_water_equivalent_m3 = context.litter_gas_transport.water_vapor_mol[cell] * context.runscript.soil_gas_transport_parameters.water_molar_mass_g_per_mol / context.runscript.soil_gas_transport_parameters.water_density_g_per_m3;
        // SURFACE-HEAT-CAPACITY-STALE-WITHIN-HOUR-001: one owner for this
        // formula, which previously existed here, in the inventory, and
        // implicitly in the snowpack transfer's subtraction.
        context.surface_heat_capacity_megajoules_per_k[cell] = ecosys.surface_litter_geometry.heatCapacityMegajoulesPerK(
            context.runscript.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
            try context.surface_organic.totalCarbon_g_c(cell),
            context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
            context.surface_precipitation.litter_water_m3[cell],
            vapor_water_equivalent_m3,
            ice_heat_capacity_per_water_equivalent_m3_k,
            context.surface_litter_ice_m3[cell],
        ) catch return error.InvalidSurfaceHeatCapacity;
    }
    // Surface temperature, litter phase change, and combustion-heat
    // consumption are owned by the downstream accepted-substep transaction.
    // Canopy state below remains a read-only hourly forcing for that solve.
    if (context.canopy_airflow.*) |*airflow| if (context.detailed_canopy.*) |*canopy| if (context.canopy_precipitation_retention.*) |*retention| {
        try ecosys.plant_development.refreshCanopyHeight(canopy, context.development_canopy_height_m);
        for (0..context.grid.cell_count) |cell| {
            context.canopy_atmospheric_vapor_diffusivity_m2_per_h[cell] = context.runscript.soil_process_parameters.reference_water_vapor_diffusivity_m2_per_h * std.math.pow(f64, context.atmosphere.air_temperature_k[cell] / context.runscript.soil_process_parameters.vapor_diffusivity_reference_temperature_k, context.runscript.soil_process_parameters.vapor_diffusivity_temperature_exponent);
        }
        for (0..context.config.plant_populations * context.grid.cell_count) |plant| context.canopy_available_intercepted_water_m3[plant] = @max(0, retention.living_surface_water_m3[plant] + retention.living_retention_m3_per_h[plant]);
        var airflow_context: ecosys.canopy_airflow.ApplyContext = .{
            .state = airflow,
            .cell_area_m2 = context.canopy_cell_area_m2,
            .total_canopy_area_m2 = context.surface_total_canopy_area_m2,
            .biome_canopy_height_m = context.surface_canopy_height_m,
            .surface_roughness_height_m = context.canopy_surface_roughness_height_m,
            .species_canopy_height_m = context.development_canopy_height_m,
            .standing_dead_height_m = canopy.plant_standing_dead_height_m,
            .atmospheric_vapor_diffusivity_m2_per_h = context.canopy_atmospheric_vapor_diffusivity_m2_per_h,
            .atmospheric_temperature_k = context.atmosphere.air_temperature_k,
            .ground_air_temperature_k = context.ground_air.temperature_k,
            .species_canopy_air_temperature_k = canopy.plant_canopy_aerodynamic_temperature_k,
            .standing_dead_air_temperature_k = canopy.plant_standing_dead_aerodynamic_temperature_k,
            .bulk_richardson_coefficient_k = context.surface_aerodynamics.bulk_richardson_coefficient_k,
            .parameters = .{
                .minimum_richardson_number = context.runscript.canopy_surface_exchange_parameters.minimum_richardson_number,
                .maximum_richardson_number = context.runscript.canopy_surface_exchange_parameters.maximum_richardson_number,
                .richardson_resistance_multiplier = context.runscript.canopy_surface_exchange_parameters.richardson_resistance_multiplier,
                .minimum_canopy_resistance_h_per_m = context.runscript.canopy_minimum_resistance_h_per_m,
                .maximum_canopy_resistance_h_per_m = context.runscript.canopy_maximum_resistance_h_per_m,
                .canopy_drag_length_m = context.runscript.surface_gas_resistance_parameters.canopy_drag_length_m,
                .volumetric_air_heat_capacity_megajoules_per_m3_k = context.runscript.ground_air_parameters.volumetric_air_heat_capacity_megajoules_per_m3_k,
            },
        };
        try tile_kernels.runKernelAcrossSerialTiles(context, &airflow_context, ecosys.canopy_airflow.applyTile);
    };
    // The aerodynamic HOUR1 preparation above is WATSUB forcing. Living
    // STOMATE/UPTAKE is deliberately a separate post-WATSUB entry point.
    // Keeping this boundary explicit prevents a future source-order regression
    // from hiding inside the snow/surface-energy wrapper.
    const CanopyHook = PostWatsubCanopyHook(@TypeOf(context), @TypeOf(plant_calendar));
    var canopy_hook: CanopyHook = .{
        .context = context,
        .plant_calendar_by_cell = plant_calendar_by_cell,
        .plant_calendar = plant_calendar,
    };
    try group_heat_water_solute.solveSoilHeatWaterAndSoluteTransport(
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
        .{
            .context = @ptrCast(&canopy_hook),
            .advance = CanopyHook.advance,
        },
        ground_air_geometry_balance,
        snow_phase_change_report,
        snow_vapor_equilibrium_report,
        &diagnostic_previous_heat_megajoules,
        &diagnostic_previous_n_g,
        &diagnostic_previous_p_g,
        &diagnostic_previous_p_owners,
    );
}

/// Existing UPTAKE/STOMATE implementation, extracted unchanged so the hourly
/// orchestrator can invoke it after accepted WATSUB flux staging and NITRO.
pub fn advanceLivingCanopyAfterWatsub(context: anytype) !void {
    if (context.canopy_airflow.*) |*airflow| if (context.canopy_surface_exchange.*) |*exchange| if (context.canopy_surface_input_workspace.*) |*surface_workspace| if (context.detailed_canopy.*) |*canopy| if (context.canopy_precipitation_retention.*) |*retention| if (context.canopy_exposure.*) |*exposure| {
        const plant_count = context.grid.cell_count * context.config.plant_populations;
        const canopy_layers = if (context.canopy_layer_distribution.*) |*value| value else return error.MissingCanopyLayersForStomate;
        const canopy_optics = if (context.canopy_optics.*) |*value| value else return error.MissingCanopyOpticsForStomate;
        const plant_dormancy = if (context.plant_dormancy.*) |*value| value else return error.MissingDormancyForStomate;
        const branch_development = if (context.branch_development.*) |*value| value else return error.MissingBranchDevelopmentForStomate;
        const growth_stages = if (context.plant_growth_stages.*) |*value| value else return error.MissingGrowthStagesForStomate;
        const stomate_capacity_contexts = try context.allocator.alloc(
            ecosys.canopy_maximum_turgor_carboxylation.Context,
            plant_count,
        );
        defer context.allocator.free(stomate_capacity_contexts);
        const stomate_boundaries = try context.allocator.alloc(
            ecosys.canopy_coupled_convergence.StomateFinalPass,
            plant_count,
        );
        defer context.allocator.free(stomate_boundaries);
        const staged_minimum_stomatal_resistance = try context.allocator.alloc(f64, plant_count);
        defer context.allocator.free(staged_minimum_stomatal_resistance);
        // UPTAKE 466--474: the first STOMATE call precedes every living-canopy
        // energy/root-water solve. Build it into staged storage; a later plant
        // failure therefore cannot leak a partially updated RSMN array.
        for (0..plant_count) |plant| {
            const cell = plant / context.config.plant_populations;
            const canopy_co2_umol_per_mol = context.current_canopy_co2_umol_per_mol_by_cell[cell];
            const intercellular_fraction = context.canopy_biochemistry_parameters[plant].intercellular_to_atmospheric_co2_ratio;
            stomate_capacity_contexts[plant] = .{
                .canopy = canopy,
                .layers = canopy_layers,
                .interception = &context.canopy_interception.*.?,
                .optics = canopy_optics,
                .geometry = context.canopy_geometry,
                .parameters_by_plant = context.canopy_biochemistry_parameters,
                .c4_carbon_parameters = context.runscript.c4_carbon_parameters,
                .direct_incidence_fraction = context.direct_incidence_fraction,
                .atmospheric_co2_umol_per_mol_by_cell = context.current_canopy_co2_umol_per_mol_by_cell,
                .dormancy = plant_dormancy,
                .branch_development = branch_development,
                .growth_stages = growth_stages,
                .dormancy_parameters_by_plant = context.development_dormancy_parameters,
                .annual_termination_hours_without_grain_fill = context.runscript.root_metabolism_parameters.annual_termination_hours_without_grain_fill,
                .presence_threshold_g_per_plant = context.runscript.plant_pool_parameters.branch_structural_presence_g_per_plant,
                .plant = plant,
            };
            stomate_boundaries[plant] = .{
                .inputs = .{
                    .photosynthesis_active = context.hourly_solar_angle_sine[cell] > 0,
                    // Replaced at both boundaries by the current-TKC pure
                    // STOMATE producer below; never carry prior-hour GROSUB.
                    .canopy_co2_fixation_umol_per_s = 0,
                    .negligible_fixation_umol_per_s = 1.0e-12,
                    .canopy_radiation_fraction = retention.living_radiation_fraction[plant],
                    // Replaced from TKC by minimumStomatalResistanceAtTemperature.
                    .co2_concentration_difference_umol_per_m3 = 0,
                    .horizontal_cell_area_m2 = context.canopy_cell_area_m2[cell],
                    .seconds_per_hour = context.runscript.shoot_control_parameters.seconds_per_hour,
                    .cuticular_water_vapor_resistance_h_per_m = canopy.plant_cuticular_water_vapor_resistance_h_per_m[plant],
                    .co2_to_water_cuticular_resistance_ratio = context.runscript.shoot_control_parameters.co2_to_water_cuticular_resistance_ratio,
                    .minimum_co2_stomatal_resistance_h_per_m = 2.78e-3,
                    .co2_to_water_stomatal_resistance_ratio = 0.641,
                },
                .canopy_to_intercellular_co2_difference_umol_per_mol = canopy_co2_umol_per_mol * (1 - intercellular_fraction),
                .maximum_turgor_carboxylation = .{
                    .context = &stomate_capacity_contexts[plant],
                    .evaluate_fn = ecosys.canopy_maximum_turgor_carboxylation.evaluateOpaque,
                },
            };
            staged_minimum_stomatal_resistance[plant] =
                try ecosys.canopy_coupled_convergence.minimumStomatalResistanceAtTemperature(
                    stomate_boundaries[plant],
                    context.plants.canopy_temperature_k[plant],
                );
        }
        try surface_workspace.refresh(
            canopy.plant_canopy_aerodynamic_temperature_k,
            canopy.plant_canopy_aerodynamic_vapor_pressure_kpa,
            staged_minimum_stomatal_resistance,
            canopy.plant_cuticular_water_vapor_resistance_h_per_m,
            context.plant_reproduction_controls.stomatal_turgor_shape,
            canopy.plant_canopy_turgor_potential_megapascal,
            context.runscript.canopy_sensible_surface_resistance_h_per_m,
            context.runscript.canopy_latent_surface_resistance_h_per_m,
            context.runscript.canopy_surface_exchange_parameters,
        );
        // UPTAKE 572--1341: solve living-canopy surface temperature, osmotic/
        // turgor state, transpiration, and root water uptake as one staged
        // transaction. This replaces the former frozen-temperature surface
        // exchange above and the later independent root-water solve; trial
        // iterates never touch production state.
        const balance = if (context.plant_water_balance.*) |*value| value else return error.MissingPlantWaterBalanceForCoupledCanopy;
        const water_workspace = if (context.plant_water_workspace.*) |*value| value else return error.MissingPlantWaterWorkspaceForCoupledCanopy;
        const roots = if (context.plant_roots.*) |*value| value else return error.MissingPlantRootsForCoupledCanopy;
        const energy = if (context.canopy_energy.*) |*value| value else return error.MissingCanopyEnergyForCoupledCanopy;
        try ecosys.plant_water_balance.refreshCanopyWorkspace(water_workspace, canopy, context.plants, context.config.plant_populations);
        try ecosys.plant_water_balance.refreshRootWorkspace(water_workspace, roots, canopy, context.plants, context.grid, context.soil_solver_properties, context.config.plant_populations, context.root_biological_domain_count_by_plant, context.runscript.plant_geometry_parameters.root_volume_numerator_m3_per_g_c, context.runscript.plant_geometry_parameters.root_dry_matter_fraction, context.runscript.plant_geometry_parameters.root_pi, context.runscript.soil_geometry_parameters.minimum_layer_thickness_m, context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3, context.soil_hourly_workspace.frozen_hydraulic_impedance_exponent, context.soil_hourly_workspace.gravitational_water_potential_mpa_per_m, context.runscript.root_morphology_parameters);
        try water_workspace.refreshActive(context.config.soil_layers);

        const roots_per_plant = balance.root_domain_count * balance.soil_layer_count;
        const staged_publication = try context.allocator.alloc(LivingCanopyPublication, plant_count);
        defer context.allocator.free(staged_publication);
        @memset(staged_publication, .{});
        const staged_canopy_potential = try context.allocator.dupe(f64, context.plants.canopy_water_potential_megapascal);
        defer context.allocator.free(staged_canopy_potential);
        const staged_active = try context.allocator.alloc(bool, plant_count);
        defer context.allocator.free(staged_active);
        @memset(staged_active, false);
        var staged_balance = try ecosys.plant_water_balance.State.init(context.allocator, balance.cell_count, balance.species_count, balance.soil_layer_count);
        defer staged_balance.deinit();

        var living_canopy_grid_solve = .{
            .context = context,
            .airflow = airflow,
            .surface_workspace = surface_workspace,
            .canopy = canopy,
            .retention = retention,
            .balance = balance,
            .water_workspace = water_workspace,
            .roots = roots,
            .staged_publication = staged_publication,
            .staged_canopy_potential = staged_canopy_potential,
            .staged_active = staged_active,
            .staged_balance = &staged_balance,
            .staged_minimum_stomatal_resistance = staged_minimum_stomatal_resistance,
            .stomate_boundaries = stomate_boundaries,
            .roots_per_plant = roots_per_plant,
        };
        // Tile traversal remains serial. CpuExecutor partitions only the
        // disjoint horizontal grid cells of the currently active tile.
        try tile_kernels.runIndexedKernelAcrossSerialTiles(
            context,
            &living_canopy_grid_solve,
            solveLivingCanopyCells,
        );
        try ecosys.plant_water_balance.state_updateRootHydraulicsWithCanopyPotential(staged_balance, roots, context.grid, context.soil_hourly_workspace.root_referenced_total_water_potential_megapascal, staged_canopy_potential, staged_active, water_workspace.cell_area_m2, water_workspace.soil_resistance_mpa_h_per_m, water_workspace.root_resistance_mpa_h_per_m, water_workspace.leaf_osmotic_potential_at_zero_total_megapascal, context.root_biological_domain_count_by_plant);
        inline for (@typeInfo(ecosys.plant_water_balance.State).@"struct".fields) |field| if (field.type == []f64 or field.type == []u16) @memcpy(@field(balance, field.name), @field(staged_balance, field.name));
        // Publish RSMN only after every plant's source-mandated final pass and
        // the coupled root-hydraulics validation succeeded.
        @memcpy(canopy.plant_minimum_water_vapor_resistance_h_per_m, staged_minimum_stomatal_resistance);
        for (staged_publication, 0..) |publication, plant| {
            const cell = plant / context.config.plant_populations;
            if (publication.coupled) |coupled| {
                const result = coupled.canopy;
                const adjusted_air_temperature_k = publication.combustion_adjusted_canopy_air_temperature_k orelse
                    return error.MissingAcceptedCanopyAirTemperature;
                canopy.plant_canopy_aerodynamic_temperature_k[plant] = adjusted_air_temperature_k;
                // HCBFCY changes TKQY, not canopy-air water content. Preserve
                // the pre-impulse vapor volume fraction when reconstructing
                // the pressure carrier used by the downstream air solve.
                canopy.plant_canopy_aerodynamic_vapor_pressure_kpa[plant] =
                    surface_workspace.canopy_air_vapor_fraction[plant] * adjusted_air_temperature_k /
                    context.runscript.canopy_surface_exchange_parameters.saturation_vapor_prefactor_k;
                context.plants.canopy_temperature_k[plant] = result.canopy_surface_temperature_k;
                context.plants.canopy_water_potential_megapascal[plant] = coupled.canopy_total_water_potential_megapascal;
                context.plants.canopy_water_storage_m_per_m2[plant] = publication.canopy_water_storage_m_per_m2;
                canopy.plant_maximum_turgor_carboxylation_umol_per_s[plant] = coupled.final_maximum_turgor_carboxylation_umol_per_s;
                canopy.plant_canopy_osmotic_potential_megapascal[plant] = result.osmotic_water_potential_megapascal;
                canopy.plant_canopy_turgor_potential_megapascal[plant] = result.turgor_water_potential_megapascal;
                // TUPVC retains source EPCCM (surface transpiration plus the
                // internal capacity adjustment). The exchange owner is the
                // physical EPCCMX atmospheric flux used by uptake.f:1285.
                canopy.plant_transpiration_m3_per_h[plant] = result.transpiration_m3_per_step;
                surface_workspace.stomatal_resistance_h_per_m[plant] = result.stomatal_resistance_h_per_m;
                exchange.boundary_layer_resistance_h_per_m[plant] = result.boundary_layer_resistance_h_per_m;
                exchange.total_aerodynamic_resistance_h_per_m[plant] = result.total_aerodynamic_resistance_h_per_m;
                exchange.adjusted_surface_resistance_h_per_m[plant] = result.adjusted_surface_resistance_h_per_m;
                exchange.canopy_surface_vapor_fraction[plant] = result.canopy_surface_vapor_fraction;
                exchange.intercepted_water_change_m3_per_h[plant] = result.intercepted_water_change_m3_per_step;
                exchange.transpiration_m3_per_h[plant] = result.surface_transpiration_m3_per_step;
                exchange.latent_heat_flux_megajoules_per_h[plant] = result.latent_heat_flux_megajoules_per_step;
                exchange.sensible_heat_flux_megajoules_per_h[plant] = result.sensible_heat_flux_megajoules_per_step;
                exchange.vapor_sensible_heat_flux_megajoules_per_h[plant] = result.vapor_sensible_heat_flux_megajoules_per_step;
                energy.downward_sky_longwave_megajoules_per_m2[plant] = context.atmosphere.longwave_radiation_megajoules_per_m2[cell] * retention.living_radiation_fraction[plant];
                energy.emitted_sky_longwave_megajoules_per_m2[plant] = result.emitted_canopy_longwave_megajoules_per_step / context.canopy_cell_area_m2[cell];
                energy.net_longwave_megajoules_per_m2[plant] = result.net_canopy_longwave_megajoules_per_step / context.canopy_cell_area_m2[cell];
                energy.net_radiation_megajoules_per_m2[plant] = result.net_canopy_radiation_megajoules_per_step / context.canopy_cell_area_m2[cell];
            } else if (publication.inactive) |inactive| {
                context.plants.canopy_temperature_k[plant] = inactive.canopy_surface_temperature_k;
                context.plants.canopy_water_potential_megapascal[plant] = inactive.canopy_total_water_potential_megapascal;
                canopy.plant_canopy_aerodynamic_temperature_k[plant] = inactive.canopy_air_temperature_k;
                canopy.plant_canopy_aerodynamic_vapor_pressure_kpa[plant] = inactive.canopy_air_vapor_concentration_m3_per_m3 * inactive.canopy_air_temperature_k / context.runscript.canopy_surface_exchange_parameters.saturation_vapor_prefactor_k;
                canopy.plant_canopy_osmotic_potential_megapascal[plant] = inactive.canopy_osmotic_water_potential_megapascal;
                canopy.plant_canopy_turgor_potential_megapascal[plant] = inactive.canopy_turgor_water_potential_megapascal;
                canopy.plant_transpiration_m3_per_h[plant] = 0;
                surface_workspace.stomatal_resistance_h_per_m[plant] = inactive.stomatal_resistance_h_per_m;
                inline for (@typeInfo(ecosys.canopy_surface_exchange.State).@"struct".fields) |field| {
                    if (field.type == []f64) @field(exchange, field.name)[plant] = 0;
                }
                exchange.boundary_layer_resistance_h_per_m[plant] = inactive.aerodynamic_resistance_h_per_m;
                exchange.total_aerodynamic_resistance_h_per_m[plant] = inactive.aerodynamic_resistance_h_per_m;
                exchange.canopy_surface_vapor_fraction[plant] = inactive.canopy_air_vapor_concentration_m3_per_m3;
                inline for (@typeInfo(ecosys.canopy_energy.State).@"struct".fields) |field| {
                    if (field.type == []f64) @field(energy, field.name)[plant] = 0;
                }
                energy.emitted_sky_longwave_megajoules_per_m2[plant] = inactive.longwave_emission_megajoules_per_step / context.canopy_cell_area_m2[cell];
            } else {
                canopy.plant_transpiration_m3_per_h[plant] = 0;
                inline for (@typeInfo(ecosys.canopy_surface_exchange.State).@"struct".fields) |field| {
                    if (field.type == []f64) @field(exchange, field.name)[plant] = 0;
                }
                inline for (@typeInfo(ecosys.canopy_energy.State).@"struct".fields) |field| {
                    if (field.type == []f64) @field(energy, field.name)[plant] = 0;
                }
            }
        }
        if (context.standing_dead_surface_exchange.*) |*dead_exchange| {
            for (0..context.grid.cell_count) |cell| for (0..context.config.plant_populations) |species| {
                const plant = cell * context.config.plant_populations + species;
                context.standing_dead_evaporation_m3_per_h[plant] = 0;
                dead_exchange.intercepted_water_change_m3_per_h[plant] = 0;
                dead_exchange.net_radiation_megajoules_per_h[plant] = 0;
                dead_exchange.sensible_heat_flux_megajoules_per_h[plant] = 0;
                dead_exchange.latent_heat_flux_megajoules_per_h[plant] = 0;
                dead_exchange.vapor_sensible_heat_flux_megajoules_per_h[plant] = 0;
                dead_exchange.storage_heat_flux_megajoules_per_h[plant] = 0;
                const standing_dead_present =
                    retention.standing_dead_radiation_fraction[plant] > 1.0e-12 and
                    canopy.plant_standing_dead_height_m[plant] > 0;
                if (!standing_dead_present) {
                    const ambient_vapor_fraction =
                        try ecosys.ground_air_exchange.vaporVolumeFraction(
                            context.atmosphere.vapor_pressure_kpa[cell],
                            context.atmosphere.air_temperature_k[cell],
                            context.runscript.ground_air_parameters,
                        );
                    const fallback = try ecosys.absent_standing_dead_canopy_state.apply(
                        false,
                        std.mem.zeroes(ecosys.absent_standing_dead_canopy_state.State),
                        .{
                            .intercepted_water_m3 = 0,
                            .intercepted_water_rate_m3_per_h = 0,
                            .timestep_h = 0,
                            .ambient_air_temperature_k = context.atmosphere.air_temperature_k[cell],
                            .ambient_vapor_volume_fraction = ambient_vapor_fraction,
                            .canopy_height_m = canopy.plant_standing_dead_height_m[plant],
                            .snow_surface_depth_m = context.snow_depth_m[cell],
                            .depth_tolerance_m = 1.0e-12,
                            .topsoil_temperature_k = context.grid.soil_temperature_k[cell * context.grid.soil_layer_capacity],
                        },
                    );
                    canopy.plant_standing_dead_aerodynamic_temperature_k[plant] =
                        fallback.canopy_air_temperature_k;
                    canopy.plant_standing_dead_aerodynamic_vapor_pressure_kpa[plant] =
                        context.atmosphere.vapor_pressure_kpa[cell];
                    canopy.plant_standing_dead_surface_temperature_k[plant] =
                        fallback.canopy_surface_temperature_k;
                    continue;
                }
                var air_temperature_k = canopy.plant_standing_dead_aerodynamic_temperature_k[plant];
                const air_vapor_fraction =
                    canopy.plant_standing_dead_aerodynamic_vapor_pressure_kpa[plant] *
                    context.runscript.canopy_surface_exchange_parameters.saturation_vapor_prefactor_k /
                    air_temperature_k;
                var exchange_inputs: ecosys.standing_dead_surface_exchange.Inputs = .{
                    .atmospheric_temperature_k = context.atmosphere.air_temperature_k[cell],
                    .standing_dead_air_temperature_k = air_temperature_k,
                    .standing_dead_surface_temperature_k = canopy.plant_standing_dead_surface_temperature_k[plant],
                    .standing_dead_air_vapor_fraction = air_vapor_fraction,
                    .bulk_richardson_coefficient_k = context.surface_aerodynamics.bulk_richardson_coefficient_k[cell],
                    .biome_isothermal_boundary_resistance_h_per_m = context.surface_aerodynamics.isothermal_aerodynamic_resistance_h_per_m[cell],
                    .aerodynamic_resistance_below_biome_h_per_m = airflow.resistance_below_biome_h_per_m[cell],
                    .aerodynamic_resistance_below_standing_dead_h_per_m = airflow.resistance_below_standing_dead_h_per_m[plant],
                    .standing_dead_radiation_fraction = retention.standing_dead_radiation_fraction[plant],
                    .latent_boundary_numerator_m2_per_h = airflow.latent_boundary_numerator_m2_per_h[cell],
                    .sensible_boundary_numerator_megajoules_per_m_h_k = airflow.sensible_boundary_numerator_megajoules_per_m_h_k[cell],
                    .sensible_surface_resistance_h_per_m = context.runscript.canopy_sensible_surface_resistance_h_per_m,
                    .latent_surface_resistance_h_per_m = context.runscript.canopy_latent_surface_resistance_h_per_m,
                    .intercepted_water_volume_m3 = @max(0, retention.standing_dead_surface_water_m3[plant] + retention.standing_dead_retention_m3_per_h[plant]),
                };
                const dead_parameters: ecosys.standing_dead_surface_exchange.Parameters = .{
                    .minimum_richardson_number = context.runscript.canopy_surface_exchange_parameters.minimum_richardson_number,
                    .maximum_richardson_number = context.runscript.canopy_surface_exchange_parameters.maximum_richardson_number,
                    .richardson_resistance_multiplier = context.runscript.canopy_surface_exchange_parameters.richardson_resistance_multiplier,
                    .minimum_boundary_resistance_h_per_m = context.runscript.canopy_surface_exchange_parameters.minimum_boundary_resistance_h_per_m,
                    .maximum_boundary_resistance_h_per_m = context.runscript.canopy_surface_exchange_parameters.maximum_boundary_resistance_h_per_m,
                    .saturation_vapor_prefactor_k = context.runscript.canopy_surface_exchange_parameters.saturation_vapor_prefactor_k,
                    .saturation_relative_humidity = context.runscript.canopy_surface_exchange_parameters.saturation_relative_humidity,
                    .saturation_temperature_coefficient_k = context.runscript.canopy_surface_exchange_parameters.saturation_temperature_k,
                    .saturation_reference_inverse_temperature_per_k = context.runscript.canopy_surface_exchange_parameters.saturation_reference_inverse_temperature_per_k,
                    .latent_heat_of_vaporization_megajoules_per_m3 = context.runscript.canopy_surface_exchange_parameters.latent_heat_of_vaporization_megajoules_per_m3,
                    .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                };
                const active_dry_volume_m3 = @min(
                    context.runscript.standing_dead_sapwood_thickness_m * retention.standing_dead_surface_area_m2[plant],
                    canopy.plant_standing_dead_carbon_g[plant] * context.runscript.stalk_volume_m3_per_g_c,
                );
                const dry_heat_capacity_megajoules_per_k = context.runscript.standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k * active_dry_volume_m3;
                const activation_threshold_megajoules_per_k = context.runscript.standing_dead_activation_heat_capacity_megajoules_per_m2_k * context.canopy_cell_area_m2[cell];
                if (dry_heat_capacity_megajoules_per_k <= activation_threshold_megajoules_per_k) continue;
                var total_canopy_radiation_fraction: f64 = 0;
                for (0..context.config.plant_populations) |population| {
                    const population_index = cell * context.config.plant_populations + population;
                    total_canopy_radiation_fraction += retention.living_radiation_fraction[population_index] +
                        retention.standing_dead_radiation_fraction[population_index];
                }
                const dead_radiation_share = if (total_canopy_radiation_fraction > 1.0e-12)
                    retention.standing_dead_radiation_fraction[plant] / total_canopy_radiation_fraction
                else
                    0;
                const cell_air_column_height_m = @max(5.0, context.surface_aerodynamics.wind_reference_height_m[cell]);
                const canopy_air_heat_capacity_megajoules_per_k =
                    cell_air_column_height_m * context.canopy_cell_area_m2[cell] *
                    context.runscript.ground_air_parameters.volumetric_air_heat_capacity_megajoules_per_m3_k;
                const dead_substep = try ecosys.substep_initialization.calculate(.{
                    .canopy_air_temperature_k = air_temperature_k,
                    .canopy_air_heat_capacity_megajoules_per_k = canopy_air_heat_capacity_megajoules_per_k,
                    .negligible_canopy_air_heat_capacity_megajoules_per_k = context.config.physical_tolerance.heat(canopy_air_heat_capacity_megajoules_per_k * air_temperature_k) / @max(1.0, air_temperature_k),
                    .canopy_radiation_share = dead_radiation_share,
                    .negligible_canopy_radiation_share = 1.0e-12,
                    .previous_combustion_heat_megajoules_per_step = context.delayed_standing_dead_combustion_heat_megajoules[plant],
                    .legacy_substep_multiplier = 1,
                    .canopy_surface_water_m3 = retention.standing_dead_surface_water_m3[plant],
                    .retained_foliar_water_m3_per_step = retention.standing_dead_retention_m3_per_h[plant],
                    .canopy_surface_temperature_k = canopy.plant_standing_dead_surface_temperature_k[plant],
                    .liquid_water_heat_capacity_megajoules_per_m3_k = dead_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                });
                // UPTAKE 3984--3997: HCBFDY raises TKQY before the standing-
                // dead surface solve. Preserve vapor concentration across the
                // sensible impulse and use this state again in the air solve.
                air_temperature_k = dead_substep.canopy_air_temperature_k;
                exchange_inputs.standing_dead_air_temperature_k = air_temperature_k;
                exchange_inputs.standing_dead_air_vapor_fraction = air_vapor_fraction;
                canopy.plant_standing_dead_aerodynamic_temperature_k[plant] = air_temperature_k;
                canopy.plant_standing_dead_aerodynamic_vapor_pressure_kpa[plant] =
                    air_vapor_fraction * air_temperature_k /
                    context.runscript.canopy_surface_exchange_parameters.saturation_vapor_prefactor_k;
                const wet_heat_capacity_megajoules_per_k = dry_heat_capacity_megajoules_per_k +
                    dead_parameters.liquid_water_heat_capacity_megajoules_per_m3_k * retention.standing_dead_surface_water_m3[plant];
                const solved_surface = try ecosys.standing_dead_surface_exchange.solveSurfaceTemperature(.{
                    .exchange_inputs = exchange_inputs,
                    .absorbed_shortwave_megajoules_per_h = retention.standing_dead_absorbed_shortwave_megajoules_per_m2[plant] * context.canopy_cell_area_m2[cell],
                    .downward_longwave_megajoules_per_h = context.atmosphere.longwave_radiation_megajoules_per_m2[cell] * retention.standing_dead_radiation_fraction[plant] * context.canopy_cell_area_m2[cell],
                    .lateral_longwave_megajoules_per_h = 0,
                    .ground_surface_temperature_k = context.grid.surface_temperature_k[cell],
                    .emission_coefficient_megajoules_per_h_k4 = context.runscript.standing_dead_emissivity * 2.04e-10 * retention.standing_dead_radiation_fraction[plant] * context.canopy_cell_area_m2[cell],
                    .dry_and_existing_water_heat_capacity_megajoules_per_k = wet_heat_capacity_megajoules_per_k,
                    .retained_precipitation_water_m3_per_h = retention.standing_dead_retention_m3_per_h[plant],
                    .retained_precipitation_heat_megajoules_per_h = 0,
                    .minimum_effective_heat_capacity_megajoules_per_k = context.runscript.standing_dead_effective_heat_capacity_floor_megajoules_per_m2_k * context.canopy_cell_area_m2[cell],
                }, dead_parameters, .{
                    .minimum_temperature_k = context.runscript.minimum_surface_temperature_k,
                    .maximum_temperature_k = context.runscript.maximum_surface_temperature_k,
                    .solver_options = .{
                        .absolute_tolerance = context.config.nonlinear_tolerance.temperature_k,
                        .relative_tolerance = context.config.nonlinear_tolerance.relative,
                        .max_iterations = try context.iteration_limits.standingDeadEnergyMaxIterations(),
                        .picard_relaxation = context.config.picard_relaxation,
                        // Placeholder: standing_dead.surface_exchange overwrites
                        // this with max(1, |T_dead|) K before solving, so the
                        // band is always set from the residual's own magnitude.
                        .residual_scale = 1.0,
                    },
                });
                canopy.plant_standing_dead_surface_temperature_k[plant] = solved_surface.temperature_k;
                const result = solved_surface.exchange;
                dead_exchange.intercepted_water_change_m3_per_h[plant] = result.intercepted_water_change_m3_per_h;
                dead_exchange.net_radiation_megajoules_per_h[plant] = solved_surface.net_radiation_megajoules_per_h;
                dead_exchange.sensible_heat_flux_megajoules_per_h[plant] = result.sensible_heat_flux_megajoules_per_h;
                dead_exchange.latent_heat_flux_megajoules_per_h[plant] = result.latent_heat_flux_megajoules_per_h;
                dead_exchange.vapor_sensible_heat_flux_megajoules_per_h[plant] = result.vapor_sensible_heat_flux_megajoules_per_h;
                dead_exchange.storage_heat_flux_megajoules_per_h[plant] = solved_surface.storage_heat_flux_megajoules_per_h;
                context.standing_dead_evaporation_m3_per_h[plant] = result.intercepted_water_change_m3_per_h;
                if (context.standing_dead_air_exchange.*) |*dead_air| {
                    var total_canopy_exposure: f64 = 0;
                    for (0..context.config.plant_populations) |population| {
                        const population_index = cell * context.config.plant_populations + population;
                        total_canopy_exposure += retention.living_radiation_fraction[population_index] + retention.standing_dead_radiation_fraction[population_index];
                    }
                    const dead_share = if (total_canopy_exposure > 1.0e-12) retention.standing_dead_radiation_fraction[plant] / total_canopy_exposure else 0;
                    if (dead_share > 1.0e-12) {
                        const air_column_height_m = @max(5.0, context.surface_aerodynamics.wind_reference_height_m[cell]);
                        const cell_air_volume_m3 = air_column_height_m * context.canopy_cell_area_m2[cell];
                        const atmospheric_sensible_conductance = airflow.sensible_boundary_numerator_megajoules_per_m_h_k[cell] * retention.standing_dead_radiation_fraction[plant] / result.total_aerodynamic_resistance_h_per_m * dead_share;
                        const atmospheric_vapor_conductance = @min(
                            airflow.latent_boundary_numerator_m2_per_h[cell] * retention.standing_dead_radiation_fraction[plant] / result.total_aerodynamic_resistance_h_per_m,
                            cell_air_volume_m3,
                        ) * dead_share;
                        const ground_sensible_conductance = airflow.sensible_boundary_numerator_megajoules_per_m_h_k[cell] / airflow.resistance_below_standing_dead_h_per_m[plant] * total_canopy_exposure * dead_share;
                        const ground_vapor_conductance = airflow.latent_boundary_numerator_m2_per_h[cell] / airflow.resistance_below_standing_dead_h_per_m[plant] * total_canopy_exposure * dead_share;
                        const dead_air_result = try ecosys.canopy_air_exchange.solveInto(dead_air, cell, species, .{
                            .initial_temperature_k = air_temperature_k,
                            .initial_vapor_fraction = canopy.plant_standing_dead_aerodynamic_vapor_pressure_kpa[plant] * context.runscript.canopy_surface_exchange_parameters.saturation_vapor_prefactor_k / air_temperature_k,
                            .atmospheric_temperature_k = context.atmosphere.air_temperature_k[cell],
                            .atmospheric_vapor_fraction = try ecosys.ground_air_exchange.vaporVolumeFraction(context.atmosphere.vapor_pressure_kpa[cell], context.atmosphere.air_temperature_k[cell], context.runscript.ground_air_parameters),
                            .ground_air_temperature_k = context.ground_air.temperature_k[cell],
                            .ground_air_vapor_fraction = context.ground_air.vapor_volume_fraction[cell],
                            .heat_capacity_megajoules_per_k = cell_air_volume_m3 * context.runscript.ground_air_parameters.volumetric_air_heat_capacity_megajoules_per_m3_k * dead_share,
                            .air_volume_m3 = cell_air_volume_m3 * dead_share,
                            .atmospheric_sensible_conductance_megajoules_per_h_k = atmospheric_sensible_conductance,
                            .atmospheric_vapor_conductance_m3_per_h = atmospheric_vapor_conductance,
                            .ground_sensible_conductance_megajoules_per_h_k = ground_sensible_conductance,
                            .ground_vapor_conductance_m3_per_h = ground_vapor_conductance,
                            .canopy_surface_sensible_heat_flux_megajoules_per_h = result.sensible_heat_flux_megajoules_per_h,
                            .canopy_surface_vapor_flux_m3_per_h = result.intercepted_water_change_m3_per_h,
                            // HCBFDY was already applied to accepted TKQY
                            // before the standing-dead surface solve.
                            .lateral_sensible_heat_flux_megajoules_per_h = 0,
                            .lateral_vapor_flux_m3_per_h = 0,
                        }, .{
                            .saturation_vapor_prefactor_k = context.runscript.canopy_surface_exchange_parameters.saturation_vapor_prefactor_k,
                            .saturation_relative_humidity = context.runscript.canopy_surface_exchange_parameters.saturation_relative_humidity,
                            .saturation_temperature_coefficient_k = context.runscript.canopy_surface_exchange_parameters.saturation_temperature_k,
                            .saturation_reference_inverse_temperature_per_k = context.runscript.canopy_surface_exchange_parameters.saturation_reference_inverse_temperature_per_k,
                        }, .{
                            .max_iterations = context.iteration_limits.canopy_energy_water_max_iterations,
                            .picard_relaxation = context.config.picard_relaxation,
                        });
                        canopy.plant_standing_dead_aerodynamic_temperature_k[plant] = dead_air_result.temperature_k;
                        canopy.plant_standing_dead_aerodynamic_vapor_pressure_kpa[plant] = dead_air_result.vapor_fraction * dead_air_result.temperature_k / context.runscript.canopy_surface_exchange_parameters.saturation_vapor_prefactor_k;
                    }
                }
            };
        }
        if (context.canopy_air_exchange.*) |*canopy_air| {
            for (0..context.grid.cell_count) |cell| {
                const air_column_height_m = @max(5.0, context.surface_aerodynamics.wind_reference_height_m[cell]);
                const cell_air_volume_m3 = air_column_height_m * context.canopy_cell_area_m2[cell];
                const cell_air_heat_capacity_megajoules_per_k = cell_air_volume_m3 * context.runscript.ground_air_parameters.volumetric_air_heat_capacity_megajoules_per_m3_k;
                var total_canopy_radiation_fraction: f64 = 0;
                for (0..context.config.plant_populations) |population| {
                    const population_index = cell * context.config.plant_populations + population;
                    total_canopy_radiation_fraction += retention.living_radiation_fraction[population_index] + retention.standing_dead_radiation_fraction[population_index];
                }
                for (0..context.config.plant_populations) |species| {
                    const plant = cell * context.config.plant_populations + species;
                    const exposure_fraction = retention.living_radiation_fraction[plant];
                    const canopy_share = if (total_canopy_radiation_fraction > 1.0e-12) exposure_fraction / total_canopy_radiation_fraction else 0;
                    if (exposure_fraction <= 1.0e-12 or canopy_share <= 1.0e-12) continue;
                    const total_resistance_h_per_m = exchange.total_aerodynamic_resistance_h_per_m[plant];
                    if (!std.math.isFinite(total_resistance_h_per_m) or total_resistance_h_per_m <= 0) {
                        canopy.plant_canopy_aerodynamic_temperature_k[plant] = context.atmosphere.air_temperature_k[cell];
                        canopy.plant_canopy_aerodynamic_vapor_pressure_kpa[plant] = context.atmosphere.vapor_pressure_kpa[cell];
                        continue;
                    }
                    const below_species_resistance_h_per_m = airflow.resistance_below_species_h_per_m[plant];
                    const atmospheric_sensible_conductance = airflow.sensible_boundary_numerator_megajoules_per_m_h_k[cell] * exposure_fraction / total_resistance_h_per_m * canopy_share;
                    const atmospheric_vapor_conductance = @min(
                        airflow.latent_boundary_numerator_m2_per_h[cell] * exposure_fraction / total_resistance_h_per_m,
                        cell_air_volume_m3,
                    ) * canopy_share;
                    const ground_sensible_conductance = airflow.sensible_boundary_numerator_megajoules_per_m_h_k[cell] / below_species_resistance_h_per_m * exposure.canopy_exposure_fraction[cell] * canopy_share;
                    const ground_vapor_conductance = airflow.latent_boundary_numerator_m2_per_h[cell] / below_species_resistance_h_per_m * exposure.canopy_exposure_fraction[cell] * canopy_share;
                    const result = try ecosys.canopy_air_exchange.solveInto(canopy_air, cell, species, .{
                        .initial_temperature_k = canopy.plant_canopy_aerodynamic_temperature_k[plant],
                        .initial_vapor_fraction = surface_workspace.canopy_air_vapor_fraction[plant],
                        .atmospheric_temperature_k = context.atmosphere.air_temperature_k[cell],
                        .atmospheric_vapor_fraction = try ecosys.ground_air_exchange.vaporVolumeFraction(context.atmosphere.vapor_pressure_kpa[cell], context.atmosphere.air_temperature_k[cell], context.runscript.ground_air_parameters),
                        .ground_air_temperature_k = context.ground_air.temperature_k[cell],
                        .ground_air_vapor_fraction = context.ground_air.vapor_volume_fraction[cell],
                        .heat_capacity_megajoules_per_k = cell_air_heat_capacity_megajoules_per_k * canopy_share,
                        .air_volume_m3 = cell_air_volume_m3 * canopy_share,
                        .atmospheric_sensible_conductance_megajoules_per_h_k = atmospheric_sensible_conductance,
                        .atmospheric_vapor_conductance_m3_per_h = atmospheric_vapor_conductance,
                        .ground_sensible_conductance_megajoules_per_h_k = ground_sensible_conductance,
                        .ground_vapor_conductance_m3_per_h = ground_vapor_conductance,
                        .canopy_surface_sensible_heat_flux_megajoules_per_h = exchange.sensible_heat_flux_megajoules_per_h[plant],
                        .canopy_surface_vapor_flux_m3_per_h = exchange.intercepted_water_change_m3_per_h[plant] + exchange.transpiration_m3_per_h[plant],
                        // HCBFCY was already applied to the accepted TKQY
                        // initial state before the TKCY solve above.
                        .lateral_sensible_heat_flux_megajoules_per_h = 0,
                        .lateral_vapor_flux_m3_per_h = 0,
                    }, .{
                        .saturation_vapor_prefactor_k = context.runscript.canopy_surface_exchange_parameters.saturation_vapor_prefactor_k,
                        .saturation_relative_humidity = context.runscript.canopy_surface_exchange_parameters.saturation_relative_humidity,
                        .saturation_temperature_coefficient_k = context.runscript.canopy_surface_exchange_parameters.saturation_temperature_k,
                        .saturation_reference_inverse_temperature_per_k = context.runscript.canopy_surface_exchange_parameters.saturation_reference_inverse_temperature_per_k,
                    }, .{
                        .max_iterations = context.iteration_limits.canopy_energy_water_max_iterations,
                        .picard_relaxation = context.config.picard_relaxation,
                    });
                    canopy.plant_canopy_aerodynamic_temperature_k[plant] = result.temperature_k;
                    canopy.plant_canopy_aerodynamic_vapor_pressure_kpa[plant] = result.vapor_fraction * result.temperature_k / context.runscript.canopy_surface_exchange_parameters.saturation_vapor_prefactor_k;
                }
            }
        }
    };
}

test "production binds one post-WATSUB living canopy root solve before transport and downstream biochemistry" {
    const allocator = std.testing.allocator;
    const snow_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_snow_energy.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(snow_source);
    const vegetation_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_vegetation.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(vegetation_source);
    const heat_water_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_heat_water_solute.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(heat_water_source);
    const entry_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/ecosys_ng.zig", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(entry_source);
    const first_test = std.mem.indexOf(u8, snow_source, "test \"") orelse return error.MissingSnowEnergyTests;
    const snow_production = snow_source[0..first_test];

    const coupled_call = std.mem.indexOf(u8, snow_production, "canopy_coupled_convergence.solveOuterCoupled") orelse return error.MissingCoupledCanopyBinding;
    const capacity_producer = std.mem.indexOf(u8, snow_production, ".evaluate_fn = ecosys.canopy_maximum_turgor_carboxylation.evaluateOpaque") orelse return error.MissingCurrentTemperatureStomateCapacityBinding;
    // Match the executable initial pass, not the preceding explanatory
    // comment that names the same function.
    const initial_stomate = std.mem.indexOfPos(u8, snow_production, capacity_producer, "try ecosys.canopy_coupled_convergence.minimumStomatalResistanceAtTemperature(") orelse return error.MissingInitialStomateBinding;
    const final_stomate = std.mem.indexOfPos(u8, snow_production, coupled_call, ".stomate_final_pass = stomate_boundaries[plant]") orelse return error.MissingFinalStomateBinding;
    const grid_dispatch = std.mem.indexOfPos(u8, snow_production, initial_stomate, "try tile_kernels.runIndexedKernelAcrossSerialTiles(") orelse return error.MissingCoupledCanopyGridDispatch;
    const soil_transport_call = std.mem.indexOf(u8, snow_production, "group_heat_water_solute.solveSoilHeatWaterAndSoluteTransport") orelse return error.MissingSoilTransportBinding;
    const hook_binding = std.mem.indexOfPos(u8, snow_production, soil_transport_call, ".advance = CanopyHook.advance") orelse return error.MissingPostWatsubCanopyBinding;
    const root_commit = std.mem.indexOf(u8, snow_production, "state_updateRootHydraulicsWithCanopyPotential") orelse return error.MissingCoupledRootCommit;
    const stomate_commit = std.mem.indexOf(u8, snow_production, "@memcpy(canopy.plant_minimum_water_vapor_resistance_h_per_m, staged_minimum_stomatal_resistance)") orelse return error.MissingStomateCommit;
    const carboxylation_commit = std.mem.indexOf(u8, snow_production, "canopy.plant_maximum_turgor_carboxylation_umol_per_s[plant] = coupled.final_maximum_turgor_carboxylation_umol_per_s") orelse return error.MissingStomateCarboxylationCommit;
    const canopy_commit = std.mem.indexOf(u8, snow_production, "context.plants.canopy_temperature_k[plant] = result.canopy_surface_temperature_k") orelse return error.MissingCoupledCanopyCommit;
    // The per-cell helper is declared before the orchestrator, so source
    // position alone cannot express call order. The initial STOMATE pass is
    // built before dispatch; the dispatched helper owns coupled+final STOMATE;
    // all global validation/publication follows the awaited dispatch.
    try std.testing.expect(coupled_call < final_stomate);
    try std.testing.expect(capacity_producer < initial_stomate and initial_stomate < grid_dispatch);
    try std.testing.expect(grid_dispatch < root_commit and root_commit < stomate_commit);
    try std.testing.expect(grid_dispatch < root_commit and root_commit < canopy_commit and canopy_commit < carboxylation_commit);
    try std.testing.expect(soil_transport_call < hook_binding);
    try std.testing.expect(std.mem.indexOf(u8, snow_production, ".canopy_co2_fixation_umol_per_s = canopy.plant_maximum_turgor_carboxylation_umol_per_s[plant]") == null);
    try std.testing.expect(std.mem.indexOf(u8, snow_production, "solver_options.max_iterations = context.iteration_limits.canopy_energy_water_max_iterations") != null);
    try std.testing.expect(std.mem.indexOf(u8, snow_production, ".heat_flux_timestep_h = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, snow_production, ".water_flux_timestep_h = 1") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, snow_production, "canopy_coupled_convergence.solveOuterCoupled"));
    try std.testing.expect(std.mem.indexOf(u8, snow_production, "water_aggregation.calculate") == null);
    try std.testing.expect(std.mem.indexOf(u8, snow_production, "canopy.plant_transpiration_m3_per_h[plant] = result.transpiration_m3_per_step") != null);
    try std.testing.expect(std.mem.indexOf(u8, snow_production, "exchange.transpiration_m3_per_h[plant] = result.surface_transpiration_m3_per_step") != null);
    try std.testing.expect(std.mem.indexOf(u8, snow_production, ".canopy_surface_vapor_flux_m3_per_h = exchange.intercepted_water_change_m3_per_h[plant] + exchange.transpiration_m3_per_h[plant]") != null);
    const retired_surface_kernel = "canopy_surface_exchange." ++ "applyTile";
    try std.testing.expect(std.mem.indexOf(u8, snow_production, retired_surface_kernel) == null);
    try std.testing.expect(std.mem.indexOf(u8, vegetation_source, "plant_water_balance.applyTile") == null);
    try std.testing.expect(std.mem.indexOf(u8, vegetation_source, "canopy_energy.applyTile") == null);

    // The coupled stage owns both source STOMATE calls and publishes RSMN
    // before GROSUB consumes it. The later EXTRACT aggregation transaction
    // must not recompute a third, post-GROSUB RSMN.
    try std.testing.expect(std.mem.indexOf(u8, vegetation_source, ".minimum_stomatal_resistance_h_per_m_by_plant = canopy.plant_minimum_water_vapor_resistance_h_per_m") != null);
    const extract_call = std.mem.indexOf(u8, entry_source, "try ecosys.uptake_coupled_transaction.apply(") orelse return error.MissingUptakeAggregationBinding;
    const extract_end = std.mem.indexOfPos(u8, entry_source, extract_call, "driver_context.ecosystem_energy_ledger_state.*.canopy_water_energy_megajoules") orelse return error.MissingUptakeAggregationEnd;
    try std.testing.expect(std.mem.indexOf(u8, entry_source[extract_call..extract_end], ".stomate") == null);

    // The accepted TKCY is the shared PlantState carrier read by GROSUB's
    // biochemistry path; these two markers guard both sides of that binding.
    const watsub = std.mem.indexOf(u8, heat_water_source, "advanceMappedDeferred(") orelse return error.MissingWatsubBinding;
    const nitro = std.mem.indexOfPos(u8, heat_water_source, watsub, ".nitro,") orelse return error.MissingNitroBinding;
    const canopy_hook = std.mem.indexOfPos(u8, heat_water_source, nitro, "post_watsub_biology.advance(") orelse return error.MissingPostWatsubCanopyCall;
    const grosub = std.mem.indexOfPos(u8, heat_water_source, canopy_hook, "advanceUptakeGrowthAndExtract(") orelse return error.MissingPostCanopyGrosub;
    const transport_replay = std.mem.indexOfPos(u8, heat_water_source, grosub, "replayAcceptedTransport()") orelse return error.MissingLateTransportReplay;
    try std.testing.expect(watsub < nitro and nitro < canopy_hook and canopy_hook < grosub and grosub < transport_replay);
    try std.testing.expect(std.mem.indexOf(u8, vegetation_source, ".canopy_temperature_k_by_plant = context.plants.canopy_temperature_k") != null);
    // Standing-dead science remains on its distinct source path.
    try std.testing.expect(std.mem.indexOf(u8, snow_production, "standing_dead_surface_exchange.solveSurfaceTemperature") != null);
}

test "living canopy nonlinear work dispatches grid columns while commit remains serial" {
    const source = @embedFile("hourly_snow_energy.zig");
    const tile_source = @embedFile("tile_kernels.zig");
    const first_test = std.mem.indexOf(u8, source, "\ntest \"") orelse
        return error.MissingSnowEnergyTestBoundary;
    const production = source[0..first_test];
    const kernel = std.mem.indexOf(
        u8,
        production,
        "noinline fn solveLivingCanopyCells(",
    ) orelse return error.MissingLivingCanopyGridKernel;
    const cell_owner = std.mem.indexOfPos(
        u8,
        production,
        kernel,
        "for (cells) |cell| try solveLivingCanopyCell(kernel_context, cell);",
    ) orelse return error.MissingWholeCellCanopyDispatch;
    const species_order = std.mem.indexOfPos(
        u8,
        production,
        cell_owner,
        "for (0..context.config.plant_populations) |species|",
    ) orelse return error.MissingSerialSpeciesOrder;
    const coupled = std.mem.indexOfPos(
        u8,
        production,
        species_order,
        "canopy_coupled_convergence.solveOuterCoupled",
    ) orelse return error.MissingLivingCanopyCoupledSolve;
    const dispatch = std.mem.indexOfPos(
        u8,
        production,
        coupled,
        "try tile_kernels.runIndexedKernelAcrossSerialTiles(",
    ) orelse return error.MissingLivingCanopyGridDispatch;
    const root_validation = std.mem.indexOfPos(
        u8,
        production,
        dispatch,
        "state_updateRootHydraulicsWithCanopyPotential",
    ) orelse return error.MissingSerialRootValidation;
    const publication = std.mem.indexOfPos(
        u8,
        production,
        root_validation,
        "for (staged_publication, 0..) |publication, plant|",
    ) orelse return error.MissingSerialCanopyPublication;

    try std.testing.expect(kernel < cell_owner and cell_owner < species_order and species_order < coupled);
    try std.testing.expect(coupled < dispatch and dispatch < root_validation and root_validation < publication);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, production, "canopy_coupled_convergence.solveOuterCoupled"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, production, "try tile_kernels.runIndexedKernelAcrossSerialTiles("),
    );
    try std.testing.expect(std.mem.indexOf(u8, production, "std.Thread.spawn(") == null);

    const tile_driver = std.mem.indexOf(
        u8,
        tile_source,
        "pub fn runIndexedKernelAcrossSerialTiles(",
    ) orelse return error.MissingIndexedSerialTileDriver;
    const next_driver = std.mem.indexOfPos(
        u8,
        tile_source,
        tile_driver,
        "pub fn runKernelAcrossSerialTilePlan(",
    ) orelse return error.MissingIndexedSerialTileDriverBoundary;
    const indexed_driver = tile_source[tile_driver..next_driver];
    try std.testing.expect(std.mem.indexOf(
        u8,
        indexed_driver,
        "for (plan.tiles, 0..) |_, tile_index|",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        indexed_driver,
        "try context.executor.runOwnedCellsIndexed(",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, indexed_driver, "std.Thread.spawn(") == null);
}

test "living canopy grid dispatch selects canonical error and never advances the next tile" {
    const Plan = struct {
        tiles: [2]u8 = .{ 0, 0 },
        offsets: [3]usize = .{ 0, 4, 6 },
        cells: [6]usize = .{ 7, 2, 9, 1, 6, 0 },

        pub fn ownedCellTile(self: *const @This(), tile_index: usize) !ecosys.compute.OwnedCellTile {
            if (tile_index >= self.tiles.len) return error.TileIndexOutOfBounds;
            return .{
                .plan_identity = @ptrCast(self),
                .tile_index = tile_index,
                .cell_indices = self.cells[self.offsets[tile_index]..self.offsets[tile_index + 1]],
            };
        }
    };
    const FailureContext = struct {
        second_tile_seen: std.atomic.Value(bool) = .init(false),

        fn apply(self: *@This(), cells: []const usize, _: usize) !void {
            for (cells) |cell| switch (cell) {
                7 => return error.CanonicalFirstCanopyFailure,
                2 => return error.LaterCanopyFailure,
                6, 0 => self.second_tile_seen.store(true, .release),
                else => {},
            };
        }
    };
    const DriverContext = struct {
        tile_plan: *const Plan,
        executor: ecosys.compute.CpuExecutor,
    };

    var plan: Plan = .{};
    const executor = try ecosys.compute.CpuExecutor.init(
        std.testing.allocator,
        4,
        .{
            .identity = @ptrCast(&plan),
            .maximum_owned_cell_count = 4,
            .owned_cell_offsets = &plan.offsets,
            .owned_cells = &plan.cells,
        },
    );
    defer executor.deinit();
    var driver = DriverContext{ .tile_plan = &plan, .executor = executor };
    var failure_context: FailureContext = .{};
    try std.testing.expectError(
        error.CanonicalFirstCanopyFailure,
        tile_kernels.runIndexedKernelAcrossSerialTiles(
            &driver,
            &failure_context,
            FailureContext.apply,
        ),
    );
    try std.testing.expect(!failure_context.second_tile_seen.load(.acquire));
}

const std = @import("std");
const compute = @import("../../core/compute.zig");
const grid_module = @import("../../state/grid.zig");
const gas_transport = @import("transport.zig");
const oxygen_allocation = @import("oxygen_allocation.zig");
const oxygen_solver = @import("oxygen_solver.zig");
const nitrogen_flux = @import("../nutrients/nitrogen_flux_workspace.zig");
const nitrifier_environment = @import("../microbial/nitrifier_environment_step.zig");
const nitrogen_parameters = @import("../nutrients/nitrogen_parameters.zig");
const reactive_nitrogen = @import("../nutrients/reactive_nitrogen_state.zig");
const root_gas = @import("../../plant/root/plant_root_gas_exchange.zig");
const surface_gas_parameters = @import("../../surface/gas_parameters.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    staged_allocation: oxygen_allocation.State,
    populations: []oxygen_allocation.Population,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_count: usize, population_count: usize) !State {
        var staged = try oxygen_allocation.State.init(allocator, cell_count, layer_count, population_count);
        errdefer staged.deinit();
        const populations = try allocator.alloc(oxygen_allocation.Population, try std.math.mul(usize, try std.math.mul(usize, cell_count, layer_count), population_count));
        @memset(populations, inactivePopulation());
        return .{ .allocator = allocator, .staged_allocation = staged, .populations = populations };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.populations);
        self.staged_allocation.deinit();
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    staging: *State,
    result: *oxygen_allocation.State,
    flux: *const nitrogen_flux.State,
    reactive: *const reactive_nitrogen.State,
    environment: *const nitrifier_environment.State,
    grid: *const grid_module.GridState,
    matrix_bulk_volume_m3: []const f64,
    porosity_fraction: []const f64,
    field_capacity_fraction: []const f64,
    gas: *gas_transport.State,
    root_gas_parameters: root_gas.RuntimeParameters,
    oxygen_parameters: nitrogen_parameters.OxygenUptakeParameters,
    /// Cell-major gas-species concentrations from the live atmospheric
    /// carrier. Soil layers select their owning cell's oxygen boundary.
    atmospheric_concentration_g_per_m3: []const f64,
    absolute_tolerance_g_o: f64,
    relative_tolerance: f64,
    derivative_floor: f64,
    picard_relaxation: f64,
    gas_max_iterations: u16,
    ice_density_megagrams_per_m3: f64 = 0.917,
};

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const populations_per_layer = context.result.population_count;
    const oxygen_species = gas_transport.Species.oxygen;
    for (range.first..range.end) |layer| {
        const base = layer * populations_per_layer;
        const water_m3 = context.grid.matrix_liquid_water_m3[layer];
        if (water_m3 <= 0) {
            @memset(context.result.allocation_fraction[base .. base + populations_per_layer], 0);
            @memset(context.result.oxygen_uptake_g_o[base .. base + populations_per_layer], 0);
            @memset(context.result.demand_satisfaction_fraction[base .. base + populations_per_layer], 0);
            @memset(context.result.iterations[base .. base + populations_per_layer], 0);
            continue;
        }
        const oxygen_environment = try root_gas.oxygenEnvironment(context.root_gas_parameters, context.grid.soil_temperature_k[layer], 0);
        const is_surface_layer = layer % context.grid.soil_layer_capacity == 0;
        const water_film_m = try root_gas.soilWaterFilmThicknessM(context.root_gas_parameters, context.grid.matric_potential_megapascal[layer], is_surface_layer);
        const matrix_volume_m3 = context.matrix_bulk_volume_m3[layer];
        const water_fraction = std.math.clamp(water_m3 / matrix_volume_m3, 0, 1);
        const aqueous_tortuosity = context.oxygen_parameters.aqueous_tortuosity_coefficient * water_fraction * water_fraction;
        for (0..populations_per_layer) |population| {
            const unit = base + population;
            const active = context.flux.aerobic_oxygen_demand_g_o[unit] > context.oxygen_parameters.negligible_oxygen_demand_g_o;
            context.staging.populations[unit] = .{
                .is_aerobic = active,
                .previous_oxygen_demand_g_o = if (active) context.reactive.previous_aerobic_oxygen_demand_g_o[unit] else 0,
                .fallback_active_fraction = if (active) context.flux.aerobic_fallback_active_fraction[unit] else 0,
                .uptake_conductance_m3_per_step = if (active) try oxygen_solver.uptakeConductance_m3_per_step(.{
                    .microbial_radius_m = context.oxygen_parameters.microbial_radius_m,
                    .water_film_thickness_m = water_film_m,
                    .tortuosity = aqueous_tortuosity,
                    .aqueous_oxygen_diffusivity_m2_per_step = oxygen_environment.aqueous_diffusivity_m2_per_h,
                    .microbial_count_per_g_c = context.oxygen_parameters.microbial_count_per_g_c,
                    .active_biomass_g_c = context.flux.aerobic_active_biomass_g_c[unit],
                }) else 0,
                .oxygen_half_saturation_g_o_per_m3 = context.oxygen_parameters.oxygen_half_saturation_g_o_per_m3,
                .maximum_oxygen_uptake_g_o = if (active) context.flux.aerobic_oxygen_demand_g_o[unit] else 0,
            };
        }
        const gas_index = try gas_transport.massIndex(layer, oxygen_species, context.gas.cell_count);
        const cell = layer / context.grid.soil_layer_capacity;
        const atmospheric_oxygen_g_o_per_m3 = try surface_gas_parameters.atmosphericConcentrationForCell(
            context.atmospheric_concentration_g_per_m3,
            context.grid.cell_count,
            cell,
            .oxygen,
        );
        var shared: oxygen_allocation.SharedLayer = .{
            .gaseous_oxygen_g_o = context.gas.gaseous_mass_g[gas_index],
            .aqueous_oxygen_g_o = context.gas.dissolved_mass_g[gas_index],
            .gaseous_flux_g_o = 0,
            .aqueous_flux_g_o = 0,
            .water_volume_m3 = water_m3,
            .air_volume_m3 = context.grid.matrix_air_volume_m3[layer],
            .oxygen_solubility_water_to_air = oxygen_environment.water_to_air_mass_solubility_ratio,
            .gas_exchange_rate_per_step = try airWaterExchangeRate(context.*, layer),
            .maximum_aqueous_oxygen_concentration_g_o_per_m3 = atmospheric_oxygen_g_o_per_m3 * oxygen_environment.water_to_air_mass_solubility_ratio,
        };
        const soil_layer = layer % context.grid.soil_layer_capacity;
        try oxygen_allocation.solveLayer(&context.staging.staged_allocation, cell, soil_layer, &shared, context.staging.populations[base .. base + populations_per_layer], .{
            .minimum_allocation_fraction = context.oxygen_parameters.minimum_allocation_fraction,
            .negligible_demand_g_o = context.oxygen_parameters.negligible_oxygen_demand_g_o,
        }, options(context.*));
        @memcpy(context.result.allocation_fraction[base .. base + populations_per_layer], context.staging.staged_allocation.allocation_fraction[base .. base + populations_per_layer]);
        @memcpy(context.result.oxygen_uptake_g_o[base .. base + populations_per_layer], context.staging.staged_allocation.oxygen_uptake_g_o[base .. base + populations_per_layer]);
        @memcpy(context.result.demand_satisfaction_fraction[base .. base + populations_per_layer], context.staging.staged_allocation.demand_satisfaction_fraction[base .. base + populations_per_layer]);
        @memcpy(context.result.iterations[base .. base + populations_per_layer], context.staging.staged_allocation.iterations[base .. base + populations_per_layer]);
        context.gas.gaseous_mass_g[gas_index] = shared.gaseous_oxygen_g_o;
        context.gas.dissolved_mass_g[gas_index] = shared.aqueous_oxygen_g_o;
    }
}

fn inactivePopulation() oxygen_allocation.Population {
    return .{ .is_aerobic = false, .previous_oxygen_demand_g_o = 0, .fallback_active_fraction = 0, .uptake_conductance_m3_per_step = 0, .oxygen_half_saturation_g_o_per_m3 = 1, .maximum_oxygen_uptake_g_o = 0 };
}

fn airWaterExchangeRate(context: ApplyContext, layer: usize) !f64 {
    const available_pore_m3 = context.grid.matrix_pore_capacity_m3[layer] - context.grid.matrix_ice_water_m3[layer] / context.ice_density_megagrams_per_m3;
    if (available_pore_m3 <= 0 or context.grid.matrix_air_volume_m3[layer] <= 0) return 0;
    const relative_water = std.math.clamp(context.grid.matrix_liquid_water_m3[layer] / available_pore_m3, 0, 1);
    const field_capacity_transition = context.field_capacity_fraction[layer] / context.porosity_fraction[layer];
    const transition = @max(context.oxygen_parameters.minimum_transition_water_fraction, field_capacity_transition);
    const exponent = if (relative_water > transition) context.oxygen_parameters.wet_exchange_exponent else context.oxygen_parameters.dry_exchange_exponent;
    const rate = context.oxygen_parameters.air_water_exchange_reference_time_h / @exp(exponent * (relative_water - transition));
    if (!std.math.isFinite(rate)) return error.NonFiniteSoilOxygenExchangeRate;
    return if (relative_water > transition) @max(0, rate) else @min(1, rate);
}

fn options(context: ApplyContext) oxygen_solver.Options {
    return .{ .absolute_tolerance_g_o = context.absolute_tolerance_g_o, .relative_tolerance = context.relative_tolerance, .derivative_floor = context.derivative_floor, .picard_relaxation = context.picard_relaxation, .gas_max_iterations = context.gas_max_iterations };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    if (!std.math.isFinite(context.ice_density_megagrams_per_m3) or context.ice_density_megagrams_per_m3 <= 0 or context.ice_density_megagrams_per_m3 > 1) return error.InvalidSoilOxygenExchangeRate;
    const layers = context.grid.layer_count;
    const units = try std.math.mul(usize, layers, context.result.population_count);
    if (range.first > range.end or range.end > layers or context.gas.cell_count != layers or context.flux.layer_count != layers or context.reactive.layer_count != layers or context.environment.layer_count != layers or context.staging.staged_allocation.population_count != context.result.population_count or context.staging.populations.len != units or context.atmospheric_concentration_g_per_m3.len != context.grid.cell_count * gas_transport.species_count) return error.SoilOxygenDimensionMismatch;
    inline for (.{ context.matrix_bulk_volume_m3, context.porosity_fraction, context.field_capacity_fraction }) |values| if (values.len != layers) return error.SoilOxygenDimensionMismatch;
    for (0..context.grid.cell_count) |cell| {
        const value = try surface_gas_parameters.atmosphericConcentrationForCell(
            context.atmospheric_concentration_g_per_m3,
            context.grid.cell_count,
            cell,
            .oxygen,
        );
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidAtmosphericOxygenConcentration;
    }
}

test "tiled soil oxygen solve conserves oxygen and exits before NPH times NPG" {
    const config = @import("../../core/config.zig").SimulationConfig{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 };
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 1;
    grid.matrix_air_volume_m3[0] = 1;
    grid.matrix_pore_capacity_m3[0] = 2;
    grid.soil_temperature_k[0] = 298.15;
    grid.matric_potential_megapascal[0] = -0.1;
    var gas = try gas_transport.State.init(std.testing.allocator, 1);
    defer gas.deinit();
    const oxygen_index = try gas_transport.massIndex(0, .oxygen, 1);
    gas.gaseous_mass_g[oxygen_index] = 1;
    gas.dissolved_mass_g[oxygen_index] = 0.02;
    var flux = try nitrogen_flux.State.init(std.testing.allocator, 1, 2);
    defer flux.deinit();
    flux.aerobic_oxygen_demand_g_o[0] = 0.1;
    flux.aerobic_active_biomass_g_c[0] = 0.01;
    flux.aerobic_fallback_active_fraction[0] = 1;
    var environment = try nitrifier_environment.State.init(std.testing.allocator, 1, 2);
    defer environment.deinit();
    var reactive = try reactive_nitrogen.State.init(std.testing.allocator, 1, 2);
    defer reactive.deinit();
    reactive.previous_aerobic_oxygen_demand_g_o[0] = 0.1;
    environment.roles[0] = .ammonia_oxidizer;
    environment.active_biomass_g_c[0] = 0.01;
    environment.microbial_active_fraction[0] = 1;
    var result = try oxygen_allocation.State.init(std.testing.allocator, 1, 1, 2);
    defer result.deinit();
    var staging = try State.init(std.testing.allocator, 1, 1, 2);
    defer staging.deinit();
    var context = testContext(&staging, &result, &flux, &reactive, &environment, &grid, &gas);
    const before = gas.gaseous_mass_g[oxygen_index] + gas.dissolved_mass_g[oxygen_index];
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(result.oxygen_uptake_g_o[0] > 0);
    try std.testing.expect(result.iterations[0] < context.gas_max_iterations);
    try std.testing.expectApproxEqAbs(before, gas.gaseous_mass_g[oxygen_index] + gas.dissolved_mass_g[oxygen_index] + result.oxygen_uptake_g_o[0], 1e-9);
    try std.testing.expectEqual(@as(f64, 0), result.oxygen_uptake_g_o[1]);
}

test "invalid soil oxygen input leaves authoritative gas and allocation unchanged" {
    const config = @import("../../core/config.zig").SimulationConfig{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 };
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var gas = try gas_transport.State.init(std.testing.allocator, 1);
    defer gas.deinit();
    var flux = try nitrogen_flux.State.init(std.testing.allocator, 1, 1);
    defer flux.deinit();
    var environment = try nitrifier_environment.State.init(std.testing.allocator, 1, 1);
    defer environment.deinit();
    var reactive = try reactive_nitrogen.State.init(std.testing.allocator, 1, 1);
    defer reactive.deinit();
    var result = try oxygen_allocation.State.init(std.testing.allocator, 1, 1, 1);
    defer result.deinit();
    var staging = try State.init(std.testing.allocator, 1, 1, 1);
    defer staging.deinit();
    result.demand_satisfaction_fraction[0] = 0.75;
    var context = testContext(&staging, &result, &flux, &reactive, &environment, &grid, &gas);
    var invalid_atmosphere = [_]f64{0} ** gas_transport.species_count;
    invalid_atmosphere[@intFromEnum(gas_transport.Species.oxygen)] = std.math.nan(f64);
    context.atmospheric_concentration_g_per_m3 = &invalid_atmosphere;
    try std.testing.expectError(error.InvalidAtmosphericOxygenConcentration, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqual(@as(f64, 0.75), result.demand_satisfaction_fraction[0]);
    try std.testing.expectEqual(@as(f64, 0), gas.gaseous_mass_g[try gas_transport.massIndex(0, .oxygen, 1)]);
}

fn testContext(staging: *State, result: *oxygen_allocation.State, flux: *const nitrogen_flux.State, reactive: *const reactive_nitrogen.State, environment: *const nitrifier_environment.State, grid: *const grid_module.GridState, gas: *gas_transport.State) ApplyContext {
    const root_parameters = root_gas.compatibilityParameters();
    return .{
        .staging = staging,
        .result = result,
        .flux = flux,
        .reactive = reactive,
        .environment = environment,
        .grid = grid,
        .matrix_bulk_volume_m3 = &.{1},
        .porosity_fraction = &.{0.5},
        .field_capacity_fraction = &.{0.25},
        .gas = gas,
        .root_gas_parameters = root_parameters,
        .oxygen_parameters = .{ .microbial_radius_m = 1e-6, .microbial_count_per_g_c = 2.3866348449e11, .oxygen_half_saturation_g_o_per_m3 = 0.064, .hygroscopic_water_potential_megapascal = -1.5e4, .air_water_exchange_reference_time_h = 0.5, .wet_exchange_exponent = 12, .dry_exchange_exponent = 12, .minimum_transition_water_fraction = 0.5, .aqueous_tortuosity_coefficient = 0.7, .minimum_allocation_fraction = 0.001, .negligible_oxygen_demand_g_o = 1e-12 },
        .atmospheric_concentration_g_per_m3 = &.{ 0, 0, 0.275, 0, 0, 0, 0 },
        .absolute_tolerance_g_o = 1e-12,
        .relative_tolerance = 1e-9,
        .derivative_floor = 1e-14,
        .picard_relaxation = 0.5,
        .gas_max_iterations = 80,
    };
}

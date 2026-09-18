const std = @import("std");
const oxygen_solver = @import("oxygen_solver.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    layer_count: usize,
    population_count: usize,
    allocation_fraction: []f64,
    oxygen_uptake_g_o: []f64,
    demand_satisfaction_fraction: []f64,
    iterations: []u16,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_count: usize, population_count: usize) !State {
        if (cell_count == 0 or layer_count == 0 or population_count == 0) return error.InvalidOxygenAllocationDimensions;
        const layer_population_count = try std.math.mul(usize, try std.math.mul(usize, cell_count, layer_count), population_count);
        const allocation_fraction = try allocator.alloc(f64, layer_population_count);
        errdefer allocator.free(allocation_fraction);
        const oxygen_uptake_g_o = try allocator.alloc(f64, layer_population_count);
        errdefer allocator.free(oxygen_uptake_g_o);
        const demand_satisfaction_fraction = try allocator.alloc(f64, layer_population_count);
        errdefer allocator.free(demand_satisfaction_fraction);
        const iterations = try allocator.alloc(u16, layer_population_count);
        @memset(allocation_fraction, 0);
        @memset(oxygen_uptake_g_o, 0);
        @memset(demand_satisfaction_fraction, 0);
        @memset(iterations, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .layer_count = layer_count, .population_count = population_count, .allocation_fraction = allocation_fraction, .oxygen_uptake_g_o = oxygen_uptake_g_o, .demand_satisfaction_fraction = demand_satisfaction_fraction, .iterations = iterations };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.allocation_fraction);
        self.allocator.free(self.oxygen_uptake_g_o);
        self.allocator.free(self.demand_satisfaction_fraction);
        self.allocator.free(self.iterations);
        self.* = undefined;
    }

    fn offset(self: State, cell_index: usize, layer_index: usize) !usize {
        if (cell_index >= self.cell_count or layer_index >= self.layer_count) return error.OxygenAllocationIndexOutOfBounds;
        return (cell_index * self.layer_count + layer_index) * self.population_count;
    }
};

pub const SharedLayer = struct {
    gaseous_oxygen_g_o: f64,
    aqueous_oxygen_g_o: f64,
    gaseous_flux_g_o: f64,
    aqueous_flux_g_o: f64,
    water_volume_m3: f64,
    air_volume_m3: f64,
    oxygen_solubility_water_to_air: f64,
    gas_exchange_rate_per_step: f64,
    maximum_aqueous_oxygen_concentration_g_o_per_m3: f64,
};

pub const Population = struct {
    is_aerobic: bool,
    previous_oxygen_demand_g_o: f64,
    fallback_active_fraction: f64,
    uptake_conductance_m3_per_step: f64,
    oxygen_half_saturation_g_o_per_m3: f64,
    maximum_oxygen_uptake_g_o: f64,
};

pub const Parameters = struct {
    minimum_allocation_fraction: f64,
    negligible_demand_g_o: f64,
};

/// Ports NITRO's FOXYX population partition without a fixed population limit.
/// Raw historical-demand shares are normalized before independent solves so
/// their sum is one and the shared oxygen inventory cannot be double-counted.
pub fn solveLayer(state: *State, cell_index: usize, layer_index: usize, shared: *SharedLayer, populations: []const Population, parameters: Parameters, options: oxygen_solver.Options) !void {
    if (populations.len != state.population_count) return error.OxygenPopulationCountMismatch;
    try validateShared(shared.*, parameters);
    const base = try state.offset(cell_index, layer_index);
    var raw_sum: f64 = 0;
    var previous_total: f64 = 0;
    for (populations) |population| {
        try validatePopulation(population);
        if (population.is_aerobic) previous_total += population.previous_oxygen_demand_g_o;
    }
    for (populations, 0..) |population, population_index| {
        const raw_fraction = if (!population.is_aerobic) 0 else @max(parameters.minimum_allocation_fraction, if (previous_total > parameters.negligible_demand_g_o) population.previous_oxygen_demand_g_o / previous_total else population.fallback_active_fraction);
        state.allocation_fraction[base + population_index] = raw_fraction;
        raw_sum += raw_fraction;
    }
    if (raw_sum == 0) {
        @memset(state.oxygen_uptake_g_o[base .. base + populations.len], 0);
        @memset(state.demand_satisfaction_fraction[base .. base + populations.len], 0);
        @memset(state.iterations[base .. base + populations.len], 0);
        shared.gaseous_oxygen_g_o += shared.gaseous_flux_g_o;
        shared.aqueous_oxygen_g_o += shared.aqueous_flux_g_o;
        shared.gaseous_flux_g_o = 0;
        shared.aqueous_flux_g_o = 0;
        return;
    }

    var final_gaseous_g_o: f64 = 0;
    var final_aqueous_g_o: f64 = 0;
    for (populations, 0..) |population, population_index| {
        const index = base + population_index;
        const fraction = state.allocation_fraction[index] / raw_sum;
        state.allocation_fraction[index] = fraction;
        if (fraction == 0) {
            state.oxygen_uptake_g_o[index] = 0;
            state.demand_satisfaction_fraction[index] = 0;
            state.iterations[index] = 0;
            continue;
        }
        const result = try oxygen_solver.solve(.{
            .allocated_gaseous_oxygen_g_o = shared.gaseous_oxygen_g_o * fraction,
            .allocated_aqueous_oxygen_g_o = shared.aqueous_oxygen_g_o * fraction,
            .allocated_gaseous_flux_g_o = shared.gaseous_flux_g_o * fraction,
            .allocated_aqueous_flux_g_o = shared.aqueous_flux_g_o * fraction,
            .water_volume_m3 = shared.water_volume_m3,
            .air_volume_m3 = shared.air_volume_m3 * fraction,
            .population_allocation_fraction = fraction,
            .oxygen_solubility_water_to_air = shared.oxygen_solubility_water_to_air,
            .gas_exchange_rate_per_step = shared.gas_exchange_rate_per_step,
            .uptake_conductance_m3_per_step = population.uptake_conductance_m3_per_step,
            .oxygen_half_saturation_g_o_per_m3 = population.oxygen_half_saturation_g_o_per_m3,
            .maximum_oxygen_uptake_g_o = population.maximum_oxygen_uptake_g_o,
            .maximum_aqueous_oxygen_concentration_g_o_per_m3 = shared.maximum_aqueous_oxygen_concentration_g_o_per_m3,
        }, options);
        state.oxygen_uptake_g_o[index] = result.oxygen_uptake_g_o;
        state.demand_satisfaction_fraction[index] = result.demand_satisfaction_fraction;
        state.iterations[index] = result.iterations;
        final_gaseous_g_o += result.gaseous_oxygen_g_o;
        final_aqueous_g_o += result.aqueous_oxygen_g_o;
    }
    shared.gaseous_oxygen_g_o = final_gaseous_g_o;
    shared.aqueous_oxygen_g_o = final_aqueous_g_o;
    shared.gaseous_flux_g_o = 0;
    shared.aqueous_flux_g_o = 0;
}

fn validateShared(shared: SharedLayer, parameters: Parameters) !void {
    inline for (@typeInfo(SharedLayer).@"struct".fields) |field| if (!std.math.isFinite(@field(shared, field.name))) return error.NonFiniteSharedOxygenState;
    if (!std.math.isFinite(parameters.minimum_allocation_fraction) or !std.math.isFinite(parameters.negligible_demand_g_o)) return error.NonFiniteOxygenAllocationParameter;
    if (shared.gaseous_oxygen_g_o < 0 or shared.aqueous_oxygen_g_o < 0 or shared.water_volume_m3 <= 0 or shared.air_volume_m3 < 0 or shared.oxygen_solubility_water_to_air < 0 or shared.gas_exchange_rate_per_step < 0 or shared.maximum_aqueous_oxygen_concentration_g_o_per_m3 <= 0 or parameters.minimum_allocation_fraction < 0 or parameters.negligible_demand_g_o < 0) return error.InvalidSharedOxygenState;
    if (shared.gaseous_oxygen_g_o + shared.gaseous_flux_g_o < 0 or shared.aqueous_oxygen_g_o + shared.aqueous_flux_g_o < 0) return error.NegativeAvailableOxygen;
}

fn validatePopulation(population: Population) !void {
    inline for (@typeInfo(Population).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(population, field.name))) return error.NonFiniteOxygenPopulation;
    if (population.previous_oxygen_demand_g_o < 0 or population.fallback_active_fraction < 0 or population.uptake_conductance_m3_per_step < 0 or population.oxygen_half_saturation_g_o_per_m3 <= 0 or population.maximum_oxygen_uptake_g_o < 0) return error.InvalidOxygenPopulation;
}

fn testOptions() oxygen_solver.Options {
    return .{ .absolute_tolerance_g_o = 1e-12, .relative_tolerance = 1e-10, .derivative_floor = 1e-14, .picard_relaxation = 0.5, .gas_max_iterations = 80 };
}

test "runtime population allocation conserves shared oxygen" {
    var state = try State.init(std.testing.allocator, 2, 3, 19);
    defer state.deinit();
    var populations: [19]Population = undefined;
    for (&populations, 0..) |*population, index| population.* = .{ .is_aerobic = true, .previous_oxygen_demand_g_o = @floatFromInt(index + 1), .fallback_active_fraction = 1, .uptake_conductance_m3_per_step = 0.02, .oxygen_half_saturation_g_o_per_m3 = 0.1, .maximum_oxygen_uptake_g_o = 0.001 };
    var layer: SharedLayer = .{ .gaseous_oxygen_g_o = 5, .aqueous_oxygen_g_o = 1, .gaseous_flux_g_o = 0.2, .aqueous_flux_g_o = 0.1, .water_volume_m3 = 2, .air_volume_m3 = 3, .oxygen_solubility_water_to_air = 0.03, .gas_exchange_rate_per_step = 0.5, .maximum_aqueous_oxygen_concentration_g_o_per_m3 = 1 };
    const before = layer.gaseous_oxygen_g_o + layer.aqueous_oxygen_g_o + layer.gaseous_flux_g_o + layer.aqueous_flux_g_o;
    try solveLayer(&state, 1, 2, &layer, &populations, .{ .minimum_allocation_fraction = 0.001, .negligible_demand_g_o = 1e-12 }, testOptions());
    const base = (1 * 3 + 2) * 19;
    var fraction_sum: f64 = 0;
    var uptake_sum: f64 = 0;
    for (0..19) |index| {
        fraction_sum += state.allocation_fraction[base + index];
        uptake_sum += state.oxygen_uptake_g_o[base + index];
        try std.testing.expect(state.iterations[base + index] < 80);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1), fraction_sum, 1e-14);
    try std.testing.expectApproxEqAbs(before, layer.gaseous_oxygen_g_o + layer.aqueous_oxygen_g_o + uptake_sum, 1e-9);
}

test "invalid population leaves shared oxygen unmodified" {
    var state = try State.init(std.testing.allocator, 1, 1, 1);
    defer state.deinit();
    const populations = [_]Population{.{ .is_aerobic = true, .previous_oxygen_demand_g_o = std.math.nan(f64), .fallback_active_fraction = 1, .uptake_conductance_m3_per_step = 1, .oxygen_half_saturation_g_o_per_m3 = 0.1, .maximum_oxygen_uptake_g_o = 1 }};
    var layer: SharedLayer = .{ .gaseous_oxygen_g_o = 5, .aqueous_oxygen_g_o = 1, .gaseous_flux_g_o = 0, .aqueous_flux_g_o = 0, .water_volume_m3 = 2, .air_volume_m3 = 3, .oxygen_solubility_water_to_air = 0.03, .gas_exchange_rate_per_step = 0.5, .maximum_aqueous_oxygen_concentration_g_o_per_m3 = 1 };
    const before = layer;
    try std.testing.expectError(error.NonFiniteOxygenPopulation, solveLayer(&state, 0, 0, &layer, &populations, .{ .minimum_allocation_fraction = 0.001, .negligible_demand_g_o = 1e-12 }, testOptions()));
    try std.testing.expectEqualDeep(before, layer);
}

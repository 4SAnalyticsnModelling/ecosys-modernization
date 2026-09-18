const std = @import("std");
const organic = @import("../organic/initialization.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    substrate_count: usize,
    population_count: usize,
    kinetic_fraction_count: usize,
    activity_change_g_c: []f64,
    dissolved_change: []organic.ElementPool,
    acetate_change_g_c: []f64,
    microbial_change: []organic.ElementPool,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, substrate_count: usize, population_count: usize, kinetic_fraction_count: usize) !State {
        if (cell_count == 0 or substrate_count == 0 or population_count == 0 or kinetic_fraction_count == 0) return error.InvalidOrganicPrimingDimensions;
        const substrate_cells = try std.math.mul(usize, cell_count, substrate_count);
        const microbial_count = try std.math.mul(usize, try std.math.mul(usize, substrate_cells, population_count), kinetic_fraction_count);
        const activity = try allocator.alloc(f64, substrate_cells);
        errdefer allocator.free(activity);
        const dissolved = try allocator.alloc(organic.ElementPool, substrate_cells);
        errdefer allocator.free(dissolved);
        const acetate = try allocator.alloc(f64, substrate_cells);
        errdefer allocator.free(acetate);
        const microbial = try allocator.alloc(organic.ElementPool, microbial_count);
        @memset(activity, 0);
        @memset(dissolved, .{});
        @memset(acetate, 0);
        @memset(microbial, .{});
        return .{ .allocator = allocator, .cell_count = cell_count, .substrate_count = substrate_count, .population_count = population_count, .kinetic_fraction_count = kinetic_fraction_count, .activity_change_g_c = activity, .dissolved_change = dissolved, .acetate_change_g_c = acetate, .microbial_change = microbial };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.microbial_change);
        self.allocator.free(self.acetate_change_g_c);
        self.allocator.free(self.dissolved_change);
        self.allocator.free(self.activity_change_g_c);
        self.* = undefined;
    }

    pub fn resetCell(self: *State, cell: usize) !void {
        if (cell >= self.cell_count) return error.OrganicPrimingCellOutOfBounds;
        @memset(self.activity_change_g_c[cell * self.substrate_count ..][0..self.substrate_count], 0);
        @memset(self.dissolved_change[cell * self.substrate_count ..][0..self.substrate_count], .{});
        @memset(self.acetate_change_g_c[cell * self.substrate_count ..][0..self.substrate_count], 0);
        const microbial_per_cell = self.substrate_count * self.population_count * self.kinetic_fraction_count;
        @memset(self.microbial_change[cell * microbial_per_cell ..][0..microbial_per_cell], .{});
    }
};

pub const Inputs = struct {
    substrate_carbon_g_c: []const f64,
    microbial_activity_g_c_per_step: []const f64,
    dissolved: []const organic.ElementPool,
    dissolved_available_after_uptake: []const organic.ElementPool,
    dissolved_acetate_carbon_g_c: []const f64,
    dissolved_acetate_available_after_uptake_g_c: []const f64,
    microbial: []const organic.ElementPool,
    microbial_temperature_water_response: []const f64, // substrate x population
    dissolved_priming_rate_per_h: f64,
    microbial_priming_rate_per_h: f64,
    decomposition_temperature_response: f64,
    timestep_h: f64,
    negligible_carbon_g_c: f64,
};

/// NITRO XFRK/XFRC/XFRN/XFRP/XFRA and XFMC/XFMN/XFMP. The result
/// is an extensive conservative delta and never mutates the source pools.
pub fn deriveCell(state: *State, cell: usize, inputs: Inputs) !void {
    try validate(state.*, inputs);
    try state.resetCell(cell);
    const substrate_base = cell * state.substrate_count;
    const microbial_per_cell = state.substrate_count * state.population_count * state.kinetic_fraction_count;
    const activity_change = state.activity_change_g_c[substrate_base..][0..state.substrate_count];
    const dissolved_change = state.dissolved_change[substrate_base..][0..state.substrate_count];
    const acetate_change = state.acetate_change_g_c[substrate_base..][0..state.substrate_count];
    const microbial_change = state.microbial_change[cell * microbial_per_cell ..][0..microbial_per_cell];
    for (0..state.substrate_count) |left| for (left + 1..state.substrate_count) |right| {
        const left_carbon = inputs.substrate_carbon_g_c[left];
        const right_carbon = inputs.substrate_carbon_g_c[right];
        if (left_carbon <= inputs.negligible_carbon_g_c or right_carbon <= inputs.negligible_carbon_g_c) continue;
        const total_carbon = left_carbon + right_carbon;
        const dissolved_factor = inputs.dissolved_priming_rate_per_h * inputs.decomposition_temperature_response * inputs.timestep_h / total_carbon;
        transferScalar(inputs.microbial_activity_g_c_per_step, activity_change, left, right, dissolved_factor * (inputs.microbial_activity_g_c_per_step[left] * right_carbon - inputs.microbial_activity_g_c_per_step[right] * left_carbon));
        transferPoolField(inputs.dissolved_available_after_uptake, dissolved_change, left, right, .carbon_g_c, dissolved_factor * (inputs.dissolved[left].carbon_g_c * right_carbon - inputs.dissolved[right].carbon_g_c * left_carbon));
        transferPoolField(inputs.dissolved_available_after_uptake, dissolved_change, left, right, .nitrogen_g_n, dissolved_factor * (inputs.dissolved[left].nitrogen_g_n * right_carbon - inputs.dissolved[right].nitrogen_g_n * left_carbon));
        transferPoolField(inputs.dissolved_available_after_uptake, dissolved_change, left, right, .phosphorus_g_p, dissolved_factor * (inputs.dissolved[left].phosphorus_g_p * right_carbon - inputs.dissolved[right].phosphorus_g_p * left_carbon));
        transferScalar(inputs.dissolved_acetate_available_after_uptake_g_c, acetate_change, left, right, dissolved_factor * (inputs.dissolved_acetate_carbon_g_c[left] * right_carbon - inputs.dissolved_acetate_carbon_g_c[right] * left_carbon));

        for (0..state.population_count) |population| for (0..state.kinetic_fraction_count) |fraction| {
            const left_index = (left * state.population_count + population) * state.kinetic_fraction_count + fraction;
            const right_index = (right * state.population_count + population) * state.kinetic_fraction_count + fraction;
            const microbial_factor = inputs.microbial_priming_rate_per_h * inputs.microbial_temperature_water_response[left * state.population_count + population] * inputs.timestep_h / total_carbon;
            transferIndexedPoolField(inputs.microbial, microbial_change, left_index, right_index, .carbon_g_c, microbial_factor * (inputs.microbial[left_index].carbon_g_c * right_carbon - inputs.microbial[right_index].carbon_g_c * left_carbon));
            transferIndexedPoolField(inputs.microbial, microbial_change, left_index, right_index, .nitrogen_g_n, microbial_factor * (inputs.microbial[left_index].nitrogen_g_n * right_carbon - inputs.microbial[right_index].nitrogen_g_n * left_carbon));
            transferIndexedPoolField(inputs.microbial, microbial_change, left_index, right_index, .phosphorus_g_p, microbial_factor * (inputs.microbial[left_index].phosphorus_g_p * right_carbon - inputs.microbial[right_index].phosphorus_g_p * left_carbon));
        };
    };
}

fn transferScalar(source: []const f64, change: []f64, left: usize, right: usize, requested: f64) void {
    if (source[left] + change[left] - requested > 0 and source[right] + change[right] + requested > 0) {
        change[left] -= requested;
        change[right] += requested;
    }
}

fn transferPoolField(source: []const organic.ElementPool, change: []organic.ElementPool, left: usize, right: usize, comptime field: std.meta.FieldEnum(organic.ElementPool), requested: f64) void {
    transferIndexedPoolField(source, change, left, right, field, requested);
}

fn transferIndexedPoolField(source: []const organic.ElementPool, change: []organic.ElementPool, left: usize, right: usize, comptime field: std.meta.FieldEnum(organic.ElementPool), requested: f64) void {
    const name = @tagName(field);
    if (@field(source[left], name) + @field(change[left], name) - requested > 0 and @field(source[right], name) + @field(change[right], name) + requested > 0) {
        @field(change[left], name) -= requested;
        @field(change[right], name) += requested;
    }
}

fn validate(state: State, inputs: Inputs) !void {
    const microbial_count = try std.math.mul(usize, try std.math.mul(usize, state.substrate_count, state.population_count), state.kinetic_fraction_count);
    if (inputs.substrate_carbon_g_c.len != state.substrate_count or inputs.microbial_activity_g_c_per_step.len != state.substrate_count or inputs.dissolved.len != state.substrate_count or inputs.dissolved_available_after_uptake.len != state.substrate_count or inputs.dissolved_acetate_carbon_g_c.len != state.substrate_count or inputs.dissolved_acetate_available_after_uptake_g_c.len != state.substrate_count or inputs.microbial.len != microbial_count or inputs.microbial_temperature_water_response.len != state.substrate_count * state.population_count) return error.InvalidOrganicPrimingDimensions;
    inline for (.{ inputs.dissolved_priming_rate_per_h, inputs.microbial_priming_rate_per_h, inputs.decomposition_temperature_response, inputs.timestep_h, inputs.negligible_carbon_g_c }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicPrimingParameter;
    if (inputs.timestep_h <= 0) return error.InvalidOrganicPrimingParameter;
    for (inputs.substrate_carbon_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicPrimingState;
    for (inputs.microbial_activity_g_c_per_step) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicPrimingState;
    for (inputs.dissolved_acetate_carbon_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicPrimingState;
    for (inputs.dissolved_acetate_available_after_uptake_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicPrimingState;
    for (inputs.microbial_temperature_water_response) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicPrimingState;
    for (inputs.dissolved) |pool| try validatePool(pool);
    for (inputs.dissolved_available_after_uptake) |pool| try validatePool(pool);
    for (inputs.microbial) |pool| try validatePool(pool);
}

fn validatePool(pool: organic.ElementPool) !void {
    inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| if (!std.math.isFinite(@field(pool, field.name)) or @field(pool, field.name) < 0) return error.InvalidOrganicPrimingState;
}

test "priming exchange conserves every extensive pool across runtime substrates" {
    var state = try State.init(std.testing.allocator, 1, 4, 2, 3);
    defer state.deinit();
    const substrate = [_]f64{ 10, 20, 30, 40 };
    const activity = [_]f64{ 4, 1, 2, 3 };
    const dissolved = [_]organic.ElementPool{
        .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.04 },
        .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 },
        .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.03 },
    };
    const acetate = [_]f64{ 1, 2, 3, 4 };
    const microbial = [_]organic.ElementPool{.{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 }} ** 24;
    const response = [_]f64{1} ** 8;
    try deriveCell(&state, 0, .{ .substrate_carbon_g_c = &substrate, .microbial_activity_g_c_per_step = &activity, .dissolved = &dissolved, .dissolved_available_after_uptake = &dissolved, .dissolved_acetate_carbon_g_c = &acetate, .dissolved_acetate_available_after_uptake_g_c = &acetate, .microbial = &microbial, .microbial_temperature_water_response = &response, .dissolved_priming_rate_per_h = 0.01, .microbial_priming_rate_per_h = 0.001, .decomposition_temperature_response = 1, .timestep_h = 1, .negligible_carbon_g_c = 1e-12 });
    var activity_sum: f64 = 0;
    var acetate_sum: f64 = 0;
    var dissolved_sum: organic.ElementPool = .{};
    var microbial_sum: organic.ElementPool = .{};
    for (state.activity_change_g_c) |value| activity_sum += value;
    for (state.acetate_change_g_c) |value| acetate_sum += value;
    for (state.dissolved_change) |pool| {
        dissolved_sum.carbon_g_c += pool.carbon_g_c;
        dissolved_sum.nitrogen_g_n += pool.nitrogen_g_n;
        dissolved_sum.phosphorus_g_p += pool.phosphorus_g_p;
    }
    for (state.microbial_change) |pool| {
        microbial_sum.carbon_g_c += pool.carbon_g_c;
        microbial_sum.nitrogen_g_n += pool.nitrogen_g_n;
        microbial_sum.phosphorus_g_p += pool.phosphorus_g_p;
    }
    inline for (.{ activity_sum, acetate_sum, dissolved_sum.carbon_g_c, dissolved_sum.nitrogen_g_n, dissolved_sum.phosphorus_g_p, microbial_sum.carbon_g_c, microbial_sum.nitrogen_g_n, microbial_sum.phosphorus_g_p }) |value| try std.testing.expectApproxEqAbs(@as(f64, 0), value, 1e-14);
}

test "priming cannot consume dissolved inventory reserved by microbial uptake" {
    var state = try State.init(std.testing.allocator, 1, 2, 1, 1);
    defer state.deinit();
    const substrate = [_]f64{ 1, 1 };
    const activity = [_]f64{ 0, 0 };
    const dissolved = [_]organic.ElementPool{
        .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.04 },
        .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
    };
    const available = [_]organic.ElementPool{
        .{},
        dissolved[1],
    };
    const acetate = [_]f64{ 0, 0 };
    const microbial = [_]organic.ElementPool{ .{}, .{} };
    const response = [_]f64{ 1, 1 };
    try deriveCell(&state, 0, .{
        .substrate_carbon_g_c = &substrate,
        .microbial_activity_g_c_per_step = &activity,
        .dissolved = &dissolved,
        .dissolved_available_after_uptake = &available,
        .dissolved_acetate_carbon_g_c = &acetate,
        .dissolved_acetate_available_after_uptake_g_c = &acetate,
        .microbial = &microbial,
        .microbial_temperature_water_response = &response,
        .dissolved_priming_rate_per_h = 0.01,
        .microbial_priming_rate_per_h = 0,
        .decomposition_temperature_response = 1,
        .timestep_h = 1,
        .negligible_carbon_g_c = 1e-12,
    });
    try std.testing.expectEqual(@as(f64, 0), state.dissolved_change[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved_change[1].carbon_g_c);
}

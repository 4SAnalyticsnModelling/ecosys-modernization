const std = @import("std");

pub const State = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    current_carbon_exchange_g_c: []f64,
    current_nitrogen_exchange_g_n: []f64,
    current_phosphorus_exchange_g_p: []f64,
    cumulative_carbon_exchange_g_c: []f64,
    cumulative_nitrogen_exchange_g_n: []f64,
    cumulative_phosphorus_exchange_g_p: []f64,
    cumulative_nitrogen_fixation_g_n: []f64,
    cumulative_net_primary_productivity_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize) !State {
        if (plant_count == 0) return error.InvalidRootSoilExchangeDimensions;
        const values = try allocator.alloc(f64, try std.math.mul(usize, plant_count, 8));
        @memset(values, 0);
        var result: State = .{ .allocator = allocator, .plant_count = plant_count, .current_carbon_exchange_g_c = undefined, .current_nitrogen_exchange_g_n = undefined, .current_phosphorus_exchange_g_p = undefined, .cumulative_carbon_exchange_g_c = undefined, .cumulative_nitrogen_exchange_g_n = undefined, .cumulative_phosphorus_exchange_g_p = undefined, .cumulative_nitrogen_fixation_g_n = undefined, .cumulative_net_primary_productivity_g_c = undefined };
        inline for (@typeInfo(State).@"struct".fields, 0..) |field, field_index| if (field.type == []f64) {
            const index = field_index - 2;
            @field(result, field.name) = values[index * plant_count .. (index + 1) * plant_count];
        };
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.current_carbon_exchange_g_c.ptr[0 .. self.plant_count * 8]);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    organic_carbon_exchange_g_c: []const f64,
    organic_nitrogen_exchange_g_n: []const f64,
    organic_phosphorus_exchange_g_p: []const f64,
    ammonium_uptake_g_n: []const f64,
    nitrate_uptake_g_n: []const f64,
    phosphate_h2_uptake_g_p: []const f64,
    phosphate_h_uptake_g_p: []const f64,
    symbiotic_fixation_g_n: []const f64,
    additional_fixation_g_n: []const f64,
    carbon_balance_g_c: []const f64,
    cumulative_respiration_g_c: []const f64,
};

/// grosub.f lines 11648–11673. Current N includes symbiotic fixation; cumulative
/// root-soil N does not. Both fixation terms accumulate in their own ledger.
pub fn accumulate(state: *State, inputs: Inputs) !void {
    try validate(state, inputs);
    for (0..state.plant_count) |plant| _ = try calculate(state, inputs, plant);
    for (0..state.plant_count) |plant| {
        const next = calculate(state, inputs, plant) catch unreachable;
        state.current_carbon_exchange_g_c[plant] = next.current_c;
        state.current_nitrogen_exchange_g_n[plant] = next.current_n;
        state.current_phosphorus_exchange_g_p[plant] = next.current_p;
        state.cumulative_carbon_exchange_g_c[plant] = next.cumulative_c;
        state.cumulative_nitrogen_exchange_g_n[plant] = next.cumulative_n;
        state.cumulative_phosphorus_exchange_g_p[plant] = next.cumulative_p;
        state.cumulative_nitrogen_fixation_g_n[plant] = next.cumulative_fixation;
        state.cumulative_net_primary_productivity_g_c[plant] = next.cumulative_npp;
    }
}

const Next = struct {
    current_c: f64,
    current_n: f64,
    current_p: f64,
    cumulative_c: f64,
    cumulative_n: f64,
    cumulative_p: f64,
    cumulative_fixation: f64,
    cumulative_npp: f64,
};

fn calculate(state: *const State, inputs: Inputs, plant: usize) !Next {
    const organic_c = inputs.organic_carbon_exchange_g_c[plant];
    const organic_n = inputs.organic_nitrogen_exchange_g_n[plant];
    const organic_p = inputs.organic_phosphorus_exchange_g_p[plant];
    const ammonium = inputs.ammonium_uptake_g_n[plant];
    const nitrate = inputs.nitrate_uptake_g_n[plant];
    const phosphate_h2 = inputs.phosphate_h2_uptake_g_p[plant];
    const phosphate_h = inputs.phosphate_h_uptake_g_p[plant];
    const fixation = inputs.symbiotic_fixation_g_n[plant];
    const additional_fixation = inputs.additional_fixation_g_n[plant];
    const current_n = organic_n + ammonium + nitrate + fixation;
    const current_p = organic_p + phosphate_h2 + phosphate_h;
    const next = Next{
        .current_c = organic_c,
        .current_n = current_n,
        .current_p = current_p,
        .cumulative_c = state.cumulative_carbon_exchange_g_c[plant] + organic_c,
        .cumulative_n = state.cumulative_nitrogen_exchange_g_n[plant] +
            organic_n + ammonium + nitrate,
        .cumulative_p = state.cumulative_phosphorus_exchange_g_p[plant] +
            organic_p + phosphate_h2 + phosphate_h,
        .cumulative_fixation = state.cumulative_nitrogen_fixation_g_n[plant] +
            fixation + additional_fixation,
        .cumulative_npp = inputs.carbon_balance_g_c[plant] +
            inputs.cumulative_respiration_g_c[plant],
    };
    inline for (@typeInfo(Next).@"struct".fields) |field|
        if (!std.math.isFinite(@field(next, field.name)))
            return error.NonFiniteRootSoilExchange;
    return next;
}

fn validate(state: *const State, inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        const values = @field(inputs, field.name);
        if (values.len != state.plant_count) return error.InvalidRootSoilExchangeDimensions;
        for (values) |value| if (!std.math.isFinite(value))
            return error.NonFiniteRootSoilExchangeInput;
    }
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        if (@field(state, field.name).len != state.plant_count)
            return error.InvalidRootSoilExchangeDimensions;
        for (@field(state, field.name)) |value| if (!std.math.isFinite(value))
            return error.NonFiniteRootSoilExchangeState;
    };
}

test "source nitrogen ordering separates current cumulative and fixation ledgers" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.cumulative_carbon_exchange_g_c, 10);
    @memset(state.cumulative_nitrogen_exchange_g_n, 20);
    @memset(state.cumulative_phosphorus_exchange_g_p, 30);
    @memset(state.cumulative_nitrogen_fixation_g_n, 40);
    const inputs: Inputs = .{
        .organic_carbon_exchange_g_c = &.{ 1, 2 },
        .organic_nitrogen_exchange_g_n = &.{ 3, 4 },
        .organic_phosphorus_exchange_g_p = &.{ 5, 6 },
        .ammonium_uptake_g_n = &.{ 7, 8 },
        .nitrate_uptake_g_n = &.{ 9, 10 },
        .phosphate_h2_uptake_g_p = &.{ 11, 12 },
        .phosphate_h_uptake_g_p = &.{ 13, 14 },
        .symbiotic_fixation_g_n = &.{ 15, 16 },
        .additional_fixation_g_n = &.{ 17, 18 },
        .carbon_balance_g_c = &.{ 19, 20 },
        .cumulative_respiration_g_c = &.{ 21, 22 },
    };
    try accumulate(&state, inputs);
    try std.testing.expectEqualSlices(f64, &.{ 34, 38 }, state.current_nitrogen_exchange_g_n);
    try std.testing.expectEqualSlices(f64, &.{ 39, 42 }, state.cumulative_nitrogen_exchange_g_n);
    try std.testing.expectEqualSlices(f64, &.{ 72, 74 }, state.cumulative_nitrogen_fixation_g_n);
    try std.testing.expectEqualSlices(f64, &.{ 40, 42 }, state.cumulative_net_primary_productivity_g_c);
}

test "repeated calls accumulate exchanges but replace current and NPP state_updates" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const inputs: Inputs = .{
        .organic_carbon_exchange_g_c = &.{1},
        .organic_nitrogen_exchange_g_n = &.{2},
        .organic_phosphorus_exchange_g_p = &.{3},
        .ammonium_uptake_g_n = &.{4},
        .nitrate_uptake_g_n = &.{5},
        .phosphate_h2_uptake_g_p = &.{6},
        .phosphate_h_uptake_g_p = &.{7},
        .symbiotic_fixation_g_n = &.{8},
        .additional_fixation_g_n = &.{9},
        .carbon_balance_g_c = &.{10},
        .cumulative_respiration_g_c = &.{11},
    };
    try accumulate(&state, inputs);
    try accumulate(&state, inputs);
    try std.testing.expectEqual(@as(f64, 1), state.current_carbon_exchange_g_c[0]);
    try std.testing.expectEqual(@as(f64, 2), state.cumulative_carbon_exchange_g_c[0]);
    try std.testing.expectEqual(@as(f64, 21), state.cumulative_net_primary_productivity_g_c[0]);
}

test "late overflow preserves every current and cumulative state_update" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64) @memset(@field(state, field.name), 7);
    const huge = std.math.floatMax(f64);
    const inputs: Inputs = .{
        .organic_carbon_exchange_g_c = &.{ 1, huge },
        .organic_nitrogen_exchange_g_n = &.{ 1, huge },
        .organic_phosphorus_exchange_g_p = &.{ 1, 1 },
        .ammonium_uptake_g_n = &.{ 1, huge },
        .nitrate_uptake_g_n = &.{ 1, 1 },
        .phosphate_h2_uptake_g_p = &.{ 1, 1 },
        .phosphate_h_uptake_g_p = &.{ 1, 1 },
        .symbiotic_fixation_g_n = &.{ 1, 1 },
        .additional_fixation_g_n = &.{ 1, 1 },
        .carbon_balance_g_c = &.{ 1, 1 },
        .cumulative_respiration_g_c = &.{ 1, 1 },
    };
    try std.testing.expectError(error.NonFiniteRootSoilExchange, accumulate(&state, inputs));
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64)
            for (@field(state, field.name)) |value| try std.testing.expectEqual(@as(f64, 7), value);
}

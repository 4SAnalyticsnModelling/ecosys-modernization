const std = @import("std");
const growth_stages = @import("../lifecycle/growth_stages.zig");

pub const ElementMass = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

pub const KineticFractions = struct {
    carbon: []const f64,
    nitrogen: []const f64,
    phosphorus: []const f64,
};

pub const State = struct {
    stalk: *ElementMass,
    senescing_stalk: *ElementMass,
    internode_length_m: []f64,
    internode_mass: []ElementMass,
    standing_dead_carbon_g_c: []f64,
    standing_dead_nitrogen_g_n: []f64,
    standing_dead_phosphorus_g_p: []f64,
};

pub const Inputs = struct {
    aboveground_turnover_type: u8,
    root_profile_type: u8,
    growth_habit: growth_stages.GrowthHabit,
    litterfall_rate_per_h: f64,
    timestep_h: f64,
    stalk_kinetics: KineticFractions,
};

/// Exact grosub.f lines 4516--4540. Transfers the FSNRX fraction of perennial
/// herbaceous/shrub stalk C, N, and P into runtime standing-dead kinetic pools,
/// then decays total stalk, its senescing subset, and every runtime internode
/// in source order. Length is m; masses are g C, g N, and g P.
pub fn apply(state: State, inputs: Inputs) !bool {
    if (inputs.aboveground_turnover_type > 5 or inputs.root_profile_type > 3)
        return error.InvalidSeasonalStalkTurnoverType;
    const admitted = (inputs.aboveground_turnover_type == 0 or
        inputs.root_profile_type <= 1) and inputs.growth_habit == .perennial;
    if (!admitted) return false;

    const kinetic_count = try validate(state, inputs);
    const turnover_fraction = inputs.litterfall_rate_per_h * inputs.timestep_h;
    if (!std.math.isFinite(turnover_fraction) or
        turnover_fraction < 0 or turnover_fraction > 1)
        return error.InvalidSeasonalStalkTurnoverFraction;

    for (0..kinetic_count) |kinetic| {
        const next_carbon_g_c = state.standing_dead_carbon_g_c[kinetic] +
            inputs.stalk_kinetics.carbon[kinetic] * turnover_fraction *
                state.stalk.carbon_g_c;
        const next_nitrogen_g_n = state.standing_dead_nitrogen_g_n[kinetic] +
            inputs.stalk_kinetics.nitrogen[kinetic] * turnover_fraction *
                state.stalk.nitrogen_g_n;
        const next_phosphorus_g_p = state.standing_dead_phosphorus_g_p[kinetic] +
            inputs.stalk_kinetics.phosphorus[kinetic] * turnover_fraction *
                state.stalk.phosphorus_g_p;
        inline for (.{ next_carbon_g_c, next_nitrogen_g_n, next_phosphorus_g_p }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidSeasonalStalkTurnoverResult;
    }

    const remaining = 1.0 - turnover_fraction;
    for (0..kinetic_count) |kinetic| {
        state.standing_dead_carbon_g_c[kinetic] +=
            inputs.stalk_kinetics.carbon[kinetic] * turnover_fraction *
            state.stalk.carbon_g_c;
        state.standing_dead_nitrogen_g_n[kinetic] +=
            inputs.stalk_kinetics.nitrogen[kinetic] * turnover_fraction *
            state.stalk.nitrogen_g_n;
        state.standing_dead_phosphorus_g_p[kinetic] +=
            inputs.stalk_kinetics.phosphorus[kinetic] * turnover_fraction *
            state.stalk.phosphorus_g_p;
    }
    state.stalk.carbon_g_c = remaining * state.stalk.carbon_g_c;
    state.stalk.nitrogen_g_n = remaining * state.stalk.nitrogen_g_n;
    state.stalk.phosphorus_g_p = remaining * state.stalk.phosphorus_g_p;
    state.senescing_stalk.carbon_g_c = remaining * state.senescing_stalk.carbon_g_c;
    state.senescing_stalk.nitrogen_g_n = remaining * state.senescing_stalk.nitrogen_g_n;
    state.senescing_stalk.phosphorus_g_p = remaining * state.senescing_stalk.phosphorus_g_p;
    for (state.internode_length_m, state.internode_mass) |*length_m, *mass| {
        length_m.* = remaining * length_m.*;
        mass.carbon_g_c = remaining * mass.carbon_g_c;
        mass.nitrogen_g_n = remaining * mass.nitrogen_g_n;
        mass.phosphorus_g_p = remaining * mass.phosphorus_g_p;
    }
    return true;
}

fn validate(state: State, inputs: Inputs) !usize {
    inline for (.{ inputs.litterfall_rate_per_h, inputs.timestep_h }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSeasonalStalkTurnoverInput;
    if (inputs.timestep_h == 0)
        return error.InvalidSeasonalStalkTurnoverInput;
    try validateMass(state.stalk.*);
    try validateMass(state.senescing_stalk.*);
    if (state.internode_length_m.len != state.internode_mass.len)
        return error.SeasonalStalkTurnoverDimensionMismatch;
    for (state.internode_length_m, state.internode_mass) |length_m, mass| {
        if (!std.math.isFinite(length_m) or length_m < 0)
            return error.InvalidSeasonalStalkTurnoverState;
        try validateMass(mass);
    }

    const count = inputs.stalk_kinetics.carbon.len;
    if (count == 0 or inputs.stalk_kinetics.nitrogen.len != count or
        inputs.stalk_kinetics.phosphorus.len != count or
        state.standing_dead_carbon_g_c.len != count or
        state.standing_dead_nitrogen_g_n.len != count or
        state.standing_dead_phosphorus_g_p.len != count)
        return error.SeasonalStalkTurnoverDimensionMismatch;
    inline for (@typeInfo(KineticFractions).@"struct".fields) |field| {
        var total: f64 = 0;
        for (@field(inputs.stalk_kinetics, field.name)) |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 1)
                return error.InvalidSeasonalStalkTurnoverKinetics;
            total += value;
        }
        if (!std.math.isFinite(total) or @abs(total - 1) > 1.0e-12)
            return error.InvalidSeasonalStalkTurnoverKinetics;
    }
    inline for (.{
        state.standing_dead_carbon_g_c,
        state.standing_dead_nitrogen_g_n,
        state.standing_dead_phosphorus_g_p,
    }) |pool| for (pool) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSeasonalStalkTurnoverState;
    return count;
}

fn validateMass(mass: ElementMass) !void {
    inline for (.{ mass.carbon_g_c, mass.nitrogen_g_n, mass.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSeasonalStalkTurnoverState;
}

const Fixture = struct {
    stalk: ElementMass = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.1 },
    senescing: ElementMass = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 },
    lengths_m: [3]f64 = .{ 1, 2, 3 },
    internodes: [3]ElementMass = .{
        .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 },
        .{ .carbon_g_c = 5, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.05 },
    },
    standing_dead: [3][5]f64 = @splat(@splat(0)),

    fn state(self: *Fixture) State {
        return .{
            .stalk = &self.stalk,
            .senescing_stalk = &self.senescing,
            .internode_length_m = &self.lengths_m,
            .internode_mass = &self.internodes,
            .standing_dead_carbon_g_c = &self.standing_dead[0],
            .standing_dead_nitrogen_g_n = &self.standing_dead[1],
            .standing_dead_phosphorus_g_p = &self.standing_dead[2],
        };
    }
};

fn testInputs() Inputs {
    const fractions = &[_]f64{ 0.05, 0.15, 0.2, 0.25, 0.35 };
    return .{
        .aboveground_turnover_type = 0,
        .root_profile_type = 3,
        .growth_habit = .perennial,
        .litterfall_rate_per_h = 0.25,
        .timestep_h = 1,
        .stalk_kinetics = .{
            .carbon = fractions,
            .nitrogen = fractions,
            .phosphorus = fractions,
        },
    };
}

fn sum(values: []const f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total;
}

test "GROSUB runtime kinetic stalk turnover conserves C N P" {
    var fixture: Fixture = .{};
    try std.testing.expect(try apply(fixture.state(), testInputs()));
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), fixture.stalk.carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), fixture.stalk.nitrogen_g_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.075), fixture.stalk.phosphorus_g_p, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 10), fixture.stalk.carbon_g_c + sum(&fixture.standing_dead[0]), 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), fixture.stalk.nitrogen_g_n + sum(&fixture.standing_dead[1]), 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), fixture.stalk.phosphorus_g_p + sum(&fixture.standing_dead[2]), 1e-14);
}

test "GROSUB decays senescing subset and all runtime internodes in K order" {
    const allocator = std.testing.allocator;
    const node_count = 39;
    const lengths = try allocator.alloc(f64, node_count);
    defer allocator.free(lengths);
    const masses = try allocator.alloc(ElementMass, node_count);
    defer allocator.free(masses);
    for (lengths, masses, 0..) |*length_m, *mass, index| {
        length_m.* = @floatFromInt(index + 1);
        mass.* = .{ .carbon_g_c = length_m.*, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    }
    var fixture: Fixture = .{};
    var runtime_state = fixture.state();
    runtime_state.internode_length_m = lengths;
    runtime_state.internode_mass = masses;
    try std.testing.expect(try apply(runtime_state, testInputs()));
    try std.testing.expectEqual(@as(f64, 6), fixture.senescing.carbon_g_c);
    for (lengths, masses, 0..) |length_m, mass, index| {
        const expected = 0.75 * @as(f64, @floatFromInt(index + 1));
        try std.testing.expectApproxEqAbs(expected, length_m, 1e-15);
        try std.testing.expectApproxEqAbs(expected, mass.carbon_g_c, 1e-15);
    }
}

test "annual and woody deep-root gates are strict no-ops" {
    var fixture: Fixture = .{};
    var request = testInputs();
    request.growth_habit = .annual;
    fixture.stalk.carbon_g_c = std.math.nan(f64);
    try std.testing.expect(!try apply(fixture.state(), request));

    request = testInputs();
    request.aboveground_turnover_type = 2;
    request.root_profile_type = 2;
    try std.testing.expect(!try apply(fixture.state(), request));
}

test "late invalid internode leaves every pool unchanged" {
    var fixture: Fixture = .{};
    fixture.internodes[2].phosphorus_g_p = std.math.nan(f64);
    const before = fixture;
    try std.testing.expectError(
        error.InvalidSeasonalStalkTurnoverState,
        apply(fixture.state(), testInputs()),
    );
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&fixture));
}

test "fraction and runtime dimensions fail before mutation" {
    var fixture: Fixture = .{};
    var request = testInputs();
    request.litterfall_rate_per_h = 1.1;
    try std.testing.expectError(
        error.InvalidSeasonalStalkTurnoverFraction,
        apply(fixture.state(), request),
    );
    request = testInputs();
    request.stalk_kinetics.nitrogen = &.{ 0.5, 0.5 };
    try std.testing.expectError(
        error.SeasonalStalkTurnoverDimensionMismatch,
        apply(fixture.state(), request),
    );
    try std.testing.expectEqual(@as(f64, 10), fixture.stalk.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), fixture.standing_dead[0][0]);
}

const std = @import("std");

pub const Elements = struct { carbon: f64, nitrogen: f64, phosphorus: f64 };
pub const Fractions = struct { carbon: []const f64, nitrogen: []const f64, phosphorus: []const f64 };
pub const Litter = struct {
    woody_carbon_g_c: []f64,
    woody_nitrogen_g_n: []f64,
    woody_phosphorus_g_p: []f64,
    stalk_carbon_g_c: []f64,
    stalk_nitrogen_g_n: []f64,
    stalk_phosphorus_g_p: []f64,
};
pub const State = struct {
    branch_stalk_carbon_g_c: *f64,
    branch_stalk_nitrogen_g_n: *f64,
    branch_stalk_phosphorus_g_p: *f64,
    residual_stalk_carbon_g_c: *f64,
    residual_stalk_nitrogen_g_n: *f64,
    residual_stalk_phosphorus_g_p: *f64,
    node_height_m: []f64,
    reserve_carbon_g_c: *f64,
    reserve_nitrogen_g_n: *f64,
    reserve_phosphorus_g_p: *f64,
    litter: Litter,
};
pub const Inputs = struct {
    removal_fraction: f64,
    recyclable: Elements,
    respiration_demand_g_c_per_timestep: f64,
    phenological_senescence_fraction: f64,
    woody_fraction: Elements,
    nonwoody_fraction: Elements,
    woody_kinetics: Fractions,
    stalk_kinetics: Fractions,
};
pub const Result = struct {
    remaining_respiration_g_c_per_timestep: f64,
    reduced_maximum_node_height_m: f64,
};

const Projection = struct {
    residual_before: Elements,
    branch_after: Elements,
    residual_after: Elements,
    reserve_after: Elements,
    remaining_respiration: f64,
    reduced_maximum_height_m: f64,
};

/// grosub.f lines 3492--3552. Publishes residual-stalk litter in woody C/N/P then
/// stalk C/N/P order for each runtime kinetic pool; updates branch and residual
/// state; finds the maximum over all runtime logical nodes, reduces it, and caps
/// every node height; then updates reserve C/N/P and SNCT. The transaction is
/// atomic on validation failure.
pub fn publish(state: State, inputs: Inputs) !Result {
    const kinetic_count = try validateTopology(state, inputs);
    const projection = try project(state, inputs);
    for (0..kinetic_count) |kinetic| try validateLitter(state, inputs, projection, kinetic);
    for (state.node_height_m) |height_m| {
        const capped = @min(projection.reduced_maximum_height_m, height_m);
        if (!std.math.isFinite(capped) or capped < 0) return error.InvalidResidualStalkHeightResult;
    }

    for (0..kinetic_count) |kinetic| state_updateLitter(state, inputs, projection, kinetic);
    state.branch_stalk_carbon_g_c.* = projection.branch_after.carbon;
    state.branch_stalk_nitrogen_g_n.* = projection.branch_after.nitrogen;
    state.branch_stalk_phosphorus_g_p.* = projection.branch_after.phosphorus;
    state.residual_stalk_carbon_g_c.* = projection.residual_after.carbon;
    state.residual_stalk_nitrogen_g_n.* = projection.residual_after.nitrogen;
    state.residual_stalk_phosphorus_g_p.* = projection.residual_after.phosphorus;
    for (state.node_height_m) |*height_m| height_m.* = @min(projection.reduced_maximum_height_m, height_m.*);
    state.reserve_carbon_g_c.* = projection.reserve_after.carbon;
    state.reserve_nitrogen_g_n.* = projection.reserve_after.nitrogen;
    state.reserve_phosphorus_g_p.* = projection.reserve_after.phosphorus;
    return .{
        .remaining_respiration_g_c_per_timestep = projection.remaining_respiration,
        .reduced_maximum_node_height_m = projection.reduced_maximum_height_m,
    };
}

fn project(state: State, inputs: Inputs) !Projection {
    const residual: Elements = .{ .carbon = state.residual_stalk_carbon_g_c.*, .nitrogen = state.residual_stalk_nitrogen_g_n.*, .phosphorus = state.residual_stalk_phosphorus_g_p.* };
    const f = inputs.removal_fraction;
    var maximum_height_m: f64 = 0;
    for (state.node_height_m) |height_m| {
        if (!std.math.isFinite(height_m) or height_m < 0) return error.InvalidResidualStalkHeightState;
        maximum_height_m = @max(maximum_height_m, height_m);
    }
    const consumed_recyclable_carbon = f * inputs.recyclable.carbon * inputs.nonwoody_fraction.carbon;
    const p: Projection = .{
        .residual_before = residual,
        .branch_after = .{
            .carbon = state.branch_stalk_carbon_g_c.* - f * residual.carbon,
            .nitrogen = state.branch_stalk_nitrogen_g_n.* - f * residual.nitrogen,
            .phosphorus = state.branch_stalk_phosphorus_g_p.* - f * residual.phosphorus,
        },
        .residual_after = .{
            .carbon = residual.carbon - f * residual.carbon,
            .nitrogen = residual.nitrogen - f * residual.nitrogen,
            .phosphorus = residual.phosphorus - f * residual.phosphorus,
        },
        .reserve_after = .{
            .carbon = state.reserve_carbon_g_c.* + consumed_recyclable_carbon * inputs.phenological_senescence_fraction,
            .nitrogen = state.reserve_nitrogen_g_n.* + f * inputs.recyclable.nitrogen * inputs.nonwoody_fraction.nitrogen,
            .phosphorus = state.reserve_phosphorus_g_p.* + f * inputs.recyclable.phosphorus * inputs.nonwoody_fraction.phosphorus,
        },
        .remaining_respiration = inputs.respiration_demand_g_c_per_timestep - consumed_recyclable_carbon,
        .reduced_maximum_height_m = maximum_height_m - f * maximum_height_m,
    };
    inline for (.{ p.residual_before, p.branch_after, p.residual_after, p.reserve_after }) |values| inline for (@typeInfo(Elements).@"struct".fields) |field| {
        const value = @field(values, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidResidualStalkStateUpdateResult;
    };
    inline for (.{ p.remaining_respiration, p.reduced_maximum_height_m }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidResidualStalkStateUpdateResult;
    return p;
}

fn validateTopology(state: State, inputs: Inputs) !usize {
    inline for (.{ inputs.removal_fraction, inputs.respiration_demand_g_c_per_timestep, inputs.phenological_senescence_fraction }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidResidualStalkStateUpdateInput;
    if (inputs.removal_fraction > 1 or inputs.phenological_senescence_fraction > 1) return error.InvalidResidualStalkStateUpdateInput;
    inline for (.{ inputs.recyclable, inputs.woody_fraction, inputs.nonwoody_fraction }) |values| inline for (@typeInfo(Elements).@"struct".fields) |field| {
        const value = @field(values, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidResidualStalkStateUpdateInput;
    };
    inline for (@typeInfo(Elements).@"struct".fields) |field| {
        if (@field(inputs.recyclable, field.name) > @field(Elements{ .carbon = state.residual_stalk_carbon_g_c.*, .nitrogen = state.residual_stalk_nitrogen_g_n.*, .phosphorus = state.residual_stalk_phosphorus_g_p.* }, field.name)) return error.InvalidResidualStalkStateUpdateInput;
        if (@abs(@field(inputs.woody_fraction, field.name) + @field(inputs.nonwoody_fraction, field.name) - 1) > 1e-12) return error.InvalidResidualStalkStateUpdateInput;
    }
    const count = inputs.woody_kinetics.carbon.len;
    if (count == 0) return error.ZeroResidualStalkKineticPools;
    inline for (.{ inputs.woody_kinetics.nitrogen, inputs.woody_kinetics.phosphorus, inputs.stalk_kinetics.carbon, inputs.stalk_kinetics.nitrogen, inputs.stalk_kinetics.phosphorus }) |values| if (values.len != count) return error.ResidualStalkKineticDimensionMismatch;
    inline for (@typeInfo(Litter).@"struct".fields) |field| if (@field(state.litter, field.name).len != count) return error.ResidualStalkKineticDimensionMismatch;
    inline for (.{ inputs.woody_kinetics, inputs.stalk_kinetics }) |kinetics| inline for (@typeInfo(Fractions).@"struct".fields) |field| {
        var total: f64 = 0;
        for (@field(kinetics, field.name)) |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidResidualStalkKineticFraction;
            total += value;
        }
        if (!std.math.isFinite(total) or @abs(total - 1) > 1e-12) return error.InvalidResidualStalkKineticFraction;
    };
    return count;
}

fn additions(state: State, inputs: Inputs, p: Projection, k: usize) [6]f64 {
    _ = state;
    const f = inputs.removal_fraction;
    return .{
        inputs.woody_kinetics.carbon[k] * f * p.residual_before.carbon * inputs.woody_fraction.carbon,
        inputs.woody_kinetics.nitrogen[k] * f * p.residual_before.nitrogen * inputs.woody_fraction.nitrogen,
        inputs.woody_kinetics.phosphorus[k] * f * p.residual_before.phosphorus * inputs.woody_fraction.phosphorus,
        inputs.stalk_kinetics.carbon[k] * f * (p.residual_before.carbon - inputs.recyclable.carbon) * inputs.nonwoody_fraction.carbon,
        inputs.stalk_kinetics.nitrogen[k] * f * (p.residual_before.nitrogen - inputs.recyclable.nitrogen) * inputs.nonwoody_fraction.nitrogen,
        inputs.stalk_kinetics.phosphorus[k] * f * (p.residual_before.phosphorus - inputs.recyclable.phosphorus) * inputs.nonwoody_fraction.phosphorus,
    };
}
fn validateLitter(state: State, inputs: Inputs, p: Projection, k: usize) !void {
    const add = additions(state, inputs, p, k);
    inline for (@typeInfo(Litter).@"struct".fields, 0..) |field, i| {
        const current = @field(state.litter, field.name)[k];
        if (!std.math.isFinite(current) or current < 0 or !std.math.isFinite(add[i]) or add[i] < 0 or !std.math.isFinite(current + add[i])) return error.InvalidResidualStalkLitterResult;
    }
}
fn state_updateLitter(state: State, inputs: Inputs, p: Projection, k: usize) void {
    const add = additions(state, inputs, p, k);
    inline for (@typeInfo(Litter).@"struct".fields, 0..) |field, i| @field(state.litter, field.name)[k] += add[i];
}

fn fixture(heights: []f64, scalars: *[9]f64, litter_store: *[6][2]f64) State {
    return .{ .branch_stalk_carbon_g_c = &scalars[0], .branch_stalk_nitrogen_g_n = &scalars[1], .branch_stalk_phosphorus_g_p = &scalars[2], .residual_stalk_carbon_g_c = &scalars[3], .residual_stalk_nitrogen_g_n = &scalars[4], .residual_stalk_phosphorus_g_p = &scalars[5], .node_height_m = heights, .reserve_carbon_g_c = &scalars[6], .reserve_nitrogen_g_n = &scalars[7], .reserve_phosphorus_g_p = &scalars[8], .litter = .{ .woody_carbon_g_c = &litter_store[0], .woody_nitrogen_g_n = &litter_store[1], .woody_phosphorus_g_p = &litter_store[2], .stalk_carbon_g_c = &litter_store[3], .stalk_nitrogen_g_n = &litter_store[4], .stalk_phosphorus_g_p = &litter_store[5] } };
}
fn testInputs() Inputs {
    const f = &[_]f64{ 0.25, 0.75 };
    return .{ .removal_fraction = 0.5, .recyclable = .{ .carbon = 2, .nitrogen = 0.4, .phosphorus = 0.065 }, .respiration_demand_g_c_per_timestep = 1, .phenological_senescence_fraction = 0, .woody_fraction = .{ .carbon = 0.2, .nitrogen = 0.2, .phosphorus = 0.2 }, .nonwoody_fraction = .{ .carbon = 0.8, .nitrogen = 0.8, .phosphorus = 0.8 }, .woody_kinetics = .{ .carbon = f, .nitrogen = f, .phosphorus = f }, .stalk_kinetics = .{ .carbon = f, .nitrogen = f, .phosphorus = f } };
}

test "residual state_update conserves carbon and caps every runtime node" {
    var heights = [_]f64{ 1, 4, 3, 2, 0.5 };
    var s = [_]f64{ 8, 1, 0.2, 8, 1, 0.2, 0, 0, 0 };
    var litter: [6][2]f64 = @splat(@splat(0));
    const state = fixture(&heights, &s, &litter);
    const result = try publish(state, testInputs());
    try std.testing.expectEqual(@as(f64, 2), result.reduced_maximum_node_height_m);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 2, 2, 0.5 }, &heights);
    try std.testing.expectEqual(@as(f64, 4), s[3]);
    const litter_c = litter[0][0] + litter[0][1] + litter[3][0] + litter[3][1];
    const respired = 1 - result.remaining_respiration_g_c_per_timestep;
    try std.testing.expectApproxEqAbs(@as(f64, 8), s[3] + litter_c + s[6] + respired, 1e-15);
}
test "late invalid height leaves litter and every scalar unchanged" {
    var heights = [_]f64{ 1, std.math.nan(f64) };
    var s = [_]f64{ 8, 1, 0.2, 8, 1, 0.2, 0, 0, 0 };
    var litter: [6][2]f64 = @splat(@splat(0));
    try std.testing.expectError(error.InvalidResidualStalkHeightState, publish(fixture(&heights, &s, &litter), testInputs()));
    try std.testing.expectEqual(@as(f64, 8), s[3]);
    try std.testing.expectEqual(@as(f64, 0), litter[0][0]);
}
test "runtime kinetic mismatch fails atomically" {
    var heights = [_]f64{1};
    var s = [_]f64{ 8, 1, 0.2, 8, 1, 0.2, 0, 0, 0 };
    var litter: [6][2]f64 = @splat(@splat(0));
    var inputs = testInputs();
    inputs.stalk_kinetics.phosphorus = inputs.stalk_kinetics.phosphorus[0..1];
    try std.testing.expectError(error.ResidualStalkKineticDimensionMismatch, publish(fixture(&heights, &s, &litter), inputs));
    try std.testing.expectEqual(@as(f64, 8), s[0]);
}

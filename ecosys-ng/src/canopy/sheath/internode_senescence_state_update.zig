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
    node_height_m: []f64,
    internode_length_m: []f64,
    internode_carbon_g_c: []f64,
    internode_nitrogen_g_n: []f64,
    internode_phosphorus_g_p: []f64,
    reserve_carbon_g_c: *f64,
    reserve_nitrogen_g_n: *f64,
    reserve_phosphorus_g_p: *f64,
    litter: Litter,
};
pub const Inputs = struct {
    selected_node: usize,
    respiration_demand_g_c_per_timestep: f64,
    presence_threshold_g_c: f64,
    phenological_senescence_fraction: f64,
    /// RCSC/RCSN/RCSP: already multiplied by sapwood/stalk C.
    sapwood_recycling: Elements,
    woody_fraction: Elements,
    nonwoody_fraction: Elements,
    woody_kinetics: Fractions,
    stalk_kinetics: Fractions,
};
pub const Result = struct {
    removal_fraction: f64,
    remaining_respiration_g_c_per_timestep: f64,
};

const Projection = struct {
    fraction: f64,
    recyclable: Elements,
    remaining: f64,
    branch: Elements,
    node: Elements,
    height_m: f64,
    length_m: f64,
    reserve: Elements,
};

/// grosub.f lines 3307--3402. Uses already sapwood-scaled RCSC/RCSN/RCSP,
/// publishes woody then stalk litter C/N/P for each runtime kinetic pool,
/// updates branch and selected logical internode state, then reserve C/N/P and
/// remaining respiration. The full transaction is validated before mutation.
pub fn publish(state: State, inputs: Inputs) !Result {
    const count = try validateTopology(state, inputs);
    const p = try project(state, inputs);
    for (0..count) |kinetic| try validateLitterPool(state, inputs, p, kinetic);

    for (0..count) |kinetic| {
        const f = p.fraction;
        const node = inputs.selected_node;
        state.litter.woody_carbon_g_c[kinetic] += inputs.woody_kinetics.carbon[kinetic] * f * state.internode_carbon_g_c[node] * inputs.woody_fraction.carbon;
        state.litter.woody_nitrogen_g_n[kinetic] += inputs.woody_kinetics.nitrogen[kinetic] * f * state.internode_nitrogen_g_n[node] * inputs.woody_fraction.nitrogen;
        state.litter.woody_phosphorus_g_p[kinetic] += inputs.woody_kinetics.phosphorus[kinetic] * f * state.internode_phosphorus_g_p[node] * inputs.woody_fraction.phosphorus;
        state.litter.stalk_carbon_g_c[kinetic] += inputs.stalk_kinetics.carbon[kinetic] * f * (state.internode_carbon_g_c[node] - p.recyclable.carbon) * inputs.nonwoody_fraction.carbon;
        state.litter.stalk_nitrogen_g_n[kinetic] += inputs.stalk_kinetics.nitrogen[kinetic] * f * (state.internode_nitrogen_g_n[node] - p.recyclable.nitrogen) * inputs.nonwoody_fraction.nitrogen;
        state.litter.stalk_phosphorus_g_p[kinetic] += inputs.stalk_kinetics.phosphorus[kinetic] * f * (state.internode_phosphorus_g_p[node] - p.recyclable.phosphorus) * inputs.nonwoody_fraction.phosphorus;
    }
    state.branch_stalk_carbon_g_c.* = p.branch.carbon;
    state.branch_stalk_nitrogen_g_n.* = p.branch.nitrogen;
    state.branch_stalk_phosphorus_g_p.* = p.branch.phosphorus;
    state.node_height_m[inputs.selected_node] = p.height_m;
    state.internode_carbon_g_c[inputs.selected_node] = p.node.carbon;
    state.internode_nitrogen_g_n[inputs.selected_node] = p.node.nitrogen;
    state.internode_phosphorus_g_p[inputs.selected_node] = p.node.phosphorus;
    state.internode_length_m[inputs.selected_node] = p.length_m;
    state.reserve_carbon_g_c.* = p.reserve.carbon;
    state.reserve_nitrogen_g_n.* = p.reserve.nitrogen;
    state.reserve_phosphorus_g_p.* = p.reserve.phosphorus;
    return .{ .removal_fraction = p.fraction, .remaining_respiration_g_c_per_timestep = p.remaining };
}

fn project(state: State, inputs: Inputs) !Projection {
    const n = inputs.selected_node;
    const node: Elements = .{ .carbon = state.internode_carbon_g_c[n], .nitrogen = state.internode_nitrogen_g_n[n], .phosphorus = state.internode_phosphorus_g_p[n] };
    const recyclable: Elements = if (node.carbon > inputs.presence_threshold_g_c) .{
        .carbon = inputs.sapwood_recycling.carbon * node.carbon,
        .nitrogen = node.nitrogen * (inputs.sapwood_recycling.nitrogen + (1 - inputs.sapwood_recycling.nitrogen) * inputs.sapwood_recycling.carbon),
        .phosphorus = node.phosphorus * (inputs.sapwood_recycling.phosphorus + (1 - inputs.sapwood_recycling.phosphorus) * inputs.sapwood_recycling.carbon),
    } else .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 };
    const fraction = if (recyclable.carbon > inputs.presence_threshold_g_c)
        @max(0.0, @min(1.0, inputs.respiration_demand_g_c_per_timestep / recyclable.carbon))
    else
        1.0;
    const consumed = fraction * recyclable.carbon * inputs.nonwoody_fraction.carbon;
    const p: Projection = .{
        .fraction = fraction,
        .recyclable = recyclable,
        .remaining = inputs.respiration_demand_g_c_per_timestep - consumed,
        .branch = .{ .carbon = state.branch_stalk_carbon_g_c.* - fraction * node.carbon, .nitrogen = state.branch_stalk_nitrogen_g_n.* - fraction * node.nitrogen, .phosphorus = state.branch_stalk_phosphorus_g_p.* - fraction * node.phosphorus },
        .node = .{ .carbon = node.carbon - fraction * node.carbon, .nitrogen = node.nitrogen - fraction * node.nitrogen, .phosphorus = node.phosphorus - fraction * node.phosphorus },
        .height_m = state.node_height_m[n] - fraction * state.internode_length_m[n],
        .length_m = state.internode_length_m[n] - fraction * state.internode_length_m[n],
        .reserve = .{
            .carbon = state.reserve_carbon_g_c.* + consumed * inputs.phenological_senescence_fraction,
            .nitrogen = state.reserve_nitrogen_g_n.* + fraction * recyclable.nitrogen * inputs.nonwoody_fraction.nitrogen,
            .phosphorus = state.reserve_phosphorus_g_p.* + fraction * recyclable.phosphorus * inputs.nonwoody_fraction.phosphorus,
        },
    };
    inline for (@typeInfo(Projection).@"struct".fields) |field| if (field.type == f64) {
        const value = @field(p, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidInternodeSenescenceResult;
    };
    inline for (.{ p.recyclable, p.branch, p.node, p.reserve }) |values| inline for (@typeInfo(Elements).@"struct".fields) |field| {
        const value = @field(values, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidInternodeSenescenceResult;
    };
    return p;
}

fn validateTopology(state: State, inputs: Inputs) !usize {
    const nodes = state.internode_carbon_g_c.len;
    inline for (.{ state.internode_nitrogen_g_n, state.internode_phosphorus_g_p, state.internode_length_m, state.node_height_m }) |v| if (v.len != nodes) return error.InternodeSenescenceDimensionMismatch;
    if (inputs.selected_node >= nodes) return error.InternodeSenescenceNodeIndexOutOfBounds;
    const count = inputs.woody_kinetics.carbon.len;
    if (count == 0) return error.ZeroInternodeSenescenceKineticPools;
    inline for (.{ inputs.woody_kinetics.nitrogen, inputs.woody_kinetics.phosphorus, inputs.stalk_kinetics.carbon, inputs.stalk_kinetics.nitrogen, inputs.stalk_kinetics.phosphorus }) |v| if (v.len != count) return error.InternodeSenescenceKineticDimensionMismatch;
    inline for (@typeInfo(Litter).@"struct".fields) |field| if (@field(state.litter, field.name).len != count) return error.InternodeSenescenceKineticDimensionMismatch;
    inline for (.{ inputs.respiration_demand_g_c_per_timestep, inputs.presence_threshold_g_c, inputs.phenological_senescence_fraction }) |v| if (!std.math.isFinite(v) or v < 0) return error.InvalidInternodeSenescenceInput;
    if (inputs.phenological_senescence_fraction > 1) return error.InvalidInternodeSenescenceInput;
    inline for (.{ inputs.sapwood_recycling, inputs.woody_fraction, inputs.nonwoody_fraction }) |values| inline for (@typeInfo(Elements).@"struct".fields) |field| {
        const v = @field(values, field.name);
        if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidInternodeSenescenceInput;
    };
    inline for (@typeInfo(Elements).@"struct".fields) |field| if (@abs(@field(inputs.woody_fraction, field.name) + @field(inputs.nonwoody_fraction, field.name) - 1) > 1e-12) return error.InvalidInternodeSenescenceInput;
    inline for (.{ inputs.woody_kinetics, inputs.stalk_kinetics }) |kinetics| inline for (@typeInfo(Fractions).@"struct".fields) |field| {
        var total: f64 = 0;
        for (@field(kinetics, field.name)) |v| {
            if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidInternodeSenescenceKineticFraction;
            total += v;
        }
        if (!std.math.isFinite(total) or @abs(total - 1) > 1e-12) return error.InvalidInternodeSenescenceKineticFraction;
    };
    return count;
}

fn validateLitterPool(state: State, inputs: Inputs, p: Projection, k: usize) !void {
    const n = inputs.selected_node;
    const additions = [_]f64{
        inputs.woody_kinetics.carbon[k] * p.fraction * state.internode_carbon_g_c[n] * inputs.woody_fraction.carbon,
        inputs.woody_kinetics.nitrogen[k] * p.fraction * state.internode_nitrogen_g_n[n] * inputs.woody_fraction.nitrogen,
        inputs.woody_kinetics.phosphorus[k] * p.fraction * state.internode_phosphorus_g_p[n] * inputs.woody_fraction.phosphorus,
        inputs.stalk_kinetics.carbon[k] * p.fraction * (state.internode_carbon_g_c[n] - p.recyclable.carbon) * inputs.nonwoody_fraction.carbon,
        inputs.stalk_kinetics.nitrogen[k] * p.fraction * (state.internode_nitrogen_g_n[n] - p.recyclable.nitrogen) * inputs.nonwoody_fraction.nitrogen,
        inputs.stalk_kinetics.phosphorus[k] * p.fraction * (state.internode_phosphorus_g_p[n] - p.recyclable.phosphorus) * inputs.nonwoody_fraction.phosphorus,
    };
    inline for (@typeInfo(Litter).@"struct".fields, 0..) |field, i| {
        const current = @field(state.litter, field.name)[k];
        if (!std.math.isFinite(current) or current < 0 or !std.math.isFinite(current + additions[i]) or additions[i] < 0) return error.InvalidInternodeSenescenceLitterResult;
    }
}

fn fixture(node_c: *[3]f64, node_n: *[3]f64, node_p: *[3]f64, lengths: *[3]f64, heights: *[3]f64, branch: *[6]f64, litter_store: *[6][2]f64) State {
    return .{ .branch_stalk_carbon_g_c = &branch[0], .branch_stalk_nitrogen_g_n = &branch[1], .branch_stalk_phosphorus_g_p = &branch[2], .node_height_m = heights, .internode_length_m = lengths, .internode_carbon_g_c = node_c, .internode_nitrogen_g_n = node_n, .internode_phosphorus_g_p = node_p, .reserve_carbon_g_c = &branch[3], .reserve_nitrogen_g_n = &branch[4], .reserve_phosphorus_g_p = &branch[5], .litter = .{ .woody_carbon_g_c = &litter_store[0], .woody_nitrogen_g_n = &litter_store[1], .woody_phosphorus_g_p = &litter_store[2], .stalk_carbon_g_c = &litter_store[3], .stalk_nitrogen_g_n = &litter_store[4], .stalk_phosphorus_g_p = &litter_store[5] } };
}
fn testInputs() Inputs {
    const f = &[_]f64{ 0.25, 0.75 };
    return .{ .selected_node = 2, .respiration_demand_g_c_per_timestep = 1, .presence_threshold_g_c = 0, .phenological_senescence_fraction = 0, .sapwood_recycling = .{ .carbon = 0.25, .nitrogen = 0.2, .phosphorus = 0.1 }, .woody_fraction = .{ .carbon = 0.2, .nitrogen = 0.2, .phosphorus = 0.2 }, .nonwoody_fraction = .{ .carbon = 0.8, .nitrogen = 0.8, .phosphorus = 0.8 }, .woody_kinetics = .{ .carbon = f, .nitrogen = f, .phosphorus = f }, .stalk_kinetics = .{ .carbon = f, .nitrogen = f, .phosphorus = f } };
}

test "scaled recycling is applied once and state_update conserves selected node carbon" {
    var c = [_]f64{ 0, 0, 8 };
    var n = [_]f64{ 0, 0, 1 };
    var p = [_]f64{ 0, 0, 0.2 };
    var len = [_]f64{ 0, 0, 2 };
    var h = [_]f64{ 0, 0, 3 };
    var branch = [_]f64{ 8, 1, 0.2, 0, 0, 0 };
    var litter: [6][2]f64 = @splat(@splat(0));
    const state = fixture(&c, &n, &p, &len, &h, &branch, &litter);
    const result = try publish(state, testInputs());
    try std.testing.expectEqual(@as(f64, 0.5), result.removal_fraction);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), result.remaining_respiration_g_c_per_timestep, 1e-15);
    try std.testing.expectEqual(@as(f64, 4), c[2]);
    try std.testing.expectEqual(@as(f64, 2), h[2]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.16), branch[4], 1e-15);
    const litter_carbon = litter[0][0] + litter[0][1] + litter[3][0] + litter[3][1];
    const respired_carbon = 1 - result.remaining_respiration_g_c_per_timestep;
    try std.testing.expectApproxEqAbs(@as(f64, 8), c[2] + litter_carbon + respired_carbon, 1e-15);
}

test "late litter overflow leaves all state unchanged" {
    var c = [_]f64{ 0, 0, 8 };
    var n = [_]f64{ 0, 0, 1 };
    var p = [_]f64{ 0, 0, 0.2 };
    var len = [_]f64{ 0, 0, 2 };
    var h = [_]f64{ 0, 0, 3 };
    var branch = [_]f64{ 8, 1, 0.2, 0, 0, 0 };
    var litter: [6][2]f64 = @splat(@splat(0));
    litter[5][1] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidInternodeSenescenceLitterResult, publish(fixture(&c, &n, &p, &len, &h, &branch, &litter), testInputs()));
    try std.testing.expectEqual(@as(f64, 8), c[2]);
    try std.testing.expectEqual(@as(f64, 8), branch[0]);
    try std.testing.expectEqual(@as(f64, 0), litter[0][0]);
}

test "below-threshold source ELSE routes the entire internode without recycling" {
    var c = [_]f64{ 0, 0, 0.01 };
    var n = [_]f64{ 0, 0, 0.002 };
    var p = [_]f64{ 0, 0, 0.0004 };
    var len = [_]f64{ 0, 0, 0.5 };
    var h = [_]f64{ 0, 0, 1 };
    var branch = [_]f64{ 0.01, 0.002, 0.0004, 0, 0, 0 };
    var litter: [6][2]f64 = @splat(@splat(0));
    var inputs = testInputs();
    inputs.presence_threshold_g_c = 0.01;
    inputs.respiration_demand_g_c_per_timestep = 2;
    const result = try publish(fixture(&c, &n, &p, &len, &h, &branch, &litter), inputs);
    try std.testing.expectEqual(@as(f64, 1), result.removal_fraction);
    try std.testing.expectEqual(@as(f64, 2), result.remaining_respiration_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 0), c[2]);
    try std.testing.expectEqual(@as(f64, 0.5), h[2]);
    try std.testing.expectEqual(@as(f64, 0), branch[3]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), litter[0][0] + litter[0][1] + litter[3][0] + litter[3][1], 1e-15);
}

test "runtime logical node and kinetic topology fail explicitly" {
    var c = [_]f64{ 0, 0, 0 };
    var n = [_]f64{ 0, 0, 0 };
    var p = [_]f64{ 0, 0, 0 };
    var len = [_]f64{ 0, 0, 0 };
    var h = [_]f64{ 0, 0, 0 };
    var branch = [_]f64{0} ** 6;
    var litter: [6][2]f64 = @splat(@splat(0));
    var inputs = testInputs();
    inputs.selected_node = 3;
    try std.testing.expectError(error.InternodeSenescenceNodeIndexOutOfBounds, publish(fixture(&c, &n, &p, &len, &h, &branch, &litter), inputs));
}

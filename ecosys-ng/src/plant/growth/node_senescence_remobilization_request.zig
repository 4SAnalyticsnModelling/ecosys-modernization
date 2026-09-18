const std = @import("std");

pub const NodeState = struct {
    leaf_carbon_g_c: []const f64,
    sheath_carbon_g_c: []const f64,
    leaf_nitrogen_g_n: []const f64,
    leaf_phosphorus_g_p: []const f64,
};

pub const RecyclingFractions = struct {
    carbon: f64,
    nitrogen: f64,
    phosphorus: f64,
};

pub const Request = struct {
    leaf_senescence_respiration_g_c_per_timestep: f64,
    sheath_senescence_respiration_g_c_per_timestep: f64,
    remobilizable_leaf_carbon_g_c: f64,
    remobilizable_leaf_nitrogen_g_n: f64,
    remobilizable_leaf_phosphorus_g_p: f64,
    leaf_mass_removal_fraction: f64,
    leaf_area_removal_fraction: f64,
};

/// grosub.f lines 2908--2909. Divides total branch senescence respiration
/// equally among the runtime-configured remobilization passes (KSNC/XKSNC).
pub fn respirationPerPass(
    total_senescence_respiration_g_c_per_timestep: f64,
    remobilization_pass_count: usize,
) !f64 {
    if (!std.math.isFinite(total_senescence_respiration_g_c_per_timestep) or
        total_senescence_respiration_g_c_per_timestep < 0)
        return error.InvalidNodeSenescenceRespiration;
    if (remobilization_pass_count == 0)
        return error.ZeroNodeSenescencePassCount;
    const result = total_senescence_respiration_g_c_per_timestep /
        @as(f64, @floatFromInt(remobilization_pass_count));
    if (!std.math.isFinite(result)) return error.NonFiniteNodeSenescencePassRespiration;
    return result;
}

/// grosub.f lines 2910--2944. For one logical runtime node, splits the current
/// pass respiration between leaf and sheath in their carbon-mass proportions,
/// calculates leaf C/N/P available for recycling, then limits removal by the
/// carbon required. The source's later litter and state updates remain separate.
pub fn calculate(
    state: NodeState,
    selected_node: usize,
    pass_senescence_respiration_g_c_per_timestep: f64,
    leaf_presence_threshold_g_c: f64,
    recycling: RecyclingFractions,
) !Request {
    const node_count = state.leaf_carbon_g_c.len;
    inline for (.{ state.sheath_carbon_g_c, state.leaf_nitrogen_g_n, state.leaf_phosphorus_g_p }) |values|
        if (values.len != node_count)
            return error.NodeSenescenceRequestDimensionMismatch;
    if (selected_node >= node_count)
        return error.NodeSenescenceRequestIndexOutOfBounds;
    inline for (.{ pass_senescence_respiration_g_c_per_timestep, leaf_presence_threshold_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidNodeSenescenceRequestInput;
    inline for (@typeInfo(RecyclingFractions).@"struct".fields) |field| {
        const value = @field(recycling, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidNodeSenescenceRecyclingFraction;
    }

    const leaf_carbon_g_c = state.leaf_carbon_g_c[selected_node];
    const sheath_carbon_g_c = state.sheath_carbon_g_c[selected_node];
    const leaf_nitrogen_g_n = state.leaf_nitrogen_g_n[selected_node];
    const leaf_phosphorus_g_p = state.leaf_phosphorus_g_p[selected_node];
    inline for (.{ leaf_carbon_g_c, sheath_carbon_g_c, leaf_nitrogen_g_n, leaf_phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidNodeSenescenceRequestState;

    var result: Request = .{
        .leaf_senescence_respiration_g_c_per_timestep = 0,
        .sheath_senescence_respiration_g_c_per_timestep = 0,
        .remobilizable_leaf_carbon_g_c = 0,
        .remobilizable_leaf_nitrogen_g_n = 0,
        .remobilizable_leaf_phosphorus_g_p = 0,
        .leaf_mass_removal_fraction = 0,
        .leaf_area_removal_fraction = 0,
    };
    if (leaf_carbon_g_c <= leaf_presence_threshold_g_c) return result;

    const leaf_share = leaf_carbon_g_c / (leaf_carbon_g_c + sheath_carbon_g_c);
    result.leaf_senescence_respiration_g_c_per_timestep =
        leaf_share * pass_senescence_respiration_g_c_per_timestep;
    result.sheath_senescence_respiration_g_c_per_timestep =
        pass_senescence_respiration_g_c_per_timestep -
        result.leaf_senescence_respiration_g_c_per_timestep;
    result.remobilizable_leaf_carbon_g_c = leaf_carbon_g_c * recycling.carbon;
    result.remobilizable_leaf_nitrogen_g_n = leaf_nitrogen_g_n *
        (recycling.nitrogen + (1.0 - recycling.nitrogen) * recycling.carbon);
    result.remobilizable_leaf_phosphorus_g_p = leaf_phosphorus_g_p *
        (recycling.phosphorus + (1.0 - recycling.phosphorus) * recycling.carbon);
    result.leaf_mass_removal_fraction = if (result.remobilizable_leaf_carbon_g_c > leaf_presence_threshold_g_c)
        @max(0.0, @min(1.0, result.leaf_senescence_respiration_g_c_per_timestep /
            result.remobilizable_leaf_carbon_g_c))
    else
        1.0;
    result.leaf_area_removal_fraction = result.leaf_mass_removal_fraction;

    inline for (@typeInfo(Request).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0)
            return error.InvalidNodeSenescenceRequestResult;
    return result;
}

const sample_recycling: RecyclingFractions = .{ .carbon = 0.5, .nitrogen = 0.6, .phosphorus = 0.7 };

test "GROSUB pass and organ split preserve source operation order" {
    const per_pass = try respirationPerPass(12, 3);
    const result = try calculate(.{
        .leaf_carbon_g_c = &.{ 1, 6 },
        .sheath_carbon_g_c = &.{ 1, 2 },
        .leaf_nitrogen_g_n = &.{ 0.1, 0.6 },
        .leaf_phosphorus_g_p = &.{ 0.01, 0.06 },
    }, 1, per_pass, 1.0e-9, sample_recycling);
    try std.testing.expectEqual(@as(f64, 3), result.leaf_senescence_respiration_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 1), result.sheath_senescence_respiration_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 3), result.remobilizable_leaf_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1), result.leaf_mass_removal_fraction);
}

test "partial leaf demand uses remobilizable carbon denominator" {
    const result = try calculate(.{
        .leaf_carbon_g_c = &.{8},
        .sheath_carbon_g_c = &.{2},
        .leaf_nitrogen_g_n = &.{1},
        .leaf_phosphorus_g_p = &.{0.1},
    }, 0, 2, 0, sample_recycling);
    try std.testing.expectApproxEqAbs(@as(f64, 1.6), result.leaf_senescence_respiration_g_c_per_timestep, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), result.leaf_mass_removal_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), result.remobilizable_leaf_nitrogen_g_n, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.085), result.remobilizable_leaf_phosphorus_g_p, 1.0e-15);
}

test "logical runtime node beyond legacy ring is addressed directly" {
    var leaf: [31]f64 = @splat(0);
    var sheath: [31]f64 = @splat(0);
    var nitrogen: [31]f64 = @splat(0);
    var phosphorus: [31]f64 = @splat(0);
    leaf[30] = 4;
    sheath[30] = 4;
    const result = try calculate(.{
        .leaf_carbon_g_c = &leaf,
        .sheath_carbon_g_c = &sheath,
        .leaf_nitrogen_g_n = &nitrogen,
        .leaf_phosphorus_g_p = &phosphorus,
    }, 30, 2, 0, sample_recycling);
    try std.testing.expectEqual(@as(f64, 1), result.leaf_senescence_respiration_g_c_per_timestep);
}

test "absent leaf leaves the entire request zero" {
    const result = try calculate(.{
        .leaf_carbon_g_c = &.{0},
        .sheath_carbon_g_c = &.{5},
        .leaf_nitrogen_g_n = &.{0},
        .leaf_phosphorus_g_p = &.{0},
    }, 0, 3, 0, sample_recycling);
    inline for (@typeInfo(Request).@"struct".fields) |field|
        try std.testing.expectEqual(@as(f64, 0), @field(result, field.name));
}

test "runtime dimensions indexes pass count and non-finite values fail" {
    try std.testing.expectError(error.ZeroNodeSenescencePassCount, respirationPerPass(1, 0));
    const state: NodeState = .{
        .leaf_carbon_g_c = &.{1},
        .sheath_carbon_g_c = &.{1},
        .leaf_nitrogen_g_n = &.{1},
        .leaf_phosphorus_g_p = &.{1},
    };
    try std.testing.expectError(error.NodeSenescenceRequestIndexOutOfBounds, calculate(state, 1, 1, 0, sample_recycling));
    var malformed = state;
    malformed.leaf_nitrogen_g_n = &.{};
    try std.testing.expectError(error.NodeSenescenceRequestDimensionMismatch, calculate(malformed, 0, 1, 0, sample_recycling));
    try std.testing.expectError(error.InvalidNodeSenescenceRequestInput, calculate(state, 0, std.math.nan(f64), 0, sample_recycling));
}

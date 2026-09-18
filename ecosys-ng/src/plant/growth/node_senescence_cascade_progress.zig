const std = @import("std");

pub const ReserveState = struct {
    reserve_carbon_g_c: *f64,
};

pub const ReserveResult = struct {
    excess_maintenance_respiration_g_c_per_timestep: f64,
    reserve_carbon_respired_g_c_per_timestep: f64,
    requirement_met: bool,
};

/// grosub.f lines 2908, 2910, and 3255. KN advances once after every outer
/// remobilization pass. If it advances beyond KVSTG, the next node loop is
/// empty; the last node must not be clamped and processed again.
pub fn firstNodeForPass(
    initial_first_node: usize,
    final_node_inclusive: usize,
    zero_based_pass: usize,
) !?usize {
    if (initial_first_node > final_node_inclusive)
        return error.InvalidNodeSenescenceRange;
    const first = std.math.add(usize, initial_first_node, zero_based_pass) catch
        return error.NodeSenescenceCursorOverflow;
    if (first > final_node_inclusive) return null;
    return first;
}

/// grosub.f lines 3256--3268. Converts the remaining total node demand SNCT to
/// excess-maintenance demand SNCR in exact multiplication order. Reserve C is
/// consumed only when WTRSVB is strictly greater than SNCR; equality and an
/// insufficient reserve leave both values unchanged for the stalk cascade.
pub fn applyReserveFallback(
    state: ReserveState,
    remaining_node_respiration_g_c_per_timestep: f64,
    phenological_senescence_fraction: f64,
) !ReserveResult {
    inline for (.{
        state.reserve_carbon_g_c.*,
        remaining_node_respiration_g_c_per_timestep,
        phenological_senescence_fraction,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteNodeSenescenceReserveInput;
    if (state.reserve_carbon_g_c.* < 0 or
        remaining_node_respiration_g_c_per_timestep < 0 or
        phenological_senescence_fraction < 0 or phenological_senescence_fraction > 1)
        return error.InvalidNodeSenescenceReserveInput;

    const excess_maintenance_g_c_per_timestep =
        remaining_node_respiration_g_c_per_timestep *
        (1.0 - phenological_senescence_fraction);
    if (!std.math.isFinite(excess_maintenance_g_c_per_timestep) or
        excess_maintenance_g_c_per_timestep < 0)
        return error.InvalidNodeSenescenceReserveResult;

    if (state.reserve_carbon_g_c.* > excess_maintenance_g_c_per_timestep) {
        const reserve_after_g_c = state.reserve_carbon_g_c.* -
            excess_maintenance_g_c_per_timestep;
        if (!std.math.isFinite(reserve_after_g_c) or reserve_after_g_c < 0)
            return error.InvalidNodeSenescenceReserveResult;
        state.reserve_carbon_g_c.* = reserve_after_g_c;
        return .{
            .excess_maintenance_respiration_g_c_per_timestep = 0,
            .reserve_carbon_respired_g_c_per_timestep = excess_maintenance_g_c_per_timestep,
            .requirement_met = true,
        };
    }
    return .{
        .excess_maintenance_respiration_g_c_per_timestep = excess_maintenance_g_c_per_timestep,
        .reserve_carbon_respired_g_c_per_timestep = 0,
        .requirement_met = false,
    };
}

test "KN advancement produces empty loops instead of repeating final node" {
    try std.testing.expectEqual(@as(?usize, 4), try firstNodeForPass(4, 5, 0));
    try std.testing.expectEqual(@as(?usize, 5), try firstNodeForPass(4, 5, 1));
    try std.testing.expectEqual(@as(?usize, null), try firstNodeForPass(4, 5, 2));
    try std.testing.expectEqual(@as(?usize, null), try firstNodeForPass(4, 5, 100));
}

test "reserve strictly exceeding SNCR satisfies requirement" {
    var reserve_g_c: f64 = 10;
    const result = try applyReserveFallback(
        .{ .reserve_carbon_g_c = &reserve_g_c },
        4,
        0.25,
    );
    try std.testing.expectEqual(@as(f64, 3), result.reserve_carbon_respired_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 0), result.excess_maintenance_respiration_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 7), reserve_g_c);
    try std.testing.expect(result.requirement_met);
}

test "reserve equal to SNCR is deliberately not consumed" {
    var reserve_g_c: f64 = 3;
    const result = try applyReserveFallback(
        .{ .reserve_carbon_g_c = &reserve_g_c },
        4,
        0.25,
    );
    try std.testing.expectEqual(@as(f64, 3), result.excess_maintenance_respiration_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 0), result.reserve_carbon_respired_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 3), reserve_g_c);
    try std.testing.expect(!result.requirement_met);
}

test "insufficient reserve remains intact for the following stalk gate" {
    var reserve_g_c: f64 = 2;
    const result = try applyReserveFallback(
        .{ .reserve_carbon_g_c = &reserve_g_c },
        4,
        0.25,
    );
    try std.testing.expectEqual(@as(f64, 3), result.excess_maintenance_respiration_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 2), reserve_g_c);
    try std.testing.expect(!result.requirement_met);
}

test "invalid cursor and reserve inputs fail without mutation" {
    try std.testing.expectError(error.InvalidNodeSenescenceRange, firstNodeForPass(2, 1, 0));
    try std.testing.expectError(error.NodeSenescenceCursorOverflow, firstNodeForPass(std.math.maxInt(usize), std.math.maxInt(usize), 1));
    var reserve_g_c: f64 = 5;
    try std.testing.expectError(
        error.NonFiniteNodeSenescenceReserveInput,
        applyReserveFallback(.{ .reserve_carbon_g_c = &reserve_g_c }, std.math.nan(f64), 0),
    );
    try std.testing.expectEqual(@as(f64, 5), reserve_g_c);
    try std.testing.expectError(
        error.InvalidNodeSenescenceReserveInput,
        applyReserveFallback(.{ .reserve_carbon_g_c = &reserve_g_c }, 1, 2),
    );
    try std.testing.expectEqual(@as(f64, 5), reserve_g_c);
}

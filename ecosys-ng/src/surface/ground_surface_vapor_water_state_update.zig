const std = @import("std");

/// Applies two already accepted, disjoint producer lanes.  This is the
/// production path: litter and topsoil may exchange in opposite directions in
/// one substep and neither is allowed to borrow the other owner's water.
pub const AcceptedLaneContext = struct {
    time_step_hours: f64,
    accepted_litter_liquid_water_change_m3: []const f64,
    accepted_topsoil_liquid_water_change_m3: []const f64,
    litter_liquid_water_m3: []f64,
    soil_matrix_liquid_water_m3: []f64,
    active_soil_layer_count: []const usize,
    soil_layer_capacity: usize,
    evaporation_m3_per_h: []f64,
    condensation_m3_per_h: []f64,
    litter_liquid_water_change_m3: []f64,
    topsoil_liquid_water_change_m3: []f64,
    litter_evaporation_m3: []f64,
    topsoil_evaporation_m3: []f64,
    litter_condensation_m3: []f64,
    topsoil_condensation_m3: []f64,
};

pub fn state_updateAcceptedLanes(context: AcceptedLaneContext) !void {
    const cells = context.litter_liquid_water_m3.len;
    if (cells == 0 or context.soil_layer_capacity == 0 or
        context.soil_matrix_liquid_water_m3.len != cells * context.soil_layer_capacity)
        return error.GroundSurfaceVaporWaterDimensionMismatch;
    inline for (.{
        context.accepted_litter_liquid_water_change_m3,
        context.accepted_topsoil_liquid_water_change_m3,
        context.active_soil_layer_count,
        context.evaporation_m3_per_h,
        context.condensation_m3_per_h,
        context.litter_liquid_water_change_m3,
        context.topsoil_liquid_water_change_m3,
        context.litter_evaporation_m3,
        context.topsoil_evaporation_m3,
        context.litter_condensation_m3,
        context.topsoil_condensation_m3,
    }) |values| if (values.len != cells)
        return error.GroundSurfaceVaporWaterDimensionMismatch;
    if (!std.math.isFinite(context.time_step_hours) or
        context.time_step_hours <= 0 or context.time_step_hours > 1)
        return error.InvalidGroundSurfaceVaporTimestep;

    // Validate every cell before publishing any state or diagnostic.
    for (0..cells) |cell| {
        if (context.active_soil_layer_count[cell] == 0 or
            context.active_soil_layer_count[cell] > context.soil_layer_capacity)
            return error.InvalidGroundSurfaceSoilLayerCount;
        const topsoil = cell * context.soil_layer_capacity;
        const litter_change = context.accepted_litter_liquid_water_change_m3[cell];
        const soil_change = context.accepted_topsoil_liquid_water_change_m3[cell];
        inline for (.{ litter_change, soil_change, context.litter_liquid_water_m3[cell], context.soil_matrix_liquid_water_m3[topsoil] }) |value|
            if (!std.math.isFinite(value)) return error.InvalidGroundSurfaceVaporWaterInput;
        if (context.litter_liquid_water_m3[cell] < 0 or
            context.soil_matrix_liquid_water_m3[topsoil] < 0)
            return error.InvalidGroundSurfaceVaporWaterInput;
        if (litter_change < -context.litter_liquid_water_m3[cell] or
            soil_change < -context.soil_matrix_liquid_water_m3[topsoil])
            return error.InsufficientGroundSurfaceLiquidWater;
    }

    for (0..cells) |cell| {
        const topsoil = cell * context.soil_layer_capacity;
        const litter_change = context.accepted_litter_liquid_water_change_m3[cell];
        const soil_change = context.accepted_topsoil_liquid_water_change_m3[cell];
        const litter_evaporation = @max(0, -litter_change);
        const soil_evaporation = @max(0, -soil_change);
        const litter_condensation = @max(0, litter_change);
        const soil_condensation = @max(0, soil_change);
        context.litter_liquid_water_m3[cell] += litter_change;
        context.soil_matrix_liquid_water_m3[topsoil] += soil_change;
        context.litter_liquid_water_change_m3[cell] = litter_change;
        context.topsoil_liquid_water_change_m3[cell] = soil_change;
        context.evaporation_m3_per_h[cell] =
            (litter_evaporation + soil_evaporation) / context.time_step_hours;
        context.condensation_m3_per_h[cell] =
            (litter_condensation + soil_condensation) / context.time_step_hours;
        context.litter_evaporation_m3[cell] = litter_evaporation;
        context.topsoil_evaporation_m3[cell] = soil_evaporation;
        context.litter_condensation_m3[cell] = litter_condensation;
        context.topsoil_condensation_m3[cell] = soil_condensation;
    }
}

test "accepted disjoint lanes retain opposing gross owners and close locally" {
    var litter = [_]f64{1};
    var soil = [_]f64{2};
    var evaporation = [_]f64{0};
    var condensation = [_]f64{0};
    var litter_change = [_]f64{0};
    var soil_change = [_]f64{0};
    var litter_evaporation = [_]f64{0};
    var soil_evaporation = [_]f64{0};
    var litter_condensation = [_]f64{0};
    var soil_condensation = [_]f64{0};
    try state_updateAcceptedLanes(.{
        .time_step_hours = 0.5,
        .accepted_litter_liquid_water_change_m3 = &.{-0.2},
        .accepted_topsoil_liquid_water_change_m3 = &.{0.3},
        .litter_liquid_water_m3 = &litter,
        .soil_matrix_liquid_water_m3 = &soil,
        .active_soil_layer_count = &.{1},
        .soil_layer_capacity = 1,
        .evaporation_m3_per_h = &evaporation,
        .condensation_m3_per_h = &condensation,
        .litter_liquid_water_change_m3 = &litter_change,
        .topsoil_liquid_water_change_m3 = &soil_change,
        .litter_evaporation_m3 = &litter_evaporation,
        .topsoil_evaporation_m3 = &soil_evaporation,
        .litter_condensation_m3 = &litter_condensation,
        .topsoil_condensation_m3 = &soil_condensation,
    });
    try std.testing.expectEqual(@as(f64, 0.8), litter[0]);
    try std.testing.expectEqual(@as(f64, 2.3), soil[0]);
    try std.testing.expectEqual(@as(f64, 0.4), evaporation[0]);
    try std.testing.expectEqual(@as(f64, 0.6), condensation[0]);
    try std.testing.expectEqual(@as(f64, 0.2), litter_evaporation[0]);
    try std.testing.expectEqual(@as(f64, 0.3), soil_condensation[0]);
    try std.testing.expectApproxEqAbs(
        (litter[0] - 1) + (soil[0] - 2),
        (condensation[0] - evaporation[0]) * 0.5,
        1e-14,
    );
}

test "accepted lane failure leaves all state and diagnostics unchanged" {
    var litter = [_]f64{ 1, 1 };
    var soil = [_]f64{ 2, 2 };
    var output = [_]f64{ 9, 9 };
    try std.testing.expectError(error.InsufficientGroundSurfaceLiquidWater, state_updateAcceptedLanes(.{
        .time_step_hours = 1,
        .accepted_litter_liquid_water_change_m3 = &.{ -0.5, -2 },
        .accepted_topsoil_liquid_water_change_m3 = &.{ 0, 0 },
        .litter_liquid_water_m3 = &litter,
        .soil_matrix_liquid_water_m3 = &soil,
        .active_soil_layer_count = &.{ 1, 1 },
        .soil_layer_capacity = 1,
        .evaporation_m3_per_h = &output,
        .condensation_m3_per_h = &output,
        .litter_liquid_water_change_m3 = &output,
        .topsoil_liquid_water_change_m3 = &output,
        .litter_evaporation_m3 = &output,
        .topsoil_evaporation_m3 = &output,
        .litter_condensation_m3 = &output,
        .topsoil_condensation_m3 = &output,
    }));
    try std.testing.expectEqualSlices(f64, &.{ 1, 1 }, &litter);
    try std.testing.expectEqualSlices(f64, &.{ 2, 2 }, &soil);
    try std.testing.expectEqualSlices(f64, &.{ 9, 9 }, &output);
}

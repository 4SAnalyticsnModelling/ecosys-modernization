const std = @import("std");

pub const SpecificInternodeLength = enum { zero, positive };

pub const Allocation = struct {
    radius_m: f64,
    surface_area_m2: f64,
    sapwood_carbon_g_c: f64,
    layer_stalk_area_m2: []const f64,
};

pub const State = struct {
    sapwood_carbon_g_c: *f64,
    layer_stalk_area_m2: []f64,
};

pub const Inputs = struct {
    canopy_emerged: bool,
    latest_internode_height_m: f64,
    specific_internode_length: SpecificInternodeLength,
    retained_live_stalk_carbon_g_c: f64,
    allocation: ?Allocation,
};

pub const Result = struct {
    allocation_published: bool,
    radius_m: f64,
    surface_area_m2: f64,
};

/// grosub.f lines 3912--3994 around allocateStalkAcrossCanopyLayers. Publishes
/// its calculated sapwood and layer areas only for an emerged canopy with a
/// positive latest internode. Both source fallback branches set sapwood from
/// SNL1/WTLSB and clear every runtime canopy layer.
pub fn publish(state: State, inputs: Inputs) !Result {
    inline for (.{ inputs.latest_internode_height_m, inputs.retained_live_stalk_carbon_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidStalkLayerStateUpdateInput;
    if (!std.math.isFinite(state.sapwood_carbon_g_c.*) or state.sapwood_carbon_g_c.* < 0)
        return error.InvalidStalkLayerStateUpdateState;

    const allocate = inputs.canopy_emerged and inputs.latest_internode_height_m > 0;
    if (allocate) {
        const allocation = inputs.allocation orelse return error.MissingStalkLayerAllocation;
        if (allocation.layer_stalk_area_m2.len != state.layer_stalk_area_m2.len)
            return error.StalkLayerStateUpdateDimensionMismatch;
        inline for (.{ allocation.radius_m, allocation.surface_area_m2, allocation.sapwood_carbon_g_c }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidStalkLayerAllocation;
        for (allocation.layer_stalk_area_m2) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidStalkLayerAllocation;

        state.sapwood_carbon_g_c.* = allocation.sapwood_carbon_g_c;
        @memcpy(state.layer_stalk_area_m2, allocation.layer_stalk_area_m2);
        return .{ .allocation_published = true, .radius_m = allocation.radius_m, .surface_area_m2 = allocation.surface_area_m2 };
    }

    state.sapwood_carbon_g_c.* = if (inputs.specific_internode_length == .positive)
        0
    else
        inputs.retained_live_stalk_carbon_g_c;
    @memset(state.layer_stalk_area_m2, 0);
    return .{ .allocation_published = false, .radius_m = 0, .surface_area_m2 = 0 };
}

test "emerged positive internode publishes existing allocation in layer order" {
    var sapwood: f64 = 1;
    var layers = [_]f64{ 9, 9, 9 };
    const result = try publish(.{ .sapwood_carbon_g_c = &sapwood, .layer_stalk_area_m2 = &layers }, .{
        .canopy_emerged = true,
        .latest_internode_height_m = 2,
        .specific_internode_length = .zero,
        .retained_live_stalk_carbon_g_c = 7,
        .allocation = .{ .radius_m = 0.1, .surface_area_m2 = 3, .sapwood_carbon_g_c = 4, .layer_stalk_area_m2 = &.{ 0.5, 1, 1.5 } },
    });
    try std.testing.expect(result.allocation_published);
    try std.testing.expectEqual(@as(f64, 4), sapwood);
    try std.testing.expectEqualSlices(f64, &.{ 0.5, 1, 1.5 }, &layers);
}

test "zero internode with zero SNL1 retains WTLSB and clears runtime layers" {
    var sapwood: f64 = 1;
    var layers: [37]f64 = @splat(9);
    const result = try publish(.{ .sapwood_carbon_g_c = &sapwood, .layer_stalk_area_m2 = &layers }, .{
        .canopy_emerged = true,
        .latest_internode_height_m = 0,
        .specific_internode_length = .zero,
        .retained_live_stalk_carbon_g_c = 7,
        .allocation = null,
    });
    try std.testing.expect(!result.allocation_published);
    try std.testing.expectEqual(@as(f64, 7), sapwood);
    try std.testing.expectEqual(@as(f64, 0), layers[36]);
}

test "positive SNL1 makes fallback sapwood zero" {
    var sapwood: f64 = 5;
    var layers = [_]f64{ 1, 2 };
    _ = try publish(.{ .sapwood_carbon_g_c = &sapwood, .layer_stalk_area_m2 = &layers }, .{
        .canopy_emerged = false,
        .latest_internode_height_m = 8,
        .specific_internode_length = .positive,
        .retained_live_stalk_carbon_g_c = 7,
        .allocation = null,
    });
    try std.testing.expectEqual(@as(f64, 0), sapwood);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, &layers);
}

test "late invalid allocation leaves sapwood and layers unchanged" {
    var sapwood: f64 = 5;
    var layers = [_]f64{ 1, 2 };
    try std.testing.expectError(error.InvalidStalkLayerAllocation, publish(
        .{ .sapwood_carbon_g_c = &sapwood, .layer_stalk_area_m2 = &layers },
        .{
            .canopy_emerged = true,
            .latest_internode_height_m = 1,
            .specific_internode_length = .zero,
            .retained_live_stalk_carbon_g_c = 7,
            .allocation = .{ .radius_m = 1, .surface_area_m2 = 1, .sapwood_carbon_g_c = 1, .layer_stalk_area_m2 = &.{ 1, std.math.nan(f64) } },
        },
    ));
    try std.testing.expectEqual(@as(f64, 5), sapwood);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, &layers);
}

test "allocation dimension mismatch is atomic" {
    var sapwood: f64 = 5;
    var layers = [_]f64{ 1, 2 };
    try std.testing.expectError(error.StalkLayerStateUpdateDimensionMismatch, publish(
        .{ .sapwood_carbon_g_c = &sapwood, .layer_stalk_area_m2 = &layers },
        .{
            .canopy_emerged = true,
            .latest_internode_height_m = 1,
            .specific_internode_length = .zero,
            .retained_live_stalk_carbon_g_c = 7,
            .allocation = .{ .radius_m = 1, .surface_area_m2 = 1, .sapwood_carbon_g_c = 1, .layer_stalk_area_m2 = &.{1} },
        },
    ));
    try std.testing.expectEqual(@as(f64, 5), sapwood);
}

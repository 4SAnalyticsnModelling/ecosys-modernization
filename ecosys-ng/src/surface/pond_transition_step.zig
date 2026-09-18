const std = @import("std");
const compute = @import("../core/compute.zig");
const transition = @import("../redistribution/pond/layer_transition.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    active: []bool,
    destination_soil_layer: []usize,
    transfer_fraction: []f64,
    boundary_change_m: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfacePondTransitionCells;
        const active = try allocator.alloc(bool, cell_count);
        errdefer allocator.free(active);
        const destination = try allocator.alloc(usize, cell_count);
        errdefer allocator.free(destination);
        const fraction = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(fraction);
        const boundary = try allocator.alloc(f64, cell_count);
        @memset(active, false);
        @memset(destination, 0);
        @memset(fraction, 0);
        @memset(boundary, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .active = active, .destination_soil_layer = destination, .transfer_fraction = fraction, .boundary_change_m = boundary };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.boundary_change_m);
        self.allocator.free(self.transfer_fraction);
        self.allocator.free(self.destination_soil_layer);
        self.allocator.free(self.active);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    surface_liquid_water_m3: []const f64,
    surface_ice_m3: []const f64,
    surface_ponding_capacity_m3: []const f64,
    surface_litter_volume_m3: []const f64,
    surface_litter_water_capacity_m3: []const f64,
    horizontal_area_m2: []const f64,
    minimum_heat_capacity_megajoules_per_k: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64 = 0.917,
};

/// Independent cells are safe for the normal tiled CPU executor and a future
/// GPU selection kernel.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    const count = context.result.cell_count;
    inline for (.{ context.surface_liquid_water_m3, context.surface_ice_m3, context.surface_ponding_capacity_m3, context.surface_litter_volume_m3, context.surface_litter_water_capacity_m3, context.horizontal_area_m2, context.minimum_heat_capacity_megajoules_per_k }) |values| if (values.len != count) return error.SurfacePondTransitionStepDimensionMismatch;
    if (range.first > range.end or range.end > count) return error.SurfacePondTransitionStepDimensionMismatch;
    for (range.first..range.end) |cell| {
        const selected = try transition.selectSeparatedSurfacePondTransfer(.{
            .top_soil_layer = 0,
            .surface_pond_liquid_water_m3 = context.surface_liquid_water_m3[cell],
            .surface_pond_ice_m3 = context.surface_ice_m3[cell],
            .surface_ponding_capacity_m3 = context.surface_ponding_capacity_m3[cell],
            .surface_litter_volume_m3 = context.surface_litter_volume_m3[cell],
            .surface_litter_water_capacity_m3 = context.surface_litter_water_capacity_m3[cell],
            .horizontal_area_m2 = context.horizontal_area_m2[cell],
            .minimum_heat_capacity_megajoules_per_k = context.minimum_heat_capacity_megajoules_per_k[cell],
            .liquid_water_heat_capacity_megajoules_per_m3_k = context.liquid_water_heat_capacity_megajoules_per_m3_k,
            .ice_density_megagrams_per_m3 = context.ice_density_megagrams_per_m3,
        });
        if (selected) |value| {
            context.result.active[cell] = true;
            context.result.destination_soil_layer[cell] = switch (value.destination) {
                .soil_layer => |layer| layer,
                .surface_pond => unreachable,
            };
            context.result.transfer_fraction[cell] = value.transfer_fraction;
            context.result.boundary_change_m[cell] = value.boundary_change_m;
        } else {
            context.result.active[cell] = false;
            context.result.destination_soil_layer[cell] = 0;
            context.result.transfer_fraction[cell] = 0;
            context.result.boundary_change_m[cell] = 0;
        }
    }
}

test "runtime surface transition selection is cell independent and clears stale events" {
    var state = try State.init(std.testing.allocator, 3);
    defer state.deinit();
    @memset(state.active, true);
    var context: ApplyContext = .{
        .result = &state,
        .surface_liquid_water_m3 = &.{ 0.1, 0.5, 0.8 },
        .surface_ice_m3 = &.{ 0, 0, 0 },
        .surface_ponding_capacity_m3 = &.{ 0.2, 0.2, 0.2 },
        .surface_litter_volume_m3 = &.{ 0.1, 0.1, 0.1 },
        .surface_litter_water_capacity_m3 = &.{ 0.1, 0.1, 0.1 },
        .horizontal_area_m2 = &.{ 10, 10, 10 },
        .minimum_heat_capacity_megajoules_per_k = &.{ 0, 0, 0 },
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    };
    try applyTile(&context, .{ .first = 0, .end = 2 });
    try std.testing.expect(!state.active[0]);
    try std.testing.expect(state.active[1]);
    try std.testing.expect(state.active[2]);
    try applyTile(&context, .{ .first = 2, .end = 3 });
    try std.testing.expect(state.active[2]);
}

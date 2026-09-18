const std = @import("std");
const environment = @import("microbial_environment.zig");
const compute = @import("../core/compute.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    biologically_active_water_m3: []f64,
    growth_temperature_response: []f64,
    maintenance_temperature_response: []f64,
    aqueous_diffusion_temperature_response: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceMicrobialEnvironmentCells;
        const water = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(water);
        const temperature = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(temperature);
        const maintenance_temperature = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(maintenance_temperature);
        const aqueous_diffusion_temperature = try allocator.alloc(f64, cell_count);
        @memset(water, 0);
        @memset(temperature, 0);
        @memset(maintenance_temperature, 0);
        @memset(aqueous_diffusion_temperature, 0);
        return .{ .allocator = allocator, .biologically_active_water_m3 = water, .growth_temperature_response = temperature, .maintenance_temperature_response = maintenance_temperature, .aqueous_diffusion_temperature_response = aqueous_diffusion_temperature };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.aqueous_diffusion_temperature_response);
        self.allocator.free(self.maintenance_temperature_response);
        self.allocator.free(self.growth_temperature_response);
        self.allocator.free(self.biologically_active_water_m3);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    litter_water_m3: []const f64,
    reference_litter_volume_m3: []const f64,
    surface_porosity_m3_per_m3: []const f64,
    field_capacity_m3_per_m3: []const f64,
    inactive_water_threshold_m3_per_m3: []const f64,
    negligible_reference_volume_m3: f64,
    litter_temperature_k: []const f64,
    thermal_adaptation_offset_k: []const f64,
};

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.biologically_active_water_m3.len;
    if (range.first > range.end or range.end > cells or context.result.growth_temperature_response.len != cells or context.result.maintenance_temperature_response.len != cells or context.result.aqueous_diffusion_temperature_response.len != cells) return error.SurfaceMicrobialEnvironmentDimensionMismatch;
    inline for (.{ context.litter_water_m3, context.reference_litter_volume_m3, context.surface_porosity_m3_per_m3, context.field_capacity_m3_per_m3, context.inactive_water_threshold_m3_per_m3, context.litter_temperature_k, context.thermal_adaptation_offset_k }) |values| if (values.len != cells) return error.SurfaceMicrobialEnvironmentDimensionMismatch;
    const staged = try context.result.allocator.alloc(environment.Result, range.end - range.first);
    defer context.result.allocator.free(staged);
    for (range.first..range.end) |cell| {
        staged[cell - range.first] = try environment.calculate(.{
            .litter_water_m3 = context.litter_water_m3[cell],
            .reference_litter_volume_m3 = context.reference_litter_volume_m3[cell],
            .surface_porosity_m3_per_m3 = context.surface_porosity_m3_per_m3[cell],
            .field_capacity_m3_per_m3 = context.field_capacity_m3_per_m3[cell],
            .inactive_water_threshold_m3_per_m3 = context.inactive_water_threshold_m3_per_m3[cell],
            .negligible_reference_volume_m3 = context.negligible_reference_volume_m3,
            .litter_temperature_k = context.litter_temperature_k[cell],
            .thermal_adaptation_offset_k = context.thermal_adaptation_offset_k[cell],
        });
    }
    for (range.first..range.end) |cell| {
        const value = staged[cell - range.first];
        context.result.biologically_active_water_m3[cell] = value.biologically_active_water_m3;
        context.result.growth_temperature_response[cell] = value.growth_temperature_response;
        context.result.maintenance_temperature_response[cell] = value.maintenance_temperature_response;
        context.result.aqueous_diffusion_temperature_response[cell] = value.aqueous_diffusion_temperature_response;
    }
}

test "surface microbial environment executes as independent tiles" {
    var state = try State.init(std.testing.allocator, 3);
    defer state.deinit();
    var context: ApplyContext = .{ .result = &state, .litter_water_m3 = &.{ 0.2, 0.4, 0.8 }, .reference_litter_volume_m3 = &.{ 1, 1, 1 }, .surface_porosity_m3_per_m3 = &.{ 0.5, 0.5, 0.5 }, .field_capacity_m3_per_m3 = &.{ 0.3, 0.3, 0.3 }, .inactive_water_threshold_m3_per_m3 = &.{ 0.1, 0.1, 0.1 }, .negligible_reference_volume_m3 = 1e-12, .litter_temperature_k = &.{ 293.15, 293.15, 293.15 }, .thermal_adaptation_offset_k = &.{ 0, 0, 0 } };
    try applyTile(&context, .{ .first = 1, .end = 3 });
    try std.testing.expectEqual(@as(f64, 0), state.biologically_active_water_m3[0]);
    try std.testing.expectApproxEqAbs(state.biologically_active_water_m3[1], state.biologically_active_water_m3[2], 1e-15);
    try std.testing.expect(state.growth_temperature_response[1] > 0);
    try std.testing.expect(state.maintenance_temperature_response[1] > 0);
}

test "surface microbial environment tile rolls back on late invalid cell" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.biologically_active_water_m3, 9);
    @memset(state.growth_temperature_response, 8);
    @memset(state.maintenance_temperature_response, 7);
    @memset(state.aqueous_diffusion_temperature_response, 6);
    var context: ApplyContext = .{
        .result = &state,
        .litter_water_m3 = &.{ 0.4, std.math.nan(f64) },
        .reference_litter_volume_m3 = &.{ 1, 1 },
        .surface_porosity_m3_per_m3 = &.{ 0.5, 0.5 },
        .field_capacity_m3_per_m3 = &.{ 0.3, 0.3 },
        .inactive_water_threshold_m3_per_m3 = &.{ 0.1, 0.1 },
        .negligible_reference_volume_m3 = 1e-12,
        .litter_temperature_k = &.{ 293.15, 293.15 },
        .thermal_adaptation_offset_k = &.{ 0, 0 },
    };
    try std.testing.expectError(
        error.NonFiniteSurfaceMicrobialEnvironment,
        applyTile(&context, .{ .first = 0, .end = 2 }),
    );
    try std.testing.expectEqualSlices(f64, &.{ 9, 9 }, state.biologically_active_water_m3);
    try std.testing.expectEqualSlices(f64, &.{ 8, 8 }, state.growth_temperature_response);
    try std.testing.expectEqualSlices(f64, &.{ 7, 7 }, state.maintenance_temperature_response);
    try std.testing.expectEqualSlices(f64, &.{ 6, 6 }, state.aqueous_diffusion_temperature_response);
}

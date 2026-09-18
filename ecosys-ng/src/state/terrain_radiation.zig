const std = @import("std");
const CellRange = @import("../core/compute.zig").CellRange;
const Topography = @import("topography.zig").Topography;
const Geometry = @import("../canopy/morphology/geometry.zig").Geometry;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    sky_sector_count: usize,
    ground_slope_sine: []f64,
    ground_slope_cosine: []f64,
    ground_aspect_radians: []f64,
    diffuse_sky_incidence_fraction: []f64,
    direct_solar_incidence_fraction: []f64,

    pub fn init(allocator: std.mem.Allocator, topography: Topography, unit_by_cell: []const usize, geometry: Geometry) !State {
        if (unit_by_cell.len == 0 or geometry.sky_azimuth_radians.len == 0) return error.EmptyTerrainRadiationGrid;
        const diffuse_count = try std.math.mul(usize, unit_by_cell.len, geometry.sky_azimuth_radians.len);
        var result: State = .{
            .allocator = allocator,
            .cell_count = unit_by_cell.len,
            .sky_sector_count = geometry.sky_azimuth_radians.len,
            .ground_slope_sine = try allocator.alloc(f64, unit_by_cell.len),
            .ground_slope_cosine = undefined,
            .ground_aspect_radians = undefined,
            .diffuse_sky_incidence_fraction = undefined,
            .direct_solar_incidence_fraction = undefined,
        };
        errdefer allocator.free(result.ground_slope_sine);
        result.ground_slope_cosine = try allocator.alloc(f64, unit_by_cell.len);
        errdefer allocator.free(result.ground_slope_cosine);
        result.ground_aspect_radians = try allocator.alloc(f64, unit_by_cell.len);
        errdefer allocator.free(result.ground_aspect_radians);
        result.diffuse_sky_incidence_fraction = try allocator.alloc(f64, diffuse_count);
        errdefer allocator.free(result.diffuse_sky_incidence_fraction);
        result.direct_solar_incidence_fraction = try allocator.alloc(f64, unit_by_cell.len);
        @memset(result.direct_solar_incidence_fraction, 0);

        for (unit_by_cell, 0..) |unit_index, cell| {
            if (unit_index >= topography.units.len) return error.TopographyUnitOutOfBounds;
            const unit = topography.units[unit_index];
            if (unit.slope_degrees < 0 or unit.slope_degrees > 90 or !std.math.isFinite(unit.geometric_aspect_degrees)) return error.InvalidTerrainGeometry;
            const slope_sine = @max(@sin(unit.slope_degrees * std.math.pi / 180.0), @sin(0.1 * std.math.pi / 180.0));
            const slope_cosine = @sqrt(@max(0.0, 1.0 - slope_sine * slope_sine));
            const aspect = unit.geometric_aspect_degrees * std.math.pi / 180.0;
            result.ground_slope_sine[cell] = slope_sine;
            result.ground_slope_cosine[cell] = slope_cosine;
            result.ground_aspect_radians[cell] = aspect;
            for (0..result.sky_sector_count) |sky| {
                const incidence = slope_cosine * geometry.sky_elevation_sine[sky] + slope_sine * geometry.sky_elevation_cosine[sky] * @cos(aspect - geometry.sky_azimuth_radians[sky]);
                result.diffuse_sky_incidence_fraction[cell * result.sky_sector_count + sky] = std.math.clamp(incidence, 0.0, 1.0);
            }
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.direct_solar_incidence_fraction);
        self.allocator.free(self.diffuse_sky_incidence_fraction);
        self.allocator.free(self.ground_aspect_radians);
        self.allocator.free(self.ground_slope_cosine);
        self.allocator.free(self.ground_slope_sine);
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| {
            if (!std.math.isFinite(value)) {
                std.log.err("non-finite terrain radiation: field={s} index={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteTerrainRadiation;
            }
        };
    }
};

pub const DirectSolarContext = struct {
    state: *State,
    solar_angle_sine: f64,
    solar_azimuth_radians: f64,
};

pub const MappedDirectSolarContext = struct {
    state: *State,
    solar_angle_sine: []const f64,
    solar_azimuth_radians: []const f64,
};

pub fn applyDirectSolarTile(context: *DirectSolarContext, range: CellRange) !void {
    if (!std.math.isFinite(context.solar_angle_sine) or !std.math.isFinite(context.solar_azimuth_radians)) return error.NonFiniteSolarGeometry;
    if (context.solar_angle_sine < 0 or context.solar_angle_sine > 1 or range.end > context.state.cell_count) return error.InvalidSolarGeometry;
    const solar_cosine = @sqrt(@max(0.0, 1.0 - context.solar_angle_sine * context.solar_angle_sine));
    for (range.first..range.end) |cell| {
        const incidence = context.state.ground_slope_cosine[cell] * context.solar_angle_sine +
            context.state.ground_slope_sine[cell] * solar_cosine * @cos(context.state.ground_aspect_radians[cell] - context.solar_azimuth_radians);
        context.state.direct_solar_incidence_fraction[cell] = std.math.clamp(incidence, 0.0, 1.0);
    }
}

pub fn applyMappedDirectSolarTile(context: *MappedDirectSolarContext, range: CellRange) !void {
    if (context.solar_angle_sine.len != context.state.cell_count or
        context.solar_azimuth_radians.len != context.state.cell_count or
        range.end > context.state.cell_count) return error.InvalidSolarGeometry;
    for (range.first..range.end) |cell| {
        const solar_sine = context.solar_angle_sine[cell];
        const solar_azimuth = context.solar_azimuth_radians[cell];
        if (!std.math.isFinite(solar_sine) or !std.math.isFinite(solar_azimuth))
            return error.NonFiniteSolarGeometry;
        if (solar_sine < 0 or solar_sine > 1) return error.InvalidSolarGeometry;
        const solar_cosine = @sqrt(@max(0.0, 1.0 - solar_sine * solar_sine));
        const incidence = context.state.ground_slope_cosine[cell] * solar_sine +
            context.state.ground_slope_sine[cell] * solar_cosine *
                @cos(context.state.ground_aspect_radians[cell] - solar_azimuth);
        context.state.direct_solar_incidence_fraction[cell] =
            std.math.clamp(incidence, 0.0, 1.0);
    }
}

test "terrain projections are heap backed and direct incidence is tiled" {
    const allocator = std.testing.allocator;
    const soil_name = try allocator.dupe(u8, "soil");
    var units = try allocator.alloc(@import("topography.zig").LandscapeUnit, 1);
    units[0] = .{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1, .compass_aspect_degrees = 180, .geometric_aspect_degrees = 270, .slope_degrees = 10, .initial_snowpack_depth_m = 0, .soil_profile_file = soil_name };
    var topography: Topography = .{ .allocator = allocator, .units = units };
    defer topography.deinit();
    var geometry = try Geometry.init(allocator, .{ .diffuse_sky_sector_count = 6 });
    defer geometry.deinit();
    var state = try State.init(allocator, topography, &.{0}, geometry);
    defer state.deinit();
    var context: DirectSolarContext = .{ .state = &state, .solar_angle_sine = 0.7, .solar_azimuth_radians = 3.0 * std.math.pi / 2.0 };
    try applyDirectSolarTile(&context, .{ .first = 0, .end = 1 });
    try state.validateFinite();
    try std.testing.expectEqual(@as(usize, 6), state.diffuse_sky_incidence_fraction.len);
    try std.testing.expect(state.direct_solar_incidence_fraction[0] >= 0 and state.direct_solar_incidence_fraction[0] <= 1);
}

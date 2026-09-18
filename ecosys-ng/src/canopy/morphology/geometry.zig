const std = @import("std");

pub const ScatteringDirection = enum(u8) { backward, forward };

/// Runtime canopy-angle discretization. Counts are configuration rather than
/// compile-time array bounds; the defaults reproduce the four ecosys classes.
pub const Discretization = struct {
    leaf_inclination_class_count: usize = 4,
    leaf_azimuth_class_count: usize = 4,
    diffuse_sky_sector_count: usize = 4,
    diffuse_sky_elevation_radians: f64 = std.math.pi / 4.0,
};

pub const Geometry = struct {
    allocator: std.mem.Allocator,
    leaf_inclination_sine: []f64,
    leaf_inclination_cosine: []f64,
    leaf_azimuth_radians: []f64,
    sky_azimuth_radians: []f64,
    sky_elevation_sine: []f64,
    sky_elevation_cosine: []f64,
    diffuse_incidence_fraction: []f64,
    diffuse_incidence_per_horizontal_area: []f64,
    diffuse_scattering_direction: []ScatteringDirection,
    diffuse_sky_horizontal_projection: f64,

    pub fn init(allocator: std.mem.Allocator, discretization: Discretization) !Geometry {
        try validateDiscretization(discretization);
        const inclination_count = discretization.leaf_inclination_class_count;
        const leaf_azimuth_count = discretization.leaf_azimuth_class_count;
        const sky_count = discretization.diffuse_sky_sector_count;
        const table_count = try std.math.mul(usize, try std.math.mul(usize, sky_count, inclination_count), leaf_azimuth_count);

        var result: Geometry = undefined;
        result.allocator = allocator;
        result.leaf_inclination_sine = try allocator.alloc(f64, inclination_count);
        errdefer allocator.free(result.leaf_inclination_sine);
        result.leaf_inclination_cosine = try allocator.alloc(f64, inclination_count);
        errdefer allocator.free(result.leaf_inclination_cosine);
        result.leaf_azimuth_radians = try allocator.alloc(f64, leaf_azimuth_count);
        errdefer allocator.free(result.leaf_azimuth_radians);
        result.sky_azimuth_radians = try allocator.alloc(f64, sky_count);
        errdefer allocator.free(result.sky_azimuth_radians);
        result.sky_elevation_sine = try allocator.alloc(f64, sky_count);
        errdefer allocator.free(result.sky_elevation_sine);
        result.sky_elevation_cosine = try allocator.alloc(f64, sky_count);
        errdefer allocator.free(result.sky_elevation_cosine);
        result.diffuse_incidence_fraction = try allocator.alloc(f64, table_count);
        errdefer allocator.free(result.diffuse_incidence_fraction);
        result.diffuse_incidence_per_horizontal_area = try allocator.alloc(f64, table_count);
        errdefer allocator.free(result.diffuse_incidence_per_horizontal_area);
        result.diffuse_scattering_direction = try allocator.alloc(ScatteringDirection, table_count);
        errdefer allocator.free(result.diffuse_scattering_direction);
        result.diffuse_sky_horizontal_projection = 0;
        result.initialize(discretization);
        return result;
    }

    pub fn deinit(self: *Geometry) void {
        self.allocator.free(self.diffuse_scattering_direction);
        self.allocator.free(self.diffuse_incidence_per_horizontal_area);
        self.allocator.free(self.diffuse_incidence_fraction);
        self.allocator.free(self.sky_elevation_cosine);
        self.allocator.free(self.sky_elevation_sine);
        self.allocator.free(self.sky_azimuth_radians);
        self.allocator.free(self.leaf_azimuth_radians);
        self.allocator.free(self.leaf_inclination_cosine);
        self.allocator.free(self.leaf_inclination_sine);
        self.* = undefined;
    }

    fn initialize(self: *Geometry, discretization: Discretization) void {
        // STARTS 142--149 defines the production four-class quadrature with
        // literal ZSIN/ZCOS values. Preserve those source values exactly;
        // midpoint trigonometry is only the runtime generalization for a
        // non-source class count.
        const starts_sine = [4]f64{ 0.195, 0.556, 0.831, 0.981 };
        const starts_cosine = [4]f64{ 0.981, 0.831, 0.556, 0.195 };
        if (self.leaf_inclination_sine.len == starts_sine.len) {
            @memcpy(self.leaf_inclination_sine, &starts_sine);
            @memcpy(self.leaf_inclination_cosine, &starts_cosine);
        } else for (self.leaf_inclination_sine, self.leaf_inclination_cosine, 0..) |*sine, *cosine, class| {
            const angle = (@as(f64, @floatFromInt(class)) + 0.5) * (std.math.pi / 2.0) / @as(f64, @floatFromInt(self.leaf_inclination_sine.len));
            sine.* = @sin(angle);
            cosine.* = @cos(angle);
        }
        for (self.leaf_azimuth_radians, 0..) |*azimuth, class| azimuth.* = (@as(f64, @floatFromInt(class)) + 0.5) * std.math.pi / @as(f64, @floatFromInt(self.leaf_azimuth_radians.len));

        const sky_sine = @sin(discretization.diffuse_sky_elevation_radians);
        const sky_cosine = @cos(discretization.diffuse_sky_elevation_radians);
        for (0..self.sky_azimuth_radians.len) |sky| {
            self.sky_azimuth_radians[sky] = (@as(f64, @floatFromInt(2 * sky + 1))) * std.math.pi / @as(f64, @floatFromInt(self.sky_azimuth_radians.len));
            self.sky_elevation_sine[sky] = sky_sine;
            self.sky_elevation_cosine[sky] = sky_cosine;
            self.diffuse_sky_horizontal_projection += sky_sine;
            for (0..self.leaf_inclination_sine.len) |inclination| for (0..self.leaf_azimuth_radians.len) |leaf_azimuth| {
                const table_index = self.index(sky, inclination, leaf_azimuth);
                const relative_azimuth_cosine = @cos(self.leaf_azimuth_radians[leaf_azimuth] - self.sky_azimuth_radians[sky]);
                const signed_incidence = self.leaf_inclination_cosine[inclination] * sky_sine + self.leaf_inclination_sine[inclination] * sky_cosine * relative_azimuth_cosine;
                self.diffuse_incidence_fraction[table_index] = @abs(signed_incidence);
                self.diffuse_incidence_per_horizontal_area[table_index] = @abs(signed_incidence) / sky_sine;
                self.diffuse_scattering_direction[table_index] = scatteringDirection(discretization.diffuse_sky_elevation_radians, signed_incidence, self.leaf_inclination_cosine[inclination], sky_sine);
            };
        }
    }

    pub fn index(self: Geometry, sky: usize, inclination: usize, leaf_azimuth: usize) usize {
        return (sky * self.leaf_inclination_sine.len + inclination) * self.leaf_azimuth_radians.len + leaf_azimuth;
    }

    /// Writes direct-solar incidence tables into caller-owned runtime buffers.
    pub fn directSolarIncidence(self: Geometry, solar_angle_sine: f64, incidence_fraction: []f64, incidence_per_horizontal_area: []f64, direction: []ScatteringDirection) !void {
        if (!std.math.isFinite(solar_angle_sine)) return error.NonFiniteSolarGeometry;
        if (solar_angle_sine <= 0 or solar_angle_sine > 1) return error.InvalidSolarAngle;
        const count = try std.math.mul(usize, self.leaf_inclination_sine.len, self.leaf_azimuth_radians.len);
        if (incidence_fraction.len != count or incidence_per_horizontal_area.len != count or direction.len != count) return error.IncorrectSolarGeometryBufferSize;
        const solar_cosine = @sqrt(@max(0.0, 1.0 - solar_angle_sine * solar_angle_sine));
        const solar_elevation = std.math.asin(solar_angle_sine);
        for (0..self.leaf_inclination_sine.len) |inclination| for (0..self.leaf_azimuth_radians.len) |azimuth| {
            const index_2d = inclination * self.leaf_azimuth_radians.len + azimuth;
            const relative_azimuth_cosine = @cos((@as(f64, @floatFromInt(azimuth)) + 0.5) * std.math.pi / @as(f64, @floatFromInt(self.leaf_azimuth_radians.len)));
            const signed_incidence = self.leaf_inclination_cosine[inclination] * solar_angle_sine + self.leaf_inclination_sine[inclination] * solar_cosine * relative_azimuth_cosine;
            incidence_fraction[index_2d] = @abs(signed_incidence);
            incidence_per_horizontal_area[index_2d] = @abs(signed_incidence) / solar_angle_sine;
            direction[index_2d] = scatteringDirection(solar_elevation, signed_incidence, self.leaf_inclination_cosine[inclination], solar_angle_sine);
        };
    }

    /// Writes one independent direct-beam table per grid cell. Buffers are
    /// cell-major and heap-owned by the caller; night cells are explicitly
    /// cleared so a prior daylight hour cannot leak into later kernels.
    pub fn directSolarIncidenceMapped(
        self: Geometry,
        solar_angle_sine_by_cell: []const f64,
        incidence_fraction: []f64,
        incidence_per_horizontal_area: []f64,
        direction: []ScatteringDirection,
    ) !void {
        const table_count =
            try std.math.mul(
                usize,
                self.leaf_inclination_sine.len,
                self.leaf_azimuth_radians.len,
            );
        const expected_count =
            try std.math.mul(usize, solar_angle_sine_by_cell.len, table_count);
        if (incidence_fraction.len != expected_count or
            incidence_per_horizontal_area.len != expected_count or
            direction.len != expected_count)
            return error.IncorrectSolarGeometryBufferSize;
        for (solar_angle_sine_by_cell, 0..) |solar_angle_sine, cell| {
            if (!std.math.isFinite(solar_angle_sine) or
                solar_angle_sine < 0 or solar_angle_sine > 1)
                return error.InvalidSolarAngle;
            const first = cell * table_count;
            const cell_fraction =
                incidence_fraction[first..][0..table_count];
            const cell_horizontal =
                incidence_per_horizontal_area[first..][0..table_count];
            const cell_direction = direction[first..][0..table_count];
            if (solar_angle_sine > 0) {
                try self.directSolarIncidence(
                    solar_angle_sine,
                    cell_fraction,
                    cell_horizontal,
                    cell_direction,
                );
            } else {
                @memset(cell_fraction, 0);
                @memset(cell_horizontal, 0);
                @memset(cell_direction, .forward);
            }
        }
    }
};

pub fn validateDiscretization(value: Discretization) !void {
    if (value.leaf_inclination_class_count == 0 or value.leaf_azimuth_class_count == 0 or value.diffuse_sky_sector_count == 0) return error.EmptyCanopyDiscretization;
    if (!std.math.isFinite(value.diffuse_sky_elevation_radians) or value.diffuse_sky_elevation_radians <= 0 or value.diffuse_sky_elevation_radians >= std.math.pi / 2.0) return error.InvalidSkyElevation;
}

fn scatteringDirection(source_elevation: f64, signed_incidence: f64, leaf_cosine: f64, source_sine: f64) ScatteringDirection {
    const incidence_angle = if (leaf_cosine > source_sine) std.math.acos(std.math.clamp(signed_incidence, -1.0, 1.0)) else -std.math.acos(std.math.clamp(signed_incidence, -1.0, 1.0));
    const scattering_angle = if (incidence_angle > -std.math.pi / 2.0)
        source_elevation + 2.0 * incidence_angle
    else
        source_elevation - 2.0 * (std.math.pi + incidence_angle);
    return if (scattering_angle > 0 and scattering_angle < std.math.pi) .backward else .forward;
}

test "default runtime geometry reproduces four-class sky projection" {
    var geometry = try Geometry.init(std.testing.allocator, .{});
    defer geometry.deinit();
    try std.testing.expectEqual(@as(usize, 64), geometry.diffuse_incidence_fraction.len);
    // starts.f:142--149 ZSIN/ZCOS are source literals, not values derived
    // from idealized inclination midpoints.
    try std.testing.expectEqualSlices(f64, &.{ 0.195, 0.556, 0.831, 0.981 }, geometry.leaf_inclination_sine);
    try std.testing.expectEqualSlices(f64, &.{ 0.981, 0.831, 0.556, 0.195 }, geometry.leaf_inclination_cosine);
    try std.testing.expectApproxEqAbs(4.0 * @sin(std.math.pi / 4.0), geometry.diffuse_sky_horizontal_projection, 1.0e-14);
    for (geometry.diffuse_incidence_fraction) |value| try std.testing.expect(std.math.isFinite(value) and value >= 0 and value <= 1);
}

test "direct incidence supports runtime class counts" {
    const allocator = std.testing.allocator;
    var geometry = try Geometry.init(allocator, .{ .leaf_inclination_class_count = 7, .leaf_azimuth_class_count = 9, .diffuse_sky_sector_count = 6 });
    defer geometry.deinit();
    const count = geometry.leaf_inclination_sine.len * geometry.leaf_azimuth_radians.len;
    const incidence = try allocator.alloc(f64, count);
    defer allocator.free(incidence);
    const horizontal = try allocator.alloc(f64, count);
    defer allocator.free(horizontal);
    const direction = try allocator.alloc(ScatteringDirection, count);
    defer allocator.free(direction);
    try geometry.directSolarIncidence(0.6, incidence, horizontal, direction);
    for (incidence) |value| try std.testing.expect(std.math.isFinite(value) and value >= 0 and value <= 1);
}

test "mapped direct incidence keeps different grid-cell solar geometry independent" {
    var geometry = try Geometry.init(std.testing.allocator, .{});
    defer geometry.deinit();
    const table_count =
        geometry.leaf_inclination_sine.len *
        geometry.leaf_azimuth_radians.len;
    const fraction = try std.testing.allocator.alloc(f64, 3 * table_count);
    defer std.testing.allocator.free(fraction);
    const horizontal = try std.testing.allocator.alloc(f64, 3 * table_count);
    defer std.testing.allocator.free(horizontal);
    const direction = try std.testing.allocator.alloc(
        ScatteringDirection,
        3 * table_count,
    );
    defer std.testing.allocator.free(direction);
    try geometry.directSolarIncidenceMapped(
        &.{ 0.2, 0.8, 0 },
        fraction,
        horizontal,
        direction,
    );
    try std.testing.expect(!std.mem.eql(
        f64,
        fraction[0..table_count],
        fraction[table_count .. 2 * table_count],
    ));
    for (fraction[2 * table_count ..]) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
    for (horizontal[2 * table_count ..]) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
}

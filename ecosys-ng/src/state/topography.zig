const std = @import("std");
const Domain = @import("../driver/runscript.zig").Domain;

/// One cell's terrain description.
///
/// The column and row span is retained because downstream consumers index by
/// global coordinate, but a unit now always covers exactly one cell: terrain
/// values come from that cell's site file, and there is no longer an input
/// format that can describe a rectangular run of cells. The legacy topography
/// file's second slope column is gone, since no process ever read it.
pub const LandscapeUnit = struct {
    west_column: usize,
    north_row: usize,
    east_column: usize,
    south_row: usize,
    compass_aspect_degrees: f64,
    geometric_aspect_degrees: f64,
    slope_degrees: f64,
    initial_snowpack_depth_m: f64,
    soil_profile_file: []const u8,

    pub fn contains(self: LandscapeUnit, column: usize, row: usize) bool {
        return column >= self.west_column and column <= self.east_column and
            row >= self.north_row and row <= self.south_row;
    }
};

pub const Topography = struct {
    allocator: std.mem.Allocator,
    units: []LandscapeUnit,

    pub fn deinit(self: *Topography) void {
        for (self.units) |unit| self.allocator.free(unit.soil_profile_file);
        self.allocator.free(self.units);
        self.* = undefined;
    }

    pub fn validateCoverage(self: Topography, domain: Domain, allocator: std.mem.Allocator) !void {
        const map = try self.buildCellUnitMap(domain, allocator);
        allocator.free(map);
    }

    /// Resolves exactly one landscape unit at a global one-based grid
    /// coordinate.
    pub fn unitForCell(self: Topography, column: usize, row: usize) !usize {
        if (column == 0 or row == 0) return error.InvalidTopographyCoordinate;
        var found: ?usize = null;
        for (self.units, 0..) |unit, index| {
            if (!unit.contains(column, row)) continue;
            if (found != null) return error.OverlappingTopographyUnits;
            found = index;
        }
        return found orelse error.IncompleteTopographyCoverage;
    }

    /// Returns one landscape-unit index per selected cell in row-major order.
    /// Overlaps and gaps are fatal because either would make state provenance
    /// ambiguous.
    pub fn buildCellUnitMap(self: Topography, domain: Domain, allocator: std.mem.Allocator) ![]usize {
        const columns = try domain.columns();
        const rows = try domain.rows();
        const cell_count = try std.math.mul(usize, columns, rows);
        const unit_by_cell = try allocator.alloc(usize, cell_count);
        errdefer allocator.free(unit_by_cell);
        @memset(unit_by_cell, std.math.maxInt(usize));
        for (self.units, 0..) |unit, unit_index| {
            const west = @max(unit.west_column, domain.west_column);
            const east = @min(unit.east_column, domain.east_column);
            const north = @max(unit.north_row, domain.north_row);
            const south = @min(unit.south_row, domain.south_row);
            if (west > east or north > south) continue;
            var column = west;
            while (column <= east) : (column += 1) {
                var row = north;
                while (row <= south) : (row += 1) {
                    const index = (row - domain.north_row) * columns + (column - domain.west_column);
                    if (unit_by_cell[index] != std.math.maxInt(usize)) return error.OverlappingTopographyUnits;
                    unit_by_cell[index] = unit_index;
                }
            }
        }
        for (unit_by_cell, 0..) |unit_index, index| {
            if (unit_index == std.math.maxInt(usize)) {
                std.log.err("topography does not cover selected domain cell index={d}", .{index});
                return error.IncompleteTopographyCoverage;
            }
        }
        return unit_by_cell;
    }

    pub fn commonSoilProfileFile(self: Topography, unit_by_cell: []const usize) ![]const u8 {
        if (unit_by_cell.len == 0) return error.EmptyGrid;
        const first_name = self.units[unit_by_cell[0]].soil_profile_file;
        for (unit_by_cell[1..]) |unit_index| {
            if (!std.mem.eql(u8, first_name, self.units[unit_index].soil_profile_file))
                return error.MultipleSoilProfileFiles;
        }
        return first_name;
    }
};

/// Converts a compass bearing to the counterclockwise-from-east convention
/// every radiation consumer uses.
pub fn geometricAspectDegrees(compass_aspect_degrees: f64) f64 {
    const geometric = 450.0 - compass_aspect_degrees;
    return if (geometric >= 360.0) geometric - 360.0 else geometric;
}

/// One unit's terrain, as a test fixture states it.
pub const UnitSpec = struct {
    west_column: usize,
    north_row: usize,
    east_column: usize,
    south_row: usize,
    compass_aspect_degrees: f64 = 0,
    slope_degrees: f64 = 0,
    initial_snowpack_depth_m: f64 = 0,
    soil_profile_file: []const u8 = "soil",
};

/// Builds a topography directly from unit specifications.
///
/// Production code reaches this shape through
/// `grid_environment.buildDomainTopography`, which reads each cell's terrain
/// from its site file. Tests that only need a terrain arrangement use this
/// instead of standing up a grid, a site catalog, and a cell mapping.
pub fn fromUnits(allocator: std.mem.Allocator, specs: []const UnitSpec) !Topography {
    const units = try allocator.alloc(LandscapeUnit, specs.len);
    errdefer allocator.free(units);
    var initialized: usize = 0;
    errdefer for (units[0..initialized]) |unit| allocator.free(unit.soil_profile_file);
    for (specs, 0..) |spec, index| {
        units[index] = .{
            .west_column = spec.west_column,
            .north_row = spec.north_row,
            .east_column = spec.east_column,
            .south_row = spec.south_row,
            .compass_aspect_degrees = spec.compass_aspect_degrees,
            .geometric_aspect_degrees = geometricAspectDegrees(spec.compass_aspect_degrees),
            .slope_degrees = spec.slope_degrees,
            .initial_snowpack_depth_m = spec.initial_snowpack_depth_m,
            .soil_profile_file = try allocator.dupe(u8, spec.soil_profile_file),
        };
        initialized += 1;
    }
    return .{ .allocator = allocator, .units = units };
}

test {
    _ = @import("topography_test.zig");
}

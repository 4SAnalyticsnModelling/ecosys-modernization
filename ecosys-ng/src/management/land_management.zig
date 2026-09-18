const std = @import("std");
const cell_grid_file = @import("../io/input/cell_grid_file.zig");
const spatial_grid = @import("../state/spatial_grid.zig");

/// The soil-management files that apply at one grid cell.
///
/// A unit is one cell. The input names the cell by coordinate, so there is no
/// rectangular range to reconcile and no possibility of two units overlapping.
pub const Unit = struct {
    fertilizer_file: []const u8,
    irrigation_file: []const u8,
    tillage_file: []const u8,
};

pub const Assignments = struct {
    allocator: std.mem.Allocator,
    /// One unit per grid cell, in row-major order.
    units: []Unit,

    pub fn deinit(self: *Assignments) void {
        for (self.units) |unit| {
            self.allocator.free(unit.fertilizer_file);
            self.allocator.free(unit.irrigation_file);
            self.allocator.free(unit.tillage_file);
        }
        self.allocator.free(self.units);
        self.* = undefined;
    }

    /// Identity map retained for callers that index through a unit map. Every
    /// cell owns its own unit now, so cell `n` is unit `n`.
    pub fn buildCellUnitMap(self: Assignments, allocator: std.mem.Allocator) ![]usize {
        const map = try allocator.alloc(usize, self.units.len);
        for (map, 0..) |*unit_index, cell| unit_index.* = cell;
        return map;
    }
};

/// Parses the coordinate-keyed soil-management grid file.
///
/// Record order is `management_cell latitude longitude fertilizer irrigation
/// tillage`, matching the file's own header. `NO` in any position disables that
/// management for the cell.
pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
    grid: spatial_grid.RegularGrid,
) !Assignments {
    const cell_count = try grid.cellCount();
    const units = try allocator.alloc(Unit, cell_count);
    errdefer allocator.free(units);
    var assigned = try allocator.alloc(bool, cell_count);
    defer allocator.free(assigned);
    @memset(assigned, false);
    errdefer for (units, assigned) |unit, is_assigned| if (is_assigned) {
        allocator.free(unit.fertilizer_file);
        allocator.free(unit.irrigation_file);
        allocator.free(unit.tillage_file);
    };

    var reader = try cell_grid_file.Reader.init(allocator, source, grid, "management_cell", 3);
    defer reader.deinit(allocator);
    while (try reader.next()) |record| {
        const fertilizer = try allocator.dupe(u8, record.names[0]);
        errdefer allocator.free(fertilizer);
        const irrigation = try allocator.dupe(u8, record.names[1]);
        errdefer allocator.free(irrigation);
        const tillage = try allocator.dupe(u8, record.names[2]);
        errdefer allocator.free(tillage);
        units[record.cell] = .{
            .fertilizer_file = fertilizer,
            .irrigation_file = irrigation,
            .tillage_file = tillage,
        };
        assigned[record.cell] = true;
    }
    try reader.requireCompleteCoverage();
    return .{ .allocator = allocator, .units = units };
}

/// Builds assignments directly from one unit per cell.
///
/// Production code reaches this shape through `parse`, which resolves each
/// cell from a coordinate. Tests of the dispatch layer only need the resulting
/// per-cell file selection, so they state it directly rather than standing up
/// a grid and a coordinate-keyed source.
pub fn fromUnits(allocator: std.mem.Allocator, specs: []const Unit) !Assignments {
    const units = try allocator.alloc(Unit, specs.len);
    errdefer allocator.free(units);
    var initialized: usize = 0;
    errdefer for (units[0..initialized]) |unit| {
        allocator.free(unit.fertilizer_file);
        allocator.free(unit.irrigation_file);
        allocator.free(unit.tillage_file);
    };
    for (specs, 0..) |spec, index| {
        const fertilizer = try allocator.dupe(u8, spec.fertilizer_file);
        errdefer allocator.free(fertilizer);
        const irrigation = try allocator.dupe(u8, spec.irrigation_file);
        errdefer allocator.free(irrigation);
        const tillage = try allocator.dupe(u8, spec.tillage_file);
        units[index] = .{
            .fertilizer_file = fertilizer,
            .irrigation_file = irrigation,
            .tillage_file = tillage,
        };
        initialized += 1;
    }
    return .{ .allocator = allocator, .units = units };
}

test {
    _ = @import("land_management_test.zig");
}

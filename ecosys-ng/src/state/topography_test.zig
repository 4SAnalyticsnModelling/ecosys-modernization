//! Tests for `topography.zig`.
//!
//! The parsing tests are gone with the topography input file. What remains is
//! the coverage and lookup logic, which is still what guarantees every cell
//! has exactly one terrain description.

const std = @import("std");
const topography_module = @import("topography.zig");
const Domain = @import("../driver/runscript.zig").Domain;

/// Builds a topography whose units are supplied directly, the way
/// `grid_environment.buildDomainTopography` does.
fn build(
    allocator: std.mem.Allocator,
    specs: []const struct { usize, usize, usize, usize, []const u8 },
) !topography_module.Topography {
    const units = try allocator.alloc(topography_module.LandscapeUnit, specs.len);
    errdefer allocator.free(units);
    for (specs, 0..) |spec, index| {
        units[index] = .{
            .west_column = spec[0],
            .north_row = spec[1],
            .east_column = spec[2],
            .south_row = spec[3],
            .compass_aspect_degrees = 94.6,
            .geometric_aspect_degrees = topography_module.geometricAspectDegrees(94.6),
            .slope_degrees = 2,
            .initial_snowpack_depth_m = 0,
            .soil_profile_file = try allocator.dupe(u8, spec[4]),
        };
    }
    return .{ .allocator = allocator, .units = units };
}

test "coverage validation and common soil profile over a full domain" {
    const allocator = std.testing.allocator;
    var topography = try build(allocator, &.{.{ 1, 1, 2, 2, "soil_profile" }});
    defer topography.deinit();
    try std.testing.expectApproxEqAbs(
        @as(f64, 355.4),
        topography.units[0].geometric_aspect_degrees,
        1.0e-12,
    );
    try topography.validateCoverage(.{
        .west_column = 1,
        .north_row = 1,
        .east_column = 1,
        .south_row = 1,
    }, allocator);
    const full_domain = Domain{ .west_column = 1, .north_row = 1, .east_column = 2, .south_row = 2 };
    const unit_by_cell = try topography.buildCellUnitMap(full_domain, allocator);
    defer allocator.free(unit_by_cell);
    try std.testing.expectEqual(@as(usize, 4), unit_by_cell.len);
    try std.testing.expectEqualStrings("soil_profile", try topography.commonSoilProfileFile(unit_by_cell));
}

test "single-cell lookup rejects gaps and overlaps" {
    const allocator = std.testing.allocator;
    var topography = try build(allocator, &.{
        .{ 1, 1, 2, 1, "soil_a" },
        .{ 2, 1, 3, 1, "soil_b" },
    });
    defer topography.deinit();
    try std.testing.expectEqual(@as(usize, 0), try topography.unitForCell(1, 1));
    try std.testing.expectError(error.OverlappingTopographyUnits, topography.unitForCell(2, 1));
    try std.testing.expectError(error.IncompleteTopographyCoverage, topography.unitForCell(4, 1));
    try std.testing.expectError(error.InvalidTopographyCoordinate, topography.unitForCell(0, 1));
}

// A domain cell that no unit covers is fatal in `buildCellUnitMap`, but it
// also logs which cell was uncovered, and a logged error fails a Zig test.
// `unitForCell` above already covers the gap case through the same
// `IncompleteTopographyCoverage` error without the log, so that is where the
// behaviour is asserted.

test "differing soil profiles are reported rather than silently reconciled" {
    const allocator = std.testing.allocator;
    var topography = try build(allocator, &.{
        .{ 1, 1, 1, 1, "soil_a" },
        .{ 2, 1, 2, 1, "soil_b" },
    });
    defer topography.deinit();
    const unit_by_cell = try topography.buildCellUnitMap(
        .{ .west_column = 1, .north_row = 1, .east_column = 2, .south_row = 1 },
        allocator,
    );
    defer allocator.free(unit_by_cell);
    try std.testing.expectError(
        error.MultipleSoilProfileFiles,
        topography.commonSoilProfileFile(unit_by_cell),
    );
}

test "geometric aspect wraps exactly once past a full turn" {
    try std.testing.expectApproxEqAbs(
        @as(f64, 355.4),
        topography_module.geometricAspectDegrees(94.6),
        1.0e-12,
    );
    // 450 - 45 exceeds 360, so one turn is removed.
    try std.testing.expectApproxEqAbs(
        @as(f64, 45),
        topography_module.geometricAspectDegrees(45),
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 90),
        topography_module.geometricAspectDegrees(0),
        1.0e-12,
    );
}

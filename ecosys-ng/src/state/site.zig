const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");

pub const LateralConnectionMode = enum(u8) {
    connected = 1,
    disconnected = 3,
};

pub const Site = struct {
    allocator: std.mem.Allocator,
    elevation_m: f64,
    mean_annual_air_temperature_c: f64,
    water_table_mode: u8,
    /// Terrain values that used to live in the per-cell topography file,
    /// which is gone: a cell's location now comes from the grid-cell input
    /// record, so the four remaining values belong with the rest of that
    /// cell's site description. The legacy file's second slope column was
    /// never read by any process and is not carried over.
    compass_aspect_degrees: f64,
    slope_degrees: f64,
    initial_snowpack_depth_m: f64,
    atmospheric_oxygen_umol_mol: f64,
    atmospheric_nitrogen_umol_mol: f64,
    atmospheric_co2_umol_mol: f64,
    atmospheric_methane_umol_mol: f64,
    atmospheric_nitrous_oxide_umol_mol: f64,
    atmospheric_ammonia_umol_mol: f64,
    ecosystem_type: i32,
    salinity_enabled: bool,
    erosion_mode: i32,
    lateral_connection_mode: LateralConnectionMode,
    initial_water_table_depth_m: f64,
    natural_water_table_surface_slope: f64,
    artificial_water_table_depth_m: ?f64,
    artificial_water_table_surface_slope: ?f64,
    /// North, east, south, west, matching READI's record order.
    surface_runoff_boundary_fraction: [4]f64,
    natural_water_table_distance_m: [4]f64,
    natural_subsurface_exchange_fraction: [4]f64,
    lower_boundary_exchange_fraction: f64,
    artificial_water_table_distance_m: [4]f64,
    artificial_subsurface_exchange_fraction: [4]f64,
    horizontal_cell_widths_m: []f64,
    vertical_cell_widths_m: []f64,

    pub fn deinit(self: *Site) void {
        self.allocator.free(self.horizontal_cell_widths_m);
        self.allocator.free(self.vertical_cell_widths_m);
        self.* = undefined;
    }

    /// Legacy IERSNG modes 1 and 3 include erosion. Mode -1 disables all
    /// profile disturbance, 0 is freeze-thaw only, and 2 is freeze-thaw plus
    /// soil-organic-matter gain/loss.
    pub fn erosionEnabled(self: Site) bool {
        return self.erosion_mode == 1 or self.erosion_mode == 3;
    }

    /// Aspect measured counterclockwise from east, the convention every
    /// radiation consumer uses. Kept as a function of the compass input so
    /// there is one definition of the conversion.
    pub fn geometricAspectDegrees(self: Site) f64 {
        const geometric = 450.0 - self.compass_aspect_degrees;
        return if (geometric >= 360.0) geometric - 360.0 else geometric;
    }
};

/// Parses strict, line-aware runtime site records.
pub fn parse(allocator: std.mem.Allocator, source: []const u8, east_column: usize, south_row: usize) !Site {
    if (east_column == 0 or south_row == 0) return error.InvalidSiteDimensions;
    var records = delimited_input.records(source);
    var record1 = delimited_input.recordTokens(try nextRecord(&records));
    var record2 = delimited_input.recordTokens(try nextRecord(&records));
    var record3 = delimited_input.recordTokens(try nextRecord(&records));
    var record4 = delimited_input.recordTokens(try nextRecord(&records));

    var result: Site = undefined;
    result.allocator = allocator;
    result.elevation_m = try number(f64, &record1);
    result.mean_annual_air_temperature_c = try number(f64, &record1);
    result.water_table_mode = try number(u8, &record1);
    result.compass_aspect_degrees = try number(f64, &record1);
    result.slope_degrees = try number(f64, &record1);
    result.initial_snowpack_depth_m = try number(f64, &record1);
    result.atmospheric_oxygen_umol_mol = try number(f64, &record2);
    result.atmospheric_nitrogen_umol_mol = try number(f64, &record2);
    result.atmospheric_co2_umol_mol = try number(f64, &record2);
    result.atmospheric_methane_umol_mol = try number(f64, &record2);
    result.atmospheric_nitrous_oxide_umol_mol = try number(f64, &record2);
    result.atmospheric_ammonia_umol_mol = try number(f64, &record2);
    result.ecosystem_type = try number(i32, &record3);
    result.salinity_enabled = (try number(i32, &record3)) != 0;
    result.erosion_mode = try number(i32, &record3);
    result.lateral_connection_mode = switch (try number(u8, &record3)) {
        1 => .connected,
        3 => .disconnected,
        else => return error.InvalidLateralConnectionMode,
    };
    result.initial_water_table_depth_m = try number(f64, &record3);
    result.natural_water_table_surface_slope = try number(f64, &record3);
    for (&result.surface_runoff_boundary_fraction) |*value| value.* = try number(f64, &record4);
    for (&result.natural_water_table_distance_m) |*value| value.* = try number(f64, &record4);
    for (&result.natural_subsurface_exchange_fraction) |*value| value.* = try number(f64, &record4);
    result.lower_boundary_exchange_fraction = try number(f64, &record4);
    try requireEnd(&record1);
    try requireEnd(&record2);
    try requireEnd(&record3);
    try requireEnd(&record4);
    if (result.water_table_mode >= 3) {
        var artificial_table = delimited_input.recordTokens(try nextRecord(&records));
        result.artificial_water_table_depth_m = try number(f64, &artificial_table);
        result.artificial_water_table_surface_slope = try number(f64, &artificial_table);
        try requireEnd(&artificial_table);
        var artificial_boundaries = delimited_input.recordTokens(try nextRecord(&records));
        for (&result.artificial_water_table_distance_m) |*value| value.* = try number(f64, &artificial_boundaries);
        for (&result.artificial_subsurface_exchange_fraction) |*value| value.* = try number(f64, &artificial_boundaries);
        try requireEnd(&artificial_boundaries);
    } else {
        result.artificial_water_table_depth_m = null;
        result.artificial_water_table_surface_slope = null;
        result.artificial_water_table_distance_m = [_]f64{0} ** 4;
        result.artificial_subsurface_exchange_fraction = [_]f64{0} ** 4;
    }

    var horizontal_widths = delimited_input.recordTokens(try nextRecord(&records));
    var vertical_widths = delimited_input.recordTokens(try nextRecord(&records));

    result.horizontal_cell_widths_m = try allocator.alloc(f64, east_column);
    errdefer allocator.free(result.horizontal_cell_widths_m);
    for (result.horizontal_cell_widths_m) |*width| width.* = try number(f64, &horizontal_widths);
    result.vertical_cell_widths_m = try allocator.alloc(f64, south_row);
    errdefer allocator.free(result.vertical_cell_widths_m);
    for (result.vertical_cell_widths_m) |*width| width.* = try number(f64, &vertical_widths);
    try requireEnd(&horizontal_widths);
    try requireEnd(&vertical_widths);
    if (records.next() != null) return error.TrailingSiteRecord;
    try validate(result);
    return result;
}

fn validate(site: Site) !void {
    if (!std.math.isFinite(site.elevation_m)) return error.InvalidElevation;
    if (!std.math.isFinite(site.mean_annual_air_temperature_c)) return error.InvalidMeanAnnualTemperature;
    if (site.water_table_mode > 4) return error.InvalidWaterTableMode;
    // Aspect is a compass bearing, slope a non-negative inclination, and
    // snowpack depth a non-negative water-equivalent depth. These moved here
    // from the topography file and keep the same admissible ranges.
    if (!std.math.isFinite(site.compass_aspect_degrees) or
        site.compass_aspect_degrees < 0 or site.compass_aspect_degrees > 360)
        return error.InvalidCompassAspect;
    if (!std.math.isFinite(site.slope_degrees) or
        site.slope_degrees < 0 or site.slope_degrees > 90)
        return error.InvalidSlope;
    if (!std.math.isFinite(site.initial_snowpack_depth_m) or
        site.initial_snowpack_depth_m < 0)
        return error.InvalidInitialSnowpackDepth;
    if (site.erosion_mode < -1 or site.erosion_mode > 3) return error.InvalidErosionMode;
    if (!std.math.isFinite(site.natural_water_table_surface_slope) or site.natural_water_table_surface_slope < 0 or site.natural_water_table_surface_slope > 1) return error.InvalidWaterTableSlope;
    if (site.artificial_water_table_surface_slope) |slope| if (!std.math.isFinite(slope) or slope < 0 or slope > 1) return error.InvalidWaterTableSlope;
    for (site.surface_runoff_boundary_fraction) |value| if (!unitFraction(value)) return error.InvalidSurfaceRunoffBoundaryFraction;
    for (site.natural_water_table_distance_m) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidNaturalWaterTableDistance;
    for (site.natural_subsurface_exchange_fraction) |value| if (!unitFraction(value)) return error.InvalidNaturalSubsurfaceExchangeFraction;
    if (!unitFraction(site.lower_boundary_exchange_fraction)) return error.InvalidLowerBoundaryExchangeFraction;
    for (site.artificial_water_table_distance_m) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidArtificialWaterTableDistance;
    for (site.artificial_subsurface_exchange_fraction) |value| if (!unitFraction(value)) return error.InvalidArtificialSubsurfaceExchangeFraction;
    for (site.horizontal_cell_widths_m) |width| if (!std.math.isFinite(width) or width <= 0) return error.InvalidCellWidth;
    for (site.vertical_cell_widths_m) |width| if (!std.math.isFinite(width) or width <= 0) return error.InvalidCellWidth;
}

fn unitFraction(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 1;
}

fn nextRecord(records: anytype) ![]const u8 {
    const record = records.next() orelse return error.UnexpectedEndOfSiteFile;
    if (hasEmptyExplicitField(record)) return error.EmptySiteRecordValue;
    return record;
}

fn hasEmptyExplicitField(record: []const u8) bool {
    const content = if (std.mem.indexOfScalar(u8, record, '#')) |comment|
        record[0..comment]
    else
        record;
    const trimmed = std.mem.trim(u8, content, " \r");
    if (trimmed.len == 0) return false;

    var field_start: usize = 0;
    var saw_explicit_delimiter = false;
    for (trimmed, 0..) |byte, index| {
        if (byte != ',' and byte != '|' and byte != '\t') continue;
        if (std.mem.trim(u8, trimmed[field_start..index], " \r").len == 0)
            return true;
        field_start = index + 1;
        saw_explicit_delimiter = true;
    }
    return saw_explicit_delimiter and
        std.mem.trim(u8, trimmed[field_start..], " \r").len == 0;
}

fn requireEnd(tokens: anytype) !void {
    if (tokens.next() != null) return error.TrailingSiteRecordData;
}

fn number(comptime T: type, tokens: anytype) !T {
    const text = tokens.next() orelse return error.UnexpectedEndOfSiteRecord;
    return switch (@typeInfo(T)) {
        .float => std.fmt.parseFloat(T, text),
        .int => std.fmt.parseInt(T, text, 10),
        else => @compileError("unsupported site number type"),
    };
}

// Record 1 is elevation, mean annual air temperature, water-table mode, then
// the three terrain values that used to sit in the topography file. Latitude
// and longitude are absent: a cell's location comes from the grid-cell input
// record, which is also what resolves its row and column.
const test_site_source = "92 5.4 3 94.6 0.23 0.00\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n33 1 3 1 1.0 0.0\n0 1 1 0 10 0 10 0 1 0 1 0 0\n1.5 1.0\n0 10 0 10 0 1 0 1\n1\n1\n";

test "parse self-contained site with Fortran record semantics" {
    const source = test_site_source;
    var site = try parse(std.testing.allocator, source, 1, 1);
    defer site.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 92), site.elevation_m, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5.4), site.mean_annual_air_temperature_c, 1.0e-12);
    try std.testing.expectEqual(@as(i32, 33), site.ecosystem_type);
    try std.testing.expect(site.salinity_enabled);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), site.horizontal_cell_widths_m[0], 1.0e-12);
    try std.testing.expectEqual([_]f64{ 0, 1, 1, 0 }, site.surface_runoff_boundary_fraction);
    try std.testing.expectEqual(LateralConnectionMode.connected, site.lateral_connection_mode);
    try std.testing.expectEqual([_]f64{ 10, 0, 10, 0 }, site.natural_water_table_distance_m);
    try std.testing.expectEqual([_]f64{ 1, 0, 1, 0 }, site.natural_subsurface_exchange_fraction);
    try std.testing.expectEqual(@as(f64, 0), site.lower_boundary_exchange_fraction);
    try std.testing.expectEqual([_]f64{ 0, 10, 0, 10 }, site.artificial_water_table_distance_m);
    try std.testing.expectEqual([_]f64{ 0, 1, 0, 1 }, site.artificial_subsurface_exchange_fraction);
    try std.testing.expect(site.erosionEnabled());
}

// SITE-SALT-001 (historical -- see the 2026-09-18 audit correction below
// SITE-SALT-002). `salinity_enabled` is field 2 of site record 3, the legacy
// `READ(1,*)IETYPG,ISALTG,IERSNG,NCNG,...` at `readi.f:154`. This field IS read
// in production: `ecosys_ng.zig`'s domain initialization copies it per cell into
// `salinity_enabled_by_cell`, which gates soil/surface/plant salt chemistry,
// uptake, tillage and relayering throughout the tree (grep that array's name).
// SITE-SALT-001 originally flagged this field as write-only; that general gap
// has since been closed by binding those consumers to this field instead of
// `runscript.dynamic_plant_salts`. One narrow, still-open exception is recorded
// at SITE-SALT-002 below. This test still pins record 3's field order so a
// shift is caught here rather than by a wrong salt branch much later.
test "readi.f:154 site record 3 places ISALTG between IETYPG and IERSNG" {
    // IETYPG=33, ISALTG=0, IERSNG=1, NCNG=3: salinity off, erosion on,
    // laterally disconnected. Every neighbour differs from ISALTG, so reading
    // the wrong column cannot coincidentally produce this combination.
    const off = "92 5.4 3 94.6 0.23 0.00\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n33 0 1 3 1.0 0.0\n0 1 1 0 10 0 10 0 1 0 1 0 0\n1.5 1.0\n0 10 0 10 0 1 0 1\n1\n1\n";
    var site_off = try parse(std.testing.allocator, off, 1, 1);
    defer site_off.deinit();
    try std.testing.expectEqual(@as(i32, 33), site_off.ecosystem_type);
    try std.testing.expect(!site_off.salinity_enabled);
    try std.testing.expectEqual(@as(i32, 1), site_off.erosion_mode);
    try std.testing.expectEqual(LateralConnectionMode.disconnected, site_off.lateral_connection_mode);

    // ISALTG=1 with an unchanged ecosystem type flips only the salt flag.
    const on = "92 5.4 3 94.6 0.23 0.00\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n33 1 1 3 1.0 0.0\n0 1 1 0 10 0 10 0 1 0 1 0 0\n1.5 1.0\n0 10 0 10 0 1 0 1\n1\n1\n";
    var site_on = try parse(std.testing.allocator, on, 1, 1);
    defer site_on.deinit();
    try std.testing.expect(site_on.salinity_enabled);
    try std.testing.expectEqual(@as(i32, 33), site_on.ecosystem_type);
    try std.testing.expectEqual(@as(i32, 1), site_on.erosion_mode);

    // ISALTG is `.NE.0`, not `.EQ.1`: `readi.f:96` documents 0 and 1, and the
    // solute branch at `solute.f:589` tests inequality, so any nonzero value
    // selects dynamic salt chemistry.
    const two = "92 5.4 3 94.6 0.23 0.00\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n33 2 1 3 1.0 0.0\n0 1 1 0 10 0 10 0 1 0 1 0 0\n1.5 1.0\n0 10 0 10 0 1 0 1\n1\n1\n";
    var site_two = try parse(std.testing.allocator, two, 1, 1);
    defer site_two.deinit();
    try std.testing.expect(site_two.salinity_enabled);
}

// SITE-SALT-002. Ottawa's own site record, verbatim, selects DYNAMIC salt
// chemistry. This matters because production does not read this flag at all:
// every `ISALTG` gate in the tree is driven instead by
// `runscript.dynamic_plant_salts`, which Ottawa's
// `plant_pool_controls,no,...` record sets to FALSE. So for the production
// example the two flags disagree, and production takes the static/fixed-pH
// branch everywhere legacy takes the dynamic one. See
// `docs/traceability/isaltg_is_driven_by_the_wrong_flag.md`.
//
// The guard pins the site side of that disagreement. If someone "resolves"
// the conflation by editing the example's site file to `ISALTG=0` instead of
// wiring the flag through, this test fails and says so.
test "readi.f:154 the production Ottawa site record selects dynamic salt chemistry" {
    // Byte-for-byte record 3 of examples_ng-prod/Cool Temperate
    // Maize-Soybean ON/runottawa_input_files/landscape/f25si98
    const ottawa_record_three = "33 1 3 1 1.0 0.0";
    const source = "92 5.4 3 94.6 0.23 0.00\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n" ++
        ottawa_record_three ++
        "\n0.0 1.0 1.0 0.0 10.0 0.0 10.0 0.0 1.0 0.0 1.0 0.0 0.0\n1.5 1.0\n0.0 10.0 0.0 10.0 0.0 1.0 0.0 1.0\n1.0\n1.0\n";
    var site = try parse(std.testing.allocator, source, 1, 1);
    defer site.deinit();
    try std.testing.expect(site.salinity_enabled);
    // Neighbours pinned so a field shift cannot fake the above: IETYPG=33 is
    // the maize ecosystem type and IERSNG=3 is freeze-thaw+erosion+SOM.
    try std.testing.expectEqual(@as(i32, 33), site.ecosystem_type);
    try std.testing.expectEqual(@as(i32, 3), site.erosion_mode);
    try std.testing.expectEqual(LateralConnectionMode.connected, site.lateral_connection_mode);
}

test "site record one carries the terrain values the topography file used to hold" {
    var site = try parse(std.testing.allocator, test_site_source, 1, 1);
    defer site.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 94.6), site.compass_aspect_degrees, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.23), site.slope_degrees, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00), site.initial_snowpack_depth_m, 1.0e-12);
    // 450 - 94.6 stays below 360, so no wrap is applied.
    try std.testing.expectApproxEqAbs(@as(f64, 355.4), site.geometricAspectDegrees(), 1.0e-12);
}

test "geometric aspect wraps once past a full turn" {
    // A compass aspect below 90 degrees pushes 450 - aspect over 360.
    const source = "92 5.4 0 45 1 0\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n33 1 0 1 1.0 0.0\n0 1 1 0 10 0 10 0 1 0 1 0 0\n1\n1\n";
    var site = try parse(std.testing.allocator, source, 1, 1);
    defer site.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 45), site.geometricAspectDegrees(), 1.0e-12);
}

test "site rejects terrain values outside their physical domain" {
    const prefix = "92 5.4 0 ";
    const suffix = "\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n33 1 0 1 1.0 0.0\n0 1 1 0 10 0 10 0 1 0 1 0 0\n1\n1\n";
    inline for (.{
        .{ "361 1 0", error.InvalidCompassAspect },
        .{ "-1 1 0", error.InvalidCompassAspect },
        .{ "90 91 0", error.InvalidSlope },
        .{ "90 -1 0", error.InvalidSlope },
        .{ "90 1 -1", error.InvalidInitialSnowpackDepth },
    }) |case| {
        try std.testing.expectError(
            case[1],
            parse(std.testing.allocator, prefix ++ case[0] ++ suffix, 1, 1),
        );
    }
}

test "erosion mode follows the complete IERSNG option domain" {
    inline for ([_]i32{ -1, 0, 1, 2, 3 }) |mode| {
        var source_buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(
            &source_buffer,
            "92 5.4 0 94.6 0.23 0\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n33 1 {d} 1 1.0 0.0\n0 1 1 0 10 0 10 0 1 0 1 0 0\n1\n1\n",
            .{mode},
        );
        var site = try parse(std.testing.allocator, source, 1, 1);
        defer site.deinit();
        try std.testing.expectEqual(mode == 1 or mode == 3, site.erosionEnabled());
    }
}

test "erosion mode outside IERSNG domain fails immediately" {
    const source = "92 5.4 0 94.6 0.23 0\n2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n33 1 4 1 1.0 0.0\n0 1 1 0 10 0 10 0 1 0 1 0 0\n1\n1\n";
    try std.testing.expectError(error.InvalidErosionMode, parse(std.testing.allocator, source, 1, 1));
}

test "site records reject empty explicit delimiter fields" {
    inline for (.{
        "92,5.4,,0,94.6,0.23,0\n",
        "92|5.4| |0|94.6|0.23|0\n",
        "92\t5.4\t\t0\t94.6\t0.23\t0\n",
    }) |first_record| {
        const source = first_record ++
            "2.1E+05 7.8E+05 360.0 1.8 0.3 0.002\n" ++
            "33 1 3 1 1.0 0.0\n" ++
            "0 1 1 0 10 0 10 0 1 0 1 0 0\n" ++
            "1.5 1.0\n0 10 0 10 0 1 0 1\n1\n1\n";
        try std.testing.expectError(
            error.EmptySiteRecordValue,
            parse(std.testing.allocator, source, 1, 1),
        );
    }
}

test "site empty-field check preserves valid spacing and comments" {
    try std.testing.expect(!hasEmptyExplicitField(
        "92  5.4  0  94.6  0.23  0 # valid spaces",
    ));
    try std.testing.expect(!hasEmptyExplicitField(
        "92, 5.4 | 0\t94.6, 0.23, 0 # mixed delimiters",
    ));
    try std.testing.expect(!hasEmptyExplicitField("# comment only"));
}

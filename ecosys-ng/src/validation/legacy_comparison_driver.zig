// **A8a DISPOSITION: NOT A BINDING CANDIDATE. Do not bind, do not delete.**
//
// Turns a column map plus two output trees into a `Report` (`run` at `:63`).
// Translates no Fortran range, so no supersession verdict applies. It is kept
// separate from the CLI so it is testable against in-memory trees, which is
// what the `Tree` indirection at `:16` and `MemoryTree` at `:34` exist for.
//
// Reachability: `legacy_comparison_index.zig:11`; bound as `legacy.driver` at
// `tools/compare_legacy.zig:51`. It in turn reaches all four siblings at its
// own lines 8 through 11.
//
// Why the census calls this unbound and why that is not a defect.
// `src/ecosys_ng.zig` is not the only build root. `build.zig:51` makes
// `src/legacy_comparison_index.zig` the root of its own module, named
// `legacy_comparison_index` at `:62`, imported by `tools/compare_legacy.zig:46`
// and exercised by `legacy_comparison_tests` at `build.zig:136`. The comment at
// `build.zig:47--49` gives the reason in the project's own words: the
// instrument depends on its own aggregator "rather than `src/module_index.zig`,
// which lane A1 owns, so that building the harness never requires editing the
// composition root." `tools/gate.ps1:255` lists that index among the real build
// roots for its own orphan lint, so the gate already agrees this code is
// reached. Unbound here means unreached *from the model*, which is the intended
// arrangement.
//
// One anti-vacuity invariant to preserve, since it is the reason this harness
// can be trusted at all: `compare_legacy.has_side_effects = true` at
// `build.zig:87` must stay set. Per the comment at `:78--86`, without it the
// build runner caches the run and reports `compare-legacy cached` with exit 0
// *without executing the harness*, writing no report and reading no output
// tree. That is the `GATE-OTTAWA-NEVER-RAN` failure class. `expectExitCode(0)`
// at `:77` is what lets the instrument's verdict reach the gate.
//
// LEGACY-COMPARISON group of docs/traceability/a8a_validation_dispositions.md
//! Driver: turn a column map plus two output trees into a `Report`.
//!
//! Kept separate from the CLI so it is testable against in-memory trees. The
//! `Tree` indirection exists for exactly that reason: tests supply a map from
//! relative path to contents, and the front end supplies real files.

const std = @import("std");
const comparison = @import("legacy_comparison.zig");
const column_map = @import("legacy_comparison_column_map.zig");
const report_module = @import("legacy_comparison_report.zig");
const attribution_module = @import("legacy_comparison_attribution.zig");

/// A source of stream text keyed by relative path. `read` returns null when the
/// stream is absent, which the driver classifies rather than treats as fatal, so
/// a run that stopped early still yields a useful partial report.
pub const Tree = struct {
    context: *const anyopaque,
    readFn: *const fn (
        context: *const anyopaque,
        allocator: std.mem.Allocator,
        relative_path: []const u8,
    ) anyerror!?[]u8,

    pub fn read(
        self: Tree,
        allocator: std.mem.Allocator,
        relative_path: []const u8,
    ) anyerror!?[]u8 {
        return self.readFn(self.context, allocator, relative_path);
    }
};

/// An in-memory tree for tests and for A8's inventory front end.
pub const MemoryTree = struct {
    entries: []const Entry,

    pub const Entry = struct { path: []const u8, contents: []const u8 };

    fn readImpl(
        context: *const anyopaque,
        allocator: std.mem.Allocator,
        relative_path: []const u8,
    ) anyerror!?[]u8 {
        const self: *const MemoryTree = @ptrCast(@alignCast(context));
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, relative_path))
                return try allocator.dupe(u8, entry.contents);
        }
        return null;
    }

    pub fn tree(self: *const MemoryTree) Tree {
        return .{ .context = self, .readFn = readImpl };
    }
};

fn detail(comptime fmt: []const u8) []const u8 {
    return fmt;
}

/// Compare every stream in `map`. Never returns early on a per-stream problem:
/// the point of the instrument is to say what it could and could not measure.
pub fn run(
    allocator: std.mem.Allocator,
    map: column_map.Map,
    legacy_tree: Tree,
    modern_tree: Tree,
    attributions: attribution_module.Table,
) !report_module.Report {
    var streams: std.ArrayList(report_module.StreamReport) = .empty;
    errdefer {
        for (streams.items) |stream| allocator.free(stream.columns);
        streams.deinit(allocator);
    }

    for (map.streams) |stream_mapping| {
        const legacy_text = try legacy_tree.read(allocator, stream_mapping.legacy_path);
        defer if (legacy_text) |text| allocator.free(text);
        if (legacy_text == null) {
            try streams.append(allocator, .{
                .id = stream_mapping.id,
                .outcome = .legacy_missing,
                .detail = stream_mapping.legacy_path,
            });
            continue;
        }
        const modern_text = try modern_tree.read(allocator, stream_mapping.modern_path);
        defer if (modern_text) |text| allocator.free(text);
        if (modern_text == null) {
            try streams.append(allocator, .{
                .id = stream_mapping.id,
                .outcome = .modern_missing,
                .detail = stream_mapping.modern_path,
            });
            continue;
        }

        var legacy_table = comparison.parseLegacy(
            allocator,
            legacy_text.?,
            stream_mapping.cadence,
        ) catch |err| {
            try streams.append(allocator, .{
                .id = stream_mapping.id,
                .outcome = switch (err) {
                    comparison.Error.LegacyStreamEmpty => .legacy_empty,
                    else => .unparsable,
                },
                .detail = @errorName(err),
            });
            continue;
        };
        defer legacy_table.deinit();

        var modern_table = comparison.parseModernWithCadence(allocator, modern_text.?, stream_mapping.cadence) catch |err| {
            try streams.append(allocator, .{
                .id = stream_mapping.id,
                .outcome = switch (err) {
                    comparison.Error.ModernStreamEmpty => .modern_empty,
                    else => .unparsable,
                },
                .detail = @errorName(err),
            });
            continue;
        };
        defer modern_table.deinit();

        var alignment = comparison.alignRows(allocator, legacy_table, modern_table) catch |err| {
            try streams.append(allocator, .{
                .id = stream_mapping.id,
                .outcome = switch (err) {
                    comparison.Error.NoAlignedRows => .no_overlap,
                    else => .unparsable,
                },
                .detail = @errorName(err),
            });
            continue;
        };
        defer alignment.deinit();

        const columns = try allocator.alloc(
            report_module.ColumnReport,
            stream_mapping.columns.len,
        );
        errdefer allocator.free(columns);
        for (stream_mapping.columns, 0..) |mapping, index| {
            const legacy_column = legacy_table.columnIndex(mapping.legacy_heading);
            const modern_column = modern_table.columnIndex(mapping.modern_heading);
            if (legacy_column == null) {
                columns[index] = .{
                    .legacy_heading = mapping.legacy_heading,
                    .modern_heading = mapping.modern_heading,
                    .outcome = .legacy_column_missing,
                };
                continue;
            }
            if (modern_column == null) {
                columns[index] = .{
                    .legacy_heading = mapping.legacy_heading,
                    .modern_heading = mapping.modern_heading,
                    .outcome = .modern_column_missing,
                };
                continue;
            }
            columns[index] = .{
                .legacy_heading = mapping.legacy_heading,
                .modern_heading = mapping.modern_heading,
                .outcome = .compared,
                .conversion_factor = mapping.conversion.factor,
                .divergence = try comparison.compareColumn(
                    legacy_table,
                    legacy_column.?,
                    modern_table,
                    modern_column.?,
                    mapping.conversion,
                    mapping.tolerance,
                    alignment,
                ),
            };
            // Material means "outside its own justified tolerance". Only those
            // columns need a cause; everything else is agreement and is left as
            // `not_material` so the gap count stays honest.
            if (!columns[index].divergence.within()) {
                if (attributions.find(stream_mapping.id, mapping.legacy_heading)) |entry| {
                    columns[index].attribution = switch (entry.kind) {
                        .intentional => .intentional,
                        .suspected_defect => .suspected_defect,
                    };
                    columns[index].attribution_reference = entry.reference;
                } else {
                    columns[index].attribution = .unattributed;
                }
            }
        }
        try streams.append(allocator, .{
            .id = stream_mapping.id,
            .outcome = .compared,
            .aligned_rows = alignment.count(),
            .legacy_only_rows = alignment.legacy_only,
            .modern_only_rows = alignment.modern_only,
            .columns = columns,
        });
    }

    return .{
        .allocator = allocator,
        .streams = try streams.toOwnedSlice(allocator),
    };
}

/// Free the per-stream column slices `run` allocated.
pub fn deinitReport(report: *report_module.Report) void {
    for (report.streams) |stream| {
        if (stream.columns.len != 0) report.allocator.free(stream.columns);
    }
    report.deinit();
}

// ---------------------------------------------------------------------- tests

/// Most driver tests are about stream and column classification, not about
/// attribution, so they run with an empty attribution table. That is also the
/// strict setting: every material divergence then reports `unattributed`.
fn runForTest(
    map: column_map.Map,
    legacy: MemoryTree,
    modern: MemoryTree,
) !report_module.Report {
    var attributions = try attribution_module.parse(std.testing.allocator, "");
    defer attributions.deinit();
    return run(std.testing.allocator, map, legacy.tree(), modern.tree(), attributions);
}

const legacy_hourly =
    "    DOY     DATE    HOUR    SOIL_CO2_FLUX   O2_1            \n" ++
    "tag    0.042    01011998       1  0.1000000E+001  0.2000000E+001\n" ++
    "tag    0.083    01011998       2  0.1000000E+001  0.2000000E+001\n";

const modern_hourly =
    "year\tday_of_year\tmonth\tday\thour\tlon\tlat\tcarbon_dioxide_emission[umol m-2 s-1]\tdissolved_oxygen_concentration_layer_1[g O2 m-3 water]\n" ++
    "1998\t1\t1\t1\t1\t1\t1\t1.0e0\t2.0e0\n" ++
    "1998\t1\t1\t1\t2\t1\t1\t1.0e0\t2.0e0\n";

const map_source =
    "stream soil_hourly_carbon hourly legacy/ch1 modern/ch1.txt\n" ++
    "column SOIL_CO2_FLUX | carbon_dioxide_emission[umol m-2 s-1] | 1.0 | 0.0 | 1e-9 | 1e-9 | identical units\n" ++
    "column O2_1 | dissolved_oxygen_concentration_layer_1[g O2 m-3 water] | 1.0 | 0.0 | 1e-9 | 1e-9 | identical units\n";

test "driver compares a fully agreeing stream" {
    var map = try column_map.parse(std.testing.allocator, map_source);
    defer map.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{
        .{ .path = "modern/ch1.txt", .contents = modern_hourly },
    } };
    var report = try runForTest(map, legacy, modern);
    defer deinitReport(&report);
    try std.testing.expectEqual(@as(usize, 1), report.comparedStreams());
    try std.testing.expectEqual(@as(usize, 2), report.comparedColumns());
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        report.worstRelative("soil_hourly_carbon").?,
        0,
    );
}

test "a missing modern stream is reported, not skipped, and compares nothing" {
    var map = try column_map.parse(std.testing.allocator, map_source);
    defer map.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{} };
    var report = try runForTest(map, legacy, modern);
    defer deinitReport(&report);
    try std.testing.expectEqual(@as(usize, 0), report.comparedStreams());
    try std.testing.expectEqual(@as(usize, 1), report.incompleteStreams());
    try std.testing.expectEqual(
        report_module.StreamOutcome.modern_missing,
        report.streams[0].outcome,
    );
    try std.testing.expectEqual(
        @as(?f64, null),
        report.worstRelative("soil_hourly_carbon"),
    );
}

test "an empty modern stream is reported as empty, not as agreement" {
    var map = try column_map.parse(std.testing.allocator, map_source);
    defer map.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{
        .{ .path = "modern/ch1.txt", .contents = "" },
    } };
    var report = try runForTest(map, legacy, modern);
    defer deinitReport(&report);
    try std.testing.expectEqual(
        report_module.StreamOutcome.modern_empty,
        report.streams[0].outcome,
    );
    try std.testing.expectEqual(@as(usize, 0), report.comparedColumns());
}

test "a modern heading-only stream is reported as empty" {
    var map = try column_map.parse(std.testing.allocator, map_source);
    defer map.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{
        .{
            .path = "modern/ch1.txt",
            .contents = "year\tday_of_year\thour\tlon\tlat\tx[m]\n",
        },
    } };
    var report = try runForTest(map, legacy, modern);
    defer deinitReport(&report);
    try std.testing.expectEqual(
        report_module.StreamOutcome.modern_empty,
        report.streams[0].outcome,
    );
}

test "an unmapped modern column is reported per column, others still compare" {
    const partial_map =
        "stream soil_hourly_carbon hourly legacy/ch1 modern/ch1.txt\n" ++
        "column SOIL_CO2_FLUX | carbon_dioxide_emission[umol m-2 s-1] | 1.0 | 0.0 | 1e-9 | 1e-9 | identical units\n" ++
        "column CO2_LIT | litter_carbon_dioxide[g C m-3 water] | 1.0 | 0.0 | 1e-9 | 1e-9 | not yet emitted\n";
    var map = try column_map.parse(std.testing.allocator, partial_map);
    defer map.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{
        .{ .path = "modern/ch1.txt", .contents = modern_hourly },
    } };
    var report = try runForTest(map, legacy, modern);
    defer deinitReport(&report);
    try std.testing.expectEqual(@as(usize, 1), report.comparedColumns());
    try std.testing.expectEqual(
        report_module.ColumnOutcome.legacy_column_missing,
        report.streams[0].columns[1].outcome,
    );
}

test "a partially completed modern run yields a partial report over the overlap" {
    // Exactly the Ottawa situation: the modern run stops early, so the modern
    // stream is a prefix. A useful partial report is required, not a failure.
    const truncated_modern =
        "year\tday_of_year\tmonth\tday\thour\tlon\tlat\tcarbon_dioxide_emission[umol m-2 s-1]\tdissolved_oxygen_concentration_layer_1[g O2 m-3 water]\n" ++
        "1998\t1\t1\t1\t1\t1\t1\t1.0e0\t2.0e0\n";
    var map = try column_map.parse(std.testing.allocator, map_source);
    defer map.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{
        .{ .path = "modern/ch1.txt", .contents = truncated_modern },
    } };
    var report = try runForTest(map, legacy, modern);
    defer deinitReport(&report);
    try std.testing.expectEqual(@as(usize, 1), report.comparedStreams());
    try std.testing.expectEqual(@as(usize, 1), report.streams[0].aligned_rows);
    try std.testing.expectEqual(@as(usize, 1), report.streams[0].legacy_only_rows);
    try std.testing.expectEqual(@as(usize, 2), report.comparedColumns());
}

test "one broken stream does not stop the driver from measuring the others" {
    const two_streams = map_source ++
        "stream soil_hourly_water hourly legacy/wh1 modern/wh1.txt\n" ++
        "column EVAPN | evapotranspiration[mm] | 1.0 | 0.0 | 1e-9 | 1e-9 | identical units\n";
    var map = try column_map.parse(std.testing.allocator, two_streams);
    defer map.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{
        .{ .path = "modern/ch1.txt", .contents = modern_hourly },
    } };
    var report = try runForTest(map, legacy, modern);
    defer deinitReport(&report);
    try std.testing.expectEqual(@as(usize, 2), report.streams.len);
    try std.testing.expectEqual(@as(usize, 1), report.comparedStreams());
    try std.testing.expectEqual(
        report_module.StreamOutcome.legacy_missing,
        report.streams[1].outcome,
    );
}

/// A modern stream that disagrees with `legacy_hourly` on both columns, so the
/// attribution path has something to classify.
const diverging_modern =
    "year\tday_of_year\tmonth\tday\thour\tlon\tlat\tcarbon_dioxide_emission[umol m-2 s-1]\tdissolved_oxygen_concentration_layer_1[g O2 m-3 water]\n" ++
    "1998\t1\t1\t1\t1\t1\t1\t3.0e0\t-1.0e0\n" ++
    "1998\t1\t1\t1\t2\t1\t1\t3.0e0\t-1.0e0\n";

fn columnByHeading(
    stream: report_module.StreamReport,
    legacy_heading: []const u8,
) report_module.ColumnReport {
    for (stream.columns) |column| {
        if (std.mem.eql(u8, column.legacy_heading, legacy_heading)) return column;
    }
    unreachable;
}

test "a material divergence with no recorded cause is reported as unattributed" {
    var map = try column_map.parse(std.testing.allocator, map_source);
    defer map.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{
        .{ .path = "modern/ch1.txt", .contents = diverging_modern },
    } };
    var report = try runForTest(map, legacy, modern);
    defer deinitReport(&report);
    try std.testing.expectEqual(@as(usize, 2), report.materialColumns());
    try std.testing.expectEqual(@as(usize, 2), report.unattributedColumns());
}

test "an intentional change and a suspected defect are classified separately" {
    var map = try column_map.parse(std.testing.allocator, map_source);
    defer map.deinit();
    var attributions = try attribution_module.parse(
        std.testing.allocator,
        "attribution soil_hourly_carbon | SOIL_CO2_FLUX | intentional | docs/model_changes.md MC-GAS-EXTENSIVE | extensive-mass gas transport replaces the legacy concentration form\n" ++
            "attribution soil_hourly_carbon | O2_1 | suspected_defect | DISC-OUTPUT-O2-LAYER-INDEX | legacy slot 35 may not be modern layer 1\n",
    );
    defer attributions.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{
        .{ .path = "modern/ch1.txt", .contents = diverging_modern },
    } };
    var report = try run(
        std.testing.allocator,
        map,
        legacy.tree(),
        modern.tree(),
        attributions,
    );
    defer deinitReport(&report);
    try std.testing.expectEqual(@as(usize, 2), report.materialColumns());
    try std.testing.expectEqual(@as(usize, 0), report.unattributedColumns());
    const carbon = columnByHeading(report.streams[0], "SOIL_CO2_FLUX");
    try std.testing.expectEqual(report_module.Attribution.intentional, carbon.attribution);
    try std.testing.expectEqualStrings(
        "docs/model_changes.md MC-GAS-EXTENSIVE",
        carbon.attribution_reference,
    );
    const oxygen = columnByHeading(report.streams[0], "O2_1");
    try std.testing.expectEqual(
        report_module.Attribution.suspected_defect,
        oxygen.attribution,
    );
}

test "an agreeing column is never counted as an attribution gap" {
    var map = try column_map.parse(std.testing.allocator, map_source);
    defer map.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{
        .{ .path = "modern/ch1.txt", .contents = modern_hourly },
    } };
    var report = try runForTest(map, legacy, modern);
    defer deinitReport(&report);
    try std.testing.expectEqual(@as(usize, 0), report.materialColumns());
    try std.testing.expectEqual(@as(usize, 0), report.unattributedColumns());
    for (report.streams[0].columns) |column| {
        try std.testing.expectEqual(
            report_module.Attribution.not_material,
            column.attribution,
        );
    }
}

test "the divergence sign records direction, not only magnitude" {
    var map = try column_map.parse(std.testing.allocator, map_source);
    defer map.deinit();
    const legacy: MemoryTree = .{ .entries = &.{
        .{ .path = "legacy/ch1", .contents = legacy_hourly },
    } };
    const modern: MemoryTree = .{ .entries = &.{
        .{ .path = "modern/ch1.txt", .contents = diverging_modern },
    } };
    var report = try runForTest(map, legacy, modern);
    defer deinitReport(&report);
    // Modern 3.0 against legacy 1.0 runs high; modern -1.0 against legacy 2.0
    // runs low. Both are the same magnitude class, and only the sign separates
    // them.
    const carbon = columnByHeading(report.streams[0], "SOIL_CO2_FLUX");
    try std.testing.expectEqual(@as(u8, '+'), carbon.divergence.signCharacter());
    try std.testing.expectApproxEqAbs(
        @as(f64, 2.0),
        carbon.divergence.max_absolute_signed,
        1e-12,
    );
    const oxygen = columnByHeading(report.streams[0], "O2_1");
    try std.testing.expectEqual(@as(u8, '-'), oxygen.divergence.signCharacter());
    try std.testing.expectApproxEqAbs(
        @as(f64, -3.0),
        oxygen.divergence.max_absolute_signed,
        1e-12,
    );
}

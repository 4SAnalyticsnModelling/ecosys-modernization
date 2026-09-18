// **A8a DISPOSITION: NOT A BINDING CANDIDATE. Do not bind, do not delete.**
//
// Per-stream, per-column divergence report plus the stored-baseline ratchet.
// Translates no Fortran, so it cannot be superseded by a production owner; it
// is the instrument's output stage, with `render` at `:139`, `findRegressions`
// at `:342` and `renderBaseline` at `:415`.
//
// Reachability: `legacy_comparison_index.zig:10` and
// `legacy_comparison_driver.zig:10`; bound as `legacy.report` at
// `tools/compare_legacy.zig:50`.
//
// The classification design is the anti-vacuity guarantee and must survive any
// future edit: `missing`, `empty` and `unmapped_column` are *reported outcomes*
// and, in strict mode, failures, rather than streams silently dropped. A
// harness that passes when it measured nothing is worse than no harness.
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
//! Per-stream, per-column divergence report plus the stored-baseline ratchet.
//!
//! Two responsibilities that belong together because they share one record
//! shape:
//!
//! 1. Render a human-readable report giving, per column, max absolute
//!    divergence, max relative divergence, and the earliest divergent timestamp.
//! 2. Compare that report against a stored baseline and fail when divergence
//!    *worsens*, so `tools/gate.ps1 -Full` can ratchet quality down over time
//!    without demanding immediate agreement.
//!
//! Streams are classified rather than silently dropped. `missing`, `empty` and
//! `unmapped_column` are reported outcomes and, in strict mode, failures.

const std = @import("std");
const comparison = @import("legacy_comparison.zig");

/// Whether a material divergence has been traced to a cause. `not_material`
/// means the column is inside its justified tolerance, so there is nothing to
/// attribute; that is the common case and must not be reported as a gap.
pub const Attribution = enum {
    not_material,
    intentional,
    suspected_defect,
    unattributed,
};

/// What actually happened to one stream. Only `compared` produced numbers.
pub const StreamOutcome = enum {
    compared,
    legacy_missing,
    modern_missing,
    legacy_empty,
    modern_empty,
    unparsable,
    no_overlap,
};

pub const ColumnOutcome = enum { compared, legacy_column_missing, modern_column_missing };

pub const ColumnReport = struct {
    legacy_heading: []const u8,
    modern_heading: []const u8,
    outcome: ColumnOutcome,
    divergence: comparison.Divergence = .{},
    conversion_factor: f64 = 1.0,
    attribution: Attribution = .not_material,
    /// `model_changes.md` citation or discrepancy ID backing `attribution`.
    attribution_reference: []const u8 = "",
};

pub const StreamReport = struct {
    id: []const u8,
    outcome: StreamOutcome,
    /// Rows present in both tables. Zero whenever `outcome != .compared`.
    aligned_rows: usize = 0,
    legacy_only_rows: usize = 0,
    modern_only_rows: usize = 0,
    columns: []ColumnReport = &.{},
    detail: []const u8 = "",
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    streams: []StreamReport,

    pub fn deinit(self: *Report) void {
        self.allocator.free(self.streams);
        self.* = undefined;
    }

    pub fn comparedStreams(self: Report) usize {
        var total: usize = 0;
        for (self.streams) |stream| {
            if (stream.outcome == .compared) total += 1;
        }
        return total;
    }

    pub fn comparedColumns(self: Report) usize {
        var total: usize = 0;
        for (self.streams) |stream| {
            for (stream.columns) |column| {
                if (column.outcome == .compared) total += 1;
            }
        }
        return total;
    }

    pub fn incompleteStreams(self: Report) usize {
        return self.streams.len - self.comparedStreams();
    }

    /// Columns whose divergence is material and has no recorded cause. This is
    /// the number the contract cares about: nonzero divergence is expected and
    /// fine, *unexplained* divergence is the outstanding work.
    pub fn unattributedColumns(self: Report) usize {
        var total: usize = 0;
        for (self.streams) |stream| {
            for (stream.columns) |column| {
                if (column.outcome != .compared) continue;
                if (column.attribution == .unattributed) total += 1;
            }
        }
        return total;
    }

    pub fn materialColumns(self: Report) usize {
        var total: usize = 0;
        for (self.streams) |stream| {
            for (stream.columns) |column| {
                if (column.outcome != .compared) continue;
                if (column.attribution != .not_material) total += 1;
            }
        }
        return total;
    }

    /// Worst relative divergence across every compared column. This is the
    /// single scalar the baseline ratchet uses per stream; see `Baseline`.
    pub fn worstRelative(self: Report, stream_id: []const u8) ?f64 {
        for (self.streams) |stream| {
            if (!std.mem.eql(u8, stream.id, stream_id)) continue;
            if (stream.outcome != .compared) return null;
            var worst: f64 = 0;
            for (stream.columns) |column| {
                if (column.outcome != .compared) continue;
                worst = @max(worst, column.divergence.max_relative);
            }
            return worst;
        }
        return null;
    }
};

/// Render the full report. Every stream appears, including incomplete ones,
/// because "this stream produced no measurement" is the most important thing
/// the instrument can tell you.
pub fn render(report: Report, writer: *std.Io.Writer) !void {
    try writer.writeAll("# legacy divergence report\n\n");
    for (report.streams) |stream| {
        try writer.print("stream {s}: {t}", .{ stream.id, stream.outcome });
        if (stream.outcome == .compared) {
            try writer.print(
                " aligned_rows={d} legacy_only_rows={d} modern_only_rows={d}\n",
                .{ stream.aligned_rows, stream.legacy_only_rows, stream.modern_only_rows },
            );
        } else {
            try writer.print(" {s}\n", .{stream.detail});
            continue;
        }
        for (stream.columns) |column| {
            if (column.outcome != .compared) {
                try writer.print(
                    "  column {s} -> {s}: {t}\n",
                    .{ column.legacy_heading, column.modern_heading, column.outcome },
                );
                continue;
            }
            const divergence = column.divergence;
            try writer.print(
                "  column {s} -> {s}: rows={d} factor={e} max_absolute={e} max_relative={e}",
                .{
                    column.legacy_heading,
                    column.modern_heading,
                    divergence.compared_rows,
                    column.conversion_factor,
                    divergence.max_absolute,
                    divergence.max_relative,
                },
            );
            if (divergence.max_absolute_at) |timestamp| {
                try writer.print(" max_absolute_at={f}", .{timestamp});
            }
            try writer.print(
                " sign={c} max_absolute_signed={e}",
                .{ divergence.signCharacter(), divergence.max_absolute_signed },
            );
            if (divergence.earliest_divergent) |timestamp| {
                try writer.print(
                    " earliest_divergent={f} earliest_absolute={e} earliest_relative={e} earliest_signed={e} divergent_rows={d}",
                    .{
                        timestamp,
                        divergence.earliest_divergent_absolute,
                        divergence.earliest_divergent_relative,
                        divergence.earliest_divergent_signed,
                        divergence.divergent_rows,
                    },
                );
            } else {
                try writer.writeAll(" within_tolerance=true");
            }
            if (divergence.nonfinite_rows != 0) {
                try writer.print(" nonfinite_rows={d}", .{divergence.nonfinite_rows});
            }
            try writer.print(" attribution={t}", .{column.attribution});
            if (column.attribution_reference.len != 0) {
                try writer.print(" reference={s}", .{column.attribution_reference});
            }
            try writer.writeAll("\n");
        }
    }
    try writer.print(
        "\nsummary: streams={d} compared={d} incomplete={d} compared_columns={d}" ++
            " material_columns={d} unattributed_columns={d}\n",
        .{
            report.streams.len,
            report.comparedStreams(),
            report.incompleteStreams(),
            report.comparedColumns(),
            report.materialColumns(),
            report.unattributedColumns(),
        },
    );
    try writer.writeAll(
        "\nA nonzero divergence is not a failure. ecosys-ng deliberately replaces\n" ++
            "several legacy formulations, so this file is a bounded-divergence report,\n" ++
            "not an equality test. The only actionable line above is an\n" ++
            "`attribution=unattributed` column; see docs/validation.md, section\n" ++
            "\"Legacy comparison is a bounded-divergence report, never an equality test\".\n",
    );
}

/// A stored per-stream divergence and coverage record.
///
/// `# ` comments and blank lines are ignored; a record is
///
/// ```text
/// <stream_id> <worst_relative> <compared_columns> [<unattributed_worst_relative> <unattributed_columns>]
/// ```
///
/// `compared_columns` is part of the baseline so that losing coverage counts as
/// a regression: a run that silently compares fewer columns than the baseline is
/// a worsening even if every remaining column agrees perfectly.
///
/// The two trailing fields are what make this a bounded-divergence ratchet
/// rather than an equality test. `worst_relative` is recorded for the reader but
/// is **not** a pass criterion, because a column attributed to an intentional
/// ecosys-ng formulation change is *supposed* to diverge and may legitimately
/// diverge further as that formulation is completed. Only the unattributed
/// figures gate the exit status. The trailing pair is optional so an older
/// three-field baseline still parses; it then contributes no unattributed
/// allowance, which is the strict reading.
pub const Baseline = struct {
    pub const Entry = struct {
        stream_id: []const u8,
        worst_relative: f64,
        compared_columns: usize,
        unattributed_worst_relative: f64 = 0,
        unattributed_columns: usize = 0,
    };

    allocator: std.mem.Allocator,
    text: []u8,
    entries: []Entry,

    pub fn deinit(self: *Baseline) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.text);
        self.* = undefined;
    }

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Baseline {
        const owned = try allocator.dupe(u8, source);
        errdefer allocator.free(owned);
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(allocator);
        var lines = std.mem.tokenizeAny(u8, owned, "\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const id = fields.next() orelse return comparison.Error.MalformedDataFile;
            const worst_text = fields.next() orelse
                return comparison.Error.MalformedDataFile;
            const columns_text = fields.next() orelse
                return comparison.Error.MalformedDataFile;
            var entry: Entry = .{
                .stream_id = id,
                .worst_relative = std.fmt.parseFloat(f64, worst_text) catch
                    return comparison.Error.MalformedDataFile,
                .compared_columns = std.fmt.parseInt(usize, columns_text, 10) catch
                    return comparison.Error.MalformedDataFile,
            };
            if (fields.next()) |unattributed_worst_text| {
                const unattributed_columns_text = fields.next() orelse
                    return comparison.Error.MalformedDataFile;
                entry.unattributed_worst_relative =
                    std.fmt.parseFloat(f64, unattributed_worst_text) catch
                        return comparison.Error.MalformedDataFile;
                entry.unattributed_columns =
                    std.fmt.parseInt(usize, unattributed_columns_text, 10) catch
                        return comparison.Error.MalformedDataFile;
            }
            if (fields.next() != null) return comparison.Error.MalformedDataFile;
            try entries.append(allocator, entry);
        }
        return .{
            .allocator = allocator,
            .text = owned,
            .entries = try entries.toOwnedSlice(allocator),
        };
    }

    pub fn find(self: Baseline, stream_id: []const u8) ?Entry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.stream_id, stream_id)) return entry;
        }
        return null;
    }
};

pub const Regression = struct {
    stream_id: []const u8,
    reason: enum {
        unattributed_divergence_worsened,
        unattributed_coverage_grew,
        coverage_lost,
        stream_no_longer_compared,
        stream_absent_from_report,
    },
    baseline_worst_relative: f64 = 0,
    observed_worst_relative: f64 = 0,
    baseline_columns: usize = 0,
    observed_columns: usize = 0,
};

/// A relative slack on the baseline ceiling, so that a bit-level difference in
/// the last digit of a legacy value does not produce a spurious regression while
/// still catching any real worsening.
pub const baseline_slack: f64 = 1.0e-12;

/// Collect regressions of `report` against `baseline`. An empty result means the
/// gate may pass. Appends to `out`, which the caller owns.
///
/// Deliberately blind to attributed divergence, however large. ecosys-ng
/// replaces several legacy formulations on purpose, so a growing divergence in
/// a column attributed to a `model_changes.md` entry or a tracked discrepancy is
/// the model becoming *more* itself, not a regression. What regresses is:
/// unexplained divergence getting worse, unexplained divergence spreading to
/// more columns, and coverage being lost.
pub fn findRegressions(
    allocator: std.mem.Allocator,
    report: Report,
    baseline: Baseline,
    out: *std.ArrayList(Regression),
) !void {
    for (baseline.entries) |entry| {
        var found = false;
        for (report.streams) |stream| {
            if (!std.mem.eql(u8, stream.id, entry.stream_id)) continue;
            found = true;
            if (stream.outcome != .compared) {
                try out.append(allocator, .{
                    .stream_id = entry.stream_id,
                    .reason = .stream_no_longer_compared,
                    .baseline_worst_relative = entry.worst_relative,
                    .baseline_columns = entry.compared_columns,
                });
                break;
            }
            var observed_columns: usize = 0;
            var observed_unattributed_worst: f64 = 0;
            var observed_unattributed_columns: usize = 0;
            for (stream.columns) |column| {
                if (column.outcome != .compared) continue;
                observed_columns += 1;
                if (column.attribution != .unattributed) continue;
                observed_unattributed_columns += 1;
                observed_unattributed_worst = @max(
                    observed_unattributed_worst,
                    column.divergence.max_relative,
                );
            }
            if (observed_columns < entry.compared_columns) {
                try out.append(allocator, .{
                    .stream_id = entry.stream_id,
                    .reason = .coverage_lost,
                    .baseline_columns = entry.compared_columns,
                    .observed_columns = observed_columns,
                });
            }
            if (observed_unattributed_columns > entry.unattributed_columns) {
                try out.append(allocator, .{
                    .stream_id = entry.stream_id,
                    .reason = .unattributed_coverage_grew,
                    .baseline_columns = entry.unattributed_columns,
                    .observed_columns = observed_unattributed_columns,
                });
            }
            if (observed_unattributed_worst >
                entry.unattributed_worst_relative + baseline_slack)
            {
                try out.append(allocator, .{
                    .stream_id = entry.stream_id,
                    .reason = .unattributed_divergence_worsened,
                    .baseline_worst_relative = entry.unattributed_worst_relative,
                    .observed_worst_relative = observed_unattributed_worst,
                });
            }
            break;
        }
        if (!found) {
            try out.append(allocator, .{
                .stream_id = entry.stream_id,
                .reason = .stream_absent_from_report,
                .baseline_worst_relative = entry.worst_relative,
                .baseline_columns = entry.compared_columns,
            });
        }
    }
}

/// Emit a baseline file recording the current state, for `--update-baseline`.
pub fn renderBaseline(report: Report, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\# Per-stream divergence and coverage record.
        \\# Written by `zig build compare-legacy -- --update-baseline`.
        \\#
        \\# Fields:
        \\#   <stream_id> <worst_relative> <compared_columns>
        \\#   <unattributed_worst_relative> <unattributed_columns>
        \\#
        \\# Only the two unattributed fields gate the exit status. ecosys-ng
        \\# intentionally replaces several legacy formulations, so an attributed
        \\# divergence may legitimately grow; an unexplained one may not. Losing
        \\# compared-column coverage is a regression regardless.
        \\
    );
    for (report.streams) |stream| {
        if (stream.outcome != .compared) continue;
        var worst: f64 = 0;
        var columns: usize = 0;
        var unattributed_worst: f64 = 0;
        var unattributed_columns: usize = 0;
        for (stream.columns) |column| {
            if (column.outcome != .compared) continue;
            columns += 1;
            worst = @max(worst, column.divergence.max_relative);
            if (column.attribution != .unattributed) continue;
            unattributed_columns += 1;
            unattributed_worst = @max(unattributed_worst, column.divergence.max_relative);
        }
        try writer.print("{s} {e} {d} {e} {d}\n", .{
            stream.id,
            worst,
            columns,
            unattributed_worst,
            unattributed_columns,
        });
    }
}

// ---------------------------------------------------------------------- tests

fn testReport(streams: []StreamReport) Report {
    return .{ .allocator = std.testing.allocator, .streams = streams };
}

test "render names every stream, including ones that measured nothing" {
    var columns = [_]ColumnReport{
        .{
            .legacy_heading = "SOIL_CO2_FLUX",
            .modern_heading = "carbon_dioxide_emission[umol m-2 s-1]",
            .outcome = .compared,
            .divergence = .{
                .compared_rows = 24,
                .max_absolute = 2.0,
                .max_relative = 0.5,
                .max_absolute_at = .{ .year = 1998, .day_of_year = 1, .hour = 9 },
                .max_absolute_signed = -2.0,
                .earliest_divergent = .{ .year = 1998, .day_of_year = 1, .hour = 3 },
                .divergent_rows = 4,
            },
            .attribution = .intentional,
            .attribution_reference = "docs/model_changes.md MC-GAS-EXTENSIVE",
        },
        .{
            .legacy_heading = "CO2_LIT",
            .modern_heading = "litter_carbon_dioxide[g C m-3 water]",
            .outcome = .modern_column_missing,
        },
    };
    var streams = [_]StreamReport{
        .{
            .id = "soil_hourly_carbon",
            .outcome = .compared,
            .aligned_rows = 24,
            .legacy_only_rows = 6852,
            .columns = &columns,
        },
        .{
            .id = "soil_daily_phosphorus",
            .outcome = .modern_missing,
            .detail = "010101998f25pd1.txt not produced by the run",
        },
    };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try render(testReport(&streams), &bytes.writer);
    const text = bytes.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "earliest_divergent=year1998-day1-hour3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "max_absolute_at=year1998-day1-hour9") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "modern_column_missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "soil_daily_phosphorus: modern_missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "incomplete=1") != null);
    // The direction of the divergence and its recorded cause are both part of
    // the report, not derived by the reader.
    try std.testing.expect(std.mem.indexOf(u8, text, "sign=-") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "attribution=intentional") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "reference=docs/model_changes.md MC-GAS-EXTENSIVE",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unattributed_columns=0") != null);
    // The report states its own contract, so a reader cannot mistake a nonzero
    // divergence for a failure.
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "A nonzero divergence is not a failure",
    ) != null);
}

test "baseline round-trips through render and parse" {
    var columns = [_]ColumnReport{.{
        .legacy_heading = "A",
        .modern_heading = "a[m]",
        .outcome = .compared,
        .divergence = .{ .compared_rows = 3, .max_relative = 0.25, .divergent_rows = 1 },
        .attribution = .unattributed,
    }};
    var streams = [_]StreamReport{.{
        .id = "s1",
        .outcome = .compared,
        .aligned_rows = 3,
        .columns = &columns,
    }};
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try renderBaseline(testReport(&streams), &bytes.writer);
    var baseline = try Baseline.parse(std.testing.allocator, bytes.written());
    defer baseline.deinit();
    const entry = baseline.find("s1").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), entry.worst_relative, 1e-15);
    try std.testing.expectEqual(@as(usize, 1), entry.compared_columns);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.25),
        entry.unattributed_worst_relative,
        1e-15,
    );
    try std.testing.expectEqual(@as(usize, 1), entry.unattributed_columns);
}

test "worsened UNATTRIBUTED divergence is a regression and improvement is not" {
    var baseline = try Baseline.parse(std.testing.allocator, "s1 1e-3 1 1e-3 1\n");
    defer baseline.deinit();
    for ([_]f64{ 1e-2, 1e-4 }, 0..) |observed, index| {
        var columns = [_]ColumnReport{.{
            .legacy_heading = "A",
            .modern_heading = "a[m]",
            .outcome = .compared,
            .divergence = .{
                .compared_rows = 3,
                .max_relative = observed,
                .divergent_rows = 1,
            },
            .attribution = .unattributed,
        }};
        var streams = [_]StreamReport{.{
            .id = "s1",
            .outcome = .compared,
            .aligned_rows = 3,
            .columns = &columns,
        }};
        var regressions: std.ArrayList(Regression) = .empty;
        defer regressions.deinit(std.testing.allocator);
        try findRegressions(
            std.testing.allocator,
            testReport(&streams),
            baseline,
            &regressions,
        );
        if (index == 0) {
            try std.testing.expectEqual(@as(usize, 1), regressions.items.len);
            const expected: Regression = .{
                .stream_id = "s1",
                .reason = .unattributed_divergence_worsened,
                .baseline_worst_relative = 1e-3,
                .observed_worst_relative = 1e-2,
            };
            try std.testing.expectEqual(expected.reason, regressions.items[0].reason);
            try std.testing.expectApproxEqAbs(
                @as(f64, 1e-2),
                regressions.items[0].observed_worst_relative,
                0,
            );
        } else {
            try std.testing.expectEqual(@as(usize, 0), regressions.items.len);
        }
    }
}

test "losing column coverage is a regression at identical divergence" {
    var baseline = try Baseline.parse(std.testing.allocator, "s1 1e-3 2 1e-3 1\n");
    defer baseline.deinit();
    var columns = [_]ColumnReport{
        .{
            .legacy_heading = "A",
            .modern_heading = "a[m]",
            .outcome = .compared,
            .divergence = .{
                .compared_rows = 3,
                .max_relative = 1e-3,
                .divergent_rows = 1,
            },
            .attribution = .unattributed,
        },
        .{
            .legacy_heading = "B",
            .modern_heading = "b[m]",
            .outcome = .modern_column_missing,
        },
    };
    var streams = [_]StreamReport{.{
        .id = "s1",
        .outcome = .compared,
        .aligned_rows = 3,
        .columns = &columns,
    }};
    var regressions: std.ArrayList(Regression) = .empty;
    defer regressions.deinit(std.testing.allocator);
    try findRegressions(
        std.testing.allocator,
        testReport(&streams),
        baseline,
        &regressions,
    );
    try std.testing.expectEqual(@as(usize, 1), regressions.items.len);
    try std.testing.expectEqual(
        @as(usize, 1),
        regressions.items[0].observed_columns,
    );
}

test "a stream that stops being compared is a regression, not a silent pass" {
    var baseline = try Baseline.parse(
        std.testing.allocator,
        "s1 1e-3 1 1e-3 1\ns2 1e-3 1 1e-3 1\n",
    );
    defer baseline.deinit();
    var streams = [_]StreamReport{.{
        .id = "s1",
        .outcome = .modern_missing,
        .detail = "run stopped early",
    }};
    var regressions: std.ArrayList(Regression) = .empty;
    defer regressions.deinit(std.testing.allocator);
    try findRegressions(
        std.testing.allocator,
        testReport(&streams),
        baseline,
        &regressions,
    );
    try std.testing.expectEqual(@as(usize, 2), regressions.items.len);
    try std.testing.expectEqualStrings("s1", regressions.items[0].stream_id);
    try std.testing.expectEqualStrings("s2", regressions.items[1].stream_id);
}

test "a malformed baseline record is rejected" {
    try std.testing.expectError(
        comparison.Error.MalformedDataFile,
        Baseline.parse(std.testing.allocator, "s1 1e-3\n"),
    );
    try std.testing.expectError(
        comparison.Error.MalformedDataFile,
        Baseline.parse(std.testing.allocator, "s1 not_a_number 1\n"),
    );
    // A five-field record is the current form; a four-field one is a truncated
    // write and must not be read as "no unattributed columns".
    try std.testing.expectError(
        comparison.Error.MalformedDataFile,
        Baseline.parse(std.testing.allocator, "s1 1e-3 1 1e-3\n"),
    );
    try std.testing.expectError(
        comparison.Error.MalformedDataFile,
        Baseline.parse(std.testing.allocator, "s1 1e-3 1 1e-3 1 extra\n"),
    );
}

test "a large attributed divergence is never a regression" {
    // The central claim of the contract. The baseline permits no unattributed
    // divergence at all, yet a column diverging by 200% exits clean because its
    // cause is on record.
    var baseline = try Baseline.parse(std.testing.allocator, "s1 1e-3 1 0e0 0\n");
    defer baseline.deinit();
    for ([_]Attribution{ .intentional, .suspected_defect }) |kind| {
        var columns = [_]ColumnReport{.{
            .legacy_heading = "A",
            .modern_heading = "a[m]",
            .outcome = .compared,
            .divergence = .{
                .compared_rows = 3,
                .max_relative = 2.0,
                .divergent_rows = 3,
            },
            .attribution = kind,
        }};
        var streams = [_]StreamReport{.{
            .id = "s1",
            .outcome = .compared,
            .aligned_rows = 3,
            .columns = &columns,
        }};
        var regressions: std.ArrayList(Regression) = .empty;
        defer regressions.deinit(std.testing.allocator);
        try findRegressions(
            std.testing.allocator,
            testReport(&streams),
            baseline,
            &regressions,
        );
        try std.testing.expectEqual(@as(usize, 0), regressions.items.len);
    }
}

test "unexplained divergence spreading to more columns is a regression" {
    var baseline = try Baseline.parse(std.testing.allocator, "s1 2e0 2 2e0 1\n");
    defer baseline.deinit();
    var columns = [_]ColumnReport{
        .{
            .legacy_heading = "A",
            .modern_heading = "a[m]",
            .outcome = .compared,
            .divergence = .{ .compared_rows = 3, .max_relative = 2.0, .divergent_rows = 3 },
            .attribution = .unattributed,
        },
        .{
            .legacy_heading = "B",
            .modern_heading = "b[m]",
            .outcome = .compared,
            .divergence = .{ .compared_rows = 3, .max_relative = 1.0, .divergent_rows = 3 },
            .attribution = .unattributed,
        },
    };
    var streams = [_]StreamReport{.{
        .id = "s1",
        .outcome = .compared,
        .aligned_rows = 3,
        .columns = &columns,
    }};
    var regressions: std.ArrayList(Regression) = .empty;
    defer regressions.deinit(std.testing.allocator);
    try findRegressions(
        std.testing.allocator,
        testReport(&streams),
        baseline,
        &regressions,
    );
    try std.testing.expectEqual(@as(usize, 1), regressions.items.len);
    try std.testing.expectEqual(
        @as(usize, 2),
        regressions.items[0].observed_columns,
    );
}

test "a three-field legacy baseline still parses and permits nothing unexplained" {
    var baseline = try Baseline.parse(std.testing.allocator, "s1 1.6e0 8\n");
    defer baseline.deinit();
    const entry = baseline.find("s1").?;
    try std.testing.expectEqual(@as(usize, 8), entry.compared_columns);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        entry.unattributed_worst_relative,
        0,
    );
    try std.testing.expectEqual(@as(usize, 0), entry.unattributed_columns);
}

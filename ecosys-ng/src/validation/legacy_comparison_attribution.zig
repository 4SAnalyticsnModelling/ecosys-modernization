// **A8a DISPOSITION: NOT A BINDING CANDIDATE. Do not bind, do not delete.**
//
// Classifies each divergence as an intentional formulation change citing
// `docs/model_changes.md`, or a suspected defect citing a discrepancy ID in
// `docs/discrepancy_register.md`. Translates no Fortran range, so it cannot be
// superseded.
//
// Reachability: `legacy_comparison_index.zig:12` and
// `legacy_comparison_driver.zig:11`; bound as `legacy.attribution` at
// `tools/compare_legacy.zig:52`.
//
// The design decision worth protecting: a divergence with neither an
// intentional-change citation nor a register ID is `unattributed`, and that is
// the only interesting state, because it is work that has not been done.
// Nonzero divergence is deliberately never itself a failure here; this file
// carries no pass/fail policy beyond classification, and
// `tools/compare_legacy.zig` decides what to do with an unattributed
// regression. Do not move a pass/fail rule into this module.
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
// LEGACY-COMPARISON group of docs/traceability/a8a_validation_dispositions.md
//! Divergence attribution: the half of the contract that turns a number into
//! evidence.
//!
//! `docs/validation.md` "Legacy comparison is a bounded-divergence report, never
//! an equality test" requires that every *material* divergence be attributed to
//! one of exactly two things:
//!
//!   1. an **intentional** formulation change, citing its `docs/model_changes.md`
//!      entry; or
//!   2. a **suspected defect**, citing a discrepancy ID in
//!      `docs/discrepancy_register.md`.
//!
//! A divergence with neither is `unattributed`, which is the only interesting
//! state: it is work that has not been done. Nonzero divergence is never itself
//! a failure, so this file deliberately contains no pass/fail policy beyond
//! classification; `tools/compare_legacy.zig` decides what to do with an
//! unattributed *regression*.
//!
//! The attribution table is a reviewable data file rather than code for the same
//! reason the column map is: each row is a scientific claim, and a claim that
//! cannot be read without recompiling cannot be reviewed.
//!
//! Record form, one per line, `#` comments and blank lines ignored:
//!
//! ```text
//! attribution <stream_id> | <legacy_heading or *> | <intentional|suspected_defect> | <reference> | <note>
//! ```
//!
//! `*` attributes every column of the stream that no exact row already covers,
//! so a whole-stream cause is stated once instead of copied per layer.

const std = @import("std");
const comparison = @import("legacy_comparison.zig");

pub const Error = comparison.Error;

/// What a divergence was traced to.
pub const Kind = enum {
    /// A deliberate ecosys-ng formulation improvement. Legacy disagreement is
    /// the *expected* result and chasing it away would be the defect.
    intentional,
    /// A divergence believed to be a translation or physics error in ecosys-ng,
    /// tracked by a discrepancy ID until classified.
    suspected_defect,
};

pub const Entry = struct {
    stream_id: []const u8,
    /// The legacy heading, or `*` for every otherwise-unattributed column of the
    /// stream.
    legacy_heading: []const u8,
    kind: Kind,
    /// `docs/model_changes.md` citation for `.intentional`, discrepancy ID for
    /// `.suspected_defect`.
    reference: []const u8,
    note: []const u8,

    pub fn isWildcard(self: Entry) bool {
        return std.mem.eql(u8, self.legacy_heading, "*");
    }
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    entries: []Entry,

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.text);
        self.* = undefined;
    }

    /// Exact column rows win over the stream wildcard, so a stream-level cause
    /// can be stated once and then refined for the one layer that behaves
    /// differently.
    pub fn find(self: Table, stream_id: []const u8, legacy_heading: []const u8) ?Entry {
        var wildcard: ?Entry = null;
        for (self.entries) |entry| {
            if (!std.mem.eql(u8, entry.stream_id, stream_id)) continue;
            if (std.mem.eql(u8, entry.legacy_heading, legacy_heading)) return entry;
            if (entry.isWildcard() and wildcard == null) wildcard = entry;
        }
        return wildcard;
    }

    pub const empty_table: []const u8 = "";
};

fn nextField(iterator: *std.mem.SplitIterator(u8, .scalar)) ![]const u8 {
    const field = iterator.next() orelse return Error.MalformedDataFile;
    return std.mem.trim(u8, field, " \t\r");
}

/// An `.intentional` row must cite `model_changes.md`, and a `.suspected_defect`
/// row must cite an identifier, because "we changed it on purpose" without a
/// recorded change and "it is a bug" without a tracked ID are both unfalsifiable
/// and would let the instrument launder an unexplained number into a pass.
fn validateReference(kind: Kind, reference: []const u8) !void {
    if (reference.len == 0) return Error.MalformedDataFile;
    switch (kind) {
        .intentional => {
            if (std.mem.indexOf(u8, reference, "model_changes.md") == null)
                return Error.MalformedDataFile;
        },
        .suspected_defect => {
            // A discrepancy ID, e.g. `DISC-OUTPUT-...`, `GAS-002`, `HEAT-001`.
            if (std.mem.indexOfScalar(u8, reference, '-') == null)
                return Error.MalformedDataFile;
            for (reference) |byte| {
                if (byte == ' ') return Error.MalformedDataFile;
            }
        },
    }
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Table {
    const owned = try allocator.dupe(u8, source);
    errdefer allocator.free(owned);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var lines = std.mem.tokenizeAny(u8, owned, "\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "attribution "))
            return Error.MalformedDataFile;
        var fields = std.mem.splitScalar(u8, line["attribution ".len..], '|');
        const stream_id = try nextField(&fields);
        const heading = try nextField(&fields);
        const kind_text = try nextField(&fields);
        const reference = try nextField(&fields);
        const note = try nextField(&fields);
        if (fields.next() != null) return Error.MalformedDataFile;
        if (stream_id.len == 0 or heading.len == 0) return Error.MalformedDataFile;
        const kind: Kind = if (std.mem.eql(u8, kind_text, "intentional"))
            .intentional
        else if (std.mem.eql(u8, kind_text, "suspected_defect"))
            .suspected_defect
        else
            return Error.MalformedDataFile;
        try validateReference(kind, reference);
        // An attribution whose reasoning is blank is an assertion, not evidence.
        if (note.len == 0) return Error.MalformedDataFile;
        try entries.append(allocator, .{
            .stream_id = stream_id,
            .legacy_heading = heading,
            .kind = kind,
            .reference = reference,
            .note = note,
        });
    }

    return .{
        .allocator = allocator,
        .text = owned,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

// ---------------------------------------------------------------------- tests

const example =
    "# comment\n" ++
    "attribution soil_hourly_heat | * | intentional | docs/model_changes.md MC-HEAT-RICHARDS | explicit geometry and Richards coupling change the surface energy partition\n" ++
    "attribution soil_hourly_heat | TEMP_1 | suspected_defect | HEAT-001 | surface layer runs hot; day-1 closure failure is owned by A6\n" ++
    "attribution plant_hourly_water | STOM_RSC | suspected_defect | DISC-OUTPUT-PLANT-DORMANT-CANOPY-STATE | live resistance reported for a dormant canopy\n";

test "attribution rows parse, and an exact column row beats the stream wildcard" {
    var table = try parse(std.testing.allocator, example);
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 3), table.entries.len);

    const exact = table.find("soil_hourly_heat", "TEMP_1").?;
    try std.testing.expectEqual(Kind.suspected_defect, exact.kind);
    try std.testing.expectEqualStrings("HEAT-001", exact.reference);

    const wildcarded = table.find("soil_hourly_heat", "SOIL_H").?;
    try std.testing.expectEqual(Kind.intentional, wildcarded.kind);

    try std.testing.expect(table.find("soil_hourly_carbon", "CH4_FLUX") == null);
}

test "an intentional attribution must cite model_changes.md" {
    try std.testing.expectError(Error.MalformedDataFile, parse(
        std.testing.allocator,
        "attribution s | C | intentional | because I said so | note\n",
    ));
}

test "a suspected defect must cite a discrepancy identifier" {
    try std.testing.expectError(Error.MalformedDataFile, parse(
        std.testing.allocator,
        "attribution s | C | suspected_defect | probably wrong | note\n",
    ));
}

test "a blank note or an unknown kind is rejected rather than recorded" {
    try std.testing.expectError(Error.MalformedDataFile, parse(
        std.testing.allocator,
        "attribution s | C | intentional | docs/model_changes.md MC-1 |   \n",
    ));
    try std.testing.expectError(Error.MalformedDataFile, parse(
        std.testing.allocator,
        "attribution s | C | probably | docs/model_changes.md MC-1 | note\n",
    ));
}

test "a line that is not an attribution record is a malformed file, not ignored" {
    try std.testing.expectError(Error.MalformedDataFile, parse(
        std.testing.allocator,
        "column s | C | 1 | 0 | 1e-9 | 1e-7 | note\n",
    ));
}

test "an empty table parses and attributes nothing" {
    var table = try parse(std.testing.allocator, "# nothing yet\n");
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 0), table.entries.len);
    try std.testing.expect(table.find("s", "C") == null);
}

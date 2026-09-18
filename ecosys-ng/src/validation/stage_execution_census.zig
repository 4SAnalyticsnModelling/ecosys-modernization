//! Records whether each named science stage has ever been entered, and when.
//!
//! Binding is not execution. A stage can be fully translated, exported from
//! `module_index.zig`, covered by unit tests, and called from a production
//! dispatch site, and still never run for a single simulated hour, because the
//! gate in front of it is false for the entire horizon. The Ottawa deck is a
//! maize-soybean rotation whose plant call sites sit behind planting gates, so
//! "translated" and "exercised on the deck" are different claims and the
//! project has repeatedly conflated them.
//!
//! This census makes the difference measurable rather than arguable. Each
//! instrumented site calls `record`, which is a bounds-checked array write on
//! a fixed-size struct: no allocation, no formatting, and no clock read on the
//! hot path. The report at the end of a run names every stage that was never
//! entered, which is the list the project needs in order to state honestly
//! which science its evidence actually covers.
//!
//! Deliberately NOT a profiler. `hourly_process_driver.zig` already emits
//! `TEMP_PROFILE <name> elapsed_ms=` markers, and those were measured costing
//! ~584 us per line, inflating the very hourly figures they were added to
//! measure. This records one integer per stage and reads no clock, so it can
//! stay on in production.

const std = @import("std");

/// Every stage whose execution is claimed but unproven.
///
/// A variant with no `record` call anywhere would report as never-executed
/// forever, which is indistinguishable from the real finding and would be
/// exactly the sort of false evidence this census exists to remove. So
/// instrumentation status is explicit: `instrumented` lists the variants that
/// have a live call site, and `report` separates "ran zero times" from "not
/// yet instrumented". Wiring a stage means adding its `record` call AND its
/// name to `instrumented`, and the test below fails if that list names a
/// variant that does not exist.
///
/// Names are grouped by the question each answers. The growing-season group
/// exists because roughly the whole horizon past emergence is unexercised, and
/// the calendar group because the deck is six forcing years repeated five
/// times with continuous state, so the wrap and repeat transitions are where
/// the untested calendar logic lives.
pub const Stage = enum {
    // Growing season: gated on a planting date the short horizon never reaches.
    plant_pre_emergence,
    /// The emergence refresh RAN. It runs unconditionally once plant state
    /// exists, so a nonzero count here says nothing about the plant -- it is a
    /// dispatch counter, kept because "the call site was reached" is still
    /// worth distinguishing from "the stage is unwired".
    plant_emergence_refresh,
    /// At least one plant is actually past emergence. This is the science
    /// question that `plant_emergence_refresh` does NOT answer.
    plant_emergence_occurred,
    /// The carboxylation kernel was DISPATCHED. Gated only on the presence of
    /// the canopy surface workspace, so this is a dispatch counter.
    canopy_carboxylation,
    /// Carbon was actually fixed, read from the accepted carbon-exchange
    /// ledger. This is the photosynthesis question.
    canopy_photosynthesis_occurred,
    canopy_energy_balance,
    root_uptake_geometry,
    root_water_uptake,
    symbiotic_nitrogen_fixation,
    nonsymbiotic_nitrogen_fixation,
    second_plant_species,

    // Management: gated on scheduled operations.
    harvest_reproductive_organs,
    harvest_branch_stalk_and_reserve,
    tillage_soil_application,
    tillage_aboveground_application,
    fertilizer_application,

    // Calendar and scene structure.
    day_of_year_reset,
    scene_transition,
    forcing_repeat_transition,

    /// NOT SCIENCE. A positive control, recorded unconditionally once per
    /// simulated hour.
    ///
    /// Every other instrumented stage in this census is one that legitimately
    /// may never fire, so a report of all zeros is ambiguous between "the
    /// model never ran this" and "the census is not wired up". The first run
    /// hit exactly that: 3 of 3 instrumented stages read zero over 346 hours,
    /// and the three were `day_of_year_reset` (needs day 365),
    /// `scene_transition` (needs a completed scene, ~52,560 hours) and
    /// `forcing_repeat_transition` (needs pass 2) -- all genuinely
    /// unreachable in 346 hours, but indistinguishable from a dead instrument
    /// by the numbers alone.
    ///
    /// This control resolves it: if it is nonzero the census is demonstrably
    /// live, so every other zero is a real finding about the model.
    census_positive_control,

    pub fn count() usize {
        return @typeInfo(Stage).@"enum".fields.len;
    }

    /// Stages with a live `record` call site. Everything else is reported as
    /// "not yet instrumented", never as "never executed".
    pub const instrumented = [_]Stage{
        .census_positive_control,
        .day_of_year_reset,
        .scene_transition,
        .forcing_repeat_transition,
        // Growing-season and management stages, recorded at dispatch sites
        // where the execution context is in scope. Each is placed past the
        // gate that can skip it, so a record means the stage genuinely ran
        // this hour rather than that its caller was reached.
        .canopy_energy_balance,
        .canopy_carboxylation,
        .canopy_photosynthesis_occurred,
        .symbiotic_nitrogen_fixation,
        .plant_emergence_refresh,
        .plant_emergence_occurred,
        .root_water_uptake,
        .nonsymbiotic_nitrogen_fixation,
        .tillage_soil_application,
        .fertilizer_application,
        // Read from the phenology state at the serial preparation stage, where
        // `active` and `emerged` are both in scope. Both are gated on ACTIVE,
        // because `active` is sized `cell_count * species_count` and an
        // inactive slot is a plant that is not there.
        .plant_pre_emergence,
        .second_plant_species,
        // Read from the ACCEPTED product ledger at the serial publish site,
        // before `publishPlantProducts` consumes it. `harvested_grain` is
        // written only by `harvestReproductiveOrgans`; the branch/stalk/reserve
        // stage sums the woody, nonstructural and nonfoliar export and litter
        // carbon, because an annual maize/soybean carries almost no woody mass
        // and gating on `woody` alone would under-report.
        .harvest_reproductive_organs,
        .harvest_branch_stalk_and_reserve,
        // Gated on `ApplyContext.aboveground_tillage_plant_count`, which
        // `applyEvent` increments only after the aboveground call succeeds.
        // `dispatchDatePhase`'s own return counts every operation kind, so it
        // could not answer this question.
        .tillage_aboveground_application,
    };

    /// Why the remaining stages are not instrumented, so that nobody "fixes" it by
    /// adding a racy counter.
    ///
    /// `Census.record` is a plain non-atomic read-modify-write
    /// (`slot.entries += 1`). Every instrumented site above is SERIAL stage-level
    /// code -- after `runKernelAcrossSerialTiles` returns, or in `ecosys_ng.zig`'s
    /// own dispatch -- never inside a tile kernel, because `CpuExecutor` dispatches
    /// cells across worker threads and a record from inside `applyTile` would be a
    /// data race. It would not show up on the Ottawa deck, which runs
    /// `tile_cell_count = 1`, which makes it exactly the kind of latent defect this
    /// tree should not acquire.
    ///
    /// ONE stage is left, and its blocker is the race above rather than effort.
    ///
    /// `root_uptake_geometry` is a leaf function, `rootUptakeGeometry` at
    /// `plant/root/water_balance.zig:459`, called per cell/layer/plant from
    /// inside the parallel water-balance kernel at `:317`. No serial point
    /// observes whether it ran, so it cannot be recorded without either an
    /// atomic counter or a per-worker census reduced after the join.
    ///
    /// Before doing that work, note that `root_water_uptake` IS instrumented
    /// and answers the science question "did the roots take up water". This
    /// variant only adds "was the geometry term evaluated", which is strictly
    /// weaker, so RETIRING the variant is probably the cheaper correct
    /// resolution. It is kept for now because deleting a census variant is a
    /// claim about what evidence the project needs, which is not a call to make
    /// while wiring counters.
    ///
    /// The other three stages that were blocked here were wired 2026-09-12 and
    /// are no longer listed. The blocker for them was that
    /// `disturbance_management_dispatch.applyEvent` and
    /// `plant_harvest_runtime.applyEvent` both return `!void`, so their serial
    /// call sites could not tell whether the branch fired. Resolved WITHOUT
    /// changing either signature: the harvest pair reads the accepted product
    /// ledger, and aboveground tillage reads a producer-owned counter on
    /// `ApplyContext`.
    ///
    /// Recorded as `STAGE-CENSUS-FOUR-STAGES-NEED-AN-APPLIED-COUNT-OR-AN-ATOMIC-001`.
    pub const uninstrumented_reason = struct {
        pub const inside_a_parallel_tile_kernel = [_]Stage{.root_uptake_geometry};
        pub const dispatch_returns_no_applied_count = [_]Stage{};
    };

    pub fn isInstrumented(self: Stage) bool {
        for (instrumented) |stage| if (stage == self) return true;
        return false;
    }
};

/// A stage's execution record. `entries` saturates rather than wrapping: the
/// question this answers is "did it ever run, and how much", and a wrapped
/// counter would silently answer "never" for the busiest stage in the model.
pub const Record = struct {
    entries: u64 = 0,
    first_entry_hour: ?u64 = null,
    last_entry_hour: ?u64 = null,
};

pub const Census = struct {
    records: [Stage.count()]Record = @splat(.{}),
    /// Highest hour the census was told about, so a report can state the
    /// horizon its "never executed" verdict is relative to. A stage that never
    /// ran in 336 hours is a much weaker claim than one that never ran in
    /// 52,560, and a report that omits the horizon invites the stronger
    /// reading.
    observed_hours: u64 = 0,

    pub fn record(self: *Census, stage: Stage, simulated_hour: u64) void {
        const slot = &self.records[@intFromEnum(stage)];
        if (slot.entries != std.math.maxInt(u64)) slot.entries += 1;
        if (slot.first_entry_hour == null) slot.first_entry_hour = simulated_hour;
        slot.last_entry_hour = simulated_hour;
        if (simulated_hour > self.observed_hours) self.observed_hours = simulated_hour;
    }

    /// Advances the horizon without attributing an entry to any stage. The
    /// driver calls this at the START of every hour, both so a run in which
    /// nothing fires still reports the horizon it covered, and so that
    /// `recordCurrent` has the current hour available.
    pub fn observeHour(self: *Census, simulated_hour: u64) void {
        if (simulated_hour > self.observed_hours) self.observed_hours = simulated_hour;
    }

    /// Records an entry at the hour the driver most recently announced.
    ///
    /// This exists so a dispatch site deep in the stage layer does not have to
    /// be handed the hour counter, which lives in the orchestration loop. The
    /// alternative -- threading an hour argument through every science
    /// signature -- is the thing the migration invariants forbid, and a site
    /// that guessed at the hour would corrupt the first/last figures that make
    /// this census readable.
    pub fn recordCurrent(self: *Census, stage: Stage) void {
        self.record(stage, self.observed_hours);
    }

    pub fn get(self: *const Census, stage: Stage) Record {
        return self.records[@intFromEnum(stage)];
    }

    pub fn executed(self: *const Census, stage: Stage) bool {
        return self.records[@intFromEnum(stage)].entries != 0;
    }

    /// Counts only INSTRUMENTED stages that never ran. An uninstrumented stage
    /// is unknown, not absent, and must never be counted as a finding.
    pub fn neverExecutedCount(self: *const Census) usize {
        var total: usize = 0;
        for (Stage.instrumented) |stage| total += @intFromBool(!self.executed(stage));
        return total;
    }

    pub fn instrumentedCount(_: *const Census) usize {
        return Stage.instrumented.len;
    }

    /// Writes the never-executed list, then the executed stages with their
    /// first entry. Both halves matter: the first is the honesty deliverable,
    /// and the second is what makes the first trustworthy, because a census
    /// whose every stage reads zero is far more likely to be unwired than to
    /// be evidence about the model.
    pub fn report(self: *const Census, writer: *std.Io.Writer) !void {
        try writer.print(
            "stage execution census: {d} of {d} INSTRUMENTED stages never executed across {d} simulated hour(s); {d} of {d} stages not yet instrumented\n",
            .{
                self.neverExecutedCount(),
                Stage.instrumented.len,
                self.observed_hours,
                Stage.count() - Stage.instrumented.len,
                Stage.count(),
            },
        );
        // The positive control decides whether the zeros mean anything.
        if (self.executed(.census_positive_control)) {
            try writer.writeAll(
                "  census is LIVE (positive control fired), so every zero below is a real " ++
                    "finding about the model, not a dead instrument.\n",
            );
        } else {
            try writer.writeAll(
                "  WARNING: the positive control never fired, so this census is NOT wired " ++
                    "up or never reached an hour. Treat every zero below as unknown, not as " ++
                    "evidence about the model.\n",
            );
        }
        try writer.writeAll("  never executed (instrumented, ran zero times -- this is the finding):\n");
        inline for (@typeInfo(Stage).@"enum".fields) |field| {
            const stage: Stage = @enumFromInt(field.value);
            if (stage.isInstrumented() and !self.executed(stage))
                try writer.print("    {s}\n", .{field.name});
        }
        try writer.writeAll("  executed:\n");
        // `if (...) { }` rather than `if (...) continue;`: `continue` in an
        // `inline for` is comptime control flow, which Zig rejects when the
        // condition is a runtime value.
        inline for (@typeInfo(Stage).@"enum".fields) |field| {
            const stage: Stage = @enumFromInt(field.value);
            const slot = self.get(stage);
            if (slot.entries != 0) {
                try writer.print(
                    "    {s} entries={d} first_hour={?d} last_hour={?d}\n",
                    .{ field.name, slot.entries, slot.first_entry_hour, slot.last_entry_hour },
                );
            }
        }
        try writer.writeAll(
            "  NOT YET INSTRUMENTED (execution unknown -- absence of a record here is NOT evidence):\n",
        );
        inline for (@typeInfo(Stage).@"enum".fields) |field| {
            const stage: Stage = @enumFromInt(field.value);
            if (!stage.isInstrumented()) try writer.print("    {s}\n", .{field.name});
        }
    }
};

test "a fresh census reports every INSTRUMENTED stage as never executed" {
    var census: Census = .{};
    try std.testing.expectEqual(Stage.instrumented.len, census.neverExecutedCount());
    try std.testing.expect(!census.executed(.harvest_reproductive_organs));
    try std.testing.expectEqual(@as(u64, 0), census.observed_hours);
}

test "uninstrumented stages are never counted as a never-executed finding" {
    // The whole point: a stage nobody wired must not masquerade as a measured
    // absence. neverExecutedCount ranges over the instrumented set only, so it
    // cannot exceed it however many variants the enum grows.
    var census: Census = .{};
    try std.testing.expect(census.neverExecutedCount() <= Stage.instrumented.len);
    try std.testing.expect(Stage.instrumented.len < Stage.count());
    // Taken from the blocked list rather than named literally. This test used
    // to hard-code `harvest_reproductive_organs`, and wiring that stage on
    // 2026-09-12 broke it -- a correct failure, but an avoidable one. Reading
    // the list means wiring the next stage cannot silently invalidate the test.
    try std.testing.expect(!uninstrumentedExample().isInstrumented());
    try std.testing.expect(Stage.day_of_year_reset.isInstrumented());
}

/// A stage that is genuinely not instrumented, for tests that need one.
///
/// Fails loudly rather than silently picking a wired stage if the blocked list
/// is ever emptied -- at which point every test using this needs redesigning,
/// because "an uninstrumented stage" would no longer exist. That is a good
/// problem and should be visible, not absorbed.
fn uninstrumentedExample() Stage {
    const blocked = Stage.uninstrumented_reason.inside_a_parallel_tile_kernel ++
        Stage.uninstrumented_reason.dispatch_returns_no_applied_count;
    if (blocked.len == 0) @compileError(
        "every stage is now instrumented: the tests that need an uninstrumented " ++
            "example must be redesigned rather than pointed at a wired stage",
    );
    return blocked[0];
}

test "every instrumented stage names a real variant and is listed once" {
    // Catches a typo or a duplicate in `instrumented`, which would otherwise
    // silently mis-state the denominator in the published report.
    for (Stage.instrumented, 0..) |outer, i| {
        var seen: usize = 0;
        for (Stage.instrumented) |inner| seen += @intFromBool(inner == outer);
        try std.testing.expectEqual(@as(usize, 1), seen);
        try std.testing.expect(i < Stage.count());
    }
}

test "record captures first and last entry and counts every entry" {
    var census: Census = .{};
    const uninstrumented = uninstrumentedExample();
    census.record(uninstrumented, 100);
    census.record(uninstrumented, 104);
    census.record(uninstrumented, 102);

    const slot = census.get(uninstrumented);
    try std.testing.expectEqual(@as(u64, 3), slot.entries);
    try std.testing.expectEqual(@as(?u64, 100), slot.first_entry_hour);
    // Last entry is the last RECORDED hour, not the maximum: stages are
    // recorded in dispatch order, and an out-of-order hour means the caller
    // is wrong, which a max() would hide.
    try std.testing.expectEqual(@as(?u64, 102), slot.last_entry_hour);
    // That stage is not instrumented, so recording it cannot change the
    // never-executed count, which ranges over the instrumented set.
    try std.testing.expectEqual(Stage.instrumented.len, census.neverExecutedCount());
    census.record(.day_of_year_reset, 24);
    try std.testing.expectEqual(Stage.instrumented.len - 1, census.neverExecutedCount());
}

test "the horizon advances on a bare hour observation with no stage entry" {
    var census: Census = .{};
    census.observeHour(336);
    try std.testing.expectEqual(@as(u64, 336), census.observed_hours);
    try std.testing.expectEqual(Stage.instrumented.len, census.neverExecutedCount());
}

test "the entry counter saturates instead of wrapping to never-executed" {
    var census: Census = .{};
    census.records[@intFromEnum(Stage.root_water_uptake)].entries = std.math.maxInt(u64);
    census.record(.root_water_uptake, 7);
    try std.testing.expectEqual(
        @as(u64, std.math.maxInt(u64)),
        census.get(.root_water_uptake).entries,
    );
    try std.testing.expect(census.executed(.root_water_uptake));
}

test "report names the unexecuted stages and warns when the census is unwired" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var census: Census = .{};
    census.observeHour(336);
    try census.report(&writer);
    const empty = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, empty, "WARNING: the positive control never fired") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "census is LIVE") == null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "across 336 simulated hour(s)") != null);
    // An uninstrumented stage must appear under the unknown heading, never
    // under the never-executed finding.
    const not_instrumented_at = std.mem.indexOf(u8, empty, "NOT YET INSTRUMENTED").?;
    const uninstrumented_at = std.mem.indexOf(u8, empty, @tagName(uninstrumentedExample())).?;
    try std.testing.expect(uninstrumented_at > not_instrumented_at);

    writer = std.Io.Writer.fixed(&buffer);
    census.record(.census_positive_control, 1);
    census.record(.day_of_year_reset, 24);
    try census.report(&writer);
    const populated = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, populated, "WARNING: the positive control never fired") == null);
    try std.testing.expect(std.mem.indexOf(u8, populated, "census is LIVE") != null);
    try std.testing.expect(std.mem.indexOf(u8, populated, "day_of_year_reset entries=1") != null);
}

test "a live positive control with other stages at zero is a real finding" {
    // The situation the first deck run produced: the control fires every hour
    // while the calendar stages legitimately cannot. That must read as LIVE
    // with genuine zeros, not as an unwired census.
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var census: Census = .{};
    for (1..347) |hour| census.record(.census_positive_control, @intCast(hour));
    try census.report(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "census is LIVE") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "census_positive_control entries=346") != null);
    try std.testing.expectEqual(@as(u64, 346), census.observed_hours);
    // The three calendar stages remain the finding.
    try std.testing.expectEqual(Stage.instrumented.len - 1, census.neverExecutedCount());
}

test "every stage variant has a distinct name usable in a report" {
    // Guards against a duplicated or empty variant name making two stages
    // indistinguishable in the published list.
    const fields = @typeInfo(Stage).@"enum".fields;
    inline for (fields, 0..) |outer, i| {
        try std.testing.expect(outer.name.len > 0);
        inline for (fields, 0..) |inner, j| {
            if (i != j) try std.testing.expect(!std.mem.eql(u8, outer.name, inner.name));
        }
    }
}

test "every stage is either instrumented or has a recorded reason why it cannot be" {
    // Makes the census's coverage claim TOTAL. Before this, a new stage could
    // be added and silently sit in neither list, reported forever as "not yet
    // instrumented" with no record of whether that was a decision or an
    // oversight. Now the two lists must partition the enum exactly, so adding a
    // variant forces a choice: wire it, or state why it cannot be wired.
    const blocked = Stage.uninstrumented_reason.inside_a_parallel_tile_kernel.len +
        Stage.uninstrumented_reason.dispatch_returns_no_applied_count.len;
    try std.testing.expectEqual(Stage.count(), Stage.instrumented.len + blocked);

    // No variant may appear twice across the three lists, and every variant
    // must appear once. A count alone would pass if one stage were listed twice
    // and another omitted.
    var seen = [_]u8{0} ** Stage.count();
    for (Stage.instrumented) |stage| seen[@intFromEnum(stage)] += 1;
    for (Stage.uninstrumented_reason.inside_a_parallel_tile_kernel) |stage| seen[@intFromEnum(stage)] += 1;
    for (Stage.uninstrumented_reason.dispatch_returns_no_applied_count) |stage| seen[@intFromEnum(stage)] += 1;
    for (seen, 0..) |times, index| {
        if (times != 1) {
            std.debug.print(
                "stage {s} appears {d} times across instrumented/blocked lists, expected exactly 1\n",
                .{ @tagName(@as(Stage, @enumFromInt(index))), times },
            );
            return error.StageCensusCoverageIsNotAPartition;
        }
    }

    // A stage with a recorded reason must not also claim to be instrumented,
    // which is the mistake that would make `report` call a blocked stage a
    // never-executed finding.
    for (Stage.uninstrumented_reason.inside_a_parallel_tile_kernel) |stage|
        try std.testing.expect(!stage.isInstrumented());
    for (Stage.uninstrumented_reason.dispatch_returns_no_applied_count) |stage|
        try std.testing.expect(!stage.isInstrumented());
}

test "the two phenology-derived stages are instrumented and distinguish an empty deck" {
    // `plant_pre_emergence` and `second_plant_species` were wired 2026-09-12.
    // Both are gated on ACTIVE, so a deck with no active plant records NEITHER
    // -- the honest answer. A naive "not emerged" test would have reported
    // pre-emergence as exercised on every hour of an empty deck.
    try std.testing.expect(Stage.plant_pre_emergence.isInstrumented());
    try std.testing.expect(Stage.second_plant_species.isInstrumented());

    var census: Census = .{};
    census.observeHour(5);
    // Nothing recorded: both must still read as never executed rather than as
    // uninstrumented, because they now have live call sites.
    try std.testing.expectEqual(@as(u64, 0), census.records[@intFromEnum(Stage.plant_pre_emergence)].entries);
    try std.testing.expectEqual(@as(u64, 0), census.records[@intFromEnum(Stage.second_plant_species)].entries);

    census.recordCurrent(.plant_pre_emergence);
    try std.testing.expectEqual(@as(u64, 1), census.records[@intFromEnum(Stage.plant_pre_emergence)].entries);
    try std.testing.expectEqual(@as(?u64, 5), census.records[@intFromEnum(Stage.plant_pre_emergence)].first_entry_hour);
    // Recording one must not disturb the other.
    try std.testing.expectEqual(@as(u64, 0), census.records[@intFromEnum(Stage.second_plant_species)].entries);
}

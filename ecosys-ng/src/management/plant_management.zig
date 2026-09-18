const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");

pub const PackedDate = struct {
    day: u8,
    month: u8,
    year: u16,

    pub fn parse(text: []const u8) !PackedDate {
        if (text.len != 8) return error.InvalidManagementDate;
        for (text) |character| if (!std.ascii.isDigit(character)) return error.InvalidManagementDate;
        const day = try std.fmt.parseInt(u8, text[0..2], 10);
        const month = try std.fmt.parseInt(u8, text[2..4], 10);
        const year = try std.fmt.parseInt(u16, text[4..8], 10);
        const calendar_validation_year: u16 = if (year == 0 or year == 9999) 2000 else year;
        _ = execution_calendar_date.dayOfYear(.{
            .day = day,
            .month = month,
            .year = calendar_validation_year,
        }) catch return error.InvalidManagementDate;
        return .{ .day = day, .month = month, .year = year };
    }

    pub fn isRecurring(self: PackedDate) bool {
        return self.year == 0 or self.year == 9999;
    }

    pub fn resolve(self: PackedDate, simulation_year: u16) !@import("../core/options.zig").Date {
        const resolved_year = if (self.isRecurring()) simulation_year else self.year;
        _ = execution_calendar_date.dayOfYear(.{
            .day = self.day,
            .month = self.month,
            .year = resolved_year,
        }) catch return error.ManagementDateInvalidForSimulationYear;
        return .{ .day = self.day, .month = self.month, .year = resolved_year };
    }

    pub fn dayOfYear(self: PackedDate, simulation_year: u16) !u16 {
        const resolved = try self.resolve(simulation_year);
        return execution_calendar_date.dayOfYear(.{
            .day = resolved.day,
            .month = resolved.month,
            .year = resolved.year,
        });
    }
};

pub const RemovalFractions = struct {
    leaf: f64,
    nonfoliar: f64,
    woody: f64,
    standing_dead: f64,
};

pub const HarvestKind = enum(u8) {
    none = 0,
    grain = 1,
    above_ground = 2,
    pruning = 3,
    animal_grazing = 4,
    insect_grazing = 6,
};

pub const TerminationKind = enum(u8) {
    retain = 0,
    terminate = 1,
    terminate_and_reseed = 2,
};

pub const Planting = struct {
    date: PackedDate,
    population_per_m2: f64,
    seed_depth_m: f64,
};

pub const HarvestEvent = struct {
    date: PackedDate,
    kind: HarvestKind,
    termination: TerminationKind,
    cutting_height_m_or_lai_fraction: f64,
    thinning_fraction_or_consumption_rate: f64,
    harvested_fraction: RemovalFractions,
    ecosystem_export_fraction: RemovalFractions,
};

pub const Schedule = struct {
    allocator: std.mem.Allocator,
    planting: Planting,
    harvest_events: []HarvestEvent,

    pub fn deinit(self: *Schedule) void {
        self.allocator.free(self.harvest_events);
        self.* = undefined;
    }

    pub fn eventsOnDate(self: *const Schedule, date: @import("../core/options.zig").Date) EventIterator {
        return .{ .events = self.harvest_events, .date = date };
    }
};

pub const EventIterator = struct {
    events: []const HarvestEvent,
    date: @import("../core/options.zig").Date,
    next_index: usize = 0,

    pub fn next(self: *EventIterator) ?*const HarvestEvent {
        while (self.next_index < self.events.len) {
            const event = &self.events[self.next_index];
            self.next_index += 1;
            if (event.date.day == self.date.day and event.date.month == self.date.month and (event.date.isRecurring() or event.date.year == self.date.year)) return event;
        }
        return null;
    }
};

pub const CatalogEntry = struct {
    name: []const u8,
    schedule: Schedule,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(CatalogEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.name);
            entry.schedule.deinit();
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn find(self: Catalog, name: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| if (std.mem.eql(u8, entry.name, name)) return index;
        return null;
    }

    pub fn appendFromSource(self: *Catalog, name: []const u8, source: []const u8) !usize {
        if (self.find(name)) |index| return index;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        var schedule = try parse(self.allocator, source);
        errdefer schedule.deinit();
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{ .name = owned_name, .schedule = schedule });
        return index;
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Schedule {
    var records = std.mem.splitScalar(u8, source, '\n');
    const planting_record = try nextRecord(&records) orelse return error.EmptyPlantManagement;
    var planting_tokens = delimited_input.recordTokens(planting_record);
    const planting = Planting{
        .date = try PackedDate.parse(planting_tokens.next() orelse return error.IncompletePlantingRecord),
        .population_per_m2 = try finiteNonnegative(&planting_tokens),
        .seed_depth_m = @max(try finiteNonnegative(&planting_tokens), 1.0e-6),
    };
    if (planting_tokens.next() != null)
        return error.TrailingPlantingRecordData;

    var events: std.ArrayList(HarvestEvent) = .empty;
    defer events.deinit(allocator);
    while (try nextRecord(&records)) |record| {
        var tokens = delimited_input.recordTokens(record);
        // The first three fields are bound to locals rather than initialized in
        // place because the fourth field's admissible domain depends on the
        // harvest kind, and Zig does not guarantee that a later struct field
        // initializer observes an earlier one.
        const date = try PackedDate.parse(tokens.next() orelse return error.IncompleteHarvestRecord);
        const kind = try harvestKind(try integer(u8, &tokens));
        const termination = try terminationKind(try integer(u8, &tokens));
        var event = HarvestEvent{
            .date = date,
            .kind = kind,
            .termination = termination,
            .cutting_height_m_or_lai_fraction = try cuttingHeightOrLeafAreaFraction(&tokens, kind),
            .thinning_fraction_or_consumption_rate = try fraction(&tokens),
            .harvested_fraction = try fractions(&tokens),
            .ecosystem_export_fraction = try fractions(&tokens),
        };
        if (event.termination == .terminate) event.thinning_fraction_or_consumption_rate = 1.0;
        if (tokens.next() != null)
            return error.TrailingHarvestRecordData;
        try events.append(allocator, event);
    }
    return .{ .allocator = allocator, .planting = planting, .harvest_events = try events.toOwnedSlice(allocator) };
}

fn harvestKind(value: u8) !HarvestKind {
    return switch (value) {
        0 => .none,
        1 => .grain,
        2 => .above_ground,
        3 => .pruning,
        4 => .animal_grazing,
        6 => .insect_grazing,
        else => error.InvalidHarvestKind,
    };
}

fn terminationKind(value: u8) !TerminationKind {
    return switch (value) {
        0 => .retain,
        1 => .terminate,
        2 => .terminate_and_reseed,
        else => error.InvalidTerminationKind,
    };
}

fn nextRecord(records: anytype) !?[]const u8 {
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record)) return error.EmptyManagementRecordValue;
        var tokens = delimited_input.recordTokens(record);
        if (tokens.next() != null) return record;
    }
    return null;
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

fn integer(comptime T: type, tokens: anytype) !T {
    return std.fmt.parseInt(T, tokens.next() orelse return error.IncompleteHarvestRecord, 10);
}

fn finiteNonnegative(tokens: anytype) !f64 {
    const value = try std.fmt.parseFloat(f64, tokens.next() orelse return error.IncompleteManagementRecord);
    if (!std.math.isFinite(value)) return error.NonfiniteManagementValue;
    if (value < 0.0) return error.NegativeManagementValue;
    return value;
}

fn fraction(tokens: anytype) !f64 {
    const value = try finiteNonnegative(tokens);
    if (value > 1.0) return error.InvalidManagementFraction;
    return value;
}

/// Fourth harvest field, which `readq.f:342-344` overloads on its sign:
///
///     HCUT = if harvesting: >0 = cutting height (m)
///                           <0 = fraction of LAI removed
///          = if grazing  : grazer biomass
///
/// The negative form is carried through to the runtime unchanged, because the
/// conversion to a physical height needs the current canopy leaf-area profile
/// and so cannot be done at parse time. `plant_harvest_runtime_apply`
/// `applyEventInternal` performs it per event via
/// `cuttingHeightFromLeafAreaRemoval`, the translation of the `ARLFY`/`ARLFR`
/// sweep at `grosub.f:8603-8625`, and gates it on the same
/// `IHVST <= 2` kind range used here.
///
/// A negative value is therefore a unit change rather than a relaxation, so it
/// gets its own domain: the magnitude is a fraction of leaf area and must lie
/// in `(0, 1]`. Zero is rejected because it is spelled `0` in the positive
/// branch already, and a "remove none of the leaf area" request written as a
/// negative zero-magnitude fraction is more likely a sign typo than an intent.
fn cuttingHeightOrLeafAreaFraction(tokens: anytype, kind: HarvestKind) !f64 {
    const value = try std.fmt.parseFloat(f64, tokens.next() orelse return error.IncompleteManagementRecord);
    if (!std.math.isFinite(value)) return error.NonfiniteManagementValue;
    if (value >= 0.0) return value;
    // Grazing spends this field on grazer biomass and the clumping-factor
    // reduction of `IHVST=3` is a multiplier, so neither admits the overload.
    if (@intFromEnum(kind) > @intFromEnum(HarvestKind.above_ground))
        return error.NegativeManagementValue;
    if (@abs(value) > 1.0) return error.InvalidLeafAreaRemovalFraction;
    return value;
}

fn fractions(tokens: anytype) !RemovalFractions {
    return .{ .leaf = try fraction(tokens), .nonfoliar = try fraction(tokens), .woody = try fraction(tokens), .standing_dead = try fraction(tokens) };
}

test "parse comma-delimited management schedule" {
    const allocator = std.testing.allocator;
    const source = @import("../core/test_fixtures.zig").plant_management_source;
    var schedule = try parse(allocator, source);
    defer schedule.deinit();
    try std.testing.expectEqual(@as(u16, 9999), schedule.planting.date.year);
    try std.testing.expectApproxEqAbs(@as(f64, 6.6), schedule.planting.population_per_m2, 1.0e-12);
    try std.testing.expectEqual(@as(usize, 1), schedule.harvest_events.len);
    try std.testing.expectEqual(TerminationKind.terminate, schedule.harvest_events[0].termination);
    try std.testing.expectEqual(@as(f64, 1.0), schedule.harvest_events[0].thinning_fraction_or_consumption_rate);
}

test "management event iterator matches recurring and exact years without allocation" {
    const events = [_]HarvestEvent{
        .{ .date = .{ .day = 1, .month = 8, .year = 9999 }, .kind = .grain, .termination = .retain, .cutting_height_m_or_lai_fraction = 0, .thinning_fraction_or_consumption_rate = 0, .harvested_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0 }, .ecosystem_export_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0 } },
        .{ .date = .{ .day = 1, .month = 8, .year = 2001 }, .kind = .above_ground, .termination = .terminate, .cutting_height_m_or_lai_fraction = 0, .thinning_fraction_or_consumption_rate = 1, .harvested_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 0 }, .ecosystem_export_fraction = .{ .leaf = 1, .nonfoliar = 1, .woody = 1, .standing_dead = 0 } },
        .{ .date = .{ .day = 2, .month = 8, .year = 9999 }, .kind = .pruning, .termination = .retain, .cutting_height_m_or_lai_fraction = 0, .thinning_fraction_or_consumption_rate = 0, .harvested_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0 }, .ecosystem_export_fraction = .{ .leaf = 0, .nonfoliar = 0, .woody = 0, .standing_dead = 0 } },
    };
    var schedule: Schedule = .{ .allocator = undefined, .planting = .{ .date = .{ .day = 1, .month = 1, .year = 9999 }, .population_per_m2 = 1, .seed_depth_m = 0.01 }, .harvest_events = @constCast(&events) };
    var iterator = schedule.eventsOnDate(.{ .day = 1, .month = 8, .year = 2001 });
    try std.testing.expectEqual(HarvestKind.grain, iterator.next().?.kind);
    try std.testing.expectEqual(HarvestKind.above_ground, iterator.next().?.kind);
    try std.testing.expect(iterator.next() == null);
}

test "parse space-delimited schedule and clamp zero seed depth" {
    const allocator = std.testing.allocator;
    var schedule = try parse(allocator, "30059999 300 0\n15099999 1 1 0 0 1 1 1 1 .95 .95 .95 .95\n");
    defer schedule.deinit();
    try std.testing.expectEqual(@as(f64, 1.0e-6), schedule.planting.seed_depth_m);
}

test "management catalog caches schedules" {
    const allocator = std.testing.allocator;
    const source = "01059999,10,0.02\n";
    var catalog = Catalog.init(allocator);
    defer catalog.deinit();
    const first = try catalog.appendFromSource("planting", source);
    const second = try catalog.appendFromSource("planting", source);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.items.len);
}

test "plant management rejects empty explicit delimiter fields" {
    try std.testing.expectError(
        error.EmptyManagementRecordValue,
        parse(std.testing.allocator, "30059999,,0\n01062001 1 1 0 0 1 1 1 1 .95 .95 .95 .95"),
    );
    try std.testing.expectError(
        error.EmptyManagementRecordValue,
        parse(
            std.testing.allocator,
            "30059999,300,0\n01062001|1|1|0|0|1|1|1|1|.95|.95|.95|",
        ),
    );
}

test "recurring management dates resolve against runtime year" {
    const recurring = try PackedDate.parse("29029999");
    try std.testing.expectEqual(@as(u16, 2024), (try recurring.resolve(2024)).year);
    try std.testing.expectError(error.ManagementDateInvalidForSimulationYear, recurring.resolve(2023));
}

test "recurring management dates honor source modulo-four leap years" {
    const recurring = try PackedDate.parse("29029999");
    try std.testing.expectEqual(@as(u16, 1900), (try recurring.resolve(1900)).year);
    try std.testing.expectEqual(@as(u16, 60), try recurring.dayOfYear(1900));
    try std.testing.expectError(error.ManagementDateInvalidForSimulationYear, recurring.resolve(1901));
}

test "management planting date resolves to runtime calendar day" {
    try std.testing.expectEqual(@as(u16, 61), try (try PackedDate.parse("01032024")).dayOfYear(2024));
    try std.testing.expectEqual(@as(u16, 60), try (try PackedDate.parse("01039999")).dayOfYear(2023));
}

test "plant management accepts comments without shifting event records" {
    var schedule = try parse(
        std.testing.allocator,
        \\# Planting is one compulsory three-value record.
        \\30059999,300,0 # zero seed depth is clamped
        \\   # Harvest remains one independent record.
        \\15099999|1|1|0|0|1|1|1|1|0.95|0.95|0.95|0.95 # terminate
        \\# End of schedule.
        ,
    );
    defer schedule.deinit();
    try std.testing.expectEqual(@as(usize, 1), schedule.harvest_events.len);
    try std.testing.expectEqual(
        TerminationKind.terminate,
        schedule.harvest_events[0].termination,
    );
}

test "plant management rejects every extra planting or harvest value" {
    try std.testing.expectError(
        error.TrailingPlantingRecordData,
        parse(
            std.testing.allocator,
            "30059999 300 0 99 # extra planting value\n",
        ),
    );
    try std.testing.expectError(
        error.TrailingHarvestRecordData,
        parse(
            std.testing.allocator,
            "30059999 300 0\n" ++
                "15099999 1 1 0 0 1 1 1 1 .95 .95 .95 .95 99 # extra\n",
        ),
    );
}

// PR-A2-LAI-HARVEST-001 / GROSUB-A2-006. `readq.f:342-344` overloads the fourth
// harvest field on its sign, and `grosub.f:8603-8625` decodes the negative form
// as a fraction of combined-canopy leaf area rather than a height in metres.
// The parser rejected every negative value, which made the LAI branch of
// `plant_harvest_runtime_apply.applyEventInternal` unreachable from any deck.
test "plant management accepts the legacy negative leaf-area-removal harvest" {
    const allocator = std.testing.allocator;
    // Verbatim first cut of `examples-ng/Cool Temperate Pasture Switzerland`
    // `oegra05i`, the record that failed with `NegativeManagementValue`.
    var schedule = try parse(
        allocator,
        "11052001 500 0.015\n" ++
            "10052005 2 0  -0.95 0 1 1 1 1 0.76 0.76 0.76 0.76\n",
    );
    defer schedule.deinit();
    try std.testing.expectEqual(@as(usize, 1), schedule.harvest_events.len);
    const event = schedule.harvest_events[0];
    try std.testing.expectEqual(HarvestKind.above_ground, event.kind);
    // Preserved with its sign: the runtime, not the parser, resolves the height,
    // because the conversion needs the live canopy leaf-area profile.
    try std.testing.expectEqual(@as(f64, -0.95), event.cutting_height_m_or_lai_fraction);
    // The remaining fields must not have shifted by a token.
    try std.testing.expectEqual(TerminationKind.retain, event.termination);
    try std.testing.expectEqual(@as(f64, 0), event.thinning_fraction_or_consumption_rate);
    try std.testing.expectEqual(@as(f64, 1), event.harvested_fraction.leaf);
    try std.testing.expectApproxEqAbs(@as(f64, 0.76), event.ecosystem_export_fraction.standing_dead, 1.0e-12);
}

test "plant management keeps a positive cutting height in metres" {
    // A height above any canopy must stay a height, not become a fraction.
    var schedule = try parse(
        std.testing.allocator,
        "11052001 500 0.015\n" ++
            "10052005 2 0 1000 0 1 1 1 1 0 0 0 0\n",
    );
    defer schedule.deinit();
    try std.testing.expectEqual(@as(f64, 1000), schedule.harvest_events[0].cutting_height_m_or_lai_fraction);
}

test "plant management bounds the leaf-area-removal fraction at unity" {
    // A magnitude above 1 is not a fraction of leaf area in any reading, and
    // `cuttingHeightFromLeafAreaRemoval` rejects it downstream, so admitting it
    // here would only move the failure past the point that can name the file.
    try std.testing.expectError(
        error.InvalidLeafAreaRemovalFraction,
        parse(
            std.testing.allocator,
            "11052001 500 0.015\n" ++
                "10052005 2 0 -1.05 0 1 1 1 1 0 0 0 0\n",
        ),
    );
    // The closed end of the domain is admissible: remove all leaf area.
    var schedule = try parse(
        std.testing.allocator,
        "11052001 500 0.015\n" ++
            "10052005 2 0 -1.0 0 1 1 1 1 0 0 0 0\n",
    );
    defer schedule.deinit();
    try std.testing.expectEqual(@as(f64, -1.0), schedule.harvest_events[0].cutting_height_m_or_lai_fraction);
}

test "plant management confines the sign overload to the harvesting kinds" {
    // `grosub.f:8603` gates the conversion on `IHVST.LE.2`. Beyond that the
    // field means grazer biomass (kinds 4 and 6) or a clumping-factor
    // multiplier (kind 3), and a negative value is meaningless in all three.
    inline for (.{
        "11052001 500 0.015\n10052005 3 0 -0.95 0 1 1 1 1 0 0 0 0\n",
        "11052001 500 0.015\n10052005 4 0 -0.95 0 1 1 1 1 0 0 0 0\n",
        "11052001 500 0.015\n10052005 6 0 -0.95 0 1 1 1 1 0 0 0 0\n",
    }) |source| {
        try std.testing.expectError(
            error.NegativeManagementValue,
            parse(std.testing.allocator, source),
        );
    }
}

test "plant management still rejects negative planting and fraction fields" {
    // The overload is confined to the one field that carries it. Nothing else
    // in the record gained a negative domain.
    try std.testing.expectError(
        error.NegativeManagementValue,
        parse(std.testing.allocator, "11052001 -500 0.015\n"),
    );
    try std.testing.expectError(
        error.NegativeManagementValue,
        parse(
            std.testing.allocator,
            "11052001 500 0.015\n" ++
                "10052005 2 0 0.05 -0.5 1 1 1 1 0 0 0 0\n",
        ),
    );
    try std.testing.expectError(
        error.NegativeManagementValue,
        parse(
            std.testing.allocator,
            "11052001 500 0.015\n" ++
                "10052005 2 0 0.05 0 1 1 1 1 0 0 0 -0.1\n",
        ),
    );
}

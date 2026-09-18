const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");
const PackedDate = @import("plant_management.zig").PackedDate;

pub const WaterChemistry_g_per_m3 = struct {
    ph: f64,
    ammonium_nitrogen: f64,
    nitrate_nitrogen: f64,
    phosphate_phosphorus: f64,
    aluminum: f64,
    iron: f64,
    calcium: f64,
    magnesium: f64,
    sodium: f64,
    potassium: f64,
    sulfate_sulfur: f64,
    chloride: f64,
};

pub const Trigger = union(enum) {
    soil_water_content: f64,
    canopy_water_potential_megapascal: f64,
};

pub const DayMonthHour = struct {
    day: u8,
    month: u8,
    hour: u8,

    pub fn parse(text: []const u8) !DayMonthHour {
        if (text.len != 8) return error.InvalidIrrigationWindow;
        for (text) |character| if (!std.ascii.isDigit(character)) return error.InvalidIrrigationWindow;
        const day = try std.fmt.parseUnsigned(u8, text[0..2], 10);
        const month = try std.fmt.parseUnsigned(u8, text[2..4], 10);
        const encoded_hour = try std.fmt.parseUnsigned(u16, text[4..8], 10);
        _ = execution_calendar_date.dayOfYear(.{ .day = day, .month = month, .year = 2000 }) catch return error.InvalidIrrigationWindow;
        if (encoded_hour % 100 != 0 or encoded_hour / 100 > 23) return error.InvalidIrrigationWindow;
        return .{ .day = day, .month = month, .hour = @intCast(encoded_hour / 100) };
    }
};

pub const Automated = struct {
    start: DayMonthHour,
    end: DayMonthHour,
    trigger: Trigger,
    refill_fraction_of_field_capacity: f64,
    evaluated_soil_depth_m: f64,
    application_depth_m: f64,
    water: WaterChemistry_g_per_m3,
};

pub const ScheduledEvent = struct {
    date: PackedDate,
    amount_mm: f64,
    first_hour: u8,
    last_hour: u8,
    application_depth_m: f64,
    water: WaterChemistry_g_per_m3,

    pub fn hourlyAmountM(self: ScheduledEvent) f64 {
        return self.amount_mm / 1000.0 / @as(f64, @floatFromInt(self.last_hour - self.first_hour + 1));
    }
};

pub const Schedule = union(enum) {
    automated: Automated,
    scheduled: []ScheduledEvent,

    pub fn deinit(self: *Schedule, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .automated => {},
            .scheduled => |events| allocator.free(events),
        }
        self.* = undefined;
    }
};

pub const CatalogEntry = struct { name: []const u8, schedule: Schedule };
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(CatalogEntry) = .empty,
    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.name);
            entry.schedule.deinit(self.allocator);
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
        var schedule = try parse(self.allocator, name, source);
        errdefer schedule.deinit(self.allocator);
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{ .name = owned_name, .schedule = schedule });
        return index;
    }
};

pub fn parse(allocator: std.mem.Allocator, filename: []const u8, source: []const u8) !Schedule {
    return if (std.ascii.startsWithIgnoreCase(filename, "auto"))
        .{ .automated = try parseAutomated(source) }
    else
        .{ .scheduled = try parseScheduled(allocator, source) };
}

fn parseAutomated(source: []const u8) !Automated {
    var tokens = delimited_input.tokens(source);
    const start = try DayMonthHour.parse(tokens.next() orelse return error.IncompleteAutomatedIrrigation);
    const end = try DayMonthHour.parse(tokens.next() orelse return error.IncompleteAutomatedIrrigation);
    const trigger_code = try std.fmt.parseUnsigned(u8, tokens.next() orelse return error.IncompleteAutomatedIrrigation, 10);
    const trigger_value = try finite(&tokens);
    const trigger: Trigger = switch (trigger_code) {
        0 => .{ .soil_water_content = try unitFraction(trigger_value) },
        1 => .{ .canopy_water_potential_megapascal = trigger_value },
        else => return error.InvalidIrrigationTrigger,
    };
    const result: Automated = .{
        .start = start,
        .end = end,
        .trigger = trigger,
        .refill_fraction_of_field_capacity = try fraction(&tokens),
        .evaluated_soil_depth_m = try nonnegative(&tokens),
        .application_depth_m = try nonnegative(&tokens),
        .water = try chemistry(&tokens),
    };
    if (tokens.next() != null) return error.TrailingAutomatedIrrigationData;
    return result;
}

fn parseScheduled(allocator: std.mem.Allocator, source: []const u8) ![]ScheduledEvent {
    var events: std.ArrayList(ScheduledEvent) = .empty;
    defer events.deinit(allocator);
    var records = std.mem.splitScalar(u8, source, '\n');
    while (try nextRecord(&records)) |record| {
        var tokens = delimited_input.recordTokens(record);
        const date_text = tokens.next() orelse unreachable;
        const date = try PackedDate.parse(date_text);
        const amount_mm = try nonnegative(&tokens);
        const first_hour = try hour(&tokens);
        const last_hour = try hour(&tokens);
        if (last_hour < first_hour) return error.InvalidIrrigationHourRange;
        const event: ScheduledEvent = .{ .date = date, .amount_mm = amount_mm, .first_hour = first_hour, .last_hour = last_hour, .application_depth_m = try nonnegative(&tokens), .water = try chemistry(&tokens) };
        if (tokens.next() != null) return error.TrailingScheduledIrrigationData;
        try events.append(allocator, event);
    }
    if (events.items.len == 0) return error.EmptyIrrigationSchedule;
    return events.toOwnedSlice(allocator);
}

fn nextRecord(records: anytype) !?[]const u8 {
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record)) return error.EmptyScheduledIrrigationRecordValue;
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

fn chemistry(tokens: anytype) !WaterChemistry_g_per_m3 {
    const ph = try finite(tokens);
    if (ph < 0.0 or ph > 14.0) return error.InvalidIrrigationPh;
    return .{ .ph = ph, .ammonium_nitrogen = try nonnegative(tokens), .nitrate_nitrogen = try nonnegative(tokens), .phosphate_phosphorus = try nonnegative(tokens), .aluminum = try nonnegative(tokens), .iron = try nonnegative(tokens), .calcium = try nonnegative(tokens), .magnesium = try nonnegative(tokens), .sodium = try nonnegative(tokens), .potassium = try nonnegative(tokens), .sulfate_sulfur = try nonnegative(tokens), .chloride = try nonnegative(tokens) };
}
fn finite(tokens: anytype) !f64 {
    const value = try std.fmt.parseFloat(f64, tokens.next() orelse return error.IncompleteIrrigationRecord);
    if (!std.math.isFinite(value)) return error.NonfiniteIrrigationValue;
    return value;
}
fn nonnegative(tokens: anytype) !f64 {
    const value = try finite(tokens);
    if (value < 0.0) return error.NegativeIrrigationValue;
    return value;
}
fn unitFraction(value: f64) !f64 {
    if (value < 0.0 or value > 1.0) return error.InvalidIrrigationFraction;
    return value;
}
fn fraction(tokens: anytype) !f64 {
    return unitFraction(try finite(tokens));
}
fn hour(tokens: anytype) !u8 {
    const value = try std.fmt.parseUnsigned(u8, tokens.next() orelse return error.IncompleteScheduledIrrigation, 10);
    if (value < 1 or value > 24) return error.InvalidIrrigationHour;
    return value;
}

test "parse scheduled irrigation with pipe delimiters" {
    const allocator = std.testing.allocator;
    var schedule = try parse(allocator, "irrigation", "01062024|24|7|12|0|7|1|2|3|4|5|6|7|8|9|10|11\n");
    defer schedule.deinit(allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 0.004), schedule.scheduled[0].hourlyAmountM(), 1.0e-12);
}

test "parse automated irrigation window" {
    const allocator = std.testing.allocator;
    var schedule = try parse(allocator, "auto_water", "01060000 30091800 0 .25 .8 1 .05 7 0 0 0 0 0 0 0 0 0 0 0");
    defer schedule.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 18), schedule.automated.end.hour);
}

test "scheduled irrigation accepts whole-line indented and trailing comments" {
    const allocator = std.testing.allocator;
    var schedule = try parse(
        allocator,
        "irrigation",
        \\# Date, water amount, hourly window, depth, and water chemistry.
        \\   # Mixed delimiters are accepted on each complete record.
        \\01062024|24|7|12|0|7|1|2|3|4|5|6|7|8|9|10|11 # first event
        \\# End of schedule.
        ,
    );
    defer schedule.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), schedule.scheduled.len);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.004),
        schedule.scheduled[0].hourlyAmountM(),
        1.0e-12,
    );
}

test "scheduled irrigation comments cannot hide short or long records" {
    try std.testing.expectError(
        error.IncompleteIrrigationRecord,
        parse(
            std.testing.allocator,
            "irrigation",
            "01062024 24 7 12 0 7 # missing water chemistry\n",
        ),
    );
    try std.testing.expectError(
        error.TrailingScheduledIrrigationData,
        parse(
            std.testing.allocator,
            "irrigation",
            "01062024 24 7 12 0 7 1 2 3 4 5 6 7 8 9 10 11 99 # extra\n",
        ),
    );
}

test "scheduled irrigation rejects empty explicit delimiter fields" {
    try std.testing.expectError(
        error.EmptyScheduledIrrigationRecordValue,
        parse(std.testing.allocator, "irrigation", "01062024,,7,12,0,7,1,2,3,4,5,6,7,8,9,10,11\n"),
    );
    try std.testing.expectError(
        error.EmptyScheduledIrrigationRecordValue,
        parse(std.testing.allocator, "irrigation", "01062024|24|7|12|0|7|1||3|4|5|6|7|8|9|10|11\n"),
    );
    try std.testing.expectError(
        error.EmptyScheduledIrrigationRecordValue,
        parse(std.testing.allocator, "irrigation", "01062024 24 7 12 0 7 1 2 3 4 5 6 7 8 9 10 11|\n"),
    );
}

test "irrigation window parser honors shared modulo-four month-day validation" {
    try std.testing.expectEqual(@as(u8, 29), (try DayMonthHour.parse("29020000")).day);
    try std.testing.expectError(
        error.InvalidIrrigationWindow,
        DayMonthHour.parse("30020000"),
    );
}

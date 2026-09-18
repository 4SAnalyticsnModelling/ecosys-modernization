const std = @import("std");
const delimited_input = @import("../input/delimited_input.zig");
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");

pub const MonthDay = struct { day: u8, month: u8 };

pub const Selection = struct {
    allocator: std.mem.Allocator,
    first_date: MonthDay,
    last_date: MonthDay,
    enabled_variables: []bool,

    pub fn deinit(self: *Selection) void {
        self.allocator.free(self.enabled_variables);
        self.* = undefined;
    }

    pub fn enabledCount(self: Selection) usize {
        var count: usize = 0;
        for (self.enabled_variables) |enabled| count += @intFromBool(enabled);
        return count;
    }

    /// Reproduces FOUTS/OUTS recurring month-day windows. ecosys uses the
    /// source MOD(year,4) leap rule, including century years.
    pub fn includesDate(self: Selection, day: u8, month: u8, year: i32) !bool {
        if (year <= 0 or year > std.math.maxInt(u16)) return false;
        const execution_year: u16 = @intCast(year);
        const current = execution_calendar_date.dayOfYear(.{ .day = day, .month = month, .year = execution_year }) catch return false;
        const first = execution_calendar_date.dayOfYear(.{ .day = self.first_date.day, .month = self.first_date.month, .year = execution_year }) catch return false;
        const last = execution_calendar_date.dayOfYear(.{ .day = self.last_date.day, .month = self.last_date.month, .year = execution_year }) catch return false;
        // Historical editors normally use first<=last. Supporting a wrapped
        // interval makes recurring winter windows explicit at runtime.
        return if (first <= last) current >= first and current <= last else current >= first or current <= last;
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Selection {
    var records = std.mem.splitScalar(u8, source, '\n');
    const first_date = try parseMonthDay(
        try singleRecordValue(&records, error.EmptyOutputSelection),
    );
    const last_date = try parseMonthDay(
        try singleRecordValue(&records, error.IncompleteOutputSelection),
    );
    var choices: std.ArrayList(bool) = .empty;
    defer choices.deinit(allocator);
    while (try nextRecordOrNull(&records)) |record| {
        var tokens = delimited_input.recordTokens(record);
        const token = tokens.next() orelse unreachable;
        const enabled = delimited_input.parseYesNo(token) catch return error.InvalidOutputChoice;
        if (tokens.next() != null) return error.TrailingOutputSelectionRecordData;
        try choices.append(allocator, enabled);
    }
    if (choices.items.len == 0) return error.NoOutputChoices;
    return .{ .allocator = allocator, .first_date = first_date, .last_date = last_date, .enabled_variables = try choices.toOwnedSlice(allocator) };
}

fn singleRecordValue(records: anytype, missing_error: anyerror) ![]const u8 {
    const record = try nextRecordOrNull(records) orelse return missing_error;
    var tokens = delimited_input.recordTokens(record);
    const value = tokens.next() orelse unreachable;
    if (tokens.next() != null) return error.TrailingOutputSelectionRecordData;
    return value;
}

fn nextRecordOrNull(records: anytype) !?[]const u8 {
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record))
            return error.EmptyOutputSelectionRecordValue;
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

fn parseMonthDay(text: []const u8) !MonthDay {
    if (text.len != 4) return error.InvalidOutputDate;
    for (text) |character| if (!std.ascii.isDigit(character)) return error.InvalidOutputDate;
    const day = try std.fmt.parseUnsigned(u8, text[0..2], 10);
    const month = try std.fmt.parseUnsigned(u8, text[2..4], 10);
    _ = execution_calendar_date.dayOfYear(.{ .day = day, .month = month, .year = 2000 }) catch return error.InvalidOutputDate;
    return .{ .day = day, .month = month };
}

pub const CatalogEntry = struct { name: []const u8, selection: Selection };
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(CatalogEntry) = .empty,
    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.name);
            entry.selection.deinit();
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
        var selection = try parse(self.allocator, source);
        errdefer selection.deinit();
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{ .name = owned_name, .selection = selection });
        return index;
    }
};

test "parse runtime-sized self-contained output selection" {
    const allocator = std.testing.allocator;
    const source = "0101\n3112\nYES\nno\nYes\nNO\n";
    var selection = try parse(allocator, source);
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 4), selection.enabled_variables.len);
    try std.testing.expectEqual(@as(u8, 1), selection.first_date.month);
    try std.testing.expectEqual(@as(u8, 31), selection.last_date.day);
    try std.testing.expect(selection.enabledCount() > 0);
}

test "output selection accepts mixed boolean casing" {
    var selection = try parse(std.testing.allocator, "0101\n3112\nYES\nno\nYes\n");
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 3), selection.enabled_variables.len);
}

test "output selection schedules inclusive recurring and wrapped date windows" {
    var summer = try parse(std.testing.allocator, "0106\n3108\nyes\n");
    defer summer.deinit();
    try std.testing.expect(try summer.includesDate(1, 6, 2001));
    try std.testing.expect(try summer.includesDate(31, 8, 2001));
    try std.testing.expect(!try summer.includesDate(1, 9, 2001));

    var winter = try parse(std.testing.allocator, "0111\n2802\nyes\n");
    defer winter.deinit();
    try std.testing.expect(try winter.includesDate(15, 1, 2001));
    try std.testing.expect(!try winter.includesDate(15, 6, 2001));
}

test "output selection uses source modulo-four leap chronology" {
    var leap_day = try parse(std.testing.allocator, "2902\n2902\nyes\n");
    defer leap_day.deinit();
    try std.testing.expect(try leap_day.includesDate(29, 2, 2000));
    try std.testing.expect(!try leap_day.includesDate(28, 2, 2001));
}

test "legacy month-day conversion preserves non-standard March/April boundary behavior" {
    var overlap = try parse(std.testing.allocator, "3003\n0104\nyes\n");
    defer overlap.deinit();
    try std.testing.expect(try overlap.includesDate(30, 3, 2001));
    try std.testing.expect(try overlap.includesDate(31, 3, 2001));
    try std.testing.expect(try overlap.includesDate(1, 4, 2001));
    try std.testing.expect(!try overlap.includesDate(2, 4, 2001));
}

test "output selection enforces one compulsory value per record" {
    try std.testing.expectError(
        error.TrailingOutputSelectionRecordData,
        parse(std.testing.allocator, "0101 3112\nyes\n"),
    );
    try std.testing.expectError(
        error.TrailingOutputSelectionRecordData,
        parse(std.testing.allocator, "0101\n3112\nyes no\n"),
    );
    inline for (.{
        "0101\n3112\nyes,\n",
        "0101\n3112\nyes| |\n",
        "0101\n3112\nyes\t\t\n",
    }) |source| try std.testing.expectError(
        error.EmptyOutputSelectionRecordValue,
        parse(std.testing.allocator, source),
    );
}

test "output selection records allow comments and casing" {
    var selection = try parse(
        std.testing.allocator,
        "# dates\n0101 # first\n3112 # last\nYeS\nno # disabled\n",
    );
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 2), selection.enabled_variables.len);
    try std.testing.expect(selection.enabled_variables[0]);
    try std.testing.expect(!selection.enabled_variables[1]);
}

const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");
const PackedDate = @import("plant_management.zig").PackedDate;

pub const Nitrogen_g_per_m2 = struct {
    broadcast_ammonium: f64,
    broadcast_ammonia: f64,
    broadcast_urea: f64,
    broadcast_nitrate: f64,
    banded_ammonium: f64,
    banded_ammonia: f64,
    banded_urea: f64,
    banded_nitrate: f64,
};
pub const Phosphorus_g_per_m2 = struct { broadcast_monocalcium_phosphate: f64, banded_monocalcium_phosphate: f64, broadcast_hydroxyapatite: f64 };
pub const Residue_g_per_m2 = struct { carbon: f64, nitrogen: f64, phosphorus: f64 };

pub const Event = struct {
    date: PackedDate,
    nitrogen_g_per_m2: Nitrogen_g_per_m2,
    phosphorus_g_per_m2: Phosphorus_g_per_m2,
    calcium_carbonate_g_ca_per_m2: f64,
    calcium_sulfate_g_ca_per_m2: f64,
    plant_residue_g_per_m2: Residue_g_per_m2,
    manure_g_per_m2: Residue_g_per_m2,
    application_depth_m: f64,
    band_row_width_m: f64,
    fertilizer_formulation: u8,
    plant_residue_type: u8,
    manure_type: u8,
};

pub const CatalogEntry = struct { name: []const u8, events: []Event };

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(CatalogEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.events);
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
        const events = try parse(self.allocator, source);
        errdefer self.allocator.free(events);
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{ .name = owned_name, .events = events });
        return index;
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ![]Event {
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(allocator);
    var records = std.mem.splitScalar(u8, source, '\n');
    while (try nextRecord(&records)) |record| {
        var values = delimited_input.recordTokens(record);
        const date_text = values.next() orelse unreachable;
        const date = try PackedDate.parse(date_text);
        const event: Event = .{
            .date = date,
            .nitrogen_g_per_m2 = .{
                .broadcast_ammonium = try amount(&values),
                .broadcast_ammonia = try amount(&values),
                .broadcast_urea = try amount(&values),
                .broadcast_nitrate = try amount(&values),
                .banded_ammonium = try amount(&values),
                .banded_ammonia = try amount(&values),
                .banded_urea = try amount(&values),
                .banded_nitrate = try amount(&values),
            },
            .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = try amount(&values), .banded_monocalcium_phosphate = try amount(&values), .broadcast_hydroxyapatite = try amount(&values) },
            .calcium_carbonate_g_ca_per_m2 = try amount(&values),
            .calcium_sulfate_g_ca_per_m2 = try amount(&values),
            .plant_residue_g_per_m2 = try residue(&values),
            .manure_g_per_m2 = try residue(&values),
            .application_depth_m = try amount(&values),
            .band_row_width_m = try amount(&values),
            // HOUR1 also uses formulation codes >= 10 to distinguish
            // crushed rock from gypsum. Preserve the full runtime byte.
            .fertilizer_formulation = try code(&values, std.math.maxInt(u8)),
            .plant_residue_type = try code(&values, 10),
            .manure_type = try code(&values, 3),
        };
        if (values.next() != null) return error.TrailingFertilizerEventData;
        try events.append(allocator, event);
    }
    return events.toOwnedSlice(allocator);
}

fn nextRecord(records: anytype) !?[]const u8 {
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record)) return error.EmptyFertilizerScheduleRecordValue;
        var values = delimited_input.recordTokens(record);
        if (values.next() != null) return record;
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

fn amount(values: anytype) !f64 {
    const value = try std.fmt.parseFloat(f64, values.next() orelse return error.IncompleteFertilizerEvent);
    if (!std.math.isFinite(value)) return error.NonfiniteFertilizerAmount;
    if (value < 0.0) return error.NegativeFertilizerAmount;
    return value;
}
fn residue(values: anytype) !Residue_g_per_m2 {
    return .{ .carbon = try amount(values), .nitrogen = try amount(values), .phosphorus = try amount(values) };
}
fn code(values: anytype, maximum: u8) !u8 {
    const value = try std.fmt.parseUnsigned(u8, values.next() orelse return error.IncompleteFertilizerEvent, 10);
    if (value > maximum) return error.InvalidFertilizerType;
    return value;
}

test "parse self-contained fertilizer schedule" {
    const allocator = std.testing.allocator;
    const source = @import("../core/test_fixtures.zig").fertilizer_schedule_source;
    const events = try parse(allocator, source);
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectApproxEqAbs(@as(f64, 13.8), events[0].nitrogen_g_per_m2.broadcast_urea, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 360.0), events[2].calcium_carbonate_g_ca_per_m2, 1.0e-12);
}

test "crushed-rock fertilizer formulation codes are preserved" {
    const source = "15041998 0 0 0 0 0 0 0 0 0 0 0 360 0 0 0 0 0 0 0 0 0 10 0 0\n";
    const events = try parse(std.testing.allocator, source);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(u8, 10), events[0].fertilizer_formulation);
    try std.testing.expectEqual(@as(f64, 360), events[0].calcium_carbonate_g_ca_per_m2);
}

test "fertilizer schedule accepts whole-line indented and trailing comments" {
    const source =
        "# Runtime fertilizer amounts use grams per square metre.\n" ++
        "   # The formulation code remains an unsigned runtime value.\n" ++
        "15041998,0,0,0,0,0,0,0,0,0,0,0,360,0,0,0,0,0,0,0,0,0,10,0,0" ++
        " # crushed rock\n" ++
        "# End of schedule.\n";
    const events = try parse(std.testing.allocator, source);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(
        @as(u8, 10),
        events[0].fertilizer_formulation,
    );
    try std.testing.expectEqual(
        @as(f64, 360),
        events[0].calcium_carbonate_g_ca_per_m2,
    );
}

test "fertilizer comments cannot hide missing or extra values" {
    try std.testing.expectError(
        error.IncompleteFertilizerEvent,
        parse(
            std.testing.allocator,
            "15041998 0 0 # remaining compulsory values are missing\n",
        ),
    );
    try std.testing.expectError(
        error.TrailingFertilizerEventData,
        parse(
            std.testing.allocator,
            "15041998 0 0 0 0 0 0 0 0 0 0 0 360 0 0 0 0 0 0 0 0 0 10 0 0 99 # extra\n",
        ),
    );
}

test "fertilizer schedule rejects empty explicit delimiter fields" {
    try std.testing.expectError(
        error.EmptyFertilizerScheduleRecordValue,
        parse(std.testing.allocator, "15041998,,0,0,0,0,0,0,0,0,0,0,360,0,0,0,0,0,0,0,0,0,10,0,0\n"),
    );
    try std.testing.expectError(
        error.EmptyFertilizerScheduleRecordValue,
        parse(std.testing.allocator, "15041998,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,0,\n"),
    );
    try std.testing.expectError(
        error.EmptyFertilizerScheduleRecordValue,
        parse(std.testing.allocator, ",0,0,0,0,0,0,0,0,0,0,0,360,0,0,0,0,0,0,0,0,0,10,0,0\n"),
    );
}

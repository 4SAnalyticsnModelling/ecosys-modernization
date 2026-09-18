const std = @import("std");
const delimited_input = @import("../io/input/delimited_input.zig");
const PackedDate = @import("plant_management.zig").PackedDate;

pub const DirectionalDrainage = struct {
    north_distance_m: f64,
    east_distance_m: f64,
    south_distance_m: f64,
    west_distance_m: f64,
    north_flow_enabled: bool,
    east_flow_enabled: bool,
    south_flow_enabled: bool,
    west_flow_enabled: bool,
};

pub const Operation = union(enum) {
    tillage: struct { depth_m: f64, mixing_fraction: f64, includes_crop: bool },
    surface_litter_removal: struct { fraction: f64 },
    fire: struct { energy_kw_per_m2: f64 },
    natural_drainage: struct { depth_m: f64 },
    artificial_drainage: struct { depth_m: f64, boundaries: DirectionalDrainage },
};

pub const Event = struct { date: PackedDate, operation: Operation };

/// REDIST caps operation 21 below complete removal so the retained surface
/// pools remain numerically defined for the subsequent litter calculations.
pub const maximum_surface_litter_removal_fraction: f64 = 0.999;

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
    var records = std.mem.splitScalar(u8, source, '\n');
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(allocator);
    while (try nextRecord(&records)) |record| {
        var tokens = delimited_input.recordTokens(record);
        const date = try PackedDate.parse(tokens.next() orelse return error.IncompleteDisturbanceEvent);
        const code = try std.fmt.parseUnsigned(u8, tokens.next() orelse return error.IncompleteDisturbanceEvent, 10);
        const magnitude = try nonnegative(&tokens);
        if (tokens.next() != null) return error.TrailingDisturbanceEventData;
        const operation: Operation = if (code <= 10)
            // day.f:347-348: ITILL.GE.0.AND.ITILL.LE.10 is inclusive of 0 (a legal,
            // minimal-mixing tillage code); CORP=AMIN1(1.0,AMAX1(0.05,ITILL/10.0))
            // floors the mixing fraction at 0.05 even when ITILL is 0.
            .{ .tillage = .{ .depth_m = magnitude, .mixing_fraction = @max(0.05, @as(f64, @floatFromInt(code)) / 10.0), .includes_crop = true } }
        else if (code >= 11 and code <= 20)
            // day.f:353-354: same AMAX1(0.05,...) floor for the "all species except
            // NZ=1" branch, keyed off ITILL-10.
            .{ .tillage = .{ .depth_m = magnitude, .mixing_fraction = @max(0.05, @as(f64, @floatFromInt(code - 10)) / 10.0), .includes_crop = false } }
        else switch (code) {
            21 => .{ .surface_litter_removal = .{
                .fraction = try effectiveSurfaceLitterRemovalFraction(magnitude),
            } },
            22 => .{ .fire = .{ .energy_kw_per_m2 = magnitude } },
            23 => .{ .natural_drainage = .{ .depth_m = magnitude } },
            24 => .{ .artificial_drainage = .{ .depth_m = magnitude, .boundaries = try parseDrainage(try nextDrainageRecord(&records) orelse return error.MissingArtificialDrainageBoundaries) } },
            else => return error.InvalidDisturbanceOperation,
        };
        try events.append(allocator, .{ .date = date, .operation = operation });
    }
    return events.toOwnedSlice(allocator);
}

pub fn effectiveSurfaceLitterRemovalFraction(
    requested_fraction: f64,
) !f64 {
    if (!std.math.isFinite(requested_fraction))
        return error.NonfiniteDisturbanceValue;
    if (requested_fraction < 0 or requested_fraction > 1)
        return error.InvalidRemovalFraction;
    return @min(
        maximum_surface_litter_removal_fraction,
        requested_fraction,
    );
}

fn parseDrainage(record: []const u8) !DirectionalDrainage {
    if (hasEmptyExplicitField(record)) return error.EmptyArtificialDrainageRecordValue;
    var tokens = delimited_input.recordTokens(record);
    const result: DirectionalDrainage = .{
        .north_distance_m = try nonnegative(&tokens),
        .east_distance_m = try nonnegative(&tokens),
        .south_distance_m = try nonnegative(&tokens),
        .west_distance_m = try nonnegative(&tokens),
        .north_flow_enabled = try flag(&tokens),
        .east_flow_enabled = try flag(&tokens),
        .south_flow_enabled = try flag(&tokens),
        .west_flow_enabled = try flag(&tokens),
    };
    if (tokens.next() != null) return error.TrailingArtificialDrainageData;
    return result;
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

fn nonnegative(tokens: anytype) !f64 {
    const value = try std.fmt.parseFloat(f64, tokens.next() orelse return error.IncompleteDisturbanceEvent);
    if (!std.math.isFinite(value)) return error.NonfiniteDisturbanceValue;
    if (value < 0.0) return error.NegativeDisturbanceValue;
    return value;
}
fn flag(tokens: anytype) !bool {
    return switch (try std.fmt.parseUnsigned(u8, tokens.next() orelse return error.IncompleteArtificialDrainageBoundaries, 10)) {
        0 => false,
        1 => true,
        else => error.InvalidDrainageBoundaryFlag,
    };
}
fn nextRecord(records: anytype) !?[]const u8 {
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record)) return error.EmptyDisturbanceRecordValue;
        var tokens = delimited_input.recordTokens(record);
        if (tokens.next() != null) return record;
    }
    return null;
}

fn nextDrainageRecord(records: anytype) !?[]const u8 {
    while (records.next()) |record| {
        if (hasEmptyExplicitField(record))
            return error.EmptyArtificialDrainageRecordValue;
        var tokens = delimited_input.recordTokens(record);
        if (tokens.next() != null) return record;
    }
    return null;
}

test "parse self-contained disturbance schedule" {
    const allocator = std.testing.allocator;
    const source = @import("../core/test_fixtures.zig").disturbance_schedule_source;
    const events = try parse(allocator, source);
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), events[0].operation.tillage.mixing_fraction, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), events[2].operation.tillage.mixing_fraction, 1.0e-12);
}

test "parse artificial drainage continuation record" {
    const allocator = std.testing.allocator;
    const events = try parse(allocator, "01012000|24|1.5\n10 20 30 40 1 0 1 0\n");
    defer allocator.free(events);
    try std.testing.expect(events[0].operation.artificial_drainage.boundaries.north_flow_enabled);
    try std.testing.expect(!events[0].operation.artificial_drainage.boundaries.east_flow_enabled);
}

test "disturbance schedule rejects explicit empty fields in event records" {
    try std.testing.expectError(
        error.EmptyDisturbanceRecordValue,
        parse(std.testing.allocator, "01012000|24|1.5,\n"),
    );
}

test "surface litter removal retains exact REDIST minimum inventory" {
    const allocator = std.testing.allocator;
    const events = try parse(
        allocator,
        "01012000,21,1.0 # complete requested removal is capped\n",
    );
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectApproxEqAbs(
        maximum_surface_litter_removal_fraction,
        events[0].operation.surface_litter_removal.fraction,
        0,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.25),
        try effectiveSurfaceLitterRemovalFraction(0.25),
        0,
    );
    try std.testing.expectError(
        error.InvalidRemovalFraction,
        effectiveSurfaceLitterRemovalFraction(1.000001),
    );
}

test "disturbance comments do not become events or drainage continuations" {
    const allocator = std.testing.allocator;
    const events = try parse(
        allocator,
        \\# Tillage uses comma-separated input.
        \\01012000,10,0.25 # full crop mixing
        \\   # Artificial drainage follows.
        \\02012000|24|1.5
        \\# Its boundary record remains a separate compulsory physical line.
        \\10 20 30 40 1 0 1 0 # north and south are open
        \\# End of schedule.
        ,
    );
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.25),
        events[0].operation.tillage.depth_m,
        0,
    );
    const drainage = events[1].operation.artificial_drainage.boundaries;
    try std.testing.expect(drainage.north_flow_enabled);
    try std.testing.expect(!drainage.east_flow_enabled);
    try std.testing.expect(drainage.south_flow_enabled);
    try std.testing.expect(!drainage.west_flow_enabled);
}

test "disturbance comments cannot hide short or long physical records" {
    try std.testing.expectError(
        error.IncompleteDisturbanceEvent,
        parse(
            std.testing.allocator,
            "01012000 10 # missing tillage depth\n",
        ),
    );
    try std.testing.expectError(
        error.TrailingArtificialDrainageData,
        parse(
            std.testing.allocator,
            "01012000 24 1\n1 2 3 4 1 0 1 0 99 # extra boundary value\n",
        ),
    );
}

test "disturbance schedule rejects empty explicit delimiter fields" {
    try std.testing.expectError(
        error.EmptyDisturbanceRecordValue,
        parse(std.testing.allocator, "01012000,,1\n"),
    );
    try std.testing.expectError(
        error.EmptyArtificialDrainageRecordValue,
        parse(
            std.testing.allocator,
            "01012000,24,1.5\n10 20 30| \n",
        ),
    );
    try std.testing.expectError(
        error.EmptyArtificialDrainageRecordValue,
        parse(
            std.testing.allocator,
            "01012000|24|1.5\n,1,1,1,1,0,0,0\n",
        ),
    );
}

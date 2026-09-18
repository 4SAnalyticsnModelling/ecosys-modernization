const std = @import("std");
const PlantTraits = @import("plant_traits.zig").PlantTraits;

pub const Entry = struct {
    name: []const u8,
    traits: PlantTraits,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |entry| self.allocator.free(entry.name);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn find(self: Catalog, name: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| if (std.mem.eql(u8, entry.name, name)) return index;
        return null;
    }

    pub fn appendFromSource(self: *Catalog, name: []const u8, source: []const u8) !usize {
        try validateInputName(name);
        if (self.find(name)) |index| return index;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const traits = try @import("plant_traits.zig").parse(source);
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{ .name = owned_name, .traits = traits });
        return index;
    }
};

fn validateInputName(name: []const u8) !void {
    if (name.len == 0 or
        std.mem.trim(u8, name, " \t\r\n").len != name.len or
        std.mem.indexOfAny(u8, name, " \t\r\n,|#") != null)
        return error.InvalidPlantInputName;
}

const test_plant_traits_source =
    \\4 2 0 0 0 0 2 0 0 2 2.0
    \\75 15 150 30 810 3 0.040 0.040 405 0.040 0.040 0.45
    \\0.20 0.075 0.20 0.075
    \\0.025 0.015 0 0 0 12.5 0.10
    \\16 5 -1 0.25
    \\0.020 0.300 0.300
    \\0 0 0.50 0.50 0.95 90 90
    \\1.2 6 0.20 0.20 0.50E-03 0
    \\3.75E-04 1.0E-04 0.20 0.10 1.0E+04 1.0E+09 5.0E-02 250 250
    \\1.4E-02 0.40 0.0125
    \\1.4E-02 0.35 0.030
    \\0.3E-02 0.18 0.009
    \\-1.5 -5 2.5E+03
    \\0.72 0.76 0.80 0.88 0.76 0.76 0.88 0.76 0.50
    \\0.10 0.02 0.0075 0.03 0.0125 0.0125 0.04 0.02 0.10
    \\0.010 0.002 0.00075 0.003 0.00125 0.00125 0.004 0.002 0.010
;

test "plant catalog caches parsed species" {
    const allocator = std.testing.allocator;
    var catalog = Catalog.init(allocator);
    defer catalog.deinit();
    const first = try catalog.appendFromSource("maiz33", test_plant_traits_source);
    const second = try catalog.appendFromSource("maiz33", test_plant_traits_source);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.items.len);
}

test "plant catalog rejects malformed compulsory input names" {
    inline for (.{
        "",
        " ",
        " maize",
        "maize ",
        "maize,corn",
        "maize|corn",
        "maize\tcorn",
        "maize#corn",
    }) |name| {
        var catalog = Catalog.init(std.testing.allocator);
        defer catalog.deinit();
        try std.testing.expectError(
            error.InvalidPlantInputName,
            catalog.appendFromSource(name, test_plant_traits_source),
        );
        try std.testing.expectEqual(@as(usize, 0), catalog.entries.items.len);
    }
}

test "plant catalog accepts extensionless and conventional file names" {
    inline for (.{ "maize", "maize-traits.txt", "maize.traits.csv" }) |name| {
        var catalog = Catalog.init(std.testing.allocator);
        defer catalog.deinit();
        _ = try catalog.appendFromSource(name, test_plant_traits_source);
        try std.testing.expectEqualStrings(name, catalog.entries.items[0].name);
    }
}

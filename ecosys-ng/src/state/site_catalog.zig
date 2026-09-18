const std = @import("std");
const site_module = @import("site.zig");

pub const Entry = struct {
    name: []const u8,
    site: site_module.Site,
};

/// Owns each distinct site file once. Grid cells refer to entries by runtime
/// index, so repeating a filename does not repeat parsing or allocation.
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |*entry| {
            entry.site.deinit();
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn find(self: Catalog, name: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.name, name)) return index;
        }
        return null;
    }

    pub fn appendFromSource(
        self: *Catalog,
        name: []const u8,
        source: []const u8,
        global_column_count: usize,
        global_row_count: usize,
    ) !usize {
        try validateInputName(name);
        if (self.find(name)) |index| return index;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        var parsed_site = try site_module.parse(
            self.allocator,
            source,
            global_column_count,
            global_row_count,
        );
        errdefer parsed_site.deinit();
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{
            .name = owned_name,
            .site = parsed_site,
        });
        return index;
    }
};

fn validateInputName(name: []const u8) !void {
    if (name.len == 0 or
        std.mem.trim(u8, name, " \t\r\n").len != name.len or
        std.mem.indexOfAny(u8, name, " \t\r\n,|#") != null)
        return error.InvalidSiteInputName;
}

const test_site_source = @import("../core/test_fixtures.zig").site_source;

test "site catalog caches repeated filenames while retaining distinct files" {
    var catalog = Catalog.init(std.testing.allocator);
    defer catalog.deinit();

    const first = try catalog.appendFromSource("shared_site", test_site_source, 1, 1);
    const repeated = try catalog.appendFromSource("shared_site", "not parsed", 1, 1);
    const distinct = try catalog.appendFromSource("other_site", test_site_source, 1, 1);

    try std.testing.expectEqual(first, repeated);
    try std.testing.expect(first != distinct);
    try std.testing.expectEqual(@as(usize, 2), catalog.entries.items.len);
}

test "site catalog rejects malformed compulsory input names" {
    inline for (.{
        "",
        " ",
        " site_a",
        "site_a ",
        "site,a",
        "site|a",
        "site\ta",
        "site#a",
    }) |name| {
        var catalog = Catalog.init(std.testing.allocator);
        defer catalog.deinit();
        try std.testing.expectError(
            error.InvalidSiteInputName,
            catalog.appendFromSource(name, test_site_source, 1, 1),
        );
        try std.testing.expectEqual(@as(usize, 0), catalog.entries.items.len);
    }
}

test "site catalog accepts extensionless and conventional file names" {
    inline for (.{ "site_a", "site-a.txt", "site.a.csv" }) |name| {
        var catalog = Catalog.init(std.testing.allocator);
        defer catalog.deinit();
        _ = try catalog.appendFromSource(name, test_site_source, 1, 1);
        try std.testing.expectEqualStrings(name, catalog.entries.items[0].name);
    }
}

const std = @import("std");
const soil_profile = @import("../../state/soil_profile.zig");
const SoilProfile = soil_profile.SoilProfile;
const SoilMaterial = @import("initialization.zig").SoilMaterial;
const SoilHydrology = @import("../water/hydrology.zig").SoilHydrology;
const retention = @import("../water/retention.zig");
const profile_derivation = @import("derivation.zig");

pub const Entry = struct {
    name: []const u8,
    profile: SoilProfile,
    material: SoilMaterial,
    hydrology_per_m2: SoilHydrology,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |*entry| {
            entry.hydrology_per_m2.deinit();
            entry.material.deinit();
            entry.profile.deinit();
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

    pub fn appendFromSource(self: *Catalog, name: []const u8, source: []const u8, retention_parameters: retention.Parameters, derivation_parameters: profile_derivation.Parameters) !usize {
        try validateInputName(name);
        if (self.find(name)) |index| return index;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        var profile = try @import("../../state/soil_profile.zig").parsePhysicalProfile(self.allocator, source);
        errdefer profile.deinit();
        var material = try SoilMaterial.init(self.allocator, profile, derivation_parameters);
        errdefer material.deinit();
        var hydrology = try SoilHydrology.init(self.allocator, profile, material, 1.0, retention_parameters);
        errdefer hydrology.deinit();
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{
            .name = owned_name,
            .profile = profile,
            .material = material,
            .hydrology_per_m2 = hydrology,
        });
        return index;
    }

    pub fn maximumLayerCount(self: Catalog) !usize {
        if (self.entries.items.len == 0) return error.EmptySoilCatalog;
        var maximum: usize = 0;
        for (self.entries.items) |entry| maximum = @max(maximum, entry.profile.total_layer_count);
        return maximum;
    }
};

fn validateInputName(name: []const u8) !void {
    if (name.len == 0 or
        std.mem.trim(u8, name, " \t\r\n").len != name.len or
        std.mem.indexOfAny(u8, name, " \t\r\n,|#") != null)
        return error.InvalidSoilInputName;
}

fn testSoilProfileSource(
    allocator: std.mem.Allocator,
    layer_property_count: usize,
) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "-0.01,-1.5,0.2,6,11,1.1,0.11,22,2.2,0.22,33,3.3,0.33,8,2,1,1,0,0,0\n");
    const physical_records = [_][]const u8{
        "0.1\n",                                        "1.3\n",
        "van_genuchten_inflection_pressure_head_m 0\n", "0.30\n",
        "0.10\n",                                       "10\n",
        "5\n",                                          "400\n",
        "400\n",                                        "0.05\n",
        "0\n",                                          "6.5\n",
        "10\n",                                         "1\n",
    };
    for (physical_records) |record|
        try source.appendSlice(allocator, record);
    for (0..layer_property_count) |property_index|
        try source.appendSlice(allocator, switch (property_index) {
            0 => "14.85\n",
            29 => "1\n",
            30 => "-1\n",
            else => "0\n",
        });
    return source.toOwnedSlice(allocator);
}

test "catalog caches repeated profile names" {
    const allocator = std.testing.allocator;
    const source = try testSoilProfileSource(
        allocator,
        @typeInfo(soil_profile.LayerProperty).@"enum".fields.len,
    );
    defer allocator.free(source);
    var catalog = Catalog.init(allocator);
    defer catalog.deinit();
    const parameters = retention.compatibilityParameters();
    const derivation = profile_derivation.compatibilityParameters();
    const first = try catalog.appendFromSource("f25sol98", source, parameters, derivation);
    const second = try catalog.appendFromSource("f25sol98", source, parameters, derivation);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), try catalog.maximumLayerCount());
    const third = try catalog.appendFromSource("second_profile", source, parameters, derivation);
    try std.testing.expect(third != first);
    try std.testing.expectEqual(@as(usize, 2), catalog.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), try catalog.maximumLayerCount());
}

test "soil catalog rejects malformed compulsory input names" {
    inline for (.{
        "",
        " ",
        " soil_a",
        "soil_a ",
        "soil,a",
        "soil|a",
        "soil\ta",
        "soil#a",
    }) |name| {
        var catalog = Catalog.init(std.testing.allocator);
        defer catalog.deinit();
        try std.testing.expectError(
            error.InvalidSoilInputName,
            catalog.appendFromSource(
                name,
                "",
                retention.compatibilityParameters(),
                profile_derivation.compatibilityParameters(),
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), catalog.entries.items.len);
    }
}

test "soil catalog accepts extensionless and conventional file names" {
    const source = try testSoilProfileSource(
        std.testing.allocator,
        @typeInfo(soil_profile.LayerProperty).@"enum".fields.len,
    );
    defer std.testing.allocator.free(source);
    inline for (.{ "soil_a", "soil-a.txt", "soil.a.csv" }) |name| {
        var catalog = Catalog.init(std.testing.allocator);
        defer catalog.deinit();
        _ = try catalog.appendFromSource(
            name,
            source,
            retention.compatibilityParameters(),
            profile_derivation.compatibilityParameters(),
        );
        try std.testing.expectEqualStrings(name, catalog.entries.items[0].name);
    }
}

//! Solve-local exact memoization for Richards face kernels.

const std = @import("std");

pub const Domain = enum(u1) {
    matrix,
    macropore,
};

const associativity: usize = 8;

const Entry = struct {
    source_water_bits: u64 = 0,
    destination_water_bits: u64 = 0,
    requested_flux_m3: f64 = 0,
    valid: bool = false,
};

const Set = struct {
    entries: [associativity]Entry = [_]Entry{.{}} ** associativity,
    next_slot: u8 = 0,
};

pub const Cache = struct {
    sets: []Set,
    hits: u32 = 0,
    misses: u32 = 0,
    assembled_target_limit_observed: bool = false,

    pub fn init(allocator: std.mem.Allocator, face_count: usize) !Cache {
        const set_count = try std.math.mul(usize, face_count, 2);
        const sets = try allocator.alloc(Set, set_count);
        @memset(sets, .{});
        return .{ .sets = sets };
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        allocator.free(self.sets);
        self.* = undefined;
    }

    pub fn beginResidual(self: *Cache) void {
        self.assembled_target_limit_observed = false;
    }

    pub fn observeAssembledTargetLimit(
        self: *Cache,
        requested_flux_m3: f64,
        accepted_flux_m3: f64,
    ) void {
        self.assembled_target_limit_observed = self.assembled_target_limit_observed or
            @as(u64, @bitCast(requested_flux_m3)) != @as(u64, @bitCast(accepted_flux_m3));
    }

    pub fn get(
        self: *Cache,
        face_index: usize,
        domain: Domain,
        source_water_m3: f64,
        destination_water_m3: f64,
    ) ?f64 {
        const set = &self.sets[setIndex(face_index, domain)];
        const source_bits: u64 = @bitCast(source_water_m3);
        const destination_bits: u64 = @bitCast(destination_water_m3);
        for (set.entries) |entry| {
            if (entry.valid and
                entry.source_water_bits == source_bits and
                entry.destination_water_bits == destination_bits)
            {
                self.hits +|= 1;
                return entry.requested_flux_m3;
            }
        }
        self.misses +|= 1;
        return null;
    }

    pub fn put(
        self: *Cache,
        face_index: usize,
        domain: Domain,
        source_water_m3: f64,
        destination_water_m3: f64,
        requested_flux_m3: f64,
    ) void {
        const set = &self.sets[setIndex(face_index, domain)];
        const slot: usize = @intCast(set.next_slot);
        set.entries[slot] = .{
            .source_water_bits = @bitCast(source_water_m3),
            .destination_water_bits = @bitCast(destination_water_m3),
            .requested_flux_m3 = requested_flux_m3,
            .valid = true,
        };
        set.next_slot = @intCast((slot + 1) % associativity);
    }

    fn setIndex(face_index: usize, domain: Domain) usize {
        return 2 * face_index + @intFromEnum(domain);
    }
};

test "face cache distinguishes domains and exact endpoint states" {
    var cache = try Cache.init(std.testing.allocator, 1);
    defer cache.deinit(std.testing.allocator);

    try std.testing.expect(cache.get(0, .matrix, 0.2, 0.3) == null);
    cache.put(0, .matrix, 0.2, 0.3, 0.01);
    cache.put(0, .macropore, 0.2, 0.3, 0.02);

    try std.testing.expectEqual(@as(f64, 0.01), cache.get(0, .matrix, 0.2, 0.3).?);
    try std.testing.expectEqual(@as(f64, 0.02), cache.get(0, .macropore, 0.2, 0.3).?);
    try std.testing.expect(cache.get(0, .matrix, 0.2, 0.30000000000000004) == null);
}

test "face cache scopes assembled-target limiting to one residual" {
    var cache = try Cache.init(std.testing.allocator, 0);
    defer cache.deinit(std.testing.allocator);

    cache.beginResidual();
    cache.observeAssembledTargetLimit(0.1, 0.1);
    try std.testing.expect(!cache.assembled_target_limit_observed);
    cache.observeAssembledTargetLimit(0.1, 0.09);
    try std.testing.expect(cache.assembled_target_limit_observed);
    cache.beginResidual();
    try std.testing.expect(!cache.assembled_target_limit_observed);
}

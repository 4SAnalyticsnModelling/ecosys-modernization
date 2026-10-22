const std = @import("std");

// Mirrors ecosys-ng/src/io/checkpoint/manifest.zig outputIdentityFingerprint exactly:
// seed 0x4f5554524f4f5433, update(run_identity little-endian u64), update(canonical_root).
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    if (args.len != 3) {
        std.debug.print("usage: fingerprint <run_identity_decimal> <canonical_root>\n", .{});
        std.process.exit(2);
    }
    const rid = try std.fmt.parseInt(u64, args[1], 10);
    var run_bytes: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &run_bytes, rid, .little);
    var hasher = std.hash.Wyhash.init(0x4f5554524f4f5433);
    hasher.update(&run_bytes);
    hasher.update(args[2]);
    std.debug.print("{d}\n", .{hasher.final()});
}

const std = @import("std");
const manifest_module = @import("manifest.zig");

const checksum_seed: u64 = 0x45434f5359534e47;

/// Streams one authoritative state owner to an atomic generation file, syncs
/// it, publishes it, then re-reads it in bounded chunks to produce the exact
/// descriptor later state_updateted by the bundle manifest.
pub fn publishSectionAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    section: manifest_module.Section,
    file_name: []const u8,
    write_buffer_bytes: usize,
    verify_buffer_bytes: usize,
    context: anytype,
    comptime writeFunction: anytype,
) !manifest_module.EntryDescriptor {
    if (write_buffer_bytes == 0 or verify_buffer_bytes == 0) return error.InvalidCheckpointSectionBufferSize;
    if (!safeFileName(file_name)) return error.InvalidCheckpointFileName;
    const write_buffer = try allocator.alloc(u8, write_buffer_bytes);
    defer allocator.free(write_buffer);
    var atomic_file = try directory.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic_file.deinit(io);
    var writer = atomic_file.file.writerStreaming(io, write_buffer);
    try writeFunction(&writer.interface, context);
    try writer.interface.flush();
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);

    const digest = try digestFile(allocator, io, directory, file_name, verify_buffer_bytes);
    return .{ .section = section, .file_name = file_name, .byte_length = digest.byte_length, .checksum = digest.checksum };
}

pub const Digest = struct { byte_length: u64, checksum: u64 };

pub fn digestFile(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, file_name: []const u8, buffer_bytes: usize) !Digest {
    if (buffer_bytes == 0) return error.InvalidCheckpointSectionBufferSize;
    if (!safeFileName(file_name)) return error.InvalidCheckpointFileName;
    var file = try directory.openFile(io, file_name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buffer = try allocator.alloc(u8, buffer_bytes);
    defer allocator.free(buffer);
    var hasher = std.hash.Wyhash.init(checksum_seed);
    var offset: u64 = 0;
    while (offset < stat.size) {
        const remaining = stat.size - offset;
        const requested: usize = @intCast(@min(remaining, buffer.len));
        const received = try file.readPositionalAll(io, buffer[0..requested], offset);
        if (received == 0) return error.CheckpointSectionTruncatedDuringVerification;
        hasher.update(buffer[0..received]);
        offset += received;
    }
    return .{ .byte_length = stat.size, .checksum = hasher.final() };
}

fn safeFileName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
        return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (name[0] == ' ' or name[name.len - 1] == ' ' or name[name.len - 1] == '.')
        return false;
    for (name) |byte| {
        if (byte == 0 or byte < 0x20 or
            std.mem.indexOfScalar(u8, "/\\<>:\"|?*", byte) != null)
            return false;
    }
    return true;
}

pub fn verifySectionFile(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, manifest: manifest_module.Manifest, section: manifest_module.Section, buffer_bytes: usize) !void {
    const expected = manifest.entry(section) orelse return error.MissingCheckpointSection;
    const actual = try digestFile(allocator, io, directory, expected.file_name, buffer_bytes);
    if (actual.byte_length != expected.byte_length) return error.CheckpointSectionLengthMismatch;
    if (actual.checksum != expected.checksum) return error.CheckpointSectionChecksumMismatch;
}

fn writeTestSection(writer: anytype, bytes: []const u8) !void {
    try writer.writeAll(bytes);
}

test "section state_update is streamed atomic and digest matches manifest verification" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const content = "runtime-sized checkpoint section";
    const descriptor = try publishSectionAtomic(std.testing.allocator, std.testing.io, temporary.dir, .plant_roots, "roots.7.bin", 7, 5, content, writeTestSection);
    try std.testing.expectEqual(@as(u64, content.len), descriptor.byte_length);
    try std.testing.expectEqual(manifest_module.checksum(content), descriptor.checksum);
    const stored = try temporary.dir.readFileAlloc(std.testing.io, descriptor.file_name, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualStrings(content, stored);
}

test "section state_update replaces prior generation file atomically" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    _ = try publishSectionAtomic(std.testing.allocator, std.testing.io, temporary.dir, .plant_canopy, "canopy.bin", 8, 8, "old", writeTestSection);
    const descriptor = try publishSectionAtomic(std.testing.allocator, std.testing.io, temporary.dir, .plant_canopy, "canopy.bin", 8, 8, "new generation", writeTestSection);
    try std.testing.expectEqual(manifest_module.checksum("new generation"), descriptor.checksum);
}

test "file verification detects a replaced section before parsing" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var sources: [manifest_module.section_count]manifest_module.EntrySource = undefined;
    inline for (@typeInfo(manifest_module.Section).@"enum".fields, 0..) |field, index| sources[index] = .{ .section = @enumFromInt(field.value), .file_name = field.name ++ ".bin", .bytes = field.name };
    var manifest = try manifest_module.build(std.testing.allocator, 1, .{ .year = 2001, .day_of_year = 1, .hour = 23 }, .{ .canonical_root = if (@import("builtin").os.tag == .windows) "C:\\ecosys-output" else "/ecosys-output", .run_identity = 1 }, .{ .columns = 1, .rows = 1, .soil_layers = 1, .snow_layers = 1, .plant_species_per_cell = 1, .root_axes_per_plant = 1 }, &sources);
    defer manifest.deinit();
    var file = try temporary.dir.createFile(std.testing.io, manifest.entry(.plant_roots).?.file_name, .{});
    try file.writeStreamingAll(std.testing.io, "plant_rootx");
    file.close(std.testing.io);
    try std.testing.expectError(error.CheckpointSectionChecksumMismatch, verifySectionFile(std.testing.allocator, std.testing.io, temporary.dir, manifest, .plant_roots, 4));
}

test "section I/O rejects unsafe names before touching the directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    inline for (.{
        "",
        "../roots.bin",
        "subdir/roots.bin",
        "subdir\\roots.bin",
        " roots.bin",
        "roots.bin ",
        "roots.",
        "roots:1.bin",
        "roots|1.bin",
        "roots?1.bin",
    }) |name| {
        try std.testing.expectError(
            error.InvalidCheckpointFileName,
            publishSectionAtomic(
                std.testing.allocator,
                std.testing.io,
                temporary.dir,
                .plant_roots,
                name,
                8,
                8,
                "must not be written",
                writeTestSection,
            ),
        );
        try std.testing.expectError(
            error.InvalidCheckpointFileName,
            digestFile(
                std.testing.allocator,
                std.testing.io,
                temporary.dir,
                name,
                8,
            ),
        );
    }
}

test "section I/O accepts portable extensionless and binary names" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    inline for (.{ "roots", "roots-1.bin", "roots.1.bin" }) |name| {
        const descriptor = try publishSectionAtomic(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            .plant_roots,
            name,
            8,
            8,
            "roots",
            writeTestSection,
        );
        try std.testing.expectEqualStrings(name, descriptor.file_name);
    }
}

const std = @import("std");
const spatial_grid = @import("spatial_grid.zig");

const file_magic = "ECOLAT01";
const manifest_magic = "ECOLATM1";
const format_version: u32 = 2;
const morton_order_tag: u8 = 1;
const manifest_name = "lateral-contributions.morton.manifest";
// Cloud sync tools (e.g. OneDrive) can hold file locks on newly written files
// during upload. 200 attempts × 50 ms = 10 s total budget covers typical
// upload latency for small tile manifest files (~69 bytes).
const atomic_replace_max_attempts: u8 = 200;
const atomic_replace_retry_delay_ms: i64 = 50;

pub const Contribution = struct {
    target_cell: usize,
    component: usize,
    delta: f64,
};

// Sorting an array of Contributions with the stable block sorter generated a
// disproportionately large specialization. The original position is part of
// this key so the smaller unstable pdq sorter still has a strict total order:
// records equivalent under the old Morton/component comparison retain their
// input order exactly.
const ContributionSortKey = struct {
    morton_index: u64,
    component: usize,
    original_index: usize,
};

/// Durable first-pass output for conservative lateral exchange. One file is
/// written per source tile. Records are sorted by target-cell Morton index and
/// component, so the second serial pass can gather contributions for its
/// owned cells without retaining a landscape-sized delta array.
pub const FileStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    buffer_byte_count: usize,
    source_generation_index: u64,
    destination_generation_index: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        buffer_byte_count: usize,
        source_generation_index: u64,
        destination_generation_index: u64,
    ) !FileStore {
        if (buffer_byte_count == 0)
            return error.InvalidLateralContributionIoBufferSize;
        if (source_generation_index == destination_generation_index)
            return error.LateralContributionGenerationMustBeDoubleBuffered;
        if (destination_generation_index != std.math.add(
            u64,
            source_generation_index,
            1,
        ) catch return error.TileGenerationIndexOverflow)
            return error.LateralContributionGenerationIsNotConsecutive;
        return .{
            .allocator = allocator,
            .io = io,
            .directory = directory,
            .buffer_byte_count = buffer_byte_count,
            .source_generation_index = source_generation_index,
            .destination_generation_index = destination_generation_index,
        };
    }

    pub fn saveSourceTile(
        self: FileStore,
        plan: spatial_grid.TilePlan,
        source_tile_index: usize,
        component_count: usize,
        contributions: []const Contribution,
    ) !void {
        if (source_tile_index >= plan.tiles.len)
            return error.TileIndexOutOfRange;
        if (component_count == 0)
            return error.InvalidLateralContributionComponentCount;
        const source_tile = plan.tiles[source_tile_index];
        // This allocation is the same size and alignment as the former owned
        // Contribution copy, preserving allocation/error behavior and peak
        // temporary storage while moving delta payloads out of the sorter.
        const sort_keys = try self.allocator.alloc(
            ContributionSortKey,
            contributions.len,
        );
        defer self.allocator.free(sort_keys);
        for (contributions, 0..) |contribution, original_index| {
            try validateContribution(
                plan,
                source_tile_index,
                component_count,
                contribution,
            );
            sort_keys[original_index] = contributionSortKey(
                contribution,
                original_index,
                plan.lon_count,
            );
        }
        std.sort.pdq(
            ContributionSortKey,
            sort_keys,
            {},
            contributionSortKeyLessThan,
        );
        const file_name = try sourceFileName(
            self.allocator,
            source_tile.z_order_index,
        );
        defer self.allocator.free(file_name);
        const buffer = try self.allocator.alloc(u8, self.buffer_byte_count);
        defer self.allocator.free(buffer);
        var atomic_file = try self.directory.createFileAtomic(
            self.io,
            file_name,
            .{ .replace = true },
        );
        defer atomic_file.deinit(self.io);
        var writer = atomic_file.file.writerStreaming(self.io, buffer);
        try writer.interface.writeAll(file_magic);
        try writer.interface.writeInt(u32, format_version, .little);
        try writer.interface.writeInt(
            u64,
            self.source_generation_index,
            .little,
        );
        try writer.interface.writeInt(
            u64,
            self.destination_generation_index,
            .little,
        );
        try writer.interface.writeByte(morton_order_tag);
        try writer.interface.writeInt(u64, plan.lat_count, .little);
        try writer.interface.writeInt(u64, plan.lon_count, .little);
        try writer.interface.writeInt(
            u64,
            source_tile.z_order_index,
            .little,
        );
        try writer.interface.writeInt(u64, component_count, .little);
        try writer.interface.writeInt(u64, sort_keys.len, .little);
        for (sort_keys) |sort_key| {
            const contribution = contributions[sort_key.original_index];
            try writer.interface.writeInt(
                u64,
                contribution.target_cell,
                .little,
            );
            try writer.interface.writeInt(
                u64,
                contribution.component,
                .little,
            );
            try writer.interface.writeInt(
                u64,
                @bitCast(contribution.delta),
                .little,
            );
        }
        try writer.interface.flush();
        try atomic_file.file.sync(self.io);
        var replace_attempt: u8 = 1;
        while (true) {
            atomic_file.replace(self.io) catch |err| {
                if (!retryAtomicReplace(err, replace_attempt)) return err;
                try std.Io.sleep(
                    self.io,
                    .fromMilliseconds(atomic_replace_retry_delay_ms),
                    .awake,
                );
                replace_attempt += 1;
                continue;
            };
            break;
        }
    }

    pub fn publish(self: FileStore, plan: spatial_grid.TilePlan) !void {
        const buffer = try self.allocator.alloc(u8, self.buffer_byte_count);
        defer self.allocator.free(buffer);
        var generation_component_count: ?usize = null;
        for (plan.tiles) |tile| {
            const file_name = try sourceFileName(
                self.allocator,
                tile.z_order_index,
            );
            defer self.allocator.free(file_name);
            var file = try self.directory.openFile(self.io, file_name, .{});
            defer file.close(self.io);
            var reader = file.readerStreaming(self.io, buffer);
            const component_count = try validateSourceFile(
                &reader.interface,
                self,
                plan,
                tile,
            );
            if (generation_component_count) |expected| {
                if (component_count != expected)
                    return error.LateralContributionComponentCountMismatch;
            } else {
                generation_component_count = component_count;
            }
        }
        const component_count = generation_component_count orelse
            return error.EmptyLateralContributionGeneration;
        var atomic_file = try self.directory.createFileAtomic(
            self.io,
            manifest_name,
            .{ .replace = true },
        );
        defer atomic_file.deinit(self.io);
        var writer = atomic_file.file.writerStreaming(self.io, buffer);
        try writer.interface.writeAll(manifest_magic);
        try writer.interface.writeInt(u32, format_version, .little);
        try writer.interface.writeInt(
            u64,
            self.source_generation_index,
            .little,
        );
        try writer.interface.writeInt(
            u64,
            self.destination_generation_index,
            .little,
        );
        try writer.interface.writeByte(morton_order_tag);
        try writer.interface.writeInt(u64, plan.lat_count, .little);
        try writer.interface.writeInt(u64, plan.lon_count, .little);
        try writer.interface.writeInt(u64, component_count, .little);
        try writer.interface.writeInt(u64, plan.tiles.len, .little);
        for (plan.tiles) |tile|
            try writer.interface.writeInt(u64, tile.z_order_index, .little);
        try writer.interface.flush();
        try atomic_file.file.sync(self.io);
        var replace_attempt: u8 = 1;
        while (true) {
            atomic_file.replace(self.io) catch |err| {
                if (!retryAtomicReplace(err, replace_attempt)) return err;
                try std.Io.sleep(
                    self.io,
                    .fromMilliseconds(atomic_replace_retry_delay_ms),
                    .awake,
                );
                replace_attempt += 1;
                continue;
            };
            break;
        }
    }

    /// Adds every first-pass contribution targeting the destination tile to
    /// its owned component array. Source files are opened only when the
    /// source tile's two-cell loaded view intersects the destination interior.
    pub fn gatherOwnedTile(
        self: FileStore,
        plan: spatial_grid.TilePlan,
        destination_tile_index: usize,
        component_count: usize,
        destination_delta: []f64,
    ) !void {
        if (destination_tile_index >= plan.tiles.len)
            return error.TileIndexOutOfRange;
        if (component_count == 0 or
            destination_delta.len !=
                plan.lat_count * plan.lon_count * component_count)
            return error.InvalidLateralContributionDestinationShape;
        try self.validateManifest(plan, component_count);
        const destination_tile = plan.tiles[destination_tile_index];
        const buffer = try self.allocator.alloc(u8, self.buffer_byte_count);
        defer self.allocator.free(buffer);
        for (plan.tiles) |source_tile| {
            if (!loadedIntersectsOwned(source_tile, destination_tile))
                continue;
            const file_name = try sourceFileName(
                self.allocator,
                source_tile.z_order_index,
            );
            defer self.allocator.free(file_name);
            var file = try self.directory.openFile(self.io, file_name, .{});
            defer file.close(self.io);
            var reader = file.readerStreaming(self.io, buffer);
            try readSourceIntoOwned(
                &reader.interface,
                self,
                plan,
                source_tile,
                destination_tile_index,
                component_count,
                destination_delta,
            );
        }
    }

    /// Gathers into a Morton-ordered, tile-local buffer. This is the
    /// production out-of-core path: memory scales with the active tile rather
    /// than the complete landscape, and tiles remain strictly serial.
    pub fn gatherOwnedTileCompact(
        self: FileStore,
        plan: spatial_grid.TilePlan,
        destination_tile_index: usize,
        component_count: usize,
        destination_delta: []f64,
    ) !void {
        if (destination_tile_index >= plan.tiles.len)
            return error.TileIndexOutOfRange;
        const owned_cells = try plan.ownedCells(destination_tile_index);
        if (component_count == 0 or
            destination_delta.len != owned_cells.len * component_count)
            return error.InvalidLateralContributionDestinationShape;
        try self.validateManifest(plan, component_count);
        const destination_tile = plan.tiles[destination_tile_index];
        const buffer = try self.allocator.alloc(u8, self.buffer_byte_count);
        defer self.allocator.free(buffer);
        for (plan.tiles) |source_tile| {
            if (!loadedIntersectsOwned(source_tile, destination_tile))
                continue;
            const file_name = try sourceFileName(
                self.allocator,
                source_tile.z_order_index,
            );
            defer self.allocator.free(file_name);
            var file = try self.directory.openFile(self.io, file_name, .{});
            defer file.close(self.io);
            var reader = file.readerStreaming(self.io, buffer);
            try readSourceIntoOwnedCompact(
                &reader.interface,
                self,
                plan,
                source_tile,
                destination_tile_index,
                component_count,
                destination_delta,
            );
        }
    }

    fn validateManifest(
        self: FileStore,
        plan: spatial_grid.TilePlan,
        component_count: usize,
    ) !void {
        const buffer = try self.allocator.alloc(u8, self.buffer_byte_count);
        defer self.allocator.free(buffer);
        var file = try self.directory.openFile(self.io, manifest_name, .{});
        defer file.close(self.io);
        var reader = file.readerStreaming(self.io, buffer);
        if (!std.mem.eql(
            u8,
            try reader.interface.takeArray(manifest_magic.len),
            manifest_magic,
        )) return error.InvalidLateralContributionManifestMagic;
        if (try reader.interface.takeInt(u32, .little) != format_version)
            return error.UnsupportedLateralContributionManifestVersion;
        if (try reader.interface.takeInt(u64, .little) !=
            self.source_generation_index or
            try reader.interface.takeInt(u64, .little) !=
                self.destination_generation_index)
            return error.LateralContributionManifestGenerationMismatch;
        if (try reader.interface.takeByte() != morton_order_tag)
            return error.LateralContributionManifestIsNotMortonOrdered;
        if (try reader.interface.takeInt(u64, .little) != plan.lat_count or
            try reader.interface.takeInt(u64, .little) != plan.lon_count)
            return error.LateralContributionManifestShapeMismatch;
        if (try reader.interface.takeInt(u64, .little) != component_count)
            return error.LateralContributionManifestComponentCountMismatch;
        if (try reader.interface.takeInt(u64, .little) != plan.tiles.len)
            return error.LateralContributionManifestShapeMismatch;
        for (plan.tiles) |tile|
            if (try reader.interface.takeInt(u64, .little) !=
                tile.z_order_index)
                return error.LateralContributionManifestTileOrderMismatch;
        if (reader.interface.peekByte()) |_| {
            return error.TrailingLateralContributionManifestData;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }
};

fn retryAtomicReplace(err: anyerror, attempt: u8) bool {
    // Zig 0.16 maps Windows STATUS_SHARING_VIOLATION during rename to
    // Unexpected. Retry only that transient class and retain a bounded,
    // fail-fast budget for persistent storage faults.
    return err == error.Unexpected and attempt < atomic_replace_max_attempts;
}

test "lateral manifest retries only transient atomic replace failures" {
    try std.testing.expect(retryAtomicReplace(error.Unexpected, 1));
    try std.testing.expect(retryAtomicReplace(
        error.Unexpected,
        atomic_replace_max_attempts - 1,
    ));
    try std.testing.expect(!retryAtomicReplace(
        error.Unexpected,
        atomic_replace_max_attempts,
    ));
    try std.testing.expect(!retryAtomicReplace(error.AccessDenied, 1));
}

fn validateSourceFile(
    reader: *std.Io.Reader,
    store: FileStore,
    plan: spatial_grid.TilePlan,
    source_tile: spatial_grid.Tile,
) !usize {
    if (!std.mem.eql(
        u8,
        try reader.takeArray(file_magic.len),
        file_magic,
    )) return error.InvalidLateralContributionFileMagic;
    if (try reader.takeInt(u32, .little) != format_version)
        return error.UnsupportedLateralContributionFileVersion;
    if (try reader.takeInt(u64, .little) != store.source_generation_index or
        try reader.takeInt(u64, .little) != store.destination_generation_index)
        return error.LateralContributionFileGenerationMismatch;
    if (try reader.takeByte() != morton_order_tag)
        return error.LateralContributionFileIsNotMortonOrdered;
    if (try reader.takeInt(u64, .little) != plan.lat_count or
        try reader.takeInt(u64, .little) != plan.lon_count or
        try reader.takeInt(u64, .little) != source_tile.z_order_index)
        return error.LateralContributionFileShapeMismatch;
    const component_count = std.math.cast(
        usize,
        try reader.takeInt(u64, .little),
    ) orelse return error.InvalidLateralContributionComponentCount;
    if (component_count == 0)
        return error.InvalidLateralContributionComponentCount;
    const record_count = try reader.takeInt(u64, .little);
    const source_tile_index = try plan.owningTileIndex(
        source_tile.owned_north_row * plan.lon_count +
            source_tile.owned_west_column,
    );
    var previous_cell_morton: ?u64 = null;
    var previous_component: usize = 0;
    for (0..record_count) |_| {
        const target_cell = std.math.cast(
            usize,
            try reader.takeInt(u64, .little),
        ) orelse return error.InvalidLateralContributionRecord;
        const component = std.math.cast(
            usize,
            try reader.takeInt(u64, .little),
        ) orelse return error.InvalidLateralContributionRecord;
        const delta: f64 = @bitCast(try reader.takeInt(u64, .little));
        const contribution = Contribution{
            .target_cell = target_cell,
            .component = component,
            .delta = delta,
        };
        try validateContribution(
            plan,
            source_tile_index,
            component_count,
            contribution,
        );
        const row = target_cell / plan.lon_count;
        const column = target_cell % plan.lon_count;
        const cell_morton = cellMortonIndex(
            @intCast(row),
            @intCast(column),
        );
        if (previous_cell_morton) |previous| {
            if (cell_morton < previous or
                (cell_morton == previous and component < previous_component))
                return error.LateralContributionRecordsAreNotMortonOrdered;
        }
        previous_cell_morton = cell_morton;
        previous_component = component;
    }
    if (reader.peekByte()) |_| {
        return error.TrailingLateralContributionFileData;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    return component_count;
}

fn readSourceIntoOwned(
    reader: *std.Io.Reader,
    store: FileStore,
    plan: spatial_grid.TilePlan,
    source_tile: spatial_grid.Tile,
    destination_tile_index: usize,
    component_count: usize,
    destination_delta: []f64,
) !void {
    if (!std.mem.eql(
        u8,
        try reader.takeArray(file_magic.len),
        file_magic,
    )) return error.InvalidLateralContributionFileMagic;
    if (try reader.takeInt(u32, .little) != format_version)
        return error.UnsupportedLateralContributionFileVersion;
    if (try reader.takeInt(u64, .little) != store.source_generation_index or
        try reader.takeInt(u64, .little) != store.destination_generation_index)
        return error.LateralContributionFileGenerationMismatch;
    if (try reader.takeByte() != morton_order_tag)
        return error.LateralContributionFileIsNotMortonOrdered;
    if (try reader.takeInt(u64, .little) != plan.lat_count or
        try reader.takeInt(u64, .little) != plan.lon_count or
        try reader.takeInt(u64, .little) != source_tile.z_order_index or
        try reader.takeInt(u64, .little) != component_count)
        return error.LateralContributionFileShapeMismatch;
    const record_count = try reader.takeInt(u64, .little);
    var previous_cell_morton: ?u64 = null;
    var previous_component: usize = 0;
    for (0..record_count) |_| {
        const target_cell = try reader.takeInt(u64, .little);
        const component = try reader.takeInt(u64, .little);
        const delta: f64 = @bitCast(try reader.takeInt(u64, .little));
        if (target_cell >= plan.lat_count * plan.lon_count or
            component >= component_count or !std.math.isFinite(delta))
            return error.InvalidLateralContributionRecord;
        const row = target_cell / plan.lon_count;
        const column = target_cell % plan.lon_count;
        const cell_morton = cellMortonIndex(
            @intCast(row),
            @intCast(column),
        );
        if (previous_cell_morton) |previous| {
            if (cell_morton < previous or
                (cell_morton == previous and component < previous_component))
                return error.LateralContributionRecordsAreNotMortonOrdered;
        }
        previous_cell_morton = cell_morton;
        previous_component = component;
        if (try plan.tileOwnsCell(destination_tile_index, target_cell)) {
            const destination_index = target_cell * component_count + component;
            destination_delta[destination_index] += delta;
            if (!std.math.isFinite(destination_delta[destination_index]))
                return error.NonFiniteLateralContributionSum;
        }
    }
    if (reader.peekByte()) |_| {
        return error.TrailingLateralContributionFileData;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
}

fn readSourceIntoOwnedCompact(
    reader: *std.Io.Reader,
    store: FileStore,
    plan: spatial_grid.TilePlan,
    source_tile: spatial_grid.Tile,
    destination_tile_index: usize,
    component_count: usize,
    destination_delta: []f64,
) !void {
    if (!std.mem.eql(
        u8,
        try reader.takeArray(file_magic.len),
        file_magic,
    )) return error.InvalidLateralContributionFileMagic;
    if (try reader.takeInt(u32, .little) != format_version)
        return error.UnsupportedLateralContributionFileVersion;
    if (try reader.takeInt(u64, .little) != store.source_generation_index or
        try reader.takeInt(u64, .little) != store.destination_generation_index)
        return error.LateralContributionFileGenerationMismatch;
    if (try reader.takeByte() != morton_order_tag)
        return error.LateralContributionFileIsNotMortonOrdered;
    if (try reader.takeInt(u64, .little) != plan.lat_count or
        try reader.takeInt(u64, .little) != plan.lon_count or
        try reader.takeInt(u64, .little) != source_tile.z_order_index or
        try reader.takeInt(u64, .little) != component_count)
        return error.LateralContributionFileShapeMismatch;
    const record_count = try reader.takeInt(u64, .little);
    var previous_cell_morton: ?u64 = null;
    var previous_component: usize = 0;
    for (0..record_count) |_| {
        const target_cell = try reader.takeInt(u64, .little);
        const component = try reader.takeInt(u64, .little);
        const delta: f64 = @bitCast(try reader.takeInt(u64, .little));
        if (target_cell >= plan.lat_count * plan.lon_count or
            component >= component_count or !std.math.isFinite(delta))
            return error.InvalidLateralContributionRecord;
        const row = target_cell / plan.lon_count;
        const column = target_cell % plan.lon_count;
        const cell_morton = cellMortonIndex(
            @intCast(row),
            @intCast(column),
        );
        if (previous_cell_morton) |previous| {
            if (cell_morton < previous or
                (cell_morton == previous and component < previous_component))
                return error.LateralContributionRecordsAreNotMortonOrdered;
        }
        previous_cell_morton = cell_morton;
        previous_component = component;
        if (try plan.tileOwnsCell(destination_tile_index, target_cell)) {
            const local_cell = try plan.ownedCellOffsetWithinTile(
                destination_tile_index,
                target_cell,
            );
            const destination_index =
                local_cell * component_count + component;
            destination_delta[destination_index] += delta;
            if (!std.math.isFinite(destination_delta[destination_index]))
                return error.NonFiniteLateralContributionSum;
        }
    }
    if (reader.peekByte()) |_| {
        return error.TrailingLateralContributionFileData;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
}

fn validateContribution(
    plan: spatial_grid.TilePlan,
    source_tile_index: usize,
    component_count: usize,
    contribution: Contribution,
) !void {
    if (contribution.target_cell >=
        plan.lat_count * plan.lon_count or
        contribution.component >= component_count or
        !std.math.isFinite(contribution.delta))
        return error.InvalidLateralContributionRecord;
    if (!try plan.tileLoadsCell(source_tile_index, contribution.target_cell))
        return error.LateralContributionTargetOutsideSourceTileHalo;
}

fn contributionSortKey(
    contribution: Contribution,
    original_index: usize,
    lon_count: usize,
) ContributionSortKey {
    return .{
        .morton_index = cellMortonIndex(
            @intCast(contribution.target_cell / lon_count),
            @intCast(contribution.target_cell % lon_count),
        ),
        .component = contribution.component,
        .original_index = original_index,
    };
}

noinline fn contributionSortKeyLessThan(
    _: void,
    left: ContributionSortKey,
    right: ContributionSortKey,
) bool {
    return left.morton_index < right.morton_index or
        (left.morton_index == right.morton_index and
            (left.component < right.component or
                (left.component == right.component and
                    left.original_index < right.original_index)));
}

fn cellMortonIndex(row: u32, column: u32) u64 {
    var result: u64 = 0;
    for (0..32) |bit| {
        result |= (@as(u64, (column >> @intCast(bit)) & 1) <<
            @intCast(2 * bit));
        result |= (@as(u64, (row >> @intCast(bit)) & 1) <<
            @intCast(2 * bit + 1));
    }
    return result;
}

fn loadedIntersectsOwned(
    source: spatial_grid.Tile,
    destination: spatial_grid.Tile,
) bool {
    return source.loaded_north_row <
        destination.owned_south_row_exclusive and
        source.loaded_south_row_exclusive > destination.owned_north_row and
        source.loaded_west_column < destination.owned_east_column_exclusive and
        source.loaded_east_column_exclusive > destination.owned_west_column;
}

fn sourceFileName(
    allocator: std.mem.Allocator,
    z_order_index: u64,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "lateral-{x:0>16}.morton.bin",
        .{z_order_index},
    );
}

// Test oracle for the exact comparison used by the former stable block sort.
// This function and its std.mem.sort instantiation are unreachable from
// production builds.
fn legacyContributionLessThan(
    lon_count: usize,
    left: Contribution,
    right: Contribution,
) bool {
    const left_morton = cellMortonIndex(
        @intCast(left.target_cell / lon_count),
        @intCast(left.target_cell % lon_count),
    );
    const right_morton = cellMortonIndex(
        @intCast(right.target_cell / lon_count),
        @intCast(right.target_cell % lon_count),
    );
    return left_morton < right_morton or
        (left_morton == right_morton and left.component < right.component);
}

fn appendLittleEndian(
    comptime T: type,
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: T,
) !void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    try bytes.appendSlice(allocator, &encoded);
}

test "deterministic pdq contribution keys preserve legacy stable bytes" {
    try std.testing.expectEqual(
        @sizeOf(Contribution),
        @sizeOf(ContributionSortKey),
    );
    try std.testing.expectEqual(
        @alignOf(Contribution),
        @alignOf(ContributionSortKey),
    );

    var plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        3,
        4,
        3,
        4,
        2,
    );
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.tiles.len);

    // Cells 3 and 4 deliberately reverse row-major order under Morton order.
    // Repeated cell/component records carry distinct f64 bit patterns so an
    // equal-key reordering changes the serialized bytes and fails this test.
    const contributions = [_]Contribution{
        .{ .target_cell = 11, .component = 2, .delta = 0x1.fffffffffffffp+1023 },
        .{ .target_cell = 3, .component = 1, .delta = -0.0 },
        .{ .target_cell = 4, .component = 1, .delta = 11.0 },
        .{ .target_cell = 0, .component = 2, .delta = 0x0.0000000000001p-1022 },
        .{ .target_cell = 3, .component = 1, .delta = 0.0 },
        .{ .target_cell = 4, .component = 0, .delta = -7.0 },
        .{ .target_cell = 4, .component = 1, .delta = 12.0 },
        .{ .target_cell = 0, .component = 0, .delta = -0x1.fffffffffffffp+1023 },
        .{ .target_cell = 11, .component = 2, .delta = -13.0 },
    };

    const legacy = try std.testing.allocator.dupe(Contribution, &contributions);
    defer std.testing.allocator.free(legacy);
    std.mem.sort(
        Contribution,
        legacy,
        plan.lon_count,
        legacyContributionLessThan,
    );

    const keys = try std.testing.allocator.alloc(
        ContributionSortKey,
        contributions.len,
    );
    defer std.testing.allocator.free(keys);
    for (contributions, 0..) |contribution, original_index|
        keys[original_index] = contributionSortKey(
            contribution,
            original_index,
            plan.lon_count,
        );
    std.sort.pdq(
        ContributionSortKey,
        keys,
        {},
        contributionSortKeyLessThan,
    );
    for (legacy, keys) |expected, key| {
        const actual = contributions[key.original_index];
        try std.testing.expectEqual(expected.target_cell, actual.target_cell);
        try std.testing.expectEqual(expected.component, actual.component);
        try std.testing.expectEqual(
            @as(u64, @bitCast(expected.delta)),
            @as(u64, @bitCast(actual.delta)),
        );
    }

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        4096,
        50,
        51,
    );
    try store.saveSourceTile(plan, 0, 3, &contributions);
    const file_name = try sourceFileName(
        std.testing.allocator,
        plan.tiles[0].z_order_index,
    );
    defer std.testing.allocator.free(file_name);
    const actual_bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        file_name,
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(actual_bytes);

    var expected_bytes = std.ArrayList(u8).empty;
    defer expected_bytes.deinit(std.testing.allocator);
    try expected_bytes.appendSlice(std.testing.allocator, file_magic);
    try appendLittleEndian(u32, &expected_bytes, std.testing.allocator, format_version);
    try appendLittleEndian(u64, &expected_bytes, std.testing.allocator, 50);
    try appendLittleEndian(u64, &expected_bytes, std.testing.allocator, 51);
    try expected_bytes.append(std.testing.allocator, morton_order_tag);
    try appendLittleEndian(u64, &expected_bytes, std.testing.allocator, plan.lat_count);
    try appendLittleEndian(u64, &expected_bytes, std.testing.allocator, plan.lon_count);
    try appendLittleEndian(
        u64,
        &expected_bytes,
        std.testing.allocator,
        plan.tiles[0].z_order_index,
    );
    try appendLittleEndian(u64, &expected_bytes, std.testing.allocator, 3);
    try appendLittleEndian(u64, &expected_bytes, std.testing.allocator, legacy.len);
    for (legacy) |contribution| {
        try appendLittleEndian(
            u64,
            &expected_bytes,
            std.testing.allocator,
            contribution.target_cell,
        );
        try appendLittleEndian(
            u64,
            &expected_bytes,
            std.testing.allocator,
            contribution.component,
        );
        try appendLittleEndian(
            u64,
            &expected_bytes,
            std.testing.allocator,
            @bitCast(contribution.delta),
        );
    }
    try std.testing.expectEqualSlices(u8, expected_bytes.items, actual_bytes);
}

test "contribution sort rejects non-finite records before publication" {
    var plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        1,
        1,
        1,
        1,
        2,
    );
    defer plan.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        256,
        60,
        61,
    );
    const invalid_deltas = [_]f64{
        std.math.nan(f64),
        std.math.inf(f64),
        -std.math.inf(f64),
    };
    for (invalid_deltas) |delta| {
        try std.testing.expectError(
            error.InvalidLateralContributionRecord,
            store.saveSourceTile(
                plan,
                0,
                1,
                &.{.{ .target_cell = 0, .component = 0, .delta = delta }},
            ),
        );
    }
    const file_name = try sourceFileName(
        std.testing.allocator,
        plan.tiles[0].z_order_index,
    );
    defer std.testing.allocator.free(file_name);
    var file = temporary.dir.openFile(
        std.testing.io,
        file_name,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    file.close(std.testing.io);
    return error.NonFiniteContributionWasPublished;
}

test "two-pass Morton lateral contribution files conserve cross-tile exchange" {
    var plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        2,
        4,
        2,
        2,
        2,
    );
    defer plan.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        4096,
        10,
        11,
    );
    const component_count: usize = 2;
    const all_delta = try std.testing.allocator.alloc(
        f64,
        2 * 4 * component_count,
    );
    defer std.testing.allocator.free(all_delta);
    @memset(all_delta, 0);

    for (plan.tiles, 0..) |_, tile_index| {
        var contributions = std.ArrayList(Contribution).empty;
        defer contributions.deinit(std.testing.allocator);
        for (try plan.ownedNeighborFaces(tile_index)) |face| {
            try contributions.appendSlice(std.testing.allocator, &.{
                .{
                    .target_cell = face.first_cell,
                    .component = 0,
                    .delta = -1,
                },
                .{
                    .target_cell = face.second_cell,
                    .component = 0,
                    .delta = 1,
                },
            });
        }
        try store.saveSourceTile(
            plan,
            tile_index,
            component_count,
            contributions.items,
        );
    }
    try store.publish(plan);
    for (plan.tiles, 0..) |_, tile_index|
        try store.gatherOwnedTile(
            plan,
            tile_index,
            component_count,
            all_delta,
        );

    var total_delta: f64 = 0;
    for (0..plan.lat_count * plan.lon_count) |cell|
        total_delta += all_delta[cell * component_count];
    try std.testing.expectEqual(@as(f64, 0), total_delta);
    for (0..plan.lat_count * plan.lon_count) |cell|
        try std.testing.expectEqual(
            @as(f64, 0),
            all_delta[cell * component_count + 1],
        );
}

test "compact Morton gather uses only active tile memory" {
    var plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        2,
        4,
        2,
        2,
        2,
    );
    defer plan.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        4096,
        20,
        21,
    );
    for (plan.tiles, 0..) |_, tile_index| {
        var contributions = std.ArrayList(Contribution).empty;
        defer contributions.deinit(std.testing.allocator);
        for (try plan.ownedNeighborFaces(tile_index)) |face|
            try contributions.appendSlice(std.testing.allocator, &.{
                .{ .target_cell = face.first_cell, .component = 0, .delta = -1 },
                .{ .target_cell = face.second_cell, .component = 0, .delta = 1 },
            });
        try store.saveSourceTile(plan, tile_index, 1, contributions.items);
    }
    try store.publish(plan);

    var total_delta: f64 = 0;
    for (plan.tiles, 0..) |_, tile_index| {
        const owned_cells = try plan.ownedCells(tile_index);
        const compact = try std.testing.allocator.alloc(f64, owned_cells.len);
        defer std.testing.allocator.free(compact);
        @memset(compact, 0);
        try store.gatherOwnedTileCompact(plan, tile_index, 1, compact);
        for (compact) |delta| total_delta += delta;
    }
    try std.testing.expectEqual(@as(f64, 0), total_delta);
}

test "state_update rejects a truncated Morton source before writing manifest" {
    var plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        1,
        3,
        1,
        2,
        2,
    );
    defer plan.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        256,
        30,
        31,
    );
    for (plan.tiles, 0..) |_, tile_index| try store.saveSourceTile(
        plan,
        tile_index,
        2,
        &.{},
    );

    const corrupt_name = try sourceFileName(
        std.testing.allocator,
        plan.tiles[plan.tiles.len - 1].z_order_index,
    );
    defer std.testing.allocator.free(corrupt_name);
    var corrupt_file = try temporary.dir.createFile(
        std.testing.io,
        corrupt_name,
        .{},
    );
    try corrupt_file.writeStreamingAll(std.testing.io, file_magic);
    corrupt_file.close(std.testing.io);

    try std.testing.expectError(error.EndOfStream, store.publish(plan));
    var manifest = temporary.dir.openFile(
        std.testing.io,
        manifest_name,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    manifest.close(std.testing.io);
    return error.InvalidLateralManifestPublishedAfterFailedPreflight;
}

test "state_update rejects inconsistent runtime component counts" {
    var plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        1,
        3,
        1,
        2,
        2,
    );
    defer plan.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        256,
        40,
        41,
    );
    try store.saveSourceTile(plan, 0, 2, &.{});
    try store.saveSourceTile(plan, 1, 3, &.{});
    try std.testing.expectError(
        error.LateralContributionComponentCountMismatch,
        store.publish(plan),
    );
}

const std = @import("std");
const compute = @import("../core/compute.zig");

pub const BoundsDegrees = struct {
    minimum_latitude_degrees_north: f64,
    maximum_latitude_degrees_north: f64,
    minimum_longitude_degrees_east: f64,
    maximum_longitude_degrees_east: f64,
    latitude_interval_degrees: f64,
    longitude_interval_degrees: f64,
};

/// Values are the site-file NCNG semantics: 1 connects lateral neighbors and
/// 3 disables lateral exchange.
pub fn validateNeighborExchangeControls(
    row_count: usize,
    column_count: usize,
    lateral_connection_mode_by_cell: []const u8,
) !void {
    const cell_count = try std.math.mul(usize, row_count, column_count);
    if (row_count == 0 or column_count == 0 or
        lateral_connection_mode_by_cell.len != cell_count)
        return error.NeighborExchangeControlDimensionMismatch;
    for (0..row_count) |row| for (0..column_count) |column| {
        const cell = row * column_count + column;
        const mode = lateral_connection_mode_by_cell[cell];
        if (mode != 1 and mode != 3) return error.InvalidLateralConnectionMode;
    };
}

/// A shared face exchanges only when both cells opt in. Computing the decision
/// once per undirected face preserves conservation even when site files differ.
pub fn cellsExchangeMassAndEnergy(left_mode: u8, right_mode: u8) !bool {
    if ((left_mode != 1 and left_mode != 3) or
        (right_mode != 1 and right_mode != 3))
        return error.InvalidLateralConnectionMode;
    return left_mode == 1 and right_mode == 1;
}

/// Runtime regular grid whose bounds are cell edges. Rows are ordered north to
/// south and columns west to east. Dimensions use the WGS84 ellipsoid at each
/// cell center rather than a spherical constant.
pub const RegularGrid = struct {
    allocator: std.mem.Allocator,
    row_count: usize,
    column_count: usize,
    bounds: BoundsDegrees,
    latitude_degrees_north_by_cell: []f64,
    longitude_degrees_east_by_cell: []f64,
    north_south_cell_width_m: []f64,
    east_west_cell_width_m: []f64,

    pub fn init(allocator: std.mem.Allocator, bounds: BoundsDegrees) !RegularGrid {
        try validateBounds(bounds);
        const row_count = try intervalCount(
            bounds.maximum_latitude_degrees_north - bounds.minimum_latitude_degrees_north,
            bounds.latitude_interval_degrees,
        );
        const column_count = try intervalCount(
            bounds.maximum_longitude_degrees_east - bounds.minimum_longitude_degrees_east,
            bounds.longitude_interval_degrees,
        );
        const cell_count = try std.math.mul(usize, row_count, column_count);
        var result: RegularGrid = undefined;
        result.allocator = allocator;
        result.row_count = row_count;
        result.column_count = column_count;
        result.bounds = bounds;
        var allocated: usize = 0;
        errdefer result.freeAllocated(allocated);
        inline for (@typeInfo(RegularGrid).@"struct".fields) |field| {
            if (field.type != []f64) continue;
            @field(result, field.name) = try allocator.alloc(f64, cell_count);
            allocated += 1;
        }

        const latitude_interval_radians = bounds.latitude_interval_degrees * std.math.pi / 180;
        const longitude_interval_radians = bounds.longitude_interval_degrees * std.math.pi / 180;
        for (0..row_count) |row| for (0..column_count) |column| {
            const cell = row * column_count + column;
            const latitude_degrees_north =
                bounds.maximum_latitude_degrees_north -
                (@as(f64, @floatFromInt(row)) + 0.5) * bounds.latitude_interval_degrees;
            const longitude_degrees_east =
                bounds.minimum_longitude_degrees_east +
                (@as(f64, @floatFromInt(column)) + 0.5) * bounds.longitude_interval_degrees;
            const radii = try wgs84RadiiOfCurvature(latitude_degrees_north);
            const latitude_radians = latitude_degrees_north * std.math.pi / 180;
            result.latitude_degrees_north_by_cell[cell] = latitude_degrees_north;
            result.longitude_degrees_east_by_cell[cell] = longitude_degrees_east;
            result.north_south_cell_width_m[cell] =
                radii.meridional_radius_m * latitude_interval_radians;
            result.east_west_cell_width_m[cell] =
                radii.prime_vertical_radius_m * @cos(latitude_radians) * longitude_interval_radians;
            inline for (.{
                result.north_south_cell_width_m[cell],
                result.east_west_cell_width_m[cell],
            }) |width_m| if (!std.math.isFinite(width_m) or width_m <= 0)
                return error.InvalidGeospatialCellDimension;
        };
        return result;
    }

    pub fn deinit(self: *RegularGrid) void {
        self.freeAllocated(4);
        self.* = undefined;
    }

    pub fn cellCount(self: RegularGrid) !usize {
        return std.math.mul(usize, self.row_count, self.column_count);
    }

    /// Coordinate precision carried by every user-facing input, in decimal
    /// degrees. Six digits is ~0.11 m of latitude, so location is resolved to
    /// better than 1 m everywhere. Users never supply a row or column index;
    /// this is the only spatial identifier the model accepts.
    pub const coordinate_precision_degrees: f64 = 1.0e-6;

    /// Derives the containing cell index from latitude and longitude. This is
    /// the sole coordinate-to-index path: grid rows and columns are internal
    /// and are never requested from the user. A coordinate outside the
    /// declared extent is an error, never a clamp to the nearest cell.
    pub fn cellIndexForCoordinate(
        self: RegularGrid,
        latitude_degrees_north: f64,
        longitude_degrees_east: f64,
    ) !usize {
        if (!std.math.isFinite(latitude_degrees_north) or
            !std.math.isFinite(longitude_degrees_east))
            return error.NonFiniteSiteCoordinate;

        // Half of the coordinate precision, so a coordinate written to six
        // decimals exactly on a boundary resolves without falling outside.
        const edge_tolerance = coordinate_precision_degrees / 2;
        if (latitude_degrees_north < self.bounds.minimum_latitude_degrees_north - edge_tolerance or
            latitude_degrees_north > self.bounds.maximum_latitude_degrees_north + edge_tolerance or
            longitude_degrees_east < self.bounds.minimum_longitude_degrees_east - edge_tolerance or
            longitude_degrees_east > self.bounds.maximum_longitude_degrees_east + edge_tolerance)
            return error.SiteCoordinateOutsideGeospatialGrid;

        // Rows run north to south, columns west to east.
        const rows_from_north = (self.bounds.maximum_latitude_degrees_north -
            latitude_degrees_north) / self.bounds.latitude_interval_degrees;
        const columns_from_west = (longitude_degrees_east -
            self.bounds.minimum_longitude_degrees_east) / self.bounds.longitude_interval_degrees;
        if (!std.math.isFinite(rows_from_north) or !std.math.isFinite(columns_from_west))
            return error.InvalidGeospatialCellDimension;

        const row = clampIndex(rows_from_north, self.row_count);
        const column = clampIndex(columns_from_west, self.column_count);
        return row * self.column_count + column;
    }

    /// Floors a fractional cell offset and pins the far edge into the last
    /// cell. The caller has already rejected coordinates outside the extent,
    /// so this only resolves the closed upper boundary.
    fn clampIndex(offset: f64, count: usize) usize {
        if (offset <= 0) return 0;
        const floored = @floor(offset);
        if (floored >= @as(f64, @floatFromInt(count))) return count - 1;
        return @intFromFloat(floored);
    }

    pub fn validateSiteCoordinate(
        self: RegularGrid,
        cell: usize,
        latitude_degrees_north: f64,
        longitude_degrees_east: f64,
    ) !void {
        if (cell >= try self.cellCount()) return error.GeospatialCellOutOfRange;
        if (!std.math.isFinite(latitude_degrees_north) or
            !std.math.isFinite(longitude_degrees_east))
            return error.NonFiniteSiteCoordinate;
        // The site coordinate identifies its own cell. It only has to fall
        // inside the cell, not sit exactly on the cell center, because users
        // supply a real location to six decimal degrees rather than a grid
        // index.
        const located = try self.cellIndexForCoordinate(
            latitude_degrees_north,
            longitude_degrees_east,
        );
        if (located != cell) return error.SiteCoordinateDoesNotMatchGridCell;
    }

    fn freeAllocated(self: *RegularGrid, allocated: usize) void {
        var visited: usize = 0;
        inline for (@typeInfo(RegularGrid).@"struct".fields) |field| {
            if (field.type != []f64) continue;
            if (visited < allocated) self.allocator.free(@field(self, field.name));
            visited += 1;
        }
    }
};

pub const Tile = struct {
    z_order_index: u64,
    owned_north_row: usize,
    owned_west_column: usize,
    owned_south_row_exclusive: usize,
    owned_east_column_exclusive: usize,
    loaded_north_row: usize,
    loaded_west_column: usize,
    loaded_south_row_exclusive: usize,
    loaded_east_column_exclusive: usize,

    pub fn ownedRowCount(self: Tile) usize {
        return self.owned_south_row_exclusive - self.owned_north_row;
    }

    pub fn ownedColumnCount(self: Tile) usize {
        return self.owned_east_column_exclusive - self.owned_west_column;
    }

    pub fn loadedCellIndicesZOrder(
        self: Tile,
        allocator: std.mem.Allocator,
        lat_count: usize,
        lon_count: usize,
    ) ![]usize {
        if (self.loaded_south_row_exclusive > lat_count or
            self.loaded_east_column_exclusive > lon_count or
            lat_count > std.math.maxInt(u32) or
            lon_count > std.math.maxInt(u32))
            return error.InvalidTileBounds;
        const rows = self.loaded_south_row_exclusive - self.loaded_north_row;
        const columns = self.loaded_east_column_exclusive - self.loaded_west_column;
        const indices = try allocator.alloc(usize, try std.math.mul(usize, rows, columns));
        errdefer allocator.free(indices);
        var next: usize = 0;
        for (self.loaded_north_row..self.loaded_south_row_exclusive) |row| {
            for (self.loaded_west_column..self.loaded_east_column_exclusive) |column| {
                indices[next] = row * lon_count + column;
                next += 1;
            }
        }
        std.sort.pdq(usize, indices, lon_count, struct {
            fn lessThan(columns_in_grid: usize, left: usize, right: usize) bool {
                return mortonIndex(
                    @intCast(left / columns_in_grid),
                    @intCast(left % columns_in_grid),
                ) < mortonIndex(
                    @intCast(right / columns_in_grid),
                    @intCast(right % columns_in_grid),
                );
            }
        }.lessThan);
        return indices;
    }

    pub fn ownedCellIndicesZOrder(
        self: Tile,
        allocator: std.mem.Allocator,
        lat_count: usize,
        lon_count: usize,
    ) ![]usize {
        var owned = self;
        owned.loaded_north_row = self.owned_north_row;
        owned.loaded_west_column = self.owned_west_column;
        owned.loaded_south_row_exclusive = self.owned_south_row_exclusive;
        owned.loaded_east_column_exclusive = self.owned_east_column_exclusive;
        return owned.loadedCellIndicesZOrder(
            allocator,
            lat_count,
            lon_count,
        );
    }
};

/// Heap-owned out-of-core schedule. Each tile reads a two-cell neighbor halo
/// but owns and state_updates only its non-overlapping interior.
pub const NeighborFace = struct {
    first_cell: usize,
    second_cell: usize,
};

pub const TilePlan = struct {
    allocator: std.mem.Allocator,
    lat_count: usize,
    lon_count: usize,
    tile_row_count: usize,
    tile_column_count: usize,
    neighbor_halo_cell_count: usize,
    tiles: []Tile,
    owned_cell_offsets: []usize,
    owned_cells_z_order: []usize,
    owning_tile_index_by_cell: []usize,
    owned_cell_offset_within_tile_by_cell: []usize,
    neighbor_face_offsets: []usize,
    neighbor_faces_by_tile: []NeighborFace,

    pub fn init(
        allocator: std.mem.Allocator,
        lat_count: usize,
        lon_count: usize,
        tile_row_count: usize,
        tile_column_count: usize,
        neighbor_halo_cell_count: usize,
    ) !TilePlan {
        if (lat_count == 0 or lon_count == 0 or
            tile_row_count == 0 or tile_column_count == 0)
            return error.InvalidTileDimensions;
        if (neighbor_halo_cell_count != 2)
            return error.InvalidLateralFlowTileHalo;
        const tile_rows = std.math.divCeil(usize, lat_count, tile_row_count) catch
            return error.InvalidTileDimensions;
        const tile_columns = std.math.divCeil(usize, lon_count, tile_column_count) catch
            return error.InvalidTileDimensions;
        const tiles = try allocator.alloc(Tile, try std.math.mul(usize, tile_rows, tile_columns));
        errdefer allocator.free(tiles);
        if (tile_rows > std.math.maxInt(u32) or tile_columns > std.math.maxInt(u32))
            return error.TileGridTooLargeForZOrder;
        for (0..tile_rows) |tile_row| for (0..tile_columns) |tile_column| {
            const index = tile_row * tile_columns + tile_column;
            const north = tile_row * tile_row_count;
            const west = tile_column * tile_column_count;
            const south = @min(lat_count, north + tile_row_count);
            const east = @min(lon_count, west + tile_column_count);
            tiles[index] = .{
                .z_order_index = mortonIndex(
                    @intCast(tile_row),
                    @intCast(tile_column),
                ),
                .owned_north_row = north,
                .owned_west_column = west,
                .owned_south_row_exclusive = south,
                .owned_east_column_exclusive = east,
                .loaded_north_row = north -| neighbor_halo_cell_count,
                .loaded_west_column = west -| neighbor_halo_cell_count,
                .loaded_south_row_exclusive = @min(
                    lat_count,
                    south + neighbor_halo_cell_count,
                ),
                .loaded_east_column_exclusive = @min(
                    lon_count,
                    east + neighbor_halo_cell_count,
                ),
            };
        };
        // Tiles execute serially in Morton order; cells inside a tile remain
        // available to parallel kernels.
        for (1..tiles.len) |index| {
            const value = tiles[index];
            var insertion = index;
            while (insertion > 0 and
                tiles[insertion - 1].z_order_index > value.z_order_index)
            {
                tiles[insertion] = tiles[insertion - 1];
                insertion -= 1;
            }
            tiles[insertion] = value;
        }
        const owned_cell_offsets = try allocator.alloc(usize, tiles.len + 1);
        errdefer allocator.free(owned_cell_offsets);
        const grid_cell_count = try std.math.mul(
            usize,
            lat_count,
            lon_count,
        );
        const owned_cells_z_order = try allocator.alloc(
            usize,
            grid_cell_count,
        );
        errdefer allocator.free(owned_cells_z_order);
        const owning_tile_index_by_cell = try allocator.alloc(
            usize,
            grid_cell_count,
        );
        errdefer allocator.free(owning_tile_index_by_cell);
        const owned_cell_offset_within_tile_by_cell = try allocator.alloc(
            usize,
            grid_cell_count,
        );
        errdefer allocator.free(owned_cell_offset_within_tile_by_cell);
        @memset(owning_tile_index_by_cell, std.math.maxInt(usize));
        @memset(
            owned_cell_offset_within_tile_by_cell,
            std.math.maxInt(usize),
        );
        owned_cell_offsets[0] = 0;
        var next_cell: usize = 0;
        for (tiles, 0..) |tile, tile_index| {
            const indices = try tile.ownedCellIndicesZOrder(
                allocator,
                lat_count,
                lon_count,
            );
            defer allocator.free(indices);
            @memcpy(
                owned_cells_z_order[next_cell..][0..indices.len],
                indices,
            );
            for (indices, 0..) |cell, local_offset| {
                if (owning_tile_index_by_cell[cell] != std.math.maxInt(usize))
                    return error.TilePlanCellOwnedMoreThanOnce;
                owning_tile_index_by_cell[cell] = tile_index;
                owned_cell_offset_within_tile_by_cell[cell] = local_offset;
            }
            next_cell += indices.len;
            owned_cell_offsets[tile_index + 1] = next_cell;
        }
        if (next_cell != grid_cell_count)
            return error.TilePlanOwnershipMismatch;
        for (owning_tile_index_by_cell) |tile_index|
            if (tile_index == std.math.maxInt(usize))
                return error.TilePlanCellHasNoOwner;
        const horizontal_face_count = try std.math.mul(
            usize,
            lat_count,
            lon_count - 1,
        );
        const vertical_face_count = try std.math.mul(
            usize,
            lat_count - 1,
            lon_count,
        );
        const neighbor_face_count = try std.math.add(
            usize,
            horizontal_face_count,
            vertical_face_count,
        );
        const neighbor_faces_by_tile = try allocator.alloc(
            NeighborFace,
            neighbor_face_count,
        );
        errdefer allocator.free(neighbor_faces_by_tile);
        const neighbor_face_offsets = try allocator.alloc(
            usize,
            tiles.len + 1,
        );
        errdefer allocator.free(neighbor_face_offsets);
        @memset(neighbor_face_offsets, 0);
        for (0..lat_count) |row| {
            for (0..lon_count) |column| {
                const first_cell = row * lon_count + column;
                if (column + 1 < lon_count) {
                    const owner = neighborFaceOwnerIndex(
                        lon_count,
                        owning_tile_index_by_cell,
                        first_cell,
                        first_cell + 1,
                    );
                    neighbor_face_offsets[owner + 1] += 1;
                }
                if (row + 1 < lat_count) {
                    const owner = neighborFaceOwnerIndex(
                        lon_count,
                        owning_tile_index_by_cell,
                        first_cell,
                        first_cell + lon_count,
                    );
                    neighbor_face_offsets[owner + 1] += 1;
                }
            }
        }
        for (1..neighbor_face_offsets.len) |index|
            neighbor_face_offsets[index] += neighbor_face_offsets[index - 1];
        const next_face_by_tile = try allocator.dupe(
            usize,
            neighbor_face_offsets[0..tiles.len],
        );
        defer allocator.free(next_face_by_tile);
        for (0..lat_count) |row| {
            for (0..lon_count) |column| {
                const first_cell = row * lon_count + column;
                if (column + 1 < lon_count) {
                    const second_cell = first_cell + 1;
                    const owner = neighborFaceOwnerIndex(
                        lon_count,
                        owning_tile_index_by_cell,
                        first_cell,
                        second_cell,
                    );
                    neighbor_faces_by_tile[next_face_by_tile[owner]] = .{
                        .first_cell = first_cell,
                        .second_cell = second_cell,
                    };
                    next_face_by_tile[owner] += 1;
                }
                if (row + 1 < lat_count) {
                    const second_cell = first_cell + lon_count;
                    const owner = neighborFaceOwnerIndex(
                        lon_count,
                        owning_tile_index_by_cell,
                        first_cell,
                        second_cell,
                    );
                    neighbor_faces_by_tile[next_face_by_tile[owner]] = .{
                        .first_cell = first_cell,
                        .second_cell = second_cell,
                    };
                    next_face_by_tile[owner] += 1;
                }
            }
        }
        return .{
            .allocator = allocator,
            .lat_count = lat_count,
            .lon_count = lon_count,
            .tile_row_count = tile_row_count,
            .tile_column_count = tile_column_count,
            .neighbor_halo_cell_count = neighbor_halo_cell_count,
            .tiles = tiles,
            .owned_cell_offsets = owned_cell_offsets,
            .owned_cells_z_order = owned_cells_z_order,
            .owning_tile_index_by_cell = owning_tile_index_by_cell,
            .owned_cell_offset_within_tile_by_cell = owned_cell_offset_within_tile_by_cell,
            .neighbor_face_offsets = neighbor_face_offsets,
            .neighbor_faces_by_tile = neighbor_faces_by_tile,
        };
    }

    pub fn ownedCells(
        self: TilePlan,
        tile_index: usize,
    ) ![]const usize {
        if (tile_index >= self.tiles.len)
            return error.TileIndexOutOfRange;
        return self.owned_cells_z_order[self.owned_cell_offsets[tile_index]..self.owned_cell_offsets[tile_index + 1]];
    }

    /// Capability used to construct the one executor assigned to this serial
    /// plan. The stable allocation identity prevents tiles from another plan
    /// being submitted accidentally.
    pub fn ownedCellExecutorPlan(self: TilePlan) compute.OwnedCellPlan {
        return .{
            .identity = @ptrCast(self.owned_cell_offsets.ptr),
            .maximum_owned_cell_count = self.maximumOwnedCellCount(),
            .owned_cell_offsets = self.owned_cell_offsets,
            .owned_cells = self.owned_cells_z_order,
        };
    }

    /// Nominal owned interior for one active tile. Halo cells are absent by
    /// construction and the executor verifies the plan identity before work.
    pub fn ownedCellTile(
        self: TilePlan,
        tile_index: usize,
    ) !compute.OwnedCellTile {
        return .{
            .plan_identity = @ptrCast(self.owned_cell_offsets.ptr),
            .tile_index = tile_index,
            .cell_indices = try self.ownedCells(tile_index),
        };
    }

    /// Maximum number of independently executable grid cells in any one
    /// serial tile. This is the only safe upper bound for cell workers; tiles
    /// themselves remain ordered and serial.
    pub fn maximumOwnedCellCount(self: TilePlan) usize {
        var maximum: usize = 0;
        for (0..self.tiles.len) |tile_index| {
            maximum = @max(
                maximum,
                self.owned_cell_offsets[tile_index + 1] -
                    self.owned_cell_offsets[tile_index],
            );
        }
        return maximum;
    }

    pub fn owningTileIndex(self: TilePlan, cell: usize) !usize {
        if (cell >= self.owning_tile_index_by_cell.len)
            return error.GridCellIndexOutOfRange;
        return self.owning_tile_index_by_cell[cell];
    }

    pub fn ownedCellOffsetWithinTile(
        self: TilePlan,
        tile_index: usize,
        cell: usize,
    ) !usize {
        if (tile_index >= self.tiles.len)
            return error.TileIndexOutOfRange;
        if (cell >= self.owning_tile_index_by_cell.len)
            return error.GridCellIndexOutOfRange;
        if (self.owning_tile_index_by_cell[cell] != tile_index)
            return error.GridCellNotOwnedByTile;
        return self.owned_cell_offset_within_tile_by_cell[cell];
    }

    pub fn ownedNeighborFaces(
        self: TilePlan,
        tile_index: usize,
    ) ![]const NeighborFace {
        if (tile_index >= self.tiles.len)
            return error.TileIndexOutOfRange;
        return self.neighbor_faces_by_tile[self.neighbor_face_offsets[tile_index]..self.neighbor_face_offsets[tile_index + 1]];
    }

    pub fn tileOwnsCell(
        self: TilePlan,
        tile_index: usize,
        cell: usize,
    ) !bool {
        if (tile_index >= self.tiles.len)
            return error.TileIndexOutOfRange;
        return try self.owningTileIndex(cell) == tile_index;
    }

    pub fn tileLoadsCell(
        self: TilePlan,
        tile_index: usize,
        cell: usize,
    ) !bool {
        if (tile_index >= self.tiles.len)
            return error.TileIndexOutOfRange;
        if (cell >= self.owning_tile_index_by_cell.len)
            return error.GridCellIndexOutOfRange;
        const row = cell / self.lon_count;
        const column = cell % self.lon_count;
        const tile = self.tiles[tile_index];
        return row >= tile.loaded_north_row and
            row < tile.loaded_south_row_exclusive and
            column >= tile.loaded_west_column and
            column < tile.loaded_east_column_exclusive;
    }

    /// Assigns each cardinal neighbor face to exactly one tile using the
    /// endpoint with the lower cell-level Morton index. Both endpoints must
    /// be present in that tile's immutable loaded interior-plus-halo view.
    pub fn owningTileIndexForNeighborFace(
        self: TilePlan,
        first_cell: usize,
        second_cell: usize,
    ) !usize {
        if (first_cell >= self.owning_tile_index_by_cell.len or
            second_cell >= self.owning_tile_index_by_cell.len)
            return error.GridCellIndexOutOfRange;
        if (first_cell == second_cell)
            return error.InvalidNeighborFace;
        const first_row = first_cell / self.lon_count;
        const first_column = first_cell % self.lon_count;
        const second_row = second_cell / self.lon_count;
        const second_column = second_cell % self.lon_count;
        const row_distance = if (first_row > second_row)
            first_row - second_row
        else
            second_row - first_row;
        const column_distance = if (first_column > second_column)
            first_column - second_column
        else
            second_column - first_column;
        if (row_distance + column_distance != 1)
            return error.InvalidNeighborFace;
        const first_morton = mortonIndex(
            @intCast(first_row),
            @intCast(first_column),
        );
        const second_morton = mortonIndex(
            @intCast(second_row),
            @intCast(second_column),
        );
        const owner_cell = if (first_morton <= second_morton)
            first_cell
        else
            second_cell;
        const tile_index = try self.owningTileIndex(owner_cell);
        if (!try self.tileLoadsCell(tile_index, first_cell) or
            !try self.tileLoadsCell(tile_index, second_cell))
            return error.NeighborFaceOutsideTileHalo;
        return tile_index;
    }

    pub fn deinit(self: *TilePlan) void {
        self.allocator.free(self.neighbor_faces_by_tile);
        self.allocator.free(self.neighbor_face_offsets);
        self.allocator.free(self.owned_cell_offset_within_tile_by_cell);
        self.allocator.free(self.owning_tile_index_by_cell);
        self.allocator.free(self.owned_cells_z_order);
        self.allocator.free(self.owned_cell_offsets);
        self.allocator.free(self.tiles);
        self.* = undefined;
    }
};

fn mortonIndex(row: u32, column: u32) u64 {
    var result: u64 = 0;
    for (0..32) |bit| {
        result |= (@as(u64, (column >> @intCast(bit)) & 1) << @intCast(2 * bit));
        result |= (@as(u64, (row >> @intCast(bit)) & 1) << @intCast(2 * bit + 1));
    }
    return result;
}

fn neighborFaceOwnerIndex(
    lon_count: usize,
    owning_tile_index_by_cell: []const usize,
    first_cell: usize,
    second_cell: usize,
) usize {
    const first_row = first_cell / lon_count;
    const first_column = first_cell % lon_count;
    const second_row = second_cell / lon_count;
    const second_column = second_cell % lon_count;
    const first_morton = mortonIndex(
        @intCast(first_row),
        @intCast(first_column),
    );
    const second_morton = mortonIndex(
        @intCast(second_row),
        @intCast(second_column),
    );
    const owner_cell = if (first_morton <= second_morton)
        first_cell
    else
        second_cell;
    return owning_tile_index_by_cell[owner_cell];
}

const CurvatureRadii = struct {
    meridional_radius_m: f64,
    prime_vertical_radius_m: f64,
};

fn wgs84RadiiOfCurvature(latitude_degrees_north: f64) !CurvatureRadii {
    if (!std.math.isFinite(latitude_degrees_north) or
        latitude_degrees_north < -90 or latitude_degrees_north > 90)
        return error.InvalidLatitude;
    const semi_major_axis_m: f64 = 6_378_137.0;
    const inverse_flattening: f64 = 298.257223563;
    const flattening: f64 = 1.0 / inverse_flattening;
    const eccentricity_squared = flattening * (2 - flattening);
    const latitude_radians = latitude_degrees_north * std.math.pi / 180;
    const denominator = @sqrt(
        1 - eccentricity_squared * std.math.pow(f64, @sin(latitude_radians), 2),
    );
    return .{
        .prime_vertical_radius_m = semi_major_axis_m / denominator,
        .meridional_radius_m = semi_major_axis_m * (1 - eccentricity_squared) /
            std.math.pow(f64, denominator, 3),
    };
}

fn validateBounds(bounds: BoundsDegrees) !void {
    inline for (@typeInfo(BoundsDegrees).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(bounds, field.name)))
            return error.NonFiniteGeospatialGrid;
    }
    if (bounds.minimum_latitude_degrees_north < -90 or
        bounds.maximum_latitude_degrees_north > 90 or
        bounds.maximum_latitude_degrees_north <= bounds.minimum_latitude_degrees_north or
        bounds.minimum_longitude_degrees_east < -180 or
        bounds.maximum_longitude_degrees_east > 180 or
        bounds.maximum_longitude_degrees_east <= bounds.minimum_longitude_degrees_east or
        bounds.latitude_interval_degrees <= 0 or
        bounds.longitude_interval_degrees <= 0)
        return error.InvalidGeospatialGridBounds;
}

fn intervalCount(span_degrees: f64, interval_degrees: f64) !usize {
    const quotient = span_degrees / interval_degrees;
    const rounded = @round(quotient);
    if (!std.math.isFinite(quotient) or rounded < 1 or
        @abs(quotient - rounded) > 1.0e-10 * @max(1.0, @abs(quotient)))
        return error.GeospatialRangeNotDivisibleByInterval;
    if (rounded > @as(f64, @floatFromInt(std.math.maxInt(usize)))) {
        return error.GeospatialGridTooLarge;
    }
    return @intFromFloat(rounded);
}

test "WGS84 regular grid derives north-to-south rows and cell dimensions" {
    var grid = try RegularGrid.init(std.testing.allocator, .{
        .minimum_latitude_degrees_north = 50,
        .maximum_latitude_degrees_north = 52,
        .minimum_longitude_degrees_east = -114,
        .maximum_longitude_degrees_east = -111,
        .latitude_interval_degrees = 1,
        .longitude_interval_degrees = 1,
    });
    defer grid.deinit();
    try std.testing.expectEqual(@as(usize, 2), grid.row_count);
    try std.testing.expectEqual(@as(usize, 3), grid.column_count);
    try std.testing.expectEqual(@as(f64, 51.5), grid.latitude_degrees_north_by_cell[0]);
    try std.testing.expectEqual(@as(f64, -113.5), grid.longitude_degrees_east_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 50.5), grid.latitude_degrees_north_by_cell[3]);
    try std.testing.expect(grid.north_south_cell_width_m[0] > 110_000);
    try std.testing.expect(grid.east_west_cell_width_m[0] > 68_000);
    try std.testing.expect(
        grid.east_west_cell_width_m[3] > grid.east_west_cell_width_m[0],
    );
}

test "site coordinates identify their own cell rather than an exact center" {
    var grid = try RegularGrid.init(std.testing.allocator, .{
        .minimum_latitude_degrees_north = 50,
        .maximum_latitude_degrees_north = 52,
        .minimum_longitude_degrees_east = -114,
        .maximum_longitude_degrees_east = -112,
        .latitude_interval_degrees = 1,
        .longitude_interval_degrees = 1,
    });
    defer grid.deinit();
    // An off-center location inside the cell is accepted: users give a real
    // site position, not a grid index snapped to a cell center.
    try grid.validateSiteCoordinate(0, 51.5, -113.5);
    try grid.validateSiteCoordinate(0, 51.234567, -113.876543);
    // A location inside a different cell is rejected for this cell.
    try std.testing.expectError(
        error.SiteCoordinateDoesNotMatchGridCell,
        grid.validateSiteCoordinate(0, 50.5, -113.5),
    );
    // Outside the declared extent entirely.
    try std.testing.expectError(
        error.SiteCoordinateOutsideGeospatialGrid,
        grid.validateSiteCoordinate(0, 49.5, -113.5),
    );
}

test "cell index is derived from latitude and longitude, not a grid index" {
    var grid = try RegularGrid.init(std.testing.allocator, .{
        .minimum_latitude_degrees_north = 50,
        .maximum_latitude_degrees_north = 52,
        .minimum_longitude_degrees_east = -114,
        .maximum_longitude_degrees_east = -112,
        .latitude_interval_degrees = 1,
        .longitude_interval_degrees = 1,
    });
    defer grid.deinit();

    // Rows run north to south, columns west to east, so the northwest cell is
    // index 0 and the southeast cell is the last.
    try std.testing.expectEqual(
        @as(usize, 0),
        try grid.cellIndexForCoordinate(51.5, -113.5),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try grid.cellIndexForCoordinate(50.5, -113.5),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try grid.cellIndexForCoordinate(51.5, -112.5),
    );

    // A real site sits anywhere inside its cell, not only on the center.
    try std.testing.expectEqual(
        @as(usize, 0),
        try grid.cellIndexForCoordinate(51.000001, -113.999999),
    );
    try grid.validateSiteCoordinate(0, 51.000001, -113.999999);

    // Six-decimal precision is honoured: one microdegree across a cell
    // boundary selects the neighbouring cell rather than rounding back.
    try std.testing.expectEqual(
        @as(usize, 0),
        try grid.cellIndexForCoordinate(51.5, -113.000001),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try grid.cellIndexForCoordinate(51.5, -112.999999),
    );

    // Closed outer edges resolve into the boundary cells.
    try std.testing.expectEqual(
        @as(usize, 0),
        try grid.cellIndexForCoordinate(52, -114),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        try grid.cellIndexForCoordinate(50, -112),
    );

    // Outside the declared extent is an error, never a clamp.
    try std.testing.expectError(
        error.SiteCoordinateOutsideGeospatialGrid,
        grid.cellIndexForCoordinate(49.5, -113.5),
    );
    try std.testing.expectError(
        error.SiteCoordinateOutsideGeospatialGrid,
        grid.cellIndexForCoordinate(51.5, -111.5),
    );
    try std.testing.expectError(
        error.NonFiniteSiteCoordinate,
        grid.cellIndexForCoordinate(std.math.nan(f64), -113.5),
    );
}

test "tile plan owns every cell once and loads a two-cell halo" {
    var plan = try TilePlan.init(std.testing.allocator, 7, 9, 3, 4, 2);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 9), plan.tiles.len);
    try std.testing.expectEqual(@as(usize, 12), plan.maximumOwnedCellCount());
    const executor_plan = plan.ownedCellExecutorPlan();
    try std.testing.expectEqual(@as(usize, 12), executor_plan.maximum_owned_cell_count);
    const ownership = try std.testing.allocator.alloc(u8, 7 * 9);
    defer std.testing.allocator.free(ownership);
    @memset(ownership, 0);
    for (plan.tiles, 0..) |tile, tile_index| {
        const cached_cells = try plan.ownedCells(tile_index);
        const owned_tile = try plan.ownedCellTile(tile_index);
        try std.testing.expect(executor_plan.identity == owned_tile.plan_identity);
        try std.testing.expectEqualSlices(usize, cached_cells, owned_tile.cells());
        const rebuilt_cells = try tile.ownedCellIndicesZOrder(
            std.testing.allocator,
            7,
            9,
        );
        defer std.testing.allocator.free(rebuilt_cells);
        try std.testing.expectEqualSlices(
            usize,
            rebuilt_cells,
            cached_cells,
        );
        for (tile.owned_north_row..tile.owned_south_row_exclusive) |row| {
            for (tile.owned_west_column..tile.owned_east_column_exclusive) |column| {
                ownership[row * 9 + column] += 1;
            }
        }
        try std.testing.expect(tile.loaded_north_row <= tile.owned_north_row);
        try std.testing.expect(tile.loaded_west_column <= tile.owned_west_column);
        try std.testing.expect(tile.loaded_south_row_exclusive >= tile.owned_south_row_exclusive);
        try std.testing.expect(tile.loaded_east_column_exclusive >= tile.owned_east_column_exclusive);
    }
    for (1..plan.tiles.len) |index| {
        try std.testing.expect(
            plan.tiles[index - 1].z_order_index <= plan.tiles[index].z_order_index,
        );
    }
    for (ownership) |count| try std.testing.expectEqual(@as(u8, 1), count);
    var center: ?Tile = null;
    for (plan.tiles) |tile| {
        if (tile.owned_north_row == 3 and tile.owned_west_column == 4)
            center = tile;
    }
    const center_tile = center orelse return error.ExpectedCenterTile;
    try std.testing.expectEqual(@as(usize, 1), center_tile.loaded_north_row);
    try std.testing.expectEqual(@as(usize, 2), center_tile.loaded_west_column);
}

test "site connection mode gates each internal face conservatively" {
    const connected = [_]u8{ 1, 1, 1, 1 };
    try validateNeighborExchangeControls(2, 2, &connected);
    try std.testing.expect(try cellsExchangeMassAndEnergy(1, 1));
    try std.testing.expect(!try cellsExchangeMassAndEnergy(1, 3));
    try std.testing.expect(!try cellsExchangeMassAndEnergy(3, 1));
    try std.testing.expect(!try cellsExchangeMassAndEnergy(3, 3));
}

test "tile cell indices follow Morton order rather than row-major order" {
    const tile = Tile{
        .z_order_index = 0,
        .owned_north_row = 0,
        .owned_west_column = 0,
        .owned_south_row_exclusive = 3,
        .owned_east_column_exclusive = 3,
        .loaded_north_row = 0,
        .loaded_west_column = 0,
        .loaded_south_row_exclusive = 3,
        .loaded_east_column_exclusive = 3,
    };
    const indices = try tile.ownedCellIndicesZOrder(std.testing.allocator, 3, 3);
    defer std.testing.allocator.free(indices);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 1, 3, 4, 2, 5, 6, 7, 8 },
        indices,
    );
}

test "every lateral neighbor face has one Morton tile owner with immutable halo access" {
    const row_count: usize = 5;
    const column_count: usize = 7;
    var plan = try TilePlan.init(
        std.testing.allocator,
        row_count,
        column_count,
        2,
        3,
        2,
    );
    defer plan.deinit();

    var cached_face_count: usize = 0;
    for (plan.tiles, 0..) |_, tile_index| {
        const faces = try plan.ownedNeighborFaces(tile_index);
        cached_face_count += faces.len;
        for (faces) |face| {
            try std.testing.expectEqual(
                tile_index,
                try plan.owningTileIndexForNeighborFace(
                    face.first_cell,
                    face.second_cell,
                ),
            );
            try std.testing.expect(
                try plan.tileLoadsCell(tile_index, face.first_cell),
            );
            try std.testing.expect(
                try plan.tileLoadsCell(tile_index, face.second_cell),
            );
        }
    }
    var face_count: usize = 0;
    for (0..row_count) |row| {
        for (0..column_count) |column| {
            const first_cell = row * column_count + column;
            if (column + 1 < column_count) {
                const second_cell = first_cell + 1;
                const owner = try plan.owningTileIndexForNeighborFace(
                    first_cell,
                    second_cell,
                );
                try std.testing.expect(try plan.tileLoadsCell(owner, first_cell));
                try std.testing.expect(try plan.tileLoadsCell(owner, second_cell));
                face_count += 1;
            }
            if (row + 1 < row_count) {
                const second_cell = first_cell + column_count;
                const owner = try plan.owningTileIndexForNeighborFace(
                    first_cell,
                    second_cell,
                );
                try std.testing.expect(try plan.tileLoadsCell(owner, first_cell));
                try std.testing.expect(try plan.tileLoadsCell(owner, second_cell));
                face_count += 1;
            }
        }
    }
    try std.testing.expectEqual(
        row_count * (column_count - 1) +
            (row_count - 1) * column_count,
        face_count,
    );
    try std.testing.expectEqual(face_count, cached_face_count);
    try std.testing.expectError(
        error.InvalidNeighborFace,
        plan.owningTileIndexForNeighborFace(0, column_count + 1),
    );
}

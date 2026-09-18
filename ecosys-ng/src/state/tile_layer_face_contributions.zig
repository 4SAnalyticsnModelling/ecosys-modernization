const std = @import("std");
const spatial_grid = @import("spatial_grid.zig");
const lateral_store = @import("tile_lateral_contribution_store.zig");
const solute_transport = @import("../soil/solute/transport.zig");
const gas_transport = @import("../soil/gas/transport.zig");

pub const Face = struct {
    source_layer_cell: usize,
    destination_layer_cell: usize,
};

/// Runtime schedule that assigns every accepted soil-layer face to one
/// horizontal source tile while retaining complete vertical columns.
pub const FacePlan = struct {
    allocator: std.mem.Allocator,
    soil_layer_capacity: usize,
    face_offsets: []usize,
    face_indices_by_tile: []usize,

    pub fn init(
        allocator: std.mem.Allocator,
        tile_plan: spatial_grid.TilePlan,
        soil_layer_capacity: usize,
        faces: []const Face,
    ) !FacePlan {
        if (soil_layer_capacity == 0)
            return error.ZeroSoilLayerCapacity;
        const layer_cell_count = try std.math.mul(
            usize,
            tile_plan.lat_count * tile_plan.lon_count,
            soil_layer_capacity,
        );
        const face_offsets = try allocator.alloc(
            usize,
            tile_plan.tiles.len + 1,
        );
        errdefer allocator.free(face_offsets);
        @memset(face_offsets, 0);
        for (faces) |face| {
            const tile_index = try faceOwnerTile(
                tile_plan,
                soil_layer_capacity,
                layer_cell_count,
                face,
            );
            face_offsets[tile_index + 1] += 1;
        }
        for (1..face_offsets.len) |index|
            face_offsets[index] += face_offsets[index - 1];
        const face_indices_by_tile = try allocator.alloc(usize, faces.len);
        errdefer allocator.free(face_indices_by_tile);
        const next_by_tile = try allocator.dupe(
            usize,
            face_offsets[0..tile_plan.tiles.len],
        );
        defer allocator.free(next_by_tile);
        for (faces, 0..) |face, face_index| {
            const tile_index = try faceOwnerTile(
                tile_plan,
                soil_layer_capacity,
                layer_cell_count,
                face,
            );
            face_indices_by_tile[next_by_tile[tile_index]] = face_index;
            next_by_tile[tile_index] += 1;
        }
        return .{
            .allocator = allocator,
            .soil_layer_capacity = soil_layer_capacity,
            .face_offsets = face_offsets,
            .face_indices_by_tile = face_indices_by_tile,
        };
    }

    pub fn initTransportFaces(
        allocator: std.mem.Allocator,
        tile_plan: spatial_grid.TilePlan,
        soil_layer_capacity: usize,
        faces: []const solute_transport.Face,
    ) !FacePlan {
        const adapted = try allocator.alloc(Face, faces.len);
        defer allocator.free(adapted);
        for (faces, adapted) |source, *destination| {
            destination.* = .{
                .source_layer_cell = source.first_cell,
                .destination_layer_cell = source.second_cell,
            };
        }
        return init(
            allocator,
            tile_plan,
            soil_layer_capacity,
            adapted,
        );
    }

    pub fn initGasFaces(
        allocator: std.mem.Allocator,
        tile_plan: spatial_grid.TilePlan,
        soil_layer_capacity: usize,
        faces: []const gas_transport.Face,
    ) !FacePlan {
        const adapted = try allocator.alloc(Face, faces.len);
        defer allocator.free(adapted);
        for (faces, adapted) |source, *destination| {
            destination.* = .{
                .source_layer_cell = source.first_cell,
                .destination_layer_cell = source.second_cell,
            };
        }
        return init(
            allocator,
            tile_plan,
            soil_layer_capacity,
            adapted,
        );
    }

    pub fn deinit(self: *FacePlan) void {
        self.allocator.free(self.face_indices_by_tile);
        self.allocator.free(self.face_offsets);
        self.* = undefined;
    }

    pub fn ownedFaceIndices(
        self: FacePlan,
        tile_index: usize,
    ) ![]const usize {
        if (tile_index + 1 >= self.face_offsets.len)
            return error.TileIndexOutOfRange;
        return self.face_indices_by_tile[self.face_offsets[tile_index]..self.face_offsets[tile_index + 1]];
    }
};

/// Converts converged face fluxes into signed endpoint records. Flux is
/// positive from source to destination. Runtime components may represent
/// micropore water, macropore water, vapor, heat, gases, or arbitrary solutes.
pub fn appendOwnedTileContributions(
    allocator: std.mem.Allocator,
    tile_plan: spatial_grid.TilePlan,
    face_plan: FacePlan,
    tile_index: usize,
    faces: []const Face,
    carrier_count: usize,
    accepted_face_flux: []const f64,
    contributions: *std.ArrayList(lateral_store.Contribution),
) !void {
    if (carrier_count == 0 or
        accepted_face_flux.len != faces.len * carrier_count)
        return error.LayerFaceContributionDimensionMismatch;
    for (try face_plan.ownedFaceIndices(tile_index)) |face_index| {
        if (face_index >= faces.len)
            return error.LayerFaceIndexOutOfRange;
        const face = faces[face_index];
        try appendOneFace(
            allocator,
            tile_plan,
            face_plan,
            tile_index,
            face.source_layer_cell,
            face.destination_layer_cell,
            face_index,
            carrier_count,
            accepted_face_flux,
            contributions,
        );
    }
}

pub fn appendOwnedTransportFaceContributions(
    allocator: std.mem.Allocator,
    tile_plan: spatial_grid.TilePlan,
    face_plan: FacePlan,
    tile_index: usize,
    faces: []const solute_transport.Face,
    carrier_count: usize,
    accepted_face_flux: []const f64,
    contributions: *std.ArrayList(lateral_store.Contribution),
) !void {
    if (carrier_count == 0 or
        accepted_face_flux.len != faces.len * carrier_count)
        return error.LayerFaceContributionDimensionMismatch;
    for (try face_plan.ownedFaceIndices(tile_index)) |face_index| {
        if (face_index >= faces.len)
            return error.LayerFaceIndexOutOfRange;
        const face = faces[face_index];
        try appendOneFace(
            allocator,
            tile_plan,
            face_plan,
            tile_index,
            face.first_cell,
            face.second_cell,
            face_index,
            carrier_count,
            accepted_face_flux,
            contributions,
        );
    }
}

pub fn appendOwnedGasFaceContributions(
    allocator: std.mem.Allocator,
    tile_plan: spatial_grid.TilePlan,
    face_plan: FacePlan,
    tile_index: usize,
    faces: []const gas_transport.Face,
    accepted_face_flux_g: []const f64,
    contributions: *std.ArrayList(lateral_store.Contribution),
) !void {
    if (accepted_face_flux_g.len !=
        faces.len * gas_transport.species_count)
        return error.LayerFaceContributionDimensionMismatch;
    for (try face_plan.ownedFaceIndices(tile_index)) |face_index| {
        if (face_index >= faces.len)
            return error.LayerFaceIndexOutOfRange;
        const face = faces[face_index];
        try appendOneFace(
            allocator,
            tile_plan,
            face_plan,
            tile_index,
            face.first_cell,
            face.second_cell,
            face_index,
            gas_transport.species_count,
            accepted_face_flux_g,
            contributions,
        );
    }
}

pub const coupled_water_heat_carrier_count: usize = 4;
pub const micropore_water_carrier: usize = 0;
pub const macropore_water_carrier: usize = 1;
pub const water_vapor_carrier: usize = 2;
pub const heat_carrier: usize = 3;

/// Direct adapter for the four accepted arrays published by
/// `transport_hydrology.SoilFaces` after the coupled Richards/vapor/heat
/// Newton–Picard solves.
pub fn appendOwnedWaterHeatVaporContributions(
    allocator: std.mem.Allocator,
    tile_plan: spatial_grid.TilePlan,
    face_plan: FacePlan,
    tile_index: usize,
    faces: []const solute_transport.Face,
    micropore_water_flux_m3: []const f64,
    macropore_water_flux_m3: []const f64,
    water_vapor_flux_m3: []const f64,
    heat_flux_megajoules: []const f64,
    contributions: *std.ArrayList(lateral_store.Contribution),
) !void {
    inline for (.{
        micropore_water_flux_m3,
        macropore_water_flux_m3,
        water_vapor_flux_m3,
        heat_flux_megajoules,
    }) |values| if (values.len != faces.len)
        return error.LayerFaceContributionDimensionMismatch;
    for (try face_plan.ownedFaceIndices(tile_index)) |face_index| {
        if (face_index >= faces.len)
            return error.LayerFaceIndexOutOfRange;
        const face = faces[face_index];
        const source_horizontal =
            face.first_cell / face_plan.soil_layer_capacity;
        const destination_horizontal =
            face.second_cell / face_plan.soil_layer_capacity;
        if (!try tile_plan.tileOwnsCell(tile_index, source_horizontal) or
            !try tile_plan.tileLoadsCell(tile_index, destination_horizontal))
            return error.LayerFaceOutsideSourceTileHalo;
        const source_layer =
            face.first_cell % face_plan.soil_layer_capacity;
        const destination_layer =
            face.second_cell % face_plan.soil_layer_capacity;
        const fluxes = [_]f64{
            micropore_water_flux_m3[face_index],
            macropore_water_flux_m3[face_index],
            water_vapor_flux_m3[face_index],
            heat_flux_megajoules[face_index],
        };
        for (fluxes, 0..) |flux, carrier| {
            if (!std.math.isFinite(flux))
                return error.NonFiniteLayerFaceFlux;
            if (flux == 0) continue;
            try contributions.append(allocator, .{
                .target_cell = source_horizontal,
                .component = source_layer *
                    coupled_water_heat_carrier_count + carrier,
                .delta = -flux,
            });
            try contributions.append(allocator, .{
                .target_cell = destination_horizontal,
                .component = destination_layer *
                    coupled_water_heat_carrier_count + carrier,
                .delta = flux,
            });
        }
    }
}

fn appendOneFace(
    allocator: std.mem.Allocator,
    tile_plan: spatial_grid.TilePlan,
    face_plan: FacePlan,
    tile_index: usize,
    source_layer_cell: usize,
    destination_layer_cell: usize,
    face_index: usize,
    carrier_count: usize,
    accepted_face_flux: []const f64,
    contributions: *std.ArrayList(lateral_store.Contribution),
) !void {
    const source_horizontal =
        source_layer_cell / face_plan.soil_layer_capacity;
    const destination_horizontal =
        destination_layer_cell / face_plan.soil_layer_capacity;
    if (!try tile_plan.tileOwnsCell(tile_index, source_horizontal) or
        !try tile_plan.tileLoadsCell(tile_index, destination_horizontal))
        return error.LayerFaceOutsideSourceTileHalo;
    const source_layer =
        source_layer_cell % face_plan.soil_layer_capacity;
    const destination_layer =
        destination_layer_cell % face_plan.soil_layer_capacity;
    for (0..carrier_count) |carrier| {
        const flux = accepted_face_flux[face_index * carrier_count + carrier];
        if (!std.math.isFinite(flux))
            return error.NonFiniteLayerFaceFlux;
        if (flux == 0) continue;
        try contributions.append(allocator, .{
            .target_cell = source_horizontal,
            .component = source_layer * carrier_count + carrier,
            .delta = -flux,
        });
        try contributions.append(allocator, .{
            .target_cell = destination_horizontal,
            .component = destination_layer * carrier_count + carrier,
            .delta = flux,
        });
    }
}

fn faceOwnerTile(
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    layer_cell_count: usize,
    face: Face,
) !usize {
    if (face.source_layer_cell >= layer_cell_count or
        face.destination_layer_cell >= layer_cell_count or
        face.source_layer_cell == face.destination_layer_cell)
        return error.InvalidLayerFace;
    const source_horizontal =
        face.source_layer_cell / soil_layer_capacity;
    const destination_horizontal =
        face.destination_layer_cell / soil_layer_capacity;
    const source_layer = face.source_layer_cell % soil_layer_capacity;
    const destination_layer =
        face.destination_layer_cell % soil_layer_capacity;
    if (source_horizontal == destination_horizontal) {
        const distance = if (source_layer > destination_layer)
            source_layer - destination_layer
        else
            destination_layer - source_layer;
        if (distance != 1)
            return error.InvalidLayerFace;
    } else {
        if (source_layer != destination_layer)
            return error.InvalidLayerFace;
        const source_row =
            source_horizontal / tile_plan.lon_count;
        const source_column =
            source_horizontal % tile_plan.lon_count;
        const destination_row =
            destination_horizontal / tile_plan.lon_count;
        const destination_column =
            destination_horizontal % tile_plan.lon_count;
        const row_distance = if (source_row > destination_row)
            source_row - destination_row
        else
            destination_row - source_row;
        const column_distance = if (source_column > destination_column)
            source_column - destination_column
        else
            destination_column - source_column;
        if (row_distance + column_distance != 1)
            return error.InvalidLayerFace;
    }
    const tile_index = try tile_plan.owningTileIndex(source_horizontal);
    if (!try tile_plan.tileLoadsCell(tile_index, destination_horizontal))
        return error.LayerFaceOutsideSourceTileHalo;
    return tile_index;
}

test "accepted layered face fluxes round trip through two Morton passes" {
    const soil_layer_capacity: usize = 3;
    const carrier_count: usize = 4;
    var tile_plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        1,
        4,
        1,
        2,
        2,
    );
    defer tile_plan.deinit();
    const faces = [_]Face{
        .{ .source_layer_cell = 0, .destination_layer_cell = 1 },
        .{ .source_layer_cell = 1, .destination_layer_cell = 2 },
        .{ .source_layer_cell = 0, .destination_layer_cell = 3 },
        .{ .source_layer_cell = 4, .destination_layer_cell = 7 },
        .{ .source_layer_cell = 7, .destination_layer_cell = 10 },
    };
    var face_plan = try FacePlan.init(
        std.testing.allocator,
        tile_plan,
        soil_layer_capacity,
        &faces,
    );
    defer face_plan.deinit();
    var flux: [faces.len * carrier_count]f64 = undefined;
    for (&flux, 0..) |*value, index|
        value.* = @as(f64, @floatFromInt(index + 1)) * 1e-3;
    const transport_faces = [_]solute_transport.Face{
        .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 },
        .{ .first_cell = 1, .second_cell = 2, .water_flux_m3_per_step = 0 },
        .{ .first_cell = 0, .second_cell = 3, .water_flux_m3_per_step = 0 },
        .{ .first_cell = 4, .second_cell = 7, .water_flux_m3_per_step = 0 },
        .{ .first_cell = 7, .second_cell = 10, .water_flux_m3_per_step = 0 },
    };
    var direct_adapter_record_count: usize = 0;
    for (tile_plan.tiles, 0..) |_, tile_index| {
        var direct_contributions =
            std.ArrayList(lateral_store.Contribution).empty;
        defer direct_contributions.deinit(std.testing.allocator);
        try appendOwnedWaterHeatVaporContributions(
            std.testing.allocator,
            tile_plan,
            face_plan,
            tile_index,
            &transport_faces,
            flux[0 * faces.len ..][0..faces.len],
            flux[1 * faces.len ..][0..faces.len],
            flux[2 * faces.len ..][0..faces.len],
            flux[3 * faces.len ..][0..faces.len],
            &direct_contributions,
        );
        direct_adapter_record_count += direct_contributions.items.len;
    }
    try std.testing.expectEqual(
        faces.len * coupled_water_heat_carrier_count * 2,
        direct_adapter_record_count,
    );
    const gas_faces = [_]gas_transport.Face{
        .{ .first_cell = 0, .second_cell = 1 },
        .{ .first_cell = 1, .second_cell = 2 },
        .{ .first_cell = 0, .second_cell = 3 },
        .{ .first_cell = 4, .second_cell = 7 },
        .{ .first_cell = 7, .second_cell = 10 },
    };
    const accepted_gas_flux_g =
        [_]f64{0.01} ** (faces.len * gas_transport.species_count);
    var gas_adapter_record_count: usize = 0;
    for (tile_plan.tiles, 0..) |_, tile_index| {
        var gas_contributions =
            std.ArrayList(lateral_store.Contribution).empty;
        defer gas_contributions.deinit(std.testing.allocator);
        try appendOwnedGasFaceContributions(
            std.testing.allocator,
            tile_plan,
            face_plan,
            tile_index,
            &gas_faces,
            &accepted_gas_flux_g,
            &gas_contributions,
        );
        gas_adapter_record_count += gas_contributions.items.len;
    }
    try std.testing.expectEqual(
        faces.len * gas_transport.species_count * 2,
        gas_adapter_record_count,
    );

    const grid_component_count = soil_layer_capacity * carrier_count;
    var expected: [4 * grid_component_count]f64 = @splat(0);
    for (faces, 0..) |face, face_index| {
        const source_horizontal =
            face.source_layer_cell / soil_layer_capacity;
        const destination_horizontal =
            face.destination_layer_cell / soil_layer_capacity;
        const source_layer =
            face.source_layer_cell % soil_layer_capacity;
        const destination_layer =
            face.destination_layer_cell % soil_layer_capacity;
        for (0..carrier_count) |carrier| {
            const value = flux[face_index * carrier_count + carrier];
            expected[
                source_horizontal * grid_component_count +
                    source_layer * carrier_count + carrier
            ] -= value;
            expected[
                destination_horizontal * grid_component_count +
                    destination_layer * carrier_count + carrier
            ] += value;
        }
    }

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try lateral_store.FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        4096,
        90,
        91,
    );
    for (tile_plan.tiles, 0..) |_, tile_index| {
        var contributions =
            std.ArrayList(lateral_store.Contribution).empty;
        defer contributions.deinit(std.testing.allocator);
        try appendOwnedTileContributions(
            std.testing.allocator,
            tile_plan,
            face_plan,
            tile_index,
            &faces,
            carrier_count,
            &flux,
            &contributions,
        );
        try store.saveSourceTile(
            tile_plan,
            tile_index,
            grid_component_count,
            contributions.items,
        );
    }
    try store.publish(tile_plan);
    var gathered: [4 * grid_component_count]f64 = @splat(0);
    for (tile_plan.tiles, 0..) |_, tile_index|
        try store.gatherOwnedTile(
            tile_plan,
            tile_index,
            grid_component_count,
            &gathered,
        );
    try std.testing.expectEqualSlices(f64, &expected, &gathered);
    for (0..carrier_count) |carrier| {
        var total: f64 = 0;
        for (0..4) |cell| {
            for (0..soil_layer_capacity) |layer| {
                total += gathered[
                    cell * grid_component_count +
                        layer * carrier_count + carrier
                ];
            }
        }
        try std.testing.expectApproxEqAbs(@as(f64, 0), total, 1e-15);
    }
}

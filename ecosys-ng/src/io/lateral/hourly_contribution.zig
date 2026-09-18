const std = @import("std");
const spatial_grid = @import("../../state/spatial_grid.zig");
const lateral_store = @import("../../state/tile_lateral_contribution_store.zig");
const layered = @import("../../state/tile_layer_face_contributions.zig");
const solute_transport = @import("../../soil/solute/transport.zig");
const gas_transport = @import("../../soil/gas/transport.zig");

pub const Workspace = struct {
    io: std.Io,
    root: std.Io.Dir,
    water_heat_vapor: std.Io.Dir,
    micropore_solute: std.Io.Dir,
    macropore_solute: std.Io.Dir,
    gas: std.Io.Dir,

    pub fn init(
        io: std.Io,
        parent: std.Io.Dir,
        root_path: []const u8,
    ) !Workspace {
        if (!safeDirectoryName(root_path))
            return error.InvalidLateralWorkspaceDirectoryName;
        const root = try parent.createDirPathOpen(io, root_path, .{});
        errdefer root.close(io);
        const water_heat_vapor = try root.createDirPathOpen(
            io,
            "water-heat-vapor",
            .{},
        );
        errdefer water_heat_vapor.close(io);
        const micropore_solute = try root.createDirPathOpen(
            io,
            "micropore-solute",
            .{},
        );
        errdefer micropore_solute.close(io);
        const macropore_solute = try root.createDirPathOpen(
            io,
            "macropore-solute",
            .{},
        );
        errdefer macropore_solute.close(io);
        const gas = try root.createDirPathOpen(io, "gas", .{});
        errdefer gas.close(io);
        return .{
            .io = io,
            .root = root,
            .water_heat_vapor = water_heat_vapor,
            .micropore_solute = micropore_solute,
            .macropore_solute = macropore_solute,
            .gas = gas,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.gas.close(self.io);
        self.macropore_solute.close(self.io);
        self.micropore_solute.close(self.io);
        self.water_heat_vapor.close(self.io);
        self.root.close(self.io);
        self.* = undefined;
    }

    pub fn store(
        self: Workspace,
        allocator: std.mem.Allocator,
        directory: std.Io.Dir,
        buffer_byte_count: usize,
        source_generation_index: u64,
    ) !lateral_store.FileStore {
        return lateral_store.FileStore.init(
            allocator,
            self.io,
            directory,
            buffer_byte_count,
            source_generation_index,
            try std.math.add(u64, source_generation_index, 1),
        );
    }
};

fn safeDirectoryName(name: []const u8) bool {
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

/// Persists one complete accepted arbitrary-carrier face ledger. Source tiles
/// are written strictly in TilePlan Morton order and the manifest is published
/// only after every source file is durable.
pub fn publishTransportGeneration(
    allocator: std.mem.Allocator,
    store: lateral_store.FileStore,
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    faces: []const solute_transport.Face,
    carrier_count: usize,
    accepted_face_flux: []const f64,
) !void {
    var face_plan = try layered.FacePlan.initTransportFaces(
        allocator,
        tile_plan,
        soil_layer_capacity,
        faces,
    );
    defer face_plan.deinit();
    for (tile_plan.tiles, 0..) |_, tile_index| {
        var contributions =
            std.ArrayList(lateral_store.Contribution).empty;
        defer contributions.deinit(allocator);
        try layered.appendOwnedTransportFaceContributions(
            allocator,
            tile_plan,
            face_plan,
            tile_index,
            faces,
            carrier_count,
            accepted_face_flux,
            &contributions,
        );
        try store.saveSourceTile(
            tile_plan,
            tile_index,
            soil_layer_capacity * carrier_count,
            contributions.items,
        );
    }
    try store.publish(tile_plan);
}

/// Persists the exact accepted dynamically assembled soil-gas face ledger.
pub fn publishGasGeneration(
    allocator: std.mem.Allocator,
    store: lateral_store.FileStore,
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    faces: []const gas_transport.Face,
    accepted_face_flux_g: []const f64,
) !void {
    var face_plan = try layered.FacePlan.initGasFaces(
        allocator,
        tile_plan,
        soil_layer_capacity,
        faces,
    );
    defer face_plan.deinit();
    for (tile_plan.tiles, 0..) |_, tile_index| {
        var contributions =
            std.ArrayList(lateral_store.Contribution).empty;
        defer contributions.deinit(allocator);
        try layered.appendOwnedGasFaceContributions(
            allocator,
            tile_plan,
            face_plan,
            tile_index,
            faces,
            accepted_face_flux_g,
            &contributions,
        );
        try store.saveSourceTile(
            tile_plan,
            tile_index,
            soil_layer_capacity * gas_transport.species_count,
            contributions.items,
        );
    }
    try store.publish(tile_plan);
}

/// Persists accepted matrix water, macropore water, vapor, and heat ledgers
/// without coercing their units into a common physical quantity.
pub fn publishWaterHeatVaporGeneration(
    allocator: std.mem.Allocator,
    store: lateral_store.FileStore,
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    faces: []const solute_transport.Face,
    micropore_water_flux_m3: []const f64,
    macropore_water_flux_m3: []const f64,
    water_vapor_flux_m3: []const f64,
    heat_flux_megajoules: []const f64,
) !void {
    var face_plan = try layered.FacePlan.initTransportFaces(
        allocator,
        tile_plan,
        soil_layer_capacity,
        faces,
    );
    defer face_plan.deinit();
    for (tile_plan.tiles, 0..) |_, tile_index| {
        var contributions =
            std.ArrayList(lateral_store.Contribution).empty;
        defer contributions.deinit(allocator);
        try layered.appendOwnedWaterHeatVaporContributions(
            allocator,
            tile_plan,
            face_plan,
            tile_index,
            faces,
            micropore_water_flux_m3,
            macropore_water_flux_m3,
            water_vapor_flux_m3,
            heat_flux_megajoules,
            &contributions,
        );
        try store.saveSourceTile(
            tile_plan,
            tile_index,
            soil_layer_capacity *
                layered.coupled_water_heat_carrier_count,
            contributions.items,
        );
    }
    try store.publish(tile_plan);
}

/// Persists an already converged complete layer-cell delta. This supports
/// coupled processes whose accepted result includes internal faces, phase
/// exchange, and open boundaries and therefore cannot be reconstructed from
/// an internal-face ledger alone.
pub fn publishLayerCellDeltaGeneration(
    allocator: std.mem.Allocator,
    store: lateral_store.FileStore,
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    carrier_count: usize,
    delta_by_layer_cell_carrier: []const f64,
) !void {
    const horizontal_cell_count = try std.math.mul(
        usize,
        tile_plan.lat_count,
        tile_plan.lon_count,
    );
    const layer_cell_count = try std.math.mul(
        usize,
        horizontal_cell_count,
        soil_layer_capacity,
    );
    if (carrier_count == 0 or
        delta_by_layer_cell_carrier.len !=
            try std.math.mul(usize, layer_cell_count, carrier_count))
        return error.LayerCellDeltaDimensionMismatch;
    for (tile_plan.tiles, 0..) |_, tile_index| {
        var contributions =
            std.ArrayList(lateral_store.Contribution).empty;
        defer contributions.deinit(allocator);
        for (try tile_plan.ownedCells(tile_index)) |horizontal_cell| {
            for (0..soil_layer_capacity) |layer| {
                const layer_cell =
                    horizontal_cell * soil_layer_capacity + layer;
                for (0..carrier_count) |carrier| {
                    const delta = delta_by_layer_cell_carrier[
                        layer_cell * carrier_count + carrier
                    ];
                    if (!std.math.isFinite(delta))
                        return error.NonFiniteLayerCellDelta;
                    if (delta == 0) continue;
                    try contributions.append(allocator, .{
                        .target_cell = horizontal_cell,
                        .component = layer * carrier_count + carrier,
                        .delta = delta,
                    });
                }
            }
        }
        try store.saveSourceTile(
            tile_plan,
            tile_index,
            soil_layer_capacity * carrier_count,
            contributions.items,
        );
    }
    try store.publish(tile_plan);
}

pub fn gatherOwnedTileCompact(
    store: lateral_store.FileStore,
    tile_plan: spatial_grid.TilePlan,
    tile_index: usize,
    soil_layer_capacity: usize,
    carrier_count: usize,
    destination_delta: []f64,
) !void {
    const component_count = try std.math.mul(
        usize,
        soil_layer_capacity,
        carrier_count,
    );
    try store.gatherOwnedTileCompact(
        tile_plan,
        tile_index,
        component_count,
        destination_delta,
    );
}

/// Reads the complete published generation back through one compact active
/// tile buffer at a time and checks conservative closure for every carrier.
pub fn verifyGenerationConservation(
    allocator: std.mem.Allocator,
    store: lateral_store.FileStore,
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    carrier_count: usize,
) !void {
    if (soil_layer_capacity == 0 or carrier_count == 0)
        return error.InvalidLateralContributionComponentCount;
    const component_count = try std.math.mul(
        usize,
        soil_layer_capacity,
        carrier_count,
    );
    var maximum_owned_cells: usize = 0;
    for (tile_plan.tiles, 0..) |_, tile_index|
        maximum_owned_cells = @max(
            maximum_owned_cells,
            (try tile_plan.ownedCells(tile_index)).len,
        );
    const compact = try allocator.alloc(
        f64,
        try std.math.mul(usize, maximum_owned_cells, component_count),
    );
    defer allocator.free(compact);
    const sum = try allocator.alloc(f64, carrier_count);
    defer allocator.free(sum);
    const absolute_sum = try allocator.alloc(f64, carrier_count);
    defer allocator.free(absolute_sum);
    @memset(sum, 0);
    @memset(absolute_sum, 0);
    // Preflight every destination tile before changing authoritative state.
    // This retains atomic failure semantics without a landscape-sized buffer.
    for (tile_plan.tiles, 0..) |_, tile_index| {
        const owned_cells = try tile_plan.ownedCells(tile_index);
        const destination =
            compact[0 .. owned_cells.len * component_count];
        @memset(destination, 0);
        try gatherOwnedTileCompact(
            store,
            tile_plan,
            tile_index,
            soil_layer_capacity,
            carrier_count,
            destination,
        );
        for (0..owned_cells.len * soil_layer_capacity) |layer_cell| {
            for (0..carrier_count) |carrier| {
                const value =
                    destination[layer_cell * carrier_count + carrier];
                sum[carrier] += value;
                absolute_sum[carrier] += @abs(value);
                if (!std.math.isFinite(sum[carrier]) or
                    !std.math.isFinite(absolute_sum[carrier]))
                    return error.NonFiniteLateralContributionSum;
            }
        }
    }
    for (sum, absolute_sum) |net, magnitude| {
        const tolerance = 32 * std.math.floatEps(f64) * @max(1, magnitude);
        if (@abs(net) > tolerance)
            return error.NonConservativeLateralContributionGeneration;
    }
}

/// Verifies a complete one-tile transport generation without serializing it
/// through the out-of-core exchange store. A single tile owns both endpoints
/// of every valid face, so the persisted generation has no external consumer;
/// accumulating in face/source order reproduces the store's per-component
/// arithmetic while avoiding write/sync/rename/read latency.
pub fn verifySingleTileTransportGenerationInMemory(
    allocator: std.mem.Allocator,
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    faces: []const solute_transport.Face,
    carrier_count: usize,
    accepted_face_flux: []const f64,
) !void {
    if (tile_plan.tiles.len != 1)
        return error.SingleTileTransportVerificationRequiresOneTile;
    if (soil_layer_capacity == 0 or carrier_count == 0)
        return error.InvalidLateralContributionComponentCount;
    if (accepted_face_flux.len !=
        try std.math.mul(usize, faces.len, carrier_count))
        return error.LayerFaceContributionDimensionMismatch;

    var face_plan = try layered.FacePlan.initTransportFaces(
        allocator,
        tile_plan,
        soil_layer_capacity,
        faces,
    );
    defer face_plan.deinit();
    const face_indices = try face_plan.ownedFaceIndices(0);
    if (face_indices.len != faces.len)
        return error.SingleTileTransportFaceOwnershipMismatch;

    const horizontal_cell_count = try std.math.mul(
        usize,
        tile_plan.lat_count,
        tile_plan.lon_count,
    );
    const component_count = try std.math.mul(
        usize,
        soil_layer_capacity,
        carrier_count,
    );
    const compact = try allocator.alloc(
        f64,
        try std.math.mul(usize, horizontal_cell_count, component_count),
    );
    defer allocator.free(compact);
    @memset(compact, 0);
    for (face_indices) |face_index| {
        const face = faces[face_index];
        const source_horizontal = face.first_cell / soil_layer_capacity;
        const destination_horizontal = face.second_cell / soil_layer_capacity;
        const source_layer = face.first_cell % soil_layer_capacity;
        const destination_layer = face.second_cell % soil_layer_capacity;
        for (0..carrier_count) |carrier| {
            const flux = accepted_face_flux[face_index * carrier_count + carrier];
            if (!std.math.isFinite(flux))
                return error.NonFiniteLayerFaceFlux;
            if (flux == 0) continue;
            const source_component = source_horizontal * component_count +
                source_layer * carrier_count + carrier;
            const destination_component = destination_horizontal * component_count +
                destination_layer * carrier_count + carrier;
            compact[source_component] -= flux;
            compact[destination_component] += flux;
            if (!std.math.isFinite(compact[source_component]) or
                !std.math.isFinite(compact[destination_component]))
                return error.NonFiniteLateralContributionSum;
        }
    }

    var sum = try allocator.alloc(f64, carrier_count);
    defer allocator.free(sum);
    var absolute_sum = try allocator.alloc(f64, carrier_count);
    defer allocator.free(absolute_sum);
    @memset(sum, 0);
    @memset(absolute_sum, 0);
    for (try tile_plan.ownedCells(0)) |horizontal_cell| {
        for (0..soil_layer_capacity) |layer| {
            for (0..carrier_count) |carrier| {
                const value = compact[
                    horizontal_cell * component_count +
                        layer * carrier_count + carrier
                ];
                sum[carrier] += value;
                absolute_sum[carrier] += @abs(value);
                if (!std.math.isFinite(sum[carrier]) or
                    !std.math.isFinite(absolute_sum[carrier]))
                    return error.NonFiniteLateralContributionSum;
            }
        }
    }
    for (sum, absolute_sum) |net, magnitude| {
        const tolerance = 32 * std.math.floatEps(f64) * @max(1, magnitude);
        if (@abs(net) > tolerance)
            return error.NonConservativeLateralContributionGeneration;
    }
}

test "lateral workspace rejects unsafe runtime directory names before I/O" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    inline for (.{
        "",
        ".",
        "..",
        "../lateral",
        "subdir/lateral",
        "subdir\\lateral",
        " lateral",
        "lateral ",
        "lateral.",
        "lateral:1",
        "lateral|1",
        "lateral?1",
    }) |name| try std.testing.expectError(
        error.InvalidLateralWorkspaceDirectoryName,
        Workspace.init(std.testing.io, temporary.dir, name),
    );
}

test "lateral workspace accepts portable runtime directory names" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    inline for (.{ "lateral", "lateral-1", "lateral.1" }) |name| {
        var workspace = try Workspace.init(std.testing.io, temporary.dir, name);
        workspace.deinit();
    }
}

/// Applies a published arbitrary-carrier generation to authoritative
/// layer-cell state. Only one compact destination tile is allocated and
/// state_updateted at a time; complete vertical columns remain intact.
pub fn state_updateTransportGeneration(
    allocator: std.mem.Allocator,
    store: lateral_store.FileStore,
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    carrier_count: usize,
    amount_by_layer_cell_carrier: []f64,
) !void {
    try state_updateLayerCellGeneration(
        allocator,
        store,
        tile_plan,
        soil_layer_capacity,
        carrier_count,
        amount_by_layer_cell_carrier,
        true,
    );
}

/// Applies a complete finite state generation. Unlike transport inventories,
/// signed state carriers such as matric potential are permitted.
pub fn state_updateFiniteStateGeneration(
    allocator: std.mem.Allocator,
    store: lateral_store.FileStore,
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    carrier_count: usize,
    state_by_layer_cell_carrier: []f64,
) !void {
    try state_updateLayerCellGeneration(
        allocator,
        store,
        tile_plan,
        soil_layer_capacity,
        carrier_count,
        state_by_layer_cell_carrier,
        false,
    );
}

/// Applies one complete one-tile layer/cell delta directly in memory. The
/// out-of-core store is an exchange boundary between tiles; with one tile,
/// every published delta is read straight back by the same owner. This keeps
/// the same whole-domain preflight and source-order floating-point addition
/// while eliding only that redundant persistence round trip.
pub fn state_updateSingleTileFiniteStateDelta(
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    carrier_count: usize,
    delta_by_layer_cell_carrier: []const f64,
    state_by_layer_cell_carrier: []f64,
) !void {
    try state_updateSingleTileLayerCellDelta(
        tile_plan,
        soil_layer_capacity,
        carrier_count,
        delta_by_layer_cell_carrier,
        state_by_layer_cell_carrier,
        false,
    );
}

pub fn state_updateSingleTileTransportDelta(
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    carrier_count: usize,
    delta_by_layer_cell_carrier: []const f64,
    state_by_layer_cell_carrier: []f64,
) !void {
    try state_updateSingleTileLayerCellDelta(
        tile_plan,
        soil_layer_capacity,
        carrier_count,
        delta_by_layer_cell_carrier,
        state_by_layer_cell_carrier,
        true,
    );
}

fn state_updateSingleTileLayerCellDelta(
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    carrier_count: usize,
    delta_by_layer_cell_carrier: []const f64,
    state_by_layer_cell_carrier: []f64,
    require_nonnegative: bool,
) !void {
    if (tile_plan.tiles.len != 1)
        return error.SingleTileStateUpdateRequiresOneTile;
    const horizontal_cell_count = try std.math.mul(
        usize,
        tile_plan.lat_count,
        tile_plan.lon_count,
    );
    const layer_cell_count = try std.math.mul(
        usize,
        horizontal_cell_count,
        soil_layer_capacity,
    );
    const value_count = try std.math.mul(
        usize,
        layer_cell_count,
        carrier_count,
    );
    if (soil_layer_capacity == 0 or carrier_count == 0 or
        delta_by_layer_cell_carrier.len != value_count or
        state_by_layer_cell_carrier.len != value_count)
        return error.InvalidLateralContributionDestinationShape;
    const owned_cells = try tile_plan.ownedCells(0);
    if (owned_cells.len != horizontal_cell_count)
        return error.SingleTileStateUpdateOwnershipMismatch;

    for (owned_cells) |horizontal_cell| {
        for (0..soil_layer_capacity) |layer| {
            for (0..carrier_count) |carrier| {
                const component = (horizontal_cell * soil_layer_capacity + layer) *
                    carrier_count + carrier;
                const delta = delta_by_layer_cell_carrier[component];
                if (!std.math.isFinite(delta))
                    return error.NonFiniteLayerCellDelta;
                const next = state_by_layer_cell_carrier[component] + delta;
                if (!std.math.isFinite(next) or
                    (require_nonnegative and next < -1.0e-12))
                    return error.InvalidLateralContributionStateUpdate;
            }
        }
    }
    for (owned_cells) |horizontal_cell| {
        for (0..soil_layer_capacity) |layer| {
            for (0..carrier_count) |carrier| {
                const component = (horizontal_cell * soil_layer_capacity + layer) *
                    carrier_count + carrier;
                state_by_layer_cell_carrier[component] +=
                    delta_by_layer_cell_carrier[component];
                if (require_nonnegative and
                    state_by_layer_cell_carrier[component] < 0)
                    state_by_layer_cell_carrier[component] = 0;
            }
        }
    }
}

fn state_updateLayerCellGeneration(
    allocator: std.mem.Allocator,
    store: lateral_store.FileStore,
    tile_plan: spatial_grid.TilePlan,
    soil_layer_capacity: usize,
    carrier_count: usize,
    state_by_layer_cell_carrier: []f64,
    require_nonnegative: bool,
) !void {
    const horizontal_cell_count = try std.math.mul(
        usize,
        tile_plan.lat_count,
        tile_plan.lon_count,
    );
    const layer_cell_count = try std.math.mul(
        usize,
        horizontal_cell_count,
        soil_layer_capacity,
    );
    if (carrier_count == 0 or
        state_by_layer_cell_carrier.len !=
            try std.math.mul(usize, layer_cell_count, carrier_count))
        return error.InvalidLateralContributionDestinationShape;
    var maximum_owned_cells: usize = 0;
    for (tile_plan.tiles, 0..) |_, tile_index|
        maximum_owned_cells = @max(
            maximum_owned_cells,
            (try tile_plan.ownedCells(tile_index)).len,
        );
    const component_count = try std.math.mul(
        usize,
        soil_layer_capacity,
        carrier_count,
    );
    const compact = try allocator.alloc(
        f64,
        try std.math.mul(usize, maximum_owned_cells, component_count),
    );
    defer allocator.free(compact);
    for (tile_plan.tiles, 0..) |_, tile_index| {
        const owned_cells = try tile_plan.ownedCells(tile_index);
        const destination =
            compact[0 .. owned_cells.len * component_count];
        @memset(destination, 0);
        try gatherOwnedTileCompact(
            store,
            tile_plan,
            tile_index,
            soil_layer_capacity,
            carrier_count,
            destination,
        );
        // Validate the complete owned tile before mutating any of it.
        for (owned_cells, 0..) |horizontal_cell, local_cell| {
            for (0..soil_layer_capacity) |layer| {
                const global_layer_cell =
                    horizontal_cell * soil_layer_capacity + layer;
                for (0..carrier_count) |carrier| {
                    const global_component =
                        global_layer_cell * carrier_count + carrier;
                    const local_component =
                        (local_cell * soil_layer_capacity + layer) *
                        carrier_count +
                        carrier;
                    const next =
                        state_by_layer_cell_carrier[global_component] +
                        destination[local_component];
                    if (!std.math.isFinite(next) or
                        (require_nonnegative and next < -1.0e-12))
                        return error.InvalidLateralContributionStateUpdate;
                }
            }
        }
    }
    // Only a completely valid generation reaches the mutation pass.
    for (tile_plan.tiles, 0..) |_, tile_index| {
        const owned_cells = try tile_plan.ownedCells(tile_index);
        const destination =
            compact[0 .. owned_cells.len * component_count];
        @memset(destination, 0);
        try gatherOwnedTileCompact(
            store,
            tile_plan,
            tile_index,
            soil_layer_capacity,
            carrier_count,
            destination,
        );
        for (owned_cells, 0..) |horizontal_cell, local_cell| {
            for (0..soil_layer_capacity) |layer| {
                const global_layer_cell =
                    horizontal_cell * soil_layer_capacity + layer;
                for (0..carrier_count) |carrier| {
                    const global_component =
                        global_layer_cell * carrier_count + carrier;
                    const local_component =
                        (local_cell * soil_layer_capacity + layer) *
                        carrier_count +
                        carrier;
                    state_by_layer_cell_carrier[global_component] +=
                        destination[local_component];
                    if (require_nonnegative and
                        state_by_layer_cell_carrier[global_component] < 0)
                        state_by_layer_cell_carrier[global_component] = 0;
                }
            }
        }
    }
}

test "hourly accepted ledgers publish and gather by serial Morton tile" {
    const soil_layer_capacity: usize = 2;
    const carrier_count: usize = 3;
    var tile_plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        1,
        4,
        1,
        2,
        2,
    );
    defer tile_plan.deinit();
    const faces = [_]solute_transport.Face{
        .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 },
        .{ .first_cell = 0, .second_cell = 2, .water_flux_m3_per_step = 0 },
        .{ .first_cell = 2, .second_cell = 4, .water_flux_m3_per_step = 0 },
        .{ .first_cell = 4, .second_cell = 6, .water_flux_m3_per_step = 0 },
    };
    const flux = [_]f64{
        1,  2,  3,
        4,  5,  6,
        7,  8,  9,
        10, 11, 12,
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try lateral_store.FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        4096,
        30,
        31,
    );
    try publishTransportGeneration(
        std.testing.allocator,
        store,
        tile_plan,
        soil_layer_capacity,
        &faces,
        carrier_count,
        &flux,
    );
    var state_updateted_amount = [_]f64{100} **
        (4 * soil_layer_capacity * carrier_count);
    var expected_amount = state_updateted_amount;
    for (faces, 0..) |face, face_index| {
        for (0..carrier_count) |carrier| {
            const accepted = flux[face_index * carrier_count + carrier];
            expected_amount[
                face.first_cell * carrier_count + carrier
            ] -= accepted;
            expected_amount[
                face.second_cell * carrier_count + carrier
            ] += accepted;
        }
    }
    try state_updateTransportGeneration(
        std.testing.allocator,
        store,
        tile_plan,
        soil_layer_capacity,
        carrier_count,
        &state_updateted_amount,
    );
    try std.testing.expectEqualSlices(
        f64,
        &expected_amount,
        &state_updateted_amount,
    );

    var total_by_carrier = [_]f64{ 0, 0, 0 };
    for (tile_plan.tiles, 0..) |_, tile_index| {
        const owned_cells = try tile_plan.ownedCells(tile_index);
        const compact = try std.testing.allocator.alloc(
            f64,
            owned_cells.len * soil_layer_capacity * carrier_count,
        );
        defer std.testing.allocator.free(compact);
        @memset(compact, 0);
        try gatherOwnedTileCompact(
            store,
            tile_plan,
            tile_index,
            soil_layer_capacity,
            carrier_count,
            compact,
        );
        for (0..owned_cells.len * soil_layer_capacity) |layer_cell| {
            for (0..carrier_count) |carrier| {
                total_by_carrier[carrier] +=
                    compact[layer_cell * carrier_count + carrier];
            }
        }
    }
    for (total_by_carrier) |total|
        try std.testing.expectEqual(@as(f64, 0), total);

    const rejected_store = try lateral_store.FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        4096,
        32,
        33,
    );
    var rejected_delta = [_]f64{0} **
        (4 * soil_layer_capacity * carrier_count);
    rejected_delta[0] = 1;
    rejected_delta[
        3 * soil_layer_capacity * carrier_count
    ] = -1;
    try publishLayerCellDeltaGeneration(
        std.testing.allocator,
        rejected_store,
        tile_plan,
        soil_layer_capacity,
        carrier_count,
        &rejected_delta,
    );
    var unchanged = [_]f64{0} **
        (4 * soil_layer_capacity * carrier_count);
    try std.testing.expectError(
        error.InvalidLateralContributionStateUpdate,
        state_updateTransportGeneration(
            std.testing.allocator,
            rejected_store,
            tile_plan,
            soil_layer_capacity,
            carrier_count,
            &unchanged,
        ),
    );
    for (unchanged) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
}

test "single-tile finite delta fast path is bit-identical to file-backed state update" {
    const soil_layer_capacity: usize = 2;
    const carrier_count: usize = 3;
    var tile_plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        1,
        2,
        1,
        2,
        2,
    );
    defer tile_plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), tile_plan.tiles.len);

    var file_backed = [_]f64{
        1,  2,  3,
        4,  5,  6,
        7,  8,  9,
        10, 11, 12,
    };
    var in_memory = file_backed;
    const delta = [_]f64{
        0.25,  -0.5, 0,
        1.25,  0.5,  -0.25,
        -0.75, 2,    -1,
        0,     -1.5, 0.125,
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try lateral_store.FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        4096,
        70,
        71,
    );
    try publishLayerCellDeltaGeneration(
        std.testing.allocator,
        store,
        tile_plan,
        soil_layer_capacity,
        carrier_count,
        &delta,
    );
    try state_updateFiniteStateGeneration(
        std.testing.allocator,
        store,
        tile_plan,
        soil_layer_capacity,
        carrier_count,
        &file_backed,
    );
    try state_updateSingleTileFiniteStateDelta(
        tile_plan,
        soil_layer_capacity,
        carrier_count,
        &delta,
        &in_memory,
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(file_backed[0..]),
        std.mem.sliceAsBytes(in_memory[0..]),
    );
}

test "single-tile transport verification matches a file-backed conservative generation" {
    const soil_layer_capacity: usize = 2;
    const carrier_count: usize = 2;
    var tile_plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        1,
        2,
        1,
        2,
        2,
    );
    defer tile_plan.deinit();
    const faces = [_]solute_transport.Face{
        .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 },
        .{ .first_cell = 0, .second_cell = 2, .water_flux_m3_per_step = 0 },
        .{ .first_cell = 1, .second_cell = 3, .water_flux_m3_per_step = 0 },
    };
    const flux = [_]f64{
        0.125, -0.25,
        1.5,   0.75,
        -0.5,  2.25,
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try lateral_store.FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        4096,
        80,
        81,
    );
    try publishTransportGeneration(
        std.testing.allocator,
        store,
        tile_plan,
        soil_layer_capacity,
        &faces,
        carrier_count,
        &flux,
    );
    try verifyGenerationConservation(
        std.testing.allocator,
        store,
        tile_plan,
        soil_layer_capacity,
        carrier_count,
    );
    try verifySingleTileTransportGenerationInMemory(
        std.testing.allocator,
        tile_plan,
        soil_layer_capacity,
        &faces,
        carrier_count,
        &flux,
    );

    var nonfinite_flux = flux;
    nonfinite_flux[2] = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteLayerFaceFlux,
        verifySingleTileTransportGenerationInMemory(
            std.testing.allocator,
            tile_plan,
            soil_layer_capacity,
            &faces,
            carrier_count,
            &nonfinite_flux,
        ),
    );
}

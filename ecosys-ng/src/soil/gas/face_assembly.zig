const std = @import("std");
const gas = @import("transport.zig");
const hydrology_module = @import("../../transport/hydrology.zig");
const soil_geometry_module = @import("../water/face_geometry.zig");

pub const Dimensions = struct {
    columns: usize,
    rows: usize,
    layers: usize,

    pub fn cellCount(self: Dimensions) !usize {
        if (self.columns == 0 or self.rows == 0 or self.layers == 0) return error.ZeroGasGridDimension;
        return std.math.mul(usize, try std.math.mul(usize, self.columns, self.rows), self.layers);
    }

    pub fn index(self: Dimensions, column: usize, row: usize, layer: usize) !usize {
        if (column >= self.columns or row >= self.rows or layer >= self.layers) return error.GasGridIndexOutOfBounds;
        return (row * self.columns + column) * self.layers + layer;
    }
};

pub const Geometry = struct {
    /// One value per runtime 3-D cell.
    active: []const bool,
    air_filled_porosity_m3_per_m3: []const f64,
    total_porosity_m3_per_m3: []const f64,
    /// Cell-major, direction-major (+x,+y,+z) face areas and path lengths.
    positive_face_area_m2: []const f64,
    positive_face_path_length_m: []const f64,
    /// Cell-major gas diffusivities in free air (m2 per solve step).
    free_air_diffusivity_m2_per_step: []const f64,
    penman_tortuosity: f64,
    minimum_air_filled_porosity_m3_per_m3: f64,
};

pub const FaceSet = struct {
    allocator: std.mem.Allocator,
    faces: []gas.Face,
    /// Face-major seven-species conductance.
    conductance_m3_per_step: []f64,
    /// Index in the fixed micropore-face topology for each active gas face.
    /// This lets callers publish a stable, topology-indexed flux ledger even
    /// when water filling temporarily disables a gaseous face.
    source_face_indices: []usize,

    pub fn deinit(self: *FaceSet) void {
        self.allocator.free(self.source_face_indices);
        self.allocator.free(self.conductance_m3_per_step);
        self.allocator.free(self.faces);
        self.* = undefined;
    }
};

/// Builds each active +x/+y/+z face once. The resulting ordering is stable,
/// deterministic, and suitable for later checkerboard/color parallelization.
pub fn build(allocator: std.mem.Allocator, dimensions: Dimensions, geometry: Geometry) !FaceSet {
    const cell_count = try dimensions.cellCount();
    try validateGeometry(cell_count, geometry);
    var active_face_count: usize = 0;
    for (0..dimensions.rows) |row| for (0..dimensions.columns) |column| for (0..dimensions.layers) |layer| {
        const first = try dimensions.index(column, row, layer);
        if (!geometry.active[first] or geometry.air_filled_porosity_m3_per_m3[first] <= geometry.minimum_air_filled_porosity_m3_per_m3) continue;
        if (column + 1 < dimensions.columns and faceIsActive(geometry, try dimensions.index(column + 1, row, layer))) active_face_count = try std.math.add(usize, active_face_count, 1);
        if (row + 1 < dimensions.rows and faceIsActive(geometry, try dimensions.index(column, row + 1, layer))) active_face_count = try std.math.add(usize, active_face_count, 1);
        if (layer + 1 < dimensions.layers and faceIsActive(geometry, try dimensions.index(column, row, layer + 1))) active_face_count = try std.math.add(usize, active_face_count, 1);
    };
    const faces = try allocator.alloc(gas.Face, active_face_count);
    errdefer allocator.free(faces);
    const conductance = try allocator.alloc(f64, try std.math.mul(usize, active_face_count, gas.species_count));
    errdefer allocator.free(conductance);
    const source_face_indices = try allocator.alloc(usize, active_face_count);
    errdefer allocator.free(source_face_indices);

    var count: usize = 0;
    for (0..dimensions.rows) |row| for (0..dimensions.columns) |column| for (0..dimensions.layers) |layer| {
        const first = try dimensions.index(column, row, layer);
        if (!geometry.active[first]) continue;
        if (column + 1 < dimensions.columns) try appendFace(dimensions, geometry, first, try dimensions.index(column + 1, row, layer), 0, faces, conductance, &count);
        if (row + 1 < dimensions.rows) try appendFace(dimensions, geometry, first, try dimensions.index(column, row + 1, layer), 1, faces, conductance, &count);
        if (layer + 1 < dimensions.layers) try appendFace(dimensions, geometry, first, try dimensions.index(column, row, layer + 1), 2, faces, conductance, &count);
    };
    std.debug.assert(count == active_face_count);
    for (source_face_indices, 0..) |*source_face, index| source_face.* = index;
    return .{ .allocator = allocator, .faces = faces, .conductance_m3_per_step = conductance, .source_face_indices = source_face_indices };
}

/// Builds gas faces on the exact runtime soil topology and half-path geometry
/// already used by WATSUB. Unlike the generic regular-grid assembler, this
/// preserves unequal source/destination dimensions and inactive layer counts.
pub fn buildMapped(allocator: std.mem.Allocator, soil_faces: *const hydrology_module.SoilFaces, soil_geometry: *const soil_geometry_module.State, air_filled_porosity_m3_per_m3: []const f64, total_porosity_m3_per_m3: []const f64, free_air_diffusivity_m2_per_step: []const f64, penman_tortuosity: f64, minimum_air_filled_porosity_m3_per_m3: f64) !FaceSet {
    const cell_count = air_filled_porosity_m3_per_m3.len;
    if (total_porosity_m3_per_m3.len != cell_count or free_air_diffusivity_m2_per_step.len != try std.math.mul(usize, cell_count, gas.species_count) or soil_faces.active_by_layer.len != cell_count or soil_faces.active_by_face.len != soil_faces.micropore_faces.len or soil_faces.micropore_faces.len != soil_geometry.face_area_m2.len or soil_faces.micropore_faces.len != soil_geometry.source_path_length_m.len or soil_faces.micropore_faces.len != soil_geometry.destination_path_length_m.len) return error.GasGeometrySizeMismatch;
    if (!std.math.isFinite(penman_tortuosity) or penman_tortuosity < 0 or !std.math.isFinite(minimum_air_filled_porosity_m3_per_m3) or minimum_air_filled_porosity_m3_per_m3 < 0) return error.InvalidGasGeometry;
    var active_count: usize = 0;
    for (soil_faces.micropore_faces, soil_faces.active_by_face) |face, active| {
        if (!active) continue;
        if (face.first_cell < cell_count and face.second_cell < cell_count and air_filled_porosity_m3_per_m3[face.first_cell] > minimum_air_filled_porosity_m3_per_m3 and air_filled_porosity_m3_per_m3[face.second_cell] > minimum_air_filled_porosity_m3_per_m3) active_count += 1;
    }
    const faces = try allocator.alloc(gas.Face, active_count);
    errdefer allocator.free(faces);
    const conductance = try allocator.alloc(f64, try std.math.mul(usize, active_count, gas.species_count));
    errdefer allocator.free(conductance);
    const source_face_indices = try allocator.alloc(usize, active_count);
    errdefer allocator.free(source_face_indices);
    var output_face: usize = 0;
    for (soil_faces.micropore_faces, 0..) |face, source_face| {
        if (!soil_faces.active_by_face[source_face]) continue;
        if (face.first_cell >= cell_count or face.second_cell >= cell_count) return error.InvalidGasTransportFace;
        const first_air = air_filled_porosity_m3_per_m3[face.first_cell];
        const second_air = air_filled_porosity_m3_per_m3[face.second_cell];
        if (first_air <= minimum_air_filled_porosity_m3_per_m3 or second_air <= minimum_air_filled_porosity_m3_per_m3) continue;
        const area_m2 = soil_geometry.face_area_m2[source_face];
        const first_geometry = 2 * try gas.airFilledDiffusionGeometry(first_air, penman_tortuosity, total_porosity_m3_per_m3[face.first_cell], area_m2, soil_geometry.source_path_length_m[source_face]);
        const second_geometry = 2 * try gas.airFilledDiffusionGeometry(second_air, penman_tortuosity, total_porosity_m3_per_m3[face.second_cell], area_m2, soil_geometry.destination_path_length_m[source_face]);
        faces[output_face] = .{ .first_cell = face.first_cell, .second_cell = face.second_cell };
        source_face_indices[output_face] = source_face;
        for (0..gas.species_count) |species| {
            const first_half = first_geometry * free_air_diffusivity_m2_per_step[face.first_cell * gas.species_count + species];
            const second_half = second_geometry * free_air_diffusivity_m2_per_step[face.second_cell * gas.species_count + species];
            conductance[output_face * gas.species_count + species] = try gas.seriesConductance(first_half, second_half);
        }
        output_face += 1;
    }
    std.debug.assert(output_face == active_count);
    return .{ .allocator = allocator, .faces = faces, .conductance_m3_per_step = conductance, .source_face_indices = source_face_indices };
}

fn faceIsActive(geometry: Geometry, cell: usize) bool {
    return geometry.active[cell] and geometry.air_filled_porosity_m3_per_m3[cell] > geometry.minimum_air_filled_porosity_m3_per_m3;
}

fn appendFace(dimensions: Dimensions, geometry: Geometry, first: usize, second: usize, direction: usize, faces: []gas.Face, conductance: []f64, count: *usize) !void {
    _ = dimensions;
    if (!geometry.active[second]) return;
    if (geometry.air_filled_porosity_m3_per_m3[first] <= geometry.minimum_air_filled_porosity_m3_per_m3 or geometry.air_filled_porosity_m3_per_m3[second] <= geometry.minimum_air_filled_porosity_m3_per_m3) return;
    faces[count.*] = .{ .first_cell = first, .second_cell = second };
    // GRID-INV-007: one area for both half-conductances, and it must be the
    // overlap rather than either cell's own cross-section. `positive_face_area_m2`
    // is indexed by the *owning* cell, so reading `first` for both halves is
    // correct only on a uniform grid; `min` makes the face symmetric under
    // renumbering, matching `face_geometry.zig`. The two halves legitimately
    // keep their own path lengths, since those are each cell's half-distance.
    const shared_area_m2 = @min(geometry.positive_face_area_m2[first * 3 + direction], geometry.positive_face_area_m2[second * 3 + direction]);
    const first_geometry = 2 * try gas.airFilledDiffusionGeometry(geometry.air_filled_porosity_m3_per_m3[first], geometry.penman_tortuosity, geometry.total_porosity_m3_per_m3[first], shared_area_m2, geometry.positive_face_path_length_m[first * 3 + direction]);
    const second_geometry = 2 * try gas.airFilledDiffusionGeometry(geometry.air_filled_porosity_m3_per_m3[second], geometry.penman_tortuosity, geometry.total_porosity_m3_per_m3[second], shared_area_m2, geometry.positive_face_path_length_m[second * 3 + direction]);
    for (0..gas.species_count) |species| {
        const first_half = first_geometry * geometry.free_air_diffusivity_m2_per_step[first * gas.species_count + species];
        const second_half = second_geometry * geometry.free_air_diffusivity_m2_per_step[second * gas.species_count + species];
        conductance[count.* * gas.species_count + species] = try gas.seriesConductance(first_half, second_half);
    }
    count.* += 1;
}

fn validateGeometry(cell_count: usize, geometry: Geometry) !void {
    if (geometry.active.len != cell_count or geometry.air_filled_porosity_m3_per_m3.len != cell_count or geometry.total_porosity_m3_per_m3.len != cell_count or geometry.positive_face_area_m2.len != cell_count * 3 or geometry.positive_face_path_length_m.len != cell_count * 3 or geometry.free_air_diffusivity_m2_per_step.len != cell_count * gas.species_count) return error.GasGeometrySizeMismatch;
    if (!std.math.isFinite(geometry.penman_tortuosity) or geometry.penman_tortuosity < 0 or !std.math.isFinite(geometry.minimum_air_filled_porosity_m3_per_m3) or geometry.minimum_air_filled_porosity_m3_per_m3 < 0) return error.InvalidGasGeometry;
    for (geometry.air_filled_porosity_m3_per_m3, geometry.total_porosity_m3_per_m3) |air, total| if (!std.math.isFinite(air) or air < 0 or !std.math.isFinite(total) or total <= 0 or air > total) return error.InvalidGasGeometry;
    for (geometry.positive_face_area_m2) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidGasGeometry;
    for (geometry.positive_face_path_length_m) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidGasGeometry;
    for (geometry.free_air_diffusivity_m2_per_step) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidGasGeometry;
}

test "runtime 3-D assembly emits every active face once" {
    const dimensions = Dimensions{ .columns = 2, .rows = 2, .layers = 2 };
    const cells = try dimensions.cellCount();
    const active = [_]bool{true} ** 8;
    const air = [_]f64{0.25} ** 8;
    const porosity = [_]f64{0.5} ** 8;
    const areas = [_]f64{1} ** 24;
    const lengths = [_]f64{1} ** 24;
    const diffusivity = [_]f64{0.1} ** (8 * gas.species_count);
    var set = try build(std.testing.allocator, dimensions, .{ .active = &active, .air_filled_porosity_m3_per_m3 = &air, .total_porosity_m3_per_m3 = &porosity, .positive_face_area_m2 = &areas, .positive_face_path_length_m = &lengths, .free_air_diffusivity_m2_per_step = &diffusivity, .penman_tortuosity = 0.66, .minimum_air_filled_porosity_m3_per_m3 = 0.01 });
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 12), set.faces.len);
    try std.testing.expectEqual(12 * gas.species_count, set.conductance_m3_per_step.len);
    for (set.conductance_m3_per_step) |value| try std.testing.expect(value > 0);
    _ = cells;
}

test "inactive cells and dry cells remove faces" {
    const active = [_]bool{ true, false, true };
    const air = [_]f64{ 0.2, 0.2, 0.0 };
    const porosity = [_]f64{0.5} ** 3;
    const areas = [_]f64{1} ** 9;
    const lengths = [_]f64{1} ** 9;
    const diffusivity = [_]f64{0.1} ** (3 * gas.species_count);
    var set = try build(std.testing.allocator, .{ .columns = 3, .rows = 1, .layers = 1 }, .{ .active = &active, .air_filled_porosity_m3_per_m3 = &air, .total_porosity_m3_per_m3 = &porosity, .positive_face_area_m2 = &areas, .positive_face_path_length_m = &lengths, .free_air_diffusivity_m2_per_step = &diffusivity, .penman_tortuosity = 0.66, .minimum_air_filled_porosity_m3_per_m3 = 0.01 });
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 0), set.faces.len);
}

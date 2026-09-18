const std = @import("std");
const grid_module = @import("../../state/grid.zig");
const hydrology_module = @import("../../transport/hydrology.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    source_path_length_m: []f64,
    destination_path_length_m: []f64,
    face_area_m2: []f64,

    /// Reconstructs STARTS `DLYR`, `AREA`, and `DIST` geometry for the shared
    /// +x/+y/+z face topology.
    ///
    /// GRID-INV-006: the face area is the **overlap** of the two cells, not the
    /// source cell's own cross-section. Legacy `XDPTH(N,..)=AREA(N,N3,N2,N1)/DIST(..)`
    /// reads `AREA` from the first cell, which is only correct on a uniform grid
    /// where both cells present the same cross-section. Because
    /// `hydrology.zig:259-260` emits only `+x/+y/+z`, the source is always the
    /// lower-index cell, so a one-sided area makes the transmitted area a
    /// function of the **index numbering**: renumbering the grid changes the
    /// water balance while conservation still holds, because both cells agree on
    /// whatever area the face declares. Taking `min` of each factor makes the
    /// face symmetric and is exact on a uniform grid, so the acceptance deck is
    /// unaffected.
    pub fn initMapped(
        allocator: std.mem.Allocator,
        grid: *const grid_module.GridState,
        faces: *const hydrology_module.SoilFaces,
        layer_thickness_m: []const f64,
        horizontal_cell_width_m: []const f64,
        vertical_cell_width_m: []const f64,
    ) !State {
        const count = faces.micropore_faces.len;
        if (faces.macropore_faces.len != count or faces.direction_axis.len != count or
            faces.active_by_face.len != count or
            layer_thickness_m.len != grid.layer_count or
            horizontal_cell_width_m.len != grid.cell_count or
            vertical_cell_width_m.len != grid.cell_count)
            return error.SoilFaceGeometryDimensionMismatch;
        var result: State = undefined;
        result.allocator = allocator;
        result.source_path_length_m = try allocator.alloc(f64, count);
        errdefer allocator.free(result.source_path_length_m);
        result.destination_path_length_m = try allocator.alloc(f64, count);
        errdefer allocator.free(result.destination_path_length_m);
        result.face_area_m2 = try allocator.alloc(f64, count);
        errdefer allocator.free(result.face_area_m2);
        try result.refreshMapped(grid, faces, layer_thickness_m, horizontal_cell_width_m, vertical_cell_width_m);
        try result.validateFinite();
        return result;
    }

    /// Recomputes all DLYR-dependent face paths and areas without allocation.
    /// Validation is completed for the entire topology before cached values
    /// are changed, so it can participate in a wider atomic geometry state_update.
    pub fn refreshMapped(
        self: *State,
        grid: *const grid_module.GridState,
        faces: *const hydrology_module.SoilFaces,
        layer_thickness_m: []const f64,
        horizontal_cell_width_m: []const f64,
        vertical_cell_width_m: []const f64,
    ) !void {
        try self.validateMapped(grid, faces, layer_thickness_m, horizontal_cell_width_m, vertical_cell_width_m);
        for (faces.micropore_faces, faces.direction_axis, 0..) |face, axis, face_index| {
            if (!faces.active_by_face[face_index]) {
                // Fixed-capacity inactive slots retain finite, non-degenerate
                // scratch geometry. Every physical consumer is mask-gated;
                // these sentinels only keep zero-thickness dormant layers out
                // of divisions and global finite-state validation.
                self.source_path_length_m[face_index] = 1;
                self.destination_path_length_m[face_index] = 1;
                self.face_area_m2[face_index] = 1;
                continue;
            }
            const source = dimensions(grid, face.first_cell, layer_thickness_m, horizontal_cell_width_m, vertical_cell_width_m) catch unreachable;
            const destination = dimensions(grid, face.second_cell, layer_thickness_m, horizontal_cell_width_m, vertical_cell_width_m) catch unreachable;
            // Overlap of the two cross-sections; see the GRID-INV-006 note on
            // `initMapped`. Path lengths stay one-sided on purpose: they are
            // each cell's own half-distance and are already combined
            // symmetrically by the callers' distance-weighted harmonic mean.
            const shared_thickness_m = @min(source.layer_thickness_m, destination.layer_thickness_m);
            switch (axis) {
                0 => {
                    self.source_path_length_m[face_index] = source.x_width_m;
                    self.destination_path_length_m[face_index] = destination.x_width_m;
                    self.face_area_m2[face_index] = shared_thickness_m * @min(source.y_width_m, destination.y_width_m);
                },
                1 => {
                    self.source_path_length_m[face_index] = source.y_width_m;
                    self.destination_path_length_m[face_index] = destination.y_width_m;
                    self.face_area_m2[face_index] = shared_thickness_m * @min(source.x_width_m, destination.x_width_m);
                },
                2 => {
                    self.source_path_length_m[face_index] = source.layer_thickness_m;
                    self.destination_path_length_m[face_index] = destination.layer_thickness_m;
                    // A `+z` face joins two layers of one column, so both cells
                    // share the horizontal footprint and `min` is an identity
                    // here. Kept symmetric so the expression stays correct if a
                    // future topology ever stacks unequal footprints.
                    self.face_area_m2[face_index] = @min(source.x_width_m, destination.x_width_m) * @min(source.y_width_m, destination.y_width_m);
                },
                else => unreachable,
            }
        }
    }

    pub fn validateMapped(
        self: *const State,
        grid: *const grid_module.GridState,
        faces: *const hydrology_module.SoilFaces,
        layer_thickness_m: []const f64,
        horizontal_cell_width_m: []const f64,
        vertical_cell_width_m: []const f64,
    ) !void {
        const count = faces.micropore_faces.len;
        if (faces.macropore_faces.len != count or faces.direction_axis.len != count or
            faces.active_by_face.len != count or
            self.source_path_length_m.len != count or self.destination_path_length_m.len != count or
            self.face_area_m2.len != count or layer_thickness_m.len != grid.layer_count or
            horizontal_cell_width_m.len != grid.cell_count or
            vertical_cell_width_m.len != grid.cell_count)
            return error.SoilFaceGeometryDimensionMismatch;
        for (faces.micropore_faces, faces.direction_axis, faces.active_by_face) |face, axis, active| {
            if (face.first_cell >= grid.layer_count or face.second_cell >= grid.layer_count or axis > 2) return error.InvalidSoilFaceTopology;
            if (!active) continue;
            _ = try dimensions(grid, face.first_cell, layer_thickness_m, horizontal_cell_width_m, vertical_cell_width_m);
            _ = try dimensions(grid, face.second_cell, layer_thickness_m, horizontal_cell_width_m, vertical_cell_width_m);
        }
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.face_area_m2);
        self.allocator.free(self.destination_path_length_m);
        self.allocator.free(self.source_path_length_m);
        self.* = undefined;
    }

    pub fn validateFinite(self: *const State) !void {
        inline for (.{ self.source_path_length_m, self.destination_path_length_m, self.face_area_m2 }) |values| for (values) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilFaceGeometry;
    }
};

const Dimensions = struct { x_width_m: f64, y_width_m: f64, layer_thickness_m: f64 };

fn dimensions(grid: *const grid_module.GridState, layer_cell: usize, layer_thickness_m: []const f64, horizontal_cell_width_m: []const f64, vertical_cell_width_m: []const f64) !Dimensions {
    const horizontal_cell = layer_cell / grid.soil_layer_capacity;
    if (horizontal_cell >= grid.cell_count) return error.InvalidSoilFaceTopology;
    if (horizontal_cell_width_m.len != grid.cell_count or vertical_cell_width_m.len != grid.cell_count) return error.CellGeometryDimensionMismatch;
    const result: Dimensions = .{ .x_width_m = horizontal_cell_width_m[horizontal_cell], .y_width_m = vertical_cell_width_m[horizontal_cell], .layer_thickness_m = layer_thickness_m[layer_cell] };
    inline for (.{ result.x_width_m, result.y_width_m, result.layer_thickness_m }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilFaceGeometry;
    return result;
}

test "mapped faces reproduce STARTS overlap AREA and full DLYR paths" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    var snow = try @import("../solute/snow_solute_transport.zig").State.init(std.testing.allocator, 2, 1);
    defer snow.deinit();
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var geometry = try State.initMapped(std.testing.allocator, &grid, &faces, &.{ 0.1, 0.2, 0.1, 0.2 }, &.{ 3, 5 }, &.{ 4, 4 });
    defer geometry.deinit();
    // First face is +x from cell 0 layer 0: AREA(1)=DLYR(3)*DLYR(2).
    try std.testing.expectEqual(@as(f64, 3), geometry.source_path_length_m[0]);
    try std.testing.expectEqual(@as(f64, 5), geometry.destination_path_length_m[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), geometry.face_area_m2[0], 1e-15);
    // Second face is +z inside cell 0: AREA(3)=DLYR(1)*DLYR(2).
    try std.testing.expectEqual(@as(f64, 0.1), geometry.source_path_length_m[1]);
    try std.testing.expectEqual(@as(f64, 0.2), geometry.destination_path_length_m[1]);
    try std.testing.expectEqual(@as(f64, 12), geometry.face_area_m2[1]);
    const updated_thickness = [_]f64{ 0.3, 0.2, 0.1, 0.2 };
    try geometry.refreshMapped(&grid, &faces, &updated_thickness, &.{ 3, 5 }, &.{ 4, 4 });
    // GRID-INV-006: this assertion previously read 1.2, which is the SOURCE
    // cell's own cross-section 0.3*4. Cell 0 layer 0 is now 0.3 m thick while
    // cell 1 layer 0 stays 0.1 m, so the transmitting overlap is 0.1*4 = 0.4.
    // The old value was the defect written down as an expectation: it is the
    // area of a face that the destination cell cannot physically present.
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), geometry.face_area_m2[0], 1e-15);
    try std.testing.expectEqual(@as(f64, 0.3), geometry.source_path_length_m[1]);
}

test "DLYRM-inactive zero-thickness face keeps only finite sentinel geometry" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 2;
    var hydro = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydro.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydro, &grid);
    defer faces.deinit();
    faces.active_by_face[0] = false;
    faces.micropore_faces[0].active = false;
    faces.macropore_faces[0].active = false;
    var geometry = try State.initMapped(std.testing.allocator, &grid, &faces, &.{ 0, 0.2 }, &.{1}, &.{1});
    defer geometry.deinit();
    try std.testing.expectEqual(@as(f64, 1), geometry.source_path_length_m[0]);
    try std.testing.expectEqual(@as(f64, 1), geometry.destination_path_length_m[0]);
    try std.testing.expectEqual(@as(f64, 1), geometry.face_area_m2[0]);
}

fn buildTwoCellGeometry(
    thickness_m: []const f64,
    horizontal_width_m: []const f64,
    vertical_width_m: []const f64,
) !struct { grid: grid_module.GridState, hydrology: hydrology_module.State, faces: hydrology_module.SoilFaces, geometry: State } {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    errdefer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 2, 1);
    errdefer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    errdefer faces.deinit();
    const geometry = try State.initMapped(std.testing.allocator, &grid, &faces, thickness_m, horizontal_width_m, vertical_width_m);
    return .{ .grid = grid, .hydrology = hydrology, .faces = faces, .geometry = geometry };
}

test "GRID-INV-P1 lateral face area is invariant to perpendicular-width renumbering" {
    // The +x face's cross-section is thickness * y_width, so the factor to
    // permute here is the PERPENDICULAR (y) width, not the x width along the
    // flow: with y widths equal this test cannot fail and proves nothing. Since
    // `hydrology.buildSoilFaces` only emits +x/+y/+z, the source cell is always
    // the lower index, so the ONLY difference between these two setups is which
    // physical column got called "cell 0". A face area that depends on that is
    // a function of the numbering, not of the mesh.
    //
    // This is exactly the defect no balance audit can see: both cells agree on
    // whatever area the face declares, so every budget still closes.
    var forward = try buildTwoCellGeometry(&.{ 0.1, 0.2, 0.1, 0.2 }, &.{ 3, 5 }, &.{ 4, 6 });
    defer forward.grid.deinit();
    defer forward.hydrology.deinit();
    defer forward.faces.deinit();
    defer forward.geometry.deinit();
    var reversed = try buildTwoCellGeometry(&.{ 0.1, 0.2, 0.1, 0.2 }, &.{ 5, 3 }, &.{ 6, 4 });
    defer reversed.grid.deinit();
    defer reversed.hydrology.deinit();
    defer reversed.faces.deinit();
    defer reversed.geometry.deinit();
    // Face 0 is the +x face in both. Pre-fix: 0.1*4 = 0.4 forward against
    // 0.1*6 = 0.6 reversed, a 1.5x swing from renumbering alone.
    try std.testing.expectApproxEqRel(forward.geometry.face_area_m2[0], reversed.geometry.face_area_m2[0], 1e-15);
    // And it is the overlap: min(4,6) = 4.
    try std.testing.expectApproxEqRel(@as(f64, 0.1 * 4), forward.geometry.face_area_m2[0], 1e-15);
}

test "GRID-INV-P1 lateral face area is invariant to layer-thickness renumbering" {
    // Same mesh, unequal layer thicknesses across the +x face. Cell 0 layer 0 is
    // 0.1 m thick and cell 1 layer 0 is 0.3 m; the transmitting cross-section is
    // the 0.1 m overlap in both orderings. Pre-fix the source cell's own
    // thickness was used, so the two orderings reported 0.1*4 and 0.3*4, a 3x
    // difference produced purely by which column was indexed first.
    var forward = try buildTwoCellGeometry(&.{ 0.1, 0.2, 0.3, 0.2 }, &.{ 3, 3 }, &.{ 4, 4 });
    defer forward.grid.deinit();
    defer forward.hydrology.deinit();
    defer forward.faces.deinit();
    defer forward.geometry.deinit();
    var reversed = try buildTwoCellGeometry(&.{ 0.3, 0.2, 0.1, 0.2 }, &.{ 3, 3 }, &.{ 4, 4 });
    defer reversed.grid.deinit();
    defer reversed.hydrology.deinit();
    defer reversed.faces.deinit();
    defer reversed.geometry.deinit();
    try std.testing.expectApproxEqRel(forward.geometry.face_area_m2[0], reversed.geometry.face_area_m2[0], 1e-15);
    // And it is the overlap, not an average or either extreme: min(0.1,0.3)*4.
    try std.testing.expectApproxEqRel(@as(f64, 0.4), forward.geometry.face_area_m2[0], 1e-15);
}

test "GRID-INV-P2 uniform grids are unchanged by the overlap area" {
    // Regression guard: on a uniform mesh the overlap equals the source cell's
    // own cross-section, so this fix must be an exact no-op. The acceptance deck
    // is uniform, which is why its watermark cannot serve as evidence either way.
    var uniform = try buildTwoCellGeometry(&.{ 0.15, 0.15, 0.15, 0.15 }, &.{ 2, 2 }, &.{ 7, 7 });
    defer uniform.grid.deinit();
    defer uniform.hydrology.deinit();
    defer uniform.faces.deinit();
    defer uniform.geometry.deinit();
    // +x face: thickness * y_width.
    try std.testing.expectApproxEqRel(@as(f64, 0.15 * 7), uniform.geometry.face_area_m2[0], 1e-15);
    // +z face: x_width * y_width, untouched by this change.
    try std.testing.expectApproxEqRel(@as(f64, 2 * 7), uniform.geometry.face_area_m2[1], 1e-15);
}

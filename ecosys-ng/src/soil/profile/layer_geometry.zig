const std = @import("std");

pub const DisturbanceChanges = struct {
    pond_m: []const f64,
    freeze_thaw_m: []const f64,
    erosion_m: []const f64,
    organic_carbon_m: []const f64,
};

/// Runtime cell×layer geometry. Boundary arrays have `layer_capacity + 1`
/// entries per cell so the surface boundary is explicit instead of hidden at
/// Fortran layer index NU-1. All persistent and transaction work arrays live
/// on the heap.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    layer_capacity: usize,
    first_active_layer: []usize,
    active_layer_count: []usize,
    boundary_depth_m: []f64,
    boundary_depth_without_freeze_m: []f64,
    layer_thickness_m: []f64,
    layer_midpoint_depth_m: []f64,
    layer_bottom_depth_from_surface_m: []f64,
    layer_midpoint_depth_from_surface_m: []f64,
    staged_boundary_depth_m: []f64,
    staged_boundary_depth_without_freeze_m: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_capacity: usize) !State {
        if (cell_count == 0 or layer_capacity == 0) return error.InvalidSoilGeometryDimensions;
        const layer_count = try std.math.mul(usize, cell_count, layer_capacity);
        const boundary_count = try std.math.mul(usize, cell_count, try std.math.add(usize, layer_capacity, 1));
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        result.layer_capacity = layer_capacity;
        result.first_active_layer = try allocator.alloc(usize, cell_count);
        errdefer allocator.free(result.first_active_layer);
        result.active_layer_count = try allocator.alloc(usize, cell_count);
        errdefer allocator.free(result.active_layer_count);
        var f64_allocated: usize = 0;
        errdefer freeF64Allocated(&result, f64_allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            const length = if (std.mem.indexOf(u8, field.name, "boundary") != null) boundary_count else layer_count;
            @field(result, field.name) = try allocator.alloc(f64, length);
            @memset(@field(result, field.name), 0);
            f64_allocated += 1;
        };
        @memset(result.first_active_layer, 0);
        @memset(result.active_layer_count, layer_capacity);
        for (0..cell_count) |cell| {
            const boundary_base = cell * (layer_capacity + 1);
            const layer_base = cell * layer_capacity;
            for (0..layer_capacity + 1) |boundary| {
                const depth: f64 = @floatFromInt(boundary);
                result.boundary_depth_m[boundary_base + boundary] = depth;
                result.boundary_depth_without_freeze_m[boundary_base + boundary] = depth;
                result.staged_boundary_depth_m[boundary_base + boundary] = depth;
                result.staged_boundary_depth_without_freeze_m[boundary_base + boundary] = depth;
            }
            for (0..layer_capacity) |layer| {
                result.layer_thickness_m[layer_base + layer] = 1;
                result.layer_midpoint_depth_m[layer_base + layer] = @as(f64, @floatFromInt(layer)) + 0.5;
                result.layer_bottom_depth_from_surface_m[layer_base + layer] = @as(f64, @floatFromInt(layer)) + 1;
                result.layer_midpoint_depth_from_surface_m[layer_base + layer] = @as(f64, @floatFromInt(layer)) + 0.5;
            }
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.allocator.free(self.active_layer_count);
        self.allocator.free(self.first_active_layer);
        self.* = undefined;
    }

    pub fn boundaryIndex(self: State, cell: usize, boundary: usize) !usize {
        if (cell >= self.cell_count or boundary > self.layer_capacity) return error.SoilGeometryIndexOutOfBounds;
        return cell * (self.layer_capacity + 1) + boundary;
    }

    pub fn layerIndex(self: State, cell: usize, layer: usize) !usize {
        if (cell >= self.cell_count or layer >= self.layer_capacity) return error.SoilGeometryIndexOutOfBounds;
        return cell * self.layer_capacity + layer;
    }
};

/// Applies REDIST's four cumulative boundary-depth mechanisms as one atomic
/// transaction and recalculates DLYR, DPTH, CDPTHZ, and DPTHZ. Freeze-free
/// depth excludes only the freeze-thaw contribution.
pub fn applyDisturbances(state: *State, changes: DisturbanceChanges, minimum_layer_thickness_m: f64) !void {
    try validateDisturbances(state, changes, minimum_layer_thickness_m);
    const boundary_count = state.boundary_depth_m.len;
    for (0..boundary_count) |index| {
        const current = state.boundary_depth_m[index];
        const current_without_freeze = state.boundary_depth_without_freeze_m[index];
        const pond = changes.pond_m[index];
        const freeze = changes.freeze_thaw_m[index];
        const erosion = changes.erosion_m[index];
        const carbon = changes.organic_carbon_m[index];
        const values = [_]f64{ current, current_without_freeze, pond, freeze, erosion, carbon };
        for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilGeometry;
        state.staged_boundary_depth_m[index] = current + pond + freeze + erosion + carbon;
        state.staged_boundary_depth_without_freeze_m[index] = current_without_freeze + pond + erosion + carbon;
    }
    try validateAndCalculateDerived(state, minimum_layer_thickness_m);
    @memcpy(state.boundary_depth_m, state.staged_boundary_depth_m);
    @memcpy(state.boundary_depth_without_freeze_m, state.staged_boundary_depth_without_freeze_m);
}

/// Non-mutating preflight for joining geometry to a wider REDIST transaction.
pub fn validateDisturbances(state: *const State, changes: DisturbanceChanges, minimum_layer_thickness_m: f64) !void {
    const boundary_count = state.boundary_depth_m.len;
    if (changes.pond_m.len != boundary_count or changes.freeze_thaw_m.len != boundary_count or changes.erosion_m.len != boundary_count or changes.organic_carbon_m.len != boundary_count) return error.SoilGeometryDimensionMismatch;
    if (!std.math.isFinite(minimum_layer_thickness_m) or minimum_layer_thickness_m <= 0) return error.InvalidMinimumLayerThickness;
    for (0..boundary_count) |index| inline for (.{ state.boundary_depth_m[index], state.boundary_depth_without_freeze_m[index], changes.pond_m[index], changes.freeze_thaw_m[index], changes.erosion_m[index], changes.organic_carbon_m[index] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilGeometry;
    for (0..state.cell_count) |cell| {
        const first = state.first_active_layer[cell];
        const active_count = state.active_layer_count[cell];
        if (active_count == 0 or first + active_count > state.layer_capacity) return error.InvalidActiveSoilLayerRange;
        const base = cell * (state.layer_capacity + 1);
        for (first..first + active_count) |layer| {
            const top = state.boundary_depth_m[base + layer] + changes.pond_m[base + layer] + changes.freeze_thaw_m[base + layer] + changes.erosion_m[base + layer] + changes.organic_carbon_m[base + layer];
            const bottom = state.boundary_depth_m[base + layer + 1] + changes.pond_m[base + layer + 1] + changes.freeze_thaw_m[base + layer + 1] + changes.erosion_m[base + layer + 1] + changes.organic_carbon_m[base + layer + 1];
            const top_without_freeze = state.boundary_depth_without_freeze_m[base + layer] + changes.pond_m[base + layer] + changes.erosion_m[base + layer] + changes.organic_carbon_m[base + layer];
            const bottom_without_freeze = state.boundary_depth_without_freeze_m[base + layer + 1] + changes.pond_m[base + layer + 1] + changes.erosion_m[base + layer + 1] + changes.organic_carbon_m[base + layer + 1];
            if (!std.math.isFinite(top) or !std.math.isFinite(bottom) or bottom - top < minimum_layer_thickness_m or bottom_without_freeze - top_without_freeze < minimum_layer_thickness_m) return error.InvalidSoilLayerGeometry;
        }
    }
}

/// Initializes geometry from runtime layer thicknesses and an arbitrary
/// surface datum. This is also useful after checkpoint restoration.
pub fn initializeCell(state: *State, cell: usize, first_layer: usize, thickness_m: []const f64, surface_depth_m: f64, minimum_layer_thickness_m: f64) !void {
    if (cell >= state.cell_count or first_layer >= state.layer_capacity or thickness_m.len == 0 or first_layer + thickness_m.len > state.layer_capacity or !std.math.isFinite(surface_depth_m) or !std.math.isFinite(minimum_layer_thickness_m) or minimum_layer_thickness_m <= 0) return error.InvalidSoilGeometryInitialization;
    for (thickness_m) |thickness| if (!std.math.isFinite(thickness) or thickness < minimum_layer_thickness_m) return error.InvalidSoilLayerThickness;
    state.first_active_layer[cell] = first_layer;
    state.active_layer_count[cell] = thickness_m.len;
    var depth = surface_depth_m;
    const boundary_base = cell * (state.layer_capacity + 1);
    state.boundary_depth_m[boundary_base + first_layer] = depth;
    state.boundary_depth_without_freeze_m[boundary_base + first_layer] = depth;
    for (thickness_m, 0..) |thickness, offset| {
        depth += thickness;
        state.boundary_depth_m[boundary_base + first_layer + offset + 1] = depth;
        state.boundary_depth_without_freeze_m[boundary_base + first_layer + offset + 1] = depth;
    }
    @memcpy(state.staged_boundary_depth_m, state.boundary_depth_m);
    @memcpy(state.staged_boundary_depth_without_freeze_m, state.boundary_depth_without_freeze_m);
    try validateAndCalculateDerived(state, minimum_layer_thickness_m);
}

fn validateAndCalculateDerived(state: *State, minimum_layer_thickness_m: f64) !void {
    // Complete validation first; derived arrays remain untouched on failure.
    for (0..state.cell_count) |cell| {
        const first = state.first_active_layer[cell];
        const active_count = state.active_layer_count[cell];
        if (active_count == 0 or first + active_count > state.layer_capacity) return error.InvalidActiveSoilLayerRange;
        const boundary_base = cell * (state.layer_capacity + 1);
        for (first..first + active_count) |layer| {
            const top = state.staged_boundary_depth_m[boundary_base + layer];
            const bottom = state.staged_boundary_depth_m[boundary_base + layer + 1];
            const top_without_freeze = state.staged_boundary_depth_without_freeze_m[boundary_base + layer];
            const bottom_without_freeze = state.staged_boundary_depth_without_freeze_m[boundary_base + layer + 1];
            if (!std.math.isFinite(top) or !std.math.isFinite(bottom) or bottom - top < minimum_layer_thickness_m or bottom_without_freeze - top_without_freeze < minimum_layer_thickness_m) return error.InvalidSoilLayerGeometry;
        }
    }
    for (0..state.cell_count) |cell| {
        const first = state.first_active_layer[cell];
        const active_count = state.active_layer_count[cell];
        const boundary_base = cell * (state.layer_capacity + 1);
        const layer_base = cell * state.layer_capacity;
        const surface_depth = state.staged_boundary_depth_m[boundary_base + first];
        for (first..first + active_count) |layer| {
            const top = state.staged_boundary_depth_m[boundary_base + layer];
            const bottom = state.staged_boundary_depth_m[boundary_base + layer + 1];
            const index = layer_base + layer;
            state.layer_thickness_m[index] = bottom - top;
            state.layer_midpoint_depth_m[index] = 0.5 * (bottom + top);
            state.layer_bottom_depth_from_surface_m[index] = bottom - surface_depth;
            state.layer_midpoint_depth_from_surface_m[index] = 0.5 * (bottom + top) - surface_depth;
        }
    }
}

fn freeF64Allocated(state: *State, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        if (visited < count) state.allocator.free(@field(state, field.name));
        visited += 1;
    };
}

test "runtime layers recalculate REDIST thickness midpoint and surface-relative depth" {
    var state = try State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    try initializeCell(&state, 0, 0, &.{ 0.1, 0.2, 0.3 }, -0.02, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), state.layer_thickness_m[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), state.layer_bottom_depth_from_surface_m[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), state.layer_midpoint_depth_from_surface_m[1], 1e-14);
}

test "uniform erosion boundary shift changes datum but preserves layer thickness" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try initializeCell(&state, 0, 0, &.{ 0.1, 0.2 }, 0, 1e-6);
    const zero = [_]f64{ 0, 0, 0 };
    const erosion = [_]f64{ -0.01, -0.01, -0.01 };
    try applyDisturbances(&state, .{ .pond_m = &zero, .freeze_thaw_m = &zero, .erosion_m = &erosion, .organic_carbon_m = &zero }, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -0.01), state.boundary_depth_m[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.layer_thickness_m[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), state.layer_bottom_depth_from_surface_m[1], 1e-14);
}

test "invalid disturbance is transactional" {
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try initializeCell(&state, 0, 0, &.{0.1}, 0, 1e-6);
    const zero = [_]f64{ 0, 0 };
    const collapse = [_]f64{ 0, -0.2 };
    try std.testing.expectError(error.InvalidSoilLayerGeometry, applyDisturbances(&state, .{ .pond_m = &zero, .freeze_thaw_m = &zero, .erosion_m = &collapse, .organic_carbon_m = &zero }, 1e-6));
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.boundary_depth_m[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.layer_thickness_m[0], 1e-14);
}

test "geometry preflight is non-mutating" {
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try initializeCell(&state, 0, 0, &.{0.1}, 0, 1e-6);
    const zero = [_]f64{ 0, 0 };
    const collapse = [_]f64{ 0, -0.2 };
    try std.testing.expectError(error.InvalidSoilLayerGeometry, validateDisturbances(&state, .{ .pond_m = &zero, .freeze_thaw_m = &zero, .erosion_m = &collapse, .organic_carbon_m = &zero }, 1e-6));
    try std.testing.expectEqual(@as(f64, 0), state.staged_boundary_depth_m[0]);
    try std.testing.expectEqual(@as(f64, 0.1), state.staged_boundary_depth_m[1]);
    try std.testing.expectEqual(@as(f64, 0.1), state.layer_thickness_m[0]);
}

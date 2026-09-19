//! Atomic end-of-hour REDIST geometry transaction. Pond-domain geometry has a
//! separate accepted owner and is intentionally zero here; this transaction
//! combines freeze-thaw, erosion, and DORGE-adjusted SOC exactly once.
const std = @import("std");
const Geometry = @import("layer_geometry.zig");
const Assembly = @import("geometry_change_assembly.zig");

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    pond_boundary_change_m: []f64,
    freeze_thaw_boundary_change_m: []f64,
    erosion_boundary_change_m: []f64,
    organic_carbon_boundary_change_m: []f64,
    scratch_pond_boundary_change_m: []f64,
    scratch_freeze_thaw_boundary_change_m: []f64,
    scratch_erosion_boundary_change_m: []f64,
    scratch_organic_carbon_boundary_change_m: []f64,
    state: State,

    pub const State = enum {
        idle,
        staged,
        state_updateting,
        state_updateted,
    };

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_capacity: usize) !Workspace {
        if (cell_count == 0 or layer_capacity == 0) return error.InvalidSoilGeometryDisturbanceDimensions;
        const count = try std.math.mul(usize, cell_count, try std.math.add(usize, layer_capacity, 1));
        var result: Workspace = undefined;
        result.allocator = allocator;
        result.pond_boundary_change_m = try zeroes(allocator, count);
        errdefer allocator.free(result.pond_boundary_change_m);
        result.freeze_thaw_boundary_change_m = try zeroes(allocator, count);
        errdefer allocator.free(result.freeze_thaw_boundary_change_m);
        result.erosion_boundary_change_m = try zeroes(allocator, count);
        errdefer allocator.free(result.erosion_boundary_change_m);
        result.organic_carbon_boundary_change_m = try zeroes(allocator, count);
        errdefer allocator.free(result.organic_carbon_boundary_change_m);
        result.scratch_pond_boundary_change_m = try zeroes(allocator, count);
        errdefer allocator.free(result.scratch_pond_boundary_change_m);
        result.scratch_freeze_thaw_boundary_change_m = try zeroes(allocator, count);
        errdefer allocator.free(result.scratch_freeze_thaw_boundary_change_m);
        result.scratch_erosion_boundary_change_m = try zeroes(allocator, count);
        errdefer allocator.free(result.scratch_erosion_boundary_change_m);
        result.scratch_organic_carbon_boundary_change_m = try zeroes(allocator, count);
        result.state = .idle;
        return result;
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.scratch_organic_carbon_boundary_change_m);
        self.allocator.free(self.scratch_erosion_boundary_change_m);
        self.allocator.free(self.scratch_freeze_thaw_boundary_change_m);
        self.allocator.free(self.scratch_pond_boundary_change_m);
        self.allocator.free(self.organic_carbon_boundary_change_m);
        self.allocator.free(self.erosion_boundary_change_m);
        self.allocator.free(self.freeze_thaw_boundary_change_m);
        self.allocator.free(self.pond_boundary_change_m);
        self.* = undefined;
    }

    /// Starts the next end-of-hour transaction. A state_updateted transaction cannot
    /// be staged again until the hourly owner explicitly resets it.
    pub fn resetForNextHour(self: *Workspace) !void {
        if (self.state == .state_updateting) return error.SoilGeometryTransactionStateUpdateInProgress;
        @memset(self.pond_boundary_change_m, 0);
        @memset(self.freeze_thaw_boundary_change_m, 0);
        @memset(self.erosion_boundary_change_m, 0);
        @memset(self.organic_carbon_boundary_change_m, 0);
        self.state = .idle;
    }

    fn changes(self: *const Workspace) Geometry.DisturbanceChanges {
        return .{
            .pond_m = self.pond_boundary_change_m,
            .freeze_thaw_m = self.freeze_thaw_boundary_change_m,
            .erosion_m = self.erosion_boundary_change_m,
            .organic_carbon_m = self.organic_carbon_boundary_change_m,
        };
    }

    /// Consumes all four staged legs through exactly one state_update owner. The
    /// callback is `relayering.applyLayerRedistribution` in production. Keeping
    /// the once-only guard here makes a second whole-transaction state_update, or a
    /// re-entrant attempt to state_update one leg separately, fail before mutation.
    pub fn state_updateOnce(self: *Workspace, context: anytype, comptime state_update_fn: anytype) !void {
        switch (self.state) {
            .idle => return error.SoilGeometryTransactionNotStaged,
            .staged => self.state = .state_updateting,
            .state_updateting => return error.SoilGeometryTransactionStateUpdateInProgress,
            .state_updateted => return error.SoilGeometryTransactionAlreadyStateUpdateted,
        }
        errdefer self.state = .staged;
        try state_update_fn(context, self.changes());
        self.state = .state_updateted;
    }
};

pub const Inputs = struct {
    /// Per-cell legacy IERSNG mode: -1 disabled; 0 freeze-thaw; 1
    /// freeze-thaw+erosion; 2 freeze-thaw+SOC; 3 all three.
    disturbance_mode_by_cell: []const i32,
    total_ice_volume_change_m3: []const f64,
    soil_matrix_fraction: []const f64,
    net_sediment_megagrams_by_cell: []const f64,
    snow_deposited_sediment_megagrams_by_cell: []const f64,
    horizontal_area_m2_by_cell: []const f64,
    surface_soil_mass_megagrams_by_cell: []const f64,
    surface_soil_volume_m3_by_cell: []const f64,
    receiving_soil_bulk_density_megagrams_per_m3_by_cell: []const f64,
    /// Accepted biological SOC change after the legacy DORGE eroded-carbon
    /// cancellation. The `PR-GEOM-01B` tag formerly here claimed this
    /// producer was missing; independently re-verified 2026-09-19
    /// (audit/issues/issue-012-pr-geom-01b-soc-cancellation-unwired.md,
    /// closed `preserved`) and found stale: production performs the
    /// cancellation in `soil/organic/carbon_change.zig`'s
    /// `publishAcceptedHourlyChange`, using the erosion term published by
    /// `soil/profile/erosion_organic_bridge.zig`'s
    /// `publishLocalCarbonNetChangeMapped` (called from
    /// `stages/hourly_sediment.zig`), matching `redist.f:6871-6873` exactly.
    organic_carbon_change_after_erosion_cancellation_g_c: []const f64,
    macropore_fraction: []const f64,
    reference_bulk_density_megagrams_per_m3: []const f64,
    initial_layer_thickness_m: []const f64,
    current_layer_thickness_m: []const f64,
    reset_organic_accumulation_by_layer: []const bool,
    ice_to_water_specific_volume_difference: f64,
    organic_carbon_specific_volume_m3_per_g: f64,
    negligible_ice_volume_change_m3: f64,
    negligible_sediment_megagrams: f64,
    negligible_carbon_change_g_c: f64,
};

/// Stages every REDIST boundary driver without touching live geometry. Assembly
/// is atomic: the four public legs are published together only after every input
/// and every derived leg validates. The caller then uses `state_updateOnce`, normally
/// through `relayering.applyStagedGeometryTransaction`, so no individual leg is
/// exposed as a state_update operation.
pub fn stage(workspace: *Workspace, geometry: *const Geometry.State, inputs: Inputs) !void {
    const expected = geometry.cell_count * (geometry.layer_capacity + 1);
    if (workspace.state != .idle) return error.SoilGeometryTransactionAlreadyStaged;
    if (workspace.pond_boundary_change_m.len != expected or workspace.freeze_thaw_boundary_change_m.len != expected or workspace.erosion_boundary_change_m.len != expected or workspace.organic_carbon_boundary_change_m.len != expected or workspace.scratch_pond_boundary_change_m.len != expected or workspace.scratch_freeze_thaw_boundary_change_m.len != expected or workspace.scratch_erosion_boundary_change_m.len != expected or workspace.scratch_organic_carbon_boundary_change_m.len != expected or inputs.disturbance_mode_by_cell.len != geometry.cell_count) return error.SoilGeometryDisturbanceWorkspaceMismatch;
    for (inputs.disturbance_mode_by_cell) |mode|
        if (mode < -1 or mode > 3) return error.InvalidSoilGeometryDisturbanceMode;
    // Pond geometry was already accepted by surface_pond_domain_transaction.
    // Keeping an explicit zero leg prevents accidental double application.
    @memset(workspace.scratch_pond_boundary_change_m, 0);
    try Assembly.assembleFreezeThawBoundaryChangeM(workspace.scratch_freeze_thaw_boundary_change_m, geometry, inputs.total_ice_volume_change_m3, inputs.soil_matrix_fraction, inputs.horizontal_area_m2_by_cell, inputs.ice_to_water_specific_volume_difference, inputs.negligible_ice_volume_change_m3);
    try Assembly.assembleErosionBoundaryChangeM(workspace.scratch_erosion_boundary_change_m, geometry, inputs.net_sediment_megagrams_by_cell, inputs.snow_deposited_sediment_megagrams_by_cell, inputs.horizontal_area_m2_by_cell, inputs.surface_soil_mass_megagrams_by_cell, inputs.surface_soil_volume_m3_by_cell, inputs.receiving_soil_bulk_density_megagrams_per_m3_by_cell, true, inputs.negligible_sediment_megagrams);
    try Assembly.assembleOrganicCarbonBoundaryChangeM(workspace.scratch_organic_carbon_boundary_change_m, geometry, inputs.organic_carbon_change_after_erosion_cancellation_g_c, inputs.macropore_fraction, inputs.reference_bulk_density_megagrams_per_m3, inputs.initial_layer_thickness_m, inputs.current_layer_thickness_m, inputs.reset_organic_accumulation_by_layer, inputs.horizontal_area_m2_by_cell, inputs.organic_carbon_specific_volume_m3_per_g, true, inputs.negligible_carbon_change_g_c);
    const stride = geometry.layer_capacity + 1;
    for (inputs.disturbance_mode_by_cell, 0..) |mode, cell| {
        const start = cell * stride;
        const end = (cell + 1) * stride;
        if (mode == -1) @memset(workspace.scratch_freeze_thaw_boundary_change_m[start..end], 0);
        if (mode != 1 and mode != 3) @memset(workspace.scratch_erosion_boundary_change_m[start..end], 0);
        if (mode != 2 and mode != 3) @memset(workspace.scratch_organic_carbon_boundary_change_m[start..end], 0);
    }

    // Publish only after every leg has validated and assembled successfully.
    @memcpy(workspace.pond_boundary_change_m, workspace.scratch_pond_boundary_change_m);
    @memcpy(workspace.freeze_thaw_boundary_change_m, workspace.scratch_freeze_thaw_boundary_change_m);
    @memcpy(workspace.erosion_boundary_change_m, workspace.scratch_erosion_boundary_change_m);
    @memcpy(workspace.organic_carbon_boundary_change_m, workspace.scratch_organic_carbon_boundary_change_m);
    workspace.state = .staged;
}

fn zeroes(allocator: std.mem.Allocator, count: usize) ![]f64 {
    const values = try allocator.alloc(f64, count);
    @memset(values, 0);
    return values;
}

const TestStateUpdateContext = struct {
    geometry: *Geometry.State,
    minimum_layer_thickness_m: f64,
    state_update_count: usize = 0,

    fn state_update(self: *TestStateUpdateContext, changes: Geometry.DisturbanceChanges) !void {
        try Geometry.applyDisturbances(self.geometry, changes, self.minimum_layer_thickness_m);
        self.state_update_count += 1;
    }
};

const ReentrantLegStateUpdateContext = struct {
    transaction: *Workspace,
    geometry: *Geometry.State,
    mutation_count: usize = 0,

    fn state_updateErosionLegSeparately(self: *ReentrantLegStateUpdateContext, changes: Geometry.DisturbanceChanges) anyerror!void {
        const zero = [_]f64{0} ** 3;
        const erosion_only = Geometry.DisturbanceChanges{
            .pond_m = &zero,
            .freeze_thaw_m = &zero,
            .erosion_m = changes.erosion_m,
            .organic_carbon_m = &zero,
        };
        // The attempted nested transaction must be rejected while the outer
        // all-four state_update owns the workspace. The mutation below is therefore
        // unreachable and proves a leg cannot be state_updateted through this API.
        try self.transaction.state_updateOnce(self, state_updateErosionLegSeparately);
        try Geometry.applyDisturbances(self.geometry, erosion_only, 1e-9);
        self.mutation_count += 1;
    }
};

fn stageTestDrivers(
    workspace: *Workspace,
    geometry: *const Geometry.State,
    total_ice_volume_change_m3: []const f64,
    net_sediment_megagrams: f64,
    organic_carbon_change_after_erosion_cancellation_g_c: []const f64,
    disturbance_mode: i32,
) !void {
    try stage(workspace, geometry, .{
        .disturbance_mode_by_cell = &.{disturbance_mode},
        .total_ice_volume_change_m3 = total_ice_volume_change_m3,
        .soil_matrix_fraction = &.{ 1, 1 },
        .net_sediment_megagrams_by_cell = &.{net_sediment_megagrams},
        .snow_deposited_sediment_megagrams_by_cell = &.{0},
        .horizontal_area_m2_by_cell = &.{10},
        .surface_soil_mass_megagrams_by_cell = &.{20},
        .surface_soil_volume_m3_by_cell = &.{10},
        .receiving_soil_bulk_density_megagrams_per_m3_by_cell = &.{2},
        .organic_carbon_change_after_erosion_cancellation_g_c = organic_carbon_change_after_erosion_cancellation_g_c,
        .macropore_fraction = &.{ 0, 0 },
        .reference_bulk_density_megagrams_per_m3 = &.{ 1, 1 },
        .initial_layer_thickness_m = &.{ 0.2, 0.3 },
        .current_layer_thickness_m = &.{ 0.2, 0.3 },
        .reset_organic_accumulation_by_layer = &.{ false, true },
        .ice_to_water_specific_volume_difference = 0.1,
        .organic_carbon_specific_volume_m3_per_g = 1.0e-4,
        .negligible_ice_volume_change_m3 = 0,
        .negligible_sediment_megagrams = 0,
        .negligible_carbon_change_g_c = 0,
    });
}

test "GEOM-ASSEMBLE erosion-only stages a uniform datum shift without state_updateting" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.2, 0.3 }, 0, 1e-9);
    var workspace = try Workspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    const before = geometry.boundary_depth_m[0..3].*;
    try stageTestDrivers(&workspace, &geometry, &.{ 0, 0 }, 1, &.{ 0, 0 }, 3);
    try std.testing.expectEqualSlices(f64, &.{ 0.05, 0.05, 0.05 }, workspace.erosion_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.pond_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.freeze_thaw_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.organic_carbon_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &before, geometry.boundary_depth_m[0..3]);
}

test "GEOM-ASSEMBLE SOC-only follows cumulative DORGC reset semantics" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.2, 0.3 }, 0, 1e-9);
    var workspace = try Workspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    try stageTestDrivers(&workspace, &geometry, &.{ 0, 0 }, 0, &.{ 100, -50 }, 3);
    for ([_]f64{ 0.0005, -0.0005, 0 }, workspace.organic_carbon_boundary_change_m) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-15);
    }
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.pond_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.freeze_thaw_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.erosion_boundary_change_m);
}

test "GEOM-ASSEMBLE excludes independently accepted pond geometry" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    try stageTestDrivers(&workspace, &geometry, &.{ 0, 0 }, 0, &.{ 0, 0 }, 3);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.pond_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.freeze_thaw_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.erosion_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.organic_carbon_boundary_change_m);
}

test "GEOM-ASSEMBLE freeze-thaw-only accumulates upward from fixed bottom" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    try stageTestDrivers(&workspace, &geometry, &.{ 0.1, -0.05 }, 0, &.{ 0, 0 }, 3);
    for ([_]f64{ 0.0005, -0.0005, 0 }, workspace.freeze_thaw_boundary_change_m) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-15);
    }
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.pond_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.erosion_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, workspace.organic_carbon_boundary_change_m);
}

test "GEOM-ASSEMBLE three disturbance legs state_update their elementwise sum exactly once" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.2, 0.3 }, 0, 1e-9);
    var workspace = try Workspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    const before = geometry.boundary_depth_m[0..3].*;
    try stageTestDrivers(&workspace, &geometry, &.{ 0.1, -0.05 }, 1, &.{ 100, -50 }, 3);
    var context = TestStateUpdateContext{ .geometry = &geometry, .minimum_layer_thickness_m = 1e-9 };
    try workspace.state_updateOnce(&context, TestStateUpdateContext.state_update);
    const expected_change = [_]f64{ 0.051, 0.049, 0.05 };
    for (before, expected_change, geometry.boundary_depth_m[0..3]) |old, change, actual| {
        try std.testing.expectApproxEqAbs(old + change, actual, 1e-14);
    }
    try std.testing.expectEqual(@as(usize, 1), context.state_update_count);
    try std.testing.expectEqual(Workspace.State.state_updateted, workspace.state);
}

test "GEOM-ASSEMBLE duplicate state_update is falsified before a second mutation" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    try stageTestDrivers(&workspace, &geometry, &.{ 0.1, -0.05 }, 1, &.{ 100, -50 }, 3);
    var context = TestStateUpdateContext{ .geometry = &geometry, .minimum_layer_thickness_m = 1e-9 };
    try workspace.state_updateOnce(&context, TestStateUpdateContext.state_update);
    const after_first = geometry.boundary_depth_m[0..3].*;
    try std.testing.expectError(error.SoilGeometryTransactionAlreadyStateUpdateted, workspace.state_updateOnce(&context, TestStateUpdateContext.state_update));
    try std.testing.expectEqual(@as(usize, 1), context.state_update_count);
    try std.testing.expectEqualSlices(f64, &after_first, geometry.boundary_depth_m[0..3]);
}

test "GEOM-ASSEMBLE separate-leg reentrant state_update is falsified before mutation" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    try stageTestDrivers(&workspace, &geometry, &.{ 0.1, -0.05 }, 1, &.{ 100, -50 }, 3);
    const before = geometry.boundary_depth_m[0..3].*;
    var context = ReentrantLegStateUpdateContext{ .transaction = &workspace, .geometry = &geometry };
    try std.testing.expectError(
        error.SoilGeometryTransactionStateUpdateInProgress,
        workspace.state_updateOnce(&context, ReentrantLegStateUpdateContext.state_updateErosionLegSeparately),
    );
    try std.testing.expectEqual(@as(usize, 0), context.mutation_count);
    try std.testing.expectEqualSlices(f64, &before, geometry.boundary_depth_m[0..3]);
    try std.testing.expectEqual(Workspace.State.staged, workspace.state);
}

test "GEOM-ASSEMBLE failed four-leg staging leaves the prior transaction untouched" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    workspace.pond_boundary_change_m[0] = 7;
    workspace.freeze_thaw_boundary_change_m[0] = 8;
    workspace.erosion_boundary_change_m[0] = 9;
    workspace.organic_carbon_boundary_change_m[0] = 10;

    try std.testing.expectError(
        error.InvalidOrganicCarbonGeometryLayer,
        stageTestDrivers(&workspace, &geometry, &.{ 0.1, -0.05 }, 1, &.{ std.math.nan(f64), -50 }, 3),
    );
    try std.testing.expectEqualSlices(f64, &.{ 7, 0, 0 }, workspace.pond_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 8, 0, 0 }, workspace.freeze_thaw_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 9, 0, 0 }, workspace.erosion_boundary_change_m);
    try std.testing.expectEqualSlices(f64, &.{ 10, 0, 0 }, workspace.organic_carbon_boundary_change_m);
    try std.testing.expectEqual(Workspace.State.idle, workspace.state);
}

test "GEOM-ASSEMBLE honors IERSNG independently for every cell" {
    var geometry = try Geometry.State.init(std.testing.allocator, 4, 1);
    defer geometry.deinit();
    for (0..4) |cell|
        try Geometry.initializeCell(&geometry, cell, 0, &.{0.2}, 0, 1e-9);
    var workspace = try Workspace.init(std.testing.allocator, 4, 1);
    defer workspace.deinit();
    try stage(&workspace, &geometry, .{
        .disturbance_mode_by_cell = &.{ -1, 0, 1, 2 },
        .total_ice_volume_change_m3 = &.{ 0.1, 0.1, 0.1, 0.1 },
        .soil_matrix_fraction = &.{ 1, 1, 1, 1 },
        .net_sediment_megagrams_by_cell = &.{ 1, 1, 1, 1 },
        .snow_deposited_sediment_megagrams_by_cell = &.{ 0, 0, 0, 0 },
        .horizontal_area_m2_by_cell = &.{ 10, 10, 10, 10 },
        .surface_soil_mass_megagrams_by_cell = &.{ 20, 20, 20, 20 },
        .surface_soil_volume_m3_by_cell = &.{ 10, 10, 10, 10 },
        .receiving_soil_bulk_density_megagrams_per_m3_by_cell = &.{ 2, 2, 2, 2 },
        .organic_carbon_change_after_erosion_cancellation_g_c = &.{ 100, 100, 100, 100 },
        .macropore_fraction = &.{ 0, 0, 0, 0 },
        .reference_bulk_density_megagrams_per_m3 = &.{ 1, 1, 1, 1 },
        .initial_layer_thickness_m = &.{ 0.2, 0.2, 0.2, 0.2 },
        .current_layer_thickness_m = &.{ 0.2, 0.2, 0.2, 0.2 },
        .reset_organic_accumulation_by_layer = &.{ true, true, true, true },
        .ice_to_water_specific_volume_difference = 0.1,
        .organic_carbon_specific_volume_m3_per_g = 1.0e-4,
        .negligible_ice_volume_change_m3 = 0,
        .negligible_sediment_megagrams = 0,
        .negligible_carbon_change_g_c = 0,
    });
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, workspace.freeze_thaw_boundary_change_m[0..2]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001), workspace.freeze_thaw_boundary_change_m[2], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), workspace.freeze_thaw_boundary_change_m[3]);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, workspace.erosion_boundary_change_m[2..4]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), workspace.erosion_boundary_change_m[4], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), workspace.erosion_boundary_change_m[5], 1e-15);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, workspace.organic_carbon_boundary_change_m[4..6]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001), workspace.organic_carbon_boundary_change_m[6], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), workspace.organic_carbon_boundary_change_m[7]);
}

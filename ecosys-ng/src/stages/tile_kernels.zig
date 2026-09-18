//! Kernel drivers that keep spatial tiles serial and fan work only across
//! independent horizontal grid cells inside the active tile.
//!
//! Extracted verbatim from `ecosys_ng.zig` so the entry point holds only
//! `main`. Declaration bodies are unchanged.

const std = @import("std");
const ecosys = @import("ecosys_ng");
/// Dispatches cell-local science across either the resident domain or the
/// non-contiguous Morton-owned cells of one loaded tile. Complete vertical
/// columns remain indivisible worker units.
pub fn runScienceCellLayers(
    context: anytype,
    kernel_context: anytype,
    comptime kernel: anytype,
) !void {
    const tile = context.active_tile_cells.* orelse
        return error.MissingActiveScienceTile;
    try context.executor.runOwnedCellLayers(
        tile,
        context.grid.soil_layer_capacity,
        kernel_context,
        kernel,
    );
}

pub fn runScienceCells(
    context: anytype,
    kernel_context: anytype,
    comptime kernel: anytype,
) !void {
    const tile = context.active_tile_cells.* orelse
        return error.MissingActiveScienceTile;
    try context.executor.runOwnedCells(tile, kernel_context, kernel);
}

/// Preserves an hourly stage boundary while executing that stage across
/// serial Morton tiles. No owned-cell list is allocated here: TilePlan builds
/// and validates the lists once during runtime initialization.
pub fn runKernelAcrossSerialTiles(
    context: anytype,
    kernel_context: anytype,
    comptime kernel: anytype,
) !void {
    const plan = context.tile_plan;
    for (plan.tiles, 0..) |_, tile_index| {
        try context.executor.runOwnedCells(
            try plan.ownedCellTile(tile_index),
            kernel_context,
            kernel,
        );
    }
}

/// Worker-local-workspace counterpart of `runKernelAcrossSerialTiles`.
/// Tiles remain strictly serial; only the owned horizontal grid columns of
/// the active tile are partitioned among stable participant indices.
pub fn runIndexedKernelAcrossSerialTiles(
    context: anytype,
    kernel_context: anytype,
    comptime kernel: anytype,
) !void {
    const plan = context.tile_plan;
    for (plan.tiles, 0..) |_, tile_index| {
        try context.executor.runOwnedCellsIndexed(
            try plan.ownedCellTile(tile_index),
            kernel_context,
            kernel,
        );
    }
}

/// Initialization and refresh kernels obey the same execution boundary as the
/// hourly science: tiles advance serially, while owned cells within the active
/// tile may run concurrently.
pub fn runKernelAcrossSerialTilePlan(
    executor: ecosys.compute.CpuExecutor,
    plan: *const ecosys.spatial_grid.TilePlan,
    kernel_context: anytype,
    comptime kernel: anytype,
) !void {
    for (plan.tiles, 0..) |_, tile_index| {
        try executor.runOwnedCells(
            try plan.ownedCellTile(tile_index),
            kernel_context,
            kernel,
        );
    }
}

test "tile driver preserves serial plan order" {
    const Plan = struct {
        tiles: [3]u8 = .{ 0, 0, 0 },
        owned_cells: [6]usize = .{ 4, 1, 5, 0, 3, 2 },

        fn ownedCellTile(self: *const @This(), tile_index: usize) !ecosys.compute.OwnedCellTile {
            if (tile_index >= self.tiles.len) return error.TileIndexOutOfBounds;
            const first = tile_index * 2;
            return .{
                .plan_identity = @ptrCast(self),
                .tile_index = tile_index,
                .cell_indices = self.owned_cells[first..][0..2],
            };
        }
    };
    const KernelContext = struct {
        visits: [6]u8 = .{0} ** 6,

        fn apply(self: *@This(), cells: []const usize) !void {
            for (cells) |cell| {
                if (self.visits[cell] != 0) return error.CellVisitedMoreThanOnce;
                self.visits[cell] = 1;
            }
        }

        fn applyIndexed(self: *@This(), cells: []const usize, worker_index: usize) !void {
            if (worker_index != 0) return error.UnexpectedRecordingWorker;
            try self.apply(cells);
        }
    };
    const RecordingExecutor = struct {
        active: bool = false,
        order: [3]usize = undefined,
        count: usize = 0,

        fn runOwnedCells(
            self: *@This(),
            tile: ecosys.compute.OwnedCellTile,
            kernel_context: anytype,
            comptime kernel: anytype,
        ) !void {
            if (self.active) return error.TileDispatchOverlap;
            self.active = true;
            defer self.active = false;
            self.order[self.count] = tile.tile_index;
            self.count += 1;
            try kernel(kernel_context, tile.cells());
        }

        fn runOwnedCellsIndexed(
            self: *@This(),
            tile: ecosys.compute.OwnedCellTile,
            kernel_context: anytype,
            comptime kernel: anytype,
        ) !void {
            if (self.active) return error.TileDispatchOverlap;
            self.active = true;
            defer self.active = false;
            self.order[self.count] = tile.tile_index;
            self.count += 1;
            try kernel(kernel_context, tile.cells(), 0);
        }
    };
    const Context = struct {
        tile_plan: *const Plan,
        executor: *RecordingExecutor,
    };

    const plan = Plan{};
    var executor = RecordingExecutor{};
    var context = Context{ .tile_plan = &plan, .executor = &executor };
    var kernel_context = KernelContext{};
    try runKernelAcrossSerialTiles(
        &context,
        &kernel_context,
        KernelContext.apply,
    );
    try std.testing.expectEqual(@as(usize, 3), executor.count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &executor.order);
    const expected_visits = [_]u8{1} ** 6;
    try std.testing.expectEqualSlices(u8, &expected_visits, &kernel_context.visits);

    executor.count = 0;
    @memset(kernel_context.visits[0..], 0);
    try runIndexedKernelAcrossSerialTiles(
        &context,
        &kernel_context,
        KernelContext.applyIndexed,
    );
    try std.testing.expectEqual(@as(usize, 3), executor.count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &executor.order);
    try std.testing.expectEqualSlices(u8, &expected_visits, &kernel_context.visits);
}

test "serial tile driver stops before the next tile after an error" {
    const Plan = struct {
        tiles: [3]u8 = .{ 0, 0, 0 },
        owned_cells: [3]usize = .{ 0, 1, 2 },

        fn ownedCellTile(self: *const @This(), tile_index: usize) !ecosys.compute.OwnedCellTile {
            if (tile_index >= self.tiles.len) return error.TileIndexOutOfBounds;
            return .{
                .plan_identity = @ptrCast(self),
                .tile_index = tile_index,
                .cell_indices = self.owned_cells[tile_index..][0..1],
            };
        }
    };
    const RecordingExecutor = struct {
        order: [3]usize = undefined,
        count: usize = 0,

        fn runOwnedCells(
            self: *@This(),
            tile: ecosys.compute.OwnedCellTile,
            _: void,
            comptime _: anytype,
        ) !void {
            self.order[self.count] = tile.tile_index;
            self.count += 1;
            if (tile.tile_index == 1) return error.SyntheticTileFailure;
        }
    };
    const Context = struct {
        tile_plan: *const Plan,
        executor: *RecordingExecutor,
    };
    const Kernel = struct {
        fn unused(_: void, _: []const usize) !void {}
    };

    const plan = Plan{};
    var executor = RecordingExecutor{};
    var context = Context{ .tile_plan = &plan, .executor = &executor };
    try std.testing.expectError(
        error.SyntheticTileFailure,
        runKernelAcrossSerialTiles(&context, {}, Kernel.unused),
    );
    try std.testing.expectEqual(@as(usize, 2), executor.count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, executor.order[0..2]);
}

test "production threading stays inside canonical grid-column dispatch" {
    const compute_source = @embedFile("../core/compute.zig");
    const driver_source = @embedFile("../ecosys_ng.zig");
    const tile_source = @embedFile("tile_kernels.zig");
    const biogeochemistry_source = @embedFile("biogeochemistry_batches.zig");
    const run_support_source = @embedFile("run_support.zig");
    const diagnostic_control_source = @embedFile("../soil/solute/reaction_diagnostic_control.zig");

    // The only production-created threads belong to the persistent compute
    // pool. Other `std.Thread` uses are either yielding locks or test-only
    // isolation checks; they must not become an independent science executor.
    const first_compute_test = std.mem.indexOf(
        u8,
        compute_source,
        "\ntest \"pool backoff counter saturates in yield phase\"",
    ) orelse return error.MissingComputeTestBoundary;
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, compute_source[0..first_compute_test], "std.Thread.spawn("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, compute_source[first_compute_test..], "std.Thread.spawn("),
    );

    const first_run_support_test = std.mem.indexOf(
        u8,
        run_support_source,
        "\ntest \"log router preserves exact run-log and stderr bytes\"",
    ) orelse return error.MissingRunSupportTestBoundary;
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, run_support_source[0..first_run_support_test], "std.Thread.spawn("),
    );
    const first_diagnostic_test = std.mem.indexOf(
        u8,
        diagnostic_control_source,
        "\ntest \"solute diagnostics default enabled and nested suppression restores exactly\"",
    ) orelse return error.MissingDiagnosticControlTestBoundary;
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, diagnostic_control_source[0..first_diagnostic_test], "std.Thread.spawn("),
    );
    try std.testing.expect(std.mem.indexOf(u8, driver_source, "std.Thread.spawn(") == null);
    try std.testing.expect(std.mem.indexOf(u8, biogeochemistry_source, "std.Thread.spawn(") == null);

    // Tile traversal is a normal serial loop. Every production dispatch first
    // obtains the plan-owned capability; no raw slice or tile task is admitted.
    const tile_tests = std.mem.indexOf(
        u8,
        tile_source,
        "\ntest \"tile driver preserves serial plan order\"",
    ) orelse return error.MissingTileKernelTestBoundary;
    const tile_production = tile_source[0..tile_tests];
    try std.testing.expect(std.mem.indexOf(u8, tile_production, "std.Thread.spawn(") == null);
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, tile_production, "for (plan.tiles, 0..) |_, tile_index|"),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, tile_production, "try plan.ownedCellTile(tile_index)"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, tile_production, "runGridColumnsParallel("),
    );

    // Soil and surface biogeochemistry hold an active-tile capability while
    // their batches execute. Pin both exceptional orchestration loops here so
    // neither can be replaced by a tile task fan-out without failing tests.
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, biogeochemistry_source, "for (plan.tiles, 0..) |_, tile_index|"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(
            u8,
            biogeochemistry_source,
            "context.active_tile_cells.* = try plan.ownedCellTile(tile_index);",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, biogeochemistry_source, "defer context.active_tile_cells.* = null;"),
    );

    // Indexed canopy dispatch was moved into this serial tile driver. Main
    // owns the executor but cannot bypass the canonical tile capability.
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, driver_source, ".runOwnedCellsIndexed("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            driver_source,
            "const executor = try ecosys.compute.CpuExecutor.init(",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            tile_production,
            "context.executor.runOwnedCellsIndexed(\n            try plan.ownedCellTile(tile_index),",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            tile_production,
            "for (plan.tiles, 0..) |_, tile_index| {\n        try context.executor.runOwnedCellsIndexed(\n            try plan.ownedCellTile(tile_index),",
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, driver_source, ".runGridColumnsParallel(") == null);

    // Public production layer dispatch accepts only `OwnedCellTile`, then
    // routes to the adapter whose worker unit is one complete vertical column.
    try std.testing.expect(std.mem.indexOf(
        u8,
        compute_source,
        "pub fn runOwnedCellLayers(\n        self: CpuExecutor,\n        tile: OwnedCellTile,",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        compute_source,
        "try self.runIndexedCellLayers(\n            try self.validatedOwnedCells(tile),",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        compute_source,
        ".end = try std.math.add(\n                                usize,\n                                first_layer,\n                                adapter.layers_per_cell,",
    ) != null);
}

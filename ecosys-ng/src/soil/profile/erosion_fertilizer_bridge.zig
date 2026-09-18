const std = @import("std");
const inventory_module = @import("../../management/fertilizer_nitrogen_inventory.zig");
const fertilizer = @import("../nutrients/fertilizer_dissolution.zig");
const constituents = @import("../../erosion/eroded_constituents.zig");

pub const component_count: usize = @typeInfo(fertilizer.FertilizerState).@"struct".fields.len;

pub const Exported = struct {
    nitrogen_g_n: f64,
    ion_mol: f64,
};

pub fn route(
    columns: usize,
    rows: usize,
    surface_soil_mass_megagrams: []const f64,
    inventory: *inventory_module.State,
    sediment: constituents.DirectionalSediment,
    workspace: *constituents.PackedWorkspace,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    if (inventory.cell_count != cells or workspace.cell_count != cells or workspace.component_count != component_count) return error.FertilizerErosionDimensionMismatch;
    try packSurface(inventory, workspace.pools);
    try constituents.routePackedWorkspace(workspace, columns, rows, surface_soil_mass_megagrams, sediment);
    try unpackSurface(inventory, workspace.pools);
}

pub fn packSurface(inventory: *const inventory_module.State, output: []f64) !void {
    return packSurfaceMapped(inventory, &.{}, output);
}

pub fn packSurfaceMapped(inventory: *const inventory_module.State, top_layer_by_cell: []const usize, output: []f64) !void {
    if (output.len != try std.math.mul(usize, inventory.cell_count, component_count))
        return error.FertilizerErosionDimensionMismatch;
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != inventory.cell_count)
        return error.FertilizerErosionDimensionMismatch;
    for (0..inventory.cell_count) |cell| {
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        if (local >= inventory.layer_capacity) return error.FertilizerErosionDimensionMismatch;
        const top = cell * inventory.layer_capacity + local;
        inline for (@typeInfo(fertilizer.FertilizerState).@"struct".fields, 0..) |field, component| {
            const value = @field(inventory.soil[top], field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidFertilizerErosionState;
            output[cell * component_count + component] = value;
        }
    }
}

pub fn unpackSurface(inventory: *inventory_module.State, input: []const f64) !void {
    return unpackSurfaceMapped(inventory, &.{}, input);
}

pub fn unpackSurfaceMapped(inventory: *inventory_module.State, top_layer_by_cell: []const usize, input: []const f64) !void {
    if (input.len != try std.math.mul(usize, inventory.cell_count, component_count))
        return error.FertilizerErosionDimensionMismatch;
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != inventory.cell_count)
        return error.FertilizerErosionDimensionMismatch;
    for (input) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidFertilizerErosionCandidate;
    for (0..inventory.cell_count) |cell| {
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        const top = try inventory.index(cell, local);
        inline for (@typeInfo(fertilizer.FertilizerState).@"struct".fields, 0..) |field, component|
            @field(inventory.soil[top], field.name) = input[cell * component_count + component];
    }
}

/// REDIST `ZPE/SEF` fertilizer carried through external sediment faces.
pub noinline fn exported(
    workspace: *const constituents.PackedWorkspace,
    nitrogen_g_per_mol: f64,
) !Exported {
    if (workspace.component_count != component_count or
        workspace.exported.len !=
            try std.math.mul(usize, workspace.cell_count, component_count))
        return error.FertilizerErosionDimensionMismatch;
    if (!std.math.isFinite(nitrogen_g_per_mol) or nitrogen_g_per_mol <= 0)
        return error.InvalidFertilizerErosionMolarMass;
    var nitrogen_mol: f64 = 0;
    for (0..workspace.cell_count) |cell| {
        const first = cell * component_count;
        inline for (@typeInfo(fertilizer.FertilizerState).@"struct".fields, 0..) |_, component| {
            const amount = workspace.exported[first + component];
            if (!std.math.isFinite(amount) or amount < 0)
                return error.InvalidFertilizerErosionExport;
            nitrogen_mol += amount;
        }
    }
    const nitrogen_g_n = nitrogen_mol * nitrogen_g_per_mol;
    if (!std.math.isFinite(nitrogen_g_n))
        return error.FertilizerErosionExportOverflow;
    // Every FertilizerState field is mineral N (ammonium/ammonia/urea/nitrate,
    // broadcast and banded); ion_inventory_mol structurally excludes mineral N
    // (see subsurface_irrigation_chemistry.zig's documented convention), so
    // this export must never credit ion_mol -- doing so would double-book
    // nitrogen mass into two ledgers meant to stay disjoint.
    return .{ .nitrogen_g_n = nitrogen_g_n, .ion_mol = 0 };
}

test "broadcast and banded fertilizer amounts follow sediment faces" {
    var inventory = try inventory_module.State.init(std.testing.allocator, 2, 1);
    defer inventory.deinit();
    inventory.soil[0].broadcast_ammonium_mol_n = 10;
    inventory.soil[0].banded_nitrate_mol_n = 20;
    var workspace = try constituents.PackedWorkspace.init(std.testing.allocator, 2, component_count);
    defer workspace.deinit();
    try route(2, 1, &.{ 10, 10 }, &inventory, .{ .east_megagrams = &.{ 1, 0 }, .west_megagrams = &.{ 0, 0 }, .south_megagrams = &.{ 0, 0 }, .north_megagrams = &.{ 0, 0 } }, &workspace);
    try std.testing.expectApproxEqAbs(@as(f64, 9), inventory.soil[0].broadcast_ammonium_mol_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), inventory.soil[1].broadcast_ammonium_mol_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 18), inventory.soil[0].banded_nitrate_mol_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2), inventory.soil[1].banded_nitrate_mol_n, 1e-14);
}

test "external fertilizer sediment export retains REDIST N and ion stoichiometry" {
    var inventory = try inventory_module.State.init(std.testing.allocator, 1, 1);
    defer inventory.deinit();
    inventory.soil[0].broadcast_ammonium_mol_n = 10;
    inventory.soil[0].banded_nitrate_mol_n = 20;
    var workspace = try constituents.PackedWorkspace.init(
        std.testing.allocator,
        1,
        component_count,
    );
    defer workspace.deinit();
    try route(1, 1, &.{10}, &inventory, .{
        .east_megagrams = &.{1},
        .west_megagrams = &.{0},
        .south_megagrams = &.{0},
        .north_megagrams = &.{0},
    }, &workspace);
    const loss = try exported(&workspace, 14);
    try std.testing.expectApproxEqAbs(@as(f64, 42), loss.nitrogen_g_n, 1e-12);
    // Every FertilizerState field is mineral N, structurally excluded from
    // ion_inventory_mol -- this export must never credit ion_mol.
    try std.testing.expectApproxEqAbs(@as(f64, 0), loss.ion_mol, 1e-12);
}

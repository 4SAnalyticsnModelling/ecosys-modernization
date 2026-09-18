const std = @import("std");
const inventory_module = @import("../../management/mineral_fertilizer_inventory.zig");
const constituents = @import("../../erosion/eroded_constituents.zig");

/// Every dry extensive HOUR1 mineral-fertilizer owner that can still be
/// present in the surface soil when REDIST calculates `FSEDER * pool`.
pub const component_count: usize =
    @typeInfo(inventory_module.Inventory).@"struct".fields.len;

/// Element-resolved external-boundary loss.  The multipliers are identical to
/// `landscape_mass_inventory_phosphorus_ions.zig`'s
/// `pendingMineralIonAtoms`/`pendingMineralElements`, so transfer accounting
/// cannot use a different chemical formula from the storage census.
pub const Exported = struct {
    phosphorus_g_p: f64 = 0,
    inorganic_carbon_g_c: f64 = 0,
    ion_mol: f64 = 0,
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    silicon_mol: f64 = 0,
};

/// Routes the dry mineral-fertilizer inventory in each cell's first soil
/// layer.  Deeper inventories are not surface-sediment owners and remain
/// untouched.  `surface_soil_mass_megagrams` is only REDIST's transported
/// fraction denominator; each Inventory field remains an extensive mole pool.
pub fn route(
    columns: usize,
    rows: usize,
    surface_soil_mass_megagrams: []const f64,
    inventory: *inventory_module.State,
    sediment: constituents.DirectionalSediment,
    workspace: *constituents.PackedWorkspace,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    const soil_count = try std.math.mul(usize, cells, inventory.layer_capacity);
    if (cells == 0 or inventory.layer_capacity == 0 or
        inventory.cell_count != cells or inventory.soil.len != soil_count or
        inventory.surface.len != cells or workspace.cell_count != cells or
        workspace.component_count != component_count)
        return error.MineralFertilizerErosionDimensionMismatch;

    try packSurface(inventory, workspace.pools);

    try constituents.routePackedWorkspace(
        workspace,
        columns,
        rows,
        surface_soil_mass_megagrams,
        sediment,
    );
    try unpackSurface(inventory, workspace.pools);
}

/// Packs the first-soil-layer dry inventory in stable cell-major, Inventory
/// declaration order.  Suspended-particulate owners use this same layout so a
/// pool cannot silently change chemical identity across local detachment,
/// directional transport, deposition, or checkpoint restore.
pub fn packSurface(
    inventory: *const inventory_module.State,
    output: []f64,
) !void {
    return packSurfaceMapped(inventory, &.{}, output);
}

pub fn packSurfaceMapped(
    inventory: *const inventory_module.State,
    top_layer_by_cell: []const usize,
    output: []f64,
) !void {
    const expected = try std.math.mul(
        usize,
        inventory.cell_count,
        component_count,
    );
    if (inventory.cell_count == 0 or inventory.layer_capacity == 0 or
        inventory.soil.len != try std.math.mul(
            usize,
            inventory.cell_count,
            inventory.layer_capacity,
        ) or output.len != expected)
        return error.MineralFertilizerErosionDimensionMismatch;
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != inventory.cell_count)
        return error.MineralFertilizerErosionDimensionMismatch;
    for (0..inventory.cell_count) |cell| {
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        if (local >= inventory.layer_capacity) return error.MineralFertilizerErosionDimensionMismatch;
        const top = cell * inventory.layer_capacity + local;
        inline for (@typeInfo(inventory_module.Inventory).@"struct".fields, 0..) |field, component| {
            const value = @field(inventory.soil[top], field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidMineralFertilizerErosionState;
            output[cell * component_count + component] = value;
        }
    }
}

/// Replaces only the first-soil-layer inventory from the stable packed layout.
/// The complete candidate is validated before any live owner is mutated.
pub fn unpackSurface(
    inventory: *inventory_module.State,
    input: []const f64,
) !void {
    return unpackSurfaceMapped(inventory, &.{}, input);
}

pub fn unpackSurfaceMapped(
    inventory: *inventory_module.State,
    top_layer_by_cell: []const usize,
    input: []const f64,
) !void {
    const expected = try std.math.mul(
        usize,
        inventory.cell_count,
        component_count,
    );
    if (inventory.cell_count == 0 or inventory.layer_capacity == 0 or
        inventory.soil.len != try std.math.mul(
            usize,
            inventory.cell_count,
            inventory.layer_capacity,
        ) or input.len != expected)
        return error.MineralFertilizerErosionDimensionMismatch;
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != inventory.cell_count)
        return error.MineralFertilizerErosionDimensionMismatch;
    for (input) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidMineralFertilizerErosionCandidate;
    for (0..inventory.cell_count) |cell| {
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        if (local >= inventory.layer_capacity) return error.MineralFertilizerErosionDimensionMismatch;
        const top = cell * inventory.layer_capacity + local;
        inline for (@typeInfo(inventory_module.Inventory).@"struct".fields, 0..) |field, component|
            @field(inventory.soil[top], field.name) =
                input[cell * component_count + component];
    }
}

/// Converts externally routed dry minerals to the exact whole-domain balance
/// units used by the inventory census.
pub noinline fn exported(
    workspace: *const constituents.PackedWorkspace,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !Exported {
    if (workspace.component_count != component_count or
        workspace.exported.len !=
            try std.math.mul(usize, workspace.cell_count, component_count))
        return error.MineralFertilizerErosionDimensionMismatch;
    inline for (.{ carbon_g_per_mol, phosphorus_g_per_mol }) |molar_mass|
        if (!std.math.isFinite(molar_mass) or molar_mass <= 0)
            return error.InvalidMineralFertilizerErosionMolarMass;

    var loss: inventory_module.Inventory = .{};
    for (0..workspace.cell_count) |cell| {
        inline for (@typeInfo(inventory_module.Inventory).@"struct".fields, 0..) |field, component| {
            const amount = workspace.exported[cell * component_count + component];
            if (!std.math.isFinite(amount) or amount < 0)
                return error.InvalidMineralFertilizerErosionExport;
            const next = @field(loss, field.name) + amount;
            if (!std.math.isFinite(next))
                return error.MineralFertilizerErosionExportOverflow;
            @field(loss, field.name) = next;
        }
    }

    const monocalcium = loss.broadcast_monocalcium_phosphate_mol +
        loss.banded_monocalcium_phosphate_mol;
    const silicate_al_fe = loss.aluminum_ground_silicate_mol +
        loss.iron_ground_silicate_mol;
    const silicate_ca_mg = loss.calcium_ground_silicate_mol +
        loss.magnesium_ground_silicate_mol;
    const silicate_na_k = loss.sodium_ground_silicate_mol +
        loss.potassium_ground_silicate_mol;
    const result: Exported = .{
        .phosphorus_g_p = phosphorus_g_per_mol *
            (2 * monocalcium + 3 * loss.hydroxyapatite_mol),
        .inorganic_carbon_g_c = carbon_g_per_mol * loss.calcite_mol,
        .ion_mol = 7 * monocalcium + 9 * loss.hydroxyapatite_mol +
            2 * (loss.calcite_mol + loss.gypsum_mol) +
            silicate_al_fe + silicate_ca_mg + silicate_na_k,
        .aluminum_mol = loss.aluminum_ground_silicate_mol,
        .iron_mol = loss.iron_ground_silicate_mol,
        .calcium_mol = monocalcium + 5 * loss.hydroxyapatite_mol +
            loss.calcite_mol + loss.gypsum_mol +
            loss.calcium_ground_silicate_mol,
        .magnesium_mol = loss.magnesium_ground_silicate_mol,
        .sodium_mol = loss.sodium_ground_silicate_mol,
        .potassium_mol = loss.potassium_ground_silicate_mol,
        .sulfur_mol = loss.gypsum_mol,
        .silicon_mol = 0.75 * silicate_al_fe + 0.5 * silicate_ca_mg +
            0.25 * silicate_na_k,
    };
    inline for (std.meta.fields(Exported)) |field|
        if (!std.math.isFinite(@field(result, field.name)) or
            @field(result, field.name) < 0)
            return error.MineralFertilizerErosionExportOverflow;
    return result;
}

test "all dry mineral fertilizer pools follow sediment faces" {
    var inventory = try inventory_module.State.init(std.testing.allocator, 2, 2);
    defer inventory.deinit();
    inline for (@typeInfo(inventory_module.Inventory).@"struct".fields, 0..) |field, component| {
        @field(inventory.soil[0], field.name) = @floatFromInt(component + 1);
        // A deeper-layer sentinel must never be routed by surface erosion.
        @field(inventory.soil[1], field.name) = 1000 + @as(f64, @floatFromInt(component));
    }
    var workspace = try constituents.PackedWorkspace.init(
        std.testing.allocator,
        2,
        component_count,
    );
    defer workspace.deinit();
    try route(2, 1, &.{ 10, 10 }, &inventory, .{
        .east_megagrams = &.{ 1, 0 },
        .west_megagrams = &.{ 0, 0 },
        .south_megagrams = &.{ 0, 0 },
        .north_megagrams = &.{ 0, 0 },
    }, &workspace);
    inline for (@typeInfo(inventory_module.Inventory).@"struct".fields, 0..) |field, component| {
        const initial: f64 = @floatFromInt(component + 1);
        try std.testing.expectApproxEqAbs(
            0.9 * initial,
            @field(inventory.soil[0], field.name),
            1e-14,
        );
        try std.testing.expectApproxEqAbs(
            0.1 * initial,
            @field(inventory.soil[2], field.name),
            1e-14,
        );
        try std.testing.expectEqual(
            1000 + @as(f64, @floatFromInt(component)),
            @field(inventory.soil[1], field.name),
        );
    }
}

test "external dry mineral fertilizer export matches storage stoichiometry" {
    var inventory = try inventory_module.State.init(std.testing.allocator, 1, 1);
    defer inventory.deinit();
    inventory.soil[0] = .{
        .broadcast_monocalcium_phosphate_mol = 2,
        .banded_monocalcium_phosphate_mol = 3,
        .hydroxyapatite_mol = 4,
        .calcite_mol = 5,
        .gypsum_mol = 6,
        .aluminum_ground_silicate_mol = 7,
        .iron_ground_silicate_mol = 8,
        .calcium_ground_silicate_mol = 9,
        .magnesium_ground_silicate_mol = 10,
        .sodium_ground_silicate_mol = 11,
        .potassium_ground_silicate_mol = 12,
    };
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
    const loss = try exported(&workspace, 12, 31);
    try std.testing.expectApproxEqAbs(@as(f64, 68.2), loss.phosphorus_g_p, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6), loss.inorganic_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 15), loss.ion_mol, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), loss.aluminum_mol, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), loss.iron_mol, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), loss.calcium_mol, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), loss.magnesium_mol, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), loss.sodium_mol, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), loss.potassium_mol, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), loss.sulfur_mol, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.65), loss.silicon_mol, 1e-12);
}

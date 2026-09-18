const std = @import("std");
const canopy_module = @import("../canopy/photosynthesis/photosynthesis.zig");
const roots_module = @import("../plant/root/plant_root_system.zig");
const support = @import("landscape_mass_inventory_support.zig");

pub fn aggregatePlantCarbonNitrogenPhosphorus(
    canopy: *const canopy_module.State,
    roots: *const roots_module.State,
) !support.Storage {
    return aggregatePlantRange(canopy, roots, 0, canopy.cell_count);
}

pub fn aggregatePlantCarbonNitrogenPhosphorusCell(
    canopy: *const canopy_module.State,
    roots: *const roots_module.State,
    cell: usize,
) !support.Storage {
    if (cell >= canopy.cell_count) return error.PlantInventoryCellOutOfBounds;
    return aggregatePlantRange(canopy, roots, cell, cell + 1);
}

/// Aboveground plant storage belongs to the canopy scope.
pub fn aggregatePlantShootsCell(
    canopy: *const canopy_module.State,
    roots: *const roots_module.State,
    cell: usize,
) !support.Storage {
    try validatePlantDimensions(canopy, roots, cell, cell + 1);
    var result: support.Storage = .{};
    try addShootsCell(&result, canopy, cell);
    try result.validate();
    return result;
}

/// Root storage belongs to its matching soil-layer scope. Every root layer is
/// retained here (including an inactive soil slot) so the partition exactly
/// reproduces the existing authoritative whole-plant census; topology
/// validation separately rejects stale conserved roots below active soil.
pub fn aggregatePlantRootsLayer(
    canopy: *const canopy_module.State,
    roots: *const roots_module.State,
    cell: usize,
    layer: usize,
) !support.Storage {
    try validatePlantDimensions(canopy, roots, cell, cell + 1);
    if (layer >= roots.soil_layer_count) return error.PlantInventoryCellOutOfBounds;
    var result: support.Storage = .{};
    try addRootsLayer(&result, canopy, roots, cell, layer);
    try result.validate();
    return result;
}

/// Reconstructs only authoritative plant inventories. Branch organ/mobile and
/// symbiont pools, C4 intermediates, seed storage, standing dead/charcoal,
/// and root axes/mobile/symbionts are included exactly once. Plant/branch
/// totals, concentrations, fluxes, balances, retained-root recurrence
/// diagnostics, node organ copies, root WSRTL protein carbon (a subset derived
/// from structural root N/P), and checkpoint accounting are deliberately
/// excluded as duplicate or non-storage coordinates. The reference root C
/// census likewise sums CPOOLR + WTRT1 + WTRT2 without WSRTL
/// (`grosub.f:12996--13015`).
fn aggregatePlantRange(
    canopy: *const canopy_module.State,
    roots: *const roots_module.State,
    first_cell: usize,
    end_cell: usize,
) !support.Storage {
    try validatePlantDimensions(canopy, roots, first_cell, end_cell);

    var result: support.Storage = .{};
    for (first_cell..end_cell) |cell| {
        try addShootsCell(&result, canopy, cell);
        for (0..roots.soil_layer_count) |layer|
            try addRootsLayer(&result, canopy, roots, cell, layer);
    }
    try result.validate();
    return result;
}

fn validatePlantDimensions(
    canopy: *const canopy_module.State,
    roots: *const roots_module.State,
    first_cell: usize,
    end_cell: usize,
) !void {
    if (canopy.cell_count == 0 or canopy.species_count == 0 or
        first_cell > end_cell or end_cell > canopy.cell_count)
        return error.PlantInventoryDimensionMismatch;
    const plant_count = try std.math.mul(usize, canopy.cell_count, canopy.species_count);
    if (roots.plant_count != plant_count or canopy.plant_branch_offsets.len != plant_count + 1)
        return error.PlantInventoryDimensionMismatch;
}

fn addShootsCell(result: *support.Storage, canopy: *const canopy_module.State, cell: usize) !void {
    for (0..canopy.species_count) |species| {
        const plant = cell * canopy.species_count + species;
        const branch_range = try canopy.branchRange(plant);
        for (branch_range.first..branch_range.end) |branch| {
            try addCnp(result, &.{ canopy.branch_leaf_carbon_g[branch], canopy.branch_sheath_carbon_g[branch], canopy.branch_stalk_carbon_g[branch], canopy.branch_reserve_carbon_g[branch], canopy.branch_husk_carbon_g[branch], canopy.branch_ear_carbon_g[branch], canopy.branch_grain_carbon_g[branch], canopy.branch_mobile_carbon_g[branch], canopy.branch_symbiont_structural_carbon_g[branch], canopy.branch_symbiont_mobile_carbon_g[branch] }, &.{ canopy.branch_leaf_nitrogen_g[branch], canopy.branch_sheath_nitrogen_g[branch], canopy.branch_stalk_nitrogen_g[branch], canopy.branch_reserve_nitrogen_g[branch], canopy.branch_husk_nitrogen_g[branch], canopy.branch_ear_nitrogen_g[branch], canopy.branch_grain_nitrogen_g[branch], canopy.branch_mobile_nitrogen_g[branch], canopy.branch_symbiont_structural_nitrogen_g[branch], canopy.branch_symbiont_mobile_nitrogen_g[branch] }, &.{ canopy.branch_leaf_phosphorus_g[branch], canopy.branch_sheath_phosphorus_g[branch], canopy.branch_stalk_phosphorus_g[branch], canopy.branch_reserve_phosphorus_g[branch], canopy.branch_husk_phosphorus_g[branch], canopy.branch_ear_phosphorus_g[branch], canopy.branch_grain_phosphorus_g[branch], canopy.branch_mobile_phosphorus_g[branch], canopy.branch_symbiont_structural_phosphorus_g[branch], canopy.branch_symbiont_mobile_phosphorus_g[branch] });
            const shoot_salt_first = branch * roots_module.salt_species_count;
            try addPlantSaltElements(result, canopy.branch_salt_content_by_species_mol[shoot_salt_first..][0..roots_module.salt_species_count]);
            const nodes = try canopy.nodeRange(branch);
            for (nodes.first..nodes.end) |node| try addCnp(result, &.{ canopy.node_c3_nonstructural_carbon_g[node], canopy.node_c4_mesophyll_nonstructural_carbon_g[node], canopy.node_bundle_sheath_co2_carbon_g[node], canopy.node_bundle_sheath_bicarbonate_carbon_g[node] }, &.{}, &.{});
        }
        try addCnp(result, &.{ canopy.plant_seed_storage_carbon_g[plant], canopy.plant_standing_dead_carbon_g[plant], canopy.plant_charcoal_carbon_g[plant] }, &.{ canopy.plant_seed_storage_nitrogen_g[plant], canopy.plant_standing_dead_nitrogen_g[plant], canopy.plant_charcoal_nitrogen_g[plant] }, &.{ canopy.plant_seed_storage_phosphorus_g[plant], canopy.plant_standing_dead_phosphorus_g[plant], canopy.plant_charcoal_phosphorus_g[plant] });
    }
}

fn addRootsLayer(result: *support.Storage, canopy: *const canopy_module.State, roots: *const roots_module.State, cell: usize, layer: usize) !void {
    for (0..canopy.species_count) |species| {
        const plant = cell * canopy.species_count + species;
        for (0..roots_module.biological_domain_count) |domain| {
            const root = try roots.layerIndex(plant, domain, layer);
            try addCnp(result, &.{ roots.mobile_carbon_g[root], roots.symbiont_structural_carbon_g_c[root], roots.symbiont_mobile_carbon_g_c[root] }, &.{ roots.mobile_nitrogen_g[root], roots.symbiont_structural_nitrogen_g_n[root], roots.symbiont_mobile_nitrogen_g_n[root] }, &.{ roots.mobile_phosphorus_g[root], roots.symbiont_structural_phosphorus_g_p[root], roots.symbiont_mobile_phosphorus_g_p[root] });
            const root_salt_first = root * roots_module.salt_species_count;
            try addPlantSaltElements(result, roots.salt_content_mol[root_salt_first..][0..roots_module.salt_species_count]);
            for (0..roots.root_axis_count) |axis| {
                const axis_layer = try roots.layerAxisIndex(plant, domain, layer, axis);
                try addCnp(result, &.{ roots.axis_primary_carbon_g[axis_layer], roots.axis_secondary_carbon_g[axis_layer] }, &.{ roots.axis_primary_nitrogen_g[axis_layer], roots.axis_secondary_nitrogen_g[axis_layer] }, &.{ roots.axis_primary_phosphorus_g[axis_layer], roots.axis_secondary_phosphorus_g[axis_layer] });
            }
        }
    }
}

/// Dynamic plant salts are authoritative element storage even though legacy
/// REDIST's aggregate `TION` diagnostic deliberately inventories only the
/// soil/litter side and compensates plant transfers with `TUPZ*`/`*SNT`.
/// Including the eight carried elements here makes root uptake, shoot/root
/// exchange, senescence, harvest litter, and combustion internal transfers in
/// the stricter hourly all-storage balance. Do not add them to
/// `ion_inventory_mol`: that field preserves the legacy pseudo-ion census.
fn addPlantSaltElements(result: *support.Storage, salt_mol: []const f64) !void {
    if (salt_mol.len != roots_module.salt_species_count)
        return error.PlantInventoryDimensionMismatch;
    inline for (.{
        &result.aluminum_mol,
        &result.iron_mol,
        &result.calcium_mol,
        &result.magnesium_mol,
        &result.sodium_mol,
        &result.potassium_mol,
        &result.sulfur_mol,
        &result.chloride_mol,
    }, 0..) |destination, salt| {
        const value = salt_mol[salt];
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPlantInventory;
        const next = destination.* + value;
        if (!std.math.isFinite(next)) return error.NonFiniteLandscapeInventory;
        destination.* = next;
    }
}

fn addCnp(result: *support.Storage, carbon: []const f64, nitrogen: []const f64, phosphorus: []const f64) !void {
    inline for (.{ .{ carbon, &result.plant_carbon_g }, .{ nitrogen, &result.plant_nitrogen_g }, .{ phosphorus, &result.plant_phosphorus_g } }) |pair| {
        for (pair[0]) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantInventory;
            const next = pair[1].* + value;
            if (!std.math.isFinite(next)) return error.NonFiniteLandscapeInventory;
            pair[1].* = next;
        }
    }
}

test "plant inventory includes authoritative pools once excludes derived WSRTL and preserves cell partition" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 2, 1, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 1, 1 });
    defer canopy.deinit();
    var roots = try roots_module.State.init(std.testing.allocator, 2, 1, 1);
    defer roots.deinit();
    canopy.branch_leaf_carbon_g[0] = 1;
    canopy.branch_mobile_nitrogen_g[0] = 2;
    canopy.branch_grain_phosphorus_g[0] = 3;
    canopy.node_bundle_sheath_co2_carbon_g[0] = 4;
    canopy.plant_seed_storage_carbon_g[0] = 5;
    canopy.plant_standing_dead_nitrogen_g[0] = 6;
    canopy.plant_charcoal_phosphorus_g[0] = 7;
    roots.mobile_carbon_g[0] = 8;
    roots.protein_carbon_g[0] = 9;
    roots.axis_primary_carbon_g[0] = 15;
    roots.axis_primary_nitrogen_g[0] = 10;
    roots.axis_secondary_phosphorus_g[0] = 11;
    roots.symbiont_structural_carbon_g_c[0] = 12;
    roots.symbiont_mobile_nitrogen_g_n[0] = 13;
    roots.symbiont_mobile_phosphorus_g_p[0] = 14;
    for (0..roots_module.salt_species_count) |salt| {
        canopy.branch_salt_content_by_species_mol[salt] =
            @floatFromInt(salt + 1);
        roots.salt_content_mol[salt] = @floatFromInt(10 * (salt + 1));
    }
    // These are duplicate summaries/diagnostics and must never enter storage.
    canopy.plant_total_shoot_carbon_g[0] = 1000;
    roots.total_carbon_g[0] = 2000;
    roots.retained_root_carbon_g_c_per_plant[0] = 3000;
    const first = try aggregatePlantCarbonNitrogenPhosphorusCell(&canopy, &roots, 0);
    const shoots = try aggregatePlantShootsCell(&canopy, &roots, 0);
    const root_layer = try aggregatePlantRootsLayer(&canopy, &roots, 0, 0);
    var layer_partition = shoots;
    try layer_partition.add(root_layer);
    const second = try aggregatePlantCarbonNitrogenPhosphorusCell(&canopy, &roots, 1);
    const all = try aggregatePlantCarbonNitrogenPhosphorus(&canopy, &roots);
    try std.testing.expectEqual(@as(f64, 45), first.plant_carbon_g);
    try std.testing.expectEqual(@as(f64, 31), first.plant_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 35), first.plant_phosphorus_g);
    try std.testing.expectEqual(@as(f64, 11), first.aluminum_mol);
    try std.testing.expectEqual(@as(f64, 22), first.iron_mol);
    try std.testing.expectEqual(@as(f64, 33), first.calcium_mol);
    try std.testing.expectEqual(@as(f64, 44), first.magnesium_mol);
    try std.testing.expectEqual(@as(f64, 55), first.sodium_mol);
    try std.testing.expectEqual(@as(f64, 66), first.potassium_mol);
    try std.testing.expectEqual(@as(f64, 77), first.sulfur_mol);
    try std.testing.expectEqual(@as(f64, 88), first.chloride_mol);
    try std.testing.expectEqual(@as(f64, 0), first.ion_inventory_mol);
    try std.testing.expectEqual(@as(f64, 0), second.plant_carbon_g);
    try std.testing.expectEqualDeep(first, layer_partition);
    try std.testing.expectEqualDeep(first, all);

    // WSRTL is protein C already contained by structural root C. Mutating the
    // uptake diagnostic alone must not create or destroy authoritative C.
    roots.protein_carbon_g[0] = 9.0e6;
    const after_protein_diagnostic = try aggregatePlantCarbonNitrogenPhosphorusCell(&canopy, &roots, 0);
    try std.testing.expectEqualDeep(first, after_protein_diagnostic);
}

test "plant inventory rejects late invalid pool atomically" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var roots = try roots_module.State.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    canopy.branch_leaf_carbon_g[0] = 2;
    roots.axis_secondary_phosphorus_g[roots.axis_secondary_phosphorus_g.len - 1] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidPlantInventory, aggregatePlantCarbonNitrogenPhosphorus(&canopy, &roots));
}

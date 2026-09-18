const std = @import("std");
const chemistry = @import("litter_chemistry.zig");
const rates = @import("litter_reaction_rates.zig");

pub const ExchangeChanges = struct {
    ammonium_mol: f64,
    hydrogen_mol: f64,
    aluminum_mol: f64,
    iron_mol: f64,
    calcium_mol: f64,
    magnesium_mol: f64,
    sodium_mol: f64,
    potassium_mol: f64,
};

pub const PhosphateMineralChanges = struct {
    aluminum_phosphate_mol: f64,
    iron_phosphate_mol: f64,
    dicalcium_phosphate_mol: f64,
    hydroxyapatite_mol: f64,
    monocalcium_phosphate_mol: f64,
};

pub const PhosphateSurfaceChanges = struct {
    deprotonated_site_mol: f64,
    hydroxyl_site_mol: f64,
    protonated_site_mol: f64,
    adsorbed_hpo4_mol_p: f64,
    adsorbed_h2po4_mol_p: f64,
};

pub const SaltMineralChanges = struct {
    gibbsite_mol: f64,
    iron_hydroxide_mol: f64,
    calcite_mol: f64,
    gypsum_mol: f64,
};

/// Extensive litter changes passed to REDIST. Aqueous and mineral
/// concentrations use litter water volume; exchange/carboxyl concentrations
/// use litter dry mass, exactly as SOLUTE.F lines 5127-5208.
pub const Changes = struct {
    ammonium_mol_n: f64,
    ammonia_mol_n: f64,
    hpo4_mol_p: f64,
    h2po4_mol_p: f64,
    hydrogen_mol: f64,
    hydroxide_mol: f64,
    aluminum_mol: f64,
    iron_mol: f64,
    calcium_mol: f64,
    magnesium_mol: f64,
    sodium_mol: f64,
    potassium_mol: f64,
    carbonate_mol: f64,
    bicarbonate_mol: f64,
    carbon_dioxide_mol: f64,
    sulfate_mol: f64,
    water_mol: f64,
    carboxyl_hydrogen_mol: f64,
    exchange: ExchangeChanges,
    phosphate_surface: PhosphateSurfaceChanges,
    phosphate_minerals: PhosphateMineralChanges,
    salt_minerals: SaltMineralChanges,
};

pub const Geometry = struct {
    litter_water_volume_m3: f64,
    litter_dry_mass_megagrams: f64,
};

pub fn calculate(before: chemistry.Cell, after: chemistry.Cell, geometry: Geometry) !Changes {
    try validateGeometry(geometry);
    const water = geometry.litter_water_volume_m3;
    const mass = geometry.litter_dry_mass_megagrams;
    return .{
        .ammonium_mol_n = try extensive(after.ammonium_mol_per_m3, before.ammonium_mol_per_m3, water),
        .ammonia_mol_n = try extensive(after.ammonia_mol_per_m3, before.ammonia_mol_per_m3, water),
        .hpo4_mol_p = try extensive(after.hpo4_mol_p_per_m3, before.hpo4_mol_p_per_m3, water),
        .h2po4_mol_p = try extensive(after.h2po4_mol_p_per_m3, before.h2po4_mol_p_per_m3, water),
        .hydrogen_mol = try extensive(after.hydrogen_mol_per_m3, before.hydrogen_mol_per_m3, water),
        .hydroxide_mol = try extensive(after.hydroxide_mol_per_m3, before.hydroxide_mol_per_m3, water),
        .aluminum_mol = try extensive(after.aluminum_mol_per_m3, before.aluminum_mol_per_m3, water),
        .iron_mol = try extensive(after.iron_mol_per_m3, before.iron_mol_per_m3, water),
        .calcium_mol = try extensive(after.calcium_mol_per_m3, before.calcium_mol_per_m3, water),
        .magnesium_mol = try extensive(after.magnesium_mol_per_m3, before.magnesium_mol_per_m3, water),
        .sodium_mol = try extensive(after.sodium_mol_per_m3, before.sodium_mol_per_m3, water),
        .potassium_mol = try extensive(after.potassium_mol_per_m3, before.potassium_mol_per_m3, water),
        .carbonate_mol = try extensive(after.carbonate_mol_per_m3, before.carbonate_mol_per_m3, water),
        .bicarbonate_mol = try extensive(after.bicarbonate_mol_per_m3, before.bicarbonate_mol_per_m3, water),
        .carbon_dioxide_mol = try extensive(after.carbon_dioxide_mol_per_m3, before.carbon_dioxide_mol_per_m3, water),
        .sulfate_mol = try extensive(after.sulfate_mol_per_m3, before.sulfate_mol_per_m3, water),
        .water_mol = try extensive(after.water_mol_per_m3, before.water_mol_per_m3, water),
        .carboxyl_hydrogen_mol = try extensive(after.carboxyl_hydrogen_mol_per_megagram, before.carboxyl_hydrogen_mol_per_megagram, mass),
        .exchange = .{
            .ammonium_mol = try extensive(after.exchange.ammonium_mol_per_megagram, before.exchange.ammonium_mol_per_megagram, mass),
            .hydrogen_mol = try extensive(after.exchange.hydrogen_mol_per_megagram, before.exchange.hydrogen_mol_per_megagram, mass),
            .aluminum_mol = try extensive(after.exchange.aluminum_mol_per_megagram, before.exchange.aluminum_mol_per_megagram, mass),
            .iron_mol = try extensive(after.exchange.iron_mol_per_megagram, before.exchange.iron_mol_per_megagram, mass),
            .calcium_mol = try extensive(after.exchange.calcium_mol_per_megagram, before.exchange.calcium_mol_per_megagram, mass),
            .magnesium_mol = try extensive(after.exchange.magnesium_mol_per_megagram, before.exchange.magnesium_mol_per_megagram, mass),
            .sodium_mol = try extensive(after.exchange.sodium_mol_per_megagram, before.exchange.sodium_mol_per_megagram, mass),
            .potassium_mol = try extensive(after.exchange.potassium_mol_per_megagram, before.exchange.potassium_mol_per_megagram, mass),
        },
        .phosphate_surface = .{
            .deprotonated_site_mol = try extensive(after.phosphate_surface.deprotonated_site_mol_per_megagram, before.phosphate_surface.deprotonated_site_mol_per_megagram, mass),
            .hydroxyl_site_mol = try extensive(after.phosphate_surface.hydroxyl_site_mol_per_megagram, before.phosphate_surface.hydroxyl_site_mol_per_megagram, mass),
            .protonated_site_mol = try extensive(after.phosphate_surface.protonated_site_mol_per_megagram, before.phosphate_surface.protonated_site_mol_per_megagram, mass),
            .adsorbed_hpo4_mol_p = try extensive(after.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram, before.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram, mass),
            .adsorbed_h2po4_mol_p = try extensive(after.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram, before.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram, mass),
        },
        .phosphate_minerals = .{
            .aluminum_phosphate_mol = try extensive(after.phosphate_minerals.aluminum_phosphate_mol_per_m3, before.phosphate_minerals.aluminum_phosphate_mol_per_m3, water),
            .iron_phosphate_mol = try extensive(after.phosphate_minerals.iron_phosphate_mol_per_m3, before.phosphate_minerals.iron_phosphate_mol_per_m3, water),
            .dicalcium_phosphate_mol = try extensive(after.phosphate_minerals.dicalcium_phosphate_mol_per_m3, before.phosphate_minerals.dicalcium_phosphate_mol_per_m3, water),
            .hydroxyapatite_mol = try extensive(after.phosphate_minerals.hydroxyapatite_mol_per_m3, before.phosphate_minerals.hydroxyapatite_mol_per_m3, water),
            .monocalcium_phosphate_mol = try extensive(after.phosphate_minerals.monocalcium_phosphate_mol_per_m3, before.phosphate_minerals.monocalcium_phosphate_mol_per_m3, water),
        },
        .salt_minerals = .{
            .gibbsite_mol = try extensive(after.salt_minerals.gibbsite_mol_per_m3, before.salt_minerals.gibbsite_mol_per_m3, water),
            .iron_hydroxide_mol = try extensive(after.salt_minerals.iron_hydroxide_mol_per_m3, before.salt_minerals.iron_hydroxide_mol_per_m3, water),
            .calcite_mol = try extensive(after.salt_minerals.calcite_mol_per_m3, before.salt_minerals.calcite_mol_per_m3, water),
            .gypsum_mol = try extensive(after.salt_minerals.gypsum_mol_per_m3, before.salt_minerals.gypsum_mol_per_m3, water),
        },
    };
}

pub fn solveCellAndCapture(state: *chemistry.State, cell_index: usize, context: *const rates.Context, options: chemistry.Options, geometry: Geometry, output: *Changes) !chemistry.Result {
    try validateGeometry(geometry);
    if (cell_index >= state.cells.len) return error.LitterChemistryCellIndexOutOfBounds;
    const before = state.cells[cell_index];
    const phosphorus_before_mol = try phosphorusInventoryMol(before, geometry);
    const result = try rates.solveCell(state, cell_index, context, options);
    try restorePhosphorusInventory(
        &state.cells[cell_index],
        geometry,
        phosphorus_before_mol,
        options,
    );
    output.* = try calculate(before, state.cells[cell_index], geometry);
    return result;
}

/// Production hourly surface-litter integration and REDIST capture. Both salt
/// modes execute one source-ordered, simultaneous ledger from the pre-hour
/// state; no solve-to-zero or post-ledger water projection occurs here.
pub fn applyHourlyCellAndCapture(state: *chemistry.State, cell_index: usize, context: *const rates.Context, options: chemistry.Options, geometry: Geometry, output: *Changes) !chemistry.Result {
    try validateGeometry(geometry);
    if (cell_index >= state.cells.len) return error.LitterChemistryCellIndexOutOfBounds;
    const before = state.cells[cell_index];
    const phosphorus_before_mol = try phosphorusInventoryMol(before, geometry);
    const result = try rates.applyHourlyCell(state, cell_index, context, options);
    try restorePhosphorusInventory(
        &state.cells[cell_index],
        geometry,
        phosphorus_before_mol,
        options,
    );
    output.* = try calculate(before, state.cells[cell_index], geometry);
    return result;
}

fn phosphorusInventoryMol(cell: chemistry.Cell, geometry: Geometry) !f64 {
    const water = geometry.litter_water_volume_m3;
    const dry_mass = geometry.litter_dry_mass_megagrams;
    const total = water * (cell.hpo4_mol_p_per_m3 +
        cell.h2po4_mol_p_per_m3 +
        cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 +
        cell.phosphate_minerals.iron_phosphate_mol_per_m3 +
        cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3 +
        3 * cell.phosphate_minerals.hydroxyapatite_mol_per_m3 +
        2 * cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3) +
        dry_mass * (cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram +
            cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram);
    if (!std.math.isFinite(total) or total < 0)
        return error.InvalidLitterPhosphorusInventory;
    return total;
}

/// The nonlinear residual accepts small coordinate errors, but reaction
/// extents are conservative. Project only that accepted roundoff back onto
/// aqueous H2PO4 so solver tolerance cannot become a material P source/sink.
fn restorePhosphorusInventory(
    cell: *chemistry.Cell,
    geometry: Geometry,
    target_mol: f64,
    options: chemistry.Options,
) !void {
    const current_mol = try phosphorusInventoryMol(cell.*, geometry);
    const correction_mol = target_mol - current_mol;
    // The inventory mixes aqueous/mineral mol m-3 with sorbed mol Mg-1.
    // Convert each unit-specific residual floor through its authoritative
    // carrier before comparing the extensive phosphorus correction.
    const permitted = options.absolute_tolerance_mol_per_m3 * geometry.litter_water_volume_m3 +
        options.absolute_tolerance_mol_per_megagram * geometry.litter_dry_mass_megagrams +
        options.relative_tolerance * @max(target_mol, current_mol);
    if (!std.math.isFinite(permitted) or @abs(correction_mol) > permitted)
        return error.NonConservativeLitterPhosphorusReaction;
    if (correction_mol >= 0) {
        cell.h2po4_mol_p_per_m3 += correction_mol / geometry.litter_water_volume_m3;
    } else {
        var removal_mol = -correction_mol;
        removeFromPool(&cell.h2po4_mol_p_per_m3, geometry.litter_water_volume_m3, 1, &removal_mol);
        removeFromPool(&cell.hpo4_mol_p_per_m3, geometry.litter_water_volume_m3, 1, &removal_mol);
        removeFromPool(&cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram, geometry.litter_dry_mass_megagrams, 1, &removal_mol);
        removeFromPool(&cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram, geometry.litter_dry_mass_megagrams, 1, &removal_mol);
        removeFromPool(&cell.phosphate_minerals.aluminum_phosphate_mol_per_m3, geometry.litter_water_volume_m3, 1, &removal_mol);
        removeFromPool(&cell.phosphate_minerals.iron_phosphate_mol_per_m3, geometry.litter_water_volume_m3, 1, &removal_mol);
        removeFromPool(&cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3, geometry.litter_water_volume_m3, 1, &removal_mol);
        removeFromPool(&cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3, geometry.litter_water_volume_m3, 2, &removal_mol);
        removeFromPool(&cell.phosphate_minerals.hydroxyapatite_mol_per_m3, geometry.litter_water_volume_m3, 3, &removal_mol);
        if (removal_mol > permitted)
            return error.LitterPhosphorusProjectionWouldBecomeNegative;
    }
    if (!std.math.isFinite(cell.h2po4_mol_p_per_m3))
        return error.InvalidLitterPhosphorusInventory;
}

fn removeFromPool(pool: *f64, carrier: f64, phosphorus_per_molecule: f64, remaining_mol: *f64) void {
    if (remaining_mol.* <= 0) return;
    const available_mol = pool.* * carrier * phosphorus_per_molecule;
    const removed_mol = @min(available_mol, remaining_mol.*);
    // Full depletion has an exact zero endpoint. Dividing the represented
    // extensive amount back by its carrier can exceed the original pool by
    // one ULP, leaving an invalid negative concentration for the next hour.
    if (removed_mol == available_mol) {
        pool.* = 0;
    } else {
        pool.* -= removed_mol / (carrier * phosphorus_per_molecule);
    }
    remaining_mol.* -= removed_mol;
}

test "litter phosphorus donor depletion cannot leave a negative concentration" {
    const initial: f64 = 0.001685955268641795;
    const carrier: f64 = 1.4468856186029942e-7;
    for ([_]f64{ 1, 2, 3 }) |stoichiometry| {
        var pool = initial;
        const available = pool * carrier * stoichiometry;
        var remaining = 2 * available;
        removeFromPool(&pool, carrier, stoichiometry, &remaining);
        try std.testing.expectEqual(@as(f64, 0), pool);
        try std.testing.expectEqual(available, remaining);
        // The next donor supplies only the extensive amount still owed.
        var next_pool = 2 * initial;
        removeFromPool(&next_pool, carrier, stoichiometry, &remaining);
        try std.testing.expectEqual(@as(f64, 0), remaining);
        try std.testing.expect(next_pool >= 0);
        try std.testing.expectApproxEqAbs(initial, next_pool, 2 * std.math.floatEps(f64) * initial);
    }
}

fn extensive(after: f64, before: f64, factor: f64) !f64 {
    const value = (after - before) * factor;
    if (!std.math.isFinite(value)) return error.NonFiniteLitterExtensiveChange;
    return value;
}

fn validateGeometry(geometry: Geometry) !void {
    if (!std.math.isFinite(geometry.litter_water_volume_m3) or geometry.litter_water_volume_m3 <= 0 or !std.math.isFinite(geometry.litter_dry_mass_megagrams) or geometry.litter_dry_mass_megagrams <= 0) return error.InvalidLitterGeometry;
}

fn zeroCell() chemistry.Cell {
    var cell: chemistry.Cell = undefined;
    zeroStruct(chemistry.Cell, &cell);
    return cell;
}

fn zeroStruct(comptime T: type, value: *T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => @field(value.*, field.name) = 0,
        .@"struct" => zeroStruct(field.type, &@field(value.*, field.name)),
        else => unreachable,
    };
}

test "litter REDIST conversion uses water volume and dry mass by pool" {
    const before = zeroCell();
    var after = before;
    after.ammonium_mol_per_m3 = 2;
    after.exchange.ammonium_mol_per_megagram = 3;
    after.carboxyl_hydrogen_mol_per_megagram = 4;
    after.phosphate_minerals.hydroxyapatite_mol_per_m3 = 5;
    const changes = try calculate(before, after, .{ .litter_water_volume_m3 = 7, .litter_dry_mass_megagrams = 11 });
    try std.testing.expectEqual(@as(f64, 14), changes.ammonium_mol_n);
    try std.testing.expectEqual(@as(f64, 33), changes.exchange.ammonium_mol);
    try std.testing.expectEqual(@as(f64, 44), changes.carboxyl_hydrogen_mol);
    try std.testing.expectEqual(@as(f64, 35), changes.phosphate_minerals.hydroxyapatite_mol);
}

test "invalid litter geometry fails before changing output" {
    const cell = zeroCell();
    try std.testing.expectError(error.InvalidLitterGeometry, calculate(cell, cell, .{ .litter_water_volume_m3 = 0, .litter_dry_mass_megagrams = 1 }));
}

test "accepted litter solver tolerance cannot change phosphorus inventory" {
    var cell = zeroCell();
    cell.h2po4_mol_p_per_m3 = 2;
    cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram = 3;
    cell.phosphate_minerals.hydroxyapatite_mol_per_m3 = 5;
    const geometry: Geometry = .{ .litter_water_volume_m3 = 7, .litter_dry_mass_megagrams = 11 };
    const target = try phosphorusInventoryMol(cell, geometry);
    cell.h2po4_mol_p_per_m3 -= 1e-9;
    try restorePhosphorusInventory(&cell, geometry, target, .{ .relative_tolerance = 1e-8 });
    try std.testing.expectApproxEqAbs(target, try phosphorusInventoryMol(cell, geometry), 5e-14);
}

test "litter phosphorus projection converts the sorbed tolerance through dry mass" {
    var cell = zeroCell();
    cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram = 1;
    const geometry: Geometry = .{ .litter_water_volume_m3 = 0.5, .litter_dry_mass_megagrams = 10 };
    const target = try phosphorusInventoryMol(cell, geometry);
    cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram -= 5e-7;
    try restorePhosphorusInventory(&cell, geometry, target, .{
        .absolute_tolerance_mol_per_m3 = 1e-15,
        .absolute_tolerance_mol_per_megagram = 1e-6,
        .relative_tolerance = 1e-16,
    });
    try std.testing.expectApproxEqAbs(target, try phosphorusInventoryMol(cell, geometry), 5e-14);
}

test "material litter phosphorus defect fails instead of being hidden" {
    var cell = zeroCell();
    cell.h2po4_mol_p_per_m3 = 2;
    const geometry: Geometry = .{ .litter_water_volume_m3 = 1, .litter_dry_mass_megagrams = 1 };
    try std.testing.expectError(
        error.NonConservativeLitterPhosphorusReaction,
        restorePhosphorusInventory(&cell, geometry, 3, .{ .relative_tolerance = 1e-8 }),
    );
}

//! Single-owner bridge for aqueous surface-litter ammonia.
//!
//! The oracle stores litter aqueous NH3 as `ZNH3S(0)` and gaseous NH3 as
//! `ZNH3G(0)` (`hour1.f:4494-4603`).  `litter_chemistry` owns the former in
//! mol N/m3.  The gas state's aqueous NH3 slot is therefore only a transient
//! g-N mirror used by the coupled gas/water phase equation; it is not a second
//! inventory or runoff-transport owner.

const std = @import("std");
const chemistry = @import("litter_chemistry.zig");
const gas = @import("../soil/gas/transport.zig");
const legacy_water_negligible_floor = @import("../core/legacy_water_negligible_floor.zig");

pub fn refreshTransientFromChemistry(
    chemistry_state: *const chemistry.State,
    gas_state: *gas.State,
    litter_water_m3: []const f64,
    cell_area_m2: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    try validateDimensions(chemistry_state, gas_state, litter_water_m3, cell_area_m2, nitrogen_molar_mass_g_per_mol);
    for (chemistry_state.cells, litter_water_m3, chemistry_state.dry_reference_water_m3, cell_area_m2) |cell, water, dry_reference_water, area_m2| {
        if (!std.math.isFinite(cell.ammonia_mol_per_m3) or cell.ammonia_mol_per_m3 < 0)
            return error.InvalidLitterAmmoniaInventory;
        const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(area_m2);
        const water_carrier = try litterAmmoniaCarrierM3(water, dry_reference_water, negligible_water_volume_m3);
        const mass = cell.ammonia_mol_per_m3 * water_carrier * nitrogen_molar_mass_g_per_mol;
        if (!std.math.isFinite(mass) or mass < 0)
            return error.InvalidLitterAmmoniaInventory;
    }
    for (chemistry_state.cells, litter_water_m3, cell_area_m2, 0..) |cell, water, area_m2, cell_index| {
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(area_m2);
        const water_carrier = try litterAmmoniaCarrierM3(water, chemistry_state.dry_reference_water_m3[cell_index], negligible_water_volume_m3);
        gas_state.dissolved_mass_g[index] = cell.ammonia_mol_per_m3 * water_carrier * nitrogen_molar_mass_g_per_mol;
        gas_state.macropore_dissolved_mass_g[index] = 0;
        gas_state.band_dissolved_mass_g[index] = 0;
    }
}

pub fn publishTransientToChemistry(
    chemistry_state: *chemistry.State,
    gas_state: *const gas.State,
    litter_water_m3: []const f64,
    cell_area_m2: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
    absolute_tolerance_g_n: f64,
    relative_tolerance: f64,
) !void {
    try validateDimensions(chemistry_state, gas_state, litter_water_m3, cell_area_m2, nitrogen_molar_mass_g_per_mol);
    if (!std.math.isFinite(absolute_tolerance_g_n) or absolute_tolerance_g_n < 0 or
        !std.math.isFinite(relative_tolerance) or relative_tolerance < 0)
        return error.InvalidLitterAmmoniaBridgeTolerance;
    for (litter_water_m3, cell_area_m2, 0..) |water, area_m2, cell_index| {
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        const dissolved = gas_state.dissolved_mass_g[index];
        if (!std.math.isFinite(dissolved) or dissolved < 0)
            return error.InvalidTransientLitterAmmoniaInventory;
        if (!std.math.isFinite(gas_state.macropore_dissolved_mass_g[index]) or
            gas_state.macropore_dissolved_mass_g[index] != 0 or
            !std.math.isFinite(gas_state.band_dissolved_mass_g[index]) or
            gas_state.band_dissolved_mass_g[index] != 0)
            return error.NoncanonicalTransientLitterAmmonia;
        const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(area_m2);
        const water_carrier = try litterAmmoniaCarrierM3(water, chemistry_state.dry_reference_water_m3[cell_index], negligible_water_volume_m3);
        if (water_carrier == 0) {
            const scale = @max(1.0, dissolved);
            if (dissolved > absolute_tolerance_g_n + relative_tolerance * scale)
                return error.LitterAmmoniaWithoutWaterCarrier;
        }
    }
    for (litter_water_m3, cell_area_m2, 0..) |water, area_m2, cell_index| {
        const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(area_m2);
        const water_carrier = try litterAmmoniaCarrierM3(water, chemistry_state.dry_reference_water_m3[cell_index], negligible_water_volume_m3);
        if (water_carrier == 0) continue;
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        chemistry_state.cells[cell_index].ammonia_mol_per_m3 =
            gas_state.dissolved_mass_g[index] / nitrogen_molar_mass_g_per_mol / water_carrier;
    }
}

/// Removes restart-stale transient litter NH3 without touching gaseous NH3.
pub fn clearTransient(gas_state: *gas.State) !void {
    try gas_state.validateShape();
    for (0..gas_state.cell_count) |cell| {
        const index = cell * gas.species_count + @intFromEnum(gas.Species.ammonia);
        gas_state.dissolved_mass_g[index] = 0;
        gas_state.macropore_dissolved_mass_g[index] = 0;
        gas_state.band_dissolved_mass_g[index] = 0;
    }
}

fn validateDimensions(
    chemistry_state: *const chemistry.State,
    gas_state: *const gas.State,
    litter_water_m3: []const f64,
    cell_area_m2: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    if (!std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0)
        return error.InvalidNitrogenMolarMass;
    if (chemistry_state.cells.len == 0 or
        chemistry_state.dry_reference_water_m3.len != chemistry_state.cells.len or
        gas_state.cell_count != chemistry_state.cells.len or
        litter_water_m3.len != chemistry_state.cells.len or
        cell_area_m2.len != chemistry_state.cells.len)
        return error.LitterAmmoniaPhaseBridgeDimensionMismatch;
    try gas_state.validateShape();
    for (litter_water_m3, chemistry_state.dry_reference_water_m3, cell_area_m2) |water, dry_reference, area_m2| {
        if (!std.math.isFinite(water) or water < 0 or
            !std.math.isFinite(dry_reference) or dry_reference < 0 or
            !std.math.isFinite(area_m2) or area_m2 < 0)
            return error.InvalidLitterAmmoniaWaterCarrier;
    }
}

/// `ZEROS2(NY,NX) = ZERO2*DH(NY,NX)*DV(NY,NX)` (`starts.f:270`). issue-066:
/// shares the same floor `landscape_mass_inventory_surface.zig`'s private
/// `negligibleLitterWaterVolumeM3` already applies for this exact litter
/// scope, and `erosion_chemistry_bridge.zig`'s now-fixed
/// `erosionWaterCarrierM3` already applies for the structurally identical
/// pack/unpack shape (issue-065), so this file's
/// `refreshTransientFromChemistry`/`publishTransientToChemistry` round trip
/// agrees with both on the same water-carrier basis for the same degenerate
/// cell. Mirrors `erosionWaterCarrierM3`'s own error-set-local duplication
/// rather than importing it: this file is a distinct production mutator.
fn litterAmmoniaCarrierM3(
    live_water_m3: f64,
    dry_reference_water_m3: f64,
    negligible_water_volume_m3: f64,
) !f64 {
    if (!std.math.isFinite(live_water_m3) or live_water_m3 < 0 or
        !std.math.isFinite(dry_reference_water_m3) or dry_reference_water_m3 < 0 or
        !std.math.isFinite(negligible_water_volume_m3) or negligible_water_volume_m3 < 0)
        return error.InvalidLitterAmmoniaWaterCarrier;
    return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
}

test "litter chemistry ammonia is sole aqueous owner and transient round trip is exact" {
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 2);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 2;
    chemistry_state.cells[1].ammonia_mol_per_m3 = 5;
    try refreshTransientFromChemistry(&chemistry_state, &gas_state, &.{ 3, 4 }, &.{ 1, 1 }, 14.01);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    try std.testing.expectApproxEqAbs(@as(f64, 84.06), gas_state.dissolved_mass_g[ammonia], 1e-13);
    gas_state.dissolved_mass_g[ammonia] -= 14.01;
    gas_state.dissolved_mass_g[gas.species_count + ammonia] += 14.01;
    try publishTransientToChemistry(&chemistry_state, &gas_state, &.{ 3, 4 }, &.{ 1, 1 }, 14.01, 1e-12, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0 / 3.0), chemistry_state.cells[0].ammonia_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 5.25), chemistry_state.cells[1].ammonia_mol_per_m3, 1e-14);
}

test "dry retained ammonia is packed onto the dry-reference carrier and round-trips exactly" {
    // issue-066: pre-fix, this test asserted the defect itself (packed mass
    // forced to exactly 0 at water==0, discarding the true extensive amount
    // the concentration represents against dry_reference_water_m3). Fixed
    // behavior: the dry cell's true extensive mass (concentration *
    // dry_reference_water_m3 * molar_mass = 4 * 2 * 14 = 112 g N) is now
    // correctly packed into the transient mirror, and with no solver-side
    // mutation between pack and unpack, the round trip recovers the exact
    // original concentration.
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 4;
    chemistry_state.dry_reference_water_m3[0] = 2;
    try refreshTransientFromChemistry(&chemistry_state, &gas_state, &.{0}, &.{1}, 14);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    try std.testing.expectApproxEqAbs(@as(f64, 112), gas_state.dissolved_mass_g[ammonia], 1e-12);
    try publishTransientToChemistry(&chemistry_state, &gas_state, &.{0}, &.{1}, 14, 1e-12, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4), chemistry_state.cells[0].ammonia_mol_per_m3, 1e-12);
}

test "invalid later transient leaves all litter chemistry owners unchanged" {
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 2);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 2;
    chemistry_state.cells[1].ammonia_mol_per_m3 = 5;
    try refreshTransientFromChemistry(&chemistry_state, &gas_state, &.{ 1, 1 }, &.{ 1, 1 }, 14);
    gas_state.dissolved_mass_g[gas.species_count + @intFromEnum(gas.Species.ammonia)] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidTransientLitterAmmoniaInventory, publishTransientToChemistry(&chemistry_state, &gas_state, &.{ 1, 1 }, &.{ 1, 1 }, 14, 1e-12, 1e-9));
    try std.testing.expectEqual(@as(f64, 2), chemistry_state.cells[0].ammonia_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 5), chemistry_state.cells[1].ammonia_mol_per_m3);
}

test "issue-066: OLD raw-carrier pack/unpack arithmetic would destroy litter aqueous ammonia mass at a near-zero-but-nonzero water content" {
    // Reproduces this issue's own diagnosis by direct arithmetic, matching
    // the pre-fix `refreshTransientFromChemistry`/`publishTransientToChemistry`
    // formulas exactly (`if (water > 0) concentration * water * molar_mass
    // else 0` / `dissolved / molar_mass / water`) -- those formulas are no
    // longer reachable through the public entry points after the fix above,
    // so this test documents historical behavior rather than calling into
    // the module.
    const dry_reference_water_m3: f64 = 2;
    const live_water_m3: f64 = 1.0e-9; // below the 1.0e-6 m3 ZEROS2 floor for a 1 m2 cell
    const nitrogen_molar_mass_g_per_mol: f64 = 14;
    const concentration_mol_per_m3: f64 = 4;
    const true_mass_g_n = concentration_mol_per_m3 * dry_reference_water_m3 * nitrogen_molar_mass_g_per_mol;
    try std.testing.expectApproxEqAbs(@as(f64, 112), true_mass_g_n, 1e-12);

    // Pack side: OLD `water > 0` is true even at 1e-9, so the raw live water
    // is used directly as the carrier, discarding nearly all the true
    // extensive mass with no ledger entry -- nothing physically removed the
    // water-borne ammonia; the litter is simply mid-evaporation.
    const packed_old_g_n = concentration_mol_per_m3 * live_water_m3 * nitrogen_molar_mass_g_per_mol;
    try std.testing.expect(packed_old_g_n / true_mass_g_n < 1.0e-6);

    // Unpack side: if the true mass (112 g N) were ever present in the
    // mirror at this water content (e.g. carried over from wet-hour
    // chemistry the solver did not touch because dissolved-phase exchange
    // was zero that hour), OLD's unpack divides by the same raw near-zero
    // water, manufacturing a physically impossible concentration nine
    // orders of magnitude above the correct value -- the "fake mass swing"
    // this defect class produces once real chemistry, not just an inert
    // round trip, is on either side of the divide.
    const unpacked_old_concentration_mol_per_m3 = true_mass_g_n / nitrogen_molar_mass_g_per_mol / live_water_m3;
    try std.testing.expect(unpacked_old_concentration_mol_per_m3 > 1.0e9);
}

test "issue-066: NEW refreshTransientFromChemistry/publishTransientToChemistry round trip preserves litter aqueous ammonia mass through a genuine solver-side mutation at a near-zero-but-nonzero water content" {
    // Two cells: cell 0 is mid-evaporation (live water 1e-9 m3, below the
    // ZEROS2 floor, dry_reference_water_m3 = 2 m3 remembered from before it
    // went dry); cell 1 is ordinarily wet (4 m3, unaffected by the fix,
    // included to prove per-cell independence). A real solver-style
    // transfer of 14 g N from cell 0 to cell 1 (matching this file's own
    // pre-existing "round trip is exact" test's own transfer magnitude) is
    // applied between pack and unpack, proving this is not merely an inert
    // closed loop.
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 2);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 4;
    chemistry_state.cells[1].ammonia_mol_per_m3 = 5;
    chemistry_state.dry_reference_water_m3[0] = 2;
    const litter_water_m3 = [_]f64{ 1.0e-9, 4 };
    const cell_area_m2 = [_]f64{ 1, 1 };
    try refreshTransientFromChemistry(&chemistry_state, &gas_state, &litter_water_m3, &cell_area_m2, 14);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    try std.testing.expectApproxEqAbs(@as(f64, 112), gas_state.dissolved_mass_g[ammonia], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 280), gas_state.dissolved_mass_g[gas.species_count + ammonia], 1e-9);

    // A real transfer: 14 g N moves from cell 0's aqueous ammonia to
    // cell 1's, exactly as if the coupled gas/water solver had equilibrated
    // some of cell 0's now-correctly-available inventory toward cell 1's
    // phase (the bridge itself does not move mass between cells; this
    // simulates what a real intervening solve does to the shared mirror).
    gas_state.dissolved_mass_g[ammonia] -= 14;
    gas_state.dissolved_mass_g[gas.species_count + ammonia] += 14;

    try publishTransientToChemistry(&chemistry_state, &gas_state, &litter_water_m3, &cell_area_m2, 14, 1e-12, 1e-9);
    // Cell 0: (112 - 14) g N / 14 / dry_reference_water_m3(2) = 3.5 mol/m3 --
    // NOT (112 - 14) / 14 / live_water_m3(1e-9), which would be ~7.0e9.
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), chemistry_state.cells[0].ammonia_mol_per_m3, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.25), chemistry_state.cells[1].ammonia_mol_per_m3, 1e-9);
}

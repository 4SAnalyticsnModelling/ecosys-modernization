//! REDIST 5802--5841 surface-litter `SST=SSS+SSF+SSX+SSP` census.
//! Production uses these exact pseudo-ion coefficients for the accepted
//! domain and per-cell inventories and for runoff boundary loss. The 42
//! aqueous coordinates remain the legacy surface layout; modern bare
//! HPO4/H2PO4 coordinates are owned by the dedicated mineral carrier.

const std = @import("std");
const ions_module = @import("../surface/litter_ion_transport_senescence_apply.zig");
const overland = @import("../surface/overland_flow_litter_salt_update.zig");

pub const Species = overland.Species;

pub const FertilizerPools = struct {
    nh3_nonband_mol: f64,
    urea_nonband_mol: f64,
    no3_nonband_mol: f64,
    nh3_band_mol: f64,
    urea_band_mol: f64,
    no3_band_mol: f64,
    nh4_nonband_mol: f64,
    nh4_band_mol: f64,
};
pub const ExchangePools = struct {
    h_mol: f64,
    al_mol: f64,
    fe_mol: f64,
    ca_mol: f64,
    megagrams_mol: f64,
    na_mol: f64,
    k_mol: f64,
    carboxyl_hydrogen_mol: f64, // XHC(0)
    site_r_mol: f64,
    nh4_nonband_mol: f64,
    nh4_band_mol: f64,
    site_roh_mol: f64,
    site_roh2_mol: f64,
    hpo4_mol: f64,
    h2po4_mol: f64,
};
pub const PrecipitatePools = struct {
    caco3_mol: f64,
    caso4_mol: f64,
    alpo4_mol: f64,
    fepo4_mol: f64,
    cahpo4_mol: f64,
    aloh_mol: f64,
    feoh_mol: f64,
    cah2po4_mol: f64,
    apatite_mol: f64,
};
pub const Inventory = struct {
    landscape_phosphate_p_g: f64 = 0,
    landscape_ion_atoms_mol: f64 = 0,
    cell_ion_atoms_mol: f64 = 0,
};
pub const Components = struct {
    dissolved_mol: f64,
    fertilizer_mol: f64,
    exchange_mol: f64,
    precipitate_mol: f64,
    phosphate_p_g: f64,
};
pub const Result = struct { inventory: Inventory, components: Components };

pub fn isDailyFinalSubstep(hour: u8, current_substep: u32, final_substep: u32) !bool {
    if (hour < 1 or hour > 24 or final_substep == 0 or current_substep > final_substep)
        return error.InvalidLitterSaltInventorySchedule;
    return hour == 24 and current_substep == final_substep;
}
pub fn inventoryIsActive(mode: ions_module.SaltSimulationMode, hour: u8, current_substep: u32, final_substep: u32) !bool {
    return mode == .dynamic and try isDailyFinalSubstep(hour, current_substep, final_substep);
}

/// Exact REDIST `SSS` coefficient for one of the 42 surface aqueous
/// coordinates. This is the source model's pseudo-ion census, not an oxygen-
/// inclusive molecular atom count.
pub fn aqueousIonCount(species: Species) !f64 {
    if (!overland.routesSpecies(species))
        return error.NotLegacySurfaceLitterSaltSpecies;
    return @import("../../soil/solute/transport_species.zig").legacyIonCount(species);
}

pub fn isLegacyPhosphate(species: Species) bool {
    return switch (species) {
        .non_band_phosphate,
        .non_band_phosphoric_acid,
        .non_band_iron_hpo4,
        .non_band_iron_h2po4,
        .non_band_calcium_phosphate,
        .non_band_calcium_hpo4,
        .non_band_calcium_h2po4,
        .non_band_magnesium_hpo4,
        => true,
        else => false,
    };
}

/// Reduces the accepted generic runoff export to exact legacy `TIONOU`
/// units. Soil-only/dedicated coordinates must be zero here.
pub fn boundaryIonExportByCell(
    boundary_export_mol_by_cell_species: []const f64,
    cell_count: usize,
    species_stride: usize,
    output_mol_by_cell: []f64,
) !void {
    const amount_count = try std.math.mul(usize, cell_count, species_stride);
    if (cell_count == 0 or species_stride < overland.legacy_surface_species_count or
        boundary_export_mol_by_cell_species.len != amount_count or
        output_mol_by_cell.len != cell_count)
        return error.LitterSaltBoundaryDimensionMismatch;
    for (0..cell_count) |cell| _ = try boundaryIonExportCell(
        boundary_export_mol_by_cell_species[cell * species_stride ..][0..species_stride],
    );
    for (0..cell_count) |cell| output_mol_by_cell[cell] = boundaryIonExportCell(
        boundary_export_mol_by_cell_species[cell * species_stride ..][0..species_stride],
    ) catch unreachable;
}

fn boundaryIonExportCell(amounts: []const f64) !f64 {
    var total: f64 = 0;
    for (amounts, 0..) |amount, species_index| {
        if (!std.math.isFinite(amount) or amount < 0)
            return error.InvalidLitterSaltBoundaryExport;
        if (species_index < overland.legacy_surface_species_count) {
            total += amount * try aqueousIonCount(@enumFromInt(species_index));
            if (!std.math.isFinite(total))
                return error.InvalidLitterSaltBoundaryExport;
        } else if (amount != 0) return error.DedicatedSurfaceSpeciesInGenericSaltExport;
    }
    return total;
}

/// Accepted-hour publication into the existing daily landscape ion-output
/// owner. The whole grid is preflighted before mutation for retry safety.
pub fn accumulateAcceptedBoundary(
    cumulative_mol_by_cell: []f64,
    accepted_mol_by_cell: []const f64,
) !void {
    if (cumulative_mol_by_cell.len == 0 or
        cumulative_mol_by_cell.len != accepted_mol_by_cell.len)
        return error.LitterSaltBoundaryDimensionMismatch;
    for (cumulative_mol_by_cell, accepted_mol_by_cell) |current, accepted| {
        const next = current + accepted;
        inline for (.{ current, accepted, next }) |value|
            if (!std.math.isFinite(value)) return error.InvalidLitterSaltBoundaryExport;
        if (current < 0 or accepted < 0 or next < 0)
            return error.InvalidLitterSaltBoundaryExport;
    }
    for (cumulative_mol_by_cell, accepted_mol_by_cell) |*current, accepted|
        current.* += accepted;
}

fn validate(value: anytype) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field|
        if (!std.math.isFinite(@field(value, field.name))) return error.InvalidLitterSaltInventoryInput;
}

/// Exact standalone translation of redist.f lines 5802--5841.
pub fn accumulate(initial: Inventory, ions: ions_module.LitterIonPools, fertilizer: FertilizerPools, exchange: ExchangePools, precipitate: PrecipitatePools, phosphorus_g_mol: f64) !Result {
    try validate(initial);
    try validate(ions);
    try validate(fertilizer);
    try validate(exchange);
    try validate(precipitate);
    if (!std.math.isFinite(phosphorus_g_mol) or phosphorus_g_mol <= 0) return error.InvalidLitterSaltInventoryInput;
    const phosphate = phosphorus_g_mol * (ions.h0p_mol + ions.h3p_mol + ions.fe1p_mol + ions.fe2p_mol + ions.ca0p_mol + ions.ca1p_mol + ions.ca2p_mol + ions.mg1p_mol);
    const dissolved = ions.al_mol + ions.fe_mol + ions.h_mol + ions.ca_mol + ions.megagrams_mol + ions.na_mol + ions.ka_mol + ions.oh_mol + ions.so4_mol + ions.cl_mol + ions.co3_mol + ions.h0p_mol +
        2.0 * (ions.hco3_mol + ions.aloh1_mol + ions.als_mol + ions.feoh1_mol + ions.fes_mol + ions.cao_mol + ions.cac_mol + ions.cas_mol + ions.mgo_mol + ions.mgc_mol + ions.mgs_mol + ions.nac_mol + ions.nas_mol + ions.kas_mol + ions.ca0p_mol) +
        3.0 * (ions.aloh2_mol + ions.feoh2_mol + ions.cah_mol + ions.mgh_mol + ions.fe1p_mol + ions.ca1p_mol + ions.mg1p_mol) +
        4.0 * (ions.aloh3_mol + ions.feoh3_mol + ions.h3p_mol + ions.fe2p_mol + ions.ca2p_mol + ions.hysi_mol) +
        5.0 * (ions.aloh4_mol + ions.feoh4_mol);
    const fertilizer_total = fertilizer.nh3_nonband_mol + fertilizer.urea_nonband_mol + fertilizer.no3_nonband_mol + fertilizer.nh3_band_mol + fertilizer.urea_band_mol + fertilizer.no3_band_mol + 2.0 * (fertilizer.nh4_nonband_mol + fertilizer.nh4_band_mol);
    // Literal REDIST SSX: XOH2 appears twice.
    const exchange_total = exchange.h_mol + exchange.al_mol + exchange.fe_mol + exchange.ca_mol + exchange.megagrams_mol + exchange.na_mol + exchange.k_mol + exchange.carboxyl_hydrogen_mol + exchange.site_r_mol +
        2.0 * (exchange.nh4_nonband_mol + exchange.nh4_band_mol + exchange.site_roh_mol) +
        3.0 * (exchange.site_roh2_mol + exchange.site_roh2_mol + exchange.hpo4_mol) + 4.0 * exchange.h2po4_mol;
    const precipitate_total = 2.0 * (precipitate.caco3_mol + precipitate.caso4_mol + precipitate.alpo4_mol + precipitate.fepo4_mol) + 3.0 * precipitate.cahpo4_mol + 4.0 * (precipitate.aloh_mol + precipitate.feoh_mol) + 7.0 * precipitate.cah2po4_mol + 9.0 * precipitate.apatite_mol;
    const total = dissolved + fertilizer_total + exchange_total + precipitate_total;
    var inventory = initial;
    inventory.landscape_phosphate_p_g += phosphate;
    inventory.landscape_ion_atoms_mol += total;
    inventory.cell_ion_atoms_mol += total;
    try validate(inventory);
    return .{ .inventory = inventory, .components = .{ .dissolved_mol = dissolved, .fertilizer_mol = fertilizer_total, .exchange_mol = exchange_total, .precipitate_mol = precipitate_total, .phosphate_p_g = phosphate } };
}

test "REDIST daily litter salt preserves stoichiometric classes" {
    var ions = std.mem.zeroes(ions_module.LitterIonPools);
    ions.al_mol = 1;
    ions.hco3_mol = 1;
    ions.aloh2_mol = 1;
    ions.aloh3_mol = 1;
    ions.aloh4_mol = 1;
    ions.h0p_mol = 1;
    var fertilizer = std.mem.zeroes(FertilizerPools);
    fertilizer.nh3_nonband_mol = 1;
    fertilizer.nh4_nonband_mol = 1;
    var exchange = std.mem.zeroes(ExchangePools);
    exchange.site_roh2_mol = 1;
    var precipitate = std.mem.zeroes(PrecipitatePools);
    precipitate.caco3_mol = 1;
    precipitate.cahpo4_mol = 1;
    precipitate.aloh_mol = 1;
    precipitate.cah2po4_mol = 1;
    precipitate.apatite_mol = 1;
    const r = try accumulate(.{}, ions, fertilizer, exchange, precipitate, 31);
    try std.testing.expectEqual(@as(f64, 16), r.components.dissolved_mol);
    try std.testing.expectEqual(@as(f64, 3), r.components.fertilizer_mol);
    try std.testing.expectEqual(@as(f64, 6), r.components.exchange_mol);
    try std.testing.expectEqual(@as(f64, 25), r.components.precipitate_mol);
    try std.testing.expectEqual(@as(f64, 50), r.inventory.cell_ion_atoms_mol);
    try std.testing.expectEqual(@as(f64, 31), r.inventory.landscape_phosphate_p_g);
}

test "REDIST daily litter salt gate and failures" {
    try std.testing.expect(try inventoryIsActive(.dynamic, 24, 4, 4));
    try std.testing.expect(!try inventoryIsActive(.static_equilibrium, 24, 4, 4));
    try std.testing.expect(!try inventoryIsActive(.dynamic, 23, 4, 4));
    try std.testing.expectError(error.InvalidLitterSaltInventoryInput, accumulate(.{}, std.mem.zeroes(ions_module.LitterIonPools), std.mem.zeroes(FertilizerPools), std.mem.zeroes(ExchangePools), std.mem.zeroes(PrecipitatePools), 0));
}

test "accepted boundary census covers all 42 legacy coordinates exactly" {
    const stride = Species.count;
    var boundary = [_]f64{0} ** stride;
    for (0..overland.legacy_surface_species_count) |species_index|
        boundary[species_index] = 1;
    var output = [_]f64{0};
    try boundaryIonExportByCell(&boundary, 1, stride, &output);
    try std.testing.expectEqual(@as(f64, 97), output[0]);

    const before = output;
    boundary[@intFromEnum(Species.non_band_hpo4)] = 1;
    try std.testing.expectError(
        error.DedicatedSurfaceSpeciesInGenericSaltExport,
        boundaryIonExportByCell(&boundary, 1, stride, &output),
    );
    try std.testing.expectEqualDeep(before, output);
}

test "boundary accumulation and carboxyl census are atomic and complete" {
    var current = [_]f64{ 2, 3 };
    try accumulateAcceptedBoundary(&current, &.{ 5, 7 });
    try std.testing.expectEqualSlices(f64, &.{ 7, 10 }, &current);
    const before = current;
    try std.testing.expectError(
        error.InvalidLitterSaltBoundaryExport,
        accumulateAcceptedBoundary(&current, &.{ 1, std.math.nan(f64) }),
    );
    try std.testing.expectEqualDeep(before, current);

    var exchange = std.mem.zeroes(ExchangePools);
    exchange.carboxyl_hydrogen_mol = 2;
    const result = try accumulate(
        .{},
        std.mem.zeroes(ions_module.LitterIonPools),
        std.mem.zeroes(FertilizerPools),
        exchange,
        std.mem.zeroes(PrecipitatePools),
        31,
    );
    try std.testing.expectEqual(@as(f64, 2), result.components.exchange_mol);
    try std.testing.expectEqual(@as(f64, 2), result.inventory.cell_ion_atoms_mol);
}

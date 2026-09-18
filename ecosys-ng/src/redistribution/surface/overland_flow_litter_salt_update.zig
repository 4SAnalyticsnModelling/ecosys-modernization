const std = @import("std");
const transport_species = @import("../../soil/solute/transport_species.zig");

pub const Species = transport_species.AqueousSpecies;

/// The legacy surface owner is exactly the established coordinates 0..41.
/// Later soil-only bare and band phosphate coordinates must never be folded
/// into this range: HPO4/H2PO4 remain with the dedicated mineral owner.
pub const legacy_surface_species_count: usize = 42;

comptime {
    if (@intFromEnum(Species.aluminum) != 0 or
        @intFromEnum(Species.bicarbonate) != 11 or
        @intFromEnum(Species.aluminum_hydroxide_1) != 12 or
        @intFromEnum(Species.hydrogen_silicate) != 33 or
        @intFromEnum(Species.non_band_phosphate) != 34 or
        @intFromEnum(Species.non_band_magnesium_hpo4) != 41 or
        @intFromEnum(Species.band_phosphate) < legacy_surface_species_count or
        @intFromEnum(Species.non_band_hpo4) < legacy_surface_species_count)
        @compileError("legacy surface litter salt coordinate layout changed");
}

pub fn routesSpecies(species: Species) bool {
    return @intFromEnum(species) < legacy_surface_species_count;
}

/// Applies the signed simultaneous runoff change to the authoritative 0..41
/// extensive owner. The complete candidate is validated before the first
/// write, so a late invalid coordinate cannot retain an earlier cell update.
pub fn applyExtensiveChanges(
    original_mol: []const f64,
    signed_change_mol: []const f64,
    candidate_mol: []f64,
    cell_count: usize,
    species_stride: usize,
) !void {
    const amount_count = try std.math.mul(usize, cell_count, species_stride);
    if (cell_count == 0 or species_stride < legacy_surface_species_count or
        original_mol.len != amount_count or signed_change_mol.len != amount_count or
        candidate_mol.len != amount_count)
        return error.OverlandLitterSaltDimensionMismatch;
    for (0..cell_count) |cell| for (0..legacy_surface_species_count) |species_index| {
        const index = cell * species_stride + species_index;
        const original = original_mol[index];
        const change = signed_change_mol[index];
        const next = original + change;
        inline for (.{ original, change, next }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteOverlandLitterIonPool;
        if (original < 0 or next < 0)
            return error.NegativeOverlandLitterIonPool;
    };
    for (0..cell_count) |cell| for (0..legacy_surface_species_count) |species_index| {
        const index = cell * species_stride + species_index;
        candidate_mol[index] = original_mol[index] + signed_change_mol[index];
    };
}

/// Litter-layer ion speciation pool at layer 0 (mol).
/// All 42 species in REDIST source order (lines 5115--5156).
pub const LitterIonSpecies = struct {
    // Base ions
    h_mol: f64, // ZHY(0)
    oh_mol: f64, // ZOH(0)
    al_mol: f64, // ZAL(0)
    fe_mol: f64, // ZFE(0)
    ca_mol: f64, // ZCA(0)
    megagrams_mol: f64, // ZMG(0)
    na_mol: f64, // ZNA(0)
    ka_mol: f64, // ZKA(0)
    so4_mol: f64, // ZSO4(0)
    cl_mol: f64, // ZCL(0)
    co3_mol: f64, // ZCO3(0)
    hco3_mol: f64, // ZHCO3(0)
    // Al complexes
    aloh1_mol: f64, // ZALOH1(0)
    aloh2_mol: f64, // ZALOH2(0)
    aloh3_mol: f64, // ZALOH3(0)
    aloh4_mol: f64, // ZALOH4(0)
    als_mol: f64, // ZALS(0)
    // Fe complexes
    feoh1_mol: f64, // ZFEOH1(0)
    feoh2_mol: f64, // ZFEOH2(0)
    feoh3_mol: f64, // ZFEOH3(0)
    feoh4_mol: f64, // ZFEOH4(0)
    fes_mol: f64, // ZFES(0)
    // Ca complexes
    cao_mol: f64, // ZCAO(0)
    cac_mol: f64, // ZCAC(0)
    cah_mol: f64, // ZCAH(0)
    cas_mol: f64, // ZCAS(0)
    // Mg complexes
    mgo_mol: f64, // ZMGO(0)
    mgc_mol: f64, // ZMGC(0)
    mgh_mol: f64, // ZMGH(0)
    mgs_mol: f64, // ZMGS(0)
    // Na/K complexes
    nac_mol: f64, // ZNAC(0)
    nas_mol: f64, // ZNAS(0)
    kas_mol: f64, // ZKAS(0)
    // Si
    hysi_mol: f64, // ZHYSI(0)
    // Phosphate species
    h0p_mol: f64, // H0PO4(0)
    h3p_mol: f64, // H3PO4(0)
    fe1p_mol: f64, // ZFE1P(0)
    fe2p_mol: f64, // ZFE2P(0)
    ca0p_mol: f64, // ZCA0P(0)
    ca1p_mol: f64, // ZCA1P(0)
    ca2p_mol: f64, // ZCA2P(0)
    mg1p_mol: f64, // ZMG1P(0)
};

/// Signed overland-flow ion increments from runoff (mol per model step), for
/// the same 42 species. Positive values enter the surface-litter pool.
pub const OverlandIonFluxes = struct {
    h_mol: f64, // TQRHY
    oh_mol: f64, // TQROH
    al_mol: f64, // TQRAL
    fe_mol: f64, // TQRFE
    ca_mol: f64, // TQRCA
    megagrams_mol: f64, // TQRMG
    na_mol: f64, // TQRNA
    ka_mol: f64, // TQRKA
    so4_mol: f64, // TQRSO
    cl_mol: f64, // TQRCL
    co3_mol: f64, // TQRC3
    hco3_mol: f64, // TQRHC
    aloh1_mol: f64, // TQRAL1
    aloh2_mol: f64, // TQRAL2
    aloh3_mol: f64, // TQRAL3
    aloh4_mol: f64, // TQRAL4
    als_mol: f64, // TQRALS
    feoh1_mol: f64, // TQRFE1
    feoh2_mol: f64, // TQRFE2
    feoh3_mol: f64, // TQRFE3
    feoh4_mol: f64, // TQRFE4
    fes_mol: f64, // TQRFES
    cao_mol: f64, // TQRCAO
    cac_mol: f64, // TQRCAC
    cah_mol: f64, // TQRCAH
    cas_mol: f64, // TQRCAS
    mgo_mol: f64, // TQRMGO
    mgc_mol: f64, // TQRMGC
    mgh_mol: f64, // TQRMGH
    mgs_mol: f64, // TQRMGS
    nac_mol: f64, // TQRNAC
    nas_mol: f64, // TQRNAS
    kas_mol: f64, // TQRKAS
    hysi_mol: f64, // TQRHYS
    h0p_mol: f64, // TQRH0P
    h3p_mol: f64, // TQRH3P
    fe1p_mol: f64, // TQRF1P
    fe2p_mol: f64, // TQRF2P
    ca0p_mol: f64, // TQRC0P
    ca1p_mol: f64, // TQRC1P
    ca2p_mol: f64, // TQRC2P
    mg1p_mol: f64, // TQRM1P
};

/// Direct translation of redist.f lines 5114--5157 (ISALTG.NE.0 body).
///
/// Caller must check both `ABS(TQR) > ZEROS` and `ISALTG != 0` before invoking.
pub fn apply(pools: LitterIonSpecies, fluxes: OverlandIonFluxes) !LitterIonSpecies {
    inline for (@typeInfo(LitterIonSpecies).@"struct".fields) |field|
        if (!std.math.isFinite(@field(pools, field.name)))
            return error.InvalidOverlandLitterIonPool;
    inline for (@typeInfo(OverlandIonFluxes).@"struct".fields) |field|
        if (!std.math.isFinite(@field(fluxes, field.name)))
            return error.InvalidOverlandLitterIonFlux;

    // Source order: lines 5115--5156.
    const result = LitterIonSpecies{
        .h_mol = pools.h_mol + fluxes.h_mol,
        .oh_mol = pools.oh_mol + fluxes.oh_mol,
        .al_mol = pools.al_mol + fluxes.al_mol,
        .fe_mol = pools.fe_mol + fluxes.fe_mol,
        .ca_mol = pools.ca_mol + fluxes.ca_mol,
        .megagrams_mol = pools.megagrams_mol + fluxes.megagrams_mol,
        .na_mol = pools.na_mol + fluxes.na_mol,
        .ka_mol = pools.ka_mol + fluxes.ka_mol,
        .so4_mol = pools.so4_mol + fluxes.so4_mol,
        .cl_mol = pools.cl_mol + fluxes.cl_mol,
        .co3_mol = pools.co3_mol + fluxes.co3_mol,
        .hco3_mol = pools.hco3_mol + fluxes.hco3_mol,
        .aloh1_mol = pools.aloh1_mol + fluxes.aloh1_mol,
        .aloh2_mol = pools.aloh2_mol + fluxes.aloh2_mol,
        .aloh3_mol = pools.aloh3_mol + fluxes.aloh3_mol,
        .aloh4_mol = pools.aloh4_mol + fluxes.aloh4_mol,
        .als_mol = pools.als_mol + fluxes.als_mol,
        .feoh1_mol = pools.feoh1_mol + fluxes.feoh1_mol,
        .feoh2_mol = pools.feoh2_mol + fluxes.feoh2_mol,
        .feoh3_mol = pools.feoh3_mol + fluxes.feoh3_mol,
        .feoh4_mol = pools.feoh4_mol + fluxes.feoh4_mol,
        .fes_mol = pools.fes_mol + fluxes.fes_mol,
        .cao_mol = pools.cao_mol + fluxes.cao_mol,
        .cac_mol = pools.cac_mol + fluxes.cac_mol,
        .cah_mol = pools.cah_mol + fluxes.cah_mol,
        .cas_mol = pools.cas_mol + fluxes.cas_mol,
        .mgo_mol = pools.mgo_mol + fluxes.mgo_mol,
        .mgc_mol = pools.mgc_mol + fluxes.mgc_mol,
        .mgh_mol = pools.mgh_mol + fluxes.mgh_mol,
        .mgs_mol = pools.mgs_mol + fluxes.mgs_mol,
        .nac_mol = pools.nac_mol + fluxes.nac_mol,
        .nas_mol = pools.nas_mol + fluxes.nas_mol,
        .kas_mol = pools.kas_mol + fluxes.kas_mol,
        .hysi_mol = pools.hysi_mol + fluxes.hysi_mol,
        .h0p_mol = pools.h0p_mol + fluxes.h0p_mol,
        .h3p_mol = pools.h3p_mol + fluxes.h3p_mol,
        .fe1p_mol = pools.fe1p_mol + fluxes.fe1p_mol,
        .fe2p_mol = pools.fe2p_mol + fluxes.fe2p_mol,
        .ca0p_mol = pools.ca0p_mol + fluxes.ca0p_mol,
        .ca1p_mol = pools.ca1p_mol + fluxes.ca1p_mol,
        .ca2p_mol = pools.ca2p_mol + fluxes.ca2p_mol,
        .mg1p_mol = pools.mg1p_mol + fluxes.mg1p_mol,
    };
    inline for (@typeInfo(LitterIonSpecies).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteOverlandLitterIonPool;
    return result;
}

test "REDIST overland litter salt maps all 42 source species" {
    var fluxes = std.mem.zeroes(OverlandIonFluxes);
    var expected_value: f64 = 1.0;
    inline for (@typeInfo(OverlandIonFluxes).@"struct".fields) |field| {
        @field(fluxes, field.name) = expected_value;
        expected_value += 1.0;
    }
    const result = try apply(std.mem.zeroes(LitterIonSpecies), fluxes);
    inline for (@typeInfo(LitterIonSpecies).@"struct".fields) |field|
        try std.testing.expectEqual(@field(fluxes, field.name), @field(result, field.name));
}

test "REDIST overland litter salt preserves all unmodified species" {
    var pools = std.mem.zeroes(LitterIonSpecies);
    pools.al_mol = 3.0;
    const result = try apply(pools, std.mem.zeroes(OverlandIonFluxes));
    try std.testing.expectEqual(@as(f64, 3.0), result.al_mol);
    try std.testing.expectEqual(@as(f64, 0.0), result.ca_mol);
}

test "REDIST overland litter salt rejects non-finite pool" {
    var bad = std.mem.zeroes(LitterIonSpecies);
    bad.fe_mol = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidOverlandLitterIonPool,
        apply(bad, std.mem.zeroes(OverlandIonFluxes)),
    );
}

test "REDIST overland litter salt preserves signed removal" {
    var pools = std.mem.zeroes(LitterIonSpecies);
    pools.aloh4_mol = 3.0;
    pools.mg1p_mol = 2.0;
    var fluxes = std.mem.zeroes(OverlandIonFluxes);
    fluxes.aloh4_mol = -0.5;
    fluxes.mg1p_mol = -0.25;
    const result = try apply(pools, fluxes);
    try std.testing.expectEqual(@as(f64, 2.5), result.aloh4_mol);
    try std.testing.expectEqual(@as(f64, 1.75), result.mg1p_mol);
}

test "REDIST overland litter salt rejects non-finite flux" {
    var fluxes = std.mem.zeroes(OverlandIonFluxes);
    fluxes.fe2p_mol = std.math.inf(f64);
    try std.testing.expectError(
        error.InvalidOverlandLitterIonFlux,
        apply(std.mem.zeroes(LitterIonSpecies), fluxes),
    );
}

test "REDIST overland litter salt rejects arithmetic overflow" {
    var pools = std.mem.zeroes(LitterIonSpecies);
    pools.cah_mol = std.math.floatMax(f64);
    var fluxes = std.mem.zeroes(OverlandIonFluxes);
    fluxes.cah_mol = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteOverlandLitterIonPool, apply(pools, fluxes));
}

test "production surface layout preserves exactly the legacy 0 through 41 coordinates" {
    inline for (@typeInfo(Species).@"enum".fields) |field| {
        const species: Species = @enumFromInt(field.value);
        try std.testing.expectEqual(field.value < legacy_surface_species_count, routesSpecies(species));
    }
    try std.testing.expect(routesSpecies(.non_band_phosphate));
    try std.testing.expect(routesSpecies(.non_band_magnesium_hpo4));
    try std.testing.expect(!routesSpecies(.band_phosphate));
    try std.testing.expect(!routesSpecies(.non_band_hpo4));
    try std.testing.expect(!routesSpecies(.non_band_h2po4));
}

test "production extensive state update covers all 42 coordinates and is atomic" {
    const stride = Species.count;
    var original = [_]f64{0} ** (2 * stride);
    var change = [_]f64{0} ** (2 * stride);
    var candidate = [_]f64{7} ** (2 * stride);
    for (0..legacy_surface_species_count) |species_index| {
        original[species_index] = @floatFromInt(species_index + 1);
        change[species_index] = 0.5;
    }
    try applyExtensiveChanges(&original, &change, &candidate, 2, stride);
    for (0..legacy_surface_species_count) |species_index|
        try std.testing.expectEqual(original[species_index] + 0.5, candidate[species_index]);
    try std.testing.expectEqual(@as(f64, 7), candidate[@intFromEnum(Species.non_band_hpo4)]);

    const before = candidate;
    change[stride + legacy_surface_species_count - 1] = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteOverlandLitterIonPool,
        applyExtensiveChanges(&original, &change, &candidate, 2, stride),
    );
    try std.testing.expectEqualDeep(before, candidate);
}

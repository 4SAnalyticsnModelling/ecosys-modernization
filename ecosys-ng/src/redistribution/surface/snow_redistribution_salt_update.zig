// **A8a DISPOSITION: superseded by the bound runtime owner.**
// `snow_drift_routing.produceAndRoute` moves the full 41-coordinate dynamic
// snow-salt inventory with the accepted physical carrier and source/recipient
// closure. `snow_solute_transport.dynamic_salts_by_cell` is the live ISALTG
// owner, so the old flag conflation and missing-producer claims no longer apply.
// This scalar REDIST update remains only as a reference kernel.

const std = @import("std");

/// Snowpack ion species pool (mol). redist.f lines 5393--5433, 41 fields.
pub const SnowIonPools = struct {
    // Base ions
    al_mol: f64, // ZALW(1)
    fe_mol: f64, // ZFEW(1)
    h_mol: f64, // ZHYW(1)
    ca_mol: f64, // ZCAW(1)
    megagrams_mol: f64, // ZMGW(1)
    na_mol: f64, // ZNAW(1)
    ka_mol: f64, // ZKAW(1)
    oh_mol: f64, // ZOHW(1)
    so4_mol: f64, // ZSO4W(1)
    cl_mol: f64, // ZCLW(1)
    co3_mol: f64, // ZCO3W(1)
    hco3_mol: f64, // ZHCO3W(1)
    // Al complexes
    aloh1_mol: f64, // ZALH1W(1)
    aloh2_mol: f64, // ZALH2W(1)
    aloh3_mol: f64, // ZALH3W(1)
    aloh4_mol: f64, // ZALH4W(1)
    als_mol: f64, // ZALSW(1)
    // Fe complexes
    feoh1_mol: f64, // ZFEH1W(1)
    feoh2_mol: f64, // ZFEH2W(1)
    feoh3_mol: f64, // ZFEH3W(1)
    feoh4_mol: f64, // ZFEH4W(1)
    fes_mol: f64, // ZFESW(1)
    // Ca complexes
    cao_mol: f64, // ZCAOW(1)
    cac_mol: f64, // ZCACW(1)
    cah_mol: f64, // ZCAHW(1)
    cas_mol: f64, // ZCASW(1)
    // Mg complexes
    mgo_mol: f64, // ZMGOW(1)
    mgc_mol: f64, // ZMGCW(1)
    mgh_mol: f64, // ZMGHW(1)
    mgs_mol: f64, // ZMGSW(1)
    // Na/K complexes
    nac_mol: f64, // ZNACW(1)
    nas_mol: f64, // ZNASW(1)
    kas_mol: f64, // ZKASW(1)
    // Phosphate species
    h0p_mol: f64, // H0PO4W(1)
    h3p_mol: f64, // H3PO4W(1)
    fe1p_mol: f64, // ZFE1PW(1)
    fe2p_mol: f64, // ZFE2PW(1)
    ca0p_mol: f64, // ZCA0PW(1)
    ca1p_mol: f64, // ZCA1PW(1)
    ca2p_mol: f64, // ZCA2PW(1)
    mg1p_mol: f64, // ZMG1PW(1)
};

/// Signed snow-overland ion increments (mol per model step). Same 41 fields.
pub const SnowIonFluxes = struct {
    al_mol: f64, // TQSAL
    fe_mol: f64, // TQSFE
    h_mol: f64, // TQSHY
    ca_mol: f64, // TQSCA
    megagrams_mol: f64, // TQSMG
    na_mol: f64, // TQSNA
    ka_mol: f64, // TQSKA
    oh_mol: f64, // TQSOH
    so4_mol: f64, // TQSSO
    cl_mol: f64, // TQSCL
    co3_mol: f64, // TQSC3
    hco3_mol: f64, // TQSHC
    aloh1_mol: f64, // TQSAL1
    aloh2_mol: f64, // TQSAL2
    aloh3_mol: f64, // TQSAL3
    aloh4_mol: f64, // TQSAL4
    als_mol: f64, // TQSALS
    feoh1_mol: f64, // TQSFE1
    feoh2_mol: f64, // TQSFE2
    feoh3_mol: f64, // TQSFE3
    feoh4_mol: f64, // TQSFE4
    fes_mol: f64, // TQSFES
    cao_mol: f64, // TQSCAO
    cac_mol: f64, // TQSCAC
    cah_mol: f64, // TQSCAH
    cas_mol: f64, // TQSCAS
    mgo_mol: f64, // TQSMGO
    mgc_mol: f64, // TQSMGC
    mgh_mol: f64, // TQSMGH
    mgs_mol: f64, // TQSMGS
    nac_mol: f64, // TQSNAC
    nas_mol: f64, // TQSNAS
    kas_mol: f64, // TQSKAS
    h0p_mol: f64, // TQSH0P
    h3p_mol: f64, // TQSH3P
    fe1p_mol: f64, // TQSF1P
    fe2p_mol: f64, // TQSF2P
    ca0p_mol: f64, // TQSC0P
    ca1p_mol: f64, // TQSC1P
    ca2p_mol: f64, // TQSC2P
    mg1p_mol: f64, // TQSM1P
};

pub const SaltSimulationMode = enum {
    static_equilibrium,
    dynamic,
};

/// Exact nested REDIST gates at lines 5356 and 5392.
pub fn redistributionIsActive(
    net_snow_redistribution_m3: f64,
    salt_mode: SaltSimulationMode,
) !bool {
    if (!std.math.isFinite(net_snow_redistribution_m3))
        return error.InvalidSnowSaltGateInput;
    return net_snow_redistribution_m3 != 0.0 and salt_mode == .dynamic;
}

/// Direct translation of redist.f lines 5393--5433 (ISALTG.NE.0 body inside TQS gate).
///
/// Caller must check both TQS != 0.0 and ISALTG != 0 before invoking.
pub fn update(pools: SnowIonPools, fluxes: SnowIonFluxes) !SnowIonPools {
    inline for (@typeInfo(SnowIonPools).@"struct".fields) |field|
        if (!std.math.isFinite(@field(pools, field.name)))
            return error.InvalidSnowIonPool;
    inline for (@typeInfo(SnowIonFluxes).@"struct".fields) |field|
        if (!std.math.isFinite(@field(fluxes, field.name)))
            return error.InvalidSnowIonFlux;

    const result = SnowIonPools{
        .al_mol = pools.al_mol + fluxes.al_mol,
        .fe_mol = pools.fe_mol + fluxes.fe_mol,
        .h_mol = pools.h_mol + fluxes.h_mol,
        .ca_mol = pools.ca_mol + fluxes.ca_mol,
        .megagrams_mol = pools.megagrams_mol + fluxes.megagrams_mol,
        .na_mol = pools.na_mol + fluxes.na_mol,
        .ka_mol = pools.ka_mol + fluxes.ka_mol,
        .oh_mol = pools.oh_mol + fluxes.oh_mol,
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
        .h0p_mol = pools.h0p_mol + fluxes.h0p_mol,
        .h3p_mol = pools.h3p_mol + fluxes.h3p_mol,
        .fe1p_mol = pools.fe1p_mol + fluxes.fe1p_mol,
        .fe2p_mol = pools.fe2p_mol + fluxes.fe2p_mol,
        .ca0p_mol = pools.ca0p_mol + fluxes.ca0p_mol,
        .ca1p_mol = pools.ca1p_mol + fluxes.ca1p_mol,
        .ca2p_mol = pools.ca2p_mol + fluxes.ca2p_mol,
        .mg1p_mol = pools.mg1p_mol + fluxes.mg1p_mol,
    };
    inline for (@typeInfo(SnowIonPools).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteSnowIonPool;
    return result;
}

test "REDIST snow salt redistribution accumulates base cations" {
    var fluxes = std.mem.zeroes(SnowIonFluxes);
    fluxes.ca_mol = 1.0;
    fluxes.megagrams_mol = 0.5;
    const result = try update(std.mem.zeroes(SnowIonPools), fluxes);
    try std.testing.expectApproxEqRel(@as(f64, 1.0), result.ca_mol, 1.0e-15);
    try std.testing.expectApproxEqRel(@as(f64, 0.5), result.megagrams_mol, 1.0e-15);
}

test "REDIST snow salt redistribution accumulates phosphate species" {
    var fluxes = std.mem.zeroes(SnowIonFluxes);
    fluxes.h0p_mol = 0.1;
    fluxes.ca1p_mol = 0.05;
    const result = try update(std.mem.zeroes(SnowIonPools), fluxes);
    try std.testing.expectApproxEqRel(@as(f64, 0.1), result.h0p_mol, 1.0e-15);
    try std.testing.expectApproxEqRel(@as(f64, 0.05), result.ca1p_mol, 1.0e-15);
}

test "REDIST snow salt preserves prior pool state" {
    var pools = std.mem.zeroes(SnowIonPools);
    pools.al_mol = 3.0;
    const result = try update(pools, std.mem.zeroes(SnowIonFluxes));
    try std.testing.expectEqual(@as(f64, 3.0), result.al_mol);
    try std.testing.expectEqual(@as(f64, 0.0), result.ca_mol);
}

test "REDIST snow salt rejects non-finite flux" {
    var bad = std.mem.zeroes(SnowIonFluxes);
    bad.so4_mol = std.math.inf(f64);
    try std.testing.expectError(
        error.InvalidSnowIonFlux,
        update(std.mem.zeroes(SnowIonPools), bad),
    );
}

test "REDIST snow salt redistribution maps all 41 source species" {
    var fluxes = std.mem.zeroes(SnowIonFluxes);
    var expected_value: f64 = 1.0;
    inline for (@typeInfo(SnowIonFluxes).@"struct".fields) |field| {
        @field(fluxes, field.name) = expected_value;
        expected_value += 1.0;
    }
    const result = try update(std.mem.zeroes(SnowIonPools), fluxes);
    inline for (@typeInfo(SnowIonPools).@"struct".fields) |field|
        try std.testing.expectEqual(@field(fluxes, field.name), @field(result, field.name));
}

test "REDIST snow salt nested gate requires nonzero snow and dynamic salts" {
    try std.testing.expect(try redistributionIsActive(1.0e-300, .dynamic));
    try std.testing.expect(try redistributionIsActive(-1.0e-300, .dynamic));
    try std.testing.expect(!try redistributionIsActive(0.0, .dynamic));
    try std.testing.expect(!try redistributionIsActive(1.0, .static_equilibrium));
    try std.testing.expectError(
        error.InvalidSnowSaltGateInput,
        redistributionIsActive(std.math.nan(f64), .dynamic),
    );
}

test "REDIST snow salt preserves signed outward redistribution" {
    var pools = std.mem.zeroes(SnowIonPools);
    pools.aloh3_mol = 4.0;
    pools.mg1p_mol = 3.0;
    var fluxes = std.mem.zeroes(SnowIonFluxes);
    fluxes.aloh3_mol = -1.5;
    fluxes.mg1p_mol = -0.5;
    const result = try update(pools, fluxes);
    try std.testing.expectEqual(@as(f64, 2.5), result.aloh3_mol);
    try std.testing.expectEqual(@as(f64, 2.5), result.mg1p_mol);
}

test "REDIST snow salt rejects non-finite pool and overflow" {
    var pools = std.mem.zeroes(SnowIonPools);
    pools.fes_mol = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidSnowIonPool,
        update(pools, std.mem.zeroes(SnowIonFluxes)),
    );

    pools = std.mem.zeroes(SnowIonPools);
    pools.ca2p_mol = std.math.floatMax(f64);
    var fluxes = std.mem.zeroes(SnowIonFluxes);
    fluxes.ca2p_mol = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteSnowIonPool, update(pools, fluxes));
}

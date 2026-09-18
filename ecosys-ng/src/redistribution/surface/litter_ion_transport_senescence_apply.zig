const std = @import("std");

/// Litter-layer ion speciation pool at layer 0 (mol). 42 species.
pub const LitterIonPools = struct {
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
    aloh1_mol: f64, // ZALOH1(0)
    aloh2_mol: f64, // ZALOH2(0)
    aloh3_mol: f64, // ZALOH3(0)
    aloh4_mol: f64, // ZALOH4(0)
    als_mol: f64, // ZALS(0)
    feoh1_mol: f64, // ZFEOH1(0)
    feoh2_mol: f64, // ZFEOH2(0)
    feoh3_mol: f64, // ZFEOH3(0)
    feoh4_mol: f64, // ZFEOH4(0)
    fes_mol: f64, // ZFES(0)
    cao_mol: f64, // ZCAO(0)
    cac_mol: f64, // ZCAC(0)
    cah_mol: f64, // ZCAH(0)
    cas_mol: f64, // ZCAS(0)
    mgo_mol: f64, // ZMGO(0)
    mgc_mol: f64, // ZMGC(0)
    mgh_mol: f64, // ZMGH(0)
    mgs_mol: f64, // ZMGS(0)
    nac_mol: f64, // ZNAC(0)
    nas_mol: f64, // ZNAS(0)
    kas_mol: f64, // ZKAS(0)
    hysi_mol: f64, // ZHYSI(0)
    h0p_mol: f64, // H0PO4(0)
    h3p_mol: f64, // H3PO4(0)
    fe1p_mol: f64, // ZFE1P(0)
    fe2p_mol: f64, // ZFE2P(0)
    ca0p_mol: f64, // ZCA0P(0)
    ca1p_mol: f64, // ZCA1P(0)
    ca2p_mol: f64, // ZCA2P(0)
    mg1p_mol: f64, // ZMG1P(0)
};

/// Transport fluxes from trnsfrs.f at face index 3 (litter-mineral interface).
/// redist.f lines 5734--5776: XHYFLS(3,0)/XOHFLS(3,0)/... (mol step-1).
pub const TransportFluxes = struct {
    h_mol: f64, // XHYFLS(3,0)
    oh_mol: f64, // XOHFLS(3,0)
    al_mol: f64, // XALFLS(3,0)
    fe_mol: f64, // XFEFLS(3,0)
    ca_mol: f64, // XCAFLS(3,0)
    megagrams_mol: f64, // XMGFLS(3,0)
    na_mol: f64, // XNAFLS(3,0)
    ka_mol: f64, // XKAFLS(3,0)
    so4_mol: f64, // XSOFLS(3,0)
    cl_mol: f64, // XCLFLS(3,0)
    co3_mol: f64, // XC3FLS(3,0)
    hco3_mol: f64, // XHCFLS(3,0)
    aloh1_mol: f64, // XAL1FS(3,0)
    aloh2_mol: f64, // XAL2FS(3,0)
    aloh3_mol: f64, // XAL3FS(3,0)
    aloh4_mol: f64, // XAL4FS(3,0)
    als_mol: f64, // XALSFS(3,0)
    feoh1_mol: f64, // XFE1FS(3,0)
    feoh2_mol: f64, // XFE2FS(3,0)
    feoh3_mol: f64, // XFE3FS(3,0)
    feoh4_mol: f64, // XFE4FS(3,0)
    fes_mol: f64, // XFESFS(3,0)
    cao_mol: f64, // XCAOFS(3,0)
    cac_mol: f64, // XCACFS(3,0)
    cah_mol: f64, // XCAHFS(3,0)
    cas_mol: f64, // XCASFS(3,0)
    mgo_mol: f64, // XMGOFS(3,0)
    mgc_mol: f64, // XMGCFS(3,0)
    mgh_mol: f64, // XMGHFS(3,0)
    mgs_mol: f64, // XMGSFS(3,0)
    nac_mol: f64, // XNACFS(3,0)
    nas_mol: f64, // XNASFS(3,0)
    kas_mol: f64, // XKASFS(3,0)
    hysi_mol: f64, // XHYSIS(3,0)
    h0p_mol: f64, // XH0PFS(3,0)
    h3p_mol: f64, // XH3PFS(3,0)
    fe1p_mol: f64, // XF1PFS(3,0)
    fe2p_mol: f64, // XF2PFS(3,0)
    ca0p_mol: f64, // XC0PFS(3,0)
    ca1p_mol: f64, // XC1PFS(3,0)
    ca2p_mol: f64, // XC2PFS(3,0)
    mg1p_mol: f64, // XM1PFS(3,0)
};

/// Plant senescence ion additions to litter (mol step-1).
/// Only the species that appear in the senescence terms (REDIST 5736-5742).
pub const SenescenceFluxes = struct {
    al_mol: f64, // ALSNT(0)
    fe_mol: f64, // FESNT(0)
    ca_mol: f64, // CASNT(0)
    megagrams_mol: f64, // GMSNT(0)
    na_mol: f64, // ANSNT(0)
    ka_mol: f64, // AKSNT(0)
    so4_mol: f64, // SOSNT(0)
    cl_mol: f64, // CLSNT(0)
};

/// Chemical transformation increments (TRCO3, TRHCO) from solute.f.
pub const TransformationFluxes = struct {
    co3_mol: f64, // TRCO3(0)
    hco3_mol: f64, // TRHCO(0)
    so4_mol: f64, // TRSO4(0)
};

pub const Result = struct {
    pools: LitterIonPools,
    /// UCO2S increment: 12*(ZCO3+ZHCO3) contribution (g C).
    uco2s_increment_gC: f64,
};

pub const SaltSimulationMode = enum { static_equilibrium, dynamic };

/// Exact redist.f line 5733 gate.
pub fn updateIsActive(mode: SaltSimulationMode) bool {
    return mode == .dynamic;
}

/// Direct translation of redist.f lines 5733--5777 (ISALTG.NE.0 block).
///
/// Caller must check ISALTG != 0 before invoking.
pub fn apply(
    pools: LitterIonPools,
    tr: TransportFluxes,
    sn: SenescenceFluxes,
    tf: TransformationFluxes,
    carbon_g_mol: f64,
) !Result {
    inline for (@typeInfo(LitterIonPools).@"struct".fields) |field|
        if (!std.math.isFinite(@field(pools, field.name)))
            return error.InvalidLitterIonPool;
    inline for (@typeInfo(TransportFluxes).@"struct".fields) |field|
        if (!std.math.isFinite(@field(tr, field.name)))
            return error.InvalidTransportFlux;
    inline for (@typeInfo(SenescenceFluxes).@"struct".fields) |field|
        if (!std.math.isFinite(@field(sn, field.name)))
            return error.InvalidSenescenceFlux;
    inline for (@typeInfo(TransformationFluxes).@"struct".fields) |field|
        if (!std.math.isFinite(@field(tf, field.name)))
            return error.InvalidTransformationFlux;
    if (!std.math.isFinite(carbon_g_mol) or carbon_g_mol <= 0.0)
        return error.InvalidCarbonMolarMass;

    const new_pools = LitterIonPools{
        .h_mol = pools.h_mol + tr.h_mol,
        .oh_mol = pools.oh_mol + tr.oh_mol,
        .al_mol = pools.al_mol + tr.al_mol + sn.al_mol,
        .fe_mol = pools.fe_mol + tr.fe_mol + sn.fe_mol,
        .ca_mol = pools.ca_mol + tr.ca_mol + sn.ca_mol,
        .megagrams_mol = pools.megagrams_mol + tr.megagrams_mol + sn.megagrams_mol,
        .na_mol = pools.na_mol + tr.na_mol + sn.na_mol,
        .ka_mol = pools.ka_mol + tr.ka_mol + sn.ka_mol,
        .so4_mol = pools.so4_mol + tr.so4_mol + tf.so4_mol + sn.so4_mol,
        .cl_mol = pools.cl_mol + tr.cl_mol + sn.cl_mol,
        .co3_mol = pools.co3_mol + tf.co3_mol + tr.co3_mol,
        .hco3_mol = pools.hco3_mol + tr.hco3_mol + tf.hco3_mol,
        .aloh1_mol = pools.aloh1_mol + tr.aloh1_mol,
        .aloh2_mol = pools.aloh2_mol + tr.aloh2_mol,
        .aloh3_mol = pools.aloh3_mol + tr.aloh3_mol,
        .aloh4_mol = pools.aloh4_mol + tr.aloh4_mol,
        .als_mol = pools.als_mol + tr.als_mol,
        .feoh1_mol = pools.feoh1_mol + tr.feoh1_mol,
        .feoh2_mol = pools.feoh2_mol + tr.feoh2_mol,
        .feoh3_mol = pools.feoh3_mol + tr.feoh3_mol,
        .feoh4_mol = pools.feoh4_mol + tr.feoh4_mol,
        .fes_mol = pools.fes_mol + tr.fes_mol,
        .cao_mol = pools.cao_mol + tr.cao_mol,
        .cac_mol = pools.cac_mol + tr.cac_mol,
        .cah_mol = pools.cah_mol + tr.cah_mol,
        .cas_mol = pools.cas_mol + tr.cas_mol,
        .mgo_mol = pools.mgo_mol + tr.mgo_mol,
        .mgc_mol = pools.mgc_mol + tr.mgc_mol,
        .mgh_mol = pools.mgh_mol + tr.mgh_mol,
        .mgs_mol = pools.mgs_mol + tr.mgs_mol,
        .nac_mol = pools.nac_mol + tr.nac_mol,
        .nas_mol = pools.nas_mol + tr.nas_mol,
        .kas_mol = pools.kas_mol + tr.kas_mol,
        .hysi_mol = pools.hysi_mol + tr.hysi_mol,
        .h0p_mol = pools.h0p_mol + tr.h0p_mol,
        .h3p_mol = pools.h3p_mol + tr.h3p_mol,
        .fe1p_mol = pools.fe1p_mol + tr.fe1p_mol,
        .fe2p_mol = pools.fe2p_mol + tr.fe2p_mol,
        .ca0p_mol = pools.ca0p_mol + tr.ca0p_mol,
        .ca1p_mol = pools.ca1p_mol + tr.ca1p_mol,
        .ca2p_mol = pools.ca2p_mol + tr.ca2p_mol,
        .mg1p_mol = pools.mg1p_mol + tr.mg1p_mol,
    };

    inline for (@typeInfo(LitterIonPools).@"struct".fields) |field|
        if (!std.math.isFinite(@field(new_pools, field.name)))
            return error.NonFiniteLitterIonPool;

    // Line 5777: UCO2S += 12*(ZCO3+ZHCO3)
    const uco2s_inc = carbon_g_mol * (new_pools.co3_mol + new_pools.hco3_mol);
    if (!std.math.isFinite(uco2s_inc)) return error.NonFiniteLitterIonCarbonInventory;
    return Result{ .pools = new_pools, .uco2s_increment_gC = uco2s_inc };
}

test "REDIST litter ion transport applies transport flux to all species" {
    var tr = std.mem.zeroes(TransportFluxes);
    tr.ca_mol = 1.0;
    tr.h0p_mol = 0.5;
    const result = try apply(
        std.mem.zeroes(LitterIonPools),
        tr,
        std.mem.zeroes(SenescenceFluxes),
        std.mem.zeroes(TransformationFluxes),
        12.0,
    );
    try std.testing.expectApproxEqRel(@as(f64, 1.0), result.pools.ca_mol, 1.0e-15);
    try std.testing.expectApproxEqRel(@as(f64, 0.5), result.pools.h0p_mol, 1.0e-15);
}

test "REDIST litter ion senescence adds to base cations and SO4/Cl" {
    var sn = std.mem.zeroes(SenescenceFluxes);
    sn.ca_mol = 2.0;
    sn.so4_mol = 0.3;
    const result = try apply(
        std.mem.zeroes(LitterIonPools),
        std.mem.zeroes(TransportFluxes),
        sn,
        std.mem.zeroes(TransformationFluxes),
        12.0,
    );
    try std.testing.expectApproxEqRel(@as(f64, 2.0), result.pools.ca_mol, 1.0e-15);
    try std.testing.expectApproxEqRel(@as(f64, 0.3), result.pools.so4_mol, 1.0e-15);
}

test "REDIST litter ion UCO2S increment is 12*(CO3+HCO3)" {
    var tr = std.mem.zeroes(TransportFluxes);
    tr.co3_mol = 1.0;
    tr.hco3_mol = 2.0;
    const result = try apply(
        std.mem.zeroes(LitterIonPools),
        tr,
        std.mem.zeroes(SenescenceFluxes),
        std.mem.zeroes(TransformationFluxes),
        12.0,
    );
    try std.testing.expectApproxEqRel(@as(f64, 36.0), result.uco2s_increment_gC, 1.0e-15);
}

test "REDIST litter ion rejects non-finite transport flux" {
    var bad = std.mem.zeroes(TransportFluxes);
    bad.al_mol = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidTransportFlux,
        apply(
            std.mem.zeroes(LitterIonPools),
            bad,
            std.mem.zeroes(SenescenceFluxes),
            std.mem.zeroes(TransformationFluxes),
            12.0,
        ),
    );
}

test "REDIST litter ion transport maps all 42 species" {
    var fluxes = std.mem.zeroes(TransportFluxes);
    var value: f64 = 1.0;
    inline for (@typeInfo(TransportFluxes).@"struct".fields) |field| {
        @field(fluxes, field.name) = value;
        value += 1.0;
    }
    const result = try apply(std.mem.zeroes(LitterIonPools), fluxes, std.mem.zeroes(SenescenceFluxes), std.mem.zeroes(TransformationFluxes), 12.0);
    inline for (@typeInfo(LitterIonPools).@"struct".fields) |field|
        try std.testing.expectEqual(@field(fluxes, field.name), @field(result.pools, field.name));
}

test "REDIST litter ion source-specific multi-term order" {
    var transport = std.mem.zeroes(TransportFluxes);
    transport.so4_mol = 2;
    transport.co3_mol = 3;
    transport.hco3_mol = 4;
    var senescence = std.mem.zeroes(SenescenceFluxes);
    senescence.so4_mol = 5;
    var transformation = std.mem.zeroes(TransformationFluxes);
    transformation.so4_mol = 7;
    transformation.co3_mol = 11;
    transformation.hco3_mol = 13;
    const result = try apply(std.mem.zeroes(LitterIonPools), transport, senescence, transformation, 10.0);
    try std.testing.expectEqual(@as(f64, 14), result.pools.so4_mol);
    try std.testing.expectEqual(@as(f64, 14), result.pools.co3_mol);
    try std.testing.expectEqual(@as(f64, 17), result.pools.hco3_mol);
    try std.testing.expectEqual(@as(f64, 310), result.uco2s_increment_gC);
}

test "REDIST litter ion gate and runtime carbon mass" {
    try std.testing.expect(updateIsActive(.dynamic));
    try std.testing.expect(!updateIsActive(.static_equilibrium));
    try std.testing.expectError(error.InvalidCarbonMolarMass, apply(
        std.mem.zeroes(LitterIonPools),
        std.mem.zeroes(TransportFluxes),
        std.mem.zeroes(SenescenceFluxes),
        std.mem.zeroes(TransformationFluxes),
        0.0,
    ));
}

test "REDIST litter ion rejects pool and carbon inventory overflow" {
    var pools = std.mem.zeroes(LitterIonPools);
    pools.al_mol = std.math.floatMax(f64);
    var transport = std.mem.zeroes(TransportFluxes);
    transport.al_mol = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteLitterIonPool, apply(pools, transport, std.mem.zeroes(SenescenceFluxes), std.mem.zeroes(TransformationFluxes), 12.0));

    pools = std.mem.zeroes(LitterIonPools);
    pools.co3_mol = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteLitterIonCarbonInventory, apply(pools, std.mem.zeroes(TransportFluxes), std.mem.zeroes(SenescenceFluxes), std.mem.zeroes(TransformationFluxes), std.math.floatMax(f64)));
}

// **A8a DISPOSITION: superseded by the bound runtime owner.**
// `snow_drift_routing.produceAndRoute` now translates WATSUB 3876--4100 and
// publishes the REDIST snow redistribution of all non-salt species directly in
// the authoritative layer-major state. Production calls that consolidated
// transaction from `hourly_heat_water_solute.advanceSnowDrift`; this scalar
// `TQS` update remains a reference kernel and must not become a second writer.

const std = @import("std");

/// Snowpack dissolved gas and nutrient pools (g).
pub const SnowSolutePools = struct {
    /// CO2W(1). Aqueous CO2 (g C).
    co2_g: f64,
    /// CH4W(1). Aqueous CH4 (g C).
    ch4_g: f64,
    /// OXYW(1). Aqueous O2 (g O).
    o2_g: f64,
    /// ZNGW(1). Aqueous N2 (g N).
    n2_g: f64,
    /// ZN2W(1). Aqueous N2O (g N).
    n2o_g: f64,
    /// ZN4W(1). NH4 (g N).
    nh4_g: f64,
    /// ZN3W(1). NH3 (g N).
    nh3_g: f64,
    /// ZNOW(1). NO3 (g N).
    no3_g: f64,
    /// Z1PW(1). HPO4 (g P).
    hpo4_g: f64,
    /// ZHPW(1). H2PO4 (g P).
    h2po4_g: f64,
};

/// Signed snow overland-solute increments (grams of the named element per
/// model step). Positive values enter snowpack layer 1.
pub const SnowSoluteFluxes = struct {
    /// TCOQSS.
    co2_g: f64,
    /// TCHQSS.
    ch4_g: f64,
    /// TOXQSS.
    o2_g: f64,
    /// TNGQSS.
    n2_g: f64,
    /// TN2QSS.
    n2o_g: f64,
    /// TN4QSS.
    nh4_g: f64,
    /// TN3QSS.
    nh3_g: f64,
    /// TNOQSS.
    no3_g: f64,
    /// TP1QSS.
    hpo4_g: f64,
    /// TPOQSS.
    h2po4_g: f64,
};

/// Exact redist.f line 5356 gate. Any finite nonzero net snow redistribution,
/// positive or negative, executes the branch.
pub fn redistributionIsActive(net_snow_redistribution_m3: f64) !bool {
    if (!std.math.isFinite(net_snow_redistribution_m3))
        return error.InvalidSnowRedistributionGateInput;
    return net_snow_redistribution_m3 != 0.0;
}

/// Direct translation of redist.f lines 5357--5366.
///
/// Caller must check TQS != 0.0 before invoking.
pub fn update(pools: SnowSolutePools, fluxes: SnowSoluteFluxes) !SnowSolutePools {
    inline for (@typeInfo(SnowSolutePools).@"struct".fields) |field|
        if (!std.math.isFinite(@field(pools, field.name)))
            return error.InvalidSnowSolutePool;
    inline for (@typeInfo(SnowSoluteFluxes).@"struct".fields) |field|
        if (!std.math.isFinite(@field(fluxes, field.name)))
            return error.InvalidSnowSoluteFlux;

    const result = SnowSolutePools{
        .co2_g = pools.co2_g + fluxes.co2_g,
        .ch4_g = pools.ch4_g + fluxes.ch4_g,
        .o2_g = pools.o2_g + fluxes.o2_g,
        .n2_g = pools.n2_g + fluxes.n2_g,
        .n2o_g = pools.n2o_g + fluxes.n2o_g,
        .nh4_g = pools.nh4_g + fluxes.nh4_g,
        .nh3_g = pools.nh3_g + fluxes.nh3_g,
        .no3_g = pools.no3_g + fluxes.no3_g,
        .hpo4_g = pools.hpo4_g + fluxes.hpo4_g,
        .h2po4_g = pools.h2po4_g + fluxes.h2po4_g,
    };
    inline for (@typeInfo(SnowSolutePools).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteSnowSolutePool;
    return result;
}

test "REDIST snow solute redistribution updates all 10 pools" {
    var fluxes = std.mem.zeroes(SnowSoluteFluxes);
    var expected_value: f64 = 1.0;
    inline for (@typeInfo(SnowSoluteFluxes).@"struct".fields) |field| {
        @field(fluxes, field.name) = expected_value;
        expected_value += 1.0;
    }
    const result = try update(std.mem.zeroes(SnowSolutePools), fluxes);
    inline for (@typeInfo(SnowSolutePools).@"struct".fields) |field|
        try std.testing.expectEqual(@field(fluxes, field.name), @field(result, field.name));
}

test "REDIST snow solute preserves prior pool state" {
    var pools = std.mem.zeroes(SnowSolutePools);
    pools.hpo4_g = 2.0;
    const result = try update(pools, std.mem.zeroes(SnowSoluteFluxes));
    try std.testing.expectEqual(@as(f64, 2.0), result.hpo4_g);
}

test "REDIST snow solute rejects non-finite flux" {
    var bad = std.mem.zeroes(SnowSoluteFluxes);
    bad.n2o_g = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidSnowSoluteFlux,
        update(std.mem.zeroes(SnowSolutePools), bad),
    );
}

test "REDIST snow redistribution gate preserves exact nonzero comparison" {
    try std.testing.expect(!try redistributionIsActive(0.0));
    try std.testing.expect(!try redistributionIsActive(-0.0));
    try std.testing.expect(try redistributionIsActive(1.0e-300));
    try std.testing.expect(try redistributionIsActive(-1.0e-300));
    try std.testing.expectError(
        error.InvalidSnowRedistributionGateInput,
        redistributionIsActive(std.math.nan(f64)),
    );
}

test "REDIST snow solute preserves signed outward redistribution" {
    var pools = std.mem.zeroes(SnowSolutePools);
    pools.co2_g = 4.0;
    pools.h2po4_g = 3.0;
    var fluxes = std.mem.zeroes(SnowSoluteFluxes);
    fluxes.co2_g = -1.5;
    fluxes.h2po4_g = -0.5;
    const result = try update(pools, fluxes);
    try std.testing.expectEqual(@as(f64, 2.5), result.co2_g);
    try std.testing.expectEqual(@as(f64, 2.5), result.h2po4_g);
}

test "REDIST snow solute rejects non-finite pool and overflow" {
    var pools = std.mem.zeroes(SnowSolutePools);
    pools.nh3_g = std.math.inf(f64);
    try std.testing.expectError(
        error.InvalidSnowSolutePool,
        update(pools, std.mem.zeroes(SnowSoluteFluxes)),
    );

    pools = std.mem.zeroes(SnowSolutePools);
    pools.o2_g = std.math.floatMax(f64);
    var fluxes = std.mem.zeroes(SnowSoluteFluxes);
    fluxes.o2_g = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteSnowSolutePool, update(pools, fluxes));
}

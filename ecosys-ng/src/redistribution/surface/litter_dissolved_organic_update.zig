const std = @import("std");

/// Signed convective-plus-diffusive solute transfer from `trnsfr.f` for
/// one of the three REDIST biochemical fractions K=0..2, accumulated over
/// the current model step. Carbon fields are g C, nitrogen is g N, and
/// phosphorus is g P. Positive values enter the surface-litter pool.
pub const OrganicFlux = struct {
    /// XOCFLS(K,3,0). DOC convective+diffusive flux.
    doc_g: f64,
    /// XONFLS(K,3,0). DON flux.
    don_g: f64,
    /// XOPFLS(K,3,0). DOP flux.
    dop_g: f64,
    /// XOAFLS(K,3,0). Acetate flux.
    acetate_g: f64,
};

/// Surface-litter dissolved organic pool for one biochemical fraction.
/// Carbon fields are g C, nitrogen is g N, and phosphorus is g P.
pub const OrganicPool = struct {
    /// OQC(K,0). DOC content.
    doc_g: f64,
    /// OQN(K,0). DON content.
    don_g: f64,
    /// OQP(K,0). DOP content.
    dop_g: f64,
    /// OQA(K,0). Acetate content.
    acetate_g: f64,
};

/// Direct translation of redist.f lines 4821--4831.
///
/// Updates three litter-fraction dissolved organic pools (K=0,1,2).
/// The caller provides one `OrganicFlux` and `OrganicPool` per fraction.
pub fn update(
    fluxes: [3]OrganicFlux,
    pools: [3]OrganicPool,
) ![3]OrganicPool {
    for (0..3) |k| {
        inline for (@typeInfo(OrganicFlux).@"struct".fields) |field|
            if (!std.math.isFinite(@field(fluxes[k], field.name)))
                return error.InvalidLitterOrganicFlux;
        inline for (@typeInfo(OrganicPool).@"struct".fields) |field|
            if (!std.math.isFinite(@field(pools[k], field.name)))
                return error.InvalidLitterOrganicPool;
    }

    var result: [3]OrganicPool = undefined;
    for (0..3) |k| {
        result[k] = .{
            .doc_g = pools[k].doc_g + fluxes[k].doc_g,
            .don_g = pools[k].don_g + fluxes[k].don_g,
            .dop_g = pools[k].dop_g + fluxes[k].dop_g,
            .acetate_g = pools[k].acetate_g + fluxes[k].acetate_g,
        };
        inline for (@typeInfo(OrganicPool).@"struct".fields) |field|
            if (!std.math.isFinite(@field(result[k], field.name)))
                return error.NonFiniteLitterOrganicPool;
    }
    return result;
}

test "REDIST litter dissolved organic updates all three fractions" {
    const fluxes: [3]OrganicFlux = .{
        .{ .doc_g = 1.0, .don_g = 0.1, .dop_g = 0.01, .acetate_g = 0.5 },
        .{ .doc_g = 2.0, .don_g = 0.2, .dop_g = 0.02, .acetate_g = 1.0 },
        .{ .doc_g = 3.0, .don_g = 0.3, .dop_g = 0.03, .acetate_g = 1.5 },
    };
    const pools: [3]OrganicPool = .{
        .{ .doc_g = 10.0, .don_g = 1.0, .dop_g = 0.1, .acetate_g = 5.0 },
        .{ .doc_g = 20.0, .don_g = 2.0, .dop_g = 0.2, .acetate_g = 10.0 },
        .{ .doc_g = 30.0, .don_g = 3.0, .dop_g = 0.3, .acetate_g = 15.0 },
    };
    const result = try update(fluxes, pools);
    try std.testing.expectEqual(@as(f64, 11.0), result[0].doc_g);
    try std.testing.expectEqual(@as(f64, 22.0), result[1].doc_g);
    try std.testing.expectEqual(@as(f64, 33.0), result[2].doc_g);
    try std.testing.expectEqual(@as(f64, 1.1), result[0].don_g);
    try std.testing.expectEqual(@as(f64, 0.22), result[1].dop_g);
    try std.testing.expectEqual(@as(f64, 16.5), result[2].acetate_g);
}

test "REDIST litter dissolved organic fractions are independent" {
    const fluxes: [3]OrganicFlux = .{
        .{ .doc_g = 5.0, .don_g = 0.0, .dop_g = 0.0, .acetate_g = 0.0 },
        std.mem.zeroes(OrganicFlux),
        std.mem.zeroes(OrganicFlux),
    };
    const pools: [3]OrganicPool = .{
        std.mem.zeroes(OrganicPool),
        .{ .doc_g = 7.0, .don_g = 0.0, .dop_g = 0.0, .acetate_g = 0.0 },
        std.mem.zeroes(OrganicPool),
    };
    const result = try update(fluxes, pools);
    try std.testing.expectEqual(@as(f64, 5.0), result[0].doc_g);
    try std.testing.expectEqual(@as(f64, 7.0), result[1].doc_g);
    try std.testing.expectEqual(@as(f64, 0.0), result[2].doc_g);
}

test "REDIST litter dissolved organic rejects non-finite flux" {
    const bad: [3]OrganicFlux = .{
        .{ .doc_g = std.math.nan(f64), .don_g = 0.0, .dop_g = 0.0, .acetate_g = 0.0 },
        std.mem.zeroes(OrganicFlux),
        std.mem.zeroes(OrganicFlux),
    };
    try std.testing.expectError(
        error.InvalidLitterOrganicFlux,
        update(bad, .{ std.mem.zeroes(OrganicPool), std.mem.zeroes(OrganicPool), std.mem.zeroes(OrganicPool) }),
    );
}

test "REDIST litter dissolved organic preserves signed outward transfer" {
    const fluxes: [3]OrganicFlux = .{
        .{ .doc_g = -2.0, .don_g = -0.25, .dop_g = -0.05, .acetate_g = -1.0 },
        std.mem.zeroes(OrganicFlux),
        std.mem.zeroes(OrganicFlux),
    };
    const pools: [3]OrganicPool = .{
        .{ .doc_g = 8.0, .don_g = 1.0, .dop_g = 0.2, .acetate_g = 4.0 },
        std.mem.zeroes(OrganicPool),
        std.mem.zeroes(OrganicPool),
    };
    const result = try update(fluxes, pools);
    try std.testing.expectEqual(@as(f64, 6.0), result[0].doc_g);
    try std.testing.expectEqual(@as(f64, 0.75), result[0].don_g);
    try std.testing.expectEqual(@as(f64, 0.15000000000000002), result[0].dop_g);
    try std.testing.expectEqual(@as(f64, 3.0), result[0].acetate_g);
}

test "REDIST litter dissolved organic rejects non-finite initial pool" {
    const pools: [3]OrganicPool = .{
        std.mem.zeroes(OrganicPool),
        .{ .doc_g = 0.0, .don_g = std.math.inf(f64), .dop_g = 0.0, .acetate_g = 0.0 },
        std.mem.zeroes(OrganicPool),
    };
    try std.testing.expectError(
        error.InvalidLitterOrganicPool,
        update(.{ std.mem.zeroes(OrganicFlux), std.mem.zeroes(OrganicFlux), std.mem.zeroes(OrganicFlux) }, pools),
    );
}

test "REDIST litter dissolved organic rejects arithmetic overflow" {
    const fluxes: [3]OrganicFlux = .{
        .{ .doc_g = std.math.floatMax(f64), .don_g = 0.0, .dop_g = 0.0, .acetate_g = 0.0 },
        std.mem.zeroes(OrganicFlux),
        std.mem.zeroes(OrganicFlux),
    };
    const pools: [3]OrganicPool = .{
        .{ .doc_g = std.math.floatMax(f64), .don_g = 0.0, .dop_g = 0.0, .acetate_g = 0.0 },
        std.mem.zeroes(OrganicPool),
        std.mem.zeroes(OrganicPool),
    };
    try std.testing.expectError(error.NonFiniteLitterOrganicPool, update(fluxes, pools));
}

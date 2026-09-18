//! REDIST lines 4318-4330 (`VHCPO`/`HFLXO`): when surface litter SOC changes,
//! the litter heat capacity `VHCP(0)` is rebuilt from the new carbon and the
//! resulting capacity change is carried at the current litter temperature into
//! `HEATIN`, the cumulative boundary heat ledger. Legacy does this because the
//! litter temperature is held fixed across the carbon change, so the enthalpy
//! the census stores moves by `dVHCP*TKS` with no corresponding process flux.
//!
//! The same is required here. The landscape census prices surface litter at
//! `dry_organic_heat_capacity * total_organic_carbon * T` (see
//! `landscape_mass_inventory_surface.zig`), while the soil census prices its
//! solids from bulk density and never from carbon. So carbon respired out of
//! the surface pool, or transferred down to a soil layer, silently changes
//! stored enthalpy. On Ottawa day one that is `3.8e-5` MJ per hour, `4.2e-4`
//! MJ per day, which is 71% of the remaining heat deviation.
const std = @import("std");

/// Signed heat, positive into the landscape, that must be booked when the
/// carbon carried by a surface litter cell changes at fixed temperature.
pub fn organicCarbonRebaseHeatMegajoules(
    carbon_before_g_c: f64,
    carbon_after_g_c: f64,
    temperature_k: f64,
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
) !f64 {
    inline for (.{ carbon_before_g_c, carbon_after_g_c, temperature_k, dry_organic_heat_capacity_megajoules_per_g_c_k }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceLitterHeatRebaseInput;
    if (carbon_before_g_c < 0 or carbon_after_g_c < 0) return error.NegativeSurfaceLitterCarbon;
    if (temperature_k <= 0) return error.InvalidSurfaceLitterRebaseTemperature;
    if (dry_organic_heat_capacity_megajoules_per_g_c_k <= 0) return error.InvalidSurfaceLitterHeatCapacity;
    const rebase = (carbon_after_g_c - carbon_before_g_c) *
        dry_organic_heat_capacity_megajoules_per_g_c_k * temperature_k;
    if (!std.math.isFinite(rebase)) return error.NonFiniteSurfaceLitterHeatRebase;
    return rebase;
}

/// Whole-landscape form. `carbon_before_g_c` and `carbon_after_g_c` are per
/// cell and `temperature_k` is the litter temperature held across the change.
pub fn landscapeOrganicCarbonRebaseHeatMegajoules(
    carbon_before_g_c: []const f64,
    carbon_after_g_c: []const f64,
    temperature_k: []const f64,
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
) !f64 {
    if (carbon_before_g_c.len != carbon_after_g_c.len or carbon_before_g_c.len != temperature_k.len)
        return error.SurfaceLitterHeatRebaseDimensionMismatch;
    var total: f64 = 0;
    for (carbon_before_g_c, carbon_after_g_c, temperature_k) |before, after, temperature| {
        total += try organicCarbonRebaseHeatMegajoules(
            before,
            after,
            temperature,
            dry_organic_heat_capacity_megajoules_per_g_c_k,
        );
        if (!std.math.isFinite(total)) return error.NonFiniteSurfaceLitterHeatRebase;
    }
    return total;
}

/// Retains the producer-owned cell partition used to form the landscape
/// scalar. All inputs are preflighted before the destination is changed.
pub fn landscapeOrganicCarbonRebaseHeatMegajoulesByCell(
    heat_megajoules_by_cell: []f64,
    carbon_before_g_c: []const f64,
    carbon_after_g_c: []const f64,
    temperature_k: []const f64,
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
) !void {
    if (carbon_before_g_c.len != carbon_after_g_c.len or
        carbon_before_g_c.len != temperature_k.len or
        carbon_before_g_c.len != heat_megajoules_by_cell.len)
        return error.SurfaceLitterHeatRebaseDimensionMismatch;
    for (carbon_before_g_c, carbon_after_g_c, temperature_k) |before, after, temperature|
        _ = try organicCarbonRebaseHeatMegajoules(before, after, temperature, dry_organic_heat_capacity_megajoules_per_g_c_k);
    for (heat_megajoules_by_cell, carbon_before_g_c, carbon_after_g_c, temperature_k) |*heat, before, after, temperature|
        heat.* = try organicCarbonRebaseHeatMegajoules(before, after, temperature, dry_organic_heat_capacity_megajoules_per_g_c_k);
}

test "carbon gained at fixed temperature is booked as heat into the landscape" {
    const rebase = try organicCarbonRebaseHeatMegajoules(1000, 1100, 300, 2.496e-6);
    try std.testing.expectApproxEqRel(100 * 2.496e-6 * 300, rebase, 1e-12);
}

test "carbon lost at fixed temperature is booked as heat out of the landscape" {
    const rebase = try organicCarbonRebaseHeatMegajoules(1100, 1000, 300, 2.496e-6);
    try std.testing.expect(rebase < 0);
    try std.testing.expectApproxEqRel(-100 * 2.496e-6 * 300, rebase, 1e-12);
}

test "unchanged carbon books nothing" {
    try std.testing.expectEqual(@as(f64, 0), try organicCarbonRebaseHeatMegajoules(1000, 1000, 300, 2.496e-6));
}

test "landscape form sums cells and rejects a length mismatch" {
    const before = [_]f64{ 1000, 2000 };
    const after = [_]f64{ 1100, 1900 };
    const temperature = [_]f64{ 300, 280 };
    const total = try landscapeOrganicCarbonRebaseHeatMegajoules(&before, &after, &temperature, 2.496e-6);
    var by_cell = [_]f64{ 99, 99 };
    try landscapeOrganicCarbonRebaseHeatMegajoulesByCell(&by_cell, &before, &after, &temperature, 2.496e-6);
    try std.testing.expectApproxEqAbs(total, by_cell[0] + by_cell[1], 1e-15);
    try std.testing.expectApproxEqRel(2.496e-6 * (100 * 300 - 100 * 280), total, 1e-12);
    try std.testing.expectError(
        error.SurfaceLitterHeatRebaseDimensionMismatch,
        landscapeOrganicCarbonRebaseHeatMegajoules(&before, &after, temperature[0..1], 2.496e-6),
    );
}

test "per-cell litter heat rebase rejects late invalid input atomically" {
    var output = [_]f64{ 7, 8 };
    const original = output;
    try std.testing.expectError(
        error.NonFiniteSurfaceLitterHeatRebaseInput,
        landscapeOrganicCarbonRebaseHeatMegajoulesByCell(&output, &.{ 1, 2 }, &.{ 3, std.math.nan(f64) }, &.{ 280, 300 }, 2.496e-6),
    );
    try std.testing.expectEqualSlices(f64, &original, &output);
}

test "invalid inputs are rejected before any booking" {
    try std.testing.expectError(error.InvalidSurfaceLitterRebaseTemperature, organicCarbonRebaseHeatMegajoules(1, 2, 0, 2.496e-6));
    try std.testing.expectError(error.NegativeSurfaceLitterCarbon, organicCarbonRebaseHeatMegajoules(-1, 2, 300, 2.496e-6));
    try std.testing.expectError(error.InvalidSurfaceLitterHeatCapacity, organicCarbonRebaseHeatMegajoules(1, 2, 300, 0));
    try std.testing.expectError(error.NonFiniteSurfaceLitterHeatRebaseInput, organicCarbonRebaseHeatMegajoules(1, std.math.nan(f64), 300, 2.496e-6));
}

//! Stationary source circulation at fixed free-ion activities and XOH.
//! This eliminates the three dependent surface rate equations without
//! imposing detailed balance on the inconsistent legacy reaction cycle.
const std = @import("std");
const exchange = @import("phosphate_exchange.zig");

pub const Result = struct {
    /// Deprotonated, hydroxyl, protonated, adsorbed HPO4, adsorbed H2PO4.
    sites: [5]f64,
    circulation: f64,
};

/// The smaller nonnegative root of j*j-b*j+c=0. The discriminant is
/// supplied as a hypot to avoid losing the small root by subtraction.
fn smallRoot(b: f64, c: f64, discriminant: f64) f64 {
    return if (c == 0) 0 else (2 * c) / (b + discriminant);
}

/// Solves the non-band source equations. With H*OH=Kw, the band equations
/// have the same stationary solution. This does not impose site capacity,
/// phosphorus inventory, or the charge census of a surrounding cell.
pub fn atFreeConcentrations(inputs: exchange.Inputs, parameters: exchange.Parameters, hydroxyl_site: f64) !Result {
    // Reuse the authoritative finite-domain validation before elimination.
    _ = try exchange.calculate(inputs, parameters);
    const h = inputs.hydrogen_activity_mol_per_m3;
    const p = inputs.h2po4_activity_mol_p_per_m3 / inputs.monovalent_activity_coefficient;
    const x = hydroxyl_site;
    const f = parameters.substrate_limit_fraction;
    const ks = parameters.protonated_site_equilibrium_constant;
    if (!std.math.isFinite(x) or x < 0 or h <= 0 or
        f <= 0 or f > 1 or ks <= 0 or ks > 1 or
        parameters.maximum_exchange_mol_per_megagram_step <= 0 or
        inputs.monovalent_activity_coefficient <= 0 or
        inputs.hydroxide_activity_mol_per_m3 <= 0 or
        parameters.h2po4_exchange_equilibrium_constant <= 0 or
        parameters.hpo4_exchange_equilibrium_constant <= 0 or
        parameters.h2po4_dissociation_constant <= 0)
        return error.UnsupportedSurfaceStationarityInput;
    if (x == 0) return .{ .sites = @splat(0), .circulation = 0 };

    const k3 = parameters.h2po4_exchange_equilibrium_constant * inputs.hydroxide_activity_mol_per_m3 / inputs.monovalent_activity_coefficient;
    const k2 = h * k3;
    var j: f64 = 0;
    var z: f64 = 0;
    var y = h * x / ks;
    if (p > 0) {
        // At stationarity r_protonation=r_protonated_adsorption=j,
        // r_hydroxyl_adsorption=-j. The latter two bounded rates require
        // z=max(j/f,(p+j)*x/k3), y=max(j/f,k2*z/(p-j)).
        // The first rate then bounds j by each of three monotone roots,
        // in addition to the original source forward and kinetic bounds.
        const root_y_donor = x * (h * f / (ks + h * f));
        const c = ks * k3 / f;
        const root_z_donor = smallRoot(x + p + c, x * p, std.math.hypot(x - p, @sqrt(c) * @sqrt(2 * (x + p) + c)));
        const root_affinity = smallRoot(p + x * (1 + ks), x * p * (1 - ks), std.math.hypot(p - x * (1 + ks), @sqrt(8 * ks * x) * @sqrt(p)));
        j = @min(root_y_donor, root_z_donor, root_affinity, f * inputs.hydrogen_concentration_mol_per_m3, f * x, f * inputs.h2po4_concentration_mol_p_per_m3, parameters.maximum_exchange_mol_per_megagram_step);
        if (j < 0 or j >= p or !std.math.isFinite(j)) return error.UnsupportedSurfaceStationarityInput;
        z = @max(j / f, (p + j) * x / k3);
        y = @max(j / f, k2 * z / (p - j));
        // If phosphate itself caps the forward adsorption, its rate is
        // unchanged by increasing XOH2. Choose the first stationary point
        // on that flat source branch by satisfying protonation exactly.
        if (j == f * inputs.h2po4_concentration_mol_p_per_m3 and x - ks * y / h > j) y = (x - j) * h / ks;
    }
    const hpo4_product = parameters.hpo4_exchange_equilibrium_constant * parameters.water_activity_product_mol2_per_m6 / parameters.h2po4_dissociation_constant;
    const sites: [5]f64 = .{
        parameters.hydroxyl_site_equilibrium_constant * x / h,
        x,
        y,
        inputs.hpo4_activity_mol_p_per_m3 * x / hpo4_product,
        z,
    };
    for (sites) |value| if (!std.math.isFinite(value) or value < 0) return error.UnsupportedSurfaceStationarityInput;
    return .{ .sites = sites, .circulation = j };
}

test "algebraic surface circulation satisfies the original bounded source" {
    for ([_]f64{ 1e-8, 1e-4, 0.1, 1, 10 }) |hydrogen| {
        for ([_]f64{ 0, 1e-8, 0.01, 1, 100 }) |phosphate| {
            for ([_]f64{ 1e-6, 0.1, 1, 20 }) |hydroxyl_site| {
                for ([_]f64{ 0.45, 1 }) |ks| {
                    for ([_]f64{ 0.001, 0.2, 1 }) |fraction| {
                        var inputs: exchange.Inputs = .{
                            .hydrogen_concentration_mol_per_m3 = hydrogen,
                            .hydrogen_activity_mol_per_m3 = hydrogen * 0.8,
                            .hydroxide_activity_mol_per_m3 = 1e-8 / (hydrogen * 0.8),
                            .h2po4_concentration_mol_p_per_m3 = phosphate,
                            .h2po4_activity_mol_p_per_m3 = phosphate * 0.8,
                            .hpo4_concentration_mol_p_per_m3 = 0.1 * phosphate,
                            .hpo4_activity_mol_p_per_m3 = 0.06 * phosphate,
                            .deprotonated_site_mol_per_megagram = 0,
                            .hydroxyl_site_mol_per_megagram = 0,
                            .protonated_site_mol_per_megagram = 0,
                            .adsorbed_h2po4_mol_p_per_megagram = 0,
                            .adsorbed_hpo4_mol_p_per_megagram = 0,
                            .monovalent_activity_coefficient = 0.8,
                            .divalent_activity_coefficient = 0.6,
                        };
                        const parameters: exchange.Parameters = .{
                            .protonated_site_equilibrium_constant = ks,
                            .hydroxyl_site_equilibrium_constant = 8.1e-4,
                            .h2po4_exchange_equilibrium_constant = 5e5,
                            .hpo4_exchange_equilibrium_constant = 1e5,
                            .water_activity_product_mol2_per_m6 = 1e-8,
                            .h2po4_dissociation_constant = 1e-4,
                            .maximum_exchange_mol_per_megagram_step = 0.1,
                            .substrate_limit_fraction = fraction,
                        };
                        const result = try atFreeConcentrations(inputs, parameters, hydroxyl_site);
                        inputs.deprotonated_site_mol_per_megagram = result.sites[0];
                        inputs.hydroxyl_site_mol_per_megagram = result.sites[1];
                        inputs.protonated_site_mol_per_megagram = result.sites[2];
                        inputs.adsorbed_hpo4_mol_p_per_megagram = result.sites[3];
                        inputs.adsorbed_h2po4_mol_p_per_megagram = result.sites[4];
                        const rates = try exchange.calculate(inputs, parameters);
                        const band_rates = try exchange.calculateBandSourceOrder(inputs, parameters);
                        const rounding = 128 * std.math.floatEps(f64) * @max(1, hydroxyl_site, phosphate);
                        try std.testing.expectApproxEqAbs(result.circulation, rates.protonated_to_hydroxyl_site_mol_per_megagram, rounding);
                        try std.testing.expectApproxEqAbs(result.circulation, rates.h2po4_with_protonated_site_mol_p_per_megagram, rounding);
                        try std.testing.expectApproxEqAbs(-result.circulation, rates.h2po4_with_hydroxyl_site_mol_p_per_megagram, rounding);
                        const deprotonation_rounding = @max(rounding, 128 * std.math.floatEps(f64) * result.sites[0]);
                        try std.testing.expectApproxEqAbs(@as(f64, 0), rates.hydroxyl_to_deprotonated_site_mol_per_megagram, deprotonation_rounding);
                        try std.testing.expectApproxEqAbs(@as(f64, 0), rates.hpo4_with_hydroxyl_site_mol_p_per_megagram, rounding);
                        inline for (@typeInfo(exchange.Flux).@"struct".fields) |field| {
                            try std.testing.expectApproxEqAbs(@field(rates, field.name), @field(band_rates, field.name), rounding);
                        }
                    }
                }
            }
        }
    }
}

const std = @import("std");

pub const Inputs = struct {
    hydrogen_concentration_mol_per_m3: f64,
    hydrogen_activity_mol_per_m3: f64,
    hydroxide_activity_mol_per_m3: f64,
    h2po4_concentration_mol_p_per_m3: f64,
    h2po4_activity_mol_p_per_m3: f64,
    hpo4_concentration_mol_p_per_m3: f64,
    hpo4_activity_mol_p_per_m3: f64,
    deprotonated_site_mol_per_megagram: f64,
    hydroxyl_site_mol_per_megagram: f64,
    protonated_site_mol_per_megagram: f64,
    adsorbed_h2po4_mol_p_per_megagram: f64,
    adsorbed_hpo4_mol_p_per_megagram: f64,
    monovalent_activity_coefficient: f64,
    divalent_activity_coefficient: f64,
};

pub const Parameters = struct {
    protonated_site_equilibrium_constant: f64,
    hydroxyl_site_equilibrium_constant: f64,
    h2po4_exchange_equilibrium_constant: f64,
    hpo4_exchange_equilibrium_constant: f64,
    water_activity_product_mol2_per_m6: f64,
    h2po4_dissociation_constant: f64,
    maximum_exchange_mol_per_megagram_step: f64,
    substrate_limit_fraction: f64,
};

pub const Flux = struct {
    protonated_to_hydroxyl_site_mol_per_megagram: f64,
    hydroxyl_to_deprotonated_site_mol_per_megagram: f64,
    h2po4_with_protonated_site_mol_p_per_megagram: f64,
    h2po4_with_hydroxyl_site_mol_p_per_megagram: f64,
    hpo4_with_hydroxyl_site_mol_p_per_megagram: f64,
};

pub const ZoneAdmission = struct {
    phosphate_zone_water_volume_m3: f64,
    minimum_water_volume_m3: f64,
    anion_exchange_capacity_mol: f64,
    minimum_exchange_capacity_mol: f64,
};

pub const RestrictedAdmission = struct {
    anion_exchange_capacity_mol: f64,
    minimum_exchange_capacity_mol: f64,
};

pub const RestrictedFlux = struct {
    h2po4_with_protonated_site_mol_p_per_megagram: f64,
    h2po4_with_hydroxyl_site_mol_p_per_megagram: f64,
    hpo4_with_hydroxyl_site_mol_p_per_megagram: f64,
};

/// Direct translation of restricted-domain SOLUTE.F lines 3075--3139.
/// The enclosing water-volume gate is owned by the restricted-zone caller.
/// Empty individual site pools yield zero instead of permitting a division
/// by zero to contaminate subsequent iterations.
pub fn calculateRestrictedSourceOrder(
    inputs: Inputs,
    parameters: Parameters,
    admission: RestrictedAdmission,
) !RestrictedFlux {
    try validate(inputs, parameters);
    inline for (@typeInfo(RestrictedAdmission).@"struct".fields) |field| {
        const value = @field(admission, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPhosphateExchangeAdmission;
    }
    if (admission.anion_exchange_capacity_mol <=
        admission.minimum_exchange_capacity_mol)
        return std.mem.zeroes(RestrictedFlux);

    const h2po4_with_protonated = if (inputs.protonated_site_mol_per_megagram > 0) blk: {
        const equilibrium_product = parameters.h2po4_exchange_equilibrium_constant *
            inputs.hydrogen_activity_mol_per_m3 *
            inputs.hydroxide_activity_mol_per_m3;
        const equilibrium = equilibrium_product *
            inputs.adsorbed_h2po4_mol_p_per_megagram /
            inputs.protonated_site_mol_per_megagram;
        break :blk bounded(
            (inputs.h2po4_activity_mol_p_per_m3 - equilibrium) /
                inputs.monovalent_activity_coefficient,
            parameters.maximum_exchange_mol_per_megagram_step,
            parameters.substrate_limit_fraction * @min(
                inputs.h2po4_concentration_mol_p_per_m3,
                inputs.protonated_site_mol_per_megagram,
            ),
            parameters.substrate_limit_fraction * inputs.adsorbed_h2po4_mol_p_per_megagram,
        );
    } else 0;
    const h2po4_with_hydroxyl = if (inputs.hydroxyl_site_mol_per_megagram > 0) blk: {
        const equilibrium_product = parameters.h2po4_exchange_equilibrium_constant *
            inputs.hydroxide_activity_mol_per_m3;
        const equilibrium = equilibrium_product *
            inputs.adsorbed_h2po4_mol_p_per_megagram /
            inputs.hydroxyl_site_mol_per_megagram;
        break :blk bounded(
            (inputs.h2po4_activity_mol_p_per_m3 - equilibrium) /
                inputs.monovalent_activity_coefficient,
            parameters.maximum_exchange_mol_per_megagram_step,
            parameters.substrate_limit_fraction * @min(
                inputs.h2po4_concentration_mol_p_per_m3,
                inputs.hydroxyl_site_mol_per_megagram,
            ),
            parameters.substrate_limit_fraction * inputs.adsorbed_h2po4_mol_p_per_megagram,
        );
    } else 0;
    const hpo4_with_hydroxyl = if (inputs.hydroxyl_site_mol_per_megagram > 0) blk: {
        const equilibrium_product = parameters.hpo4_exchange_equilibrium_constant *
            parameters.water_activity_product_mol2_per_m6 /
            parameters.h2po4_dissociation_constant;
        const equilibrium = equilibrium_product *
            inputs.adsorbed_hpo4_mol_p_per_megagram /
            inputs.hydroxyl_site_mol_per_megagram;
        break :blk bounded(
            (inputs.hpo4_activity_mol_p_per_m3 - equilibrium) /
                inputs.divalent_activity_coefficient,
            parameters.maximum_exchange_mol_per_megagram_step,
            parameters.substrate_limit_fraction * @min(
                inputs.hpo4_concentration_mol_p_per_m3,
                inputs.hydroxyl_site_mol_per_megagram,
            ),
            parameters.substrate_limit_fraction * inputs.adsorbed_hpo4_mol_p_per_megagram,
        );
    } else 0;
    return .{
        .h2po4_with_protonated_site_mol_p_per_megagram = h2po4_with_protonated,
        .h2po4_with_hydroxyl_site_mol_p_per_megagram = h2po4_with_hydroxyl,
        .hpo4_with_hydroxyl_site_mol_p_per_megagram = hpo4_with_hydroxyl,
    };
}

/// Restricted band-zone translation of SOLUTE.F lines 3268--3307. The
/// source deliberately uses `FIONX` for the hydroxyl-site H2PO4 path and
/// `FIONN` for the protonated-site H2PO4 and HPO4 paths.
pub fn calculateRestrictedBandSourceOrder(
    inputs: Inputs,
    parameters: Parameters,
    admission: RestrictedAdmission,
    hydroxyl_h2po4_substrate_limit_fraction: f64,
) !RestrictedFlux {
    try validate(inputs, parameters);
    inline for (@typeInfo(RestrictedAdmission).@"struct".fields) |field| {
        const value = @field(admission, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPhosphateExchangeAdmission;
    }
    if (!std.math.isFinite(hydroxyl_h2po4_substrate_limit_fraction) or
        hydroxyl_h2po4_substrate_limit_fraction < 0 or
        hydroxyl_h2po4_substrate_limit_fraction > 1)
        return error.InvalidPhosphateExchangeParameter;
    if (admission.anion_exchange_capacity_mol <=
        admission.minimum_exchange_capacity_mol)
        return std.mem.zeroes(RestrictedFlux);

    const h2po4_with_protonated = if (inputs.protonated_site_mol_per_megagram > 0) blk: {
        const equilibrium_product = parameters.h2po4_exchange_equilibrium_constant *
            parameters.water_activity_product_mol2_per_m6;
        const equilibrium = equilibrium_product *
            inputs.adsorbed_h2po4_mol_p_per_megagram /
            inputs.protonated_site_mol_per_megagram;
        break :blk bounded(
            (inputs.h2po4_activity_mol_p_per_m3 - equilibrium) /
                inputs.monovalent_activity_coefficient,
            parameters.maximum_exchange_mol_per_megagram_step,
            parameters.substrate_limit_fraction * @min(
                inputs.h2po4_concentration_mol_p_per_m3,
                inputs.protonated_site_mol_per_megagram,
            ),
            parameters.substrate_limit_fraction * inputs.adsorbed_h2po4_mol_p_per_megagram,
        );
    } else 0;
    const h2po4_with_hydroxyl = if (inputs.hydroxyl_site_mol_per_megagram > 0) blk: {
        const equilibrium_product = parameters.h2po4_exchange_equilibrium_constant *
            inputs.hydroxide_activity_mol_per_m3;
        const equilibrium = equilibrium_product *
            inputs.adsorbed_h2po4_mol_p_per_megagram /
            inputs.hydroxyl_site_mol_per_megagram;
        break :blk bounded(
            (inputs.h2po4_activity_mol_p_per_m3 - equilibrium) /
                inputs.monovalent_activity_coefficient,
            parameters.maximum_exchange_mol_per_megagram_step,
            hydroxyl_h2po4_substrate_limit_fraction * @min(
                inputs.h2po4_concentration_mol_p_per_m3,
                inputs.hydroxyl_site_mol_per_megagram,
            ),
            hydroxyl_h2po4_substrate_limit_fraction * inputs.adsorbed_h2po4_mol_p_per_megagram,
        );
    } else 0;
    const hpo4_with_hydroxyl = if (inputs.hydroxyl_site_mol_per_megagram > 0) blk: {
        const equilibrium_product = parameters.hpo4_exchange_equilibrium_constant *
            parameters.water_activity_product_mol2_per_m6 /
            parameters.h2po4_dissociation_constant;
        const equilibrium = equilibrium_product *
            inputs.adsorbed_hpo4_mol_p_per_megagram /
            inputs.hydroxyl_site_mol_per_megagram;
        break :blk bounded(
            (inputs.hpo4_activity_mol_p_per_m3 - equilibrium) /
                inputs.divalent_activity_coefficient,
            parameters.maximum_exchange_mol_per_megagram_step,
            parameters.substrate_limit_fraction * @min(
                inputs.hpo4_concentration_mol_p_per_m3,
                inputs.hydroxyl_site_mol_per_megagram,
            ),
            parameters.substrate_limit_fraction * inputs.adsorbed_hpo4_mol_p_per_megagram,
        );
    } else 0;
    return .{
        .h2po4_with_protonated_site_mol_p_per_megagram = h2po4_with_protonated,
        .h2po4_with_hydroxyl_site_mol_p_per_megagram = h2po4_with_hydroxyl,
        .hpo4_with_hydroxyl_site_mol_p_per_megagram = hpo4_with_hydroxyl,
    };
}

/// Direct translation of the SOLUTE.F lines 979--980 admission gate and
/// lines 1076--1082 inactive reset. Equality remains inactive because both
/// source comparisons use strict `.GT.`.
pub fn calculateAdmitted(
    inputs: Inputs,
    parameters: Parameters,
    admission: ZoneAdmission,
) !Flux {
    inline for (@typeInfo(ZoneAdmission).@"struct".fields) |field| {
        const value = @field(admission, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPhosphateExchangeAdmission;
    }
    if (admission.phosphate_zone_water_volume_m3 <=
        admission.minimum_water_volume_m3 or
        admission.anion_exchange_capacity_mol <=
            admission.minimum_exchange_capacity_mol)
        return std.mem.zeroes(Flux);
    return calculate(inputs, parameters);
}

/// Band-zone counterpart preserving SOLUTE.F lines 1106--1200, including
/// line 1141's direct `SXH2P * DPH2O` equilibrium-product assignment.
pub fn calculateBandAdmitted(
    inputs: Inputs,
    parameters: Parameters,
    admission: ZoneAdmission,
) !Flux {
    inline for (@typeInfo(ZoneAdmission).@"struct".fields) |field| {
        const value = @field(admission, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPhosphateExchangeAdmission;
    }
    if (admission.phosphate_zone_water_volume_m3 <=
        admission.minimum_water_volume_m3 or
        admission.anion_exchange_capacity_mol <=
            admission.minimum_exchange_capacity_mol)
        return std.mem.zeroes(Flux);
    return calculateBandSourceOrder(inputs, parameters);
}

/// Direct shared kernel for SOLUTE lines 979--1054 and 1106--1174. The
/// non-band H2PO4/protonated-site expression uses explicit H and OH
/// activities; after water projection their product equals the band branch's
/// source `DPH2O` expression.
pub fn calculate(inputs: Inputs, parameters: Parameters) !Flux {
    return calculateForZone(inputs, parameters, .non_band);
}

test "source phosphate surface cycle does not imply individual detailed balance" {
    // SOLUTE.F 54-55, 981-1032: site protonation gives XOH2/XOH = H/Ks.
    // The two adsorption routes instead agree only if XOH2/XOH = H.
    // Ks is 0.45 in the source, not 1. Do not impose zero rate on all three
    // routes or silently alter Ks to make an equilibrium isotherm possible.
    const hydrogen: f64 = 1.0e-3;
    const kw: f64 = 1.0e-8;
    const hydroxide = kw / hydrogen;
    const phosphate: f64 = 0.1;
    const site_constant: f64 = 0.45;
    const exchange_constant: f64 = 5.0e5;
    const hydroxyl: f64 = 1;
    const protonated = hydrogen * hydroxyl / site_constant;
    const adsorbed = phosphate * hydroxyl / (exchange_constant * hydroxide);
    const result = try calculate(.{
        .hydrogen_concentration_mol_per_m3 = hydrogen,
        .hydrogen_activity_mol_per_m3 = hydrogen,
        .hydroxide_activity_mol_per_m3 = hydroxide,
        .h2po4_concentration_mol_p_per_m3 = phosphate,
        .h2po4_activity_mol_p_per_m3 = phosphate,
        .hpo4_concentration_mol_p_per_m3 = 0,
        .hpo4_activity_mol_p_per_m3 = 0,
        .deprotonated_site_mol_per_megagram = 8.1e-4 * hydroxyl / hydrogen,
        .hydroxyl_site_mol_per_megagram = hydroxyl,
        .protonated_site_mol_per_megagram = protonated,
        .adsorbed_h2po4_mol_p_per_megagram = adsorbed,
        .adsorbed_hpo4_mol_p_per_megagram = 0,
        .monovalent_activity_coefficient = 1,
        .divalent_activity_coefficient = 1,
    }, .{
        .protonated_site_equilibrium_constant = site_constant,
        .hydroxyl_site_equilibrium_constant = 8.1e-4,
        .h2po4_exchange_equilibrium_constant = exchange_constant,
        .hpo4_exchange_equilibrium_constant = 5.0e3,
        .water_activity_product_mol2_per_m6 = kw,
        .h2po4_dissociation_constant = 6.2e-5,
        .maximum_exchange_mol_per_megagram_step = 1,
        .substrate_limit_fraction = 1,
    });
    const roundoff = 128 * std.math.floatEps(f64);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.protonated_to_hydroxyl_site_mol_per_megagram, roundoff);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.h2po4_with_hydroxyl_site_mol_p_per_megagram, roundoff);
    try std.testing.expectApproxEqAbs(protonated, result.h2po4_with_protonated_site_mol_p_per_megagram, roundoff);
    try std.testing.expect(result.h2po4_with_protonated_site_mol_p_per_megagram > roundoff);
}

/// Direct band-zone equations from SOLUTE.F lines 1108--1174.
pub fn calculateBandSourceOrder(inputs: Inputs, parameters: Parameters) !Flux {
    return calculateForZone(inputs, parameters, .band);
}

const ZoneEquation = enum { non_band, band };

fn calculateForZone(
    inputs: Inputs,
    parameters: Parameters,
    zone: ZoneEquation,
) !Flux {
    try validate(inputs, parameters);
    const protonated_to_hydroxyl = if (inputs.protonated_site_mol_per_megagram > 0 and inputs.hydrogen_activity_mol_per_m3 > 0) bounded(
        inputs.hydroxyl_site_mol_per_megagram - parameters.protonated_site_equilibrium_constant * inputs.protonated_site_mol_per_megagram / inputs.hydrogen_activity_mol_per_m3,
        parameters.maximum_exchange_mol_per_megagram_step,
        parameters.substrate_limit_fraction * @min(inputs.hydrogen_concentration_mol_per_m3, inputs.hydroxyl_site_mol_per_megagram),
        parameters.substrate_limit_fraction * inputs.protonated_site_mol_per_megagram,
    ) else 0;
    const hydroxyl_to_deprotonated = if (inputs.hydroxyl_site_mol_per_megagram > 0 and inputs.hydrogen_activity_mol_per_m3 > 0) bounded(
        inputs.deprotonated_site_mol_per_megagram - parameters.hydroxyl_site_equilibrium_constant * inputs.hydroxyl_site_mol_per_megagram / inputs.hydrogen_activity_mol_per_m3,
        parameters.maximum_exchange_mol_per_megagram_step,
        parameters.substrate_limit_fraction * @min(inputs.hydrogen_concentration_mol_per_m3, inputs.deprotonated_site_mol_per_megagram),
        parameters.substrate_limit_fraction * inputs.hydroxyl_site_mol_per_megagram,
    ) else 0;
    const h2po4_with_protonated = if (inputs.protonated_site_mol_per_megagram > 0) blk: {
        const exchange_product = switch (zone) {
            .non_band => parameters.h2po4_exchange_equilibrium_constant *
                inputs.hydrogen_activity_mol_per_m3 *
                inputs.hydroxide_activity_mol_per_m3,
            .band => parameters.h2po4_exchange_equilibrium_constant *
                parameters.water_activity_product_mol2_per_m6,
        };
        const equilibrium = exchange_product *
            inputs.adsorbed_h2po4_mol_p_per_megagram /
            inputs.protonated_site_mol_per_megagram;
        break :blk bounded((inputs.h2po4_activity_mol_p_per_m3 - equilibrium) / inputs.monovalent_activity_coefficient, parameters.maximum_exchange_mol_per_megagram_step, parameters.substrate_limit_fraction * @min(inputs.h2po4_concentration_mol_p_per_m3, inputs.protonated_site_mol_per_megagram), parameters.substrate_limit_fraction * inputs.adsorbed_h2po4_mol_p_per_megagram);
    } else 0;
    const h2po4_with_hydroxyl = if (inputs.hydroxyl_site_mol_per_megagram > 0) blk: {
        const equilibrium = parameters.h2po4_exchange_equilibrium_constant * inputs.hydroxide_activity_mol_per_m3 * inputs.adsorbed_h2po4_mol_p_per_megagram / inputs.hydroxyl_site_mol_per_megagram;
        break :blk bounded((inputs.h2po4_activity_mol_p_per_m3 - equilibrium) / inputs.monovalent_activity_coefficient, parameters.maximum_exchange_mol_per_megagram_step, parameters.substrate_limit_fraction * @min(inputs.h2po4_concentration_mol_p_per_m3, inputs.hydroxyl_site_mol_per_megagram), parameters.substrate_limit_fraction * inputs.adsorbed_h2po4_mol_p_per_megagram);
    } else 0;
    const hpo4_with_hydroxyl = if (inputs.hydroxyl_site_mol_per_megagram > 0) blk: {
        const effective_equilibrium = parameters.hpo4_exchange_equilibrium_constant * parameters.water_activity_product_mol2_per_m6 / parameters.h2po4_dissociation_constant;
        const equilibrium = effective_equilibrium * inputs.adsorbed_hpo4_mol_p_per_megagram / inputs.hydroxyl_site_mol_per_megagram;
        break :blk bounded((inputs.hpo4_activity_mol_p_per_m3 - equilibrium) / inputs.divalent_activity_coefficient, parameters.maximum_exchange_mol_per_megagram_step, parameters.substrate_limit_fraction * @min(inputs.hpo4_concentration_mol_p_per_m3, inputs.hydroxyl_site_mol_per_megagram), parameters.substrate_limit_fraction * inputs.adsorbed_hpo4_mol_p_per_megagram);
    } else 0;
    return .{ .protonated_to_hydroxyl_site_mol_per_megagram = protonated_to_hydroxyl, .hydroxyl_to_deprotonated_site_mol_per_megagram = hydroxyl_to_deprotonated, .h2po4_with_protonated_site_mol_p_per_megagram = h2po4_with_protonated, .h2po4_with_hydroxyl_site_mol_p_per_megagram = h2po4_with_hydroxyl, .hpo4_with_hydroxyl_site_mol_p_per_megagram = hpo4_with_hydroxyl };
}

fn bounded(driving_force: f64, maximum_rate: f64, precipitation_limit: f64, dissolution_limit: f64) f64 {
    return @max(-maximum_rate, -dissolution_limit, @min(maximum_rate, precipitation_limit, driving_force));
}

fn validate(inputs: Inputs, parameters: Parameters) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0) return error.InvalidPhosphateExchangeInput;
    inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name)) or @field(parameters, field.name) < 0) return error.InvalidPhosphateExchangeParameter;
    if (inputs.monovalent_activity_coefficient <= 0 or inputs.divalent_activity_coefficient <= 0 or parameters.water_activity_product_mol2_per_m6 <= 0 or parameters.h2po4_dissociation_constant <= 0 or parameters.substrate_limit_fraction > 1) return error.InvalidPhosphateExchangeParameter;
}

test "phosphate exchange rates obey kinetic and substrate bounds" {
    const flux = try calculate(.{ .hydrogen_concentration_mol_per_m3 = 0.1, .hydrogen_activity_mol_per_m3 = 0.08, .hydroxide_activity_mol_per_m3 = 1e-6, .h2po4_concentration_mol_p_per_m3 = 0.2, .h2po4_activity_mol_p_per_m3 = 0.16, .hpo4_concentration_mol_p_per_m3 = 0.1, .hpo4_activity_mol_p_per_m3 = 0.06, .deprotonated_site_mol_per_megagram = 0.2, .hydroxyl_site_mol_per_megagram = 0.4, .protonated_site_mol_per_megagram = 0.3, .adsorbed_h2po4_mol_p_per_megagram = 0.05, .adsorbed_hpo4_mol_p_per_megagram = 0.05, .monovalent_activity_coefficient = 0.8, .divalent_activity_coefficient = 0.6 }, .{ .protonated_site_equilibrium_constant = 0.1, .hydroxyl_site_equilibrium_constant = 0.1, .h2po4_exchange_equilibrium_constant = 0.2, .hpo4_exchange_equilibrium_constant = 0.2, .water_activity_product_mol2_per_m6 = 1e-8, .h2po4_dissociation_constant = 1e-3, .maximum_exchange_mol_per_megagram_step = 0.01, .substrate_limit_fraction = 0.2 });
    inline for (@typeInfo(Flux).@"struct".fields) |field| try std.testing.expect(@abs(@field(flux, field.name)) <= 0.01);
}

test "empty phosphate exchange sites produce finite zero branches" {
    const flux = try calculate(.{ .hydrogen_concentration_mol_per_m3 = 0.1, .hydrogen_activity_mol_per_m3 = 0.1, .hydroxide_activity_mol_per_m3 = 1e-7, .h2po4_concentration_mol_p_per_m3 = 0.1, .h2po4_activity_mol_p_per_m3 = 0.1, .hpo4_concentration_mol_p_per_m3 = 0.1, .hpo4_activity_mol_p_per_m3 = 0.1, .deprotonated_site_mol_per_megagram = 0, .hydroxyl_site_mol_per_megagram = 0, .protonated_site_mol_per_megagram = 0, .adsorbed_h2po4_mol_p_per_megagram = 0, .adsorbed_hpo4_mol_p_per_megagram = 0, .monovalent_activity_coefficient = 1, .divalent_activity_coefficient = 1 }, .{ .protonated_site_equilibrium_constant = 1, .hydroxyl_site_equilibrium_constant = 1, .h2po4_exchange_equilibrium_constant = 1, .hpo4_exchange_equilibrium_constant = 1, .water_activity_product_mol2_per_m6 = 1e-8, .h2po4_dissociation_constant = 1e-3, .maximum_exchange_mol_per_megagram_step = 0.1, .substrate_limit_fraction = 0.2 });
    try std.testing.expectEqual(@as(f64, 0), flux.h2po4_with_protonated_site_mol_p_per_megagram);
}

test "SOLUTE 979-1082 admission gate preserves strict wet-capacity tests" {
    const inputs = Inputs{ .hydrogen_concentration_mol_per_m3 = 0.1, .hydrogen_activity_mol_per_m3 = 0.1, .hydroxide_activity_mol_per_m3 = 1.0e-7, .h2po4_concentration_mol_p_per_m3 = 0.1, .h2po4_activity_mol_p_per_m3 = 0.1, .hpo4_concentration_mol_p_per_m3 = 0.1, .hpo4_activity_mol_p_per_m3 = 0.1, .deprotonated_site_mol_per_megagram = 0.2, .hydroxyl_site_mol_per_megagram = 0.3, .protonated_site_mol_per_megagram = 0.4, .adsorbed_h2po4_mol_p_per_megagram = 0.05, .adsorbed_hpo4_mol_p_per_megagram = 0.05, .monovalent_activity_coefficient = 1, .divalent_activity_coefficient = 1 };
    const parameters = Parameters{ .protonated_site_equilibrium_constant = 0.1, .hydroxyl_site_equilibrium_constant = 0.1, .h2po4_exchange_equilibrium_constant = 0.1, .hpo4_exchange_equilibrium_constant = 0.1, .water_activity_product_mol2_per_m6 = 1.0e-8, .h2po4_dissociation_constant = 1.0e-3, .maximum_exchange_mol_per_megagram_step = 0.1, .substrate_limit_fraction = 0.2 };
    const inactive = try calculateAdmitted(inputs, parameters, .{ .phosphate_zone_water_volume_m3 = 1.0e-12, .minimum_water_volume_m3 = 1.0e-12, .anion_exchange_capacity_mol = 1, .minimum_exchange_capacity_mol = 1.0e-12 });
    try std.testing.expectEqualDeep(std.mem.zeroes(Flux), inactive);
    const no_capacity = try calculateAdmitted(inputs, parameters, .{ .phosphate_zone_water_volume_m3 = 1, .minimum_water_volume_m3 = 1.0e-12, .anion_exchange_capacity_mol = 1.0e-12, .minimum_exchange_capacity_mol = 1.0e-12 });
    try std.testing.expectEqualDeep(std.mem.zeroes(Flux), no_capacity);
    const active = try calculateAdmitted(inputs, parameters, .{ .phosphate_zone_water_volume_m3 = 1, .minimum_water_volume_m3 = 1.0e-12, .anion_exchange_capacity_mol = 1, .minimum_exchange_capacity_mol = 1.0e-12 });
    try std.testing.expectEqualDeep(try calculate(inputs, parameters), active);
}

test "SOLUTE line 1141 uses water product directly in band exchange" {
    const inputs = Inputs{ .hydrogen_concentration_mol_per_m3 = 2, .hydrogen_activity_mol_per_m3 = 2, .hydroxide_activity_mol_per_m3 = 3, .h2po4_concentration_mol_p_per_m3 = 2, .h2po4_activity_mol_p_per_m3 = 1, .hpo4_concentration_mol_p_per_m3 = 1, .hpo4_activity_mol_p_per_m3 = 1, .deprotonated_site_mol_per_megagram = 1, .hydroxyl_site_mol_per_megagram = 1, .protonated_site_mol_per_megagram = 2, .adsorbed_h2po4_mol_p_per_megagram = 0.4, .adsorbed_hpo4_mol_p_per_megagram = 0.4, .monovalent_activity_coefficient = 1, .divalent_activity_coefficient = 1 };
    const parameters = Parameters{ .protonated_site_equilibrium_constant = 0.1, .hydroxyl_site_equilibrium_constant = 0.1, .h2po4_exchange_equilibrium_constant = 0.1, .hpo4_exchange_equilibrium_constant = 0.1, .water_activity_product_mol2_per_m6 = 5, .h2po4_dissociation_constant = 1, .maximum_exchange_mol_per_megagram_step = 10, .substrate_limit_fraction = 1 };
    const non_band = try calculate(inputs, parameters);
    const band = try calculateBandSourceOrder(inputs, parameters);
    const band_equilibrium = 0.1 * 5.0 * 0.4 / 2.0;
    try std.testing.expectEqual(
        1.0 - band_equilibrium,
        band.h2po4_with_protonated_site_mol_p_per_megagram,
    );
    try std.testing.expect(
        band.h2po4_with_protonated_site_mol_p_per_megagram !=
            non_band.h2po4_with_protonated_site_mol_p_per_megagram,
    );
    const admitted = try calculateBandAdmitted(inputs, parameters, .{ .phosphate_zone_water_volume_m3 = 1, .minimum_water_volume_m3 = 0, .anion_exchange_capacity_mol = 1, .minimum_exchange_capacity_mol = 0 });
    try std.testing.expectEqualDeep(band, admitted);
}

test "phosphate exchange matches SOLUTE non-band source equations" {
    const inputs = Inputs{
        .hydrogen_concentration_mol_per_m3 = 0.1,
        .hydrogen_activity_mol_per_m3 = 0.08,
        .hydroxide_activity_mol_per_m3 = 1.25e-7,
        .h2po4_concentration_mol_p_per_m3 = 0.2,
        .h2po4_activity_mol_p_per_m3 = 0.16,
        .hpo4_concentration_mol_p_per_m3 = 0.1,
        .hpo4_activity_mol_p_per_m3 = 0.06,
        .deprotonated_site_mol_per_megagram = 0.2,
        .hydroxyl_site_mol_per_megagram = 0.4,
        .protonated_site_mol_per_megagram = 0.3,
        .adsorbed_h2po4_mol_p_per_megagram = 0.05,
        .adsorbed_hpo4_mol_p_per_megagram = 0.05,
        .monovalent_activity_coefficient = 0.8,
        .divalent_activity_coefficient = 0.6,
    };
    const parameters = Parameters{
        .protonated_site_equilibrium_constant = 0.1,
        .hydroxyl_site_equilibrium_constant = 0.02,
        .h2po4_exchange_equilibrium_constant = 0.2,
        .hpo4_exchange_equilibrium_constant = 0.2,
        .water_activity_product_mol2_per_m6 = 1.0e-8,
        .h2po4_dissociation_constant = 1.0e-3,
        .maximum_exchange_mol_per_megagram_step = 1,
        .substrate_limit_fraction = 0.5,
    };
    const result = try calculate(inputs, parameters);

    const protonated_equilibrium =
        parameters.protonated_site_equilibrium_constant *
        inputs.protonated_site_mol_per_megagram /
        inputs.hydrogen_activity_mol_per_m3;
    const hydroxyl_equilibrium =
        parameters.hydroxyl_site_equilibrium_constant *
        inputs.hydroxyl_site_mol_per_megagram /
        inputs.hydrogen_activity_mol_per_m3;
    const h2po4_protonated_equilibrium =
        parameters.h2po4_exchange_equilibrium_constant *
        inputs.hydrogen_activity_mol_per_m3 *
        inputs.hydroxide_activity_mol_per_m3 *
        inputs.adsorbed_h2po4_mol_p_per_megagram /
        inputs.protonated_site_mol_per_megagram;
    const h2po4_hydroxyl_equilibrium =
        parameters.h2po4_exchange_equilibrium_constant *
        inputs.hydroxide_activity_mol_per_m3 *
        inputs.adsorbed_h2po4_mol_p_per_megagram /
        inputs.hydroxyl_site_mol_per_megagram;
    const hpo4_equilibrium =
        parameters.hpo4_exchange_equilibrium_constant *
        parameters.water_activity_product_mol2_per_m6 /
        parameters.h2po4_dissociation_constant *
        inputs.adsorbed_hpo4_mol_p_per_megagram /
        inputs.hydroxyl_site_mol_per_megagram;

    try std.testing.expectEqual(
        bounded(
            inputs.hydroxyl_site_mol_per_megagram - protonated_equilibrium,
            1,
            0.5 * @min(
                inputs.hydrogen_concentration_mol_per_m3,
                inputs.hydroxyl_site_mol_per_megagram,
            ),
            0.5 * inputs.protonated_site_mol_per_megagram,
        ),
        result.protonated_to_hydroxyl_site_mol_per_megagram,
    );
    try std.testing.expectEqual(
        bounded(
            inputs.deprotonated_site_mol_per_megagram - hydroxyl_equilibrium,
            1,
            0.5 * @min(
                inputs.hydrogen_concentration_mol_per_m3,
                inputs.deprotonated_site_mol_per_megagram,
            ),
            0.5 * inputs.hydroxyl_site_mol_per_megagram,
        ),
        result.hydroxyl_to_deprotonated_site_mol_per_megagram,
    );
    try std.testing.expectEqual(
        bounded(
            (inputs.h2po4_activity_mol_p_per_m3 -
                h2po4_protonated_equilibrium) /
                inputs.monovalent_activity_coefficient,
            1,
            0.5 * @min(
                inputs.h2po4_concentration_mol_p_per_m3,
                inputs.protonated_site_mol_per_megagram,
            ),
            0.5 * inputs.adsorbed_h2po4_mol_p_per_megagram,
        ),
        result.h2po4_with_protonated_site_mol_p_per_megagram,
    );
    try std.testing.expectEqual(
        bounded(
            (inputs.h2po4_activity_mol_p_per_m3 -
                h2po4_hydroxyl_equilibrium) /
                inputs.monovalent_activity_coefficient,
            1,
            0.5 * @min(
                inputs.h2po4_concentration_mol_p_per_m3,
                inputs.hydroxyl_site_mol_per_megagram,
            ),
            0.5 * inputs.adsorbed_h2po4_mol_p_per_megagram,
        ),
        result.h2po4_with_hydroxyl_site_mol_p_per_megagram,
    );
    try std.testing.expectEqual(
        bounded(
            (inputs.hpo4_activity_mol_p_per_m3 - hpo4_equilibrium) /
                inputs.divalent_activity_coefficient,
            1,
            0.5 * @min(
                inputs.hpo4_concentration_mol_p_per_m3,
                inputs.hydroxyl_site_mol_per_megagram,
            ),
            0.5 * inputs.adsorbed_hpo4_mol_p_per_megagram,
        ),
        result.hpo4_with_hydroxyl_site_mol_p_per_megagram,
    );
}

test "SOLUTE 3075-3139 restricted exchange preserves source order and gate" {
    const inputs = Inputs{
        .hydrogen_concentration_mol_per_m3 = 2,
        .hydrogen_activity_mol_per_m3 = 2,
        .hydroxide_activity_mol_per_m3 = 3,
        .h2po4_concentration_mol_p_per_m3 = 2,
        .h2po4_activity_mol_p_per_m3 = 5,
        .hpo4_concentration_mol_p_per_m3 = 2,
        .hpo4_activity_mol_p_per_m3 = 5,
        .deprotonated_site_mol_per_megagram = 1,
        .hydroxyl_site_mol_per_megagram = 2,
        .protonated_site_mol_per_megagram = 2,
        .adsorbed_h2po4_mol_p_per_megagram = 0.4,
        .adsorbed_hpo4_mol_p_per_megagram = 0.4,
        .monovalent_activity_coefficient = 1,
        .divalent_activity_coefficient = 1,
    };
    const parameters = Parameters{
        .protonated_site_equilibrium_constant = 0.1,
        .hydroxyl_site_equilibrium_constant = 0.1,
        .h2po4_exchange_equilibrium_constant = 0.1,
        .hpo4_exchange_equilibrium_constant = 0.2,
        .water_activity_product_mol2_per_m6 = 5,
        .h2po4_dissociation_constant = 1,
        .maximum_exchange_mol_per_megagram_step = 10,
        .substrate_limit_fraction = 0.5,
    };
    const active = try calculateRestrictedSourceOrder(inputs, parameters, .{
        .anion_exchange_capacity_mol = 2,
        .minimum_exchange_capacity_mol = 1,
    });
    try std.testing.expectEqual(1, active.h2po4_with_protonated_site_mol_p_per_megagram);
    try std.testing.expectEqual(1, active.h2po4_with_hydroxyl_site_mol_p_per_megagram);
    try std.testing.expectEqual(1, active.hpo4_with_hydroxyl_site_mol_p_per_megagram);

    const equality_inactive = try calculateRestrictedSourceOrder(inputs, parameters, .{
        .anion_exchange_capacity_mol = 1,
        .minimum_exchange_capacity_mol = 1,
    });
    try std.testing.expectEqualDeep(std.mem.zeroes(RestrictedFlux), equality_inactive);
}

test "SOLUTE 3268-3307 restricted band exchange retains FIONX split" {
    const inputs = Inputs{
        .hydrogen_concentration_mol_per_m3 = 2,
        .hydrogen_activity_mol_per_m3 = 2,
        .hydroxide_activity_mol_per_m3 = 3,
        .h2po4_concentration_mol_p_per_m3 = 2,
        .h2po4_activity_mol_p_per_m3 = 5,
        .hpo4_concentration_mol_p_per_m3 = 2,
        .hpo4_activity_mol_p_per_m3 = 5,
        .deprotonated_site_mol_per_megagram = 1,
        .hydroxyl_site_mol_per_megagram = 2,
        .protonated_site_mol_per_megagram = 2,
        .adsorbed_h2po4_mol_p_per_megagram = 0.4,
        .adsorbed_hpo4_mol_p_per_megagram = 0.4,
        .monovalent_activity_coefficient = 1,
        .divalent_activity_coefficient = 1,
    };
    const parameters = Parameters{
        .protonated_site_equilibrium_constant = 0.1,
        .hydroxyl_site_equilibrium_constant = 0.1,
        .h2po4_exchange_equilibrium_constant = 0.1,
        .hpo4_exchange_equilibrium_constant = 0.2,
        .water_activity_product_mol2_per_m6 = 5,
        .h2po4_dissociation_constant = 1,
        .maximum_exchange_mol_per_megagram_step = 10,
        .substrate_limit_fraction = 0.5,
    };
    const active = try calculateRestrictedBandSourceOrder(inputs, parameters, .{
        .anion_exchange_capacity_mol = 2,
        .minimum_exchange_capacity_mol = 1,
    }, 0.25);
    try std.testing.expectEqual(1, active.h2po4_with_protonated_site_mol_p_per_megagram);
    try std.testing.expectEqual(0.5, active.h2po4_with_hydroxyl_site_mol_p_per_megagram);
    try std.testing.expectEqual(1, active.hpo4_with_hydroxyl_site_mol_p_per_megagram);

    const equality_inactive = try calculateRestrictedBandSourceOrder(inputs, parameters, .{
        .anion_exchange_capacity_mol = 1,
        .minimum_exchange_capacity_mol = 1,
    }, 0.25);
    try std.testing.expectEqualDeep(std.mem.zeroes(RestrictedFlux), equality_inactive);
}

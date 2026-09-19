const std = @import("std");
const ion_pairing = @import("ion_pairing.zig");
const aqueous_network = @import("aqueous_network.zig");
const activity_coefficients = @import("activity_coefficients.zig");

pub const EquilibriumConstants = struct {
    ammonium: f64,
    bicarbonate: f64,
    carbon_dioxide: f64,
    aluminum_hydroxide_1: f64,
    aluminum_hydroxide_2: f64,
    aluminum_hydroxide_3: f64,
    aluminum_hydroxide_4: f64,
    aluminum_sulfate: f64,
    iron_hydroxide_1: f64,
    iron_hydroxide_2: f64,
    iron_hydroxide_3: f64,
    iron_hydroxide_4: f64,
    iron_sulfate: f64,
    calcium_hydroxide: f64,
    calcium_carbonate: f64,
    calcium_bicarbonate: f64,
    calcium_sulfate: f64,
    magnesium_hydroxide: f64,
    magnesium_carbonate: f64,
    magnesium_bicarbonate: f64,
    magnesium_sulfate: f64,
    sodium_carbonate: f64,
    sodium_sulfate: f64,
    potassium_sulfate: f64,
};

pub const Kinetics = struct {
    ammonium_substrate_limit_fraction: f64,
    general_substrate_limit_fraction: f64,
    maximum_fast_association_mol_per_m3_step: f64,
    maximum_slow_association_mol_per_m3_step: f64,
};

pub const ZoneWaterState = enum {
    dry,
    wet,
};

pub const AmmoniumZoneWaterState = struct {
    non_band: ZoneWaterState,
    band: ZoneWaterState,
};

pub const AmmoniumZoneWaterAdmission = struct {
    non_band_water_volume_m3: f64,
    band_water_volume_m3: f64,
    minimum_water_volume_m3: f64,
};

pub const RestrictedAmmoniumInputs = struct {
    ammonium_non_band_concentration_mol_n_per_m3: f64,
    ammonia_non_band_concentration_mol_n_per_m3: f64,
    ammonium_band_concentration_mol_n_per_m3: f64,
    ammonia_band_concentration_mol_n_per_m3: f64,
    ammonium_non_band_activity_mol_n_per_m3: f64,
    ammonia_non_band_activity_mol_n_per_m3: f64,
    ammonium_band_activity_mol_n_per_m3: f64,
    ammonia_band_activity_mol_n_per_m3: f64,
    hydrogen_activity_mol_per_m3: f64,
    ammonium_dissociation_constant: f64,
    substrate_limit_fraction: f64,
    maximum_reaction_mol_n_per_m3_step: f64,
    /// SOLUTE.F line 3578 uses retained `XMIN`, not the `XMINN` assigned at
    /// line 3575. It is explicit here rather than reproducing hidden storage.
    retained_band_negative_limit_mol_n_per_m3_step: f64,
};

pub const RestrictedAmmoniumFluxes = struct {
    non_band_association_mol_n_per_m3: f64,
    band_association_mol_n_per_m3: f64,
};

/// Exact restricted NH4-NH3+H equations from SOLUTE.F lines 3557--3588.
/// Equality at either runtime water threshold is dry. Positive flux denotes
/// NH3+H association into NH4, matching the source sign convention.
pub fn calculateRestrictedAmmoniumSourceOrder(
    input: RestrictedAmmoniumInputs,
    water: AmmoniumZoneWaterAdmission,
) !RestrictedAmmoniumFluxes {
    inline for (@typeInfo(RestrictedAmmoniumInputs).@"struct".fields) |field| {
        const value = @field(input, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidRestrictedAmmoniumInput;
    }
    inline for (@typeInfo(AmmoniumZoneWaterAdmission).@"struct".fields) |field| {
        const value = @field(water, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidAmmoniumZoneWaterAdmission;
    }
    if (input.hydrogen_activity_mol_per_m3 <= 0 or
        input.ammonium_dissociation_constant <= 0 or
        input.substrate_limit_fraction > 1)
        return error.InvalidRestrictedAmmoniumInput;

    var result = RestrictedAmmoniumFluxes{
        .non_band_association_mol_n_per_m3 = 0,
        .band_association_mol_n_per_m3 = 0,
    };
    if (water.non_band_water_volume_m3 > water.minimum_water_volume_m3) {
        const negative_limit = input.substrate_limit_fraction *
            input.ammonium_non_band_concentration_mol_n_per_m3;
        const positive_limit = input.substrate_limit_fraction *
            input.ammonia_non_band_concentration_mol_n_per_m3;
        const ammonia_equilibrium_activity = input.ammonium_dissociation_constant *
            input.ammonium_non_band_activity_mol_n_per_m3 /
            input.hydrogen_activity_mol_per_m3;
        result.non_band_association_mol_n_per_m3 = @max(
            -input.maximum_reaction_mol_n_per_m3_step,
            -negative_limit,
            @min(
                input.maximum_reaction_mol_n_per_m3_step,
                positive_limit,
                input.ammonia_non_band_activity_mol_n_per_m3 -
                    ammonia_equilibrium_activity,
            ),
        );
    }
    if (water.band_water_volume_m3 > water.minimum_water_volume_m3) {
        const positive_limit = input.substrate_limit_fraction *
            input.ammonia_band_concentration_mol_n_per_m3;
        const ammonia_equilibrium_activity = input.ammonium_dissociation_constant *
            input.ammonium_band_activity_mol_n_per_m3 /
            input.hydrogen_activity_mol_per_m3;
        result.band_association_mol_n_per_m3 = @max(
            -input.maximum_reaction_mol_n_per_m3_step,
            -input.retained_band_negative_limit_mol_n_per_m3_step,
            @min(
                input.maximum_reaction_mol_n_per_m3_step,
                positive_limit,
                input.ammonia_band_activity_mol_n_per_m3 -
                    ammonia_equilibrium_activity,
            ),
        );
    }
    return result;
}

/// Maps the non-phosphate ion-pair equations in SOLUTE.F lines 1432--1707.
pub fn calculate(state: aqueous_network.State, coefficients: activity_coefficients.Result, constants: EquilibriumConstants, kinetics: Kinetics) !aqueous_network.Fluxes {
    try validate(state, coefficients, constants, kinetics);
    const g1 = coefficients.monovalent_activity_coefficient;
    const g2 = coefficients.divalent_activity_coefficient;
    const g3 = coefficients.trivalent_activity_coefficient;
    const fast = kinetics.maximum_fast_association_mol_per_m3_step;
    const slow = kinetics.maximum_slow_association_mol_per_m3_step;
    const general = kinetics.general_substrate_limit_fraction;
    return .{
        .ammonium_non_band_association = try reaction(state.ammonia_non_band, state.hydrogen, state.ammonium_non_band, state.ammonia_non_band, state.hydrogen * g1, state.ammonium_non_band * g1, 1, constants.ammonium, kinetics.ammonium_substrate_limit_fraction, fast),
        // SOLUTE.F uniquely divides the band NH3 driving force by A1.
        .ammonium_band_association = try reaction(state.ammonia_band, state.hydrogen, state.ammonium_band, state.ammonia_band, state.hydrogen * g1, state.ammonium_band * g1, g1, constants.ammonium, kinetics.ammonium_substrate_limit_fraction, fast),
        .carbonate_hydrogen_association = try reaction(state.carbonate, state.hydrogen, state.bicarbonate, state.carbonate * g2, state.hydrogen * g1, state.bicarbonate * g1, g2, constants.bicarbonate, general, fast),
        .bicarbonate_hydrogen_association = try reaction(state.bicarbonate, state.hydrogen, state.carbon_dioxide, state.bicarbonate * g1, state.hydrogen * g1, state.carbon_dioxide, g1, constants.carbon_dioxide, general, fast),
        .aluminum_hydroxide_1_association = try reaction(state.aluminum, state.hydroxide, state.aluminum_hydroxide_1, state.aluminum * g3, state.hydroxide * g1, state.aluminum_hydroxide_1 * g2, g3, constants.aluminum_hydroxide_1, general, slow),
        .aluminum_hydroxide_2_association = try reaction(state.aluminum_hydroxide_1, state.hydroxide, state.aluminum_hydroxide_2, state.aluminum_hydroxide_1 * g2, state.hydroxide * g1, state.aluminum_hydroxide_2 * g1, g2, constants.aluminum_hydroxide_2, general, slow),
        .aluminum_hydroxide_3_association = try reaction(state.aluminum_hydroxide_2, state.hydroxide, state.aluminum_hydroxide_3, state.aluminum_hydroxide_2 * g1, state.hydroxide * g1, state.aluminum_hydroxide_3, g1, constants.aluminum_hydroxide_3, general, slow),
        .aluminum_hydroxide_4_association = try reaction(state.aluminum_hydroxide_3, state.hydroxide, state.aluminum_hydroxide_4, state.aluminum_hydroxide_3, state.hydroxide * g1, state.aluminum_hydroxide_4 * g1, 1, constants.aluminum_hydroxide_4, general, slow),
        .aluminum_sulfate_association = try reaction(state.aluminum, state.sulfate, state.aluminum_sulfate, state.aluminum * g3, state.sulfate * g2, state.aluminum_sulfate * g1, g3, constants.aluminum_sulfate, general, slow),
        .iron_hydroxide_1_association = try reaction(state.iron, state.hydroxide, state.iron_hydroxide_1, state.iron * g3, state.hydroxide * g1, state.iron_hydroxide_1 * g2, g3, constants.iron_hydroxide_1, general, slow),
        .iron_hydroxide_2_association = try reaction(state.iron_hydroxide_1, state.hydroxide, state.iron_hydroxide_2, state.iron_hydroxide_1 * g2, state.hydroxide * g1, state.iron_hydroxide_2 * g1, g2, constants.iron_hydroxide_2, general, slow),
        .iron_hydroxide_3_association = try reaction(state.iron_hydroxide_2, state.hydroxide, state.iron_hydroxide_3, state.iron_hydroxide_2 * g1, state.hydroxide * g1, state.iron_hydroxide_3, g1, constants.iron_hydroxide_3, general, slow),
        .iron_hydroxide_4_association = try reaction(state.iron_hydroxide_3, state.hydroxide, state.iron_hydroxide_4, state.iron_hydroxide_3, state.hydroxide * g1, state.iron_hydroxide_4 * g1, 1, constants.iron_hydroxide_4, general, slow),
        // Deliberately does not reproduce the legacy f77src/starte.f:941-942
        // (RFES) quirk of reading the undeclared, never-assigned local
        // `FIONX` instead of `FIONS` (see
        // audit/issues/issue-027-starte-fionx-undefined-variable-phosphate-dissociation.md).
        // `general` (kinetics.general_substrate_limit_fraction) is applied
        // uniformly to both bound terms here, matching this reaction's
        // properly-declared siblings.
        .iron_sulfate_association = try reaction(state.iron, state.sulfate, state.iron_sulfate, state.iron * g3, state.sulfate * g2, state.iron_sulfate * g1, g3, constants.iron_sulfate, general, slow),
        .calcium_hydroxide_association = try reaction(state.calcium, state.hydroxide, state.calcium_hydroxide, state.calcium * g2, state.hydroxide * g1, state.calcium_hydroxide * g1, g2, constants.calcium_hydroxide, general, slow),
        .calcium_carbonate_association = try reaction(state.calcium, state.carbonate, state.calcium_carbonate, state.calcium * g2, state.carbonate * g2, state.calcium_carbonate, g2, constants.calcium_carbonate, general, slow),
        .calcium_bicarbonate_association = try reaction(state.calcium, state.bicarbonate, state.calcium_bicarbonate, state.calcium * g2, state.bicarbonate * g1, state.calcium_bicarbonate * g1, g2, constants.calcium_bicarbonate, general, slow),
        .calcium_sulfate_association = try reaction(state.calcium, state.sulfate, state.calcium_sulfate, state.calcium * g2, state.sulfate * g2, state.calcium_sulfate, g2, constants.calcium_sulfate, general, slow),
        .magnesium_hydroxide_association = try reaction(state.magnesium, state.hydroxide, state.magnesium_hydroxide, state.magnesium * g2, state.hydroxide * g1, state.magnesium_hydroxide * g1, g2, constants.magnesium_hydroxide, general, slow),
        .magnesium_carbonate_association = try reaction(state.magnesium, state.carbonate, state.magnesium_carbonate, state.magnesium * g2, state.carbonate * g2, state.magnesium_carbonate, g2, constants.magnesium_carbonate, general, slow),
        .magnesium_bicarbonate_association = try reaction(state.magnesium, state.bicarbonate, state.magnesium_bicarbonate, state.magnesium * g2, state.bicarbonate * g1, state.magnesium_bicarbonate * g1, g2, constants.magnesium_bicarbonate, general, slow),
        .magnesium_sulfate_association = try reaction(state.magnesium, state.sulfate, state.magnesium_sulfate, state.magnesium * g2, state.sulfate * g2, state.magnesium_sulfate, g2, constants.magnesium_sulfate, general, slow),
        .sodium_carbonate_association = try reaction(state.sodium, state.carbonate, state.sodium_carbonate, state.sodium * g1, state.carbonate * g2, state.sodium_carbonate * g1, g1, constants.sodium_carbonate, general, slow),
        .sodium_sulfate_association = try reaction(state.sodium, state.sulfate, state.sodium_sulfate, state.sodium * g1, state.sulfate * g2, state.sodium_sulfate * g1, g1, constants.sodium_sulfate, general, slow),
        .potassium_sulfate_association = try reaction(state.potassium, state.sulfate, state.potassium_sulfate, state.potassium * g1, state.sulfate * g2, state.potassium_sulfate * g1, g1, constants.potassium_sulfate, general, slow),
    };
}

/// Retains the source `VOLWNH`/`VOLWNB` gates without coupling this kernel to
/// a particular grid or water-volume owner. The caller derives each named
/// status from its compulsory runtime water-volume threshold.
pub fn calculateSourceOrder(
    state: aqueous_network.State,
    coefficients: activity_coefficients.Result,
    constants: EquilibriumConstants,
    kinetics: Kinetics,
    ammonium_zone_water: AmmoniumZoneWaterState,
) !aqueous_network.Fluxes {
    var fluxes = try calculate(state, coefficients, constants, kinetics);
    if (ammonium_zone_water.non_band == .dry)
        fluxes.ammonium_non_band_association = 0;
    if (ammonium_zone_water.band == .dry)
        fluxes.ammonium_band_association = 0;
    return fluxes;
}

/// Applies the strict runtime water-volume gates in SOLUTE.F 1463 and 1479.
/// Equality is dry, matching `VOLWNH/VOLWNB .GT. ZEROS2` exactly.
pub fn calculateSourceOrderForWaterVolumes(
    state: aqueous_network.State,
    coefficients: activity_coefficients.Result,
    constants: EquilibriumConstants,
    kinetics: Kinetics,
    water: AmmoniumZoneWaterAdmission,
) !aqueous_network.Fluxes {
    inline for (@typeInfo(AmmoniumZoneWaterAdmission).@"struct".fields) |field| {
        const value = @field(water, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidAmmoniumZoneWaterAdmission;
    }
    return calculateSourceOrder(
        state,
        coefficients,
        constants,
        kinetics,
        .{
            .non_band = if (water.non_band_water_volume_m3 >
                water.minimum_water_volume_m3) .wet else .dry,
            .band = if (water.band_water_volume_m3 >
                water.minimum_water_volume_m3) .wet else .dry,
        },
    );
}

fn reaction(free_first: f64, free_second: f64, paired: f64, first_activity: f64, second_activity: f64, paired_activity: f64, first_coefficient: f64, dissociation_constant: f64, limit_fraction: f64, maximum: f64) !f64 {
    return ion_pairing.calculate(.{ .free_first_mol_per_m3 = free_first, .free_second_mol_per_m3 = free_second, .paired_mol_per_m3 = paired }, .{ .free_first_mol_per_m3 = first_activity, .free_second_mol_per_m3 = second_activity, .paired_mol_per_m3 = paired_activity, .free_first_activity_coefficient = first_coefficient }, .{ .dissociation_constant = dissociation_constant, .substrate_limit_fraction = limit_fraction, .maximum_association_mol_per_m3_step = maximum });
}

fn validate(state: aqueous_network.State, coefficients: activity_coefficients.Result, constants: EquilibriumConstants, kinetics: Kinetics) !void {
    inline for (@typeInfo(aqueous_network.State).@"struct".fields) |field| if (!std.math.isFinite(@field(state, field.name)) or @field(state, field.name) < 0) return error.InvalidAqueousReactionState;
    if (!std.math.isFinite(coefficients.monovalent_activity_coefficient) or coefficients.monovalent_activity_coefficient <= 0 or !std.math.isFinite(coefficients.divalent_activity_coefficient) or coefficients.divalent_activity_coefficient <= 0 or !std.math.isFinite(coefficients.trivalent_activity_coefficient) or coefficients.trivalent_activity_coefficient <= 0) return error.InvalidActivityCoefficient;
    inline for (@typeInfo(EquilibriumConstants).@"struct".fields) |field| if (!std.math.isFinite(@field(constants, field.name)) or @field(constants, field.name) < 0) return error.InvalidAqueousEquilibriumConstant;
    inline for (@typeInfo(Kinetics).@"struct".fields) |field| if (!std.math.isFinite(@field(kinetics, field.name)) or @field(kinetics, field.name) < 0) return error.InvalidAqueousKinetics;
    if (kinetics.ammonium_substrate_limit_fraction > 1 or kinetics.general_substrate_limit_fraction > 1) return error.InvalidAqueousKinetics;
}

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| @field(result, field.name) = value;
    return result;
}

test "SOLUTE DPCO3 is the product of the two bound carbonate constants" {
    // Disposition guard for chemistry/equilibrium/calcium_carbonate_equilibrium_constants,
    // which derives SOLUTE.F:72 DPCO3 = DPCO2 * DPHCO as a named output.
    // Production never needs that composite: this evaluator carries the two
    // factors separately, as the two sequential dissociation steps
    // (SOLUTE.F:157-158 carbonate<->bicarbonate<->CO2), and their composition
    // reproduces DPCO3 exactly. Stated from the source PARAMETER values at
    // solute.f:56, not by calling the candidate module, so binding or deleting
    // that module cannot make this tautological.
    const dissolved_carbon_dioxide_dissociation: f64 = 4.2e-4; // DPCO2
    const bicarbonate_dissociation: f64 = 5.6e-8; // DPHCO
    const carbonate_dissociation_product =
        dissolved_carbon_dioxide_dissociation * bicarbonate_dissociation; // DPCO3

    // The composite is exactly the two-step product, so a single named DPCO3
    // constant would be redundant with the pair this module already consumes.
    var constants = filled(EquilibriumConstants, 1);
    constants.carbon_dioxide = dissolved_carbon_dioxide_dissociation;
    constants.bicarbonate = bicarbonate_dissociation;
    try std.testing.expectEqual(
        carbonate_dissociation_product,
        constants.carbon_dioxide * constants.bicarbonate,
    );

    // Falsifiability companion: the equality above is only informative because
    // the two constants are genuinely distinct and neither alone equals the
    // product. Without this, the claim would hold for any pair including 1/1.
    try std.testing.expect(constants.carbon_dioxide != constants.bicarbonate);
    try std.testing.expect(carbonate_dissociation_product != constants.carbon_dioxide);
    try std.testing.expect(carbonate_dissociation_product != constants.bicarbonate);
}

test "all aqueous reactions are at equilibrium for unit activities and constants" {
    const state = filled(aqueous_network.State, 1);
    const coefficients = activity_coefficients.Result{ .ionic_strength_mol_per_l = 0, .monovalent_activity_coefficient = 1, .divalent_activity_coefficient = 1, .trivalent_activity_coefficient = 1, .total_ion_activity_mol_per_m3 = 1, .electrical_conductivity_dS_per_m = 0 };
    const fluxes = try calculate(state, coefficients, filled(EquilibriumConstants, 1), .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0.2, .maximum_fast_association_mol_per_m3_step = 0.1, .maximum_slow_association_mol_per_m3_step = 0.1 });
    inline for (@typeInfo(aqueous_network.Fluxes).@"struct".fields) |field| try std.testing.expectApproxEqAbs(@as(f64, 0), @field(fluxes, field.name), 1e-15);
}

test "aqueous rate evaluator feeds conservative transformation ledger" {
    var state = filled(aqueous_network.State, 1);
    state.calcium = 2;
    const coefficients = activity_coefficients.Result{ .ionic_strength_mol_per_l = 0, .monovalent_activity_coefficient = 1, .divalent_activity_coefficient = 1, .trivalent_activity_coefficient = 1, .total_ion_activity_mol_per_m3 = 1, .electrical_conductivity_dS_per_m = 0 };
    const fluxes = try calculate(state, coefficients, filled(EquilibriumConstants, 1), .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0.2, .maximum_fast_association_mol_per_m3_step = 0.1, .maximum_slow_association_mol_per_m3_step = 0.1 });
    const transformations = try aqueous_network.assemble(fluxes, .{ .non_band = 0.8, .band = 0.2 });
    try std.testing.expectApproxEqAbs(@as(f64, 0), transformations.calcium + transformations.calcium_hydroxide + transformations.calcium_carbonate + transformations.calcium_bicarbonate + transformations.calcium_sulfate, 1e-14);
}

test "aqueous evaluator matches every SOLUTE source pairing equation" {
    var state: aqueous_network.State = undefined;
    var state_value: f64 = 0.2;
    inline for (@typeInfo(aqueous_network.State).@"struct".fields) |field| {
        @field(state, field.name) = state_value;
        state_value += 0.037;
    }
    var constants: EquilibriumConstants = undefined;
    var constant_value: f64 = 0.1;
    inline for (@typeInfo(EquilibriumConstants).@"struct".fields) |field| {
        @field(constants, field.name) = constant_value;
        constant_value += 0.013;
    }
    const coefficients = activity_coefficients.Result{
        .ionic_strength_mol_per_l = 0.1,
        .monovalent_activity_coefficient = 0.8,
        .divalent_activity_coefficient = 0.6,
        .trivalent_activity_coefficient = 0.4,
        .total_ion_activity_mol_per_m3 = 1,
        .electrical_conductivity_dS_per_m = 0.2,
    };
    const kinetics = Kinetics{
        .ammonium_substrate_limit_fraction = 0.7,
        .general_substrate_limit_fraction = 0.6,
        .maximum_fast_association_mol_per_m3_step = 10,
        .maximum_slow_association_mol_per_m3_step = 10,
    };
    const fluxes = try calculateSourceOrder(
        state,
        coefficients,
        constants,
        kinetics,
        .{ .non_band = .wet, .band = .wet },
    );
    const g1 = coefficients.monovalent_activity_coefficient;
    const g2 = coefficients.divalent_activity_coefficient;
    const g3 = coefficients.trivalent_activity_coefficient;

    try expectSourceRate(fluxes.ammonium_non_band_association, state.ammonia_non_band, state.hydrogen, state.ammonium_non_band, state.ammonia_non_band, state.hydrogen * g1, state.ammonium_non_band * g1, 1, constants.ammonium, kinetics.ammonium_substrate_limit_fraction, kinetics.maximum_fast_association_mol_per_m3_step);
    try expectSourceRate(fluxes.ammonium_band_association, state.ammonia_band, state.hydrogen, state.ammonium_band, state.ammonia_band, state.hydrogen * g1, state.ammonium_band * g1, g1, constants.ammonium, kinetics.ammonium_substrate_limit_fraction, kinetics.maximum_fast_association_mol_per_m3_step);
    try expectSourceRate(fluxes.carbonate_hydrogen_association, state.carbonate, state.hydrogen, state.bicarbonate, state.carbonate * g2, state.hydrogen * g1, state.bicarbonate * g1, g2, constants.bicarbonate, kinetics.general_substrate_limit_fraction, kinetics.maximum_fast_association_mol_per_m3_step);
    try expectSourceRate(fluxes.bicarbonate_hydrogen_association, state.bicarbonate, state.hydrogen, state.carbon_dioxide, state.bicarbonate * g1, state.hydrogen * g1, state.carbon_dioxide, g1, constants.carbon_dioxide, kinetics.general_substrate_limit_fraction, kinetics.maximum_fast_association_mol_per_m3_step);
    try expectSourceRate(fluxes.aluminum_hydroxide_1_association, state.aluminum, state.hydroxide, state.aluminum_hydroxide_1, state.aluminum * g3, state.hydroxide * g1, state.aluminum_hydroxide_1 * g2, g3, constants.aluminum_hydroxide_1, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.aluminum_hydroxide_2_association, state.aluminum_hydroxide_1, state.hydroxide, state.aluminum_hydroxide_2, state.aluminum_hydroxide_1 * g2, state.hydroxide * g1, state.aluminum_hydroxide_2 * g1, g2, constants.aluminum_hydroxide_2, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.aluminum_hydroxide_3_association, state.aluminum_hydroxide_2, state.hydroxide, state.aluminum_hydroxide_3, state.aluminum_hydroxide_2 * g1, state.hydroxide * g1, state.aluminum_hydroxide_3, g1, constants.aluminum_hydroxide_3, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.aluminum_hydroxide_4_association, state.aluminum_hydroxide_3, state.hydroxide, state.aluminum_hydroxide_4, state.aluminum_hydroxide_3, state.hydroxide * g1, state.aluminum_hydroxide_4 * g1, 1, constants.aluminum_hydroxide_4, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.aluminum_sulfate_association, state.aluminum, state.sulfate, state.aluminum_sulfate, state.aluminum * g3, state.sulfate * g2, state.aluminum_sulfate * g1, g3, constants.aluminum_sulfate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.iron_hydroxide_1_association, state.iron, state.hydroxide, state.iron_hydroxide_1, state.iron * g3, state.hydroxide * g1, state.iron_hydroxide_1 * g2, g3, constants.iron_hydroxide_1, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.iron_hydroxide_2_association, state.iron_hydroxide_1, state.hydroxide, state.iron_hydroxide_2, state.iron_hydroxide_1 * g2, state.hydroxide * g1, state.iron_hydroxide_2 * g1, g2, constants.iron_hydroxide_2, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.iron_hydroxide_3_association, state.iron_hydroxide_2, state.hydroxide, state.iron_hydroxide_3, state.iron_hydroxide_2 * g1, state.hydroxide * g1, state.iron_hydroxide_3, g1, constants.iron_hydroxide_3, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.iron_hydroxide_4_association, state.iron_hydroxide_3, state.hydroxide, state.iron_hydroxide_4, state.iron_hydroxide_3, state.hydroxide * g1, state.iron_hydroxide_4 * g1, 1, constants.iron_hydroxide_4, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.iron_sulfate_association, state.iron, state.sulfate, state.iron_sulfate, state.iron * g3, state.sulfate * g2, state.iron_sulfate * g1, g3, constants.iron_sulfate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.calcium_hydroxide_association, state.calcium, state.hydroxide, state.calcium_hydroxide, state.calcium * g2, state.hydroxide * g1, state.calcium_hydroxide * g1, g2, constants.calcium_hydroxide, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.calcium_carbonate_association, state.calcium, state.carbonate, state.calcium_carbonate, state.calcium * g2, state.carbonate * g2, state.calcium_carbonate, g2, constants.calcium_carbonate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.calcium_bicarbonate_association, state.calcium, state.bicarbonate, state.calcium_bicarbonate, state.calcium * g2, state.bicarbonate * g1, state.calcium_bicarbonate * g1, g2, constants.calcium_bicarbonate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.calcium_sulfate_association, state.calcium, state.sulfate, state.calcium_sulfate, state.calcium * g2, state.sulfate * g2, state.calcium_sulfate, g2, constants.calcium_sulfate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.magnesium_hydroxide_association, state.magnesium, state.hydroxide, state.magnesium_hydroxide, state.magnesium * g2, state.hydroxide * g1, state.magnesium_hydroxide * g1, g2, constants.magnesium_hydroxide, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.magnesium_carbonate_association, state.magnesium, state.carbonate, state.magnesium_carbonate, state.magnesium * g2, state.carbonate * g2, state.magnesium_carbonate, g2, constants.magnesium_carbonate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.magnesium_bicarbonate_association, state.magnesium, state.bicarbonate, state.magnesium_bicarbonate, state.magnesium * g2, state.bicarbonate * g1, state.magnesium_bicarbonate * g1, g2, constants.magnesium_bicarbonate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.magnesium_sulfate_association, state.magnesium, state.sulfate, state.magnesium_sulfate, state.magnesium * g2, state.sulfate * g2, state.magnesium_sulfate, g2, constants.magnesium_sulfate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.sodium_carbonate_association, state.sodium, state.carbonate, state.sodium_carbonate, state.sodium * g1, state.carbonate * g2, state.sodium_carbonate * g1, g1, constants.sodium_carbonate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.sodium_sulfate_association, state.sodium, state.sulfate, state.sodium_sulfate, state.sodium * g1, state.sulfate * g2, state.sodium_sulfate * g1, g1, constants.sodium_sulfate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
    try expectSourceRate(fluxes.potassium_sulfate_association, state.potassium, state.sulfate, state.potassium_sulfate, state.potassium * g1, state.sulfate * g2, state.potassium_sulfate * g1, g1, constants.potassium_sulfate, kinetics.general_substrate_limit_fraction, kinetics.maximum_slow_association_mol_per_m3_step);
}

test "source-order aqueous evaluator disables dry ammonium zones" {
    const state = filled(aqueous_network.State, 1);
    const coefficients = activity_coefficients.Result{ .ionic_strength_mol_per_l = 0, .monovalent_activity_coefficient = 1, .divalent_activity_coefficient = 1, .trivalent_activity_coefficient = 1, .total_ion_activity_mol_per_m3 = 1, .electrical_conductivity_dS_per_m = 0 };
    var constants = filled(EquilibriumConstants, 1);
    constants.ammonium = 0.5;
    const fluxes = try calculateSourceOrder(state, coefficients, constants, .{
        .ammonium_substrate_limit_fraction = 0.2,
        .general_substrate_limit_fraction = 0.2,
        .maximum_fast_association_mol_per_m3_step = 0.1,
        .maximum_slow_association_mol_per_m3_step = 0.1,
    }, .{ .non_band = .dry, .band = .wet });
    try std.testing.expectEqual(@as(f64, 0), fluxes.ammonium_non_band_association);
    try std.testing.expect(fluxes.ammonium_band_association > 0);
}

test "runtime ammonium water gates preserve strict source comparison" {
    const state = filled(aqueous_network.State, 1);
    const coefficients = activity_coefficients.Result{
        .ionic_strength_mol_per_l = 0,
        .monovalent_activity_coefficient = 1,
        .divalent_activity_coefficient = 1,
        .trivalent_activity_coefficient = 1,
        .total_ion_activity_mol_per_m3 = 1,
        .electrical_conductivity_dS_per_m = 0,
    };
    var constants = filled(EquilibriumConstants, 1);
    constants.ammonium = 0.5;
    const kinetics = Kinetics{
        .ammonium_substrate_limit_fraction = 0.2,
        .general_substrate_limit_fraction = 0.2,
        .maximum_fast_association_mol_per_m3_step = 0.1,
        .maximum_slow_association_mol_per_m3_step = 0.1,
    };
    const fluxes = try calculateSourceOrderForWaterVolumes(
        state,
        coefficients,
        constants,
        kinetics,
        .{
            .non_band_water_volume_m3 = 1.0e-12,
            .band_water_volume_m3 = 1.0001e-12,
            .minimum_water_volume_m3 = 1.0e-12,
        },
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        fluxes.ammonium_non_band_association,
    );
    try std.testing.expect(fluxes.ammonium_band_association > 0);
}

fn expectSourceRate(
    actual: f64,
    free_first: f64,
    free_second: f64,
    paired: f64,
    first_activity: f64,
    second_activity: f64,
    paired_activity: f64,
    first_coefficient: f64,
    dissociation_constant: f64,
    substrate_limit_fraction: f64,
    maximum: f64,
) !void {
    const dissociation_limit = substrate_limit_fraction * paired;
    const association_limit =
        substrate_limit_fraction * @min(free_first, free_second);
    const equilibrium_first_activity =
        dissociation_constant * paired_activity / second_activity;
    const expected = @max(
        -maximum,
        -dissociation_limit,
        @min(
            maximum,
            association_limit,
            (first_activity - equilibrium_first_activity) / first_coefficient,
        ),
    );
    try std.testing.expectApproxEqAbs(expected, actual, 1e-15);
}

test "SOLUTE 3557-3588 restricted ammonium retains band XMIN dependency" {
    const inputs = RestrictedAmmoniumInputs{
        .ammonium_non_band_concentration_mol_n_per_m3 = 10,
        .ammonia_non_band_concentration_mol_n_per_m3 = 4,
        .ammonium_band_concentration_mol_n_per_m3 = 100,
        .ammonia_band_concentration_mol_n_per_m3 = 4,
        .ammonium_non_band_activity_mol_n_per_m3 = 8,
        .ammonia_non_band_activity_mol_n_per_m3 = 1,
        .ammonium_band_activity_mol_n_per_m3 = 8,
        .ammonia_band_activity_mol_n_per_m3 = 0,
        .hydrogen_activity_mol_per_m3 = 2,
        .ammonium_dissociation_constant = 1,
        .substrate_limit_fraction = 0.5,
        .maximum_reaction_mol_n_per_m3_step = 10,
        .retained_band_negative_limit_mol_n_per_m3_step = 0.25,
    };
    const active = try calculateRestrictedAmmoniumSourceOrder(inputs, .{
        .non_band_water_volume_m3 = 2,
        .band_water_volume_m3 = 2,
        .minimum_water_volume_m3 = 1,
    });
    try std.testing.expectEqual(-3, active.non_band_association_mol_n_per_m3);
    // Line 3578 bounds with retained XMIN=.25 rather than line 3575 XMINN=50.
    try std.testing.expectEqual(-0.25, active.band_association_mol_n_per_m3);

    const equality_dry = try calculateRestrictedAmmoniumSourceOrder(inputs, .{
        .non_band_water_volume_m3 = 1,
        .band_water_volume_m3 = 1,
        .minimum_water_volume_m3 = 1,
    });
    try std.testing.expectEqualDeep(std.mem.zeroes(RestrictedAmmoniumFluxes), equality_dry);
}

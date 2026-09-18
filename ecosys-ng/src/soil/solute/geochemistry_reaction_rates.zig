const std = @import("std");
const aqueous_network = @import("aqueous_network.zig");
const geochemistry = @import("geochemistry_network.zig");
const mineral_precipitation = @import("mineral_precipitation.zig");
const silicate_weathering = @import("silicate_weathering.zig");
const activity_coefficients = @import("activity_coefficients.zig");

pub const SolubilityProducts = struct {
    gibbsite: f64,
    iron_hydroxide: f64,
    calcite: f64,
    gypsum: f64,
    aluminum_silicate: f64,
    iron_silicate: f64,
    calcium_silicate: f64,
    magnesium_silicate: f64,
    sodium_silicate: f64,
    potassium_silicate: f64,
};

pub const Kinetics = struct {
    general_substrate_limit_fraction: f64,
    hydrogen_coupled_substrate_limit_fraction: f64,
    maximum_hydroxide_mineral_mol_per_m3_step: f64,
    maximum_general_mineral_mol_per_m3_step: f64,
    calcite_hydroxide_inhibition_constant_mol_per_m3: f64,
    maximum_natural_weathering_mol_per_m3_step: f64,
    maximum_ground_weathering_mol_per_m3_step: f64,
};

pub const MineralCompletionState = struct {
    dissolved_aluminum_mol_per_m3: f64,
    dissolved_iron_mol_per_m3: f64,
    dissolved_calcium_mol_per_m3: f64,
    dissolved_hydroxide_mol_per_m3: f64,
    dissolved_carbonate_mol_per_m3: f64,
    dissolved_sulfate_mol_per_m3: f64,
    gibbsite_solid_mol_per_m3: f64,
    iron_hydroxide_solid_mol_per_m3: f64,
    calcite_solid_mol_per_m3: f64,
    gypsum_solid_mol_per_m3: f64,
};

pub const SourceOrderMineralCompletion = struct {
    extents: geochemistry.MineralExtents,
    final_state: MineralCompletionState,
};

pub fn calculate(shared: aqueous_network.State, solids: geochemistry.SolidState, coefficients: activity_coefficients.Result, products: SolubilityProducts, kinetics: Kinetics) !geochemistry.Transformations {
    try validate(shared, solids, coefficients, products, kinetics);
    const g1 = coefficients.monovalent_activity_coefficient;
    const g2 = coefficients.divalent_activity_coefficient;
    const g3 = coefficients.trivalent_activity_coefficient;
    const hydroxide_activity = shared.hydroxide * g1;
    // SOLUTE-013: solute.f lines 2520-2523 update dissolved Ca after calcite
    // precipitates before evaluating gypsum's extent at lines 2535-2541, so
    // gypsum must observe calcite's consumption of the shared Ca inventory
    // rather than the two extents drawing on the same initial Ca
    // independently (which double-counts a finite pool).
    const calcite_extent = try mineralExtent(shared.calcium, shared.carbonate, solids.calcite_solid_mol_per_m3, shared.calcium * g2, shared.carbonate * g2, .{ .first_mol_per_mol_solid = 1, .second_mol_per_mol_solid = 1 }, products.calcite, g2, kinetics.general_substrate_limit_fraction, kinetics.maximum_hydroxide_mineral_mol_per_m3_step, try mineral_precipitation.calciteDissolutionLimit(kinetics.maximum_hydroxide_mineral_mol_per_m3_step, hydroxide_activity, kinetics.calcite_hydroxide_inhibition_constant_mol_per_m3));
    const calcium_after_calcite = @max(0, shared.calcium - calcite_extent);
    const gypsum_extent = try mineralExtent(calcium_after_calcite, shared.sulfate, solids.gypsum_solid_mol_per_m3, calcium_after_calcite * g2, shared.sulfate * g2, .{ .first_mol_per_mol_solid = 1, .second_mol_per_mol_solid = 1 }, products.gypsum, g2, kinetics.hydrogen_coupled_substrate_limit_fraction, kinetics.maximum_general_mineral_mol_per_m3_step, kinetics.maximum_general_mineral_mol_per_m3_step);
    const mineral_extents = geochemistry.MineralExtents{
        .gibbsite_precipitation_mol_per_m3 = try mineralExtent(shared.aluminum, shared.hydroxide, solids.gibbsite_solid_mol_per_m3, shared.aluminum * g3, hydroxide_activity, .{ .first_mol_per_mol_solid = 1, .second_mol_per_mol_solid = 3 }, products.gibbsite, g3, kinetics.hydrogen_coupled_substrate_limit_fraction, kinetics.maximum_hydroxide_mineral_mol_per_m3_step, kinetics.maximum_hydroxide_mineral_mol_per_m3_step),
        .iron_hydroxide_precipitation_mol_per_m3 = try mineralExtent(shared.iron, shared.hydroxide, solids.iron_hydroxide_solid_mol_per_m3, shared.iron * g3, hydroxide_activity, .{ .first_mol_per_mol_solid = 1, .second_mol_per_mol_solid = 3 }, products.iron_hydroxide, g3, kinetics.hydrogen_coupled_substrate_limit_fraction, kinetics.maximum_hydroxide_mineral_mol_per_m3_step, kinetics.maximum_hydroxide_mineral_mol_per_m3_step),
        .calcite_precipitation_mol_per_m3 = calcite_extent,
        .gypsum_precipitation_mol_per_m3 = gypsum_extent,
    };
    const aluminum_weathering = try weather(shared, solids.aluminum_natural_silicate_mol_per_m3, solids.aluminum_ground_silicate_mol_per_m3, shared.aluminum, shared.aluminum * g3, products.aluminum_silicate, 3, 0.75, shared.hydrogen * g1, kinetics);
    const iron_weathering = try weather(shared, solids.iron_natural_silicate_mol_per_m3, solids.iron_ground_silicate_mol_per_m3, shared.iron, shared.iron * g3, products.iron_silicate, 3, 0.75, shared.hydrogen * g1, kinetics);
    const calcium_weathering = try weather(shared, solids.calcium_natural_silicate_mol_per_m3, solids.calcium_ground_silicate_mol_per_m3, shared.calcium, shared.calcium * g2, products.calcium_silicate, 2, 0.5, shared.hydrogen * g1, kinetics);
    const magnesium_weathering = try weather(shared, solids.magnesium_natural_silicate_mol_per_m3, solids.magnesium_ground_silicate_mol_per_m3, shared.magnesium, shared.magnesium * g2, products.magnesium_silicate, 2, 0.5, shared.hydrogen * g1, kinetics);
    const sodium_weathering = try weather(shared, solids.sodium_natural_silicate_mol_per_m3, solids.sodium_ground_silicate_mol_per_m3, shared.sodium, shared.sodium * g1, products.sodium_silicate, 1, 0.25, shared.hydrogen * g1, kinetics);
    const potassium_weathering = try weather(shared, solids.potassium_natural_silicate_mol_per_m3, solids.potassium_ground_silicate_mol_per_m3, shared.potassium, shared.potassium * g1, products.potassium_silicate, 1, 0.25, shared.hydrogen * g1, kinetics);
    const weathering = geochemistry.WeatheringExtents{
        .aluminum_natural_mol_per_m3 = aluminum_weathering.natural_rock_dissolution_mol_per_m3_step,
        .aluminum_ground_mol_per_m3 = aluminum_weathering.ground_rock_dissolution_mol_per_m3_step,
        .iron_natural_mol_per_m3 = iron_weathering.natural_rock_dissolution_mol_per_m3_step,
        .iron_ground_mol_per_m3 = iron_weathering.ground_rock_dissolution_mol_per_m3_step,
        .calcium_natural_mol_per_m3 = calcium_weathering.natural_rock_dissolution_mol_per_m3_step,
        .calcium_ground_mol_per_m3 = calcium_weathering.ground_rock_dissolution_mol_per_m3_step,
        .magnesium_natural_mol_per_m3 = magnesium_weathering.natural_rock_dissolution_mol_per_m3_step,
        .magnesium_ground_mol_per_m3 = magnesium_weathering.ground_rock_dissolution_mol_per_m3_step,
        .sodium_natural_mol_per_m3 = sodium_weathering.natural_rock_dissolution_mol_per_m3_step,
        .sodium_ground_mol_per_m3 = sodium_weathering.ground_rock_dissolution_mol_per_m3_step,
        .potassium_natural_mol_per_m3 = potassium_weathering.natural_rock_dissolution_mol_per_m3_step,
        .potassium_ground_mol_per_m3 = potassium_weathering.ground_rock_dissolution_mol_per_m3_step,
    };
    return geochemistry.assemble(mineral_extents, weathering);
}

/// Equation-order diagnostic for SOLUTE.F lines 2469-2548.
///
/// The source retains the hydroxide activity calculated before this block but
/// updates dissolved calcium after calcite before evaluating gypsum. It also
/// limits Al(OH)3 and Fe(OH)3 precipitation by dissolved metal alone rather
/// than by the three-hydroxide stoichiometry. This function preserves those
/// details for controlled comparisons without weakening production bounds.
pub fn calculateMineralsSourceOrder(initial: MineralCompletionState, coefficients: activity_coefficients.Result, products: SolubilityProducts, kinetics: Kinetics) !SourceOrderMineralCompletion {
    try validateSourceMineralInputs(initial, coefficients, products, kinetics);
    var state = initial;
    const g1 = coefficients.monovalent_activity_coefficient;
    const g2 = coefficients.divalent_activity_coefficient;
    const g3 = coefficients.trivalent_activity_coefficient;
    const hydroxide_activity = initial.dissolved_hydroxide_mol_per_m3 * g1;

    const gibbsite = sourceHydroxideMineralExtent(
        state.dissolved_aluminum_mol_per_m3,
        state.gibbsite_solid_mol_per_m3,
        hydroxide_activity,
        g3,
        products.gibbsite,
        kinetics.hydrogen_coupled_substrate_limit_fraction,
        kinetics.maximum_hydroxide_mineral_mol_per_m3_step,
    );
    state.dissolved_aluminum_mol_per_m3 -= gibbsite;
    state.dissolved_hydroxide_mol_per_m3 -= 3 * gibbsite;
    state.gibbsite_solid_mol_per_m3 += gibbsite;

    const iron_hydroxide = sourceHydroxideMineralExtent(
        state.dissolved_iron_mol_per_m3,
        state.iron_hydroxide_solid_mol_per_m3,
        hydroxide_activity,
        g3,
        products.iron_hydroxide,
        kinetics.hydrogen_coupled_substrate_limit_fraction,
        kinetics.maximum_hydroxide_mineral_mol_per_m3_step,
    );
    state.dissolved_iron_mol_per_m3 -= iron_hydroxide;
    state.dissolved_hydroxide_mol_per_m3 -= 3 * iron_hydroxide;
    state.iron_hydroxide_solid_mol_per_m3 += iron_hydroxide;

    const calcite = sourceBinaryMineralExtent(
        state.dissolved_calcium_mol_per_m3,
        state.dissolved_carbonate_mol_per_m3,
        state.calcite_solid_mol_per_m3,
        g2,
        products.calcite,
        kinetics.general_substrate_limit_fraction,
        kinetics.maximum_hydroxide_mineral_mol_per_m3_step,
        try mineral_precipitation.calciteDissolutionLimit(
            kinetics.maximum_hydroxide_mineral_mol_per_m3_step,
            hydroxide_activity,
            kinetics.calcite_hydroxide_inhibition_constant_mol_per_m3,
        ),
    );
    state.dissolved_calcium_mol_per_m3 -= calcite;
    state.dissolved_carbonate_mol_per_m3 -= calcite;
    state.calcite_solid_mol_per_m3 += calcite;

    const gypsum = sourceBinaryMineralExtent(
        state.dissolved_calcium_mol_per_m3,
        state.dissolved_sulfate_mol_per_m3,
        state.gypsum_solid_mol_per_m3,
        g2,
        products.gypsum,
        kinetics.hydrogen_coupled_substrate_limit_fraction,
        kinetics.maximum_general_mineral_mol_per_m3_step,
        kinetics.maximum_general_mineral_mol_per_m3_step,
    );
    state.dissolved_calcium_mol_per_m3 -= gypsum;
    state.dissolved_sulfate_mol_per_m3 -= gypsum;
    state.gypsum_solid_mol_per_m3 += gypsum;

    if (!allFinite(state)) return error.NonFiniteSourceOrderMineralState;
    return .{
        .extents = .{
            .gibbsite_precipitation_mol_per_m3 = gibbsite,
            .iron_hydroxide_precipitation_mol_per_m3 = iron_hydroxide,
            .calcite_precipitation_mol_per_m3 = calcite,
            .gypsum_precipitation_mol_per_m3 = gypsum,
        },
        .final_state = state,
    };
}

fn mineralExtent(first: f64, second: f64, solid: f64, first_activity: f64, second_activity: f64, stoichiometry: mineral_precipitation.Stoichiometry, product: f64, coefficient: f64, fraction: f64, precipitation_maximum: f64, dissolution_maximum: f64) !f64 {
    return mineral_precipitation.calculateExtent(.{ .dissolved_first_mol_per_m3 = first, .dissolved_second_mol_per_m3 = second, .solid_mol_per_m3 = solid }, first_activity, second_activity, stoichiometry, .{ .solubility_product = product, .first_activity_coefficient = coefficient, .substrate_limit_fraction = fraction, .maximum_precipitation_mol_per_m3_step = precipitation_maximum, .maximum_dissolution_mol_per_m3_step = dissolution_maximum });
}

fn weather(shared: aqueous_network.State, natural: f64, ground: f64, metal: f64, metal_activity: f64, product: f64, charge: u2, silicate_ratio: f64, hydrogen_activity: f64, kinetics: Kinetics) !silicate_weathering.Rates {
    return silicate_weathering.calculate(.{ .natural_rock_mol_per_m3 = natural, .ground_rock_mol_per_m3 = ground, .dissolved_metal_mol_per_m3 = metal, .dissolved_hydrogen_silicate_mol_per_m3 = shared.hydrogen_silicate, .hydrogen_mol_per_m3 = shared.hydrogen }, .{ .metal_charge = charge, .hydrogen_silicate_mol_per_mol_metal = silicate_ratio, .solubility_product = product }, metal_activity, hydrogen_activity, shared.hydrogen_silicate, kinetics.maximum_natural_weathering_mol_per_m3_step, kinetics.maximum_ground_weathering_mol_per_m3_step);
}

fn sourceHydroxideMineralExtent(metal: f64, solid: f64, hydroxide_activity: f64, metal_activity_coefficient: f64, solubility_product: f64, substrate_limit_fraction: f64, maximum_mol_per_m3_step: f64) f64 {
    const equilibrium_metal_activity = if (hydroxide_activity == 0)
        std.math.inf(f64)
    else
        solubility_product / std.math.pow(f64, hydroxide_activity, 3);
    return sourceClippedExtent(
        metal * metal_activity_coefficient,
        equilibrium_metal_activity,
        metal_activity_coefficient,
        substrate_limit_fraction * metal,
        solid,
        maximum_mol_per_m3_step,
        maximum_mol_per_m3_step,
    );
}

fn sourceBinaryMineralExtent(first: f64, second: f64, solid: f64, divalent_activity_coefficient: f64, solubility_product: f64, substrate_limit_fraction: f64, precipitation_maximum: f64, dissolution_maximum: f64) f64 {
    const second_activity = second * divalent_activity_coefficient;
    const equilibrium_first_activity = if (second_activity == 0)
        std.math.inf(f64)
    else
        solubility_product / second_activity;
    return sourceClippedExtent(
        first * divalent_activity_coefficient,
        equilibrium_first_activity,
        divalent_activity_coefficient,
        substrate_limit_fraction * @min(first, second),
        solid,
        precipitation_maximum,
        dissolution_maximum,
    );
}

fn sourceClippedExtent(first_activity: f64, equilibrium_first_activity: f64, first_activity_coefficient: f64, substrate_limit: f64, solid: f64, precipitation_maximum: f64, dissolution_maximum: f64) f64 {
    const driving_force = (first_activity - equilibrium_first_activity) / first_activity_coefficient;
    return @max(
        -@max(0, solid),
        -dissolution_maximum,
        @min(precipitation_maximum, substrate_limit, driving_force),
    );
}

fn validateSourceMineralInputs(state: MineralCompletionState, coefficients: activity_coefficients.Result, products: SolubilityProducts, kinetics: Kinetics) !void {
    inline for (@typeInfo(MineralCompletionState).@"struct".fields) |field| {
        const value = @field(state, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSourceOrderMineralState;
    }
    inline for (.{ products.gibbsite, products.iron_hydroxide, products.calcite, products.gypsum }) |product| {
        if (!std.math.isFinite(product) or product <= 0) return error.InvalidGeochemistrySolubilityProduct;
    }
    inline for (.{ coefficients.monovalent_activity_coefficient, coefficients.divalent_activity_coefficient, coefficients.trivalent_activity_coefficient }) |coefficient| {
        if (!std.math.isFinite(coefficient) or coefficient <= 0) return error.InvalidGeochemistryKinetics;
    }
    inline for (.{ kinetics.general_substrate_limit_fraction, kinetics.hydrogen_coupled_substrate_limit_fraction }) |fraction| {
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidGeochemistryKinetics;
    }
    inline for (.{ kinetics.maximum_hydroxide_mineral_mol_per_m3_step, kinetics.maximum_general_mineral_mol_per_m3_step }) |maximum| {
        if (!std.math.isFinite(maximum) or maximum < 0) return error.InvalidGeochemistryKinetics;
    }
    if (!std.math.isFinite(kinetics.calcite_hydroxide_inhibition_constant_mol_per_m3) or kinetics.calcite_hydroxide_inhibition_constant_mol_per_m3 <= 0) return error.InvalidGeochemistryKinetics;
}

fn allFinite(state: MineralCompletionState) bool {
    inline for (@typeInfo(MineralCompletionState).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(state, field.name))) return false;
    }
    return true;
}

fn validate(shared: aqueous_network.State, solids: geochemistry.SolidState, coefficients: activity_coefficients.Result, products: SolubilityProducts, kinetics: Kinetics) !void {
    inline for (@typeInfo(aqueous_network.State).@"struct".fields) |field| if (!std.math.isFinite(@field(shared, field.name)) or @field(shared, field.name) < 0) return error.InvalidGeochemistryAqueousState;
    inline for (@typeInfo(geochemistry.SolidState).@"struct".fields) |field| if (!std.math.isFinite(@field(solids, field.name)) or @field(solids, field.name) < 0) return error.InvalidGeochemistrySolidState;
    inline for (@typeInfo(SolubilityProducts).@"struct".fields) |field| if (!std.math.isFinite(@field(products, field.name)) or @field(products, field.name) <= 0) return error.InvalidGeochemistrySolubilityProduct;
    inline for (@typeInfo(Kinetics).@"struct".fields) |field| if (!std.math.isFinite(@field(kinetics, field.name)) or @field(kinetics, field.name) < 0) return error.InvalidGeochemistryKinetics;
    if (kinetics.general_substrate_limit_fraction > 1 or kinetics.hydrogen_coupled_substrate_limit_fraction > 1 or kinetics.calcite_hydroxide_inhibition_constant_mol_per_m3 <= 0 or coefficients.monovalent_activity_coefficient <= 0 or coefficients.divalent_activity_coefficient <= 0 or coefficients.trivalent_activity_coefficient <= 0) return error.InvalidGeochemistryKinetics;
}

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| @field(result, field.name) = value;
    return result;
}

test "shared rate evaluator feeds conservative mineral-weathering ledger" {
    const shared = filled(aqueous_network.State, 1);
    const solids = filled(geochemistry.SolidState, 1);
    const coefficients = activity_coefficients.Result{ .ionic_strength_mol_per_l = 0, .monovalent_activity_coefficient = 1, .divalent_activity_coefficient = 1, .trivalent_activity_coefficient = 1, .total_ion_activity_mol_per_m3 = 1, .electrical_conductivity_dS_per_m = 0 };
    const changes = try calculate(shared, solids, coefficients, filled(SolubilityProducts, 1), .{ .general_substrate_limit_fraction = 0.2, .hydrogen_coupled_substrate_limit_fraction = 0.2, .maximum_hydroxide_mineral_mol_per_m3_step = 0.1, .maximum_general_mineral_mol_per_m3_step = 0.1, .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1, .maximum_natural_weathering_mol_per_m3_step = 0.01, .maximum_ground_weathering_mol_per_m3_step = 0.02 });
    try std.testing.expectApproxEqAbs(@as(f64, 0), changes.dissolved_aluminum_mol_per_m3 + changes.gibbsite_solid_mol_per_m3 + changes.aluminum_natural_silicate_mol_per_m3 + changes.aluminum_ground_silicate_mol_per_m3, 1e-14);
    inline for (@typeInfo(geochemistry.Transformations).@"struct".fields) |field| try std.testing.expect(std.math.isFinite(@field(changes, field.name)));
}

test "source order applies calcite before gypsum" {
    const products = SolubilityProducts{
        .gibbsite = 1,
        .iron_hydroxide = 1,
        .calcite = 0.01,
        .gypsum = 0.01,
        .aluminum_silicate = 1,
        .iron_silicate = 1,
        .calcium_silicate = 1,
        .magnesium_silicate = 1,
        .sodium_silicate = 1,
        .potassium_silicate = 1,
    };
    const kinetics = Kinetics{
        .general_substrate_limit_fraction = 0.5,
        .hydrogen_coupled_substrate_limit_fraction = 0.5,
        .maximum_hydroxide_mineral_mol_per_m3_step = 0.4,
        .maximum_general_mineral_mol_per_m3_step = 0.4,
        .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1,
        .maximum_natural_weathering_mol_per_m3_step = 0,
        .maximum_ground_weathering_mol_per_m3_step = 0,
    };
    const coefficients = activity_coefficients.Result{
        .ionic_strength_mol_per_l = 0,
        .monovalent_activity_coefficient = 1,
        .divalent_activity_coefficient = 1,
        .trivalent_activity_coefficient = 1,
        .total_ion_activity_mol_per_m3 = 0,
        .electrical_conductivity_dS_per_m = 0,
    };
    const source = try calculateMineralsSourceOrder(.{
        .dissolved_aluminum_mol_per_m3 = 0,
        .dissolved_iron_mol_per_m3 = 0,
        .dissolved_calcium_mol_per_m3 = 0.5,
        .dissolved_hydroxide_mol_per_m3 = 1,
        .dissolved_carbonate_mol_per_m3 = 0.5,
        .dissolved_sulfate_mol_per_m3 = 0.5,
        .gibbsite_solid_mol_per_m3 = 0,
        .iron_hydroxide_solid_mol_per_m3 = 0,
        .calcite_solid_mol_per_m3 = 0.1,
        .gypsum_solid_mol_per_m3 = 0.1,
    }, coefficients, products, kinetics);
    try std.testing.expectEqual(@as(f64, 0.25), source.extents.calcite_precipitation_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.125), source.extents.gypsum_precipitation_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.125), source.final_state.dissolved_calcium_mol_per_m3);

    var simultaneous_aqueous = filled(aqueous_network.State, 0);
    simultaneous_aqueous.calcium = 0.5;
    simultaneous_aqueous.hydroxide = 1;
    simultaneous_aqueous.carbonate = 0.5;
    simultaneous_aqueous.sulfate = 0.5;
    simultaneous_aqueous.hydrogen = 1;
    var simultaneous_solids = filled(geochemistry.SolidState, 0);
    simultaneous_solids.calcite_solid_mol_per_m3 = 0.1;
    simultaneous_solids.gypsum_solid_mol_per_m3 = 0.1;
    // SOLUTE-013 fix: production `calculate` now sequences gypsum after
    // calcite's Ca consumption, so it matches the source-order extents above
    // rather than drawing both minerals from the same initial Ca pool.
    const simultaneous = try calculate(simultaneous_aqueous, simultaneous_solids, coefficients, products, kinetics);
    try std.testing.expectEqual(@as(f64, 0.25), simultaneous.calcite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.125), simultaneous.gypsum_solid_mol_per_m3);
}

test "source hydroxide mineral limiter can overdraw hydroxide" {
    var products = filled(SolubilityProducts, 1);
    products.gibbsite = 0.001;
    products.iron_hydroxide = 0.001;
    const coefficients = activity_coefficients.Result{
        .ionic_strength_mol_per_l = 0,
        .monovalent_activity_coefficient = 1,
        .divalent_activity_coefficient = 1,
        .trivalent_activity_coefficient = 1,
        .total_ion_activity_mol_per_m3 = 0,
        .electrical_conductivity_dS_per_m = 0,
    };
    const kinetics = Kinetics{
        .general_substrate_limit_fraction = 0.5,
        .hydrogen_coupled_substrate_limit_fraction = 0.5,
        .maximum_hydroxide_mineral_mol_per_m3_step = 0.4,
        .maximum_general_mineral_mol_per_m3_step = 0.4,
        .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1,
        .maximum_natural_weathering_mol_per_m3_step = 0,
        .maximum_ground_weathering_mol_per_m3_step = 0,
    };
    const source = try calculateMineralsSourceOrder(.{
        .dissolved_aluminum_mol_per_m3 = 0.4,
        .dissolved_iron_mol_per_m3 = 0.3,
        .dissolved_calcium_mol_per_m3 = 0,
        .dissolved_hydroxide_mol_per_m3 = 0.2,
        .dissolved_carbonate_mol_per_m3 = 0,
        .dissolved_sulfate_mol_per_m3 = 0,
        .gibbsite_solid_mol_per_m3 = 0.1,
        .iron_hydroxide_solid_mol_per_m3 = 0.1,
        .calcite_solid_mol_per_m3 = 0,
        .gypsum_solid_mol_per_m3 = 0,
    }, coefficients, products, kinetics);
    try std.testing.expectEqual(@as(f64, 0.2), source.extents.gibbsite_precipitation_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.15), source.extents.iron_hydroxide_precipitation_mol_per_m3);
    try std.testing.expectApproxEqAbs(@as(f64, -0.85), source.final_state.dissolved_hydroxide_mol_per_m3, 1e-15);

    var bounded_aqueous = filled(aqueous_network.State, 0);
    bounded_aqueous.aluminum = 0.4;
    bounded_aqueous.iron = 0.3;
    bounded_aqueous.hydroxide = 0.2;
    bounded_aqueous.hydrogen = 1;
    var bounded_solids = filled(geochemistry.SolidState, 0);
    bounded_solids.gibbsite_solid_mol_per_m3 = 0.1;
    bounded_solids.iron_hydroxide_solid_mol_per_m3 = 0.1;
    const bounded = try calculate(bounded_aqueous, bounded_solids, coefficients, products, kinetics);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 30.0), bounded.gibbsite_solid_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 30.0), bounded.iron_hydroxide_solid_mol_per_m3, 1e-15);
}

const std = @import("std");

pub const State = struct {
    dissolved_cation_mol_per_m3: f64,
    dissolved_phosphate_mol_p_per_m3: f64,
    precipitate_mol_per_m3: f64,
};

pub const Stoichiometry = struct {
    cation_mol_per_mol_precipitate: f64,
    phosphorus_mol_per_mol_precipitate: f64,
};

pub const Kinetics = struct {
    substrate_limit_fraction: f64,
    maximum_precipitation_mol_per_m3_step: f64,
    maximum_dissolution_mol_per_m3_step: f64,
    phosphate_activity_coefficient: f64,
};

/// Positive extent precipitates and negative extent dissolves. Unlike the
/// original repeated loop, bounds account for mineral stoichiometry directly.
pub fn calculateExtent(state: State, phosphate_activity_mol_p_per_m3: f64, equilibrium_phosphate_activity_mol_p_per_m3: f64, stoichiometry: Stoichiometry, kinetics: Kinetics) !f64 {
    try validate(state, phosphate_activity_mol_p_per_m3, equilibrium_phosphate_activity_mol_p_per_m3, stoichiometry, kinetics);
    const available_extent = @min(
        state.dissolved_cation_mol_per_m3 / stoichiometry.cation_mol_per_mol_precipitate,
        state.dissolved_phosphate_mol_p_per_m3 / stoichiometry.phosphorus_mol_per_mol_precipitate,
    );
    const precipitation_limit = kinetics.substrate_limit_fraction * available_extent;
    const dissolution_limit = state.precipitate_mol_per_m3;
    const driving_force = (phosphate_activity_mol_p_per_m3 - equilibrium_phosphate_activity_mol_p_per_m3) /
        kinetics.phosphate_activity_coefficient;
    return @max(
        -kinetics.maximum_dissolution_mol_per_m3_step,
        -dissolution_limit,
        @min(kinetics.maximum_precipitation_mol_per_m3_step, precipitation_limit, driving_force),
    );
}

/// Fixed-pH surface branch from SOLUTE.F 2962--3049. Its XMIN limiter uses
/// only the corresponding phosphate concentration; unlike the dynamic/band
/// branch it does not include dissolved metal in the precipitation cap.
pub fn calculateExtentWithPhosphateOnlyPrecipitationLimit(
    state: State,
    phosphate_activity_mol_p_per_m3: f64,
    equilibrium_phosphate_activity_mol_p_per_m3: f64,
    stoichiometry: Stoichiometry,
    kinetics: Kinetics,
) !f64 {
    try validate(
        state,
        phosphate_activity_mol_p_per_m3,
        equilibrium_phosphate_activity_mol_p_per_m3,
        stoichiometry,
        kinetics,
    );
    const precipitation_limit = kinetics.substrate_limit_fraction *
        state.dissolved_phosphate_mol_p_per_m3 /
        stoichiometry.phosphorus_mol_per_mol_precipitate;
    const driving_force =
        (phosphate_activity_mol_p_per_m3 -
            equilibrium_phosphate_activity_mol_p_per_m3) /
        kinetics.phosphate_activity_coefficient;
    return @max(
        -kinetics.maximum_dissolution_mol_per_m3_step,
        -state.precipitate_mol_per_m3,
        @min(
            kinetics.maximum_precipitation_mol_per_m3_step,
            precipitation_limit,
            driving_force,
        ),
    );
}

pub fn state_update(state: *State, extent_mol_per_m3: f64, stoichiometry: Stoichiometry) !void {
    try validateState(state.*);
    try validateStoichiometry(stoichiometry);
    if (!std.math.isFinite(extent_mol_per_m3)) return error.NonFinitePrecipitationExtent;
    var next = state.*;
    next.dissolved_cation_mol_per_m3 -= extent_mol_per_m3 * stoichiometry.cation_mol_per_mol_precipitate;
    next.dissolved_phosphate_mol_p_per_m3 -= extent_mol_per_m3 * stoichiometry.phosphorus_mol_per_mol_precipitate;
    next.precipitate_mol_per_m3 += extent_mol_per_m3;
    try validateState(next);
    try conserved(
        state.dissolved_cation_mol_per_m3 + state.precipitate_mol_per_m3 * stoichiometry.cation_mol_per_mol_precipitate,
        next.dissolved_cation_mol_per_m3 + next.precipitate_mol_per_m3 * stoichiometry.cation_mol_per_mol_precipitate,
    );
    try conserved(
        state.dissolved_phosphate_mol_p_per_m3 + state.precipitate_mol_per_m3 * stoichiometry.phosphorus_mol_per_mol_precipitate,
        next.dissolved_phosphate_mol_p_per_m3 + next.precipitate_mol_per_m3 * stoichiometry.phosphorus_mol_per_mol_precipitate,
    );
    state.* = next;
}

pub fn aluminumOrIronPhosphateEquilibriumH2po4(solubility_product: f64, hydrogen_activity_mol_per_m3: f64, h2po4_dissociation_constant: f64, hpo4_dissociation_constant: f64, metal_activity_mol_per_m3: f64) !f64 {
    try positiveFinite(&.{ solubility_product, hydrogen_activity_mol_per_m3, h2po4_dissociation_constant, hpo4_dissociation_constant });
    try nonnegativeFinite(metal_activity_mol_per_m3);
    if (metal_activity_mol_per_m3 == 0) return std.math.floatMax(f64);
    const target = solubility_product * hydrogen_activity_mol_per_m3 * hydrogen_activity_mol_per_m3 /
        (h2po4_dissociation_constant * hpo4_dissociation_constant * metal_activity_mol_per_m3);
    return finiteOrMaximum(target);
}

pub fn dicalciumPhosphateEquilibriumHpo4(solubility_product: f64, calcium_activity_mol_per_m3: f64) !f64 {
    try positiveFinite(&.{solubility_product});
    try nonnegativeFinite(calcium_activity_mol_per_m3);
    if (calcium_activity_mol_per_m3 == 0) return std.math.floatMax(f64);
    return finiteOrMaximum(solubility_product / calcium_activity_mol_per_m3);
}

pub fn monocalciumPhosphateEquilibriumH2po4(solubility_product: f64, calcium_activity_mol_per_m3: f64) !f64 {
    try positiveFinite(&.{solubility_product});
    try nonnegativeFinite(calcium_activity_mol_per_m3);
    if (calcium_activity_mol_per_m3 == 0) return std.math.floatMax(f64);
    return finiteOrMaximum(@sqrt(solubility_product / calcium_activity_mol_per_m3));
}

pub fn hydroxyapatiteEquilibriumH2po4(solubility_product: f64, hydrogen_activity_mol_per_m3: f64, hydroxide_activity_mol_per_m3: f64, calcium_activity_mol_per_m3: f64, h2po4_dissociation_constant: f64, hpo4_dissociation_constant: f64) !f64 {
    try positiveFinite(&.{ solubility_product, hydrogen_activity_mol_per_m3, hydroxide_activity_mol_per_m3, h2po4_dissociation_constant, hpo4_dissociation_constant });
    try nonnegativeFinite(calcium_activity_mol_per_m3);
    if (calcium_activity_mol_per_m3 == 0) return std.math.floatMax(f64);
    const ratio = solubility_product * std.math.pow(f64, hydrogen_activity_mol_per_m3, 6) /
        (std.math.pow(f64, calcium_activity_mol_per_m3, 5) * hydroxide_activity_mol_per_m3 *
            std.math.pow(f64, h2po4_dissociation_constant * hpo4_dissociation_constant, 3));
    if (std.math.isNan(ratio) or ratio < 0) return error.InvalidPhosphateEquilibrium;
    if (std.math.isInf(ratio)) return std.math.floatMax(f64);
    return finiteOrMaximum(std.math.cbrt(ratio));
}

fn validate(state: State, activity: f64, equilibrium: f64, stoichiometry: Stoichiometry, kinetics: Kinetics) !void {
    try validateState(state);
    try validateStoichiometry(stoichiometry);
    if (!std.math.isFinite(activity) or activity < 0 or !std.math.isFinite(equilibrium) or equilibrium < 0 or
        !std.math.isFinite(kinetics.substrate_limit_fraction) or kinetics.substrate_limit_fraction < 0 or kinetics.substrate_limit_fraction > 1 or
        !std.math.isFinite(kinetics.maximum_precipitation_mol_per_m3_step) or kinetics.maximum_precipitation_mol_per_m3_step < 0 or
        !std.math.isFinite(kinetics.maximum_dissolution_mol_per_m3_step) or kinetics.maximum_dissolution_mol_per_m3_step < 0 or
        !std.math.isFinite(kinetics.phosphate_activity_coefficient) or kinetics.phosphate_activity_coefficient <= 0)
        return error.InvalidPhosphatePrecipitationParameter;
}

fn validateState(state: State) !void {
    inline for (@typeInfo(State).@"struct".fields) |field| {
        const value = @field(state, field.name);
        if (!std.math.isFinite(value)) return error.NonFinitePhosphatePrecipitationState;
        if (value < 0) return error.NegativePhosphatePrecipitationState;
    }
}

fn validateStoichiometry(stoichiometry: Stoichiometry) !void {
    if (!std.math.isFinite(stoichiometry.cation_mol_per_mol_precipitate) or stoichiometry.cation_mol_per_mol_precipitate <= 0 or
        !std.math.isFinite(stoichiometry.phosphorus_mol_per_mol_precipitate) or stoichiometry.phosphorus_mol_per_mol_precipitate <= 0)
        return error.InvalidPhosphatePrecipitationStoichiometry;
}

fn positiveFinite(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidPhosphateEquilibrium;
}

fn nonnegativeFinite(value: f64) !void {
    if (!std.math.isFinite(value) or value < 0)
        return error.InvalidPhosphateEquilibrium;
}

fn finiteOrMaximum(value: f64) !f64 {
    if (std.math.isNan(value) or value < 0)
        return error.InvalidPhosphateEquilibrium;
    return if (std.math.isInf(value)) std.math.floatMax(f64) else value;
}

fn conserved(before: f64, after: f64) !void {
    if (@abs(before - after) > 1e-12 * @max(1.0, @abs(before), @abs(after))) return error.PhosphatePrecipitationConservationFailure;
}

test "hydroxyapatite precipitation is stoichiometrically bounded and conservative" {
    const stoichiometry = Stoichiometry{ .cation_mol_per_mol_precipitate = 5, .phosphorus_mol_per_mol_precipitate = 3 };
    var state = State{ .dissolved_cation_mol_per_m3 = 0.5, .dissolved_phosphate_mol_p_per_m3 = 0.15, .precipitate_mol_per_m3 = 0.02 };
    const extent = try calculateExtent(state, 0.2, 0.01, stoichiometry, .{ .substrate_limit_fraction = 0.2, .maximum_precipitation_mol_per_m3_step = 0.1, .maximum_dissolution_mol_per_m3_step = 0.1, .phosphate_activity_coefficient = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), extent, 1e-15);
    const calcium_before = state.dissolved_cation_mol_per_m3 + 5 * state.precipitate_mol_per_m3;
    const phosphorus_before = state.dissolved_phosphate_mol_p_per_m3 + 3 * state.precipitate_mol_per_m3;
    try state_update(&state, extent, stoichiometry);
    try std.testing.expectApproxEqAbs(calcium_before, state.dissolved_cation_mol_per_m3 + 5 * state.precipitate_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(phosphorus_before, state.dissolved_phosphate_mol_p_per_m3 + 3 * state.precipitate_mol_per_m3, 1e-15);
}

test "phosphate mineral dissolution cannot exceed precipitate inventory" {
    const extent = try calculateExtent(.{ .dissolved_cation_mol_per_m3 = 0, .dissolved_phosphate_mol_p_per_m3 = 0, .precipitate_mol_per_m3 = 0.03 }, 0, 1, .{ .cation_mol_per_mol_precipitate = 1, .phosphorus_mol_per_mol_precipitate = 1 }, .{ .substrate_limit_fraction = 0.2, .maximum_precipitation_mol_per_m3_step = 0.1, .maximum_dissolution_mol_per_m3_step = 0.1, .phosphate_activity_coefficient = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, -0.03), extent, 1e-15);
}

test "zero dissolved metal yields the dissolution-side equilibrium limit" {
    const target = try aluminumOrIronPhosphateEquilibriumH2po4(
        1,
        1,
        1,
        1,
        0,
    );
    try std.testing.expectEqual(std.math.floatMax(f64), target);
    const extent = try calculateExtent(
        .{
            .dissolved_cation_mol_per_m3 = 0,
            .dissolved_phosphate_mol_p_per_m3 = 0.2,
            .precipitate_mol_per_m3 = 0.03,
        },
        0.2,
        target,
        .{
            .cation_mol_per_mol_precipitate = 1,
            .phosphorus_mol_per_mol_precipitate = 1,
        },
        .{
            .substrate_limit_fraction = 0.2,
            .maximum_precipitation_mol_per_m3_step = 0.1,
            .maximum_dissolution_mol_per_m3_step = 0.1,
            .phosphate_activity_coefficient = 1,
        },
    );
    try std.testing.expectApproxEqAbs(@as(f64, -0.03), extent, 1e-15);
}

test "fixed-pH precipitation limiter follows phosphate without metal cap" {
    const state = State{
        .dissolved_cation_mol_per_m3 = 1e-6,
        .dissolved_phosphate_mol_p_per_m3 = 0.5,
        .precipitate_mol_per_m3 = 0,
    };
    const kinetics = Kinetics{
        .substrate_limit_fraction = 0.2,
        .maximum_precipitation_mol_per_m3_step = 1,
        .maximum_dissolution_mol_per_m3_step = 1,
        .phosphate_activity_coefficient = 1,
    };
    const stoichiometry = Stoichiometry{
        .cation_mol_per_mol_precipitate = 1,
        .phosphorus_mol_per_mol_precipitate = 1,
    };
    try std.testing.expectApproxEqAbs(
        @as(f64, 1e-6 * 0.2),
        try calculateExtent(state, 1, 0, stoichiometry, kinetics),
        1e-18,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1),
        try calculateExtentWithPhosphateOnlyPrecipitationLimit(
            state,
            1,
            0,
            stoichiometry,
            kinetics,
        ),
        1e-15,
    );
}

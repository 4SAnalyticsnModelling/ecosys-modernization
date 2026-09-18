const std = @import("std");

pub const State = struct {
    dissolved_first_mol_per_m3: f64,
    dissolved_second_mol_per_m3: f64,
    solid_mol_per_m3: f64,
};

pub const Stoichiometry = struct {
    first_mol_per_mol_solid: f64,
    second_mol_per_mol_solid: f64,
};

pub const Parameters = struct {
    solubility_product: f64,
    first_activity_coefficient: f64,
    substrate_limit_fraction: f64,
    maximum_precipitation_mol_per_m3_step: f64,
    maximum_dissolution_mol_per_m3_step: f64,
};

/// Binary mineral A_a B_b(s), covering gibbsite/Fe(OH)3, calcite and gypsum.
pub fn calculateExtent(state: State, first_activity_mol_per_m3: f64, second_activity_mol_per_m3: f64, stoichiometry: Stoichiometry, parameters: Parameters) !f64 {
    try validate(state, first_activity_mol_per_m3, second_activity_mol_per_m3, stoichiometry, parameters);
    // A zero partner activity is a valid, completely undersaturated state.
    // Evaluating Ksp / 0 would manufacture infinity; its exact limiting
    // extent is bounded dissolution of the existing solid inventory.
    if (second_activity_mol_per_m3 == 0)
        return @max(-parameters.maximum_dissolution_mol_per_m3_step, -state.solid_mol_per_m3);
    const equilibrium_first_activity = parameters.solubility_product /
        std.math.pow(f64, second_activity_mol_per_m3, stoichiometry.second_mol_per_mol_solid / stoichiometry.first_mol_per_mol_solid);
    if (!std.math.isFinite(equilibrium_first_activity)) return error.NonFiniteMineralEquilibrium;
    const available = @min(
        state.dissolved_first_mol_per_m3 / stoichiometry.first_mol_per_mol_solid,
        state.dissolved_second_mol_per_m3 / stoichiometry.second_mol_per_mol_solid,
    );
    const precipitation_limit = parameters.substrate_limit_fraction * available;
    const driving_force = (first_activity_mol_per_m3 - equilibrium_first_activity) /
        parameters.first_activity_coefficient;
    return @max(
        -parameters.maximum_dissolution_mol_per_m3_step,
        -state.solid_mol_per_m3,
        @min(parameters.maximum_precipitation_mol_per_m3_step, precipitation_limit, driving_force),
    );
}

pub fn state_update(state: *State, extent_mol_per_m3: f64, stoichiometry: Stoichiometry) !void {
    try validateState(state.*);
    try validateStoichiometry(stoichiometry);
    if (!std.math.isFinite(extent_mol_per_m3)) return error.NonFiniteMineralExtent;
    var next = state.*;
    next.dissolved_first_mol_per_m3 -= extent_mol_per_m3 * stoichiometry.first_mol_per_mol_solid;
    next.dissolved_second_mol_per_m3 -= extent_mol_per_m3 * stoichiometry.second_mol_per_mol_solid;
    next.solid_mol_per_m3 += extent_mol_per_m3;
    try validateState(next);
    try conserved(state.dissolved_first_mol_per_m3 + state.solid_mol_per_m3 * stoichiometry.first_mol_per_mol_solid, next.dissolved_first_mol_per_m3 + next.solid_mol_per_m3 * stoichiometry.first_mol_per_mol_solid);
    try conserved(state.dissolved_second_mol_per_m3 + state.solid_mol_per_m3 * stoichiometry.second_mol_per_mol_solid, next.dissolved_second_mol_per_m3 + next.solid_mol_per_m3 * stoichiometry.second_mol_per_mol_solid);
    state.* = next;
}

/// Legacy calcite inhibition `TPDZ/(1 + aOH/OHKI)`, validated explicitly.
pub fn calciteDissolutionLimit(uninhibited_mol_per_m3_step: f64, hydroxide_activity_mol_per_m3: f64, hydroxide_inhibition_constant_mol_per_m3: f64) !f64 {
    if (!std.math.isFinite(uninhibited_mol_per_m3_step) or uninhibited_mol_per_m3_step < 0 or
        !std.math.isFinite(hydroxide_activity_mol_per_m3) or hydroxide_activity_mol_per_m3 < 0 or
        !std.math.isFinite(hydroxide_inhibition_constant_mol_per_m3) or hydroxide_inhibition_constant_mol_per_m3 <= 0)
        return error.InvalidCalciteInhibition;
    return uninhibited_mol_per_m3_step / (1 + hydroxide_activity_mol_per_m3 / hydroxide_inhibition_constant_mol_per_m3);
}

fn validate(state: State, first_activity: f64, second_activity: f64, stoichiometry: Stoichiometry, parameters: Parameters) !void {
    try validateState(state);
    try validateStoichiometry(stoichiometry);
    if (!std.math.isFinite(first_activity) or first_activity < 0 or !std.math.isFinite(second_activity) or second_activity < 0 or
        !std.math.isFinite(parameters.solubility_product) or parameters.solubility_product <= 0 or
        !std.math.isFinite(parameters.first_activity_coefficient) or parameters.first_activity_coefficient <= 0 or
        !std.math.isFinite(parameters.substrate_limit_fraction) or parameters.substrate_limit_fraction < 0 or parameters.substrate_limit_fraction > 1 or
        !std.math.isFinite(parameters.maximum_precipitation_mol_per_m3_step) or parameters.maximum_precipitation_mol_per_m3_step < 0 or
        !std.math.isFinite(parameters.maximum_dissolution_mol_per_m3_step) or parameters.maximum_dissolution_mol_per_m3_step < 0)
        return error.InvalidMineralPrecipitationParameter;
}

test "zero partner activity produces finite inventory-bounded dissolution" {
    const parameters: Parameters = .{
        .solubility_product = 3.3e-3,
        .first_activity_coefficient = 1,
        .substrate_limit_fraction = 0.2,
        .maximum_precipitation_mol_per_m3_step = 0.0025,
        .maximum_dissolution_mol_per_m3_step = 0.001,
    };
    try std.testing.expectEqual(@as(f64, -0.001), try calculateExtent(.{
        .dissolved_first_mol_per_m3 = 1,
        .dissolved_second_mol_per_m3 = 0,
        .solid_mol_per_m3 = 0.01,
    }, 1, 0, .{ .first_mol_per_mol_solid = 1, .second_mol_per_mol_solid = 1 }, parameters));
    try std.testing.expectEqual(@as(f64, -0.0002), try calculateExtent(.{
        .dissolved_first_mol_per_m3 = 1,
        .dissolved_second_mol_per_m3 = 0,
        .solid_mol_per_m3 = 0.0002,
    }, 1, 0, .{ .first_mol_per_mol_solid = 1, .second_mol_per_mol_solid = 1 }, parameters));
}

fn validateState(state: State) !void {
    inline for (@typeInfo(State).@"struct".fields) |field| {
        const value = @field(state, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteMineralState;
        if (value < 0) return error.NegativeMineralState;
    }
}

fn validateStoichiometry(stoichiometry: Stoichiometry) !void {
    if (!std.math.isFinite(stoichiometry.first_mol_per_mol_solid) or stoichiometry.first_mol_per_mol_solid <= 0 or
        !std.math.isFinite(stoichiometry.second_mol_per_mol_solid) or stoichiometry.second_mol_per_mol_solid <= 0)
        return error.InvalidMineralStoichiometry;
}

fn conserved(before: f64, after: f64) !void {
    if (@abs(before - after) > 1e-12 * @max(1.0, @abs(before), @abs(after))) return error.MineralConservationFailure;
}

test "gibbsite precipitation consumes three hydroxides per aluminum" {
    const stoichiometry = Stoichiometry{ .first_mol_per_mol_solid = 1, .second_mol_per_mol_solid = 3 };
    var state = State{ .dissolved_first_mol_per_m3 = 0.2, .dissolved_second_mol_per_m3 = 0.6, .solid_mol_per_m3 = 0.1 };
    const extent = try calculateExtent(state, 0.2, 0.5, stoichiometry, .{ .solubility_product = 1e-4, .first_activity_coefficient = 0.5, .substrate_limit_fraction = 0.1, .maximum_precipitation_mol_per_m3_step = 0.1, .maximum_dissolution_mol_per_m3_step = 0.1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), extent, 1e-15);
    try state_update(&state, extent, stoichiometry);
    try std.testing.expectApproxEqAbs(@as(f64, 0.18), state.dissolved_first_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.54), state.dissolved_second_mol_per_m3, 1e-15);
}

test "calcite hydroxide inhibition reduces its dissolution ceiling" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.025), try calciteDissolutionLimit(0.1, 3, 1), 1e-15);
}

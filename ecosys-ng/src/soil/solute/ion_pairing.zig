const std = @import("std");

pub const ReactionState = struct {
    free_first_mol_per_m3: f64,
    free_second_mol_per_m3: f64,
    paired_mol_per_m3: f64,
};

pub const Activities = struct {
    free_first_mol_per_m3: f64,
    free_second_mol_per_m3: f64,
    paired_mol_per_m3: f64,
    free_first_activity_coefficient: f64,
};

pub const Parameters = struct {
    dissociation_constant: f64,
    substrate_limit_fraction: f64,
    maximum_association_mol_per_m3_step: f64,
};

/// Reusable kernel for the SOLUTE binary reactions A + B <-> AB. Positive
/// flux associates the free ions; negative flux dissociates the pair.
pub fn calculate(state: ReactionState, activities: Activities, parameters: Parameters) !f64 {
    try validate(state, activities, parameters);
    if (activities.free_second_mol_per_m3 == 0) return bounded(
        -state.paired_mol_per_m3,
        parameters.maximum_association_mol_per_m3_step,
        parameters.substrate_limit_fraction * @min(state.free_first_mol_per_m3, state.free_second_mol_per_m3),
        parameters.substrate_limit_fraction * state.paired_mol_per_m3,
    );
    const equilibrium_first_activity = parameters.dissociation_constant *
        activities.paired_mol_per_m3 / activities.free_second_mol_per_m3;
    const driving_force = (activities.free_first_mol_per_m3 - equilibrium_first_activity) /
        activities.free_first_activity_coefficient;
    return bounded(
        driving_force,
        parameters.maximum_association_mol_per_m3_step,
        parameters.substrate_limit_fraction * @min(state.free_first_mol_per_m3, state.free_second_mol_per_m3),
        parameters.substrate_limit_fraction * state.paired_mol_per_m3,
    );
}

/// Atomically applies A + B <-> AB and rejects nonphysical or non-finite state.
pub fn state_update(state: *ReactionState, association_mol_per_m3: f64) !void {
    try validateState(state.*);
    if (!std.math.isFinite(association_mol_per_m3)) return error.NonFiniteIonPairingFlux;
    var next = state.*;
    next.free_first_mol_per_m3 -= association_mol_per_m3;
    next.free_second_mol_per_m3 -= association_mol_per_m3;
    next.paired_mol_per_m3 += association_mol_per_m3;
    try validateState(next);
    const first_before = state.free_first_mol_per_m3 + state.paired_mol_per_m3;
    const second_before = state.free_second_mol_per_m3 + state.paired_mol_per_m3;
    try conserved(first_before, next.free_first_mol_per_m3 + next.paired_mol_per_m3);
    try conserved(second_before, next.free_second_mol_per_m3 + next.paired_mol_per_m3);
    state.* = next;
}

fn bounded(driving_force: f64, maximum: f64, association_limit: f64, dissociation_limit: f64) f64 {
    return @max(-maximum, -dissociation_limit, @min(maximum, association_limit, driving_force));
}

fn validate(state: ReactionState, activities: Activities, parameters: Parameters) !void {
    try validateState(state);
    inline for (@typeInfo(Activities).@"struct".fields) |field| {
        const value = @field(activities, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidIonPairingActivity;
    }
    if (activities.free_first_activity_coefficient <= 0 or
        !std.math.isFinite(parameters.dissociation_constant) or parameters.dissociation_constant < 0 or
        !std.math.isFinite(parameters.substrate_limit_fraction) or parameters.substrate_limit_fraction < 0 or parameters.substrate_limit_fraction > 1 or
        !std.math.isFinite(parameters.maximum_association_mol_per_m3_step) or parameters.maximum_association_mol_per_m3_step < 0)
        return error.InvalidIonPairingParameter;
}

fn validateState(state: ReactionState) !void {
    inline for (@typeInfo(ReactionState).@"struct".fields) |field| {
        const value = @field(state, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteIonPairingState;
        if (value < 0) return error.NegativeIonPairingState;
    }
}

fn conserved(before: f64, after: f64) !void {
    if (@abs(before - after) > 1e-12 * @max(1.0, @abs(before), @abs(after)))
        return error.IonPairingConservationFailure;
}

test "binary ion association follows equilibrium and substrate bounds" {
    const state = ReactionState{ .free_first_mol_per_m3 = 0.8, .free_second_mol_per_m3 = 0.5, .paired_mol_per_m3 = 0.1 };
    const flux = try calculate(state, .{ .free_first_mol_per_m3 = 0.64, .free_second_mol_per_m3 = 0.4, .paired_mol_per_m3 = 0.08, .free_first_activity_coefficient = 0.8 }, .{ .dissociation_constant = 0.2, .substrate_limit_fraction = 0.1, .maximum_association_mol_per_m3_step = 0.02 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), flux, 1e-15);
}

test "ion-pair state_update conserves both constituents" {
    var state = ReactionState{ .free_first_mol_per_m3 = 0.8, .free_second_mol_per_m3 = 0.5, .paired_mol_per_m3 = 0.1 };
    const first_before = state.free_first_mol_per_m3 + state.paired_mol_per_m3;
    const second_before = state.free_second_mol_per_m3 + state.paired_mol_per_m3;
    try state_update(&state, 0.02);
    try std.testing.expectApproxEqAbs(first_before, state.free_first_mol_per_m3 + state.paired_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(second_before, state.free_second_mol_per_m3 + state.paired_mol_per_m3, 1e-15);
}

test "missing second-ion activity yields bounded dissociation without division by zero" {
    const flux = try calculate(.{ .free_first_mol_per_m3 = 0, .free_second_mol_per_m3 = 0, .paired_mol_per_m3 = 0.1 }, .{ .free_first_mol_per_m3 = 0, .free_second_mol_per_m3 = 0, .paired_mol_per_m3 = 0.1, .free_first_activity_coefficient = 1 }, .{ .dissociation_constant = 1, .substrate_limit_fraction = 0.2, .maximum_association_mol_per_m3_step = 0.1 });
    try std.testing.expectApproxEqAbs(@as(f64, -0.02), flux, 1e-15);
}

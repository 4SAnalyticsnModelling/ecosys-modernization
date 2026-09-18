//! `reaction_try` declarations: acceptance.
//!
//! Split out of `reaction_try.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("reaction_search_span.zig");
const __parent = @import("reaction_solver.zig");
const group_aliases = @import("reaction_try_aliases.zig");

/// Newton globalization uses this smooth merit, while the scaled maximum
/// residual remains the sole nonlinear convergence and divergence metric.
/// A separate finite maximum-residual guard prevents an RMS-descent step from
/// hiding an explosive component behind improvement in the remaining rows.
pub const maximum_scaled_residual_growth_safeguard: f64 = 2.0;
pub const rms_armijo_slope_fraction: f64 = 1.0e-4;

pub fn tryAcceptReactionExtentLineSearch(
    scratch: *chemistry.State,
    current: []const f64,
    transformations: chemistry.CellTransformations,
    initial_fraction: f64,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_residual: []const f64,
    current_maximum_norm: f64,
    accepted_fraction: *f64,
) !bool {
    return tryAcceptReactionExtentLineSearchImpl(
        scratch,
        current,
        transformations,
        initial_fraction,
        candidate_state,
        accepted_state,
        residual_work,
        parameters,
        options,
        current_residual,
        current_maximum_norm,
        accepted_fraction,
        null,
    );
}

/// Scoped globalization for a bounded inexact Newton reaction direction.
/// Unlike the exact-Newton shorthand, this uses the directional derivative
/// of the same scaled RMS merit that is evaluated at every exact trial.
pub fn tryAcceptReactionExtentSlopeAwareLineSearch(
    scratch: *chemistry.State,
    current: []const f64,
    transformations: chemistry.CellTransformations,
    initial_fraction: f64,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_residual: []const f64,
    current_maximum_norm: f64,
    directional_derivative: f64,
    accepted_fraction: *f64,
) !bool {
    return tryAcceptReactionExtentLineSearchImpl(
        scratch,
        current,
        transformations,
        initial_fraction,
        candidate_state,
        accepted_state,
        residual_work,
        parameters,
        options,
        current_residual,
        current_maximum_norm,
        accepted_fraction,
        directional_derivative,
    );
}

fn tryAcceptReactionExtentLineSearchImpl(
    scratch: *chemistry.State,
    current: []const f64,
    transformations: chemistry.CellTransformations,
    initial_fraction: f64,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_residual: []const f64,
    current_maximum_norm: f64,
    accepted_fraction: *f64,
    directional_derivative: ?f64,
) !bool {
    accepted_fraction.* = 0;
    const current_merit = try scaledRmsNorm(current, current_residual, options);
    var fraction = initial_fraction;
    var attempt: u8 = 0;
    while (attempt < 48) : (attempt += 1) {
        _ = group_aliases.transformedVectorAdmissible(
            scratch,
            current,
            transformations,
            parameters,
            fraction,
            candidate_state,
        ) catch {
            fraction *= 0.5;
            continue;
        };
        group_aliases.evaluateGlobalResidualAt(
            scratch,
            candidate_state,
            parameters,
            residual_work,
        ) catch {
            fraction *= 0.5;
            continue;
        };
        const candidate_maximum_norm =
            try group_aliases.scaledNorm(candidate_state, residual_work, options);
        const candidate_merit =
            try scaledRmsNorm(candidate_state, residual_work, options);
        const acceptable = if (directional_derivative) |slope|
            reactionExtentSlopeAwareLineSearchAcceptable(
                current_maximum_norm,
                current_merit,
                candidate_maximum_norm,
                candidate_merit,
                fraction,
                slope,
            )
        else
            reactionExtentLineSearchAcceptable(
                current_maximum_norm,
                current_merit,
                candidate_maximum_norm,
                candidate_merit,
                fraction,
            );
        if (acceptable) {
            @memcpy(accepted_state, candidate_state);
            accepted_fraction.* = fraction;
            return true;
        }
        fraction *= 0.5;
    }
    return false;
}

/// Applies the same Newton globalization policy to conservative reaction
/// extents as to packed-state Newton targets: smooth RMS Armijo owns descent,
/// while the maximum norm is a finite bounded-growth safeguard rather than a
/// second, stricter merit function.
fn reactionExtentLineSearchAcceptable(
    current_maximum_norm: f64,
    current_merit: f64,
    candidate_maximum_norm: f64,
    candidate_merit: f64,
    fraction: f64,
) bool {
    return rmsArmijoDecrease(current_merit, candidate_merit, fraction) and
        maximumNormGrowthSafeguard(
            current_maximum_norm,
            candidate_maximum_norm,
        );
}

fn reactionExtentSlopeAwareLineSearchAcceptable(
    current_maximum_norm: f64,
    current_merit: f64,
    candidate_maximum_norm: f64,
    candidate_merit: f64,
    fraction: f64,
    directional_derivative: f64,
) bool {
    return rmsSlopeAwareArmijoDecrease(
        current_merit,
        candidate_merit,
        fraction,
        directional_derivative,
    ) and maximumNormGrowthSafeguard(
        current_maximum_norm,
        candidate_maximum_norm,
    );
}

pub fn scaledRmsNorm(
    state: []const f64,
    residual: []const f64,
    options: group_aliases.Options,
) !f64 {
    if (state.len == 0 or state.len != residual.len)
        return error.NonFiniteSoluteReactionState;
    var scaled_sum_squares: f64 = 0;
    for (state, residual, 0..) |value, change, packed_component| {
        if (!std.math.isFinite(value) or value < 0 or
            !std.math.isFinite(change))
            return error.NonFiniteSoluteReactionState;
        const scaled_change =
            change / group_aliases.residualScale(value, packed_component, options);
        scaled_sum_squares += scaled_change * scaled_change;
        if (!std.math.isFinite(scaled_sum_squares))
            return error.NonFiniteSoluteReactionState;
    }
    return @sqrt(scaled_sum_squares / @as(f64, @floatFromInt(state.len)));
}

pub fn meaningfulRmsMeritDecrease(
    current_merit: f64,
    candidate_merit: f64,
) bool {
    if (!std.math.isFinite(current_merit) or current_merit < 0 or
        !std.math.isFinite(candidate_merit) or candidate_merit < 0)
    {
        return false;
    }
    const representation_floor = 64.0 * std.math.floatEps(f64) *
        @max(1.0, @abs(current_merit));
    return current_merit - candidate_merit > representation_floor;
}

/// Armijo sufficient decrease for an inexact Newton direction. The fraction
/// is the actual backtracking multiplier applied to the conservative step.
pub fn rmsArmijoDecrease(
    current_merit: f64,
    candidate_merit: f64,
    fraction: f64,
) bool {
    if (!meaningfulRmsMeritDecrease(current_merit, candidate_merit) or
        !std.math.isFinite(fraction) or fraction <= 0 or fraction > 1)
    {
        return false;
    }
    return candidate_merit <= current_merit *
        (1.0 - rms_armijo_slope_fraction * fraction);
}

/// Standard Armijo sufficient decrease for a bounded/inexact Newton
/// direction whose actual scaled-RMS directional derivative is available.
pub fn rmsSlopeAwareArmijoDecrease(
    current_merit: f64,
    candidate_merit: f64,
    fraction: f64,
    directional_derivative: f64,
) bool {
    if (!meaningfulRmsMeritDecrease(current_merit, candidate_merit) or
        !std.math.isFinite(fraction) or fraction <= 0 or fraction > 1 or
        !std.math.isFinite(directional_derivative) or
        directional_derivative >= 0)
    {
        return false;
    }
    const required_merit = current_merit +
        rms_armijo_slope_fraction * fraction * directional_derivative;
    return std.math.isFinite(required_merit) and
        candidate_merit <= required_merit;
}

pub fn maximumNormGrowthSafeguard(
    current_maximum_norm: f64,
    candidate_maximum_norm: f64,
) bool {
    return std.math.isFinite(current_maximum_norm) and
        current_maximum_norm >= 0 and
        std.math.isFinite(candidate_maximum_norm) and
        candidate_maximum_norm >= 0 and
        candidate_maximum_norm <= maximum_scaled_residual_growth_safeguard *
            current_maximum_norm;
}

pub fn newtonCandidateAcceptable(
    current_maximum_norm: f64,
    current_merit: f64,
    candidate_maximum_norm: f64,
    candidate_merit: f64,
) bool {
    return meaningfulRmsMeritDecrease(current_merit, candidate_merit) and
        maximumNormGrowthSafeguard(
            current_maximum_norm,
            candidate_maximum_norm,
        );
}

/// Exact RMS-Armijo backtracking between two conservative packed states.
/// Unlike Anderson acceptance, this permits a bounded L-infinity ridge
/// crossing; it never changes the maximum-norm convergence criterion.
pub fn tryAcceptNewtonTargetLineSearch(
    scratch: *chemistry.State,
    current: []const f64,
    current_residual: []const f64,
    target: []const f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    initial_fraction: f64,
    current_maximum_norm: f64,
) !bool {
    const current_merit = try scaledRmsNorm(
        current,
        current_residual,
        options,
    );
    var fraction = initial_fraction;
    var attempt: u8 = 0;
    while (attempt < 48) : (attempt += 1) {
        const candidate_maximum_norm =
            group_aliases.evaluateCandidateResidualAtFraction(
                scratch,
                current,
                target,
                accepted_state,
                residual_work,
                parameters,
                options,
                fraction,
            ) catch {
                fraction *= 0.5;
                continue;
            };
        const candidate_merit = try scaledRmsNorm(
            accepted_state,
            residual_work,
            options,
        );
        if (rmsArmijoDecrease(current_merit, candidate_merit, fraction) and
            maximumNormGrowthSafeguard(
                current_maximum_norm,
                candidate_maximum_norm,
            ))
        {
            return true;
        }
        fraction *= 0.5;
    }
    return false;
}

pub fn tryAcceptExactReactionExtentCandidate(
    scratch: *chemistry.State,
    candidate_state: []const f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
) !bool {
    try group_aliases.evaluateGlobalResidualAt(
        scratch,
        candidate_state,
        parameters,
        residual_work,
    );
    const candidate_norm =
        try group_aliases.scaledNorm(candidate_state, residual_work, options);
    if (candidate_norm >= current_norm) return false;
    @memcpy(accepted_state, candidate_state);
    return true;
}

test "reaction extent line search permits bounded maximum-norm ridge crossing" {
    const current_maximum = 2.0;
    const current_merit = @sqrt((4.0 + 2.25) / 2.0);
    const candidate_maximum = 2.1;
    const candidate_merit = @sqrt((4.41 + 0.0) / 2.0);

    try std.testing.expect(candidate_maximum > current_maximum);
    try std.testing.expect(reactionExtentLineSearchAcceptable(
        current_maximum,
        current_merit,
        candidate_maximum,
        candidate_merit,
        1.0,
    ));
    try std.testing.expect(!reactionExtentLineSearchAcceptable(
        current_maximum,
        current_merit,
        2.000001 * current_maximum,
        candidate_merit,
        1.0,
    ));
}

test "slope-aware Armijo accepts a shallow inexact descent" {
    const current_merit = 100.0;
    const candidate_merit = 99.99999;
    const directional_derivative = -0.02;
    try std.testing.expect(!rmsArmijoDecrease(
        current_merit,
        candidate_merit,
        1,
    ));
    try std.testing.expect(reactionExtentSlopeAwareLineSearchAcceptable(
        10,
        current_merit,
        19,
        candidate_merit,
        1,
        directional_derivative,
    ));
}

test "slope-aware Armijo rejects non-descent directions" {
    for ([_]f64{ 0, 1, std.math.nan(f64) }) |directional_derivative|
        try std.testing.expect(!rmsSlopeAwareArmijoDecrease(
            10,
            9,
            0.5,
            directional_derivative,
        ));
}

test "slope-aware Armijo equals exact-Newton shorthand for slope minus merit" {
    const current_merit = 20.0;
    for ([_]f64{ 1, 0.5, 0.125 }) |fraction| {
        for ([_]f64{ 19.0, 19.999, 20.0 }) |candidate_merit|
            try std.testing.expectEqual(
                rmsArmijoDecrease(
                    current_merit,
                    candidate_merit,
                    fraction,
                ),
                rmsSlopeAwareArmijoDecrease(
                    current_merit,
                    candidate_merit,
                    fraction,
                    -current_merit,
                ),
            );
    }
}

pub fn tryProjectWaterPair(
    scratch: *chemistry.State,
    vector: []f64,
    parameters: chemistry.ReactionParameters,
) bool {
    scratch.unpackCell(0, vector) catch return false;
    const coefficients =
        scratch.activityCoefficients(0, parameters.fractions) catch
            return false;
    const water = water_equilibrium.projectProvisional(
        scratch.aqueous[0].hydrogen,
        scratch.aqueous[0].hydroxide,
        coefficients.monovalent_activity_coefficient,
        parameters.water_activity_product_mol2_per_m6,
    ) catch return false;
    scratch.aqueous[0].hydrogen =
        water.hydrogen_concentration_mol_per_m3;
    scratch.aqueous[0].hydroxide =
        water.hydroxide_concentration_mol_per_m3;
    scratch.packCell(0, vector) catch return false;
    return true;
}

/// Depth-one Anderson acceleration of the complete conservative fixed-point
/// map. Both mapped endpoints share the same elemental and site totals, so
/// their affine secant candidate retains those totals. Backtracking preserves
/// nonnegative inventories; H+/OH- are then projected onto Kw.
pub fn tryAcceptAndersonCandidate(
    scratch: *chemistry.State,
    current: []const f64,
    target: []const f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
) !bool {
    var fraction = group_aliases.phosphateTrustRegionFraction(
        current,
        target,
        options,
        parameters.phosphate_kinetics.substrate_limit_fraction,
    );
    var attempt: u8 = 0;
    while (attempt < 32) : (attempt += 1) {
        const candidate_norm = group_aliases.evaluateCandidateResidualAtFraction(
            scratch,
            current,
            target,
            accepted_state,
            residual_work,
            parameters,
            options,
            fraction,
        ) catch {
            fraction *= 0.5;
            continue;
        };
        if (candidate_norm < current_norm) return true;
        fraction *= 0.5;
    }
    return false;
}

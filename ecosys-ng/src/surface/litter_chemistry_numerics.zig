//! `litter_chemistry` declarations: numerics.
//!
//! Split out of `litter_chemistry.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ledger = @import("litter_reaction_transformations.zig");
const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const numerics = @import("../core/numerics.zig");
const group_types = @import("litter_chemistry_types.zig");

pub fn meaningfullyImproves(current_norm: f64, candidate_norm: f64) bool {
    return candidate_norm <= 1 or
        candidate_norm <= current_norm * (1 - 1e-6);
}

pub fn solveDampedLeastSquares(
    jacobian: []const f64,
    right_hand_side: []const f64,
    solution: []f64,
    normal_matrix: []f64,
    normal_right_hand_side: []f64,
    dimension: usize,
    options: group_types.Options,
) bool {
    var maximum_diagonal: f64 = 0;
    for (0..dimension) |column| {
        var projected_rhs: f64 = 0;
        for (0..dimension) |row|
            projected_rhs += jacobian[row * dimension + column] *
                right_hand_side[row];
        normal_right_hand_side[column] = projected_rhs;
        for (0..dimension) |other_column| {
            var product: f64 = 0;
            for (0..dimension) |row|
                product += jacobian[row * dimension + column] *
                    jacobian[row * dimension + other_column];
            normal_matrix[column * dimension + other_column] = product;
        }
        maximum_diagonal = @max(
            maximum_diagonal,
            normal_matrix[column * dimension + column],
        );
    }
    if (!std.math.isFinite(maximum_diagonal) or maximum_diagonal <= 0)
        return false;

    // Marquardt diagonal scaling keeps weak but physically meaningful
    // coordinates from being erased by a single very stiff activity
    // derivative. A scalar `lambda * max(diagonal)` previously collapsed
    // the aluminum-phosphate step by many orders of magnitude.
    var damping_fraction = 128 * std.math.floatEps(f64);
    var attempt: u16 = 0;
    while (attempt < group_types.probeCap(options, 10)) : (attempt += 1) {
        group_types.recordProbe(options);
        for (0..dimension) |row| {
            for (0..dimension) |column| {
                var product: f64 = 0;
                for (0..dimension) |source_row|
                    product += jacobian[source_row * dimension + row] *
                        jacobian[source_row * dimension + column];
                normal_matrix[row * dimension + column] = product;
            }
            normal_matrix[row * dimension + row] +=
                damping_fraction *
                @max(normal_matrix[row * dimension + row], 1e-30);
            var projected_rhs: f64 = 0;
            for (0..dimension) |source_row|
                projected_rhs += jacobian[source_row * dimension + row] *
                    right_hand_side[source_row];
            normal_right_hand_side[row] = projected_rhs;
        }
        @memcpy(solution, normal_right_hand_side);
        if (numerics.solveDenseLinearSystem(
            normal_matrix,
            solution,
            dimension,
        )) return true;
        damping_fraction *= 100;
    }
    return false;
}

pub fn residualProbeIsInformative(
    base_residual: []const f64,
    probe_residual: []const f64,
) bool {
    for (base_residual, probe_residual) |base, probe| {
        const threshold = 128 * std.math.floatEps(f64) *
            @max(1.0, @abs(base), @abs(probe));
        if (@abs(probe - base) > threshold) return true;
    }
    return false;
}

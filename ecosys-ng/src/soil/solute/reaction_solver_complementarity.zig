//! `reaction_solver` declarations: complementarity.
//!
//! Split out of `reaction_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const aqueous_network = @import("aqueous_network.zig");
const phosphate_network = @import("phosphate_network.zig");
const cation_exchange = @import("cation_exchange.zig");
const geochemistry = @import("geochemistry_network.zig");
const aqueous_rates = @import("aqueous_reaction_rates.zig");
const phosphate_rates = @import("phosphate_reaction_rates.zig");
const geochemistry_rates = @import("geochemistry_reaction_rates.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("reaction_search_span.zig");
const group_candidates = @import("reaction_solver_candidates.zig");
const group_evaluate = @import("reaction_solver_evaluate.zig");
const group_numerics = @import("reaction_solver_numerics.zig");
const group_reaction_span = @import("reaction_solver_reaction_span.zig");
const group_solve = @import("reaction_solver_solve.zig");
const group_types = @import("reaction_solver_types.zig");

pub fn complementarityColumnDerivative(
    branch: i8,
    negative_derivative: f64,
    positive_derivative: f64,
) f64 {
    return switch (branch) {
        -1 => negative_derivative,
        0 => 0.5 *
            (negative_derivative + positive_derivative),
        1 => positive_derivative,
        else => unreachable,
    };
}

pub fn refineComplementarityDirectionalJacobian(
    workspace: *group_types.Workspace,
    inputs: ComplementaritySearchInputs,
    transformations: chemistry.CellTransformations,
    negative_jacobian: []f64,
    positive_jacobian: []f64,
    selected_jacobian: []f64,
    probe_state: []f64,
    probe_residual: []f64,
) bool {
    var solution_norm_squared: f64 = 0;
    for (workspace.reaction_span_solution[0..inputs.column_count]) |extent|
        solution_norm_squared += extent * extent;
    if (!std.math.isFinite(solution_norm_squared) or
        solution_norm_squared <= std.math.floatEps(f64))
    {
        return false;
    }
    const directional_fraction =
        std.math.cbrt(std.math.floatEps(f64));
    _ = group_numerics.transformedVectorAdmissible(
        inputs.scratch,
        inputs.current,
        transformations,
        inputs.parameters,
        directional_fraction,
        probe_state,
    ) catch return false;
    group_evaluate.evaluateGlobalResidualAt(
        inputs.scratch,
        probe_state,
        inputs.parameters,
        probe_residual,
    ) catch return false;

    var maximum_correction: f64 = 0;
    for (0..inputs.current.len) |row| {
        const scale = group_numerics.residualScale(
            inputs.current[row],
            row,
            inputs.options,
        );
        const weight = group_reaction_span.reactionSpanRowWeight(
            inputs.global_residual[row] / scale,
            inputs.current_norm,
        );
        const actual_directional_derivative =
            group_numerics.scaledResidualDifference(inputs.current[row], inputs.global_residual[row], probe_state[row], probe_residual[row], row, inputs.options) / directional_fraction * weight;
        var predicted_directional_derivative: f64 = 0;
        for (
            workspace.reaction_span_solution[0..inputs.column_count],
            0..,
        ) |extent, column| {
            predicted_directional_derivative +=
                selected_jacobian[
                    row * inputs.column_count + column
                ] * extent;
        }
        const difference =
            actual_directional_derivative -
            predicted_directional_derivative;
        if (!std.math.isFinite(difference)) return false;
        maximum_correction =
            @max(maximum_correction, @abs(difference));
        for (
            workspace.reaction_span_solution[0..inputs.column_count],
            0..,
        ) |extent, column| {
            if (extent == 0) continue;
            const correction =
                difference * extent / solution_norm_squared;
            const index = row * inputs.column_count + column;
            selected_jacobian[index] += correction;
            switch (workspace.reaction_span_branch_states[column]) {
                -1 => negative_jacobian[index] += correction,
                1 => positive_jacobian[index] += correction,
                0 => {},
                else => unreachable,
            }
        }
    }
    return maximum_correction >
        64 * std.math.floatEps(f64);
}

pub const ComplementaritySearchInputs = struct {
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    probe_state: []f64,
    probe_residual: []f64,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    options: group_types.Options,
    current_norm: f64,
    monovalent_activity_coefficient: f64,
    column_count: usize,
};

pub fn searchReactionSpanComplementarity(
    trace: *group_types.SolverTrace,
    workspace: *group_types.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    current_transformations: chemistry.CellTransformations,
    probe_state: []f64,
    probe_residual: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_types.Options,
    current_norm: f64,
    monovalent_activity_coefficient: f64,
    column_count: usize,
) !void {
    trace.full_network_complementarity_search_attempted = true;
    var ambiguous_count: usize = 0;
    for (
        workspace.reaction_span_solution[0..column_count],
        0..,
    ) |solution, column| {
        if (!group_reaction_span.reactionSpanExtentIsSignificant(
            workspace,
            column,
            solution,
        )) continue;
        const reaction =
            workspace.reaction_span_active_reactions[column];
        const rate = workspace.reaction_span_rates[reaction];
        if ((solution < 0) == (rate < 0)) continue;
        trace.full_network_complementarity_ambiguous_columns[
            ambiguous_count
        ] = column;
        ambiguous_count += 1;
    }
    trace.full_network_complementarity_ambiguous_count =
        ambiguous_count;
    if (ambiguous_count == 0 or ambiguous_count > 16) return;

    const matrix_count = current.len * column_count;
    const selected_jacobian = try trace.allocator.dupe(
        f64,
        workspace.reaction_span_jacobian[0..matrix_count],
    );
    defer trace.allocator.free(selected_jacobian);
    const opposite_jacobian = try trace.allocator.dupe(
        f64,
        selected_jacobian,
    );
    defer trace.allocator.free(opposite_jacobian);
    const original_solution = try trace.allocator.dupe(
        f64,
        workspace.reaction_span_solution[0..column_count],
    );
    defer trace.allocator.free(original_solution);
    const original_active_bounds = try trace.allocator.dupe(
        i8,
        workspace.reaction_span_active_bounds[0..column_count],
    );
    defer trace.allocator.free(original_active_bounds);
    const original_last_rank = workspace.reaction_span_last_rank;
    const original_used_truncated_qr =
        workspace.reaction_span_used_truncated_qr;
    // This search is diagnostic only. Every bounded solve below reuses the
    // production workspace, so restore all persistent primary-solve state on
    // both success and error paths. Trace collection must never select a
    // different scientific candidate.
    defer {
        @memcpy(
            workspace.reaction_span_jacobian[0..matrix_count],
            selected_jacobian,
        );
        @memcpy(
            workspace.reaction_span_solution[0..column_count],
            original_solution,
        );
        @memcpy(
            workspace.reaction_span_active_bounds[0..column_count],
            original_active_bounds,
        );
        workspace.reaction_span_last_rank = original_last_rank;
        workspace.reaction_span_used_truncated_qr =
            original_used_truncated_qr;
    }
    const inputs = ComplementaritySearchInputs{
        .scratch = scratch,
        .current = current,
        .global_residual = global_residual,
        .probe_state = probe_state,
        .probe_residual = probe_residual,
        .current_transformations = current_transformations,
        .parameters = parameters,
        .options = options,
        .current_norm = current_norm,
        .monovalent_activity_coefficient = monovalent_activity_coefficient,
        .column_count = column_count,
    };
    for (
        trace.full_network_complementarity_ambiguous_columns[0..ambiguous_count],
    ) |column| {
        const reaction =
            workspace.reaction_span_active_reactions[column];
        const selected_rate =
            workspace.reaction_span_rates[reaction];
        try group_reaction_span.evaluateReactionSpanDerivativeColumn(
            inputs,
            workspace,
            column,
            if (selected_rate < 0) 1 else -1,
            opposite_jacobian,
        );
    }

    const combination_count_u64 =
        @as(u64, 1) << @intCast(ambiguous_count);
    const combination_count: usize =
        @intCast(combination_count_u64);
    trace.full_network_complementarity_combination_count =
        combination_count;
    const pattern_mismatch_counts = try trace.allocator.alloc(
        usize,
        combination_count,
    );
    defer trace.allocator.free(pattern_mismatch_counts);
    @memset(pattern_mismatch_counts, std.math.maxInt(usize));
    const pattern_mismatch_columns = try trace.allocator.alloc(
        usize,
        combination_count,
    );
    defer trace.allocator.free(pattern_mismatch_columns);
    const pattern_mismatch_solutions = try trace.allocator.alloc(
        f64,
        combination_count,
    );
    defer trace.allocator.free(pattern_mismatch_solutions);
    const mismatch_work = try trace.allocator.alloc(
        usize,
        column_count,
    );
    defer trace.allocator.free(mismatch_work);
    var mask: u64 = 0;
    while (mask < combination_count_u64) : (mask += 1) {
        @memcpy(
            workspace.reaction_span_jacobian[0..matrix_count],
            selected_jacobian,
        );
        for (
            trace.full_network_complementarity_ambiguous_columns[0..ambiguous_count],
            0..,
        ) |column, bit| {
            if (mask & (@as(u64, 1) << @intCast(bit)) == 0)
                continue;
            for (0..current.len) |row|
                workspace.reaction_span_jacobian[
                    row * column_count + column
                ] = opposite_jacobian[
                    row * column_count + column
                ];
        }
        if (!group_reaction_span.solveBoundedReactionSpan(
            workspace,
            current.len,
            column_count,
        )) continue;
        const mismatch_count = group_reaction_span.reactionSpanDerivativeSideMismatchCount(
            workspace,
            column_count,
            trace.full_network_complementarity_ambiguous_columns[0..ambiguous_count],
            mask,
            mismatch_work,
        );
        const pattern_index: usize = @intCast(mask);
        pattern_mismatch_counts[pattern_index] =
            mismatch_count;
        if (mismatch_count == 1) {
            const mismatch_column = mismatch_work[0];
            pattern_mismatch_columns[pattern_index] =
                mismatch_column;
            pattern_mismatch_solutions[pattern_index] =
                workspace.reaction_span_solution[mismatch_column];
        }
        if (mismatch_count <
            trace.full_network_complementarity_minimum_mismatch_count)
        {
            trace.full_network_complementarity_minimum_mismatch_count =
                mismatch_count;
            trace.full_network_complementarity_minimum_mismatch_mask =
                mask;
            @memcpy(
                trace.full_network_complementarity_mismatch_columns[0..mismatch_count],
                mismatch_work[0..mismatch_count],
            );
        }
        if (mismatch_count != 0) continue;
        trace.full_network_complementarity_consistent_count += 1;
        const merit =
            try evaluateComplementarityCandidate(inputs, workspace) orelse
            continue;
        trace.full_network_complementarity_exact_descent_count += 1;
        if (merit.exact <
            trace.full_network_complementarity_best_exact_merit)
        {
            trace.full_network_complementarity_best_mask = mask;
            trace.full_network_complementarity_best_predicted_merit =
                merit.predicted;
            trace.full_network_complementarity_best_exact_merit =
                merit.exact;
        }
    }
    try searchComplementarityKinkBlends(
        trace,
        workspace,
        inputs,
        selected_jacobian,
        opposite_jacobian,
        pattern_mismatch_counts,
        pattern_mismatch_columns,
        pattern_mismatch_solutions,
    );
}

const ComplementarityMerit = struct {
    predicted: f64,
    exact: f64,
};

fn evaluateComplementarityCandidate(
    inputs: ComplementaritySearchInputs,
    workspace: *group_types.Workspace,
) !?ComplementarityMerit {
    var transformations =
        reaction_span.zeroTransformations(inputs.parameters);
    var has_nonzero_extent = false;
    for (
        workspace.reaction_span_solution[0..inputs.column_count],
        0..,
    ) |normalized_extent, column| {
        if (!std.math.isFinite(normalized_extent))
            return error.NonFiniteSoluteReactionExtent;
        if (normalized_extent == 0) continue;
        try reaction_span.addReactionExtent(
            &transformations,
            workspace.reaction_span_active_reactions[column],
            normalized_extent *
                workspace.reaction_span_extent_scales[column],
            inputs.current_transformations,
            inputs.parameters,
        );
        has_nonzero_extent = true;
    }
    if (!has_nonzero_extent) return null;
    const inventory_fraction = group_numerics.transformedVectorAdmissible(
        inputs.scratch,
        inputs.current,
        transformations,
        inputs.parameters,
        1,
        inputs.probe_state,
    ) catch return null;
    const predicted_norm = group_reaction_span.reactionSpanPredictedNorm(
        workspace,
        inputs.current,
        inputs.global_residual,
        inputs.options,
        inputs.current_norm,
        inputs.column_count,
        inventory_fraction,
    );
    if (!std.math.isFinite(predicted_norm)) return null;
    if (!try group_candidates.tryAcceptAndersonCandidate(
        inputs.scratch,
        inputs.current,
        inputs.probe_state,
        workspace.complementarity_candidate_state,
        inputs.probe_residual,
        inputs.parameters,
        inputs.options,
        inputs.current_norm,
    )) return null;
    const exact_norm = try group_numerics.scaledNorm(
        workspace.complementarity_candidate_state,
        inputs.probe_residual,
        inputs.options,
    );
    if (inputs.current_norm - exact_norm <
        1.0e-6 * @max(1.0, inputs.current_norm))
    {
        return null;
    }
    return .{
        .predicted = predicted_norm,
        .exact = exact_norm,
    };
}

fn searchComplementarityKinkBlends(
    trace: *group_types.SolverTrace,
    workspace: *group_types.Workspace,
    inputs: ComplementaritySearchInputs,
    selected_jacobian: []const f64,
    opposite_jacobian: []const f64,
    pattern_mismatch_counts: []const usize,
    pattern_mismatch_columns: []const usize,
    pattern_mismatch_solutions: []const f64,
) !void {
    if (trace.full_network_complementarity_minimum_mismatch_count != 1)
        return;
    const ambiguous_columns =
        trace.full_network_complementarity_ambiguous_columns[0..trace.full_network_complementarity_ambiguous_count];
    var best_base_mask: ?u64 = null;
    var best_blend_column: usize = 0;
    var best_selected_solution: f64 = 0;
    var best_opposite_solution: f64 = 0;
    var best_endpoint_score = std.math.inf(f64);
    for (pattern_mismatch_counts, 0..) |base_count, base_index| {
        if (base_count != 1) continue;
        const base_mask: u64 = @intCast(base_index);
        for (ambiguous_columns, 0..) |blend_column, bit| {
            const bit_mask = @as(u64, 1) << @intCast(bit);
            if (base_mask & bit_mask != 0) continue;
            const other_index: usize =
                @intCast(base_mask | bit_mask);
            if (pattern_mismatch_counts[other_index] != 1 or
                pattern_mismatch_columns[base_index] != blend_column or
                pattern_mismatch_columns[other_index] != blend_column)
            {
                continue;
            }
            const endpoint_selected_solution =
                pattern_mismatch_solutions[base_index];
            const endpoint_opposite_solution =
                pattern_mismatch_solutions[other_index];
            if ((endpoint_selected_solution < 0) ==
                (endpoint_opposite_solution < 0))
            {
                continue;
            }
            const endpoint_score = @max(
                @abs(endpoint_selected_solution),
                @abs(endpoint_opposite_solution),
            );
            if (endpoint_score >= best_endpoint_score) continue;
            best_endpoint_score = endpoint_score;
            best_base_mask = base_mask;
            best_blend_column = blend_column;
            best_selected_solution = endpoint_selected_solution;
            best_opposite_solution = endpoint_opposite_solution;
        }
    }
    const base_mask = best_base_mask orelse return;
    trace.full_network_complementarity_blend_attempted = true;
    trace.full_network_complementarity_blend_column =
        best_blend_column;

    var selected_fraction: f64 = 0;
    var opposite_fraction: f64 = 1;
    var selected_solution = best_selected_solution;
    var opposite_solution = best_opposite_solution;
    var blend_fraction: f64 = 0.5;
    var blend_solution: f64 = std.math.nan(f64);
    var iteration: u8 = 0;
    while (iteration < 80) : (iteration += 1) {
        blend_fraction = if (opposite_solution != selected_solution)
            selected_fraction -
                selected_solution *
                    (opposite_fraction - selected_fraction) /
                    (opposite_solution - selected_solution)
        else
            selected_fraction +
                0.5 * (opposite_fraction - selected_fraction);
        if (!std.math.isFinite(blend_fraction) or
            blend_fraction <= selected_fraction or
            blend_fraction >= opposite_fraction)
        {
            blend_fraction = selected_fraction +
                0.5 * (opposite_fraction - selected_fraction);
        }
        blend_solution = solveComplementarityBlend(
            workspace,
            inputs,
            selected_jacobian,
            opposite_jacobian,
            ambiguous_columns,
            base_mask,
            best_blend_column,
            blend_fraction,
        ) orelse return;
        if (!group_reaction_span.reactionSpanExtentIsSignificant(
            workspace,
            best_blend_column,
            blend_solution,
        )) break;
        if ((blend_solution < 0) ==
            (selected_solution < 0))
        {
            selected_fraction = blend_fraction;
            selected_solution = blend_solution;
        } else {
            opposite_fraction = blend_fraction;
            opposite_solution = blend_solution;
        }
    }
    trace.full_network_complementarity_blend_fraction =
        blend_fraction;
    trace.full_network_complementarity_blend_solution =
        blend_solution;
    if (group_reaction_span.reactionSpanExtentIsSignificant(
        workspace,
        best_blend_column,
        blend_solution,
    )) return;
    if (group_reaction_span.reactionSpanDerivativeSideMismatchCount(
        workspace,
        inputs.column_count,
        ambiguous_columns,
        base_mask,
        null,
    ) != 0) return;
    const merit =
        try evaluateComplementarityCandidate(inputs, workspace) orelse
        return;
    trace.full_network_complementarity_blend_predicted_merit =
        merit.predicted;
    trace.full_network_complementarity_blend_exact_merit =
        merit.exact;
}
pub const tryFullNetworkComplementarityCandidate = group_candidates.__try.tryFullNetworkComplementarityCandidate;
pub const tryRetainedComplementarityCandidate = group_candidates.__try.tryRetainedComplementarityCandidate;
pub const solveComplementarityBlend = group_solve.__solve.solveComplementarityBlend;

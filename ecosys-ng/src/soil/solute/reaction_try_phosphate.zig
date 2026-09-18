//! `reaction_try` declarations: phosphate.
//!
//! Split out of `reaction_try.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("reaction_search_span.zig");
const __parent = @import("reaction_solver.zig");
const group_acceptance = @import("reaction_try_acceptance.zig");
const group_aliases = @import("reaction_try_aliases.zig");
const diagnostic_control = @import("reaction_diagnostic_control.zig");

pub fn tryPhosphateExtentCandidate(
    workspace: *group_aliases.Workspace,
    scratch: *chemistry.State,
    current: []const f64,
    global_residual: []const f64,
    candidate_state: []f64,
    accepted_state: []f64,
    residual_work: []f64,
    parameters: chemistry.ReactionParameters,
    options: group_aliases.Options,
    current_norm: f64,
) !bool {
    diagnostic_control.recordStrategyCall(.phosphate_extent);
    var diagnostic_strategy_scope = diagnostic_control.enterStrategy(.phosphate_extent);
    defer diagnostic_strategy_scope.deinit();
    const limiting_index = group_aliases.largestScaledResidualIndex(
        current,
        global_residual,
        options,
    );
    if (!group_aliases.phosphateExtentControlsPackedIndex(limiting_index)) return false;
    if (!group_aliases.phosphateZoneExtentControlsPackedIndex(limiting_index) and
        group_aliases.largestPhosphateZoneScaledResidual(
            current,
            global_residual,
            options,
        ) <= 1)
    {
        return false;
    }

    const branch_residual = workspace.phosphate_extent_residual;
    try group_aliases.evaluatePhosphateExtentResiduals(
        scratch,
        current,
        parameters,
        branch_residual,
    );
    const jacobian = workspace.phosphate_extent_jacobian;
    @memset(jacobian, 0);
    for (global_residual, current, 0..) |value, state_value, row| {
        const scale = group_aliases.residualScale(state_value, row, options);
        const normalized_residual = value / scale;
        const active_weight = @max(
            @sqrt(std.math.floatEps(f64)),
            @abs(normalized_residual) / current_norm,
        );
        workspace.phosphate_extent_rhs[row] =
            -normalized_residual * active_weight;
    }

    for (0..group_aliases.coupled_extent_reaction_count) |column| {
        const reaction: group_aliases.CoupledExtentReaction = @enumFromInt(column);
        if (!group_aliases.coupledExtentReactionEnabled(reaction, limiting_index)) continue;
        var direction: f64 = if (branch_residual[column] < 0) -1 else 1;
        var available = group_aliases.maximumPhosphateExtent(
            current,
            reaction,
            direction,
            parameters,
        );
        if (available <= 0) {
            direction = -direction;
            available = group_aliases.maximumPhosphateExtent(
                current,
                reaction,
                direction,
                parameters,
            );
        }
        if (available <= 0) continue;
        const characteristic = group_aliases.phosphateExtentCharacteristic(
            current,
            reaction,
            parameters,
        );
        const nominal_probe =
            @sqrt(std.math.floatEps(f64)) * @max(1.0, characteristic);
        const probe_magnitude = @min(nominal_probe, 0.125 * available);
        if (probe_magnitude <=
            64 * std.math.floatEps(f64) * @max(1.0, characteristic))
        {
            continue;
        }
        @memcpy(workspace.probe_state, current);
        const signed_probe = direction * probe_magnitude;
        if (!group_aliases.applyPhosphateExtent(
            workspace.probe_state,
            reaction,
            signed_probe,
            parameters,
        )) continue;
        if (!group_acceptance.tryProjectWaterPair(
            scratch,
            workspace.probe_state,
            parameters,
        )) continue;
        group_aliases.evaluateGlobalResidualAt(
            scratch,
            workspace.probe_state,
            parameters,
            residual_work,
        ) catch continue;
        for (0..current.len) |row| {
            const scale = group_aliases.residualScale(current[row], row, options);
            const active_weight = @max(
                @sqrt(std.math.floatEps(f64)),
                @abs(global_residual[row] / scale) / current_norm,
            );
            jacobian[row * group_aliases.coupled_extent_reaction_count + column] =
                @import("reaction_solver_numerics.zig").scaledResidualDifference(current[row], global_residual[row], workspace.probe_state[row], residual_work[row], row, options) / signed_probe * active_weight;
        }
    }

    if (group_aliases.solveBoundedPhosphateExtents(
        workspace,
        current,
        parameters,
        options,
        limiting_index,
    )) {
        @memcpy(candidate_state, current);
        var has_nonzero_extent = false;
        for (workspace.phosphate_extent_solution, 0..) |extent, index| {
            if (!std.math.isFinite(extent) or extent == 0) continue;
            const reaction: group_aliases.CoupledExtentReaction = @enumFromInt(index);
            if (!group_aliases.applyPhosphateExtent(
                candidate_state,
                reaction,
                extent,
                parameters,
            )) break;
            has_nonzero_extent = true;
        }
        const initial_fraction = group_aliases.phosphateTrustRegionFraction(
            current,
            candidate_state,
            options,
            parameters.phosphate_kinetics.substrate_limit_fraction,
        );
        if (has_nonzero_extent and
            try group_acceptance.tryAcceptNewtonTargetLineSearch(
                scratch,
                current,
                global_residual,
                candidate_state,
                accepted_state,
                residual_work,
                parameters,
                options,
                initial_fraction,
                current_norm,
            ))
        {
            return true;
        }
    }
    return false;
}

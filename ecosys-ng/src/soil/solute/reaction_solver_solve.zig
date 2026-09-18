//! `reaction_solver` declarations: solve.
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
const group_diagnostics = @import("reaction_solver_diagnostics.zig");
const group_types = @import("reaction_solver_types.zig");

pub fn selectTraceCandidate(
    entry: ?*group_diagnostics.IterationDiagnostic,
    candidate: group_types.CandidateKind,
    maximum_scaled_residual: f64,
) void {
    if (entry) |diagnostic| {
        diagnostic.selected_candidate = candidate;
        diagnostic.selected_maximum_scaled_residual =
            maximum_scaled_residual;
    }
}

/// Retains the strictly best exactly priced candidate. Strict comparison is
/// intentional: equal-merit candidates keep deterministic source order.
pub fn retainBetterCandidate(
    best_state: []f64,
    best_residual: []f64,
    best_norm: *f64,
    best_kind: *group_types.CandidateKind,
    best_is_picard: *bool,
    candidate_state: []const f64,
    candidate_residual: []const f64,
    candidate_norm: f64,
    candidate_kind: group_types.CandidateKind,
    candidate_is_picard: bool,
) bool {
    if (best_state.len != candidate_state.len or
        best_residual.len != candidate_residual.len or
        best_state.len != best_residual.len or
        !std.math.isFinite(candidate_norm) or
        candidate_norm >= best_norm.*)
    {
        return false;
    }
    @memcpy(best_state, candidate_state);
    @memcpy(best_residual, candidate_residual);
    best_norm.* = candidate_norm;
    best_kind.* = candidate_kind;
    best_is_picard.* = candidate_is_picard;
    return true;
}

pub fn candidateCountsAsPicard(kind: group_types.CandidateKind) bool {
    return switch (kind) {
        .anderson_depth_two,
        .anderson_depth_one,
        .coordinate_anderson,
        => true,
        else => false,
    };
}

/// SOLUTE's association, ion-pairing, exchange, and mineral-saturation
/// branches calculate thermodynamic targets. Their legacy T*H limits are
/// fixed-cycle relaxation controls, not hourly source rates. Newton/Picard
/// closure therefore retains inventory-fraction bounds but removes these
/// dimensional caps. True kinetic sources are operator-split separately.
pub fn equilibriumClosureParameters(
    parameters: chemistry.ReactionParameters,
) chemistry.ReactionParameters {
    var result = parameters;
    // Reaction implementations retain their substrate/product fractional
    // bounds. A very large finite ceiling removes only the flat dimensional
    // limiter while satisfying finite-input validation.
    const unlimited = 1.0e100;
    if (result.carboxyl_exchange_parameters
        .maximum_exchange_mol_per_m3_per_iteration > 0)
    {
        result.carboxyl_exchange_parameters
            .maximum_exchange_mol_per_m3_per_iteration = unlimited;
    }
    if (result.aqueous_kinetics.maximum_fast_association_mol_per_m3_step > 0)
        result.aqueous_kinetics.maximum_fast_association_mol_per_m3_step =
            unlimited;
    if (result.aqueous_kinetics.maximum_slow_association_mol_per_m3_step > 0)
        result.aqueous_kinetics.maximum_slow_association_mol_per_m3_step =
            unlimited;
    if (result.phosphate_surface.maximum_exchange_mol_per_megagram_step > 0)
        result.phosphate_surface.maximum_exchange_mol_per_megagram_step = unlimited;
    if (result.phosphate_minerals) |*minerals| {
        if (minerals.maximum_phosphate_precipitation_mol_per_m3_step > 0)
            minerals.maximum_phosphate_precipitation_mol_per_m3_step =
                unlimited;
        if (minerals.maximum_apatite_precipitation_mol_per_m3_step > 0)
            minerals.maximum_apatite_precipitation_mol_per_m3_step =
                unlimited;
        if (minerals.maximum_mineral_dissolution_mol_per_m3_step > 0)
            minerals.maximum_mineral_dissolution_mol_per_m3_step = unlimited;
    }
    if (result.phosphate_kinetics.maximum_pairing_mol_per_m3_step > 0)
        result.phosphate_kinetics.maximum_pairing_mol_per_m3_step = unlimited;
    if (result.cation_exchange_parameters
        .maximum_adsorption_mol_charge_per_m3_step > 0)
    {
        result.cation_exchange_parameters
            .maximum_adsorption_mol_charge_per_m3_step = unlimited;
    }
    // Geochemical mineral transformations are bounded per-step kinetic
    // extents. They are applied once between equilibrium closures below.
    result.geochemistry_kinetics
        .maximum_hydroxide_mineral_mol_per_m3_step = 0;
    result.geochemistry_kinetics
        .maximum_general_mineral_mol_per_m3_step = 0;
    result.geochemistry_kinetics
        .maximum_natural_weathering_mol_per_m3_step = 0;
    result.geochemistry_kinetics
        .maximum_ground_weathering_mol_per_m3_step = 0;
    return result;
}

pub fn combineResults(first: group_types.Result, second: group_types.Result) group_types.Result {
    return .{
        .iterations = std.math.add(
            u16,
            first.iterations,
            second.iterations,
        ) catch std.math.maxInt(u16),
        .newton_raphson_steps = std.math.add(
            u16,
            first.newton_raphson_steps,
            second.newton_raphson_steps,
        ) catch std.math.maxInt(u16),
        .picard_steps = std.math.add(
            u16,
            first.picard_steps,
            second.picard_steps,
        ) catch std.math.maxInt(u16),
        .anderson_steps = std.math.add(
            u16,
            first.anderson_steps,
            second.anderson_steps,
        ) catch std.math.maxInt(u16),
        .maximum_scaled_residual = @max(
            first.maximum_scaled_residual,
            second.maximum_scaled_residual,
        ),
        .converged = first.converged and second.converged,
        // Only the post-kinetic terminal closure is the finally accepted
        // projection. The first closure is an internal split-solve iterate.
        .accepted_water_equilibrium_extent_mol_per_m3 = second.accepted_water_equilibrium_extent_mol_per_m3,
    };
}

pub fn rememberHistory(
    current: []const f64,
    residual: []const f64,
    previous_state: []f64,
    previous_residual: []f64,
    previous_previous_state: []f64,
    previous_previous_residual: []f64,
    history_count: *u2,
) void {
    if (history_count.* >= 1) {
        @memcpy(previous_previous_state, previous_state);
        @memcpy(previous_previous_residual, previous_residual);
    }
    @memcpy(previous_state, current);
    @memcpy(previous_residual, residual);
    history_count.* = @min(2, history_count.* + 1);
}

pub fn validateOptions(options: group_types.Options) !void {
    if (options.search_reference_concentrations) |references| {
        if (references.len != chemistry.State.packedComponentCount()) return error.InvalidSoluteReactionSolverOptions;
        for (references) |reference| if (!std.math.isFinite(reference) or reference < 0) return error.InvalidSoluteReactionSolverOptions;
    }
    if (!options.anderson_recovery or !std.math.isFinite(options.absolute_tolerance_mol_per_m3) or options.absolute_tolerance_mol_per_m3 <= 0 or !std.math.isFinite(options.absolute_tolerance_mol_per_megagram) or options.absolute_tolerance_mol_per_megagram <= 0 or !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or !std.math.isFinite(options.directional_probe_fraction) or options.directional_probe_fraction <= 0 or !std.math.isFinite(options.minimum_newton_fraction) or options.minimum_newton_fraction <= 0 or !std.math.isFinite(options.maximum_newton_fraction) or options.maximum_newton_fraction < options.minimum_newton_fraction or options.maximum_newton_fraction > 1 or options.max_iterations == 0 or options.divergence_patience == 0 or !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1) return error.InvalidSoluteReactionSolverOptions;
}

// Moved to reaction_solve.zig; re-exported so call sites are unchanged.
pub const __solve = @import("reaction_solve.zig");
pub const retainMeaningfulCandidate = __solve.retainMeaningfulCandidate;
pub const retainMeaningfulNewtonCandidate = __solve.retainMeaningfulNewtonCandidate;
pub const andersonTierEnabled = __solve.andersonTierEnabled;
pub const solveCell = __solve.solveCell;
pub const solveCellWithTrace = __solve.solveCellWithTrace;
pub const solveCellWithWorkspace = __solve.solveCellWithWorkspace;
pub const solveCellWithWorkspaceAndTrace = __solve.solveCellWithWorkspaceAndTrace;
pub const requireAcceptedStateConservation = __solve.requireAcceptedStateConservation;
pub const rebaseEntryCarboxylCapacity = __solve.rebaseEntryCarboxylCapacity;
pub const solveEquilibriumWithWorkspace = __solve.solveEquilibriumWithWorkspace;
pub const solvePivotedHouseholder = __solve.solvePivotedHouseholder;

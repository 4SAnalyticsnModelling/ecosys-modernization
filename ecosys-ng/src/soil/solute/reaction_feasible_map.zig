//! Feasible source-map direction with reaction-local donor stopping.
//! This selects a search direction; it does not price physical convergence.
const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const span = @import("conservative_reaction_span.zig");
const numerics = @import("reaction_solver_numerics.zig");
const indices = @import("reaction_solver_numerics2.zig");

pub fn evaluate(scratch: *chemistry.State, current: []const f64, transformations: chemistry.CellTransformations, parameters: chemistry.ReactionParameters, output: []f64) !void {
    const full_fraction = try numerics.transformedVectorAdmissible(scratch, current, transformations, parameters, 1, output);
    if (full_fraction == 1) return;
    const component_count = comptime chemistry.State.packedComponentCount();
    if (current.len != component_count or output.len != component_count) return error.ChemistryVectorSizeMismatch;
    try scratch.unpackCell(0, current);
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    const water = try @import("water_equilibrium.zig").solve(.{
        .hydrogen_concentration_mol_per_m3 = scratch.aqueous[0].hydrogen,
        .hydroxide_concentration_mol_per_m3 = scratch.aqueous[0].hydroxide,
        .monovalent_activity_coefficient = coefficients.monovalent_activity_coefficient,
        .water_activity_product_mol2_per_m6 = parameters.water_activity_product_mol2_per_m6,
        .negligible_concentration_mol_per_m3 = parameters.negligible_water_ion_concentration_mol_per_m3,
    });
    scratch.aqueous[0].hydrogen = water.hydrogen_concentration_mol_per_m3;
    scratch.aqueous[0].hydroxide = water.hydroxide_concentration_mol_per_m3;
    var rates: [span.reaction_count]f64 = undefined;
    try span.evaluateRates(scratch, 0, parameters, &rates);
    var columns: [span.reaction_count][component_count]f64 = undefined;
    var active: [span.reaction_count]bool = undefined;
    var fractions: [span.reaction_count]f64 = @splat(0);
    for (rates, 0..) |rate, reaction| {
        active[reaction] = rate != 0;
        if (rate == 0) {
            @memset(&columns[reaction], 0);
            continue;
        }
        var changes = span.zeroTransformations(parameters);
        try span.addReactionExtent(&changes, reaction, rate, transformations, parameters);
        try scratch.undampedReactionBalance(0, changes, coefficients.monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, &columns[reaction]);
    }
    const hydrogen = indices.aqueousPackedIndex("hydrogen");
    const hydroxide = indices.aqueousPackedIndex("hydroxide");
    var pools: [component_count]f64 = undefined;
    @memcpy(&pools, current);
    // Each pass either finishes or stops at least one consuming reaction.
    // This is a finite linear inventory calculation, not a nonlinear retry.
    for (0..span.reaction_count + 1) |_| {
        var direction: [component_count]f64 = @splat(0);
        for (0..span.reaction_count) |reaction| {
            if (!active[reaction]) continue;
            for (0..component_count) |row| direction[row] += (1 - fractions[reaction]) * columns[reaction][row];
        }
        var fraction: f64 = 1;
        var limiting: ?usize = null;
        for (direction, pools, 0..) |change, available, row| {
            if (!std.math.isFinite(change) or !std.math.isFinite(available)) return error.NonFiniteSoluteReactionState;
            if (row == hydrogen or row == hydroxide or change >= 0) continue;
            const bound = @max(0, available) / -change;
            if (bound < fraction) {
                fraction = bound;
                limiting = row;
            }
        }
        for (&fractions, active) |*value, moving| if (moving) {
            value.* += fraction * (1 - value.*);
        };
        if (limiting) |row| {
            var stopped = false;
            for (&active, 0..) |*moving, reaction| {
                if (moving.* and columns[reaction][row] < 0) {
                    moving.* = false;
                    stopped = true;
                }
            }
            if (!stopped) return error.InvalidFeasibleReactionDirection;
            @memcpy(&pools, current);
            for (fractions, 0..) |amount, reaction| {
                for (0..component_count) |component| pools[component] += amount * columns[reaction][component];
            }
        } else break;
    }
    var changes = span.zeroTransformations(parameters);
    for (rates, fractions, 0..) |rate, fraction, reaction| {
        if (rate == 0 or fraction == 0) continue;
        try span.addReactionExtent(&changes, reaction, rate * fraction, transformations, parameters);
    }
    // The actual transaction remains authoritative for rounding, coupled
    // carrier reconciliation, and dependent H/OH projection.
    _ = try numerics.transformedVectorAdmissible(scratch, current, changes, parameters, 1, output);
}

//! `coupled_gas_solver` declarations: newton steps.
//!
//! Split out of `coupled_gas_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const gas = @import("transport.zig");
const atmosphere = @import("atmosphere_exchange.zig");
const numerics = @import("../../core/numerics.zig");
const group_diagnostics = @import("coupled_gas_solver_diagnostics.zig");
const group_directions = @import("coupled_gas_solver_directions.zig");
const group_misc = @import("coupled_gas_solver_misc.zig");
const group_residual = @import("coupled_gas_solver_residual.zig");

/// Solves all currently unconverged gaseous species on one conservative face
/// manifold. A transfer coordinate adds mass to the receiving cell and
/// removes exactly the same mass from its neighbor. The small dense Jacobian
/// therefore captures cross-species pressure displacement without changing
/// any species inventory or assembling the complete three-phase system.
pub fn conservativeMultiSpeciesFaceNewtonStep(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    residual_fraction: f64,
    target: []f64,
    probe: []f64,
    probe_residual: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    previous: []f64,
    previous_residual: []f64,
    options: group_misc.Options,
    current_norm: f64,
    target_was_overwritten: *bool,
) !bool {
    target_was_overwritten.* = false;
    if (current_norm <= 10) return false;
    const inventory_count = scratch.gaseous_mass_g.len;
    const limiting_index =
        (try group_diagnostics.worstExtremeIncomingGasIndex(
            current,
            residual,
            target,
            inputs,
            options,
            inventory_count,
        )) orelse return false;
    if (current[limiting_index] <= 0 or
        residual[limiting_index] <= 0 or
        target[limiting_index] <= current[limiting_index])
        return false;
    const receiving_cell = limiting_index / gas.species_count;
    const limiting_species = limiting_index % gas.species_count;
    const active_species = try allocator.alloc(usize, gas.species_count);
    defer allocator.free(active_species);
    var dimension: usize = 0;
    for (0..gas.species_count) |species| {
        if (try group_diagnostics.scaledSpeciesNorm(
            current,
            residual,
            options,
            inventory_count,
            species,
        ) > 1) {
            active_species[dimension] = species;
            dimension += 1;
        }
    }
    if (dimension < 2) return false;

    for (inputs.faces) |face| {
        if (face.first_cell != receiving_cell and
            face.second_cell != receiving_cell)
            continue;
        const donor_cell =
            if (face.first_cell == receiving_cell)
                face.second_cell
            else
                face.first_cell;
        const limiting_donor =
            donor_cell * gas.species_count + limiting_species;
        if (current[limiting_donor] <=
            10.0 * current[limiting_index])
            continue;

        const matrix = try allocator.alloc(
            f64,
            try std.math.mul(usize, dimension, dimension),
        );
        defer allocator.free(matrix);
        const right_hand_side = try allocator.alloc(f64, dimension);
        defer allocator.free(right_hand_side);
        var valid_jacobian = true;
        for (active_species[0..dimension], 0..) |species, column| {
            const receiver = receiving_cell * gas.species_count + species;
            const donor = donor_cell * gas.species_count + species;
            // The donor can be many orders of magnitude larger than the
            // receiver. sqrt(epsilon)*donor then becomes a nonlocal,
            // gram-scale transfer and differentiates the wrong active-set
            // branch. Use receiver-scale truncation error, but never request
            // less than a comfortably representable subtraction at the
            // donor magnitude.
            const donor_resolution_g =
                64.0 * std.math.floatEps(f64) *
                @max(1.0, current[donor]);
            const receiver_probe_g =
                group_directions.gasJacobianProbeG(
                    current[receiver],
                    group_misc.absoluteToleranceForSpecies(options, species),
                );
            const epsilon = @min(
                current[donor],
                @max(donor_resolution_g, receiver_probe_g),
            );
            if (!std.math.isFinite(epsilon) or epsilon <= 0) {
                valid_jacobian = false;
                break;
            }
            @memcpy(probe, current);
            probe[receiver] += epsilon;
            probe[donor] -= epsilon;
            target_was_overwritten.* = true;
            group_residual.residualAt(
                allocator,
                scratch,
                base,
                probe,
                inputs,
                residual_fraction,
                target,
                probe_residual,
            ) catch {
                valid_jacobian = false;
                break;
            };
            for (active_species[0..dimension], 0..) |row_species, row| {
                const row_index =
                    receiving_cell * gas.species_count + row_species;
                matrix[row * dimension + column] =
                    (probe_residual[row_index] - residual[row_index]) /
                    epsilon;
            }
        }
        if (!valid_jacobian) continue;
        for (active_species[0..dimension], 0..) |species, row| {
            const index = receiving_cell * gas.species_count + species;
            right_hand_side[row] = -residual[index];
        }
        if (!numerics.solveDenseLinearSystem(
            matrix,
            right_hand_side,
            dimension,
        )) continue;
        @memset(probe, 0);
        for (active_species[0..dimension], right_hand_side) |species, change| {
            if (!std.math.isFinite(change)) {
                valid_jacobian = false;
                break;
            }
            const receiver = receiving_cell * gas.species_count + species;
            const donor = donor_cell * gas.species_count + species;
            probe[receiver] = change;
            probe[donor] = -change;
        }
        if (!valid_jacobian) continue;
        var fraction: f64 = 1;
        var search: u8 = 0;
        const current_limiting_norm =
            try group_diagnostics.scaledCoordinateResidual(
                current[limiting_index],
                residual[limiting_index],
                options,
                limiting_index,
                inventory_count,
            );
        while (search < 24) : (search += 1) {
            @memcpy(candidate, current);
            var nonnegative = true;
            for (candidate, probe) |*value, direction| {
                value.* += fraction * direction;
                if (!std.math.isFinite(value.*) or value.* < 0) {
                    nonnegative = false;
                    break;
                }
            }
            if (!nonnegative) {
                fraction *= 0.5;
                continue;
            }
            if (group_residual.residualAt(
                allocator,
                scratch,
                base,
                candidate,
                inputs,
                residual_fraction,
                target,
                candidate_residual,
            )) |_| {
                const candidate_norm =
                    try group_diagnostics.scaledNorm(candidate, candidate_residual, options);
                const candidate_limiting_norm =
                    try group_diagnostics.scaledCoordinateResidual(
                        candidate[limiting_index],
                        candidate_residual[limiting_index],
                        options,
                        limiting_index,
                        inventory_count,
                    );
                if (candidate_limiting_norm < current_limiting_norm and
                    candidate_norm < current_norm)
                {
                    @memcpy(previous, current);
                    @memcpy(previous_residual, residual);
                    @memcpy(current, candidate);
                    return true;
                }
            } else |_| {}
            fraction *= 0.5;
        }
    }
    return false;
}

/// Resolves a donor-clamped gaseous face on its conservative coordinate.
/// Moving only the limiting cell can make the neighboring residual worse and
/// causes the projected scalar/full Newton paths to bounce between opposite
/// donor bounds. An equal-and-opposite pair correction follows the actual
/// face conservation manifold while the full residual/line search continues
/// to account for pressure displacement, other faces, and phase exchange.
pub fn conservativeFaceNewtonStep(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    residual_fraction: f64,
    target: []f64,
    probe: []f64,
    probe_residual: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    previous: []f64,
    previous_residual: []f64,
    options: group_misc.Options,
    current_norm: f64,
    target_was_overwritten: *bool,
) !bool {
    target_was_overwritten.* = false;
    const inventory_count = scratch.gaseous_mass_g.len;
    const limiting_index =
        (try group_diagnostics.worstScaleSeparatedIncomingGasIndex(
            current,
            residual,
            target,
            inputs,
            options,
            inventory_count,
        )) orelse return false;
    // This scalar safeguard is reserved for an unresolved incoming pool whose
    // residual exceeds its complete receiving inventory. Less-extreme
    // scale-separated blocks stay in the coupled multi-species Newton/Picard
    // path so one face coordinate cannot preempt the global correction.
    if (current[limiting_index] <= 0 or
        residual[limiting_index] <= 0 or
        target[limiting_index] <= current[limiting_index])
        return false;
    const limiting_cell = limiting_index / gas.species_count;
    const species = limiting_index % gas.species_count;
    for (inputs.faces) |face| {
        if (face.first_cell != limiting_cell and
            face.second_cell != limiting_cell)
            continue;
        const neighbor_cell =
            if (face.first_cell == limiting_cell)
                face.second_cell
            else
                face.first_cell;
        const neighbor_index =
            neighbor_cell * gas.species_count + species;
        if (current[neighbor_index] <=
            10.0 * current[limiting_index])
            continue;
        var probe_transfer_g = group_directions.gasJacobianProbeG(
            @max(current[limiting_index], current[neighbor_index]),
            group_misc.absoluteToleranceForSpecies(options, species),
        );
        if (current[neighbor_index] >= probe_transfer_g) {
            // Positive transfer increases the limiting cell.
        } else if (current[limiting_index] >= probe_transfer_g) {
            probe_transfer_g = -probe_transfer_g;
        } else {
            continue;
        }
        @memcpy(probe, current);
        probe[limiting_index] += probe_transfer_g;
        probe[neighbor_index] -= probe_transfer_g;
        target_was_overwritten.* = true;
        group_residual.residualAt(
            allocator,
            scratch,
            base,
            probe,
            inputs,
            residual_fraction,
            target,
            probe_residual,
        ) catch continue;
        const derivative =
            (probe_residual[limiting_index] -
                residual[limiting_index]) /
            probe_transfer_g;
        if (!std.math.isFinite(derivative) or
            @abs(derivative) <= std.math.floatEps(f64))
            continue;
        const correction_g =
            std.math.clamp(
                -residual[limiting_index] / derivative,
                -current[limiting_index],
                current[neighbor_index],
            );
        if (!std.math.isFinite(correction_g) or correction_g == 0)
            continue;
        var fraction: f64 = 1;
        var search: u8 = 0;
        while (search < 24) : (search += 1) {
            @memcpy(candidate, current);
            const accepted_transfer_g = fraction * correction_g;
            candidate[limiting_index] += accepted_transfer_g;
            candidate[neighbor_index] -= accepted_transfer_g;
            if (candidate[limiting_index] < 0 or
                candidate[neighbor_index] < 0)
            {
                fraction *= 0.5;
                continue;
            }
            if (group_residual.residualAt(
                allocator,
                scratch,
                base,
                candidate,
                inputs,
                residual_fraction,
                target,
                candidate_residual,
            )) |_| {
                const current_coordinate_norm =
                    try group_diagnostics.scaledCoordinateResidual(
                        current[limiting_index],
                        residual[limiting_index],
                        options,
                        limiting_index,
                        inventory_count,
                    );
                const candidate_coordinate_norm =
                    try group_diagnostics.scaledCoordinateResidual(
                        candidate[limiting_index],
                        candidate_residual[limiting_index],
                        options,
                        limiting_index,
                        inventory_count,
                    );
                const candidate_global_norm =
                    try group_diagnostics.scaledNorm(
                        candidate,
                        candidate_residual,
                        options,
                    );
                const unresolved_positive_bound =
                    group_diagnostics.hasUnresolvedPositiveBound(
                        candidate[limiting_index],
                        target[limiting_index],
                        candidate_residual[limiting_index],
                    );
                // A locally improving active-set correction is publishable
                // only when it is also a strict exact global-merit descent.
                // Coupled pressure residuals may move between species, so a
                // coordinate-only test cannot protect the accepted state.
                if (!unresolved_positive_bound and
                    candidate_coordinate_norm <
                        current_coordinate_norm and
                    candidate_global_norm < current_norm)
                {
                    @memcpy(previous, current);
                    @memcpy(previous_residual, residual);
                    @memcpy(current, candidate);
                    return true;
                }
            } else |_| {}
            fraction *= 0.5;
        }
    }
    return false;
}

/// A gas coordinate exactly at zero has a discontinuous pressure correction:
/// its residual omits the mixture displacement until the first positive trial.
/// Linearizing with an epsilon-sized perturbation therefore produces an
/// unusably large positive slope. Form a physically populated active-set
/// point, take its Newton step on the smooth positive branch, then accept
/// only the line-searched Newton result. The populated point itself is never
/// committed as a Picard update.
fn activeSetConservativeFaceNewtonStep(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    residual_fraction: f64,
    target: []f64,
    probe: []f64,
    probe_residual: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    previous: []f64,
    previous_residual: []f64,
    options: group_misc.Options,
    current_norm: f64,
    limiting_index: usize,
    populated_seed_g: f64,
) !bool {
    const inventory_count = scratch.gaseous_mass_g.len;
    const receiver_cell = limiting_index / gas.species_count;
    const species = limiting_index % gas.species_count;
    const current_coordinate_norm =
        try group_diagnostics.scaledCoordinateResidual(
            current[limiting_index],
            residual[limiting_index],
            options,
            limiting_index,
            inventory_count,
        );
    for (inputs.faces) |face| {
        const donor_cell = if (face.first_cell == receiver_cell)
            face.second_cell
        else if (face.second_cell == receiver_cell)
            face.first_cell
        else
            continue;
        const donor_index = donor_cell * gas.species_count + species;
        if (current[donor_index] <= 0) continue;
        const seed_transfer_g = @min(
            populated_seed_g,
            current[donor_index],
        );
        if (!std.math.isFinite(seed_transfer_g) or
            seed_transfer_g <= 0)
            continue;

        // Populate the smooth face branch by an equal-and-opposite transfer.
        // The seed is a Jacobian point only; it is never a committed Picard
        // update and therefore preserves the no-vanilla-publication policy.
        @memcpy(candidate, current);
        candidate[limiting_index] += seed_transfer_g;
        candidate[donor_index] -= seed_transfer_g;
        if (group_residual.residualAt(
            allocator,
            scratch,
            base,
            candidate,
            inputs,
            residual_fraction,
            target,
            candidate_residual,
        )) |_| {} else |_| continue;

        const epsilon = @min(
            group_directions.gasJacobianProbeG(
                seed_transfer_g,
                group_misc.absoluteToleranceForSpecies(options, species),
            ),
            0.5 * candidate[donor_index],
        );
        if (!std.math.isFinite(epsilon) or epsilon <= 0) continue;
        @memcpy(probe, candidate);
        probe[limiting_index] += epsilon;
        probe[donor_index] -= epsilon;
        if (group_residual.residualAt(
            allocator,
            scratch,
            base,
            probe,
            inputs,
            residual_fraction,
            target,
            probe_residual,
        )) |_| {} else |_| continue;
        const derivative =
            (probe_residual[limiting_index] -
                candidate_residual[limiting_index]) /
            epsilon;
        if (!std.math.isFinite(derivative) or derivative >= 0)
            continue;
        const correction_g =
            -candidate_residual[limiting_index] / derivative;
        if (!std.math.isFinite(correction_g))
            continue;

        // The pressure clamp is discontinuous at the zero-inventory bound.
        // Backtrack the Newton correction on the positive, donor-conservative
        // branch. The seed itself remains uncommitted, so this never
        // publishes an unaccelerated Picard image.
        var fraction: f64 = 1;
        var search: u8 = 0;
        while (search < 24) : (search += 1) {
            const transfer_g = seed_transfer_g +
                fraction * correction_g;
            if (transfer_g <= 0 or transfer_g > current[donor_index]) {
                fraction *= 0.5;
                continue;
            }
            @memcpy(probe, current);
            probe[limiting_index] += transfer_g;
            probe[donor_index] -= transfer_g;
            if (group_residual.residualAt(
                allocator,
                scratch,
                base,
                probe,
                inputs,
                residual_fraction,
                target,
                probe_residual,
            )) |_| {
                const coordinate_norm =
                    try group_diagnostics.scaledCoordinateResidual(
                        probe[limiting_index],
                        probe_residual[limiting_index],
                        options,
                        limiting_index,
                        inventory_count,
                    );
                const global_norm = try group_diagnostics.scaledNorm(
                    probe,
                    probe_residual,
                    options,
                );
                if (coordinate_norm < current_coordinate_norm and
                    global_norm < current_norm)
                {
                    @memcpy(previous, current);
                    @memcpy(previous_residual, residual);
                    @memcpy(current, probe);
                    return true;
                }
            } else |_| {}
            fraction *= 0.5;
        }
    }
    return false;
}

/// Releases a zero gaseous bound from its paired aqueous source. In a nearly
/// saturated pore, volatilization or bubbling can supply gas without a
/// gaseous donor face; changing only the gas coordinate then breaks the
/// phase-transfer invariant and leaves Newton at the non-smooth bound.
fn activeSetDissolvedGasNewtonStep(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    residual_fraction: f64,
    target: []f64,
    probe: []f64,
    probe_residual: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    previous: []f64,
    previous_residual: []f64,
    options: group_misc.Options,
    current_norm: f64,
    limiting_index: usize,
    populated_seed_g: f64,
) !bool {
    const inventory_count = scratch.gaseous_mass_g.len;
    const receiver_cell = limiting_index / gas.species_count;
    const species = limiting_index % gas.species_count;
    const current_coordinate_norm =
        try group_diagnostics.scaledCoordinateResidual(
            current[limiting_index],
            residual[limiting_index],
            options,
            limiting_index,
            inventory_count,
        );
    for (0..scratch.cell_count) |source_cell| {
        const local_phase_source = source_cell == receiver_cell;
        const bubble_source = if (inputs.bubble_receiver_cell_by_cell) |receivers|
            inputs.bubbling_enabled[source_cell] and
                receivers[source_cell] != null and
                receivers[source_cell].? == receiver_cell
        else
            false;
        if (!local_phase_source and !bubble_source) continue;

        const source_gas_index =
            source_cell * gas.species_count + species;
        for ([_]usize{ inventory_count, 2 * inventory_count }) |phase_offset| {
            const donor_index = phase_offset + source_gas_index;
            if (current[donor_index] <= 0) continue;
            // Enter the positive phase branch at a pressure-capacity scale,
            // rather than at the assembled defect scale. Near a dry bound
            // the latter remains on the discontinuity and differentiates the
            // wrong (volatilizing) branch. This is an uncommitted Newton
            // expansion point, never a published Picard image.
            const seed_transfer_g = @min(
                populated_seed_g,
                current[donor_index],
            );
            if (!std.math.isFinite(seed_transfer_g) or
                seed_transfer_g <= 0)
                continue;

            @memcpy(candidate, current);
            candidate[limiting_index] += seed_transfer_g;
            candidate[donor_index] -= seed_transfer_g;
            if (group_residual.residualAt(
                allocator,
                scratch,
                base,
                candidate,
                inputs,
                residual_fraction,
                target,
                candidate_residual,
            )) |_| {} else |_| continue;

            const epsilon = @min(
                group_directions.gasJacobianProbeG(
                    seed_transfer_g,
                    group_misc.absoluteToleranceForSpecies(options, species),
                ),
                0.5 * candidate[donor_index],
            );
            if (!std.math.isFinite(epsilon) or epsilon <= 0)
                continue;
            @memcpy(probe, candidate);
            probe[limiting_index] += epsilon;
            probe[donor_index] -= epsilon;
            if (group_residual.residualAt(
                allocator,
                scratch,
                base,
                probe,
                inputs,
                residual_fraction,
                target,
                probe_residual,
            )) |_| {} else |_| continue;
            const derivative =
                (probe_residual[limiting_index] -
                    candidate_residual[limiting_index]) /
                epsilon;
            if (std.math.isFinite(derivative) and derivative < 0) {
                const correction_g =
                    -candidate_residual[limiting_index] / derivative;
                const full_transfer_g = seed_transfer_g + correction_g;
                if (std.math.isFinite(full_transfer_g) and
                    full_transfer_g > 0)
                {
                    var fraction: f64 = 1;
                    var search: u8 = 0;
                    while (search < 24) : (search += 1) {
                        const transfer_g = fraction * full_transfer_g;
                        if (transfer_g > current[donor_index]) {
                            fraction *= 0.5;
                            continue;
                        }
                        @memcpy(probe, current);
                        probe[limiting_index] += transfer_g;
                        probe[donor_index] -= transfer_g;
                        if (group_residual.residualAt(
                            allocator,
                            scratch,
                            base,
                            probe,
                            inputs,
                            residual_fraction,
                            target,
                            probe_residual,
                        )) |_| {
                            const coordinate_norm =
                                try group_diagnostics.scaledCoordinateResidual(
                                    probe[limiting_index],
                                    probe_residual[limiting_index],
                                    options,
                                    limiting_index,
                                    inventory_count,
                                );
                            if (coordinate_norm < current_coordinate_norm and
                                try group_diagnostics.scaledNorm(
                                    probe,
                                    probe_residual,
                                    options,
                                ) < current_norm)
                            {
                                @memcpy(previous, current);
                                @memcpy(previous_residual, residual);
                                @memcpy(current, probe);
                                return true;
                            }
                        } else |_| {}
                        fraction *= 0.5;
                    }
                }
            }

            // Anderson recovery is owned by the solve-level fallback after
            // every Newton family has failed. Keep this helper Newton-only so
            // its Boolean result and accounting cannot misclassify a fallback.
        }
    }
    return false;
}

pub fn activeSetGasNewtonStep(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    residual_fraction: f64,
    target: []f64,
    probe: []f64,
    probe_residual: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    previous: []f64,
    previous_residual: []f64,
    options: group_misc.Options,
    current_norm: f64,
    target_was_overwritten: *bool,
) !bool {
    target_was_overwritten.* = false;
    const inventory_count = scratch.gaseous_mass_g.len;
    const limiting_index =
        try group_diagnostics.worstResidualIndex(current, residual, options);
    if (limiting_index >= inventory_count or
        residual[limiting_index] <= 0 or
        !group_diagnostics.isNumericallyAtNonnegativeBound(
            current[limiting_index],
            target[limiting_index],
        ))
        return false;

    // Every active-set helper below may evaluate one or more trial states into
    // the shared target. Conservatively mark it dirty once this rare branch is
    // entered; the caller then restores F(current) exactly once if all helpers
    // reject their candidates.
    target_was_overwritten.* = true;

    const cell = limiting_index / gas.species_count;
    const species = limiting_index % gas.species_count;
    std.log.debug(
        "gas active bound: cell={d} species={d} target_g={e} residual_g={e}",
        .{
            cell,
            species,
            target[limiting_index],
            residual[limiting_index],
        },
    );
    const air_volume_m3 = scratch.air_volume_m3[cell];
    const temperature_k = scratch.temperature_k[cell];
    const capacity_g =
        1.2194e4 * air_volume_m3 / temperature_k *
        gas.g_per_mol_tracked[species];
    const pressure_branch_seed_g = 0.5 * capacity_g;
    // Use the assembled incoming inventory for the unconstrained smooth
    // branch. The conservative pressure-face path below instead evaluates
    // its Newton derivative beyond the clamp activation threshold.
    const populated_seed_g = pressure_branch_seed_g;
    if (!std.math.isFinite(populated_seed_g) or populated_seed_g <= 0)
        return false;
    if (try activeSetDissolvedGasNewtonStep(
        allocator,
        scratch,
        base,
        current,
        residual,
        inputs,
        residual_fraction,
        target,
        probe,
        probe_residual,
        candidate,
        candidate_residual,
        previous,
        previous_residual,
        options,
        current_norm,
        limiting_index,
        pressure_branch_seed_g,
    )) return true;
    if (try activeSetConservativeFaceNewtonStep(
        allocator,
        scratch,
        base,
        current,
        residual,
        inputs,
        residual_fraction,
        target,
        probe,
        probe_residual,
        candidate,
        candidate_residual,
        previous,
        previous_residual,
        options,
        current_norm,
        limiting_index,
        pressure_branch_seed_g,
    )) return true;

    // Both rejected active-set helpers evaluate trial states and therefore
    // overwrite the shared assembled `target`. Rebuild F(current) before
    // selecting every unresolved bound for the complete smooth-manifold
    // Newton system; pairing current residuals with a stale target can omit
    // simultaneous atmospheric or phase sources entirely.
    try group_residual.residualAt(
        allocator,
        scratch,
        base,
        current,
        inputs,
        residual_fraction,
        target,
        candidate_residual,
    );

    // Populate every unresolved gaseous bound before forming the Jacobian.
    // Pressure displacement couples species and neighboring cells, so a
    // scalar derivative at the worst zero coordinate can be an ascent in a
    // tied low-air-volume receiver. These are only smooth-manifold Newton
    // seeds: neither the populated vector nor a fixed-point image is ever
    // committed.
    @memcpy(candidate, current);
    var populated_count: usize = 0;
    for (0..inventory_count) |index| {
        if (residual[index] <= 0 or
            !group_diagnostics.isNumericallyAtNonnegativeBound(
                current[index],
                target[index],
            ))
            continue;
        const seed_cell = index / gas.species_count;
        const seed_species = index % gas.species_count;
        const seed_capacity_g =
            1.2194e4 * scratch.air_volume_m3[seed_cell] /
            scratch.temperature_k[seed_cell] *
            gas.g_per_mol_tracked[seed_species];
        // The assembled zero-branch target can be many orders of magnitude
        // below the positive pressure branch. It is not a valid Jacobian
        // expansion scale. Seed at half ideal-gas capacity, then publish only
        // the strictly descending Newton correction from that smooth branch.
        const seed_g = 0.5 * seed_capacity_g;
        if (!std.math.isFinite(seed_g) or seed_g <= 0) continue;
        candidate[index] = seed_g;
        populated_count += 1;
    }
    if (populated_count == 0) return false;
    if (group_residual.residualAt(
        allocator,
        scratch,
        base,
        candidate,
        inputs,
        residual_fraction,
        target,
        candidate_residual,
    )) |_| {} else |_| return false;

    // Prefer the complete damped Newton correction on the populated smooth
    // manifold. It includes the donor and all pressure-coupled species, which
    // avoids the scalar active-set derivative treating a conservative face
    // source as external mass.
    if (try group_directions.denseFullNewtonDirection(
        allocator,
        scratch,
        base,
        candidate,
        candidate_residual,
        inputs,
        options,
        target,
        probe_residual,
        previous,
        probe,
    )) {
        // The Newton direction is formed at the populated smooth-manifold
        // seed, but its line search must start from the physical current
        // state. Starting from the seed cannot backtrack through the
        // zero-inventory bound and rejects every low-air-volume release.
        for (candidate, probe, current) |seed, *direction, value| {
            const full_newton_value = seed + direction.*;
            if (!std.math.isFinite(full_newton_value)) {
                direction.* = 0;
                continue;
            }
            direction.* = full_newton_value - value;
        }
        var fraction: f64 = 1;
        var search: u8 = 0;
        while (search < 24) : (search += 1) {
            @memcpy(previous, current);
            var nonnegative = true;
            for (previous, probe) |*value, direction| {
                value.* += fraction * direction;
                if (!std.math.isFinite(value.*) or value.* < 0) {
                    nonnegative = false;
                    break;
                }
            }
            if (nonnegative) {
                if (group_residual.residualAt(
                    allocator,
                    scratch,
                    base,
                    previous,
                    inputs,
                    residual_fraction,
                    target,
                    probe_residual,
                )) |_| {
                    const active_coordinate_norm =
                        try group_diagnostics.scaledCoordinateResidual(
                            previous[limiting_index],
                            probe_residual[limiting_index],
                            options,
                            limiting_index,
                            inventory_count,
                        );
                    const global_norm = try group_diagnostics.scaledNorm(
                        previous,
                        probe_residual,
                        options,
                    );
                    const active_descent =
                        active_coordinate_norm <
                        try group_diagnostics.scaledCoordinateResidual(
                            current[limiting_index],
                            residual[limiting_index],
                            options,
                            limiting_index,
                            inventory_count,
                        ) and
                        global_norm < current_norm;
                    if (active_descent) {
                        @memcpy(candidate, current);
                        @memcpy(current, previous);
                        @memcpy(previous, candidate);
                        @memcpy(previous_residual, residual);
                        return true;
                    }
                } else |_| {}
            }
            fraction *= 0.5;
        }
    }

    // Fall back to the local scalar smooth-manifold Newton correction only
    // when the complete active-set Jacobian cannot yield a damped descent.
    // This remains Newton, not a Picard publication.
    @memcpy(candidate, current);
    candidate[limiting_index] = pressure_branch_seed_g;
    if (group_residual.residualAt(
        allocator,
        scratch,
        base,
        candidate,
        inputs,
        residual_fraction,
        target,
        candidate_residual,
    )) |_| {} else |_| return false;
    const epsilon =
        group_directions.gasJacobianProbeG(
            pressure_branch_seed_g,
            group_misc.absoluteToleranceForCoordinate(
                options,
                limiting_index,
                inventory_count,
            ),
        );
    @memcpy(probe, candidate);
    probe[limiting_index] += epsilon;
    if (group_residual.residualAt(
        allocator,
        scratch,
        base,
        probe,
        inputs,
        residual_fraction,
        target,
        probe_residual,
    )) |_| {} else |_| return false;
    const derivative =
        (probe_residual[limiting_index] -
            candidate_residual[limiting_index]) / epsilon;
    if (!std.math.isFinite(derivative) or derivative >= 0) return false;
    const correction = -candidate_residual[limiting_index] / derivative;
    if (!std.math.isFinite(correction)) return false;

    const current_coordinate_norm = try group_diagnostics.scaledCoordinateResidual(
        current[limiting_index],
        residual[limiting_index],
        options,
        limiting_index,
        inventory_count,
    );
    var fraction: f64 = 1;
    var search: u8 = 0;
    while (search < 24) : (search += 1) {
        @memcpy(probe, candidate);
        probe[limiting_index] += fraction * correction;
        if (!std.math.isFinite(probe[limiting_index]) or
            probe[limiting_index] < 0)
        {
            fraction *= 0.5;
            continue;
        }
        if (group_residual.residualAt(
            allocator,
            scratch,
            base,
            probe,
            inputs,
            residual_fraction,
            target,
            probe_residual,
        )) |_| {
            const candidate_coordinate_norm =
                try group_diagnostics.scaledCoordinateResidual(
                    probe[limiting_index],
                    probe_residual[limiting_index],
                    options,
                    limiting_index,
                    inventory_count,
                );
            if (candidate_coordinate_norm < current_coordinate_norm and
                try group_diagnostics.scaledNorm(
                    probe,
                    probe_residual,
                    options,
                ) < current_norm)
            {
                @memcpy(previous, current);
                @memcpy(previous_residual, residual);
                @memcpy(current, probe);
                return true;
            }
        } else |_| {}
        fraction *= 0.5;
    }
    return false;
}

pub fn denseAllSpeciesNewtonStep(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    residual_fraction: f64,
    target: []f64,
    direction: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    previous: []f64,
    previous_residual: []f64,
    options: group_misc.Options,
    current_norm: f64,
) !bool {
    @memset(direction, 0);
    var block_options = options;
    block_options.transport_iteration_fraction =
        residual_fraction;
    if (!try group_directions.denseAllSpeciesNewtonDirection(
        allocator,
        scratch,
        base,
        current,
        residual,
        inputs,
        block_options,
        target,
        candidate_residual,
        candidate,
        direction,
    )) return false;
    if (!try group_directions.filterIndependentSpeciesDirections(
        allocator,
        scratch,
        base,
        current,
        residual,
        inputs,
        block_options,
        target,
        candidate_residual,
        candidate,
        direction,
    )) return false;
    for (current, direction, candidate) |value, delta, *next| {
        next.* = value + delta;
        if (!std.math.isFinite(next.*) or next.* < 0) return false;
    }
    try group_residual.residualAt(
        allocator,
        scratch,
        base,
        candidate,
        inputs,
        residual_fraction,
        target,
        candidate_residual,
    );
    if (try group_diagnostics.scaledNorm(
        candidate,
        candidate_residual,
        options,
    ) >= current_norm) return false;
    @memcpy(previous, current);
    @memcpy(previous_residual, residual);
    @memcpy(current, candidate);
    return true;
}

/// Applies the complete cross-species Jacobian as one bounded tail update.
/// The ordinary loop may hand a scale-separated donor active set to the
/// semismooth tail at half-budget, before its late full-dense window opens.
/// Keeping this wrapper in the shared tail budget ensures pressure-
/// displacement derivatives are still available without adding iterations.
pub fn denseFullNewtonStep(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    residual_fraction: f64,
    target: []f64,
    direction: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    previous: []f64,
    previous_residual: []f64,
    options: group_misc.Options,
    current_norm: f64,
) !bool {
    @memset(direction, 0);
    var full_options = options;
    full_options.transport_iteration_fraction = residual_fraction;
    if (!try group_directions.denseFullNewtonDirection(
        allocator,
        scratch,
        base,
        current,
        residual,
        inputs,
        full_options,
        target,
        candidate_residual,
        candidate,
        direction,
    )) return false;
    var fraction: f64 = 1;
    var search: u8 = 0;
    while (search < 24) : (search += 1) {
        var finite_nonnegative = true;
        for (current, direction, candidate) |value, delta, *next| {
            next.* = value + fraction * delta;
            if (!std.math.isFinite(next.*) or next.* < 0) {
                finite_nonnegative = false;
                break;
            }
        }
        if (finite_nonnegative) {
            if (group_residual.residualAt(
                allocator,
                scratch,
                base,
                candidate,
                inputs,
                residual_fraction,
                target,
                candidate_residual,
            )) |_| {
                if (try group_diagnostics.scaledNorm(
                    candidate,
                    candidate_residual,
                    options,
                ) < current_norm) {
                    @memcpy(previous, current);
                    @memcpy(previous_residual, residual);
                    @memcpy(current, candidate);
                    return true;
                }
            } else |_| {}
        }
        fraction *= 0.5;
    }
    return false;
}

pub fn denseWorstSpeciesNewtonStep(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    residual_fraction: f64,
    target: []f64,
    direction: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    previous: []f64,
    previous_residual: []f64,
    options: group_misc.Options,
    current_norm: f64,
) !bool {
    const inventory_count = scratch.gaseous_mass_g.len;
    const species = try group_diagnostics.worstResidualSpecies(
        current,
        residual,
        options,
        inventory_count,
    );
    @memset(direction, 0);
    var species_options = options;
    species_options.transport_iteration_fraction =
        residual_fraction;
    if (!try group_directions.denseSpeciesNewtonDirection(
        allocator,
        scratch,
        base,
        current,
        residual,
        inputs,
        species_options,
        target,
        candidate_residual,
        candidate,
        direction,
        species,
    )) return false;
    var fraction: f64 = 1;
    var search: u8 = 0;
    while (search < 20) : (search += 1) {
        var admissible = true;
        for (current, direction, candidate) |value, delta, *next| {
            next.* = value + fraction * delta;
            if (!std.math.isFinite(next.*) or next.* < 0) admissible = false;
        }
        if (admissible) {
            if (group_residual.residualAt(
                allocator,
                scratch,
                base,
                candidate,
                inputs,
                residual_fraction,
                target,
                candidate_residual,
            )) |_| {
                if (try group_diagnostics.scaledNorm(
                    candidate,
                    candidate_residual,
                    options,
                ) < current_norm) {
                    @memcpy(previous, current);
                    @memcpy(previous_residual, residual);
                    @memcpy(current, candidate);
                    return true;
                }
            } else |_| {}
        }
        fraction *= 0.5;
    }
    return false;
}

pub fn coordinateNewtonStep(
    allocator: std.mem.Allocator,
    scratch: *gas.State,
    base: []const f64,
    current: []f64,
    residual: []const f64,
    inputs: group_misc.Inputs,
    residual_fraction: f64,
    target: []f64,
    probe: []f64,
    probe_residual: []f64,
    candidate: []f64,
    candidate_residual: []f64,
    previous: []f64,
    previous_residual: []f64,
    options: group_misc.Options,
    current_norm: f64,
) !bool {
    const inventory_count = scratch.gaseous_mass_g.len;
    const limiting_index = try group_diagnostics.worstResidualIndex(current, residual, options);
    // In the convergence tail, stay within the current semismooth active set;
    // a larger cbrt(epsilon) probe can cross a donor clamp and differentiate
    // the neighboring branch instead of the accepted one.
    const coordinate_scale = @max(1.0, @abs(current[limiting_index]));
    const stable_probe = @sqrt(std.math.floatEps(f64)) * coordinate_scale;
    const cancellation_floor = 64.0 * std.math.floatEps(f64) * coordinate_scale;
    // Do not shrink the probe with the residual. Near convergence that made
    // the function difference smaller than the roundoff accumulated by the
    // coupled transport/phase evaluation, producing a biased derivative and
    // dozens of tiny accepted Newton steps. sqrt(epsilon)*state_scale is the
    // standard forward-difference balance between truncation and cancellation.
    const epsilon = @max(cancellation_floor, stable_probe);
    @memcpy(probe, current);
    probe[limiting_index] += epsilon;
    var has_derivative = false;
    var derivative: f64 = 0;
    if (group_residual.residualAt(allocator, scratch, base, probe, inputs, residual_fraction, target, probe_residual)) |_| {
        if (current[limiting_index] >= epsilon) {
            @memcpy(candidate, current);
            candidate[limiting_index] -= epsilon;
            if (group_residual.residualAt(allocator, scratch, base, candidate, inputs, residual_fraction, target, candidate_residual)) |_| {
                derivative = (probe_residual[limiting_index] - candidate_residual[limiting_index]) / (2.0 * epsilon);
                has_derivative = std.math.isFinite(derivative) and @abs(derivative) > std.math.floatEps(f64);
            } else |_| {}
        } else {
            derivative = (probe_residual[limiting_index] - residual[limiting_index]) / epsilon;
            has_derivative = std.math.isFinite(derivative) and @abs(derivative) > std.math.floatEps(f64);
        }
    } else |_| {}
    if (!has_derivative) return false;

    const correction = -residual[limiting_index] / derivative;
    const coordinate_norm = try group_diagnostics.scaledCoordinateResidual(current[limiting_index], residual[limiting_index], options, limiting_index, inventory_count);
    var fraction: f64 = 1;
    var search: u8 = 0;
    while (search < 20) : (search += 1) {
        @memcpy(candidate, current);
        candidate[limiting_index] = current[limiting_index] + fraction * correction;
        if (!std.math.isFinite(candidate[limiting_index]) or candidate[limiting_index] < 0) {
            fraction *= 0.5;
            continue;
        }
        if (group_residual.residualAt(allocator, scratch, base, candidate, inputs, residual_fraction, target, candidate_residual)) |_| {
            const next_coordinate_norm = try group_diagnostics.scaledCoordinateResidual(candidate[limiting_index], candidate_residual[limiting_index], options, limiting_index, inventory_count);
            if (next_coordinate_norm < coordinate_norm and try group_diagnostics.scaledNorm(candidate, candidate_residual, options) < current_norm) {
                @memcpy(previous, current);
                @memcpy(previous_residual, residual);
                @memcpy(current, candidate);
                return true;
            }
        } else |_| {}
        fraction *= 0.5;
    }
    return false;
}

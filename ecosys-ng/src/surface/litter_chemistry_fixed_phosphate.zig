//! `litter_chemistry` declarations: fixed phosphate.
//!
//! Split out of `litter_chemistry.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ledger = @import("litter_reaction_transformations.zig");
const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const numerics = @import("../core/numerics.zig");
const group_fixtures = @import("litter_chemistry_fixtures.zig");
const group_numerics = @import("litter_chemistry_numerics.zig");
const group_phosphate_exchange = @import("litter_chemistry_phosphate_exchange.zig");
const group_phosphate_minerals = @import("litter_chemistry_phosphate_minerals.zig");
const group_struct_arithmetic = @import("litter_chemistry_struct_arithmetic.zig");
const group_types = @import("litter_chemistry_types.zig");

/// Solves each admissible mineral phase assemblage explicitly. An active
/// mineral is constrained to zero saturation residual; an inactive mineral
/// is fixed at zero inventory and must remain undersaturated. This avoids the
/// nearly singular Fischer-Burmeister Jacobian when several large solid
/// inventories compete for the same finite aqueous phosphate pool.
pub fn conservativeFixedPhosphateActiveSetNewton(
    current: group_types.Cell,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
) !?group_types.Cell {
    const calculate =
        evaluator.phosphate_mineral_equilibrium_residuals orelse return null;
    const density = environment.litter_mass_per_water_volume_megagrams_per_m3;
    const site_total = group_phosphate_exchange.phosphateSiteTotal(current);
    const phosphorus_total = group_phosphate_exchange.phosphateTotal(current, density);
    const cation_totals = group_phosphate_exchange.phosphateCationTotals(current);
    var best: ?group_types.Cell = null;
    var best_norm = current_norm;

    var mask: u8 = 0;
    // Phase assemblages are alternative Jacobian probes within one outer
    // Newton iteration. Enumerate the complete, fixed-size active-set family;
    // do not make this inner work another `max_iterations` loop.
    const mask_cap: u8 = 1 << group_types.fixed_phosphate_mineral_count;
    while (mask < mask_cap) : (mask += 1) {
        group_types.recordProbe(options);
        var coordinates = fixedPhosphateCoordinates(current);
        for (0..group_types.fixed_phosphate_mineral_count) |mineral_index| {
            if (!mineralIsActive(mask, mineral_index))
                coordinates[mineral_index + 1] = 0;
        }
        var candidate = fixedPhosphateCandidate(
            current,
            coordinates,
            site_total,
            phosphorus_total,
            cation_totals,
            density,
        ) catch continue;

        // `solveCell` has already consumed exactly one shared nonlinear slot.
        // Each mask is an alternative line-search probe from that same current
        // state, so it may expose at most one damped Newton update. Returning a
        // multi-update local trajectory here would multiply the user's hard
        // ceiling behind the outer budget.
        var iteration: u16 = 0;
        while (iteration < 1) : (iteration += 1) {
            group_types.recordProbe(options);
            var residual: [group_types.fixed_phosphate_coordinate_count]f64 = undefined;
            const dimension = try fixedPhosphateActiveSetResidual(
                candidate,
                evaluator,
                calculate,
                mask,
                &residual,
            );
            const reduced_norm = activeSetResidualNorm(
                candidate,
                residual,
                dimension,
                mask,
                options,
            );
            if (reduced_norm <= 1) break;

            var matrix: [
                group_types.fixed_phosphate_coordinate_count *
                    group_types.fixed_phosphate_coordinate_count
            ]f64 = @splat(0);
            var coordinate_slots: [group_types.fixed_phosphate_coordinate_count]usize =
                undefined;
            coordinate_slots[0] = 0;
            var slot_count: usize = 1;
            for (0..group_types.fixed_phosphate_mineral_count) |mineral_index| {
                if (mineralIsActive(mask, mineral_index)) {
                    coordinate_slots[slot_count] = mineral_index + 1;
                    slot_count += 1;
                }
            }
            std.debug.assert(slot_count == dimension);

            var usable = true;
            for (0..dimension) |column| {
                const coordinate_index = coordinate_slots[column];
                const coordinate_scale = @max(
                    @abs(coordinates[coordinate_index]),
                    options.absolute_tolerance_mol_per_m3,
                );
                var step = std.math.cbrt(std.math.floatEps(f64)) *
                    coordinate_scale;
                var probe_residual: [group_types.fixed_phosphate_coordinate_count]f64 =
                    undefined;
                var selected_step: f64 = 0;
                var search: u16 = 0;
                while (search < 12) : (search += 1) {
                    group_types.recordProbe(options);
                    const signed_step =
                        if (search % 2 == 0) step else -step;
                    var probe_coordinates = coordinates;
                    probe_coordinates[coordinate_index] += signed_step;
                    const probe = fixedPhosphateCandidate(
                        current,
                        probe_coordinates,
                        site_total,
                        phosphorus_total,
                        cation_totals,
                        density,
                    ) catch {
                        if (search % 2 == 1) step *= 2;
                        continue;
                    };
                    _ = fixedPhosphateActiveSetResidual(
                        probe,
                        evaluator,
                        calculate,
                        mask,
                        &probe_residual,
                    ) catch {
                        if (search % 2 == 1) step *= 2;
                        continue;
                    };
                    if (group_numerics.residualProbeIsInformative(
                        residual[0..dimension],
                        probe_residual[0..dimension],
                    )) {
                        selected_step = signed_step;
                        break;
                    }
                    if (search % 2 == 1) step *= 2;
                }
                if (selected_step == 0) {
                    usable = false;
                    break;
                }
                for (0..dimension) |row| {
                    const scale = activeSetResidualScale(
                        candidate,
                        row,
                        mask,
                        options,
                    );
                    matrix[row * dimension + column] =
                        (probe_residual[row] - residual[row]) /
                        selected_step * coordinate_scale / scale;
                }
            }
            if (!usable) break;

            var right_hand_side: [group_types.fixed_phosphate_coordinate_count]f64 = @splat(0);
            for (0..dimension) |row|
                right_hand_side[row] = -residual[row] /
                    activeSetResidualScale(candidate, row, mask, options);
            var solved_matrix = matrix;
            var delta = right_hand_side;
            if (!numerics.solveDenseLinearSystem(
                solved_matrix[0 .. dimension * dimension],
                delta[0..dimension],
                dimension,
            )) {
                var normal_matrix: [
                    group_types.fixed_phosphate_coordinate_count *
                        group_types.fixed_phosphate_coordinate_count
                ]f64 = @splat(0);
                var normal_right_hand_side: [group_types.fixed_phosphate_coordinate_count]f64 = @splat(0);
                if (!group_numerics.solveDampedLeastSquares(
                    matrix[0 .. dimension * dimension],
                    right_hand_side[0..dimension],
                    delta[0..dimension],
                    normal_matrix[0 .. dimension * dimension],
                    normal_right_hand_side[0..dimension],
                    dimension,
                    options,
                )) break;
            }
            for (0..dimension) |column| {
                const coordinate_index = coordinate_slots[column];
                delta[column] *= @max(
                    @abs(coordinates[coordinate_index]),
                    options.absolute_tolerance_mol_per_m3,
                );
            }

            var accepted = false;
            var fraction: f64 = 1;
            var line_search: u8 = 0;
            while (line_search < group_types.probeCap(options, 40)) : (line_search += 1) {
                group_types.recordProbe(options);
                var trial_coordinates = coordinates;
                for (0..dimension) |column|
                    trial_coordinates[coordinate_slots[column]] +=
                        fraction * delta[column];
                const trial = fixedPhosphateCandidate(
                    current,
                    trial_coordinates,
                    site_total,
                    phosphorus_total,
                    cation_totals,
                    density,
                ) catch {
                    fraction *= 0.5;
                    continue;
                };
                var trial_residual: [group_types.fixed_phosphate_coordinate_count]f64 = undefined;
                _ = fixedPhosphateActiveSetResidual(
                    trial,
                    evaluator,
                    calculate,
                    mask,
                    &trial_residual,
                ) catch {
                    fraction *= 0.5;
                    continue;
                };
                if (activeSetResidualNorm(
                    trial,
                    trial_residual,
                    dimension,
                    mask,
                    options,
                ) < reduced_norm) {
                    coordinates = trial_coordinates;
                    candidate = trial;
                    accepted = true;
                    break;
                }
                fraction *= 0.5;
            }
            if (!accepted) break;
        }

        if (!try fixedPhosphateActiveSetIsAdmissible(
            candidate,
            evaluator,
            calculate,
            mask,
            options,
        )) continue;
        const changes = group_struct_arithmetic.changesAt(candidate, environment, evaluator) catch
            continue;
        const complete_norm = try group_struct_arithmetic.scaledNorm(candidate, changes, options);
        if (group_numerics.meaningfullyImproves(best_norm, complete_norm)) {
            best = candidate;
            best_norm = complete_norm;
        }
    }
    return best;
}

fn mineralIsActive(mask: u8, mineral_index: usize) bool {
    return mask & (@as(u8, 1) << @intCast(mineral_index)) != 0;
}

pub fn conservativeFixedPhosphateComplementarityNewton(
    current: group_types.Cell,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
) !?group_types.Cell {
    const calculate =
        evaluator.phosphate_mineral_equilibrium_residuals orelse return null;
    const density = environment.litter_mass_per_water_volume_megagrams_per_m3;
    const site_total = group_phosphate_exchange.phosphateSiteTotal(current);
    const phosphorus_total = group_phosphate_exchange.phosphateTotal(current, density);
    const cation_totals = group_phosphate_exchange.phosphateCationTotals(current);
    const coordinates = fixedPhosphateCoordinates(current);
    var base_residual: [group_types.fixed_phosphate_coordinate_count]f64 = undefined;
    try fixedPhosphateComplementarityResidual(
        current,
        evaluator,
        calculate,
        &base_residual,
    );
    const base_reduced_norm =
        fixedPhosphateResidualNorm(current, base_residual, options);
    if (base_reduced_norm <= 1) return null;

    const coordinate_scales = [_]f64{
        @max(
            current.hpo4_mol_p_per_m3,
            current.h2po4_mol_p_per_m3,
            options.absolute_tolerance_mol_per_m3,
        ),
        @max(
            cation_totals.aluminum_mol_per_m3,
            options.absolute_tolerance_mol_per_m3,
        ),
        @max(
            cation_totals.iron_mol_per_m3,
            options.absolute_tolerance_mol_per_m3,
        ),
        @max(
            cation_totals.calcium_mol_per_m3,
            options.absolute_tolerance_mol_per_m3,
        ),
        @max(
            cation_totals.calcium_mol_per_m3 / 5,
            options.absolute_tolerance_mol_per_m3,
        ),
        @max(
            cation_totals.calcium_mol_per_m3,
            options.absolute_tolerance_mol_per_m3,
        ),
    };
    var matrix: [
        group_types.fixed_phosphate_coordinate_count *
            group_types.fixed_phosphate_coordinate_count
    ]f64 = undefined;
    for (0..group_types.fixed_phosphate_coordinate_count) |column| {
        var magnitude = std.math.cbrt(std.math.floatEps(f64)) *
            coordinate_scales[column];
        var selected_step: f64 = 0;
        var probe_residual: [group_types.fixed_phosphate_coordinate_count]f64 = undefined;
        var search: u16 = 0;
        while (search < 12) : (search += 1) {
            group_types.recordProbe(options);
            const step = if (search % 2 == 0) magnitude else -magnitude;
            var probe_coordinates = coordinates;
            probe_coordinates[column] += step;
            if (fixedPhosphateCandidate(
                current,
                probe_coordinates,
                site_total,
                phosphorus_total,
                cation_totals,
                density,
            )) |probe| {
                if (fixedPhosphateComplementarityResidual(
                    probe,
                    evaluator,
                    calculate,
                    &probe_residual,
                )) |_| {
                    if (group_numerics.residualProbeIsInformative(
                        &base_residual,
                        &probe_residual,
                    )) {
                        selected_step = step;
                        break;
                    }
                } else |_| {}
            } else |_| {}
            if (search % 2 == 1) magnitude *= 2;
        }
        if (selected_step == 0) return null;
        for (0..group_types.fixed_phosphate_coordinate_count) |row| {
            const residual_scale =
                fixedPhosphateResidualScale(current, row, options);
            matrix[row * group_types.fixed_phosphate_coordinate_count + column] =
                (probe_residual[row] - base_residual[row]) /
                selected_step * coordinate_scales[column] /
                residual_scale;
        }
    }
    var right_hand_side: [group_types.fixed_phosphate_coordinate_count]f64 = undefined;
    for (0..group_types.fixed_phosphate_coordinate_count) |row|
        right_hand_side[row] = -base_residual[row] /
            fixedPhosphateResidualScale(current, row, options);
    var solved_matrix = matrix;
    var delta = right_hand_side;
    if (!numerics.solveDenseLinearSystem(
        &solved_matrix,
        &delta,
        group_types.fixed_phosphate_coordinate_count,
    )) {
        var normal_matrix: [
            group_types.fixed_phosphate_coordinate_count *
                group_types.fixed_phosphate_coordinate_count
        ]f64 = undefined;
        var normal_right_hand_side: [group_types.fixed_phosphate_coordinate_count]f64 = undefined;
        if (!group_numerics.solveDampedLeastSquares(
            &matrix,
            &right_hand_side,
            &delta,
            &normal_matrix,
            &normal_right_hand_side,
            group_types.fixed_phosphate_coordinate_count,
            options,
        )) return null;
    }
    for (0..group_types.fixed_phosphate_coordinate_count) |coordinate|
        delta[coordinate] *= coordinate_scales[coordinate];

    var fraction: f64 = 1;
    var line_search: u8 = 0;
    while (line_search < group_types.probeCap(options, 53)) : (line_search += 1) {
        group_types.recordProbe(options);
        var candidate_coordinates = coordinates;
        for (0..group_types.fixed_phosphate_coordinate_count) |coordinate|
            candidate_coordinates[coordinate] +=
                fraction * delta[coordinate];
        if (fixedPhosphateCandidate(
            current,
            candidate_coordinates,
            site_total,
            phosphorus_total,
            cation_totals,
            density,
        )) |candidate| {
            var candidate_residual: [group_types.fixed_phosphate_coordinate_count]f64 =
                undefined;
            if (fixedPhosphateComplementarityResidual(
                candidate,
                evaluator,
                calculate,
                &candidate_residual,
            )) |_| {
                const candidate_reduced_norm = fixedPhosphateResidualNorm(
                    candidate,
                    candidate_residual,
                    options,
                );
                const candidate_changes =
                    group_struct_arithmetic.changesAt(candidate, environment, evaluator) catch {
                        fraction *= 0.5;
                        continue;
                    };
                const candidate_norm =
                    try group_struct_arithmetic.scaledNorm(candidate, candidate_changes, options);
                if (group_numerics.meaningfullyImproves(
                    base_reduced_norm,
                    candidate_reduced_norm,
                ) and group_numerics.meaningfullyImproves(
                    current_norm,
                    candidate_norm,
                ))
                    return candidate;
            } else |_| {}
        } else |_| {}
        fraction *= 0.5;
    }
    return null;
}

fn fixedPhosphateCoordinates(
    cell: group_types.Cell,
) [group_types.fixed_phosphate_coordinate_count]f64 {
    const mineral = cell.phosphate_minerals;
    return .{
        cell.hpo4_mol_p_per_m3,
        mineral.aluminum_phosphate_mol_per_m3,
        mineral.iron_phosphate_mol_per_m3,
        mineral.dicalcium_phosphate_mol_per_m3,
        mineral.hydroxyapatite_mol_per_m3,
        mineral.monocalcium_phosphate_mol_per_m3,
    };
}

fn fixedPhosphateCandidate(
    current: group_types.Cell,
    coordinates: [group_types.fixed_phosphate_coordinate_count]f64,
    site_total: f64,
    phosphorus_total: f64,
    cation_totals: group_phosphate_exchange.PhosphateCationTotals,
    density: f64,
) !group_types.Cell {
    var candidate = current;
    candidate.hpo4_mol_p_per_m3 = coordinates[0];
    candidate.phosphate_minerals = .{
        .aluminum_phosphate_mol_per_m3 = coordinates[1],
        .iron_phosphate_mol_per_m3 = coordinates[2],
        .dicalcium_phosphate_mol_per_m3 = coordinates[3],
        .hydroxyapatite_mol_per_m3 = coordinates[4],
        .monocalcium_phosphate_mol_per_m3 = coordinates[5],
    };
    try group_phosphate_exchange.closePhosphateConservation(
        &candidate,
        site_total,
        phosphorus_total,
        cation_totals,
        density,
    );
    return candidate;
}

fn fixedPhosphateActiveSetResidual(
    cell: group_types.Cell,
    evaluator: group_fixtures.Evaluator,
    calculate: *const fn (
        context: *const anyopaque,
        cell: group_types.Cell,
    ) anyerror!ledger.PhosphateMineralExtents,
    mask: u8,
    residual: *[group_types.fixed_phosphate_coordinate_count]f64,
) !usize {
    const extents = try evaluator.evaluate(evaluator.context, cell);
    _ = calculate;
    residual[0] = extents.h2po4_association_mol_p_per_m3;
    var row: usize = 1;
    for (0..group_types.fixed_phosphate_mineral_count) |mineral_index| {
        if (mineralIsActive(mask, mineral_index)) {
            residual[row] = group_phosphate_minerals.phosphateMineralExtent(
                extents.phosphate_minerals,
                @enumFromInt(mineral_index),
            );
            row += 1;
        }
    }
    return row;
}

fn activeSetResidualScale(
    cell: group_types.Cell,
    row: usize,
    mask: u8,
    options: group_types.Options,
) f64 {
    if (row == 0)
        return options.scaleMolPerM3(cell.hpo4_mol_p_per_m3);
    var active_row: usize = 1;
    for (0..group_types.fixed_phosphate_mineral_count) |mineral_index| {
        if (!mineralIsActive(mask, mineral_index)) continue;
        if (active_row == row) {
            const inventory = group_phosphate_minerals.phosphateMineralInventory(
                cell,
                @enumFromInt(mineral_index),
            );
            return options.scaleMolPerM3(inventory);
        }
        active_row += 1;
    }
    unreachable;
}

fn activeSetResidualNorm(
    cell: group_types.Cell,
    residual: [group_types.fixed_phosphate_coordinate_count]f64,
    dimension: usize,
    mask: u8,
    options: group_types.Options,
) f64 {
    var maximum: f64 = 0;
    for (0..dimension) |row|
        maximum = @max(
            maximum,
            @abs(residual[row]) /
                activeSetResidualScale(cell, row, mask, options),
        );
    return maximum;
}

fn fixedPhosphateActiveSetIsAdmissible(
    cell: group_types.Cell,
    evaluator: group_fixtures.Evaluator,
    calculate: *const fn (
        context: *const anyopaque,
        cell: group_types.Cell,
    ) anyerror!ledger.PhosphateMineralExtents,
    mask: u8,
    options: group_types.Options,
) !bool {
    var residual: [group_types.fixed_phosphate_coordinate_count]f64 = undefined;
    const dimension = try fixedPhosphateActiveSetResidual(
        cell,
        evaluator,
        calculate,
        mask,
        &residual,
    );
    if (activeSetResidualNorm(
        cell,
        residual,
        dimension,
        mask,
        options,
    ) > 1) return false;

    const saturation = try calculate(evaluator.context, cell);
    for (0..group_types.fixed_phosphate_mineral_count) |mineral_index| {
        const reaction: group_phosphate_minerals.PhosphateMineralReaction =
            @enumFromInt(mineral_index);
        const inventory = group_phosphate_minerals.phosphateMineralInventory(cell, reaction);
        const scale = options.scaleMolPerM3(inventory);
        if (mineralIsActive(mask, mineral_index)) {
            if (inventory <= 0) return false;
        } else {
            if (inventory != 0) return false;
            // A missing solid is admissible only when it has no positive
            // precipitation drive. Negative values denote undersaturation.
            if (group_phosphate_minerals.phosphateMineralExtent(saturation, reaction) > scale)
                return false;
        }
    }
    return true;
}

fn fixedPhosphateComplementarityResidual(
    cell: group_types.Cell,
    evaluator: group_fixtures.Evaluator,
    calculate: *const fn (
        context: *const anyopaque,
        cell: group_types.Cell,
    ) anyerror!ledger.PhosphateMineralExtents,
    residual: *[group_types.fixed_phosphate_coordinate_count]f64,
) !void {
    const extents = try evaluator.evaluate(evaluator.context, cell);
    const saturation = try calculate(evaluator.context, cell);
    const mineral = cell.phosphate_minerals;
    residual.* = .{
        extents.h2po4_association_mol_p_per_m3,
        fischerBurmeister(
            mineral.aluminum_phosphate_mol_per_m3,
            -saturation.aluminum_phosphate_mol_per_m3,
        ),
        fischerBurmeister(
            mineral.iron_phosphate_mol_per_m3,
            -saturation.iron_phosphate_mol_per_m3,
        ),
        fischerBurmeister(
            mineral.dicalcium_phosphate_mol_per_m3,
            -saturation.dicalcium_phosphate_mol_per_m3,
        ),
        fischerBurmeister(
            mineral.hydroxyapatite_mol_per_m3,
            -saturation.hydroxyapatite_mol_per_m3,
        ),
        fischerBurmeister(
            mineral.monocalcium_phosphate_mol_per_m3,
            -saturation.monocalcium_phosphate_mol_per_m3,
        ),
    };
}

fn fischerBurmeister(nonnegative_left: f64, nonnegative_right: f64) f64 {
    return std.math.hypot(nonnegative_left, nonnegative_right) -
        nonnegative_left - nonnegative_right;
}

fn fixedPhosphateResidualNorm(
    cell: group_types.Cell,
    residual: [group_types.fixed_phosphate_coordinate_count]f64,
    options: group_types.Options,
) f64 {
    var maximum: f64 = 0;
    for (residual, 0..) |value, row|
        maximum = @max(
            maximum,
            @abs(value) /
                fixedPhosphateResidualScale(cell, row, options),
        );
    return maximum;
}

fn fixedPhosphateResidualScale(
    cell: group_types.Cell,
    row: usize,
    options: group_types.Options,
) f64 {
    const coordinates = fixedPhosphateCoordinates(cell);
    return options.scaleMolPerM3(coordinates[row]);
}

pub fn resolveIncompatibleFixedPhosphateSolids(
    current: group_types.Cell,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
) !?group_types.Cell {
    const calculate =
        evaluator.phosphate_mineral_equilibrium_residuals orelse return null;
    const residuals = try calculate(evaluator.context, current);
    const aluminum_solid =
        current.phosphate_minerals.aluminum_phosphate_mol_per_m3;
    const iron_solid =
        current.phosphate_minerals.iron_phosphate_mol_per_m3;
    const scale = options.scaleMolPerM3(@max(@abs(aluminum_solid), @abs(iron_solid)));
    if (aluminum_solid <= scale or iron_solid <= scale) return null;

    if (residuals.aluminum_phosphate_mol_per_m3 < -scale and
        residuals.iron_phosphate_mol_per_m3 > scale)
        return fixedPhosphateBoundaryCandidate(
            current,
            environment,
            evaluator,
            options,
            current_norm,
            .aluminum,
        );
    if (residuals.iron_phosphate_mol_per_m3 < -scale and
        residuals.aluminum_phosphate_mol_per_m3 > scale)
        return fixedPhosphateBoundaryCandidate(
            current,
            environment,
            evaluator,
            options,
            current_norm,
            .iron,
        );
    return null;
}

fn fixedPhosphateBoundaryCandidate(
    current: group_types.Cell,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
    exhausted: group_types.IncompatiblePhosphateSolid,
) !?group_types.Cell {
    const calculate =
        evaluator.phosphate_mineral_equilibrium_residuals orelse return null;
    var base = current;
    const released = switch (exhausted) {
        .aluminum => current.phosphate_minerals
            .aluminum_phosphate_mol_per_m3,
        .iron => current.phosphate_minerals.iron_phosphate_mol_per_m3,
    };
    switch (exhausted) {
        .aluminum => {
            base.phosphate_minerals.aluminum_phosphate_mol_per_m3 = 0;
            base.aluminum_mol_per_m3 += released;
        },
        .iron => {
            base.phosphate_minerals.iron_phosphate_mol_per_m3 = 0;
            base.iron_mol_per_m3 += released;
        },
    }
    base.h2po4_mol_p_per_m3 += released;
    try group_struct_arithmetic.validateCell(base);

    const active_residual = struct {
        fn value(
            which: group_types.IncompatiblePhosphateSolid,
            residual: ledger.PhosphateMineralExtents,
        ) f64 {
            return switch (which) {
                .aluminum => residual.iron_phosphate_mol_per_m3,
                .iron => residual.aluminum_phosphate_mol_per_m3,
            };
        }
    }.value;
    const lower_residual = active_residual(
        exhausted,
        try calculate(evaluator.context, base),
    );
    if (lower_residual <= 0) return null;
    const active_aqueous = switch (exhausted) {
        .aluminum => base.iron_mol_per_m3,
        .iron => base.aluminum_mol_per_m3,
    };
    const residual_scale = options.scaleMolPerM3(@max(
        @abs(released),
        @abs(active_aqueous),
        @abs(base.h2po4_mol_p_per_m3),
    ));
    var upper = @min(base.h2po4_mol_p_per_m3, active_aqueous);
    upper *= 1 - 64 * std.math.floatEps(f64);
    if (upper <= 0) return null;
    var upper_candidate =
        try applyCompetingFixedPhosphateExtent(base, exhausted, upper);
    const upper_residual = active_residual(
        exhausted,
        try calculate(evaluator.context, upper_candidate),
    );
    if (upper_residual > 0) return null;

    var lower: f64 = 0;
    var candidate = base;
    var iteration: u16 = 0;
    while (iteration < options.max_iterations) : (iteration += 1) {
        group_types.recordProbe(options);
        const middle = lower + 0.5 * (upper - lower);
        const middle_candidate =
            try applyCompetingFixedPhosphateExtent(base, exhausted, middle);
        const middle_residual = active_residual(
            exhausted,
            try calculate(evaluator.context, middle_candidate),
        );
        candidate = middle_candidate;
        if (@abs(middle_residual) <= residual_scale)
            break;
        if (middle_residual > 0) {
            lower = middle;
        } else {
            upper = middle;
            upper_candidate = middle_candidate;
        }
        if (upper - lower <= std.math.floatEps(f64) *
            @max(@abs(upper), options.absolute_tolerance_mol_per_m3))
        {
            candidate = upper_candidate;
            break;
        }
    }
    const candidate_residuals = try calculate(evaluator.context, candidate);
    const exhausted_residual = switch (exhausted) {
        .aluminum => candidate_residuals
            .aluminum_phosphate_mol_per_m3,
        .iron => candidate_residuals.iron_phosphate_mol_per_m3,
    };
    const remaining_residual = active_residual(
        exhausted,
        candidate_residuals,
    );
    if (exhausted_residual > residual_scale or
        @abs(remaining_residual) > residual_scale)
        return null;
    const candidate_changes =
        try group_struct_arithmetic.changesAt(candidate, environment, evaluator);
    const candidate_norm =
        try group_struct_arithmetic.scaledNorm(candidate, candidate_changes, options);
    return if (candidate_norm <= 10 * current_norm) candidate else null;
}

fn applyCompetingFixedPhosphateExtent(
    base: group_types.Cell,
    exhausted: group_types.IncompatiblePhosphateSolid,
    extent: f64,
) !group_types.Cell {
    var candidate = base;
    switch (exhausted) {
        .aluminum => {
            candidate.phosphate_minerals.iron_phosphate_mol_per_m3 +=
                extent;
            candidate.iron_mol_per_m3 -= extent;
        },
        .iron => {
            candidate.phosphate_minerals.aluminum_phosphate_mol_per_m3 +=
                extent;
            candidate.aluminum_mol_per_m3 -= extent;
        },
    }
    candidate.h2po4_mol_p_per_m3 -= extent;
    try group_struct_arithmetic.validateCell(candidate);
    return candidate;
}

pub fn accelerateFixedPhosphateCationBounds(
    current: group_types.Cell,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
) !?group_types.Cell {
    const extents = try evaluator.evaluate(evaluator.context, current);
    const equilibrium_residuals_callback =
        evaluator.phosphate_mineral_equilibrium_residuals orelse return null;
    const equilibrium_residuals =
        try equilibrium_residuals_callback(evaluator.context, current);
    const aluminum_extent =
        extents.phosphate_minerals.aluminum_phosphate_mol_per_m3;
    const iron_extent =
        extents.phosphate_minerals.iron_phosphate_mol_per_m3;
    var candidate = current;
    var total_phosphate_consumption: f64 = 0;
    var accelerated = false;

    inline for (.{
        .{
            "aluminum_mol_per_m3",
            "aluminum_phosphate_mol_per_m3",
            aluminum_extent,
            equilibrium_residuals.aluminum_phosphate_mol_per_m3,
        },
        .{
            "iron_mol_per_m3",
            "iron_phosphate_mol_per_m3",
            iron_extent,
            equilibrium_residuals.iron_phosphate_mol_per_m3,
        },
    }) |entry| {
        const dissolved = @field(current, entry[0]);
        const solid = @field(current.phosphate_minerals, entry[1]);
        const extent = entry[2];
        const saturation_residual = entry[3];
        const extent_scale = options.scaleMolPerM3(solid);
        if (dissolved > 0 and extent > extent_scale and
            saturation_residual > 0)
        {
            const rate_fraction = extent / dissolved;
            if (std.math.isFinite(rate_fraction) and rate_fraction > 0 and
                rate_fraction <= 1)
            {
                const target_dissolved =
                    @min(dissolved, 0.5 * extent_scale / rate_fraction);
                const consumed = dissolved - target_dissolved;
                if (consumed > 0) {
                    @field(candidate, entry[0]) = target_dissolved;
                    @field(candidate.phosphate_minerals, entry[1]) =
                        solid + consumed;
                    total_phosphate_consumption += consumed;
                    accelerated = true;
                }
            }
        }
    }
    if (!accelerated or
        total_phosphate_consumption > candidate.h2po4_mol_p_per_m3)
        return null;
    candidate.h2po4_mol_p_per_m3 -= total_phosphate_consumption;
    try group_struct_arithmetic.validateCell(candidate);
    const candidate_changes = try group_struct_arithmetic.changesAt(candidate, environment, evaluator);
    const candidate_norm = try group_struct_arithmetic.scaledNorm(candidate, candidate_changes, options);
    // Moving directly to a reactant bound can expose the phosphate
    // association residual that the next coupled Newton step must remove.
    // Permit that bounded active-set transition only when it resolves the
    // controlling Al/Fe rate and keeps the full merit within one decade.
    const candidate_aluminum_scaled = group_phosphate_minerals.scaledPhosphateMineralResidual(
        candidate_changes.phosphate_minerals,
        candidate,
        options,
        .aluminum_phosphate,
    );
    const candidate_iron_scaled = group_phosphate_minerals.scaledPhosphateMineralResidual(
        candidate_changes.phosphate_minerals,
        candidate,
        options,
        .iron_phosphate,
    );
    return if ((candidate_aluminum_scaled <= 1 and
        candidate_iron_scaled <= 1) and
        candidate_norm <= 10 * current_norm)
        candidate
    else
        null;
}

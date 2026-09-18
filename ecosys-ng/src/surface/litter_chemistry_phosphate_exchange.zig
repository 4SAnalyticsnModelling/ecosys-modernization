//! `litter_chemistry` declarations: phosphate exchange.
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
const group_phosphate_minerals = @import("litter_chemistry_phosphate_minerals.zig");
const group_struct_arithmetic = @import("litter_chemistry_struct_arithmetic.zig");
const group_types = @import("litter_chemistry_types.zig");

/// Semismooth Newton step for the fixed-pH active set exposed by dry,
/// high-density litter: phosphate association, simultaneous AlPO4
/// dissolution/FePO4 precipitation, and competitive cation exchange. The
/// remaining phosphate minerals stay at their current complementarity bounds.
/// Every coordinate is reconstructed from elemental, phosphate-site, and
/// exchange-charge invariants before its residual is evaluated.
fn reducedActivePhosphateExchangeNewton(
    current: group_types.Cell,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
) !?group_types.Cell {
    const equilibrate_exchange =
        evaluator.equilibrate_cation_exchange orelse return null;
    _ = evaluator.phosphate_mineral_equilibrium_residuals orelse return null;
    const density = environment.litter_mass_per_water_volume_megagrams_per_m3;
    const extents = try evaluator.evaluate(evaluator.context, current);
    const mineral_scale = options.scaleMolPerM3(@max(
        @abs(current.hpo4_mol_p_per_m3),
        @abs(current.h2po4_mol_p_per_m3),
        @abs(current.phosphate_minerals.aluminum_phosphate_mol_per_m3),
        @abs(current.phosphate_minerals.iron_phosphate_mol_per_m3),
        @abs(current.phosphate_minerals.dicalcium_phosphate_mol_per_m3),
        @abs(current.phosphate_minerals.hydroxyapatite_mol_per_m3),
        @abs(current.phosphate_minerals.monocalcium_phosphate_mol_per_m3),
        density * @abs(current.exchange.calcium_mol_per_megagram),
    ));
    if (extents.phosphate_minerals.aluminum_phosphate_mol_per_m3 >=
        -mineral_scale or
        extents.phosphate_minerals.iron_phosphate_mol_per_m3 <=
            mineral_scale or
        @abs(extents.exchange.calcium_mol_per_megagram) <=
            mineral_scale / density or
        @abs(extents.phosphate_minerals.dicalcium_phosphate_mol_per_m3) >
            mineral_scale or
        @abs(extents.phosphate_minerals.hydroxyapatite_mol_per_m3) >
            mineral_scale or
        @abs(extents.phosphate_minerals.monocalcium_phosphate_mol_per_m3) >
            mineral_scale)
        return null;

    const exchange_target =
        try equilibrate_exchange(evaluator.context, current);
    const site_total = phosphateSiteTotal(current);
    const phosphorus_total = phosphateTotal(current, density);
    const coordinates = [_]f64{
        current.hpo4_mol_p_per_m3,
        current.phosphate_minerals.aluminum_phosphate_mol_per_m3,
        current.phosphate_minerals.iron_phosphate_mol_per_m3,
        0.5,
    };
    const coordinate_scales = [_]f64{
        @max(
            current.hpo4_mol_p_per_m3,
            current.h2po4_mol_p_per_m3,
            options.absolute_tolerance_mol_per_m3,
        ),
        @max(
            current.phosphate_minerals.aluminum_phosphate_mol_per_m3,
            current.aluminum_mol_per_m3,
            options.absolute_tolerance_mol_per_m3,
        ),
        @max(
            current.phosphate_minerals.iron_phosphate_mol_per_m3,
            current.iron_mol_per_m3,
            options.absolute_tolerance_mol_per_m3,
        ),
        1,
    };
    const base_state = try reducedActiveCandidate(
        current,
        exchange_target,
        coordinates,
        site_total,
        phosphorus_total,
        density,
    );
    var base_residual: [group_types.reduced_active_coordinate_count]f64 = undefined;
    try reducedActiveResidual(
        base_state,
        evaluator,
        density,
        &base_residual,
    );
    var matrix: [
        group_types.reduced_active_coordinate_count *
            group_types.reduced_active_coordinate_count
    ]f64 = undefined;
    var probe_coordinates = coordinates;
    for (0..group_types.reduced_active_coordinate_count) |column| {
        const step = std.math.cbrt(std.math.floatEps(f64)) *
            coordinate_scales[column];
        var found_probe = false;
        var signed_step = step;
        var search: u8 = 0;
        while (search < group_types.probeCap(options, 24)) : (search += 1) {
            group_types.recordProbe(options);
            probe_coordinates = coordinates;
            probe_coordinates[column] += signed_step;
            if (reducedActiveCandidate(
                current,
                exchange_target,
                probe_coordinates,
                site_total,
                phosphorus_total,
                density,
            )) |probe| {
                var probe_residual: [group_types.reduced_active_coordinate_count]f64 =
                    undefined;
                if (reducedActiveResidual(
                    probe,
                    evaluator,
                    density,
                    &probe_residual,
                )) |_| {
                    for (0..group_types.reduced_active_coordinate_count) |row| {
                        matrix[row * group_types.reduced_active_coordinate_count + column] =
                            (probe_residual[row] - base_residual[row]) /
                            signed_step * coordinate_scales[column] /
                            reducedActiveResidualScale(
                                current,
                                row,
                                density,
                                options,
                            );
                    }
                    found_probe = true;
                    break;
                } else |_| {}
            } else |_| {}
            signed_step = if (signed_step > 0)
                -signed_step
            else
                -2 * signed_step;
        }
        if (!found_probe) return null;
    }
    var right_hand_side: [group_types.reduced_active_coordinate_count]f64 = undefined;
    for (0..group_types.reduced_active_coordinate_count) |row|
        right_hand_side[row] = -base_residual[row] /
            reducedActiveResidualScale(current, row, density, options);
    var solved_matrix = matrix;
    var delta = right_hand_side;
    if (!numerics.solveDenseLinearSystem(
        &solved_matrix,
        &delta,
        group_types.reduced_active_coordinate_count,
    )) {
        var normal_matrix: [
            group_types.reduced_active_coordinate_count *
                group_types.reduced_active_coordinate_count
        ]f64 = undefined;
        var normal_right_hand_side: [group_types.reduced_active_coordinate_count]f64 = undefined;
        if (!group_numerics.solveDampedLeastSquares(
            &matrix,
            &right_hand_side,
            &delta,
            &normal_matrix,
            &normal_right_hand_side,
            group_types.reduced_active_coordinate_count,
            options,
        )) {
            return null;
        }
    }
    for (0..group_types.reduced_active_coordinate_count) |coordinate|
        delta[coordinate] *= coordinate_scales[coordinate];

    var fraction: f64 = 1;
    var line_search: u8 = 0;
    while (line_search < group_types.probeCap(options, 53)) : (line_search += 1) {
        group_types.recordProbe(options);
        var candidate_coordinates = coordinates;
        for (0..group_types.reduced_active_coordinate_count) |coordinate|
            candidate_coordinates[coordinate] +=
                fraction * delta[coordinate];
        // Progress toward the exact Gapon target is a bounded homotopy
        // coordinate, never an extrapolation beyond either physical state.
        if (candidate_coordinates[3] >= 0 and
            candidate_coordinates[3] <= 1)
        {
            if (reducedActiveCandidate(
                current,
                exchange_target,
                candidate_coordinates,
                site_total,
                phosphorus_total,
                density,
            )) |candidate| {
                const candidate_changes =
                    group_struct_arithmetic.changesAt(candidate, environment, evaluator) catch {
                        fraction *= 0.5;
                        continue;
                    };
                const candidate_norm =
                    try group_struct_arithmetic.scaledNorm(candidate, candidate_changes, options);
                if (group_numerics.meaningfullyImproves(current_norm, candidate_norm))
                    return candidate;
            } else |_| {}
        }
        fraction *= 0.5;
    }
    return null;
}

fn reducedActiveCandidate(
    current: group_types.Cell,
    exchange_target: group_types.Cell,
    coordinates: [group_types.reduced_active_coordinate_count]f64,
    site_total: f64,
    phosphorus_total: f64,
    density: f64,
) !group_types.Cell {
    var candidate = try group_struct_arithmetic.interpolateCell(
        current,
        exchange_target,
        coordinates[3],
    );
    const cation_totals = phosphateCationTotals(candidate);
    candidate.hpo4_mol_p_per_m3 = coordinates[0];
    candidate.phosphate_minerals.aluminum_phosphate_mol_per_m3 =
        coordinates[1];
    candidate.phosphate_minerals.iron_phosphate_mol_per_m3 =
        coordinates[2];
    try closePhosphateConservation(
        &candidate,
        site_total,
        phosphorus_total,
        cation_totals,
        density,
    );
    return candidate;
}

fn reducedActiveResidual(
    cell: group_types.Cell,
    evaluator: group_fixtures.Evaluator,
    density: f64,
    residual: *[group_types.reduced_active_coordinate_count]f64,
) !void {
    const extents = try evaluator.evaluate(evaluator.context, cell);
    residual.* = .{
        extents.h2po4_association_mol_p_per_m3,
        extents.phosphate_minerals.aluminum_phosphate_mol_per_m3,
        extents.phosphate_minerals.iron_phosphate_mol_per_m3,
        density * extents.exchange.calcium_mol_per_megagram,
    };
}

fn reducedActiveResidualScale(
    cell: group_types.Cell,
    row: usize,
    density: f64,
    options: group_types.Options,
) f64 {
    const inventory = switch (row) {
        0 => @min(
            cell.hpo4_mol_p_per_m3,
            cell.h2po4_mol_p_per_m3,
        ),
        1 => @min(
            cell.aluminum_mol_per_m3,
            cell.phosphate_minerals.aluminum_phosphate_mol_per_m3,
        ),
        2 => @min(
            cell.iron_mol_per_m3,
            cell.phosphate_minerals.iron_phosphate_mol_per_m3,
        ),
        3 => @min(
            cell.calcium_mol_per_m3,
            density * cell.exchange.calcium_mol_per_megagram,
        ),
        else => unreachable,
    };
    return options.scaleMolPerM3(inventory);
}

pub fn conservativePhosphateNewton(
    allocator: std.mem.Allocator,
    current: group_types.Cell,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
) !?group_types.Cell {
    const matrix = try allocator.alloc(f64, group_types.phosphate_coordinate_count * group_types.phosphate_coordinate_count);
    defer allocator.free(matrix);
    const right_hand_side = try allocator.alloc(f64, group_types.phosphate_coordinate_count);
    defer allocator.free(right_hand_side);
    const base_residual = try allocator.alloc(f64, group_types.phosphate_coordinate_count);
    defer allocator.free(base_residual);
    const probe_residual = try allocator.alloc(f64, group_types.phosphate_coordinate_count);
    defer allocator.free(probe_residual);
    const delta = try allocator.alloc(f64, group_types.phosphate_coordinate_count);
    defer allocator.free(delta);
    const normal_matrix = try allocator.alloc(
        f64,
        group_types.phosphate_coordinate_count * group_types.phosphate_coordinate_count,
    );
    defer allocator.free(normal_matrix);
    const normal_right_hand_side =
        try allocator.alloc(f64, group_types.phosphate_coordinate_count);
    defer allocator.free(normal_right_hand_side);

    const site_total = phosphateSiteTotal(current);
    const phosphorus_total = phosphateTotal(current, environment.litter_mass_per_water_volume_megagrams_per_m3);
    const density = environment.litter_mass_per_water_volume_megagrams_per_m3;
    const coupled_totals = coupledPhosphateExchangeTotals(current, density);
    const base_changes = try group_struct_arithmetic.changesAt(current, environment, evaluator);
    const frozen_exchange_coordinates =
        frozenExchangeCoordinates(current, base_changes, options);
    const base_exchange_target = if (evaluator.equilibrate_cation_exchange) |equilibrate|
        try equilibrate(evaluator.context, current)
    else
        null;
    packCoupledPhosphateResidual(
        current,
        current,
        base_changes,
        base_exchange_target,
        frozen_exchange_coordinates,
        base_residual,
    );
    try group_phosphate_minerals.replacePhosphateMineralResiduals(
        evaluator,
        current,
        base_residual,
    );
    const base_coupled_norm =
        group_struct_arithmetic.scaledCoordinateResidualNorm(current, base_residual, options);
    for (0..group_types.phosphate_coordinate_count) |column| {
        if (frozen_exchange_coordinates[column]) {
            for (0..group_types.phosphate_coordinate_count) |row|
                matrix[row * group_types.phosphate_coordinate_count + column] = 0;
            matrix[column * group_types.phosphate_coordinate_count + column] = 1;
            continue;
        }
        const coordinate_value = phosphateCoordinate(current, column);
        const variable_scale = @max(
            @abs(coordinate_value),
            phosphateCoordinateScale(options, column, 0),
        );
        const step = std.math.cbrt(std.math.floatEps(f64)) *
            variable_scale;
        var selected_step: f64 = 0;
        var magnitude = step;
        var search: u8 = 0;
        while (search < group_types.probeCap(options, 40)) : (search += 1) {
            group_types.recordProbe(options);
            const signed_step = if (search % 2 == 0)
                magnitude
            else
                -magnitude;
            var trial = current;
            setPhosphateCoordinate(&trial, column, phosphateCoordinate(current, column) + signed_step);
            if (closeCoupledPhosphateExchangeConservation(
                &trial,
                site_total,
                phosphorus_total,
                coupled_totals,
                density,
            )) |_| {
                if (group_struct_arithmetic.changesAt(trial, environment, evaluator)) |probe_changes| {
                    const probe_exchange_target = if (evaluator.equilibrate_cation_exchange) |equilibrate|
                        try equilibrate(evaluator.context, trial)
                    else
                        null;
                    packCoupledPhosphateResidual(
                        current,
                        trial,
                        probe_changes,
                        probe_exchange_target,
                        frozen_exchange_coordinates,
                        probe_residual,
                    );
                    try group_phosphate_minerals.replacePhosphateMineralResiduals(
                        evaluator,
                        trial,
                        probe_residual,
                    );
                    if (group_numerics.residualProbeIsInformative(
                        base_residual,
                        probe_residual,
                    )) {
                        selected_step = signed_step;
                        break;
                    }
                } else |_| {}
            } else |_| {}
            if (search % 2 == 1) magnitude *= 2;
        }
        if (selected_step == 0) return null;
        for (0..group_types.phosphate_coordinate_count) |row| {
            const row_value = phosphateCoordinate(current, row);
            const scale = phosphateCoordinateScale(options, row, row_value);
            matrix[row * group_types.phosphate_coordinate_count + column] =
                (probe_residual[row] - base_residual[row]) /
                selected_step * variable_scale / scale;
        }
    }
    for (0..group_types.phosphate_coordinate_count) |row| {
        const row_value = phosphateCoordinate(current, row);
        const scale = phosphateCoordinateScale(options, row, row_value);
        right_hand_side[row] = -base_residual[row] / scale;
    }
    @memcpy(normal_matrix, matrix);
    @memcpy(delta, right_hand_side);
    const direct_solution = numerics.solveDenseLinearSystem(
        normal_matrix,
        delta,
        group_types.phosphate_coordinate_count,
    );
    if (!direct_solution and !group_numerics.solveDampedLeastSquares(
        matrix,
        right_hand_side,
        delta,
        normal_matrix,
        normal_right_hand_side,
        group_types.phosphate_coordinate_count,
        options,
    )) return null;
    for (0..group_types.phosphate_coordinate_count) |coordinate|
        delta[coordinate] *= @max(
            @abs(phosphateCoordinate(current, coordinate)),
            phosphateCoordinateScale(options, coordinate, 0),
        );

    var line_fraction: f64 = 1;
    var line_search: u8 = 0;
    while (line_search < group_types.probeCap(options, 24)) : (line_search += 1) {
        group_types.recordProbe(options);
        var candidate = current;
        for (0..group_types.phosphate_coordinate_count) |coordinate|
            setPhosphateCoordinate(&candidate, coordinate, phosphateCoordinate(current, coordinate) + line_fraction * delta[coordinate]);
        if (closeCoupledPhosphateExchangeConservation(
            &candidate,
            site_total,
            phosphorus_total,
            coupled_totals,
            density,
        )) |_| {
            const candidate_changes = group_struct_arithmetic.changesAt(
                candidate,
                environment,
                evaluator,
            ) catch {
                line_fraction *= 0.5;
                continue;
            };
            const candidate_norm = try group_struct_arithmetic.scaledNorm(candidate, candidate_changes, options);
            const candidate_exchange_target = if (evaluator.equilibrate_cation_exchange) |equilibrate|
                try equilibrate(evaluator.context, candidate)
            else
                null;
            packCoupledPhosphateResidual(
                current,
                candidate,
                candidate_changes,
                candidate_exchange_target,
                frozen_exchange_coordinates,
                probe_residual,
            );
            try group_phosphate_minerals.replacePhosphateMineralResiduals(
                evaluator,
                candidate,
                probe_residual,
            );
            const candidate_coupled_norm =
                group_struct_arithmetic.scaledCoordinateResidualNorm(current, probe_residual, options);
            // The full-cell infinity norm can be controlled by a capped
            // reaction outside this conservative coordinate block. Accept
            // a strict decrease of the coupled block while preventing a
            // material increase of that global merit; subsequent hybrid
            // iterations then resolve the remaining reaction.
            if (group_numerics.meaningfullyImproves(current_norm, candidate_norm) or
                (group_numerics.meaningfullyImproves(
                    base_coupled_norm,
                    candidate_coupled_norm,
                ) and
                    candidate_norm <= current_norm * (1 + 1e-10)))
                return candidate;
        } else |_| {}
        line_fraction *= 0.5;
    }
    return null;
}

pub fn phosphateSiteTotal(cell: group_types.Cell) f64 {
    const p = cell.phosphate_surface;
    return p.deprotonated_site_mol_per_megagram + p.hydroxyl_site_mol_per_megagram +
        p.protonated_site_mol_per_megagram + p.adsorbed_hpo4_mol_p_per_megagram +
        p.adsorbed_h2po4_mol_p_per_megagram;
}

pub fn phosphateTotal(cell: group_types.Cell, density: f64) f64 {
    const p = cell.phosphate_minerals;
    return cell.hpo4_mol_p_per_m3 + cell.h2po4_mol_p_per_m3 +
        density * (cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram +
            cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram) +
        p.aluminum_phosphate_mol_per_m3 + p.iron_phosphate_mol_per_m3 +
        p.dicalcium_phosphate_mol_per_m3 + 3 * p.hydroxyapatite_mol_per_m3 +
        2 * p.monocalcium_phosphate_mol_per_m3;
}

pub const PhosphateCationTotals = struct {
    aluminum_mol_per_m3: f64,
    iron_mol_per_m3: f64,
    calcium_mol_per_m3: f64,
};

pub fn phosphateCationTotals(cell: group_types.Cell) PhosphateCationTotals {
    const minerals = cell.phosphate_minerals;
    return .{
        .aluminum_mol_per_m3 = cell.aluminum_mol_per_m3 +
            minerals.aluminum_phosphate_mol_per_m3,
        .iron_mol_per_m3 = cell.iron_mol_per_m3 +
            minerals.iron_phosphate_mol_per_m3,
        .calcium_mol_per_m3 = cell.calcium_mol_per_m3 +
            minerals.dicalcium_phosphate_mol_per_m3 +
            5 * minerals.hydroxyapatite_mol_per_m3 +
            minerals.monocalcium_phosphate_mol_per_m3,
    };
}

pub fn closePhosphateConservation(
    cell: *group_types.Cell,
    site_total: f64,
    phosphorus_total: f64,
    cation_totals: PhosphateCationTotals,
    density: f64,
) !void {
    const surface = &cell.phosphate_surface;
    surface.adsorbed_h2po4_mol_p_per_megagram = site_total -
        surface.deprotonated_site_mol_per_megagram -
        surface.hydroxyl_site_mol_per_megagram -
        surface.protonated_site_mol_per_megagram -
        surface.adsorbed_hpo4_mol_p_per_megagram;
    const minerals = cell.phosphate_minerals;
    cell.h2po4_mol_p_per_m3 = phosphorus_total -
        cell.hpo4_mol_p_per_m3 -
        density * (surface.adsorbed_hpo4_mol_p_per_megagram + surface.adsorbed_h2po4_mol_p_per_megagram) -
        minerals.aluminum_phosphate_mol_per_m3 -
        minerals.iron_phosphate_mol_per_m3 -
        minerals.dicalcium_phosphate_mol_per_m3 -
        3 * minerals.hydroxyapatite_mol_per_m3 -
        2 * minerals.monocalcium_phosphate_mol_per_m3;
    cell.aluminum_mol_per_m3 = cation_totals.aluminum_mol_per_m3 -
        minerals.aluminum_phosphate_mol_per_m3;
    cell.iron_mol_per_m3 = cation_totals.iron_mol_per_m3 -
        minerals.iron_phosphate_mol_per_m3;
    cell.calcium_mol_per_m3 = cation_totals.calcium_mol_per_m3 -
        minerals.dicalcium_phosphate_mol_per_m3 -
        5 * minerals.hydroxyapatite_mol_per_m3 -
        minerals.monocalcium_phosphate_mol_per_m3;
    try group_struct_arithmetic.validateCell(cell.*);
}

pub const CoupledPhosphateExchangeTotals = struct {
    ammoniacal_nitrogen_mol_per_m3: f64,
    aluminum_mol_per_m3: f64,
    iron_mol_per_m3: f64,
    calcium_mol_per_m3: f64,
    magnesium_mol_per_m3: f64,
    sodium_mol_per_m3: f64,
    potassium_mol_per_m3: f64,
    exchange_charge_mol_per_megagram: f64,
};

pub fn coupledPhosphateExchangeTotals(
    cell: group_types.Cell,
    density: f64,
) CoupledPhosphateExchangeTotals {
    const minerals = cell.phosphate_minerals;
    const exchange = cell.exchange;
    return .{
        .ammoniacal_nitrogen_mol_per_m3 = cell.ammonia_mol_per_m3 + cell.ammonium_mol_per_m3 +
            density * exchange.ammonium_mol_per_megagram,
        .aluminum_mol_per_m3 = cell.aluminum_mol_per_m3 +
            minerals.aluminum_phosphate_mol_per_m3 +
            density * exchange.aluminum_mol_per_megagram,
        .iron_mol_per_m3 = cell.iron_mol_per_m3 +
            minerals.iron_phosphate_mol_per_m3 +
            density * exchange.iron_mol_per_megagram,
        .calcium_mol_per_m3 = cell.calcium_mol_per_m3 +
            minerals.dicalcium_phosphate_mol_per_m3 +
            5 * minerals.hydroxyapatite_mol_per_m3 +
            minerals.monocalcium_phosphate_mol_per_m3 +
            density * exchange.calcium_mol_per_megagram,
        .magnesium_mol_per_m3 = cell.magnesium_mol_per_m3 +
            density * exchange.magnesium_mol_per_megagram,
        .sodium_mol_per_m3 = cell.sodium_mol_per_m3 +
            density * exchange.sodium_mol_per_megagram,
        .potassium_mol_per_m3 = cell.potassium_mol_per_m3 +
            density * exchange.potassium_mol_per_megagram,
        .exchange_charge_mol_per_megagram = exchange.ammonium_mol_per_megagram +
            exchange.hydrogen_mol_per_megagram +
            3 * exchange.aluminum_mol_per_megagram +
            3 * exchange.iron_mol_per_megagram +
            2 * exchange.calcium_mol_per_megagram +
            2 * exchange.magnesium_mol_per_megagram +
            exchange.sodium_mol_per_megagram +
            exchange.potassium_mol_per_megagram,
    };
}

pub fn closeCoupledPhosphateExchangeConservation(
    cell: *group_types.Cell,
    site_total: f64,
    phosphorus_total: f64,
    totals: CoupledPhosphateExchangeTotals,
    density: f64,
) !void {
    try closePhosphateConservation(
        cell,
        site_total,
        phosphorus_total,
        phosphateCationTotals(cell.*),
        density,
    );
    const exchange = &cell.exchange;
    exchange.calcium_mol_per_megagram =
        0.5 * (totals.exchange_charge_mol_per_megagram -
            exchange.ammonium_mol_per_megagram -
            exchange.hydrogen_mol_per_megagram -
            3 * exchange.aluminum_mol_per_megagram -
            3 * exchange.iron_mol_per_megagram -
            2 * exchange.magnesium_mol_per_megagram -
            exchange.sodium_mol_per_megagram -
            exchange.potassium_mol_per_megagram);

    const minerals = cell.phosphate_minerals;
    cell.ammonium_mol_per_m3 =
        totals.ammoniacal_nitrogen_mol_per_m3 -
        cell.ammonia_mol_per_m3 -
        density * exchange.ammonium_mol_per_megagram;
    cell.aluminum_mol_per_m3 = totals.aluminum_mol_per_m3 -
        minerals.aluminum_phosphate_mol_per_m3 -
        density * exchange.aluminum_mol_per_megagram;
    cell.iron_mol_per_m3 = totals.iron_mol_per_m3 -
        minerals.iron_phosphate_mol_per_m3 -
        density * exchange.iron_mol_per_megagram;
    cell.calcium_mol_per_m3 = totals.calcium_mol_per_m3 -
        minerals.dicalcium_phosphate_mol_per_m3 -
        5 * minerals.hydroxyapatite_mol_per_m3 -
        minerals.monocalcium_phosphate_mol_per_m3 -
        density * exchange.calcium_mol_per_megagram;
    cell.magnesium_mol_per_m3 = totals.magnesium_mol_per_m3 -
        density * exchange.magnesium_mol_per_megagram;
    cell.sodium_mol_per_m3 = totals.sodium_mol_per_m3 -
        density * exchange.sodium_mol_per_megagram;
    cell.potassium_mol_per_m3 = totals.potassium_mol_per_m3 -
        density * exchange.potassium_mol_per_megagram;
    try group_struct_arithmetic.validateCell(cell.*);
}

pub fn phosphateCoordinate(cell: group_types.Cell, index: usize) f64 {
    return switch (index) {
        0 => cell.hpo4_mol_p_per_m3,
        1 => cell.phosphate_surface.deprotonated_site_mol_per_megagram,
        2 => cell.phosphate_surface.hydroxyl_site_mol_per_megagram,
        3 => cell.phosphate_surface.protonated_site_mol_per_megagram,
        4 => cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram,
        5 => cell.phosphate_minerals.aluminum_phosphate_mol_per_m3,
        6 => cell.phosphate_minerals.iron_phosphate_mol_per_m3,
        7 => cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3,
        8 => cell.phosphate_minerals.hydroxyapatite_mol_per_m3,
        9 => cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3,
        10 => cell.exchange.ammonium_mol_per_megagram,
        11 => cell.exchange.hydrogen_mol_per_megagram,
        12 => cell.exchange.aluminum_mol_per_megagram,
        13 => cell.exchange.iron_mol_per_megagram,
        14 => cell.exchange.magnesium_mol_per_megagram,
        15 => cell.exchange.sodium_mol_per_megagram,
        16 => cell.exchange.potassium_mol_per_megagram,
        17 => cell.ammonia_mol_per_m3,
        else => unreachable,
    };
}

pub fn phosphateCoordinateScale(options: group_types.Options, index: usize, value: f64) f64 {
    return if ((index >= 1 and index <= 4) or (index >= 10 and index <= 16))
        options.scaleMolPerMegagram(value)
    else
        options.scaleMolPerM3(value);
}

fn setPhosphateCoordinate(cell: *group_types.Cell, index: usize, value: f64) void {
    switch (index) {
        0 => cell.hpo4_mol_p_per_m3 = value,
        1 => cell.phosphate_surface.deprotonated_site_mol_per_megagram = value,
        2 => cell.phosphate_surface.hydroxyl_site_mol_per_megagram = value,
        3 => cell.phosphate_surface.protonated_site_mol_per_megagram = value,
        4 => cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram = value,
        5 => cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 = value,
        6 => cell.phosphate_minerals.iron_phosphate_mol_per_m3 = value,
        7 => cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3 = value,
        8 => cell.phosphate_minerals.hydroxyapatite_mol_per_m3 = value,
        9 => cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3 = value,
        10 => cell.exchange.ammonium_mol_per_megagram = value,
        11 => cell.exchange.hydrogen_mol_per_megagram = value,
        12 => cell.exchange.aluminum_mol_per_megagram = value,
        13 => cell.exchange.iron_mol_per_megagram = value,
        14 => cell.exchange.magnesium_mol_per_megagram = value,
        15 => cell.exchange.sodium_mol_per_megagram = value,
        16 => cell.exchange.potassium_mol_per_megagram = value,
        17 => cell.ammonia_mol_per_m3 = value,
        else => unreachable,
    }
}

fn packCoupledPhosphateResidual(
    reference: group_types.Cell,
    state_value: group_types.Cell,
    changes: group_types.Cell,
    equilibrium_target: ?group_types.Cell,
    frozen_exchange_coordinates: [group_types.phosphate_coordinate_count]bool,
    output: []f64,
) void {
    for (0..group_types.phosphate_coordinate_count) |index| {
        output[index] = if (frozen_exchange_coordinates[index])
            phosphateCoordinate(state_value, index) -
                phosphateCoordinate(reference, index)
        else if (index >= 10 and index <= 16 and equilibrium_target != null)
            phosphateCoordinate(equilibrium_target.?, index) -
                phosphateCoordinate(state_value, index)
        else
            phosphateCoordinate(changes, index);
    }
}

fn frozenExchangeCoordinates(
    state_value: group_types.Cell,
    changes: group_types.Cell,
    options: group_types.Options,
) [group_types.phosphate_coordinate_count]bool {
    var result = [_]bool{false} ** group_types.phosphate_coordinate_count;
    for (10..17) |index| {
        const scale = phosphateCoordinateScale(
            options,
            index,
            phosphateCoordinate(state_value, index),
        );
        result[index] =
            @abs(phosphateCoordinate(changes, index)) <= scale;
    }
    // NH3/NH4 association has its own exact conservative scalar solve.
    // Leaving NH3 in the rank-deficient phosphate normal equations lets its
    // much larger concentration scale dominate the mineral direction.
    result[17] = true;
    return result;
}

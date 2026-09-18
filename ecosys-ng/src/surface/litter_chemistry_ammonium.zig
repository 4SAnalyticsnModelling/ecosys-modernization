//! `litter_chemistry` declarations: ammonium.
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
const group_struct_arithmetic = @import("litter_chemistry_struct_arithmetic.zig");
const group_types = @import("litter_chemistry_types.zig");

/// One conservative, damped Newton update for the coupled NH4/NH3/exchange
/// coordinates. This is deliberately an update, not a nested root solve: the
/// owner accounts the accepted update against its single `max_iterations`
/// budget and retains Anderson as the only solve-level fallback.
pub fn conservativeAmmoniumAssociationSolve(
    current: group_types.Cell,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
) !?group_types.Cell {
    const base_extents = try evaluator.evaluate(evaluator.context, current);
    const aqueous_scale = @min(
        options.scaleMolPerM3(current.ammonium_mol_per_m3),
        options.scaleMolPerM3(current.ammonia_mol_per_m3),
    );
    const exchange_scale = options.scaleMolPerMegagram(
        current.exchange.ammonium_mol_per_megagram,
    );
    if (@abs(base_extents.ammonium_association_mol_per_m3) <= aqueous_scale and
        @abs(base_extents.exchange.ammonium_mol_per_megagram) <= exchange_scale)
        return null;
    const density = environment.litter_mass_per_water_volume_megagrams_per_m3;
    const total_nitrogen = current.ammonium_mol_per_m3 +
        current.ammonia_mol_per_m3 +
        density * current.exchange.ammonium_mol_per_megagram;
    if (!std.math.isFinite(total_nitrogen) or total_nitrogen <= 0) return null;

    const coordinate_scales = [2]f64{
        @max(
            options.absolute_tolerance_mol_per_megagram,
            @abs(current.exchange.ammonium_mol_per_megagram),
            total_nitrogen / density,
        ),
        @max(
            options.absolute_tolerance_mol_per_m3,
            @abs(current.ammonium_mol_per_m3),
            @abs(current.ammonia_mol_per_m3),
        ),
    };
    const coordinates = [2]f64{
        current.exchange.ammonium_mol_per_megagram,
        current.ammonium_mol_per_m3,
    };
    // When exchange already closes, solve the remaining association equation
    // as its actual scalar Newton coordinate. Avoiding a rank-deficient 2x2
    // normal equation preserves the exact one-update solution of a linear
    // NH4/NH3 association law.
    if (@abs(base_extents.exchange.ammonium_mol_per_megagram) <= exchange_scale) {
        const step = std.math.sqrt(std.math.cbrt(std.math.floatEps(f64))) *
            coordinate_scales[1];
        const probe = ammoniumCandidate(
            current,
            total_nitrogen,
            density,
            coordinates[0],
            coordinates[1] + step,
        ) catch return null;
        group_types.recordProbe(options);
        const probe_extent =
            (try evaluator.evaluate(evaluator.context, probe))
                .ammonium_association_mol_per_m3;
        const derivative =
            (probe_extent - base_extents.ammonium_association_mol_per_m3) / step;
        if (!std.math.isFinite(derivative) or
            @abs(derivative) <= std.math.floatEps(f64))
            return null;
        const direction =
            -base_extents.ammonium_association_mol_per_m3 / derivative;
        var fraction: f64 = 1;
        var line_search: u8 = 0;
        while (line_search < 12) : (line_search += 1) {
            group_types.recordProbe(options);
            const candidate = ammoniumCandidate(
                current,
                total_nitrogen,
                density,
                coordinates[0],
                coordinates[1] + fraction * direction,
            ) catch {
                fraction *= 0.5;
                continue;
            };
            const changes = try group_struct_arithmetic.changesAt(
                candidate,
                environment,
                evaluator,
            );
            const norm = try group_struct_arithmetic.scaledNorm(candidate, changes, options);
            if (group_numerics.meaningfullyImproves(current_norm, norm))
                return candidate;
            fraction *= 0.5;
        }
        return null;
    }
    const base_residual = [2]f64{
        base_extents.exchange.ammonium_mol_per_megagram / exchange_scale,
        base_extents.ammonium_association_mol_per_m3 / aqueous_scale,
    };
    var jacobian: [4]f64 = undefined;
    inline for (0..2) |column| {
        var step = std.math.cbrt(std.math.floatEps(f64)) * coordinate_scales[column];
        var probe_coordinates = coordinates;
        probe_coordinates[column] += step;
        const probe = ammoniumCandidate(
            current,
            total_nitrogen,
            density,
            probe_coordinates[0],
            probe_coordinates[1],
        ) catch fallback: {
            step = -step;
            probe_coordinates = coordinates;
            probe_coordinates[column] += step;
            break :fallback ammoniumCandidate(
                current,
                total_nitrogen,
                density,
                probe_coordinates[0],
                probe_coordinates[1],
            ) catch return null;
        };
        group_types.recordProbe(options);
        const probe_extents = try evaluator.evaluate(evaluator.context, probe);
        const probe_residual = [2]f64{
            probe_extents.exchange.ammonium_mol_per_megagram / exchange_scale,
            probe_extents.ammonium_association_mol_per_m3 / aqueous_scale,
        };
        inline for (0..2) |row|
            jacobian[row * 2 + column] =
                (probe_residual[row] - base_residual[row]) /
                (step / coordinate_scales[column]);
    }
    var right_hand_side = [2]f64{ -base_residual[0], -base_residual[1] };
    var direction: [2]f64 = undefined;
    var normal_matrix: [4]f64 = undefined;
    var normal_right_hand_side: [2]f64 = undefined;
    if (!group_numerics.solveDampedLeastSquares(
        &jacobian,
        &right_hand_side,
        &direction,
        &normal_matrix,
        &normal_right_hand_side,
        2,
        options,
    )) return null;

    var fraction: f64 = 1;
    var line_search: u8 = 0;
    while (line_search < 12) : (line_search += 1) {
        group_types.recordProbe(options);
        const candidate = ammoniumCandidate(
            current,
            total_nitrogen,
            density,
            coordinates[0] + fraction * direction[0] * coordinate_scales[0],
            coordinates[1] + fraction * direction[1] * coordinate_scales[1],
        ) catch {
            fraction *= 0.5;
            continue;
        };
        const changes = try group_struct_arithmetic.changesAt(
            candidate,
            environment,
            evaluator,
        );
        const norm = try group_struct_arithmetic.scaledNorm(candidate, changes, options);
        if (group_numerics.meaningfullyImproves(current_norm, norm))
            return candidate;
        fraction *= 0.5;
    }
    return null;
}

fn ammoniumCandidate(
    reference: group_types.Cell,
    total_nitrogen: f64,
    density: f64,
    exchange_ammonium_mol_per_megagram: f64,
    ammonium_mol_per_m3: f64,
) !group_types.Cell {
    if (!std.math.isFinite(exchange_ammonium_mol_per_megagram) or
        exchange_ammonium_mol_per_megagram < 0 or
        !std.math.isFinite(ammonium_mol_per_m3) or
        ammonium_mol_per_m3 < 0)
        return error.NegativeLitterChemistryState;
    const aqueous_total =
        total_nitrogen - density * exchange_ammonium_mol_per_megagram;
    if (!std.math.isFinite(aqueous_total) or
        ammonium_mol_per_m3 > aqueous_total)
        return error.NegativeLitterChemistryState;
    var candidate = reference;
    candidate.exchange.ammonium_mol_per_megagram =
        exchange_ammonium_mol_per_megagram;
    candidate.ammonium_mol_per_m3 = ammonium_mol_per_m3;
    candidate.ammonia_mol_per_m3 = aqueous_total - ammonium_mol_per_m3;
    try group_struct_arithmetic.validateCell(candidate);
    return candidate;
}

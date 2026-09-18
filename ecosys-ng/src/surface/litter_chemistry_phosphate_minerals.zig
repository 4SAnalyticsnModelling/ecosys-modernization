//! `litter_chemistry` declarations: phosphate minerals.
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
const group_struct_arithmetic = @import("litter_chemistry_struct_arithmetic.zig");
const group_types = @import("litter_chemistry_types.zig");

pub const PhosphateMineralReaction = enum(u8) {
    aluminum_phosphate,
    iron_phosphate,
    dicalcium_phosphate,
    hydroxyapatite,
    monocalcium_phosphate,

    fn controlledByH2po4(self: PhosphateMineralReaction) bool {
        return self != .dicalcium_phosphate;
    }
};

/// One damped active-set Newton update in the two aqueous phosphate
/// coordinates, with the selected mineral as the dependent conservative
/// inventory. The uncapped equilibrium residual supplies the derivative when
/// the kinetic extent is clipped on a plateau. No nested bracket iteration is
/// permitted: the owner accounts this one accepted update against its shared
/// `max_iterations` budget.
pub fn conservativePhosphateActiveReactionSolve(
    current: group_types.Cell,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
    allow_non_improving_target: bool,
) !?group_types.Cell {
    const extents = try evaluator.evaluate(evaluator.context, current);
    const active_mineral = dominantPhosphateMineral(
        extents.phosphate_minerals,
        current,
        options,
    );
    const mineral_extent = phosphateMineralExtent(extents.phosphate_minerals, active_mineral);
    const mineral_scale = options.scaleMolPerM3(phosphateMineralInventory(current, active_mineral));
    if (@abs(mineral_extent) <= mineral_scale) return null;

    const density = environment.litter_mass_per_water_volume_megagrams_per_m3;
    const phosphorus_total = group_phosphate_exchange.phosphateTotal(current, density);
    const aqueous_plus_slack = current.hpo4_mol_p_per_m3 +
        current.h2po4_mol_p_per_m3 +
        phosphatePerMineral(active_mineral) *
            phosphateMineralInventory(current, active_mineral);
    if (!std.math.isFinite(aqueous_plus_slack) or aqueous_plus_slack <= 0) return null;

    _ = allow_non_improving_target;
    const equilibrium = evaluator.phosphate_mineral_equilibrium_residuals orelse
        return null;
    const coordinates = [2]f64{
        current.hpo4_mol_p_per_m3,
        current.h2po4_mol_p_per_m3,
    };
    const coordinate_scales = [2]f64{
        @max(options.absolute_tolerance_mol_per_m3, @abs(coordinates[0]), aqueous_plus_slack),
        @max(options.absolute_tolerance_mol_per_m3, @abs(coordinates[1]), aqueous_plus_slack),
    };
    const association_scale = @min(
        options.scaleMolPerM3(coordinates[0]),
        options.scaleMolPerM3(coordinates[1]),
    );
    const base_equilibrium = try equilibrium(evaluator.context, current);
    const base_residual = [2]f64{
        phosphateMineralExtent(base_equilibrium, active_mineral) / mineral_scale,
        extents.h2po4_association_mol_p_per_m3 / association_scale,
    };
    const association_closed =
        @abs(extents.h2po4_association_mol_p_per_m3) <= association_scale;

    var direction = [2]f64{ 0, 0 };
    if (association_closed) {
        const column: usize = if (active_mineral.controlledByH2po4()) 1 else 0;
        var step = std.math.sqrt(std.math.cbrt(std.math.floatEps(f64))) *
            coordinate_scales[column];
        var probe_coordinates = coordinates;
        probe_coordinates[column] += step;
        const probe = phosphateCandidateFromAqueous(
            current,
            phosphorus_total,
            density,
            active_mineral,
            probe_coordinates[0],
            probe_coordinates[1],
        ) catch fallback: {
            step = -step;
            probe_coordinates = coordinates;
            probe_coordinates[column] += step;
            break :fallback phosphateCandidateFromAqueous(
                current,
                phosphorus_total,
                density,
                active_mineral,
                probe_coordinates[0],
                probe_coordinates[1],
            ) catch return null;
        };
        group_types.recordProbe(options);
        const probe_equilibrium = try equilibrium(evaluator.context, probe);
        const derivative =
            (phosphateMineralExtent(probe_equilibrium, active_mineral) /
                mineral_scale - base_residual[0]) /
            (step / coordinate_scales[column]);
        if (!std.math.isFinite(derivative) or
            @abs(derivative) <= std.math.floatEps(f64))
            return null;
        direction[column] = -base_residual[0] / derivative;
    } else {
        var jacobian: [4]f64 = undefined;
        inline for (0..2) |column| {
            var step = std.math.cbrt(std.math.floatEps(f64)) *
                coordinate_scales[column];
            var probe_coordinates = coordinates;
            probe_coordinates[column] += step;
            const probe = phosphateCandidateFromAqueous(
                current,
                phosphorus_total,
                density,
                active_mineral,
                probe_coordinates[0],
                probe_coordinates[1],
            ) catch fallback: {
                step = -step;
                probe_coordinates = coordinates;
                probe_coordinates[column] += step;
                break :fallback phosphateCandidateFromAqueous(
                    current,
                    phosphorus_total,
                    density,
                    active_mineral,
                    probe_coordinates[0],
                    probe_coordinates[1],
                ) catch return null;
            };
            group_types.recordProbe(options);
            const probe_equilibrium = try equilibrium(evaluator.context, probe);
            const probe_extents = try evaluator.evaluate(evaluator.context, probe);
            const probe_residual = [2]f64{
                phosphateMineralExtent(probe_equilibrium, active_mineral) / mineral_scale,
                probe_extents.h2po4_association_mol_p_per_m3 / association_scale,
            };
            inline for (0..2) |row|
                jacobian[row * 2 + column] =
                    (probe_residual[row] - base_residual[row]) /
                    (step / coordinate_scales[column]);
        }
        var right_hand_side = [2]f64{ -base_residual[0], -base_residual[1] };
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
    }

    var fraction: f64 = 1;
    var line_search: u8 = 0;
    while (line_search < 12) : (line_search += 1) {
        group_types.recordProbe(options);
        const candidate = phosphateCandidateFromAqueous(
            current,
            phosphorus_total,
            density,
            active_mineral,
            coordinates[0] + fraction * direction[0] * coordinate_scales[0],
            coordinates[1] + fraction * direction[1] * coordinate_scales[1],
        ) catch {
            fraction *= 0.5;
            continue;
        };
        const candidate_changes = try group_struct_arithmetic.changesAt(
            candidate,
            environment,
            evaluator,
        );
        const candidate_norm = try group_struct_arithmetic.scaledNorm(
            candidate,
            candidate_changes,
            options,
        );
        if (group_numerics.meaningfullyImproves(current_norm, candidate_norm))
            return candidate;
        fraction *= 0.5;
    }
    return null;
}

fn dominantPhosphateMineral(
    extents: ledger.PhosphateMineralExtents,
    state_value: group_types.Cell,
    options: group_types.Options,
) PhosphateMineralReaction {
    var result: PhosphateMineralReaction = .aluminum_phosphate;
    var magnitude = scaledPhosphateMineralResidual(
        extents,
        state_value,
        options,
        result,
    );
    inline for ([_]PhosphateMineralReaction{
        .iron_phosphate,
        .dicalcium_phosphate,
        .hydroxyapatite,
        .monocalcium_phosphate,
    }) |reaction| {
        const candidate = scaledPhosphateMineralResidual(
            extents,
            state_value,
            options,
            reaction,
        );
        if (candidate > magnitude) {
            result = reaction;
            magnitude = candidate;
        }
    }
    return result;
}

pub fn scaledPhosphateMineralResidual(
    extents: ledger.PhosphateMineralExtents,
    state_value: group_types.Cell,
    options: group_types.Options,
    reaction: PhosphateMineralReaction,
) f64 {
    const inventory = phosphateMineralInventory(state_value, reaction);
    const scale = options.scaleMolPerM3(inventory);
    return @abs(phosphateMineralExtent(extents, reaction)) / scale;
}

pub fn phosphateMineralExtent(extents: ledger.PhosphateMineralExtents, reaction: PhosphateMineralReaction) f64 {
    return switch (reaction) {
        .aluminum_phosphate => extents.aluminum_phosphate_mol_per_m3,
        .iron_phosphate => extents.iron_phosphate_mol_per_m3,
        .dicalcium_phosphate => extents.dicalcium_phosphate_mol_per_m3,
        .hydroxyapatite => extents.hydroxyapatite_mol_per_m3,
        .monocalcium_phosphate => extents.monocalcium_phosphate_mol_per_m3,
    };
}

pub fn phosphateMineralInventory(cell: group_types.Cell, reaction: PhosphateMineralReaction) f64 {
    return phosphateMineralExtent(cell.phosphate_minerals, reaction);
}

fn setPhosphateMineralInventory(cell: *group_types.Cell, reaction: PhosphateMineralReaction, value: f64) void {
    switch (reaction) {
        .aluminum_phosphate => cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 = value,
        .iron_phosphate => cell.phosphate_minerals.iron_phosphate_mol_per_m3 = value,
        .dicalcium_phosphate => cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3 = value,
        .hydroxyapatite => cell.phosphate_minerals.hydroxyapatite_mol_per_m3 = value,
        .monocalcium_phosphate => cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3 = value,
    }
}

fn phosphatePerMineral(reaction: PhosphateMineralReaction) f64 {
    return switch (reaction) {
        .aluminum_phosphate, .iron_phosphate, .dicalcium_phosphate => 1,
        .hydroxyapatite => 3,
        .monocalcium_phosphate => 2,
    };
}

fn phosphateCandidateFromAqueous(
    reference: group_types.Cell,
    phosphorus_total: f64,
    density: f64,
    slack_mineral: PhosphateMineralReaction,
    hpo4_mol_p_per_m3: f64,
    h2po4_mol_p_per_m3: f64,
) !group_types.Cell {
    var candidate = reference;
    candidate.hpo4_mol_p_per_m3 = hpo4_mol_p_per_m3;
    candidate.h2po4_mol_p_per_m3 = h2po4_mol_p_per_m3;
    setPhosphateMineralInventory(&candidate, slack_mineral, 0);
    const without_slack = group_phosphate_exchange.phosphateTotal(candidate, density);
    setPhosphateMineralInventory(
        &candidate,
        slack_mineral,
        (phosphorus_total - without_slack) / phosphatePerMineral(slack_mineral),
    );
    try group_struct_arithmetic.validateCell(candidate);
    return candidate;
}

fn eliminateUndersaturatedPhosphateMinerals(
    initial: group_types.Cell,
    phosphorus_total: f64,
    density: f64,
    slack_mineral: PhosphateMineralReaction,
    evaluator: group_fixtures.Evaluator,
) !group_types.Cell {
    var candidate = initial;
    const extents = (try evaluator.evaluate(evaluator.context, candidate)).phosphate_minerals;
    inline for ([_]PhosphateMineralReaction{
        .aluminum_phosphate,
        .iron_phosphate,
        .dicalcium_phosphate,
        .hydroxyapatite,
        .monocalcium_phosphate,
    }) |reaction| {
        if (reaction != slack_mineral and
            phosphateMineralExtent(extents, reaction) < 0 and
            phosphateMineralInventory(candidate, reaction) > 0)
            setPhosphateMineralInventory(&candidate, reaction, 0);
    }
    const slack_before = phosphateMineralInventory(candidate, slack_mineral);
    setPhosphateMineralInventory(&candidate, slack_mineral, 0);
    const without_slack = group_phosphate_exchange.phosphateTotal(candidate, density);
    const slack_after =
        (phosphorus_total - without_slack) / phosphatePerMineral(slack_mineral);
    // Do not repair a negative conserved inventory by zeroing it: that would
    // create phosphorus equal to the discarded deficit. Reject the active-set
    // elimination and retain the exact conservative input state instead.
    if (!std.math.isFinite(slack_after) or slack_after < 0) {
        setPhosphateMineralInventory(&candidate, slack_mineral, slack_before);
        return initial;
    }
    setPhosphateMineralInventory(&candidate, slack_mineral, slack_after);
    try group_struct_arithmetic.validateCell(candidate);
    return candidate;
}

pub fn replacePhosphateMineralResiduals(
    evaluator: group_fixtures.Evaluator,
    state_value: group_types.Cell,
    residual: []f64,
) !void {
    const calculate = evaluator.phosphate_mineral_equilibrium_residuals orelse
        return;
    const mineral = try calculate(evaluator.context, state_value);
    residual[5] = mineral.aluminum_phosphate_mol_per_m3;
    residual[6] = mineral.iron_phosphate_mol_per_m3;
    residual[7] = mineral.dicalcium_phosphate_mol_per_m3;
    residual[8] = mineral.hydroxyapatite_mol_per_m3;
    residual[9] = mineral.monocalcium_phosphate_mol_per_m3;
}

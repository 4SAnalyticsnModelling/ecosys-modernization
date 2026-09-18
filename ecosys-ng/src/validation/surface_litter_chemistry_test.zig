//! Tests for `litter_chemistry.zig`.
//!
//! Extracted verbatim so the module beside it contains only the model
//! code. Tests that use private declarations of that module stay there,
//! since a sibling file can only reach `pub` declarations.

const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const ledger = @import("../surface/litter_reaction_transformations.zig");
const numerics = @import("../core/numerics.zig");
const std = @import("std");
const surface_litter_chemistry = @import("../surface/litter_chemistry.zig");
test "solid mineral inventory survives wet dry and rewet carrier changes" {
    var state = try surface_litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].salt_minerals.calcite_mol_per_m3 = 2;
    state.cells[0].phosphate_minerals.hydroxyapatite_mol_per_m3 = 3;
    try state.bindMineralReferenceWater(&.{1});

    try state.renormalizeMinerals(0, 0);
    try std.testing.expectEqual(@as(f64, 2), state.cells[0].salt_minerals.calcite_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 1), state.mineral_reference_water_m3[0]);

    try state.renormalizeMinerals(0, 0.25);
    try std.testing.expectEqual(@as(f64, 8), state.cells[0].salt_minerals.calcite_mol_per_m3);
    try std.testing.expectEqual(
        @as(f64, 12),
        state.cells[0].phosphate_minerals.hydroxyapatite_mol_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 2),
        state.cells[0].salt_minerals.calcite_mol_per_m3 * 0.25,
    );
}

fn simultaneousPhosphateSinkEvaluator(
    _: *const anyopaque,
    _: surface_litter_chemistry.Cell,
) !ledger.ReactionExtents {
    var extents = std.mem.zeroes(ledger.ReactionExtents);
    extents.phosphate_minerals.aluminum_phosphate_mol_per_m3 = 0.5;
    extents.phosphate_minerals.iron_phosphate_mol_per_m3 = 0.5;
    extents.phosphate_minerals.dicalcium_phosphate_mol_per_m3 = 0.5;
    return extents;
}

test "fixed-pH simultaneous sinks share one exact admissible substrate fraction" {
    var state = try surface_litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].h2po4_mol_p_per_m3 = 1;
    const context: u8 = 0;
    const result = try surface_litter_chemistry.applyHourlyCell(
        &state,
        0,
        .{
            .litter_mass_per_water_volume_megagrams_per_m3 = 1,
            .dynamic_salts = false,
        },
        .{
            .context = &context,
            .evaluate = simultaneousPhosphateSinkEvaluator,
        },
        .{},
    );
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try std.testing.expectEqual(@as(f64, 0), state.cells[0].h2po4_mol_p_per_m3);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.0 / 3.0),
        state.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.0 / 3.0),
        state.cells[0].phosphate_minerals.iron_phosphate_mol_per_m3,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.0 / 3.0),
        state.cells[0].phosphate_minerals.dicalcium_phosphate_mol_per_m3,
        1e-15,
    );
}

/// Reproduces the Ottawa surface-litter phosphate tail: one capped hourly
/// precipitation rate evaluated against the pre-hour aqueous H2PO4 pool.
const CappedPhosphatePlateauContext = struct {
    /// mol P m-3 per hour; the recorded failure had rates in this range
    /// against inventories of order 10 mol m-3.
    capped_rate: f64,
    target_h2po4_mol_p_per_m3: f64,
};

fn cappedPhosphatePlateauEvaluator(
    raw: *const anyopaque,
    cell: surface_litter_chemistry.Cell,
) !ledger.ReactionExtents {
    const context: *const CappedPhosphatePlateauContext =
        @ptrCast(@alignCast(raw));
    var extents = std.mem.zeroes(ledger.ReactionExtents);
    // Capped to a constant whenever supersaturated.
    if (cell.h2po4_mol_p_per_m3 > context.target_h2po4_mol_p_per_m3)
        extents.phosphate_minerals.aluminum_phosphate_mol_per_m3 =
            context.capped_rate;
    return extents;
}

test "dynamic capped phosphate applies one hourly increment independent of solver ceiling" {
    // SOLUTE.F 3996--5250 contains no MRXN loop in either salt mode and uses
    // undivided hourly rates. A capped rate is one physical increment, not a
    // nonlinear residual that must be driven to zero.
    var one = try surface_litter_chemistry.State.init(std.testing.allocator, 1);
    defer one.deinit();
    var thousand = try surface_litter_chemistry.State.init(std.testing.allocator, 1);
    defer thousand.deinit();
    one.cells[0].h2po4_mol_p_per_m3 = 12;
    one.cells[0].hpo4_mol_p_per_m3 = 2;
    one.cells[0].aluminum_mol_per_m3 = 1;
    one.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3 = 14;
    thousand.cells[0] = one.cells[0];
    const phosphorus_before =
        one.cells[0].h2po4_mol_p_per_m3 +
        one.cells[0].hpo4_mol_p_per_m3 +
        one.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3;
    const context = CappedPhosphatePlateauContext{
        .capped_rate = 2.5e-3,
        .target_h2po4_mol_p_per_m3 = 4,
    };
    const environment = surface_litter_chemistry.Environment{
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = true,
    };
    const evaluator = surface_litter_chemistry.Evaluator{
        .context = &context,
        .evaluate = cappedPhosphatePlateauEvaluator,
    };
    const one_result = try surface_litter_chemistry.applyHourlyCell(
        &one,
        0,
        environment,
        evaluator,
        .{ .max_iterations = 1 },
    );
    const thousand_result = try surface_litter_chemistry.applyHourlyCell(
        &thousand,
        0,
        environment,
        evaluator,
        .{ .max_iterations = 1000 },
    );
    try std.testing.expectEqual(one.cells[0], thousand.cells[0]);
    try std.testing.expectEqual(@as(u16, 1), one_result.iterations);
    try std.testing.expectEqual(@as(u16, 1), thousand_result.iterations);
    try std.testing.expectEqual(@as(u16, 1), one_result.accepted_updates);
    try std.testing.expectEqual(@as(u16, 1), thousand_result.accepted_updates);
    try std.testing.expectEqual(@as(u16, 0), one_result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), one_result.picard_steps);
    try std.testing.expectEqual(@as(u16, 0), one_result.anderson_steps);
    try std.testing.expectApproxEqAbs(
        @as(f64, 12 - 2.5e-3),
        one.cells[0].h2po4_mol_p_per_m3,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 14 + 2.5e-3),
        one.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3,
        1e-15,
    );
    // Phosphorus is conserved across the aqueous/mineral split.
    try std.testing.expectApproxEqAbs(
        phosphorus_before,
        one.cells[0].h2po4_mol_p_per_m3 +
            one.cells[0].hpo4_mol_p_per_m3 +
            one.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3,
        1e-9,
    );
}

test "fixed-pH litter never iterates undivided hourly rates" {
    // SOLUTE.F 3996--5250 has no `DO M=` statement and uses the undivided
    // hourly TPD/TSL constants, so the fixed-pH litter branch must apply one
    // increment even when offered a large ceiling. Guards the MRXN
    // multiplication that iterating this branch would introduce.
    var state = try surface_litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].h2po4_mol_p_per_m3 = 12;
    state.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3 = 14;
    const context = CappedPhosphatePlateauContext{
        .capped_rate = 2.5e-3,
        .target_h2po4_mol_p_per_m3 = 4,
    };
    const result = try surface_litter_chemistry.applyHourlyCell(
        &state,
        0,
        .{
            .litter_mass_per_water_volume_megagrams_per_m3 = 1,
            .dynamic_salts = false,
        },
        .{ .context = &context, .evaluate = cappedPhosphatePlateauEvaluator },
        .{ .max_iterations = 1000 },
    );
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try std.testing.expectEqual(@as(u16, 0), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.picard_steps);
    // Exactly one hourly capped increment moved from aqueous to solid.
    try std.testing.expectApproxEqAbs(
        @as(f64, 12 - 2.5e-3),
        state.cells[0].h2po4_mol_p_per_m3,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 14 + 2.5e-3),
        state.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3,
        1e-15,
    );
}

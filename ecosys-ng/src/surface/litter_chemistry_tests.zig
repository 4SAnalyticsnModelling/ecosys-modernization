//! `litter_chemistry` declarations: tests.
//!
//! Split out of `litter_chemistry.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ledger = @import("litter_reaction_transformations.zig");
const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const numerics = @import("../core/numerics.zig");
const group_fixed_phosphate = @import("litter_chemistry_fixed_phosphate.zig");
const group_fixtures = @import("litter_chemistry_fixtures.zig");
const group_numerics = @import("litter_chemistry_numerics.zig");
const group_phosphate_exchange = @import("litter_chemistry_phosphate_exchange.zig");
const group_solve = @import("litter_chemistry_solve.zig");
const group_struct_arithmetic = @import("litter_chemistry_struct_arithmetic.zig");
const group_types = @import("litter_chemistry_types.zig");

test "trace litter reaction inventories use unit-specific scales without a one-unit floor" {
    var state = std.mem.zeroes(group_types.Cell);
    var changes = std.mem.zeroes(group_types.Cell);
    state.ammonium_mol_per_m3 = 1e-10;
    changes.ammonium_mol_per_m3 = 5e-12;
    const options: group_types.Options = .{
        .absolute_tolerance_mol_per_m3 = 1e-13,
        .absolute_tolerance_mol_per_megagram = 1e-9,
        .relative_tolerance = 1e-8,
    };
    try std.testing.expect(try group_struct_arithmetic.scaledNorm(state, changes, options) > 1);

    changes.ammonium_mol_per_m3 = 0;
    state.exchange.ammonium_mol_per_megagram = 1e-10;
    changes.exchange.ammonium_mol_per_megagram = 5e-12;
    try std.testing.expect(try group_struct_arithmetic.scaledNorm(state, changes, options) < 1);
}

const TerminalProjectionTestContext = struct {
    calls: usize = 0,
    extent_mol_per_m3: f64,
};

fn zeroReactionEvaluator(
    _: *const anyopaque,
    _: group_types.Cell,
) !ledger.ReactionExtents {
    return std.mem.zeroes(ledger.ReactionExtents);
}

fn countedTerminalWaterProjection(
    raw: *const anyopaque,
    cell: group_types.Cell,
) !group_fixtures.WaterEquilibriumProjection {
    const context: *TerminalProjectionTestContext =
        @ptrCast(@alignCast(@constCast(raw)));
    context.calls += 1;
    var projected = cell;
    projected.hydrogen_mol_per_m3 = 0.25;
    projected.hydroxide_mol_per_m3 = 4;
    return .{
        .cell = projected,
        .equal_reaction_extent_mol_per_m3 = context.extent_mol_per_m3,
    };
}

const HourlySourceOrderTestContext = struct {
    evaluations: usize = 0,
    starting_water_projections: usize = 0,
};

fn hourlySourceOrderEvaluator(
    raw: *const anyopaque,
    _: group_types.Cell,
) !ledger.ReactionExtents {
    const context: *HourlySourceOrderTestContext =
        @ptrCast(@alignCast(@constCast(raw)));
    context.evaluations += 1;
    var extents = std.mem.zeroes(ledger.ReactionExtents);
    // The starting-water callback has already completed RHHX. This is the
    // later source-ordered reaction evaluated from that projected state.
    extents.external_hydrogen_mol_per_m3 = 0.25;
    return extents;
}

fn sourceOrderStartingWaterProjection(
    raw: *const anyopaque,
    cell: group_types.Cell,
) !group_fixtures.WaterEquilibriumProjection {
    const context: *HourlySourceOrderTestContext =
        @ptrCast(@alignCast(@constCast(raw)));
    context.starting_water_projections += 1;
    var projected = cell;
    projected.hydrogen_mol_per_m3 -= 0.5;
    projected.hydroxide_mol_per_m3 -= 0.5;
    projected.water_mol_per_m3 += 0.5;
    return .{ .cell = projected, .equal_reaction_extent_mol_per_m3 = 0.5 };
}

fn projectWaterFromZeroHydrogen(
    _: *const anyopaque,
    cell: group_types.Cell,
) !group_fixtures.WaterEquilibriumProjection {
    var projected = cell;
    projected.hydrogen_mol_per_m3 = 1;
    projected.hydroxide_mol_per_m3 = 1;
    projected.water_mol_per_m3 -= 1;
    return .{ .cell = projected, .equal_reaction_extent_mol_per_m3 = -1 };
}

fn consumeProjectedHydrogen(
    _: *const anyopaque,
    _: group_types.Cell,
) !ledger.ReactionExtents {
    var extents = std.mem.zeroes(ledger.ReactionExtents);
    extents.ammonium_association_mol_per_m3 = 0.5;
    return extents;
}

const HydrogenSolverTestMode = enum {
    damped_newton,
    anderson_recovery,
};

const HydrogenSolverTestContext = struct {
    mode: HydrogenSolverTestMode,
    rejected_full_newton_trials: usize = 0,
};

const RepeatedAndersonTestContext = struct {
    coefficient: f64 = 35.48133892335755,
    root_mol_per_m3: f64 = 0.001,
};

/// Isolates the generic conservative solver path without invoking a
/// reaction-specific active-set solve. Positive extent transfers hydrogen from
/// the aqueous pool to litter carboxyl sites, so every trial conserves total H.
fn hydrogenSolverTestEvaluator(
    raw: *const anyopaque,
    cell: group_types.Cell,
) !ledger.ReactionExtents {
    const context: *HydrogenSolverTestContext =
        @ptrCast(@alignCast(@constCast(raw)));
    var extents = std.mem.zeroes(ledger.ReactionExtents);
    extents.carboxyl_hydrogen_adsorption_mol_per_megagram = switch (context.mode) {
        .damped_newton => damped: {
            if (cell.hydrogen_mol_per_m3 == 1) {
                // The undamped secant-Newton endpoint is deliberately
                // non-descent; the half step remains on the linear branch.
                context.rejected_full_newton_trials += 1;
                break :damped 2;
            }
            break :damped cell.hydrogen_mol_per_m3 - 1;
        },
        .anderson_recovery => 8 * cell.hydrogen_mol_per_m3 - 1,
    };
    return extents;
}

/// A convex conservative hydrogen-transfer residual. At the initial state and
/// after its first Anderson update, the directional Newton probe is outside
/// the nonnegative domain. The second Anderson cycle enters the Newton basin.
fn repeatedAndersonTestEvaluator(
    raw: *const anyopaque,
    cell: group_types.Cell,
) !ledger.ReactionExtents {
    const context: *const RepeatedAndersonTestContext =
        @ptrCast(@alignCast(raw));
    var extents = std.mem.zeroes(ledger.ReactionExtents);
    extents.carboxyl_hydrogen_adsorption_mol_per_megagram =
        context.coefficient *
        (cell.hydrogen_mol_per_m3 * cell.hydrogen_mol_per_m3 -
            context.root_mol_per_m3 * context.root_mol_per_m3);
    return extents;
}

test "fixed-pH cation-bound acceleration advances Al and Fe simultaneously" {
    var cell = std.mem.zeroes(group_types.Cell);
    cell.aluminum_mol_per_m3 = 2;
    cell.iron_mol_per_m3 = 3;
    cell.h2po4_mol_p_per_m3 = 10;
    cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 = 4;
    cell.phosphate_minerals.iron_phosphate_mol_per_m3 = 5;
    const context: u8 = 0;
    const evaluator = group_fixtures.Evaluator{
        .context = &context,
        .evaluate = group_fixtures.cationBoundPhosphateEvaluator,
        .phosphate_mineral_equilibrium_residuals = group_fixtures.supersaturatedAluminumAndIronPhosphate,
    };
    const options = group_types.Options{};
    const changes = try group_struct_arithmetic.changesAt(
        cell,
        .{
            .litter_mass_per_water_volume_megagrams_per_m3 = 1,
            .dynamic_salts = false,
        },
        evaluator,
    );
    const norm = try group_struct_arithmetic.scaledNorm(cell, changes, options);
    const candidate = (try group_fixed_phosphate.accelerateFixedPhosphateCationBounds(
        cell,
        .{
            .litter_mass_per_water_volume_megagrams_per_m3 = 1,
            .dynamic_salts = false,
        },
        evaluator,
        options,
        norm,
    )).?;
    try std.testing.expect(candidate.aluminum_mol_per_m3 < cell.aluminum_mol_per_m3);
    try std.testing.expect(candidate.iron_mol_per_m3 < cell.iron_mol_per_m3);
    try std.testing.expectApproxEqAbs(
        cell.aluminum_mol_per_m3 +
            cell.phosphate_minerals.aluminum_phosphate_mol_per_m3,
        candidate.aluminum_mol_per_m3 +
            candidate.phosphate_minerals.aluminum_phosphate_mol_per_m3,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        cell.iron_mol_per_m3 +
            cell.phosphate_minerals.iron_phosphate_mol_per_m3,
        candidate.iron_mol_per_m3 +
            candidate.phosphate_minerals.iron_phosphate_mol_per_m3,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        cell.h2po4_mol_p_per_m3 +
            cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 +
            cell.phosphate_minerals.iron_phosphate_mol_per_m3,
        candidate.h2po4_mol_p_per_m3 +
            candidate.phosphate_minerals.aluminum_phosphate_mol_per_m3 +
            candidate.phosphate_minerals.iron_phosphate_mol_per_m3,
        1e-14,
    );
}

test "runtime litter cell solve converges early and conserves nitrogen" {
    var state = try group_types.State.init(std.testing.allocator, 3);
    defer state.deinit();
    state.cells[2].ammonia_mol_per_m3 = 2;
    const before = state.cells[2].ammonia_mol_per_m3 + state.cells[2].ammonium_mol_per_m3;
    const context = group_fixtures.TestContext{ .rate_fraction = 0.25 };
    const result = try group_solve.solveCell(&state, 2, .{ .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = true }, .{ .context = &context, .evaluate = group_fixtures.testEvaluator }, .{});
    try std.testing.expect(result.iterations < 60);
    try std.testing.expect(result.newton_raphson_steps + result.picard_steps > 0);
    try std.testing.expectEqual(result.picard_steps, result.anderson_steps);
    try std.testing.expect(result.accepted_updates <= 60);
    try std.testing.expectApproxEqAbs(before, state.cells[2].ammonia_mol_per_m3 + state.cells[2].ammonium_mol_per_m3, 1e-12);
    try std.testing.expectApproxEqAbs(state.cells[2].ammonia_mol_per_m3, state.cells[2].ammonium_mol_per_m3, 5e-8);
}

test "terminal litter water projection is committed exactly once" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].hydrogen_mol_per_m3 = 2;
    state.cells[0].hydroxide_mol_per_m3 = 2;
    var context = TerminalProjectionTestContext{ .extent_mol_per_m3 = 0.08 };
    const result = try group_solve.solveCell(
        &state,
        0,
        .{ .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = false },
        .{
            .context = &context,
            .evaluate = zeroReactionEvaluator,
            .project_water_equilibrium = countedTerminalWaterProjection,
        },
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqual(@as(f64, 0.08), result.accepted_water_equilibrium_extent_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.25), state.cells[0].hydrogen_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 4), state.cells[0].hydroxide_mol_per_m3);
    try state.publishAcceptedWaterEquilibriumBalance(
        0,
        result.accepted_water_equilibrium_extent_mol_per_m3,
        0.25,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), state.water_equilibrium_balance_mol[0], 1e-16);
}

test "dynamic hourly litter update is identical at iteration ceilings one and one thousand" {
    var one = try group_types.State.init(std.testing.allocator, 1);
    defer one.deinit();
    var thousand = try group_types.State.init(std.testing.allocator, 1);
    defer thousand.deinit();
    one.cells[0].hydrogen_mol_per_m3 = 2;
    one.cells[0].hydroxide_mol_per_m3 = 1;
    thousand.cells[0] = one.cells[0];
    var one_context = HourlySourceOrderTestContext{};
    var thousand_context = HourlySourceOrderTestContext{};
    const environment = group_types.Environment{
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = true,
    };

    const one_result = try group_solve.applyHourlyCell(
        &one,
        0,
        environment,
        .{ .context = &one_context, .evaluate = hourlySourceOrderEvaluator },
        .{ .max_iterations = 1 },
    );
    const thousand_result = try group_solve.applyHourlyCell(
        &thousand,
        0,
        environment,
        .{ .context = &thousand_context, .evaluate = hourlySourceOrderEvaluator },
        .{ .max_iterations = 1000 },
    );

    try std.testing.expectEqual(one.cells[0], thousand.cells[0]);
    try std.testing.expectEqual(@as(usize, 1), one_context.evaluations);
    try std.testing.expectEqual(@as(usize, 1), thousand_context.evaluations);
    try std.testing.expectEqual(@as(u16, 1), one_result.iterations);
    try std.testing.expectEqual(@as(u16, 1), thousand_result.iterations);
    try std.testing.expectEqual(@as(u16, 1), one_result.accepted_updates);
    try std.testing.expectEqual(@as(u16, 1), thousand_result.accepted_updates);
    try std.testing.expectEqual(@as(u16, 0), one_result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), one_result.picard_steps);
    try std.testing.expectEqual(@as(u16, 0), one_result.anderson_steps);
}

test "hourly litter keeps source-order RHHX and does not project after reactions" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].hydrogen_mol_per_m3 = 2;
    state.cells[0].hydroxide_mol_per_m3 = 1;
    var context = HourlySourceOrderTestContext{};

    const result = try group_solve.applyHourlyCell(
        &state,
        0,
        .{
            .litter_mass_per_water_volume_megagrams_per_m3 = 1,
            .dynamic_salts = true,
        },
        .{
            .context = &context,
            .evaluate = hourlySourceOrderEvaluator,
            .project_starting_water_equilibrium = sourceOrderStartingWaterProjection,
        },
        .{ .max_iterations = 1000 },
    );

    try std.testing.expectEqual(@as(usize, 1), context.evaluations);
    try std.testing.expectEqual(@as(usize, 1), context.starting_water_projections);
    // Initial projection gives H/OH = 1.5/0.5; the later reaction adds H=0.25.
    // A post-reaction projection would replace these deliberately unequal
    // source-order results with the callback's sentinel values.
    try std.testing.expectEqual(@as(f64, 1.75), state.cells[0].hydrogen_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.5), state.cells[0].hydroxide_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.5), state.cells[0].water_mol_per_m3);
    try std.testing.expectEqual(
        @as(f64, 0.5),
        result.accepted_water_equilibrium_extent_mol_per_m3,
    );
}

test "hourly litter projects zero starting hydrogen before later sinks" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].water_mol_per_m3 = 2;
    state.cells[0].ammonia_mol_per_m3 = 1;
    const context: u8 = 0;

    const result = try group_solve.applyHourlyCell(
        &state,
        0,
        .{
            .litter_mass_per_water_volume_megagrams_per_m3 = 1,
            .dynamic_salts = true,
        },
        .{
            .context = &context,
            .evaluate = consumeProjectedHydrogen,
            .project_starting_water_equilibrium = projectWaterFromZeroHydrogen,
        },
        .{},
    );

    try std.testing.expectEqual(@as(f64, 0.5), state.cells[0].hydrogen_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 1), state.cells[0].hydroxide_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 1), state.cells[0].water_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.5), state.cells[0].ammonia_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.5), state.cells[0].ammonium_mol_per_m3);
    try std.testing.expectEqual(
        @as(f64, -1),
        result.accepted_water_equilibrium_extent_mol_per_m3,
    );
}

test "fixed-pH branch state_updates one hourly kinetic increment without MRXN multiplication" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].ammonia_mol_per_m3 = 2;
    const context = group_fixtures.TestContext{ .rate_fraction = 0.25 };
    const result = try group_solve.solveCell(
        &state,
        0,
        .{
            .litter_mass_per_water_volume_megagrams_per_m3 = 1,
            .dynamic_salts = false,
        },
        .{ .context = &context, .evaluate = group_fixtures.testEvaluator },
        .{ .max_iterations = 1000 },
    );
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try std.testing.expectEqual(@as(u16, 0), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.picard_steps);
    try std.testing.expectEqual(@as(u16, 1), result.accepted_updates);
    try std.testing.expectEqual(@as(f64, 1.5), state.cells[0].ammonia_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.5), state.cells[0].ammonium_mol_per_m3);
}

test "generic litter Newton backtracks a non-descent full step without Picard publication" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].hydrogen_mol_per_m3 = 2;
    var context = HydrogenSolverTestContext{ .mode = .damped_newton };
    const result = try group_solve.solveCell(
        &state,
        0,
        .{ .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = true },
        .{ .context = &context, .evaluate = hydrogenSolverTestEvaluator },
        .{
            .absolute_tolerance_mol_per_m3 = 0.01,
            .absolute_tolerance_mol_per_megagram = 0.01,
            .relative_tolerance = 1e-12,
            .max_iterations = 10,
        },
    );

    try std.testing.expect(context.rejected_full_newton_trials > 0);
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expectEqual(@as(u16, 0), result.picard_steps);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    try std.testing.expectEqual(result.newton_raphson_steps, result.accepted_updates);
    try std.testing.expect(result.accepted_updates <= result.iterations);
    try std.testing.expect(result.iterations <= 10);
    try std.testing.expect(state.cells[0].hydrogen_mol_per_m3 > 1);
    try std.testing.expect(state.cells[0].hydrogen_mol_per_m3 < 1.05);
    try std.testing.expectApproxEqAbs(
        @as(f64, 2),
        state.cells[0].hydrogen_mol_per_m3 +
            state.cells[0].carboxyl_hydrogen_mol_per_megagram,
        1e-14,
    );
}

test "litter fallback reserves hard-ceiling slot for Newton retry and never publishes its Picard seed" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].hydrogen_mol_per_m3 = 0.25;
    state.cells[0].carboxyl_hydrogen_mol_per_megagram = 0.75;
    const before = state.cells[0];
    var context = HydrogenSolverTestContext{ .mode = .anderson_recovery };
    const evaluator = group_fixtures.Evaluator{
        .context = &context,
        .evaluate = hydrogenSolverTestEvaluator,
    };
    const environment = group_types.Environment{
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = true,
    };

    // One slot cannot hold both recovery and its mandatory Newton retry.
    try std.testing.expectError(
        error.LitterChemistrySolverDidNotConverge,
        group_solve.solveCell(
            &state,
            0,
            environment,
            evaluator,
            .{ .max_iterations = 1 },
        ),
    );
    try std.testing.expectEqual(before, state.cells[0]);

    // With exactly two slots the sequence is Newton -> one Anderson update ->
    // separately budgeted Newton retry. The bounded-Picard seed is H(aq)=0;
    // only the accelerated H(aq)=0.125 state may be published.
    const result = try group_solve.solveCell(
        &state,
        0,
        environment,
        evaluator,
        .{ .max_iterations = 2 },
    );
    try std.testing.expectEqual(@as(u16, 2), result.iterations);
    try std.testing.expectEqual(@as(u16, 0), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 1), result.picard_steps);
    try std.testing.expectEqual(@as(u16, 1), result.anderson_steps);
    try std.testing.expectEqual(@as(u16, 1), result.accepted_updates);
    try std.testing.expect(result.accepted_updates <= result.iterations);
    try std.testing.expectEqual(@as(f64, 0.125), state.cells[0].hydrogen_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.875), state.cells[0].carboxyl_hydrogen_mol_per_megagram);
}

test "litter recovery may repeat Anderson only after its mandatory Newton retry" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].hydrogen_mol_per_m3 = 0.25;
    state.cells[0].carboxyl_hydrogen_mol_per_megagram = 0.75;
    const total_hydrogen_before = state.cells[0].hydrogen_mol_per_m3 +
        state.cells[0].carboxyl_hydrogen_mol_per_megagram;
    const context = RepeatedAndersonTestContext{};

    const result = try group_solve.solveCell(
        &state,
        0,
        .{
            .litter_mass_per_water_volume_megagrams_per_m3 = 1,
            .dynamic_salts = true,
        },
        .{ .context = &context, .evaluate = repeatedAndersonTestEvaluator },
        .{ .max_iterations = 100 },
    );

    // The first private bounded-Picard seed is H=0.1114032374 mol m-3.
    // A one-shot recovery would stop after the first accelerated state
    // H=0.0770657439; convergence therefore proves that another Anderson
    // update ran only after the separately budgeted Newton retry.
    try std.testing.expect(result.anderson_steps > 1);
    try std.testing.expectEqual(result.anderson_steps, result.picard_steps);
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expect(result.accepted_updates <= result.iterations);
    try std.testing.expect(result.maximum_scaled_residual <= 1);
    try std.testing.expect(result.iterations < 100);
    try std.testing.expectApproxEqAbs(
        context.root_mol_per_m3,
        state.cells[0].hydrogen_mol_per_m3,
        1e-8,
    );
    try std.testing.expectApproxEqAbs(
        total_hydrogen_before,
        state.cells[0].hydrogen_mol_per_m3 +
            state.cells[0].carboxyl_hydrogen_mol_per_megagram,
        1e-14,
    );
    try std.testing.expect(state.cells[0].hydrogen_mol_per_m3 != 0.11140323741431729);
}

test "subnormal extinct-phase noise does not cap an admissible mineral step" {
    var current = std.mem.zeroes(group_types.Cell);
    current.h2po4_mol_p_per_m3 = 10;
    var changes = std.mem.zeroes(group_types.Cell);
    changes.h2po4_mol_p_per_m3 = -0.005;
    changes.phosphate_minerals.dicalcium_phosphate_mol_per_m3 = -3.0e-319;
    changes.phosphate_minerals.hydroxyapatite_mol_per_m3 = -9.0e-319;
    changes.phosphate_minerals.monocalcium_phosphate_mol_per_m3 = -6.0e-319;
    try std.testing.expectApproxEqAbs(
        @as(f64, 2000),
        group_struct_arithmetic.maximumAdmissibleFraction(group_types.Cell, current, changes),
        1e-10,
    );
}

test "saturated kinetic ceilings state_update one hourly increment instead of failing" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].h2po4_mol_p_per_m3 = 1;
    state.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3 = 14.7;
    state.cells[0].phosphate_minerals.iron_phosphate_mol_per_m3 = 14.7;
    state.cells[0].phosphate_minerals.hydroxyapatite_mol_per_m3 = 9.8;
    const context: u8 = 0;
    const phosphorus_before = group_phosphate_exchange.phosphateTotal(state.cells[0], 1);

    // The production ceiling for this path. A ceiling raise is forbidden, so
    // the regression must pass at exactly the ceiling production uses.
    const result = try group_solve.solveCell(
        &state,
        0,
        .{
            .litter_mass_per_water_volume_megagrams_per_m3 = 1,
            .dynamic_salts = false,
        },
        .{
            .context = &context,
            .evaluate = group_fixtures.saturatedCeilingPhosphateEvaluator,
        },
        .{ .max_iterations = 1000 },
    );

    // One bounded hourly increment, exactly as the source branch does. Not
    // 1000 iterations ending in LitterChemistrySolverDidNotConverge.
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try std.testing.expectEqual(@as(u16, 1), result.accepted_updates);
    try std.testing.expectEqual(@as(u16, 0), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.picard_steps);

    // The shared H2PO4 substrate is the binding constraint: 1 mol P feeding
    // sinks that consume 1 + 1 + 1 + 3 = 6 mol P per unit extent admits at
    // most 1/6, and the substrate must not go negative.
    try std.testing.expect(state.cells[0].h2po4_mol_p_per_m3 >= 0);

    // Phosphorus is conserved across the state_updateted transformation.
    try std.testing.expectApproxEqAbs(
        phosphorus_before,
        group_phosphate_exchange.phosphateTotal(state.cells[0], 1),
        1e-12,
    );
}

test "saturated ceiling rates would stall an iterated equilibrium map" {
    // Proves the diagnosis rather than only the fix: with rates pinned at a
    // ceiling the residual is constant, so no iteration count converges. This
    // is why raising the ceiling was the wrong instrument.
    var cell = std.mem.zeroes(group_types.Cell);
    cell.h2po4_mol_p_per_m3 = 1;
    const context: u8 = 0;
    const evaluator = group_fixtures.Evaluator{
        .context = &context,
        .evaluate = group_fixtures.saturatedCeilingPhosphateEvaluator,
    };
    const environment = group_types.Environment{
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = false,
    };
    const options = group_types.Options{};
    const first = try group_struct_arithmetic.changesAt(cell, environment, evaluator);
    const first_norm = try group_struct_arithmetic.scaledNorm(cell, first, options);
    try std.testing.expect(first_norm > 1);

    // Move the state anywhere admissible; the residual is unchanged because a
    // saturated rate does not depend on the state.
    const moved = try group_struct_arithmetic.applyFraction(cell, first, 0.05);
    const second = try group_struct_arithmetic.changesAt(moved, environment, evaluator);
    try std.testing.expectEqual(
        first.phosphate_minerals.hydroxyapatite_mol_per_m3,
        second.phosphate_minerals.hydroxyapatite_mol_per_m3,
    );
    try std.testing.expect(try group_struct_arithmetic.scaledNorm(moved, second, options) > 1);
}

test "convergence reached on the last permitted iteration is state_updateted" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].ammonia_mol_per_m3 = 2;
    const context = group_fixtures.TestContext{ .rate_fraction = 0.25 };
    const result = try group_solve.solveCell(&state, 0, .{ .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = true }, .{ .context = &context, .evaluate = group_fixtures.testEvaluator }, .{ .max_iterations = 1 });
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try std.testing.expectEqual(@as(u16, 1), result.accepted_updates);
    try std.testing.expect(result.maximum_scaled_residual <= 1);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.cells[0].ammonium_mol_per_m3, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.cells[0].ammonia_mol_per_m3, 1e-12);
}

test "phosphate Newton propagates nested cation exchange failure" {
    var cell = std.mem.zeroes(group_types.Cell);
    cell.ammonia_mol_per_m3 = 2;
    const context = group_fixtures.TestContext{ .rate_fraction = 0.25 };
    const evaluator = group_fixtures.Evaluator{
        .context = &context,
        .evaluate = group_fixtures.testEvaluator,
        .equilibrate_cation_exchange = group_fixtures.failingCationExchange,
    };
    try std.testing.expectError(
        error.SyntheticNestedExchangeFailure,
        group_phosphate_exchange.conservativePhosphateNewton(
            std.testing.allocator,
            cell,
            .{
                .litter_mass_per_water_volume_megagrams_per_m3 = 1,
                .dynamic_salts = true,
            },
            evaluator,
            .{},
            2,
        ),
    );
}

test "phosphate Newton coordinates close site phosphorus and cation conservation exactly" {
    var cell = std.mem.zeroes(group_types.Cell);
    cell.hpo4_mol_p_per_m3 = 2;
    cell.h2po4_mol_p_per_m3 = 3;
    cell.phosphate_surface = .{
        .deprotonated_site_mol_per_megagram = 0.1,
        .hydroxyl_site_mol_per_megagram = 0.2,
        .protonated_site_mol_per_megagram = 0.3,
        .adsorbed_hpo4_mol_p_per_megagram = 0.4,
        .adsorbed_h2po4_mol_p_per_megagram = 0.5,
    };
    cell.phosphate_minerals = .{
        .aluminum_phosphate_mol_per_m3 = 0.6,
        .iron_phosphate_mol_per_m3 = 0.7,
        .dicalcium_phosphate_mol_per_m3 = 0.8,
        .hydroxyapatite_mol_per_m3 = 0.9,
        .monocalcium_phosphate_mol_per_m3 = 1,
    };
    cell.aluminum_mol_per_m3 = 2;
    cell.iron_mol_per_m3 = 2;
    cell.calcium_mol_per_m3 = 8;
    const density: f64 = 2;
    const site_total = group_phosphate_exchange.phosphateSiteTotal(cell);
    const phosphorus_total = group_phosphate_exchange.phosphateTotal(cell, density);
    const cation_totals = group_phosphate_exchange.phosphateCationTotals(cell);
    cell.hpo4_mol_p_per_m3 += 0.1;
    cell.phosphate_surface.deprotonated_site_mol_per_megagram += 0.01;
    cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram -= 0.02;
    cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 += 0.03;
    cell.phosphate_minerals.hydroxyapatite_mol_per_m3 -= 0.04;
    try group_phosphate_exchange.closePhosphateConservation(
        &cell,
        site_total,
        phosphorus_total,
        cation_totals,
        density,
    );
    try std.testing.expectApproxEqAbs(site_total, group_phosphate_exchange.phosphateSiteTotal(cell), 1e-15);
    try std.testing.expectApproxEqAbs(phosphorus_total, group_phosphate_exchange.phosphateTotal(cell, density), 1e-14);
    const cations_after = group_phosphate_exchange.phosphateCationTotals(cell);
    try std.testing.expectApproxEqAbs(
        cation_totals.aluminum_mol_per_m3,
        cations_after.aluminum_mol_per_m3,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        cation_totals.iron_mol_per_m3,
        cations_after.iron_mol_per_m3,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        cation_totals.calcium_mol_per_m3,
        cations_after.calcium_mol_per_m3,
        1e-14,
    );
}

test "coupled phosphate exchange coordinates conserve elements and exchange charge" {
    var cell = std.mem.zeroes(group_types.Cell);
    cell.ammonia_mol_per_m3 = 3;
    cell.ammonium_mol_per_m3 = 5;
    cell.hpo4_mol_p_per_m3 = 4;
    cell.h2po4_mol_p_per_m3 = 6;
    cell.aluminum_mol_per_m3 = 7;
    cell.iron_mol_per_m3 = 8;
    cell.calcium_mol_per_m3 = 20;
    cell.magnesium_mol_per_m3 = 9;
    cell.sodium_mol_per_m3 = 10;
    cell.potassium_mol_per_m3 = 11;
    cell.phosphate_surface.deprotonated_site_mol_per_megagram = 0.1;
    cell.phosphate_surface.hydroxyl_site_mol_per_megagram = 0.2;
    cell.phosphate_surface.protonated_site_mol_per_megagram = 0.3;
    cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram = 0.4;
    cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram = 0.5;
    cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 = 0.6;
    cell.phosphate_minerals.iron_phosphate_mol_per_m3 = 0.7;
    cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3 = 0.8;
    cell.phosphate_minerals.hydroxyapatite_mol_per_m3 = 0.9;
    cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3 = 1;
    cell.exchange = .{
        .ammonium_mol_per_megagram = 0.11,
        .hydrogen_mol_per_megagram = 0.12,
        .aluminum_mol_per_megagram = 0.13,
        .iron_mol_per_megagram = 0.14,
        .calcium_mol_per_megagram = 0.15,
        .magnesium_mol_per_megagram = 0.16,
        .sodium_mol_per_megagram = 0.17,
        .potassium_mol_per_megagram = 0.18,
    };
    const density: f64 = 2;
    const site_total = group_phosphate_exchange.phosphateSiteTotal(cell);
    const phosphorus_total = group_phosphate_exchange.phosphateTotal(cell, density);
    const totals = group_phosphate_exchange.coupledPhosphateExchangeTotals(cell, density);

    cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 += 0.2;
    cell.phosphate_minerals.hydroxyapatite_mol_per_m3 -= 0.1;
    cell.exchange.ammonium_mol_per_megagram += 0.01;
    cell.exchange.hydrogen_mol_per_megagram -= 0.02;
    cell.exchange.aluminum_mol_per_megagram += 0.01;
    cell.exchange.magnesium_mol_per_megagram -= 0.03;
    cell.exchange.sodium_mol_per_megagram += 0.02;
    cell.ammonia_mol_per_m3 += 0.25;
    try group_phosphate_exchange.closeCoupledPhosphateExchangeConservation(
        &cell,
        site_total,
        phosphorus_total,
        totals,
        density,
    );

    try std.testing.expectApproxEqAbs(
        phosphorus_total,
        group_phosphate_exchange.phosphateTotal(cell, density),
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        site_total,
        group_phosphate_exchange.phosphateSiteTotal(cell),
        1e-15,
    );
    const after = group_phosphate_exchange.coupledPhosphateExchangeTotals(cell, density);
    inline for (@typeInfo(group_phosphate_exchange.CoupledPhosphateExchangeTotals).@"struct".fields) |field|
        try std.testing.expectApproxEqAbs(
            @field(totals, field.name),
            @field(after, field.name),
            1e-13,
        );
}

test "damped least squares resolves a rank deficient coupled Jacobian" {
    const jacobian = [_]f64{
        1, 1,
        2, 2,
    };
    const right_hand_side = [_]f64{ 2, 4 };
    var solution = [_]f64{ 0, 0 };
    var normal_matrix = [_]f64{ 0, 0, 0, 0 };
    var normal_right_hand_side = [_]f64{ 0, 0 };
    var probes: group_types.ProbeCounts = .{};
    try std.testing.expect(group_numerics.solveDampedLeastSquares(
        &jacobian,
        &right_hand_side,
        &solution,
        &normal_matrix,
        &normal_right_hand_side,
        2,
        .{ .max_iterations = 1, .probe_counts = &probes },
    ));
    try std.testing.expectEqual(@as(u32, 1), probes.iterations);
    try std.testing.expectApproxEqAbs(@as(f64, 1), solution[0], 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, 1), solution[1], 1e-8);
}

test "Marquardt scaling preserves weak coordinates beside stiff chemistry" {
    const jacobian = [_]f64{
        1e12, 0,
        0,    1,
    };
    const right_hand_side = [_]f64{ 1e12, 1 };
    var solution = [_]f64{ 0, 0 };
    var normal_matrix = [_]f64{ 0, 0, 0, 0 };
    var normal_right_hand_side = [_]f64{ 0, 0 };
    var probes: group_types.ProbeCounts = .{};
    try std.testing.expect(group_numerics.solveDampedLeastSquares(
        &jacobian,
        &right_hand_side,
        &solution,
        &normal_matrix,
        &normal_right_hand_side,
        2,
        .{ .max_iterations = 2, .probe_counts = &probes },
    ));
    try std.testing.expect(probes.iterations >= 1);
    try std.testing.expect(probes.iterations <= 2);
    try std.testing.expectApproxEqAbs(@as(f64, 1), solution[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1), solution[1], 1e-10);
}

test "failed litter solve leaves caller state untouched" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].ammonia_mol_per_m3 = 2;
    const before = state.cells[0];
    state.water_equilibrium_balance_mol[0] = 7;
    // A constant nonzero association rate against a cell that cannot satisfy
    // it fails somewhere in the reaction network. Which specific error surfaces
    // first is an internal detail of the strategy order, so do not pin the
    // tag: the invariant under test is that *any* fail-fast leaves the caller's
    // state byte-identical, because `group_solve.solveCell` writes
    // `state.cells[cell_index]` only on a success path.
    var context = TerminalProjectionTestContext{ .extent_mol_per_m3 = 0.08 };
    if (group_solve.solveCell(
        &state,
        0,
        .{
            .litter_mass_per_water_volume_megagrams_per_m3 = 1,
            .dynamic_salts = true,
        },
        .{ .context = &context, .evaluate = group_fixtures.divergentEvaluator, .project_water_equilibrium = countedTerminalWaterProjection },
        .{ .max_iterations = 2 },
    )) |_| {
        return error.ExpectedLitterChemistryFailure;
    } else |_| {}
    try std.testing.expectEqual(before, state.cells[0]);
    try std.testing.expectEqual(@as(f64, 7), state.water_equilibrium_balance_mol[0]);
    try std.testing.expectEqual(@as(usize, 0), context.calls);
}

test "litter solve rejects caller budget and probe-count opt-outs transactionally" {
    var state = try group_types.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].ammonia_mol_per_m3 = 2;
    const before = state.cells[0];
    const context = group_fixtures.TestContext{ .rate_fraction = 0.25 };
    const evaluator = group_fixtures.Evaluator{
        .context = &context,
        .evaluate = group_fixtures.testEvaluator,
    };

    var budget = try numerics.NonlinearBudget.init(2);
    try std.testing.expectError(
        error.InvalidLitterChemistrySharedBudgetConfiguration,
        group_solve.solveCell(
            &state,
            0,
            .{ .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = true },
            evaluator,
            .{ .max_iterations = 2, .shared_budget = &budget },
        ),
    );
    try std.testing.expectEqual(before, state.cells[0]);
    try std.testing.expectEqual(@as(u16, 0), budget.attempted_iterations);

    var probes: group_types.ProbeCounts = .{};
    try std.testing.expectError(
        error.InvalidLitterChemistrySharedBudgetConfiguration,
        group_solve.solveCell(
            &state,
            0,
            .{ .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = true },
            evaluator,
            .{ .max_iterations = 2, .probe_counts = &probes },
        ),
    );
    try std.testing.expectEqual(before, state.cells[0]);
    try std.testing.expectEqual(@as(u32, 0), probes.iterations);
}

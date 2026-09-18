//! `litter_chemistry` declarations: solve.
//!
//! Split out of `litter_chemistry.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ledger = @import("litter_reaction_transformations.zig");
const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const numerics = @import("../core/numerics.zig");
const group_ammonium = @import("litter_chemistry_ammonium.zig");
const group_fixed_phosphate = @import("litter_chemistry_fixed_phosphate.zig");
const group_fixtures = @import("litter_chemistry_fixtures.zig");
const group_logging = @import("litter_chemistry_logging.zig");
const group_numerics = @import("litter_chemistry_numerics.zig");
const group_phosphate_minerals = @import("litter_chemistry_phosphate_minerals.zig");
const group_struct_arithmetic = @import("litter_chemistry_struct_arithmetic.zig");
const group_types = @import("litter_chemistry_types.zig");

fn terminalWaterEquilibriumProjection(
    evaluator: group_fixtures.Evaluator,
    cell: group_types.Cell,
) !group_fixtures.WaterEquilibriumProjection {
    const project = evaluator.project_water_equilibrium orelse return .{
        .cell = cell,
        .equal_reaction_extent_mol_per_m3 = 0,
    };
    const accepted = try project(evaluator.context, cell);
    try group_struct_arithmetic.validateCell(accepted.cell);
    if (!std.math.isFinite(accepted.equal_reaction_extent_mol_per_m3))
        return error.NonFiniteLitterWaterEquilibriumExtent;
    return accepted;
}

fn boundedAndersonSeed(
    current: group_types.Cell,
    changes: group_types.Cell,
    options: group_types.Options,
) !group_types.Cell {
    return group_struct_arithmetic.boundedPicard(
        current,
        changes,
        options.picard_relaxation,
        options,
    ) catch |err| switch (err) {
        // This is Anderson fallback stagnation, not an invalid caller state.
        // Keep the internal seed-construction error private so the fixed-hour
        // recovery gate can refine the physical schedule.
        error.NoPhysicallyAdmissibleLitterPicardStep => return error.LitterChemistrySolverStagnated,
        else => return err,
    };
}

const AndersonCandidate = struct {
    cell: group_types.Cell,
    scaled_residual: f64,
};

/// Backtracks the complete Anderson step from the accepted current iterate.
/// In `interpolateCell(seed, current, coefficient)`, coefficient one is the
/// current iterate and coefficient zero is the private bounded-Picard seed, so
/// globalization must approach one, not zero. The seed may be crossed while
/// backtracking but is never publishable. Invalid extrapolations are rejected
/// as solver probes rather than escaping as invalid caller state.
fn dampedAndersonCandidate(
    seed: group_types.Cell,
    current: group_types.Cell,
    mixing: f64,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
) !?AndersonCandidate {
    var damping: f64 = 1;
    var attempt: u16 = 0;
    while (attempt < group_types.probeCap(options, 53)) : (attempt += 1) {
        const coefficient = 1 + damping * (mixing - 1);
        if (!std.math.isFinite(coefficient) or coefficient == 1) return null;
        if (coefficient == 0) {
            damping *= 0.5;
            continue;
        }
        group_types.recordProbe(options);
        const candidate = group_struct_arithmetic.interpolateCell(
            seed,
            current,
            coefficient,
        ) catch |err| switch (err) {
            error.NegativeLitterChemistryState,
            error.NonFiniteLitterChemistryState,
            => {
                damping *= 0.5;
                continue;
            },
        };
        if (group_struct_arithmetic.valuesEqual(group_types.Cell, candidate, seed)) {
            damping *= 0.5;
            continue;
        }
        if (group_struct_arithmetic.valuesEqual(group_types.Cell, candidate, current))
            return null;
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
        if (numerics.andersonImprovesAcceptedMerit(candidate_norm, current_norm))
            return .{ .cell = candidate, .scaled_residual = candidate_norm };
        damping *= 0.5;
    }
    return null;
}

noinline fn tryNewtonCandidate(
    current: group_types.Cell,
    changes: group_types.Cell,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    options: group_types.Options,
    current_norm: f64,
) !?group_types.Cell {
    // These phosphate escapes were previously guarded by
    // `!environment.dynamic_salts`, which the solve-level early return already
    // excludes from this phase. Each accepts only on a strict improvement of
    // the complete reaction norm and closes phosphorus, cation, and site
    // conservation exactly.
    if (try group_fixed_phosphate.conservativeFixedPhosphateActiveSetNewton(
        current,
        environment,
        evaluator,
        options,
        current_norm,
    )) |candidate| return candidate;
    if (try group_fixed_phosphate.conservativeFixedPhosphateComplementarityNewton(
        current,
        environment,
        evaluator,
        options,
        current_norm,
    )) |candidate| return candidate;

    // The dense phosphate/exchange candidate is intentionally not admitted
    // here. Its reduced closure reconstructs P, cations, sites, and exchange
    // charge, but its hydroxyapatite and exchange-H coordinates also alter
    // H/OH/solvent-water inventories that it does not close. Merit descent is
    // not a substitute for conservation. Keep that experimental implementation
    // available to focused tests, but exclude it from every publishable solve
    // until the missing hydrogen/water invariants are part of its coordinates.
    if (try group_phosphate_minerals.conservativePhosphateActiveReactionSolve(
        current,
        environment,
        evaluator,
        options,
        current_norm,
        false,
    )) |candidate| return candidate;
    if (try group_ammonium.conservativeAmmoniumAssociationSolve(
        current,
        environment,
        evaluator,
        options,
        current_norm,
    )) |candidate| return candidate;

    if (group_struct_arithmetic.applyFraction(
        current,
        changes,
        options.directional_probe_fraction,
    )) |probe| {
        if (group_struct_arithmetic.changesAt(probe, environment, evaluator)) |probe_changes| {
            var numerator: f64 = 0;
            var denominator: f64 = 0;
            group_struct_arithmetic.directionalProducts(
                group_types.Cell,
                changes,
                probe_changes,
                options.directional_probe_fraction,
                &numerator,
                &denominator,
            );
            if (std.math.isFinite(denominator) and
                denominator > std.math.floatEps(f64))
            {
                const raw_fraction = -numerator / denominator;
                var fraction = @min(
                    @max(raw_fraction, options.minimum_newton_fraction),
                    @min(
                        options.maximum_newton_fraction,
                        group_struct_arithmetic.maximumAdmissibleFraction(
                            group_types.Cell,
                            current,
                            changes,
                        ),
                    ),
                );
                // The directional finite-difference quotient supplies a Newton
                // fraction. Backtrack that direction until the complete scaled
                // residual descends; no raw or inventory-boundary point escapes.
                var line_search: u16 = 0;
                while (line_search < group_types.probeCap(options, 53) and
                    std.math.isFinite(fraction) and
                    fraction > std.math.floatEps(f64)) : (line_search += 1)
                {
                    group_types.recordProbe(options);
                    if (group_struct_arithmetic.applyFraction(
                        current,
                        changes,
                        fraction,
                    )) |candidate| {
                        if (group_struct_arithmetic.changesAt(
                            candidate,
                            environment,
                            evaluator,
                        )) |candidate_changes| {
                            const candidate_norm = try group_struct_arithmetic.scaledNorm(
                                candidate,
                                candidate_changes,
                                options,
                            );
                            if (group_numerics.meaningfullyImproves(
                                current_norm,
                                candidate_norm,
                            )) return candidate;
                        } else |_| {}
                    } else |_| {}
                    fraction *= 0.5;
                }
            }
        } else |_| {}
    } else |_| {}
    return null;
}

/// Applies the surface-litter SOLUTE rates for one physical subhour.
///
/// Unlike the bulk-soil section, SOLUTE.F 3996--5250 has no MRXN loop in
/// either ISALTG branch and uses the undivided hourly rate constants at
/// 4009--4016. Evaluate every reaction from the same pre-hour cell and apply
/// one shared admissible fraction. The evaluator already includes the
/// source-order starting-water RHHX transformation, so a second terminal
/// H/OH projection would be an extra reaction absent from the source.
pub fn applyHourlyCell(
    state: *group_types.State,
    cell_index: usize,
    environment: group_types.Environment,
    evaluator: group_fixtures.Evaluator,
    requested_options: group_types.Options,
) !group_types.Result {
    if (cell_index >= state.cells.len)
        return error.LitterChemistryCellIndexOutOfBounds;
    if (requested_options.shared_budget != null or requested_options.probe_counts != null)
        return error.InvalidLitterChemistrySharedBudgetConfiguration;
    try group_struct_arithmetic.validateOptions(requested_options);
    if (!std.math.isFinite(environment.litter_mass_per_water_volume_megagrams_per_m3) or
        environment.litter_mass_per_water_volume_megagrams_per_m3 <= 0)
        return error.InvalidLitterMassWaterRatio;

    const stored_current = state.cells[cell_index];
    const starting_water = if (environment.dynamic_salts)
        if (evaluator.project_starting_water_equilibrium) |project|
            try project(evaluator.context, stored_current)
        else
            group_fixtures.WaterEquilibriumProjection{
                .cell = stored_current,
                .equal_reaction_extent_mol_per_m3 = 0,
            }
    else
        group_fixtures.WaterEquilibriumProjection{
            .cell = stored_current,
            .equal_reaction_extent_mol_per_m3 = 0,
        };
    if (!std.math.isFinite(starting_water.equal_reaction_extent_mol_per_m3))
        return error.NonFiniteLitterWaterEquilibriumExtent;
    const current = starting_water.cell;
    try group_struct_arithmetic.validateCell(current);
    const extents = try evaluator.evaluate(evaluator.context, current);
    const changes = try ledger.assemble(
        extents,
        environment.litter_mass_per_water_volume_megagrams_per_m3,
        environment.dynamic_salts,
    );
    const maximum_fraction = group_struct_arithmetic.maximumAdmissibleFraction(
        group_types.Cell,
        current,
        changes,
    );
    const accepted_fraction = if (std.math.isFinite(maximum_fraction))
        @min(1.0, maximum_fraction)
    else
        1.0;
    if (accepted_fraction <= 0)
        return error.NoPhysicallyAdmissibleHourlyLitterKineticStep;

    // Endpoint-roundoff correction is a numerical representation detail, not
    // an equilibrium iteration. Keep it independent of the caller's nonlinear
    // solver ceiling so max_iterations cannot change hourly chemistry.
    var admissibility_options = requested_options;
    admissibility_options.max_iterations = 53;
    const accepted = try group_struct_arithmetic.applyAdmissibleFraction(
        current,
        changes,
        accepted_fraction,
        admissibility_options,
    );
    state.cells[cell_index] = accepted;
    return .{
        .iterations = 1,
        .newton_raphson_steps = 0,
        .picard_steps = 0,
        .maximum_scaled_residual = 0,
        .anderson_steps = 0,
        .accepted_updates = 1,
        .probe_iterations = 0,
        .accepted_water_equilibrium_extent_mol_per_m3 = if (environment.dynamic_salts)
            starting_water.equal_reaction_extent_mol_per_m3 +
                accepted_fraction * extents.water_ion_recombination_mol_per_m3
        else
            0,
    };
}

/// Optional non-hourly conservative equilibrium solve with Anderson fallback.
/// Production hourly litter chemistry uses `applyHourlyCell` instead.
/// State is copied into local iterates and published only after convergence.
pub fn solveCell(state: *group_types.State, cell_index: usize, environment: group_types.Environment, evaluator: group_fixtures.Evaluator, requested_options: group_types.Options) !group_types.Result {
    if (cell_index >= state.cells.len) return error.LitterChemistryCellIndexOutOfBounds;
    if (requested_options.shared_budget != null or requested_options.probe_counts != null)
        return error.InvalidLitterChemistrySharedBudgetConfiguration;
    try group_struct_arithmetic.validateOptions(requested_options);
    var budget = try numerics.NonlinearBudget.init(requested_options.max_iterations);
    var accepted_updates: u16 = 0;
    var probe_counts: group_types.ProbeCounts = .{};
    var options = requested_options;
    options.shared_budget = &budget;
    options.probe_counts = &probe_counts;
    if (!std.math.isFinite(environment.litter_mass_per_water_volume_megagrams_per_m3) or environment.litter_mass_per_water_volume_megagrams_per_m3 <= 0) return error.InvalidLitterMassWaterRatio;
    try group_struct_arithmetic.validateCell(state.cells[cell_index]);

    var current = state.cells[cell_index];
    // SOLUTE.F's fixed-pH (ISALTG=0) litter branch, source lines 4634--4929,
    // sits outside any equilibrium loop: the surface-litter section 3996--5250
    // contains no `DO M=` statement, and its TPD/TADA/TADC/TSL/TRW rates
    // (lines 4009--4016) are the undivided hourly constants, not the
    // MRXN-divided TPDX/TADAX/TSLX constants the soil `DO 1000 M=1,MRXN` loop
    // at line 822 consumes. Applying undivided hourly rates repeatedly until
    // every rate vanishes would multiply one hour of precipitation and
    // association by the equilibrium iteration ceiling. This optional solver
    // therefore retains a single kinetic update for fixed pH. The production
    // hourly path handles both salt modes in `applyHourlyCell`; the iterative
    // hybrid below is available only to explicit non-hourly callers.
    if (!environment.dynamic_salts) {
        const changes = try group_struct_arithmetic.changesAt(current, environment, evaluator);
        const maximum_fraction =
            group_struct_arithmetic.maximumAdmissibleFraction(group_types.Cell, current, changes);
        const accepted_fraction =
            if (std.math.isFinite(maximum_fraction))
                @min(1.0, maximum_fraction)
            else
                1.0;
        if (accepted_fraction <= 0)
            return error.NoPhysicallyAdmissibleFixedPhKineticStep;
        const accepted = try group_struct_arithmetic.applyAdmissibleFraction(
            current,
            changes,
            accepted_fraction,
            options,
        );
        accepted_updates += 1;
        const terminal_water = try terminalWaterEquilibriumProjection(evaluator, accepted);
        state.cells[cell_index] = terminal_water.cell;
        return .{
            .iterations = 1,
            .newton_raphson_steps = 0,
            .picard_steps = 0,
            // This branch integrates a bounded kinetic rate; it has no
            // unresolved nonlinear-equilibrium residual after acceptance.
            .maximum_scaled_residual = 0,
            .accepted_updates = accepted_updates,
            .probe_iterations = probe_counts.iterations,
            .accepted_water_equilibrium_extent_mol_per_m3 = terminal_water.equal_reaction_extent_mol_per_m3,
        };
    }
    var newton_steps: u16 = 0;
    var picard_steps: u16 = 0;
    var anderson_steps: u16 = 0;
    var previous_norm = std.math.inf(f64);
    var insufficient_progress_steps: u16 = 0;
    var newton_retry_required = false;
    var iteration: u16 = 0;
    while (iteration < options.max_iterations) : (iteration += 1) {
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        const changes = try group_struct_arithmetic.changesAt(current, environment, evaluator);
        const current_norm = try group_struct_arithmetic.scaledNorm(current, changes, options);
        if (!retrying_newton_after_anderson and current_norm <= 1) {
            const terminal_water = try terminalWaterEquilibriumProjection(evaluator, current);
            state.cells[cell_index] = terminal_water.cell;
            return .{ .iterations = iteration + 1, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .maximum_scaled_residual = current_norm, .anderson_steps = anderson_steps, .accepted_updates = accepted_updates, .probe_iterations = probe_counts.iterations, .accepted_water_equilibrium_extent_mol_per_m3 = terminal_water.equal_reaction_extent_mol_per_m3 };
        }
        try budget.beginIteration();
        const progress_floor = std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, previous_norm);
        if (std.math.isFinite(previous_norm) and previous_norm - current_norm <= progress_floor)
            insufficient_progress_steps +|= 1
        else
            insufficient_progress_steps = 0;
        previous_norm = current_norm;
        const progress_requires_anderson = insufficient_progress_steps >= 4;
        newton_primary: {
            if (progress_requires_anderson and !retrying_newton_after_anderson)
                break :newton_primary;
            if (try tryNewtonCandidate(
                current,
                changes,
                environment,
                evaluator,
                options,
                current_norm,
            )) |candidate| {
                accepted_updates += 1;
                current = candidate;
                newton_steps += 1;
                continue;
            }
        }
        if (retrying_newton_after_anderson) {
            // The Anderson state is not eligible for convergence publication
            // until one separately budgeted Newton attempt has inspected it.
            // If it already satisfies the nonlinear tolerance, that mandatory
            // retry completes the sequence without another recovery update.
            // Otherwise the rejected retry consumes this iteration and the
            // next iteration restarts Newton before it may form another
            // Anderson-only recovery candidate.
            if (current_norm <= 1) {
                const terminal_water = try terminalWaterEquilibriumProjection(evaluator, current);
                state.cells[cell_index] = terminal_water.cell;
                return .{ .iterations = iteration + 1, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .maximum_scaled_residual = current_norm, .anderson_steps = anderson_steps, .accepted_updates = accepted_updates, .probe_iterations = probe_counts.iterations, .accepted_water_equilibrium_extent_mol_per_m3 = terminal_water.equal_reaction_extent_mol_per_m3 };
            }
            continue;
        }
        if (iteration + 1 >= options.max_iterations or budget.remaining() == 0)
            return error.LitterChemistrySolverDidNotConverge;

        // Sole fallback: bounded relaxation is evaluated only as the second
        // same-iteration Anderson sample and is never committed directly.
        const seed = try boundedAndersonSeed(current, changes, options);
        const seed_changes = try group_struct_arithmetic.changesAt(seed, environment, evaluator);
        const mixing = group_struct_arithmetic.andersonMixingRatio(group_types.Cell, seed, seed_changes, changes, options) orelse
            return error.LitterChemistrySolverStagnated;
        const accelerated = try dampedAndersonCandidate(
            seed,
            current,
            mixing,
            environment,
            evaluator,
            options,
            current_norm,
        ) orelse return error.LitterChemistrySolverStagnated;
        const candidate = accelerated.cell;
        anderson_steps += 1;
        // Do not scale stagnation by the largest inventory in the cell. A
        // large carbonate or exchange pool can make a representable,
        // convergence-controlling trace-ion correction look globally tiny.
        if (group_struct_arithmetic.valuesEqual(group_types.Cell, current, candidate))
            return error.LitterChemistrySolverStagnated;
        accepted_updates += 1;
        current = candidate;
        picard_steps += 1;
        newton_retry_required = true;
    }

    const final_changes = try group_struct_arithmetic.changesAt(current, environment, evaluator);
    const final_norm = try group_struct_arithmetic.scaledNorm(current, final_changes, options);
    // An accepted step on the last permitted iteration may itself satisfy
    // equilibrium. Check that state before reporting ceiling exhaustion.
    if (!newton_retry_required and final_norm <= 1) {
        const terminal_water = try terminalWaterEquilibriumProjection(evaluator, current);
        state.cells[cell_index] = terminal_water.cell;
        return .{
            .iterations = options.max_iterations,
            .newton_raphson_steps = newton_steps,
            .picard_steps = picard_steps,
            .maximum_scaled_residual = final_norm,
            .anderson_steps = anderson_steps,
            .accepted_updates = accepted_updates,
            .probe_iterations = probe_counts.iterations,
            .accepted_water_equilibrium_extent_mol_per_m3 = terminal_water.equal_reaction_extent_mol_per_m3,
        };
    }
    std.log.warn("litter chemistry failed to converge: cell={d} iterations={d} maximum_scaled_residual={e} newton_steps={d} picard_steps={d}", .{ cell_index, options.max_iterations, final_norm, newton_steps, picard_steps });
    group_logging.logUnconvergedFields(group_types.Cell, "", current, final_changes, options);
    group_logging.logAdmissibleLimits(group_types.Cell, "", current, final_changes, group_struct_arithmetic.maximumAdmissibleFraction(group_types.Cell, current, final_changes));
    const final_extents = try evaluator.evaluate(evaluator.context, current);
    std.log.warn(
        "litter phosphate mineral extents: AlPO4={e} FePO4={e} CaHPO4={e} hydroxyapatite={e} monocalcium={e}",
        .{
            final_extents.phosphate_minerals.aluminum_phosphate_mol_per_m3,
            final_extents.phosphate_minerals.iron_phosphate_mol_per_m3,
            final_extents.phosphate_minerals.dicalcium_phosphate_mol_per_m3,
            final_extents.phosphate_minerals.hydroxyapatite_mol_per_m3,
            final_extents.phosphate_minerals.monocalcium_phosphate_mol_per_m3,
        },
    );
    std.log.warn(
        "litter salt mineral extents: gibbsite={e} iron_hydroxide={e} calcite={e} gypsum={e}",
        .{
            final_extents.salt_minerals.gibbsite_mol_per_m3,
            final_extents.salt_minerals.iron_hydroxide_mol_per_m3,
            final_extents.salt_minerals.calcite_mol_per_m3,
            final_extents.salt_minerals.gypsum_mol_per_m3,
        },
    );
    std.log.warn(
        "litter exchange extents mol/Mg: NH4={e} H={e} Al={e} Fe={e} Ca={e} Mg={e} Na={e} K={e}",
        .{
            final_extents.exchange.ammonium_mol_per_megagram,
            final_extents.exchange.hydrogen_mol_per_megagram,
            final_extents.exchange.aluminum_mol_per_megagram,
            final_extents.exchange.iron_mol_per_megagram,
            final_extents.exchange.calcium_mol_per_megagram,
            final_extents.exchange.magnesium_mol_per_megagram,
            final_extents.exchange.sodium_mol_per_megagram,
            final_extents.exchange.potassium_mol_per_megagram,
        },
    );
    if (evaluator.phosphate_mineral_equilibrium_residuals) |calculate| {
        const exact = try calculate(evaluator.context, current);
        std.log.warn(
            "litter phosphate saturation residuals: AlPO4={e} FePO4={e} CaHPO4={e} hydroxyapatite={e} monocalcium={e}",
            .{
                exact.aluminum_phosphate_mol_per_m3,
                exact.iron_phosphate_mol_per_m3,
                exact.dicalcium_phosphate_mol_per_m3,
                exact.hydroxyapatite_mol_per_m3,
                exact.monocalcium_phosphate_mol_per_m3,
            },
        );
    }
    return error.LitterChemistrySolverDidNotConverge;
}

test "inadmissible Anderson seed is public nonlinear stagnation" {
    var current: group_types.Cell = undefined;
    group_struct_arithmetic.zeroValue(group_types.Cell, &current);
    var changes: group_types.Cell = undefined;
    group_struct_arithmetic.zeroValue(group_types.Cell, &changes);
    changes.ammonia_mol_per_m3 = -1;
    var probes: group_types.ProbeCounts = .{};
    try std.testing.expectError(
        error.LitterChemistrySolverStagnated,
        boundedAndersonSeed(current, changes, .{ .probe_counts = &probes }),
    );
    try std.testing.expect(probes.iterations > 0);
}

test "inadmissible raw Anderson extrapolation is damped before publication" {
    const Evaluator = struct {
        fn evaluate(_: *const anyopaque, cell: group_types.Cell) !ledger.ReactionExtents {
            var extents = std.mem.zeroes(ledger.ReactionExtents);
            extents.external_hydrogen_mol_per_m3 = cell.hydrogen_mol_per_m3;
            return extents;
        }
    };
    const context: u8 = 0;
    var seed = std.mem.zeroes(group_types.Cell);
    seed.hydrogen_mol_per_m3 = 0.1;
    var current = seed;
    current.hydrogen_mol_per_m3 = 1;

    // The raw Anderson coefficient extrapolates H to -0.08 mol m-3. The
    // complete-step line search halves toward coefficient one, giving
    // coefficient 0.4 and H=0.46 mol m-3; the private bounded-Picard seed is
    // never returned.
    try std.testing.expectError(
        error.NegativeLitterChemistryState,
        group_struct_arithmetic.interpolateCell(seed, current, -0.2),
    );
    const accelerated = (try dampedAndersonCandidate(
        seed,
        current,
        -0.2,
        .{ .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = true },
        .{ .context = &context, .evaluate = Evaluator.evaluate },
        .{ .absolute_tolerance_mol_per_m3 = 1 },
        1,
    )) orelse return error.ExpectedAdmissibleDampedAndersonCandidate;
    try std.testing.expect(accelerated.cell.hydrogen_mol_per_m3 >= 0);
    try std.testing.expect(!group_struct_arithmetic.valuesEqual(
        group_types.Cell,
        accelerated.cell,
        seed,
    ));
    try std.testing.expect(accelerated.scaled_residual < 1);
}

test "large negative Anderson mixing backtracks toward current coefficient one" {
    const Evaluator = struct {
        fn evaluate(_: *const anyopaque, cell: group_types.Cell) !ledger.ReactionExtents {
            var extents = std.mem.zeroes(ledger.ReactionExtents);
            extents.carboxyl_hydrogen_adsorption_mol_per_megagram =
                cell.hydrogen_mol_per_m3 - 0.95;
            return extents;
        }
    };
    const context: u8 = 0;
    const options = group_types.Options{
        .absolute_tolerance_mol_per_m3 = 1e-3,
        .absolute_tolerance_mol_per_megagram = 1e-3,
        // Keep the two conserved carriers on the same effective absolute
        // scale so equal-magnitude residuals at current and seed stay equal.
        .relative_tolerance = 1e-30,
    };
    var seed = std.mem.zeroes(group_types.Cell);
    seed.hydrogen_mol_per_m3 = 0.9;
    seed.carboxyl_hydrogen_mol_per_megagram = 0.1;
    var current = std.mem.zeroes(group_types.Cell);
    current.hydrogen_mol_per_m3 = 1;
    const environment = group_types.Environment{
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = true,
    };
    const evaluator = group_fixtures.Evaluator{
        .context = &context,
        .evaluate = Evaluator.evaluate,
    };
    const current_changes = try group_struct_arithmetic.changesAt(
        current,
        environment,
        evaluator,
    );
    const current_norm = try group_struct_arithmetic.scaledNorm(
        current,
        current_changes,
        options,
    );

    // This is the production failure's coefficient scale. The raw candidate
    // is negative. Halving the coefficient itself generates only coefficients
    // <= 0 and approaches the seed, where the merit is no better than current.
    // Backtracking the complete Anderson step instead eventually enters the
    // open interval (seed, current), where this conservative residual descends.
    const mixing: f64 = -1400;
    try std.testing.expectError(
        error.NegativeLitterChemistryState,
        group_struct_arithmetic.interpolateCell(seed, current, mixing),
    );
    var old_damping: f64 = 1;
    var old_attempt: u16 = 0;
    while (old_attempt < 53) : (old_attempt += 1) {
        const old_coefficient = old_damping * mixing;
        if (group_struct_arithmetic.interpolateCell(
            seed,
            current,
            old_coefficient,
        )) |old_candidate| {
            const old_changes = try group_struct_arithmetic.changesAt(
                old_candidate,
                environment,
                evaluator,
            );
            const old_norm = try group_struct_arithmetic.scaledNorm(
                old_candidate,
                old_changes,
                options,
            );
            try std.testing.expect(!numerics.andersonImprovesAcceptedMerit(
                old_norm,
                current_norm,
            ));
        } else |err| switch (err) {
            error.NegativeLitterChemistryState => {},
            else => return err,
        }
        old_damping *= 0.5;
    }

    const accelerated = (try dampedAndersonCandidate(
        seed,
        current,
        mixing,
        environment,
        evaluator,
        options,
        current_norm,
    )) orelse return error.ExpectedGlobalizedAndersonCandidate;
    try std.testing.expect(accelerated.cell.hydrogen_mol_per_m3 >
        seed.hydrogen_mol_per_m3);
    try std.testing.expect(accelerated.cell.hydrogen_mol_per_m3 <
        current.hydrogen_mol_per_m3);
    try std.testing.expect(accelerated.cell.carboxyl_hydrogen_mol_per_megagram >= 0);
    try std.testing.expect(numerics.andersonImprovesAcceptedMerit(
        accelerated.scaled_residual,
        current_norm,
    ));
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        accelerated.cell.hydrogen_mol_per_m3 +
            accelerated.cell.carboxyl_hydrogen_mol_per_megagram,
        1e-14,
    );
}

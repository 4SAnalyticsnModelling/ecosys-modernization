const std = @import("std");
const ecosys = @import("ecosys_ng");

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const invocation = parseInvocation(args) catch {
        std.log.err(
            "usage: ecosys_ng_replay_solute [--production] <ecosys-ng-solute-failure-*.bin>",
            .{},
        );
        return error.MissingSoluteFailureSnapshotPath;
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        invocation.snapshot_path,
        allocator,
        .limited(16 * 1024 * 1024),
    );
    defer allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var replay_case = try ecosys.solute_failure_snapshot.read(
        allocator,
        &reader,
    );
    defer replay_case.deinit();
    const packed_count =
        ecosys.solute_chemistry_state.State.packedComponentCount();
    const initial_state = try allocator.alloc(f64, packed_count);
    defer allocator.free(initial_state);
    try replay_case.state.packCell(0, initial_state);
    if (invocation.production_mode) {
        return runProductionBenchmark(
            init.io,
            allocator,
            &replay_case,
            initial_state,
        );
    }
    const initial_residual = try allocator.alloc(f64, packed_count);
    defer allocator.free(initial_residual);
    const initial_maximum_scaled_residual =
        try ecosys.solute_reaction_solver.evaluateCellResidual(
            allocator,
            &replay_case.state,
            0,
            replay_case.parameters,
            replay_case.options,
            initial_residual,
        );
    std.log.info(
        "SOLUTE initial residual vector: components={d} maximum_scaled_residual={e}",
        .{ packed_count, initial_maximum_scaled_residual },
    );
    for (initial_state, initial_residual, 0..) |
        state_value,
        residual_value,
        component_index,
    | {
        // STATE-relative, which is NOT the scale the solver ranks on.
        //
        // `reaction_solver_numerics.residualScale` uses
        // `options.search_reference_concentrations` when it is populated, and
        // production populates it: `reaction_solve.zig:1082` installs the
        // references built by `initializeSearchReferences` (`:1006`), which
        // gives hydrogen and hydroxide `@max(own_value, water_ion_reference)`
        // -- a charge-weighted total over the whole ion inventory -- and gives
        // every `*_megagram` phosphate coordinate its conserved site total.
        //
        // So for any trace species the solver's scale is dominated by a FAMILY
        // total while the ratio below is relative to the species' own value.
        // The two differ by orders of magnitude. This field is named
        // `state_relative_residual` rather than `scaled_residual` because the
        // old name invited exactly one mistake: reading it as the solver's
        // ranking metric and back-computing a native residual from the
        // absolute floor alone. That produced a published magnitude for the
        // hour-2232 hydrogen residual that was wrong by orders of magnitude
        // and had to be retracted.
        //
        // To see the solver's own metric, read `limiting_residual` in the
        // iteration trace below, which is computed with the search references.
        const state_relative_scale =
            replay_case.options.absoluteToleranceForPackedComponent(component_index) +
            replay_case.options.relative_tolerance * @abs(state_value);
        std.log.info(
            "SOLUTE initial component: index={d} name={s} state={e} residual={e} state_relative_residual={e} (NOT the solver ranking scale; see limiting_residual in the trace)",
            .{
                component_index,
                ecosys.solute_chemistry_state.State.packedComponentName(
                    component_index,
                ) orelse "unknown",
                state_value,
                residual_value,
                @abs(residual_value) / state_relative_scale,
            },
        );
    }
    const diagnostic = ecosys.solute_reaction_solver.diagnoseCell(
        &replay_case.state,
        0,
        replay_case.parameters,
    ) catch |err| diagnostic: {
        std.log.warn(
            "SOLUTE pre-solve decomposition unavailable: error={s}",
            .{@errorName(err)},
        );
        break :diagnostic null;
    };
    if (diagnostic) |value| std.log.info(
        "SOLUTE pre-solve decomposition: aqueous(H={e},OH={e}) phosphate(H={e},OH={e}) exchange_H={e} carboxyl_H={e} geochemistry(H={e},OH={e}) assembled(H={e},OH={e})",
        .{
            value.aqueous_hydrogen_mol_per_m3,
            value.aqueous_hydroxide_mol_per_m3,
            value.phosphate_hydrogen_mol_per_m3,
            value.phosphate_hydroxide_mol_per_m3,
            value.cation_exchange_hydrogen_mol_per_m3,
            value.carboxyl_hydrogen_mol_per_m3,
            value.geochemistry_hydrogen_mol_per_m3,
            value.geochemistry_hydroxide_mol_per_m3,
            value.assembled_hydrogen_mol_per_m3,
            value.assembled_hydroxide_mol_per_m3,
        },
    );
    const hpo4 = ecosys.solute_reaction_solver.diagnoseNonBandHpo4(
        &replay_case.state,
        0,
        replay_case.parameters,
    ) catch |err| hpo4_diagnostic: {
        std.log.warn(
            "SOLUTE non-band HPO4 decomposition unavailable: error={s}",
            .{@errorName(err)},
        );
        break :hpo4_diagnostic null;
    };
    if (hpo4) |value| std.log.info(
        "SOLUTE non-band HPO4 decomposition: PO4_protonation={e} HPO4_protonation={e} metal_pairing={e} surface_adsorption={e} assembled={e}",
        .{
            value.po4_protonation_mol_p_per_m3,
            value.hpo4_protonation_mol_p_per_m3,
            value.metal_pairing_mol_p_per_m3,
            value.surface_adsorption_mol_p_per_m3,
            value.assembled_change_mol_p_per_m3,
        },
    );
    var trace = try ecosys.solute_reaction_solver.SolverTrace.init(
        allocator,
        @as(usize, replay_case.options.max_iterations) + 2,
    );
    defer trace.deinit();
    const result = ecosys.solute_reaction_solver.solveCellWithTrace(
        allocator,
        &replay_case.state,
        0,
        replay_case.parameters,
        replay_case.options,
        &trace,
    ) catch |err| {
        logTrace(&trace);
        std.log.err(
            "SOLUTE replay failed reproducibly: snapshot={s} scene_hour={d} cell={d} layer={d} max_iterations={d} error={s}",
            .{
                invocation.snapshot_path,
                replay_case.context.scene_hour,
                replay_case.context.global_cell_id,
                replay_case.context.soil_layer_id,
                replay_case.options.max_iterations,
                @errorName(err),
            },
        );
        return err;
    };
    logTrace(&trace);
    const first_final_state = try allocator.alloc(f64, packed_count);
    defer allocator.free(first_final_state);
    try replay_case.state.packCell(0, first_final_state);
    var repeated_state = try ecosys.solute_chemistry_state.State.init(
        allocator,
        1,
    );
    defer repeated_state.deinit();
    try repeated_state.unpackCell(0, initial_state);
    const repeated_result = try ecosys.solute_reaction_solver.solveCell(
        allocator,
        &repeated_state,
        0,
        replay_case.parameters,
        replay_case.options,
    );
    const repeated_final_state = try allocator.alloc(f64, packed_count);
    defer allocator.free(repeated_final_state);
    try repeated_state.packCell(0, repeated_final_state);
    const repeatability = compareStates(
        first_final_state,
        repeated_final_state,
    );
    if (!std.meta.eql(result, repeated_result) or
        repeatability.maximum_absolute_difference != 0)
    {
        return error.NonDeterministicSoluteReplay;
    }
    std.log.info(
        "SOLUTE replay converged: iterations={d} newton={d} picard={d} residual={e}",
        .{
            result.iterations,
            result.newton_raphson_steps,
            result.picard_steps,
            result.maximum_scaled_residual,
        },
    );
    std.log.info(
        "SOLUTE deterministic repeat: maximum_absolute_difference={e} maximum_relative_difference={e}",
        .{
            repeatability.maximum_absolute_difference,
            repeatability.maximum_relative_difference,
        },
    );
}

const Invocation = struct {
    snapshot_path: []const u8,
    production_mode: bool,
};

fn parseInvocation(args: []const []const u8) !Invocation {
    if (args.len == 2) return .{
        .snapshot_path = args[1],
        .production_mode = false,
    };
    if (args.len == 3 and std.mem.eql(u8, args[1], "--production")) {
        return .{
            .snapshot_path = args[2],
            .production_mode = true,
        };
    }
    return error.InvalidSoluteReplayArguments;
}

test "solute replay invocation distinguishes diagnostic and production modes" {
    const diagnostic = try parseInvocation(&.{ "replay", "failure.bin" });
    try std.testing.expect(!diagnostic.production_mode);
    try std.testing.expectEqualStrings("failure.bin", diagnostic.snapshot_path);

    const production = try parseInvocation(&.{
        "replay",
        "--production",
        "failure.bin",
    });
    try std.testing.expect(production.production_mode);
    try std.testing.expectEqualStrings("failure.bin", production.snapshot_path);
}

test "solute replay invocation rejects missing and unknown modes" {
    try std.testing.expectError(
        error.InvalidSoluteReplayArguments,
        parseInvocation(&.{"replay"}),
    );
    try std.testing.expectError(
        error.InvalidSoluteReplayArguments,
        parseInvocation(&.{ "replay", "--trace", "failure.bin" }),
    );
}

fn runProductionBenchmark(
    io: std.Io,
    allocator: std.mem.Allocator,
    replay_case: *ecosys.solute_failure_snapshot.ReplayCase,
    initial_state: []const f64,
) !void {
    var workspace = try ecosys.solute_reaction_solver.Workspace.init(allocator);
    defer workspace.deinit();
    const packed_count =
        ecosys.solute_chemistry_state.State.packedComponentCount();
    const first_final_state = try allocator.alloc(f64, packed_count);
    defer allocator.free(first_final_state);
    const repeated_final_state = try allocator.alloc(f64, packed_count);
    defer allocator.free(repeated_final_state);

    var suppression = ecosys.solute_reaction_solver.suppressDiagnostics();
    defer suppression.restore();
    const started = std.Io.Timestamp.now(io, .awake);
    const result = try ecosys.solute_reaction_solver.solveCellWithWorkspace(
        &workspace,
        &replay_case.state,
        0,
        replay_case.parameters,
        replay_case.options,
    );
    const elapsed = started.untilNow(io, .awake).nanoseconds;
    try replay_case.state.packCell(0, first_final_state);

    // Startup reuses one worker-owned workspace across layers. Reset only the
    // scientific cell, then exercise that same ownership pattern again.
    try replay_case.state.unpackCell(0, initial_state);
    const repeated_result =
        try ecosys.solute_reaction_solver.solveCellWithWorkspace(
            &workspace,
            &replay_case.state,
            0,
            replay_case.parameters,
            replay_case.options,
        );
    try replay_case.state.packCell(0, repeated_final_state);
    const repeatability = compareStates(
        first_final_state,
        repeated_final_state,
    );
    if (!std.meta.eql(result, repeated_result) or
        repeatability.maximum_absolute_difference != 0)
    {
        return error.NonDeterministicSoluteProductionReplay;
    }
    std.log.info(
        "SOLUTE production replay: elapsed_ns={d} elapsed_seconds={d:.6} iterations={d} newton={d} picard={d} residual={e}",
        .{
            elapsed,
            @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s,
            result.iterations,
            result.newton_raphson_steps,
            result.picard_steps,
            result.maximum_scaled_residual,
        },
    );
    std.log.info(
        "SOLUTE production replay deterministic repeat: maximum_absolute_difference={e} maximum_relative_difference={e}",
        .{
            repeatability.maximum_absolute_difference,
            repeatability.maximum_relative_difference,
        },
    );
}

fn logTrace(trace: *const ecosys.solute_reaction_solver.SolverTrace) void {
    for (trace.recorded()) |entry| {
        std.log.info(
            "SOLUTE iteration trace: closure={d} iteration={d} limiter_index={d} limiter_name={s} state={e} residual={e} current_merit={e} full_network_merit={e} phosphate_merit={e} full_status={s} active_columns={d} populated_columns={d} rank={d} inventory_fraction={e} predicted_merit={e} anderson_attempted={} selected={s} selected_merit={e}",
            .{
                entry.closure_index,
                entry.iteration,
                entry.limiting_component_index,
                ecosys.solute_chemistry_state.State.packedComponentName(
                    entry.limiting_component_index,
                ) orelse "unknown",
                entry.limiting_state_value,
                entry.limiting_residual,
                entry.current_maximum_scaled_residual,
                entry.full_network_candidate_maximum_scaled_residual,
                entry.phosphate_candidate_maximum_scaled_residual,
                @tagName(entry.full_network_status),
                entry.full_network_active_columns,
                entry.full_network_populated_columns,
                entry.full_network_rank,
                entry.full_network_inventory_fraction,
                entry.full_network_predicted_maximum_scaled_residual,
                entry.anderson_attempted,
                @tagName(entry.selected_candidate),
                entry.selected_maximum_scaled_residual,
            },
        );
        if (entry.ternary_correction_status != .not_attempted) {
            std.log.info(
                "SOLUTE ternary correction trace: closure={d} iteration={d} status={s} initialized_axes={d} kept_axes={d} base_certified={} discovery_rank={d} ambiguous_axes={d} patterns={d} considered={d} solved={d} kkt={d} nonzero={d} admissible={d} armijo_attempts={d} armijo_accepted={d}",
                .{
                    entry.closure_index,
                    entry.iteration,
                    @tagName(entry.ternary_correction_status),
                    entry.ternary_correction_initialized_axes,
                    entry.ternary_correction_kept_axes,
                    entry.ternary_correction_base_certified,
                    entry.ternary_correction_discovery_rank,
                    entry.ternary_correction_ambiguous_axes,
                    entry.ternary_correction_pattern_count,
                    entry.ternary_correction_patterns_considered,
                    entry.ternary_correction_patterns_solved,
                    entry.ternary_correction_patterns_kkt,
                    entry.ternary_correction_patterns_nonzero,
                    entry.ternary_correction_patterns_admissible,
                    entry.ternary_correction_armijo_attempts,
                    entry.ternary_correction_armijo_accepted,
                },
            );
            for (
                entry.ternary_correction_axis_diagnostics[0..entry.ternary_correction_axis_diagnostic_count],
                0..,
            ) |axis, diagnostic_index| {
                const identity =
                    ecosys.solute_conservative_reaction_span.reactionIdentity(
                        axis.reaction_index,
                    );
                std.log.info(
                    "SOLUTE ternary ambiguous axis: diagnostic_index={d} source={s} column={d} reaction_index={d} domain={s} name={s} discovery_extent={e} discovery_branch={d} current_rate={e} current_branch={d} extent_significance_ratio={e} normalized_pinned_kkt_violation={e}",
                    .{
                        diagnostic_index,
                        @tagName(axis.source),
                        axis.compact_column,
                        axis.reaction_index,
                        if (identity) |value|
                            @tagName(value.domain)
                        else
                            "unknown",
                        if (identity) |value|
                            value.name
                        else
                            "unknown",
                        axis.discovery_extent,
                        axis.discovery_branch,
                        axis.current_rate,
                        axis.current_branch,
                        axis.extent_significance_ratio,
                        axis.normalized_pinned_kkt_violation,
                    },
                );
            }
        }
    }
    if (!trace.full_network_comparison_valid) return;
    std.log.info(
        "SOLUTE rejected full-network direction: closure={d} iteration={d} limiting_component_index={d} limiting_component_name={s} inventory_fraction={e} first_trial_fraction={e} first_trial_merit={e} directional_fraction={e}",
        .{
            trace.full_network_comparison_closure,
            trace.full_network_comparison_iteration,
            trace.full_network_limiting_component_index,
            ecosys.solute_chemistry_state.State.packedComponentName(
                trace.full_network_limiting_component_index,
            ) orelse "unknown",
            trace.full_network_comparison_inventory_fraction,
            trace.full_network_first_trial_fraction,
            trace.full_network_first_trial_maximum_scaled_residual,
            trace.full_network_directional_fraction,
        },
    );
    if (trace.full_network_complementarity_search_attempted) {
        std.log.info(
            "SOLUTE complementarity search: ambiguous_columns={d} combinations={d} side_consistent={d} exact_descents={d} minimum_mismatches={d} minimum_mismatch_mask={d} best_mask={d} best_predicted_merit={e} best_exact_merit={e}",
            .{
                trace.full_network_complementarity_ambiguous_count,
                trace.full_network_complementarity_combination_count,
                trace.full_network_complementarity_consistent_count,
                trace.full_network_complementarity_exact_descent_count,
                trace.full_network_complementarity_minimum_mismatch_count,
                trace.full_network_complementarity_minimum_mismatch_mask,
                trace.full_network_complementarity_best_mask,
                trace.full_network_complementarity_best_predicted_merit,
                trace.full_network_complementarity_best_exact_merit,
            },
        );
        for (
            trace.full_network_complementarity_ambiguous_columns[0..trace.full_network_complementarity_ambiguous_count],
            0..,
        ) |column, bit| {
            const reaction = trace.full_network_reactions[column];
            const identity =
                ecosys.solute_conservative_reaction_span.reactionIdentity(
                    reaction.reaction_index,
                ) orelse continue;
            const minimum_pattern_uses_opposite =
                trace.full_network_complementarity_minimum_mismatch_mask &
                (@as(u64, 1) << @intCast(bit)) != 0;
            std.log.info(
                "SOLUTE complementarity ambiguous axis: bit={d} column={d} reaction_index={d} domain={s} name={s} selection_rate={e} original_solution={e} minimum_pattern_uses_opposite_side={}",
                .{
                    bit,
                    column,
                    reaction.reaction_index,
                    @tagName(identity.domain),
                    identity.name,
                    reaction.selection_rate,
                    reaction.normalized_solution,
                    minimum_pattern_uses_opposite,
                },
            );
        }
        if (trace.full_network_complementarity_minimum_mismatch_count !=
            std.math.maxInt(usize))
        {
            for (
                trace.full_network_complementarity_mismatch_columns[0..trace.full_network_complementarity_minimum_mismatch_count],
            ) |column| {
                const reaction = trace.full_network_reactions[column];
                const identity =
                    ecosys.solute_conservative_reaction_span.reactionIdentity(
                        reaction.reaction_index,
                    ) orelse continue;
                std.log.info(
                    "SOLUTE complementarity remaining mismatch: column={d} reaction_index={d} domain={s} name={s}",
                    .{
                        column,
                        reaction.reaction_index,
                        @tagName(identity.domain),
                        identity.name,
                    },
                );
            }
        }
        if (trace.full_network_complementarity_blend_attempted) {
            const column =
                trace.full_network_complementarity_blend_column;
            const reaction = trace.full_network_reactions[column];
            const identity =
                ecosys.solute_conservative_reaction_span.reactionIdentity(
                    reaction.reaction_index,
                );
            std.log.info(
                "SOLUTE complementarity kink blend: column={d} reaction_index={d} domain={s} name={s} opposite_side_fraction={e} normalized_solution={e} predicted_merit={e} exact_merit={e}",
                .{
                    column,
                    reaction.reaction_index,
                    if (identity) |value|
                        @tagName(value.domain)
                    else
                        "unknown",
                    if (identity) |value|
                        value.name
                    else
                        "unknown",
                    trace.full_network_complementarity_blend_fraction,
                    trace.full_network_complementarity_blend_solution,
                    trace.full_network_complementarity_blend_predicted_merit,
                    trace.full_network_complementarity_blend_exact_merit,
                },
            );
        }
    }
    for (
        trace.full_network_reactions[0..trace.full_network_reaction_count],
    ) |reaction| {
        const identity =
            ecosys.solute_conservative_reaction_span.reactionIdentity(
                reaction.reaction_index,
            ) orelse continue;
        const bound_scale = @max(
            1,
            @max(
                @abs(reaction.normalized_lower_bound),
                @abs(reaction.normalized_upper_bound),
            ),
        );
        const bound_tolerance =
            64 * std.math.floatEps(f64) * bound_scale;
        const selected_face: []const u8 =
            if (@abs(
                reaction.normalized_solution -
                    reaction.normalized_lower_bound,
            ) <= bound_tolerance)
                "lower"
            else if (@abs(
                reaction.normalized_solution -
                    reaction.normalized_upper_bound,
            ) <= bound_tolerance)
                "upper"
            else
                "free";
        const predicted_limiting_contribution =
            reaction.limiting_normalized_residual_derivative *
            reaction.normalized_solution *
            trace.full_network_comparison_inventory_fraction;
        std.log.info(
            "SOLUTE rejected reaction axis: index={d} domain={s} name={s} selection_rate={e} current_rate={e} directional_rate={e} current_rate_change_per_direction_fraction={e} native_extent_scale={e} normalized_lower_bound={e} normalized_upper_bound={e} normalized_solution={e} selected_face={s} selected_side_limiting_normalized_residual_derivative={e} solution_side_limiting_normalized_residual_derivative={e} predicted_limiting_contribution={e}",
            .{
                reaction.reaction_index,
                @tagName(identity.domain),
                identity.name,
                reaction.selection_rate,
                reaction.current_rate,
                reaction.directional_rate,
                (reaction.directional_rate - reaction.current_rate) /
                    trace.full_network_directional_fraction,
                reaction.native_extent_scale,
                reaction.normalized_lower_bound,
                reaction.normalized_upper_bound,
                reaction.normalized_solution,
                selected_face,
                reaction.limiting_normalized_residual_derivative,
                reaction.solution_side_limiting_normalized_residual_derivative,
                predicted_limiting_contribution,
            },
        );
    }
    for (
        trace.full_network_base_residual,
        trace.full_network_predicted_residual,
        trace.full_network_realized_residual,
        0..,
    ) |base, predicted, realized, component_index| {
        std.log.info(
            "SOLUTE rejected direction component: index={d} name={s} base_residual={e} predicted_residual={e} realized_residual={e} predicted_directional_derivative={e} realized_directional_derivative={e}",
            .{
                component_index,
                ecosys.solute_chemistry_state.State.packedComponentName(
                    component_index,
                ) orelse "unknown",
                base,
                predicted,
                realized,
                (predicted - base) /
                    trace.full_network_directional_fraction,
                (realized - base) /
                    trace.full_network_directional_fraction,
            },
        );
    }
}

const StateComparison = struct {
    maximum_absolute_difference: f64,
    maximum_relative_difference: f64,
};

fn compareStates(first: []const f64, second: []const f64) StateComparison {
    var maximum_absolute_difference: f64 = 0;
    var maximum_relative_difference: f64 = 0;
    for (first, second) |first_value, second_value| {
        const absolute_difference = @abs(first_value - second_value);
        const scale = @max(@abs(first_value), @abs(second_value));
        const relative_difference = if (scale == 0)
            0
        else
            absolute_difference / scale;
        maximum_absolute_difference = @max(
            maximum_absolute_difference,
            absolute_difference,
        );
        maximum_relative_difference = @max(
            maximum_relative_difference,
            relative_difference,
        );
    }
    return .{
        .maximum_absolute_difference = maximum_absolute_difference,
        .maximum_relative_difference = maximum_relative_difference,
    };
}

test "state comparison reports exact and scaled differences" {
    const exact = compareStates(&.{ 0, 2 }, &.{ 0, 2 });
    try std.testing.expectEqual(@as(f64, 0), exact.maximum_absolute_difference);
    try std.testing.expectEqual(@as(f64, 0), exact.maximum_relative_difference);
    const changed = compareStates(&.{ 0, 2 }, &.{ 1, 4 });
    try std.testing.expectEqual(@as(f64, 2), changed.maximum_absolute_difference);
    try std.testing.expectEqual(@as(f64, 1), changed.maximum_relative_difference);
}

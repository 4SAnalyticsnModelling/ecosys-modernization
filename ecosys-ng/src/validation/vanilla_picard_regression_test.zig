//! Regression guard for the v1.0.0 solver-architecture invariant:
//! "damped/line-search Newton primary, Anderson-accelerated Picard the ONLY
//! allowed fallback, no vanilla Picard anywhere in production." A
//! two-session sweep found and fixed nine vanilla-Picard violations (see
//! docs/discrepancy_register.md's `SOLVER-VANILLA-PICARD-*` entries and the
//! "Anderson-accelerated" commits in `git log`). The source-tree registration
//! test below rejects new bespoke Picard-counter loops until they are audited
//! and registered, while the known-solver table catches the easy-to-miss
//! regression of an already-fixed solver losing its Anderson fallback. Every
//! file below must retain an executable Anderson
//! implementation token; comments alone do not satisfy the guard. Bespoke
//! solvers with a compatibility opt-out must also retain production
//! validation that rejects false.
const std = @import("std");

/// Retains source positions while replacing comments and literals with
/// whitespace. Solver-policy guards must be satisfied by executable tokens;
/// prose and test-message strings are not evidence of a production path.
fn executableSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const State = enum { code, line_comment, block_comment, string, character };
    var result = try allocator.alloc(u8, source.len);
    @memset(result, ' ');
    var state: State = .code;
    var block_depth: usize = 0;
    var escaped = false;
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        const byte = source[index];
        const next = if (index + 1 < source.len) source[index + 1] else 0;
        switch (state) {
            .code => {
                if (byte == '/' and next == '/') {
                    state = .line_comment;
                    index += 1;
                } else if (byte == '/' and next == '*') {
                    state = .block_comment;
                    block_depth = 1;
                    index += 1;
                } else if (byte == '"') {
                    state = .string;
                    escaped = false;
                } else if (byte == '\'') {
                    state = .character;
                    escaped = false;
                } else if (byte == '\\' and next == '\\') {
                    // Zig multiline-string line: `\\text`.
                    state = .line_comment;
                    index += 1;
                } else {
                    result[index] = byte;
                }
            },
            .line_comment => if (byte == '\n') {
                result[index] = byte;
                state = .code;
            },
            .block_comment => {
                if (byte == '/' and next == '*') {
                    block_depth += 1;
                    index += 1;
                } else if (byte == '*' and next == '/') {
                    block_depth -= 1;
                    index += 1;
                    if (block_depth == 0) state = .code;
                } else if (byte == '\n') {
                    result[index] = byte;
                }
            },
            .string, .character => {
                if (byte == '\n') result[index] = byte;
                if (escaped) {
                    escaped = false;
                } else if (byte == '\\') {
                    escaped = true;
                } else if ((state == .string and byte == '"') or
                    (state == .character and byte == '\''))
                {
                    state = .code;
                }
            },
        }
    }
    return result;
}

const SolverGuard = struct {
    path: []const u8,
    implementation_token: []const u8,
    rejects_disabled_token: ?[]const u8 = null,
    publication_verification_token: ?[]const u8 = null,
};

const known_anderson_picard_solvers = [_]SolverGuard{
    .{ .path = "src/core/numerics.zig", .implementation_token = "andersonDepthOneCandidate", .rejects_disabled_token = "!options.anderson_recovery" },
    .{ .path = "src/soil/water/solver_solve.zig", .implementation_token = "andersonDepthOneCandidate", .rejects_disabled_token = "!options.anderson_recovery" },
    .{ .path = "src/soil/heat/solver_solve.zig", .implementation_token = "andersonDepthOneCandidate" },
    .{ .path = "src/soil/water/phase_solver.zig", .implementation_token = "andersonDepthOneCandidate", .rejects_disabled_token = "!options.anderson_recovery_enabled" },
    .{ .path = "src/soil/water/enthalpy_balance.zig", .implementation_token = "numerics.newtonPicard" },
    .{ .path = "src/soil/water/snow_transport_solver.zig", .implementation_token = "andersonDepthOneCandidate", .rejects_disabled_token = "!options.anderson_recovery" },
    .{ .path = "src/soil/water/snow_phase_change.zig", .implementation_token = "andersonAcceleratedPhaseHeat", .rejects_disabled_token = "!options.anderson_recovery" },
    .{ .path = "src/soil/gas/vapor_solver.zig", .implementation_token = "andersonDepthOneCandidate", .rejects_disabled_token = "!options.anderson_recovery" },
    .{ .path = "src/soil/gas/aqueous_extensive_transport.zig", .implementation_token = "andersonDepthOneCandidate", .rejects_disabled_token = "!options.anderson_recovery", .publication_verification_token = "publication_residual" },
    .{ .path = "src/soil/gas/coupled_gas_solver_solve.zig", .implementation_token = "andersonDepthOneCandidate", .publication_verification_token = "conservativePublicationNorm" },
    .{ .path = "src/soil/organic/transport.zig", .implementation_token = "andersonDepthOneCandidate", .rejects_disabled_token = "!options.anderson_recovery", .publication_verification_token = "publication_residual" },
    .{ .path = "src/soil/solute/transport_solver.zig", .implementation_token = "andersonDepthOneCandidate", .rejects_disabled_token = "!options.anderson_recovery", .publication_verification_token = "publication_residual" },
    .{ .path = "src/soil/solute/reaction_solve.zig", .implementation_token = "scaledAndersonDepthOneCandidate" },
    .{ .path = "src/soil/solute/reaction_try_acceptance.zig", .implementation_token = "tryAcceptAndersonCandidate" },
    // Local chemistry candidate generators. Each runs a line-searched dense
    // Newton primary, offers exactly one Anderson depth-one candidate per
    // counted iteration, and fails closed on unimproved iterations
    // (`SurfaceChargeStagnated`, `SurfaceMineralStagnated`,
    // `PhosphateSpeciationStagnated`) rather than publishing a raw map image.
    .{ .path = "src/soil/solute/reaction_surface_charge.zig", .implementation_token = "numerics.andersonDepthOneCandidate" },
    .{ .path = "src/soil/solute/reaction_surface_minerals.zig", .implementation_token = "numerics.andersonDepthOneCandidate" },
    .{ .path = "src/soil/solute/phosphate_local_speciation.zig", .implementation_token = "numerics.andersonDepthOneCandidate" },
    // Scalar acid-base/hydroxide elimination: delegates the whole policy to
    // the shared `newtonPicard` (Newton primary, mandatory Anderson recovery)
    // and never sets `.anderson_recovery = false`.
    .{ .path = "src/soil/solute/hydroxide_speciation.zig", .implementation_token = "numerics.newtonPicard" },
    .{ .path = "src/surface/litter_chemistry_solve.zig", .implementation_token = "andersonMixingRatio" },
    .{ .path = "src/surface/litter_reaction_rates.zig", .implementation_token = "core_numerics.andersonDepthOneCandidate", .rejects_disabled_token = "!options.anderson_recovery" },
    .{ .path = "src/plant/root/plant_root_salt_exchange.zig", .implementation_token = "andersonDepthOneCandidate", .rejects_disabled_token = "!options.anderson_recovery" },
    .{ .path = "src/canopy/energy/air_exchange.zig", .implementation_token = "numerics.newtonPicard", .rejects_disabled_token = "!options.anderson_recovery" },
    .{ .path = "src/canopy/energy/coupled_convergence.zig", .implementation_token = "numerics.newtonPicard" },
    .{ .path = "src/surface/temperature_solver.zig", .implementation_token = "numerics.newtonPicard" },
    .{ .path = "src/canopy/photosynthesis/leaf_co2_solver.zig", .implementation_token = "numerics.newtonPicard" },
    .{ .path = "src/plant/root/oxygen_uptake_solver.zig", .implementation_token = "numerics.newtonPicard" },
    .{ .path = "src/plant/root/plant_root_gas_exchange.zig", .implementation_token = "numerics.newtonPicard" },
    .{ .path = "src/plant/root/water_balance.zig", .implementation_token = "numerics.newtonPicardFiniteDifference" },
    .{ .path = "src/plant/standing_dead/surface_exchange.zig", .implementation_token = "numerics.newtonPicard" },
    .{ .path = "src/soil/gas/methane_oxidation.zig", .implementation_token = "numerics.newtonPicard" },
    .{ .path = "src/soil/gas/oxygen_solver.zig", .implementation_token = "numerics.newtonPicard" },
    .{ .path = "src/soil/profile/erosion.zig", .implementation_token = "numerics.newtonPicardFiniteDifference" },
    .{ .path = "src/surface/ground_air_exchange.zig", .implementation_token = "numerics.newtonPicard" },
};

// Files which mention solver mechanics but do not own a production nonlinear
// iteration. Keeping this support/caller registry explicit makes discovery
// fail closed when a new file introduces fixed-point/Picard/Anderson machinery.
const registered_solver_support_files = [_][]const u8{
    "canopy/energy/temperature_solver.zig",
    "driver/model_initialization.zig",
    "ecosys_ng.zig",
    "replay_coupled_gas_failure.zig",
    "replay_solute_failure.zig",
    "soil/gas/coupled_gas_solver_diagnostics.zig",
    "soil/gas/coupled_gas_solver_misc.zig",
    "soil/gas/coupled_gas_solver_newton_steps.zig",
    "soil/gas/coupled_gas_solver_residual.zig",
    "soil/gas/methane_step.zig",
    "soil/gas/transport_step.zig",
    "soil/heat/solver_residual.zig",
    "soil/heat/solver_tests.zig",
    "soil/heat/solver_types.zig",
    "soil/solute/reaction_solver_complementarity.zig",
    "soil/solute/reaction_solver.zig",
    "soil/solute/reaction_solver_candidates.zig",
    "soil/solute/reaction_solver_solve.zig",
    "soil/solute/reaction_solver_tests.zig",
    "soil/solute/reaction_solver_types.zig",
    "soil/solute/reaction_try_network.zig",
    "soil/solute/reaction_try.zig",
    "soil/water/heat_step.zig",
    "soil/water/retention.zig",
    "soil/water/solver_tests.zig",
    "soil/water/solver_types.zig",
    "stages/hourly_heat_water_solute.zig",
    "stages/hourly_snow_energy.zig",
    "surface/litter_chemistry_step.zig",
    "surface/litter_chemistry_struct_arithmetic.zig",
    "surface/litter_chemistry_tests.zig",
    "surface/litter_chemistry_types.zig",
    "surface/litter_gas_transport_step.zig",
    "validation/surface_litter_chemistry_test.zig",
};

test "every known nonlinear solver retains executable mandatory Anderson recovery" {
    const allocator = std.testing.allocator;
    for (known_anderson_picard_solvers) |guard| {
        const source = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            guard.path,
            allocator,
            .limited(2 * 1024 * 1024),
        ) catch |err| {
            std.debug.print(
                "VANILLA-PICARD REGRESSION GUARD: could not read '{s}': {s}\n",
                .{ guard.path, @errorName(err) },
            );
            return err;
        };
        defer allocator.free(source);
        const executable = try executableSource(allocator, source);
        defer allocator.free(executable);
        if (std.mem.indexOf(u8, executable, guard.implementation_token) == null) {
            std.debug.print(
                "VANILLA-PICARD REGRESSION GUARD: '{s}' lacks executable token '{s}'.\n",
                .{ guard.path, guard.implementation_token },
            );
        }
        try std.testing.expect(std.mem.indexOf(u8, executable, guard.implementation_token) != null);
        if (guard.rejects_disabled_token) |token|
            try std.testing.expect(std.mem.indexOf(u8, executable, token) != null);
        if (guard.publication_verification_token) |token|
            try std.testing.expect(std.mem.indexOf(u8, executable, token) != null);
    }
}

test "all production solver-like source requires explicit solver or support registration" {
    const io = std.testing.io;
    var source_dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer source_dir.close(io);
    var walker = try source_dir.walk(std.testing.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (sourcePathEqual(entry.path, "validation/vanilla_picard_regression_test.zig")) continue;
        const source = try source_dir.readFileAlloc(
            io,
            entry.path,
            std.testing.allocator,
            .limited(8 * 1024 * 1024),
        );
        defer std.testing.allocator.free(source);
        const executable = try executableSource(std.testing.allocator, source);
        defer std.testing.allocator.free(executable);
        const solver_markers = [_][]const u8{
            "picard_steps",
            "newtonPicard",
            "newtonPicardFiniteDifference",
            "andersonDepthOneCandidate",
            "andersonMixingRatio",
            "tryAcceptAndersonCandidate",
            "fixed_point",
            "fixedPoint",
        };
        var solver_like = false;
        for (solver_markers) |marker| {
            if (std.mem.indexOf(u8, executable, marker) != null) {
                solver_like = true;
                break;
            }
        }
        if (!solver_like) continue;
        var registered = false;
        var registered_solver = false;
        for (known_anderson_picard_solvers) |guard| {
            const relative = if (std.mem.startsWith(u8, guard.path, "src/")) guard.path[4..] else guard.path;
            if (sourcePathEqual(entry.path, relative)) {
                registered = true;
                registered_solver = true;
                break;
            }
        }
        if (!registered) for (registered_solver_support_files) |path| {
            if (sourcePathEqual(entry.path, path)) {
                registered = true;
                break;
            }
        };
        if (!registered) {
            std.debug.print(
                "VANILLA-PICARD REGRESSION GUARD: unregistered solver-like production source '{s}'.\n",
                .{entry.path},
            );
            return error.UnregisteredNonlinearSolverSource;
        }
        if (!registered_solver and std.mem.indexOf(u8, executable, "picard_steps +=") != null) {
            std.debug.print(
                "VANILLA-PICARD REGRESSION GUARD: support/caller file '{s}' owns a Picard iteration and must be promoted to the solver registry.\n",
                .{entry.path},
            );
            return error.NonlinearIterationHiddenInSupportFile;
        }
    }
}

test "raw fixed-point images cannot be published as converged solver state" {
    // A conservative F(x) image is useful for exact mass closure, but copying
    // it straight into production state is a vanilla Picard publication unless
    // F(x) itself has first passed an independent residual check.  This exact
    // source-tree guard covers the representation used by the vector
    // transport solvers; their table entries above also require the positive
    // publication-verification token.
    const forbidden = [_][]const u8{
        "@memcpy(state.amount_mol, fixed_point)",
        "@memcpy(amounts_g, fixed_point)",
        "state_update(grid, target,",
    };
    const io = std.testing.io;
    var source_dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer source_dir.close(io);
    var walker = try source_dir.walk(std.testing.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (sourcePathEqual(entry.path, "validation/vanilla_picard_regression_test.zig")) continue;
        const source = try source_dir.readFileAlloc(io, entry.path, std.testing.allocator, .limited(8 * 1024 * 1024));
        defer std.testing.allocator.free(source);
        const executable = try executableSource(std.testing.allocator, source);
        defer std.testing.allocator.free(executable);
        for (forbidden) |token| {
            if (std.mem.indexOf(u8, executable, token) != null) {
                std.debug.print(
                    "VANILLA-PICARD REGRESSION GUARD: raw fixed-point publication '{s}' in '{s}'.\n",
                    .{ token, entry.path },
                );
                return error.RawFixedPointPublication;
            }
        }
    }
}

test "solver policy scanner ignores comments and literals but retains code" {
    const source =
        \\// picard_steps += 1
        \\const message = "andersonDepthOneCandidate";
        \\/* nested /* picard_steps += 1 */ comment */
        \\picard_steps += 1;
    ;
    const executable = try executableSource(std.testing.allocator, source);
    defer std.testing.allocator.free(executable);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, executable, "picard_steps += 1"));
    try std.testing.expect(std.mem.indexOf(u8, executable, "andersonDepthOneCandidate") == null);
}

test "soil water policy remains Newton first with Anderson-only counted recovery" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/soil/water/solver_solve.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    // These tokens identify the removed raw-state repair, final-iteration
    // extrapolation, and unaccelerated residual-correction paths.
    for ([_][]const u8{
        "valid_aitken_candidate",
        "valid_secant_candidate",
        "scale_index < 29",
        "correction_fraction",
        "while (restoration < 12)",
    }) |forbidden| try std.testing.expect(std.mem.indexOf(u8, source, forbidden) == null);

    const newton = std.mem.indexOf(u8, source, "var dense_jacobian_valid") orelse
        return error.MissingSoilWaterNewtonPrimary;
    const recovery = std.mem.indexOf(u8, source, "var used_anderson") orelse
        return error.MissingSoilWaterAndersonRecovery;
    const ceiling = std.mem.indexOfPos(u8, source, recovery, "if (iteration + 1 >= options.max_iterations)") orelse
        return error.MissingSoilWaterAndersonRetryCeiling;
    const commit = std.mem.indexOfPos(u8, source, ceiling, "@memcpy(current, candidate)") orelse
        return error.MissingSoilWaterAndersonCommit;
    const counter = std.mem.indexOfPos(u8, source, commit, "picard_steps += 1") orelse
        return error.MissingSoilWaterAndersonCounter;
    try std.testing.expect(newton < recovery);
    try std.testing.expect(recovery < ceiling);
    try std.testing.expect(ceiling < commit);
    try std.testing.expect(commit < counter);
    try std.testing.expect(std.mem.indexOfPos(u8, source, recovery, "newton_steps += 1") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "picard_steps += 1"));
    try std.testing.expect(std.mem.indexOf(u8, source, "newton_retry_required = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (retrying_newton_after_anderson) continue") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (newton_retry_required) return error.SoilWaterSolverDidNotConverge") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "seed_fraction *= 0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "dampedAndersonStorageCandidate") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "andersonImprovesAcceptedMerit") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "seed_norm") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "options.maximum_newton_fraction > 1") != null);

    const newton_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/soil/water/solver_newton.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(newton_source);
    try std.testing.expect(std.mem.indexOf(u8, newton_source, "use_scaled_merit") == null);
    try std.testing.expect(std.mem.count(u8, newton_source, "group_residual.scaledNorm(") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, source, "progress_requires_anderson") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "std.math.sqrt(std.math.floatEps(f64))") != null);
}

test "shared scalar Anderson recovery requires a Newton retry slot" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/core/numerics.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const retry_skip = std.mem.indexOf(u8, source, "if (retrying_newton_after_anderson) continue") orelse
        return error.MissingScalarNewtonRetry;
    const retry_ceiling = std.mem.indexOfPos(u8, source, retry_skip, "if (updates + 1 >= options.max_iterations or") orelse
        return error.MissingScalarAndersonRetryCeiling;
    const shared_retry_slot = std.mem.indexOfPos(u8, source, retry_ceiling, "options.shared_budget.?.remaining() == 0") orelse
        return error.MissingScalarSharedBudgetRetryCeiling;
    const anderson_seed = std.mem.indexOfPos(u8, source, retry_ceiling, "const fixed_point = picardFn(context, x)") orelse
        return error.MissingScalarAndersonSeed;
    const seed_state = std.mem.indexOfPos(u8, source, anderson_seed, "const seed_x = std.math.clamp(") orelse
        return error.MissingScalarAndersonSeedState;
    const seed_map = std.mem.indexOfPos(u8, source, seed_state, "const seed_fixed_point = picardFn(context, seed_x)") orelse
        return error.MissingScalarAndersonSecondMapSample;
    const acceleration = std.mem.indexOfPos(u8, source, seed_map, "const accelerated = seed_x - mixing * (seed_x - x)") orelse
        return error.MissingScalarAndersonAcceleration;
    const accepted_merit = std.mem.indexOfPos(u8, source, acceleration, "var best_anderson_residual = current_residual") orelse
        return error.MissingScalarAcceptedStateMerit;
    const anderson_commit = std.mem.indexOfPos(u8, source, accepted_merit, "x = next_x") orelse
        return error.MissingScalarAndersonCommit;
    const counter = std.mem.indexOfPos(u8, source, anderson_commit, "anderson_steps += 1") orelse
        return error.MissingScalarAndersonCounter;
    const retry_required = std.mem.indexOfPos(u8, source, counter, "newton_retry_required = true") orelse
        return error.MissingScalarNewtonRetryArm;
    const final_guard = std.mem.indexOfPos(u8, source, retry_required, "if (newton_retry_required) {") orelse
        return error.MissingScalarFinalRetryGuard;
    try std.testing.expect(retry_skip < retry_ceiling);
    try std.testing.expect(retry_ceiling < shared_retry_slot);
    try std.testing.expect(shared_retry_slot < anderson_seed);
    try std.testing.expect(anderson_seed < seed_state);
    try std.testing.expect(seed_state < seed_map);
    try std.testing.expect(seed_map < acceleration);
    try std.testing.expect(acceleration < accepted_merit);
    try std.testing.expect(accepted_merit < anderson_commit);
    try std.testing.expect(anderson_commit < counter);
    try std.testing.expect(counter < retry_required);
    try std.testing.expect(retry_required < final_guard);

    // The relaxed seed is a private second map sample, never an acceptance
    // incumbent or directly publishable state. Only a line-searched Anderson
    // candidate competes with the accepted current residual.
    const recovery = source[anderson_seed..retry_required];
    try std.testing.expect(std.mem.indexOf(u8, recovery, "seed_absolute_residual") == null);
    try std.testing.expect(std.mem.indexOf(u8, recovery, "x = seed_x") == null);
    try std.testing.expect(std.mem.indexOf(u8, recovery, "next_x = seed_x") == null);
    try std.testing.expect(std.mem.indexOf(u8, recovery, "next_x = candidate") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovery, "* absolute_residual") != null);
}

test "water-energy vector cluster requires fail-closed Anderson retry policy" {
    const files = [_][]const u8{
        "src/soil/heat/solver_solve.zig",
        "src/soil/water/phase_solver.zig",
        "src/soil/gas/vapor_solver.zig",
        "src/soil/water/snow_transport_solver.zig",
        "src/soil/water/snow_phase_change.zig",
    };
    for (files) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(2 * 1024 * 1024),
        );
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "newton_retry_required") != null or
            std.mem.indexOf(u8, source, "retry_required") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "retrying_newton_after_anderson") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "std.math.sqrt(std.math.floatEps(f64))") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "picard_steps += 1") != null);
    }

    const bounded_vector_files = [_][]const u8{
        "src/soil/heat/solver_solve.zig",
        "src/soil/water/phase_solver.zig",
        "src/soil/gas/vapor_solver.zig",
        "src/soil/water/snow_transport_solver.zig",
    };
    for (bounded_vector_files) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(2 * 1024 * 1024));
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "maximum_newton_fraction > 1") != null);
        if (std.mem.eql(u8, path, "src/soil/heat/solver_solve.zig")) {
            const recovery_start = std.mem.indexOf(u8, source, "var best_anderson_norm = norm") orelse
                return error.MissingHeatAcceptedStateMerit;
            const seed_map = std.mem.indexOfPos(u8, source, recovery_start, "exactEnthalpyPicardImage(") orelse
                return error.MissingHeatPrivatePicardMapSample;
            const acceleration = std.mem.indexOfPos(u8, source, seed_map, "andersonDepthOneCandidate(") orelse
                return error.MissingHeatAndersonAcceleration;
            const pricing = std.mem.indexOfPos(u8, source, acceleration, "priceAndersonDirection(") orelse
                return error.MissingHeatAndersonPricing;
            const reject = std.mem.indexOfPos(u8, source, pricing, "if (!used_anderson) {") orelse
                return error.MissingHeatAndersonRejectionGate;
            const speculative_exception = std.mem.indexOfPos(u8, source, reject, "if (slow_progress_requires_anderson and !progress_requires_anderson)") orelse
                return error.MissingHeatSpeculativeRecoveryException;
            const replay_arm = std.mem.indexOfPos(u8, source, speculative_exception, "speculative_newton_replay = true") orelse
                return error.MissingHeatSpeculativeNewtonReplay;
            // Genuine measured stagnation is classified in the loop and
            // raised at the solver's single terminal return, so the
            // diagnostics and the best-state physical audit can run first.
            // The classification is only fail-closed if that terminal switch
            // still maps it to the fatal error, which is asserted below.
            const terminal_stagnation = std.mem.indexOfPos(u8, source, replay_arm, "terminal_reason = .stagnated") orelse
                return error.MissingHeatGenuineStagnationTerminal;
            if (std.mem.indexOfPos(u8, source, terminal_stagnation, ".stagnated => error.SoilHeatSolverStagnated") == null)
                return error.MissingHeatGenuineStagnationTerminalError;
            const commit = std.mem.indexOfPos(u8, source, terminal_stagnation, "@memcpy(current, candidate)") orelse
                return error.MissingHeatAndersonCommit;
            const anderson_counter = std.mem.indexOfPos(u8, source, commit, "anderson_steps += 1") orelse
                return error.MissingHeatAndersonCounter;
            const picard_counter = std.mem.indexOfPos(u8, source, anderson_counter, "picard_steps += 1") orelse
                return error.MissingHeatCompatibilityCounter;
            const retry_arm = std.mem.indexOfPos(u8, source, picard_counter, "newton_retry_required = true") orelse
                return error.MissingHeatNewtonRetryArm;
            try std.testing.expect(recovery_start < seed_map);
            try std.testing.expect(seed_map < acceleration);
            try std.testing.expect(acceleration < pricing);
            try std.testing.expect(pricing < reject);
            try std.testing.expect(reject < speculative_exception);
            try std.testing.expect(speculative_exception < replay_arm);
            try std.testing.expect(replay_arm < terminal_stagnation);
            try std.testing.expect(terminal_stagnation < commit);
            try std.testing.expect(commit < anderson_counter);
            try std.testing.expect(anderson_counter < picard_counter);
            try std.testing.expect(picard_counter < retry_arm);

            // The raw/exact seed remains history-only: it cannot lower the
            // publishable merit incumbent or reach `current` before a priced
            // Anderson proposal has passed the rejection gate.
            const recovery = source[recovery_start..retry_arm];
            try std.testing.expect(std.mem.indexOf(u8, recovery, "seed_norm") == null);
            try std.testing.expect(std.mem.indexOf(u8, recovery, "@min(best_anderson_norm") == null);
            try std.testing.expect(std.mem.indexOf(u8, source[recovery_start..reject], "@memcpy(current, candidate)") == null);

            // Forecast-only recovery may probe Anderson and retry ordinary
            // Newton in the next counted slot. That retry must bypass
            // bookkeeping and recovery gates exactly once; genuine measured
            // stagnation still reaches the terminal classification above.
            try std.testing.expect(std.mem.indexOf(u8, source, "retain_iteration_for_speculative_replay") == null);
            try std.testing.expect(std.mem.indexOf(u8, source, "while (iteration < options.max_iterations) : (iteration += 1)") != null);
            const replay_capture = std.mem.indexOf(u8, source, "const replaying_speculative_newton = speculative_newton_replay") orelse
                return error.MissingHeatSpeculativeReplayCapture;
            const bookkeeping_guard = std.mem.indexOfPos(u8, source, replay_capture, "if (!replaying_speculative_newton) {") orelse
                return error.MissingHeatSpeculativeBookkeepingGuard;
            const newton_replay_bypass = std.mem.indexOfPos(u8, source, bookkeeping_guard, "if (!replaying_speculative_newton and") orelse
                return error.MissingHeatSpeculativeNewtonBypass;
            try std.testing.expect(replay_capture < bookkeeping_guard);
            try std.testing.expect(bookkeeping_guard < newton_replay_bypass);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, source, "andersonImprovesAcceptedMerit") != null);
            try std.testing.expect(std.mem.indexOf(u8, source, "seed_norm") == null);
            try std.testing.expect(std.mem.indexOf(u8, source, "relaxed_norm") == null);
        }
    }
}

test "WATSUB snow vapor equilibrium remains one frozen-entry explicit evaluation" {
    const equilibrium_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/soil/water/snow_vapor_equilibrium.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(equilibrium_source);
    const executable_equilibrium = try executableSource(std.testing.allocator, equilibrium_source);
    defer std.testing.allocator.free(executable_equilibrium);
    const explicit_call = std.mem.indexOf(u8, executable_equilibrium, "const transfer = try explicitTransfer(") orelse
        return error.MissingExplicitSnowVaporTransfer;
    try std.testing.expect(std.mem.indexOfPos(
        u8,
        executable_equilibrium,
        explicit_call,
        "temperature[index]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, executable_equilibrium, "andersonAcceleratedTransfer") == null);
    try std.testing.expect(std.mem.indexOf(u8, executable_equilibrium, "candidateAt(") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        equilibrium_source,
        "test \"explicit snow vapor transfer uses frozen entry temperature and exact donor caps\"",
    ) != null);

    const stage_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(stage_source);
    const executable_stage = try executableSource(std.testing.allocator, stage_source);
    defer std.testing.allocator.free(executable_stage);
    const fused_owner = std.mem.indexOf(u8, executable_stage, "fn advanceSourceOrderedSnowPhysics(") orelse
        return error.MissingSourceOrderedSnowOwner;
    const fused_end = std.mem.indexOfPos(u8, executable_stage, fused_owner, "fn advanceSnowBeforeSoil(") orelse
        return error.MissingSourceOrderedSnowOwnerEnd;
    const fused = executable_stage[fused_owner..fused_end];
    const layer_loop = std.mem.indexOf(u8, fused, "for (0..capacity) |local_layer|") orelse
        return error.MissingSourceOrderedSnowLayerLoop;
    const melt = std.mem.indexOfPos(u8, fused, layer_loop, "snow_melt_water_routing.calculate") orelse
        return error.MissingSourceOrderedSnowMelt;
    const conduction = std.mem.indexOfPos(u8, fused, melt, "snow_heat_conduction.solve") orelse
        return error.MissingSourceOrderedSnowConduction;
    const diffusion = std.mem.indexOfPos(u8, fused, conduction, "snow_vapor_diffusion.solve") orelse
        return error.MissingSourceOrderedSnowVaporDiffusion;
    const face_mass = std.mem.indexOfPos(u8, fused, diffusion, "liquid_water_volume_m3[source] -= liquid_to_lower") orelse
        return error.MissingSourceOrderedSnowFaceMass;
    const equilibrium = std.mem.indexOfPos(u8, fused, face_mass, "snow_vapor_equilibrium.explicitTransfer") orelse
        return error.MissingSourceOrderedSnowVaporEquilibrium;
    const phase = std.mem.indexOfPos(u8, fused, equilibrium, "snow_phase_change.solve") orelse
        return error.MissingSourceOrderedSnowPhase;
    const replay = std.mem.indexOfPos(u8, fused, phase, "snow_source_order_energy.apply") orelse
        return error.MissingSourceOrderedSnowReplay;
    // Melt, conduction and vapor are all valued before any face mass moves;
    // explicit equilibrium and Newton/Anderson/Newton phase then close the
    // local layer, and the independent replay is the sole final commit.
    try std.testing.expect(melt < conduction);
    try std.testing.expect(conduction < diffusion);
    try std.testing.expect(diffusion < face_mass);
    try std.testing.expect(face_mass < equilibrium);
    try std.testing.expect(equilibrium < phase);
    try std.testing.expect(phase < replay);
}

test "chemistry vector cluster keeps private seed out of merit and requires Newton retry" {
    const files = [_][]const u8{
        "src/soil/gas/aqueous_extensive_transport.zig",
        "src/soil/organic/transport.zig",
        "src/soil/solute/transport_solver.zig",
        "src/soil/solute/reaction_solve.zig",
        "src/surface/litter_chemistry_solve.zig",
        "src/plant/root/plant_root_salt_exchange.zig",
        "src/surface/litter_reaction_rates.zig",
        "src/soil/gas/coupled_gas_solver_solve.zig",
    };
    for (files) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(2 * 1024 * 1024),
        );
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "newton_retry_required") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "retrying_newton_after_anderson") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "seed_norm") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "relaxed_norm") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "andersonImprovesAcceptedMerit") != null);
        // `reaction_solve.zig` publishes through the documented physical
        // endpoint gate (`docs/chemical_endpoint_acceptance.md`) instead of a
        // residual/retry schedule, so Anderson may be priced inside the last
        // permitted iteration: no endpoint -- Newton or Anderson -- can reach
        // production state without independently clearing that gate. Its
        // scheduling anchor is the remaining-budget-aware Anderson entry gate,
        // and the fail-closed replacement is asserted positively below rather
        // than assumed.
        const physical_endpoint_acceptance =
            std.mem.eql(u8, path, "src/soil/solute/reaction_solve.zig");
        if (!physical_endpoint_acceptance)
            try std.testing.expect(std.mem.indexOf(u8, source, "+ 1 >= options.max_iterations") != null);
        if (!std.mem.eql(u8, path, "src/soil/gas/coupled_gas_solver_solve.zig"))
            try std.testing.expect(std.mem.indexOf(u8, source, "std.math.sqrt(std.math.floatEps(f64))") != null);
        const retry = std.mem.indexOf(u8, source, "const retrying_newton_after_anderson") orelse
            return error.MissingChemistryNewtonRetryPhase;
        const retry_gate = std.mem.indexOfPos(u8, source, retry, "if (retrying_newton_after_anderson") orelse
            return error.MissingChemistryNewtonRetryGate;
        const retry_ceiling = if (physical_endpoint_acceptance) anchor: {
            // Both the in-loop and the final-budget acceptance paths must be
            // gated on the physical quality score, and every other exit must
            // still be a fatal classification.
            for ([_][]const u8{
                "if (physical_norm <= 1) {",
                "const accepted_final_norm = if (final_physical_norm <= 1)",
                "requirePhysicalReactionBalance(",
                "return error.SoluteReactionSolverStagnated;",
                "return error.SoluteReactionSolverDiverged;",
                "return error.SoluteReactionSolverDidNotConverge;",
            }) |token| {
                if (std.mem.indexOf(u8, source, token) == null)
                    return error.MissingChemistryPhysicalEndpointFailClosedGate;
            }
            const gate = std.mem.indexOfPos(
                u8,
                source,
                retry_gate,
                "if (progress_requires_anderson or andersonTierEnabled(",
            ) orelse return error.MissingChemistryAndersonEntryGate;
            if (std.mem.indexOfPos(u8, source, gate, "options.max_iterations - iteration,") == null)
                return error.MissingChemistryAndersonRemainingBudgetArgument;
            break :anchor gate;
        } else std.mem.indexOfPos(u8, source, retry_gate, "+ 1 >= options.max_iterations") orelse
            return error.MissingChemistryAndersonRetryCeiling;
        const accepted_merit_token: []const u8 = if (std.mem.eql(u8, path, "src/soil/solute/reaction_solve.zig"))
            "retainMeaningfulAndersonCandidate("
        else if (std.mem.eql(u8, path, "src/surface/litter_chemistry_solve.zig"))
            "dampedAndersonCandidate("
        else
            "andersonImprovesAcceptedMerit";
        const accepted_merit = std.mem.indexOfPos(u8, source, retry_ceiling, accepted_merit_token) orelse
            return error.MissingChemistryAcceptedStateMerit;
        const retry_arm = std.mem.indexOfPos(u8, source, accepted_merit, "newton_retry_required = true") orelse
            return error.MissingChemistryNewtonRetryArm;
        try std.testing.expect(retry < retry_gate);
        try std.testing.expect(retry_gate < retry_ceiling);
        try std.testing.expect(retry_ceiling < accepted_merit);
        try std.testing.expect(accepted_merit < retry_arm);
    }

    const bounded_option_files = [_][]const u8{
        "src/soil/solute/transport_solver.zig",
        "src/soil/solute/reaction_solver_solve.zig",
        "src/surface/litter_chemistry_struct_arithmetic.zig",
    };
    for (bounded_option_files) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(2 * 1024 * 1024));
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "maximum_newton_fraction > 1") != null);
    }
}

test "surface litter active path has one aggregate ceiling and no bracket publication" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const solve = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/surface/litter_chemistry_solve.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(solve);
    const ammonium = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/surface/litter_chemistry_ammonium.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(ammonium);
    const phosphate = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/surface/litter_chemistry_phosphate_minerals.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(phosphate);
    const fixed = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/surface/litter_chemistry_fixed_phosphate.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(fixed);

    const solve_start = std.mem.indexOf(u8, solve, "pub fn solveCell(") orelse
        return error.MissingSurfaceLitterSolveEntry;
    const solve_end = std.mem.indexOfPos(u8, solve, solve_start, "const final_changes") orelse
        return error.MissingSurfaceLitterSolveExit;
    const active_solve = solve[solve_start..solve_end];
    const candidate_start = std.mem.indexOf(u8, solve, "noinline fn tryNewtonCandidate(") orelse
        return error.MissingSurfaceLitterNewtonCandidateHelper;
    const candidate_end = std.mem.indexOfPos(
        u8,
        solve,
        candidate_start,
        "/// Applies the surface-litter SOLUTE rates for one physical subhour.",
    ) orelse return error.MissingSurfaceLitterNewtonCandidateHelperExit;
    const candidate_solve = solve[candidate_start..candidate_end];
    const forbidden_publications = [_][]const u8{
        "conservativePhosphateNewton(",
        "resolveIncompatibleFixedPhosphateSolids(",
        "accelerateFixedPhosphateCationBounds(",
        "equilibrate_exchange(evaluator.context, current)",
        "lower + 0.5 * (upper - lower)",
    };
    for (forbidden_publications) |token| {
        try std.testing.expect(std.mem.indexOf(u8, active_solve, token) == null);
        try std.testing.expect(std.mem.indexOf(u8, candidate_solve, token) == null);
    }
    const required_newton_candidates = [_][]const u8{
        "conservativePhosphateActiveReactionSolve(",
        "conservativeAmmoniumAssociationSolve(",
    };
    for (required_newton_candidates) |token|
        try std.testing.expect(std.mem.indexOf(u8, candidate_solve, token) != null);
    const required_policy = [_][]const u8{
        "try budget.beginIteration()",
        "try tryNewtonCandidate(",
        "andersonMixingRatio(",
        "newton_retry_required = true",
        "if (retrying_newton_after_anderson)",
    };
    for (required_policy) |token|
        try std.testing.expect(std.mem.indexOf(u8, active_solve, token) != null);

    // Each specialized helper proposes at most one damped Newton update. It
    // must not hide a second max-iteration or bracket solve under the outer,
    // shared iteration budget.
    const helper_forbidden = [_][]const u8{
        "while (iteration < options.max_iterations)",
        "while (search < options.max_iterations)",
        "lower + 0.5 * (upper - lower)",
        "bracketPhosphateReactionRoot(",
    };
    for (helper_forbidden) |token| {
        try std.testing.expect(std.mem.indexOf(u8, ammonium, token) == null);
        try std.testing.expect(std.mem.indexOf(u8, phosphate, token) == null);
    }

    const active_set_start = std.mem.indexOf(u8, fixed, "pub fn conservativeFixedPhosphateActiveSetNewton(") orelse
        return error.MissingFixedPhosphateActiveSetNewton;
    const active_set_end = std.mem.indexOfPos(u8, fixed, active_set_start, "fn mineralIsActive(") orelse
        return error.MissingFixedPhosphateActiveSetNewtonEnd;
    const complementarity_end = std.mem.indexOfPos(u8, fixed, active_set_end, "fn fixedPhosphateCoordinates(") orelse
        return error.MissingFixedPhosphateComplementarityNewtonEnd;
    const active_fixed = fixed[active_set_start..complementarity_end];
    try std.testing.expect(std.mem.indexOf(u8, active_fixed, "while (search < options.max_iterations)") == null);
    try std.testing.expect(std.mem.indexOf(u8, active_fixed, "candidate_norm <= 10 * current_norm") == null);
    try std.testing.expect(std.mem.indexOf(u8, active_fixed, "while (iteration < 1)") != null);
}

test "coupled gas slow-progress gate preserves mandatory Newton retry" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/soil/gas/coupled_gas_solver_solve.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    const loop = std.mem.indexOf(u8, source, "while (iteration < options.max_iterations)") orelse
        return error.MissingCoupledGasIterationLoop;
    const retry_phase = std.mem.indexOfPos(u8, source, loop, "const retrying_newton_after_anderson = newton_retry_required") orelse
        return error.MissingCoupledGasRetryPhase;
    const slow_watch = std.mem.indexOfPos(u8, source, retry_phase, "coupledGasSlowProgressExceededPatience(") orelse
        return error.MissingCoupledGasSlowProgressWatch;
    const retry_argument = std.mem.indexOfPos(u8, source, slow_watch, "retrying_newton_after_anderson,") orelse
        return error.MissingCoupledGasSlowProgressRetryExemption;
    const newton_attempt = std.mem.indexOfPos(u8, source, retry_argument, "events.append(.newton_attempt)") orelse
        return error.MissingCoupledGasNewtonAttempt;
    const retry_gate = std.mem.indexOfPos(u8, source, newton_attempt, "if (retrying_newton_after_anderson)") orelse
        return error.MissingCoupledGasPostAndersonNewtonRetryGate;
    try std.testing.expect(retry_phase < slow_watch);
    try std.testing.expect(slow_watch < retry_argument);
    try std.testing.expect(retry_argument < newton_attempt);
    try std.testing.expect(newton_attempt < retry_gate);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source[loop..newton_attempt],
        "if (slow_progress_count >= 4) return error.CoupledGasSolverStagnated",
    ) == null);
}

fn sourcePathEqual(actual: []const u8, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |actual_byte, expected_byte| {
        const normalized = if (actual_byte == '\\') '/' else actual_byte;
        if (normalized != expected_byte) return false;
    }
    return true;
}

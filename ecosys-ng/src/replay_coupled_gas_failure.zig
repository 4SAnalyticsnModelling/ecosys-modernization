const std = @import("std");
const builtin = @import("builtin");
const ecosys = @import("ecosys_ng");

/// Replays one self-contained pre-solve coupled-gas failure snapshot.
pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (comptime builtin.mode == .Debug) _ = debug_allocator.deinit();
    }
    const allocator = if (comptime builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 6) {
        std.log.err(
            "usage: ecosys_ng_replay_gas <ecosys-ng-gas-failure-*.bin> [max_iterations] [krylov_restart_max] [krylov_relative_tolerance] [local_preconditioner]",
            .{},
        );
        return error.MissingCoupledGasFailureSnapshotPath;
    }
    // An explicit ceiling exists so the minimum sufficient iteration budget for
    // a real captured state can be measured. It only ever *lowers* the recorded
    // ceiling below what the snapshot carries: a replay may not manufacture
    // headroom the failing production solve did not have, because that would
    // turn a diagnosis into the very "widen the ceiling" move the migration
    // rules forbid.
    const requested_ceiling: ?u16 = if (args.len >= 3)
        std.fmt.parseInt(u16, args[2], 10) catch
            return error.InvalidCoupledGasReplayIterationCeiling
    else
        null;
    const requested_krylov_restart: ?usize = if (args.len >= 4)
        std.fmt.parseInt(usize, args[3], 10) catch
            return error.InvalidCoupledGasReplayKrylovRestart
    else
        null;
    const requested_krylov_tolerance: ?f64 = if (args.len >= 5)
        std.fmt.parseFloat(f64, args[4]) catch
            return error.InvalidCoupledGasReplayKrylovTolerance
    else
        null;
    const use_local_krylov_preconditioner = if (args.len == 6)
        std.mem.eql(u8, args[5], "true") or
            if (std.mem.eql(u8, args[5], "false")) false else return error.InvalidCoupledGasReplayPreconditioner
    else
        true;
    if (requested_krylov_tolerance) |tolerance| {
        if (!std.math.isFinite(tolerance) or tolerance <= 0 or tolerance >= 1)
            return error.InvalidCoupledGasReplayKrylovTolerance;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(256 * 1024 * 1024),
    );
    defer allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var replay_case = try ecosys.coupled_gas_failure_snapshot.read(
        allocator,
        &reader,
        .{},
    );
    defer replay_case.deinit();
    var options = ecosys.coupled_gas_failure_reporter.replayOptions(replay_case.options);
    if (options.maximum_newton_fraction > 1) {
        std.log.warn(
            "coupled gas replay snapshot uses retired super-unit Newton fraction: captured={e} replayed={e}",
            .{ options.maximum_newton_fraction, 1.0 },
        );
        options.maximum_newton_fraction = 1;
    }
    if (requested_ceiling) |ceiling| {
        if (ceiling == 0 or ceiling > replay_case.options.max_iterations) {
            std.log.err(
                "requested replay ceiling must be within the captured ceiling: requested={d} captured={d}",
                .{ ceiling, replay_case.options.max_iterations },
            );
            return error.InvalidCoupledGasReplayIterationCeiling;
        }
        options.max_iterations = ceiling;
    }
    if (requested_krylov_restart) |restart| {
        if (restart == 0 or restart > 64)
            return error.InvalidCoupledGasReplayKrylovRestart;
        options.krylov_restart_max = restart;
    }
    if (requested_krylov_tolerance) |tolerance|
        options.krylov_relative_tolerance = tolerance;
    options.use_local_krylov_preconditioner = use_local_krylov_preconditioner;
    std.log.info(
        "coupled gas replay options: absolute_tolerance_g={e} relative_tolerance={e} picard_relaxation={e} directional_probe_fraction={e} minimum_newton_fraction={e} maximum_newton_fraction={e} divergence_patience={d} divergence_growth_factor={e} transport_iteration_fraction={e} max_iterations={d} accept_physically_conserved_ceiling={} krylov_restart_max={d} krylov_relative_tolerance={e} local_preconditioner={}",
        .{
            options.absolute_tolerance_g,
            options.relative_tolerance,
            options.picard_relaxation,
            options.directional_probe_fraction,
            options.minimum_newton_fraction,
            options.maximum_newton_fraction,
            options.divergence_patience,
            options.divergence_growth_factor,
            options.transport_iteration_fraction,
            options.max_iterations,
            options.accept_physically_conserved_ceiling,
            options.krylov_restart_max,
            options.krylov_relative_tolerance,
            options.use_local_krylov_preconditioner,
        },
    );
    // An archived version 1 snapshot did not record the REDIST bubble receiver
    // map, so the replayed system releases bubbles into the source cell. Say so
    // on every line, in both the success and failure paths, so no report can
    // cite a v1 replay as faithful evidence about bubbling without noticing.
    const bubbling_fidelity = if (replay_case.bubble_receiver_map_captured)
        "captured"
    else
        "not-captured-v1-source-cell-default";
    if (!replay_case.bubble_receiver_map_captured) {
        var any_bubbling = false;
        for (replay_case.bubbling_enabled) |enabled| any_bubbling = any_bubbling or enabled;
        if (any_bubbling) std.log.warn(
            "coupled gas replay snapshot predates bubble receiver capture: snapshot={s} bubbling_cells_present=true replayed_destination=source_cell",
            .{args[1]},
        );
    }
    const solve_started = std.Io.Clock.now(.boot, init.io);
    const result = ecosys.coupled_gas_solver.solve(
        allocator,
        &replay_case.state,
        ecosys.coupled_gas_failure_reporter.replayInputs(&replay_case),
        options,
    ) catch |err| {
        std.log.err(
            "coupled gas replay failed reproducibly: snapshot={s} cells={d} faces={d} max_iterations={d} bubble_receiver_map={s} error={s}",
            .{
                args[1],
                replay_case.state.cell_count,
                replay_case.faces.len,
                options.max_iterations,
                bubbling_fidelity,
                @errorName(err),
            },
        );
        return err;
    };
    const solve_elapsed = solve_started.durationTo(std.Io.Clock.now(.boot, init.io));
    std.log.info(
        "coupled gas replay converged: snapshot={s} cells={d} unknowns={d} iterations={d} newton_steps={d} picard_steps={d} initial_maximum_scaled_residual={e} maximum_scaled_residual={e} dense_jacobian_assemblies={d} dense_jacobian_reuses={d} krylov_direction_calls={d} krylov_iterations={d} solve_elapsed_ns={d} max_iterations={d} bubble_receiver_map={s}",
        .{
            args[1],
            replay_case.state.cell_count,
            replay_case.state.gaseous_mass_g.len * 3,
            result.iterations,
            result.newton_raphson_steps,
            result.picard_steps,
            result.initial_maximum_scaled_residual,
            result.maximum_scaled_residual,
            result.dense_full_jacobian_assemblies,
            result.dense_full_jacobian_reuses,
            result.krylov_direction_calls,
            result.krylov_iterations,
            solve_elapsed.nanoseconds,
            options.max_iterations,
            bubbling_fidelity,
        },
    );
}

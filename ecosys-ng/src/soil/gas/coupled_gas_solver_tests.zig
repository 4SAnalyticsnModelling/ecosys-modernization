//! `coupled_gas_solver` declarations: tests.
//!
//! Split out of `coupled_gas_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const gas = @import("transport.zig");
const atmosphere = @import("atmosphere_exchange.zig");
const numerics = @import("../../core/numerics.zig");
const group_diagnostics = @import("coupled_gas_solver_diagnostics.zig");
const group_directions = @import("coupled_gas_solver_directions.zig");
const group_misc = @import("coupled_gas_solver_misc.zig");
const group_validation = @import("coupled_gas_solver_validation.zig");

fn readCoupledGasSolverSolveSource() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/soil/gas/coupled_gas_solver_solve.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
}

test {
    // Reach private solve-ordering regressions from the normal test root.
    _ = @import("coupled_gas_solver_solve.zig");
}

test "coupled gas primary Newton eligibility and order ignore the iteration ceiling" {
    const source = try readCoupledGasSolverSolveSource();
    defer std.testing.allocator.free(source);
    const primary_start = std.mem.indexOf(
        u8,
        source,
        "newton_attempts: {",
    ) orelse return error.MissingCoupledGasNewtonSchedule;
    const recovery_start = std.mem.indexOfPos(
        u8,
        source,
        primary_start,
        "if (retrying_newton_after_anderson) {",
    ) orelse return error.MissingCoupledGasRecoveryBoundary;
    const primary = source[primary_start..recovery_start];

    // `max_iterations` may price the bounded contraction forecast before the
    // primary block, but it cannot enable a Newton family or reroute an
    // accepted Newton state within an entered slot.
    const forecast_start = std.mem.indexOf(
        u8,
        source,
        "const remaining_updates = options.max_iterations - iteration;",
    ) orelse return error.MissingCoupledGasSlowProgressBudget;
    try std.testing.expect(forecast_start < primary_start);
    const forecast = source[forecast_start..primary_start];
    try std.testing.expect(std.mem.indexOf(
        u8,
        forecast,
        "remaining_updates >= 2",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        forecast,
        "remaining_updates <= slow_newton_recovery_reserve",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        forecast,
        "slowNewtonProgressNeedsRecovery(",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        primary,
        "progress_requires_anderson or\n                slow_progress_requires_anderson",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, primary, "max_iterations") == null);
    try std.testing.expect(std.mem.indexOf(u8, primary, "acceptedNewtonTailRequiresRecovery") == null);

    const multi_species = std.mem.indexOf(
        u8,
        primary,
        "conservativeMultiSpeciesFaceNewtonStep(",
    ) orelse return error.MissingCoupledGasMultiSpeciesNewton;
    const scalar_face = std.mem.indexOf(
        u8,
        primary,
        "conservativeFaceNewtonStep(",
    ) orelse return error.MissingCoupledGasScalarFaceNewton;
    const active_set = std.mem.indexOf(
        u8,
        primary,
        "activeSetGasNewtonStep(",
    ) orelse return error.MissingCoupledGasActiveSetNewton;
    const dense = std.mem.indexOf(
        u8,
        primary,
        "const use_full_dense",
    ) orelse return error.MissingCoupledGasDenseNewton;
    try std.testing.expect(multi_species < scalar_face);
    try std.testing.expect(scalar_face < active_set);
    try std.testing.expect(active_set < dense);
}

test "production gas owners explicitly enable bounded physical publication" {
    inline for (.{
        "src/stages/hourly_heat_water_solute.zig",
        "src/stages/hourly_gas_surface_water.zig",
    }) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(4 * 1024 * 1024),
        );
        defer std.testing.allocator.free(source);
        const advance = std.mem.indexOf(u8, source, "soil_gas_transport.advance(") orelse
            return error.MissingProductionSoilGasOwner;
        const failure_report = std.mem.indexOfPos(u8, source, advance, ".failure_report") orelse
            return error.MissingProductionSoilGasFailureBoundary;
        const opt_in = std.mem.indexOfPos(
            u8,
            source,
            advance,
            ".accept_physically_conserved_ceiling = true",
        ) orelse return error.MissingProductionSoilGasPhysicalPublicationOptIn;
        try std.testing.expect(opt_in < failure_report);
    }

    const litter_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_sediment.zig",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(litter_source);
    const litter_advance = std.mem.indexOf(
        u8,
        litter_source,
        "surface_litter_gas_transport.advanceWithFailureReport(",
    ) orelse return error.MissingProductionLitterGasOwner;
    const litter_boundary = std.mem.indexOfPos(
        u8,
        litter_source,
        litter_advance,
        "if (diagnostic_first_hour)",
    ) orelse return error.MissingProductionLitterGasBoundary;
    const litter_opt_in = std.mem.indexOfPos(
        u8,
        litter_source,
        litter_advance,
        ".accept_physically_conserved_ceiling = true",
    ) orelse return error.MissingProductionLitterGasPhysicalPublicationOptIn;
    const litter_failure_report = std.mem.indexOfPos(
        u8,
        litter_source,
        litter_opt_in,
        "gas_failure_report,",
    ) orelse return error.MissingProductionLitterGasFailureBoundary;
    try std.testing.expect(litter_opt_in < litter_failure_report and litter_failure_report < litter_boundary);
}

test "coupled gas Krylov restart keeps large-grid workspace linear" {
    const options: group_misc.Options = .{
        .max_iterations = 20,
        .krylov_restart_max = 12,
    };
    try std.testing.expectEqual(
        @as(usize, 3),
        try group_directions.krylovRestartLength(
            9,
            1,
            true,
            options.krylov_restart_max,
        ),
    );

    const large_unknowns: usize = 21 * 20_000;
    const restart = try group_directions.krylovRestartLength(
        large_unknowns,
        20_000,
        true,
        options.krylov_restart_max,
    );
    try std.testing.expectEqual(@as(usize, 12), restart);
    try std.testing.expectEqual(
        (restart + 1) * large_unknowns,
        13 * large_unknowns,
    );
}

test "coupled gas preflight rejects malformed and nonphysical state" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.temperature_k[0] = 293.15;
    try group_validation.validate(&state, group_validation.validationTestInputs(), .{ .max_iterations = 1 });
    try std.testing.expectError(
        error.InvalidCoupledGasSolverOptions,
        group_validation.validate(
            &state,
            group_validation.validationTestInputs(),
            .{ .max_iterations = 1, .krylov_restart_max = 0 },
        ),
    );
    try std.testing.expectError(
        error.InvalidCoupledGasSolverOptions,
        group_validation.validate(
            &state,
            group_validation.validationTestInputs(),
            .{
                .max_iterations = 1,
                .krylov_restart_max = group_misc.maximum_krylov_restart + 1,
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidCoupledGasSolverOptions,
        group_validation.validate(
            &state,
            group_validation.validationTestInputs(),
            .{ .max_iterations = 1, .krylov_relative_tolerance = 0 },
        ),
    );
    try std.testing.expectError(
        error.InvalidCoupledGasSolverOptions,
        group_validation.validate(
            &state,
            group_validation.validationTestInputs(),
            .{ .max_iterations = 1, .krylov_relative_tolerance = 1 },
        ),
    );

    const complete_masses = state.gaseous_mass_g;
    state.gaseous_mass_g = complete_masses[0 .. complete_masses.len - 1];
    try std.testing.expectError(error.CoupledGasStateSizeMismatch, group_validation.validate(&state, group_validation.validationTestInputs(), .{ .max_iterations = 1 }));
    state.gaseous_mass_g = complete_masses;

    state.gaseous_mass_g[0] = std.math.nan(f64);
    try std.testing.expectError(error.NonFiniteGasTransportState, group_validation.validate(&state, group_validation.validationTestInputs(), .{ .max_iterations = 1 }));
    state.gaseous_mass_g[0] = -1;
    try std.testing.expectError(error.NegativeGasTransportState, group_validation.validate(&state, group_validation.validationTestInputs(), .{ .max_iterations = 1 }));
    state.gaseous_mass_g[0] = 0;
    state.temperature_k[0] = 0;
    try std.testing.expectError(error.InvalidGasTransportTemperature, group_validation.validate(&state, group_validation.validationTestInputs(), .{ .max_iterations = 1 }));
}

test "coupled gas preflight validates topology conductance and boundaries" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.temperature_k[0] = 293.15;
    const self_face = [_]gas.Face{.{ .first_cell = 0, .second_cell = 0 }};
    const conductance = [_]f64{0} ** gas.species_count;
    var inputs = group_validation.validationTestInputs();
    inputs.faces = &self_face;
    inputs.face_conductance_m3_per_step = &conductance;
    try std.testing.expectError(error.InvalidGasTransportFace, group_validation.validate(&state, inputs, .{ .max_iterations = 1 }));

    const invalid_conductance = [_]f64{-1} ** gas.species_count;
    inputs.faces = &.{};
    inputs.face_conductance_m3_per_step = &.{};
    inputs.atmospheric_boundaries = &.{.{
        .cell_index = 0,
        .aerodynamic_conductance_m3_per_step = 0,
        .interior_conductance_m3_per_step = invalid_conductance,
        .atmospheric_concentration_g_per_m3 = conductance,
    }};
    try std.testing.expectError(error.InvalidGasBoundary, group_validation.validate(&state, inputs, .{ .max_iterations = 1 }));
}

test "coupled gas preflight enforces damped Newton and divergence options" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.temperature_k[0] = 293.15;
    const inputs = group_validation.validationTestInputs();
    try std.testing.expectError(error.InvalidCoupledGasSolverOptions, group_validation.validate(&state, inputs, .{ .maximum_newton_fraction = 1.01, .max_iterations = 2 }));
    try std.testing.expectError(error.InvalidCoupledGasSolverOptions, group_validation.validate(&state, inputs, .{ .divergence_patience = 0, .max_iterations = 2 }));
    try std.testing.expectError(error.InvalidCoupledGasSolverOptions, group_validation.validate(&state, inputs, .{ .divergence_growth_factor = 0.5, .max_iterations = 2 }));
}

test "Newton merit cannot trade a worse limiting species for a lower L2 residual" {
    const options: group_misc.Options = .{ .absolute_tolerance_g = 1, .relative_tolerance = 1e-12, .max_iterations = 2 };
    const inventory_count = gas.species_count;
    const state = [_]f64{0} ** (3 * inventory_count);
    var current_residual = [_]f64{0} ** (3 * inventory_count);
    var candidate_residual = [_]f64{0} ** (3 * inventory_count);
    const limiting = @intFromEnum(gas.Species.oxygen);
    const tied = @intFromEnum(gas.Species.nitrous_oxide);
    current_residual[limiting] = 10;
    current_residual[tied] = 10;
    candidate_residual[limiting] = 11;
    const current_maximum = try group_diagnostics.scaledNorm(&state, &current_residual, options);
    // The candidate's L2 norm is smaller (11 versus sqrt(200)), but its
    // limiting component is worse and therefore must not be accepted.
    try std.testing.expect(!(try group_diagnostics.newtonMeritImproves(&state, &candidate_residual, options, current_maximum)));
}

test "worst residual coordinate uses the solver infinity norm scaling" {
    const options: group_misc.Options = .{ .absolute_tolerance_g = 1.0e-12, .relative_tolerance = 1.0e-8, .max_iterations = 2 };
    try std.testing.expectEqual(@as(usize, 1), try group_diagnostics.worstResidualIndex(&.{ 1.0e6, 0.5, 2.0 }, &.{ 1.0e-3, 2.0e-8, 1.0e-8 }, options));
}

test "Newton globalization accepts every strict infinity-norm improvement" {
    try std.testing.expectApproxEqAbs(@as(f64, 10), group_diagnostics.newtonAcceptanceTarget(10), 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2), group_diagnostics.newtonAcceptanceTarget(2), 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.337), group_diagnostics.newtonAcceptanceTarget(1.337), 1e-15);
}

test "coordinate Newton merit can advance one of two tied limiting residuals" {
    const options: group_misc.Options = .{ .absolute_tolerance_g = 1, .relative_tolerance = 1.0e-12, .max_iterations = 2 };
    const inventory_count = gas.species_count;
    const current = [_]f64{0} ** (3 * inventory_count);
    var residual = [_]f64{0} ** (3 * inventory_count);
    const candidate = [_]f64{0} ** (3 * inventory_count);
    var candidate_residual = [_]f64{0} ** (3 * inventory_count);
    const advanced = @intFromEnum(gas.Species.oxygen);
    const tied = @intFromEnum(gas.Species.nitrous_oxide);
    residual[advanced] = 2;
    residual[tied] = 2;
    candidate_residual[advanced] = 0.5;
    candidate_residual[tied] = 2;
    const current_norm = try group_diagnostics.scaledNorm(&current, &residual, options);
    try std.testing.expect(try group_diagnostics.scaledCoordinateResidual(candidate[advanced], candidate_residual[advanced], options, advanced, inventory_count) < try group_diagnostics.scaledCoordinateResidual(current[advanced], residual[advanced], options, advanced, inventory_count));
    try std.testing.expect(try group_diagnostics.scaledNorm(&candidate, &candidate_residual, options) <= current_norm);
}

test "trace-gas correction is not hidden by a large inventory" {
    const current = [_]f64{ 1.0e12, 1.0e-9 };
    const corrected = [_]f64{ 1.0e12, 1.0e-9 + 1.0e-15 };
    try std.testing.expect(!group_diagnostics.vectorsEqual(&current, &corrected));
    try std.testing.expect(group_diagnostics.vectorsEqual(&current, &current));
}

test "trace-gas relative scaling has no implicit one-gram floor" {
    const options: group_misc.Options = .{
        .absolute_tolerance_g = 1.0e-12,
        .relative_tolerance = 1.0e-8,
        .max_iterations = 2,
    };
    const inventory_count = gas.species_count;
    var state = [_]f64{0} ** (3 * gas.species_count);
    var residual = [_]f64{0} ** (3 * gas.species_count);
    state[0] = 1.0e-10;
    residual[0] = 1.0e-9;
    // Relative error is ten times the entire pool; the species absolute floor,
    // not an arbitrary one-gram reference, controls this trace coordinate.
    try std.testing.expect(try group_diagnostics.scaledCoordinateResidual(state[0], residual[0], options, 0, inventory_count) > 1);
    try std.testing.expect(try group_diagnostics.scaledNorm(&state, &residual, options) > 1);
}

test "projected zero cannot be accepted while its conservative source is positive" {
    try std.testing.expect(group_diagnostics.hasUnresolvedPositiveBound(0, 0.016, 0.016));
    try std.testing.expect(!group_diagnostics.hasUnresolvedPositiveBound(0, 0, 0));
    try std.testing.expect(!group_diagnostics.hasUnresolvedPositiveBound(0.1, 0.2, 0.1));
    try std.testing.expect(!group_diagnostics.hasUnresolvedPositiveBound(0, 0, -0.1));
}

test "extreme donor scale selects nonlocal conservative face bracket" {
    const options: group_misc.Options = .{
        .relative_tolerance = 1.0e-8,
        .max_iterations = 80,
    };
    try std.testing.expect(
        group_diagnostics.requiresNonlocalConservativeBracket(
            1.0e-4,
            1.0e8,
            options,
        ),
    );
    try std.testing.expect(
        !group_diagnostics.requiresNonlocalConservativeBracket(
            1,
            500,
            options,
        ),
    );
}

test "semismooth budget handoff requires an active incoming extreme donor" {
    const options: group_misc.Options = .{
        .relative_tolerance = 1.0e-8,
        .max_iterations = 80,
    };
    const inventory_count = 2 * gas.species_count;
    var current = [_]f64{1} ** (3 * 2 * gas.species_count);
    var residual = [_]f64{0} ** (3 * 2 * gas.species_count);
    var target = current;
    current[0] = 1.0e-4;
    current[gas.species_count] = 1.0e8;
    residual[0] = 1;
    target[0] = 1.0001;
    const inputs: group_misc.Inputs = .{
        .faces = &.{.{
            .first_cell = 0,
            .second_cell = 1,
        }},
        .face_conductance_m3_per_step = &([_]f64{0} ** gas.species_count),
        .atmospheric_boundaries = &.{},
        .water_volume_m3 = &.{ 0, 0 },
        .band_water_volume_m3 = &.{ 0, 0 },
        .mass_solubility_ratio = &([_]f64{1} ** (2 * gas.species_count)),
        .gas_water_exchange_rate_per_step = &([_]f64{0} ** (2 * gas.species_count)),
        .band_gas_water_exchange_rate_per_step = &([_]f64{0} ** (2 * gas.species_count)),
        .bubbling_enabled = &.{ false, false },
    };
    try std.testing.expect(group_diagnostics.hasExtremeIncomingDonorResidual(
        &current,
        &residual,
        &target,
        inputs,
        options,
        inventory_count,
    ));
    residual[0] = 0;
    target[0] = current[0];
    try std.testing.expect(!group_diagnostics.hasExtremeIncomingDonorResidual(
        &current,
        &residual,
        &target,
        inputs,
        options,
        inventory_count,
    ));
}

test "extreme gas face remains selectable when a dissolved residual is larger" {
    const options: group_misc.Options = .{
        .relative_tolerance = 1.0e-8,
        .max_iterations = 80,
    };
    const inventory_count = 2 * gas.species_count;
    var current = [_]f64{1} ** (3 * 2 * gas.species_count);
    var residual = [_]f64{0} ** (3 * 2 * gas.species_count);
    var target = current;
    current[0] = 1.0e-4;
    current[gas.species_count] = 1.0e8;
    residual[0] = 1;
    target[0] = 1.0001;
    residual[inventory_count + 1] = 1.0e6;
    const inputs: group_misc.Inputs = .{
        .faces = &.{.{
            .first_cell = 0,
            .second_cell = 1,
        }},
        .face_conductance_m3_per_step = &([_]f64{0} ** gas.species_count),
        .atmospheric_boundaries = &.{},
        .water_volume_m3 = &.{ 0, 0 },
        .band_water_volume_m3 = &.{ 0, 0 },
        .mass_solubility_ratio = &([_]f64{1} ** (2 * gas.species_count)),
        .gas_water_exchange_rate_per_step = &([_]f64{0} ** (2 * gas.species_count)),
        .band_gas_water_exchange_rate_per_step = &([_]f64{0} ** (2 * gas.species_count)),
        .bubbling_enabled = &.{ false, false },
    };
    try std.testing.expectEqual(
        @as(?usize, 0),
        try group_diagnostics.worstExtremeIncomingGasIndex(
            &current,
            &residual,
            &target,
            inputs,
            options,
            inventory_count,
        ),
    );
    residual[0] = 1.0e-8;
    target[0] = current[0] + residual[0];
    try std.testing.expectEqual(
        @as(?usize, null),
        try group_diagnostics.worstExtremeIncomingGasIndex(
            &current,
            &residual,
            &target,
            inputs,
            options,
            inventory_count,
        ),
    );
    try std.testing.expectEqual(
        @as(?usize, 0),
        try group_diagnostics.worstScaleSeparatedIncomingGasIndex(
            &current,
            &residual,
            &target,
            inputs,
            options,
            inventory_count,
        ),
    );
}

test "single remaining gas species is detected across all phases and cells" {
    const options: group_misc.Options = .{
        .relative_tolerance = 1.0e-8,
        .max_iterations = 80,
    };
    const inventory_count = 2 * gas.species_count;
    const current = [_]f64{1} ** (3 * 2 * gas.species_count);
    var residual = [_]f64{0} ** (3 * 2 * gas.species_count);
    residual[gas.species_count + 6] = 1.0e-4;
    residual[2 * inventory_count + gas.species_count + 6] = -1.0e-4;
    try std.testing.expectEqual(
        @as(usize, 1),
        try group_diagnostics.unconvergedSpeciesCount(
            &current,
            &residual,
            options,
            inventory_count,
        ),
    );
    residual[2] = 1.0e-4;
    try std.testing.expectEqual(
        @as(usize, 2),
        try group_diagnostics.unconvergedSpeciesCount(
            &current,
            &residual,
            options,
            inventory_count,
        ),
    );
}

test "depleted phase classification is relative to its aqueous inventory" {
    const options: group_misc.Options = .{
        .absolute_tolerance_g = 1.0e-14,
        .relative_tolerance = 1.0e-8,
        .max_iterations = 80,
    };
    try std.testing.expect(group_diagnostics.isScaleDepletedGas(2.3e-13, 5.42, group_misc.absoluteToleranceForSpecies(options, 0), options));
    try std.testing.expect(!group_diagnostics.isScaleDepletedGas(2.4e-5, 2.1e-5, group_misc.absoluteToleranceForSpecies(options, 0), options));
    try std.testing.expect(!group_diagnostics.isScaleDepletedGas(0, 5.42, group_misc.absoluteToleranceForSpecies(options, 0), options));
    try std.testing.expect(!group_diagnostics.isScaleDepletedGas(1.0e-13, 0, group_misc.absoluteToleranceForSpecies(options, 0), options));
}

test "coupled gas scaled norm preserves species-specific absolute floors" {
    const options: group_misc.Options = .{
        .absolute_tolerance_g_by_species = .{ 1.0e-10, 1.0e-12, 1.0e-12, 1.0e-12, 1.0e-12, 1.0e-12, 1.0e-12 },
        .relative_tolerance = 1.0e-14,
        .max_iterations = 2,
    };
    var state = [_]f64{0} ** (3 * gas.species_count);
    var residual = [_]f64{0} ** (3 * gas.species_count);
    residual[0] = 1.0e-10;
    residual[1] = 1.0e-10;
    const carbon_norm = try group_diagnostics.scaledSpeciesNorm(&state, &residual, options, gas.species_count, 0);
    const methane_norm = try group_diagnostics.scaledSpeciesNorm(&state, &residual, options, gas.species_count, 1);
    try std.testing.expect(methane_norm > 90 * carbon_norm);
    try std.testing.expect(methane_norm > 90);
}

test "matrix-free Jacobian probe retains derivative precision at gram-scale state" {
    const probe = group_directions.jacobianProbeMagnitude(1, 1);
    try std.testing.expect(probe > 1.0e-9);
    try std.testing.expect(probe < 1.0e-7);
    try std.testing.expectEqual(probe * 1.0e6, group_directions.jacobianProbeMagnitude(1.0e6, 1.0e6));
    try std.testing.expectEqual(probe, group_directions.jacobianProbeMagnitude(1, 1.0e-8));
}

test "matrix-free gas scaling matches trace-species nonlinear tolerance" {
    const absolute_tolerance_g = 1.0e-11;
    const relative_tolerance = 1.0e-8;
    const state_g = 1.0e-6;
    const scales = group_directions.krylovCoordinateScales(
        state_g,
        absolute_tolerance_g,
        relative_tolerance,
    );
    try std.testing.expectApproxEqAbs(
        absolute_tolerance_g + relative_tolerance * state_g,
        scales.residual_g,
        std.math.floatEps(f64),
    );
    try std.testing.expectApproxEqRel(
        scales.residual_g,
        relative_tolerance * scales.state_g,
        2 * std.math.floatEps(f64),
    );
    try std.testing.expect(scales.state_g < 0.01);
}

test "dense gas Jacobian probe follows trace-species mass scale" {
    const absolute_tolerance_g = 2.0e-13;
    const trace_mass_g = 6.0e-10;
    const trace_probe_g = group_directions.gasJacobianProbeG(
        trace_mass_g,
        absolute_tolerance_g,
    );
    const expected_fraction = std.math.cbrt(std.math.floatEps(f64));
    try std.testing.expectApproxEqRel(
        expected_fraction * trace_mass_g,
        trace_probe_g,
        std.math.floatEps(f64),
    );
    try std.testing.expect(trace_probe_g < 1.0e-4 * trace_mass_g);
    try std.testing.expectEqual(
        expected_fraction * absolute_tolerance_g,
        group_directions.gasJacobianProbeG(0, absolute_tolerance_g),
    );
}

test "tail refinement selects the species controlling convergence" {
    const inventory_count = gas.species_count;
    const state = [_]f64{0} ** gas.species_count;
    var residual = [_]f64{0} ** gas.species_count;
    residual[@intFromEnum(gas.Species.nitrous_oxide)] = 3;
    residual[@intFromEnum(gas.Species.carbon_dioxide)] = 2;
    const options: group_misc.Options = .{ .absolute_tolerance_g = 1, .relative_tolerance = 0, .max_iterations = 8 };
    try std.testing.expectEqual(@intFromEnum(gas.Species.nitrous_oxide), try group_diagnostics.worstResidualSpecies(&state, &residual, options, inventory_count));
}

test "species tail rejects local progress that does not strictly reduce the global merit" {
    const inventory_count = gas.species_count;
    const state = [_]f64{0} ** (3 * inventory_count);
    var current_residual = [_]f64{0} ** (3 * inventory_count);
    var candidate_residual = [_]f64{0} ** (3 * inventory_count);
    const selected = @intFromEnum(gas.Species.oxygen);
    const tied = @intFromEnum(gas.Species.nitrous_oxide);
    current_residual[selected] = 5;
    current_residual[tied] = 5;
    candidate_residual[selected] = 4;
    candidate_residual[tied] = 5;
    const options: group_misc.Options = .{ .absolute_tolerance_g = 1, .relative_tolerance = 0, .max_iterations = 8 };
    const global = try group_diagnostics.scaledNorm(&state, &current_residual, options);
    try std.testing.expect(!try group_diagnostics.speciesBlockMeritImproves(&state, &current_residual, &state, &candidate_residual, options, inventory_count, selected, global));
}

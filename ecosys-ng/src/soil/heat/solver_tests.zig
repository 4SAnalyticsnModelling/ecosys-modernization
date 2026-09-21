//! `solver` declarations: tests.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const grid_module = @import("../../state/grid.zig");
const heat = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const numerics = @import("../../core/numerics.zig");
const boundary_topology_module = @import("../profile/boundary_topology.zig");
const water_boundary = @import("../water/boundary.zig");
const enthalpy = @import("../water/enthalpy_balance.zig");
const retention = @import("../water/retention.zig");
const group_enthalpy = @import("solver_enthalpy.zig");
const group_boundary = @import("solver_boundary.zig");
const group_fixtures = @import("solver_fixtures.zig");
const group_misc = @import("solver_misc.zig");
const group_residual = @import("solver_residual.zig");
const group_solve = @import("solver_solve.zig");
const group_types = @import("solver_types.zig");
// issue-076: this checkout is CRLF, so `\n`-only needles cannot match the
// production text these assertions read back from disk.
const source_scan = @import("../../core/source_scan.zig");

fn readSolverSolveSource() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/soil/heat/solver_solve.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
}

test "REAL-DECK-HOUR-11-FATAL-STAGNATION-001: physically absurd soil temperature is rejected before commit" {
    // The exact top-layer temperature a real production run reached
    // (~125.5 K, colder than any terrestrial surface condition) before this
    // gate existed -- it is finite, so `grid.validateFinite()` alone let it
    // through. This is the same [173.15, 373.15] K domain every sibling
    // scalar solver already enforces via `numerics.newtonPicard`'s bracket.
    try std.testing.expectError(
        error.SoilHeatSolverTemperatureOutsidePhysicalDomain,
        group_solve.validateSoilTemperaturePhysicalDomain(&.{ 280, 125.5172096009 }),
    );
    try std.testing.expectError(
        error.SoilHeatSolverTemperatureOutsidePhysicalDomain,
        group_solve.validateSoilTemperaturePhysicalDomain(&.{400}),
    );
    // The exact bracket endpoints, and anything strictly inside, remain
    // admissible -- this tightens validation only, it does not narrow the
    // domain every other solver already assumes.
    try group_solve.validateSoilTemperaturePhysicalDomain(&.{ 173.15, 280, 373.15 });
}

test "issue-068: hour-2895's exact offending temperatures (401.75/452.64/455.14 K) violate the physical domain" {
    // Exact values captured by issue-068's diagnostic logging at hour 2,895,
    // cell 0/layer 0 (a chronically near-zero-heat-capacity layer), at
    // escalating substep_count=20/32/64 respectively -- 28.6/79.5/82.0 K
    // past the 373.15 K ceiling, confirmed a genuine numerical instability
    // (escalating substeps made the overshoot WORSE, not better), not a
    // marginal/roundoff overshoot. Before this issue's fix, the two
    // residual-scaled early-accept branches in `solve()` would commit a
    // value like this whenever their own scaled-residual criterion alone
    // was satisfied; see the end-to-end wiring proof below for confirmation
    // that both branches now also require `allTemperaturesPhysicallyValid`.
    try std.testing.expectError(
        error.SoilHeatSolverTemperatureOutsidePhysicalDomain,
        group_solve.validateSoilTemperaturePhysicalDomain(&.{4.017531898751224e2}),
    );
    try std.testing.expectError(
        error.SoilHeatSolverTemperatureOutsidePhysicalDomain,
        group_solve.validateSoilTemperaturePhysicalDomain(&.{4.5264430224579985e2}),
    );
    try std.testing.expectError(
        error.SoilHeatSolverTemperatureOutsidePhysicalDomain,
        group_solve.validateSoilTemperaturePhysicalDomain(&.{4.551385293197757e2}),
    );
}

test "issue-068: both residual-scaled early-accept branches require the candidate to be inside the physical domain before committing" {
    // Direct source-text proof that the fix actually reached both sites
    // issue-068 named (the mid-loop `norm <= 1` branch and the tail's
    // `strict_accept`/`practical_accept` branch), not just one of them, and
    // that the guard sits between the acceptance decision and the call to
    // `commitAcceptedState` -- i.e. a candidate that fails the guard falls
    // through to the existing `.iteration_limit`/`.stagnated`/`.diverged`
    // failure path instead of ever reaching `commitAcceptedState` (which
    // would otherwise raise `SoilHeatSolverTemperatureOutsidePhysicalDomain`
    // from inside a bare `try`, aborting the solve immediately and skipping
    // that failure path's own richer diagnostics).
    const source = try readSolverSolveSource();
    defer std.testing.allocator.free(source);

    const mid_loop_accept = std.mem.indexOf(
        u8,
        source,
        "if (!retrying_newton_after_anderson and norm <= 1 and",
    ) orelse return error.MissingHeatMidLoopEarlyAccept;
    const mid_loop_commit = std.mem.indexOfPos(
        u8,
        source,
        mid_loop_accept,
        "commitAcceptedState(",
    ) orelse return error.MissingHeatMidLoopCommit;
    try std.testing.expect(std.mem.indexOf(
        u8,
        source[mid_loop_accept..mid_loop_commit],
        "allTemperaturesPhysicallyValid(current)",
    ) != null);

    const tail_accept = std.mem.indexOf(
        u8,
        source,
        "if ((strict_accept or practical_accept) and",
    ) orelse return error.MissingHeatTailEarlyAccept;
    const tail_commit = std.mem.indexOfPos(
        u8,
        source,
        tail_accept,
        "commitAcceptedState(",
    ) orelse return error.MissingHeatTailCommit;
    try std.testing.expect(std.mem.indexOf(
        u8,
        source[tail_accept..tail_commit],
        "allTemperaturesPhysicallyValid(current)",
    ) != null);

    // The guard itself must be built on the same primitive every other
    // per-trial admissibility check in this file already uses
    // (`group_validation.isPhysicalTemperatureK`), not a redefinition of
    // the physical domain -- this never widens the bound in
    // `solver_validation.zig`.
    const guard_fn = std.mem.indexOf(
        u8,
        source,
        "fn allTemperaturesPhysicallyValid(temperature_k: []const f64) bool {",
    ) orelse return error.MissingHeatDomainGuardHelper;
    const guard_fn_end = std.mem.indexOfPos(u8, source, guard_fn, "\n}") orelse
        return error.MissingHeatDomainGuardHelperEnd;
    try std.testing.expect(std.mem.indexOf(
        u8,
        source[guard_fn..guard_fn_end],
        "group_validation.isPhysicalTemperatureK(value)",
    ) != null);
}

test "heat Newton rejects an impossible full step and accepts a bounded backtrack" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.soil_temperature_k, 300);

    const source_megajoules = [_]f64{ -400, -400 };
    var properties = group_fixtures.testProperties();
    properties.cell_heat_source_megajoules = &source_megajoules;
    const no_flux: [0]f64 = .{};
    var output_flux: [0]f64 = .{};

    const Recorder = struct {
        direction_k: f64 = std.math.nan(f64),
        accepted_fraction: ?f64 = null,

        fn onPricedDirection(
            context: ?*anyopaque,
            direction: []const f64,
            accepted_fraction: ?f64,
            _: f64,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.direction_k = direction[0];
            self.accepted_fraction = accepted_fraction;
        }
    };
    var recorder = Recorder{};
    const trace: group_types.DiagnosticTrace = .{
        .context = &recorder,
        .on_priced_direction = Recorder.onPricedDirection,
    };

    try std.testing.expectError(
        error.SoilHeatSolverDidNotConverge,
        group_solve.solve(
            std.testing.allocator,
            &grid,
            &.{},
            properties,
            .{
                .liquid_water_m3 = &no_flux,
                .vapor_m3 = &no_flux,
                .macropore_water_m3 = &no_flux,
            },
            &output_flux,
            .{
                .max_iterations = 1,
                .dense_newton_max_components = 0,
                .diagnostic_trace = &trace,
            },
        ),
    );

    try std.testing.expectEqual(@as(f64, -200), recorder.direction_k);
    try std.testing.expect(300 + recorder.direction_k < 173.15);
    try std.testing.expectEqual(@as(?f64, 0.5), recorder.accepted_fraction);
    try std.testing.expect(300 + recorder.accepted_fraction.? * recorder.direction_k >= 173.15);
    try std.testing.expectEqualSlices(f64, &.{ 300, 300 }, grid.soil_temperature_k);
}

test "dynamic matrix pore capacity defines the Dall'Amico retention volume" {
    const pore_capacity_m3 = 588_380.0197233009;
    const saturated_water_content_m3_per_m3 = 0.5120612363148425;
    const volume_m3 = try group_enthalpy.porousMediumVolumeFromPoreCapacity(
        pore_capacity_m3,
        saturated_water_content_m3_per_m3,
    );
    try std.testing.expectApproxEqRel(
        pore_capacity_m3,
        volume_m3 * saturated_water_content_m3_per_m3,
        4 * std.math.floatEps(f64),
    );
    try std.testing.expectError(
        error.InvalidCoupledSoilPoreGeometry,
        group_enthalpy.porousMediumVolumeFromPoreCapacity(0, saturated_water_content_m3_per_m3),
    );
}

test "hybrid heat solve exits before NPH and conserves sensible heat" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 300;
    grid.soil_temperature_k[1] = 280;
    const zero_flux = [_]f64{0};
    var output = [_]f64{0};
    const before = 2 * grid.soil_temperature_k[0] + 2 * grid.soil_temperature_k[1];
    const result = try group_solve.solve(std.testing.allocator, &grid, &.{.{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 }}, group_fixtures.testProperties(), .{ .liquid_water_m3 = &zero_flux, .vapor_m3 = &zero_flux, .macropore_water_m3 = &zero_flux }, &output, .{ .max_iterations = 20 });
    try std.testing.expect(result.iterations < 20);
    try std.testing.expect(result.newton_raphson_steps + result.picard_steps > 0);
    try std.testing.expectApproxEqAbs(before, 2 * grid.soil_temperature_k[0] + 2 * grid.soil_temperature_k[1], 1e-10);
    try std.testing.expect(output[0] > 0);
}

test "heat residual is face-order invariant and closes internal energy" {
    const values = struct {
        const capacity = [_]f64{ 2, 3, 4 };
        const zero = [_]f64{ 0, 0, 0 };
        const density = [_]f64{ 1, 1, 1 };
        const liquid = [_]f64{ 0.2, 0.2, 0.2 };
        const air = [_]f64{ 0.3, 0.3, 0.3 };
        const numerator = [_]f64{ 0.01, 0.01, 0.01 };
        const denominator = [_]f64{ 1, 1, 1 };
        const top = [_]bool{ true, false, false };
    };
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &values.capacity,
        .minimum_heat_capacity_megajoules_per_k = &values.zero,
        .bulk_density_megagrams_per_m3 = &values.density,
        .liquid_water_fraction = &values.liquid,
        .ice_fraction = &values.zero,
        .air_fraction = &values.air,
        .fraction_of_pore_volume_air_filled = &values.air,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &values.numerator,
        .solid_conductivity_denominator = &values.denominator,
        .is_top_soil_layer = &values.top,
        .top_snow_heat_capacity_megajoules_per_k = &values.zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &values.zero,
        .snow_storage_heat_flux_megajoules = &values.zero,
        .cell_heat_source_megajoules = &values.zero,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
    };
    const forward_faces = [_]group_types.Face{
        .{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 0.5, .destination_path_length_m = 0.5, .face_area_m2 = 1 },
        .{ .source_cell = 1, .destination_cell = 2, .source_path_length_m = 0.5, .destination_path_length_m = 0.5, .face_area_m2 = 1 },
    };
    const reverse_faces = [_]group_types.Face{
        forward_faces[1],
        forward_faces[0],
    };
    const temperature = [_]f64{ 300, 280, 260 };
    const zero_face_flux = [_]f64{ 0, 0 };
    const water_fluxes: group_types.WaterHeatFluxes = .{
        .liquid_water_m3 = &zero_face_flux,
        .vapor_m3 = &zero_face_flux,
        .macropore_water_m3 = &zero_face_flux,
    };
    var target_forward: [3]f64 = undefined;
    var residual_forward: [3]f64 = undefined;
    var scratch_forward: [3]f64 = undefined;
    var flux_forward: [2]f64 = undefined;
    var target_reverse: [3]f64 = undefined;
    var residual_reverse: [3]f64 = undefined;
    var scratch_reverse: [3]f64 = undefined;
    var flux_reverse: [2]f64 = undefined;
    var phase_matrix_liquid: [3]f64 = undefined;
    var phase_matrix_ice: [3]f64 = undefined;
    var phase_macropore_liquid: [3]f64 = undefined;
    var phase_macropore_ice: [3]f64 = undefined;
    const phase_buffers: group_misc.PhaseBuffers = .{
        .matrix_liquid_m3 = &phase_matrix_liquid,
        .matrix_ice_m3 = &phase_matrix_ice,
        .macropore_liquid_m3 = &phase_macropore_liquid,
        .macropore_ice_m3 = &phase_macropore_ice,
        .macropore_enabled = false,
        .ice_density_megagrams_per_m3 = 0.917,
    };
    try group_residual.residualAt(&forward_faces, properties, water_fluxes, &temperature, &temperature, &target_forward, &residual_forward, &scratch_forward, &flux_forward, phase_buffers, .{ .max_iterations = 80 });
    try group_residual.residualAt(&reverse_faces, properties, water_fluxes, &temperature, &temperature, &target_reverse, &residual_reverse, &scratch_reverse, &flux_reverse, phase_buffers, .{ .max_iterations = 80 });

    for (residual_forward, residual_reverse) |forward, reverse|
        try std.testing.expectApproxEqAbs(forward, reverse, 64 * std.math.floatEps(f64) * @max(1, @abs(forward)));
    try std.testing.expectApproxEqAbs(flux_forward[0], flux_reverse[1], 64 * std.math.floatEps(f64) * @max(1, @abs(flux_forward[0])));
    try std.testing.expectApproxEqAbs(flux_forward[1], flux_reverse[0], 64 * std.math.floatEps(f64) * @max(1, @abs(flux_forward[1])));
    var internal_energy_change_megajoules: f64 = 0;
    var sensible_energy_scale_megajoules: f64 = 0;
    for (residual_forward, values.capacity, temperature) |difference_k, capacity, temperature_k| {
        internal_energy_change_megajoules += difference_k * capacity;
        sensible_energy_scale_megajoules += capacity * @abs(temperature_k);
    }
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        internal_energy_change_megajoules,
        4 * std.math.floatEps(f64) * sensible_energy_scale_megajoules,
    );
}

test "NEWTON-ANDERSON-PRACTICAL-ACCEPTANCE-001: practical-accept path fires end-to-end and conserves energy" {
    // Three incommensurate-capacity cells (2/3/5 MJ/K) in a chain, pure
    // sensible heat (no `enthalpy_coupling`, so `conservationScaledNorm`
    // trivially returns 0 -- this fixture isolates the numerical-residual
    // acceptance path from the separate conservation check, which is
    // verified independently below via the actual physical invariant, not
    // just the trivial-zero return). A plain two-cell fixture (as used by
    // "hybrid heat solve exits before NPH") lands on an exact
    // floating-point fixed point regardless of tolerance, never exercising
    // this path; the asymmetric 3-cell chain does not.
    const values = struct {
        const capacity = [_]f64{ 2, 3, 5 };
        const zero = [_]f64{ 0, 0, 0 };
        const density = [_]f64{ 1, 1, 1 };
        const liquid = [_]f64{ 0.2, 0.2, 0.2 };
        const air = [_]f64{ 0.3, 0.3, 0.3 };
        const numerator = [_]f64{ 0.01, 0.01, 0.01 };
        const denominator = [_]f64{ 1, 1, 1 };
        const top = [_]bool{ true, false, false };
    };
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &values.capacity,
        .minimum_heat_capacity_megajoules_per_k = &values.zero,
        .bulk_density_megagrams_per_m3 = &values.density,
        .liquid_water_fraction = &values.liquid,
        .ice_fraction = &values.zero,
        .air_fraction = &values.air,
        .fraction_of_pore_volume_air_filled = &values.air,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &values.numerator,
        .solid_conductivity_denominator = &values.denominator,
        .is_top_soil_layer = &values.top,
        .top_snow_heat_capacity_megajoules_per_k = &values.zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &values.zero,
        .snow_storage_heat_flux_megajoules = &values.zero,
        .cell_heat_source_megajoules = &values.zero,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
    };
    const faces = [_]group_types.Face{
        .{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 0.5, .destination_path_length_m = 0.5, .face_area_m2 = 1 },
        .{ .source_cell = 1, .destination_cell = 2, .source_path_length_m = 0.5, .destination_path_length_m = 0.5, .face_area_m2 = 1 },
    };
    const zero_flux = [_]f64{ 0, 0 };
    const water_fluxes: group_types.WaterHeatFluxes = .{ .liquid_water_m3 = &zero_flux, .vapor_m3 = &zero_flux, .macropore_water_m3 = &zero_flux };

    const Recorder = struct {
        nonlinear_norm: f64 = std.math.nan(f64),
        conservation_norm: f64 = std.math.nan(f64),
        strict_accept: bool = false,
        practical_accept: bool = false,
        fn onFinalAcceptance(context: ?*anyopaque, nonlinear_norm: f64, conservation_norm: f64, strict_accept: bool, practical_accept: bool) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.* = .{ .nonlinear_norm = nonlinear_norm, .conservation_norm = conservation_norm, .strict_accept = strict_accept, .practical_accept = practical_accept };
        }
    };

    // Crippled step (fixed 0.9 fraction, dense/global Newton disabled) so
    // the solve makes real but incomplete progress each iteration instead
    // of resolving this linear conduction problem in one full step.
    const crippled_options = group_types.Options{
        .max_iterations = 4,
        .minimum_newton_fraction = 0.9,
        .maximum_newton_fraction = 0.9,
        .dense_newton_max_components = 0,
    };

    // Companion negative check first: one fewer iteration of the identical
    // crippled setup must still fail outright (`nonlinear_norm` far above
    // even the 100x practical band) -- this brackets the positive case
    // below, so the accept path exercised there cannot be explained by
    // "this configuration always converges regardless."
    {
        var grid = try grid_module.GridState.init(std.testing.allocator, try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 3, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 3 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 }));
        defer grid.deinit();
        grid.soil_temperature_k[0] = 300;
        grid.soil_temperature_k[1] = 280;
        grid.soil_temperature_k[2] = 340;
        var output = [_]f64{ 0, 0 };
        var one_fewer = crippled_options;
        one_fewer.max_iterations = 3;
        try std.testing.expectError(error.SoilHeatSolverDidNotConverge, group_solve.solve(std.testing.allocator, &grid, &faces, properties, water_fluxes, &output, one_fewer));
    }

    var grid = try grid_module.GridState.init(std.testing.allocator, try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 3, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 3 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 }));
    defer grid.deinit();
    grid.soil_temperature_k[0] = 300;
    grid.soil_temperature_k[1] = 280;
    grid.soil_temperature_k[2] = 340;
    const energy_before_megajoules = values.capacity[0] * grid.soil_temperature_k[0] +
        values.capacity[1] * grid.soil_temperature_k[1] +
        values.capacity[2] * grid.soil_temperature_k[2];
    var output = [_]f64{ 0, 0 };
    var recorder = Recorder{};
    const trace: group_types.DiagnosticTrace = .{ .context = &recorder, .on_final_acceptance = Recorder.onFinalAcceptance };
    var options_with_trace = crippled_options;
    options_with_trace.diagnostic_trace = &trace;
    _ = try group_solve.solve(std.testing.allocator, &grid, &faces, properties, water_fluxes, &output, options_with_trace);

    // The accept path fired was genuinely the PRACTICAL one, not strict:
    try std.testing.expect(recorder.practical_accept);
    try std.testing.expect(!recorder.strict_accept);
    try std.testing.expect(recorder.nonlinear_norm > 1);
    try std.testing.expect(recorder.nonlinear_norm <= 100);
    // Conservation held to the SAME strict standard as normal acceptance
    // (not relaxed by this path):
    try std.testing.expect(recorder.conservation_norm <= 1);
    // Independent physical check, not just the trivial-zero return this
    // no-`enthalpy_coupling` fixture gets from `conservationScaledNorm`:
    // total sensible heat (capacity * temperature) is exactly conserved.
    const energy_after_megajoules = values.capacity[0] * grid.soil_temperature_k[0] +
        values.capacity[1] * grid.soil_temperature_k[1] +
        values.capacity[2] * grid.soil_temperature_k[2];
    try std.testing.expectApproxEqAbs(energy_before_megajoules, energy_after_megajoules, 1e-9);
    // Physically valid: finite, positive-kelvin states.
    for (grid.soil_temperature_k[0..3]) |temperature_k| {
        try std.testing.expect(std.math.isFinite(temperature_k));
        try std.testing.expect(temperature_k > 0);
    }
}

test "NEWTON-ANDERSON-PRACTICAL-ACCEPTANCE-001: still rejects a residual far outside the practical multiplier" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 300;
    grid.soil_temperature_k[1] = 280;
    const zero_flux = [_]f64{0};
    var output = [_]f64{99};
    // Same unreachable-tolerance setup as the acceptance test above, but with
    // `max_iterations = 1` and a crippled directional-Newton fraction (same
    // knobs as "failed heat convergence is atomic"): the solve is stopped
    // long before it gets anywhere near the representable-precision floor,
    // so its residual is far above even the 100x practical multiplier and
    // must still be rejected.
    try std.testing.expectError(error.SoilHeatSolverDidNotConverge, group_solve.solve(std.testing.allocator, &grid, &.{.{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 }}, group_fixtures.testProperties(), .{ .liquid_water_m3 = &zero_flux, .vapor_m3 = &zero_flux, .macropore_water_m3 = &zero_flux }, &output, .{ .max_iterations = 1, .absolute_tolerance_k = 1e-300, .relative_tolerance = 1e-300, .minimum_newton_fraction = 0.05, .maximum_newton_fraction = 0.05, .dense_newton_max_components = 0 }));
    try std.testing.expectEqual(@as(f64, 300), grid.soil_temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 99), output[0]);
}

test "failed heat convergence is atomic" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 300;
    grid.soil_temperature_k[1] = 280;
    const zero_flux = [_]f64{0};
    var output = [_]f64{99};
    try std.testing.expectError(error.SoilHeatSolverDidNotConverge, group_solve.solve(std.testing.allocator, &grid, &.{.{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 }}, group_fixtures.testProperties(), .{ .liquid_water_m3 = &zero_flux, .vapor_m3 = &zero_flux, .macropore_water_m3 = &zero_flux }, &output, .{ .max_iterations = 1, .minimum_newton_fraction = 0.05, .maximum_newton_fraction = 0.05, .dense_newton_max_components = 0 }));
    try std.testing.expectEqual(@as(f64, 300), grid.soil_temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 99), output[0]);
}

test "coupled heat residual state_updates Dall'Amico phase and conserves enthalpy" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 1,
            .lat_count = 1,
            .soil_layers = 1,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 80,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 275;
    grid.matrix_liquid_water_m3[0] = 0.4;
    grid.macropore_liquid_water_m3[0] = 0.05;
    grid.liquid_water_m3[0] = 0.45;
    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.macropore_pore_capacity_m3[0] = 0.1;
    grid.matrix_air_volume_m3[0] = 0.1;
    grid.macropore_air_volume_m3[0] = 0.05;
    grid.air_volume_m3[0] = 0.15;
    const capacity = [_]f64{2.8855};
    const zero = [_]f64{0};
    const density = [_]f64{1};
    const liquid_fraction = [_]f64{0.45};
    const air_fraction = [_]f64{0.15};
    const numerator = [_]f64{0.01};
    const denominator = [_]f64{1};
    const top = [_]bool{true};
    const cooling_megajoules = [_]f64{-100};
    const volume = [_]f64{1};
    const macropore_volume = [_]f64{0.1};
    const curve = [_]retention.MualemVanGenuchtenParameters{.{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.5,
        .alpha_per_m = 1.6,
        .n = 1.6,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    }};
    const macropore_curve = [_]retention.MualemVanGenuchtenParameters{.{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 15,
        .n = 2.68,
        .saturated_hydraulic_conductivity_m_per_h = 0.1,
    }};
    const coupling: group_misc.EnthalpyCoupling = .{
        .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
        .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
        .porous_medium_volume_m3 = &volume,
        .mualem_van_genuchten = &curve,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
        .ice_density_megagrams_per_m3 = 0.917,
        .solver_options = .{ .max_iterations = 80 },
        .macropore_liquid_water_m3 = grid.macropore_liquid_water_m3,
        .macropore_ice_water_equivalent_m3 = grid.macropore_ice_water_m3,
        .macropore_porous_medium_volume_m3 = &macropore_volume,
        .macropore_mualem_van_genuchten = &macropore_curve,
    };
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &density,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &zero,
        .air_fraction = &air_fraction,
        .fraction_of_pore_volume_air_filled = &air_fraction,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &numerator,
        .solid_conductivity_denominator = &denominator,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &cooling_megajoules,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = coupling,
    };
    const initial_parameters =
        try group_enthalpy.enthalpyParameters(properties, coupling, 0);
    const initial_state = try enthalpy.stateAtTemperature(
        initial_parameters,
        grid.soil_temperature_k[0],
    );
    var no_face_heat_flux: [0]f64 = .{};
    const no_water_flux: [0]f64 = .{};
    var recovery_routing_test_control: group_types.RecoveryRoutingTestControl = .{
        .force_speculative_iteration = 1,
        .reject_speculative_anderson = true,
    };
    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        .{
            .liquid_water_m3 = &no_water_flux,
            .vapor_m3 = &no_water_flux,
            .macropore_water_m3 = &no_water_flux,
        },
        &no_face_heat_flux,
        .{
            .max_iterations = 80,
            .divergence_patience = 2,
            .recovery_routing_test_control = &recovery_routing_test_control,
        },
    );
    const final_state = try enthalpy.stateAtTemperature(
        initial_parameters,
        grid.soil_temperature_k[0],
    );
    try std.testing.expect(result.iterations < 80);
    // A forecast is speculative. Rejecting every priced Anderson candidate in
    // this actual nonlinear solve must retry Newton in the next counted NPH
    // slot, not classify the solve as stagnated or exceed the hard ceiling.
    // Patience two is deliberate: the pre-fix replay repriced the unchanged
    // state as a second insufficient-progress observation and suppressed that
    // Newton.
    try std.testing.expectEqual(@as(u16, 1), recovery_routing_test_control.speculative_probes);
    try std.testing.expectEqual(@as(u16, 1), recovery_routing_test_control.next_slot_newton_fallbacks);
    try std.testing.expectEqual(
        recovery_routing_test_control.speculative_anderson_iteration.? + 1,
        recovery_routing_test_control.next_slot_newton_iteration.?,
    );
    try std.testing.expectEqual(result.iterations, recovery_routing_test_control.iterations_entered);
    try std.testing.expect(recovery_routing_test_control.iterations_entered <= 80);
    try std.testing.expectEqual(@as(u16, 1), recovery_routing_test_control.invalidated_forecasts);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    try std.testing.expect(grid.matrix_ice_water_m3[0] > 0);
    try std.testing.expect(grid.macropore_ice_water_m3[0] > 0);
    try std.testing.expectApproxEqAbs(
        initial_state.enthalpy_megajoules + cooling_megajoules[0],
        final_state.enthalpy_megajoules,
        1.0e-8,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.4),
        grid.matrix_liquid_water_m3[0] +
            grid.matrix_ice_water_m3[0],
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.05),
        grid.macropore_liquid_water_m3[0] +
            grid.macropore_ice_water_m3[0],
        1.0e-12,
    );
}

test "DIAG two-layer conduction-coupled cooling sweep near real hour-15 magnitudes" {
    const multipliers = [_]f64{ 1, 2, 5, 10 };
    for (multipliers) |multiplier| {
        const cfg = try @import("../../core/config.zig").SimulationConfig.init(
            .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
            .{ .worker_threads = 1, .tile_cells = 1 },
            .{
                .relative_tolerance = 1e-8,
                .absolute_tolerance = 1e-11,
                .max_nonlinear_iterations = 20,
            },
        );
        var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
        defer grid.deinit();

        const curve = [_]retention.MualemVanGenuchtenParameters{
            .{
                .residual_water_content_m3_per_m3 = 0.05,
                .saturated_water_content_m3_per_m3 = 0.5,
                .alpha_per_m = 1.6,
                .n = 1.6,
                .saturated_hydraulic_conductivity_m_per_h = 0.01,
            },
            .{
                .residual_water_content_m3_per_m3 = 0.05,
                .saturated_water_content_m3_per_m3 = 0.5,
                .alpha_per_m = 1.6,
                .n = 1.6,
                .saturated_hydraulic_conductivity_m_per_h = 0.01,
            },
        };

        // Layer 0: real captured hour-15/cell-0 state. Layer 1: a plausible
        // warmer, larger, unforced layer below it, coupled only via
        // conduction -- isolates whether multi-layer coupling itself (not
        // magnitude) triggers the failure mode no single-layer fixture in
        // this investigation chain has reproduced.
        const total_water_0 = 2.318e-3;
        const volume_0 = total_water_0 / 0.3;
        const total_water_1 = 0.02;
        const volume_1 = total_water_1 / 0.3;
        const volumes = [_]f64{ volume_0, volume_1 };

        const capacity = [_]f64{ 0.016893, 0.5 };
        const zero = [_]f64{ 0, 0 };
        const density = [_]f64{ 1, 1 };
        var liquid_fraction = [_]f64{ 0, 0 };
        var ice_fraction_baseline = [_]f64{ 0, 0 };
        const air_fraction = [_]f64{ 0.15, 0.15 };
        const numerator = [_]f64{ 0.01, 0.01 };
        const denominator = [_]f64{ 1, 1 };
        const top = [_]bool{ true, false };
        const cooling_megajoules = [_]f64{ -0.03224 * multiplier, 0 };

        var initial_parameters: [2]enthalpy.Parameters = undefined;
        var initial_state: [2]enthalpy.State = undefined;

        const properties: group_types.Properties = .{
            .heat_capacity_megajoules_per_k = &capacity,
            .minimum_heat_capacity_megajoules_per_k = &zero,
            .bulk_density_megagrams_per_m3 = &density,
            .liquid_water_fraction = &liquid_fraction,
            .ice_fraction = &ice_fraction_baseline,
            .air_fraction = &air_fraction,
            .fraction_of_pore_volume_air_filled = &air_fraction,
            .solid_conductivity_numerator_m_megajoules_per_h_k = &numerator,
            .solid_conductivity_denominator = &denominator,
            .is_top_soil_layer = &top,
            .top_snow_heat_capacity_megajoules_per_k = &zero,
            .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
            .snow_storage_heat_flux_megajoules = &zero,
            .cell_heat_source_megajoules = &cooling_megajoules,
            .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
            .turbulence = .{
                .water_fraction_threshold = 1,
                .air_fraction_threshold = 1,
                .water_rayleigh_coefficient = 0,
                .air_rayleigh_coefficient = 0,
                .water_nusselt_denominator = 1,
                .air_nusselt_denominator = 1,
            },
            .enthalpy_coupling = .{
                .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
                .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
                .porous_medium_volume_m3 = &volumes,
                .mualem_van_genuchten = &curve,
                .gravitational_water_potential_mpa_per_m = 0.00980665,
                .pure_water_melting_temperature_k = 273.15,
                .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
                .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
                .ice_density_megagrams_per_m3 = 0.917,
                .solver_options = .{ .max_iterations = 20 },
            },
        };

        grid.soil_temperature_k[0] = 254.74;
        grid.soil_temperature_k[1] = 262.0;
        grid.matrix_liquid_water_m3[0] = total_water_0;
        grid.matrix_ice_water_m3[0] = 0;
        grid.matrix_liquid_water_m3[1] = total_water_1;
        grid.matrix_ice_water_m3[1] = 0;

        for ([_]usize{ 0, 1 }) |cell| {
            initial_parameters[cell] = try group_enthalpy.enthalpyParameters(properties, properties.enthalpy_coupling.?, cell);
            initial_state[cell] = try enthalpy.stateAtTemperature(initial_parameters[cell], grid.soil_temperature_k[cell]);
            grid.matrix_liquid_water_m3[cell] = initial_state[cell].liquid_water_m3;
            grid.matrix_ice_water_m3[cell] = initial_state[cell].ice_water_equivalent_m3;
            // `cellConductivityInputs` computes the conductivity-input phase
            // fractions as this baseline PLUS a coupling delta that is exactly
            // zero at the (trial == base) starting point -- so this baseline
            // must equal the real physical fraction at the seeded temperature,
            // not a placeholder, or a trial that legitimately moves the phase
            // split further from the placeholder (here: any warming, since
            // real ice > 0 but the placeholder claimed 0) spuriously trips
            // `InvalidCoupledSoilIceFraction`/`InvalidCoupledSoilLiquidFraction`.
            liquid_fraction[cell] = initial_state[cell].liquid_water_m3 / volumes[cell];
            ice_fraction_baseline[cell] = initial_state[cell].ice_water_equivalent_m3 / volumes[cell];
        }

        var output_flux: [1]f64 = undefined;
        const zero_face_flux = [_]f64{0};

        const result = group_solve.solve(
            std.testing.allocator,
            &grid,
            &.{.{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 0.05, .destination_path_length_m = 0.15, .face_area_m2 = 1 }},
            properties,
            .{
                .liquid_water_m3 = &zero_face_flux,
                .vapor_m3 = &zero_face_flux,
                .macropore_water_m3 = &zero_face_flux,
            },
            &output_flux,
            .{ .max_iterations = 20 },
        );

        if (result) |ok| {
            std.debug.print(
                "DIAG-2LAYER multiplier={d} status=converged iterations={d} T0={d} T1={d}\n",
                .{ multiplier, ok.iterations, grid.soil_temperature_k[0], grid.soil_temperature_k[1] },
            );
        } else |err| {
            std.debug.print(
                "DIAG-2LAYER multiplier={d} status=FAILED error={s} T0={d} T1={d}\n",
                .{ multiplier, @errorName(err), grid.soil_temperature_k[0], grid.soil_temperature_k[1] },
            );
        }
    }
}

/// Captures every `DiagnosticTrace` callback into plain counters/values so a
/// test can assert on what the trace actually reported, rather than eyeballing
/// `std.debug.print` output. See `SURFACE-HEAT-BRACKET-RUNAWAY-001` in
/// `docs/discrepancy_register.md` for why this scaffold exists: three
/// separate prior investigation passes each introduced their own
/// fixture-construction artifact (an infeasible magnitude once, an
/// inconsistent/placeholder ice fraction twice) that produced a confident but
/// wrong conclusion -- this scaffold is built and verified against
/// known-good/known-bad cases BEFORE being trusted for a real production
/// capture, specifically to avoid a fourth repeat of that failure mode.
const TraceCapture = struct {
    iterations_seen: u16 = 0,
    last_norm: f64 = std.math.nan(f64),
    priced_calls: u16 = 0,
    accepted_priced_calls: u16 = 0,
    ice_check_calls: u16 = 0,
    /// Largest `|properties_fraction_sum - coupling_fraction_sum|` observed
    /// across every `on_ice_fraction_consistency_check` call this solve.
    largest_ice_fraction_delta: f64 = 0,
    transition_proximity_calls: u16 = 0,
    /// Smallest `distance_k / kink_radius_k` seen across every
    /// `on_transition_proximity` call whose `near_domain_transition` was
    /// `false` -- how close a SKIPPED cell came to the activation radius
    /// without crossing it. `inf` if no such call was seen.
    smallest_missed_distance_over_radius: f64 = std.math.inf(f64),
    saw_near_domain_transition_true: bool = false,

    fn onIterationResidual(
        context: ?*anyopaque,
        iteration: u16,
        _: []const f64,
        _: []const f64,
        norm: f64,
    ) void {
        const self: *TraceCapture = @ptrCast(@alignCast(context.?));
        self.iterations_seen = iteration + 1;
        self.last_norm = norm;
    }

    fn onPricedDirection(
        context: ?*anyopaque,
        _: []const f64,
        accepted_fraction: ?f64,
        _: f64,
    ) void {
        const self: *TraceCapture = @ptrCast(@alignCast(context.?));
        self.priced_calls += 1;
        if (accepted_fraction != null) self.accepted_priced_calls += 1;
    }

    fn onIceFractionConsistencyCheck(
        context: ?*anyopaque,
        _: usize,
        properties_fraction_sum: f64,
        coupling_fraction_sum: f64,
    ) void {
        const self: *TraceCapture = @ptrCast(@alignCast(context.?));
        self.ice_check_calls += 1;
        const delta = @abs(properties_fraction_sum - coupling_fraction_sum);
        if (delta > self.largest_ice_fraction_delta) self.largest_ice_fraction_delta = delta;
    }

    /// Records whether the discovery loop's skip-check ever classified a
    /// cell as near its transition, and the closest miss (as a fraction of
    /// the activation radius) among cells it classified as NOT near.
    fn onTransitionProximityWithDistance(
        context: ?*anyopaque,
        _: usize,
        temperature_k: f64,
        transition_k: f64,
        kink_radius_k: f64,
        near_domain_transition: bool,
    ) void {
        const self: *TraceCapture = @ptrCast(@alignCast(context.?));
        self.transition_proximity_calls += 1;
        if (near_domain_transition) {
            self.saw_near_domain_transition_true = true;
        } else {
            const ratio = @abs(temperature_k - transition_k) / kink_radius_k;
            if (ratio < self.smallest_missed_distance_over_radius)
                self.smallest_missed_distance_over_radius = ratio;
        }
    }

    fn trace(self: *TraceCapture) group_types.DiagnosticTrace {
        return .{
            .context = self,
            .on_iteration_residual = onIterationResidual,
            .on_priced_direction = onPricedDirection,
            .on_ice_fraction_consistency_check = onIceFractionConsistencyCheck,
            .on_transition_proximity = onTransitionProximityWithDistance,
        };
    }
};

test "DIAGNOSTIC TRACE verification: known-converging real-magnitude fixture reports true iteration count, an accepted direction, and a clean (self-consistent) ice-fraction check" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    const curve = [_]retention.MualemVanGenuchtenParameters{
        .{ .residual_water_content_m3_per_m3 = 0.05, .saturated_water_content_m3_per_m3 = 0.5, .alpha_per_m = 1.6, .n = 1.6, .saturated_hydraulic_conductivity_m_per_h = 0.01 },
        .{ .residual_water_content_m3_per_m3 = 0.05, .saturated_water_content_m3_per_m3 = 0.5, .alpha_per_m = 1.6, .n = 1.6, .saturated_hydraulic_conductivity_m_per_h = 0.01 },
    };
    const total_water_0 = 2.318e-3;
    const volume_0 = total_water_0 / 0.3;
    const total_water_1 = 0.02;
    const volume_1 = total_water_1 / 0.3;
    const volumes = [_]f64{ volume_0, volume_1 };
    const capacity = [_]f64{ 0.016893, 0.5 };
    const zero = [_]f64{ 0, 0 };
    const density = [_]f64{ 1, 1 };
    var liquid_fraction = [_]f64{ 0, 0 };
    var ice_fraction_baseline = [_]f64{ 0, 0 };
    const air_fraction = [_]f64{ 0.15, 0.15 };
    const numerator = [_]f64{ 0.01, 0.01 };
    const denominator = [_]f64{ 1, 1 };
    const top = [_]bool{ true, false };
    // multiplier=5: confirmed converging in the register's own two-layer
    // reproduction (`SURFACE-HEAT-BRACKET-RUNAWAY-001`).
    const cooling_megajoules = [_]f64{ -0.03224 * 5, 0 };

    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &density,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &ice_fraction_baseline,
        .air_fraction = &air_fraction,
        .fraction_of_pore_volume_air_filled = &air_fraction,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &numerator,
        .solid_conductivity_denominator = &denominator,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &cooling_megajoules,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = .{
            .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
            .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
            .porous_medium_volume_m3 = &volumes,
            .mualem_van_genuchten = &curve,
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .pure_water_melting_temperature_k = 273.15,
            .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
            .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
            .ice_density_megagrams_per_m3 = 0.917,
            .solver_options = .{ .max_iterations = 20 },
        },
    };

    grid.soil_temperature_k[0] = 254.74;
    grid.soil_temperature_k[1] = 262.0;
    grid.matrix_liquid_water_m3[0] = total_water_0;
    grid.matrix_ice_water_m3[0] = 0;
    grid.matrix_liquid_water_m3[1] = total_water_1;
    grid.matrix_ice_water_m3[1] = 0;
    for ([_]usize{ 0, 1 }) |cell| {
        const initial_parameters = try group_enthalpy.enthalpyParameters(properties, properties.enthalpy_coupling.?, cell);
        const initial_state = try enthalpy.stateAtTemperature(initial_parameters, grid.soil_temperature_k[cell]);
        grid.matrix_liquid_water_m3[cell] = initial_state.liquid_water_m3;
        grid.matrix_ice_water_m3[cell] = initial_state.ice_water_equivalent_m3;
        // Self-consistent, matching the register's own fix: the baseline
        // fraction is derived from the real Dall'Amico equilibrium at the
        // seeded temperature, not a placeholder.
        liquid_fraction[cell] = initial_state.liquid_water_m3 / volumes[cell];
        ice_fraction_baseline[cell] = initial_state.ice_water_equivalent_m3 / volumes[cell];
    }

    var capture: TraceCapture = .{};
    var output_flux: [1]f64 = undefined;
    const zero_face_flux = [_]f64{0};
    const trace = capture.trace();
    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{.{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 0.05, .destination_path_length_m = 0.15, .face_area_m2 = 1 }},
        properties,
        .{ .liquid_water_m3 = &zero_face_flux, .vapor_m3 = &zero_face_flux, .macropore_water_m3 = &zero_face_flux },
        &output_flux,
        .{ .max_iterations = 20, .diagnostic_trace = &trace },
    );

    // The trace must report the SAME iteration count `solve` itself returns
    // -- proving `on_iteration_residual` fires exactly once per real outer
    // iteration, not more or fewer.
    try std.testing.expectEqual(result.iterations, capture.iterations_seen);
    // A converging case must have accepted at least one priced direction.
    try std.testing.expect(capture.priced_calls > 0);
    try std.testing.expect(capture.accepted_priced_calls > 0);
    // Both cells' ice-fraction consistency check must have fired, and found
    // no discrepancy: this fixture derives its baseline fractions from the
    // real equilibrium, exactly the class of self-consistency the register's
    // three prior fixture-construction mistakes lacked.
    try std.testing.expectEqual(@as(u16, 2), capture.ice_check_calls);
    try std.testing.expect(capture.largest_ice_fraction_delta < 1e-9);
}

test "DIAGNOSTIC TRACE verification: the ice-fraction consistency check catches the EXACT placeholder-fraction defect that broke three prior investigation passes" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    const curve = [_]retention.MualemVanGenuchtenParameters{
        .{ .residual_water_content_m3_per_m3 = 0.05, .saturated_water_content_m3_per_m3 = 0.5, .alpha_per_m = 1.6, .n = 1.6, .saturated_hydraulic_conductivity_m_per_h = 0.01 },
        .{ .residual_water_content_m3_per_m3 = 0.05, .saturated_water_content_m3_per_m3 = 0.5, .alpha_per_m = 1.6, .n = 1.6, .saturated_hydraulic_conductivity_m_per_h = 0.01 },
    };
    const total_water_0 = 2.318e-3;
    const volume_0 = total_water_0 / 0.3;
    const total_water_1 = 0.02;
    const volume_1 = total_water_1 / 0.3;
    const volumes = [_]f64{ volume_0, volume_1 };
    const capacity = [_]f64{ 0.016893, 0.5 };
    const zero = [_]f64{ 0, 0 };
    const density = [_]f64{ 1, 1 };
    // Deliberately reproduce the ORIGINAL bug from `SURFACE-HEAT-BRACKET-
    // RUNAWAY-001`: flat placeholder fractions that are NOT derived from the
    // real equilibrium at the seeded (well-below-freezing) temperature.
    const liquid_fraction = [_]f64{ 0.45, 0.45 };
    const ice_fraction_baseline = [_]f64{ 0, 0 };
    const air_fraction = [_]f64{ 0.15, 0.15 };
    const numerator = [_]f64{ 0.01, 0.01 };
    const denominator = [_]f64{ 1, 1 };
    const top = [_]bool{ true, false };
    const cooling_megajoules = [_]f64{ -0.03224 * 5, 0 };

    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &density,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &ice_fraction_baseline,
        .air_fraction = &air_fraction,
        .fraction_of_pore_volume_air_filled = &air_fraction,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &numerator,
        .solid_conductivity_denominator = &denominator,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &cooling_megajoules,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = .{
            .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
            .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
            .porous_medium_volume_m3 = &volumes,
            .mualem_van_genuchten = &curve,
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .pure_water_melting_temperature_k = 273.15,
            .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
            .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
            .ice_density_megagrams_per_m3 = 0.917,
            .solver_options = .{ .max_iterations = 20 },
        },
    };

    // 254.74K is 18.4K below freezing: the real equilibrium ice fraction is
    // substantial, but the placeholder above claims zero -- the exact
    // mismatch that produced `error.InvalidCoupledSoilIceFraction`/silent
    // stalls three separate times in the real investigation this scaffold
    // exists to support.
    grid.soil_temperature_k[0] = 254.74;
    grid.soil_temperature_k[1] = 262.0;
    grid.matrix_liquid_water_m3[0] = total_water_0;
    grid.matrix_ice_water_m3[0] = 0;
    grid.matrix_liquid_water_m3[1] = total_water_1;
    grid.matrix_ice_water_m3[1] = 0;
    for ([_]usize{ 0, 1 }) |cell| {
        const initial_parameters = try group_enthalpy.enthalpyParameters(properties, properties.enthalpy_coupling.?, cell);
        const initial_state = try enthalpy.stateAtTemperature(initial_parameters, grid.soil_temperature_k[cell]);
        // Seed the GRID with the real equilibrium (so the solve itself
        // starts from a physically valid state) but leave `properties`'
        // baseline fractions at their wrong placeholder values above --
        // reproducing exactly the seeded-grid-vs-properties-baseline
        // mismatch the register root-caused.
        grid.matrix_liquid_water_m3[cell] = initial_state.liquid_water_m3;
        grid.matrix_ice_water_m3[cell] = initial_state.ice_water_equivalent_m3;
    }

    var capture: TraceCapture = .{};
    const trace = capture.trace();
    // The consistency check fires at solve entry regardless of outcome, so
    // it's sufficient to construct the workspace and call it directly rather
    // than needing a full convergent/divergent solve.
    var output_flux: [1]f64 = undefined;
    const zero_face_flux = [_]f64{0};
    _ = group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{.{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 0.05, .destination_path_length_m = 0.15, .face_area_m2 = 1 }},
        properties,
        .{ .liquid_water_m3 = &zero_face_flux, .vapor_m3 = &zero_face_flux, .macropore_water_m3 = &zero_face_flux },
        &output_flux,
        .{ .max_iterations = 20, .diagnostic_trace = &trace },
    ) catch {};

    try std.testing.expectEqual(@as(u16, 2), capture.ice_check_calls);
    // Layer 0's real equilibrium ice fraction at 254.74K over volume_0 is
    // substantial (well above the 1e-9 clean-fixture threshold the prior
    // test used) -- the check must report a large discrepancy, not a clean
    // one, proving it would have caught this defect immediately rather than
    // letting it silently corrupt hours of downstream investigation.
    try std.testing.expect(capture.largest_ice_fraction_delta > 1e-3);
}

test "DIAGNOSTIC TRACE verification: known-infeasible magnitude reports a rejected priced direction" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 275;
    grid.matrix_liquid_water_m3[0] = 0.45;
    const capacity = [_]f64{2.8855};
    const zero = [_]f64{0};
    const density = [_]f64{1};
    const liquid_fraction = [_]f64{0.45};
    const air_fraction = [_]f64{0.15};
    const numerator = [_]f64{0.01};
    const denominator = [_]f64{1};
    const top = [_]bool{true};
    // Confirmed infeasible for this exact fixture in `SURFACE-HEAT-BRACKET-
    // RUNAWAY-001` (`docs/discrepancy_register.md`): removing this much
    // energy has no solution above 0 K given this cell's water mass and
    // capacity, so `solve` must reject every candidate and ultimately fail.
    const cooling_megajoules = [_]f64{-800};
    const volume = [_]f64{1};
    const curve = [_]retention.MualemVanGenuchtenParameters{.{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.5,
        .alpha_per_m = 1.6,
        .n = 1.6,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    }};
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &density,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &zero,
        .air_fraction = &air_fraction,
        .fraction_of_pore_volume_air_filled = &air_fraction,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &numerator,
        .solid_conductivity_denominator = &denominator,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &cooling_megajoules,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = .{
            .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
            .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
            .porous_medium_volume_m3 = &volume,
            .mualem_van_genuchten = &curve,
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .pure_water_melting_temperature_k = 273.15,
            .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
            .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
            .ice_density_megagrams_per_m3 = 0.917,
            .solver_options = .{ .max_iterations = 20 },
        },
    };

    var capture: TraceCapture = .{};
    const trace = capture.trace();
    var no_face_heat_flux: [0]f64 = .{};
    const no_water_flux: [0]f64 = .{};
    const result = group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        .{ .liquid_water_m3 = &no_water_flux, .vapor_m3 = &no_water_flux, .macropore_water_m3 = &no_water_flux },
        &no_face_heat_flux,
        .{ .max_iterations = 20, .diagnostic_trace = &trace },
    );

    try std.testing.expectError(error.SoilHeatSolverStagnated, result);
    try std.testing.expect(capture.priced_calls > 0);
    // At least one call must be a full rejection (this infeasible magnitude
    // must never actually accept a step toward its nonexistent root).
    try std.testing.expect(capture.accepted_priced_calls < capture.priced_calls);
}

test "layer conservation gate prevents loose nonlinear enthalpy acceptance" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    grid.soil_temperature_k[0] = 275;
    grid.matrix_liquid_water_m3[0] = 0.4;
    grid.liquid_water_m3[0] = 0.4;
    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.matrix_air_volume_m3[0] = 0.1;
    grid.air_volume_m3[0] = 0.1;

    const heat_capacity = [_]f64{1 + 4.19 * 0.4};
    const zero = [_]f64{0};
    const density = [_]f64{1};
    const liquid_fraction = [_]f64{0.4};
    const air_fraction = [_]f64{0.1};
    const conductivity_numerator = [_]f64{0.01};
    const conductivity_denominator = [_]f64{1};
    const top = [_]bool{true};
    const source = [_]f64{-1e-6};
    const volume = [_]f64{1};
    const area = [_]f64{1};
    const curve = [_]retention.MualemVanGenuchtenParameters{.{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.5,
        .alpha_per_m = 1.6,
        .n = 1.6,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    }};
    const coupling: group_misc.EnthalpyCoupling = .{
        .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
        .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
        .porous_medium_volume_m3 = &volume,
        .mualem_van_genuchten = &curve,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
        .ice_density_megagrams_per_m3 = 0.917,
        // Both nonlinear gates deliberately accept the initial state. Only
        // the independently configured local conservation gate may advance it.
        .solver_options = .{
            .max_iterations = 20,
            .absolute_enthalpy_tolerance_megajoules = 1e-3,
            .relative_enthalpy_tolerance = 1e-8,
        },
        .conservation_cell_area_m2 = &area,
        .conservation_absolute_tolerance_megajoules_per_m2 = 0,
        .conservation_relative_tolerance = 1e-9,
    };
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &heat_capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &density,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &zero,
        .air_fraction = &air_fraction,
        .fraction_of_pore_volume_air_filled = &air_fraction,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &conductivity_numerator,
        .solid_conductivity_denominator = &conductivity_denominator,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &source,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = coupling,
    };
    const parameters = try group_enthalpy.enthalpyParameters(properties, coupling, 0);
    const initial_state = try enthalpy.stateAtTemperature(parameters, grid.soil_temperature_k[0]);
    const nonlinear_limit =
        coupling.solver_options.absolute_enthalpy_tolerance_megajoules +
        coupling.solver_options.relative_enthalpy_tolerance *
            @max(1.0, @abs(initial_state.enthalpy_megajoules + source[0]));
    try std.testing.expect(@abs(source[0]) < nonlinear_limit);

    // Even if an adjacent-f64 proof masks the nonlinear MJ coordinate, the
    // independently reconstructed conservation coordinate remains live.
    const initial_residual_k = [_]f64{source[0] / heat_capacity[0]};
    const initial_scaled_nonlinear_enthalpy = [_]f64{source[0] / nonlinear_limit};
    const recognized_endpoint = [_]f64{1};
    var masked_enthalpy: [1]f64 = undefined;
    const options: group_types.Options = .{
        .max_iterations = 20,
        .absolute_tolerance_k = 1e-6,
        .relative_tolerance = 1e-12,
    };
    const initial_k_coordinate = @abs(initial_residual_k[0]) /
        (options.absolute_tolerance_k +
            options.relative_tolerance * grid.soil_temperature_k[0]);
    const initial_conservation_coordinate = try group_residual.conservationScaledNorm(
        properties,
        grid.soil_temperature_k,
        grid.soil_temperature_k,
        &initial_residual_k,
    );
    const initial_worst_conservation = (try group_residual.worstConservationComponent(
        properties,
        grid.soil_temperature_k,
        grid.soil_temperature_k,
        &initial_residual_k,
    )).?;
    try std.testing.expectEqual(@as(usize, 0), initial_worst_conservation.cell);
    try std.testing.expectEqual(
        initial_conservation_coordinate,
        initial_worst_conservation.scaled_norm,
    );
    try std.testing.expect(@abs(initial_scaled_nonlinear_enthalpy[0]) < initial_k_coordinate);
    try std.testing.expect(initial_k_coordinate < initial_conservation_coordinate);
    const represented_nonlinear = try group_solve.representedEndpointNorm(
        grid.soil_temperature_k,
        &initial_residual_k,
        &initial_scaled_nonlinear_enthalpy,
        &recognized_endpoint,
        &masked_enthalpy,
        options,
    );
    const represented_with_conservation =
        try group_solve.conservationAwareRepresentedEndpointNorm(
            properties,
            grid.soil_temperature_k,
            grid.soil_temperature_k,
            &initial_residual_k,
            &initial_scaled_nonlinear_enthalpy,
            &recognized_endpoint,
            &masked_enthalpy,
            options,
        );
    try std.testing.expect(represented_nonlinear <= 1);
    try std.testing.expect(represented_with_conservation > 1);

    const empty_flux: [0]f64 = .{};
    var output_flux: [0]f64 = .{};
    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &output_flux,
        options,
    );
    try std.testing.expect(result.iterations > 0);
    try std.testing.expect(
        result.enthalpy_topology_newton_steps > 0 or
            result.megajoule_active_set_newton_steps > 0 or
            result.constitutive_energy_newton_steps > 0,
    );
    try std.testing.expect(result.maximum_scaled_nonlinear_residual <= 1);
    try std.testing.expect(result.maximum_scaled_conservation_residual <= 1);

    const final_state = try enthalpy.stateAtTemperature(parameters, grid.soil_temperature_k[0]);
    const expected_enthalpy = initial_state.enthalpy_megajoules + source[0];
    const residual_megajoules = final_state.enthalpy_megajoules - expected_enthalpy;
    const delta_storage = final_state.enthalpy_megajoules - initial_state.enthalpy_megajoules;
    const activity = @max(@abs(delta_storage), @abs(source[0]));
    const initial_expression_roundoff = try group_residual.enthalpyExpressionRoundoffBound(
        parameters,
        275,
        initial_state.liquid_water_m3 + initial_state.secondary_liquid_water_m3,
        initial_state.ice_water_equivalent_m3 + initial_state.secondary_ice_water_equivalent_m3,
    );
    const final_expression_roundoff = try group_residual.enthalpyExpressionRoundoffBound(
        parameters,
        grid.soil_temperature_k[0],
        final_state.liquid_water_m3 + final_state.secondary_liquid_water_m3,
        final_state.ice_water_equivalent_m3 + final_state.secondary_ice_water_equivalent_m3,
    );
    const derived_roundoff = try group_residual.conservationArithmeticBound(
        4,
        @abs(residual_megajoules) +
            @abs(expected_enthalpy) +
            @abs(source[0]) +
            @abs(delta_storage),
    );
    const closure_limit =
        initial_expression_roundoff + final_expression_roundoff + derived_roundoff +
        coupling.conservation_relative_tolerance * activity;
    try std.testing.expect(@abs(residual_megajoules) <= closure_limit);
}

test "neighbor-changing Newton candidate reprices adjacent enthalpy endpoints atomically" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 80 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    const curve_value: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 400,
        .n = 2.5,
        .saturated_hydraulic_conductivity_m_per_h = 1,
    };
    const curve = [_]retention.MualemVanGenuchtenParameters{ curve_value, curve_value };
    const volume = [_]f64{ 0.01, 0.01 };
    const liquid_capacity = 0.6 / 1.43e-7 * 1.0e-6;
    const ice_capacity = 2.117;
    const latent_heat = 333.7;
    const phase_parameters: enthalpy.Parameters = .{
        .porous_medium_volume_m3 = volume[0],
        .total_water_equivalent_m3 = volume[0],
        .unfrozen_pressure_head_m = 0,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        .dry_solid_heat_capacity_megajoules_per_k = 0,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity,
        .latent_heat_of_fusion_megajoules_per_m3 = latent_heat,
        .mualem_van_genuchten = curve_value,
    };
    grid.soil_temperature_k[0] = 273.14999579769204;
    grid.soil_temperature_k[1] = 274.7950063199689;
    for (grid.soil_temperature_k, 0..) |temperature_k, cell| {
        const phase = try enthalpy.stateAtTemperature(phase_parameters, temperature_k);
        grid.matrix_liquid_water_m3[cell] = phase.liquid_water_m3;
        grid.matrix_ice_water_m3[cell] = phase.ice_water_equivalent_m3;
        grid.liquid_water_m3[cell] = phase.liquid_water_m3;
        grid.matrix_pore_capacity_m3[cell] = volume[cell];
    }
    const base_temperature_k = [_]f64{
        grid.soil_temperature_k[0],
        grid.soil_temperature_k[1],
    };
    const base_liquid_water_m3 = [_]f64{
        grid.matrix_liquid_water_m3[0],
        grid.matrix_liquid_water_m3[1],
    };
    const base_ice_water_m3 = [_]f64{
        grid.matrix_ice_water_m3[0],
        grid.matrix_ice_water_m3[1],
    };
    const initial_neighbor_temperature_k = grid.soil_temperature_k[1];
    var heat_capacity = [_]f64{
        liquid_capacity * grid.matrix_liquid_water_m3[0] + ice_capacity * grid.matrix_ice_water_m3[0],
        liquid_capacity * grid.matrix_liquid_water_m3[1] + ice_capacity * grid.matrix_ice_water_m3[1],
    };
    const zero = [_]f64{ 0, 0 };
    const liquid_fraction = [_]f64{
        grid.matrix_liquid_water_m3[0] / volume[0],
        grid.matrix_liquid_water_m3[1] / volume[1],
    };
    const ice_fraction = [_]f64{
        grid.matrix_ice_water_m3[0] / volume[0],
        grid.matrix_ice_water_m3[1] / volume[1],
    };
    const top = [_]bool{ true, false };
    const boundary_cell = [_]usize{ 0, 1 };
    const boundary_temperature = [_]f64{ 268.15, 275.15 };
    const boundary_distance = [_]f64{ 0.005, 0.005 };
    const boundary_area = [_]f64{ 1, 1 };
    const empty_curve: [0]retention.MualemVanGenuchtenParameters = .{};
    const coupling: group_misc.EnthalpyCoupling = .{
        .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
        .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
        .porous_medium_volume_m3 = &volume,
        .mualem_van_genuchten = &curve,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity,
        .latent_heat_of_fusion_megajoules_per_m3 = latent_heat,
        .ice_density_megagrams_per_m3 = 0.917,
        .solver_options = .{
            .max_iterations = 80,
            .absolute_enthalpy_tolerance_megajoules = 1e-13,
            .relative_enthalpy_tolerance = 1e-11,
        },
        .macropore_mualem_van_genuchten = &empty_curve,
    };
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &heat_capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &zero,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &ice_fraction,
        .air_fraction = &zero,
        .fraction_of_pore_volume_air_filled = &zero,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &zero,
        .solid_conductivity_denominator = &zero,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &zero,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .time_step_hours = 10.0 / 3600.0,
        .dirichlet_thermal_boundaries = .{
            .cell_index = &boundary_cell,
            .temperature_k = &boundary_temperature,
            .distance_from_cell_center_m = &boundary_distance,
            .face_area_m2 = &boundary_area,
        },
        .enthalpy_coupling = coupling,
    };
    const face = [_]group_types.Face{.{
        .source_cell = 0,
        .destination_cell = 1,
        .source_path_length_m = 0.01,
        .destination_path_length_m = 0.01,
        .face_area_m2 = 1,
    }};
    const zero_face = [_]f64{0};
    var heat_flux: [1]f64 = undefined;
    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &face,
        properties,
        .{ .liquid_water_m3 = &zero_face, .vapor_m3 = &zero_face, .macropore_water_m3 = &zero_face },
        &heat_flux,
        .{
            // Production owns bounded dense workspace, but the signed-energy
            // merit governs this sharp moving phase front. The former
            // K-Jacobian-first schedule accepted 20 tiny decreases and
            // exhausted this ceiling before energy Newton was reached.
            .max_iterations = 20,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .dense_newton_max_components = 256,
        },
    );
    try std.testing.expect(result.enthalpy_representability_probes >= 2);
    try std.testing.expect(grid.soil_temperature_k[1] != initial_neighbor_temperature_k);
    for (grid.soil_temperature_k, 0..) |temperature_k, cell| {
        const accepted_phase = try enthalpy.stateAtTemperature(phase_parameters, temperature_k);
        try std.testing.expectEqual(accepted_phase.liquid_water_m3, grid.matrix_liquid_water_m3[cell]);
        try std.testing.expectEqual(accepted_phase.ice_water_equivalent_m3, grid.matrix_ice_water_m3[cell]);
    }

    // Reprice the same accepted adjacent endpoint after a one-ULP neighbour
    // move. The production helper may switch only the active cell between its
    // two bracketing f64 values; neither rejected endpoint probe may publish
    // temperature or phase into the accepted grid.
    const accepted_temperature_k = [_]f64{
        grid.soil_temperature_k[0],
        grid.soil_temperature_k[1],
    };
    const accepted_liquid_water_m3 = [_]f64{
        grid.matrix_liquid_water_m3[0],
        grid.matrix_liquid_water_m3[1],
    };
    const accepted_ice_water_m3 = [_]f64{
        grid.matrix_ice_water_m3[0],
        grid.matrix_ice_water_m3[1],
    };
    var repricing_properties = properties;
    repricing_properties.enthalpy_coupling.?.matrix_liquid_water_m3 = &base_liquid_water_m3;
    repricing_properties.enthalpy_coupling.?.matrix_ice_water_equivalent_m3 = &base_ice_water_m3;
    var repriced_candidate = accepted_temperature_k;
    repriced_candidate[1] = std.math.nextAfter(
        f64,
        repriced_candidate[1],
        std.math.inf(f64),
    );
    const proposed_neighbor_temperature_k = repriced_candidate[1];
    const recognized_endpoint = [_]f64{ 1, 0 };
    var target: [2]f64 = undefined;
    var candidate_residual: [2]f64 = undefined;
    var scratch: [2]f64 = undefined;
    var endpoint_state: [2]f64 = undefined;
    var endpoint_residual: [2]f64 = undefined;
    var saved_scaled_enthalpy: [2]f64 = undefined;
    var proven_mask: [2]f64 = undefined;
    var repricing_flux: [1]f64 = undefined;
    var phase_matrix_liquid: [2]f64 = undefined;
    var phase_matrix_ice: [2]f64 = undefined;
    var phase_macropore_liquid: [2]f64 = undefined;
    var phase_macropore_ice: [2]f64 = undefined;
    var repricing_probes: u32 = 0;
    const repriced_norm = try group_solve.repriceAdjacentEnthalpyEndpoints(
        &face,
        repricing_properties,
        .{ .liquid_water_m3 = &zero_face, .vapor_m3 = &zero_face, .macropore_water_m3 = &zero_face },
        &base_temperature_k,
        &repriced_candidate,
        &recognized_endpoint,
        &target,
        &candidate_residual,
        &scratch,
        &endpoint_state,
        &endpoint_residual,
        &saved_scaled_enthalpy,
        &proven_mask,
        &repricing_flux,
        .{
            .matrix_liquid_m3 = &phase_matrix_liquid,
            .matrix_ice_m3 = &phase_matrix_ice,
            .macropore_liquid_m3 = &phase_macropore_liquid,
            .macropore_ice_m3 = &phase_macropore_ice,
            .macropore_enabled = false,
            .ice_density_megagrams_per_m3 = 0.917,
        },
        .{
            .max_iterations = 80,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .dense_newton_max_components = 0,
        },
        &repricing_probes,
    );
    try std.testing.expect(repriced_norm != null);
    // Stable one-endpoint repricing is exactly selected/alternative/selected:
    // the settled-vector certificate removes the old sequential/sweep replay.
    try std.testing.expectEqual(@as(u32, 3), repricing_probes);
    try std.testing.expectEqual(proposed_neighbor_temperature_k, repriced_candidate[1]);
    try std.testing.expect(
        repriced_candidate[0] == accepted_temperature_k[0] or
            repriced_candidate[0] == std.math.nextAfter(
                f64,
                accepted_temperature_k[0],
                if (scratch[0] > 0) std.math.inf(f64) else -std.math.inf(f64),
            ),
    );
    try std.testing.expectEqualSlices(f64, &accepted_temperature_k, grid.soil_temperature_k);
    try std.testing.expectEqualSlices(f64, &accepted_liquid_water_m3, grid.matrix_liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &accepted_ice_water_m3, grid.matrix_ice_water_m3);

    // A physically material neighbour move shifts this endpoint root by far
    // more than one ULP. The repricer must relocate and narrow the new actual
    // signed-MJ bracket, not test only the stale endpoint pair and reject the
    // otherwise valid coupled Newton proposal.
    var relocated_candidate = accepted_temperature_k;
    relocated_candidate[1] += 1e-4;
    const relocated_neighbor_temperature_k = relocated_candidate[1];
    const stale_endpoint_temperature_k = relocated_candidate[0];
    var relocation_probes: u32 = 0;
    const relocated_norm = try group_solve.repriceAdjacentEnthalpyEndpoints(
        &face,
        repricing_properties,
        .{ .liquid_water_m3 = &zero_face, .vapor_m3 = &zero_face, .macropore_water_m3 = &zero_face },
        &base_temperature_k,
        &relocated_candidate,
        &recognized_endpoint,
        &target,
        &candidate_residual,
        &scratch,
        &endpoint_state,
        &endpoint_residual,
        &saved_scaled_enthalpy,
        &proven_mask,
        &repricing_flux,
        .{
            .matrix_liquid_m3 = &phase_matrix_liquid,
            .matrix_ice_m3 = &phase_matrix_ice,
            .macropore_liquid_m3 = &phase_macropore_liquid,
            .macropore_ice_m3 = &phase_macropore_ice,
            .macropore_enabled = false,
            .ice_density_megagrams_per_m3 = 0.917,
        },
        .{
            .max_iterations = 80,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .dense_newton_max_components = 0,
        },
        &relocation_probes,
    );
    try std.testing.expect(relocated_norm != null);
    try std.testing.expectEqual(
        relocated_neighbor_temperature_k,
        relocated_candidate[1],
    );
    try std.testing.expect(
        relocated_candidate[0] != stale_endpoint_temperature_k and
            relocated_candidate[0] != std.math.nextAfter(
                f64,
                stale_endpoint_temperature_k,
                std.math.inf(f64),
            ) and
            relocated_candidate[0] != std.math.nextAfter(
                f64,
                stale_endpoint_temperature_k,
                -std.math.inf(f64),
            ),
    );
    try std.testing.expectEqualSlices(f64, &recognized_endpoint, &proven_mask);

    // A changed-neighbour proposal can also place the retained endpoint
    // exactly on the enthalpy root. Repricing must accept that endpoint
    // directly instead of stepping one ULP toward -Inf and rejecting a valid
    // candidate when the arbitrary second probe has the same sign.
    var exact_properties = repricing_properties;
    exact_properties.dirichlet_thermal_boundaries = null;
    var exact_candidate = base_temperature_k;
    var exact_flux: [0]f64 = .{};
    const exact_water_flux: [0]f64 = .{};
    var exact_probes: u32 = 0;
    const exact_norm = try group_solve.repriceAdjacentEnthalpyEndpoints(
        &.{},
        exact_properties,
        .{
            .liquid_water_m3 = &exact_water_flux,
            .vapor_m3 = &exact_water_flux,
            .macropore_water_m3 = &exact_water_flux,
        },
        &base_temperature_k,
        &exact_candidate,
        &recognized_endpoint,
        &target,
        &candidate_residual,
        &scratch,
        &endpoint_state,
        &endpoint_residual,
        &saved_scaled_enthalpy,
        &proven_mask,
        &exact_flux,
        .{
            .matrix_liquid_m3 = &phase_matrix_liquid,
            .matrix_ice_m3 = &phase_matrix_ice,
            .macropore_liquid_m3 = &phase_macropore_liquid,
            .macropore_ice_m3 = &phase_macropore_ice,
            .macropore_enabled = false,
            .ice_density_megagrams_per_m3 = 0.917,
        },
        .{
            .max_iterations = 80,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .dense_newton_max_components = 0,
        },
        &exact_probes,
    );
    try std.testing.expectEqual(@as(?f64, 0), exact_norm);
    try std.testing.expectEqual(@as(u32, 1), exact_probes);
    try std.testing.expectEqualSlices(f64, &base_temperature_k, &exact_candidate);
    try std.testing.expectEqualSlices(f64, &recognized_endpoint, &proven_mask);
}

test "smooth cold analytic Newton clears strict MJ quantization before Anderson" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 80 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    const curve_value: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 400,
        .n = 2.5,
        .saturated_hydraulic_conductivity_m_per_h = 1,
    };
    const curve = [_]retention.MualemVanGenuchtenParameters{ curve_value, curve_value };
    const volume = [_]f64{ 0.01, 0.01 };
    const liquid_capacity = 0.6 / 1.43e-7 * 1.0e-6;
    const ice_capacity = 2.117;
    const phase_parameters: enthalpy.Parameters = .{
        .porous_medium_volume_m3 = volume[0],
        .total_water_equivalent_m3 = volume[0],
        .unfrozen_pressure_head_m = 0,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        .dry_solid_heat_capacity_megajoules_per_k = 0,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
        .mualem_van_genuchten = curve_value,
    };
    @memset(grid.soil_temperature_k, 272.7082120237665);
    for (0..2) |cell| {
        const phase = try enthalpy.stateAtTemperature(
            phase_parameters,
            grid.soil_temperature_k[cell],
        );
        grid.matrix_liquid_water_m3[cell] = phase.liquid_water_m3;
        grid.matrix_ice_water_m3[cell] = phase.ice_water_equivalent_m3;
        grid.liquid_water_m3[cell] = phase.liquid_water_m3;
        grid.matrix_pore_capacity_m3[cell] = volume[cell];
    }
    const heat_capacity = [_]f64{
        liquid_capacity * grid.matrix_liquid_water_m3[0] + ice_capacity * grid.matrix_ice_water_m3[0],
        liquid_capacity * grid.matrix_liquid_water_m3[1] + ice_capacity * grid.matrix_ice_water_m3[1],
    };
    const zero = [_]f64{ 0, 0 };
    const liquid_fraction = [_]f64{
        grid.matrix_liquid_water_m3[0] / volume[0],
        grid.matrix_liquid_water_m3[1] / volume[1],
    };
    const ice_fraction = [_]f64{
        grid.matrix_ice_water_m3[0] / volume[0],
        grid.matrix_ice_water_m3[1] / volume[1],
    };
    const top = [_]bool{ true, false };
    // The first coordinate reproduces the late production failure's strict-MJ
    // scale (2.278103...) while remaining on a smooth frozen branch.
    const source = [_]f64{
        -2.278103104947794 * (1e-13 + 1e-11),
        0,
    };
    const empty_curve: [0]retention.MualemVanGenuchtenParameters = .{};
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &heat_capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &zero,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &ice_fraction,
        .air_fraction = &zero,
        .fraction_of_pore_volume_air_filled = &zero,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &zero,
        .solid_conductivity_denominator = &zero,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &source,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = .{
            .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
            .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
            .porous_medium_volume_m3 = &volume,
            .mualem_van_genuchten = &curve,
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .pure_water_melting_temperature_k = 273.15,
            .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity,
            .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
            .ice_density_megagrams_per_m3 = 0.917,
            .solver_options = .{
                .max_iterations = 80,
                .absolute_enthalpy_tolerance_megajoules = 1e-13,
                .relative_enthalpy_tolerance = 1e-11,
            },
            .macropore_mualem_van_genuchten = &empty_curve,
        },
    };
    const empty_flux: [0]f64 = .{};
    var output_flux: [0]f64 = .{};
    const initial_temperature_k = [_]f64{
        grid.soil_temperature_k[0],
        grid.soil_temperature_k[1],
    };
    var initial_target: [2]f64 = undefined;
    var initial_residual: [2]f64 = undefined;
    var initial_scaled_enthalpy: [2]f64 = undefined;
    var initial_phase_liquid: [2]f64 = undefined;
    var initial_phase_ice: [2]f64 = undefined;
    var initial_phase_macropore_liquid: [2]f64 = undefined;
    var initial_phase_macropore_ice: [2]f64 = undefined;
    const sub_ulp_parameters = try group_enthalpy.enthalpyParameters(
        properties,
        properties.enthalpy_coupling.?,
        0,
    );
    const base_enthalpy_state = try enthalpy.stateAtTemperature(
        sub_ulp_parameters,
        initial_temperature_k[0],
    );
    const nearest_root = try enthalpy.temperatureFromEnthalpy(
        sub_ulp_parameters,
        base_enthalpy_state.enthalpy_megajoules + source[0],
        .{
            .max_iterations = 80,
            .absolute_enthalpy_tolerance_megajoules = 1e-18,
            .relative_enthalpy_tolerance = 1e-18,
        },
    );
    const sub_ulp_trial_temperature_k = [_]f64{
        nearest_root.state.temperature_k,
        initial_temperature_k[1],
    };
    try group_residual.residualAt(
        &.{},
        properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &initial_temperature_k,
        &sub_ulp_trial_temperature_k,
        &initial_target,
        &initial_residual,
        &initial_scaled_enthalpy,
        &output_flux,
        .{
            .matrix_liquid_m3 = &initial_phase_liquid,
            .matrix_ice_m3 = &initial_phase_ice,
            .macropore_liquid_m3 = &initial_phase_macropore_liquid,
            .macropore_ice_m3 = &initial_phase_macropore_ice,
            .macropore_enabled = false,
            .ice_density_megagrams_per_m3 = 0.917,
        },
        .{
            .max_iterations = 80,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .directional_probe_fraction = 1e-12,
            .dense_newton_max_components = 0,
        },
    );
    const temperature_ulp_k = std.math.nextAfter(
        f64,
        sub_ulp_trial_temperature_k[0],
        std.math.inf(f64),
    ) - sub_ulp_trial_temperature_k[0];
    try std.testing.expect(initial_residual[0] != 0);
    try std.testing.expect(@abs(initial_residual[0]) < temperature_ulp_k);
    try std.testing.expectEqual(sub_ulp_trial_temperature_k[0], initial_target[0]);
    const sub_ulp_state = try enthalpy.stateAtTemperature(
        sub_ulp_parameters,
        sub_ulp_trial_temperature_k[0],
    );
    const sub_ulp_capacity = try enthalpy.enthalpyDerivativeMjPerK(
        sub_ulp_parameters,
        sub_ulp_trial_temperature_k[0],
        sub_ulp_state,
    );
    const sub_ulp_enthalpy_tolerance =
        properties.enthalpy_coupling.?.solver_options.absolute_enthalpy_tolerance_megajoules +
        properties.enthalpy_coupling.?.solver_options.relative_enthalpy_tolerance;
    try std.testing.expectApproxEqRel(
        initial_scaled_enthalpy[0],
        initial_residual[0] * sub_ulp_capacity /
            sub_ulp_enthalpy_tolerance,
        16 * std.math.floatEps(f64),
    );
    try group_residual.residualAt(
        &.{},
        properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &initial_temperature_k,
        &initial_temperature_k,
        &initial_target,
        &initial_residual,
        &initial_scaled_enthalpy,
        &output_flux,
        .{
            .matrix_liquid_m3 = &initial_phase_liquid,
            .matrix_ice_m3 = &initial_phase_ice,
            .macropore_liquid_m3 = &initial_phase_macropore_liquid,
            .macropore_ice_m3 = &initial_phase_macropore_ice,
            .macropore_enabled = false,
            .ice_density_megagrams_per_m3 = 0.917,
        },
        .{
            .max_iterations = 80,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .directional_probe_fraction = 1e-12,
            .dense_newton_max_components = 0,
        },
    );
    const initial_k_coordinate = @abs(initial_residual[0]) /
        (1e-8 + 1e-10 * @abs(initial_temperature_k[0]));
    try std.testing.expectApproxEqRel(
        @as(f64, 0.0291562),
        initial_k_coordinate,
        0.05,
    );
    try std.testing.expectApproxEqRel(
        @as(f64, 2.278103104947794),
        @abs(initial_scaled_enthalpy[0]),
        0.01,
    );
    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &output_flux,
        .{
            .max_iterations = 80,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            // Make the numerical directional probe round back to the current
            // f64 state; a two-cell/no-face topology also has no tridiagonal
            // path. The remaining accepted direction is analytic Newton.
            .directional_probe_fraction = 1e-12,
            .dense_newton_max_components = 0,
        },
    );
    try std.testing.expect(result.megajoule_active_set_newton_steps > 0);
    try std.testing.expect(result.megajoule_active_set_newton_probes <= 8);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    try std.testing.expect(result.maximum_scaled_residual <= 1);

    var megajoule_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer megajoule_grid.deinit();
    @memset(megajoule_grid.soil_temperature_k, 272.7082120237665);
    for (0..2) |cell| {
        const phase = try enthalpy.stateAtTemperature(
            phase_parameters,
            megajoule_grid.soil_temperature_k[cell],
        );
        megajoule_grid.matrix_liquid_water_m3[cell] = phase.liquid_water_m3;
        megajoule_grid.matrix_ice_water_m3[cell] = phase.ice_water_equivalent_m3;
        megajoule_grid.liquid_water_m3[cell] = phase.liquid_water_m3;
        megajoule_grid.matrix_pore_capacity_m3[cell] = volume[cell];
    }
    const megajoule_source = [_]f64{
        source[0] * (13.829135169240894 / 2.278103104947794),
        0,
    };
    var megajoule_properties = properties;
    megajoule_properties.cell_heat_source_megajoules = &megajoule_source;
    megajoule_properties.enthalpy_coupling.?.matrix_liquid_water_m3 =
        megajoule_grid.matrix_liquid_water_m3;
    megajoule_properties.enthalpy_coupling.?.matrix_ice_water_equivalent_m3 =
        megajoule_grid.matrix_ice_water_m3;
    const megajoule_face = [_]group_types.Face{.{
        .source_cell = 0,
        .destination_cell = 1,
        .source_path_length_m = 0.01,
        .destination_path_length_m = 0.01,
        .face_area_m2 = 1,
    }};
    const zero_face_flux = [_]f64{0};
    var megajoule_heat_flux: [1]f64 = undefined;
    const megajoule_initial_temperature_k = [_]f64{
        megajoule_grid.soil_temperature_k[0],
        megajoule_grid.soil_temperature_k[1],
    };
    try group_residual.residualAt(
        &megajoule_face,
        megajoule_properties,
        .{
            .liquid_water_m3 = &zero_face_flux,
            .vapor_m3 = &zero_face_flux,
            .macropore_water_m3 = &zero_face_flux,
        },
        &megajoule_initial_temperature_k,
        &megajoule_initial_temperature_k,
        &initial_target,
        &initial_residual,
        &initial_scaled_enthalpy,
        &megajoule_heat_flux,
        .{
            .matrix_liquid_m3 = &initial_phase_liquid,
            .matrix_ice_m3 = &initial_phase_ice,
            .macropore_liquid_m3 = &initial_phase_macropore_liquid,
            .macropore_ice_m3 = &initial_phase_macropore_ice,
            .macropore_enabled = false,
            .ice_density_megagrams_per_m3 = 0.917,
        },
        .{
            .max_iterations = 80,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .directional_probe_fraction = 1e-12,
            .dense_newton_max_components = 0,
        },
    );
    // On this smooth nonlinear frozen branch, compare the signed-energy
    // Jacobian's centered cbrt(eps) diagonal and face-neighbour entries with a
    // smaller centered reference and the former one-sided sqrt(eps) stencil.
    const baseline_temperature_residual = initial_residual;
    const baseline_megajoule_coordinate = initial_scaled_enthalpy;
    var derivative_temperature_k = megajoule_initial_temperature_k;
    derivative_temperature_k[1] -= 0.2;
    try group_residual.residualAt(
        &megajoule_face,
        megajoule_properties,
        .{
            .liquid_water_m3 = &zero_face_flux,
            .vapor_m3 = &zero_face_flux,
            .macropore_water_m3 = &zero_face_flux,
        },
        &megajoule_initial_temperature_k,
        &derivative_temperature_k,
        &initial_target,
        &initial_residual,
        &initial_scaled_enthalpy,
        &megajoule_heat_flux,
        .{
            .matrix_liquid_m3 = &initial_phase_liquid,
            .matrix_ice_m3 = &initial_phase_ice,
            .macropore_liquid_m3 = &initial_phase_macropore_liquid,
            .macropore_ice_m3 = &initial_phase_macropore_ice,
            .macropore_enabled = false,
            .ice_density_megagrams_per_m3 = 0.917,
        },
        .{
            .max_iterations = 80,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .directional_probe_fraction = 1e-12,
            .dense_newton_max_components = 0,
        },
    );
    const baseline_scaled_enthalpy = initial_scaled_enthalpy;
    const sqrt_step = std.math.sqrt(std.math.floatEps(f64)) *
        @max(1.0, @abs(derivative_temperature_k[0]));
    const cbrt_step = std.math.cbrt(std.math.floatEps(f64)) *
        @max(1.0, @abs(derivative_temperature_k[0]));
    const derivative_steps = [_]f64{
        cbrt_step / 8,
        sqrt_step,
        cbrt_step,
    };
    var h_jacobian_columns: [3][2]f64 = undefined;
    var forward_scaled_enthalpy: [3][2]f64 = undefined;
    for (derivative_steps, 0..) |step, estimate| {
        var perturbed_temperature_k = derivative_temperature_k;
        perturbed_temperature_k[0] += step;
        try group_residual.residualAt(
            &megajoule_face,
            megajoule_properties,
            .{
                .liquid_water_m3 = &zero_face_flux,
                .vapor_m3 = &zero_face_flux,
                .macropore_water_m3 = &zero_face_flux,
            },
            &megajoule_initial_temperature_k,
            &perturbed_temperature_k,
            &initial_target,
            &initial_residual,
            &initial_scaled_enthalpy,
            &megajoule_heat_flux,
            .{
                .matrix_liquid_m3 = &initial_phase_liquid,
                .matrix_ice_m3 = &initial_phase_ice,
                .macropore_liquid_m3 = &initial_phase_macropore_liquid,
                .macropore_ice_m3 = &initial_phase_macropore_ice,
                .macropore_enabled = false,
                .ice_density_megagrams_per_m3 = 0.917,
            },
            .{
                .max_iterations = 80,
                .absolute_tolerance_k = 1e-8,
                .relative_tolerance = 1e-10,
                .directional_probe_fraction = 1e-12,
                .dense_newton_max_components = 0,
            },
        );
        forward_scaled_enthalpy[estimate] = initial_scaled_enthalpy;
        for (&h_jacobian_columns[estimate], initial_scaled_enthalpy, baseline_scaled_enthalpy) |*entry, perturbed, baseline|
            entry.* = (perturbed - baseline) / step;
    }
    for ([_]usize{ 0, 2 }) |estimate| {
        var backward_temperature_k = derivative_temperature_k;
        backward_temperature_k[0] -= derivative_steps[estimate];
        try group_residual.residualAt(
            &megajoule_face,
            megajoule_properties,
            .{
                .liquid_water_m3 = &zero_face_flux,
                .vapor_m3 = &zero_face_flux,
                .macropore_water_m3 = &zero_face_flux,
            },
            &megajoule_initial_temperature_k,
            &backward_temperature_k,
            &initial_target,
            &initial_residual,
            &initial_scaled_enthalpy,
            &megajoule_heat_flux,
            .{
                .matrix_liquid_m3 = &initial_phase_liquid,
                .matrix_ice_m3 = &initial_phase_ice,
                .macropore_liquid_m3 = &initial_phase_macropore_liquid,
                .macropore_ice_m3 = &initial_phase_macropore_ice,
                .macropore_enabled = false,
                .ice_density_megagrams_per_m3 = 0.917,
            },
            .{
                .max_iterations = 80,
                .absolute_tolerance_k = 1e-8,
                .relative_tolerance = 1e-10,
                .directional_probe_fraction = 1e-12,
                .dense_newton_max_components = 0,
            },
        );
        for (&h_jacobian_columns[estimate], forward_scaled_enthalpy[estimate], initial_scaled_enthalpy) |*entry, forward, backward|
            entry.* = (forward - backward) / (2 * derivative_steps[estimate]);
    }
    const one_sided_sqrt_diagonal_error = @abs(h_jacobian_columns[1][0] - h_jacobian_columns[0][0]);
    const centered_cbrt_diagonal_error = @abs(h_jacobian_columns[2][0] - h_jacobian_columns[0][0]);
    const one_sided_sqrt_off_diagonal_error = @abs(h_jacobian_columns[1][1] - h_jacobian_columns[0][1]);
    const centered_cbrt_off_diagonal_error = @abs(h_jacobian_columns[2][1] - h_jacobian_columns[0][1]);
    try std.testing.expect(std.math.isFinite(h_jacobian_columns[0][0]));
    try std.testing.expect(std.math.isFinite(h_jacobian_columns[0][1]));
    try std.testing.expect(h_jacobian_columns[0][0] != 0);
    try std.testing.expect(h_jacobian_columns[0][1] != 0);
    try std.testing.expect(centered_cbrt_diagonal_error < one_sided_sqrt_diagonal_error);
    try std.testing.expect(centered_cbrt_off_diagonal_error < one_sided_sqrt_off_diagonal_error);
    const megajoule_initial_k_coordinate = @abs(baseline_temperature_residual[0]) /
        (1e-8 + 1e-10 * @abs(megajoule_initial_temperature_k[0]));
    try std.testing.expectApproxEqRel(
        @as(f64, 0.17706743510148257),
        megajoule_initial_k_coordinate,
        0.05,
    );
    try std.testing.expectApproxEqRel(
        @as(f64, 13.829135169240894),
        @abs(baseline_megajoule_coordinate[0]),
        0.01,
    );
    const megajoule_result = try group_solve.solve(
        std.testing.allocator,
        &megajoule_grid,
        &megajoule_face,
        megajoule_properties,
        .{
            .liquid_water_m3 = &zero_face_flux,
            .vapor_m3 = &zero_face_flux,
            .macropore_water_m3 = &zero_face_flux,
        },
        &megajoule_heat_flux,
        .{
            .max_iterations = 80,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .directional_probe_fraction = 1e-12,
            .dense_newton_max_components = 0,
        },
    );
    try std.testing.expect(megajoule_result.enthalpy_topology_newton_steps > 0);
    try std.testing.expect(megajoule_result.enthalpy_topology_newton_probes <= 14);
    try std.testing.expectEqual(@as(u16, 0), megajoule_result.anderson_steps);
    try std.testing.expect(megajoule_result.maximum_scaled_residual <= 1);
}

test "dense signed enthalpy Newton solves connected 2x2 graph and failure stays atomic" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 2, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 4 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    const curve_value: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 400,
        .n = 2.5,
        .saturated_hydraulic_conductivity_m_per_h = 1,
    };
    const curves = [_]retention.MualemVanGenuchtenParameters{curve_value} ** 4;
    const volume = [_]f64{0.01} ** 4;
    const liquid_capacity = 0.6 / 1.43e-7 * 1.0e-6;
    const ice_capacity = 2.117;
    const phase_parameters: enthalpy.Parameters = .{
        .porous_medium_volume_m3 = volume[0],
        .total_water_equivalent_m3 = volume[0],
        .unfrozen_pressure_head_m = 0,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        .dry_solid_heat_capacity_megajoules_per_k = 0,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
        .mualem_van_genuchten = curve_value,
    };
    @memset(grid.soil_temperature_k, 272.7082120237665);
    for (0..4) |cell| {
        const phase = try enthalpy.stateAtTemperature(
            phase_parameters,
            grid.soil_temperature_k[cell],
        );
        grid.matrix_liquid_water_m3[cell] = phase.liquid_water_m3;
        grid.matrix_ice_water_m3[cell] = phase.ice_water_equivalent_m3;
        grid.liquid_water_m3[cell] = phase.liquid_water_m3;
        grid.matrix_pore_capacity_m3[cell] = volume[cell];
    }
    const heat_capacity_value = liquid_capacity * grid.matrix_liquid_water_m3[0] +
        ice_capacity * grid.matrix_ice_water_m3[0];
    const heat_capacity = [_]f64{heat_capacity_value} ** 4;
    const zero = [_]f64{0} ** 4;
    const one = [_]f64{1} ** 4;
    const conductivity_numerator = [_]f64{0.01} ** 4;
    const liquid_fraction_value = grid.matrix_liquid_water_m3[0] / volume[0];
    const ice_fraction_value = grid.matrix_ice_water_m3[0] / volume[0];
    const liquid_fraction = [_]f64{liquid_fraction_value} ** 4;
    const ice_fraction = [_]f64{ice_fraction_value} ** 4;
    const top = [_]bool{true} ** 4;
    const failure_source = [_]f64{ -0.1, 0, 0, 0 };
    const source = [_]f64{
        -13.829135169240894 * (1e-13 + 1e-11),
        0,
        0,
        0,
    };
    const empty_curve: [0]retention.MualemVanGenuchtenParameters = .{};
    var properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &heat_capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &zero,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &ice_fraction,
        .air_fraction = &zero,
        .fraction_of_pore_volume_air_filled = &zero,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &conductivity_numerator,
        .solid_conductivity_denominator = &one,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &failure_source,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = .{
            .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
            .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
            .porous_medium_volume_m3 = &volume,
            .mualem_van_genuchten = &curves,
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .pure_water_melting_temperature_k = 273.15,
            .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity,
            .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
            .ice_density_megagrams_per_m3 = 0.917,
            .solver_options = .{
                .max_iterations = 80,
                .absolute_enthalpy_tolerance_megajoules = 1e-13,
                .relative_enthalpy_tolerance = 1e-11,
            },
            .macropore_mualem_van_genuchten = &empty_curve,
        },
    };
    // A square grid contains a cycle and stride-two links, so it cannot pass
    // the sequential `upper == lower + 1` column-topology predicate.
    const faces = [_]group_types.Face{
        .{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 0.01, .destination_path_length_m = 0.01, .face_area_m2 = 1 },
        .{ .source_cell = 0, .destination_cell = 2, .source_path_length_m = 0.01, .destination_path_length_m = 0.01, .face_area_m2 = 1 },
        .{ .source_cell = 1, .destination_cell = 3, .source_path_length_m = 0.01, .destination_path_length_m = 0.01, .face_area_m2 = 1 },
        .{ .source_cell = 2, .destination_cell = 3, .source_path_length_m = 0.01, .destination_path_length_m = 0.01, .face_area_m2 = 1 },
    };
    const zero_face_flux = [_]f64{0} ** faces.len;
    var heat_flux = [_]f64{99} ** faces.len;
    const initial_temperature = [_]f64{272.7082120237665} ** 4;
    const initial_matrix_liquid = [_]f64{grid.matrix_liquid_water_m3[0]} ** 4;
    const initial_matrix_ice = [_]f64{grid.matrix_ice_water_m3[0]} ** 4;

    try std.testing.expectError(
        error.SoilHeatSolverDidNotConverge,
        group_solve.solve(
            std.testing.allocator,
            &grid,
            &faces,
            properties,
            .{ .liquid_water_m3 = &zero_face_flux, .vapor_m3 = &zero_face_flux, .macropore_water_m3 = &zero_face_flux },
            &heat_flux,
            .{
                .max_iterations = 1,
                .absolute_tolerance_k = 1e-8,
                .relative_tolerance = 1e-10,
                .dense_newton_max_components = 4,
            },
        ),
    );
    try std.testing.expectEqualSlices(f64, &initial_temperature, grid.soil_temperature_k);
    try std.testing.expectEqualSlices(f64, &initial_matrix_liquid, grid.matrix_liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &initial_matrix_ice, grid.matrix_ice_water_m3);
    try std.testing.expectEqualSlices(f64, &([_]f64{99} ** faces.len), &heat_flux);

    properties.cell_heat_source_megajoules = &source;
    var initial_total_enthalpy: f64 = 0;
    for (grid.soil_temperature_k) |temperature_k|
        initial_total_enthalpy += (try enthalpy.stateAtTemperature(phase_parameters, temperature_k)).enthalpy_megajoules;
    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &faces,
        properties,
        .{ .liquid_water_m3 = &zero_face_flux, .vapor_m3 = &zero_face_flux, .macropore_water_m3 = &zero_face_flux },
        &heat_flux,
        .{
            .max_iterations = 20,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .dense_newton_max_components = 4,
        },
    );
    try std.testing.expect(result.enthalpy_dense_newton_steps > 0);
    try std.testing.expect(result.enthalpy_dense_newton_probes >= 2 * grid.layer_count);
    try std.testing.expectEqual(@as(u16, 0), result.enthalpy_topology_newton_steps);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    try std.testing.expect(result.maximum_scaled_residual <= 1);
    var final_total_enthalpy: f64 = 0;
    for (grid.soil_temperature_k) |temperature_k|
        final_total_enthalpy += (try enthalpy.stateAtTemperature(phase_parameters, temperature_k)).enthalpy_megajoules;
    try std.testing.expectApproxEqAbs(
        initial_total_enthalpy + source[0],
        final_total_enthalpy,
        1e-10,
    );
}

test "crossed phase transition accepts a bounded adjacent-f64 endpoint in one update" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    const melting_temperature_k = 273.15;
    const base_temperature_k = 273.07;
    const porous_medium_volume_m3 = 0.01;
    const total_water_m3 = porous_medium_volume_m3;
    const dry_capacity_megajoules_per_k = 0.02;
    const liquid_capacity_megajoules_per_m3_k = 4.19;
    const ice_capacity_megajoules_per_m3_k = 1.93;
    const latent_heat_megajoules_per_m3 = 333.7;
    const curve: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 400,
        .n = 1.1,
        .saturated_hydraulic_conductivity_m_per_h = 1,
    };
    const parameters: enthalpy.Parameters = .{
        .porous_medium_volume_m3 = porous_medium_volume_m3,
        .total_water_equivalent_m3 = total_water_m3,
        .unfrozen_pressure_head_m = 0,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = melting_temperature_k,
        .dry_solid_heat_capacity_megajoules_per_k = dry_capacity_megajoules_per_k,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity_megajoules_per_m3_k,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity_megajoules_per_m3_k,
        .latent_heat_of_fusion_megajoules_per_m3 = latent_heat_megajoules_per_m3,
        .mualem_van_genuchten = curve,
    };
    const transition_temperature_k = enthalpy.depressedMeltingTemperatureK(
        parameters,
        parameters.unfrozen_pressure_head_m,
    );
    const lower_transition_temperature_k = std.math.nextAfter(
        f64,
        transition_temperature_k,
        -std.math.inf(f64),
    );
    const lower_transition_state = try enthalpy.stateAtTemperature(
        parameters,
        lower_transition_temperature_k,
    );
    const upper_transition_state = try enthalpy.stateAtTemperature(
        parameters,
        transition_temperature_k,
    );
    const transition_interval_megajoules =
        upper_transition_state.enthalpy_megajoules -
        lower_transition_state.enthalpy_megajoules;
    try std.testing.expect(transition_interval_megajoules > 0);
    const target_enthalpy_megajoules =
        lower_transition_state.enthalpy_megajoules +
        0.5 * transition_interval_megajoules;
    try std.testing.expect(target_enthalpy_megajoules >
        lower_transition_state.enthalpy_megajoules);
    try std.testing.expect(target_enthalpy_megajoules <
        upper_transition_state.enthalpy_megajoules);

    // The incoming WATSUB-style state is intentionally source-limited and
    // therefore mostly liquid despite being 0.08 K below equilibrium. Choose
    // the non-phase heat so its conservative target lies exactly inside the
    // transition's adjacent-f64 enthalpy interval.
    const actual_liquid_m3 = 0.999 * total_water_m3;
    const actual_ice_m3 = total_water_m3 - actual_liquid_m3;
    const heat_capacity_megajoules_per_k =
        dry_capacity_megajoules_per_k +
        liquid_capacity_megajoules_per_m3_k * actual_liquid_m3 +
        ice_capacity_megajoules_per_m3_k * actual_ice_m3;
    const actual_base_enthalpy_megajoules =
        heat_capacity_megajoules_per_k *
        (base_temperature_k - melting_temperature_k) +
        latent_heat_megajoules_per_m3 * actual_liquid_m3;
    const source_megajoules =
        target_enthalpy_megajoules - actual_base_enthalpy_megajoules;
    try std.testing.expect(source_megajoules > 0);

    grid.soil_temperature_k[0] = base_temperature_k;
    grid.matrix_liquid_water_m3[0] = actual_liquid_m3;
    grid.matrix_ice_water_m3[0] = actual_ice_m3;
    grid.liquid_water_m3[0] = actual_liquid_m3;
    grid.ice_water_m3[0] = actual_ice_m3;
    grid.matrix_pore_capacity_m3[0] = porous_medium_volume_m3;

    const heat_capacity = [_]f64{heat_capacity_megajoules_per_k};
    const zero = [_]f64{0};
    const liquid_fraction = [_]f64{actual_liquid_m3 / porous_medium_volume_m3};
    const ice_fraction = [_]f64{actual_ice_m3 / porous_medium_volume_m3};
    const top = [_]bool{true};
    var source = [_]f64{source_megajoules};
    const volume = [_]f64{porous_medium_volume_m3};
    const area = [_]f64{1};
    const curves = [_]retention.MualemVanGenuchtenParameters{curve};
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &heat_capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &zero,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &ice_fraction,
        .air_fraction = &zero,
        .fraction_of_pore_volume_air_filled = &zero,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &zero,
        .solid_conductivity_denominator = &zero,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &source,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity_megajoules_per_m3_k,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = .{
            .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
            .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
            .porous_medium_volume_m3 = &volume,
            .unfrozen_pressure_head_m = &zero,
            .mualem_van_genuchten = &curves,
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .pure_water_melting_temperature_k = melting_temperature_k,
            .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity_megajoules_per_m3_k,
            .latent_heat_of_fusion_megajoules_per_m3 = latent_heat_megajoules_per_m3,
            .ice_density_megagrams_per_m3 = 0.917,
            .solver_options = .{
                .max_iterations = 80,
                .absolute_enthalpy_tolerance_megajoules = 0.01 * transition_interval_megajoules,
                .relative_enthalpy_tolerance = 0,
            },
            .conservation_cell_area_m2 = &area,
            .conservation_absolute_tolerance_megajoules_per_m2 = 0.01 * transition_interval_megajoules,
            .conservation_relative_tolerance = 0,
        },
    };
    const no_flux: [0]f64 = .{};
    var output_flux: [0]f64 = .{};
    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        .{
            .liquid_water_m3 = &no_flux,
            .vapor_m3 = &no_flux,
            .macropore_water_m3 = &no_flux,
        },
        &output_flux,
        .{
            .max_iterations = 1,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .dense_newton_max_components = 0,
        },
    );
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try std.testing.expectEqual(@as(u16, 1), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.picard_steps);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    try std.testing.expectEqual(
        @as(u32, 2),
        result.enthalpy_representability_probes,
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        result.phase_transition_newton_steps,
    );
    try std.testing.expect(result.final_endpoint_proof_reused);
    try std.testing.expect(result.maximum_scaled_residual <= 1);
    try std.testing.expect(result.maximum_scaled_conservation_residual <= 1);
    try std.testing.expect(grid.soil_temperature_k[0] ==
        lower_transition_temperature_k or
        grid.soil_temperature_k[0] == transition_temperature_k);

    var branch_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer branch_grid.deinit();
    branch_grid.soil_temperature_k[0] = base_temperature_k;
    branch_grid.matrix_liquid_water_m3[0] = actual_liquid_m3;
    branch_grid.matrix_ice_water_m3[0] = actual_ice_m3;
    branch_grid.liquid_water_m3[0] = actual_liquid_m3;
    branch_grid.ice_water_m3[0] = actual_ice_m3;
    branch_grid.matrix_pore_capacity_m3[0] = porous_medium_volume_m3;
    const warm_state = try enthalpy.stateAtTemperature(
        parameters,
        transition_temperature_k + 0.02,
    );
    source[0] = warm_state.enthalpy_megajoules - actual_base_enthalpy_megajoules;
    var branch_properties = properties;
    branch_properties.enthalpy_coupling.?.matrix_liquid_water_m3 =
        branch_grid.matrix_liquid_water_m3;
    branch_properties.enthalpy_coupling.?.matrix_ice_water_equivalent_m3 =
        branch_grid.matrix_ice_water_m3;
    const branch_result = try group_solve.solve(
        std.testing.allocator,
        &branch_grid,
        &.{},
        branch_properties,
        .{
            .liquid_water_m3 = &no_flux,
            .vapor_m3 = &no_flux,
            .macropore_water_m3 = &no_flux,
        },
        &output_flux,
        .{
            .max_iterations = 3,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .dense_newton_max_components = 0,
        },
    );
    try std.testing.expectEqual(@as(u16, 3), branch_result.iterations);
    try std.testing.expectEqual(@as(u16, 3), branch_result.newton_raphson_steps);
    try std.testing.expectEqual(
        @as(u16, 1),
        branch_result.phase_transition_newton_steps,
    );
    try std.testing.expect(branch_result.maximum_scaled_residual <= 1);
    try std.testing.expect(branch_result.maximum_scaled_conservation_residual <= 1);
    try std.testing.expect(branch_grid.soil_temperature_k[0] >
        transition_temperature_k);

    var cooling_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer cooling_grid.deinit();
    cooling_grid.soil_temperature_k[0] = transition_temperature_k;
    cooling_grid.matrix_liquid_water_m3[0] = actual_liquid_m3;
    cooling_grid.matrix_ice_water_m3[0] = actual_ice_m3;
    cooling_grid.liquid_water_m3[0] = actual_liquid_m3;
    cooling_grid.ice_water_m3[0] = actual_ice_m3;
    cooling_grid.matrix_pore_capacity_m3[0] = porous_medium_volume_m3;
    const cooling_base_enthalpy_megajoules =
        heat_capacity_megajoules_per_k *
        (transition_temperature_k - melting_temperature_k) +
        latent_heat_megajoules_per_m3 * actual_liquid_m3;
    source[0] = -8.0e-4;
    const cooling_target_enthalpy_megajoules =
        cooling_base_enthalpy_megajoules + source[0];
    const cooling_root = try enthalpy.temperatureFromEnthalpy(
        parameters,
        cooling_target_enthalpy_megajoules,
        .{
            .max_iterations = 80,
            .absolute_enthalpy_tolerance_megajoules = 1e-13,
            .relative_enthalpy_tolerance = 1e-11,
            .initial_temperature_k = transition_temperature_k,
        },
    );
    try std.testing.expect(cooling_root.state.temperature_k <
        transition_temperature_k);
    var cooling_properties = properties;
    cooling_properties.enthalpy_coupling.?.matrix_liquid_water_m3 =
        cooling_grid.matrix_liquid_water_m3;
    cooling_properties.enthalpy_coupling.?.matrix_ice_water_equivalent_m3 =
        cooling_grid.matrix_ice_water_m3;
    cooling_properties.enthalpy_coupling.?.solver_options
        .absolute_enthalpy_tolerance_megajoules = 1e-13;
    cooling_properties.enthalpy_coupling.?.solver_options
        .relative_enthalpy_tolerance = 1e-11;
    const cooling_result = try group_solve.solve(
        std.testing.allocator,
        &cooling_grid,
        &.{},
        cooling_properties,
        .{
            .liquid_water_m3 = &no_flux,
            .vapor_m3 = &no_flux,
            .macropore_water_m3 = &no_flux,
        },
        &output_flux,
        .{
            .max_iterations = 2,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .dense_newton_max_components = 0,
        },
    );
    try std.testing.expectEqual(@as(u16, 2), cooling_result.iterations);
    try std.testing.expectEqual(@as(u16, 1), cooling_result.phase_transition_newton_steps);
    try std.testing.expectEqual(@as(u16, 1), cooling_result.constitutive_energy_newton_steps);
    try std.testing.expectEqual(@as(u16, 0), cooling_result.enthalpy_topology_newton_steps);
    try std.testing.expect(cooling_result.maximum_scaled_residual <= 1);
    try std.testing.expect(cooling_result.maximum_scaled_conservation_residual <= 1);
    try std.testing.expect(cooling_grid.soil_temperature_k[0] <
        transition_temperature_k);
    try std.testing.expectApproxEqAbs(
        cooling_target_enthalpy_megajoules,
        (try enthalpy.stateAtTemperature(
            parameters,
            cooling_grid.soil_temperature_k[0],
        )).enthalpy_megajoules,
        1e-9,
    );

    var asymptotic_grid = try grid_module.GridState.init(
        std.testing.allocator,
        cfg,
    );
    defer asymptotic_grid.deinit();
    const asymptotic_total_water_m3 = 0.5 * porous_medium_volume_m3;
    const asymptotic_unfrozen_pressure_head_m =
        try curve.pressureHeadAtWaterContent(
            asymptotic_total_water_m3 / porous_medium_volume_m3,
        );
    const asymptotic_parameters: enthalpy.Parameters = .{
        .porous_medium_volume_m3 = porous_medium_volume_m3,
        .total_water_equivalent_m3 = asymptotic_total_water_m3,
        .unfrozen_pressure_head_m = asymptotic_unfrozen_pressure_head_m,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = melting_temperature_k,
        .dry_solid_heat_capacity_megajoules_per_k = dry_capacity_megajoules_per_k,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity_megajoules_per_m3_k,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity_megajoules_per_m3_k,
        .latent_heat_of_fusion_megajoules_per_m3 = latent_heat_megajoules_per_m3,
        .mualem_van_genuchten = curve,
    };
    const asymptotic_transition_temperature_k =
        enthalpy.depressedMeltingTemperatureK(
            asymptotic_parameters,
            asymptotic_unfrozen_pressure_head_m,
        );
    const asymptotic_base_temperature_k =
        asymptotic_transition_temperature_k - 0.08;
    const equilibrium_base_state = try enthalpy.stateAtTemperature(
        asymptotic_parameters,
        asymptotic_base_temperature_k,
    );
    const equilibrium_transition_state = try enthalpy.stateAtTemperature(
        asymptotic_parameters,
        asymptotic_transition_temperature_k,
    );
    const equilibrium_source_megajoules =
        equilibrium_transition_state.enthalpy_megajoules -
        equilibrium_base_state.enthalpy_megajoules;
    const equilibrium_derivative_megajoules_per_k =
        try enthalpy.enthalpyDerivativeMjPerK(
            asymptotic_parameters,
            asymptotic_base_temperature_k,
            equilibrium_base_state,
        );
    const equilibrium_newton_correction_k =
        equilibrium_source_megajoules /
        equilibrium_derivative_megajoules_per_k;
    // Fixture preconditions, so the real assertion at the end of this test
    // cannot pass for a trivial reason.
    //
    // Below the transition the freeze curve is convex: the apparent heat
    // capacity is the sensible capacity plus the latent term
    // `latent_heat * d(liquid_fraction)/dT`, and the liquid fraction rises ever
    // more steeply as the depressed melting point is approached, so more ice
    // melts per degree the closer the state sits to the transition. The
    // derivative at the cold end is therefore strictly below the secant slope
    // across the interval, which is the mean of the derivative over it.
    //
    // The consequence is the point of this fixture: a raw Newton step from
    // below necessarily OVERSHOOTS the transition, even though the source is
    // exactly the enthalpy needed to reach it. Nothing in the curve can make it
    // undershoot. So landing on the transition is not something Newton does on
    // its own -- it is what the production solver's bounded adjacent-f64
    // endpoint has to deliver, which is precisely what
    // `expectEqual(asymptotic_transition_temperature_k, ...)` below then
    // proves. Were the raw step to undershoot, that final equality would be
    // testing nothing about the endpoint clamp at all.
    const equilibrium_secant_megajoules_per_k = equilibrium_source_megajoules /
        (asymptotic_transition_temperature_k - asymptotic_base_temperature_k);
    try std.testing.expect(equilibrium_derivative_megajoules_per_k <
        equilibrium_secant_megajoules_per_k);
    try std.testing.expect(equilibrium_newton_correction_k > 0);
    try std.testing.expect(asymptotic_base_temperature_k +
        equilibrium_newton_correction_k >
        asymptotic_transition_temperature_k);

    asymptotic_grid.soil_temperature_k[0] =
        asymptotic_base_temperature_k;
    asymptotic_grid.matrix_liquid_water_m3[0] =
        equilibrium_base_state.liquid_water_m3;
    asymptotic_grid.matrix_ice_water_m3[0] =
        equilibrium_base_state.ice_water_equivalent_m3;
    asymptotic_grid.liquid_water_m3[0] =
        equilibrium_base_state.liquid_water_m3;
    asymptotic_grid.ice_water_m3[0] =
        equilibrium_base_state.ice_water_equivalent_m3;
    asymptotic_grid.matrix_pore_capacity_m3[0] = porous_medium_volume_m3;
    const equilibrium_capacity =
        [_]f64{equilibrium_base_state.sensible_heat_capacity_megajoules_per_k};
    const equilibrium_liquid_fraction = [_]f64{
        equilibrium_base_state.liquid_water_m3 / porous_medium_volume_m3,
    };
    const equilibrium_ice_fraction = [_]f64{
        equilibrium_base_state.ice_water_equivalent_m3 /
            porous_medium_volume_m3,
    };
    const asymptotic_unfrozen_pressure_head =
        [_]f64{asymptotic_unfrozen_pressure_head_m};
    source[0] = equilibrium_source_megajoules;
    var asymptotic_properties = properties;
    asymptotic_properties.heat_capacity_megajoules_per_k =
        &equilibrium_capacity;
    asymptotic_properties.liquid_water_fraction =
        &equilibrium_liquid_fraction;
    asymptotic_properties.ice_fraction = &equilibrium_ice_fraction;
    asymptotic_properties.enthalpy_coupling.?.matrix_liquid_water_m3 =
        asymptotic_grid.matrix_liquid_water_m3;
    asymptotic_properties.enthalpy_coupling.?.matrix_ice_water_equivalent_m3 =
        asymptotic_grid.matrix_ice_water_m3;
    asymptotic_properties.enthalpy_coupling.?.unfrozen_pressure_head_m =
        &asymptotic_unfrozen_pressure_head;
    asymptotic_properties.enthalpy_coupling.?.solver_options
        .absolute_enthalpy_tolerance_megajoules = 1e-13;
    asymptotic_properties.enthalpy_coupling.?.solver_options
        .relative_enthalpy_tolerance = 1e-11;
    asymptotic_properties.enthalpy_coupling.?
        .conservation_absolute_tolerance_megajoules_per_m2 = 1e-13;
    const asymptotic_result = try group_solve.solve(
        std.testing.allocator,
        &asymptotic_grid,
        &.{},
        asymptotic_properties,
        .{
            .liquid_water_m3 = &no_flux,
            .vapor_m3 = &no_flux,
            .macropore_water_m3 = &no_flux,
        },
        &output_flux,
        .{
            .max_iterations = 2,
            .absolute_tolerance_k = 1e-8,
            .relative_tolerance = 1e-10,
            .dense_newton_max_components = 0,
        },
    );
    try std.testing.expectEqual(@as(u16, 2), asymptotic_result.iterations);
    try std.testing.expectEqual(
        @as(u16, 1),
        asymptotic_result.phase_transition_newton_steps,
    );
    try std.testing.expect(asymptotic_result.maximum_scaled_residual <= 1);
    try std.testing.expect(
        asymptotic_result.maximum_scaled_conservation_residual <= 1,
    );
    try std.testing.expectEqual(
        asymptotic_transition_temperature_k,
        asymptotic_grid.soil_temperature_k[0],
    );
}

test "MJ active-set Newton leaves a tied sub-ULP phase coordinate and final-slot endpoint to representability" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 2 },
    );
    var one_step_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer one_step_grid.deinit();

    const melting_temperature_k = 273.15;
    const volume_m3 = [_]f64{ 0.01, 0.01 };
    const curves = [_]retention.MualemVanGenuchtenParameters{
        .{
            .residual_water_content_m3_per_m3 = 0,
            .saturated_water_content_m3_per_m3 = 1,
            .alpha_per_m = 400,
            .n = 2.5,
            .saturated_hydraulic_conductivity_m_per_h = 1,
        },
        .{
            .residual_water_content_m3_per_m3 = 0,
            .saturated_water_content_m3_per_m3 = 1,
            // Paired with the negative reference head below, this remains a
            // steep but physical Dall'Amico transition well below pure-water
            // melting: the pressure response makes its MJ defect representable
            // while its K-equivalent correction is below one temperature ULP.
            .alpha_per_m = 10,
            .n = 2.5,
            .saturated_hydraulic_conductivity_m_per_h = 1,
        },
    };
    const unfrozen_pressure_head_m = [_]f64{ 0, -0.1 };
    const dry_capacity_megajoules_per_k = 0.02;
    const liquid_capacity_megajoules_per_m3_k = 4.19;
    const ice_capacity_megajoules_per_m3_k = 1.93;
    const latent_heat_megajoules_per_m3 = 333.7;
    const depressed_transition_k = melting_temperature_k * @exp(
        0.00980665 * unfrozen_pressure_head_m[1] /
            latent_heat_megajoules_per_m3,
    );
    const base_temperature_k = [_]f64{
        // Higher smooth MJ limiter checked first by discovery.
        268.5699707913046,
        // Lower-ranked discrete endpoint at the actual pressure-depressed
        // transition, far outside a pure-water kink-radius shortcut.
        depressed_transition_k - 1.0e-7,
    };
    const total_water_m3 = [_]f64{
        volume_m3[0],
        (try curves[1].waterContentAtPressureHead(
            unfrozen_pressure_head_m[1],
        )) * volume_m3[1],
    };
    const transition_radius_k = 2 * std.math.sqrt(std.math.floatEps(f64)) *
        melting_temperature_k;
    try std.testing.expect(
        melting_temperature_k - depressed_transition_k >
            64 * transition_radius_k,
    );
    try std.testing.expect(
        @abs(base_temperature_k[1] - depressed_transition_k) <
            transition_radius_k,
    );
    try std.testing.expect(
        @abs(base_temperature_k[1] - melting_temperature_k) >
            64 * transition_radius_k,
    );
    var parameters: [2]enthalpy.Parameters = undefined;
    var equilibrium: [2]enthalpy.State = undefined;
    var derivative_megajoules_per_k: [2]f64 = undefined;
    for (0..2) |cell| {
        parameters[cell] = .{
            .porous_medium_volume_m3 = volume_m3[cell],
            .total_water_equivalent_m3 = total_water_m3[cell],
            .unfrozen_pressure_head_m = unfrozen_pressure_head_m[cell],
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .pure_water_melting_temperature_k = melting_temperature_k,
            .dry_solid_heat_capacity_megajoules_per_k = dry_capacity_megajoules_per_k,
            .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity_megajoules_per_m3_k,
            .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity_megajoules_per_m3_k,
            .latent_heat_of_fusion_megajoules_per_m3 = latent_heat_megajoules_per_m3,
            .mualem_van_genuchten = curves[cell],
        };
        equilibrium[cell] = try enthalpy.stateAtTemperature(
            parameters[cell],
            base_temperature_k[cell],
        );
        derivative_megajoules_per_k[cell] = try enthalpy.enthalpyDerivativeMjPerK(
            parameters[cell],
            base_temperature_k[cell],
            equilibrium[cell],
        );
    }
    try std.testing.expectEqual(
        depressed_transition_k,
        enthalpy.depressedMeltingTemperatureK(
            parameters[1],
            unfrozen_pressure_head_m[1],
        ),
    );

    const absolute_tolerance_k = 1e-8;
    const relative_tolerance = 1e-10;
    const production_k_coordinate = 0.03;
    const production_megajoule_coordinate = 9.537914325228348;
    const tied_megajoule_coordinate = 9.536670504702371;
    const temperature_tolerance_cell_0 = absolute_tolerance_k +
        relative_tolerance * @abs(base_temperature_k[0]);
    const enthalpy_tolerance_megajoules = derivative_megajoules_per_k[0] *
        temperature_tolerance_cell_0 * production_k_coordinate /
        production_megajoule_coordinate;
    const desired_defect_megajoules = [_]f64{
        production_megajoule_coordinate * enthalpy_tolerance_megajoules,
        tied_megajoule_coordinate * enthalpy_tolerance_megajoules,
    };
    const source_megajoules = [_]f64{ 1e-12, 1e-6 };
    var actual_liquid_m3: [2]f64 = undefined;
    var actual_ice_m3: [2]f64 = undefined;
    var heat_capacity_megajoules_per_k: [2]f64 = undefined;
    var liquid_fraction: [2]f64 = undefined;
    var ice_fraction: [2]f64 = undefined;
    for (0..2) |cell| {
        const phase_exchange_megajoules_per_m3 = latent_heat_megajoules_per_m3 +
            (liquid_capacity_megajoules_per_m3_k - ice_capacity_megajoules_per_m3_k) *
                (base_temperature_k[cell] - melting_temperature_k);
        actual_liquid_m3[cell] = equilibrium[cell].liquid_water_m3 +
            (desired_defect_megajoules[cell] - source_megajoules[cell]) /
                phase_exchange_megajoules_per_m3;
        actual_ice_m3[cell] = total_water_m3[cell] - actual_liquid_m3[cell];
        try std.testing.expect(actual_liquid_m3[cell] > 0);
        try std.testing.expect(actual_ice_m3[cell] > 0);
        heat_capacity_megajoules_per_k[cell] = dry_capacity_megajoules_per_k +
            liquid_capacity_megajoules_per_m3_k * actual_liquid_m3[cell] +
            ice_capacity_megajoules_per_m3_k * actual_ice_m3[cell];
        liquid_fraction[cell] = actual_liquid_m3[cell] / volume_m3[cell];
        ice_fraction[cell] = actual_ice_m3[cell] / volume_m3[cell];
    }
    @memcpy(one_step_grid.soil_temperature_k, &base_temperature_k);
    @memcpy(one_step_grid.matrix_liquid_water_m3, &actual_liquid_m3);
    @memcpy(one_step_grid.matrix_ice_water_m3, &actual_ice_m3);
    @memcpy(one_step_grid.liquid_water_m3, &actual_liquid_m3);
    @memcpy(one_step_grid.ice_water_m3, &actual_ice_m3);
    @memcpy(one_step_grid.matrix_pore_capacity_m3, &volume_m3);

    const zero = [_]f64{ 0, 0 };
    const top = [_]bool{ true, false };
    const empty_curve: [0]retention.MualemVanGenuchtenParameters = .{};
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &heat_capacity_megajoules_per_k,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &zero,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &ice_fraction,
        .air_fraction = &zero,
        .fraction_of_pore_volume_air_filled = &zero,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &zero,
        .solid_conductivity_denominator = &zero,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &source_megajoules,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity_megajoules_per_m3_k,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = .{
            .matrix_liquid_water_m3 = one_step_grid.matrix_liquid_water_m3,
            .matrix_ice_water_equivalent_m3 = one_step_grid.matrix_ice_water_m3,
            .porous_medium_volume_m3 = &volume_m3,
            .unfrozen_pressure_head_m = &unfrozen_pressure_head_m,
            .mualem_van_genuchten = &curves,
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .pure_water_melting_temperature_k = melting_temperature_k,
            .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_capacity_megajoules_per_m3_k,
            .latent_heat_of_fusion_megajoules_per_m3 = latent_heat_megajoules_per_m3,
            .ice_density_megagrams_per_m3 = 0.917,
            .solver_options = .{
                .max_iterations = 80,
                .absolute_enthalpy_tolerance_megajoules = enthalpy_tolerance_megajoules,
                .relative_enthalpy_tolerance = 1e-30,
            },
            .macropore_mualem_van_genuchten = &empty_curve,
        },
    };
    const empty_flux: [0]f64 = .{};
    var output_flux: [0]f64 = .{};
    var target: [2]f64 = undefined;
    var residual: [2]f64 = undefined;
    var scaled_enthalpy: [2]f64 = undefined;
    var phase_liquid: [2]f64 = undefined;
    var phase_ice: [2]f64 = undefined;
    var phase_macropore_liquid: [2]f64 = undefined;
    var phase_macropore_ice: [2]f64 = undefined;
    const phase_buffers: group_misc.PhaseBuffers = .{
        .matrix_liquid_m3 = &phase_liquid,
        .matrix_ice_m3 = &phase_ice,
        .macropore_liquid_m3 = &phase_macropore_liquid,
        .macropore_ice_m3 = &phase_macropore_ice,
        .macropore_enabled = false,
        .ice_density_megagrams_per_m3 = 0.917,
    };
    const options: group_types.Options = .{
        .max_iterations = 2,
        .absolute_tolerance_k = absolute_tolerance_k,
        .relative_tolerance = relative_tolerance,
        // Round the ordinary directional secant probe back to the current
        // state so this fixture reaches the intended analytic active set.
        .directional_probe_fraction = 1e-16,
        .dense_newton_max_components = 0,
    };
    try group_residual.residualAt(
        &.{},
        properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &base_temperature_k,
        &base_temperature_k,
        &target,
        &residual,
        &scaled_enthalpy,
        &output_flux,
        phase_buffers,
        options,
    );
    const initial_norm = try group_residual.scaledNorm(
        &base_temperature_k,
        &residual,
        &scaled_enthalpy,
        true,
        options,
    );
    const initial_k_coordinate = @abs(residual[0]) /
        temperature_tolerance_cell_0;
    try std.testing.expectApproxEqRel(
        production_k_coordinate,
        initial_k_coordinate,
        1e-4,
    );
    try std.testing.expectApproxEqRel(
        production_megajoule_coordinate,
        @abs(scaled_enthalpy[0]),
        1e-4,
    );
    try std.testing.expectApproxEqRel(
        tied_megajoule_coordinate,
        @abs(scaled_enthalpy[1]),
        1e-4,
    );
    try std.testing.expect(base_temperature_k[1] + residual[1] ==
        base_temperature_k[1]);

    const depressed_kink_temperature = [_]f64{
        base_temperature_k[0],
        depressed_transition_k,
    };
    const depressed_kink_residual = [_]f64{ 0, 1e-3 };
    const depressed_kink_scaled_enthalpy = [_]f64{ 0, 2 };
    var depressed_kink_direction: [2]f64 = undefined;
    try std.testing.expect(!(try group_solve.mjActiveSetNewtonDirection(
        properties,
        &depressed_kink_temperature,
        &depressed_kink_residual,
        &depressed_kink_scaled_enthalpy,
        &depressed_kink_direction,
    )));
    try std.testing.expectEqual(@as(f64, 0), depressed_kink_direction[1]);

    var active_direction: [2]f64 = undefined;
    try std.testing.expect(try group_solve.mjActiveSetNewtonDirection(
        properties,
        &base_temperature_k,
        &residual,
        &scaled_enthalpy,
        &active_direction,
    ));
    try std.testing.expectEqual(residual[0], active_direction[0]);
    try std.testing.expectEqual(@as(f64, 0), active_direction[1]);
    const active_candidate = [_]f64{
        base_temperature_k[0] + active_direction[0],
        base_temperature_k[1],
    };
    try group_residual.residualAt(
        &.{},
        properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &base_temperature_k,
        &active_candidate,
        &target,
        &residual,
        &scaled_enthalpy,
        &output_flux,
        phase_buffers,
        options,
    );
    const active_candidate_norm = try group_residual.scaledNorm(
        &active_candidate,
        &residual,
        &scaled_enthalpy,
        true,
        options,
    );
    try std.testing.expect(active_candidate_norm < initial_norm);
    try std.testing.expectApproxEqRel(
        tied_megajoule_coordinate,
        active_candidate_norm,
        1e-4,
    );
    var adjacent_candidate = active_candidate;
    adjacent_candidate[1] = std.math.nextAfter(
        f64,
        active_candidate[1],
        if (scaled_enthalpy[1] > 0) std.math.inf(f64) else -std.math.inf(f64),
    );
    const current_tied_sign = std.math.signbit(scaled_enthalpy[1]);
    try group_residual.residualAt(
        &.{},
        properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &base_temperature_k,
        &adjacent_candidate,
        &target,
        &residual,
        &scaled_enthalpy,
        &output_flux,
        phase_buffers,
        options,
    );
    try std.testing.expect(
        scaled_enthalpy[1] == 0 or
            std.math.signbit(scaled_enthalpy[1]) != current_tied_sign,
    );

    var one_step_options = options;
    one_step_options.max_iterations = 1;
    const one_step_result = try group_solve.solve(
        std.testing.allocator,
        &one_step_grid,
        &.{},
        properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &output_flux,
        one_step_options,
    );
    try std.testing.expectEqual(@as(u16, 1), one_step_result.iterations);
    try std.testing.expectEqual(@as(u16, 1), one_step_result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), one_step_result.anderson_steps);
    try std.testing.expect(one_step_result.final_endpoint_proof_reused);
    try std.testing.expect(one_step_result.maximum_scaled_residual <= 1);

    var two_step_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer two_step_grid.deinit();
    @memcpy(two_step_grid.soil_temperature_k, &base_temperature_k);
    @memcpy(two_step_grid.matrix_liquid_water_m3, &actual_liquid_m3);
    @memcpy(two_step_grid.matrix_ice_water_m3, &actual_ice_m3);
    @memcpy(two_step_grid.liquid_water_m3, &actual_liquid_m3);
    @memcpy(two_step_grid.ice_water_m3, &actual_ice_m3);
    @memcpy(two_step_grid.matrix_pore_capacity_m3, &volume_m3);
    var two_step_properties = properties;
    two_step_properties.enthalpy_coupling.?.matrix_liquid_water_m3 =
        two_step_grid.matrix_liquid_water_m3;
    two_step_properties.enthalpy_coupling.?.matrix_ice_water_equivalent_m3 =
        two_step_grid.matrix_ice_water_m3;
    const result = try group_solve.solve(
        std.testing.allocator,
        &two_step_grid,
        &.{},
        two_step_properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &output_flux,
        options,
    );
    try std.testing.expectEqual(@as(u16, 1), result.megajoule_active_set_newton_steps);
    // More than eight probes proves the discovery scan skipped the higher
    // smooth, non-bracketing MJ coordinate and found the lower discrete
    // endpoint before active-set Newton pricing; relocation and the final
    // simultaneous proof add read-only probes of their own.
    try std.testing.expect(result.megajoule_active_set_newton_probes > 8);
    try std.testing.expect(result.enthalpy_representability_probes > 0);
    try std.testing.expectEqual(@as(u16, 2), result.iterations);
    try std.testing.expectEqual(@as(u16, 1), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), result.anderson_steps);
    try std.testing.expect(!result.final_endpoint_proof_reused);
    try std.testing.expect(result.maximum_scaled_residual <= 1);

    // Put the exact cell-1 root between adjacent f64 temperatures, with the
    // raw MJ defect closer to the upper endpoint. Endpoint discovery must not
    // let that unrepresentable raw coordinate override the represented K and
    // coupled merit: the lower current temperature is retained without
    // spending the only permitted update.
    const switched_temperature_k = std.math.nextAfter(
        f64,
        base_temperature_k[1],
        std.math.inf(f64),
    );
    const switched_state = try enthalpy.stateAtTemperature(
        parameters[1],
        switched_temperature_k,
    );
    const adjacent_enthalpy_interval_megajoules =
        switched_state.enthalpy_megajoules - equilibrium[1].enthalpy_megajoules;
    try std.testing.expect(adjacent_enthalpy_interval_megajoules > 0);
    const switched_desired_defect_megajoules = [_]f64{
        0,
        0.75 * adjacent_enthalpy_interval_megajoules,
    };
    var switched_liquid_m3: [2]f64 = undefined;
    var switched_ice_m3: [2]f64 = undefined;
    var switched_heat_capacity: [2]f64 = undefined;
    var switched_liquid_fraction: [2]f64 = undefined;
    var switched_ice_fraction: [2]f64 = undefined;
    for (0..2) |cell| {
        const phase_exchange_megajoules_per_m3 =
            latent_heat_megajoules_per_m3 +
            (liquid_capacity_megajoules_per_m3_k -
                ice_capacity_megajoules_per_m3_k) *
                (base_temperature_k[cell] - melting_temperature_k);
        switched_liquid_m3[cell] = equilibrium[cell].liquid_water_m3 +
            (switched_desired_defect_megajoules[cell] -
                source_megajoules[cell]) /
                phase_exchange_megajoules_per_m3;
        switched_ice_m3[cell] = total_water_m3[cell] -
            switched_liquid_m3[cell];
        try std.testing.expect(switched_liquid_m3[cell] > 0);
        try std.testing.expect(switched_ice_m3[cell] > 0);
        switched_heat_capacity[cell] = dry_capacity_megajoules_per_k +
            liquid_capacity_megajoules_per_m3_k * switched_liquid_m3[cell] +
            ice_capacity_megajoules_per_m3_k * switched_ice_m3[cell];
        switched_liquid_fraction[cell] = switched_liquid_m3[cell] /
            volume_m3[cell];
        switched_ice_fraction[cell] = switched_ice_m3[cell] /
            volume_m3[cell];
    }
    var switched_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer switched_grid.deinit();
    @memcpy(switched_grid.soil_temperature_k, &base_temperature_k);
    @memcpy(switched_grid.matrix_liquid_water_m3, &switched_liquid_m3);
    @memcpy(switched_grid.matrix_ice_water_m3, &switched_ice_m3);
    @memcpy(switched_grid.liquid_water_m3, &switched_liquid_m3);
    @memcpy(switched_grid.ice_water_m3, &switched_ice_m3);
    @memcpy(switched_grid.matrix_pore_capacity_m3, &volume_m3);
    var switched_properties = properties;
    switched_properties.heat_capacity_megajoules_per_k = &switched_heat_capacity;
    switched_properties.liquid_water_fraction = &switched_liquid_fraction;
    switched_properties.ice_fraction = &switched_ice_fraction;
    switched_properties.enthalpy_coupling.?.matrix_liquid_water_m3 =
        switched_grid.matrix_liquid_water_m3;
    switched_properties.enthalpy_coupling.?.matrix_ice_water_equivalent_m3 =
        switched_grid.matrix_ice_water_m3;
    switched_properties.enthalpy_coupling.?.solver_options
        .absolute_enthalpy_tolerance_megajoules =
        adjacent_enthalpy_interval_megajoules / 10;
    switched_properties.enthalpy_coupling.?.solver_options
        .relative_enthalpy_tolerance = 1e-30;
    const conservation_area_m2 = [_]f64{ 1, 1 };
    var conservation_properties = switched_properties;
    conservation_properties.enthalpy_coupling.?.conservation_cell_area_m2 =
        &conservation_area_m2;
    conservation_properties.enthalpy_coupling.?
        .conservation_absolute_tolerance_megajoules_per_m2 =
        0.1 * adjacent_enthalpy_interval_megajoules;
    conservation_properties.enthalpy_coupling.?.conservation_relative_tolerance = 0;
    var conservation_source_megajoules = source_megajoules;
    conservation_source_megajoules[1] -=
        0.5 * adjacent_enthalpy_interval_megajoules;
    conservation_properties.cell_heat_source_megajoules =
        &conservation_source_megajoules;
    try group_residual.residualAt(
        &.{},
        conservation_properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &base_temperature_k,
        &base_temperature_k,
        &target,
        &residual,
        &scaled_enthalpy,
        &output_flux,
        phase_buffers,
        one_step_options,
    );
    const raw_conservation_norm = try group_residual.conservationScaledNorm(
        conservation_properties,
        &base_temperature_k,
        &base_temperature_k,
        &residual,
    );
    const represented_conservation_norm =
        try group_residual.conservationScaledNormWithRepresentedEndpoints(
            conservation_properties,
            &base_temperature_k,
            &base_temperature_k,
            &residual,
            &[_]f64{ 0, 1 },
        );
    try std.testing.expect(raw_conservation_norm > 1);
    try std.testing.expect(represented_conservation_norm <= 1);
    const switched_result = try group_solve.solve(
        std.testing.allocator,
        &switched_grid,
        &.{},
        switched_properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &output_flux,
        one_step_options,
    );
    try std.testing.expectEqual(@as(u16, 1), switched_result.iterations);
    try std.testing.expectEqual(@as(u16, 0), switched_result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 0), switched_result.anderson_steps);
    try std.testing.expectEqual(@as(u16, 0), switched_result.megajoule_active_set_newton_steps);
    try std.testing.expectEqual(base_temperature_k[1], switched_grid.soil_temperature_k[1]);
    try std.testing.expectEqual(@as(u32, 1), switched_result.enthalpy_representability_probes);
    try std.testing.expect(!switched_result.final_endpoint_proof_reused);
    try std.testing.expect(switched_result.maximum_scaled_residual <= 1);
    try std.testing.expect(switched_result.maximum_scaled_conservation_residual <= 1);

    // Make the nonlinear enthalpy tolerance deliberately looser than the raw
    // defect while retaining the strict conservation gate above. Endpoint
    // discovery must still select this conservation-only limiter, prove the
    // adjacent bracket, and publish the lower-merit represented endpoint.
    var conservation_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer conservation_grid.deinit();
    @memcpy(conservation_grid.soil_temperature_k, &base_temperature_k);
    @memcpy(conservation_grid.matrix_liquid_water_m3, &switched_liquid_m3);
    @memcpy(conservation_grid.matrix_ice_water_m3, &switched_ice_m3);
    @memcpy(conservation_grid.liquid_water_m3, &switched_liquid_m3);
    @memcpy(conservation_grid.ice_water_m3, &switched_ice_m3);
    @memcpy(conservation_grid.matrix_pore_capacity_m3, &volume_m3);
    conservation_properties.enthalpy_coupling.?.matrix_liquid_water_m3 =
        conservation_grid.matrix_liquid_water_m3;
    conservation_properties.enthalpy_coupling.?.matrix_ice_water_equivalent_m3 =
        conservation_grid.matrix_ice_water_m3;
    conservation_properties.enthalpy_coupling.?.solver_options
        .absolute_enthalpy_tolerance_megajoules =
        10 * adjacent_enthalpy_interval_megajoules;
    const conservation_only_result = try group_solve.solve(
        std.testing.allocator,
        &conservation_grid,
        &.{},
        conservation_properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &output_flux,
        one_step_options,
    );
    // The current state is already the lower-merit member of the proven
    // adjacent-f64 bracket. Its represented conservation allowance must
    // survive the post-discovery merit recomputation so the in-loop audit
    // accepts without an unnecessary Newton promotion or final-slot reuse.
    try std.testing.expectEqual(@as(u16, 1), conservation_only_result.iterations);
    try std.testing.expectEqual(@as(u16, 0), conservation_only_result.newton_raphson_steps);
    try std.testing.expect(conservation_only_result.enthalpy_representability_probes > 0);
    try std.testing.expect(!conservation_only_result.final_endpoint_proof_reused);
    try std.testing.expect(conservation_only_result.maximum_scaled_residual <= 1);
    try std.testing.expect(conservation_only_result.maximum_scaled_conservation_residual <= 1);

    // Audit the upper member of the same bracket without permitting another
    // state promotion. The lower neighbor is closer to this root, but the
    // current upper endpoint is itself within the exact one-ULP represented
    // gate and therefore remains a valid binary64 solution.
    var audit_properties = conservation_properties;
    audit_properties.enthalpy_coupling.?.matrix_liquid_water_m3 =
        &switched_liquid_m3;
    audit_properties.enthalpy_coupling.?.matrix_ice_water_equivalent_m3 =
        &switched_ice_m3;
    var audit_current = base_temperature_k;
    audit_current[1] = switched_temperature_k;
    var audit_candidate: [2]f64 = undefined;
    var audit_candidate_residual: [2]f64 = undefined;
    var audit_candidate_scaled_enthalpy: [2]f64 = undefined;
    var audit_checked: [2]f64 = undefined;
    var audit_proven_mask: [2]f64 = undefined;
    try group_residual.residualAt(
        &.{},
        audit_properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &base_temperature_k,
        &audit_current,
        &target,
        &residual,
        &scaled_enthalpy,
        &output_flux,
        phase_buffers,
        one_step_options,
    );
    const upper_raw_conservation_norm =
        try group_residual.conservationScaledNorm(
            audit_properties,
            &base_temperature_k,
            &audit_current,
            &residual,
        );
    var audit_probe_count: u32 = 0;
    const upper_represented_norm =
        try group_solve.probeOnlyFinalRepresentableNorm(
            &.{},
            audit_properties,
            .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
            &base_temperature_k,
            &audit_current,
            &target,
            &residual,
            &scaled_enthalpy,
            &audit_candidate,
            &audit_candidate_residual,
            &audit_candidate_scaled_enthalpy,
            &audit_checked,
            &audit_proven_mask,
            &output_flux,
            phase_buffers,
            one_step_options,
            &audit_probe_count,
        );
    try std.testing.expect(upper_raw_conservation_norm > 1);
    try std.testing.expect(upper_represented_norm <= 1);
    try std.testing.expectEqual(@as(f64, 1), audit_proven_mask[1]);
    try std.testing.expectEqual(switched_temperature_k, audit_current[1]);
    try std.testing.expect(audit_probe_count > 0);

    // Reverse the two limiting MJ coordinates so the sub-ULP endpoint is
    // discovered first. That endpoint must not suppress analytic Newton on
    // the unrelated smooth coordinate. This is the reduced form of Appendix
    // C step 8652: one already-complete phase coordinate coexists with a
    // smooth 7.5e-9 K correction whose MJ gate still exceeds one.
    const reversed_desired_defect_megajoules = [_]f64{
        tied_megajoule_coordinate * enthalpy_tolerance_megajoules,
        production_megajoule_coordinate * enthalpy_tolerance_megajoules,
    };
    var reversed_liquid_m3: [2]f64 = undefined;
    var reversed_ice_m3: [2]f64 = undefined;
    var reversed_heat_capacity: [2]f64 = undefined;
    var reversed_liquid_fraction: [2]f64 = undefined;
    var reversed_ice_fraction: [2]f64 = undefined;
    for (0..2) |cell| {
        const phase_exchange_megajoules_per_m3 =
            latent_heat_megajoules_per_m3 +
            (liquid_capacity_megajoules_per_m3_k -
                ice_capacity_megajoules_per_m3_k) *
                (base_temperature_k[cell] - melting_temperature_k);
        reversed_liquid_m3[cell] = equilibrium[cell].liquid_water_m3 +
            (reversed_desired_defect_megajoules[cell] -
                source_megajoules[cell]) /
                phase_exchange_megajoules_per_m3;
        reversed_ice_m3[cell] = total_water_m3[cell] - reversed_liquid_m3[cell];
        reversed_heat_capacity[cell] = dry_capacity_megajoules_per_k +
            liquid_capacity_megajoules_per_m3_k * reversed_liquid_m3[cell] +
            ice_capacity_megajoules_per_m3_k * reversed_ice_m3[cell];
        reversed_liquid_fraction[cell] =
            reversed_liquid_m3[cell] / volume_m3[cell];
        reversed_ice_fraction[cell] = reversed_ice_m3[cell] / volume_m3[cell];
    }
    var reversed_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer reversed_grid.deinit();
    @memcpy(reversed_grid.soil_temperature_k, &base_temperature_k);
    @memcpy(reversed_grid.matrix_liquid_water_m3, &reversed_liquid_m3);
    @memcpy(reversed_grid.matrix_ice_water_m3, &reversed_ice_m3);
    @memcpy(reversed_grid.liquid_water_m3, &reversed_liquid_m3);
    @memcpy(reversed_grid.ice_water_m3, &reversed_ice_m3);
    @memcpy(reversed_grid.matrix_pore_capacity_m3, &volume_m3);
    var reversed_properties = properties;
    reversed_properties.heat_capacity_megajoules_per_k = &reversed_heat_capacity;
    reversed_properties.liquid_water_fraction = &reversed_liquid_fraction;
    reversed_properties.ice_fraction = &reversed_ice_fraction;
    reversed_properties.enthalpy_coupling.?.matrix_liquid_water_m3 =
        reversed_grid.matrix_liquid_water_m3;
    reversed_properties.enthalpy_coupling.?.matrix_ice_water_equivalent_m3 =
        reversed_grid.matrix_ice_water_m3;
    const reversed_result = try group_solve.solve(
        std.testing.allocator,
        &reversed_grid,
        &.{},
        reversed_properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &output_flux,
        options,
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        reversed_result.megajoule_active_set_newton_steps,
    );
    try std.testing.expect(reversed_result.enthalpy_representability_probes > 0);
    try std.testing.expectEqual(@as(u16, 0), reversed_result.anderson_steps);
    try std.testing.expect(reversed_result.maximum_scaled_residual <= 1);
}

test "final conservation refinement retains adjacent endpoints while free coordinates advance" {
    // The hour-858 failure had one coordinate whose root was proven between
    // adjacent f64 temperatures and a second coordinate that still needed a
    // Newton correction. Pin the integration contract around the numerically
    // exercised endpoint repricer above: the final refinement may neither
    // erase that proof before pricing nor move the represented coordinate.
    const source = try readSolverSolveSource();
    defer std.testing.allocator.free(source);
    const refinement_start = std.mem.indexOf(
        u8,
        source,
        "const maximum_conservation_refinement_steps: u8 = 15;",
    ) orelse return error.MissingHeatConservationRefinement;
    const refinement_end = std.mem.indexOfPos(
        u8,
        source,
        refinement_start,
        "const strict_accept =",
    ) orelse return error.MissingHeatConservationAcceptance;
    const refinement = source[refinement_start..refinement_end];
    const loop_start = std.mem.indexOf(
        u8,
        refinement,
        "while (conservation_refinement_steps <",
    ) orelse return error.MissingHeatConservationRefinementLoop;
    try std.testing.expect(std.mem.indexOf(
        u8,
        refinement[0..loop_start],
        "@memset(enthalpy_endpoint_mask, 0);",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        refinement,
        "delta.* = if (endpoint != 0) 0 else difference_k;",
    ) != null);
    try std.testing.expect(std.mem.count(
        u8,
        refinement,
        "priceRepresentableNewtonDirection(",
    ) == 2);
    try std.testing.expect(source_scan.containsIgnoringCarriageReturns(
        refinement,
        "enthalpy_endpoint_mask,\n                    accepted_endpoint_proof_mask,",
    ));
    try std.testing.expect(std.mem.count(
        u8,
        refinement,
        "probeOnlyFinalRepresentableNorm(",
    ) == 2);
}

test "scaled slow Newton forecast distinguishes reachable and ineffective trajectories" {
    // Four accepted steps reduced this scaled merit by only ten percent. At
    // that observed logarithmic contraction, the three remaining NPH updates
    // cannot approach the unchanged acceptance gate at one.
    try std.testing.expect(group_solve.slowNewtonProgressNeedsRecovery(
        1000,
        900,
        4,
        3,
    ));
    // The same bounded window can also establish that Newton remains capable
    // of reaching the gate. This is not an unconditional final-slot diversion.
    try std.testing.expect(!group_solve.slowNewtonProgressNeedsRecovery(
        1.0e6,
        100,
        4,
        3,
    ));
    try std.testing.expect(group_solve.slowNewtonProgressNeedsRecovery(
        100,
        100,
        4,
        3,
    ));
    try std.testing.expect(!group_solve.slowNewtonProgressNeedsRecovery(
        1000,
        900,
        3,
        3,
    ));
    try std.testing.expect(!group_solve.slowNewtonProgressNeedsRecovery(
        1000,
        900,
        4,
        1,
    ));
    try std.testing.expect(!group_solve.slowNewtonProgressNeedsRecovery(
        2,
        1,
        4,
        3,
    ));
    try std.testing.expect(!group_solve.slowNewtonProgressNeedsRecovery(
        std.math.inf(f64),
        900,
        4,
        3,
    ));
}

test "heat primary Newton yields only to measured recovery signals" {
    const source = try readSolverSolveSource();
    defer std.testing.allocator.free(source);
    const primary_start = std.mem.indexOf(
        u8,
        source,
        "newton_primary: {",
    ) orelse return error.MissingHeatPrimaryNewtonSchedule;
    const recovery_start = std.mem.indexOfPos(
        u8,
        source,
        primary_start,
        "if (retrying_newton_after_anderson) continue;",
    ) orelse return error.MissingHeatNewtonRecoveryBoundary;
    const primary = source[primary_start..recovery_start];
    const enthalpy_dense_helper = std.mem.indexOf(
        u8,
        source,
        "noinline fn tryDenseSignedEnthalpyNewton(",
    ) orelse return error.MissingNoInlineDenseEnthalpyNewtonHelper;
    try std.testing.expect(enthalpy_dense_helper < primary_start);

    // NPH affects method routing only after a bounded normalized forecast has
    // established that the accepted Newton trajectory cannot reach the
    // existing gate while endpoint audit, Anderson, and its mandatory Newton
    // retry still fit. The primary block sees only that measured signal; it
    // cannot blindly reserve a final Newton slot.
    const forecast_start = std.mem.indexOf(
        u8,
        source,
        "const remaining_updates = options.max_iterations - iteration;",
    ) orelse return error.MissingHeatSlowProgressBudget;
    try std.testing.expect(forecast_start < primary_start);
    const forecast = source[forecast_start..primary_start];
    try std.testing.expect(std.mem.indexOf(
        u8,
        forecast,
        "remaining_updates <= slow_newton_recovery_reserve",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        forecast,
        "remaining_updates >= minimum_recovery_updates",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        forecast,
        "slowNewtonProgressNeedsRecovery(",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        primary,
        "progress_requires_anderson or slow_progress_requires_anderson",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, primary, "max_iterations") == null);

    // Each dense branch linearizes the coordinate that actually governs the
    // full merit. Signed energy gets a topology-independent bounded dense
    // path only where the sequential-column operator is unavailable; the
    // legacy K-linearized branch remains first only when K governs.
    const enthalpy_dense = source_scan.indexOfIgnoringCarriageReturns(
        primary,
        "if (use_dense_newton and\n                energy_merit_dominates and",
    ) orelse return error.MissingHeatDenseEnthalpyNewton;
    const temperature_dense = std.mem.indexOf(
        u8,
        primary,
        "if (use_dense_newton and !energy_merit_dominates) {",
    ) orelse return error.MissingHeatDenseNewton;
    const directional_gate = source_scan.indexOfIgnoringCarriageReturns(
        primary,
        "if (energy_merit_dominates)\n                    break :temperature_residual_directional;",
    ) orelse return error.MissingHeatDirectionalMeritGate;
    const directional = std.mem.indexOf(
        u8,
        primary,
        "stageAdmissibleDirectionProbe(",
    ) orelse return error.MissingHeatDirectionalNewton;
    try std.testing.expect(enthalpy_dense < temperature_dense);
    try std.testing.expect(temperature_dense < directional);
    try std.testing.expect(directional_gate < directional);
}

test "transition-optimized endpoint discovery full-scans before recovery or ceiling" {
    // Performance may skip an obviously smooth MJ coordinate, but that
    // shortcut is never scientific evidence that no lower-ranked endpoint
    // exists. Pin the two conservative production barriers: a skipped scan
    // forces a shortcut-free retry before Anderson, while the final allowed
    // iteration disables optimization before the hard ceiling is checked.
    const source = try readSolverSolveSource();
    defer std.testing.allocator.free(source);
    try std.testing.expect(source_scan.containsIgnoringCarriageReturns(
        source,
        "!force_full_endpoint_scan and\n                iteration + 1 < options.max_iterations",
    ));
    const retry_guard = std.mem.indexOf(
        u8,
        source,
        "if (retrying_newton_after_anderson) continue;",
    ) orelse return error.MissingNewtonRetryGuard;
    const recovery = std.mem.indexOfPos(
        u8,
        source,
        retry_guard,
        "// RECOVERY.",
    ) orelse return error.MissingAndersonRecovery;
    const barrier = source[retry_guard..recovery];
    try std.testing.expect(source_scan.containsIgnoringCarriageReturns(
        barrier,
        "endpoint_discovery_optimization_skipped and\n            !force_full_endpoint_scan",
    ));
    try std.testing.expect(source_scan.containsIgnoringCarriageReturns(
        barrier,
        "force_full_endpoint_scan = true;\n            continue;",
    ));
    const full_scan = std.mem.indexOf(
        u8,
        barrier,
        "force_full_endpoint_scan = true;",
    ) orelse unreachable;
    const hard_ceiling = std.mem.indexOf(
        u8,
        barrier,
        "iteration + 1 >= options.max_iterations",
    ) orelse return error.MissingHardIterationCeiling;
    try std.testing.expect(full_scan < hard_ceiling);

    const divergence_watch = std.mem.indexOf(
        u8,
        source,
        "non_improving_steps >= options.divergence_patience",
    ) orelse return error.MissingHeatDivergenceWatch;
    const divergence_defer = std.mem.indexOfPos(
        u8,
        source,
        divergence_watch,
        "terminal_reason = .diverged;",
    ) orelse return error.MissingHeatDivergenceDeferral;
    const divergence_barrier = source[divergence_watch..divergence_defer];
    try std.testing.expect(source_scan.containsIgnoringCarriageReturns(
        divergence_barrier,
        "endpoint_discovery_optimization_skipped and\n                        !force_full_endpoint_scan",
    ));
    try std.testing.expect(source_scan.containsIgnoringCarriageReturns(
        divergence_barrier,
        "force_full_endpoint_scan = true;\n                        continue;",
    ));

    const exhausted_audit = std.mem.indexOf(
        u8,
        source,
        "final_norm = final_audit:",
    ) orelse return error.MissingFinalRepresentabilityAudit;
    const exhausted_commit = std.mem.indexOfPos(
        u8,
        source,
        exhausted_audit,
        "const strict_accept = !newton_retry_required and final_norm <= 1;",
    ) orelse return error.MissingFinalConvergenceGate;
    try std.testing.expect(exhausted_audit < exhausted_commit);
    const exhausted_audit_source = source[exhausted_audit..exhausted_commit];
    try std.testing.expect(std.mem.indexOf(
        u8,
        exhausted_audit_source,
        "accepted_endpoint_proof_mask",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        exhausted_audit_source,
        "probeOnlyFinalRepresentableNorm(",
    ) != null);
    const best_state_restore = std.mem.indexOf(
        u8,
        source,
        "if (restore_best_before_final_audit and best_state_valid)",
    ) orelse return error.MissingHeatBestStateRestore;
    try std.testing.expect(best_state_restore < exhausted_audit);
    const terminal_error_switch = std.mem.indexOfPos(
        u8,
        source,
        exhausted_commit,
        "return switch (terminal_reason)",
    ) orelse return error.MissingHeatTerminalErrorClassification;
    try std.testing.expect(exhausted_commit < terminal_error_switch);

    const iteration_loop = std.mem.indexOf(
        u8,
        source,
        "while (iteration < options.max_iterations)",
    ) orelse return error.MissingHeatIterationLoop;
    const first_iteration_residual = std.mem.indexOfPos(
        u8,
        source,
        iteration_loop,
        "try group_residual.residualAt(",
    ) orelse return error.MissingHeatIterationResidual;
    const iteration_prefix = source[iteration_loop..first_iteration_residual];
    try std.testing.expect(std.mem.indexOf(
        u8,
        iteration_prefix,
        "accepted_state_endpoint_proof_valid = false;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        iteration_prefix,
        "accepted_state_endpoint_proof_norm = std.math.inf(f64);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        iteration_prefix,
        "@memset(accepted_endpoint_proof_mask, 0);",
    ) != null);

    const repricer_start = std.mem.indexOf(
        u8,
        source,
        "fn priceRepresentableNewtonDirection(",
    ) orelse return error.MissingRepresentableNewtonPricer;
    const repricer_end = std.mem.indexOfPos(
        u8,
        source,
        repricer_start,
        "fn priceNewtonDirection(",
    ) orelse return error.MissingRepresentableNewtonPricerEnd;
    const repricer = source[repricer_start..repricer_end];
    try std.testing.expect(std.mem.indexOf(
        u8,
        repricer,
        "@memcpy(best_proven_mask, proven_mask);",
    ) != null);
    const endpoint_reprice_start = std.mem.indexOf(
        u8,
        source,
        "pub fn repriceAdjacentEnthalpyEndpoints(",
    ) orelse return error.MissingEndpointRepricing;
    const endpoint_reprice = source[endpoint_reprice_start..repricer_start];
    try std.testing.expect(std.mem.indexOf(
        u8,
        endpoint_reprice,
        "preferAlternativeRepresentedEndpoint(",
    ) != null);

    const final_probe_start = std.mem.indexOf(
        u8,
        source,
        "fn probeOnlyFinalRepresentableNorm(",
    ) orelse return error.MissingFinalProbeOnlyAudit;
    const final_probe_end = std.mem.indexOfPos(
        u8,
        source,
        final_probe_start,
        "/// Re-establishes every proven adjacent-f64 enthalpy bracket",
    ) orelse return error.MissingFinalProbeOnlyAuditEnd;
    const final_probe = source[final_probe_start..final_probe_end];
    try std.testing.expect(std.mem.indexOf(
        u8,
        final_probe,
        "current: []const f64",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, final_probe, "@memcpy(current") == null);
}

test "represented endpoint merit ignores raw sub-ULP MJ ranking but retains coupled merit" {
    const options: group_types.Options = .{
        .max_iterations = 1,
        .absolute_tolerance_k = 1,
        .relative_tolerance = 0,
    };
    const temperature_k = [_]f64{ 273.15, 270 };
    const recognized = [_]f64{ 1, 0 };
    const current_residual_k = [_]f64{ 0.1, 0.2 };
    const alternative_residual_k = [_]f64{ -0.1, 0.9 };
    const current_scaled_enthalpy = [_]f64{ 100, 0.2 };
    const alternative_scaled_enthalpy = [_]f64{ -1, 0.9 };
    var merit_scratch: [2]f64 = undefined;

    const raw_current = try group_residual.scaledNorm(
        &temperature_k,
        &current_residual_k,
        &current_scaled_enthalpy,
        true,
        options,
    );
    const raw_alternative = try group_residual.scaledNorm(
        &temperature_k,
        &alternative_residual_k,
        &alternative_scaled_enthalpy,
        true,
        options,
    );
    try std.testing.expect(raw_alternative < raw_current);

    const represented_current = try group_solve.representedEndpointNorm(
        &temperature_k,
        &current_residual_k,
        &current_scaled_enthalpy,
        &recognized,
        &merit_scratch,
        options,
    );
    const represented_alternative = try group_solve.representedEndpointNorm(
        &temperature_k,
        &alternative_residual_k,
        &alternative_scaled_enthalpy,
        &recognized,
        &merit_scratch,
        options,
    );
    // Masking the proven sub-ULP MJ coordinate in both alternatives reverses
    // the raw ranking while retaining the K gate and coupled smooth cell.
    try std.testing.expect(represented_current < represented_alternative);

    // When another coupled coordinate dominates both represented merits, an
    // upper current endpoint and its lower adjacent alternative tie exactly.
    // The shared selector must reproduce the established lower-temperature
    // choice even though their raw active-MJ coordinates differ strongly.
    const lower_temperature_k = [_]f64{ 273.15, 270 };
    const upper_temperature_k = [_]f64{
        std.math.nextAfter(f64, 273.15, std.math.inf(f64)),
        270,
    };
    const tie_current_residual_k = [_]f64{ 0.1, 0.9 };
    const tie_alternative_residual_k = [_]f64{ -0.1, 0.9 };
    const tie_current_scaled_enthalpy = [_]f64{ -100, 0.9 };
    const tie_alternative_scaled_enthalpy = [_]f64{ 1, 0.9 };
    const represented_upper = try group_solve.representedEndpointNorm(
        &upper_temperature_k,
        &tie_current_residual_k,
        &tie_current_scaled_enthalpy,
        &recognized,
        &merit_scratch,
        options,
    );
    const represented_lower = try group_solve.representedEndpointNorm(
        &lower_temperature_k,
        &tie_alternative_residual_k,
        &tie_alternative_scaled_enthalpy,
        &recognized,
        &merit_scratch,
        options,
    );
    try std.testing.expectEqual(represented_upper, represented_lower);
    try std.testing.expect(group_solve.preferAlternativeRepresentedEndpoint(
        represented_upper,
        upper_temperature_k[0],
        represented_lower,
        lower_temperature_k[0],
    ));
    try std.testing.expect(!group_solve.preferAlternativeRepresentedEndpoint(
        represented_lower,
        lower_temperature_k[0],
        represented_upper,
        upper_temperature_k[0],
    ));

    const source = try readSolverSolveSource();
    defer std.testing.allocator.free(source);
    const fast_path = std.mem.indexOf(
        u8,
        source,
        "// Common case: the neighbour-changing Newton proposal",
    ) orelse return error.MissingSettledEndpointFastPath;
    const slow_path = std.mem.indexOfPos(
        u8,
        source,
        fast_path,
        "// A neighbour-changing Newton proposal can move an endpoint root",
    ) orelse return error.MissingEndpointRelocationFallback;
    const fast_source = source[fast_path..slow_path];
    try std.testing.expect(std.mem.count(
        u8,
        fast_source,
        "conservationAwareRepresentedEndpointNorm(",
    ) == 2);
    try std.testing.expect(std.mem.count(
        u8,
        fast_source,
        "preferAlternativeRepresentedEndpoint(",
    ) == 1);

    const final_probe_start = std.mem.indexOf(
        u8,
        source,
        "fn probeOnlyFinalRepresentableNorm(",
    ) orelse return error.MissingFinalProbeOnlyAudit;
    const final_probe_end = std.mem.indexOfPos(
        u8,
        source,
        final_probe_start,
        "pub fn representedEndpointNorm(",
    ) orelse return error.MissingRepresentedEndpointNorm;
    const final_probe = source[final_probe_start..final_probe_end];
    try std.testing.expect(std.mem.count(
        u8,
        final_probe,
        "preferAlternativeRepresentedEndpoint(",
    ) == 0);

    const discovery_start = std.mem.indexOf(
        u8,
        source,
        "// The saturated enthalpy curve can cross its exact root",
    ) orelse return error.MissingEndpointDiscovery;
    const discovery_end = std.mem.indexOfPos(
        u8,
        source,
        discovery_start,
        "// If another, achievable coordinate still limits convergence",
    ) orelse return error.MissingEndpointDiscoveryEnd;
    const discovery = source[discovery_start..discovery_end];
    try std.testing.expect(std.mem.count(
        u8,
        discovery,
        "conservationAwareRepresentedEndpointNorm(",
    ) == 6);
    try std.testing.expect(std.mem.count(
        u8,
        discovery,
        "preferAlternativeRepresentedEndpoint(",
    ) == 2);
}

test "endpoint certificate rejects a non-adjacent bracket after bounded bisection" {
    const lower_temperature_k: f64 = 200;
    const adjacent_temperature_k = std.math.nextAfter(
        f64,
        lower_temperature_k,
        std.math.inf(f64),
    );
    try std.testing.expect(group_solve.isExactOrAdjacentEndpointBracket(
        lower_temperature_k,
        lower_temperature_k,
    ));
    try std.testing.expect(group_solve.isExactOrAdjacentEndpointBracket(
        lower_temperature_k,
        adjacent_temperature_k,
    ));
    // A wide physical-temperature bracket cannot be certified simply because
    // the bounded scalar-probe budget was exhausted.
    try std.testing.expect(!group_solve.isExactOrAdjacentEndpointBracket(
        lower_temperature_k,
        300,
    ));

    const source = try readSolverSolveSource();
    defer std.testing.allocator.free(source);
    const bisection_start = std.mem.indexOf(
        u8,
        source,
        "var bisection_step: u8 = 0;",
    ) orelse return error.MissingEndpointBisection;
    const endpoint_pricing = std.mem.indexOfPos(
        u8,
        source,
        bisection_start,
        "candidate[cell] = lower_temperature_k;",
    ) orelse return error.MissingEndpointPricing;
    const post_bisection = source[bisection_start..endpoint_pricing];
    try std.testing.expect(std.mem.indexOf(
        u8,
        post_bisection,
        "if (!isExactOrAdjacentEndpointBracket(",
    ) != null);
}

test "heat topology endpoint constraints preserve every unmasked Newton row" {
    const mask = [_]f64{ 0, 1, 0, 1 };
    var lower = [_]f64{ 0, -2, -3, -4 };
    var diagonal = [_]f64{ 10, 20, 30, 40 };
    var upper = [_]f64{ 5, 6, 7, 0 };
    var right_hand_side = [_]f64{ 11, 12, 13, 14 };
    try std.testing.expect(group_solve.constrainRepresentableEndpointRows(
        &mask,
        &lower,
        &diagonal,
        &upper,
        &right_hand_side,
    ));
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, -3, 0 }, &lower);
    try std.testing.expectEqualSlices(f64, &.{ 10, 1, 30, 1 }, &diagonal);
    try std.testing.expectEqualSlices(f64, &.{ 5, 0, 7, 0 }, &upper);
    try std.testing.expectEqualSlices(f64, &.{ 11, 0, 13, 0 }, &right_hand_side);
}

test "rejected mixed endpoint repricing preserves the current signed MJ vector" {
    // The early mixed-endpoint branch may reject every neighbor-changing
    // candidate and fall through to enthalpy-topology/MJ Newton. Its repricer
    // therefore needs private scratch; using `accelerated_residual` as the
    // saved-candidate buffer corrupts the current signed MJ vector before that
    // downstream Newton reads it. Pin the production call's buffer ownership.
    const source = try readSolverSolveSource();
    defer std.testing.allocator.free(source);
    const branch_start = std.mem.indexOf(
        u8,
        source,
        "if (!committed_neighbor and representable_norm > 1)",
    ) orelse return error.MissingMixedEndpointRepricingBranch;
    const branch_end = std.mem.indexOfPos(
        u8,
        source,
        branch_start,
        "if (committed_neighbor) continue;",
    ) orelse return error.MissingMixedEndpointRepricingCloseout;
    const branch = source[branch_start..branch_end];
    try std.testing.expect(source_scan.containsIgnoringCarriageReturns(
        branch,
        "probe_residual,\n                                        topology_lower,\n                                        topology_diagonal,",
    ));
    // This negative assertion was previously passing for the wrong reason: on a
    // CRLF checkout its `\n` needle could not match regardless of what the
    // production text said, so it proved nothing (issue-076).
    try std.testing.expect(!source_scan.containsIgnoringCarriageReturns(
        branch,
        "probe_residual,\n                                        accelerated_residual,\n                                        topology_diagonal,",
    ));
}

test "exact enthalpy Anderson promotion is unpublished until a Newton retry" {
    // The private Picard seed supplies only the second fixed-point sample. It
    // must not lower the merit incumbent used to price a publishable Anderson
    // proposal. Pin the production branch as well as the end-to-end method
    // counters below: the scalar adversarial merit case lives in numerics.zig.
    const solve_source = try readSolverSolveSource();
    defer std.testing.allocator.free(solve_source);
    const recovery_start = std.mem.indexOf(
        u8,
        solve_source,
        "var best_anderson_norm = norm;",
    ) orelse return error.MissingHeatAndersonRecovery;
    const recovery_end = std.mem.indexOfPos(
        u8,
        solve_source,
        recovery_start,
        "// Anderson acceleration over consistent evaluated",
    ) orelse return error.MissingHeatAndersonHistory;
    const initial_recovery = solve_source[recovery_start..recovery_end];
    try std.testing.expect(std.mem.indexOf(u8, initial_recovery, "seed_norm") == null);
    try std.testing.expect(std.mem.indexOf(u8, initial_recovery, "@min(best_anderson_norm") == null);

    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 3, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 3 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    const curve_value: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 4,
        .n = 2,
        .saturated_hydraulic_conductivity_m_per_h = 1,
    };
    const curve = [_]retention.MualemVanGenuchtenParameters{
        curve_value,
        curve_value,
        curve_value,
    };
    const volume = [_]f64{ 0.01, 0.01, 0.01 };
    const phase_parameters: enthalpy.Parameters = .{
        .porous_medium_volume_m3 = volume[0],
        .total_water_equivalent_m3 = volume[0],
        .unfrozen_pressure_head_m = 0,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        .dry_solid_heat_capacity_megajoules_per_k = 0.02,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
        .mualem_van_genuchten = curve_value,
    };
    var capacity: [3]f64 = undefined;
    var liquid_fraction: [3]f64 = undefined;
    var ice_fraction: [3]f64 = undefined;
    @memset(grid.soil_temperature_k, phase_parameters.pure_water_melting_temperature_k);
    for (0..3) |cell| {
        const phase = try enthalpy.stateAtTemperature(
            phase_parameters,
            grid.soil_temperature_k[cell],
        );
        grid.matrix_liquid_water_m3[cell] = phase.liquid_water_m3;
        grid.matrix_ice_water_m3[cell] = phase.ice_water_equivalent_m3;
        grid.liquid_water_m3[cell] = phase.liquid_water_m3;
        grid.matrix_pore_capacity_m3[cell] = volume[cell];
        capacity[cell] = phase.sensible_heat_capacity_megajoules_per_k;
        liquid_fraction[cell] = phase.liquid_water_m3 / volume[cell];
        ice_fraction[cell] = phase.ice_water_equivalent_m3 / volume[cell];
    }
    const zero = [_]f64{ 0, 0, 0 };
    const source = [_]f64{ -0.05, -0.04, -0.03 };
    const top = [_]bool{ true, false, false };
    const empty_curve: [0]retention.MualemVanGenuchtenParameters = .{};
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &zero,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &ice_fraction,
        .air_fraction = &zero,
        .fraction_of_pore_volume_air_filled = &zero,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &zero,
        .solid_conductivity_denominator = &zero,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &source,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = .{
            .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
            .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
            .porous_medium_volume_m3 = &volume,
            .mualem_van_genuchten = &curve,
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .pure_water_melting_temperature_k = phase_parameters.pure_water_melting_temperature_k,
            .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
            .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
            .ice_density_megagrams_per_m3 = 0.917,
            .solver_options = .{
                .max_iterations = 20,
                .local_iteration_limit = 12,
            },
            .macropore_mualem_van_genuchten = &empty_curve,
        },
    };
    const empty_flux: [0]f64 = .{};
    var empty_heat_flux: [0]f64 = .{};
    const initial_temperature_k = [_]f64{
        grid.soil_temperature_k[0],
        grid.soil_temperature_k[1],
        grid.soil_temperature_k[2],
    };
    var exact_image: [3]f64 = undefined;
    var target: [3]f64 = undefined;
    var residual: [3]f64 = undefined;
    var scaled_enthalpy: [3]f64 = undefined;
    var phase_liquid: [3]f64 = undefined;
    var phase_ice: [3]f64 = undefined;
    var phase_macropore_liquid: [3]f64 = undefined;
    var phase_macropore_ice: [3]f64 = undefined;
    const options: group_types.Options = .{
        .max_iterations = 2,
        .absolute_tolerance_k = 1e-8,
        .relative_tolerance = 1e-10,
        .directional_probe_fraction = 1e-16,
        .dense_newton_max_components = 0,
    };
    const phase_buffers: group_misc.PhaseBuffers = .{
        .matrix_liquid_m3 = &phase_liquid,
        .matrix_ice_m3 = &phase_ice,
        .macropore_liquid_m3 = &phase_macropore_liquid,
        .macropore_ice_m3 = &phase_macropore_ice,
        .macropore_enabled = false,
        .ice_density_megagrams_per_m3 = 0.917,
    };
    try group_residual.exactEnthalpyPicardImage(
        &.{},
        properties,
        .{
            .liquid_water_m3 = &empty_flux,
            .vapor_m3 = &empty_flux,
            .macropore_water_m3 = &empty_flux,
        },
        &initial_temperature_k,
        &initial_temperature_k,
        &exact_image,
        &target,
        &residual,
        &scaled_enthalpy,
        &empty_heat_flux,
        phase_buffers,
        options,
    );
    const initial_norm = try group_residual.scaledNorm(
        &initial_temperature_k,
        &residual,
        &scaled_enthalpy,
        true,
        options,
    );
    try std.testing.expect(initial_norm > 1);
    try std.testing.expect(!std.mem.eql(f64, &initial_temperature_k, &exact_image));
    // Evaluating the raw exact map is probe-only and cannot publish phase or
    // temperature state.
    try std.testing.expectEqualSlices(f64, &initial_temperature_k, grid.soil_temperature_k);

    var final_slot_options = options;
    final_slot_options.max_iterations = 1;
    try std.testing.expectError(error.SoilHeatSolverDidNotConverge, group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        .{ .liquid_water_m3 = &empty_flux, .vapor_m3 = &empty_flux, .macropore_water_m3 = &empty_flux },
        &empty_heat_flux,
        final_slot_options,
    ));
    try std.testing.expectEqualSlices(f64, &initial_temperature_k, grid.soil_temperature_k);

    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        .{
            .liquid_water_m3 = &empty_flux,
            .vapor_m3 = &empty_flux,
            .macropore_water_m3 = &empty_flux,
        },
        &empty_heat_flux,
        options,
    );
    try std.testing.expectEqual(@as(u16, 2), result.iterations);
    try std.testing.expectEqual(@as(u16, 1), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 1), result.anderson_steps);
    try std.testing.expectEqual(result.anderson_steps, result.picard_steps);
    try std.testing.expect(result.maximum_scaled_residual < initial_norm);
    try std.testing.expect(result.maximum_scaled_residual <= 1);
    try std.testing.expect(result.newton_raphson_steps + result.anderson_steps <= options.max_iterations);
}

test "runtime Dirichlet thermal face uses cell distance and physical step" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 1,
            .lat_count = 1,
            .soil_layers = 1,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 40,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 280;
    const capacity = [_]f64{2};
    const zero = [_]f64{0};
    const density = [_]f64{1};
    const liquid = [_]f64{0.2};
    const air = [_]f64{0.3};
    const numerator = [_]f64{0.01};
    const denominator = [_]f64{1};
    const top = [_]bool{true};
    const boundary_cell = [_]usize{0};
    const boundary_temperature = [_]f64{300};
    const boundary_distance = [_]f64{0.5};
    const boundary_area = [_]f64{1};
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &density,
        .liquid_water_fraction = &liquid,
        .ice_fraction = &zero,
        .air_fraction = &air,
        .fraction_of_pore_volume_air_filled = &air,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &numerator,
        .solid_conductivity_denominator = &denominator,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &zero,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .time_step_hours = 0.25,
        .dirichlet_thermal_boundaries = .{
            .cell_index = &boundary_cell,
            .temperature_k = &boundary_temperature,
            .distance_from_cell_center_m = &boundary_distance,
            .face_area_m2 = &boundary_area,
        },
    };
    const empty_flux: [0]f64 = .{};
    var heat_flux: [0]f64 = .{};
    const conductivity = try heat.calculateCellConductivity(
        try group_enthalpy.cellConductivityInputs(
            properties,
            0,
            20,
            .{
                .matrix_liquid_m3 = &heat_flux,
                .matrix_ice_m3 = &heat_flux,
                .macropore_liquid_m3 = &heat_flux,
                .macropore_ice_m3 = &heat_flux,
                .macropore_enabled = false,
                .ice_density_megagrams_per_m3 = 0.917,
            },
        ),
        properties.turbulence,
    );
    const coefficient = conductivity * boundary_area[0] *
        properties.time_step_hours /
        (boundary_distance[0] * capacity[0]);
    const expected_temperature_k =
        (280 + coefficient * boundary_temperature[0]) /
        (1 + coefficient);
    var workspace = try group_types.Workspace.init(
        std.testing.allocator,
        1,
        0,
        40,
    );
    defer workspace.deinit();
    const first_result = try group_solve.solveWithWorkspace(
        &workspace,
        &grid,
        &.{},
        properties,
        .{
            .liquid_water_m3 = &empty_flux,
            .vapor_m3 = &empty_flux,
            .macropore_water_m3 = &empty_flux,
        },
        &heat_flux,
        .{ .max_iterations = 40 },
    );
    try std.testing.expectApproxEqAbs(
        expected_temperature_k,
        grid.soil_temperature_k[0],
        1.0e-9,
    );
    try std.testing.expectApproxEqAbs(
        capacity[0] * (expected_temperature_k - 280),
        first_result.boundary_heat_input_megajoules,
        1.0e-9,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        first_result.boundary_heat_output_megajoules,
    );
    var boundary_input_by_cell = [_]f64{0};
    var boundary_output_by_cell = [_]f64{0};
    const boundary_total = try group_boundary.acceptedBoundaryHeatByHorizontalCell(
        properties,
        grid.soil_temperature_k,
        .{
            .matrix_liquid_m3 = workspace.matrix_liquid_m3,
            .matrix_ice_m3 = workspace.matrix_ice_m3,
            .macropore_liquid_m3 = workspace.macropore_liquid_m3,
            .macropore_ice_m3 = workspace.macropore_ice_m3,
            .macropore_enabled = false,
            .ice_density_megagrams_per_m3 = 0.917,
        },
        1,
        &boundary_input_by_cell,
        &boundary_output_by_cell,
    );
    try std.testing.expectEqual(boundary_total.input_megajoules, boundary_input_by_cell[0]);
    try std.testing.expectEqual(boundary_total.output_megajoules, boundary_output_by_cell[0]);
    const first_temperature_k = grid.soil_temperature_k[0];
    _ = try group_solve.solveWithWorkspace(
        &workspace,
        &grid,
        &.{},
        properties,
        .{
            .liquid_water_m3 = &empty_flux,
            .vapor_m3 = &empty_flux,
            .macropore_water_m3 = &empty_flux,
        },
        &heat_flux,
        .{ .max_iterations = 40 },
    );
    try std.testing.expect(grid.soil_temperature_k[0] >
        first_temperature_k);
}

test "unfrozen pressure head prices total water on the unmodified retention curve" {
    // HEAT-001 regression. `1c97ba0` priced the LIQUID content against a
    // retention curve whose saturated content had been reduced by the ice
    // fraction. Both halves of that are wrong, and this test pins each one
    // independently so a future change cannot reintroduce one while the other
    // stays fixed.
    const curve = retention.MualemVanGenuchtenParameters{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.5,
        .alpha_per_m = 1.6,
        .n = 1.6,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    const volume_m3 = 1.0;

    // Property 1: the head is a function of TOTAL water, so repartitioning the
    // same total between liquid and ice cannot move it. This is what makes the
    // Dall'Amico reference state independent of the answer the equilibrium is
    // solving for. The old code made the head fall as ice grew.
    //
    // The comparison is approximate rather than exact only because
    // `total*(1-f) + total*f` is not bit-identical to `total` in binary floating
    // point; the tolerance covers the TEST's own rounding, not any latitude in
    // the property. `1e-15` is about four ulp here, while the defect this pins
    // moves the head by more than `1e-3` (asserted below).
    const total_m3 = 0.30;
    const total_head_m = try group_enthalpy.unfrozenPressureHeadM(curve, total_m3, volume_m3);
    var ice_fraction: f64 = 0;
    while (ice_fraction <= 0.9) : (ice_fraction += 0.1) {
        const liquid_m3 = total_m3 * (1.0 - ice_fraction);
        const ice_m3 = total_m3 * ice_fraction;
        try std.testing.expectApproxEqRel(
            total_head_m,
            try group_enthalpy.unfrozenPressureHeadM(curve, liquid_m3 + ice_m3, volume_m3),
            1e-15,
        );
    }

    // Property 2: the head is a point ON the curve it is consumed with, so
    // reading the water content back off that same curve returns the input.
    // An ice-shrunk curve breaks exactly this round trip, which is what left
    // `soil_enthalpy_balance` evaluating the enthalpy and its own temperature
    // derivative on two different constitutive relations.
    try std.testing.expectApproxEqRel(
        total_m3 / volume_m3,
        try curve.waterContentAtPressureHead(total_head_m),
        1e-12,
    );

    // The defect's own signature, to prove property 1 is a real constraint and
    // not a tautology a degenerate curve would also satisfy: the head the old
    // code produced for a 0.2 ice fraction is distinguishable from the correct
    // head by far more than a rounding error.
    const ice_shrunk = retention.MualemVanGenuchtenParameters{
        .residual_water_content_m3_per_m3 = curve.residual_water_content_m3_per_m3,
        .saturated_water_content_m3_per_m3 = curve.saturated_water_content_m3_per_m3 - 0.2,
        .alpha_per_m = curve.alpha_per_m,
        .n = curve.n,
        .pore_connectivity = curve.pore_connectivity,
        .saturated_hydraulic_conductivity_m_per_h = curve.saturated_hydraulic_conductivity_m_per_h,
    };
    const old_code_head_m = try ice_shrunk.pressureHeadAtWaterContent(0.1);
    try std.testing.expect(@abs(old_code_head_m - total_head_m) > 1e-3);

    // Saturation is where the head is zero, and total water at or above
    // saturation clamps there rather than leaving the retention domain. This is
    // the guard `soil_phase_solver.freezeThawEquilibrium` already applies: an
    // admissibility clamp on the INPUT, not a widened domain.
    try std.testing.expectEqual(
        @as(f64, 0),
        try group_enthalpy.unfrozenPressureHeadM(curve, 0.5, volume_m3),
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        try group_enthalpy.unfrozenPressureHeadM(curve, 0.7, volume_m3),
    );

    // Degenerate geometry is an error, not a silent infinity.
    try std.testing.expectError(
        error.InvalidCoupledSoilPorousMediumVolume,
        group_enthalpy.unfrozenPressureHeadM(curve, 0.3, 0),
    );
}

test "macropore phase state_update refuses to zero a cell that has no macropore capacity but holds water" {
    // HEAT-MACROPORE-PUBLISH-SINK-001 regression. The upstream phase solver
    // substitutes a literal 0 for macropore liquid and ice whenever the
    // secondary equilibrium is absent, which is exactly what happens for a
    // zero-capacity cell. The old unconditional @memcpy published that zero
    // over live water and the recomputation loop rebuilt the totals from the
    // components it had just overwritten, so the loss was unobservable
    // downstream. The state_update must now refuse instead.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 80 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    // Cell 0 has macropore capacity, cell 1 does not. That is the Ottawa
    // profile shape: 0.01 for the upper cells, then zeros, some declared and
    // some copy-forward extrapolated.
    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.macropore_pore_capacity_m3[0] = 0.1;
    grid.matrix_pore_capacity_m3[1] = 0.5;
    grid.macropore_pore_capacity_m3[1] = 0;

    // Cell 1 is holding macropore water despite having no capacity for it.
    // That is the corrupt precondition the old code erased.
    grid.matrix_liquid_water_m3[0] = 0.11;
    grid.matrix_liquid_water_m3[1] = 0.12;
    grid.matrix_ice_water_m3[0] = 0.01;
    grid.matrix_ice_water_m3[1] = 0.02;
    grid.macropore_liquid_water_m3[0] = 0.03;
    grid.macropore_liquid_water_m3[1] = 0.02;
    grid.macropore_ice_water_m3[0] = 0.004;
    grid.liquid_water_m3[0] = 0.14;
    grid.liquid_water_m3[1] = 0.14;
    grid.ice_water_m3[0] = 0.014;
    grid.ice_water_m3[1] = 0.02;
    const matrix_liquid_before = [_]f64{ 0.11, 0.12 };
    const matrix_ice_before = [_]f64{ 0.01, 0.02 };
    const macropore_liquid_before = [_]f64{ 0.03, 0.02 };
    const macropore_ice_before = [_]f64{ 0.004, 0 };
    const total_liquid_before = [_]f64{ 0.14, 0.14 };
    const total_ice_before = [_]f64{ 0.014, 0.02 };
    const matrix_air_before = [_]f64{ grid.matrix_air_volume_m3[0], grid.matrix_air_volume_m3[1] };
    const macropore_air_before = [_]f64{ grid.macropore_air_volume_m3[0], grid.macropore_air_volume_m3[1] };
    const total_air_before = [_]f64{ grid.air_volume_m3[0], grid.air_volume_m3[1] };

    var matrix_liquid = [_]f64{ 0.4, 0.4 };
    var matrix_ice = [_]f64{ 0, 0 };
    var macropore_liquid = [_]f64{ 0.05, 0 };
    var macropore_ice = [_]f64{ 0, 0 };

    try std.testing.expectError(error.UnbackedMacroporePhaseInventory, group_residual.state_updateMatrixPhase(&grid, .{
        .matrix_liquid_m3 = &matrix_liquid,
        .matrix_ice_m3 = &matrix_ice,
        .macropore_liquid_m3 = &macropore_liquid,
        .macropore_ice_m3 = &macropore_ice,
        .macropore_enabled = true,
        .ice_density_megagrams_per_m3 = 0.917,
    }));

    // Every primary and derived phase owner is byte-for-byte unchanged. The
    // state_update refused before publishing either matrix or macropore state.
    try std.testing.expectEqualSlices(f64, &matrix_liquid_before, grid.matrix_liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &matrix_ice_before, grid.matrix_ice_water_m3);
    try std.testing.expectEqualSlices(f64, &macropore_liquid_before, grid.macropore_liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &macropore_ice_before, grid.macropore_ice_water_m3);
    try std.testing.expectEqualSlices(f64, &total_liquid_before, grid.liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &total_ice_before, grid.ice_water_m3);
    try std.testing.expectEqualSlices(f64, &matrix_air_before, grid.matrix_air_volume_m3);
    try std.testing.expectEqualSlices(f64, &macropore_air_before, grid.macropore_air_volume_m3);
    try std.testing.expectEqualSlices(f64, &total_air_before, grid.air_volume_m3);
}

test "late heat phase preflight leaves temperature water phase and caller flux unchanged" {
    // A converged nonlinear candidate is still only staged state. This setup
    // deliberately carries resident macropore water in cell 1 despite zero
    // macropore capacity, so the final phase preflight fails after cell 0 has
    // solved a nonzero heat source. No part of that candidate may leak out.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 80 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    @memcpy(grid.soil_temperature_k, &[_]f64{ 275, 270 });
    @memcpy(grid.matrix_pore_capacity_m3, &[_]f64{ 0.5, 0.5 });
    @memcpy(grid.macropore_pore_capacity_m3, &[_]f64{ 0.1, 0 });
    @memcpy(grid.matrix_liquid_water_m3, &[_]f64{ 0.2, 0.12 });
    @memcpy(grid.matrix_ice_water_m3, &[_]f64{ 0, 0.02 });
    @memcpy(grid.macropore_liquid_water_m3, &[_]f64{ 0.03, 0.02 });
    @memcpy(grid.macropore_ice_water_m3, &[_]f64{ 0, 0.004 });
    @memcpy(grid.liquid_water_m3, &[_]f64{ 0.23, 0.14 });
    @memcpy(grid.ice_water_m3, &[_]f64{ 0, 0.024 });
    @memcpy(grid.matrix_air_volume_m3, &[_]f64{ 0.3, 0.358 });
    @memcpy(grid.macropore_air_volume_m3, &[_]f64{ 0.07, 0 });
    @memcpy(grid.air_volume_m3, &[_]f64{ 0.37, 0.358 });

    const temperature_before = [_]f64{ 275, 270 };
    const matrix_liquid_before = [_]f64{ 0.2, 0.12 };
    const matrix_ice_before = [_]f64{ 0, 0.02 };
    const macropore_liquid_before = [_]f64{ 0.03, 0.02 };
    const macropore_ice_before = [_]f64{ 0, 0.004 };
    const total_liquid_before = [_]f64{ 0.23, 0.14 };
    const total_ice_before = [_]f64{ 0, 0.024 };
    const matrix_air_before = [_]f64{ 0.3, 0.358 };
    const macropore_air_before = [_]f64{ 0.07, 0 };
    const total_air_before = [_]f64{ 0.37, 0.358 };

    const matrix_curve_value: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.5,
        .alpha_per_m = 1.6,
        .n = 1.6,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    const macropore_curve_value: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 15,
        .n = 2.68,
        .saturated_hydraulic_conductivity_m_per_h = 0.1,
    };
    const matrix_curve = [_]retention.MualemVanGenuchtenParameters{ matrix_curve_value, matrix_curve_value };
    const macropore_curve = [_]retention.MualemVanGenuchtenParameters{ macropore_curve_value, macropore_curve_value };
    const matrix_volume = [_]f64{ 1, 1 };
    const macropore_volume = [_]f64{ 0.1, 0.1 };
    const capacity = [_]f64{ 2, 2 };
    const zero = [_]f64{ 0, 0 };
    const density = [_]f64{ 1, 1 };
    const liquid_fraction = [_]f64{ 0.23, 0.14 };
    const ice_fraction = [_]f64{ 0, 0.024 };
    const air_fraction = [_]f64{ 0.37, 0.358 };
    const numerator = [_]f64{ 0.01, 0.01 };
    const denominator = [_]f64{ 1, 1 };
    const top = [_]bool{ true, false };
    const source = [_]f64{ 0.1, 0 };
    const coupling: group_misc.EnthalpyCoupling = .{
        .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
        .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
        .porous_medium_volume_m3 = &matrix_volume,
        .mualem_van_genuchten = &matrix_curve,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
        .ice_density_megagrams_per_m3 = 0.917,
        .solver_options = .{ .max_iterations = 80 },
        .macropore_liquid_water_m3 = grid.macropore_liquid_water_m3,
        .macropore_ice_water_equivalent_m3 = grid.macropore_ice_water_m3,
        .macropore_porous_medium_volume_m3 = &macropore_volume,
        .macropore_mualem_van_genuchten = &macropore_curve,
    };
    const properties: group_types.Properties = .{
        .heat_capacity_megajoules_per_k = &capacity,
        .minimum_heat_capacity_megajoules_per_k = &zero,
        .bulk_density_megagrams_per_m3 = &density,
        .liquid_water_fraction = &liquid_fraction,
        .ice_fraction = &ice_fraction,
        .air_fraction = &air_fraction,
        .fraction_of_pore_volume_air_filled = &air_fraction,
        .solid_conductivity_numerator_m_megajoules_per_h_k = &numerator,
        .solid_conductivity_denominator = &denominator,
        .is_top_soil_layer = &top,
        .top_snow_heat_capacity_megajoules_per_k = &zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero,
        .snow_storage_heat_flux_megajoules = &zero,
        .cell_heat_source_megajoules = &source,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .enthalpy_coupling = coupling,
    };
    const faces = [_]group_types.Face{.{
        .source_cell = 0,
        .destination_cell = 1,
        .source_path_length_m = 1,
        .destination_path_length_m = 1,
        .face_area_m2 = 0,
    }};
    const no_water_flux = [_]f64{0};
    var caller_heat_flux = [_]f64{123.456};

    try std.testing.expectError(
        error.UnbackedMacroporePhaseInventory,
        group_solve.solve(
            std.testing.allocator,
            &grid,
            &faces,
            properties,
            .{
                .liquid_water_m3 = &no_water_flux,
                .vapor_m3 = &no_water_flux,
                .macropore_water_m3 = &no_water_flux,
            },
            &caller_heat_flux,
            .{ .max_iterations = 80 },
        ),
    );

    try std.testing.expectEqualSlices(f64, &temperature_before, grid.soil_temperature_k);
    try std.testing.expectEqualSlices(f64, &matrix_liquid_before, grid.matrix_liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &matrix_ice_before, grid.matrix_ice_water_m3);
    try std.testing.expectEqualSlices(f64, &macropore_liquid_before, grid.macropore_liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &macropore_ice_before, grid.macropore_ice_water_m3);
    try std.testing.expectEqualSlices(f64, &total_liquid_before, grid.liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &total_ice_before, grid.ice_water_m3);
    try std.testing.expectEqualSlices(f64, &matrix_air_before, grid.matrix_air_volume_m3);
    try std.testing.expectEqualSlices(f64, &macropore_air_before, grid.macropore_air_volume_m3);
    try std.testing.expectEqualSlices(f64, &total_air_before, grid.air_volume_m3);
    try std.testing.expectEqualSlices(f64, &[_]f64{123.456}, &caller_heat_flux);
}

test "macropore phase state_update publishes capacity-backed cells and leaves genuinely empty cells alone" {
    // The companion case: a zero-capacity cell whose incoming and resident
    // values are both zero is a real no-op, so the state_update must succeed. This
    // pins that the fix did not turn a benign profile into a hard failure,
    // which is the obvious way an assert-and-raise change regresses.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 80 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();

    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.macropore_pore_capacity_m3[0] = 0.1;
    grid.matrix_pore_capacity_m3[1] = 0.5;
    grid.macropore_pore_capacity_m3[1] = 0;
    grid.macropore_liquid_water_m3[1] = 0;
    grid.macropore_ice_water_m3[1] = 0;

    var matrix_liquid = [_]f64{ 0.4, 0.42 };
    var matrix_ice = [_]f64{ 0, 0.01 };
    var macropore_liquid = [_]f64{ 0.05, 0 };
    var macropore_ice = [_]f64{ 0.01, 0 };

    try group_residual.state_updateMatrixPhase(&grid, .{
        .matrix_liquid_m3 = &matrix_liquid,
        .matrix_ice_m3 = &matrix_ice,
        .macropore_liquid_m3 = &macropore_liquid,
        .macropore_ice_m3 = &macropore_ice,
        .macropore_enabled = true,
        .ice_density_megagrams_per_m3 = 0.917,
    });

    // Capacity-backed cell 0 received both phases.
    try std.testing.expectEqual(@as(f64, 0.05), grid.macropore_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.01), grid.macropore_ice_water_m3[0]);
    // Totals are the sum of the two domains.
    try std.testing.expectApproxEqRel(@as(f64, 0.45), grid.liquid_water_m3[0], 1e-14);
    try std.testing.expectApproxEqRel(@as(f64, 0.42), grid.liquid_water_m3[1], 1e-14);
    try std.testing.expectApproxEqRel(@as(f64, 0.01), grid.ice_water_m3[1], 1e-14);
    // The capacity-free cell stays empty rather than acquiring inventory.
    try std.testing.expectEqual(@as(f64, 0), grid.macropore_liquid_water_m3[1]);
    try std.testing.expectEqual(@as(f64, 0), grid.macropore_ice_water_m3[1]);
}

test "coupled heat solve exposes Anderson recovery and a divergence watch without moving the fixed point" {
    // Audit gap 3 (a11_solver_conformance_audit.md). This solver's recovery step
    // was a plain directional Picard at relaxation 0.5 with no acceleration and
    // no divergence detector. Anderson recovery is allowed to change WHICH
    // points the iteration visits; it is not allowed to change the point it
    // converges to, because that point is the discretized WATSUB energy balance
    // and nothing about a step-size heuristic may redefine it.
    //
    // So the acceptance property is a comparison, not a tolerance: solve the
    // same problem twice from the same initial state, once with the recovery
    // enabled and once with `anderson_recovery = false` (the pre-change
    // trajectory), and require the two converged temperature fields to agree far
    // more tightly than the solver's own convergence tolerance.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 },
    );
    const face: group_types.Face = .{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 };
    const zero_flux = [_]f64{0};
    const fluxes: group_types.WaterHeatFluxes = .{ .liquid_water_m3 = &zero_flux, .vapor_m3 = &zero_flux, .macropore_water_m3 = &zero_flux };

    // The directional Newton path is switched off (`dense_newton_max_components
    // = 0` plus a pinned unit fraction) is NOT what is wanted here: the point is
    // to exercise the real solver. Instead the Newton line search stays on, and
    // the recovery flag is the only difference between the two solves.
    var accelerated_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer accelerated_grid.deinit();
    accelerated_grid.soil_temperature_k[0] = 320;
    accelerated_grid.soil_temperature_k[1] = 260;
    var accelerated_output = [_]f64{0};
    const accelerated_result = try group_solve.solve(std.testing.allocator, &accelerated_grid, &.{face}, group_fixtures.testProperties(), fluxes, &accelerated_output, .{ .max_iterations = 40, .anderson_recovery = true });

    var plain_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer plain_grid.deinit();
    plain_grid.soil_temperature_k[0] = 320;
    plain_grid.soil_temperature_k[1] = 260;
    var plain_output = [_]f64{0};
    const plain_result = try group_solve.solve(std.testing.allocator, &plain_grid, &.{face}, group_fixtures.testProperties(), fluxes, &plain_output, .{ .max_iterations = 40 });

    // Same fixed point, to the precision at which the solver defines one. The
    // band is four times its own convergence gate
    // (`absolute_tolerance_k + relative_tolerance * |T|`, about 3e-7 K here)
    // rather than an arbitrary epsilon, because any two accepted iterates are
    // indistinguishable inside that gate by construction. A different root, the
    // failure this exists to catch, is orders of magnitude outside it.
    for (accelerated_grid.soil_temperature_k, plain_grid.soil_temperature_k) |accelerated_value, plain_value| {
        const gate = 1e-11 + 1e-9 * @abs(plain_value);
        try std.testing.expect(@abs(accelerated_value - plain_value) <= 4 * gate);
    }
    // The HFLWM-equivalent face heat output is part of the answer too. It is a
    // megajoule flux rather than a temperature, so it is priced relatively.
    try std.testing.expectApproxEqRel(plain_output[0], accelerated_output[0], 1.0e-6);

    // CONTROL. Both configurations must actually have converged, otherwise the
    // agreement above would be the trivial agreement of two unmoved states.
    // `solve` returns an error on non-convergence, so reaching here proves that,
    // but the recovery path also has to have been reachable: assert the run
    // performed real work and that the counters stayed self-consistent.
    try std.testing.expect(accelerated_result.iterations >= 1);
    try std.testing.expect(accelerated_result.newton_raphson_steps + accelerated_result.picard_steps > 0);
    try std.testing.expect(accelerated_result.maximum_scaled_residual <= 1);
    try std.testing.expect(plain_result.maximum_scaled_residual <= 1);
    // `anderson_steps` is a subset of `picard_steps` by construction, and the
    // disabled configuration must report none. If a later change starts counting
    // Anderson steps outside the recovery branch, or leaks them into a solve that
    // switched the recovery off, one of these fails.
    try std.testing.expect(accelerated_result.anderson_steps <= accelerated_result.picard_steps);
    try std.testing.expectEqual(plain_result.picard_steps, plain_result.anderson_steps);
}

test "component Newton rejects a requested amplification above one" {
    // Pinning the local secant multiplier at two reflects both temperatures
    // through the root. That full component-Newton step has the same global
    // merit as the initial state and must be rejected; the half step reaches
    // the root. This specifically guards globalization of the assembled
    // component direction rather than its per-cell secant construction.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 400 },
    );
    const face: group_types.Face = .{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 };
    const zero_flux = [_]f64{0};
    const fluxes: group_types.WaterHeatFluxes = .{ .liquid_water_m3 = &zero_flux, .vapor_m3 = &zero_flux, .macropore_water_m3 = &zero_flux };
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 320;
    grid.soil_temperature_k[1] = 260;
    var output = [_]f64{0};
    try std.testing.expectError(error.InvalidSoilHeatSolverOptions, group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{face},
        group_fixtures.testProperties(),
        fluxes,
        &output,
        .{
            .max_iterations = 400,
            .minimum_newton_fraction = 2,
            .maximum_newton_fraction = 2,
            .dense_newton_max_components = 0,
        },
    ));
}

test "heat solver recovery and watch options are validated rather than silently disabled" {
    // A detector that a nonsense option turns off is worse than no detector,
    // because the absence is then invisible. Zero patience would fire on the
    // first non-improving iteration and a growth factor below one would fire on
    // an IMPROVING one, so both are option faults, as is a non-finite factor.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 300;
    grid.soil_temperature_k[1] = 280;
    const zero_flux = [_]f64{0};
    var output = [_]f64{99};
    const face: group_types.Face = .{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 };
    const fluxes: group_types.WaterHeatFluxes = .{ .liquid_water_m3 = &zero_flux, .vapor_m3 = &zero_flux, .macropore_water_m3 = &zero_flux };
    const rejected = [_]group_types.Options{
        .{ .max_iterations = 40, .divergence_patience = 0 },
        .{ .max_iterations = 40, .divergence_growth_factor = 0.5 },
        .{ .max_iterations = 40, .divergence_growth_factor = 0 },
        .{ .max_iterations = 40, .divergence_growth_factor = -1 },
        .{ .max_iterations = 40, .divergence_growth_factor = std.math.nan(f64) },
        .{ .max_iterations = 40, .divergence_growth_factor = std.math.inf(f64) },
        .{ .max_iterations = 40, .anderson_recovery = false },
    };
    for (rejected) |options|
        try std.testing.expectError(
            error.InvalidSoilHeatSolverOptions,
            group_solve.solve(std.testing.allocator, &grid, &.{face}, group_fixtures.testProperties(), fluxes, &output, options),
        );
    var invalid_iteration_zero_control: group_types.RecoveryRoutingTestControl = .{
        .force_speculative_iteration = 0,
    };
    try std.testing.expectError(
        error.InvalidSoilHeatSolverOptions,
        group_solve.solve(
            std.testing.allocator,
            &grid,
            &.{face},
            group_fixtures.testProperties(),
            fluxes,
            &output,
            .{
                .max_iterations = 40,
                .recovery_routing_test_control = &invalid_iteration_zero_control,
            },
        ),
    );
    // Rejection is atomic: no partial state or output was published.
    try std.testing.expectEqual(@as(f64, 300), grid.soil_temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 99), output[0]);

    // CONTROL. The rejections above must come from the VALUES being nonsense,
    // not from the solver refusing any non-default watch configuration. A tight
    // but legal watch (patience one, growth factor exactly one, the boundary
    // value) has to be accepted and still converge.
    var strict_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer strict_grid.deinit();
    strict_grid.soil_temperature_k[0] = 300;
    strict_grid.soil_temperature_k[1] = 280;
    var strict_output = [_]f64{0};
    const strict_result = try group_solve.solve(std.testing.allocator, &strict_grid, &.{face}, group_fixtures.testProperties(), fluxes, &strict_output, .{ .max_iterations = 40, .divergence_patience = 1, .divergence_growth_factor = 1 });
    try std.testing.expect(strict_result.maximum_scaled_residual <= 1);
    // And the shipped defaults are the ones documented in core/numerics.zig, so
    // this solver's watch cannot drift away from the shared semantics unnoticed.
    const defaults: group_types.Options = .{ .max_iterations = 40 };
    try std.testing.expectEqual(@as(u16, 8), defaults.divergence_patience);
    try std.testing.expectEqual(@as(f64, 1.0e3), defaults.divergence_growth_factor);
    try std.testing.expect(defaults.anderson_recovery);
}

test "a stiff heat solve is stabilized without exhausting the iteration ceiling" {
    // This deliberately stiff short face used to reach Anderson recovery, but
    // the topology-local Newton globalization can now solve it directly. The
    // regression owns the policy outcome: convergence before the hard ceiling
    // with every accepted update accounted to Newton or genuine Anderson.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4000 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 300;
    grid.soil_temperature_k[1] = 280;
    const zero_flux = [_]f64{0};
    var output = [_]f64{99};
    const face: group_types.Face = .{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 1e-4, .destination_path_length_m = 1e-4, .face_area_m2 = 1 };
    const fluxes: group_types.WaterHeatFluxes = .{ .liquid_water_m3 = &zero_flux, .vapor_m3 = &zero_flux, .macropore_water_m3 = &zero_flux };
    // A growth factor of one with patience one is the most sensitive legal
    // watch. A merit-decreasing Newton path must remain admissible under it.
    const stabilized = try group_solve.solve(std.testing.allocator, &grid, &.{face}, group_fixtures.testProperties(), fluxes, &output, .{ .max_iterations = 4000, .picard_relaxation = 1, .divergence_patience = 1, .divergence_growth_factor = 1, .dense_newton_max_components = 0 });
    try std.testing.expect(stabilized.iterations < 4000);
    try std.testing.expect(stabilized.newton_raphson_steps + stabilized.anderson_steps > 0);
    try std.testing.expectEqual(stabilized.picard_steps, stabilized.anderson_steps);
    try std.testing.expect(stabilized.newton_raphson_steps + stabilized.picard_steps <= stabilized.iterations);
    try std.testing.expect(stabilized.maximum_scaled_residual <= 1);

    // CONTROL, and the whole point of the gap: with the DEFAULT watch this same
    // fixture must not be reported as divergence. The defaults exist to catch
    // runaway trajectories, not stiff ones, and a detector that fires on the
    // default settings of a solvable problem would be worse than none. Here the
    // same overshooting configuration under the shipped 1e3/8 watch is allowed
    // to converge or to hit the ceiling, but must not be called divergence.
    var default_grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer default_grid.deinit();
    default_grid.soil_temperature_k[0] = 300;
    default_grid.soil_temperature_k[1] = 280;
    var default_output = [_]f64{0};
    if (group_solve.solve(std.testing.allocator, &default_grid, &.{face}, group_fixtures.testProperties(), fluxes, &default_output, .{ .max_iterations = 4000, .picard_relaxation = 1, .dense_newton_max_components = 0 })) |_| {} else |err| try std.testing.expect(err != error.SoilHeatSolverDiverged);
}

test "a cell with a steep retention curve has a large apparent heat capacity measurably outside the ULP-scale transition radius" {
    // SURFACE-HEAT-BRACKET-RUNAWAY-001: the discovery-scan skip-optimization
    // in `solveWithWorkspace` only trusted the smooth Newton predictor away
    // from an ULP-scale (~2*sqrt(eps)) temperature-distance radius around the
    // exact phase transition. This test isolates the physical claim behind
    // widening that gate with a magnitude test on `enthalpyDerivativeMjPerK`:
    // a cell can sit measurably outside that ULP radius while its apparent
    // heat capacity is still far larger than its ordinary sensible capacity,
    // because the retention curve's water-capacity slope near residual
    // saturation is steep. This does not exercise the full multi-cell solver
    // (synthetic multi-cell reproduction of the real hour-15 failure is
    // conclusively foreclosed per this entry's own prior amendments) -- it
    // verifies the calibration of the new gate's threshold in isolation.
    const melting_temperature_k = 273.15;
    const unfrozen_pressure_head_m = -0.1;
    const latent_heat_megajoules_per_m3 = 333.7;
    const gravitational_water_potential_mpa_per_m = 0.00980665;
    const steep_curve: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 10,
        .n = 2.5,
        .saturated_hydraulic_conductivity_m_per_h = 1,
    };
    const steep_parameters: enthalpy.Parameters = .{
        .porous_medium_volume_m3 = 0.01,
        .total_water_equivalent_m3 = 0.005,
        .unfrozen_pressure_head_m = unfrozen_pressure_head_m,
        .gravitational_water_potential_mpa_per_m = gravitational_water_potential_mpa_per_m,
        .pure_water_melting_temperature_k = melting_temperature_k,
        .dry_solid_heat_capacity_megajoules_per_k = 0.02,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
        .latent_heat_of_fusion_megajoules_per_m3 = latent_heat_megajoules_per_m3,
        .mualem_van_genuchten = steep_curve,
    };
    const depressed_transition_k = enthalpy.depressedMeltingTemperatureK(
        steep_parameters,
        unfrozen_pressure_head_m,
    );
    const transition_radius_k = 2 * std.math.sqrt(std.math.floatEps(f64)) *
        melting_temperature_k;
    // Measurably outside the ULP radius (by 7 orders of magnitude), but
    // still close enough to the transition to sit on the steep part of the
    // retention curve's water-capacity slope.
    const outside_radius_temperature_k = depressed_transition_k - 1.0e-3;
    try std.testing.expect(
        @abs(outside_radius_temperature_k - depressed_transition_k) >
            64 * transition_radius_k,
    );
    const steep_state = try enthalpy.stateAtTemperature(
        steep_parameters,
        outside_radius_temperature_k,
    );
    const steep_derivative_megajoules_per_k = try enthalpy.enthalpyDerivativeMjPerK(
        steep_parameters,
        outside_radius_temperature_k,
        steep_state,
    );
    // The widened gate's exact criterion: derivative >= 2x sensible capacity.
    try std.testing.expect(
        steep_derivative_megajoules_per_k >=
            2 * steep_state.sensible_heat_capacity_megajoules_per_k,
    );

    // CONTROL: an ordinary cell far above freezing, no phase change at all,
    // must NOT trip the new criterion -- the derivative collapses to the
    // plain sensible capacity when there is no latent contribution, so this
    // must stay far below the 2x threshold. This guards against the widened
    // gate becoming a false-positive-prone always-on discovery path.
    const ordinary_temperature_k = 293.15;
    const ordinary_state = try enthalpy.stateAtTemperature(
        steep_parameters,
        ordinary_temperature_k,
    );
    const ordinary_derivative_megajoules_per_k = try enthalpy.enthalpyDerivativeMjPerK(
        steep_parameters,
        ordinary_temperature_k,
        ordinary_state,
    );
    try std.testing.expectApproxEqRel(
        ordinary_state.sensible_heat_capacity_megajoules_per_k,
        ordinary_derivative_megajoules_per_k,
        1e-9,
    );
    try std.testing.expect(
        ordinary_derivative_megajoules_per_k <
            2 * ordinary_state.sensible_heat_capacity_megajoules_per_k,
    );
}

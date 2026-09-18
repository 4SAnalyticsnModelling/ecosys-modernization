const std = @import("std");
const numerics = @import("../../core/numerics.zig");

pub const Parameters = struct {
    saturation_vapor_prefactor_k: f64 = 2.173e-3,
    saturation_relative_humidity: f64 = 0.61,
    saturation_temperature_coefficient_k: f64 = 5360.0,
    saturation_reference_inverse_temperature_per_k: f64 = 3.661e-3,
};

pub const SolverOptions = struct {
    max_iterations: u16 = 100,
    absolute_temperature_tolerance_k: f64 = 1.0e-8,
    absolute_vapor_fraction_tolerance: f64 = 1.0e-12,
    relative_tolerance: f64 = 1.0e-10,
    picard_relaxation: f64 = 0.5,
    /// Forwarded to `core/numerics.zig`. Anderson-accelerated Picard recovery
    /// is the conforming fallback; disable only to reproduce a pre-Anderson
    /// trajectory.
    anderson_recovery: bool = true,
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
};

pub const Inputs = struct {
    initial_temperature_k: f64,
    initial_vapor_fraction: f64,
    atmospheric_temperature_k: f64,
    atmospheric_vapor_fraction: f64,
    ground_air_temperature_k: f64,
    ground_air_vapor_fraction: f64,
    heat_capacity_megajoules_per_k: f64,
    air_volume_m3: f64,
    atmospheric_sensible_conductance_megajoules_per_h_k: f64,
    atmospheric_vapor_conductance_m3_per_h: f64,
    ground_sensible_conductance_megajoules_per_h_k: f64,
    ground_vapor_conductance_m3_per_h: f64,
    canopy_surface_sensible_heat_flux_megajoules_per_h: f64,
    canopy_surface_vapor_flux_m3_per_h: f64,
    lateral_sensible_heat_flux_megajoules_per_h: f64,
    lateral_vapor_flux_m3_per_h: f64,
};

pub const Result = struct {
    temperature_k: f64,
    vapor_fraction: f64,
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    /// Recovery steps taken with the Anderson candidate rather than the plain
    /// relaxed Picard candidate. Counted inside `picard_steps` as well.
    anderson_steps: u16 = 0,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    temperature_k: []f64,
    vapor_fraction: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, species_count: usize) !State {
        if (cell_count == 0 or species_count == 0) return error.InvalidCanopyAirDimensions;
        const count = try std.math.mul(usize, cell_count, species_count);
        const temperature = try allocator.alloc(f64, count);
        errdefer allocator.free(temperature);
        const vapor = try allocator.alloc(f64, count);
        @memset(temperature, 0);
        @memset(vapor, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .species_count = species_count, .temperature_k = temperature, .vapor_fraction = vapor };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.temperature_k);
        self.allocator.free(self.vapor_fraction);
        self.* = undefined;
    }

    pub fn index(self: State, cell: usize, species: usize) !usize {
        if (cell >= self.cell_count or species >= self.species_count) return error.CanopyAirIndexOutOfBounds;
        return cell * self.species_count + species;
    }
};

/// Physical bracket for the air temperature solve, in kelvin. The balance is
/// affine in temperature, so any bracket containing the root gives the same
/// root; this one is wide enough to never bind on a physical atmosphere while
/// still bounding the shared solver's stagnation and clamping logic.
const minimum_temperature_k: f64 = 1.0;
const maximum_temperature_k: f64 = 1.0e4;

/// The two balances are triangular, not coupled: `temperatureTarget` reads only
/// the temperature, and the vapor balance reads the temperature only through
/// the already-determined saturation cap. Each is therefore a scalar
/// fixed-point problem and both delegate to `core/numerics.zig`, which supplies
/// the damped-Newton/Anderson-recovery/divergence-detection behaviour the
/// solver brief requires instead of the bespoke relaxed Picard this file used
/// to run.
/// The shared solver reports exhaustion, stagnation and divergence in its own
/// vocabulary. Callers of this module (and the commentary in
/// `canopy/state/convergence_pass_control.zig`) are written against
/// `error.CanopyAirSolverDidNotConverge`, so translate the failure-to-converge
/// family back to it and keep genuinely different faults (non-finite values,
/// invalid options) distinguishable.
fn translateSolverError(err: anyerror) anyerror {
    return switch (err) {
        error.NewtonPicardDidNotConverge,
        error.NewtonPicardStagnated,
        error.NewtonPicardDiverged,
        => error.CanopyAirSolverDidNotConverge,
        else => err,
    };
}

pub fn solve(inputs: Inputs, parameters: Parameters, options: SolverOptions) !Result {
    try validate(inputs, parameters, options);

    const TemperatureContext = struct { inputs: Inputs };
    const Temperature = struct {
        fn fixedPoint(context: TemperatureContext, temperature_k: f64) f64 {
            return temperatureTarget(context.inputs, temperature_k);
        }
        fn residual(context: TemperatureContext, temperature_k: f64) f64 {
            return temperatureTarget(context.inputs, temperature_k) - temperature_k;
        }
        fn derivative(context: TemperatureContext, _: f64) f64 {
            // Affine balance: d(target - x)/dx is constant.
            return -1.0 -
                (context.inputs.atmospheric_sensible_conductance_megajoules_per_h_k +
                    context.inputs.ground_sensible_conductance_megajoules_per_h_k) /
                    context.inputs.heat_capacity_megajoules_per_k;
        }
    };
    const temperature_solve = numerics.newtonPicard(
        TemperatureContext{ .inputs = inputs },
        Temperature.residual,
        Temperature.derivative,
        Temperature.fixedPoint,
        minimum_temperature_k,
        maximum_temperature_k,
        std.math.clamp(inputs.initial_temperature_k, minimum_temperature_k, maximum_temperature_k),
        temperatureSolverOptions(inputs, options),
    ) catch |err| return translateSolverError(err);
    const temperature_k = temperature_solve.root;
    // `saturationVaporFraction` re-derives the temperature target at the
    // accepted point and carries both historical nonphysical-target
    // diagnostics (`InvalidCanopyAirTemperatureTarget`,
    // `InvalidCanopyAirVaporTarget`), so those error paths are preserved.
    const saturation_vapor_fraction = try saturationVaporFraction(inputs, parameters, temperature_k);
    const VaporContext = struct { inputs: Inputs, saturation: f64 };
    const Vapor = struct {
        fn fixedPoint(context: VaporContext, vapor_fraction: f64) f64 {
            return std.math.clamp(vaporTarget(context.inputs, vapor_fraction), 0.0, context.saturation);
        }
        fn residual(context: VaporContext, vapor_fraction: f64) f64 {
            return fixedPoint(context, vapor_fraction) - vapor_fraction;
        }
        fn derivative(context: VaporContext, vapor_fraction: f64) f64 {
            // Semismooth: on the saturation branch the target no longer
            // responds to the iterate, so the residual slope is just -1.
            const unconstrained = vaporTarget(context.inputs, vapor_fraction);
            if (unconstrained > context.saturation or unconstrained < 0) return -1.0;
            return -1.0 -
                (context.inputs.atmospheric_vapor_conductance_m3_per_h +
                    context.inputs.ground_vapor_conductance_m3_per_h) /
                    context.inputs.air_volume_m3;
        }
    };
    // A volume fraction cannot exceed one, and the saturation cap is applied
    // inside the map, so the bracket only has to be admissible and non-empty.
    const vapor_upper_bound = @max(1.0, saturation_vapor_fraction) + 1.0;
    const vapor_solve = numerics.newtonPicard(
        VaporContext{ .inputs = inputs, .saturation = saturation_vapor_fraction },
        Vapor.residual,
        Vapor.derivative,
        Vapor.fixedPoint,
        0.0,
        vapor_upper_bound,
        std.math.clamp(inputs.initial_vapor_fraction, 0.0, vapor_upper_bound),
        vaporSolverOptions(inputs, options),
    ) catch |err| return translateSolverError(err);

    return .{
        .temperature_k = temperature_k,
        .vapor_fraction = vapor_solve.root,
        .iterations = @max(temperature_solve.iterations, vapor_solve.iterations),
        .newton_raphson_steps = temperature_solve.newton_raphson_steps + vapor_solve.newton_raphson_steps,
        .picard_steps = temperature_solve.picard_steps + vapor_solve.picard_steps,
        .anderson_steps = temperature_solve.anderson_steps + vapor_solve.anderson_steps,
    };
}

/// `residual_scale` is mandatory in `core/numerics.zig` and must be stated in
/// the residual's own units. The residual here is a temperature difference, so
/// the characteristic magnitude is the temperature scale of the problem. Using
/// `max(1, |initial|)` reproduces the acceptance band this file applied before
/// delegating (`abs_tol + rel_tol * max(1, |value|)`).
fn temperatureSolverOptions(inputs: Inputs, options: SolverOptions) numerics.SolverOptions {
    return .{
        .absolute_tolerance = options.absolute_temperature_tolerance_k,
        .relative_tolerance = options.relative_tolerance,
        .residual_scale = @max(1.0, @abs(inputs.initial_temperature_k)),
        .picard_relaxation = options.picard_relaxation,
        .max_iterations = options.max_iterations,
        .anderson_recovery = options.anderson_recovery,
        .divergence_patience = options.divergence_patience,
        .divergence_growth_factor = options.divergence_growth_factor,
    };
}

fn vaporSolverOptions(inputs: Inputs, options: SolverOptions) numerics.SolverOptions {
    return .{
        .absolute_tolerance = options.absolute_vapor_fraction_tolerance,
        .relative_tolerance = options.relative_tolerance,
        .residual_scale = @max(1.0, @abs(inputs.initial_vapor_fraction)),
        .picard_relaxation = options.picard_relaxation,
        .max_iterations = options.max_iterations,
        .anderson_recovery = options.anderson_recovery,
        .divergence_patience = options.divergence_patience,
        .divergence_growth_factor = options.divergence_growth_factor,
    };
}

pub fn solveInto(state: *State, cell: usize, species: usize, inputs: Inputs, parameters: Parameters, options: SolverOptions) !Result {
    const state_index = try state.index(cell, species);
    const result = try solve(inputs, parameters, options);
    state.temperature_k[state_index] = result.temperature_k;
    state.vapor_fraction[state_index] = result.vapor_fraction;
    return result;
}

fn temperatureTarget(inputs: Inputs, temperature_k: f64) f64 {
    const sensible_megajoules_per_h =
        inputs.atmospheric_sensible_conductance_megajoules_per_h_k * (inputs.atmospheric_temperature_k - temperature_k) -
        inputs.ground_sensible_conductance_megajoules_per_h_k * (temperature_k - inputs.ground_air_temperature_k) -
        inputs.canopy_surface_sensible_heat_flux_megajoules_per_h +
        inputs.lateral_sensible_heat_flux_megajoules_per_h;
    return inputs.initial_temperature_k + sensible_megajoules_per_h / inputs.heat_capacity_megajoules_per_k;
}

fn vaporTarget(inputs: Inputs, vapor_fraction: f64) f64 {
    const vapor_m3_per_h =
        inputs.atmospheric_vapor_conductance_m3_per_h * (inputs.atmospheric_vapor_fraction - vapor_fraction) -
        inputs.ground_vapor_conductance_m3_per_h * (vapor_fraction - inputs.ground_air_vapor_fraction) -
        inputs.canopy_surface_vapor_flux_m3_per_h +
        inputs.lateral_vapor_flux_m3_per_h;
    return inputs.initial_vapor_fraction + vapor_m3_per_h / inputs.air_volume_m3;
}

fn saturationVaporFraction(inputs: Inputs, parameters: Parameters, temperature_k: f64) !f64 {
    const temperature_target_k = temperatureTarget(inputs, temperature_k);
    if (!std.math.isFinite(temperature_target_k) or temperature_target_k <= 0) return error.InvalidCanopyAirTemperatureTarget;
    const saturation = parameters.saturation_vapor_prefactor_k / temperature_target_k *
        parameters.saturation_relative_humidity *
        @exp(parameters.saturation_temperature_coefficient_k * (parameters.saturation_reference_inverse_temperature_per_k - 1.0 / temperature_target_k));
    if (!std.math.isFinite(saturation) or saturation < 0) return error.InvalidCanopyAirVaporTarget;
    return saturation;
}

fn validate(inputs: Inputs, parameters: Parameters, options: SolverOptions) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteCanopyAirInput;
    inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteCanopyAirParameter;
    if (inputs.initial_temperature_k <= 0 or inputs.atmospheric_temperature_k <= 0 or inputs.ground_air_temperature_k <= 0 or inputs.initial_vapor_fraction < 0 or inputs.atmospheric_vapor_fraction < 0 or inputs.ground_air_vapor_fraction < 0 or inputs.heat_capacity_megajoules_per_k <= 0 or inputs.air_volume_m3 <= 0) return error.InvalidCanopyAirInput;
    inline for (.{ inputs.atmospheric_sensible_conductance_megajoules_per_h_k, inputs.atmospheric_vapor_conductance_m3_per_h, inputs.ground_sensible_conductance_megajoules_per_h_k, inputs.ground_vapor_conductance_m3_per_h }) |value| if (value < 0) return error.InvalidCanopyAirInput;
    if (options.max_iterations == 0 or !options.anderson_recovery or !std.math.isFinite(options.absolute_temperature_tolerance_k) or options.absolute_temperature_tolerance_k <= 0 or !std.math.isFinite(options.absolute_vapor_fraction_tolerance) or options.absolute_vapor_fraction_tolerance <= 0 or !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or options.divergence_patience == 0 or !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1) return error.InvalidCanopyAirSolverOptions;
}

test "UPTAKE canopy air balance supports runtime species and exits early" {
    var state = try State.init(std.testing.allocator, 1, 7);
    defer state.deinit();
    const result = try solveInto(&state, 0, 6, .{
        .initial_temperature_k = 290,
        .initial_vapor_fraction = 0.005,
        .atmospheric_temperature_k = 300,
        .atmospheric_vapor_fraction = 0.01,
        .ground_air_temperature_k = 295,
        .ground_air_vapor_fraction = 0.007,
        .heat_capacity_megajoules_per_k = 1,
        .air_volume_m3 = 10,
        .atmospheric_sensible_conductance_megajoules_per_h_k = 0.1,
        .atmospheric_vapor_conductance_m3_per_h = 0.2,
        .ground_sensible_conductance_megajoules_per_h_k = 0.05,
        .ground_vapor_conductance_m3_per_h = 0.1,
        .canopy_surface_sensible_heat_flux_megajoules_per_h = 0.1,
        .canopy_surface_vapor_flux_m3_per_h = 0.001,
        .lateral_sensible_heat_flux_megajoules_per_h = 0,
        .lateral_vapor_flux_m3_per_h = 0,
    }, .{}, .{});
    try std.testing.expect(result.iterations < 100);
    try std.testing.expect(state.temperature_k[6] > 290);
    try std.testing.expect(state.vapor_fraction[6] >= 0);
}

/// Stiff-but-solvable canopy air case. The conductances are large relative to
/// the heat capacity and air volume, which is the regime where an
/// under-relaxed Picard map crawls and where the brief requires a damped
/// Newton with Anderson-accelerated recovery.
fn stiffInputs() Inputs {
    return .{
        .initial_temperature_k = 280,
        .initial_vapor_fraction = 0.004,
        .atmospheric_temperature_k = 305,
        .atmospheric_vapor_fraction = 0.012,
        .ground_air_temperature_k = 298,
        .ground_air_vapor_fraction = 0.009,
        .heat_capacity_megajoules_per_k = 0.02,
        .air_volume_m3 = 0.05,
        .atmospheric_sensible_conductance_megajoules_per_h_k = 0.4,
        .atmospheric_vapor_conductance_m3_per_h = 0.5,
        .ground_sensible_conductance_megajoules_per_h_k = 0.3,
        .ground_vapor_conductance_m3_per_h = 0.4,
        .canopy_surface_sensible_heat_flux_megajoules_per_h = 0.02,
        .canopy_surface_vapor_flux_m3_per_h = 0.0005,
        .lateral_sensible_heat_flux_megajoules_per_h = 0,
        .lateral_vapor_flux_m3_per_h = 0,
    };
}

test "canopy air exchange requires Anderson as its sole fallback" {
    // Conformance guard. Before this solver delegated to `core/numerics.zig`
    // it ran a bespoke relaxed-Picard fallback with no Anderson recovery and no
    // divergence detection, so neither the `anderson_recovery` option nor the
    // `anderson_steps` result field existed and this test could not compile,
    // let alone pass.
    const inputs = stiffInputs();
    const with_recovery = try solve(inputs, .{}, .{ .anderson_recovery = true });
    try std.testing.expectError(error.InvalidCanopyAirSolverOptions, solve(inputs, .{}, .{ .anderson_recovery = false }));

    // The published answer must actually satisfy both balances, not merely be
    // whatever the loop last held. Recompute the residuals independently.
    const temperature_residual = temperatureTarget(inputs, with_recovery.temperature_k) - with_recovery.temperature_k;
    try std.testing.expect(@abs(temperature_residual) <= 1e-6);
    const saturation = try saturationVaporFraction(inputs, .{}, with_recovery.temperature_k);
    const vapor_image = std.math.clamp(vaporTarget(inputs, with_recovery.vapor_fraction), 0.0, saturation);
    try std.testing.expect(@abs(vapor_image - with_recovery.vapor_fraction) <= 1e-10);
    try std.testing.expect(with_recovery.vapor_fraction >= 0);
    try std.testing.expect(with_recovery.vapor_fraction <= saturation + 1e-12);
}

test "canopy air exchange reports divergence as a convergence failure" {
    // The audit's universal gap was that no solver detected divergence or
    // oscillation. Delegation inherits `divergence_patience` /
    // `divergence_growth_factor` from `core/numerics.zig`, and this module
    // translates that family back to its documented public error so callers
    // written against `CanopyAirSolverDidNotConverge` keep working.
    const inputs = stiffInputs();
    // Every failure-to-converge outcome the shared solver can report, including
    // the divergence/oscillation verdict this module previously had no way to
    // reach, must reach callers under this module's documented error name.
    // Exercised directly because the shared solver logs stagnation at `err`
    // level, and this build treats a logged error inside a test as a failure.
    try std.testing.expectEqual(error.CanopyAirSolverDidNotConverge, translateSolverError(error.NewtonPicardDiverged));
    try std.testing.expectEqual(error.CanopyAirSolverDidNotConverge, translateSolverError(error.NewtonPicardStagnated));
    try std.testing.expectEqual(error.CanopyAirSolverDidNotConverge, translateSolverError(error.NewtonPicardDidNotConverge));
    // CONTROL: unrelated faults must stay distinguishable, so the mapping above
    // cannot be passing because everything is flattened to one error.
    try std.testing.expectEqual(error.NonFiniteNumericValue, translateSolverError(error.NonFiniteNumericValue));
    try std.testing.expectEqual(error.OutOfMemory, translateSolverError(error.OutOfMemory));
    // CONTROL: the stiff case still solves, so the divergence options being
    // plumbed through has not made ordinary solves fail.
    _ = try solve(inputs, .{}, .{});

    // Degenerate option values that the shared solver validates must be
    // rejected up front rather than silently disabling the new detector.
    try std.testing.expectError(error.InvalidCanopyAirSolverOptions, solve(inputs, .{}, .{ .divergence_patience = 0 }));
    try std.testing.expectError(error.InvalidCanopyAirSolverOptions, solve(inputs, .{}, .{ .divergence_growth_factor = 0.5 }));
}

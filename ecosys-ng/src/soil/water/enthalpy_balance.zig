const std = @import("std");
const numerics = @import("../../core/numerics.zig");
const phase_change = @import("phase_change.zig");
const retention = @import("retention.zig");

pub const SecondaryDomain = struct {
    porous_medium_volume_m3: f64,
    total_water_equivalent_m3: f64,
    unfrozen_pressure_head_m: f64,
    mualem_van_genuchten: retention.MualemVanGenuchtenParameters,
};

pub const Parameters = struct {
    porous_medium_volume_m3: f64,
    total_water_equivalent_m3: f64,
    unfrozen_pressure_head_m: f64,
    gravitational_water_potential_mpa_per_m: f64,
    pure_water_melting_temperature_k: f64,
    dry_solid_heat_capacity_megajoules_per_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_water_equivalent_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    mualem_van_genuchten: retention.MualemVanGenuchtenParameters,
    secondary_domain: ?SecondaryDomain = null,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| {
            if (field.type == f64 and !std.math.isFinite(@field(self, field.name)))
                return error.NonFiniteSoilEnthalpyParameter;
        }
        if (self.porous_medium_volume_m3 <= 0 or
            self.total_water_equivalent_m3 < 0 or
            self.unfrozen_pressure_head_m > 0 or
            self.gravitational_water_potential_mpa_per_m <= 0 or
            self.pure_water_melting_temperature_k <= 0 or
            self.dry_solid_heat_capacity_megajoules_per_k < 0 or
            self.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or
            self.ice_water_equivalent_heat_capacity_megajoules_per_m3_k <= 0 or
            self.latent_heat_of_fusion_megajoules_per_m3 <= 0)
            return error.InvalidSoilEnthalpyParameter;
        try self.mualem_van_genuchten.validate();
        if (self.secondary_domain) |secondary| {
            inline for (@typeInfo(SecondaryDomain).@"struct".fields) |field| {
                if (field.type == f64 and
                    !std.math.isFinite(@field(secondary, field.name)))
                    return error.NonFiniteSoilEnthalpyParameter;
            }
            if (secondary.porous_medium_volume_m3 <= 0 or
                secondary.total_water_equivalent_m3 < 0 or
                secondary.unfrozen_pressure_head_m > 0)
                return error.InvalidSoilEnthalpyParameter;
            try secondary.mualem_van_genuchten.validate();
        }
    }
};

pub const State = struct {
    temperature_k: f64,
    liquid_water_m3: f64,
    ice_water_equivalent_m3: f64,
    secondary_liquid_water_m3: f64,
    secondary_ice_water_equivalent_m3: f64,
    sensible_heat_capacity_megajoules_per_k: f64,
    enthalpy_megajoules: f64,
};

pub const SolverOptions = struct {
    /// User hard ceiling inherited from the owning heat solve.
    max_iterations: u16,
    /// Optional constitutive-method ceiling. Each cell owns an independent
    /// budget of `min(local_iteration_limit, max_iterations)`; it never
    /// consumes a coupled state-promotion budget from another cell.
    local_iteration_limit: u16 = std.math.maxInt(u16),
    absolute_enthalpy_tolerance_megajoules: f64 = 1.0e-12,
    relative_enthalpy_tolerance: f64 = 1.0e-10,
    /// Backtracking probes for Newton/Anderson globalization. Saturated soil
    /// has a sharp enthalpy-slope change at melting and can require a fraction
    /// below 1/2048; probes do not consume the nonlinear-iteration ceiling.
    max_line_search_steps: u8 = 24,
    minimum_temperature_k: f64 = 173.15,
    maximum_temperature_k: f64 = 373.15,
    initial_temperature_k: ?f64 = null,
    /// Physical-acceptance goal (2026-09-04): opt-in escape from chasing
    /// `absolute_enthalpy_tolerance_megajoules`/`relative_enthalpy_tolerance`
    /// (as tight as 1e-12 MJ / 1e-10 relative in production) all the way to
    /// the iteration ceiling. `null` (the default) preserves today's
    /// behavior exactly. When set, a ceiling failure is accepted instead of
    /// propagated if the residual energy error, expressed as the
    /// temperature perturbation it would cause through the cell's own
    /// sensible heat capacity, is already below this threshold -- a
    /// physically interpretable quantity, unlike a raw megajoule residual.
    physical_acceptance_temperature_tolerance_k: ?f64 = null,
};

pub const SolverResult = struct {
    state: State,
    iterations: u16,
    attempted_nonlinear_iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    anderson_recovery_steps: u16 = 0,
};

/// Conservative cell enthalpy relative to solid ice at the pure-water
/// melting temperature. The Dall'Amico liquid/ice partition is evaluated at
/// the trial temperature, so latent and sensible energy share one coordinate.
pub fn stateAtTemperature(parameters: Parameters, temperature_k: f64) !State {
    try parameters.validate();
    if (!std.math.isFinite(temperature_k) or temperature_k <= 0)
        return error.InvalidSoilEnthalpyTemperature;
    const equilibrium = try phase_change.dallAmicoEquilibrium(.{
        .temperature_k = temperature_k,
        .total_water_equivalent_m3 = parameters.total_water_equivalent_m3,
        .porous_medium_volume_m3 = parameters.porous_medium_volume_m3,
        .unfrozen_pressure_head_m = parameters.unfrozen_pressure_head_m,
        .gravitational_water_potential_mpa_per_m = parameters.gravitational_water_potential_mpa_per_m,
        .latent_heat_of_fusion_megajoules_per_m3 = parameters.latent_heat_of_fusion_megajoules_per_m3,
        .pure_water_melting_temperature_k = parameters.pure_water_melting_temperature_k,
        .mualem_van_genuchten = parameters.mualem_van_genuchten,
    });
    const secondary_equilibrium =
        if (parameters.secondary_domain) |secondary|
            try phase_change.dallAmicoEquilibrium(.{
                .temperature_k = temperature_k,
                .total_water_equivalent_m3 = secondary.total_water_equivalent_m3,
                .porous_medium_volume_m3 = secondary.porous_medium_volume_m3,
                .unfrozen_pressure_head_m = secondary.unfrozen_pressure_head_m,
                .gravitational_water_potential_mpa_per_m = parameters.gravitational_water_potential_mpa_per_m,
                .latent_heat_of_fusion_megajoules_per_m3 = parameters.latent_heat_of_fusion_megajoules_per_m3,
                .pure_water_melting_temperature_k = parameters.pure_water_melting_temperature_k,
                .mualem_van_genuchten = secondary.mualem_van_genuchten,
            })
        else
            null;
    const secondary_liquid_water_m3 =
        if (secondary_equilibrium) |state| state.liquid_water_m3 else 0;
    const secondary_ice_water_equivalent_m3 =
        if (secondary_equilibrium) |state|
            state.ice_water_equivalent_m3
        else
            0;
    const heat_capacity_megajoules_per_k =
        parameters.dry_solid_heat_capacity_megajoules_per_k +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
            (equilibrium.liquid_water_m3 +
                secondary_liquid_water_m3) +
        parameters.ice_water_equivalent_heat_capacity_megajoules_per_m3_k *
            (equilibrium.ice_water_equivalent_m3 +
                secondary_ice_water_equivalent_m3);
    const enthalpy_megajoules =
        heat_capacity_megajoules_per_k *
        (temperature_k - parameters.pure_water_melting_temperature_k) +
        parameters.latent_heat_of_fusion_megajoules_per_m3 *
            (equilibrium.liquid_water_m3 +
                secondary_liquid_water_m3);
    if (!std.math.isFinite(heat_capacity_megajoules_per_k) or
        heat_capacity_megajoules_per_k <= 0 or
        !std.math.isFinite(enthalpy_megajoules))
        return error.NonFiniteSoilEnthalpyState;
    return .{
        .temperature_k = temperature_k,
        .liquid_water_m3 = equilibrium.liquid_water_m3,
        .ice_water_equivalent_m3 = equilibrium.ice_water_equivalent_m3,
        .secondary_liquid_water_m3 = secondary_liquid_water_m3,
        .secondary_ice_water_equivalent_m3 = secondary_ice_water_equivalent_m3,
        .sensible_heat_capacity_megajoules_per_k = heat_capacity_megajoules_per_k,
        .enthalpy_megajoules = enthalpy_megajoules,
    };
}

pub fn enthalpyDerivativeMjPerK(
    parameters: Parameters,
    temperature_k: f64,
    state: State,
) !f64 {
    const pressure_head_change_m_per_k =
        parameters.latent_heat_of_fusion_megajoules_per_m3 /
        (parameters.gravitational_water_potential_mpa_per_m *
            temperature_k);
    var liquid_water_change_m3_per_k: f64 = 0;
    if (state.ice_water_equivalent_m3 > 0 and
        temperature_k < depressedMeltingTemperatureK(
            parameters,
            parameters.unfrozen_pressure_head_m,
        ))
    {
        liquid_water_change_m3_per_k +=
            parameters.porous_medium_volume_m3 *
            try parameters.mualem_van_genuchten.waterCapacityPerM(
                frozenPressureHeadM(
                    parameters,
                    parameters.unfrozen_pressure_head_m,
                    temperature_k,
                ),
            ) *
            pressure_head_change_m_per_k;
    }
    if (parameters.secondary_domain) |secondary| {
        const secondary_melting_temperature_k =
            depressedMeltingTemperatureK(
                parameters,
                secondary.unfrozen_pressure_head_m,
            );
        if (state.secondary_ice_water_equivalent_m3 > 0 and
            temperature_k < secondary_melting_temperature_k)
        {
            liquid_water_change_m3_per_k +=
                secondary.porous_medium_volume_m3 *
                try secondary.mualem_van_genuchten.waterCapacityPerM(
                    frozenPressureHeadM(
                        parameters,
                        secondary.unfrozen_pressure_head_m,
                        temperature_k,
                    ),
                ) *
                parameters.latent_heat_of_fusion_megajoules_per_m3 /
                (parameters.gravitational_water_potential_mpa_per_m *
                    temperature_k);
        }
    }
    const heat_capacity_change_megajoules_per_k2 =
        (parameters.liquid_water_heat_capacity_megajoules_per_m3_k -
            parameters.ice_water_equivalent_heat_capacity_megajoules_per_m3_k) *
        liquid_water_change_m3_per_k;
    const derivative_megajoules_per_k =
        state.sensible_heat_capacity_megajoules_per_k +
        heat_capacity_change_megajoules_per_k2 *
            (temperature_k - parameters.pure_water_melting_temperature_k) +
        parameters.latent_heat_of_fusion_megajoules_per_m3 *
            liquid_water_change_m3_per_k;
    if (!std.math.isFinite(derivative_megajoules_per_k) or derivative_megajoules_per_k <= 0)
        return error.NonFiniteSoilEnthalpyDerivative;
    return derivative_megajoules_per_k;
}

/// Dall'Amico/Clapeyron transition for a domain's unfrozen matric head.
/// Public so coupled solvers can classify the actual cell/domain kink rather
/// than assuming the pure-water melting point.
pub fn depressedMeltingTemperatureK(
    parameters: Parameters,
    unfrozen_pressure_head_m: f64,
) f64 {
    const exponent =
        parameters.gravitational_water_potential_mpa_per_m *
        unfrozen_pressure_head_m /
        parameters.latent_heat_of_fusion_megajoules_per_m3;
    const minimum_exponent =
        @log(std.math.floatMin(f64)) -
        @log(parameters.pure_water_melting_temperature_k);
    return parameters.pure_water_melting_temperature_k *
        @exp(@max(minimum_exponent, exponent));
}

fn frozenPressureHeadM(
    parameters: Parameters,
    unfrozen_pressure_head_m: f64,
    temperature_k: f64,
) f64 {
    const melting_temperature_k =
        depressedMeltingTemperatureK(parameters, unfrozen_pressure_head_m);
    return if (temperature_k < melting_temperature_k)
        unfrozen_pressure_head_m +
            parameters.latent_heat_of_fusion_megajoules_per_m3 /
                parameters.gravitational_water_potential_mpa_per_m *
                std.math.log1p(
                    (temperature_k - melting_temperature_k) /
                        melting_temperature_k,
                )
    else
        unfrozen_pressure_head_m;
}

const EnthalpyRootContext = struct {
    parameters: Parameters,
    target_enthalpy_megajoules: f64,
};

fn enthalpyResidual(context: *const EnthalpyRootContext, temperature_k: f64) f64 {
    const state = stateAtTemperature(context.parameters, temperature_k) catch return std.math.nan(f64);
    return state.enthalpy_megajoules - context.target_enthalpy_megajoules;
}

fn enthalpyDerivative(context: *const EnthalpyRootContext, temperature_k: f64) f64 {
    const state = stateAtTemperature(context.parameters, temperature_k) catch return std.math.nan(f64);
    return enthalpyDerivativeMjPerK(context.parameters, temperature_k, state) catch std.math.nan(f64);
}

fn enthalpyPicardImage(context: *const EnthalpyRootContext, temperature_k: f64) f64 {
    const state = stateAtTemperature(context.parameters, temperature_k) catch return std.math.nan(f64);
    // Sensible heat capacity supplies a physical fixed-point scale. The image
    // is evaluated only as an Anderson seed and is never committed directly.
    const capacity = @max(state.sensible_heat_capacity_megajoules_per_k, std.math.floatMin(f64));
    return temperature_k - (state.enthalpy_megajoules - context.target_enthalpy_megajoules) / capacity;
}

/// Safeguarded Newton/Anderson inversion used by the coupled spatial
/// heat residual. The runtime iteration ceiling is a convergence limit, not
/// a number of phase or full-model substeps.
pub fn temperatureFromEnthalpy(
    parameters: Parameters,
    target_enthalpy_megajoules: f64,
    options: SolverOptions,
) !SolverResult {
    try parameters.validate();
    if (!std.math.isFinite(target_enthalpy_megajoules))
        return error.NonFiniteSoilEnthalpyTarget;
    if (options.max_iterations == 0 or
        options.local_iteration_limit == 0 or
        options.max_line_search_steps == 0 or
        !std.math.isFinite(options.absolute_enthalpy_tolerance_megajoules) or
        options.absolute_enthalpy_tolerance_megajoules <= 0 or
        !std.math.isFinite(options.relative_enthalpy_tolerance) or
        options.relative_enthalpy_tolerance <= 0 or
        !std.math.isFinite(options.minimum_temperature_k) or
        !std.math.isFinite(options.maximum_temperature_k) or
        options.minimum_temperature_k <= 0 or
        options.maximum_temperature_k <= options.minimum_temperature_k)
        return error.InvalidSoilEnthalpySolverOption;
    if (options.initial_temperature_k) |initial_temperature_k|
        if (!std.math.isFinite(initial_temperature_k) or
            initial_temperature_k < options.minimum_temperature_k or
            initial_temperature_k > options.maximum_temperature_k)
            return error.InvalidSoilEnthalpySolverOption;
    const lower_temperature_k = options.minimum_temperature_k;
    const upper_temperature_k = options.maximum_temperature_k;
    const lower_state = try stateAtTemperature(parameters, lower_temperature_k);
    const upper_state = try stateAtTemperature(parameters, upper_temperature_k);
    if (target_enthalpy_megajoules < lower_state.enthalpy_megajoules or
        target_enthalpy_megajoules > upper_state.enthalpy_megajoules)
        return error.SoilEnthalpyTargetOutsideTemperatureBracket;
    const temperature_k = options.initial_temperature_k orelse
        lower_temperature_k +
            (upper_temperature_k - lower_temperature_k) *
                (target_enthalpy_megajoules - lower_state.enthalpy_megajoules) /
                (upper_state.enthalpy_megajoules - lower_state.enthalpy_megajoules);
    const context: EnthalpyRootContext = .{ .parameters = parameters, .target_enthalpy_megajoules = target_enthalpy_megajoules };
    var local_budget = try numerics.NonlinearBudget.init(options.max_iterations);
    const local_iteration_cap = try local_budget.localIterationCap(
        options.local_iteration_limit,
    );
    var last_iterate: numerics.SolveResult = undefined;
    const solved = numerics.newtonPicard(
        &context,
        enthalpyResidual,
        enthalpyDerivative,
        enthalpyPicardImage,
        lower_temperature_k,
        upper_temperature_k,
        temperature_k,
        .{
            .max_iterations = local_iteration_cap,
            .absolute_tolerance = options.absolute_enthalpy_tolerance_megajoules,
            .relative_tolerance = options.relative_enthalpy_tolerance,
            .residual_scale = @max(1.0, @abs(target_enthalpy_megajoules)),
            .safeguard_with_bracket = true,
            .accept_nearest_representable_root = true,
            .max_line_search_steps = options.max_line_search_steps,
            .shared_budget = &local_budget,
            .last_iterate_on_failure = if (options.physical_acceptance_temperature_tolerance_k != null) &last_iterate else null,
        },
    ) catch |err| switch (err) {
        error.NewtonPicardDiverged, error.NewtonPicardStagnated, error.NewtonPicardDidNotConverge => acceptance: {
            const acceptance_tolerance_k = options.physical_acceptance_temperature_tolerance_k orelse return err;
            const candidate_state = stateAtTemperature(parameters, last_iterate.root) catch return err;
            const candidate_residual_megajoules = candidate_state.enthalpy_megajoules - target_enthalpy_megajoules;
            const implied_temperature_error_k = @abs(candidate_residual_megajoules) /
                candidate_state.sensible_heat_capacity_megajoules_per_k;
            if (!std.math.isFinite(implied_temperature_error_k) or
                implied_temperature_error_k > acceptance_tolerance_k) return err;
            var recovered = last_iterate;
            recovered.residual = candidate_residual_megajoules;
            break :acceptance recovered;
        },
        else => return err,
    };
    return .{
        .state = try stateAtTemperature(parameters, solved.root),
        .iterations = solved.iterations,
        .attempted_nonlinear_iterations = local_budget.attempted_iterations,
        .newton_raphson_steps = solved.newton_raphson_steps,
        .picard_steps = solved.anderson_steps,
        .anderson_recovery_steps = solved.anderson_steps,
    };
}

fn testParameters() Parameters {
    return .{
        .porous_medium_volume_m3 = 1,
        .total_water_equivalent_m3 = 0.45,
        .unfrozen_pressure_head_m = -2,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        .dry_solid_heat_capacity_megajoules_per_k = 1.5,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.93,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
        .mualem_van_genuchten = .{
            .residual_water_content_m3_per_m3 = 0.05,
            .saturated_water_content_m3_per_m3 = 0.45,
            .alpha_per_m = 1.6,
            .n = 1.6,
            .saturated_hydraulic_conductivity_m_per_h = 0.01,
        },
    };
}

test "Dall'Amico enthalpy inversion conserves energy and exits early" {
    const parameters = testParameters();
    const expected = try stateAtTemperature(parameters, 268);
    const solved = try temperatureFromEnthalpy(
        parameters,
        expected.enthalpy_megajoules,
        .{ .max_iterations = 80 },
    );
    try std.testing.expect(solved.iterations < 80);
    try std.testing.expectEqual(solved.iterations, solved.attempted_nonlinear_iterations);
    try std.testing.expect(solved.newton_raphson_steps +
        solved.picard_steps > 0);
    try std.testing.expectApproxEqAbs(
        expected.temperature_k,
        solved.state.temperature_k,
        1.0e-8,
    );
    try std.testing.expectApproxEqAbs(
        expected.enthalpy_megajoules,
        solved.state.enthalpy_megajoules,
        1.0e-9,
    );
    try std.testing.expectApproxEqAbs(
        parameters.total_water_equivalent_m3,
        solved.state.liquid_water_m3 +
            solved.state.ice_water_equivalent_m3,
        1.0e-14,
    );
}

test "saturated Stefan transition enthalpy inversion crosses the melting point" {
    const parameters: Parameters = .{
        .porous_medium_volume_m3 = 0.01,
        .total_water_equivalent_m3 = 0.01,
        .unfrozen_pressure_head_m = 0,
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        .dry_solid_heat_capacity_megajoules_per_k = 0,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 0.6 / 1.43e-7 * 1.0e-6,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 2.117,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
        .mualem_van_genuchten = .{
            .residual_water_content_m3_per_m3 = 0,
            .saturated_water_content_m3_per_m3 = 1,
            .alpha_per_m = 400,
            .n = 2.5,
            .saturated_hydraulic_conductivity_m_per_h = 1,
        },
    };
    inline for (.{
        .{ 3.335686749884302, 273.2346422651122 },
        .{ 3.335815735075785, 273.1499989301399 },
        .{ 3.335753011998289, 273.192320597626 },
    }) |case| {
        const solved = try temperatureFromEnthalpy(parameters, case[0], .{
            .max_iterations = 80,
            .absolute_enthalpy_tolerance_megajoules = 1.0e-13,
            .relative_enthalpy_tolerance = 1.0e-11,
            .initial_temperature_k = case[1],
        });
        const tolerance = 1.0e-13 + 1.0e-11 * @abs(case[0]);
        const residual = solved.state.enthalpy_megajoules - case[0];
        if (@abs(residual) > tolerance) {
            // The constitutive slope at saturated melting is stiff enough
            // that the requested enthalpy can lie strictly between adjacent
            // f64 temperatures. Prove the returned endpoint is the closer of
            // those two representations rather than widening the tolerance.
            const neighbor_temperature = std.math.nextAfter(
                f64,
                solved.state.temperature_k,
                if (residual > 0) -std.math.inf(f64) else std.math.inf(f64),
            );
            const neighbor = try stateAtTemperature(parameters, neighbor_temperature);
            const neighbor_residual = neighbor.enthalpy_megajoules - case[0];
            try std.testing.expect(std.math.signbit(neighbor_residual) != std.math.signbit(residual));
            try std.testing.expect(@abs(residual) <= @abs(neighbor_residual));
        }
    }
}

test "enthalpy outside runtime temperature bracket fails explicitly" {
    try std.testing.expectError(
        error.SoilEnthalpyTargetOutsideTemperatureBracket,
        temperatureFromEnthalpy(
            testParameters(),
            -1.0e9,
            .{ .max_iterations = 80 },
        ),
    );
}

test "per-cell enthalpy inversion honors its independent local ceiling" {
    const parameters = testParameters();
    const expected = try stateAtTemperature(parameters, 268);
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        temperatureFromEnthalpy(
            parameters,
            expected.enthalpy_megajoules,
            .{
                .max_iterations = 20,
                .local_iteration_limit = 1,
                .initial_temperature_k = 350,
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidSoilEnthalpySolverOption,
        temperatureFromEnthalpy(
            parameters,
            expected.enthalpy_megajoules,
            .{ .max_iterations = 20, .local_iteration_limit = 0 },
        ),
    );
}

test "physical acceptance accepts a ceiling-bound iterate the residual-only gate would reject" {
    // Same fixture as "per-cell enthalpy inversion honors its independent
    // local ceiling" above, which fails with NewtonPicardDidNotConverge at
    // local_iteration_limit=1. A generous acceptance tolerance now accepts
    // that same one-step iterate; the returned state must still actually
    // satisfy stateAtTemperature's own finiteness/positivity checks.
    const parameters = testParameters();
    const expected = try stateAtTemperature(parameters, 268);
    const solved = try temperatureFromEnthalpy(
        parameters,
        expected.enthalpy_megajoules,
        .{
            .max_iterations = 20,
            .local_iteration_limit = 1,
            .initial_temperature_k = 350,
            .physical_acceptance_temperature_tolerance_k = 25.0,
        },
    );
    try std.testing.expect(solved.state.temperature_k != expected.temperature_k);
    try std.testing.expect(std.math.isFinite(solved.state.temperature_k));
    try std.testing.expect(solved.state.sensible_heat_capacity_megajoules_per_k > 0);
    try std.testing.expectApproxEqAbs(
        parameters.total_water_equivalent_m3,
        solved.state.liquid_water_m3 + solved.state.ice_water_equivalent_m3,
        1.0e-12,
    );
}

test "physical acceptance defaults to unused and still rejects a negligible tolerance" {
    const parameters = testParameters();
    const expected = try stateAtTemperature(parameters, 268);
    // Default (null): identical failure to the pre-existing ceiling test.
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        temperatureFromEnthalpy(
            parameters,
            expected.enthalpy_megajoules,
            .{ .max_iterations = 20, .local_iteration_limit = 1, .initial_temperature_k = 350 },
        ),
    );
    // A physically negligible (not merely small) tolerance still rejects:
    // this is not a disguised "always accept" switch.
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        temperatureFromEnthalpy(
            parameters,
            expected.enthalpy_megajoules,
            .{
                .max_iterations = 20,
                .local_iteration_limit = 1,
                .initial_temperature_k = 350,
                .physical_acceptance_temperature_tolerance_k = 1.0e-30,
            },
        ),
    );
}

// `issue-024` round 11 measurement, NOT an assertion that either side is right.
//
// The oracle rate-limits the TOP soil layer's freezing specifically. That layer
// is gated out of the deep-layer micropore kernel (`watsub.f:6360`'s
// `IF(N3.GT.NUM(NY,NX))`, with `NUM=NU` at `watsub.f:125`, confirmed by
// `:6447-6451`) and handled instead at `watsub.f:2802-2823`, where the freeze
// branch's mass cap is `333.0*VOLW2*XNPSRX` with
// `XNPSRX = 1/(NPH*NPS*NPRS)` (`wthr.f:622`, `NPS=20`/`NPRS=10` at `:605-606`)
// while the thaw branch keeps `XNPXX = 1/NPH` (`:2810`). That block sits outside
// the `MM`/`NN` inner loops (`watsub.f:1237-2599`, `:1913-2198`), so the freeze
// fraction does not re-accumulate: it executes `NFH*NPH` times per hour.
//
// ecosys-ng commits, for every layer including this one, the UNCONSTRAINED
// Dall'Amico equilibrium split that `stateAtTemperature` returns
// (`soil/heat/solver_residual.zig:145-160` fills the phase buffers from
// `trialState`; `soil/heat/solver_solve.zig:674-676` publishes them). No rate
// limiter exists on that path -- independently searched from both the editor and
// the reviewer side of the 2026-09-21 adversarial session
// (`audit/reviews/review-pi-2026-09-21-round2.md`).
//
// This test pins the resulting overshoot factor so that neither side can drift
// silently while the disposition question (is the oracle's kinetic ceiling real
// nucleation-limited physics, or a numerical convenience?) is still open with a
// human reviewer. It deliberately asserts only a loose bound: the exact factor
// depends on the retention curve, and the point is the order of magnitude.
test "issue-024: legacy top-layer freeze-rate ceiling versus unconstrained equilibrium partition" {
    // Ottawa top soil layer, from this issue's Experiments 1-2: layer 1 spans
    // 0.00-0.01 m over a 1 m2 footprint and starts at volumetric water 0.28
    // (the `THW=1` field-capacity code in `f25sol98`, decoded identically by both
    // sides).
    const porous_medium_volume_m3: f64 = 0.01;
    const initial_water_fraction: f64 = 0.28;
    const total_water_m3: f64 = initial_water_fraction * porous_medium_volume_m3;

    // Oracle ceiling. The mass cap binds on every execution for this state (the
    // `XNPR`-attenuated driving term is ~25x larger), so compound it over the
    // hour's `NFH*NPH = 4*20` executions.
    const xnpsrx = 1.0 / (20.0 * 20.0 * 10.0);
    var legacy_liquid_m3 = total_water_m3;
    for (0..80) |_| legacy_liquid_m3 -= legacy_liquid_m3 * xnpsrx;
    const legacy_converted_fraction =
        (total_water_m3 - legacy_liquid_m3) / total_water_m3;
    // ~2% per hour, and NPH-independent: NFH*NPH * 1/(NPH*NPS*NPRS) = NFH/200.
    try std.testing.expect(legacy_converted_fraction > 0.019);
    try std.testing.expect(legacy_converted_fraction < 0.021);

    // ecosys-ng's committed partition for the same layer. This deck's
    // `van_genuchten_inflection_pressure_head_m = 0` opts every layer into the
    // generic Carsel-Parrish texture curve rather than one anchored to its own
    // supplied FC/WP (this issue's round 10), so use that curve here.
    const curve = try retention.carselParrishDefault(.clay_loam, null);
    const parameters: Parameters = .{
        .porous_medium_volume_m3 = porous_medium_volume_m3,
        .total_water_equivalent_m3 = total_water_m3,
        .unfrozen_pressure_head_m =
            try curve.pressureHeadAtWaterContent(initial_water_fraction),
        .gravitational_water_potential_mpa_per_m = 0.00980665,
        .pure_water_melting_temperature_k = 273.15,
        // Sensible-heat terms do not enter the partition at a fixed temperature;
        // they only affect enthalpy bookkeeping, so the measured ice fraction is
        // insensitive to these three values.
        .dry_solid_heat_capacity_megajoules_per_k = 1.0752 * porous_medium_volume_m3,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = 1.9274,
        .latent_heat_of_fusion_megajoules_per_m3 = 333.0,
        .mualem_van_genuchten = curve,
    };

    // The oracle's own measured hour-1 end state for this exact cell
    // (`TEMP_1 = -21.04 degC`, recorded in this issue from Round 2/Experiment 5's
    // read of `01998f25eh1`). Asking ecosys-ng's partition what it would do at the
    // oracle's own temperature is the matched-state comparison both `issue-024`
    // and `issue-079` asked for.
    const equilibrium = try stateAtTemperature(parameters, 252.11);
    const equilibrium_converted_fraction =
        equilibrium.ice_water_equivalent_m3 / total_water_m3;

    // Measured 2026-09-21 on this fixture (`zig test src/module_index.zig
    // --test-filter "legacy top-layer freeze-rate ceiling"`):
    //   legacy ceiling      = 1.9803777595356717e-2  (1.98% of liquid per hour)
    //   equilibrium at 252.11 K = 5.812939516021001e-1  (58.1% converted)
    //   overshoot           = 2.935268025522529e1   (29.35x)
    //   unfrozen head       = -2.690877828681523e0 m
    // For scale, the same formulation-class gap measured 19.17x for the LITTER
    // layer (EXEC-002) before it was replaced there with the energy-led limiter
    // in `surface/litter_freeze_thaw_energy_limit.zig`. The 58.1% here is also
    // close to the ~51-53.4% conversion the production runs actually record for
    // this cell at hour 1 (issue-024 rounds 2 and 9) -- independent support for
    // the finding that this partition, not the energy-led kernel, is what
    // production commits.
    // Conservation first: the partition must not create or destroy water.
    try std.testing.expectApproxEqAbs(
        total_water_m3,
        equilibrium.liquid_water_m3 + equilibrium.ice_water_equivalent_m3,
        1.0e-15,
    );
    // The formulation-class gap: at the oracle's own hour-1 temperature the
    // equilibrium partition converts more than an order of magnitude beyond the
    // oracle's whole-hour kinetic ceiling.
    try std.testing.expect(
        equilibrium_converted_fraction > 10.0 * legacy_converted_fraction,
    );
}

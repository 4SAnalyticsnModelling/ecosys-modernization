const std = @import("std");
const numerics = @import("../../core/numerics.zig");

pub const DiffusionInputs = struct {
    microbial_radius_m: f64,
    water_film_thickness_m: f64,
    tortuosity: f64,
    aqueous_oxygen_diffusivity_m2_per_step: f64,
    microbial_count_per_g_c: f64,
    active_biomass_g_c: f64,
};

/// Ports NITRO DIFOX, including the spherical microbial surface factor 12.57.
pub fn uptakeConductance_m3_per_step(inputs: DiffusionInputs) !f64 {
    inline for (@typeInfo(DiffusionInputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteOxygenDiffusionInput;
    if (inputs.microbial_radius_m <= 0 or inputs.water_film_thickness_m <= 0 or inputs.tortuosity < 0 or inputs.aqueous_oxygen_diffusivity_m2_per_step < 0 or inputs.microbial_count_per_g_c < 0 or inputs.active_biomass_g_c < 0) return error.InvalidOxygenDiffusionInput;
    const radial_factor_m = inputs.microbial_radius_m * (inputs.water_film_thickness_m + inputs.microbial_radius_m) / inputs.water_film_thickness_m;
    const conductance = inputs.tortuosity * inputs.aqueous_oxygen_diffusivity_m2_per_step * 12.57 * inputs.microbial_count_per_g_c * inputs.active_biomass_g_c * radial_factor_m;
    if (!std.math.isFinite(conductance)) return error.NonFiniteOxygenConductance;
    return conductance;
}

pub const Inputs = struct {
    allocated_gaseous_oxygen_g_o: f64,
    allocated_aqueous_oxygen_g_o: f64,
    allocated_gaseous_flux_g_o: f64,
    allocated_aqueous_flux_g_o: f64,
    water_volume_m3: f64,
    air_volume_m3: f64,
    population_allocation_fraction: f64,
    oxygen_solubility_water_to_air: f64,
    gas_exchange_rate_per_step: f64,
    uptake_conductance_m3_per_step: f64,
    oxygen_half_saturation_g_o_per_m3: f64,
    maximum_oxygen_uptake_g_o: f64,
    maximum_aqueous_oxygen_concentration_g_o_per_m3: f64,
};

pub const Options = struct {
    absolute_tolerance_g_o: f64,
    relative_tolerance: f64,
    derivative_floor: f64,
    picard_relaxation: f64,
    gas_max_iterations: u16,
};

pub const Result = struct {
    gaseous_oxygen_g_o: f64,
    aqueous_oxygen_g_o: f64,
    oxygen_uptake_g_o: f64,
    gas_to_water_exchange_g_o: f64,
    demand_satisfaction_fraction: f64,
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    residual_g_o: f64,
};

const Context = struct {
    inputs: Inputs,
    gas_before_exchange_g_o: f64,
    aqueous_before_exchange_g_o: f64,
    total_before_uptake_g_o: f64,
};

const ConservedInventory = struct {
    gaseous_g_o: f64,
    aqueous_g_o: f64,
    uptake_g_o: f64,
};

/// Replaces NITRO's nested NPH/NPT O2 cycles with one bounded implicit
/// damped-Newton solve with Anderson-accelerated Picard recovery.
/// `gas_max_iterations` is NPH*NPG from runtime options, and convergence
/// exits immediately.
pub fn solve(inputs: Inputs, options: Options) !Result {
    try validate(inputs, options);
    const gas_before = inputs.allocated_gaseous_oxygen_g_o + inputs.allocated_gaseous_flux_g_o;
    const aqueous_before = inputs.allocated_aqueous_oxygen_g_o + inputs.allocated_aqueous_flux_g_o;
    if (gas_before < 0 or aqueous_before < 0) return error.NegativeAvailableOxygen;
    const total_before = gas_before + aqueous_before;
    if (total_before == 0 or inputs.maximum_oxygen_uptake_g_o == 0) return .{ .gaseous_oxygen_g_o = gas_before, .aqueous_oxygen_g_o = aqueous_before, .oxygen_uptake_g_o = 0, .gas_to_water_exchange_g_o = 0, .demand_satisfaction_fraction = if (inputs.maximum_oxygen_uptake_g_o == 0) 1 else 0, .iterations = 0, .newton_raphson_steps = 0, .picard_steps = 0, .residual_g_o = 0 };
    // Once the requested relative mass tolerance underflows to zero, no
    // representable Newton/Anderson correction can resolve this inventory at
    // the configured precision. Preserve the trace inventory exactly instead
    // of constructing a zero absolute tolerance or silently consuming it.
    const relative_inventory_tolerance_g_o = total_before * options.relative_tolerance;
    // Arithmetic on subnormal gram inventories cannot reliably distinguish a
    // residual correction from representation noise (the Arctic example
    // reaches ~4e-314 g O). Preserve that finite trace exactly; it is far
    // below any physical model resolution and must not consume NPH*NPG.
    if (total_before <= std.math.floatMin(f64) or relative_inventory_tolerance_g_o == 0) return .{ .gaseous_oxygen_g_o = gas_before, .aqueous_oxygen_g_o = aqueous_before, .oxygen_uptake_g_o = 0, .gas_to_water_exchange_g_o = 0, .demand_satisfaction_fraction = 0, .iterations = 0, .newton_raphson_steps = 0, .picard_steps = 0, .residual_g_o = 0 };
    const context: Context = .{ .inputs = inputs, .gas_before_exchange_g_o = gas_before, .aqueous_before_exchange_g_o = aqueous_before, .total_before_uptake_g_o = total_before };
    // Start from the phase-equilibrium partition rather than a dry aqueous
    // boundary. This seeds dissolution when all available O2 begins in gas
    // and avoids a Picard two-cycle at the physical lower bound.
    const water_capacity_m3 = inputs.water_volume_m3 * inputs.oxygen_solubility_water_to_air;
    const equilibrium_aqueous_g_o = total_before * water_capacity_m3 / (water_capacity_m3 + inputs.air_volume_m3);
    const initial = std.math.clamp(@max(aqueous_before, equilibrium_aqueous_g_o), 0, total_before);
    // A run-wide absolute tolerance can exceed a depleted population's
    // entire O2 allocation. Scale it down for small inventories so an
    // initially bounded aqueous mass cannot be accepted while its implied
    // gas mass is negative.
    const inventory_absolute_tolerance_g_o = @min(options.absolute_tolerance_g_o, relative_inventory_tolerance_g_o);
    const solved = try numerics.newtonPicard(&context, residual, derivative, picard, 0, total_before, initial, .{
        .absolute_tolerance = inventory_absolute_tolerance_g_o,
        .relative_tolerance = options.relative_tolerance,
        .derivative_floor = options.derivative_floor,
        .picard_relaxation = options.picard_relaxation,
        // The residual is an oxygen mass balance, so its scale is the
        // available inventory. Potential demand may be orders of magnitude
        // larger and must not loosen conservation convergence.
        .residual_scale = total_before,
        .max_iterations = options.gas_max_iterations,
    });
    const candidate_uptake = activeUptake(context, solved.root).value;
    const roundoff_tolerance = inventory_absolute_tolerance_g_o + options.relative_tolerance * total_before;
    const conserved = conserveInventory(total_before, solved.root, candidate_uptake, roundoff_tolerance) catch |err| {
        std.log.err(
            "invalid oxygen solution: aqueous_g_o={e} uptake_g_o={e} gas_before_g_o={e} aqueous_before_g_o={e} residual_g_o={e} tolerance_g_o={e} iterations={d}",
            .{ solved.root, candidate_uptake, gas_before, aqueous_before, solved.residual, roundoff_tolerance, solved.iterations },
        );
        return err;
    };
    const exchange = gas_before - conserved.gaseous_g_o;
    if (!std.math.isFinite(exchange)) {
        std.log.err(
            "invalid oxygen exchange: gas_before_g_o={e} conserved_gas_g_o={e}",
            .{ gas_before, conserved.gaseous_g_o },
        );
        return error.InvalidOxygenSolution;
    }
    const satisfaction = demandSatisfactionFraction(
        conserved.uptake_g_o,
        inputs.maximum_oxygen_uptake_g_o,
    ) catch |err| {
        std.log.err(
            "invalid oxygen demand satisfaction: uptake_g_o={e} demand_g_o={e} aqueous_g_o={e} gaseous_g_o={e} total_before_g_o={e} residual_g_o={e} iterations={d}",
            .{ conserved.uptake_g_o, inputs.maximum_oxygen_uptake_g_o, conserved.aqueous_g_o, conserved.gaseous_g_o, total_before, solved.residual, solved.iterations },
        );
        return err;
    };
    const mass_error = conserved.gaseous_g_o + conserved.aqueous_g_o + conserved.uptake_g_o - total_before;
    const closure_roundoff_g_o = 64.0 * std.math.floatEps(f64) * total_before;
    if (@abs(mass_error) > closure_roundoff_g_o) return error.OxygenMassBalanceFailure;
    return .{
        .gaseous_oxygen_g_o = conserved.gaseous_g_o,
        .aqueous_oxygen_g_o = conserved.aqueous_g_o,
        .oxygen_uptake_g_o = conserved.uptake_g_o,
        .gas_to_water_exchange_g_o = exchange,
        .demand_satisfaction_fraction = satisfaction,
        .iterations = solved.iterations,
        .newton_raphson_steps = solved.newton_raphson_steps,
        .picard_steps = solved.picard_steps,
        .residual_g_o = solved.residual,
    };
}

fn demandSatisfactionFraction(uptake_g_o: f64, demand_g_o: f64) !f64 {
    if (!std.math.isFinite(uptake_g_o) or uptake_g_o < 0 or
        !std.math.isFinite(demand_g_o) or demand_g_o <= 0)
        return error.InvalidOxygenSolution;
    const demand_roundoff_g_o = 64.0 * std.math.floatEps(f64) *
        @max(uptake_g_o, demand_g_o);
    if (uptake_g_o > demand_g_o + demand_roundoff_g_o)
        return error.InvalidOxygenSolution;
    const fraction = uptake_g_o / demand_g_o;
    if (!std.math.isFinite(fraction) or fraction < 0)
        return error.InvalidOxygenSolution;
    return @min(1, fraction);
}

fn conserveInventory(total_g_o: f64, aqueous_g_o: f64, uptake_g_o: f64, projection_tolerance_g_o: f64) !ConservedInventory {
    inline for (.{ total_g_o, aqueous_g_o, uptake_g_o, projection_tolerance_g_o }) |value| if (!std.math.isFinite(value)) return error.InvalidOxygenSolution;
    if (total_g_o < 0 or aqueous_g_o < 0 or uptake_g_o < 0 or projection_tolerance_g_o < 0) return error.InvalidOxygenSolution;
    const allocated_g_o = aqueous_g_o + uptake_g_o;
    if (!std.math.isFinite(allocated_g_o) or allocated_g_o > total_g_o + projection_tolerance_g_o) return error.InvalidOxygenSolution;
    if (allocated_g_o <= total_g_o) return .{ .gaseous_g_o = total_g_o - allocated_g_o, .aqueous_g_o = aqueous_g_o, .uptake_g_o = uptake_g_o };

    // Couple the correction across storage and uptake. Silently clamping the
    // negative gas coordinate to zero would manufacture molecular oxygen.
    const scale = total_g_o / allocated_g_o;
    const projected_uptake_g_o = uptake_g_o * scale;
    const projected_aqueous_g_o = total_g_o - projected_uptake_g_o;
    if (!std.math.isFinite(scale) or scale < 0 or scale > 1 or !std.math.isFinite(projected_aqueous_g_o) or projected_aqueous_g_o < 0 or !std.math.isFinite(projected_uptake_g_o) or projected_uptake_g_o < 0) return error.InvalidOxygenSolution;
    return .{ .gaseous_g_o = 0, .aqueous_g_o = projected_aqueous_g_o, .uptake_g_o = projected_uptake_g_o };
}

const UptakeValue = struct { value: f64, derivative: f64 };

fn activeUptake(context: Context, aqueous_mass_g_o: f64) UptakeValue {
    const inputs = context.inputs;
    const effective_water_m3 = inputs.water_volume_m3 * inputs.population_allocation_fraction;
    if (aqueous_mass_g_o <= 0) return .{ .value = 0, .derivative = 0 };
    const unconstrained_concentration = aqueous_mass_g_o / effective_water_m3;
    const concentration = @min(inputs.maximum_aqueous_oxygen_concentration_g_o_per_m3, unconstrained_concentration);
    const dc_da: f64 = if (unconstrained_concentration > 0 and unconstrained_concentration < inputs.maximum_aqueous_oxygen_concentration_g_o_per_m3) 1 / effective_water_m3 else 0;
    const x = inputs.uptake_conductance_m3_per_step * concentration;
    if (x <= 0) return .{ .value = 0, .derivative = 0 };
    const demand = inputs.maximum_oxygen_uptake_g_o;
    const sum = demand + inputs.uptake_conductance_m3_per_step * inputs.oxygen_half_saturation_g_o_per_m3 + x;
    const half_saturation_term = inputs.uptake_conductance_m3_per_step * inputs.oxygen_half_saturation_g_o_per_m3;
    const discriminant = (demand - x) * (demand - x) + half_saturation_term * (2 * (demand + x) + half_saturation_term);
    if (!std.math.isFinite(discriminant)) return .{ .value = std.math.nan(f64), .derivative = std.math.nan(f64) };
    const root = @sqrt(discriminant);
    // Stable form of the source quadratic. The explicit sub-hour source kept
    // uptake below the current aqueous inventory through its tiny XNPG step;
    // the implicit replacement enforces that conservation bound directly.
    const denominator = sum + root;
    const unconstrained_value = if (denominator > 0)
        if (x <= demand)
            2 * (demand / denominator) * x
        else
            2 * (x / denominator) * demand
    else
        0;
    const physical_limit = @min(aqueous_mass_g_o, demand);
    if (unconstrained_value >= physical_limit) return .{
        .value = physical_limit,
        .derivative = if (aqueous_mass_g_o < demand) 1 else 0,
    };
    const value = unconstrained_value;
    const dx_da = inputs.uptake_conductance_m3_per_step * dc_da;
    const derivative_value = if (root > std.math.floatEps(f64)) 0.5 * (dx_da - (2 * sum * dx_da - 4 * demand * dx_da) / (2 * root)) else 0;
    return .{ .value = value, .derivative = derivative_value };
}

fn exchangeAndDerivative(context: Context, aqueous_mass_g_o: f64, uptake: UptakeValue) struct { value: f64, derivative: f64 } {
    const inputs = context.inputs;
    const water_capacity_m3 = inputs.water_volume_m3 * inputs.oxygen_solubility_water_to_air;
    const combined_capacity_m3 = water_capacity_m3 + inputs.air_volume_m3;
    const gas_mass_g_o = context.total_before_uptake_g_o - aqueous_mass_g_o - uptake.value;
    const gas_derivative = -1 - uptake.derivative;
    const value = inputs.gas_exchange_rate_per_step * (@max(0, gas_mass_g_o) * water_capacity_m3 - aqueous_mass_g_o * inputs.air_volume_m3) / combined_capacity_m3;
    const derivative_value = inputs.gas_exchange_rate_per_step * ((if (gas_mass_g_o > 0) gas_derivative * water_capacity_m3 else 0) - inputs.air_volume_m3) / combined_capacity_m3;
    return .{ .value = value, .derivative = derivative_value };
}

fn residual(context: *const Context, aqueous_mass_g_o: f64) f64 {
    const uptake = activeUptake(context.*, aqueous_mass_g_o);
    const exchange = exchangeAndDerivative(context.*, aqueous_mass_g_o, uptake);
    return aqueous_mass_g_o - context.aqueous_before_exchange_g_o + uptake.value - exchange.value;
}

fn derivative(context: *const Context, aqueous_mass_g_o: f64) f64 {
    const uptake = activeUptake(context.*, aqueous_mass_g_o);
    const exchange = exchangeAndDerivative(context.*, aqueous_mass_g_o, uptake);
    return 1 + uptake.derivative - exchange.derivative;
}

fn picard(context: *const Context, aqueous_mass_g_o: f64) f64 {
    const uptake = activeUptake(context.*, aqueous_mass_g_o);
    const exchange = exchangeAndDerivative(context.*, aqueous_mass_g_o, uptake);
    return context.aqueous_before_exchange_g_o - uptake.value + exchange.value;
}

fn validate(inputs: Inputs, options: Options) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteOxygenSolverInput;
    inline for (@typeInfo(Options).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(options, field.name))) return error.NonFiniteOxygenSolverOption;
    if (inputs.allocated_gaseous_oxygen_g_o < 0 or inputs.allocated_aqueous_oxygen_g_o < 0 or inputs.water_volume_m3 <= 0 or inputs.air_volume_m3 < 0 or inputs.population_allocation_fraction <= 0 or inputs.population_allocation_fraction > 1 or inputs.oxygen_solubility_water_to_air < 0 or inputs.gas_exchange_rate_per_step < 0 or inputs.uptake_conductance_m3_per_step < 0 or inputs.oxygen_half_saturation_g_o_per_m3 <= 0 or inputs.maximum_oxygen_uptake_g_o < 0 or inputs.maximum_aqueous_oxygen_concentration_g_o_per_m3 <= 0) return error.InvalidOxygenSolverInput;
    if (inputs.water_volume_m3 * inputs.oxygen_solubility_water_to_air + inputs.air_volume_m3 <= 0 or options.absolute_tolerance_g_o <= 0 or options.relative_tolerance <= 0 or options.relative_tolerance >= 1 or options.derivative_floor <= 0 or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or options.gas_max_iterations == 0) return error.InvalidOxygenSolverOption;
}

fn testInputs() Inputs {
    return .{ .allocated_gaseous_oxygen_g_o = 5, .allocated_aqueous_oxygen_g_o = 1, .allocated_gaseous_flux_g_o = 0, .allocated_aqueous_flux_g_o = 0, .water_volume_m3 = 2, .air_volume_m3 = 3, .population_allocation_fraction = 1, .oxygen_solubility_water_to_air = 0.03, .gas_exchange_rate_per_step = 0.5, .uptake_conductance_m3_per_step = 2, .oxygen_half_saturation_g_o_per_m3 = 0.1, .maximum_oxygen_uptake_g_o = 0.8, .maximum_aqueous_oxygen_concentration_g_o_per_m3 = 1 };
}

fn testOptions() Options {
    return .{ .absolute_tolerance_g_o = 1e-12, .relative_tolerance = 1e-10, .derivative_floor = 1e-14, .picard_relaxation = 0.5, .gas_max_iterations = 80 };
}

test "hybrid oxygen solve converges early and conserves mass" {
    const inputs = testInputs();
    const result = try solve(inputs, testOptions());
    try std.testing.expect(result.iterations < 80);
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expectApproxEqAbs(inputs.allocated_gaseous_oxygen_g_o + inputs.allocated_aqueous_oxygen_g_o, result.gaseous_oxygen_g_o + result.aqueous_oxygen_g_o + result.oxygen_uptake_g_o, 1e-9);
    const before = inputs.allocated_gaseous_oxygen_g_o + inputs.allocated_gaseous_flux_g_o + inputs.allocated_aqueous_oxygen_g_o + inputs.allocated_aqueous_flux_g_o;
    try std.testing.expectApproxEqAbs(inputs.allocated_gaseous_oxygen_g_o + inputs.allocated_gaseous_flux_g_o - result.gaseous_oxygen_g_o, result.gas_to_water_exchange_g_o, 64.0 * std.math.floatEps(f64) * before);
    try std.testing.expectApproxEqAbs(inputs.allocated_aqueous_oxygen_g_o + inputs.allocated_aqueous_flux_g_o + result.gas_to_water_exchange_g_o - result.oxygen_uptake_g_o, result.aqueous_oxygen_g_o, 64.0 * std.math.floatEps(f64) * before);
    try std.testing.expect(result.demand_satisfaction_fraction > 0 and result.demand_satisfaction_fraction <= 1);
}

test "oxygen demand satisfaction normalizes only representational excess" {
    try std.testing.expectEqual(@as(f64, 0.5), try demandSatisfactionFraction(0.5, 1));
    try std.testing.expectEqual(
        @as(f64, 1),
        try demandSatisfactionFraction(std.math.nextAfter(f64, 1, std.math.inf(f64)), 1),
    );
    try std.testing.expectError(
        error.InvalidOxygenSolution,
        demandSatisfactionFraction(1 + 1.0e-12, 1),
    );
}

test "active oxygen uptake enforces demand cap without intermediate overflow" {
    var inputs = testInputs();
    inputs.water_volume_m3 = 2.0e154;
    inputs.population_allocation_fraction = 1;
    inputs.uptake_conductance_m3_per_step = 1.0e154;
    inputs.oxygen_half_saturation_g_o_per_m3 = 1.0e-154;
    inputs.maximum_oxygen_uptake_g_o = 1.0e154;
    inputs.maximum_aqueous_oxygen_concentration_g_o_per_m3 = 1;
    const context: Context = .{
        .inputs = inputs,
        .gas_before_exchange_g_o = 1.0e154,
        .aqueous_before_exchange_g_o = 2.0e154,
        .total_before_uptake_g_o = 3.0e154,
    };
    const uptake = activeUptake(context, 2.0e154);
    try std.testing.expect(std.math.isFinite(uptake.value));
    try std.testing.expectEqual(inputs.maximum_oxygen_uptake_g_o, uptake.value);
    try std.testing.expectEqual(@as(f64, 0), uptake.derivative);
}

test "zero oxygen returns without consuming iteration budget" {
    var inputs = testInputs();
    inputs.allocated_gaseous_oxygen_g_o = 0;
    inputs.allocated_aqueous_oxygen_g_o = 0;
    const result = try solve(inputs, testOptions());
    try std.testing.expectEqual(@as(u16, 0), result.iterations);
    try std.testing.expectEqual(@as(f64, 0), result.oxygen_uptake_g_o);
}

test "subnormal oxygen trace is preserved without nonlinear iterations" {
    var inputs = testInputs();
    inputs.allocated_gaseous_oxygen_g_o = 4.0e-314;
    inputs.allocated_aqueous_oxygen_g_o = 4.0e-315;
    const result = try solve(inputs, testOptions());
    try std.testing.expectEqual(@as(u16, 0), result.iterations);
    try std.testing.expectEqual(inputs.allocated_gaseous_oxygen_g_o, result.gaseous_oxygen_g_o);
    try std.testing.expectEqual(inputs.allocated_aqueous_oxygen_g_o, result.aqueous_oxygen_g_o);
    try std.testing.expectEqual(@as(f64, 0), result.oxygen_uptake_g_o);
}

test "oxygen diffusion conductance preserves NITRO spherical factor" {
    const conductance = try uptakeConductance_m3_per_step(.{ .microbial_radius_m = 1e-6, .water_film_thickness_m = 2e-6, .tortuosity = 0.5, .aqueous_oxygen_diffusivity_m2_per_step = 1e-4, .microbial_count_per_g_c = 1e12, .active_biomass_g_c = 0.01 });
    try std.testing.expectApproxEqRel(@as(f64, 0.5 * 1e-4 * 12.57 * 1e12 * 0.01 * 1.5e-6), conductance, 1e-14);
}

test "oxygen solver uses Anderson-Picard when Newton derivative is rejected" {
    var options = testOptions();
    options.derivative_floor = 1e9;
    options.relative_tolerance = 1e-8;
    const result = try solve(testInputs(), options);
    try std.testing.expect(result.picard_steps > 0);
    try std.testing.expectEqual(@as(u16, 0), result.newton_raphson_steps);
}

test "depleted oxygen inventory uses a mass-conserving scaled tolerance" {
    var inputs = testInputs();
    inputs.allocated_gaseous_oxygen_g_o = 7.0e-13;
    inputs.allocated_aqueous_oxygen_g_o = 1.19e-11;
    inputs.maximum_oxygen_uptake_g_o = 1.0e-9;
    var options = testOptions();
    options.absolute_tolerance_g_o = 1.0e-11;
    options.relative_tolerance = 1.0e-8;

    const result = try solve(inputs, options);
    const before = inputs.allocated_gaseous_oxygen_g_o + inputs.allocated_aqueous_oxygen_g_o;
    try std.testing.expect(result.gaseous_oxygen_g_o >= 0);
    try std.testing.expect(result.aqueous_oxygen_g_o >= 0);
    try std.testing.expectApproxEqAbs(before, result.gaseous_oxygen_g_o + result.aqueous_oxygen_g_o + result.oxygen_uptake_g_o, before * 3.0e-8);
}

test "subnormal oxygen below relative resolution is preserved exactly" {
    var inputs = testInputs();
    inputs.allocated_gaseous_oxygen_g_o = std.math.floatTrueMin(f64);
    inputs.allocated_aqueous_oxygen_g_o = 0;
    const result = try solve(inputs, testOptions());
    try std.testing.expectEqual(inputs.allocated_gaseous_oxygen_g_o, result.gaseous_oxygen_g_o);
    try std.testing.expectEqual(@as(f64, 0), result.aqueous_oxygen_g_o);
    try std.testing.expectEqual(@as(f64, 0), result.oxygen_uptake_g_o);
    try std.testing.expectEqual(@as(u16, 0), result.iterations);
}

test "oxygen roundoff projection conserves instead of clipping a negative gas candidate" {
    const conserved = try conserveInventory(1, 0.6, 0.4000000005, 1e-9);
    try std.testing.expectEqual(@as(f64, 0), conserved.gaseous_g_o);
    try std.testing.expect(conserved.aqueous_g_o < 0.6);
    try std.testing.expect(conserved.uptake_g_o < 0.4000000005);
    try std.testing.expectApproxEqAbs(@as(f64, 1), conserved.gaseous_g_o + conserved.aqueous_g_o + conserved.uptake_g_o, 4.0 * std.math.floatEps(f64));
}

test "oxygen projection rejects a material inventory overdraft" {
    try std.testing.expectError(error.InvalidOxygenSolution, conserveInventory(1, 0.6, 0.5, 1e-6));
}

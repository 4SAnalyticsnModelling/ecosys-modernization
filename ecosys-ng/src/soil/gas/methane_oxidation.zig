const std = @import("std");
const numerics = @import("../../core/numerics.zig");

pub const Inputs = struct {
    gaseous_methane_g_c: f64,
    aqueous_methane_g_c: f64,
    gaseous_methane_flux_g_c: f64,
    aqueous_methane_flux_g_c: f64,
    methanogenesis_g_c: f64,
    water_volume_m3: f64,
    air_volume_m3: f64,
    methane_solubility_water_to_air: f64,
    gas_exchange_rate_per_step: f64,
    gas_exchange_enabled: bool,
    methane_half_saturation_g_c_per_m3: f64,
    maximum_methane_oxidation_g_c: f64,
    biomass_conversion_efficiency_g_c_per_g_c: f64,
    growth_respiration_g_c_per_g_c: f64,
    maintenance_respiration_g_c: f64,
};

pub const Options = struct {
    absolute_tolerance_g_c: f64,
    relative_tolerance: f64,
    derivative_floor: f64,
    picard_relaxation: f64,
    gas_max_iterations: u16,
};

pub const Result = struct {
    gaseous_methane_g_c: f64,
    aqueous_methane_g_c: f64,
    methane_oxidation_g_c: f64,
    growth_respiration_g_c: f64,
    methane_carbon_uptake_g_c: f64,
    nonstructural_carbon_gain_g_c: f64,
    gas_to_water_exchange_g_c: f64,
    oxygen_demand_g_o: f64,
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    residual_g_c: f64,
};

const Context = struct {
    inputs: Inputs,
    gas_before_exchange_g_c: f64,
    aqueous_before_exchange_g_c: f64,
    total_before_consumption_g_c: f64,
};

const Consumption = struct { total_g_c: f64, derivative: f64 };
const CarbonPartition = struct {
    respiration_g_c: f64,
    uptake_g_c: f64,
    nonstructural_gain_g_c: f64,
    total_consumption_g_c: f64,
};
const ConservedCarbonPartition = struct {
    oxidation_g_c: f64,
    respiration_g_c: f64,
    uptake_g_c: f64,
    nonstructural_gain_g_c: f64,
    total_consumption_g_c: f64,
};

const ConservedInventory = struct {
    gaseous_g_c: f64,
    aqueous_g_c: f64,
    consumed_g_c: f64,
};

/// Replaces NITRO's NPH×NPT methane dissolution/oxidation cycling with a
/// single bounded implicit damped-Newton solve with Anderson-accelerated
/// Picard recovery. The caller supplies
/// the runtime NPH×NPG gas ceiling and convergence exits immediately.
pub fn solve(inputs: Inputs, options: Options) !Result {
    try validate(inputs, options);
    const gas_before = inputs.gaseous_methane_g_c + inputs.gaseous_methane_flux_g_c;
    const aqueous_before = inputs.aqueous_methane_g_c + inputs.aqueous_methane_flux_g_c + inputs.methanogenesis_g_c;
    if (gas_before < 0 or aqueous_before < 0) return error.NegativeAvailableMethane;
    const total_before = gas_before + aqueous_before;
    if (total_before == 0 or inputs.maximum_methane_oxidation_g_c == 0) return .{
        .gaseous_methane_g_c = gas_before,
        .aqueous_methane_g_c = aqueous_before,
        .methane_oxidation_g_c = 0,
        .growth_respiration_g_c = 0,
        .methane_carbon_uptake_g_c = 0,
        .nonstructural_carbon_gain_g_c = 0,
        .gas_to_water_exchange_g_c = 0,
        .oxygen_demand_g_o = 0,
        .iterations = 0,
        .newton_raphson_steps = 0,
        .picard_steps = 0,
        .residual_g_c = 0,
    };
    const relative_inventory_tolerance_g_c = total_before * options.relative_tolerance;
    if (total_before <= std.math.floatMin(f64) or relative_inventory_tolerance_g_c == 0) return .{
        .gaseous_methane_g_c = gas_before,
        .aqueous_methane_g_c = aqueous_before,
        .methane_oxidation_g_c = 0,
        .growth_respiration_g_c = 0,
        .methane_carbon_uptake_g_c = 0,
        .nonstructural_carbon_gain_g_c = 0,
        .gas_to_water_exchange_g_c = 0,
        .oxygen_demand_g_o = 0,
        .iterations = 0,
        .newton_raphson_steps = 0,
        .picard_steps = 0,
        .residual_g_c = 0,
    };
    const context: Context = .{ .inputs = inputs, .gas_before_exchange_g_c = gas_before, .aqueous_before_exchange_g_c = aqueous_before, .total_before_consumption_g_c = total_before };
    // This residual closes one layer's methane inventory. Potential oxidation
    // is a kinetic ceiling, not a mass scale, and the run-wide absolute floor
    // may exceed a depleted layer's complete inventory. Scale the configured
    // floor to this inventory so nonlinear convergence cannot precede the
    // independent conservation gate.
    const inventory_absolute_tolerance_g_c = @min(options.absolute_tolerance_g_c, relative_inventory_tolerance_g_c);
    const solved = try numerics.newtonPicard(&context, residual, derivative, picard, 0, total_before, @min(aqueous_before, total_before), .{
        .absolute_tolerance = inventory_absolute_tolerance_g_c,
        .relative_tolerance = options.relative_tolerance,
        .derivative_floor = options.derivative_floor,
        .picard_relaxation = options.picard_relaxation,
        .residual_scale = total_before,
        .max_iterations = options.gas_max_iterations,
    });
    const candidate_consumed = consumption(context, solved.root).total_g_c;
    const projection_tolerance_g_c = inventoryProjectionTolerance(options.absolute_tolerance_g_c, options.relative_tolerance, total_before);
    const conserved = try conserveInventory(total_before, solved.root, candidate_consumed, projection_tolerance_g_c);
    const partition = conservedCarbonPartition(inputs, conserved.consumed_g_c);
    const oxidation = partition.oxidation_g_c;
    const respiration = partition.respiration_g_c;
    const uptake = partition.uptake_g_c;
    const nonstructural_gain = partition.nonstructural_gain_g_c;
    const gas_to_water_exchange_g_c = gas_before - conserved.gaseous_g_c;
    const oxygen_demand = 5.333 * oxidation + 2.667 * respiration;
    inline for (.{ oxidation, respiration, uptake, nonstructural_gain, oxygen_demand }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMethaneSolution;
    if (!std.math.isFinite(gas_to_water_exchange_g_c)) return error.InvalidMethaneSolution;
    const closure_error_g_c = conserved.gaseous_g_c + conserved.aqueous_g_c + oxidation + uptake - total_before;
    const closure_roundoff_g_c = 64.0 * std.math.floatEps(f64) * total_before;
    if (@abs(closure_error_g_c) > closure_roundoff_g_c) return error.MethaneMassBalanceFailure;
    return .{
        .gaseous_methane_g_c = conserved.gaseous_g_c,
        .aqueous_methane_g_c = conserved.aqueous_g_c,
        .methane_oxidation_g_c = oxidation,
        .growth_respiration_g_c = respiration,
        .methane_carbon_uptake_g_c = uptake,
        .nonstructural_carbon_gain_g_c = nonstructural_gain,
        .gas_to_water_exchange_g_c = gas_to_water_exchange_g_c,
        .oxygen_demand_g_o = oxygen_demand,
        .iterations = solved.iterations,
        .newton_raphson_steps = solved.newton_raphson_steps,
        .picard_steps = solved.picard_steps,
        .residual_g_c = solved.residual,
    };
}

fn inventoryProjectionTolerance(absolute_tolerance_g_c: f64, relative_tolerance: f64, inventory_g_c: f64) f64 {
    const scaled_g_c = @max(relative_tolerance * inventory_g_c, 64.0 * std.math.floatEps(f64) * inventory_g_c);
    return @min(absolute_tolerance_g_c, scaled_g_c) + scaled_g_c;
}

fn conserveInventory(total_g_c: f64, aqueous_g_c: f64, consumed_g_c: f64, projection_tolerance_g_c: f64) !ConservedInventory {
    inline for (.{ total_g_c, aqueous_g_c, consumed_g_c, projection_tolerance_g_c }) |value| if (!std.math.isFinite(value)) return error.InvalidMethaneSolution;
    if (total_g_c < 0 or aqueous_g_c < 0 or consumed_g_c < 0 or projection_tolerance_g_c < 0) return error.InvalidMethaneSolution;
    const allocated_g_c = aqueous_g_c + consumed_g_c;
    if (!std.math.isFinite(allocated_g_c) or allocated_g_c > total_g_c + projection_tolerance_g_c) return error.InvalidMethaneSolution;
    if (allocated_g_c <= total_g_c) return .{ .gaseous_g_c = total_g_c - allocated_g_c, .aqueous_g_c = aqueous_g_c, .consumed_g_c = consumed_g_c };

    // The converged residual can leave the gas candidate negative by a few
    // scaled ulps. Project aqueous storage and its dependent reaction sink
    // together; clipping gas alone would create carbon.
    const scale = total_g_c / allocated_g_c;
    const projected_consumed_g_c = consumed_g_c * scale;
    const projected_aqueous_g_c = total_g_c - projected_consumed_g_c;
    if (!std.math.isFinite(scale) or scale < 0 or scale > 1 or !std.math.isFinite(projected_aqueous_g_c) or projected_aqueous_g_c < 0 or !std.math.isFinite(projected_consumed_g_c) or projected_consumed_g_c < 0) return error.InvalidMethaneSolution;
    return .{ .gaseous_g_c = 0, .aqueous_g_c = projected_aqueous_g_c, .consumed_g_c = projected_consumed_g_c };
}

fn consumption(context: Context, aqueous_g_c: f64) Consumption {
    if (aqueous_g_c <= 0) return .{ .total_g_c = 0, .derivative = 0 };
    const concentration = aqueous_g_c / context.inputs.water_volume_m3;
    const half_saturation = context.inputs.methane_half_saturation_g_c_per_m3;
    const kinetic_oxidation = context.inputs.maximum_methane_oxidation_g_c * concentration / (concentration + half_saturation);
    const partition = carbonPartition(context.inputs, kinetic_oxidation);
    if (aqueous_g_c <= partition.total_consumption_g_c) return .{ .total_g_c = aqueous_g_c, .derivative = 1 };
    const oxidation_derivative = context.inputs.maximum_methane_oxidation_g_c * half_saturation / (context.inputs.water_volume_m3 * std.math.pow(f64, concentration + half_saturation, 2));
    const respiration_per_oxidation = context.inputs.biomass_conversion_efficiency_g_c_per_g_c * context.inputs.growth_respiration_g_c_per_g_c;
    const total_per_oxidation = if (partition.respiration_g_c <= context.inputs.maintenance_respiration_g_c)
        1 + respiration_per_oxidation
    else
        1 + context.inputs.biomass_conversion_efficiency_g_c_per_g_c;
    return .{ .total_g_c = partition.total_consumption_g_c, .derivative = oxidation_derivative * total_per_oxidation };
}

/// NITRO.F 2580--2583 and 3821: methane oxidation respiration first pays
/// maintenance; only growth respiration is divided by ECHZ to obtain gross
/// CH4 carbon uptake. Net uptake is credited to microbial nonstructural C.
fn carbonPartition(inputs: Inputs, oxidation_g_c: f64) CarbonPartition {
    const respiration = oxidation_g_c * inputs.biomass_conversion_efficiency_g_c_per_g_c * inputs.growth_respiration_g_c_per_g_c;
    const maintenance = @min(inputs.maintenance_respiration_g_c, respiration);
    const growth_respiration = @max(0, respiration - maintenance);
    const uptake = maintenance + growth_respiration / inputs.growth_respiration_g_c_per_g_c;
    return .{
        .respiration_g_c = respiration,
        .uptake_g_c = uptake,
        .nonstructural_gain_g_c = uptake - respiration,
        .total_consumption_g_c = oxidation_g_c + uptake,
    };
}

fn conservedCarbonPartition(inputs: Inputs, consumption_g_c: f64) ConservedCarbonPartition {
    const oxidation = oxidationForTotalConsumption(inputs, consumption_g_c);
    const source_partition = carbonPartition(inputs, oxidation);
    // Preserve the solver's exactly conserved donor debit after a roundoff
    // projection while retaining the source maintenance/growth split. In the
    // source maintenance-limited regime uptake equals respiration and net
    // nonstructural gain is exactly zero. Reconstruct that identity from the
    // conserved debit instead of subtracting two separately rounded values.
    const uptake = consumption_g_c - oxidation;
    const maintenance_limited = source_partition.nonstructural_gain_g_c == 0;
    const respiration = if (maintenance_limited) uptake else source_partition.respiration_g_c;
    return .{
        .oxidation_g_c = oxidation,
        .respiration_g_c = respiration,
        .uptake_g_c = uptake,
        .nonstructural_gain_g_c = if (maintenance_limited) 0 else uptake - respiration,
        .total_consumption_g_c = consumption_g_c,
    };
}

fn oxidationForTotalConsumption(inputs: Inputs, total_g_c: f64) f64 {
    if (total_g_c <= 0) return 0;
    const respiration_per_oxidation = inputs.biomass_conversion_efficiency_g_c_per_g_c * inputs.growth_respiration_g_c_per_g_c;
    if (respiration_per_oxidation == 0) return total_g_c;
    const maintenance_threshold_oxidation = inputs.maintenance_respiration_g_c / respiration_per_oxidation;
    const maintenance_threshold_total = maintenance_threshold_oxidation + inputs.maintenance_respiration_g_c;
    if (total_g_c <= maintenance_threshold_total)
        return total_g_c / (1 + respiration_per_oxidation);
    return (total_g_c + inputs.maintenance_respiration_g_c * (1 / inputs.growth_respiration_g_c_per_g_c - 1)) /
        (1 + inputs.biomass_conversion_efficiency_g_c_per_g_c);
}

fn exchange(context: Context, aqueous_g_c: f64, consumed: Consumption) Consumption {
    if (!context.inputs.gas_exchange_enabled or context.inputs.gas_exchange_rate_per_step == 0) return .{ .total_g_c = 0, .derivative = 0 };
    const water_capacity_m3 = context.inputs.water_volume_m3 * context.inputs.methane_solubility_water_to_air;
    const total_capacity_m3 = water_capacity_m3 + context.inputs.air_volume_m3;
    const unconstrained_gas = context.total_before_consumption_g_c - aqueous_g_c - consumed.total_g_c;
    // NITRO's `ZEROS` is a grid-area-scaled numerical zero, not reserved CH4
    // storage. Using it as a positive gas mass in this implicit replacement
    // lets the residual dissolve methane that does not exist. The active
    // nonnegative gas bound is the conservative translation used by the
    // otherwise identical soil-O2 exchange solve.
    const gas = @max(0, unconstrained_gas);
    const gas_derivative: f64 = if (unconstrained_gas > 0) -1 - consumed.derivative else 0;
    return .{
        .total_g_c = context.inputs.gas_exchange_rate_per_step * (gas * water_capacity_m3 - aqueous_g_c * context.inputs.air_volume_m3) / total_capacity_m3,
        .derivative = context.inputs.gas_exchange_rate_per_step * (gas_derivative * water_capacity_m3 - context.inputs.air_volume_m3) / total_capacity_m3,
    };
}

fn residual(context: *const Context, aqueous_g_c: f64) f64 {
    const consumed = consumption(context.*, aqueous_g_c);
    return aqueous_g_c - context.aqueous_before_exchange_g_c + consumed.total_g_c - exchange(context.*, aqueous_g_c, consumed).total_g_c;
}

fn derivative(context: *const Context, aqueous_g_c: f64) f64 {
    const consumed = consumption(context.*, aqueous_g_c);
    return 1 + consumed.derivative - exchange(context.*, aqueous_g_c, consumed).derivative;
}

fn picard(context: *const Context, aqueous_g_c: f64) f64 {
    const consumed = consumption(context.*, aqueous_g_c);
    return context.aqueous_before_exchange_g_c - consumed.total_g_c + exchange(context.*, aqueous_g_c, consumed).total_g_c;
}

fn validate(inputs: Inputs, options: Options) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteMethaneOxidationInput;
    inline for (@typeInfo(Options).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(options, field.name))) return error.NonFiniteMethaneOxidationOption;
    if (inputs.gaseous_methane_g_c < 0 or inputs.aqueous_methane_g_c < 0 or inputs.water_volume_m3 <= 0 or inputs.air_volume_m3 < 0 or inputs.methane_solubility_water_to_air < 0 or inputs.gas_exchange_rate_per_step < 0 or inputs.methane_half_saturation_g_c_per_m3 <= 0 or inputs.maximum_methane_oxidation_g_c < 0 or inputs.biomass_conversion_efficiency_g_c_per_g_c < 0 or inputs.growth_respiration_g_c_per_g_c <= 0 or inputs.growth_respiration_g_c_per_g_c > 1 or inputs.maintenance_respiration_g_c < 0) return error.InvalidMethaneOxidationInput;
    if (inputs.gas_exchange_enabled and inputs.water_volume_m3 * inputs.methane_solubility_water_to_air + inputs.air_volume_m3 <= 0) return error.InvalidMethaneExchangeCapacity;
    if (options.absolute_tolerance_g_c <= 0 or options.relative_tolerance <= 0 or options.relative_tolerance >= 1 or options.derivative_floor <= 0 or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or options.gas_max_iterations == 0) return error.InvalidMethaneOxidationOption;
}

fn testInputs() Inputs {
    return .{ .gaseous_methane_g_c = 4, .aqueous_methane_g_c = 1, .gaseous_methane_flux_g_c = 0.1, .aqueous_methane_flux_g_c = 0.1, .methanogenesis_g_c = 0.2, .water_volume_m3 = 2, .air_volume_m3 = 3, .methane_solubility_water_to_air = 0.03, .gas_exchange_rate_per_step = 0.5, .gas_exchange_enabled = true, .methane_half_saturation_g_c_per_m3 = 0.2, .maximum_methane_oxidation_g_c = 0.3, .biomass_conversion_efficiency_g_c_per_g_c = 0.4, .growth_respiration_g_c_per_g_c = 0.5, .maintenance_respiration_g_c = 0.01 };
}

fn testOptions() Options {
    return .{ .absolute_tolerance_g_c = 1e-12, .relative_tolerance = 1e-10, .derivative_floor = 1e-14, .picard_relaxation = 0.5, .gas_max_iterations = 80 };
}

test "hybrid methane oxidation converges early and conserves carbon" {
    const inputs = testInputs();
    const result = try solve(inputs, testOptions());
    const before = inputs.gaseous_methane_g_c + inputs.aqueous_methane_g_c + inputs.gaseous_methane_flux_g_c + inputs.aqueous_methane_flux_g_c + inputs.methanogenesis_g_c;
    try std.testing.expect(result.iterations < 80);
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expectApproxEqAbs(before, result.gaseous_methane_g_c + result.aqueous_methane_g_c + result.methane_oxidation_g_c + result.methane_carbon_uptake_g_c, 1e-9);
    try std.testing.expectApproxEqAbs(inputs.gaseous_methane_g_c + inputs.gaseous_methane_flux_g_c - result.gaseous_methane_g_c, result.gas_to_water_exchange_g_c, 64.0 * std.math.floatEps(f64) * before);
    try std.testing.expectApproxEqAbs(inputs.aqueous_methane_g_c + inputs.aqueous_methane_flux_g_c + inputs.methanogenesis_g_c + result.gas_to_water_exchange_g_c - result.methane_oxidation_g_c - result.methane_carbon_uptake_g_c, result.aqueous_methane_g_c, 64.0 * std.math.floatEps(f64) * before);
    try std.testing.expectApproxEqAbs(result.methane_carbon_uptake_g_c - result.growth_respiration_g_c, result.nonstructural_carbon_gain_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(5.333 * result.methane_oxidation_g_c + 2.667 * result.growth_respiration_g_c, result.oxygen_demand_g_o, 1e-14);
}

test "zero methane exits without iteration" {
    var inputs = testInputs();
    inputs.gaseous_methane_g_c = 0;
    inputs.aqueous_methane_g_c = 0;
    inputs.gaseous_methane_flux_g_c = 0;
    inputs.aqueous_methane_flux_g_c = 0;
    inputs.methanogenesis_g_c = 0;
    const result = try solve(inputs, testOptions());
    try std.testing.expectEqual(@as(u16, 0), result.iterations);
}

test "methane roundoff projection conserves instead of clipping a negative gas candidate" {
    const conserved = try conserveInventory(1, 0.6, 0.4000000005, 1e-9);
    try std.testing.expectEqual(@as(f64, 0), conserved.gaseous_g_c);
    try std.testing.expect(conserved.aqueous_g_c < 0.6);
    try std.testing.expect(conserved.consumed_g_c < 0.4000000005);
    try std.testing.expectApproxEqAbs(@as(f64, 1), conserved.gaseous_g_c + conserved.aqueous_g_c + conserved.consumed_g_c, 4.0 * std.math.floatEps(f64));
}

test "methane projection rejects a material inventory overdraft" {
    try std.testing.expectError(error.InvalidMethaneSolution, conserveInventory(1, 0.6, 0.5, 1e-6));
}

test "trace methane inventory is solved at its own mass scale" {
    var inputs = testInputs();
    inputs.gaseous_methane_g_c = 0;
    inputs.aqueous_methane_g_c = 1e-12;
    inputs.gaseous_methane_flux_g_c = 0;
    inputs.aqueous_methane_flux_g_c = 0;
    inputs.methanogenesis_g_c = 0;
    inputs.water_volume_m3 = 0.25;
    inputs.air_volume_m3 = 0.1;
    // Deliberately much larger than the inventory: it is a kinetic ceiling,
    // not the scale of the methane mass-balance residual.
    inputs.maximum_methane_oxidation_g_c = 1e-4;
    var options = testOptions();
    options.absolute_tolerance_g_c = 1e-11;
    options.relative_tolerance = 1e-8;

    const result = try solve(inputs, options);
    const after = result.gaseous_methane_g_c + result.aqueous_methane_g_c +
        result.methane_oxidation_g_c + result.methane_carbon_uptake_g_c;
    try std.testing.expect(result.iterations > 0);
    try std.testing.expect(result.iterations < options.gas_max_iterations);
    try std.testing.expect(result.gaseous_methane_g_c >= 0);
    try std.testing.expect(result.aqueous_methane_g_c >= 0);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-12), after, 64.0 * std.math.floatEps(f64) * 1e-12);
}

test "hour-five storage snapshot in a near-saturated layer cannot gain fictitious methane" {
    var inputs = testInputs();
    inputs.gaseous_methane_g_c = 9.533225681585258e-12;
    inputs.aqueous_methane_g_c = 4.441881839736117e-6;
    inputs.gaseous_methane_flux_g_c = 0;
    inputs.aqueous_methane_flux_g_c = 0;
    inputs.methanogenesis_g_c = 0;
    inputs.water_volume_m3 = 2.5563193262659184e-1;
    // The gas/aqueous inventories and kinetic ceiling are the production
    // hour-five diagnostic values. A tiny synthetic positive air volume
    // isolates that observed near-saturated-layer branch. Before this fix the
    // 1e-10-g numerical floor acted as gas storage and drove about 5e-11 g
    // into water although only 9.53e-12 g existed in gas.
    inputs.air_volume_m3 = 1e-12;
    inputs.methane_solubility_water_to_air = 0.03;
    inputs.gas_exchange_rate_per_step = 0.5;
    inputs.maximum_methane_oxidation_g_c = 3.1246793590411444e-4;
    inputs.methane_half_saturation_g_c_per_m3 = 0.2;
    inputs.biomass_conversion_efficiency_g_c_per_g_c = 0.4;
    inputs.growth_respiration_g_c_per_g_c = 0.5;
    inputs.maintenance_respiration_g_c = 1e-5;
    var options = testOptions();
    options.absolute_tolerance_g_c = 1e-10;
    options.relative_tolerance = 1e-8;

    const before = inputs.gaseous_methane_g_c + inputs.aqueous_methane_g_c;
    const result = try solve(inputs, options);
    const after = result.gaseous_methane_g_c + result.aqueous_methane_g_c +
        result.methane_oxidation_g_c + result.methane_carbon_uptake_g_c;
    try std.testing.expect(result.iterations > 0);
    try std.testing.expect(result.gaseous_methane_g_c >= 0);
    try std.testing.expect(result.gas_to_water_exchange_g_c <= inputs.gaseous_methane_g_c);
    try std.testing.expectApproxEqAbs(before, after, 64.0 * std.math.floatEps(f64) * before);
}

test "maintenance-limited methane partition preserves exact zero net gain" {
    var inputs = testInputs();
    inputs.biomass_conversion_efficiency_g_c_per_g_c = 0.75;
    inputs.growth_respiration_g_c_per_g_c = 0.27322404371584696;
    inputs.maintenance_respiration_g_c = 1;
    const consumption_g_c = 5.686578522290372e-57;
    const partition = conservedCarbonPartition(inputs, consumption_g_c);
    try std.testing.expectEqual(consumption_g_c, partition.total_consumption_g_c);
    try std.testing.expectEqual(partition.respiration_g_c, partition.uptake_g_c);
    try std.testing.expectEqual(@as(f64, 0), partition.nonstructural_gain_g_c);
    try std.testing.expect(partition.respiration_g_c >= 0);
}

test "subnormal methane trace is preserved without nonlinear iterations" {
    var inputs = testInputs();
    inputs.gaseous_methane_g_c = 4.0e-314;
    inputs.aqueous_methane_g_c = 4.0e-315;
    inputs.gaseous_methane_flux_g_c = 0;
    inputs.aqueous_methane_flux_g_c = 0;
    inputs.methanogenesis_g_c = 0;
    const result = try solve(inputs, testOptions());
    try std.testing.expectEqual(inputs.gaseous_methane_g_c, result.gaseous_methane_g_c);
    try std.testing.expectEqual(inputs.aqueous_methane_g_c, result.aqueous_methane_g_c);
    try std.testing.expectEqual(@as(f64, 0), result.methane_oxidation_g_c);
    try std.testing.expectEqual(@as(u16, 0), result.iterations);
}

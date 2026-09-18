const std = @import("std");
const numerics = @import("../../core/numerics.zig");

/// Runtime inputs shared by the direct/diffuse C3 and C4 convergence blocks in
/// GROSUB. Compensation point and electron requirement select pathway science.
pub const Inputs = struct {
    canopy_air_co2_umol_per_mol: f64,
    co2_solubility_umol_per_l_per_umol_per_mol: f64,
    compensation_point_umol_per_l: f64,
    electron_requirement_umol_e_per_umol_co2: f64,
    maximum_carboxylation_umol_per_m2_s: f64,
    carboxylation_half_saturation_umol_per_l: f64,
    electron_transport_umol_e_per_m2_s: f64,
    water_stress_fraction: f64,
    biochemical_feedback_fraction: f64,
    stomatal_conductance_mol_per_m2_s: f64,
};

pub const Result = struct {
    intercellular_co2_umol_per_mol: f64,
    carboxylation_umol_per_m2_s: f64,
    diffusion_umol_per_m2_s: f64,
    normalized_mismatch: f64,
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
};

const Context = struct { inputs: Inputs };

/// Solves the legacy carboxylation=diffusion balance with the process ceiling
/// already clamped to the user's hard maximum and the 0.005 mismatch criterion.
pub fn solve(inputs: Inputs, initial_intercellular_co2_umol_per_mol: f64, picard_relaxation: f64, max_iterations: u16) !Result {
    try validate(inputs);
    const context: Context = .{ .inputs = inputs };
    const solved = try numerics.newtonPicard(context, residual, residualDerivative, picard, 0, inputs.canopy_air_co2_umol_per_mol, initial_intercellular_co2_umol_per_mol, .{
        .absolute_tolerance = 0.005,
        .relative_tolerance = std.math.floatEps(f64),
        .residual_scale = 1,
        .picard_relaxation = picard_relaxation,
        .max_iterations = max_iterations,
    });
    const rates = ratesAt(inputs, solved.root);
    return .{ .intercellular_co2_umol_per_mol = solved.root, .carboxylation_umol_per_m2_s = rates.carboxylation, .diffusion_umol_per_m2_s = rates.diffusion, .normalized_mismatch = solved.residual, .iterations = solved.iterations, .newton_raphson_steps = solved.newton_raphson_steps, .picard_steps = solved.picard_steps };
}

fn residualDerivative(context: Context, intercellular_co2_umol_per_mol: f64) f64 {
    const span = context.inputs.canopy_air_co2_umol_per_mol;
    const step = @max(1.0e-3, 1.0e-3 * span);
    const lower = @max(0, intercellular_co2_umol_per_mol - step);
    const upper = @min(span, intercellular_co2_umol_per_mol + step);
    if (upper <= lower) return std.math.nan(f64);
    return (residual(context, upper) - residual(context, lower)) /
        (upper - lower);
}

const Rates = struct { carboxylation: f64, diffusion: f64 };

fn ratesAt(inputs: Inputs, intercellular_co2_umol_per_mol: f64) Rates {
    const dissolved_co2 = intercellular_co2_umol_per_mol * inputs.co2_solubility_umol_per_l_per_umol_per_mol;
    const co2_above_compensation = @max(0.0, dissolved_co2 - inputs.compensation_point_umol_per_l);
    const carboxylation_efficiency = co2_above_compensation / (inputs.electron_requirement_umol_e_per_umol_co2 * dissolved_co2 + 10.5 * inputs.compensation_point_umol_per_l);
    const co2_limited = inputs.maximum_carboxylation_umol_per_m2_s * co2_above_compensation / (dissolved_co2 + inputs.carboxylation_half_saturation_umol_per_l);
    const light_limited = inputs.electron_transport_umol_e_per_m2_s * carboxylation_efficiency;
    return .{
        .carboxylation = @min(co2_limited, light_limited) * inputs.water_stress_fraction * inputs.biochemical_feedback_fraction,
        .diffusion = (inputs.canopy_air_co2_umol_per_mol - intercellular_co2_umol_per_mol) * inputs.stomatal_conductance_mol_per_m2_s,
    };
}

fn residual(context: Context, intercellular_co2_umol_per_mol: f64) f64 {
    const rates = ratesAt(context.inputs, intercellular_co2_umol_per_mol);
    const sum = rates.carboxylation + rates.diffusion;
    return if (sum > 0) (rates.carboxylation - rates.diffusion) / sum else 0;
}

/// GROSUB's process map uses 95% diffusion and 5% carboxylation when updating
/// intercellular CO2. Generic under-relaxation remains outside this map.
fn picard(context: Context, intercellular_co2_umol_per_mol: f64) f64 {
    const rates = ratesAt(context.inputs, intercellular_co2_umol_per_mol);
    const blended_rate = 0.95 * rates.diffusion + 0.05 * rates.carboxylation;
    return context.inputs.canopy_air_co2_umol_per_mol - blended_rate / context.inputs.stomatal_conductance_mol_per_m2_s;
}

fn validate(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteLeafCo2Input;
    if (inputs.canopy_air_co2_umol_per_mol <= 0 or inputs.co2_solubility_umol_per_l_per_umol_per_mol <= 0 or inputs.compensation_point_umol_per_l < 0 or inputs.electron_requirement_umol_e_per_umol_co2 <= 0 or inputs.maximum_carboxylation_umol_per_m2_s < 0 or inputs.carboxylation_half_saturation_umol_per_l <= 0 or inputs.electron_transport_umol_e_per_m2_s < 0 or inputs.water_stress_fraction < 0 or inputs.water_stress_fraction > 1 or inputs.biochemical_feedback_fraction < 0 or inputs.biochemical_feedback_fraction > 1 or inputs.stomatal_conductance_mol_per_m2_s <= 0) return error.InvalidLeafCo2Input;
}

test "C3 leaf CO2 balance converges before legacy ceiling" {
    const result = try solve(.{ .canopy_air_co2_umol_per_mol = 420, .co2_solubility_umol_per_l_per_umol_per_mol = 0.03, .compensation_point_umol_per_l = 1.2, .electron_requirement_umol_e_per_umol_co2 = 4, .maximum_carboxylation_umol_per_m2_s = 75, .carboxylation_half_saturation_umol_per_l = 15, .electron_transport_umol_e_per_m2_s = 150, .water_stress_fraction = 0.9, .biochemical_feedback_fraction = 1, .stomatal_conductance_mol_per_m2_s = 0.2 }, 280, 0.5, 100);
    try std.testing.expect(result.iterations < 100);
    try std.testing.expect(@abs(result.normalized_mismatch) <= 0.005 + 1.0e-12);
    try std.testing.expectApproxEqRel(result.carboxylation_umol_per_m2_s, result.diffusion_umol_per_m2_s, 0.011);
}

test "C4 leaf CO2 balance uses the same bounded solver" {
    const result = try solve(.{ .canopy_air_co2_umol_per_mol = 420, .co2_solubility_umol_per_l_per_umol_per_mol = 0.03, .compensation_point_umol_per_l = 0.2, .electron_requirement_umol_e_per_umol_co2 = 5, .maximum_carboxylation_umol_per_m2_s = 80, .carboxylation_half_saturation_umol_per_l = 10, .electron_transport_umol_e_per_m2_s = 180, .water_stress_fraction = 1, .biochemical_feedback_fraction = 0.95, .stomatal_conductance_mol_per_m2_s = 0.25 }, 300, 0.5, 100);
    try std.testing.expect(result.iterations < 100);
    try std.testing.expect(@abs(result.normalized_mismatch) <= 0.005 + 1.0e-12);
}

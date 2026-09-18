const std = @import("std");

pub const Inputs = struct {
    leaf_carbon_g_c: f64,
    leaf_protein_surface_density_g_per_m2: f64,
    mesophyll_nonstructural_carbon_g_c: f64,
    bundle_sheath_co2_carbon_g_c: f64,
    mesophyll_water_g_per_g_c: f64,
    bundle_sheath_water_g_per_g_c: f64,
    mesophyll_feedback_half_saturation_umol_per_l: f64,
    annual_termination_fraction: f64,
    pep_carboxylase_protein_fraction: f64,
    mesophyll_chlorophyll_protein_fraction: f64,
    pep_carboxylation_umol_per_g_s_25c: f64,
    carboxylation_temperature_factor: f64,
    dissolved_co2_umol_per_l: f64,
    co2_compensation_umol_per_l: f64,
    pep_co2_half_saturation_umol_per_l: f64,
    chlorophyll_electron_transport_umol_per_g_s_25c: f64,
    electron_transport_temperature_factor: f64,
    electron_requirement_umol_e_per_umol_co2: f64,
};

pub const Result = struct {
    mesophyll_nonstructural_carbon_umol_per_l: f64,
    bundle_sheath_co2_umol_per_l: f64,
    feedback_fraction: f64,
    pep_carboxylase_surface_density_g_per_m2: f64,
    chlorophyll_surface_density_g_per_m2: f64,
    co2_unlimited_carboxylation_umol_per_m2_s: f64,
    co2_limited_carboxylation_umol_per_m2_s: f64,
    light_saturated_electron_transport_umol_per_m2_s: f64,
    carboxylation_umol_co2_per_umol_electron: f64,
};

/// STOMATE.F 246--297 C4 feedback and capacity in source assignment order.
pub fn compute(inputs: Inputs) !Result {
    try validate(inputs);
    var result: Result = undefined;
    result.mesophyll_nonstructural_carbon_umol_per_l = @max(
        0,
        0.021e9 * inputs.mesophyll_nonstructural_carbon_g_c /
            (inputs.leaf_carbon_g_c * inputs.mesophyll_water_g_per_g_c),
    );
    result.bundle_sheath_co2_umol_per_l = @max(
        0,
        0.083e9 * inputs.bundle_sheath_co2_carbon_g_c /
            (inputs.leaf_carbon_g_c * inputs.bundle_sheath_water_g_per_g_c),
    );
    result.feedback_fraction =
        1 / (1 + result.mesophyll_nonstructural_carbon_umol_per_l /
            inputs.mesophyll_feedback_half_saturation_umol_per_l);
    result.feedback_fraction *= inputs.annual_termination_fraction;
    result.pep_carboxylase_surface_density_g_per_m2 =
        inputs.pep_carboxylase_protein_fraction *
        inputs.leaf_protein_surface_density_g_per_m2;
    result.chlorophyll_surface_density_g_per_m2 =
        inputs.mesophyll_chlorophyll_protein_fraction *
        inputs.leaf_protein_surface_density_g_per_m2;
    result.co2_unlimited_carboxylation_umol_per_m2_s =
        inputs.pep_carboxylation_umol_per_g_s_25c *
        inputs.carboxylation_temperature_factor *
        result.pep_carboxylase_surface_density_g_per_m2;
    result.co2_limited_carboxylation_umol_per_m2_s = @max(
        0,
        result.co2_unlimited_carboxylation_umol_per_m2_s *
            (inputs.dissolved_co2_umol_per_l -
                inputs.co2_compensation_umol_per_l) /
            (inputs.dissolved_co2_umol_per_l +
                inputs.pep_co2_half_saturation_umol_per_l),
    );
    result.light_saturated_electron_transport_umol_per_m2_s =
        inputs.chlorophyll_electron_transport_umol_per_g_s_25c *
        inputs.electron_transport_temperature_factor *
        result.chlorophyll_surface_density_g_per_m2;
    result.carboxylation_umol_co2_per_umol_electron = @max(
        0,
        (inputs.dissolved_co2_umol_per_l -
            inputs.co2_compensation_umol_per_l) /
            (inputs.electron_requirement_umol_e_per_umol_co2 *
                inputs.dissolved_co2_umol_per_l +
                10.5 * inputs.co2_compensation_umol_per_l),
    );
    inline for (@typeInfo(Result).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteCanopyC4CapacityResult;
    return result;
}

pub fn computeRuntimeNodes(
    inputs: []const Inputs,
    scratch: []Result,
    destination: []Result,
) !void {
    if (inputs.len != scratch.len or inputs.len != destination.len)
        return error.CanopyC4CapacityDimensionMismatch;
    for (inputs, scratch) |node_inputs, *candidate|
        candidate.* = try compute(node_inputs);
    @memcpy(destination, scratch);
}

fn validate(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteCanopyC4CapacityInput;
    if (inputs.leaf_carbon_g_c <= 0 or
        inputs.leaf_protein_surface_density_g_per_m2 <= 0 or
        inputs.mesophyll_nonstructural_carbon_g_c < 0 or
        inputs.bundle_sheath_co2_carbon_g_c < 0 or
        inputs.mesophyll_water_g_per_g_c <= 0 or
        inputs.bundle_sheath_water_g_per_g_c <= 0 or
        inputs.mesophyll_feedback_half_saturation_umol_per_l <= 0 or
        inputs.annual_termination_fraction < 0 or
        inputs.annual_termination_fraction > 1 or
        inputs.pep_carboxylase_protein_fraction < 0 or
        inputs.mesophyll_chlorophyll_protein_fraction < 0 or
        inputs.pep_carboxylation_umol_per_g_s_25c < 0 or
        inputs.carboxylation_temperature_factor < 0 or
        inputs.dissolved_co2_umol_per_l < 0 or
        inputs.co2_compensation_umol_per_l < 0 or
        inputs.pep_co2_half_saturation_umol_per_l <= 0 or
        inputs.chlorophyll_electron_transport_umol_per_g_s_25c < 0 or
        inputs.electron_transport_temperature_factor < 0 or
        inputs.electron_requirement_umol_e_per_umol_co2 <= 0)
        return error.InvalidCanopyC4CapacityInput;
}

fn compatibilityInputs() Inputs {
    return .{
        .leaf_carbon_g_c = 2,
        .leaf_protein_surface_density_g_per_m2 = 1.5,
        .mesophyll_nonstructural_carbon_g_c = 0.2,
        .bundle_sheath_co2_carbon_g_c = 0.1,
        .mesophyll_water_g_per_g_c = 4.8,
        .bundle_sheath_water_g_per_g_c = 1.2,
        .mesophyll_feedback_half_saturation_umol_per_l = 5e6,
        .annual_termination_fraction = 0.5,
        .pep_carboxylase_protein_fraction = 0.2,
        .mesophyll_chlorophyll_protein_fraction = 0.1,
        .pep_carboxylation_umol_per_g_s_25c = 40,
        .carboxylation_temperature_factor = 0.8,
        .dissolved_co2_umol_per_l = 20,
        .co2_compensation_umol_per_l = 0.5,
        .pep_co2_half_saturation_umol_per_l = 10,
        .chlorophyll_electron_transport_umol_per_g_s_25c = 100,
        .electron_transport_temperature_factor = 0.9,
        .electron_requirement_umol_e_per_umol_co2 = 3,
    };
}

test "C4 capacity preserves source fields and annual feedback order" {
    const result = try compute(compatibilityInputs());
    try std.testing.expect(result.mesophyll_nonstructural_carbon_umol_per_l > 0);
    try std.testing.expect(result.bundle_sheath_co2_umol_per_l > 0);
    try std.testing.expect(result.feedback_fraction < 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), result.pep_carboxylase_surface_density_g_per_m2, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), result.chlorophyll_surface_density_g_per_m2, 1e-15);
}

test "shared compatibility outputs reconcile with existing c4Capacity" {
    const stomatal = @import("../energy/stomatal_resistance.zig");
    const inputs = compatibilityInputs();
    const gas: stomatal.GasEnvironment = .{
        .air_amount_mol_per_m3 = 1,
        .intercellular_co2_umol_per_mol = 1,
        .co2_solubility_umol_per_l_per_umol_per_mol = 1,
        .o2_solubility_umol_per_l_per_umol_per_mol = 1,
        .dissolved_co2_umol_per_l = inputs.dissolved_co2_umol_per_l,
        .dissolved_o2_umol_per_l = 1,
        .atmospheric_to_intercellular_co2_umol_per_m3 = 1,
        .rubisco_carboxylation_temperature_factor = inputs.carboxylation_temperature_factor,
        .rubisco_oxygenation_temperature_factor = 1,
        .electron_transport_temperature_factor = inputs.electron_transport_temperature_factor,
        .rubisco_co2_half_saturation_umol_per_l = 1,
        .rubisco_co2_half_saturation_with_o2_umol_per_l = 1,
        .rubisco_o2_half_saturation_umol_per_l = 1,
    };
    const existing = try stomatal.c4Capacity(
        inputs.leaf_carbon_g_c,
        inputs.leaf_protein_surface_density_g_per_m2,
        inputs.mesophyll_nonstructural_carbon_g_c,
        inputs.bundle_sheath_co2_carbon_g_c,
        inputs.pep_carboxylase_protein_fraction,
        inputs.mesophyll_chlorophyll_protein_fraction,
        inputs.pep_carboxylation_umol_per_g_s_25c,
        inputs.pep_co2_half_saturation_umol_per_l,
        inputs.chlorophyll_electron_transport_umol_per_g_s_25c,
        gas,
        inputs.annual_termination_fraction,
    );
    const result = try compute(inputs);
    try std.testing.expectApproxEqAbs(existing.mesophyll_nonstructural_c_umol_per_l, result.mesophyll_nonstructural_carbon_umol_per_l, 1e-12);
    try std.testing.expectApproxEqAbs(existing.bundle_sheath_nonstructural_c_umol_per_l, result.bundle_sheath_co2_umol_per_l, 1e-12);
    try std.testing.expectApproxEqAbs(existing.feedback_fraction, result.feedback_fraction, 1e-15);
    try std.testing.expectApproxEqAbs(existing.co2_unlimited_carboxylation_umol_per_m2_s, result.co2_unlimited_carboxylation_umol_per_m2_s, 1e-12);
    try std.testing.expectApproxEqAbs(existing.co2_limited_carboxylation_umol_per_m2_s, result.co2_limited_carboxylation_umol_per_m2_s, 1e-12);
    try std.testing.expectApproxEqAbs(existing.light_saturated_electron_transport_umol_per_m2_s, result.light_saturated_electron_transport_umol_per_m2_s, 1e-12);
    try std.testing.expectApproxEqAbs(existing.carboxylation_umol_co2_per_umol_electron, result.carboxylation_umol_co2_per_umol_electron, 1e-15);
}

test "later invalid runtime node leaves destination unchanged" {
    var invalid = compatibilityInputs();
    invalid.mesophyll_water_g_per_g_c = 0;
    const inputs = [_]Inputs{ compatibilityInputs(), invalid };
    var scratch: [2]Result = undefined;
    var destination: [2]Result = undefined;
    destination[0] = try compute(compatibilityInputs());
    destination[1] = destination[0];
    destination[0].feedback_fraction = 41;
    destination[1].feedback_fraction = 42;
    try std.testing.expectError(
        error.InvalidCanopyC4CapacityInput,
        computeRuntimeNodes(&inputs, &scratch, &destination),
    );
    try std.testing.expectEqual(@as(f64, 41), destination[0].feedback_fraction);
    try std.testing.expectEqual(@as(f64, 42), destination[1].feedback_fraction);
}

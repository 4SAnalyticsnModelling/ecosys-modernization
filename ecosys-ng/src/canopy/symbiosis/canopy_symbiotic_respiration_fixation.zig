const std = @import("std");

pub const BranchInputs = struct {
    structural_carbon_g_c: f64,
    structural_nitrogen_g_n: f64,
    nonstructural_carbon_g_c: f64,
    nutrient_activity_fraction: f64,
    canopy_growth_temperature_response: f64,
    canopy_growth_water_response: f64,
    canopy_maintenance_temperature_response: f64,
    canopy_maintenance_water_response: f64,
    nitrogen_per_nonstructural_carbon_g_n_per_g_c: f64,
    nitrogen_per_nonstructural_phosphorus_g_n_per_g_p: f64,
};

pub const Fluxes = struct {
    oxygen_unconstrained_respiration_g_c: f64,
    maintenance_respiration_g_c: f64,
    respiration_minus_maintenance_g_c: f64,
    growth_respiration_g_c: f64,
    senescence_respiration_g_c: f64,
    nitrogen_deficit_respiration_requirement_g_c: f64,
    nitrogen_fixation_respiration_g_c: f64,
    fixed_nitrogen_g_n: f64,
};

pub const Inputs = struct {
    fixation_type: u8,
    timestep_h: f64,
    growth_respiration_presence_threshold_g_c: f64,
    specific_respiration_per_h: f64,
    specific_maintenance_g_c_per_g_n_h: f64,
    target_nitrogen_per_carbon_g_n_per_g_c: f64,
    nitrogen_fixation_yield_g_n_per_g_c: f64,
    excess_nitrogen_inhibition_g_n_per_g_c: f64,
    excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p: f64,
};

/// Source-order UPNFC state_update from already time-normalized branch RUPNFB
/// diagnostics. Branches are summed in ascending NB order.
pub fn sumFixedNitrogenPerHour(branch_fixed_nitrogen_g_n_per_h: []const f64) !f64 {
    var total_g_n_per_h: f64 = 0;
    for (branch_fixed_nitrogen_g_n_per_h) |fixed_g_n_per_h| {
        if (!std.math.isFinite(fixed_g_n_per_h) or fixed_g_n_per_h < 0)
            return error.InvalidCanopySymbioticFixedNitrogenDiagnostic;
        total_g_n_per_h += fixed_g_n_per_h;
        if (!std.math.isFinite(total_g_n_per_h))
            return error.NonFinitePlantCanopyFixationTotal;
    }
    return total_g_n_per_h;
}

/// Exact grosub.f lines 5392--5442 canopy diazotroph respiration and N2
/// fixation in ascending NB order. Fluxes are per biological timestep.
/// `plant_fixed_nitrogen_g_n` is source UPNFC and is state_updateted only after the
/// entire runtime branch sweep succeeds.
pub fn calculateAll(
    branches: []const BranchInputs,
    outputs: []Fluxes,
    plant_fixed_nitrogen_g_n: *f64,
    inputs: Inputs,
) !void {
    if (branches.len == 0 or outputs.len != branches.len)
        return error.CanopySymbioticRespirationDimensionMismatch;
    if (inputs.fixation_type > 6) return error.InvalidSymbioticFixationType;
    if (inputs.fixation_type < 4) return;
    try validateInputs(inputs);
    if (!std.math.isFinite(plant_fixed_nitrogen_g_n.*) or plant_fixed_nitrogen_g_n.* < 0)
        return error.InvalidPlantCanopyFixationTotal;

    var next_total = plant_fixed_nitrogen_g_n.*;
    for (branches) |branch| {
        const fluxes = try calculateOne(branch, inputs);
        next_total += fluxes.fixed_nitrogen_g_n;
        if (!std.math.isFinite(next_total)) return error.NonFinitePlantCanopyFixationTotal;
    }
    for (branches, outputs) |branch, *output| output.* = try calculateOne(branch, inputs);
    plant_fixed_nitrogen_g_n.* = next_total;
}

fn calculateOne(branch: BranchInputs, inputs: Inputs) !Fluxes {
    inline for (@typeInfo(BranchInputs).@"struct".fields) |field| {
        const value = @field(branch, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidCanopySymbioticRespirationState;
    }
    if (branch.nutrient_activity_fraction > 1)
        return error.InvalidCanopySymbioticRespirationState;

    const respiration_numerator = @max(
        0,
        @min(branch.nonstructural_carbon_g_c, inputs.specific_respiration_per_h * branch.structural_carbon_g_c) *
            branch.nutrient_activity_fraction * branch.canopy_growth_temperature_response *
            branch.canopy_growth_water_response * inputs.timestep_h,
    );
    const oxygen_unconstrained_respiration = respiration_numerator /
        (1 + @max(
            branch.nitrogen_per_nonstructural_carbon_g_n_per_g_c / inputs.excess_nitrogen_inhibition_g_n_per_g_c,
            branch.nitrogen_per_nonstructural_phosphorus_g_n_per_g_p / inputs.excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p,
        ));
    const maintenance_respiration = @max(
        0,
        inputs.specific_maintenance_g_c_per_g_n_h * branch.canopy_maintenance_temperature_response *
            branch.structural_nitrogen_g_n * branch.canopy_maintenance_water_response * inputs.timestep_h,
    );
    const respiration_minus_maintenance = oxygen_unconstrained_respiration - maintenance_respiration;
    const growth_respiration = @max(0, respiration_minus_maintenance);
    const senescence_respiration = @max(0, -respiration_minus_maintenance);
    const nitrogen_deficit_requirement = @max(
        0,
        branch.structural_carbon_g_c * inputs.target_nitrogen_per_carbon_g_n_per_g_c - branch.structural_nitrogen_g_n,
    ) / inputs.nitrogen_fixation_yield_g_n_per_g_c;
    const fixation_respiration = if (growth_respiration > inputs.growth_respiration_presence_threshold_g_c)
        growth_respiration * nitrogen_deficit_requirement / (growth_respiration + nitrogen_deficit_requirement)
    else
        0;
    const result = Fluxes{
        .oxygen_unconstrained_respiration_g_c = oxygen_unconstrained_respiration,
        .maintenance_respiration_g_c = maintenance_respiration,
        .respiration_minus_maintenance_g_c = respiration_minus_maintenance,
        .growth_respiration_g_c = growth_respiration,
        .senescence_respiration_g_c = senescence_respiration,
        .nitrogen_deficit_respiration_requirement_g_c = nitrogen_deficit_requirement,
        .nitrogen_fixation_respiration_g_c = fixation_respiration,
        .fixed_nitrogen_g_n = fixation_respiration * inputs.nitrogen_fixation_yield_g_n_per_g_c,
    };
    inline for (@typeInfo(Fluxes).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteCanopySymbioticRespirationFlux;
    return result;
}

fn validateInputs(inputs: Inputs) !void {
    inline for (.{
        inputs.timestep_h,
        inputs.growth_respiration_presence_threshold_g_c,
        inputs.specific_respiration_per_h,
        inputs.specific_maintenance_g_c_per_g_n_h,
        inputs.target_nitrogen_per_carbon_g_n_per_g_c,
        inputs.nitrogen_fixation_yield_g_n_per_g_c,
        inputs.excess_nitrogen_inhibition_g_n_per_g_c,
        inputs.excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidCanopySymbioticRespirationInput;
    if (inputs.timestep_h == 0 or inputs.target_nitrogen_per_carbon_g_n_per_g_c == 0 or
        inputs.nitrogen_fixation_yield_g_n_per_g_c == 0 or
        inputs.excess_nitrogen_inhibition_g_n_per_g_c == 0 or
        inputs.excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p == 0)
        return error.InvalidCanopySymbioticRespirationInput;
}

fn testInputs() Inputs {
    return .{
        .fixation_type = 4,
        .timestep_h = 0.5,
        .growth_respiration_presence_threshold_g_c = 1.0e-12,
        .specific_respiration_per_h = 0.125,
        .specific_maintenance_g_c_per_g_n_h = 0.01,
        .target_nitrogen_per_carbon_g_n_per_g_c = 0.1,
        .nitrogen_fixation_yield_g_n_per_g_c = 0.25,
        .excess_nitrogen_inhibition_g_n_per_g_c = 10,
        .excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p = 1000,
    };
}

fn testBranch() BranchInputs {
    return .{
        .structural_carbon_g_c = 10,
        .structural_nitrogen_g_n = 0.5,
        .nonstructural_carbon_g_c = 2,
        .nutrient_activity_fraction = 0.8,
        .canopy_growth_temperature_response = 1.2,
        .canopy_growth_water_response = 0.75,
        .canopy_maintenance_temperature_response = 1.1,
        .canopy_maintenance_water_response = 0.9,
        .nitrogen_per_nonstructural_carbon_g_n_per_g_c = 0.05,
        .nitrogen_per_nonstructural_phosphorus_g_n_per_g_p = 5,
    };
}

test "GROSUB RCNDL through RUPNFB preserves source equation order" {
    var outputs: [1]Fluxes = undefined;
    var total_g_n: f64 = 0;
    const inputs = testInputs();
    const branch = testBranch();
    try calculateAll(&.{branch}, &outputs, &total_g_n, inputs);
    const expected_respiration = @max(0, @min(branch.nonstructural_carbon_g_c, inputs.specific_respiration_per_h * branch.structural_carbon_g_c) * branch.nutrient_activity_fraction * branch.canopy_growth_temperature_response * branch.canopy_growth_water_response * inputs.timestep_h) / (1 + @max(branch.nitrogen_per_nonstructural_carbon_g_n_per_g_c / inputs.excess_nitrogen_inhibition_g_n_per_g_c, branch.nitrogen_per_nonstructural_phosphorus_g_n_per_g_p / inputs.excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p));
    try std.testing.expectApproxEqAbs(expected_respiration, outputs[0].oxygen_unconstrained_respiration_g_c, 1e-15);
    try std.testing.expectEqual(outputs[0].fixed_nitrogen_g_n, total_g_n);
    try std.testing.expectApproxEqAbs(outputs[0].nitrogen_fixation_respiration_g_c * inputs.nitrogen_fixation_yield_g_n_per_g_c, outputs[0].fixed_nitrogen_g_n, 1e-15);
}

test "GROSUB growth threshold is strict and maintenance excess drives senescence" {
    var branch = testBranch();
    branch.nonstructural_carbon_g_c = 0;
    var outputs: [1]Fluxes = undefined;
    var total_g_n: f64 = 0;
    try calculateAll(&.{branch}, &outputs, &total_g_n, testInputs());
    try std.testing.expectEqual(@as(f64, 0), outputs[0].growth_respiration_g_c);
    try std.testing.expect(outputs[0].senescence_respiration_g_c > 0);
    try std.testing.expectEqual(@as(f64, 0), outputs[0].fixed_nitrogen_g_n);
}

test "GROSUB root fixation type leaves canopy outputs and total unchanged" {
    var outputs: [1]Fluxes = undefined;
    outputs[0].fixed_nitrogen_g_n = 19;
    var total_g_n: f64 = std.math.nan(f64);
    var inputs = testInputs();
    inputs.fixation_type = 3;
    var branch = testBranch();
    branch.structural_carbon_g_c = std.math.nan(f64);
    try calculateAll(&.{branch}, &outputs, &total_g_n, inputs);
    try std.testing.expect(std.math.isNan(total_g_n));
    try std.testing.expectEqual(@as(f64, 19), outputs[0].fixed_nitrogen_g_n);
}

test "GROSUB fixation sweep supports runtime branches and atomically accumulates UPNFC" {
    var branches = [_]BranchInputs{testBranch()} ** 43;
    var outputs: [43]Fluxes = undefined;
    var total_g_n: f64 = 2;
    try calculateAll(&branches, &outputs, &total_g_n, testInputs());
    var expected: f64 = 2;
    for (outputs) |output| expected += output.fixed_nitrogen_g_n;
    try std.testing.expectEqual(expected, total_g_n);

    const before_outputs = outputs;
    const before_total = total_g_n;
    branches[42].structural_nitrogen_g_n = std.math.nan(f64);
    try std.testing.expectError(error.InvalidCanopySymbioticRespirationState, calculateAll(&branches, &outputs, &total_g_n, testInputs()));
    try std.testing.expectEqualDeep(before_outputs, outputs);
    try std.testing.expectEqual(before_total, total_g_n);
}

test "GROSUB UPNFC state_update sums runtime branches in ascending source order" {
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.6),
        try sumFixedNitrogenPerHour(&.{ 0.1, 0.2, 0.3 }),
        1e-15,
    );
    try std.testing.expectError(
        error.InvalidCanopySymbioticFixedNitrogenDiagnostic,
        sumFixedNitrogenPerHour(&.{ 0.1, std.math.nan(f64) }),
    );
}

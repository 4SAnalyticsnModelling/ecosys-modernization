const std = @import("std");

pub const Inputs = struct {
    canopy_temperature_c: f64,
    air_amount_mol_per_m3: f64,
    atmospheric_co2_umol_per_mol: f64,
    intercellular_co2_umol_per_mol: f64,
    intercellular_o2_umol_per_mol: f64,
};

pub const Result = struct {
    co2_solubility_umol_per_l_per_umol_per_mol: f64,
    o2_solubility_umol_per_l_per_umol_per_mol: f64,
    dissolved_co2_umol_per_l: f64,
    dissolved_o2_umol_per_l: f64,
    atmospheric_to_intercellular_co2_umol_per_m3: f64,
};

/// STOMATE.F 69--73 aqueous solubility, dissolved gas, and atmospheric-
/// intercellular CO2 difference in exact source assignment order.
pub fn compute(inputs: Inputs) !Result {
    try validate(inputs);
    var result: Result = undefined;
    result.co2_solubility_umol_per_l_per_umol_per_mol =
        @exp(-2.621 - 0.0317 * inputs.canopy_temperature_c);
    result.o2_solubility_umol_per_l_per_umol_per_mol =
        @exp(-6.175 - 0.0211 * inputs.canopy_temperature_c);
    result.dissolved_co2_umol_per_l =
        inputs.intercellular_co2_umol_per_mol *
        result.co2_solubility_umol_per_l_per_umol_per_mol;
    result.dissolved_o2_umol_per_l =
        inputs.intercellular_o2_umol_per_mol *
        result.o2_solubility_umol_per_l_per_umol_per_mol;
    result.atmospheric_to_intercellular_co2_umol_per_m3 =
        inputs.air_amount_mol_per_m3 *
        (inputs.atmospheric_co2_umol_per_mol -
            inputs.intercellular_co2_umol_per_mol);
    inline for (@typeInfo(Result).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteCanopyAqueousGasResult;
    return result;
}

pub fn computeRuntimeAxes(
    inputs: []const Inputs,
    scratch: []Result,
    destination: []Result,
) !void {
    if (inputs.len != scratch.len or inputs.len != destination.len)
        return error.CanopyAqueousGasDimensionMismatch;
    for (inputs, scratch) |axis_inputs, *candidate|
        candidate.* = try compute(axis_inputs);
    @memcpy(destination, scratch);
}

fn validate(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteCanopyAqueousGasInput;
    if (inputs.canopy_temperature_c <= -273.15 or
        inputs.air_amount_mol_per_m3 <= 0 or
        inputs.atmospheric_co2_umol_per_mol < 0 or
        inputs.intercellular_co2_umol_per_mol < 0 or
        inputs.intercellular_o2_umol_per_mol < 0)
        return error.InvalidCanopyAqueousGasInput;
}

fn testInputs() Inputs {
    return .{
        .canopy_temperature_c = 25,
        .air_amount_mol_per_m3 = @as(f64, 12_194) / 298.15,
        .atmospheric_co2_umol_per_mol = 400,
        .intercellular_co2_umol_per_mol = 280,
        .intercellular_o2_umol_per_mol = 210_000,
    };
}

test "aqueous gas environment preserves all five source assignments" {
    const inputs = testInputs();
    const result = try compute(inputs);
    const expected_co2_solubility = @exp(-2.621 - 0.0317 * 25);
    const expected_o2_solubility = @exp(-6.175 - 0.0211 * 25);
    try std.testing.expectEqual(
        expected_co2_solubility,
        result.co2_solubility_umol_per_l_per_umol_per_mol,
    );
    try std.testing.expectEqual(
        expected_o2_solubility,
        result.o2_solubility_umol_per_l_per_umol_per_mol,
    );
    try std.testing.expectEqual(
        @as(f64, 280) * expected_co2_solubility,
        result.dissolved_co2_umol_per_l,
    );
    try std.testing.expectEqual(
        @as(f64, 210_000) * expected_o2_solubility,
        result.dissolved_o2_umol_per_l,
    );
    try std.testing.expectEqual(
        inputs.air_amount_mol_per_m3 * 120,
        result.atmospheric_to_intercellular_co2_umol_per_m3,
    );
}

test "zero intercellular CO2 retains finite explicit solubility" {
    var inputs = testInputs();
    inputs.intercellular_co2_umol_per_mol = 0;
    const result = try compute(inputs);
    try std.testing.expect(std.math.isFinite(
        result.co2_solubility_umol_per_l_per_umol_per_mol,
    ));
    try std.testing.expectEqual(@as(f64, 0), result.dissolved_co2_umol_per_l);
}

test "runtime axes preserve independent cell and species values" {
    var second = testInputs();
    second.canopy_temperature_c = 5;
    const inputs = [_]Inputs{ testInputs(), second };
    var scratch: [2]Result = undefined;
    var destination: [2]Result = undefined;
    try computeRuntimeAxes(&inputs, &scratch, &destination);
    try std.testing.expect(
        destination[1].co2_solubility_umol_per_l_per_umol_per_mol >
            destination[0].co2_solubility_umol_per_l_per_umol_per_mol,
    );
}

test "later nonfinite axis leaves destination unchanged" {
    var second = testInputs();
    second.intercellular_o2_umol_per_mol = std.math.nan(f64);
    const inputs = [_]Inputs{ testInputs(), second };
    var scratch: [2]Result = undefined;
    var destination: [2]Result = undefined;
    destination[0] = try compute(testInputs());
    destination[1] = destination[0];
    destination[0].dissolved_co2_umol_per_l = 41;
    destination[1].dissolved_co2_umol_per_l = 42;
    try std.testing.expectError(
        error.NonFiniteCanopyAqueousGasInput,
        computeRuntimeAxes(&inputs, &scratch, &destination),
    );
    try std.testing.expectEqual(@as(f64, 41), destination[0].dissolved_co2_umol_per_l);
    try std.testing.expectEqual(@as(f64, 42), destination[1].dissolved_co2_umol_per_l);
}

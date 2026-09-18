const std = @import("std");

pub const Inputs = struct {
    photosynthesis_active: bool,
    canopy_co2_fixation_umol_per_s: f64,
    negligible_fixation_umol_per_s: f64,
    canopy_radiation_fraction: f64,
    co2_concentration_difference_umol_per_m3: f64,
    horizontal_cell_area_m2: f64,
    seconds_per_hour: f64,
    cuticular_water_vapor_resistance_h_per_m: f64,
    co2_to_water_cuticular_resistance_ratio: f64,
    minimum_co2_stomatal_resistance_h_per_m: f64,
    co2_to_water_stomatal_resistance_ratio: f64,
};

/// STOMATE.F lines 656--665 in source branch and assignment order.
pub fn compute(inputs: Inputs) !f64 {
    try validate(inputs);
    if (!inputs.photosynthesis_active)
        return inputs.cuticular_water_vapor_resistance_h_per_m;

    const co2_resistance_h_per_m =
        if (inputs.canopy_co2_fixation_umol_per_s >
        inputs.negligible_fixation_umol_per_s)
            inputs.canopy_radiation_fraction *
                inputs.co2_concentration_difference_umol_per_m3 *
                inputs.horizontal_cell_area_m2 /
                (inputs.canopy_co2_fixation_umol_per_s *
                    inputs.seconds_per_hour)
        else
            inputs.cuticular_water_vapor_resistance_h_per_m *
                inputs.co2_to_water_cuticular_resistance_ratio;
    const result = @min(
        inputs.cuticular_water_vapor_resistance_h_per_m,
        @max(
            inputs.minimum_co2_stomatal_resistance_h_per_m,
            co2_resistance_h_per_m *
                inputs.co2_to_water_stomatal_resistance_ratio,
        ),
    );
    if (!std.math.isFinite(result))
        return error.NonFiniteMinimumStomatalResistanceResult;
    return result;
}

pub fn computeRuntimePlants(
    inputs: []const Inputs,
    scratch_h_per_m: []f64,
    destination_h_per_m: []f64,
) !void {
    if (inputs.len != scratch_h_per_m.len or inputs.len != destination_h_per_m.len)
        return error.MinimumStomatalResistanceDimensionMismatch;
    for (inputs, scratch_h_per_m) |plant_inputs, *candidate|
        candidate.* = try compute(plant_inputs);
    @memcpy(destination_h_per_m, scratch_h_per_m);
}

fn validate(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteMinimumStomatalResistanceInput;
    }
    if (inputs.canopy_co2_fixation_umol_per_s < 0 or
        inputs.negligible_fixation_umol_per_s < 0 or
        inputs.canopy_radiation_fraction < 0 or
        inputs.canopy_radiation_fraction > 1 or
        inputs.co2_concentration_difference_umol_per_m3 < 0 or
        inputs.horizontal_cell_area_m2 <= 0 or
        inputs.seconds_per_hour <= 0 or
        inputs.cuticular_water_vapor_resistance_h_per_m < 0 or
        inputs.co2_to_water_cuticular_resistance_ratio <= 0 or
        inputs.minimum_co2_stomatal_resistance_h_per_m < 0 or
        inputs.co2_to_water_stomatal_resistance_ratio <= 0)
        return error.InvalidMinimumStomatalResistanceInput;
}

fn fixture() Inputs {
    return .{
        .photosynthesis_active = true,
        .canopy_co2_fixation_umol_per_s = 100,
        .negligible_fixation_umol_per_s = 1.0e-12,
        .canopy_radiation_fraction = 1,
        .co2_concentration_difference_umol_per_m3 = 100,
        .horizontal_cell_area_m2 = 1,
        .seconds_per_hour = 3600,
        .cuticular_water_vapor_resistance_h_per_m = 0.01,
        .co2_to_water_cuticular_resistance_ratio = 1.56,
        .minimum_co2_stomatal_resistance_h_per_m = 2.78e-3,
        .co2_to_water_stomatal_resistance_ratio = 0.641,
    };
}

test "minimum stomatal resistance reconciles active source branches" {
    const stomatal = @import("stomatal_resistance.zig");
    var inputs = fixture();
    const result = try compute(inputs);
    const existing = try stomatal.minimumWaterVaporResistanceHPerM(
        inputs.canopy_co2_fixation_umol_per_s,
        inputs.canopy_radiation_fraction,
        inputs.co2_concentration_difference_umol_per_m3,
        inputs.horizontal_cell_area_m2,
        inputs.cuticular_water_vapor_resistance_h_per_m,
        true,
    );
    try std.testing.expectEqual(existing, result);

    inputs.canopy_co2_fixation_umol_per_s = 0;
    try std.testing.expectEqual(
        inputs.cuticular_water_vapor_resistance_h_per_m *
            inputs.co2_to_water_cuticular_resistance_ratio *
            inputs.co2_to_water_stomatal_resistance_ratio,
        try compute(inputs),
    );
}

test "inactive photosynthesis retains exact cuticular resistance" {
    var inputs = fixture();
    inputs.photosynthesis_active = false;
    try std.testing.expectEqual(
        inputs.cuticular_water_vapor_resistance_h_per_m,
        try compute(inputs),
    );
}

test "later invalid runtime plant leaves all resistances unchanged" {
    var invalid = fixture();
    invalid.seconds_per_hour = 0;
    const inputs = [_]Inputs{ fixture(), invalid };
    var scratch: [2]f64 = undefined;
    var destination = [_]f64{ 41, 42 };
    try std.testing.expectError(
        error.InvalidMinimumStomatalResistanceInput,
        computeRuntimePlants(&inputs, &scratch, &destination),
    );
    try std.testing.expectEqualSlices(f64, &.{ 41, 42 }, &destination);
}

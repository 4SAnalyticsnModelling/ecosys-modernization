// **SOIL-PSISO-001: RESOLVED, but this module is still not the binding site.**
// The osmotic term `-8.3143E-06*TKS*CION` (`hour1.f:4181`) is now applied
// directly inside `soil/runtime/hourly_workspace.zig:refresh`, reading CION
// per layer from the production SOLUTE chemistry state via
// `chemistry_state.State.activityCoefficients`, rather than through this
// module's `calculate`. That is deliberate, not an oversight: `calculate`
// also recomputes the gravimetric head, and `hourly_workspace.zig:138`
// already publishes that term, so calling `calculate` whole would
// double-count it. This module remains a faithful, independently tested
// translation of `hour1.f:4181--4184` (osmotic term at `:38--39`, gravimetric
// head at `:40--41`, the `AMIN1(0.0, PSISM+PSISO+PSISH)` clamp at
// `:42--47`), kept for reference and for any future caller that genuinely
// wants the whole three-term law in one place rather than the gravimetric
// and osmotic halves assembled separately as production now does.
//
// soil osmotic potential group of docs/discrepancy_register.md SOIL-PSISO-001

const std = @import("std");

pub const Inputs = struct {
    matric_potential_megapascal: f64,
    soil_temperature_k: f64,
    total_ion_activity_mol_m3: f64,
    surface_elevation_m: f64,
    layer_midpoint_depth_below_surface_m: f64,
};

pub const Result = struct {
    osmotic_potential_megapascal: f64,
    gravitational_potential_megapascal: f64,
    total_potential_megapascal: f64,
};

pub const CalculationError = error{
    NonFiniteInput,
    InvalidMatricPotential,
    InvalidSoilTemperature,
    NegativeIonActivity,
    NegativeLayerDepth,
    NonFiniteResult,
};

/// Translates `hour1.f` lines 4181--4184 while making the elevation reference
/// explicit. Matric potential is supplied by the Mualem-van Genuchten solver.
pub fn calculate(inputs: Inputs) CalculationError!Result {
    inline for (std.meta.fields(Inputs)) |field| {
        if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteInput;
    }
    if (inputs.matric_potential_megapascal > 0.0) return error.InvalidMatricPotential;
    if (inputs.soil_temperature_k <= 0.0) return error.InvalidSoilTemperature;
    if (inputs.total_ion_activity_mol_m3 < 0.0) return error.NegativeIonActivity;
    if (inputs.layer_midpoint_depth_below_surface_m < 0.0) return error.NegativeLayerDepth;

    const osmotic_potential_megapascal =
        -8.3143e-6 * inputs.soil_temperature_k * inputs.total_ion_activity_mol_m3;
    const layer_midpoint_elevation_m =
        inputs.surface_elevation_m - inputs.layer_midpoint_depth_below_surface_m;
    const gravitational_potential_megapascal = 0.0098 * layer_midpoint_elevation_m;
    const total_potential_megapascal = @min(
        0.0,
        inputs.matric_potential_megapascal +
            osmotic_potential_megapascal +
            gravitational_potential_megapascal,
    );
    const result = Result{
        .osmotic_potential_megapascal = osmotic_potential_megapascal,
        .gravitational_potential_megapascal = gravitational_potential_megapascal,
        .total_potential_megapascal = total_potential_megapascal,
    };
    inline for (std.meta.fields(Result)) |field| {
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteResult;
    }
    return result;
}

test "water potential includes absolute layer elevation" {
    const result = try calculate(.{
        .matric_potential_megapascal = -0.1,
        .soil_temperature_k = 280.0,
        .total_ion_activity_mol_m3 = 10.0,
        .surface_elevation_m = 100.0,
        .layer_midpoint_depth_below_surface_m = 2.0,
    });
    const expected_osmotic = -8.3143e-6 * 280.0 * 10.0;
    const expected_gravitational = 0.0098 * (100.0 - 2.0);
    try std.testing.expectEqual(expected_osmotic, result.osmotic_potential_megapascal);
    try std.testing.expectApproxEqAbs(
        expected_gravitational,
        result.gravitational_potential_megapascal,
        1.0e-15,
    );
    try std.testing.expectEqual(@as(f64, 0.0), result.total_potential_megapascal);
}

test "negative absolute elevation lowers total potential" {
    const result = try calculate(.{
        .matric_potential_megapascal = -0.1,
        .soil_temperature_k = 273.15,
        .total_ion_activity_mol_m3 = 0.0,
        .surface_elevation_m = -10.0,
        .layer_midpoint_depth_below_surface_m = 5.0,
    });
    try std.testing.expectEqual(@as(f64, -0.147), result.gravitational_potential_megapascal);
    try std.testing.expectEqual(@as(f64, -0.247), result.total_potential_megapascal);
}

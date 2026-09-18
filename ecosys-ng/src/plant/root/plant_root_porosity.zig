const std = @import("std");

pub const Parameters = struct {
    maximum_porosity_fraction: f64,
    oxygen_stress_induction_fraction_per_h: f64,
    relaxation_fraction_per_h: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.NonFiniteRootPorosityParameter;
        if (self.maximum_porosity_fraction <= 0 or self.maximum_porosity_fraction >= 1 or
            self.oxygen_stress_induction_fraction_per_h < 0 or self.relaxation_fraction_per_h < 0)
            return error.InvalidRootPorosityParameter;
    }
};

pub fn compatibilityParameters() Parameters {
    return .{
        .maximum_porosity_fraction = 0.75,
        .oxygen_stress_induction_fraction_per_h = 0.1,
        .relaxation_fraction_per_h = 0.01,
    };
}

/// UPTAKE 3858--3862 source selector for the OSTR operand consumed by
/// GROSUB. A root with no oxygen demand receives zero satisfaction, not the
/// neutral value one used by the production caller.
pub fn sourceOxygenSatisfaction(
    oxygen_uptake_g_o: f64,
    oxygen_demand_g_o: f64,
    presence_threshold_g_o: f64,
) !f64 {
    inline for (.{ oxygen_uptake_g_o, oxygen_demand_g_o, presence_threshold_g_o }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteRootPorosityOxygenInput;
    if (oxygen_uptake_g_o < 0 or oxygen_demand_g_o < 0 or presence_threshold_g_o < 0)
        return error.InvalidRootPorosityOxygenInput;
    const satisfaction = if (oxygen_demand_g_o > presence_threshold_g_o)
        oxygen_uptake_g_o / oxygen_demand_g_o
    else
        0;
    if (!std.math.isFinite(satisfaction) or satisfaction < 0 or satisfaction > 1)
        return error.InvalidRootPorosityOxygenResult;
    return satisfaction;
}

/// GROSUB PORT acclimation. Oxygen satisfaction is OSTR (uptake/demand).
pub fn adapt(
    current_porosity_fraction: f64,
    initial_porosity_fraction: f64,
    oxygen_satisfaction_fraction: f64,
    timestep_h: f64,
    parameters: Parameters,
) !f64 {
    try parameters.validate();
    inline for (.{ current_porosity_fraction, initial_porosity_fraction, oxygen_satisfaction_fraction, timestep_h }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteRootPorosityInput;
    if (current_porosity_fraction < 0 or current_porosity_fraction >= 1 or
        initial_porosity_fraction < 0 or initial_porosity_fraction >= 1 or
        oxygen_satisfaction_fraction < 0 or oxygen_satisfaction_fraction > 1 or timestep_h < 0)
        return error.InvalidRootPorosityInput;
    const next = @min(
        parameters.maximum_porosity_fraction,
        current_porosity_fraction +
            (parameters.oxygen_stress_induction_fraction_per_h * initial_porosity_fraction * (1 - oxygen_satisfaction_fraction) -
                parameters.relaxation_fraction_per_h * (current_porosity_fraction - initial_porosity_fraction)) *
                timestep_h,
    );
    if (!std.math.isFinite(next) or next < 0 or next >= 1) return error.InvalidRootPorosityResult;
    return next;
}

test "GROSUB root porosity acclimation preserves PORT source equation and cap" {
    const parameters = compatibilityParameters();
    try std.testing.expectApproxEqAbs(@as(f64, 0.22), try adapt(0.2, 0.2, 0, 1, parameters), 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.299), try adapt(0.3, 0.2, 1, 1, parameters), 1.0e-15);
    try std.testing.expectEqual(@as(f64, 0.75), try adapt(0.749, 0.2, 0, 1, parameters));
}

test "UPTAKE zero oxygen demand drives source root porosity induction" {
    const parameters = compatibilityParameters();
    const source_oxygen_satisfaction = try sourceOxygenSatisfaction(0, 0, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), source_oxygen_satisfaction);
    try std.testing.expectApproxEqAbs(@as(f64, 0.22), try adapt(0.2, 0.2, source_oxygen_satisfaction, 1, parameters), 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), try adapt(0.2, 0.2, 1, 1, parameters), 1e-15);
    try std.testing.expectError(error.InvalidRootPorosityOxygenResult, sourceOxygenSatisfaction(2, 1, 0));
}

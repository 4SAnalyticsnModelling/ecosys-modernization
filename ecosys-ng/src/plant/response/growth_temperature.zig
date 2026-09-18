const std = @import("std");

pub const Parameters = struct {
    gas_constant_j_per_mol_k: f64,
    temperature_scale_k: f64,
    arrhenius_log_prefactor: f64,
    activation_energy_j_per_mol: f64,
    low_temperature_inactivation_j_per_mol: f64,
    high_temperature_inactivation_j_per_mol: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.InvalidPlantGrowthTemperatureParameter;
        if (self.gas_constant_j_per_mol_k <= 0 or self.temperature_scale_k <= 0 or self.activation_energy_j_per_mol <= 0 or self.low_temperature_inactivation_j_per_mol <= 0 or self.high_temperature_inactivation_j_per_mol <= 0) return error.InvalidPlantGrowthTemperatureParameter;
    }
};

pub fn compatibilityParameters() Parameters {
    return .{ .gas_constant_j_per_mol_k = 8.3143, .temperature_scale_k = 710, .arrhenius_log_prefactor = 25.229, .activation_energy_j_per_mol = 62500, .low_temperature_inactivation_j_per_mol = 197500, .high_temperature_inactivation_j_per_mol = 222500 };
}

/// UPTAKE TFN3/TFN4 growth response for canopy or acclimated soil temperature.
pub fn response(adjusted_temperature_k: f64, parameters: Parameters) !f64 {
    try parameters.validate();
    if (!std.math.isFinite(adjusted_temperature_k) or adjusted_temperature_k <= 0) return error.InvalidPlantGrowthTemperature;
    const rt_j_per_mol = parameters.gas_constant_j_per_mol_k * adjusted_temperature_k;
    const st_j_per_mol = parameters.temperature_scale_k * adjusted_temperature_k;
    const inactivation = 1 +
        @exp((parameters.low_temperature_inactivation_j_per_mol - st_j_per_mol) / rt_j_per_mol) +
        @exp((st_j_per_mol - parameters.high_temperature_inactivation_j_per_mol) / rt_j_per_mol);
    const result = @exp(parameters.arrhenius_log_prefactor - parameters.activation_energy_j_per_mol / rt_j_per_mol) / inactivation;
    if (!std.math.isFinite(result) or result < 0) return error.NonFinitePlantGrowthTemperature;
    return result;
}

test "UPTAKE TFN3 and TFN4 retain the source growth Arrhenius equation" {
    const temperature_k = 298.15;
    const rt = 8.3143 * temperature_k;
    const st = 710.0 * temperature_k;
    const expected = @exp(25.229 - 62500.0 / rt) / (1 + @exp((197500.0 - st) / rt) + @exp((st - 222500.0) / rt));
    try std.testing.expectApproxEqAbs(expected, try response(temperature_k, compatibilityParameters()), 1.0e-14);
}

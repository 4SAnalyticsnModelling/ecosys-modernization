const std = @import("std");
const phase = @import("../water/phase_change.zig");
const heat = @import("../heat/flux.zig");

pub const RuntimeParameters = struct {
    vapor_equilibrium: phase.VaporEquilibriumParameters,
    freeze_thaw: phase.FreezeThawParameters,
    heat_turbulence: heat.TurbulenceParameters,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
};

/// Historical WATSUB coefficients materialized as a runtime value for command
/// files that predate the explicit soil_phase_heat record.
pub fn compatibilityParameters() RuntimeParameters {
    const water_prandtl = 1.0e-6 / 1.45e-7;
    const air_prandtl = 2.0e-8 / 2.01e-5;
    return .{
        .vapor_equilibrium = .{ .vapor_density_temperature_coefficient = 2.173e-3, .molecular_weight_ratio = 0.61, .clausius_clapeyron_coefficient_k = 5360, .reference_inverse_temperature_per_k = 3.661e-3, .water_molar_mass_g_per_mol = 18, .gas_constant_j_per_mol_k = 8.3143, .latent_heat_of_vaporization_megajoules_per_m3 = 2450 },
        .freeze_thaw = .{ .freezing_potential_numerator_k_megapascal = 9.0959e4, .latent_heat_of_fusion_megajoules_per_m3 = 333, .ice_density_megagrams_per_m3 = 0.917, .heat_capacity_temperature_feedback_per_k = 6.2913e-3, .pure_water_freezing_temperature_k = 273.15 },
        .heat_turbulence = .{
            .water_fraction_threshold = 0.333,
            .air_fraction_threshold = 0.333,
            .water_rayleigh_coefficient = 9.8 * 2.07e-4 / (1.0e-6 * 1.45e-7),
            .air_rayleigh_coefficient = 9.8 * 3.66e-3 / (2.0e-8 * 2.01e-5),
            .water_nusselt_denominator = std.math.pow(f64, 1.0 + std.math.pow(f64, 0.492 / water_prandtl, 0.5625), 0.4444),
            .air_nusselt_denominator = std.math.pow(f64, 1.0 + std.math.pow(f64, 0.492 / air_prandtl, 0.5625), 0.4444),
            .maximum_rayleigh_number = 1.0e4,
        },
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
    };
}

pub fn validate(parameters: RuntimeParameters) !void {
    inline for (@typeInfo(phase.VaporEquilibriumParameters).@"struct".fields) |field| {
        const value = @field(parameters.vapor_equilibrium, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilPhaseHeatParameters;
    }
    inline for (@typeInfo(phase.FreezeThawParameters).@"struct".fields) |field| {
        const value = @field(parameters.freeze_thaw, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilPhaseHeatParameters;
    }
    if (parameters.freeze_thaw.ice_density_megagrams_per_m3 >= 1) return error.InvalidSoilPhaseHeatParameters;
    inline for (@typeInfo(heat.TurbulenceParameters).@"struct".fields) |field| {
        const value = @field(parameters.heat_turbulence, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilPhaseHeatParameters;
    }
    if (parameters.heat_turbulence.water_nusselt_denominator <= 0 or parameters.heat_turbulence.air_nusselt_denominator <= 0 or parameters.heat_turbulence.maximum_rayleigh_number <= 0) return error.InvalidSoilPhaseHeatParameters;
    if (!std.math.isFinite(parameters.liquid_water_heat_capacity_megajoules_per_m3_k) or parameters.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or !std.math.isFinite(parameters.ice_heat_capacity_megajoules_per_m3_k) or parameters.ice_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidSoilPhaseHeatParameters;
}

test "compatibility science reproduces WATSUB Rayleigh and phase constants" {
    const parameters = compatibilityParameters();
    try validate(parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 9.8 * 2.07e-4 / (1e-6 * 1.45e-7)), parameters.heat_turbulence.water_rayleigh_coefficient, 1e-3);
    try std.testing.expectEqual(@as(f64, 333), parameters.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3);
    try std.testing.expectEqual(@as(f64, 2450), parameters.vapor_equilibrium.latent_heat_of_vaporization_megajoules_per_m3);
    try std.testing.expectEqual(@as(f64, 4.19), parameters.liquid_water_heat_capacity_megajoules_per_m3_k);
}

// **A8a DISPOSITION: BOUND; CANOPY-TKC-001 closed for this component.**
// `stages/hourly_snow_energy.zig` assembles these UPTAKE.F 776--831 invariant
// terms once per living plant and passes them to the coupled TKCY/root-water
// residual. The emitted, canopy-ground, sky, and lateral longwave terms are
// therefore evaluated by one owner rather than the retired diagnostic writer.
const std = @import("std");

pub const Inputs = struct {
    canopy_total_water_potential_megapascal: f64,
    absorbed_shortwave_radiation_megajoules_per_h: f64,
    heat_flux_timestep_h: f64,
    canopy_emissivity: f64,
    stefan_boltzmann_megajoules_per_h_m2_k4: f64,
    absorbed_radiation_fraction: f64,
    cell_area_m2: f64,
    sky_longwave_radiation_megajoules_per_h: f64,
    lateral_longwave_radiation_megajoules_per_step: f64,
    canopy_radiation_share: f64,
    nonstructural_carbon_concentration_g_c_per_g_c: f64,
    nonstructural_nitrogen_concentration_g_n_per_g_c: f64,
    nonstructural_phosphorus_concentration_g_p_per_g_c: f64,
    osmotic_molar_mass_intercept_g_per_mol: f64,
    osmotic_molar_mass_slope_g_per_mol: f64,
    latent_boundary_conductance_m2_per_step: f64,
    sensible_boundary_conductance_megajoules_per_m_k_step: f64,
};

pub const FluxAccumulators = struct {
    net_radiation_megajoules_per_step: f64 = 0,
    latent_heat_megajoules_per_step: f64 = 0,
    sensible_heat_megajoules_per_step: f64 = 0,
    canopy_heat_storage_megajoules_per_step: f64 = 0,
    water_vapor_m3_per_step: f64 = 0,
    thermal_radiation_megajoules_per_step: f64 = 0,
    canopy_surface_evaporation_m3_per_step: f64 = 0,
    transpiration_m3_per_step: f64 = 0,
    ground_evaporation_m3_per_step: f64 = 0,
    ground_sensible_heat_megajoules_per_step: f64 = 0,
    maximum_root_water_uptake_m3_per_step: f64 = 0,
};

pub const Result = struct {
    convergence_check: usize,
    trial_canopy_water_potential_megapascal: f64,
    trial_transpiration_m3_per_step: f64,
    trial_root_water_uptake_m3_per_step: f64,
    absorbed_shortwave_radiation_megajoules_per_step: f64,
    emitted_longwave_coefficient_megajoules_per_step_k4: f64,
    absorbed_sky_longwave_megajoules_per_step: f64,
    absorbed_lateral_longwave_megajoules_per_step: f64,
    total_nonstructural_solute_concentration_g_per_g_c: f64,
    osmotic_molar_mass_g_per_mol: f64,
    nonlinear_iteration_count: usize,
    fluxes: FluxAccumulators,
    latent_boundary_conductance_m2_per_step: f64,
    sensible_boundary_conductance_megajoules_per_m_k_step: f64,
};

/// UPTAKE.F 776--831. Initializes convergence and all energy-balance terms
/// that remain fixed inside the subsequent nonlinear iteration.
pub fn calculate(inputs: Inputs) !Result {
    try validateInputs(inputs);
    const absorbed_shortwave =
        inputs.absorbed_shortwave_radiation_megajoules_per_h *
        inputs.heat_flux_timestep_h;
    const emitted_longwave_coefficient =
        inputs.canopy_emissivity *
        inputs.stefan_boltzmann_megajoules_per_h_m2_k4 *
        inputs.absorbed_radiation_fraction *
        inputs.cell_area_m2 *
        inputs.heat_flux_timestep_h;
    const absorbed_sky_longwave =
        inputs.sky_longwave_radiation_megajoules_per_h *
        inputs.absorbed_radiation_fraction *
        inputs.heat_flux_timestep_h;
    const absorbed_lateral_longwave =
        inputs.lateral_longwave_radiation_megajoules_per_step *
        inputs.canopy_radiation_share *
        inputs.heat_flux_timestep_h;
    const total_solute =
        inputs.nonstructural_carbon_concentration_g_c_per_g_c +
        inputs.nonstructural_nitrogen_concentration_g_n_per_g_c +
        inputs.nonstructural_phosphorus_concentration_g_p_per_g_c;
    const osmotic_molar_mass =
        inputs.osmotic_molar_mass_intercept_g_per_mol +
        inputs.osmotic_molar_mass_slope_g_per_mol *
            @max(0, total_solute);
    const result = Result{
        .convergence_check = 0,
        .trial_canopy_water_potential_megapascal = inputs.canopy_total_water_potential_megapascal,
        .trial_transpiration_m3_per_step = 0,
        .trial_root_water_uptake_m3_per_step = 0,
        .absorbed_shortwave_radiation_megajoules_per_step = absorbed_shortwave,
        .emitted_longwave_coefficient_megajoules_per_step_k4 = emitted_longwave_coefficient,
        .absorbed_sky_longwave_megajoules_per_step = absorbed_sky_longwave,
        .absorbed_lateral_longwave_megajoules_per_step = absorbed_lateral_longwave,
        .total_nonstructural_solute_concentration_g_per_g_c = total_solute,
        .osmotic_molar_mass_g_per_mol = osmotic_molar_mass,
        .nonlinear_iteration_count = 0,
        .fluxes = .{},
        .latent_boundary_conductance_m2_per_step = inputs.absorbed_radiation_fraction *
            inputs.latent_boundary_conductance_m2_per_step,
        .sensible_boundary_conductance_megajoules_per_m_k_step = inputs.absorbed_radiation_fraction *
            inputs.sensible_boundary_conductance_megajoules_per_m_k_step,
    };
    try validateResult(result);
    return result;
}

fn validateInputs(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.InvalidCanopyEnergyFixedTermInput;
    if (inputs.heat_flux_timestep_h < 0 or
        inputs.canopy_emissivity < 0 or
        inputs.stefan_boltzmann_megajoules_per_h_m2_k4 < 0 or
        inputs.absorbed_radiation_fraction < 0 or
        inputs.cell_area_m2 <= 0 or
        inputs.canopy_radiation_share < 0 or
        inputs.osmotic_molar_mass_intercept_g_per_mol <= 0 or
        inputs.osmotic_molar_mass_slope_g_per_mol < 0 or
        inputs.latent_boundary_conductance_m2_per_step < 0 or
        inputs.sensible_boundary_conductance_megajoules_per_m_k_step < 0)
        return error.InvalidCanopyEnergyFixedTermInput;
}

fn validateResult(result: Result) !void {
    inline for (@typeInfo(Result).@"struct".fields) |field| {
        if (field.type == f64 and !std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteCanopyEnergyFixedTerm;
    }
    inline for (@typeInfo(FluxAccumulators).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result.fluxes, field.name)))
            return error.NonFiniteCanopyEnergyFixedTerm;
}

fn sourceInputs() Inputs {
    return .{
        .canopy_total_water_potential_megapascal = -1.5,
        .absorbed_shortwave_radiation_megajoules_per_h = 4,
        .heat_flux_timestep_h = 0.25,
        .canopy_emissivity = 0.97,
        .stefan_boltzmann_megajoules_per_h_m2_k4 = 2.04e-10,
        .absorbed_radiation_fraction = 0.4,
        .cell_area_m2 = 100,
        .sky_longwave_radiation_megajoules_per_h = 2,
        .lateral_longwave_radiation_megajoules_per_step = -0.5,
        .canopy_radiation_share = 0.3,
        .nonstructural_carbon_concentration_g_c_per_g_c = 0.1,
        .nonstructural_nitrogen_concentration_g_n_per_g_c = 0.02,
        .nonstructural_phosphorus_concentration_g_p_per_g_c = 0.01,
        .osmotic_molar_mass_intercept_g_per_mol = 144,
        .osmotic_molar_mass_slope_g_per_mol = 840,
        .latent_boundary_conductance_m2_per_step = 5,
        .sensible_boundary_conductance_megajoules_per_m_k_step = 6,
    };
}

test "UPTAKE fixed canopy energy terms preserve source operation order" {
    const result = try calculate(sourceInputs());
    try std.testing.expectEqual(@as(usize, 0), result.convergence_check);
    try std.testing.expectEqual(@as(f64, -1.5), result.trial_canopy_water_potential_megapascal);
    try std.testing.expectEqual(@as(f64, 1), result.absorbed_shortwave_radiation_megajoules_per_step);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), result.absorbed_sky_longwave_megajoules_per_step, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.0375), result.absorbed_lateral_longwave_megajoules_per_step, 1e-15);
    try std.testing.expectEqual(@as(f64, 0.13), result.total_nonstructural_solute_concentration_g_per_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 253.2), result.osmotic_molar_mass_g_per_mol, 1e-12);
    try std.testing.expectEqual(@as(f64, 2), result.latent_boundary_conductance_m2_per_step);
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), result.sensible_boundary_conductance_megajoules_per_m_k_step, 1e-15);
    inline for (@typeInfo(FluxAccumulators).@"struct".fields) |field|
        try std.testing.expectEqual(@as(f64, 0), @field(result.fluxes, field.name));
}

test "negative total solute uses source zero floor only in molar mass" {
    var inputs = sourceInputs();
    inputs.nonstructural_carbon_concentration_g_c_per_g_c = -1;
    inputs.nonstructural_nitrogen_concentration_g_n_per_g_c = 0;
    inputs.nonstructural_phosphorus_concentration_g_p_per_g_c = 0;
    const result = try calculate(inputs);
    try std.testing.expectEqual(@as(f64, -1), result.total_nonstructural_solute_concentration_g_per_g_c);
    try std.testing.expectEqual(@as(f64, 144), result.osmotic_molar_mass_g_per_mol);
}

test "fixed canopy energy terms reject non-finite input" {
    var inputs = sourceInputs();
    inputs.sky_longwave_radiation_megajoules_per_h = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidCanopyEnergyFixedTermInput,
        calculate(inputs),
    );
}

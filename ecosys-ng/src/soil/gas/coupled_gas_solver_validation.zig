//! `coupled_gas_solver` declarations: validation.
//!
//! Split out of `coupled_gas_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const gas = @import("transport.zig");
const atmosphere = @import("atmosphere_exchange.zig");
const numerics = @import("../../core/numerics.zig");
const group_misc = @import("coupled_gas_solver_misc.zig");

pub fn validate(state: *const gas.State, inputs: group_misc.Inputs, options: group_misc.Options) !void {
    try state.validateFinite();
    const n = std.math.mul(usize, state.cell_count, gas.species_count) catch
        return error.CoupledGasStateSizeMismatch;
    if (inputs.face_conductance_m3_per_step.len != try std.math.mul(usize, inputs.faces.len, gas.species_count)) return error.GasFaceParameterSizeMismatch;
    if (inputs.water_volume_m3.len != state.cell_count or inputs.band_water_volume_m3.len != state.cell_count or inputs.bubbling_enabled.len != state.cell_count or inputs.mass_solubility_ratio.len != n or inputs.gas_water_exchange_rate_per_step.len != n or inputs.band_gas_water_exchange_rate_per_step.len != n) return error.CoupledGasInputSizeMismatch;
    const has_air_zones = inputs.nonband_air_volume_m3.len != 0 or inputs.band_air_volume_m3.len != 0;
    if (has_air_zones and (inputs.nonband_air_volume_m3.len != state.cell_count or inputs.band_air_volume_m3.len != state.cell_count))
        return error.CoupledGasInputSizeMismatch;
    // Legacy `ZEROS2`, one value per modeled cell. An empty slice is the
    // documented "caller owns no cell area" case and keeps every guarded site
    // at its bare positivity test; any other length is a wiring mistake.
    if (inputs.minimum_carrier_volume_m3.len != 0) {
        if (inputs.minimum_carrier_volume_m3.len != state.cell_count)
            return error.CoupledGasInputSizeMismatch;
        for (inputs.minimum_carrier_volume_m3) |minimum_m3|
            if (!std.math.isFinite(minimum_m3) or minimum_m3 < 0)
                return error.InvalidCoupledGasCarrierMinimum;
    }
    if (inputs.bubble_receiver_cell_by_cell) |receivers| {
        if (receivers.len != state.cell_count) return error.CoupledGasInputSizeMismatch;
        for (receivers) |receiver| if (receiver) |cell|
            if (cell >= state.cell_count) return error.GasBubbleReceiverOutOfBounds;
    }
    if (inputs.atmospheric_flux_g_by_component) |fluxes| if (fluxes.len != n) return error.GasBoundaryFluxSizeMismatch;
    if (inputs.subsurface_flux_g_by_component) |fluxes| if (fluxes.len != n) return error.GasBoundaryFluxSizeMismatch;
    if (inputs.bubble_transfer_g_by_component) |fluxes| if (fluxes.len != n) return error.GasBubbleFluxSizeMismatch;
    if (inputs.face_flux_g_by_component) |fluxes| if (fluxes.len !=
        try std.math.mul(usize, inputs.faces.len, gas.species_count))
        return error.GasFaceFluxSizeMismatch;
    for (options.absolute_tolerance_g_by_species) |tolerance_g| if (!std.math.isFinite(tolerance_g) or tolerance_g <= 0) return error.InvalidCoupledGasSolverOptions;
    if (!std.math.isNan(options.absolute_tolerance_g) and (!std.math.isFinite(options.absolute_tolerance_g) or options.absolute_tolerance_g <= 0)) return error.InvalidCoupledGasSolverOptions;
    if (!std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or !std.math.isFinite(options.directional_probe_fraction) or options.directional_probe_fraction <= 0 or !std.math.isFinite(options.minimum_newton_fraction) or options.minimum_newton_fraction <= 0 or !std.math.isFinite(options.maximum_newton_fraction) or options.maximum_newton_fraction < options.minimum_newton_fraction or options.maximum_newton_fraction > 1 or options.divergence_patience == 0 or !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1 or !std.math.isFinite(options.transport_iteration_fraction) or options.transport_iteration_fraction <= 0 or options.transport_iteration_fraction > 1 or options.max_iterations == 0 or options.krylov_restart_max == 0 or options.krylov_restart_max > group_misc.maximum_krylov_restart or !std.math.isFinite(options.krylov_relative_tolerance) or options.krylov_relative_tolerance <= 0 or options.krylov_relative_tolerance >= 1) return error.InvalidCoupledGasSolverOptions;
    for (inputs.water_volume_m3, inputs.band_water_volume_m3) |water, band_water| if (!std.math.isFinite(water) or water < 0 or !std.math.isFinite(band_water) or band_water < 0 or band_water > water) return error.InvalidCoupledGasInput;
    if (has_air_zones) for (inputs.nonband_air_volume_m3, inputs.band_air_volume_m3, state.air_volume_m3) |nonband_air, band_air, total_air| {
        if (!std.math.isFinite(nonband_air) or nonband_air < 0 or !std.math.isFinite(band_air) or band_air < 0 or
            @abs(nonband_air + band_air - total_air) > 64 * std.math.floatEps(f64) * @max(1, @abs(total_air)))
            return error.InvalidCoupledGasAirZoneVolumes;
    };
    for (inputs.mass_solubility_ratio) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidCoupledGasInput;
    for (inputs.gas_water_exchange_rate_per_step, inputs.band_gas_water_exchange_rate_per_step) |rate, band_rate| if (!std.math.isFinite(rate) or rate < 0 or !std.math.isFinite(band_rate) or band_rate < 0) return error.InvalidCoupledGasInput;
    for (inputs.faces) |face| {
        if (face.first_cell >= state.cell_count or face.second_cell >= state.cell_count or face.first_cell == face.second_cell)
            return error.InvalidGasTransportFace;
    }
    for (inputs.face_conductance_m3_per_step) |conductance| {
        if (!std.math.isFinite(conductance) or conductance < 0) return error.InvalidCoupledGasInput;
    }
    try validateBoundaries(state.cell_count, inputs.atmospheric_boundaries);
    try validateBoundaries(state.cell_count, inputs.subsurface_boundaries);
}

fn validateBoundaries(cell_count: usize, boundaries: []const atmosphere.Boundary) !void {
    for (boundaries) |boundary| {
        if (boundary.cell_index >= cell_count or
            !std.math.isFinite(boundary.aerodynamic_conductance_m3_per_step) or
            boundary.aerodynamic_conductance_m3_per_step < 0 or
            !std.math.isFinite(boundary.pressure_exchange_fraction) or
            boundary.pressure_exchange_fraction < 0 or
            boundary.pressure_exchange_fraction > 1)
        {
            return error.InvalidGasBoundary;
        }
        for (boundary.interior_conductance_m3_per_step, boundary.atmospheric_concentration_g_per_m3) |conductance, concentration| {
            if (!std.math.isFinite(conductance) or conductance < 0 or
                !std.math.isFinite(concentration) or concentration < 0)
            {
                return error.InvalidGasBoundary;
            }
        }
    }
}

pub fn validationTestInputs() group_misc.Inputs {
    return .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{},
        .water_volume_m3 = &.{0},
        .band_water_volume_m3 = &.{0},
        .mass_solubility_ratio = &([_]f64{1} ** gas.species_count),
        .gas_water_exchange_rate_per_step = &([_]f64{0} ** gas.species_count),
        .band_gas_water_exchange_rate_per_step = &([_]f64{0} ** gas.species_count),
        .bubbling_enabled = &.{false},
    };
}

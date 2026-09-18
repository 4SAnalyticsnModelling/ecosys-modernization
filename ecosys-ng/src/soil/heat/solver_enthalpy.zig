//! `solver` declarations: enthalpy.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const grid_module = @import("../../state/grid.zig");
const heat = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const numerics = @import("../../core/numerics.zig");
const boundary_topology_module = @import("../profile/boundary_topology.zig");
const water_boundary = @import("../water/boundary.zig");
const enthalpy = @import("../water/enthalpy_balance.zig");
const retention = @import("../water/retention.zig");
const group_misc = @import("solver_misc.zig");
const group_types = @import("solver_types.zig");

/// The `unfrozen_pressure_head_m` that `soil_enthalpy_balance` and
/// `soil_water_phase_change.dallAmicoEquilibrium` require: the matric head the
/// layer's TOTAL water (liquid plus ice water equivalent) would hold on the
/// UNMODIFIED retention curve if none of it were frozen.
///
/// Both properties are load bearing, and getting either wrong is a conservation
/// defect rather than a cosmetic one.
///
/// **Total water, not liquid.** In Dall'Amico et al. (2011) the head is the
/// reference state of the freezing curve: `dallAmicoEquilibrium` depresses the
/// melting point from it via the Clapeyron exponent, walks the head down the
/// curve to the current temperature, and reads the liquid fraction back off it.
/// Pricing the LIQUID content there makes the reference state a function of the
/// answer it is supposed to determine, so as ice grows the reference dries, the
/// depressed melting point falls, and the equilibrium tracks a moving target
/// while the enthalpy that was already booked against the previous target is
/// not revisited. The pre-existing owner of this same physics,
/// `soil_phase_solver.freezeThawEquilibrium`, already prices total water.
///
/// **Unmodified curve, not an ice-shrunk one.** The head is consumed alongside
/// `mualem_van_genuchten`, which `soil_enthalpy_balance` passes through
/// unmodified to both `dallAmicoEquilibrium` and `waterCapacityPerM`. A head
/// produced from a curve with a different `saturated_water_content_m3_per_m3`
/// is not a point on the curve that then interprets it, so the enthalpy state
/// and its own temperature derivative are evaluated on two different
/// constitutive relations and the Newton iteration converges to a temperature
/// that satisfies neither.
///
/// Clamping to the saturated content is the same admissibility guard
/// `soil_phase_solver` applies. It is not a widened domain: the retention curve
/// is undefined above saturation, saturation is where the head is zero, and a
/// total water content above it is a water-balance question owned upstream, not
/// something to be absorbed by silently reshaping the curve here.
pub fn unfrozenPressureHeadM(
    parameters: retention.MualemVanGenuchtenParameters,
    total_water_equivalent_m3: f64,
    porous_medium_volume_m3: f64,
) !f64 {
    if (!std.math.isFinite(porous_medium_volume_m3) or porous_medium_volume_m3 <= 0)
        return error.InvalidCoupledSoilPorousMediumVolume;
    const total_water_content_m3_per_m3 =
        total_water_equivalent_m3 / porous_medium_volume_m3;
    return parameters.pressureHeadAtWaterContent(std.math.clamp(
        total_water_content_m3_per_m3,
        parameters.residual_water_content_m3_per_m3,
        parameters.saturated_water_content_m3_per_m3,
    ));
}

pub fn enthalpyParameters(
    properties: group_types.Properties,
    coupling: group_misc.EnthalpyCoupling,
    cell: usize,
) !enthalpy.Parameters {
    const matrix_retention = coupling.mualem_van_genuchten[cell];
    const matrix_volume_m3 =
        if (coupling.matrix_pore_capacity_m3.len != 0)
            try porousMediumVolumeFromPoreCapacity(
                coupling.matrix_pore_capacity_m3[cell],
                matrix_retention.saturated_water_content_m3_per_m3,
            )
        else
            coupling.porous_medium_volume_m3[cell];
    const dry_solid_heat_capacity_megajoules_per_k =
        properties.heat_capacity_megajoules_per_k[cell] -
        properties.liquid_water_heat_capacity_megajoules_per_m3_k *
            coupling.matrix_liquid_water_m3[cell] -
        coupling.ice_water_equivalent_heat_capacity_megajoules_per_m3_k *
            coupling.matrix_ice_water_equivalent_m3[cell] -
        (if (coupling.macropore_mualem_van_genuchten.len != 0)
            properties.liquid_water_heat_capacity_megajoules_per_m3_k *
                coupling.macropore_liquid_water_m3[cell] +
                coupling.ice_water_equivalent_heat_capacity_megajoules_per_m3_k *
                    coupling.macropore_ice_water_equivalent_m3[cell]
        else
            0);
    const normalized_dry_solid_heat_capacity_megajoules_per_k =
        try normalizeNonnegativeRoundoff(
            dry_solid_heat_capacity_megajoules_per_k,
            properties.heat_capacity_megajoules_per_k[cell],
            error.InvalidCoupledSoilDryHeatCapacity,
        );
    return .{
        .porous_medium_volume_m3 = matrix_volume_m3,
        .total_water_equivalent_m3 = coupling.matrix_liquid_water_m3[cell] +
            coupling.matrix_ice_water_equivalent_m3[cell],
        .unfrozen_pressure_head_m = if (coupling.unfrozen_pressure_head_m.len != 0)
            coupling.unfrozen_pressure_head_m[cell]
        else
            try unfrozenPressureHeadM(
                matrix_retention,
                coupling.matrix_liquid_water_m3[cell] +
                    coupling.matrix_ice_water_equivalent_m3[cell],
                matrix_volume_m3,
            ),
        .gravitational_water_potential_mpa_per_m = coupling.gravitational_water_potential_mpa_per_m,
        .pure_water_melting_temperature_k = coupling.pure_water_melting_temperature_k,
        .dry_solid_heat_capacity_megajoules_per_k = normalized_dry_solid_heat_capacity_megajoules_per_k,
        .liquid_water_heat_capacity_megajoules_per_m3_k = properties.liquid_water_heat_capacity_megajoules_per_m3_k,
        .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = coupling.ice_water_equivalent_heat_capacity_megajoules_per_m3_k,
        .latent_heat_of_fusion_megajoules_per_m3 = coupling.latent_heat_of_fusion_megajoules_per_m3,
        .mualem_van_genuchten = matrix_retention,
        .secondary_domain = if (coupling.macropore_mualem_van_genuchten.len != 0 and
            coupling.macropore_porous_medium_volume_m3[cell] > 0)
            .{
                .porous_medium_volume_m3 = coupling.macropore_porous_medium_volume_m3[cell],
                .total_water_equivalent_m3 = coupling.macropore_liquid_water_m3[cell] +
                    coupling.macropore_ice_water_equivalent_m3[cell],
                .unfrozen_pressure_head_m = if (coupling.macropore_unfrozen_pressure_head_m.len != 0)
                    coupling.macropore_unfrozen_pressure_head_m[cell]
                else
                    try unfrozenPressureHeadM(
                        coupling.macropore_mualem_van_genuchten[cell],
                        coupling.macropore_liquid_water_m3[cell] +
                            coupling.macropore_ice_water_equivalent_m3[cell],
                        coupling.macropore_porous_medium_volume_m3[cell],
                    ),
                .mualem_van_genuchten = coupling.macropore_mualem_van_genuchten[cell],
            }
        else
            null,
    };
}

pub fn porousMediumVolumeFromPoreCapacity(
    pore_capacity_m3: f64,
    saturated_water_content_m3_per_m3: f64,
) !f64 {
    if (!std.math.isFinite(pore_capacity_m3) or pore_capacity_m3 <= 0 or
        !std.math.isFinite(saturated_water_content_m3_per_m3) or
        saturated_water_content_m3_per_m3 <= 0)
        return error.InvalidCoupledSoilPoreGeometry;
    const volume_m3 =
        pore_capacity_m3 / saturated_water_content_m3_per_m3;
    if (!std.math.isFinite(volume_m3) or volume_m3 <= 0)
        return error.InvalidCoupledSoilPoreGeometry;
    return volume_m3;
}

pub fn cellConductivityInputs(
    properties: group_types.Properties,
    cell: usize,
    temperature_difference_k: f64,
    phase_buffers: group_misc.PhaseBuffers,
) !heat.CellConductivityInputs {
    var liquid_water_fraction = properties.liquid_water_fraction[cell];
    var ice_fraction = properties.ice_fraction[cell];
    var air_fraction = properties.air_fraction[cell];
    var fraction_of_pore_volume_air_filled = properties.fraction_of_pore_volume_air_filled[cell];
    if (properties.enthalpy_coupling) |coupling| {
        // WATSUB 6841-6855 reconstructs THETWX/THETIX/THETPX from current
        // matrix + macropore volumes over their combined bulk volume. Adding
        // phase deltas to HOUR1 fractions mixes different time levels; it can
        // invent negative ice at thaw and reject every Newton crossing.
        const matrix_volume_m3 = if (coupling.matrix_pore_capacity_m3.len != 0)
            try porousMediumVolumeFromPoreCapacity(coupling.matrix_pore_capacity_m3[cell], coupling.mualem_van_genuchten[cell].saturated_water_content_m3_per_m3)
        else
            coupling.porous_medium_volume_m3[cell];
        const matrix_pore_m3 = matrix_volume_m3 *
            coupling.mualem_van_genuchten[cell].saturated_water_content_m3_per_m3;
        const macro_enabled = phase_buffers.macropore_enabled and
            coupling.macropore_porous_medium_volume_m3[cell] > 0;
        const macro_volume_m3 = if (macro_enabled) coupling.macropore_porous_medium_volume_m3[cell] else 0;
        const macro_pore_m3 = if (macro_enabled) macro_volume_m3 *
            coupling.macropore_mualem_van_genuchten[cell].saturated_water_content_m3_per_m3 else 0;
        const matrix_liquid_m3 = phase_buffers.matrix_liquid_m3[cell];
        const macro_liquid_m3 = if (macro_enabled) phase_buffers.macropore_liquid_m3[cell] else 0;
        // Conductivity uses physical ice volume, whereas enthalpy and phase
        // buffers conserve water-equivalent volume.
        const ice_units = @import("../../core/ice_units.zig");
        const matrix_ice_m3 = try ice_units.physicalVolumeM3FromWaterEquivalent(phase_buffers.matrix_ice_m3[cell], coupling.ice_density_megagrams_per_m3);
        const macro_ice_m3 = if (macro_enabled) try ice_units.physicalVolumeM3FromWaterEquivalent(phase_buffers.macropore_ice_m3[cell], coupling.ice_density_megagrams_per_m3) else 0;
        const bulk_volume_m3 = matrix_volume_m3 + macro_volume_m3;
        const pore_volume_m3 = matrix_pore_m3 + macro_pore_m3;
        const air_volume_m3 = @max(0.0, matrix_pore_m3 - matrix_liquid_m3 - matrix_ice_m3) +
            @max(0.0, macro_pore_m3 - macro_liquid_m3 - macro_ice_m3);
        liquid_water_fraction = (matrix_liquid_m3 + macro_liquid_m3) / bulk_volume_m3;
        ice_fraction = (matrix_ice_m3 + macro_ice_m3) / bulk_volume_m3;
        air_fraction = air_volume_m3 / bulk_volume_m3;
        fraction_of_pore_volume_air_filled = if (pore_volume_m3 > 0) air_volume_m3 / pore_volume_m3 else 0;
    }
    return .{
        .bulk_density_megagrams_per_m3 = properties.bulk_density_megagrams_per_m3[cell],
        .liquid_water_fraction = liquid_water_fraction,
        .ice_fraction = ice_fraction,
        .air_fraction = air_fraction,
        .fraction_of_pore_volume_air_filled = fraction_of_pore_volume_air_filled,
        .solid_conductivity_numerator_m_megajoules_per_h_k = properties.solid_conductivity_numerator_m_megajoules_per_h_k[cell],
        .solid_conductivity_denominator = properties.solid_conductivity_denominator[cell],
        .temperature_difference_k = temperature_difference_k,
    };
}

/// Reconstruction subtracts the same extensive phase carrier represented in
/// two independently rounded forms.  A negative result is admissible only
/// within a scale-aware machine-roundoff envelope; larger negatives are an
/// impossible phase state and must reach the nonlinear retry/rollback path.
fn normalizeNonnegativeRoundoff(value: f64, scale: f64, failure: anyerror) !f64 {
    if (!std.math.isFinite(value) or !std.math.isFinite(scale) or scale < 0)
        return failure;
    const tolerance = 64.0 * std.math.floatEps(f64) * @max(1.0, scale);
    if (value < -tolerance) return failure;
    return if (value < 0) 0 else value;
}

test "enthalpy reconstruction normalizes only scaled floating-point roundoff" {
    const epsilon = std.math.floatEps(f64);
    try std.testing.expectEqual(@as(f64, 0), try normalizeNonnegativeRoundoff(-32 * epsilon, 1, error.InvalidTestPhase));
    try std.testing.expectEqual(@as(f64, 2), try normalizeNonnegativeRoundoff(2, 2, error.InvalidTestPhase));
}

test "phase fraction negative beyond scaled roundoff is rejected" {
    const epsilon = std.math.floatEps(f64);
    try std.testing.expectEqual(@as(f64, 0), try normalizeNonnegativeRoundoff(-32 * epsilon * 100, 100, error.InvalidCoupledSoilIceFraction));
    try std.testing.expectError(error.InvalidCoupledSoilIceFraction, normalizeNonnegativeRoundoff(-128 * epsilon * 100, 100, error.InvalidCoupledSoilIceFraction));
}

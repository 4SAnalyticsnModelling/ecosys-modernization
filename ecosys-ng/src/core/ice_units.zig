//! Canonical conversions between physical ice volume and liquid-water-
//! equivalent (WE) volume.  Runtime water carriers use WE; pore geometry and
//! the original ECOSYS `VOLI`/`VOLIH` equations use physical ice volume.

const std = @import("std");

pub const reference_ice_density_megagrams_per_m3: f64 = 0.917;

fn validateDensity(ice_density_megagrams_per_m3: f64) !void {
    if (!std.math.isFinite(ice_density_megagrams_per_m3) or
        ice_density_megagrams_per_m3 <= 0 or
        ice_density_megagrams_per_m3 > 1)
        return error.InvalidIceDensity;
}

fn validateVolume(volume_m3: f64) !void {
    if (!std.math.isFinite(volume_m3) or volume_m3 < 0)
        return error.InvalidIceVolume;
}

pub fn physicalVolumeM3FromWaterEquivalent(
    water_equivalent_m3: f64,
    ice_density_megagrams_per_m3: f64,
) !f64 {
    try validateVolume(water_equivalent_m3);
    try validateDensity(ice_density_megagrams_per_m3);
    return water_equivalent_m3 / ice_density_megagrams_per_m3;
}

pub fn waterEquivalentM3FromPhysicalVolume(
    physical_ice_volume_m3: f64,
    ice_density_megagrams_per_m3: f64,
) !f64 {
    try validateVolume(physical_ice_volume_m3);
    try validateDensity(ice_density_megagrams_per_m3);
    return physical_ice_volume_m3 * ice_density_megagrams_per_m3;
}

/// Converts ECOSYS's physical-ice volumetric heat capacity into the
/// coefficient for a WE carrier.  This preserves `Ci_phys*V_phys` exactly.
pub fn heatCapacityPerWaterEquivalentM3K(
    physical_ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
) !f64 {
    if (!std.math.isFinite(physical_ice_heat_capacity_megajoules_per_m3_k) or
        physical_ice_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidIceHeatCapacity;
    try validateDensity(ice_density_megagrams_per_m3);
    return physical_ice_heat_capacity_megajoules_per_m3_k /
        ice_density_megagrams_per_m3;
}

/// Frozen-carrier enthalpy per cubic metre WE, referenced consistently with
/// liquid water at the pure-water melting temperature. `frozen_carrier` is
/// the sensible coefficient of the actual carrier: `Cs` for solid snow or
/// `Ci_phys/rho` for physical ice expressed as WE. Latent fusion is per WE
/// and therefore is deliberately not density-scaled.
pub fn frozenWaterEquivalentEnthalpyPerM3(
    temperature_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    frozen_carrier_heat_capacity_per_water_equivalent_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    melting_temperature_k: f64,
) !f64 {
    if (!std.math.isFinite(temperature_k) or temperature_k <= 0 or
        !std.math.isFinite(liquid_water_heat_capacity_megajoules_per_m3_k) or
        liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or
        !std.math.isFinite(frozen_carrier_heat_capacity_per_water_equivalent_m3_k) or
        frozen_carrier_heat_capacity_per_water_equivalent_m3_k <= 0 or
        !std.math.isFinite(latent_heat_of_fusion_megajoules_per_m3) or
        latent_heat_of_fusion_megajoules_per_m3 <= 0 or
        !std.math.isFinite(melting_temperature_k) or melting_temperature_k <= 0)
        return error.InvalidIceEnthalpyParameter;
    return liquid_water_heat_capacity_megajoules_per_m3_k * melting_temperature_k -
        latent_heat_of_fusion_megajoules_per_m3 +
        frozen_carrier_heat_capacity_per_water_equivalent_m3_k *
            (temperature_k - melting_temperature_k);
}

pub fn frozenWaterEquivalentCorrectionFromSensiblePerM3(
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    frozen_carrier_heat_capacity_per_water_equivalent_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    melting_temperature_k: f64,
) !f64 {
    return (try frozenWaterEquivalentEnthalpyPerM3(
        melting_temperature_k,
        liquid_water_heat_capacity_megajoules_per_m3_k,
        frozen_carrier_heat_capacity_per_water_equivalent_m3_k,
        latent_heat_of_fusion_megajoules_per_m3,
        melting_temperature_k,
    )) - frozen_carrier_heat_capacity_per_water_equivalent_m3_k * melting_temperature_k;
}

/// Re-bases any frozen WE carrier's published sensible product `C_carrier*T`
/// onto the canonical frozen-water enthalpy.  Solid snow and refrozen ice
/// have different sensible coefficients, so callers must pass the coefficient
/// belonging to the actual carrier instead of applying one grouped offset.
pub fn frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
    carrier_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    melting_temperature_k: f64,
) !f64 {
    return frozenWaterEquivalentCorrectionFromSensiblePerM3(
        liquid_water_heat_capacity_megajoules_per_m3_k,
        carrier_heat_capacity_megajoules_per_m3_k,
        latent_heat_of_fusion_megajoules_per_m3,
        melting_temperature_k,
    );
}

test "physical ice and water-equivalent conversions preserve mass and capacity" {
    const rho = reference_ice_density_megagrams_per_m3;
    const physical_m3 = 0.125;
    const water_equivalent_m3 = try waterEquivalentM3FromPhysicalVolume(physical_m3, rho);
    try std.testing.expectApproxEqAbs(physical_m3, try physicalVolumeM3FromWaterEquivalent(water_equivalent_m3, rho), 1.0e-15);

    const capacity_physical = 1.9274;
    const capacity_we = try heatCapacityPerWaterEquivalentM3K(capacity_physical, rho);
    try std.testing.expectApproxEqAbs(capacity_physical * physical_m3, capacity_we * water_equivalent_m3, 1.0e-15);
}

test "frozen WE enthalpy keeps fusion latent heat density independent" {
    const temperature_k = 268.15;
    const liquid_capacity = 4.19;
    const ice_capacity_we = try heatCapacityPerWaterEquivalentM3K(1.9274, reference_ice_density_megagrams_per_m3);
    const latent = 333.0;
    const melting_k = 273.15;
    const expected = liquid_capacity * melting_k - latent + ice_capacity_we * (temperature_k - melting_k);
    try std.testing.expectApproxEqAbs(expected, try frozenWaterEquivalentEnthalpyPerM3(temperature_k, liquid_capacity, ice_capacity_we, latent, melting_k), 1.0e-12);
    try std.testing.expectApproxEqAbs((liquid_capacity - ice_capacity_we) * melting_k - latent, try frozenWaterEquivalentCorrectionFromSensiblePerM3(liquid_capacity, ice_capacity_we, latent, melting_k), 1.0e-12);
    const solid_capacity = 2.095;
    const expected_solid_correction = (liquid_capacity - solid_capacity) * melting_k - latent;
    try std.testing.expectApproxEqAbs(
        expected_solid_correction,
        try frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
            solid_capacity,
            liquid_capacity,
            latent,
            melting_k,
        ),
        1.0e-12,
    );
    try std.testing.expect(@abs(expected_solid_correction -
        ((liquid_capacity - ice_capacity_we) * melting_k - latent)) > 1);
}

test "ice-unit helpers reject invalid state" {
    try std.testing.expectError(error.InvalidIceDensity, physicalVolumeM3FromWaterEquivalent(1, 0));
    try std.testing.expectError(error.InvalidIceDensity, waterEquivalentM3FromPhysicalVolume(1, 1.01));
    try std.testing.expectError(error.InvalidIceVolume, physicalVolumeM3FromWaterEquivalent(-1, reference_ice_density_megagrams_per_m3));
    try std.testing.expectError(error.InvalidIceHeatCapacity, heatCapacityPerWaterEquivalentM3K(0, reference_ice_density_megagrams_per_m3));
}

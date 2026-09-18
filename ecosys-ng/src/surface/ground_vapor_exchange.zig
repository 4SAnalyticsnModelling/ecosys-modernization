const std = @import("std");

/// Accepted WATSUB atmospheric vapor exchange for one physical owner. Positive
/// water is condensation into the owner; negative water is evaporation. The
/// represented pore vapor is consumed before liquid water, and only the liquid
/// leg carries latent heat. Carrier sensible heat follows the total transfer.
pub const Inputs = struct {
    time_step_hours: f64,
    /// Already FSNX*BAREW-partitioned WATSUB `PAREGM / dt`.
    vapor_conductance_m3_per_h: f64,
    air_vapor_volume_fraction: f64,
    vapor_fraction_conversion_k_per_kpa: f64,
    air_temperature_k: f64,
    owner_temperature_k: f64,
    owner_air_volume_m3: f64,
    owner_vapor_water_equivalent_m3: f64,
    owner_water_potential_megapascal: f64,
    owner_liquid_water_m3: f64,
    surface_vapor_activity_fraction: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_vaporization_megajoules_per_m3: f64,
};

pub const Accepted = struct {
    owner_vapor_volume_fraction: f64,
    unlimited_water_change_m3: f64,
    vapor_water_change_m3: f64,
    liquid_water_change_m3: f64,
    water_change_m3: f64,
    evaporation_m3: f64,
    condensation_m3: f64,
    latent_heat_megajoules: f64,
    carrier_sensible_heat_megajoules: f64,
    total_heat_megajoules: f64,
    vapor_evaporation_limited_by_owner: bool,
    liquid_evaporation_limited_by_owner: bool,
};

pub const PhaseSplit = struct {
    vapor_water_change_m3: f64,
    liquid_water_change_m3: f64,
    total_water_change_m3: f64,
    vapor_limited: bool,
    liquid_limited: bool,
};

/// WATSUB EVAP*V/EVAP*W. `unlimited_water_change_m3` and returned changes use
/// the owner sign convention (positive inward). This helper also accepts rates
/// when all three inputs use rate units.
pub fn splitVaporThenLiquid(
    unlimited_water_change_m3: f64,
    owner_vapor_water_equivalent_m3: f64,
    owner_liquid_water_m3: f64,
) !PhaseSplit {
    inline for (.{ unlimited_water_change_m3, owner_vapor_water_equivalent_m3, owner_liquid_water_m3 }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteGroundVaporPhaseSplit;
    if (owner_vapor_water_equivalent_m3 < 0 or owner_liquid_water_m3 < 0)
        return error.InvalidGroundVaporPhaseSplit;
    const vapor_change = @max(unlimited_water_change_m3, -owner_vapor_water_equivalent_m3);
    const liquid_remainder = unlimited_water_change_m3 - vapor_change;
    const liquid_change = @max(liquid_remainder, -owner_liquid_water_m3);
    return .{
        .vapor_water_change_m3 = vapor_change,
        .liquid_water_change_m3 = liquid_change,
        .total_water_change_m3 = vapor_change + liquid_change,
        .vapor_limited = vapor_change != unlimited_water_change_m3,
        .liquid_limited = liquid_change != liquid_remainder,
    };
}

pub fn accepted(inputs: Inputs) !Accepted {
    inline for (.{
        inputs.time_step_hours,
        inputs.vapor_conductance_m3_per_h,
        inputs.air_vapor_volume_fraction,
        inputs.vapor_fraction_conversion_k_per_kpa,
        inputs.air_temperature_k,
        inputs.owner_temperature_k,
        inputs.owner_air_volume_m3,
        inputs.owner_vapor_water_equivalent_m3,
        inputs.owner_water_potential_megapascal,
        inputs.owner_liquid_water_m3,
        inputs.surface_vapor_activity_fraction,
        inputs.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.latent_heat_of_vaporization_megajoules_per_m3,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteGroundVaporExchangeInput;
    if (inputs.time_step_hours <= 0 or inputs.time_step_hours > 1 or
        inputs.vapor_conductance_m3_per_h < 0 or
        inputs.air_vapor_volume_fraction < 0 or
        inputs.vapor_fraction_conversion_k_per_kpa <= 0 or inputs.air_temperature_k <= 0 or
        inputs.owner_temperature_k <= 0 or inputs.owner_air_volume_m3 < 0 or
        inputs.owner_vapor_water_equivalent_m3 < 0 or inputs.owner_liquid_water_m3 < 0 or
        inputs.surface_vapor_activity_fraction < 0 or inputs.surface_vapor_activity_fraction > 1 or
        inputs.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or
        inputs.latent_heat_of_vaporization_megajoules_per_m3 <= 0)
        return error.InvalidGroundVaporExchangeInput;

    const potential_factor = @exp(18.0 * inputs.owner_water_potential_megapascal /
        (8.3143 * inputs.owner_temperature_k));
    const owner_vapor_pressure_kpa = inputs.surface_vapor_activity_fraction *
        saturationVaporPressureKpa(inputs.owner_temperature_k) * potential_factor;
    const equilibrium_vapor_volume_fraction = owner_vapor_pressure_kpa *
        inputs.vapor_fraction_conversion_k_per_kpa / inputs.owner_temperature_k;
    const owner_vapor_volume_fraction = if (inputs.owner_air_volume_m3 > 0)
        inputs.owner_vapor_water_equivalent_m3 / inputs.owner_air_volume_m3
    else
        equilibrium_vapor_volume_fraction;
    const unlimited_water_change_m3 = inputs.vapor_conductance_m3_per_h *
        (inputs.air_vapor_volume_fraction - owner_vapor_volume_fraction) *
        inputs.time_step_hours;
    const split = try splitVaporThenLiquid(
        unlimited_water_change_m3,
        inputs.owner_vapor_water_equivalent_m3,
        inputs.owner_liquid_water_m3,
    );
    const water_change_m3 = split.total_water_change_m3;
    const donor_temperature_k = if (water_change_m3 >= 0)
        inputs.air_temperature_k
    else
        inputs.owner_temperature_k;
    const latent_heat_megajoules = split.liquid_water_change_m3 *
        inputs.latent_heat_of_vaporization_megajoules_per_m3;
    const carrier_sensible_heat_megajoules = water_change_m3 *
        inputs.liquid_water_heat_capacity_megajoules_per_m3_k * donor_temperature_k;
    const total_heat_megajoules = latent_heat_megajoules + carrier_sensible_heat_megajoules;
    inline for (.{ owner_vapor_pressure_kpa, owner_vapor_volume_fraction, unlimited_water_change_m3, split.vapor_water_change_m3, split.liquid_water_change_m3, water_change_m3, latent_heat_megajoules, carrier_sensible_heat_megajoules, total_heat_megajoules }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteGroundVaporExchangeResult;
    return .{
        .owner_vapor_volume_fraction = owner_vapor_volume_fraction,
        .unlimited_water_change_m3 = unlimited_water_change_m3,
        .vapor_water_change_m3 = split.vapor_water_change_m3,
        .liquid_water_change_m3 = split.liquid_water_change_m3,
        .water_change_m3 = water_change_m3,
        .evaporation_m3 = @max(0, -water_change_m3),
        .condensation_m3 = @max(0, water_change_m3),
        .latent_heat_megajoules = latent_heat_megajoules,
        .carrier_sensible_heat_megajoules = carrier_sensible_heat_megajoules,
        .total_heat_megajoules = total_heat_megajoules,
        .vapor_evaporation_limited_by_owner = split.vapor_limited,
        .liquid_evaporation_limited_by_owner = split.liquid_limited,
    };
}

pub fn saturationVaporPressureKpa(temperature_k: f64) f64 {
    return 0.61 * @exp(5360.0 * (3.661e-3 - 1.0 / temperature_k));
}

test "separate owner exchange preserves sign and donor-temperature energy" {
    const condensation = try accepted(.{
        .time_step_hours = 0.5,
        .vapor_conductance_m3_per_h = 0.2,
        .air_vapor_volume_fraction = 0.02,
        .vapor_fraction_conversion_k_per_kpa = 2.173e-3,
        .air_temperature_k = 290,
        .owner_temperature_k = 280,
        .owner_air_volume_m3 = 1,
        .owner_vapor_water_equivalent_m3 = 0,
        .owner_water_potential_megapascal = 0,
        .owner_liquid_water_m3 = 0,
        .surface_vapor_activity_fraction = 0.5,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2400,
    });
    try std.testing.expect(condensation.water_change_m3 > 0);
    try std.testing.expectEqual(@as(f64, 0), condensation.liquid_water_change_m3);
    try std.testing.expectEqual(@as(f64, 0), condensation.latent_heat_megajoules);
    try std.testing.expectApproxEqAbs(
        condensation.water_change_m3 * 4 * 290,
        condensation.carrier_sensible_heat_megajoules,
        1e-14,
    );

    const evaporation = try accepted(.{
        .time_step_hours = 1,
        .vapor_conductance_m3_per_h = 1,
        .air_vapor_volume_fraction = 0,
        .vapor_fraction_conversion_k_per_kpa = 2.173e-3,
        .air_temperature_k = 290,
        .owner_temperature_k = 280,
        .owner_air_volume_m3 = 1,
        .owner_vapor_water_equivalent_m3 = 0.001,
        .owner_water_potential_megapascal = 0,
        .owner_liquid_water_m3 = 1,
        .surface_vapor_activity_fraction = 1,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2400,
    });
    try std.testing.expect(evaporation.water_change_m3 < 0);
    try std.testing.expectApproxEqAbs(
        evaporation.water_change_m3 * 4 * 280,
        evaporation.carrier_sensible_heat_megajoules,
        1e-14,
    );
}

test "dry owner cap is atomic across water latent and sensible heat" {
    const dry = try accepted(.{
        .time_step_hours = 1,
        .vapor_conductance_m3_per_h = 1000,
        .air_vapor_volume_fraction = 0,
        .vapor_fraction_conversion_k_per_kpa = 2.173e-3,
        .air_temperature_k = 290,
        .owner_temperature_k = 300,
        .owner_air_volume_m3 = 0,
        .owner_vapor_water_equivalent_m3 = 0,
        .owner_water_potential_megapascal = 0,
        .owner_liquid_water_m3 = 0,
        .surface_vapor_activity_fraction = 1,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
    });
    try std.testing.expectEqual(@as(f64, 0), dry.water_change_m3);
    try std.testing.expectEqual(@as(f64, 0), dry.total_heat_megajoules);
    try std.testing.expect(dry.vapor_evaporation_limited_by_owner);
    try std.testing.expect(dry.liquid_evaporation_limited_by_owner);

    const limited = try accepted(.{
        .time_step_hours = 1,
        .vapor_conductance_m3_per_h = 1000,
        .air_vapor_volume_fraction = 0,
        .vapor_fraction_conversion_k_per_kpa = 2.173e-3,
        .air_temperature_k = 290,
        .owner_temperature_k = 300,
        .owner_air_volume_m3 = 0,
        .owner_vapor_water_equivalent_m3 = 0,
        .owner_water_potential_megapascal = 0,
        .owner_liquid_water_m3 = 0.002,
        .surface_vapor_activity_fraction = 1,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
    });
    try std.testing.expectEqual(@as(f64, -0.002), limited.water_change_m3);
    try std.testing.expectApproxEqAbs(-0.002 * (2465 + 4.19 * 300), limited.total_heat_megajoules, 1e-12);
}

test "invalid candidate cannot publish a partial activity" {
    try std.testing.expectError(error.InvalidGroundVaporExchangeInput, accepted(.{
        .time_step_hours = 1,
        .vapor_conductance_m3_per_h = -1,
        .air_vapor_volume_fraction = 1,
        .vapor_fraction_conversion_k_per_kpa = 2.173e-3,
        .air_temperature_k = 290,
        .owner_temperature_k = 280,
        .owner_air_volume_m3 = 1,
        .owner_vapor_water_equivalent_m3 = 0,
        .owner_water_potential_megapascal = 0,
        .owner_liquid_water_m3 = 1,
        .surface_vapor_activity_fraction = 1,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2400,
    }));
}

test "WATSUB phase split consumes represented vapor before liquid" {
    const split = try splitVaporThenLiquid(-0.5, 0.2, 0.1);
    try std.testing.expectEqual(@as(f64, -0.2), split.vapor_water_change_m3);
    try std.testing.expectEqual(@as(f64, -0.1), split.liquid_water_change_m3);
    try std.testing.expectApproxEqAbs(@as(f64, -0.3), split.total_water_change_m3, 1e-15);
    try std.testing.expect(split.vapor_limited);
    try std.testing.expect(split.liquid_limited);

    const condensation = try splitVaporThenLiquid(0.25, 0, 0);
    try std.testing.expectEqual(@as(f64, 0.25), condensation.vapor_water_change_m3);
    try std.testing.expectEqual(@as(f64, 0), condensation.liquid_water_change_m3);
}

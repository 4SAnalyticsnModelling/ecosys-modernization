//! **A5 DISPOSITION: never production bound.**
//!
//! Legacy source: `ecosys_f77/hour1.f` lines 3596--3622. This module is an exact,
//! tested, source-order translation of that range and is imported only by
//! `src/module_index.zig`, so it is reachable by `zig build test` and unreachable
//! from `executeHourlyScience`. That is intentional and must stay that way.
//!
//! Classification: architecturally superseded. Production stores the same physics in a
//! different representation, deliberately, with the deviation recorded in
//! `docs/model_changes.md`. Binding this kernel would reintroduce the
//! formulation the project chose to leave behind, as a second writer.
//!
//! Superseded by: `soil_solver_properties` + `soil_water_heat_step`, both
//! verified production bound. See the correction note in
//! `solid_thermal_porosity.zig`: `mineral_layer_phase_initialization` was
//! originally named here too and was removed because it is itself unbound.
//!
//! Same dual-domain reason as `soil_solid_thermal_porosity`: the legacy
//! single-domain air/water/ice fractions have no place to record the macropore
//! phase split that production transports through.
//!
//! Do not bind this module, and do not delete it: the tests are a source-order
//! comparison oracle for the range above. Full argument and the census behind
//! it: `docs/traceability/hour1_2039_5200_binding_survey.md`.
const std = @import("std");

pub const Inputs = struct {
    cell_width_x_m: f64,
    cell_width_y_m: f64,
    layer_thickness_m: f64,
    horizontal_area_m2: f64,
    micropore_volume_fraction: f64, // FMPR
    bulk_density_megagrams_m3: f64,
    micropore_capacity_m3: f64, // VOLA
    micropore_water_m3: f64,
    micropore_ice_m3: f64,
    macropore_capacity_m3: f64, // VOLAH
    macropore_water_m3: f64,
    macropore_ice_m3: f64,
    porosity_m3_m3: f64,
    volume_threshold_m3: f64,
    bulk_density_threshold_megagrams_m3: f64,
};

pub const Result = struct {
    lateral_area_x_m2: f64,
    lateral_area_y_m2: f64,
    total_layer_volume_m3: f64,
    rock_excluded_volume_m3: f64,
    effective_soil_volume_m3: f64,
    air_filled_pore_volume_m3: f64,
    micropore_water_fraction_m3_m3: f64,
    micropore_ice_fraction_m3_m3: f64,
    pore_air_fraction_m3_m3: f64,
    total_air_fraction_m3_m3: f64,
};

pub const CalculationError = error{
    NonFiniteInput,
    NegativeInput,
    InvalidFraction,
    NonFiniteResult,
};

/// Translates `hour1.f` lines 3596--3622 in source operation order.
pub fn calculate(inputs: Inputs) CalculationError!Result {
    inline for (std.meta.fields(Inputs)) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteInput;
        if (value < 0.0) return error.NegativeInput;
    }
    if (inputs.micropore_volume_fraction > 1.0 or inputs.porosity_m3_m3 > 1.0) {
        return error.InvalidFraction;
    }

    const lateral_area_x_m2 = inputs.layer_thickness_m * inputs.cell_width_y_m;
    const lateral_area_y_m2 = inputs.layer_thickness_m * inputs.cell_width_x_m;
    const total_layer_volume_m3 = inputs.horizontal_area_m2 * inputs.layer_thickness_m;
    const rock_excluded_volume_m3 =
        total_layer_volume_m3 * inputs.micropore_volume_fraction;
    const effective_soil_volume_m3 = rock_excluded_volume_m3;

    const air_filled_pore_volume_m3 =
        if (inputs.bulk_density_megagrams_m3 > inputs.bulk_density_threshold_megagrams_m3)
            @max(
                0.0,
                inputs.micropore_capacity_m3 -
                    inputs.micropore_water_m3 -
                    inputs.micropore_ice_m3,
            ) +
                @max(
                    0.0,
                    inputs.macropore_capacity_m3 -
                        inputs.macropore_water_m3 -
                        inputs.macropore_ice_m3,
                )
        else
            0.0;

    var micropore_water_fraction_m3_m3: f64 = undefined;
    var micropore_ice_fraction_m3_m3: f64 = undefined;
    var pore_air_fraction_m3_m3: f64 = undefined;
    if (effective_soil_volume_m3 <= inputs.volume_threshold_m3) {
        micropore_water_fraction_m3_m3 = inputs.porosity_m3_m3;
        micropore_ice_fraction_m3_m3 = 0.0;
        pore_air_fraction_m3_m3 = 0.0;
    } else {
        micropore_water_fraction_m3_m3 = @max(
            0.0,
            @min(
                inputs.porosity_m3_m3,
                inputs.micropore_water_m3 / effective_soil_volume_m3,
            ),
        );
        micropore_ice_fraction_m3_m3 = @max(
            0.0,
            @min(
                inputs.porosity_m3_m3,
                inputs.micropore_ice_m3 / effective_soil_volume_m3,
            ),
        );
        pore_air_fraction_m3_m3 =
            @max(0.0, air_filled_pore_volume_m3 / effective_soil_volume_m3);
    }
    const total_air_fraction_m3_m3 = @max(
        0.0,
        inputs.porosity_m3_m3 -
            micropore_water_fraction_m3_m3 -
            micropore_ice_fraction_m3_m3,
    );

    const result = Result{
        .lateral_area_x_m2 = lateral_area_x_m2,
        .lateral_area_y_m2 = lateral_area_y_m2,
        .total_layer_volume_m3 = total_layer_volume_m3,
        .rock_excluded_volume_m3 = rock_excluded_volume_m3,
        .effective_soil_volume_m3 = effective_soil_volume_m3,
        .air_filled_pore_volume_m3 = air_filled_pore_volume_m3,
        .micropore_water_fraction_m3_m3 = micropore_water_fraction_m3_m3,
        .micropore_ice_fraction_m3_m3 = micropore_ice_fraction_m3_m3,
        .pore_air_fraction_m3_m3 = pore_air_fraction_m3_m3,
        .total_air_fraction_m3_m3 = total_air_fraction_m3_m3,
    };
    inline for (std.meta.fields(Result)) |field| {
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteResult;
    }
    return result;
}

test "soil layer geometry and phase fractions preserve legacy equations" {
    const result = try calculate(.{
        .cell_width_x_m = 10.0,
        .cell_width_y_m = 20.0,
        .layer_thickness_m = 0.5,
        .horizontal_area_m2 = 200.0,
        .micropore_volume_fraction = 0.8,
        .bulk_density_megagrams_m3 = 1.2,
        .micropore_capacity_m3 = 40.0,
        .micropore_water_m3 = 20.0,
        .micropore_ice_m3 = 4.0,
        .macropore_capacity_m3 = 5.0,
        .macropore_water_m3 = 1.0,
        .macropore_ice_m3 = 0.0,
        .porosity_m3_m3 = 0.5,
        .volume_threshold_m3 = 1.0e-12,
        .bulk_density_threshold_megagrams_m3 = 1.0e-12,
    });
    try std.testing.expectEqual(@as(f64, 10.0), result.lateral_area_x_m2);
    try std.testing.expectEqual(@as(f64, 5.0), result.lateral_area_y_m2);
    try std.testing.expectEqual(@as(f64, 80.0), result.effective_soil_volume_m3);
    try std.testing.expectEqual(@as(f64, 20.0), result.air_filled_pore_volume_m3);
    try std.testing.expectEqual(@as(f64, 0.25), result.micropore_water_fraction_m3_m3);
}

test "negligible effective volume uses saturated legacy fallback" {
    const result = try calculate(.{
        .cell_width_x_m = 1.0,
        .cell_width_y_m = 1.0,
        .layer_thickness_m = 0.0,
        .horizontal_area_m2 = 1.0,
        .micropore_volume_fraction = 0.0,
        .bulk_density_megagrams_m3 = 0.0,
        .micropore_capacity_m3 = 0.0,
        .micropore_water_m3 = 0.0,
        .micropore_ice_m3 = 0.0,
        .macropore_capacity_m3 = 0.0,
        .macropore_water_m3 = 0.0,
        .macropore_ice_m3 = 0.0,
        .porosity_m3_m3 = 0.6,
        .volume_threshold_m3 = 0.0,
        .bulk_density_threshold_megagrams_m3 = 0.0,
    });
    try std.testing.expectEqual(@as(f64, 0.6), result.micropore_water_fraction_m3_m3);
    try std.testing.expectEqual(@as(f64, 0.0), result.total_air_fraction_m3_m3);
}

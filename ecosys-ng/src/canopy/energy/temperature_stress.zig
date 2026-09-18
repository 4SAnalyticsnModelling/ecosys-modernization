// **CURRENT DISPOSITION: SUPERSEDED; THIS DUPLICATE MODULE STAYS UNBOUND.**
// `canopy/photosynthesis/biochemistry.zig` owns the production translation:
// it consumes current hourly canopy temperature, applies prior-hour HEAT to
// C3 feedback, then updates CHILL/HEAT in UPTAKE source order. The historical
// A8a text below predates that binding and is retained only as provenance.
//
// **HISTORICAL A8a DISPOSITION: GAP, blocked on CANOPY-TKC-001.** This transcribes
// UPTAKE.F 1601--1610, the canopy chilling and heating stress accumulators, in
// exact source branch order: chilling accumulates toward a ceiling while the
// canopy surface temperature is below the chilling threshold and decays at the
// same rate above it, with the heating term recovering symmetrically.
// No bound module accumulates these. The chilling threshold that appears
// elsewhere in production, `chilling_temperature_c` in
// `plant/lifecycle/dormancy.zig` and its parameter blocks, is a different
// mechanism: it gates leafout hour accumulation directly from the current
// temperature and keeps no chilling store of its own. There is nothing in `src`
// that holds an accumulated chilling total for the canopy, so this is a genuine
// gap and not a duplicate.
// It is blocked rather than merely unbound because its driving input is the
// canopy surface temperature in Celsius, and `CANOPY-TKC-001` establishes that
// production's live canopy surface temperature is frozen at the site mean annual
// air temperature after planting. Bound as-is, the chilling branch would be
// decided once and then taken every hour for the plant's whole life, which is a
// worse failure than not accumulating at all.
// CANOPY-TKC-001 group of
// docs/traceability/canopy_surface_temperature_is_never_updated_hourly.md
const std = @import("std");

pub const Inputs = struct {
    canopy_surface_temperature_c: f64,
    chilling_threshold_c: f64,
    accumulated_chilling_h: f64,
    accumulated_heating_degree_h: f64,
    biological_timestep_h_per_step: f64,
    maximum_chilling_h: f64,
    chilling_accumulation_rate: f64,
    heating_threshold_c: f64,
    heating_recovery_rate_per_h: f64,
};

pub const Result = struct {
    accumulated_chilling_h: f64,
    accumulated_heating_degree_h: f64,
};

/// UPTAKE.F 1601--1610. Updates canopy chilling and heating stress in the
/// exact source branch order using runtime thresholds and rates.
pub fn calculate(inputs: Inputs) !Result {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.InvalidCanopyTemperatureStressInput;
    if (inputs.accumulated_chilling_h < 0 or
        inputs.accumulated_heating_degree_h < 0 or
        inputs.biological_timestep_h_per_step < 0 or
        inputs.maximum_chilling_h < 0 or
        inputs.chilling_accumulation_rate < 0 or
        inputs.heating_recovery_rate_per_h < 0)
        return error.InvalidCanopyTemperatureStressInput;
    const chilling =
        if (inputs.canopy_surface_temperature_c < inputs.chilling_threshold_c)
            @min(
                inputs.maximum_chilling_h,
                inputs.accumulated_chilling_h +
                    inputs.chilling_accumulation_rate *
                        inputs.biological_timestep_h_per_step,
            )
        else
            @max(
                0,
                inputs.accumulated_chilling_h -
                    inputs.chilling_accumulation_rate *
                        inputs.biological_timestep_h_per_step,
            );
    const heating =
        if (inputs.canopy_surface_temperature_c > inputs.heating_threshold_c)
            inputs.accumulated_heating_degree_h +
                (inputs.canopy_surface_temperature_c -
                    inputs.heating_threshold_c) *
                    inputs.biological_timestep_h_per_step
        else
            @max(
                0,
                inputs.accumulated_heating_degree_h -
                    inputs.heating_recovery_rate_per_h *
                        inputs.biological_timestep_h_per_step,
            );
    if (!std.math.isFinite(chilling) or !std.math.isFinite(heating))
        return error.NonFiniteCanopyTemperatureStressResult;
    return .{
        .accumulated_chilling_h = chilling,
        .accumulated_heating_degree_h = heating,
    };
}

test "cold canopy accumulates capped chilling and recovers heat" {
    const result = try calculate(.{
        .canopy_surface_temperature_c = 2,
        .chilling_threshold_c = 5,
        .accumulated_chilling_h = 23.5,
        .accumulated_heating_degree_h = 1,
        .biological_timestep_h_per_step = 1,
        .maximum_chilling_h = 24,
        .chilling_accumulation_rate = 1,
        .heating_threshold_c = 60,
        .heating_recovery_rate_per_h = 0.02,
    });
    try std.testing.expectEqual(@as(f64, 24), result.accumulated_chilling_h);
    try std.testing.expectEqual(@as(f64, 0.98), result.accumulated_heating_degree_h);
}

test "hot canopy releases chilling and accumulates degree hours" {
    const result = try calculate(.{
        .canopy_surface_temperature_c = 65,
        .chilling_threshold_c = 5,
        .accumulated_chilling_h = 2,
        .accumulated_heating_degree_h = 1,
        .biological_timestep_h_per_step = 0.5,
        .maximum_chilling_h = 24,
        .chilling_accumulation_rate = 1,
        .heating_threshold_c = 60,
        .heating_recovery_rate_per_h = 0.02,
    });
    try std.testing.expectEqual(@as(f64, 1.5), result.accumulated_chilling_h);
    try std.testing.expectEqual(@as(f64, 3.5), result.accumulated_heating_degree_h);
}

test "stress recovery retains zero floors" {
    const result = try calculate(.{
        .canopy_surface_temperature_c = 20,
        .chilling_threshold_c = 5,
        .accumulated_chilling_h = 0.2,
        .accumulated_heating_degree_h = 0.001,
        .biological_timestep_h_per_step = 1,
        .maximum_chilling_h = 24,
        .chilling_accumulation_rate = 1,
        .heating_threshold_c = 60,
        .heating_recovery_rate_per_h = 0.02,
    });
    try std.testing.expectEqual(@as(f64, 0), result.accumulated_chilling_h);
    try std.testing.expectEqual(@as(f64, 0), result.accumulated_heating_degree_h);
}

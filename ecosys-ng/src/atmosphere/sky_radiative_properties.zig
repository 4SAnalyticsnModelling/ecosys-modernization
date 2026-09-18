//! Sole production owner of the WTHR atmospheric radiative properties
//! (`wthr.f:243--262`): cloudiness CLD and sky emissivity EMM.
//!
//! Bound into production through `atmosphere/atmospheric_radiation.zig`
//! `prepare`, which previously carried this arithmetic inline as a second,
//! anonymous copy. The duplicate-owner screen flagged the pair at score 2.56 /
//! jaccard 0.35; the resolution was to delete the inline copy and bind this
//! module, not to mark it as a duplicate. Reasoning and the non-vacuity proof:
//! `docs/traceability/sky_radiative_properties_binding.md`.
//!
//! `prepare` must pass the RADZ-capped shortwave (`wthr.f:235`), not the raw
//! forcing value, or CLD can exceed the source's value.

const std = @import("std");

pub const Inputs = struct {
    outdoors: bool,
    extraterrestrial_shortwave_megajoules_per_m2_h: f64,
    incoming_shortwave_megajoules_per_m2_h: f64,
    atmospheric_vapor_pressure_kpa: f64,
    air_temperature_k: f64,
    minimum_outdoor_cloudiness_fraction: f64 = 0.2,
    maximum_outdoor_cloudiness_fraction: f64 = 1,
    phytotron_sky_emissivity_fraction: f64 = 0.97,
};

pub const Properties = struct {
    cloudiness_fraction: f64,
    sky_emissivity_fraction: f64,
};

/// Exact WTHR atmospheric radiative properties from wthr.f:238-263.
pub fn derive(inputs: Inputs) !Properties {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (field.type == bool) continue;
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteSkyRadiativePropertyInput;
    }
    if (inputs.extraterrestrial_shortwave_megajoules_per_m2_h < 0 or
        inputs.incoming_shortwave_megajoules_per_m2_h < 0 or
        inputs.atmospheric_vapor_pressure_kpa < 0 or
        inputs.air_temperature_k <= 0 or
        inputs.minimum_outdoor_cloudiness_fraction < 0 or
        inputs.maximum_outdoor_cloudiness_fraction >
            1 or
        inputs.minimum_outdoor_cloudiness_fraction >
            inputs.maximum_outdoor_cloudiness_fraction or
        inputs.phytotron_sky_emissivity_fraction < 0 or
        inputs.phytotron_sky_emissivity_fraction > 1)
        return error.InvalidSkyRadiativePropertyInput;

    if (!inputs.outdoors) {
        return .{
            .cloudiness_fraction = 0,
            .sky_emissivity_fraction = inputs.phytotron_sky_emissivity_fraction,
        };
    }

    const cloudiness = if (inputs.extraterrestrial_shortwave_megajoules_per_m2_h > 0)
        std.math.clamp(
            2.33 - 3.33 *
                inputs.incoming_shortwave_megajoules_per_m2_h /
                inputs.extraterrestrial_shortwave_megajoules_per_m2_h,
            inputs.minimum_outdoor_cloudiness_fraction,
            inputs.maximum_outdoor_cloudiness_fraction,
        )
    else
        inputs.minimum_outdoor_cloudiness_fraction;
    var emissivity =
        0.625 * @max(
            1.0,
            std.math.pow(
                f64,
                1.0e3 * inputs.atmospheric_vapor_pressure_kpa /
                    inputs.air_temperature_k,
                0.131,
            ),
        );
    emissivity *=
        1.0 + 0.242 * std.math.pow(f64, cloudiness, 0.583);
    if (!std.math.isFinite(emissivity))
        return error.SkyRadiativePropertyOverflow;
    return .{
        .cloudiness_fraction = cloudiness,
        .sky_emissivity_fraction = emissivity,
    };
}

test "clear outdoor sky clamps cloudiness to source minimum" {
    const result = try derive(.{
        .outdoors = true,
        .extraterrestrial_shortwave_megajoules_per_m2_h = 4,
        .incoming_shortwave_megajoules_per_m2_h = 4,
        .atmospheric_vapor_pressure_kpa = 1,
        .air_temperature_k = 290,
    });
    try std.testing.expectEqual(
        @as(f64, 0.2),
        result.cloudiness_fraction,
    );
    try std.testing.expect(result.sky_emissivity_fraction > 0.625);
}

test "dark outdoor hour uses source minimum cloudiness branch" {
    const result = try derive(.{
        .outdoors = true,
        .extraterrestrial_shortwave_megajoules_per_m2_h = 0,
        .incoming_shortwave_megajoules_per_m2_h = 0,
        .atmospheric_vapor_pressure_kpa = 0,
        .air_temperature_k = 270,
    });
    const expected =
        0.625 * (1 + 0.242 * std.math.pow(f64, 0.2, 0.583));
    try std.testing.expectEqual(@as(f64, 0.2), result.cloudiness_fraction);
    try std.testing.expectEqual(expected, result.sky_emissivity_fraction);
}

test "opaque outdoor sky clamps cloudiness to one" {
    const result = try derive(.{
        .outdoors = true,
        .extraterrestrial_shortwave_megajoules_per_m2_h = 4,
        .incoming_shortwave_megajoules_per_m2_h = 0,
        .atmospheric_vapor_pressure_kpa = 1,
        .air_temperature_k = 290,
    });
    try std.testing.expectEqual(@as(f64, 1), result.cloudiness_fraction);
}

test "phytotron uses exact fixed source properties" {
    const result = try derive(.{
        .outdoors = false,
        .extraterrestrial_shortwave_megajoules_per_m2_h = 0,
        .incoming_shortwave_megajoules_per_m2_h = 0,
        .atmospheric_vapor_pressure_kpa = 0,
        .air_temperature_k = 290,
    });
    try std.testing.expectEqual(@as(f64, 0), result.cloudiness_fraction);
    try std.testing.expectEqual(
        @as(f64, 0.97),
        result.sky_emissivity_fraction,
    );
}

test "nonfinite late input fails before returning sky properties" {
    try std.testing.expectError(
        error.NonFiniteSkyRadiativePropertyInput,
        derive(.{
            .outdoors = true,
            .extraterrestrial_shortwave_megajoules_per_m2_h = 1,
            .incoming_shortwave_megajoules_per_m2_h = 0.5,
            .atmospheric_vapor_pressure_kpa = std.math.nan(f64),
            .air_temperature_k = 290,
        }),
    );
}

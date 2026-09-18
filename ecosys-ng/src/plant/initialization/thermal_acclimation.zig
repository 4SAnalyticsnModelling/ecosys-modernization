// **A8a DISPOSITION: unwired pure kernel, superseded; do not bind piecemeal.**
// Source: `startq.f` 320--348.
// Covered by production: `plant_initialization.thermalAcclimation` and `initializeThermalAcclimation`, dispatched at `ecosys_ng.zig:2449` and `:2506`.
// This is NOT a double-mutation case. Nothing in `ecosys_ng.zig` names this
// module, and its entry point takes only structs it defines itself, so it has no
// path to production state and cannot compete for ownership. It is retained, not
// deleted, because it carries an exact source range and tests; binding it is part
// of the single consolidation refactor tracked as INIT-004, not an isolated wire.
// Group INDEX of docs/traceability/plant_initialization_unbound_family_are_unwired_kernels_not_competing_owners.md
const std = @import("std");

pub const PhotosynthesisPathway = enum {
    c3,
    c4,
};

pub const Parameters = struct {
    leafout_base_temperature_c: f64,
    leafoff_base_temperature_c: f64,
    adaptation_zone_pivot: f64,
    cold_zone_offset_c_per_zone: f64,
    warm_zone_offset_c_per_zone: f64,
    maximum_leafoff_temperature_c: f64,
    high_temperature_zone_slope_c_per_zone: f64,
    c3_default_high_temperature_intercept_c: f64,
    c3_default_seed_set_sensitivity_per_c_h: f64,
    soybean_high_temperature_intercept_c: f64,
    soybean_seed_set_sensitivity_per_c_h: f64,
    c4_high_temperature_intercept_c: f64,
    c4_default_seed_set_sensitivity_per_c_h: f64,
    maize_seed_set_sensitivity_per_c_h: f64,
    soybean_identifier_prefix: []const u8,
    maize_identifier_prefix: []const u8,
};

pub const Result = struct {
    adaptation_zone: f64,
    temperature_offset_c: f64,
    leafout_threshold_temperature_c: f64,
    leafoff_threshold_temperature_c: f64,
    seed_set_high_temperature_threshold_c: f64,
    seed_set_temperature_sensitivity_per_c_h: f64,
};

pub const InitializationError = error{
    NonFiniteInput,
    EmptySpeciesPrefix,
    InvalidSensitivity,
    NonFiniteResult,
};

/// Translates `startq.f` lines 320--348 for one plant species.
///
/// Species-prefix matching is ASCII case-insensitive, so `SOYB`, `Soyb`, and
/// `soyb` select the same trait branch.
pub fn initialize(
    initial_adaptation_zone: f64,
    pathway: PhotosynthesisPathway,
    species_identifier: []const u8,
    parameters: Parameters,
) InitializationError!Result {
    if (!std.math.isFinite(initial_adaptation_zone)) return error.NonFiniteInput;
    inline for (std.meta.fields(Parameters)) |field| {
        if (field.type == f64 and !std.math.isFinite(@field(parameters, field.name))) {
            return error.NonFiniteInput;
        }
    }
    if (parameters.soybean_identifier_prefix.len == 0 or
        parameters.maize_identifier_prefix.len == 0)
    {
        return error.EmptySpeciesPrefix;
    }
    if (parameters.c3_default_seed_set_sensitivity_per_c_h < 0.0 or
        parameters.soybean_seed_set_sensitivity_per_c_h < 0.0 or
        parameters.c4_default_seed_set_sensitivity_per_c_h < 0.0 or
        parameters.maize_seed_set_sensitivity_per_c_h < 0.0)
    {
        return error.InvalidSensitivity;
    }

    const temperature_offset_c =
        if (initial_adaptation_zone <= parameters.adaptation_zone_pivot)
            parameters.cold_zone_offset_c_per_zone *
                (parameters.adaptation_zone_pivot - initial_adaptation_zone)
        else
            parameters.warm_zone_offset_c_per_zone *
                (parameters.adaptation_zone_pivot - initial_adaptation_zone);
    const leafout_threshold_c =
        parameters.leafout_base_temperature_c - temperature_offset_c;
    const leafoff_threshold_c = @min(
        parameters.maximum_leafoff_temperature_c,
        parameters.leafoff_base_temperature_c - temperature_offset_c,
    );

    const is_soybean = startsWithIgnoreCase(
        species_identifier,
        parameters.soybean_identifier_prefix,
    );
    const is_maize = startsWithIgnoreCase(
        species_identifier,
        parameters.maize_identifier_prefix,
    );
    const high_temperature_intercept_c = switch (pathway) {
        .c3 => if (is_soybean)
            parameters.soybean_high_temperature_intercept_c
        else
            parameters.c3_default_high_temperature_intercept_c,
        .c4 => parameters.c4_high_temperature_intercept_c,
    };
    const sensitivity_per_c_h = switch (pathway) {
        .c3 => if (is_soybean)
            parameters.soybean_seed_set_sensitivity_per_c_h
        else
            parameters.c3_default_seed_set_sensitivity_per_c_h,
        .c4 => if (is_maize)
            parameters.maize_seed_set_sensitivity_per_c_h
        else
            parameters.c4_default_seed_set_sensitivity_per_c_h,
    };

    const result = Result{
        .adaptation_zone = initial_adaptation_zone,
        .temperature_offset_c = temperature_offset_c,
        .leafout_threshold_temperature_c = leafout_threshold_c,
        .leafoff_threshold_temperature_c = leafoff_threshold_c,
        .seed_set_high_temperature_threshold_c = high_temperature_intercept_c +
            parameters.high_temperature_zone_slope_c_per_zone * initial_adaptation_zone,
        .seed_set_temperature_sensitivity_per_c_h = sensitivity_per_c_h,
    };
    inline for (std.meta.fields(Result)) |field| {
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteResult;
    }
    return result;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn legacyParameters() Parameters {
    return .{
        .leafout_base_temperature_c = 5.0,
        .leafoff_base_temperature_c = 12.5,
        .adaptation_zone_pivot = 3.0,
        .cold_zone_offset_c_per_zone = 2.5,
        .warm_zone_offset_c_per_zone = 1.25,
        .maximum_leafoff_temperature_c = 15.0,
        .high_temperature_zone_slope_c_per_zone = 2.0,
        .c3_default_high_temperature_intercept_c = 27.5,
        .c3_default_seed_set_sensitivity_per_c_h = 0.005,
        .soybean_high_temperature_intercept_c = 35.0,
        .soybean_seed_set_sensitivity_per_c_h = 0.002,
        .c4_high_temperature_intercept_c = 30.0,
        .c4_default_seed_set_sensitivity_per_c_h = 0.002,
        .maize_seed_set_sensitivity_per_c_h = 0.010,
        .soybean_identifier_prefix = "soyb",
        .maize_identifier_prefix = "maiz",
    };
}

test "soybean prefix is case-insensitive and uses C3 special thresholds" {
    const result = try initialize(2.0, .c3, "SoYBean", legacyParameters());
    try std.testing.expectEqual(@as(f64, 2.5), result.temperature_offset_c);
    try std.testing.expectEqual(@as(f64, 2.5), result.leafout_threshold_temperature_c);
    try std.testing.expectEqual(@as(f64, 10.0), result.leafoff_threshold_temperature_c);
    try std.testing.expectEqual(
        @as(f64, 39.0),
        result.seed_set_high_temperature_threshold_c,
    );
    try std.testing.expectEqual(
        @as(f64, 0.002),
        result.seed_set_temperature_sensitivity_per_c_h,
    );
}

test "maize and generic C4 share threshold but retain distinct sensitivity" {
    const parameters = legacyParameters();
    const maize = try initialize(4.0, .c4, "MAIZE", parameters);
    const generic = try initialize(4.0, .c4, "sorghum", parameters);

    try std.testing.expectEqual(
        maize.seed_set_high_temperature_threshold_c,
        generic.seed_set_high_temperature_threshold_c,
    );
    try std.testing.expectEqual(
        @as(f64, 0.010),
        maize.seed_set_temperature_sensitivity_per_c_h,
    );
    try std.testing.expectEqual(
        @as(f64, 0.002),
        generic.seed_set_temperature_sensitivity_per_c_h,
    );
    try std.testing.expectEqual(@as(f64, -1.25), maize.temperature_offset_c);
}

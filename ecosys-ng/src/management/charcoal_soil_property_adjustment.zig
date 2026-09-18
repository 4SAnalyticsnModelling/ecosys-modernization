// **A8a DISPOSITION: BOUND.** `runtime_material_refresh.refreshAcceptedHour`
// applies the signed current-minus-prior OSC charcoal delta once at the next
// fixed-hour HOUR1 boundary. This covers fertilizer, fire, decomposition and
// redistribution through the same authoritative organic owner.
//
// The legacy block is `hour1.f:3720--3725`, read verbatim and confirmed line for
// line against this file. Under `IF(VOLY.GT.ZEROS)`, applied charcoal raises four
// soil properties of the receiving layer: `FC` and `WP` each by
// `1.0E-06*DORGCC/VOLY`, and `CEC` and `AEC` each by `1.0E-03*DORGCC/VOLY`. This
// module is a faithful pure function of exactly those four statements, volume
// guard included.
//
// Register: DIST-022 in docs/discrepancy_register.md.
// M1 organic-amendment group of
// docs/traceability/management_unbound_family_is_superseded_by_the_schedule_dispatchers.md
const std = @import("std");

pub const Properties = struct {
    field_capacity_m3_m3: f64,
    wilting_point_m3_m3: f64,
    cation_exchange_capacity_mol_per_megagram: f64,
    anion_exchange_capacity_mol_per_megagram: f64,
};

pub const AdjustmentError = error{
    NonFiniteInput,
    NegativeInput,
    InvalidWaterRetention,
    NonFiniteResult,
};

pub const Deltas = struct {
    retention_fraction: f64,
    exchange_capacity_mol_per_megagram: f64,
};

/// Exact signed HOUR1 coefficients. DORGCC may be negative when charcoal is
/// combusted, decomposed, eroded, or redistributed away from a layer.
pub fn signedDeltas(
    charcoal_carbon_delta_g: f64,
    effective_soil_volume_m3: f64,
    volume_threshold_m3: f64,
) AdjustmentError!Deltas {
    inline for (.{ charcoal_carbon_delta_g, effective_soil_volume_m3, volume_threshold_m3 }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteInput;
    if (effective_soil_volume_m3 < 0 or volume_threshold_m3 < 0)
        return error.NegativeInput;
    if (effective_soil_volume_m3 <= volume_threshold_m3)
        return .{ .retention_fraction = 0, .exchange_capacity_mol_per_megagram = 0 };
    const result: Deltas = .{
        .retention_fraction = 1.0e-6 * charcoal_carbon_delta_g / effective_soil_volume_m3,
        .exchange_capacity_mol_per_megagram = 1.0e-3 * charcoal_carbon_delta_g / effective_soil_volume_m3,
    };
    if (!std.math.isFinite(result.retention_fraction) or
        !std.math.isFinite(result.exchange_capacity_mol_per_megagram))
        return error.NonFiniteResult;
    return result;
}

/// Translates `hour1.f` lines 3720--3725. `charcoal_carbon_g` is legacy DORGCC
/// and `effective_soil_volume_m3` is VOLY.
pub fn adjust(
    properties: Properties,
    charcoal_carbon_g: f64,
    effective_soil_volume_m3: f64,
    volume_threshold_m3: f64,
) AdjustmentError!Properties {
    inline for (std.meta.fields(Properties)) |field| {
        const value = @field(properties, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteInput;
        if (value < 0.0) return error.NegativeInput;
    }
    if (properties.field_capacity_m3_m3 > 1.0 or properties.wilting_point_m3_m3 > 1.0) {
        return error.InvalidWaterRetention;
    }
    const delta = try signedDeltas(charcoal_carbon_g, effective_soil_volume_m3, volume_threshold_m3);

    const adjusted = Properties{
        .field_capacity_m3_m3 = properties.field_capacity_m3_m3 + delta.retention_fraction,
        .wilting_point_m3_m3 = properties.wilting_point_m3_m3 + delta.retention_fraction,
        .cation_exchange_capacity_mol_per_megagram = properties.cation_exchange_capacity_mol_per_megagram + delta.exchange_capacity_mol_per_megagram,
        .anion_exchange_capacity_mol_per_megagram = properties.anion_exchange_capacity_mol_per_megagram + delta.exchange_capacity_mol_per_megagram,
    };
    inline for (std.meta.fields(Properties)) |field| {
        if (!std.math.isFinite(@field(adjusted, field.name))) return error.NonFiniteResult;
    }
    if (adjusted.field_capacity_m3_m3 < 0 or adjusted.wilting_point_m3_m3 < 0 or
        adjusted.cation_exchange_capacity_mol_per_megagram < 0 or
        adjusted.anion_exchange_capacity_mol_per_megagram < 0 or
        adjusted.field_capacity_m3_m3 > 1.0 or
        adjusted.wilting_point_m3_m3 > adjusted.field_capacity_m3_m3)
    {
        return error.InvalidWaterRetention;
    }
    return adjusted;
}

test "signed charcoal loss reverses all four source coefficients" {
    const adjusted = try adjust(.{
        .field_capacity_m3_m3 = 0.31,
        .wilting_point_m3_m3 = 0.11,
        .cation_exchange_capacity_mol_per_megagram = 30.0,
        .anion_exchange_capacity_mol_per_megagram = 12.0,
    }, -100_000.0, 10.0, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0.30), adjusted.field_capacity_m3_m3);
    try std.testing.expectEqual(@as(f64, 0.10), adjusted.wilting_point_m3_m3);
    try std.testing.expectEqual(@as(f64, 20.0), adjusted.cation_exchange_capacity_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 2.0), adjusted.anion_exchange_capacity_mol_per_megagram);
}

test "charcoal increments retention and exchange capacities in source order" {
    const adjusted = try adjust(.{
        .field_capacity_m3_m3 = 0.30,
        .wilting_point_m3_m3 = 0.10,
        .cation_exchange_capacity_mol_per_megagram = 20.0,
        .anion_exchange_capacity_mol_per_megagram = 2.0,
    }, 100_000.0, 10.0, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0.31), adjusted.field_capacity_m3_m3);
    try std.testing.expectEqual(@as(f64, 0.11), adjusted.wilting_point_m3_m3);
    try std.testing.expectEqual(@as(f64, 30.0), adjusted.cation_exchange_capacity_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 12.0), adjusted.anion_exchange_capacity_mol_per_megagram);
}

test "volume at threshold preserves existing properties" {
    const properties = Properties{
        .field_capacity_m3_m3 = 0.30,
        .wilting_point_m3_m3 = 0.10,
        .cation_exchange_capacity_mol_per_megagram = 20.0,
        .anion_exchange_capacity_mol_per_megagram = 2.0,
    };
    try std.testing.expectEqual(properties, try adjust(properties, 100.0, 0.0, 0.0));
}

//! Accepted bottom-snow liquid enthalpy publication to the surface litter.
//!
//! WATSUB 1600--1633 forms litter/soil meltwater and donor-temperature heat;
//! 2534--2579 adds both carrier and heat to the recipient before its
//! temperature is published.  The stage owns the split and calls this pure
//! candidate before committing the litter state.

const std = @import("std");

pub const Candidate = struct {
    heat_capacity_megajoules_per_k: f64,
    temperature_k: f64,
};

pub const RecipientHeatSplit = struct {
    litter_megajoules: f64,
    topsoil_megajoules: f64,
    total_megajoules: f64,
};

/// Forms each accepted recipient's donor-temperature heat from the same water
/// partition that recipient owns, then defines the snow donor ledger as their
/// exact stored sum. Deriving one recipient by subtracting a ratio-scaled
/// sibling from a separately rounded total can manufacture a tiny negative
/// heat when nearly all discharge follows one path.
pub fn acceptedRecipientHeatSplit(
    litter_water_m3: f64,
    topsoil_water_m3: f64,
    donor_temperature_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
) !RecipientHeatSplit {
    inline for (.{
        litter_water_m3,
        topsoil_water_m3,
        donor_temperature_k,
        liquid_water_heat_capacity_megajoules_per_m3_k,
    }) |value| if (!std.math.isFinite(value))
        return error.InvalidSnowDischargeRecipientState;
    if (litter_water_m3 < 0 or topsoil_water_m3 < 0 or
        donor_temperature_k <= 0 or
        liquid_water_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidSnowDischargeRecipientState;
    const specific_heat = liquid_water_heat_capacity_megajoules_per_m3_k *
        donor_temperature_k;
    const litter_heat = specific_heat * litter_water_m3;
    const topsoil_heat = specific_heat * topsoil_water_m3;
    const total_heat = litter_heat + topsoil_heat;
    inline for (.{ specific_heat, litter_heat, topsoil_heat, total_heat }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSnowDischargeRecipientState;
    return .{
        .litter_megajoules = litter_heat,
        .topsoil_megajoules = topsoil_heat,
        .total_megajoules = total_heat,
    };
}

/// The soil water ingress owner publishes accepted meltwater into the live
/// topsoil carrier before the spatial heat solve.  That state change already
/// represents `Cl * Tsoil * dW` in the canonical enthalpy census, so the heat
/// residual must receive only the donor-temperature remainder.
pub fn acceptedTopsoilHeatRemainder(
    accepted_water_m3: f64,
    accepted_heat_megajoules: f64,
    recipient_temperature_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
) !f64 {
    inline for (.{
        accepted_water_m3,
        accepted_heat_megajoules,
        recipient_temperature_k,
        liquid_water_heat_capacity_megajoules_per_m3_k,
    }) |value| if (!std.math.isFinite(value)) return error.InvalidSnowDischargeRecipientState;
    if (accepted_water_m3 < 0 or accepted_heat_megajoules < 0 or
        recipient_temperature_k <= 0 or
        liquid_water_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidSnowDischargeRecipientState;
    const represented_storage_heat = liquid_water_heat_capacity_megajoules_per_m3_k *
        recipient_temperature_k * accepted_water_m3;
    const remainder = accepted_heat_megajoules - represented_storage_heat;
    if (!std.math.isFinite(represented_storage_heat) or !std.math.isFinite(remainder))
        return error.InvalidSnowDischargeRecipientState;
    return remainder;
}

pub fn acceptedLitterCandidate(
    old_capacity_megajoules_per_k: f64,
    old_temperature_k: f64,
    accepted_water_m3: f64,
    accepted_heat_megajoules: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
) !Candidate {
    inline for (.{
        old_capacity_megajoules_per_k,
        old_temperature_k,
        accepted_water_m3,
        accepted_heat_megajoules,
        liquid_water_heat_capacity_megajoules_per_m3_k,
    }) |value| if (!std.math.isFinite(value)) return error.InvalidSnowDischargeRecipientState;
    if (old_capacity_megajoules_per_k <= 0 or old_temperature_k <= 0 or
        accepted_water_m3 < 0 or accepted_heat_megajoules < 0 or
        liquid_water_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidSnowDischargeRecipientState;
    const new_capacity = old_capacity_megajoules_per_k +
        liquid_water_heat_capacity_megajoules_per_m3_k * accepted_water_m3;
    const new_energy = old_capacity_megajoules_per_k * old_temperature_k +
        accepted_heat_megajoules;
    const new_temperature = new_energy / new_capacity;
    if (!std.math.isFinite(new_capacity) or new_capacity <= 0 or
        !std.math.isFinite(new_energy) or
        !std.math.isFinite(new_temperature) or new_temperature <= 0)
        return error.InvalidSnowDischargeRecipientState;
    return .{
        .heat_capacity_megajoules_per_k = new_capacity,
        .temperature_k = new_temperature,
    };
}

test "accepted snow discharge adds donor-temperature enthalpy to litter carrier" {
    const old_capacity: f64 = 12;
    const old_temperature: f64 = 280;
    const water: f64 = 0.4;
    const liquid_capacity: f64 = 4.19;
    const donor_temperature: f64 = 272;
    const heat = liquid_capacity * donor_temperature * water;
    const candidate = try acceptedLitterCandidate(
        old_capacity,
        old_temperature,
        water,
        heat,
        liquid_capacity,
    );
    try std.testing.expectEqual(old_capacity + liquid_capacity * water, candidate.heat_capacity_megajoules_per_k);
    try std.testing.expectApproxEqAbs(
        old_capacity * old_temperature + heat,
        candidate.heat_capacity_megajoules_per_k * candidate.temperature_k,
        64 * std.math.floatEps(f64) * (old_capacity * old_temperature + heat),
    );
    try std.testing.expect(candidate.temperature_k < old_temperature);
    try std.testing.expect(candidate.temperature_k > donor_temperature);
    try std.testing.expectError(
        error.InvalidSnowDischargeRecipientState,
        acceptedLitterCandidate(old_capacity, old_temperature, -water, heat, liquid_capacity),
    );
}

test "accepted snow discharge heat split has exact nonnegative recipient sum" {
    const split = try acceptedRecipientHeatSplit(
        0.125,
        std.math.floatTrueMin(f64),
        272.75,
        4.19,
    );
    try std.testing.expect(split.litter_megajoules >= 0);
    try std.testing.expect(split.topsoil_megajoules >= 0);
    try std.testing.expectEqual(
        split.litter_megajoules + split.topsoil_megajoules,
        split.total_megajoules,
    );
    try std.testing.expectError(
        error.InvalidSnowDischargeRecipientState,
        acceptedRecipientHeatSplit(-0.125, 0, 272.75, 4.19),
    );
}

test "accepted topsoil meltwater publishes only unrepresented donor heat" {
    const liquid_capacity: f64 = 4.19;
    const water: f64 = 2.8e-6;
    const donor_temperature: f64 = 273.0;
    const recipient_temperature: f64 = 269.5;
    const donor_heat = liquid_capacity * donor_temperature * water;
    const remainder = try acceptedTopsoilHeatRemainder(
        water,
        donor_heat,
        recipient_temperature,
        liquid_capacity,
    );
    try std.testing.expectApproxEqAbs(
        liquid_capacity * (donor_temperature - recipient_temperature) * water,
        remainder,
        1e-18,
    );
    try std.testing.expectError(
        error.InvalidSnowDischargeRecipientState,
        acceptedTopsoilHeatRemainder(-water, donor_heat, recipient_temperature, liquid_capacity),
    );
}

// **A8a DISPOSITION: BOUND.** This is one member of the A4e BIND2
// litter/topsoil transfer family translated from REDIST/TRNSFRS. Production
// calls the complete six-kernel source-order family through
// `litter_soil_interface.advance`, from
// `stages/hourly_heat_water_solute.zig:advanceLitterSoilInterface`.
//
// The production transaction uses the accepted litter/soil Darcy water flux,
// projects the canonical runtime species into the source-order compatibility
// widths, transfers salt, phosphate, dissolved organic C/N/P/acetate, and
// mineral N/P, verifies donor admissibility and pair closure in native units,
// and only then publishes all authoritative owners. Water and sensible heat
// are transferred in the same stage transaction. Failed recovery attempts are
// restored by the enclosing heat/water/solute stage snapshot.
//
// This hourly porous-interface owner is distinct from
// `pond_domain_transaction`, which transfers only the pond-transition
// disturbance fraction.
const std = @import("std");

pub const litter_species_count = 42;
pub const soil_species_count = 50;
const pre_phosphate_species_count = 34;

pub const Contributions = struct {
    /// Per-field amount step-1; free PO4/H3PO4 are g P, others are mol.
    snow_litter_flux_amount_per_step: []const f64,
    snow_soil_flux_amount_per_step: []const f64,
    /// Positive litter-to-soil interface flux in the same per-field units.
    convective_flux_amount_per_step: []const f64,
    diffusive_flux_amount_per_step: []const f64,
};

/// Exact source-order accumulation for REDIST from TRNSFRS.F lines 2939--3088.
/// Litter phosphate accumulators lose both soil phosphate domains; soil
/// accumulators receive their corresponding domain. Validation is atomic.
pub fn accumulate(
    contributions: Contributions,
    litter_accumulated_flux_amount_per_step: []f64,
    soil_accumulated_flux_amount_per_step: []f64,
) !void {
    inline for (.{ contributions.snow_litter_flux_amount_per_step.len, litter_accumulated_flux_amount_per_step.len }) |len|
        if (len != litter_species_count) return error.LitterSoilSoluteAccumulationDimensionMismatch;
    inline for (.{ contributions.snow_soil_flux_amount_per_step.len, contributions.convective_flux_amount_per_step.len, contributions.diffusive_flux_amount_per_step.len, soil_accumulated_flux_amount_per_step.len }) |len|
        if (len != soil_species_count) return error.LitterSoilSoluteAccumulationDimensionMismatch;
    try validate(contributions, litter_accumulated_flux_amount_per_step, soil_accumulated_flux_amount_per_step);

    for (0..litter_species_count) |species| {
        const result = litter_accumulated_flux_amount_per_step[species] + litterIncrement(contributions, species);
        if (!std.math.isFinite(result)) return error.NonFiniteLitterSoilSoluteAccumulationResult;
    }
    for (0..soil_species_count) |species| {
        const result = soil_accumulated_flux_amount_per_step[species] + soilIncrement(contributions, species);
        if (!std.math.isFinite(result)) return error.NonFiniteLitterSoilSoluteAccumulationResult;
    }
    for (0..litter_species_count) |species|
        litter_accumulated_flux_amount_per_step[species] += litterIncrement(contributions, species);
    for (0..soil_species_count) |species|
        soil_accumulated_flux_amount_per_step[species] += soilIncrement(contributions, species);
}

fn litterIncrement(contributions: Contributions, species: usize) f64 {
    var increment = contributions.snow_litter_flux_amount_per_step[species] -
        contributions.convective_flux_amount_per_step[species] -
        contributions.diffusive_flux_amount_per_step[species];
    if (species >= pre_phosphate_species_count) {
        increment -= contributions.convective_flux_amount_per_step[species + 8] +
            contributions.diffusive_flux_amount_per_step[species + 8];
    }
    return increment;
}

fn soilIncrement(contributions: Contributions, species: usize) f64 {
    return contributions.snow_soil_flux_amount_per_step[species] +
        contributions.convective_flux_amount_per_step[species] +
        contributions.diffusive_flux_amount_per_step[species];
}

fn validate(contributions: Contributions, litter: []const f64, soil: []const f64) !void {
    inline for (.{ contributions.snow_litter_flux_amount_per_step, contributions.snow_soil_flux_amount_per_step, contributions.convective_flux_amount_per_step, contributions.diffusive_flux_amount_per_step, litter, soil }) |values|
        for (values) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilSoluteAccumulationInput;
}

fn fixture(snow_litter: []const f64, snow_soil: []const f64, convective: []const f64, diffusive: []const f64) Contributions {
    return .{ .snow_litter_flux_amount_per_step = snow_litter, .snow_soil_flux_amount_per_step = snow_soil, .convective_flux_amount_per_step = convective, .diffusive_flux_amount_per_step = diffusive };
}

test "TRNSFRS accumulates increments without prior boundary totals" {
    const snow_litter = [_]f64{2} ** litter_species_count;
    const snow_soil = [_]f64{3} ** soil_species_count;
    const convective = [_]f64{1} ** soil_species_count;
    const diffusive = [_]f64{0.5} ** soil_species_count;
    var litter = [_]f64{10} ** litter_species_count;
    var soil = [_]f64{20} ** soil_species_count;
    try accumulate(fixture(&snow_litter, &snow_soil, &convective, &diffusive), &litter, &soil);
    try std.testing.expectEqual(@as(f64, 10.5), litter[0]);
    try std.testing.expectEqual(@as(f64, 9), litter[34]);
    try std.testing.expectEqual(@as(f64, 24.5), soil[0]);
    try std.testing.expectEqual(@as(f64, 24.5), soil[42]);
}

test "interface-only increments conserve phosphate across domains" {
    const snow_litter = [_]f64{0} ** litter_species_count;
    const snow_soil = [_]f64{0} ** soil_species_count;
    var convective = [_]f64{0} ** soil_species_count;
    var diffusive = [_]f64{0} ** soil_species_count;
    convective[34] = 2;
    convective[42] = 3;
    diffusive[34] = -0.5;
    diffusive[42] = 1;
    var litter = [_]f64{0} ** litter_species_count;
    var soil = [_]f64{0} ** soil_species_count;
    try accumulate(fixture(&snow_litter, &snow_soil, &convective, &diffusive), &litter, &soil);
    try std.testing.expectEqual(@as(f64, 0), litter[34] + soil[34] + soil[42]);
}

test "late non-finite accumulation is atomic" {
    const snow_litter = [_]f64{2} ** litter_species_count;
    const snow_soil = [_]f64{3} ** soil_species_count;
    const convective = [_]f64{1} ** soil_species_count;
    var diffusive = [_]f64{0.5} ** soil_species_count;
    diffusive[soil_species_count - 1] = std.math.inf(f64);
    var litter = [_]f64{10} ** litter_species_count;
    var soil = [_]f64{20} ** soil_species_count;
    try std.testing.expectError(error.NonFiniteLitterSoilSoluteAccumulationInput, accumulate(fixture(&snow_litter, &snow_soil, &convective, &diffusive), &litter, &soil));
    try std.testing.expectEqual(@as(f64, 10), litter[0]);
    try std.testing.expectEqual(@as(f64, 20), soil[0]);
}

test "accumulation rejects short snow-litter topology" {
    const short_litter = [_]f64{0} ** (litter_species_count - 1);
    const soil_values = [_]f64{0} ** soil_species_count;
    var litter = [_]f64{0} ** litter_species_count;
    var soil = [_]f64{0} ** soil_species_count;
    try std.testing.expectError(error.LitterSoilSoluteAccumulationDimensionMismatch, accumulate(fixture(&short_litter, &soil_values, &soil_values, &soil_values), &litter, &soil));
}

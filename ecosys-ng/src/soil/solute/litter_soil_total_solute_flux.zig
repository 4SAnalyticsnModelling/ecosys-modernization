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

pub const Inputs = struct {
    /// Per-field amount step-1; free PO4/H3PO4 are g P, others are mol.
    litter_boundary_flux_amount_per_step: []const f64,
    snow_litter_flux_amount_per_step: []const f64,
    soil_boundary_flux_amount_per_step: []const f64,
    snow_soil_flux_amount_per_step: []const f64,
    /// Positive litter-to-soil exchanges in the same per-field units.
    convective_flux_amount_per_step: []const f64,
    diffusive_flux_amount_per_step: []const f64,
};

/// Exact source-order state_update from TRNSFRS.F lines 2826--2925.
///
/// Litter phosphate pools lose both non-band and band exchange, whereas each
/// soil phosphate pool receives its corresponding exchange slot. Results are
/// validated completely before either destination is mutated.
pub fn publish(
    inputs: Inputs,
    litter_total_flux_amount_per_step: []f64,
    soil_total_flux_amount_per_step: []f64,
) !void {
    inline for (.{ inputs.litter_boundary_flux_amount_per_step.len, inputs.snow_litter_flux_amount_per_step.len, litter_total_flux_amount_per_step.len }) |len|
        if (len != litter_species_count) return error.LitterSoilTotalSoluteFluxDimensionMismatch;
    inline for (.{ inputs.soil_boundary_flux_amount_per_step.len, inputs.snow_soil_flux_amount_per_step.len, inputs.convective_flux_amount_per_step.len, inputs.diffusive_flux_amount_per_step.len, soil_total_flux_amount_per_step.len }) |len|
        if (len != soil_species_count) return error.LitterSoilTotalSoluteFluxDimensionMismatch;
    try validateInputs(inputs);

    for (0..litter_species_count) |species| {
        const result = litterResult(inputs, species);
        if (!std.math.isFinite(result)) return error.NonFiniteLitterSoilTotalSoluteFluxResult;
    }
    for (0..soil_species_count) |species| {
        const result = soilResult(inputs, species);
        if (!std.math.isFinite(result)) return error.NonFiniteLitterSoilTotalSoluteFluxResult;
    }
    for (0..litter_species_count) |species|
        litter_total_flux_amount_per_step[species] = litterResult(inputs, species);
    for (0..soil_species_count) |species|
        soil_total_flux_amount_per_step[species] = soilResult(inputs, species);
}

fn litterResult(inputs: Inputs, species: usize) f64 {
    var result = inputs.litter_boundary_flux_amount_per_step[species] +
        inputs.snow_litter_flux_amount_per_step[species] -
        inputs.convective_flux_amount_per_step[species] -
        inputs.diffusive_flux_amount_per_step[species];
    if (species >= pre_phosphate_species_count) {
        const band_species = species + 8;
        // Group each zone's accepted transfer just as the independent
        // accumulation kernel and shared-donor limiter do.
        result -= inputs.convective_flux_amount_per_step[band_species] +
            inputs.diffusive_flux_amount_per_step[band_species];
    }
    return result;
}

fn soilResult(inputs: Inputs, species: usize) f64 {
    return inputs.soil_boundary_flux_amount_per_step[species] +
        inputs.snow_soil_flux_amount_per_step[species] +
        inputs.convective_flux_amount_per_step[species] +
        inputs.diffusive_flux_amount_per_step[species];
}

fn validateInputs(inputs: Inputs) !void {
    inline for (.{ inputs.litter_boundary_flux_amount_per_step, inputs.snow_litter_flux_amount_per_step, inputs.soil_boundary_flux_amount_per_step, inputs.snow_soil_flux_amount_per_step, inputs.convective_flux_amount_per_step, inputs.diffusive_flux_amount_per_step }) |values|
        for (values) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilTotalSoluteFluxInput;
}

fn fixture(
    litter_boundary: []const f64,
    snow_litter: []const f64,
    soil_boundary: []const f64,
    snow_soil: []const f64,
    convective: []const f64,
    diffusive: []const f64,
) Inputs {
    return .{ .litter_boundary_flux_amount_per_step = litter_boundary, .snow_litter_flux_amount_per_step = snow_litter, .soil_boundary_flux_amount_per_step = soil_boundary, .snow_soil_flux_amount_per_step = snow_soil, .convective_flux_amount_per_step = convective, .diffusive_flux_amount_per_step = diffusive };
}

test "TRNSFRS publishes exact litter and soil signs" {
    const litter_boundary = [_]f64{10} ** litter_species_count;
    const snow_litter = [_]f64{2} ** litter_species_count;
    const soil_boundary = [_]f64{20} ** soil_species_count;
    const snow_soil = [_]f64{3} ** soil_species_count;
    const convective = [_]f64{1} ** soil_species_count;
    const diffusive = [_]f64{0.5} ** soil_species_count;
    var litter = [_]f64{0} ** litter_species_count;
    var soil = [_]f64{0} ** soil_species_count;
    try publish(fixture(&litter_boundary, &snow_litter, &soil_boundary, &snow_soil, &convective, &diffusive), &litter, &soil);
    try std.testing.expectEqual(@as(f64, 10.5), litter[0]);
    try std.testing.expectEqual(@as(f64, 9), litter[34]);
    try std.testing.expectEqual(@as(f64, 24.5), soil[0]);
    try std.testing.expectEqual(@as(f64, 24.5), soil[42]);
}

test "internal exchange cancels exactly across litter and soil phosphate pools" {
    const litter_boundary = [_]f64{0} ** litter_species_count;
    const snow_litter = [_]f64{0} ** litter_species_count;
    const soil_boundary = [_]f64{0} ** soil_species_count;
    const snow_soil = [_]f64{0} ** soil_species_count;
    var convective = [_]f64{0} ** soil_species_count;
    var diffusive = [_]f64{0} ** soil_species_count;
    convective[34] = 2;
    convective[42] = 3;
    diffusive[34] = -0.5;
    diffusive[42] = 1;
    var litter = [_]f64{0} ** litter_species_count;
    var soil = [_]f64{0} ** soil_species_count;
    try publish(fixture(&litter_boundary, &snow_litter, &soil_boundary, &snow_soil, &convective, &diffusive), &litter, &soil);
    try std.testing.expectEqual(@as(f64, 0), litter[34] + soil[34] + soil[42]);
}

test "late invalid input leaves both totals atomic" {
    const litter_boundary = [_]f64{10} ** litter_species_count;
    const snow_litter = [_]f64{2} ** litter_species_count;
    const soil_boundary = [_]f64{20} ** soil_species_count;
    const snow_soil = [_]f64{3} ** soil_species_count;
    const convective = [_]f64{1} ** soil_species_count;
    var diffusive = [_]f64{0.5} ** soil_species_count;
    diffusive[soil_species_count - 1] = std.math.inf(f64);
    var litter = [_]f64{9} ** litter_species_count;
    var soil = [_]f64{7} ** soil_species_count;
    try std.testing.expectError(error.NonFiniteLitterSoilTotalSoluteFluxInput, publish(fixture(&litter_boundary, &snow_litter, &soil_boundary, &snow_soil, &convective, &diffusive), &litter, &soil));
    try std.testing.expectEqual(@as(f64, 9), litter[0]);
    try std.testing.expectEqual(@as(f64, 7), soil[0]);
}

test "total flux topology rejects short litter input" {
    const short_litter = [_]f64{0} ** (litter_species_count - 1);
    const litter = [_]f64{0} ** litter_species_count;
    const soil = [_]f64{0} ** soil_species_count;
    var litter_output = [_]f64{9} ** litter_species_count;
    var soil_output = [_]f64{7} ** soil_species_count;
    try std.testing.expectError(error.LitterSoilTotalSoluteFluxDimensionMismatch, publish(fixture(&short_litter, &litter, &soil, &soil, &soil, &soil), &litter_output, &soil_output));
}

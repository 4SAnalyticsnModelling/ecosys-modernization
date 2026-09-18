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

pub const pre_phosphate_species_count = 34;
pub const phosphate_species_count = 8;
pub const litter_species_count = 42;
pub const soil_species_count = 50;

pub const Inputs = struct {
    litter_bulk_volume_m3: f64,
    minimum_litter_bulk_volume_m3: f64,
    litter_water_m3: f64,
    soil_surface_water_m3: f64,
    minimum_water_m3: f64,
    nonband_phosphate_fraction: f64,
    band_phosphate_fraction: f64,
    /// Free PO4/H3PO4 fields are g P; all other fields are mol.
    litter_inventory_amount: []const f64,
    soil_surface_inventory_amount: []const f64,
};

/// Exact concentration construction from TRNSFRS.F lines 2477--2605.
/// Returns false without publishing when the legacy volume gates are closed.
/// Concentrations preserve each inventory field's unit per m3 in exact
/// 42-field litter and 50-field soil order.
pub fn calculate(
    inputs: Inputs,
    litter_concentration_amount_per_m3: []f64,
    soil_concentration_amount_per_m3: []f64,
) !bool {
    if (inputs.litter_inventory_amount.len != litter_species_count or
        inputs.soil_surface_inventory_amount.len != soil_species_count or
        litter_concentration_amount_per_m3.len != litter_species_count or
        soil_concentration_amount_per_m3.len != soil_species_count)
        return error.LitterSoilSoluteConcentrationDimensionMismatch;
    try validate(inputs);
    if (!(inputs.litter_bulk_volume_m3 > inputs.minimum_litter_bulk_volume_m3 and
        inputs.litter_water_m3 > inputs.minimum_water_m3 and
        inputs.soil_surface_water_m3 > inputs.minimum_water_m3)) return false;

    const nonband_water_m3 = inputs.soil_surface_water_m3 * inputs.nonband_phosphate_fraction;
    const band_water_m3 = inputs.soil_surface_water_m3 * inputs.band_phosphate_fraction;
    for (0..litter_species_count) |species| {
        const value = @max(0, inputs.litter_inventory_amount[species] / inputs.litter_water_m3);
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilSoluteConcentrationResult;
    }
    for (0..pre_phosphate_species_count) |species| {
        var value = @max(0, inputs.soil_surface_inventory_amount[species] / inputs.soil_surface_water_m3);
        // Legacy line 2585 couples this H4SiO4 fallback to absent non-band P water.
        if (species == 33 and !(nonband_water_m3 > inputs.minimum_water_m3)) value = 0;
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilSoluteConcentrationResult;
    }
    for (0..phosphate_species_count) |phosphate| {
        const nonband = if (nonband_water_m3 > inputs.minimum_water_m3)
            @max(0, inputs.soil_surface_inventory_amount[34 + phosphate] / nonband_water_m3)
        else
            0;
        const band = if (band_water_m3 > inputs.minimum_water_m3)
            @max(0, inputs.soil_surface_inventory_amount[42 + phosphate] / band_water_m3)
        else
            nonband;
        if (!std.math.isFinite(nonband) or !std.math.isFinite(band))
            return error.NonFiniteLitterSoilSoluteConcentrationResult;
    }

    for (0..litter_species_count) |species|
        litter_concentration_amount_per_m3[species] =
            @max(0, inputs.litter_inventory_amount[species] / inputs.litter_water_m3);
    for (0..pre_phosphate_species_count) |species| {
        soil_concentration_amount_per_m3[species] =
            @max(0, inputs.soil_surface_inventory_amount[species] / inputs.soil_surface_water_m3);
    }
    if (!(nonband_water_m3 > inputs.minimum_water_m3)) soil_concentration_amount_per_m3[33] = 0;
    for (0..phosphate_species_count) |phosphate| {
        const nonband = if (nonband_water_m3 > inputs.minimum_water_m3)
            @max(0, inputs.soil_surface_inventory_amount[34 + phosphate] / nonband_water_m3)
        else
            0;
        soil_concentration_amount_per_m3[34 + phosphate] = nonband;
        soil_concentration_amount_per_m3[42 + phosphate] = if (band_water_m3 > inputs.minimum_water_m3)
            @max(0, inputs.soil_surface_inventory_amount[42 + phosphate] / band_water_m3)
        else
            nonband;
    }
    return true;
}

fn validate(inputs: Inputs) !void {
    inline for (.{ inputs.litter_bulk_volume_m3, inputs.minimum_litter_bulk_volume_m3, inputs.litter_water_m3, inputs.soil_surface_water_m3, inputs.minimum_water_m3, inputs.nonband_phosphate_fraction, inputs.band_phosphate_fraction }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilSoluteConcentrationInput;
    if (inputs.litter_bulk_volume_m3 < 0 or inputs.minimum_litter_bulk_volume_m3 < 0 or
        inputs.litter_water_m3 < 0 or inputs.soil_surface_water_m3 < 0 or inputs.minimum_water_m3 < 0 or
        inputs.nonband_phosphate_fraction < 0 or inputs.nonband_phosphate_fraction > 1 or
        inputs.band_phosphate_fraction < 0 or inputs.band_phosphate_fraction > 1)
        return error.InvalidLitterSoilSoluteConcentrationInput;
    for (inputs.litter_inventory_amount) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilSoluteConcentrationInput;
    for (inputs.soil_surface_inventory_amount) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilSoluteConcentrationInput;
}

fn fixture(litter: []const f64, soil: []const f64) Inputs {
    return .{ .litter_bulk_volume_m3 = 1, .minimum_litter_bulk_volume_m3 = 0.01, .litter_water_m3 = 2, .soil_surface_water_m3 = 4, .minimum_water_m3 = 0.1, .nonband_phosphate_fraction = 0.25, .band_phosphate_fraction = 0.5, .litter_inventory_amount = litter, .soil_surface_inventory_amount = soil };
}

test "TRNSFRS constructs exact litter and partitioned soil concentrations" {
    const litter = [_]f64{8} ** litter_species_count;
    const soil = [_]f64{8} ** soil_species_count;
    var litter_concentration = [_]f64{99} ** litter_species_count;
    var soil_concentration = [_]f64{99} ** soil_species_count;
    try std.testing.expect(try calculate(fixture(&litter, &soil), &litter_concentration, &soil_concentration));
    try std.testing.expectEqual(@as(f64, 4), litter_concentration[0]);
    try std.testing.expectEqual(@as(f64, 2), soil_concentration[0]);
    try std.testing.expectEqual(@as(f64, 8), soil_concentration[34]);
    try std.testing.expectEqual(@as(f64, 4), soil_concentration[42]);
}

test "absent phosphate pore volumes preserve exact zero and fallback behavior" {
    const litter = [_]f64{8} ** litter_species_count;
    const soil = [_]f64{8} ** soil_species_count;
    var litter_concentration = [_]f64{0} ** litter_species_count;
    var soil_concentration = [_]f64{0} ** soil_species_count;
    var inputs = fixture(&litter, &soil);
    inputs.nonband_phosphate_fraction = 0;
    inputs.band_phosphate_fraction = 0;
    try std.testing.expect(try calculate(inputs, &litter_concentration, &soil_concentration));
    try std.testing.expectEqual(@as(f64, 0), soil_concentration[33]);
    try std.testing.expectEqual(@as(f64, 0), soil_concentration[34]);
    try std.testing.expectEqual(@as(f64, 0), soil_concentration[42]);
}

test "closed legacy volume gate leaves outputs unchanged" {
    const litter = [_]f64{8} ** litter_species_count;
    const soil = [_]f64{8} ** soil_species_count;
    var litter_concentration = [_]f64{9} ** litter_species_count;
    var soil_concentration = [_]f64{7} ** soil_species_count;
    var inputs = fixture(&litter, &soil);
    inputs.litter_water_m3 = 0;
    try std.testing.expect(!try calculate(inputs, &litter_concentration, &soil_concentration));
    try std.testing.expectEqual(@as(f64, 9), litter_concentration[0]);
    try std.testing.expectEqual(@as(f64, 7), soil_concentration[0]);
}

test "late invalid inventory leaves both concentration groups atomic" {
    var litter = [_]f64{8} ** litter_species_count;
    litter[litter_species_count - 1] = std.math.inf(f64);
    const soil = [_]f64{8} ** soil_species_count;
    var litter_concentration = [_]f64{9} ** litter_species_count;
    var soil_concentration = [_]f64{7} ** soil_species_count;
    try std.testing.expectError(error.NonFiniteLitterSoilSoluteConcentrationInput, calculate(fixture(&litter, &soil), &litter_concentration, &soil_concentration));
    try std.testing.expectEqual(@as(f64, 9), litter_concentration[0]);
    try std.testing.expectEqual(@as(f64, 7), soil_concentration[0]);
}

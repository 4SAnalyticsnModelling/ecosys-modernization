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
pub const conductance_class_count = 14;

pub const Inputs = struct {
    /// Legacy volume gate from TRNSFRS.F line 2477.
    exchange_active: bool,
    /// Free PO4/H3PO4 fields are g P m-3; all others are mol m-3.
    litter_concentration_amount_per_m3: []const f64,
    soil_concentration_amount_per_m3: []const f64,
    /// PO4, Al, Fe, H, Ca, Mg, Na, K, OH, SO4, Cl, CO3, HCO3, H4SiO4;
    /// each value is m3 step-1.
    conductance_m3_per_step: []const f64,
    nonband_phosphate_fraction: f64,
    band_phosphate_fraction: f64,
};

/// Exact compatibility translation of TRNSFRS.F lines 2692--2793.
/// Positive per-field amount step-1 flux is from litter toward soil. All 50 outputs are
/// validated before state_update; a closed volume gate explicitly zeros them.
pub fn calculate(inputs: Inputs, flux_amount_per_step: []f64) !void {
    if (inputs.litter_concentration_amount_per_m3.len != litter_species_count or
        inputs.soil_concentration_amount_per_m3.len != soil_species_count or
        inputs.conductance_m3_per_step.len != conductance_class_count or
        flux_amount_per_step.len != soil_species_count)
        return error.LitterSoilDiffusiveSoluteDimensionMismatch;
    try validate(inputs);
    if (!inputs.exchange_active) {
        @memset(flux_amount_per_step, 0);
        return;
    }
    for (0..soil_species_count) |species| {
        const value = fluxForSpecies(inputs, species);
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilDiffusiveSoluteResult;
    }
    for (0..soil_species_count) |species|
        flux_amount_per_step[species] = fluxForSpecies(inputs, species);
}

fn fluxForSpecies(inputs: Inputs, species: usize) f64 {
    const litter_species = if (species < litter_species_count) species else species - 8;
    const class = conductanceClass(species);
    var flux = inputs.conductance_m3_per_step[class] *
        (inputs.litter_concentration_amount_per_m3[litter_species] -
            inputs.soil_concentration_amount_per_m3[species]);
    if (species >= 34 and species < 42) flux *= inputs.nonband_phosphate_fraction;
    if (species >= 42) flux *= inputs.band_phosphate_fraction;
    return flux;
}

fn conductanceClass(species: usize) usize {
    return switch (species) {
        0, 12...16 => 1, // aluminum
        1, 17...21 => 2, // iron
        2 => 3, // hydrogen
        3, 22...25 => 4, // calcium
        4, 26...29 => 5, // magnesium
        5, 30...31 => 6, // sodium
        6, 32 => 7, // potassium
        7 => 8, // hydroxide
        8 => 9, // sulfate
        9 => 10, // chloride
        10 => 11, // carbonate
        11 => 12, // bicarbonate
        33 => 13, // H4SiO4
        34...49 => 0, // phosphate
        else => unreachable,
    };
}

fn validate(inputs: Inputs) !void {
    inline for (.{ inputs.nonband_phosphate_fraction, inputs.band_phosphate_fraction }) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidLitterSoilDiffusiveSoluteInput;
    for (inputs.litter_concentration_amount_per_m3) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterSoilDiffusiveSoluteInput;
    for (inputs.soil_concentration_amount_per_m3) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterSoilDiffusiveSoluteInput;
    for (inputs.conductance_m3_per_step) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterSoilDiffusiveSoluteInput;
}

fn fixture(litter: []const f64, soil: []const f64, conductance: []const f64) Inputs {
    return .{ .exchange_active = true, .litter_concentration_amount_per_m3 = litter, .soil_concentration_amount_per_m3 = soil, .conductance_m3_per_step = conductance, .nonband_phosphate_fraction = 0.25, .band_phosphate_fraction = 0.75 };
}

test "TRNSFRS preserves species-class mapping and signed concentration gradient" {
    var litter = [_]f64{10} ** litter_species_count;
    var soil = [_]f64{2} ** soil_species_count;
    var conductance: [conductance_class_count]f64 = undefined;
    for (&conductance, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    litter[0] = 1;
    soil[0] = 3;
    var flux = [_]f64{0} ** soil_species_count;
    try calculate(fixture(&litter, &soil, &conductance), &flux);
    try std.testing.expectEqual(@as(f64, -4), flux[0]); // Al class index 1 => 2.
    try std.testing.expectEqual(@as(f64, 16), flux[12]);
    try std.testing.expectEqual(@as(f64, 112), flux[33]); // H4SiO4 class 13 => 14.
    try std.testing.expectEqual(@as(f64, 2), flux[34]); // PO4 class 0 * 0.25.
    try std.testing.expectEqual(@as(f64, 6), flux[42]); // same litter P * 0.75.
}

test "closed legacy gate explicitly zeroes all fifty fluxes" {
    const litter = [_]f64{10} ** litter_species_count;
    const soil = [_]f64{2} ** soil_species_count;
    const conductance = [_]f64{1} ** conductance_class_count;
    var flux = [_]f64{9} ** soil_species_count;
    var inputs = fixture(&litter, &soil, &conductance);
    inputs.exchange_active = false;
    try calculate(inputs, &flux);
    try std.testing.expectEqualSlices(f64, &([_]f64{0} ** soil_species_count), &flux);
}

test "late invalid concentration leaves output atomic" {
    const litter = [_]f64{10} ** litter_species_count;
    var soil = [_]f64{2} ** soil_species_count;
    soil[soil_species_count - 1] = std.math.inf(f64);
    const conductance = [_]f64{1} ** conductance_class_count;
    var flux = [_]f64{9} ** soil_species_count;
    try std.testing.expectError(
        error.InvalidLitterSoilDiffusiveSoluteInput,
        calculate(fixture(&litter, &soil, &conductance), &flux),
    );
    try std.testing.expectEqualSlices(f64, &([_]f64{9} ** soil_species_count), &flux);
}

test "diffusive topology rejects a missing conductance class" {
    const litter = [_]f64{10} ** litter_species_count;
    const soil = [_]f64{2} ** soil_species_count;
    const conductance = [_]f64{1} ** (conductance_class_count - 1);
    var flux = [_]f64{9} ** soil_species_count;
    try std.testing.expectError(
        error.LitterSoilDiffusiveSoluteDimensionMismatch,
        calculate(fixture(&litter, &soil, &conductance), &flux),
    );
}

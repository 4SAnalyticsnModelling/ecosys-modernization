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
    /// Positive is litter to soil; non-positive uses soil as donor, m3 step-1.
    litter_to_soil_water_flux_m3_per_step: f64,
    litter_water_m3: f64,
    soil_surface_water_m3: f64,
    minimum_water_m3: f64,
    maximum_convective_fraction: f64,
    nonband_phosphate_fraction: f64,
    band_phosphate_fraction: f64,
    /// 34 salt/complex and eight phosphate inventories. Free PO4/H3PO4 are
    /// g P; the remaining fields are mol, matching the source COMMON arrays.
    litter_inventory_amount: []const f64,
    /// 34 salt/complex, eight non-band P, and eight band P inventories, with
    /// the same per-field units as `litter_inventory_amount`.
    soil_surface_inventory_amount: []const f64,
};

/// Exact compatibility translation of TRNSFRS.F lines 2326--2468.
///
/// The returned sign follows the water flux: positive transfers litter to
/// soil and negative transfers soil to litter. The result is only published
/// after every source value and calculated flux has been validated.
pub fn calculate(inputs: Inputs, flux_amount_per_step: []f64) !void {
    if (inputs.litter_inventory_amount.len != litter_species_count or
        inputs.soil_surface_inventory_amount.len != soil_species_count or
        flux_amount_per_step.len != soil_species_count)
        return error.LitterSoilConvectiveSoluteDimensionMismatch;
    try validateInputs(inputs);

    const water_flux = inputs.litter_to_soil_water_flux_m3_per_step;
    const fraction = if (water_flux > 0)
        if (inputs.litter_water_m3 > inputs.minimum_water_m3)
            std.math.clamp(water_flux / inputs.litter_water_m3, 0, inputs.maximum_convective_fraction)
        else
            inputs.maximum_convective_fraction
    else if (inputs.soil_surface_water_m3 > inputs.minimum_water_m3)
        std.math.clamp(water_flux / inputs.soil_surface_water_m3, -inputs.maximum_convective_fraction, 0)
    else
        -inputs.maximum_convective_fraction;

    for (0..soil_species_count) |species| {
        const value = sourceFlux(inputs, species, fraction, water_flux > 0);
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilConvectiveSoluteResult;
    }
    for (0..soil_species_count) |species|
        flux_amount_per_step[species] = sourceFlux(inputs, species, fraction, water_flux > 0);
}

fn sourceFlux(inputs: Inputs, species: usize, fraction: f64, downward: bool) f64 {
    if (!downward) return fraction * @max(0, inputs.soil_surface_inventory_amount[species]);
    if (species < pre_phosphate_species_count)
        return fraction * @max(0, inputs.litter_inventory_amount[species]);
    const phosphate = if (species < litter_species_count)
        species - pre_phosphate_species_count
    else
        species - litter_species_count;
    const partition = if (species < litter_species_count)
        inputs.nonband_phosphate_fraction
    else
        inputs.band_phosphate_fraction;
    return fraction * @max(0, inputs.litter_inventory_amount[pre_phosphate_species_count + phosphate]) * partition;
}

fn validateInputs(inputs: Inputs) !void {
    inline for (.{ inputs.litter_to_soil_water_flux_m3_per_step, inputs.litter_water_m3, inputs.soil_surface_water_m3, inputs.minimum_water_m3, inputs.maximum_convective_fraction, inputs.nonband_phosphate_fraction, inputs.band_phosphate_fraction }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilConvectiveSoluteInput;
    if (inputs.litter_water_m3 < 0 or inputs.soil_surface_water_m3 < 0 or
        inputs.minimum_water_m3 < 0 or inputs.maximum_convective_fraction < 0 or
        inputs.nonband_phosphate_fraction < 0 or inputs.nonband_phosphate_fraction > 1 or
        inputs.band_phosphate_fraction < 0 or inputs.band_phosphate_fraction > 1)
        return error.InvalidLitterSoilConvectiveSoluteInput;
    for (inputs.litter_inventory_amount) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilConvectiveSoluteInput;
    for (inputs.soil_surface_inventory_amount) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilConvectiveSoluteInput;
}

fn baseInputs(litter: []const f64, soil: []const f64, water_flux: f64) Inputs {
    return .{
        .litter_to_soil_water_flux_m3_per_step = water_flux,
        .litter_water_m3 = 4,
        .soil_surface_water_m3 = 2,
        .minimum_water_m3 = 0.01,
        .maximum_convective_fraction = 0.75,
        .nonband_phosphate_fraction = 0.25,
        .band_phosphate_fraction = 0.75,
        .litter_inventory_amount = litter,
        .soil_surface_inventory_amount = soil,
    };
}

test "TRNSFRS downward flow uses litter and partitions phosphate" {
    const litter = [_]f64{8} ** litter_species_count;
    const soil = [_]f64{99} ** soil_species_count;
    var flux = [_]f64{0} ** soil_species_count;
    try calculate(baseInputs(&litter, &soil, 2), &flux);
    try std.testing.expectEqual(@as(f64, 4), flux[0]);
    try std.testing.expectEqual(@as(f64, 1), flux[34]);
    try std.testing.expectEqual(@as(f64, 3), flux[42]);
}

test "TRNSFRS upward flow uses distinct soil non-band and band inventories" {
    const litter = [_]f64{99} ** litter_species_count;
    var soil = [_]f64{4} ** soil_species_count;
    soil[34] = 8;
    soil[42] = 12;
    var flux = [_]f64{0} ** soil_species_count;
    try calculate(baseInputs(&litter, &soil, -1), &flux);
    try std.testing.expectEqual(@as(f64, -2), flux[0]);
    try std.testing.expectEqual(@as(f64, -4), flux[34]);
    try std.testing.expectEqual(@as(f64, -6), flux[42]);
}

test "dry donor uses signed maximum fraction and clamps negative inventory" {
    var litter = [_]f64{8} ** litter_species_count;
    litter[0] = -3;
    const soil = [_]f64{4} ** soil_species_count;
    var flux = [_]f64{9} ** soil_species_count;
    var inputs = baseInputs(&litter, &soil, 2);
    inputs.litter_water_m3 = 0;
    try calculate(inputs, &flux);
    try std.testing.expectEqual(@as(f64, 0), flux[0]);
    try std.testing.expectEqual(@as(f64, 6), flux[1]);
}

test "late invalid input leaves output atomic" {
    var litter = [_]f64{8} ** litter_species_count;
    litter[litter_species_count - 1] = std.math.inf(f64);
    const soil = [_]f64{4} ** soil_species_count;
    var flux = [_]f64{9} ** soil_species_count;
    try std.testing.expectError(
        error.NonFiniteLitterSoilConvectiveSoluteInput,
        calculate(baseInputs(&litter, &soil, 2), &flux),
    );
    try std.testing.expectEqualSlices(f64, &([_]f64{9} ** soil_species_count), &flux);
}

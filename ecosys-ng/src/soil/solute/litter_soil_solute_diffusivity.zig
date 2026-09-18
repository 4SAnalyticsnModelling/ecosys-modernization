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

/// PO4, Al, Fe, H, Ca, Mg, Na, K, OH, SO4, Cl, CO3, HCO3, H4SiO4.
pub const diffusivity_class_count = 14;

pub const Inputs = struct {
    litter_thickness_m: f64,
    soil_surface_thickness_m: f64,
    minimum_thickness_m: f64,
    litter_tortuosity: f64,
    soil_surface_tortuosity: f64,
    litter_cover_fraction: f64,
    dispersivity_m: f64,
    litter_to_soil_water_flux_m3_per_step: f64,
    soil_surface_area_m2: f64,
    maximum_pore_velocity_m_per_step: f64,
    /// Exact source order documented by `diffusivity_class_count`, m2 step-1.
    aqueous_diffusivity_m2_per_step: []const f64,
};

/// Exact compatibility translation of TRNSFRS.F lines 2633--2666.
/// Publishes fourteen face conductances in m3 step-1 only after all classes
/// have finite results.
pub fn calculate(inputs: Inputs, conductance_m3_per_step: []f64) !void {
    if (inputs.aqueous_diffusivity_m2_per_step.len != diffusivity_class_count or
        conductance_m3_per_step.len != diffusivity_class_count)
        return error.LitterSoilSoluteDiffusivityDimensionMismatch;
    try validate(inputs);

    const litter_thickness_m = @max(inputs.minimum_thickness_m, inputs.litter_thickness_m);
    const soil_thickness_m = @max(inputs.minimum_thickness_m, inputs.soil_surface_thickness_m);
    const tortuosity_per_m = (inputs.litter_tortuosity + inputs.soil_surface_tortuosity) /
        (litter_thickness_m + soil_thickness_m) * inputs.litter_cover_fraction;
    const dispersion_m2_per_step = inputs.dispersivity_m * @min(
        inputs.maximum_pore_velocity_m_per_step,
        @abs(inputs.litter_to_soil_water_flux_m3_per_step / inputs.soil_surface_area_m2),
    );
    for (inputs.aqueous_diffusivity_m2_per_step) |diffusivity_m2_per_step| {
        const result = (diffusivity_m2_per_step * tortuosity_per_m + dispersion_m2_per_step) *
            inputs.soil_surface_area_m2;
        if (!std.math.isFinite(result)) return error.NonFiniteLitterSoilSoluteDiffusivityResult;
    }
    for (inputs.aqueous_diffusivity_m2_per_step, conductance_m3_per_step) |diffusivity, *result| {
        result.* = (diffusivity * tortuosity_per_m + dispersion_m2_per_step) *
            inputs.soil_surface_area_m2;
    }
}

fn validate(inputs: Inputs) !void {
    inline for (.{ inputs.litter_thickness_m, inputs.soil_surface_thickness_m, inputs.minimum_thickness_m, inputs.litter_tortuosity, inputs.soil_surface_tortuosity, inputs.litter_cover_fraction, inputs.dispersivity_m, inputs.litter_to_soil_water_flux_m3_per_step, inputs.soil_surface_area_m2, inputs.maximum_pore_velocity_m_per_step }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilSoluteDiffusivityInput;
    if (inputs.litter_thickness_m < 0 or inputs.soil_surface_thickness_m < 0 or
        inputs.minimum_thickness_m <= 0 or inputs.litter_tortuosity < 0 or
        inputs.soil_surface_tortuosity < 0 or inputs.litter_cover_fraction < 0 or
        inputs.litter_cover_fraction > 1 or inputs.dispersivity_m < 0 or
        inputs.soil_surface_area_m2 <= 0 or inputs.maximum_pore_velocity_m_per_step < 0)
        return error.InvalidLitterSoilSoluteDiffusivityInput;
    for (inputs.aqueous_diffusivity_m2_per_step) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterSoilSoluteDiffusivityInput;
}

fn fixture(diffusivity: []const f64) Inputs {
    return .{ .litter_thickness_m = 1, .soil_surface_thickness_m = 3, .minimum_thickness_m = 0.1, .litter_tortuosity = 2, .soil_surface_tortuosity = 2, .litter_cover_fraction = 0.5, .dispersivity_m = 2, .litter_to_soil_water_flux_m3_per_step = -8, .soil_surface_area_m2 = 4, .maximum_pore_velocity_m_per_step = 1, .aqueous_diffusivity_m2_per_step = diffusivity };
}

test "TRNSFRS preserves fourteen diffusivity classes and operation order" {
    var diffusivity: [diffusivity_class_count]f64 = undefined;
    for (&diffusivity, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    var conductance = [_]f64{0} ** diffusivity_class_count;
    try calculate(fixture(&diffusivity), &conductance);
    // TORTL=(2+2)/(1+3)*0.5=0.5; DISPN=2*min(1,abs(-8/4))=2.
    try std.testing.expectEqual(@as(f64, 10), conductance[0]);
    try std.testing.expectEqual(@as(f64, 36), conductance[13]);
}

test "minimum thickness is applied independently to both sides" {
    const diffusivity = [_]f64{1} ** diffusivity_class_count;
    var conductance = [_]f64{0} ** diffusivity_class_count;
    var inputs = fixture(&diffusivity);
    inputs.litter_thickness_m = 0;
    inputs.soil_surface_thickness_m = 0;
    inputs.litter_to_soil_water_flux_m3_per_step = 0;
    try calculate(inputs, &conductance);
    try std.testing.expectEqual(@as(f64, 40), conductance[0]);
}

test "late invalid class leaves conductance output atomic" {
    var diffusivity = [_]f64{1} ** diffusivity_class_count;
    diffusivity[diffusivity_class_count - 1] = std.math.inf(f64);
    var conductance = [_]f64{9} ** diffusivity_class_count;
    try std.testing.expectError(
        error.InvalidLitterSoilSoluteDiffusivityInput,
        calculate(fixture(&diffusivity), &conductance),
    );
    try std.testing.expectEqualSlices(f64, &([_]f64{9} ** diffusivity_class_count), &conductance);
}

test "diffusivity topology rejects a missing class" {
    const diffusivity = [_]f64{1} ** (diffusivity_class_count - 1);
    var conductance = [_]f64{9} ** diffusivity_class_count;
    try std.testing.expectError(
        error.LitterSoilSoluteDiffusivityDimensionMismatch,
        calculate(fixture(&diffusivity), &conductance),
    );
}

// **A8a DISPOSITION: SUPERSEDED BY THE BOUND DLYRM TOPOLOGY OWNER; HOLD-1
// IS CLOSED.** `transport/hydrology.SoilFaces.refreshMapped` applies the
// strict source/destination thickness gate, zeros every water/vapor/heat
// carrier for inactive fixed-capacity slots, and is bound at initialization,
// checkpoint restore, and accepted relayering. Solute face owners additionally
// publish exact-zero conductance/mobility and the solver returns exact-zero
// flux for an inactive face.
//
// **HISTORICAL A8a DISPOSITION: HOLD-1, do not bind and do not mark superseded.**
// Source: `trnsfrs.f` 8472--8522. Named member of HOLD-1, the `DLYRM` thin-layer gate, in
// docs/traceability/a4e_trnsfrs_unbound_dispositions.md. Production has no
// thickness predicate: `transport_hydrology.buildSoilFacesMapped`
// (`hydrology.zig:228`) enumerates faces from `active_soil_layer_count` alone,
// and `face_parameters.zig:117` then rejects a zero-bulk-volume layer with
// `InvalidSoilSoluteLayerState`, the open Arctic Fen blocker. The condition this
// module implements is therefore genuinely absent from production. The likely fix
// is the face builder's predicate rather than binding this kernel, but that is
// undecided, so this is a HOLD and not a supersession.
// Group HOLD-1 of docs/traceability/transport_unbound_family_was_already_dispositioned_elsewhere.md
const std = @import("std");

pub const macropore_species_count = 49;
pub const micropore_species_count = 50;

/// Safe translation of the thin-layer ELSE at TRNSFRS.F lines 8472--8522.
/// The source clears only macropore flux even though this ELSE closes the outer
/// thickness guard opened before both pore-domain kernels at line 7736. Clear
/// both instantaneous families so a newly thin layer cannot publish stale
/// micropore flux from a preceding substep.
pub fn resetIfThin(
    source_layer_thickness_m: f64,
    minimum_transport_layer_thickness_m: f64,
    macropore_boundary_flux_amount_per_step: []f64,
    micropore_boundary_flux_amount_per_step: []f64,
) !bool {
    inline for (.{ source_layer_thickness_m, minimum_transport_layer_thickness_m }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteThinExternalMacroporeFluxInput;
    if (source_layer_thickness_m < 0 or minimum_transport_layer_thickness_m < 0)
        return error.InvalidThinExternalMacroporeFluxInput;
    if (source_layer_thickness_m > minimum_transport_layer_thickness_m) return false;
    if (macropore_boundary_flux_amount_per_step.len != macropore_species_count or
        micropore_boundary_flux_amount_per_step.len != micropore_species_count)
        return error.ThinExternalMacroporeFluxDimensionMismatch;
    for (macropore_boundary_flux_amount_per_step) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteThinExternalMacroporeFluxInput;
    for (micropore_boundary_flux_amount_per_step) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteThinExternalMacroporeFluxInput;
    @memset(macropore_boundary_flux_amount_per_step, 0);
    @memset(micropore_boundary_flux_amount_per_step, 0);
    return true;
}

test "thin layer clears both external pore-domain instantaneous families" {
    var macropore_flux = [_]f64{3} ** macropore_species_count;
    var micropore_flux = [_]f64{4} ** micropore_species_count;
    try std.testing.expect(try resetIfThin(0.01, 0.01, &macropore_flux, &micropore_flux));
    try std.testing.expectEqualSlices(f64, &([_]f64{0} ** macropore_species_count), &macropore_flux);
    try std.testing.expectEqualSlices(f64, &([_]f64{0} ** micropore_species_count), &micropore_flux);
}

test "TRNSFRS layer below threshold clears compact P endpoints" {
    var macropore_flux = [_]f64{3} ** macropore_species_count;
    var micropore_flux = [_]f64{4} ** micropore_species_count;
    try std.testing.expect(try resetIfThin(0.005, 0.01, &macropore_flux, &micropore_flux));
    try std.testing.expectEqual(@as(f64, 0), macropore_flux[32]);
    try std.testing.expectEqual(@as(f64, 0), macropore_flux[33]);
    try std.testing.expectEqual(@as(f64, 0), macropore_flux[48]);
    try std.testing.expectEqual(@as(f64, 0), micropore_flux[49]);
}

test "TRNSFRS strict thickness pass leaves flux untouched" {
    var macropore_flux = [_]f64{3} ** macropore_species_count;
    var micropore_flux = [_]f64{4} ** micropore_species_count;
    try std.testing.expect(!try resetIfThin(0.0101, 0.01, &macropore_flux, &micropore_flux));
    try std.testing.expectEqualSlices(f64, &([_]f64{3} ** macropore_species_count), &macropore_flux);
    try std.testing.expectEqualSlices(f64, &([_]f64{4} ** micropore_species_count), &micropore_flux);
}

test "active thin reset rejects runtime topology mismatch atomically" {
    var short_flux = [_]f64{3} ** (macropore_species_count - 1);
    var micropore_flux = [_]f64{4} ** micropore_species_count;
    try std.testing.expectError(error.ThinExternalMacroporeFluxDimensionMismatch, resetIfThin(0.01, 0.01, &short_flux, &micropore_flux));
    try std.testing.expectEqualSlices(f64, &([_]f64{3} ** (macropore_species_count - 1)), &short_flux);
    try std.testing.expectEqualSlices(f64, &([_]f64{4} ** micropore_species_count), &micropore_flux);
}

test "late invalid value prevents partial thin reset" {
    var macropore_flux = [_]f64{3} ** macropore_species_count;
    var micropore_flux = [_]f64{4} ** micropore_species_count;
    micropore_flux[49] = std.math.inf(f64);
    try std.testing.expectError(error.NonFiniteThinExternalMacroporeFluxInput, resetIfThin(0.01, 0.01, &macropore_flux, &micropore_flux));
    try std.testing.expectEqual(@as(f64, 3), macropore_flux[0]);
}

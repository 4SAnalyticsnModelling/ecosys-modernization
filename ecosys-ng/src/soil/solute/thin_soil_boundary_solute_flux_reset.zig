// **A8a DISPOSITION: SUPERSEDED BY THE BOUND DLYRM TOPOLOGY OWNER; HOLD-1
// IS CLOSED.** `SoilFaces.active_by_layer` is rebuilt from accepted live
// geometry with strict `thickness > DLYRM`; every production local-boundary
// and micropore/macropore-exchange owner skips inactive layers, leaving their
// state unchanged and publishing exact-zero boundary ledgers.
//
// **HISTORICAL A8a DISPOSITION: HELD. Stays unbound pending named external evidence.**
// This module preserves a policy no bound module reproduces, and the record
// that owns it is still open.
//
// A4e group: HOLD1, the `DLYRM` thin-layer gate (HOLD-1). Production owner:
// face construction, which omits the legacy dual `DLYR > DLYRM` thin-layer
// test entirely. That omission is HOLD-1 in the note and is the open Arctic
// Fen blocker, so this module preserves a *policy* no bound module reproduces.
//
// The family argument, stated in full so this file reads alone. `trnsfrs.f`
// runs an explicit `NPH` sub-hour loop: it recomputes face fluxes, accumulates
// them into substep accumulators (`T*FLS`, `R*FXS`, `R*FLZ`), applies them to
// pore inventories, and repeats. Production replaced that with an implicit
// solve over the whole hour in `driver/transport_step.zig`, whose entry points
// `solveSoilFaceFluxesDeferred` (`:77`) and `advanceSoilLocalSoluteProcesses`
// (`:165`) are bound at `stages/hourly_science_heat_water_solute.zig:410` and
// `:419`. Both encodings write the same pore inventories. Binding a member of
// this family therefore does not add missing physics, it adds a second
// independently-stepped writer of state the implicit solver already owns, and
// every flux would be applied twice with no non-finite value to catch it. The
// width mismatch makes it worse than a doubling: the compat modules carry a
// 42-wide state with `silicic_acid_species_index = 33` and a 41-wide
// transported vector (see `micropore_solute_state_update.zig:3--5`), while
// production is 50-wide and compiler-checked through
// `soil/solute/transport_species.zig:6`, so the second copy would also land on
// the wrong species.
//
// Held, not superseded and not bound: the note records it as blocked on the
// routing of `InvalidSoilSoluteLayerState`. A8a does not overrule a live HOLD.
//
// Caution on the record this cites:
// `docs/traceability/a4e_trnsfrs_unbound_dispositions.md` is accurate in its
// structure and its group assignment still verifies (`pwsh
// tools/a4e_verify_groups.ps1` reports assigned 80 / unique 80 / total 80 with
// all defect lists empty, re-run at this state_update), but every `ecosys_ng.zig`
// line number in it is stale because the hourly call sites moved into
// `src/stages/`, and its module tables use pre-reorganization `soil_`-prefixed
// names that match no current path. The citations in this banner were each re-
// derived by grepping for the exact declaration. Naming that rather than
// editing another lane's note.
//
// A4e HOLD1 group of docs/traceability/a4e_trnsfrs_unbound_dispositions.md
const std = @import("std");

pub const micropore_species_count = 50;
pub const macropore_species_count = 49;

pub const BoundaryState = struct {
    current_volumetric_water_content: *f64,
    adjacent_volumetric_water_content: *f64,
    micropore_flux_amount_per_step: []f64,
    macropore_flux_amount_per_step: []f64,
};

/// Compatibility translation of TRNSFRS.F lines 6974--7076.
/// This is the ELSE of the strict dual `DLYR(3,...) > DLYRM` guard, so either
/// layer at or below the threshold clears both THETW1 values and all fluxes.
pub fn resetIfThin(
    current_layer_thickness_m: f64,
    adjacent_layer_thickness_m: f64,
    minimum_transport_layer_thickness_m: f64,
    state: BoundaryState,
) !bool {
    inline for (.{ current_layer_thickness_m, adjacent_layer_thickness_m, minimum_transport_layer_thickness_m }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteThinSoilBoundarySoluteFluxInput;
    if (current_layer_thickness_m < 0 or adjacent_layer_thickness_m < 0 or minimum_transport_layer_thickness_m < 0)
        return error.InvalidThinSoilBoundarySoluteFluxInput;
    if (current_layer_thickness_m > minimum_transport_layer_thickness_m and
        adjacent_layer_thickness_m > minimum_transport_layer_thickness_m)
        return false;
    if (state.micropore_flux_amount_per_step.len != micropore_species_count or
        state.macropore_flux_amount_per_step.len != macropore_species_count)
        return error.ThinSoilBoundarySoluteFluxDimensionMismatch;
    if (!std.math.isFinite(state.current_volumetric_water_content.*) or
        !std.math.isFinite(state.adjacent_volumetric_water_content.*))
        return error.NonFiniteThinSoilBoundarySoluteFluxInput;
    for (state.micropore_flux_amount_per_step) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteThinSoilBoundarySoluteFluxInput;
    for (state.macropore_flux_amount_per_step) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteThinSoilBoundarySoluteFluxInput;

    state.current_volumetric_water_content.* = 0;
    state.adjacent_volumetric_water_content.* = 0;
    @memset(state.micropore_flux_amount_per_step, 0);
    @memset(state.macropore_flux_amount_per_step, 0);
    return true;
}

test "TRNSFRS current layer at threshold triggers complete reset" {
    var current_theta: f64 = 0.3;
    var adjacent_theta: f64 = 0.4;
    var micropore_flux = [_]f64{2} ** micropore_species_count;
    var macropore_flux = [_]f64{3} ** macropore_species_count;
    const applied = try resetIfThin(0.01, 0.2, 0.01, .{ .current_volumetric_water_content = &current_theta, .adjacent_volumetric_water_content = &adjacent_theta, .micropore_flux_amount_per_step = &micropore_flux, .macropore_flux_amount_per_step = &macropore_flux });
    try std.testing.expect(applied);
    try std.testing.expectEqual(@as(f64, 0), current_theta);
    try std.testing.expectEqual(@as(f64, 0), adjacent_theta);
    try std.testing.expectEqualSlices(f64, &([_]f64{0} ** micropore_species_count), &micropore_flux);
    try std.testing.expectEqualSlices(f64, &([_]f64{0} ** macropore_species_count), &macropore_flux);
}

test "TRNSFRS adjacent layer below threshold triggers complete reset" {
    var current_theta: f64 = 0.3;
    var adjacent_theta: f64 = 0.4;
    var micropore_flux = [_]f64{2} ** micropore_species_count;
    var macropore_flux = [_]f64{3} ** macropore_species_count;
    try std.testing.expect(try resetIfThin(0.2, 0.005, 0.01, .{ .current_volumetric_water_content = &current_theta, .adjacent_volumetric_water_content = &adjacent_theta, .micropore_flux_amount_per_step = &micropore_flux, .macropore_flux_amount_per_step = &macropore_flux }));
    try std.testing.expectEqual(@as(f64, 0), micropore_flux[49]);
    try std.testing.expectEqual(@as(f64, 0), macropore_flux[48]);
}

test "TRNSFRS dual strict pass leaves state untouched" {
    var current_theta: f64 = 0.3;
    var adjacent_theta: f64 = 0.4;
    var micropore_flux = [_]f64{2} ** micropore_species_count;
    var macropore_flux = [_]f64{3} ** macropore_species_count;
    const applied = try resetIfThin(0.0101, 0.02, 0.01, .{ .current_volumetric_water_content = &current_theta, .adjacent_volumetric_water_content = &adjacent_theta, .micropore_flux_amount_per_step = &micropore_flux, .macropore_flux_amount_per_step = &macropore_flux });
    try std.testing.expect(!applied);
    try std.testing.expectEqual(@as(f64, 0.3), current_theta);
    try std.testing.expectEqual(@as(f64, 2), micropore_flux[49]);
}

test "thin-path dimension error leaves all targets unchanged" {
    var current_theta: f64 = 0.3;
    var adjacent_theta: f64 = 0.4;
    var short_micro = [_]f64{2} ** (micropore_species_count - 1);
    var macropore_flux = [_]f64{3} ** macropore_species_count;
    try std.testing.expectError(error.ThinSoilBoundarySoluteFluxDimensionMismatch, resetIfThin(0.01, 0.2, 0.01, .{ .current_volumetric_water_content = &current_theta, .adjacent_volumetric_water_content = &adjacent_theta, .micropore_flux_amount_per_step = &short_micro, .macropore_flux_amount_per_step = &macropore_flux }));
    try std.testing.expectEqual(@as(f64, 0.3), current_theta);
    try std.testing.expectEqual(@as(f64, 0.4), adjacent_theta);
}

test "late invalid macropore value keeps thin reset atomic" {
    var current_theta: f64 = 0.3;
    var adjacent_theta: f64 = 0.4;
    var micropore_flux = [_]f64{2} ** micropore_species_count;
    var macropore_flux = [_]f64{3} ** macropore_species_count;
    macropore_flux[48] = std.math.inf(f64);
    try std.testing.expectError(error.NonFiniteThinSoilBoundarySoluteFluxInput, resetIfThin(0.01, 0.2, 0.01, .{ .current_volumetric_water_content = &current_theta, .adjacent_volumetric_water_content = &adjacent_theta, .micropore_flux_amount_per_step = &micropore_flux, .macropore_flux_amount_per_step = &macropore_flux }));
    try std.testing.expectEqual(@as(f64, 0.3), current_theta);
    try std.testing.expectEqual(@as(f64, 2), micropore_flux[0]);
}

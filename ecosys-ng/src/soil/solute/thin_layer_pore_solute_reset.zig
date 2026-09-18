// **A8a DISPOSITION: SUPERSEDED BY THE BOUND DLYRM TOPOLOGY OWNER; HOLD-1
// IS CLOSED.** The shared runtime face masks apply the source's strict dual
// DLYR gate before aqueous, organic, mineral-N, and dissolved-gas transport.
// Inactive fixed slots publish exact-zero conductance/mobility and cannot
// change either donor, recipient, or local pore-domain inventories.
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

pub const micropore_species_count = 42;
pub const macropore_species_count = 41;
pub const band_phosphorus_species_count = 8;
pub const PoreFluxApplicability = enum { apply, skip };

pub const Inputs = struct {
    applicability: PoreFluxApplicability,
    current_layer_thickness_m: f64,
    neighbor_layer_thickness_m: f64,
    minimum_layer_thickness_m: f64,
};

pub const Totals = struct {
    micropore_mol_per_step: []f64,
    micropore_band_phosphorus_mol_per_step: []f64,
    macropore_mol_per_step: []f64,
    macropore_band_phosphorus_mol_per_step: []f64,
};

/// Compatibility translation of TRNSFRS.F lines 9249--9347.
/// This is the ELSE branch of the dual DLYR>DLYRM test: if either layer is
/// too thin, all four exact source families are reset to zero.
pub fn reset(inputs: Inputs, totals: Totals) !bool {
    if (inputs.applicability == .skip) return false;
    try validateThickness(inputs);
    if (inputs.current_layer_thickness_m > inputs.minimum_layer_thickness_m and
        inputs.neighbor_layer_thickness_m > inputs.minimum_layer_thickness_m) return false;
    try validateActiveTotals(totals);

    @memset(totals.micropore_mol_per_step, 0);
    @memset(totals.micropore_band_phosphorus_mol_per_step, 0);
    @memset(totals.macropore_mol_per_step, 0);
    @memset(totals.macropore_band_phosphorus_mol_per_step, 0);
    return true;
}

fn validateThickness(inputs: Inputs) !void {
    const scalars = [_]f64{
        inputs.current_layer_thickness_m,
        inputs.neighbor_layer_thickness_m,
        inputs.minimum_layer_thickness_m,
    };
    for (scalars) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteThinLayerPoreSoluteInput;
}

fn validateActiveTotals(totals: Totals) !void {
    if (totals.micropore_mol_per_step.len != micropore_species_count or
        totals.micropore_band_phosphorus_mol_per_step.len != band_phosphorus_species_count or
        totals.macropore_mol_per_step.len != macropore_species_count or
        totals.macropore_band_phosphorus_mol_per_step.len != band_phosphorus_species_count)
        return error.ThinLayerPoreSoluteDimensionMismatch;
    const slices = [_][]const f64{
        totals.micropore_mol_per_step,
        totals.micropore_band_phosphorus_mol_per_step,
        totals.macropore_mol_per_step,
        totals.macropore_band_phosphorus_mol_per_step,
    };
    for (slices) |slice| for (slice) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteThinLayerPoreSoluteInput;
}

fn totalsFor(micropore: []f64, micro_band: []f64, macropore: []f64, macro_band: []f64) Totals {
    return .{
        .micropore_mol_per_step = micropore,
        .micropore_band_phosphorus_mol_per_step = micro_band,
        .macropore_mol_per_step = macropore,
        .macropore_band_phosphorus_mol_per_step = macro_band,
    };
}

test "TRNSFRS thin current layer resets every exact pore family" {
    var micropore = [_]f64{1} ** micropore_species_count;
    var micro_band = [_]f64{2} ** band_phosphorus_species_count;
    var macropore = [_]f64{3} ** macropore_species_count;
    var macro_band = [_]f64{4} ** band_phosphorus_species_count;
    try std.testing.expect(try reset(.{
        .applicability = .apply,
        .current_layer_thickness_m = 0.1,
        .neighbor_layer_thickness_m = 0.2,
        .minimum_layer_thickness_m = 0.1,
    }, totalsFor(&micropore, &micro_band, &macropore, &macro_band)));
    try std.testing.expectEqual(@as(f64, 0), micropore[41]);
    try std.testing.expectEqual(@as(f64, 0), micro_band[7]);
    try std.testing.expectEqual(@as(f64, 0), macropore[40]);
    try std.testing.expectEqual(@as(f64, 0), macro_band[7]);
}

test "thin neighbor alone triggers reset" {
    var micropore = [_]f64{1} ** micropore_species_count;
    var micro_band = [_]f64{2} ** band_phosphorus_species_count;
    var macropore = [_]f64{3} ** macropore_species_count;
    var macro_band = [_]f64{4} ** band_phosphorus_species_count;
    _ = try reset(.{
        .applicability = .apply,
        .current_layer_thickness_m = 0.2,
        .neighbor_layer_thickness_m = 0.05,
        .minimum_layer_thickness_m = 0.1,
    }, totalsFor(&micropore, &micro_band, &macropore, &macro_band));
    try std.testing.expectEqual(@as(f64, 0), micropore[0]);
}

test "two thick layers and skipped outer block do not reset" {
    var micropore = [_]f64{1} ** micropore_species_count;
    var micro_band = [_]f64{2} ** band_phosphorus_species_count;
    var macropore = [_]f64{3} ** macropore_species_count;
    var macro_band = [_]f64{4} ** band_phosphorus_species_count;
    const totals = totalsFor(&micropore, &micro_band, &macropore, &macro_band);
    try std.testing.expect(!try reset(.{ .applicability = .apply, .current_layer_thickness_m = 0.2, .neighbor_layer_thickness_m = 0.3, .minimum_layer_thickness_m = 0.1 }, totals));
    const empty = [_]f64{};
    try std.testing.expect(!try reset(.{ .applicability = .skip, .current_layer_thickness_m = std.math.nan(f64), .neighbor_layer_thickness_m = std.math.nan(f64), .minimum_layer_thickness_m = std.math.nan(f64) }, totalsFor(@constCast(&empty), @constCast(&empty), @constCast(&empty), @constCast(&empty))));
    try std.testing.expectEqual(@as(f64, 1), micropore[0]);
}

test "runtime reset topology mismatch fails atomically" {
    var short_micropore = [_]f64{1} ** (micropore_species_count - 1);
    var micro_band = [_]f64{2} ** band_phosphorus_species_count;
    var macropore = [_]f64{3} ** macropore_species_count;
    var macro_band = [_]f64{4} ** band_phosphorus_species_count;
    try std.testing.expectError(error.ThinLayerPoreSoluteDimensionMismatch, reset(.{ .applicability = .apply, .current_layer_thickness_m = 0.01, .neighbor_layer_thickness_m = 0.2, .minimum_layer_thickness_m = 0.1 }, totalsFor(&short_micropore, &micro_band, &macropore, &macro_band)));
    try std.testing.expectEqual(@as(f64, 3), macropore[0]);
}

test "nonfinite late family fails before reset" {
    var micropore = [_]f64{1} ** micropore_species_count;
    var micro_band = [_]f64{2} ** band_phosphorus_species_count;
    var macropore = [_]f64{3} ** macropore_species_count;
    var macro_band = [_]f64{4} ** band_phosphorus_species_count;
    macro_band[7] = std.math.nan(f64);
    try std.testing.expectError(error.NonFiniteThinLayerPoreSoluteInput, reset(.{ .applicability = .apply, .current_layer_thickness_m = 0.01, .neighbor_layer_thickness_m = 0.2, .minimum_layer_thickness_m = 0.1 }, totalsFor(&micropore, &micro_band, &macropore, &macro_band)));
    try std.testing.expectEqual(@as(f64, 1), micropore[0]);
}

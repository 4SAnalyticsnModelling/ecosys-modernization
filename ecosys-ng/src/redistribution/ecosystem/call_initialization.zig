// **A8a DISPOSITION: SUPERSEDED CALL-LOCAL INITIALIZATION; DO NOT BIND.**
// Current production reconstructs the DORGE-equivalent accepted hourly organic
// change before the bound geometry/erosion transaction. The other four targets
// are dead call-local totals with no production state or downstream consumer.
// The detailed text below is the retained historical audit and its former GAP
// conclusion is superseded. Verified transcription of `redist.f:198--204`:
// `VOLISO=0.0` at `:198`, `TFLWT=0.0` at `:199`, `VOLPT=0.0` at `:200`,
// `VOLTT=0.0` at `:201`, then the column-outer row-inner loop headers at
// `:202--203` and `DORGE(NY,NX)=0.0` at `:204`. The module reproduces the four
// scalar resets in source order at `92--95` and the per-cell reset
// in the same traversal at `124`.
//
// Family argument, stated in full here because each module in this directory must
// stand on its own. All four modules in `src/redistribution/ecosystem/` are
// unwired pure kernels: each has exactly two references in the tree, its
// `src/module_index.zig` registration and its `_ = ecosys.<name>;` line in
// `src/index/redistribution_test_index.zig`. None is imported by any production
// module, so the usual supersession wording about installing a second writer with
// no defined precedence is factually false for this family; there is no call site
// to double-mutate from. What is true is that REDIST's end-of-call ecosystem
// bookkeeping was restructured in production into coarser owners on different
// cadences, and these granular per-call kernels were never given a caller.
//
// This module is a special case even within that family: it cannot be bound,
// because none of the five things it resets exists as production state.
//
// `VOLISO`: the only Zig holder is
// `redistribution/soil/water_balance_state.zig:31` (`landscape_ice_m3`), which
// accumulates it at `:68`. That module is **itself unbound**, so there is no
// production accumulator for this reset to precede.
//
// `DORGE`: the only Zig occurrences of the name are comments and a test name in
// `redistribution/erosion/organic_matter_apply.zig` at `:154`, `:323` and
// `:337` (renumbered when that module's A8a banner was added; see its GAP
// banner and `docs/traceability/redistribution_erosion_apply_family_disposition.md`).
// That module is also **itself unbound**. A grep across `src` for a field named
// `eroded_organic_carbon` returns zero hits, so production has no `DORGE`
// accumulator under a Zig name either. This is consistent with the standing
// finding that no production path selects an erosion-enabled disturbance mode.
//
// `TFLWT`, `VOLPT`, `VOLTT`: these are dead in the Fortran itself. This module's
// own doc comments at `68--76` record that each is reset at
// `:199--201` and never subsequently read anywhere in `redist.f`, which is why
// their Zig field names are `unconsumed_*` and their units are declared
// unevidenced. Reproducing a reset of a legacy variable that the legacy code
// never reads has no observable consequence in either implementation.
//
// So the correct reading is not that production restructured this block, but
// that production has no equivalent because four of the five targets are inert
// and the fifth belongs to an unbound module. Binding this would install a
// zeroing pass over state that does not exist. Left unbound; if the erosion
// path is ever activated, the `DORGE` reset must be re-derived together with
// `organic_matter_apply.zig`, not lifted from here in isolation.
//
// Non-vacuity caveat, and it matters here more than usual. A reset kernel's test
// can pass vacuously, and a conservation check over all-zero terms passes
// trivially. This module's tests at `128` and beyond seed non-zero values
// before resetting and assert the traversal window, so they are not vacuous as
// written. But they prove only that the module zeroes what it is handed; they
// say nothing about whether anything in production is holding those values.
// A8a phase 2, src/redistribution/ecosystem directory sweep. REDIST-ECOSYSTEM group of docs/traceability/a8a_redistribution_ecosystem_dispositions.md
const std = @import("std");

pub const GridWindow = struct {
    first_column: usize,
    last_column_inclusive: usize,
    first_row: usize,
    last_row_inclusive: usize,
};

pub const CallTotals = struct {
    /// REDIST VOLISO, accumulated later from matrix and macropore ice (m3).
    landscape_ice_volume_m3: f64,
    /// REDIST TFLWT is reset but never subsequently read in REDIST.F.
    /// Its scientific unit is therefore not evidenced by this routine.
    unconsumed_water_flux_total: f64,
    /// REDIST VOLPT is reset but never subsequently read in REDIST.F.
    /// Its scientific unit is therefore not evidenced by this routine.
    unconsumed_plant_volume_total: f64,
    /// REDIST VOLTT is reset but never subsequently read in REDIST.F.
    /// Its scientific unit is therefore not evidenced by this routine.
    unconsumed_total_volume: f64,
};

/// Exact REDIST.F lines 198--201 call-local initialization, retaining source
/// assignment order. Validation precedes mutation so an invalid incoming
/// diagnostic cannot be silently erased by the reset.
pub fn resetCallTotals(totals: *CallTotals) !void {
    const values = [_]f64{
        totals.landscape_ice_volume_m3,
        totals.unconsumed_water_flux_total,
        totals.unconsumed_plant_volume_total,
        totals.unconsumed_total_volume,
    };
    for (values) |value|
        if (!std.math.isFinite(value)) return error.InvalidRedistCallTotal;

    totals.landscape_ice_volume_m3 = 0;
    totals.unconsumed_water_flux_total = 0;
    totals.unconsumed_plant_volume_total = 0;
    totals.unconsumed_total_volume = 0;
}

/// Exact meaningful redist.f line 204 call-local reset.
///
/// Traceability: `DORGE(NY,NX)=0` in the source's column-outer, row-inner
/// traversal. Validation completes before any caller-owned value changes.
pub fn resetErodedOrganicCarbon(
    eroded_organic_carbon_g_c_by_cell: []f64,
    column_count: usize,
    row_count: usize,
    window: GridWindow,
) !void {
    if (column_count == 0 or row_count == 0)
        return error.InvalidRedistGridDimensions;
    const cell_count = std.math.mul(usize, column_count, row_count) catch
        return error.InvalidRedistGridDimensions;
    if (eroded_organic_carbon_g_c_by_cell.len != cell_count or
        window.first_column > window.last_column_inclusive or
        window.first_row > window.last_row_inclusive or
        window.last_column_inclusive >= column_count or
        window.last_row_inclusive >= row_count)
        return error.InvalidRedistGridWindow;
    for (eroded_organic_carbon_g_c_by_cell) |value|
        if (!std.math.isFinite(value))
            return error.InvalidErodedOrganicCarbonAccumulator;

    for (window.first_column..window.last_column_inclusive + 1) |column| {
        for (window.first_row..window.last_row_inclusive + 1) |row|
            eroded_organic_carbon_g_c_by_cell[row * column_count + column] = 0;
    }
}

test "REDIST call reset preserves column outer row inner runtime window" {
    var carbon = [_]f64{
        1, 2,  3,  4,
        5, 6,  7,  8,
        9, 10, 11, 12,
    };
    try resetErodedOrganicCarbon(&carbon, 4, 3, .{
        .first_column = 1,
        .last_column_inclusive = 2,
        .first_row = 0,
        .last_row_inclusive = 1,
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ 1, 0, 0, 4, 5, 0, 0, 8, 9, 10, 11, 12 },
        &carbon,
    );
}

test "REDIST lines 198 through 201 reset call totals in source order" {
    var totals = CallTotals{
        .landscape_ice_volume_m3 = 1,
        .unconsumed_water_flux_total = 2,
        .unconsumed_plant_volume_total = 3,
        .unconsumed_total_volume = 4,
    };
    try resetCallTotals(&totals);
    try std.testing.expectEqual(@as(f64, 0), totals.landscape_ice_volume_m3);
    try std.testing.expectEqual(@as(f64, 0), totals.unconsumed_water_flux_total);
    try std.testing.expectEqual(@as(f64, 0), totals.unconsumed_plant_volume_total);
    try std.testing.expectEqual(@as(f64, 0), totals.unconsumed_total_volume);
}

test "REDIST call-total reset rejects late nonfinite state atomically" {
    var totals = CallTotals{
        .landscape_ice_volume_m3 = 1,
        .unconsumed_water_flux_total = 2,
        .unconsumed_plant_volume_total = 3,
        .unconsumed_total_volume = std.math.nan(f64),
    };
    try std.testing.expectError(error.InvalidRedistCallTotal, resetCallTotals(&totals));
    try std.testing.expectEqual(@as(f64, 1), totals.landscape_ice_volume_m3);
    try std.testing.expectEqual(@as(f64, 2), totals.unconsumed_water_flux_total);
    try std.testing.expectEqual(@as(f64, 3), totals.unconsumed_plant_volume_total);
    try std.testing.expect(std.math.isNan(totals.unconsumed_total_volume));
}

test "REDIST call reset rejects invalid late state atomically" {
    var carbon = [_]f64{ 1, 2, 3, std.math.nan(f64) };
    try std.testing.expectError(
        error.InvalidErodedOrganicCarbonAccumulator,
        resetErodedOrganicCarbon(&carbon, 2, 2, .{
            .first_column = 0,
            .last_column_inclusive = 0,
            .first_row = 0,
            .last_row_inclusive = 0,
        }),
    );
    try std.testing.expectEqual(@as(f64, 1), carbon[0]);
    try std.testing.expect(std.math.isNan(carbon[3]));
}

test "REDIST call reset rejects reversed and out-of-range windows" {
    var carbon = [_]f64{ 1, 2, 3, 4 };
    try std.testing.expectError(
        error.InvalidRedistGridWindow,
        resetErodedOrganicCarbon(&carbon, 2, 2, .{
            .first_column = 1,
            .last_column_inclusive = 0,
            .first_row = 0,
            .last_row_inclusive = 1,
        }),
    );
    try std.testing.expectError(
        error.InvalidRedistGridWindow,
        resetErodedOrganicCarbon(&carbon, 2, 2, .{
            .first_column = 0,
            .last_column_inclusive = 2,
            .first_row = 0,
            .last_row_inclusive = 1,
        }),
    );
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3, 4 }, &carbon);
}

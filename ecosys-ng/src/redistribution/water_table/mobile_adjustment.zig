// **A8a DISPOSITION: SUPERSEDED BY BOUND OWNER; WTBL-001 is closed.**
// `boundary_topology.advanceMobileTablesAtSolarNoon` consumes the accepted
// boundary ledger at the source cadence and updates modes 2/4.
//
// **HISTORICAL A8a DISPOSITION: GAP.** Do not bind until WTBL-001 is resolved. Registered
// as WTBL-001 in `docs/discrepancy_register.md`; see also
// `docs/traceability/redistribution_water_table_family_is_a_blocked_gap.md`.
//
// Citation verified by reading `redist.f`, and it corrects a claim two sibling
// banners make. This module transcribes `redist.f:11090--11100`: for `IDTBL ==
// 2 or 4`, `DTBLX = DTBLZ + CDPTH(NU-1)` then `DTBLX = DTBLX -
// HVOLO/AREA(3,NU) - 0.00167*(DTBLX - DTBLZ - CDPTH(NU-1))` (`:11091--11094`),
// and separately for `IDTBL == 4`, `DTBLY = DTBLY - HVOLO/AREA(3,NU) -
// 0.00167*(DTBLY - DTBLD)` (`:11096--11099`). `adjustCell` (`:94`) reproduces
// both, including the `IDTBL` gate at `:103`, the two-statement sequencing of
// the natural arm at `:105--107`, and restricting the artificial arm to type 4
// at `:109` and `:116`.
//
// The correction: both `management/drainage_management.zig:9--10` and
// `soil/water/table_depth_mode_adjustment.zig:18--19` describe this drift as
// happening "each step". It does not. `:11090` sits inside the block opened at
// `redist.f:11019` by `IF(NFZ.EQ.1.AND.J.EQ.INT(ZNOON(NY,NX)))THEN`, verified
// by counting `IF`/`ENDIF` nesting from `:11019` forward: at `:11090` the
// depth is 2, and the outer block is still open. So the drift is applied once
// per day, at the solar-noon sub-step, not once per `NFZ`. The `0.00167`
// relaxation coefficient must be read against a daily interval, and anyone
// binding this on an hourly or sub-hourly cadence would apply it roughly 24 or
// 96 times too often. Those two sibling banners are left as they are rather
// than edited from here, per the rule against editing other dispositions; this
// is the correction of record.
//
// Unbound, registry-only. References are `module_index.zig:1070` and
// `index/redistribution_test_index.zig:84`. No production caller.
//
// Blockers, two of them. First, `soil_surface_elevation_m` (`:77`,
// `CDPTH(NU-1)`) has no publisher anywhere in `src`. Second, and less obvious,
// `net_boundary_water_transfer_m3_step` (`:78`, `HVOLO`) does exist in
// production but not in this shape: per
// `soil/water/subsurface_boundary_water_heat_accounting.zig:14--24`, `VOLWOU`,
// `UVOLO` and `HVOLO` collapse into one signed per-layer flux array summed per
// cell into the daily water ledger, so a per-cell per-step `HVOLO` scalar
// would have to be re-derived from that reduction rather than read. Neither
// input is available as declared.
//
// Also inert by mode. Even given inputs, the gate requires `IDTBL` 2 or 4, and
// production can never reach those values at runtime: mode is copied once from
// the site record (`soil/profile/boundary_topology.zig:89`) and the only thing
// that could promote it, the `ITILL == 24` arm, is itself dropped at
// `management/disturbance_management_dispatch.zig:107`. So this module is
// blocked twice over, on inputs and on reachability.
//
// Near-miss owner: `management/drainage_management.zig advanceMobileTables`
// implements the same drift with the `0.00167` relaxation as a runtime
// control, and `soil/water/table_depth_mode_adjustment.zig` is the hourly
// refresh half. All three are unbound. Bind at most one.
//
// Empirical scope, established by reading the suite rather than transcribing
// the caveat WTBL-001 left open. WTBL-001 recorded that it had not been
// checked whether any example selects mode 2 or 4 or schedules operation 23 or
// 24. Checked now, over the authoritative `../examples_ng-prod`: it contains
// exactly one deck, `Cool Temperate Maize-Soybean ON`. Its only site file is
// `runottawa_input_files/landscape/f25si98`, whose record 1 is `92 5.4 3 94.6
// 0.23 0.00`; `state/site.zig:81` parses token 3 as `water_table_mode`, so the
// mode is 3, artificial stationary. Its five disturbance files
// `soil/tillage_disturbance/f25til98` through `f25til02` were printed in full
// and contain only operation codes 10, 8, 5, 4, 2 and 1, every one inside the
// tillage range 1..20. So no deck in the suite reaches either drainage arm or
// either mobile arm. This gap is vacuous for the whole shipped suite, not
// merely for one deck, and that is now a checked statement rather than an open
// question.
//
// What is not claimed. No numerical comparison against the Fortran was run,
// because no deck exercises the path, so there is nothing to compare. The per-
// cell arithmetic here was read against `redist.f` statement by statement and
// matches, but "matches on reading" is weaker than "agrees at runtime" and is
// not upgraded here.
const std = @import("std");

pub const Inputs = struct {
    water_table_type: []const i32, // IDTBL: 2 natural mobile, 4 artificial mobile
    soil_surface_elevation_m: []const f64, // CDPTH(NU-1)
    net_boundary_water_transfer_m3_step: []const f64, // HVOLO
    cell_area_m2: []const f64, // AREA(3,NU)
};
pub const State = struct {
    natural_reference_depth_m: []const f64, // DTBLZ
    natural_current_depth_m: []f64, // DTBLX
    artificial_reference_depth_m: []const f64, // DTBLD
    artificial_current_depth_m: []f64, // DTBLY
};

fn finiteSlice(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 11090--11100 for one runtime-indexed cell.
pub fn adjustCell(cell: usize, inputs: Inputs, state: State) !bool {
    const cell_count = inputs.water_table_type.len;
    if (cell_count == 0 or cell >= cell_count) return error.MobileWaterTableDimensionMismatch;
    inline for (.{ inputs.soil_surface_elevation_m, inputs.net_boundary_water_transfer_m3_step, inputs.cell_area_m2, state.natural_reference_depth_m, state.natural_current_depth_m, state.artificial_reference_depth_m, state.artificial_current_depth_m }) |values|
        if (values.len != cell_count) return error.MobileWaterTableDimensionMismatch;
    inline for (.{ inputs.soil_surface_elevation_m, inputs.net_boundary_water_transfer_m3_step, inputs.cell_area_m2, state.natural_reference_depth_m, state.natural_current_depth_m, state.artificial_reference_depth_m, state.artificial_current_depth_m }) |values|
        if (!finiteSlice(values)) return error.InvalidMobileWaterTableInput;
    if (inputs.cell_area_m2[cell] <= 0) return error.InvalidMobileWaterTableInput;
    const water_table_type = inputs.water_table_type[cell];
    if (water_table_type != 2 and water_table_type != 4) return false;

    var next_natural = state.natural_reference_depth_m[cell] + inputs.soil_surface_elevation_m[cell];
    next_natural = next_natural - inputs.net_boundary_water_transfer_m3_step[cell] / inputs.cell_area_m2[cell] -
        0.00167 * (next_natural - state.natural_reference_depth_m[cell] - inputs.soil_surface_elevation_m[cell]);
    var next_artificial = state.artificial_current_depth_m[cell];
    if (water_table_type == 4) {
        next_artificial = next_artificial - inputs.net_boundary_water_transfer_m3_step[cell] / inputs.cell_area_m2[cell] -
            0.00167 * (next_artificial - state.artificial_reference_depth_m[cell]);
    }
    if (!std.math.isFinite(next_natural) or !std.math.isFinite(next_artificial))
        return error.NonFiniteMobileWaterTableResult;
    state.natural_current_depth_m[cell] = next_natural;
    if (water_table_type == 4) state.artificial_current_depth_m[cell] = next_artificial;
    return true;
}

test "REDIST mobile water table preserves IDTBL gates and sequential equations" {
    const types = [_]i32{ 0, 2, 4 };
    const surface = [_]f64{ 1, 2, 3 };
    const transfer = [_]f64{ 10, 20, 30 };
    const area = [_]f64{ 10, 10, 10 };
    const natural_reference = [_]f64{ 4, 5, 6 };
    var natural_current = [_]f64{ 7, 8, 9 };
    const artificial_reference = [_]f64{ 10, 11, 12 };
    var artificial_current = [_]f64{ 13, 14, 15 };
    const inputs = Inputs{ .water_table_type = &types, .soil_surface_elevation_m = &surface, .net_boundary_water_transfer_m3_step = &transfer, .cell_area_m2 = &area };
    const state = State{ .natural_reference_depth_m = &natural_reference, .natural_current_depth_m = &natural_current, .artificial_reference_depth_m = &artificial_reference, .artificial_current_depth_m = &artificial_current };
    try std.testing.expect(!try adjustCell(0, inputs, state));
    try std.testing.expect(try adjustCell(1, inputs, state));
    try std.testing.expectEqual(@as(f64, 5), natural_current[1]);
    try std.testing.expectEqual(@as(f64, 14), artificial_current[1]);
    try std.testing.expect(try adjustCell(2, inputs, state));
    try std.testing.expectEqual(@as(f64, 6), natural_current[2]);
    try std.testing.expectApproxEqAbs(15 - 3 - 0.00167 * (15 - 12), artificial_current[2], 1e-12);
}

test "REDIST mobile artificial late overflow leaves natural update atomic" {
    const types = [_]i32{4};
    const surface = [_]f64{1};
    const transfer = [_]f64{-std.math.floatMax(f64)};
    const area = [_]f64{1};
    const natural_reference = [_]f64{2};
    var natural_current = [_]f64{3};
    const artificial_reference = [_]f64{0};
    var artificial_current = [_]f64{std.math.floatMax(f64)};
    try std.testing.expectError(error.NonFiniteMobileWaterTableResult, adjustCell(0, .{ .water_table_type = &types, .soil_surface_elevation_m = &surface, .net_boundary_water_transfer_m3_step = &transfer, .cell_area_m2 = &area }, .{ .natural_reference_depth_m = &natural_reference, .natural_current_depth_m = &natural_current, .artificial_reference_depth_m = &artificial_reference, .artificial_current_depth_m = &artificial_current }));
    try std.testing.expectEqual(@as(f64, 3), natural_current[0]);
    try std.testing.expectEqual(std.math.floatMax(f64), artificial_current[0]);
}

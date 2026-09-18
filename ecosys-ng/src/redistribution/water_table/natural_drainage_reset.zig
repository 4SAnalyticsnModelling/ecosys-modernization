// **A8a DISPOSITION: SUPERSEDED BY BOUND OWNER; WTBL-001 is closed.**
// `boundary_topology.applyNaturalDrainageReset` is reached from the scheduled
// disturbance dispatcher and owns the reference/current depth transaction.
//
// **HISTORICAL A8a DISPOSITION: GAP.** Do not bind until WTBL-001 is resolved. Registered
// as WTBL-001 in `docs/discrepancy_register.md`; see also
// `docs/traceability/redistribution_water_table_family_is_a_blocked_gap.md`.
//
// Citation verified by reading `redist.f`. This module transcribes the `ITILL
// == 23` arm at `redist.f:11050--11057`, under the enclosing gate
// `IF(NFZ.EQ.1.AND.J.EQ.INT(ZNOON(NY,NX)))THEN` at `:11019`. Legacy forms
// `DCORPW = DCORP + CDPTH(NU-1)` (`:11051`), assigns `DTBLI = DCORPW`
// (`:11052`), `DTBLZ = DTBLI - (ALTZ-ALT)*(1.0-DTBLG)` (`:11053--11054`),
// `DTBLX = DTBLZ + CDPTH(NU-1)` (`:11055`), and raises `IFLGS = 1` (`:11056`).
// `applyCell` (`:99`) reproduces all five in that order at `:123--131`, and its
// gate at `:122` reproduces `NFZ == 1`, `J == INT(ZNOON)` and `ITILL == 23`
// together. Note deliberately that the `23` arm carries no `AMAX1(0.0, ...)`
// clamp, unlike the `24` arm at `:11069`; this module correctly omits one.
//
// Unbound, and this is a registry-only kernel. Its only references are
// `module_index.zig:1068` and `index/redistribution_test_index.zig:85`. There
// is no production caller and no second writer, so binding it would not create
// a precedence conflict; the reason not to bind is that it cannot be fed.
//
// The blocker, stated concretely. The module needs `soil_surface_elevation_m`
// (`CDPTH(NU-1)`, `:80`) and the elevation pair `ALTZ`/`ALT` (`:81--82`). A
// grep across `src` for `soil_surface_elevation_m` returns only this file, its
// two siblings under `redistribution/water_table/`, and the commentary in
// `management/drainage_management.zig:36`: nothing publishes it.
// `state/site.zig:79` parses a single scalar `elevation_m`, which is the site
// elevation, not the per-cell `ALT` versus reference `ALTZ` pair the
// elevation-response term needs. Until a publisher exists, `applyCell` has no
// inputs.
//
// Even with inputs it would be inert. Production reaches this event and drops
// it: `management/disturbance_schedule.zig:80` does decode code 23 into
// `.natural_drainage`, so the parse is not the problem, but
// `management/disturbance_management_dispatch.zig applyEvent` (`:95`) switches
// on `event.operation`, handles `.tillage` (`:97`) and `.fire` (`:98`), and
// falls through `else => return` at `:107` without effect or log. That silent
// drop is DIST-021. Furthermore the state this module would write does not
// exist as two arrays: `soil/profile/boundary_topology.zig` keeps one
// `natural_water_table_depth_m` (`:31`), written once at `:85`, so there is no
// `DTBLI`/`DTBLZ`/`DTBLX` triple to update and no `IFLGS` refresh flag.
//
// Near-miss owner, named so the next reader is not misled.
// `management/drainage_management.zig` performs the same 23 transaction and
// also the 24 transaction and the mobile drift, is more complete than this
// module, and is equally unbound and equally blocked on the same publisher. Do
// not bind these two independently; they would both write the same table.
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

pub const Schedule = struct {
    event_count: usize,
    cell_count: usize,
    /// ITILL(I,NY,NX), event-major then cell.
    disturbance_type: []const i32,
    /// DCORP(I,NY,NX), event-major then cell (m).
    configured_water_table_depth_m: []const f64,
    solar_noon_h: []const f64, // ZNOON, cell-major
};
pub const Geometry = struct {
    soil_surface_elevation_m: []const f64, // CDPTH(NU-1), cell-major
    reference_elevation_m: []const f64, // ALTZ
    cell_elevation_m: []const f64, // ALT
    natural_water_table_slope_m_m: []const f64, // DTBLG
};
pub const State = struct {
    natural_water_table_input_depth_m: []f64, // DTBLI
    natural_water_table_reference_depth_m: []f64, // DTBLZ
    natural_water_table_current_depth_m: []f64, // DTBLX
    soil_boundary_refresh_flag: []u8, // IFLGS
};

fn finiteSlice(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 11019 and 11050--11057 for one event and cell.
/// Returns true only when the scheduled natural-drainage reset is applied.
pub fn applyCell(first_daily_cycle: i32, hour: i32, event: usize, cell: usize, schedule: Schedule, geometry: Geometry, state: State) !bool {
    if (schedule.event_count == 0 or schedule.cell_count == 0 or event >= schedule.event_count or cell >= schedule.cell_count or
        schedule.disturbance_type.len != schedule.event_count * schedule.cell_count or
        schedule.configured_water_table_depth_m.len != schedule.event_count * schedule.cell_count or
        schedule.solar_noon_h.len != schedule.cell_count)
        return error.NaturalDrainageResetDimensionMismatch;
    inline for (std.meta.fields(Geometry)) |field|
        if (@field(geometry, field.name).len != schedule.cell_count) return error.NaturalDrainageResetDimensionMismatch;
    inline for (std.meta.fields(State)) |field|
        if (@field(state, field.name).len != schedule.cell_count) return error.NaturalDrainageResetDimensionMismatch;
    if (!finiteSlice(schedule.configured_water_table_depth_m) or !finiteSlice(schedule.solar_noon_h))
        return error.InvalidNaturalDrainageResetInput;
    inline for (std.meta.fields(Geometry)) |field|
        if (!finiteSlice(@field(geometry, field.name))) return error.InvalidNaturalDrainageResetInput;
    inline for (.{ state.natural_water_table_input_depth_m, state.natural_water_table_reference_depth_m, state.natural_water_table_current_depth_m }) |values|
        if (!finiteSlice(values)) return error.InvalidNaturalDrainageResetInput;
    const at = event * schedule.cell_count + cell;
    if (schedule.solar_noon_h[cell] < 0 or schedule.solar_noon_h[cell] > 24 or
        geometry.natural_water_table_slope_m_m[cell] < 0 or
        geometry.natural_water_table_slope_m_m[cell] > 1)
        return error.InvalidNaturalDrainageResetInput;

    const solar_noon_integer: i32 = @intFromFloat(schedule.solar_noon_h[cell]);
    if (first_daily_cycle != 1 or hour != solar_noon_integer or schedule.disturbance_type[at] != 23) return false;
    const depth_with_surface_m = schedule.configured_water_table_depth_m[at] + geometry.soil_surface_elevation_m[cell];
    const reference_depth_m = depth_with_surface_m - (geometry.reference_elevation_m[cell] - geometry.cell_elevation_m[cell]) * (1.0 - geometry.natural_water_table_slope_m_m[cell]);
    const current_depth_m = reference_depth_m + geometry.soil_surface_elevation_m[cell];
    inline for (.{ depth_with_surface_m, reference_depth_m, current_depth_m }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteNaturalDrainageResetResult;
    state.natural_water_table_input_depth_m[cell] = depth_with_surface_m;
    state.natural_water_table_reference_depth_m[cell] = reference_depth_m;
    state.natural_water_table_current_depth_m[cell] = current_depth_m;
    state.soil_boundary_refresh_flag[cell] = 1;
    return true;
}

test "REDIST natural drainage reset preserves daily gates and equation order" {
    const disturbance = [_]i32{ 23, 23, 23, 0 };
    const configured_depth = [_]f64{ 1, 2, 3, 4 };
    const solar_noon = [_]f64{ 12.9, 13.2 };
    const surface = [_]f64{ 0.1, 0.2 };
    const reference_elevation = [_]f64{ 100, 200 };
    const cell_elevation = [_]f64{ 90, 180 };
    const gradient = [_]f64{ 0.25, 0.5 };
    var input_depth = [_]f64{ 7, 8 };
    var reference_depth = [_]f64{ 9, 10 };
    var current_depth = [_]f64{ 11, 12 };
    var flags = [_]u8{ 0, 0 };
    const schedule = Schedule{ .event_count = 2, .cell_count = 2, .disturbance_type = &disturbance, .configured_water_table_depth_m = &configured_depth, .solar_noon_h = &solar_noon };
    const geometry = Geometry{ .soil_surface_elevation_m = &surface, .reference_elevation_m = &reference_elevation, .cell_elevation_m = &cell_elevation, .natural_water_table_slope_m_m = &gradient };
    const state = State{ .natural_water_table_input_depth_m = &input_depth, .natural_water_table_reference_depth_m = &reference_depth, .natural_water_table_current_depth_m = &current_depth, .soil_boundary_refresh_flag = &flags };
    try std.testing.expect(!try applyCell(0, 12, 0, 1, schedule, geometry, state));
    try std.testing.expect(!try applyCell(1, 12, 0, 1, schedule, geometry, state));
    try std.testing.expect(try applyCell(1, 12, 0, 0, schedule, geometry, state));
    try std.testing.expectEqual(@as(f64, 1.1), input_depth[0]);
    try std.testing.expectApproxEqAbs(1.1 - (100 - 90) * (1 - 0.25), reference_depth[0], 1e-12);
    try std.testing.expectApproxEqAbs(reference_depth[0] + 0.1, current_depth[0], 1e-12);
    try std.testing.expectEqual(@as(u8, 1), flags[0]);
    try std.testing.expectEqual(@as(f64, 8), input_depth[1]);
}

test "REDIST natural drainage late overflow is atomic" {
    const disturbance = [_]i32{23};
    const configured_depth = [_]f64{std.math.floatMax(f64)};
    const solar_noon = [_]f64{12};
    const surface = [_]f64{std.math.floatMax(f64)};
    const elevation = [_]f64{0};
    const gradient = [_]f64{0};
    var input_depth = [_]f64{7};
    var reference_depth = [_]f64{8};
    var current_depth = [_]f64{9};
    var flags = [_]u8{0};
    try std.testing.expectError(error.NonFiniteNaturalDrainageResetResult, applyCell(1, 12, 0, 0, .{ .event_count = 1, .cell_count = 1, .disturbance_type = &disturbance, .configured_water_table_depth_m = &configured_depth, .solar_noon_h = &solar_noon }, .{ .soil_surface_elevation_m = &surface, .reference_elevation_m = &elevation, .cell_elevation_m = &elevation, .natural_water_table_slope_m_m = &gradient }, .{ .natural_water_table_input_depth_m = &input_depth, .natural_water_table_reference_depth_m = &reference_depth, .natural_water_table_current_depth_m = &current_depth, .soil_boundary_refresh_flag = &flags }));
    try std.testing.expectEqual(@as(f64, 7), input_depth[0]);
    try std.testing.expectEqual(@as(f64, 8), reference_depth[0]);
    try std.testing.expectEqual(@as(f64, 9), current_depth[0]);
    try std.testing.expectEqual(@as(u8, 0), flags[0]);
}

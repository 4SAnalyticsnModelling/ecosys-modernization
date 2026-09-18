// **A8a DISPOSITION: SUPERSEDED BY BOUND OWNER; WTBL-001 is closed.**
// `boundary_topology.applyArtificialDrainageReset` performs mode promotion,
// depth reset, and directional boundary restoration from operation 24.
//
// **HISTORICAL A8a DISPOSITION: GAP.** Do not bind until WTBL-001 is resolved. Registered
// as WTBL-001 in `docs/discrepancy_register.md`; see also
// `docs/traceability/redistribution_water_table_family_is_a_blocked_gap.md`.
//
// Citation verified by reading `redist.f`. This module transcribes the `ITILL
// == 24` arm at `redist.f:11061--11085`, under the same solar-noon gate at
// `:11019`. Legacy forms `DCORPW = DCORP + CDPTH(NU-1)` (`:11062`), promotes
// `IDTBL` 1 to 3 and 2 to 4 (`:11063--11067`), assigns `DTBLDI = DCORPW`
// (`:11068`), `DTBLD = AMAX1(0.0, DTBLDI - (ALTZ-ALT)*(1.0-DTBLDG))` (`:11069
// --11070`), `DTBLY = DTBLD` (`:11071`), and restores all eight recharge
// boundary controls `RCHG{N,E,S,W}{A,B}` from their `*Z` initial values
// (`:11072--11079`). `applyCell` (`:121`) reproduces every one: the gate at
// `:149`, the promotion at `:152`, the clamped reference depth at `:153` with
// the `@max(0.0, ...)` that the `23` arm does not have, the `DTBLY = DTBLD`
// copy at `:160`, and the eight-way restore as one `inline for` at `:161--162`.
//
// The mode promotion is the part worth flagging. Installing tile drainage mid-
// run is not just a depth edit; it changes the cell's water-table mode, which
// changes which boundary arms the water solver takes. Production copies
// `site.water_table_mode` into `soil/profile/boundary_topology.zig:30` once at
// `:89` and never reassigns it. Verified by grepping `water_table_mode` across
// `src`: the only non-test writes are that initialization and the reads at
// `soil/water/solver_residual.zig:248` and `:264`. So the promotion cannot
// happen, and a runscript that installs drainage partway through a run
// completes normally with the original boundary configuration.
//
// Unbound, registry-only. References are `module_index.zig:1069` and
// `index/redistribution_test_index.zig:55`. No production caller, therefore no
// competing writer.
//
// Blockers. Same missing `soil_surface_elevation_m` and `ALTZ`/`ALT` pair as
// its natural-drainage sibling; additionally the eight `RCHG*` boundary
// controls and their `*Z` baselines are not carried as a mutable pair in
// production, so there is nothing to restore. The event also reaches
// `disturbance_schedule.zig:81`, which decodes code 24 and even parses the
// artificial-drainage boundary record, and is then dropped by
// `disturbance_management_dispatch.zig:107`. Parsing work is being done and
// thrown away.
//
// Near-miss owner: `management/drainage_management.zig` performs this same
// transaction and is also unbound and also blocked. Bind at most one of them.
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
    disturbance_type: []const i32, // ITILL, event-major then cell
    configured_water_table_depth_m: []const f64, // DCORP, event-major then cell
    solar_noon_h: []const f64, // ZNOON, cell-major
};
pub const Geometry = struct {
    soil_surface_elevation_m: []const f64, // CDPTH(NU-1)
    reference_elevation_m: []const f64, // ALTZ
    cell_elevation_m: []const f64, // ALT
    artificial_water_table_slope_m_m: []const f64, // DTBLDG
};
pub const ArtificialBoundaryParameters = struct {
    north_distance_m: []f64,
    east_distance_m: []f64,
    south_distance_m: []f64,
    west_distance_m: []f64,
    north_exchange_fraction: []f64,
    east_exchange_fraction: []f64,
    south_exchange_fraction: []f64,
    west_exchange_fraction: []f64,
};
pub const State = struct {
    water_table_type: []i32, // IDTBL
    artificial_water_table_input_depth_m: []f64, // DTBLDI
    artificial_water_table_reference_depth_m: []f64, // DTBLD
    artificial_water_table_current_depth_m: []f64, // DTBLY
    boundary_parameters: ArtificialBoundaryParameters, // RCHG*A/B
    baseline_boundary_parameters: ArtificialBoundaryParameters, // RCHG*AZ/BZ
};

fn finiteSlice(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}
fn validBoundaryDimensions(parameters: ArtificialBoundaryParameters, cell_count: usize) bool {
    inline for (std.meta.fields(ArtificialBoundaryParameters)) |field|
        if (@field(parameters, field.name).len != cell_count) return false;
    return true;
}
fn finiteBoundaryParameters(parameters: ArtificialBoundaryParameters) bool {
    inline for (std.meta.fields(ArtificialBoundaryParameters)) |field|
        if (!finiteSlice(@field(parameters, field.name))) return false;
    return true;
}

fn validBoundaryDomains(parameters: ArtificialBoundaryParameters) bool {
    inline for (.{ parameters.north_distance_m, parameters.east_distance_m, parameters.south_distance_m, parameters.west_distance_m }) |distances|
        for (distances) |distance_m| if (distance_m < 0) return false;
    inline for (.{ parameters.north_exchange_fraction, parameters.east_exchange_fraction, parameters.south_exchange_fraction, parameters.west_exchange_fraction }) |fractions|
        for (fractions) |fraction| if (fraction < 0 or fraction > 1) return false;
    return true;
}

/// Direct translation of REDIST 11019 and 11061--11085 for one event and cell.
pub fn applyCell(first_daily_cycle: i32, hour: i32, event: usize, cell: usize, schedule: Schedule, geometry: Geometry, state: State) !bool {
    if (schedule.event_count == 0 or schedule.cell_count == 0 or event >= schedule.event_count or cell >= schedule.cell_count or
        schedule.disturbance_type.len != schedule.event_count * schedule.cell_count or
        schedule.configured_water_table_depth_m.len != schedule.event_count * schedule.cell_count or
        schedule.solar_noon_h.len != schedule.cell_count)
        return error.ArtificialDrainageResetDimensionMismatch;
    inline for (std.meta.fields(Geometry)) |field|
        if (@field(geometry, field.name).len != schedule.cell_count) return error.ArtificialDrainageResetDimensionMismatch;
    inline for (.{ state.water_table_type, state.artificial_water_table_input_depth_m, state.artificial_water_table_reference_depth_m, state.artificial_water_table_current_depth_m }) |values|
        if (values.len != schedule.cell_count) return error.ArtificialDrainageResetDimensionMismatch;
    if (!validBoundaryDimensions(state.boundary_parameters, schedule.cell_count) or !validBoundaryDimensions(state.baseline_boundary_parameters, schedule.cell_count))
        return error.ArtificialDrainageResetDimensionMismatch;
    if (!finiteSlice(schedule.configured_water_table_depth_m) or !finiteSlice(schedule.solar_noon_h))
        return error.InvalidArtificialDrainageResetInput;
    inline for (std.meta.fields(Geometry)) |field|
        if (!finiteSlice(@field(geometry, field.name))) return error.InvalidArtificialDrainageResetInput;
    inline for (.{ state.artificial_water_table_input_depth_m, state.artificial_water_table_reference_depth_m, state.artificial_water_table_current_depth_m }) |values|
        if (!finiteSlice(values)) return error.InvalidArtificialDrainageResetInput;
    if (!finiteBoundaryParameters(state.boundary_parameters) or !finiteBoundaryParameters(state.baseline_boundary_parameters))
        return error.InvalidArtificialDrainageResetInput;
    if (!validBoundaryDomains(state.boundary_parameters) or !validBoundaryDomains(state.baseline_boundary_parameters))
        return error.InvalidArtificialDrainageResetInput;
    const at = event * schedule.cell_count + cell;
    if (schedule.solar_noon_h[cell] < 0 or schedule.solar_noon_h[cell] > 24 or
        geometry.artificial_water_table_slope_m_m[cell] < 0 or geometry.artificial_water_table_slope_m_m[cell] > 1)
        return error.InvalidArtificialDrainageResetInput;

    const solar_noon_integer: i32 = @intFromFloat(schedule.solar_noon_h[cell]);
    if (first_daily_cycle != 1 or hour != solar_noon_integer or schedule.disturbance_type[at] != 24) return false;
    const depth_with_surface_m = schedule.configured_water_table_depth_m[at] + geometry.soil_surface_elevation_m[cell];
    var next_type = state.water_table_type[cell];
    if (next_type == 1) next_type = 3 else if (next_type == 2) next_type = 4;
    const reference_depth_m = @max(0.0, depth_with_surface_m - (geometry.reference_elevation_m[cell] - geometry.cell_elevation_m[cell]) * (1.0 - geometry.artificial_water_table_slope_m_m[cell]));
    inline for (.{ depth_with_surface_m, reference_depth_m }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteArtificialDrainageResetResult;

    state.water_table_type[cell] = next_type;
    state.artificial_water_table_input_depth_m[cell] = depth_with_surface_m;
    state.artificial_water_table_reference_depth_m[cell] = reference_depth_m;
    state.artificial_water_table_current_depth_m[cell] = reference_depth_m;
    inline for (std.meta.fields(ArtificialBoundaryParameters)) |field|
        @field(state.boundary_parameters, field.name)[cell] = @field(state.baseline_boundary_parameters, field.name)[cell];
    return true;
}

fn boundaryParameterSlices(backing: *[8][2]f64) ArtificialBoundaryParameters {
    return .{ .north_distance_m = &backing[0], .east_distance_m = &backing[1], .south_distance_m = &backing[2], .west_distance_m = &backing[3], .north_exchange_fraction = &backing[4], .east_exchange_fraction = &backing[5], .south_exchange_fraction = &backing[6], .west_exchange_fraction = &backing[7] };
}

test "REDIST artificial drainage reset preserves gates type remap and recharge copies" {
    const disturbance = [_]i32{ 24, 24 };
    const configured = [_]f64{ 2, 3 };
    const noon = [_]f64{ 12.9, 13.2 };
    const surface = [_]f64{ 0.1, 0.2 };
    const reference_elevation = [_]f64{ 100, 200 };
    const cell_elevation = [_]f64{ 90, 180 };
    const gradient = [_]f64{ 0.25, 0.5 };
    var types = [_]i32{ 1, 2 };
    var input_depth = [_]f64{ 7, 8 };
    var reference_depth = [_]f64{ 9, 10 };
    var current_depth = [_]f64{ 11, 12 };
    var current_backing: [8][2]f64 = @splat(@splat(0));
    var baseline_backing: [8][2]f64 = undefined;
    for (0..8) |direction| baseline_backing[direction] = if (direction < 4)
        .{ @floatFromInt(direction + 1), @floatFromInt(direction + 11) }
    else
        .{ 0.1 * @as(f64, @floatFromInt(direction - 3)), 0.2 * @as(f64, @floatFromInt(direction - 3)) };
    const schedule = Schedule{ .event_count = 1, .cell_count = 2, .disturbance_type = &disturbance, .configured_water_table_depth_m = &configured, .solar_noon_h = &noon };
    const geometry = Geometry{ .soil_surface_elevation_m = &surface, .reference_elevation_m = &reference_elevation, .cell_elevation_m = &cell_elevation, .artificial_water_table_slope_m_m = &gradient };
    const state = State{ .water_table_type = &types, .artificial_water_table_input_depth_m = &input_depth, .artificial_water_table_reference_depth_m = &reference_depth, .artificial_water_table_current_depth_m = &current_depth, .boundary_parameters = boundaryParameterSlices(&current_backing), .baseline_boundary_parameters = boundaryParameterSlices(&baseline_backing) };
    try std.testing.expect(!try applyCell(1, 12, 0, 1, schedule, geometry, state));
    try std.testing.expect(try applyCell(1, 12, 0, 0, schedule, geometry, state));
    try std.testing.expectEqual(@as(i32, 3), types[0]);
    try std.testing.expectEqual(@as(f64, 2.1), input_depth[0]);
    try std.testing.expectEqual(@as(f64, 0), reference_depth[0]);
    try std.testing.expectEqual(@as(f64, 0), current_depth[0]);
    for (0..8) |direction| try std.testing.expectEqual(baseline_backing[direction][0], current_backing[direction][0]);
    try std.testing.expectEqual(@as(i32, 2), types[1]);
}

test "REDIST artificial drainage late overflow is atomic" {
    const disturbance = [_]i32{ 24, 0 };
    const configured = [_]f64{ std.math.floatMax(f64), 0 };
    const noon = [_]f64{ 12, 12 };
    const surface = [_]f64{ std.math.floatMax(f64), 0 };
    const elevation = [_]f64{ 0, 0 };
    const gradient = [_]f64{ 0, 0 };
    var types = [_]i32{ 1, 0 };
    var input_depth = [_]f64{ 7, 0 };
    var reference_depth = [_]f64{ 8, 0 };
    var current_depth = [_]f64{ 9, 0 };
    var current_backing: [8][2]f64 = @splat(@splat(0));
    var baseline_backing: [8][2]f64 = @splat(@splat(1));
    try std.testing.expectError(error.NonFiniteArtificialDrainageResetResult, applyCell(1, 12, 0, 0, .{ .event_count = 1, .cell_count = 2, .disturbance_type = &disturbance, .configured_water_table_depth_m = &configured, .solar_noon_h = &noon }, .{ .soil_surface_elevation_m = &surface, .reference_elevation_m = &elevation, .cell_elevation_m = &elevation, .artificial_water_table_slope_m_m = &gradient }, .{ .water_table_type = &types, .artificial_water_table_input_depth_m = &input_depth, .artificial_water_table_reference_depth_m = &reference_depth, .artificial_water_table_current_depth_m = &current_depth, .boundary_parameters = boundaryParameterSlices(&current_backing), .baseline_boundary_parameters = boundaryParameterSlices(&baseline_backing) }));
    try std.testing.expectEqual(@as(i32, 1), types[0]);
    try std.testing.expectEqual(@as(f64, 7), input_depth[0]);
    try std.testing.expectEqual(@as(f64, 0), current_backing[0][0]);
}

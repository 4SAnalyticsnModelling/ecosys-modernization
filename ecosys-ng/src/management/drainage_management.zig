// **A8a DISPOSITION: SUPERSEDED BY BOUND OWNER; WTBL-001 is closed.** Scheduled
// operations 23/24 dispatch into `boundary_topology` reset transactions; hourly
// head refresh and solar-noon mobile-table drift are also production-bound.
//
// **HISTORICAL A8a DISPOSITION: GAP.** Do not bind until WTBL-001 is resolved. This module
// is complete, correct as far as it was checked, and has no caller.
//
// The legacy block is `redist.f:11050--11100`, read verbatim. `ITILL == 23`
// rewrites `DTBLI`, recomputes `DTBLZ` with the elevation-response term and
// `DTBLX` with the `CDPTH(NU-1)` surface offset, and raises `IFLGS`.
// `ITILL == 24` rewrites `DTBLDI`/`DTBLD`, copies `DTBLY`, restores all eight
// recharge boundary controls from their initial values, and promotes `IDTBL`
// from 1 to 3 and from 2 to 4. `:11090--11100` then drifts both mobile tables
// each step by `HVOLO/AREA` with a `0.00167` relaxation toward the reference.
// This file performs all of that, mode promotion and boundary restore included.
//
// The family argument in full: unbound `src/management/` is otherwise superseded
// because production replaced per-statement HOUR1/REDIST decomposition with
// three runscript-catalog schedule dispatchers, each legacy statement landing in
// a bound applier. Here the dispatcher exists and drops the event.
// `water_table_mode` lives at `soil/profile/boundary_topology.zig:30`, is copied
// once from the site record at `:89`, and is never reassigned; only
// `initial_water_table_depth_m` and `natural_water_table_surface_slope` are
// threaded (`ecosys_ng.zig:1422--1423`, `:1794`), plus
// `internal_water_table_depth_m` (`:6296`, `:7255`). No mode can be promoted and
// neither disturbance can take effect.
//
// Read first, in this order:
// docs/traceability/hour1_water_table_mode_adjustment_is_owned_by_boundary_topology.md,
// which establishes that the *hourly refresh* at `hour1.f:2348--2356` is a
// representational identity for the stationary modes and is correctly absent;
// then DIST-021, which records that operations 23 and 24 reach
// `disturbance_management_dispatch.applyEvent` and fall through its
// `else => return` without effect or log, and defers their analysis. WTBL-001 is
// that deferred analysis.
//
// Blocker, stated openly: the mobile arms need `CDPTH(NU-1)` and its initial
// value, which nothing in the tree publishes.
// `redistribution/water_table/mobile_adjustment.zig` is the other half of the
// same capability, is likewise UNBOUND, and consumes a `soil_surface_elevation_m`
// that has no producer. Neither half can be bound before that publisher exists.
//
// Vacuity caveat: Ottawa's site record gives `water_table_mode = 3`, artificial
// stationary, never disturbed, so the gap is vacuous for the shipped
// configuration. Whether any example selects mode 2 or 4, or schedules operation
// 23 or 24, was not checked.
//
// Register: WTBL-001 in docs/discrepancy_register.md.
// M4 disturbance group of
// docs/traceability/management_unbound_family_is_superseded_by_the_schedule_dispatchers.md
const std = @import("std");

pub const WaterTableType = enum(u8) {
    none = 0,
    natural_stationary = 1,
    natural_mobile = 2,
    artificial_stationary = 3,
    artificial_mobile = 4,
};

pub const DirectionalBoundaries = struct {
    initial_distance_m: []const f64,
    initial_flow_enabled: []const bool,
    active_distance_m: []f64,
    active_flow_enabled: []bool,
};

pub const CellState = struct {
    water_table_type: WaterTableType,
    reference_elevation_m: f64,
    current_elevation_m: f64,
    surface_elevation_m: f64,
    natural_elevation_response_fraction: f64,
    artificial_elevation_response_fraction: f64,
    natural_input_head_m: f64,
    natural_reference_head_m: f64,
    natural_current_head_m: f64,
    artificial_input_head_m: f64,
    artificial_reference_head_m: f64,
    artificial_current_head_m: f64,
    natural_profile_refresh_required: bool,
};

/// REDIST disturbance 23. Validation completes before the state state_update.
pub fn applyNaturalDrainage(
    state: *CellState,
    requested_depth_below_surface_m: f64,
) !void {
    try validateState(state.*, null);
    try validateDepth(requested_depth_below_surface_m);
    const input_head_m =
        requested_depth_below_surface_m + state.surface_elevation_m;
    const reference_head_m = input_head_m -
        (state.reference_elevation_m - state.current_elevation_m) *
            (1 - state.natural_elevation_response_fraction);
    const current_head_m = reference_head_m + state.surface_elevation_m;
    try validateDerived(&.{ input_head_m, reference_head_m, current_head_m });

    state.natural_input_head_m = input_head_m;
    state.natural_reference_head_m = reference_head_m;
    state.natural_current_head_m = current_head_m;
    state.natural_profile_refresh_required = true;
}

/// REDIST disturbance 24. The four compass boundaries are represented as
/// runtime slices so no compile-time landscape dimension enters the kernel.
pub fn applyArtificialDrainage(
    state: *CellState,
    boundaries: DirectionalBoundaries,
    requested_depth_below_surface_m: f64,
) !void {
    try validateState(state.*, boundaries);
    try validateDepth(requested_depth_below_surface_m);
    const next_type: WaterTableType = switch (state.water_table_type) {
        .natural_stationary => .artificial_stationary,
        .natural_mobile => .artificial_mobile,
        else => state.water_table_type,
    };
    const input_head_m =
        requested_depth_below_surface_m + state.surface_elevation_m;
    const reference_head_m = @max(
        0,
        input_head_m -
            (state.reference_elevation_m - state.current_elevation_m) *
                (1 - state.artificial_elevation_response_fraction),
    );
    try validateDerived(&.{ input_head_m, reference_head_m });

    state.water_table_type = next_type;
    state.artificial_input_head_m = input_head_m;
    state.artificial_reference_head_m = reference_head_m;
    state.artificial_current_head_m = reference_head_m;
    @memcpy(boundaries.active_distance_m, boundaries.initial_distance_m);
    @memcpy(
        boundaries.active_flow_enabled,
        boundaries.initial_flow_enabled,
    );
}

/// Exact mobile-table continuation in REDIST. `relaxation_per_hour` is a
/// runtime control whose compatibility value is the source 0.00167 h-1.
pub fn advanceMobileTables(
    state: *CellState,
    net_boundary_water_outflow_m3: f64,
    horizontal_cell_area_m2: f64,
    relaxation_per_hour: f64,
) !void {
    try validateState(state.*, null);
    inline for (.{
        net_boundary_water_outflow_m3,
        horizontal_cell_area_m2,
        relaxation_per_hour,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteDrainageManagementInput;
    if (horizontal_cell_area_m2 <= 0 or relaxation_per_hour < 0 or
        relaxation_per_hour > 1)
        return error.InvalidDrainageManagementInput;

    const specific_outflow_m =
        net_boundary_water_outflow_m3 / horizontal_cell_area_m2;
    var natural_next = state.natural_current_head_m;
    var artificial_next = state.artificial_current_head_m;
    if (state.water_table_type == .natural_mobile or
        state.water_table_type == .artificial_mobile)
    {
        // The source first reconstructs DTBLX from the elevation-adjusted
        // reference, then applies outflow. Its following relaxation term is
        // therefore exactly zero at this point.
        natural_next = state.natural_reference_head_m +
            state.surface_elevation_m - specific_outflow_m;
    }
    if (state.water_table_type == .artificial_mobile) {
        artificial_next = state.artificial_current_head_m -
            specific_outflow_m -
            relaxation_per_hour *
                (state.artificial_current_head_m -
                    state.artificial_reference_head_m);
    }
    try validateDerived(&.{ natural_next, artificial_next });
    state.natural_current_head_m = natural_next;
    state.artificial_current_head_m = artificial_next;
}

fn validateState(
    state: CellState,
    maybe_boundaries: ?DirectionalBoundaries,
) !void {
    inline for (.{
        state.reference_elevation_m,
        state.current_elevation_m,
        state.surface_elevation_m,
        state.natural_elevation_response_fraction,
        state.artificial_elevation_response_fraction,
        state.natural_input_head_m,
        state.natural_reference_head_m,
        state.natural_current_head_m,
        state.artificial_input_head_m,
        state.artificial_reference_head_m,
        state.artificial_current_head_m,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteDrainageManagementState;
    if (state.natural_elevation_response_fraction < 0 or
        state.natural_elevation_response_fraction > 1 or
        state.artificial_elevation_response_fraction < 0 or
        state.artificial_elevation_response_fraction > 1)
        return error.InvalidDrainageElevationResponse;
    if (maybe_boundaries) |boundaries| {
        const count = boundaries.initial_distance_m.len;
        if (count == 0 or boundaries.initial_flow_enabled.len != count or
            boundaries.active_distance_m.len != count or
            boundaries.active_flow_enabled.len != count)
            return error.DrainageBoundaryDimensionMismatch;
        for (boundaries.initial_distance_m) |distance_m|
            if (!std.math.isFinite(distance_m) or distance_m < 0)
                return error.InvalidDrainageBoundaryDistance;
    }
}

fn validateDepth(depth_m: f64) !void {
    if (!std.math.isFinite(depth_m))
        return error.NonFiniteDrainageManagementInput;
    if (depth_m < 0) return error.InvalidDrainageDepth;
}

fn validateDerived(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value))
        return error.DrainageManagementOverflow;
}

fn exampleState() CellState {
    return .{
        .water_table_type = .natural_mobile,
        .reference_elevation_m = 110,
        .current_elevation_m = 100,
        .surface_elevation_m = 2,
        .natural_elevation_response_fraction = 0.25,
        .artificial_elevation_response_fraction = 0.5,
        .natural_input_head_m = 0,
        .natural_reference_head_m = 0,
        .natural_current_head_m = 0,
        .artificial_input_head_m = 0,
        .artificial_reference_head_m = 0,
        .artificial_current_head_m = 0,
        .natural_profile_refresh_required = false,
    };
}

test "disturbance 23 applies elevation-aware natural water-table heads" {
    var state = exampleState();
    try applyNaturalDrainage(&state, 3);
    try std.testing.expectEqual(@as(f64, 5), state.natural_input_head_m);
    try std.testing.expectEqual(@as(f64, -2.5), state.natural_reference_head_m);
    try std.testing.expectEqual(@as(f64, -0.5), state.natural_current_head_m);
    try std.testing.expect(state.natural_profile_refresh_required);
}

test "disturbance 24 atomically activates mobile artificial drainage" {
    var state = exampleState();
    var active_distance = [_]f64{ 90, 90, 90, 90, 90, 90 };
    var active_enabled = [_]bool{ false, false, false, false, false, false };
    const initial_distance = [_]f64{ 1, 2, 3, 4, 5, 6 };
    const initial_enabled =
        [_]bool{ true, false, true, false, true, false };
    try applyArtificialDrainage(&state, .{
        .initial_distance_m = &initial_distance,
        .initial_flow_enabled = &initial_enabled,
        .active_distance_m = &active_distance,
        .active_flow_enabled = &active_enabled,
    }, 4);
    try std.testing.expectEqual(
        WaterTableType.artificial_mobile,
        state.water_table_type,
    );
    try std.testing.expectEqual(@as(f64, 6), state.artificial_input_head_m);
    try std.testing.expectEqual(@as(f64, 1), state.artificial_reference_head_m);
    try std.testing.expectEqualSlices(f64, &initial_distance, &active_distance);
    try std.testing.expectEqualSlices(bool, &initial_enabled, &active_enabled);
}

test "invalid late artificial boundary leaves state and slices unchanged" {
    var state = exampleState();
    const before = state;
    var active_distance = [_]f64{ 8, 9 };
    const active_before = active_distance;
    var active_enabled = [_]bool{ false, false };
    const initial_distance = [_]f64{ 1, std.math.nan(f64) };
    const initial_enabled = [_]bool{ true, true };
    try std.testing.expectError(
        error.InvalidDrainageBoundaryDistance,
        applyArtificialDrainage(&state, .{
            .initial_distance_m = &initial_distance,
            .initial_flow_enabled = &initial_enabled,
            .active_distance_m = &active_distance,
            .active_flow_enabled = &active_enabled,
        }, 4),
    );
    try std.testing.expectEqualDeep(before, state);
    try std.testing.expectEqualSlices(f64, &active_before, &active_distance);
    try std.testing.expectEqualSlices(
        bool,
        &[_]bool{ false, false },
        &active_enabled,
    );
}

test "mobile update preserves source natural reset and artificial relaxation" {
    var state = exampleState();
    state.water_table_type = .artificial_mobile;
    state.natural_reference_head_m = 5;
    state.natural_current_head_m = 99;
    state.artificial_reference_head_m = 10;
    state.artificial_current_head_m = 14;
    try advanceMobileTables(&state, 20, 100, 0.00167);
    try std.testing.expectApproxEqAbs(
        @as(f64, 6.8),
        state.natural_current_head_m,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        14 - 0.2 - 0.00167 * 4,
        state.artificial_current_head_m,
        1e-14,
    );
}

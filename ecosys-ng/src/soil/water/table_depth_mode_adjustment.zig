// **A8a DISPOSITION: SUPERSEDED BY BOUND TOPOLOGY OWNER; WTBL-001 is closed.**
// Initial surface depth is bound at initialization, current heads refresh before
// WATSUB, and scheduled drainage/mobile modes update through the same owner.
//
// **HISTORICAL A8a DISPOSITION: half superseded, half gap. Keep unbound and do not banner
// as settled.** `hour1.f:2348--2356` refreshes current external water table
// depths from initial ones each hour. The two stationary arms -- `DTBLX = DTBLZ`
// for `IDTBL <= 1` or `== 3` (`:2349`) and `DTBLY = DTBLD` for `IDTBL == 3` or
// `4` (`:2355`) -- are structurally unrepresentable in production rather than
// merely redundant: `soil/profile/boundary_topology.zig` keeps a single array
// per external table (`natural_water_table_depth_m:31`,
// `artificial_water_table_depth_m:34`), written once at `:85`/`:88` from
// `starts.f:702--705` and read directly as the face's external depth by the one
// production consumer, `soil/water/solver_residual.zig:265` (gated at `:248` on
// mode `!= 0` and `:264` on mode `>= 3`). There is no second array to copy into,
// so the hourly copy is an identity.
//
// The `IDTBL == 2`/`4` mobile arm at `:2351--2352`, `DTBLZ + CDPTH(NU-1) -
// CDPTHI`, is a real gap: nothing in production publishes the soil surface
// elevation or its initial value (`starts.f:585--586`, re-derived at
// `redist.f:8324` on uppermost-layer reset). Its sibling
// `redistribution/water_table/mobile_adjustment.zig` (`redist.f:11090--11100`,
// the `HVOLO/AREA` drift) is the other half of the same absent capability and is
// itself unbound; neither can be bound until that symbol exists. Also missing:
// `redist.f:11050--11085`, where `ITILL == 23`/`24` rewrite the reference depths
// and promote `IDTBL` 1->3 and 2->4, whereas production copies
// `site.water_table_mode` once at `:89` and never reassigns it.
//
// Vacuous for the shipped Ottawa case: `f25si98` record 1 selects mode 3, so
// only the two copy arms are reachable. See the water-table group of
// docs/traceability/hour1_water_table_mode_adjustment_is_owned_by_boundary_topology.md

const std = @import("std");

pub const Mode = enum(u8) {
    none = 0,
    absolute = 1,
    relative = 2,
    absolute_dynamic = 3,
    relative_dynamic = 4,
};

pub const Inputs = struct {
    mode: Mode,
    configured_water_table_depth_m: f64,
    configured_dynamic_depth_m: f64,
    cumulative_depth_above_uppermost_soil_layer_m: f64,
    initial_cumulative_depth_m: f64,
};

pub const Result = struct {
    adjusted_water_table_depth_m: f64,
    /// Null preserves the caller's DTBLY for source modes 0, 1, and 2.
    dynamic_water_table_depth_m: ?f64,
};

/// `hour1.f` lines 2348--2356. Preserves the absolute/relative adjustment
/// followed by the independent dynamic-mode assignment.
pub fn compute(inputs: Inputs) !Result {
    try validate(inputs);
    const adjusted_water_table_depth_m = switch (inputs.mode) {
        .none, .absolute, .absolute_dynamic => inputs.configured_water_table_depth_m,
        .relative, .relative_dynamic => inputs.configured_water_table_depth_m +
            inputs.cumulative_depth_above_uppermost_soil_layer_m -
            inputs.initial_cumulative_depth_m,
    };
    if (!std.math.isFinite(adjusted_water_table_depth_m))
        return error.NonFiniteAdjustedWaterTableDepth;
    return .{
        .adjusted_water_table_depth_m = adjusted_water_table_depth_m,
        .dynamic_water_table_depth_m = switch (inputs.mode) {
            .absolute_dynamic, .relative_dynamic => inputs.configured_dynamic_depth_m,
            else => null,
        },
    };
}

fn validate(inputs: Inputs) !void {
    inline for (.{
        inputs.configured_water_table_depth_m,
        inputs.configured_dynamic_depth_m,
        inputs.cumulative_depth_above_uppermost_soil_layer_m,
        inputs.initial_cumulative_depth_m,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteWaterTableAdjustmentInput;
}

test "relative dynamic mode applies depth offset then dynamic target" {
    const result = try compute(.{
        .mode = .relative_dynamic,
        .configured_water_table_depth_m = 2,
        .configured_dynamic_depth_m = 3,
        .cumulative_depth_above_uppermost_soil_layer_m = 0.5,
        .initial_cumulative_depth_m = 0.2,
    });
    try std.testing.expectApproxEqAbs(
        @as(f64, 2.3),
        result.adjusted_water_table_depth_m,
        1e-15,
    );
    try std.testing.expectEqual(
        @as(f64, 3),
        result.dynamic_water_table_depth_m.?,
    );
}

test "absolute nondynamic mode preserves dynamic caller state" {
    const result = try compute(.{
        .mode = .absolute,
        .configured_water_table_depth_m = 2,
        .configured_dynamic_depth_m = 9,
        .cumulative_depth_above_uppermost_soil_layer_m = 0.5,
        .initial_cumulative_depth_m = 0.2,
    });
    try std.testing.expectEqual(
        @as(f64, 2),
        result.adjusted_water_table_depth_m,
    );
    try std.testing.expect(result.dynamic_water_table_depth_m == null);
}

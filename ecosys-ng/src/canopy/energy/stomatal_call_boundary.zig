// **A8a DISPOSITION: SUPERSEDED BY BOUND COUPLED OWNER.** CANOPY-TKC-001 is
// closed: `coupled_convergence.StomateFinalPass` carries the complete boundary,
// evaluates STOMATE at accepted TKC, resets RSMN, and performs the final solve.
//
// **HISTORICAL A8a DISPOSITION: GAP, blocked on CANOPY-TKC-001.** This is the UPTAKE.F
// 472--474 call boundary: `prepare` returns the complete UPTAKE-owned input
// snapshot that the separate STOMATE routine consumes, so that the caller cannot
// silently pass a partially assembled request across the routine boundary.
// A call boundary has no purpose without the caller on its near side. That caller
// is the canopy iteration of `canopy/energy/temperature_solver.zig`, which has no
// production caller (`CANOPY-TKC-001`, docs/discrepancy_register.md). Production
// reaches stomatal behaviour by a different route: the bound
// `canopy/energy/stomatal_resistance.zig` is invoked directly, without this
// snapshot type, so there is no bound consumer for a prepared request.
// This is not the same thing as the request being wrong. It encodes which inputs
// UPTAKE owns at the moment of the call, which is exactly the information needed
// to check that the production path passes the same set. Keeping it unbound
// preserves that reference; deleting it as unused would discard the only
// machine-checkable statement of the legacy interface.
// UPTAKE-RECONCILE-572-1863 group of
// docs/traceability/a7b_reconcile_canopy_iteration_cluster.md
const std = @import("std");

pub const Request = struct {
    species_index: usize,
    canopy_air_temperature_k: f64,
    canopy_vapor_concentration_m3_per_m3: f64,
};

pub const SnapshotState = struct {
    saved_canopy_air_temperature_k: []f64,
    saved_canopy_vapor_concentration_m3_per_m3: []f64,
};

/// UPTAKE.F 472--474 call boundary. The returned request is the complete
/// UPTAKE-owned input snapshot that precedes the separate STOMATE routine.
pub fn prepare(
    state: SnapshotState,
    species_index: usize,
    current_canopy_air_temperature_k: []const f64,
    current_canopy_vapor_concentration_m3_per_m3: []const f64,
) !Request {
    const species_count = state.saved_canopy_air_temperature_k.len;
    if (species_count == 0 or
        state.saved_canopy_vapor_concentration_m3_per_m3.len != species_count or
        current_canopy_air_temperature_k.len != species_count or
        current_canopy_vapor_concentration_m3_per_m3.len != species_count or
        species_index >= species_count)
        return error.InvalidCanopyStomatalBoundaryDimensions;
    const temperature_k = current_canopy_air_temperature_k[species_index];
    const vapor = current_canopy_vapor_concentration_m3_per_m3[species_index];
    if (!std.math.isFinite(temperature_k) or temperature_k <= 0 or
        !std.math.isFinite(vapor) or vapor < 0)
        return error.InvalidCanopyStomatalBoundaryInput;

    state.saved_canopy_air_temperature_k[species_index] = temperature_k;
    state.saved_canopy_vapor_concentration_m3_per_m3[species_index] = vapor;
    return .{
        .species_index = species_index,
        .canopy_air_temperature_k = temperature_k,
        .canopy_vapor_concentration_m3_per_m3 = vapor,
    };
}

test "UPTAKE snapshots selected runtime species before STOMATE call" {
    var saved_temperature = [_]f64{ 1, 2, 3 };
    var saved_vapor = [_]f64{ 4, 5, 6 };
    const request = try prepare(.{
        .saved_canopy_air_temperature_k = &saved_temperature,
        .saved_canopy_vapor_concentration_m3_per_m3 = &saved_vapor,
    }, 1, &.{ 280, 290, 300 }, &.{ 0.01, 0.02, 0.03 });
    try std.testing.expectEqual(@as(usize, 1), request.species_index);
    try std.testing.expectEqual(@as(f64, 290), request.canopy_air_temperature_k);
    try std.testing.expectEqual(@as(f64, 0.02), request.canopy_vapor_concentration_m3_per_m3);
    try std.testing.expectEqual([3]f64{ 1, 290, 3 }, saved_temperature);
    try std.testing.expectEqual([3]f64{ 4, 0.02, 6 }, saved_vapor);
}

test "invalid vapor leaves both saved canopy values unchanged" {
    var saved_temperature = [_]f64{280};
    var saved_vapor = [_]f64{0.01};
    try std.testing.expectError(
        error.InvalidCanopyStomatalBoundaryInput,
        prepare(.{
            .saved_canopy_air_temperature_k = &saved_temperature,
            .saved_canopy_vapor_concentration_m3_per_m3 = &saved_vapor,
        }, 0, &.{300}, &.{-0.1}),
    );
    try std.testing.expectEqual(@as(f64, 280), saved_temperature[0]);
    try std.testing.expectEqual(@as(f64, 0.01), saved_vapor[0]);
}

test "stomatal boundary rejects mismatched runtime species dimensions" {
    var saved_temperature = [_]f64{ 0, 0 };
    var saved_vapor = [_]f64{ 0, 0 };
    try std.testing.expectError(
        error.InvalidCanopyStomatalBoundaryDimensions,
        prepare(.{
            .saved_canopy_air_temperature_k = &saved_temperature,
            .saved_canopy_vapor_concentration_m3_per_m3 = &saved_vapor,
        }, 1, &.{300}, &.{0.01}),
    );
}

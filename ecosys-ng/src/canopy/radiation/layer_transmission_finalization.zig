// **A8a DISPOSITION: SUPERSEDED BY BOUND BURIAL-AWARE OWNER.** The current
// interception owner copies transmission through buried layers and is called
// through `refreshLayerTransmissionWithBurial` in production.
//
// **HISTORICAL A8a DISPOSITION: HOLD, not superseded. Do not bind; the blocking input
// does not exist.** This module is one member of a three-way additive cluster
// that binds together or not at all per `docs/agent_workflow.md` section 8a.
// The three cluster members are `canopy/radiation/top_down_layer_eligibility.zig`,
// `canopy/radiation/layer_transmission_finalization.zig` and
// `canopy/radiation/upward_scattering_traversal.zig`. Note that the
// pre-existing HOLD header below, preserved unchanged, names only two of the
// three: it lists `top_down_layer_eligibility` and `upward_scattering_traversal`
// and omits `layer_transmission_finalization`. That header is left as written
// rather than silently corrected, but the membership above is the accurate one,
// and `docs/traceability/canopy_radiation_unbound_family_disposition.md:64--65`
// lists all three. A fourth module, `submerged_upward_scatter_propagation.zig`,
// is the upward-sweep ELSE of the same predicate and carries its own banner.
//
// The blocker is unchanged at HEAD and was re-verified rather than repeated on
// the register's authority. Both HOUR1 sweeps open with the same two-part test
// on the layer's bottom boundary height, `IF(ZL(L-1).GE.DPTHS-ZERO .AND.
// ZL(L-1).GE.DPTH0-ZERO)`, descending at `hour1.f:1191--1193` and ascending at
// `hour1.f:1686--1688`. `DPTH0`, surface water-plus-ice ponding depth
// (`hour1.f:972`), has no producer anywhere in production: the only Zig
// occurrences of the name `surface_water_ice_depth_m` are the parameter
// declarations and test literals of unbound modules,
// `canopy/energy/interception_surface_accumulation.zig:39` with test values at
// `:226` and `:255`, plus `top_down_layer_eligibility.zig:39` and
// `upward_scattering_traversal.zig:44` here. No production site computes it.
//
// The production owner of this sweep is `canopy/energy/interception.zig`,
// dispatched from `src/stages/hourly_science_driver.zig:145`
// (`refreshLayerTransmission`, defined at `interception.zig:222`, which calls
// `calculateLayerTransmission` at `:440`), `:148`
// (`refreshAtmosphericLayerAbsorption`, `:232`) and `:154`
// (`applyGroundReflectedUpwardSweep`, `:354`). `interception.zig` has its first
// `test ` line at `:498`, so all four of those definitions are production code.
// It applies no burial gate: a case-insensitive search of that file for `height`
// and for `depth` returns zero hits, so the gate cannot be hiding under another
// name, and `calculateLayerTransmission` descends every layer unconditionally
// with no copy-through path.
//
// So this is not supersession. Production does not implement this behaviour by
// another route; it omits it, and a buried canopy layer still intercepts and
// attenuates shortwave and PAR as if in open air. Ottawa has a real winter
// snowpack, so the state is reached. Binding the cluster cannot fix that either,
// because the predicate's second operand does not exist yet. The cluster stays
// unbound under CANOPY-BURIAL-001, a `##` top-level heading at
// `docs/discrepancy_register.md:7220`, with the derivation in
// `docs/traceability/canopy_layer_burial_gate_is_absent.md`. Closing it means
// giving `DPTH0` a producer and adding the gate to the bound owner, not wiring
// these three in.
//
// Do not treat `canopy/energy/interception_surface_reset.zig` or
// `canopy/energy/interception_accumulator_initialization.zig` as the owner for
// this range; both are themselves unbound. `canopy/radiation/layer_distribution.zig`,
// `optics.zig`, `radiation.zig` and `exposure.zig` in this directory are bound,
// but none of them carries the burial predicate either.
// A8a phase 2, src/canopy/radiation directory sweep. Group B of docs/traceability/canopy_radiation_unbound_family_disposition.md
// UNBOUND, deliberately: this module is one member of an UNBOUND CLUSTER
// (`tools/check_additive_clusters.py`) together with
// `canopy/radiation/top_down_layer_eligibility.zig` and
// `canopy/radiation/upward_scattering_traversal.zig`. Per
// `docs/agent_workflow.md` section 8a Phase 1 the members bind together or
// not at all, and they cannot bind yet: the HOUR1 burial predicate needs
// surface water-plus-ice ponding depth `DPTH0` (`hour1.f:972`), which has no
// producer anywhere in production. The production owner of this sweep,
// `canopy/energy/interception.zig`, applies no burial gate at all and takes
// no height or depth argument of any kind. Filed as CANOPY-BURIAL-001; see
// docs/traceability/canopy_layer_burial_gate_is_absent.md.
const std = @import("std");

pub const LayerExposure = enum {
    exposed,
    submerged,
};

pub const AboveBoundary = struct {
    forward_scattered_shortwave_megajoules_per_m2_h: f64,
    forward_scattered_par_umol_per_m2_s: f64,
    direct_transmittance: f64,
    diffuse_transmittance: f64,
};

pub const LayerState = struct {
    accumulated_direct_interception_fraction: f64,
    accumulated_diffuse_interception_fraction: f64,
    forward_scattered_shortwave_megajoules_per_m2_h: f64,
    forward_scattered_par_umol_per_m2_s: f64,
    direct_transmittance: f64,
    direct_interception_fraction: f64,
    diffuse_transmittance: f64,
};

/// `hour1.f` lines 1579--1591. Finalizes an exposed layer or propagates the
/// boundary above through a submerged layer in exact source assignment order.
pub fn apply(
    exposure: LayerExposure,
    current_direct_interception_fraction: f64,
    current_diffuse_interception_fraction: f64,
    above: AboveBoundary,
    state: *LayerState,
) !void {
    try validate(
        exposure,
        current_direct_interception_fraction,
        current_diffuse_interception_fraction,
        above,
        state.*,
    );
    switch (exposure) {
        .exposed => {
            state.accumulated_direct_interception_fraction +=
                current_direct_interception_fraction;
            state.accumulated_diffuse_interception_fraction +=
                current_diffuse_interception_fraction;
            state.direct_transmittance =
                1.0 - state.accumulated_direct_interception_fraction;
            state.direct_interception_fraction =
                1.0 - state.direct_transmittance;
            state.diffuse_transmittance =
                1.0 - state.accumulated_diffuse_interception_fraction;
        },
        .submerged => {
            state.forward_scattered_shortwave_megajoules_per_m2_h =
                above.forward_scattered_shortwave_megajoules_per_m2_h;
            state.forward_scattered_par_umol_per_m2_s =
                above.forward_scattered_par_umol_per_m2_s;
            state.direct_transmittance = above.direct_transmittance;
            state.direct_interception_fraction =
                1.0 - state.direct_transmittance;
            state.diffuse_transmittance = above.diffuse_transmittance;
        },
    }
}

fn validate(
    exposure: LayerExposure,
    direct_delta: f64,
    diffuse_delta: f64,
    above: AboveBoundary,
    state: LayerState,
) !void {
    inline for (.{
        direct_delta,
        diffuse_delta,
        above.forward_scattered_shortwave_megajoules_per_m2_h,
        above.forward_scattered_par_umol_per_m2_s,
        above.direct_transmittance,
        above.diffuse_transmittance,
        state.accumulated_direct_interception_fraction,
        state.accumulated_diffuse_interception_fraction,
        state.forward_scattered_shortwave_megajoules_per_m2_h,
        state.forward_scattered_par_umol_per_m2_s,
        state.direct_transmittance,
        state.direct_interception_fraction,
        state.diffuse_transmittance,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidCanopyLayerTransmissionInput;
    if (above.direct_transmittance > 1 or above.diffuse_transmittance > 1)
        return error.InvalidCanopyLayerTransmissionInput;
    if (exposure == .exposed and
        (state.accumulated_direct_interception_fraction + direct_delta > 1 or
            state.accumulated_diffuse_interception_fraction +
                diffuse_delta > 1))
        return error.CanopyLayerInterceptionExceedsOne;
}

test "exposed layer finalizes accumulated interception in source order" {
    var state: LayerState = .{
        .accumulated_direct_interception_fraction = 0.2,
        .accumulated_diffuse_interception_fraction = 0.1,
        .forward_scattered_shortwave_megajoules_per_m2_h = 7,
        .forward_scattered_par_umol_per_m2_s = 8,
        .direct_transmittance = 9,
        .direct_interception_fraction = 10,
        .diffuse_transmittance = 11,
    };
    try apply(.exposed, 0.3, 0.4, .{
        .forward_scattered_shortwave_megajoules_per_m2_h = 1,
        .forward_scattered_par_umol_per_m2_s = 2,
        .direct_transmittance = 0.8,
        .diffuse_transmittance = 0.7,
    }, &state);
    try std.testing.expectEqual(@as(f64, 0.5), state.accumulated_direct_interception_fraction);
    try std.testing.expectEqual(@as(f64, 0.5), state.accumulated_diffuse_interception_fraction);
    try std.testing.expectEqual(@as(f64, 0.5), state.direct_transmittance);
    try std.testing.expectEqual(@as(f64, 0.5), state.direct_interception_fraction);
    try std.testing.expectEqual(@as(f64, 0.5), state.diffuse_transmittance);
    try std.testing.expectEqual(@as(f64, 7), state.forward_scattered_shortwave_megajoules_per_m2_h);
}

test "submerged layer inherits the boundary above" {
    var state: LayerState = .{
        .accumulated_direct_interception_fraction = 0.2,
        .accumulated_diffuse_interception_fraction = 0.3,
        .forward_scattered_shortwave_megajoules_per_m2_h = 7,
        .forward_scattered_par_umol_per_m2_s = 8,
        .direct_transmittance = 0.1,
        .direct_interception_fraction = 0.9,
        .diffuse_transmittance = 0.2,
    };
    try apply(.submerged, 0, 0, .{
        .forward_scattered_shortwave_megajoules_per_m2_h = 1,
        .forward_scattered_par_umol_per_m2_s = 2,
        .direct_transmittance = 0.8,
        .diffuse_transmittance = 0.7,
    }, &state);
    try std.testing.expectEqual(@as(f64, 1), state.forward_scattered_shortwave_megajoules_per_m2_h);
    try std.testing.expectEqual(@as(f64, 2), state.forward_scattered_par_umol_per_m2_s);
    try std.testing.expectEqual(@as(f64, 0.8), state.direct_transmittance);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), state.direct_interception_fraction, 1e-15);
    try std.testing.expectEqual(@as(f64, 0.7), state.diffuse_transmittance);
    try std.testing.expectEqual(@as(f64, 0.2), state.accumulated_direct_interception_fraction);
}

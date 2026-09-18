// **A8a DISPOSITION: SUPERSEDED BY BOUND BURIAL-AWARE OWNER.** `BurialInputs`
// now derives DPTH0 and the production `*WithBurial` upward sweep is called by
// `stages/hourly_process_driver.zig`; keep this granular kernel as an oracle.
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

pub const WorkingRadiation = struct {
    shortwave_megajoules_m2_h: f64,
    par_umol_m2_s: f64,
};

pub const Boundaries = struct {
    diffuse_transmittance: []f64,
    forward_scattered_shortwave_megajoules_m2_h: []f64,
    forward_scattered_par_umol_m2_s: []f64,
    backscattered_shortwave_megajoules_m2_h: []const f64,
    backscattered_par_umol_m2_s: []const f64,
};

/// `hour1.f` lines 1681--1685. Initializes bottom boundary index zero in exact
/// source assignment order.
pub fn initialize(working: *WorkingRadiation, boundaries: Boundaries) !void {
    try validateBoundaryDimensions(boundaries);
    working.shortwave_megajoules_m2_h = 0.0;
    working.par_umol_m2_s = 0.0;
    boundaries.diffuse_transmittance[0] = 1.0;
    boundaries.forward_scattered_shortwave_megajoules_m2_h[0] = 0.0;
    boundaries.forward_scattered_par_umol_m2_s[0] = 0.0;
}

/// `hour1.f` lines 1686--1692 for one zero-based layer in ascending traversal.
/// Returns false for a snow- or water-submerged layer.
pub fn admitLayer(
    layer: usize,
    layer_bottom_height_m: []const f64,
    snow_depth_m: f64,
    surface_water_ice_depth_m: f64,
    depth_tolerance_m: f64,
    working: *WorkingRadiation,
    boundaries: Boundaries,
) !bool {
    try validateLayer(
        layer,
        layer_bottom_height_m,
        snow_depth_m,
        surface_water_ice_depth_m,
        depth_tolerance_m,
        working.*,
        boundaries,
    );
    if (layer_bottom_height_m[layer] < snow_depth_m - depth_tolerance_m or
        layer_bottom_height_m[layer] <
            surface_water_ice_depth_m - depth_tolerance_m)
        return false;
    const below_boundary = layer;
    const current_boundary = layer + 1;
    working.shortwave_megajoules_m2_h =
        working.shortwave_megajoules_m2_h *
        boundaries.diffuse_transmittance[below_boundary] +
        boundaries.forward_scattered_shortwave_megajoules_m2_h[below_boundary] +
        boundaries.backscattered_shortwave_megajoules_m2_h[below_boundary];
    working.par_umol_m2_s =
        working.par_umol_m2_s *
        boundaries.diffuse_transmittance[below_boundary] +
        boundaries.forward_scattered_par_umol_m2_s[below_boundary] +
        boundaries.backscattered_par_umol_m2_s[below_boundary];
    boundaries.forward_scattered_shortwave_megajoules_m2_h[current_boundary] = 0.0;
    boundaries.forward_scattered_par_umol_m2_s[current_boundary] = 0.0;
    return true;
}

fn validateBoundaryDimensions(boundaries: Boundaries) !void {
    const boundary_count = boundaries.diffuse_transmittance.len;
    if (boundary_count < 2 or
        boundaries.forward_scattered_shortwave_megajoules_m2_h.len != boundary_count or
        boundaries.forward_scattered_par_umol_m2_s.len != boundary_count or
        boundaries.backscattered_shortwave_megajoules_m2_h.len != boundary_count or
        boundaries.backscattered_par_umol_m2_s.len != boundary_count)
        return error.CanopyUpwardBoundaryDimensionMismatch;
}

fn validateLayer(
    layer: usize,
    heights: []const f64,
    snow_depth_m: f64,
    water_ice_depth_m: f64,
    tolerance_m: f64,
    working: WorkingRadiation,
    boundaries: Boundaries,
) !void {
    try validateBoundaryDimensions(boundaries);
    if (heights.len + 1 != boundaries.diffuse_transmittance.len or
        layer >= heights.len)
        return error.CanopyUpwardLayerOutOfRange;
    inline for (.{
        snow_depth_m,
        water_ice_depth_m,
        tolerance_m,
        working.shortwave_megajoules_m2_h,
        working.par_umol_m2_s,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidCanopyUpwardTraversalInput;
    for (heights) |value| if (!std.math.isFinite(value))
        return error.InvalidCanopyUpwardTraversalInput;
    inline for (.{
        boundaries.diffuse_transmittance,
        boundaries.forward_scattered_shortwave_megajoules_m2_h,
        boundaries.forward_scattered_par_umol_m2_s,
        boundaries.backscattered_shortwave_megajoules_m2_h,
        boundaries.backscattered_par_umol_m2_s,
    }) |values| for (values) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidCanopyUpwardTraversalInput;
}

test "initialization then exposed layer advances upward scattered radiation" {
    var transmission = [_]f64{ 9, 0.8, 0.7 };
    var forward_sw = [_]f64{ 9, 5, 6 };
    var forward_par = [_]f64{ 8, 7, 6 };
    const back_sw = [_]f64{ 2, 3, 4 };
    const back_par = [_]f64{ 20, 30, 40 };
    var working: WorkingRadiation = .{
        .shortwave_megajoules_m2_h = 99,
        .par_umol_m2_s = 98,
    };
    const boundaries: Boundaries = .{
        .diffuse_transmittance = &transmission,
        .forward_scattered_shortwave_megajoules_m2_h = &forward_sw,
        .forward_scattered_par_umol_m2_s = &forward_par,
        .backscattered_shortwave_megajoules_m2_h = &back_sw,
        .backscattered_par_umol_m2_s = &back_par,
    };
    try initialize(&working, boundaries);
    try std.testing.expectEqual(@as(f64, 0), working.shortwave_megajoules_m2_h);
    try std.testing.expectEqual(@as(f64, 1), transmission[0]);
    try std.testing.expect(try admitLayer(
        0,
        &.{ 1, 2 },
        0,
        0,
        0,
        &working,
        boundaries,
    ));
    try std.testing.expectEqual(@as(f64, 2), working.shortwave_megajoules_m2_h);
    try std.testing.expectEqual(@as(f64, 20), working.par_umol_m2_s);
    try std.testing.expectEqual(@as(f64, 0), forward_sw[1]);
    try std.testing.expectEqual(@as(f64, 0), forward_par[1]);
}

test "submerged layer leaves traversal state unchanged" {
    var transmission = [_]f64{ 1, 0.8 };
    var forward_sw = [_]f64{ 1, 2 };
    var forward_par = [_]f64{ 3, 4 };
    const back_sw = [_]f64{ 5, 6 };
    const back_par = [_]f64{ 7, 8 };
    var working: WorkingRadiation = .{
        .shortwave_megajoules_m2_h = 9,
        .par_umol_m2_s = 10,
    };
    try std.testing.expect(!(try admitLayer(0, &.{0}, 1, 0, 0.1, &working, .{
        .diffuse_transmittance = &transmission,
        .forward_scattered_shortwave_megajoules_m2_h = &forward_sw,
        .forward_scattered_par_umol_m2_s = &forward_par,
        .backscattered_shortwave_megajoules_m2_h = &back_sw,
        .backscattered_par_umol_m2_s = &back_par,
    })));
    try std.testing.expectEqual(@as(f64, 9), working.shortwave_megajoules_m2_h);
    try std.testing.expectEqual(@as(f64, 2), forward_sw[1]);
}

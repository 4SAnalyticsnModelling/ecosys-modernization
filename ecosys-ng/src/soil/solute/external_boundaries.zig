const std = @import("std");
const solute = @import("transport.zig");

pub const Boundary = struct {
    cell_index: usize,
    /// Positive leaves the modeled domain; negative recharges from outside.
    outward_water_flux_m3_per_step: f64,
};

/// Calculates the TRNSFRS external micropore/macropore convection rule in a
/// direction-independent form. Positive output is a gain by the model.
///
/// `apply_donor_content_ceiling` reproduces the macropore-only asymmetry in
/// the Fortran oracle: the micropore boundary (`trnsfrs.f:7825-7892`)
/// recharges unconditionally at `FLWM*C_boundary`, but the macropore boundary
/// (`trnsfrs.f:8161-8163,8263-8265`) caps that convective recharge term at
/// the donor-content-based, `VFLWX`-bounded rate (`AMAX1`/`AMIN1` against
/// `VFLW*donor_content`), whichever has the smaller magnitude. Callers must
/// pass `false` for micropore boundaries and `true` for macropore boundaries.
///
/// Deliberately does not reproduce a separate legacy defect: `trnsfrs.f`'s
/// macropore boundary discharge branch (`:8092`) covers only `NN.EQ.1`
/// (missing the `NN.EQ.2`/`FLWHM.LT.0.0` mirror present in both the
/// micropore section above it and the sibling gas file `trnsfr.f:6500-6501`
/// at the identical location), and its two recharge branches gate on
/// `FLWM` instead of `FLWHM`. This function classifies discharge vs.
/// recharge purely by the sign of `outward_water_flux_m3_per_step`, so every
/// macropore boundary face is always resolved by its own flux's sign
/// regardless of orientation. See
/// `audit/issues/issue-042-trnsfrs-macropore-boundary-flux-branch-structure-diverges-from-sibling.md`.
/// Do not add an `NN`-style orientation parameter to "restore" this asymmetry.
pub fn calculateNetFluxMol(state: *const solute.State, boundary: Boundary, maximum_transport_fraction: f64, discharge_mobility_fraction: []const f64, recharge_concentration_mol_per_m3: []const f64, output_net_flux_mol: []f64, apply_donor_content_ceiling: bool) !void {
    if (boundary.cell_index >= state.cell_count) return error.SoluteBoundaryCellIndexOutOfBounds;
    if (discharge_mobility_fraction.len != state.species_count or recharge_concentration_mol_per_m3.len != state.species_count or output_net_flux_mol.len != state.species_count) return error.TransportSpeciesCountMismatch;
    if (!std.math.isFinite(boundary.outward_water_flux_m3_per_step) or !std.math.isFinite(maximum_transport_fraction) or maximum_transport_fraction < 0 or maximum_transport_fraction > 1) return error.InvalidSoluteBoundaryInput;
    const water = state.water_volume_m3[boundary.cell_index];
    if (!std.math.isFinite(water) or water < 0) return error.InvalidSoluteBoundaryInput;
    const amounts = try state.cellAmountsConst(boundary.cell_index);
    if (boundary.outward_water_flux_m3_per_step > 0) {
        const fraction = if (water > 0) @min(maximum_transport_fraction, boundary.outward_water_flux_m3_per_step / water) else 0;
        for (amounts, discharge_mobility_fraction, recharge_concentration_mol_per_m3, output_net_flux_mol) |amount, mobility, concentration, *net| {
            try validateSpeciesInput(amount, mobility, concentration);
            net.* = -amount * mobility * fraction;
        }
    } else if (boundary.outward_water_flux_m3_per_step < 0) {
        // VFLW = clamp(-VFLWX, VFLWX, outward_flux / water); the donor-content
        // ceiling magnitude is |VFLW| * donor_amount * mobility.
        const donor_fraction = if (water > 0) @min(maximum_transport_fraction, -boundary.outward_water_flux_m3_per_step / water) else 0;
        for (amounts, discharge_mobility_fraction, recharge_concentration_mol_per_m3, output_net_flux_mol) |amount, mobility, concentration, *net| {
            try validateSpeciesInput(amount, mobility, concentration);
            const boundary_term = -boundary.outward_water_flux_m3_per_step * concentration * mobility;
            if (apply_donor_content_ceiling) {
                const donor_term = amount * mobility * donor_fraction;
                net.* = @min(boundary_term, donor_term);
            } else {
                net.* = boundary_term;
            }
            if (!std.math.isFinite(net.*)) return error.NonFiniteSoluteBoundaryFlux;
        }
    } else {
        @memset(output_net_flux_mol, 0);
    }
}

/// Sums all external faces before validating and state_updateting, preventing one
/// failed face from leaving a partial boundary update.
pub fn state_updateNetFluxes(allocator: std.mem.Allocator, state: *solute.State, boundaries: []const Boundary, boundary_net_flux_mol: []const f64) !void {
    if (boundary_net_flux_mol.len != try std.math.mul(usize, boundaries.len, state.species_count)) return error.SoluteBoundaryFluxSizeMismatch;
    const net = try allocator.alloc(f64, state.amount_mol.len);
    defer allocator.free(net);
    @memset(net, 0);
    for (boundaries, 0..) |boundary, boundary_index| {
        if (boundary.cell_index >= state.cell_count) return error.SoluteBoundaryCellIndexOutOfBounds;
        for (0..state.species_count) |species| {
            const value = boundary_net_flux_mol[boundary_index * state.species_count + species];
            if (!std.math.isFinite(value)) return error.NonFiniteSoluteBoundaryFlux;
            net[boundary.cell_index * state.species_count + species] += value;
        }
    }
    for (state.amount_mol, net) |amount, change| if (!std.math.isFinite(amount + change) or amount + change < 0) return error.NegativeSoluteBoundaryCandidate;
    for (state.amount_mol, net) |*amount, change| amount.* += change;
}

pub fn state_updateCellNetFlux(state: *solute.State, cell_index: usize, net_flux_mol: []const f64) !void {
    if (cell_index >= state.cell_count) return error.SoluteBoundaryCellIndexOutOfBounds;
    if (net_flux_mol.len != state.species_count) return error.TransportSpeciesCountMismatch;
    const amounts = try state.cellAmounts(cell_index);
    for (amounts, net_flux_mol) |amount, change| if (!std.math.isFinite(change) or !std.math.isFinite(amount + change) or amount + change < 0) return error.NegativeSoluteBoundaryCandidate;
    for (amounts, net_flux_mol) |*amount, change| amount.* += change;
}

fn validateSpeciesInput(amount: f64, mobility: f64, concentration: f64) !void {
    if (!std.math.isFinite(amount) or amount < 0 or !std.math.isFinite(mobility) or mobility < 0 or mobility > 1 or !std.math.isFinite(concentration) or concentration < 0) return error.InvalidSoluteBoundaryInput;
}

test "external discharge uses donor inventory and VFLWX ceiling" {
    var state = try solute.State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    state.water_volume_m3[0] = 2;
    @memcpy(try state.cellAmounts(0), &[_]f64{ 4, 6, 8 });
    var net: [3]f64 = undefined;
    try calculateNetFluxMol(&state, .{ .cell_index = 0, .outward_water_flux_m3_per_step = 10 }, 0.25, &[_]f64{ 1, 0.5, 0 }, &[_]f64{ 0, 0, 0 }, &net, false);
    try std.testing.expectEqualSlices(f64, &[_]f64{ -1, -0.75, 0 }, &net);
}

test "external recharge uses prescribed concentration and mobility" {
    var state = try solute.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    var net: [2]f64 = undefined;
    try calculateNetFluxMol(&state, .{ .cell_index = 0, .outward_water_flux_m3_per_step = -2 }, 0.5, &[_]f64{ 0.75, 0.25 }, &[_]f64{ 3, 4 }, &net, false);
    try std.testing.expectEqualSlices(f64, &[_]f64{ 4.5, 2 }, &net);
}

test "macropore recharge is capped by the donor-content VFLWX ceiling" {
    // Fortran oracle: trnsfrs.f:8161-8163 (AMAX1 branch) caps the macropore
    // recharge convective term at the smaller of the boundary-concentration
    // term and the VFLW*donor_content term. Here the boundary concentration
    // is large but the donor macropore content is small, so the donor-content
    // ceiling (0.5 water content * min(fraction=0.5, 2/4=0.5) * 1 mobility =
    // 1) must win over the raw boundary term (2 * 3 * 1 = 6).
    var state = try solute.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.water_volume_m3[0] = 4;
    @memcpy(try state.cellAmounts(0), &[_]f64{2});
    var net: [1]f64 = undefined;
    try calculateNetFluxMol(&state, .{ .cell_index = 0, .outward_water_flux_m3_per_step = -2 }, 0.5, &[_]f64{1}, &[_]f64{3}, &net, true);
    try std.testing.expectEqualSlices(f64, &[_]f64{1}, &net);
}

test "macropore recharge keeps the boundary term when it is the smaller magnitude" {
    var state = try solute.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.water_volume_m3[0] = 4;
    @memcpy(try state.cellAmounts(0), &[_]f64{100});
    var net: [1]f64 = undefined;
    try calculateNetFluxMol(&state, .{ .cell_index = 0, .outward_water_flux_m3_per_step = -2 }, 0.5, &[_]f64{1}, &[_]f64{3}, &net, true);
    try std.testing.expectEqualSlices(f64, &[_]f64{6}, &net);
}

test "multiple external faces state_update atomically" {
    var state = try solute.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.amount_mol[0] = 2;
    const boundaries = [_]Boundary{ .{ .cell_index = 0, .outward_water_flux_m3_per_step = 1 }, .{ .cell_index = 0, .outward_water_flux_m3_per_step = 1 } };
    try state_updateNetFluxes(std.testing.allocator, &state, &boundaries, &[_]f64{ -0.5, -0.5 });
    try std.testing.expectEqual(@as(f64, 1), state.amount_mol[0]);
    try std.testing.expectError(error.NegativeSoluteBoundaryCandidate, state_updateNetFluxes(std.testing.allocator, &state, &boundaries, &[_]f64{ -1, -1 }));
    try std.testing.expectEqual(@as(f64, 1), state.amount_mol[0]);
}

test "external state_update rejects a sub-tolerance overdraw without clipping" {
    var state = try solute.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.amount_mol[0] = 1;
    try std.testing.expectError(
        error.NegativeSoluteBoundaryCandidate,
        state_updateCellNetFlux(&state, 0, &.{-(1.0 + 1.0e-15)}),
    );
    try std.testing.expectEqual(@as(f64, 1), state.amount_mol[0]);
}

//! `coupled_gas_solver` declarations: residual.
//!
//! Split out of `coupled_gas_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const gas = @import("transport.zig");
const atmosphere = @import("atmosphere_exchange.zig");
const numerics = @import("../../core/numerics.zig");
const group_misc = @import("coupled_gas_solver_misc.zig");

const PhaseAllocation = struct {
    gas_remaining_g: f64,
    nonband_flux_g: f64,
    band_flux_g: f64,
};

/// Applies the two NH3-zone (or single-zone generic-gas) requests against one
/// gaseous donor. Aqueous releases are made available first. Positive requests
/// then share only that exact available inventory, with the final positive
/// zone assigned as a remainder so independently rounded products cannot
/// overdraw the donor. This is flux construction, not post-state clipping.
fn allocatePhaseExchange(
    gas_available_g: f64,
    requested_nonband_g: f64,
    requested_band_g: f64,
) !PhaseAllocation {
    inline for (.{ gas_available_g, requested_nonband_g, requested_band_g }) |value|
        if (!std.math.isFinite(value)) return error.InvalidCoupledGasCandidate;
    if (gas_available_g < 0) return error.InvalidCoupledGasCandidate;

    const released_nonband_g = @min(0, requested_nonband_g);
    const released_band_g = @min(0, requested_band_g);
    const released_total_g = -(released_nonband_g + released_band_g);
    const gas_after_release_g = gas_available_g + released_total_g;
    if (!std.math.isFinite(gas_after_release_g) or gas_after_release_g < 0)
        return error.InvalidCoupledGasCandidate;

    const positive_nonband_g = @max(0, requested_nonband_g);
    const positive_band_g = @max(0, requested_band_g);
    const positive_total_g = positive_nonband_g + positive_band_g;
    if (!std.math.isFinite(positive_total_g)) return error.InvalidCoupledGasCandidate;
    const accepted_positive_g = @min(gas_after_release_g, positive_total_g);

    var accepted_nonband_positive_g: f64 = 0;
    var accepted_band_positive_g: f64 = 0;
    if (accepted_positive_g > 0 and positive_total_g > 0) {
        if (positive_nonband_g == 0) {
            accepted_band_positive_g = accepted_positive_g;
        } else if (positive_band_g == 0) {
            accepted_nonband_positive_g = accepted_positive_g;
        } else if (positive_nonband_g <= positive_band_g) {
            accepted_nonband_positive_g = @min(
                accepted_positive_g,
                accepted_positive_g * positive_nonband_g / positive_total_g,
            );
            accepted_band_positive_g = accepted_positive_g - accepted_nonband_positive_g;
        } else {
            accepted_band_positive_g = @min(
                accepted_positive_g,
                accepted_positive_g * positive_band_g / positive_total_g,
            );
            accepted_nonband_positive_g = accepted_positive_g - accepted_band_positive_g;
        }
    }

    const gas_remaining_g = gas_after_release_g - accepted_positive_g;
    if (!std.math.isFinite(gas_remaining_g) or gas_remaining_g < 0)
        return error.InvalidCoupledGasCandidate;
    return .{
        .gas_remaining_g = gas_remaining_g,
        .nonband_flux_g = released_nonband_g + accepted_nonband_positive_g,
        .band_flux_g = released_band_g + accepted_band_positive_g,
    };
}

/// Each side's own area-scaled legacy `ZEROS2`, in the face's `[first, second]`
/// order. `trnsfr.f:5305-5306` compares each cell against `ZEROS2` for its own
/// horizontal cell, so the two are never collapsed into one scalar.
pub fn faceCarrierMinimumM3(inputs: group_misc.Inputs, face: gas.Face) [2]f64 {
    return .{
        group_misc.minimumCarrierVolumeM3(inputs, face.first_cell),
        group_misc.minimumCarrierVolumeM3(inputs, face.second_cell),
    };
}

/// The complete `trnsfr.f:5303-5306` admission test that this module owns: a
/// gaseous face exists only when both cells hold a resolvable air volume.
/// `face_assembly.zig` has already applied the `THETPM > THETX` half at
/// construction; this is the `VOLPM > ZEROS2` half, which the dimensionless
/// test does not imply for a thin layer.
pub fn gaseousFace(
    scratch: *const gas.State,
    inputs: group_misc.Inputs,
    face: gas.Face,
) bool {
    const minimum = faceCarrierMinimumM3(inputs, face);
    return scratch.air_volume_m3[face.first_cell] > minimum[0] and
        scratch.air_volume_m3[face.second_cell] > minimum[1];
}

pub fn residualAt(allocator: std.mem.Allocator, scratch: *gas.State, base: []const f64, trial: []const f64, inputs: group_misc.Inputs, transport_iteration_fraction: f64, target: []f64, residual: []f64) !void {
    return residualAtCapturing(allocator, scratch, base, trial, inputs, transport_iteration_fraction, target, residual, false);
}

pub fn capturesFluxLedgers(inputs: group_misc.Inputs) bool {
    return inputs.atmospheric_flux_g_by_component != null or
        inputs.subsurface_flux_g_by_component != null or
        inputs.face_flux_g_by_component != null or
        inputs.bubble_transfer_g_by_component != null;
}

pub fn residualAtCapturing(allocator: std.mem.Allocator, scratch: *gas.State, base: []const f64, trial: []const f64, inputs: group_misc.Inputs, transport_iteration_fraction: f64, target: []f64, residual: []f64, capture_boundaries: bool) !void {
    // The solve entry point has already validated all invariant geometry and
    // parameters. Validate the changing iterate once here, then use kernels
    // that do not rescan the same seven-species slices at every face, boundary,
    // phase exchange, and bubbling evaluation.
    for (trial) |value| {
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidCoupledGasCandidate;
    }
    copyVectorToState(trial, scratch);
    @memcpy(target, base);
    const n = scratch.gaseous_mass_g.len;
    const gas_target = target[0..n];
    const dissolved_target = target[n .. 2 * n];
    const band_target = target[2 * n .. 3 * n];
    // Reuse the output-residual workspace until the final subtraction below.
    // TRNSFR evaluates gas boundaries before air-water exchange in each NPG
    // subcycle, then the next subcycle may export gas released by the previous
    // one.  This full-step fixed-base map has no later subcycle image, so retain
    // any donor-limited gas outflow request and offer its remainder once more
    // after air-water exchange and bubbling have released gas. Keeping the two
    // boundary classes separate preserves their accepted ledgers exactly.
    const pending_atmospheric_outflow_g = residual[0..n];
    const pending_subsurface_outflow_g = residual[n .. 2 * n];
    @memset(pending_atmospheric_outflow_g, 0);
    @memset(pending_subsurface_outflow_g, 0);
    if (capture_boundaries) {
        if (inputs.atmospheric_flux_g_by_component) |fluxes| {
            if (fluxes.len != n) return error.GasBoundaryFluxSizeMismatch;
            @memset(fluxes, 0);
        }
        if (inputs.subsurface_flux_g_by_component) |subsurface_fluxes| {
            if (subsurface_fluxes.len != n) return error.GasBoundaryFluxSizeMismatch;
            @memset(subsurface_fluxes, 0);
        }
        if (inputs.face_flux_g_by_component) |face_fluxes| {
            if (face_fluxes.len !=
                inputs.faces.len * gas.species_count)
                return error.GasFaceFluxSizeMismatch;
            @memset(face_fluxes, 0);
        }
        if (inputs.bubble_transfer_g_by_component) |bubble_transfers| {
            if (bubble_transfers.len != n)
                return error.GasBubbleFluxSizeMismatch;
            @memset(bubble_transfers, 0);
        }
    }
    var diffusion: [gas.species_count]f64 = undefined;
    var pressure: [gas.species_count]f64 = undefined;
    // TRNSFR pressure displacement is a sequential donor-bounded inventory
    // correction, not a constitutive equilibrium. Assemble it explicitly from
    // the conservative target before solving the differentiable diffusion and
    // phase-exchange terms.
    for (inputs.faces, 0..) |face, face_index| {
        // A fully water-filled cell has no gaseous control volume. A face
        // transfer into it is not an active gas transport path: accepting it
        // creates a positive gaseous target at a zero-capacity coordinate,
        // where no nonnegative coupled root exists. Skipping the entire
        // face preserves the equal-and-opposite internal ledger pairing.
        //
        // "No gaseous control volume" is the legacy `VOLPM > ZEROS2` test of
        // `trnsfr.f:5303-5306`, not a bare positivity test: the source
        // performs no gaseous transport -- diffusive or convective -- across
        // a face whose air volume is at or below the area-scaled minimum, and
        // it has no `ELSE` branch there. The reasoning in the paragraph above
        // applies at exactly the same strength to an unresolvable volume as
        // to a zero one; only the threshold was missing.
        if (!gaseousFace(scratch, inputs, face)) continue;
        const first_target = gas_target[face.first_cell * gas.species_count ..][0..gas.species_count];
        const second_target = gas_target[face.second_cell * gas.species_count ..][0..gas.species_count];
        try gas.adjacentPressureDrivenFluxesGFromValidatedInputs(first_target, second_target, scratch.air_volume_m3[face.second_cell], scratch.temperature_k[face.second_cell], scratch.water_vapor_mol[face.second_cell], transport_iteration_fraction, &pressure);
        for (pressure, 0..) |convective, species| {
            const first_index = face.first_cell * gas.species_count + species;
            const second_index = face.second_cell * gas.species_count + species;
            const bounded = std.math.clamp(convective, -gas_target[second_index], gas_target[first_index]);
            gas_target[first_index] -= bounded;
            gas_target[second_index] += bounded;
            if (capture_boundaries) {
                if (inputs.face_flux_g_by_component) |fluxes|
                    fluxes[face_index * gas.species_count + species] += bounded;
            }
        }
    }
    for (inputs.faces, 0..) |face, face_index| {
        if (!gaseousFace(scratch, inputs, face)) continue;
        const face_conductance = inputs.face_conductance_m3_per_step[face_index * gas.species_count ..][0..gas.species_count];
        var iteration_conductance_m3: [gas.species_count]f64 = undefined;
        for (face_conductance, 0..) |conductance_m3, species| {
            iteration_conductance_m3[species] = conductance_m3 * transport_iteration_fraction;
        }
        try gas.calculateFaceDiffusiveFluxesGFromValidatedInputs(
            scratch,
            face,
            &iteration_conductance_m3,
            faceCarrierMinimumM3(inputs, face),
            &diffusion,
        );
        for (diffusion, 0..) |diffusive, species| {
            const first_index = face.first_cell * gas.species_count + species;
            const second_index = face.second_cell * gas.species_count + species;
            const bounded = std.math.clamp(diffusive, -gas_target[second_index], gas_target[first_index]);
            gas_target[first_index] -= bounded;
            gas_target[second_index] += bounded;
            if (capture_boundaries) {
                if (inputs.face_flux_g_by_component) |fluxes|
                    fluxes[face_index * gas.species_count + species] += bounded;
            }
        }
    }
    var boundary_flux: [gas.species_count]f64 = undefined;
    for (inputs.atmospheric_boundaries) |boundary| {
        try atmosphere.calculateFluxesGFromValidatedInputs(scratch, boundary, transport_iteration_fraction, &boundary_flux);
        for (boundary_flux, 0..) |flux, species| {
            const index = boundary.cell_index * gas.species_count + species;
            const accepted = @max(-gas_target[index], flux);
            gas_target[index] += accepted;
            if (flux < accepted)
                pending_atmospheric_outflow_g[index] += flux - accepted;
            if (capture_boundaries) {
                if (inputs.atmospheric_flux_g_by_component) |fluxes| fluxes[index] += accepted;
            }
        }
    }
    var cached_subsurface_boundary: ?atmosphere.Boundary = null;
    var cached_subsurface_flux: [gas.species_count]f64 = undefined;
    for (inputs.subsurface_boundaries) |boundary| {
        if (cached_subsurface_boundary) |cached| {
            if (std.meta.eql(cached, boundary)) {
                boundary_flux = cached_subsurface_flux;
            } else {
                try atmosphere.calculateFluxesGFromValidatedInputs(scratch, boundary, transport_iteration_fraction, &boundary_flux);
                cached_subsurface_boundary = boundary;
                cached_subsurface_flux = boundary_flux;
            }
        } else {
            try atmosphere.calculateFluxesGFromValidatedInputs(scratch, boundary, transport_iteration_fraction, &boundary_flux);
            cached_subsurface_boundary = boundary;
            cached_subsurface_flux = boundary_flux;
        }
        for (boundary_flux, 0..) |flux, species| {
            const index = boundary.cell_index * gas.species_count + species;
            const accepted = @max(-gas_target[index], flux);
            gas_target[index] += accepted;
            if (flux < accepted)
                pending_subsurface_outflow_g[index] += flux - accepted;
            if (capture_boundaries) {
                if (inputs.subsurface_flux_g_by_component) |fluxes| fluxes[index] += accepted;
            }
        }
    }
    var bubble: [gas.species_count]f64 = undefined;
    var band_bubble: [gas.species_count]f64 = undefined;
    for (0..scratch.cell_count) |cell| {
        const start = cell * gas.species_count;
        const solubility = inputs.mass_solubility_ratio[start..][0..gas.species_count];
        const nonband_air_volume_m3 = if (inputs.nonband_air_volume_m3.len == 0)
            scratch.air_volume_m3[cell]
        else
            inputs.nonband_air_volume_m3[cell];
        const band_air_volume_m3 = if (inputs.band_air_volume_m3.len == 0)
            scratch.air_volume_m3[cell]
        else
            inputs.band_air_volume_m3[cell];
        for (0..gas.species_count) |species| {
            const index = start + species;
            const is_ammonia = species == @intFromEnum(gas.Species.ammonia);
            const primary_air_volume_m3 = if (is_ammonia) nonband_air_volume_m3 else scratch.air_volume_m3[cell];
            const primary_water_volume_m3 = if (is_ammonia)
                inputs.water_volume_m3[cell] - inputs.band_water_volume_m3[cell]
            else
                inputs.water_volume_m3[cell];
            // Phase exchange target uses base dissolved (dissolved_target before this loop
            // body modifies it) as the Picard departure point so that the fixed-point
            // equation is target_d = base_d + rate*(D_eq - base_d), which converges to
            // D_eq for rate=1.  Using trial dissolved instead gives a fixed point of
            // (base_d + rate*D_eq)/(1+rate) = D_eq/2 when base_d=0, causing oscillation.
            // ZNH3S/ZNH3B both exchange against the same pre-exchange ZNH3G2
            // (`trnsfr.f:5561-5584`). Do not make the band equation depend on
            // a sequentially depleted gas pool. Bound the combined donor only
            // after both zone requests have been evaluated.
            const requested_phase = try gas.phaseExchangeFluxGFromValidatedInputs(scratch.gaseous_mass_g[index], dissolved_target[index], primary_air_volume_m3, primary_water_volume_m3, solubility[species], inputs.gas_water_exchange_rate_per_step[index]);
            const phase = @max(requested_phase, -dissolved_target[index]);
            const requested_band_phase = try gas.phaseExchangeFluxGFromValidatedInputs(scratch.gaseous_mass_g[index], band_target[index], band_air_volume_m3, inputs.band_water_volume_m3[cell], solubility[species], inputs.band_gas_water_exchange_rate_per_step[index]);
            const band_phase = @max(requested_band_phase, -band_target[index]);
            const accepted = try allocatePhaseExchange(gas_target[index], phase, band_phase);
            gas_target[index] = accepted.gas_remaining_g;
            dissolved_target[index] += accepted.nonband_flux_g;
            band_target[index] += accepted.band_flux_g;
        }
        if (inputs.bubbling_enabled[cell]) {
            // `trnsfr.f:5777-5778`/`5880-5889`: no bubbling at all below the
            // minimum aqueous carrier. The band zone carries the same floor
            // because the source uses one `ZEROS2` per horizontal cell.
            const minimum_carrier_volume_m3 = group_misc.minimumCarrierVolumeM3(inputs, cell);
            try gas.bubblingFluxesGFromValidatedInputs(inputs.water_volume_m3[cell], minimum_carrier_volume_m3, scratch.temperature_k[cell], scratch.dissolved_mass_g[start..][0..gas.species_count], solubility, transport_iteration_fraction, &bubble);
            try gas.bubblingFluxesGFromValidatedInputs(inputs.band_water_volume_m3[cell], minimum_carrier_volume_m3, scratch.temperature_k[cell], scratch.band_dissolved_mass_g[start..][0..gas.species_count], solubility, transport_iteration_fraction, &band_bubble);
            for (bubble, band_bubble, 0..) |nonband, band, species| {
                const accepted_nonband = @max(-dissolved_target[start + species], nonband);
                const accepted_band = @max(-band_target[start + species], band);
                dissolved_target[start + species] += accepted_nonband;
                band_target[start + species] += accepted_band;
                const released_g = -(accepted_nonband + accepted_band);
                if (released_g == 0) continue;
                const receiver = if (inputs.bubble_receiver_cell_by_cell) |receivers|
                    receivers[cell]
                else
                    cell;
                if (receiver) |receiver_cell| {
                    gas_target[receiver_cell * gas.species_count + species] += released_g;
                    if (capture_boundaries and receiver_cell != cell) {
                        if (inputs.bubble_transfer_g_by_component) |transfers|
                            transfers[start + species] += released_g;
                    }
                } else if (capture_boundaries) {
                    // REDIST LG=0 adds escaping bubbles to CIB/CHB/etc.,
                    // hence HCO2G/UCO2G and atmospheric exchange. They are
                    // not profile drainage, which also enters the NBP loss.
                    if (inputs.atmospheric_flux_g_by_component) |fluxes|
                        fluxes[start + species] -= released_g;
                }
            }
        }
    }
    for (0..n) |index| {
        const atmospheric_remainder = @max(
            -gas_target[index],
            pending_atmospheric_outflow_g[index],
        );
        gas_target[index] += atmospheric_remainder;
        if (capture_boundaries and atmospheric_remainder != 0) {
            if (inputs.atmospheric_flux_g_by_component) |fluxes| {
                fluxes[index] += atmospheric_remainder;
            }
        }

        const subsurface_remainder = @max(
            -gas_target[index],
            pending_subsurface_outflow_g[index],
        );
        gas_target[index] += subsurface_remainder;
        if (capture_boundaries and subsurface_remainder != 0) {
            if (inputs.subsurface_flux_g_by_component) |fluxes| {
                fluxes[index] += subsurface_remainder;
            }
        }
    }
    _ = allocator;
    for (target, trial, residual) |fixed_point, value, *difference| {
        if (!std.math.isFinite(fixed_point) or fixed_point < 0) return error.InvalidCoupledGasCandidate;
        difference.* = fixed_point - value;
    }
}

pub fn copyStateToVector(state: *const gas.State, vector: []f64) void {
    const n = state.gaseous_mass_g.len;
    @memcpy(vector[0..n], state.gaseous_mass_g);
    @memcpy(vector[n .. 2 * n], state.dissolved_mass_g);
    @memcpy(vector[2 * n .. 3 * n], state.band_dissolved_mass_g);
}

pub fn copyVectorToState(vector: []const f64, state: *gas.State) void {
    const n = state.gaseous_mass_g.len;
    @memcpy(state.gaseous_mass_g, vector[0..n]);
    @memcpy(state.dissolved_mass_g, vector[n .. 2 * n]);
    @memcpy(state.band_dissolved_mass_g, vector[2 * n .. 3 * n]);
}

pub fn addDirection(current: []const f64, direction: []const f64, fraction: f64, output: []f64) !void {
    for (current, direction, output) |value, delta, *candidate| {
        candidate.* = value + fraction * delta;
        if (!std.math.isFinite(candidate.*) or candidate.* < 0) return error.InvalidCoupledGasCandidate;
    }
}

test "NH3 zones exchange from the same base gas and share the bounded donor" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try gas.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.air_volume_m3[0] = 2;
    state.temperature_k[0] = 298.15;
    const ammonia = @intFromEnum(gas.Species.ammonia);
    state.gaseous_mass_g[ammonia] = 10;
    const count = gas.species_count * 3;
    var base: [count]f64 = undefined;
    var target: [count]f64 = undefined;
    var residual: [count]f64 = undefined;
    copyStateToVector(&state, &base);
    var solubility = [_]f64{1} ** gas.species_count;
    solubility[ammonia] = 9;
    var exchange = [_]f64{0} ** gas.species_count;
    exchange[ammonia] = 1;
    try residualAt(std.testing.allocator, &scratch, &base, &base, .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{},
        .water_volume_m3 = &.{2},
        .band_water_volume_m3 = &.{1},
        .nonband_air_volume_m3 = &.{1},
        .band_air_volume_m3 = &.{1},
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &exchange,
        .band_gas_water_exchange_rate_per_step = &exchange,
        .bubbling_enabled = &.{false},
    }, 1, &target, &residual);
    try std.testing.expectApproxEqAbs(@as(f64, 0), target[ammonia], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 5), target[gas.species_count + ammonia], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 5), target[2 * gas.species_count + ammonia], 1e-14);
}

test "combined phase allocation uses an exact remaining donor" {
    const allocated = try allocatePhaseExchange(0.1, 0.07, 0.09);
    try std.testing.expectEqual(@as(f64, 0), allocated.gas_remaining_g);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1),
        allocated.nonband_flux_g + allocated.band_flux_g,
        8 * std.math.floatEps(f64),
    );

    // Aqueous volatilization is available to the other zone in the same
    // simultaneous phase transaction. The gas donor still finishes exactly
    // at zero and its net loss equals the two recipient changes.
    const mixed = try allocatePhaseExchange(0.1, -0.02, 0.15);
    try std.testing.expectEqual(@as(f64, 0), mixed.gas_remaining_g);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1),
        mixed.nonband_flux_g + mixed.band_flux_g,
        8 * std.math.floatEps(f64),
    );
}

test "conservative publication phase image remains nonnegative and closed" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try gas.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 298.15;
    const ammonia = @intFromEnum(gas.Species.ammonia);
    state.gaseous_mass_g[ammonia] = 0.1;
    const count = gas.species_count * 3;
    var base: [count]f64 = undefined;
    var target: [count]f64 = undefined;
    var publication_target: [count]f64 = undefined;
    var residual: [count]f64 = undefined;
    copyStateToVector(&state, &base);
    var solubility = [_]f64{1} ** gas.species_count;
    solubility[ammonia] = 100;
    var exchange = [_]f64{0} ** gas.species_count;
    exchange[ammonia] = 1;
    const inputs: group_misc.Inputs = .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{},
        .water_volume_m3 = &.{2},
        .band_water_volume_m3 = &.{1},
        .nonband_air_volume_m3 = &.{0.5},
        .band_air_volume_m3 = &.{0.5},
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &exchange,
        .band_gas_water_exchange_rate_per_step = &exchange,
        .bubbling_enabled = &.{false},
    };
    try residualAt(std.testing.allocator, &scratch, &base, &base, inputs, 0.25, &target, &residual);
    try residualAt(std.testing.allocator, &scratch, &base, &target, inputs, 0.25, &publication_target, &residual);
    for (publication_target) |value| try std.testing.expect(value >= 0 and std.math.isFinite(value));
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1),
        publication_target[ammonia] +
            publication_target[gas.species_count + ammonia] +
            publication_target[2 * gas.species_count + ammonia],
        16 * std.math.floatEps(f64),
    );
}

test "phase-released non-ammonia gas closes atmospheric and subsurface boundary classes independently" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try gas.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 298.15;
    scratch.air_volume_m3[0] = state.air_volume_m3[0];
    scratch.temperature_k[0] = state.temperature_k[0];
    const species = @intFromEnum(gas.Species.carbon_dioxide);
    state.dissolved_mass_g[species] = 2;

    const count = gas.species_count * 3;
    var base: [count]f64 = undefined;
    var trial: [count]f64 = undefined;
    var target: [count]f64 = undefined;
    var residual: [count]f64 = undefined;
    copyStateToVector(&state, &base);
    trial = base;
    // Boundary fluxes are evaluated from the nonlinear iterate. The exact
    // target still begins from the authoritative base and receives this gas
    // only through the aqueous phase release below.
    trial[species] = 1;

    var solubility = [_]f64{1} ** gas.species_count;
    solubility[species] = 1;
    var exchange = [_]f64{0} ** gas.species_count;
    exchange[species] = 1;
    const band_exchange = [_]f64{0} ** gas.species_count;
    const zero_atmosphere = [_]f64{0} ** gas.species_count;
    const interior = [_]f64{0.05} ** gas.species_count;
    const atmospheric = atmosphere.Boundary{
        .cell_index = 0,
        .aerodynamic_conductance_m3_per_step = 0.05,
        .interior_conductance_m3_per_step = interior,
        .atmospheric_concentration_g_per_m3 = zero_atmosphere,
        .pressure_exchange_fraction = 0,
    };
    const subsurface = atmosphere.Boundary{
        .cell_index = 0,
        .aerodynamic_conductance_m3_per_step = 0.1,
        .interior_conductance_m3_per_step = interior,
        .atmospheric_concentration_g_per_m3 = zero_atmosphere,
        .pressure_exchange_fraction = 0,
    };
    var atmospheric_ledger = [_]f64{0} ** gas.species_count;
    var subsurface_ledger = [_]f64{0} ** gas.species_count;
    try residualAtCapturing(std.testing.allocator, &scratch, &base, &trial, .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{atmospheric},
        .subsurface_boundaries = &.{subsurface},
        .water_volume_m3 = &.{1},
        .band_water_volume_m3 = &.{0},
        .nonband_air_volume_m3 = &.{1},
        .band_air_volume_m3 = &.{0},
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &exchange,
        .band_gas_water_exchange_rate_per_step = &band_exchange,
        .bubbling_enabled = &.{false},
        .atmospheric_flux_g_by_component = &atmospheric_ledger,
        .subsurface_flux_g_by_component = &subsurface_ledger,
    }, 1, &target, &residual, true);

    try std.testing.expect(atmospheric_ledger[species] < 0);
    try std.testing.expect(subsurface_ledger[species] < 0);
    const final_species_g = target[species] +
        target[gas.species_count + species] +
        target[2 * gas.species_count + species];
    try std.testing.expectApproxEqAbs(
        base[gas.species_count + species] + atmospheric_ledger[species] + subsurface_ledger[species],
        final_species_g,
        16 * std.math.floatEps(f64),
    );
}

test "identical subsurface boundaries retain sequential donor bounds" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try gas.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 298.15;
    scratch.air_volume_m3[0] = state.air_volume_m3[0];
    scratch.temperature_k[0] = state.temperature_k[0];
    const species = @intFromEnum(gas.Species.carbon_dioxide);
    state.gaseous_mass_g[species] = 1;

    const count = gas.species_count * 3;
    var base: [count]f64 = undefined;
    var target: [count]f64 = undefined;
    var residual: [count]f64 = undefined;
    copyStateToVector(&state, &base);

    const boundary: atmosphere.Boundary = .{
        .cell_index = 0,
        .aerodynamic_conductance_m3_per_step = std.math.floatMax(f64),
        .interior_conductance_m3_per_step = [_]f64{1} ** gas.species_count,
        .atmospheric_concentration_g_per_m3 = [_]f64{0} ** gas.species_count,
        .pressure_exchange_fraction = 0,
    };
    const boundaries = [_]atmosphere.Boundary{boundary} ** 4;
    const solubility = [_]f64{1} ** gas.species_count;
    const no_exchange = [_]f64{0} ** gas.species_count;
    var subsurface_ledger = [_]f64{0} ** gas.species_count;
    try residualAtCapturing(std.testing.allocator, &scratch, &base, &base, .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{},
        .subsurface_boundaries = &boundaries,
        .water_volume_m3 = &.{1},
        .band_water_volume_m3 = &.{0},
        .nonband_air_volume_m3 = &.{1},
        .band_air_volume_m3 = &.{0},
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &no_exchange,
        .band_gas_water_exchange_rate_per_step = &no_exchange,
        .bubbling_enabled = &.{false},
        .subsurface_flux_g_by_component = &subsurface_ledger,
    }, 1, &target, &residual, true);

    try std.testing.expectEqual(@as(f64, 0), target[species]);
    try std.testing.expectEqual(@as(f64, -1), subsurface_ledger[species]);
    for (subsurface_ledger, 0..) |flux, index| {
        if (index != species) try std.testing.expectEqual(@as(f64, 0), flux);
    }
}

test "zero-air face cannot source gaseous inventory or a face ledger flow" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    var scratch = try gas.State.init(std.testing.allocator, 2);
    defer scratch.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 300;
    state.temperature_k[1] = 300;
    scratch.air_volume_m3[0] = state.air_volume_m3[0];
    scratch.temperature_k[0] = state.temperature_k[0];
    scratch.temperature_k[1] = state.temperature_k[1];
    const nitrogen = @intFromEnum(gas.Species.nitrogen);
    state.gaseous_mass_g[nitrogen] = 1;
    const count = 2 * gas.species_count * 3;
    var base: [count]f64 = undefined;
    var target: [count]f64 = undefined;
    var residual: [count]f64 = undefined;
    var face_ledger = [_]f64{0} ** gas.species_count;
    copyStateToVector(&state, &base);
    const faces = [_]gas.Face{.{
        .first_cell = 0,
        .second_cell = 1,
    }};
    var conductance = [_]f64{0} ** gas.species_count;
    conductance[nitrogen] = 0.1;
    const water = [_]f64{ 0, 0 };
    const n = 2 * gas.species_count;
    const solubility = [_]f64{1} ** n;
    const no_exchange = [_]f64{0} ** n;
    const no_bubbling = [_]bool{ false, false };
    try residualAtCapturing(
        std.testing.allocator,
        &scratch,
        &base,
        &base,
        .{
            .faces = &faces,
            .face_conductance_m3_per_step = &conductance,
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = &water,
            .band_water_volume_m3 = &water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &no_exchange,
            .band_gas_water_exchange_rate_per_step = &no_exchange,
            .bubbling_enabled = &no_bubbling,
            .face_flux_g_by_component = &face_ledger,
        },
        1,
        &target,
        &residual,
        true,
    );
    try std.testing.expectEqual(@as(f64, 1), target[nitrogen]);
    try std.testing.expectEqual(@as(f64, 0), target[gas.species_count + nitrogen]);
    try std.testing.expectEqual(@as(f64, 0), residual[nitrogen]);
    try std.testing.expectEqual(@as(f64, 0), residual[gas.species_count + nitrogen]);
    for (face_ledger) |flux| try std.testing.expectEqual(@as(f64, 0), flux);
}

test "escaping bubbling reaches daily atmosphere without a second carbon drainage loss" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try @import("../../state/grid.zig").GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    var scratch = try gas.State.init(std.testing.allocator, 2);
    defer scratch.deinit();
    var transport = try @import("transport_step.zig").State.init(std.testing.allocator, 2);
    defer transport.deinit();
    for (0..2) |cell| {
        state.temperature_k[cell] = 300;
        state.air_volume_m3[cell] = 0;
    }
    const co2 = @intFromEnum(gas.Species.carbon_dioxide);
    const ch4 = @intFromEnum(gas.Species.methane);
    const nh3 = @intFromEnum(gas.Species.ammonia);
    state.dissolved_mass_g[co2] = 2;
    state.dissolved_mass_g[gas.species_count + ch4] = 3;
    state.band_dissolved_mass_g[gas.species_count + nh3] = 4;
    const n = 2 * gas.species_count;
    var base: [3 * n]f64 = undefined;
    var target: [3 * n]f64 = undefined;
    var residual: [3 * n]f64 = undefined;
    copyStateToVector(&state, &base);
    const solubility = [_]f64{1} ** n;
    const no_exchange = [_]f64{0} ** n;
    // Loss of liquid capacity releases the complete dissolved inventory;
    // neither layer has a viable gas receiver (the source LG=0 branch).
    try residualAtCapturing(std.testing.allocator, &scratch, &base, &base, .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{},
        .water_volume_m3 = &.{ 0, 0 },
        .band_water_volume_m3 = &.{ 0, 0 },
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &no_exchange,
        .band_gas_water_exchange_rate_per_step = &no_exchange,
        .bubbling_enabled = &.{ true, true },
        .bubble_receiver_cell_by_cell = &.{ null, null },
        .atmospheric_flux_g_by_component = transport.atmospheric_flux_g_per_h,
        .subsurface_flux_g_by_component = transport.subsurface_flux_g_per_h,
    }, 1, &target, &residual, true);
    for (0..n) |component| {
        const before = base[component] + base[n + component] + base[2 * n + component];
        const after = target[component] + target[n + component] + target[2 * n + component];
        try std.testing.expectEqual(@as(f64, 0), after);
        try std.testing.expectEqual(-before, transport.atmospheric_flux_g_per_h[component]);
        try std.testing.expectEqual(@as(f64, 0), transport.subsurface_flux_g_per_h[component]);
    }
    var daily_gas = try @import("../diagnostics/daily_gas_flux.zig").State.init(std.testing.allocator, 1);
    defer daily_gas.deinit();
    const no_litter = [_]f64{0} ** gas.species_count;
    try daily_gas.accumulateHour(null, 1, 2, transport.atmospheric_flux_g_per_h, &no_litter);
    try std.testing.expectEqual(@as(f64, -2), try daily_gas.getSoilLitterBoundary(0, .carbon_dioxide));
    try std.testing.expectEqual(@as(f64, -3), try daily_gas.getSoilLitterBoundary(0, .methane));
    try std.testing.expectEqual(@as(f64, -4), try daily_gas.getSoilLitterBoundary(0, .ammonia));
    var daily_carbon = try @import("../diagnostics/daily_carbon_export.zig").State.init(std.testing.allocator, 1);
    defer daily_carbon.deinit();
    try daily_carbon.accumulateGaseousInorganicDrainageHour(&grid, &transport);
    try std.testing.expectEqual(@as(f64, 0), daily_carbon.dissolved_inorganic_carbon_drainage_g[0]);
    const productivity = try @import("../diagnostics/daily_ecosystem_carbon.zig").calculate(.{
        .net_primary_productivity_g_c = 0,
        .signed_heterotrophic_respiration_g_c = -5,
        .dissolved_organic_carbon_runoff_g_c = 0,
        .dissolved_inorganic_carbon_runoff_g_c = 0,
        .dissolved_organic_carbon_drainage_g_c = 0,
        .dissolved_inorganic_carbon_drainage_g_c = daily_carbon.dissolved_inorganic_carbon_drainage_g[0],
        .harvested_carbon_g_c = 0,
        .organic_fertilizer_carbon_input_g_c = 0,
    });
    try std.testing.expectEqual(@as(f64, -5), productivity.net_biome_productivity_g_c);
}

test "accepted bubbling exposes exact modeled source to receiver transfer" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    var scratch = try gas.State.init(std.testing.allocator, 2);
    defer scratch.deinit();
    for (0..2) |cell| {
        state.temperature_k[cell] = 300;
        scratch.temperature_k[cell] = 300;
        state.air_volume_m3[cell] = 1;
        scratch.air_volume_m3[cell] = 1;
    }
    const oxygen = @intFromEnum(gas.Species.oxygen);
    const source_component = gas.species_count + oxygen;
    state.dissolved_mass_g[source_component] = 2;
    const count = 2 * gas.species_count * 3;
    var base: [count]f64 = undefined;
    var target: [count]f64 = undefined;
    var residual: [count]f64 = undefined;
    copyStateToVector(&state, &base);
    const water = [_]f64{ 0, 0 };
    const n = 2 * gas.species_count;
    const solubility = [_]f64{1} ** n;
    const no_exchange = [_]f64{0} ** n;
    var bubble_transfer = [_]f64{0} ** n;
    try residualAtCapturing(
        std.testing.allocator,
        &scratch,
        &base,
        &base,
        .{
            .faces = &.{},
            .face_conductance_m3_per_step = &.{},
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = &water,
            .band_water_volume_m3 = &water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &no_exchange,
            .band_gas_water_exchange_rate_per_step = &no_exchange,
            .bubbling_enabled = &.{ false, true },
            .bubble_receiver_cell_by_cell = &.{ 0, 0 },
            .bubble_transfer_g_by_component = &bubble_transfer,
        },
        1,
        &target,
        &residual,
        true,
    );
    try std.testing.expectEqual(@as(f64, 2), bubble_transfer[source_component]);
    try std.testing.expectEqual(@as(f64, 2), target[oxygen]);
    try std.testing.expectEqual(@as(f64, 0), target[source_component]);
    try std.testing.expectEqual(@as(f64, 0), target[n + source_component]);
    for (bubble_transfer, 0..) |value, component|
        if (component != source_component)
            try std.testing.expectEqual(@as(f64, 0), value);
}

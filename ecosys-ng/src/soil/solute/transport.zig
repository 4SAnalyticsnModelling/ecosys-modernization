const std = @import("std");

pub const Face = struct {
    first_cell: usize,
    second_cell: usize,
    /// Runtime DLYRM gate for fixed-capacity topology slots.
    active: bool = true,
    /// Positive water moves first -> second; negative moves second -> first.
    water_flux_m3_per_step: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    water_volume_m3: []f64,
    /// Cell-major extensive aqueous inventories in mol.
    amount_mol: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, species_count: usize) !State {
        if (cell_count == 0) return error.ZeroTransportCellCount;
        if (species_count == 0) return error.ZeroTransportSpeciesCount;
        const water = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(water);
        const amount = try allocator.alloc(f64, try std.math.mul(usize, cell_count, species_count));
        errdefer allocator.free(amount);
        @memset(water, 0);
        @memset(amount, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .species_count = species_count, .water_volume_m3 = water, .amount_mol = amount };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.amount_mol);
        self.allocator.free(self.water_volume_m3);
        self.* = undefined;
    }

    pub fn cellAmounts(self: *State, cell_index: usize) ![]f64 {
        if (cell_index >= self.cell_count) return error.TransportCellIndexOutOfBounds;
        const start = cell_index * self.species_count;
        return self.amount_mol[start .. start + self.species_count];
    }

    pub fn cellAmountsConst(self: *const State, cell_index: usize) ![]const f64 {
        if (cell_index >= self.cell_count) return error.TransportCellIndexOutOfBounds;
        const start = cell_index * self.species_count;
        return self.amount_mol[start .. start + self.species_count];
    }

    /// Rejects corrupted runtime-shaped aqueous state before it can silently
    /// enter a transport solve or an authoritative tile generation.
    pub fn validateFinite(self: *const State) !void {
        if (self.cell_count == 0) return error.ZeroTransportCellCount;
        if (self.species_count == 0) return error.ZeroTransportSpeciesCount;
        if (self.water_volume_m3.len != self.cell_count)
            return error.TransportWaterVolumeDimensionMismatch;
        const expected_amount_count = std.math.mul(
            usize,
            self.cell_count,
            self.species_count,
        ) catch return error.TransportStateDimensionOverflow;
        if (self.amount_mol.len != expected_amount_count)
            return error.TransportAmountDimensionMismatch;

        for (self.water_volume_m3, 0..) |water_volume_m3, cell_index| {
            if (!std.math.isFinite(water_volume_m3))
                return error.NonFiniteTransportWaterVolume;
            if (water_volume_m3 < 0)
                return error.NegativeTransportWaterVolume;
            const first_species = cell_index * self.species_count;
            for (
                self.amount_mol[first_species..][0..self.species_count],
            ) |amount_mol| {
                if (!std.math.isFinite(amount_mol))
                    return error.NonFiniteTransportAmount;
                if (amount_mol < 0)
                    return error.NegativeTransportAmount;
            }
        }
    }
};

pub const FaceParameters = struct {
    /// Legacy `VFLWX`: maximum donor-water fraction transported per solve step.
    maximum_convective_fraction: f64,
};

/// Computes positive first->second molar fluxes for every runtime species.
/// `diffusive_conductance_m3_per_step` includes diffusivity, tortuosity,
/// dispersivity, interface area, and distance. `mobility_fraction` is an
/// additional mobile share only; band/non-band fractions already reside in
/// their physical extensive inventories and therefore pass one here.
pub fn calculateFaceFluxes(state: *const State, face: Face, diffusive_conductance_m3_per_step: []const f64, mobility_fraction: []const f64, parameters: FaceParameters, output_flux_mol: []f64) !void {
    try state.validateFinite();
    return calculateFaceFluxesFromValidatedState(
        state,
        face,
        diffusive_conductance_m3_per_step,
        mobility_fraction,
        parameters,
        output_flux_mol,
    );
}

/// Face kernel for callers that have already validated the complete state.
/// Dense transport Jacobians evaluate many faces against one trial vector;
/// rescanning every cell and species before every face is redundant. Shape,
/// topology, and scalar parameters remain checked on every invocation.
pub fn calculateFaceFluxesFromValidatedState(state: *const State, face: Face, diffusive_conductance_m3_per_step: []const f64, mobility_fraction: []const f64, parameters: FaceParameters, output_flux_mol: []f64) !void {
    try validateFaceShapeInputs(state, face, diffusive_conductance_m3_per_step, mobility_fraction, parameters, output_flux_mol);
    return calculateFaceFluxesFromValidatedInputs(
        state,
        face,
        diffusive_conductance_m3_per_step,
        mobility_fraction,
        parameters,
        output_flux_mol,
    );
}

/// Vector face kernel for the implicit solver after its solve-invariant inputs
/// and current trial state have been validated once.
pub fn calculateFaceFluxesFromValidatedInputs(state: *const State, face: Face, diffusive_conductance_m3_per_step: []const f64, mobility_fraction: []const f64, parameters: FaceParameters, output_flux_mol: []f64) !void {
    if (!face.active) {
        @memset(output_flux_mol, 0);
        return;
    }
    const first = try state.cellAmountsConst(face.first_cell);
    const second = try state.cellAmountsConst(face.second_cell);
    const first_water = state.water_volume_m3[face.first_cell];
    const second_water = state.water_volume_m3[face.second_cell];

    for (output_flux_mol, first, second, diffusive_conductance_m3_per_step, mobility_fraction) |*flux, first_amount, second_amount, conductance, mobility| {
        const first_mobile = first_amount * mobility;
        const second_mobile = second_amount * mobility;
        const first_concentration = if (first_water > 0) first_amount / first_water else 0;
        const second_concentration = if (second_water > 0) second_amount / second_water else 0;
        const donor_fraction = if (face.water_flux_m3_per_step >= 0)
            if (first_water > 0) @min(parameters.maximum_convective_fraction, face.water_flux_m3_per_step / first_water) else parameters.maximum_convective_fraction
        else if (second_water > 0)
            @min(parameters.maximum_convective_fraction, -face.water_flux_m3_per_step / second_water)
        else
            parameters.maximum_convective_fraction;
        const convection = if (face.water_flux_m3_per_step >= 0) donor_fraction * first_mobile else -donor_fraction * second_mobile;
        const diffusion = conductance * (first_concentration - second_concentration) * mobility;
        // The old NPH loop limited each small transfer indirectly. The direct
        // solve applies the identical direction but clips the combined extent
        // to the available mobile inventory, preventing negative progression.
        flux.* = std.math.clamp(convection + diffusion, -second_mobile, first_mobile);
        if (!std.math.isFinite(flux.*)) return error.NonFiniteSoluteTransportFlux;
    }
}

/// Scalar form of `calculateFaceFluxesFromValidatedInputs`. Transport species
/// are independent equations, so a finite-difference column for one species
/// must not reevaluate every other species merely to discard their rows.
pub fn calculateFaceFluxForSpeciesFromValidatedInputs(
    state: *const State,
    face: Face,
    diffusive_conductance_m3_per_step: []const f64,
    mobility_fraction: []const f64,
    parameters: FaceParameters,
    species: usize,
) !f64 {
    if (species >= state.species_count) return error.TransportSpeciesCountMismatch;
    if (!face.active) return 0;
    const first_amount = (try state.cellAmountsConst(face.first_cell))[species];
    const second_amount = (try state.cellAmountsConst(face.second_cell))[species];
    const first_water = state.water_volume_m3[face.first_cell];
    const second_water = state.water_volume_m3[face.second_cell];
    const mobility = mobility_fraction[species];
    const first_mobile = first_amount * mobility;
    const second_mobile = second_amount * mobility;
    const first_concentration = if (first_water > 0) first_amount / first_water else 0;
    const second_concentration = if (second_water > 0) second_amount / second_water else 0;
    const donor_fraction = if (face.water_flux_m3_per_step >= 0)
        if (first_water > 0) @min(parameters.maximum_convective_fraction, face.water_flux_m3_per_step / first_water) else parameters.maximum_convective_fraction
    else if (second_water > 0)
        @min(parameters.maximum_convective_fraction, -face.water_flux_m3_per_step / second_water)
    else
        parameters.maximum_convective_fraction;
    const convection = if (face.water_flux_m3_per_step >= 0)
        donor_fraction * first_mobile
    else
        -donor_fraction * second_mobile;
    const diffusion = diffusive_conductance_m3_per_step[species] *
        (first_concentration - second_concentration) * mobility;
    const flux = std.math.clamp(
        convection + diffusion,
        -second_mobile,
        first_mobile,
    );
    if (!std.math.isFinite(flux)) return error.NonFiniteSoluteTransportFlux;
    return flux;
}

/// Applies a previously calculated face vector atomically and conserves every
/// species exactly. Suitable face coloring lets callers execute independent
/// grid faces in parallel without atomics.
pub fn state_updateFaceFluxes(state: *State, face: Face, flux_mol: []const f64) !void {
    if (face.first_cell >= state.cell_count or face.second_cell >= state.cell_count or face.first_cell == face.second_cell) return error.InvalidTransportFace;
    if (flux_mol.len != state.species_count) return error.TransportSpeciesCountMismatch;
    const first = try state.cellAmounts(face.first_cell);
    const second = try state.cellAmounts(face.second_cell);
    for (flux_mol, first, second) |flux, first_amount, second_amount| {
        if (!std.math.isFinite(flux)) return error.NonFiniteSoluteTransportFlux;
        if (first_amount - flux < 0 or second_amount + flux < 0) return error.InsufficientSoluteForTransport;
    }
    for (flux_mol, first, second) |flux, *first_amount, *second_amount| {
        first_amount.* -= flux;
        second_amount.* += flux;
    }
}

/// Physical replacement for the legacy `XFRS=0.05` TRNSFRS constant
/// (SOLUTE-XFRS-PHYSICAL, `docs/agent_prompt_substep_audit_and_limiters.md`
/// Part 3, Route A). The legacy form capped the *exchanging* macropore water
/// at `0.05*layer_volume_m3` inside both the numerator and the denominator of
/// the transfer, which does not merely slow the exchange: it moves the
/// zero-flux point away from equal concentration whenever
/// `macropore_water_m3 > 0.05*layer_volume_m3`, i.e. in exactly the wet,
/// macropore-rich regime that motivates having a dual-domain model at all.
///
/// This form instead lets the exchange relax toward the true, uncapped,
/// equal-concentration equilibrium at a physically set first-order rate:
///
///   Q_eq = equilibrium transfer that equalizes concentration between the
///          full micropore and macropore water volumes (no volume cap).
///   Q    = Q_eq * (1 - exp(-alpha * dt)), dt = step_fraction (dt<=1 h)
///   alpha = beta * D_eff * theta_micro / d^2
///
/// - `d` (`macropore_spacing_m_arg`) is the existing per-layer macropore
///   spacing already produced by `soil/runtime/hourly_workspace.zig` from the
///   legacy `PHOL=1/sqrt(pi*NHOL)` geometry (`hour1.f:2318-2328`). No new
///   input parameter; this is the same spacing already bound at
///   `soil/water/solver_residual.zig:220-221` for the water dual-domain
///   exchange (Gerke-van Genuchten first-order transfer,
///   `soil/water/flux.zig:calculateDualDomainExchange`), so the solute
///   exchange now uses the identical geometric length scale as the water
///   exchange between the same two domains.
/// - `beta` = 3, the analytic first-order shape factor for spherical
///   aggregates (Gerke & van Genuchten 1993; cylindrical/planar aggregate
///   families use 15/8 respectively). 3 is used here because it matches the
///   value already adopted for water-phase dual-domain exchange (default
///   `dual_domain_geometry_factor`, `soil/runtime/hourly_workspace.zig:35`),
///   keeping the solute and water exchange geometrically consistent for the
///   same aggregate population.
/// - `D_eff` is not re-derived here: callers already compute a per-species,
///   temperature- and tortuosity-adjusted diffusive conductance
///   (`soil/solute/face_parameters.zig`) for lateral face transport between
///   cells. Reusing a second, independent diffusivity model for the vertical
///   micropore/macropore exchange inside one cell would silently diverge from
///   that convention, so this function instead takes a directly supplied
///   `micropore_diffusivity_m2_per_h` reference value (temperature-adjusted by
///   the caller with the same factor used for lateral transport) and combines
///   it with `theta_micro` here. Pass 0 to fall back to zero exchange (safe,
///   finite, conservative default) rather than inventing a diffusivity.
pub fn calculatePoreExchangeFlux(micropore_amount_mol: f64, macropore_amount_mol: f64, micropore_water_m3: f64, macropore_water_m3: f64, layer_volume_m3: f64, step_fraction: f64, macropore_spacing_m_arg: f64, micropore_diffusivity_m2_per_h: f64) !f64 {
    const values = [_]f64{ micropore_amount_mol, macropore_amount_mol, micropore_water_m3, macropore_water_m3, layer_volume_m3, step_fraction, macropore_spacing_m_arg, micropore_diffusivity_m2_per_h };
    for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPoreExchangeInput;
    if (step_fraction > 1) return error.InvalidPoreExchangeInput;
    if (macropore_spacing_m_arg <= 0) return error.InvalidPoreExchangeInput;
    if (macropore_water_m3 == 0) return 0;
    const combined_water_m3 = micropore_water_m3 + macropore_water_m3;
    if (combined_water_m3 == 0) return 0;
    // Uncapped equal-concentration equilibrium transfer (macropore -> micropore
    // positive); step_fraction and alpha below set how much of that gap closes.
    const equilibrium_flux_mol = (macropore_amount_mol * micropore_water_m3 - micropore_amount_mol * macropore_water_m3) / combined_water_m3;
    if (layer_volume_m3 == 0) return 0;
    const theta_micro = micropore_water_m3 / layer_volume_m3;
    const beta: f64 = 3; // spherical-aggregate shape factor, matches dual_domain_geometry_factor default
    const alpha_per_h = beta * micropore_diffusivity_m2_per_h * theta_micro /
        (macropore_spacing_m_arg * macropore_spacing_m_arg);
    if (!std.math.isFinite(alpha_per_h) or alpha_per_h < 0) return error.InvalidPoreExchangeInput;
    const approach_fraction = 1 - @exp(-alpha_per_h * step_fraction);
    const flux = equilibrium_flux_mol * approach_fraction;
    if (!std.math.isFinite(flux)) return error.NonFinitePoreExchangeFlux;
    return std.math.clamp(flux, -micropore_amount_mol, macropore_amount_mol);
}

/// FINHM donor-upwind convective carrier from WATSUB/TRNSFR. `water_m3` is
/// the accepted post-exchange endpoint, so the donor's pre-transfer water is
/// reconstructed by adding the amount it donated. Positive flux transfers
/// macropore solute into the micropore domain; negative reverses the transfer.
pub fn calculateConvectivePoreExchangeFlux(
    micropore_amount: f64,
    macropore_amount: f64,
    micropore_water_m3: f64,
    macropore_water_m3: f64,
    macropore_to_micropore_water_m3: f64,
    maximum_convective_fraction: f64,
) !f64 {
    const values = [_]f64{ micropore_amount, macropore_amount, micropore_water_m3, macropore_water_m3, macropore_to_micropore_water_m3, maximum_convective_fraction };
    for (values) |value| if (!std.math.isFinite(value)) return error.InvalidPoreExchangeInput;
    if (micropore_amount < 0 or macropore_amount < 0 or micropore_water_m3 < 0 or macropore_water_m3 < 0 or maximum_convective_fraction < 0 or maximum_convective_fraction > 1)
        return error.InvalidPoreExchangeInput;
    if (macropore_to_micropore_water_m3 == 0) return 0;
    if (macropore_to_micropore_water_m3 > 0) {
        const donor_water_m3 = macropore_water_m3 + macropore_to_micropore_water_m3;
        if (!std.math.isFinite(donor_water_m3) or donor_water_m3 <= 0)
            return error.InvalidPoreExchangeInput;
        const donor_fraction = @min(maximum_convective_fraction, macropore_to_micropore_water_m3 / donor_water_m3);
        return @min(macropore_amount, donor_fraction * macropore_amount);
    }
    const donor_water_m3 = micropore_water_m3 - macropore_to_micropore_water_m3;
    if (!std.math.isFinite(donor_water_m3) or donor_water_m3 <= 0)
        return error.InvalidPoreExchangeInput;
    const donor_fraction = @min(maximum_convective_fraction, -macropore_to_micropore_water_m3 / donor_water_m3);
    return -@min(micropore_amount, donor_fraction * micropore_amount);
}

pub fn state_updatePoreExchange(micropore_amount_mol: *f64, macropore_amount_mol: *f64, flux_macropore_to_micropore_mol: f64) !void {
    if (!std.math.isFinite(micropore_amount_mol.*) or micropore_amount_mol.* < 0 or !std.math.isFinite(macropore_amount_mol.*) or macropore_amount_mol.* < 0 or !std.math.isFinite(flux_macropore_to_micropore_mol)) return error.InvalidPoreExchangeInput;
    if (micropore_amount_mol.* + flux_macropore_to_micropore_mol < 0 or macropore_amount_mol.* - flux_macropore_to_micropore_mol < 0) return error.InsufficientSoluteForPoreExchange;
    micropore_amount_mol.* += flux_macropore_to_micropore_mol;
    macropore_amount_mol.* -= flux_macropore_to_micropore_mol;
}

fn validateFaceShapeInputs(state: *const State, face: Face, conductance: []const f64, mobility: []const f64, parameters: FaceParameters, output: []f64) !void {
    if (face.first_cell >= state.cell_count or face.second_cell >= state.cell_count or face.first_cell == face.second_cell) return error.InvalidTransportFace;
    if (conductance.len != state.species_count or mobility.len != state.species_count or output.len != state.species_count) return error.TransportSpeciesCountMismatch;
    if (!std.math.isFinite(face.water_flux_m3_per_step) or !std.math.isFinite(parameters.maximum_convective_fraction) or parameters.maximum_convective_fraction < 0 or parameters.maximum_convective_fraction > 1) return error.InvalidTransportParameter;
    if (!std.math.isFinite(state.water_volume_m3[face.first_cell]) or state.water_volume_m3[face.first_cell] < 0 or !std.math.isFinite(state.water_volume_m3[face.second_cell]) or state.water_volume_m3[face.second_cell] < 0) return error.InvalidTransportWaterVolume;
    const first = try state.cellAmountsConst(face.first_cell);
    const second = try state.cellAmountsConst(face.second_cell);
    for (first, second, conductance, mobility) |a, b, d, mobile| {
        if (!std.math.isFinite(a) or a < 0 or !std.math.isFinite(b) or b < 0) return error.InvalidSoluteTransportState;
        if (!std.math.isFinite(d) or d < 0 or !std.math.isFinite(mobile) or mobile < 0 or mobile > 1) return error.InvalidTransportParameter;
    }
}

test "upwind convection and diffusion conserve every runtime species" {
    var state = try State.init(std.testing.allocator, 2, 3);
    defer state.deinit();
    state.water_volume_m3[0] = 2;
    state.water_volume_m3[1] = 1;
    @memcpy(try state.cellAmounts(0), &[_]f64{ 4, 2, 8 });
    @memcpy(try state.cellAmounts(1), &[_]f64{ 1, 3, 0 });
    const before = [_]f64{ 5, 5, 8 };
    var flux: [3]f64 = undefined;
    try calculateFaceFluxes(&state, .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0.2 }, &[_]f64{ 0.1, 0.1, 0.1 }, &[_]f64{ 1, 0.5, 1 }, .{ .maximum_convective_fraction = 0.2 }, &flux);
    try state_updateFaceFluxes(&state, .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0.2 }, &flux);
    const first = try state.cellAmountsConst(0);
    const second = try state.cellAmountsConst(1);
    for (before, first, second) |total, a, b| try std.testing.expectApproxEqAbs(total, a + b, 1e-14);
}

test "single-species face kernel is bit-identical to the validated vector kernel" {
    var state = try State.init(std.testing.allocator, 2, 3);
    defer state.deinit();
    state.water_volume_m3[0..2].* = .{ 2, 1 };
    @memcpy(try state.cellAmounts(0), &[_]f64{ 4, 2, 8 });
    @memcpy(try state.cellAmounts(1), &[_]f64{ 1, 3, 0 });
    const face: Face = .{
        .first_cell = 0,
        .second_cell = 1,
        .water_flux_m3_per_step = 0.2,
    };
    const conductance = [_]f64{ 0.1, 0.2, 0.3 };
    const mobility = [_]f64{ 1, 0.5, 0.75 };
    const parameters: FaceParameters = .{ .maximum_convective_fraction = 0.2 };
    var vector: [3]f64 = undefined;
    try state.validateFinite();
    try calculateFaceFluxesFromValidatedInputs(
        &state,
        face,
        &conductance,
        &mobility,
        parameters,
        &vector,
    );
    for (vector, 0..) |expected, species| {
        const scalar = try calculateFaceFluxForSpeciesFromValidatedInputs(
            &state,
            face,
            &conductance,
            &mobility,
            parameters,
            species,
        );
        try std.testing.expectEqual(
            @as(u64, @bitCast(expected)),
            @as(u64, @bitCast(scalar)),
        );
    }
}

test "negative water flux uses the second cell as donor" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    state.water_volume_m3[0] = 1;
    state.water_volume_m3[1] = 2;
    (try state.cellAmounts(0))[0] = 0;
    (try state.cellAmounts(1))[0] = 4;
    var flux: [1]f64 = undefined;
    try calculateFaceFluxes(&state, .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = -0.2 }, &[_]f64{0}, &[_]f64{1}, .{ .maximum_convective_fraction = 1 }, &flux);
    try std.testing.expectApproxEqAbs(@as(f64, -0.4), flux[0], 1e-15);
}

test "DLYRM-inactive fixed-capacity face returns exact zero flux" {
    var state = try State.init(std.testing.allocator, 2, 2);
    defer state.deinit();
    @memset(state.water_volume_m3, 1);
    @memcpy(try state.cellAmounts(0), &[_]f64{ 4, 8 });
    @memcpy(try state.cellAmounts(1), &[_]f64{ 1, 2 });
    var flux = [_]f64{ 99, 99 };
    try calculateFaceFluxes(
        &state,
        .{ .first_cell = 0, .second_cell = 1, .active = false, .water_flux_m3_per_step = 100 },
        &.{ 100, 100 },
        &.{ 1, 1 },
        .{ .maximum_convective_fraction = 1 },
        &flux,
    );
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, &flux);
}

test "micropore macropore exchange relaxes toward equal-concentration equilibrium" {
    // Uncapped equilibrium target: (macro*micro_water - micro*macro_water) / combined_water
    // = (6*4 - 2*3) / 7 = 18/7.
    const equilibrium: f64 = (6.0 * 4.0 - 2.0 * 3.0) / 7.0;
    const flux = try calculatePoreExchangeFlux(2, 6, 4, 3, 20, 1, 1, 0.1);
    // Full step_fraction with finite alpha still only approaches, never
    // overshoots, the equilibrium target.
    try std.testing.expect(flux > 0);
    try std.testing.expect(flux < equilibrium);
    var micro: f64 = 2;
    var macro: f64 = 6;
    try state_updatePoreExchange(&micro, &macro, flux);
    try std.testing.expectApproxEqAbs(@as(f64, 8), micro + macro, 1e-15);
}

test "FINHM convective pore exchange is donor-upwind and conservative by sign" {
    const macro_to_micro = try calculateConvectivePoreExchangeFlux(4, 9, 2.25, 0.75, 0.25, 1);
    // Pre-transfer macropore water is 1 m3, hence 25% of its inventory.
    try std.testing.expectApproxEqAbs(@as(f64, 2.25), macro_to_micro, 1e-15);
    var micro: f64 = 4;
    var macro: f64 = 9;
    try state_updatePoreExchange(&micro, &macro, macro_to_micro);
    try std.testing.expectApproxEqAbs(@as(f64, 13), micro + macro, 0);

    const micro_to_macro = try calculateConvectivePoreExchangeFlux(8, 3, 1.5, 1.5, -0.5, 1);
    // Pre-transfer micropore water is 2 m3, hence 25% of its inventory.
    try std.testing.expectApproxEqAbs(@as(f64, -2), micro_to_macro, 1e-15);
}

test "pore exchange flux approaches equilibrium as alpha*dt grows" {
    const equilibrium: f64 = (6.0 * 4.0 - 2.0 * 3.0) / 7.0;
    // Large diffusivity / tiny spacing drives alpha*dt >> 1.
    const flux = try calculatePoreExchangeFlux(2, 6, 4, 3, 20, 1, 1e-6, 1);
    try std.testing.expectApproxEqAbs(equilibrium, flux, 1e-9);
}

test "pore exchange flux is antisymmetric in donor/acceptor amounts" {
    // Hold micropore/macropore water volumes equal so the relaxation rate
    // (which depends on micropore geometry, not on which side is "donor")
    // stays identical between the two calls; only the amounts (and hence
    // the concentration difference driving the flux) are swapped.
    const forward = try calculatePoreExchangeFlux(2, 6, 4, 4, 20, 1, 0.05, 0.1);
    const reversed = try calculatePoreExchangeFlux(6, 2, 4, 4, 20, 1, 0.05, 0.1);
    try std.testing.expectApproxEqAbs(-forward, reversed, 1e-15);
}

test "pore exchange flux rejects non-positive macropore spacing" {
    try std.testing.expectError(error.InvalidPoreExchangeInput, calculatePoreExchangeFlux(2, 6, 4, 3, 20, 1, 0, 0.1));
    try std.testing.expectError(error.InvalidPoreExchangeInput, calculatePoreExchangeFlux(2, 6, 4, 3, 20, 1, -1, 0.1));
}

test "pore exchange flux is zero when micropore diffusivity is zero" {
    const flux = try calculatePoreExchangeFlux(2, 6, 4, 3, 20, 1, 0.05, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0), flux, 1e-15);
}

test "combined transport cannot overdraw a donor" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    state.water_volume_m3[0] = 1;
    state.water_volume_m3[1] = 1;
    (try state.cellAmounts(0))[0] = 0.1;
    var flux: [1]f64 = undefined;
    try calculateFaceFluxes(&state, .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 100 }, &[_]f64{100}, &[_]f64{1}, .{ .maximum_convective_fraction = 1 }, &flux);
    try std.testing.expectEqual(@as(f64, 0.1), flux[0]);
}

test "face transfer rejects even a sub-tolerance overdraw without clipping either pool" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    (try state.cellAmounts(0))[0] = 1;
    (try state.cellAmounts(1))[0] = 2;
    try std.testing.expectError(
        error.InsufficientSoluteForTransport,
        state_updateFaceFluxes(&state, .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }, &.{1.0 + 1.0e-15}),
    );
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, state.amount_mol);
}

test "aqueous state supports more than five runtime species and validates all inventories" {
    const runtime_species_count: usize = 13;
    var state = try State.init(
        std.testing.allocator,
        4,
        runtime_species_count,
    );
    defer state.deinit();

    for (state.water_volume_m3, 0..) |*water_volume_m3, cell_index|
        water_volume_m3.* = @as(f64, @floatFromInt(cell_index + 1));
    for (state.amount_mol, 0..) |*amount_mol, component_index|
        amount_mol.* = @as(f64, @floatFromInt(component_index + 1)) * 1e-6;
    try state.validateFinite();

    state.amount_mol[runtime_species_count + 7] = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteTransportAmount,
        state.validateFinite(),
    );
}

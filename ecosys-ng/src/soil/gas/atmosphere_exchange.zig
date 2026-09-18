const std = @import("std");
const gas = @import("transport.zig");

pub const Boundary = struct {
    cell_index: usize,
    /// Species-independent aerodynamic boundary conductance (`PARG`).
    aerodynamic_conductance_m3_per_step: f64,
    /// Conductance through the litter or upper soil cell for each gas.
    interior_conductance_m3_per_step: [gas.species_count]f64,
    atmospheric_concentration_g_per_m3: [gas.species_count]f64,
    /// Fraction of the open-boundary pressure displacement represented by
    /// this face. Surface atmosphere exchange uses one; perimeter/profile
    /// boundaries use their runtime subsurface exchange fraction.
    pressure_exchange_fraction: f64 = 1,
};

/// Computes total diffusive plus temperature/pressure exchange. Positive flux
/// enters the cell. `iteration_fraction` is reserved for a caller intentionally
/// splitting this local equation; accepted whole-step solves pass one.
pub fn calculateFluxesG(state: *const gas.State, boundary: Boundary, iteration_fraction: f64, output_flux_g: []f64) !void {
    if (boundary.cell_index >= state.cell_count) return error.GasBoundaryCellIndexOutOfBounds;
    if (output_flux_g.len != gas.species_count) return error.GasSpeciesCountMismatch;
    if (!std.math.isFinite(boundary.aerodynamic_conductance_m3_per_step) or boundary.aerodynamic_conductance_m3_per_step < 0 or !std.math.isFinite(boundary.pressure_exchange_fraction) or boundary.pressure_exchange_fraction < 0 or boundary.pressure_exchange_fraction > 1) return error.InvalidGasBoundary;
    const masses = try state.gaseousMassesConst(boundary.cell_index);
    var pressure_flux: [gas.species_count]f64 = undefined;
    try gas.pressureDrivenFluxesG(state.air_volume_m3[boundary.cell_index], state.temperature_k[boundary.cell_index], state.water_vapor_mol[boundary.cell_index], masses, iteration_fraction, &pressure_flux);
    // `pressureDrivenFluxesG` allocates a bulk pressure correction in
    // proportion to the resident dry-gas mixture. At an exactly empty dry-gas
    // control volume that mixture is undefined and the low-level routine
    // correctly returns zero. An open boundary, however, supplies the missing
    // composition: use its atmospheric mole fractions to populate the
    // pressure deficit. Without this boundary-owned limit, F(x) jumps from a
    // small diffusive input at x=0 to a pressure-scale target for every x>0;
    // no strictly descending Newton or Anderson path can leave the bound.
    var resident_dry_gas_mol: f64 = 0;
    var atmospheric_dry_gas_mol_per_m3: f64 = 0;
    for (masses, boundary.atmospheric_concentration_g_per_m3, gas.g_per_mol_tracked) |mass, concentration, molar_mass| {
        if (!std.math.isFinite(concentration) or concentration < 0)
            return error.InvalidGasBoundary;
        resident_dry_gas_mol += mass / molar_mass;
        atmospheric_dry_gas_mol_per_m3 += concentration / molar_mass;
    }
    if (resident_dry_gas_mol == 0 and atmospheric_dry_gas_mol_per_m3 > 0) {
        const capacity_mol = @max(
            0,
            1.2194e4 * state.air_volume_m3[boundary.cell_index] /
                state.temperature_k[boundary.cell_index] -
                state.water_vapor_mol[boundary.cell_index],
        );
        for (&pressure_flux, boundary.atmospheric_concentration_g_per_m3, gas.g_per_mol_tracked) |*flux, concentration, molar_mass| {
            flux.* = capacity_mol * iteration_fraction *
                (concentration / molar_mass) /
                atmospheric_dry_gas_mol_per_m3 * molar_mass;
            if (!std.math.isFinite(flux.*) or flux.* < 0)
                return error.NonFiniteGasBoundaryFlux;
        }
    }
    for (output_flux_g, masses, pressure_flux, boundary.interior_conductance_m3_per_step, boundary.atmospheric_concentration_g_per_m3, gas.atmospheric_boundary_multiplier) |*total, mass, pressure, interior, atmospheric_concentration, multiplier| {
        if (!std.math.isFinite(atmospheric_concentration) or atmospheric_concentration < 0) return error.InvalidGasBoundary;
        const boundary_conductance = if (multiplier == 0)
            0
        else if (boundary.aerodynamic_conductance_m3_per_step > std.math.floatMax(f64) / multiplier)
            std.math.floatMax(f64)
        else
            boundary.aerodynamic_conductance_m3_per_step * multiplier;
        const effective = try gas.seriesConductance(interior, boundary_conductance);
        const diffusion = try gas.atmosphericDiffusiveFluxG(mass, state.air_volume_m3[boundary.cell_index], atmospheric_concentration, effective, iteration_fraction);
        total.* = @max(-mass, diffusion + boundary.pressure_exchange_fraction * pressure);
        if (!std.math.isFinite(total.*)) return error.NonFiniteGasBoundaryFlux;
    }
}

/// Coupled-solver form after one solve-level validation of boundary parameters
/// and one residual-level validation of the nonlinear candidate inventories.
pub fn calculateFluxesGFromValidatedInputs(state: *const gas.State, boundary: Boundary, iteration_fraction: f64, output_flux_g: []f64) !void {
    const masses = state.gaseous_mass_g[boundary.cell_index * gas.species_count ..][0..gas.species_count];
    var pressure_flux: [gas.species_count]f64 = undefined;
    try gas.pressureDrivenFluxesGFromValidatedInputs(state.air_volume_m3[boundary.cell_index], state.temperature_k[boundary.cell_index], state.water_vapor_mol[boundary.cell_index], masses, iteration_fraction, &pressure_flux);
    var resident_dry_gas_mol: f64 = 0;
    var atmospheric_dry_gas_mol_per_m3: f64 = 0;
    for (masses, boundary.atmospheric_concentration_g_per_m3, gas.g_per_mol_tracked) |mass, concentration, molar_mass| {
        resident_dry_gas_mol += mass / molar_mass;
        atmospheric_dry_gas_mol_per_m3 += concentration / molar_mass;
    }
    if (resident_dry_gas_mol == 0 and atmospheric_dry_gas_mol_per_m3 > 0) {
        const capacity_mol = @max(
            0,
            1.2194e4 * state.air_volume_m3[boundary.cell_index] /
                state.temperature_k[boundary.cell_index] -
                state.water_vapor_mol[boundary.cell_index],
        );
        for (&pressure_flux, boundary.atmospheric_concentration_g_per_m3, gas.g_per_mol_tracked) |*flux, concentration, molar_mass| {
            flux.* = capacity_mol * iteration_fraction *
                (concentration / molar_mass) /
                atmospheric_dry_gas_mol_per_m3 * molar_mass;
            if (!std.math.isFinite(flux.*) or flux.* < 0)
                return error.NonFiniteGasBoundaryFlux;
        }
    }
    for (output_flux_g, masses, pressure_flux, boundary.interior_conductance_m3_per_step, boundary.atmospheric_concentration_g_per_m3, gas.atmospheric_boundary_multiplier) |*total, mass, pressure, interior, atmospheric_concentration, multiplier| {
        const boundary_conductance = if (multiplier == 0)
            0
        else if (boundary.aerodynamic_conductance_m3_per_step > std.math.floatMax(f64) / multiplier)
            std.math.floatMax(f64)
        else
            boundary.aerodynamic_conductance_m3_per_step * multiplier;
        const effective = gas.seriesConductanceFromValidatedInputs(interior, boundary_conductance);
        const diffusion = gas.atmosphericDiffusiveFluxGFromValidatedInputs(mass, state.air_volume_m3[boundary.cell_index], atmospheric_concentration, effective, iteration_fraction);
        total.* = @max(-mass, diffusion + boundary.pressure_exchange_fraction * pressure);
        if (!std.math.isFinite(total.*)) return error.NonFiniteGasBoundaryFlux;
    }
}

/// Applies independent boundary vectors atomically. Multiple boundaries may
/// address one cell (e.g. exposed litter and soil are normally mutually
/// exclusive); all contributions are summed before validation and state_update.
pub fn state_updateFluxesG(allocator: std.mem.Allocator, state: *gas.State, boundaries: []const Boundary, boundary_flux_g: []const f64) !void {
    if (boundary_flux_g.len != try std.math.mul(usize, boundaries.len, gas.species_count)) return error.GasBoundaryFluxSizeMismatch;
    const net = try allocator.alloc(f64, state.gaseous_mass_g.len);
    defer allocator.free(net);
    @memset(net, 0);
    for (boundaries, 0..) |boundary, boundary_index| {
        if (boundary.cell_index >= state.cell_count) return error.GasBoundaryCellIndexOutOfBounds;
        for (0..gas.species_count) |species| {
            const flux = boundary_flux_g[boundary_index * gas.species_count + species];
            if (!std.math.isFinite(flux)) return error.NonFiniteGasBoundaryFlux;
            net[boundary.cell_index * gas.species_count + species] += flux;
        }
    }
    for (state.gaseous_mass_g, net) |mass, change| if (!std.math.isFinite(mass + change) or mass + change < 0) return error.NegativeGasBoundaryCandidate;
    for (state.gaseous_mass_g, net) |*mass, change| mass.* += change;
}

test "species multipliers reproduce atmospheric boundary conductances" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 300;
    // Set the molar inventory to ideal capacity so pressure flow is zero.
    state.gaseous_mass_g[0] = 1.2194e4 / @as(f64, 300) * 12;
    const interior = [_]f64{0.1} ** gas.species_count;
    var atmosphere = [_]f64{0} ** gas.species_count;
    atmosphere[0] = state.gaseous_mass_g[0] + 1;
    var flux: [gas.species_count]f64 = undefined;
    try calculateFluxesG(&state, .{ .cell_index = 0, .aerodynamic_conductance_m3_per_step = 0.1, .interior_conductance_m3_per_step = interior, .atmospheric_concentration_g_per_m3 = atmosphere }, 1, &flux);
    const expected_conductance = 0.1 * (0.1 * 0.74) / (0.1 + 0.1 * 0.74);
    try std.testing.expectApproxEqAbs(expected_conductance, flux[0], 1e-12);
}

test "validated atmosphere kernel is bit-identical to checked entry point" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.air_volume_m3[0] = 0.8;
    state.temperature_k[0] = 296.15;
    state.water_vapor_mol[0] = 0.01;
    for (0..gas.species_count) |species|
        state.gaseous_mass_g[species] = @as(f64, @floatFromInt(species + 1)) * 0.25;
    const boundary: Boundary = .{
        .cell_index = 0,
        .aerodynamic_conductance_m3_per_step = 0.12,
        .interior_conductance_m3_per_step = .{ 0.11, 0.13, 0.17, 0.19, 0.23, 0.29, 0.31 },
        .atmospheric_concentration_g_per_m3 = .{ 0.2, 0.001, 0.3, 0.8, 0.0001, 0.00001, 0.000001 },
        .pressure_exchange_fraction = 0.4,
    };
    var checked: [gas.species_count]f64 = undefined;
    var validated: [gas.species_count]f64 = undefined;
    try calculateFluxesG(&state, boundary, 0.125, &checked);
    try calculateFluxesGFromValidatedInputs(&state, boundary, 0.125, &validated);
    try std.testing.expectEqualSlices(f64, &checked, &validated);
}

test "boundary state_updates are atomic across runtime cells" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.gaseous_mass_g[0] = 2;
    const boundaries = [_]Boundary{.{ .cell_index = 0, .aerodynamic_conductance_m3_per_step = 1, .interior_conductance_m3_per_step = [_]f64{1} ** gas.species_count, .atmospheric_concentration_g_per_m3 = [_]f64{0} ** gas.species_count }};
    var flux = [_]f64{0} ** gas.species_count;
    flux[0] = -1;
    try state_updateFluxesG(std.testing.allocator, &state, &boundaries, &flux);
    try std.testing.expectEqual(@as(f64, 1), state.gaseous_mass_g[0]);
    flux[0] = -2;
    try std.testing.expectError(error.NegativeGasBoundaryCandidate, state_updateFluxesG(std.testing.allocator, &state, &boundaries, &flux));
    try std.testing.expectEqual(@as(f64, 1), state.gaseous_mass_g[0]);
}

test "boundary state_update rejects a sub-tolerance overdraw without clipping" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.gaseous_mass_g[0] = 1;
    const boundaries = [_]Boundary{.{ .cell_index = 0, .aerodynamic_conductance_m3_per_step = 1, .interior_conductance_m3_per_step = [_]f64{1} ** gas.species_count, .atmospheric_concentration_g_per_m3 = [_]f64{0} ** gas.species_count }};
    var flux = [_]f64{0} ** gas.species_count;
    flux[0] = -(1.0 + 1.0e-15);
    try std.testing.expectError(error.NegativeGasBoundaryCandidate, state_updateFluxesG(std.testing.allocator, &state, &boundaries, &flux));
    try std.testing.expectEqual(@as(f64, 1), state.gaseous_mass_g[0]);
}

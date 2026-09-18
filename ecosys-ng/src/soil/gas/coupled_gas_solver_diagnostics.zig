//! `coupled_gas_solver` declarations: diagnostics.
//!
//! Split out of `coupled_gas_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const gas = @import("transport.zig");
const atmosphere = @import("atmosphere_exchange.zig");
const numerics = @import("../../core/numerics.zig");
const group_misc = @import("coupled_gas_solver_misc.zig");

pub fn scaledNorm(state: []const f64, residual: []const f64, options: group_misc.Options) !f64 {
    const phase_count: usize = 3;
    if (state.len == 0 or
        state.len != residual.len or
        state.len % (phase_count * gas.species_count) != 0)
        return error.NonFiniteCoupledGasState;
    const inventory_count = state.len / phase_count;
    var maximum: f64 = 0;
    for (state, residual, 0..) |value, difference, index| {
        if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteCoupledGasState;
        maximum = @max(maximum, @abs(difference) / (group_misc.absoluteToleranceForCoordinate(options, index, inventory_count) + options.relative_tolerance * @abs(value)));
    }
    return maximum;
}

pub fn newtonMeritImproves(candidate: []const f64, candidate_residual: []const f64, options: group_misc.Options, current_maximum_scaled_residual: f64) !bool {
    if (!std.math.isFinite(current_maximum_scaled_residual) or current_maximum_scaled_residual < 0)
        return error.NonFiniteCoupledGasState;
    return try scaledNorm(candidate, candidate_residual, options) < current_maximum_scaled_residual;
}

pub fn newtonAcceptanceTarget(current_scaled_residual: f64) f64 {
    return current_scaled_residual;
}

pub fn speciesBlockMeritImproves(current: []const f64, current_residual: []const f64, candidate: []const f64, candidate_residual: []const f64, options: group_misc.Options, inventory_count: usize, species: usize, current_maximum_scaled_residual: f64) !bool {
    const current_species = try scaledSpeciesNorm(current, current_residual, options, inventory_count, species);
    const candidate_species = try scaledSpeciesNorm(candidate, candidate_residual, options, inventory_count, species);
    const candidate_global = try scaledNorm(candidate, candidate_residual, options);
    return candidate_species < current_species and candidate_global < current_maximum_scaled_residual;
}

pub fn scaledSpeciesNorm(state: []const f64, residual: []const f64, options: group_misc.Options, inventory_count: usize, active_species: usize) !f64 {
    var maximum: f64 = 0;
    for (state, residual, 0..) |value, difference, index| {
        if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteCoupledGasState;
        if ((index % inventory_count) % gas.species_count != active_species) continue;
        maximum = @max(maximum, @abs(difference) / (group_misc.absoluteToleranceForSpecies(options, active_species) + options.relative_tolerance * @abs(value)));
    }
    return maximum;
}

pub fn worstResidualSpecies(state: []const f64, residual: []const f64, options: group_misc.Options, inventory_count: usize) !usize {
    var worst_species: usize = 0;
    var worst_norm: f64 = -1;
    for (0..gas.species_count) |species| {
        const norm = try scaledSpeciesNorm(state, residual, options, inventory_count, species);
        if (norm > worst_norm) {
            worst_norm = norm;
            worst_species = species;
        }
    }
    return worst_species;
}

pub fn unconvergedSpeciesCount(
    state: []const f64,
    residual: []const f64,
    options: group_misc.Options,
    inventory_count: usize,
) !usize {
    var count: usize = 0;
    for (0..gas.species_count) |species| {
        if (try scaledSpeciesNorm(
            state,
            residual,
            options,
            inventory_count,
            species,
        ) > 1) count += 1;
    }
    return count;
}

pub fn worstResidualIndex(state: []const f64, residual: []const f64, options: group_misc.Options) !usize {
    if (state.len == 0 or state.len != residual.len) return error.NonFiniteCoupledGasState;
    var worst_index: usize = 0;
    var worst_norm: f64 = -1;
    for (state, residual, 0..) |value, difference, index| {
        if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteCoupledGasState;
        const norm = try scaledCoordinateResidual(value, difference, options, index, state.len / 3);
        if (norm > worst_norm) {
            worst_norm = norm;
            worst_index = index;
        }
    }
    return worst_index;
}

pub fn scaledCoordinateResidual(value: f64, difference: f64, options: group_misc.Options, coordinate_index: usize, inventory_count: usize) !f64 {
    if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteCoupledGasState;
    return @abs(difference) / (group_misc.absoluteToleranceForCoordinate(options, coordinate_index, inventory_count) + options.relative_tolerance * @abs(value));
}

pub fn isScaleDepletedGas(base_gas_mass_g: f64, base_dissolved_mass_g: f64, absolute_tolerance_g: f64, options: group_misc.Options) bool {
    // Active-set detection must occur before the gas coordinate reaches the
    // final nonlinear tolerance. Using `relative_tolerance * dissolved`
    // classified a gas pool at 6.8e-6 of its paired aqueous inventory as an
    // ordinary interior coordinate, bypassing the conservative two-phase
    // Newton block and leaving the fixed-point map on a donor-clamped cycle.
    // The square-root tolerance is the standard scale-separation threshold
    // for selecting the active set; it does not relax the root acceptance
    // criterion, which remains `scaledNorm <= 1`.
    const active_set_relative_scale =
        @sqrt(options.relative_tolerance);
    return base_gas_mass_g > 0 and
        base_dissolved_mass_g > 0 and
        base_gas_mass_g <=
            absolute_tolerance_g +
                active_set_relative_scale * base_dissolved_mass_g;
}

pub fn isNumericallyAtNonnegativeBound(value: f64, assembled_target: f64) bool {
    return value <= 64.0 * std.math.floatEps(f64) *
        @max(1.0, @abs(assembled_target));
}

pub fn hasUnresolvedPositiveBound(
    value: f64,
    assembled_target: f64,
    residual: f64,
) bool {
    return isNumericallyAtNonnegativeBound(value, assembled_target) and
        residual > 0;
}

pub fn requiresNonlocalConservativeBracket(
    receiver_mass_g: f64,
    donor_mass_g: f64,
    options: group_misc.Options,
) bool {
    return donor_mass_g >
        (1.0 / @sqrt(options.relative_tolerance)) *
            receiver_mass_g;
}

pub fn hasExtremeIncomingDonorResidual(
    current: []const f64,
    residual: []const f64,
    target: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    inventory_count: usize,
) bool {
    return (worstExtremeIncomingGasIndex(
        current,
        residual,
        target,
        inputs,
        options,
        inventory_count,
    ) catch return false) != null;
}

/// Select the largest unresolved gaseous residual that is trapped behind an
/// incoming, scale-separated donor face. The global worst coordinate may be
/// the paired dissolved phase; using it to select a face caused the
/// conservative safeguard to be skipped and spent the remaining NPH*NPG
/// budget on slow projected phase corrections.
pub fn worstExtremeIncomingGasIndex(
    current: []const f64,
    residual: []const f64,
    target: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    inventory_count: usize,
) !?usize {
    return selectScaleSeparatedIncomingGasIndex(
        current,
        residual,
        target,
        inputs,
        options,
        inventory_count,
        true,
    );
}

/// Multi-species face Newton does not require the scalar bracket's stronger
/// residual-greater-than-inventory condition. Its dense pressure block is
/// valid for any tolerance-unconverged positive incoming coordinate.
pub fn worstScaleSeparatedIncomingGasIndex(
    current: []const f64,
    residual: []const f64,
    target: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    inventory_count: usize,
) !?usize {
    return selectScaleSeparatedIncomingGasIndex(
        current,
        residual,
        target,
        inputs,
        options,
        inventory_count,
        false,
    );
}

fn selectScaleSeparatedIncomingGasIndex(
    current: []const f64,
    residual: []const f64,
    target: []const f64,
    inputs: group_misc.Inputs,
    options: group_misc.Options,
    inventory_count: usize,
    require_residual_larger_than_inventory: bool,
) !?usize {
    var worst_index: ?usize = null;
    var worst_norm: f64 = -1;
    for (inputs.faces) |face| {
        for (0..gas.species_count) |species| {
            const first =
                face.first_cell * gas.species_count + species;
            const second =
                face.second_cell * gas.species_count + species;
            if (first >= inventory_count or
                second >= inventory_count) return error.GasFaceCellOutOfRange;
            if (current[first] > 0 and residual[first] > 0 and
                (!require_residual_larger_than_inventory or
                    residual[first] > current[first]) and
                target[first] > current[first] and
                requiresNonlocalConservativeBracket(
                    current[first],
                    current[second],
                    options,
                ))
            {
                const norm = try scaledCoordinateResidual(
                    current[first],
                    residual[first],
                    options,
                    first,
                    inventory_count,
                );
                if (norm > worst_norm) {
                    worst_norm = norm;
                    worst_index = first;
                }
            }
            if (current[second] > 0 and residual[second] > 0 and
                (!require_residual_larger_than_inventory or
                    residual[second] > current[second]) and
                target[second] > current[second] and
                requiresNonlocalConservativeBracket(
                    current[second],
                    current[first],
                    options,
                ))
            {
                const norm = try scaledCoordinateResidual(
                    current[second],
                    residual[second],
                    options,
                    second,
                    inventory_count,
                );
                if (norm > worst_norm) {
                    worst_norm = norm;
                    worst_index = second;
                }
            }
        }
    }
    return worst_index;
}

pub fn vectorsEqual(a: []const f64, b: []const f64) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

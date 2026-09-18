const std = @import("std");

pub const State = struct {
    natural_rock_mol_per_m3: f64,
    ground_rock_mol_per_m3: f64,
    dissolved_metal_mol_per_m3: f64,
    dissolved_hydrogen_silicate_mol_per_m3: f64,
    hydrogen_mol_per_m3: f64,
};

pub const Mineral = struct {
    metal_charge: u2,
    hydrogen_silicate_mol_per_mol_metal: f64,
    solubility_product: f64,
};

pub const Rates = struct {
    natural_rock_dissolution_mol_per_m3_step: f64,
    ground_rock_dissolution_mol_per_m3_step: f64,
};

/// Translates the magnitude of SOLUTE.F lines 1895--1937. The source's
/// non-positive rock-loss rates become explicit positive dissolution extents.
pub fn calculate(state: State, mineral: Mineral, metal_activity_mol_per_m3: f64, hydrogen_activity_mol_per_m3: f64, hydrogen_silicate_concentration_mol_per_m3: f64, natural_maximum_mol_per_m3_step: f64, ground_maximum_mol_per_m3_step: f64) !Rates {
    try validate(state, mineral, metal_activity_mol_per_m3, hydrogen_activity_mol_per_m3, hydrogen_silicate_concentration_mol_per_m3, natural_maximum_mol_per_m3_step, ground_maximum_mol_per_m3_step);
    const charge: f64 = @floatFromInt(mineral.metal_charge);
    // The Fortran rate is non-positive for dissolution. ecosys-ng exposes a
    // positive dissolution extent and applies its stoichiometry explicitly.
    const hydrogen_limit = state.hydrogen_mol_per_m3 / charge;
    // Zero dissolved silicate is the exact fully undersaturated limit. Avoid
    // manufacturing infinity in Ksp*[H]^z/[H4SiO4]^r; all following bounds
    // remain finite and conservative.
    const thermodynamic_extent = if (hydrogen_silicate_concentration_mol_per_m3 == 0)
        hydrogen_limit
    else blk: {
        const equilibrium_metal_activity = mineral.solubility_product * std.math.pow(f64, hydrogen_activity_mol_per_m3, charge) /
            std.math.pow(f64, hydrogen_silicate_concentration_mol_per_m3, mineral.hydrogen_silicate_mol_per_mol_metal);
        if (!std.math.isFinite(equilibrium_metal_activity)) return error.NonFiniteSilicateEquilibrium;
        break :blk @max(0.0, equilibrium_metal_activity - metal_activity_mol_per_m3);
    };
    const natural_extent = @min(state.natural_rock_mol_per_m3, natural_maximum_mol_per_m3_step, thermodynamic_extent, hydrogen_limit);
    const remaining_hydrogen_extent = @max(0.0, hydrogen_limit - natural_extent);
    return .{
        .natural_rock_dissolution_mol_per_m3_step = natural_extent,
        .ground_rock_dissolution_mol_per_m3_step = @min(state.ground_rock_mol_per_m3, ground_maximum_mol_per_m3_step, thermodynamic_extent, remaining_hydrogen_extent),
    };
}

/// Source-order magnitude of SOLUTE.F 1908--1937. Natural and ground rock
/// losses are independently clipped against the same activity difference;
/// the source does not share an aqueous-hydrogen budget between them.
pub fn calculateSourceOrder(
    state: State,
    mineral: Mineral,
    metal_activity_mol_per_m3: f64,
    hydrogen_activity_mol_per_m3: f64,
    hydrogen_silicate_concentration_mol_per_m3: f64,
    natural_maximum_mol_per_m3_step: f64,
    ground_maximum_mol_per_m3_step: f64,
) !Rates {
    try validate(
        state,
        mineral,
        metal_activity_mol_per_m3,
        hydrogen_activity_mol_per_m3,
        hydrogen_silicate_concentration_mol_per_m3,
        natural_maximum_mol_per_m3_step,
        ground_maximum_mol_per_m3_step,
    );
    const charge: f64 = @floatFromInt(mineral.metal_charge);
    const equilibrium_activity = if (hydrogen_silicate_concentration_mol_per_m3 == 0)
        std.math.inf(f64)
    else
        mineral.solubility_product *
            std.math.pow(f64, hydrogen_activity_mol_per_m3, charge) /
            std.math.pow(
                f64,
                hydrogen_silicate_concentration_mol_per_m3,
                mineral.hydrogen_silicate_mol_per_mol_metal,
            );
    if (std.math.isNan(equilibrium_activity) or equilibrium_activity < 0)
        return error.NonFiniteSilicateEquilibrium;
    const source_loss_magnitude = @max(
        0,
        equilibrium_activity - metal_activity_mol_per_m3,
    );
    return .{
        .natural_rock_dissolution_mol_per_m3_step = @min(
            state.natural_rock_mol_per_m3,
            natural_maximum_mol_per_m3_step,
            source_loss_magnitude,
        ),
        .ground_rock_dissolution_mol_per_m3_step = @min(
            state.ground_rock_mol_per_m3,
            ground_maximum_mol_per_m3_step,
            source_loss_magnitude,
        ),
    };
}

pub fn state_update(state: *State, mineral: Mineral, rates: Rates) !void {
    try validateState(state.*);
    try validateMineral(mineral);
    if (!std.math.isFinite(rates.natural_rock_dissolution_mol_per_m3_step) or rates.natural_rock_dissolution_mol_per_m3_step < 0 or
        !std.math.isFinite(rates.ground_rock_dissolution_mol_per_m3_step) or rates.ground_rock_dissolution_mol_per_m3_step < 0)
        return error.InvalidSilicateWeatheringRate;
    var next = state.*;
    next.natural_rock_mol_per_m3 -= rates.natural_rock_dissolution_mol_per_m3_step;
    next.ground_rock_mol_per_m3 -= rates.ground_rock_dissolution_mol_per_m3_step;
    const total = rates.natural_rock_dissolution_mol_per_m3_step + rates.ground_rock_dissolution_mol_per_m3_step;
    next.dissolved_metal_mol_per_m3 += total;
    next.dissolved_hydrogen_silicate_mol_per_m3 += total * mineral.hydrogen_silicate_mol_per_mol_metal;
    next.hydrogen_mol_per_m3 -= total * @as(f64, @floatFromInt(mineral.metal_charge));
    try validateState(next);
    const metal_before = state.natural_rock_mol_per_m3 + state.ground_rock_mol_per_m3 + state.dissolved_metal_mol_per_m3;
    const metal_after = next.natural_rock_mol_per_m3 + next.ground_rock_mol_per_m3 + next.dissolved_metal_mol_per_m3;
    if (@abs(metal_after - metal_before) > 1e-12 * @max(1.0, metal_before)) return error.SilicateWeatheringConservationFailure;
    state.* = next;
}

fn validate(state: State, mineral: Mineral, metal_activity: f64, hydrogen_activity: f64, silicate: f64, natural_maximum: f64, ground_maximum: f64) !void {
    try validateState(state);
    try validateMineral(mineral);
    if (!std.math.isFinite(metal_activity) or metal_activity < 0 or !std.math.isFinite(hydrogen_activity) or hydrogen_activity <= 0 or
        !std.math.isFinite(silicate) or silicate < 0 or !std.math.isFinite(natural_maximum) or natural_maximum < 0 or
        !std.math.isFinite(ground_maximum) or ground_maximum < 0) return error.InvalidSilicateWeatheringInput;
}

test "zero dissolved silicate gives finite hydrogen and inventory bounded weathering" {
    const rates = try calculate(.{
        .natural_rock_mol_per_m3 = 0.1,
        .ground_rock_mol_per_m3 = 0.2,
        .dissolved_metal_mol_per_m3 = 0,
        .dissolved_hydrogen_silicate_mol_per_m3 = 0,
        .hydrogen_mol_per_m3 = 0.03,
    }, .{
        .metal_charge = 3,
        .hydrogen_silicate_mol_per_mol_metal = 0.75,
        .solubility_product = 1e5,
    }, 0, 0.03, 0, 0.004, 0.02);
    try std.testing.expectEqual(@as(f64, 0.004), rates.natural_rock_dissolution_mol_per_m3_step);
    try std.testing.expectEqual(@as(f64, 0.006), rates.ground_rock_dissolution_mol_per_m3_step);
}

fn validateState(state: State) !void {
    inline for (@typeInfo(State).@"struct".fields) |field| {
        const value = @field(state, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteSilicateWeatheringState;
        if (value < 0) return error.NegativeSilicateWeatheringState;
    }
}

fn validateMineral(mineral: Mineral) !void {
    if (mineral.metal_charge == 0 or !std.math.isFinite(mineral.hydrogen_silicate_mol_per_mol_metal) or
        mineral.hydrogen_silicate_mol_per_mol_metal <= 0 or !std.math.isFinite(mineral.solubility_product) or mineral.solubility_product <= 0)
        return error.InvalidSilicateMineral;
}

test "trivalent silicate weathering conserves metal and applies legacy stoichiometry" {
    var state = State{ .natural_rock_mol_per_m3 = 0.1, .ground_rock_mol_per_m3 = 0.05, .dissolved_metal_mol_per_m3 = 0.01, .dissolved_hydrogen_silicate_mol_per_m3 = 0.02, .hydrogen_mol_per_m3 = 0.3 };
    const mineral = Mineral{ .metal_charge = 3, .hydrogen_silicate_mol_per_mol_metal = 0.75, .solubility_product = 2 };
    const metal_before = state.natural_rock_mol_per_m3 + state.ground_rock_mol_per_m3 + state.dissolved_metal_mol_per_m3;
    const rates = try calculate(state, mineral, 0.01, 0.5, 0.2, 0.01, 0.02);
    try state_update(&state, mineral, rates);
    try std.testing.expectApproxEqAbs(metal_before, state.natural_rock_mol_per_m3 + state.ground_rock_mol_per_m3 + state.dissolved_metal_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.21), state.hydrogen_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0425), state.dissolved_hydrogen_silicate_mol_per_m3, 1e-15);
}

test "silicate weathering ceases above equilibrium activity" {
    const state = State{ .natural_rock_mol_per_m3 = 1, .ground_rock_mol_per_m3 = 1, .dissolved_metal_mol_per_m3 = 1, .dissolved_hydrogen_silicate_mol_per_m3 = 1, .hydrogen_mol_per_m3 = 1 };
    const rates = try calculate(state, .{ .metal_charge = 1, .hydrogen_silicate_mol_per_mol_metal = 0.25, .solubility_product = 0.1 }, 1, 0.1, 1, 0.1, 0.1);
    try std.testing.expectEqual(@as(f64, 0), rates.natural_rock_dissolution_mol_per_m3_step);
    try std.testing.expectEqual(@as(f64, 0), rates.ground_rock_dissolution_mol_per_m3_step);
}

test "all silicate valence classes match source weathering magnitudes" {
    const minerals = [_]Mineral{
        .{ .metal_charge = 3, .hydrogen_silicate_mol_per_mol_metal = 0.75, .solubility_product = 1.7 },
        .{ .metal_charge = 2, .hydrogen_silicate_mol_per_mol_metal = 0.50, .solubility_product = 1.3 },
        .{ .metal_charge = 1, .hydrogen_silicate_mol_per_mol_metal = 0.25, .solubility_product = 0.9 },
    };
    const state = State{
        .natural_rock_mol_per_m3 = 0.8,
        .ground_rock_mol_per_m3 = 0.6,
        .dissolved_metal_mol_per_m3 = 0.1,
        .dissolved_hydrogen_silicate_mol_per_m3 = 0.4,
        .hydrogen_mol_per_m3 = 100,
    };
    const metal_activity = 0.15;
    const hydrogen_activity = 0.7;
    const hydrogen_silicate = 0.4;
    const natural_maximum = 0.12;
    const ground_maximum = 0.08;
    for (minerals) |mineral| {
        const rates = try calculate(
            state,
            mineral,
            metal_activity,
            hydrogen_activity,
            hydrogen_silicate,
            natural_maximum,
            ground_maximum,
        );
        const charge: f64 = @floatFromInt(mineral.metal_charge);
        const equilibrium_activity = mineral.solubility_product *
            std.math.pow(f64, hydrogen_activity, charge) /
            std.math.pow(
                f64,
                hydrogen_silicate,
                mineral.hydrogen_silicate_mol_per_mol_metal,
            );
        const source_loss_magnitude =
            @max(0.0, equilibrium_activity - metal_activity);
        try std.testing.expectApproxEqAbs(
            @min(state.natural_rock_mol_per_m3, natural_maximum, source_loss_magnitude),
            rates.natural_rock_dissolution_mol_per_m3_step,
            1e-15,
        );
        try std.testing.expectApproxEqAbs(
            @min(state.ground_rock_mol_per_m3, ground_maximum, source_loss_magnitude),
            rates.ground_rock_dissolution_mol_per_m3_step,
            1e-15,
        );
    }
}

test "source-order natural and ground weathering have independent limits" {
    const state = State{
        .natural_rock_mol_per_m3 = 0.8,
        .ground_rock_mol_per_m3 = 0.6,
        .dissolved_metal_mol_per_m3 = 0.1,
        .dissolved_hydrogen_silicate_mol_per_m3 = 0.4,
        .hydrogen_mol_per_m3 = 0.003,
    };
    const mineral = Mineral{
        .metal_charge = 3,
        .hydrogen_silicate_mol_per_mol_metal = 0.75,
        .solubility_product = 10,
    };
    const source = try calculateSourceOrder(
        state,
        mineral,
        0.1,
        0.7,
        0.4,
        0.12,
        0.08,
    );
    try std.testing.expectEqual(@as(f64, 0.12), source.natural_rock_dissolution_mol_per_m3_step);
    try std.testing.expectEqual(@as(f64, 0.08), source.ground_rock_dissolution_mol_per_m3_step);

    const conservative = try calculate(
        state,
        mineral,
        0.1,
        0.7,
        0.4,
        0.12,
        0.08,
    );
    try std.testing.expectEqual(@as(f64, 0.001), conservative.natural_rock_dissolution_mol_per_m3_step);
    try std.testing.expectEqual(@as(f64, 0), conservative.ground_rock_dissolution_mol_per_m3_step);
}

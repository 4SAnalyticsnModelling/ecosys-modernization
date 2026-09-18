const std = @import("std");

pub const MineralExtents = struct {
    gibbsite_precipitation_mol_per_m3: f64,
    iron_hydroxide_precipitation_mol_per_m3: f64,
    calcite_precipitation_mol_per_m3: f64,
    gypsum_precipitation_mol_per_m3: f64,
};

pub const WeatheringExtents = struct {
    aluminum_natural_mol_per_m3: f64,
    aluminum_ground_mol_per_m3: f64,
    iron_natural_mol_per_m3: f64,
    iron_ground_mol_per_m3: f64,
    calcium_natural_mol_per_m3: f64,
    calcium_ground_mol_per_m3: f64,
    magnesium_natural_mol_per_m3: f64,
    magnesium_ground_mol_per_m3: f64,
    sodium_natural_mol_per_m3: f64,
    sodium_ground_mol_per_m3: f64,
    potassium_natural_mol_per_m3: f64,
    potassium_ground_mol_per_m3: f64,
};

pub const Transformations = struct {
    dissolved_aluminum_mol_per_m3: f64,
    dissolved_iron_mol_per_m3: f64,
    dissolved_calcium_mol_per_m3: f64,
    dissolved_magnesium_mol_per_m3: f64,
    dissolved_sodium_mol_per_m3: f64,
    dissolved_potassium_mol_per_m3: f64,
    dissolved_hydrogen_mol_per_m3: f64,
    dissolved_hydroxide_mol_per_m3: f64,
    dissolved_carbonate_mol_per_m3: f64,
    dissolved_sulfate_mol_per_m3: f64,
    dissolved_hydrogen_silicate_mol_per_m3: f64,
    gibbsite_solid_mol_per_m3: f64,
    iron_hydroxide_solid_mol_per_m3: f64,
    calcite_solid_mol_per_m3: f64,
    gypsum_solid_mol_per_m3: f64,
    aluminum_natural_silicate_mol_per_m3: f64,
    aluminum_ground_silicate_mol_per_m3: f64,
    iron_natural_silicate_mol_per_m3: f64,
    iron_ground_silicate_mol_per_m3: f64,
    calcium_natural_silicate_mol_per_m3: f64,
    calcium_ground_silicate_mol_per_m3: f64,
    magnesium_natural_silicate_mol_per_m3: f64,
    magnesium_ground_silicate_mol_per_m3: f64,
    sodium_natural_silicate_mol_per_m3: f64,
    sodium_ground_silicate_mol_per_m3: f64,
    potassium_natural_silicate_mol_per_m3: f64,
    potassium_ground_silicate_mol_per_m3: f64,
};

pub const SolidState = struct {
    gibbsite_solid_mol_per_m3: f64,
    iron_hydroxide_solid_mol_per_m3: f64,
    calcite_solid_mol_per_m3: f64,
    gypsum_solid_mol_per_m3: f64,
    aluminum_natural_silicate_mol_per_m3: f64,
    aluminum_ground_silicate_mol_per_m3: f64,
    iron_natural_silicate_mol_per_m3: f64,
    iron_ground_silicate_mol_per_m3: f64,
    calcium_natural_silicate_mol_per_m3: f64,
    calcium_ground_silicate_mol_per_m3: f64,
    magnesium_natural_silicate_mol_per_m3: f64,
    magnesium_ground_silicate_mol_per_m3: f64,
    sodium_natural_silicate_mol_per_m3: f64,
    sodium_ground_silicate_mol_per_m3: f64,
    potassium_natural_silicate_mol_per_m3: f64,
    potassium_ground_silicate_mol_per_m3: f64,
};

pub const SourceIterationStage = enum {
    before_iteration_ceiling,
    iteration_ceiling,
};

pub fn state_updateSolids(state: *SolidState, transformations: Transformations) !void {
    try validateSolidState(state.*);
    var next = state.*;
    inline for (@typeInfo(SolidState).@"struct".fields) |field| {
        const change = @field(transformations, field.name);
        if (!std.math.isFinite(change)) return error.NonFiniteGeochemistryTransformation;
        @field(next, field.name) += change;
    }
    try validateSolidState(next);
    state.* = next;
}

/// Reconstructs the aqueous half of a geochemistry transaction from the
/// solid deltas that were actually representable in `f64` storage.  A small
/// requested extent can round when it is added to a much larger mineral or
/// natural-rock pool; publishing the unrounded aqueous extent in that case
/// creates or destroys element inventory.  The returned transaction retains
/// the exact stored solid deltas and applies the source stoichiometry to those
/// deltas, so the concentration-state update remains conservative without a
/// physical-unit tolerance or a compensating ledger.
pub fn transformationsForRealizedSolidUpdate(
    before: SolidState,
    after: SolidState,
) !Transformations {
    try validateSolidState(before);
    try validateSolidState(after);

    var result = std.mem.zeroes(Transformations);
    inline for (@typeInfo(SolidState).@"struct".fields) |field| {
        const change = @field(after, field.name) - @field(before, field.name);
        if (!std.math.isFinite(change))
            return error.NonFiniteGeochemistryTransformation;
        @field(result, field.name) = change;
    }

    const aluminum_silicate = result.aluminum_natural_silicate_mol_per_m3 +
        result.aluminum_ground_silicate_mol_per_m3;
    const iron_silicate = result.iron_natural_silicate_mol_per_m3 +
        result.iron_ground_silicate_mol_per_m3;
    const calcium_silicate = result.calcium_natural_silicate_mol_per_m3 +
        result.calcium_ground_silicate_mol_per_m3;
    const magnesium_silicate = result.magnesium_natural_silicate_mol_per_m3 +
        result.magnesium_ground_silicate_mol_per_m3;
    const sodium_silicate = result.sodium_natural_silicate_mol_per_m3 +
        result.sodium_ground_silicate_mol_per_m3;
    const potassium_silicate = result.potassium_natural_silicate_mol_per_m3 +
        result.potassium_ground_silicate_mol_per_m3;

    result.dissolved_aluminum_mol_per_m3 =
        -(result.gibbsite_solid_mol_per_m3 + aluminum_silicate);
    result.dissolved_iron_mol_per_m3 =
        -(result.iron_hydroxide_solid_mol_per_m3 + iron_silicate);
    result.dissolved_calcium_mol_per_m3 =
        -(result.calcite_solid_mol_per_m3 +
            result.gypsum_solid_mol_per_m3 + calcium_silicate);
    result.dissolved_magnesium_mol_per_m3 = -magnesium_silicate;
    result.dissolved_sodium_mol_per_m3 = -sodium_silicate;
    result.dissolved_potassium_mol_per_m3 = -potassium_silicate;
    result.dissolved_hydrogen_mol_per_m3 =
        3 * (aluminum_silicate + iron_silicate) +
        2 * (calcium_silicate + magnesium_silicate) +
        sodium_silicate + potassium_silicate;
    result.dissolved_hydroxide_mol_per_m3 =
        -3 * (result.gibbsite_solid_mol_per_m3 +
            result.iron_hydroxide_solid_mol_per_m3);
    result.dissolved_carbonate_mol_per_m3 =
        -result.calcite_solid_mol_per_m3;
    result.dissolved_sulfate_mol_per_m3 =
        -result.gypsum_solid_mol_per_m3;
    result.dissolved_hydrogen_silicate_mol_per_m3 =
        -0.75 * (aluminum_silicate + iron_silicate) -
        0.5 * (calcium_silicate + magnesium_silicate) -
        0.25 * (sodium_silicate + potassium_silicate);
    return result;
}

/// Direct silicate-pool update for SOLUTE.F 2430--2441. All twelve source
/// additions are unfloored and skipped at `M == MRXN`.
pub fn applySourceOrderSilicateUpdate(
    current: SolidState,
    transformations: Transformations,
    stage: SourceIterationStage,
) !SolidState {
    try validateSolidState(current);
    inline for (@typeInfo(Transformations).@"struct".fields) |field|
        if (!std.math.isFinite(@field(transformations, field.name)))
            return error.NonFiniteGeochemistryTransformation;
    if (stage == .iteration_ceiling) return current;

    var next = current;
    inline for (.{
        "aluminum_natural_silicate_mol_per_m3",
        "iron_natural_silicate_mol_per_m3",
        "calcium_natural_silicate_mol_per_m3",
        "magnesium_natural_silicate_mol_per_m3",
        "sodium_natural_silicate_mol_per_m3",
        "potassium_natural_silicate_mol_per_m3",
        "aluminum_ground_silicate_mol_per_m3",
        "iron_ground_silicate_mol_per_m3",
        "calcium_ground_silicate_mol_per_m3",
        "magnesium_ground_silicate_mol_per_m3",
        "sodium_ground_silicate_mol_per_m3",
        "potassium_ground_silicate_mol_per_m3",
    }) |name| {
        @field(next, name) = @field(current, name) +
            @field(transformations, name);
        if (!std.math.isFinite(@field(next, name)) or @field(next, name) < 0)
            return error.InvalidGeochemistrySilicateStateUpdate;
    }
    return next;
}

fn validateSolidState(state: SolidState) !void {
    inline for (@typeInfo(SolidState).@"struct".fields) |field| {
        const value = @field(state, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteGeochemistrySolidState;
        if (value < 0) return error.NegativeGeochemistrySolidState;
    }
}

pub fn assemble(minerals: MineralExtents, weathering: WeatheringExtents) !Transformations {
    inline for (@typeInfo(MineralExtents).@"struct".fields) |field| if (!std.math.isFinite(@field(minerals, field.name))) return error.NonFiniteMineralExtent;
    inline for (@typeInfo(WeatheringExtents).@"struct".fields) |field| {
        const extent = @field(weathering, field.name);
        if (!std.math.isFinite(extent) or extent < 0) return error.InvalidWeatheringExtent;
    }
    const aluminum_weathering = weathering.aluminum_natural_mol_per_m3 + weathering.aluminum_ground_mol_per_m3;
    const iron_weathering = weathering.iron_natural_mol_per_m3 + weathering.iron_ground_mol_per_m3;
    const calcium_weathering = weathering.calcium_natural_mol_per_m3 + weathering.calcium_ground_mol_per_m3;
    const magnesium_weathering = weathering.magnesium_natural_mol_per_m3 + weathering.magnesium_ground_mol_per_m3;
    const sodium_weathering = weathering.sodium_natural_mol_per_m3 + weathering.sodium_ground_mol_per_m3;
    const potassium_weathering = weathering.potassium_natural_mol_per_m3 + weathering.potassium_ground_mol_per_m3;
    return .{
        .dissolved_aluminum_mol_per_m3 = aluminum_weathering - minerals.gibbsite_precipitation_mol_per_m3,
        .dissolved_iron_mol_per_m3 = iron_weathering - minerals.iron_hydroxide_precipitation_mol_per_m3,
        .dissolved_calcium_mol_per_m3 = calcium_weathering - minerals.calcite_precipitation_mol_per_m3 - minerals.gypsum_precipitation_mol_per_m3,
        .dissolved_magnesium_mol_per_m3 = magnesium_weathering,
        .dissolved_sodium_mol_per_m3 = sodium_weathering,
        .dissolved_potassium_mol_per_m3 = potassium_weathering,
        .dissolved_hydrogen_mol_per_m3 = -3 * (aluminum_weathering + iron_weathering) - 2 * (calcium_weathering + magnesium_weathering) - sodium_weathering - potassium_weathering,
        .dissolved_hydroxide_mol_per_m3 = -3 * (minerals.gibbsite_precipitation_mol_per_m3 + minerals.iron_hydroxide_precipitation_mol_per_m3),
        .dissolved_carbonate_mol_per_m3 = -minerals.calcite_precipitation_mol_per_m3,
        .dissolved_sulfate_mol_per_m3 = -minerals.gypsum_precipitation_mol_per_m3,
        .dissolved_hydrogen_silicate_mol_per_m3 = 0.75 * (aluminum_weathering + iron_weathering) + 0.5 * (calcium_weathering + magnesium_weathering) + 0.25 * (sodium_weathering + potassium_weathering),
        .gibbsite_solid_mol_per_m3 = minerals.gibbsite_precipitation_mol_per_m3,
        .iron_hydroxide_solid_mol_per_m3 = minerals.iron_hydroxide_precipitation_mol_per_m3,
        .calcite_solid_mol_per_m3 = minerals.calcite_precipitation_mol_per_m3,
        .gypsum_solid_mol_per_m3 = minerals.gypsum_precipitation_mol_per_m3,
        .aluminum_natural_silicate_mol_per_m3 = -weathering.aluminum_natural_mol_per_m3,
        .aluminum_ground_silicate_mol_per_m3 = -weathering.aluminum_ground_mol_per_m3,
        .iron_natural_silicate_mol_per_m3 = -weathering.iron_natural_mol_per_m3,
        .iron_ground_silicate_mol_per_m3 = -weathering.iron_ground_mol_per_m3,
        .calcium_natural_silicate_mol_per_m3 = -weathering.calcium_natural_mol_per_m3,
        .calcium_ground_silicate_mol_per_m3 = -weathering.calcium_ground_mol_per_m3,
        .magnesium_natural_silicate_mol_per_m3 = -weathering.magnesium_natural_mol_per_m3,
        .magnesium_ground_silicate_mol_per_m3 = -weathering.magnesium_ground_mol_per_m3,
        .sodium_natural_silicate_mol_per_m3 = -weathering.sodium_natural_mol_per_m3,
        .sodium_ground_silicate_mol_per_m3 = -weathering.sodium_ground_mol_per_m3,
        .potassium_natural_silicate_mol_per_m3 = -weathering.potassium_natural_mol_per_m3,
        .potassium_ground_silicate_mol_per_m3 = -weathering.potassium_ground_mol_per_m3,
    };
}

test "shared mineral and weathering ledger conserves all metals" {
    const transformations = try assemble(.{ .gibbsite_precipitation_mol_per_m3 = 0.01, .iron_hydroxide_precipitation_mol_per_m3 = -0.02, .calcite_precipitation_mol_per_m3 = 0.03, .gypsum_precipitation_mol_per_m3 = -0.01 }, .{ .aluminum_natural_mol_per_m3 = 0.001, .aluminum_ground_mol_per_m3 = 0.002, .iron_natural_mol_per_m3 = 0.003, .iron_ground_mol_per_m3 = 0.004, .calcium_natural_mol_per_m3 = 0.005, .calcium_ground_mol_per_m3 = 0.006, .magnesium_natural_mol_per_m3 = 0.007, .magnesium_ground_mol_per_m3 = 0.008, .sodium_natural_mol_per_m3 = 0.009, .sodium_ground_mol_per_m3 = 0.01, .potassium_natural_mol_per_m3 = 0.011, .potassium_ground_mol_per_m3 = 0.012 });
    try std.testing.expectApproxEqAbs(@as(f64, 0), transformations.dissolved_aluminum_mol_per_m3 + transformations.gibbsite_solid_mol_per_m3 + transformations.aluminum_natural_silicate_mol_per_m3 + transformations.aluminum_ground_silicate_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0), transformations.dissolved_iron_mol_per_m3 + transformations.iron_hydroxide_solid_mol_per_m3 + transformations.iron_natural_silicate_mol_per_m3 + transformations.iron_ground_silicate_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0), transformations.dissolved_calcium_mol_per_m3 + transformations.calcite_solid_mol_per_m3 + transformations.gypsum_solid_mol_per_m3 + transformations.calcium_natural_silicate_mol_per_m3 + transformations.calcium_ground_silicate_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0), transformations.dissolved_magnesium_mol_per_m3 + transformations.magnesium_natural_silicate_mol_per_m3 + transformations.magnesium_ground_silicate_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0), transformations.dissolved_sodium_mol_per_m3 + transformations.sodium_natural_silicate_mol_per_m3 + transformations.sodium_ground_silicate_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0), transformations.dissolved_potassium_mol_per_m3 + transformations.potassium_natural_silicate_mol_per_m3 + transformations.potassium_ground_silicate_mol_per_m3, 1e-14);
}

test "geochemistry solid state_update rolls back on exhausted mineral" {
    var state: SolidState = undefined;
    inline for (@typeInfo(SolidState).@"struct".fields) |field| @field(state, field.name) = 1;
    const before = state;
    var transformations: Transformations = undefined;
    inline for (@typeInfo(Transformations).@"struct".fields) |field| @field(transformations, field.name) = 0;
    transformations.calcium_natural_silicate_mol_per_m3 = -2;
    try std.testing.expectError(error.NegativeGeochemistrySolidState, state_updateSolids(&state, transformations));
    try std.testing.expectEqualDeep(before, state);
}

test "source silicate update is unfloored and ceiling gated" {
    var current: SolidState = undefined;
    inline for (@typeInfo(SolidState).@"struct".fields) |field|
        @field(current, field.name) = 1;
    var changes: Transformations = undefined;
    inline for (@typeInfo(Transformations).@"struct".fields) |field|
        @field(changes, field.name) = 0;
    changes.aluminum_natural_silicate_mol_per_m3 = -1;
    changes.potassium_ground_silicate_mol_per_m3 = 0.25;

    const terminal = try applySourceOrderSilicateUpdate(
        current,
        changes,
        .iteration_ceiling,
    );
    try std.testing.expectEqualDeep(current, terminal);

    const continuing = try applySourceOrderSilicateUpdate(
        current,
        changes,
        .before_iteration_ceiling,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        continuing.aluminum_natural_silicate_mol_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 1.25),
        continuing.potassium_ground_silicate_mol_per_m3,
    );
}

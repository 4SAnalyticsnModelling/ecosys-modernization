const std = @import("std");

// DUPLICATE OWNER, do not bind. This is a faithful translation of
// startq.f 113--285 (CFOPC/CFOPN/CFOPP), but plant/partition/litter.zig is
// the bound production owner of exactly that block. Binding this too would
// initialize the same six-by-four litter fractions twice; whichever ran
// second would silently win, with no non-finite value or conservation
// residual to reveal it. Note also that the trait names differ between the
// two modules: `growth_type` here is IGTYP (`root_profile_type` there) and
// `woody_type` here is IBTYP (`aboveground_turnover_type` there).
// Retained for its explicit runtime-profile parameterization and pinned to
// the bound owner by the equivalence guard below. See
// docs/traceability/a8a_litter_kinetic_partition_duplicate_owner.md.

pub const Traits = struct {
    growth_type: i32,
    nitrogen_fixation_type: i32,
    woody_type: i32,
};

pub const Profiles = struct {
    nonstructural: []const f64,
    nonvascular: []const f64,
    legume_foliar: []const f64,
    legume_nonfoliar: []const f64,
    herbaceous_foliar: []const f64,
    herbaceous_nonfoliar: []const f64,
    deciduous_foliar: []const f64,
    woody_nonfoliar: []const f64,
    conifer_foliar: []const f64,
    herbaceous_stalk: []const f64,
    herbaceous_root: []const f64,
    deciduous_root: []const f64,
    conifer_root: []const f64,
    coarse_wood: []const f64,
    nitrogen_weights: []const f64,
    phosphorus_weights: []const f64,
};

pub const Output = struct {
    organ_count: usize,
    component_count: usize,
    carbon_fraction: []f64,
    nitrogen_fraction: []f64,
    phosphorus_fraction: []f64,
};

pub const InitializationError = error{
    InsufficientOrganCount,
    ComponentCountMismatch,
    OutputExtentMismatch,
    NonFiniteFraction,
    NegativeFraction,
    InvalidCarbonFractionSum,
    ZeroNutrientDenominator,
    ExtentOverflow,
};

/// Translates `startq.f` lines 113--285.
///
/// Organ indexes retain STARTQ order: nonstructural, foliar, non-foliar,
/// stalk, fine root, and coarse wood. Kinetic-component count is runtime.
pub fn initialize(
    traits: Traits,
    profiles: Profiles,
    output: Output,
) InitializationError!void {
    if (output.organ_count < 6) return error.InsufficientOrganCount;
    const component_count = output.component_count;
    inline for (std.meta.fields(Profiles)) |field| {
        if (@field(profiles, field.name).len != component_count) {
            return error.ComponentCountMismatch;
        }
    }
    const extent = std.math.mul(usize, output.organ_count, component_count) catch
        return error.ExtentOverflow;
    if (output.carbon_fraction.len != extent or output.nitrogen_fraction.len != extent or
        output.phosphorus_fraction.len != extent)
    {
        return error.OutputExtentMismatch;
    }
    try validateProfiles(profiles);

    copyOrgan(output, 0, profiles.nonstructural);
    if (traits.growth_type == 0) {
        copyOrgan(output, 1, profiles.nonvascular);
        copyOrgan(output, 2, profiles.nonvascular);
    } else if (traits.nitrogen_fixation_type != 0) {
        copyOrgan(output, 1, profiles.legume_foliar);
        copyOrgan(output, 2, profiles.legume_nonfoliar);
    } else if (traits.woody_type == 0 or traits.growth_type <= 1) {
        copyOrgan(output, 1, profiles.herbaceous_foliar);
        copyOrgan(output, 2, profiles.herbaceous_nonfoliar);
    } else if (traits.woody_type == 1 or traits.woody_type >= 3) {
        copyOrgan(output, 1, profiles.deciduous_foliar);
        copyOrgan(output, 2, profiles.woody_nonfoliar);
    } else {
        copyOrgan(output, 1, profiles.conifer_foliar);
        copyOrgan(output, 2, profiles.woody_nonfoliar);
    }

    if (traits.growth_type == 0) {
        copyOrgan(output, 3, profiles.nonvascular);
    } else if (traits.woody_type == 0 or traits.growth_type <= 1) {
        copyOrgan(output, 3, profiles.herbaceous_stalk);
    } else {
        copyOrgan(output, 3, profiles.coarse_wood);
    }
    if (traits.growth_type == 0) {
        copyOrgan(output, 4, profiles.nonvascular);
    } else if (traits.woody_type == 0 or traits.growth_type <= 1) {
        copyOrgan(output, 4, profiles.herbaceous_root);
    } else if (traits.woody_type == 1 or traits.woody_type >= 3) {
        copyOrgan(output, 4, profiles.deciduous_root);
    } else {
        copyOrgan(output, 4, profiles.conifer_root);
    }
    copyOrgan(output, 5, profiles.coarse_wood);

    for (0..6) |organ| {
        var nitrogen_denominator: f64 = 0.0;
        var phosphorus_denominator: f64 = 0.0;
        for (0..component_count) |component| {
            const index = organ * component_count + component;
            nitrogen_denominator +=
                output.carbon_fraction[index] * profiles.nitrogen_weights[component];
            phosphorus_denominator +=
                output.carbon_fraction[index] * profiles.phosphorus_weights[component];
        }
        if (nitrogen_denominator <= 0.0 or phosphorus_denominator <= 0.0) {
            return error.ZeroNutrientDenominator;
        }
        for (0..component_count) |component| {
            const index = organ * component_count + component;
            output.nitrogen_fraction[index] =
                output.carbon_fraction[index] * profiles.nitrogen_weights[component] /
                nitrogen_denominator;
            output.phosphorus_fraction[index] =
                output.carbon_fraction[index] * profiles.phosphorus_weights[component] /
                phosphorus_denominator;
        }
    }
}

fn copyOrgan(output: Output, organ: usize, profile: []const f64) void {
    const start = organ * output.component_count;
    @memcpy(output.carbon_fraction[start .. start + output.component_count], profile);
}

fn validateProfiles(profiles: Profiles) InitializationError!void {
    inline for (std.meta.fields(Profiles)) |field| {
        const values = @field(profiles, field.name);
        var sum: f64 = 0.0;
        for (values) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteFraction;
            if (value < 0.0) return error.NegativeFraction;
            sum += value;
        }
        if (!std.mem.eql(u8, field.name, "nitrogen_weights") and
            !std.mem.eql(u8, field.name, "phosphorus_weights") and
            @abs(sum - 1.0) > 1.0e-12)
        {
            return error.InvalidCarbonFractionSum;
        }
    }
}

test "legume profiles and nutrient normalization preserve STARTQ order" {
    const profiles = legacyProfiles();
    var carbon: [24]f64 = undefined;
    var nitrogen: [24]f64 = undefined;
    var phosphorus: [24]f64 = undefined;
    try initialize(.{
        .growth_type = 2,
        .nitrogen_fixation_type = 1,
        .woody_type = 0,
    }, profiles, .{
        .organ_count = 6,
        .component_count = 4,
        .carbon_fraction = &carbon,
        .nitrogen_fraction = &nitrogen,
        .phosphorus_fraction = &phosphorus,
    });

    try std.testing.expectEqualSlices(f64, profiles.legume_foliar, carbon[4..8]);
    try std.testing.expectEqualSlices(f64, profiles.legume_nonfoliar, carbon[8..12]);
    for (0..6) |organ| {
        var nitrogen_sum: f64 = 0.0;
        var phosphorus_sum: f64 = 0.0;
        for (0..4) |component| {
            nitrogen_sum += nitrogen[organ * 4 + component];
            phosphorus_sum += phosphorus[organ * 4 + component];
        }
        try std.testing.expectApproxEqAbs(1.0, nitrogen_sum, 1.0e-14);
        try std.testing.expectApproxEqAbs(1.0, phosphorus_sum, 1.0e-14);
    }
}

test "runtime component extent is accepted" {
    const unit = [_]f64{1.0};
    const profiles = Profiles{
        .nonstructural = &unit,
        .nonvascular = &unit,
        .legume_foliar = &unit,
        .legume_nonfoliar = &unit,
        .herbaceous_foliar = &unit,
        .herbaceous_nonfoliar = &unit,
        .deciduous_foliar = &unit,
        .woody_nonfoliar = &unit,
        .conifer_foliar = &unit,
        .herbaceous_stalk = &unit,
        .herbaceous_root = &unit,
        .deciduous_root = &unit,
        .conifer_root = &unit,
        .coarse_wood = &unit,
        .nitrogen_weights = &unit,
        .phosphorus_weights = &unit,
    };
    var carbon: [6]f64 = undefined;
    var nitrogen: [6]f64 = undefined;
    var phosphorus: [6]f64 = undefined;
    try initialize(.{ .growth_type = 0, .nitrogen_fixation_type = 0, .woody_type = 0 }, profiles, .{
        .organ_count = 6,
        .component_count = 1,
        .carbon_fraction = &carbon,
        .nitrogen_fraction = &nitrogen,
        .phosphorus_fraction = &phosphorus,
    });
    try std.testing.expectEqualSlices(f64, &.{ 1, 1, 1, 1, 1, 1 }, &carbon);
}

test "STARTQ CFOPC agrees with the bound plant/partition/litter owner on every trait branch" {
    // Pin-the-pair equivalence guard. Both modules translate the same
    // startq.f 113--285 CFOPC/CFOPN/CFOPP block: this one is unbound and
    // parameterized on caller-supplied profiles, and
    // plant/partition/litter.zig is the bound production owner with the table
    // hardcoded. Binding this module as-is would double-initialize the same
    // fractions, so it stays unbound; the guard exists so that if either
    // table is ever edited alone, the disagreement surfaces here instead of
    // as a litter-chemistry drift far downstream. See
    // docs/traceability/a8a_litter_kinetic_partition_duplicate_owner.md.
    //
    // Deliberately exhaustive over the three traits the source branches on
    // rather than spot-checking: the branches are ordered and overlapping
    // (`IBTYP.EQ.0 .OR. IGTYP.LE.1` before `IBTYP.EQ.1 .OR. IBTYP.GE.3`), so
    // a mismatch in branch *order* only shows on a combination that two
    // separate arms could claim.
    const bound = @import("../partition/litter.zig");
    const parameters = @import("seed_and_population.zig").compatibilityStandingDeadPartitionParameters();
    const profiles = legacyProfiles();

    for (0..5) |growth_type| for (0..2) |nitrogen_fixation_type| for (0..5) |woody_type| {
        var carbon: [24]f64 = undefined;
        var nitrogen: [24]f64 = undefined;
        var phosphorus: [24]f64 = undefined;
        try initialize(.{
            .growth_type = @intCast(growth_type),
            .nitrogen_fixation_type = @intCast(nitrogen_fixation_type),
            .woody_type = @intCast(woody_type),
        }, profiles, .{
            .organ_count = 6,
            .component_count = 4,
            .carbon_fraction = &carbon,
            .nitrogen_fraction = &nitrogen,
            .phosphorus_fraction = &phosphorus,
        });

        // growth_type is IGTYP (root_profile_type) and woody_type is IBTYP
        // (aboveground_turnover_type). The two modules name these differently,
        // which is exactly the kind of swap this guard is here to catch.
        var traits = std.mem.zeroes(@import("../../state/plant_traits.zig").PlantTraits);
        traits.functional_type.root_profile_type = @intCast(growth_type);
        traits.functional_type.nitrogen_fixation_type = @intCast(nitrogen_fixation_type);
        traits.functional_type.aboveground_turnover_type = @intCast(woody_type);
        const expected = bound.carbonFractions(traits, parameters);

        for (expected, 0..) |organ_fractions, organ| {
            try std.testing.expectEqualSlices(f64, &organ_fractions, carbon[organ * 4 .. organ * 4 + 4]);
        }

        // Carbon alone is not the whole of the shared block. Both modules also
        // derive the CFOPN/CFOPP nutrient fractions from the same carbon
        // fractions by the identical normalized-weighted form (here
        // `:135--140`, the owner via `withNutrients`/`normalizedWeighted` at
        // `plant/partition/litter.zig:119--124`), and the owner's weights at
        // `plant/initialization/seed_and_population.zig:122--123` are the same
        // numbers as `legacyProfiles().nitrogen_weights`/`phosphorus_weights`.
        // Pinning only carbon would let a divergence in either normalization,
        // or a silent edit to one weight table, pass this guard while still
        // being a real difference between two translations of
        // `startq.f:113--285`.
        var owner_state = try bound.State.init(std.testing.allocator, 1);
        defer owner_state.deinit();
        try owner_state.initializePlant(0, traits, parameters);
        for (0..6) |organ| {
            const owner = try owner_state.get(0, @enumFromInt(organ));
            try std.testing.expectEqualSlices(f64, &owner.carbon, carbon[organ * 4 .. organ * 4 + 4]);
            try std.testing.expectEqualSlices(f64, &owner.nitrogen, nitrogen[organ * 4 .. organ * 4 + 4]);
            try std.testing.expectEqualSlices(f64, &owner.phosphorus, phosphorus[organ * 4 .. organ * 4 + 4]);
        }
    };
}

fn legacyProfiles() Profiles {
    return .{
        .nonstructural = &.{ 0.00, 1.00, 0.00, 0.00 },
        .nonvascular = &.{ 0.07, 0.25, 0.30, 0.38 },
        .legume_foliar = &.{ 0.16, 0.38, 0.34, 0.12 },
        .legume_nonfoliar = &.{ 0.07, 0.41, 0.37, 0.15 },
        .herbaceous_foliar = &.{ 0.08, 0.41, 0.36, 0.15 },
        .herbaceous_nonfoliar = &.{ 0.07, 0.41, 0.36, 0.16 },
        .deciduous_foliar = &.{ 0.07, 0.34, 0.36, 0.23 },
        .woody_nonfoliar = &.{ 0.000, 0.045, 0.660, 0.295 },
        .conifer_foliar = &.{ 0.07, 0.25, 0.38, 0.30 },
        .herbaceous_stalk = &.{ 0.03, 0.25, 0.57, 0.15 },
        .herbaceous_root = &.{ 0.057, 0.263, 0.542, 0.138 },
        .deciduous_root = &.{ 0.059, 0.308, 0.464, 0.169 },
        .conifer_root = &.{ 0.07, 0.25, 0.38, 0.30 },
        .coarse_wood = &.{ 0.00, 0.045, 0.660, 0.295 },
        .nitrogen_weights = &.{ 0.020, 0.010, 0.010, 0.020 },
        .phosphorus_weights = &.{ 0.0020, 0.0010, 0.0010, 0.0020 },
    };
}

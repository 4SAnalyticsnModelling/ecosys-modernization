// **PRODUCTION BOUND.** GROSUB 2730--2743's ordered woody then sheath C/N/P
// publication is called into transaction-local accumulators by the selected-
// node production path before its atomic commit.
const std = @import("std");

pub const ElementSlices = struct {
    carbon: []const f64,
    nitrogen: []const f64,
    phosphorus: []const f64,
};

pub const Kinetics = struct {
    woody: ElementSlices,
    sheath: ElementSlices,
};

pub const ElementAccumulators = struct {
    carbon_g_c: []f64,
    nitrogen_g_n: []f64,
    phosphorus_g_p: []f64,
};

pub const Accumulators = struct {
    woody: ElementAccumulators,
    sheath: ElementAccumulators,
};

pub const Snapshot = struct {
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
    remobilizable_carbon_g_c: f64,
    remobilizable_nitrogen_g_n: f64,
    remobilizable_phosphorus_g_p: f64,
    remobilization_fraction: f64,
};

pub const Composition = struct {
    carbon: [2]f64,
    nitrogen: [2]f64,
    phosphorus: [2]f64,
};

const Addition = struct {
    woody_carbon_g_c: f64,
    woody_nitrogen_g_n: f64,
    woody_phosphorus_g_p: f64,
    sheath_carbon_g_c: f64,
    sheath_nitrogen_g_n: f64,
    sheath_phosphorus_g_p: f64,
};

/// grosub.f lines 2730--2743. Publishes sheath/petiole litter into a runtime
/// number of kinetic pools, in exact woody C/N/P then sheath C/N/P source order.
pub fn publish(snapshot: Snapshot, composition: Composition, kinetics: Kinetics, output: Accumulators) !void {
    const count = kinetics.woody.carbon.len;
    if (count == 0) return error.ZeroSheathSenescenceKineticPools;
    try validateDimensions(kinetics, output, count);
    try validateInputs(snapshot, composition, kinetics);
    for (0..count) |pool| {
        const addition = additions(snapshot, composition, kinetics, pool);
        inline for (.{
            .{ output.woody.carbon_g_c[pool], addition.woody_carbon_g_c },
            .{ output.woody.nitrogen_g_n[pool], addition.woody_nitrogen_g_n },
            .{ output.woody.phosphorus_g_p[pool], addition.woody_phosphorus_g_p },
            .{ output.sheath.carbon_g_c[pool], addition.sheath_carbon_g_c },
            .{ output.sheath.nitrogen_g_n[pool], addition.sheath_nitrogen_g_n },
            .{ output.sheath.phosphorus_g_p[pool], addition.sheath_phosphorus_g_p },
        }) |pair| if (!std.math.isFinite(pair[0]) or pair[0] < 0 or
            !std.math.isFinite(pair[0] + pair[1]) or pair[0] + pair[1] < 0)
            return error.NonFiniteSheathSenescenceLitterResult;
    }
    for (0..count) |pool| {
        const addition = additions(snapshot, composition, kinetics, pool);
        output.woody.carbon_g_c[pool] += addition.woody_carbon_g_c;
        output.woody.nitrogen_g_n[pool] += addition.woody_nitrogen_g_n;
        output.woody.phosphorus_g_p[pool] += addition.woody_phosphorus_g_p;
        output.sheath.carbon_g_c[pool] += addition.sheath_carbon_g_c;
        output.sheath.nitrogen_g_n[pool] += addition.sheath_nitrogen_g_n;
        output.sheath.phosphorus_g_p[pool] += addition.sheath_phosphorus_g_p;
    }
}

fn validateDimensions(kinetics: Kinetics, output: Accumulators, count: usize) !void {
    inline for (.{ kinetics.woody, kinetics.sheath }) |family|
        inline for (@typeInfo(ElementSlices).@"struct".fields) |field|
            if (@field(family, field.name).len != count)
                return error.SheathSenescenceKineticDimensionMismatch;
    inline for (.{ output.woody, output.sheath }) |family|
        inline for (@typeInfo(ElementAccumulators).@"struct".fields) |field|
            if (@field(family, field.name).len != count)
                return error.SheathSenescenceKineticDimensionMismatch;
}

fn validateInputs(snapshot: Snapshot, composition: Composition, kinetics: Kinetics) !void {
    inline for (@typeInfo(Snapshot).@"struct".fields) |field| {
        const value = @field(snapshot, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSheathSenescenceLitterSnapshot;
    }
    if (snapshot.remobilization_fraction > 1 or
        snapshot.remobilizable_carbon_g_c > snapshot.carbon_g_c or
        snapshot.remobilizable_nitrogen_g_n > snapshot.nitrogen_g_n or
        snapshot.remobilizable_phosphorus_g_p > snapshot.phosphorus_g_p)
        return error.InvalidSheathSenescenceLitterSnapshot;
    inline for (.{ composition.carbon, composition.nitrogen, composition.phosphorus }) |fractions| {
        inline for (fractions) |value| if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidSheathSenescenceComposition;
        if (@abs(fractions[0] + fractions[1] - 1) > 1.0e-12)
            return error.InvalidSheathSenescenceComposition;
    }
    inline for (.{ kinetics.woody, kinetics.sheath }) |family|
        inline for (@typeInfo(ElementSlices).@"struct".fields) |field| {
            var total: f64 = 0;
            for (@field(family, field.name)) |value| {
                if (!std.math.isFinite(value) or value < 0 or value > 1)
                    return error.InvalidSheathSenescenceKineticFraction;
                total += value;
            }
            if (!std.math.isFinite(total) or @abs(total - 1) > 1.0e-12)
                return error.InvalidSheathSenescenceKineticFraction;
        };
}

fn additions(snapshot: Snapshot, composition: Composition, kinetics: Kinetics, pool: usize) Addition {
    const fraction = snapshot.remobilization_fraction;
    return .{
        .woody_carbon_g_c = kinetics.woody.carbon[pool] * fraction * snapshot.carbon_g_c * composition.carbon[0],
        .woody_nitrogen_g_n = kinetics.woody.nitrogen[pool] * fraction * snapshot.nitrogen_g_n * composition.nitrogen[0],
        .woody_phosphorus_g_p = kinetics.woody.phosphorus[pool] * fraction * snapshot.phosphorus_g_p * composition.phosphorus[0],
        .sheath_carbon_g_c = kinetics.sheath.carbon[pool] * fraction * (snapshot.carbon_g_c - snapshot.remobilizable_carbon_g_c) * composition.carbon[1],
        .sheath_nitrogen_g_n = kinetics.sheath.nitrogen[pool] * fraction * (snapshot.nitrogen_g_n - snapshot.remobilizable_nitrogen_g_n) * composition.nitrogen[1],
        .sheath_phosphorus_g_p = kinetics.sheath.phosphorus[pool] * fraction * (snapshot.phosphorus_g_p - snapshot.remobilizable_phosphorus_g_p) * composition.phosphorus[1],
    };
}

fn uniformKinetics(fractions: []const f64) Kinetics {
    const elements: ElementSlices = .{ .carbon = fractions, .nitrogen = fractions, .phosphorus = fractions };
    return .{ .woody = elements, .sheath = elements };
}

fn makeOutput(storage: *[6][5]f64, count: usize) Accumulators {
    return .{
        .woody = .{ .carbon_g_c = storage[0][0..count], .nitrogen_g_n = storage[1][0..count], .phosphorus_g_p = storage[2][0..count] },
        .sheath = .{ .carbon_g_c = storage[3][0..count], .nitrogen_g_n = storage[4][0..count], .phosphorus_g_p = storage[5][0..count] },
    };
}

const sample_snapshot: Snapshot = .{
    .carbon_g_c = 8,
    .nitrogen_g_n = 0.8,
    .phosphorus_g_p = 0.16,
    .remobilizable_carbon_g_c = 4,
    .remobilizable_nitrogen_g_n = 0.64,
    .remobilizable_phosphorus_g_p = 0.136,
    .remobilization_fraction = 0.25,
};
const sample_composition: Composition = .{
    .carbon = .{ 0.2, 0.8 },
    .nitrogen = .{ 0.1, 0.9 },
    .phosphorus = .{ 0.3, 0.7 },
};

test "GROSUB sheath partition supports runtime kinetic pool count" {
    const fractions = [_]f64{ 0.1, 0.15, 0.2, 0.25, 0.3 };
    var storage: [6][5]f64 = @splat(@splat(0));
    const output = makeOutput(&storage, fractions.len);
    try publish(sample_snapshot, sample_composition, uniformKinetics(&fractions), output);
    try std.testing.expectApproxEqAbs(0.1 * 0.25 * 8 * 0.2, output.woody.carbon_g_c[0], 1.0e-15);
    try std.testing.expectApproxEqAbs(0.3 * 0.25 * (0.8 - 0.64) * 0.9, output.sheath.nitrogen_g_n[4], 1.0e-15);
}

test "classified sheath litter closes C N P mass" {
    const fractions = [_]f64{ 0.1, 0.2, 0.3, 0.4 };
    var storage: [6][5]f64 = @splat(@splat(0));
    const output = makeOutput(&storage, fractions.len);
    try publish(sample_snapshot, sample_composition, uniformKinetics(&fractions), output);
    var totals: [3]f64 = @splat(0);
    for (0..fractions.len) |pool| {
        totals[0] += output.woody.carbon_g_c[pool] + output.sheath.carbon_g_c[pool];
        totals[1] += output.woody.nitrogen_g_n[pool] + output.sheath.nitrogen_g_n[pool];
        totals[2] += output.woody.phosphorus_g_p[pool] + output.sheath.phosphorus_g_p[pool];
    }
    try std.testing.expectApproxEqAbs(0.25 * (8 * 0.2 + (8 - 4) * 0.8), totals[0], 1.0e-15);
    try std.testing.expectApproxEqAbs(0.25 * (0.8 * 0.1 + (0.8 - 0.64) * 0.9), totals[1], 1.0e-15);
    try std.testing.expectApproxEqAbs(0.25 * (0.16 * 0.3 + (0.16 - 0.136) * 0.7), totals[2], 1.0e-15);
}

test "late overflow is atomic and malformed topology fails" {
    const fractions = [_]f64{ 1, 0, 0, 0, 0 };
    var storage: [6][5]f64 = @splat(@splat(1));
    storage[0][0] = std.math.floatMax(f64);
    var snapshot = sample_snapshot;
    snapshot.carbon_g_c = std.math.floatMax(f64);
    snapshot.remobilizable_carbon_g_c = 0;
    snapshot.remobilization_fraction = 1;
    var composition = sample_composition;
    composition.carbon = .{ 1, 0 };
    try std.testing.expectError(error.NonFiniteSheathSenescenceLitterResult, publish(snapshot, composition, uniformKinetics(&fractions), makeOutput(&storage, fractions.len)));
    try std.testing.expectEqual(@as(f64, 1), storage[1][0]);
    var malformed = uniformKinetics(&fractions);
    malformed.sheath.phosphorus = malformed.sheath.phosphorus[0..4];
    try std.testing.expectError(error.SheathSenescenceKineticDimensionMismatch, publish(sample_snapshot, sample_composition, malformed, makeOutput(&storage, fractions.len)));
}

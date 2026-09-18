const std = @import("std");
const growth_stages = @import("../lifecycle/growth_stages.zig");

pub const ElementMass = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

pub const KineticFractions = struct {
    carbon: []const f64,
    nitrogen: []const f64,
    phosphorus: []const f64,
};

pub const State = struct {
    reproductive_growth_disabled: *bool,
    litterfall_delay_h: *f64,
    husk: *ElementMass,
    ear: *ElementMass,
    grain: *ElementMass,
    potential_seed_site_count: *f64,
    seed_count: *f64,
    individual_seed_carbon_g_c: *f64,
    plant_seed_storage: *ElementMass,
    litter_carbon_g_c: []f64,
    litter_nitrogen_g_n: []f64,
    litter_phosphorus_g_p: []f64,
};

pub const Inputs = struct {
    timestep_h: f64,
    litterfall_rate_per_h: f64,
    litterfall_delay_threshold_h: f64,
    growth_habit: growth_stages.GrowthHabit,
    phenology: growth_stages.PhenologyType,
    nonfoliar_kinetics: KineticFractions,
};

/// Exact grosub.f lines 4426--4488 end-of-season reproductive turnover for one
/// runtime branch. C, N, and P masses are g C, g N, and g P; the timestep and
/// delay are h. The source M-loop order is retained. An admitted call finishes
/// turnover even when its delay update re-enables reproductive growth.
pub fn apply(state: State, inputs: Inputs) !bool {
    if (!state.reproductive_growth_disabled.*) return false;
    const kinetic_count = try validate(state, inputs);
    const fraction = inputs.litterfall_rate_per_h * inputs.timestep_h;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
        return error.InvalidReproductiveTurnoverFraction;

    const next_delay_h = state.litterfall_delay_h.* + 1.0 * inputs.timestep_h;
    if (!std.math.isFinite(next_delay_h))
        return error.NonFiniteReproductiveTurnoverResult;
    const self_seeding_annual = inputs.growth_habit == .annual and
        inputs.phenology != .evergreen;

    // Prove every destination update before performing the first mutation.
    var next_storage = state.plant_seed_storage.*;
    for (0..kinetic_count) |kinetic| {
        const husk_ear_carbon_g_c = state.husk.carbon_g_c + state.ear.carbon_g_c;
        const husk_ear_nitrogen_g_n = state.husk.nitrogen_g_n + state.ear.nitrogen_g_n;
        const husk_ear_phosphorus_g_p = state.husk.phosphorus_g_p + state.ear.phosphorus_g_p;
        const next_litter_carbon_g_c = state.litter_carbon_g_c[kinetic] +
            fraction * inputs.nonfoliar_kinetics.carbon[kinetic] *
                (husk_ear_carbon_g_c + if (self_seeding_annual) 0 else state.grain.carbon_g_c);
        const next_litter_nitrogen_g_n = state.litter_nitrogen_g_n[kinetic] +
            fraction * inputs.nonfoliar_kinetics.nitrogen[kinetic] *
                (husk_ear_nitrogen_g_n + if (self_seeding_annual) 0 else state.grain.nitrogen_g_n);
        const next_litter_phosphorus_g_p = state.litter_phosphorus_g_p[kinetic] +
            fraction * inputs.nonfoliar_kinetics.phosphorus[kinetic] *
                (husk_ear_phosphorus_g_p + if (self_seeding_annual) 0 else state.grain.phosphorus_g_p);
        inline for (.{
            next_litter_carbon_g_c,
            next_litter_nitrogen_g_n,
            next_litter_phosphorus_g_p,
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidReproductiveTurnoverResult;

        if (self_seeding_annual) {
            next_storage.carbon_g_c += fraction *
                inputs.nonfoliar_kinetics.carbon[kinetic] * state.grain.carbon_g_c;
            next_storage.nitrogen_g_n += fraction *
                inputs.nonfoliar_kinetics.nitrogen[kinetic] * state.grain.nitrogen_g_n;
            next_storage.phosphorus_g_p += fraction *
                inputs.nonfoliar_kinetics.phosphorus[kinetic] * state.grain.phosphorus_g_p;
            try validateMass(next_storage, error.InvalidReproductiveTurnoverResult);
        }
    }

    state.litterfall_delay_h.* = next_delay_h;
    if (state.litterfall_delay_h.* >= inputs.litterfall_delay_threshold_h) {
        state.reproductive_growth_disabled.* = false;
        state.litterfall_delay_h.* = 0;
    }
    for (0..kinetic_count) |kinetic| {
        state.litter_carbon_g_c[kinetic] += fraction *
            inputs.nonfoliar_kinetics.carbon[kinetic] *
            (state.husk.carbon_g_c + state.ear.carbon_g_c);
        state.litter_nitrogen_g_n[kinetic] += fraction *
            inputs.nonfoliar_kinetics.nitrogen[kinetic] *
            (state.husk.nitrogen_g_n + state.ear.nitrogen_g_n);
        state.litter_phosphorus_g_p[kinetic] += fraction *
            inputs.nonfoliar_kinetics.phosphorus[kinetic] *
            (state.husk.phosphorus_g_p + state.ear.phosphorus_g_p);
        if (self_seeding_annual) {
            state.plant_seed_storage.carbon_g_c += fraction *
                inputs.nonfoliar_kinetics.carbon[kinetic] * state.grain.carbon_g_c;
            state.plant_seed_storage.nitrogen_g_n += fraction *
                inputs.nonfoliar_kinetics.nitrogen[kinetic] * state.grain.nitrogen_g_n;
            state.plant_seed_storage.phosphorus_g_p += fraction *
                inputs.nonfoliar_kinetics.phosphorus[kinetic] * state.grain.phosphorus_g_p;
        } else {
            state.litter_carbon_g_c[kinetic] += fraction *
                inputs.nonfoliar_kinetics.carbon[kinetic] * state.grain.carbon_g_c;
            state.litter_nitrogen_g_n[kinetic] += fraction *
                inputs.nonfoliar_kinetics.nitrogen[kinetic] * state.grain.nitrogen_g_n;
            state.litter_phosphorus_g_p[kinetic] += fraction *
                inputs.nonfoliar_kinetics.phosphorus[kinetic] * state.grain.phosphorus_g_p;
        }
    }
    const remaining = 1.0 - fraction;
    state.husk.carbon_g_c = remaining * state.husk.carbon_g_c;
    state.ear.carbon_g_c = remaining * state.ear.carbon_g_c;
    state.grain.carbon_g_c = remaining * state.grain.carbon_g_c;
    state.husk.nitrogen_g_n = remaining * state.husk.nitrogen_g_n;
    state.ear.nitrogen_g_n = remaining * state.ear.nitrogen_g_n;
    state.grain.nitrogen_g_n = remaining * state.grain.nitrogen_g_n;
    state.husk.phosphorus_g_p = remaining * state.husk.phosphorus_g_p;
    state.ear.phosphorus_g_p = remaining * state.ear.phosphorus_g_p;
    state.grain.phosphorus_g_p = remaining * state.grain.phosphorus_g_p;
    state.potential_seed_site_count.* = remaining * state.potential_seed_site_count.*;
    state.seed_count.* = remaining * state.seed_count.*;
    state.individual_seed_carbon_g_c.* = remaining * state.individual_seed_carbon_g_c.*;
    return true;
}

fn validate(state: State, inputs: Inputs) !usize {
    inline for (.{
        state.litterfall_delay_h.*,
        state.potential_seed_site_count.*,
        state.seed_count.*,
        state.individual_seed_carbon_g_c.*,
        inputs.timestep_h,
        inputs.litterfall_rate_per_h,
        inputs.litterfall_delay_threshold_h,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidReproductiveTurnoverInput;
    if (inputs.timestep_h == 0)
        return error.InvalidReproductiveTurnoverInput;
    inline for (.{ state.husk.*, state.ear.*, state.grain.*, state.plant_seed_storage.* }) |mass|
        try validateMass(mass, error.InvalidReproductiveTurnoverState);

    const count = inputs.nonfoliar_kinetics.carbon.len;
    if (count == 0 or inputs.nonfoliar_kinetics.nitrogen.len != count or
        inputs.nonfoliar_kinetics.phosphorus.len != count or
        state.litter_carbon_g_c.len != count or
        state.litter_nitrogen_g_n.len != count or
        state.litter_phosphorus_g_p.len != count)
        return error.ReproductiveTurnoverDimensionMismatch;
    inline for (@typeInfo(KineticFractions).@"struct".fields) |field| {
        var total: f64 = 0;
        for (@field(inputs.nonfoliar_kinetics, field.name)) |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 1)
                return error.InvalidReproductiveTurnoverKinetics;
            total += value;
        }
        if (!std.math.isFinite(total) or @abs(total - 1) > 1.0e-12)
            return error.InvalidReproductiveTurnoverKinetics;
    }
    inline for (.{ state.litter_carbon_g_c, state.litter_nitrogen_g_n, state.litter_phosphorus_g_p }) |pool|
        for (pool) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidReproductiveTurnoverState;
    return count;
}

fn validateMass(mass: ElementMass, comptime failure: anyerror) !void {
    inline for (.{ mass.carbon_g_c, mass.nitrogen_g_n, mass.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return failure;
}

const Fixture = struct {
    disabled: bool = true,
    delay_h: f64 = 2,
    husk: ElementMass = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 },
    ear: ElementMass = .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.04 },
    grain: ElementMass = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 },
    diagnostics: [3]f64 = .{ 100, 80, 0.1 },
    storage: ElementMass = .{},
    litter: [3][4]f64 = @splat(@splat(0)),

    fn state(self: *Fixture) State {
        return .{
            .reproductive_growth_disabled = &self.disabled,
            .litterfall_delay_h = &self.delay_h,
            .husk = &self.husk,
            .ear = &self.ear,
            .grain = &self.grain,
            .potential_seed_site_count = &self.diagnostics[0],
            .seed_count = &self.diagnostics[1],
            .individual_seed_carbon_g_c = &self.diagnostics[2],
            .plant_seed_storage = &self.storage,
            .litter_carbon_g_c = &self.litter[0],
            .litter_nitrogen_g_n = &self.litter[1],
            .litter_phosphorus_g_p = &self.litter[2],
        };
    }
};

fn testInputs(growth_habit: growth_stages.GrowthHabit, phenology: growth_stages.PhenologyType) Inputs {
    const fractions = &[_]f64{ 0.1, 0.2, 0.3, 0.4 };
    return .{
        .timestep_h = 1,
        .litterfall_rate_per_h = 0.25,
        .litterfall_delay_threshold_h = 3,
        .growth_habit = growth_habit,
        .phenology = phenology,
        .nonfoliar_kinetics = .{
            .carbon = fractions,
            .nitrogen = fractions,
            .phosphorus = fractions,
        },
    };
}

test "GROSUB deciduous annual retains grain and litters husk and ear" {
    var fixture: Fixture = .{};
    try std.testing.expect(try apply(fixture.state(), testInputs(.annual, .winter_deciduous)));
    try std.testing.expect(!fixture.disabled);
    try std.testing.expectEqual(@as(f64, 0), fixture.delay_h);
    try std.testing.expectApproxEqAbs(@as(f64, 2), fixture.storage.carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), fixture.litter[0][0] + fixture.litter[0][1] + fixture.litter[0][2] + fixture.litter[0][3], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), fixture.husk.carbon_g_c + fixture.ear.carbon_g_c + fixture.grain.carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 14), fixture.storage.carbon_g_c + fixture.husk.carbon_g_c + fixture.ear.carbon_g_c +
        fixture.grain.carbon_g_c + fixture.litter[0][0] + fixture.litter[0][1] +
        fixture.litter[0][2] + fixture.litter[0][3], 1e-14);
    try std.testing.expectEqual(@as(f64, 75), fixture.diagnostics[0]);
    try std.testing.expectEqual(@as(f64, 60), fixture.diagnostics[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.075), fixture.diagnostics[2], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4), fixture.storage.nitrogen_g_n + fixture.husk.nitrogen_g_n +
        fixture.ear.nitrogen_g_n + fixture.grain.nitrogen_g_n +
        fixture.litter[1][0] + fixture.litter[1][1] + fixture.litter[1][2] +
        fixture.litter[1][3], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.14), fixture.storage.phosphorus_g_p + fixture.husk.phosphorus_g_p +
        fixture.ear.phosphorus_g_p + fixture.grain.phosphorus_g_p +
        fixture.litter[2][0] + fixture.litter[2][1] + fixture.litter[2][2] +
        fixture.litter[2][3], 1e-15);
}

test "perennial routes grain through the same runtime kinetic pools" {
    var fixture: Fixture = .{};
    try std.testing.expect(try apply(fixture.state(), testInputs(.perennial, .winter_deciduous)));
    try std.testing.expectEqual(@as(f64, 0), fixture.storage.carbon_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), fixture.litter[0][0] + fixture.litter[0][1] + fixture.litter[0][2] + fixture.litter[0][3], 1e-15);
}

test "enabled reproductive growth is strict no-op before body reads" {
    var fixture: Fixture = .{ .disabled = false, .delay_h = std.math.nan(f64) };
    try std.testing.expect(!try apply(fixture.state(), testInputs(.annual, .winter_deciduous)));
}

test "late invalid destination leaves full transaction unchanged" {
    var fixture: Fixture = .{};
    fixture.litter[2][3] = std.math.nan(f64);
    const before = fixture;
    try std.testing.expectError(
        error.InvalidReproductiveTurnoverState,
        apply(fixture.state(), testInputs(.annual, .winter_deciduous)),
    );
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&fixture));
}

test "oversized hourly fraction and kinetic mismatch fail atomically" {
    var fixture: Fixture = .{};
    var invalid = testInputs(.annual, .drought_deciduous);
    invalid.litterfall_rate_per_h = 1.01;
    try std.testing.expectError(
        error.InvalidReproductiveTurnoverFraction,
        apply(fixture.state(), invalid),
    );
    invalid = testInputs(.annual, .drought_deciduous);
    invalid.nonfoliar_kinetics.phosphorus = &.{ 0.5, 0.5 };
    try std.testing.expectError(
        error.ReproductiveTurnoverDimensionMismatch,
        apply(fixture.state(), invalid),
    );
    try std.testing.expect(fixture.disabled);
    try std.testing.expectEqual(@as(f64, 2), fixture.delay_h);
}

test "GROSUB 241-hour seasonal trajectory clears at 240 and never repeats at 241" {
    var fixture: Fixture = .{ .delay_h = 0 };
    var inputs = testInputs(.annual, .winter_deciduous);
    inputs.litterfall_rate_per_h = 2.884e-3;
    inputs.litterfall_delay_threshold_h = 240;
    const initial = fixture.husk.carbon_g_c + fixture.ear.carbon_g_c +
        fixture.grain.carbon_g_c + fixture.storage.carbon_g_c;
    for (0..239) |hour| {
        try std.testing.expect(try apply(fixture.state(), inputs));
        try std.testing.expectEqual(@as(f64, @floatFromInt(hour + 1)), fixture.delay_h);
        try std.testing.expect(fixture.disabled);
    }
    try std.testing.expect(try apply(fixture.state(), inputs));
    try std.testing.expectEqual(@as(f64, 0), fixture.delay_h);
    try std.testing.expect(!fixture.disabled);
    const after_threshold = fixture;
    try std.testing.expect(!try apply(fixture.state(), inputs));
    try std.testing.expectEqualDeep(after_threshold, fixture);
    var final = fixture.husk.carbon_g_c + fixture.ear.carbon_g_c +
        fixture.grain.carbon_g_c + fixture.storage.carbon_g_c;
    for (fixture.litter[0]) |value| final += value;
    try std.testing.expectApproxEqAbs(initial, final, 2.0e-12);
}

test "seasonal trajectory restart at hour 120 is bit-identical" {
    var continuous: Fixture = .{ .delay_h = 0 };
    var inputs = testInputs(.annual, .winter_deciduous);
    inputs.litterfall_rate_per_h = 2.884e-3;
    inputs.litterfall_delay_threshold_h = 240;
    for (0..120) |_| try std.testing.expect(try apply(continuous.state(), inputs));
    var restarted = continuous;
    for (120..241) |_| {
        _ = try apply(continuous.state(), inputs);
        _ = try apply(restarted.state(), inputs);
    }
    try std.testing.expectEqualDeep(continuous, restarted);
}

const std = @import("std");

pub const EnableStatus = enum { enabled, disabled };
pub const Elements = struct { carbon: f64, nitrogen: f64, phosphorus: f64 };
pub const Kinetics = struct { carbon: []const f64, nitrogen: []const f64, phosphorus: []const f64 };
pub const State = struct {
    husk: *Elements,
    ear: *Elements,
    grain: *Elements,
    potential_seed_site_count: *f64,
    grain_count: *f64,
    individual_grain_carbon_g_c: *f64,
    litter_carbon_g_c: []f64,
    litter_nitrogen_g_n: []f64,
    litter_phosphorus_g_p: []f64,
};
pub const Inputs = struct {
    leafout_status: EnableStatus,
    perennial: bool,
    accumulated_leafout_h: f64,
    required_leafout_h: f64,
    reproductive_litter_kinetics: Kinetics,
};

/// grosub.f lines 4302--4323. At completed perennial leafout, routes all husk,
/// ear, and grain C/N/P to runtime nonwoody litter pools in C/N/P source order;
/// clears organ C first, then N, then P, followed by grain diagnostics.
pub fn apply(state: State, inputs: Inputs) !bool {
    if (inputs.leafout_status != .enabled or !inputs.perennial or
        inputs.accumulated_leafout_h < inputs.required_leafout_h)
        return false;
    const count = try validate(state, inputs);
    const totals: Elements = .{
        .carbon = state.husk.carbon + state.ear.carbon + state.grain.carbon,
        .nitrogen = state.husk.nitrogen + state.ear.nitrogen + state.grain.nitrogen,
        .phosphorus = state.husk.phosphorus + state.ear.phosphorus + state.grain.phosphorus,
    };
    for (0..count) |kinetic| {
        inline for (.{
            state.litter_carbon_g_c[kinetic] + inputs.reproductive_litter_kinetics.carbon[kinetic] * totals.carbon,
            state.litter_nitrogen_g_n[kinetic] + inputs.reproductive_litter_kinetics.nitrogen[kinetic] * totals.nitrogen,
            state.litter_phosphorus_g_p[kinetic] + inputs.reproductive_litter_kinetics.phosphorus[kinetic] * totals.phosphorus,
        }) |updated| if (!std.math.isFinite(updated) or updated < 0)
            return error.InvalidSpringReproductiveLitterResult;
    }

    for (0..count) |kinetic| {
        state.litter_carbon_g_c[kinetic] += inputs.reproductive_litter_kinetics.carbon[kinetic] * totals.carbon;
        state.litter_nitrogen_g_n[kinetic] += inputs.reproductive_litter_kinetics.nitrogen[kinetic] * totals.nitrogen;
        state.litter_phosphorus_g_p[kinetic] += inputs.reproductive_litter_kinetics.phosphorus[kinetic] * totals.phosphorus;
    }
    state.husk.carbon = 0;
    state.ear.carbon = 0;
    state.grain.carbon = 0;
    state.husk.nitrogen = 0;
    state.ear.nitrogen = 0;
    state.grain.nitrogen = 0;
    state.husk.phosphorus = 0;
    state.ear.phosphorus = 0;
    state.grain.phosphorus = 0;
    state.potential_seed_site_count.* = 0;
    state.grain_count.* = 0;
    state.individual_grain_carbon_g_c.* = 0;
    return true;
}

fn validate(state: State, inputs: Inputs) !usize {
    inline for (.{ inputs.accumulated_leafout_h, inputs.required_leafout_h, state.potential_seed_site_count.*, state.grain_count.*, state.individual_grain_carbon_g_c.* }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSpringReproductiveInput;
    inline for (.{ state.husk.*, state.ear.*, state.grain.* }) |organ| inline for (@typeInfo(Elements).@"struct".fields) |field| {
        const value = @field(organ, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSpringReproductiveState;
    };
    const count = inputs.reproductive_litter_kinetics.carbon.len;
    if (count == 0) return error.ZeroSpringReproductiveKineticPools;
    inline for (.{ inputs.reproductive_litter_kinetics.nitrogen, inputs.reproductive_litter_kinetics.phosphorus, state.litter_carbon_g_c, state.litter_nitrogen_g_n, state.litter_phosphorus_g_p }) |values|
        if (values.len != count) return error.SpringReproductiveKineticDimensionMismatch;
    inline for (@typeInfo(Kinetics).@"struct".fields) |field| {
        var total: f64 = 0;
        for (@field(inputs.reproductive_litter_kinetics, field.name)) |fraction| {
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidSpringReproductiveKinetics;
            total += fraction;
        }
        if (!std.math.isFinite(total) or @abs(total - 1) > 1e-12) return error.InvalidSpringReproductiveKinetics;
    }
    inline for (.{ state.litter_carbon_g_c, state.litter_nitrogen_g_n, state.litter_phosphorus_g_p }) |values| for (values) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSpringReproductiveLitterState;
    return count;
}

fn testState(organs: *[3]Elements, diagnostics: *[3]f64, litter: *[3][3]f64) State {
    return .{ .husk = &organs[0], .ear = &organs[1], .grain = &organs[2], .potential_seed_site_count = &diagnostics[0], .grain_count = &diagnostics[1], .individual_grain_carbon_g_c = &diagnostics[2], .litter_carbon_g_c = &litter[0], .litter_nitrogen_g_n = &litter[1], .litter_phosphorus_g_p = &litter[2] };
}
fn testInputs() Inputs {
    const fractions = &[_]f64{ 0.2, 0.3, 0.5 };
    return .{ .leafout_status = .enabled, .perennial = true, .accumulated_leafout_h = 10, .required_leafout_h = 10, .reproductive_litter_kinetics = .{ .carbon = fractions, .nitrogen = fractions, .phosphorus = fractions } };
}

test "spring reproductive litterfall conserves C N P and clears diagnostics" {
    var organs = [_]Elements{ .{ .carbon = 1, .nitrogen = 0.1, .phosphorus = 0.01 }, .{ .carbon = 2, .nitrogen = 0.2, .phosphorus = 0.02 }, .{ .carbon = 3, .nitrogen = 0.3, .phosphorus = 0.03 } };
    var diagnostics = [_]f64{ 10, 20, 0.4 };
    var litter: [3][3]f64 = @splat(@splat(0));
    try std.testing.expect(try apply(testState(&organs, &diagnostics, &litter), testInputs()));
    try std.testing.expectApproxEqAbs(@as(f64, 6), litter[0][0] + litter[0][1] + litter[0][2], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), litter[1][0] + litter[1][1] + litter[1][2], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), litter[2][0] + litter[2][1] + litter[2][2], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), organs[2].carbon);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, &diagnostics);
}

test "disabled gate is strict no-op before state reads" {
    var organs: [3]Elements = @splat(.{ .carbon = std.math.nan(f64), .nitrogen = 0, .phosphorus = 0 });
    var diagnostics = [_]f64{std.math.nan(f64)} ** 3;
    var litter: [3][3]f64 = @splat(@splat(std.math.nan(f64)));
    var inputs = testInputs();
    inputs.leafout_status = .disabled;
    try std.testing.expect(!try apply(testState(&organs, &diagnostics, &litter), inputs));
}

test "late invalid litter leaves organs and diagnostics unchanged" {
    var organs = [_]Elements{ .{ .carbon = 1, .nitrogen = 0.1, .phosphorus = 0.01 }, .{ .carbon = 2, .nitrogen = 0.2, .phosphorus = 0.02 }, .{ .carbon = 3, .nitrogen = 0.3, .phosphorus = 0.03 } };
    var diagnostics = [_]f64{ 10, 20, 0.4 };
    var litter: [3][3]f64 = @splat(@splat(0));
    litter[2][2] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidSpringReproductiveLitterState, apply(testState(&organs, &diagnostics, &litter), testInputs()));
    try std.testing.expectEqual(@as(f64, 1), organs[0].carbon);
    try std.testing.expectEqual(@as(f64, 10), diagnostics[0]);
    try std.testing.expectEqual(@as(f64, 0), litter[0][0]);
}

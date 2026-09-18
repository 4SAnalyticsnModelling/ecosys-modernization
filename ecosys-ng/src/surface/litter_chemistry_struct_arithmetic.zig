//! `litter_chemistry` declarations: struct arithmetic.
//!
//! Split out of `litter_chemistry.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ledger = @import("litter_reaction_transformations.zig");
const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const numerics = @import("../core/numerics.zig");
const group_fixtures = @import("litter_chemistry_fixtures.zig");
const group_logging = @import("litter_chemistry_logging.zig");
const group_phosphate_exchange = @import("litter_chemistry_phosphate_exchange.zig");
const group_types = @import("litter_chemistry_types.zig");

/// Applies the largest representable admissible fraction at or below the
/// analytic shared-inventory bound. A mathematically exact endpoint can round
/// one of many simultaneous sinks a few ulps below zero; bisection corrects
/// only that floating-point endpoint error without changing relative rates.
pub fn applyAdmissibleFraction(
    current: group_types.Cell,
    changes: group_types.Cell,
    requested_fraction: f64,
    options: group_types.Options,
) !group_types.Cell {
    if (applyFraction(current, changes, requested_fraction)) |candidate|
        return candidate
    else |err| switch (err) {
        error.NegativeLitterChemistryState => {},
        else => return err,
    }
    var lower: f64 = 0;
    var upper = requested_fraction;
    var best = current;
    var iteration: u16 = 0;
    while (iteration < options.max_iterations) : (iteration += 1) {
        group_types.recordProbe(options);
        const middle = lower + 0.5 * (upper - lower);
        if (applyFraction(current, changes, middle)) |candidate| {
            lower = middle;
            best = candidate;
        } else |err| switch (err) {
            error.NegativeLitterChemistryState => upper = middle,
            else => return err,
        }
    }
    if (lower <= 0) return error.NoPhysicallyAdmissibleFixedPhKineticStep;
    return best;
}

pub fn scaledCoordinateResidualNorm(
    reference: group_types.Cell,
    residual: []const f64,
    options: group_types.Options,
) f64 {
    var result: f64 = 0;
    for (residual, 0..) |residual_value, coordinate| {
        const state_value = group_phosphate_exchange.phosphateCoordinate(reference, coordinate);
        const scale = group_phosphate_exchange.phosphateCoordinateScale(options, coordinate, state_value);
        result = @max(result, @abs(residual_value) / scale);
    }
    return result;
}

pub fn maximumAdmissibleFraction(comptime T: type, current: T, changes: T) f64 {
    var result = std.math.inf(f64);
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const value = @field(current, field.name);
            const change = @field(changes, field.name);
            // Underflow-scale dissolution of an already extinct phase is
            // numerical noise, not a physical active-set boundary. It can
            // otherwise cap a simultaneous mineral plateau at one iteration
            // even though scaling that change by any useful finite step still
            // lies inside the roundoff normalization allowance.
            const roundoff_change = std.math.floatEps(f64) *
                @max(1.0, @abs(value));
            if (change < -roundoff_change)
                result = @min(result, @max(0, value) / -change);
        },
        .@"struct" => result = @min(result, maximumAdmissibleFraction(field.type, @field(current, field.name), @field(changes, field.name))),
        else => @compileError("litter chemistry contains a non-numeric field"),
    };
    return result;
}

pub fn valuesEqual(comptime T: type, left: T, right: T) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => if (@field(left, field.name) != @field(right, field.name)) return false,
        .@"struct" => if (!valuesEqual(field.type, @field(left, field.name), @field(right, field.name))) return false,
        else => @compileError("litter chemistry contains a non-numeric field"),
    };
    return true;
}

pub fn boundedPicard(
    current: group_types.Cell,
    changes: group_types.Cell,
    requested_fraction: f64,
    options: group_types.Options,
) !group_types.Cell {
    var fraction = requested_fraction;
    var attempts: u16 = 0;
    while (attempts < group_types.probeCap(options, 53)) : (attempts += 1) {
        group_types.recordProbe(options);
        if (applyFraction(current, changes, fraction)) |candidate| return candidate else |err| switch (err) {
            error.NegativeLitterChemistryState => fraction *= 0.5,
            else => return err,
        }
        if (fraction <= std.math.floatEps(f64)) break;
    }
    group_logging.logInadmissibleDirections(group_types.Cell, "", current, changes);
    return error.NoPhysicallyAdmissibleLitterPicardStep;
}

pub fn changesAt(cell: group_types.Cell, environment: group_types.Environment, evaluator: group_fixtures.Evaluator) !group_types.Cell {
    const extents = try evaluator.evaluate(evaluator.context, cell);
    return ledger.assemble(extents, environment.litter_mass_per_water_volume_megagrams_per_m3, environment.dynamic_salts);
}

pub fn applyFraction(current: group_types.Cell, changes: group_types.Cell, fraction: f64) !group_types.Cell {
    var result = current;
    try addScaled(group_types.Cell, &result, changes, fraction);
    try validateCell(result);
    return result;
}

pub fn interpolateCell(current: group_types.Cell, target: group_types.Cell, fraction: f64) !group_types.Cell {
    var result = current;
    try interpolateValue(group_types.Cell, &result, target, fraction);
    try validateCell(result);
    return result;
}

fn interpolateValue(comptime T: type, destination: *T, target: T, fraction: f64) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const next = @field(destination.*, field.name) +
                fraction * (@field(target, field.name) -
                    @field(destination.*, field.name));
            if (!std.math.isFinite(next)) return error.NonFiniteLitterChemistryState;
            @field(destination.*, field.name) = next;
        },
        .@"struct" => try interpolateValue(
            field.type,
            &@field(destination.*, field.name),
            @field(target, field.name),
            fraction,
        ),
        else => @compileError("litter chemistry contains a non-numeric field"),
    };
}

fn addScaled(comptime T: type, destination: *T, changes: T, fraction: f64) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const change = @field(changes, field.name) * fraction;
            if (!std.math.isFinite(change)) return error.NonFiniteLitterChemistryChange;
            @field(destination.*, field.name) += change;
        },
        .@"struct" => try addScaled(field.type, &@field(destination.*, field.name), @field(changes, field.name), fraction),
        else => @compileError("litter chemistry contains a non-numeric field"),
    };
}

pub fn validateCell(cell: group_types.Cell) !void {
    try validateValue(group_types.Cell, cell);
}

fn validateValue(comptime T: type, value: T) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const number = @field(value, field.name);
            if (!std.math.isFinite(number)) return error.NonFiniteLitterChemistryState;
            if (number < 0) return error.NegativeLitterChemistryState;
        },
        .@"struct" => try validateValue(field.type, @field(value, field.name)),
        else => @compileError("litter chemistry contains a non-numeric field"),
    };
}

pub fn scaledNorm(state_value: group_types.Cell, changes: group_types.Cell, options: group_types.Options) !f64 {
    var maximum: f64 = 0;
    try accumulateScaledNorm(group_types.Cell, state_value, changes, options, &maximum);
    return maximum;
}

fn accumulateScaledNorm(comptime T: type, state_value: T, changes: T, options: group_types.Options, maximum: *f64) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const value = @field(state_value, field.name);
            const change = @field(changes, field.name);
            if (!std.math.isFinite(value) or !std.math.isFinite(change)) return error.NonFiniteLitterChemistryState;
            maximum.* = @max(maximum.*, @abs(change) / options.scaleForField(field.name, value));
        },
        .@"struct" => try accumulateScaledNorm(field.type, @field(state_value, field.name), @field(changes, field.name), options, maximum),
        else => unreachable,
    };
}

/// Depth-one Anderson secant ratio over the fixed-point defect `changes`,
/// normalized by its own largest scaled component. Without that
/// normalization the sums silently underflow: a slowly crawling recovery step
/// changes the defect by far less than one tolerance unit, the squared terms
/// fall below machine epsilon, and the acceleration gate then rejects exactly
/// the stalled sequence it exists to rescue. Mirrors the vector form in
/// `soil/gas/vapor_solver.zig`. Returns `null` when the ratio is not usable
/// (the recovery step must then report stagnation rather than commit the
/// bounded-Picard seed without acceleration).
pub fn andersonMixingRatio(comptime T: type, now_state: T, now_defect: T, before_defect: T, options: group_types.Options) ?f64 {
    var largest_change: f64 = 0;
    accumulateLargestChange(T, now_state, now_defect, before_defect, options, &largest_change);
    if (!std.math.isFinite(largest_change) or largest_change <= 0) return null;
    var numerator: f64 = 0;
    var denominator: f64 = 0;
    accumulateMixingProducts(T, now_state, now_defect, before_defect, options, largest_change, &numerator, &denominator);
    if (!std.math.isFinite(numerator) or !std.math.isFinite(denominator) or denominator <= std.math.floatEps(f64)) return null;
    const mixing = numerator / denominator;
    return if (std.math.isFinite(mixing)) mixing else null;
}

fn accumulateLargestChange(comptime T: type, now_state: T, now_defect: T, before_defect: T, options: group_types.Options, largest_change: *f64) void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const value = @field(now_state, field.name);
            const scale = options.scaleForField(field.name, value);
            const change = @abs((@field(now_defect, field.name) - @field(before_defect, field.name)) / scale);
            largest_change.* = @max(largest_change.*, change);
        },
        .@"struct" => accumulateLargestChange(field.type, @field(now_state, field.name), @field(now_defect, field.name), @field(before_defect, field.name), options, largest_change),
        else => unreachable,
    };
}

fn accumulateMixingProducts(comptime T: type, now_state: T, now_defect: T, before_defect: T, options: group_types.Options, largest_change: f64, numerator: *f64, denominator: *f64) void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const value = @field(now_state, field.name);
            const scale = options.scaleForField(field.name, value);
            const now = @field(now_defect, field.name);
            const before = @field(before_defect, field.name);
            const change = ((now - before) / scale) / largest_change;
            numerator.* += change * ((now / scale) / largest_change);
            denominator.* += change * change;
        },
        .@"struct" => accumulateMixingProducts(field.type, @field(now_state, field.name), @field(now_defect, field.name), @field(before_defect, field.name), options, largest_change, numerator, denominator),
        else => unreachable,
    };
}

pub fn directionalProducts(comptime T: type, base: T, probe: T, probe_fraction: f64, numerator: *f64, denominator: *f64) void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const derivative = (@field(probe, field.name) - @field(base, field.name)) / probe_fraction;
            numerator.* += @field(base, field.name) * derivative;
            denominator.* += derivative * derivative;
        },
        .@"struct" => directionalProducts(field.type, @field(base, field.name), @field(probe, field.name), probe_fraction, numerator, denominator),
        else => unreachable,
    };
}

fn maximumDifference(comptime T: type, a: T, b: T) f64 {
    var maximum: f64 = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => maximum = @max(maximum, @abs(@field(a, field.name) - @field(b, field.name))),
        .@"struct" => maximum = @max(maximum, maximumDifference(field.type, @field(a, field.name), @field(b, field.name))),
        else => unreachable,
    };
    return maximum;
}

fn maximumMagnitude(comptime T: type, value: T) f64 {
    var maximum: f64 = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => maximum = @max(maximum, @abs(@field(value, field.name))),
        .@"struct" => maximum = @max(maximum, maximumMagnitude(field.type, @field(value, field.name))),
        else => unreachable,
    };
    return maximum;
}

pub fn zeroValue(comptime T: type, value: *T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => @field(value.*, field.name) = 0,
        .@"struct" => zeroValue(field.type, &@field(value.*, field.name)),
        else => @compileError("litter chemistry contains a non-numeric field"),
    };
}

pub fn validateOptions(options: group_types.Options) !void {
    if (!options.anderson_recovery or !std.math.isFinite(options.absolute_tolerance_mol_per_m3) or options.absolute_tolerance_mol_per_m3 <= 0 or !std.math.isFinite(options.absolute_tolerance_mol_per_megagram) or options.absolute_tolerance_mol_per_megagram <= 0 or !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or !std.math.isFinite(options.directional_probe_fraction) or options.directional_probe_fraction <= 0 or !std.math.isFinite(options.minimum_newton_fraction) or options.minimum_newton_fraction <= 0 or !std.math.isFinite(options.maximum_newton_fraction) or options.maximum_newton_fraction < options.minimum_newton_fraction or options.maximum_newton_fraction > 1 or options.max_iterations == 0) return error.InvalidLitterChemistrySolverOptions;
}

const TestPair = struct { a: f64, b: f64 };

test "andersonMixingRatio is null on degenerate history and finite on a real secant" {
    const options: group_types.Options = .{};
    // Degenerate: the defect has not changed between the two remembered
    // iterations, so the secant denominator is exactly zero and there is
    // nothing to extrapolate from.
    const state = TestPair{ .a = 1, .b = 1 };
    const same_defect = TestPair{ .a = 0.1, .b = -0.1 };
    try std.testing.expect(andersonMixingRatio(TestPair, state, same_defect, same_defect, options) == null);

    // A geometrically shrinking defect (ratio 0.5 each step, matching a
    // contracting Picard map) gives a well-defined, finite mixing ratio.
    const now_defect = TestPair{ .a = 0.05, .b = -0.05 };
    const before_defect = TestPair{ .a = 0.1, .b = -0.1 };
    const mixing = andersonMixingRatio(TestPair, state, now_defect, before_defect, options);
    try std.testing.expect(mixing != null);
    try std.testing.expect(std.math.isFinite(mixing.?));
}

test "litter chemistry rejects disabled Anderson recovery" {
    try std.testing.expectError(error.InvalidLitterChemistrySolverOptions, validateOptions(.{ .anderson_recovery = false }));
    try std.testing.expectError(error.InvalidLitterChemistrySolverOptions, validateOptions(.{ .maximum_newton_fraction = 1.01 }));
}

test "andersonMixingRatio scales identically under a uniform tolerance rescale" {
    // The secant ratio is a pure number: rescaling BOTH the absolute and
    // relative tolerance by the same factor k rescales every `scale(v)` term
    // by k uniformly, which cancels exactly in the numerator and denominator.
    // This is the property the vector form in `soil/gas/vapor_solver.zig`
    // relies on to stay well-conditioned regardless of the reaction's
    // absolute scale.
    const state = TestPair{ .a = 2, .b = -3 };
    const now_defect = TestPair{ .a = 0.02, .b = -0.03 };
    const before_defect = TestPair{ .a = 0.05, .b = -0.07 };
    const baseline: group_types.Options = .{ .absolute_tolerance_mol_per_m3 = 1e-11, .absolute_tolerance_mol_per_megagram = 1e-11, .relative_tolerance = 1e-8 };
    const rescaled: group_types.Options = .{ .absolute_tolerance_mol_per_m3 = 1e-11 * 1e5, .absolute_tolerance_mol_per_megagram = 1e-11 * 1e5, .relative_tolerance = 1e-8 * 1e5 };
    const mixing_baseline = andersonMixingRatio(TestPair, state, now_defect, before_defect, baseline).?;
    const mixing_rescaled = andersonMixingRatio(TestPair, state, now_defect, before_defect, rescaled).?;
    try std.testing.expectApproxEqRel(mixing_baseline, mixing_rescaled, 1e-9);
}

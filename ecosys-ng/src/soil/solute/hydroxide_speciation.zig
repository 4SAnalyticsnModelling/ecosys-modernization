//! Conservative local elimination of Al/Fe hydroxide and acid-base chains. This is a
//! candidate generator, not a replacement for the full chemistry acceptance
//! gate. Ionic-strength coefficients are frozen at the caller's anchor.
const std = @import("std");
const numerics = @import("../../core/numerics.zig");
const water = @import("water_equilibrium.zig");

pub const Chain = struct {
    /// M, MOH, M(OH)2, M(OH)3, M(OH)4; these five chemical species are not
    /// grid/runtime dimensions. Other complexes and minerals are untouched.
    concentrations_mol_per_m3: [5]f64,
    dissociation_constants: [4]f64,
};

/// Successive acid dissociation states, ordered from most protonated to
/// least protonated. Entries above species_count are inactive and zero.
/// The fraction converts zone molarity to the common aqueous charge basis.
pub const AcidChain = struct {
    species_count: u3,
    concentrations_mol_per_m3: [4]f64,
    dissociation_constants: [3]f64,
    activity_coefficients: [4]f64,
    water_fraction: f64,
};

pub const Inputs = struct {
    aluminum: Chain,
    iron: Chain,
    hydrogen_mol_per_m3: f64,
    hydroxide_mol_per_m3: f64,
    monovalent_activity_coefficient: f64,
    divalent_activity_coefficient: f64,
    trivalent_activity_coefficient: f64,
    water_activity_product_mol2_per_m6: f64,
    max_iterations: u16,
    shared_budget: ?*numerics.NonlinearBudget = null,
    acids: []const AcidChain = &.{},
};

pub const Result = struct {
    aluminum_mol_per_m3: [5]f64,
    iron_mol_per_m3: [5]f64,
    hydrogen_mol_per_m3: f64,
    hydroxide_mol_per_m3: f64,
    charge_balance_residual_mol_per_m3: f64,
    iterations: u16,
};

/// Algebraic elimination at a caller-owned acidity coordinate. The charge
/// residual is deliberately returned, not silently projected away: a coupled
/// mineral Newton solve must change acidity and conserved totals together.
pub const Evaluation = struct {
    state: Result,
    charge_derivative_log_hydroxide: f64,
};

pub fn evaluateAt(input: Inputs, log_hydroxide: f64) !Evaluation {
    const context = try makeContext(input);
    const hydroxide = @exp(log_hydroxide);
    const hydrogen = context.concentration_product / hydroxide;
    if (!std.math.isFinite(hydroxide) or !std.math.isFinite(hydrogen) or hydroxide <= 0 or hydrogen <= 0) return error.InvalidHydroxideSpeciationState;
    return .{
        .state = .{
            .aluminum_mol_per_m3 = context.distribution(input.aluminum, context.aluminum_total, log_hydroxide).concentrations,
            .iron_mol_per_m3 = context.distribution(input.iron, context.iron_total, log_hydroxide).concentrations,
            .hydrogen_mol_per_m3 = hydrogen,
            .hydroxide_mol_per_m3 = hydroxide,
            .charge_balance_residual_mol_per_m3 = context.residual(log_hydroxide),
            .iterations = 0,
        },
        .charge_derivative_log_hydroxide = context.derivative(log_hydroxide),
    };
}

const Distribution = struct {
    concentrations: [5]f64,
    bound_hydroxide: f64,
    variance_times_total: f64,
};
const AcidMoments = struct { bound: f64, derivative: f64 };

const Context = struct {
    input: Inputs,
    aluminum_total: f64,
    iron_total: f64,
    invariant: f64,
    concentration_product: f64,

    fn acidDistribution(self: Context, chain: AcidChain, log_hydroxide: f64) Distribution {
        var result: Distribution = .{ .concentrations = @splat(0), .bound_hydroxide = 0, .variance_times_total = 0 };
        if (chain.water_fraction == 0) {
            @memcpy(result.concentrations[0..4], &chain.concentrations_mol_per_m3);
            return result;
        }
        var weights: [4]f64 = @splat(0);
        var maximum: f64 = 0;
        var acid_total: f64 = 0;
        for (chain.concentrations_mol_per_m3[0..chain.species_count]) |value| acid_total += value;
        for (0..chain.species_count - 1) |index| {
            weights[index + 1] = weights[index] + @log(chain.dissociation_constants[index]) + @log(chain.activity_coefficients[index]) + @log(self.input.monovalent_activity_coefficient) + log_hydroxide - @log(self.input.water_activity_product_mol2_per_m6) - @log(chain.activity_coefficients[index + 1]);
            maximum = @max(maximum, weights[index + 1]);
        }
        var sum: f64 = 0;
        for (weights[0..chain.species_count]) |*value| {
            value.* = @exp(value.* - maximum);
            sum += value.*;
        }
        var mean: f64 = 0;
        for (weights[0..chain.species_count], 0..) |weight, index| {
            const probability = weight / sum;
            result.concentrations[index] = acid_total * probability;
            mean += @as(f64, @floatFromInt(index)) * probability;
        }
        const whole_water_total = acid_total * chain.water_fraction;
        result.bound_hydroxide = whole_water_total * mean;
        for (weights[0..chain.species_count], 0..) |weight, index| {
            const deviation = @as(f64, @floatFromInt(index)) - mean;
            result.variance_times_total += whole_water_total * (weight / sum) * deviation * deviation;
        }
        return result;
    }

    fn acidMoments(self: Context, log_hydroxide: f64) AcidMoments {
        var result: AcidMoments = .{ .bound = 0, .derivative = 0 };
        for (self.input.acids) |chain| {
            const acid = self.acidDistribution(chain, log_hydroxide);
            result.bound += acid.bound_hydroxide;
            result.derivative += acid.variance_times_total;
        }
        return result;
    }

    fn distribution(self: Context, chain: Chain, total: f64, log_hydroxide: f64) Distribution {
        const g1 = self.input.monovalent_activity_coefficient;
        const g2 = self.input.divalent_activity_coefficient;
        const g3 = self.input.trivalent_activity_coefficient;
        const log_coefficients = [5]f64{ @log(g3), @log(g2), @log(g1), 0, @log(g1) };
        var weights: [5]f64 = undefined;
        weights[0] = 0;
        var maximum: f64 = 0;
        for (chain.dissociation_constants, 0..) |constant, index| {
            weights[index + 1] = weights[index] + log_coefficients[index] + @log(g1) + log_hydroxide - @log(constant) - log_coefficients[index + 1];
            maximum = @max(maximum, weights[index + 1]);
        }
        var sum: f64 = 0;
        for (&weights) |*value| {
            value.* = @exp(value.* - maximum);
            sum += value.*;
        }
        var result: Distribution = .{ .concentrations = undefined, .bound_hydroxide = 0, .variance_times_total = 0 };
        var mean: f64 = 0;
        for (weights, 0..) |weight, index| {
            const probability = weight / sum;
            result.concentrations[index] = total * probability;
            mean += @as(f64, @floatFromInt(index)) * probability;
        }
        result.bound_hydroxide = total * mean;
        for (weights, 0..) |weight, index| {
            const deviation = @as(f64, @floatFromInt(index)) - mean;
            result.variance_times_total += total * (weight / sum) * deviation * deviation;
        }
        return result;
    }

    fn residual(self: Context, log_hydroxide: f64) f64 {
        const hydroxide = @exp(log_hydroxide);
        const aluminum = self.distribution(self.input.aluminum, self.aluminum_total, log_hydroxide);
        const iron = self.distribution(self.input.iron, self.iron_total, log_hydroxide);
        return hydroxide - self.concentration_product / hydroxide + aluminum.bound_hydroxide + iron.bound_hydroxide + self.acidMoments(log_hydroxide).bound - self.invariant;
    }

    fn derivative(self: Context, log_hydroxide: f64) f64 {
        const hydroxide = @exp(log_hydroxide);
        const aluminum = self.distribution(self.input.aluminum, self.aluminum_total, log_hydroxide);
        const iron = self.distribution(self.input.iron, self.iron_total, log_hydroxide);
        return hydroxide + self.concentration_product / hydroxide + aluminum.variance_times_total + iron.variance_times_total + self.acidMoments(log_hydroxide).derivative;
    }

    fn fixedPoint(self: Context, log_hydroxide: f64) f64 {
        const aluminum = self.distribution(self.input.aluminum, self.aluminum_total, log_hydroxide);
        const iron = self.distribution(self.input.iron, self.iron_total, log_hydroxide);
        const pair = water.projectProvisional(aluminum.bound_hydroxide + iron.bound_hydroxide + self.acidMoments(log_hydroxide).bound - self.invariant, 0, self.input.monovalent_activity_coefficient, self.input.water_activity_product_mol2_per_m6) catch return std.math.nan(f64);
        return @log(pair.hydroxide_concentration_mol_per_m3);
    }
};

fn chainTotal(chain: Chain) !f64 {
    var value: f64 = 0;
    for (chain.concentrations_mol_per_m3) |concentration| {
        if (!std.math.isFinite(concentration) or concentration < 0) return error.InvalidHydroxideSpeciationState;
        value += concentration;
    }
    for (chain.dissociation_constants) |constant|
        if (!std.math.isFinite(constant) or constant <= 0) return error.InvalidHydroxideSpeciationConstant;
    if (!std.math.isFinite(value)) return error.InvalidHydroxideSpeciationState;
    return value;
}

fn bound(chain: Chain) f64 {
    var value: f64 = 0;
    for (chain.concentrations_mol_per_m3, 0..) |concentration, index|
        value += concentration * @as(f64, @floatFromInt(index));
    return value;
}

fn validateAcid(chain: AcidChain) !void {
    if (chain.species_count < 2 or chain.species_count > 4 or !std.math.isFinite(chain.water_fraction) or chain.water_fraction < 0 or chain.water_fraction > 1) return error.InvalidAcidSpeciationChain;
    for (chain.concentrations_mol_per_m3, 0..) |value, index| {
        if (!std.math.isFinite(value) or value < 0 or (index >= chain.species_count and value != 0)) return error.InvalidAcidSpeciationChain;
    }
    if (chain.water_fraction == 0) return;
    for (chain.dissociation_constants[0 .. chain.species_count - 1]) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidAcidSpeciationChain;
    for (chain.activity_coefficients[0..chain.species_count]) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidAcidSpeciationChain;
}

/// Reconstructs one acid chain at a solved local endpoint. No caller storage
/// is mutated; the result is validated before it can enter a cell candidate.
pub fn acidConcentrations(input: Inputs, chain: AcidChain, hydroxide_mol_per_m3: f64) ![4]f64 {
    try validateAcid(chain);
    if (!std.math.isFinite(hydroxide_mol_per_m3) or hydroxide_mol_per_m3 <= 0) return error.InvalidAcidSpeciationChain;
    const context: Context = .{ .input = input, .aluminum_total = 0, .iron_total = 0, .invariant = 0, .concentration_product = 0 };
    const distribution = context.acidDistribution(chain, @log(hydroxide_mol_per_m3));
    var result: [4]f64 = undefined;
    @memcpy(&result, distribution.concentrations[0..4]);
    var before_total: f64 = 0;
    var after_total: f64 = 0;
    for (result, chain.concentrations_mol_per_m3) |value, before| {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidAcidSpeciationChain;
        before_total += before;
        after_total += value;
    }
    if (!std.math.isFinite(before_total) or @abs(after_total - before_total) > 128 * std.math.floatEps(f64) * before_total) return error.AcidSpeciationMassImbalance;
    return result;
}

fn makeContext(input: Inputs) !Context {
    for ([_]f64{ input.hydrogen_mol_per_m3, input.hydroxide_mol_per_m3 }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidHydroxideSpeciationState;
    for ([_]f64{ input.monovalent_activity_coefficient, input.divalent_activity_coefficient, input.trivalent_activity_coefficient, input.water_activity_product_mol2_per_m6 }) |value|
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidHydroxideSpeciationConstant;
    const aluminum_total = try chainTotal(input.aluminum);
    const iron_total = try chainTotal(input.iron);
    var maximum_bound = 4 * (aluminum_total + iron_total);
    var invariant = input.hydroxide_mol_per_m3 - input.hydrogen_mol_per_m3 + bound(input.aluminum) + bound(input.iron);
    for (input.acids) |chain| {
        try validateAcid(chain);
        for (chain.concentrations_mol_per_m3[0..chain.species_count], 0..) |value, index| {
            maximum_bound += @as(f64, @floatFromInt(chain.species_count - 1)) * value * chain.water_fraction;
            invariant += @as(f64, @floatFromInt(index)) * value * chain.water_fraction;
        }
    }
    const concentration_product = input.water_activity_product_mol2_per_m6 / input.monovalent_activity_coefficient / input.monovalent_activity_coefficient;
    const scale = input.hydrogen_mol_per_m3 + input.hydroxide_mol_per_m3 + maximum_bound + @sqrt(concentration_product);
    if (!std.math.isFinite(scale) or !std.math.isFinite(invariant) or concentration_product <= 0 or !std.math.isFinite(concentration_product)) return error.InvalidHydroxideSpeciationState;
    return .{ .input = input, .aluminum_total = aluminum_total, .iron_total = iron_total, .invariant = invariant, .concentration_product = concentration_product };
}

pub fn solve(input: Inputs) !Result {
    if (input.max_iterations == 0) return error.InvalidHydroxideSpeciationIterationLimit;
    const context = try makeContext(input);
    const aluminum_total = context.aluminum_total;
    const iron_total = context.iron_total;
    const invariant = context.invariant;
    const concentration_product = context.concentration_product;
    var maximum_bound = 4 * (aluminum_total + iron_total);
    for (input.acids) |chain| for (chain.concentrations_mol_per_m3[0..chain.species_count]) |value| {
        maximum_bound += @as(f64, @floatFromInt(chain.species_count - 1)) * value * chain.water_fraction;
    };
    const scale = input.hydrogen_mol_per_m3 + input.hydroxide_mol_per_m3 + maximum_bound + @sqrt(concentration_product);
    const lower = try water.projectProvisional(maximum_bound - invariant, 0, input.monovalent_activity_coefficient, input.water_activity_product_mol2_per_m6);
    const upper = try water.projectProvisional(-invariant, 0, input.monovalent_activity_coefficient, input.water_activity_product_mol2_per_m6);
    const anchor = try water.projectProvisional(input.hydrogen_mol_per_m3, input.hydroxide_mol_per_m3, input.monovalent_activity_coefficient, input.water_activity_product_mol2_per_m6);
    var iterations: u16 = 0;
    var root = @log(anchor.hydroxide_concentration_mol_per_m3);
    const tolerance = 128 * std.math.floatEps(f64) * scale;
    if (maximum_bound > 0 and @abs(context.residual(root)) > tolerance) {
        var best: numerics.SolveResult = .{ .root = root, .residual = std.math.inf(f64), .iterations = 0, .newton_raphson_steps = 0, .picard_steps = 0 };
        const result = numerics.newtonPicard(context, Context.residual, Context.derivative, Context.fixedPoint, @log(lower.hydroxide_concentration_mol_per_m3), @log(upper.hydroxide_concentration_mol_per_m3), root, .{
            .residual_scale = scale,
            .relative_tolerance = 64 * std.math.floatEps(f64),
            .max_iterations = input.max_iterations,
            .shared_budget = input.shared_budget,
            .last_iterate_on_failure = &best,
            .divergence_patience = 2,
        }) catch |err| blk: {
            if (!std.math.isFinite(best.residual) or @abs(context.residual(best.root)) > tolerance) return err;
            break :blk best;
        };
        root = result.root;
        iterations = result.iterations;
    }
    const residual = context.residual(root);
    if (!std.math.isFinite(residual) or @abs(residual) > tolerance) return error.HydroxideSpeciationChargeImbalance;
    const hydroxide = @exp(root);
    const aluminum = context.distribution(input.aluminum, aluminum_total, root);
    const iron = context.distribution(input.iron, iron_total, root);
    const hydrogen = concentration_product / hydroxide;
    if (!std.math.isFinite(hydroxide) or !std.math.isFinite(hydrogen) or hydroxide <= 0 or hydrogen <= 0) return error.InvalidHydroxideSpeciationState;
    for ([_]Distribution{ aluminum, iron }, [_]f64{ aluminum_total, iron_total }) |distribution, original_total| {
        var final_total: f64 = 0;
        for (distribution.concentrations) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidHydroxideSpeciationState;
            final_total += value;
        }
        if (@abs(final_total - original_total) > 128 * std.math.floatEps(f64) * original_total) return error.HydroxideSpeciationMetalImbalance;
    }
    for (input.acids) |chain| _ = try acidConcentrations(input, chain, hydroxide);
    return .{
        .aluminum_mol_per_m3 = aluminum.concentrations,
        .iron_mol_per_m3 = iron.concentrations,
        .hydrogen_mol_per_m3 = hydrogen,
        .hydroxide_mol_per_m3 = hydroxide,
        .charge_balance_residual_mol_per_m3 = residual,
        .iterations = iterations,
    };
}

test "conserved hydroxide speciation recovers a manufactured five-species equilibrium" {
    const result = try solve(.{
        .aluminum = .{ .concentrations_mol_per_m3 = @splat(0), .dissociation_constants = @splat(1) },
        .iron = .{ .concentrations_mol_per_m3 = .{ 1, 0, 0, 0, 0 }, .dissociation_constants = @splat(1) },
        .hydrogen_mol_per_m3 = 1,
        .hydroxide_mol_per_m3 = 3,
        .monovalent_activity_coefficient = 1,
        .divalent_activity_coefficient = 1,
        .trivalent_activity_coefficient = 1,
        .water_activity_product_mol2_per_m6 = 1,
        .max_iterations = 20,
    });
    const roundoff = 128 * std.math.floatEps(f64);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.hydrogen_mol_per_m3, roundoff);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.hydroxide_mol_per_m3, roundoff);
    for (result.iron_mol_per_m3) |value| try std.testing.expectApproxEqAbs(@as(f64, 0.2), value, roundoff);
    for (result.aluminum_mol_per_m3) |value| try std.testing.expectEqual(@as(f64, 0), value);
}

test "conserved hydroxide speciation couples fractional-water acid charge and nonunit activities" {
    const acid: AcidChain = .{
        .species_count = 2,
        .concentrations_mol_per_m3 = .{ 1, 0, 0, 0 },
        .dissociation_constants = .{ 1, 0, 0 },
        .activity_coefficients = .{ 0.5, 1, 0, 0 },
        .water_fraction = 0.25,
    };
    const input: Inputs = .{
        .aluminum = .{ .concentrations_mol_per_m3 = @splat(0), .dissociation_constants = @splat(1) },
        .iron = .{ .concentrations_mol_per_m3 = @splat(0), .dissociation_constants = @splat(1) },
        .hydrogen_mol_per_m3 = 1,
        .hydroxide_mol_per_m3 = 1.125,
        .monovalent_activity_coefficient = 0.5,
        .divalent_activity_coefficient = 0.25,
        .trivalent_activity_coefficient = 0.125,
        .water_activity_product_mol2_per_m6 = 0.25,
        .max_iterations = 20,
        .acids = &.{acid},
    };
    const result = try solve(input);
    const concentrations = try acidConcentrations(input, acid, result.hydroxide_mol_per_m3);
    const roundoff = 128 * std.math.floatEps(f64);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.hydroxide_mol_per_m3, roundoff);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.hydrogen_mol_per_m3, roundoff);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), concentrations[0], roundoff);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), concentrations[1], roundoff);
    const context: Context = .{ .input = input, .aluminum_total = 0, .iron_total = 0, .invariant = 0.125, .concentration_product = 1 };
    try std.testing.expectApproxEqAbs(@as(f64, 2.0625), context.derivative(0), roundoff);
    var dry = acid;
    dry.water_fraction = 0;
    dry.dissociation_constants = @splat(0);
    try std.testing.expectEqualDeep(dry.concentrations_mol_per_m3, try acidConcentrations(input, dry, 1));
}

//! Coupled phosphate-mineral/acid-base candidate, with frozen activities.
//! Chemical dimensions only: five mineral formulae in two phosphate zones.
//! Other complexes, sorption and exchange remain owned by the full network.
const std = @import("std");
const speciation = @import("hydroxide_speciation.zig");
const water = @import("water_equilibrium.zig");
const numerics = @import("../../core/numerics.zig");

const phase_count = 10;
const dimension = phase_count + 1;
const acid_count = 7;
const metal_index = [5]usize{ 0, 1, 2, 2, 2 };
const metal_stoichiometry = [5]f64{ 1, 1, 1, 5, 1 };
const phosphorus_stoichiometry = [5]f64{ 1, 1, 1, 3, 2 };
const base_charge = [5]f64{ 3, 3, 2, 10, 2 };

pub const Inputs = struct {
    aqueous: speciation.Inputs,
    /// carbonate, NH4 non-band/band, phosphate non-band/band, CaOH, MgOH.
    /// These indices describe chemistry, not grid/runtime storage dimensions.
    solids_mol_per_m3: [2][5]f64,
    solubility_products: [5]f64,
    enabled: [2][5]bool,
};

pub const Result = struct {
    aqueous: speciation.Result,
    acids_mol_per_m3: [acid_count][4]f64,
    solids_mol_per_m3: [2][5]f64,
    iterations: u16,
    maximum_scaled_residual: f64,
};

const Evaluation = struct {
    result: Result,
    residual: [dimension]f64,
    jacobian: [dimension * dimension]f64,
    norm: f64,
    roundoff: f64,
};

fn sum(values: []const f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total;
}

fn mean(values: []const f64) f64 {
    const total = sum(values);
    if (total == 0) return 0;
    var weighted: f64 = 0;
    for (values, 0..) |value, index| weighted += value * @as(f64, @floatFromInt(index));
    return weighted / total;
}

fn bound(input: speciation.Inputs) f64 {
    var total = sum(&input.aluminum.concentrations_mol_per_m3) * mean(&input.aluminum.concentrations_mol_per_m3) + sum(&input.iron.concentrations_mol_per_m3) * mean(&input.iron.concentrations_mol_per_m3);
    for (input.acids) |acid| if (acid.water_fraction > 0) {
        total += sum(&acid.concentrations_mol_per_m3) * mean(&acid.concentrations_mol_per_m3) * acid.water_fraction;
    };
    return total;
}

const Context = struct {
    input: Inputs,
    scales: [phase_count]f64,
    metal_totals: [3]f64,
    phosphorus_totals: [2]f64,
    invariant: f64,
    charge_scale: f64,

    fn init(input: Inputs) !Context {
        if (input.aqueous.acids.len != acid_count) return error.InvalidPhosphateSpeciationInput;
        if (input.aqueous.acids[3].species_count != 4 or input.aqueous.acids[4].species_count != 4 or input.aqueous.acids[5].species_count != 2) return error.InvalidPhosphateSpeciationInput;
        var result: Context = .{
            .input = input,
            .scales = @splat(1),
            .metal_totals = .{ sum(&input.aqueous.aluminum.concentrations_mol_per_m3), sum(&input.aqueous.iron.concentrations_mol_per_m3), sum(&input.aqueous.acids[5].concentrations_mol_per_m3) },
            .phosphorus_totals = .{ sum(&input.aqueous.acids[3].concentrations_mol_per_m3), sum(&input.aqueous.acids[4].concentrations_mol_per_m3) },
            .invariant = input.aqueous.hydroxide_mol_per_m3 - input.aqueous.hydrogen_mol_per_m3 + bound(input.aqueous),
            .charge_scale = input.aqueous.hydrogen_mol_per_m3 + input.aqueous.hydroxide_mol_per_m3 + @sqrt(input.aqueous.water_activity_product_mol2_per_m6) / input.aqueous.monovalent_activity_coefficient,
        };
        var total_metals = result.metal_totals;
        var total_phosphorus = result.phosphorus_totals;
        for (0..2) |zone| {
            const fraction = input.aqueous.acids[3 + zone].water_fraction;
            for (0..5) |mineral| {
                const solid = input.solids_mol_per_m3[zone][mineral];
                if (!std.math.isFinite(solid) or solid < 0) return error.InvalidPhosphateSpeciationInput;
                if (!input.enabled[zone][mineral]) continue;
                if (fraction <= 0 or !std.math.isFinite(input.solubility_products[mineral]) or input.solubility_products[mineral] <= 0) return error.InvalidPhosphateSpeciationInput;
                total_metals[metal_index[mineral]] += fraction * solid * metal_stoichiometry[mineral];
                total_phosphorus[zone] += solid * phosphorus_stoichiometry[mineral];
            }
        }
        result.charge_scale += 4 * sum(&total_metals);
        for (input.aqueous.acids) |acid| result.charge_scale += 3 * sum(&acid.concentrations_mol_per_m3) * acid.water_fraction;
        for (0..2) |zone| for (0..5) |mineral| {
            const index = zone * 5 + mineral;
            if (!input.enabled[zone][mineral]) continue;
            result.scales[index] = @min(total_metals[metal_index[mineral]] / metal_stoichiometry[mineral], input.aqueous.acids[3 + zone].water_fraction * total_phosphorus[zone] / phosphorus_stoichiometry[mineral]);
            // A phase with no elemental inventory is chemically inactive.
            if (result.scales[index] == 0) result.input.enabled[zone][mineral] = false;
        };
        if (!std.math.isFinite(result.charge_scale) or result.charge_scale <= 0) return error.InvalidPhosphateSpeciationInput;
        return result;
    }

    fn evaluate(self: Context, coordinates: [dimension]f64) !Evaluation {
        var aqueous = self.input.aqueous;
        var acids: [acid_count]speciation.AcidChain = undefined;
        @memcpy(&acids, aqueous.acids);
        aqueous.acids = &acids;
        var metals = self.metal_totals;
        var phosphorus = self.phosphorus_totals;
        var invariant = self.invariant;
        var solids = self.input.solids_mol_per_m3;
        for (0..phase_count) |index| {
            const zone = index / 5;
            const mineral = index % 5;
            if (!self.input.enabled[zone][mineral]) continue;
            const extent = coordinates[index + 1] * self.scales[index];
            const fraction = acids[3 + zone].water_fraction;
            if (coordinates[index + 1] != 0) {
                const upper = self.input.solids_mol_per_m3[zone][mineral] * fraction / self.scales[index];
                solids[zone][mineral] = (upper - coordinates[index + 1]) * self.scales[index] / fraction;
            }
            if (!std.math.isFinite(solids[zone][mineral]) or solids[zone][mineral] < 0) return error.InadmissiblePhosphateSpeciationTrial;
            metals[metal_index[mineral]] += extent * metal_stoichiometry[mineral];
            phosphorus[zone] += extent * phosphorus_stoichiometry[mineral] / fraction;
            invariant += extent * base_charge[mineral];
        }
        for (metals ++ phosphorus) |total| if (!std.math.isFinite(total) or total < 0) return error.InadmissiblePhosphateSpeciationTrial;
        aqueous.aluminum.concentrations_mol_per_m3 = .{ metals[0], 0, 0, 0, 0 };
        aqueous.iron.concentrations_mol_per_m3 = .{ metals[1], 0, 0, 0, 0 };
        acids[5].concentrations_mol_per_m3 = .{ metals[2], 0, 0, 0 };
        for (0..2) |zone| if (acids[3 + zone].water_fraction > 0) {
            acids[3 + zone].concentrations_mol_per_m3 = .{ phosphorus[zone], 0, 0, 0 };
        };
        const pair = try water.projectProvisional(bound(aqueous) - invariant, 0, aqueous.monovalent_activity_coefficient, aqueous.water_activity_product_mol2_per_m6);
        aqueous.hydrogen_mol_per_m3 = pair.hydrogen_concentration_mol_per_m3;
        aqueous.hydroxide_mol_per_m3 = pair.hydroxide_concentration_mol_per_m3;
        const evaluated = try speciation.evaluateAt(aqueous, coordinates[0]);
        var result: Evaluation = .{
            .result = .{ .aqueous = evaluated.state, .acids_mol_per_m3 = undefined, .solids_mol_per_m3 = solids, .iterations = 0, .maximum_scaled_residual = 0 },
            .residual = @splat(0),
            .jacobian = @splat(0),
            .norm = 0,
            .roundoff = 256 * std.math.floatEps(f64),
        };
        for (acids, 0..) |acid, index| result.result.acids_mol_per_m3[index] = try speciation.acidConcentrations(aqueous, acid, evaluated.state.hydroxide_mol_per_m3);
        const metal_means = [3]f64{ mean(&evaluated.state.aluminum_mol_per_m3), mean(&evaluated.state.iron_mol_per_m3), mean(&result.result.acids_mol_per_m3[5]) };
        const phosphorus_means = [2]f64{ mean(&result.result.acids_mol_per_m3[3]), mean(&result.result.acids_mol_per_m3[4]) };
        const metal_activity = [3]f64{ evaluated.state.aluminum_mol_per_m3[0] * aqueous.trivalent_activity_coefficient, evaluated.state.iron_mol_per_m3[0] * aqueous.trivalent_activity_coefficient, result.result.acids_mol_per_m3[5][0] * aqueous.divalent_activity_coefficient };
        var charge_slopes: [phase_count]f64 = @splat(0);
        for (0..phase_count) |index| {
            const mineral = index % 5;
            charge_slopes[index] = base_charge[mineral] - metal_stoichiometry[mineral] * metal_means[metal_index[mineral]] - phosphorus_stoichiometry[mineral] * phosphorus_means[index / 5];
        }
        result.residual[0] = evaluated.state.charge_balance_residual_mol_per_m3 / self.charge_scale;
        result.jacobian[0] = evaluated.charge_derivative_log_hydroxide / self.charge_scale;
        for (0..phase_count) |index| if (self.input.enabled[index / 5][index % 5]) {
            result.jacobian[index + 1] = -charge_slopes[index] * self.scales[index] / self.charge_scale;
        };
        for (0..phase_count) |index| {
            const row = index + 1;
            const zone = index / 5;
            const mineral = index % 5;
            if (!self.input.enabled[zone][mineral]) {
                result.residual[row] = coordinates[row];
                result.jacobian[row * dimension + row] = 1;
                continue;
            }
            const phosphate = result.result.acids_mol_per_m3[3 + zone];
            const p_activity = switch (mineral) {
                0, 1, 3 => phosphate[3] * aqueous.trivalent_activity_coefficient,
                2 => phosphate[2] * aqueous.divalent_activity_coefficient,
                4 => phosphate[1] * aqueous.monovalent_activity_coefficient,
                else => unreachable,
            };
            // Zero dissolved totals are boundary states; do not manufacture
            // positive mass to make logarithms finite.
            if (metal_activity[metal_index[mineral]] <= 0 or p_activity <= 0) return error.InadmissiblePhosphateSpeciationTrial;
            const log_metal = metal_stoichiometry[mineral] * @log(metal_activity[metal_index[mineral]]);
            const log_phosphate = phosphorus_stoichiometry[mineral] * @log(p_activity);
            const log_hydroxide = if (mineral == 3) @log(evaluated.state.hydroxide_mol_per_m3 * aqueous.monovalent_activity_coefficient) else 0;
            const log_k = @log(self.input.solubility_products[mineral]);
            const affinity = log_metal + log_phosphate + log_hydroxide - log_k;
            const solid = solids[zone][mineral] * acids[3 + zone].water_fraction / self.scales[index];
            const hypotenuse = @sqrt(affinity * affinity + solid * solid);
            // Stable Fischer-Burmeister complementarity: solid >= 0,
            // log(Q/K) <= 0, and a present equilibrium solid has Q/K = 1.
            result.residual[row] = if (affinity < 0) solid * (solid / (hypotenuse - affinity) - 1) else if (hypotenuse == 0) 0 else affinity * (1 + affinity / (hypotenuse + solid));
            const affinity_factor = if (hypotenuse == 0) 1 else 1 + affinity / hypotenuse;
            const solid_factor = if (hypotenuse == 0) 1 else 1 - solid / hypotenuse;
            result.jacobian[row * dimension] = affinity_factor * charge_slopes[index];
            for (0..phase_count) |column_index| {
                if (!self.input.enabled[column_index / 5][column_index % 5]) continue;
                const other = column_index % 5;
                var derivative: f64 = 0;
                if (metal_index[mineral] == metal_index[other]) derivative += metal_stoichiometry[mineral] * metal_stoichiometry[other] / metals[metal_index[mineral]];
                if (zone == column_index / 5) derivative += phosphorus_stoichiometry[mineral] * phosphorus_stoichiometry[other] / (acids[3 + zone].water_fraction * phosphorus[zone]);
                result.jacobian[row * dimension + column_index + 1] = affinity_factor * derivative * self.scales[column_index] + if (index == column_index) solid_factor else @as(f64, 0);
            }
            result.roundoff = @max(result.roundoff, 256 * std.math.floatEps(f64) * (1 + @abs(log_metal) + @abs(log_phosphate) + @abs(log_hydroxide) + @abs(log_k)));
        }
        for (result.residual) |value| {
            if (!std.math.isFinite(value)) return error.InadmissiblePhosphateSpeciationTrial;
            result.norm = @max(result.norm, @abs(value));
        }
        result.result.maximum_scaled_residual = result.norm / result.roundoff;
        return result;
    }
};

/// One bounded Newton–Anderson solve; no nested iteration or retry ladder.
/// An unsuccessful candidate is never returned as local equilibrium.
pub fn solve(input: Inputs) !Result {
    const context = try Context.init(input);
    var coordinates: [dimension]f64 = @splat(0);
    const pair = try water.projectProvisional(input.aqueous.hydrogen_mol_per_m3, input.aqueous.hydroxide_mol_per_m3, input.aqueous.monovalent_activity_coefficient, input.aqueous.water_activity_product_mol2_per_m6);
    coordinates[0] = @log(pair.hydroxide_concentration_mol_per_m3);
    // Validate the original species, before redistributing any family totals.
    _ = try speciation.evaluateAt(input.aqueous, coordinates[0]);
    var current = try context.evaluate(coordinates);
    var iteration: u16 = 0;
    while (current.norm > current.roundoff and iteration < input.aqueous.max_iterations) : (iteration += 1) {
        if (input.aqueous.shared_budget) |budget| try budget.beginIteration();
        var matrix = current.jacobian;
        var step = current.residual;
        for (&step) |*value| value.* = -value.*;
        if (!numerics.solveDenseLinearSystem(&matrix, &step, dimension)) return error.SingularPhosphateSpeciationJacobian;
        var fixed: [phase_count]bool = @splat(false);
        for (0..phase_count) |_| {
            var added = false;
            for (0..phase_count) |index| {
                if (!context.input.enabled[index / 5][index % 5]) continue;
                const upper = input.solids_mol_per_m3[index / 5][index % 5] * input.aqueous.acids[3 + index / 5].water_fraction / context.scales[index];
                if (step[index + 1] > upper - coordinates[index + 1] and !fixed[index]) {
                    fixed[index] = true;
                    added = true;
                }
            }
            if (!added) break;
            matrix = current.jacobian;
            step = current.residual;
            for (&step) |*value| value.* = -value.*;
            for (fixed, 0..) |is_fixed, index| if (is_fixed) {
                const row = index + 1;
                @memset(matrix[row * dimension ..][0..dimension], 0);
                matrix[row * dimension + row] = 1;
                const upper = input.solids_mol_per_m3[index / 5][index % 5] * input.aqueous.acids[3 + index / 5].water_fraction / context.scales[index];
                step[row] = upper - coordinates[row];
            };
            if (!numerics.solveDenseLinearSystem(&matrix, &step, dimension)) return error.SingularPhosphateSpeciationJacobian;
        }
        // Reapply the exact linear face equations after elimination. Dense
        // pivot roundoff must not create a positive dissolution direction
        // for an absent phase during fractional line-search trials.
        for (fixed, 0..) |is_fixed, index| if (is_fixed) {
            const upper = input.solids_mol_per_m3[index / 5][index % 5] * input.aqueous.acids[3 + index / 5].water_fraction / context.scales[index];
            step[index + 1] = upper - coordinates[index + 1];
        };
        var fraction: f64 = 1;
        var improved = false;
        const previous_coordinates = coordinates;
        const previous = current;
        for (0..12) |_| {
            var trial = coordinates;
            for (&trial, step) |*value, delta| value.* += fraction * delta;
            if (fraction == 1) for (fixed, 0..) |is_fixed, index| {
                if (is_fixed) trial[index + 1] = input.solids_mol_per_m3[index / 5][index % 5] * input.aqueous.acids[3 + index / 5].water_fraction / context.scales[index];
            };
            const candidate = context.evaluate(trial) catch |err| switch (err) {
                error.InadmissiblePhosphateSpeciationTrial => {
                    fraction *= 0.5;
                    continue;
                },
                else => return err,
            };
            if (candidate.norm < current.norm) {
                coordinates = trial;
                current = candidate;
                improved = true;
                break;
            }
            fraction *= 0.5;
        }
        if (!improved) return error.PhosphateSpeciationStagnated;
        var accelerated: [dimension]f64 = undefined;
        if (numerics.andersonDepthOneCandidate(&previous_coordinates, &previous.residual, &coordinates, &current.residual, &accelerated)) {
            const candidate = context.evaluate(accelerated) catch |err| switch (err) {
                error.InadmissiblePhosphateSpeciationTrial => continue,
                else => return err,
            };
            if (candidate.norm < current.norm) {
                coordinates = accelerated;
                current = candidate;
            }
        }
    }
    if (current.norm > current.roundoff) return error.PhosphateSpeciationDidNotConverge;
    if (@abs(current.residual[0]) > 128 * std.math.floatEps(f64)) return error.HydroxideSpeciationChargeImbalance;
    current.result.iterations = iteration;
    return current.result;
}

test "coupled phosphate speciation analytic Jacobian includes shared metals and fractional charge" {
    var acids: [acid_count]speciation.AcidChain = @splat(.{ .species_count = 2, .concentrations_mol_per_m3 = .{ 1, 0, 0, 0 }, .dissociation_constants = .{ 1, 0, 0 }, .activity_coefficients = .{ 1, 1, 0, 0 }, .water_fraction = 1 });
    for (3..5) |index| acids[index] = .{ .species_count = 4, .concentrations_mol_per_m3 = .{ 1, 0, 0, 0 }, .dissociation_constants = .{ 1, 1, 1 }, .activity_coefficients = .{ 1, 1, 1, 1 }, .water_fraction = if (index == 3) 0.25 else 0.75 };
    const context = try Context.init(.{
        .aqueous = .{
            .aluminum = .{ .concentrations_mol_per_m3 = .{ 1, 0, 0, 0, 0 }, .dissociation_constants = @splat(1) },
            .iron = .{ .concentrations_mol_per_m3 = .{ 1, 0, 0, 0, 0 }, .dissociation_constants = @splat(1) },
            .hydrogen_mol_per_m3 = 1,
            .hydroxide_mol_per_m3 = 1,
            .monovalent_activity_coefficient = 1,
            .divalent_activity_coefficient = 1,
            .trivalent_activity_coefficient = 1,
            .water_activity_product_mol2_per_m6 = 1,
            .max_iterations = 20,
            .acids = &acids,
        },
        .solids_mol_per_m3 = @splat(@splat(1)),
        .solubility_products = @splat(1),
        .enabled = @splat(@splat(true)),
    });
    const coordinates: [dimension]f64 = @splat(0);
    const base = try context.evaluate(coordinates);
    const h = std.math.cbrt(std.math.floatEps(f64));
    for (0..dimension) |column| {
        var positive = coordinates;
        var negative = coordinates;
        positive[column] += h;
        negative[column] -= h;
        const plus = try context.evaluate(positive);
        const minus = try context.evaluate(negative);
        for (0..dimension) |row| {
            const analytic = base.jacobian[row * dimension + column];
            const finite_difference = (plus.residual[row] - minus.residual[row]) / (2 * h);
            try std.testing.expectApproxEqAbs(analytic, finite_difference, 64 * @sqrt(std.math.floatEps(f64)) * @max(1, @abs(analytic)));
        }
    }
}

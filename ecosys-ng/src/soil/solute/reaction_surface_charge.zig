//! Conservative local surface/acid candidate. Mineral and ion-pair pools stay
//! fixed; the caller must price the candidate against the complete network.
const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const phosphate = @import("phosphate_network.zig");
const surface = @import("phosphate_surface_stationarity.zig");
const exchange = @import("phosphate_exchange.zig");
const numerics = @import("../../core/numerics.zig");
const activity = @import("activity_coefficients.zig");
const classification = @import("charge_classification.zig");
const dimension = 6; // log H, two free-P/site pairs, log ionic strength.

pub fn coefficients(log_strength: f64) !activity.Result {
    var totals = std.mem.zeroes(activity.ChargeClassTotals);
    totals.monovalent_cations_mol = 2000 * @exp(log_strength);
    return activity.calculate(totals, 1);
}

pub fn freeP(z: phosphate.State) f64 {
    return z.dissolved_po4_mol_p_per_m3 + z.dissolved_hpo4_mol_p_per_m3 + z.dissolved_h2po4_mol_p_per_m3 + z.dissolved_h3po4_mol_p_per_m3;
}
fn zoneCharge(z: phosphate.State, density: f64) f64 {
    return density * (z.protonated_site_mol_per_megagram - z.deprotonated_site_mol_per_megagram - z.adsorbed_hpo4_mol_p_per_megagram) - 3 * z.dissolved_po4_mol_p_per_m3 - 2 * z.dissolved_hpo4_mol_p_per_m3 - z.dissolved_h2po4_mol_p_per_m3;
}
pub const Evaluation = struct {
    zones: [2]phosphate.State,
    carboxyl: f64,
    residual: [dimension]f64,
    norm: f64,
};
pub const Context = struct {
    parameters: chemistry.ReactionParameters,
    before: [2]phosphate.State,
    fractions: [2]f64,
    densities: [2]f64,
    capacities: [2]f64,
    totals: [2]f64,
    aqueous: @import("aqueous_network.zig").State,
    invariant: f64,
    charge_scale: f64,
    carboxyl: f64,

    pub fn evaluate(self: Context, x: [dimension]f64) !Evaluation {
        return self.evaluateWithActivities(x, try coefficients(x[5]));
    }

    /// `coefficients` is a pure function of `x[5]`, and the coupled
    /// surface/mineral candidate has already evaluated it for exactly this
    /// coordinate vector before calling in. Accepting the retained value
    /// removes one of the four Debye-Huckel evaluations that every
    /// finite-difference probe of that 26-coordinate target performed, and
    /// is bit-identical because the argument is the same.
    pub fn evaluateWithActivities(self: Context, x: [dimension]f64, activities: activity.Result) !Evaluation {
        var profile_scope = @import("reaction_diagnostic_control.zig").beginPhase(.surface_charge_target);
        defer profile_scope.end();
        const gamma: [3]f64 = .{ activities.monovalent_activity_coefficient, activities.divalent_activity_coefficient, activities.trivalent_activity_coefficient };
        const h = @exp(x[0]);
        const ah = h * gamma[0];
        const oh = self.parameters.water_activity_product_mol2_per_m6 / ah / gamma[0];
        if (!std.math.isFinite(h + oh) or h <= 0 or oh <= 0) return error.InvalidSurfaceChargeTrial;
        var result: Evaluation = .{ .zones = self.before, .carboxyl = self.carboxyl, .residual = @splat(0), .norm = 0 };
        var charge = h - oh;
        for (&result.zones, 0..) |*zone, i| {
            const pi = 1 + 2 * i;
            const xi = pi + 1;
            result.residual[pi] = x[pi];
            result.residual[xi] = x[xi];
            if (self.fractions[i] == 0) continue;
            const p = if (self.totals[i] == 0) 0 else self.totals[i] * @exp(x[pi]);
            const neutral = if (self.capacities[i] == 0) 0 else self.capacities[i] * @exp(x[xi]);
            const constants = self.parameters.phosphate_constants;
            zone.dissolved_h2po4_mol_p_per_m3 = p;
            zone.dissolved_h3po4_mol_p_per_m3 = p * gamma[0] * ah / constants.h3po4;
            zone.dissolved_hpo4_mol_p_per_m3 = p * gamma[0] * constants.h2po4 / (ah * gamma[1]);
            zone.dissolved_po4_mol_p_per_m3 = zone.dissolved_hpo4_mol_p_per_m3 * gamma[1] * constants.hpo4 / (ah * gamma[2]);
            if (self.capacities[i] > 0) {
                const inputs: exchange.Inputs = .{
                    .hydrogen_concentration_mol_per_m3 = h,
                    .hydrogen_activity_mol_per_m3 = ah,
                    .hydroxide_activity_mol_per_m3 = oh * gamma[0],
                    .h2po4_concentration_mol_p_per_m3 = p,
                    .h2po4_activity_mol_p_per_m3 = p * gamma[0],
                    .hpo4_concentration_mol_p_per_m3 = zone.dissolved_hpo4_mol_p_per_m3,
                    .hpo4_activity_mol_p_per_m3 = zone.dissolved_hpo4_mol_p_per_m3 * gamma[1],
                    .deprotonated_site_mol_per_megagram = 0,
                    .hydroxyl_site_mol_per_megagram = 0,
                    .protonated_site_mol_per_megagram = 0,
                    .adsorbed_h2po4_mol_p_per_megagram = 0,
                    .adsorbed_hpo4_mol_p_per_megagram = 0,
                    .monovalent_activity_coefficient = gamma[0],
                    .divalent_activity_coefficient = gamma[1],
                };
                const sites = (try surface.atFreeConcentrations(inputs, self.parameters.phosphate_surface, neutral)).sites;
                zone.deprotonated_site_mol_per_megagram = sites[0];
                zone.hydroxyl_site_mol_per_megagram = sites[1];
                zone.protonated_site_mol_per_megagram = sites[2];
                zone.adsorbed_hpo4_mol_p_per_megagram = sites[3];
                zone.adsorbed_h2po4_mol_p_per_megagram = sites[4];
                result.residual[xi] = @log((try phosphate.siteInventory(zone.*)) / self.capacities[i]);
            }
            if (self.totals[i] > 0) result.residual[pi] = @log((freeP(zone.*) + self.densities[i] * (zone.adsorbed_hpo4_mol_p_per_megagram + zone.adsorbed_h2po4_mol_p_per_megagram)) / self.totals[i]);
            charge += self.fractions[i] * zoneCharge(zone.*, self.densities[i]);
        }
        const cp = self.parameters.carboxyl_exchange_parameters;
        if (cp.maximum_exchange_mol_per_m3_per_iteration > 0 and cp.substrate_limit_fraction_per_iteration > 0)
            result.carboxyl = self.parameters.total_carboxyl_sites_mol_per_megagram * ah / (ah + cp.dissociation_constant_mol_per_m3);
        charge += self.parameters.cation_exchange_water_ratios.shared_megagrams_per_m3 * result.carboxyl;
        result.residual[0] = (charge - self.invariant) / self.charge_scale;
        var aqueous = self.aqueous;
        aqueous.hydrogen = h;
        aqueous.hydroxide = oh;
        const actual = try activity.calculate(try classification.classify(aqueous, result.zones[0], result.zones[1], self.parameters.fractions), 1);
        result.residual[5] = @log(actual.ionic_strength_mol_per_l) - x[5];
        for (result.residual) |r| {
            if (!std.math.isFinite(r)) return error.InvalidSurfaceChargeTrial;
            result.norm = @max(result.norm, @abs(r));
        }
        return result;
    }
};

/// Returns a native conservative transformation after a bounded local
/// Newton–Anderson inversion. Roundoff convergence here enforces inventories,
/// not the complete chemistry's independent physical acceptance budgets.
pub fn initialize(scratch: *chemistry.State, current: []const f64, parameters: chemistry.ReactionParameters, x: *[dimension]f64) !Context {
    try scratch.unpackCell(0, current);
    if (parameters.phosphate_kinetics.substrate_limit_fraction == 0 or parameters.phosphate_kinetics.maximum_pairing_mol_per_m3_step == 0) return error.UnsupportedSurfaceChargeInput;
    const gamma = try scratch.activityCoefficients(0, parameters.fractions);
    const aq = scratch.aqueous[0];
    var context: Context = .{
        .parameters = parameters,
        .before = .{ scratch.non_band_phosphate[0], scratch.band_phosphate[0] },
        .fractions = .{ parameters.fractions.phosphate_non_band, parameters.fractions.phosphate_band },
        .densities = .{ parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3, parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 },
        .capacities = @splat(0),
        .totals = @splat(0),
        .aqueous = aq,
        .invariant = aq.hydrogen - aq.hydroxide,
        .charge_scale = aq.hydrogen + aq.hydroxide,
        .carboxyl = scratch.carboxyl_bound_hydrogen_mol_per_megagram[0],
    };
    x.* = @splat(0);
    x[0] = @log(aq.hydrogen);
    x[5] = @log(gamma.ionic_strength_mol_per_l);
    for (context.before, 0..) |zone, i| {
        if (context.fractions[i] == 0) continue;
        context.capacities[i] = try phosphate.siteInventory(zone);
        context.totals[i] = freeP(zone) + context.densities[i] * (zone.adsorbed_hpo4_mol_p_per_megagram + zone.adsorbed_h2po4_mol_p_per_megagram);
        context.invariant += context.fractions[i] * zoneCharge(zone, context.densities[i]);
        context.charge_scale += context.fractions[i] * (3 * context.totals[i] + context.densities[i] * context.capacities[i]);
        if (context.totals[i] > 0) x[1 + 2 * i] = @log(@max(0.001, zone.dissolved_h2po4_mol_p_per_m3 / context.totals[i]));
        if (context.capacities[i] > 0) x[2 + 2 * i] = @log(@max(0.001, zone.hydroxyl_site_mol_per_megagram / context.capacities[i]));
    }
    const density = parameters.cation_exchange_water_ratios.shared_megagrams_per_m3;
    context.invariant += density * context.carboxyl;
    context.charge_scale += density * parameters.total_carboxyl_sites_mol_per_megagram;
    return context;
}

pub fn candidate(scratch: *chemistry.State, current: []const f64, parameters: chemistry.ReactionParameters, maximum_iterations: u16, output: []f64) !u16 {
    var profile_scope = @import("reaction_diagnostic_control.zig").beginPhase(.local_charge_candidate);
    defer profile_scope.end();
    var x: [dimension]f64 = undefined;
    const context = try initialize(scratch, current, parameters, &x);
    var value = try context.evaluate(x);
    var iteration: u16 = 0;
    const roundoff = 16 * std.math.floatEps(f64);
    while (value.norm > roundoff and iteration < maximum_iterations) : (iteration += 1) {
        var jacobian: [dimension * dimension]f64 = undefined;
        const probe = std.math.cbrt(std.math.floatEps(f64));
        for (0..dimension) |column| {
            var plus = x;
            var minus = x;
            plus[column] += probe;
            minus[column] -= probe;
            const positive = try context.evaluate(plus);
            const negative = try context.evaluate(minus);
            for (0..dimension) |row| jacobian[row * dimension + column] = (positive.residual[row] - negative.residual[row]) / (2 * probe);
        }
        var step = value.residual;
        for (&step) |*r| r.* = -r.*;
        if (!numerics.solveDenseLinearSystem(&jacobian, &step, dimension)) return error.SingularSurfaceChargeJacobian;
        const previous_x = x;
        const previous_value = value;
        var improved = false;
        var fraction: f64 = 1;
        for (0..16) |_| {
            var trial = x;
            for (&trial, step) |*coordinate, delta| coordinate.* += fraction * delta;
            const next = context.evaluate(trial) catch {
                fraction *= 0.5;
                continue;
            };
            if (next.norm < value.norm) {
                x = trial;
                value = next;
                improved = true;
                break;
            }
            fraction *= 0.5;
        }
        var accelerated: [dimension]f64 = undefined;
        if (numerics.andersonDepthOneCandidate(&previous_x, &previous_value.residual, &x, &value.residual, &accelerated)) {
            if (context.evaluate(accelerated)) |next| {
                if (next.norm < value.norm) {
                    x = accelerated;
                    value = next;
                    improved = true;
                }
            } else |_| {}
        }
        if (!improved) return error.SurfaceChargeStagnated;
    }
    if (value.norm > roundoff) return error.SurfaceChargeDidNotConverge;
    const changes = try transformations(context, value);
    try @import("reaction_solver_numerics.zig").transformedVector(scratch, current, changes, (try coefficients(x[5])).monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, 1, output);
    return iteration;
}

pub fn transformations(context: Context, value: Evaluation) !chemistry.CellTransformations {
    const parameters = context.parameters;
    var changes = @import("conservative_reaction_span.zig").zeroTransformations(parameters);
    for (context.before, value.zones, 0..) |before, after, i| {
        if (context.fractions[i] == 0) continue;
        var fluxes: phosphate.Fluxes = std.mem.zeroes(phosphate.Fluxes);
        fluxes.soil_mass_per_water_volume_megagrams_per_m3 = context.densities[i];
        fluxes.surface.protonated_to_hydroxyl_site_mol_per_megagram = after.protonated_site_mol_per_megagram - before.protonated_site_mol_per_megagram;
        fluxes.surface.hydroxyl_to_deprotonated_site_mol_per_megagram = before.deprotonated_site_mol_per_megagram - after.deprotonated_site_mol_per_megagram;
        fluxes.surface.h2po4_with_hydroxyl_site_mol_p_per_megagram = after.adsorbed_h2po4_mol_p_per_megagram - before.adsorbed_h2po4_mol_p_per_megagram;
        fluxes.surface.hpo4_with_hydroxyl_site_mol_p_per_megagram = after.adsorbed_hpo4_mol_p_per_megagram - before.adsorbed_hpo4_mol_p_per_megagram;
        fluxes.aqueous.po4_hydrogen_association_mol_p_per_m3 = before.dissolved_po4_mol_p_per_m3 - after.dissolved_po4_mol_p_per_m3;
        fluxes.aqueous.h2po4_hydrogen_association_mol_p_per_m3 = after.dissolved_h3po4_mol_p_per_m3 - before.dissolved_h3po4_mol_p_per_m3;
        fluxes.aqueous.hpo4_hydrogen_association_mol_p_per_m3 = fluxes.aqueous.po4_hydrogen_association_mol_p_per_m3 - fluxes.surface.hpo4_with_hydroxyl_site_mol_p_per_megagram * context.densities[i] - (after.dissolved_hpo4_mol_p_per_m3 - before.dissolved_hpo4_mol_p_per_m3);
        const assembled = try phosphate.assemble(fluxes);
        if (i == 0) changes.non_band_phosphate = assembled else changes.band_phosphate = assembled;
    }
    changes.carboxyl_hydrogen_change_mol_per_megagram = value.carboxyl - context.carboxyl;
    return changes;
}

const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const speciation = @import("hydroxide_speciation.zig");
const numerics = @import("../../core/numerics.zig");
const phosphate_speciation = @import("phosphate_local_speciation.zig");

/// Builds a conservative candidate without touching the accepted vector.
/// The caller must evaluate the complete network at this candidate; frozen
/// activity-coefficient local equilibrium is not full-network convergence.
pub fn hydroxideCandidate(
    scratch: *chemistry.State,
    current: []const f64,
    parameters: chemistry.ReactionParameters,
    budget: *numerics.NonlinearBudget,
    output: []f64,
) !bool {
    return candidate(scratch, current, parameters, budget, output, false, false);
}

pub fn acidBaseCandidate(scratch: *chemistry.State, current: []const f64, parameters: chemistry.ReactionParameters, budget: *numerics.NonlinearBudget, output: []f64) !bool {
    return candidate(scratch, current, parameters, budget, output, true, false);
}

pub fn phosphateCandidate(scratch: *chemistry.State, current: []const f64, parameters: chemistry.ReactionParameters, budget: *numerics.NonlinearBudget, output: []f64) !bool {
    return candidate(scratch, current, parameters, budget, output, true, true);
}

const solid_fields = .{ "aluminum_phosphate_solid_mol_per_m3", "iron_phosphate_solid_mol_per_m3", "dicalcium_phosphate_solid_mol_per_m3", "hydroxyapatite_solid_mol_per_m3", "monocalcium_phosphate_solid_mol_per_m3" };

fn candidate(scratch: *chemistry.State, current: []const f64, parameters: chemistry.ReactionParameters, budget: *numerics.NonlinearBudget, output: []f64, comptime include_acids: bool, comptime include_minerals: bool) !bool {
    if (parameters.aqueous_kinetics.general_substrate_limit_fraction == 0 or
        parameters.aqueous_kinetics.maximum_slow_association_mol_per_m3_step == 0 or budget.remaining() == 0) return false;
    const constants = parameters.aqueous_constants;
    const aluminum_constants = [4]f64{ constants.aluminum_hydroxide_1, constants.aluminum_hydroxide_2, constants.aluminum_hydroxide_3, constants.aluminum_hydroxide_4 };
    const iron_constants = [4]f64{ constants.iron_hydroxide_1, constants.iron_hydroxide_2, constants.iron_hydroxide_3, constants.iron_hydroxide_4 };
    // Zero dissociation constants describe irreversible limits, not the
    // finite equilibrium chains this elimination represents.
    for (aluminum_constants ++ iron_constants) |constant| if (constant == 0) return false;
    try scratch.unpackCell(0, current);
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    const before = scratch.aqueous[0];
    const g1 = coefficients.monovalent_activity_coefficient;
    const g2 = coefficients.divalent_activity_coefficient;
    const g3 = coefficients.trivalent_activity_coefficient;
    const ammonium_active = parameters.aqueous_kinetics.ammonium_substrate_limit_fraction > 0 and parameters.aqueous_kinetics.maximum_fast_association_mol_per_m3_step > 0;
    const phosphate_active = parameters.phosphate_kinetics.substrate_limit_fraction > 0 and parameters.phosphate_kinetics.maximum_pairing_mol_per_m3_step > 0;
    var acids = [_]speciation.AcidChain{
        .{ .species_count = 3, .concentrations_mol_per_m3 = .{ before.carbon_dioxide, before.bicarbonate, before.carbonate, 0 }, .dissociation_constants = .{ constants.carbon_dioxide, constants.bicarbonate, 0 }, .activity_coefficients = .{ 1, g1, g2, 0 }, .water_fraction = if (parameters.aqueous_kinetics.maximum_fast_association_mol_per_m3_step > 0) 1 else 0 },
        .{ .species_count = 2, .concentrations_mol_per_m3 = .{ before.ammonium_non_band, before.ammonia_non_band, 0, 0 }, .dissociation_constants = .{ constants.ammonium, 0, 0 }, .activity_coefficients = .{ g1, 1, 0, 0 }, .water_fraction = if (ammonium_active) parameters.fractions.ammonium_non_band else 0 },
        .{ .species_count = 2, .concentrations_mol_per_m3 = .{ before.ammonium_band, before.ammonia_band, 0, 0 }, .dissociation_constants = .{ constants.ammonium, 0, 0 }, .activity_coefficients = .{ g1, 1, 0, 0 }, .water_fraction = if (ammonium_active) parameters.fractions.ammonium_band else 0 },
        undefined,
        undefined,
        .{ .species_count = 2, .concentrations_mol_per_m3 = .{ before.calcium, before.calcium_hydroxide, 0, 0 }, .dissociation_constants = .{ if (constants.calcium_hydroxide > 0) parameters.water_activity_product_mol2_per_m6 / constants.calcium_hydroxide else 0, 0, 0 }, .activity_coefficients = .{ g2, g1, 0, 0 }, .water_fraction = 1 },
        .{ .species_count = 2, .concentrations_mol_per_m3 = .{ before.magnesium, before.magnesium_hydroxide, 0, 0 }, .dissociation_constants = .{ if (constants.magnesium_hydroxide > 0) parameters.water_activity_product_mol2_per_m6 / constants.magnesium_hydroxide else 0, 0, 0 }, .activity_coefficients = .{ g2, g1, 0, 0 }, .water_fraction = 1 },
    };
    for ([_]@TypeOf(scratch.non_band_phosphate[0]){ scratch.non_band_phosphate[0], scratch.band_phosphate[0] }, 0..) |zone, index| {
        acids[3 + index] = .{
            .species_count = 4,
            .concentrations_mol_per_m3 = .{ zone.dissolved_h3po4_mol_p_per_m3, zone.dissolved_h2po4_mol_p_per_m3, zone.dissolved_hpo4_mol_p_per_m3, zone.dissolved_po4_mol_p_per_m3 },
            .dissociation_constants = .{ parameters.phosphate_constants.h3po4, parameters.phosphate_constants.h2po4, parameters.phosphate_constants.hpo4 },
            .activity_coefficients = .{ 1, g1, g2, g3 },
            .water_fraction = if (!phosphate_active) 0 else if (index == 0) parameters.fractions.phosphate_non_band else parameters.fractions.phosphate_band,
        };
    }
    if (include_acids) for (acids) |acid| {
        if (acid.water_fraction == 0) continue;
        for (acid.dissociation_constants[0 .. acid.species_count - 1]) |constant| if (constant == 0) return false;
    };
    const inputs: speciation.Inputs = .{
        .aluminum = .{
            .concentrations_mol_per_m3 = .{ before.aluminum, before.aluminum_hydroxide_1, before.aluminum_hydroxide_2, before.aluminum_hydroxide_3, before.aluminum_hydroxide_4 },
            .dissociation_constants = aluminum_constants,
        },
        .iron = .{
            .concentrations_mol_per_m3 = .{ before.iron, before.iron_hydroxide_1, before.iron_hydroxide_2, before.iron_hydroxide_3, before.iron_hydroxide_4 },
            .dissociation_constants = iron_constants,
        },
        .hydrogen_mol_per_m3 = before.hydrogen,
        .hydroxide_mol_per_m3 = before.hydroxide,
        .monovalent_activity_coefficient = coefficients.monovalent_activity_coefficient,
        .divalent_activity_coefficient = coefficients.divalent_activity_coefficient,
        .trivalent_activity_coefficient = coefficients.trivalent_activity_coefficient,
        .water_activity_product_mol2_per_m6 = parameters.water_activity_product_mol2_per_m6,
        .max_iterations = budget.remaining(),
        .shared_budget = budget,
        .acids = if (include_acids) &acids else &.{},
    };
    var mineral_result: ?phosphate_speciation.Result = null;
    const result = if (include_minerals) mineral: {
        const p = parameters.phosphate_minerals orelse return false;
        var solids: [2][5]f64 = undefined;
        var enabled: [2][5]bool = undefined;
        for ([_]@TypeOf(scratch.non_band_phosphate[0]){ scratch.non_band_phosphate[0], scratch.band_phosphate[0] }, 0..) |zone, index| {
            inline for (solid_fields, 0..) |name, mineral| solids[index][mineral] = @field(zone, name);
            const active = acids[3 + index].water_fraction > 0;
            enabled[index] = .{ active and p.maximum_phosphate_precipitation_mol_per_m3_step > 0, active and p.maximum_phosphate_precipitation_mol_per_m3_step > 0, active and p.maximum_phosphate_precipitation_mol_per_m3_step > 0, active and p.maximum_apatite_precipitation_mol_per_m3_step > 0, active and p.maximum_phosphate_precipitation_mol_per_m3_step > 0 and p.maximum_mineral_dissolution_mol_per_m3_step > 0 };
        }
        mineral_result = phosphate_speciation.solve(.{ .aqueous = inputs, .solids_mol_per_m3 = solids, .solubility_products = .{ p.aluminum_phosphate_solubility_product, p.iron_phosphate_solubility_product, p.dicalcium_phosphate_solubility_product, p.hydroxyapatite_solubility_product, p.monocalcium_phosphate_solubility_product }, .enabled = enabled }) catch |err| switch (err) {
            error.PhosphateSpeciationStagnated, error.PhosphateSpeciationDidNotConverge, error.SingularPhosphateSpeciationJacobian, error.NonlinearIterationBudgetExhausted, error.InadmissiblePhosphateSpeciationTrial => return false,
            else => return err,
        };
        break :mineral mineral_result.?.aqueous;
    } else speciation.solve(inputs) catch |err| switch (err) {
        error.NewtonPicardDiverged, error.NewtonPicardStagnated, error.NewtonPicardDidNotConverge, error.NonlinearIterationBudgetExhausted => return false,
        else => return err,
    };
    var after = before;
    after.hydrogen = result.hydrogen_mol_per_m3;
    after.hydroxide = result.hydroxide_mol_per_m3;
    after.aluminum = result.aluminum_mol_per_m3[0];
    after.iron = result.iron_mol_per_m3[0];
    inline for (1..5) |index| {
        const suffix = .{ "1", "2", "3", "4" }[index - 1];
        @field(after, "aluminum_hydroxide_" ++ suffix) = result.aluminum_mol_per_m3[index];
        @field(after, "iron_hydroxide_" ++ suffix) = result.iron_mol_per_m3[index];
    }
    if (include_acids) {
        const carbon = if (mineral_result) |mineral| mineral.acids_mol_per_m3[0] else try speciation.acidConcentrations(inputs, acids[0], after.hydroxide);
        const ammonium_non_band = if (mineral_result) |mineral| mineral.acids_mol_per_m3[1] else try speciation.acidConcentrations(inputs, acids[1], after.hydroxide);
        const ammonium_band = if (mineral_result) |mineral| mineral.acids_mol_per_m3[2] else try speciation.acidConcentrations(inputs, acids[2], after.hydroxide);
        after.carbon_dioxide = carbon[0];
        after.bicarbonate = carbon[1];
        after.carbonate = carbon[2];
        after.ammonium_non_band = ammonium_non_band[0];
        after.ammonia_non_band = ammonium_non_band[1];
        after.ammonium_band = ammonium_band[0];
        after.ammonia_band = ammonium_band[1];
        const calcium = if (mineral_result) |mineral| mineral.acids_mol_per_m3[5] else try speciation.acidConcentrations(inputs, acids[5], after.hydroxide);
        const magnesium = if (mineral_result) |mineral| mineral.acids_mol_per_m3[6] else try speciation.acidConcentrations(inputs, acids[6], after.hydroxide);
        after.calcium = calcium[0];
        after.calcium_hydroxide = calcium[1];
        after.magnesium = magnesium[0];
        after.magnesium_hydroxide = magnesium[1];
        const next_water = scratch.water_mol_per_m3[0] + (after.carbon_dioxide - before.carbon_dioxide);
        if (!std.math.isFinite(next_water) or next_water < 0) return error.InvalidLocalSpeciationWaterInventory;
        scratch.water_mol_per_m3[0] = next_water;
        for ([_]*@TypeOf(scratch.non_band_phosphate[0]){ &scratch.non_band_phosphate[0], &scratch.band_phosphate[0] }, 0..) |zone, index| {
            const phosphate = if (mineral_result) |mineral| mineral.acids_mol_per_m3[3 + index] else try speciation.acidConcentrations(inputs, acids[3 + index], after.hydroxide);
            zone.dissolved_h3po4_mol_p_per_m3 = phosphate[0];
            zone.dissolved_h2po4_mol_p_per_m3 = phosphate[1];
            zone.dissolved_hpo4_mol_p_per_m3 = phosphate[2];
            zone.dissolved_po4_mol_p_per_m3 = phosphate[3];
            if (mineral_result) |mineral| inline for (solid_fields, 0..) |name, phase| {
                @field(zone.*, name) = mineral.solids_mol_per_m3[index][phase];
            };
        }
    }
    scratch.aqueous[0] = after;
    try scratch.packCell(0, output);
    return true;
}

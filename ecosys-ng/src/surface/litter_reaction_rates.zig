const std = @import("std");
const chemistry = @import("litter_chemistry.zig");
const ledger = @import("litter_reaction_transformations.zig");
const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const ion_pairing = @import("../soil/solute/ion_pairing.zig");
const cation_exchange = @import("../soil/solute/cation_exchange.zig");
const phosphate_precipitation = @import("../soil/solute/phosphate_precipitation.zig");
const mineral_precipitation = @import("../soil/solute/mineral_precipitation.zig");
const water_equilibrium = @import("../soil/solute/water_equilibrium.zig");
const phosphate_exchange = @import("../soil/solute/phosphate_exchange.zig");
const core_numerics = @import("../core/numerics.zig");
const arith = @import("litter_chemistry_struct_arithmetic.zig");
const chemistry_numerics = @import("litter_chemistry_numerics.zig");

pub const DissociationConstants = struct {
    ammonium: f64,
    carbon_dioxide: f64,
    bicarbonate: f64,
    h2po4: f64,
    hpo4: f64,
    carboxyl: f64,
};

pub const MineralProducts = struct {
    aluminum_phosphate: f64,
    iron_phosphate: f64,
    dicalcium_phosphate: f64,
    hydroxyapatite: f64,
    monocalcium_phosphate: f64,
    gibbsite: f64,
    iron_hydroxide: f64,
    calcite: f64,
    gypsum: f64,
    fixed_ph_aluminum_h2po4: f64,
    fixed_ph_iron_h2po4: f64,
    fixed_ph_hydroxyapatite_h2po4: f64,
};

pub const Kinetics = struct {
    ammonium_substrate_limit_fraction: f64,
    general_substrate_limit_fraction: f64,
    maximum_ammonium_association_mol_per_m3_step: f64,
    maximum_association_mol_per_m3_step: f64,
    maximum_phosphate_precipitation_mol_per_m3_step: f64,
    maximum_apatite_precipitation_mol_per_m3_step: f64,
    maximum_monocalcium_dissolution_mol_per_m3_step: f64,
    maximum_cation_adsorption_mol_charge_per_m3_step: f64,
    calcite_hydroxide_inhibition_constant_mol_per_m3: f64,
};

pub const Parameters = struct {
    activity: activity_coefficients.Result,
    dissociation: DissociationConstants,
    minerals: MineralProducts,
    kinetics: Kinetics,
    cation_exchange_capacity_mol_charge_per_megagram: f64,
    cation_selectivity: cation_exchange.Selectivity,
    water_activity_product_mol2_per_m6: f64,
    negligible_water_ion_concentration_mol_per_m3: f64,
    external_hydrogen_mol_per_m3: f64 = 0,
    phosphate_surface: phosphate_exchange.Parameters = .{
        .protonated_site_equilibrium_constant = 0,
        .hydroxyl_site_equilibrium_constant = 0,
        .h2po4_exchange_equilibrium_constant = 0,
        .hpo4_exchange_equilibrium_constant = 0,
        .water_activity_product_mol2_per_m6 = 0,
        .h2po4_dissociation_constant = 0,
        .maximum_exchange_mol_per_megagram_step = 0,
        .substrate_limit_fraction = 0,
    },
};

pub const Context = struct {
    parameters: Parameters,
    litter_mass_per_water_volume_megagrams_per_m3: f64,
    dynamic_salts: bool,
    solver_options: chemistry.Options = .{},

    pub fn evaluator(self: *const Context) chemistry.Evaluator {
        return .{
            .context = self,
            .evaluate = evaluateOpaque,
            .equilibrate_cation_exchange = equilibrateCationExchangeOpaque,
            .phosphate_mineral_equilibrium_residuals = phosphateMineralEquilibriumResidualsOpaque,
            // SOLUTE.F 4238--4265 applies RHHX only in the dynamic-salt
            // branch. Its fixed-pH branch (4634 onward) uses the prescribed
            // H/OH state directly and must never enter either projection.
            .project_starting_water_equilibrium = if (self.dynamic_salts)
                projectWaterEquilibriumOpaque
            else
                null,
            .project_water_equilibrium = if (self.dynamic_salts)
                projectWaterEquilibriumOpaque
            else
                null,
        };
    }
};

fn projectWaterEquilibriumOpaque(
    raw: *const anyopaque,
    cell: chemistry.Cell,
) !@import("litter_chemistry_fixtures.zig").WaterEquilibriumProjection {
    const context: *const Context = @ptrCast(@alignCast(raw));
    const p = context.parameters;
    const water = try water_equilibrium.solve(.{
        .hydrogen_concentration_mol_per_m3 = cell.hydrogen_mol_per_m3,
        .hydroxide_concentration_mol_per_m3 = cell.hydroxide_mol_per_m3,
        .monovalent_activity_coefficient = p.activity.monovalent_activity_coefficient,
        .water_activity_product_mol2_per_m6 = p.water_activity_product_mol2_per_m6,
        .negligible_concentration_mol_per_m3 = p.negligible_water_ion_concentration_mol_per_m3,
    });
    var accepted = cell;
    accepted.hydrogen_mol_per_m3 = water.hydrogen_concentration_mol_per_m3;
    accepted.hydroxide_mol_per_m3 = water.hydroxide_concentration_mol_per_m3;
    accepted.water_mol_per_m3 += water.equal_reaction_extent_mol_per_m3;
    return .{
        .cell = accepted,
        .equal_reaction_extent_mol_per_m3 = water.equal_reaction_extent_mol_per_m3,
    };
}

pub fn evaluateOpaque(raw: *const anyopaque, cell: chemistry.Cell) !ledger.ReactionExtents {
    const context: *const Context = @ptrCast(@alignCast(raw));
    return calculate(cell, context.*);
}

fn phosphateMineralEquilibriumResidualsOpaque(
    raw: *const anyopaque,
    cell: chemistry.Cell,
) !ledger.PhosphateMineralExtents {
    const context: *const Context = @ptrCast(@alignCast(raw));
    try validate(cell, context.*);
    const p = context.parameters;
    const g1 = p.activity.monovalent_activity_coefficient;
    const g2 = p.activity.divalent_activity_coefficient;
    const water = try water_equilibrium.solve(.{
        .hydrogen_concentration_mol_per_m3 = cell.hydrogen_mol_per_m3,
        .hydroxide_concentration_mol_per_m3 = cell.hydroxide_mol_per_m3,
        .monovalent_activity_coefficient = g1,
        .water_activity_product_mol2_per_m6 = p.water_activity_product_mol2_per_m6,
        .negligible_concentration_mol_per_m3 = p.negligible_water_ion_concentration_mol_per_m3,
    });
    const hydrogen_activity =
        water.hydrogen_concentration_mol_per_m3 * g1;
    const hydroxide_activity =
        water.hydroxide_concentration_mol_per_m3 * g1;
    const aluminum_activity =
        cell.aluminum_mol_per_m3 *
        p.activity.trivalent_activity_coefficient;
    const iron_activity =
        cell.iron_mol_per_m3 *
        p.activity.trivalent_activity_coefficient;
    const calcium_activity = cell.calcium_mol_per_m3 * g2;
    if (aluminum_activity <= 0 or iron_activity <= 0 or
        calcium_activity <= 0 or hydrogen_activity <= 0 or
        hydroxide_activity <= 0)
        return error.InvalidLitterMineralActivity;
    const aluminum_target = if (context.dynamic_salts)
        try phosphate_precipitation.aluminumOrIronPhosphateEquilibriumH2po4(
            p.minerals.aluminum_phosphate,
            hydrogen_activity,
            p.dissociation.h2po4,
            p.dissociation.hpo4,
            aluminum_activity,
        )
    else
        p.minerals.fixed_ph_aluminum_h2po4 *
            hydrogen_activity * hydrogen_activity /
            (p.minerals.gibbsite /
                std.math.pow(f64, hydroxide_activity, 3));
    const iron_target = if (context.dynamic_salts)
        try phosphate_precipitation.aluminumOrIronPhosphateEquilibriumH2po4(
            p.minerals.iron_phosphate,
            hydrogen_activity,
            p.dissociation.h2po4,
            p.dissociation.hpo4,
            iron_activity,
        )
    else
        p.minerals.fixed_ph_iron_h2po4 *
            hydrogen_activity * hydrogen_activity /
            (p.minerals.iron_hydroxide /
                std.math.pow(f64, hydroxide_activity, 3));
    const dicalcium_target =
        try phosphate_precipitation.dicalciumPhosphateEquilibriumHpo4(
            p.minerals.dicalcium_phosphate,
            calcium_activity,
        );
    const apatite_target = if (context.dynamic_salts)
        try phosphate_precipitation.hydroxyapatiteEquilibriumH2po4(
            p.minerals.hydroxyapatite,
            hydrogen_activity,
            hydroxide_activity,
            calcium_activity,
            p.dissociation.h2po4,
            p.dissociation.hpo4,
        )
    else
        std.math.cbrt(
            p.minerals.fixed_ph_hydroxyapatite_h2po4 *
                std.math.pow(f64, hydrogen_activity, 7) /
                std.math.pow(f64, calcium_activity, 5),
        );
    const monocalcium_target =
        try phosphate_precipitation.monocalciumPhosphateEquilibriumH2po4(
            p.minerals.monocalcium_phosphate,
            calcium_activity,
        );
    return .{
        .aluminum_phosphate_mol_per_m3 = complementarityResidual(
            cell.phosphate_minerals.aluminum_phosphate_mol_per_m3,
            cell.h2po4_mol_p_per_m3 * g1 - aluminum_target,
        ),
        .iron_phosphate_mol_per_m3 = complementarityResidual(
            cell.phosphate_minerals.iron_phosphate_mol_per_m3,
            cell.h2po4_mol_p_per_m3 * g1 - iron_target,
        ),
        .dicalcium_phosphate_mol_per_m3 = complementarityResidual(
            cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3,
            cell.hpo4_mol_p_per_m3 * g2 - dicalcium_target,
        ),
        .hydroxyapatite_mol_per_m3 = complementarityResidual(
            cell.phosphate_minerals.hydroxyapatite_mol_per_m3,
            cell.h2po4_mol_p_per_m3 * g1 - apatite_target,
        ),
        .monocalcium_phosphate_mol_per_m3 = complementarityResidual(
            cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3,
            cell.h2po4_mol_p_per_m3 * g1 - monocalcium_target,
        ),
    };
}

fn complementarityResidual(solid_mol_per_m3: f64, saturation_residual: f64) f64 {
    return if (solid_mol_per_m3 <= 0)
        @max(0, saturation_residual)
    else
        saturation_residual;
}

const exchange_coordinate_names = [_][]const u8{
    "ammonium_mol_per_megagram",
    "aluminum_mol_per_megagram",
    "iron_mol_per_megagram",
    "calcium_mol_per_megagram",
    "magnesium_mol_per_megagram",
    "sodium_mol_per_megagram",
    "potassium_mol_per_megagram",
};
const exchange_coordinate_count = exchange_coordinate_names.len;

fn equilibrateCationExchangeOpaque(raw: *const anyopaque, cell: chemistry.Cell) !chemistry.Cell {
    const context: *const Context = @ptrCast(@alignCast(raw));
    const density = context.litter_mass_per_water_volume_megagrams_per_m3;
    const p = context.parameters;
    if (p.cation_exchange_capacity_mol_charge_per_megagram == 0) return cell;
    const options = context.solver_options;
    const totals = ledger.ExchangeAdsorption{
        .ammonium_mol_per_megagram = (cell.ammonium_mol_per_m3 +
            cell.ammonia_mol_per_m3) / density +
            cell.exchange.ammonium_mol_per_megagram,
        .hydrogen_mol_per_megagram = 0,
        .aluminum_mol_per_megagram = cell.aluminum_mol_per_m3 / density +
            cell.exchange.aluminum_mol_per_megagram,
        .iron_mol_per_megagram = cell.iron_mol_per_m3 / density +
            cell.exchange.iron_mol_per_megagram,
        .calcium_mol_per_megagram = cell.calcium_mol_per_m3 / density +
            cell.exchange.calcium_mol_per_megagram,
        .magnesium_mol_per_megagram = cell.magnesium_mol_per_m3 / density +
            cell.exchange.magnesium_mol_per_megagram,
        .sodium_mol_per_megagram = cell.sodium_mol_per_m3 / density +
            cell.exchange.sodium_mol_per_megagram,
        .potassium_mol_per_megagram = cell.potassium_mol_per_m3 / density +
            cell.exchange.potassium_mol_per_megagram,
    };
    var result = cell;
    var best_norm = std.math.inf(f64);
    var explosive_updates: u8 = 0;
    var previous_norm = std.math.inf(f64);
    var insufficient_progress_updates: u8 = 0;
    var newton_retry_required = false;
    var update: u16 = 0;
    while (update < options.max_iterations) : (update += 1) {
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        chemistry.recordProbe(options);
        const before = result.exchange;
        var residual: [exchange_coordinate_count]f64 = undefined;
        var scales: [exchange_coordinate_count]f64 = undefined;
        var target_exchange: ledger.ExchangeAdsorption = undefined;
        const current_norm = try exchangeScaledResidual(result, totals, density, p, options, &residual, &scales, &target_exchange);
        if (!retrying_newton_after_anderson and current_norm <= 1) return result;
        if (current_norm > 1e3 * @max(1.0, best_norm)) {
            explosive_updates += 1;
            if (explosive_updates >= @min(@as(u8, 4), @as(u8, @intCast(@min(options.max_iterations, std.math.maxInt(u8))))))
                return error.LitterExchangeSolverDiverged;
        } else {
            explosive_updates = 0;
        }
        best_norm = @min(best_norm, current_norm);
        const progress_floor = std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, previous_norm);
        if (std.math.isFinite(previous_norm) and previous_norm - current_norm <= progress_floor)
            insufficient_progress_updates +|= 1
        else
            insufficient_progress_updates = 0;
        previous_norm = current_norm;
        const progress_requires_anderson = insufficient_progress_updates >= 4;

        // Primary: finite-difference Newton on the seven conserved exchange
        // coordinates, with a scaled residual and backtracking line search.
        // Hydrogen is deliberately excluded: this accelerator holds the
        // aqueous H coordinate fixed while the outer coupled chemistry solve
        // owns its exchange reaction and water-equilibrium response.
        var jacobian: [exchange_coordinate_count * exchange_coordinate_count]f64 = undefined;
        var variable_scales: [exchange_coordinate_count]f64 = undefined;
        var usable_jacobian = true;
        inline for (exchange_coordinate_names, 0..) |name, column| {
            const coordinate = @field(before, name);
            const total = @field(totals, name);
            variable_scales[column] = @max(options.absolute_tolerance_mol_per_megagram, @abs(coordinate), @abs(total), @abs(@field(target_exchange, name)));
            var step = std.math.cbrt(std.math.floatEps(f64)) * variable_scales[column];
            if (step <= 0 or !std.math.isFinite(step)) {
                usable_jacobian = false;
                break;
            }
            if (coordinate + step > total) step = -step;
            if (coordinate + step < 0) {
                usable_jacobian = false;
                break;
            }
            var probe_exchange = before;
            @field(probe_exchange, name) += step;
            const probe_cell = reconstructExchangeCell(result, probe_exchange, totals, density, p.dissociation.ammonium) catch {
                usable_jacobian = false;
                break;
            };
            var probe_residual: [exchange_coordinate_count]f64 = undefined;
            _ = exchangeScaledResidualWithScales(probe_cell, density, p, scales, &probe_residual) catch {
                usable_jacobian = false;
                break;
            };
            inline for (0..exchange_coordinate_count) |row|
                jacobian[row * exchange_coordinate_count + column] =
                    (probe_residual[row] - residual[row]) /
                    (step / variable_scales[column]);
        }

        var accepted_newton = false;
        if (usable_jacobian and (!progress_requires_anderson or retrying_newton_after_anderson)) {
            var right_hand_side: [exchange_coordinate_count]f64 = undefined;
            var direction: [exchange_coordinate_count]f64 = undefined;
            var normal_matrix: [exchange_coordinate_count * exchange_coordinate_count]f64 = undefined;
            var normal_right_hand_side: [exchange_coordinate_count]f64 = undefined;
            inline for (0..exchange_coordinate_count) |coordinate|
                right_hand_side[coordinate] = -residual[coordinate];
            if (chemistry_numerics.solveDampedLeastSquares(&jacobian, &right_hand_side, &direction, &normal_matrix, &normal_right_hand_side, exchange_coordinate_count, options)) {
                var exchange_direction = std.mem.zeroes(ledger.ExchangeAdsorption);
                inline for (exchange_coordinate_names, 0..) |name, coordinate|
                    @field(exchange_direction, name) = direction[coordinate] * variable_scales[coordinate];
                const maximum_fraction = admissibleExchangeDirectionFraction(before, exchange_direction, totals);
                if (std.math.isFinite(maximum_fraction) and maximum_fraction > 0 and exchangeScaledStepNorm(exchange_direction, scales) > 8 * std.math.floatEps(f64)) {
                    var fraction = @min(1.0, maximum_fraction);
                    var line_search: u8 = 0;
                    const line_search_ceiling: u8 = @max(1, @min(12, @as(u8, @intCast(@min(options.max_iterations, std.math.maxInt(u8))))));
                    while (line_search < line_search_ceiling) : (line_search += 1) {
                        if (exchangeCandidate(result, before, exchange_direction, fraction, totals, density, p.dissociation.ammonium)) |candidate| {
                            var candidate_residual: [exchange_coordinate_count]f64 = undefined;
                            const candidate_norm = exchangeScaledResidualWithScales(candidate, density, p, scales, &candidate_residual) catch std.math.inf(f64);
                            if (candidate_norm <= current_norm * (1 - 1e-4 * fraction)) {
                                result = candidate;
                                accepted_newton = true;
                                break;
                            }
                        } else |_| {}
                        fraction *= 0.5;
                    }
                }
            }
        }
        if (accepted_newton) continue;
        if (retrying_newton_after_anderson) continue;
        if (!options.anderson_recovery) return error.LitterExchangeSolverStagnated;
        if (update + 1 >= options.max_iterations)
            return error.LitterExchangeSolverDidNotConverge;

        // Sole fallback: a relaxed Picard point seeds depth-one Anderson,
        // but is never published. The accepted accelerated direction is
        // damped, then Newton is restarted on the next update.
        var seed_fraction = options.picard_relaxation;
        inline for (exchange_coordinate_names) |name|
            seed_fraction = admissibleExchangeFraction(seed_fraction, @field(before, name), @field(target_exchange, name), @field(totals, name));
        if (!std.math.isFinite(seed_fraction) or seed_fraction <= 0)
            return error.LitterExchangeSolverStagnated;
        var seed_exchange = before;
        inline for (exchange_coordinate_names) |name|
            @field(seed_exchange, name) += seed_fraction * (@field(target_exchange, name) - @field(before, name));
        const seed_cell = try reconstructExchangeCell(result, seed_exchange, totals, density, p.dissociation.ammonium);
        var seed_residual: [exchange_coordinate_count]f64 = undefined;
        _ = try exchangeScaledResidualWithScales(seed_cell, density, p, scales, &seed_residual);
        var current_values: [exchange_coordinate_count]f64 = undefined;
        var seed_values: [exchange_coordinate_count]f64 = undefined;
        var accelerated_values: [exchange_coordinate_count]f64 = undefined;
        inline for (exchange_coordinate_names, 0..) |name, coordinate| {
            current_values[coordinate] = @field(before, name);
            seed_values[coordinate] = @field(seed_exchange, name);
        }
        if (!core_numerics.andersonDepthOneCandidate(
            &current_values,
            &residual,
            &seed_values,
            &seed_residual,
            &accelerated_values,
        ))
            return error.LitterExchangeSolverStagnated;
        var anderson_direction = std.mem.zeroes(ledger.ExchangeAdsorption);
        inline for (exchange_coordinate_names, 0..) |name, coordinate|
            @field(anderson_direction, name) =
                accelerated_values[coordinate] - @field(before, name);
        const maximum_fraction = admissibleExchangeDirectionFraction(before, anderson_direction, totals);
        if (!std.math.isFinite(maximum_fraction) or maximum_fraction <= 0 or exchangeScaledStepNorm(anderson_direction, scales) <= 8 * std.math.floatEps(f64))
            return error.LitterExchangeSolverStagnated;
        var fraction = @min(1.0, maximum_fraction);
        var accepted_anderson = false;
        var line_search: u8 = 0;
        const line_search_ceiling: u8 = @max(1, @min(12, @as(u8, @intCast(@min(options.max_iterations, std.math.maxInt(u8))))));
        while (line_search < line_search_ceiling) : (line_search += 1) {
            if (exchangeCandidate(result, before, anderson_direction, fraction, totals, density, p.dissociation.ammonium)) |candidate| {
                var candidate_residual: [exchange_coordinate_count]f64 = undefined;
                const candidate_norm = exchangeScaledResidualWithScales(candidate, density, p, scales, &candidate_residual) catch std.math.inf(f64);
                if (core_numerics.andersonImprovesAcceptedMerit(candidate_norm, current_norm) and
                    candidate_norm <= current_norm * (1 - 1e-4 * fraction))
                {
                    result = candidate;
                    accepted_anderson = true;
                    break;
                }
            } else |_| {}
            fraction *= 0.5;
        }
        if (!accepted_anderson)
            return error.LitterExchangeSolverStagnated;
        newton_retry_required = true;
    }
    var residual: [exchange_coordinate_count]f64 = undefined;
    var scales: [exchange_coordinate_count]f64 = undefined;
    var target: ledger.ExchangeAdsorption = undefined;
    const final_norm = try exchangeScaledResidual(result, totals, density, p, options, &residual, &scales, &target);
    if (!newton_retry_required and final_norm <= 1)
        return result;
    return error.LitterExchangeSolverDidNotConverge;
}

/// This cell's own cation-exchange equilibrium target at its current aqueous
/// and exchange state -- the fixed-point map `equilibrateCationExchangeOpaque`
/// relaxes toward, and the map used to score both the plain and the
/// Anderson-accelerated candidate's self-consistency.
fn exchangeEquilibriumTarget(cell: chemistry.Cell, density: f64, p: Parameters) !cation_exchange.Cations {
    const concentrations = cation_exchange.Cations{
        .ammonium_non_band = cell.ammonium_mol_per_m3,
        .ammonium_band = 0,
        .hydrogen = cell.hydrogen_mol_per_m3,
        .aluminum = cell.aluminum_mol_per_m3,
        .iron = cell.iron_mol_per_m3,
        .calcium = cell.calcium_mol_per_m3,
        .magnesium = cell.magnesium_mol_per_m3,
        .sodium = cell.sodium_mol_per_m3,
        .potassium = cell.potassium_mol_per_m3,
    };
    var activities = concentrations;
    activities.ammonium_non_band *= p.activity.monovalent_activity_coefficient;
    activities.hydrogen *= p.activity.monovalent_activity_coefficient;
    activities.aluminum *= p.activity.trivalent_activity_coefficient;
    activities.iron *= p.activity.trivalent_activity_coefficient;
    activities.calcium *= p.activity.divalent_activity_coefficient;
    activities.magnesium *= p.activity.divalent_activity_coefficient;
    activities.sodium *= p.activity.monovalent_activity_coefficient;
    activities.potassium *= p.activity.monovalent_activity_coefficient;
    const current_exchange = cation_exchange.Cations{
        .ammonium_non_band = cell.exchange.ammonium_mol_per_megagram,
        .ammonium_band = 0,
        .hydrogen = cell.exchange.hydrogen_mol_per_megagram,
        .aluminum = cell.exchange.aluminum_mol_per_megagram,
        .iron = cell.exchange.iron_mol_per_megagram,
        .calcium = cell.exchange.calcium_mol_per_megagram,
        .magnesium = cell.exchange.magnesium_mol_per_megagram,
        .sodium = cell.exchange.sodium_mol_per_megagram,
        .potassium = cell.exchange.potassium_mol_per_megagram,
    };
    return try cation_exchange.equilibriumIonConcentration(.{
        .cation_exchange_capacity_mol_charge_per_megagram = p.cation_exchange_capacity_mol_charge_per_megagram,
        .aqueous_concentration_mol_per_m3 = concentrations,
        .aqueous_activity_mol_per_m3 = activities,
        .exchange_concentration_mol_per_megagram = current_exchange,
        .ammonium_non_band_fraction = 1,
        .ammonium_band_fraction = 0,
        .soil_mass_per_water_volume_megagrams_per_m3 = density,
    }, p.cation_selectivity);
}

fn activeExchangeTarget(cell: chemistry.Cell, density: f64, p: Parameters) !ledger.ExchangeAdsorption {
    const target = try exchangeEquilibriumTarget(cell, density, p);
    const result = ledger.ExchangeAdsorption{
        .ammonium_mol_per_megagram = target.ammonium_non_band,
        // The inner accelerator freezes H; the outer coupled chemistry
        // ledger owns its aqueous/exchange transfer and water response.
        .hydrogen_mol_per_megagram = cell.exchange.hydrogen_mol_per_megagram,
        .aluminum_mol_per_megagram = target.aluminum,
        .iron_mol_per_megagram = target.iron,
        .calcium_mol_per_megagram = target.calcium,
        .magnesium_mol_per_megagram = target.magnesium,
        .sodium_mol_per_megagram = target.sodium,
        .potassium_mol_per_megagram = target.potassium,
    };
    inline for (@typeInfo(ledger.ExchangeAdsorption).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0)
            return error.InvalidLitterExchangeTarget;
    return result;
}

fn exchangeScaledResidual(
    cell: chemistry.Cell,
    totals: ledger.ExchangeAdsorption,
    density: f64,
    p: Parameters,
    options: chemistry.Options,
    residual: *[exchange_coordinate_count]f64,
    scales: *[exchange_coordinate_count]f64,
    target: *ledger.ExchangeAdsorption,
) !f64 {
    target.* = try activeExchangeTarget(cell, density, p);
    inline for (exchange_coordinate_names, 0..) |name, coordinate| {
        const characteristic = @max(
            @abs(@field(cell.exchange, name)),
            @abs(@field(target.*, name)),
            @abs(@field(totals, name)),
        );
        scales[coordinate] = @max(
            options.absolute_tolerance_mol_per_megagram,
            64 * std.math.floatEps(f64) * characteristic,
        ) + options.relative_tolerance * characteristic;
        if (!std.math.isFinite(scales[coordinate]) or scales[coordinate] <= 0)
            return error.InvalidLitterExchangeTolerance;
        residual[coordinate] =
            (@field(target.*, name) - @field(cell.exchange, name)) /
            scales[coordinate];
        if (!std.math.isFinite(residual[coordinate]))
            return error.NonFiniteLitterExchangeResidual;
    }
    return maximumArrayMagnitude(residual);
}

fn exchangeScaledResidualWithScales(
    cell: chemistry.Cell,
    density: f64,
    p: Parameters,
    scales: [exchange_coordinate_count]f64,
    residual: *[exchange_coordinate_count]f64,
) !f64 {
    const target = try activeExchangeTarget(cell, density, p);
    inline for (exchange_coordinate_names, 0..) |name, coordinate| {
        residual[coordinate] =
            (@field(target, name) - @field(cell.exchange, name)) /
            scales[coordinate];
        if (!std.math.isFinite(residual[coordinate]))
            return error.NonFiniteLitterExchangeResidual;
    }
    return maximumArrayMagnitude(residual);
}

fn maximumArrayMagnitude(values: *const [exchange_coordinate_count]f64) f64 {
    var maximum: f64 = 0;
    for (values) |value| maximum = @max(maximum, @abs(value));
    return maximum;
}

fn exchangeScaledStepNorm(direction: ledger.ExchangeAdsorption, scales: [exchange_coordinate_count]f64) f64 {
    var maximum: f64 = 0;
    inline for (exchange_coordinate_names, 0..) |name, coordinate|
        maximum = @max(maximum, @abs(@field(direction, name)) / scales[coordinate]);
    return maximum;
}

fn admissibleExchangeDirectionFraction(current: ledger.ExchangeAdsorption, direction: ledger.ExchangeAdsorption, totals: ledger.ExchangeAdsorption) f64 {
    var fraction = std.math.inf(f64);
    inline for (exchange_coordinate_names) |name| {
        const value = @field(current, name);
        const change = @field(direction, name);
        const total = @field(totals, name);
        if (!std.math.isFinite(value) or !std.math.isFinite(change) or !std.math.isFinite(total) or value < 0 or total < value)
            return 0;
        if (change > 0)
            fraction = @min(fraction, (total - value) / change)
        else if (change < 0)
            fraction = @min(fraction, value / -change);
    }
    return fraction;
}

fn exchangeCandidate(
    base: chemistry.Cell,
    current: ledger.ExchangeAdsorption,
    direction: ledger.ExchangeAdsorption,
    fraction: f64,
    totals: ledger.ExchangeAdsorption,
    density: f64,
    ammonium_dissociation: f64,
) !chemistry.Cell {
    var exchange = current;
    inline for (exchange_coordinate_names) |name| {
        const value = @field(current, name) + fraction * @field(direction, name);
        if (!std.math.isFinite(value) or value < 0 or value > @field(totals, name))
            return error.InvalidLitterExchangeCandidate;
        @field(exchange, name) = value;
    }
    return reconstructExchangeCell(base, exchange, totals, density, ammonium_dissociation);
}

/// Rebuilds the aqueous side of `base` from a candidate exchange state,
/// holding hydrogen (and therefore the ammonia/ammonium split ratio) fixed --
/// exchange never touches the fixed hydrogen domain in this evaluator.
fn reconstructExchangeCell(base: chemistry.Cell, exchange: ledger.ExchangeAdsorption, totals: ledger.ExchangeAdsorption, density: f64, ammonium_dissociation: f64) !chemistry.Cell {
    var result = base;
    result.exchange = exchange;
    const aqueous_n_per_megagram = totals.ammonium_mol_per_megagram - exchange.ammonium_mol_per_megagram;
    const ammonia_to_ammonium = ammonium_dissociation / result.hydrogen_mol_per_m3;
    result.ammonium_mol_per_m3 = density * aqueous_n_per_megagram / (1 + ammonia_to_ammonium);
    result.ammonia_mol_per_m3 = density * aqueous_n_per_megagram - result.ammonium_mol_per_m3;
    result.aluminum_mol_per_m3 = density * (totals.aluminum_mol_per_megagram - exchange.aluminum_mol_per_megagram);
    result.iron_mol_per_m3 = density * (totals.iron_mol_per_megagram - exchange.iron_mol_per_megagram);
    result.calcium_mol_per_m3 = density * (totals.calcium_mol_per_megagram - exchange.calcium_mol_per_megagram);
    result.magnesium_mol_per_m3 = density * (totals.magnesium_mol_per_megagram - exchange.magnesium_mol_per_megagram);
    result.sodium_mol_per_m3 = density * (totals.sodium_mol_per_megagram - exchange.sodium_mol_per_megagram);
    result.potassium_mol_per_m3 = density * (totals.potassium_mol_per_megagram - exchange.potassium_mol_per_megagram);
    try validateExchangeReconstruction(&result);
    return result;
}

fn validateExchangeReconstruction(cell: *const chemistry.Cell) !void {
    inline for ([_][]const u8{
        "ammonium_mol_per_m3",
        "ammonia_mol_per_m3",
        "aluminum_mol_per_m3",
        "iron_mol_per_m3",
        "calcium_mol_per_m3",
        "magnesium_mol_per_m3",
        "sodium_mol_per_m3",
        "potassium_mol_per_m3",
    }) |field_name| {
        const value = @field(cell.*, field_name);
        if (!std.math.isFinite(value))
            return error.NonFiniteLitterExchangeReconstruction;
        // This coordinate is reconstructed from an exact conserved total.
        // Clipping even a roundoff-sized deficit would manufacture that ion;
        // reject the candidate and let damping/Anderson choose another one.
        if (value < 0)
            return error.NegativeLitterExchangeReconstruction;
    }
}

fn admissibleExchangeFraction(requested: f64, current: f64, target: f64, total: f64) f64 {
    if (target <= current) return requested;
    return @min(requested, @max(0, total - current) / (target - current));
}

/// Runs the litter formulation carried by `context`; density and salt mode are
/// sourced once so the evaluator and conservative ledger cannot disagree.
pub fn solveCell(state: *chemistry.State, cell_index: usize, context: *const Context, options: chemistry.Options) !chemistry.Result {
    var bounded_context = context.*;
    var nested_probe_counts: chemistry.ProbeCounts = .{};
    bounded_context.solver_options = options;
    bounded_context.solver_options.probe_counts = &nested_probe_counts;
    var result = try chemistry.solveCell(state, cell_index, .{
        .litter_mass_per_water_volume_megagrams_per_m3 = context.litter_mass_per_water_volume_megagrams_per_m3,
        .dynamic_salts = context.dynamic_salts,
    }, bounded_context.evaluator(), options);
    result.probe_iterations +|= nested_probe_counts.iterations;
    return result;
}

/// Applies one physical-hour surface-litter reaction ledger. This is the
/// production SOLUTE.F 3996--5250 path; it deliberately does not invoke the
/// optional nonlinear equilibrium solver used by other callers.
pub fn applyHourlyCell(state: *chemistry.State, cell_index: usize, context: *const Context, options: chemistry.Options) !chemistry.Result {
    return chemistry.applyHourlyCell(state, cell_index, .{
        .litter_mass_per_water_volume_megagrams_per_m3 = context.litter_mass_per_water_volume_megagrams_per_m3,
        .dynamic_salts = context.dynamic_salts,
    }, context.evaluator(), options);
}

/// Litter-only equilibrium rates from SOLUTE.F. The litter has one
/// aqueous/exchange domain, phosphate surface sites, and five coprecipitates.
pub fn calculate(cell: chemistry.Cell, context: Context) !ledger.ReactionExtents {
    try validate(cell, context);
    const p = context.parameters;
    const g1 = p.activity.monovalent_activity_coefficient;
    const g2 = p.activity.divalent_activity_coefficient;
    const limit = p.kinetics.general_substrate_limit_fraction;
    const maximum = p.kinetics.maximum_association_mol_per_m3_step;

    // The dynamic branch starts with SOLUTE.F's RHHX projection
    // (4238--4265). The fixed-pH branch starts at 4634 and consumes the
    // prescribed CHY1/COH1 directly; applying RHHX there changes its rates.
    const water = if (context.dynamic_salts)
        try water_equilibrium.solve(.{
            .hydrogen_concentration_mol_per_m3 = cell.hydrogen_mol_per_m3,
            .hydroxide_concentration_mol_per_m3 = cell.hydroxide_mol_per_m3,
            .monovalent_activity_coefficient = g1,
            .water_activity_product_mol2_per_m6 = p.water_activity_product_mol2_per_m6,
            .negligible_concentration_mol_per_m3 = p.negligible_water_ion_concentration_mol_per_m3,
        })
    else
        water_equilibrium.Result{
            .hydrogen_concentration_mol_per_m3 = cell.hydrogen_mol_per_m3,
            .hydroxide_concentration_mol_per_m3 = cell.hydroxide_mol_per_m3,
            .hydrogen_activity_mol_per_m3 = cell.hydrogen_mol_per_m3 * g1,
            .hydroxide_activity_mol_per_m3 = cell.hydroxide_mol_per_m3 * g1,
            .equal_reaction_extent_mol_per_m3 = 0,
            .ph = 0,
        };
    const hydrogen = water.hydrogen_concentration_mol_per_m3;
    const hydroxide = water.hydroxide_concentration_mol_per_m3;
    const hydrogen_activity = hydrogen * g1;
    const hydroxide_activity = hydroxide * g1;
    const recombination = cell.hydrogen_mol_per_m3 - hydrogen;
    if (@abs(recombination - (cell.hydroxide_mol_per_m3 - hydroxide)) > 1e-10 * @max(1.0, @abs(recombination))) return error.LitterWaterEquilibriumImbalance;

    var result = zeroExtents();
    result.water_ion_recombination_mol_per_m3 = recombination;
    result.external_hydrogen_mol_per_m3 = p.external_hydrogen_mol_per_m3;
    result.ammonium_association_mol_per_m3 = try association(cell.ammonia_mol_per_m3, hydrogen, cell.ammonium_mol_per_m3, cell.ammonia_mol_per_m3, hydrogen_activity, cell.ammonium_mol_per_m3 * g1, 1, p.dissociation.ammonium, p.kinetics.ammonium_substrate_limit_fraction, p.kinetics.maximum_ammonium_association_mol_per_m3_step);

    // Dynamic SOLUTE.F source order is intentionally asymmetric: RNH4 is
    // evaluated from CHY1/AHY1, then lines 4528--4529 update AHY1 for all
    // later carbonate, H2PO4, and phosphate-mineral equilibrium rates. CHY1
    // itself remains the substrate bound. Fixed pH does not perform this
    // intermediate activity update (4893--4929).
    const later_hydrogen_activity = if (context.dynamic_salts)
        try finiteIntermediate(
            (hydrogen - result.ammonium_association_mol_per_m3) * g1,
        )
    else
        hydrogen_activity;
    if (later_hydrogen_activity < 0)
        return error.InvalidLitterHydrogenActivity;

    if (context.dynamic_salts) {
        result.carbonate_hydrogen_association_mol_per_m3 = try association(cell.carbonate_mol_per_m3, hydrogen, cell.bicarbonate_mol_per_m3, cell.carbonate_mol_per_m3 * g2, later_hydrogen_activity, cell.bicarbonate_mol_per_m3 * g1, g2, p.dissociation.bicarbonate, limit, maximum);
        result.bicarbonate_hydrogen_association_mol_per_m3 = try association(cell.bicarbonate_mol_per_m3, hydrogen, cell.carbon_dioxide_mol_per_m3, cell.bicarbonate_mol_per_m3 * g1, later_hydrogen_activity, cell.carbon_dioxide_mol_per_m3, g1, p.dissociation.carbon_dioxide, limit, maximum);
    }
    result.h2po4_association_mol_p_per_m3 = try association(cell.hpo4_mol_p_per_m3, hydrogen, cell.h2po4_mol_p_per_m3, cell.hpo4_mol_p_per_m3 * g2, later_hydrogen_activity, cell.h2po4_mol_p_per_m3 * g1, g2, p.dissociation.h2po4, limit, maximum);

    result.exchange = try exchangeRates(cell, hydrogen, context);
    const surface_site_total = cell.phosphate_surface.deprotonated_site_mol_per_megagram + cell.phosphate_surface.hydroxyl_site_mol_per_megagram + cell.phosphate_surface.protonated_site_mol_per_megagram + cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram + cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram;
    if (surface_site_total > 0) result.phosphate_surface = try phosphate_exchange.calculate(.{
        .hydrogen_concentration_mol_per_m3 = hydrogen,
        .hydrogen_activity_mol_per_m3 = hydrogen_activity,
        .hydroxide_activity_mol_per_m3 = hydroxide_activity,
        .h2po4_concentration_mol_p_per_m3 = cell.h2po4_mol_p_per_m3,
        .h2po4_activity_mol_p_per_m3 = cell.h2po4_mol_p_per_m3 * g1,
        .hpo4_concentration_mol_p_per_m3 = cell.hpo4_mol_p_per_m3,
        .hpo4_activity_mol_p_per_m3 = cell.hpo4_mol_p_per_m3 * g2,
        .deprotonated_site_mol_per_megagram = cell.phosphate_surface.deprotonated_site_mol_per_megagram,
        .hydroxyl_site_mol_per_megagram = cell.phosphate_surface.hydroxyl_site_mol_per_megagram,
        .protonated_site_mol_per_megagram = cell.phosphate_surface.protonated_site_mol_per_megagram,
        .adsorbed_h2po4_mol_p_per_megagram = cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram,
        .adsorbed_hpo4_mol_p_per_megagram = cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram,
        .monovalent_activity_coefficient = g1,
        .divalent_activity_coefficient = g2,
    }, p.phosphate_surface);
    result.carboxyl_hydrogen_adsorption_mol_per_megagram = if (context.dynamic_salts) try carboxylRate(cell, hydrogen_activity, context) else 0;
    result.phosphate_minerals = try phosphateMinerals(cell, later_hydrogen_activity, hydroxide_activity, context);

    if (context.dynamic_salts) {
        const without_salt = try ledger.assemble(result, context.litter_mass_per_water_volume_megagrams_per_m3, true);
        result.salt_minerals = try saltMinerals(cell, without_salt, hydroxide_activity, context);
    }
    return result;
}

fn exchangeRates(cell: chemistry.Cell, hydrogen: f64, context: Context) !ledger.ExchangeAdsorption {
    const p = context.parameters;
    const concentrations = cation_exchange.Cations{
        .ammonium_non_band = cell.ammonium_mol_per_m3,
        .ammonium_band = 0,
        .hydrogen = hydrogen,
        .aluminum = cell.aluminum_mol_per_m3,
        .iron = cell.iron_mol_per_m3,
        .calcium = cell.calcium_mol_per_m3,
        .magnesium = cell.magnesium_mol_per_m3,
        .sodium = cell.sodium_mol_per_m3,
        .potassium = cell.potassium_mol_per_m3,
    };
    var activities = concentrations;
    activities.ammonium_non_band *= p.activity.monovalent_activity_coefficient;
    activities.hydrogen *= p.activity.monovalent_activity_coefficient;
    activities.aluminum *= p.activity.trivalent_activity_coefficient;
    activities.iron *= p.activity.trivalent_activity_coefficient;
    activities.calcium *= p.activity.divalent_activity_coefficient;
    activities.magnesium *= p.activity.divalent_activity_coefficient;
    activities.sodium *= p.activity.monovalent_activity_coefficient;
    activities.potassium *= p.activity.monovalent_activity_coefficient;
    const exchange_state = cation_exchange.Cations{
        .ammonium_non_band = cell.exchange.ammonium_mol_per_megagram,
        .ammonium_band = 0,
        .hydrogen = cell.exchange.hydrogen_mol_per_megagram,
        .aluminum = cell.exchange.aluminum_mol_per_megagram,
        .iron = cell.exchange.iron_mol_per_megagram,
        .calcium = cell.exchange.calcium_mol_per_megagram,
        .magnesium = cell.exchange.magnesium_mol_per_megagram,
        .sodium = cell.exchange.sodium_mol_per_megagram,
        .potassium = cell.exchange.potassium_mol_per_megagram,
    };
    const rates = try cation_exchange.calculateSourceOrder(.{
        .cation_exchange_capacity_mol_charge_per_megagram = p.cation_exchange_capacity_mol_charge_per_megagram,
        .aqueous_concentration_mol_per_m3 = concentrations,
        .aqueous_activity_mol_per_m3 = activities,
        .exchange_concentration_mol_per_megagram = exchange_state,
        .ammonium_non_band_fraction = 1,
        .ammonium_band_fraction = 0,
        .soil_mass_per_water_volume_megagrams_per_m3 = context.litter_mass_per_water_volume_megagrams_per_m3,
    }, .{ .selectivity = p.cation_selectivity, .substrate_limit_fraction = p.kinetics.general_substrate_limit_fraction, .maximum_adsorption_mol_charge_per_m3_step = p.kinetics.maximum_cation_adsorption_mol_charge_per_m3_step }, .{
        .minimum_activity_mol_per_m3 = p.negligible_water_ion_concentration_mol_per_m3,
    });
    return .{ .ammonium_mol_per_megagram = rates.ammonium_non_band, .hydrogen_mol_per_megagram = rates.hydrogen, .aluminum_mol_per_megagram = rates.aluminum, .iron_mol_per_megagram = rates.iron, .calcium_mol_per_megagram = rates.calcium, .magnesium_mol_per_megagram = rates.magnesium, .sodium_mol_per_megagram = rates.sodium, .potassium_mol_per_megagram = rates.potassium };
}

fn carboxylRate(cell: chemistry.Cell, hydrogen_activity: f64, context: Context) !f64 {
    if (context.parameters.cation_exchange_capacity_mol_charge_per_megagram == 0) return 0;
    if (hydrogen_activity <= 0) return error.InvalidLitterHydrogenActivity;
    const occupied = cell.carboxyl_hydrogen_mol_per_megagram;
    const open = @max(0, context.parameters.cation_exchange_capacity_mol_charge_per_megagram - occupied);
    const equilibrium_open = @min(context.parameters.cation_exchange_capacity_mol_charge_per_megagram, context.parameters.dissociation.carboxyl * occupied / hydrogen_activity);
    const density = context.litter_mass_per_water_volume_megagrams_per_m3;
    const maximum_per_megagram = context.parameters.kinetics.maximum_cation_adsorption_mol_charge_per_m3_step / density;
    const substrate_limit = context.parameters.kinetics.general_substrate_limit_fraction / density * occupied;
    return @max(-maximum_per_megagram, -substrate_limit, @min(maximum_per_megagram, substrate_limit, open - equilibrium_open));
}

fn phosphateMinerals(cell: chemistry.Cell, hydrogen_activity: f64, hydroxide_activity: f64, context: Context) !ledger.PhosphateMineralExtents {
    const p = context.parameters;
    const g1 = p.activity.monovalent_activity_coefficient;
    const g2 = p.activity.divalent_activity_coefficient;
    // SOLUTE.F 648--680 floors every aqueous concentration at ZEROC before
    // forming activities: `CAL1=AMAX1(ZEROC,ZAL(L,NY,NX)/VOLW(L,NY,NX))`,
    // `CCA1=AMAX1(ZEROC,ZCA(...)/VOLW(...))`, with
    // `PARAMETER (ZEROC=1.0E-32)` at SOLUTE.F 131, and only then
    // `AAL1=CAL1*A3`, `ACA1=CCA1*A2` at 868/878. The `0.0` assignments at
    // 684--692 are the NO-WATER branch, which does not reach these equilibria.
    //
    // Without the floor, a litter cell with no calcium at all gives
    // `calcium_activity == 0` exactly, and the hydroxyapatite target divides
    // by `calcium_activity**5` (SOLUTE.F 4597). The guard below then rejected
    // the hour. That is what stopped the Ottawa deck at day 90: measured state
    // had `calcium_mol_per_m3 = 0` with `hydroxyapatite = 0.0167 mol m-3` and
    // 9.53e-3 m3 of water, i.e. water present and apatite present but no
    // dissolved calcium -- and Ca/Mg/Na/K/SO4/Cl were ALL exactly zero while
    // Al and Fe were seeded, so this is an unseeded species, not depletion.
    //
    // With the floor the target becomes very large but finite, and the
    // precipitation kinetics clamp it exactly as the source does: legacy's
    // `AMAX1(-AMAX1(0.0,PCAPH1),-TPA,AMIN1(TPA,XMINP,...))` is
    // `Kinetics.maximum_dissolution_mol_per_m3_step` plus the substrate limit
    // here. Infinite undersaturation therefore dissolves apatite at its rate
    // limit, which is the physically right answer and the one the oracle gives.
    //
    // This is the fifth instance of ZEROS-AREA-SCALING-UNTRANSLATED-001.
    const zero_concentration_mol_per_m3 = 1.0e-32;
    const aluminum_mol_per_m3 = @max(zero_concentration_mol_per_m3, cell.aluminum_mol_per_m3);
    const iron_mol_per_m3 = @max(zero_concentration_mol_per_m3, cell.iron_mol_per_m3);
    const calcium_mol_per_m3 = @max(zero_concentration_mol_per_m3, cell.calcium_mol_per_m3);
    const aluminum_activity = aluminum_mol_per_m3 * p.activity.trivalent_activity_coefficient;
    const iron_activity = iron_mol_per_m3 * p.activity.trivalent_activity_coefficient;
    const calcium_activity = calcium_mol_per_m3 * g2;
    // Retained deliberately. The floor removes the exact-zero case, so this now
    // only fires on a negative or non-finite activity, which remains a real
    // defect worth failing on. It also names which activity is at fault, which
    // it previously did not -- the day-90 diagnosis was only possible because a
    // separate caller happened to dump the whole cell state.
    if (aluminum_activity <= 0 or iron_activity <= 0 or calcium_activity <= 0 or hydrogen_activity <= 0 or hydroxide_activity <= 0) {
        std.log.err(
            "litter mineral activity non-positive: aluminum={e} iron={e} calcium={e} hydrogen={e} hydroxide={e}",
            .{ aluminum_activity, iron_activity, calcium_activity, hydrogen_activity, hydroxide_activity },
        );
        return error.InvalidLitterMineralActivity;
    }
    const dynamic = context.dynamic_salts;
    const aluminum_target = if (dynamic)
        try phosphate_precipitation.aluminumOrIronPhosphateEquilibriumH2po4(p.minerals.aluminum_phosphate, hydrogen_activity, p.dissociation.h2po4, p.dissociation.hpo4, aluminum_activity)
    else
        p.minerals.fixed_ph_aluminum_h2po4 * hydrogen_activity * hydrogen_activity / (p.minerals.gibbsite / std.math.pow(f64, hydroxide_activity, 3));
    const iron_target = if (dynamic)
        try phosphate_precipitation.aluminumOrIronPhosphateEquilibriumH2po4(p.minerals.iron_phosphate, hydrogen_activity, p.dissociation.h2po4, p.dissociation.hpo4, iron_activity)
    else
        p.minerals.fixed_ph_iron_h2po4 * hydrogen_activity * hydrogen_activity / (p.minerals.iron_hydroxide / std.math.pow(f64, hydroxide_activity, 3));
    const dicalcium_target = try phosphate_precipitation.dicalciumPhosphateEquilibriumHpo4(p.minerals.dicalcium_phosphate, calcium_activity);
    const apatite_target = if (dynamic)
        try phosphate_precipitation.hydroxyapatiteEquilibriumH2po4(p.minerals.hydroxyapatite, hydrogen_activity, hydroxide_activity, calcium_activity, p.dissociation.h2po4, p.dissociation.hpo4)
    else
        std.math.cbrt(p.minerals.fixed_ph_hydroxyapatite_h2po4 * std.math.pow(f64, hydrogen_activity, 7) / std.math.pow(f64, calcium_activity, 5));
    const monocalcium_target = try phosphate_precipitation.monocalciumPhosphateEquilibriumH2po4(p.minerals.monocalcium_phosphate, calcium_activity);
    const standard = phosphate_precipitation.Kinetics{ .substrate_limit_fraction = p.kinetics.general_substrate_limit_fraction, .maximum_precipitation_mol_per_m3_step = p.kinetics.maximum_phosphate_precipitation_mol_per_m3_step, .maximum_dissolution_mol_per_m3_step = p.kinetics.maximum_phosphate_precipitation_mol_per_m3_step, .phosphate_activity_coefficient = g1 };
    return .{
        .aluminum_phosphate_mol_per_m3 = try phosphateExtent(aluminum_mol_per_m3, cell.h2po4_mol_p_per_m3, cell.phosphate_minerals.aluminum_phosphate_mol_per_m3, cell.h2po4_mol_p_per_m3 * g1, aluminum_target, 1, 1, standard, dynamic),
        .iron_phosphate_mol_per_m3 = try phosphateExtent(iron_mol_per_m3, cell.h2po4_mol_p_per_m3, cell.phosphate_minerals.iron_phosphate_mol_per_m3, cell.h2po4_mol_p_per_m3 * g1, iron_target, 1, 1, standard, dynamic),
        .dicalcium_phosphate_mol_per_m3 = try phosphateExtent(calcium_mol_per_m3, cell.hpo4_mol_p_per_m3, cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3, cell.hpo4_mol_p_per_m3 * g2, dicalcium_target, 1, 1, .{ .substrate_limit_fraction = standard.substrate_limit_fraction, .maximum_precipitation_mol_per_m3_step = standard.maximum_precipitation_mol_per_m3_step, .maximum_dissolution_mol_per_m3_step = standard.maximum_dissolution_mol_per_m3_step, .phosphate_activity_coefficient = g2 }, dynamic),
        .hydroxyapatite_mol_per_m3 = try phosphateExtent(calcium_mol_per_m3, cell.h2po4_mol_p_per_m3, cell.phosphate_minerals.hydroxyapatite_mol_per_m3, cell.h2po4_mol_p_per_m3 * g1, apatite_target, 5, 3, .{ .substrate_limit_fraction = standard.substrate_limit_fraction, .maximum_precipitation_mol_per_m3_step = p.kinetics.maximum_apatite_precipitation_mol_per_m3_step, .maximum_dissolution_mol_per_m3_step = p.kinetics.maximum_apatite_precipitation_mol_per_m3_step, .phosphate_activity_coefficient = g1 }, dynamic),
        .monocalcium_phosphate_mol_per_m3 = try phosphateExtent(calcium_mol_per_m3, cell.h2po4_mol_p_per_m3, cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3, cell.h2po4_mol_p_per_m3 * g1, monocalcium_target, 1, 2, .{ .substrate_limit_fraction = standard.substrate_limit_fraction, .maximum_precipitation_mol_per_m3_step = standard.maximum_precipitation_mol_per_m3_step, .maximum_dissolution_mol_per_m3_step = p.kinetics.maximum_monocalcium_dissolution_mol_per_m3_step, .phosphate_activity_coefficient = g1 }, dynamic),
    };
}

fn phosphateExtent(cation: f64, phosphate: f64, solid: f64, activity: f64, target: f64, cation_count: f64, phosphorus_count: f64, kinetics: phosphate_precipitation.Kinetics, limit_by_cation: bool) !f64 {
    const state = phosphate_precipitation.State{ .dissolved_cation_mol_per_m3 = cation, .dissolved_phosphate_mol_p_per_m3 = phosphate, .precipitate_mol_per_m3 = solid };
    const stoichiometry = phosphate_precipitation.Stoichiometry{ .cation_mol_per_mol_precipitate = cation_count, .phosphorus_mol_per_mol_precipitate = phosphorus_count };
    return if (limit_by_cation)
        phosphate_precipitation.calculateExtent(state, activity, target, stoichiometry, kinetics)
    else
        phosphate_precipitation.calculateExtentWithPhosphateOnlyPrecipitationLimit(state, activity, target, stoichiometry, kinetics);
}

fn saltMinerals(cell: chemistry.Cell, base: chemistry.Cell, hydroxide_activity: f64, context: Context) !ledger.SaltMineralExtents {
    const p = context.parameters;
    const limit = p.kinetics.general_substrate_limit_fraction;
    const maximum = p.kinetics.maximum_phosphate_precipitation_mol_per_m3_step;
    const aluminum = try finiteIntermediate(cell.aluminum_mol_per_m3 + base.aluminum_mol_per_m3);
    const iron = try finiteIntermediate(cell.iron_mol_per_m3 + base.iron_mol_per_m3);
    const calcium = try finiteIntermediate(cell.calcium_mol_per_m3 + base.calcium_mol_per_m3);
    const carbonate = try finiteIntermediate(cell.carbonate_mol_per_m3 + base.carbonate_mol_per_m3);
    const sulfate = try finiteIntermediate(cell.sulfate_mol_per_m3 + base.sulfate_mol_per_m3);
    // SOLUTE.F 5021--5047 evaluates Al(OH)3 and Fe(OH)3 against AOH1,
    // the positive water-equilibrium OH activity. ROH is the simultaneous
    // ledger direction and is not folded into an OH substrate inventory.
    // The outer conservative solve limits that complete direction before
    // publication. Requiring `cell.OH + base.OH >= 0` here incorrectly turns
    // source-order residual evaluation into sequential state mutation and
    // aborts acidic dynamic-salt cells before damping can act.
    const gibbsite = try sourceOrderedBinaryMineral(aluminum, 0, cell.salt_minerals.gibbsite_mol_per_m3, aluminum * p.activity.trivalent_activity_coefficient, hydroxide_activity, 1, 3, false, p.minerals.gibbsite, p.activity.trivalent_activity_coefficient, limit, maximum, maximum);
    const iron_hydroxide = try sourceOrderedBinaryMineral(iron, 0, cell.salt_minerals.iron_hydroxide_mol_per_m3, iron * p.activity.trivalent_activity_coefficient, hydroxide_activity, 1, 3, false, p.minerals.iron_hydroxide, p.activity.trivalent_activity_coefficient, limit, maximum, maximum);
    const calcite_dissolution = try mineral_precipitation.calciteDissolutionLimit(maximum, hydroxide_activity, p.kinetics.calcite_hydroxide_inhibition_constant_mol_per_m3);
    const calcite = try sourceOrderedBinaryMineral(calcium, carbonate, cell.salt_minerals.calcite_mol_per_m3, calcium * p.activity.divalent_activity_coefficient, carbonate * p.activity.divalent_activity_coefficient, 1, 1, true, p.minerals.calcite, p.activity.divalent_activity_coefficient, limit, maximum, calcite_dissolution);
    // Unlike the bulk-soil kernel (`geochemistry_reaction_rates.zig`'s
    // SOLUTE-013 correction), the surface-litter Fortran source
    // (`solute.f:5049-5075`) never recomputes CCAX/ACA1 between the calcite
    // and gypsum blocks: gypsum is deliberately evaluated against the
    // pre-precipitation calcium pool, simultaneously with calcite, not
    // sequentially. Reuse the undepleted `calcium` here to match.
    const gypsum = try sourceOrderedBinaryMineral(calcium, sulfate, cell.salt_minerals.gypsum_mol_per_m3, calcium * p.activity.divalent_activity_coefficient, sulfate * p.activity.divalent_activity_coefficient, 1, 1, true, p.minerals.gypsum, p.activity.divalent_activity_coefficient, limit, maximum, maximum);
    return .{ .gibbsite_mol_per_m3 = gibbsite, .iron_hydroxide_mol_per_m3 = iron_hydroxide, .calcite_mol_per_m3 = calcite, .gypsum_mol_per_m3 = gypsum };
}

fn sourceOrderedBinaryMineral(first: f64, second: f64, solid: f64, first_activity: f64, second_activity: f64, first_count: f64, second_count: f64, limit_by_second: bool, product: f64, first_coefficient: f64, limit: f64, maximum_precipitation: f64, maximum_dissolution: f64) !f64 {
    inline for (.{ first, second, solid, first_activity, second_activity, first_count, second_count, product, first_coefficient, limit, maximum_precipitation, maximum_dissolution }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteIntermediateLitterChemistry;
    if (solid < 0 or first_count <= 0 or second_count <= 0 or product <= 0 or first_coefficient <= 0 or limit < 0 or limit > 1 or maximum_precipitation < 0 or maximum_dissolution < 0)
        return error.InvalidLitterMineralRate;
    if (second_activity == 0)
        return @max(-maximum_dissolution, -@max(0, solid));
    const equilibrium_first_activity = product /
        std.math.pow(f64, second_activity, second_count / first_count);
    if (!std.math.isFinite(equilibrium_first_activity))
        return error.NonFiniteLitterMineralRate;
    const available = if (limit_by_second)
        @min(first / first_count, second / second_count)
    else
        first / first_count;
    const driving_force = (first_activity - equilibrium_first_activity) /
        first_coefficient;
    const extent = @max(
        -maximum_dissolution,
        -@max(0, solid),
        @min(maximum_precipitation, limit * available, driving_force),
    );
    if (!std.math.isFinite(extent)) return error.NonFiniteLitterMineralRate;
    return extent;
}

fn association(free_first: f64, free_second: f64, paired: f64, first_activity: f64, second_activity: f64, paired_activity: f64, first_coefficient: f64, constant: f64, limit: f64, maximum: f64) !f64 {
    return ion_pairing.calculate(.{ .free_first_mol_per_m3 = free_first, .free_second_mol_per_m3 = free_second, .paired_mol_per_m3 = paired }, .{ .free_first_mol_per_m3 = first_activity, .free_second_mol_per_m3 = second_activity, .paired_mol_per_m3 = paired_activity, .free_first_activity_coefficient = first_coefficient }, .{ .dissociation_constant = constant, .substrate_limit_fraction = limit, .maximum_association_mol_per_m3_step = maximum });
}

fn finiteIntermediate(value: f64) !f64 {
    if (!std.math.isFinite(value)) return error.NonFiniteIntermediateLitterChemistry;
    return value;
}

fn validate(cell: chemistry.Cell, context: Context) !void {
    _ = cell;
    if (!std.math.isFinite(context.litter_mass_per_water_volume_megagrams_per_m3) or context.litter_mass_per_water_volume_megagrams_per_m3 <= 0) return error.InvalidLitterMassWaterRatio;
    inline for (@typeInfo(DissociationConstants).@"struct".fields) |field| if (!std.math.isFinite(@field(context.parameters.dissociation, field.name)) or @field(context.parameters.dissociation, field.name) <= 0) return error.InvalidLitterDissociationConstant;
    inline for (@typeInfo(MineralProducts).@"struct".fields) |field| if (!std.math.isFinite(@field(context.parameters.minerals, field.name)) or @field(context.parameters.minerals, field.name) <= 0) return error.InvalidLitterMineralProduct;
    inline for (@typeInfo(Kinetics).@"struct".fields) |field| if (!std.math.isFinite(@field(context.parameters.kinetics, field.name)) or @field(context.parameters.kinetics, field.name) < 0) return error.InvalidLitterKinetics;
    if (context.parameters.kinetics.ammonium_substrate_limit_fraction > 1 or context.parameters.kinetics.general_substrate_limit_fraction > 1 or context.parameters.kinetics.calcite_hydroxide_inhibition_constant_mol_per_m3 <= 0 or context.parameters.cation_exchange_capacity_mol_charge_per_megagram < 0) return error.InvalidLitterKinetics;
}

fn zeroExtents() ledger.ReactionExtents {
    var value: ledger.ReactionExtents = undefined;
    zeroStruct(ledger.ReactionExtents, &value);
    return value;
}

fn zeroStruct(comptime T: type, value: *T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => @field(value.*, field.name) = 0,
        .@"struct" => zeroStruct(field.type, &@field(value.*, field.name)),
        else => unreachable,
    };
}

fn unitParameters() Parameters {
    return .{
        .activity = .{ .ionic_strength_mol_per_l = 0, .monovalent_activity_coefficient = 1, .divalent_activity_coefficient = 1, .trivalent_activity_coefficient = 1, .total_ion_activity_mol_per_m3 = 0, .electrical_conductivity_dS_per_m = 0 },
        .dissociation = .{ .ammonium = 1, .carbon_dioxide = 1, .bicarbonate = 1, .h2po4 = 1, .hpo4 = 1, .carboxyl = 1 },
        .minerals = .{ .aluminum_phosphate = 1, .iron_phosphate = 1, .dicalcium_phosphate = 1, .hydroxyapatite = 1, .monocalcium_phosphate = 1, .gibbsite = 1, .iron_hydroxide = 1, .calcite = 1, .gypsum = 1, .fixed_ph_aluminum_h2po4 = 1, .fixed_ph_iron_h2po4 = 1, .fixed_ph_hydroxyapatite_h2po4 = 1 },
        .kinetics = .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0.2, .maximum_ammonium_association_mol_per_m3_step = 0.1, .maximum_association_mol_per_m3_step = 0.1, .maximum_phosphate_precipitation_mol_per_m3_step = 0.1, .maximum_apatite_precipitation_mol_per_m3_step = 0.1, .maximum_monocalcium_dissolution_mol_per_m3_step = 0.1, .maximum_cation_adsorption_mol_charge_per_m3_step = 0, .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1 },
        .cation_exchange_capacity_mol_charge_per_megagram = 0,
        .cation_selectivity = .{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 },
        .water_activity_product_mol2_per_m6 = 1,
        .negligible_water_ion_concentration_mol_per_m3 = 1e-32,
    };
}

test "litter rate evaluator supplies exact single-zone associations" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var cell = state.cells[0];
    cell.hydrogen_mol_per_m3 = 1;
    cell.hydroxide_mol_per_m3 = 1;
    cell.ammonia_mol_per_m3 = 2;
    cell.ammonium_mol_per_m3 = 0.5;
    cell.hpo4_mol_p_per_m3 = 2;
    cell.h2po4_mol_p_per_m3 = 0.5;
    cell.aluminum_mol_per_m3 = 1;
    cell.iron_mol_per_m3 = 1;
    cell.calcium_mol_per_m3 = 1;
    cell.magnesium_mol_per_m3 = 1;
    cell.sodium_mol_per_m3 = 1;
    cell.potassium_mol_per_m3 = 1;
    cell.carbonate_mol_per_m3 = 1;
    cell.bicarbonate_mol_per_m3 = 1;
    cell.carbon_dioxide_mol_per_m3 = 1;
    cell.sulfate_mol_per_m3 = 1;
    const extents = try calculate(cell, .{ .parameters = unitParameters(), .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = false });
    try std.testing.expect(extents.ammonium_association_mol_per_m3 > 0);
    try std.testing.expect(extents.h2po4_association_mol_p_per_m3 > 0);
    try std.testing.expectEqual(@as(f64, 0), extents.bicarbonate_hydrogen_association_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), extents.salt_minerals.calcite_mol_per_m3);
}

test "fixed-pH litter evaluator never applies dynamic water equilibrium" {
    var cell = std.mem.zeroes(chemistry.Cell);
    cell.hydrogen_mol_per_m3 = 4;
    cell.hydroxide_mol_per_m3 = 4;
    cell.ammonia_mol_per_m3 = 1;
    cell.ammonium_mol_per_m3 = 1;
    cell.hpo4_mol_p_per_m3 = 1;
    cell.h2po4_mol_p_per_m3 = 1;
    cell.aluminum_mol_per_m3 = 1;
    cell.iron_mol_per_m3 = 1;
    cell.calcium_mol_per_m3 = 1;
    cell.magnesium_mol_per_m3 = 1;
    cell.sodium_mol_per_m3 = 1;
    cell.potassium_mol_per_m3 = 1;

    const context = Context{
        .parameters = unitParameters(),
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = false,
    };
    const evaluator = context.evaluator();
    try std.testing.expect(evaluator.project_starting_water_equilibrium == null);
    try std.testing.expect(evaluator.project_water_equilibrium == null);

    const extents = try calculate(cell, context);
    try std.testing.expectEqual(
        @as(f64, 0),
        extents.water_ion_recombination_mol_per_m3,
    );
    const expected_phosphate = try phosphateMinerals(
        cell,
        cell.hydrogen_mol_per_m3,
        cell.hydroxide_mol_per_m3,
        context,
    );
    try std.testing.expectEqual(expected_phosphate, extents.phosphate_minerals);
}

test "dynamic litter propagates post-ammonium hydrogen activity in source order" {
    var cell = std.mem.zeroes(chemistry.Cell);
    cell.hydrogen_mol_per_m3 = 1;
    cell.hydroxide_mol_per_m3 = 1;
    cell.ammonia_mol_per_m3 = 2;
    cell.ammonium_mol_per_m3 = 0.5;
    cell.hpo4_mol_p_per_m3 = 0.55;
    cell.h2po4_mol_p_per_m3 = 0.5;
    cell.carbonate_mol_per_m3 = 0.55;
    cell.bicarbonate_mol_per_m3 = 0.5;
    cell.carbon_dioxide_mol_per_m3 = 0.25;
    cell.aluminum_mol_per_m3 = 1;
    cell.iron_mol_per_m3 = 1;
    cell.calcium_mol_per_m3 = 1;
    cell.magnesium_mol_per_m3 = 1;
    cell.sodium_mol_per_m3 = 1;
    cell.potassium_mol_per_m3 = 1;
    cell.sulfate_mol_per_m3 = 1;
    cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 = 1;
    cell.phosphate_minerals.iron_phosphate_mol_per_m3 = 1;
    cell.phosphate_minerals.hydroxyapatite_mol_per_m3 = 1;

    var parameters = unitParameters();
    parameters.kinetics.general_substrate_limit_fraction = 1;
    parameters.kinetics.maximum_association_mol_per_m3_step = 10;
    parameters.kinetics.maximum_phosphate_precipitation_mol_per_m3_step = 10;
    parameters.kinetics.maximum_apatite_precipitation_mol_per_m3_step = 10;
    parameters.kinetics.maximum_monocalcium_dissolution_mol_per_m3_step = 10;
    const context = Context{
        .parameters = parameters,
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = true,
    };
    const extents = try calculate(cell, context);
    try std.testing.expectEqual(@as(f64, 0.1), extents.ammonium_association_mol_per_m3);

    // SOLUTE.F 4528--4529 changes AHY1 but leaves CHY1 as the later
    // substrate bound. With unit activity coefficient, AHY1 becomes 0.9.
    const post_ammonium_hydrogen_activity = 0.9;
    const expected_carbonate = try association(
        cell.carbonate_mol_per_m3,
        cell.hydrogen_mol_per_m3,
        cell.bicarbonate_mol_per_m3,
        cell.carbonate_mol_per_m3,
        post_ammonium_hydrogen_activity,
        cell.bicarbonate_mol_per_m3,
        1,
        parameters.dissociation.bicarbonate,
        parameters.kinetics.general_substrate_limit_fraction,
        parameters.kinetics.maximum_association_mol_per_m3_step,
    );
    const expected_h2po4 = try association(
        cell.hpo4_mol_p_per_m3,
        cell.hydrogen_mol_per_m3,
        cell.h2po4_mol_p_per_m3,
        cell.hpo4_mol_p_per_m3,
        post_ammonium_hydrogen_activity,
        cell.h2po4_mol_p_per_m3,
        1,
        parameters.dissociation.h2po4,
        parameters.kinetics.general_substrate_limit_fraction,
        parameters.kinetics.maximum_association_mol_per_m3_step,
    );
    try std.testing.expectEqual(expected_carbonate, extents.carbonate_hydrogen_association_mol_per_m3);
    try std.testing.expectEqual(expected_h2po4, extents.h2po4_association_mol_p_per_m3);

    const expected_phosphate = try phosphateMinerals(
        cell,
        post_ammonium_hydrogen_activity,
        cell.hydroxide_mol_per_m3,
        context,
    );
    const stale_phosphate = try phosphateMinerals(
        cell,
        cell.hydrogen_mol_per_m3,
        cell.hydroxide_mol_per_m3,
        context,
    );
    try std.testing.expectEqual(expected_phosphate, extents.phosphate_minerals);
    try std.testing.expect(
        stale_phosphate.aluminum_phosphate_mol_per_m3 !=
            extents.phosphate_minerals.aluminum_phosphate_mol_per_m3,
    );
}

test "rate context binds directly to transactional litter solver" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].hydrogen_mol_per_m3 = 1;
    state.cells[0].hydroxide_mol_per_m3 = 1;
    state.cells[0].ammonia_mol_per_m3 = 1;
    state.cells[0].ammonium_mol_per_m3 = 1;
    state.cells[0].hpo4_mol_p_per_m3 = 1;
    state.cells[0].h2po4_mol_p_per_m3 = 1;
    state.cells[0].aluminum_mol_per_m3 = 1;
    state.cells[0].iron_mol_per_m3 = 1;
    state.cells[0].calcium_mol_per_m3 = 1;
    state.cells[0].magnesium_mol_per_m3 = 1;
    state.cells[0].sodium_mol_per_m3 = 1;
    state.cells[0].potassium_mol_per_m3 = 1;
    state.cells[0].carbonate_mol_per_m3 = 1;
    state.cells[0].bicarbonate_mol_per_m3 = 1;
    state.cells[0].carbon_dioxide_mol_per_m3 = 1;
    state.cells[0].sulfate_mol_per_m3 = 1;
    var parameters = unitParameters();
    parameters.kinetics.maximum_phosphate_precipitation_mol_per_m3_step = 0;
    parameters.kinetics.maximum_apatite_precipitation_mol_per_m3_step = 0;
    const context = Context{ .parameters = parameters, .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = false };
    const result = try solveCell(&state, 0, &context, .{});
    try std.testing.expect(result.iterations < 60);
}

test "nested litter cation exchange converges with scaled Newton and conserves every ion" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var cell = state.cells[0];
    cell.hydrogen_mol_per_m3 = 1;
    cell.ammonium_mol_per_m3 = 0.5;
    cell.ammonia_mol_per_m3 = 0.5;
    cell.aluminum_mol_per_m3 = 1;
    cell.iron_mol_per_m3 = 1;
    cell.calcium_mol_per_m3 = 1;
    cell.magnesium_mol_per_m3 = 1;
    cell.sodium_mol_per_m3 = 1;
    cell.potassium_mol_per_m3 = 1;

    var parameters = unitParameters();
    parameters.cation_exchange_capacity_mol_charge_per_megagram = 1;
    const options = chemistry.Options{
        .absolute_tolerance_mol_per_m3 = 1e-10,
        .absolute_tolerance_mol_per_megagram = 1e-10,
        .relative_tolerance = 1e-8,
        .picard_relaxation = 0.35,
        .max_iterations = 40,
        .anderson_recovery = true,
    };
    const context = Context{
        .parameters = parameters,
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = true,
        .solver_options = options,
    };
    const result = try equilibrateCationExchangeOpaque(&context, cell);

    try std.testing.expectApproxEqAbs(
        cell.ammonium_mol_per_m3 + cell.ammonia_mol_per_m3 +
            cell.exchange.ammonium_mol_per_megagram,
        result.ammonium_mol_per_m3 + result.ammonia_mol_per_m3 +
            result.exchange.ammonium_mol_per_megagram,
        2e-14,
    );
    inline for (.{
        .{ "aluminum_mol_per_m3", "aluminum_mol_per_megagram" },
        .{ "iron_mol_per_m3", "iron_mol_per_megagram" },
        .{ "calcium_mol_per_m3", "calcium_mol_per_megagram" },
        .{ "magnesium_mol_per_m3", "magnesium_mol_per_megagram" },
        .{ "sodium_mol_per_m3", "sodium_mol_per_megagram" },
        .{ "potassium_mol_per_m3", "potassium_mol_per_megagram" },
    }) |names| try std.testing.expectApproxEqAbs(
        @field(cell, names[0]) + @field(cell.exchange, names[1]),
        @field(result, names[0]) + @field(result.exchange, names[1]),
        2e-14,
    );
    try std.testing.expectEqual(cell.hydrogen_mol_per_m3, result.hydrogen_mol_per_m3);
    try std.testing.expectEqual(
        cell.exchange.hydrogen_mol_per_megagram,
        result.exchange.hydrogen_mol_per_megagram,
    );

    const totals = ledger.ExchangeAdsorption{
        .ammonium_mol_per_megagram = cell.ammonium_mol_per_m3 +
            cell.ammonia_mol_per_m3 + cell.exchange.ammonium_mol_per_megagram,
        .hydrogen_mol_per_megagram = 0,
        .aluminum_mol_per_megagram = cell.aluminum_mol_per_m3 +
            cell.exchange.aluminum_mol_per_megagram,
        .iron_mol_per_megagram = cell.iron_mol_per_m3 +
            cell.exchange.iron_mol_per_megagram,
        .calcium_mol_per_megagram = cell.calcium_mol_per_m3 +
            cell.exchange.calcium_mol_per_megagram,
        .magnesium_mol_per_megagram = cell.magnesium_mol_per_m3 +
            cell.exchange.magnesium_mol_per_megagram,
        .sodium_mol_per_megagram = cell.sodium_mol_per_m3 +
            cell.exchange.sodium_mol_per_megagram,
        .potassium_mol_per_megagram = cell.potassium_mol_per_m3 +
            cell.exchange.potassium_mol_per_megagram,
    };
    var residual: [exchange_coordinate_count]f64 = undefined;
    var scales: [exchange_coordinate_count]f64 = undefined;
    var target: ledger.ExchangeAdsorption = undefined;
    try std.testing.expect((try exchangeScaledResidual(
        result,
        totals,
        1,
        parameters,
        options,
        &residual,
        &scales,
        &target,
    )) <= 1);
}

test "nested litter cation exchange treats max iterations as a hard failure ceiling" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var cell = state.cells[0];
    cell.hydrogen_mol_per_m3 = 1;
    cell.ammonium_mol_per_m3 = 0.5;
    cell.ammonia_mol_per_m3 = 0.5;
    cell.aluminum_mol_per_m3 = 1;
    cell.iron_mol_per_m3 = 1;
    cell.calcium_mol_per_m3 = 1;
    cell.magnesium_mol_per_m3 = 1;
    cell.sodium_mol_per_m3 = 1;
    cell.potassium_mol_per_m3 = 1;

    var parameters = unitParameters();
    parameters.cation_exchange_capacity_mol_charge_per_megagram = 1;
    var probe_counts: chemistry.ProbeCounts = .{};
    const context = Context{
        .parameters = parameters,
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = true,
        .solver_options = .{
            .absolute_tolerance_mol_per_m3 = 1e-14,
            .absolute_tolerance_mol_per_megagram = 1e-14,
            .relative_tolerance = 1e-13,
            .picard_relaxation = 0.35,
            .max_iterations = 1,
            .anderson_recovery = true,
            .probe_counts = &probe_counts,
        },
    };
    try std.testing.expectError(
        error.LitterExchangeSolverDidNotConverge,
        equilibrateCationExchangeOpaque(&context, cell),
    );
    try std.testing.expect(probe_counts.iterations > 0);
}

test "dynamic-salt litter evaluates carbonate and salt minerals" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var cell = state.cells[0];
    cell.hydrogen_mol_per_m3 = 1;
    cell.hydroxide_mol_per_m3 = 1;
    cell.ammonia_mol_per_m3 = 1;
    cell.ammonium_mol_per_m3 = 1;
    cell.hpo4_mol_p_per_m3 = 1;
    cell.h2po4_mol_p_per_m3 = 1;
    cell.aluminum_mol_per_m3 = 2;
    cell.iron_mol_per_m3 = 2;
    cell.calcium_mol_per_m3 = 2;
    cell.magnesium_mol_per_m3 = 1;
    cell.sodium_mol_per_m3 = 1;
    cell.potassium_mol_per_m3 = 1;
    cell.carbonate_mol_per_m3 = 2;
    cell.bicarbonate_mol_per_m3 = 0.5;
    cell.carbon_dioxide_mol_per_m3 = 0.25;
    cell.sulfate_mol_per_m3 = 2;
    var parameters = unitParameters();
    parameters.minerals.gibbsite = 0.01;
    parameters.minerals.iron_hydroxide = 0.01;
    parameters.minerals.calcite = 0.01;
    parameters.minerals.gypsum = 0.01;
    parameters.kinetics.maximum_phosphate_precipitation_mol_per_m3_step = 0.01;
    parameters.kinetics.maximum_apatite_precipitation_mol_per_m3_step = 0.01;
    const extents = try calculate(cell, .{ .parameters = parameters, .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = true });
    try std.testing.expect(extents.carbonate_hydrogen_association_mol_per_m3 > 0);
    try std.testing.expect(extents.salt_minerals.gibbsite_mol_per_m3 > 0);
    try std.testing.expect(extents.salt_minerals.iron_hydroxide_mol_per_m3 > 0);
    try std.testing.expect(extents.salt_minerals.calcite_mol_per_m3 > 0);
    try std.testing.expect(extents.salt_minerals.gypsum_mol_per_m3 > 0);
}

test "dynamic-salt apatite hydroxide debit remains a bounded solver direction" {
    // Production-shaped acidic litter: water equilibrium leaves only a tiny
    // OH pool, while Ca and phosphate can request a larger simultaneous
    // hydroxyapatite precipitation step. SOLUTE.F 4990--5067 carries that
    // debit in ROH and lets the shared hourly admissibility bound limit the
    // complete direction; it does not treat COH1+ROH as a salt-mineral substrate.
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var cell = state.cells[0];
    cell.hydrogen_mol_per_m3 = 1e-3;
    cell.hydroxide_mol_per_m3 = 1e-5;
    cell.hpo4_mol_p_per_m3 = 1;
    cell.h2po4_mol_p_per_m3 = 1;
    cell.aluminum_mol_per_m3 = 1;
    cell.iron_mol_per_m3 = 1;
    cell.calcium_mol_per_m3 = 1;
    cell.magnesium_mol_per_m3 = 1;
    cell.sodium_mol_per_m3 = 1;
    cell.potassium_mol_per_m3 = 1;
    cell.carbonate_mol_per_m3 = 1;
    cell.bicarbonate_mol_per_m3 = 1;
    cell.carbon_dioxide_mol_per_m3 = 1;
    cell.sulfate_mol_per_m3 = 1;

    var parameters = unitParameters();
    parameters.water_activity_product_mol2_per_m6 = 1e-8;
    parameters.kinetics.maximum_ammonium_association_mol_per_m3_step = 0;
    parameters.kinetics.maximum_association_mol_per_m3_step = 0;
    parameters.kinetics.maximum_phosphate_precipitation_mol_per_m3_step = 1;
    parameters.kinetics.maximum_apatite_precipitation_mol_per_m3_step = 1;
    parameters.minerals.aluminum_phosphate = 1e12;
    parameters.minerals.iron_phosphate = 1e12;
    parameters.minerals.dicalcium_phosphate = 1e12;
    parameters.minerals.monocalcium_phosphate = 1e12;
    parameters.minerals.hydroxyapatite = 1e-30;

    const extents = try calculate(cell, .{
        .parameters = parameters,
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = true,
    });
    try std.testing.expect(extents.phosphate_minerals.hydroxyapatite_mol_per_m3 > cell.hydroxide_mol_per_m3);
    const changes = try ledger.assemble(extents, 1, true);
    try std.testing.expect(changes.hydroxide_mol_per_m3 < -cell.hydroxide_mol_per_m3);
    const fraction = @min(1.0, arith.maximumAdmissibleFraction(chemistry.Cell, cell, changes));
    const candidate = try arith.applyAdmissibleFraction(cell, changes, fraction, .{ .max_iterations = 60 });
    try std.testing.expect(candidate.hydroxide_mol_per_m3 >= 0);
}

test "dynamic-salt mineral residual accepts a signed simultaneous carbonate coordinate" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var cell = state.cells[0];
    cell.aluminum_mol_per_m3 = 1;
    cell.iron_mol_per_m3 = 1;
    cell.calcium_mol_per_m3 = 1;
    cell.carbonate_mol_per_m3 = 0.01;
    cell.sulfate_mol_per_m3 = 1;
    cell.salt_minerals.calcite_mol_per_m3 = 0.1;

    var simultaneous = std.mem.zeroes(chemistry.Cell);
    simultaneous.carbonate_mol_per_m3 = -0.02;
    var parameters = unitParameters();
    parameters.minerals.calcite = 0.01;
    const extents = try saltMinerals(cell, simultaneous, 1, .{
        .parameters = parameters,
        .litter_mass_per_water_volume_megagrams_per_m3 = 1,
        .dynamic_salts = true,
    });
    // SOLUTE.F carries CCO3X=CCO31+RCO3 as a signed residual coordinate;
    // its source-ordered XMIN bound requests dissolution here. The outer
    // admissible projection, not an inner clamp, decides the published state.
    try std.testing.expect(extents.calcite_mol_per_m3 < 0);
}

test "litter gypsum evaluates against undepleted calcium, unlike bulk-soil SOLUTE-013 sequencing" {
    // Surface-litter `solute.f:5049-5075` never recomputes CCAX/ACA1 between
    // the calcite and gypsum blocks (contrast the bulk-soil branch at
    // `solute.f:2509-2548`, which explicitly updates CCA1/ACA1 after calcite
    // before gypsum -- see the sibling `SOLUTE-013` fix in
    // `geochemistry_reaction_rates.zig`). This locks in the source-faithful,
    // simultaneous litter evaluation so it cannot silently regress back to
    // depleting calcium before gypsum.
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var cell = state.cells[0];
    cell.calcium_mol_per_m3 = 0.5;
    cell.carbonate_mol_per_m3 = 0.5;
    cell.sulfate_mol_per_m3 = 0.5;
    cell.salt_minerals.calcite_mol_per_m3 = 0.1;
    cell.salt_minerals.gypsum_mol_per_m3 = 0.1;

    var base_state = try chemistry.State.init(std.testing.allocator, 1);
    defer base_state.deinit();
    const base = base_state.cells[0];

    var parameters = unitParameters();
    parameters.minerals.calcite = 0.01;
    parameters.minerals.gypsum = 0.01;
    parameters.kinetics.general_substrate_limit_fraction = 0.5;
    parameters.kinetics.maximum_phosphate_precipitation_mol_per_m3_step = 10;
    const context = Context{ .parameters = parameters, .litter_mass_per_water_volume_megagrams_per_m3 = 1, .dynamic_salts = true };

    const extents = try saltMinerals(cell, base, 0, context);

    // Independent oracle: both extents evaluated from the same (undepleted)
    // 0.5 mol/m3 calcium pool, mirroring the literal source.
    const expected = try mineral_precipitation.calculateExtent(
        .{ .dissolved_first_mol_per_m3 = 0.5, .dissolved_second_mol_per_m3 = 0.5, .solid_mol_per_m3 = 0.1 },
        0.5,
        0.5,
        .{ .first_mol_per_mol_solid = 1, .second_mol_per_mol_solid = 1 },
        .{ .solubility_product = 0.01, .first_activity_coefficient = 1, .substrate_limit_fraction = 0.5, .maximum_precipitation_mol_per_m3_step = 10, .maximum_dissolution_mol_per_m3_step = 10 },
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), expected, 1e-12);
    try std.testing.expectApproxEqAbs(expected, extents.calcite_mol_per_m3, 1e-12);
    try std.testing.expectApproxEqAbs(expected, extents.gypsum_mol_per_m3, 1e-12);
}

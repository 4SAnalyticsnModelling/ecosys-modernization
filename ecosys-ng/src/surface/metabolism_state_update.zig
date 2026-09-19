const std = @import("std");
const compute = @import("../core/compute.zig");
const gas = @import("../soil/gas/transport.zig");
const organic = @import("../soil/organic/initialization.zig");
const chemistry = @import("litter_chemistry.zig");
const respiration = @import("microbial_respiration_step.zig");
const oxygen = @import("microbial_oxygen_driver.zig");
const fixation = @import("nonsymbiotic_nitrogen_fixation_step.zig");
const uptake = @import("microbial_substrate_uptake_step.zig");
const denitrification = @import("denitrification_step.zig");
const assimilation = @import("microbial_assimilation_step.zig");
const mineral_exchange = @import("microbial_mineral_exchange_step.zig");
const topsoil_exchange = @import("topsoil_mineral_exchange_step.zig");
const turnover = @import("microbial_turnover_step.zig");
const priming = @import("organic_priming_step.zig");
const organic_decomposition = @import("organic_decomposition_step.zig");
const organic_sorption = @import("organic_sorption_step.zig");
const litter_colonization = @import("litter_colonization_step.zig");
const metabolism = @import("../soil/microbial/metabolism.zig");
const soil_chemistry = @import("../soil/solute/chemistry_state.zig");
const aqueous_network = @import("../soil/solute/aqueous_network.zig");
const grid = @import("../state/grid.zig");
const zone_classification = @import("../soil/solute/charge_classification.zig");
const scoped_conservation = @import("../validation/scoped_conservation.zig");
const legacy_water_negligible_floor = @import("../core/legacy_water_negligible_floor.zig");

pub const ApplyContext = struct {
    surface_organic: *organic.State,
    litter_chemistry: *chemistry.State,
    litter_gas: *gas.State,
    litter_water_m3: []const f64,
    /// Per-cell horizontal footprint (m2), used only to derive the legacy
    /// `ZEROS2` negligible-water floor (issue-061) for
    /// `effectiveAqueousCarrierM3`; not otherwise consumed by this stage.
    cell_area_m2: []const f64,
    respiration: *const respiration.State,
    oxygen: *const oxygen.State,
    nitrogen_fixation: *const fixation.State,
    substrate_uptake: *const uptake.State,
    denitrification: *denitrification.State,
    assimilation: *const assimilation.State,
    mineral_exchange: *const mineral_exchange.State,
    topsoil_exchange: *const topsoil_exchange.State,
    turnover: *const turnover.State,
    priming: *const priming.State,
    organic_decomposition: *const organic_decomposition.State,
    organic_sorption: *const organic_sorption.State,
    litter_colonization: *const litter_colonization.State,
    topsoil_organic: *organic.State,
    topsoil_humus_partition: []const [2]f64,
    topsoil_chemistry: *soil_chemistry.State,
    model_grid: *const grid.GridState,
    zone_fractions: zone_classification.ZoneFractions,
    zone_fractions_by_layer: []const zone_classification.ZoneFractions = &.{},
    microbial_parameters: respiration.Parameters,
    nitrogen_molar_mass_g_per_mol: f64,
    negligible_carbon_g_c: f64,
    fraction_tolerance: f64,
    phosphorus_molar_mass_g_per_mol: f64,
    hourly_signed_heterotrophic_respiration_g_c: ?[]f64 = null,
    hourly_carbon_dioxide_production_g_c: ?[]f64 = null,
};

/// Atomic per-cell NITRO redistribution for the translated surface metabolism
/// block. All source sufficiency and finite-result checks precede mutation.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| {
        var cell_context = context.*;
        if (context.zone_fractions_by_layer.len != 0) {
            const top = try context.model_grid.layerIndex(cell, 0);
            cell_context.zone_fractions = context.zone_fractions_by_layer[top];
        }
        try state_updateCell(&cell_context, cell);
    }
}

fn state_updateCell(context: *ApplyContext, cell: usize) !void {
    const conserved_carbon_before_g_c = try authoritativeCellCarbon_g_c(context.*, cell);
    const conserved_nitrogen_before_g_n = try authoritativeCellNitrogen_g_n(context.*, cell);
    const conserved_phosphorus_before_g_p = try authoritativeCellPhosphorus_g_p(context.*, cell);
    const hydrogen_index = cell * gas.species_count + @intFromEnum(gas.Species.hydrogen);
    const hydrogen_before_g_h = context.litter_gas.dissolved_mass_g[hydrogen_index];
    var dissolved_after: [respiration.litter_complex_count]organic.ElementPool = undefined;
    var acetate_after: [respiration.litter_complex_count]f64 = undefined;
    var nonstructural_after: [respiration.unit_count_per_cell]organic.ElementPool = undefined;
    var structural_after: [respiration.unit_count_per_cell * assimilation.structural_component_count]organic.ElementPool = undefined;
    var residue_after: [respiration.litter_complex_count * turnover.structural_component_count]organic.ElementPool = undefined;
    var substrate_structural_after: [respiration.litter_complex_count * organic.structural_fraction_count]organic.ElementPool = undefined;
    var colonized_structural_after: [respiration.litter_complex_count * organic.structural_fraction_count]f64 = undefined;
    var adsorbed_after: [respiration.litter_complex_count]organic.ElementPool = undefined;
    var adsorbed_acetate_after: [respiration.litter_complex_count]f64 = undefined;
    var total_co2_g_c: f64 = 0;
    var total_ch4_g_c: f64 = 0;
    var total_h2_g_h: f64 = 0;
    var total_fixed_n_g_n: f64 = 0;
    var total_ammonium_exchange_g_n: f64 = 0;
    var total_nitrate_exchange_g_n: f64 = 0;
    var total_h2po4_exchange_g_p: f64 = 0;
    var total_hpo4_exchange_g_p: f64 = 0;
    const top_organic_layer = try context.model_grid.layerIndex(cell, 0);
    var topsoil_humus_after = [2]organic.ElementPool{
        context.topsoil_organic.structural[(top_organic_layer * organic.substrate_count + 4) * organic.structural_fraction_count],
        context.topsoil_organic.structural[(top_organic_layer * organic.substrate_count + 4) * organic.structural_fraction_count + 1],
    };
    var topsoil_humus_colonized_after = [2]f64{
        context.topsoil_organic.colonized_structural_carbon_g_c[(top_organic_layer * organic.substrate_count + 4) * organic.structural_fraction_count],
        context.topsoil_organic.colonized_structural_carbon_g_c[(top_organic_layer * organic.substrate_count + 4) * organic.structural_fraction_count + 1],
    };
    const topsoil_particulate_index = (top_organic_layer * organic.substrate_count + 3) * organic.structural_fraction_count;
    var topsoil_particulate_after = context.topsoil_organic.structural[topsoil_particulate_index];
    var topsoil_particulate_colonized_after = context.topsoil_organic.colonized_structural_carbon_g_c[topsoil_particulate_index];

    for (0..respiration.litter_complex_count) |complex| {
        const compact = cell * respiration.litter_complex_count + complex;
        var decomposition_dissolved_input: organic.ElementPool = .{};
        for (0..organic.structural_fraction_count) |fraction| {
            const local = complex * organic.structural_fraction_count + fraction;
            const surface_index = (cell * organic.substrate_count + complex) * organic.structural_fraction_count + fraction;
            const decomposed = context.organic_decomposition.structural_decomposition[compact * organic.structural_fraction_count + fraction];
            substrate_structural_after[local] = subtractPool(context.surface_organic.structural[surface_index], decomposed);
            colonized_structural_after[local] = context.surface_organic.colonized_structural_carbon_g_c[surface_index] - decomposed.carbon_g_c + context.litter_colonization.colonized_carbon_increment_g_c[compact * organic.structural_fraction_count + fraction];
            decomposition_dissolved_input = addPool(decomposition_dissolved_input, context.organic_decomposition.dissolved_structural_products[compact * organic.structural_fraction_count + fraction]);
            const particulate = context.organic_decomposition.particulate_products[compact * organic.structural_fraction_count + fraction];
            topsoil_particulate_after = addPool(topsoil_particulate_after, particulate);
            topsoil_particulate_colonized_after += particulate.carbon_g_c;
        }
        for (0..turnover.structural_component_count) |component| residue_after[complex * turnover.structural_component_count + component] = context.surface_organic.residue[(cell * organic.substrate_count + complex) * organic.residue_fraction_count + component];
        for (0..organic.residue_fraction_count) |fraction| decomposition_dissolved_input = addPool(decomposition_dissolved_input, context.organic_decomposition.microbial_residue_decomposition[compact * organic.residue_fraction_count + fraction]);
        decomposition_dissolved_input = addPool(decomposition_dissolved_input, context.organic_decomposition.sorbed_organic_decomposition[compact]);
        const mobile = cell * organic.substrate_count + complex;
        const adsorbed_before_sorption = subtractPool(context.surface_organic.adsorbed[mobile], context.organic_decomposition.sorbed_organic_decomposition[compact]);
        const adsorbed_acetate_before_sorption = context.surface_organic.adsorbed_acetate_carbon_g_c[mobile] - context.organic_decomposition.sorbed_acetate_decomposition_g_c[compact];
        var sorption: organic.ElementPool = .{ .carbon_g_c = context.organic_sorption.doc_sorption_g_c[compact], .nitrogen_g_n = context.organic_sorption.don_sorption_g_n[compact], .phosphorus_g_p = context.organic_sorption.dop_sorption_g_p[compact] };
        var doc_c: f64 = 0;
        var don_n: f64 = 0;
        var dop_p: f64 = 0;
        var acetate_c: f64 = 0;
        var fermentation_c: f64 = 0;
        for (0..respiration.source_population_count) |population| {
            const unit_local = complex * respiration.source_population_count + population;
            const unit = cell * respiration.unit_count_per_cell + unit_local;
            doc_c += context.substrate_uptake.doc_uptake_g_c[unit];
            don_n += context.substrate_uptake.dissolved_organic_nitrogen_uptake_g_n[unit];
            dop_p += context.substrate_uptake.dissolved_organic_phosphorus_uptake_g_p[unit];
            acetate_c += context.substrate_uptake.acetate_uptake_g_c[unit];
            const oxygen_fraction = if (context.oxygen.populations[unit].is_aerobic) context.oxygen.allocation.demand_satisfaction_fraction[unit] else 1;
            const actual_respiration_g_c = context.respiration.substrate_limited_respiration_g_c[unit] * oxygen_fraction;
            switch (context.microbial_parameters.populations[population].metabolism) {
                .aerobic_heterotroph => total_co2_g_c += actual_respiration_g_c,
                .fermenting_heterotroph => {
                    total_co2_g_c += 0.333 * actual_respiration_g_c;
                    fermentation_c += 0.667 * actual_respiration_g_c;
                    total_h2_g_h += 0.111 * actual_respiration_g_c;
                },
                .acetotrophic_methanogen => {
                    total_co2_g_c += 0.5 * actual_respiration_g_c;
                    total_ch4_g_c += 0.5 * actual_respiration_g_c;
                },
            }
            total_co2_g_c += context.substrate_uptake.denitrification_respiration_g_c[unit] + context.nitrogen_fixation.fixation_respiration_g_c[unit];
            total_fixed_n_g_n += context.nitrogen_fixation.fixed_nitrogen_g_n[unit];
            const mineral_n = context.mineral_exchange.ammonium_exchange_g_n[unit] + context.mineral_exchange.nitrate_exchange_g_n[unit];
            const mineral_p = context.mineral_exchange.h2po4_exchange_g_p[unit] + context.mineral_exchange.hpo4_exchange_g_p[unit];
            const topsoil_n = context.topsoil_exchange.ammonium_exchange_g_n[unit] + context.topsoil_exchange.nitrate_exchange_g_n[unit];
            const topsoil_p = context.topsoil_exchange.h2po4_exchange_g_p[unit] + context.topsoil_exchange.hpo4_exchange_g_p[unit];
            total_ammonium_exchange_g_n += context.mineral_exchange.ammonium_exchange_g_n[unit];
            total_nitrate_exchange_g_n += context.mineral_exchange.nitrate_exchange_g_n[unit];
            total_h2po4_exchange_g_p += context.mineral_exchange.h2po4_exchange_g_p[unit];
            total_hpo4_exchange_g_p += context.mineral_exchange.hpo4_exchange_g_p[unit];

            const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count + 2;
            const current = context.surface_organic.microbial[microbial];
            var structural_transfer: organic.ElementPool = .{};
            var turnover_recycled_to_nonstructural: organic.ElementPool = .{};
            for (0..assimilation.structural_component_count) |component| {
                const transfer = context.assimilation.transfer[(unit * assimilation.structural_component_count) + component];
                structural_transfer.carbon_g_c += transfer.carbon_g_c;
                structural_transfer.nitrogen_g_n += transfer.nitrogen_g_n;
                structural_transfer.phosphorus_g_p += transfer.phosphorus_g_p;
                const current_structural = context.surface_organic.microbial[microbial - 2 + component];
                const priming_change = context.priming.exchange.microbial_change[cell * respiration.unit_count_per_cell * organic.kinetic_fraction_count + unit_local * organic.kinetic_fraction_count + component];
                const turnover_index = unit * turnover.structural_component_count + component;
                const basal = context.turnover.basal[turnover_index];
                const senescence = context.turnover.senescence[turnover_index];
                structural_after[(unit_local * assimilation.structural_component_count) + component] = .{ .carbon_g_c = current_structural.carbon_g_c + transfer.carbon_g_c - basal.decomposed.carbon_g_c - senescence.decomposed.carbon_g_c + priming_change.carbon_g_c, .nitrogen_g_n = current_structural.nitrogen_g_n + transfer.nitrogen_g_n - basal.decomposed.nitrogen_g_n - senescence.decomposed.nitrogen_g_n + priming_change.nitrogen_g_n, .phosphorus_g_p = current_structural.phosphorus_g_p + transfer.phosphorus_g_p - basal.decomposed.phosphorus_g_p - senescence.decomposed.phosphorus_g_p + priming_change.phosphorus_g_p };
                try finitePool(structural_after[(unit_local * assimilation.structural_component_count) + component]);
                turnover_recycled_to_nonstructural = addPool(turnover_recycled_to_nonstructural, fromMetabolic(basal.recycled));
                turnover_recycled_to_nonstructural.nitrogen_g_n += senescence.recycled.nitrogen_g_n;
                turnover_recycled_to_nonstructural.phosphorus_g_p += senescence.recycled.phosphorus_g_p;
                total_co2_g_c += senescence.recycled.carbon_g_c;
                const residue_index = complex * turnover.structural_component_count + component;
                residue_after[residue_index] = addPool(residue_after[residue_index], fromMetabolic(basal.microbial_residue));
                residue_after[residue_index] = addPool(residue_after[residue_index], fromMetabolic(senescence.microbial_residue));
                const humified = addPool(fromMetabolic(basal.humified), fromMetabolic(senescence.humified));
                for (0..2) |humus_class| {
                    const humus_input = scalePool(humified, context.topsoil_humus_partition[cell][humus_class]);
                    topsoil_humus_after[humus_class] = addPool(topsoil_humus_after[humus_class], humus_input);
                    topsoil_humus_colonized_after[humus_class] += humus_input.carbon_g_c;
                }
            }
            _ = try nonnegativeCandidate(current.carbon_g_c - structural_transfer.carbon_g_c, @abs(current.carbon_g_c) + @abs(structural_transfer.carbon_g_c), error.InsufficientNonstructuralSurfaceMicrobialPool);
            _ = try nonnegativeCandidate(current.nitrogen_g_n - structural_transfer.nitrogen_g_n, @abs(current.nitrogen_g_n) + @abs(structural_transfer.nitrogen_g_n), error.InsufficientNonstructuralSurfaceMicrobialPool);
            _ = try nonnegativeCandidate(current.phosphorus_g_p - structural_transfer.phosphorus_g_p, @abs(current.phosphorus_g_p) + @abs(structural_transfer.phosphorus_g_p), error.InsufficientNonstructuralSurfaceMicrobialPool);
            nonstructural_after[unit_local] = .{
                .carbon_g_c = current.carbon_g_c - structural_transfer.carbon_g_c + context.substrate_uptake.nonstructural_carbon_gain_g_c[unit],
                .nitrogen_g_n = current.nitrogen_g_n - structural_transfer.nitrogen_g_n + context.substrate_uptake.dissolved_organic_nitrogen_uptake_g_n[unit] + context.nitrogen_fixation.fixed_nitrogen_g_n[unit] + mineral_n,
                .phosphorus_g_p = current.phosphorus_g_p - structural_transfer.phosphorus_g_p + context.substrate_uptake.dissolved_organic_phosphorus_uptake_g_p[unit] + mineral_p + topsoil_p,
            };
            nonstructural_after[unit_local] = addPool(nonstructural_after[unit_local], turnover_recycled_to_nonstructural);
            nonstructural_after[unit_local] = addPool(nonstructural_after[unit_local], context.priming.exchange.microbial_change[cell * respiration.unit_count_per_cell * organic.kinetic_fraction_count + unit_local * organic.kinetic_fraction_count + 2]);
            nonstructural_after[unit_local].nitrogen_g_n += topsoil_n;
            try finitePool(nonstructural_after[unit_local]);
        }
        const current = context.surface_organic.dissolved[mobile];
        _ = try nonnegativeCandidate(current.carbon_g_c - doc_c, @abs(current.carbon_g_c) + @abs(doc_c), error.InsufficientSurfaceMicrobialSubstrate);
        _ = try nonnegativeCandidate(current.nitrogen_g_n - don_n, @abs(current.nitrogen_g_n) + @abs(don_n), error.InsufficientSurfaceMicrobialSubstrate);
        _ = try nonnegativeCandidate(current.phosphorus_g_p - dop_p, @abs(current.phosphorus_g_p) + @abs(dop_p), error.InsufficientSurfaceMicrobialSubstrate);
        _ = try nonnegativeCandidate(context.surface_organic.dissolved_acetate_carbon_g_c[mobile] - acetate_c, @abs(context.surface_organic.dissolved_acetate_carbon_g_c[mobile]) + @abs(acetate_c), error.InsufficientSurfaceMicrobialSubstrate);
        const priming_index = cell * priming.substrate_count + complex;
        dissolved_after[complex] = addPool(addPool(.{ .carbon_g_c = current.carbon_g_c - doc_c, .nitrogen_g_n = current.nitrogen_g_n - don_n, .phosphorus_g_p = current.phosphorus_g_p - dop_p }, context.priming.exchange.dissolved_change[priming_index]), decomposition_dissolved_input);
        sorption.carbon_g_c = boundedExchange(sorption.carbon_g_c, dissolved_after[complex].carbon_g_c, adsorbed_before_sorption.carbon_g_c);
        sorption.nitrogen_g_n = boundedExchange(sorption.nitrogen_g_n, dissolved_after[complex].nitrogen_g_n, adsorbed_before_sorption.nitrogen_g_n);
        sorption.phosphorus_g_p = boundedExchange(sorption.phosphorus_g_p, dissolved_after[complex].phosphorus_g_p, adsorbed_before_sorption.phosphorus_g_p);
        adsorbed_after[complex] = addPool(adsorbed_before_sorption, sorption);
        dissolved_after[complex] = subtractPool(dissolved_after[complex], sorption);
        acetate_after[complex] = context.surface_organic.dissolved_acetate_carbon_g_c[mobile] - acetate_c + fermentation_c + context.priming.exchange.acetate_change_g_c[priming_index] + context.organic_decomposition.sorbed_acetate_decomposition_g_c[compact];
        const acetate_sorption_g_c = boundedExchange(context.organic_sorption.acetate_sorption_g_c[compact], acetate_after[complex], adsorbed_acetate_before_sorption);
        adsorbed_acetate_after[complex] = try nonnegativeCandidate(
            adsorbed_acetate_before_sorption + acetate_sorption_g_c,
            @abs(adsorbed_acetate_before_sorption) + @abs(acetate_sorption_g_c),
            error.NonFiniteSurfaceMetabolismStateUpdate,
        );
        acetate_after[complex] -= acetate_sorption_g_c;
        try finitePool(dissolved_after[complex]);
        if (!std.math.isFinite(acetate_after[complex]) or acetate_after[complex] < 0) return error.NonFiniteSurfaceMetabolismStateUpdate;
    }

    const chemo_don_g_n = context.denitrification.chemodenitrification_dissolved_organic_nitrogen_production_g_n[cell];
    var total_residue_carbon_g_c: f64 = 0;
    for (residue_after) |pool| total_residue_carbon_g_c += pool.carbon_g_c;
    for (0..respiration.litter_complex_count) |complex| {
        var complex_residue_carbon_g_c: f64 = 0;
        for (0..turnover.structural_component_count) |component| complex_residue_carbon_g_c += residue_after[complex * turnover.structural_component_count + component].carbon_g_c;
        const residue_fraction: f64 = if (total_residue_carbon_g_c > context.negligible_carbon_g_c) complex_residue_carbon_g_c / total_residue_carbon_g_c else if (complex == 0) 1.0 else 0.0;
        dissolved_after[complex].nitrogen_g_n += chemo_don_g_n * residue_fraction;
    }

    const water_m3 = context.litter_water_m3[cell];
    // `litter_chemistry_carrier_rebase` retains aqueous concentrations on the
    // last positive carrier when litter becomes exactly dry.  HOUR1 stores the
    // corresponding extensive mass directly, so a dry biological step must
    // reconstruct and publish against that remembered carrier rather than
    // treating live water == 0 as an empty inventory.
    const aqueous_carrier_m3 = effectiveAqueousCarrierM3(
        water_m3,
        context.litter_chemistry.dry_reference_water_m3[cell],
        negligibleLitterWaterVolumeM3(context.cell_area_m2[cell]),
    );
    const nitrate_before_g_n = context.litter_chemistry.cells[cell].nitrate_mol_per_m3 * aqueous_carrier_m3 * context.nitrogen_molar_mass_g_per_mol;
    const ammonium_before_g_n = context.litter_chemistry.cells[cell].ammonium_mol_per_m3 * aqueous_carrier_m3 * context.nitrogen_molar_mass_g_per_mol;
    const h2po4_before_g_p = context.litter_chemistry.cells[cell].h2po4_mol_p_per_m3 * aqueous_carrier_m3 * context.phosphorus_molar_mass_g_per_mol;
    const hpo4_before_g_p = context.litter_chemistry.cells[cell].hpo4_mol_p_per_m3 * aqueous_carrier_m3 * context.phosphorus_molar_mass_g_per_mol;
    var nitrate_reduction_g_n: f64 = 0;
    var nitrite_reduction_g_n: f64 = 0;
    var n2o_reduction_g_n: f64 = 0;
    for (0..respiration.litter_complex_count) |complex| {
        const compact = cell * respiration.litter_complex_count + complex;
        nitrate_reduction_g_n += context.denitrification.nitrate_reduction_g_n[compact];
        nitrite_reduction_g_n += context.denitrification.nitrite_reduction_g_n[compact];
        n2o_reduction_g_n += context.denitrification.nitrous_oxide_reduction_g_n[compact];
    }
    const chemo_nitrite_reduction_g_n = context.denitrification.chemodenitrification_nitrite_reduction_g_n[cell];
    const chemo_n2o_production_g_n = context.denitrification.chemodenitrification_nitrous_oxide_production_g_n[cell];
    const nitrite_before_g_n = context.denitrification.nitrite_g_n[cell];
    const n2o_index = cell * gas.species_count + @intFromEnum(gas.Species.nitrous_oxide);
    const n2_index = cell * gas.species_count + @intFromEnum(gas.Species.nitrogen);
    const n2o_before_g_n = context.litter_gas.dissolved_mass_g[n2o_index];
    const n2_before_g_n = context.litter_gas.dissolved_mass_g[n2_index];
    const top = try context.model_grid.layerIndex(cell, 0);
    const top_water_m3 = context.model_grid.matrix_liquid_water_m3[top];
    var top_aqueous_after = context.topsoil_chemistry.aqueous[top];
    var top_non_band_phosphate_after = context.topsoil_chemistry.non_band_phosphate[top];
    var top_band_phosphate_after = context.topsoil_chemistry.band_phosphate[top];
    var top_ammonium_g_n: f64 = 0;
    var top_nitrate_g_n: f64 = 0;
    var top_h2po4_g_p: f64 = 0;
    var top_hpo4_g_p: f64 = 0;
    for (cell * respiration.unit_count_per_cell..(cell + 1) * respiration.unit_count_per_cell) |unit| {
        top_ammonium_g_n += context.topsoil_exchange.ammonium_exchange_g_n[unit];
        top_nitrate_g_n += context.topsoil_exchange.nitrate_exchange_g_n[unit];
        top_h2po4_g_p += context.topsoil_exchange.h2po4_exchange_g_p[unit];
        top_hpo4_g_p += context.topsoil_exchange.hpo4_exchange_g_p[unit];
    }
    const top_ammonium_available = top_water_m3 * context.nitrogen_molar_mass_g_per_mol * (context.zone_fractions.ammonium_non_band * top_aqueous_after.ammonium_non_band + context.zone_fractions.ammonium_band * top_aqueous_after.ammonium_band);
    const top_nitrate_available = top_water_m3 * context.nitrogen_molar_mass_g_per_mol * (context.zone_fractions.nitrate_non_band * top_aqueous_after.nitrate_non_band + context.zone_fractions.nitrate_band * top_aqueous_after.nitrate_band);
    const top_h2po4_available = top_water_m3 * context.phosphorus_molar_mass_g_per_mol * (context.zone_fractions.phosphate_non_band * top_non_band_phosphate_after.dissolved_h2po4_mol_p_per_m3 + context.zone_fractions.phosphate_band * top_band_phosphate_after.dissolved_h2po4_mol_p_per_m3);
    const top_hpo4_available = top_water_m3 * context.phosphorus_molar_mass_g_per_mol * (context.zone_fractions.phosphate_non_band * top_non_band_phosphate_after.dissolved_hpo4_mol_p_per_m3 + context.zone_fractions.phosphate_band * top_band_phosphate_after.dissolved_hpo4_mol_p_per_m3);
    if (top_water_m3 > 0) {
        const ammonium_delta = top_ammonium_g_n / (top_water_m3 * context.nitrogen_molar_mass_g_per_mol);
        const nitrate_delta = top_nitrate_g_n / (top_water_m3 * context.nitrogen_molar_mass_g_per_mol);
        const h2po4_delta = top_h2po4_g_p / (top_water_m3 * context.phosphorus_molar_mass_g_per_mol);
        const hpo4_delta = top_hpo4_g_p / (top_water_m3 * context.phosphorus_molar_mass_g_per_mol);
        if (context.zone_fractions.ammonium_non_band > 0) top_aqueous_after.ammonium_non_band -= ammonium_delta;
        if (context.zone_fractions.ammonium_band > 0) top_aqueous_after.ammonium_band -= ammonium_delta;
        if (context.zone_fractions.nitrate_non_band > 0) top_aqueous_after.nitrate_non_band -= nitrate_delta;
        if (context.zone_fractions.nitrate_band > 0) top_aqueous_after.nitrate_band -= nitrate_delta;
        if (context.zone_fractions.phosphate_non_band > 0) {
            top_non_band_phosphate_after.dissolved_h2po4_mol_p_per_m3 -= h2po4_delta;
            top_non_band_phosphate_after.dissolved_hpo4_mol_p_per_m3 -= hpo4_delta;
        }
        if (context.zone_fractions.phosphate_band > 0) {
            top_band_phosphate_after.dissolved_h2po4_mol_p_per_m3 -= h2po4_delta;
            top_band_phosphate_after.dissolved_hpo4_mol_p_per_m3 -= hpo4_delta;
        }
        top_aqueous_after.ammonium_non_band = try nonnegativeCandidate(top_aqueous_after.ammonium_non_band, @abs(context.topsoil_chemistry.aqueous[top].ammonium_non_band) + @abs(ammonium_delta), error.InsufficientTopsoilMineralNutrient);
        top_aqueous_after.ammonium_band = try nonnegativeCandidate(top_aqueous_after.ammonium_band, @abs(context.topsoil_chemistry.aqueous[top].ammonium_band) + @abs(ammonium_delta), error.InsufficientTopsoilMineralNutrient);
        top_aqueous_after.nitrate_non_band = try nonnegativeCandidate(top_aqueous_after.nitrate_non_band, @abs(context.topsoil_chemistry.aqueous[top].nitrate_non_band) + @abs(nitrate_delta), error.InsufficientTopsoilMineralNutrient);
        top_aqueous_after.nitrate_band = try nonnegativeCandidate(top_aqueous_after.nitrate_band, @abs(context.topsoil_chemistry.aqueous[top].nitrate_band) + @abs(nitrate_delta), error.InsufficientTopsoilMineralNutrient);
        top_non_band_phosphate_after.dissolved_h2po4_mol_p_per_m3 = try nonnegativeCandidate(top_non_band_phosphate_after.dissolved_h2po4_mol_p_per_m3, @abs(context.topsoil_chemistry.non_band_phosphate[top].dissolved_h2po4_mol_p_per_m3) + @abs(h2po4_delta), error.InsufficientTopsoilMineralNutrient);
        top_non_band_phosphate_after.dissolved_hpo4_mol_p_per_m3 = try nonnegativeCandidate(top_non_band_phosphate_after.dissolved_hpo4_mol_p_per_m3, @abs(context.topsoil_chemistry.non_band_phosphate[top].dissolved_hpo4_mol_p_per_m3) + @abs(hpo4_delta), error.InsufficientTopsoilMineralNutrient);
        top_band_phosphate_after.dissolved_h2po4_mol_p_per_m3 = try nonnegativeCandidate(top_band_phosphate_after.dissolved_h2po4_mol_p_per_m3, @abs(context.topsoil_chemistry.band_phosphate[top].dissolved_h2po4_mol_p_per_m3) + @abs(h2po4_delta), error.InsufficientTopsoilMineralNutrient);
        top_band_phosphate_after.dissolved_hpo4_mol_p_per_m3 = try nonnegativeCandidate(top_band_phosphate_after.dissolved_hpo4_mol_p_per_m3, @abs(context.topsoil_chemistry.band_phosphate[top].dissolved_hpo4_mol_p_per_m3) + @abs(hpo4_delta), error.InsufficientTopsoilMineralNutrient);
    }
    inline for (.{
        top_aqueous_after.ammonium_non_band,
        top_aqueous_after.ammonium_band,
        top_aqueous_after.nitrate_non_band,
        top_aqueous_after.nitrate_band,
        top_non_band_phosphate_after.dissolved_h2po4_mol_p_per_m3,
        top_non_band_phosphate_after.dissolved_hpo4_mol_p_per_m3,
        top_band_phosphate_after.dissolved_h2po4_mol_p_per_m3,
        top_band_phosphate_after.dissolved_hpo4_mol_p_per_m3,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InsufficientTopsoilMineralNutrient;
    const ammonium_after_g_n = try nonnegativeCandidate(
        ammonium_before_g_n - total_ammonium_exchange_g_n,
        @abs(ammonium_before_g_n) + @abs(total_ammonium_exchange_g_n),
        error.InsufficientSurfaceInorganicNitrogen,
    );
    const nitrate_after_g_n = try nonnegativeCandidate(
        nitrate_before_g_n - nitrate_reduction_g_n - total_nitrate_exchange_g_n,
        @abs(nitrate_before_g_n) + @abs(nitrate_reduction_g_n) + @abs(total_nitrate_exchange_g_n),
        error.InsufficientSurfaceInorganicNitrogen,
    );
    const h2po4_after_g_p = try nonnegativeCandidate(
        h2po4_before_g_p - total_h2po4_exchange_g_p,
        @abs(h2po4_before_g_p) + @abs(total_h2po4_exchange_g_p),
        error.InsufficientSurfaceInorganicNitrogen,
    );
    const hpo4_after_g_p = try nonnegativeCandidate(
        hpo4_before_g_p - total_hpo4_exchange_g_p,
        @abs(hpo4_before_g_p) + @abs(total_hpo4_exchange_g_p),
        error.InsufficientSurfaceInorganicNitrogen,
    );
    const nitrite_after_g_n = try nonnegativeCandidate(
        nitrite_before_g_n + nitrate_reduction_g_n - nitrite_reduction_g_n - chemo_nitrite_reduction_g_n,
        @abs(nitrite_before_g_n) + @abs(nitrate_reduction_g_n) + @abs(nitrite_reduction_g_n) + @abs(chemo_nitrite_reduction_g_n),
        error.InsufficientSurfaceInorganicNitrogen,
    );
    const n2o_after_g_n = try nonnegativeCandidate(
        n2o_before_g_n + nitrite_reduction_g_n + chemo_n2o_production_g_n - n2o_reduction_g_n,
        @abs(n2o_before_g_n) + @abs(nitrite_reduction_g_n) + @abs(chemo_n2o_production_g_n) + @abs(n2o_reduction_g_n),
        error.InsufficientSurfaceInorganicNitrogen,
    );
    const n2_after_g_n = try nonnegativeCandidate(
        n2_before_g_n + n2o_reduction_g_n - total_fixed_n_g_n,
        @abs(n2_before_g_n) + @abs(n2o_reduction_g_n) + @abs(total_fixed_n_g_n),
        error.InsufficientSurfaceInorganicNitrogen,
    );
    inline for (.{ total_co2_g_c, total_ch4_g_c, total_h2_g_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteSurfaceMetabolismStateUpdate;
    for (0..respiration.litter_complex_count) |complex| for (0..organic.residue_fraction_count) |component| {
        const residue_index = complex * organic.residue_fraction_count + component;
        residue_after[residue_index] = subtractPool(residue_after[residue_index], context.organic_decomposition.microbial_residue_decomposition[(cell * respiration.litter_complex_count + complex) * organic.residue_fraction_count + component]);
    };
    for (residue_after) |pool| try finitePool(pool);
    for (substrate_structural_after) |pool| try finitePool(pool);
    for (&colonized_structural_after, substrate_structural_after) |*value, substrate| {
        value.* = try nonnegativeCandidate(
            value.*,
            @max(@abs(value.*), @abs(substrate.carbon_g_c)),
            error.NonFiniteSurfaceMetabolismStateUpdate,
        );
        if (value.* > substrate.carbon_g_c) return error.NonFiniteSurfaceMetabolismStateUpdate;
    }
    for (adsorbed_after) |pool| try finitePool(pool);
    for (adsorbed_acetate_after) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteSurfaceMetabolismStateUpdate;
    for (topsoil_humus_after) |pool| try finitePool(pool);
    for (topsoil_humus_colonized_after) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteSurfaceMetabolismStateUpdate;
    try finitePool(topsoil_particulate_after);
    if (!std.math.isFinite(topsoil_particulate_colonized_after) or topsoil_particulate_colonized_after < 0) return error.NonFiniteSurfaceMetabolismStateUpdate;

    // Per-cell native-unit donor/recipient checks precede commit. These use
    // the independently reconstructed concentration loss, so band/non-band
    // weighting or g/mol mistakes cannot be hidden by another cell.
    try requireSignedStorageTransfer(
        ammonium_before_g_n,
        ammonium_after_g_n,
        total_ammonium_exchange_g_n,
        error.SurfaceAmmoniumTransferImbalance,
    );
    try requireSignedStorageTransfer(
        nitrate_before_g_n,
        nitrate_after_g_n,
        nitrate_reduction_g_n + total_nitrate_exchange_g_n,
        error.SurfaceNitrateTransferImbalance,
    );
    try requireSignedStorageTransfer(
        h2po4_before_g_p,
        h2po4_after_g_p,
        total_h2po4_exchange_g_p,
        error.SurfacePhosphateTransferImbalance,
    );
    try requireSignedStorageTransfer(
        hpo4_before_g_p,
        hpo4_after_g_p,
        total_hpo4_exchange_g_p,
        error.SurfacePhosphateTransferImbalance,
    );
    const top_ammonium_after_g_n = top_water_m3 * context.nitrogen_molar_mass_g_per_mol *
        (context.zone_fractions.ammonium_non_band * top_aqueous_after.ammonium_non_band +
            context.zone_fractions.ammonium_band * top_aqueous_after.ammonium_band);
    const top_nitrate_after_g_n = top_water_m3 * context.nitrogen_molar_mass_g_per_mol *
        (context.zone_fractions.nitrate_non_band * top_aqueous_after.nitrate_non_band +
            context.zone_fractions.nitrate_band * top_aqueous_after.nitrate_band);
    const top_h2po4_after_g_p = top_water_m3 * context.phosphorus_molar_mass_g_per_mol *
        (context.zone_fractions.phosphate_non_band * top_non_band_phosphate_after.dissolved_h2po4_mol_p_per_m3 +
            context.zone_fractions.phosphate_band * top_band_phosphate_after.dissolved_h2po4_mol_p_per_m3);
    const top_hpo4_after_g_p = top_water_m3 * context.phosphorus_molar_mass_g_per_mol *
        (context.zone_fractions.phosphate_non_band * top_non_band_phosphate_after.dissolved_hpo4_mol_p_per_m3 +
            context.zone_fractions.phosphate_band * top_band_phosphate_after.dissolved_hpo4_mol_p_per_m3);
    try requireSignedStorageTransfer(top_ammonium_available, top_ammonium_after_g_n, top_ammonium_g_n, error.TopsoilAmmoniumTransferImbalance);
    try requireSignedStorageTransfer(top_nitrate_available, top_nitrate_after_g_n, top_nitrate_g_n, error.TopsoilNitrateTransferImbalance);
    try requireSignedStorageTransfer(top_h2po4_available, top_h2po4_after_g_p, top_h2po4_g_p, error.TopsoilPhosphateTransferImbalance);
    try requireSignedStorageTransfer(top_hpo4_available, top_hpo4_after_g_p, top_hpo4_g_p, error.TopsoilPhosphateTransferImbalance);
    try requireInternalTransfer(
        total_h2_g_h,
        context.oxygen.respiration_hydrogen_g_h_per_step[cell],
        error.SurfaceHydrogenProductBindingImbalance,
    );

    // Surface NITRO fermentation is a true H2-H production term. Validate the
    // per-cell transfer before the first state mutation so equal-and-opposite
    // errors in different cells cannot cancel at the domain audit.
    const hydrogen_after_g_h = hydrogen_before_g_h + total_h2_g_h;
    const hydrogen_scale_g_h = @max(hydrogen_before_g_h, hydrogen_after_g_h);
    const hydrogen_closure = try scoped_conservation.evaluate(.{
        .storage_before = hydrogen_before_g_h,
        .storage_after = hydrogen_after_g_h,
        .internal_production = total_h2_g_h,
    }, .{
        .absolute = 64 * std.math.floatEps(f64) * hydrogen_scale_g_h,
        .relative = 16 * std.math.floatEps(f64),
    });
    if (!hydrogen_closure.accepted) return error.SurfaceHydrogenTransformationImbalance;

    const projected_carbon_after_g_c = try projectedCellCarbon_g_c(
        context.*,
        cell,
        dissolved_after,
        acetate_after,
        adsorbed_after,
        adsorbed_acetate_after,
        residue_after,
        substrate_structural_after,
        nonstructural_after,
        structural_after,
        topsoil_particulate_after,
        topsoil_humus_after,
        total_co2_g_c,
        total_ch4_g_c,
    );
    try requireProjectedClosure(
        conserved_carbon_before_g_c,
        projected_carbon_after_g_c,
        error.InvalidSurfaceCarbonConservationClosure,
    );
    const projected_nitrogen_after_g_n = try projectedCellNitrogen_g_n(
        context.*,
        cell,
        ammonium_after_g_n,
        nitrate_after_g_n,
        nitrite_after_g_n,
        n2o_after_g_n,
        n2_after_g_n,
        dissolved_after,
        adsorbed_after,
        residue_after,
        substrate_structural_after,
        nonstructural_after,
        structural_after,
        top_aqueous_after,
        topsoil_particulate_after,
        topsoil_humus_after,
    );
    try requireProjectedClosure(
        conserved_nitrogen_before_g_n,
        projected_nitrogen_after_g_n,
        error.InvalidSurfaceNitrogenConservationClosure,
    );
    const projected_phosphorus_after_g_p = try projectedCellPhosphorus_g_p(
        context.*,
        cell,
        h2po4_after_g_p,
        hpo4_after_g_p,
        dissolved_after,
        adsorbed_after,
        residue_after,
        substrate_structural_after,
        nonstructural_after,
        structural_after,
        top_non_band_phosphate_after,
        top_band_phosphate_after,
        topsoil_particulate_after,
        topsoil_humus_after,
    );
    try requireProjectedClosure(
        conserved_phosphorus_before_g_p,
        projected_phosphorus_after_g_p,
        error.InvalidSurfacePhosphorusConservationClosure,
    );

    // Stage every fallible concentration projection before the first state
    // write. In particular, mineralization in a dry cell with neither live
    // water nor a retained carrier must fail without leaving organic pools
    // partially committed.
    const nitrate_after_mol_per_m3 = try concentrationFromExtensiveAmount(nitrate_after_g_n, aqueous_carrier_m3, context.nitrogen_molar_mass_g_per_mol);
    const ammonium_after_mol_per_m3 = try concentrationFromExtensiveAmount(ammonium_after_g_n, aqueous_carrier_m3, context.nitrogen_molar_mass_g_per_mol);
    const h2po4_after_mol_p_per_m3 = try concentrationFromExtensiveAmount(h2po4_after_g_p, aqueous_carrier_m3, context.phosphorus_molar_mass_g_per_mol);
    const hpo4_after_mol_p_per_m3 = try concentrationFromExtensiveAmount(hpo4_after_g_p, aqueous_carrier_m3, context.phosphorus_molar_mass_g_per_mol);

    for (0..respiration.litter_complex_count) |complex| {
        const mobile = cell * organic.substrate_count + complex;
        context.surface_organic.dissolved[mobile] = dissolved_after[complex];
        context.surface_organic.dissolved_acetate_carbon_g_c[mobile] = acetate_after[complex];
        context.surface_organic.adsorbed[mobile] = adsorbed_after[complex];
        context.surface_organic.adsorbed_acetate_carbon_g_c[mobile] = adsorbed_acetate_after[complex];
        for (0..organic.structural_fraction_count) |fraction| {
            const local = complex * organic.structural_fraction_count + fraction;
            const surface_index = (cell * organic.substrate_count + complex) * organic.structural_fraction_count + fraction;
            context.surface_organic.structural[surface_index] = substrate_structural_after[local];
            context.surface_organic.colonized_structural_carbon_g_c[surface_index] = colonized_structural_after[local];
        }
        for (0..turnover.structural_component_count) |component| context.surface_organic.residue[(cell * organic.substrate_count + complex) * organic.residue_fraction_count + component] = residue_after[complex * turnover.structural_component_count + component];
        for (0..respiration.source_population_count) |population| {
            const unit_local = complex * respiration.source_population_count + population;
            const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count + 2;
            context.surface_organic.microbial[microbial] = nonstructural_after[unit_local];
            for (0..assimilation.structural_component_count) |component| context.surface_organic.microbial[microbial - 2 + component] = structural_after[(unit_local * assimilation.structural_component_count) + component];
        }
    }
    context.litter_chemistry.cells[cell].nitrate_mol_per_m3 = nitrate_after_mol_per_m3;
    context.litter_chemistry.cells[cell].ammonium_mol_per_m3 = ammonium_after_mol_per_m3;
    context.litter_chemistry.cells[cell].h2po4_mol_p_per_m3 = h2po4_after_mol_p_per_m3;
    context.litter_chemistry.cells[cell].hpo4_mol_p_per_m3 = hpo4_after_mol_p_per_m3;
    context.denitrification.nitrite_g_n[cell] = nitrite_after_g_n;
    context.litter_gas.dissolved_mass_g[n2o_index] = n2o_after_g_n;
    context.litter_gas.dissolved_mass_g[n2_index] = n2_after_g_n;
    context.topsoil_chemistry.aqueous[top] = top_aqueous_after;
    context.topsoil_chemistry.non_band_phosphate[top] = top_non_band_phosphate_after;
    context.topsoil_chemistry.band_phosphate[top] = top_band_phosphate_after;
    for (0..2) |humus_class| {
        const humus_index = (top_organic_layer * organic.substrate_count + 4) * organic.structural_fraction_count + humus_class;
        context.topsoil_organic.structural[humus_index] = topsoil_humus_after[humus_class];
        context.topsoil_organic.colonized_structural_carbon_g_c[humus_index] = topsoil_humus_colonized_after[humus_class];
    }
    context.topsoil_organic.structural[topsoil_particulate_index] = topsoil_particulate_after;
    context.topsoil_organic.colonized_structural_carbon_g_c[topsoil_particulate_index] = topsoil_particulate_colonized_after;
    context.litter_gas.dissolved_mass_g[cell * gas.species_count + @intFromEnum(gas.Species.carbon_dioxide)] += total_co2_g_c;
    context.litter_gas.dissolved_mass_g[cell * gas.species_count + @intFromEnum(gas.Species.methane)] += total_ch4_g_c;
    if (context.hourly_signed_heterotrophic_respiration_g_c) |ledger|
        ledger[cell] = -(total_co2_g_c + total_ch4_g_c);
    if (context.hourly_carbon_dioxide_production_g_c) |ledger|
        ledger[cell] = total_co2_g_c;
    context.litter_gas.dissolved_mass_g[hydrogen_index] = hydrogen_after_g_h;
}

fn requireInternalTransfer(donor_loss: f64, recipient_gain: f64, comptime failure: anyerror) !void {
    const scale = @max(@abs(donor_loss), @abs(recipient_gain));
    const closure = scoped_conservation.evaluateTransfer(
        donor_loss,
        recipient_gain,
        1,
        .{
            .absolute = 128 * std.math.floatEps(f64) * scale,
            .relative = 32 * std.math.floatEps(f64),
        },
    ) catch return failure;
    if (!closure.accepted) return failure;
}

/// Validates a signed mineral exchange against its aqueous storage owner.
/// Positive exchange is immobilization (aqueous consumption); negative
/// exchange is mineralization (aqueous production). The physical tolerance is
/// scaled only to interval activity, while `evaluate` separately accounts for
/// binary64 subtraction roundoff from the standing before/after storage.
fn requireSignedStorageTransfer(
    storage_before: f64,
    storage_after: f64,
    signed_exchange: f64,
    comptime failure: anyerror,
) !void {
    const activity_scale = @abs(signed_exchange);
    const closure = scoped_conservation.evaluate(.{
        .storage_before = storage_before,
        .storage_after = storage_after,
        .internal_production = if (signed_exchange < 0) -signed_exchange else 0,
        .internal_consumption = if (signed_exchange > 0) signed_exchange else 0,
    }, .{
        .absolute = 128 * std.math.floatEps(f64) * @max(std.math.floatMin(f64), activity_scale),
        .relative = 32 * std.math.floatEps(f64),
    }) catch return failure;
    if (!closure.accepted) return failure;
}

/// `solute.f:610`-style `ZEROS2` floor (issue-060/issue-061): substitutes the
/// remembered `dry_reference_water_m3` once `live_water_m3` falls at or below
/// the legacy negligible-water floor, not only when it is exactly zero.
fn effectiveAqueousCarrierM3(live_water_m3: f64, dry_reference_water_m3: f64, negligible_water_volume_m3: f64) f64 {
    return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
}

/// `ZEROS2` scaled to one cell's actual horizontal footprint, for this file's
/// `effectiveAqueousCarrierM3` callers.
fn negligibleLitterWaterVolumeM3(cell_area_m2: f64) f64 {
    return legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(cell_area_m2);
}

fn concentrationFromExtensiveAmount(amount_g: f64, carrier_m3: f64, molar_mass_g_per_mol: f64) !f64 {
    if (!std.math.isFinite(amount_g) or amount_g < 0 or
        !std.math.isFinite(carrier_m3) or carrier_m3 < 0 or
        !std.math.isFinite(molar_mass_g_per_mol) or molar_mass_g_per_mol <= 0)
        return error.InvalidSurfaceAqueousInventory;
    if (carrier_m3 > 0) return amount_g / (carrier_m3 * molar_mass_g_per_mol);
    if (amount_g == 0) return 0;
    // Never hide an unrepresented amount by converting it to a zero
    // concentration.  A dry cell with retained mass must own a positive
    // `dry_reference_water_m3`; no-carrier mass is a binding/accounting defect.
    return error.SurfaceAqueousMassWithoutCarrier;
}

fn nonnegativeCandidate(value: f64, operation_scale: f64, comptime failure: anyerror) !f64 {
    if (!std.math.isFinite(value) or !std.math.isFinite(operation_scale) or operation_scale < 0)
        return failure;
    if (value < 0) return failure;
    return value;
}

fn projectedCellCarbon_g_c(
    context: ApplyContext,
    cell: usize,
    dissolved_after: [respiration.litter_complex_count]organic.ElementPool,
    acetate_after: [respiration.litter_complex_count]f64,
    adsorbed_after: [respiration.litter_complex_count]organic.ElementPool,
    adsorbed_acetate_after: [respiration.litter_complex_count]f64,
    residue_after: [respiration.litter_complex_count * turnover.structural_component_count]organic.ElementPool,
    substrate_structural_after: [respiration.litter_complex_count * organic.structural_fraction_count]organic.ElementPool,
    nonstructural_after: [respiration.unit_count_per_cell]organic.ElementPool,
    structural_after: [respiration.unit_count_per_cell * assimilation.structural_component_count]organic.ElementPool,
    topsoil_particulate_after: organic.ElementPool,
    topsoil_humus_after: [2]organic.ElementPool,
    carbon_dioxide_production_g_c: f64,
    methane_production_g_c: f64,
) !f64 {
    var total: f64 = 0;
    const mobile_first = cell * organic.substrate_count;
    for (0..organic.substrate_count) |substrate| {
        if (substrate < respiration.litter_complex_count) {
            total += dissolved_after[substrate].carbon_g_c + acetate_after[substrate];
            total += adsorbed_after[substrate].carbon_g_c + adsorbed_acetate_after[substrate];
        } else {
            total += context.surface_organic.dissolved[mobile_first + substrate].carbon_g_c + context.surface_organic.dissolved_acetate_carbon_g_c[mobile_first + substrate];
            total += context.surface_organic.adsorbed[mobile_first + substrate].carbon_g_c + context.surface_organic.adsorbed_acetate_carbon_g_c[mobile_first + substrate];
        }
    }
    const residue_first = cell * organic.substrate_count * organic.residue_fraction_count;
    for (0..organic.substrate_count) |substrate|
        for (0..organic.residue_fraction_count) |fraction| {
            total += if (substrate < respiration.litter_complex_count)
                residue_after[substrate * organic.residue_fraction_count + fraction].carbon_g_c
            else
                context.surface_organic.residue[residue_first + substrate * organic.residue_fraction_count + fraction].carbon_g_c;
        };
    const surface_structural_first = cell * organic.substrate_count * organic.structural_fraction_count;
    for (0..organic.substrate_count) |substrate|
        for (0..organic.structural_fraction_count) |fraction| {
            total += if (substrate < respiration.litter_complex_count)
                substrate_structural_after[substrate * organic.structural_fraction_count + fraction].carbon_g_c
            else
                context.surface_organic.structural[surface_structural_first + substrate * organic.structural_fraction_count + fraction].carbon_g_c;
        };
    for (0..organic.microbial_substrate_count) |substrate|
        for (0..organic.microbial_population_count) |population|
            for (0..organic.kinetic_fraction_count) |fraction| {
                if (substrate < respiration.litter_complex_count) {
                    const unit_local = substrate * respiration.source_population_count + population;
                    total += if (fraction < assimilation.structural_component_count)
                        structural_after[unit_local * assimilation.structural_component_count + fraction].carbon_g_c
                    else
                        nonstructural_after[unit_local].carbon_g_c;
                } else {
                    const index = ((cell * organic.microbial_substrate_count + substrate) * organic.microbial_population_count + population) * organic.kinetic_fraction_count + fraction;
                    total += context.surface_organic.microbial[index].carbon_g_c;
                }
            };
    inline for ([_]gas.Species{ .carbon_dioxide, .methane }) |species| {
        const index = cell * gas.species_count + @intFromEnum(species);
        total += context.litter_gas.gaseous_mass_g[index];
        total += context.litter_gas.dissolved_mass_g[index] + if (species == .carbon_dioxide) carbon_dioxide_production_g_c else methane_production_g_c;
        total += context.litter_gas.macropore_dissolved_mass_g[index] + context.litter_gas.band_dissolved_mass_g[index];
    }
    total += topsoil_particulate_after.carbon_g_c + topsoil_humus_after[0].carbon_g_c + topsoil_humus_after[1].carbon_g_c;
    if (!std.math.isFinite(total)) return error.NonFiniteSurfaceCarbonConservationCensus;
    return total;
}

fn projectedCellNitrogen_g_n(
    context: ApplyContext,
    cell: usize,
    ammonium_after_g_n: f64,
    nitrate_after_g_n: f64,
    nitrite_after_g_n: f64,
    nitrous_oxide_after_g_n: f64,
    dinitrogen_after_g_n: f64,
    dissolved_after: [respiration.litter_complex_count]organic.ElementPool,
    adsorbed_after: [respiration.litter_complex_count]organic.ElementPool,
    residue_after: [respiration.litter_complex_count * turnover.structural_component_count]organic.ElementPool,
    substrate_structural_after: [respiration.litter_complex_count * organic.structural_fraction_count]organic.ElementPool,
    nonstructural_after: [respiration.unit_count_per_cell]organic.ElementPool,
    structural_after: [respiration.unit_count_per_cell * assimilation.structural_component_count]organic.ElementPool,
    top_aqueous_after: aqueous_network.State,
    topsoil_particulate_after: organic.ElementPool,
    topsoil_humus_after: [2]organic.ElementPool,
) !f64 {
    const water_m3 = context.litter_water_m3[cell];
    const aqueous_carrier = effectiveAqueousCarrierM3(
        water_m3,
        context.litter_chemistry.dry_reference_water_m3[cell],
        negligibleLitterWaterVolumeM3(context.cell_area_m2[cell]),
    );
    var total = ammonium_after_g_n + nitrate_after_g_n + nitrite_after_g_n +
        aqueous_carrier * context.nitrogen_molar_mass_g_per_mol *
            context.litter_chemistry.cells[cell].ammonia_mol_per_m3;
    const mobile_first = cell * organic.substrate_count;
    for (0..organic.substrate_count) |substrate| {
        if (substrate < respiration.litter_complex_count) {
            total += dissolved_after[substrate].nitrogen_g_n;
            total += adsorbed_after[substrate].nitrogen_g_n;
        } else {
            total += context.surface_organic.dissolved[mobile_first + substrate].nitrogen_g_n;
            total += context.surface_organic.adsorbed[mobile_first + substrate].nitrogen_g_n;
        }
    }
    const residue_first = cell * organic.substrate_count * organic.residue_fraction_count;
    for (0..organic.substrate_count) |substrate|
        for (0..organic.residue_fraction_count) |fraction| {
            if (substrate < respiration.litter_complex_count)
                total += residue_after[substrate * organic.residue_fraction_count + fraction].nitrogen_g_n
            else
                total += context.surface_organic.residue[residue_first + substrate * organic.residue_fraction_count + fraction].nitrogen_g_n;
        };
    const surface_structural_first = cell * organic.substrate_count * organic.structural_fraction_count;
    for (0..organic.substrate_count) |substrate|
        for (0..organic.structural_fraction_count) |fraction| {
            if (substrate < respiration.litter_complex_count)
                total += substrate_structural_after[substrate * organic.structural_fraction_count + fraction].nitrogen_g_n
            else
                total += context.surface_organic.structural[surface_structural_first + substrate * organic.structural_fraction_count + fraction].nitrogen_g_n;
        };
    for (0..organic.microbial_substrate_count) |substrate|
        for (0..organic.microbial_population_count) |population|
            for (0..organic.kinetic_fraction_count) |fraction| {
                if (substrate < respiration.litter_complex_count) {
                    const unit_local = substrate * respiration.source_population_count + population;
                    total += if (fraction < assimilation.structural_component_count)
                        structural_after[unit_local * assimilation.structural_component_count + fraction].nitrogen_g_n
                    else
                        nonstructural_after[unit_local].nitrogen_g_n;
                } else {
                    const index = ((cell * organic.microbial_substrate_count + substrate) * organic.microbial_population_count + population) * organic.kinetic_fraction_count + fraction;
                    total += context.surface_organic.microbial[index].nitrogen_g_n;
                }
            };
    inline for ([_]gas.Species{ .nitrogen, .nitrous_oxide }) |species| {
        const index = cell * gas.species_count + @intFromEnum(species);
        total += context.litter_gas.gaseous_mass_g[index];
        total += switch (species) {
            .nitrogen => dinitrogen_after_g_n,
            .nitrous_oxide => nitrous_oxide_after_g_n,
            else => unreachable,
        };
        total += context.litter_gas.macropore_dissolved_mass_g[index] +
            context.litter_gas.band_dissolved_mass_g[index];
    }
    total += context.litter_gas.gaseous_mass_g[
        cell * gas.species_count + @intFromEnum(gas.Species.ammonia)
    ];
    const top = try context.model_grid.layerIndex(cell, 0);
    const top_water_m3 = context.model_grid.matrix_liquid_water_m3[top];
    total += top_water_m3 * context.nitrogen_molar_mass_g_per_mol *
        (top_aqueous_after.ammonium_non_band * context.zone_fractions.ammonium_non_band +
            top_aqueous_after.ammonium_band * context.zone_fractions.ammonium_band +
            top_aqueous_after.nitrate_non_band * context.zone_fractions.nitrate_non_band +
            top_aqueous_after.nitrate_band * context.zone_fractions.nitrate_band);
    total += topsoil_particulate_after.nitrogen_g_n;
    total += topsoil_humus_after[0].nitrogen_g_n + topsoil_humus_after[1].nitrogen_g_n;
    if (!std.math.isFinite(total)) return error.NonFiniteSurfaceNitrogenConservationCensus;
    return total;
}

fn projectedCellPhosphorus_g_p(
    context: ApplyContext,
    cell: usize,
    h2po4_after_g_p: f64,
    hpo4_after_g_p: f64,
    dissolved_after: [respiration.litter_complex_count]organic.ElementPool,
    adsorbed_after: [respiration.litter_complex_count]organic.ElementPool,
    residue_after: [respiration.litter_complex_count * turnover.structural_component_count]organic.ElementPool,
    substrate_structural_after: [respiration.litter_complex_count * organic.structural_fraction_count]organic.ElementPool,
    nonstructural_after: [respiration.unit_count_per_cell]organic.ElementPool,
    structural_after: [respiration.unit_count_per_cell * assimilation.structural_component_count]organic.ElementPool,
    top_non_band_phosphate_after: anytype,
    top_band_phosphate_after: anytype,
    topsoil_particulate_after: organic.ElementPool,
    topsoil_humus_after: [2]organic.ElementPool,
) !f64 {
    var total = h2po4_after_g_p + hpo4_after_g_p;
    const mobile_first = cell * organic.substrate_count;
    for (0..organic.substrate_count) |substrate| {
        if (substrate < respiration.litter_complex_count) {
            total += dissolved_after[substrate].phosphorus_g_p + adsorbed_after[substrate].phosphorus_g_p;
        } else {
            total += context.surface_organic.dissolved[mobile_first + substrate].phosphorus_g_p + context.surface_organic.adsorbed[mobile_first + substrate].phosphorus_g_p;
        }
    }
    const residue_first = cell * organic.substrate_count * organic.residue_fraction_count;
    for (0..organic.substrate_count) |substrate|
        for (0..organic.residue_fraction_count) |fraction| {
            total += if (substrate < respiration.litter_complex_count)
                residue_after[substrate * organic.residue_fraction_count + fraction].phosphorus_g_p
            else
                context.surface_organic.residue[residue_first + substrate * organic.residue_fraction_count + fraction].phosphorus_g_p;
        };
    const surface_structural_first = cell * organic.substrate_count * organic.structural_fraction_count;
    for (0..organic.substrate_count) |substrate|
        for (0..organic.structural_fraction_count) |fraction| {
            total += if (substrate < respiration.litter_complex_count)
                substrate_structural_after[substrate * organic.structural_fraction_count + fraction].phosphorus_g_p
            else
                context.surface_organic.structural[surface_structural_first + substrate * organic.structural_fraction_count + fraction].phosphorus_g_p;
        };
    for (0..organic.microbial_substrate_count) |substrate|
        for (0..organic.microbial_population_count) |population|
            for (0..organic.kinetic_fraction_count) |fraction| {
                if (substrate < respiration.litter_complex_count) {
                    const unit_local = substrate * respiration.source_population_count + population;
                    total += if (fraction < assimilation.structural_component_count)
                        structural_after[unit_local * assimilation.structural_component_count + fraction].phosphorus_g_p
                    else
                        nonstructural_after[unit_local].phosphorus_g_p;
                } else {
                    const index = ((cell * organic.microbial_substrate_count + substrate) * organic.microbial_population_count + population) * organic.kinetic_fraction_count + fraction;
                    total += context.surface_organic.microbial[index].phosphorus_g_p;
                }
            };
    const top = try context.model_grid.layerIndex(cell, 0);
    const top_water_m3 = context.model_grid.matrix_liquid_water_m3[top];
    total += top_water_m3 * context.phosphorus_molar_mass_g_per_mol *
        (context.zone_fractions.phosphate_non_band *
            (top_non_band_phosphate_after.dissolved_h2po4_mol_p_per_m3 + top_non_band_phosphate_after.dissolved_hpo4_mol_p_per_m3) +
            context.zone_fractions.phosphate_band *
                (top_band_phosphate_after.dissolved_h2po4_mol_p_per_m3 + top_band_phosphate_after.dissolved_hpo4_mol_p_per_m3));
    total += topsoil_particulate_after.phosphorus_g_p + topsoil_humus_after[0].phosphorus_g_p + topsoil_humus_after[1].phosphorus_g_p;
    if (!std.math.isFinite(total)) return error.NonFiniteSurfacePhosphorusConservationCensus;
    return total;
}

fn requireProjectedClosure(before: f64, after: f64, comptime failure: anyerror) !void {
    const scale = @max(@abs(before), @abs(after));
    const closure = scoped_conservation.evaluate(.{
        .storage_before = before,
        .storage_after = after,
    }, .{
        .absolute = 64 * std.math.floatEps(f64) * @max(std.math.floatMin(f64), scale),
        .relative = 32 * std.math.floatEps(f64),
    }) catch return failure;
    if (!closure.accepted) return failure;
}

fn authoritativeCellCarbon_g_c(context: ApplyContext, cell: usize) !f64 {
    var total = try context.surface_organic.totalCarbon_g_c(cell);
    inline for ([_]gas.Species{ .carbon_dioxide, .methane }) |species| {
        const index = cell * gas.species_count + @intFromEnum(species);
        total += context.litter_gas.gaseous_mass_g[index] + context.litter_gas.dissolved_mass_g[index] +
            context.litter_gas.macropore_dissolved_mass_g[index] + context.litter_gas.band_dissolved_mass_g[index];
    }
    const top = try context.model_grid.layerIndex(cell, 0);
    const particulate = (top * organic.substrate_count + 3) * organic.structural_fraction_count;
    total += context.topsoil_organic.structural[particulate].carbon_g_c;
    const humus = (top * organic.substrate_count + 4) * organic.structural_fraction_count;
    total += context.topsoil_organic.structural[humus].carbon_g_c + context.topsoil_organic.structural[humus + 1].carbon_g_c;
    if (!std.math.isFinite(total)) return error.NonFiniteSurfaceCarbonConservationCensus;
    return total;
}

fn authoritativeCellNitrogen_g_n(context: ApplyContext, cell: usize) !f64 {
    var total: f64 = context.denitrification.nitrite_g_n[cell];
    const water_m3 = context.litter_water_m3[cell];
    const aqueous_carrier = effectiveAqueousCarrierM3(
        water_m3,
        context.litter_chemistry.dry_reference_water_m3[cell],
        negligibleLitterWaterVolumeM3(context.cell_area_m2[cell]),
    );
    total += aqueous_carrier * context.nitrogen_molar_mass_g_per_mol *
        (context.litter_chemistry.cells[cell].ammonium_mol_per_m3 +
            context.litter_chemistry.cells[cell].ammonia_mol_per_m3 +
            context.litter_chemistry.cells[cell].nitrate_mol_per_m3);
    const mobile_first = cell * organic.substrate_count;
    for (context.surface_organic.dissolved[mobile_first..][0..organic.substrate_count]) |pool| total += pool.nitrogen_g_n;
    for (context.surface_organic.adsorbed[mobile_first..][0..organic.substrate_count]) |pool| total += pool.nitrogen_g_n;
    const residue_first = cell * organic.substrate_count * organic.residue_fraction_count;
    for (context.surface_organic.residue[residue_first..][0 .. organic.substrate_count * organic.residue_fraction_count]) |pool| total += pool.nitrogen_g_n;
    const structural_first = cell * organic.substrate_count * organic.structural_fraction_count;
    for (context.surface_organic.structural[structural_first..][0 .. organic.substrate_count * organic.structural_fraction_count]) |pool| total += pool.nitrogen_g_n;
    const microbial_first = cell * organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    const microbial_count = organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    for (context.surface_organic.microbial[microbial_first..][0..microbial_count]) |pool| total += pool.nitrogen_g_n;
    inline for ([_]gas.Species{ .nitrogen, .nitrous_oxide }) |species| {
        const index = cell * gas.species_count + @intFromEnum(species);
        total += context.litter_gas.gaseous_mass_g[index] + context.litter_gas.dissolved_mass_g[index] +
            context.litter_gas.macropore_dissolved_mass_g[index] + context.litter_gas.band_dissolved_mass_g[index];
    }
    total += context.litter_gas.gaseous_mass_g[
        cell * gas.species_count + @intFromEnum(gas.Species.ammonia)
    ];
    const top = try context.model_grid.layerIndex(cell, 0);
    const top_water_m3 = context.model_grid.matrix_liquid_water_m3[top];
    const aqueous = context.topsoil_chemistry.aqueous[top];
    total += top_water_m3 * context.nitrogen_molar_mass_g_per_mol *
        (aqueous.ammonium_non_band * context.zone_fractions.ammonium_non_band +
            aqueous.ammonium_band * context.zone_fractions.ammonium_band +
            aqueous.nitrate_non_band * context.zone_fractions.nitrate_non_band +
            aqueous.nitrate_band * context.zone_fractions.nitrate_band);
    const particulate = (top * organic.substrate_count + 3) * organic.structural_fraction_count;
    total += context.topsoil_organic.structural[particulate].nitrogen_g_n;
    const humus = (top * organic.substrate_count + 4) * organic.structural_fraction_count;
    total += context.topsoil_organic.structural[humus].nitrogen_g_n +
        context.topsoil_organic.structural[humus + 1].nitrogen_g_n;
    if (!std.math.isFinite(total)) return error.NonFiniteSurfaceNitrogenConservationCensus;
    return total;
}

fn authoritativeCellPhosphorus_g_p(context: ApplyContext, cell: usize) !f64 {
    const water_m3 = context.litter_water_m3[cell];
    const aqueous_carrier = effectiveAqueousCarrierM3(
        water_m3,
        context.litter_chemistry.dry_reference_water_m3[cell],
        negligibleLitterWaterVolumeM3(context.cell_area_m2[cell]),
    );
    var total = aqueous_carrier * context.phosphorus_molar_mass_g_per_mol *
        (context.litter_chemistry.cells[cell].h2po4_mol_p_per_m3 + context.litter_chemistry.cells[cell].hpo4_mol_p_per_m3);
    const mobile_first = cell * organic.substrate_count;
    for (context.surface_organic.dissolved[mobile_first..][0..organic.substrate_count]) |pool| total += pool.phosphorus_g_p;
    for (context.surface_organic.adsorbed[mobile_first..][0..organic.substrate_count]) |pool| total += pool.phosphorus_g_p;
    const residue_first = cell * organic.substrate_count * organic.residue_fraction_count;
    for (context.surface_organic.residue[residue_first..][0 .. organic.substrate_count * organic.residue_fraction_count]) |pool| total += pool.phosphorus_g_p;
    const structural_first = cell * organic.substrate_count * organic.structural_fraction_count;
    for (context.surface_organic.structural[structural_first..][0 .. organic.substrate_count * organic.structural_fraction_count]) |pool| total += pool.phosphorus_g_p;
    const microbial_first = cell * organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    const microbial_count = organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    for (context.surface_organic.microbial[microbial_first..][0..microbial_count]) |pool| total += pool.phosphorus_g_p;
    const top = try context.model_grid.layerIndex(cell, 0);
    const top_water_m3 = context.model_grid.matrix_liquid_water_m3[top];
    const non_band = context.topsoil_chemistry.non_band_phosphate[top];
    const band = context.topsoil_chemistry.band_phosphate[top];
    total += top_water_m3 * context.phosphorus_molar_mass_g_per_mol *
        (context.zone_fractions.phosphate_non_band *
            (non_band.dissolved_h2po4_mol_p_per_m3 + non_band.dissolved_hpo4_mol_p_per_m3) +
            context.zone_fractions.phosphate_band *
                (band.dissolved_h2po4_mol_p_per_m3 + band.dissolved_hpo4_mol_p_per_m3));
    const particulate = (top * organic.substrate_count + 3) * organic.structural_fraction_count;
    total += context.topsoil_organic.structural[particulate].phosphorus_g_p;
    const humus = (top * organic.substrate_count + 4) * organic.structural_fraction_count;
    total += context.topsoil_organic.structural[humus].phosphorus_g_p + context.topsoil_organic.structural[humus + 1].phosphorus_g_p;
    if (!std.math.isFinite(total)) return error.NonFiniteSurfacePhosphorusConservationCensus;
    return total;
}

test "dry litter metabolism carrier preserves retained aqueous N and P" {
    const dry_reference_m3: f64 = 2.5;
    const nitrogen_g_per_mol: f64 = 14;
    const phosphorus_g_per_mol: f64 = 31;
    const ammonium_mol_per_m3: f64 = 3;
    const phosphate_mol_per_m3: f64 = 0.4;

    const test_negligible_water_volume_m3 = negligibleLitterWaterVolumeM3(1);
    const carrier = effectiveAqueousCarrierM3(0, dry_reference_m3, test_negligible_water_volume_m3);
    const ammonium_g_n = ammonium_mol_per_m3 * carrier * nitrogen_g_per_mol;
    const phosphate_g_p = phosphate_mol_per_m3 * carrier * phosphorus_g_per_mol;

    try std.testing.expectEqual(dry_reference_m3, carrier);
    try std.testing.expectEqual(
        ammonium_mol_per_m3,
        try concentrationFromExtensiveAmount(ammonium_g_n, carrier, nitrogen_g_per_mol),
    );
    try std.testing.expectEqual(
        phosphate_mol_per_m3,
        try concentrationFromExtensiveAmount(phosphate_g_p, carrier, phosphorus_g_per_mol),
    );
    // A genuinely empty dry cell remains canonically zero; no artificial
    // carrier or concentration floor is introduced.
    try std.testing.expectEqual(@as(f64, 0), effectiveAqueousCarrierM3(0, 0, test_negligible_water_volume_m3));
    try std.testing.expectEqual(@as(f64, 0), try concentrationFromExtensiveAmount(0, 0, nitrogen_g_per_mol));
    try std.testing.expectError(
        error.SurfaceAqueousMassWithoutCarrier,
        concentrationFromExtensiveAmount(1, 0, nitrogen_g_per_mol),
    );
}

test "issue-061: BEFORE -- the old exact-zero guard used a collapsed-but-nonzero carrier instead of the remembered dry reference" {
    // Literal reproduction of the old guard this issue replaced:
    // `if (live_water_m3 > 0) live_water_m3 else dry_reference_water_m3`.
    const oldEffectiveAqueousCarrierM3 = struct {
        fn call(live_water_m3: f64, dry_reference_water_m3: f64) f64 {
            return if (live_water_m3 > 0) live_water_m3 else dry_reference_water_m3;
        }
    }.call;

    const dry_reference_m3: f64 = 2.5;
    const ammonium_mol_per_m3: f64 = 3;
    const nitrogen_g_per_mol: f64 = 14;
    // Below the Ottawa deck's ZEROS2 floor (1.0e-6 m3 for a 1 m2 cell), but
    // not exactly zero -- the same collapsed-but-nonzero regime issue-060
    // diagnosed for `matrix_liquid_water_m3`, here on the surface-metabolism
    // aqueous carrier.
    const collapsed_water_m3: f64 = 1e-9;

    const old_carrier = oldEffectiveAqueousCarrierM3(collapsed_water_m3, dry_reference_m3);
    try std.testing.expectEqual(collapsed_water_m3, old_carrier);
    const old_ammonium_g_n = ammonium_mol_per_m3 * old_carrier * nitrogen_g_per_mol;
    const correct_ammonium_g_n = ammonium_mol_per_m3 * dry_reference_m3 * nitrogen_g_per_mol;
    // The old guard's collapsed-carrier result is a >99.99% fake loss
    // relative to the correct (dry-reference) mass, the same shape as
    // issue-060's own hour-2,894 evidence.
    const fake_relative_loss = (correct_ammonium_g_n - old_ammonium_g_n) / correct_ammonium_g_n;
    try std.testing.expect(fake_relative_loss > 0.9999);
}

test "issue-061: AFTER -- the ZEROS2-floored guard substitutes the remembered dry reference instead of the collapsed carrier" {
    const dry_reference_m3: f64 = 2.5;
    const ammonium_mol_per_m3: f64 = 3;
    const nitrogen_g_per_mol: f64 = 14;
    const collapsed_water_m3: f64 = 1e-9; // Below the 1.0e-6 m3 floor.
    const negligible_water_volume_m3 = negligibleLitterWaterVolumeM3(1);

    const carrier = effectiveAqueousCarrierM3(collapsed_water_m3, dry_reference_m3, negligible_water_volume_m3);
    try std.testing.expectEqual(dry_reference_m3, carrier);
    try std.testing.expectEqual(
        ammonium_mol_per_m3 * dry_reference_m3 * nitrogen_g_per_mol,
        ammonium_mol_per_m3 * carrier * nitrogen_g_per_mol,
    );
}

test "issue-061: the surface-metabolism floored guard's boundary matches legacy's GT (not GE) comparison and preserves the exact-zero case" {
    const dry_reference_m3: f64 = 2.5;
    const negligible_water_volume_m3 = negligibleLitterWaterVolumeM3(1);

    // Exactly at the floor takes the dry-reference branch.
    try std.testing.expectEqual(
        dry_reference_m3,
        effectiveAqueousCarrierM3(negligible_water_volume_m3, dry_reference_m3, negligible_water_volume_m3),
    );
    // One ULP above the floor is treated as present water.
    const just_above = std.math.nextAfter(f64, negligible_water_volume_m3, std.math.inf(f64));
    try std.testing.expectEqual(
        just_above,
        effectiveAqueousCarrierM3(just_above, dry_reference_m3, negligible_water_volume_m3),
    );
    // The pre-existing exact-zero case is unchanged.
    try std.testing.expectEqual(
        dry_reference_m3,
        effectiveAqueousCarrierM3(0, dry_reference_m3, negligible_water_volume_m3),
    );
    // An ordinary, comfortably wet cell is unaffected by the floor.
    try std.testing.expectEqual(
        @as(f64, 0.05),
        effectiveAqueousCarrierM3(0.05, dry_reference_m3, negligible_water_volume_m3),
    );
}

test "signed surface mineral transfer accepts immobilization and mineralization" {
    try requireSignedStorageTransfer(10, 8, 2, error.TestTransferImbalance);
    try requireSignedStorageTransfer(8, 10, -2, error.TestTransferImbalance);
    // The physical limit remains activity-scaled, but an unrepresentably
    // small transfer from a large standing pool is bounded as binary64
    // storage arithmetic rather than misreported as a conservation defect.
    const standing: f64 = 1.0e6;
    const tiny_exchange: f64 = 1.0e-10;
    try requireSignedStorageTransfer(
        standing,
        standing - tiny_exchange,
        tiny_exchange,
        error.TestTransferImbalance,
    );
    try std.testing.expectError(
        error.TestTransferImbalance,
        requireSignedStorageTransfer(8, 9.5, -2, error.TestTransferImbalance),
    );
}

fn finitePool(pool: organic.ElementPool) !void {
    inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| if (!std.math.isFinite(@field(pool, field.name)) or @field(pool, field.name) < 0) return error.NonFiniteSurfaceMetabolismStateUpdate;
}

fn addPool(a: organic.ElementPool, b: organic.ElementPool) organic.ElementPool {
    return .{ .carbon_g_c = a.carbon_g_c + b.carbon_g_c, .nitrogen_g_n = a.nitrogen_g_n + b.nitrogen_g_n, .phosphorus_g_p = a.phosphorus_g_p + b.phosphorus_g_p };
}

fn scalePool(pool: organic.ElementPool, fraction: f64) organic.ElementPool {
    return .{ .carbon_g_c = pool.carbon_g_c * fraction, .nitrogen_g_n = pool.nitrogen_g_n * fraction, .phosphorus_g_p = pool.phosphorus_g_p * fraction };
}

fn subtractPool(a: organic.ElementPool, b: organic.ElementPool) organic.ElementPool {
    return .{ .carbon_g_c = a.carbon_g_c - b.carbon_g_c, .nitrogen_g_n = a.nitrogen_g_n - b.nitrogen_g_n, .phosphorus_g_p = a.phosphorus_g_p - b.phosphorus_g_p };
}

fn fromMetabolic(pool: metabolism.ElementalPool) organic.ElementPool {
    return .{ .carbon_g_c = pool.carbon_g_c, .nitrogen_g_n = pool.nitrogen_g_n, .phosphorus_g_p = pool.phosphorus_g_p };
}

/// Limits a simultaneously evaluated adsorption/desorption flux to the
/// inventory remaining after the other hourly source and sink terms.
fn boundedExchange(proposed: f64, dissolved_available: f64, sorbed_available: f64) f64 {
    if (proposed >= 0) return @min(proposed, @max(0, dissolved_available));
    return @max(proposed, -@max(0, sorbed_available));
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    if (context.hourly_signed_heterotrophic_respiration_g_c) |ledger| if (ledger.len != context.model_grid.cell_count) return error.HeterotrophicRespirationLedgerDimensionMismatch;
    if (context.hourly_carbon_dioxide_production_g_c) |ledger| if (ledger.len != context.model_grid.cell_count) return error.CarbonDioxideProductionLedgerDimensionMismatch;
    const cells = context.surface_organic.layer_count;
    if (range.first > range.end or range.end > cells or context.litter_chemistry.cells.len != cells or context.litter_chemistry.dry_reference_water_m3.len != cells or context.litter_gas.cell_count != cells or context.litter_water_m3.len != cells or context.cell_area_m2.len != cells or context.respiration.cell_count != cells or context.oxygen.cell_count != cells or context.nitrogen_fixation.cell_count != cells or context.substrate_uptake.cell_count != cells or context.denitrification.cell_count != cells or context.assimilation.cell_count != cells or context.mineral_exchange.cell_count != cells or context.topsoil_exchange.cell_count != cells or context.turnover.cell_count != cells or context.priming.cellCount() != cells or context.organic_decomposition.cell_count != cells or context.organic_sorption.cell_count != cells or context.litter_colonization.cell_count != cells or context.topsoil_humus_partition.len != cells or context.model_grid.cell_count != cells or context.topsoil_chemistry.cell_count != context.model_grid.layer_count or context.topsoil_organic.layer_count != context.model_grid.layer_count or (context.zone_fractions_by_layer.len != 0 and context.zone_fractions_by_layer.len != context.model_grid.layer_count)) return error.SurfaceMetabolismStateUpdateDimensionMismatch;
    for (context.topsoil_humus_partition) |partition| if (!std.math.isFinite(partition[0]) or !std.math.isFinite(partition[1]) or partition[0] < 0 or partition[1] < 0 or @abs(partition[0] + partition[1] - 1) > context.fraction_tolerance) return error.InvalidSurfaceMetabolismStateUpdateParameter;
    if (!std.math.isFinite(context.nitrogen_molar_mass_g_per_mol) or context.nitrogen_molar_mass_g_per_mol <= 0 or !std.math.isFinite(context.phosphorus_molar_mass_g_per_mol) or context.phosphorus_molar_mass_g_per_mol <= 0 or !std.math.isFinite(context.negligible_carbon_g_c) or context.negligible_carbon_g_c < 0 or !std.math.isFinite(context.fraction_tolerance) or context.fraction_tolerance < 0) return error.InvalidSurfaceMetabolismStateUpdateParameter;
    const fractions_to_validate = if (context.zone_fractions_by_layer.len == 0) @as([]const zone_classification.ZoneFractions, &.{context.zone_fractions}) else context.zone_fractions_by_layer;
    for (fractions_to_validate) |fractions| inline for (@typeInfo(zone_classification.ZoneFractions).@"struct".fields) |field| if (!std.math.isFinite(@field(fractions, field.name)) or @field(fractions, field.name) < 0 or @field(fractions, field.name) > 1) return error.InvalidSurfaceMetabolismStateUpdateParameter;
}

test "surface sorption exchange cannot overdraw either shared pool" {
    try std.testing.expectEqual(@as(f64, 0.1), boundedExchange(0.4, 0.1, 2));
    try std.testing.expectEqual(@as(f64, -0.2), boundedExchange(-0.5, 2, 0.2));
}

test "surface metabolism state_update conserves carbon nitrogen and phosphorus" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.dissolved[0] = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 };
    organic_state.dissolved_acetate_carbon_g_c[0] = 1;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.cells[0].nitrate_mol_per_m3 = 0.1;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.nitrogen)] = 1;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.nitrous_oxide)] = 0.2;
    var respiration_state = try respiration.State.init(std.testing.allocator, 1);
    defer respiration_state.deinit();
    respiration_state.substrate_limited_respiration_g_c[0] = 0.1;
    var oxygen_state = try oxygen.State.init(std.testing.allocator, 1);
    defer oxygen_state.deinit();
    oxygen_state.populations[0].is_aerobic = true;
    oxygen_state.allocation.demand_satisfaction_fraction[0] = 1;
    var fixation_state = try fixation.State.init(std.testing.allocator, 1);
    defer fixation_state.deinit();
    var uptake_state = try uptake.State.init(std.testing.allocator, 1);
    defer uptake_state.deinit();
    uptake_state.doc_uptake_g_c[0] = 0.3;
    uptake_state.dissolved_organic_nitrogen_uptake_g_n[0] = 0.03;
    uptake_state.dissolved_organic_phosphorus_uptake_g_p[0] = 0.003;
    uptake_state.nonstructural_carbon_gain_g_c[0] = 0.2;
    var denitrification_state = try denitrification.State.init(std.testing.allocator, 1);
    defer denitrification_state.deinit();
    var assimilation_state = try assimilation.State.init(std.testing.allocator, 1);
    defer assimilation_state.deinit();
    var mineral_exchange_state = try mineral_exchange.State.init(std.testing.allocator, 1);
    defer mineral_exchange_state.deinit();
    // Source RINH4/RIPO4 are signed: negative values mineralize microbial
    // surplus into the surface aqueous pools.
    mineral_exchange_state.ammonium_exchange_g_n[0] = -0.01;
    mineral_exchange_state.h2po4_exchange_g_p[0] = -0.001;
    var topsoil_exchange_state = try topsoil_exchange.State.init(std.testing.allocator, 1);
    defer topsoil_exchange_state.deinit();
    var turnover_state = try turnover.State.init(std.testing.allocator, 1);
    defer turnover_state.deinit();
    var priming_state = try priming.State.init(std.testing.allocator, 1);
    defer priming_state.deinit();
    var organic_decomposition_state = try organic_decomposition.State.init(std.testing.allocator, 1);
    defer organic_decomposition_state.deinit();
    var organic_sorption_state = try organic_sorption.State.init(std.testing.allocator, 1);
    defer organic_sorption_state.deinit();
    var litter_colonization_state = try litter_colonization.State.init(std.testing.allocator, 1);
    defer litter_colonization_state.deinit();
    organic_sorption_state.doc_sorption_g_c[0] = 0.02;
    organic_sorption_state.acetate_sorption_g_c[0] = 0.01;
    organic_state.structural[3].carbon_g_c = 1;
    organic_state.colonized_structural_carbon_g_c[3] = 1;
    organic_state.residue[0].carbon_g_c = 0.2;
    organic_state.adsorbed[0].carbon_g_c = 0.1;
    organic_state.adsorbed_acetate_carbon_g_c[0] = 0.1;
    organic_decomposition_state.structural_decomposition[3].carbon_g_c = 0.1;
    organic_decomposition_state.particulate_products[3].carbon_g_c = 0.02;
    organic_decomposition_state.dissolved_structural_products[3].carbon_g_c = 0.08;
    organic_decomposition_state.microbial_residue_decomposition[0].carbon_g_c = 0.02;
    organic_decomposition_state.sorbed_organic_decomposition[0].carbon_g_c = 0.01;
    organic_decomposition_state.sorbed_acetate_decomposition_g_c[0] = 0.01;
    priming_state.exchange.dissolved_change[0].carbon_g_c = -0.01;
    priming_state.exchange.dissolved_change[1].carbon_g_c = 0.01;
    priming_state.exchange.microbial_change[0].carbon_g_c = -0.01;
    priming_state.exchange.microbial_change[respiration.source_population_count * organic.kinetic_fraction_count].carbon_g_c = 0.01;
    organic_state.microbial[0].carbon_g_c = 1;
    turnover_state.basal[0] = .{
        .decomposed = .{ .carbon_g_c = 0.1, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        .recycled = .{ .carbon_g_c = 0.03, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        .humified = .{ .carbon_g_c = 0.014, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        .microbial_residue = .{ .carbon_g_c = 0.056, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
    };
    const runtime_config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid.GridState.init(std.testing.allocator, runtime_config);
    defer model_grid.deinit();
    model_grid.matrix_liquid_water_m3[0] = 1;
    var topsoil_chemistry = try soil_chemistry.State.init(std.testing.allocator, 1);
    defer topsoil_chemistry.deinit();
    var topsoil_organic = try organic.State.init(std.testing.allocator, 1);
    defer topsoil_organic.deinit();
    var parameters: respiration.Parameters = undefined;
    parameters.populations = [_]@import("../soil/microbial/respiration_activity.zig").PopulationParameters{.{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0 }} ** respiration.source_population_count;
    const carbon_before = try organic_state.totalCarbon_g_c(0) + try topsoil_organic.totalCarbon_g_c(0) + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.methane)];
    const nitrogen_before = organic_state.dissolved[0].nitrogen_g_n + chemistry_state.cells[0].nitrate_mol_per_m3 * 14 + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.nitrogen)] + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.nitrous_oxide)];
    var context: ApplyContext = .{ .surface_organic = &organic_state, .litter_chemistry = &chemistry_state, .litter_gas = &gas_state, .litter_water_m3 = &.{1}, .cell_area_m2 = &.{1}, .respiration = &respiration_state, .oxygen = &oxygen_state, .nitrogen_fixation = &fixation_state, .substrate_uptake = &uptake_state, .denitrification = &denitrification_state, .assimilation = &assimilation_state, .mineral_exchange = &mineral_exchange_state, .topsoil_exchange = &topsoil_exchange_state, .turnover = &turnover_state, .priming = &priming_state, .organic_decomposition = &organic_decomposition_state, .organic_sorption = &organic_sorption_state, .litter_colonization = &litter_colonization_state, .topsoil_organic = &topsoil_organic, .topsoil_humus_partition = &.{.{ 0.5, 0.5 }}, .topsoil_chemistry = &topsoil_chemistry, .model_grid = &model_grid, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .microbial_parameters = parameters, .nitrogen_molar_mass_g_per_mol = 14, .phosphorus_molar_mass_g_per_mol = 31, .negligible_carbon_g_c = 1e-12, .fraction_tolerance = 1e-12 };
    const phosphorus_before = try authoritativeCellPhosphorus_g_p(context, 0);
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const carbon_after = try organic_state.totalCarbon_g_c(0) + try topsoil_organic.totalCarbon_g_c(0) + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.methane)];
    const nitrogen_after = organic_state.dissolved[0].nitrogen_g_n + organic_state.microbial[2].nitrogen_g_n + (chemistry_state.cells[0].ammonium_mol_per_m3 + chemistry_state.cells[0].nitrate_mol_per_m3) * 14 + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.nitrogen)] + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.nitrous_oxide)];
    try std.testing.expectApproxEqAbs(carbon_before, carbon_after, 1e-12);
    try std.testing.expectApproxEqAbs(nitrogen_before, nitrogen_after, 1e-12);
    try std.testing.expectApproxEqAbs(phosphorus_before, try authoritativeCellPhosphorus_g_p(context, 0), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), chemistry_state.cells[0].ammonium_mol_per_m3 * 14, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001), chemistry_state.cells[0].h2po4_mol_p_per_m3 * 31, 1e-15);

    // A deliberately non-stoichiometric turnover candidate must fail at the
    // projected census before any owner or output ledger is published.
    organic_state.microbial[0].nitrogen_g_n = 1;
    turnover_state.basal[0].decomposed.nitrogen_g_n = 0.01;
    var signed_ledger = [_]f64{12};
    var co2_ledger = [_]f64{34};
    context.hourly_signed_heterotrophic_respiration_g_c = &signed_ledger;
    context.hourly_carbon_dioxide_production_g_c = &co2_ledger;
    const projected_failure_n_before = try authoritativeCellNitrogen_g_n(context, 0);
    const projected_failure_doc_before = organic_state.dissolved[0];
    const projected_failure_microbe_before = organic_state.microbial[0];
    const projected_failure_chemistry_before = chemistry_state.cells[0];
    const projected_failure_gas_before = gas_state.dissolved_mass_g[0..gas.species_count].*;
    try std.testing.expectError(
        error.InvalidSurfaceNitrogenConservationClosure,
        applyTile(&context, .{ .first = 0, .end = 1 }),
    );
    try std.testing.expectEqual(projected_failure_n_before, try authoritativeCellNitrogen_g_n(context, 0));
    try std.testing.expectEqualDeep(projected_failure_doc_before, organic_state.dissolved[0]);
    try std.testing.expectEqualDeep(projected_failure_microbe_before, organic_state.microbial[0]);
    try std.testing.expectEqualDeep(projected_failure_chemistry_before, chemistry_state.cells[0]);
    try std.testing.expectEqualSlices(f64, &projected_failure_gas_before, gas_state.dissolved_mass_g[0..gas.species_count]);
    try std.testing.expectEqual(@as(f64, 12), signed_ledger[0]);
    try std.testing.expectEqual(@as(f64, 34), co2_ledger[0]);

    turnover_state.basal[0].decomposed.nitrogen_g_n = 0;
    turnover_state.basal[0].microbial_residue.carbon_g_c += 1.0e-3;
    try std.testing.expectError(error.InvalidSurfaceCarbonConservationClosure, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqualDeep(projected_failure_doc_before, organic_state.dissolved[0]);
    try std.testing.expectEqualDeep(projected_failure_microbe_before, organic_state.microbial[0]);
    try std.testing.expectEqualDeep(projected_failure_chemistry_before, chemistry_state.cells[0]);
    try std.testing.expectEqualSlices(f64, &projected_failure_gas_before, gas_state.dissolved_mass_g[0..gas.species_count]);
    try std.testing.expectEqual(@as(f64, 12), signed_ledger[0]);
    try std.testing.expectEqual(@as(f64, 34), co2_ledger[0]);

    turnover_state.basal[0].microbial_residue.carbon_g_c -= 1.0e-3;
    turnover_state.basal[0].microbial_residue.phosphorus_g_p = 1.0e-3;
    try std.testing.expectError(error.InvalidSurfacePhosphorusConservationClosure, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqualDeep(projected_failure_doc_before, organic_state.dissolved[0]);
    try std.testing.expectEqualDeep(projected_failure_microbe_before, organic_state.microbial[0]);
    try std.testing.expectEqualDeep(projected_failure_chemistry_before, chemistry_state.cells[0]);
    try std.testing.expectEqualSlices(f64, &projected_failure_gas_before, gas_state.dissolved_mass_g[0..gas.species_count]);
    try std.testing.expectEqual(@as(f64, 12), signed_ledger[0]);
    try std.testing.expectEqual(@as(f64, 34), co2_ledger[0]);
}

test "insufficient substrate leaves every surface metabolism pool unchanged" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.dissolved[0].carbon_g_c = 0.1;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var respiration_state = try respiration.State.init(std.testing.allocator, 1);
    defer respiration_state.deinit();
    var oxygen_state = try oxygen.State.init(std.testing.allocator, 1);
    defer oxygen_state.deinit();
    var fixation_state = try fixation.State.init(std.testing.allocator, 1);
    defer fixation_state.deinit();
    var uptake_state = try uptake.State.init(std.testing.allocator, 1);
    defer uptake_state.deinit();
    uptake_state.doc_uptake_g_c[0] = 0.2;
    var denitrification_state = try denitrification.State.init(std.testing.allocator, 1);
    defer denitrification_state.deinit();
    var assimilation_state = try assimilation.State.init(std.testing.allocator, 1);
    defer assimilation_state.deinit();
    var mineral_exchange_state = try mineral_exchange.State.init(std.testing.allocator, 1);
    defer mineral_exchange_state.deinit();
    var topsoil_exchange_state = try topsoil_exchange.State.init(std.testing.allocator, 1);
    defer topsoil_exchange_state.deinit();
    var turnover_state = try turnover.State.init(std.testing.allocator, 1);
    defer turnover_state.deinit();
    var priming_state = try priming.State.init(std.testing.allocator, 1);
    defer priming_state.deinit();
    var organic_decomposition_state = try organic_decomposition.State.init(std.testing.allocator, 1);
    defer organic_decomposition_state.deinit();
    var organic_sorption_state = try organic_sorption.State.init(std.testing.allocator, 1);
    defer organic_sorption_state.deinit();
    var litter_colonization_state = try litter_colonization.State.init(std.testing.allocator, 1);
    defer litter_colonization_state.deinit();
    const runtime_config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid.GridState.init(std.testing.allocator, runtime_config);
    defer model_grid.deinit();
    model_grid.matrix_liquid_water_m3[0] = 1;
    var topsoil_chemistry = try soil_chemistry.State.init(std.testing.allocator, 1);
    defer topsoil_chemistry.deinit();
    var topsoil_organic = try organic.State.init(std.testing.allocator, 1);
    defer topsoil_organic.deinit();
    var parameters: respiration.Parameters = undefined;
    parameters.populations = [_]@import("../soil/microbial/respiration_activity.zig").PopulationParameters{.{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0 }} ** respiration.source_population_count;
    const before_doc = organic_state.dissolved[0];
    const before_gas = gas_state.dissolved_mass_g;
    var gas_copy: [gas.species_count]f64 = undefined;
    @memcpy(&gas_copy, before_gas[0..gas.species_count]);
    var context: ApplyContext = .{ .surface_organic = &organic_state, .litter_chemistry = &chemistry_state, .litter_gas = &gas_state, .litter_water_m3 = &.{1}, .cell_area_m2 = &.{1}, .respiration = &respiration_state, .oxygen = &oxygen_state, .nitrogen_fixation = &fixation_state, .substrate_uptake = &uptake_state, .denitrification = &denitrification_state, .assimilation = &assimilation_state, .mineral_exchange = &mineral_exchange_state, .topsoil_exchange = &topsoil_exchange_state, .turnover = &turnover_state, .priming = &priming_state, .organic_decomposition = &organic_decomposition_state, .organic_sorption = &organic_sorption_state, .litter_colonization = &litter_colonization_state, .topsoil_organic = &topsoil_organic, .topsoil_humus_partition = &.{.{ 0.5, 0.5 }}, .topsoil_chemistry = &topsoil_chemistry, .model_grid = &model_grid, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .microbial_parameters = parameters, .nitrogen_molar_mass_g_per_mol = 14, .phosphorus_molar_mass_g_per_mol = 31, .negligible_carbon_g_c = 1e-12, .fraction_tolerance = 1e-12 };
    try std.testing.expectError(error.InsufficientSurfaceMicrobialSubstrate, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqual(before_doc, organic_state.dissolved[0]);
    try std.testing.expectEqualSlices(f64, &gas_copy, gas_state.dissolved_mass_g[0..gas.species_count]);
}

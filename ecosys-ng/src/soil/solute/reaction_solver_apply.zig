//! `reaction_solver` declarations: apply.
//!
//! Split out of `reaction_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const aqueous_network = @import("aqueous_network.zig");
const phosphate_network = @import("phosphate_network.zig");
const cation_exchange = @import("cation_exchange.zig");
const geochemistry = @import("geochemistry_network.zig");
const aqueous_rates = @import("aqueous_reaction_rates.zig");
const phosphate_rates = @import("phosphate_reaction_rates.zig");
const geochemistry_rates = @import("geochemistry_reaction_rates.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("reaction_search_span.zig");
const group_numerics2 = @import("reaction_solver_numerics2.zig");
const group_phosphate = @import("reaction_solver_phosphate.zig");

pub fn applyAqueousCalciumExtent(
    vector: []f64,
    comptime ligand_name: []const u8,
    comptime pair_name: []const u8,
    extent_mol_per_m3: f64,
) void {
    applyAqueousAssociationExtent(
        vector,
        "calcium",
        ligand_name,
        pair_name,
        extent_mol_per_m3,
    );
}

fn applyAqueousAssociationExtent(
    vector: []f64,
    comptime first_name: []const u8,
    comptime second_name: []const u8,
    comptime product_name: []const u8,
    extent_mol_per_m3: f64,
) void {
    addPacked(vector, group_numerics2.aqueousPackedIndex(first_name), -extent_mol_per_m3);
    addPacked(vector, group_numerics2.aqueousPackedIndex(second_name), -extent_mol_per_m3);
    addPacked(vector, group_numerics2.aqueousPackedIndex(product_name), extent_mol_per_m3);
}

pub fn applySiteExchangeExtent(
    vector: []f64,
    zone_index: usize,
    density_megagrams_per_m3: f64,
    comptime dissolved_name: []const u8,
    comptime site_name: []const u8,
    comptime adsorbed_name: []const u8,
    extent_mol_per_m3: f64,
) void {
    addPacked(
        vector,
        group_phosphate.phosphatePackedIndex(zone_index, dissolved_name),
        -extent_mol_per_m3,
    );
    addPacked(
        vector,
        group_phosphate.phosphatePackedIndex(zone_index, site_name),
        -extent_mol_per_m3 / density_megagrams_per_m3,
    );
    addPacked(
        vector,
        group_phosphate.phosphatePackedIndex(zone_index, adsorbed_name),
        extent_mol_per_m3 / density_megagrams_per_m3,
    );
}

pub fn addPacked(vector: []f64, index: usize, change: f64) void {
    vector[index] += change;
}

pub fn applyKineticGeochemistryStep(
    scratch: *chemistry.State,
    state: *chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    current: []f64,
) !void {
    try state.packCell(cell_index, current);
    const changes = try state.evaluateGeochemistryTransformations(
        cell_index,
        parameters.fractions,
        parameters.geochemistry_products,
        parameters.geochemistry_kinetics,
    );
    var transformations = std.mem.zeroes(chemistry.CellTransformations);
    transformations.non_band_phosphate_water_fraction =
        parameters.fractions.phosphate_non_band;
    transformations.band_phosphate_water_fraction =
        parameters.fractions.phosphate_band;
    transformations.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 =
        parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
    transformations.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 =
        parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
    transformations.cation_exchange_water_ratios =
        parameters.cation_exchange_water_ratios;
    transformations.geochemistry = changes;
    transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3 =
        parameters.cation_exchange_water_ratios.shared_megagrams_per_m3;
    try applyAdmissibleKineticTransformations(
        scratch,
        state,
        cell_index,
        transformations,
        current,
    );
}

pub fn applyAdmissibleKineticTransformations(
    scratch: *chemistry.State,
    state: *chemistry.State,
    cell_index: usize,
    transformations: chemistry.CellTransformations,
    current: []const f64,
) !void {
    var fraction: f64 = 1;
    var rejected_fraction: ?f64 = null;
    var last_rejection: ?anyerror = null;
    var attempt: u16 = 0;
    while (attempt < group_numerics2.maximum_admissibility_backtracks) : (attempt += 1) {
        try scratch.unpackCell(0, current);
        scratch.state_updateCell(
            0,
            group_numerics2.scaled(transformations, fraction),
        ) catch |err| {
            last_rejection = err;
            rejected_fraction = fraction;
            fraction *= 0.5;
            continue;
        };
        break;
    }
    if (attempt == group_numerics2.maximum_admissibility_backtracks) return last_rejection orelse
        error.NoAdmissibleKineticGeochemistryStep;

    if (rejected_fraction) |upper_bound| {
        var lower = fraction;
        var upper = upper_bound;
        while (group_numerics2.admissibilityFractionMidpoint(lower, upper)) |middle| {
            try scratch.unpackCell(0, current);
            scratch.state_updateCell(
                0,
                group_numerics2.scaled(transformations, middle),
            ) catch {
                upper = middle;
                continue;
            };
            lower = middle;
        }
        fraction = lower;
    }
    try state.state_updateCell(
        cell_index,
        group_numerics2.scaled(transformations, fraction),
    );
}

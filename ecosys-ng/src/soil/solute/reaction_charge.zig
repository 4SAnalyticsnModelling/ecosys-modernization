//! Charge carried by mutable chemistry pools, on the layer-water basis.
//! Fixed background/site countercharge cancels between entry and exit; this
//! census tests charge conservation, not an assumed zero net initial charge.
const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const classification = @import("charge_classification.zig");
const conservation = @import("../../validation/scoped_conservation.zig");
const diagnostics = @import("reaction_diagnostic_control.zig");

pub const Inventory = struct {
    positive_mol_charge_per_m3: f64,
    negative_mol_charge_per_m3: f64,

    pub fn net(self: Inventory) f64 {
        return self.positive_mol_charge_per_m3 - self.negative_mol_charge_per_m3;
    }

    pub fn gross(self: Inventory) f64 {
        return self.positive_mol_charge_per_m3 + self.negative_mol_charge_per_m3;
    }
};

pub fn inventory(state: *const chemistry.State, cell: usize, parameters: chemistry.ReactionParameters) !Inventory {
    if (cell >= state.cell_count) return error.ChemistryCellIndexOutOfBounds;
    const fractions = parameters.fractions;
    const classes = try classification.classify(state.aqueous[cell], state.non_band_phosphate[cell], state.band_phosphate[cell], fractions);
    const ratios = parameters.cation_exchange_water_ratios;
    const non_band_density = parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
    const band_density = parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
    for ([_]f64{ ratios.shared_megagrams_per_m3, ratios.ammonium_non_band_megagrams_per_m3, ratios.ammonium_band_megagrams_per_m3, non_band_density, band_density }) |density| {
        if (!std.math.isFinite(density) or density < 0) return error.InvalidSoluteReactionChargeInventory;
    }
    const exchange = state.cation_exchange_mol_per_megagram[cell];
    inline for (std.meta.fields(@TypeOf(exchange))) |field| {
        const value = @field(exchange, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSoluteReactionChargeInventory;
    }
    const carboxyl = state.carboxyl_bound_hydrogen_mol_per_megagram[cell];
    if (!std.math.isFinite(carboxyl) or carboxyl < 0) return error.InvalidSoluteReactionChargeInventory;
    var result: Inventory = .{
        .positive_mol_charge_per_m3 = 3 * classes.trivalent_cations_mol + 2 * classes.divalent_cations_mol + classes.monovalent_cations_mol +
            ratios.shared_megagrams_per_m3 * (exchange.hydrogen + 3 * (exchange.aluminum + exchange.iron) + 2 * (exchange.calcium + exchange.magnesium) + exchange.sodium + exchange.potassium + carboxyl) +
            fractions.ammonium_non_band * ratios.ammonium_non_band_megagrams_per_m3 * exchange.ammonium_non_band +
            fractions.ammonium_band * ratios.ammonium_band_megagrams_per_m3 * exchange.ammonium_band,
        .negative_mol_charge_per_m3 = 3 * classes.trivalent_anions_mol + 2 * classes.divalent_anions_mol + classes.monovalent_anions_mol,
    };
    for ([_]@TypeOf(state.non_band_phosphate[cell]){ state.non_band_phosphate[cell], state.band_phosphate[cell] }, [_]f64{ fractions.phosphate_non_band * non_band_density, fractions.phosphate_band * band_density }) |zone, factor| {
        // SXOH2 is +1, SXO is -1, and SXHPO4 is -1; SXOH and SXH2PO4
        // are neutral, matching every native surface-reaction ledger.
        result.positive_mol_charge_per_m3 += factor * zone.protonated_site_mol_per_megagram;
        result.negative_mol_charge_per_m3 += factor * (zone.deprotonated_site_mol_per_megagram + zone.adsorbed_hpo4_mol_p_per_megagram);
    }
    if (!std.math.isFinite(result.gross())) return error.InvalidSoluteReactionChargeInventory;
    return result;
}

pub fn requireConserved(before: Inventory, after: Inventory) !void {
    for ([_]f64{ before.positive_mol_charge_per_m3, before.negative_mol_charge_per_m3, after.positive_mol_charge_per_m3, after.negative_mol_charge_per_m3 }) |value| {
        if (!std.math.isFinite(value) or value < 0) return error.SoluteReactionAcceptedStateConservationFailure;
    }
    // Charge can nearly cancel. Use gross standing charge to bound the
    // census arithmetic, never the small net charge as its error scale.
    const scale = @max(before.gross(), after.gross());
    const closure = conservation.evaluate(.{ .storage_before = before.net(), .storage_after = after.net() }, .{
        .absolute = 2048 * std.math.floatEps(f64) * @max(std.math.floatMin(f64), scale),
        .relative = 64 * std.math.floatEps(f64),
    }) catch return error.SoluteReactionAcceptedStateConservationFailure;
    if (closure.accepted) return;
    if (diagnostics.isEnabled()) std.log.warn("SOLUTE accepted-state charge failure: before={e} after={e} residual={e} gross_scale={e} limit={e}", .{
        before.net(), after.net(), closure.residual, scale, closure.effective_acceptance_limit,
    });
    return error.SoluteReactionAcceptedStateConservationFailure;
}

pub fn requireConservedStates(before: *const chemistry.State, before_cell: usize, after: *const chemistry.State, after_cell: usize, parameters: chemistry.ReactionParameters) !void {
    const original = inventory(before, before_cell, parameters) catch return error.SoluteReactionAcceptedStateConservationFailure;
    const candidate = inventory(after, after_cell, parameters) catch return error.SoluteReactionAcceptedStateConservationFailure;
    try requireConserved(original, candidate);
}

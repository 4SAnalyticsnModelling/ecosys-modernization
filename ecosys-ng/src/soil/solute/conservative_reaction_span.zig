const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const aqueous_network = @import("aqueous_network.zig");
const aqueous_rates = @import("aqueous_reaction_rates.zig");
const phosphate_network = @import("phosphate_network.zig");
const phosphate_exchange = @import("phosphate_exchange.zig");
const phosphate_rates = @import("phosphate_reaction_rates.zig");
const cation_exchange = @import("cation_exchange.zig");
const geochemistry = @import("geochemistry_network.zig");
const geochemistry_rates = @import("geochemistry_reaction_rates.zig");

pub const aqueous_reaction_count =
    @typeInfo(aqueous_network.Fluxes).@"struct".fields.len;
pub const phosphate_mineral_reaction_count =
    @typeInfo(phosphate_network.MineralFluxes).@"struct".fields.len;
pub const phosphate_surface_reaction_count =
    @typeInfo(phosphate_exchange.Flux).@"struct".fields.len;
pub const phosphate_aqueous_reaction_count =
    @typeInfo(phosphate_network.DissociationAndPairingFluxes).@"struct".fields.len;
pub const phosphate_zone_reaction_count =
    phosphate_mineral_reaction_count +
    phosphate_surface_reaction_count +
    phosphate_aqueous_reaction_count;
pub const equilibrium_mineral_reaction_count =
    @typeInfo(geochemistry.MineralExtents).@"struct".fields.len;

pub const aqueous_reaction_offset: usize = 0;
pub const non_band_phosphate_reaction_offset =
    aqueous_reaction_offset + aqueous_reaction_count;
pub const non_band_phosphate_mineral_offset =
    non_band_phosphate_reaction_offset;
pub const non_band_phosphate_surface_offset =
    non_band_phosphate_mineral_offset + phosphate_mineral_reaction_count;
pub const non_band_phosphate_aqueous_offset =
    non_band_phosphate_surface_offset + phosphate_surface_reaction_count;
pub const band_phosphate_reaction_offset =
    non_band_phosphate_reaction_offset + phosphate_zone_reaction_count;
pub const band_phosphate_mineral_offset = band_phosphate_reaction_offset;
pub const band_phosphate_surface_offset =
    band_phosphate_mineral_offset + phosphate_mineral_reaction_count;
pub const band_phosphate_aqueous_offset =
    band_phosphate_surface_offset + phosphate_surface_reaction_count;
pub const gapon_reaction_offset =
    band_phosphate_reaction_offset + phosphate_zone_reaction_count;
pub const gapon_reaction_count =
    @typeInfo(cation_exchange.Cations).@"struct".fields.len - 1;
pub const carboxyl_reaction_index =
    gapon_reaction_offset + gapon_reaction_count;
pub const equilibrium_mineral_reaction_offset = carboxyl_reaction_index + 1;

/// Complete conservative equilibrium-reaction axis count. Operator-split
/// silicate weathering is intentionally excluded from the equilibrium span.
pub const reaction_count =
    equilibrium_mineral_reaction_offset + equilibrium_mineral_reaction_count;

/// True for the 38 reactions (aqueous, gapon/cation-exchange, and
/// equilibrium-mineral) whose extent-to-inventory map is confirmed pure
/// linear-add + hard-reject (genuinely affine in native extent, no
/// bisection needed) -- see `docs/discrepancy_register.md`'s
/// `PERF-REACTION-SPAN-CLOSED-FORM-001`. False for phosphate reactions
/// (`stageCellUpdate`'s reconciliation logic is not a pure add) and for
/// the carboxyl reaction, which is already fully closed-form and
/// short-circuited before `maximumReactionSpanExtent` is ever reached for
/// it (`reactionSpanExtentBounds`).
pub fn reactionSpanExtentIsClosedFormEligible(reaction: usize) bool {
    if (reaction < non_band_phosphate_reaction_offset) return true;
    if (reaction >= gapon_reaction_offset and reaction < carboxyl_reaction_index) return true;
    if (reaction >= equilibrium_mineral_reaction_offset) return true;
    return false;
}

pub const ReactionDomain = enum {
    aqueous,
    non_band_phosphate_mineral,
    non_band_phosphate_surface,
    non_band_phosphate_aqueous,
    band_phosphate_mineral,
    band_phosphate_surface,
    band_phosphate_aqueous,
    cation_exchange,
    carboxyl,
    equilibrium_mineral,
};

pub const ReactionIdentity = struct {
    domain: ReactionDomain,
    name: []const u8,
};

/// Returns the scientific ledger identity for one reaction-span column.
pub fn reactionIdentity(column: usize) ?ReactionIdentity {
    inline for (
        @typeInfo(aqueous_network.Fluxes).@"struct".fields,
        0..,
    ) |field, index| {
        if (column == aqueous_reaction_offset + index)
            return .{ .domain = .aqueous, .name = field.name };
    }
    inline for (
        @typeInfo(phosphate_network.MineralFluxes).@"struct".fields,
        0..,
    ) |field, index| {
        if (column == non_band_phosphate_mineral_offset + index)
            return .{
                .domain = .non_band_phosphate_mineral,
                .name = field.name,
            };
        if (column == band_phosphate_mineral_offset + index)
            return .{
                .domain = .band_phosphate_mineral,
                .name = field.name,
            };
    }
    inline for (
        @typeInfo(phosphate_exchange.Flux).@"struct".fields,
        0..,
    ) |field, index| {
        if (column == non_band_phosphate_surface_offset + index)
            return .{
                .domain = .non_band_phosphate_surface,
                .name = field.name,
            };
        if (column == band_phosphate_surface_offset + index)
            return .{
                .domain = .band_phosphate_surface,
                .name = field.name,
            };
    }
    inline for (
        @typeInfo(phosphate_network.DissociationAndPairingFluxes).@"struct".fields,
        0..,
    ) |field, index| {
        if (column == non_band_phosphate_aqueous_offset + index)
            return .{
                .domain = .non_band_phosphate_aqueous,
                .name = field.name,
            };
        if (column == band_phosphate_aqueous_offset + index)
            return .{
                .domain = .band_phosphate_aqueous,
                .name = field.name,
            };
    }
    if (column >= gapon_reaction_offset and column < carboxyl_reaction_index)
        return .{
            .domain = .cation_exchange,
            .name = gaponBasisName(column - gapon_reaction_offset) orelse
                unreachable,
        };
    if (column == carboxyl_reaction_index)
        return .{
            .domain = .carboxyl,
            .name = "hydrogen_protonation",
        };
    inline for (
        @typeInfo(geochemistry.MineralExtents).@"struct".fields,
        0..,
    ) |field, index| {
        if (column == equilibrium_mineral_reaction_offset + index)
            return .{
                .domain = .equilibrium_mineral,
                .name = field.name,
            };
    }
    return null;
}

/// Reports whether a reaction axis exists in the configured scientific
/// network independently of its rate at the current iterate. Exact
/// substrate exhaustion can make an enabled rate zero without removing its
/// one-sided response from the semismooth Newton system. Conversely, axes
/// disabled by source/runtime gates must not be manufactured merely because
/// a numerical probe can perturb their ledger coordinates.
pub fn reactionStructurallyEnabled(
    parameters: chemistry.ReactionParameters,
    column: usize,
) bool {
    if (column < non_band_phosphate_reaction_offset) {
        const local = column - aqueous_reaction_offset;
        const kinetics = parameters.aqueous_kinetics;
        return switch (local) {
            0 => parameters.fractions.ammonium_non_band > 0 and
                kinetics.ammonium_substrate_limit_fraction > 0 and
                kinetics.maximum_fast_association_mol_per_m3_step > 0,
            1 => parameters.fractions.ammonium_band > 0 and
                kinetics.ammonium_substrate_limit_fraction > 0 and
                kinetics.maximum_fast_association_mol_per_m3_step > 0,
            2, 3 => kinetics.general_substrate_limit_fraction > 0 and
                kinetics.maximum_fast_association_mol_per_m3_step > 0,
            else => kinetics.general_substrate_limit_fraction > 0 and
                kinetics.maximum_slow_association_mol_per_m3_step > 0,
        };
    }
    if (column < band_phosphate_reaction_offset) {
        return phosphateReactionStructurallyEnabled(
            parameters,
            parameters.fractions.phosphate_non_band,
            column - non_band_phosphate_reaction_offset,
        );
    }
    if (column < gapon_reaction_offset) {
        return phosphateReactionStructurallyEnabled(
            parameters,
            parameters.fractions.phosphate_band,
            column - band_phosphate_reaction_offset,
        );
    }
    if (column < carboxyl_reaction_index) {
        const local = column - gapon_reaction_offset;
        const exchange = parameters.cation_exchange_parameters;
        if (parameters.cation_exchange_capacity_mol_charge_per_megagram <= 0 or
            parameters.cation_exchange_water_ratios.shared_megagrams_per_m3 <= 0 or
            exchange.substrate_limit_fraction <= 0 or
            exchange.maximum_adsorption_mol_charge_per_m3_step <= 0)
        {
            return false;
        }
        return switch (local) {
            0 => parameters.fractions.ammonium_non_band > 0 and
                parameters.cation_exchange_water_ratios
                    .ammonium_non_band_megagrams_per_m3 > 0,
            1 => parameters.fractions.ammonium_band > 0 and
                parameters.cation_exchange_water_ratios
                    .ammonium_band_megagrams_per_m3 > 0,
            2...7 => true,
            else => false,
        };
    }
    if (column == carboxyl_reaction_index) {
        const exchange = parameters.carboxyl_exchange_parameters;
        return parameters.total_carboxyl_sites_mol_per_megagram > 0 and
            parameters.cation_exchange_water_ratios.shared_megagrams_per_m3 > 0 and
            exchange.maximum_exchange_mol_per_m3_per_iteration > 0 and
            exchange.substrate_limit_fraction_per_iteration > 0;
    }
    if (column < reaction_count) {
        const local = column - equilibrium_mineral_reaction_offset;
        return if (local <= 2)
            parameters.geochemistry_kinetics
                .maximum_hydroxide_mineral_mol_per_m3_step > 0
        else
            parameters.geochemistry_kinetics
                .maximum_general_mineral_mol_per_m3_step > 0;
    }
    return false;
}

fn phosphateReactionStructurallyEnabled(
    parameters: chemistry.ReactionParameters,
    water_fraction: f64,
    local: usize,
) bool {
    if (water_fraction <= 0) return false;
    if (local < phosphate_mineral_reaction_count) {
        const minerals = parameters.phosphate_minerals orelse return false;
        return switch (local) {
            0...2 => minerals.maximum_phosphate_precipitation_mol_per_m3_step > 0,
            3 => minerals.maximum_apatite_precipitation_mol_per_m3_step > 0,
            4 => minerals.maximum_phosphate_precipitation_mol_per_m3_step > 0 or
                minerals.maximum_mineral_dissolution_mol_per_m3_step > 0,
            else => false,
        };
    }
    if (local < phosphate_mineral_reaction_count +
        phosphate_surface_reaction_count)
    {
        return parameters.phosphate_surface
            .maximum_exchange_mol_per_megagram_step > 0 and
            parameters.phosphate_surface.substrate_limit_fraction > 0;
    }
    if (local >= phosphate_zone_reaction_count) return false;
    const aqueous_local = local - phosphate_mineral_reaction_count -
        phosphate_surface_reaction_count;
    // `calcium_po4_pairing_mol_p_per_m3` is source-disabled in both zones.
    if (aqueous_local == 5) return false;
    return parameters.phosphate_kinetics.substrate_limit_fraction > 0 and
        parameters.phosphate_kinetics.maximum_pairing_mol_per_m3_step > 0;
}

/// Evaluates each native equilibrium rate without modifying `state`.
///
/// The caller must first project the cell's H+/OH- pair onto the configured
/// water equilibrium. This routine deliberately does not apply a second water
/// projection, so every rate is evaluated at exactly the solver's current
/// iterate. Phosphate surface rates are mol/Mg, other phosphate and aqueous
/// rates are mol/m3, the carboxyl rate is mol/Mg, and mineral rates are
/// mol/m3. Each Gapon basis rate is the source adsorption change for one
/// non-calcium ion in mol ion/Mg. Its paired calcium change closes exchanger
/// charge; together the eight rates reconstruct the complete source vector.
pub fn evaluateRates(
    state: *const chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    output: []f64,
) !void {
    if (output.len != reaction_count)
        return error.SoluteReactionRateVectorSizeMismatch;
    if (cell_index >= state.cell_count)
        return error.ChemistryCellIndexOutOfBounds;

    const coefficients =
        try state.activityCoefficients(cell_index, parameters.fractions);
    const aqueous = try aqueous_rates.calculateSourceOrder(
        state.aqueous[cell_index],
        coefficients,
        parameters.aqueous_constants,
        parameters.aqueous_kinetics,
        .{
            .non_band = if (parameters.fractions.ammonium_non_band > 0)
                .wet
            else
                .dry,
            .band = if (parameters.fractions.ammonium_band > 0)
                .wet
            else
                .dry,
        },
    );
    writeStruct(aqueous_network.Fluxes, aqueous, output, aqueous_reaction_offset);

    try evaluatePhosphateZoneRates(
        state.aqueous[cell_index],
        state.non_band_phosphate[cell_index],
        coefficients,
        parameters.fractions.phosphate_non_band,
        parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        parameters,
        output[non_band_phosphate_reaction_offset..band_phosphate_reaction_offset],
    );
    try evaluatePhosphateZoneRates(
        state.aqueous[cell_index],
        state.band_phosphate[cell_index],
        coefficients,
        parameters.fractions.phosphate_band,
        parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        parameters,
        output[band_phosphate_reaction_offset..gapon_reaction_offset],
    );

    const adsorption = try evaluateCationAdsorption(
        state,
        cell_index,
        coefficients,
        parameters,
    );
    comptime var gapon_basis_index: usize = 0;
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "calcium")) continue;
        const owner_is_active = if (comptime std.mem.eql(
            u8,
            field.name,
            "ammonium_non_band",
        ))
            parameters.cation_exchange_water_ratios
                .ammonium_non_band_megagrams_per_m3 > 0
        else if (comptime std.mem.eql(u8, field.name, "ammonium_band"))
            parameters.cation_exchange_water_ratios
                .ammonium_band_megagrams_per_m3 > 0
        else
            true;
        output[gapon_reaction_offset + gapon_basis_index] = if (owner_is_active)
            @field(adsorption, field.name)
        else
            0;
        gapon_basis_index += 1;
    }
    output[carboxyl_reaction_index] =
        try state.evaluateCarboxylHydrogenChange(
            cell_index,
            parameters.total_carboxyl_sites_mol_per_megagram,
            state.aqueous[cell_index].hydrogen *
                coefficients.monovalent_activity_coefficient,
            parameters.cation_exchange_water_ratios.shared_megagrams_per_m3,
            parameters.carboxyl_exchange_parameters,
        );

    var equilibrium_kinetics = parameters.geochemistry_kinetics;
    equilibrium_kinetics.maximum_natural_weathering_mol_per_m3_step = 0;
    equilibrium_kinetics.maximum_ground_weathering_mol_per_m3_step = 0;
    const minerals = try geochemistry_rates.calculate(
        state.aqueous[cell_index],
        state.geochemistry_solids[cell_index],
        coefficients,
        parameters.geochemistry_products,
        equilibrium_kinetics,
    );
    output[equilibrium_mineral_reaction_offset + 0] =
        minerals.gibbsite_solid_mol_per_m3;
    output[equilibrium_mineral_reaction_offset + 1] =
        minerals.iron_hydroxide_solid_mol_per_m3;
    output[equilibrium_mineral_reaction_offset + 2] =
        minerals.calcite_solid_mol_per_m3;
    output[equilibrium_mineral_reaction_offset + 3] =
        minerals.gypsum_solid_mol_per_m3;
}

/// Creates an empty cell ledger with all runtime conversion metadata set.
pub fn zeroTransformations(
    parameters: chemistry.ReactionParameters,
) chemistry.CellTransformations {
    var result = std.mem.zeroes(chemistry.CellTransformations);
    result.non_band_phosphate_water_fraction =
        parameters.fractions.phosphate_non_band;
    result.band_phosphate_water_fraction =
        parameters.fractions.phosphate_band;
    result.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 =
        parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
    result.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 =
        parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
    result.cation_exchange_water_ratios =
        parameters.cation_exchange_water_ratios;
    result.carboxyl_soil_mass_per_water_volume_megagrams_per_m3 =
        parameters.cation_exchange_water_ratios.shared_megagrams_per_m3;
    return result;
}

/// Adds one conservative reaction axis to `target`.
///
/// `native_extent` uses the rate units documented by `evaluateRates`. Each
/// Gapon extent is one non-calcium exchange-ion change paired against calcium;
/// every basis direction is independently charge conservative.
pub fn addReactionExtent(
    target: *chemistry.CellTransformations,
    column: usize,
    native_extent: f64,
    current_transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
) !void {
    if (column >= reaction_count) return error.SoluteReactionColumnOutOfBounds;
    if (!std.math.isFinite(native_extent))
        return error.NonFiniteSoluteReactionExtent;

    if (column < non_band_phosphate_reaction_offset) {
        var fluxes = std.mem.zeroes(aqueous_network.Fluxes);
        setStructField(
            aqueous_network.Fluxes,
            &fluxes,
            column - aqueous_reaction_offset,
            native_extent,
        );
        const changes = try aqueous_network.assemble(fluxes, .{
            .non_band = parameters.fractions.ammonium_non_band,
            .band = parameters.fractions.ammonium_band,
        });
        try addStruct(aqueous_network.Transformations, &target.aqueous, changes);
        return;
    }
    if (column < band_phosphate_reaction_offset) {
        try addPhosphateExtent(
            &target.non_band_phosphate,
            column - non_band_phosphate_reaction_offset,
            native_extent,
            parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        );
        return;
    }
    if (column < gapon_reaction_offset) {
        try addPhosphateExtent(
            &target.band_phosphate,
            column - band_phosphate_reaction_offset,
            native_extent,
            parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        );
        return;
    }
    if (column < carboxyl_reaction_index) {
        try addCationExchangeBasisExtent(
            &target.cation_adsorption_mol_per_megagram,
            column - gapon_reaction_offset,
            native_extent,
            parameters.fractions,
        );
        return;
    }
    if (column == carboxyl_reaction_index) {
        const next =
            target.carboxyl_hydrogen_change_mol_per_megagram + native_extent;
        if (!std.math.isFinite(next))
            return error.NonFiniteSoluteReactionTransformation;
        target.carboxyl_hydrogen_change_mol_per_megagram = next;
        return;
    }

    _ = current_transformations;

    var extents = std.mem.zeroes(geochemistry.MineralExtents);
    setStructField(
        geochemistry.MineralExtents,
        &extents,
        column - equilibrium_mineral_reaction_offset,
        native_extent,
    );
    const changes = try geochemistry.assemble(
        extents,
        std.mem.zeroes(geochemistry.WeatheringExtents),
    );
    try addStruct(
        geochemistry.Transformations,
        &target.geochemistry,
        changes,
    );
}

fn evaluatePhosphateZoneRates(
    shared: aqueous_network.State,
    zone: phosphate_network.State,
    coefficients: @import("activity_coefficients.zig").Result,
    water_fraction: f64,
    soil_mass_per_water_volume_megagrams_per_m3: f64,
    parameters: chemistry.ReactionParameters,
    output: []f64,
) !void {
    if (output.len != phosphate_zone_reaction_count)
        return error.SolutePhosphateRateVectorSizeMismatch;
    if (water_fraction == 0) {
        @memset(output, 0);
        return;
    }
    const fluxes = try phosphate_rates.calculate(
        shared,
        zone,
        coefficients,
        soil_mass_per_water_volume_megagrams_per_m3,
        parameters.phosphate_constants,
        parameters.phosphate_surface,
        parameters.phosphate_minerals,
        parameters.phosphate_kinetics,
    );
    writeStruct(phosphate_network.MineralFluxes, fluxes.minerals, output, 0);
    writeStruct(
        phosphate_exchange.Flux,
        fluxes.surface,
        output,
        phosphate_mineral_reaction_count,
    );
    writeStruct(
        phosphate_network.DissociationAndPairingFluxes,
        fluxes.aqueous,
        output,
        phosphate_mineral_reaction_count + phosphate_surface_reaction_count,
    );
}

fn evaluateCationAdsorption(
    state: *const chemistry.State,
    cell_index: usize,
    coefficients: @import("activity_coefficients.zig").Result,
    parameters: chemistry.ReactionParameters,
) !cation_exchange.Cations {
    const shared = state.aqueous[cell_index];
    const concentrations = cation_exchange.Cations{
        .ammonium_non_band = shared.ammonium_non_band,
        .ammonium_band = shared.ammonium_band,
        .hydrogen = shared.hydrogen,
        .aluminum = shared.aluminum,
        .iron = shared.iron,
        .calcium = shared.calcium,
        .magnesium = shared.magnesium,
        .sodium = shared.sodium,
        .potassium = shared.potassium,
    };
    var activities = concentrations;
    activities.ammonium_non_band *= coefficients.monovalent_activity_coefficient;
    activities.ammonium_band *= coefficients.monovalent_activity_coefficient;
    activities.hydrogen *= coefficients.monovalent_activity_coefficient;
    activities.aluminum *= coefficients.trivalent_activity_coefficient;
    activities.iron *= coefficients.trivalent_activity_coefficient;
    activities.calcium *= coefficients.divalent_activity_coefficient;
    activities.magnesium *= coefficients.divalent_activity_coefficient;
    activities.sodium *= coefficients.monovalent_activity_coefficient;
    activities.potassium *= coefficients.monovalent_activity_coefficient;
    return cation_exchange.calculateSourceOrder(.{
        .cation_exchange_capacity_mol_charge_per_megagram = parameters.cation_exchange_capacity_mol_charge_per_megagram,
        .aqueous_concentration_mol_per_m3 = concentrations,
        .aqueous_activity_mol_per_m3 = activities,
        .exchange_concentration_mol_per_megagram = state.cation_exchange_mol_per_megagram[cell_index],
        .ammonium_non_band_fraction = parameters.fractions.ammonium_non_band,
        .ammonium_band_fraction = parameters.fractions.ammonium_band,
        .soil_mass_per_water_volume_megagrams_per_m3 = parameters.cation_exchange_water_ratios.shared_megagrams_per_m3,
    }, parameters.cation_exchange_parameters, .{
        .minimum_activity_mol_per_m3 = parameters.negligible_water_ion_concentration_mol_per_m3,
    });
}

fn addPhosphateExtent(
    target: *phosphate_network.Transformations,
    local_column: usize,
    native_extent: f64,
    soil_mass_per_water_volume_megagrams_per_m3: f64,
) !void {
    var fluxes = std.mem.zeroes(phosphate_network.Fluxes);
    fluxes.soil_mass_per_water_volume_megagrams_per_m3 =
        soil_mass_per_water_volume_megagrams_per_m3;
    if (local_column < phosphate_mineral_reaction_count) {
        setStructField(
            phosphate_network.MineralFluxes,
            &fluxes.minerals,
            local_column,
            native_extent,
        );
    } else if (local_column <
        phosphate_mineral_reaction_count + phosphate_surface_reaction_count)
    {
        setStructField(
            phosphate_exchange.Flux,
            &fluxes.surface,
            local_column - phosphate_mineral_reaction_count,
            native_extent,
        );
    } else {
        setStructField(
            phosphate_network.DissociationAndPairingFluxes,
            &fluxes.aqueous,
            local_column -
                phosphate_mineral_reaction_count -
                phosphate_surface_reaction_count,
            native_extent,
        );
    }
    const changes = try phosphate_network.assemble(fluxes);
    try addStruct(phosphate_network.Transformations, target, changes);
}

fn addCationExchangeBasisExtent(
    target: *cation_exchange.Cations,
    local_column: usize,
    native_extent: f64,
    fractions: @import("charge_classification.zig").ZoneFractions,
) !void {
    if (local_column >= gapon_reaction_count)
        return error.SoluteReactionColumnOutOfBounds;
    var change = std.mem.zeroes(cation_exchange.Cations);
    comptime var basis_index: usize = 0;
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "calcium")) continue;
        if (local_column == basis_index) {
            @field(change, field.name) = native_extent;
            change.calcium = -0.5 * cationSiteChargeWeight(field.name, fractions) * native_extent;
        }
        basis_index += 1;
    }
    try addStruct(cation_exchange.Cations, target, change);
}

/// Adds a calcium-neutral exchange between two non-calcium Gapon coordinates.
/// This is the active-face direction needed when calcium itself is pinned at a
/// donor boundary: the two exchanger changes carry equal and opposite charge,
/// so neither the aqueous nor exchanger calcium inventories are touched.
pub fn addGaponSwapExtent(
    target: *chemistry.CellTransformations,
    first_local_column: usize,
    second_local_column: usize,
    first_native_extent: f64,
    fractions: @import("charge_classification.zig").ZoneFractions,
) !void {
    const first_charge_weight = gaponBasisSiteChargeWeight(first_local_column, fractions) orelse
        return error.SoluteReactionColumnOutOfBounds;
    const second_charge_weight = gaponBasisSiteChargeWeight(second_local_column, fractions) orelse
        return error.SoluteReactionColumnOutOfBounds;
    if (first_local_column == second_local_column)
        return error.DuplicateCationExchangeBasisColumn;
    if (!std.math.isFinite(first_native_extent))
        return error.NonFiniteSoluteReactionExtent;
    if (first_charge_weight == 0 or second_charge_weight == 0)
        return error.InactiveCationExchangeBasis;
    try addCationExchangeBasisExtent(
        &target.cation_adsorption_mol_per_megagram,
        first_local_column,
        first_native_extent,
        fractions,
    );
    try addCationExchangeBasisExtent(
        &target.cation_adsorption_mol_per_megagram,
        second_local_column,
        -(first_charge_weight / second_charge_weight) * first_native_extent,
        fractions,
    );
}

pub fn gaponBasisValence(local_column: usize) ?f64 {
    return switch (local_column) {
        0, 1, 2, 6, 7 => 1,
        3, 4 => 3,
        5 => 2,
        else => null,
    };
}

pub fn gaponBasisSiteChargeWeight(
    local_column: usize,
    fractions: @import("charge_classification.zig").ZoneFractions,
) ?f64 {
    return switch (local_column) {
        0 => fractions.ammonium_non_band,
        1 => fractions.ammonium_band,
        else => gaponBasisValence(local_column),
    };
}

fn cationValence(comptime name: []const u8) f64 {
    return if (std.mem.eql(u8, name, "aluminum") or
        std.mem.eql(u8, name, "iron"))
        3
    else if (std.mem.eql(u8, name, "calcium") or
        std.mem.eql(u8, name, "magnesium"))
        2
    else
        1;
}

fn cationSiteChargeWeight(
    comptime name: []const u8,
    fractions: @import("charge_classification.zig").ZoneFractions,
) f64 {
    return if (std.mem.eql(u8, name, "ammonium_non_band"))
        fractions.ammonium_non_band
    else if (std.mem.eql(u8, name, "ammonium_band"))
        fractions.ammonium_band
    else
        cationValence(name);
}

fn cationCharge(
    value: cation_exchange.Cations,
    fractions: @import("charge_classification.zig").ZoneFractions,
) f64 {
    var charge: f64 = 0;
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field|
        charge += cationSiteChargeWeight(field.name, fractions) * @field(value, field.name);
    return charge;
}

fn gaponBasisName(local_column: usize) ?[]const u8 {
    return switch (local_column) {
        0 => "ammonium_non_band_vs_calcium",
        1 => "ammonium_band_vs_calcium",
        2 => "hydrogen_vs_calcium",
        3 => "aluminum_vs_calcium",
        4 => "iron_vs_calcium",
        5 => "magnesium_vs_calcium",
        6 => "sodium_vs_calcium",
        7 => "potassium_vs_calcium",
        else => null,
    };
}

fn writeStruct(
    comptime T: type,
    value: T,
    output: []f64,
    offset: usize,
) void {
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, index|
        output[offset + index] = @field(value, field.name);
}

fn setStructField(
    comptime T: type,
    target: *T,
    index: usize,
    value: f64,
) void {
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, field_index| {
        if (index == field_index) @field(target.*, field.name) = value;
    }
}

fn addStruct(comptime T: type, target: *T, change: T) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const next = @field(target.*, field.name) + @field(change, field.name);
        if (!std.math.isFinite(next))
            return error.NonFiniteSoluteReactionTransformation;
    }
    inline for (@typeInfo(T).@"struct".fields) |field|
        @field(target.*, field.name) += @field(change, field.name);
}

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field|
        @field(result, field.name) = value;
    return result;
}

fn testParameters() chemistry.ReactionParameters {
    return .{
        .fractions = .{
            .ammonium_non_band = 0.8,
            .ammonium_band = 0.2,
            .nitrate_non_band = 0.6,
            .nitrate_band = 0.4,
            .phosphate_non_band = 0.7,
            .phosphate_band = 0.3,
        },
        .non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1.2,
        .band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1.5,
        .cation_exchange_capacity_mol_charge_per_megagram = 10,
        .cation_exchange_water_ratios = .{
            .shared_megagrams_per_m3 = 1.4,
            .ammonium_non_band_megagrams_per_m3 = 1.1,
            .ammonium_band_megagrams_per_m3 = 1.8,
        },
        .total_carboxyl_sites_mol_per_megagram = 2,
        .carboxyl_exchange_parameters = .{
            .dissociation_constant_mol_per_m3 = 0.01,
            .maximum_exchange_mol_per_m3_per_iteration = 0.01,
            .substrate_limit_fraction_per_iteration = 0.2,
        },
        .aqueous_constants = filled(aqueous_rates.EquilibriumConstants, 1),
        .aqueous_kinetics = .{
            .ammonium_substrate_limit_fraction = 0.2,
            .general_substrate_limit_fraction = 0.2,
            .maximum_fast_association_mol_per_m3_step = 0.01,
            .maximum_slow_association_mol_per_m3_step = 0.01,
        },
        .phosphate_constants = filled(phosphate_rates.EquilibriumConstants, 1),
        .phosphate_surface = .{
            .protonated_site_equilibrium_constant = 1,
            .hydroxyl_site_equilibrium_constant = 1,
            .h2po4_exchange_equilibrium_constant = 1,
            .hpo4_exchange_equilibrium_constant = 1,
            .water_activity_product_mol2_per_m6 = 1,
            .h2po4_dissociation_constant = 1,
            .maximum_exchange_mol_per_megagram_step = 0.01,
            .substrate_limit_fraction = 0.2,
        },
        .phosphate_minerals = filled(phosphate_rates.MineralParameters, 1),
        .phosphate_kinetics = .{
            .substrate_limit_fraction = 0.2,
            .maximum_pairing_mol_per_m3_step = 0.01,
        },
        .cation_exchange_parameters = .{
            .selectivity = .{
                .calcium_ammonium = 1,
                .calcium_hydrogen = 1,
                .calcium_aluminum_and_iron = 1,
                .calcium_magnesium = 1,
                .calcium_sodium = 1,
                .calcium_potassium = 1,
            },
            .substrate_limit_fraction = 0.2,
            .maximum_adsorption_mol_charge_per_m3_step = 0.01,
        },
        .geochemistry_products = filled(geochemistry_rates.SolubilityProducts, 1),
        .geochemistry_kinetics = .{
            .general_substrate_limit_fraction = 0.2,
            .hydrogen_coupled_substrate_limit_fraction = 0.2,
            .maximum_hydroxide_mineral_mol_per_m3_step = 0.01,
            .maximum_general_mineral_mol_per_m3_step = 0.01,
            .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1,
            .maximum_natural_weathering_mol_per_m3_step = 0.01,
            .maximum_ground_weathering_mol_per_m3_step = 0.01,
        },
        .water_activity_product_mol2_per_m6 = 1,
        .negligible_water_ion_concentration_mol_per_m3 = 1e-32,
    };
}

fn resetPositiveTestState(state: *chemistry.State) void {
    state.aqueous[0] = filled(aqueous_network.State, 10);
    state.non_band_phosphate[0] = filled(phosphate_network.State, 10);
    state.band_phosphate[0] = filled(phosphate_network.State, 10);
    state.cation_exchange_mol_per_megagram[0] =
        filled(cation_exchange.Cations, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.geochemistry_solids[0] = filled(geochemistry.SolidState, 10);
    state.water_mol_per_m3[0] = 10;
}

test "reaction span offsets cover every equilibrium ledger axis" {
    try std.testing.expectEqual(@as(usize, 25), aqueous_reaction_count);
    try std.testing.expectEqual(@as(usize, 5), phosphate_mineral_reaction_count);
    try std.testing.expectEqual(@as(usize, 5), phosphate_surface_reaction_count);
    try std.testing.expectEqual(@as(usize, 9), phosphate_aqueous_reaction_count);
    try std.testing.expectEqual(@as(usize, 25), non_band_phosphate_reaction_offset);
    try std.testing.expectEqual(@as(usize, 44), band_phosphate_reaction_offset);
    try std.testing.expectEqual(@as(usize, 63), gapon_reaction_offset);
    try std.testing.expectEqual(@as(usize, 8), gapon_reaction_count);
    try std.testing.expectEqual(@as(usize, 71), carboxyl_reaction_index);
    try std.testing.expectEqual(@as(usize, 72), equilibrium_mineral_reaction_offset);
    try std.testing.expectEqual(@as(usize, 76), reaction_count);
}

test "structural reaction gates retain only configured scientific axes" {
    const calcium_po4_local = phosphate_mineral_reaction_count +
        phosphate_surface_reaction_count + 5;
    var parameters = testParameters();
    try std.testing.expect(!reactionStructurallyEnabled(
        parameters,
        non_band_phosphate_reaction_offset + calcium_po4_local,
    ));
    try std.testing.expect(!reactionStructurallyEnabled(
        parameters,
        band_phosphate_reaction_offset + calcium_po4_local,
    ));

    parameters.fractions.phosphate_non_band = 0;
    try std.testing.expect(!reactionStructurallyEnabled(
        parameters,
        non_band_phosphate_mineral_offset,
    ));
    try std.testing.expect(!reactionStructurallyEnabled(
        parameters,
        non_band_phosphate_surface_offset,
    ));
    try std.testing.expect(!reactionStructurallyEnabled(
        parameters,
        non_band_phosphate_aqueous_offset,
    ));

    parameters = testParameters();
    parameters.phosphate_minerals = null;
    try std.testing.expect(!reactionStructurallyEnabled(
        parameters,
        non_band_phosphate_mineral_offset,
    ));
    try std.testing.expect(reactionStructurallyEnabled(
        parameters,
        non_band_phosphate_aqueous_offset,
    ));

    parameters = testParameters();
    parameters.cation_exchange_water_ratios
        .ammonium_non_band_megagrams_per_m3 = 0;
    parameters.cation_exchange_water_ratios
        .ammonium_band_megagrams_per_m3 = 0;
    try std.testing.expect(!reactionStructurallyEnabled(
        parameters,
        gapon_reaction_offset,
    ));
    try std.testing.expect(!reactionStructurallyEnabled(
        parameters,
        gapon_reaction_offset + 1,
    ));
    try std.testing.expect(reactionStructurallyEnabled(
        parameters,
        gapon_reaction_offset + 5,
    ));

    parameters = testParameters();
    parameters.fractions.ammonium_band = 0;
    try std.testing.expect(!reactionStructurallyEnabled(parameters, 1));
    try std.testing.expect(!reactionStructurallyEnabled(
        parameters,
        gapon_reaction_offset + 1,
    ));
    try std.testing.expect(reactionStructurallyEnabled(parameters, 0));

    var minerals = parameters.phosphate_minerals.?;
    minerals.maximum_phosphate_precipitation_mol_per_m3_step = 0;
    minerals.maximum_apatite_precipitation_mol_per_m3_step = 0;
    minerals.maximum_mineral_dissolution_mol_per_m3_step = 0;
    parameters.phosphate_minerals = minerals;
    for (0..phosphate_mineral_reaction_count) |local| try std.testing.expect(
        !reactionStructurallyEnabled(
            parameters,
            non_band_phosphate_reaction_offset + local,
        ),
    );
    minerals.maximum_mineral_dissolution_mol_per_m3_step = 1;
    parameters.phosphate_minerals = minerals;
    try std.testing.expect(reactionStructurallyEnabled(
        parameters,
        non_band_phosphate_reaction_offset + 4,
    ));
}

test "reaction identities cover every equilibrium ledger axis" {
    for (0..reaction_count) |column|
        try std.testing.expect(reactionIdentity(column) != null);
    try std.testing.expect(reactionIdentity(reaction_count) == null);

    const aqueous = reactionIdentity(aqueous_reaction_offset).?;
    try std.testing.expectEqual(ReactionDomain.aqueous, aqueous.domain);
    try std.testing.expectEqualStrings(
        "ammonium_non_band_association",
        aqueous.name,
    );
    const non_band_mineral =
        reactionIdentity(non_band_phosphate_mineral_offset).?;
    try std.testing.expectEqual(
        ReactionDomain.non_band_phosphate_mineral,
        non_band_mineral.domain,
    );
    try std.testing.expectEqualStrings(
        "aluminum_phosphate_mol_per_m3",
        non_band_mineral.name,
    );
    const band_surface =
        reactionIdentity(band_phosphate_surface_offset).?;
    try std.testing.expectEqual(
        ReactionDomain.band_phosphate_surface,
        band_surface.domain,
    );
    try std.testing.expectEqualStrings(
        "protonated_to_hydroxyl_site_mol_per_megagram",
        band_surface.name,
    );
    const band_aqueous =
        reactionIdentity(band_phosphate_aqueous_offset).?;
    try std.testing.expectEqual(
        ReactionDomain.band_phosphate_aqueous,
        band_aqueous.domain,
    );
    try std.testing.expectEqualStrings(
        "po4_hydrogen_association_mol_p_per_m3",
        band_aqueous.name,
    );
    try std.testing.expectEqualStrings(
        "ammonium_non_band_vs_calcium",
        reactionIdentity(gapon_reaction_offset).?.name,
    );
    try std.testing.expectEqualStrings(
        "potassium_vs_calcium",
        reactionIdentity(gapon_reaction_offset + gapon_reaction_count - 1).?.name,
    );
    try std.testing.expectEqualStrings(
        "hydrogen_protonation",
        reactionIdentity(carboxyl_reaction_index).?.name,
    );
    const final_mineral = reactionIdentity(reaction_count - 1).?;
    try std.testing.expectEqual(
        ReactionDomain.equilibrium_mineral,
        final_mineral.domain,
    );
    try std.testing.expectEqualStrings(
        "gypsum_precipitation_mol_per_m3",
        final_mineral.name,
    );
}

test "runtime rates retain disabled phosphate axes as zero" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    resetPositiveTestState(&state);
    const rates = try std.testing.allocator.alloc(f64, reaction_count);
    defer std.testing.allocator.free(rates);
    try evaluateRates(&state, 0, testParameters(), rates);

    const calcium_po4_local_index =
        phosphate_mineral_reaction_count +
        phosphate_surface_reaction_count + 5;
    try std.testing.expectEqual(
        @as(f64, 0),
        rates[non_band_phosphate_reaction_offset + calcium_po4_local_index],
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        rates[band_phosphate_reaction_offset + calcium_po4_local_index],
    );
    for (rates) |rate| try std.testing.expect(std.math.isFinite(rate));
}

test "reaction span exactly follows dry ammonium zone source gates" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    resetPositiveTestState(&state);
    state.aqueous[0].ammonia_band = 1;
    state.aqueous[0].ammonium_band = 0;
    state.aqueous[0].hydrogen = 1;

    var parameters = testParameters();
    const coefficients = try state.activityCoefficients(0, parameters.fractions);
    const ungated = try aqueous_rates.calculate(
        state.aqueous[0],
        coefficients,
        parameters.aqueous_constants,
        parameters.aqueous_kinetics,
    );
    try std.testing.expect(ungated.ammonium_band_association > 0);

    parameters.fractions.ammonium_band = 0;
    var rates: [reaction_count]f64 = undefined;
    try evaluateRates(&state, 0, parameters, &rates);
    const transformations = try state.evaluateCell(0, parameters);
    try std.testing.expectEqual(@as(f64, 0), rates[1]);
    try std.testing.expectEqual(
        @as(f64, 0),
        transformations.aqueous.ammonium_band,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        transformations.aqueous.ammonia_band,
    );
    try std.testing.expect(!reactionStructurallyEnabled(parameters, 1));
    try std.testing.expect(!reactionStructurallyEnabled(
        parameters,
        gapon_reaction_offset + 1,
    ));
}

test "every reaction axis assembles an admissible atomic cell transaction" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const parameters = testParameters();
    var current = zeroTransformations(parameters);
    current.cation_adsorption_mol_per_megagram.ammonium_non_band = 0.01;
    current.cation_adsorption_mol_per_megagram.sodium = -0.01;

    for (0..reaction_count) |column| {
        resetPositiveTestState(&state);
        var target = zeroTransformations(parameters);
        const extent: f64 = 1e-4;
        try addReactionExtent(
            &target,
            column,
            extent,
            current,
            parameters,
        );
        try state.state_updateCell(0, target);
    }
}

test "Gapon basis axes are charge conservative and reconstruct the complete source vector" {
    const parameters = testParameters();
    var current = zeroTransformations(parameters);
    current.cation_adsorption_mol_per_megagram = .{
        .ammonium_non_band = 0.125,
        .ammonium_band = -0.0625,
        .hydrogen = 0.03125,
        .aluminum = 0.015625,
        .iron = -0.0078125,
        .calcium = -0.12578125,
        .magnesium = 0.0625,
        .sodium = -0.03125,
        .potassium = 0.015625,
    };
    var target = zeroTransformations(parameters);
    comptime var basis_index: usize = 0;
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "calcium")) continue;
        var axis = zeroTransformations(parameters);
        const extent = @field(
            current.cation_adsorption_mol_per_megagram,
            field.name,
        );
        try addReactionExtent(
            &axis,
            gapon_reaction_offset + basis_index,
            extent,
            current,
            parameters,
        );
        try std.testing.expectEqual(
            @as(f64, 0),
            cationCharge(axis.cation_adsorption_mol_per_megagram, parameters.fractions),
        );
        try addStruct(
            cation_exchange.Cations,
            &target.cation_adsorption_mol_per_megagram,
            axis.cation_adsorption_mol_per_megagram,
        );
        basis_index += 1;
    }
    try std.testing.expectEqual(
        current.cation_adsorption_mol_per_megagram,
        target.cation_adsorption_mol_per_megagram,
    );
}

test "Gapon source rates reconstruct adsorption and conserve every aqueous-exchange species" {
    const parameters = testParameters();
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    resetPositiveTestState(&state);
    const adsorption = try evaluateCationAdsorption(
        &state,
        0,
        try state.activityCoefficients(0, parameters.fractions),
        parameters,
    );
    var rates: [reaction_count]f64 = undefined;
    try evaluateRates(&state, 0, parameters, &rates);

    var transformations = zeroTransformations(parameters);
    for (0..gapon_reaction_count) |basis_index| try addReactionExtent(
        &transformations,
        gapon_reaction_offset + basis_index,
        rates[gapon_reaction_offset + basis_index],
        zeroTransformations(parameters),
        parameters,
    );
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| {
        try std.testing.expectApproxEqAbs(
            @field(adsorption, field.name),
            @field(transformations.cation_adsorption_mol_per_megagram, field.name),
            128 * std.math.floatEps(f64) * @max(1.0, @abs(@field(adsorption, field.name))),
        );
    }

    const aqueous_before = state.aqueous[0];
    const exchange_before = state.cation_exchange_mol_per_megagram[0];
    try state.state_updateCell(0, transformations);
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| {
        const ratio = if (comptime std.mem.eql(u8, field.name, "ammonium_non_band"))
            parameters.cation_exchange_water_ratios.ammonium_non_band_megagrams_per_m3
        else if (comptime std.mem.eql(u8, field.name, "ammonium_band"))
            parameters.cation_exchange_water_ratios.ammonium_band_megagrams_per_m3
        else
            parameters.cation_exchange_water_ratios.shared_megagrams_per_m3;
        const before = @field(aqueous_before, field.name) +
            ratio * @field(exchange_before, field.name);
        const after = @field(state.aqueous[0], field.name) +
            ratio * @field(state.cation_exchange_mol_per_megagram[0], field.name);
        try std.testing.expectApproxEqAbs(
            before,
            after,
            128 * std.math.floatEps(f64) * @max(1.0, @abs(before)),
        );
    }
}

test "Gapon non-calcium swap remains admissible with calcium pinned" {
    const parameters = testParameters();
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    resetPositiveTestState(&state);
    state.aqueous[0].calcium = 0;
    state.cation_exchange_mol_per_megagram[0].calcium = 0;
    const aqueous_ammonium_before = state.aqueous[0].ammonium_band;
    const aqueous_hydrogen_before = state.aqueous[0].hydrogen;
    const exchange_ammonium_before =
        state.cation_exchange_mol_per_megagram[0].ammonium_band;
    const exchange_hydrogen_before =
        state.cation_exchange_mol_per_megagram[0].hydrogen;

    var transformations = zeroTransformations(parameters);
    try addGaponSwapExtent(&transformations, 1, 2, 0.25, parameters.fractions);
    try std.testing.expectEqual(
        @as(f64, 0),
        transformations.cation_adsorption_mol_per_megagram.calcium,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        cationCharge(transformations.cation_adsorption_mol_per_megagram, parameters.fractions),
    );
    try state.state_updateCell(0, transformations);
    try std.testing.expectEqual(@as(f64, 0), state.aqueous[0].calcium);
    try std.testing.expectEqual(
        @as(f64, 0),
        state.cation_exchange_mol_per_megagram[0].calcium,
    );
    try std.testing.expectApproxEqAbs(
        aqueous_ammonium_before +
            parameters.cation_exchange_water_ratios
                .ammonium_band_megagrams_per_m3 * exchange_ammonium_before,
        state.aqueous[0].ammonium_band +
            parameters.cation_exchange_water_ratios
                .ammonium_band_megagrams_per_m3 *
                state.cation_exchange_mol_per_megagram[0].ammonium_band,
        64 * std.math.floatEps(f64) *
            @max(1.0, @abs(aqueous_ammonium_before)),
    );
    try std.testing.expectApproxEqAbs(
        aqueous_hydrogen_before +
            parameters.cation_exchange_water_ratios.shared_megagrams_per_m3 *
                exchange_hydrogen_before,
        state.aqueous[0].hydrogen +
            parameters.cation_exchange_water_ratios.shared_megagrams_per_m3 *
                state.cation_exchange_mol_per_megagram[0].hydrogen,
        64 * std.math.floatEps(f64) *
            @max(1.0, @abs(aqueous_hydrogen_before)),
    );
}

test "Gapon rates exclude ammonium coordinates without a water owner" {
    var parameters = testParameters();
    parameters.cation_exchange_water_ratios
        .ammonium_non_band_megagrams_per_m3 = 0;
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    resetPositiveTestState(&state);
    var rates: [reaction_count]f64 = undefined;
    try evaluateRates(&state, 0, parameters, &rates);
    try std.testing.expectEqual(
        @as(f64, 0),
        rates[gapon_reaction_offset],
    );
}

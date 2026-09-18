const std = @import("std");
const concentration_kernel = @import("litter_soil_solute_concentration.zig");
const diffusivity_kernel = @import("litter_soil_solute_diffusivity.zig");
const convective_kernel = @import("litter_soil_convective_solute_flux.zig");
const diffusive_kernel = @import("litter_soil_diffusive_solute_flux.zig");
const total_kernel = @import("litter_soil_total_solute_flux.zig");
const accumulation_kernel = @import("litter_soil_solute_flux_accumulation.zig");
const litter_organic_update = @import("../../redistribution/surface/litter_dissolved_organic_update.zig");
const transport_species = @import("transport_species.zig");
const litter_chemistry = @import("../../surface/litter_chemistry.zig");

pub const litter_species_count = concentration_kernel.litter_species_count;
pub const soil_species_count = concentration_kernel.soil_species_count;
pub const organic_fraction_count: usize = 3;
pub const organic_component_count: usize = 4;
/// NH4, NH3, NO3, NO2, HPO4, H2PO4.  The last two remain distinct from the
/// extensive PO4/H3PO4 coordinates at indices 34/35.
pub const mineral_species_count: usize = 6;
pub const mineral_soil_zone_count: usize = 12;
pub const canonical_species_count = transport_species.AqueousSpecies.count;

/// HOUR1 parameter codebook projected onto the three runtime interface
/// families. Salt order is PO4, Al, Fe, H, Ca, Mg, Na, K, OH, SO4, Cl, CO3,
/// HCO3, H4SiO4 (`hour1.f:79--87`; `trnsfrs.f:2633--2646`). Organic order is
/// DOC, DON, DOP, acetate. Mineral order is NH4, NH3, NO3, NO2, HPO4, H2PO4;
/// both phosphate forms use POSG, not the adjacent ZNSG ammonium value.
pub const reference_salt_diffusivity_m2_per_h: [diffusivity_kernel.diffusivity_class_count]f64 = .{
    3.0e-6, 5.0e-6, 5.0e-6, 5.0e-6, 5.0e-6, 5.0e-6, 5.0e-6,
    5.0e-6, 5.0e-6, 5.0e-6, 5.0e-6, 5.0e-6, 5.0e-6, 5.0e-6,
};
pub const reference_organic_diffusivity_m2_per_h: [organic_component_count]f64 = .{ 1.0e-8, 1.0e-8, 1.0e-8, 3.64e-6 };
pub const reference_mineral_diffusivity_m2_per_h: [mineral_species_count]f64 = .{ 4.0e-6, 4.0e-6, 6.0e-6, 6.0e-6, 3.0e-6, 3.0e-6 };

/// Concentration carriers for one accepted litter-water transition.  The
/// interface still receives the live water volume for physical transport, but
/// retained chemistry is exported from its remembered dry carrier and is
/// imported onto the new live carrier (or the retained carrier when still
/// dry).  This makes wet/dry/rewet an extensive-inventory-preserving change of
/// representation rather than a source or sink.
pub const AqueousCarrierTransition = struct {
    before_m3: f64,
    after_m3: f64,
    dry_reference_after_m3: f64,
};

pub fn aqueousCarrierTransition(
    old_live_water_m3: f64,
    new_live_water_m3: f64,
    dry_reference_before_m3: f64,
) !AqueousCarrierTransition {
    inline for (.{ old_live_water_m3, new_live_water_m3, dry_reference_before_m3 }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterSoilChemistryCarrier;
    const before_m3 = if (old_live_water_m3 > 0)
        old_live_water_m3
    else
        dry_reference_before_m3;
    return .{
        .before_m3 = before_m3,
        .after_m3 = if (new_live_water_m3 > 0) new_live_water_m3 else before_m3,
        .dry_reference_after_m3 = if (new_live_water_m3 > 0) 0 else before_m3,
    };
}

comptime {
    if (canonical_species_count != soil_species_count + 4 or
        @intFromEnum(transport_species.AqueousSpecies.non_band_hpo4) != soil_species_count or
        @intFromEnum(transport_species.AqueousSpecies.non_band_h2po4) != soil_species_count + 1 or
        @intFromEnum(transport_species.AqueousSpecies.band_hpo4) != soil_species_count + 2 or
        @intFromEnum(transport_species.AqueousSpecies.band_h2po4) != soil_species_count + 3)
        @compileError("litter/topsoil canonical phosphate adapter mapping changed");
}

/// Projects the canonical 54-coordinate runtime carriers into the exact
/// source-order 42-litter/50-soil interface without treating the appended
/// bare HPO4/H2PO4 coordinates as legacy complex slots.
pub fn projectCanonicalSolutes(
    canonical_litter_mol: []const f64,
    canonical_soil_mol: []const f64,
    litter_compatibility_mol: *[litter_species_count]f64,
    soil_compatibility_mol: *[soil_species_count]f64,
) !void {
    if (canonical_litter_mol.len != canonical_species_count or
        canonical_soil_mol.len != canonical_species_count)
        return error.LitterSoilCanonicalDimensionMismatch;
    inline for (.{ canonical_litter_mol, canonical_soil_mol }) |values|
        for (values) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidLitterSoilCanonicalInventory;
    @memcpy(litter_compatibility_mol, canonical_litter_mol[0..litter_species_count]);
    @memcpy(soil_compatibility_mol, canonical_soil_mol[0..soil_species_count]);
}

/// Publishes a fully accepted compatibility transaction back into canonical
/// runtime storage. The four appended bare-phosphate coordinates are the
/// transport owners corresponding to the dedicated compatibility mineral
/// vector; chemistry is their concentration mirror. Validate every source
/// before modifying either runtime slice so publication is atomic.
pub fn publishCanonicalSolutes(
    canonical_litter_mol: []f64,
    canonical_soil_mol: []f64,
    litter_compatibility_mol: *const [litter_species_count]f64,
    soil_compatibility_mol: *const [soil_species_count]f64,
    soil_mineral_mol: *const [mineral_soil_zone_count]f64,
) !void {
    if (canonical_litter_mol.len != canonical_species_count or
        canonical_soil_mol.len != canonical_species_count)
        return error.LitterSoilCanonicalDimensionMismatch;
    inline for (.{
        litter_compatibility_mol,
        soil_compatibility_mol,
        soil_mineral_mol,
    }) |values| for (values) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterSoilCanonicalInventory;

    @memcpy(canonical_litter_mol[0..litter_species_count], litter_compatibility_mol);
    @memcpy(canonical_soil_mol[0..soil_species_count], soil_compatibility_mol);
    canonical_soil_mol[@intFromEnum(transport_species.AqueousSpecies.non_band_hpo4)] = soil_mineral_mol[8];
    canonical_soil_mol[@intFromEnum(transport_species.AqueousSpecies.non_band_h2po4)] = soil_mineral_mol[10];
    canonical_soil_mol[@intFromEnum(transport_species.AqueousSpecies.band_hpo4)] = soil_mineral_mol[9];
    canonical_soil_mol[@intFromEnum(transport_species.AqueousSpecies.band_h2po4)] = soil_mineral_mol[11];
}

pub const Parameters = struct {
    minimum_litter_bulk_volume_m3: f64,
    minimum_water_m3: f64,
    minimum_thickness_m: f64,
    litter_tortuosity: f64,
    soil_surface_tortuosity: f64,
    litter_cover_fraction: f64,
    dispersivity_m: f64,
    maximum_pore_velocity_m_per_step: f64,
    maximum_convective_fraction: f64,
    nonband_phosphate_fraction: f64,
    band_phosphate_fraction: f64,
    /// NH4, NH3, NO3, NO2, HPO4, H2PO4 zone carriers. These cannot share one
    /// phosphate fraction: TRNSFR uses VLNH4, VLNO3, and VLPO4 respectively.
    nonband_mineral_fraction: [mineral_species_count]f64,
    band_mineral_fraction: [mineral_species_count]f64,
    phosphorus_g_per_mol: f64,
    aqueous_diffusivity_m2_per_step: [diffusivity_kernel.diffusivity_class_count]f64,
    organic_diffusivity_m2_per_step: [organic_component_count]f64,
    mineral_diffusivity_m2_per_step: [mineral_species_count]f64,
    /// Physical admissibility floors in each inventory's native unit. Free
    /// phosphate is represented as g P during this transaction; the other
    /// solute coordinates and all mineral pools are mol.
    solute_admissibility_absolute_tolerance_mol: f64,
    phosphate_admissibility_absolute_tolerance_g_p: f64,
    /// DOC, DON, DOP, acetate = g C, g N, g P, g C.
    organic_admissibility_absolute_tolerance_g: [organic_component_count]f64,
    mineral_admissibility_absolute_tolerance_mol: f64,
    admissibility_relative_tolerance: f64,
    zone_fraction_absolute_tolerance: f64,
    zone_fraction_relative_tolerance: f64,
    /// Conservation acceptance is deliberately independent of physical
    /// admissibility and nonlinear convergence.
    solute_conservation_absolute_tolerance_mol: f64,
    phosphate_conservation_absolute_tolerance_g_p: f64,
    organic_conservation_absolute_tolerance_g: [organic_component_count]f64,
    mineral_conservation_absolute_tolerance_mol: f64,
    conservation_relative_tolerance: f64,
};

pub const Inputs = struct {
    litter_bulk_volume_m3: f64,
    litter_water_m3: f64,
    soil_surface_water_m3: f64,
    litter_thickness_m: f64,
    soil_surface_thickness_m: f64,
    soil_surface_area_m2: f64,
    litter_to_soil_water_flux_m3_per_step: f64,
    /// Runtime representation is mol for all 42/50 fields. The compatibility
    /// kernels' two free-phosphate slots are converted to and from g P only
    /// inside this transaction.
    litter_solute_mol: *[litter_species_count]f64,
    soil_solute_mol: *[soil_species_count]f64,
    litter_organic: *[organic_fraction_count]litter_organic_update.OrganicPool,
    soil_organic: *[organic_fraction_count]litter_organic_update.OrganicPool,
    /// NH4, NH3, NO3, NO2, HPO4, H2PO4 in litter; non-band/band pairs in soil.
    litter_mineral_mol: *[mineral_species_count]f64,
    soil_mineral_mol: *[mineral_soil_zone_count]f64,
};

pub const Result = struct {
    maximum_absolute_solute_closure: f64,
    maximum_normalized_solute_closure: f64,
    maximum_absolute_organic_closure_g: f64,
    maximum_normalized_organic_closure: f64,
    maximum_absolute_mineral_closure_mol: f64,
    maximum_normalized_mineral_closure: f64,
    /// Exact accepted producer transfers. Positive values move litter ->
    /// topsoil and negative values move topsoil -> litter. These are retained
    /// separately from closure diagnostics so a local conservation ledger can
    /// publish both sides without reconstructing fluxes from state deltas.
    signed_solute_transfer_mol: [litter_species_count]f64,
    signed_organic_transfer_g: [organic_fraction_count][organic_component_count]f64,
    signed_mineral_transfer_mol: [mineral_species_count]f64,
};

/// Synchronizes only free non-phosphate litter chemistry into persistent
/// transport. PO4/H3PO4 at 34/35 are transport-owned and retain their amount;
/// HPO4/H2PO4 move through the separate mineral vector below.
pub fn exportRepresentedLitterChemistry(cell: anytype, water_m3: f64, inventory_mol: *[litter_species_count]f64) !void {
    if (!std.math.isFinite(water_m3) or water_m3 < 0) return error.InvalidLitterSoilChemistryCarrier;
    const values = [_]f64{
        cell.aluminum_mol_per_m3,
        cell.iron_mol_per_m3,
        cell.hydrogen_mol_per_m3,
        cell.calcium_mol_per_m3,
        cell.magnesium_mol_per_m3,
        cell.sodium_mol_per_m3,
        cell.potassium_mol_per_m3,
        cell.hydroxide_mol_per_m3,
        cell.sulfate_mol_per_m3,
        cell.chloride_mol_per_m3,
        cell.carbonate_mol_per_m3,
        cell.bicarbonate_mol_per_m3,
    };
    for (values, 0..) |concentration, species| {
        if (!std.math.isFinite(concentration) or concentration < 0)
            return error.InvalidLitterSoilChemistryInventory;
        if (water_m3 == 0) {
            if (concentration != 0) return error.LitterSoluteWithoutWaterCarrier;
            continue;
        }
        const amount = concentration * water_m3;
        if (!std.math.isFinite(amount) or amount < 0) return error.InvalidLitterSoilChemistryInventory;
        inventory_mol[species] = amount;
    }
}

/// Publishes the represented litter coordinates after an accepted transfer.
/// `water_m3` is the effective chemistry carrier, which can be a remembered
/// dry reference.  A truly unbound represented amount remains invalid.
pub fn importRepresentedLitterChemistry(cell: anytype, water_m3: f64, inventory_mol: *const [litter_species_count]f64, absolute_tolerance_mol: f64, relative_tolerance: f64) !void {
    inline for (.{ water_m3, absolute_tolerance_mol, relative_tolerance }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidLitterSoilChemistryCarrier;
    for (inventory_mol[0..12]) |amount|
        if (!std.math.isFinite(amount) or amount < 0)
            return error.InvalidLitterSoilChemistryInventory;
    if (water_m3 == 0) {
        // There is no destination representation for even a small non-zero
        // inventory.  Do not erase a physical amount under an admissibility
        // tolerance: fail and let the enclosing hourly transaction roll back.
        for (inventory_mol[0..12]) |amount|
            if (amount != 0) return error.LitterSoluteWithoutWaterCarrier;
        cell.aluminum_mol_per_m3 = 0;
        cell.iron_mol_per_m3 = 0;
        cell.hydrogen_mol_per_m3 = 0;
        cell.calcium_mol_per_m3 = 0;
        cell.magnesium_mol_per_m3 = 0;
        cell.sodium_mol_per_m3 = 0;
        cell.potassium_mol_per_m3 = 0;
        cell.hydroxide_mol_per_m3 = 0;
        cell.sulfate_mol_per_m3 = 0;
        cell.chloride_mol_per_m3 = 0;
        cell.carbonate_mol_per_m3 = 0;
        cell.bicarbonate_mol_per_m3 = 0;
        return;
    }
    cell.aluminum_mol_per_m3 = inventory_mol[0] / water_m3;
    cell.iron_mol_per_m3 = inventory_mol[1] / water_m3;
    cell.hydrogen_mol_per_m3 = inventory_mol[2] / water_m3;
    cell.calcium_mol_per_m3 = inventory_mol[3] / water_m3;
    cell.magnesium_mol_per_m3 = inventory_mol[4] / water_m3;
    cell.sodium_mol_per_m3 = inventory_mol[5] / water_m3;
    cell.potassium_mol_per_m3 = inventory_mol[6] / water_m3;
    cell.hydroxide_mol_per_m3 = inventory_mol[7] / water_m3;
    cell.sulfate_mol_per_m3 = inventory_mol[8] / water_m3;
    cell.chloride_mol_per_m3 = inventory_mol[9] / water_m3;
    cell.carbonate_mol_per_m3 = inventory_mol[10] / water_m3;
    cell.bicarbonate_mol_per_m3 = inventory_mol[11] / water_m3;
}

/// Exports NH4, NH3, NO3, NO2, HPO4, and H2PO4. Concentration-backed fields
/// use the effective aqueous carrier; NO2 already has an authoritative
/// extensive owner in `surface_denitrification.nitrite_g_n`, so its molar
/// amount is supplied directly and remains representable when litter is dry.
pub fn exportLitterAqueousMinerals(cell: anytype, carrier_m3: f64, nitrite_mol: f64) ![mineral_species_count]f64 {
    if (!std.math.isFinite(carrier_m3) or carrier_m3 < 0)
        return error.InvalidLitterSoilChemistryCarrier;
    if (!std.math.isFinite(nitrite_mol) or nitrite_mol < 0)
        return error.InvalidLitterSoilChemistryInventory;
    const concentrations = [mineral_species_count - 1]f64{
        cell.ammonium_mol_per_m3,
        cell.ammonia_mol_per_m3,
        cell.nitrate_mol_per_m3,
        cell.hpo4_mol_p_per_m3,
        cell.h2po4_mol_p_per_m3,
    };
    var amounts: [mineral_species_count]f64 = undefined;
    const amount_indices = [_]usize{ 0, 1, 2, 4, 5 };
    for (concentrations, amount_indices) |concentration, species| {
        if (!std.math.isFinite(concentration) or concentration < 0)
            return error.InvalidLitterSoilChemistryInventory;
        if (carrier_m3 == 0 and concentration != 0)
            return error.LitterMineralWithoutWaterCarrier;
        const amount = concentration * carrier_m3;
        if (!std.math.isFinite(amount) or amount < 0)
            return error.InvalidLitterSoilChemistryInventory;
        amounts[species] = amount;
    }
    amounts[3] = nitrite_mol;
    return amounts;
}

/// Stages and publishes all five concentration-backed dissolved minerals and
/// returns the accepted extensive NO2 amount. A failed no-carrier or invalid-
/// inventory check leaves `cell` byte-exact.
pub fn importLitterAqueousMinerals(
    cell: anytype,
    carrier_m3: f64,
    inventory_mol: *const [mineral_species_count]f64,
) !f64 {
    if (!std.math.isFinite(carrier_m3) or carrier_m3 < 0)
        return error.InvalidLitterSoilChemistryCarrier;
    for (inventory_mol, 0..) |amount, species| {
        if (!std.math.isFinite(amount) or amount < 0)
            return error.InvalidLitterSoilChemistryInventory;
        if (carrier_m3 == 0 and amount != 0 and species != 3)
            return error.LitterMineralWithoutWaterCarrier;
    }
    const inverse_carrier = if (carrier_m3 > 0) 1 / carrier_m3 else 0;
    const concentrations = [mineral_species_count - 1]f64{
        inventory_mol[0] * inverse_carrier,
        inventory_mol[1] * inverse_carrier,
        inventory_mol[2] * inverse_carrier,
        inventory_mol[4] * inverse_carrier,
        inventory_mol[5] * inverse_carrier,
    };
    for (concentrations) |concentration|
        if (!std.math.isFinite(concentration) or concentration < 0)
            return error.InvalidLitterSoilChemistryInventory;
    cell.ammonium_mol_per_m3 = concentrations[0];
    cell.ammonia_mol_per_m3 = concentrations[1];
    cell.nitrate_mol_per_m3 = concentrations[2];
    cell.hpo4_mol_p_per_m3 = concentrations[3];
    cell.h2po4_mol_p_per_m3 = concentrations[4];
    return inventory_mol[3];
}

/// Atomic litter/topsoil transfer for the accepted NPH substep. All seven
/// translated REDIST/TRNSFRS kernels are exercised in source order. No caller
/// state is changed unless every salt, organic, and mineral donor remains
/// admissible and every paired transfer closes at its native scale.
pub fn advance(inputs: Inputs, parameters: Parameters) !Result {
    try validate(inputs, parameters);
    var litter_work = inputs.litter_solute_mol.*;
    var soil_work = inputs.soil_solute_mol.*;
    convertFreePhosphateToGrams(&litter_work, &soil_work, parameters.phosphorus_g_per_mol);

    var litter_concentration: [litter_species_count]f64 = @splat(0);
    var soil_concentration: [soil_species_count]f64 = @splat(0);
    const exchange_active = try concentration_kernel.calculate(.{
        .litter_bulk_volume_m3 = inputs.litter_bulk_volume_m3,
        .minimum_litter_bulk_volume_m3 = parameters.minimum_litter_bulk_volume_m3,
        .litter_water_m3 = inputs.litter_water_m3,
        .soil_surface_water_m3 = inputs.soil_surface_water_m3,
        .minimum_water_m3 = parameters.minimum_water_m3,
        .nonband_phosphate_fraction = parameters.nonband_phosphate_fraction,
        .band_phosphate_fraction = parameters.band_phosphate_fraction,
        .litter_inventory_amount = &litter_work,
        .soil_surface_inventory_amount = &soil_work,
    }, &litter_concentration, &soil_concentration);

    var conductance: [diffusivity_kernel.diffusivity_class_count]f64 = @splat(0);
    try diffusivity_kernel.calculate(.{
        .litter_thickness_m = inputs.litter_thickness_m,
        .soil_surface_thickness_m = inputs.soil_surface_thickness_m,
        .minimum_thickness_m = parameters.minimum_thickness_m,
        .litter_tortuosity = parameters.litter_tortuosity,
        .soil_surface_tortuosity = parameters.soil_surface_tortuosity,
        .litter_cover_fraction = parameters.litter_cover_fraction,
        .dispersivity_m = parameters.dispersivity_m,
        .litter_to_soil_water_flux_m3_per_step = inputs.litter_to_soil_water_flux_m3_per_step,
        .soil_surface_area_m2 = inputs.soil_surface_area_m2,
        .maximum_pore_velocity_m_per_step = parameters.maximum_pore_velocity_m_per_step,
        .aqueous_diffusivity_m2_per_step = &parameters.aqueous_diffusivity_m2_per_step,
    }, &conductance);

    var convective: [soil_species_count]f64 = @splat(0);
    try convective_kernel.calculate(.{
        .litter_to_soil_water_flux_m3_per_step = inputs.litter_to_soil_water_flux_m3_per_step,
        .litter_water_m3 = inputs.litter_water_m3,
        .soil_surface_water_m3 = inputs.soil_surface_water_m3,
        .minimum_water_m3 = parameters.minimum_water_m3,
        .maximum_convective_fraction = parameters.maximum_convective_fraction,
        .nonband_phosphate_fraction = parameters.nonband_phosphate_fraction,
        .band_phosphate_fraction = parameters.band_phosphate_fraction,
        .litter_inventory_amount = &litter_work,
        .soil_surface_inventory_amount = &soil_work,
    }, &convective);
    var diffusive: [soil_species_count]f64 = @splat(0);
    try diffusive_kernel.calculate(.{
        .exchange_active = exchange_active,
        .litter_concentration_amount_per_m3 = &litter_concentration,
        .soil_concentration_amount_per_m3 = &soil_concentration,
        .conductance_m3_per_step = &conductance,
        .nonband_phosphate_fraction = parameters.nonband_phosphate_fraction,
        .band_phosphate_fraction = parameters.band_phosphate_fraction,
    }, &diffusive);
    limitSaltTransfers(&convective, &diffusive, &litter_work, &soil_work);

    const zero_litter: [litter_species_count]f64 = @splat(0);
    const zero_soil: [soil_species_count]f64 = @splat(0);
    var litter_increment: [litter_species_count]f64 = @splat(0);
    var soil_increment: [soil_species_count]f64 = @splat(0);
    try total_kernel.publish(.{
        .litter_boundary_flux_amount_per_step = &zero_litter,
        .snow_litter_flux_amount_per_step = &zero_litter,
        .soil_boundary_flux_amount_per_step = &zero_soil,
        .snow_soil_flux_amount_per_step = &zero_soil,
        .convective_flux_amount_per_step = &convective,
        .diffusive_flux_amount_per_step = &diffusive,
    }, &litter_increment, &soil_increment);
    var litter_accumulated: [litter_species_count]f64 = @splat(0);
    var soil_accumulated: [soil_species_count]f64 = @splat(0);
    try accumulation_kernel.accumulate(.{
        .snow_litter_flux_amount_per_step = &zero_litter,
        .snow_soil_flux_amount_per_step = &zero_soil,
        .convective_flux_amount_per_step = &convective,
        .diffusive_flux_amount_per_step = &diffusive,
    }, &litter_accumulated, &soil_accumulated);
    if (!std.mem.eql(f64, &litter_increment, &litter_accumulated) or
        !std.mem.eql(f64, &soil_increment, &soil_accumulated))
        return error.LitterSoilSoluteLedgerDisagreement;

    var result: Result = std.mem.zeroes(Result);
    for (0..litter_species_count) |species| {
        const phosphate_coordinate = species == 34 or species == 35;
        const admissibility_absolute = if (phosphate_coordinate)
            parameters.phosphate_admissibility_absolute_tolerance_g_p
        else
            parameters.solute_admissibility_absolute_tolerance_mol;
        const conservation_absolute = if (phosphate_coordinate)
            parameters.phosphate_conservation_absolute_tolerance_g_p
        else
            parameters.solute_conservation_absolute_tolerance_mol;
        const soil_first = species;
        const soil_second: ?usize = if (species >= 34) species + 8 else null;
        const before = litter_work[species] + soil_work[soil_first] +
            (if (soil_second) |index| soil_work[index] else 0);
        const litter_candidate = litter_work[species] + litter_increment[species];
        const soil_first_candidate = soil_work[soil_first] + soil_increment[soil_first];
        const soil_second_candidate = if (soil_second) |index|
            soil_work[index] + soil_increment[index]
        else
            0;
        if (litter_candidate < 0 or soil_first_candidate < 0 or soil_second_candidate < 0) std.log.warn(
            "litter-soil solute donor rejection: species={d} before=({e},{e},{e}) candidate=({e},{e},{e}) convective=({e},{e}) diffusive=({e},{e})",
            .{ species, litter_work[species], soil_work[soil_first], if (soil_second) |index| soil_work[index] else 0, litter_candidate, soil_first_candidate, soil_second_candidate, convective[soil_first], if (soil_second) |index| convective[index] else 0, diffusive[soil_first], if (soil_second) |index| diffusive[index] else 0 },
        );
        try requireAdmissible(litter_candidate, scale3(litter_work[species], litter_increment[species], before), admissibility_absolute, parameters.admissibility_relative_tolerance);
        try requireAdmissible(soil_first_candidate, scale3(soil_work[soil_first], soil_increment[soil_first], before), admissibility_absolute, parameters.admissibility_relative_tolerance);
        if (soil_second != null)
            try requireAdmissible(soil_second_candidate, scale3(soil_work[soil_second.?], soil_increment[soil_second.?], before), admissibility_absolute, parameters.admissibility_relative_tolerance);
        const after = litter_candidate + soil_first_candidate +
            (if (soil_second != null) soil_second_candidate else 0);
        try recordClosure(before, after, conservation_absolute, parameters.conservation_relative_tolerance, &result.maximum_absolute_solute_closure, &result.maximum_normalized_solute_closure);
        result.signed_solute_transfer_mol[species] = if (phosphate_coordinate)
            -litter_increment[species] / parameters.phosphorus_g_per_mol
        else
            -litter_increment[species];
        litter_work[species] = litter_candidate;
        soil_work[soil_first] = soil_first_candidate;
        if (soil_second) |index| soil_work[index] = soil_second_candidate;
    }
    convertFreePhosphateToMoles(&litter_work, &soil_work, parameters.phosphorus_g_per_mol);

    var litter_organic_candidate = inputs.litter_organic.*;
    var soil_organic_candidate = inputs.soil_organic.*;
    var litter_fluxes: [organic_fraction_count]litter_organic_update.OrganicFlux = undefined;
    for (0..organic_fraction_count) |fraction| {
        var transfer: [organic_component_count]f64 = undefined;
        const litter_values = organicValues(litter_organic_candidate[fraction]);
        const soil_values = organicValues(soil_organic_candidate[fraction]);
        try calculateGenericTransfers(
            litter_values,
            soil_values,
            inputs,
            parameters,
            parameters.organic_diffusivity_m2_per_step,
            &transfer,
        );
        litter_fluxes[fraction] = .{
            .doc_g = -transfer[0],
            .don_g = -transfer[1],
            .dop_g = -transfer[2],
            .acetate_g = -transfer[3],
        };
        result.signed_organic_transfer_g[fraction] = transfer;
        const soil_before = soil_organic_candidate[fraction];
        soil_organic_candidate[fraction] = .{
            .doc_g = soil_before.doc_g + transfer[0],
            .don_g = soil_before.don_g + transfer[1],
            .dop_g = soil_before.dop_g + transfer[2],
            .acetate_g = soil_before.acetate_g + transfer[3],
        };
        const fields = @typeInfo(litter_organic_update.OrganicPool).@"struct".fields;
        inline for (fields, 0..) |field, component| {
            const before = @field(litter_organic_candidate[fraction], field.name) + @field(soil_before, field.name);
            const after = @field(litter_organic_candidate[fraction], field.name) - transfer[component] + @field(soil_organic_candidate[fraction], field.name);
            try requireAdmissible(@field(soil_organic_candidate[fraction], field.name), scale3(@field(soil_before, field.name), transfer[component], before), parameters.organic_admissibility_absolute_tolerance_g[component], parameters.admissibility_relative_tolerance);
            try recordClosure(before, after, parameters.organic_conservation_absolute_tolerance_g[component], parameters.conservation_relative_tolerance, &result.maximum_absolute_organic_closure_g, &result.maximum_normalized_organic_closure);
        }
    }
    litter_organic_candidate = try litter_organic_update.update(litter_fluxes, litter_organic_candidate);
    for (litter_organic_candidate) |pool| inline for (@typeInfo(litter_organic_update.OrganicPool).@"struct".fields, 0..) |field, component|
        try requireAdmissible(@field(pool, field.name), @abs(@field(pool, field.name)), parameters.organic_admissibility_absolute_tolerance_g[component], parameters.admissibility_relative_tolerance);

    var litter_mineral_candidate = inputs.litter_mineral_mol.*;
    var soil_mineral_candidate = inputs.soil_mineral_mol.*;
    for (0..mineral_species_count) |species| {
        const non_band = 2 * species;
        const band = non_band + 1;
        const litter_before = litter_mineral_candidate[species];
        const soil_non_band_before = soil_mineral_candidate[non_band];
        const soil_band_before = soil_mineral_candidate[band];
        var transfer = try zonedMineralTransfer(
            litter_before,
            soil_non_band_before,
            soil_band_before,
            inputs,
            parameters,
            parameters.mineral_diffusivity_m2_per_step[species],
            species,
        );
        limitZonedTransfer(&transfer, litter_before, soil_non_band_before, soil_band_before);
        result.signed_mineral_transfer_mol[species] = transfer[0] + transfer[1];
        litter_mineral_candidate[species] -= transfer[0] + transfer[1];
        soil_mineral_candidate[non_band] += transfer[0];
        soil_mineral_candidate[band] += transfer[1];
        const before = litter_before + soil_non_band_before + soil_band_before;
        const after = litter_mineral_candidate[species] + soil_mineral_candidate[non_band] + soil_mineral_candidate[band];
        if (litter_mineral_candidate[species] < 0 or soil_mineral_candidate[non_band] < 0 or soil_mineral_candidate[band] < 0) std.log.warn(
            "litter-soil mineral donor rejection: species={d} before=({e},{e},{e}) transfers=({e},{e}) candidate=({e},{e},{e})",
            .{ species, litter_before, soil_non_band_before, soil_band_before, transfer[0], transfer[1], litter_mineral_candidate[species], soil_mineral_candidate[non_band], soil_mineral_candidate[band] },
        );
        try requireAdmissible(litter_mineral_candidate[species], scale3(litter_before, transfer[0] + transfer[1], before), parameters.mineral_admissibility_absolute_tolerance_mol, parameters.admissibility_relative_tolerance);
        try requireAdmissible(soil_mineral_candidate[non_band], scale3(soil_non_band_before, transfer[0], before), parameters.mineral_admissibility_absolute_tolerance_mol, parameters.admissibility_relative_tolerance);
        try requireAdmissible(soil_mineral_candidate[band], scale3(soil_band_before, transfer[1], before), parameters.mineral_admissibility_absolute_tolerance_mol, parameters.admissibility_relative_tolerance);
        try recordClosure(before, after, parameters.mineral_conservation_absolute_tolerance_mol, parameters.conservation_relative_tolerance, &result.maximum_absolute_mineral_closure_mol, &result.maximum_normalized_mineral_closure);
    }

    inputs.litter_solute_mol.* = litter_work;
    inputs.soil_solute_mol.* = soil_work;
    inputs.litter_organic.* = litter_organic_candidate;
    inputs.soil_organic.* = soil_organic_candidate;
    inputs.litter_mineral_mol.* = litter_mineral_candidate;
    inputs.soil_mineral_mol.* = soil_mineral_candidate;
    return result;
}

fn organicValues(pool: litter_organic_update.OrganicPool) [organic_component_count]f64 {
    return .{ pool.doc_g, pool.don_g, pool.dop_g, pool.acetate_g };
}

fn calculateGenericTransfers(
    litter: [organic_component_count]f64,
    soil: [organic_component_count]f64,
    inputs: Inputs,
    parameters: Parameters,
    diffusivity: [organic_component_count]f64,
    output: *[organic_component_count]f64,
) !void {
    const conductance_geometry = try genericConductanceGeometry(inputs, parameters);
    const convective_fraction = donorFraction(inputs.litter_to_soil_water_flux_m3_per_step, inputs.litter_water_m3, inputs.soil_surface_water_m3, parameters);
    for (0..organic_component_count) |component| {
        const convective = convective_fraction * (if (convective_fraction >= 0) litter[component] else soil[component]);
        const diffusive = if (inputs.litter_water_m3 > parameters.minimum_water_m3 and inputs.soil_surface_water_m3 > parameters.minimum_water_m3)
            (diffusivity[component] * conductance_geometry[0] + conductance_geometry[1]) * inputs.soil_surface_area_m2 *
                (litter[component] / inputs.litter_water_m3 - soil[component] / inputs.soil_surface_water_m3)
        else
            0;
        var transfer = convective + diffusive;
        if (!std.math.isFinite(transfer)) return error.NonFiniteLitterSoilOrganicTransfer;
        transfer = std.math.clamp(transfer, -soil[component], litter[component]);
        output[component] = transfer;
    }
}

fn zonedMineralTransfer(
    litter: f64,
    soil_non_band: f64,
    soil_band: f64,
    inputs: Inputs,
    parameters: Parameters,
    diffusivity: f64,
    species: usize,
) ![2]f64 {
    const geometry = try genericConductanceGeometry(inputs, parameters);
    const conductance = (diffusivity * geometry[0] + geometry[1]) * inputs.soil_surface_area_m2;
    const convective_fraction = donorFraction(inputs.litter_to_soil_water_flux_m3_per_step, inputs.litter_water_m3, inputs.soil_surface_water_m3, parameters);
    const fractions = [2]f64{ parameters.nonband_mineral_fraction[species], parameters.band_mineral_fraction[species] };
    const soil = [2]f64{ soil_non_band, soil_band };
    var result: [2]f64 = undefined;
    for (0..2) |zone| {
        const convective = if (convective_fraction >= 0)
            convective_fraction * litter * fractions[zone]
        else
            convective_fraction * soil[zone];
        const diffusive = if (inputs.litter_water_m3 > parameters.minimum_water_m3 and inputs.soil_surface_water_m3 * fractions[zone] > parameters.minimum_water_m3)
            conductance * fractions[zone] *
                (litter / inputs.litter_water_m3 - soil[zone] / (inputs.soil_surface_water_m3 * fractions[zone]))
        else
            0;
        result[zone] = convective + diffusive;
        if (!std.math.isFinite(result[zone])) return error.NonFiniteLitterSoilMineralTransfer;
    }
    return result;
}

fn genericConductanceGeometry(inputs: Inputs, parameters: Parameters) ![2]f64 {
    const thickness = @max(parameters.minimum_thickness_m, inputs.litter_thickness_m) +
        @max(parameters.minimum_thickness_m, inputs.soil_surface_thickness_m);
    const tortuosity_per_m = (parameters.litter_tortuosity + parameters.soil_surface_tortuosity) /
        thickness * parameters.litter_cover_fraction;
    const dispersion_m2_per_step = parameters.dispersivity_m * @min(
        parameters.maximum_pore_velocity_m_per_step,
        @abs(inputs.litter_to_soil_water_flux_m3_per_step / inputs.soil_surface_area_m2),
    );
    if (!std.math.isFinite(tortuosity_per_m) or !std.math.isFinite(dispersion_m2_per_step))
        return error.NonFiniteLitterSoilConductanceGeometry;
    return .{ tortuosity_per_m, dispersion_m2_per_step };
}

fn donorFraction(water_flux: f64, litter_water: f64, soil_water: f64, parameters: Parameters) f64 {
    if (water_flux > 0)
        return if (litter_water > parameters.minimum_water_m3)
            std.math.clamp(water_flux / litter_water, 0, parameters.maximum_convective_fraction)
        else
            parameters.maximum_convective_fraction;
    return if (soil_water > parameters.minimum_water_m3)
        std.math.clamp(water_flux / soil_water, -parameters.maximum_convective_fraction, 0)
    else
        -parameters.maximum_convective_fraction;
}

fn limitSaltTransfers(convective: *[soil_species_count]f64, diffusive: *[soil_species_count]f64, litter: *const [litter_species_count]f64, soil: *const [soil_species_count]f64) void {
    for (0..34) |species| limitCombinedTransfer(&convective[species], &diffusive[species], litter[species], soil[species]);
    for (34..42) |species| {
        const band = species + 8;
        limitNegativeTransfer(&convective[species], &diffusive[species], soil[species]);
        limitNegativeTransfer(&convective[band], &diffusive[band], soil[band]);
        const total = (convective[species] + diffusive[species]) + (convective[band] + diffusive[band]);
        if (total > litter[species] and total > 0) {
            const scale = litter[species] / total;
            var parts = [_]f64{ convective[species] * scale, diffusive[species] * scale, convective[band] * scale, diffusive[band] * scale };
            const represented = (parts[0] + parts[1]) + (parts[2] + parts[3]);
            if (represented > litter[species]) {
                var largest: usize = 0;
                for (parts, 0..) |part, index| if (part > parts[largest]) {
                    largest = index;
                };
                // Reduce the accepted outgoing flux, never project a donor
                // state independently from its recipient. One inward neighbor
                // covers rounding of the represented excess subtraction.
                parts[largest] = std.math.nextAfter(f64, parts[largest] - (represented - litter[species]), 0);
            }
            convective[species] = parts[0];
            diffusive[species] = parts[1];
            convective[band] = parts[2];
            diffusive[band] = parts[3];
        }
    }
}

fn limitCombinedTransfer(convective: *f64, diffusive: *f64, litter: f64, soil: f64) void {
    const total = convective.* + diffusive.*;
    const limited = std.math.clamp(total, -soil, litter);
    if (total != limited) scalePairToTotal(convective, diffusive, limited);
}

fn limitNegativeTransfer(convective: *f64, diffusive: *f64, soil: f64) void {
    const total = convective.* + diffusive.*;
    if (total < -soil) scalePairToTotal(convective, diffusive, -soil);
}

fn limitZonedTransfer(transfer: *[2]f64, litter: f64, soil_non_band: f64, soil_band: f64) void {
    transfer[0] = @max(-soil_non_band, transfer[0]);
    transfer[1] = @max(-soil_band, transfer[1]);
    const total = transfer[0] + transfer[1];
    if (total > litter and total > 0) scalePairToTotal(&transfer[0], &transfer[1], litter);
}

fn scalePairToTotal(first: *f64, second: *f64, total: f64) void {
    const scale = total / (first.* + second.*);
    const larger = if (@abs(first.*) >= @abs(second.*)) first else second;
    const smaller = if (larger == first) second else first;
    smaller.* *= scale;
    larger.* = total - smaller.*;
    const represented = first.* + second.*;
    if ((total >= 0 and represented > total) or (total < 0 and represented < total))
        larger.* = std.math.nextAfter(f64, larger.*, 0);
}

fn convertFreePhosphateToGrams(litter: *[litter_species_count]f64, soil: *[soil_species_count]f64, phosphorus_g_per_mol: f64) void {
    litter[34] *= phosphorus_g_per_mol;
    litter[35] *= phosphorus_g_per_mol;
    soil[34] *= phosphorus_g_per_mol;
    soil[35] *= phosphorus_g_per_mol;
    soil[42] *= phosphorus_g_per_mol;
    soil[43] *= phosphorus_g_per_mol;
}

fn convertFreePhosphateToMoles(litter: *[litter_species_count]f64, soil: *[soil_species_count]f64, phosphorus_g_per_mol: f64) void {
    litter[34] /= phosphorus_g_per_mol;
    litter[35] /= phosphorus_g_per_mol;
    soil[34] /= phosphorus_g_per_mol;
    soil[35] /= phosphorus_g_per_mol;
    soil[42] /= phosphorus_g_per_mol;
    soil[43] /= phosphorus_g_per_mol;
}

fn requireAdmissible(value: f64, scale: f64, absolute_tolerance: f64, relative_tolerance: f64) !void {
    if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilInterfaceCandidate;
    const tolerance = absolute_tolerance + relative_tolerance * @abs(scale);
    if (value < -tolerance) return error.NegativeLitterSoilInterfaceCandidate;
    // Candidate limiting uses the donor's exact stored value, so a successful
    // path reaches zero exactly and does not need an independent projection.
    if (value < 0) return error.NegativeLitterSoilInterfaceRoundoff;
}

fn recordClosure(before: f64, after: f64, absolute_tolerance: f64, relative_tolerance: f64, max_absolute: *f64, max_normalized: *f64) !void {
    const absolute = @abs(after - before);
    const scale = @max(@abs(before), @abs(after));
    // Even when the configured per-area floor is zero, allow only the
    // representation error of the local arithmetic, never a physical or
    // nonlinear tolerance borrowed from another criterion.
    const representation_floor = 32.0 * std.math.floatEps(f64) * @max(1.0, scale);
    const denominator = @max(absolute_tolerance, representation_floor) + relative_tolerance * scale;
    const normalized = if (denominator > 0) absolute / denominator else absolute;
    if (!std.math.isFinite(absolute) or !std.math.isFinite(normalized)) return error.NonFiniteLitterSoilInterfaceClosure;
    max_absolute.* = @max(max_absolute.*, absolute);
    max_normalized.* = @max(max_normalized.*, normalized);
    if (normalized > 1) return error.LitterSoilInterfaceConservationFailure;
}

fn scale3(a: f64, b: f64, c: f64) f64 {
    return @max(@abs(a), @max(@abs(b), @abs(c)));
}

fn validate(inputs: Inputs, parameters: Parameters) !void {
    inline for (@typeInfo(Parameters).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteLitterSoilInterfaceParameter,
        .array => for (@field(parameters, field.name)) |value| if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilInterfaceParameter,
        else => {},
    };
    inline for (.{ inputs.litter_bulk_volume_m3, inputs.litter_water_m3, inputs.soil_surface_water_m3, inputs.litter_thickness_m, inputs.soil_surface_thickness_m, inputs.soil_surface_area_m2, inputs.litter_to_soil_water_flux_m3_per_step }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteLitterSoilInterfaceInput;
    if (inputs.litter_bulk_volume_m3 < 0 or inputs.litter_water_m3 < 0 or inputs.soil_surface_water_m3 < 0 or
        inputs.litter_thickness_m < 0 or inputs.soil_surface_thickness_m < 0 or inputs.soil_surface_area_m2 <= 0 or
        parameters.minimum_litter_bulk_volume_m3 < 0 or parameters.minimum_water_m3 < 0 or parameters.minimum_thickness_m <= 0 or
        parameters.litter_tortuosity < 0 or parameters.soil_surface_tortuosity < 0 or parameters.litter_cover_fraction < 0 or parameters.litter_cover_fraction > 1 or
        parameters.dispersivity_m < 0 or parameters.maximum_pore_velocity_m_per_step < 0 or parameters.maximum_convective_fraction < 0 or parameters.maximum_convective_fraction > 1 or
        parameters.nonband_phosphate_fraction < 0 or parameters.nonband_phosphate_fraction > 1 or parameters.band_phosphate_fraction < 0 or parameters.band_phosphate_fraction > 1 or
        @abs(parameters.nonband_phosphate_fraction + parameters.band_phosphate_fraction - 1) > parameters.zone_fraction_absolute_tolerance + parameters.zone_fraction_relative_tolerance * @max(1.0, @abs(parameters.nonband_phosphate_fraction + parameters.band_phosphate_fraction)) or
        parameters.phosphorus_g_per_mol <= 0 or
        parameters.solute_admissibility_absolute_tolerance_mol < 0 or parameters.phosphate_admissibility_absolute_tolerance_g_p < 0 or
        parameters.mineral_admissibility_absolute_tolerance_mol < 0 or parameters.admissibility_relative_tolerance < 0 or
        parameters.zone_fraction_absolute_tolerance < 0 or parameters.zone_fraction_relative_tolerance < 0 or
        parameters.solute_conservation_absolute_tolerance_mol < 0 or parameters.phosphate_conservation_absolute_tolerance_g_p < 0 or
        parameters.mineral_conservation_absolute_tolerance_mol < 0 or parameters.conservation_relative_tolerance <= 0)
        return error.InvalidLitterSoilInterfaceParameter;
    for (parameters.nonband_mineral_fraction, parameters.band_mineral_fraction) |nonband, band| {
        if (!std.math.isFinite(nonband) or !std.math.isFinite(band) or nonband < 0 or nonband > 1 or band < 0 or band > 1 or
            @abs(nonband + band - 1) > parameters.zone_fraction_absolute_tolerance + parameters.zone_fraction_relative_tolerance * @max(1.0, @abs(nonband + band)))
            return error.InvalidLitterSoilInterfaceParameter;
    }
    inline for (parameters.organic_admissibility_absolute_tolerance_g) |value|
        if (value < 0) return error.InvalidLitterSoilInterfaceParameter;
    inline for (parameters.organic_conservation_absolute_tolerance_g) |value|
        if (value < 0) return error.InvalidLitterSoilInterfaceParameter;
    inline for (.{ inputs.litter_solute_mol, inputs.soil_solute_mol, inputs.litter_mineral_mol, inputs.soil_mineral_mol }) |values|
        for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidLitterSoilInterfaceInventory;
    for (inputs.litter_organic, inputs.soil_organic) |litter, soil| inline for (@typeInfo(litter_organic_update.OrganicPool).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(litter, field.name)) or @field(litter, field.name) < 0 or
            !std.math.isFinite(@field(soil, field.name)) or @field(soil, field.name) < 0)
            return error.InvalidLitterSoilInterfaceInventory;
    };
}

fn fixtureParameters() Parameters {
    return .{
        .minimum_litter_bulk_volume_m3 = 1e-12,
        .minimum_water_m3 = 1e-12,
        .minimum_thickness_m = 1e-4,
        .litter_tortuosity = 0.2,
        .soil_surface_tortuosity = 0.2,
        .litter_cover_fraction = 1,
        .dispersivity_m = 0,
        .maximum_pore_velocity_m_per_step = 1,
        .maximum_convective_fraction = 1,
        .nonband_phosphate_fraction = 0.25,
        .band_phosphate_fraction = 0.75,
        .nonband_mineral_fraction = @splat(0.25),
        .band_mineral_fraction = @splat(0.75),
        .phosphorus_g_per_mol = 31,
        .aqueous_diffusivity_m2_per_step = @splat(1e-6),
        .organic_diffusivity_m2_per_step = .{ 1e-8, 1e-8, 1e-8, 3.64e-6 },
        .mineral_diffusivity_m2_per_step = .{ 4e-6, 4e-6, 6e-6, 6e-6, 3e-6, 3e-6 },
        .solute_admissibility_absolute_tolerance_mol = 1e-12,
        .phosphate_admissibility_absolute_tolerance_g_p = 2e-12,
        .organic_admissibility_absolute_tolerance_g = .{ 3e-12, 4e-12, 5e-12, 3e-12 },
        .mineral_admissibility_absolute_tolerance_mol = 6e-12,
        .admissibility_relative_tolerance = 1e-10,
        .zone_fraction_absolute_tolerance = 7e-12,
        .zone_fraction_relative_tolerance = 2e-10,
        .solute_conservation_absolute_tolerance_mol = 1e-13,
        .phosphate_conservation_absolute_tolerance_g_p = 2e-13,
        .organic_conservation_absolute_tolerance_g = .{ 3e-13, 4e-13, 5e-13, 3e-13 },
        .mineral_conservation_absolute_tolerance_mol = 6e-13,
        .conservation_relative_tolerance = 1e-9,
    };
}

test "litter interface split donor limits survive represented flux publication" {
    const cases = [_]struct { donor: f64, convective: f64, diffusive: f64 }{
        // Raw split whose previous independent rescaling overdraws by one ulp.
        .{ .donor = 1.013047766507193e-8, .convective = 4.086081450110149e-8, .diffusive = 4.865135429353169e-8 },
        // Accepted component values captured at Ottawa day89/hour13.
        .{ .donor = 5.4147061952735584e-11, .convective = 5.124906307361864e-11, .diffusive = 2.8979988791169467e-12 },
    };
    for (cases) |sample| for ([_]usize{ 1, 34 }) |species| {
        var litter: [litter_species_count]f64 = @splat(0);
        var soil: [soil_species_count]f64 = @splat(0);
        var convective: [soil_species_count]f64 = @splat(0);
        var diffusive: [soil_species_count]f64 = @splat(0);
        litter[species] = sample.donor;
        soil[species] = 1.0923692452053262e-13;
        convective[species] = sample.convective;
        diffusive[species] = sample.diffusive;
        if (species == 34) {
            convective[species] *= 0.6;
            diffusive[species] *= 0.6;
            convective[species + 8] = sample.convective * 0.4;
            diffusive[species + 8] = sample.diffusive * 0.4;
        }
        limitSaltTransfers(&convective, &diffusive, &litter, &soil);
        const zero_litter: [litter_species_count]f64 = @splat(0);
        const zero_soil: [soil_species_count]f64 = @splat(0);
        var litter_delta: [litter_species_count]f64 = @splat(0);
        var soil_delta: [soil_species_count]f64 = @splat(0);
        var accumulated_litter = litter_delta;
        var accumulated_soil = soil_delta;
        try total_kernel.publish(.{
            .litter_boundary_flux_amount_per_step = &zero_litter,
            .snow_litter_flux_amount_per_step = &zero_litter,
            .soil_boundary_flux_amount_per_step = &zero_soil,
            .snow_soil_flux_amount_per_step = &zero_soil,
            .convective_flux_amount_per_step = &convective,
            .diffusive_flux_amount_per_step = &diffusive,
        }, &litter_delta, &soil_delta);
        try accumulation_kernel.accumulate(.{
            .snow_litter_flux_amount_per_step = &zero_litter,
            .snow_soil_flux_amount_per_step = &zero_soil,
            .convective_flux_amount_per_step = &convective,
            .diffusive_flux_amount_per_step = &diffusive,
        }, &accumulated_litter, &accumulated_soil);
        try std.testing.expectEqualSlices(f64, &litter_delta, &accumulated_litter);
        try std.testing.expectEqualSlices(f64, &soil_delta, &accumulated_soil);
        const donor_after = sample.donor + litter_delta[species];
        const received = soil_delta[species] + (if (species == 34) soil_delta[species + 8] else 0);
        try std.testing.expect(donor_after >= 0);
        try std.testing.expectEqual(-litter_delta[species], received);
        try std.testing.expectApproxEqAbs(sample.donor, donor_after + received, 2 * std.math.floatEps(f64) * sample.donor);

        var outgoing = -sample.convective;
        var diffusion = -sample.diffusive;
        limitNegativeTransfer(&outgoing, &diffusion, sample.donor);
        try std.testing.expect(sample.donor + (outgoing + diffusion) >= 0);
        var zones = [_]f64{ sample.convective, sample.diffusive };
        limitZonedTransfer(&zones, sample.donor, 0, 0);
        try std.testing.expect(sample.donor - (zones[0] + zones[1]) >= 0);
    };
}

test "litter interface conservation acceptance is independent of admissibility" {
    var maximum_absolute: f64 = 0;
    var maximum_normalized: f64 = 0;
    const parameters = fixtureParameters();
    try std.testing.expect(parameters.solute_admissibility_absolute_tolerance_mol > parameters.solute_conservation_absolute_tolerance_mol);
    // A comparatively relaxed physical admissibility band cannot authorize
    // a mass leak under the independent conservation policy.
    try std.testing.expectError(
        error.LitterSoilInterfaceConservationFailure,
        recordClosure(1, 1.000001, 1e-12, 1e-10, &maximum_absolute, &maximum_normalized),
    );
    try std.testing.expect(maximum_normalized > 1);
}

test "litter interface diffusivity families preserve the HOUR1 species codebook" {
    try std.testing.expectEqual(@as(f64, 3.0e-6), reference_salt_diffusivity_m2_per_h[0]);
    for (reference_salt_diffusivity_m2_per_h[1..]) |value|
        try std.testing.expectEqual(@as(f64, 5.0e-6), value);
    try std.testing.expectEqualSlices(f64, &.{ 1.0e-8, 1.0e-8, 1.0e-8, 3.64e-6 }, &reference_organic_diffusivity_m2_per_h);
    try std.testing.expectEqualSlices(f64, &.{ 4.0e-6, 4.0e-6, 6.0e-6, 6.0e-6, 3.0e-6, 3.0e-6 }, &reference_mineral_diffusivity_m2_per_h);
}

test "mineral interface uses the source zone family for each N and P species" {
    var litter_solute: [litter_species_count]f64 = @splat(0);
    var soil_solute: [soil_species_count]f64 = @splat(0);
    var litter_organic: [organic_fraction_count]litter_organic_update.OrganicPool =
        @splat(.{ .doc_g = 0, .don_g = 0, .dop_g = 0, .acetate_g = 0 });
    var soil_organic = litter_organic;
    var litter_mineral: [mineral_species_count]f64 = @splat(1);
    var soil_mineral: [mineral_soil_zone_count]f64 = @splat(0);
    var parameters = fixtureParameters();
    parameters.nonband_mineral_fraction = .{ 0.8, 0.8, 0.3, 0.3, 0.1, 0.1 };
    parameters.band_mineral_fraction = .{ 0.2, 0.2, 0.7, 0.7, 0.9, 0.9 };
    _ = try advance(.{
        .litter_bulk_volume_m3 = 1,
        .litter_water_m3 = 1,
        .soil_surface_water_m3 = 1,
        .litter_thickness_m = 0.05,
        .soil_surface_thickness_m = 0.1,
        .soil_surface_area_m2 = 1,
        .litter_to_soil_water_flux_m3_per_step = 0,
        .litter_solute_mol = &litter_solute,
        .soil_solute_mol = &soil_solute,
        .litter_organic = &litter_organic,
        .soil_organic = &soil_organic,
        .litter_mineral_mol = &litter_mineral,
        .soil_mineral_mol = &soil_mineral,
    }, parameters);

    // TRNSFR VLNH4, VLNO3 and VLPO4: within each family, band/non-band
    // recipient gains follow that family's carrier split exactly.
    try std.testing.expectApproxEqRel(@as(f64, 4), soil_mineral[0] / soil_mineral[1], 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 3.0 / 7.0), soil_mineral[4] / soil_mineral[5], 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 1.0 / 9.0), soil_mineral[8] / soil_mineral[9], 1e-12);
    try std.testing.expectApproxEqRel(soil_mineral[0] / soil_mineral[1], soil_mineral[2] / soil_mineral[3], 1e-12);
    try std.testing.expectApproxEqRel(soil_mineral[4] / soil_mineral[5], soil_mineral[6] / soil_mineral[7], 1e-12);
    try std.testing.expectApproxEqRel(soil_mineral[8] / soil_mineral[9], soil_mineral[10] / soil_mineral[11], 1e-12);
}

test "litter soil interface conserves every salt organic and mineral field" {
    var litter_solute: [litter_species_count]f64 = @splat(2);
    var soil_solute: [soil_species_count]f64 = @splat(1);
    var litter_organic: [organic_fraction_count]litter_organic_update.OrganicPool = @splat(.{ .doc_g = 4, .don_g = 2, .dop_g = 1, .acetate_g = 3 });
    var soil_organic: [organic_fraction_count]litter_organic_update.OrganicPool = @splat(.{ .doc_g = 1, .don_g = 1, .dop_g = 1, .acetate_g = 1 });
    var litter_mineral = [mineral_species_count]f64{ 2, 3, 4, 5, 6, 7 };
    var soil_mineral = [mineral_soil_zone_count]f64{ 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6 };
    const litter_solute_before = litter_solute;
    const litter_organic_before = litter_organic;
    const litter_mineral_before = litter_mineral;
    const salt_before = sum(&litter_solute) + sum(&soil_solute);
    const organic_before = organicSum(&litter_organic) + organicSum(&soil_organic);
    const mineral_before = sum(&litter_mineral) + sum(&soil_mineral);
    const result = try advance(.{
        .litter_bulk_volume_m3 = 1,
        .litter_water_m3 = 0.5,
        .soil_surface_water_m3 = 0.5,
        .litter_thickness_m = 0.05,
        .soil_surface_thickness_m = 0.1,
        .soil_surface_area_m2 = 1,
        .litter_to_soil_water_flux_m3_per_step = 0.1,
        .litter_solute_mol = &litter_solute,
        .soil_solute_mol = &soil_solute,
        .litter_organic = &litter_organic,
        .soil_organic = &soil_organic,
        .litter_mineral_mol = &litter_mineral,
        .soil_mineral_mol = &soil_mineral,
    }, fixtureParameters());
    try std.testing.expectApproxEqAbs(salt_before, sum(&litter_solute) + sum(&soil_solute), 2e-13);
    try std.testing.expectApproxEqAbs(organic_before, organicSum(&litter_organic) + organicSum(&soil_organic), 2e-13);
    try std.testing.expectApproxEqAbs(mineral_before, sum(&litter_mineral) + sum(&soil_mineral), 2e-13);
    try std.testing.expect(result.maximum_normalized_solute_closure <= 1);
    try std.testing.expect(result.maximum_normalized_organic_closure <= 1);
    try std.testing.expect(result.maximum_normalized_mineral_closure <= 1);
    for (0..litter_species_count) |species|
        try std.testing.expectApproxEqAbs(
            litter_solute_before[species] - litter_solute[species],
            result.signed_solute_transfer_mol[species],
            2e-13,
        );
    for (0..organic_fraction_count) |fraction| inline for (
        @typeInfo(litter_organic_update.OrganicPool).@"struct".fields,
        0..,
    ) |field, component|
        try std.testing.expectApproxEqAbs(
            @field(litter_organic_before[fraction], field.name) - @field(litter_organic[fraction], field.name),
            result.signed_organic_transfer_g[fraction][component],
            2e-13,
        );
    for (0..mineral_species_count) |species|
        try std.testing.expectApproxEqAbs(
            litter_mineral_before[species] - litter_mineral[species],
            result.signed_mineral_transfer_mol[species],
            2e-13,
        );
}

test "canonical adapter preserves no-transfer state and publishes zoned phosphate atomically" {
    var canonical_litter: [canonical_species_count]f64 = @splat(0);
    var canonical_soil: [canonical_species_count]f64 = @splat(0);
    for (0..litter_species_count) |species| canonical_litter[species] = @floatFromInt(species + 1);
    for (0..soil_species_count) |species| canonical_soil[species] = @floatFromInt(species + 2);
    canonical_litter[canonical_species_count - 1] = 91;
    canonical_soil[@intFromEnum(transport_species.AqueousSpecies.non_band_hpo4)] = 2;
    canonical_soil[@intFromEnum(transport_species.AqueousSpecies.non_band_h2po4)] = 3;
    canonical_soil[@intFromEnum(transport_species.AqueousSpecies.band_hpo4)] = 5;
    canonical_soil[@intFromEnum(transport_species.AqueousSpecies.band_h2po4)] = 7;
    const litter_before = canonical_litter;
    const soil_before = canonical_soil;
    var litter_solute: [litter_species_count]f64 = undefined;
    var soil_solute: [soil_species_count]f64 = undefined;
    try projectCanonicalSolutes(&canonical_litter, &canonical_soil, &litter_solute, &soil_solute);
    var litter_organic: [organic_fraction_count]litter_organic_update.OrganicPool = @splat(.{ .doc_g = 0, .don_g = 0, .dop_g = 0, .acetate_g = 0 });
    var soil_organic: [organic_fraction_count]litter_organic_update.OrganicPool = @splat(.{ .doc_g = 0, .don_g = 0, .dop_g = 0, .acetate_g = 0 });
    var litter_mineral: [mineral_species_count]f64 = @splat(0);
    var soil_mineral: [mineral_soil_zone_count]f64 = @splat(0);
    soil_mineral[8] = canonical_soil[@intFromEnum(transport_species.AqueousSpecies.non_band_hpo4)];
    soil_mineral[10] = canonical_soil[@intFromEnum(transport_species.AqueousSpecies.non_band_h2po4)];
    soil_mineral[9] = canonical_soil[@intFromEnum(transport_species.AqueousSpecies.band_hpo4)];
    soil_mineral[11] = canonical_soil[@intFromEnum(transport_species.AqueousSpecies.band_h2po4)];
    var parameters = fixtureParameters();
    parameters.litter_cover_fraction = 0;
    parameters.dispersivity_m = 0;
    _ = try advance(.{
        .litter_bulk_volume_m3 = 1,
        .litter_water_m3 = 1,
        .soil_surface_water_m3 = 1,
        .litter_thickness_m = 0.05,
        .soil_surface_thickness_m = 0.1,
        .soil_surface_area_m2 = 1,
        .litter_to_soil_water_flux_m3_per_step = 0,
        .litter_solute_mol = &litter_solute,
        .soil_solute_mol = &soil_solute,
        .litter_organic = &litter_organic,
        .soil_organic = &soil_organic,
        .litter_mineral_mol = &litter_mineral,
        .soil_mineral_mol = &soil_mineral,
    }, parameters);
    try publishCanonicalSolutes(&canonical_litter, &canonical_soil, &litter_solute, &soil_solute, &soil_mineral);
    try std.testing.expectEqualSlices(f64, &litter_before, &canonical_litter);
    try std.testing.expectEqualSlices(f64, &soil_before, &canonical_soil);

    var invalid_mineral = soil_mineral;
    invalid_mineral[9] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidLitterSoilCanonicalInventory, publishCanonicalSolutes(&canonical_litter, &canonical_soil, &litter_solute, &soil_solute, &invalid_mineral));
    try std.testing.expectEqualSlices(f64, &litter_before, &canonical_litter);
    try std.testing.expectEqualSlices(f64, &soil_before, &canonical_soil);
}

test "canonical litter transfer equals summed zoned recipient gain and is substep invariant" {
    const Outcome = struct {
        litter_solute: [litter_species_count]f64,
        soil_solute: [soil_species_count]f64,
        litter_mineral: [mineral_species_count]f64,
        soil_mineral: [mineral_soil_zone_count]f64,
    };
    const Runner = struct {
        fn run(fluxes: []const f64) !Outcome {
            var result: Outcome = .{
                .litter_solute = @splat(0),
                .soil_solute = @splat(0),
                .litter_mineral = .{ 0, 0, 0, 0, 4, 2 },
                .soil_mineral = @splat(0),
            };
            result.litter_solute[34] = 5;
            var litter_organic: [organic_fraction_count]litter_organic_update.OrganicPool = @splat(.{ .doc_g = 0, .don_g = 0, .dop_g = 0, .acetate_g = 0 });
            var soil_organic: [organic_fraction_count]litter_organic_update.OrganicPool = @splat(.{ .doc_g = 0, .don_g = 0, .dop_g = 0, .acetate_g = 0 });
            var litter_water_m3: f64 = 1;
            var soil_water_m3: f64 = 1;
            var parameters = fixtureParameters();
            parameters.litter_cover_fraction = 0;
            parameters.dispersivity_m = 0;
            for (fluxes) |flux| {
                _ = try advance(.{
                    .litter_bulk_volume_m3 = 1,
                    .litter_water_m3 = litter_water_m3,
                    .soil_surface_water_m3 = soil_water_m3,
                    .litter_thickness_m = 0.05,
                    .soil_surface_thickness_m = 0.1,
                    .soil_surface_area_m2 = 1,
                    .litter_to_soil_water_flux_m3_per_step = flux,
                    .litter_solute_mol = &result.litter_solute,
                    .soil_solute_mol = &result.soil_solute,
                    .litter_organic = &litter_organic,
                    .soil_organic = &soil_organic,
                    .litter_mineral_mol = &result.litter_mineral,
                    .soil_mineral_mol = &result.soil_mineral,
                }, parameters);
                litter_water_m3 -= flux;
                soil_water_m3 += flux;
            }
            return result;
        }
    };

    const full = try Runner.run(&.{0.2});
    const halves = try Runner.run(&.{ 0.1, 0.1 });
    try std.testing.expectApproxEqAbs(@as(f64, 5), full.litter_solute[34] + full.soil_solute[34] + full.soil_solute[42], 2e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 4), full.litter_mineral[4] + full.soil_mineral[8] + full.soil_mineral[9], 2e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2), full.litter_mineral[5] + full.soil_mineral[10] + full.soil_mineral[11], 2e-14);
    inline for (@typeInfo(Outcome).@"struct".fields) |field|
        for (@field(full, field.name), @field(halves, field.name)) |one, two|
            try std.testing.expectApproxEqAbs(one, two, 2e-14);
}

test "late invalid mineral leaves all interface owners byte exact" {
    var litter_solute: [litter_species_count]f64 = @splat(2);
    var soil_solute: [soil_species_count]f64 = @splat(1);
    var litter_organic: [organic_fraction_count]litter_organic_update.OrganicPool = @splat(.{ .doc_g = 4, .don_g = 2, .dop_g = 1, .acetate_g = 3 });
    var soil_organic: [organic_fraction_count]litter_organic_update.OrganicPool = @splat(.{ .doc_g = 1, .don_g = 1, .dop_g = 1, .acetate_g = 1 });
    var litter_mineral = [mineral_species_count]f64{ 2, 3, 4, 5, 6, 7 };
    var soil_mineral = [mineral_soil_zone_count]f64{ 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, std.math.nan(f64) };
    const litter_before = litter_solute;
    const soil_before = soil_solute;
    const organic_before = litter_organic;
    try std.testing.expectError(error.InvalidLitterSoilInterfaceInventory, advance(.{
        .litter_bulk_volume_m3 = 1,
        .litter_water_m3 = 0.5,
        .soil_surface_water_m3 = 0.5,
        .litter_thickness_m = 0.05,
        .soil_surface_thickness_m = 0.1,
        .soil_surface_area_m2 = 1,
        .litter_to_soil_water_flux_m3_per_step = 0.1,
        .litter_solute_mol = &litter_solute,
        .soil_solute_mol = &soil_solute,
        .litter_organic = &litter_organic,
        .soil_organic = &soil_organic,
        .litter_mineral_mol = &litter_mineral,
        .soil_mineral_mol = &soil_mineral,
    }, fixtureParameters()));
    try std.testing.expectEqualSlices(f64, &litter_before, &litter_solute);
    try std.testing.expectEqualSlices(f64, &soil_before, &soil_solute);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&organic_before), std.mem.asBytes(&litter_organic));
}

test "dry litter interface aqueous minerals survive rewet and wet dry rewet" {
    var chemistry = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.cells[0].ammonium_mol_per_m3 = 3;
    chemistry.cells[0].nitrate_mol_per_m3 = 5;
    chemistry.cells[0].h2po4_mol_p_per_m3 = 7;
    chemistry.dry_reference_water_m3[0] = 2;

    const dry_to_wet = try aqueousCarrierTransition(0, 4, chemistry.dry_reference_water_m3[0]);
    var amounts = try exportLitterAqueousMinerals(chemistry.cells[0], dry_to_wet.before_m3, 0.7);
    try std.testing.expectEqual(@as(f64, 0.7), try importLitterAqueousMinerals(&chemistry.cells[0], dry_to_wet.after_m3, &amounts));
    chemistry.dry_reference_water_m3[0] = dry_to_wet.dry_reference_after_m3;
    try std.testing.expectEqual(@as(f64, 6), chemistry.cells[0].ammonium_mol_per_m3 * 4);
    try std.testing.expectEqual(@as(f64, 10), chemistry.cells[0].nitrate_mol_per_m3 * 4);
    try std.testing.expectEqual(@as(f64, 14), chemistry.cells[0].h2po4_mol_p_per_m3 * 4);
    try std.testing.expectEqual(@as(f64, 0), chemistry.dry_reference_water_m3[0]);

    // A physical interface can remove all live water while leaving dissolved
    // inventory behind.  Keep it represented on the pre-transfer carrier,
    // then dilute from that exact reference when water returns.
    const wet_to_dry = try aqueousCarrierTransition(4, 0, chemistry.dry_reference_water_m3[0]);
    amounts = try exportLitterAqueousMinerals(chemistry.cells[0], wet_to_dry.before_m3, 0.7);
    amounts[0] -= 1;
    amounts[2] -= 2;
    try std.testing.expectEqual(@as(f64, 0.7), try importLitterAqueousMinerals(&chemistry.cells[0], wet_to_dry.after_m3, &amounts));
    chemistry.dry_reference_water_m3[0] = wet_to_dry.dry_reference_after_m3;
    try std.testing.expectEqual(@as(f64, 4), chemistry.dry_reference_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 5), chemistry.cells[0].ammonium_mol_per_m3 * 4);
    try std.testing.expectEqual(@as(f64, 8), chemistry.cells[0].nitrate_mol_per_m3 * 4);

    const rewet = try aqueousCarrierTransition(0, 8, chemistry.dry_reference_water_m3[0]);
    amounts = try exportLitterAqueousMinerals(chemistry.cells[0], rewet.before_m3, 0.7);
    try std.testing.expectEqual(@as(f64, 0.7), try importLitterAqueousMinerals(&chemistry.cells[0], rewet.after_m3, &amounts));
    try std.testing.expectEqual(@as(f64, 5), chemistry.cells[0].ammonium_mol_per_m3 * 8);
    try std.testing.expectEqual(@as(f64, 8), chemistry.cells[0].nitrate_mol_per_m3 * 8);
    try std.testing.expectEqual(@as(f64, 14), chemistry.cells[0].h2po4_mol_p_per_m3 * 8);
}

test "unbound dry litter interface chemistry fails without mutation" {
    var chemistry = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.cells[0].ammonium_mol_per_m3 = 2;
    const before = chemistry.cells[0];
    try std.testing.expectError(
        error.LitterMineralWithoutWaterCarrier,
        exportLitterAqueousMinerals(chemistry.cells[0], 0, 0),
    );
    try std.testing.expectEqualDeep(before, chemistry.cells[0]);

    var invalid_amounts: [mineral_species_count]f64 = @splat(0);
    invalid_amounts[4] = 1;
    try std.testing.expectError(
        error.LitterMineralWithoutWaterCarrier,
        importLitterAqueousMinerals(&chemistry.cells[0], 0, &invalid_amounts),
    );
    try std.testing.expectEqualDeep(before, chemistry.cells[0]);
}

fn sum(values: []const f64) f64 {
    var result: f64 = 0;
    for (values) |value| result += value;
    return result;
}

fn organicSum(values: []const litter_organic_update.OrganicPool) f64 {
    var result: f64 = 0;
    for (values) |pool| {
        inline for (@typeInfo(litter_organic_update.OrganicPool).@"struct".fields) |field|
            result += @field(pool, field.name);
    }
    return result;
}

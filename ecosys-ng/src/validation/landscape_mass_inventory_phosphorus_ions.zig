//! `landscape_mass_inventory` declarations: phosphorus ions.
//!
//! Split out of `landscape_mass_inventory.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const grid_module = @import("../state/grid.zig");
const gas = @import("../soil/gas/transport.zig");
const organic = @import("../soil/organic/initialization.zig");
const organic_transport = @import("../soil/organic/transport.zig");
const litter_chemistry = @import("../surface/litter_chemistry.zig");
const litter_fertilizer = @import("../surface/litter_fertilizer.zig");
const audit = @import("mass_balance_audit.zig");
const surface_precipitation = @import("../surface/precipitation.zig");
const canopy_retention = @import("../canopy/energy/precipitation_retention.zig");
const mineral_nitrogen = @import("../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const nitrogen_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
const mineral_fertilizer = @import("../management/mineral_fertilizer_inventory.zig");
const soil_chemistry = @import("../soil/solute/chemistry_state.zig");
const solute_transport = @import("../soil/solute/transport.zig");
const solute_species = @import("../soil/solute/transport_species.zig");
const zone_classification = @import("../soil/solute/charge_classification.zig");
const plant_roots = @import("../plant/root/plant_root_system.zig");
const plant_litter_salt_ingress = @import("../plant/salt/litter_ingress.zig");
const group_nitrogen = @import("landscape_mass_inventory_nitrogen.zig");
const group_support = @import("landscape_mass_inventory_support.zig");
const legacy_water_negligible_floor = @import("../core/legacy_water_negligible_floor.zig");

const pending_litter_salt_species = [_]solute_species.AqueousSpecies{
    .aluminum,
    .iron,
    .calcium,
    .magnesium,
    .sodium,
    .potassium,
    .sulfate,
    .chloride,
};

/// Dry plant-litter salt is already extensive mol. Exchange layer zero is the
/// surface scope and exchange layer `L + 1` is soil layer `L`; retaining that
/// owner in this exact order makes carrierless tillage visible to both the
/// canonical cell census and its layer-local partition.
pub fn aggregatePendingPlantLitterSalts(
    state: *const plant_litter_salt_ingress.State,
) !group_support.Storage {
    var result: group_support.Storage = .{};
    for (0..state.cell_count) |cell|
        for (0..state.soil_layer_capacity + 1) |exchange_layer|
            try result.add(try aggregatePendingPlantLitterSaltExchangeLayer(state, cell, exchange_layer));
    return result;
}

pub fn aggregatePendingPlantLitterSaltsCell(
    state: *const plant_litter_salt_ingress.State,
    cell: usize,
) !group_support.Storage {
    if (cell >= state.cell_count) return error.PendingPlantLitterSaltInventoryCellOutOfBounds;
    var result: group_support.Storage = .{};
    for (0..state.soil_layer_capacity + 1) |exchange_layer|
        try result.add(try aggregatePendingPlantLitterSaltExchangeLayer(state, cell, exchange_layer));
    return result;
}

pub fn aggregatePendingPlantLitterSaltExchangeLayer(
    state: *const plant_litter_salt_ingress.State,
    cell: usize,
    exchange_layer: usize,
) !group_support.Storage {
    if (cell >= state.cell_count or exchange_layer > state.soil_layer_capacity)
        return error.PendingPlantLitterSaltInventoryCellOutOfBounds;
    const expected = try std.math.mul(
        usize,
        try std.math.mul(usize, state.cell_count, state.soil_layer_capacity + 1),
        plant_litter_salt_ingress.salt_count,
    );
    if (state.pending_mol.len != expected or state.staged_mol.len != expected or
        pending_litter_salt_species.len != plant_litter_salt_ingress.salt_count)
        return error.PendingPlantLitterSaltInventoryDimensionMismatch;

    var result: group_support.Storage = .{};
    const base = (cell * (state.soil_layer_capacity + 1) + exchange_layer) *
        plant_litter_salt_ingress.salt_count;
    for (pending_litter_salt_species, 0..) |species, salt| {
        const amount_mol = state.pending_mol[base + salt];
        if (!std.math.isFinite(amount_mol) or amount_mol < 0)
            return error.InvalidPendingPlantLitterSaltInventory;
        try group_support.addElementMoles(
            &result,
            group_support.aqueousSpeciesElements(species).scaled(amount_mol),
        );
        // Each pending entry is one transported aqueous species molecule.
        result.ion_inventory_mol += amount_mol;
        if (!std.math.isFinite(result.ion_inventory_mol))
            return error.NonFiniteLandscapeInventory;
    }
    try result.validate();
    return result;
}

/// Remaining REDIST profile phosphate and salt inventory. Mobile matrix and
/// macropore solutes are transport-owned extensive mol. Immobile exchange,
/// phosphate surfaces, precipitates, and dry fertilizer are added from their
/// distinct runtime owners. Mineral-N fertilizer and exchangeable ammonium
/// are excluded here because `group_nitrogen.aggregateProfileMineralNitrogen` owns their
/// TION contribution.
pub fn aggregateProfilePhosphorusAndIons(
    grid: *const grid_module.GridState,
    micropore: *const solute_transport.State,
    macropore: *const solute_transport.State,
    chemistry: *const soil_chemistry.State,
    pending_fertilizer: *const mineral_fertilizer.State,
    soil_water_m3: []const f64,
    soil_mass_megagrams: []const f64,
    fractions_source: anytype,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    cell_area_m2: []const f64,
) !group_support.Storage {
    return aggregateProfilePhosphorusAndIonsRange(
        grid,
        micropore,
        macropore,
        chemistry,
        pending_fertilizer,
        soil_water_m3,
        soil_mass_megagrams,
        fractions_source,
        carbon_g_per_mol,
        phosphorus_g_per_mol,
        cell_area_m2,
        0,
        grid.cell_count,
        null,
    );
}

pub fn aggregateProfilePhosphorusAndIonsCell(
    grid: *const grid_module.GridState,
    micropore: *const solute_transport.State,
    macropore: *const solute_transport.State,
    chemistry: *const soil_chemistry.State,
    pending_fertilizer: *const mineral_fertilizer.State,
    soil_water_m3: []const f64,
    soil_mass_megagrams: []const f64,
    fractions_source: anytype,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    cell_area_m2: []const f64,
    cell: usize,
) !group_support.Storage {
    if (cell >= grid.cell_count) return error.ProfilePhosphorusIonInventoryCellOutOfBounds;
    return aggregateProfilePhosphorusAndIonsRange(
        grid,
        micropore,
        macropore,
        chemistry,
        pending_fertilizer,
        soil_water_m3,
        soil_mass_megagrams,
        fractions_source,
        carbon_g_per_mol,
        phosphorus_g_per_mol,
        cell_area_m2,
        cell,
        cell + 1,
        null,
    );
}

pub fn aggregateProfilePhosphorusAndIonsLayer(
    grid: *const grid_module.GridState,
    micropore: *const solute_transport.State,
    macropore: *const solute_transport.State,
    chemistry: *const soil_chemistry.State,
    pending_fertilizer: *const mineral_fertilizer.State,
    soil_water_m3: []const f64,
    soil_mass_megagrams: []const f64,
    fractions_source: anytype,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    cell_area_m2: []const f64,
    cell: usize,
    layer: usize,
) !group_support.Storage {
    if (cell >= grid.cell_count or layer >= grid.soil_layer_capacity)
        return error.ProfilePhosphorusIonInventoryCellOutOfBounds;
    return aggregateProfilePhosphorusAndIonsRange(
        grid,
        micropore,
        macropore,
        chemistry,
        pending_fertilizer,
        soil_water_m3,
        soil_mass_megagrams,
        fractions_source,
        carbon_g_per_mol,
        phosphorus_g_per_mol,
        cell_area_m2,
        cell,
        cell + 1,
        layer,
    );
}

fn aggregateProfilePhosphorusAndIonsRange(
    grid: *const grid_module.GridState,
    micropore: *const solute_transport.State,
    macropore: *const solute_transport.State,
    chemistry: *const soil_chemistry.State,
    pending_fertilizer: *const mineral_fertilizer.State,
    soil_water_m3: []const f64,
    soil_mass_megagrams: []const f64,
    fractions_source: anytype,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    cell_area_m2: []const f64,
    first_cell: usize,
    end_cell: usize,
    local_layer_filter: ?usize,
) !group_support.Storage {
    const species_count = solute_species.AqueousSpecies.count;
    if (grid.layer_count !=
        try std.math.mul(usize, grid.cell_count, grid.soil_layer_capacity) or
        grid.active_soil_layer_count.len != grid.cell_count or
        micropore.cell_count != grid.layer_count or
        macropore.cell_count != grid.layer_count or
        micropore.species_count != species_count or
        macropore.species_count != species_count or
        chemistry.cell_count != grid.layer_count or
        pending_fertilizer.cell_count != grid.cell_count or
        pending_fertilizer.layer_capacity != grid.soil_layer_capacity or
        pending_fertilizer.soil.len != grid.layer_count or
        soil_water_m3.len != grid.layer_count or
        chemistry.dry_reference_water_m3.len != grid.layer_count or
        soil_mass_megagrams.len != grid.layer_count or
        cell_area_m2.len != grid.cell_count)
        return error.ProfilePhosphorusIonInventoryDimensionMismatch;
    if (!std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0 or
        !std.math.isFinite(phosphorus_g_per_mol) or
        phosphorus_g_per_mol <= 0)
        return error.InvalidElementMolarMass;
    try micropore.validateFinite();
    try macropore.validateFinite();

    var result: group_support.Storage = .{};
    var element_moles: group_support.ElementMolesAccumulator = .{};
    for (first_cell..end_cell) |cell| {
        const active_layers = grid.active_soil_layer_count[cell];
        if (active_layers > grid.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        if (!std.math.isFinite(cell_area_m2[cell]) or cell_area_m2[cell] < 0)
            return error.InvalidLandscapeCellArea;
        const negligible_water_volume_m3 = legacyNegligibleWaterVolumeM3(cell_area_m2[cell]);
        const first_layer = if (local_layer_filter) |layer| @min(layer, active_layers) else 0;
        const end_layer = if (local_layer_filter) |layer| @min(layer + 1, active_layers) else active_layers;
        for (first_layer..end_layer) |layer| {
            const profile_cell = cell * grid.soil_layer_capacity + layer;
            const fractions = try inventoryFractionsAt(fractions_source, profile_cell);
            try validatePhosphateFractions(fractions);
            const water_m3 = try aqueousCarrierM3(
                soil_water_m3[profile_cell],
                chemistry.dry_reference_water_m3[profile_cell],
                negligible_water_volume_m3,
            );
            const mass_megagrams = soil_mass_megagrams[profile_cell];
            if (!std.math.isFinite(mass_megagrams) or mass_megagrams < 0)
                return error.InvalidProfileChemistryGeometry;

            const matrix_amounts =
                try micropore.cellAmountsConst(profile_cell);
            const macro_amounts =
                try macropore.cellAmountsConst(profile_cell);
            inline for (@typeInfo(solute_species.AqueousSpecies).@"enum".fields) |field| {
                const species: solute_species.AqueousSpecies =
                    @enumFromInt(field.value);
                const amount_mol =
                    matrix_amounts[field.value] + macro_amounts[field.value];
                try element_moles.add(
                    group_support.aqueousSpeciesElements(species).scaled(amount_mol),
                );
                result.ion_inventory_mol +=
                    amount_mol * aqueousIonAtomCount(species);
                if (isPhosphateCarrier(species))
                    result.phosphate_phosphorus_g +=
                        amount_mol * phosphorus_g_per_mol;
                if (isCarbonateCarrier(species))
                    result.carbon_dioxide_carbon_g +=
                        amount_mol * carbon_g_per_mol;
            }

            const non_band = chemistry.non_band_phosphate[profile_cell];
            const band = chemistry.band_phosphate[profile_cell];
            try group_support.validateFiniteNonnegativeStruct(non_band);
            try group_support.validateFiniteNonnegativeStruct(band);
            const immobile_non_band =
                phosphateImmobileInventory(non_band, water_m3, mass_megagrams, fractions.phosphate_non_band);
            const immobile_band =
                phosphateImmobileInventory(band, water_m3, mass_megagrams, fractions.phosphate_band);
            result.phosphate_phosphorus_g += phosphorus_g_per_mol *
                (immobile_non_band.phosphorus_mol + immobile_band.phosphorus_mol);
            result.ion_inventory_mol += immobile_non_band.ion_mol + immobile_band.ion_mol;
            try element_moles.add(
                immobile_non_band.elements,
            );
            try element_moles.add(
                immobile_band.elements,
            );
            const pending_non_band = chemistry.pending_non_band_phosphate_mol[profile_cell];
            const pending_band = chemistry.pending_band_phosphate_mol[profile_cell];
            try group_support.validateFiniteNonnegativeStruct(pending_non_band);
            try group_support.validateFiniteNonnegativeStruct(pending_band);
            // Pending fields are already extensive mol, so unit carriers
            // recover the same stoichiometric inventory without rescaling.
            const pending_immobile_non_band = phosphateImmobileInventory(pending_non_band, 1, 1, 1);
            const pending_immobile_band = phosphateImmobileInventory(pending_band, 1, 1, 1);
            result.phosphate_phosphorus_g += phosphorus_g_per_mol *
                (pending_immobile_non_band.phosphorus_mol + pending_immobile_band.phosphorus_mol);
            result.ion_inventory_mol += pending_immobile_non_band.ion_mol + pending_immobile_band.ion_mol;
            try element_moles.add(pending_immobile_non_band.elements);
            try element_moles.add(pending_immobile_band.elements);

            const exchange = chemistry.cation_exchange_mol_per_megagram[profile_cell];
            try group_support.validateFiniteNonnegativeStruct(exchange);
            const carboxyl_hydrogen =
                chemistry.carboxyl_bound_hydrogen_mol_per_megagram[profile_cell];
            if (!std.math.isFinite(carboxyl_hydrogen) or
                carboxyl_hydrogen < 0)
                return error.InvalidProfileMineralIonState;
            result.ion_inventory_mol +=
                carrierAmount(exchange.hydrogen, mass_megagrams) +
                carrierAmount(exchange.aluminum, mass_megagrams) +
                carrierAmount(exchange.iron, mass_megagrams) +
                carrierAmount(exchange.calcium, mass_megagrams) +
                carrierAmount(exchange.magnesium, mass_megagrams) +
                carrierAmount(exchange.sodium, mass_megagrams) +
                carrierAmount(exchange.potassium, mass_megagrams) +
                carrierAmount(carboxyl_hydrogen, mass_megagrams);
            try element_moles.add(.{
                .aluminum = carrierAmount(exchange.aluminum, mass_megagrams),
                .iron = carrierAmount(exchange.iron, mass_megagrams),
                .calcium = carrierAmount(exchange.calcium, mass_megagrams),
                .magnesium = carrierAmount(exchange.magnesium, mass_megagrams),
                .sodium = carrierAmount(exchange.sodium, mass_megagrams),
                .potassium = carrierAmount(exchange.potassium, mass_megagrams),
            });
            const pending_exchange = chemistry.pending_cation_exchange_mol[profile_cell];
            const pending_carboxyl_hydrogen = chemistry.pending_carboxyl_bound_hydrogen_mol[profile_cell];
            try group_support.validateFiniteNonnegativeStruct(pending_exchange);
            if (!std.math.isFinite(pending_carboxyl_hydrogen) or pending_carboxyl_hydrogen < 0)
                return error.InvalidProfileMineralIonState;
            result.ion_inventory_mol += pending_exchange.hydrogen + pending_exchange.aluminum +
                pending_exchange.iron + pending_exchange.calcium + pending_exchange.magnesium +
                pending_exchange.sodium + pending_exchange.potassium + pending_carboxyl_hydrogen;
            try element_moles.add(.{
                .aluminum = pending_exchange.aluminum,
                .iron = pending_exchange.iron,
                .calcium = pending_exchange.calcium,
                .magnesium = pending_exchange.magnesium,
                .sodium = pending_exchange.sodium,
                .potassium = pending_exchange.potassium,
            });

            const solids = chemistry.geochemistry_solids[profile_cell];
            try group_support.validateFiniteNonnegativeStruct(solids);
            const extensive_solids = extensiveGeochemistrySolids(solids, water_m3);
            result.ion_inventory_mol +=
                geochemistrySolidIonAtoms(extensive_solids);
            try element_moles.add(
                geochemistrySolidElements(extensive_solids),
            );
            result.carbon_dioxide_carbon_g +=
                extensive_solids.calcite_solid_mol_per_m3 * carbon_g_per_mol;
            const pending_solids = chemistry.pending_geochemistry_solids_mol[profile_cell];
            try group_support.validateFiniteNonnegativeStruct(pending_solids);
            result.ion_inventory_mol += geochemistrySolidIonAtoms(pending_solids);
            try element_moles.add(geochemistrySolidElements(pending_solids));
            result.carbon_dioxide_carbon_g +=
                pending_solids.calcite_solid_mol_per_m3 * carbon_g_per_mol;

            const pending = pending_fertilizer.soil[profile_cell];
            try group_support.validateFiniteNonnegativeStruct(pending);
            const pending_phosphate_g = phosphorus_g_per_mol *
                (2 * (pending.broadcast_monocalcium_phosphate_mol +
                    pending.banded_monocalcium_phosphate_mol) +
                    3 * pending.hydroxyapatite_mol);
            // TEMP_DIAGNOSTIC (`issue-099`): the census's own read. The deposit
            // is confirmed to write 8.064516129032258e-2 mol of banded
            // monocalcium phosphate to `soil[2]` at hour 3,275, and this line
            // reads `soil[profile_cell]` with the identical index expression --
            // yet the cell census reports scope 2's phosphorus rising by only
            // 1.185e-4 instead of 5.0 g. Six static mechanisms were checked and
            // all were correct, so this is the one unobserved value.
            if (!@import("builtin").is_test and pending.banded_monocalcium_phosphate_mol != 0) std.log.err(
                "TEMP_DIAGNOSTIC census_read: profile_cell={d} cell={d} layer={d} banded_mol={e} pending_phosphate_g={e}",
                .{ profile_cell, cell, layer, pending.banded_monocalcium_phosphate_mol, pending_phosphate_g },
            );
            result.phosphate_phosphorus_g += pending_phosphate_g;
            result.ion_inventory_mol += pendingMineralIonAtoms(pending);
            try element_moles.add(pendingMineralElements(pending));
            result.carbon_dioxide_carbon_g +=
                pending.calcite_mol * carbon_g_per_mol;
        }
    }
    try group_support.addElementMoles(&result, try element_moles.finish());
    try result.validate();
    return result;
}

fn inventoryFractionsAt(source: anytype, profile_cell: usize) !zone_classification.ZoneFractions {
    if (comptime @TypeOf(source) == zone_classification.ZoneFractions) return source;
    return source.scienceZoneFractionsForFlatIndex(profile_cell);
}

pub const IonSubcomponents = struct {
    dissolved_aqueous_mol: f64 = 0,
    immobile_phosphate_ion_mol: f64 = 0,
    cation_exchange_mol: f64 = 0,
    geochemistry_solids_mol: f64 = 0,
    pending_fertilizer_ion_mol: f64 = 0,
};

/// Diagnostic-only decomposition of `aggregateProfilePhosphorusAndIons`'s
/// `ion_inventory_mol` into its five source pools. Added for
/// EXEC-SALT-SENESCENCE-LEDGER-001's day-1 non-closure investigation to
/// isolate which sub-pool carries the hourly climb. Mirrors the ion terms of
/// `aggregateProfilePhosphorusAndIons` exactly; not wired into any production
/// balance and not itself an authoritative EXEC total.
pub fn debugIonSubcomponents(
    grid: *const grid_module.GridState,
    micropore: *const solute_transport.State,
    macropore: *const solute_transport.State,
    chemistry: *const soil_chemistry.State,
    pending_fertilizer: *const mineral_fertilizer.State,
    soil_water_m3: []const f64,
    soil_mass_megagrams: []const f64,
    fractions_source: anytype,
    cell_area_m2: []const f64,
) !IonSubcomponents {
    if (cell_area_m2.len != grid.cell_count)
        return error.ProfilePhosphorusIonInventoryDimensionMismatch;
    var result: IonSubcomponents = .{};
    for (0..grid.cell_count) |cell| {
        const active_layers = grid.active_soil_layer_count[cell];
        if (active_layers > grid.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        if (!std.math.isFinite(cell_area_m2[cell]) or cell_area_m2[cell] < 0)
            return error.InvalidLandscapeCellArea;
        const negligible_water_volume_m3 = legacyNegligibleWaterVolumeM3(cell_area_m2[cell]);
        for (0..active_layers) |layer| {
            const profile_cell = cell * grid.soil_layer_capacity + layer;
            const fractions = try inventoryFractionsAt(fractions_source, profile_cell);
            const water_m3 = try aqueousCarrierM3(
                soil_water_m3[profile_cell],
                chemistry.dry_reference_water_m3[profile_cell],
                negligible_water_volume_m3,
            );
            const mass_megagrams = soil_mass_megagrams[profile_cell];

            const matrix_amounts = try micropore.cellAmountsConst(profile_cell);
            const macro_amounts = try macropore.cellAmountsConst(profile_cell);
            inline for (@typeInfo(solute_species.AqueousSpecies).@"enum".fields) |field| {
                const species: solute_species.AqueousSpecies = @enumFromInt(field.value);
                const amount_mol = matrix_amounts[field.value] + macro_amounts[field.value];
                result.dissolved_aqueous_mol += amount_mol * aqueousIonAtomCount(species);
            }

            const non_band = chemistry.non_band_phosphate[profile_cell];
            const band = chemistry.band_phosphate[profile_cell];
            const immobile_non_band =
                phosphateImmobileInventory(non_band, water_m3, mass_megagrams, fractions.phosphate_non_band);
            const immobile_band =
                phosphateImmobileInventory(band, water_m3, mass_megagrams, fractions.phosphate_band);
            result.immobile_phosphate_ion_mol +=
                immobile_non_band.ion_mol + immobile_band.ion_mol;
            result.immobile_phosphate_ion_mol +=
                phosphateImmobileInventory(chemistry.pending_non_band_phosphate_mol[profile_cell], 1, 1, 1).ion_mol +
                phosphateImmobileInventory(chemistry.pending_band_phosphate_mol[profile_cell], 1, 1, 1).ion_mol;

            const exchange = chemistry.cation_exchange_mol_per_megagram[profile_cell];
            const carboxyl_hydrogen =
                chemistry.carboxyl_bound_hydrogen_mol_per_megagram[profile_cell];
            result.cation_exchange_mol +=
                carrierAmount(exchange.hydrogen, mass_megagrams) +
                carrierAmount(exchange.aluminum, mass_megagrams) +
                carrierAmount(exchange.iron, mass_megagrams) +
                carrierAmount(exchange.calcium, mass_megagrams) +
                carrierAmount(exchange.magnesium, mass_megagrams) +
                carrierAmount(exchange.sodium, mass_megagrams) +
                carrierAmount(exchange.potassium, mass_megagrams) +
                carrierAmount(carboxyl_hydrogen, mass_megagrams);
            const pending_exchange = chemistry.pending_cation_exchange_mol[profile_cell];
            result.cation_exchange_mol += pending_exchange.hydrogen + pending_exchange.aluminum +
                pending_exchange.iron + pending_exchange.calcium + pending_exchange.magnesium +
                pending_exchange.sodium + pending_exchange.potassium +
                chemistry.pending_carboxyl_bound_hydrogen_mol[profile_cell];

            const solids = chemistry.geochemistry_solids[profile_cell];
            result.geochemistry_solids_mol +=
                geochemistrySolidIonAtoms(extensiveGeochemistrySolids(solids, water_m3));
            result.geochemistry_solids_mol +=
                geochemistrySolidIonAtoms(chemistry.pending_geochemistry_solids_mol[profile_cell]);

            const pending = pending_fertilizer.soil[profile_cell];
            result.pending_fertilizer_ion_mol += pendingMineralIonAtoms(pending);
        }
    }
    return result;
}

/// Diagnostic-only per-species decomposition of `dissolved_aqueous_mol`
/// (one entry per `AqueousSpecies`), for EXEC-SALT-SENESCENCE-LEDGER-001's
/// investigation into which specific dissolved species carries the day-1
/// ion non-closure. Mirrors `debugIonSubcomponents`'s aqueous loop exactly;
/// not wired into any production balance.
pub fn debugDissolvedAqueousPerSpecies(
    grid: *const grid_module.GridState,
    micropore: *const solute_transport.State,
    macropore: *const solute_transport.State,
) ![solute_species.AqueousSpecies.count]f64 {
    var result: [solute_species.AqueousSpecies.count]f64 = @splat(0);
    for (0..grid.cell_count) |cell| {
        const active_layers = grid.active_soil_layer_count[cell];
        if (active_layers > grid.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        for (0..active_layers) |layer| {
            const profile_cell = cell * grid.soil_layer_capacity + layer;
            const matrix_amounts = try micropore.cellAmountsConst(profile_cell);
            const macro_amounts = try macropore.cellAmountsConst(profile_cell);
            inline for (@typeInfo(solute_species.AqueousSpecies).@"enum".fields) |field| {
                const species: solute_species.AqueousSpecies = @enumFromInt(field.value);
                const amount_mol = matrix_amounts[field.value] + macro_amounts[field.value];
                result[field.value] += amount_mol * aqueousIonAtomCount(species);
            }
        }
    }
    return result;
}

const ImmobilePhosphateInventory = struct {
    phosphorus_mol: f64,
    ion_mol: f64,
    elements: group_support.ElementMoles,
};

fn phosphateImmobileInventory(
    state: anytype,
    water_m3: f64,
    soil_mass_megagrams: f64,
    zone_fraction: f64,
) ImmobilePhosphateInventory {
    const soil_carrier = soil_mass_megagrams * zone_fraction;
    const water_carrier = water_m3 * zone_fraction;
    const adsorbed_hpo4 =
        carrierAmount(state.adsorbed_hpo4_mol_p_per_megagram, soil_carrier);
    const adsorbed_h2po4 =
        carrierAmount(state.adsorbed_h2po4_mol_p_per_megagram, soil_carrier);
    const aluminum_phosphate =
        carrierAmount(state.aluminum_phosphate_solid_mol_per_m3, water_carrier);
    const iron_phosphate =
        carrierAmount(state.iron_phosphate_solid_mol_per_m3, water_carrier);
    const dicalcium_phosphate =
        carrierAmount(state.dicalcium_phosphate_solid_mol_per_m3, water_carrier);
    const hydroxyapatite =
        carrierAmount(state.hydroxyapatite_solid_mol_per_m3, water_carrier);
    const monocalcium_phosphate =
        carrierAmount(state.monocalcium_phosphate_solid_mol_per_m3, water_carrier);
    return .{
        .phosphorus_mol = adsorbed_hpo4 + adsorbed_h2po4 +
            aluminum_phosphate + iron_phosphate + dicalcium_phosphate +
            3 * hydroxyapatite + 2 * monocalcium_phosphate,
        .ion_mol = carrierAmount(state.deprotonated_site_mol_per_megagram, soil_carrier) +
            2 * carrierAmount(state.hydroxyl_site_mol_per_megagram, soil_carrier) +
            3 * carrierAmount(state.protonated_site_mol_per_megagram, soil_carrier) +
            // REDIST profile `SSX` counts the exchange site together with
            // its adsorbed phosphate: XH1P/XH1PB are three pseudo-ions and
            // XH2P/XH2PB are four (`redist.f:7264-7272`).
            3 * adsorbed_hpo4 + 4 * adsorbed_h2po4 +
            2 * (aluminum_phosphate + iron_phosphate) +
            3 * dicalcium_phosphate +
            9 * hydroxyapatite + 7 * monocalcium_phosphate,
        .elements = .{
            .aluminum = aluminum_phosphate,
            .iron = iron_phosphate,
            .calcium = dicalcium_phosphate +
                5 * hydroxyapatite + monocalcium_phosphate,
        },
    };
}

fn carrierAmount(stored_value: f64, carrier: f64) f64 {
    return stored_value * carrier;
}

/// `ZERO2 = 1.0E-06` (`starts.f:94`), the legacy noise-floor literal that
/// `ZEROS2(NY,NX) = ZERO2 * DH(NY,NX) * DV(NY,NX)` (`starts.f:270`) scales by
/// the grid cell's horizontal footprint `DH*DV` (m2). This is the exact
/// literal `solute.f:610`'s `IF(VOLW(L,NY,NX).GT.ZEROS2(NY,NX))THEN` tests
/// `VOLW` (soil water content, m3) against. Legacy compares a footprint-area
/// quantity directly to a volume; that is deliberate, not a units bug -- it
/// keeps the floor proportional to how `VOLW` itself scales with cell size,
/// the same design `flux.zig:47-62`'s `minimum_layer_heat_capacity_megajoules_per_m2_k`
/// already uses for the analogous `STARTS 655` floor on the same degenerate
/// layers (see that file's `ZEROS/ZEROS2 threshold translation gap` note).
const legacy_negligible_water_volume_m3_per_m2: f64 =
    legacy_water_negligible_floor.legacy_negligible_water_volume_m3_per_m2;

/// `ZEROS2` scaled to one cell's actual horizontal footprint. issue-061:
/// delegates to the shared derivation in `core/legacy_water_negligible_floor.zig`
/// so every sibling site (`water_carrier_rebase.zig`,
/// `landscape_mass_inventory_surface.zig`, `metabolism_state_update.zig`)
/// agrees on the same literal and scaling instead of re-deriving it.
fn legacyNegligibleWaterVolumeM3(cell_area_m2: f64) f64 {
    return legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(cell_area_m2);
}

/// `solute.f:610` keeps extensive `Z*` when `VOLW <= ZEROS2`. issue-060: this
/// translation previously only substituted `dry_reference_water_m3` when
/// `live_water_m3` was EXACTLY `0` (`live_water_m3 > 0`), not when it merely
/// fell at or below the `ZEROS2` noise floor. A collapsed-but-nonzero water
/// content (observed at hour 2,894 during a heat-solver stagnation/recovery
/// episode: the same layer's total heat capacity had already fallen below
/// `flux.zig`'s analogous `STARTS 655` floor) multiplied roughly-unchanged
/// solid/mineral-precipitate concentrations by a near-zero carrier and
/// manufactured a large fake mass loss (90-99.996% of several elements'
/// per-cell pools) that the conservation gate correctly rejected. The fix
/// widens the substitution to `live_water_m3 <= negligible_water_volume_m3`,
/// matching legacy's `<=` (not `<`) comparison exactly, while leaving the
/// substitution itself (fall back to `dry_reference_water_m3`) unchanged from
/// what the exact-zero case already did.
fn aqueousCarrierM3(
    live_water_m3: f64,
    dry_reference_water_m3: f64,
    negligible_water_volume_m3: f64,
) !f64 {
    if (!std.math.isFinite(live_water_m3) or live_water_m3 < 0 or
        !std.math.isFinite(dry_reference_water_m3) or dry_reference_water_m3 < 0 or
        !std.math.isFinite(negligible_water_volume_m3) or negligible_water_volume_m3 < 0)
        return error.InvalidProfileChemistryGeometry;
    return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
}

fn extensiveGeochemistrySolids(state: anytype, water_m3: f64) @TypeOf(state) {
    var result = state;
    inline for (@typeInfo(@TypeOf(state)).@"struct".fields) |field|
        @field(result, field.name) = carrierAmount(@field(state, field.name), water_m3);
    return result;
}

fn geochemistrySolidElements(state: anytype) group_support.ElementMoles {
    const aluminum_silicate = state.aluminum_natural_silicate_mol_per_m3 +
        state.aluminum_ground_silicate_mol_per_m3;
    const iron_silicate = state.iron_natural_silicate_mol_per_m3 +
        state.iron_ground_silicate_mol_per_m3;
    const calcium_silicate = state.calcium_natural_silicate_mol_per_m3 +
        state.calcium_ground_silicate_mol_per_m3;
    const magnesium_silicate = state.magnesium_natural_silicate_mol_per_m3 +
        state.magnesium_ground_silicate_mol_per_m3;
    const sodium_silicate = state.sodium_natural_silicate_mol_per_m3 +
        state.sodium_ground_silicate_mol_per_m3;
    const potassium_silicate = state.potassium_natural_silicate_mol_per_m3 +
        state.potassium_ground_silicate_mol_per_m3;
    return .{
        .aluminum = state.gibbsite_solid_mol_per_m3 + aluminum_silicate,
        .iron = state.iron_hydroxide_solid_mol_per_m3 + iron_silicate,
        .calcium = state.calcite_solid_mol_per_m3 +
            state.gypsum_solid_mol_per_m3 + calcium_silicate,
        .magnesium = magnesium_silicate,
        .sodium = sodium_silicate,
        .potassium = potassium_silicate,
        .sulfur = state.gypsum_solid_mol_per_m3,
        // SOLUTE's silicate extents are metal-normalized. Their released
        // H4SiO4 coefficient is 3/4 for Al/Fe, 1/2 for Ca/Mg, and 1/4 for
        // Na/K; use those same formula coefficients for the solid inventory.
        .silicon = 0.75 * (aluminum_silicate + iron_silicate) +
            0.5 * (calcium_silicate + magnesium_silicate) +
            0.25 * (sodium_silicate + potassium_silicate),
    };
}

fn geochemistrySolidIonAtoms(state: anytype) f64 {
    return 4 * (state.gibbsite_solid_mol_per_m3 +
        state.iron_hydroxide_solid_mol_per_m3) +
        2 * (state.calcite_solid_mol_per_m3 +
            state.gypsum_solid_mol_per_m3) +
        state.aluminum_natural_silicate_mol_per_m3 +
        state.aluminum_ground_silicate_mol_per_m3 +
        state.iron_natural_silicate_mol_per_m3 +
        state.iron_ground_silicate_mol_per_m3 +
        state.calcium_natural_silicate_mol_per_m3 +
        state.calcium_ground_silicate_mol_per_m3 +
        state.magnesium_natural_silicate_mol_per_m3 +
        state.magnesium_ground_silicate_mol_per_m3 +
        state.sodium_natural_silicate_mol_per_m3 +
        state.sodium_ground_silicate_mol_per_m3 +
        state.potassium_natural_silicate_mol_per_m3 +
        state.potassium_ground_silicate_mol_per_m3;
}

fn pendingMineralIonAtoms(state: mineral_fertilizer.Inventory) f64 {
    return 7 * (state.broadcast_monocalcium_phosphate_mol +
        state.banded_monocalcium_phosphate_mol) +
        9 * state.hydroxyapatite_mol +
        2 * (state.calcite_mol + state.gypsum_mol) +
        state.aluminum_ground_silicate_mol +
        state.iron_ground_silicate_mol +
        state.calcium_ground_silicate_mol +
        state.magnesium_ground_silicate_mol +
        state.sodium_ground_silicate_mol +
        state.potassium_ground_silicate_mol;
}

/// Dry mineral fertilizer routed to litter remains outside the concentration
/// chemistry owner until water is available. It is nevertheless part of the
/// whole-landscape EXEC storage and must be counted exactly once.
pub fn aggregatePendingSurfaceMinerals(
    state: *const mineral_fertilizer.State,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !group_support.Storage {
    return aggregatePendingSurfaceMineralsRange(state, carbon_g_per_mol, phosphorus_g_per_mol, 0, state.cell_count);
}

fn pendingMineralElements(state: mineral_fertilizer.Inventory) group_support.ElementMoles {
    const monocalcium = state.broadcast_monocalcium_phosphate_mol +
        state.banded_monocalcium_phosphate_mol;
    return .{
        .aluminum = state.aluminum_ground_silicate_mol,
        .iron = state.iron_ground_silicate_mol,
        .calcium = monocalcium + 5 * state.hydroxyapatite_mol +
            state.calcite_mol + state.gypsum_mol +
            state.calcium_ground_silicate_mol,
        .magnesium = state.magnesium_ground_silicate_mol,
        .sodium = state.sodium_ground_silicate_mol,
        .potassium = state.potassium_ground_silicate_mol,
        .sulfur = state.gypsum_mol,
        .silicon = 0.75 * (state.aluminum_ground_silicate_mol +
            state.iron_ground_silicate_mol) +
            0.5 * (state.calcium_ground_silicate_mol +
                state.magnesium_ground_silicate_mol) +
            0.25 * (state.sodium_ground_silicate_mol +
                state.potassium_ground_silicate_mol),
    };
}

pub fn aggregatePendingSurfaceMineralsCell(
    state: *const mineral_fertilizer.State,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    cell: usize,
) !group_support.Storage {
    if (cell >= state.cell_count) return error.PendingSurfaceMineralInventoryCellOutOfBounds;
    return aggregatePendingSurfaceMineralsRange(state, carbon_g_per_mol, phosphorus_g_per_mol, cell, cell + 1);
}

fn aggregatePendingSurfaceMineralsRange(
    state: *const mineral_fertilizer.State,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    first_cell: usize,
    end_cell: usize,
) !group_support.Storage {
    if (state.cell_count == 0 or state.surface.len != state.cell_count)
        return error.PendingSurfaceMineralInventoryDimensionMismatch;
    inline for (.{ carbon_g_per_mol, phosphorus_g_per_mol }) |molar_mass|
        if (!std.math.isFinite(molar_mass) or molar_mass <= 0)
            return error.InvalidElementMolarMass;

    var result: group_support.Storage = .{};
    for (state.surface[first_cell..end_cell]) |pending| {
        try group_support.validateFiniteNonnegativeStruct(pending);
        result.phosphate_phosphorus_g += phosphorus_g_per_mol *
            (2 * (pending.broadcast_monocalcium_phosphate_mol +
                pending.banded_monocalcium_phosphate_mol) +
                3 * pending.hydroxyapatite_mol);
        result.carbon_dioxide_carbon_g +=
            pending.calcite_mol * carbon_g_per_mol;
        result.ion_inventory_mol += pendingMineralIonAtoms(pending);
        try group_support.addElementMoles(&result, pendingMineralElements(pending));
    }
    try result.validate();
    return result;
}

fn validatePhosphateFractions(
    fractions: zone_classification.ZoneFractions,
) !void {
    inline for (@typeInfo(zone_classification.ZoneFractions).@"struct".fields) |field| {
        const fraction = @field(fractions, field.name);
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
            return error.InvalidChemistryZoneFraction;
    }
    if (@abs(fractions.phosphate_non_band + fractions.phosphate_band - 1) >
        1e-12)
        return error.InvalidChemistryZoneFraction;
}

fn isPhosphateCarrier(species: solute_species.AqueousSpecies) bool {
    return solute_species.diffusivityClass(species) == .phosphate;
}

fn isCarbonateCarrier(species: solute_species.AqueousSpecies) bool {
    return switch (species) {
        .carbonate,
        .bicarbonate,
        .calcium_carbonate,
        .calcium_bicarbonate,
        .magnesium_carbonate,
        .magnesium_bicarbonate,
        .sodium_carbonate,
        => true,
        else => false,
    };
}

fn aqueousIonAtomCount(species: solute_species.AqueousSpecies) f64 {
    return solute_species.legacyIonCount(species);
}

test "phosphate immobile inventory excludes transported bare phosphate and retains REDIST adsorbed-site weights" {
    const phosphate_network = @import("../soil/solute/phosphate_network.zig");
    // Bare dissolved HPO4/H2PO4 are authoritative in the transport carrier;
    // counting them here would double-count storage after chemistry export.
    var hpo4_only = std.mem.zeroes(phosphate_network.State);
    hpo4_only.dissolved_hpo4_mol_p_per_m3 = 5;
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        phosphateImmobileInventory(hpo4_only, 1, 1, 1).ion_mol,
        1e-12,
    );

    var h2po4_only = std.mem.zeroes(phosphate_network.State);
    h2po4_only.dissolved_h2po4_mol_p_per_m3 = 5;
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        phosphateImmobileInventory(h2po4_only, 1, 1, 1).ion_mol,
        1e-12,
    );

    var adsorbed_hpo4_only = std.mem.zeroes(phosphate_network.State);
    adsorbed_hpo4_only.adsorbed_hpo4_mol_p_per_megagram = 5;
    try std.testing.expectApproxEqAbs(
        @as(f64, 3 * 5),
        phosphateImmobileInventory(adsorbed_hpo4_only, 1, 1, 1).ion_mol,
        1e-12,
    );

    var adsorbed_h2po4_only = std.mem.zeroes(phosphate_network.State);
    adsorbed_h2po4_only.adsorbed_h2po4_mol_p_per_megagram = 5;
    try std.testing.expectApproxEqAbs(
        @as(f64, 4 * 5),
        phosphateImmobileInventory(adsorbed_h2po4_only, 1, 1, 1).ion_mol,
        1e-12,
    );
}

test "issue-060: the legacy ZEROS2 translation is starts.f's ZERO2 literal, and the Ottawa deck's 1 m2 cell reduces it to 1.0e-6 m3" {
    // `starts.f:94`: `ZERO2=1.0E-06`. `starts.f:270`:
    // `ZEROS2(NY,NX)=ZERO2*DH(NY,NX)*DV(NY,NX)`.
    try std.testing.expectEqual(@as(f64, 1.0e-6), legacy_negligible_water_volume_m3_per_m2);
    // The Ottawa deck's site file (`f25si98`) gives every cell DH=DV=1.0 m
    // (also pinned independently at `flux.zig`'s hour-2725/2726 fixtures),
    // so ZEROS2 = 1.0e-6 * 1.0 * 1.0 = 1.0e-6 m3 for this deck.
    try std.testing.expectEqual(@as(f64, 1.0e-6), legacyNegligibleWaterVolumeM3(1.0));
    // A cell with a larger footprint gets a proportionally larger floor,
    // exactly mirroring how VOLW itself scales with cell size.
    try std.testing.expectEqual(@as(f64, 4.0e-6), legacyNegligibleWaterVolumeM3(4.0));
}

test "issue-060: BEFORE -- the old exact-zero guard manufactured a large fake mass loss for a collapsed-but-nonzero water carrier" {
    // Literal reproduction of the old guard this issue replaced
    // (`landscape_mass_inventory_phosphorus_ions.zig`'s `aqueousCarrierM3`
    // before this fix): `if (live_water_m3 > 0) live_water_m3 else
    // dry_reference_water_m3`. This is deliberately re-derived here, not
    // assumed, so the regression is a real before/after comparison.
    const oldAqueousCarrierM3 = struct {
        fn call(live_water_m3: f64, dry_reference_water_m3: f64) f64 {
            return if (live_water_m3 > 0) live_water_m3 else dry_reference_water_m3;
        }
    }.call;

    // A representative solid-mineral concentration (matching the order of
    // magnitude of hour 2,894's reported silicon pool, `before=100.136`).
    const concentration_mol_per_m3: f64 = 100;
    // The layer's normal, pre-collapse water content.
    const water_before_m3: f64 = 0.05;
    // A collapsed-but-nonzero water content, of the kind the hour-2,894
    // heat-solver stagnation/recovery episode produced: far below the
    // Ottawa deck's ZEROS2 floor (1.0e-6 m3) but not exactly zero.
    const water_after_collapsed_m3: f64 = 1e-9;

    const mass_before_mol = concentration_mol_per_m3 *
        oldAqueousCarrierM3(water_before_m3, water_before_m3);
    const mass_after_old_mol = concentration_mol_per_m3 *
        oldAqueousCarrierM3(water_after_collapsed_m3, water_before_m3);

    try std.testing.expectApproxEqAbs(@as(f64, 5), mass_before_mol, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-7), mass_after_old_mol, 1e-15);

    // No modeled process touched this mass (internal_production/consumption
    // are both zero in the real failure); the old guard alone manufactures a
    // >99.99% fake loss, matching the 90-99.996% collapses issue-060 logged.
    const fake_relative_loss = (mass_before_mol - mass_after_old_mol) / mass_before_mol;
    try std.testing.expect(fake_relative_loss > 0.9999);
}

test "issue-060: AFTER -- the ZEROS2-floored guard substitutes the stable reference and reports no manufactured loss" {
    const concentration_mol_per_m3: f64 = 100;
    const water_before_m3: f64 = 0.05;
    const water_after_collapsed_m3: f64 = 1e-9;
    const cell_area_m2: f64 = 1; // The Ottawa deck's actual per-cell footprint.
    const negligible_water_volume_m3 = legacyNegligibleWaterVolumeM3(cell_area_m2);

    const mass_before_mol = concentration_mol_per_m3 *
        try aqueousCarrierM3(water_before_m3, water_before_m3, negligible_water_volume_m3);
    const mass_after_new_mol = concentration_mol_per_m3 *
        try aqueousCarrierM3(water_after_collapsed_m3, water_before_m3, negligible_water_volume_m3);

    // The collapsed-but-nonzero carrier is at/below the floor, so the new
    // guard substitutes the same stable reference volume the exact-zero case
    // already used -- the extensive mass is unchanged, not manufactured-lost.
    try std.testing.expectEqual(mass_before_mol, mass_after_new_mol);
    try std.testing.expectApproxEqAbs(@as(f64, 5), mass_after_new_mol, 1e-12);
}

test "issue-060: the floored guard's boundary matches legacy's GT (not GE) comparison and preserves the exact-zero case" {
    const dry_reference_water_m3: f64 = 4;
    const negligible_water_volume_m3 = legacyNegligibleWaterVolumeM3(1.0);

    // Exactly at the floor takes the fallback (legacy `.GT.ZEROS2`, strict
    // greater-than, so equality does not count as "present").
    try std.testing.expectEqual(
        dry_reference_water_m3,
        try aqueousCarrierM3(negligible_water_volume_m3, dry_reference_water_m3, negligible_water_volume_m3),
    );
    // One ULP above the floor is treated as present water.
    const just_above = std.math.nextAfter(f64, negligible_water_volume_m3, std.math.inf(f64));
    try std.testing.expectEqual(
        just_above,
        try aqueousCarrierM3(just_above, dry_reference_water_m3, negligible_water_volume_m3),
    );
    // The pre-existing exact-zero case is unchanged: it was already below any
    // positive floor, so it still substitutes the reference volume.
    try std.testing.expectEqual(
        dry_reference_water_m3,
        try aqueousCarrierM3(0, dry_reference_water_m3, negligible_water_volume_m3),
    );
    // Ordinary, comfortably wet layers are unaffected by the floor.
    try std.testing.expectEqual(
        @as(f64, 0.05),
        try aqueousCarrierM3(0.05, dry_reference_water_m3, negligible_water_volume_m3),
    );
}

test "REDIST phosphate adsorption preserves the site plus aqueous pseudo-ion inventory" {
    const phosphate_network = @import("../soil/solute/phosphate_network.zig");

    var hydroxyl_site = std.mem.zeroes(phosphate_network.State);
    hydroxyl_site.hydroxyl_site_mol_per_megagram = 1;

    // SOLUTE RXH1P consumes one XOH1 and one aqueous HPO4 while producing
    // one XH1P and one aqueous OH (solute.f:2182,2206,2211,2213).
    var adsorbed_hpo4 = std.mem.zeroes(phosphate_network.State);
    adsorbed_hpo4.adsorbed_hpo4_mol_p_per_megagram = 1;
    const hpo4_before = phosphateImmobileInventory(hydroxyl_site, 1, 1, 1).ion_mol +
        aqueousIonAtomCount(.non_band_hpo4);
    const hpo4_after = phosphateImmobileInventory(adsorbed_hpo4, 1, 1, 1).ion_mol +
        aqueousIonAtomCount(.hydroxide);
    try std.testing.expectEqual(hpo4_before, hpo4_after);

    // SOLUTE RYH2P is the corresponding XOH1 + H2PO4 exchange and has the
    // same released-OH bookkeeping in ROH.
    var adsorbed_h2po4 = std.mem.zeroes(phosphate_network.State);
    adsorbed_h2po4.adsorbed_h2po4_mol_p_per_megagram = 1;
    const h2po4_before = phosphateImmobileInventory(hydroxyl_site, 1, 1, 1).ion_mol +
        aqueousIonAtomCount(.non_band_h2po4);
    const h2po4_after = phosphateImmobileInventory(adsorbed_h2po4, 1, 1, 1).ion_mol +
        aqueousIonAtomCount(.hydroxide);
    try std.testing.expectEqual(h2po4_before, h2po4_after);
}

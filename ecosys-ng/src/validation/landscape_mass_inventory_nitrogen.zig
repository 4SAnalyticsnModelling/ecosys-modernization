//! `landscape_mass_inventory` declarations: nitrogen.
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
const group_support = @import("landscape_mass_inventory_support.zig");

/// REDIST profile mineral-N inventory. Aqueous matrix and macropore amounts
/// are transport-owned extensive mol N; exchangeable ammonium is chemistry-
/// owned mol N/Mg soil; and undissolved fertilizer remains in its runtime
/// inventory until dissolution. Chemistry aqueous concentrations and plant-
/// available nutrient mirrors are intentionally not counted a second time.
pub fn aggregateProfileMineralNitrogen(
    grid: *const grid_module.GridState,
    transport: *const mineral_nitrogen.State,
    chemistry: *const soil_chemistry.State,
    fertilizer: *const nitrogen_fertilizer.State,
    soil_mass_megagrams: []const f64,
    fractions_source: anytype,
    nitrogen_g_per_mol: f64,
) !group_support.Storage {
    return aggregateProfileMineralNitrogenRange(
        grid,
        transport,
        chemistry,
        fertilizer,
        soil_mass_megagrams,
        fractions_source,
        nitrogen_g_per_mol,
        0,
        grid.cell_count,
        null,
    );
}

pub fn aggregateProfileMineralNitrogenCell(
    grid: *const grid_module.GridState,
    transport: *const mineral_nitrogen.State,
    chemistry: *const soil_chemistry.State,
    fertilizer: *const nitrogen_fertilizer.State,
    soil_mass_megagrams: []const f64,
    fractions_source: anytype,
    nitrogen_g_per_mol: f64,
    cell: usize,
) !group_support.Storage {
    if (cell >= grid.cell_count) return error.ProfileMineralNitrogenInventoryCellOutOfBounds;
    return aggregateProfileMineralNitrogenRange(
        grid,
        transport,
        chemistry,
        fertilizer,
        soil_mass_megagrams,
        fractions_source,
        nitrogen_g_per_mol,
        cell,
        cell + 1,
        null,
    );
}

pub fn aggregateProfileMineralNitrogenLayer(
    grid: *const grid_module.GridState,
    transport: *const mineral_nitrogen.State,
    chemistry: *const soil_chemistry.State,
    fertilizer: *const nitrogen_fertilizer.State,
    soil_mass_megagrams: []const f64,
    fractions_source: anytype,
    nitrogen_g_per_mol: f64,
    cell: usize,
    layer: usize,
) !group_support.Storage {
    if (cell >= grid.cell_count or layer >= grid.soil_layer_capacity)
        return error.ProfileMineralNitrogenInventoryCellOutOfBounds;
    return aggregateProfileMineralNitrogenRange(
        grid,
        transport,
        chemistry,
        fertilizer,
        soil_mass_megagrams,
        fractions_source,
        nitrogen_g_per_mol,
        cell,
        cell + 1,
        layer,
    );
}

fn aggregateProfileMineralNitrogenRange(
    grid: *const grid_module.GridState,
    transport: *const mineral_nitrogen.State,
    chemistry: *const soil_chemistry.State,
    fertilizer: *const nitrogen_fertilizer.State,
    soil_mass_megagrams: []const f64,
    fractions_source: anytype,
    nitrogen_g_per_mol: f64,
    first_cell: usize,
    end_cell: usize,
    local_layer_filter: ?usize,
) !group_support.Storage {
    if (grid.layer_count !=
        try std.math.mul(usize, grid.cell_count, grid.soil_layer_capacity) or
        grid.active_soil_layer_count.len != grid.cell_count or
        transport.cell_count != grid.layer_count or
        chemistry.cell_count != grid.layer_count or
        fertilizer.cell_count != grid.cell_count or
        fertilizer.layer_capacity != grid.soil_layer_capacity or
        fertilizer.soil.len != grid.layer_count or
        soil_mass_megagrams.len != grid.layer_count)
        return error.ProfileMineralNitrogenInventoryDimensionMismatch;
    if (!std.math.isFinite(nitrogen_g_per_mol) or nitrogen_g_per_mol <= 0)
        return error.InvalidNitrogenMolarMass;
    try transport.validate();

    var result: group_support.Storage = .{};
    for (first_cell..end_cell) |cell| {
        const active_layers = grid.active_soil_layer_count[cell];
        if (active_layers > grid.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const first_layer = if (local_layer_filter) |layer| @min(layer, active_layers) else 0;
        const end_layer = if (local_layer_filter) |layer| @min(layer + 1, active_layers) else active_layers;
        for (first_layer..end_layer) |layer| {
            const profile_cell = cell * grid.soil_layer_capacity + layer;
            const fractions = try inventoryFractionsAt(fractions_source, profile_cell);
            try validateInventoryFractions(fractions);
            const mass_megagrams = soil_mass_megagrams[profile_cell];
            if (!std.math.isFinite(mass_megagrams) or mass_megagrams < 0)
                return error.InvalidSoilMass;

            const matrix = try transport.matrix.cellAmountsConst(profile_cell);
            const macropore =
                try transport.macropore.cellAmountsConst(profile_cell);
            const ammonium_mol_n =
                nitrogenAmount(matrix, macropore, .ammonium_non_band) +
                nitrogenAmount(matrix, macropore, .ammonium_band) +
                nitrogenAmount(matrix, macropore, .ammonia_non_band) +
                nitrogenAmount(matrix, macropore, .ammonia_band);
            const nitrate_mol_n =
                nitrogenAmount(matrix, macropore, .nitrate_non_band) +
                nitrogenAmount(matrix, macropore, .nitrate_band) +
                nitrogenAmount(matrix, macropore, .nitrite_non_band) +
                nitrogenAmount(matrix, macropore, .nitrite_band);

            const exchange = chemistry.cation_exchange_mol_per_megagram[profile_cell];
            try group_support.validateFiniteNonnegativeStruct(exchange);
            const exchange_ammonium_mol_n =
                carrierAmount(exchange.ammonium_non_band, mass_megagrams * fractions.ammonium_non_band) +
                carrierAmount(exchange.ammonium_band, mass_megagrams * fractions.ammonium_band);
            const pending_exchange = chemistry.pending_cation_exchange_mol[profile_cell];
            try group_support.validateFiniteNonnegativeStruct(pending_exchange);
            const pending_exchange_ammonium_mol_n =
                pending_exchange.ammonium_non_band + pending_exchange.ammonium_band;

            const dry = fertilizer.soil[profile_cell];
            try group_support.validateFiniteNonnegativeStruct(dry);
            const dry_ammonium_mol_n =
                dry.broadcast_ammonium_mol_n +
                dry.broadcast_ammonia_mol_n +
                dry.broadcast_urea_mol_n +
                dry.banded_ammonium_mol_n +
                dry.banded_ammonia_mol_n +
                dry.banded_urea_mol_n;
            const dry_nitrate_mol_n =
                dry.broadcast_nitrate_mol_n + dry.banded_nitrate_mol_n;

            result.ammonium_nitrogen_g +=
                (ammonium_mol_n + exchange_ammonium_mol_n + pending_exchange_ammonium_mol_n +
                    dry_ammonium_mol_n) *
                nitrogen_g_per_mol;
            result.nitrate_nitrogen_g +=
                (nitrate_mol_n + dry_nitrate_mol_n) * nitrogen_g_per_mol;

            // Legacy TION atom-count convention: exchange NH4 and dry NH4
            // carry two atoms; dry NH3, urea, and nitrate carry one.
            result.ion_inventory_mol +=
                2 * (exchange_ammonium_mol_n + pending_exchange_ammonium_mol_n) +
                2 * (dry.broadcast_ammonium_mol_n +
                    dry.banded_ammonium_mol_n) +
                dry.broadcast_ammonia_mol_n +
                dry.broadcast_urea_mol_n +
                dry.broadcast_nitrate_mol_n +
                dry.banded_ammonia_mol_n +
                dry.banded_urea_mol_n +
                dry.banded_nitrate_mol_n;
        }
    }
    try result.validate();
    return result;
}

fn carrierAmount(stored_value: f64, carrier: f64) f64 {
    return stored_value * carrier;
}

fn inventoryFractionsAt(source: anytype, profile_cell: usize) !zone_classification.ZoneFractions {
    if (comptime @TypeOf(source) == zone_classification.ZoneFractions) return source;
    return source.scienceZoneFractionsForFlatIndex(profile_cell);
}

fn validateInventoryFractions(fractions: zone_classification.ZoneFractions) !void {
    inline for (std.meta.fields(zone_classification.ZoneFractions)) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidMineralNitrogenZoneFraction;
    }
    if (@abs(fractions.ammonium_non_band + fractions.ammonium_band - 1) >
        64 * std.math.floatEps(f64) or
        @abs(fractions.nitrate_non_band + fractions.nitrate_band - 1) >
            64 * std.math.floatEps(f64))
        return error.InvalidMineralNitrogenZoneFraction;
}

fn nitrogenAmount(
    matrix: []const f64,
    macropore: []const f64,
    species: mineral_nitrogen.Species,
) f64 {
    const species_index = @intFromEnum(species);
    return matrix[species_index] + macropore[species_index];
}

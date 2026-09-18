const std = @import("std");
const nutrient = @import("../../plant/root/plant_root_nutrient_uptake.zig");
const plant_root_system = @import("../../plant/root/plant_root_system.zig");
const GridState = @import("../../state/grid.zig").GridState;
const SoilCatalogEntry = @import("../profile/catalog.zig").Entry;
const SoilProperties = @import("../water/solver_properties.zig").State;
const OrganicInitializationState = @import("../organic/initialization.zig").State;
const SoluteChemistryState = @import("../solute/chemistry_state.zig").State;
const ZoneFractions = @import("../solute/charge_classification.zig").ZoneFractions;

fn validateZoneFractions(fractions: ZoneFractions) !void {
    inline for (@typeInfo(ZoneFractions).@"struct".fields) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidNutrientZoneFractions;
    }
    if (@abs(fractions.ammonium_non_band + fractions.ammonium_band - 1) > 1.0e-12 or
        @abs(fractions.nitrate_non_band + fractions.nitrate_band - 1) > 1.0e-12 or
        @abs(fractions.phosphate_non_band + fractions.phosphate_band - 1) > 1.0e-12) return error.InvalidNutrientZoneFractions;
}

pub const EquilibriumZoneWaterVolumes = struct {
    ammonium_non_band_m3: []const f64,
    ammonium_band_m3: []const f64,
    nitrate_non_band_m3: []const f64,
    nitrate_band_m3: []const f64,
    phosphate_non_band_m3: []const f64,
    phosphate_band_m3: []const f64,
};

pub const InitializationParameters = struct {
    initial_ammonium_band_fraction: f64,
    initial_nitrate_band_fraction: f64,
    initial_phosphate_band_fraction: f64,
    initial_h2po4_fraction: f64,
    initial_ammonium_band_row_spacing_m: f64,
    initial_nitrate_band_row_spacing_m: f64,
    initial_phosphate_band_row_spacing_m: f64,

    pub fn validate(self: InitializationParameters) !void {
        inline for (.{
            self.initial_ammonium_band_fraction,
            self.initial_nitrate_band_fraction,
            self.initial_phosphate_band_fraction,
            self.initial_h2po4_fraction,
        }) |value| if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidPlantAvailableNutrientInitialization;
        inline for (.{
            self.initial_ammonium_band_row_spacing_m,
            self.initial_nitrate_band_row_spacing_m,
            self.initial_phosphate_band_row_spacing_m,
        }) |value| if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidPlantAvailableNutrientInitialization;
    }
};

pub fn compatibilityInitializationParameters() InitializationParameters {
    // Retained only for isolated legacy-format diagnostics. Production
    // runscripts require explicit plant_nutrients geometry.
    return .{
        .initial_ammonium_band_fraction = 0,
        .initial_nitrate_band_fraction = 0,
        .initial_phosphate_band_fraction = 0,
        .initial_h2po4_fraction = 1,
        .initial_ammonium_band_row_spacing_m = 1,
        .initial_nitrate_band_row_spacing_m = 1,
        .initial_phosphate_band_row_spacing_m = 1,
    };
}

pub const DissolvedOrganicInitialization = struct {
    microbial_carbon_g_c: []const f64,
    nitrogen_to_carbon_g_n_per_g_c: []const f64,
    phosphorus_to_carbon_g_p_per_g_c: []const f64,
    carbon_allocation_fraction: []const f64,
    nitrogen_allocation_fraction: []const f64,
    phosphorus_allocation_fraction: []const f64,
    dissolved_fraction_of_microbial_carbon: []const f64,
};

/// Heap-owned extensive soil pools consumed or replenished by plant roots.
/// This state corresponds to the separate ZNH4S/ZNH4B/ZNO3S/ZNO3B,
/// H2PO4/H2POB/H1PO4/H1POB and OQC/OQN/OQP arrays in UPTAKE/NITRO.
pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    mineral_g_element: []f64,
    organic_carbon_g_c: []f64,
    organic_nitrogen_g_n: []f64,
    organic_phosphorus_g_p: []f64,
    organic_carbon_change_g_c_per_h: []f64,
    organic_nitrogen_change_g_n_per_h: []f64,
    organic_phosphorus_change_g_p_per_h: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.ZeroPlantAvailableNutrientLayers;
        const mineral_count = try std.math.mul(usize, layer_count, nutrient.nutrient_pool_count);
        const organic_count = try std.math.mul(usize, layer_count, plant_root_system.organic_substrate_count);
        const mineral = try allocator.alloc(f64, mineral_count);
        errdefer allocator.free(mineral);
        const carbon = try allocator.alloc(f64, organic_count);
        errdefer allocator.free(carbon);
        const nitrogen = try allocator.alloc(f64, organic_count);
        errdefer allocator.free(nitrogen);
        const phosphorus = try allocator.alloc(f64, organic_count);
        errdefer allocator.free(phosphorus);
        const carbon_change = try allocator.alloc(f64, organic_count);
        errdefer allocator.free(carbon_change);
        const nitrogen_change = try allocator.alloc(f64, organic_count);
        errdefer allocator.free(nitrogen_change);
        const phosphorus_change = try allocator.alloc(f64, organic_count);
        inline for (.{ mineral, carbon, nitrogen, phosphorus, carbon_change, nitrogen_change, phosphorus_change }) |values| @memset(values, 0);
        return .{ .allocator = allocator, .layer_count = layer_count, .mineral_g_element = mineral, .organic_carbon_g_c = carbon, .organic_nitrogen_g_n = nitrogen, .organic_phosphorus_g_p = phosphorus, .organic_carbon_change_g_c_per_h = carbon_change, .organic_nitrogen_change_g_n_per_h = nitrogen_change, .organic_phosphorus_change_g_p_per_h = phosphorus_change };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.organic_phosphorus_change_g_p_per_h);
        self.allocator.free(self.organic_nitrogen_change_g_n_per_h);
        self.allocator.free(self.organic_carbon_change_g_c_per_h);
        self.allocator.free(self.organic_phosphorus_g_p);
        self.allocator.free(self.organic_nitrogen_g_n);
        self.allocator.free(self.organic_carbon_g_c);
        self.allocator.free(self.mineral_g_element);
        self.* = undefined;
    }

    pub fn mineralPools(self: *State, layer: usize) ![]f64 {
        if (layer >= self.layer_count) return error.PlantAvailableNutrientLayerOutOfBounds;
        return self.mineral_g_element[layer * nutrient.nutrient_pool_count ..][0..nutrient.nutrient_pool_count];
    }

    pub fn organicIndex(self: State, layer: usize, substrate: usize) !usize {
        if (layer >= self.layer_count or substrate >= plant_root_system.organic_substrate_count) return error.PlantAvailableNutrientLayerOutOfBounds;
        return try std.math.add(usize, try std.math.mul(usize, layer, plant_root_system.organic_substrate_count), substrate);
    }

    pub fn resetHourlyChanges(self: *State) void {
        @memset(self.organic_carbon_change_g_c_per_h, 0);
        @memset(self.organic_nitrogen_change_g_n_per_h, 0);
        @memset(self.organic_phosphorus_change_g_p_per_h, 0);
    }

    /// Exact STARTS OQC/OQN/OQP transaction for the five organic substrate
    /// complexes. The caller supplies OSCM, CNOSCT/CPOSCT and FOSCI/N/P after
    /// the complete biomass/residue allocation has been evaluated. OQCK is a
    /// runtime slice instead of a DATA statement.
    pub fn initializeDissolvedOrganic(self: *State, inputs: DissolvedOrganicInitialization) !void {
        const count = self.organic_carbon_g_c.len;
        inline for (.{
            inputs.microbial_carbon_g_c,
            inputs.nitrogen_to_carbon_g_n_per_g_c,
            inputs.phosphorus_to_carbon_g_p_per_g_c,
            inputs.carbon_allocation_fraction,
            inputs.nitrogen_allocation_fraction,
            inputs.phosphorus_allocation_fraction,
            inputs.dissolved_fraction_of_microbial_carbon,
        }) |values| if (values.len != count) return error.OrganicInitializationDimensionMismatch;

        for (0..count) |index| {
            const microbial_carbon = inputs.microbial_carbon_g_c[index];
            const nitrogen_to_carbon = inputs.nitrogen_to_carbon_g_n_per_g_c[index];
            const phosphorus_to_carbon = inputs.phosphorus_to_carbon_g_p_per_g_c[index];
            const carbon_allocation = inputs.carbon_allocation_fraction[index];
            const nitrogen_allocation = inputs.nitrogen_allocation_fraction[index];
            const phosphorus_allocation = inputs.phosphorus_allocation_fraction[index];
            const dissolved_fraction = inputs.dissolved_fraction_of_microbial_carbon[index];
            inline for (.{ microbial_carbon, nitrogen_to_carbon, phosphorus_to_carbon, carbon_allocation, nitrogen_allocation, phosphorus_allocation, dissolved_fraction }) |value| {
                if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicInitialization;
            }
            if (carbon_allocation > 1 or nitrogen_allocation > 1 or phosphorus_allocation > 1 or dissolved_fraction > 1) return error.InvalidOrganicInitialization;
            const carbon = @max(0.0, microbial_carbon * dissolved_fraction * carbon_allocation);
            const nitrogen = @max(0.0, carbon * nitrogen_to_carbon * nitrogen_allocation);
            const phosphorus = @max(0.0, carbon * phosphorus_to_carbon * phosphorus_allocation);
            if (!std.math.isFinite(carbon) or !std.math.isFinite(nitrogen) or !std.math.isFinite(phosphorus)) return error.NonFiniteOrganicInitialization;
            self.organic_carbon_g_c[index] = carbon;
            self.organic_nitrogen_g_n[index] = nitrogen;
            self.organic_phosphorus_g_p[index] = phosphorus;
        }
    }

    /// Publishes the completed STARTS OQC/OQN/OQP pools into the authoritative
    /// root-exchange inventory without retaining a dependency on input files.
    pub fn bindInitializedDissolvedOrganic(self: *State, initialized: *const OrganicInitializationState) !void {
        if (initialized.layer_count != self.layer_count or initialized.dissolved.len != self.organic_carbon_g_c.len) return error.OrganicInitializationDimensionMismatch;
        for (initialized.dissolved) |pool| inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p }) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicInitialization;
        };
        for (initialized.dissolved, 0..) |pool, index| {
            self.organic_carbon_g_c[index] = pool.carbon_g_c;
            self.organic_nitrogen_g_n[index] = pool.nitrogen_g_n;
            self.organic_phosphorus_g_p[index] = pool.phosphorus_g_p;
        }
    }

    /// `starte.f` lines 1443--1454 state_update after coupled chemistry convergence.
    /// Concentrations are mol element m-3; inventories are extensive g N/P.
    pub fn bindEquilibratedMineralPools(self: *State, chemistry: *const SoluteChemistryState, volumes: EquilibriumZoneWaterVolumes) !void {
        if (chemistry.cell_count != self.layer_count) return error.EquilibriumMineralDimensionMismatch;
        inline for (.{ volumes.ammonium_non_band_m3, volumes.ammonium_band_m3, volumes.nitrate_non_band_m3, volumes.nitrate_band_m3, volumes.phosphate_non_band_m3, volumes.phosphate_band_m3 }) |values| if (values.len != self.layer_count) return error.EquilibriumMineralDimensionMismatch;
        for (0..self.layer_count) |layer| {
            const aqueous = chemistry.aqueous[layer];
            const non_band_phosphate = chemistry.non_band_phosphate[layer];
            const band_phosphate = chemistry.band_phosphate[layer];
            inline for (.{
                aqueous.ammonium_non_band,
                aqueous.ammonium_band,
                aqueous.nitrate_non_band,
                aqueous.nitrate_band,
                non_band_phosphate.dissolved_h2po4_mol_p_per_m3,
                non_band_phosphate.dissolved_hpo4_mol_p_per_m3,
                band_phosphate.dissolved_h2po4_mol_p_per_m3,
                band_phosphate.dissolved_hpo4_mol_p_per_m3,
                volumes.ammonium_non_band_m3[layer],
                volumes.ammonium_band_m3[layer],
                volumes.nitrate_non_band_m3[layer],
                volumes.nitrate_band_m3[layer],
                volumes.phosphate_non_band_m3[layer],
                volumes.phosphate_band_m3[layer],
            }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidEquilibriumMineralState;
        }
        for (0..self.layer_count) |layer| {
            const aqueous = chemistry.aqueous[layer];
            const non_band_phosphate = chemistry.non_band_phosphate[layer];
            const band_phosphate = chemistry.band_phosphate[layer];
            const pools = try self.mineralPools(layer);
            pools[@intFromEnum(nutrient.NutrientPool.ammonium_nonband)] = aqueous.ammonium_non_band * volumes.ammonium_non_band_m3[layer] * 14.0;
            pools[@intFromEnum(nutrient.NutrientPool.ammonium_band)] = aqueous.ammonium_band * volumes.ammonium_band_m3[layer] * 14.0;
            pools[@intFromEnum(nutrient.NutrientPool.nitrate_nonband)] = aqueous.nitrate_non_band * volumes.nitrate_non_band_m3[layer] * 14.0;
            pools[@intFromEnum(nutrient.NutrientPool.nitrate_band)] = aqueous.nitrate_band * volumes.nitrate_band_m3[layer] * 14.0;
            pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_nonband)] = non_band_phosphate.dissolved_h2po4_mol_p_per_m3 * volumes.phosphate_non_band_m3[layer] * 31.0;
            pools[@intFromEnum(nutrient.NutrientPool.phosphate_h_nonband)] = non_band_phosphate.dissolved_hpo4_mol_p_per_m3 * volumes.phosphate_non_band_m3[layer] * 31.0;
            pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_band)] = band_phosphate.dissolved_h2po4_mol_p_per_m3 * volumes.phosphate_band_m3[layer] * 31.0;
            pools[@intFromEnum(nutrient.NutrientPool.phosphate_h_band)] = band_phosphate.dissolved_hpo4_mol_p_per_m3 * volumes.phosphate_band_m3[layer] * 31.0;
        }
    }

    pub fn refreshMineralPools(
        self: *State,
        chemistry: *const SoluteChemistryState,
        water_volume_m3: []const f64,
        fractions_source: anytype,
    ) !void {
        if (chemistry.cell_count != self.layer_count or water_volume_m3.len != self.layer_count) return error.EquilibriumMineralDimensionMismatch;
        for (water_volume_m3) |water| if (!std.math.isFinite(water) or water < 0) return error.InvalidEquilibriumMineralState;
        for (0..self.layer_count) |layer| {
            const fractions = try mineralFractionsAt(fractions_source, layer);
            try validateZoneFractions(fractions);
            const water = water_volume_m3[layer];
            const aqueous = chemistry.aqueous[layer];
            const non_band = chemistry.non_band_phosphate[layer];
            const band = chemistry.band_phosphate[layer];
            const pools = try self.mineralPools(layer);
            pools[@intFromEnum(nutrient.NutrientPool.ammonium_nonband)] = aqueous.ammonium_non_band * water * fractions.ammonium_non_band * 14;
            pools[@intFromEnum(nutrient.NutrientPool.ammonium_band)] = aqueous.ammonium_band * water * fractions.ammonium_band * 14;
            pools[@intFromEnum(nutrient.NutrientPool.nitrate_nonband)] = aqueous.nitrate_non_band * water * fractions.nitrate_non_band * 14;
            pools[@intFromEnum(nutrient.NutrientPool.nitrate_band)] = aqueous.nitrate_band * water * fractions.nitrate_band * 14;
            pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_nonband)] = non_band.dissolved_h2po4_mol_p_per_m3 * water * fractions.phosphate_non_band * 31;
            pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_band)] = band.dissolved_h2po4_mol_p_per_m3 * water * fractions.phosphate_band * 31;
            pools[@intFromEnum(nutrient.NutrientPool.phosphate_h_nonband)] = non_band.dissolved_hpo4_mol_p_per_m3 * water * fractions.phosphate_non_band * 31;
            pools[@intFromEnum(nutrient.NutrientPool.phosphate_h_band)] = band.dissolved_hpo4_mol_p_per_m3 * water * fractions.phosphate_band * 31;
        }
        try self.validateFinite();
    }

    pub fn publishMineralPools(
        self: *const State,
        chemistry: *SoluteChemistryState,
        water_volume_m3: []const f64,
        fractions_source: anytype,
    ) !void {
        if (chemistry.cell_count != self.layer_count or water_volume_m3.len != self.layer_count) return error.EquilibriumMineralDimensionMismatch;
        try self.validateFinite();
        for (0..self.layer_count) |layer| {
            const fractions = try mineralFractionsAt(fractions_source, layer);
            try validateZoneFractions(fractions);
            const water = water_volume_m3[layer];
            if (!std.math.isFinite(water) or water < 0) return error.InvalidEquilibriumMineralState;
            if (water == 0) continue;
            const pools = self.mineral_g_element[layer * nutrient.nutrient_pool_count ..][0..nutrient.nutrient_pool_count];
            inline for (.{
                .{ nutrient.NutrientPool.ammonium_nonband, fractions.ammonium_non_band },
                .{ nutrient.NutrientPool.ammonium_band, fractions.ammonium_band },
                .{ nutrient.NutrientPool.nitrate_nonband, fractions.nitrate_non_band },
                .{ nutrient.NutrientPool.nitrate_band, fractions.nitrate_band },
            }) |entry| if (entry[1] == 0 and pools[@intFromEnum(entry[0])] > 0) return error.NutrientMassInZeroVolumeZone;
            inline for (.{
                .{ nutrient.NutrientPool.phosphate_h2_nonband, fractions.phosphate_non_band },
                .{ nutrient.NutrientPool.phosphate_h_nonband, fractions.phosphate_non_band },
                .{ nutrient.NutrientPool.phosphate_h2_band, fractions.phosphate_band },
                .{ nutrient.NutrientPool.phosphate_h_band, fractions.phosphate_band },
            }) |entry| if (entry[1] == 0 and pools[@intFromEnum(entry[0])] > 0) return error.NutrientMassInZeroVolumeZone;
        }
        for (0..self.layer_count) |layer| {
            const fractions = try mineralFractionsAt(fractions_source, layer);
            const water = water_volume_m3[layer];
            if (water == 0) continue;
            const pools = self.mineral_g_element[layer * nutrient.nutrient_pool_count ..][0..nutrient.nutrient_pool_count];
            if (fractions.ammonium_non_band > 0) chemistry.aqueous[layer].ammonium_non_band = pools[@intFromEnum(nutrient.NutrientPool.ammonium_nonband)] / (water * fractions.ammonium_non_band * 14);
            if (fractions.ammonium_band > 0) chemistry.aqueous[layer].ammonium_band = pools[@intFromEnum(nutrient.NutrientPool.ammonium_band)] / (water * fractions.ammonium_band * 14);
            if (fractions.nitrate_non_band > 0) chemistry.aqueous[layer].nitrate_non_band = pools[@intFromEnum(nutrient.NutrientPool.nitrate_nonband)] / (water * fractions.nitrate_non_band * 14);
            if (fractions.nitrate_band > 0) chemistry.aqueous[layer].nitrate_band = pools[@intFromEnum(nutrient.NutrientPool.nitrate_band)] / (water * fractions.nitrate_band * 14);
            if (fractions.phosphate_non_band > 0) {
                chemistry.non_band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 = pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_nonband)] / (water * fractions.phosphate_non_band * 31);
                chemistry.non_band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 = pools[@intFromEnum(nutrient.NutrientPool.phosphate_h_nonband)] / (water * fractions.phosphate_non_band * 31);
            }
            if (fractions.phosphate_band > 0) {
                chemistry.band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 = pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_band)] / (water * fractions.phosphate_band * 31);
                chemistry.band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 = pools[@intFromEnum(nutrient.NutrientPool.phosphate_h_band)] / (water * fractions.phosphate_band * 31);
            }
        }
    }

    pub fn validateFinite(self: *const State) !void {
        inline for (.{ self.mineral_g_element, self.organic_carbon_g_c, self.organic_nitrogen_g_n, self.organic_phosphorus_g_p }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantAvailableNutrientState;
        inline for (.{ self.organic_carbon_change_g_c_per_h, self.organic_nitrogen_change_g_n_per_h, self.organic_phosphorus_change_g_p_per_h }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantAvailableNutrientChange;
    }

    /// STARTS initializes band volumes to zero. Extensive profile inputs are
    /// converted from g element per Mg soil using current runtime geometry.
    pub fn initializeMapped(self: *State, grid: *const GridState, properties: *const SoilProperties, catalog_entries: []const SoilCatalogEntry, catalog_index_by_cell: []const usize, parameters: InitializationParameters) !void {
        try parameters.validate();
        if (self.layer_count != grid.layer_count or properties.layer_count != grid.layer_count or catalog_index_by_cell.len != grid.cell_count) return error.PlantAvailableNutrientDimensionMismatch;
        @memset(self.mineral_g_element, 0);
        for (0..grid.cell_count) |cell| {
            const catalog_index = catalog_index_by_cell[cell];
            if (catalog_index >= catalog_entries.len) return error.SoilCatalogMapOutOfBounds;
            const profile = catalog_entries[catalog_index].profile;
            const material = catalog_entries[catalog_index].material;
            if (profile.total_layer_count != grid.active_soil_layer_count[cell]) return error.SoilLayerCountMismatch;
            const ammonium = material.initial_ammonium_g_per_megagram;
            const nitrate = profile.property(.nitrate_g_per_megagram);
            const phosphate = profile.property(.phosphate_g_per_megagram);
            for (0..profile.total_layer_count) |layer| {
                const layer_cell = try grid.layerIndex(cell, layer);
                const soil_mass_megagrams = properties.matrix_bulk_volume_m3[layer_cell] * properties.bulk_density_megagrams_per_m3[layer_cell];
                if (!std.math.isFinite(soil_mass_megagrams) or soil_mass_megagrams < 0) return error.InvalidSoilMassForNutrientInitialization;
                const pools = try self.mineralPools(layer_cell);
                const ammonium_total = ammonium[layer] * soil_mass_megagrams;
                const nitrate_total = nitrate[layer] * soil_mass_megagrams;
                const phosphate_total = phosphate[layer] * soil_mass_megagrams;
                inline for (.{ ammonium_total, nitrate_total, phosphate_total }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantAvailableNutrientInitialization;
                pools[@intFromEnum(nutrient.NutrientPool.ammonium_band)] = ammonium_total * parameters.initial_ammonium_band_fraction;
                pools[@intFromEnum(nutrient.NutrientPool.ammonium_nonband)] = ammonium_total - pools[@intFromEnum(nutrient.NutrientPool.ammonium_band)];
                pools[@intFromEnum(nutrient.NutrientPool.nitrate_band)] = nitrate_total * parameters.initial_nitrate_band_fraction;
                pools[@intFromEnum(nutrient.NutrientPool.nitrate_nonband)] = nitrate_total - pools[@intFromEnum(nutrient.NutrientPool.nitrate_band)];
                const phosphate_band = phosphate_total * parameters.initial_phosphate_band_fraction;
                const phosphate_nonband = phosphate_total - phosphate_band;
                pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_nonband)] = phosphate_nonband * parameters.initial_h2po4_fraction;
                pools[@intFromEnum(nutrient.NutrientPool.phosphate_h_nonband)] = phosphate_nonband - pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_nonband)];
                pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_band)] = phosphate_band * parameters.initial_h2po4_fraction;
                pools[@intFromEnum(nutrient.NutrientPool.phosphate_h_band)] = phosphate_band - pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_band)];
            }
        }
        try self.validateFinite();
    }
};

fn mineralFractionsAt(source: anytype, layer: usize) !ZoneFractions {
    if (comptime @TypeOf(source) == ZoneFractions) return source;
    return source.scienceZoneFractionsForFlatIndex(layer);
}

test "plant available nutrient pools use runtime layers and typed scientific extents" {
    var state = try State.init(std.testing.allocator, 11);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 11 * nutrient.nutrient_pool_count), state.mineral_g_element.len);
    try std.testing.expectEqual(@as(usize, 11 * plant_root_system.organic_substrate_count), state.organic_carbon_g_c.len);
    const index = try state.organicIndex(10, 4);
    state.organic_carbon_change_g_c_per_h[index] = -0.2;
    state.resetHourlyChanges();
    try std.testing.expectEqual(@as(f64, 0), state.organic_carbon_change_g_c_per_h[index]);
}

test "soil profile nutrient concentrations initialize extensive non-band masses" {
    const allocator = std.testing.allocator;
    const soil_profile = @import("../../state/soil_profile.zig");
    const fixture = try @import("../../core/test_fixtures.zig").soilProfileSource(allocator, @typeInfo(soil_profile.LayerProperty).@"enum".fields.len);
    defer allocator.free(fixture);
    var catalog = @import("../profile/catalog.zig").Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("soil", fixture, @import("../water/retention.zig").compatibilityParameters(), @import("../profile/derivation.zig").compatibilityParameters());
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 20 });
    var grid = try GridState.init(allocator, config);
    defer grid.deinit();
    try @import("../../driver/model_initialization.zig").initializeCellHydrology(&grid, 0, catalog.entries.items[0].hydrology_per_m2);
    var properties = try @import("../water/solver_properties.zig").State.initMapped(allocator, &grid, catalog.entries.items, &.{0}, &.{1}, &.{1}, @import("../water/solver_properties.zig").compatibilityParameters());
    defer properties.deinit();
    var state = try State.init(allocator, grid.layer_count);
    defer state.deinit();
    try state.initializeMapped(&grid, &properties, catalog.entries.items, &.{0}, compatibilityInitializationParameters());
    const pools = try state.mineralPools(0);
    const soil_mass = properties.matrix_bulk_volume_m3[0] * properties.bulk_density_megagrams_per_m3[0];
    const profile = catalog.entries.items[0].profile;
    try std.testing.expectApproxEqAbs(@max(@as(f64, 1), profile.property(.ammonium_g_per_megagram)[0]) * soil_mass, pools[@intFromEnum(nutrient.NutrientPool.ammonium_nonband)], 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0), pools[@intFromEnum(nutrient.NutrientPool.ammonium_band)]);
    try std.testing.expectApproxEqAbs(profile.property(.phosphate_g_per_megagram)[0] * soil_mass, pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_nonband)], 1.0e-12);
}

test "STARTS dissolved organic initialization preserves five runtime substrate classes" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    const count = 2 * plant_root_system.organic_substrate_count;
    const microbial_carbon = [_]f64{100} ** count;
    const nitrogen_to_carbon = [_]f64{0.1} ** count;
    const phosphorus_to_carbon = [_]f64{0.01} ** count;
    const allocation = [_]f64{1} ** count;
    const dissolved_fraction = [_]f64{0.005} ** count;
    try state.initializeDissolvedOrganic(.{
        .microbial_carbon_g_c = &microbial_carbon,
        .nitrogen_to_carbon_g_n_per_g_c = &nitrogen_to_carbon,
        .phosphorus_to_carbon_g_p_per_g_c = &phosphorus_to_carbon,
        .carbon_allocation_fraction = &allocation,
        .nitrogen_allocation_fraction = &allocation,
        .phosphorus_allocation_fraction = &allocation,
        .dissolved_fraction_of_microbial_carbon = &dissolved_fraction,
    });
    try std.testing.expectEqual(@as(usize, count), state.organic_carbon_g_c.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.organic_carbon_g_c[9], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), state.organic_nitrogen_g_n[9], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.005), state.organic_phosphorus_g_p[9], 1.0e-15);
}

test "STARTS profile organic matter splits particulate and humus C N P conservatively" {
    const masses = try @import("../organic/initialization.zig").profileOrganicComplexMasses(20, 2, 1200, 140, 1.5, 0.05, 0.005);
    try std.testing.expectApproxEqAbs(@as(f64, 3000), masses.particulate_carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 27000), masses.humus_carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 150), masses.particulate_nitrogen_g_n, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1650), masses.humus_nitrogen_g_n, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 15), masses.particulate_phosphorus_g_p, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 195), masses.humus_phosphorus_g_p, 1.0e-12);
}

test "completed STARTS dissolved pools bind to root exchange inventory" {
    var initialized = try OrganicInitializationState.init(std.testing.allocator, 3);
    defer initialized.deinit();
    for (initialized.dissolved, 0..) |*pool, index| pool.* = .{ .carbon_g_c = @floatFromInt(index), .nitrogen_g_n = 0.1 * @as(f64, @floatFromInt(index)), .phosphorus_g_p = 0.01 * @as(f64, @floatFromInt(index)) };
    var available = try State.init(std.testing.allocator, 3);
    defer available.deinit();
    try available.bindInitializedDissolvedOrganic(&initialized);
    try std.testing.expectEqual(initialized.dissolved[14].carbon_g_c, available.organic_carbon_g_c[14]);
    try std.testing.expectEqual(initialized.dissolved[14].nitrogen_g_n, available.organic_nitrogen_g_n[14]);
    try std.testing.expectEqual(initialized.dissolved[14].phosphorus_g_p, available.organic_phosphorus_g_p[14]);
}

test "converged STARTE concentrations publish exact band and non-band masses" {
    var chemistry = try SoluteChemistryState.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.aqueous[1].ammonium_non_band = 2;
    chemistry.aqueous[1].ammonium_band = 3;
    chemistry.aqueous[1].nitrate_non_band = 4;
    chemistry.aqueous[1].nitrate_band = 5;
    chemistry.non_band_phosphate[1].dissolved_h2po4_mol_p_per_m3 = 6;
    chemistry.non_band_phosphate[1].dissolved_hpo4_mol_p_per_m3 = 7;
    chemistry.band_phosphate[1].dissolved_h2po4_mol_p_per_m3 = 8;
    chemistry.band_phosphate[1].dissolved_hpo4_mol_p_per_m3 = 9;
    const volumes = [_]f64{ 0.1, 0.2 };
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    try state.bindEquilibratedMineralPools(&chemistry, .{
        .ammonium_non_band_m3 = &volumes,
        .ammonium_band_m3 = &volumes,
        .nitrate_non_band_m3 = &volumes,
        .nitrate_band_m3 = &volumes,
        .phosphate_non_band_m3 = &volumes,
        .phosphate_band_m3 = &volumes,
    });
    const pools = try state.mineralPools(1);
    try std.testing.expectApproxEqAbs(@as(f64, 2 * 0.2 * 14), pools[@intFromEnum(nutrient.NutrientPool.ammonium_nonband)], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7 * 0.2 * 31), pools[@intFromEnum(nutrient.NutrientPool.phosphate_h_nonband)], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 8 * 0.2 * 31), pools[@intFromEnum(nutrient.NutrientPool.phosphate_h2_band)], 1.0e-12);
}

test "hourly chemistry and root-available pools round trip without changing mass" {
    var chemistry = try SoluteChemistryState.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.aqueous[0].ammonium_non_band = 2;
    chemistry.aqueous[0].ammonium_band = 3;
    chemistry.aqueous[0].nitrate_non_band = 4;
    chemistry.aqueous[0].nitrate_band = 5;
    chemistry.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 6;
    chemistry.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 7;
    chemistry.band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 8;
    chemistry.band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 9;
    const fractions: ZoneFractions = .{ .ammonium_non_band = 0.75, .ammonium_band = 0.25, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.8, .phosphate_band = 0.2 };
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try state.refreshMineralPools(&chemistry, &.{2}, fractions);
    const initial = state.mineral_g_element[0..nutrient.nutrient_pool_count].*;
    @memset(std.mem.asBytes(&chemistry.aqueous[0]), 0);
    @memset(std.mem.asBytes(&chemistry.non_band_phosphate[0]), 0);
    @memset(std.mem.asBytes(&chemistry.band_phosphate[0]), 0);
    try state.publishMineralPools(&chemistry, &.{2}, fractions);
    try state.refreshMineralPools(&chemistry, &.{2}, fractions);
    for (initial, state.mineral_g_element) |expected, actual| try std.testing.expectApproxEqAbs(expected, actual, 1.0e-12);
}

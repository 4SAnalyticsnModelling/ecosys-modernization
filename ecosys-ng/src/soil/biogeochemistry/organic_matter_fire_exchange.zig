const std = @import("std");
const PlantSoilExchange = @import("../../plant/exchange/soil.zig");
const GasTransport = @import("../gas/transport.zig");
const PlantNutrients = @import("../nutrients/plant_available_nutrients.zig");
const NutrientUptake = @import("../../plant/root/plant_root_nutrient_uptake.zig");
const SoilOrganic = @import("../organic/initialization.zig");
const SoluteTransport = @import("../solute/transport.zig");
const SoluteSpecies = @import("../solute/transport_species.zig");
const SurfaceChemistry = @import("../../surface/litter_chemistry.zig");

pub const salt_species_count = 8;

pub const PhysicalTolerances = struct {
    carbon_g_c: f64,
    water_volume_m3: f64,

    fn validate(self: PhysicalTolerances) !void {
        inline for (.{ self.carbon_g_c, self.water_volume_m3 }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicMatterFireFinalization;
    }
};

/// Runtime layer ledger shared by litter, soil-organic, symbiont, storage, and
/// root fire producers before the common oxygen-limited product transaction.
pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    substrate_count: usize,
    unlimited_combustion_carbon_g_c: []f64,
    combusted_carbon_by_substrate_g_c: []f64,
    combusted_nitrogen_g_n: []f64,
    combusted_phosphorus_g_p: []f64,
    released_salt_mol: []f64,
    combustion_temperature_response: []f64,
    carbon_dioxide_emission_g_c: []f64,
    methane_emission_g_c: []f64,
    oxygen_consumption_g_o: []f64,
    /// Source ROGOX (trnsfr.f 1111/1292), the aerobic oxygen-limited part of
    /// oxygen_consumption_g_o, consumed separately by redist.f 4499/4837.
    oxygen_limited_uptake_g_o: []f64,
    /// Source RC4OX (trnsfr.f 1114--1116/1295--1297), methane oxidised by the
    /// residual oxygen, in g C. Its oxygen demand is this times 2.667.
    methane_combustion_g_c: []f64,
    charcoal_production_g_c: []f64,
    ammonium_production_g_n: []f64,
    gaseous_nitrogen_emission_g_n: []f64,
    phosphate_production_g_p: []f64,
    gaseous_phosphorus_emission_g_p: []f64,
    heat_release_megajoules: []f64,
    pending_surface_ammonium_mol_n: []f64,
    pending_surface_phosphate_mol_p: []f64,
    pending_surface_salt_mol: []f64,
    /// Current-hour shoot-fire return provenance. These are a strict subset
    /// of the persistent pending surface carriers above; manure uses the
    /// generic addSurfaceNutrients path and must not be conflated with fire.
    canopy_fire_surface_ammonium_mol_n: []f64,
    canopy_fire_surface_phosphate_mol_p: []f64,
    canopy_fire_surface_salt_mol: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize, substrate_count: usize) !State {
        if (layer_count == 0 or substrate_count == 0) return error.InvalidOrganicMatterFireLayerCount;
        var result: State = undefined;
        result.allocator = allocator;
        result.layer_count = layer_count;
        result.substrate_count = substrate_count;
        result.unlimited_combustion_carbon_g_c = try allocateZeroed(allocator, layer_count);
        errdefer allocator.free(result.unlimited_combustion_carbon_g_c);
        result.combusted_carbon_by_substrate_g_c = try allocateZeroed(allocator, try std.math.mul(usize, layer_count, substrate_count));
        errdefer allocator.free(result.combusted_carbon_by_substrate_g_c);
        result.combusted_nitrogen_g_n = try allocateZeroed(allocator, layer_count);
        errdefer allocator.free(result.combusted_nitrogen_g_n);
        result.combusted_phosphorus_g_p = try allocateZeroed(allocator, layer_count);
        errdefer allocator.free(result.combusted_phosphorus_g_p);
        result.released_salt_mol = try allocateZeroed(allocator, try std.math.mul(usize, layer_count, salt_species_count));
        errdefer allocator.free(result.released_salt_mol);
        inline for (.{
            "combustion_temperature_response",
            "carbon_dioxide_emission_g_c",
            "methane_emission_g_c",
            "oxygen_consumption_g_o",
            "oxygen_limited_uptake_g_o",
            "methane_combustion_g_c",
            "charcoal_production_g_c",
            "ammonium_production_g_n",
            "gaseous_nitrogen_emission_g_n",
            "phosphate_production_g_p",
            "gaseous_phosphorus_emission_g_p",
            "heat_release_megajoules",
        }) |field_name| {
            @field(result, field_name) = try allocateZeroed(allocator, layer_count);
            errdefer allocator.free(@field(result, field_name));
        }
        result.pending_surface_ammonium_mol_n = try allocateZeroed(allocator, layer_count);
        errdefer allocator.free(result.pending_surface_ammonium_mol_n);
        result.pending_surface_phosphate_mol_p = try allocateZeroed(allocator, layer_count);
        errdefer allocator.free(result.pending_surface_phosphate_mol_p);
        result.pending_surface_salt_mol = try allocateZeroed(allocator, try std.math.mul(usize, layer_count, salt_species_count));
        errdefer allocator.free(result.pending_surface_salt_mol);
        result.canopy_fire_surface_ammonium_mol_n = try allocateZeroed(allocator, layer_count);
        errdefer allocator.free(result.canopy_fire_surface_ammonium_mol_n);
        result.canopy_fire_surface_phosphate_mol_p = try allocateZeroed(allocator, layer_count);
        errdefer allocator.free(result.canopy_fire_surface_phosphate_mol_p);
        result.canopy_fire_surface_salt_mol = try allocateZeroed(allocator, try std.math.mul(usize, layer_count, salt_species_count));
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.canopy_fire_surface_salt_mol);
        self.allocator.free(self.canopy_fire_surface_phosphate_mol_p);
        self.allocator.free(self.canopy_fire_surface_ammonium_mol_n);
        self.allocator.free(self.pending_surface_salt_mol);
        self.allocator.free(self.pending_surface_phosphate_mol_p);
        self.allocator.free(self.pending_surface_ammonium_mol_n);
        inline for (.{
            "heat_release_megajoules",
            "gaseous_phosphorus_emission_g_p",
            "phosphate_production_g_p",
            "gaseous_nitrogen_emission_g_n",
            "ammonium_production_g_n",
            "charcoal_production_g_c",
            "oxygen_consumption_g_o",
            "oxygen_limited_uptake_g_o",
            "methane_combustion_g_c",
            "methane_emission_g_c",
            "carbon_dioxide_emission_g_c",
            "combustion_temperature_response",
        }) |field_name| self.allocator.free(@field(self, field_name));
        self.allocator.free(self.released_salt_mol);
        self.allocator.free(self.combusted_phosphorus_g_p);
        self.allocator.free(self.combusted_nitrogen_g_n);
        self.allocator.free(self.combusted_carbon_by_substrate_g_c);
        self.allocator.free(self.unlimited_combustion_carbon_g_c);
        self.* = undefined;
    }

    pub fn resetHourly(self: *State) void {
        @memset(self.unlimited_combustion_carbon_g_c, 0);
        @memset(self.combusted_carbon_by_substrate_g_c, 0);
        @memset(self.combusted_nitrogen_g_n, 0);
        @memset(self.combusted_phosphorus_g_p, 0);
        @memset(self.released_salt_mol, 0);
        @memset(self.combustion_temperature_response, 0);
        @memset(self.carbon_dioxide_emission_g_c, 0);
        @memset(self.methane_emission_g_c, 0);
        @memset(self.oxygen_consumption_g_o, 0);
        @memset(self.oxygen_limited_uptake_g_o, 0);
        @memset(self.methane_combustion_g_c, 0);
        @memset(self.charcoal_production_g_c, 0);
        @memset(self.ammonium_production_g_n, 0);
        @memset(self.gaseous_nitrogen_emission_g_n, 0);
        @memset(self.phosphate_production_g_p, 0);
        @memset(self.gaseous_phosphorus_emission_g_p, 0);
        @memset(self.heat_release_megajoules, 0);
        @memset(self.canopy_fire_surface_ammonium_mol_n, 0);
        @memset(self.canopy_fire_surface_phosphate_mol_p, 0);
        @memset(self.canopy_fire_surface_salt_mol, 0);
    }

    /// Adds any extensive surface ammonium/phosphate source to the persistent
    /// dry-surface inventory. The common finalizer dissolves it when litter
    /// water is available.
    pub fn addSurfaceNutrients(self: *State, cell: usize, ammonium_mol_n: f64, phosphate_mol_p: f64) !void {
        const next = try self.previewSurfaceNutrients(cell, ammonium_mol_n, phosphate_mol_p);
        self.pending_surface_ammonium_mol_n[cell] = next.ammonium_mol_n;
        self.pending_surface_phosphate_mol_p[cell] = next.phosphate_mol_p;
    }

    const SurfaceNutrientPreview = struct { ammonium_mol_n: f64, phosphate_mol_p: f64 };

    fn previewSurfaceNutrients(self: *const State, cell: usize, ammonium_mol_n: f64, phosphate_mol_p: f64) !SurfaceNutrientPreview {
        if (cell >= self.layer_count) return error.SurfaceNutrientCellOutOfBounds;
        if (!std.math.isFinite(ammonium_mol_n) or ammonium_mol_n < 0 or
            !std.math.isFinite(phosphate_mol_p) or phosphate_mol_p < 0)
            return error.InvalidSurfaceNutrientDeposition;
        const next_ammonium = self.pending_surface_ammonium_mol_n[cell] + ammonium_mol_n;
        const next_phosphate = self.pending_surface_phosphate_mol_p[cell] + phosphate_mol_p;
        if (!std.math.isFinite(next_ammonium) or !std.math.isFinite(next_phosphate))
            return error.NonFiniteSurfaceNutrientDeposition;
        return .{ .ammonium_mol_n = next_ammonium, .phosphate_mol_p = next_phosphate };
    }

    pub fn validateSurfaceNutrients(self: *const State, cell: usize, ammonium_mol_n: f64, phosphate_mol_p: f64) !void {
        _ = try self.previewSurfaceNutrients(cell, ammonium_mol_n, phosphate_mol_p);
    }

    /// Atomically records the shoot-fire subset while updating the common
    /// persistent dry-surface nutrient carrier.
    pub fn addCanopyFireSurfaceNutrients(self: *State, cell: usize, ammonium_mol_n: f64, phosphate_mol_p: f64) !void {
        const pending = try self.previewSurfaceNutrients(cell, ammonium_mol_n, phosphate_mol_p);
        const fire_ammonium = try checkedAdd(self.canopy_fire_surface_ammonium_mol_n[cell], ammonium_mol_n);
        const fire_phosphate = try checkedAdd(self.canopy_fire_surface_phosphate_mol_p[cell], phosphate_mol_p);
        if (fire_ammonium < 0 or fire_phosphate < 0) return error.InvalidSurfaceNutrientDeposition;
        self.pending_surface_ammonium_mol_n[cell] = pending.ammonium_mol_n;
        self.pending_surface_phosphate_mol_p[cell] = pending.phosphate_mol_p;
        self.canopy_fire_surface_ammonium_mol_n[cell] = fire_ammonium;
        self.canopy_fire_surface_phosphate_mol_p[cell] = fire_phosphate;
    }

    /// Adds an extensive surface salt source (e.g. shoot-fire combustion
    /// products) to the persistent dry-surface inventory, mirroring
    /// `addSurfaceNutrients`. The common finalizer (`finalizeSurfaceCell`)
    /// dissolves it into litter solution once litter water is available.
    pub fn addSurfaceSalts(self: *State, cell: usize, salts_mol: []const f64) !void {
        if (cell >= self.layer_count or salts_mol.len != salt_species_count) return error.OrganicMatterFireDimensionMismatch;
        var next: [salt_species_count]f64 = undefined;
        for (&next, salts_mol, 0..) |*amount, salt_mol, salt| {
            if (!std.math.isFinite(salt_mol) or salt_mol < 0) return error.InvalidOrganicMatterFirePool;
            amount.* = self.pending_surface_salt_mol[cell * salt_species_count + salt] + salt_mol;
            if (!std.math.isFinite(amount.*)) return error.NonFiniteOrganicMatterFireFinalization;
        }
        for (next, 0..) |amount, salt| self.pending_surface_salt_mol[cell * salt_species_count + salt] = amount;
    }

    /// Shoot-fire salt counterpart of addCanopyFireSurfaceNutrients.
    pub fn addCanopyFireSurfaceSalts(self: *State, cell: usize, salts_mol: []const f64) !void {
        if (cell >= self.layer_count or salts_mol.len != salt_species_count) return error.OrganicMatterFireDimensionMismatch;
        var next_pending: [salt_species_count]f64 = undefined;
        var next_fire: [salt_species_count]f64 = undefined;
        for (salts_mol, 0..) |salt_mol, salt| {
            if (!std.math.isFinite(salt_mol) or salt_mol < 0) return error.InvalidOrganicMatterFirePool;
            const index = cell * salt_species_count + salt;
            next_pending[salt] = try checkedAdd(self.pending_surface_salt_mol[index], salt_mol);
            next_fire[salt] = try checkedAdd(self.canopy_fire_surface_salt_mol[index], salt_mol);
            if (next_pending[salt] < 0 or next_fire[salt] < 0) return error.InvalidOrganicMatterFirePool;
        }
        for (0..salt_species_count) |salt| {
            const index = cell * salt_species_count + salt;
            self.pending_surface_salt_mol[index] = next_pending[salt];
            self.canopy_fire_surface_salt_mol[index] = next_fire[salt];
        }
    }

    /// Publishes the current EXTRACT shoot/standing-dead fire return before
    /// SOLUTE while leaving older dry-surface and NITRO/REDIST products in the
    /// common pending carrier. The per-hour canopy-fire arrays remain intact
    /// for the later conservation/accounting consumers; only their matching
    /// contribution is removed from `pending_surface_*`, so the REDIST
    /// finalizer cannot dissolve it a second time.
    pub fn publishCanopyFireSurfaceSolutes(
        self: *State,
        cell: usize,
        chemistry: *SurfaceChemistry.State,
        litter_water_m3: []const f64,
        dynamic_salts: bool,
        water_volume_tolerance_m3: f64,
    ) !void {
        if (cell >= self.layer_count or chemistry.cells.len != self.layer_count or
            litter_water_m3.len != self.layer_count)
            return error.OrganicMatterFireDimensionMismatch;
        if (!std.math.isFinite(water_volume_tolerance_m3) or water_volume_tolerance_m3 < 0)
            return error.InvalidOrganicMatterFireFinalization;
        const water_m3 = litter_water_m3[cell];
        if (!std.math.isFinite(water_m3) or water_m3 < 0)
            return error.InvalidOrganicMatterFireFinalization;
        if (water_m3 <= water_volume_tolerance_m3) return;

        const fire_ammonium = self.canopy_fire_surface_ammonium_mol_n[cell];
        const fire_phosphate = self.canopy_fire_surface_phosphate_mol_p[cell];
        const next_pending_ammonium = self.pending_surface_ammonium_mol_n[cell] - fire_ammonium;
        const next_pending_phosphate = self.pending_surface_phosphate_mol_p[cell] - fire_phosphate;
        inline for (.{ fire_ammonium, fire_phosphate, next_pending_ammonium, next_pending_phosphate }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.NonFiniteOrganicMatterFireFinalization;

        var next_pending_salts: [salt_species_count]f64 = undefined;
        for (&next_pending_salts, 0..) |*amount, salt| {
            const index = cell * salt_species_count + salt;
            const fire_salt = if (dynamic_salts) self.canopy_fire_surface_salt_mol[index] else 0;
            amount.* = self.pending_surface_salt_mol[index] - fire_salt;
            if (!std.math.isFinite(fire_salt) or fire_salt < 0 or
                !std.math.isFinite(amount.*) or amount.* < 0)
                return error.NonFiniteOrganicMatterFireFinalization;
        }

        var next_chemistry = chemistry.cells[cell];
        next_chemistry.ammonium_mol_per_m3 += fire_ammonium / water_m3;
        next_chemistry.h2po4_mol_p_per_m3 += fire_phosphate / water_m3;
        if (dynamic_salts) {
            next_chemistry.aluminum_mol_per_m3 += self.canopy_fire_surface_salt_mol[cell * salt_species_count + 0] / water_m3;
            next_chemistry.iron_mol_per_m3 += self.canopy_fire_surface_salt_mol[cell * salt_species_count + 1] / water_m3;
            next_chemistry.calcium_mol_per_m3 += self.canopy_fire_surface_salt_mol[cell * salt_species_count + 2] / water_m3;
            next_chemistry.magnesium_mol_per_m3 += self.canopy_fire_surface_salt_mol[cell * salt_species_count + 3] / water_m3;
            next_chemistry.sodium_mol_per_m3 += self.canopy_fire_surface_salt_mol[cell * salt_species_count + 4] / water_m3;
            next_chemistry.potassium_mol_per_m3 += self.canopy_fire_surface_salt_mol[cell * salt_species_count + 5] / water_m3;
            next_chemistry.sulfate_mol_per_m3 += self.canopy_fire_surface_salt_mol[cell * salt_species_count + 6] / water_m3;
            next_chemistry.chloride_mol_per_m3 += self.canopy_fire_surface_salt_mol[cell * salt_species_count + 7] / water_m3;
        }
        inline for (.{
            next_chemistry.ammonium_mol_per_m3, next_chemistry.h2po4_mol_p_per_m3,
            next_chemistry.aluminum_mol_per_m3, next_chemistry.iron_mol_per_m3,
            next_chemistry.calcium_mol_per_m3,  next_chemistry.magnesium_mol_per_m3,
            next_chemistry.sodium_mol_per_m3,   next_chemistry.potassium_mol_per_m3,
            next_chemistry.sulfate_mol_per_m3,  next_chemistry.chloride_mol_per_m3,
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.NonFiniteOrganicMatterFireFinalization;

        chemistry.cells[cell] = next_chemistry;
        self.pending_surface_ammonium_mol_n[cell] = next_pending_ammonium;
        self.pending_surface_phosphate_mol_p[cell] = next_pending_phosphate;
        for (next_pending_salts, 0..) |amount, salt|
            self.pending_surface_salt_mol[cell * salt_species_count + salt] = amount;
    }

    pub fn addCombustedPools(self: *State, layer: usize, carbon_g_c: f64, nitrogen_g_n: f64, phosphorus_g_p: f64, salts_mol: []const f64) !void {
        try self.addCombustedPoolsForSubstrate(layer, 0, carbon_g_c, nitrogen_g_n, phosphorus_g_p, salts_mol);
    }

    pub fn addCombustedPoolsForSubstrate(self: *State, layer: usize, substrate: usize, carbon_g_c: f64, nitrogen_g_n: f64, phosphorus_g_p: f64, salts_mol: []const f64) !void {
        try self.validateCombustedPoolsForSubstrate(layer, substrate, carbon_g_c, nitrogen_g_n, phosphorus_g_p, salts_mol);
        self.unlimited_combustion_carbon_g_c[layer] += carbon_g_c;
        const substrate_index = layer * self.substrate_count + substrate;
        self.combusted_carbon_by_substrate_g_c[substrate_index] += carbon_g_c;
        self.combusted_nitrogen_g_n[layer] += nitrogen_g_n;
        self.combusted_phosphorus_g_p[layer] += phosphorus_g_p;
        for (salts_mol, 0..) |salt_mol, salt|
            self.released_salt_mol[layer * salt_species_count + salt] += salt_mol;
    }

    pub fn validateCombustedPoolsForSubstrate(self: *const State, layer: usize, substrate: usize, carbon_g_c: f64, nitrogen_g_n: f64, phosphorus_g_p: f64, salts_mol: []const f64) !void {
        if (layer >= self.layer_count or substrate >= self.substrate_count or salts_mol.len != salt_species_count) return error.OrganicMatterFireDimensionMismatch;
        inline for (.{ carbon_g_c, nitrogen_g_n, phosphorus_g_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicMatterFirePool;
        for (salts_mol) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicMatterFirePool;
        _ = try checkedAdd(self.unlimited_combustion_carbon_g_c[layer], carbon_g_c);
        const substrate_index = layer * self.substrate_count + substrate;
        _ = try checkedAdd(self.combusted_carbon_by_substrate_g_c[substrate_index], carbon_g_c);
        _ = try checkedAdd(self.combusted_nitrogen_g_n[layer], nitrogen_g_n);
        _ = try checkedAdd(self.combusted_phosphorus_g_p[layer], phosphorus_g_p);
        for (salts_mol, 0..) |salt_mol, salt| {
            const index = layer * salt_species_count + salt;
            _ = try checkedAdd(self.released_salt_mol[index], salt_mol);
        }
    }

    /// Validates a complete no-salt organic state_update before its owner is
    /// mutated. NITRO combustion uses this to keep pool removal and the shared
    /// fire ledger one atomic C/N/P transaction.
    pub fn validateOrganicCombustionBySubstrate(self: *const State, layer: usize, carbon_g_c: []const f64, nitrogen_g_n: []const f64, phosphorus_g_p: []const f64) !void {
        if (layer >= self.layer_count or carbon_g_c.len != self.substrate_count or nitrogen_g_n.len != self.substrate_count or phosphorus_g_p.len != self.substrate_count)
            return error.OrganicMatterFireDimensionMismatch;
        var total_carbon_g_c: f64 = 0;
        var total_nitrogen_g_n: f64 = 0;
        var total_phosphorus_g_p: f64 = 0;
        for (carbon_g_c, nitrogen_g_n, phosphorus_g_p, 0..) |carbon, nitrogen, phosphorus, substrate| {
            inline for (.{ carbon, nitrogen, phosphorus }) |value|
                if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicMatterFirePool;
            _ = try checkedAdd(self.combusted_carbon_by_substrate_g_c[layer * self.substrate_count + substrate], carbon);
            total_carbon_g_c = try checkedAdd(total_carbon_g_c, carbon);
            total_nitrogen_g_n = try checkedAdd(total_nitrogen_g_n, nitrogen);
            total_phosphorus_g_p = try checkedAdd(total_phosphorus_g_p, phosphorus);
        }
        _ = try checkedAdd(self.unlimited_combustion_carbon_g_c[layer], total_carbon_g_c);
        _ = try checkedAdd(self.combusted_nitrogen_g_n[layer], total_nitrogen_g_n);
        _ = try checkedAdd(self.combusted_phosphorus_g_p[layer], total_phosphorus_g_p);
    }

    pub fn setCombustionTemperatureResponse(self: *State, layer: usize, response: f64) !void {
        if (layer >= self.layer_count) return error.OrganicMatterFireDimensionMismatch;
        if (!std.math.isFinite(response) or response < 0 or response > 1) return error.InvalidOrganicMatterFireTemperatureResponse;
        self.combustion_temperature_response[layer] = response;
    }

    /// Atomically publishes one combined NITRO+GROSUB layer transaction.
    pub fn finalizeLayer(self: *State, layer: usize, gas: *GasTransport.State, nutrients: *PlantNutrients.State, organic: *SoilOrganic.State, micropore_solutes: *SoluteTransport.State, dynamic_salts: bool, delayed_heat_megajoules: []f64, tolerances: PhysicalTolerances, parameters: PlantSoilExchange.SubsurfaceFireParameters) !void {
        if (layer >= self.layer_count or gas.cell_count != self.layer_count or nutrients.layer_count != self.layer_count or organic.layer_count != self.layer_count or micropore_solutes.cell_count != self.layer_count or micropore_solutes.species_count != SoluteSpecies.AqueousSpecies.count or delayed_heat_megajoules.len != self.layer_count or self.substrate_count != SoilOrganic.microbial_substrate_count) return error.OrganicMatterFireDimensionMismatch;
        try tolerances.validate();
        const oxygen_index = try GasTransport.massIndex(layer, .oxygen, gas.cell_count);
        const methane_index = try GasTransport.massIndex(layer, .methane, gas.cell_count);
        const carbon_dioxide_index = try GasTransport.massIndex(layer, .carbon_dioxide, gas.cell_count);
        const air_volume_m3 = gas.air_volume_m3[layer];
        if (!std.math.isFinite(air_volume_m3) or air_volume_m3 < 0) return error.InvalidOrganicMatterFireFinalization;
        const oxygen_content_g_o = gas.gaseous_mass_g[oxygen_index];
        const methane_content_g_c = gas.gaseous_mass_g[methane_index];
        if (!std.math.isFinite(oxygen_content_g_o) or oxygen_content_g_o < 0 or !std.math.isFinite(methane_content_g_c) or methane_content_g_c < 0) return error.InvalidOrganicMatterFireFinalization;
        const oxygen_concentration_g_o_per_m3 = if (air_volume_m3 > 0) oxygen_content_g_o / air_volume_m3 else 0;
        const methane_concentration_g_c_per_m3 = if (air_volume_m3 > 0) methane_content_g_c / air_volume_m3 else 0;
        const products = try PlantSoilExchange.subsurfaceOrganicMatterFire(
            self.unlimited_combustion_carbon_g_c[layer],
            tolerances.carbon_g_c,
            self.combustion_temperature_response[layer],
            oxygen_concentration_g_o_per_m3,
            oxygen_content_g_o,
            methane_concentration_g_c_per_m3,
            methane_content_g_c,
            parameters,
        );
        const ammonium_fraction = 0.1 + (0.5 - 0.1) * (1 - self.combustion_temperature_response[layer]);
        const phosphate_fraction = 0.7 + (0.9 - 0.7) * (1 - self.combustion_temperature_response[layer]);
        const ammonium_g_n = self.combusted_nitrogen_g_n[layer] * ammonium_fraction;
        const gaseous_nitrogen_g_n = self.combusted_nitrogen_g_n[layer] - ammonium_g_n;
        const phosphate_g_p = self.combusted_phosphorus_g_p[layer] * phosphate_fraction;
        const gaseous_phosphorus_g_p = self.combusted_phosphorus_g_p[layer] - phosphate_g_p;
        const ammonium_index = layer * NutrientUptake.nutrient_pool_count + @intFromEnum(NutrientUptake.NutrientPool.ammonium_nonband);
        const phosphate_index = layer * NutrientUptake.nutrient_pool_count + @intFromEnum(NutrientUptake.NutrientPool.phosphate_h2_nonband);
        const next_oxygen = oxygen_content_g_o - products.oxygen_consumed_g;
        const next_carbon_dioxide = gas.gaseous_mass_g[carbon_dioxide_index] + products.carbon_dioxide_emitted_g_carbon;
        const next_methane = methane_content_g_c + products.methane_emitted_g_carbon;
        const next_ammonium = nutrients.mineral_g_element[ammonium_index] + ammonium_g_n;
        const next_phosphate = nutrients.mineral_g_element[phosphate_index] + phosphate_g_p;
        const next_heat = delayed_heat_megajoules[layer] + products.heat_released_megajoules;
        inline for (.{ next_oxygen, next_carbon_dioxide, next_methane, next_ammonium, next_phosphate, next_heat }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteOrganicMatterFireFinalization;
        var next_charcoal_g_c: [SoilOrganic.substrate_count]f64 = undefined;
        for (&next_charcoal_g_c, 0..) |*next_charcoal, destination_substrate| {
            const structural_index = ((layer * SoilOrganic.substrate_count + destination_substrate) * SoilOrganic.structural_fraction_count) + SoilOrganic.structural_fraction_count - 1;
            next_charcoal.* = organic.structural[structural_index].carbon_g_c;
            if (!std.math.isFinite(next_charcoal.*) or next_charcoal.* < 0) return error.InvalidOrganicMatterFireFinalization;
        }
        if (self.unlimited_combustion_carbon_g_c[layer] > 0) {
            for (0..self.substrate_count) |source_substrate| {
                const destination_substrate = if (source_substrate < SoilOrganic.substrate_count) source_substrate else 1;
                const source_carbon = self.combusted_carbon_by_substrate_g_c[layer * self.substrate_count + source_substrate];
                next_charcoal_g_c[destination_substrate] += products.charcoal_produced_g_carbon * source_carbon / self.unlimited_combustion_carbon_g_c[layer];
            }
        }
        for (next_charcoal_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteOrganicMatterFireFinalization;
        const salt_destinations = [_]SoluteSpecies.AqueousSpecies{ .aluminum, .iron, .calcium, .magnesium, .sodium, .potassium, .sulfate, .chloride };
        var next_salt_mol: [salt_species_count]f64 = undefined;
        for (&next_salt_mol, salt_destinations, 0..) |*next_amount, species, salt| {
            const solute_index = layer * micropore_solutes.species_count + SoluteSpecies.index(species);
            const released = if (dynamic_salts) self.released_salt_mol[layer * salt_species_count + salt] else 0;
            next_amount.* = micropore_solutes.amount_mol[solute_index] + released;
            if (!std.math.isFinite(next_amount.*) or next_amount.* < 0) return error.NonFiniteOrganicMatterFireFinalization;
        }

        gas.gaseous_mass_g[oxygen_index] = next_oxygen;
        gas.gaseous_mass_g[carbon_dioxide_index] = next_carbon_dioxide;
        gas.gaseous_mass_g[methane_index] = next_methane;
        nutrients.mineral_g_element[ammonium_index] = next_ammonium;
        nutrients.mineral_g_element[phosphate_index] = next_phosphate;
        delayed_heat_megajoules[layer] = next_heat;
        for (next_charcoal_g_c, 0..) |charcoal, substrate| {
            const structural_index = ((layer * SoilOrganic.substrate_count + substrate) * SoilOrganic.structural_fraction_count) + SoilOrganic.structural_fraction_count - 1;
            organic.structural[structural_index].carbon_g_c = charcoal;
        }
        for (next_salt_mol, salt_destinations) |amount, species| {
            const solute_index = layer * micropore_solutes.species_count + SoluteSpecies.index(species);
            micropore_solutes.amount_mol[solute_index] = amount;
        }
        self.carbon_dioxide_emission_g_c[layer] = products.carbon_dioxide_emitted_g_carbon;
        self.methane_emission_g_c[layer] = products.methane_emitted_g_carbon;
        self.oxygen_consumption_g_o[layer] = products.oxygen_consumed_g;
        self.oxygen_limited_uptake_g_o[layer] = products.oxygen_limited_uptake_g;
        self.methane_combustion_g_c[layer] = products.methane_combustion_g_carbon;
        self.charcoal_production_g_c[layer] = products.charcoal_produced_g_carbon;
        self.ammonium_production_g_n[layer] = ammonium_g_n;
        self.gaseous_nitrogen_emission_g_n[layer] = gaseous_nitrogen_g_n;
        self.phosphate_production_g_p[layer] = phosphate_g_p;
        self.gaseous_phosphorus_emission_g_p[layer] = gaseous_phosphorus_g_p;
        self.heat_release_megajoules[layer] = products.heat_released_megajoules;
    }

    /// Atomically publishes the NITRO `L=0` fire products. Mineral products
    /// remain extensive while litter is dry and dissolve on the first wet
    /// hour, avoiding the silent mass loss caused by dividing through zero
    /// litter-water volume.
    pub fn finalizeSurfaceCell(
        self: *State,
        cell: usize,
        gas: *GasTransport.State,
        chemistry: *SurfaceChemistry.State,
        organic: *SoilOrganic.State,
        litter_water_m3: []const f64,
        dynamic_salts: bool,
        delayed_surface_heat_megajoules: []f64,
        tolerances: PhysicalTolerances,
        nitrogen_molar_mass_g_per_mol: f64,
        phosphorus_molar_mass_g_per_mol: f64,
        parameters: PlantSoilExchange.SubsurfaceFireParameters,
    ) !void {
        if (cell >= self.layer_count or gas.cell_count != self.layer_count or chemistry.cells.len != self.layer_count or organic.layer_count != self.layer_count or litter_water_m3.len != self.layer_count or delayed_surface_heat_megajoules.len != self.layer_count or self.substrate_count != SoilOrganic.microbial_substrate_count) return error.OrganicMatterFireDimensionMismatch;
        try tolerances.validate();
        inline for (.{ nitrogen_molar_mass_g_per_mol, phosphorus_molar_mass_g_per_mol }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidOrganicMatterFireFinalization;
        const water_m3 = litter_water_m3[cell];
        if (!std.math.isFinite(water_m3) or water_m3 < 0) return error.InvalidOrganicMatterFireFinalization;
        const oxygen_index = try GasTransport.massIndex(cell, .oxygen, gas.cell_count);
        const methane_index = try GasTransport.massIndex(cell, .methane, gas.cell_count);
        const carbon_dioxide_index = try GasTransport.massIndex(cell, .carbon_dioxide, gas.cell_count);
        const air_volume_m3 = gas.air_volume_m3[cell];
        const oxygen_g_o = gas.gaseous_mass_g[oxygen_index];
        const methane_g_c = gas.gaseous_mass_g[methane_index];
        if (!std.math.isFinite(air_volume_m3) or air_volume_m3 < 0 or !std.math.isFinite(oxygen_g_o) or oxygen_g_o < 0 or !std.math.isFinite(methane_g_c) or methane_g_c < 0) return error.InvalidOrganicMatterFireFinalization;
        const products = try PlantSoilExchange.subsurfaceOrganicMatterFire(
            self.unlimited_combustion_carbon_g_c[cell],
            tolerances.carbon_g_c,
            self.combustion_temperature_response[cell],
            if (air_volume_m3 > 0) oxygen_g_o / air_volume_m3 else 0,
            oxygen_g_o,
            if (air_volume_m3 > 0) methane_g_c / air_volume_m3 else 0,
            methane_g_c,
            parameters,
        );
        const ammonium_fraction = 0.1 + 0.4 * (1 - self.combustion_temperature_response[cell]);
        const phosphate_fraction = 0.7 + 0.2 * (1 - self.combustion_temperature_response[cell]);
        const ammonium_mol_n = self.combusted_nitrogen_g_n[cell] * ammonium_fraction / nitrogen_molar_mass_g_per_mol;
        const phosphate_mol_p = self.combusted_phosphorus_g_p[cell] * phosphate_fraction / phosphorus_molar_mass_g_per_mol;
        const next_pending_ammonium = self.pending_surface_ammonium_mol_n[cell] + ammonium_mol_n;
        const next_pending_phosphate = self.pending_surface_phosphate_mol_p[cell] + phosphate_mol_p;
        const next_oxygen = oxygen_g_o - products.oxygen_consumed_g;
        const next_carbon_dioxide = gas.gaseous_mass_g[carbon_dioxide_index] + products.carbon_dioxide_emitted_g_carbon;
        const next_methane = methane_g_c + products.methane_emitted_g_carbon;
        const next_heat = delayed_surface_heat_megajoules[cell] + products.heat_released_megajoules;
        inline for (.{ next_pending_ammonium, next_pending_phosphate, next_oxygen, next_carbon_dioxide, next_methane, next_heat }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteOrganicMatterFireFinalization;

        var next_charcoal_g_c: [SoilOrganic.substrate_count]f64 = undefined;
        for (&next_charcoal_g_c, 0..) |*amount, substrate| {
            const index = ((cell * SoilOrganic.substrate_count + substrate) * SoilOrganic.structural_fraction_count) + SoilOrganic.structural_fraction_count - 1;
            amount.* = organic.structural[index].carbon_g_c;
            if (!std.math.isFinite(amount.*) or amount.* < 0) return error.InvalidOrganicMatterFireFinalization;
        }
        if (self.unlimited_combustion_carbon_g_c[cell] > 0) for (0..self.substrate_count) |source_substrate| {
            const destination_substrate = if (source_substrate < SoilOrganic.substrate_count) source_substrate else 1;
            const source_carbon = self.combusted_carbon_by_substrate_g_c[cell * self.substrate_count + source_substrate];
            next_charcoal_g_c[destination_substrate] += products.charcoal_produced_g_carbon * source_carbon / self.unlimited_combustion_carbon_g_c[cell];
        };
        for (next_charcoal_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteOrganicMatterFireFinalization;

        var pending_salts: [salt_species_count]f64 = undefined;
        for (&pending_salts, 0..) |*amount, salt| {
            amount.* = self.pending_surface_salt_mol[cell * salt_species_count + salt] + if (dynamic_salts) self.released_salt_mol[cell * salt_species_count + salt] else 0;
            if (!std.math.isFinite(amount.*) or amount.* < 0) return error.NonFiniteOrganicMatterFireFinalization;
        }
        var next_chemistry = chemistry.cells[cell];
        if (water_m3 > tolerances.water_volume_m3) {
            next_chemistry.ammonium_mol_per_m3 += next_pending_ammonium / water_m3;
            next_chemistry.h2po4_mol_p_per_m3 += next_pending_phosphate / water_m3;
            if (dynamic_salts) {
                next_chemistry.aluminum_mol_per_m3 += pending_salts[0] / water_m3;
                next_chemistry.iron_mol_per_m3 += pending_salts[1] / water_m3;
                next_chemistry.calcium_mol_per_m3 += pending_salts[2] / water_m3;
                next_chemistry.magnesium_mol_per_m3 += pending_salts[3] / water_m3;
                next_chemistry.sodium_mol_per_m3 += pending_salts[4] / water_m3;
                next_chemistry.potassium_mol_per_m3 += pending_salts[5] / water_m3;
                next_chemistry.sulfate_mol_per_m3 += pending_salts[6] / water_m3;
                next_chemistry.chloride_mol_per_m3 += pending_salts[7] / water_m3;
            }
        }
        inline for (.{
            next_chemistry.ammonium_mol_per_m3, next_chemistry.h2po4_mol_p_per_m3,
            next_chemistry.aluminum_mol_per_m3, next_chemistry.iron_mol_per_m3,
            next_chemistry.calcium_mol_per_m3,  next_chemistry.magnesium_mol_per_m3,
            next_chemistry.sodium_mol_per_m3,   next_chemistry.potassium_mol_per_m3,
            next_chemistry.sulfate_mol_per_m3,  next_chemistry.chloride_mol_per_m3,
        }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteOrganicMatterFireFinalization;

        gas.gaseous_mass_g[oxygen_index] = next_oxygen;
        gas.gaseous_mass_g[carbon_dioxide_index] = next_carbon_dioxide;
        gas.gaseous_mass_g[methane_index] = next_methane;
        delayed_surface_heat_megajoules[cell] = next_heat;
        chemistry.cells[cell] = next_chemistry;
        self.pending_surface_ammonium_mol_n[cell] = if (water_m3 > tolerances.water_volume_m3) 0 else next_pending_ammonium;
        self.pending_surface_phosphate_mol_p[cell] = if (water_m3 > tolerances.water_volume_m3) 0 else next_pending_phosphate;
        for (pending_salts, 0..) |amount, salt| self.pending_surface_salt_mol[cell * salt_species_count + salt] = if (water_m3 > tolerances.water_volume_m3) 0 else amount;
        for (next_charcoal_g_c, 0..) |amount, substrate| {
            const index = ((cell * SoilOrganic.substrate_count + substrate) * SoilOrganic.structural_fraction_count) + SoilOrganic.structural_fraction_count - 1;
            organic.structural[index].carbon_g_c = amount;
        }
        self.carbon_dioxide_emission_g_c[cell] = products.carbon_dioxide_emitted_g_carbon;
        self.methane_emission_g_c[cell] = products.methane_emitted_g_carbon;
        self.oxygen_consumption_g_o[cell] = products.oxygen_consumed_g;
        self.oxygen_limited_uptake_g_o[cell] = products.oxygen_limited_uptake_g;
        self.methane_combustion_g_c[cell] = products.methane_combustion_g_carbon;
        self.charcoal_production_g_c[cell] = products.charcoal_produced_g_carbon;
        self.ammonium_production_g_n[cell] = ammonium_mol_n * nitrogen_molar_mass_g_per_mol;
        self.gaseous_nitrogen_emission_g_n[cell] = self.combusted_nitrogen_g_n[cell] - self.ammonium_production_g_n[cell];
        self.phosphate_production_g_p[cell] = phosphate_mol_p * phosphorus_molar_mass_g_per_mol;
        self.gaseous_phosphorus_emission_g_p[cell] = self.combusted_phosphorus_g_p[cell] - self.phosphate_production_g_p[cell];
        self.heat_release_megajoules[cell] = products.heat_released_megajoules;
    }
};

fn allocateZeroed(allocator: std.mem.Allocator, count: usize) ![]f64 {
    const values = try allocator.alloc(f64, count);
    @memset(values, 0);
    return values;
}

fn checkedAdd(left: f64, right: f64) !f64 {
    const result = left + right;
    if (!std.math.isFinite(result)) return error.NonFiniteOrganicMatterFireLedger;
    return result;
}

test "runtime fire ledger aggregates arbitrary layers and conserves C N P salts" {
    var state = try State.init(std.testing.allocator, 3, 6);
    defer state.deinit();
    try state.addCombustedPools(2, 4, 0.3, 0.04, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try state.addCombustedPools(2, 6, 0.7, 0.06, &.{ 8, 7, 6, 5, 4, 3, 2, 1 });
    try std.testing.expectEqual(@as(f64, 10), state.unlimited_combustion_carbon_g_c[2]);
    try std.testing.expectEqual(@as(f64, 1), state.combusted_nitrogen_g_n[2]);
    try std.testing.expectEqual(@as(f64, 0.1), state.combusted_phosphorus_g_p[2]);
    for (0..salt_species_count) |salt| try std.testing.expectEqual(@as(f64, 9), state.released_salt_mol[2 * salt_species_count + salt]);
    state.resetHourly();
    try std.testing.expectEqual(@as(f64, 0), state.unlimited_combustion_carbon_g_c[2]);
}

test "combined soil root fire finalization atomically conserves products" {
    var state = try State.init(std.testing.allocator, 1, 6);
    defer state.deinit();
    var gas = try GasTransport.State.init(std.testing.allocator, 1);
    defer gas.deinit();
    var nutrients = try PlantNutrients.State.init(std.testing.allocator, 1);
    defer nutrients.deinit();
    gas.air_volume_m3[0] = 10;
    gas.gaseous_mass_g[try GasTransport.massIndex(0, .oxygen, 1)] = 20;
    gas.gaseous_mass_g[try GasTransport.massIndex(0, .methane, 1)] = 0.1;
    try state.setCombustionTemperatureResponse(0, 0.4);
    try state.addCombustedPools(0, 10, 1, 0.2, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    var delayed_heat = [_]f64{0};
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var micropore_solutes = try SoluteTransport.State.init(std.testing.allocator, 1, SoluteSpecies.AqueousSpecies.count);
    defer micropore_solutes.deinit();
    try state.finalizeLayer(0, &gas, &nutrients, &organic, &micropore_solutes, true, &delayed_heat, .{ .carbon_g_c = 1e-12, .water_volume_m3 = 1e-12 }, .{
        .oxygen_half_saturation_g_o_per_m3 = 2.8,
        .methane_half_saturation_g_c_per_m3 = 0.005,
        .aerobic_combustion_energy_megajoules_per_g_carbon = 0.0375,
        .anaerobic_combustion_energy_megajoules_per_g_carbon = 0.0125,
        .methane_combustion_energy_megajoules_per_g_carbon = 0.0743,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 10), state.carbon_dioxide_emission_g_c[0] + state.methane_emission_g_c[0] + state.charcoal_production_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.ammonium_production_g_n[0] + state.gaseous_nitrogen_emission_g_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), state.phosphate_production_g_p[0] + state.gaseous_phosphorus_emission_g_p[0], 1e-12);
    try std.testing.expect(state.oxygen_consumption_g_o[0] <= 20);
    // ROGOX/RC4OX export: the parts must reconstruct the aggregate exactly, or
    // redist.f 4499/4837 would double count or lose oxygen against the same
    // gas debit finalizeLayer already applied.
    try std.testing.expectApproxEqAbs(
        state.oxygen_consumption_g_o[0],
        state.oxygen_limited_uptake_g_o[0] + state.methane_combustion_g_c[0] * 2.667,
        1e-12,
    );
    try std.testing.expect(state.oxygen_limited_uptake_g_o[0] >= 0);
    try std.testing.expect(state.methane_combustion_g_c[0] >= 0);
    // RC4OX is bounded by the methane actually present and by the oxygen left
    // after the aerobic branch: both source AMIN1 arms, checked independently.
    try std.testing.expect(state.methane_combustion_g_c[0] <= 0.1 + 1e-12);
    try std.testing.expect(state.methane_combustion_g_c[0] * 2.667 <= 20 - state.oxygen_limited_uptake_g_o[0] + 1e-12);
    try std.testing.expect(delayed_heat[0] > 0);
    const charcoal_index = SoilOrganic.structural_fraction_count - 1;
    try std.testing.expectApproxEqAbs(state.charcoal_production_g_c[0], organic.structural[charcoal_index].carbon_g_c, 1e-12);
    const salt_destinations = [_]SoluteSpecies.AqueousSpecies{ .aluminum, .iron, .calcium, .magnesium, .sodium, .potassium, .sulfate, .chloride };
    for (salt_destinations, 0..) |species, salt| try std.testing.expectEqual(@as(f64, @floatFromInt(salt + 1)), micropore_solutes.amount_mol[SoluteSpecies.index(species)]);
}

test "surface fire conserves products while dry and dissolves pending minerals when wetted" {
    var state = try State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer state.deinit();
    var gas = try GasTransport.State.init(std.testing.allocator, 1);
    defer gas.deinit();
    gas.air_volume_m3[0] = 10;
    const oxygen_index = try GasTransport.massIndex(0, .oxygen, 1);
    const methane_index = try GasTransport.massIndex(0, .methane, 1);
    const carbon_dioxide_index = try GasTransport.massIndex(0, .carbon_dioxide, 1);
    gas.gaseous_mass_g[oxygen_index] = 20;
    gas.gaseous_mass_g[methane_index] = 0.1;
    var chemistry = try SurfaceChemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var water_m3 = [_]f64{0};
    var delayed_heat_megajoules = [_]f64{0};
    try state.setCombustionTemperatureResponse(0, 0.4);
    try state.addCombustedPoolsForSubstrate(0, 2, 10, 1.4, 0.31, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const parameters: PlantSoilExchange.SubsurfaceFireParameters = .{
        .oxygen_half_saturation_g_o_per_m3 = 2.8,
        .methane_half_saturation_g_c_per_m3 = 0.005,
        .aerobic_combustion_energy_megajoules_per_g_carbon = 0.0375,
        .anaerobic_combustion_energy_megajoules_per_g_carbon = 0.0125,
        .methane_combustion_energy_megajoules_per_g_carbon = 0.0743,
    };
    try state.finalizeSurfaceCell(0, &gas, &chemistry, &organic, &water_m3, true, &delayed_heat_megajoules, .{ .carbon_g_c = 1e-12, .water_volume_m3 = 1e-12 }, 14, 31, parameters);
    try std.testing.expect(chemistry.cells[0].ammonium_mol_per_m3 == 0);
    try std.testing.expect(state.pending_surface_ammonium_mol_n[0] > 0);
    try std.testing.expect(state.pending_surface_phosphate_mol_p[0] > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 10), state.carbon_dioxide_emission_g_c[0] + state.methane_emission_g_c[0] + state.charcoal_production_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4), state.ammonium_production_g_n[0] + state.gaseous_nitrogen_emission_g_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.31), state.phosphate_production_g_p[0] + state.gaseous_phosphorus_emission_g_p[0], 1e-12);
    try std.testing.expect(gas.gaseous_mass_g[oxygen_index] >= 0);
    try std.testing.expect(gas.gaseous_mass_g[carbon_dioxide_index] > 0);
    try std.testing.expect(delayed_heat_megajoules[0] > 0);

    const pending_ammonium = state.pending_surface_ammonium_mol_n[0];
    const pending_phosphate = state.pending_surface_phosphate_mol_p[0];
    state.resetHourly();
    water_m3[0] = 2;
    // A carbon-unit tolerance larger than this water volume must not suppress
    // dissolution of the extensive pending mineral inventories.
    try state.finalizeSurfaceCell(0, &gas, &chemistry, &organic, &water_m3, true, &delayed_heat_megajoules, .{ .carbon_g_c = 10, .water_volume_m3 = 1e-12 }, 14, 31, parameters);
    try std.testing.expectApproxEqAbs(pending_ammonium / 2, chemistry.cells[0].ammonium_mol_per_m3, 1e-12);
    try std.testing.expectApproxEqAbs(pending_phosphate / 2, chemistry.cells[0].h2po4_mol_p_per_m3, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), state.pending_surface_ammonium_mol_n[0]);
    try std.testing.expectEqual(@as(f64, 0), state.pending_surface_phosphate_mol_p[0]);
    const salt_concentrations = [_]f64{
        chemistry.cells[0].aluminum_mol_per_m3,
        chemistry.cells[0].iron_mol_per_m3,
        chemistry.cells[0].calcium_mol_per_m3,
        chemistry.cells[0].magnesium_mol_per_m3,
        chemistry.cells[0].sodium_mol_per_m3,
        chemistry.cells[0].potassium_mol_per_m3,
        chemistry.cells[0].sulfate_mol_per_m3,
        chemistry.cells[0].chloride_mol_per_m3,
    };
    for (salt_concentrations, 1..) |concentration, expected| try std.testing.expectEqual(@as(f64, @floatFromInt(expected)) / 2, concentration);
}

test "EXTRACT canopy fire solutes publish before SOLUTE without replaying older pending products" {
    var state = try State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer state.deinit();
    var chemistry = try SurfaceChemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    const water_m3 = [_]f64{2};
    const older_salts = [_]f64{1} ** salt_species_count;
    const canopy_salts = [_]f64{2} ** salt_species_count;
    try state.addSurfaceNutrients(0, 5, 3);
    try state.addSurfaceSalts(0, &older_salts);
    try state.addCanopyFireSurfaceNutrients(0, 2, 1);
    try state.addCanopyFireSurfaceSalts(0, &canopy_salts);

    try state.publishCanopyFireSurfaceSolutes(0, &chemistry, &water_m3, true, 1e-12);

    try std.testing.expectEqual(@as(f64, 1), chemistry.cells[0].ammonium_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.5), chemistry.cells[0].h2po4_mol_p_per_m3);
    inline for (.{
        chemistry.cells[0].aluminum_mol_per_m3,
        chemistry.cells[0].iron_mol_per_m3,
        chemistry.cells[0].calcium_mol_per_m3,
        chemistry.cells[0].magnesium_mol_per_m3,
        chemistry.cells[0].sodium_mol_per_m3,
        chemistry.cells[0].potassium_mol_per_m3,
        chemistry.cells[0].sulfate_mol_per_m3,
        chemistry.cells[0].chloride_mol_per_m3,
    }) |concentration| try std.testing.expectEqual(@as(f64, 1), concentration);
    try std.testing.expectEqual(@as(f64, 5), state.pending_surface_ammonium_mol_n[0]);
    try std.testing.expectEqual(@as(f64, 3), state.pending_surface_phosphate_mol_p[0]);
    for (0..salt_species_count) |salt| {
        try std.testing.expectEqual(@as(f64, 1), state.pending_surface_salt_mol[salt]);
        try std.testing.expectEqual(@as(f64, 2), state.canopy_fire_surface_salt_mol[salt]);
    }
    try std.testing.expectEqual(@as(f64, 2), state.canopy_fire_surface_ammonium_mol_n[0]);
    try std.testing.expectEqual(@as(f64, 1), state.canopy_fire_surface_phosphate_mol_p[0]);
}

test "surface nutrient deposition persists extensive manure minerals without water" {
    var state = try State.init(std.testing.allocator, 2, SoilOrganic.substrate_count);
    defer state.deinit();
    try state.addSurfaceNutrients(1, 0.25, 0.125);
    try state.addSurfaceNutrients(1, 0.75, 0.375);
    try std.testing.expectEqual(@as(f64, 1), state.pending_surface_ammonium_mol_n[1]);
    try std.testing.expectEqual(@as(f64, 0.5), state.pending_surface_phosphate_mol_p[1]);
    try std.testing.expectError(error.InvalidSurfaceNutrientDeposition, state.addSurfaceNutrients(1, -1, 0));
    try std.testing.expectEqual(@as(f64, 1), state.pending_surface_ammonium_mol_n[1]);
}

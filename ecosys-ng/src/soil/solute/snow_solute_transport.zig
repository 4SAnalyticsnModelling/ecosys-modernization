const std = @import("std");
const dynamic_salt = @import("snowpack_internal_salt_aggregation.zig");
const transport_species = @import("transport_species.zig");

pub const SaltSpecies = dynamic_salt.SaltSpecies;
pub const salt_species_count = dynamic_salt.salt_species_count;

/// Maps the 41-coordinate REDIST snow chemistry order onto the shared aqueous
/// species identity. Snow omits only the runoff/soil hydrogen-silicate slot at
/// aqueous index 33; keeping this translation here gives snow storage,
/// atmospheric input, discharge, and drift one canonical species basis.
pub fn aqueousSpeciesForSalt(species: SaltSpecies) transport_species.AqueousSpecies {
    comptime {
        if (@intFromEnum(SaltSpecies.potassium_sulfate) != 32 or
            @intFromEnum(transport_species.AqueousSpecies.potassium_sulfate) != 32 or
            @intFromEnum(transport_species.AqueousSpecies.hydrogen_silicate) != 33 or
            @intFromEnum(SaltSpecies.phosphate) != 33 or
            @intFromEnum(transport_species.AqueousSpecies.non_band_phosphate) != 34 or
            @intFromEnum(SaltSpecies.magnesium_hydrogen_phosphate) + 1 !=
                @intFromEnum(transport_species.AqueousSpecies.non_band_magnesium_hpo4))
            @compileError("snow/aqueous salt species mapping changed");
    }
    const snow_index = @intFromEnum(species);
    return @enumFromInt(if (snow_index < 33) snow_index else snow_index + 1);
}

pub const Species = enum(u8) {
    carbon_dioxide_carbon,
    methane_carbon,
    oxygen,
    dinitrogen_nitrogen,
    nitrous_oxide_nitrogen,
    ammonium_nitrogen,
    ammonia_nitrogen,
    nitrate_nitrogen,
    hydrogen_phosphate_phosphorus,
    dihydrogen_phosphate_phosphorus,
    aluminum,
    iron,
    calcium,
    magnesium,
    sodium,
    potassium,
    sulfate_sulfur,
    chloride,
};

pub const species_count = @typeInfo(Species).@"enum".fields.len;
pub const primary_species_count: usize = @intFromEnum(Species.aluminum);
pub const static_ion_species_count: usize = species_count - primary_species_count;
pub const nitrogen_g_per_mol: f64 = 14;
pub const phosphorus_g_per_mol: f64 = 31;
/// STARTS 654 `VHCPWX = 8.380E-04 * AREA`: the source's snow-presence
/// threshold is per horizontal area, not a generic numerical heat floor.
pub const activation_heat_capacity_megajoules_per_m2_k: f64 = 8.380e-4;

/// Authoritative snow thermodynamic coefficients. Callers must supply these
/// explicitly so storage, boundary heat, phase change, and transport cannot
/// silently use different constants.
pub const ThermodynamicParameters = struct {
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    pure_water_melting_temperature_k: f64,

    fn validate(self: ThermodynamicParameters) !void {
        inline for (@typeInfo(ThermodynamicParameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidSnowThermodynamicParameters;
        }
    }
};

/// Test-fixture values only. Production entry points require runscript-owned
/// coefficients and cannot fall back to this value.
pub const test_thermodynamics: ThermodynamicParameters = .{
    .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095,
    .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
    .pure_water_melting_temperature_k = 273.15,
};

/// Physical-state admissibility and conservation are distinct decisions.  A
/// negative liquid inventory is never accepted: the admissibility band only
/// distinguishes a roundoff-sized overdraft from a material one for diagnosis.
/// Conservation is audited independently at cell/column scale so cancellation
/// between snow columns cannot hide a leak.
pub const MeltWaterUpdateTolerances = struct {
    admissibility_absolute_m3: f64,
    admissibility_relative: f64,
    conservation_absolute_depth_m: f64,
    conservation_relative: f64,
};

pub const MeltWaterUpdateOptions = struct {
    tolerances: MeltWaterUpdateTolerances,
    thermodynamics: ThermodynamicParameters,
    /// Signed downward convective heat, indexed by the lower/destination
    /// snow layer. Entry zero in every column is zero.
    accepted_downward_heat_megajoules: []f64 = &.{},
    /// Positive convective heat discharged from the bottom active snow layer,
    /// indexed by cell. The water destination split is published separately.
    accepted_discharge_heat_megajoules: []f64 = &.{},
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    layer_capacity: usize,
    active: []bool,
    solid_snow_water_equivalent_m3: []f64,
    liquid_water_volume_m3: []f64,
    vapor_water_equivalent_m3: []f64,
    ice_volume_m3: []f64,
    air_filled_volume_m3: []f64,
    total_layer_volume_m3: []f64,
    target_layer_volume_m3: []f64,
    layer_thickness_m: []f64,
    cumulative_depth_m: []f64,
    snow_density_megagrams_per_m3: []f64,
    temperature_k: []f64,
    heat_capacity_megajoules_per_k: []f64,
    horizontal_area_m2: []f64,
    amount_g: []f64,
    /// Exact REDIST/TRNSFRS dynamic-salt snow inventory, layer-major in
    /// `SaltSpecies` order.  This remains separate from `amount_g`: the former
    /// is mol (mol P for phosphate species), while the latter is tracked-element
    /// grams.  Mixing them in one vector would silently apply gram tolerances
    /// and molar conversions to the wrong coordinates.
    salt_amount_mol: []f64,
    dynamic_salts_by_cell: []bool,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_capacity: usize) !State {
        if (cell_count == 0 or layer_capacity == 0) return error.ZeroSnowTransportDimension;
        const layer_count = try std.math.mul(usize, cell_count, layer_capacity);
        const active = try allocator.alloc(bool, layer_count);
        errdefer allocator.free(active);
        var physical: [13][]f64 = undefined;
        var physical_count: usize = 0;
        errdefer for (physical[0..physical_count]) |values| allocator.free(values);
        for (&physical) |*values| {
            values.* = try allocator.alloc(f64, layer_count);
            @memset(values.*, 0);
            physical_count += 1;
        }
        const amount = try allocator.alloc(f64, try std.math.mul(usize, layer_count, species_count));
        errdefer allocator.free(amount);
        const salt_amount = try allocator.alloc(f64, try std.math.mul(usize, layer_count, salt_species_count));
        errdefer allocator.free(salt_amount);
        const dynamic_salts = try allocator.alloc(bool, cell_count);
        errdefer allocator.free(dynamic_salts);
        @memset(active, false);
        @memset(amount, 0);
        @memset(salt_amount, 0);
        @memset(dynamic_salts, false);
        return .{ .allocator = allocator, .cell_count = cell_count, .layer_capacity = layer_capacity, .active = active, .solid_snow_water_equivalent_m3 = physical[0], .liquid_water_volume_m3 = physical[1], .vapor_water_equivalent_m3 = physical[2], .ice_volume_m3 = physical[3], .air_filled_volume_m3 = physical[4], .total_layer_volume_m3 = physical[5], .target_layer_volume_m3 = physical[6], .layer_thickness_m = physical[7], .cumulative_depth_m = physical[8], .snow_density_megagrams_per_m3 = physical[9], .temperature_k = physical[10], .heat_capacity_megajoules_per_k = physical[11], .horizontal_area_m2 = physical[12], .amount_g = amount, .salt_amount_mol = salt_amount, .dynamic_salts_by_cell = dynamic_salts };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.dynamic_salts_by_cell);
        self.allocator.free(self.salt_amount_mol);
        self.allocator.free(self.amount_g);
        inline for (.{ self.solid_snow_water_equivalent_m3, self.liquid_water_volume_m3, self.vapor_water_equivalent_m3, self.ice_volume_m3, self.air_filled_volume_m3, self.total_layer_volume_m3, self.target_layer_volume_m3, self.layer_thickness_m, self.cumulative_depth_m, self.snow_density_megagrams_per_m3, self.temperature_k, self.heat_capacity_megajoules_per_k, self.horizontal_area_m2 }) |values| self.allocator.free(values);
        self.allocator.free(self.active);
        self.* = undefined;
    }

    /// STARTS snow-layer initialization with runtime layer boundaries.
    pub fn initializePhysicalState(self: *State, snow_depth_m: []const f64, cell_area_m2: []const f64, atmospheric_temperature_k: []const f64, layer_bottom_depth_m: []const f64, initial_snow_density_megagrams_per_m3: f64, thermodynamics: ThermodynamicParameters) !void {
        try thermodynamics.validate();
        if (snow_depth_m.len != self.cell_count or cell_area_m2.len != self.cell_count or atmospheric_temperature_k.len != self.cell_count or layer_bottom_depth_m.len != self.layer_capacity or !std.math.isFinite(initial_snow_density_megagrams_per_m3) or initial_snow_density_megagrams_per_m3 <= 0) return error.InvalidSnowPhysicalInitialization;
        var previous_bottom: f64 = 0;
        for (layer_bottom_depth_m) |bottom| {
            if (!std.math.isFinite(bottom) or bottom <= previous_bottom) return error.InvalidSnowLayerBoundary;
            previous_bottom = bottom;
        }
        for (0..self.cell_count) |cell| {
            const depth = snow_depth_m[cell];
            const area = cell_area_m2[cell];
            const air_temperature = atmospheric_temperature_k[cell];
            if (!std.math.isFinite(depth) or depth < 0 or !std.math.isFinite(area) or area <= 0 or !std.math.isFinite(air_temperature) or air_temperature <= 0) return error.InvalidSnowPhysicalInitialization;
            var cumulative: f64 = 0;
            for (0..self.layer_capacity) |layer| {
                const index = cell * self.layer_capacity + layer;
                const top = if (layer == 0) 0 else layer_bottom_depth_m[layer - 1];
                const nominal = layer_bottom_depth_m[layer] - top;
                const thickness = @min(nominal, @max(0, depth - top));
                const solid = thickness * initial_snow_density_megagrams_per_m3 * area;
                const total = if (solid > 0) solid / initial_snow_density_megagrams_per_m3 else 0;
                self.active[index] = thickness > 0;
                self.solid_snow_water_equivalent_m3[index] = solid;
                self.liquid_water_volume_m3[index] = 0;
                self.vapor_water_equivalent_m3[index] = 0;
                self.ice_volume_m3[index] = 0;
                self.total_layer_volume_m3[index] = total;
                self.target_layer_volume_m3[index] = nominal * area;
                self.air_filled_volume_m3[index] = @max(0, total - solid);
                self.layer_thickness_m[index] = thickness;
                cumulative += thickness;
                self.cumulative_depth_m[index] = cumulative;
                self.snow_density_megagrams_per_m3[index] = initial_snow_density_megagrams_per_m3;
                self.temperature_k[index] = @min(thermodynamics.pure_water_melting_temperature_k, air_temperature);
                self.heat_capacity_megajoules_per_k[index] = thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * solid;
                self.horizontal_area_m2[index] = area;
            }
        }
    }

    /// REDIST top-layer `TQS/TQW/THQS` update, state_updateted only after every
    /// runtime cell has valid mass and energy inputs.
    pub fn state_updateAtmosphericWater(self: *State, solid_snow_input_m3: []const f64, liquid_water_input_m3: []const f64, heat_input_megajoules: []const f64, fallback_temperature_k: []const f64, initial_snow_density_megagrams_per_m3: f64, thermodynamics: ThermodynamicParameters) !void {
        try thermodynamics.validate();
        inline for (.{ solid_snow_input_m3.len, liquid_water_input_m3.len, heat_input_megajoules.len, fallback_temperature_k.len }) |length| if (length != self.cell_count) return error.SnowAtmosphericInputDimensionMismatch;
        for (0..self.cell_count) |cell| {
            inline for (.{ solid_snow_input_m3[cell], liquid_water_input_m3[cell], heat_input_megajoules[cell], fallback_temperature_k[cell] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSnowAtmosphericInput;
            if (solid_snow_input_m3[cell] < 0 or liquid_water_input_m3[cell] < 0 or fallback_temperature_k[cell] <= 0) return error.InvalidSnowAtmosphericInput;
            const top = cell * self.layer_capacity;
            const solid = self.solid_snow_water_equivalent_m3[top] + solid_snow_input_m3[cell];
            const liquid = self.liquid_water_volume_m3[top] + liquid_water_input_m3[cell];
            const heat_capacity = thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * solid + thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (liquid + self.vapor_water_equivalent_m3[top]) + thermodynamics.ice_heat_capacity_megajoules_per_m3_k * self.ice_volume_m3[top];
            const old_energy = self.heat_capacity_megajoules_per_k[top] * self.temperature_k[top];
            const temperature = if (heat_capacity > 0) (old_energy + heat_input_megajoules[cell]) / heat_capacity else fallback_temperature_k[cell];
            if (!std.math.isFinite(temperature) or temperature <= 0) return error.InvalidSnowAtmosphericEnergy;
        }
        for (0..self.cell_count) |cell| {
            const top = cell * self.layer_capacity;
            const old_energy = self.heat_capacity_megajoules_per_k[top] * self.temperature_k[top];
            self.solid_snow_water_equivalent_m3[top] += solid_snow_input_m3[cell];
            self.liquid_water_volume_m3[top] += liquid_water_input_m3[cell];
            self.heat_capacity_megajoules_per_k[top] = thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * self.solid_snow_water_equivalent_m3[top] + thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (self.liquid_water_volume_m3[top] + self.vapor_water_equivalent_m3[top]) + thermodynamics.ice_heat_capacity_megajoules_per_m3_k * self.ice_volume_m3[top];
            if (self.heat_capacity_megajoules_per_k[top] > 0) self.temperature_k[top] = (old_energy + heat_input_megajoules[cell]) / self.heat_capacity_megajoules_per_k[top];
            if (self.solid_snow_water_equivalent_m3[top] + self.liquid_water_volume_m3[top] + self.ice_volume_m3[top] > 0) {
                self.active[top] = true;
                if (self.snow_density_megagrams_per_m3[top] <= 0) self.snow_density_megagrams_per_m3[top] = initial_snow_density_megagrams_per_m3;
            }
            self.refreshCellGeometry(cell);
        }
    }

    pub fn state_updateMeltWater(self: *State, downward_water_flux_m3: []const f64, litter_water_flux_m3: []const f64, soil_micropore_water_flux_m3: []const f64, soil_macropore_water_flux_m3: []const f64, options: MeltWaterUpdateOptions) !void {
        const layers = self.cell_count * self.layer_capacity;
        if (downward_water_flux_m3.len != layers or litter_water_flux_m3.len != self.cell_count or soil_micropore_water_flux_m3.len != self.cell_count or soil_macropore_water_flux_m3.len != self.cell_count) return error.SnowMeltStateUpdateDimensionMismatch;
        if ((options.accepted_downward_heat_megajoules.len != 0 and options.accepted_downward_heat_megajoules.len != layers) or
            (options.accepted_discharge_heat_megajoules.len != 0 and options.accepted_discharge_heat_megajoules.len != self.cell_count))
            return error.SnowMeltHeatLedgerDimensionMismatch;
        try options.thermodynamics.validate();
        const tolerances = options.tolerances;
        inline for (.{ tolerances.admissibility_absolute_m3, tolerances.admissibility_relative, tolerances.conservation_absolute_depth_m, tolerances.conservation_relative }) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowMeltStateUpdateTolerance;
        }
        if (tolerances.admissibility_relative == 0 or tolerances.conservation_relative == 0) return error.InvalidSnowMeltStateUpdateTolerance;
        for (self.liquid_water_volume_m3) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowMeltLiquidState;
        }
        for (downward_water_flux_m3) |flux| {
            if (!std.math.isFinite(flux) or flux < 0) return error.InvalidSnowMeltStateUpdate;
        }
        inline for (.{ litter_water_flux_m3, soil_micropore_water_flux_m3, soil_macropore_water_flux_m3 }) |fluxes| {
            for (fluxes) |flux| if (!std.math.isFinite(flux) or flux < 0) return error.InvalidSnowMeltStateUpdate;
        }
        const candidate = try self.allocator.dupe(f64, self.liquid_water_volume_m3);
        defer self.allocator.free(candidate);
        const candidate_capacity = try self.allocator.dupe(f64, self.heat_capacity_megajoules_per_k);
        defer self.allocator.free(candidate_capacity);
        const candidate_energy = try self.allocator.alloc(f64, layers);
        defer self.allocator.free(candidate_energy);
        const candidate_temperature = try self.allocator.dupe(f64, self.temperature_k);
        defer self.allocator.free(candidate_temperature);
        const downward_heat = try self.allocator.alloc(f64, layers);
        defer self.allocator.free(downward_heat);
        const discharge_heat = try self.allocator.alloc(f64, self.cell_count);
        defer self.allocator.free(discharge_heat);
        @memset(downward_heat, 0);
        @memset(discharge_heat, 0);
        for (0..layers) |layer| {
            const canonical_capacity = options.thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * self.solid_snow_water_equivalent_m3[layer] +
                options.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (self.liquid_water_volume_m3[layer] + self.vapor_water_equivalent_m3[layer]) +
                options.thermodynamics.ice_heat_capacity_megajoules_per_m3_k * self.ice_volume_m3[layer];
            const scale = @max(1, @max(@abs(canonical_capacity), @abs(self.heat_capacity_megajoules_per_k[layer])));
            if (!std.math.isFinite(canonical_capacity) or
                @abs(canonical_capacity - self.heat_capacity_megajoules_per_k[layer]) > 128 * std.math.floatEps(f64) * scale)
                return error.InconsistentSnowMeltHeatCapacity;
            candidate_energy[layer] = self.heat_capacity_megajoules_per_k[layer] * self.temperature_k[layer];
            if (!std.math.isFinite(candidate_energy[layer])) return error.InvalidSnowMeltEnergyState;
        }
        for (0..self.cell_count) |cell| {
            const first = cell * self.layer_capacity;
            const last = first + self.layer_capacity;
            var before_m3: f64 = 0;
            for (self.liquid_water_volume_m3[first..last]) |value| before_m3 += value;
            var bottom: ?usize = null;
            for (0..self.layer_capacity) |layer| {
                if (self.active[cell * self.layer_capacity + layer]) bottom = layer;
            }
            for (1..self.layer_capacity) |layer| {
                const destination = cell * self.layer_capacity + layer;
                const flux = downward_water_flux_m3[destination];
                candidate[destination - 1] -= flux;
                candidate[destination] += flux;
                const heat = options.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
                    self.temperature_k[destination - 1] * flux;
                if (!std.math.isFinite(heat)) return error.InvalidSnowMeltConvectiveHeat;
                downward_heat[destination] = heat;
                candidate_energy[destination - 1] -= heat;
                candidate_energy[destination] += heat;
            }
            const discharge = litter_water_flux_m3[cell] + soil_micropore_water_flux_m3[cell] + soil_macropore_water_flux_m3[cell];
            if (!std.math.isFinite(discharge)) return error.InvalidSnowMeltStateUpdate;
            if (bottom) |layer| {
                const source = cell * self.layer_capacity + layer;
                candidate[source] -= discharge;
                discharge_heat[cell] = options.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
                    self.temperature_k[source] * discharge;
                if (!std.math.isFinite(discharge_heat[cell])) return error.InvalidSnowMeltConvectiveHeat;
                candidate_energy[source] -= discharge_heat[cell];
            } else if (discharge > 0) {
                return error.SnowMeltDischargeWithoutActiveLayer;
            }

            var after_m3: f64 = 0;
            for (candidate[first..last], self.liquid_water_volume_m3[first..last]) |value, previous| {
                if (!std.math.isFinite(value)) return error.SnowMeltExceedsLiquidInventory;
                if (value < 0) {
                    const scale_m3 = @max(@abs(previous), @max(@abs(value), before_m3 + discharge));
                    const admissibility_limit_m3 = tolerances.admissibility_absolute_m3 + tolerances.admissibility_relative * scale_m3;
                    if (-value <= admissibility_limit_m3) return error.SnowMeltRoundoffWouldRequireClipping;
                    return error.SnowMeltExceedsLiquidInventory;
                }
                after_m3 += value;
            }
            const area_m2 = self.horizontal_area_m2[first];
            if (!std.math.isFinite(area_m2) or area_m2 < 0) return error.InvalidSnowMeltCellArea;
            const closure_m3 = after_m3 + discharge - before_m3;
            const closure_scale_m3 = @max(@abs(before_m3), @abs(after_m3) + discharge);
            const closure_limit_m3 = tolerances.conservation_absolute_depth_m * area_m2 + tolerances.conservation_relative * closure_scale_m3;
            if (!std.math.isFinite(closure_m3) or @abs(closure_m3) > closure_limit_m3) return error.SnowMeltWaterClosureFailure;
        }
        var energy_before: f64 = 0;
        var energy_after: f64 = 0;
        var exported_energy: f64 = 0;
        for (0..layers) |layer| {
            candidate_capacity[layer] = options.thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * self.solid_snow_water_equivalent_m3[layer] +
                options.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (candidate[layer] + self.vapor_water_equivalent_m3[layer]) +
                options.thermodynamics.ice_heat_capacity_megajoules_per_m3_k * self.ice_volume_m3[layer];
            if (!std.math.isFinite(candidate_capacity[layer]) or candidate_capacity[layer] < 0)
                return error.InvalidSnowMeltHeatCapacity;
            if (candidate_capacity[layer] > 0)
                candidate_temperature[layer] = candidate_energy[layer] / candidate_capacity[layer];
            if (!std.math.isFinite(candidate_temperature[layer]) or candidate_temperature[layer] <= 0)
                return error.InvalidSnowMeltTemperature;
            energy_before += self.heat_capacity_megajoules_per_k[layer] * self.temperature_k[layer];
            energy_after += candidate_energy[layer];
        }
        for (discharge_heat) |heat| exported_energy += heat;
        const energy_scale = @max(1, @max(@abs(energy_before), @abs(energy_after) + exported_energy));
        if (!std.math.isFinite(energy_before) or !std.math.isFinite(energy_after) or
            !std.math.isFinite(exported_energy) or
            @abs(energy_after + exported_energy - energy_before) > 512 * std.math.floatEps(f64) * energy_scale)
            return error.SnowMeltEnergyClosureFailure;
        @memcpy(self.liquid_water_volume_m3, candidate);
        @memcpy(self.heat_capacity_megajoules_per_k, candidate_capacity);
        @memcpy(self.temperature_k, candidate_temperature);
        if (options.accepted_downward_heat_megajoules.len != 0)
            @memcpy(options.accepted_downward_heat_megajoules, downward_heat);
        if (options.accepted_discharge_heat_megajoules.len != 0)
            @memcpy(options.accepted_discharge_heat_megajoules, discharge_heat);
        for (0..self.cell_count) |cell| self.refreshCellGeometry(cell);
    }

    fn refreshCellGeometry(self: *State, cell: usize) void {
        var cumulative: f64 = 0;
        for (0..self.layer_capacity) |layer| {
            const index = cell * self.layer_capacity + layer;
            const density = self.snow_density_megagrams_per_m3[index];
            const solid_volume = if (density > 0) self.solid_snow_water_equivalent_m3[index] / density else 0;
            const total = solid_volume + self.liquid_water_volume_m3[index] + self.ice_volume_m3[index];
            self.total_layer_volume_m3[index] = total;
            self.air_filled_volume_m3[index] = @max(0, total - self.solid_snow_water_equivalent_m3[index] - self.liquid_water_volume_m3[index] - self.ice_volume_m3[index]);
            self.layer_thickness_m[index] = if (self.horizontal_area_m2[index] > 0) total / self.horizontal_area_m2[index] else 0;
            cumulative += self.layer_thickness_m[index];
            self.cumulative_depth_m[index] = cumulative;
        }
    }

    pub fn refreshAllGeometry(self: *State) void {
        for (0..self.cell_count) |cell| self.refreshCellGeometry(cell);
    }

    pub fn layerIndex(self: *const State, cell: usize, layer: usize) !usize {
        if (cell >= self.cell_count or layer >= self.layer_capacity) return error.SnowTransportIndexOutOfBounds;
        return cell * self.layer_capacity + layer;
    }

    pub fn amounts(self: *State, cell: usize, layer: usize) ![]f64 {
        const index = try self.layerIndex(cell, layer);
        return self.amount_g[index * species_count .. (index + 1) * species_count];
    }

    pub fn amountsConst(self: *const State, cell: usize, layer: usize) ![]const f64 {
        const index = try self.layerIndex(cell, layer);
        return self.amount_g[index * species_count .. (index + 1) * species_count];
    }

    pub fn saltAmounts(self: *State, cell: usize, layer: usize) ![]f64 {
        const index = try self.layerIndex(cell, layer);
        return self.salt_amount_mol[index * salt_species_count .. (index + 1) * salt_species_count];
    }

    pub fn saltAmountsConst(self: *const State, cell: usize, layer: usize) ![]const f64 {
        const index = try self.layerIndex(cell, layer);
        return self.salt_amount_mol[index * salt_species_count .. (index + 1) * salt_species_count];
    }
};

pub const InitialChemicalConcentrations = struct {
    /// The ten STARTE non-salt carriers in `Species` order through H2PO4.
    primary_g_per_m3: [primary_species_count]f64,
    /// Raw weather-header Al, Fe, Ca, Mg, Na, K, sulfate-S, and chloride for
    /// static-salinity cells. Dynamic cells own these elements exclusively in
    /// the 41-species mol vector below.
    static_ion_g_per_m3: [static_ion_species_count]f64 = @splat(0),
    /// Full dynamic-salt equilibrium in exact REDIST order.
    salt_mol_per_m3: [salt_species_count]f64,
};

/// STARTE 2072--2200 chemical initialization against the already accepted
/// physical snow layers.  Every cell is validated and staged before any owner
/// changes, so a late invalid header or overflow cannot partially initialize a
/// landscape.  Static-salt cells receive the ten non-salt carriers only;
/// dynamic cells additionally receive all 41 equilibrium species.
pub fn initializeChemicalState(
    state: *State,
    concentrations_by_cell: []const InitialChemicalConcentrations,
    salinity_enabled_by_cell: []const bool,
    ice_density_megagrams_per_m3: f64,
    activation_heat_capacity_coefficient_megajoules_per_m2_k: f64,
) !void {
    if (concentrations_by_cell.len != state.cell_count or
        salinity_enabled_by_cell.len != state.cell_count)
        return error.SnowChemicalInitializationDimensionMismatch;
    inline for (.{ ice_density_megagrams_per_m3, activation_heat_capacity_coefficient_megajoules_per_m2_k }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSnowChemicalInitializationParameter;
    if (ice_density_megagrams_per_m3 == 0)
        return error.InvalidSnowChemicalInitializationParameter;

    const candidate_primary = try state.allocator.alloc(f64, state.amount_g.len);
    defer state.allocator.free(candidate_primary);
    const candidate_salt = try state.allocator.alloc(f64, state.salt_amount_mol.len);
    defer state.allocator.free(candidate_salt);
    @memset(candidate_primary, 0);
    @memset(candidate_salt, 0);

    for (0..state.cell_count) |cell| {
        const concentrations = concentrations_by_cell[cell];
        for (concentrations.primary_g_per_m3) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidInitialSnowChemicalConcentration;
        for (concentrations.static_ion_g_per_m3) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidInitialSnowChemicalConcentration;
        if (salinity_enabled_by_cell[cell]) for (concentrations.salt_mol_per_m3) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidInitialSnowChemicalConcentration;

        for (0..state.layer_capacity) |layer| {
            const layer_index = cell * state.layer_capacity + layer;
            inline for (.{
                state.liquid_water_volume_m3[layer_index],
                state.solid_snow_water_equivalent_m3[layer_index],
                state.ice_volume_m3[layer_index],
                state.heat_capacity_megajoules_per_k[layer_index],
                state.horizontal_area_m2[layer_index],
            }) |value| if (!std.math.isFinite(value) or value < 0)
                return error.InvalidInitialSnowPhysicalState;
            if (state.horizontal_area_m2[layer_index] == 0)
                return error.InvalidInitialSnowPhysicalState;
            const active_heat_capacity_threshold_megajoules_per_k =
                activation_heat_capacity_coefficient_megajoules_per_m2_k * state.horizontal_area_m2[layer_index];
            if (!std.math.isFinite(active_heat_capacity_threshold_megajoules_per_k))
                return error.InvalidInitialSnowPhysicalState;
            if (state.heat_capacity_megajoules_per_k[layer_index] <=
                active_heat_capacity_threshold_megajoules_per_k) continue;
            const water_equivalent_m3 = state.liquid_water_volume_m3[layer_index] +
                state.solid_snow_water_equivalent_m3[layer_index] +
                state.ice_volume_m3[layer_index] * ice_density_megagrams_per_m3;
            if (!std.math.isFinite(water_equivalent_m3) or water_equivalent_m3 < 0)
                return error.InvalidInitialSnowPhysicalState;
            for (concentrations.primary_g_per_m3, 0..) |value, species| {
                const inventory = water_equivalent_m3 * value;
                if (!std.math.isFinite(inventory))
                    return error.InitialSnowChemicalInventoryOverflow;
                candidate_primary[layer_index * species_count + species] = inventory;
            }
            if (salinity_enabled_by_cell[cell]) {
                for (concentrations.salt_mol_per_m3, 0..) |value, species| {
                    const inventory = water_equivalent_m3 * value;
                    if (!std.math.isFinite(inventory))
                        return error.InitialSnowChemicalInventoryOverflow;
                    candidate_salt[layer_index * salt_species_count + species] = inventory;
                }
            } else {
                for (concentrations.static_ion_g_per_m3, 0..) |value, ion| {
                    const inventory = water_equivalent_m3 * value;
                    if (!std.math.isFinite(inventory))
                        return error.InitialSnowChemicalInventoryOverflow;
                    candidate_primary[layer_index * species_count + primary_species_count + ion] = inventory;
                }
            }
        }
    }
    @memcpy(state.amount_g, candidate_primary);
    @memcpy(state.salt_amount_mol, candidate_salt);
    @memcpy(state.dynamic_salts_by_cell, salinity_enabled_by_cell);
}

test "STARTE snow chemistry zero depth has zero inventory" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0}, &.{2}, &.{268}, &.{ 0.05, 0.10 }, 0.1, test_thermodynamics);
    const concentrations: InitialChemicalConcentrations = .{
        .primary_g_per_m3 = [_]f64{3} ** primary_species_count,
        .salt_mol_per_m3 = [_]f64{5} ** salt_species_count,
    };
    try initializeChemicalState(&state, &.{concentrations}, &.{true}, 0.917, 1e-15);
    try std.testing.expectEqualSlices(f64, &([_]f64{0} ** (2 * species_count)), state.amount_g);
    try std.testing.expectEqualSlices(f64, &([_]f64{0} ** (2 * salt_species_count)), state.salt_amount_mol);
}

test "STARTE snow chemistry uses strict area-scaled VHCPWX activation" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.1, 0.1 }, &.{ 2, 3 }, &.{ 268, 268 }, &.{0.2}, 0.1, test_thermodynamics);
    state.heat_capacity_megajoules_per_k[0] =
        activation_heat_capacity_megajoules_per_m2_k * state.horizontal_area_m2[0];
    state.heat_capacity_megajoules_per_k[1] =
        1.01 * activation_heat_capacity_megajoules_per_m2_k * state.horizontal_area_m2[1];
    const concentrations: InitialChemicalConcentrations = .{
        .primary_g_per_m3 = [_]f64{2} ** primary_species_count,
        .salt_mol_per_m3 = [_]f64{0.5} ** salt_species_count,
    };

    try initializeChemicalState(
        &state,
        &.{ concentrations, concentrations },
        &.{ true, true },
        0.917,
        activation_heat_capacity_megajoules_per_m2_k,
    );

    for (try state.amountsConst(0, 0)) |inventory|
        try std.testing.expectEqual(@as(f64, 0), inventory);
    for (try state.saltAmountsConst(0, 0)) |inventory|
        try std.testing.expectEqual(@as(f64, 0), inventory);
    for ((try state.amountsConst(1, 0))[0..primary_species_count]) |inventory|
        try std.testing.expect(inventory > 0);
    for (try state.saltAmountsConst(1, 0)) |inventory|
        try std.testing.expect(inventory > 0);
}

test "STARTE snow chemistry initializes every gas nutrient and dynamic ion species" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.08}, &.{2}, &.{268}, &.{ 0.05, 0.10 }, 0.1, test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.01;
    state.ice_volume_m3[0] = 0.02;
    const concentrations: InitialChemicalConcentrations = .{
        .primary_g_per_m3 = comptime values: {
            var values: [primary_species_count]f64 = undefined;
            for (&values, 0..) |*value, index| value.* = @floatFromInt(index + 1);
            break :values values;
        },
        .salt_mol_per_m3 = comptime values: {
            var values: [salt_species_count]f64 = undefined;
            for (&values, 0..) |*value, index| value.* = @as(f64, @floatFromInt(index + 1)) / 1000;
            break :values values;
        },
    };
    try initializeChemicalState(&state, &.{concentrations}, &.{true}, 0.917, 1e-15);
    const water_equivalent_m3 = state.solid_snow_water_equivalent_m3[0] + 0.01 + 0.02 * 0.917;
    for ((try state.amountsConst(0, 0))[0..primary_species_count], concentrations.primary_g_per_m3) |inventory, concentration|
        try std.testing.expectApproxEqAbs(water_equivalent_m3 * concentration, inventory, 1e-15);
    for (try state.saltAmountsConst(0, 0), concentrations.salt_mol_per_m3) |inventory, concentration|
        try std.testing.expectApproxEqAbs(water_equivalent_m3 * concentration, inventory, 1e-15);
    try std.testing.expect(state.dynamic_salts_by_cell[0]);
}

test "STARTE snow chemistry honors mixed per-cell salinity" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.1, 0.1 }, &.{ 1, 1 }, &.{ 268, 268 }, &.{0.2}, 0.1, test_thermodynamics);
    const concentrations: InitialChemicalConcentrations = .{
        .primary_g_per_m3 = [_]f64{2} ** primary_species_count,
        .static_ion_g_per_m3 = [_]f64{3} ** static_ion_species_count,
        .salt_mol_per_m3 = [_]f64{4} ** salt_species_count,
    };
    try initializeChemicalState(&state, &.{ concentrations, concentrations }, &.{ true, false }, 0.917, 1e-15);
    for (try state.saltAmountsConst(0, 0)) |inventory| try std.testing.expect(inventory > 0);
    for (try state.saltAmountsConst(1, 0)) |inventory| try std.testing.expectEqual(@as(f64, 0), inventory);
    for ((try state.amountsConst(0, 0))[0..primary_species_count]) |inventory| try std.testing.expect(inventory > 0);
    for ((try state.amountsConst(1, 0))[0..primary_species_count]) |inventory| try std.testing.expect(inventory > 0);
    for ((try state.amountsConst(0, 0))[primary_species_count..]) |inventory| try std.testing.expectEqual(@as(f64, 0), inventory);
    for ((try state.amountsConst(1, 0))[primary_species_count..]) |inventory| try std.testing.expect(inventory > 0);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, state.dynamic_salts_by_cell);
}

test "STARTE snow chemistry late invalid cell rolls back atomically" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.1, 0.1 }, &.{ 1, 1 }, &.{ 268, 268 }, &.{0.2}, 0.1, test_thermodynamics);
    @memset(state.amount_g, 7);
    @memset(state.salt_amount_mol, 11);
    @memset(state.dynamic_salts_by_cell, false);
    const valid: InitialChemicalConcentrations = .{
        .primary_g_per_m3 = [_]f64{2} ** primary_species_count,
        .salt_mol_per_m3 = [_]f64{4} ** salt_species_count,
    };
    var invalid = valid;
    invalid.salt_mol_per_m3[salt_species_count - 1] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidInitialSnowChemicalConcentration, initializeChemicalState(&state, &.{ valid, invalid }, &.{ true, true }, 0.917, 1e-15));
    for (state.amount_g) |inventory| try std.testing.expectEqual(@as(f64, 7), inventory);
    for (state.salt_amount_mol) |inventory| try std.testing.expectEqual(@as(f64, 11), inventory);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, state.dynamic_salts_by_cell);
}

pub const SurfacePartition = struct {
    litter_cover_fraction: f64,
    bare_soil_fraction: f64,
    nonband_ammonium_fraction: f64,
    band_ammonium_fraction: f64,
    nonband_nitrate_fraction: f64,
    band_nitrate_fraction: f64,
    nonband_phosphate_fraction: f64,
    band_phosphate_fraction: f64,
};

pub const SurfaceDischarge = struct {
    /// Representation-only aqueous carrier for litter chemistry delivered when
    /// the live litter liquid volume is zero. This is not an additional water
    /// storage or boundary flux; snow disappearance sets it to the transferred
    /// water equivalent so concentration-backed litter pools can preserve the
    /// exact extensive amount through a frozen/dry interval.
    litter_dry_reference_carrier_m3: f64 = 0,
    litter_g: [species_count]f64 = [_]f64{0} ** species_count,
    soil_nonband_g: [species_count]f64 = [_]f64{0} ** species_count,
    soil_band_g: [species_count]f64 = [_]f64{0} ** species_count,
    litter_salt_mol: [salt_species_count]f64 = [_]f64{0} ** salt_species_count,
    soil_nonband_salt_mol: [salt_species_count]f64 = [_]f64{0} ** salt_species_count,
    soil_band_salt_mol: [salt_species_count]f64 = [_]f64{0} ** salt_species_count,
};

pub const Fluxes = struct {
    allocator: std.mem.Allocator,
    /// Layer-major flux from a layer to the next layer; zero at discharge layer.
    downward_g: []f64,
    downward_salt_mol: []f64,
    surface_discharge: []SurfaceDischarge,

    pub fn deinit(self: *Fluxes) void {
        self.allocator.free(self.surface_discharge);
        self.allocator.free(self.downward_salt_mol);
        self.allocator.free(self.downward_g);
        self.* = undefined;
    }
};

pub const FluxTolerances = struct {
    water_absolute_m3: f64,
    relative: f64,
};

/// Converts precipitation/irrigation concentrations into tracked snow
/// inventories. The first five concentrations are already tracked-mass g/m3;
/// nutrient inputs are mol/m3 and receive the exact 14 or 31 multipliers.
pub fn atmosphericInputG(rain_water_m3: f64, irrigation_water_m3: f64, rain_first_five_g_per_m3: [5]f64, irrigation_first_five_g_per_m3: [5]f64, rain_nutrients_mol_per_m3: [5]f64, irrigation_nutrients_mol_per_m3: [5]f64, rain_ions_g_per_m3: [8]f64, irrigation_ions_g_per_m3: [8]f64) ![species_count]f64 {
    if (!std.math.isFinite(rain_water_m3) or rain_water_m3 < 0 or !std.math.isFinite(irrigation_water_m3) or irrigation_water_m3 < 0) return error.InvalidSnowAtmosphericInput;
    var output = [_]f64{0} ** species_count;
    for (rain_first_five_g_per_m3, irrigation_first_five_g_per_m3, 0..) |rain, irrigation, species| {
        if (!std.math.isFinite(rain) or rain < 0 or !std.math.isFinite(irrigation) or irrigation < 0) return error.InvalidSnowAtmosphericInput;
        output[species] = rain_water_m3 * rain + irrigation_water_m3 * irrigation;
    }
    for (rain_nutrients_mol_per_m3, irrigation_nutrients_mol_per_m3, 0..) |rain, irrigation, nutrient| {
        if (!std.math.isFinite(rain) or rain < 0 or !std.math.isFinite(irrigation) or irrigation < 0) return error.InvalidSnowAtmosphericInput;
        const factor = if (nutrient < 3) nitrogen_g_per_mol else phosphorus_g_per_mol;
        output[5 + nutrient] = (rain_water_m3 * rain + irrigation_water_m3 * irrigation) * factor;
    }
    for (rain_ions_g_per_m3, irrigation_ions_g_per_m3, 0..) |rain, irrigation, ion| {
        if (!std.math.isFinite(rain) or rain < 0 or !std.math.isFinite(irrigation) or irrigation < 0) return error.InvalidSnowAtmosphericInput;
        output[10 + ion] = rain_water_m3 * rain + irrigation_water_m3 * irrigation;
    }
    return output;
}

/// Evaluates one snow-water transport residual from a supplied trial state.
/// `water_flux_to_lower_m3` is layer-major. Surface fluxes apply only to the
/// first active layer whose lower neighbor is absent, matching `ICHKL`.
pub fn calculateFluxes(allocator: std.mem.Allocator, state: *const State, water_flux_to_lower_m3: []const f64, litter_water_flux_m3: []const f64, soil_micropore_water_flux_m3: []const f64, soil_macropore_water_flux_m3: []const f64, partitions: []const SurfacePartition, tolerances: FluxTolerances) !Fluxes {
    const layer_count = try std.math.mul(usize, state.cell_count, state.layer_capacity);
    if (water_flux_to_lower_m3.len != layer_count or litter_water_flux_m3.len != state.cell_count or soil_micropore_water_flux_m3.len != state.cell_count or soil_macropore_water_flux_m3.len != state.cell_count or partitions.len != state.cell_count) return error.SnowTransportInputSizeMismatch;
    const downward = try allocator.alloc(f64, state.amount_g.len);
    errdefer allocator.free(downward);
    @memset(downward, 0);
    const downward_salt = try allocator.alloc(f64, state.salt_amount_mol.len);
    errdefer allocator.free(downward_salt);
    @memset(downward_salt, 0);
    const discharge = try allocator.alloc(SurfaceDischarge, state.cell_count);
    errdefer allocator.free(discharge);
    @memset(discharge, .{});
    try validateState(state);
    if (!std.math.isFinite(tolerances.water_absolute_m3) or tolerances.water_absolute_m3 < 0 or
        !std.math.isFinite(tolerances.relative) or tolerances.relative <= 0)
        return error.InvalidSnowFluxTolerance;
    for (0..state.cell_count) |cell| {
        try validatePartition(partitions[cell]);
        var discharged = false;
        for (0..state.layer_capacity) |layer| {
            const layer_index = try state.layerIndex(cell, layer);
            if (!state.active[layer_index]) continue;
            const amounts_g = try state.amountsConst(cell, layer);
            const salt_amounts_mol = try state.saltAmountsConst(cell, layer);
            const has_active_lower = layer + 1 < state.layer_capacity and state.active[try state.layerIndex(cell, layer + 1)];
            if (has_active_lower) {
                const water = state.liquid_water_volume_m3[layer_index];
                const requested = water_flux_to_lower_m3[try state.layerIndex(cell, layer + 1)];
                if (!std.math.isFinite(requested) or requested < 0) return error.InvalidSnowWaterFlux;
                const tolerance_m3 = tolerances.water_absolute_m3 + tolerances.relative * @max(water, requested);
                if (requested > water + tolerance_m3) return error.SnowLayerFluxExceedsInventory;
                const fraction = if (water > 0) @min(requested, water) / water else 0;
                for (amounts_g, 0..) |amount, species| downward[layer_index * species_count + species] = amount * fraction;
                for (salt_amounts_mol, 0..) |amount, species| downward_salt[layer_index * salt_species_count + species] = amount * fraction;
            } else if (!discharged) {
                const water = state.liquid_water_volume_m3[layer_index];
                const litter_requested = litter_water_flux_m3[cell];
                const soil_requested = soil_micropore_water_flux_m3[cell] + soil_macropore_water_flux_m3[cell];
                if (!std.math.isFinite(litter_requested) or litter_requested < 0 or
                    !std.math.isFinite(soil_requested) or soil_requested < 0)
                    return error.InvalidSnowWaterFlux;
                const total_requested = litter_requested + soil_requested;
                if (!std.math.isFinite(total_requested)) return error.InvalidSnowWaterFlux;
                const tolerance_m3 = tolerances.water_absolute_m3 + tolerances.relative * @max(water, total_requested);
                if (total_requested > water + tolerance_m3) return error.SnowSurfaceFluxExceedsInventory;
                const accepted_scale = if (total_requested > water and total_requested > 0) water / total_requested else 1;
                const litter_fraction = if (water > 0) litter_requested * accepted_scale / water else 0;
                const soil_fraction = if (water > 0) soil_requested * accepted_scale / water else 0;
                routeSurface(amounts_g, litter_fraction, soil_fraction, partitions[cell], &discharge[cell]);
                routeSurfaceSalt(salt_amounts_mol, litter_fraction, soil_fraction, partitions[cell], &discharge[cell]);
                discharged = true;
            }
        }
    }
    return .{ .allocator = allocator, .downward_g = downward, .downward_salt_mol = downward_salt, .surface_discharge = discharge };
}

pub fn state_update(state: *State, atmospheric_top_input_g: []const f64, fluxes: *const Fluxes) !void {
    if (atmospheric_top_input_g.len != try std.math.mul(usize, state.cell_count, species_count) or fluxes.downward_g.len != state.amount_g.len or fluxes.downward_salt_mol.len != state.salt_amount_mol.len or fluxes.surface_discharge.len != state.cell_count) return error.SnowTransportInputSizeMismatch;
    const candidate = try state.allocator.dupe(f64, state.amount_g);
    defer state.allocator.free(candidate);
    const salt_candidate = try state.allocator.dupe(f64, state.salt_amount_mol);
    defer state.allocator.free(salt_candidate);
    for (0..state.cell_count) |cell| {
        const top = try state.layerIndex(cell, 0);
        for (0..species_count) |species| candidate[top * species_count + species] += atmospheric_top_input_g[cell * species_count + species];
        for (0..state.layer_capacity) |layer| {
            const index = try state.layerIndex(cell, layer);
            if (!state.active[index]) continue;
            for (0..species_count) |species| {
                const component = index * species_count + species;
                const outgoing = fluxes.downward_g[component];
                candidate[component] -= outgoing;
                if (layer + 1 < state.layer_capacity and state.active[try state.layerIndex(cell, layer + 1)]) candidate[(index + 1) * species_count + species] += outgoing;
                if (layer + 1 >= state.layer_capacity or !state.active[try state.layerIndex(cell, layer + 1)]) candidate[component] -= fluxes.surface_discharge[cell].litter_g[species] + fluxes.surface_discharge[cell].soil_nonband_g[species] + fluxes.surface_discharge[cell].soil_band_g[species];
            }
            for (0..salt_species_count) |species| {
                const component = index * salt_species_count + species;
                const outgoing = fluxes.downward_salt_mol[component];
                salt_candidate[component] -= outgoing;
                if (layer + 1 < state.layer_capacity and state.active[try state.layerIndex(cell, layer + 1)]) salt_candidate[(index + 1) * salt_species_count + species] += outgoing;
                if (layer + 1 >= state.layer_capacity or !state.active[try state.layerIndex(cell, layer + 1)]) salt_candidate[component] -= fluxes.surface_discharge[cell].litter_salt_mol[species] + fluxes.surface_discharge[cell].soil_nonband_salt_mol[species] + fluxes.surface_discharge[cell].soil_band_salt_mol[species];
            }
        }
    }
    for (candidate) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowTransportCandidate;
    for (salt_candidate) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowTransportCandidate;
    @memcpy(state.amount_g, candidate);
    @memcpy(state.salt_amount_mol, salt_candidate);
}

fn routeSurface(amounts_g: []const f64, litter_fraction: f64, soil_fraction: f64, partition: SurfacePartition, output: *SurfaceDischarge) void {
    for (amounts_g, 0..) |amount, species| {
        output.litter_g[species] = amount * litter_fraction;
        switch (@as(Species, @enumFromInt(species))) {
            .ammonium_nitrogen, .ammonia_nitrogen => {
                output.soil_nonband_g[species] = amount * soil_fraction * partition.nonband_ammonium_fraction;
                output.soil_band_g[species] = amount * soil_fraction * partition.band_ammonium_fraction;
            },
            .nitrate_nitrogen => {
                output.soil_nonband_g[species] = amount * soil_fraction * partition.nonband_nitrate_fraction;
                output.soil_band_g[species] = amount * soil_fraction * partition.band_nitrate_fraction;
            },
            .hydrogen_phosphate_phosphorus, .dihydrogen_phosphate_phosphorus => {
                output.soil_nonband_g[species] = amount * soil_fraction * partition.nonband_phosphate_fraction;
                output.soil_band_g[species] = amount * soil_fraction * partition.band_phosphate_fraction;
            },
            else => output.soil_nonband_g[species] = amount * soil_fraction,
        }
    }
}

fn routeSurfaceSalt(amounts_mol: []const f64, litter_fraction: f64, soil_fraction: f64, partition: SurfacePartition, output: *SurfaceDischarge) void {
    for (amounts_mol, 0..) |amount, species| {
        output.litter_salt_mol[species] = amount * litter_fraction;
        const salt_species: SaltSpecies = @enumFromInt(species);
        if (@intFromEnum(salt_species) >= @intFromEnum(SaltSpecies.phosphate)) {
            output.soil_nonband_salt_mol[species] = amount * soil_fraction * partition.nonband_phosphate_fraction;
            output.soil_band_salt_mol[species] = amount * soil_fraction * partition.band_phosphate_fraction;
        } else {
            output.soil_nonband_salt_mol[species] = amount * soil_fraction;
        }
    }
}

fn validateState(state: *const State) !void {
    inline for (.{ state.solid_snow_water_equivalent_m3, state.liquid_water_volume_m3, state.vapor_water_equivalent_m3, state.ice_volume_m3, state.air_filled_volume_m3, state.total_layer_volume_m3, state.target_layer_volume_m3, state.layer_thickness_m, state.cumulative_depth_m, state.snow_density_megagrams_per_m3, state.temperature_k, state.heat_capacity_megajoules_per_k, state.horizontal_area_m2 }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowTransportState;
    for (state.amount_g) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowTransportState;
    for (state.salt_amount_mol) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowTransportState;
}

fn validatePartition(partition: SurfacePartition) !void {
    inline for (@typeInfo(SurfacePartition).@"struct".fields) |field| {
        const value = @field(partition, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSnowSurfacePartition;
    }
    if (@abs(partition.litter_cover_fraction + partition.bare_soil_fraction - 1) > 1e-10 or @abs(partition.nonband_ammonium_fraction + partition.band_ammonium_fraction - 1) > 1e-10 or @abs(partition.nonband_nitrate_fraction + partition.band_nitrate_fraction - 1) > 1e-10 or @abs(partition.nonband_phosphate_fraction + partition.band_phosphate_fraction - 1) > 1e-10) return error.InvalidSnowSurfacePartition;
}

const test_melt_water_tolerances: MeltWaterUpdateTolerances = .{
    .admissibility_absolute_m3 = 1e-14,
    .admissibility_relative = 1e-12,
    .conservation_absolute_depth_m = 0,
    .conservation_relative = 1e-9,
};

const test_melt_water_options: MeltWaterUpdateOptions = .{
    .tolerances = test_melt_water_tolerances,
    .thermodynamics = test_thermodynamics,
};

fn refreshTestHeatCapacities(state: *State) void {
    for (0..state.heat_capacity_megajoules_per_k.len) |layer|
        state.heat_capacity_megajoules_per_k[layer] =
            test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * state.solid_snow_water_equivalent_m3[layer] +
            test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (state.liquid_water_volume_m3[layer] + state.vapor_water_equivalent_m3[layer]) +
            test_thermodynamics.ice_heat_capacity_megajoules_per_m3_k * state.ice_volume_m3[layer];
}

test "snow atmospheric nutrients and irrigation ions retain units" {
    const input = try atmosphericInputG(2, 1, [_]f64{ 1, 2, 3, 4, 5 }, [_]f64{ 2, 3, 4, 5, 6 }, [_]f64{1} ** 5, [_]f64{2} ** 5, [_]f64{0} ** 8, [_]f64{1} ** 8);
    try std.testing.expectEqual(@as(f64, 4), input[0]);
    try std.testing.expectEqual(@as(f64, 56), input[5]);
    try std.testing.expectEqual(@as(f64, 124), input[8]);
    try std.testing.expectEqual(@as(f64, 1), input[@intFromEnum(Species.aluminum)]);
}

test "STARTS snow physical state uses runtime layer boundaries" {
    var state = try State.init(std.testing.allocator, 2, 3);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.2, 0 }, &.{ 10, 20 }, &.{ 278.0, 268.0 }, &.{ 0.05, 0.125, 0.25 }, 0.05, test_thermodynamics);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false, false, false }, state.active);
    try std.testing.expectApproxEqAbs(@as(f64, 0.025), state.solid_snow_water_equivalent_m3[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0375), state.solid_snow_water_equivalent_m3[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0375), state.solid_snow_water_equivalent_m3[2], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), state.cumulative_depth_m[2], 1e-12);
    try std.testing.expectEqual(@as(f64, 273.15), state.temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 268), state.temperature_k[3]);
}

test "snow physical state uses explicit non-default thermodynamic coefficients" {
    const thermodynamics: ThermodynamicParameters = .{
        .solid_snow_heat_capacity_megajoules_per_m3_k = 3,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 5,
        .ice_heat_capacity_megajoules_per_m3_k = 2,
        .pure_water_melting_temperature_k = 274,
    };
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{2}, &.{280}, &.{0.2}, 0.1, thermodynamics);
    try std.testing.expectApproxEqAbs(@as(f64, 274), state.temperature_k[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), state.heat_capacity_megajoules_per_k[0], 1e-15);

    const old_energy = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0];
    try state.state_updateAtmosphericWater(&.{0.01}, &.{0.02}, &.{0}, &.{270}, 0.1, thermodynamics);
    try std.testing.expectApproxEqAbs(@as(f64, 3 * 0.03 + 5 * 0.02), state.heat_capacity_megajoules_per_k[0], 1e-15);
    try std.testing.expectApproxEqAbs(old_energy, state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0], 1e-12);
}

test "REDIST atmospheric input and WATSUB melt state_update conserve snow water" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0}, &.{10}, &.{270}, &.{ 0.05, 0.125 }, 0.05, test_thermodynamics);
    try state.state_updateAtmosphericWater(&.{0.2}, &.{0.1}, &.{2.095 * 0.2 * 268 + 4.19 * 0.1 * 268}, &.{268}, 0.05, test_thermodynamics);
    try std.testing.expect(state.active[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 268), state.temperature_k[0], 1e-10);
    const before = state.liquid_water_volume_m3[0] + state.liquid_water_volume_m3[1];
    try state.state_updateMeltWater(&.{ 0, 0.04 }, &.{0.02}, &.{0.01}, &.{0.01}, test_melt_water_options);
    const after = state.liquid_water_volume_m3[0] + state.liquid_water_volume_m3[1];
    try std.testing.expectApproxEqAbs(before - 0.04, after, 1e-12);
}

test "snow melt percolation carries donor enthalpy and rebuilds canonical capacity" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{268}, &.{ 0.05, 0.1 }, 0.1, test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.03;
    state.liquid_water_volume_m3[1] = 0.02;
    state.temperature_k[0] = 270;
    state.temperature_k[1] = 280;
    refreshTestHeatCapacities(&state);
    state.refreshAllGeometry();
    const capacity_before = state.heat_capacity_megajoules_per_k[0..2].*;
    const energy_before = capacity_before[0] * 270 + capacity_before[1] * 280;
    var downward_heat = [_]f64{ 99, 99 };
    var discharge_heat = [_]f64{99};
    var options = test_melt_water_options;
    options.accepted_downward_heat_megajoules = &downward_heat;
    options.accepted_discharge_heat_megajoules = &discharge_heat;
    try state.state_updateMeltWater(&.{ 0, 0.01 }, &.{0.005}, &.{0.003}, &.{0.002}, options);
    try std.testing.expectEqual(@as(f64, 0), downward_heat[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 4.19 * 270 * 0.01), downward_heat[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 4.19 * 280 * 0.01), discharge_heat[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 270), state.temperature_k[0], 1e-12);
    try std.testing.expect(state.temperature_k[1] < 280);
    for (0..2) |layer| {
        const expected_capacity = test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * state.solid_snow_water_equivalent_m3[layer] +
            test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (state.liquid_water_volume_m3[layer] + state.vapor_water_equivalent_m3[layer]) +
            test_thermodynamics.ice_heat_capacity_megajoules_per_m3_k * state.ice_volume_m3[layer];
        try std.testing.expectApproxEqAbs(expected_capacity, state.heat_capacity_megajoules_per_k[layer], 1e-15);
    }
    const energy_after = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0] +
        state.heat_capacity_megajoules_per_k[1] * state.temperature_k[1];
    try std.testing.expectApproxEqAbs(energy_before, energy_after + discharge_heat[0], 1e-12);
}

test "failed snow melt state_update leaves liquid state unchanged" {
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.01}, &.{1}, &.{270}, &.{0.05}, 0.05, test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.01;
    refreshTestHeatCapacities(&state);
    try std.testing.expectError(error.SnowMeltExceedsLiquidInventory, state.state_updateMeltWater(&.{0}, &.{0.02}, &.{0}, &.{0}, test_melt_water_options));
    try std.testing.expectEqual(@as(f64, 0.01), state.liquid_water_volume_m3[0]);
}

test "roundoff-sized snow melt overdraft rejects atomically without clipping" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.01, 0.01 }, &.{ 2, 3 }, &.{ 270, 270 }, &.{0.05}, 0.05, test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.25;
    state.liquid_water_volume_m3[1] = 1e-8;
    refreshTestHeatCapacities(&state);
    state.refreshAllGeometry();
    const liquid_before = state.liquid_water_volume_m3[0..2].*;
    const volume_before = state.total_layer_volume_m3[0..2].*;
    const thickness_before = state.layer_thickness_m[0..2].*;
    const depth_before = state.cumulative_depth_m[0..2].*;

    try std.testing.expectError(
        error.SnowMeltRoundoffWouldRequireClipping,
        state.state_updateMeltWater(&.{ 0, 0 }, &.{ 0.1, 1.00000001e-8 }, &.{ 0, 0 }, &.{ 0, 0 }, test_melt_water_options),
    );
    try std.testing.expectEqualSlices(f64, &liquid_before, state.liquid_water_volume_m3);
    try std.testing.expectEqualSlices(f64, &volume_before, state.total_layer_volume_m3);
    try std.testing.expectEqualSlices(f64, &thickness_before, state.layer_thickness_m);
    try std.testing.expectEqualSlices(f64, &depth_before, state.cumulative_depth_m);
}

test "melt water and carried solute close independently at snow-column scale" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{10}, &.{270}, &.{ 0.05, 0.1 }, 0.05, test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.2;
    state.liquid_water_volume_m3[1] = 0.3;
    refreshTestHeatCapacities(&state);
    @memset(try state.amounts(0, 0), 10);
    @memset(try state.amounts(0, 1), 4);
    @memset(try state.saltAmounts(0, 0), 0.1);
    @memset(try state.saltAmounts(0, 1), 0.04);
    const downward = [_]f64{ 0, 0.05 };
    const litter = [_]f64{0.025};
    const micropore = [_]f64{0.05};
    const macropore = [_]f64{0.025};
    const partition = SurfacePartition{ .litter_cover_fraction = 0.25, .bare_soil_fraction = 0.75, .nonband_ammonium_fraction = 0.6, .band_ammonium_fraction = 0.4, .nonband_nitrate_fraction = 0.7, .band_nitrate_fraction = 0.3, .nonband_phosphate_fraction = 0.8, .band_phosphate_fraction = 0.2 };

    var solute_fluxes = try calculateFluxes(std.testing.allocator, &state, &downward, &litter, &micropore, &macropore, &.{partition}, .{ .water_absolute_m3 = 1e-12, .relative = 1e-10 });
    defer solute_fluxes.deinit();
    var solute_before_g: f64 = 0;
    for (state.amount_g) |amount_g| solute_before_g += amount_g;
    var salt_before_mol: f64 = 0;
    for (state.salt_amount_mol) |amount_mol| salt_before_mol += amount_mol;
    const water_before_m3 = state.liquid_water_volume_m3[0] + state.liquid_water_volume_m3[1];

    try state.state_updateMeltWater(&downward, &litter, &micropore, &macropore, test_melt_water_options);
    try state_update(&state, &([_]f64{0} ** species_count), &solute_fluxes);

    var solute_after_g: f64 = 0;
    for (state.amount_g) |amount_g| solute_after_g += amount_g;
    var solute_discharge_g: f64 = 0;
    for (solute_fluxes.surface_discharge[0].litter_g, solute_fluxes.surface_discharge[0].soil_nonband_g, solute_fluxes.surface_discharge[0].soil_band_g) |litter_g, nonband_g, band_g| solute_discharge_g += litter_g + nonband_g + band_g;
    var salt_after_mol: f64 = 0;
    for (state.salt_amount_mol) |amount_mol| salt_after_mol += amount_mol;
    var salt_discharge_mol: f64 = 0;
    for (solute_fluxes.surface_discharge[0].litter_salt_mol, solute_fluxes.surface_discharge[0].soil_nonband_salt_mol, solute_fluxes.surface_discharge[0].soil_band_salt_mol) |litter_mol, nonband_mol, band_mol| salt_discharge_mol += litter_mol + nonband_mol + band_mol;
    const water_after_m3 = state.liquid_water_volume_m3[0] + state.liquid_water_volume_m3[1];
    const water_discharge_m3 = litter[0] + micropore[0] + macropore[0];
    try std.testing.expectApproxEqAbs(water_before_m3, water_after_m3 + water_discharge_m3, 16 * std.math.floatEps(f64) * water_before_m3);
    try std.testing.expectApproxEqAbs(solute_before_g, solute_after_g + solute_discharge_g, 32 * std.math.floatEps(f64) * solute_before_g);
    try std.testing.expectApproxEqAbs(salt_before_mol, salt_after_mol + salt_discharge_mol, 32 * std.math.floatEps(f64) * salt_before_mol);
}

test "pre-existing STARTE snow chemistry closes every species through first-hour melt" {
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{268}, &.{0.2}, 0.1, test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.04;
    refreshTestHeatCapacities(&state);
    state.refreshAllGeometry();
    const concentrations: InitialChemicalConcentrations = .{
        .primary_g_per_m3 = comptime values: {
            var values: [primary_species_count]f64 = undefined;
            for (&values, 0..) |*value, index|
                value.* = @as(f64, @floatFromInt(index + 1));
            break :values values;
        },
        .salt_mol_per_m3 = comptime values: {
            var values: [salt_species_count]f64 = undefined;
            for (&values, 0..) |*value, index|
                value.* = @as(f64, @floatFromInt(index + 1)) / 1000;
            break :values values;
        },
    };
    try initializeChemicalState(
        &state,
        &.{concentrations},
        &.{true},
        0.917,
        activation_heat_capacity_megajoules_per_m2_k,
    );
    const initial_g = try std.testing.allocator.dupe(f64, state.amount_g);
    defer std.testing.allocator.free(initial_g);
    const initial_salt_mol = try std.testing.allocator.dupe(f64, state.salt_amount_mol);
    defer std.testing.allocator.free(initial_salt_mol);

    const partition: SurfacePartition = .{
        .litter_cover_fraction = 0.25,
        .bare_soil_fraction = 0.75,
        .nonband_ammonium_fraction = 0.6,
        .band_ammonium_fraction = 0.4,
        .nonband_nitrate_fraction = 0.7,
        .band_nitrate_fraction = 0.3,
        .nonband_phosphate_fraction = 0.8,
        .band_phosphate_fraction = 0.2,
    };
    const downward = [_]f64{0};
    const litter = [_]f64{0.005};
    const micropore = [_]f64{0.01};
    const macropore = [_]f64{0.005};
    var fluxes = try calculateFluxes(
        std.testing.allocator,
        &state,
        &downward,
        &litter,
        &micropore,
        &macropore,
        &.{partition},
        .{ .water_absolute_m3 = 1e-12, .relative = 1e-10 },
    );
    defer fluxes.deinit();
    try state.state_updateMeltWater(
        &downward,
        &litter,
        &micropore,
        &macropore,
        test_melt_water_options,
    );
    try state_update(&state, &([_]f64{0} ** species_count), &fluxes);

    for (0..species_count) |species| {
        const discharged = fluxes.surface_discharge[0].litter_g[species] +
            fluxes.surface_discharge[0].soil_nonband_g[species] +
            fluxes.surface_discharge[0].soil_band_g[species];
        try std.testing.expectApproxEqAbs(
            initial_g[species],
            state.amount_g[species] + discharged,
            32 * std.math.floatEps(f64) * @max(1, initial_g[species]),
        );
    }
    for (0..salt_species_count) |species| {
        const discharged = fluxes.surface_discharge[0].litter_salt_mol[species] +
            fluxes.surface_discharge[0].soil_nonband_salt_mol[species] +
            fluxes.surface_discharge[0].soil_band_salt_mol[species];
        try std.testing.expectApproxEqAbs(
            initial_salt_mol[species],
            state.salt_amount_mol[species] + discharged,
            32 * std.math.floatEps(f64) * @max(1, initial_salt_mol[species]),
        );
    }
}

test "production owns pre-existing snow chemistry before baseline and preserves checkpoint chemistry" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    const owner = std.mem.indexOf(u8, source, "var initial_snow_chemistry_initialized = false;") orelse
        return error.MissingInitialSnowChemistryOwner;
    const checkpoint_swap = std.mem.indexOfPos(u8, source, owner, "try ecosys.checkpoint_bundle_reader.swapIntoLive") orelse
        return error.MissingSnowChemistryCheckpointRestore;
    const checkpoint_owned = std.mem.indexOfPos(u8, source, checkpoint_swap, "initial_snow_chemistry_initialized = true;") orelse
        return error.MissingSnowChemistryCheckpointOwnership;
    const initial_gate = std.mem.indexOfPos(u8, source, checkpoint_owned, "if (!timeline_state.initial_snow_chemistry_initialized)") orelse
        return error.MissingInitialSnowChemistryGate;
    const exact_presence_gate = std.mem.indexOfPos(u8, source, initial_gate, "activation_heat_capacity_megajoules_per_m2_k * area_m2") orelse
        return error.MissingExactInitialSnowPresenceGate;
    const gas_initialization = std.mem.indexOfPos(u8, source, exact_presence_gate, "snow_chemistry_initialization.initialPrecipitationDissolvedGasGPerM3(") orelse
        return error.MissingExactInitialSnowGasInitialization;
    const gas_activity = std.mem.indexOfPos(u8, source, gas_initialization, "driver_context.surface_gas_parameters.*.precipitation_activity_log") orelse
        return error.MissingInitialSnowGasActivityBinding;
    const initializer = std.mem.indexOfPos(u8, source, gas_activity, "snow_solute_transport.initializeChemicalState(") orelse
        return error.MissingInitialSnowChemistryBinding;
    const exact_threshold = std.mem.indexOfPos(u8, source, initializer, "snow_solute_transport.activation_heat_capacity_megajoules_per_m2_k") orelse
        return error.MissingInitialSnowChemistryThresholdBinding;
    const baseline = std.mem.indexOfPos(u8, source, exact_threshold, "const totals = try reconstructLandscapeMassBalance(") orelse
        return error.MissingPostSnowChemistryMassBaseline;
    try std.testing.expect(owner < checkpoint_swap and checkpoint_swap < checkpoint_owned);
    try std.testing.expect(checkpoint_owned < initial_gate and initial_gate < exact_presence_gate);
    try std.testing.expect(exact_presence_gate < gas_initialization and gas_initialization < gas_activity);
    try std.testing.expect(gas_activity < initializer);
    try std.testing.expect(initializer < exact_threshold and exact_threshold < baseline);
}

test "accepted fused snow substep binds exact melt admissibility and conservation replay" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_heat_water_solute.zig", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(source);
    const owner = std.mem.indexOf(u8, source, "fn advanceSourceOrderedSnowPhysics(") orelse return error.MissingAcceptedSubstepSnowOwner;
    const owner_end = std.mem.indexOfPos(u8, source, owner, "fn advanceSnowBeforeSoil(") orelse return error.MissingAcceptedSubstepSnowOwnerEnd;
    const melt_call = std.mem.indexOfPos(u8, source, owner, "snow_melt_water_routing.calculate(") orelse return error.MissingProductionSnowMeltWaterRouting;
    const admissibility_gate = std.mem.indexOfPos(u8, source, melt_call, "return error.SnowSourceOrderMeltOverdraw") orelse return error.MissingSnowMeltExactAdmissibilityGate;
    const replay = std.mem.indexOfPos(u8, source, admissibility_gate, "snow_source_order_energy.apply(") orelse return error.MissingSnowMeltExactConservationReplay;
    const replay_gate = std.mem.indexOfPos(u8, source, replay, "return error.SnowSourceOrderReplayMismatch") orelse return error.MissingSnowMeltExactConservationReplayGate;
    try std.testing.expect(owner < melt_call and melt_call < admissibility_gate and admissibility_gate < replay and replay < replay_gate and replay_gate < owner_end);

    const schedule_hook = std.mem.indexOf(u8, source, "fn prepareSubstep(raw:") orelse return error.MissingAcceptedSubstepPrepareHook;
    const scheduled_owner = std.mem.indexOfPos(u8, source, schedule_hook, "advanceSnowBeforeSoil(time_step_hours)") orelse return error.MissingAcceptedSubstepSnowOwnerCall;
    try std.testing.expect(schedule_hook < scheduled_owner and scheduled_owner < owner);
}

test "runtime snow layers route melt conservatively to lower layer and surface" {
    var state = try State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    state.active[0] = true;
    state.active[1] = true;
    state.liquid_water_volume_m3[0] = 2;
    state.liquid_water_volume_m3[1] = 2;
    @memset(try state.amounts(0, 0), 10);
    @memset(try state.amounts(0, 1), 4);
    const downward_water = [_]f64{ 0, 1, 0 };
    const partition = SurfacePartition{ .litter_cover_fraction = 0.25, .bare_soil_fraction = 0.75, .nonband_ammonium_fraction = 0.6, .band_ammonium_fraction = 0.4, .nonband_nitrate_fraction = 0.7, .band_nitrate_fraction = 0.3, .nonband_phosphate_fraction = 0.8, .band_phosphate_fraction = 0.2 };
    var fluxes = try calculateFluxes(std.testing.allocator, &state, &downward_water, &[_]f64{0.5}, &[_]f64{0.5}, &[_]f64{0}, &[_]SurfacePartition{partition}, .{ .water_absolute_m3 = 1e-12, .relative = 1e-10 });
    defer fluxes.deinit();
    const zero_input = [_]f64{0} ** species_count;
    try state_update(&state, &zero_input, &fluxes);
    var remaining: f64 = 0;
    for (state.amount_g) |amount| remaining += amount;
    var discharged: f64 = 0;
    for (fluxes.surface_discharge[0].litter_g, fluxes.surface_discharge[0].soil_nonband_g, fluxes.surface_discharge[0].soil_band_g) |a, b, c| discharged += a + b + c;
    try std.testing.expectApproxEqAbs(@as(f64, 14 * species_count), remaining + discharged, 1e-12);
}

test "snow flux rejects material carrier overdraft and source-limits only tolerance-sized roundoff" {
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.liquid_water_volume_m3[0] = 1;
    @memset(try state.amounts(0, 0), 3);
    @memset(try state.saltAmounts(0, 0), 0.2);
    const partition = SurfacePartition{ .litter_cover_fraction = 0.25, .bare_soil_fraction = 0.75, .nonband_ammonium_fraction = 0.6, .band_ammonium_fraction = 0.4, .nonband_nitrate_fraction = 0.7, .band_nitrate_fraction = 0.3, .nonband_phosphate_fraction = 0.8, .band_phosphate_fraction = 0.2 };
    const tolerances: FluxTolerances = .{ .water_absolute_m3 = 1e-12, .relative = 1e-10 };
    try std.testing.expectError(
        error.SnowSurfaceFluxExceedsInventory,
        calculateFluxes(std.testing.allocator, &state, &.{0}, &.{1.1}, &.{0}, &.{0}, &.{partition}, tolerances),
    );

    var fluxes = try calculateFluxes(std.testing.allocator, &state, &.{0}, &.{1 + 5e-13}, &.{0}, &.{0}, &.{partition}, tolerances);
    defer fluxes.deinit();
    for (0..species_count) |species| {
        const routed = fluxes.surface_discharge[0].litter_g[species] + fluxes.surface_discharge[0].soil_nonband_g[species] + fluxes.surface_discharge[0].soil_band_g[species];
        try std.testing.expectApproxEqAbs(@as(f64, 3), routed, 1e-14);
    }
    for (0..salt_species_count) |species| {
        const routed = fluxes.surface_discharge[0].litter_salt_mol[species] + fluxes.surface_discharge[0].soil_nonband_salt_mol[species] + fluxes.surface_discharge[0].soil_band_salt_mol[species];
        try std.testing.expectApproxEqAbs(@as(f64, 0.2), routed, 1e-15);
    }
    for (state.amount_g) |amount| try std.testing.expectEqual(@as(f64, 3), amount);
    for (state.salt_amount_mol) |amount| try std.testing.expectEqual(@as(f64, 0.2), amount);
}

test "failed snow state_update does not modify state" {
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.amount_g[0] = 1;
    const downward = try std.testing.allocator.alloc(f64, species_count);
    defer std.testing.allocator.free(downward);
    @memset(downward, 0);
    const downward_salt = try std.testing.allocator.alloc(f64, salt_species_count);
    defer std.testing.allocator.free(downward_salt);
    @memset(downward_salt, 0);
    const discharge = try std.testing.allocator.alloc(SurfaceDischarge, 1);
    defer std.testing.allocator.free(discharge);
    discharge[0] = .{};
    discharge[0].litter_g[0] = 2;
    const fluxes = Fluxes{ .allocator = std.testing.allocator, .downward_g = downward, .downward_salt_mol = downward_salt, .surface_discharge = discharge };
    const zero_input = [_]f64{0} ** species_count;
    try std.testing.expectError(error.InvalidSnowTransportCandidate, state_update(&state, &zero_input, &fluxes));
    try std.testing.expectEqual(@as(f64, 1), state.amount_g[0]);
}

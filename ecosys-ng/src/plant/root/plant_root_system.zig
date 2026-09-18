const std = @import("std");
const PlantTraits = @import("../../state/plant_traits.zig").PlantTraits;

pub const biological_domain_count: usize = 2;
pub const salt_species_count: usize = 8;
pub const organic_substrate_count: usize = 5;
pub const transported_root_gas_count: usize = 6;

pub const InitializationParameters = struct {
    root_nitrogen_to_maximum_protein_multiplier: f64,
    root_phosphorus_to_maximum_protein_multiplier: f64,
    mycorrhizal_radius_m: f64,
    initial_total_water_potential_megapascal: f64,
    osmotic_water_potential_decrement_megapascal: f64,
    initial_active_length_m: f64,
    initial_water_fraction: f64,

    pub fn validate(self: InitializationParameters) !void {
        inline for (@typeInfo(InitializationParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.NonFiniteRootInitializationParameter;
        if (self.root_nitrogen_to_maximum_protein_multiplier <= 0 or self.root_phosphorus_to_maximum_protein_multiplier <= 0 or self.mycorrhizal_radius_m <= 0 or self.initial_total_water_potential_megapascal > 0 or self.osmotic_water_potential_decrement_megapascal > 0 or self.initial_active_length_m < 0 or self.initial_water_fraction < 0 or self.initial_water_fraction > 1) return error.InvalidRootInitializationParameter;
    }
};

pub fn compatibilityInitializationParameters() InitializationParameters {
    return .{
        .root_nitrogen_to_maximum_protein_multiplier = 2.5,
        .root_phosphorus_to_maximum_protein_multiplier = 25.0,
        .mycorrhizal_radius_m = 2.5e-6,
        .initial_total_water_potential_megapascal = -0.01,
        .osmotic_water_potential_decrement_megapascal = -0.01,
        .initial_active_length_m = 1.0e-3,
        .initial_water_fraction = 1.0,
    };
}

pub const MorphologyParameters = struct {
    minimum_average_secondary_length_m: f64,
    root_elastic_modulus_megapascal: f64,

    pub fn validate(self: MorphologyParameters) !void {
        inline for (@typeInfo(MorphologyParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.NonFiniteRootMorphologyParameter;
        if (self.minimum_average_secondary_length_m <= 0 or self.root_elastic_modulus_megapascal <= 0) return error.InvalidRootMorphologyParameter;
    }
};

pub fn compatibilityMorphologyParameters() MorphologyParameters {
    return .{
        .minimum_average_secondary_length_m = 1.0e-2,
        .root_elastic_modulus_megapascal = 5.0,
    };
}
pub const SaltSpecies = enum(u8) { aluminum, iron, calcium, magnesium, sodium, potassium, sulfate, chloride };

pub const UptakeCompetition = struct {
    oxygen: f64,
    ammonium_nonband: f64,
    ammonium_band: f64,
    nitrate_nonband: f64,
    nitrate_band: f64,
    phosphate_h2_nonband: f64,
    phosphate_h2_band: f64,
    phosphate_h_nonband: f64,
    phosphate_h_band: f64,
};

/// UPTAKE competition fractions for one root or mycorrhizal population.
/// Previous-hour population demand is used when the corresponding combined
/// microbial/root demand is significant; otherwise the biome root fraction is
/// retained. The source minimum population share is applied independently to
/// every nutrient and soil-zone pool.
pub fn uptakeCompetition(
    minimum_population_fraction: f64,
    root_biome_fraction: f64,
    significance_threshold_g: f64,
    population_demand_g_per_h: UptakeCompetition,
    combined_demand_g_per_h: UptakeCompetition,
) !UptakeCompetition {
    inline for (.{ minimum_population_fraction, root_biome_fraction, significance_threshold_g }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteUptakeCompetitionInput;
    }
    if (minimum_population_fraction < 0 or root_biome_fraction < 0 or significance_threshold_g < 0) return error.InvalidUptakeCompetitionInput;

    var result: UptakeCompetition = undefined;
    inline for (@typeInfo(UptakeCompetition).@"struct".fields) |field| {
        const population_demand = @field(population_demand_g_per_h, field.name);
        const combined_demand = @field(combined_demand_g_per_h, field.name);
        if (!std.math.isFinite(population_demand) or population_demand < 0 or !std.math.isFinite(combined_demand) or combined_demand < 0) return error.InvalidUptakeCompetitionDemand;
        @field(result, field.name) = if (combined_demand > significance_threshold_g)
            @max(minimum_population_fraction, population_demand / combined_demand)
        else
            root_biome_fraction;
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteUptakeCompetitionResult;
    }
    return result;
}

/// Heap-owned STARTQ root/mycorrhizal state. Every extent is derived from the
/// runscript and mapped soil profiles; the historical NR=10 ceiling is absent.
pub const State = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    soil_layer_count: usize,
    root_axis_count: usize,
    /// Source `NG`, indexed by runtime plant; zero-based soil-layer index.
    planting_layer_by_plant: []usize,
    /// Source `NI`, indexed by runtime plant and shared by all of its
    /// biological domains; zero-based inclusive deepest rooted soil layer.
    current_deepest_rooted_layer_by_plant: []usize,
    /// Source `NIX`, indexed by runtime plant; zero-based inclusive deepest
    /// layer accumulated for state_update at the next biological boundary.
    next_deepest_rooted_layer_by_plant: []usize,
    /// Source `NINR`, indexed by runtime plant and root axis; zero-based
    /// inclusive deepest layer reached by that axis across root domains.
    deepest_rooted_layer_by_axis: []usize,
    active_root_axis_count: []usize,
    roots_dead: []bool,
    seed_volume_m3_per_plant: []f64,
    seed_length_m_per_plant: []f64,
    seed_surface_area_m2_per_plant: []f64,
    ammonium_uptake_g_n_per_h: []f64,
    nitrate_uptake_g_n_per_h: []f64,
    phosphate_uptake_g_p_per_h: []f64,
    fixation_uptake_g_n_per_h: []f64,
    /// Layer-resolved RUPNF owner; plant totals remain above for outputs.
    fixation_uptake_g_n_per_h_by_layer: []f64,
    /// GROSUB PORT indexed by runtime plant then biological domain.
    current_porosity_fraction_by_domain: []f64,
    /// GROSUB PORTI indexed by runtime plant then biological domain.
    initial_porosity_fraction_by_domain: []f64,
    water_uptake_m3_per_h: []f64,
    total_water_potential_megapascal: []f64,
    osmotic_water_potential_megapascal: []f64,
    turgor_water_potential_megapascal: []f64,
    mobile_carbon_g: []f64,
    mobile_nitrogen_g: []f64,
    mobile_phosphorus_g: []f64,
    symbiont_structural_carbon_g_c: []f64,
    symbiont_structural_nitrogen_g_n: []f64,
    symbiont_structural_phosphorus_g_p: []f64,
    symbiont_mobile_carbon_g_c: []f64,
    symbiont_mobile_nitrogen_g_n: []f64,
    symbiont_mobile_phosphorus_g_p: []f64,
    symbiotic_respiration_actual_g_c_per_h: []f64,
    symbiotic_respiration_oxygen_unlimited_g_c_per_h: []f64,
    mobile_carbon_concentration_g_per_g: []f64,
    mobile_nitrogen_concentration_g_per_g: []f64,
    mobile_phosphorus_concentration_g_per_g: []f64,
    salt_concentration_mol_per_g_c: []f64,
    maximum_protein_carbon_g_per_g_c: []f64,
    total_carbon_g: []f64,
    primary_root_carbon_g: []f64,
    protein_carbon_g: []f64,
    primary_radius_m: []f64,
    secondary_radius_m: []f64,
    reference_primary_radius_m: []f64,
    reference_secondary_radius_m: []f64,
    projected_area_m2: []f64,
    active_length_m: []f64,
    water_fraction: []f64,
    aqueous_volume_m3: []f64,
    gaseous_volume_m3: []f64,
    root_length_m_per_plant: []f64,
    root_length_density_m_per_m3: []f64,
    root_surface_area_m2_per_plant: []f64,
    average_secondary_length_m: []f64,
    /// GROSUB `RTNL`: authoritative secondary-axis count for one biological
    /// domain and soil layer. This is intentionally distinct from per-axis
    /// `axis_secondary_count` (`RTN2`): withdrawal moves the layer aggregate
    /// upward while clearing the withdrawing RTN2 without adding it to the
    /// destination RTN2 (grosub.f:7238--7242).
    secondary_axis_count_total: []f64,
    sink_strength_m: []f64,
    ammonium_uptake_nonband_g_n_per_h: []f64,
    nitrate_uptake_nonband_g_n_per_h: []f64,
    phosphate_h2_uptake_nonband_g_p_per_h: []f64,
    phosphate_h_uptake_nonband_g_p_per_h: []f64,
    ammonium_uptake_band_g_n_per_h: []f64,
    nitrate_uptake_band_g_n_per_h: []f64,
    phosphate_h2_uptake_band_g_p_per_h: []f64,
    phosphate_h_uptake_band_g_p_per_h: []f64,
    previous_ammonium_uptake_nonband_g_n_per_h: []f64,
    previous_nitrate_uptake_nonband_g_n_per_h: []f64,
    previous_phosphate_h2_uptake_nonband_g_p_per_h: []f64,
    previous_phosphate_h_uptake_nonband_g_p_per_h: []f64,
    previous_ammonium_uptake_band_g_n_per_h: []f64,
    previous_nitrate_uptake_band_g_n_per_h: []f64,
    previous_phosphate_h2_uptake_band_g_p_per_h: []f64,
    previous_phosphate_h_uptake_band_g_p_per_h: []f64,
    ammonium_demand_nonband_g_n_per_h: []f64,
    nitrate_demand_nonband_g_n_per_h: []f64,
    phosphate_h2_demand_nonband_g_p_per_h: []f64,
    phosphate_h_demand_nonband_g_p_per_h: []f64,
    ammonium_demand_band_g_n_per_h: []f64,
    nitrate_demand_band_g_n_per_h: []f64,
    phosphate_h2_demand_band_g_p_per_h: []f64,
    phosphate_h_demand_band_g_p_per_h: []f64,
    previous_ammonium_demand_nonband_g_n_per_h: []f64,
    previous_nitrate_demand_nonband_g_n_per_h: []f64,
    previous_phosphate_h2_demand_nonband_g_p_per_h: []f64,
    previous_phosphate_h_demand_nonband_g_p_per_h: []f64,
    previous_ammonium_demand_band_g_n_per_h: []f64,
    previous_nitrate_demand_band_g_n_per_h: []f64,
    previous_phosphate_h2_demand_band_g_p_per_h: []f64,
    previous_phosphate_h_demand_band_g_p_per_h: []f64,
    oxygen_uptake_g_o_per_h: []f64,
    oxygen_uptake_from_soil_g_o_per_h: []f64,
    oxygen_uptake_from_root_pool_g_o_per_h: []f64,
    oxygen_demand_g_o_per_h: []f64,
    /// UPTAKE ROXYP snapshot taken by `resetHourlyFluxes` before this hour's
    /// demand is recomputed; the FOXYX competition-fraction read side
    /// (`refreshOxygenPopulationCompetitionFraction`) reads only this array so
    /// a population's own this-hour demand cannot feed its own this-hour
    /// fraction (`uptake.f:1811` vs `1872`).
    previous_oxygen_demand_g_o_per_h: []f64,
    /// UPTAKE FOXYX for O2, computed by
    /// `refreshOxygenPopulationCompetitionFraction` from previous-hour demand
    /// only. Read directly by `solveOxygenUptake`'s input assembly.
    population_competition_fraction_g_o: []f64,
    respiration_unlimited_by_oxygen_g_c_per_h: []f64,
    respiration_unlimited_by_carbon_g_c_per_h: []f64,
    actual_respiration_g_c_per_h: []f64,
    oxygen_process_constraint_fraction: []f64,
    ammonium_assimilation_g_n_per_h: []f64,
    band_ammonium_assimilation_g_n_per_h: []f64,
    nitrate_assimilation_g_n_per_h: []f64,
    band_nitrate_assimilation_g_n_per_h: []f64,
    phosphate_h2_assimilation_g_p_per_h: []f64,
    phosphate_h_assimilation_g_p_per_h: []f64,
    band_phosphate_h2_assimilation_g_p_per_h: []f64,
    band_phosphate_h_assimilation_g_p_per_h: []f64,
    gaseous_carbon_dioxide_g_c: []f64,
    aqueous_carbon_dioxide_g_c: []f64,
    gaseous_oxygen_g_o: []f64,
    aqueous_oxygen_g_o: []f64,
    gaseous_methane_g_c: []f64,
    aqueous_methane_g_c: []f64,
    gaseous_nitrous_oxide_g_n: []f64,
    aqueous_nitrous_oxide_g_n: []f64,
    gaseous_ammonia_g_n: []f64,
    aqueous_ammonia_g_n: []f64,
    gaseous_hydrogen_g_h: []f64,
    aqueous_hydrogen_g_h: []f64,
    /// Accepted extensive transactions, indexed by rootIndex * 6 + gas.
    /// Gas order is CO2-C, CH4-C, N2O-N, NH3-N, H2-H, and O2-O.
    soil_to_root_gas_exchange_g_per_h: []f64,
    aqueous_to_gaseous_root_exchange_g_per_h: []f64,
    atmosphere_to_root_gas_exchange_g_per_h: []f64,
    /// Separate non-band and band NH3 soil-root exchange indexed by rootIndex.
    /// EXTRACT RUPN3S and RUPN3B per species/layer before per-layer summation.
    ammonia_nonband_soil_exchange_g_n_per_h: []f64,
    ammonia_band_soil_exchange_g_n_per_h: []f64,
    withdrawal_carbon_dioxide_loss_g_c_per_h: []f64,
    withdrawal_oxygen_loss_g_o_per_h: []f64,
    withdrawal_methane_loss_g_c_per_h: []f64,
    withdrawal_nitrous_oxide_loss_g_n_per_h: []f64,
    withdrawal_ammonia_loss_g_n_per_h: []f64,
    withdrawal_hydrogen_loss_g_h_per_h: []f64,
    /// Exact GROSUB root-layer origins for the six source-signed atmospheric
    /// gas releases above. Indexed like every root pool (plant, biological
    /// domain, soil layer); values are non-positive ecosystem losses. The
    /// per-plant arrays remain the reference output owner, while these
    /// sidecars retain the spatial provenance required for local closure.
    withdrawal_carbon_dioxide_loss_g_c_per_h_by_root: []f64,
    withdrawal_oxygen_loss_g_o_per_h_by_root: []f64,
    withdrawal_methane_loss_g_c_per_h_by_root: []f64,
    withdrawal_nitrous_oxide_loss_g_n_per_h_by_root: []f64,
    withdrawal_ammonia_loss_g_n_per_h_by_root: []f64,
    withdrawal_hydrogen_loss_g_h_per_h_by_root: []f64,
    combustion_carbon_loss_g_c_per_h: []f64,
    combustion_nitrogen_loss_g_n_per_h: []f64,
    combustion_phosphorus_loss_g_p_per_h: []f64,
    symbiont_combustion_g_c_per_h: []f64,
    root_combustion_g_c_per_h: []f64,
    combustion_salt_loss_mol_per_h: []f64,
    salt_content_mol: []f64,
    salt_uptake_mol_per_h: []f64,
    exudate_carbon_exchange_g_c_per_h: []f64,
    exudate_nitrogen_exchange_g_n_per_h: []f64,
    exudate_phosphorus_exchange_g_p_per_h: []f64,
    carbon_dioxide_advection_g_c_per_h: []f64,
    carbon_dioxide_diffusion_g_c_per_h: []f64,
    carbon_dioxide_solubilization_g_c_per_h: []f64,
    aqueous_carbon_dioxide_reaction_g_c_per_h: []f64,
    axis_depth_m: []f64,
    axis_primary_length_m: []f64,
    axis_primary_count: []f64,
    axis_primary_carbon_g: []f64,
    axis_primary_nitrogen_g: []f64,
    axis_primary_phosphorus_g: []f64,
    axis_secondary_length_m: []f64,
    axis_secondary_count: []f64,
    axis_secondary_carbon_g: []f64,
    axis_secondary_nitrogen_g: []f64,
    axis_secondary_phosphorus_g: []f64,
    /// GROSUB 507--508 `WTRTA`: retained root carbon per plant (g C plant-1).
    /// PERSISTENT per-plant state, because 507 is a recurrence on its own
    /// previous value (`AMAX1(0.999992087*WTRTA*XNFH, WTRT/PP)`), so it is not
    /// reconstructible from the current hour's pools alone. Sized
    /// `plant_count` by an explicit rule in `fieldCount`, and covered by
    /// `plant_root_checkpoint`'s reflective `[]f64` walk, which is what keeps
    /// restart equivalence intact (Wave 2 `RESTART-EQUIVALENCE`). See
    /// `primary_root_axis_scaling.advance` for the recurrence and
    /// `ecosys_ng.zig` `applyRootMetabolism` for the single production writer.
    retained_root_carbon_g_c_per_plant: []f64,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize, soil_layer_count: usize, root_axis_count: usize) !State {
        if (plant_count == 0 or soil_layer_count == 0 or root_axis_count == 0) return error.InvalidPlantRootDimensions;
        const domain_layer_count = try std.math.mul(usize, try std.math.mul(usize, plant_count, biological_domain_count), soil_layer_count);
        const domain_axis_count = try std.math.mul(usize, try std.math.mul(usize, plant_count, biological_domain_count), root_axis_count);
        const domain_layer_axis_count = try std.math.mul(usize, domain_layer_count, root_axis_count);
        const salt_count = try std.math.mul(usize, domain_layer_count, salt_species_count);
        const exudate_count = try std.math.mul(usize, domain_layer_count, organic_substrate_count);
        var result: State = undefined;
        result.allocator = allocator;
        result.plant_count = plant_count;
        result.soil_layer_count = soil_layer_count;
        result.root_axis_count = root_axis_count;
        result.planting_layer_by_plant = try allocator.alloc(usize, plant_count);
        errdefer allocator.free(result.planting_layer_by_plant);
        @memset(result.planting_layer_by_plant, 0);
        result.current_deepest_rooted_layer_by_plant = try allocator.alloc(usize, plant_count);
        errdefer allocator.free(result.current_deepest_rooted_layer_by_plant);
        @memset(result.current_deepest_rooted_layer_by_plant, 0);
        result.next_deepest_rooted_layer_by_plant = try allocator.alloc(usize, plant_count);
        errdefer allocator.free(result.next_deepest_rooted_layer_by_plant);
        @memset(result.next_deepest_rooted_layer_by_plant, 0);
        result.deepest_rooted_layer_by_axis =
            try allocator.alloc(usize, try std.math.mul(usize, plant_count, root_axis_count));
        errdefer allocator.free(result.deepest_rooted_layer_by_axis);
        @memset(result.deepest_rooted_layer_by_axis, 0);
        result.active_root_axis_count = try allocator.alloc(usize, plant_count);
        errdefer allocator.free(result.active_root_axis_count);
        @memset(result.active_root_axis_count, 0);
        result.roots_dead = try allocator.alloc(bool, plant_count);
        errdefer allocator.free(result.roots_dead);
        @memset(result.roots_dead, true);
        var float_fields = floatFieldPointers(&result);
        var allocated: usize = 0;
        errdefer freeFloatFields(allocator, float_fields[0..allocated]);
        for (&float_fields, float_field_extent_kinds) |field, extent_kind| {
            field.* = try allocateZeroedFloatField(allocator, fieldExtent(
                extent_kind,
                plant_count,
                plant_count * biological_domain_count,
                domain_layer_count,
                domain_axis_count,
                domain_layer_axis_count,
                salt_count,
                exudate_count,
            ));
            allocated += 1;
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        var float_fields = floatFieldPointers(self);
        freeFloatFields(self.allocator, &float_fields);
        self.allocator.free(self.roots_dead);
        self.allocator.free(self.active_root_axis_count);
        self.allocator.free(self.deepest_rooted_layer_by_axis);
        self.allocator.free(self.next_deepest_rooted_layer_by_plant);
        self.allocator.free(self.current_deepest_rooted_layer_by_plant);
        self.allocator.free(self.planting_layer_by_plant);
        self.* = undefined;
    }

    pub fn layerIndex(self: State, plant: usize, domain: usize, layer: usize) !usize {
        if (plant >= self.plant_count or domain >= biological_domain_count or layer >= self.soil_layer_count) return error.PlantRootIndexOutOfBounds;
        return (plant * biological_domain_count + domain) * self.soil_layer_count + layer;
    }

    pub fn domainIndex(self: State, plant: usize, domain: usize) !usize {
        if (plant >= self.plant_count or domain >= biological_domain_count)
            return error.PlantRootIndexOutOfBounds;
        return plant * biological_domain_count + domain;
    }

    /// Records source `NIX=MAX(NIX,NINR)` without changing the `NI` range
    /// consumed during the current biological step.
    pub fn includeNextDeepestRootedLayer(self: *State, plant: usize, layer: usize) !void {
        if (plant >= self.plant_count or layer >= self.soil_layer_count)
            return error.PlantRootLayerOutOfBounds;
        self.next_deepest_rooted_layer_by_plant[plant] =
            @max(self.next_deepest_rooted_layer_by_plant[plant], layer);
    }

    /// Rebuilds source `NIX=MAX(NIX,NINR(NR))` after every axis has completed
    /// extension or withdrawal for the current biological step.
    pub fn rebuildNextDeepestRootedLayerFromAxes(self: *State, plant: usize) !void {
        if (plant >= self.plant_count) return error.PlantRootIndexOutOfBounds;
        var deepest = self.planting_layer_by_plant[plant];
        if (deepest >= self.soil_layer_count) return error.InvalidRootedLayerBounds;
        for (0..self.active_root_axis_count[plant]) |axis| {
            const axis_deepest =
                self.deepest_rooted_layer_by_axis[try self.rootAxisIndex(plant, axis)];
            if (axis_deepest < self.planting_layer_by_plant[plant] or
                axis_deepest >= self.soil_layer_count)
                return error.InvalidRootedLayerBounds;
            deepest = @max(deepest, axis_deepest);
        }
        self.next_deepest_rooted_layer_by_plant[plant] = deepest;
    }

    /// Biological-step boundary corresponding to `NI=NIX`. Source `NIX`
    /// (grosub.f:7332, `NIX=MAX(NIX,NINR(NR))`) never regresses below an
    /// axis's already-reached depth on an hour without a fresh crossing --
    /// `NINR` itself only shrinks via the explicit withdrawal path
    /// (grosub.f:7127-7292), so the ordinary every-hour re-affirmation keeps
    /// `NIX` pinned at least as deep as the last hour's published value.
    /// Resetting `next_deepest_rooted_layer_by_plant` down to
    /// `planting_layer_by_plant` here would silently un-deepen the boundary
    /// on the very next non-crossing hour even though the axis's root mass
    /// is still fully present in the deeper layers, so the accumulator for
    /// the next hour's `includeNextDeepestRootedLayer` ratchet is instead
    /// seeded from the depth just published, matching source's non-shrinking
    /// behavior. The half-open plant range supports deterministic tile
    /// decomposition; every plant remains independent at this boundary.
    pub fn advanceRootedLayerBoundary(self: *State, first_plant: usize, end_plant: usize) !void {
        if (first_plant > end_plant or end_plant > self.plant_count)
            return error.PlantRootRangeOutOfBounds;
        for (first_plant..end_plant) |plant| {
            const planting_layer = self.planting_layer_by_plant[plant];
            const next_deepest = self.next_deepest_rooted_layer_by_plant[plant];
            if (planting_layer >= self.soil_layer_count or next_deepest < planting_layer or
                next_deepest >= self.soil_layer_count)
                return error.InvalidRootedLayerBounds;
        }
        for (first_plant..end_plant) |plant| {
            self.current_deepest_rooted_layer_by_plant[plant] =
                self.next_deepest_rooted_layer_by_plant[plant];
        }
    }

    pub fn axisIndex(self: State, plant: usize, domain: usize, axis: usize) !usize {
        if (plant >= self.plant_count or domain >= biological_domain_count or axis >= self.root_axis_count) return error.PlantRootIndexOutOfBounds;
        return (plant * biological_domain_count + domain) * self.root_axis_count + axis;
    }

    pub fn rootAxisIndex(self: State, plant: usize, axis: usize) !usize {
        if (plant >= self.plant_count or axis >= self.root_axis_count)
            return error.PlantRootIndexOutOfBounds;
        return plant * self.root_axis_count + axis;
    }

    pub fn layerAxisIndex(self: State, plant: usize, domain: usize, layer: usize, axis: usize) !usize {
        return (try self.layerIndex(plant, domain, layer)) * self.root_axis_count + axis;
    }

    pub fn saltIndex(self: State, plant: usize, domain: usize, layer: usize, species: SaltSpecies) !usize {
        return try std.math.add(usize, try std.math.mul(usize, try self.layerIndex(plant, domain, layer), salt_species_count), @intFromEnum(species));
    }

    pub fn substrateIndex(self: State, plant: usize, domain: usize, layer: usize, substrate: usize) !usize {
        if (substrate >= organic_substrate_count) return error.PlantRootSubstrateIndexOutOfBounds;
        return try std.math.add(usize, try std.math.mul(usize, try self.layerIndex(plant, domain, layer), organic_substrate_count), substrate);
    }

    pub fn initializePlant(self: *State, plant: usize, traits: PlantTraits, planting_layer: usize, seeding_depth_m: f64, parameters: InitializationParameters) !void {
        try parameters.validate();
        if (plant >= self.plant_count or planting_layer >= self.soil_layer_count) return error.PlantRootIndexOutOfBounds;
        if (!std.math.isFinite(seeding_depth_m) or seeding_depth_m < 0) return error.InvalidPlantingDepth;
        self.planting_layer_by_plant[plant] = planting_layer;
        self.current_deepest_rooted_layer_by_plant[plant] = planting_layer;
        self.next_deepest_rooted_layer_by_plant[plant] = planting_layer;
        for (0..self.root_axis_count) |axis|
            self.deepest_rooted_layer_by_axis[try self.rootAxisIndex(plant, axis)] =
                planting_layer;
        self.active_root_axis_count[plant] = 0;
        self.roots_dead[plant] = true;
        const maximum_protein = @min(
            traits.organ_nitrogen_to_carbon_ratio.root * parameters.root_nitrogen_to_maximum_protein_multiplier,
            traits.organ_phosphorus_to_carbon_ratio.root * parameters.root_phosphorus_to_maximum_protein_multiplier,
        );
        if (!std.math.isFinite(maximum_protein) or maximum_protein < 0) return error.InvalidRootProteinConcentration;
        for (0..biological_domain_count) |domain| {
            const domain_index = try self.domainIndex(plant, domain);
            self.current_porosity_fraction_by_domain[domain_index] = traits.roots.root_porosity_fraction;
            self.initial_porosity_fraction_by_domain[domain_index] = traits.roots.root_porosity_fraction;
            const primary_radius_m = if (domain == 0) traits.roots.primary_root_radius_m else parameters.mycorrhizal_radius_m;
            const secondary_radius_m = if (domain == 0) traits.roots.secondary_root_radius_m else parameters.mycorrhizal_radius_m;
            if (!std.math.isFinite(primary_radius_m) or primary_radius_m <= 0 or !std.math.isFinite(secondary_radius_m) or secondary_radius_m <= 0) return error.InvalidRootRadius;
            for (0..self.soil_layer_count) |layer| {
                const index = try self.layerIndex(plant, domain, layer);
                self.total_water_potential_megapascal[index] = parameters.initial_total_water_potential_megapascal;
                self.osmotic_water_potential_megapascal[index] = traits.water_relations.osmotic_potential_megapascal + parameters.osmotic_water_potential_decrement_megapascal;
                self.turgor_water_potential_megapascal[index] = @max(0.0, parameters.initial_total_water_potential_megapascal - self.osmotic_water_potential_megapascal[index]);
                self.maximum_protein_carbon_g_per_g_c[index] = maximum_protein;
                self.primary_radius_m[index] = primary_radius_m;
                self.secondary_radius_m[index] = secondary_radius_m;
                self.reference_primary_radius_m[index] = primary_radius_m;
                self.reference_secondary_radius_m[index] = secondary_radius_m;
                self.active_length_m[index] = parameters.initial_active_length_m;
                self.water_fraction[index] = parameters.initial_water_fraction;
            }
            for (0..self.root_axis_count) |axis| self.axis_depth_m[try self.axisIndex(plant, domain, axis)] = seeding_depth_m;
        }
    }

    /// Stores STARTQ SDVL/SDLG/SDAR seed geometry. GROSUB applies it only to
    /// the root domain in the planting layer.
    pub fn setSeedGeometry(self: *State, plant: usize, volume_m3_per_plant: f64, length_m_per_plant: f64, surface_area_m2_per_plant: f64) !void {
        if (plant >= self.plant_count) return error.PlantRootIndexOutOfBounds;
        inline for (.{ volume_m3_per_plant, length_m_per_plant, surface_area_m2_per_plant }) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSeedGeometry;
        }
        self.seed_volume_m3_per_plant[plant] = volume_m3_per_plant;
        self.seed_length_m_per_plant[plant] = length_m_per_plant;
        self.seed_surface_area_m2_per_plant[plant] = surface_area_m2_per_plant;
    }

    /// Reconstructs one runtime plant after a terminating harvest. Every
    /// plant-major persistent pool and diagnostic is cleared before STARTQ
    /// geometry and water status are applied, so a new crop cannot inherit
    /// C/N/P, gas, salt, exudate, demand, or root-axis history.
    pub fn reconstructPlant(self: *State, plant: usize, traits: PlantTraits, planting_layer: usize, seeding_depth_m: f64, parameters: InitializationParameters) !void {
        if (plant >= self.plant_count) return error.PlantRootIndexOutOfBounds;
        var float_fields = floatFieldPointers(self);
        try clearPlantFloatFields(&float_fields, self.plant_count, plant);
        self.planting_layer_by_plant[plant] = 0;
        self.current_deepest_rooted_layer_by_plant[plant] = 0;
        self.next_deepest_rooted_layer_by_plant[plant] = 0;
        @memset(
            self.deepest_rooted_layer_by_axis[plant * self.root_axis_count .. (plant + 1) * self.root_axis_count],
            0,
        );
        self.active_root_axis_count[plant] = 0;
        self.roots_dead[plant] = true;
        try self.initializePlant(plant, traits, planting_layer, seeding_depth_m, parameters);
    }

    /// GROSUB 371--376 resets per-layer `RTN1` and `RTNL` before rebuilding
    /// them. `axis_primary_count` stores each runtime axis's RTN1 contribution;
    /// RTN2 itself is persistent and is therefore not cleared here.
    pub fn resetGrosubAxisCountAggregates(self: *State, plant: usize) !void {
        if (plant >= self.plant_count) return error.PlantRootIndexOutOfBounds;
        const layer_count_per_plant = biological_domain_count * self.soil_layer_count;
        const first_layer = plant * layer_count_per_plant;
        @memset(self.secondary_axis_count_total[first_layer .. first_layer + layer_count_per_plant], 0);
        const axis_count_per_plant = layer_count_per_plant * self.root_axis_count;
        const first_axis_layer = plant * axis_count_per_plant;
        @memset(self.axis_primary_count[first_axis_layer .. first_axis_layer + axis_count_per_plant], 0);
    }

    pub const LayerTopology = struct {
        primary_axis_count: f64,
        secondary_axis_count: f64,
        primary_length_m_per_plant: f64,
        secondary_length_m_per_cell: f64,
        total_root_length_m: f64,
        root_length_m_per_plant: f64,
        root_length_density_m_per_m3: f64,
        average_secondary_length_m: f64,
    };

    pub const SourceOrderLayerCarbonTotals = struct {
        active_secondary_carbon_g_c: f64,
        actual_primary_and_secondary_carbon_g_c: f64,
    };

    /// Exact GROSUB 8210-8218 WTRTL/WTRTD operands for one root domain/layer.
    pub fn sourceOrderLayerCarbonTotals(
        primary_carbon_g_c_by_axis: []const f64,
        secondary_carbon_g_c_by_axis: []const f64,
    ) !SourceOrderLayerCarbonTotals {
        if (primary_carbon_g_c_by_axis.len != secondary_carbon_g_c_by_axis.len)
            return error.RootCarbonTotalDimensionMismatch;
        var result: SourceOrderLayerCarbonTotals = .{
            .active_secondary_carbon_g_c = 0,
            .actual_primary_and_secondary_carbon_g_c = 0,
        };
        for (primary_carbon_g_c_by_axis, secondary_carbon_g_c_by_axis) |primary, secondary| {
            if (!std.math.isFinite(primary) or !std.math.isFinite(secondary) or primary < 0 or secondary < 0)
                return error.InvalidRootCarbonTotalInput;
            result.active_secondary_carbon_g_c += secondary;
            result.actual_primary_and_secondary_carbon_g_c += secondary + primary;
        }
        if (!std.math.isFinite(result.active_secondary_carbon_g_c) or
            !std.math.isFinite(result.actual_primary_and_secondary_carbon_g_c))
            return error.NonFiniteRootCarbonTotal;
        return result;
    }

    /// GROSUB WTRTL active-root C reconstruction. Secondary-root C remains in
    /// its physical layer; the complete primary C of each axis is assigned to
    /// that axis's deepest occupied tip layer (NINR).
    pub fn refreshActiveCarbonByLayer(self: *State, plant: usize, domain: usize) !void {
        if (plant >= self.plant_count or domain >= biological_domain_count) return error.PlantRootIndexOutOfBounds;
        for (0..self.soil_layer_count) |layer| {
            const root = try self.layerIndex(plant, domain, layer);
            self.total_carbon_g[root] = 0;
        }
        const active_axes = self.active_root_axis_count[plant];
        if (active_axes > self.root_axis_count) return error.InvalidActiveRootAxisCount;
        for (0..active_axes) |axis| {
            var total_primary_carbon_g_c: f64 = 0;
            var tip_layer: usize = self.planting_layer_by_plant[plant];
            if (tip_layer >= self.soil_layer_count) return error.PlantRootLayerOutOfBounds;
            for (0..self.soil_layer_count) |layer| {
                const axis_layer = try self.layerAxisIndex(plant, domain, layer, axis);
                const primary = self.axis_primary_carbon_g[axis_layer];
                const secondary = self.axis_secondary_carbon_g[axis_layer];
                const primary_length = self.axis_primary_length_m[axis_layer];
                inline for (.{ primary, secondary, primary_length }) |value|
                    if (!std.math.isFinite(value) or value < 0) return error.InvalidRootActiveCarbonState;
                total_primary_carbon_g_c += primary;
                self.total_carbon_g[try self.layerIndex(plant, domain, layer)] += secondary;
                if (primary > 0 or primary_length > 0) tip_layer = layer;
            }
            const tip = try self.layerIndex(plant, domain, tip_layer);
            self.total_carbon_g[tip] += total_primary_carbon_g_c;
            if (!std.math.isFinite(self.total_carbon_g[tip])) return error.NonFiniteRootActiveCarbon;
        }
        for (0..self.soil_layer_count) |layer| {
            const value = self.total_carbon_g[try self.layerIndex(plant, domain, layer)];
            if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootActiveCarbon;
        }
    }

    /// GROSUB RTLGT/RTLGP/RTDNP/RTLGA aggregation over runtime root axes.
    pub fn layerTopology(self: State, plant: usize, domain: usize, layer: usize, plant_population_count: f64, layer_thickness_m: f64, woody_root_fraction: f64, minimum_average_secondary_length_m: f64) !LayerTopology {
        inline for (.{ plant_population_count, layer_thickness_m, woody_root_fraction, minimum_average_secondary_length_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootTopologyInput;
        if (plant_population_count <= 0 or layer_thickness_m <= 0 or woody_root_fraction < 0 or woody_root_fraction > 1 or minimum_average_secondary_length_m < 0) return error.InvalidRootTopologyInput;
        var primary_count: f64 = 0;
        const root = try self.layerIndex(plant, domain, layer);
        const secondary_count = self.secondary_axis_count_total[root];
        if (!std.math.isFinite(secondary_count) or secondary_count < 0) return error.InvalidRootTopologyState;
        var primary_length: f64 = 0;
        var secondary_length: f64 = 0;
        for (0..self.root_axis_count) |axis| {
            const index = try self.layerAxisIndex(plant, domain, layer, axis);
            inline for (.{ self.axis_primary_count[index], self.axis_secondary_count[index], self.axis_primary_length_m[index], self.axis_secondary_length_m[index] }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootTopologyState;
            primary_count += self.axis_primary_count[index];
            primary_length += self.axis_primary_length_m[index];
            secondary_length += self.axis_secondary_length_m[index];
        }
        const total_length = primary_length * plant_population_count + secondary_length;
        const seed_length_m = if (domain == 0 and layer == self.planting_layer_by_plant[plant]) self.seed_length_m_per_plant[plant] else 0;
        if (!std.math.isFinite(seed_length_m) or seed_length_m < 0) return error.InvalidSeedGeometry;
        const length_per_plant = total_length / plant_population_count * woody_root_fraction + seed_length_m;
        return .{
            .primary_axis_count = primary_count,
            .secondary_axis_count = secondary_count,
            .primary_length_m_per_plant = primary_length,
            .secondary_length_m_per_cell = secondary_length,
            .total_root_length_m = total_length,
            .root_length_m_per_plant = length_per_plant,
            .root_length_density_m_per_m3 = length_per_plant / layer_thickness_m,
            .average_secondary_length_m = if (secondary_count > 0) @max(minimum_average_secondary_length_m, secondary_length / secondary_count) else minimum_average_secondary_length_m,
        };
    }

    pub fn refreshLayerMorphology(self: *State, plant: usize, domain: usize, layer: usize, plant_population_count: f64, layer_thickness_m: f64, woody_root_fraction: f64, root_porosity_fraction: f64, volume_m3_per_g_c: f64, root_geometry_pi: f64, vascular_growth_habit: bool, parameters: MorphologyParameters) !LayerTopology {
        try parameters.validate();
        if (!std.math.isFinite(root_porosity_fraction) or root_porosity_fraction < 0 or root_porosity_fraction >= 1 or !std.math.isFinite(volume_m3_per_g_c) or volume_m3_per_g_c <= 0 or !std.math.isFinite(root_geometry_pi) or root_geometry_pi <= 0) return error.InvalidRootMorphologyInput;
        const topology = try self.layerTopology(plant, domain, layer, plant_population_count, layer_thickness_m, woody_root_fraction, parameters.minimum_average_secondary_length_m);
        const index = try self.layerIndex(plant, domain, layer);
        const total_carbon = self.total_carbon_g[index];
        const primary_carbon = self.primary_root_carbon_g[index];
        const turgor = self.turgor_water_potential_megapascal[index];
        const total_water_potential = self.total_water_potential_megapascal[index];
        if (!std.math.isFinite(total_carbon) or total_carbon < 0 or !std.math.isFinite(primary_carbon) or primary_carbon < 0 or primary_carbon > total_carbon or !std.math.isFinite(turgor) or turgor < 0 or !std.math.isFinite(total_water_potential) or total_water_potential > 0) return error.InvalidRootMorphologyState;
        const reference_primary_radius_m = self.reference_primary_radius_m[index];
        const reference_secondary_radius_m = self.reference_secondary_radius_m[index];
        if (!std.math.isFinite(reference_primary_radius_m) or reference_primary_radius_m <= 0 or !std.math.isFinite(reference_secondary_radius_m) or reference_secondary_radius_m <= 0) return error.InvalidRootMorphologyState;
        const has_live_roots = topology.total_root_length_m > 0 and total_carbon > 0;
        var root_volume_m3: f64 = 0;
        var surface_area_m2: f64 = 0;
        if (has_live_roots) {
            self.primary_radius_m[index] = @max(reference_primary_radius_m, (1.0 + total_water_potential / parameters.root_elastic_modulus_megapascal) * reference_primary_radius_m);
            self.secondary_radius_m[index] = @max(reference_secondary_radius_m, (1.0 + total_water_potential / parameters.root_elastic_modulus_megapascal) * reference_secondary_radius_m);
            const secondary_carbon_g = total_carbon - primary_carbon;
            root_volume_m3 = @max(
                root_geometry_pi * reference_secondary_radius_m * reference_secondary_radius_m * topology.secondary_length_m_per_cell,
                secondary_carbon_g * volume_m3_per_g_c * turgor,
            );
            const circumference_factor = 2.0 * root_geometry_pi;
            surface_area_m2 = circumference_factor * self.primary_radius_m[index] * topology.primary_length_m_per_plant * plant_population_count + circumference_factor * self.secondary_radius_m[index] * topology.secondary_length_m_per_cell;
            if (vascular_growth_habit) surface_area_m2 *= parameters.minimum_average_secondary_length_m / topology.average_secondary_length_m;
        } else {
            inline for (.{
                .{ "gaseous_carbon_dioxide_g_c", "aqueous_carbon_dioxide_g_c", "withdrawal_carbon_dioxide_loss_g_c_per_h", "withdrawal_carbon_dioxide_loss_g_c_per_h_by_root" },
                .{ "gaseous_oxygen_g_o", "aqueous_oxygen_g_o", "withdrawal_oxygen_loss_g_o_per_h", "withdrawal_oxygen_loss_g_o_per_h_by_root" },
                .{ "gaseous_methane_g_c", "aqueous_methane_g_c", "withdrawal_methane_loss_g_c_per_h", "withdrawal_methane_loss_g_c_per_h_by_root" },
                .{ "gaseous_nitrous_oxide_g_n", "aqueous_nitrous_oxide_g_n", "withdrawal_nitrous_oxide_loss_g_n_per_h", "withdrawal_nitrous_oxide_loss_g_n_per_h_by_root" },
                .{ "gaseous_ammonia_g_n", "aqueous_ammonia_g_n", "withdrawal_ammonia_loss_g_n_per_h", "withdrawal_ammonia_loss_g_n_per_h_by_root" },
                .{ "gaseous_hydrogen_g_h", "aqueous_hydrogen_g_h", "withdrawal_hydrogen_loss_g_h_per_h", "withdrawal_hydrogen_loss_g_h_per_h_by_root" },
            }) |fields| {
                const released = @field(self, fields[0])[index] + @field(self, fields[1])[index];
                if (!std.math.isFinite(released) or
                    !std.math.isFinite(@field(self, fields[2])[plant] - released) or
                    !std.math.isFinite(@field(self, fields[3])[index] - released))
                    return error.InvalidRootMorphologyState;
            }
            self.primary_radius_m[index] = reference_primary_radius_m;
            self.secondary_radius_m[index] = reference_secondary_radius_m;
            inline for (.{
                .{ "gaseous_carbon_dioxide_g_c", "aqueous_carbon_dioxide_g_c", "withdrawal_carbon_dioxide_loss_g_c_per_h", "withdrawal_carbon_dioxide_loss_g_c_per_h_by_root" },
                .{ "gaseous_oxygen_g_o", "aqueous_oxygen_g_o", "withdrawal_oxygen_loss_g_o_per_h", "withdrawal_oxygen_loss_g_o_per_h_by_root" },
                .{ "gaseous_methane_g_c", "aqueous_methane_g_c", "withdrawal_methane_loss_g_c_per_h", "withdrawal_methane_loss_g_c_per_h_by_root" },
                .{ "gaseous_nitrous_oxide_g_n", "aqueous_nitrous_oxide_g_n", "withdrawal_nitrous_oxide_loss_g_n_per_h", "withdrawal_nitrous_oxide_loss_g_n_per_h_by_root" },
                .{ "gaseous_ammonia_g_n", "aqueous_ammonia_g_n", "withdrawal_ammonia_loss_g_n_per_h", "withdrawal_ammonia_loss_g_n_per_h_by_root" },
                .{ "gaseous_hydrogen_g_h", "aqueous_hydrogen_g_h", "withdrawal_hydrogen_loss_g_h_per_h", "withdrawal_hydrogen_loss_g_h_per_h_by_root" },
            }) |fields| {
                const released = @field(self, fields[0])[index] + @field(self, fields[1])[index];
                @field(self, fields[2])[plant] -= released;
                @field(self, fields[3])[index] -= released;
                @field(self, fields[0])[index] = 0;
                @field(self, fields[1])[index] = 0;
            }
        }
        const seed_volume_m3 = if (domain == 0 and layer == self.planting_layer_by_plant[plant]) self.seed_volume_m3_per_plant[plant] * plant_population_count else 0;
        if (!std.math.isFinite(seed_volume_m3) or seed_volume_m3 < 0) return error.InvalidSeedGeometry;
        const total_volume_m3 = root_volume_m3 + seed_volume_m3;
        self.gaseous_volume_m3[index] = root_porosity_fraction * total_volume_m3;
        self.aqueous_volume_m3[index] = (1.0 - root_porosity_fraction) * total_volume_m3;
        self.root_length_m_per_plant[index] = topology.root_length_m_per_plant;
        self.root_length_density_m_per_m3[index] = topology.root_length_density_m_per_m3;
        self.average_secondary_length_m[index] = topology.average_secondary_length_m;
        const seed_surface_area_m2 = if (domain == 0 and layer == self.planting_layer_by_plant[plant]) self.seed_surface_area_m2_per_plant[plant] else 0;
        if (!std.math.isFinite(seed_surface_area_m2) or seed_surface_area_m2 < 0) return error.InvalidSeedGeometry;
        self.root_surface_area_m2_per_plant[index] = surface_area_m2 / plant_population_count * woody_root_fraction + seed_surface_area_m2;
        return topology;
    }

    pub fn refreshLayerMorphologySourceOrder(
        self: *State,
        plant: usize,
        domain: usize,
        layer: usize,
        plant_population_count: f64,
        layer_thickness_m: f64,
        minimum_layer_thickness_m: f64,
        woody_root_fraction: f64,
        root_porosity_fraction: f64,
        volume_m3_per_g_c: f64,
        root_geometry_pi: f64,
        vascular_growth_habit: bool,
        parameters: MorphologyParameters,
    ) !LayerTopology {
        var topology = try self.refreshLayerMorphology(
            plant,
            domain,
            layer,
            plant_population_count,
            layer_thickness_m,
            woody_root_fraction,
            root_porosity_fraction,
            volume_m3_per_g_c,
            root_geometry_pi,
            vascular_growth_habit,
            parameters,
        );
        topology.root_length_density_m_per_m3 =
            try sourceOrderRootLengthDensity(
                topology.root_length_m_per_plant,
                layer_thickness_m,
                minimum_layer_thickness_m,
            );
        self.root_length_density_m_per_m3[
            try self.layerIndex(plant, domain, layer)
        ] = topology.root_length_density_m_per_m3;
        return topology;
    }

    pub noinline fn validateFinite(self: State) !void {
        if (self.planting_layer_by_plant.len != self.plant_count or
            self.current_deepest_rooted_layer_by_plant.len != self.plant_count or
            self.next_deepest_rooted_layer_by_plant.len != self.plant_count or
            self.deepest_rooted_layer_by_axis.len !=
                self.plant_count * self.root_axis_count)
            return error.InvalidPlantRootTopology;
        for (0..self.plant_count) |plant| {
            const planting = self.planting_layer_by_plant[plant];
            const current = self.current_deepest_rooted_layer_by_plant[plant];
            const next = self.next_deepest_rooted_layer_by_plant[plant];
            if (planting >= self.soil_layer_count or current < planting or
                current >= self.soil_layer_count or next < planting or next >= self.soil_layer_count)
                return error.InvalidRootedLayerBounds;
            for (0..self.root_axis_count) |axis| {
                const deepest =
                    self.deepest_rooted_layer_by_axis[try self.rootAxisIndex(plant, axis)];
                if (deepest < planting or deepest >= self.soil_layer_count)
                    return error.InvalidRootedLayerBounds;
            }
        }
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| if (!std.math.isFinite(value)) {
            std.log.err("non-finite plant root state: field={s} index={d} value={e}", .{ field.name, index, value });
            return error.NonFinitePlantRootState;
        };
        inline for (.{ self.current_porosity_fraction_by_domain, self.initial_porosity_fraction_by_domain }) |porosity_by_domain|
            for (porosity_by_domain) |porosity|
                if (porosity < 0 or porosity >= 1) return error.InvalidPlantRootPorosityState;
    }

    /// UPTAKE hourly flux initialization. Persistent C/N/P, gas inventories,
    /// morphology, potentials, axis state, and the prior GROSUB WSRTL uptake
    /// diagnostic are deliberately not cleared.
    pub fn resetHourlyFluxes(self: *State) void {
        @memcpy(self.previous_ammonium_uptake_nonband_g_n_per_h, self.ammonium_uptake_nonband_g_n_per_h);
        @memcpy(self.previous_nitrate_uptake_nonband_g_n_per_h, self.nitrate_uptake_nonband_g_n_per_h);
        @memcpy(self.previous_phosphate_h2_uptake_nonband_g_p_per_h, self.phosphate_h2_uptake_nonband_g_p_per_h);
        @memcpy(self.previous_phosphate_h_uptake_nonband_g_p_per_h, self.phosphate_h_uptake_nonband_g_p_per_h);
        @memcpy(self.previous_ammonium_uptake_band_g_n_per_h, self.ammonium_uptake_band_g_n_per_h);
        @memcpy(self.previous_nitrate_uptake_band_g_n_per_h, self.nitrate_uptake_band_g_n_per_h);
        @memcpy(self.previous_phosphate_h2_uptake_band_g_p_per_h, self.phosphate_h2_uptake_band_g_p_per_h);
        @memcpy(self.previous_phosphate_h_uptake_band_g_p_per_h, self.phosphate_h_uptake_band_g_p_per_h);
        @memcpy(self.previous_oxygen_demand_g_o_per_h, self.oxygen_demand_g_o_per_h);
        inline for (.{
            self.ammonium_uptake_g_n_per_h,
            self.nitrate_uptake_g_n_per_h,
            self.phosphate_uptake_g_p_per_h,
            self.fixation_uptake_g_n_per_h,
            self.fixation_uptake_g_n_per_h_by_layer,
            self.water_uptake_m3_per_h,
            self.ammonium_uptake_nonband_g_n_per_h,
            self.nitrate_uptake_nonband_g_n_per_h,
            self.phosphate_h2_uptake_nonband_g_p_per_h,
            self.phosphate_h_uptake_nonband_g_p_per_h,
            self.ammonium_uptake_band_g_n_per_h,
            self.nitrate_uptake_band_g_n_per_h,
            self.phosphate_h2_uptake_band_g_p_per_h,
            self.phosphate_h_uptake_band_g_p_per_h,
            self.ammonium_demand_nonband_g_n_per_h,
            self.nitrate_demand_nonband_g_n_per_h,
            self.phosphate_h2_demand_nonband_g_p_per_h,
            self.phosphate_h_demand_nonband_g_p_per_h,
            self.ammonium_demand_band_g_n_per_h,
            self.nitrate_demand_band_g_n_per_h,
            self.phosphate_h2_demand_band_g_p_per_h,
            self.phosphate_h_demand_band_g_p_per_h,
            self.oxygen_uptake_g_o_per_h,
            self.oxygen_uptake_from_soil_g_o_per_h,
            self.oxygen_uptake_from_root_pool_g_o_per_h,
            self.oxygen_demand_g_o_per_h,
            self.respiration_unlimited_by_oxygen_g_c_per_h,
            self.respiration_unlimited_by_carbon_g_c_per_h,
            self.actual_respiration_g_c_per_h,
            self.symbiotic_respiration_actual_g_c_per_h,
            self.symbiotic_respiration_oxygen_unlimited_g_c_per_h,
            self.ammonium_assimilation_g_n_per_h,
            self.band_ammonium_assimilation_g_n_per_h,
            self.nitrate_assimilation_g_n_per_h,
            self.band_nitrate_assimilation_g_n_per_h,
            self.phosphate_h2_assimilation_g_p_per_h,
            self.phosphate_h_assimilation_g_p_per_h,
            self.band_phosphate_h2_assimilation_g_p_per_h,
            self.band_phosphate_h_assimilation_g_p_per_h,
            self.carbon_dioxide_advection_g_c_per_h,
            self.carbon_dioxide_diffusion_g_c_per_h,
            self.carbon_dioxide_solubilization_g_c_per_h,
            self.aqueous_carbon_dioxide_reaction_g_c_per_h,
            self.soil_to_root_gas_exchange_g_per_h,
            self.aqueous_to_gaseous_root_exchange_g_per_h,
            self.atmosphere_to_root_gas_exchange_g_per_h,
            self.ammonia_nonband_soil_exchange_g_n_per_h,
            self.ammonia_band_soil_exchange_g_n_per_h,
            self.withdrawal_carbon_dioxide_loss_g_c_per_h,
            self.withdrawal_oxygen_loss_g_o_per_h,
            self.withdrawal_methane_loss_g_c_per_h,
            self.withdrawal_nitrous_oxide_loss_g_n_per_h,
            self.withdrawal_ammonia_loss_g_n_per_h,
            self.withdrawal_hydrogen_loss_g_h_per_h,
            self.withdrawal_carbon_dioxide_loss_g_c_per_h_by_root,
            self.withdrawal_oxygen_loss_g_o_per_h_by_root,
            self.withdrawal_methane_loss_g_c_per_h_by_root,
            self.withdrawal_nitrous_oxide_loss_g_n_per_h_by_root,
            self.withdrawal_ammonia_loss_g_n_per_h_by_root,
            self.withdrawal_hydrogen_loss_g_h_per_h_by_root,
            self.combustion_carbon_loss_g_c_per_h,
            self.combustion_nitrogen_loss_g_n_per_h,
            self.combustion_phosphorus_loss_g_p_per_h,
            self.symbiont_combustion_g_c_per_h,
            self.root_combustion_g_c_per_h,
            self.sink_strength_m,
            self.combustion_salt_loss_mol_per_h,
            self.salt_uptake_mol_per_h,
            self.exudate_carbon_exchange_g_c_per_h,
            self.exudate_nitrogen_exchange_g_n_per_h,
            self.exudate_phosphorus_exchange_g_p_per_h,
        }) |values| @memset(values, 0);
    }

    /// Publishes the current UPTAKE nutrient capacities as the sole
    /// preceding-accepted-hour contributor history. The outer-hour owner calls
    /// this only after every conservation gate passes, immediately before its
    /// rollback transaction commits.
    pub fn publishAcceptedNutrientDemandHistory(self: *State) void {
        @memcpy(self.previous_ammonium_demand_nonband_g_n_per_h, self.ammonium_demand_nonband_g_n_per_h);
        @memcpy(self.previous_nitrate_demand_nonband_g_n_per_h, self.nitrate_demand_nonband_g_n_per_h);
        @memcpy(self.previous_phosphate_h2_demand_nonband_g_p_per_h, self.phosphate_h2_demand_nonband_g_p_per_h);
        @memcpy(self.previous_phosphate_h_demand_nonband_g_p_per_h, self.phosphate_h_demand_nonband_g_p_per_h);
        @memcpy(self.previous_ammonium_demand_band_g_n_per_h, self.ammonium_demand_band_g_n_per_h);
        @memcpy(self.previous_nitrate_demand_band_g_n_per_h, self.nitrate_demand_band_g_n_per_h);
        @memcpy(self.previous_phosphate_h2_demand_band_g_p_per_h, self.phosphate_h2_demand_band_g_p_per_h);
        @memcpy(self.previous_phosphate_h_demand_band_g_p_per_h, self.phosphate_h_demand_band_g_p_per_h);
    }

    /// GROSUB lines 371--374. UPTAKE consumes the preceding GROSUB pass's
    /// WSRTL first (`soil.f:175,182`; `uptake.f:1679--1694`), then GROSUB
    /// clears and rebuilds this protein-C subset from structural root N and P
    /// (`grosub.f:6412--6423,7018--7031`). It is not a persistent carbon pool.
    pub fn resetGrosubProteinCarbon(self: *State) void {
        @memset(self.protein_carbon_g, 0);
    }
};

pub const NegativeStructuralCarbonCleanup = struct {
    structural_carbon_g_c: f64,
    mobile_carbon_g_c: f64,
    removed_deficit_g_c: f64,
};

/// GROSUB lines 7301--7307 source-order characterization. The legacy model
/// zeroes a negative structural pool and charges the deficit to shared mobile
/// carbon. Production state validation intentionally rejects such a state
/// before it reaches this repair path.
pub fn sourceOrderNegativeStructuralCarbonCleanup(
    structural_carbon_g_c: f64,
    mobile_carbon_g_c: f64,
) !NegativeStructuralCarbonCleanup {
    if (!std.math.isFinite(structural_carbon_g_c) or
        !std.math.isFinite(mobile_carbon_g_c))
        return error.NonFiniteNegativeStructuralCarbonCleanup;
    if (structural_carbon_g_c >= 0) return .{
        .structural_carbon_g_c = structural_carbon_g_c,
        .mobile_carbon_g_c = mobile_carbon_g_c,
        .removed_deficit_g_c = 0,
    };
    return .{
        .structural_carbon_g_c = 0,
        .mobile_carbon_g_c = mobile_carbon_g_c + structural_carbon_g_c,
        .removed_deficit_g_c = -structural_carbon_g_c,
    };
}

/// GROSUB lines 7428--7429 gate for publishing live root morphology.
pub fn sourceOrderRootMorphologyIsActive(
    total_root_length_m: f64,
    total_root_carbon_g_c: f64,
    plant_population_count: f64,
    presence_threshold: f64,
) !bool {
    inline for (.{
        total_root_length_m,
        total_root_carbon_g_c,
        plant_population_count,
        presence_threshold,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidRootMorphologyGateInput;
    return total_root_length_m > presence_threshold and
        total_root_carbon_g_c > presence_threshold and
        plant_population_count > presence_threshold;
}

/// GROSUB lines 7431--7435 and 7512--7517. Numerically negligible layers
/// publish zero length density instead of dividing by their thickness.
pub fn sourceOrderRootLengthDensity(
    root_length_m_per_plant: f64,
    layer_thickness_m: f64,
    minimum_layer_thickness_m: f64,
) !f64 {
    inline for (.{ root_length_m_per_plant, layer_thickness_m, minimum_layer_thickness_m }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidRootLengthDensityInput;
    return if (layer_thickness_m > minimum_layer_thickness_m)
        root_length_m_per_plant / layer_thickness_m
    else
        0;
}

const FloatFieldExtent = enum(u8) {
    plant,
    domain,
    domain_layer,
    domain_axis,
    domain_layer_axis,
    salt,
    exudate,
    transported_gas,
};

const float_field_count = count: {
    var count: usize = 0;
    for (@typeInfo(State).@"struct".fields) |field| {
        if (field.type == []f64) count += 1;
    }
    break :count count;
};

const FloatFieldPointers = [float_field_count]*[]f64;

const float_field_extent_kinds: [float_field_count]FloatFieldExtent = kinds: {
    @setEvalBranchQuota(20000);
    var result: [float_field_count]FloatFieldExtent = undefined;
    var index: usize = 0;
    for (@typeInfo(State).@"struct".fields) |field| {
        if (field.type == []f64) {
            result[index] = floatFieldExtentKind(field.name);
            index += 1;
        }
    }
    break :kinds result;
};

fn floatFieldExtentKind(comptime name: []const u8) FloatFieldExtent {
    if (std.mem.startsWith(u8, name, "axis_depth_")) return .domain_axis;
    if (std.mem.startsWith(u8, name, "axis_")) return .domain_layer_axis;
    if (std.mem.eql(u8, name, "salt_content_mol") or std.mem.eql(u8, name, "salt_uptake_mol_per_h") or std.mem.eql(u8, name, "combustion_salt_loss_mol_per_h")) return .salt;
    if (std.mem.startsWith(u8, name, "exudate_")) return .exudate;
    if (std.mem.eql(u8, name, "soil_to_root_gas_exchange_g_per_h") or
        std.mem.eql(u8, name, "aqueous_to_gaseous_root_exchange_g_per_h") or
        std.mem.eql(u8, name, "atmosphere_to_root_gas_exchange_g_per_h"))
        return .transported_gas;
    if (std.mem.startsWith(u8, name, "withdrawal_") and
        std.mem.endsWith(u8, name, "_by_root")) return .domain_layer;
    if (std.mem.eql(u8, name, "ammonium_uptake_g_n_per_h") or
        std.mem.eql(u8, name, "nitrate_uptake_g_n_per_h") or
        std.mem.eql(u8, name, "phosphate_uptake_g_p_per_h") or
        std.mem.eql(u8, name, "fixation_uptake_g_n_per_h") or
        std.mem.eql(u8, name, "retained_root_carbon_g_c_per_plant") or
        std.mem.startsWith(u8, name, "withdrawal_") or
        std.mem.startsWith(u8, name, "combustion_") or
        std.mem.startsWith(u8, name, "seed_")) return .plant;
    if (std.mem.eql(u8, name, "current_porosity_fraction_by_domain") or
        std.mem.eql(u8, name, "initial_porosity_fraction_by_domain")) return .domain;
    return .domain_layer;
}

noinline fn floatFieldPointers(state: *State) FloatFieldPointers {
    var result: FloatFieldPointers = undefined;
    comptime var index: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        result[index] = &@field(state, field.name);
        index += 1;
    };
    return result;
}

fn fieldExtent(
    kind: FloatFieldExtent,
    plant_count: usize,
    domain_count: usize,
    domain_layer_count: usize,
    domain_axis_count: usize,
    domain_layer_axis_count: usize,
    salt_count: usize,
    exudate_count: usize,
) usize {
    return switch (kind) {
        .plant => plant_count,
        .domain => domain_count,
        .domain_layer => domain_layer_count,
        .domain_axis => domain_axis_count,
        .domain_layer_axis => domain_layer_axis_count,
        .salt => salt_count,
        .exudate => exudate_count,
        .transported_gas => domain_layer_count * transported_root_gas_count,
    };
}

noinline fn allocateZeroedFloatField(allocator: std.mem.Allocator, count: usize) ![]f64 {
    const values = try allocator.alloc(f64, count);
    @memset(values, 0);
    return values;
}

noinline fn freeFloatFields(allocator: std.mem.Allocator, fields: []const *const []f64) void {
    for (fields) |field| allocator.free(field.*);
}

noinline fn clearPlantFloatFields(fields: []const *const []f64, plant_count: usize, plant: usize) !void {
    for (fields) |field| {
        const values = field.*;
        if (values.len % plant_count != 0) return error.InvalidPlantRootFieldExtent;
        const per_plant = values.len / plant_count;
        @memset(values[plant * per_plant .. (plant + 1) * per_plant], 0);
    }
}

test "plant root state releases every partial allocation prefix" {
    const fixed_field_allocation_count: usize = 6;
    for (0..fixed_field_allocation_count + float_field_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            State.init(failing.allocator(), 2, 3, 4),
        );
    }
}

test "plant reconstruction is equivalent for every floating field and preserves its neighbor" {
    const traits = try @import("../../state/plant_traits.zig").parse(@import("../../core/test_fixtures.zig").plant_traits_source);
    const parameters = compatibilityInitializationParameters();
    const target_plant: usize = 0;
    const neighbor_plant: usize = 1;

    var actual = try State.init(std.testing.allocator, 2, 3, 4);
    defer actual.deinit();
    var expected = try State.init(std.testing.allocator, 2, 3, 4);
    defer expected.deinit();

    var actual_fields = floatFieldPointers(&actual);
    for (&actual_fields, 0..) |field, field_index| {
        for (field.*, 0..) |*value, value_index| {
            value.* = @floatFromInt(field_index + value_index + 1);
        }
    }
    @memset(actual.planting_layer_by_plant, 1);
    @memset(actual.current_deepest_rooted_layer_by_plant, 2);
    @memset(actual.next_deepest_rooted_layer_by_plant, 2);
    @memset(actual.deepest_rooted_layer_by_axis, 2);
    @memset(actual.active_root_axis_count, 3);
    @memset(actual.roots_dead, false);

    try actual.reconstructPlant(target_plant, traits, 2, 0.08, parameters);
    try expected.initializePlant(target_plant, traits, 2, 0.08, parameters);

    var expected_fields = floatFieldPointers(&expected);
    for (&actual_fields, &expected_fields, 0..) |actual_field, expected_field, field_index| {
        const per_plant = actual_field.*.len / actual.plant_count;
        try std.testing.expectEqualSlices(
            f64,
            expected_field.*[target_plant * per_plant .. (target_plant + 1) * per_plant],
            actual_field.*[target_plant * per_plant .. (target_plant + 1) * per_plant],
        );
        for (actual_field.*[neighbor_plant * per_plant .. (neighbor_plant + 1) * per_plant], neighbor_plant * per_plant..) |value, value_index| {
            try std.testing.expectEqual(@as(f64, @floatFromInt(field_index + value_index + 1)), value);
        }
    }
    try std.testing.expectEqual(expected.planting_layer_by_plant[target_plant], actual.planting_layer_by_plant[target_plant]);
    try std.testing.expectEqual(expected.current_deepest_rooted_layer_by_plant[target_plant], actual.current_deepest_rooted_layer_by_plant[target_plant]);
    try std.testing.expectEqual(expected.next_deepest_rooted_layer_by_plant[target_plant], actual.next_deepest_rooted_layer_by_plant[target_plant]);
    try std.testing.expectEqual(expected.active_root_axis_count[target_plant], actual.active_root_axis_count[target_plant]);
    try std.testing.expectEqual(expected.roots_dead[target_plant], actual.roots_dead[target_plant]);
    try std.testing.expectEqualSlices(
        usize,
        expected.deepest_rooted_layer_by_axis[target_plant * actual.root_axis_count .. (target_plant + 1) * actual.root_axis_count],
        actual.deepest_rooted_layer_by_axis[target_plant * actual.root_axis_count .. (target_plant + 1) * actual.root_axis_count],
    );
    try std.testing.expectEqual(@as(usize, 1), actual.planting_layer_by_plant[neighbor_plant]);
    try std.testing.expectEqual(@as(usize, 2), actual.current_deepest_rooted_layer_by_plant[neighbor_plant]);
    try std.testing.expectEqual(@as(usize, 2), actual.next_deepest_rooted_layer_by_plant[neighbor_plant]);
    try std.testing.expectEqual(@as(usize, 3), actual.active_root_axis_count[neighbor_plant]);
    try std.testing.expect(!actual.roots_dead[neighbor_plant]);
}

test {
    _ = @import("plant_root_system_test.zig");
}

const std = @import("std");
const rooted_layer_eligibility = @import("rooted_layer_eligibility.zig");
const root_pool_transaction_replay = @import("pool_transaction_replay.zig");
const PlantRootState = @import("plant_root_system.zig").State;
const NutrientUptakeTraits = @import("../../state/plant_traits.zig").NutrientUptake;
const growth_temperature = @import("../response/growth_temperature.zig");

pub const RuntimeParameters = struct {
    reference_temperature_k: f64,
    aqueous_diffusivity_m2_per_h_at_reference: [3]f64,
    aqueous_diffusivity_temperature_exponent: f64,
    liquid_tortuosity_coefficient: f64,
    nitrogen_inhibition_by_nitrogen_g_n_per_g_c: f64,
    nitrogen_inhibition_by_phosphorus_g_p_per_g_c: f64,
    phosphorus_inhibition_by_phosphorus_g_p_per_g_c: f64,
    phosphorus_inhibition_by_nitrogen_g_n_per_g_c: f64,
    minimum_population_uptake_fraction_multiplier: f64,
    phosphorus_molar_mass_g_per_mol: f64,

    pub fn validate(self: RuntimeParameters) !void {
        if (!std.math.isFinite(self.reference_temperature_k) or self.reference_temperature_k <= 0 or
            !std.math.isFinite(self.aqueous_diffusivity_temperature_exponent) or self.aqueous_diffusivity_temperature_exponent < 0 or
            !std.math.isFinite(self.liquid_tortuosity_coefficient) or self.liquid_tortuosity_coefficient < 0 or
            !std.math.isFinite(self.nitrogen_inhibition_by_nitrogen_g_n_per_g_c) or self.nitrogen_inhibition_by_nitrogen_g_n_per_g_c <= 0 or
            !std.math.isFinite(self.nitrogen_inhibition_by_phosphorus_g_p_per_g_c) or self.nitrogen_inhibition_by_phosphorus_g_p_per_g_c <= 0 or
            !std.math.isFinite(self.phosphorus_inhibition_by_phosphorus_g_p_per_g_c) or self.phosphorus_inhibition_by_phosphorus_g_p_per_g_c <= 0 or
            !std.math.isFinite(self.phosphorus_inhibition_by_nitrogen_g_n_per_g_c) or self.phosphorus_inhibition_by_nitrogen_g_n_per_g_c <= 0) return error.InvalidRootNutrientRuntimeParameters;
        if (!std.math.isFinite(self.minimum_population_uptake_fraction_multiplier) or self.minimum_population_uptake_fraction_multiplier < 0 or self.minimum_population_uptake_fraction_multiplier > 1) return error.InvalidRootNutrientRuntimeParameters;
        if (!std.math.isFinite(self.phosphorus_molar_mass_g_per_mol) or self.phosphorus_molar_mass_g_per_mol <= 0) return error.InvalidRootNutrientRuntimeParameters;
        for (self.aqueous_diffusivity_m2_per_h_at_reference) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootNutrientRuntimeParameters;
    }

    pub fn diffusivityM2PerH(self: RuntimeParameters, nutrient: usize, temperature_k: f64) !f64 {
        try self.validate();
        if (nutrient >= self.aqueous_diffusivity_m2_per_h_at_reference.len) return error.RootNutrientKindOutOfBounds;
        if (!std.math.isFinite(temperature_k) or temperature_k <= 0) return error.InvalidRootNutrientTemperature;
        const value = self.aqueous_diffusivity_m2_per_h_at_reference[nutrient] *
            std.math.pow(f64, temperature_k / self.reference_temperature_k, self.aqueous_diffusivity_temperature_exponent);
        if (!std.math.isFinite(value)) return error.NonFiniteRootNutrientDiffusivity;
        return value;
    }
};

pub fn compatibilityRuntimeParameters() RuntimeParameters {
    return .{
        .reference_temperature_k = 298.15,
        .aqueous_diffusivity_m2_per_h_at_reference = .{ 4.00e-6, 6.00e-6, 3.00e-6 },
        .aqueous_diffusivity_temperature_exponent = 6,
        .liquid_tortuosity_coefficient = 0.7,
        .nitrogen_inhibition_by_nitrogen_g_n_per_g_c = 1,
        .nitrogen_inhibition_by_phosphorus_g_p_per_g_c = 1,
        .phosphorus_inhibition_by_phosphorus_g_p_per_g_c = 0.01,
        .phosphorus_inhibition_by_nitrogen_g_n_per_g_c = 0.01,
        .minimum_population_uptake_fraction_multiplier = 1.0e-4,
        .phosphorus_molar_mass_g_per_mol = 31,
    };
}

pub const ActivityFractions = struct {
    protein: f64,
    carbon: f64,
    nitrogen: f64,
    phosphorus: f64,
};

fn feedbackFraction(numerator: f64, inhibited_pool: f64, inhibition_constant: f64) f64 {
    const denominator = numerator + inhibited_pool / inhibition_constant;
    return if (denominator > 0) numerator / denominator else 1;
}

pub fn activityFractions(
    protein_carbon_g: f64,
    total_carbon_g: f64,
    maximum_protein_carbon_g_per_g_c: f64,
    mobile_carbon_g: f64,
    respiration_unlimited_by_carbon_g_c_per_step: f64,
    mobile_carbon_concentration_g_per_g: f64,
    mobile_nitrogen_concentration_g_per_g: f64,
    mobile_phosphorus_concentration_g_per_g: f64,
    apply_nutrient_feedback: bool,
    parameters: RuntimeParameters,
) !ActivityFractions {
    try parameters.validate();
    inline for (.{ protein_carbon_g, total_carbon_g, maximum_protein_carbon_g_per_g_c, mobile_carbon_g, respiration_unlimited_by_carbon_g_c_per_step, mobile_carbon_concentration_g_per_g, mobile_nitrogen_concentration_g_per_g, mobile_phosphorus_concentration_g_per_g }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootNutrientActivityInput;
    const protein = if (total_carbon_g > 0)
        @min(maximum_protein_carbon_g_per_g_c, protein_carbon_g / total_carbon_g) / 0.05
    else
        1;
    const carbon = if (respiration_unlimited_by_carbon_g_c_per_step > 0)
        std.math.clamp(mobile_carbon_g / respiration_unlimited_by_carbon_g_c_per_step, 0, 1)
    else
        0;
    var nitrogen: f64 = 1;
    var phosphorus: f64 = 1;
    if (apply_nutrient_feedback and mobile_carbon_concentration_g_per_g > 0) {
        nitrogen = @min(
            feedbackFraction(mobile_carbon_concentration_g_per_g, mobile_nitrogen_concentration_g_per_g, parameters.nitrogen_inhibition_by_nitrogen_g_n_per_g_c),
            feedbackFraction(mobile_phosphorus_concentration_g_per_g, mobile_nitrogen_concentration_g_per_g, parameters.nitrogen_inhibition_by_phosphorus_g_p_per_g_c),
        );
        phosphorus = @min(
            feedbackFraction(mobile_carbon_concentration_g_per_g, mobile_phosphorus_concentration_g_per_g, parameters.phosphorus_inhibition_by_phosphorus_g_p_per_g_c),
            feedbackFraction(mobile_nitrogen_concentration_g_per_g, mobile_phosphorus_concentration_g_per_g, parameters.phosphorus_inhibition_by_nitrogen_g_n_per_g_c),
        );
    }
    const result: ActivityFractions = .{ .protein = protein, .carbon = carbon, .nitrogen = nitrogen, .phosphorus = phosphorus };
    inline for (@typeInfo(ActivityFractions).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteRootNutrientActivity;
    return result;
}

pub const NutrientPool = enum(u8) {
    ammonium_nonband,
    ammonium_band,
    nitrate_nonband,
    nitrate_band,
    phosphate_h2_nonband,
    phosphate_h2_band,
    phosphate_h_nonband,
    phosphate_h_band,
};
pub const nutrient_pool_count = @typeInfo(NutrientPool).@"enum".fields.len;

pub const Input = struct {
    soil_concentration_g_element_per_m3: f64,
    soil_pool_g_element: f64,
    total_soil_water_volume_m3: f64,
    soil_zone_fraction: f64,
    water_mass_flow_term: f64,
    diffusive_conductance_m3_per_step: f64,
    minimum_residual_concentration_g_element_per_m3: f64,
    michaelis_half_saturation_g_element_per_m3: f64,
    maximum_uptake_g_element_per_plant_step: f64,
    oxygen_unlimited_maximum_uptake_g_element_per_plant_step: f64,
    plant_population_count: f64,
    population_competition_fraction: f64,
    time_fraction: f64,
    carbon_uptake_limitation_fraction: f64,
};

pub const Result = struct {
    demand_g_element: f64,
    uptake_g_element: f64,
    oxygen_unlimited_uptake_g_element: f64,
    carbon_unlimited_uptake_g_element: f64,
    available_g_element: f64,
};

pub const TransactionMapping = struct {
    uptake_g_element: [nutrient_pool_count]f64,
    respiration_cost: root_pool_transaction_replay.NutrientRespirationCost,
};

pub fn mapTransactionResult(results: []const Result, respiration_g_c_per_g_element: f64) !TransactionMapping {
    if (results.len != nutrient_pool_count or !std.math.isFinite(respiration_g_c_per_g_element) or respiration_g_c_per_g_element < 0)
        return error.InvalidRootNutrientTransactionMapping;
    var mapping: TransactionMapping = .{ .uptake_g_element = undefined, .respiration_cost = .{} };
    for (results, 0..) |result, pool| {
        inline for (.{ result.uptake_g_element, result.oxygen_unlimited_uptake_g_element, result.carbon_unlimited_uptake_g_element }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidRootNutrientTransactionMapping;
        mapping.uptake_g_element[pool] = result.uptake_g_element;
        mapping.respiration_cost.actual_cost_g_c += respiration_g_c_per_g_element * result.uptake_g_element;
        mapping.respiration_cost.oxygen_unlimited_g_c += respiration_g_c_per_g_element * result.oxygen_unlimited_uptake_g_element;
        mapping.respiration_cost.carbon_unlimited_g_c += respiration_g_c_per_g_element * result.carbon_unlimited_uptake_g_element;
    }
    inline for (.{ mapping.respiration_cost.actual_cost_g_c, mapping.respiration_cost.oxygen_unlimited_g_c, mapping.respiration_cost.carbon_unlimited_g_c }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteRootNutrientTransactionMapping;
    return mapping;
}

pub const LayerCompetitor = struct {
    plant: usize,
    domain: usize,
    layer: usize,
    input_by_pool: []const Input,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    competitor_capacity: usize,
    input_by_competitor_pool: []Input,
    staged_results: []Result,
    competitors: []LayerCompetitor,
    admission_index_by_competitor: []usize,

    pub fn init(allocator: std.mem.Allocator, competitor_capacity: usize) !Workspace {
        if (competitor_capacity == 0) return error.ZeroRootNutrientCompetitorCapacity;
        const value_count = try std.math.mul(usize, competitor_capacity, nutrient_pool_count);
        const input_storage = try allocator.alloc(Input, value_count);
        errdefer allocator.free(input_storage);
        const results = try allocator.alloc(Result, value_count);
        errdefer allocator.free(results);
        const competitors = try allocator.alloc(LayerCompetitor, competitor_capacity);
        errdefer allocator.free(competitors);
        const admission_indices = try allocator.alloc(usize, competitor_capacity);
        errdefer allocator.free(admission_indices);
        for (competitors, 0..) |*competitor, index| competitor.* = .{
            .plant = 0,
            .domain = 0,
            .layer = 0,
            .input_by_pool = input_storage[index * nutrient_pool_count ..][0..nutrient_pool_count],
        };
        return .{
            .allocator = allocator,
            .competitor_capacity = competitor_capacity,
            .input_by_competitor_pool = input_storage,
            .staged_results = results,
            .competitors = competitors,
            .admission_index_by_competitor = admission_indices,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.admission_index_by_competitor);
        self.allocator.free(self.competitors);
        self.allocator.free(self.staged_results);
        self.allocator.free(self.input_by_competitor_pool);
        self.* = undefined;
    }

    pub fn inputs(self: *Workspace, competitor: usize) ![]Input {
        if (competitor >= self.competitor_capacity) return error.RootNutrientCompetitorOutOfBounds;
        return self.input_by_competitor_pool[competitor * nutrient_pool_count ..][0..nutrient_pool_count];
    }

    pub fn advance(self: *Workspace, roots: *PlantRootState, soil_pool_g_element: []f64, competitor_count: usize) !void {
        if (competitor_count > self.competitor_capacity) return error.RootNutrientCompetitorOutOfBounds;
        const result_count = try std.math.mul(usize, competitor_count, nutrient_pool_count);
        try advanceCompetingLayer(roots, soil_pool_g_element, self.competitors[0..competitor_count], self.staged_results[0..result_count]);
    }

    /// GROSUB/UPTAKE transaction that also assimilates extracted N and P and
    /// charges CUPRL respiration to the same root-layer mobile pools.
    pub fn advanceAssimilating(self: *Workspace, roots: *PlantRootState, soil_pool_g_element: []f64, competitor_count: usize, respiration_g_c_per_g_element: f64) !void {
        if (competitor_count > self.competitor_capacity) return error.RootNutrientCompetitorOutOfBounds;
        const result_count = try std.math.mul(usize, competitor_count, nutrient_pool_count);
        try advanceCompetingLayerTransaction(roots, soil_pool_g_element, self.competitors[0..competitor_count], self.staged_results[0..result_count], respiration_g_c_per_g_element);
    }

    /// Solve-only production boundary. Results are caller-owned and neither
    /// root nor shared soil state is mutated.
    pub fn stage(self: *Workspace, roots: *const PlantRootState, soil_pool_g_element: []const f64, competitor_count: usize) !void {
        if (competitor_count > self.competitor_capacity) return error.RootNutrientCompetitorOutOfBounds;
        const result_count = try std.math.mul(usize, competitor_count, nutrient_pool_count);
        try stageCompetingLayer(roots, soil_pool_g_element, self.competitors[0..competitor_count], self.staged_results[0..result_count]);
    }

    /// Publishes previously staged nutrient uptake, assimilation, and
    /// respiration without recalculating any result.
    pub fn state_updateStagedAssimilating(self: *Workspace, roots: *PlantRootState, soil_pool_g_element: []f64, competitor_count: usize, respiration_g_c_per_g_element: f64) !void {
        if (competitor_count > self.competitor_capacity) return error.RootNutrientCompetitorOutOfBounds;
        const result_count = try std.math.mul(usize, competitor_count, nutrient_pool_count);
        try state_updateStagedCompetingLayerTransaction(roots, soil_pool_g_element, self.competitors[0..competitor_count], self.staged_results[0..result_count], respiration_g_c_per_g_element);
    }
};

pub const GridWorkspace = struct {
    allocator: std.mem.Allocator,
    per_cell: []Workspace,
    admission_capacity_per_cell: usize,
    admission_storage: []rooted_layer_eligibility.Coordinate,
    transaction_nutrient_storage: []TransactionMapping,
    transaction_nutrient_selected: []bool,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, competitor_capacity_per_cell: usize) !GridWorkspace {
        return initWithAdmissionCapacity(allocator, cell_count, competitor_capacity_per_cell, competitor_capacity_per_cell);
    }

    pub fn initWithAdmissionCapacity(allocator: std.mem.Allocator, cell_count: usize, competitor_capacity_per_cell: usize, admission_capacity_per_cell: usize) !GridWorkspace {
        if (cell_count == 0) return error.ZeroRootNutrientGridCells;
        if (admission_capacity_per_cell == 0) return error.ZeroRootNutrientAdmissionCapacity;
        const workspaces = try allocator.alloc(Workspace, cell_count);
        errdefer allocator.free(workspaces);
        var initialized: usize = 0;
        errdefer for (workspaces[0..initialized]) |*workspace| workspace.deinit();
        for (workspaces) |*workspace| {
            workspace.* = try Workspace.init(allocator, competitor_capacity_per_cell);
            initialized += 1;
        }
        const admission_count = try std.math.mul(usize, cell_count, admission_capacity_per_cell);
        const admission_storage = try allocator.alloc(rooted_layer_eligibility.Coordinate, admission_count);
        errdefer allocator.free(admission_storage);
        const transaction_nutrient_storage = try allocator.alloc(TransactionMapping, admission_count);
        errdefer allocator.free(transaction_nutrient_storage);
        const transaction_nutrient_selected = try allocator.alloc(bool, admission_count);
        errdefer allocator.free(transaction_nutrient_selected);
        @memset(transaction_nutrient_selected, false);
        return .{ .allocator = allocator, .per_cell = workspaces, .admission_capacity_per_cell = admission_capacity_per_cell, .admission_storage = admission_storage, .transaction_nutrient_storage = transaction_nutrient_storage, .transaction_nutrient_selected = transaction_nutrient_selected };
    }

    pub fn admissionBuffer(self: *GridWorkspace, cell: usize) ![]rooted_layer_eligibility.Coordinate {
        if (cell >= self.per_cell.len) return error.RootNutrientGridCellOutOfBounds;
        return self.admission_storage[cell * self.admission_capacity_per_cell ..][0..self.admission_capacity_per_cell];
    }

    pub fn transactionNutrientBuffer(self: *GridWorkspace, cell: usize) ![]TransactionMapping {
        if (cell >= self.per_cell.len) return error.RootNutrientGridCellOutOfBounds;
        return self.transaction_nutrient_storage[cell * self.admission_capacity_per_cell ..][0..self.admission_capacity_per_cell];
    }

    pub fn transactionNutrientSelection(self: *GridWorkspace, cell: usize) ![]bool {
        if (cell >= self.per_cell.len) return error.RootNutrientGridCellOutOfBounds;
        return self.transaction_nutrient_selected[cell * self.admission_capacity_per_cell ..][0..self.admission_capacity_per_cell];
    }

    pub fn deinit(self: *GridWorkspace) void {
        self.allocator.free(self.admission_storage);
        self.allocator.free(self.transaction_nutrient_selected);
        self.allocator.free(self.transaction_nutrient_storage);
        for (self.per_cell) |*workspace| workspace.deinit();
        self.allocator.free(self.per_cell);
        self.* = undefined;
    }
};

pub const TraitInput = struct {
    traits: NutrientUptakeTraits,
    element_molar_mass_g_per_mol: f64,
    root_surface_area_m2_per_plant: f64,
    root_activity_fraction: f64,
    nutrient_zone_access_fraction: f64,
    oxygen_limitation_fraction: f64,
    soil_concentration_g_element_per_m3: f64,
    soil_pool_g_element: f64,
    total_soil_water_volume_m3: f64,
    soil_zone_fraction: f64,
    water_mass_flow_term: f64,
    diffusive_conductance_m3_per_step: f64,
    plant_population_count: f64,
    population_competition_fraction: f64,
    time_fraction: f64,
    carbon_uptake_limitation_fraction: f64,
    /// Legacy HPO4 uses one quarter of the H2PO4 rate and residual
    /// concentration. Other nutrient pools use 1.
    phosphate_charge_multiplier: f64 = 1,
};

pub const LayerInputRequest = struct {
    traits_by_element: [3]NutrientUptakeTraits,
    soil_pool_g_element: []const f64,
    total_soil_water_volume_m3: f64,
    zone_fraction_by_pool: [nutrient_pool_count]f64,
    aqueous_diffusivity_m2_per_h_by_element: [3]f64,
    liquid_tortuosity: f64,
    timestep_h: f64,
    soil_path_length_m: f64,
    root_cylinder_radius_m: f64,
    root_surface_area_per_radius_m: f64,
    root_surface_area_m2_per_plant: f64,
    root_activity_fraction: f64,
    nutrient_activity_fraction_by_element: [3]f64,
    oxygen_limitation_fraction: f64,
    root_water_uptake_m3_per_plant_step: f64,
    plant_population_count: f64,
    population_competition_fraction_by_pool: [nutrient_pool_count]f64,
    carbon_uptake_limitation_fraction: f64,
};

fn elementIndex(pool: NutrientPool) usize {
    return switch (pool) {
        .ammonium_nonband, .ammonium_band => 0,
        .nitrate_nonband, .nitrate_band => 1,
        else => 2,
    };
}

/// Builds all eight UPTAKE operands from one immutable layer snapshot.
/// Convective transport is UPWTRP times the zone fraction (m3 per plant);
/// concentration remains a separate quadratic operand exactly as in UPTAKE.
pub fn buildLayerInputs(request: LayerInputRequest, outputs: []Input) !void {
    if (request.soil_pool_g_element.len != nutrient_pool_count or outputs.len != nutrient_pool_count) return error.RootNutrientPoolCountMismatch;
    inline for (.{ request.total_soil_water_volume_m3, request.liquid_tortuosity, request.timestep_h, request.soil_path_length_m, request.root_cylinder_radius_m, request.root_surface_area_per_radius_m, request.root_surface_area_m2_per_plant, request.root_activity_fraction, request.oxygen_limitation_fraction, request.root_water_uptake_m3_per_plant_step, request.plant_population_count, request.carbon_uptake_limitation_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootNutrientLayerInput;
    if (request.total_soil_water_volume_m3 < 0 or request.liquid_tortuosity < 0 or request.timestep_h <= 0 or request.root_water_uptake_m3_per_plant_step < 0) return error.InvalidRootNutrientLayerInput;
    for (0..nutrient_pool_count) |pool_index| {
        const pool: NutrientPool = @enumFromInt(pool_index);
        const element = elementIndex(pool);
        const zone_fraction = request.zone_fraction_by_pool[pool_index];
        const zone_water_m3 = request.total_soil_water_volume_m3 * zone_fraction;
        const soil_pool = request.soil_pool_g_element[pool_index];
        if (!std.math.isFinite(zone_fraction) or zone_fraction < 0 or zone_fraction > 1 or !std.math.isFinite(soil_pool) or soil_pool < 0) return error.InvalidRootNutrientLayerInput;
        const concentration = if (zone_water_m3 > 0) soil_pool / zone_water_m3 else 0;
        const conductance = if (request.root_surface_area_m2_per_plant > 0 and request.root_surface_area_per_radius_m > 0 and request.root_cylinder_radius_m > 0)
            try radialDiffusiveConductanceM3PerStep(
                request.aqueous_diffusivity_m2_per_h_by_element[element],
                request.liquid_tortuosity,
                request.timestep_h,
                request.soil_path_length_m,
                request.root_cylinder_radius_m,
                request.root_surface_area_per_radius_m,
            )
        else
            0;
        outputs[pool_index] = try inputFromTraits(.{
            .traits = request.traits_by_element[element],
            .element_molar_mass_g_per_mol = if (element < 2) 14 else 31,
            .root_surface_area_m2_per_plant = request.root_surface_area_m2_per_plant,
            .root_activity_fraction = request.root_activity_fraction * request.nutrient_activity_fraction_by_element[element],
            .nutrient_zone_access_fraction = zone_fraction,
            .oxygen_limitation_fraction = request.oxygen_limitation_fraction,
            .soil_concentration_g_element_per_m3 = concentration,
            .soil_pool_g_element = soil_pool,
            .total_soil_water_volume_m3 = request.total_soil_water_volume_m3,
            .soil_zone_fraction = zone_fraction,
            .water_mass_flow_term = request.root_water_uptake_m3_per_plant_step * zone_fraction,
            .diffusive_conductance_m3_per_step = conductance * zone_fraction,
            .plant_population_count = request.plant_population_count,
            .population_competition_fraction = request.population_competition_fraction_by_pool[pool_index],
            .time_fraction = request.timestep_h,
            .carbon_uptake_limitation_fraction = request.carbon_uptake_limitation_fraction,
            .phosphate_charge_multiplier = if (pool == .phosphate_h_nonband or pool == .phosphate_h_band) 0.25 else 1,
        });
    }
}

/// UPTAKE `ZNSGX/PATHL/DIFFL` radial soil-to-root diffusion geometry.
/// The hydraulic workspace supplies the same effective cylinder radius,
/// root-spacing path, and `RTARR` surface-area/radius term used by water
/// uptake, preventing the two kernels from reconstructing different roots.
pub fn radialDiffusiveConductanceM3PerStep(
    aqueous_diffusivity_m2_per_h: f64,
    liquid_tortuosity: f64,
    timestep_h: f64,
    soil_path_length_m: f64,
    root_cylinder_radius_m: f64,
    root_surface_area_per_radius_m: f64,
) !f64 {
    inline for (.{ aqueous_diffusivity_m2_per_h, liquid_tortuosity, timestep_h, soil_path_length_m, root_cylinder_radius_m, root_surface_area_per_radius_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootNutrientDiffusionInput;
    if (aqueous_diffusivity_m2_per_h < 0 or liquid_tortuosity < 0 or timestep_h <= 0 or soil_path_length_m < 0 or root_cylinder_radius_m <= 0 or root_surface_area_per_radius_m <= 0) return error.InvalidRootNutrientDiffusionInput;
    const effective_diffusivity_m2 = aqueous_diffusivity_m2_per_h * liquid_tortuosity * timestep_h;
    if (effective_diffusivity_m2 == 0 or soil_path_length_m == 0) return 0;
    const diffusion_path_m = @min(soil_path_length_m, @sqrt(2 * effective_diffusivity_m2));
    if (diffusion_path_m == 0) return 0;
    const radial_logarithm = @log((diffusion_path_m + root_cylinder_radius_m) / root_cylinder_radius_m);
    if (!std.math.isFinite(radial_logarithm) or radial_logarithm <= 0) return error.InvalidRootNutrientDiffusionGeometry;
    const conductance = effective_diffusivity_m2 * root_surface_area_per_radius_m / radial_logarithm;
    if (!std.math.isFinite(conductance) or conductance < 0) return error.NonFiniteRootNutrientDiffusion;
    return conductance;
}

pub fn rootGrowthTemperatureResponse(soil_temperature_k: f64, thermal_adaptation_offset_k: f64, parameters: growth_temperature.Parameters) !f64 {
    if (!std.math.isFinite(soil_temperature_k) or !std.math.isFinite(thermal_adaptation_offset_k) or soil_temperature_k <= 0 or soil_temperature_k + thermal_adaptation_offset_k <= 0) return error.InvalidRootGrowthTemperature;
    return growth_temperature.response(soil_temperature_k + thermal_adaptation_offset_k, parameters);
}

/// Builds the exact dimensional operands used by the UPTAKE quadratic from a
/// runtime READQ trait record. READQ stores Km and the residual concentration
/// in umol L-1; numerically that is mol m-3, so multiplication by molar mass
/// produces g element m-3 without an additional power-of-ten conversion.
pub fn inputFromTraits(input: TraitInput) !Input {
    inline for (@typeInfo(TraitInput).@"struct".fields) |field| {
        if (field.type == NutrientUptakeTraits) continue;
        if (!std.math.isFinite(@field(input, field.name))) return error.NonFiniteRootNutrientTraitInput;
    }
    inline for (@typeInfo(NutrientUptakeTraits).@"struct".fields) |field| if (!std.math.isFinite(@field(input.traits, field.name))) return error.NonFiniteRootNutrientTraitInput;
    if (input.element_molar_mass_g_per_mol <= 0 or
        input.root_surface_area_m2_per_plant < 0 or
        input.root_activity_fraction < 0 or input.root_activity_fraction > 1 or
        input.nutrient_zone_access_fraction < 0 or input.nutrient_zone_access_fraction > 1 or
        input.oxygen_limitation_fraction < 0 or input.oxygen_limitation_fraction > 1 or
        input.phosphate_charge_multiplier <= 0 or input.phosphate_charge_multiplier > 1 or
        input.traits.maximum_rate_g_per_m2_h < 0 or
        input.traits.half_saturation_umol_per_l < 0 or
        input.traits.minimum_concentration_umol_per_l < 0) return error.InvalidRootNutrientTraitInput;

    const oxygen_unlimited_maximum =
        input.traits.maximum_rate_g_per_m2_h *
        input.phosphate_charge_multiplier *
        input.root_surface_area_m2_per_plant *
        input.root_activity_fraction *
        input.nutrient_zone_access_fraction *
        input.time_fraction;
    return .{
        .soil_concentration_g_element_per_m3 = input.soil_concentration_g_element_per_m3,
        .soil_pool_g_element = input.soil_pool_g_element,
        .total_soil_water_volume_m3 = input.total_soil_water_volume_m3,
        .soil_zone_fraction = input.soil_zone_fraction,
        .water_mass_flow_term = input.water_mass_flow_term,
        .diffusive_conductance_m3_per_step = input.diffusive_conductance_m3_per_step,
        .minimum_residual_concentration_g_element_per_m3 = input.traits.minimum_concentration_umol_per_l * input.element_molar_mass_g_per_mol * input.phosphate_charge_multiplier,
        .michaelis_half_saturation_g_element_per_m3 = input.traits.half_saturation_umol_per_l * input.element_molar_mass_g_per_mol,
        .maximum_uptake_g_element_per_plant_step = oxygen_unlimited_maximum * input.oxygen_limitation_fraction,
        .oxygen_unlimited_maximum_uptake_g_element_per_plant_step = oxygen_unlimited_maximum,
        .plant_population_count = input.plant_population_count,
        .population_competition_fraction = input.population_competition_fraction,
        .time_fraction = input.time_fraction,
        .carbon_uptake_limitation_fraction = input.carbon_uptake_limitation_fraction,
    };
}

fn transportMichaelisRoot(maximum_uptake: f64, diffusion: f64, mass_flow_term: f64, concentration: f64, minimum_concentration: f64, half_saturation: f64) !f64 {
    const x = (diffusion + mass_flow_term) * concentration;
    const y = diffusion * minimum_concentration;
    const available_transport = @max(0.0, x - y);
    if (maximum_uptake == 0 or available_transport == 0) return 0;
    const minus_b = maximum_uptake + diffusion * half_saturation + available_transport;
    const c = available_transport * maximum_uptake;
    const discriminant = @max(0.0, minus_b * minus_b - 4.0 * c);
    const result = 2.0 * c / (minus_b + @sqrt(discriminant));
    if (!std.math.isFinite(result)) return error.NonFiniteRootNutrientQuadratic;
    return @max(0.0, result);
}

/// Shared UPTAKE NH4/NO3/H2PO4/HPO4 band/non-band transport equation.
/// The source's `water_mass_flow_term` is retained algebraically as written,
/// including its placement beside diffusive conductance in X.
pub fn solve(input: Input) !Result {
    inline for (@typeInfo(Input).@"struct".fields) |field| if (!std.math.isFinite(@field(input, field.name))) return error.NonFiniteRootNutrientInput;
    if (input.soil_concentration_g_element_per_m3 < 0 or input.soil_pool_g_element < 0 or input.total_soil_water_volume_m3 < 0 or input.soil_zone_fraction < 0 or input.soil_zone_fraction > 1 or input.water_mass_flow_term < 0 or input.diffusive_conductance_m3_per_step < 0 or input.minimum_residual_concentration_g_element_per_m3 < 0 or input.michaelis_half_saturation_g_element_per_m3 < 0 or input.maximum_uptake_g_element_per_plant_step < 0 or input.oxygen_unlimited_maximum_uptake_g_element_per_plant_step < 0 or input.plant_population_count <= 0 or input.population_competition_fraction < 0 or input.time_fraction < 0 or input.time_fraction > 1 or input.carbon_uptake_limitation_fraction <= 0 or input.carbon_uptake_limitation_fraction > 1) return error.InvalidRootNutrientInput;
    if (input.soil_zone_fraction == 0 or input.soil_concentration_g_element_per_m3 <= input.minimum_residual_concentration_g_element_per_m3) return .{ .demand_g_element = 0, .uptake_g_element = 0, .oxygen_unlimited_uptake_g_element = 0, .carbon_unlimited_uptake_g_element = 0, .available_g_element = 0 };

    const limited_per_plant = try transportMichaelisRoot(input.maximum_uptake_g_element_per_plant_step, input.diffusive_conductance_m3_per_step, input.water_mass_flow_term, input.soil_concentration_g_element_per_m3, input.minimum_residual_concentration_g_element_per_m3, input.michaelis_half_saturation_g_element_per_m3);
    const unlimited_per_plant = try transportMichaelisRoot(input.oxygen_unlimited_maximum_uptake_g_element_per_plant_step, input.diffusive_conductance_m3_per_step, input.water_mass_flow_term, input.soil_concentration_g_element_per_m3, input.minimum_residual_concentration_g_element_per_m3, input.michaelis_half_saturation_g_element_per_m3);
    const minimum_residual_mass = input.minimum_residual_concentration_g_element_per_m3 * input.total_soil_water_volume_m3 * input.soil_zone_fraction;
    const available = @max(0.0, input.population_competition_fraction * (input.soil_pool_g_element - minimum_residual_mass) * input.time_fraction);
    const demand = @max(0.0, limited_per_plant * input.plant_population_count);
    const uptake = @min(available, demand);
    const oxygen_unlimited = @min(available, @max(0.0, unlimited_per_plant * input.plant_population_count));
    const result = Result{ .demand_g_element = demand, .uptake_g_element = uptake, .oxygen_unlimited_uptake_g_element = oxygen_unlimited, .carbon_unlimited_uptake_g_element = uptake / input.carbon_uptake_limitation_fraction, .available_g_element = available };
    inline for (@typeInfo(Result).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteRootNutrientResult;
    return result;
}

pub fn state_updateUptake(soil_pool_g_element: *f64, root_pool_g_element: *f64, accumulated_uptake_g_element: *f64, uptake_g_element: f64) !void {
    inline for (.{ soil_pool_g_element.*, root_pool_g_element.*, accumulated_uptake_g_element.*, uptake_g_element }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootNutrientStateUpdateInput;
    if (soil_pool_g_element.* < 0 or root_pool_g_element.* < 0 or uptake_g_element < 0 or uptake_g_element > soil_pool_g_element.*) return error.InvalidRootNutrientStateUpdate;
    const next_soil = soil_pool_g_element.* - uptake_g_element;
    const next_root = root_pool_g_element.* + uptake_g_element;
    const next_uptake = accumulated_uptake_g_element.* + uptake_g_element;
    if (!std.math.isFinite(next_root) or !std.math.isFinite(next_uptake)) return error.NonFiniteRootNutrientStateUpdate;
    soil_pool_g_element.* = next_soil;
    root_pool_g_element.* = next_root;
    accumulated_uptake_g_element.* = next_uptake;
}

fn layerUptakeField(roots: *PlantRootState, pool: NutrientPool) []f64 {
    return switch (pool) {
        .ammonium_nonband => roots.ammonium_uptake_nonband_g_n_per_h,
        .ammonium_band => roots.ammonium_uptake_band_g_n_per_h,
        .nitrate_nonband => roots.nitrate_uptake_nonband_g_n_per_h,
        .nitrate_band => roots.nitrate_uptake_band_g_n_per_h,
        .phosphate_h2_nonband => roots.phosphate_h2_uptake_nonband_g_p_per_h,
        .phosphate_h2_band => roots.phosphate_h2_uptake_band_g_p_per_h,
        .phosphate_h_nonband => roots.phosphate_h_uptake_nonband_g_p_per_h,
        .phosphate_h_band => roots.phosphate_h_uptake_band_g_p_per_h,
    };
}

fn layerDemandField(roots: *PlantRootState, pool: NutrientPool) []f64 {
    return switch (pool) {
        .ammonium_nonband => roots.ammonium_demand_nonband_g_n_per_h,
        .ammonium_band => roots.ammonium_demand_band_g_n_per_h,
        .nitrate_nonband => roots.nitrate_demand_nonband_g_n_per_h,
        .nitrate_band => roots.nitrate_demand_band_g_n_per_h,
        .phosphate_h2_nonband => roots.phosphate_h2_demand_nonband_g_p_per_h,
        .phosphate_h2_band => roots.phosphate_h2_demand_band_g_p_per_h,
        .phosphate_h_nonband => roots.phosphate_h_demand_nonband_g_p_per_h,
        .phosphate_h_band => roots.phosphate_h_demand_band_g_p_per_h,
    };
}

/// Atomic state_update of all band/non-band NH4, NO3, H2PO4, and HPO4
/// results for one root or mycorrhizal layer, including source PFT totals.
pub fn state_updateLayerUptake(roots: *PlantRootState, plant: usize, domain: usize, layer: usize, soil_pool_g_element: []f64, results: []const Result) !void {
    if (soil_pool_g_element.len != nutrient_pool_count or results.len != nutrient_pool_count) return error.RootNutrientPoolCountMismatch;
    const layer_index = try roots.layerIndex(plant, domain, layer);
    var next_soil: [nutrient_pool_count]f64 = undefined;
    var next_layer: [nutrient_pool_count]f64 = undefined;
    var next_demand: [nutrient_pool_count]f64 = undefined;
    var ammonium_total: f64 = roots.ammonium_uptake_g_n_per_h[plant];
    var nitrate_total: f64 = roots.nitrate_uptake_g_n_per_h[plant];
    var phosphate_total: f64 = roots.phosphate_uptake_g_p_per_h[plant];
    for (0..nutrient_pool_count) |pool_index| {
        const pool: NutrientPool = @enumFromInt(pool_index);
        const uptake = results[pool_index].uptake_g_element;
        if (!std.math.isFinite(soil_pool_g_element[pool_index]) or soil_pool_g_element[pool_index] < 0 or !std.math.isFinite(uptake) or uptake < 0) return error.InvalidRootNutrientStateUpdate;
        next_soil[pool_index] = soil_pool_g_element[pool_index] - uptake;
        next_layer[pool_index] = layerUptakeField(roots, pool)[layer_index] + uptake;
        next_demand[pool_index] = layerDemandField(roots, pool)[layer_index] + results[pool_index].demand_g_element;
        if (next_soil[pool_index] < 0 or !std.math.isFinite(next_layer[pool_index]) or !std.math.isFinite(next_demand[pool_index])) return error.InvalidRootNutrientStateUpdate;
        switch (pool) {
            .ammonium_nonband, .ammonium_band => ammonium_total += uptake,
            .nitrate_nonband, .nitrate_band => nitrate_total += uptake,
            else => phosphate_total += uptake,
        }
    }
    inline for (.{ ammonium_total, nitrate_total, phosphate_total }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootNutrientStateUpdate;
    for (0..nutrient_pool_count) |pool_index| {
        const pool: NutrientPool = @enumFromInt(pool_index);
        soil_pool_g_element[pool_index] = next_soil[pool_index];
        layerUptakeField(roots, pool)[layer_index] = next_layer[pool_index];
        layerDemandField(roots, pool)[layer_index] = next_demand[pool_index];
    }
    roots.ammonium_uptake_g_n_per_h[plant] = ammonium_total;
    roots.nitrate_uptake_g_n_per_h[plant] = nitrate_total;
    roots.phosphate_uptake_g_p_per_h[plant] = phosphate_total;
}

/// Evaluates every runtime plant/root-domain competitor against one immutable
/// soil-layer snapshot, validates the aggregate withdrawal, then publishes a
/// single rollback-safe EXTRACT transaction. `staged_results` is caller-owned
/// runtime workspace so the hourly kernel performs no allocation.
pub fn advanceCompetingLayer(
    roots: *PlantRootState,
    soil_pool_g_element: []f64,
    competitors: []const LayerCompetitor,
    staged_results: []Result,
) !void {
    try advanceCompetingLayerTransaction(roots, soil_pool_g_element, competitors, staged_results, null);
}

fn advanceCompetingLayerTransaction(
    roots: *PlantRootState,
    soil_pool_g_element: []f64,
    competitors: []const LayerCompetitor,
    staged_results: []Result,
    respiration_coefficient: ?f64,
) !void {
    try stageCompetingLayer(roots, soil_pool_g_element, competitors, staged_results);
    try state_updateStagedCompetingLayerTransaction(roots, soil_pool_g_element, competitors, staged_results, respiration_coefficient);
}

/// Solves all competitors against one immutable shared-layer snapshot and
/// validates aggregate availability without mutating root or soil state.
pub fn stageCompetingLayer(
    roots: *const PlantRootState,
    soil_pool_g_element: []const f64,
    competitors: []const LayerCompetitor,
    staged_results: []Result,
) !void {
    if (soil_pool_g_element.len != nutrient_pool_count) return error.RootNutrientPoolCountMismatch;
    const result_count = try std.math.mul(usize, competitors.len, nutrient_pool_count);
    if (staged_results.len != result_count) return error.RootNutrientCompetitionWorkspaceSizeMismatch;

    var total_uptake = [_]f64{0} ** nutrient_pool_count;
    for (competitors, 0..) |competitor, competitor_index| {
        if (competitor.input_by_pool.len != nutrient_pool_count) return error.RootNutrientPoolCountMismatch;
        _ = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
        const result_base = competitor_index * nutrient_pool_count;
        for (0..nutrient_pool_count) |pool_index| {
            const result = try solve(competitor.input_by_pool[pool_index]);
            staged_results[result_base + pool_index] = result;
            total_uptake[pool_index] += result.uptake_g_element;
            if (!std.math.isFinite(total_uptake[pool_index])) return error.NonFiniteRootNutrientCompetition;
        }
    }
    // Each competitor's `solve()` call above independently bounds its own
    // `available` by `population_competition_fraction * soil_pool`, but the
    // per-competitor fractions can legitimately sum above 1.0 across
    // simultaneously active populations/domains sharing a layer (the
    // elementwise `max(floor, demand_share)` in the caller can push the sum
    // over 1.0 even though each individual share is <= 1.0). When that
    // happens, rescale every competitor's uptake down proportionally so the
    // aggregate withdrawal never exceeds the shared soil pool -- mirroring
    // `plant_root_salt_exchange.zig`'s `constrainSpeciesExchange`, rather
    // than aborting the whole simulation over a supply-side allocation
    // conflict that has a well-defined, physically sensible resolution.
    for (0..nutrient_pool_count) |pool_index| {
        const soil = soil_pool_g_element[pool_index];
        if (!std.math.isFinite(soil) or soil < 0) return error.InvalidRootNutrientStateUpdate;
        if (total_uptake[pool_index] > soil + 1.0e-12) {
            const scale = if (total_uptake[pool_index] > 0) soil / total_uptake[pool_index] else 0;
            if (!std.math.isFinite(scale) or scale < 0) return error.RootNutrientCompetitionOverdraw;
            for (0..competitors.len) |competitor_index| {
                const result_base = competitor_index * nutrient_pool_count;
                staged_results[result_base + pool_index].uptake_g_element *= scale;
                staged_results[result_base + pool_index].carbon_unlimited_uptake_g_element *= scale;
            }
        }
    }
}

pub fn state_updateStagedCompetingLayer(
    roots: *PlantRootState,
    soil_pool_g_element: []f64,
    competitors: []const LayerCompetitor,
    staged_results: []const Result,
) !void {
    try state_updateStagedCompetingLayerTransaction(roots, soil_pool_g_element, competitors, staged_results, null);
}

pub fn state_updateStagedAssimilatingLayer(
    roots: *PlantRootState,
    soil_pool_g_element: []f64,
    competitors: []const LayerCompetitor,
    staged_results: []const Result,
    respiration_g_c_per_g_element: f64,
) !void {
    try state_updateStagedCompetingLayerTransaction(roots, soil_pool_g_element, competitors, staged_results, respiration_g_c_per_g_element);
}

fn state_updateStagedCompetingLayerTransaction(
    roots: *PlantRootState,
    soil_pool_g_element: []f64,
    competitors: []const LayerCompetitor,
    staged_results: []const Result,
    respiration_coefficient: ?f64,
) !void {
    if (soil_pool_g_element.len != nutrient_pool_count) return error.RootNutrientPoolCountMismatch;
    if (respiration_coefficient) |coefficient| if (!std.math.isFinite(coefficient) or coefficient < 0) return error.InvalidRootNutrientRespirationCoefficient;
    const result_count = try std.math.mul(usize, competitors.len, nutrient_pool_count);
    if (staged_results.len != result_count) return error.RootNutrientCompetitionWorkspaceSizeMismatch;
    var total_uptake = [_]f64{0} ** nutrient_pool_count;
    for (competitors, 0..) |competitor, competitor_index| {
        _ = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
        const result_base = competitor_index * nutrient_pool_count;
        for (0..nutrient_pool_count) |pool_index| {
            const result = staged_results[result_base + pool_index];
            inline for (.{ result.uptake_g_element, result.demand_g_element, result.oxygen_unlimited_uptake_g_element, result.carbon_unlimited_uptake_g_element }) |value|
                if (!std.math.isFinite(value) or value < 0) return error.InvalidRootNutrientStateUpdate;
            total_uptake[pool_index] += result.uptake_g_element;
            if (!std.math.isFinite(total_uptake[pool_index])) return error.NonFiniteRootNutrientCompetition;
        }
    }
    for (soil_pool_g_element, total_uptake) |soil, uptake| {
        if (!std.math.isFinite(soil) or soil < 0) return error.InvalidRootNutrientStateUpdate;
        if (uptake > soil + 1.0e-12) return error.RootNutrientCompetitionOverdraw;
    }

    // Validate every destination before changing either shared soil or roots.
    for (competitors, 0..) |competitor, competitor_index| {
        const layer_index = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
        const result_base = competitor_index * nutrient_pool_count;
        var ammonium_total = roots.ammonium_uptake_g_n_per_h[competitor.plant];
        var nitrate_total = roots.nitrate_uptake_g_n_per_h[competitor.plant];
        var phosphate_total = roots.phosphate_uptake_g_p_per_h[competitor.plant];
        for (0..nutrient_pool_count) |pool_index| {
            const pool: NutrientPool = @enumFromInt(pool_index);
            const uptake = staged_results[result_base + pool_index].uptake_g_element;
            const next_layer = layerUptakeField(roots, pool)[layer_index] + uptake;
            if (!std.math.isFinite(next_layer)) return error.NonFiniteRootNutrientStateUpdate;
            switch (pool) {
                .ammonium_nonband, .ammonium_band => ammonium_total += uptake,
                .nitrate_nonband, .nitrate_band => nitrate_total += uptake,
                else => phosphate_total += uptake,
            }
        }
        inline for (.{ ammonium_total, nitrate_total, phosphate_total }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootNutrientStateUpdate;
        if (respiration_coefficient) |coefficient| {
            var nitrogen_g_n: f64 = 0;
            var phosphorus_g_p: f64 = 0;
            var respiration_actual_g_c: f64 = 0;
            var respiration_oxygen_unlimited_g_c: f64 = 0;
            var respiration_carbon_unlimited_g_c: f64 = 0;
            for (0..nutrient_pool_count) |pool_index| {
                const result = staged_results[result_base + pool_index];
                if (pool_index < 4) nitrogen_g_n += result.uptake_g_element else phosphorus_g_p += result.uptake_g_element;
                respiration_actual_g_c += coefficient * result.uptake_g_element;
                respiration_oxygen_unlimited_g_c += coefficient * result.oxygen_unlimited_uptake_g_element;
                respiration_carbon_unlimited_g_c += coefficient * result.carbon_unlimited_uptake_g_element;
            }
            const next_mobile_c = roots.mobile_carbon_g[layer_index] - respiration_actual_g_c;
            inline for (.{
                next_mobile_c,
                roots.mobile_nitrogen_g[layer_index] + nitrogen_g_n,
                roots.mobile_phosphorus_g[layer_index] + phosphorus_g_p,
                roots.actual_respiration_g_c_per_h[layer_index] + respiration_actual_g_c,
                roots.respiration_unlimited_by_oxygen_g_c_per_h[layer_index] + respiration_oxygen_unlimited_g_c,
                roots.respiration_unlimited_by_carbon_g_c_per_h[layer_index] + respiration_carbon_unlimited_g_c,
            }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootNutrientAssimilation;
            if (next_mobile_c < 0) return error.InsufficientRootMobileCarbonForNutrientUptake;
        }
    }

    for (0..nutrient_pool_count) |pool_index| soil_pool_g_element[pool_index] -= total_uptake[pool_index];
    for (competitors, 0..) |competitor, competitor_index| {
        const layer_index = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
        const result_base = competitor_index * nutrient_pool_count;
        for (0..nutrient_pool_count) |pool_index| {
            const pool: NutrientPool = @enumFromInt(pool_index);
            const uptake = staged_results[result_base + pool_index].uptake_g_element;
            layerUptakeField(roots, pool)[layer_index] += uptake;
            layerDemandField(roots, pool)[layer_index] += staged_results[result_base + pool_index].demand_g_element;
            switch (pool) {
                .ammonium_nonband, .ammonium_band => roots.ammonium_uptake_g_n_per_h[competitor.plant] += uptake,
                .nitrate_nonband, .nitrate_band => roots.nitrate_uptake_g_n_per_h[competitor.plant] += uptake,
                else => roots.phosphate_uptake_g_p_per_h[competitor.plant] += uptake,
            }
        }
        if (respiration_coefficient) |coefficient| {
            var nitrogen_g_n: f64 = 0;
            var phosphorus_g_p: f64 = 0;
            var respiration_actual_g_c: f64 = 0;
            var respiration_oxygen_unlimited_g_c: f64 = 0;
            var respiration_carbon_unlimited_g_c: f64 = 0;
            for (0..nutrient_pool_count) |pool_index| {
                const result = staged_results[result_base + pool_index];
                if (pool_index < 4) nitrogen_g_n += result.uptake_g_element else phosphorus_g_p += result.uptake_g_element;
                respiration_actual_g_c += coefficient * result.uptake_g_element;
                respiration_oxygen_unlimited_g_c += coefficient * result.oxygen_unlimited_uptake_g_element;
                respiration_carbon_unlimited_g_c += coefficient * result.carbon_unlimited_uptake_g_element;
            }
            roots.mobile_carbon_g[layer_index] -= respiration_actual_g_c;
            roots.mobile_nitrogen_g[layer_index] += nitrogen_g_n;
            roots.mobile_phosphorus_g[layer_index] += phosphorus_g_p;
            roots.actual_respiration_g_c_per_h[layer_index] += respiration_actual_g_c;
            roots.respiration_unlimited_by_oxygen_g_c_per_h[layer_index] += respiration_oxygen_unlimited_g_c;
            roots.respiration_unlimited_by_carbon_g_c_per_h[layer_index] += respiration_carbon_unlimited_g_c;
        }
    }
}

test "eight-pool builder preserves zone mass flow and phosphate charge scaling" {
    const traits = [3]NutrientUptakeTraits{
        .{ .maximum_rate_g_per_m2_h = 0.01, .half_saturation_umol_per_l = 0.2, .minimum_concentration_umol_per_l = 0.01 },
        .{ .maximum_rate_g_per_m2_h = 0.02, .half_saturation_umol_per_l = 0.3, .minimum_concentration_umol_per_l = 0.02 },
        .{ .maximum_rate_g_per_m2_h = 0.04, .half_saturation_umol_per_l = 0.4, .minimum_concentration_umol_per_l = 0.03 },
    };
    var outputs: [nutrient_pool_count]Input = undefined;
    try buildLayerInputs(.{
        .traits_by_element = traits,
        .soil_pool_g_element = &.{ 8, 2, 12, 3, 4, 1, 2, 0.5 },
        .total_soil_water_volume_m3 = 2,
        .zone_fraction_by_pool = .{ 0.8, 0.2, 0.8, 0.2, 0.8, 0.2, 0.8, 0.2 },
        .aqueous_diffusivity_m2_per_h_by_element = .{ 4e-6, 6e-6, 3e-6 },
        .liquid_tortuosity = 0.5,
        .timestep_h = 1,
        .soil_path_length_m = 0.01,
        .root_cylinder_radius_m = 0.0002,
        .root_surface_area_per_radius_m = 2,
        .root_surface_area_m2_per_plant = 1,
        .root_activity_fraction = 0.5,
        .nutrient_activity_fraction_by_element = .{ 1, 1, 1 },
        .oxygen_limitation_fraction = 0.75,
        .root_water_uptake_m3_per_plant_step = 0.1,
        .plant_population_count = 10,
        .population_competition_fraction_by_pool = .{1} ** nutrient_pool_count,
        .carbon_uptake_limitation_fraction = 0.5,
    }, &outputs);
    try std.testing.expectApproxEqAbs(@as(f64, 5), outputs[0].soil_concentration_g_element_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), outputs[0].water_mass_flow_term, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), outputs[1].water_mass_flow_term, 1e-15);
    try std.testing.expectApproxEqAbs(outputs[4].maximum_uptake_g_element_per_plant_step * 0.25, outputs[6].maximum_uptake_g_element_per_plant_step, 1e-15);
    try std.testing.expectApproxEqAbs(outputs[4].minimum_residual_concentration_g_element_per_m3 * 0.25, outputs[6].minimum_residual_concentration_g_element_per_m3, 1e-15);
}

test "UPTAKE eight-pool layer state_update updates runtime root and PFT totals atomically" {
    var roots = try PlantRootState.init(std.testing.allocator, 2, 2, 3);
    defer roots.deinit();
    var soil = [_]f64{2} ** nutrient_pool_count;
    var results = [_]Result{.{ .demand_g_element = 0.2, .uptake_g_element = 0.2, .oxygen_unlimited_uptake_g_element = 0.3, .carbon_unlimited_uptake_g_element = 0.4, .available_g_element = 1 }} ** nutrient_pool_count;
    try state_updateLayerUptake(&roots, 1, 1, 1, &soil, &results);
    const index = try roots.layerIndex(1, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), roots.ammonium_uptake_nonband_g_n_per_h[index], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), roots.ammonium_uptake_g_n_per_h[1], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), roots.nitrate_uptake_g_n_per_h[1], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), roots.phosphate_uptake_g_p_per_h[1], 1.0e-12);
    const soil_before = soil;
    results[7].uptake_g_element = 3;
    try std.testing.expectError(error.InvalidRootNutrientStateUpdate, state_updateLayerUptake(&roots, 1, 1, 1, &soil, &results));
    try std.testing.expectEqualSlices(f64, &soil_before, &soil);
}

test "runtime competitors stage against one layer snapshot and state_update conservatively" {
    var roots = try PlantRootState.init(std.testing.allocator, 3, 1, 1);
    defer roots.deinit();
    var soil = [_]f64{12} ** nutrient_pool_count;
    var inputs: [3][nutrient_pool_count]Input = undefined;
    for (&inputs) |*plant_inputs| {
        for (plant_inputs) |*input| input.* = .{
            .soil_concentration_g_element_per_m3 = 4,
            .soil_pool_g_element = 12,
            .total_soil_water_volume_m3 = 2,
            .soil_zone_fraction = 1,
            .water_mass_flow_term = 0.1,
            .diffusive_conductance_m3_per_step = 0.2,
            .minimum_residual_concentration_g_element_per_m3 = 0,
            .michaelis_half_saturation_g_element_per_m3 = 1,
            .maximum_uptake_g_element_per_plant_step = 0.2,
            .oxygen_unlimited_maximum_uptake_g_element_per_plant_step = 0.3,
            .plant_population_count = 1,
            .population_competition_fraction = 1.0 / 3.0,
            .time_fraction = 1,
            .carbon_uptake_limitation_fraction = 1,
        };
    }
    const competitors = [_]LayerCompetitor{
        .{ .plant = 0, .domain = 0, .layer = 0, .input_by_pool = &inputs[0] },
        .{ .plant = 1, .domain = 0, .layer = 0, .input_by_pool = &inputs[1] },
        .{ .plant = 2, .domain = 0, .layer = 0, .input_by_pool = &inputs[2] },
    };
    var staged: [3 * nutrient_pool_count]Result = undefined;
    const initial = soil;
    try advanceCompetingLayer(&roots, &soil, &competitors, &staged);
    for (0..nutrient_pool_count) |pool_index| {
        var root_total: f64 = 0;
        const pool: NutrientPool = @enumFromInt(pool_index);
        for (0..3) |plant| root_total += layerUptakeField(&roots, pool)[try roots.layerIndex(plant, 0, 0)];
        try std.testing.expectApproxEqAbs(initial[pool_index], soil[pool_index] + root_total, 1.0e-12);
    }
}

test "GROSUB nutrient assimilation atomically couples extraction mobile pools and respiration" {
    var roots = try PlantRootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var soil = [_]f64{10} ** nutrient_pool_count;
    const root = try roots.layerIndex(0, 0, 0);
    roots.mobile_carbon_g[root] = 10;
    const inputs = try workspace.inputs(0);
    for (inputs) |*input| input.* = .{
        .soil_concentration_g_element_per_m3 = 4,
        .soil_pool_g_element = 10,
        .total_soil_water_volume_m3 = 2,
        .soil_zone_fraction = 1,
        .water_mass_flow_term = 0.1,
        .diffusive_conductance_m3_per_step = 0.2,
        .minimum_residual_concentration_g_element_per_m3 = 0,
        .michaelis_half_saturation_g_element_per_m3 = 1,
        .maximum_uptake_g_element_per_plant_step = 0.2,
        .oxygen_unlimited_maximum_uptake_g_element_per_plant_step = 0.3,
        .plant_population_count = 1,
        .population_competition_fraction = 1,
        .time_fraction = 1,
        .carbon_uptake_limitation_fraction = 0.5,
    };
    workspace.competitors[0] = .{ .plant = 0, .domain = 0, .layer = 0, .input_by_pool = inputs };
    try workspace.advanceAssimilating(&roots, &soil, 1, 0.86);
    var actual_total: f64 = 0;
    var oxygen_total: f64 = 0;
    var carbon_total: f64 = 0;
    for (workspace.staged_results[0..nutrient_pool_count]) |result| {
        actual_total += result.uptake_g_element;
        oxygen_total += result.oxygen_unlimited_uptake_g_element;
        carbon_total += result.carbon_unlimited_uptake_g_element;
    }
    try std.testing.expectApproxEqAbs(10 - 0.86 * actual_total, roots.mobile_carbon_g[root], 1.0e-12);
    try std.testing.expectApproxEqAbs(0.86 * actual_total, roots.actual_respiration_g_c_per_h[root], 1.0e-12);
    try std.testing.expectApproxEqAbs(0.86 * oxygen_total, roots.respiration_unlimited_by_oxygen_g_c_per_h[root], 1.0e-12);
    try std.testing.expectApproxEqAbs(0.86 * carbon_total, roots.respiration_unlimited_by_carbon_g_c_per_h[root], 1.0e-12);
    try std.testing.expectApproxEqAbs(
        workspace.staged_results[0].uptake_g_element + workspace.staged_results[1].uptake_g_element +
            workspace.staged_results[2].uptake_g_element + workspace.staged_results[3].uptake_g_element,
        roots.mobile_nitrogen_g[root],
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(actual_total - roots.mobile_nitrogen_g[root], roots.mobile_phosphorus_g[root], 1.0e-12);

    var starved_roots = try PlantRootState.init(std.testing.allocator, 1, 1, 1);
    defer starved_roots.deinit();
    const soil_before = soil;
    try std.testing.expectError(error.InsufficientRootMobileCarbonForNutrientUptake, workspace.advanceAssimilating(&starved_roots, &soil, 1, 0.86));
    try std.testing.expectEqualSlices(f64, &soil_before, &soil);
    try std.testing.expectEqual(@as(f64, 0), starved_roots.mobile_nitrogen_g[0]);
}

test "combined nutrient advance is bit-identical to stage then state_update for single and shared competitors" {
    for (1..3) |competitor_count| {
        var combined_roots = try PlantRootState.init(std.testing.allocator, competitor_count, 1, 1);
        defer combined_roots.deinit();
        var staged_roots = try PlantRootState.init(std.testing.allocator, competitor_count, 1, 1);
        defer staged_roots.deinit();
        var combined_workspace = try Workspace.init(std.testing.allocator, competitor_count);
        defer combined_workspace.deinit();
        var staged_workspace = try Workspace.init(std.testing.allocator, competitor_count);
        defer staged_workspace.deinit();
        for (0..competitor_count) |competitor| {
            const combined_inputs = try combined_workspace.inputs(competitor);
            const staged_inputs = try staged_workspace.inputs(competitor);
            for (combined_inputs, staged_inputs) |*combined_input, *staged_input| {
                combined_input.* = .{ .soil_concentration_g_element_per_m3 = 4, .soil_pool_g_element = 20, .total_soil_water_volume_m3 = 2, .soil_zone_fraction = 1, .water_mass_flow_term = 0.1, .diffusive_conductance_m3_per_step = 0.2, .minimum_residual_concentration_g_element_per_m3 = 0, .michaelis_half_saturation_g_element_per_m3 = 1, .maximum_uptake_g_element_per_plant_step = 0.2, .oxygen_unlimited_maximum_uptake_g_element_per_plant_step = 0.3, .plant_population_count = 1, .population_competition_fraction = 1 / @as(f64, @floatFromInt(competitor_count)), .time_fraction = 1, .carbon_uptake_limitation_fraction = 0.5 };
                staged_input.* = combined_input.*;
            }
            combined_workspace.competitors[competitor] = .{ .plant = competitor, .domain = 0, .layer = 0, .input_by_pool = combined_inputs };
            staged_workspace.competitors[competitor] = .{ .plant = competitor, .domain = 0, .layer = 0, .input_by_pool = staged_inputs };
            combined_roots.mobile_carbon_g[try combined_roots.layerIndex(competitor, 0, 0)] = 10;
            staged_roots.mobile_carbon_g[try staged_roots.layerIndex(competitor, 0, 0)] = 10;
        }
        var combined_soil = [_]f64{20} ** nutrient_pool_count;
        var staged_soil = combined_soil;
        try combined_workspace.advanceAssimilating(&combined_roots, &combined_soil, competitor_count, 0.86);
        try staged_workspace.stage(&staged_roots, &staged_soil, competitor_count);
        try staged_workspace.state_updateStagedAssimilating(&staged_roots, &staged_soil, competitor_count, 0.86);
        try std.testing.expectEqualSlices(f64, &combined_soil, &staged_soil);
        try std.testing.expectEqualSlices(Result, combined_workspace.staged_results[0 .. competitor_count * nutrient_pool_count], staged_workspace.staged_results[0 .. competitor_count * nutrient_pool_count]);
        inline for (.{ "mobile_carbon_g", "mobile_nitrogen_g", "mobile_phosphorus_g", "actual_respiration_g_c_per_h", "respiration_unlimited_by_oxygen_g_c_per_h", "respiration_unlimited_by_carbon_g_c_per_h", "ammonium_uptake_nonband_g_n_per_h", "nitrate_uptake_nonband_g_n_per_h", "phosphate_h2_uptake_nonband_g_p_per_h" }) |field_name|
            try std.testing.expectEqualSlices(f64, @field(combined_roots, field_name), @field(staged_roots, field_name));
    }
}

test "late staged nutrient state_update failure rolls back root and shared soil" {
    var roots = try PlantRootState.init(std.testing.allocator, 2, 1, 1);
    defer roots.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 2);
    defer workspace.deinit();
    for (0..2) |competitor| {
        const inputs = try workspace.inputs(competitor);
        for (inputs) |*input| input.* = .{ .soil_concentration_g_element_per_m3 = 1, .soil_pool_g_element = 2, .total_soil_water_volume_m3 = 1, .soil_zone_fraction = 1, .water_mass_flow_term = 0, .diffusive_conductance_m3_per_step = 0.1, .minimum_residual_concentration_g_element_per_m3 = 0, .michaelis_half_saturation_g_element_per_m3 = 1, .maximum_uptake_g_element_per_plant_step = 0.1, .oxygen_unlimited_maximum_uptake_g_element_per_plant_step = 0.1, .plant_population_count = 1, .population_competition_fraction = 0.5, .time_fraction = 1, .carbon_uptake_limitation_fraction = 1 };
        workspace.competitors[competitor] = .{ .plant = competitor, .domain = 0, .layer = 0, .input_by_pool = inputs };
        roots.mobile_carbon_g[try roots.layerIndex(competitor, 0, 0)] = 10;
    }
    var soil = [_]f64{2} ** nutrient_pool_count;
    try workspace.stage(&roots, &soil, 2);
    workspace.staged_results[nutrient_pool_count].uptake_g_element = 3;
    const soil_before = soil;
    const mobile_before = roots.mobile_carbon_g[0..2].*;
    try std.testing.expectError(error.RootNutrientCompetitionOverdraw, workspace.state_updateStagedAssimilating(&roots, &soil, 2, 0.86));
    try std.testing.expectEqualSlices(f64, &soil_before, &soil);
    try std.testing.expectEqualSlices(f64, &mobile_before, roots.mobile_carbon_g[0..2]);
    try std.testing.expectEqual(@as(f64, 0), roots.mobile_nitrogen_g[0]);
    try std.testing.expectEqual(@as(f64, 0), roots.mobile_nitrogen_g[1]);
}

test "runtime competitor over-1.0 competition fractions are rescaled down, not aborted, and never overdraw the shared pool" {
    // Two symmetric competitors each independently solve to more demand than
    // the shared soil pool can supply (population_competition_fraction=1 for
    // both, i.e. the elementwise max(floor, demand_share) formula in the
    // caller pushed both fractions to 1.0). This is the exact shape of
    // RootNutrientCompetitionOverdraw's fatal path before the fix in
    // stageCompetingLayer that rescales every competitor's uptake down
    // proportionally instead of aborting -- mirroring
    // plant_root_salt_exchange.zig's constrainSpeciesExchange.
    var roots = try PlantRootState.init(std.testing.allocator, 2, 1, 1);
    defer roots.deinit();
    var soil = [_]f64{1} ** nutrient_pool_count;
    var inputs: [2][nutrient_pool_count]Input = undefined;
    for (&inputs) |*plant_inputs| {
        for (plant_inputs) |*input| input.* = .{
            .soil_concentration_g_element_per_m3 = 100,
            .soil_pool_g_element = 1,
            .total_soil_water_volume_m3 = 1,
            .soil_zone_fraction = 1,
            .water_mass_flow_term = 1,
            .diffusive_conductance_m3_per_step = 1,
            .minimum_residual_concentration_g_element_per_m3 = 0,
            .michaelis_half_saturation_g_element_per_m3 = 0,
            .maximum_uptake_g_element_per_plant_step = 100,
            .oxygen_unlimited_maximum_uptake_g_element_per_plant_step = 100,
            .plant_population_count = 1,
            .population_competition_fraction = 1,
            .time_fraction = 1,
            .carbon_uptake_limitation_fraction = 1,
        };
    }
    const competitors = [_]LayerCompetitor{
        .{ .plant = 0, .domain = 0, .layer = 0, .input_by_pool = &inputs[0] },
        .{ .plant = 1, .domain = 0, .layer = 0, .input_by_pool = &inputs[1] },
    };
    var staged: [2 * nutrient_pool_count]Result = undefined;
    const soil_before = soil;
    try advanceCompetingLayer(&roots, &soil, &competitors, &staged);
    // The rescale must never let aggregate withdrawal exceed the pool.
    for (soil) |value| try std.testing.expect(value >= -1.0e-9);
    // Two perfectly symmetric competitors each independently demanded more
    // than the whole pool, so the rescale must land exactly at full
    // depletion, split evenly between them.
    for (soil, soil_before) |after, before| try std.testing.expectApproxEqAbs(@as(f64, 0), after, before * 1.0e-9 + 1.0e-9);
    const layer0 = try roots.layerIndex(0, 0, 0);
    const layer1 = try roots.layerIndex(1, 0, 0);
    try std.testing.expectApproxEqAbs(roots.ammonium_uptake_nonband_g_n_per_h[layer0], roots.ammonium_uptake_nonband_g_n_per_h[layer1], 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), roots.ammonium_uptake_nonband_g_n_per_h[layer0], 1.0e-9);
}

test "runtime single competitor below the pool ceiling is never rescaled" {
    var roots = try PlantRootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    var soil = [_]f64{10} ** nutrient_pool_count;
    var inputs: [nutrient_pool_count]Input = undefined;
    for (&inputs) |*input| input.* = .{
        .soil_concentration_g_element_per_m3 = 4,
        .soil_pool_g_element = 10,
        .total_soil_water_volume_m3 = 2,
        .soil_zone_fraction = 1,
        .water_mass_flow_term = 0.1,
        .diffusive_conductance_m3_per_step = 0.2,
        .minimum_residual_concentration_g_element_per_m3 = 0,
        .michaelis_half_saturation_g_element_per_m3 = 1,
        .maximum_uptake_g_element_per_plant_step = 0.1,
        .oxygen_unlimited_maximum_uptake_g_element_per_plant_step = 0.1,
        .plant_population_count = 1,
        .population_competition_fraction = 1,
        .time_fraction = 1,
        .carbon_uptake_limitation_fraction = 1,
    };
    const competitors = [_]LayerCompetitor{
        .{ .plant = 0, .domain = 0, .layer = 0, .input_by_pool = &inputs },
    };
    var staged_direct: [nutrient_pool_count]Result = undefined;
    for (0..nutrient_pool_count) |pool_index| staged_direct[pool_index] = try solve(inputs[pool_index]);
    var staged_via_stage: [nutrient_pool_count]Result = undefined;
    try stageCompetingLayer(&roots, &soil, &competitors, &staged_via_stage);
    // A single competitor demanding less than the pool must pass through
    // stageCompetingLayer's rescale branch untouched (scale never engages).
    try std.testing.expectEqualSlices(Result, &staged_direct, &staged_via_stage);
}

test {
    _ = @import("plant_root_nutrient_uptake_test.zig");
}

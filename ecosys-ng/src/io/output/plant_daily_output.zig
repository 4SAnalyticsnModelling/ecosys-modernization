const std = @import("std");

pub const Water = struct {
    transpiration_mm: f64,
    cold_or_water_stress_h: f64,
    oxygen_stress_factor: f64,
    plant_water_storage_mm: f64,
};

pub fn water(cumulative_transpiration_source_m3: f64, cold_or_water_stress_h: f64, oxygen_stress_factor: f64, plant_water_storage_m3: f64, cell_area_m2: f64) !Water {
    try validateArea(cell_area_m2);
    inline for (.{ cumulative_transpiration_source_m3, cold_or_water_stress_h, oxygen_stress_factor, plant_water_storage_m3 }) |value| try finite(value);
    return .{
        // CTRAN carries the source uptake sign; OUTPD reports positive loss.
        .transpiration_mm = -cumulative_transpiration_source_m3 * 1000.0 / cell_area_m2,
        .cold_or_water_stress_h = cold_or_water_stress_h,
        .oxygen_stress_factor = oxygen_stress_factor,
        .plant_water_storage_mm = plant_water_storage_m3 * 1000.0 / cell_area_m2,
    };
}

pub const CarbonInputs = struct {
    cell_area_m2: f64,
    shoot_carbon_g: f64,
    leaf_carbon_g: f64,
    sheath_carbon_g: f64,
    stalk_carbon_g: f64,
    reserve_carbon_g: f64,
    husk_carbon_g: f64,
    ear_carbon_g: f64,
    grain_carbon_g: f64,
    root_carbon_g: f64,
    nodule_carbon_g: f64,
    vegetative_residue_carbon_g: f64,
    grain_number: f64,
    projected_leaf_area_m2: f64,
    daily_net_carbon_change_g: f64,
    cumulative_carbon_uptake_g: f64,
    cumulative_carbon_sink_g: f64,
    initial_cumulative_carbon_sink_g: f64,
    signed_total_respiration_carbon_g: f64,
    signed_aboveground_respiration_carbon_g: f64,
    carbon_pollination_factor: f64,
    harvested_carbon_g: f64,
    root_length_density_m_per_m3_by_layer: []const f64,
    plant_population: f64,
    balance_carbon_g: f64,
    storage_carbon_g: f64,
    carbon_oxidation_flux_g: f64,
    net_primary_productivity_g: f64,
    canopy_height_m: f64,
};

pub const CarbonBalanceInputs = struct {
    shoot_carbon_g: f64,
    root_carbon_g: f64,
    nodule_carbon_g: f64,
    storage_carbon_g: f64,
    standing_dead_carbon_g: f64,
    cumulative_carbon_sink_g: f64,
    cumulative_root_soil_carbon_exchange_g: f64,
    cumulative_carbon_balance_g: f64,
    cumulative_harvested_carbon_g: f64,
    harvested_carbon_g: f64,
    carbon_oxidation_g: f64,
    cumulative_net_primary_productivity_g: f64,
};

/// Exact GROSUB BALC accounting identity. Signed exchange, oxidation, and NPP
/// values must be supplied with their source conventions.
pub fn carbonBalance(inputs: CarbonBalanceInputs) !f64 {
    inline for (std.meta.fields(CarbonBalanceInputs)) |field|
        try finite(@field(inputs, field.name));
    const result =
        inputs.shoot_carbon_g +
        inputs.root_carbon_g +
        inputs.nodule_carbon_g +
        inputs.storage_carbon_g +
        inputs.cumulative_carbon_sink_g -
        inputs.cumulative_root_soil_carbon_exchange_g -
        inputs.cumulative_carbon_balance_g +
        inputs.standing_dead_carbon_g +
        inputs.cumulative_harvested_carbon_g +
        inputs.harvested_carbon_g -
        inputs.carbon_oxidation_g -
        inputs.cumulative_net_primary_productivity_g;
    try finite(result);
    return result;
}

pub const Carbon = struct {
    scalar_values: [27]f64,
    root_density_g_m2_by_layer: []f64,

    pub fn deinit(self: *Carbon, allocator: std.mem.Allocator) void {
        allocator.free(self.root_density_g_m2_by_layer);
        self.* = undefined;
    }

    pub fn valueCount(self: Carbon) usize {
        return 27 + self.root_density_g_m2_by_layer.len;
    }

    pub fn writeValues(self: Carbon, destination: []f64) !void {
        if (destination.len != self.valueCount()) return error.PlantDailyOutputDimensionMismatch;
        @memcpy(destination[0..20], self.scalar_values[0..20]);
        @memcpy(destination[20 .. 20 + self.root_density_g_m2_by_layer.len], self.root_density_g_m2_by_layer);
        @memcpy(destination[20 + self.root_density_g_m2_by_layer.len ..], self.scalar_values[20..]);
    }
};

/// OUTPD choices 51..92. Root-density choices 71..85 become a runtime-length
/// profile; the remaining scalar choices retain their original order.
pub fn carbon(allocator: std.mem.Allocator, inputs: CarbonInputs) !Carbon {
    try validateArea(inputs.cell_area_m2);
    const inv_area = 1.0 / inputs.cell_area_m2;
    const scalars = [_]f64{
        inputs.shoot_carbon_g * inv_area,                    inputs.leaf_carbon_g * inv_area,
        inputs.sheath_carbon_g * inv_area,                   inputs.stalk_carbon_g * inv_area,
        inputs.reserve_carbon_g * inv_area,                  (inputs.husk_carbon_g + inputs.ear_carbon_g) * inv_area,
        inputs.grain_carbon_g * inv_area,                    inputs.root_carbon_g * inv_area,
        inputs.nodule_carbon_g * inv_area,                   inputs.vegetative_residue_carbon_g * inv_area,
        inputs.grain_number * inv_area,                      inputs.projected_leaf_area_m2 * inv_area,
        inputs.daily_net_carbon_change_g * inv_area,         inputs.cumulative_carbon_uptake_g * inv_area,
        inputs.cumulative_carbon_sink_g * inv_area,          inputs.initial_cumulative_carbon_sink_g * inv_area,
        inputs.signed_total_respiration_carbon_g * inv_area, inputs.signed_aboveground_respiration_carbon_g * inv_area,
        inputs.carbon_pollination_factor,                    inputs.harvested_carbon_g * inv_area,
        inputs.balance_carbon_g * inv_area,                  inputs.storage_carbon_g * inv_area,
        inputs.carbon_oxidation_flux_g * inv_area,           0.0,
        inputs.net_primary_productivity_g * inv_area,        inputs.canopy_height_m,
        inputs.plant_population * inv_area,
    };
    for (scalars) |value| try finite(value);
    const roots = try allocator.alloc(f64, inputs.root_length_density_m_per_m3_by_layer.len);
    errdefer allocator.free(roots);
    for (inputs.root_length_density_m_per_m3_by_layer, roots) |density, *result| {
        try finite(density);
        result.* = density * inputs.plant_population * inv_area;
        try finite(result.*);
    }
    return .{ .scalar_values = scalars, .root_density_g_m2_by_layer = roots };
}

/// Writes OUTPD choices 51..92 directly into caller-owned storage. This is the
/// simulation hot-path form: it preserves the exact choice order without a
/// per-plant heap allocation.
pub fn calculateCarbonInto(inputs: CarbonInputs, destination: []f64) !void {
    const expected_length = 27 + inputs.root_length_density_m_per_m3_by_layer.len;
    if (destination.len != expected_length) return error.PlantDailyOutputDimensionMismatch;
    try validateArea(inputs.cell_area_m2);
    const inv_area = 1.0 / inputs.cell_area_m2;
    const scalars = [_]f64{
        inputs.shoot_carbon_g * inv_area,                    inputs.leaf_carbon_g * inv_area,
        inputs.sheath_carbon_g * inv_area,                   inputs.stalk_carbon_g * inv_area,
        inputs.reserve_carbon_g * inv_area,                  (inputs.husk_carbon_g + inputs.ear_carbon_g) * inv_area,
        inputs.grain_carbon_g * inv_area,                    inputs.root_carbon_g * inv_area,
        inputs.nodule_carbon_g * inv_area,                   inputs.vegetative_residue_carbon_g * inv_area,
        inputs.grain_number * inv_area,                      inputs.projected_leaf_area_m2 * inv_area,
        inputs.daily_net_carbon_change_g * inv_area,         inputs.cumulative_carbon_uptake_g * inv_area,
        inputs.cumulative_carbon_sink_g * inv_area,          inputs.initial_cumulative_carbon_sink_g * inv_area,
        inputs.signed_total_respiration_carbon_g * inv_area, inputs.signed_aboveground_respiration_carbon_g * inv_area,
        inputs.carbon_pollination_factor,                    inputs.harvested_carbon_g * inv_area,
        inputs.balance_carbon_g * inv_area,                  inputs.storage_carbon_g * inv_area,
        inputs.carbon_oxidation_flux_g * inv_area,           0.0,
        inputs.net_primary_productivity_g * inv_area,        inputs.canopy_height_m,
        inputs.plant_population * inv_area,
    };
    for (scalars) |value| try finite(value);
    @memcpy(destination[0..20], scalars[0..20]);
    for (inputs.root_length_density_m_per_m3_by_layer, destination[20 .. 20 + inputs.root_length_density_m_per_m3_by_layer.len]) |density, *result| {
        try finite(density);
        result.* = density * inputs.plant_population * inv_area;
        try finite(result.*);
    }
    @memcpy(destination[20 + inputs.root_length_density_m_per_m3_by_layer.len ..], scalars[20..]);
}

pub const NutrientInputs = struct {
    cell_area_m2: f64,
    shoot_g: f64,
    leaf_g: f64,
    sheath_g: f64,
    stalk_g: f64,
    reserve_g: f64,
    husk_g: f64,
    ear_g: f64,
    grain_g: f64,
    root_g: f64,
    nodule_g: f64,
    vegetative_residue_g: f64,
    cumulative_uptake_g: f64,
    cumulative_sink_g: f64,
    nitrogen_fixation_g: f64,
    aboveground_litter_sink_g: f64,
    pollination_factor: f64,
    leaf_carbon_g: f64,
    leaf_nitrogen_g: f64,
    leaf_phosphorus_g: f64,
    nonstructural_carbon_g: f64,
    nonstructural_nitrogen_g: f64,
    nonstructural_phosphorus_g: f64,
    minimum_leaf_carbon_g: f64,
    other_pollination_factor: f64,
    gaseous_loss_g: f64,
    harvested_g: f64,
    balance_g: f64,
    storage_g: f64,
    oxidation_flux_g: f64,
};

pub const Nitrogen = struct { values: [23]f64 };
pub const Phosphorus = struct { values: [19]f64 };

pub const NutrientBalanceInputs = struct {
    shoot_g: f64,
    root_g: f64,
    nodule_g: f64,
    storage_g: f64,
    standing_dead_g: f64,
    cumulative_sink_g: f64,
    cumulative_root_soil_exchange_g: f64,
    cumulative_balance_g: f64,
    cumulative_harvested_g: f64,
    harvested_g: f64,
    oxidation_g: f64,
    atmospheric_exchange_g: f64 = 0,
    biological_fixation_g: f64 = 0,
};

fn baseNutrientBalance(inputs: NutrientBalanceInputs) !f64 {
    inline for (std.meta.fields(NutrientBalanceInputs)) |field|
        try finite(@field(inputs, field.name));
    const result =
        inputs.shoot_g +
        inputs.root_g +
        inputs.nodule_g +
        inputs.storage_g +
        inputs.cumulative_sink_g -
        inputs.cumulative_root_soil_exchange_g -
        inputs.cumulative_balance_g +
        inputs.standing_dead_g +
        inputs.cumulative_harvested_g +
        inputs.harvested_g -
        inputs.oxidation_g;
    try finite(result);
    return result;
}

/// Exact GROSUB BALN identity, including signed canopy NH3 exchange and N2
/// fixation terms that do not occur in phosphorus accounting.
pub fn nitrogenBalance(inputs: NutrientBalanceInputs) !f64 {
    const result = try baseNutrientBalance(inputs) -
        inputs.atmospheric_exchange_g -
        inputs.biological_fixation_g;
    try finite(result);
    return result;
}

/// Exact GROSUB BALP identity.
pub fn phosphorusBalance(inputs: NutrientBalanceInputs) !f64 {
    if (inputs.atmospheric_exchange_g != 0 or inputs.biological_fixation_g != 0)
        return error.InvalidPhosphorusBalanceInput;
    return baseNutrientBalance(inputs);
}

fn nutrientRatio(numerator: f64, inputs: NutrientInputs) f64 {
    const denominator = inputs.leaf_carbon_g + inputs.nonstructural_carbon_g;
    return if (inputs.leaf_carbon_g > inputs.minimum_leaf_carbon_g and denominator > 0) numerator / denominator else 0;
}

pub fn nitrogen(inputs: NutrientInputs) !Nitrogen {
    try validateNutrientInputs(inputs);
    const a = 1.0 / inputs.cell_area_m2;
    const values = [_]f64{
        inputs.shoot_g * a,                 inputs.leaf_g * a,                                                                   inputs.sheath_g * a,                  inputs.stalk_g * a,        inputs.reserve_g * a,
        (inputs.husk_g + inputs.ear_g) * a, inputs.grain_g * a,                                                                  inputs.root_g * a,                    inputs.nodule_g * a,       inputs.vegetative_residue_g * a,
        inputs.cumulative_uptake_g * a,     inputs.cumulative_sink_g * a,                                                        inputs.nitrogen_fixation_g * a,       inputs.pollination_factor, nutrientRatio(inputs.leaf_nitrogen_g + inputs.nonstructural_nitrogen_g, inputs),
        inputs.other_pollination_factor,    nutrientRatio(inputs.leaf_phosphorus_g + inputs.nonstructural_phosphorus_g, inputs), inputs.gaseous_loss_g * a,            inputs.harvested_g * a,    inputs.balance_g * a,
        inputs.storage_g * a,               inputs.oxidation_flux_g * a,                                                         inputs.aboveground_litter_sink_g * a,
    };
    for (values) |value| try finite(value);
    return .{ .values = values };
}

pub fn phosphorus(inputs: NutrientInputs) !Phosphorus {
    try validateNutrientInputs(inputs);
    const a = 1.0 / inputs.cell_area_m2;
    const values = [_]f64{
        inputs.shoot_g * a,                 inputs.leaf_g * a,            inputs.sheath_g * a,         inputs.stalk_g * a,                                                                  inputs.reserve_g * a,
        (inputs.husk_g + inputs.ear_g) * a, inputs.grain_g * a,           inputs.root_g * a,           inputs.nodule_g * a,                                                                 inputs.vegetative_residue_g * a,
        inputs.cumulative_uptake_g * a,     inputs.cumulative_sink_g * a, inputs.pollination_factor,   nutrientRatio(inputs.leaf_phosphorus_g + inputs.nonstructural_phosphorus_g, inputs), inputs.harvested_g * a,
        inputs.balance_g * a,               inputs.storage_g * a,         inputs.oxidation_flux_g * a, inputs.aboveground_litter_sink_g * a,
    };
    for (values) |value| try finite(value);
    return .{ .values = values };
}

fn validateNutrientInputs(inputs: NutrientInputs) !void {
    try validateArea(inputs.cell_area_m2);
    if (inputs.minimum_leaf_carbon_g < 0) return error.InvalidPlantDailyNutrientOutput;
    inline for (std.meta.fields(NutrientInputs)) |field| try finite(@field(inputs, field.name));
}

pub const DevelopmentPhase = enum {
    not_alive,
    planting,
    emergence,
    floral_initiation,
    jointing,
    elongation,
    heading,
    anthesis,
    seed_fill,
    seed_number_set,
    seed_mass_set,
    end_seed_fill,
};

pub const Development = struct {
    phase: DevelopmentPhase,
    branch_count: usize,
    main_branch_stage: f64,
    development_feedback: f64,
    leaf_nitrogen_to_carbon_ratio: f64,
    leaf_phosphorus_to_carbon_ratio: f64,
    minimum_daily_canopy_water_potential_megapascal: f64,
    oxygen_stress_factor: f64,
    temperature_function: f64,
};

pub const DevelopmentInputs = struct {
    alive: bool,
    milestone_day_by_stage: []const u32,
    branch_count: usize,
    main_branch_stage: f64,
    development_feedback: f64,
    leaf_structural_carbon_g: f64,
    leaf_structural_nitrogen_g: f64,
    leaf_structural_phosphorus_g: f64,
    plant_nonstructural_carbon_g: f64,
    plant_nonstructural_nitrogen_g: f64,
    plant_nonstructural_phosphorus_g: f64,
    minimum_leaf_carbon_g: f64,
    minimum_daily_canopy_water_potential_megapascal: f64,
    oxygen_stress_factor: f64,
    temperature_function: f64,
};

pub fn development(inputs: DevelopmentInputs) !Development {
    if (inputs.milestone_day_by_stage.len != 10) return error.PlantDevelopmentMilestoneDimensionMismatch;
    inline for (.{ inputs.main_branch_stage, inputs.development_feedback, inputs.leaf_structural_carbon_g, inputs.leaf_structural_nitrogen_g, inputs.leaf_structural_phosphorus_g, inputs.plant_nonstructural_carbon_g, inputs.plant_nonstructural_nitrogen_g, inputs.plant_nonstructural_phosphorus_g, inputs.minimum_leaf_carbon_g, inputs.minimum_daily_canopy_water_potential_megapascal, inputs.oxygen_stress_factor, inputs.temperature_function }) |value| try finite(value);
    if (inputs.minimum_leaf_carbon_g < 0) return error.InvalidPlantDevelopmentOutput;
    if (!inputs.alive) return .{ .phase = .not_alive, .branch_count = 0, .main_branch_stage = 0, .development_feedback = 0, .leaf_nitrogen_to_carbon_ratio = 0, .leaf_phosphorus_to_carbon_ratio = 0, .minimum_daily_canopy_water_potential_megapascal = 0, .oxygen_stress_factor = 0, .temperature_function = 0 };

    var phase: DevelopmentPhase = .planting;
    var reverse_index: usize = inputs.milestone_day_by_stage.len;
    while (reverse_index > 0) {
        reverse_index -= 1;
        if (inputs.milestone_day_by_stage[reverse_index] == 0) continue;
        phase = @enumFromInt(@intFromEnum(DevelopmentPhase.emergence) + reverse_index);
        break;
    }
    const denominator = inputs.leaf_structural_carbon_g + inputs.plant_nonstructural_carbon_g;
    const has_leaf = inputs.leaf_structural_carbon_g > inputs.minimum_leaf_carbon_g;
    return .{
        .phase = phase,
        .branch_count = inputs.branch_count,
        .main_branch_stage = inputs.main_branch_stage,
        .development_feedback = inputs.development_feedback,
        .leaf_nitrogen_to_carbon_ratio = if (has_leaf and denominator > 0) (inputs.leaf_structural_nitrogen_g + inputs.plant_nonstructural_nitrogen_g) / denominator else 0,
        .leaf_phosphorus_to_carbon_ratio = if (has_leaf and denominator > 0) (inputs.leaf_structural_phosphorus_g + inputs.plant_nonstructural_phosphorus_g) / denominator else 0,
        .minimum_daily_canopy_water_potential_megapascal = inputs.minimum_daily_canopy_water_potential_megapascal,
        .oxygen_stress_factor = inputs.oxygen_stress_factor,
        .temperature_function = inputs.temperature_function,
    };
}

pub fn phaseLabel(phase: DevelopmentPhase) []const u8 {
    return switch (phase) {
        .not_alive => "not_alive",
        .planting => "planting",
        .emergence => "emergence",
        .floral_initiation => "floral_initiation",
        .jointing => "jointing",
        .elongation => "elongation",
        .heading => "heading",
        .anthesis => "anthesis",
        .seed_fill => "seed_fill",
        .seed_number_set => "seed_number_set",
        .seed_mass_set => "seed_mass_set",
        .end_seed_fill => "end_seed_fill",
    };
}

fn validateArea(area_m2: f64) !void {
    if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidPlantOutputArea;
}

fn finite(value: f64) !void {
    if (!std.math.isFinite(value)) return error.NonFinitePlantOutput;
}

test "OUTPD daily water retains source sign and area conversions" {
    const output = try water(-0.004, 0.7, 0.8, 0.002, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 2), output.transpiration_mm, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), output.cold_or_water_stress_h, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), output.plant_water_storage_mm, 1e-15);
}

test "OUTPD daily carbon expands root profile in exact choice order" {
    const densities = [_]f64{ 1, 2, 3 };
    var inputs = std.mem.zeroes(CarbonInputs);
    inputs.cell_area_m2 = 2;
    inputs.shoot_carbon_g = 10;
    inputs.harvested_carbon_g = 8;
    inputs.root_length_density_m_per_m3_by_layer = &densities;
    inputs.plant_population = 4;
    var output = try carbon(std.testing.allocator, inputs);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 30), output.valueCount());
    var values: [30]f64 = undefined;
    try output.writeValues(&values);
    try std.testing.expectApproxEqAbs(@as(f64, 5), values[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2), values[20], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 6), values[22], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4), values[19], 1e-15);

    var direct_values: [30]f64 = undefined;
    try calculateCarbonInto(inputs, &direct_values);
    try std.testing.expectEqualSlices(f64, &values, &direct_values);
}

test "GROSUB BALC preserves every signed carbon accounting term" {
    const balance = try carbonBalance(.{
        .shoot_carbon_g = 10,
        .root_carbon_g = 4,
        .nodule_carbon_g = 1,
        .storage_carbon_g = 2,
        .standing_dead_carbon_g = 3,
        .cumulative_carbon_sink_g = 5,
        .cumulative_root_soil_carbon_exchange_g = -2,
        .cumulative_carbon_balance_g = 6,
        .cumulative_harvested_carbon_g = 7,
        .harvested_carbon_g = 0.5,
        .carbon_oxidation_g = -0.25,
        .cumulative_net_primary_productivity_g = 8,
    });
    try std.testing.expectEqual(@as(f64, 20.75), balance);
}

test "OUTPD nutrient ratios retain source leaf-carbon guard" {
    var inputs = std.mem.zeroes(NutrientInputs);
    inputs.cell_area_m2 = 2;
    inputs.leaf_carbon_g = 8;
    inputs.nonstructural_carbon_g = 2;
    inputs.leaf_nitrogen_g = 0.8;
    inputs.nonstructural_nitrogen_g = 0.2;
    inputs.leaf_phosphorus_g = 0.08;
    inputs.nonstructural_phosphorus_g = 0.02;
    const n = try nitrogen(inputs);
    const p = try phosphorus(inputs);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), n.values[14], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), n.values[16], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), p.values[13], 1e-15);
}

test "GROSUB BALN and BALP preserve signed nutrient accounting" {
    const shared: NutrientBalanceInputs = .{
        .shoot_g = 10,
        .root_g = 4,
        .nodule_g = 1,
        .storage_g = 2,
        .standing_dead_g = 3,
        .cumulative_sink_g = 5,
        .cumulative_root_soil_exchange_g = -2,
        .cumulative_balance_g = 6,
        .cumulative_harvested_g = 7,
        .harvested_g = 0.5,
        .oxidation_g = -0.25,
    };
    try std.testing.expectEqual(@as(f64, 28.75), try phosphorusBalance(shared));
    var nitrogen_inputs = shared;
    nitrogen_inputs.atmospheric_exchange_g = -0.5;
    nitrogen_inputs.biological_fixation_g = 1.25;
    try std.testing.expectEqual(@as(f64, 28), try nitrogenBalance(nitrogen_inputs));
}

test "OUTPD development selects latest attained stage and guarded nutrient ratios" {
    const milestones = [_]u32{ 10, 20, 30, 40, 50, 60, 0, 0, 0, 0 };
    const output = try development(.{ .alive = true, .milestone_day_by_stage = &milestones, .branch_count = 4, .main_branch_stage = 2.5, .development_feedback = 0.8, .leaf_structural_carbon_g = 8, .leaf_structural_nitrogen_g = 0.8, .leaf_structural_phosphorus_g = 0.08, .plant_nonstructural_carbon_g = 2, .plant_nonstructural_nitrogen_g = 0.2, .plant_nonstructural_phosphorus_g = 0.02, .minimum_leaf_carbon_g = 1e-9, .minimum_daily_canopy_water_potential_megapascal = -1.2, .oxygen_stress_factor = 0.9, .temperature_function = 0.7 });
    try std.testing.expectEqual(DevelopmentPhase.anthesis, output.phase);
    try std.testing.expectEqualStrings("anthesis", phaseLabel(output.phase));
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), output.leaf_nitrogen_to_carbon_ratio, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), output.leaf_phosphorus_to_carbon_ratio, 1e-15);
    try std.testing.expectEqual(@as(f64, -1.2), output.minimum_daily_canopy_water_potential_megapascal);
}

test "OUTPD dead plant emits explicit not-alive status" {
    const output = try development(.{ .alive = false, .milestone_day_by_stage = &([_]u32{0} ** 10), .branch_count = 99, .main_branch_stage = 1, .development_feedback = 1, .leaf_structural_carbon_g = 1, .leaf_structural_nitrogen_g = 1, .leaf_structural_phosphorus_g = 1, .plant_nonstructural_carbon_g = 1, .plant_nonstructural_nitrogen_g = 1, .plant_nonstructural_phosphorus_g = 1, .minimum_leaf_carbon_g = 0, .minimum_daily_canopy_water_potential_megapascal = -1, .oxygen_stress_factor = 1, .temperature_function = 1 });
    try std.testing.expectEqual(DevelopmentPhase.not_alive, output.phase);
    try std.testing.expectEqual(@as(usize, 0), output.branch_count);
}

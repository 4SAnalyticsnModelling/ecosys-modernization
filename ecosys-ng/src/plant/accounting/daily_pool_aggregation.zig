const std = @import("std");

pub const CarbonInputs = struct {
    branch_leaf_carbon_g: []const f64,
    branch_sheath_carbon_g: []const f64,
    branch_stalk_carbon_g: []const f64,
    branch_reserve_carbon_g: []const f64,
    branch_husk_carbon_g: []const f64,
    branch_ear_carbon_g: []const f64,
    branch_grain_carbon_g: []const f64,
    branch_mobile_carbon_g: []const f64,
    branch_seed_count: []const f64,
    c4_intermediate_carbon_g: f64,
    canopy_symbiont_carbon_g: f64,
    root_carbon_g_by_layer: []const f64,
    primary_root_length_density_m_per_m3_by_layer: []const f64,
    root_symbiont_carbon_g: f64,
    standing_dead_carbon_g: f64,
    seed_storage_carbon_g: f64,
    projected_leaf_area_m2: f64,
    plant_population_count: f64,
};

pub const CarbonPools = struct {
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
    storage_carbon_g: f64,
};

pub const ElementInputs = struct {
    branch_leaf_g: []const f64,
    branch_sheath_g: []const f64,
    branch_stalk_g: []const f64,
    branch_reserve_g: []const f64,
    branch_husk_g: []const f64,
    branch_ear_g: []const f64,
    branch_grain_g: []const f64,
    branch_mobile_g: []const f64,
    root_g_by_layer: []const f64,
    canopy_symbiont_g: f64,
    root_symbiont_g: f64,
    standing_dead_g: f64,
    seed_storage_g: f64,
};

pub const ElementPools = struct {
    shoot_g: f64 = 0,
    leaf_g: f64 = 0,
    sheath_g: f64 = 0,
    stalk_g: f64 = 0,
    reserve_g: f64 = 0,
    husk_g: f64 = 0,
    ear_g: f64 = 0,
    grain_g: f64 = 0,
    root_g: f64 = 0,
    nodule_g: f64 = 0,
    vegetative_residue_g: f64 = 0,
    storage_g: f64 = 0,
};

/// Aggregates the common GROSUB WTSHN/WTSHP state topology for either N or P.
/// Units are selected by the caller and must be consistent across every slice.
pub fn calculateElement(inputs: ElementInputs) !ElementPools {
    const branch_count = inputs.branch_leaf_g.len;
    inline for (.{
        inputs.branch_sheath_g,
        inputs.branch_stalk_g,
        inputs.branch_reserve_g,
        inputs.branch_husk_g,
        inputs.branch_ear_g,
        inputs.branch_grain_g,
        inputs.branch_mobile_g,
    }) |values| if (values.len != branch_count) return error.PlantDailyBranchPoolDimensionMismatch;
    inline for (.{ inputs.canopy_symbiont_g, inputs.root_symbiont_g, inputs.standing_dead_g, inputs.seed_storage_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantDailyPool;
    var result: ElementPools = .{
        .nodule_g = inputs.canopy_symbiont_g + inputs.root_symbiont_g,
        .vegetative_residue_g = inputs.standing_dead_g,
        .storage_g = inputs.seed_storage_g,
    };
    for (0..branch_count) |branch| {
        inline for (.{
            inputs.branch_leaf_g[branch],
            inputs.branch_sheath_g[branch],
            inputs.branch_stalk_g[branch],
            inputs.branch_reserve_g[branch],
            inputs.branch_husk_g[branch],
            inputs.branch_ear_g[branch],
            inputs.branch_grain_g[branch],
            inputs.branch_mobile_g[branch],
        }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantDailyPool;
        result.leaf_g += inputs.branch_leaf_g[branch];
        result.sheath_g += inputs.branch_sheath_g[branch];
        result.stalk_g += inputs.branch_stalk_g[branch];
        result.reserve_g += inputs.branch_reserve_g[branch];
        result.husk_g += inputs.branch_husk_g[branch];
        result.ear_g += inputs.branch_ear_g[branch];
        result.grain_g += inputs.branch_grain_g[branch];
        result.shoot_g +=
            inputs.branch_leaf_g[branch] +
            inputs.branch_sheath_g[branch] +
            inputs.branch_stalk_g[branch] +
            inputs.branch_reserve_g[branch] +
            inputs.branch_husk_g[branch] +
            inputs.branch_ear_g[branch] +
            inputs.branch_grain_g[branch] +
            inputs.branch_mobile_g[branch];
    }
    for (inputs.root_g_by_layer) |value| {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantDailyPool;
        result.root_g += value;
    }
    inline for (std.meta.fields(ElementPools)) |field|
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFinitePlantDailyPool;
    return result;
}

/// Aggregates OUTPD WTSHT..WTSTG from runtime branch and soil-layer extents
/// and copies the primary-root RTDNP profile. RTDNP is root length density per
/// plant (m m-3), not root carbon; OUTPD subsequently multiplies it by PP/AREA.
pub fn calculateCarbonInto(inputs: CarbonInputs, root_length_density_m_per_m3_by_layer: []f64) !CarbonPools {
    const branch_count = inputs.branch_leaf_carbon_g.len;
    inline for (.{
        inputs.branch_sheath_carbon_g,
        inputs.branch_stalk_carbon_g,
        inputs.branch_reserve_carbon_g,
        inputs.branch_husk_carbon_g,
        inputs.branch_ear_carbon_g,
        inputs.branch_grain_carbon_g,
        inputs.branch_mobile_carbon_g,
        inputs.branch_seed_count,
    }) |values| if (values.len != branch_count) return error.PlantDailyBranchPoolDimensionMismatch;
    if (inputs.primary_root_length_density_m_per_m3_by_layer.len != root_length_density_m_per_m3_by_layer.len or
        inputs.root_carbon_g_by_layer.len != root_length_density_m_per_m3_by_layer.len)
        return error.PlantDailyRootPoolDimensionMismatch;
    inline for (.{
        inputs.standing_dead_carbon_g,
        inputs.seed_storage_carbon_g,
        inputs.projected_leaf_area_m2,
        inputs.plant_population_count,
        inputs.c4_intermediate_carbon_g,
        inputs.canopy_symbiont_carbon_g,
        inputs.root_symbiont_carbon_g,
    }) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantDailyPool;
    if (inputs.plant_population_count < 0 or inputs.standing_dead_carbon_g < 0 or inputs.seed_storage_carbon_g < 0 or inputs.projected_leaf_area_m2 < 0 or inputs.c4_intermediate_carbon_g < 0 or inputs.canopy_symbiont_carbon_g < 0 or inputs.root_symbiont_carbon_g < 0)
        return error.InvalidPlantDailyPool;

    var result: CarbonPools = .{
        .shoot_carbon_g = 0,
        .leaf_carbon_g = 0,
        .sheath_carbon_g = 0,
        .stalk_carbon_g = 0,
        .reserve_carbon_g = 0,
        .husk_carbon_g = 0,
        .ear_carbon_g = 0,
        .grain_carbon_g = 0,
        .root_carbon_g = 0,
        .nodule_carbon_g = inputs.canopy_symbiont_carbon_g + inputs.root_symbiont_carbon_g,
        .vegetative_residue_carbon_g = inputs.standing_dead_carbon_g,
        .grain_number = 0,
        .projected_leaf_area_m2 = inputs.projected_leaf_area_m2,
        .storage_carbon_g = inputs.seed_storage_carbon_g,
    };
    for (0..branch_count) |branch| {
        inline for (.{
            inputs.branch_leaf_carbon_g[branch],
            inputs.branch_sheath_carbon_g[branch],
            inputs.branch_stalk_carbon_g[branch],
            inputs.branch_reserve_carbon_g[branch],
            inputs.branch_husk_carbon_g[branch],
            inputs.branch_ear_carbon_g[branch],
            inputs.branch_grain_carbon_g[branch],
            inputs.branch_mobile_carbon_g[branch],
            inputs.branch_seed_count[branch],
        }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantDailyPool;
        result.leaf_carbon_g += inputs.branch_leaf_carbon_g[branch];
        result.sheath_carbon_g += inputs.branch_sheath_carbon_g[branch];
        result.stalk_carbon_g += inputs.branch_stalk_carbon_g[branch];
        result.reserve_carbon_g += inputs.branch_reserve_carbon_g[branch];
        result.husk_carbon_g += inputs.branch_husk_carbon_g[branch];
        result.ear_carbon_g += inputs.branch_ear_carbon_g[branch];
        result.grain_carbon_g += inputs.branch_grain_carbon_g[branch];
        result.grain_number += inputs.branch_seed_count[branch];
        result.shoot_carbon_g +=
            inputs.branch_leaf_carbon_g[branch] +
            inputs.branch_sheath_carbon_g[branch] +
            inputs.branch_stalk_carbon_g[branch] +
            inputs.branch_reserve_carbon_g[branch] +
            inputs.branch_husk_carbon_g[branch] +
            inputs.branch_ear_carbon_g[branch] +
            inputs.branch_grain_carbon_g[branch] +
            inputs.branch_mobile_carbon_g[branch];
    }
    result.shoot_carbon_g += inputs.c4_intermediate_carbon_g;
    for (inputs.root_carbon_g_by_layer, inputs.primary_root_length_density_m_per_m3_by_layer, root_length_density_m_per_m3_by_layer) |root_carbon_g, density, *result_density| {
        if (!std.math.isFinite(root_carbon_g) or root_carbon_g < 0 or !std.math.isFinite(density) or density < 0) return error.InvalidPlantDailyPool;
        result.root_carbon_g += root_carbon_g;
        result_density.* = density;
    }
    inline for (std.meta.fields(CarbonPools)) |field|
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFinitePlantDailyPool;
    return result;
}

test "OUTPD carbon pools use arbitrary branches layers and per-plant RTDNP units" {
    const branches = 7;
    const layers = 19;
    const ones = [_]f64{1} ** branches;
    const twos = [_]f64{2} ** layers;
    var root_profile: [layers]f64 = undefined;
    const pools = try calculateCarbonInto(.{
        .branch_leaf_carbon_g = &ones,
        .branch_sheath_carbon_g = &ones,
        .branch_stalk_carbon_g = &ones,
        .branch_reserve_carbon_g = &ones,
        .branch_husk_carbon_g = &ones,
        .branch_ear_carbon_g = &ones,
        .branch_grain_carbon_g = &ones,
        .branch_mobile_carbon_g = &ones,
        .branch_seed_count = &ones,
        .c4_intermediate_carbon_g = 7,
        .canopy_symbiont_carbon_g = 7,
        .root_carbon_g_by_layer = &twos,
        .primary_root_length_density_m_per_m3_by_layer = &twos,
        .root_symbiont_carbon_g = 9.5,
        .standing_dead_carbon_g = 3,
        .seed_storage_carbon_g = 4,
        .projected_leaf_area_m2 = 5,
        .plant_population_count = 4,
    }, &root_profile);
    try std.testing.expectEqual(@as(f64, 63), pools.shoot_carbon_g);
    try std.testing.expectEqual(@as(f64, 38), pools.root_carbon_g);
    try std.testing.expectEqual(@as(f64, 16.5), pools.nodule_carbon_g);
    try std.testing.expectEqual(@as(f64, 2), root_profile[18]);
}

test "inactive zero-population plant retains finite zero-scaled RTDNP output" {
    var root_profile: [2]f64 = undefined;
    const empty = [_]f64{};
    const zero = [_]f64{ 0, 0 };
    const pools = try calculateCarbonInto(.{
        .branch_leaf_carbon_g = &empty,
        .branch_sheath_carbon_g = &empty,
        .branch_stalk_carbon_g = &empty,
        .branch_reserve_carbon_g = &empty,
        .branch_husk_carbon_g = &empty,
        .branch_ear_carbon_g = &empty,
        .branch_grain_carbon_g = &empty,
        .branch_mobile_carbon_g = &empty,
        .branch_seed_count = &empty,
        .c4_intermediate_carbon_g = 0,
        .canopy_symbiont_carbon_g = 0,
        .root_carbon_g_by_layer = &zero,
        .primary_root_length_density_m_per_m3_by_layer = &zero,
        .root_symbiont_carbon_g = 0,
        .standing_dead_carbon_g = 0,
        .seed_storage_carbon_g = 0,
        .projected_leaf_area_m2 = 0,
        .plant_population_count = 0,
    }, &root_profile);
    try std.testing.expectEqual(@as(f64, 0), pools.shoot_carbon_g);
    try std.testing.expectEqualSlices(f64, &zero, &root_profile);
}

test "GROSUB elemental pools aggregate arbitrary branches and layers" {
    const branches = [_]f64{ 1, 2, 3, 4, 5, 6 };
    const roots = [_]f64{ 0.1, 0.2, 0.3, 0.4 };
    const pools = try calculateElement(.{
        .branch_leaf_g = &branches,
        .branch_sheath_g = &branches,
        .branch_stalk_g = &branches,
        .branch_reserve_g = &branches,
        .branch_husk_g = &branches,
        .branch_ear_g = &branches,
        .branch_grain_g = &branches,
        .branch_mobile_g = &branches,
        .root_g_by_layer = &roots,
        .canopy_symbiont_g = 0.5,
        .root_symbiont_g = 0.75,
        .standing_dead_g = 2,
        .seed_storage_g = 3,
    });
    try std.testing.expectEqual(@as(f64, 168), pools.shoot_g);
    try std.testing.expectEqual(@as(f64, 1), pools.root_g);
    try std.testing.expectEqual(@as(f64, 1.25), pools.nodule_g);
}

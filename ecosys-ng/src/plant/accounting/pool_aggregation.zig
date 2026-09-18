const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const canopy_module = @import("../../canopy/photosynthesis/photosynthesis.zig");
const root_module = @import("../root/plant_root_system.zig");
const stages_module = @import("../lifecycle/growth_stages.zig");
const concentration = @import("../lifecycle/phenology.zig");

pub const RuntimeParameters = struct {
    branch_structural_presence_g_per_plant: f64,
    grain_fill_detection_g_c_per_plant: f64,
    plant_root_structural_presence_g_per_plant: f64,
    feedback_carbon_concentration_minimum_g_per_g: f64,
    nitrogen_inhibition_g_n_per_g_c: f64,
    phosphorus_inhibition_g_p_per_g_c: f64,

    pub fn validate(self: RuntimeParameters) !void {
        inline for (@typeInfo(RuntimeParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name)) or @field(self, field.name) < 0) return error.InvalidPlantPoolAggregationParameter;
        if (self.nitrogen_inhibition_g_n_per_g_c <= 0 or self.phosphorus_inhibition_g_p_per_g_c <= 0) return error.InvalidPlantPoolAggregationParameter;
    }
};

pub fn compatibilityParameters() RuntimeParameters {
    return .{ .branch_structural_presence_g_per_plant = 1.0e-15, .grain_fill_detection_g_c_per_plant = 1.0e-6, .plant_root_structural_presence_g_per_plant = 1.0e-6, .feedback_carbon_concentration_minimum_g_per_g = 1.0e-6, .nitrogen_inhibition_g_n_per_g_c = 1.0e-2, .phosphorus_inhibition_g_p_per_g_c = 1.0e-3 };
}

pub const ElementMass = struct {
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
};

pub const BranchElementPools = struct {
    leaf: ElementMass,
    sheath: ElementMass,
    stalk: ElementMass,
    stalk_reserve: ElementMass,
    husk: ElementMass,
    ear: ElementMass,
    grain: ElementMass,
    mobile: ElementMass,
};

pub const BranchTotals = struct {
    c4_intermediate_carbon_g_c: f64,
    leaf_sheath_carbon_g_c: f64,
    total: ElementMass,
};

pub const PostHarvestPlantTotals = struct {
    leaf_sheath_carbon_g_c: f64,
    stalk_carbon_g_c: f64,
    sapwood_carbon_g_c: f64,
    stalk_surface_area_m2: f64,
};

/// Exact GROSUB 9757-9768 plant reconstruction with runtime branch/layer axes.
pub fn sourceOrderPostHarvestPlantTotals(
    branch_leaf_sheath_carbon_g_c: []const f64,
    branch_stalk_carbon_g_c: []const f64,
    branch_sapwood_carbon_g_c: []const f64,
    branch_stalk_surface_area_m2: []const f64,
    canopy_layer_count: usize,
) !PostHarvestPlantTotals {
    const branch_count = branch_leaf_sheath_carbon_g_c.len;
    if (canopy_layer_count == 0 or branch_stalk_carbon_g_c.len != branch_count or
        branch_sapwood_carbon_g_c.len != branch_count or
        branch_stalk_surface_area_m2.len != try std.math.mul(usize, branch_count, canopy_layer_count))
        return error.PostHarvestPlantTotalDimensionMismatch;
    var result: PostHarvestPlantTotals = .{
        .leaf_sheath_carbon_g_c = 0,
        .stalk_carbon_g_c = 0,
        .sapwood_carbon_g_c = 0,
        .stalk_surface_area_m2 = 0,
    };
    for (0..branch_count) |branch| {
        const leaf_sheath = branch_leaf_sheath_carbon_g_c[branch];
        const stalk = branch_stalk_carbon_g_c[branch];
        const sapwood = branch_sapwood_carbon_g_c[branch];
        inline for (.{ leaf_sheath, stalk, sapwood }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPostHarvestPlantTotalInput;
        result.leaf_sheath_carbon_g_c += leaf_sheath;
        result.stalk_carbon_g_c += stalk;
        result.sapwood_carbon_g_c += sapwood;
        const first = branch * canopy_layer_count;
        for (branch_stalk_surface_area_m2[first..][0..canopy_layer_count]) |area_m2| {
            if (!std.math.isFinite(area_m2) or area_m2 < 0)
                return error.InvalidPostHarvestPlantTotalInput;
            result.stalk_surface_area_m2 += area_m2;
        }
    }
    inline for (@typeInfo(PostHarvestPlantTotals).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFinitePostHarvestPlantTotal;
    return result;
}

/// Exact GROSUB 8466-8501 and 9640-9659 branch C/N/P reconstruction. The four
/// C4 slices replace the source's fixed 25 compartments with a runtime extent.
pub fn sourceOrderBranchTotals(
    pools: BranchElementPools,
    bundle_sheath_nonstructural_carbon_g_c: []const f64,
    mesophyll_nonstructural_carbon_g_c: []const f64,
    bundle_sheath_carbon_dioxide_g_c: []const f64,
    bundle_sheath_bicarbonate_g_c: []const f64,
) !BranchTotals {
    const compartment_count = bundle_sheath_nonstructural_carbon_g_c.len;
    if (mesophyll_nonstructural_carbon_g_c.len != compartment_count or
        bundle_sheath_carbon_dioxide_g_c.len != compartment_count or
        bundle_sheath_bicarbonate_g_c.len != compartment_count)
        return error.BranchTotalDimensionMismatch;
    inline for (@typeInfo(BranchElementPools).@"struct".fields) |field| {
        const pool = @field(pools, field.name);
        inline for (@typeInfo(ElementMass).@"struct".fields) |element| {
            const value = @field(pool, element.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidBranchTotalInput;
        }
    }
    var c4_carbon_g_c: f64 = 0;
    for (
        bundle_sheath_nonstructural_carbon_g_c,
        mesophyll_nonstructural_carbon_g_c,
        bundle_sheath_carbon_dioxide_g_c,
        bundle_sheath_bicarbonate_g_c,
    ) |bundle_sheath, mesophyll, carbon_dioxide, bicarbonate| {
        inline for (.{ bundle_sheath, mesophyll, carbon_dioxide, bicarbonate }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidBranchTotalInput;
        c4_carbon_g_c += bundle_sheath + mesophyll + carbon_dioxide + bicarbonate;
    }
    var total: ElementMass = .{
        .carbon_g_c = c4_carbon_g_c,
        .nitrogen_g_n = 0,
        .phosphorus_g_p = 0,
    };
    inline for (@typeInfo(BranchElementPools).@"struct".fields) |field| {
        const pool = @field(pools, field.name);
        total.carbon_g_c += pool.carbon_g_c;
        total.nitrogen_g_n += pool.nitrogen_g_n;
        total.phosphorus_g_p += pool.phosphorus_g_p;
    }
    inline for (@typeInfo(ElementMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(total, field.name))) return error.NonFiniteBranchTotal;
    return .{
        .c4_intermediate_carbon_g_c = c4_carbon_g_c,
        .leaf_sheath_carbon_g_c = pools.leaf.carbon_g_c + pools.sheath.carbon_g_c,
        .total = total,
    };
}

/// GROSUB 8508-8511 adds mobile carbon after physical-layer structural WTRTD.
pub fn sourceOrderActualRootCarbonWithMobile(
    actual_structural_carbon_g_c: f64,
    mobile_carbon_g_c: f64,
) !f64 {
    inline for (.{ actual_structural_carbon_g_c, mobile_carbon_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidRootTotalInput;
    const total = actual_structural_carbon_g_c + mobile_carbon_g_c;
    if (!std.math.isFinite(total)) return error.NonFiniteRootTotal;
    return total;
}

pub const ApplyContext = struct {
    canopy: *canopy_module.State,
    roots: *root_module.State,
    growth_stages: *const stages_module.State,
    active_by_plant: []const bool,
    biological_domain_count_by_plant: []const u8,
    salinity_enabled_by_cell: []const bool,
    parameters: RuntimeParameters,
};

/// HFUNC CPOOLP/ZPOOLP/PPOOLP, CCPOL*/CZPOL*/CPPOL*, CSALT*, and
/// FDBKP aggregation. Tiles own disjoint plants, branches, and root layers.
pub fn validateApplyContext(context: *const ApplyContext) !void {
    try context.parameters.validate();
    const canopy = context.canopy;
    const plant_count = canopy.plant_branch_offsets.len - 1;
    if (context.roots.plant_count != plant_count or context.growth_stages.plant_count != plant_count or context.active_by_plant.len != plant_count or context.biological_domain_count_by_plant.len != plant_count or context.salinity_enabled_by_cell.len != canopy.cell_count or canopy.species_count == 0) return error.PlantPoolAggregationDimensionMismatch;
    try validateFiniteInputs(context.*);
}

pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    try validateApplyContext(context);
    return applyValidatedTile(context, range);
}

/// Production entry after one stage-wide validation. The grid executor calls
/// a range kernel once per owned cell, so rescanning every plant/root array in
/// this function would turn one hourly aggregation into O(cells * state).
pub fn applyValidatedTile(context: *ApplyContext, range: CellRange) !void {
    const canopy = context.canopy;
    if (range.first > range.end or range.end > canopy.cell_count)
        return error.PlantPoolAggregationDimensionMismatch;
    for (range.first..range.end) |cell| for (0..canopy.species_count) |species| {
        const dynamic_salts = context.salinity_enabled_by_cell[cell];
        const plant = cell * canopy.species_count + species;
        if (!context.active_by_plant[plant]) continue;
        const population = canopy.plant_population_count[plant];
        const branch_threshold = context.parameters.branch_structural_presence_g_per_plant * population;
        const plant_threshold = context.parameters.plant_root_structural_presence_g_per_plant * population;
        const branch_range = try canopy.branchRange(plant);
        var structural_c_g: f64 = 0;
        var mobile_c_g: f64 = 0;
        var mobile_n_g: f64 = 0;
        var mobile_p_g: f64 = 0;
        var symbiont_c_g: f64 = 0;
        var symbiont_n_g: f64 = 0;
        var symbiont_p_g: f64 = 0;
        var salt_mol: f64 = 0;
        var total_shoot_carbon_g: f64 = 0;
        for (branch_range.first..branch_range.end) |branch| {
            if (context.growth_stages.branches[branch].dead) continue;
            const branch_structural = canopy.branch_leaf_carbon_g[branch] + canopy.branch_sheath_carbon_g[branch];
            var c4_intermediate_carbon_g: f64 = 0;
            const nodes = try canopy.nodeRange(branch);
            for (nodes.first..nodes.end) |node| c4_intermediate_carbon_g += canopy.node_c3_nonstructural_carbon_g[node] + canopy.node_c4_mesophyll_nonstructural_carbon_g[node] + canopy.node_bundle_sheath_co2_carbon_g[node] + canopy.node_bundle_sheath_bicarbonate_carbon_g[node];
            total_shoot_carbon_g += branch_structural + canopy.branch_stalk_carbon_g[branch] + canopy.branch_reserve_carbon_g[branch] + canopy.branch_husk_carbon_g[branch] + canopy.branch_ear_carbon_g[branch] + canopy.branch_grain_carbon_g[branch] + canopy.branch_mobile_carbon_g[branch] + c4_intermediate_carbon_g;
            structural_c_g += branch_structural;
            mobile_c_g += canopy.branch_mobile_carbon_g[branch];
            mobile_n_g += canopy.branch_mobile_nitrogen_g[branch];
            mobile_p_g += canopy.branch_mobile_phosphorus_g[branch];
            // HFUNC CPOLNP/ZPOLNP/PPOLNP sum CPOLNB/ZPOLNB/PPOLNB only.
            // Structural symbiont biomass is not part of these mobile pools.
            symbiont_c_g += canopy.branch_symbiont_mobile_carbon_g[branch];
            symbiont_n_g += canopy.branch_symbiont_mobile_nitrogen_g[branch];
            symbiont_p_g += canopy.branch_symbiont_mobile_phosphorus_g[branch];
            var branch_salt: f64 = 0;
            if (dynamic_salts) {
                for (0..root_module.salt_species_count) |salt_species| branch_salt += canopy.branch_salt_content_by_species_mol[branch * root_module.salt_species_count + salt_species];
            }
            salt_mol += branch_salt;
            const values = try concentration.nonstructuralConcentrations(branch_structural, canopy.branch_mobile_carbon_g[branch], canopy.branch_mobile_nitrogen_g[branch], canopy.branch_mobile_phosphorus_g[branch], branch_salt, dynamic_salts, branch_threshold);
            canopy.branch_mobile_carbon_concentration_g_per_g[branch] = values.carbon_g_per_g;
            canopy.branch_mobile_nitrogen_concentration_g_per_g[branch] = values.nitrogen_g_per_g;
            canopy.branch_mobile_phosphorus_concentration_g_per_g[branch] = values.phosphorus_g_per_g;
        }
        canopy.plant_mobile_carbon_g[plant] = mobile_c_g;
        canopy.plant_shoot_growth_g_c_per_step[plant] = total_shoot_carbon_g - canopy.plant_previous_total_shoot_carbon_g[plant];
        canopy.plant_previous_total_shoot_carbon_g[plant] = total_shoot_carbon_g;
        canopy.plant_total_shoot_carbon_g[plant] = total_shoot_carbon_g;
        canopy.plant_mobile_nitrogen_g[plant] = mobile_n_g;
        canopy.plant_mobile_phosphorus_g[plant] = mobile_p_g;
        canopy.plant_symbiont_mobile_carbon_g[plant] = symbiont_c_g;
        canopy.plant_symbiont_mobile_nitrogen_g[plant] = symbiont_n_g;
        canopy.plant_symbiont_mobile_phosphorus_g[plant] = symbiont_p_g;
        canopy.plant_salt_content_mol[plant] = salt_mol;
        const values = try concentration.nonstructuralConcentrations(structural_c_g, mobile_c_g, mobile_n_g, mobile_p_g, salt_mol, dynamic_salts, plant_threshold);
        canopy.plant_mobile_carbon_concentration_g_per_g[plant] = values.carbon_g_per_g;
        canopy.plant_mobile_nitrogen_concentration_g_per_g[plant] = values.nitrogen_g_per_g;
        canopy.plant_mobile_phosphorus_concentration_g_per_g[plant] = values.phosphorus_g_per_g;
        canopy.plant_salt_concentration_mol_per_g_c[plant] = values.salt_mol_per_g_c;
        canopy.plant_symbiont_mobile_carbon_concentration_g_per_g[plant] = if (structural_c_g > plant_threshold) @max(0.0, symbiont_c_g / (structural_c_g + symbiont_c_g)) else 1;
        const carbon_concentration = values.carbon_g_per_g;
        canopy.plant_nitrogen_phosphorus_fixation_constraint_fraction[plant] = if (carbon_concentration > context.parameters.feedback_carbon_concentration_minimum_g_per_g)
            @min(
                values.nitrogen_g_per_g / (values.nitrogen_g_per_g + carbon_concentration * context.parameters.nitrogen_inhibition_g_n_per_g_c),
                values.phosphorus_g_per_g / (values.phosphorus_g_per_g + carbon_concentration * context.parameters.phosphorus_inhibition_g_p_per_g_c),
            )
        else
            1;

        const biological_domain_count = context.biological_domain_count_by_plant[plant];
        if (biological_domain_count < 1 or biological_domain_count > root_module.biological_domain_count)
            return error.PlantPoolAggregationDimensionMismatch;
        for (0..biological_domain_count) |domain| {
            try context.roots.refreshActiveCarbonByLayer(plant, domain);
            for (0..context.roots.soil_layer_count) |layer| {
                const index = try context.roots.layerIndex(plant, domain, layer);
                var root_salt_mol: f64 = 0;
                if (dynamic_salts) {
                    for (0..root_module.salt_species_count) |salt_species| root_salt_mol += context.roots.salt_content_mol[index * root_module.salt_species_count + salt_species];
                }
                const root_values = try concentration.nonstructuralConcentrations(context.roots.total_carbon_g[index], context.roots.mobile_carbon_g[index], context.roots.mobile_nitrogen_g[index], context.roots.mobile_phosphorus_g[index], root_salt_mol, dynamic_salts, plant_threshold);
                context.roots.mobile_carbon_concentration_g_per_g[index] = root_values.carbon_g_per_g;
                context.roots.mobile_nitrogen_concentration_g_per_g[index] = root_values.nitrogen_g_per_g;
                context.roots.mobile_phosphorus_concentration_g_per_g[index] = root_values.phosphorus_g_per_g;
                context.roots.salt_concentration_mol_per_g_c[index] = root_values.salt_mol_per_g_c;
            }
        }
    };
}

fn validateFiniteInputs(context: ApplyContext) !void {
    inline for (.{ context.canopy.branch_mobile_carbon_g, context.canopy.branch_mobile_nitrogen_g, context.canopy.branch_mobile_phosphorus_g, context.canopy.branch_symbiont_mobile_carbon_g, context.canopy.branch_symbiont_mobile_nitrogen_g, context.canopy.branch_symbiont_mobile_phosphorus_g, context.canopy.branch_symbiont_structural_carbon_g, context.canopy.branch_symbiont_structural_nitrogen_g, context.canopy.branch_symbiont_structural_phosphorus_g, context.canopy.branch_leaf_carbon_g, context.canopy.branch_sheath_carbon_g, context.canopy.branch_salt_content_by_species_mol, context.canopy.plant_population_count, context.roots.total_carbon_g, context.roots.mobile_carbon_g, context.roots.mobile_nitrogen_g, context.roots.mobile_phosphorus_g, context.roots.salt_content_mol }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantPoolAggregationState;
}

test "HFUNC pool aggregation retains separate denominators and arbitrary species" {
    const allocator = std.testing.allocator;
    const species_count = 7;
    const counts = try allocator.alloc(usize, species_count);
    defer allocator.free(counts);
    @memset(counts, 1);
    var canopy = try canopy_module.State.init(allocator, 1, species_count, counts, counts, counts);
    defer canopy.deinit();
    var roots = try root_module.State.init(allocator, species_count, 2, 1);
    defer roots.deinit();
    var growth = try stages_module.State.init(allocator, counts);
    defer growth.deinit();
    for (0..species_count) |plant| {
        canopy.plant_population_count[plant] = 1;
        canopy.branch_leaf_carbon_g[plant] = 8;
        canopy.branch_sheath_carbon_g[plant] = 2;
        canopy.branch_mobile_carbon_g[plant] = 2;
        canopy.branch_mobile_nitrogen_g[plant] = 1;
        canopy.branch_mobile_phosphorus_g[plant] = 0.5;
        canopy.branch_symbiont_mobile_carbon_g[plant] = 1;
        canopy.branch_symbiont_mobile_nitrogen_g[plant] = 0.1;
        canopy.branch_symbiont_mobile_phosphorus_g[plant] = 0.01;
        canopy.branch_symbiont_structural_carbon_g[plant] = 100;
        canopy.branch_symbiont_structural_nitrogen_g[plant] = 10;
        canopy.branch_symbiont_structural_phosphorus_g[plant] = 1;
    }
    const active = try allocator.alloc(bool, species_count);
    defer allocator.free(active);
    @memset(active, true);
    const first_mycorrhizal_layer = try roots.layerIndex(0, 1, 0);
    const second_mycorrhizal_layer = try roots.layerIndex(1, 1, 0);
    roots.mobile_carbon_g[first_mycorrhizal_layer] = 1;
    roots.mobile_carbon_g[second_mycorrhizal_layer] = 1;
    var biological_domain_counts = [_]u8{2} ** species_count;
    biological_domain_counts[0] = 1;
    var context: ApplyContext = .{ .canopy = &canopy, .roots = &roots, .growth_stages = &growth, .active_by_plant = active, .biological_domain_count_by_plant = &biological_domain_counts, .salinity_enabled_by_cell = &.{true}, .parameters = compatibilityParameters() };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    for (0..species_count) |plant| {
        try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 12.0), canopy.plant_mobile_carbon_concentration_g_per_g[plant], 1.0e-15);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 11.0), canopy.plant_mobile_nitrogen_concentration_g_per_g[plant], 1.0e-15);
        try std.testing.expectApproxEqAbs(@as(f64, 0.5 / 10.5), canopy.plant_mobile_phosphorus_concentration_g_per_g[plant], 1.0e-15);
        try std.testing.expectEqual(@as(f64, 1), canopy.plant_symbiont_mobile_carbon_g[plant]);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 11.0), canopy.plant_symbiont_mobile_carbon_concentration_g_per_g[plant], 1.0e-15);
    }
    try std.testing.expectEqual(@as(f64, 0), roots.mobile_carbon_concentration_g_per_g[first_mycorrhizal_layer]);
    try std.testing.expectEqual(@as(f64, 1), roots.mobile_carbon_concentration_g_per_g[second_mycorrhizal_layer]);
}

test "GROSUB branch totals preserve every source pool and runtime C4 extent" {
    var bundle_sheath: [31]f64 = @splat(0.1);
    var mesophyll: [31]f64 = @splat(0.2);
    var carbon_dioxide: [31]f64 = @splat(0.3);
    var bicarbonate: [31]f64 = @splat(0.4);
    bundle_sheath[30] = 1.1;
    const pools: BranchElementPools = .{
        .leaf = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .sheath = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 },
        .stalk = .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.03 },
        .stalk_reserve = .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.04 },
        .husk = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.05 },
        .ear = .{ .carbon_g_c = 6, .nitrogen_g_n = 0.6, .phosphorus_g_p = 0.06 },
        .grain = .{ .carbon_g_c = 7, .nitrogen_g_n = 0.7, .phosphorus_g_p = 0.07 },
        .mobile = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 },
    };
    const totals = try sourceOrderBranchTotals(pools, &bundle_sheath, &mesophyll, &carbon_dioxide, &bicarbonate);
    try std.testing.expectApproxEqAbs(@as(f64, 32), totals.c4_intermediate_carbon_g_c, 1.0e-14);
    try std.testing.expectEqual(@as(f64, 3), totals.leaf_sheath_carbon_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 68), totals.total.carbon_g_c, 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 3.6), totals.total.nitrogen_g_n, 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.36), totals.total.phosphorus_g_p, 1.0e-14);
}

test "GROSUB post-harvest branch rebuild uses remaining pools only" {
    const empty_c4 = [_]f64{};
    const pools: BranchElementPools = .{
        .leaf = .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.04 },
        .sheath = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .stalk = .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.03 },
        .stalk_reserve = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 },
        .husk = .{ .carbon_g_c = 0.5, .nitrogen_g_n = 0.05, .phosphorus_g_p = 0.005 },
        .ear = .{ .carbon_g_c = 0.25, .nitrogen_g_n = 0.025, .phosphorus_g_p = 0.0025 },
        .grain = .{ .carbon_g_c = 0.75, .nitrogen_g_n = 0.075, .phosphorus_g_p = 0.0075 },
        .mobile = .{ .carbon_g_c = 1.5, .nitrogen_g_n = 0.15, .phosphorus_g_p = 0.015 },
    };
    const totals = try sourceOrderBranchTotals(pools, &empty_c4, &empty_c4, &empty_c4, &empty_c4);
    try std.testing.expectEqual(@as(f64, 5), totals.leaf_sheath_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 13), totals.total.carbon_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 1.3), totals.total.nitrogen_g_n, 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.13), totals.total.phosphorus_g_p, 1.0e-14);
}

test "GROSUB post-harvest plant totals preserve branch then layer order" {
    const totals = try sourceOrderPostHarvestPlantTotals(
        &.{ 3, 7, 11 },
        &.{ 2, 5, 13 },
        &.{ 1, 4, 8 },
        &.{
            0.1, 0.2, 0.3, 0.4,
            0.5, 0.6, 0.7, 0.8,
            0.9, 1.0, 1.1, 1.2,
        },
        4,
    );
    try std.testing.expectEqual(@as(f64, 21), totals.leaf_sheath_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 20), totals.stalk_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 13), totals.sapwood_carbon_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 7.8), totals.stalk_surface_area_m2, 1.0e-14);
}

test "GROSUB post-harvest plant totals reject malformed and invalid state" {
    try std.testing.expectError(
        error.PostHarvestPlantTotalDimensionMismatch,
        sourceOrderPostHarvestPlantTotals(&.{1}, &.{1}, &.{1}, &.{ 1, 2 }, 3),
    );
    try std.testing.expectError(
        error.InvalidPostHarvestPlantTotalInput,
        sourceOrderPostHarvestPlantTotals(&.{1}, &.{1}, &.{1}, &.{-1}, 1),
    );
}

test "GROSUB actual root total adds mobile carbon after structural reconstruction" {
    try std.testing.expectEqual(@as(f64, 7.5), try sourceOrderActualRootCarbonWithMobile(6, 1.5));
    try std.testing.expectError(error.InvalidRootTotalInput, sourceOrderActualRootCarbonWithMobile(-1, 2));
}

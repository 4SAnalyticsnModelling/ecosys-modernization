const std = @import("std");

pub const ElementGrowth = struct {
    leaf: f64,
    sheath: f64,
    stalk: f64,
    reserve: f64,
    husk: f64,
    ear: f64,
};

pub const Growth = struct {
    carbon_g_c_per_timestep: ElementGrowth,
    nitrogen_g_n_per_timestep: ElementGrowth,
    phosphorus_g_p_per_timestep: ElementGrowth,
};

pub const Pools = struct {
    leaf_carbon_g_c: []f64,
    sheath_carbon_g_c: []f64,
    stalk_carbon_g_c: []f64,
    reserve_carbon_g_c: []f64,
    husk_carbon_g_c: []f64,
    ear_carbon_g_c: []f64,
    leaf_nitrogen_g_n: []f64,
    sheath_nitrogen_g_n: []f64,
    stalk_nitrogen_g_n: []f64,
    reserve_nitrogen_g_n: []f64,
    husk_nitrogen_g_n: []f64,
    ear_nitrogen_g_n: []f64,
    leaf_phosphorus_g_p: []f64,
    sheath_phosphorus_g_p: []f64,
    stalk_phosphorus_g_p: []f64,
    reserve_phosphorus_g_p: []f64,
    husk_phosphorus_g_p: []f64,
    ear_phosphorus_g_p: []f64,
};

/// grosub.f lines 2227--2244: publish one branch's organ growth in exact source
/// assignment order. Grain growth is deliberately absent: GROGR/GROGRN/GROGRP
/// are calculated at lines 2211/2219/2226 but are not state_updateted in this block.
pub fn publish(pools: Pools, branch: usize, growth: Growth) !void {
    const branch_count = pools.leaf_carbon_g_c.len;
    inline for (@typeInfo(Pools).@"struct".fields) |field| {
        if (@field(pools, field.name).len != branch_count)
            return error.BranchOrganGrowthDimensionMismatch;
    }
    if (branch >= branch_count) return error.BranchOrganGrowthIndexOutOfBounds;

    inline for (@typeInfo(Growth).@"struct".fields) |element_field| {
        const element = @field(growth, element_field.name);
        inline for (@typeInfo(ElementGrowth).@"struct".fields) |organ_field| {
            const value = @field(element, organ_field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidBranchOrganGrowth;
        }
    }

    // Validate the complete transaction before mutation while retaining the
    // Fortran state_update order below.
    inline for (.{
        pools.leaf_carbon_g_c[branch] + growth.carbon_g_c_per_timestep.leaf,
        pools.sheath_carbon_g_c[branch] + growth.carbon_g_c_per_timestep.sheath,
        pools.stalk_carbon_g_c[branch] + growth.carbon_g_c_per_timestep.stalk,
        pools.reserve_carbon_g_c[branch] + growth.carbon_g_c_per_timestep.reserve,
        pools.husk_carbon_g_c[branch] + growth.carbon_g_c_per_timestep.husk,
        pools.ear_carbon_g_c[branch] + growth.carbon_g_c_per_timestep.ear,
        pools.leaf_nitrogen_g_n[branch] + growth.nitrogen_g_n_per_timestep.leaf,
        pools.sheath_nitrogen_g_n[branch] + growth.nitrogen_g_n_per_timestep.sheath,
        pools.stalk_nitrogen_g_n[branch] + growth.nitrogen_g_n_per_timestep.stalk,
        pools.reserve_nitrogen_g_n[branch] + growth.nitrogen_g_n_per_timestep.reserve,
        pools.husk_nitrogen_g_n[branch] + growth.nitrogen_g_n_per_timestep.husk,
        pools.ear_nitrogen_g_n[branch] + growth.nitrogen_g_n_per_timestep.ear,
        pools.leaf_phosphorus_g_p[branch] + growth.phosphorus_g_p_per_timestep.leaf,
        pools.sheath_phosphorus_g_p[branch] + growth.phosphorus_g_p_per_timestep.sheath,
        pools.stalk_phosphorus_g_p[branch] + growth.phosphorus_g_p_per_timestep.stalk,
        pools.reserve_phosphorus_g_p[branch] + growth.phosphorus_g_p_per_timestep.reserve,
        pools.husk_phosphorus_g_p[branch] + growth.phosphorus_g_p_per_timestep.husk,
        pools.ear_phosphorus_g_p[branch] + growth.phosphorus_g_p_per_timestep.ear,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidBranchOrganGrowthResult;

    pools.leaf_carbon_g_c[branch] += growth.carbon_g_c_per_timestep.leaf;
    pools.sheath_carbon_g_c[branch] += growth.carbon_g_c_per_timestep.sheath;
    pools.stalk_carbon_g_c[branch] += growth.carbon_g_c_per_timestep.stalk;
    pools.reserve_carbon_g_c[branch] += growth.carbon_g_c_per_timestep.reserve;
    pools.husk_carbon_g_c[branch] += growth.carbon_g_c_per_timestep.husk;
    pools.ear_carbon_g_c[branch] += growth.carbon_g_c_per_timestep.ear;
    pools.leaf_nitrogen_g_n[branch] += growth.nitrogen_g_n_per_timestep.leaf;
    pools.sheath_nitrogen_g_n[branch] += growth.nitrogen_g_n_per_timestep.sheath;
    pools.stalk_nitrogen_g_n[branch] += growth.nitrogen_g_n_per_timestep.stalk;
    pools.reserve_nitrogen_g_n[branch] += growth.nitrogen_g_n_per_timestep.reserve;
    pools.husk_nitrogen_g_n[branch] += growth.nitrogen_g_n_per_timestep.husk;
    pools.ear_nitrogen_g_n[branch] += growth.nitrogen_g_n_per_timestep.ear;
    pools.leaf_phosphorus_g_p[branch] += growth.phosphorus_g_p_per_timestep.leaf;
    pools.sheath_phosphorus_g_p[branch] += growth.phosphorus_g_p_per_timestep.sheath;
    pools.stalk_phosphorus_g_p[branch] += growth.phosphorus_g_p_per_timestep.stalk;
    pools.reserve_phosphorus_g_p[branch] += growth.phosphorus_g_p_per_timestep.reserve;
    pools.husk_phosphorus_g_p[branch] += growth.phosphorus_g_p_per_timestep.husk;
    pools.ear_phosphorus_g_p[branch] += growth.phosphorus_g_p_per_timestep.ear;
}

fn uniformPools(storage: *[18][2]f64) Pools {
    return .{
        .leaf_carbon_g_c = &storage[0],
        .sheath_carbon_g_c = &storage[1],
        .stalk_carbon_g_c = &storage[2],
        .reserve_carbon_g_c = &storage[3],
        .husk_carbon_g_c = &storage[4],
        .ear_carbon_g_c = &storage[5],
        .leaf_nitrogen_g_n = &storage[6],
        .sheath_nitrogen_g_n = &storage[7],
        .stalk_nitrogen_g_n = &storage[8],
        .reserve_nitrogen_g_n = &storage[9],
        .husk_nitrogen_g_n = &storage[10],
        .ear_nitrogen_g_n = &storage[11],
        .leaf_phosphorus_g_p = &storage[12],
        .sheath_phosphorus_g_p = &storage[13],
        .stalk_phosphorus_g_p = &storage[14],
        .reserve_phosphorus_g_p = &storage[15],
        .husk_phosphorus_g_p = &storage[16],
        .ear_phosphorus_g_p = &storage[17],
    };
}

fn sampleGrowth() Growth {
    return .{
        .carbon_g_c_per_timestep = .{ .leaf = 1, .sheath = 2, .stalk = 3, .reserve = 4, .husk = 5, .ear = 6 },
        .nitrogen_g_n_per_timestep = .{ .leaf = 0.1, .sheath = 0.2, .stalk = 0.3, .reserve = 0.4, .husk = 0.5, .ear = 0.6 },
        .phosphorus_g_p_per_timestep = .{ .leaf = 0.01, .sheath = 0.02, .stalk = 0.03, .reserve = 0.04, .husk = 0.05, .ear = 0.06 },
    };
}

test "GROSUB publishes six organ C N P pools for a runtime branch" {
    var storage: [18][2]f64 = @splat(@splat(10));
    const pools = uniformPools(&storage);
    try publish(pools, 1, sampleGrowth());
    try std.testing.expectEqual(@as(f64, 11), pools.leaf_carbon_g_c[1]);
    try std.testing.expectEqual(@as(f64, 16), pools.ear_carbon_g_c[1]);
    try std.testing.expectEqual(@as(f64, 10.4), pools.reserve_nitrogen_g_n[1]);
    try std.testing.expectEqual(@as(f64, 10.06), pools.ear_phosphorus_g_p[1]);
    try std.testing.expectEqual(@as(f64, 10), pools.leaf_carbon_g_c[0]);
}

test "state_update is atomic on invalid growth or overflow" {
    var storage: [18][2]f64 = @splat(@splat(1));
    const pools = uniformPools(&storage);
    var invalid = sampleGrowth();
    invalid.nitrogen_g_n_per_timestep.husk = -1;
    try std.testing.expectError(error.InvalidBranchOrganGrowth, publish(pools, 0, invalid));
    try std.testing.expectEqual(@as(f64, 1), pools.leaf_carbon_g_c[0]);
    pools.ear_phosphorus_g_p[0] = std.math.floatMax(f64);
    var overflowing = sampleGrowth();
    overflowing.phosphorus_g_p_per_timestep.ear = std.math.floatMax(f64);
    try std.testing.expectError(error.InvalidBranchOrganGrowthResult, publish(pools, 0, overflowing));
    try std.testing.expectEqual(@as(f64, 1), pools.leaf_carbon_g_c[0]);
}

test "state_update rejects mismatched runtime topology and branch index" {
    var storage: [18][2]f64 = @splat(@splat(0));
    var pools = uniformPools(&storage);
    pools.ear_phosphorus_g_p = pools.ear_phosphorus_g_p[0..1];
    try std.testing.expectError(error.BranchOrganGrowthDimensionMismatch, publish(pools, 0, sampleGrowth()));
    pools = uniformPools(&storage);
    try std.testing.expectError(error.BranchOrganGrowthIndexOutOfBounds, publish(pools, 2, sampleGrowth()));
}

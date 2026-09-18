// **A8a DISPOSITION: unwired pure kernel, superseded; do not bind piecemeal.**
// Source: `startq.f` 485--545.
// Covered by production: the bound `plant_initialization` owner (`plant/initialization/seed_and_population.zig`), called across `ecosys_ng.zig:2393-2512`.
// This is NOT a double-mutation case. Nothing in `ecosys_ng.zig` names this
// module, and its entry point takes only structs it defines itself, so it has no
// path to production state and cannot compete for ownership. It is retained, not
// deleted, because it carries an exact source range and tests; binding it is part
// of the single consolidation refactor tracked as INIT-004, not an isolated wire.
// Group INDEX of docs/traceability/plant_initialization_unbound_family_are_unwired_kernels_not_competing_owners.md
const std = @import("std");

pub const ElementalMass = struct {
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
};

pub const PlantStressState = struct {
    water_stress: f64,
    chilling_accumulation: f64,
    heat_accumulation: f64,
};

pub const BranchBiomassState = struct {
    mobile_pool: ElementalMass,
    new_mobile_pool: ElementalMass,
    shoot: ElementalMass,
    leaf: ElementalMass,
    node: ElementalMass,
    sheath: ElementalMass,
    stalk: ElementalMass,
    reserve: ElementalMass,
    husk: ElementalMass,
    ear: ElementalMass,
    grain: ElementalMass,
    vascular_stalk_carbon_g_c: f64,
    leaf_sheath_carbon_g_c: f64,
    potential_grain_number: f64,
    actual_grain_number: f64,
    grain_weight_g: f64,
    leaf_area_m2: f64,
    ammonia_exchange_g_n: f64,
    recycled_leaf: ElementalMass,
    senescing_leaf: ElementalMass,
    total_leaf_area_m2: f64,
    recycled_sheath: ElementalMass,
    standing_dead: ElementalMass,
    senescing_sheath: ElementalMass,
    sheath_height_m: f64,
};

/// Translates the scalar and branch-owned portion of `startq.f` lines 485--545.
///
/// Branch count is runtime-defined. Nested canopy-layer and node arrays that
/// begin at line 546 remain a separate ownership block.
pub fn initialize(branches: []BranchBiomassState) PlantStressState {
    const stress = PlantStressState{
        .water_stress = 0.0,
        .chilling_accumulation = 0.0,
        .heat_accumulation = 0.0,
    };
    for (branches) |*branch| {
        branch.* = std.mem.zeroes(BranchBiomassState);
    }
    return stress;
}

test "runtime branches clear all morphology and elemental ledgers" {
    var branches: [3]BranchBiomassState = undefined;
    @memset(std.mem.asBytes(&branches), 0xff);

    const stress = initialize(&branches);

    try std.testing.expectEqual(std.mem.zeroes(PlantStressState), stress);
    for (branches) |branch| {
        try std.testing.expectEqual(std.mem.zeroes(BranchBiomassState), branch);
    }
}

test "zero runtime branches still initialize plant stress state" {
    var branches: [0]BranchBiomassState = .{};
    const stress = initialize(&branches);
    try std.testing.expectEqual(@as(f64, 0.0), stress.water_stress);
    try std.testing.expectEqual(@as(f64, 0.0), stress.chilling_accumulation);
    try std.testing.expectEqual(@as(f64, 0.0), stress.heat_accumulation);
}

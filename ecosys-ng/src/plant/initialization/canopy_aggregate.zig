// **A8a DISPOSITION: unwired pure kernel, superseded; do not bind piecemeal.**
// Source: `startq.f` 587--633.
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

pub const NonstructuralState = struct {
    pool: ElementalMass,
    canopy_carbon_concentration_g_c_g_c: f64,
    nodule_carbon_concentration_g_c_g_c: f64,
    canopy_nitrogen_concentration_g_n_g_c: f64,
    canopy_phosphorus_concentration_g_p_g_c: f64,
};

pub const LayerAggregates = struct {
    leaf_area_m2: []f64,
    living_leaf_carbon_g_c: []f64,
    standing_stalk_area_m2: []f64,
};

pub const SpeciesState = struct {
    nonstructural: NonstructuralState,
    shoot: ElementalMass,
    leaf: ElementalMass,
    sheath: ElementalMass,
    stalk: ElementalMass,
    reserve: ElementalMass,
    husk: ElementalMass,
    ear: ElementalMass,
    grain: ElementalMass,
    node: ElementalMass,
    shoot_carbon_change_g_c: f64,
    vascular_stalk_carbon_g_c: f64,
    total_root_carbon_g_c: f64,
    structural_root_carbon_g_c: f64,
    leaf_sheath_carbon_g_c: f64,
    total_leaf_area_m2: f64,
    root_carbon_per_plant_g_c: f64,
    standing_stalk_area_m2: f64,
};

pub const InitializationError = error{
    LayerCountMismatch,
};

/// Translates `startq.f` lines 587--633 with runtime canopy-layer extent.
pub fn initialize(
    layers: LayerAggregates,
    state: *SpeciesState,
) InitializationError!void {
    if (layers.living_leaf_carbon_g_c.len != layers.leaf_area_m2.len or
        layers.standing_stalk_area_m2.len != layers.leaf_area_m2.len)
    {
        return error.LayerCountMismatch;
    }

    for (0..layers.leaf_area_m2.len) |layer| {
        layers.leaf_area_m2[layer] = 0.0;
        layers.living_leaf_carbon_g_c[layer] = 0.0;
        layers.standing_stalk_area_m2[layer] = 0.0;
    }
    state.* = std.mem.zeroes(SpeciesState);
}

test "runtime canopy layers and species aggregates reset completely" {
    var leaf_area = [_]f64{ 1.0, 2.0, 3.0 };
    var leaf_carbon = [_]f64{ 4.0, 5.0, 6.0 };
    var stalk_area = [_]f64{ 7.0, 8.0, 9.0 };
    var state: SpeciesState = undefined;
    @memset(std.mem.asBytes(&state), 0xff);

    try initialize(.{
        .leaf_area_m2 = &leaf_area,
        .living_leaf_carbon_g_c = &leaf_carbon,
        .standing_stalk_area_m2 = &stalk_area,
    }, &state);

    try std.testing.expectEqualSlices(f64, &.{ 0.0, 0.0, 0.0 }, &leaf_area);
    try std.testing.expectEqualSlices(f64, &.{ 0.0, 0.0, 0.0 }, &leaf_carbon);
    try std.testing.expectEqualSlices(f64, &.{ 0.0, 0.0, 0.0 }, &stalk_area);
    try std.testing.expectEqual(std.mem.zeroes(SpeciesState), state);
}

test "layer mismatch fails before any reset" {
    var leaf_area = [_]f64{1.0};
    var leaf_carbon = [_]f64{ 2.0, 3.0 };
    var stalk_area = [_]f64{4.0};
    var state = std.mem.zeroes(SpeciesState);
    state.total_leaf_area_m2 = 5.0;

    try std.testing.expectError(error.LayerCountMismatch, initialize(.{
        .leaf_area_m2 = &leaf_area,
        .living_leaf_carbon_g_c = &leaf_carbon,
        .standing_stalk_area_m2 = &stalk_area,
    }, &state));
    try std.testing.expectEqual(@as(f64, 1.0), leaf_area[0]);
    try std.testing.expectEqual(@as(f64, 5.0), state.total_leaf_area_m2);
}

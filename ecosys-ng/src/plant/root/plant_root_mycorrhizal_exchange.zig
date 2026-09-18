const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const Roots = @import("plant_root_system.zig");
const RootMetabolism = @import("plant_root_metabolism.zig");

pub const Parameters = struct {
    minimum_partner_water_volume_ratio: f64,
    exchange_fraction_per_h: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0 or value > 1)
                return error.InvalidRootMycorrhizalExchangeParameter;
        }
    }
};

pub fn compatibilityParameters() Parameters {
    return .{
        .minimum_partner_water_volume_ratio = 0.05,
        .exchange_fraction_per_h = 0.5,
    };
}

pub const Transfer = struct {
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
};

/// GROSUB 425 traversal is restricted to the plant's rooted profile
/// `NU..NIX`, inclusive.
pub fn sourceOrderLayerIsEligible(
    layer: usize,
    planting_layer: usize,
    deepest_rooted_layer: usize,
) bool {
    return deepest_rooted_layer >= planting_layer and
        layer >= planting_layer and layer <= deepest_rooted_layer;
}

/// grosub.f lines 8098--8153 are lexically nested inside the preceding
/// WTPLTT and CPOOLT gates. Dynamic salt exchange therefore requires both
/// effective partner water and pre-exchange mobile C above their thresholds.
pub fn sourceOrderSaltExchangeIsEnabled(
    dynamic_salts: bool,
    effective_water_total_m3: f64,
    mobile_carbon_total_g_c: f64,
    water_presence_threshold_m3: f64,
    carbon_presence_threshold_g_c: f64,
) !bool {
    inline for (.{
        effective_water_total_m3,
        mobile_carbon_total_g_c,
        water_presence_threshold_m3,
        carbon_presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidRootMycorrhizalSaltExchangeGate;
    return dynamic_salts and
        effective_water_total_m3 > water_presence_threshold_m3 and
        mobile_carbon_total_g_c > carbon_presence_threshold_g_c;
}

/// grosub.f lines 8055--8074 include a strict population-scaled ZEROP gate on
/// effective partner water before evaluating C/N/P exchange.
pub fn sourceOrderCalculate(
    parameters: Parameters,
    timestep_h: f64,
    root_water_volume_m3: f64,
    mycorrhizal_water_volume_m3: f64,
    root_carbon_g_c: f64,
    mycorrhizal_carbon_g_c: f64,
    root_nitrogen_g_n: f64,
    mycorrhizal_nitrogen_g_n: f64,
    root_phosphorus_g_p: f64,
    mycorrhizal_phosphorus_g_p: f64,
    presence_threshold_m3: f64,
) !Transfer {
    if (!std.math.isFinite(presence_threshold_m3) or presence_threshold_m3 < 0)
        return error.InvalidRootMycorrhizalExchangeInput;
    try parameters.validate();
    inline for (.{
        timestep_h,
        root_water_volume_m3,
        mycorrhizal_water_volume_m3,
        root_carbon_g_c,
        mycorrhizal_carbon_g_c,
        root_nitrogen_g_n,
        mycorrhizal_nitrogen_g_n,
        root_phosphorus_g_p,
        mycorrhizal_phosphorus_g_p,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidRootMycorrhizalExchangeInput;
    const effective_partner_m3 = @min(
        root_water_volume_m3,
        @max(parameters.minimum_partner_water_volume_ratio * root_water_volume_m3, mycorrhizal_water_volume_m3),
    );
    if (!std.math.isFinite(effective_partner_m3) or effective_partner_m3 < 0)
        return error.InvalidRootMycorrhizalExchangeInput;
    if (root_water_volume_m3 + effective_partner_m3 <= presence_threshold_m3)
        return .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    return calculate(
        parameters,
        timestep_h,
        root_water_volume_m3,
        mycorrhizal_water_volume_m3,
        root_carbon_g_c,
        mycorrhizal_carbon_g_c,
        root_nitrogen_g_n,
        mycorrhizal_nitrogen_g_n,
        root_phosphorus_g_p,
        mycorrhizal_phosphorus_g_p,
    );
}

/// Positive values move from the root to its mycorrhizal partner.
pub fn calculate(
    parameters: Parameters,
    timestep_h: f64,
    root_water_volume_m3: f64,
    mycorrhizal_water_volume_m3: f64,
    root_carbon_g_c: f64,
    mycorrhizal_carbon_g_c: f64,
    root_nitrogen_g_n: f64,
    mycorrhizal_nitrogen_g_n: f64,
    root_phosphorus_g_p: f64,
    mycorrhizal_phosphorus_g_p: f64,
) !Transfer {
    try parameters.validate();
    inline for (.{
        timestep_h,               root_water_volume_m3,   mycorrhizal_water_volume_m3,
        root_carbon_g_c,          mycorrhizal_carbon_g_c, root_nitrogen_g_n,
        mycorrhizal_nitrogen_g_n, root_phosphorus_g_p,    mycorrhizal_phosphorus_g_p,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootMycorrhizalExchangeInput;

    const effective_mycorrhizal_water_m3 = @min(
        root_water_volume_m3,
        @max(parameters.minimum_partner_water_volume_ratio * root_water_volume_m3, mycorrhizal_water_volume_m3),
    );
    const water_total_m3 = root_water_volume_m3 + effective_mycorrhizal_water_m3;
    if (water_total_m3 == 0) return .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    const rate_timestep = parameters.exchange_fraction_per_h * timestep_h;
    const carbon = rate_timestep *
        (root_carbon_g_c * effective_mycorrhizal_water_m3 - mycorrhizal_carbon_g_c * root_water_volume_m3) /
        water_total_m3;
    const carbon_total = root_carbon_g_c + mycorrhizal_carbon_g_c;
    const result: Transfer = if (carbon_total > 0) .{
        .carbon_g_c = carbon,
        .nitrogen_g_n = rate_timestep * (root_nitrogen_g_n * mycorrhizal_carbon_g_c - mycorrhizal_nitrogen_g_n * root_carbon_g_c) / carbon_total,
        .phosphorus_g_p = rate_timestep * (root_phosphorus_g_p * mycorrhizal_carbon_g_c - mycorrhizal_phosphorus_g_p * root_carbon_g_c) / carbon_total,
    } else .{ .carbon_g_c = carbon, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    inline for (@typeInfo(Transfer).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteRootMycorrhizalExchange;
    return result;
}

pub const ApplyContext = struct {
    roots: *Roots.State,
    cell_count: usize,
    species_count: usize,
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    plant_parameters: []const RootMetabolism.RuntimePlantParameters,
    parameters: Parameters,
    timestep_h: f64,
    salinity_enabled_by_cell: []const bool,
};

pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    try context.parameters.validate();
    if (context.active_by_plant.len != context.roots.plant_count or
        context.plant_parameters.len != context.roots.plant_count or range.first > range.end)
        return error.RootMycorrhizalExchangeDimensionMismatch;
    if (context.cell_count == 0 or context.species_count * context.cell_count != context.roots.plant_count or range.end > context.cell_count or context.active_soil_layer_count_by_cell.len != context.cell_count or context.salinity_enabled_by_cell.len != context.cell_count)
        return error.RootMycorrhizalExchangeDimensionMismatch;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h < 0) return error.InvalidRootMycorrhizalExchangeInput;

    // Validate the complete tile from one snapshot before publishing any
    // donor/recipient pair. The second traversal is infallible because each
    // plant/domain/layer pair owns disjoint state.
    try processTile(context, range, false);
    processTile(context, range, true) catch unreachable;
}

fn processTile(context: *ApplyContext, range: CellRange, comptime commit: bool) !void {
    for (range.first..range.end) |cell| for (0..context.species_count) |species| {
        if (context.active_soil_layer_count_by_cell[cell] > context.roots.soil_layer_count)
            return error.RootMycorrhizalExchangeDimensionMismatch;
        const plant = cell * context.species_count + species;
        if (!context.active_by_plant[plant] or context.plant_parameters[plant].mycorrhizal_type != 2) continue;
        const planting_layer = context.roots.planting_layer_by_plant[plant];
        const deepest_rooted_layer = context.roots.current_deepest_rooted_layer_by_plant[plant];
        if (planting_layer >= context.active_soil_layer_count_by_cell[cell] or
            deepest_rooted_layer < planting_layer or
            deepest_rooted_layer >= context.active_soil_layer_count_by_cell[cell])
            return error.InvalidRootMycorrhizalExchangeLayerSelector;
        // GROSUB DO 425 is NU..NIX, not the complete active soil profile.
        // The preflight pass validates every selected pair before the commit
        // pass, so a malformed selector or late overdraw leaves all pools
        // unchanged.
        for (planting_layer..deepest_rooted_layer + 1) |layer| {
            const root = if (commit) context.roots.layerIndex(plant, 0, layer) catch unreachable else try context.roots.layerIndex(plant, 0, layer);
            const mycorrhiza = if (commit) context.roots.layerIndex(plant, 1, layer) catch unreachable else try context.roots.layerIndex(plant, 1, layer);
            inline for (.{
                context.roots.aqueous_volume_m3[root],
                context.roots.aqueous_volume_m3[mycorrhiza],
                context.roots.mobile_carbon_g[root],
                context.roots.mobile_carbon_g[mycorrhiza],
                context.roots.mobile_nitrogen_g[root],
                context.roots.mobile_nitrogen_g[mycorrhiza],
                context.roots.mobile_phosphorus_g[root],
                context.roots.mobile_phosphorus_g[mycorrhiza],
            }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootMycorrhizalExchangeInput;
            const transfer_result = calculate(
                context.parameters,
                context.timestep_h,
                context.roots.aqueous_volume_m3[root],
                context.roots.aqueous_volume_m3[mycorrhiza],
                context.roots.mobile_carbon_g[root],
                context.roots.mobile_carbon_g[mycorrhiza],
                context.roots.mobile_nitrogen_g[root],
                context.roots.mobile_nitrogen_g[mycorrhiza],
                context.roots.mobile_phosphorus_g[root],
                context.roots.mobile_phosphorus_g[mycorrhiza],
            );
            const transfer = if (commit) transfer_result catch unreachable else try transfer_result;
            const next_elements = [_]f64{
                context.roots.mobile_carbon_g[root] - transfer.carbon_g_c,
                context.roots.mobile_carbon_g[mycorrhiza] + transfer.carbon_g_c,
                context.roots.mobile_nitrogen_g[root] - transfer.nitrogen_g_n,
                context.roots.mobile_nitrogen_g[mycorrhiza] + transfer.nitrogen_g_n,
                context.roots.mobile_phosphorus_g[root] - transfer.phosphorus_g_p,
                context.roots.mobile_phosphorus_g[mycorrhiza] + transfer.phosphorus_g_p,
            };
            if (!commit) inline for (next_elements) |value| if (!std.math.isFinite(value) or value < 0) return error.RootMycorrhizalExchangeWouldOverdraw;

            const salt_water_total_m3 = context.roots.aqueous_volume_m3[root] + context.roots.aqueous_volume_m3[mycorrhiza];
            if (context.salinity_enabled_by_cell[cell] and salt_water_total_m3 > 0) for (0..Roots.salt_species_count) |salt| {
                const root_salt = root * Roots.salt_species_count + salt;
                const mycorrhizal_salt = mycorrhiza * Roots.salt_species_count + salt;
                if (!commit and (!std.math.isFinite(context.roots.salt_content_mol[root_salt]) or context.roots.salt_content_mol[root_salt] < 0 or !std.math.isFinite(context.roots.salt_content_mol[mycorrhizal_salt]) or context.roots.salt_content_mol[mycorrhizal_salt] < 0))
                    return error.InvalidRootMycorrhizalExchangeInput;
                const salt_transfer_mol = context.parameters.exchange_fraction_per_h * context.timestep_h *
                    (context.roots.salt_content_mol[root_salt] * context.roots.aqueous_volume_m3[mycorrhiza] -
                        context.roots.salt_content_mol[mycorrhizal_salt] * context.roots.aqueous_volume_m3[root]) / salt_water_total_m3;
                const next_root = context.roots.salt_content_mol[root_salt] - salt_transfer_mol;
                const next_mycorrhiza = context.roots.salt_content_mol[mycorrhizal_salt] + salt_transfer_mol;
                if (!commit and (!std.math.isFinite(next_root) or !std.math.isFinite(next_mycorrhiza) or next_root < 0 or next_mycorrhiza < 0))
                    return error.RootMycorrhizalSaltExchangeWouldOverdraw;
                if (commit) {
                    context.roots.salt_content_mol[root_salt] = next_root;
                    context.roots.salt_content_mol[mycorrhizal_salt] = next_mycorrhiza;
                }
            };

            if (commit) {
                context.roots.mobile_carbon_g[root] = next_elements[0];
                context.roots.mobile_carbon_g[mycorrhiza] = next_elements[1];
                context.roots.mobile_nitrogen_g[root] = next_elements[2];
                context.roots.mobile_nitrogen_g[mycorrhiza] = next_elements[3];
                context.roots.mobile_phosphorus_g[root] = next_elements[4];
                context.roots.mobile_phosphorus_g[mycorrhiza] = next_elements[5];
            }
        }
    };
}

test "root-mycorrhizal exchange conserves mobile elements" {
    const result = try calculate(compatibilityParameters(), 1, 2, 1, 4, 1, 0.4, 0.2, 0.08, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), result.carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.04), result.nitrogen_g_n, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.004), result.phosphorus_g_p, 1.0e-12);
}

test "GROSUB root-mycorrhizal exchange uses strict WTPLTT ZEROP gate" {
    const result = try sourceOrderCalculate(
        .{ .minimum_partner_water_volume_ratio = 0, .exchange_fraction_per_h = 0.5 },
        1,
        1,
        0,
        4,
        1,
        0.4,
        0.2,
        0.08,
        0.01,
        1,
    );
    try std.testing.expectEqual(Transfer{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 }, result);
}

test "GROSUB root-mycorrhizal traversal is limited to NU through NIX" {
    try std.testing.expect(!sourceOrderLayerIsEligible(1, 2, 4));
    try std.testing.expect(sourceOrderLayerIsEligible(2, 2, 4));
    try std.testing.expect(sourceOrderLayerIsEligible(4, 2, 4));
    try std.testing.expect(!sourceOrderLayerIsEligible(5, 2, 4));
    try std.testing.expect(!sourceOrderLayerIsEligible(2, 4, 2));
}

test "GROSUB dynamic salt exchange retains enclosing water and carbon gates" {
    try std.testing.expect(try sourceOrderSaltExchangeIsEnabled(true, 2, 1, 0.1, 0.1));
    try std.testing.expect(!try sourceOrderSaltExchangeIsEnabled(false, 2, 1, 0.1, 0.1));
    try std.testing.expect(!try sourceOrderSaltExchangeIsEnabled(true, 0.1, 1, 0.1, 0.1));
    try std.testing.expect(!try sourceOrderSaltExchangeIsEnabled(true, 2, 0.1, 0.1, 0.1));
}

test "live exchange follows the source MY equals two gate" {
    var roots = try Roots.State.init(std.testing.allocator, 2, 2, 1);
    defer roots.deinit();
    const active = [_]bool{ true, true };
    const base: RootMetabolism.RuntimePlantParameters = .{
        .root_profile_type = 1,
        .mycorrhizal_type = 0,
        .growth_habit = 1,
        .leaf_phenology_type = 0,
        .root_growth_yield_g_c_per_g_c = 0.7,
        .root_nitrogen_to_carbon_g_n_per_g_c = 0.03,
        .root_phosphorus_to_carbon_g_p_per_g_c = 0.003,
        .stalk_nitrogen_to_carbon_g_n_per_g_c = 0.01,
        .stalk_phosphorus_to_carbon_g_p_per_g_c = 0.001,
        .primary_root_radius_m = 0.001,
        .secondary_root_radius_m = 0.0002,
        .primary_specific_length_m_per_g_c = 10,
        .secondary_specific_length_m_per_g_c = 20,
        .secondary_root_branching_per_m = 2,
        .shoot_root_equilibration_fraction_per_h = 0.1,
    };
    var enabled = base;
    enabled.mycorrhizal_type = 2;
    const plant_parameters = [_]RootMetabolism.RuntimePlantParameters{ base, enabled };
    for (0..2) |plant| {
        const root = try roots.layerIndex(plant, 0, 0);
        const mycorrhiza = try roots.layerIndex(plant, 1, 0);
        roots.aqueous_volume_m3[root] = 2;
        roots.aqueous_volume_m3[mycorrhiza] = 1;
        roots.mobile_carbon_g[root] = 4;
        roots.mobile_carbon_g[mycorrhiza] = 1;
        for (0..Roots.salt_species_count) |salt| {
            const scale: f64 = @floatFromInt(salt + 1);
            roots.salt_content_mol[root * Roots.salt_species_count + salt] = 3 * scale;
            roots.salt_content_mol[mycorrhiza * Roots.salt_species_count + salt] = scale;
        }
    }
    const inactive_root = try roots.layerIndex(1, 0, 1);
    const inactive_mycorrhiza = try roots.layerIndex(1, 1, 1);
    roots.aqueous_volume_m3[inactive_root] = 2;
    roots.aqueous_volume_m3[inactive_mycorrhiza] = 1;
    roots.mobile_carbon_g[inactive_root] = 4;
    roots.mobile_carbon_g[inactive_mycorrhiza] = 1;
    var context: ApplyContext = .{
        .roots = &roots,
        .cell_count = 1,
        .species_count = 2,
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &active,
        .plant_parameters = &plant_parameters,
        .parameters = compatibilityParameters(),
        .timestep_h = 1,
        .salinity_enabled_by_cell = &.{true},
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 4), roots.mobile_carbon_g[try roots.layerIndex(0, 0, 0)]);
    try std.testing.expect(roots.mobile_carbon_g[try roots.layerIndex(1, 0, 0)] < 4);
    try std.testing.expectApproxEqAbs(
        @as(f64, 5),
        roots.mobile_carbon_g[try roots.layerIndex(1, 0, 0)] + roots.mobile_carbon_g[try roots.layerIndex(1, 1, 0)],
        1.0e-12,
    );
    try std.testing.expectEqual(@as(f64, 4), roots.mobile_carbon_g[inactive_root]);
    try std.testing.expectEqual(@as(f64, 1), roots.mobile_carbon_g[inactive_mycorrhiza]);
    const enabled_root = try roots.layerIndex(1, 0, 0);
    const enabled_mycorrhiza = try roots.layerIndex(1, 1, 0);
    for (0..Roots.salt_species_count) |salt| {
        const scale: f64 = @floatFromInt(salt + 1);
        const root_salt = roots.salt_content_mol[enabled_root * Roots.salt_species_count + salt];
        const mycorrhizal_salt = roots.salt_content_mol[enabled_mycorrhiza * Roots.salt_species_count + salt];
        try std.testing.expectApproxEqAbs(4 * scale, root_salt + mycorrhizal_salt, 1.0e-12);
        try std.testing.expect(root_salt < 3 * scale);
    }
}

test "live GROSUB exchange changes only the plant NU through NIX layers" {
    var roots = try Roots.State.init(std.testing.allocator, 1, 4, 1);
    defer roots.deinit();
    roots.planting_layer_by_plant[0] = 1;
    roots.current_deepest_rooted_layer_by_plant[0] = 2;
    roots.next_deepest_rooted_layer_by_plant[0] = 2;
    roots.deepest_rooted_layer_by_axis[0] = 2;
    for (0..4) |layer| {
        const root = try roots.layerIndex(0, 0, layer);
        const partner = try roots.layerIndex(0, 1, layer);
        roots.aqueous_volume_m3[root] = 2;
        roots.aqueous_volume_m3[partner] = 1;
        roots.mobile_carbon_g[root] = 4;
        roots.mobile_carbon_g[partner] = 1;
    }
    var plant_parameter = std.mem.zeroes(RootMetabolism.RuntimePlantParameters);
    plant_parameter.mycorrhizal_type = 2;
    var context: ApplyContext = .{
        .roots = &roots,
        .cell_count = 1,
        .species_count = 1,
        .active_soil_layer_count_by_cell = &.{4},
        .active_by_plant = &.{true},
        .plant_parameters = &.{plant_parameter},
        .parameters = compatibilityParameters(),
        .timestep_h = 1,
        .salinity_enabled_by_cell = &.{false},
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    for (0..4) |layer| {
        const root = try roots.layerIndex(0, 0, layer);
        const partner = try roots.layerIndex(0, 1, layer);
        try std.testing.expectApproxEqAbs(@as(f64, 5), roots.mobile_carbon_g[root] + roots.mobile_carbon_g[partner], 1.0e-12);
        if (layer >= 1 and layer <= 2) {
            try std.testing.expect(roots.mobile_carbon_g[root] < 4);
            try std.testing.expect(roots.mobile_carbon_g[partner] > 1);
        } else {
            try std.testing.expectEqual(@as(f64, 4), roots.mobile_carbon_g[root]);
            try std.testing.expectEqual(@as(f64, 1), roots.mobile_carbon_g[partner]);
        }
    }
}

test "invalid late NU NIX selector leaves the complete tile unchanged" {
    var roots = try Roots.State.init(std.testing.allocator, 2, 2, 1);
    defer roots.deinit();
    roots.planting_layer_by_plant[1] = 1;
    // Invalid for plant one: NIX remains zero, above NU=one.
    var plant_parameter = std.mem.zeroes(RootMetabolism.RuntimePlantParameters);
    plant_parameter.mycorrhizal_type = 2;
    for (0..2) |plant| {
        const root = try roots.layerIndex(plant, 0, 0);
        const partner = try roots.layerIndex(plant, 1, 0);
        roots.aqueous_volume_m3[root] = 2;
        roots.aqueous_volume_m3[partner] = 1;
        roots.mobile_carbon_g[root] = 4;
        roots.mobile_carbon_g[partner] = 1;
    }
    const before = try std.testing.allocator.dupe(f64, roots.mobile_carbon_g);
    defer std.testing.allocator.free(before);
    var context: ApplyContext = .{
        .roots = &roots,
        .cell_count = 1,
        .species_count = 2,
        .active_soil_layer_count_by_cell = &.{2},
        .active_by_plant = &.{ true, true },
        .plant_parameters = &.{ plant_parameter, plant_parameter },
        .parameters = compatibilityParameters(),
        .timestep_h = 1,
        .salinity_enabled_by_cell = &.{false},
    };
    try std.testing.expectError(error.InvalidRootMycorrhizalExchangeLayerSelector, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqualSlices(f64, before, roots.mobile_carbon_g);
}

test "mycorrhizal sub-legacy-tolerance overdraw leaves the entire tile unchanged" {
    var roots = try Roots.State.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    var plant_parameter = std.mem.zeroes(RootMetabolism.RuntimePlantParameters);
    plant_parameter.mycorrhizal_type = 2;
    roots.current_deepest_rooted_layer_by_plant[0] = 1;
    for (0..2) |layer| {
        const root = try roots.layerIndex(0, 0, layer);
        const partner = try roots.layerIndex(0, 1, layer);
        roots.aqueous_volume_m3[root] = 1;
        roots.aqueous_volume_m3[partner] = 1;
        roots.mobile_carbon_g[root] = 1;
        roots.mobile_carbon_g[partner] = if (layer == 0) 1 else 0;
    }
    const before = try std.testing.allocator.dupe(f64, roots.mobile_carbon_g);
    defer std.testing.allocator.free(before);
    var context: ApplyContext = .{
        .roots = &roots,
        .cell_count = 1,
        .species_count = 1,
        .active_soil_layer_count_by_cell = &.{2},
        .active_by_plant = &.{true},
        .plant_parameters = &.{plant_parameter},
        .parameters = .{ .minimum_partner_water_volume_ratio = 0, .exchange_fraction_per_h = 1 },
        .timestep_h = 2.0000000000002,
        .salinity_enabled_by_cell = &.{false},
    };
    try std.testing.expectError(error.RootMycorrhizalExchangeWouldOverdraw, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqualSlices(f64, before, roots.mobile_carbon_g);
}

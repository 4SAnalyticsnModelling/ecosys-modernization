const std = @import("std");
const SoilProfile = @import("../../state/soil_profile.zig").SoilProfile;
const SoilMaterial = @import("../profile/initialization.zig").SoilMaterial;
const retention = @import("retention.zig");

pub const SoilHydrology = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    /// Maximum-rooting-layer bound (the oracle's `NJ`), expressed in the same
    /// 0-based, surface-relative layer numbering as every `[]f64` field here:
    /// `profile.maximum_rooting_layer_index - profile.surface_layer_index + 1`.
    /// Strictly `<= layer_count` (the oracle's `NL`, i.e. `layer_count`
    /// includes described and extrapolated layers below the rooting zone
    /// that root-zone-bounded disturbance handlers must not touch).
    maximum_rooting_layer_count: usize,
    layer_thickness_m: []f64,
    total_layer_volume_m3: []f64,
    matrix_volume_m3: []f64,
    matrix_pore_volume_m3: []f64,
    macropore_volume_m3: []f64,
    total_porosity_fraction: []f64,
    initial_water_fraction: []f64,
    initial_ice_fraction: []f64,
    matrix_water_volume_m3: []f64,
    macropore_water_volume_m3: []f64,
    matrix_ice_volume_m3: []f64,
    macropore_ice_volume_m3: []f64,
    matrix_air_volume_m3: []f64,
    macropore_air_volume_m3: []f64,
    air_volume_m3: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        profile: SoilProfile,
        material: SoilMaterial,
        horizontal_cell_area_m2: f64,
        retention_parameters: retention.Parameters,
    ) !SoilHydrology {
        if (!std.math.isFinite(horizontal_cell_area_m2) or horizontal_cell_area_m2 <= 0.0) return error.InvalidHorizontalCellArea;
        if (profile.total_layer_count != material.layer_count) return error.SoilLayerCountMismatch;
        var result: SoilHydrology = undefined;
        result.allocator = allocator;
        result.layer_count = profile.total_layer_count;
        result.maximum_rooting_layer_count = try std.math.add(
            usize,
            profile.maximum_rooting_layer_index - profile.surface_layer_index,
            1,
        );
        if (result.maximum_rooting_layer_count == 0 or result.maximum_rooting_layer_count > result.layer_count)
            return error.InvalidMaximumRootingLayerCount;
        var allocated: usize = 0;
        errdefer freeAllocated(&result, allocated);
        inline for (@typeInfo(SoilHydrology).@"struct".fields) |field| {
            if (field.type == []f64) {
                @field(result, field.name) = try allocator.alloc(f64, result.layer_count);
                allocated += 1;
            }
        }

        const input_water = profile.property(.initial_liquid_water);
        const input_ice = profile.property(.initial_ice_water);
        const organic_carbon = material.total_organic_carbon_g_per_megagram;
        var previous_bottom_m: f64 = 0.0;
        for (0..result.layer_count) |layer| {
            const thickness_m = profile.depth_to_layer_bottom_m[layer] - previous_bottom_m;
            previous_bottom_m = profile.depth_to_layer_bottom_m[layer];
            if (!std.math.isFinite(thickness_m) or thickness_m <= 0.0) return error.InvalidSoilLayerThickness;
            const total_volume_m3 = horizontal_cell_area_m2 * thickness_m;
            const matrix_volume_m3 = total_volume_m3 * material.micropore_fraction[layer];
            const organic_equivalent_g_per_megagram = @min(1_000_000.0, organic_carbon[layer] / 0.55);
            const particle_density_megagrams_per_m3 = 1.0e-6 *
                (1.30 * organic_equivalent_g_per_megagram + 2.66 * (1_000_000.0 - organic_equivalent_g_per_megagram));
            const bulk_density = material.bulk_density_megagrams_per_m3[layer];
            const porosity = if (bulk_density > 1.0e-12)
                1.0 - bulk_density / particle_density_megagrams_per_m3
            else
                1.0;
            if (!std.math.isFinite(porosity) or porosity < 0.0 or porosity > 1.0) return error.InvalidSoilPorosity;
            const curve = try retention.resolve(retention_parameters, .{
                .porosity_fraction = porosity,
                .macropore_fraction = profile.macropore_fraction[layer],
                .sand_fraction = material.sand_mass_fraction[layer],
                .clay_fraction = material.clay_mass_fraction[layer],
                .organic_carbon_g_per_megagram = organic_carbon[layer],
                .bulk_density_megagrams_per_m3 = bulk_density,
                .supplied_field_capacity_fraction = supplied(profile.field_capacity_m3_m3[layer]),
                .supplied_wilting_point_fraction = supplied(profile.wilting_point_m3_m3[layer]),
            }, profile.field_capacity_potential_megapascal, profile.wilting_point_potential_megapascal);

            const water_fraction = decodeWaterFraction(input_water[layer], porosity, curve.curve.field_capacity_fraction, curve.curve.wilting_point_fraction);
            const ice_fraction = decodeIceFraction(input_ice[layer], porosity, water_fraction, curve.curve.field_capacity_fraction, curve.curve.wilting_point_fraction);
            if (water_fraction + ice_fraction > porosity + 1.0e-12) return error.InitialWaterExceedsPorosity;
            const macropore_volume_m3 = profile.macropore_fraction[layer] * total_volume_m3;
            const matrix_pore_volume_m3 = porosity * matrix_volume_m3;
            const matrix_water_m3 = water_fraction * matrix_volume_m3;
            const matrix_ice_m3 = ice_fraction * matrix_volume_m3;
            const macropore_water_m3 = water_fraction * macropore_volume_m3;
            const macropore_ice_m3 = ice_fraction * macropore_volume_m3;

            result.layer_thickness_m[layer] = thickness_m;
            result.total_layer_volume_m3[layer] = total_volume_m3;
            result.matrix_volume_m3[layer] = matrix_volume_m3;
            result.matrix_pore_volume_m3[layer] = matrix_pore_volume_m3;
            result.macropore_volume_m3[layer] = macropore_volume_m3;
            result.total_porosity_fraction[layer] = porosity;
            result.initial_water_fraction[layer] = water_fraction;
            result.initial_ice_fraction[layer] = ice_fraction;
            result.matrix_water_volume_m3[layer] = matrix_water_m3;
            result.macropore_water_volume_m3[layer] = macropore_water_m3;
            result.matrix_ice_volume_m3[layer] = matrix_ice_m3;
            result.macropore_ice_volume_m3[layer] = macropore_ice_m3;
            result.matrix_air_volume_m3[layer] = @max(0.0, matrix_pore_volume_m3 - matrix_water_m3 - matrix_ice_m3);
            result.macropore_air_volume_m3[layer] = @max(0.0, macropore_volume_m3 - macropore_water_m3 - macropore_ice_m3);
            result.air_volume_m3[layer] = result.matrix_air_volume_m3[layer] + result.macropore_air_volume_m3[layer];
        }
        try result.validateFinite();
        return result;
    }

    pub fn deinit(self: *SoilHydrology) void {
        inline for (@typeInfo(SoilHydrology).@"struct".fields) |field| {
            if (field.type == []f64) self.allocator.free(@field(self, field.name));
        }
        self.* = undefined;
    }

    fn validateFinite(self: SoilHydrology) !void {
        inline for (@typeInfo(SoilHydrology).@"struct".fields) |field| {
            if (field.type == []f64) for (@field(self, field.name), 0..) |value, layer| {
                if (!std.math.isFinite(value)) {
                    std.log.err("non-finite initialized hydrology: field={s} layer={d}", .{ field.name, layer });
                    return error.NonFiniteInitializedHydrology;
                }
            };
        }
    }
};

fn supplied(value: f64) ?f64 {
    return if (value < 0) null else value;
}

fn decodeWaterFraction(input: f64, porosity: f64, field_capacity: f64, wilting_point: f64) f64 {
    if (input > 1.0) return porosity;
    if (input == 1.0) return field_capacity;
    if (input == 0.0) return wilting_point;
    if (input < 0.0) return 0.0;
    return input;
}

fn decodeIceFraction(input: f64, porosity: f64, water_fraction: f64, field_capacity: f64, wilting_point: f64) f64 {
    const available_porosity = @max(0.0, porosity - water_fraction);
    if (input > 1.0) return @min(porosity, available_porosity);
    if (input == 1.0) return @min(field_capacity, available_porosity);
    if (input == 0.0) return @min(wilting_point, available_porosity);
    if (input < 0.0) return 0.0;
    return input;
}

fn freeAllocated(state: *SoilHydrology, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(SoilHydrology).@"struct".fields) |field| {
        if (field.type == []f64) {
            if (visited < count) state.allocator.free(@field(state, field.name));
            visited += 1;
        }
    }
}

test "initialize water and ice from reference sentinel rules" {
    const source = try @import("../../core/test_fixtures.zig").soilProfileSource(std.testing.allocator, @typeInfo(@import("../../state/soil_profile.zig").LayerProperty).@"enum".fields.len);
    defer std.testing.allocator.free(source);
    var profile = try @import("../../state/soil_profile.zig").parsePhysicalProfile(std.testing.allocator, source);
    defer profile.deinit();
    var material = try SoilMaterial.init(std.testing.allocator, profile, @import("../profile/derivation.zig").compatibilityParameters());
    defer material.deinit();
    const parameters = retention.compatibilityParameters();
    var hydrology = try SoilHydrology.init(std.testing.allocator, profile, material, 1.0, parameters);
    defer hydrology.deinit();
    try std.testing.expectApproxEqAbs(profile.field_capacity_m3_m3[0], hydrology.initial_water_fraction[0], 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0.0), hydrology.initial_ice_fraction[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), hydrology.layer_thickness_m[0], 1.0e-12);
    try std.testing.expect(hydrology.air_volume_m3[0] >= 0.0);
}

test "negative initial water sentinel preserves source zero" {
    try std.testing.expectEqual(
        @as(f64, 0),
        decodeWaterFraction(-1, 0.5, 0.3, 0.1),
    );
}

test "negative field capacity and wilting sentinels use HOUR1 runtime estimators" {
    const allocator = std.testing.allocator;
    const source = try @import("../../core/test_fixtures.zig").soilProfileSource(allocator, @typeInfo(@import("../../state/soil_profile.zig").LayerProperty).@"enum".fields.len);
    defer allocator.free(source);
    var profile = try @import("../../state/soil_profile.zig").parsePhysicalProfile(allocator, source);
    defer profile.deinit();
    profile.field_capacity_m3_m3[0] = -1;
    profile.wilting_point_m3_m3[0] = -1;
    var material = try SoilMaterial.init(allocator, profile, @import("../profile/derivation.zig").compatibilityParameters());
    defer material.deinit();
    var hydrology = try SoilHydrology.init(allocator, profile, material, 1, retention.compatibilityParameters());
    defer hydrology.deinit();
    try std.testing.expect(hydrology.initial_water_fraction[0] > 0);
    try std.testing.expect(hydrology.initial_water_fraction[0] < hydrology.total_porosity_fraction[0]);
}

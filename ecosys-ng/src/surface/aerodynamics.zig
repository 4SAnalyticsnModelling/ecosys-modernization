const std = @import("std");
const CellRange = @import("../core/compute.zig").CellRange;

/// STARTS 93 and 654. These are source predicates, not nonlinear or
/// conservation tolerances.
pub const source_zero_bulk_density_megagrams_per_m3: f64 = 1.0e-15;
pub const snow_activation_heat_capacity_megajoules_per_m2_k: f64 =
    @import("../soil/solute/snow_solute_transport.zig").activation_heat_capacity_megajoules_per_m2_k;

pub const Parameters = struct {
    canopy_area_attenuation: f64,
    minimum_reference_height_above_displacement_m: f64,
    snow_roughness_height_m: f64,
    soil_roughness_height_m: f64,
    richardson_coefficient_k_m: f64,
    neutral_resistance_denominator: f64,
    minimum_wind_speed_m_per_h: f64,
    minimum_aerodynamic_resistance_h_per_m: f64,
    weather_height_includes_displacement: bool,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    zero_plane_displacement_m: []f64,
    effective_roughness_height_m: []f64,
    wind_reference_height_m: []f64,
    bulk_richardson_coefficient_k: []f64,
    isothermal_aerodynamic_resistance_h_per_m: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        initial_roughness_height_m: f64,
        initial_reference_height_m: f64,
    ) !State {
        if (cell_count == 0 or
            !std.math.isFinite(initial_roughness_height_m) or
            initial_roughness_height_m <= 0 or
            !std.math.isFinite(initial_reference_height_m) or
            initial_reference_height_m <= initial_roughness_height_m)
            return error.InvalidSurfaceAerodynamicInitialization;
        var arrays: [5][]f64 = undefined;
        var count: usize = 0;
        errdefer for (arrays[0..count]) |values| allocator.free(values);
        for (&arrays) |*values| {
            values.* = try allocator.alloc(f64, cell_count);
            @memset(values.*, 0);
            count += 1;
        }
        @memset(arrays[1], initial_roughness_height_m);
        @memset(arrays[2], initial_reference_height_m);
        @memset(arrays[4], 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .zero_plane_displacement_m = arrays[0], .effective_roughness_height_m = arrays[1], .wind_reference_height_m = arrays[2], .bulk_richardson_coefficient_k = arrays[3], .isothermal_aerodynamic_resistance_h_per_m = arrays[4] };
    }

    pub fn deinit(self: *State) void {
        inline for (.{ self.zero_plane_displacement_m, self.effective_roughness_height_m, self.wind_reference_height_m, self.bulk_richardson_coefficient_k, self.isothermal_aerodynamic_resistance_h_per_m }) |values| self.allocator.free(values);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    state: *State,
    cell_area_m2: []const f64,
    total_canopy_area_m2: []const f64,
    canopy_height_m: []const f64,
    snow_depth_m: []const f64,
    ground_surface_roughness_height_m: []const f64,
    weather_reference_height_m: []const f64,
    wind_speed_m_per_h: []const f64,
    parameters: Parameters,
};

/// HOUR1 `ARLSG/ZX/ZY/ZD/ZE/ZZ/ZR/RIBX/RABX` update. The previous hourly
/// roughness participates in displacement exactly as the source state does.
pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    const state = context.state;
    if (range.end > state.cell_count) return error.SurfaceAerodynamicRangeOutOfBounds;
    inline for (.{ context.cell_area_m2.len, context.total_canopy_area_m2.len, context.canopy_height_m.len, context.snow_depth_m.len, context.ground_surface_roughness_height_m.len, context.wind_speed_m_per_h.len }) |length| if (length != state.cell_count) return error.SurfaceAerodynamicDimensionMismatch;
    const p = context.parameters;
    inline for (.{ p.canopy_area_attenuation, p.minimum_reference_height_above_displacement_m, p.snow_roughness_height_m, p.soil_roughness_height_m, p.richardson_coefficient_k_m, p.neutral_resistance_denominator, p.minimum_wind_speed_m_per_h, p.minimum_aerodynamic_resistance_h_per_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceAerodynamicParameter;
    if (context.weather_reference_height_m.len != context.state.cell_count or p.canopy_area_attenuation <= 0 or p.minimum_reference_height_above_displacement_m <= 0 or p.snow_roughness_height_m <= 0 or p.soil_roughness_height_m <= 0 or p.richardson_coefficient_k_m < 0 or p.neutral_resistance_denominator <= 0 or p.minimum_wind_speed_m_per_h < 0 or p.minimum_aerodynamic_resistance_h_per_m <= 0) return error.InvalidSurfaceAerodynamicParameter;
    for (range.first..range.end) |cell| {
        inline for (.{ context.cell_area_m2[cell], context.total_canopy_area_m2[cell], context.canopy_height_m[cell], context.snow_depth_m[cell], context.ground_surface_roughness_height_m[cell], context.wind_speed_m_per_h[cell], state.effective_roughness_height_m[cell] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceAerodynamicInput;
        if (context.cell_area_m2[cell] <= 0 or context.total_canopy_area_m2[cell] < 0 or context.canopy_height_m[cell] < 0 or context.snow_depth_m[cell] < 0 or context.ground_surface_roughness_height_m[cell] <= 0 or context.wind_speed_m_per_h[cell] < 0 or state.effective_roughness_height_m[cell] <= 0) return error.InvalidSurfaceAerodynamicInput;
        const canopy_area_index = context.total_canopy_area_m2[cell] / context.cell_area_m2[cell];
        var displacement = state.effective_roughness_height_m[cell];
        var canopy_roughness: f64 = 0;
        if (canopy_area_index > 0 and context.canopy_height_m[cell] >= context.snow_depth_m[cell]) {
            const attenuation = std.math.exp(-p.canopy_area_attenuation * canopy_area_index);
            const intercepted = 1 - attenuation;
            displacement += context.canopy_height_m[cell] * @max(0, 1 - 2 / canopy_area_index * intercepted);
            canopy_roughness = context.canopy_height_m[cell] * @max(context.ground_surface_roughness_height_m[cell], attenuation * intercepted);
        }
        const weather_reference_height_m = context.weather_reference_height_m[cell];
        if (!std.math.isFinite(weather_reference_height_m) or weather_reference_height_m <= 0) return error.InvalidSurfaceAerodynamicParameter;
        const reference_height = if (p.weather_height_includes_displacement) weather_reference_height_m + displacement else @max(weather_reference_height_m, displacement + p.minimum_reference_height_above_displacement_m);
        const roughness = @max(canopy_roughness, context.ground_surface_roughness_height_m[cell]);
        const height_above_displacement = reference_height - displacement;
        if (height_above_displacement <= roughness) return error.InvalidAerodynamicReferenceGeometry;
        const wind = context.wind_speed_m_per_h[cell];
        const richardson = if (wind > p.minimum_wind_speed_m_per_h) p.richardson_coefficient_k_m * height_above_displacement / (wind * wind) else 0;
        const resistance = if (wind > p.minimum_wind_speed_m_per_h) blk: {
            const logarithm = @log(height_above_displacement / roughness);
            break :blk logarithm * logarithm / (p.neutral_resistance_denominator * wind);
        } else p.minimum_aerodynamic_resistance_h_per_m;
        inline for (.{ displacement, canopy_roughness, reference_height, roughness, richardson, resistance }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceAerodynamicResult;
        state.zero_plane_displacement_m[cell] = displacement;
        state.effective_roughness_height_m[cell] = roughness;
        state.wind_reference_height_m[cell] = reference_height;
        state.bulk_richardson_coefficient_k[cell] = richardson;
        state.isothermal_aerodynamic_resistance_h_per_m[cell] = @max(p.minimum_aerodynamic_resistance_h_per_m, resistance);
    }
}

/// HOUR1 2367--2371 `ZS`: water/zero-density surface or an active first snow
/// layer selects `ZSW`; otherwise the bare-soil `ZSX` is retained. A merely
/// positive geometric snow depth is not the source presence predicate.
pub fn sourceGroundSurfaceRoughnessHeightM(
    parameters: Parameters,
    surface_soil_bulk_density_megagrams_per_m3: f64,
    first_snow_layer_heat_capacity_megajoules_per_k: f64,
    cell_area_m2: f64,
) !f64 {
    inline for (.{
        parameters.snow_roughness_height_m,
        parameters.soil_roughness_height_m,
        surface_soil_bulk_density_megagrams_per_m3,
        first_snow_layer_heat_capacity_megajoules_per_k,
        cell_area_m2,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceAerodynamicInput;
    if (parameters.snow_roughness_height_m <= 0 or parameters.soil_roughness_height_m <= 0 or
        surface_soil_bulk_density_megagrams_per_m3 < 0 or
        first_snow_layer_heat_capacity_megajoules_per_k < 0 or cell_area_m2 <= 0)
        return error.InvalidSurfaceAerodynamicInput;
    const active_snow = first_snow_layer_heat_capacity_megajoules_per_k >
        snow_activation_heat_capacity_megajoules_per_m2_k * cell_area_m2;
    return if (surface_soil_bulk_density_megagrams_per_m3 < source_zero_bulk_density_megagrams_per_m3 or active_snow)
        parameters.snow_roughness_height_m
    else
        parameters.soil_roughness_height_m;
}

test "HOUR1 canopy roughness displacement RIBX and RABX" {
    var state = try State.init(std.testing.allocator, 1, 0.01, 2.01);
    defer state.deinit();
    var context: ApplyContext = .{ .state = &state, .cell_area_m2 = &.{10}, .total_canopy_area_m2 = &.{20}, .canopy_height_m = &.{2}, .snow_depth_m = &.{0}, .ground_surface_roughness_height_m = &.{0.01}, .weather_reference_height_m = &.{5}, .wind_speed_m_per_h = &.{3600}, .parameters = .{ .canopy_area_attenuation = 0.5, .minimum_reference_height_above_displacement_m = 2, .snow_roughness_height_m = 0.001, .soil_roughness_height_m = 0.01, .richardson_coefficient_k_m = 1.27e8, .neutral_resistance_denominator = 0.168, .minimum_wind_speed_m_per_h = 0, .minimum_aerodynamic_resistance_h_per_m = 1e-8, .weather_height_includes_displacement = false } };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const attenuation = @exp(-1.0);
    const displacement = 0.01 + 2 * (1 - (1 - attenuation));
    const roughness = 2 * @max(0.01, attenuation * (1 - attenuation));
    const height = 5 - displacement;
    try std.testing.expectApproxEqAbs(displacement, state.zero_plane_displacement_m[0], 1e-12);
    try std.testing.expectApproxEqAbs(roughness, state.effective_roughness_height_m[0], 1e-12);
    try std.testing.expectApproxEqAbs(1.27e8 * height / (3600.0 * 3600.0), state.bulk_richardson_coefficient_k[0], 1e-12);
    try std.testing.expectApproxEqAbs(@log(height / roughness) * @log(height / roughness) / (0.168 * 3600), state.isothermal_aerodynamic_resistance_h_per_m[0], 1e-12);
}

test "HOUR1 ZS uses snow heat capacity and zero-density surface, not snow depth" {
    const parameters: Parameters = .{
        .canopy_area_attenuation = 0.5,
        .minimum_reference_height_above_displacement_m = 2,
        .snow_roughness_height_m = 0.005,
        .soil_roughness_height_m = 0.025,
        .richardson_coefficient_k_m = 1.27e8,
        .neutral_resistance_denominator = 0.168,
        .minimum_wind_speed_m_per_h = 0,
        .minimum_aerodynamic_resistance_h_per_m = 1e-8,
        .weather_height_includes_displacement = false,
    };
    const area_m2: f64 = 10;
    const threshold = snow_activation_heat_capacity_megajoules_per_m2_k * area_m2;
    try std.testing.expectEqual(parameters.soil_roughness_height_m, try sourceGroundSurfaceRoughnessHeightM(parameters, 1.2, threshold, area_m2));
    try std.testing.expectEqual(parameters.snow_roughness_height_m, try sourceGroundSurfaceRoughnessHeightM(parameters, 1.2, threshold * 1.01, area_m2));
    try std.testing.expectEqual(parameters.snow_roughness_height_m, try sourceGroundSurfaceRoughnessHeightM(parameters, 0, 0, area_m2));
}

test "HOUR1 canopy ZE uses current ZS rather than fixed soil roughness" {
    var state = try State.init(std.testing.allocator, 1, 0.005, 5);
    defer state.deinit();
    var context: ApplyContext = .{
        .state = &state,
        .cell_area_m2 = &.{1},
        .total_canopy_area_m2 = &.{200},
        .canopy_height_m = &.{2},
        .snow_depth_m = &.{0},
        .ground_surface_roughness_height_m = &.{0.005},
        .weather_reference_height_m = &.{10},
        .wind_speed_m_per_h = &.{3600},
        .parameters = .{
            .canopy_area_attenuation = 0.5,
            .minimum_reference_height_above_displacement_m = 2,
            .snow_roughness_height_m = 0.005,
            .soil_roughness_height_m = 0.025,
            .richardson_coefficient_k_m = 1.27e8,
            .neutral_resistance_denominator = 0.168,
            .minimum_wind_speed_m_per_h = 0,
            .minimum_aerodynamic_resistance_h_per_m = 1e-8,
            .weather_height_includes_displacement = false,
        },
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const attenuation = @exp(-100.0);
    const expected_ze = 2.0 * @max(0.005, attenuation * (1.0 - attenuation));
    try std.testing.expectApproxEqAbs(expected_ze, state.effective_roughness_height_m[0], 1e-15);
    try std.testing.expect(state.effective_roughness_height_m[0] < 0.025);
}

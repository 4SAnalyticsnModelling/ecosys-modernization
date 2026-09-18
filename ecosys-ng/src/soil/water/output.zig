const std = @import("std");

/// Runtime-sized hourly soil-water diagnostics translated from OUTSH choices
/// 1..50. Layer profiles are no longer truncated to the source's 20 layers.
pub const HourlyDiagnostics = struct {
    allocator: std.mem.Allocator,
    evapotranspiration_mm: f64,
    runoff_mm: f64,
    sediment_discharge_water_mm: f64,
    root_water_uptake_mm: f64,
    external_water_outflow_mm: f64,
    surface_water_equivalent_mm: f64,
    volumetric_liquid_water_fraction_by_layer: []f64,
    surface_volumetric_liquid_water_fraction: f64,
    volumetric_ice_fraction_by_layer: []f64,
    surface_volumetric_ice_fraction: f64,
    active_layer_depth_below_surface_m: f64,
    water_table_depth_below_surface_m: f64,

    pub fn deinit(self: *HourlyDiagnostics) void {
        self.allocator.free(self.volumetric_liquid_water_fraction_by_layer);
        self.allocator.free(self.volumetric_ice_fraction_by_layer);
        self.* = undefined;
    }

    pub fn validateFinite(self: HourlyDiagnostics) !void {
        inline for (.{
            self.evapotranspiration_mm,
            self.runoff_mm,
            self.sediment_discharge_water_mm,
            self.root_water_uptake_mm,
            self.external_water_outflow_mm,
            self.surface_water_equivalent_mm,
            self.surface_volumetric_liquid_water_fraction,
            self.surface_volumetric_ice_fraction,
            self.active_layer_depth_below_surface_m,
            self.water_table_depth_below_surface_m,
        }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilWaterOutput;
        for (self.volumetric_liquid_water_fraction_by_layer) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilWaterOutput;
        for (self.volumetric_ice_fraction_by_layer) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilWaterOutput;
    }

    pub fn valueCount(self: HourlyDiagnostics) usize {
        return 10 + self.volumetric_liquid_water_fraction_by_layer.len + self.volumetric_ice_fraction_by_layer.len;
    }

    pub fn writeValues(self: HourlyDiagnostics, output: []f64) !void {
        if (output.len != self.valueCount()) return error.SoilWaterOutputValueDimensionMismatch;
        output[0..6].* = .{ self.evapotranspiration_mm, self.runoff_mm, self.sediment_discharge_water_mm, self.root_water_uptake_mm, self.external_water_outflow_mm, self.surface_water_equivalent_mm };
        var index: usize = 6;
        @memcpy(output[index..][0..self.volumetric_liquid_water_fraction_by_layer.len], self.volumetric_liquid_water_fraction_by_layer);
        index += self.volumetric_liquid_water_fraction_by_layer.len;
        output[index] = self.surface_volumetric_liquid_water_fraction;
        index += 1;
        @memcpy(output[index..][0..self.volumetric_ice_fraction_by_layer.len], self.volumetric_ice_fraction_by_layer);
        index += self.volumetric_ice_fraction_by_layer.len;
        output[index..][0..3].* = .{ self.surface_volumetric_ice_fraction, self.active_layer_depth_below_surface_m, self.water_table_depth_below_surface_m };
    }
};

pub const Inputs = struct {
    evapotranspiration_m3: f64,
    runoff_m3: f64,
    sediment_discharge_water_m3: f64,
    root_water_uptake_m3: f64,
    external_water_outflow_m3: f64,
    surface_snow_volume_m3: f64,
    surface_ice_volume_m3: f64,
    surface_liquid_water_m3: f64,
    ice_density_megagrams_per_m3: f64,
    local_surface_area_m2: f64,
    total_grid_area_m2: f64,
    volumetric_liquid_water_fraction_by_layer: []const f64,
    surface_volumetric_liquid_water_fraction: f64,
    volumetric_ice_fraction_by_layer: []const f64,
    surface_volumetric_ice_fraction: f64,
    active_layer_boundary_depth_m: f64,
    water_table_boundary_depth_m: f64,
    soil_surface_reference_depth_m: f64,
};

/// Projects one cell directly into its caller-owned output row. This is the
/// hot-path form used by long simulations: it performs no allocation and
/// preserves the catalog ordering produced by `soil_output_catalog.water`.
pub fn calculateInto(inputs: Inputs, output: []f64) !void {
    const layer_count = inputs.volumetric_liquid_water_fraction_by_layer.len;
    if (layer_count != inputs.volumetric_ice_fraction_by_layer.len) return error.SoilWaterOutputLayerDimensionMismatch;
    if (output.len != 10 + 2 * layer_count) return error.SoilWaterOutputValueDimensionMismatch;
    if (!std.math.isFinite(inputs.local_surface_area_m2) or inputs.local_surface_area_m2 <= 0 or !std.math.isFinite(inputs.total_grid_area_m2) or inputs.total_grid_area_m2 <= 0 or !std.math.isFinite(inputs.ice_density_megagrams_per_m3) or inputs.ice_density_megagrams_per_m3 <= 0) return error.InvalidSoilWaterOutputGeometry;
    inline for (.{ inputs.evapotranspiration_m3, inputs.runoff_m3, inputs.sediment_discharge_water_m3, inputs.root_water_uptake_m3, inputs.external_water_outflow_m3, inputs.surface_snow_volume_m3, inputs.surface_ice_volume_m3, inputs.surface_liquid_water_m3, inputs.surface_volumetric_liquid_water_fraction, inputs.surface_volumetric_ice_fraction, inputs.active_layer_boundary_depth_m, inputs.water_table_boundary_depth_m, inputs.soil_surface_reference_depth_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilWaterOutputInput;
    for (inputs.volumetric_liquid_water_fraction_by_layer, inputs.volumetric_ice_fraction_by_layer) |liquid_fraction, ice_fraction| {
        if (!std.math.isFinite(liquid_fraction) or !std.math.isFinite(ice_fraction)) return error.NonFiniteSoilWaterOutputInput;
    }

    output[0..6].* = .{
        inputs.evapotranspiration_m3 * 1000.0 / inputs.local_surface_area_m2,
        -inputs.runoff_m3 * 1000.0 / inputs.total_grid_area_m2,
        inputs.sediment_discharge_water_m3 * 1000.0 / inputs.total_grid_area_m2,
        inputs.root_water_uptake_m3 * 1000.0 / inputs.local_surface_area_m2,
        inputs.external_water_outflow_m3 * 1000.0 / inputs.total_grid_area_m2,
        @max(0.0, (inputs.surface_snow_volume_m3 + inputs.surface_ice_volume_m3 * inputs.ice_density_megagrams_per_m3 + inputs.surface_liquid_water_m3) * 1000.0 / inputs.local_surface_area_m2),
    };
    var index: usize = 6;
    for (output[index..][0..layer_count], inputs.volumetric_liquid_water_fraction_by_layer) |*destination, source| destination.* = source;
    index += layer_count;
    output[index] = inputs.surface_volumetric_liquid_water_fraction;
    index += 1;
    for (output[index..][0..layer_count], inputs.volumetric_ice_fraction_by_layer) |*destination, source| destination.* = source;
    index += layer_count;
    output[index..][0..3].* = .{
        inputs.surface_volumetric_ice_fraction,
        inputs.soil_surface_reference_depth_m - inputs.active_layer_boundary_depth_m,
        inputs.soil_surface_reference_depth_m - inputs.water_table_boundary_depth_m,
    };
    for (output) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilWaterOutput;
}

pub fn calculate(allocator: std.mem.Allocator, inputs: Inputs) !HourlyDiagnostics {
    if (inputs.volumetric_liquid_water_fraction_by_layer.len != inputs.volumetric_ice_fraction_by_layer.len) return error.SoilWaterOutputLayerDimensionMismatch;
    if (!std.math.isFinite(inputs.local_surface_area_m2) or inputs.local_surface_area_m2 <= 0 or !std.math.isFinite(inputs.total_grid_area_m2) or inputs.total_grid_area_m2 <= 0 or !std.math.isFinite(inputs.ice_density_megagrams_per_m3) or inputs.ice_density_megagrams_per_m3 <= 0) return error.InvalidSoilWaterOutputGeometry;
    inline for (.{ inputs.evapotranspiration_m3, inputs.runoff_m3, inputs.sediment_discharge_water_m3, inputs.root_water_uptake_m3, inputs.external_water_outflow_m3, inputs.surface_snow_volume_m3, inputs.surface_ice_volume_m3, inputs.surface_liquid_water_m3, inputs.surface_volumetric_liquid_water_fraction, inputs.surface_volumetric_ice_fraction, inputs.active_layer_boundary_depth_m, inputs.water_table_boundary_depth_m, inputs.soil_surface_reference_depth_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilWaterOutputInput;

    const liquid = try allocator.dupe(f64, inputs.volumetric_liquid_water_fraction_by_layer);
    errdefer allocator.free(liquid);
    const ice = try allocator.dupe(f64, inputs.volumetric_ice_fraction_by_layer);
    errdefer allocator.free(ice);
    for (liquid, ice) |liquid_fraction, ice_fraction| {
        if (!std.math.isFinite(liquid_fraction) or !std.math.isFinite(ice_fraction)) return error.NonFiniteSoilWaterOutputInput;
    }

    var result: HourlyDiagnostics = .{
        .allocator = allocator,
        .evapotranspiration_mm = inputs.evapotranspiration_m3 * 1000.0 / inputs.local_surface_area_m2,
        .runoff_mm = -inputs.runoff_m3 * 1000.0 / inputs.total_grid_area_m2,
        .sediment_discharge_water_mm = inputs.sediment_discharge_water_m3 * 1000.0 / inputs.total_grid_area_m2,
        .root_water_uptake_mm = inputs.root_water_uptake_m3 * 1000.0 / inputs.local_surface_area_m2,
        .external_water_outflow_mm = inputs.external_water_outflow_m3 * 1000.0 / inputs.total_grid_area_m2,
        .surface_water_equivalent_mm = @max(0.0, (inputs.surface_snow_volume_m3 + inputs.surface_ice_volume_m3 * inputs.ice_density_megagrams_per_m3 + inputs.surface_liquid_water_m3) * 1000.0 / inputs.local_surface_area_m2),
        .volumetric_liquid_water_fraction_by_layer = liquid,
        .surface_volumetric_liquid_water_fraction = inputs.surface_volumetric_liquid_water_fraction,
        .volumetric_ice_fraction_by_layer = ice,
        .surface_volumetric_ice_fraction = inputs.surface_volumetric_ice_fraction,
        .active_layer_depth_below_surface_m = inputs.soil_surface_reference_depth_m - inputs.active_layer_boundary_depth_m,
        .water_table_depth_below_surface_m = inputs.soil_surface_reference_depth_m - inputs.water_table_boundary_depth_m,
    };
    try result.validateFinite();
    return result;
}

test "allocation-free soil-water projection matches owned diagnostics" {
    const liquid = [_]f64{ 0.2, 0.3 };
    const ice = [_]f64{ 0.01, 0.02 };
    const inputs: Inputs = .{
        .evapotranspiration_m3 = 0.4,
        .runoff_m3 = -0.2,
        .sediment_discharge_water_m3 = 0.1,
        .root_water_uptake_m3 = 0.3,
        .external_water_outflow_m3 = 0.05,
        .surface_snow_volume_m3 = 0.01,
        .surface_ice_volume_m3 = 0.02,
        .surface_liquid_water_m3 = 0.03,
        .ice_density_megagrams_per_m3 = 0.917,
        .local_surface_area_m2 = 100,
        .total_grid_area_m2 = 200,
        .volumetric_liquid_water_fraction_by_layer = &liquid,
        .surface_volumetric_liquid_water_fraction = 0.4,
        .volumetric_ice_fraction_by_layer = &ice,
        .surface_volumetric_ice_fraction = 0.05,
        .active_layer_boundary_depth_m = 1.2,
        .water_table_boundary_depth_m = 2.1,
        .soil_surface_reference_depth_m = 0.2,
    };
    var owned = try calculate(std.testing.allocator, inputs);
    defer owned.deinit();
    var expected: [14]f64 = undefined;
    var actual: [14]f64 = undefined;
    try owned.writeValues(&expected);
    try calculateInto(inputs, &actual);
    try std.testing.expectEqualSlices(f64, &expected, &actual);
}

test "allocation-free soil-water projection supports in-place profile workspace" {
    var row = [_]f64{0} ** 14;
    row[6..8].* = .{ 0.2, 0.3 };
    row[9..11].* = .{ 0.01, 0.02 };
    try calculateInto(.{
        .evapotranspiration_m3 = 0,
        .runoff_m3 = 0,
        .sediment_discharge_water_m3 = 0,
        .root_water_uptake_m3 = 0,
        .external_water_outflow_m3 = 0,
        .surface_snow_volume_m3 = 0,
        .surface_ice_volume_m3 = 0,
        .surface_liquid_water_m3 = 0,
        .ice_density_megagrams_per_m3 = 0.917,
        .local_surface_area_m2 = 1,
        .total_grid_area_m2 = 1,
        .volumetric_liquid_water_fraction_by_layer = row[6..8],
        .surface_volumetric_liquid_water_fraction = 0.4,
        .volumetric_ice_fraction_by_layer = row[9..11],
        .surface_volumetric_ice_fraction = 0.05,
        .active_layer_boundary_depth_m = -1,
        .water_table_boundary_depth_m = -2,
        .soil_surface_reference_depth_m = 0,
    }, &row);
    try std.testing.expectEqualSlices(f64, &.{ 0.2, 0.3 }, row[6..8]);
    try std.testing.expectEqualSlices(f64, &.{ 0.01, 0.02 }, row[9..11]);
}

test "OUTSH hourly soil-water equations retain signs units and runtime layers" {
    const layer_count = 23;
    var liquid: [layer_count]f64 = undefined;
    var ice: [layer_count]f64 = undefined;
    for (&liquid, &ice, 0..) |*liquid_fraction, *ice_fraction, layer| {
        liquid_fraction.* = 0.1 + 0.001 * @as(f64, @floatFromInt(layer));
        ice_fraction.* = 0.02 + 0.001 * @as(f64, @floatFromInt(layer));
    }
    var output = try calculate(std.testing.allocator, .{
        .evapotranspiration_m3 = 0.4,
        .runoff_m3 = -0.2,
        .sediment_discharge_water_m3 = 0.1,
        .root_water_uptake_m3 = 0.3,
        .external_water_outflow_m3 = 0.05,
        .surface_snow_volume_m3 = 0.01,
        .surface_ice_volume_m3 = 0.02,
        .surface_liquid_water_m3 = 0.03,
        .ice_density_megagrams_per_m3 = 0.917,
        .local_surface_area_m2 = 100,
        .total_grid_area_m2 = 200,
        .volumetric_liquid_water_fraction_by_layer = &liquid,
        .surface_volumetric_liquid_water_fraction = 0.4,
        .volumetric_ice_fraction_by_layer = &ice,
        .surface_volumetric_ice_fraction = 0.05,
        .active_layer_boundary_depth_m = 1.2,
        .water_table_boundary_depth_m = 2.1,
        .soil_surface_reference_depth_m = 0.2,
    });
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 23), output.volumetric_liquid_water_fraction_by_layer.len);
    try std.testing.expectEqual(@as(usize, 56), output.valueCount());
    try std.testing.expectApproxEqAbs(@as(f64, 4), output.evapotranspiration_mm, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), output.runoff_mm, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), output.root_water_uptake_mm, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -1), output.active_layer_depth_below_surface_m, 1e-15);
    try std.testing.expectApproxEqAbs((0.01 + 0.02 * 0.917 + 0.03) * 10, output.surface_water_equivalent_mm, 1e-15);
    var values: [56]f64 = undefined;
    try output.writeValues(&values);
    try std.testing.expectEqual(@as(f64, 4), values[0]);
    try std.testing.expectEqual(@as(f64, 0.4), values[29]);
    try std.testing.expectEqual(@as(f64, 0.05), values[53]);
    try std.testing.expectEqual(@as(f64, -1), values[54]);
}

test "soil-water output rejects mismatched runtime profiles" {
    try std.testing.expectError(error.SoilWaterOutputLayerDimensionMismatch, calculate(std.testing.allocator, .{
        .evapotranspiration_m3 = 0,
        .runoff_m3 = 0,
        .sediment_discharge_water_m3 = 0,
        .root_water_uptake_m3 = 0,
        .external_water_outflow_m3 = 0,
        .surface_snow_volume_m3 = 0,
        .surface_ice_volume_m3 = 0,
        .surface_liquid_water_m3 = 0,
        .ice_density_megagrams_per_m3 = 0.917,
        .local_surface_area_m2 = 1,
        .total_grid_area_m2 = 1,
        .volumetric_liquid_water_fraction_by_layer = &.{0.1},
        .surface_volumetric_liquid_water_fraction = 0,
        .volumetric_ice_fraction_by_layer = &.{},
        .surface_volumetric_ice_fraction = 0,
        .active_layer_boundary_depth_m = 0,
        .water_table_boundary_depth_m = 0,
        .soil_surface_reference_depth_m = 0,
    }));
}

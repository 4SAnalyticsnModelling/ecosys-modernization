const std = @import("std");

// The WATSUB vapor conversion coefficient maps vapor partial pressure to the
// equivalent liquid-water volume fraction: volume_fraction = P * C / T.
// Multiplying that fraction by liquid-water density publishes vapor density in
// g m-3. This is the ideal-gas form rho = P / (R_v * T), with the historical
// ecosys coefficient implying R_v = 1 / (C * 1000) kPa m3 kg-1 K-1.
const vapor_fraction_conversion_k_per_kpa = 2.173e-3;
const liquid_water_density_g_per_m3 = 1.0e6;

fn litterWaterVaporDensityGPerM3(partial_pressure_kpa: f64, absolute_temperature_k: f64) f64 {
    return partial_pressure_kpa * vapor_fraction_conversion_k_per_kpa /
        absolute_temperature_k * liquid_water_density_g_per_m3;
}

/// Hourly OUTSH soil-heat diagnostics. Temperature profiles use the active
/// runtime layer count instead of the historical twenty-layer output ceiling.
pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    incoming_shortwave_radiation_w_per_m2: f64,
    air_temperature_c: f64,
    atmospheric_vapor_pressure_kpa: f64,
    wind_speed_m_per_s: f64,
    rain_and_irrigation_mm: f64,
    ground_surface_net_radiation_w_per_m2: f64,
    ground_surface_latent_heat_flux_w_per_m2: f64,
    ground_surface_sensible_heat_flux_w_per_m2: f64,
    ground_surface_storage_heat_flux_w_per_m2: f64,
    ecosystem_net_radiation_w_per_m2: f64,
    ecosystem_latent_heat_flux_w_per_m2: f64,
    ecosystem_sensible_heat_flux_w_per_m2: f64,
    ecosystem_storage_heat_flux_w_per_m2: f64,
    soil_temperature_c_by_layer: []f64,
    surface_soil_temperature_c: f64,
    surface_water_temperature_c: f64,
    litter_temperature_c: f64,
    litter_water_vapor_density_g_per_m3: f64,

    pub fn deinit(self: *Diagnostics) void {
        self.allocator.free(self.soil_temperature_c_by_layer);
        self.* = undefined;
    }

    pub fn valueCount(self: Diagnostics) usize {
        return 17 + self.soil_temperature_c_by_layer.len;
    }

    pub fn writeValues(self: Diagnostics, output: []f64) !void {
        if (output.len != self.valueCount()) return error.SoilHeatOutputValueDimensionMismatch;
        output[0..13].* = .{ self.incoming_shortwave_radiation_w_per_m2, self.air_temperature_c, self.atmospheric_vapor_pressure_kpa, self.wind_speed_m_per_s, self.rain_and_irrigation_mm, self.ground_surface_net_radiation_w_per_m2, self.ground_surface_latent_heat_flux_w_per_m2, self.ground_surface_sensible_heat_flux_w_per_m2, self.ground_surface_storage_heat_flux_w_per_m2, self.ecosystem_net_radiation_w_per_m2, self.ecosystem_latent_heat_flux_w_per_m2, self.ecosystem_sensible_heat_flux_w_per_m2, self.ecosystem_storage_heat_flux_w_per_m2 };
        @memcpy(output[13..][0..self.soil_temperature_c_by_layer.len], self.soil_temperature_c_by_layer);
        const index = 13 + self.soil_temperature_c_by_layer.len;
        output[index..][0..4].* = .{ self.surface_soil_temperature_c, self.surface_water_temperature_c, self.litter_temperature_c, self.litter_water_vapor_density_g_per_m3 };
    }
};

pub const Inputs = struct {
    incoming_shortwave_radiation_megajoules_per_m2_h: f64,
    air_temperature_c: f64,
    atmospheric_vapor_pressure_kpa: f64,
    wind_travel_m_per_h: f64,
    rainfall_m3: f64,
    irrigation_m3: f64,
    local_surface_area_m2: f64,
    ground_surface_net_radiation_megajoules: f64,
    ground_surface_latent_heat_megajoules: f64,
    ground_surface_sensible_heat_megajoules: f64,
    ground_surface_storage_heat_megajoules: f64,
    ecosystem_net_radiation_megajoules: f64,
    ecosystem_latent_heat_megajoules: f64,
    ecosystem_sensible_heat_megajoules: f64,
    ecosystem_storage_heat_megajoules: f64,
    soil_temperature_c_by_layer: []const f64,
    surface_soil_temperature_c: f64,
    surface_water_temperature_c: f64,
    litter_temperature_c: f64,
    litter_water_vapor_partial_pressure_kpa: f64,
    litter_absolute_temperature_k: f64,
};

/// Allocation-free hot-path projection in the exact hourly heat catalog order.
pub fn calculateInto(inputs: Inputs, output: []f64) !void {
    if (output.len != 17 + inputs.soil_temperature_c_by_layer.len) return error.SoilHeatOutputValueDimensionMismatch;
    if (!std.math.isFinite(inputs.local_surface_area_m2) or inputs.local_surface_area_m2 <= 0 or !std.math.isFinite(inputs.litter_absolute_temperature_k) or inputs.litter_absolute_temperature_k <= 0) return error.InvalidSoilHeatOutputGeometry;
    inline for (.{ inputs.incoming_shortwave_radiation_megajoules_per_m2_h, inputs.air_temperature_c, inputs.atmospheric_vapor_pressure_kpa, inputs.wind_travel_m_per_h, inputs.rainfall_m3, inputs.irrigation_m3, inputs.ground_surface_net_radiation_megajoules, inputs.ground_surface_latent_heat_megajoules, inputs.ground_surface_sensible_heat_megajoules, inputs.ground_surface_storage_heat_megajoules, inputs.ecosystem_net_radiation_megajoules, inputs.ecosystem_latent_heat_megajoules, inputs.ecosystem_sensible_heat_megajoules, inputs.ecosystem_storage_heat_megajoules, inputs.surface_soil_temperature_c, inputs.surface_water_temperature_c, inputs.litter_temperature_c, inputs.litter_water_vapor_partial_pressure_kpa }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilHeatOutputInput;
    for (inputs.soil_temperature_c_by_layer) |temperature_c| if (!std.math.isFinite(temperature_c)) return error.NonFiniteSoilHeatOutputInput;

    const watts_per_megajoule_per_h = 277.8;
    const area = inputs.local_surface_area_m2;
    output[0..13].* = .{
        inputs.incoming_shortwave_radiation_megajoules_per_m2_h * watts_per_megajoule_per_h,
        inputs.air_temperature_c,
        inputs.atmospheric_vapor_pressure_kpa,
        inputs.wind_travel_m_per_h / 3600.0,
        (inputs.rainfall_m3 + inputs.irrigation_m3) * 1000.0 / area,
        inputs.ground_surface_net_radiation_megajoules * watts_per_megajoule_per_h / area,
        inputs.ground_surface_latent_heat_megajoules * watts_per_megajoule_per_h / area,
        inputs.ground_surface_sensible_heat_megajoules * watts_per_megajoule_per_h / area,
        inputs.ground_surface_storage_heat_megajoules * watts_per_megajoule_per_h / area,
        inputs.ecosystem_net_radiation_megajoules * watts_per_megajoule_per_h / area,
        inputs.ecosystem_latent_heat_megajoules * watts_per_megajoule_per_h / area,
        inputs.ecosystem_sensible_heat_megajoules * watts_per_megajoule_per_h / area,
        inputs.ecosystem_storage_heat_megajoules * watts_per_megajoule_per_h / area,
    };
    for (output[13..][0..inputs.soil_temperature_c_by_layer.len], inputs.soil_temperature_c_by_layer) |*destination, source| destination.* = source;
    const index = 13 + inputs.soil_temperature_c_by_layer.len;
    output[index..][0..4].* = .{
        inputs.surface_soil_temperature_c,
        inputs.surface_water_temperature_c,
        inputs.litter_temperature_c,
        litterWaterVaporDensityGPerM3(
            inputs.litter_water_vapor_partial_pressure_kpa,
            inputs.litter_absolute_temperature_k,
        ),
    };
    for (output) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilHeatOutput;
}

pub fn calculate(allocator: std.mem.Allocator, inputs: Inputs) !Diagnostics {
    if (!std.math.isFinite(inputs.local_surface_area_m2) or inputs.local_surface_area_m2 <= 0 or !std.math.isFinite(inputs.litter_absolute_temperature_k) or inputs.litter_absolute_temperature_k <= 0) return error.InvalidSoilHeatOutputGeometry;
    inline for (.{ inputs.incoming_shortwave_radiation_megajoules_per_m2_h, inputs.air_temperature_c, inputs.atmospheric_vapor_pressure_kpa, inputs.wind_travel_m_per_h, inputs.rainfall_m3, inputs.irrigation_m3, inputs.ground_surface_net_radiation_megajoules, inputs.ground_surface_latent_heat_megajoules, inputs.ground_surface_sensible_heat_megajoules, inputs.ground_surface_storage_heat_megajoules, inputs.ecosystem_net_radiation_megajoules, inputs.ecosystem_latent_heat_megajoules, inputs.ecosystem_sensible_heat_megajoules, inputs.ecosystem_storage_heat_megajoules, inputs.surface_soil_temperature_c, inputs.surface_water_temperature_c, inputs.litter_temperature_c, inputs.litter_water_vapor_partial_pressure_kpa }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilHeatOutputInput;
    const temperatures = try allocator.dupe(f64, inputs.soil_temperature_c_by_layer);
    errdefer allocator.free(temperatures);
    for (temperatures) |temperature_c| if (!std.math.isFinite(temperature_c)) return error.NonFiniteSoilHeatOutputInput;

    // OUTSH uses 277.8 = 1e6 J MJ-1 / 3600 s h-1.
    const watts_per_megajoule_per_h = 277.8;
    const area = inputs.local_surface_area_m2;
    return .{
        .allocator = allocator,
        .incoming_shortwave_radiation_w_per_m2 = inputs.incoming_shortwave_radiation_megajoules_per_m2_h * watts_per_megajoule_per_h,
        .air_temperature_c = inputs.air_temperature_c,
        .atmospheric_vapor_pressure_kpa = inputs.atmospheric_vapor_pressure_kpa,
        .wind_speed_m_per_s = inputs.wind_travel_m_per_h / 3600.0,
        .rain_and_irrigation_mm = (inputs.rainfall_m3 + inputs.irrigation_m3) * 1000.0 / area,
        .ground_surface_net_radiation_w_per_m2 = inputs.ground_surface_net_radiation_megajoules * watts_per_megajoule_per_h / area,
        .ground_surface_latent_heat_flux_w_per_m2 = inputs.ground_surface_latent_heat_megajoules * watts_per_megajoule_per_h / area,
        .ground_surface_sensible_heat_flux_w_per_m2 = inputs.ground_surface_sensible_heat_megajoules * watts_per_megajoule_per_h / area,
        .ground_surface_storage_heat_flux_w_per_m2 = inputs.ground_surface_storage_heat_megajoules * watts_per_megajoule_per_h / area,
        .ecosystem_net_radiation_w_per_m2 = inputs.ecosystem_net_radiation_megajoules * watts_per_megajoule_per_h / area,
        .ecosystem_latent_heat_flux_w_per_m2 = inputs.ecosystem_latent_heat_megajoules * watts_per_megajoule_per_h / area,
        .ecosystem_sensible_heat_flux_w_per_m2 = inputs.ecosystem_sensible_heat_megajoules * watts_per_megajoule_per_h / area,
        .ecosystem_storage_heat_flux_w_per_m2 = inputs.ecosystem_storage_heat_megajoules * watts_per_megajoule_per_h / area,
        .soil_temperature_c_by_layer = temperatures,
        .surface_soil_temperature_c = inputs.surface_soil_temperature_c,
        .surface_water_temperature_c = inputs.surface_water_temperature_c,
        .litter_temperature_c = inputs.litter_temperature_c,
        .litter_water_vapor_density_g_per_m3 = litterWaterVaporDensityGPerM3(
            inputs.litter_water_vapor_partial_pressure_kpa,
            inputs.litter_absolute_temperature_k,
        ),
    };
}

test "allocation-free soil-heat projection matches owned diagnostics" {
    const temperatures = [_]f64{ 2, 4, 6 };
    const inputs: Inputs = .{
        .incoming_shortwave_radiation_megajoules_per_m2_h = 2,
        .air_temperature_c = 12,
        .atmospheric_vapor_pressure_kpa = 1.1,
        .wind_travel_m_per_h = 7200,
        .rainfall_m3 = 0.1,
        .irrigation_m3 = 0.2,
        .local_surface_area_m2 = 100,
        .ground_surface_net_radiation_megajoules = 1,
        .ground_surface_latent_heat_megajoules = 2,
        .ground_surface_sensible_heat_megajoules = 3,
        .ground_surface_storage_heat_megajoules = 4,
        .ecosystem_net_radiation_megajoules = 5,
        .ecosystem_latent_heat_megajoules = 6,
        .ecosystem_sensible_heat_megajoules = 7,
        .ecosystem_storage_heat_megajoules = 8,
        .soil_temperature_c_by_layer = &temperatures,
        .surface_soil_temperature_c = 3,
        .surface_water_temperature_c = 4,
        .litter_temperature_c = 5,
        .litter_water_vapor_partial_pressure_kpa = 0.001,
        .litter_absolute_temperature_k = 280,
    };
    var owned = try calculate(std.testing.allocator, inputs);
    defer owned.deinit();
    var expected: [20]f64 = undefined;
    var actual: [20]f64 = undefined;
    try owned.writeValues(&expected);
    try calculateInto(inputs, &actual);
    try std.testing.expectEqualSlices(f64, &expected, &actual);
}

test "OUTSH hourly soil-heat equations preserve conversions and runtime layers" {
    const temperatures = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 };
    var output = try calculate(std.testing.allocator, .{
        .incoming_shortwave_radiation_megajoules_per_m2_h = 2,
        .air_temperature_c = 12,
        .atmospheric_vapor_pressure_kpa = 1.1,
        .wind_travel_m_per_h = 7200,
        .rainfall_m3 = 0.1,
        .irrigation_m3 = 0.2,
        .local_surface_area_m2 = 100,
        .ground_surface_net_radiation_megajoules = 1,
        .ground_surface_latent_heat_megajoules = 2,
        .ground_surface_sensible_heat_megajoules = 3,
        .ground_surface_storage_heat_megajoules = 4,
        .ecosystem_net_radiation_megajoules = 5,
        .ecosystem_latent_heat_megajoules = 6,
        .ecosystem_sensible_heat_megajoules = 7,
        .ecosystem_storage_heat_megajoules = 8,
        .soil_temperature_c_by_layer = &temperatures,
        .surface_soil_temperature_c = 3,
        .surface_water_temperature_c = 4,
        .litter_temperature_c = 5,
        .litter_water_vapor_partial_pressure_kpa = 0.001,
        .litter_absolute_temperature_k = 280,
    });
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 23), output.soil_temperature_c_by_layer.len);
    try std.testing.expectEqual(@as(usize, 40), output.valueCount());
    try std.testing.expectApproxEqAbs(@as(f64, 555.6), output.incoming_shortwave_radiation_w_per_m2, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), output.wind_speed_m_per_s, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), output.rain_and_irrigation_mm, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 5) * 277.8 / 100.0, output.ecosystem_net_radiation_w_per_m2, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001) * 2.173e-3 / 280.0 * 1.0e6, output.litter_water_vapor_density_g_per_m3, 1e-12);
    var values: [40]f64 = undefined;
    try output.writeValues(&values);
    try std.testing.expectEqual(@as(f64, 1), values[13]);
    try std.testing.expectEqual(@as(f64, 3), values[36]);
    try std.testing.expectEqual(@as(f64, 4), values[37]);
}

test "litter vapor density preserves ideal-gas pressure-temperature provenance" {
    const partial_pressure_kpa = 1.25;
    const absolute_temperature_k = 280.0;
    const implied_specific_gas_constant_kpa_m3_per_kg_k =
        1.0 / (vapor_fraction_conversion_k_per_kpa * 1000.0);
    const ideal_gas_density_g_per_m3 = partial_pressure_kpa /
        (implied_specific_gas_constant_kpa_m3_per_kg_k * absolute_temperature_k) *
        1000.0;

    try std.testing.expectApproxEqAbs(
        ideal_gas_density_g_per_m3,
        litterWaterVaporDensityGPerM3(partial_pressure_kpa, absolute_temperature_k),
        8 * std.math.floatEps(f64) * ideal_gas_density_g_per_m3,
    );
    try std.testing.expectEqual(
        litterWaterVaporDensityGPerM3(partial_pressure_kpa, absolute_temperature_k) / 2.0,
        litterWaterVaporDensityGPerM3(partial_pressure_kpa, 2.0 * absolute_temperature_k),
    );
}

const std = @import("std");

pub const Carbon = struct {
    canopy_carbon_dioxide_flux_umol_per_m2_s: f64,
    gross_primary_productivity_g_c_per_m2_h: f64,
    signed_aboveground_respiration_g_c_per_m2_h: f64,
    nonstructural_carbon_concentration: f64,
    stomatal_resistance_s_per_m: f64,
    boundary_layer_resistance_s_per_m: f64,
    leaf_area_index: f64,

    pub fn values(self: Carbon) [7]f64 {
        return .{ self.canopy_carbon_dioxide_flux_umol_per_m2_s, self.gross_primary_productivity_g_c_per_m2_h, self.signed_aboveground_respiration_g_c_per_m2_h, self.nonstructural_carbon_concentration, self.stomatal_resistance_s_per_m, self.boundary_layer_resistance_s_per_m, self.leaf_area_index };
    }
};

pub fn carbon(net_co2_g_c_per_h: f64, gross_primary_productivity_g_c_per_h: f64, signed_aboveground_respiration_g_c_per_h: f64, nonstructural_carbon_concentration: f64, canopy_stomatal_resistance_h_per_m: f64, canopy_boundary_resistance_h_per_m: f64, leaf_area_m2: f64, cell_area_m2: f64) !Carbon {
    try validateArea(cell_area_m2);
    inline for (.{ net_co2_g_c_per_h, gross_primary_productivity_g_c_per_h, signed_aboveground_respiration_g_c_per_h, nonstructural_carbon_concentration, canopy_stomatal_resistance_h_per_m, canopy_boundary_resistance_h_per_m, leaf_area_m2 }) |value| try finite(value);
    return .{
        .canopy_carbon_dioxide_flux_umol_per_m2_s = net_co2_g_c_per_h / cell_area_m2 * 23.148,
        .gross_primary_productivity_g_c_per_m2_h = gross_primary_productivity_g_c_per_h / cell_area_m2,
        .signed_aboveground_respiration_g_c_per_m2_h = signed_aboveground_respiration_g_c_per_h / cell_area_m2,
        .nonstructural_carbon_concentration = nonstructural_carbon_concentration,
        .stomatal_resistance_s_per_m = canopy_stomatal_resistance_h_per_m * 1.56 * 3600.0,
        .boundary_layer_resistance_s_per_m = canopy_boundary_resistance_h_per_m * 1.34 * 3600.0,
        .leaf_area_index = leaf_area_m2 / cell_area_m2,
    };
}

pub const Water = struct {
    allocator: std.mem.Allocator,
    canopy_total_water_potential_megapascal: f64,
    canopy_turgor_potential_megapascal: f64,
    stomatal_resistance_s_per_m: f64,
    boundary_layer_resistance_s_per_m: f64,
    transpiration_mm: f64,
    oxygen_stress_factor: f64,
    primary_root_total_water_potential_mpa_by_layer: []f64,

    pub fn deinit(self: *Water) void {
        self.allocator.free(self.primary_root_total_water_potential_mpa_by_layer);
        self.* = undefined;
    }

    pub fn valueCount(self: Water) usize {
        return 6 + self.primary_root_total_water_potential_mpa_by_layer.len;
    }

    pub fn writeValues(self: Water, output: []f64) !void {
        if (output.len != self.valueCount()) return error.PlantWaterOutputValueDimensionMismatch;
        output[0..6].* = .{ self.canopy_total_water_potential_megapascal, self.canopy_turgor_potential_megapascal, self.stomatal_resistance_s_per_m, self.boundary_layer_resistance_s_per_m, self.transpiration_mm, self.oxygen_stress_factor };
        @memcpy(output[6..], self.primary_root_total_water_potential_mpa_by_layer);
    }
};

pub fn water(allocator: std.mem.Allocator, canopy_total_water_potential_megapascal: f64, canopy_turgor_potential_megapascal: f64, stomatal_resistance_h_per_m: f64, boundary_resistance_h_per_m: f64, transpiration_m3: f64, oxygen_stress_factor: f64, primary_root_total_water_potential_mpa_by_layer: []const f64, cell_area_m2: f64) !Water {
    try validateArea(cell_area_m2);
    inline for (.{ canopy_total_water_potential_megapascal, canopy_turgor_potential_megapascal, stomatal_resistance_h_per_m, boundary_resistance_h_per_m, transpiration_m3, oxygen_stress_factor }) |value| try finite(value);
    const roots = try duplicateFinite(allocator, primary_root_total_water_potential_mpa_by_layer);
    return .{ .allocator = allocator, .canopy_total_water_potential_megapascal = canopy_total_water_potential_megapascal, .canopy_turgor_potential_megapascal = canopy_turgor_potential_megapascal, .stomatal_resistance_s_per_m = stomatal_resistance_h_per_m * 3600.0, .boundary_layer_resistance_s_per_m = boundary_resistance_h_per_m * 3600.0, .transpiration_mm = transpiration_m3 * 1000.0 / cell_area_m2, .oxygen_stress_factor = oxygen_stress_factor, .primary_root_total_water_potential_mpa_by_layer = roots };
}

/// Allocation-free OUTPH water row for the runtime streaming path.
pub fn calculateWaterInto(canopy_total_water_potential_megapascal: f64, canopy_turgor_potential_megapascal: f64, stomatal_resistance_h_per_m: f64, boundary_resistance_h_per_m: f64, outward_water_flux_m3_per_h: f64, oxygen_stress_factor: f64, primary_root_total_water_potential_mpa_by_layer: []const f64, cell_area_m2: f64, output: []f64) !void {
    try validateArea(cell_area_m2);
    if (output.len != 6 + primary_root_total_water_potential_mpa_by_layer.len) return error.PlantWaterOutputValueDimensionMismatch;
    inline for (.{ canopy_total_water_potential_megapascal, canopy_turgor_potential_megapascal, stomatal_resistance_h_per_m, boundary_resistance_h_per_m, outward_water_flux_m3_per_h, oxygen_stress_factor }) |value| try finite(value);
    output[0..6].* = .{
        canopy_total_water_potential_megapascal,
        canopy_turgor_potential_megapascal,
        stomatal_resistance_h_per_m * 3600.0,
        boundary_resistance_h_per_m * 3600.0,
        outward_water_flux_m3_per_h * 1000.0 / cell_area_m2,
        oxygen_stress_factor,
    };
    for (primary_root_total_water_potential_mpa_by_layer, output[6..]) |potential, *destination| {
        try finite(potential);
        destination.* = potential;
    }
}

pub const Nitrogen = struct {
    allocator: std.mem.Allocator,
    ammonium_uptake_g_n_per_m2_h: f64,
    nitrate_uptake_g_n_per_m2_h: f64,
    nitrogen_fixation_g_n_per_m2_h: f64,
    nonstructural_nitrogen_concentration: f64,
    ammonia_flux_g_n_per_m2_h: f64,
    ammonium_uptake_g_n_per_m2_h_by_layer: []f64,
    nitrate_uptake_g_n_per_m2_h_by_layer: []f64,

    pub fn deinit(self: *Nitrogen) void {
        self.allocator.free(self.ammonium_uptake_g_n_per_m2_h_by_layer);
        self.allocator.free(self.nitrate_uptake_g_n_per_m2_h_by_layer);
        self.* = undefined;
    }

    pub fn valueCount(self: Nitrogen) usize {
        return 5 + self.ammonium_uptake_g_n_per_m2_h_by_layer.len + self.nitrate_uptake_g_n_per_m2_h_by_layer.len;
    }

    pub fn writeValues(self: Nitrogen, output: []f64) !void {
        if (output.len != self.valueCount()) return error.PlantNitrogenOutputValueDimensionMismatch;
        output[0..5].* = .{ self.ammonium_uptake_g_n_per_m2_h, self.nitrate_uptake_g_n_per_m2_h, self.nitrogen_fixation_g_n_per_m2_h, self.nonstructural_nitrogen_concentration, self.ammonia_flux_g_n_per_m2_h };
        @memcpy(output[5..][0..self.ammonium_uptake_g_n_per_m2_h_by_layer.len], self.ammonium_uptake_g_n_per_m2_h_by_layer);
        @memcpy(output[5 + self.ammonium_uptake_g_n_per_m2_h_by_layer.len ..], self.nitrate_uptake_g_n_per_m2_h_by_layer);
    }
};

pub const LayerNitrogenInputs = struct {
    ammonium_root_non_band_g_n_per_h: []const f64,
    ammonium_mycorrhiza_non_band_g_n_per_h: []const f64,
    ammonium_root_band_g_n_per_h: []const f64,
    ammonium_mycorrhiza_band_g_n_per_h: []const f64,
    nitrate_root_non_band_g_n_per_h: []const f64,
    nitrate_mycorrhiza_non_band_g_n_per_h: []const f64,
    nitrate_root_band_g_n_per_h: []const f64,
    nitrate_mycorrhiza_band_g_n_per_h: []const f64,
    layer_area_m2: []const f64,
};

pub fn nitrogen(allocator: std.mem.Allocator, ammonium_uptake_g_n_per_h: f64, nitrate_uptake_g_n_per_h: f64, nitrogen_fixation_g_n_per_h: f64, nonstructural_nitrogen_concentration: f64, ammonia_flux_g_n_per_h: f64, cell_area_m2: f64, layers: LayerNitrogenInputs) !Nitrogen {
    try validateArea(cell_area_m2);
    inline for (.{ ammonium_uptake_g_n_per_h, nitrate_uptake_g_n_per_h, nitrogen_fixation_g_n_per_h, nonstructural_nitrogen_concentration, ammonia_flux_g_n_per_h }) |value| try finite(value);
    const count = layers.layer_area_m2.len;
    inline for (.{ layers.ammonium_root_non_band_g_n_per_h.len, layers.ammonium_mycorrhiza_non_band_g_n_per_h.len, layers.ammonium_root_band_g_n_per_h.len, layers.ammonium_mycorrhiza_band_g_n_per_h.len, layers.nitrate_root_non_band_g_n_per_h.len, layers.nitrate_mycorrhiza_non_band_g_n_per_h.len, layers.nitrate_root_band_g_n_per_h.len, layers.nitrate_mycorrhiza_band_g_n_per_h.len }) |length| if (length != count) return error.PlantNitrogenOutputLayerDimensionMismatch;
    const ammonium = try allocator.alloc(f64, count);
    errdefer allocator.free(ammonium);
    const nitrate = try allocator.alloc(f64, count);
    errdefer allocator.free(nitrate);
    for (0..count) |layer| {
        try validateArea(layers.layer_area_m2[layer]);
        ammonium[layer] = (layers.ammonium_root_non_band_g_n_per_h[layer] + layers.ammonium_mycorrhiza_non_band_g_n_per_h[layer] + layers.ammonium_root_band_g_n_per_h[layer] + layers.ammonium_mycorrhiza_band_g_n_per_h[layer]) / layers.layer_area_m2[layer];
        nitrate[layer] = (layers.nitrate_root_non_band_g_n_per_h[layer] + layers.nitrate_mycorrhiza_non_band_g_n_per_h[layer] + layers.nitrate_root_band_g_n_per_h[layer] + layers.nitrate_mycorrhiza_band_g_n_per_h[layer]) / layers.layer_area_m2[layer];
        try finite(ammonium[layer]);
        try finite(nitrate[layer]);
    }
    return .{ .allocator = allocator, .ammonium_uptake_g_n_per_m2_h = ammonium_uptake_g_n_per_h / cell_area_m2, .nitrate_uptake_g_n_per_m2_h = nitrate_uptake_g_n_per_h / cell_area_m2, .nitrogen_fixation_g_n_per_m2_h = nitrogen_fixation_g_n_per_h / cell_area_m2, .nonstructural_nitrogen_concentration = nonstructural_nitrogen_concentration, .ammonia_flux_g_n_per_m2_h = ammonia_flux_g_n_per_h / cell_area_m2, .ammonium_uptake_g_n_per_m2_h_by_layer = ammonium, .nitrate_uptake_g_n_per_m2_h_by_layer = nitrate };
}

pub fn calculateNitrogenInto(ammonium_uptake_g_n_per_h: f64, nitrate_uptake_g_n_per_h: f64, nitrogen_fixation_g_n_per_h: f64, nonstructural_nitrogen_concentration: f64, ammonia_flux_g_n_per_h: f64, cell_area_m2: f64, layers: LayerNitrogenInputs, output: []f64) !void {
    try validateArea(cell_area_m2);
    inline for (.{ ammonium_uptake_g_n_per_h, nitrate_uptake_g_n_per_h, nitrogen_fixation_g_n_per_h, nonstructural_nitrogen_concentration, ammonia_flux_g_n_per_h }) |value| try finite(value);
    const count = layers.layer_area_m2.len;
    inline for (.{ layers.ammonium_root_non_band_g_n_per_h.len, layers.ammonium_mycorrhiza_non_band_g_n_per_h.len, layers.ammonium_root_band_g_n_per_h.len, layers.ammonium_mycorrhiza_band_g_n_per_h.len, layers.nitrate_root_non_band_g_n_per_h.len, layers.nitrate_mycorrhiza_non_band_g_n_per_h.len, layers.nitrate_root_band_g_n_per_h.len, layers.nitrate_mycorrhiza_band_g_n_per_h.len }) |length| if (length != count) return error.PlantNitrogenOutputLayerDimensionMismatch;
    const expected_count = try std.math.add(usize, 5, try std.math.mul(usize, 2, count));
    if (output.len != expected_count) return error.PlantNitrogenOutputValueDimensionMismatch;
    output[0..5].* = .{
        ammonium_uptake_g_n_per_h / cell_area_m2,
        nitrate_uptake_g_n_per_h / cell_area_m2,
        nitrogen_fixation_g_n_per_h / cell_area_m2,
        nonstructural_nitrogen_concentration,
        ammonia_flux_g_n_per_h / cell_area_m2,
    };
    for (0..count) |layer| {
        try validateArea(layers.layer_area_m2[layer]);
        output[5 + layer] = (layers.ammonium_root_non_band_g_n_per_h[layer] + layers.ammonium_mycorrhiza_non_band_g_n_per_h[layer] + layers.ammonium_root_band_g_n_per_h[layer] + layers.ammonium_mycorrhiza_band_g_n_per_h[layer]) / layers.layer_area_m2[layer];
        output[5 + count + layer] = (layers.nitrate_root_non_band_g_n_per_h[layer] + layers.nitrate_mycorrhiza_non_band_g_n_per_h[layer] + layers.nitrate_root_band_g_n_per_h[layer] + layers.nitrate_mycorrhiza_band_g_n_per_h[layer]) / layers.layer_area_m2[layer];
        try finite(output[5 + layer]);
        try finite(output[5 + count + layer]);
    }
}

pub const Phosphorus = struct {
    allocator: std.mem.Allocator,
    phosphate_uptake_g_p_per_m2_h: f64,
    nonstructural_phosphorus_concentration: f64,
    phosphate_uptake_g_p_per_m2_h_by_layer: []f64,

    pub fn deinit(self: *Phosphorus) void {
        self.allocator.free(self.phosphate_uptake_g_p_per_m2_h_by_layer);
        self.* = undefined;
    }

    pub fn valueCount(self: Phosphorus) usize {
        return 2 + self.phosphate_uptake_g_p_per_m2_h_by_layer.len;
    }

    pub fn writeValues(self: Phosphorus, output: []f64) !void {
        if (output.len != self.valueCount()) return error.PlantPhosphorusOutputValueDimensionMismatch;
        output[0..2].* = .{ self.phosphate_uptake_g_p_per_m2_h, self.nonstructural_phosphorus_concentration };
        @memcpy(output[2..], self.phosphate_uptake_g_p_per_m2_h_by_layer);
    }
};

pub fn phosphorus(allocator: std.mem.Allocator, total_uptake_g_p_per_h: f64, nonstructural_concentration: f64, root_non_band: []const f64, mycorrhiza_non_band: []const f64, root_band: []const f64, mycorrhiza_band: []const f64, layer_area_m2: []const f64, cell_area_m2: f64) !Phosphorus {
    try validateArea(cell_area_m2);
    try finite(total_uptake_g_p_per_h);
    try finite(nonstructural_concentration);
    const count = layer_area_m2.len;
    if (root_non_band.len != count or mycorrhiza_non_band.len != count or root_band.len != count or mycorrhiza_band.len != count) return error.PlantPhosphorusOutputLayerDimensionMismatch;
    const by_layer = try allocator.alloc(f64, count);
    errdefer allocator.free(by_layer);
    for (by_layer, 0..) |*value, layer| {
        try validateArea(layer_area_m2[layer]);
        value.* = (root_non_band[layer] + mycorrhiza_non_band[layer] + root_band[layer] + mycorrhiza_band[layer]) / layer_area_m2[layer];
        try finite(value.*);
    }
    return .{ .allocator = allocator, .phosphate_uptake_g_p_per_m2_h = total_uptake_g_p_per_h / cell_area_m2, .nonstructural_phosphorus_concentration = nonstructural_concentration, .phosphate_uptake_g_p_per_m2_h_by_layer = by_layer };
}

pub fn calculatePhosphorusInto(total_uptake_g_p_per_h: f64, nonstructural_concentration: f64, root_non_band: []const f64, mycorrhiza_non_band: []const f64, root_band: []const f64, mycorrhiza_band: []const f64, layer_area_m2: []const f64, cell_area_m2: f64, output: []f64) !void {
    try validateArea(cell_area_m2);
    try finite(total_uptake_g_p_per_h);
    try finite(nonstructural_concentration);
    const count = layer_area_m2.len;
    if (root_non_band.len != count or mycorrhiza_non_band.len != count or root_band.len != count or mycorrhiza_band.len != count) return error.PlantPhosphorusOutputLayerDimensionMismatch;
    if (output.len != try std.math.add(usize, 2, count)) return error.PlantPhosphorusOutputValueDimensionMismatch;
    output[0..2].* = .{ total_uptake_g_p_per_h / cell_area_m2, nonstructural_concentration };
    for (0..count) |layer| {
        try validateArea(layer_area_m2[layer]);
        output[2 + layer] = (root_non_band[layer] + mycorrhiza_non_band[layer] + root_band[layer] + mycorrhiza_band[layer]) / layer_area_m2[layer];
        try finite(output[2 + layer]);
    }
}

pub const Heat = struct {
    canopy_net_radiation_w_per_m2: f64,
    canopy_latent_heat_flux_w_per_m2: f64,
    canopy_sensible_heat_flux_w_per_m2: f64,
    canopy_storage_heat_flux_w_per_m2: f64,
    canopy_temperature_c: f64,
    temperature_function: f64,
    standing_dead_temperature_c: f64,

    pub fn values(self: Heat) [7]f64 {
        return .{ self.canopy_net_radiation_w_per_m2, self.canopy_latent_heat_flux_w_per_m2, self.canopy_sensible_heat_flux_w_per_m2, self.canopy_storage_heat_flux_w_per_m2, self.canopy_temperature_c, self.temperature_function, self.standing_dead_temperature_c };
    }
};

pub fn heat(net_radiation_megajoules: f64, latent_heat_megajoules: f64, sensible_heat_megajoules: f64, storage_heat_megajoules: f64, canopy_temperature_c: f64, temperature_function: f64, standing_dead_temperature_c: f64, cell_area_m2: f64) !Heat {
    try validateArea(cell_area_m2);
    inline for (.{ net_radiation_megajoules, latent_heat_megajoules, sensible_heat_megajoules, storage_heat_megajoules, canopy_temperature_c, temperature_function, standing_dead_temperature_c }) |value| try finite(value);
    return .{ .canopy_net_radiation_w_per_m2 = 277.8 * net_radiation_megajoules / cell_area_m2, .canopy_latent_heat_flux_w_per_m2 = 277.8 * latent_heat_megajoules / cell_area_m2, .canopy_sensible_heat_flux_w_per_m2 = 277.8 * sensible_heat_megajoules / cell_area_m2, .canopy_storage_heat_flux_w_per_m2 = 277.8 * storage_heat_megajoules / cell_area_m2, .canopy_temperature_c = canopy_temperature_c, .temperature_function = temperature_function, .standing_dead_temperature_c = standing_dead_temperature_c };
}

fn validateArea(area_m2: f64) !void {
    if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidPlantOutputArea;
}

fn finite(value: f64) !void {
    if (!std.math.isFinite(value)) return error.NonFinitePlantOutput;
}

fn duplicateFinite(allocator: std.mem.Allocator, values: []const f64) ![]f64 {
    const copy = try allocator.dupe(f64, values);
    errdefer allocator.free(copy);
    for (copy) |value| try finite(value);
    return copy;
}

test "OUTPH carbon water and heat equations preserve exact conversions with runtime roots" {
    const carbon_output = try carbon(12, 6, 3, 0.1, 0.2, 0.3, 4, 2);
    try std.testing.expectApproxEqAbs(6 * 23.148, carbon_output.canopy_carbon_dioxide_flux_umol_per_m2_s, 1e-12);
    try std.testing.expectApproxEqAbs(0.2 * 1.56 * 3600, carbon_output.stomatal_resistance_s_per_m, 1e-12);
    const roots = [_]f64{1} ** 23;
    var water_output = try water(std.testing.allocator, -1, 0.2, 0.1, 0.2, 0.004, 0.8, &roots, 2);
    defer water_output.deinit();
    try std.testing.expectEqual(@as(usize, 29), water_output.valueCount());
    try std.testing.expectApproxEqAbs(@as(f64, 2), water_output.transpiration_mm, 1e-15);
    const heat_output = try heat(1, 2, 3, 4, 20, 0.9, 15, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 277.8) / 2.0, heat_output.canopy_net_radiation_w_per_m2, 1e-12);
    var water_values: [29]f64 = undefined;
    try water_output.writeValues(&water_values);
    try std.testing.expectEqual(@as(f64, 1), water_values[28]);
    try std.testing.expectEqual(@as(f64, 15), heat_output.values()[6]);
    var streaming_water_values: [29]f64 = undefined;
    try calculateWaterInto(-1, 0.2, 0.1, 0.2, 0.004, 0.8, &roots, 2, &streaming_water_values);
    try std.testing.expectEqualSlices(f64, &water_values, &streaming_water_values);
}

test "OUTPH nutrient layer outputs sum root mycorrhiza band and non-band uptake" {
    const a = [_]f64{ 1, 2 };
    const area = [_]f64{ 2, 4 };
    var nitrogen_output = try nitrogen(std.testing.allocator, 10, 20, 30, 0.2, 5, 10, .{ .ammonium_root_non_band_g_n_per_h = &a, .ammonium_mycorrhiza_non_band_g_n_per_h = &a, .ammonium_root_band_g_n_per_h = &a, .ammonium_mycorrhiza_band_g_n_per_h = &a, .nitrate_root_non_band_g_n_per_h = &a, .nitrate_mycorrhiza_non_band_g_n_per_h = &a, .nitrate_root_band_g_n_per_h = &a, .nitrate_mycorrhiza_band_g_n_per_h = &a, .layer_area_m2 = &area });
    defer nitrogen_output.deinit();
    try std.testing.expectEqualSlices(f64, &.{ 2, 2 }, nitrogen_output.ammonium_uptake_g_n_per_m2_h_by_layer);
    var phosphorus_output = try phosphorus(std.testing.allocator, 10, 0.1, &a, &a, &a, &a, &area, 10);
    defer phosphorus_output.deinit();
    try std.testing.expectEqualSlices(f64, &.{ 2, 2 }, phosphorus_output.phosphate_uptake_g_p_per_m2_h_by_layer);
    var nitrogen_values: [9]f64 = undefined;
    try nitrogen_output.writeValues(&nitrogen_values);
    try std.testing.expectEqual(@as(f64, 2), nitrogen_values[8]);
    var phosphorus_values: [4]f64 = undefined;
    try phosphorus_output.writeValues(&phosphorus_values);
    try std.testing.expectEqual(@as(f64, 2), phosphorus_values[3]);
    var streaming_nitrogen_values: [9]f64 = undefined;
    try calculateNitrogenInto(10, 20, 30, 0.2, 5, 10, .{ .ammonium_root_non_band_g_n_per_h = &a, .ammonium_mycorrhiza_non_band_g_n_per_h = &a, .ammonium_root_band_g_n_per_h = &a, .ammonium_mycorrhiza_band_g_n_per_h = &a, .nitrate_root_non_band_g_n_per_h = &a, .nitrate_mycorrhiza_non_band_g_n_per_h = &a, .nitrate_root_band_g_n_per_h = &a, .nitrate_mycorrhiza_band_g_n_per_h = &a, .layer_area_m2 = &area }, &streaming_nitrogen_values);
    try std.testing.expectEqualSlices(f64, &nitrogen_values, &streaming_nitrogen_values);
    var streaming_phosphorus_values: [4]f64 = undefined;
    try calculatePhosphorusInto(10, 0.1, &a, &a, &a, &a, &area, 10, &streaming_phosphorus_values);
    try std.testing.expectEqualSlices(f64, &phosphorus_values, &streaming_phosphorus_values);
}

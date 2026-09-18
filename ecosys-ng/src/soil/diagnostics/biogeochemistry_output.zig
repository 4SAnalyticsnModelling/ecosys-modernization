const std = @import("std");
const gas_transport = @import("../gas/transport.zig");

/// Projects the HOUR1/OUTSH aqueous concentration convention:
/// tracked-element mass (g) divided by liquid-water volume (m3).
pub fn writeDissolvedGasConcentrationProfile(
    dissolved_mass_g: []const f64,
    liquid_water_volume_m3: []const f64,
    first_layer: usize,
    layer_count: usize,
    species: gas_transport.Species,
    output_g_per_m3: []f64,
) !void {
    if (output_g_per_m3.len != layer_count or liquid_water_volume_m3.len * gas_transport.species_count != dissolved_mass_g.len or first_layer > liquid_water_volume_m3.len or layer_count > liquid_water_volume_m3.len - first_layer) return error.GasConcentrationDimensionMismatch;
    for (output_g_per_m3, 0..) |*concentration, local_layer| {
        const layer = first_layer + local_layer;
        const mass = dissolved_mass_g[layer * gas_transport.species_count + @intFromEnum(species)];
        const water = liquid_water_volume_m3[layer];
        if (!std.math.isFinite(mass) or mass < 0 or !std.math.isFinite(water) or water < 0) return error.InvalidGasConcentrationState;
        if (water == 0) {
            if (mass != 0) return error.DissolvedGasWithoutLiquidWater;
            concentration.* = 0;
        } else concentration.* = mass / water;
        if (!std.math.isFinite(concentration.*)) return error.NonFiniteBiogeochemistryOutput;
    }
}

pub fn dissolvedGasConcentration(mass_g: f64, liquid_water_volume_m3: f64) !f64 {
    var mass = [_]f64{0} ** gas_transport.species_count;
    mass[@intFromEnum(gas_transport.Species.carbon_dioxide)] = mass_g;
    var output: [1]f64 = undefined;
    try writeDissolvedGasConcentrationProfile(&mass, &.{liquid_water_volume_m3}, 0, 1, .carbon_dioxide, &output);
    return output[0];
}

pub const CarbonDiagnostics = struct {
    allocator: std.mem.Allocator,
    carbon_dioxide_emission_umol_per_m2_s: f64,
    net_carbon_exchange_umol_per_m2_s: f64,
    methane_emission_umol_per_m2_s: f64,
    oxygen_exchange_umol_per_m2_s: f64,
    carbon_dioxide_concentration_by_layer: []f64,
    canopy_air_carbon_dioxide_umol_per_mol: f64,
    methane_concentration_by_layer: []f64,
    oxygen_concentration_by_layer: []f64,
    litter_oxygen_concentration: f64,

    pub fn deinit(self: *CarbonDiagnostics) void {
        self.allocator.free(self.carbon_dioxide_concentration_by_layer);
        self.allocator.free(self.methane_concentration_by_layer);
        self.allocator.free(self.oxygen_concentration_by_layer);
        self.* = undefined;
    }

    pub fn valueCount(self: CarbonDiagnostics) usize {
        return 6 + self.carbon_dioxide_concentration_by_layer.len + self.methane_concentration_by_layer.len + self.oxygen_concentration_by_layer.len;
    }

    pub fn writeValues(self: CarbonDiagnostics, output: []f64) !void {
        if (output.len != self.valueCount()) return error.CarbonOutputValueDimensionMismatch;
        output[0..4].* = .{ self.carbon_dioxide_emission_umol_per_m2_s, self.net_carbon_exchange_umol_per_m2_s, self.methane_emission_umol_per_m2_s, self.oxygen_exchange_umol_per_m2_s };
        var index: usize = 4;
        @memcpy(output[index..][0..self.carbon_dioxide_concentration_by_layer.len], self.carbon_dioxide_concentration_by_layer);
        index += self.carbon_dioxide_concentration_by_layer.len;
        output[index] = self.canopy_air_carbon_dioxide_umol_per_mol;
        index += 1;
        @memcpy(output[index..][0..self.methane_concentration_by_layer.len], self.methane_concentration_by_layer);
        index += self.methane_concentration_by_layer.len;
        @memcpy(output[index..][0..self.oxygen_concentration_by_layer.len], self.oxygen_concentration_by_layer);
        index += self.oxygen_concentration_by_layer.len;
        output[index] = self.litter_oxygen_concentration;
    }
};

pub const CarbonInputs = struct {
    carbon_dioxide_emission_g_c_per_h: f64,
    net_carbon_exchange_g_c_per_h: f64,
    methane_emission_g_c_per_h: f64,
    oxygen_exchange_g_o2_per_h: f64,
    local_surface_area_m2: f64,
    carbon_dioxide_concentration_by_layer: []const f64,
    canopy_air_carbon_dioxide_umol_per_mol: f64,
    methane_concentration_by_layer: []const f64,
    oxygen_concentration_by_layer: []const f64,
    litter_oxygen_concentration: f64,
};

pub fn calculateCarbonInto(inputs: CarbonInputs, output: []f64) !void {
    const carbon_layers = inputs.carbon_dioxide_concentration_by_layer.len;
    const methane_layers = inputs.methane_concentration_by_layer.len;
    const oxygen_layers = inputs.oxygen_concentration_by_layer.len;
    if (output.len != 6 + carbon_layers + methane_layers + oxygen_layers) return error.CarbonOutputValueDimensionMismatch;
    if (!std.math.isFinite(inputs.local_surface_area_m2) or inputs.local_surface_area_m2 <= 0) return error.InvalidBiogeochemistryOutputArea;
    inline for (.{ inputs.carbon_dioxide_emission_g_c_per_h, inputs.net_carbon_exchange_g_c_per_h, inputs.methane_emission_g_c_per_h, inputs.oxygen_exchange_g_o2_per_h, inputs.canopy_air_carbon_dioxide_umol_per_mol, inputs.litter_oxygen_concentration }) |value| if (!std.math.isFinite(value)) return error.NonFiniteBiogeochemistryOutput;
    inline for (.{ inputs.carbon_dioxide_concentration_by_layer, inputs.methane_concentration_by_layer, inputs.oxygen_concentration_by_layer }) |profile| for (profile) |value| if (!std.math.isFinite(value)) return error.NonFiniteBiogeochemistryOutput;
    output[0..4].* = .{
        inputs.carbon_dioxide_emission_g_c_per_h / inputs.local_surface_area_m2 * 23.14815,
        inputs.net_carbon_exchange_g_c_per_h / inputs.local_surface_area_m2 * 23.14815,
        inputs.methane_emission_g_c_per_h / inputs.local_surface_area_m2 * 23.14815,
        inputs.oxygen_exchange_g_o2_per_h / inputs.local_surface_area_m2 * 8.68056,
    };
    var index: usize = 4;
    for (output[index..][0..carbon_layers], inputs.carbon_dioxide_concentration_by_layer) |*destination, source| destination.* = source;
    index += carbon_layers;
    output[index] = inputs.canopy_air_carbon_dioxide_umol_per_mol;
    index += 1;
    for (output[index..][0..methane_layers], inputs.methane_concentration_by_layer) |*destination, source| destination.* = source;
    index += methane_layers;
    for (output[index..][0..oxygen_layers], inputs.oxygen_concentration_by_layer) |*destination, source| destination.* = source;
    index += oxygen_layers;
    output[index] = inputs.litter_oxygen_concentration;
}

pub fn calculateCarbon(allocator: std.mem.Allocator, inputs: CarbonInputs) !CarbonDiagnostics {
    if (!std.math.isFinite(inputs.local_surface_area_m2) or inputs.local_surface_area_m2 <= 0) return error.InvalidBiogeochemistryOutputArea;
    inline for (.{ inputs.carbon_dioxide_emission_g_c_per_h, inputs.net_carbon_exchange_g_c_per_h, inputs.methane_emission_g_c_per_h, inputs.oxygen_exchange_g_o2_per_h, inputs.canopy_air_carbon_dioxide_umol_per_mol, inputs.litter_oxygen_concentration }) |value| if (!std.math.isFinite(value)) return error.NonFiniteBiogeochemistryOutput;
    const carbon_dioxide = try duplicateFinite(allocator, inputs.carbon_dioxide_concentration_by_layer);
    errdefer allocator.free(carbon_dioxide);
    const methane = try duplicateFinite(allocator, inputs.methane_concentration_by_layer);
    errdefer allocator.free(methane);
    const oxygen = try duplicateFinite(allocator, inputs.oxygen_concentration_by_layer);
    errdefer allocator.free(oxygen);
    return .{
        .allocator = allocator,
        // Exact OUTSH factors: 1e6 umol mol-1 / molar mass / 3600 s h-1.
        .carbon_dioxide_emission_umol_per_m2_s = inputs.carbon_dioxide_emission_g_c_per_h / inputs.local_surface_area_m2 * 23.14815,
        .net_carbon_exchange_umol_per_m2_s = inputs.net_carbon_exchange_g_c_per_h / inputs.local_surface_area_m2 * 23.14815,
        .methane_emission_umol_per_m2_s = inputs.methane_emission_g_c_per_h / inputs.local_surface_area_m2 * 23.14815,
        .oxygen_exchange_umol_per_m2_s = inputs.oxygen_exchange_g_o2_per_h / inputs.local_surface_area_m2 * 8.68056,
        .carbon_dioxide_concentration_by_layer = carbon_dioxide,
        .canopy_air_carbon_dioxide_umol_per_mol = inputs.canopy_air_carbon_dioxide_umol_per_mol,
        .methane_concentration_by_layer = methane,
        .oxygen_concentration_by_layer = oxygen,
        .litter_oxygen_concentration = inputs.litter_oxygen_concentration,
    };
}

pub const NitrogenDiagnostics = struct {
    allocator: std.mem.Allocator,
    nitrous_oxide_emission_g_n_per_m2_h: f64,
    dinitrogen_emission_g_n_per_m2_h: f64,
    ammonia_emission_g_n_per_m2_h: f64,
    dissolved_inorganic_nitrogen_runoff_g_n_per_m2_h: f64,
    dissolved_inorganic_nitrogen_drainage_g_n_per_m2_h: f64,
    nitrous_oxide_concentration_by_layer: []f64,
    litter_nitrous_oxide_concentration: f64,
    ammonia_concentration_by_layer: []f64,
    litter_ammonia_concentration: f64,

    pub fn deinit(self: *NitrogenDiagnostics) void {
        self.allocator.free(self.nitrous_oxide_concentration_by_layer);
        self.allocator.free(self.ammonia_concentration_by_layer);
        self.* = undefined;
    }

    pub fn valueCount(self: NitrogenDiagnostics) usize {
        return 7 + self.nitrous_oxide_concentration_by_layer.len + self.ammonia_concentration_by_layer.len;
    }

    pub fn writeValues(self: NitrogenDiagnostics, output: []f64) !void {
        if (output.len != self.valueCount()) return error.NitrogenOutputValueDimensionMismatch;
        output[0..5].* = .{ self.nitrous_oxide_emission_g_n_per_m2_h, self.dinitrogen_emission_g_n_per_m2_h, self.ammonia_emission_g_n_per_m2_h, self.dissolved_inorganic_nitrogen_runoff_g_n_per_m2_h, self.dissolved_inorganic_nitrogen_drainage_g_n_per_m2_h };
        var index: usize = 5;
        @memcpy(output[index..][0..self.nitrous_oxide_concentration_by_layer.len], self.nitrous_oxide_concentration_by_layer);
        index += self.nitrous_oxide_concentration_by_layer.len;
        output[index] = self.litter_nitrous_oxide_concentration;
        index += 1;
        @memcpy(output[index..][0..self.ammonia_concentration_by_layer.len], self.ammonia_concentration_by_layer);
        index += self.ammonia_concentration_by_layer.len;
        output[index] = self.litter_ammonia_concentration;
    }
};

pub const NitrogenInputs = struct {
    nitrous_oxide_emission_g_n_per_h: f64,
    dinitrogen_emission_g_n_per_h: f64,
    ammonia_emission_g_n_per_h: f64,
    dissolved_inorganic_nitrogen_runoff_g_n_per_h: f64,
    dissolved_inorganic_nitrogen_drainage_g_n_per_h: f64,
    local_surface_area_m2: f64,
    total_grid_area_m2: f64,
    nitrous_oxide_concentration_by_layer: []const f64,
    litter_nitrous_oxide_concentration: f64,
    ammonia_concentration_by_layer: []const f64,
    litter_ammonia_concentration: f64,
};

pub fn calculateNitrogenInto(inputs: NitrogenInputs, output: []f64) !void {
    const nitrous_oxide_layers = inputs.nitrous_oxide_concentration_by_layer.len;
    const ammonia_layers = inputs.ammonia_concentration_by_layer.len;
    if (output.len != 7 + nitrous_oxide_layers + ammonia_layers) return error.NitrogenOutputValueDimensionMismatch;
    if (!std.math.isFinite(inputs.local_surface_area_m2) or inputs.local_surface_area_m2 <= 0 or !std.math.isFinite(inputs.total_grid_area_m2) or inputs.total_grid_area_m2 <= 0) return error.InvalidBiogeochemistryOutputArea;
    inline for (.{ inputs.nitrous_oxide_emission_g_n_per_h, inputs.dinitrogen_emission_g_n_per_h, inputs.ammonia_emission_g_n_per_h, inputs.dissolved_inorganic_nitrogen_runoff_g_n_per_h, inputs.dissolved_inorganic_nitrogen_drainage_g_n_per_h, inputs.litter_nitrous_oxide_concentration, inputs.litter_ammonia_concentration }) |value| if (!std.math.isFinite(value)) return error.NonFiniteBiogeochemistryOutput;
    inline for (.{ inputs.nitrous_oxide_concentration_by_layer, inputs.ammonia_concentration_by_layer }) |profile| for (profile) |value| if (!std.math.isFinite(value)) return error.NonFiniteBiogeochemistryOutput;
    output[0..5].* = .{
        inputs.nitrous_oxide_emission_g_n_per_h / inputs.local_surface_area_m2,
        inputs.dinitrogen_emission_g_n_per_h / inputs.local_surface_area_m2,
        inputs.ammonia_emission_g_n_per_h / inputs.local_surface_area_m2,
        inputs.dissolved_inorganic_nitrogen_runoff_g_n_per_h / inputs.total_grid_area_m2,
        inputs.dissolved_inorganic_nitrogen_drainage_g_n_per_h / inputs.total_grid_area_m2,
    };
    var index: usize = 5;
    for (output[index..][0..nitrous_oxide_layers], inputs.nitrous_oxide_concentration_by_layer) |*destination, source| destination.* = source;
    index += nitrous_oxide_layers;
    output[index] = inputs.litter_nitrous_oxide_concentration;
    index += 1;
    for (output[index..][0..ammonia_layers], inputs.ammonia_concentration_by_layer) |*destination, source| destination.* = source;
    index += ammonia_layers;
    output[index] = inputs.litter_ammonia_concentration;
}

pub fn calculateNitrogen(allocator: std.mem.Allocator, inputs: NitrogenInputs) !NitrogenDiagnostics {
    if (!std.math.isFinite(inputs.local_surface_area_m2) or inputs.local_surface_area_m2 <= 0 or !std.math.isFinite(inputs.total_grid_area_m2) or inputs.total_grid_area_m2 <= 0) return error.InvalidBiogeochemistryOutputArea;
    inline for (.{ inputs.nitrous_oxide_emission_g_n_per_h, inputs.dinitrogen_emission_g_n_per_h, inputs.ammonia_emission_g_n_per_h, inputs.dissolved_inorganic_nitrogen_runoff_g_n_per_h, inputs.dissolved_inorganic_nitrogen_drainage_g_n_per_h, inputs.litter_nitrous_oxide_concentration, inputs.litter_ammonia_concentration }) |value| if (!std.math.isFinite(value)) return error.NonFiniteBiogeochemistryOutput;
    const nitrous_oxide = try duplicateFinite(allocator, inputs.nitrous_oxide_concentration_by_layer);
    errdefer allocator.free(nitrous_oxide);
    const ammonia = try duplicateFinite(allocator, inputs.ammonia_concentration_by_layer);
    errdefer allocator.free(ammonia);
    return .{
        .allocator = allocator,
        .nitrous_oxide_emission_g_n_per_m2_h = inputs.nitrous_oxide_emission_g_n_per_h / inputs.local_surface_area_m2,
        .dinitrogen_emission_g_n_per_m2_h = inputs.dinitrogen_emission_g_n_per_h / inputs.local_surface_area_m2,
        .ammonia_emission_g_n_per_m2_h = inputs.ammonia_emission_g_n_per_h / inputs.local_surface_area_m2,
        .dissolved_inorganic_nitrogen_runoff_g_n_per_m2_h = inputs.dissolved_inorganic_nitrogen_runoff_g_n_per_h / inputs.total_grid_area_m2,
        .dissolved_inorganic_nitrogen_drainage_g_n_per_m2_h = inputs.dissolved_inorganic_nitrogen_drainage_g_n_per_h / inputs.total_grid_area_m2,
        .nitrous_oxide_concentration_by_layer = nitrous_oxide,
        .litter_nitrous_oxide_concentration = inputs.litter_nitrous_oxide_concentration,
        .ammonia_concentration_by_layer = ammonia,
        .litter_ammonia_concentration = inputs.litter_ammonia_concentration,
    };
}

pub const PhosphorusDiagnostics = struct {
    dissolved_inorganic_phosphorus_runoff_g_p_per_m2_h: f64,
    dissolved_inorganic_phosphorus_drainage_g_p_per_m2_h: f64,
};

pub fn calculatePhosphorus(runoff_g_p_per_h: f64, drainage_g_p_per_h: f64, total_grid_area_m2: f64) !PhosphorusDiagnostics {
    if (!std.math.isFinite(total_grid_area_m2) or total_grid_area_m2 <= 0) return error.InvalidBiogeochemistryOutputArea;
    if (!std.math.isFinite(runoff_g_p_per_h) or !std.math.isFinite(drainage_g_p_per_h)) return error.NonFiniteBiogeochemistryOutput;
    return .{ .dissolved_inorganic_phosphorus_runoff_g_p_per_m2_h = runoff_g_p_per_h / total_grid_area_m2, .dissolved_inorganic_phosphorus_drainage_g_p_per_m2_h = drainage_g_p_per_h / total_grid_area_m2 };
}

pub fn phosphorusValues(diagnostics: PhosphorusDiagnostics) [2]f64 {
    return .{ diagnostics.dissolved_inorganic_phosphorus_runoff_g_p_per_m2_h, diagnostics.dissolved_inorganic_phosphorus_drainage_g_p_per_m2_h };
}

fn duplicateFinite(allocator: std.mem.Allocator, values: []const f64) ![]f64 {
    const copy = try allocator.dupe(f64, values);
    errdefer allocator.free(copy);
    for (copy) |value| if (!std.math.isFinite(value)) return error.NonFiniteBiogeochemistryOutput;
    return copy;
}

test "OUTSH carbon diagnostics preserve exact factors across runtime layers" {
    const layers = [_]f64{1} ** 23;
    var output = try calculateCarbon(std.testing.allocator, .{ .carbon_dioxide_emission_g_c_per_h = 100, .net_carbon_exchange_g_c_per_h = -50, .methane_emission_g_c_per_h = 25, .oxygen_exchange_g_o2_per_h = 32, .local_surface_area_m2 = 100, .carbon_dioxide_concentration_by_layer = &layers, .canopy_air_carbon_dioxide_umol_per_mol = 2, .methane_concentration_by_layer = &layers, .oxygen_concentration_by_layer = &layers, .litter_oxygen_concentration = 4 });
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 23), output.oxygen_concentration_by_layer.len);
    try std.testing.expectEqual(@as(usize, 75), output.valueCount());
    try std.testing.expectApproxEqAbs(@as(f64, 23.14815), output.carbon_dioxide_emission_umol_per_m2_s, 1e-12);
    try std.testing.expectApproxEqAbs(32.0 / 100.0 * 8.68056, output.oxygen_exchange_umol_per_m2_s, 1e-12);
    var values: [75]f64 = undefined;
    try output.writeValues(&values);
    try std.testing.expectEqual(@as(f64, 2), values[27]);
    try std.testing.expectEqual(@as(f64, 4), values[74]);
}

test "OUTSH nitrogen and phosphorus diagnostics preserve local and grid areas" {
    const layers = [_]f64{ 1, 2, 3 };
    var nitrogen = try calculateNitrogen(std.testing.allocator, .{ .nitrous_oxide_emission_g_n_per_h = 10, .dinitrogen_emission_g_n_per_h = 20, .ammonia_emission_g_n_per_h = 30, .dissolved_inorganic_nitrogen_runoff_g_n_per_h = 40, .dissolved_inorganic_nitrogen_drainage_g_n_per_h = 50, .local_surface_area_m2 = 10, .total_grid_area_m2 = 100, .nitrous_oxide_concentration_by_layer = &layers, .litter_nitrous_oxide_concentration = 4, .ammonia_concentration_by_layer = &layers, .litter_ammonia_concentration = 5 });
    defer nitrogen.deinit();
    try std.testing.expectEqual(@as(usize, 13), nitrogen.valueCount());
    try std.testing.expectApproxEqAbs(@as(f64, 1), nitrogen.nitrous_oxide_emission_g_n_per_m2_h, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), nitrogen.dissolved_inorganic_nitrogen_runoff_g_n_per_m2_h, 1e-15);
    var nitrogen_values: [13]f64 = undefined;
    try nitrogen.writeValues(&nitrogen_values);
    try std.testing.expectEqual(@as(f64, 4), nitrogen_values[8]);
    try std.testing.expectEqual(@as(f64, 5), nitrogen_values[12]);
    const phosphorus = try calculatePhosphorus(20, 30, 100);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), phosphorus.dissolved_inorganic_phosphorus_runoff_g_p_per_m2_h, 1e-15);
    try std.testing.expectEqual([2]f64{ 0.2, 0.3 }, phosphorusValues(phosphorus));
}

test "allocation-free carbon and nitrogen projections match owned diagnostics" {
    const profile = [_]f64{ 1, 2, 3 };
    const carbon_inputs: CarbonInputs = .{ .carbon_dioxide_emission_g_c_per_h = 10, .net_carbon_exchange_g_c_per_h = -2, .methane_emission_g_c_per_h = 3, .oxygen_exchange_g_o2_per_h = 4, .local_surface_area_m2 = 5, .carbon_dioxide_concentration_by_layer = &profile, .canopy_air_carbon_dioxide_umol_per_mol = 6, .methane_concentration_by_layer = &profile, .oxygen_concentration_by_layer = &profile, .litter_oxygen_concentration = 7 };
    var owned_carbon = try calculateCarbon(std.testing.allocator, carbon_inputs);
    defer owned_carbon.deinit();
    var expected_carbon: [15]f64 = undefined;
    var actual_carbon: [15]f64 = undefined;
    try owned_carbon.writeValues(&expected_carbon);
    try calculateCarbonInto(carbon_inputs, &actual_carbon);
    try std.testing.expectEqualSlices(f64, &expected_carbon, &actual_carbon);

    const nitrogen_inputs: NitrogenInputs = .{ .nitrous_oxide_emission_g_n_per_h = 1, .dinitrogen_emission_g_n_per_h = 2, .ammonia_emission_g_n_per_h = 3, .dissolved_inorganic_nitrogen_runoff_g_n_per_h = 4, .dissolved_inorganic_nitrogen_drainage_g_n_per_h = 5, .local_surface_area_m2 = 5, .total_grid_area_m2 = 10, .nitrous_oxide_concentration_by_layer = &profile, .litter_nitrous_oxide_concentration = 6, .ammonia_concentration_by_layer = &profile, .litter_ammonia_concentration = 7 };
    var owned_nitrogen = try calculateNitrogen(std.testing.allocator, nitrogen_inputs);
    defer owned_nitrogen.deinit();
    var expected_nitrogen: [13]f64 = undefined;
    var actual_nitrogen: [13]f64 = undefined;
    try owned_nitrogen.writeValues(&expected_nitrogen);
    try calculateNitrogenInto(nitrogen_inputs, &actual_nitrogen);
    try std.testing.expectEqualSlices(f64, &expected_nitrogen, &actual_nitrogen);
}

test "OUTSH dissolved gas concentration uses runtime water volume and fails on impossible dry mass" {
    var dissolved = [_]f64{0} ** (2 * gas_transport.species_count);
    dissolved[@intFromEnum(gas_transport.Species.carbon_dioxide)] = 6;
    dissolved[gas_transport.species_count + @intFromEnum(gas_transport.Species.carbon_dioxide)] = 4;
    var profile: [2]f64 = undefined;
    try writeDissolvedGasConcentrationProfile(&dissolved, &.{ 2, 0.5 }, 0, 2, .carbon_dioxide, &profile);
    try std.testing.expectEqual([2]f64{ 3, 8 }, profile);
    try std.testing.expectEqual(@as(f64, 0), try dissolvedGasConcentration(0, 0));
    try std.testing.expectError(error.DissolvedGasWithoutLiquidWater, dissolvedGasConcentration(1, 0));
}

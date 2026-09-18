const std = @import("std");
const Variable = @import("../../io/output/record.zig").Variable;

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    variables: []Variable,

    pub fn deinit(self: *Catalog) void {
        for (self.variables) |variable| self.allocator.free(variable.name);
        self.allocator.free(self.variables);
        self.* = undefined;
    }
};

pub fn water(allocator: std.mem.Allocator, layer_count: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.fixed("evapotranspiration", "mm");
    try builder.fixed("runoff", "mm");
    try builder.fixed("sediment_discharge_water", "mm");
    try builder.fixed("root_water_uptake", "mm");
    try builder.fixed("external_water_outflow", "mm");
    try builder.fixed("surface_water_equivalent", "mm");
    try builder.layers("volumetric_liquid_water_fraction", "m3 m-3", layer_count);
    try builder.fixed("surface_excess_liquid_water_depth", "m");
    try builder.layers("volumetric_ice_fraction", "m3 m-3", layer_count);
    try builder.fixed("surface_excess_ice_water_depth", "m");
    try builder.fixed("active_layer_depth_below_surface", "m");
    try builder.fixed("water_table_depth_below_surface", "m");
    return builder.finish();
}

pub fn heat(allocator: std.mem.Allocator, layer_count: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    const fixed_variables = [_]Variable{
        .{ .name = "incoming_shortwave_radiation", .unit = "W m-2" },
        .{ .name = "air_temperature", .unit = "degC" },
        .{ .name = "atmospheric_vapor_pressure", .unit = "kPa" },
        .{ .name = "wind_speed", .unit = "m s-1" },
        .{ .name = "rain_and_irrigation", .unit = "mm" },
        .{ .name = "ground_surface_net_radiation", .unit = "W m-2" },
        .{ .name = "ground_surface_latent_heat_flux", .unit = "W m-2" },
        .{ .name = "ground_surface_sensible_heat_flux", .unit = "W m-2" },
        .{ .name = "ground_surface_storage_heat_flux", .unit = "W m-2" },
        .{ .name = "ecosystem_net_radiation", .unit = "W m-2" },
        .{ .name = "ecosystem_latent_heat_flux", .unit = "W m-2" },
        .{ .name = "ecosystem_sensible_heat_flux", .unit = "W m-2" },
        .{ .name = "ecosystem_storage_heat_flux", .unit = "W m-2" },
    };
    for (fixed_variables) |variable| try builder.fixed(variable.name, variable.unit);
    try builder.layers("soil_temperature", "degC", layer_count);
    try builder.fixed("surface_soil_temperature", "degC");
    try builder.fixed("surface_water_temperature", "degC");
    try builder.fixed("litter_temperature", "degC");
    try builder.fixed("litter_water_vapor_density", "g m-3");
    return builder.finish();
}

pub fn carbon(allocator: std.mem.Allocator, carbon_dioxide_layers: usize, methane_layers: usize, oxygen_layers: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.fixed("carbon_dioxide_emission", "umol m-2 s-1");
    try builder.fixed("net_carbon_exchange", "umol m-2 s-1");
    try builder.fixed("methane_emission", "umol m-2 s-1");
    try builder.fixed("oxygen_exchange", "umol m-2 s-1");
    try builder.layers("dissolved_carbon_dioxide_carbon_concentration", "g C m-3 water", carbon_dioxide_layers);
    try builder.fixed("canopy_air_carbon_dioxide", "umol mol-1");
    try builder.layers("dissolved_methane_carbon_concentration", "g C m-3 water", methane_layers);
    try builder.layers("dissolved_oxygen_concentration", "g O2 m-3 water", oxygen_layers);
    try builder.fixed("litter_dissolved_oxygen_concentration", "g O2 m-3 water");
    return builder.finish();
}

pub fn nitrogen(allocator: std.mem.Allocator, nitrous_oxide_layers: usize, ammonia_layers: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.fixed("nitrous_oxide_emission", "g N m-2 h-1");
    try builder.fixed("dinitrogen_emission", "g N m-2 h-1");
    try builder.fixed("ammonia_emission", "g N m-2 h-1");
    try builder.fixed("dissolved_inorganic_nitrogen_runoff", "g N m-2 h-1");
    try builder.fixed("dissolved_inorganic_nitrogen_drainage", "g N m-2 h-1");
    // Catalog order deliberately differs from source slot order here: the
    // source names N2O_1..15 at slots 6-20, NH3_1..15 at 21-35, and only then
    // N2O_LIT at 36 and NH3_LIT at 37 (`fouts.f:221-262`, `outsh.f:218-219`
    // `CZ2OS(0)`/`CNH3S(0)`), whereas this catalog keeps each litter entry next
    // to its own layer block. The value producer is written against this order,
    // so the order stays; `src/io/output/editor_layout.zig`'s layout for editor
    // index 2 states the source slot of every run and resolves the permutation.
    try builder.layers("dissolved_nitrous_oxide_nitrogen_concentration", "g N m-3 water", nitrous_oxide_layers);
    try builder.fixed("litter_dissolved_nitrous_oxide_nitrogen_concentration", "g N m-3 water");
    try builder.layers("dissolved_ammonia_nitrogen_concentration", "g N m-3 water", ammonia_layers);
    try builder.fixed("litter_dissolved_ammonia_nitrogen_concentration", "g N m-3 water");
    return builder.finish();
}

pub fn phosphorus(allocator: std.mem.Allocator) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.fixed("dissolved_inorganic_phosphorus_runoff", "g P m-2 h-1");
    try builder.fixed("dissolved_inorganic_phosphorus_drainage", "g P m-2 h-1");
    return builder.finish();
}

pub fn dailyCarbon(allocator: std.mem.Allocator, layer_count: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    for ([_][]const u8{ "residue_carbon", "organic_carbon", "organic_fertilizer_carbon", "carbon_sink", "daily_soil_carbon_dioxide_exchange" }) |name| try builder.fixed(name, "g C m-2");
    try builder.fixed("daily_soil_oxygen_exchange", "g O m-2");
    for ([_][]const u8{ "carbon_output", "microbial_carbon", "surface_organic_carbon", "daily_soil_methane_exchange", "dissolved_organic_carbon_runoff", "dissolved_organic_carbon_drainage", "dissolved_inorganic_carbon_runoff", "dissolved_inorganic_carbon_drainage" }) |name| try builder.fixed(name, "g C m-2");
    try builder.fixed("atmospheric_carbon_dioxide", "umol mol-1");
    try builder.fixed("net_biome_productivity", "g C m-2");
    try builder.fixed("fire_carbon_dioxide_emission", "g C m-2");
    try builder.layers("organic_carbon", "g C m-2", layer_count);
    try builder.fixed("soil_fire_charcoal_production", "g C m-2");
    try builder.fixed("canopy_air_carbon_dioxide_exchange", "g C m-2");
    try builder.fixed("canopy_air_methane_exchange", "g C m-2");
    try builder.fixed("canopy_air_oxygen_exchange", "g O m-2");
    for (1..6) |slot| {
        const name = try std.fmt.allocPrint(allocator, "reserved_zero_{d}", .{slot});
        defer allocator.free(name);
        try builder.fixed(name, "g C m-2");
    }
    try builder.fixed("daily_hydrogen_flux", "g H m-2");
    try builder.fixed("harvested_carbon", "g C m-2");
    try builder.fixed("total_leaf_area", "m2 m-2");
    for ([_][]const u8{ "gross_primary_productivity", "autotrophic_respiration", "net_primary_productivity", "total_heterotrophic_respiration", "fire_methane_emission", "total_inorganic_carbon_storage", "standing_dead_carbon" }) |name| try builder.fixed(name, "g C m-2");
    return builder.finish();
}

pub fn dailyWater(allocator: std.mem.Allocator, liquid_layers: usize, ice_layers: usize, potential_layers: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    for ([_][]const u8{ "rainfall", "evaporation", "runoff", "soil_water_storage", "water_outflow", "snow_depth" }) |name| try builder.fixed(name, "mm");
    try builder.layers("volumetric_liquid_water_fraction", "m3 m-3", liquid_layers);
    try builder.fixed("surface_volumetric_liquid_water_fraction", "m3 m-3");
    try builder.layers("volumetric_ice_fraction", "m3 m-3", ice_layers);
    try builder.fixed("surface_volumetric_ice_fraction", "m3 m-3");
    try builder.layers("total_water_potential", "MPa", potential_layers);
    for ([_][]const u8{ "lateral_water_outflow", "sediment_outflow" }) |name| try builder.fixed(name, "mm");
    try builder.fixed("surface_water_potential", "MPa");
    for ([_][]const u8{ "active_surface_depth", "active_layer_depth_below_surface", "water_table_depth_below_surface" }) |name| try builder.fixed(name, "m");
    return builder.finish();
}

pub fn dailyNitrogen(allocator: std.mem.Allocator, layer_count: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    for ([_][]const u8{ "residue_nitrogen", "organic_nitrogen", "fertilizer_nitrogen", "nitrogen_sink", "ammonium_nitrogen", "nitrate_nitrogen", "dissolved_organic_nitrogen_runoff", "dissolved_organic_nitrogen_drainage", "dissolved_inorganic_nitrogen_runoff", "dissolved_inorganic_nitrogen_drainage", "daily_soil_nitrous_oxide_exchange", "daily_soil_ammonia_exchange", "dissolved_dinitrogen_storage", "total_organic_nitrogen" }) |name| try builder.fixed(name, "g N m-2");
    try builder.layers("ammonium_nitrogen_concentration", "g N m-3", layer_count);
    try builder.layers("nitrate_plus_nitrite_nitrogen_concentration", "g N m-3", layer_count);
    try builder.fixed("surface_ammonium_nitrogen_concentration", "g N m-3");
    for ([_][]const u8{ "soil_fire_nitrogen_loss", "harvested_nitrogen", "net_microbial_nitrogen_mineralization", "fire_nitrogen_emission", "daily_soil_dinitrogen_exchange" }) |name| try builder.fixed(name, "g N m-2");
    return builder.finish();
}

pub fn dailyPhosphorus(allocator: std.mem.Allocator, layer_count: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    for ([_][]const u8{ "residue_phosphorus", "organic_phosphorus", "fertilizer_phosphorus", "phosphorus_sink", "phosphate_phosphorus", "dissolved_organic_phosphorus_runoff", "dissolved_organic_phosphorus_drainage", "dissolved_inorganic_phosphorus_runoff", "dissolved_inorganic_phosphorus_drainage", "precipitated_phosphorus", "total_organic_phosphorus", "fire_phosphorus_emission" }) |name| try builder.fixed(name, "g P m-2");
    try builder.layers("aqueous_phosphate_phosphorus_concentration", "g P m-3", layer_count);
    try builder.layers("sorbed_phosphate_phosphorus_concentration", "g P m-3", layer_count);
    try builder.fixed("surface_aqueous_phosphate_phosphorus_concentration", "g P m-3");
    try builder.fixed("surface_sorbed_phosphate_phosphorus_concentration", "g P m-3");
    for ([_][]const u8{ "soil_fire_phosphorus_loss", "soluble_phosphate_storage", "harvested_phosphorus", "net_microbial_phosphate_mineralization", "reserved_zero_49", "reserved_zero_50" }) |name| try builder.fixed(name, "g P m-2");
    return builder.finish();
}

pub fn dailyHeat(allocator: std.mem.Allocator, temperature_layers: usize, conductivity_layers: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.fixed("total_radiation", "MJ m-2");
    try builder.fixed("maximum_air_temperature", "degC");
    try builder.fixed("minimum_air_temperature", "degC");
    try builder.fixed("maximum_atmospheric_vapor_pressure", "kPa");
    try builder.fixed("minimum_atmospheric_vapor_pressure", "kPa");
    try builder.fixed("cumulative_wind_distance", "km");
    try builder.fixed("total_precipitation", "mm");
    for (0..temperature_layers) |layer| {
        const maximum = try std.fmt.allocPrint(allocator, "maximum_soil_temperature_layer_{d}", .{layer + 1});
        defer allocator.free(maximum);
        try builder.fixed(maximum, "degC");
        const minimum = try std.fmt.allocPrint(allocator, "minimum_soil_temperature_layer_{d}", .{layer + 1});
        defer allocator.free(minimum);
        try builder.fixed(minimum, "degC");
    }
    try builder.fixed("surface_maximum_soil_temperature", "degC");
    try builder.fixed("surface_minimum_soil_temperature", "degC");
    try builder.layers("electrical_conductivity", "dS m-1", conductivity_layers);
    try builder.fixed("ionic_outflow", "mol m-2");
    return builder.finish();
}

const Builder = struct {
    allocator: std.mem.Allocator,
    variables: std.ArrayList(Variable) = .empty,

    fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Builder) void {
        for (self.variables.items) |variable| self.allocator.free(variable.name);
        self.variables.deinit(self.allocator);
    }

    fn fixed(self: *Builder, name: []const u8, unit: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.variables.append(self.allocator, .{ .name = owned_name, .unit = unit });
    }

    fn layers(self: *Builder, prefix: []const u8, unit: []const u8, count: usize) !void {
        for (0..count) |layer| {
            const name = try std.fmt.allocPrint(self.allocator, "{s}_layer_{d}", .{ prefix, layer + 1 });
            errdefer self.allocator.free(name);
            try self.variables.append(self.allocator, .{ .name = name, .unit = unit });
        }
    }

    fn finish(self: *Builder) !Catalog {
        const variables = try self.variables.toOwnedSlice(self.allocator);
        return .{ .allocator = self.allocator, .variables = variables };
    }
};

test "runtime OUTSH catalogs reproduce historical counts and expand beyond them" {
    var water_catalog = try water(std.testing.allocator, 20);
    defer water_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 50), water_catalog.variables.len);

    var heat_catalog = try heat(std.testing.allocator, 20);
    defer heat_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 37), heat_catalog.variables.len);

    var carbon_catalog = try carbon(std.testing.allocator, 14, 15, 15);
    defer carbon_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 50), carbon_catalog.variables.len);

    var nitrogen_catalog = try nitrogen(std.testing.allocator, 15, 15);
    defer nitrogen_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 37), nitrogen_catalog.variables.len);

    var expanded = try water(std.testing.allocator, 31);
    defer expanded.deinit();
    try std.testing.expectEqual(@as(usize, 72), expanded.variables.len);
    try std.testing.expectEqualStrings("volumetric_liquid_water_fraction_layer_31", expanded.variables[36].name);
}

test "runtime OUTSD catalogs reproduce all historical fifty-choice families" {
    var c = try dailyCarbon(std.testing.allocator, 14);
    defer c.deinit();
    var w = try dailyWater(std.testing.allocator, 13, 13, 10);
    defer w.deinit();
    var n = try dailyNitrogen(std.testing.allocator, 15);
    defer n.deinit();
    var p = try dailyPhosphorus(std.testing.allocator, 15);
    defer p.deinit();
    var h = try dailyHeat(std.testing.allocator, 14, 12);
    defer h.deinit();
    try std.testing.expectEqual(@as(usize, 50), c.variables.len);
    try std.testing.expectEqual(@as(usize, 50), w.variables.len);
    try std.testing.expectEqual(@as(usize, 50), n.variables.len);
    try std.testing.expectEqual(@as(usize, 50), p.variables.len);
    try std.testing.expectEqual(@as(usize, 50), h.variables.len);
    try std.testing.expectEqualStrings(
        "dS m-1",
        h.variables[37].unit,
    );
    var expanded = try dailyNitrogen(std.testing.allocator, 24);
    defer expanded.deinit();
    try std.testing.expectEqual(@as(usize, 68), expanded.variables.len);

    var expanded_water = try dailyWater(std.testing.allocator, 17, 17, 17);
    defer expanded_water.deinit();
    try std.testing.expectEqual(@as(usize, 65), expanded_water.variables.len);
    try std.testing.expectEqualStrings("total_water_potential_layer_17", expanded_water.variables[58].name);
}

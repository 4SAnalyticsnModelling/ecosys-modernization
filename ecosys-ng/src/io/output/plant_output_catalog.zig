const std = @import("std");
const Variable = @import("record.zig").Variable;

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    variables: []Variable,

    pub fn deinit(self: *Catalog) void {
        for (self.variables) |variable| self.allocator.free(variable.name);
        self.allocator.free(self.variables);
        self.* = undefined;
    }
};

pub fn carbon(allocator: std.mem.Allocator) !Catalog {
    return fixedCatalog(allocator, &.{
        .{ .name = "canopy_carbon_dioxide_flux", .unit = "umol m-2 s-1" },
        .{ .name = "gross_primary_productivity", .unit = "g C m-2 h-1" },
        .{ .name = "signed_aboveground_respiration", .unit = "g C m-2 h-1" },
        .{ .name = "nonstructural_carbon_concentration", .unit = "model_concentration" },
        .{ .name = "stomatal_resistance", .unit = "s m-1" },
        .{ .name = "boundary_layer_resistance", .unit = "s m-1" },
        .{ .name = "leaf_area_index", .unit = "m2 m-2" },
    });
}

pub fn water(allocator: std.mem.Allocator, root_layer_count: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.fixed("canopy_total_water_potential", "MPa");
    try builder.fixed("canopy_turgor_potential", "MPa");
    try builder.fixed("stomatal_resistance", "s m-1");
    try builder.fixed("boundary_layer_resistance", "s m-1");
    try builder.fixed("transpiration", "mm");
    try builder.fixed("oxygen_stress_factor", "fraction");
    try builder.layers("primary_root_total_water_potential", "MPa", root_layer_count);
    return builder.finish();
}

pub fn nitrogen(allocator: std.mem.Allocator, root_layer_count: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.fixed("ammonium_uptake", "g N m-2 h-1");
    try builder.fixed("nitrate_uptake", "g N m-2 h-1");
    try builder.fixed("nitrogen_fixation", "g N m-2 h-1");
    try builder.fixed("nonstructural_nitrogen_concentration", "model_concentration");
    try builder.fixed("ammonia_flux", "g N m-2 h-1");
    try builder.layers("ammonium_uptake", "g N m-2 h-1", root_layer_count);
    try builder.layers("nitrate_uptake", "g N m-2 h-1", root_layer_count);
    return builder.finish();
}

pub fn phosphorus(allocator: std.mem.Allocator, root_layer_count: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.fixed("phosphate_uptake", "g P m-2 h-1");
    try builder.fixed("nonstructural_phosphorus_concentration", "model_concentration");
    try builder.layers("phosphate_uptake", "g P m-2 h-1", root_layer_count);
    return builder.finish();
}

pub fn heat(allocator: std.mem.Allocator) !Catalog {
    return fixedCatalog(allocator, &.{
        .{ .name = "canopy_net_radiation", .unit = "W m-2" },
        .{ .name = "canopy_latent_heat_flux", .unit = "W m-2" },
        .{ .name = "canopy_sensible_heat_flux", .unit = "W m-2" },
        .{ .name = "canopy_storage_heat_flux", .unit = "W m-2" },
        .{ .name = "canopy_temperature", .unit = "degC" },
        .{ .name = "temperature_function", .unit = "fraction" },
        .{ .name = "standing_dead_temperature", .unit = "degC" },
    });
}

pub fn dailyCarbon(allocator: std.mem.Allocator, root_layer_count: usize) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    for ([_][]const u8{ "shoot_carbon", "leaf_carbon", "sheath_carbon", "stalk_carbon", "reserve_carbon", "husk_and_ear_carbon", "grain_carbon", "root_carbon", "nodule_carbon", "vegetative_residue_carbon", "grain_number", "projected_leaf_area", "daily_net_carbon_change", "cumulative_carbon_uptake", "cumulative_carbon_sink", "initial_cumulative_carbon_sink", "signed_total_respiration_carbon", "signed_aboveground_respiration_carbon" }) |name| try builder.fixed(name, if (std.mem.eql(u8, name, "grain_number")) "number m-2" else if (std.mem.eql(u8, name, "projected_leaf_area")) "m2 m-2" else "g C m-2");
    try builder.fixed("carbon_pollination_factor", "fraction");
    try builder.fixed("harvested_carbon", "g C m-2");
    try builder.layers("root_length_density", "m m-3 plant m-2", root_layer_count);
    for ([_][]const u8{ "carbon_balance", "storage_carbon", "carbon_oxidation_flux", "reserved_zero", "net_primary_productivity", "canopy_height", "plant_population" }) |name| try builder.fixed(name, if (std.mem.eql(u8, name, "canopy_height")) "m" else if (std.mem.eql(u8, name, "plant_population")) "plants m-2" else "g C m-2");
    return builder.finish();
}

pub fn dailyWater(allocator: std.mem.Allocator) !Catalog {
    return fixedCatalog(allocator, &.{
        .{ .name = "transpiration", .unit = "mm" },              .{ .name = "cold_or_water_stress", .unit = "h" },
        .{ .name = "oxygen_stress_factor", .unit = "fraction" }, .{ .name = "plant_water_storage", .unit = "mm" },
    });
}

pub fn dailyNitrogen(allocator: std.mem.Allocator) !Catalog {
    return dailyNutrient(allocator, "N", true);
}

pub fn dailyPhosphorus(allocator: std.mem.Allocator) !Catalog {
    return dailyNutrient(allocator, "P", false);
}

fn dailyNutrient(allocator: std.mem.Allocator, element: []const u8, include_nitrogen_extras: bool) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    for ([_][]const u8{ "shoot", "leaf", "sheath", "stalk", "reserve", "husk_and_ear", "grain", "root", "nodule", "vegetative_residue", "cumulative_uptake", "cumulative_sink" }) |name| {
        const owned = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ name, element });
        defer allocator.free(owned);
        try builder.fixed(owned, if (std.mem.eql(u8, element, "N")) "g N m-2" else "g P m-2");
    }
    if (include_nitrogen_extras) try builder.fixed("nitrogen_fixation", "g N m-2");
    try builder.fixed("pollination_factor", "fraction");
    if (include_nitrogen_extras) {
        try builder.fixed("leaf_nitrogen_to_carbon_ratio", "g N g-1 C");
        try builder.fixed("phosphorus_pollination_factor", "fraction");
    }
    try builder.fixed("leaf_phosphorus_to_carbon_ratio", "g P g-1 C");
    if (include_nitrogen_extras) try builder.fixed("ammonia_exchange", "g N m-2");
    for ([_][]const u8{ "harvested", "balance", "storage", "oxidation_flux", "aboveground_litter_sink" }) |name| {
        const owned = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ name, element });
        defer allocator.free(owned);
        try builder.fixed(owned, if (std.mem.eql(u8, element, "N")) "g N m-2" else "g P m-2");
    }
    return builder.finish();
}

pub fn dailyDevelopment(allocator: std.mem.Allocator) !Catalog {
    return fixedCatalog(allocator, &.{
        .{ .name = "development_phase", .unit = "enum_code" },              .{ .name = "branch_count", .unit = "count" },
        .{ .name = "main_branch_stage", .unit = "stage" },                  .{ .name = "development_feedback", .unit = "fraction" },
        .{ .name = "leaf_nitrogen_to_carbon_ratio", .unit = "g N g-1 C" },  .{ .name = "leaf_phosphorus_to_carbon_ratio", .unit = "g P g-1 C" },
        .{ .name = "minimum_daily_canopy_water_potential", .unit = "MPa" }, .{ .name = "oxygen_stress_factor", .unit = "fraction" },
        .{ .name = "temperature_function", .unit = "fraction" },
    });
}

fn fixedCatalog(allocator: std.mem.Allocator, variables: []const Variable) !Catalog {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    for (variables) |variable| try builder.fixed(variable.name, variable.unit);
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
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.variables.append(self.allocator, .{ .name = owned, .unit = unit });
    }

    fn layers(self: *Builder, prefix: []const u8, unit: []const u8, count: usize) !void {
        for (0..count) |layer| {
            const name = try std.fmt.allocPrint(self.allocator, "{s}_layer_{d}", .{ prefix, layer + 1 });
            errdefer self.allocator.free(name);
            try self.variables.append(self.allocator, .{ .name = name, .unit = unit });
        }
    }

    fn finish(self: *Builder) !Catalog {
        return .{ .allocator = self.allocator, .variables = try self.variables.toOwnedSlice(self.allocator) };
    }
};

test "OUTPH catalogs reproduce legacy counts and remove fifteen-layer ceiling" {
    var carbon_catalog = try carbon(std.testing.allocator);
    defer carbon_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 7), carbon_catalog.variables.len);
    var water_catalog = try water(std.testing.allocator, 15);
    defer water_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 21), water_catalog.variables.len);
    var nitrogen_catalog = try nitrogen(std.testing.allocator, 15);
    defer nitrogen_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 35), nitrogen_catalog.variables.len);
    var phosphorus_catalog = try phosphorus(std.testing.allocator, 15);
    defer phosphorus_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 17), phosphorus_catalog.variables.len);
    var heat_catalog = try heat(std.testing.allocator);
    defer heat_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 7), heat_catalog.variables.len);
    var expanded = try nitrogen(std.testing.allocator, 24);
    defer expanded.deinit();
    try std.testing.expectEqual(@as(usize, 53), expanded.variables.len);
    try std.testing.expectEqualStrings("nitrate_uptake_layer_24", expanded.variables[52].name);
}

test "OUTPD catalogs reproduce source counts and expand root layers" {
    var c = try dailyCarbon(std.testing.allocator, 15);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 42), c.variables.len);
    var expanded = try dailyCarbon(std.testing.allocator, 24);
    defer expanded.deinit();
    try std.testing.expectEqual(@as(usize, 51), expanded.variables.len);
    var w = try dailyWater(std.testing.allocator);
    defer w.deinit();
    var n = try dailyNitrogen(std.testing.allocator);
    defer n.deinit();
    var p = try dailyPhosphorus(std.testing.allocator);
    defer p.deinit();
    var h = try dailyDevelopment(std.testing.allocator);
    defer h.deinit();
    try std.testing.expectEqual(@as(usize, 4), w.variables.len);
    try std.testing.expectEqual(@as(usize, 23), n.variables.len);
    try std.testing.expectEqual(@as(usize, 19), p.variables.len);
    try std.testing.expectEqual(@as(usize, 9), h.variables.len);
}

const std = @import("std");
const RootLitter = @import("plant_root_metabolism.zig").RootLitter;
const SoilOrganic = @import("../../soil/organic/initialization.zig");

pub const substrate_kind_count: usize = 2;
pub const kinetic_component_count: usize = 4;

pub const LayerInput = struct {
    litter: RootLitter = std.mem.zeroes(RootLitter),

    pub fn add(self: *LayerInput, litter: RootLitter) !void {
        inline for (@typeInfo(RootLitter).@"struct".fields) |field| {
            for (&@field(self.litter, field.name), @field(litter, field.name)) |*total, value| {
                if (!std.math.isFinite(value) or value < 0) return error.InvalidRootLitterfall;
                total.* += value;
                if (!std.math.isFinite(total.*)) return error.NonFiniteRootLitterfall;
            }
        }
    }
};

/// Prevalidates the exact GROSUB CSNC/ZSNC/PSNC state_update. Substrates zero
/// and one are coarse and fine plant litter; components one through four map
/// to structural fractions zero through three. Fire-derived charcoal is not
/// modified by ordinary root litterfall.
pub fn validateStateUpdate(soil: *const SoilOrganic.State, layer: usize, input: LayerInput) !void {
    if (layer >= soil.layer_count) return error.RootLitterfallLayerOutOfBounds;
    inline for (.{ 0, 1 }) |substrate| for (0..kinetic_component_count) |kinetic| {
        const prefix = if (substrate == 0) "woody_" else "nonwoody_";
        const pool = soil.structural[(layer * SoilOrganic.substrate_count + substrate) * SoilOrganic.structural_fraction_count + kinetic];
        inline for (.{
            pool.carbon_g_c + @field(input.litter, prefix ++ "carbon_g_c")[kinetic],
            pool.nitrogen_g_n + @field(input.litter, prefix ++ "nitrogen_g_n")[kinetic],
            pool.phosphorus_g_p + @field(input.litter, prefix ++ "phosphorus_g_p")[kinetic],
        }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootLitterfallStateUpdate;
    };
}

/// Must only be called after `validateStateUpdate`; it is deliberately
/// infallible so a prevalidated root-pool state_update and soil state_update form one
/// transaction without a failure point between them.
pub fn publishValidated(soil: *SoilOrganic.State, layer: usize, input: LayerInput) void {
    inline for (.{ 0, 1 }) |substrate| for (0..kinetic_component_count) |kinetic| {
        const prefix = if (substrate == 0) "woody_" else "nonwoody_";
        const pool = &soil.structural[(layer * SoilOrganic.substrate_count + substrate) * SoilOrganic.structural_fraction_count + kinetic];
        pool.carbon_g_c += @field(input.litter, prefix ++ "carbon_g_c")[kinetic];
        pool.nitrogen_g_n += @field(input.litter, prefix ++ "nitrogen_g_n")[kinetic];
        pool.phosphorus_g_p += @field(input.litter, prefix ++ "phosphorus_g_p")[kinetic];
    };
}

test "root litterfall publishes coarse and fine kinetics without touching charcoal" {
    var soil = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    var input: LayerInput = .{};
    var litter = std.mem.zeroes(RootLitter);
    litter.woody_carbon_g_c = .{ 1, 2, 3, 4 };
    litter.nonwoody_nitrogen_g_n = .{ 0.1, 0.2, 0.3, 0.4 };
    litter.nonwoody_phosphorus_g_p = .{ 0.01, 0.02, 0.03, 0.04 };
    try input.add(litter);
    try validateStateUpdate(&soil, 0, input);
    publishValidated(&soil, 0, input);
    try std.testing.expectEqual(@as(f64, 1), soil.structural[0].carbon_g_c);
    const fine = SoilOrganic.structural_fraction_count;
    try std.testing.expectEqual(@as(f64, 0.1), soil.structural[fine].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 0), soil.structural[SoilOrganic.structural_fraction_count - 1].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), soil.structural[fine + SoilOrganic.structural_fraction_count - 1].carbon_g_c);
}

test "root litterfall rejects overflow before changing soil" {
    var soil = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    soil.structural[0].carbon_g_c = std.math.floatMax(f64);
    var input: LayerInput = .{};
    var litter = std.mem.zeroes(RootLitter);
    litter.woody_carbon_g_c[0] = std.math.floatMax(f64);
    try input.add(litter);
    try std.testing.expectError(error.NonFiniteRootLitterfallStateUpdate, validateStateUpdate(&soil, 0, input));
    try std.testing.expectEqual(std.math.floatMax(f64), soil.structural[0].carbon_g_c);
}

const std = @import("std");
const canopy = @import("../../canopy/photosynthesis/photosynthesis.zig");
const root = @import("../root/plant_root_metabolism.zig");

pub const ElementalMass = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

pub const Result = struct {
    aboveground: ElementalMass,
    belowground: ElementalMass,
};

/// Reconstructs one plant's EXTRACT `HCSNC/HZSNC/HPSNC` state_update from the
/// accepted natural shoot/root and management litter owners. The natural shoot
/// producer includes standing-dead litter before this reduction, matching
/// GROSUB 12598--12653; management retains all three plant-resolved C/N/P
/// fields. Traceability: `extract.f` lines 46--69 and `grosub.f` lines
/// 10842--10850, 12598--12653.
pub fn totals(
    shoot: canopy.SenescenceProducts,
    roots: root.RootLitter,
    management_shoot: ElementalMass,
) !Result {
    inline for (@typeInfo(ElementalMass).@"struct".fields) |field| {
        const value = @field(management_shoot, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidManagementLitterStateUpdate;
    }
    var result: Result = .{
        .aboveground = management_shoot,
        .belowground = .{},
    };
    for (0..shoot.woody_carbon_g.len) |kinetic| {
        result.aboveground.carbon_g_c +=
            shoot.woody_carbon_g[kinetic] +
            shoot.nonwoody_carbon_g[kinetic];
        result.aboveground.nitrogen_g_n +=
            shoot.woody_nitrogen_g[kinetic] +
            shoot.nonwoody_nitrogen_g[kinetic];
        result.aboveground.phosphorus_g_p +=
            shoot.woody_phosphorus_g[kinetic] +
            shoot.nonwoody_phosphorus_g[kinetic];
        result.belowground.carbon_g_c +=
            roots.woody_carbon_g_c[kinetic] +
            roots.nonwoody_carbon_g_c[kinetic];
        result.belowground.nitrogen_g_n +=
            roots.woody_nitrogen_g_n[kinetic] +
            roots.nonwoody_nitrogen_g_n[kinetic];
        result.belowground.phosphorus_g_p +=
            roots.woody_phosphorus_g_p[kinetic] +
            roots.nonwoody_phosphorus_g_p[kinetic];
        try validateResult(result);
    }
    return result;
}

fn validateResult(result: Result) !void {
    inline for (.{ result.aboveground, result.belowground }) |mass|
        inline for (@typeInfo(ElementalMass).@"struct".fields) |field| {
            const value = @field(mass, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidPlantLitterfallStateUpdate;
        };
}

test "EXTRACT litter state_update includes accepted management shoot C N P" {
    var shoot: canopy.SenescenceProducts = .{};
    var roots = std.mem.zeroes(root.RootLitter);
    shoot.woody_carbon_g[0] = 2;
    shoot.nonwoody_carbon_g[0] = 3;
    shoot.woody_nitrogen_g[0] = 0.2;
    shoot.nonwoody_phosphorus_g[0] = 0.03;
    roots.woody_carbon_g_c[0] = 4;
    roots.nonwoody_carbon_g_c[0] = 1;
    roots.woody_nitrogen_g_n[0] = 0.4;
    roots.nonwoody_phosphorus_g_p[0] = 0.01;
    const result = try totals(shoot, roots, .{
        .carbon_g_c = 7,
        .nitrogen_g_n = 0.7,
        .phosphorus_g_p = 0.07,
    });
    try std.testing.expectEqual(@as(f64, 12), result.aboveground.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 5), result.belowground.carbon_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), result.aboveground.nitrogen_g_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result.aboveground.phosphorus_g_p, 1e-15);
    try std.testing.expectEqual(@as(f64, 0.01), result.belowground.phosphorus_g_p);
}

test "late invalid kinetic pool rejects the complete state_update" {
    var shoot: canopy.SenescenceProducts = .{};
    const roots = std.mem.zeroes(root.RootLitter);
    shoot.woody_carbon_g[shoot.woody_carbon_g.len - 1] = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidPlantLitterfallStateUpdate,
        totals(shoot, roots, .{ .carbon_g_c = 3 }),
    );
}

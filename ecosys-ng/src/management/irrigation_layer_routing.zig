const std = @import("std");
const irrigation = @import("irrigation_schedule.zig");

pub const dissolved_species_count = 11;

/// Heap-owned hourly irrigation loads. Surface carriers remain indexed by
/// cell; subsurface carriers use the runtime cell×soil-layer layout but are
/// never populated by `accumulate` (see IRRIGATION-SUBSURFACE-DEAD-CODE-001):
/// the Fortran oracle's depth-based surface/subsurface split is permanently
/// disabled, so every irrigation event is routed to the surface carriers
/// regardless of `application_depth_m`. The subsurface storage remains here
/// only as the destination for a future, independently validated enhancement.
/// All chemistry is extensive, so simultaneous events can be state_updateted
/// without concentration averaging.
pub const Loads = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    soil_layer_capacity: usize,
    surface_water_m3: []f64,
    subsurface_water_m3: []f64,
    surface_dissolved_mass_g: []f64,
    subsurface_dissolved_mass_g: []f64,
    surface_hydrogen_mol: []f64,
    subsurface_hydrogen_mol: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        soil_layer_capacity: usize,
    ) !Loads {
        if (cell_count == 0 or soil_layer_capacity == 0)
            return error.EmptyIrrigationRoutingDomain;
        const layer_count = try std.math.mul(
            usize,
            cell_count,
            soil_layer_capacity,
        );
        const surface_species_count = try std.math.mul(
            usize,
            cell_count,
            dissolved_species_count,
        );
        const subsurface_species_count = try std.math.mul(
            usize,
            layer_count,
            dissolved_species_count,
        );
        var result: Loads = .{
            .allocator = allocator,
            .cell_count = cell_count,
            .soil_layer_capacity = soil_layer_capacity,
            .surface_water_m3 = try allocator.alloc(f64, cell_count),
            .subsurface_water_m3 = undefined,
            .surface_dissolved_mass_g = undefined,
            .subsurface_dissolved_mass_g = undefined,
            .surface_hydrogen_mol = undefined,
            .subsurface_hydrogen_mol = undefined,
        };
        errdefer allocator.free(result.surface_water_m3);
        result.subsurface_water_m3 = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(result.subsurface_water_m3);
        result.surface_dissolved_mass_g =
            try allocator.alloc(f64, surface_species_count);
        errdefer allocator.free(result.surface_dissolved_mass_g);
        result.subsurface_dissolved_mass_g =
            try allocator.alloc(f64, subsurface_species_count);
        errdefer allocator.free(result.subsurface_dissolved_mass_g);
        result.surface_hydrogen_mol = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.surface_hydrogen_mol);
        result.subsurface_hydrogen_mol =
            try allocator.alloc(f64, layer_count);
        result.reset();
        return result;
    }

    pub fn deinit(self: *Loads) void {
        self.allocator.free(self.subsurface_hydrogen_mol);
        self.allocator.free(self.surface_hydrogen_mol);
        self.allocator.free(self.subsurface_dissolved_mass_g);
        self.allocator.free(self.surface_dissolved_mass_g);
        self.allocator.free(self.subsurface_water_m3);
        self.allocator.free(self.surface_water_m3);
        self.* = undefined;
    }

    pub fn reset(self: *Loads) void {
        @memset(self.surface_water_m3, 0);
        @memset(self.subsurface_water_m3, 0);
        @memset(self.surface_dissolved_mass_g, 0);
        @memset(self.subsurface_dissolved_mass_g, 0);
        @memset(self.surface_hydrogen_mol, 0);
        @memset(self.subsurface_hydrogen_mol, 0);
    }

    /// Applies a climate multiplier to the complete extensive irrigation
    /// transaction. Preflight makes overflow/non-finite failure atomic.
    pub fn scale(self: *Loads, multiplier: f64) !void {
        if (!std.math.isFinite(multiplier) or multiplier < 0)
            return error.InvalidIrrigationMultiplier;
        inline for (.{
            self.surface_water_m3,
            self.subsurface_water_m3,
            self.surface_dissolved_mass_g,
            self.subsurface_dissolved_mass_g,
            self.surface_hydrogen_mol,
            self.subsurface_hydrogen_mol,
        }) |values| {
            for (values) |value| {
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidIrrigationLoad;
                if (!std.math.isFinite(value * multiplier))
                    return error.IrrigationRoutingOverflow;
            }
        }
        inline for (.{
            self.surface_water_m3,
            self.subsurface_water_m3,
            self.surface_dissolved_mass_g,
            self.subsurface_dissolved_mass_g,
            self.surface_hydrogen_mol,
            self.subsurface_hydrogen_mol,
        }) |values| {
            for (values) |*value| value.* *= multiplier;
        }
    }

    pub fn accumulate(
        self: *Loads,
        cell: usize,
        active_layer_count: usize,
        layer_thickness_m: []const f64,
        cell_area_m2: f64,
        water_depth_m: f64,
        application_depth_m: f64,
        chemistry: irrigation.WaterChemistry_g_per_m3,
    ) !void {
        if (cell >= self.cell_count or
            layer_thickness_m.len != self.soil_layer_capacity)
            return error.IrrigationRoutingDimensionMismatch;
        if (active_layer_count == 0 or
            active_layer_count > self.soil_layer_capacity)
            return error.InvalidActiveIrrigationLayerCount;
        inline for (.{ cell_area_m2, water_depth_m, application_depth_m }) |value|
            if (!std.math.isFinite(value))
                return error.NonFiniteIrrigationRoutingInput;
        if (cell_area_m2 <= 0 or water_depth_m < 0 or application_depth_m < 0)
            return error.InvalidIrrigationRoutingInput;
        const concentrations = chemistryValues(chemistry);
        for (concentrations) |concentration|
            if (!std.math.isFinite(concentration) or concentration < 0)
                return error.InvalidIrrigationChemistry;
        if (!std.math.isFinite(chemistry.ph) or
            chemistry.ph < 0 or chemistry.ph > 14)
            return error.InvalidIrrigationChemistry;
        var cumulative_depth_m: f64 = 0;
        for (layer_thickness_m[0..active_layer_count]) |thickness_m| {
            if (!std.math.isFinite(thickness_m) or thickness_m <= 0)
                return error.InvalidIrrigationLayerThickness;
            cumulative_depth_m += thickness_m;
            if (!std.math.isFinite(cumulative_depth_m))
                return error.IrrigationRoutingOverflow;
        }
        if (water_depth_m == 0) return;
        const water_volume_m3 = water_depth_m * cell_area_m2;
        if (!std.math.isFinite(water_volume_m3))
            return error.IrrigationRoutingOverflow;
        const hydrogen_mol =
            water_volume_m3 * 1000.0 * std.math.pow(f64, 10.0, -chemistry.ph);
        if (!std.math.isFinite(hydrogen_mol))
            return error.IrrigationRoutingOverflow;

        // IRRIGATION-SUBSURFACE-DEAD-CODE-001: the Fortran oracle's
        // depth-based surface/subsurface split (`WDPTHD.LE.CDPTH(...)` at
        // wthr.f:308-315) is permanently commented out, so PRECUI (and
        // therefore PRECU) is unconditionally 0.0 there -- every irrigation
        // record is applied at the surface regardless of
        // WDPTHI/application_depth_m. Match that behavior exactly here:
        // always deposit into the surface carriers. `application_depth_m`
        // is still validated above as a schema field but deliberately does
        // not select a destination, so `subsurface_water_m3` and its
        // dissolved/hydrogen counterparts stay at zero, keeping
        // `subsurface_irrigation_chemistry.zig`/`subsurface_irrigation_heat.zig`
        // inert by construction (mirroring PRECU=0.0 in the oracle) unless
        // this routing is deliberately promoted as a validated enhancement
        // per MIGRATION.md/docs/model_changes.md.
        const next_water = self.surface_water_m3[cell] + water_volume_m3;
        const next_hydrogen =
            self.surface_hydrogen_mol[cell] + hydrogen_mol;
        if (!std.math.isFinite(next_water) or
            !std.math.isFinite(next_hydrogen))
            return error.IrrigationRoutingOverflow;
        const first = cell * dissolved_species_count;
        var candidate = [_]f64{0} ** dissolved_species_count;
        for (&candidate, concentrations, 0..) |*next, concentration, species| {
            next.* = self.surface_dissolved_mass_g[first + species] +
                water_volume_m3 * concentration;
            if (!std.math.isFinite(next.*))
                return error.IrrigationRoutingOverflow;
        }
        self.surface_water_m3[cell] = next_water;
        self.surface_hydrogen_mol[cell] = next_hydrogen;
        @memcpy(
            self.surface_dissolved_mass_g[first..][0..dissolved_species_count],
            &candidate,
        );
    }
};

pub fn layerAtDepth(
    active_layer_thickness_m: []const f64,
    application_depth_m: f64,
) !usize {
    if (active_layer_thickness_m.len == 0)
        return error.EmptyActiveIrrigationProfile;
    if (!std.math.isFinite(application_depth_m) or application_depth_m <= 0)
        return error.InvalidSubsurfaceIrrigationDepth;

    var cumulative_depth_m: f64 = 0;
    for (active_layer_thickness_m, 0..) |thickness_m, layer| {
        if (!std.math.isFinite(thickness_m) or thickness_m <= 0)
            return error.InvalidIrrigationLayerThickness;
        cumulative_depth_m += thickness_m;
        if (!std.math.isFinite(cumulative_depth_m))
            return error.IrrigationRoutingOverflow;
        if (cumulative_depth_m >= application_depth_m) return layer;
    }
    return error.SubsurfaceIrrigationDepthBelowProfile;
}

fn chemistryValues(
    water: irrigation.WaterChemistry_g_per_m3,
) [dissolved_species_count]f64 {
    return .{
        water.ammonium_nitrogen,
        water.nitrate_nitrogen,
        water.phosphate_phosphorus,
        water.aluminum,
        water.iron,
        water.calcium,
        water.magnesium,
        water.sodium,
        water.potassium,
        water.sulfate_sulfur,
        water.chloride,
    };
}

test "irrigation routing always uses surface carriers regardless of application depth (IRRIGATION-SUBSURFACE-DEAD-CODE-001)" {
    var loads = try Loads.init(std.testing.allocator, 1, 7);
    defer loads.deinit();
    const chemistry: irrigation.WaterChemistry_g_per_m3 = .{
        .ph = 7,
        .ammonium_nitrogen = 1,
        .nitrate_nitrogen = 2,
        .phosphate_phosphorus = 3,
        .aluminum = 4,
        .iron = 5,
        .calcium = 6,
        .magnesium = 7,
        .sodium = 8,
        .potassium = 9,
        .sulfate_sulfur = 10,
        .chloride = 11,
    };
    const thickness = [_]f64{ 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35 };
    try loads.accumulate(0, 7, &thickness, 10, 0.001, 0, chemistry);
    try loads.accumulate(0, 7, &thickness, 10, 0.002, 0.12, chemistry);
    try loads.accumulate(0, 7, &thickness, 10, 0.003, 0.90, chemistry);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.06),
        loads.surface_water_m3[0],
        1.0e-14,
    );
    for (loads.subsurface_water_m3) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.24),
        loads.surface_dissolved_mass_g[3],
        1.0e-14,
    );
    for (loads.subsurface_dissolved_mass_g) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
    for (loads.subsurface_hydrogen_mol) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
}

test "irrigation event with application depth beyond the soil profile still succeeds via the surface route" {
    var loads = try Loads.init(std.testing.allocator, 2, 3);
    defer loads.deinit();
    const chemistry = std.mem.zeroInit(
        irrigation.WaterChemistry_g_per_m3,
        .{ .ph = 6 },
    );
    // Legacy (wthr.f:308-315) never routes below the surface, so an
    // application depth deeper than the whole soil profile is not an error.
    try loads.accumulate(
        1,
        2,
        &.{ 0.1, 0.2, 9.0 },
        5,
        0.004,
        5,
        chemistry,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.02),
        loads.surface_water_m3[1],
        1.0e-14,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        loads.subsurface_water_m3[1 * 3 + 1],
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        loads.subsurface_hydrogen_mol[1 * 3 + 1],
    );
}

test "climate scaling preserves every irrigation concentration and is atomic" {
    var loads = try Loads.init(std.testing.allocator, 1, 2);
    defer loads.deinit();
    const chemistry: irrigation.WaterChemistry_g_per_m3 = .{
        .ph = 6,
        .ammonium_nitrogen = 2,
        .nitrate_nitrogen = 3,
        .phosphate_phosphorus = 5,
        .aluminum = 7,
        .iron = 11,
        .calcium = 13,
        .magnesium = 17,
        .sodium = 19,
        .potassium = 23,
        .sulfate_sulfur = 29,
        .chloride = 31,
    };
    try loads.accumulate(0, 2, &.{ 0.1, 0.2 }, 10, 0.01, 0, chemistry);
    const water_before = loads.surface_water_m3[0];
    const mass_before = loads.surface_dissolved_mass_g[0];
    try loads.scale(1.5);
    try std.testing.expectEqual(water_before * 1.5, loads.surface_water_m3[0]);
    try std.testing.expectEqual(mass_before * 1.5, loads.surface_dissolved_mass_g[0]);
    try std.testing.expectEqual(
        mass_before / water_before,
        loads.surface_dissolved_mass_g[0] / loads.surface_water_m3[0],
    );

    const retained_water = loads.surface_water_m3[0];
    const retained_mass = loads.surface_dissolved_mass_g[0];
    loads.surface_hydrogen_mol[0] = std.math.inf(f64);
    try std.testing.expectError(error.InvalidIrrigationLoad, loads.scale(2));
    try std.testing.expectEqual(retained_water, loads.surface_water_m3[0]);
    try std.testing.expectEqual(retained_mass, loads.surface_dissolved_mass_g[0]);
}

test "subsurface irrigation layer scan uses active cumulative bottoms" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try layerAtDepth(&.{ 0.05, 0.10, 0.20 }, 0.05),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try layerAtDepth(&.{ 0.05, 0.10, 0.20 }, 0.0500001),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try layerAtDepth(&.{ 0.05, 0.10, 0.20 }, 0.35),
    );
    try std.testing.expectError(
        error.SubsurfaceIrrigationDepthBelowProfile,
        layerAtDepth(&.{ 0.05, 0.10, 0.20 }, 0.350001),
    );
}

test "failed irrigation event cannot partially alter its destination" {
    var loads = try Loads.init(std.testing.allocator, 1, 1);
    defer loads.deinit();
    var chemistry = std.mem.zeroInit(
        irrigation.WaterChemistry_g_per_m3,
        .{ .ph = 7 },
    );
    try loads.accumulate(0, 1, &.{0.1}, 10, 0.001, 0, chemistry);
    const before_water = loads.surface_water_m3[0];
    const before_hydrogen = loads.surface_hydrogen_mol[0];
    chemistry.nitrate_nitrogen = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidIrrigationChemistry,
        loads.accumulate(0, 1, &.{0.1}, 10, 0.002, 0, chemistry),
    );
    try std.testing.expectEqual(before_water, loads.surface_water_m3[0]);
    try std.testing.expectEqual(
        before_hydrogen,
        loads.surface_hydrogen_mol[0],
    );
}

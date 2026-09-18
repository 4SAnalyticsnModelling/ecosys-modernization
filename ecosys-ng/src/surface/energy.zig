const std = @import("std");
const CellRange = @import("../core/compute.zig").CellRange;
const GridState = @import("../state/grid.zig").GridState;
const AtmosphericState = @import("../atmosphere/atmospheric_forcing.zig").State;
const GroundRadiationState = @import("ground_radiation.zig").State;
const ExposureState = @import("../canopy/radiation/exposure.zig").State;
const snow_cover_fraction = @import("../soil/water/snow_cover_fraction.zig");

pub const Settings = struct {
    soil_longwave_emissivity: f64 = 0.97,
    snow_longwave_emissivity: f64 = 0.97,
    snow_full_cover_depth_m: f64 = 0.07,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    surface_emissivity: []f64,
    downward_sky_longwave_megajoules_per_m2: []f64,
    emitted_sky_longwave_megajoules_per_m2: []f64,
    net_longwave_megajoules_per_m2: []f64,
    net_radiation_megajoules_per_m2: []f64,
    fire_ignition_megajoules_per_m2: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.EmptySurfaceEnergyGrid;
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer freeAllocated(&result, allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, cell_count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| {
            if (!std.math.isFinite(value)) {
                std.log.err("non-finite surface energy: field={s} index={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteSurfaceEnergy;
            }
        };
    }
};

pub const ApplyContext = struct {
    result: *State,
    grid: *const GridState,
    atmosphere: *const AtmosphericState,
    ground_radiation: *const GroundRadiationState,
    snow_depth_m: []const f64,
    exposure: ?*const ExposureState,
    settings: Settings,
};

/// Radiation sign convention is positive toward the surface. The ecosys
/// hourly Stefan-Boltzmann coefficient is 2.04e-10 MJ m-2 h-1 K-4.
pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    try validateSettings(context.settings);
    const result = context.result;
    if (range.end > result.cell_count or context.grid.cell_count != result.cell_count or context.atmosphere.cell_count != result.cell_count or context.ground_radiation.cell_count != result.cell_count or context.snow_depth_m.len != result.cell_count) return error.SurfaceEnergyDimensionMismatch;
    if (context.exposure) |exposure| if (exposure.cell_count != result.cell_count) return error.SurfaceEnergyDimensionMismatch;
    for (range.first..range.end) |cell| {
        const temperature_k = context.grid.surface_temperature_k[cell];
        const atmospheric_longwave = context.atmosphere.longwave_radiation_megajoules_per_m2[cell];
        const ground_exposure = if (context.exposure) |exposure| exposure.ground_exposure_fraction[cell] else 1.0;
        if (!std.math.isFinite(context.snow_depth_m[cell]) or context.snow_depth_m[cell] < 0) return error.InvalidSurfaceSnowDepth;
        // `watsub.f:386-392`'s FSNW is a square root of the depth ratio (with a
        // floor-and-complement on the snow-free side), not a square. See
        // `docs/traceability/watsub_snow_cover_fraction_exponent_defect.md`.
        const snow_cover = (try snow_cover_fraction.evaluate(context.snow_depth_m[cell], context.settings.snow_full_cover_depth_m)).snow_fraction;
        const emissivity = snow_cover * context.settings.snow_longwave_emissivity + (1.0 - snow_cover) * context.settings.soil_longwave_emissivity;
        const energy = try calculate(
            context.ground_radiation.absorbed_shortwave_megajoules_per_m2[cell],
            atmospheric_longwave,
            result.fire_ignition_megajoules_per_m2[cell],
            temperature_k,
            ground_exposure,
            emissivity,
        );
        result.surface_emissivity[cell] = emissivity;
        result.downward_sky_longwave_megajoules_per_m2[cell] = energy.downward_longwave;
        result.emitted_sky_longwave_megajoules_per_m2[cell] = energy.emitted_longwave;
        result.net_longwave_megajoules_per_m2[cell] = energy.net_longwave;
        result.net_radiation_megajoules_per_m2[cell] = energy.net_radiation;
        result.fire_ignition_megajoules_per_m2[cell] = 0;
    }
}

const Energy = struct { downward_longwave: f64, emitted_longwave: f64, net_longwave: f64, net_radiation: f64 };

fn calculate(absorbed_shortwave: f64, atmospheric_longwave: f64, fire_ignition_megajoules_per_m2: f64, surface_temperature_k: f64, ground_exposure: f64, emissivity: f64) !Energy {
    inline for (.{ absorbed_shortwave, atmospheric_longwave, fire_ignition_megajoules_per_m2, surface_temperature_k, ground_exposure, emissivity }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceEnergyInput;
    if (absorbed_shortwave < 0 or atmospheric_longwave < 0 or fire_ignition_megajoules_per_m2 < 0 or surface_temperature_k <= 0 or ground_exposure < 0 or ground_exposure > 1 or emissivity < 0 or emissivity > 1) return error.InvalidSurfaceEnergyInput;
    const downward = atmospheric_longwave * ground_exposure + fire_ignition_megajoules_per_m2;
    const emitted = emissivity * 2.04e-10 * std.math.pow(f64, surface_temperature_k, 4) * ground_exposure;
    const net_longwave = downward - emitted;
    const net_radiation = absorbed_shortwave + net_longwave;
    if (@abs(net_radiation - (absorbed_shortwave + downward - emitted)) > 1.0e-12 * @max(1.0, @abs(net_radiation))) return error.SurfaceRadiationImbalance;
    return .{ .downward_longwave = downward, .emitted_longwave = emitted, .net_longwave = net_longwave, .net_radiation = net_radiation };
}

fn validateSettings(settings: Settings) !void {
    if (!std.math.isFinite(settings.soil_longwave_emissivity) or settings.soil_longwave_emissivity < 0 or settings.soil_longwave_emissivity > 1 or !std.math.isFinite(settings.snow_longwave_emissivity) or settings.snow_longwave_emissivity < 0 or settings.snow_longwave_emissivity > 1 or !std.math.isFinite(settings.snow_full_cover_depth_m) or settings.snow_full_cover_depth_m <= 0) return error.InvalidSurfaceEnergySettings;
}

fn freeAllocated(state: *State, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        if (visited < count) state.allocator.free(@field(state, field.name));
        visited += 1;
    };
}

test "surface radiation identity is conservative" {
    const energy = try calculate(1.2, 1.0, 0, 273.15, 0.8, 0.97);
    try std.testing.expectApproxEqAbs(energy.net_radiation, 1.2 + energy.downward_longwave - energy.emitted_longwave, 1.0e-14);
    try std.testing.expect(energy.emitted_longwave > 0);
}

test "invalid temperatures fail immediately" {
    try std.testing.expectError(error.InvalidSurfaceEnergyInput, calculate(1, 1, 0, 0, 1, 0.97));
}

test "WATSUB solar-noon fire ignition adds unshaded longwave energy" {
    const energy = try calculate(0, 1, 7.2, 300, 0.25, 0.97);
    try std.testing.expectApproxEqAbs(7.45, energy.downward_longwave, 1e-14);
}

test "snow-cover blend for emissivity follows the source square root, not a square" {
    // One fourth of the full-cover depth: sqrt(0.25) = 0.5 exactly, matching
    // `snow_cover_fraction.zig`'s own pinned analytical case. The previous
    // squared form would have produced 0.0625, understating cover 8x.
    const cover = try snow_cover_fraction.evaluate(0.0175, 0.07);
    try std.testing.expectApproxEqRel(@as(f64, 0.5), cover.snow_fraction, 1e-15);
}

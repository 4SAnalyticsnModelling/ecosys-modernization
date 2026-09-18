const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const PlantState = @import("../../state/grid.zig").PlantState;
const AtmosphericState = @import("../../atmosphere/atmospheric_forcing.zig").State;
const ExposureState = @import("../radiation/exposure.zig").State;
const InterceptionState = @import("interception.zig").State;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    downward_sky_longwave_megajoules_per_m2: []f64,
    emitted_sky_longwave_megajoules_per_m2: []f64,
    net_longwave_megajoules_per_m2: []f64,
    net_radiation_megajoules_per_m2: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, species_count: usize) !State {
        if (cell_count == 0 or species_count == 0) return error.InvalidCanopyEnergyDimensions;
        const count = try std.math.mul(usize, cell_count, species_count);
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        result.species_count = species_count;
        var allocated: usize = 0;
        errdefer freeAllocated(&result, allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, count);
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
                std.log.err("non-finite canopy energy: field={s} index={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteCanopyEnergy;
            }
        };
    }
};

pub const ApplyContext = struct {
    result: *State,
    plants: *const PlantState,
    atmosphere: *const AtmosphericState,
    exposure: *const ExposureState,
    interception: *const InterceptionState,
    canopy_longwave_emissivity: f64,
};

/// Computes the sky-facing canopy radiative boundary for each runtime species.
/// Canopy-ground exchange remains explicit for the coupled energy solver.
pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    const result = context.result;
    const emissivity = context.canopy_longwave_emissivity;
    if (!std.math.isFinite(emissivity) or emissivity < 0 or emissivity > 1) return error.InvalidCanopyEmissivity;
    if (range.end > result.cell_count or context.plants.cell_count != result.cell_count or context.atmosphere.cell_count != result.cell_count or context.exposure.cell_count != result.cell_count or context.interception.cell_count != result.cell_count or context.plants.species_count != result.species_count or context.exposure.species_count != result.species_count or context.interception.species_count != result.species_count) return error.CanopyEnergyDimensionMismatch;
    for (range.first..range.end) |cell| for (0..result.species_count) |species| {
        const index = cell * result.species_count + species;
        const temperature_k = context.plants.canopy_temperature_k[index];
        const exposure = context.exposure.species_exposure_fraction[index];
        const energy = try calculate(
            context.interception.absorbed_shortwave_megajoules_per_m2[index],
            context.atmosphere.longwave_radiation_megajoules_per_m2[cell],
            temperature_k,
            exposure,
            emissivity,
        );
        result.downward_sky_longwave_megajoules_per_m2[index] = energy.downward_longwave;
        result.emitted_sky_longwave_megajoules_per_m2[index] = energy.emitted_longwave;
        result.net_longwave_megajoules_per_m2[index] = energy.net_longwave;
        result.net_radiation_megajoules_per_m2[index] = energy.net_radiation;
    };
}

const Energy = struct { downward_longwave: f64, emitted_longwave: f64, net_longwave: f64, net_radiation: f64 };

fn calculate(absorbed_shortwave: f64, atmospheric_longwave: f64, temperature_k: f64, exposure: f64, emissivity: f64) !Energy {
    inline for (.{ absorbed_shortwave, atmospheric_longwave, temperature_k, exposure, emissivity }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopyEnergyInput;
    if (absorbed_shortwave < 0 or atmospheric_longwave < 0 or temperature_k <= 0 or exposure < 0 or exposure > 1 or emissivity < 0 or emissivity > 1) return error.InvalidCanopyEnergyInput;
    const downward = atmospheric_longwave * exposure;
    const emitted = emissivity * 2.04e-10 * std.math.pow(f64, temperature_k, 4) * exposure;
    const net_longwave = downward - emitted;
    return .{ .downward_longwave = downward, .emitted_longwave = emitted, .net_longwave = net_longwave, .net_radiation = absorbed_shortwave + net_longwave };
}

fn freeAllocated(state: *State, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        if (visited < count) state.allocator.free(@field(state, field.name));
        visited += 1;
    };
}

test "canopy thermal emission scales with species exposure" {
    const full = try calculate(1, 0.8, 290, 1, 0.97);
    const half = try calculate(0.5, 0.8, 290, 0.5, 0.97);
    try std.testing.expectApproxEqAbs(full.emitted_longwave * 0.5, half.emitted_longwave, 1.0e-14);
    try std.testing.expectApproxEqAbs(full.downward_longwave * 0.5, half.downward_longwave, 1.0e-14);
}

test "invalid canopy temperature fails immediately" {
    try std.testing.expectError(error.InvalidCanopyEnergyInput, calculate(0, 1, 0, 1, 0.97));
}

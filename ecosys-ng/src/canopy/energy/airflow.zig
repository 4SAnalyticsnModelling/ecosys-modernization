const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;

pub const Parameters = struct {
    minimum_richardson_number: f64,
    maximum_richardson_number: f64,
    richardson_resistance_multiplier: f64,
    minimum_canopy_resistance_h_per_m: f64,
    maximum_canopy_resistance_h_per_m: f64,
    canopy_drag_length_m: f64,
    volumetric_air_heat_capacity_megajoules_per_m3_k: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    neutral_resistance_below_biome_h_per_m: []f64,
    resistance_below_biome_h_per_m: []f64,
    resistance_below_species_h_per_m: []f64,
    resistance_below_standing_dead_h_per_m: []f64,
    latent_boundary_numerator_m2_per_h: []f64,
    sensible_boundary_numerator_megajoules_per_m_h_k: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, species_count: usize) !State {
        if (cell_count == 0 or species_count == 0) return error.InvalidCanopyAirflowDimensions;
        const species_values = try std.math.mul(usize, cell_count, species_count);
        var state: State = .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .neutral_resistance_below_biome_h_per_m = try allocator.alloc(f64, cell_count),
            .resistance_below_biome_h_per_m = undefined,
            .resistance_below_species_h_per_m = undefined,
            .resistance_below_standing_dead_h_per_m = undefined,
            .latent_boundary_numerator_m2_per_h = undefined,
            .sensible_boundary_numerator_megajoules_per_m_h_k = undefined,
        };
        errdefer allocator.free(state.neutral_resistance_below_biome_h_per_m);
        state.resistance_below_biome_h_per_m = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(state.resistance_below_biome_h_per_m);
        state.resistance_below_species_h_per_m = try allocator.alloc(f64, species_values);
        errdefer allocator.free(state.resistance_below_species_h_per_m);
        state.resistance_below_standing_dead_h_per_m = try allocator.alloc(f64, species_values);
        errdefer allocator.free(state.resistance_below_standing_dead_h_per_m);
        state.latent_boundary_numerator_m2_per_h = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(state.latent_boundary_numerator_m2_per_h);
        state.sensible_boundary_numerator_megajoules_per_m_h_k = try allocator.alloc(f64, cell_count);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) @memset(@field(state, field.name), 0);
        return state;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    state: *State,
    cell_area_m2: []const f64,
    total_canopy_area_m2: []const f64,
    biome_canopy_height_m: []const f64,
    surface_roughness_height_m: []const f64,
    species_canopy_height_m: []const f64,
    standing_dead_height_m: []const f64,
    atmospheric_vapor_diffusivity_m2_per_h: []const f64,
    atmospheric_temperature_k: []const f64,
    ground_air_temperature_k: []const f64,
    species_canopy_air_temperature_k: []const f64,
    standing_dead_air_temperature_k: []const f64,
    bulk_richardson_coefficient_k: []const f64,
    parameters: Parameters,
};

/// Exact WATSUB `ARDNS/RACGX/RACG/RAGCX/RAGC` canopy-profile resistance
/// update, expressed once per hour rather than inside a full-model subcycle.
pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    const state = context.state;
    const p = context.parameters;
    if (range.end > state.cell_count) return error.CanopyAirflowRangeOutOfBounds;
    const species_values = try std.math.mul(usize, state.cell_count, state.species_count);
    inline for (.{ context.cell_area_m2, context.total_canopy_area_m2, context.biome_canopy_height_m, context.surface_roughness_height_m, context.atmospheric_vapor_diffusivity_m2_per_h, context.atmospheric_temperature_k, context.ground_air_temperature_k, context.bulk_richardson_coefficient_k }) |values| if (values.len != state.cell_count) return error.CanopyAirflowDimensionMismatch;
    inline for (.{ context.species_canopy_height_m, context.standing_dead_height_m, context.species_canopy_air_temperature_k, context.standing_dead_air_temperature_k }) |values| if (values.len != species_values) return error.CanopyAirflowDimensionMismatch;
    inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(p, field.name))) return error.NonFiniteCanopyAirflowParameter;
    if (p.maximum_richardson_number < p.minimum_richardson_number or p.richardson_resistance_multiplier <= 0 or p.minimum_canopy_resistance_h_per_m <= 0 or p.maximum_canopy_resistance_h_per_m < p.minimum_canopy_resistance_h_per_m or p.canopy_drag_length_m < 0 or p.volumetric_air_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidCanopyAirflowParameter;

    for (range.first..range.end) |cell| {
        inline for (.{ context.cell_area_m2[cell], context.total_canopy_area_m2[cell], context.biome_canopy_height_m[cell], context.surface_roughness_height_m[cell], context.atmospheric_vapor_diffusivity_m2_per_h[cell], context.atmospheric_temperature_k[cell], context.ground_air_temperature_k[cell], context.bulk_richardson_coefficient_k[cell] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopyAirflowInput;
        if (context.cell_area_m2[cell] <= 0 or context.total_canopy_area_m2[cell] < 0 or context.biome_canopy_height_m[cell] < 0 or context.surface_roughness_height_m[cell] <= 0 or context.atmospheric_vapor_diffusivity_m2_per_h[cell] <= 0 or context.atmospheric_temperature_k[cell] <= 0 or context.ground_air_temperature_k[cell] <= 0) return error.InvalidCanopyAirflowInput;

        const height = context.biome_canopy_height_m[cell];
        const neutral_resistance = if (height > context.surface_roughness_height_m[cell])
            context.total_canopy_area_m2[cell] * p.canopy_drag_length_m /
                (context.cell_area_m2[cell] * context.atmospheric_vapor_diffusivity_m2_per_h[cell])
        else
            0;
        const atmosphere_richardson = std.math.clamp(
            context.bulk_richardson_coefficient_k[cell] / context.atmospheric_temperature_k[cell] *
                (context.atmospheric_temperature_k[cell] - context.ground_air_temperature_k[cell]),
            p.minimum_richardson_number,
            p.maximum_richardson_number,
        );
        const atmosphere_stability = 1 - p.richardson_resistance_multiplier * atmosphere_richardson;
        if (atmosphere_stability <= 0) return error.InvalidCanopyAirflowStability;
        state.neutral_resistance_below_biome_h_per_m[cell] = neutral_resistance;
        state.resistance_below_biome_h_per_m[cell] = std.math.clamp(neutral_resistance / atmosphere_stability, p.minimum_canopy_resistance_h_per_m, p.maximum_canopy_resistance_h_per_m);
        state.latent_boundary_numerator_m2_per_h[cell] = context.cell_area_m2[cell];
        state.sensible_boundary_numerator_megajoules_per_m_h_k[cell] = context.cell_area_m2[cell] * p.volumetric_air_heat_capacity_megajoules_per_m3_k;

        for (0..state.species_count) |species| {
            const index = cell * state.species_count + species;
            state.resistance_below_species_h_per_m[index] = try profileResistance(
                height,
                context.species_canopy_height_m[index],
                neutral_resistance,
                context.bulk_richardson_coefficient_k[cell],
                context.species_canopy_air_temperature_k[index],
                context.ground_air_temperature_k[cell],
                p,
            );
            state.resistance_below_standing_dead_h_per_m[index] = try profileResistance(
                height,
                context.standing_dead_height_m[index],
                neutral_resistance,
                context.bulk_richardson_coefficient_k[cell],
                context.standing_dead_air_temperature_k[index],
                context.ground_air_temperature_k[cell],
                p,
            );
        }
    }
}

fn profileResistance(biome_height_m: f64, profile_height_m: f64, biome_neutral_resistance_h_per_m: f64, bulk_richardson_coefficient_k: f64, profile_air_temperature_k: f64, ground_air_temperature_k: f64, parameters: Parameters) !f64 {
    if (!std.math.isFinite(profile_height_m) or profile_height_m < 0 or !std.math.isFinite(profile_air_temperature_k) or (profile_height_m > 0 and profile_air_temperature_k <= 0)) return error.InvalidCanopyAirflowSpeciesInput;
    if (profile_height_m == 0) return parameters.minimum_canopy_resistance_h_per_m;
    const neutral_resistance = if (biome_height_m > 0)
        (if (profile_height_m == biome_height_m) biome_neutral_resistance_h_per_m else profile_height_m / biome_height_m * biome_neutral_resistance_h_per_m)
    else
        0;
    const richardson = std.math.clamp(
        bulk_richardson_coefficient_k / profile_air_temperature_k * (profile_air_temperature_k - ground_air_temperature_k),
        parameters.minimum_richardson_number,
        parameters.maximum_richardson_number,
    );
    const stability = 1 - parameters.richardson_resistance_multiplier * richardson;
    if (stability <= 0) return error.InvalidCanopyAirflowSpeciesStability;
    return std.math.clamp(neutral_resistance / stability, parameters.minimum_canopy_resistance_h_per_m, parameters.maximum_canopy_resistance_h_per_m);
}

test "WATSUB canopy airflow supports runtime species and HOUR1 numerators" {
    const species_count: usize = 7;
    var state = try State.init(std.testing.allocator, 1, species_count);
    defer state.deinit();
    const heights = [_]f64{ 1, 2, 3, 4, 5, 6, 7 };
    const temperatures = [_]f64{290} ** species_count;
    var context: ApplyContext = .{
        .state = &state,
        .cell_area_m2 = &.{10},
        .total_canopy_area_m2 = &.{70},
        .biome_canopy_height_m = &.{7},
        .surface_roughness_height_m = &.{0.01},
        .species_canopy_height_m = &heights,
        .standing_dead_height_m = &heights,
        .atmospheric_vapor_diffusivity_m2_per_h = &.{0.09},
        .atmospheric_temperature_k = &.{290},
        .ground_air_temperature_k = &.{290},
        .species_canopy_air_temperature_k = &temperatures,
        .standing_dead_air_temperature_k = &temperatures,
        .bulk_richardson_coefficient_k = &.{0},
        .parameters = .{
            .minimum_richardson_number = -0.1,
            .maximum_richardson_number = 0.05,
            .richardson_resistance_multiplier = 10,
            .minimum_canopy_resistance_h_per_m = 1.0e-8,
            .maximum_canopy_resistance_h_per_m = 1.0e6,
            .canopy_drag_length_m = 2.0e-4,
            .volumetric_air_heat_capacity_megajoules_per_m3_k = 1.25e-3,
        },
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const expected_neutral = 70.0 * 2.0e-4 / (10.0 * 0.09);
    try std.testing.expectApproxEqAbs(expected_neutral, state.neutral_resistance_below_biome_h_per_m[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected_neutral / 7.0, state.resistance_below_species_h_per_m[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected_neutral, state.resistance_below_species_h_per_m[6], 1e-15);
    try std.testing.expectApproxEqAbs(state.resistance_below_species_h_per_m[6], state.resistance_below_standing_dead_h_per_m[6], 1e-15);
    try std.testing.expectEqual(@as(f64, 10), state.latent_boundary_numerator_m2_per_h[0]);
    try std.testing.expectEqual(@as(f64, 0.0125), state.sensible_boundary_numerator_megajoules_per_m_h_k[0]);
}

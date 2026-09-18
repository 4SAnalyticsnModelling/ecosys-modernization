// **A8a DISPOSITION: BOUND. Live plant consumers, microbial soil
// acclimation, and GROUPI persistence are composed at the day boundary.**
//
// This is a faithful translation of `wthr.f:412--440`, the
// `IF(ICLM.EQ.2.AND.J.EQ.1)` annual biological re-acclimation under
// climate-change mode 2, verified term for term: `DTS=0.5*DTA`,
// `ATCA`/`ATCS` (`:414--415`), `OFFSET=0.333*(15-AMAX1(0,AMIN1(30,ATCS)))`
// (`:416`), and per plant `ZTYP`, `OFFST`, `TCZ`, `TCX`, `HTC` and the
// `GROUPI` chain including the `IBTYP != 0` division by 25 (`:418--431`).
//
// Production performs the live per-plant refresh at the day boundary through
// `applyDaily`. Initialization still derives the entry values through
// `plant/initialization/seed_and_population.zig thermalAcclimation`, which is
// the different `startq.f:322--343` form: static zone, no `DTA`, and a
// two-slope offset (2.50 below the pivot, 1.25 above) where `wthr.f:419` has a
// single 2.50 slope. The two are not interchangeable; do not unify them.
//
// The mode is reachable, so this is a live half-implementation and not an
// absent feature: `core/options.zig` parses and accepts
// `climate_change_mode == 2`, and `io/input/climate_change.zig` implements the
// mode-2 weather half. A mode-2 run completes with its weather modifiers
// advancing and its biology silently frozen at year one. No shipped scene in
// examples_ng-prod selects mode 2, which is why no divergence column moves.
//
// See PLANT-ACCLIM-MODE2-001 and SOIL-MOFFSET-001, and
// docs/traceability/a8a_plant_response_reaudit.md
const std = @import("std");
const Dormancy = @import("../lifecycle/dormancy.zig");

pub const CellState = struct {
    mean_annual_air_temperature_c: f64,
    mean_annual_soil_temperature_c: f64,
    microbial_arrhenius_offset_c: f64,
};

pub const PlantInputs = struct {
    initial_thermal_adaptation_zone: []const f64,
    default_lower_temperature_threshold_c: []const f64,
    default_upper_temperature_threshold_c: []const f64,
    initial_floral_initiation_group: []const f64,
    planting_node_number: []const f64,
    carboxylation_type: []const u8,
    biomass_turnover_type: []const u8,
};

pub const PlantState = struct {
    thermal_adaptation_zone: []f64,
    arrhenius_offset_c: []f64,
    lower_temperature_threshold_c: []f64,
    upper_temperature_threshold_c: []f64,
    grain_number_heat_threshold_c: []f64,
    floral_initiation_node_number: []f64,
};

pub const Inputs = struct {
    incremental_climate_change: bool,
    source_hour: u8,
    daily_average_air_temperature_change_c: f64,
    initial_mean_annual_air_temperature_c: f64,
};

/// Atomic WTHR J=1 biological acclimation over arbitrary runtime plants.
pub fn apply(
    cell: *CellState,
    plants: PlantState,
    plant_inputs: PlantInputs,
    inputs: Inputs,
) !bool {
    if (inputs.source_hour < 1 or inputs.source_hour > 24)
        return error.InvalidClimateAcclimationSourceHour;
    if (!inputs.incremental_climate_change or inputs.source_hour != 1)
        return false;
    inline for (@typeInfo(CellState).@"struct".fields) |field|
        if (!std.math.isFinite(@field(cell.*, field.name)))
            return error.NonFiniteClimateAcclimationState;
    inline for (.{
        inputs.daily_average_air_temperature_change_c,
        inputs.initial_mean_annual_air_temperature_c,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteClimateAcclimationInput;
    const count = plant_inputs.initial_thermal_adaptation_zone.len;
    if (count == 0 or
        plant_inputs.default_lower_temperature_threshold_c.len != count or
        plant_inputs.default_upper_temperature_threshold_c.len != count or
        plant_inputs.initial_floral_initiation_group.len != count or
        plant_inputs.planting_node_number.len != count or
        plant_inputs.carboxylation_type.len != count or
        plant_inputs.biomass_turnover_type.len != count or
        plants.thermal_adaptation_zone.len != count or
        plants.arrhenius_offset_c.len != count or
        plants.lower_temperature_threshold_c.len != count or
        plants.upper_temperature_threshold_c.len != count or
        plants.grain_number_heat_threshold_c.len != count or
        plants.floral_initiation_node_number.len != count)
        return error.ClimateAcclimationPlantDimensionMismatch;

    const soil_change_c =
        0.5 * inputs.daily_average_air_temperature_change_c;
    const next_air_c = inputs.initial_mean_annual_air_temperature_c +
        inputs.daily_average_air_temperature_change_c;
    const next_soil_c = inputs.initial_mean_annual_air_temperature_c +
        soil_change_c;
    const microbial_offset_c =
        0.333 * (15 - std.math.clamp(next_soil_c, 0, 30));
    inline for (.{ soil_change_c, next_air_c, next_soil_c, microbial_offset_c }) |value| if (!std.math.isFinite(value))
        return error.ClimateAcclimationOverflow;

    // First pass validates every input and every candidate. The second pass
    // is a no-fail state_update, so a bad late plant cannot partially acclimate.
    for (0..count) |plant| {
        inline for (.{
            plant_inputs.initial_thermal_adaptation_zone[plant],
            plant_inputs.default_lower_temperature_threshold_c[plant],
            plant_inputs.default_upper_temperature_threshold_c[plant],
            plant_inputs.initial_floral_initiation_group[plant],
            plant_inputs.planting_node_number[plant],
        }) |value| if (!std.math.isFinite(value))
            return error.NonFiniteClimateAcclimationPlantInput;
        const candidate = derivePlant(plant_inputs, plant, inputs);
        inline for (@typeInfo(PlantCandidate).@"struct".fields) |field|
            if (!std.math.isFinite(@field(candidate, field.name)))
                return error.ClimateAcclimationOverflow;
    }

    cell.* = .{
        .mean_annual_air_temperature_c = next_air_c,
        .mean_annual_soil_temperature_c = next_soil_c,
        .microbial_arrhenius_offset_c = microbial_offset_c,
    };
    for (0..count) |plant| {
        const candidate = derivePlant(plant_inputs, plant, inputs);
        plants.thermal_adaptation_zone[plant] =
            candidate.thermal_adaptation_zone;
        plants.arrhenius_offset_c[plant] = candidate.arrhenius_offset_c;
        plants.lower_temperature_threshold_c[plant] =
            candidate.lower_temperature_threshold_c;
        plants.upper_temperature_threshold_c[plant] =
            candidate.upper_temperature_threshold_c;
        plants.grain_number_heat_threshold_c[plant] =
            candidate.grain_number_heat_threshold_c;
        plants.floral_initiation_node_number[plant] =
            candidate.floral_initiation_node_number;
    }
    return true;
}

pub const DailyRefreshInputs = struct {
    cell_count: usize,
    plants_per_cell: usize,
    source_hour: u8,
    incremental_climate_change: bool,
    daily_average_air_temperature_change_c: f64,
    initial_mean_annual_air_temperature_c_by_cell: []const f64,
    plant_initial_thermal_adaptation_zone: []const f64,
    plant_photosynthesis_pathway: []const u8,
    /// READQ `GROUPX`, before the perennial conversion.
    plant_initial_floral_initiation_group: ?[]const f64 = null,
    /// READQ `XTLI`, after the same perennial conversion used at startup.
    plant_seed_initial_node_number: ?[]const f64 = null,
    plant_biomass_turnover_type: ?[]const u8 = null,
    default_lower_temperature_threshold_c: f64,
    default_upper_temperature_threshold_c: f64,
};

pub const DailyRefreshOutputs = struct {
    thermal_adaptation_offset_c: []f64,
    leafout_threshold_c: []f64,
    leafoff_threshold_c: []f64,
    seed_set_high_temperature_c: []f64,
    /// Persistent WTHR `GROUPI`, consumed by development normalization and
    /// by branches created after the daily refresh.
    floral_initiation_node_number: ?[]f64 = null,
    /// HFUNC reads TCZ/TCX from this owner, not from the canopy mirror.
    dormancy_parameters_by_plant: ?[]Dormancy.Parameters = null,
};

/// Atomically publishes WTHR's TCZ/TCX into the parameter owner read by the
/// next same-hour HFUNC pass (`hfunc.f:869,908,1024,1064`).
pub fn bindDormancyThresholds(
    parameters: []Dormancy.Parameters,
    leafout_threshold_c: []const f64,
    leafoff_threshold_c: []const f64,
) !void {
    if (parameters.len != leafout_threshold_c.len or
        parameters.len != leafoff_threshold_c.len)
        return error.ClimateAcclimationDormancyDimensionMismatch;
    for (parameters, leafout_threshold_c, leafoff_threshold_c) |parameter, leafout, leafoff| {
        if (!std.math.isFinite(leafout) or !std.math.isFinite(leafoff))
            return error.NonFiniteClimateAcclimationDormancyThreshold;
        var candidate = parameter;
        candidate.leafout_temperature_threshold_c = leafout;
        candidate.leafoff_temperature_threshold_c = leafoff;
        try candidate.validate();
    }
    for (parameters, leafout_threshold_c, leafoff_threshold_c) |*parameter, leafout, leafoff| {
        parameter.leafout_temperature_threshold_c = leafout;
        parameter.leafoff_temperature_threshold_c = leafoff;
    }
}

/// Drives `apply` once per grid cell over every plant it owns, matching
/// `wthr.f:412--431`'s `NY,NX`/`NZ` loop nest at the composition root's day
/// boundary. The four canopy fields that are live in the hourly path --
/// `plant_thermal_adaptation_offset_c`, `plant_leafout_threshold_c`,
/// `plant_leafoff_threshold_c`, `plant_seed_set_high_temperature_c` (`wthr.f`
/// `OFFST`/`TCZ`/`TCX`/`HTC`) -- and the persistent development `GROUPI`
/// output are published here.
///
/// Every cell is derived into scratch storage before any live output changes,
/// so an invalid late plant cannot leave a partially acclimated domain.
pub fn applyDaily(
    allocator: std.mem.Allocator,
    inputs: DailyRefreshInputs,
    outputs: DailyRefreshOutputs,
) !void {
    if (!inputs.incremental_climate_change) return;
    if (inputs.cell_count == 0 or inputs.plants_per_cell == 0)
        return error.InvalidClimateAcclimationDailyRefreshDimensions;
    const plant_count = try std.math.mul(usize, inputs.cell_count, inputs.plants_per_cell);
    const group_binding_requested = inputs.plant_initial_floral_initiation_group != null or
        inputs.plant_seed_initial_node_number != null or
        inputs.plant_biomass_turnover_type != null or
        outputs.floral_initiation_node_number != null;
    if (group_binding_requested and
        (inputs.plant_initial_floral_initiation_group == null or
            inputs.plant_seed_initial_node_number == null or
            inputs.plant_biomass_turnover_type == null or
            outputs.floral_initiation_node_number == null))
        return error.IncompleteClimateAcclimationGroupBinding;
    if (inputs.initial_mean_annual_air_temperature_c_by_cell.len != inputs.cell_count or
        inputs.plant_initial_thermal_adaptation_zone.len != plant_count or
        inputs.plant_photosynthesis_pathway.len != plant_count or
        outputs.thermal_adaptation_offset_c.len != plant_count or
        outputs.leafout_threshold_c.len != plant_count or
        outputs.leafoff_threshold_c.len != plant_count or
        outputs.seed_set_high_temperature_c.len != plant_count or
        (inputs.plant_initial_floral_initiation_group != null and
            inputs.plant_initial_floral_initiation_group.?.len != plant_count) or
        (inputs.plant_seed_initial_node_number != null and
            inputs.plant_seed_initial_node_number.?.len != plant_count) or
        (inputs.plant_biomass_turnover_type != null and
            inputs.plant_biomass_turnover_type.?.len != plant_count) or
        (outputs.floral_initiation_node_number != null and
            outputs.floral_initiation_node_number.?.len != plant_count) or
        (outputs.dormancy_parameters_by_plant != null and
            outputs.dormancy_parameters_by_plant.?.len != plant_count))
        return error.ClimateAcclimationDailyRefreshDimensionMismatch;
    if (!std.math.isFinite(inputs.daily_average_air_temperature_change_c) or
        !std.math.isFinite(inputs.default_lower_temperature_threshold_c) or
        !std.math.isFinite(inputs.default_upper_temperature_threshold_c))
        return error.NonFiniteClimateAcclimationDailyRefreshInput;
    if (inputs.source_hour < 1 or inputs.source_hour > 24)
        return error.InvalidClimateAcclimationSourceHour;
    if (inputs.source_hour != 1) return;

    // The optional zero inputs retain the lower-level API's usefulness for
    // canopy-only callers. Production supplies the complete GROUPI binding.
    const zero_per_plant = try allocator.alloc(f64, inputs.plants_per_cell);
    defer allocator.free(zero_per_plant);
    @memset(zero_per_plant, 0);
    const zero_turnover_type = try allocator.alloc(u8, inputs.plants_per_cell);
    defer allocator.free(zero_turnover_type);
    @memset(zero_turnover_type, 0);
    const default_lower = try allocator.alloc(f64, inputs.plants_per_cell);
    defer allocator.free(default_lower);
    @memset(default_lower, inputs.default_lower_temperature_threshold_c);
    const default_upper = try allocator.alloc(f64, inputs.plants_per_cell);
    defer allocator.free(default_upper);
    @memset(default_upper, inputs.default_upper_temperature_threshold_c);
    const candidate_zone = try allocator.alloc(f64, plant_count);
    defer allocator.free(candidate_zone);
    const candidate_offset = try allocator.alloc(f64, plant_count);
    defer allocator.free(candidate_offset);
    const candidate_lower = try allocator.alloc(f64, plant_count);
    defer allocator.free(candidate_lower);
    const candidate_upper = try allocator.alloc(f64, plant_count);
    defer allocator.free(candidate_upper);
    const candidate_heat = try allocator.alloc(f64, plant_count);
    defer allocator.free(candidate_heat);
    const candidate_group = try allocator.alloc(f64, plant_count);
    defer allocator.free(candidate_group);

    for (0..inputs.cell_count) |cell| {
        const base = cell * inputs.plants_per_cell;
        const end = base + inputs.plants_per_cell;
        var cell_state: CellState = .{
            .mean_annual_air_temperature_c = 0,
            .mean_annual_soil_temperature_c = 0,
            .microbial_arrhenius_offset_c = 0,
        };
        _ = try apply(&cell_state, .{
            .thermal_adaptation_zone = candidate_zone[base..end],
            .arrhenius_offset_c = candidate_offset[base..end],
            .lower_temperature_threshold_c = candidate_lower[base..end],
            .upper_temperature_threshold_c = candidate_upper[base..end],
            .grain_number_heat_threshold_c = candidate_heat[base..end],
            .floral_initiation_node_number = candidate_group[base..end],
        }, .{
            .initial_thermal_adaptation_zone = inputs.plant_initial_thermal_adaptation_zone[base..end],
            .default_lower_temperature_threshold_c = default_lower,
            .default_upper_temperature_threshold_c = default_upper,
            .initial_floral_initiation_group = if (inputs.plant_initial_floral_initiation_group) |values| values[base..end] else zero_per_plant,
            .planting_node_number = if (inputs.plant_seed_initial_node_number) |values| values[base..end] else zero_per_plant,
            .carboxylation_type = inputs.plant_photosynthesis_pathway[base..end],
            .biomass_turnover_type = if (inputs.plant_biomass_turnover_type) |values| values[base..end] else zero_turnover_type,
        }, .{
            .incremental_climate_change = true,
            .source_hour = inputs.source_hour,
            .daily_average_air_temperature_change_c = inputs.daily_average_air_temperature_change_c,
            .initial_mean_annual_air_temperature_c = inputs.initial_mean_annual_air_temperature_c_by_cell[cell],
        });
    }
    if (outputs.dormancy_parameters_by_plant) |parameters|
        try bindDormancyThresholds(
            parameters,
            candidate_lower,
            candidate_upper,
        );
    @memcpy(outputs.thermal_adaptation_offset_c, candidate_offset);
    @memcpy(outputs.leafout_threshold_c, candidate_lower);
    @memcpy(outputs.leafoff_threshold_c, candidate_upper);
    @memcpy(outputs.seed_set_high_temperature_c, candidate_heat);
    if (outputs.floral_initiation_node_number) |group|
        @memcpy(group, candidate_group);
}

const PlantCandidate = struct {
    thermal_adaptation_zone: f64,
    arrhenius_offset_c: f64,
    lower_temperature_threshold_c: f64,
    upper_temperature_threshold_c: f64,
    grain_number_heat_threshold_c: f64,
    floral_initiation_node_number: f64,
};

fn derivePlant(
    inputs: PlantInputs,
    plant: usize,
    climate: Inputs,
) PlantCandidate {
    const zone = inputs.initial_thermal_adaptation_zone[plant] +
        0.30 / 2.667 * climate.daily_average_air_temperature_change_c;
    const offset_c = 2.5 * (3 - zone);
    var group = inputs.initial_floral_initiation_group[plant] +
        0.30 * climate.daily_average_air_temperature_change_c;
    if (inputs.biomass_turnover_type[plant] != 0) group /= 25;
    group -= inputs.planting_node_number[plant];
    return .{
        .thermal_adaptation_zone = zone,
        .arrhenius_offset_c = offset_c,
        .lower_temperature_threshold_c = inputs.default_lower_temperature_threshold_c[plant] - offset_c,
        .upper_temperature_threshold_c = @min(
            15,
            inputs.default_upper_temperature_threshold_c[plant] - offset_c,
        ),
        .grain_number_heat_threshold_c = (if (inputs.carboxylation_type[plant] == 3)
            @as(f64, 27)
        else
            @as(f64, 30)) + 3 * zone,
        .floral_initiation_node_number = group,
    };
}

test "incremental climate acclimates arbitrary plants at source hour one" {
    const count = 7;
    var zone = [_]f64{0} ** count;
    var offset = [_]f64{0} ** count;
    var lower = [_]f64{0} ** count;
    var upper = [_]f64{0} ** count;
    var heat = [_]f64{0} ** count;
    var group = [_]f64{0} ** count;
    var cell: CellState = .{
        .mean_annual_air_temperature_c = 0,
        .mean_annual_soil_temperature_c = 0,
        .microbial_arrhenius_offset_c = 0,
    };
    const applied = try apply(&cell, .{
        .thermal_adaptation_zone = &zone,
        .arrhenius_offset_c = &offset,
        .lower_temperature_threshold_c = &lower,
        .upper_temperature_threshold_c = &upper,
        .grain_number_heat_threshold_c = &heat,
        .floral_initiation_node_number = &group,
    }, .{
        .initial_thermal_adaptation_zone = &.{ 1, 2, 3, 4, 5, 6, 7 },
        .default_lower_temperature_threshold_c = &.{ 0, 0, 0, 0, 0, 0, 0 },
        .default_upper_temperature_threshold_c = &.{ 30, 30, 30, 30, 30, 30, 30 },
        .initial_floral_initiation_group = &.{ 10, 10, 10, 10, 10, 10, 10 },
        .planting_node_number = &.{ 1, 1, 1, 1, 1, 1, 1 },
        .carboxylation_type = &.{ 3, 4, 3, 4, 3, 4, 3 },
        .biomass_turnover_type = &.{ 0, 1, 0, 1, 0, 1, 0 },
    }, .{
        .incremental_climate_change = true,
        .source_hour = 1,
        .daily_average_air_temperature_change_c = 4,
        .initial_mean_annual_air_temperature_c = 10,
    });
    try std.testing.expect(applied);
    try std.testing.expectEqual(@as(f64, 14), cell.mean_annual_air_temperature_c);
    try std.testing.expectEqual(@as(f64, 12), cell.mean_annual_soil_temperature_c);
    try std.testing.expectApproxEqAbs(@as(f64, 0.999), cell.microbial_arrhenius_offset_c, 1e-15);
    try std.testing.expect(heat[0] < heat[1]);
    try std.testing.expect(group[0] > group[1]);
    try std.testing.expectEqual(@as(usize, count), zone.len);
}

test "upper plant temperature threshold retains source fifteen degree cap" {
    var zone = [_]f64{0};
    var offset = [_]f64{0};
    var lower = [_]f64{0};
    var upper = [_]f64{0};
    var heat = [_]f64{0};
    var group = [_]f64{0};
    var cell: CellState = .{
        .mean_annual_air_temperature_c = 0,
        .mean_annual_soil_temperature_c = 0,
        .microbial_arrhenius_offset_c = 0,
    };
    _ = try apply(&cell, .{
        .thermal_adaptation_zone = &zone,
        .arrhenius_offset_c = &offset,
        .lower_temperature_threshold_c = &lower,
        .upper_temperature_threshold_c = &upper,
        .grain_number_heat_threshold_c = &heat,
        .floral_initiation_node_number = &group,
    }, .{
        .initial_thermal_adaptation_zone = &.{3},
        .default_lower_temperature_threshold_c = &.{0},
        .default_upper_temperature_threshold_c = &.{100},
        .initial_floral_initiation_group = &.{10},
        .planting_node_number = &.{0},
        .carboxylation_type = &.{3},
        .biomass_turnover_type = &.{0},
    }, .{
        .incremental_climate_change = true,
        .source_hour = 1,
        .daily_average_air_temperature_change_c = 0,
        .initial_mean_annual_air_temperature_c = 10,
    });
    try std.testing.expectEqual(@as(f64, 15), upper[0]);
}

test "nonincremental or nonfirst hour leaves all state untouched" {
    var value = [_]f64{9};
    var cell: CellState = .{
        .mean_annual_air_temperature_c = 1,
        .mean_annual_soil_temperature_c = 2,
        .microbial_arrhenius_offset_c = 3,
    };
    const before = cell;
    const applied = try apply(&cell, .{
        .thermal_adaptation_zone = &value,
        .arrhenius_offset_c = &value,
        .lower_temperature_threshold_c = &value,
        .upper_temperature_threshold_c = &value,
        .grain_number_heat_threshold_c = &value,
        .floral_initiation_node_number = &value,
    }, .{
        .initial_thermal_adaptation_zone = &.{1},
        .default_lower_temperature_threshold_c = &.{1},
        .default_upper_temperature_threshold_c = &.{1},
        .initial_floral_initiation_group = &.{1},
        .planting_node_number = &.{1},
        .carboxylation_type = &.{3},
        .biomass_turnover_type = &.{0},
    }, .{
        .incremental_climate_change = true,
        .source_hour = 2,
        .daily_average_air_temperature_change_c = 1,
        .initial_mean_annual_air_temperature_c = 10,
    });
    try std.testing.expect(!applied);
    try std.testing.expectEqualDeep(before, cell);
    try std.testing.expectEqual(@as(f64, 9), value[0]);
}

test "invalid late plant rolls back cell and all plant outputs" {
    var zone = [_]f64{ 7, 8 };
    var offset = [_]f64{ 7, 8 };
    var lower = [_]f64{ 7, 8 };
    var upper = [_]f64{ 7, 8 };
    var heat = [_]f64{ 7, 8 };
    var group = [_]f64{ 7, 8 };
    const zone_before = zone;
    var cell: CellState = .{
        .mean_annual_air_temperature_c = 1,
        .mean_annual_soil_temperature_c = 2,
        .microbial_arrhenius_offset_c = 3,
    };
    const cell_before = cell;
    try std.testing.expectError(
        error.NonFiniteClimateAcclimationPlantInput,
        apply(&cell, .{
            .thermal_adaptation_zone = &zone,
            .arrhenius_offset_c = &offset,
            .lower_temperature_threshold_c = &lower,
            .upper_temperature_threshold_c = &upper,
            .grain_number_heat_threshold_c = &heat,
            .floral_initiation_node_number = &group,
        }, .{
            .initial_thermal_adaptation_zone = &.{ 1, std.math.nan(f64) },
            .default_lower_temperature_threshold_c = &.{ 0, 0 },
            .default_upper_temperature_threshold_c = &.{ 20, 20 },
            .initial_floral_initiation_group = &.{ 1, 1 },
            .planting_node_number = &.{ 0, 0 },
            .carboxylation_type = &.{ 3, 3 },
            .biomass_turnover_type = &.{ 0, 0 },
        }, .{
            .incremental_climate_change = true,
            .source_hour = 1,
            .daily_average_air_temperature_change_c = 1,
            .initial_mean_annual_air_temperature_c = 10,
        }),
    );
    try std.testing.expectEqualDeep(cell_before, cell);
    try std.testing.expectEqualSlices(f64, &zone_before, &zone);
}

test "daily refresh publishes canopy and GROUPI fields per cell and per plant" {
    const std_testing = std.testing;
    var offset = [_]f64{0} ** 4;
    var lower = [_]f64{0} ** 4;
    var upper = [_]f64{0} ** 4;
    var heat = [_]f64{0} ** 4;
    var group = [_]f64{0} ** 4;
    const entry_parameter: Dormancy.Parameters = .{
        .required_leafout_h = 2,
        .required_leafoff_h = 2,
        .leafout_temperature_threshold_c = 10,
        .leafoff_temperature_threshold_c = 0,
        .chilling_temperature_c = -5,
        .drought_leafout_total_water_potential_megapascal = -0.1,
        .combined_leafout_turgor_potential_megapascal = 0.1,
        .leafoff_total_water_potential_megapascal = -1.5,
        .drought_leafoff_total_water_potential_megapascal = -2,
        .maximum_photoperiod_counter_h = 3600,
        .evergreen_leafoff_remobilization_start_fraction = 0.75,
        .deciduous_leafoff_remobilization_start_fraction = 0.5,
        .full_senescence_duration_h = 480,
    };
    var dormancy_parameters = [_]Dormancy.Parameters{entry_parameter} ** 4;
    try applyDaily(std_testing.allocator, .{
        .cell_count = 2,
        .plants_per_cell = 2,
        .source_hour = 1,
        .incremental_climate_change = true,
        .daily_average_air_temperature_change_c = 4,
        .initial_mean_annual_air_temperature_c_by_cell = &.{ 10, -5 },
        .plant_initial_thermal_adaptation_zone = &.{ 1, 3, 1, 3 },
        .plant_photosynthesis_pathway = &.{ 3, 4, 3, 4 },
        .plant_initial_floral_initiation_group = &.{ 20, 50, 20, 50 },
        .plant_seed_initial_node_number = &.{ 2, 0.01, 2, 0.01 },
        .plant_biomass_turnover_type = &.{ 0, 1, 0, 1 },
        .default_lower_temperature_threshold_c = 0,
        .default_upper_temperature_threshold_c = 30,
    }, .{
        .thermal_adaptation_offset_c = &offset,
        .leafout_threshold_c = &lower,
        .leafoff_threshold_c = &upper,
        .seed_set_high_temperature_c = &heat,
        .floral_initiation_node_number = &group,
        .dormancy_parameters_by_plant = &dormancy_parameters,
    });
    // Same (zone, pathway) pair in both cells: the cell-level ATCAI split
    // must not leak into the published per-plant canopy fields.
    try std_testing.expectApproxEqAbs(offset[0], offset[2], 1e-12);
    try std_testing.expectApproxEqAbs(heat[0], heat[2], 1e-12);
    // Colder adaptation zone (1) warms the offset relative to the warmer
    // zone (3), matching `derivePlant`'s `2.5*(3-zone)` slope.
    try std_testing.expect(offset[0] > offset[1]);
    try std_testing.expect(heat[0] < heat[1]);
    const expected_zone = 1 + 0.30 / 2.667 * 4;
    const expected_offset = 2.5 * (3 - expected_zone);
    try std_testing.expectApproxEqAbs(expected_offset, offset[0], 1e-12);
    try std_testing.expectApproxEqAbs(-expected_offset, lower[0], 1e-12);
    try std_testing.expectApproxEqAbs(@as(f64, 15), upper[0], 1e-12);
    try std_testing.expectApproxEqAbs(27 + 3 * expected_zone, heat[0], 1e-12);
    try std_testing.expectApproxEqAbs(@as(f64, 19.2), group[0], 1e-12);
    try std_testing.expectApproxEqAbs(@as(f64, 2.038), group[1], 1e-12);
    try std_testing.expectApproxEqAbs(lower[0], dormancy_parameters[0].leafout_temperature_threshold_c, 1e-12);
    try std_testing.expectApproxEqAbs(upper[0], dormancy_parameters[0].leafoff_temperature_threshold_c, 1e-12);

    // Checkpoint resume reconstructs the noncheckpointed parameter mirrors
    // by applying the same cumulative DTA again. Every output must therefore
    // be an overwrite-only, bit-reproducible function of static traits+DTA.
    const published_offset = offset;
    const published_lower = lower;
    const published_upper = upper;
    const published_heat = heat;
    const published_group = group;
    @memset(&offset, -91);
    @memset(&lower, -92);
    @memset(&upper, -93);
    @memset(&heat, -94);
    @memset(&group, -95);
    for (&dormancy_parameters) |*parameter| {
        parameter.leafout_temperature_threshold_c = -96;
        parameter.leafoff_temperature_threshold_c = -97;
    }
    try applyDaily(std_testing.allocator, .{
        .cell_count = 2,
        .plants_per_cell = 2,
        .source_hour = 1,
        .incremental_climate_change = true,
        .daily_average_air_temperature_change_c = 4,
        .initial_mean_annual_air_temperature_c_by_cell = &.{ 10, -5 },
        .plant_initial_thermal_adaptation_zone = &.{ 1, 3, 1, 3 },
        .plant_photosynthesis_pathway = &.{ 3, 4, 3, 4 },
        .plant_initial_floral_initiation_group = &.{ 20, 50, 20, 50 },
        .plant_seed_initial_node_number = &.{ 2, 0.01, 2, 0.01 },
        .plant_biomass_turnover_type = &.{ 0, 1, 0, 1 },
        .default_lower_temperature_threshold_c = 0,
        .default_upper_temperature_threshold_c = 30,
    }, .{
        .thermal_adaptation_offset_c = &offset,
        .leafout_threshold_c = &lower,
        .leafoff_threshold_c = &upper,
        .seed_set_high_temperature_c = &heat,
        .floral_initiation_node_number = &group,
        .dormancy_parameters_by_plant = &dormancy_parameters,
    });
    try std_testing.expectEqualDeep(published_offset, offset);
    try std_testing.expectEqualDeep(published_lower, lower);
    try std_testing.expectEqualDeep(published_upper, upper);
    try std_testing.expectEqualDeep(published_heat, heat);
    try std_testing.expectEqualDeep(published_group, group);
    for (dormancy_parameters, published_lower, published_upper) |parameter, expected_lower, expected_upper| {
        try std_testing.expectEqual(expected_lower, parameter.leafout_temperature_threshold_c);
        try std_testing.expectEqual(expected_upper, parameter.leafoff_temperature_threshold_c);
    }

    // At 5 C the entry threshold blocks HFUNC leafout, while WTHR's
    // current mode-2 TCZ permits it. This is the live causal connection the
    // former canopy-only mirror lacked.
    var entry_state: Dormancy.State = .{};
    var acclimated_state: Dormancy.State = .{};
    const hfunc_inputs: Dormancy.Inputs = .{
        .day_of_year = 100,
        .execution_year = 2020,
        .latitude_deg_n = 53,
        .timestep_h = 1,
        .current_daylength_h = 13,
        .previous_daylength_h = 12.9,
        .maximum_seasonal_daylength_h = 17,
        .canopy_temperature_c = 5,
        .canopy_turgor_potential_megapascal = 0.2,
        .canopy_total_water_potential_megapascal = -0.05,
        .surface_soil_water_potential_megapascal = -0.1,
        .seed_layer_soil_water_potential_megapascal = -0.1,
        .emerged = true,
        .floral_initiated = false,
    };
    try Dormancy.advance(&entry_state, hfunc_inputs, entry_parameter, .perennial, .winter_deciduous);
    try Dormancy.advance(&acclimated_state, hfunc_inputs, dormancy_parameters[0], .perennial, .winter_deciduous);
    try std_testing.expectEqual(@as(f64, 0), entry_state.accumulated_leafout_h);
    try std_testing.expectEqual(@as(f64, 1), acclimated_state.accumulated_leafout_h);
}

test "dormancy threshold binding rolls back on a bad late plant" {
    const parameter: Dormancy.Parameters = .{
        .required_leafout_h = 2,
        .required_leafoff_h = 2,
        .leafout_temperature_threshold_c = 5,
        .leafoff_temperature_threshold_c = 0,
        .chilling_temperature_c = -5,
        .drought_leafout_total_water_potential_megapascal = -0.1,
        .combined_leafout_turgor_potential_megapascal = 0.1,
        .leafoff_total_water_potential_megapascal = -1.5,
        .drought_leafoff_total_water_potential_megapascal = -2,
        .maximum_photoperiod_counter_h = 3600,
        .evergreen_leafoff_remobilization_start_fraction = 0.75,
        .deciduous_leafoff_remobilization_start_fraction = 0.5,
        .full_senescence_duration_h = 480,
    };
    var parameters = [_]Dormancy.Parameters{ parameter, parameter };
    const before = parameters;
    try std.testing.expectError(
        error.NonFiniteClimateAcclimationDormancyThreshold,
        bindDormancyThresholds(&parameters, &.{ 1, std.math.nan(f64) }, &.{ 2, 3 }),
    );
    try std.testing.expectEqualDeep(before, parameters);
}

test "daily refresh rolls back every published field on a bad late cell" {
    var offset = [_]f64{ 11, 12 };
    var lower = [_]f64{ 21, 22 };
    var upper = [_]f64{ 31, 32 };
    var heat = [_]f64{ 41, 42 };
    var group = [_]f64{ 51, 52 };
    const offset_before = offset;
    const lower_before = lower;
    const upper_before = upper;
    const heat_before = heat;
    const group_before = group;
    try std.testing.expectError(error.NonFiniteClimateAcclimationPlantInput, applyDaily(std.testing.allocator, .{
        .cell_count = 2,
        .plants_per_cell = 1,
        .source_hour = 1,
        .incremental_climate_change = true,
        .daily_average_air_temperature_change_c = 4,
        .initial_mean_annual_air_temperature_c_by_cell = &.{ 10, 10 },
        .plant_initial_thermal_adaptation_zone = &.{ 1, 1 },
        .plant_photosynthesis_pathway = &.{ 3, 3 },
        .plant_initial_floral_initiation_group = &.{ 20, std.math.nan(f64) },
        .plant_seed_initial_node_number = &.{ 2, 2 },
        .plant_biomass_turnover_type = &.{ 0, 0 },
        .default_lower_temperature_threshold_c = 0,
        .default_upper_temperature_threshold_c = 30,
    }, .{
        .thermal_adaptation_offset_c = &offset,
        .leafout_threshold_c = &lower,
        .leafoff_threshold_c = &upper,
        .seed_set_high_temperature_c = &heat,
        .floral_initiation_node_number = &group,
    }));
    try std.testing.expectEqualSlices(f64, &offset_before, &offset);
    try std.testing.expectEqualSlices(f64, &lower_before, &lower);
    try std.testing.expectEqualSlices(f64, &upper_before, &upper);
    try std.testing.expectEqualSlices(f64, &heat_before, &heat);
    try std.testing.expectEqualSlices(f64, &group_before, &group);
}

test "production mode2 acclimation is rollback-owned and precedes HFUNC" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        allocator,
        .limited(12 * 1024 * 1024),
    );
    defer allocator.free(source);
    const prepare_start = std.mem.indexOf(u8, source, "noinline fn prepareHourlyScience(") orelse return error.MissingPrepareHourlySciencePhase;
    const advance_start = std.mem.indexOfPos(u8, source, prepare_start, "noinline fn advanceHour(") orelse return error.MissingAdvanceHourPhase;
    const prepare_phase = source[prepare_start..advance_start];
    const daily_marker = std.mem.indexOf(u8, prepare_phase, "PLANT_ACCLIM_MODE2_DAILY_BINDING") orelse return error.MissingDailyBiologicalClimateAcclimation;
    const acclimation = std.mem.indexOfPos(u8, prepare_phase, daily_marker, "biological_climate_acclimation.applyDaily(") orelse return error.MissingBiologicalClimateAcclimation;
    const acclimation_body = prepare_phase[acclimation..];
    const binding = std.mem.indexOf(u8, acclimation_body, ".dormancy_parameters_by_plant = driver_context.development_dormancy_parameters.*") orelse return error.MissingDormancyAcclimationBinding;
    const group_input = std.mem.indexOf(u8, acclimation_body, ".plant_initial_floral_initiation_group = driver_context.plant_initial_floral_initiation_group.*") orelse return error.MissingGroupAcclimationInput;
    const group_output = std.mem.indexOf(u8, acclimation_body, ".floral_initiation_node_number = driver_context.plant_topology_controls.*.initial_maturity_group") orelse return error.MissingGroupAcclimationOutput;
    const development_binding = std.mem.indexOf(u8, acclimation_body, "parameters.maturity_group_node_count = group") orelse return error.MissingDevelopmentGroupBinding;
    try std.testing.expect(binding < acclimation_body.len);
    try std.testing.expect(group_input < group_output and group_output < development_binding);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, acclimation_body, ".dormancy_parameters_by_plant = driver_context.development_dormancy_parameters.*"));

    const transaction = std.mem.indexOfPos(u8, source, advance_start, "driver_context.outer_hour_transaction_workspace.*.begin(") orelse return error.MissingOuterHourTransaction;
    const prepare_call = std.mem.indexOfPos(u8, source, transaction, "try prepareHourlyScience(driver_context,") orelse return error.MissingHourlyPreparationCall;
    const hfunc = std.mem.indexOfPos(u8, source, prepare_call, "executeHourlyScience(") orelse return error.MissingHourlyScienceCall;
    try std.testing.expect(transaction < prepare_call and prepare_call < hfunc);

    const swap = std.mem.indexOf(u8, source, "checkpoint_bundle_reader.swapIntoLive(") orelse return error.MissingCheckpointOwnerSwap;
    const resume_marker = std.mem.indexOfPos(u8, source, swap, "PLANT_ACCLIM_MODE2_RESUME_BINDING") orelse return error.MissingResumeBiologicalClimateAcclimation;
    const restored_deinit = std.mem.indexOfPos(u8, source, resume_marker, "restored.deinit()") orelse return error.MissingRestoredBundleRelease;
    const resume_body = source[resume_marker..restored_deinit];
    _ = std.mem.indexOf(u8, resume_body, "biological_climate_acclimation.applyDaily(") orelse return error.MissingResumeBiologicalClimateRefresh;
    _ = std.mem.indexOf(u8, resume_body, "parameters.maturity_group_node_count = group") orelse return error.MissingResumeDevelopmentGroupBinding;
    try std.testing.expect(std.mem.indexOf(u8, resume_body, "climate_state.advanceDay(") == null);
    try std.testing.expect(swap < resume_marker and resume_marker < restored_deinit and restored_deinit < transaction);
}

test "daily refresh is a no-op outside incremental climate change" {
    var offset = [_]f64{ 11, 12 };
    var lower = [_]f64{ 11, 12 };
    var upper = [_]f64{ 11, 12 };
    var heat = [_]f64{ 11, 12 };
    try applyDaily(std.testing.allocator, .{
        .cell_count = 1,
        .plants_per_cell = 2,
        .source_hour = 1,
        .incremental_climate_change = false,
        .daily_average_air_temperature_change_c = 4,
        .initial_mean_annual_air_temperature_c_by_cell = &.{10},
        .plant_initial_thermal_adaptation_zone = &.{ 1, 3 },
        .plant_photosynthesis_pathway = &.{ 3, 4 },
        .default_lower_temperature_threshold_c = 0,
        .default_upper_temperature_threshold_c = 30,
    }, .{
        .thermal_adaptation_offset_c = &offset,
        .leafout_threshold_c = &lower,
        .leafoff_threshold_c = &upper,
        .seed_set_high_temperature_c = &heat,
    });
    try std.testing.expectEqualSlices(f64, &.{ 11, 12 }, &offset);
    try std.testing.expectEqualSlices(f64, &.{ 11, 12 }, &lower);
    try std.testing.expectEqualSlices(f64, &.{ 11, 12 }, &upper);
    try std.testing.expectEqualSlices(f64, &.{ 11, 12 }, &heat);
}

test "daily refresh rejects a plant array that does not cover every cell" {
    var offset = [_]f64{0} ** 4;
    var lower = [_]f64{0} ** 4;
    var upper = [_]f64{0} ** 4;
    var heat = [_]f64{0} ** 4;
    try std.testing.expectError(error.ClimateAcclimationDailyRefreshDimensionMismatch, applyDaily(std.testing.allocator, .{
        .cell_count = 2,
        .plants_per_cell = 2,
        .source_hour = 1,
        .incremental_climate_change = true,
        .daily_average_air_temperature_change_c = 4,
        .initial_mean_annual_air_temperature_c_by_cell = &.{ 10, -5 },
        .plant_initial_thermal_adaptation_zone = &.{ 1, 3, 1 },
        .plant_photosynthesis_pathway = &.{ 3, 4, 3, 4 },
        .default_lower_temperature_threshold_c = 0,
        .default_upper_temperature_threshold_c = 30,
    }, .{
        .thermal_adaptation_offset_c = &offset,
        .leafout_threshold_c = &lower,
        .leafoff_threshold_c = &upper,
        .seed_set_high_temperature_c = &heat,
    }));
}

const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const stages = @import("growth_stages.zig");
const dormancy = @import("dormancy.zig");
const phenology = @import("phenology.zig");
const canopy_photosynthesis = @import("../../canopy/photosynthesis/photosynthesis.zig");
const plant_root_system = @import("../root/plant_root_system.zig");
const GridState = @import("../../state/grid.zig").GridState;
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");

pub const Calendar = struct {
    day_of_year: u16,
    current_year: i32,
    current_daylength_h: f64,
    previous_daylength_h: f64,
    maximum_seasonal_daylength_h: f64,
    latitude_degrees_north: f64,
};

pub const AdvanceContext = struct {
    growth_stages: *stages.State,
    dormancy_state: *dormancy.RuntimeState,
    phenology_state: *phenology.State,
    branch_development: *const phenology.BranchDevelopmentState,
    species_parameters_by_plant: []const stages.SpeciesParameters,
    dormancy_parameters_by_plant: []const dormancy.Parameters,
    planting_day_of_year_by_plant: []const u16,
    planting_year_by_plant: []const i32,
    canopy_height_m_by_plant: []const f64,
    snow_depth_m_by_cell: []const f64,
    canopy_temperature_k_by_plant: []const f64,
    canopy_turgor_potential_mpa_by_plant: []const f64,
    canopy_total_water_potential_mpa_by_plant: []const f64,
    surface_soil_water_potential_mpa_by_cell: []const f64,
    seed_layer_soil_water_potential_mpa_by_plant: []const f64,
    emerged_by_plant: []bool,
    calendar_by_cell: []const Calendar,
    timestep_h: f64,
};

/// HFUNC orchestration for branch growth stages followed by branch dormancy.
/// Each tile owns disjoint plants and branches, so CPU workers need no locks.
pub fn advanceTile(context: *AdvanceContext, range: CellRange) !void {
    try validateContext(context.*, range);
    const species_count = context.phenology_state.species_count;
    for (range.first..range.end) |cell| for (0..species_count) |species| {
        const calendar = context.calendar_by_cell[cell];
        const execution_year = std.math.cast(u16, calendar.current_year) orelse
            return error.InvalidPlantDevelopmentDate;
        const plant = cell * species_count + species;
        context.phenology_state.leafout_transition_this_step[plant] = false;
        if (!context.phenology_state.active[plant]) continue;
        const dormant_seed = context.phenology_state.reseed_pending[plant];
        if (!context.emerged_by_plant[plant] and !dormant_seed) continue;
        const branch_range = try context.growth_stages.branchRange(plant);
        if (branch_range.first == branch_range.end) return error.ActivePlantHasNoDevelopmentBranch;
        const primary_branch_index = if (dormant_seed)
            branch_range.first
        else
            (try context.growth_stages.mainLivingBranch(plant)) orelse continue;
        for (branch_range.first..branch_range.end) |branch_index| {
            var branch = &context.growth_stages.branches[branch_index];
            if (branch.dead and !dormant_seed) continue;
            const branch_dormancy = &context.dormancy_state.branches[branch_index];
            var species_parameters = context.species_parameters_by_plant[plant];
            species_parameters.branch_floral_node_requirement = context.branch_development.maturity_group[branch_index];
            const dormancy_parameters = context.dormancy_parameters_by_plant[plant];
            if (dormant_seed) {
                try dormancy.advance(branch_dormancy, .{
                    .day_of_year = calendar.day_of_year,
                    .execution_year = execution_year,
                    .latitude_deg_n = calendar.latitude_degrees_north,
                    .timestep_h = context.timestep_h,
                    .current_daylength_h = calendar.current_daylength_h,
                    .previous_daylength_h = calendar.previous_daylength_h,
                    .maximum_seasonal_daylength_h = calendar.maximum_seasonal_daylength_h,
                    .canopy_temperature_c = context.canopy_temperature_k_by_plant[plant] - 273.15,
                    .canopy_turgor_potential_megapascal = context.canopy_turgor_potential_mpa_by_plant[plant],
                    .canopy_total_water_potential_megapascal = context.canopy_total_water_potential_mpa_by_plant[plant],
                    .surface_soil_water_potential_megapascal = context.surface_soil_water_potential_mpa_by_cell[cell],
                    .seed_layer_soil_water_potential_megapascal = context.seed_layer_soil_water_potential_mpa_by_plant[plant],
                    .emerged = false,
                    .floral_initiated = false,
                }, dormancy_parameters, species_parameters.growth_habit, species_parameters.phenology_type);
                if (branch_dormancy.accumulated_leafout_h >= dormancy_parameters.required_leafout_h) {
                    context.phenology_state.active[plant] = false;
                    context.phenology_state.lifecycle_initialized[plant] = false;
                    break;
                }
                continue;
            }
            var node_increment = context.phenology_state.node_initiation_per_timestep[plant];
            var leaf_increment = context.phenology_state.leaf_appearance_per_timestep[plant];
            const development_enabled = species_parameters.phenology_type == .evergreen or
                branch_dormancy.accumulated_leafoff_h < dormancy_parameters.required_leafoff_h or
                (species_parameters.growth_habit == .annual and species_parameters.phenology_type == .winter_deciduous);
            const annual_winter_prefloral_limit_reached =
                species_parameters.growth_habit == .annual and
                species_parameters.phenology_type == .winter_deciduous and
                branch.floral_initiation_day == 0 and
                branch.initiated_node_count > context.branch_development.maturity_group[branch_index] +
                    context.branch_development.initial_reproductive_stage[branch_index];
            if (!development_enabled or annual_winter_prefloral_limit_reached) {
                node_increment = 0;
                leaf_increment = 0;
                branch.lowest_node_nutrient_remobilization_enabled = false;
            }
            branch.initiated_node_count += node_increment;
            branch.appeared_leaf_count += leaf_increment;
            const stage_inputs: stages.RuntimeInputs = .{
                .day_of_year = calendar.day_of_year,
                .current_year = calendar.current_year,
                .planting_day_of_year = context.planting_day_of_year_by_plant[plant],
                .planting_year = context.planting_year_by_plant[plant],
                .current_daylength_h = calendar.current_daylength_h,
                .previous_daylength_h = calendar.previous_daylength_h,
                .canopy_height_m = context.canopy_height_m_by_plant[plant],
                .snow_depth_m = context.snow_depth_m_by_cell[cell],
                .accumulated_leafout_h = branch_dormancy.accumulated_leafout_h,
                .required_leafout_h = dormancy_parameters.required_leafout_h,
                .accumulated_leafoff_h = branch_dormancy.accumulated_leafoff_h,
                .required_leafoff_h = dormancy_parameters.required_leafoff_h,
                .leafout_disabled = branch_dormancy.leafout_disabled,
            };
            const primary_anthesis_started = context.growth_stages.branches[primary_branch_index].anthesis_day != 0;
            try stages.advanceBranch(branch, node_increment, stage_inputs, species_parameters, branch_index == primary_branch_index, primary_anthesis_started);
            // HFUNC IFLGG follows the branch development gate itself; it is not
            // conditional on anthesis.
            branch.lowest_node_nutrient_remobilization_enabled = development_enabled;
            const dormancy_inputs: dormancy.Inputs = .{
                .day_of_year = calendar.day_of_year,
                .execution_year = execution_year,
                .latitude_deg_n = calendar.latitude_degrees_north,
                .timestep_h = context.timestep_h,
                .current_daylength_h = calendar.current_daylength_h,
                .previous_daylength_h = calendar.previous_daylength_h,
                .maximum_seasonal_daylength_h = calendar.maximum_seasonal_daylength_h,
                .canopy_temperature_c = context.canopy_temperature_k_by_plant[plant] - 273.15,
                .canopy_turgor_potential_megapascal = context.canopy_turgor_potential_mpa_by_plant[plant],
                .canopy_total_water_potential_megapascal = context.canopy_total_water_potential_mpa_by_plant[plant],
                .surface_soil_water_potential_megapascal = context.surface_soil_water_potential_mpa_by_cell[cell],
                .seed_layer_soil_water_potential_megapascal = context.seed_layer_soil_water_potential_mpa_by_plant[plant],
                .emerged = context.emerged_by_plant[plant],
                .floral_initiated = branch.floral_initiation_day != 0,
            };
            const leafout_before_h = branch_dormancy.accumulated_leafout_h;
            try dormancy.advance(branch_dormancy, dormancy_inputs, dormancy_parameters, species_parameters.growth_habit, species_parameters.phenology_type);
            if (species_parameters.growth_habit == .perennial and
                leafout_before_h < dormancy_parameters.required_leafout_h and
                branch_dormancy.accumulated_leafout_h >= dormancy_parameters.required_leafout_h)
                context.phenology_state.leafout_transition_this_step[plant] = true;
        }
        context.phenology_state.floral_initiated[plant] = context.growth_stages.branches[primary_branch_index].floral_initiation_day != 0;
    };
}

/// HFUNC IDAY(1): emergence requires hypocotyl clearance, positive shoot
/// area, and primary-root penetration below seeding depth in the same hour.
pub fn refreshEmergence(
    canopy: *const canopy_photosynthesis.State,
    roots: *const plant_root_system.State,
    growth_stages: *stages.State,
    seeding_depth_m_by_plant: []const f64,
    day_of_year: u16,
    area_threshold_m2_per_plant: f64,
    root_depth_margin_m: f64,
    emerged_by_plant: []bool,
) !void {
    const plant_count = canopy.plant_branch_offsets.len - 1;
    if (roots.plant_count != plant_count or growth_stages.plant_count != plant_count or seeding_depth_m_by_plant.len != plant_count or emerged_by_plant.len != plant_count) return error.PlantDevelopmentDimensionMismatch;
    if (day_of_year == 0 or day_of_year > 366 or !std.math.isFinite(area_threshold_m2_per_plant) or area_threshold_m2_per_plant < 0 or !std.math.isFinite(root_depth_margin_m) or root_depth_margin_m < 0) return error.InvalidEmergenceInput;
    for (0..plant_count) |plant| {
        if (emerged_by_plant[plant]) continue;
        const seed_depth_m = seeding_depth_m_by_plant[plant];
        const hypocotyl_height_m = canopy.plant_hypocotyledon_height_m[plant];
        const primary_root_depth_m = roots.axis_depth_m[try roots.axisIndex(plant, 0, 0)];
        const population_count = canopy.plant_population_count[plant];
        inline for (.{ seed_depth_m, hypocotyl_height_m, primary_root_depth_m, population_count }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidEmergenceState;
        var leaf_plus_stalk_area_m2: f64 = 0;
        const branch_range = try canopy.branchRange(plant);
        for (branch_range.first..branch_range.end) |branch| {
            const leaf_area = canopy.branch_leaf_area_m2[branch];
            if (!std.math.isFinite(leaf_area) or leaf_area < 0) return error.InvalidEmergenceState;
            leaf_plus_stalk_area_m2 += leaf_area;
            for (canopy.branch_node_offsets[branch]..canopy.branch_node_offsets[branch + 1]) |node| {
                for (canopy.node_sample_offsets[node]..canopy.node_sample_offsets[node + 1]) |sample| {
                    const stalk_area = canopy.sample_stalk_area_m2[sample];
                    if (!std.math.isFinite(stalk_area) or stalk_area < 0) return error.InvalidEmergenceState;
                    leaf_plus_stalk_area_m2 += stalk_area;
                }
            }
        }
        if (hypocotyl_height_m > seed_depth_m and leaf_plus_stalk_area_m2 > area_threshold_m2_per_plant * population_count and primary_root_depth_m > seed_depth_m + root_depth_margin_m) {
            emerged_by_plant[plant] = true;
            const stages_for_plant = try growth_stages.branchRange(plant);
            for (growth_stages.branches[stages_for_plant.first..stages_for_plant.end]) |*branch| {
                if (!branch.dead and branch.emergence_day == 0) branch.emergence_day = day_of_year;
            }
        }
    }
}

/// GROSUB HTCTL: before emergence, the first main-branch leaf length plus its
/// sheath and internode lengths defines hypocotyledon height. The source's
/// 1.0E+02 converts leaf area per square metre and population density to the
/// centimetre-based length used by its leaf geometry.
pub fn refreshHypocotyledonHeight(canopy: *canopy_photosynthesis.State, seeding_depth_m_by_plant: []const f64) !void {
    const plant_count = canopy.plant_branch_offsets.len - 1;
    if (seeding_depth_m_by_plant.len != plant_count) return error.EmergenceDimensionMismatch;
    for (0..plant_count) |plant| {
        const seed_depth_m = seeding_depth_m_by_plant[plant];
        const population_per_m2 = canopy.plant_population_per_m2[plant];
        if (!std.math.isFinite(seed_depth_m) or seed_depth_m < 0 or !std.math.isFinite(population_per_m2) or population_per_m2 < 0) return error.InvalidHypocotyledonInput;
        if (canopy.plant_hypocotyledon_height_m[plant] > seed_depth_m or population_per_m2 == 0) continue;
        const branches = try canopy.branchRange(plant);
        if (branches.first == branches.end) continue;
        const nodes = try canopy.nodeRange(branches.first);
        if (nodes.first == nodes.end) continue;
        const node = nodes.first;
        const leaf_area_m2 = canopy.node_leaf_area_m2[node];
        const sheath_height_m = canopy.node_sheath_height_m[node];
        const internode_length_m = canopy.node_internode_length_m[node];
        inline for (.{ leaf_area_m2, sheath_height_m, internode_length_m }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidHypocotyledonInput;
        if (leaf_area_m2 > 0) canopy.plant_hypocotyledon_height_m[plant] = @sqrt(1.0e2 * leaf_area_m2 / population_per_m2) + sheath_height_m + internode_length_m;
    }
}

pub fn refreshCanopyHeight(canopy: *const canopy_photosynthesis.State, output_m_by_plant: []f64) !void {
    const plant_count = canopy.plant_branch_offsets.len - 1;
    if (output_m_by_plant.len != plant_count) return error.PlantDevelopmentDimensionMismatch;
    @memset(output_m_by_plant, 0);
    for (0..plant_count) |plant| {
        const branches = try canopy.branchRange(plant);
        for (branches.first..branches.end) |branch| {
            const first_node = canopy.branch_node_offsets[branch];
            const end_node = canopy.branch_node_offsets[branch + 1];
            for (canopy.node_height_m[first_node..end_node]) |height_m| {
                if (!std.math.isFinite(height_m) or height_m < 0) return error.InvalidCanopyHeight;
                output_m_by_plant[plant] = @max(output_m_by_plant[plant], height_m);
            }
        }
    }
}

/// HFUNC WSTR is the current lowest-order living branch's leafoff counter.
pub fn coldOrWaterStressHours(growth_stages: *const stages.State, dormancy_state: *const dormancy.RuntimeState, plant: usize) !f64 {
    if (dormancy_state.branches.len != growth_stages.branches.len) return error.PlantDevelopmentDimensionMismatch;
    const primary_branch = (try growth_stages.mainLivingBranch(plant)) orelse return 0;
    const hours = dormancy_state.branches[primary_branch].accumulated_leafoff_h;
    if (!std.math.isFinite(hours) or hours < 0) return error.InvalidDormancyState;
    return hours;
}

pub fn refreshSoilWaterPotentials(grid: *const GridState, soil_total_water_potential_megapascal: []const f64, litter_matric_plus_osmotic_potential_megapascal: []const f64, relative_surface_elevation_m: []const f64, gravitational_water_potential_mpa_per_m: f64, roots: *const plant_root_system.State, surface_by_cell_megapascal: []f64, seed_layer_by_plant_megapascal: []f64) !void {
    if (soil_total_water_potential_megapascal.len != grid.layer_count or litter_matric_plus_osmotic_potential_megapascal.len != grid.cell_count or relative_surface_elevation_m.len != grid.cell_count or surface_by_cell_megapascal.len != grid.cell_count or seed_layer_by_plant_megapascal.len != roots.plant_count or roots.plant_count % grid.cell_count != 0) return error.PlantDevelopmentDimensionMismatch;
    if (!std.math.isFinite(gravitational_water_potential_mpa_per_m) or
        gravitational_water_potential_mpa_per_m <= 0)
        return error.InvalidPlantDevelopmentInput;
    const species_count = roots.plant_count / grid.cell_count;
    for (0..grid.cell_count) |cell| {
        const surface_index = cell * grid.soil_layer_capacity;
        const litter_total_water_potential_megapascal =
            litter_matric_plus_osmotic_potential_megapascal[cell] +
            gravitational_water_potential_mpa_per_m *
                relative_surface_elevation_m[cell];
        surface_by_cell_megapascal[cell] = @min(
            soil_total_water_potential_megapascal[surface_index],
            litter_total_water_potential_megapascal,
        );
        if (!std.math.isFinite(surface_by_cell_megapascal[cell])) return error.NonFinitePlantDevelopmentInput;
        for (0..species_count) |species| {
            const plant = cell * species_count + species;
            const layer = roots.planting_layer_by_plant[plant];
            if (layer >= grid.active_soil_layer_count[cell]) return error.InvalidPlantingLayer;
            seed_layer_by_plant_megapascal[plant] =
                soil_total_water_potential_megapascal[surface_index + layer];
            if (!std.math.isFinite(seed_layer_by_plant_megapascal[plant])) return error.NonFinitePlantDevelopmentInput;
        }
    }
}

fn validateContext(context: AdvanceContext, range: CellRange) !void {
    const plants = try std.math.mul(usize, context.phenology_state.cell_count, context.phenology_state.species_count);
    if (range.first > range.end or range.end > context.phenology_state.cell_count or context.growth_stages.plant_count != plants or context.dormancy_state.branches.len != context.growth_stages.branches.len or context.branch_development.branch_count != context.growth_stages.branches.len) return error.PlantDevelopmentDimensionMismatch;
    inline for (.{ context.species_parameters_by_plant.len, context.dormancy_parameters_by_plant.len, context.planting_day_of_year_by_plant.len, context.planting_year_by_plant.len, context.canopy_height_m_by_plant.len, context.canopy_temperature_k_by_plant.len, context.canopy_turgor_potential_mpa_by_plant.len, context.canopy_total_water_potential_mpa_by_plant.len, context.seed_layer_soil_water_potential_mpa_by_plant.len, context.emerged_by_plant.len }) |length| if (length != plants) return error.PlantDevelopmentDimensionMismatch;
    inline for (.{ context.snow_depth_m_by_cell.len, context.surface_soil_water_potential_mpa_by_cell.len, context.calendar_by_cell.len }) |length| if (length != context.phenology_state.cell_count) return error.PlantDevelopmentDimensionMismatch;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.InvalidPlantDevelopmentInput;
    for (context.calendar_by_cell[range.first..range.end]) |calendar| {
        inline for (.{ calendar.current_daylength_h, calendar.previous_daylength_h, calendar.maximum_seasonal_daylength_h, calendar.latitude_degrees_north }) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantDevelopmentInput;
        try validateCalendarDate(calendar);
        if (calendar.current_daylength_h < 0 or calendar.current_daylength_h > 24 or calendar.previous_daylength_h < 0 or calendar.previous_daylength_h > 24) return error.InvalidPlantDevelopmentInput;
    }
}

fn validateCalendarDate(calendar: Calendar) !void {
    const year = std.math.cast(u16, calendar.current_year) orelse
        return error.InvalidPlantDevelopmentInput;
    const maximum_day: u16 =
        if (execution_calendar_date.isLeapYear(year)) 366 else 365;
    if (year == 0 or calendar.day_of_year == 0 or
        calendar.day_of_year > maximum_day)
        return error.InvalidPlantDevelopmentInput;
}

test "HFUNC soil stress receives landscape total potential for every runtime plant" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 2,
            .lat_count = 1,
            .soil_layers = 3,
            .plant_populations = 2,
        },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 3;
    grid.active_soil_layer_count[1] = 3;
    var roots = try plant_root_system.State.init(
        std.testing.allocator,
        4,
        3,
        1,
    );
    defer roots.deinit();
    roots.planting_layer_by_plant[0] = 0;
    roots.planting_layer_by_plant[1] = 2;
    roots.planting_layer_by_plant[2] = 1;
    roots.planting_layer_by_plant[3] = 2;
    const total_potential_megapascal = [_]f64{
        -0.11, -0.22, -0.33,
        -0.44, -0.55, -0.66,
    };
    var surface_megapascal: [2]f64 = undefined;
    var seed_megapascal: [4]f64 = undefined;
    try refreshSoilWaterPotentials(
        &grid,
        &total_potential_megapascal,
        &.{ -0.2, -1.0 },
        &.{ 10, 20 },
        0.0098,
        &roots,
        &surface_megapascal,
        &seed_megapascal,
    );
    try std.testing.expectEqual(@as(f64, -0.11), surface_megapascal[0]);
    try std.testing.expectApproxEqAbs(-0.804, surface_megapascal[1], 1e-14);
    try std.testing.expectEqualSlices(
        f64,
        &.{ -0.11, -0.33, -0.55, -0.66 },
        &seed_megapascal,
    );
}

test "HFUNC development kernel advances arbitrary runtime species without shared state" {
    const allocator = std.testing.allocator;
    const species_count = 7;
    var phenology_state = try phenology.State.init(allocator, 1, species_count);
    defer phenology_state.deinit();
    @memset(phenology_state.active, true);
    @memset(phenology_state.node_initiation_per_timestep, 0.25);
    @memset(phenology_state.leaf_appearance_per_timestep, 0.2);
    const counts = try allocator.alloc(usize, species_count);
    defer allocator.free(counts);
    @memset(counts, 1);
    var growth_state = try stages.State.init(allocator, counts);
    defer growth_state.deinit();
    var dormancy_state = try dormancy.RuntimeState.init(allocator, species_count);
    defer dormancy_state.deinit();
    var branch_development = try phenology.BranchDevelopmentState.init(allocator, species_count);
    defer branch_development.deinit();
    @memset(branch_development.maturity_group, 20);
    growth_state.branches[species_count - 1].dead = true;
    const species_parameters = try allocator.alloc(stages.SpeciesParameters, species_count);
    defer allocator.free(species_parameters);
    @memset(species_parameters, .{ .growth_habit = .annual, .phenology_type = .evergreen, .photoperiod_type = .insensitive, .maturity_group_node_count = 5, .branch_floral_node_requirement = 20, .critical_photoperiod_h = 12, .photoperiod_sensitivity_h = 1, .determinate = false, .vegetative_stage_duration = 2, .reproductive_stage_duration = 0.667 });
    const dormancy_parameters = try allocator.alloc(dormancy.Parameters, species_count);
    defer allocator.free(dormancy_parameters);
    @memset(dormancy_parameters, .{ .required_leafout_h = 2, .required_leafoff_h = 2, .leafout_temperature_threshold_c = 5, .leafoff_temperature_threshold_c = 0, .chilling_temperature_c = -5, .drought_leafout_total_water_potential_megapascal = -0.1, .combined_leafout_turgor_potential_megapascal = 0.1, .leafoff_total_water_potential_megapascal = -1.5, .drought_leafoff_total_water_potential_megapascal = -2.0, .maximum_photoperiod_counter_h = 3600, .evergreen_leafoff_remobilization_start_fraction = 0.75, .deciduous_leafoff_remobilization_start_fraction = 0.5, .full_senescence_duration_h = 480 });
    const u16_values = try allocator.alloc(u16, species_count);
    defer allocator.free(u16_values);
    @memset(u16_values, 100);
    const i32_values = try allocator.alloc(i32, species_count);
    defer allocator.free(i32_values);
    @memset(i32_values, 2020);
    const f64_values = try allocator.alloc(f64, species_count);
    defer allocator.free(f64_values);
    @memset(f64_values, 1);
    const temperatures = try allocator.alloc(f64, species_count);
    defer allocator.free(temperatures);
    @memset(temperatures, 283.15);
    const emerged = try allocator.alloc(bool, species_count);
    defer allocator.free(emerged);
    @memset(emerged, true);
    var context: AdvanceContext = .{ .growth_stages = &growth_state, .dormancy_state = &dormancy_state, .phenology_state = &phenology_state, .branch_development = &branch_development, .species_parameters_by_plant = species_parameters, .dormancy_parameters_by_plant = dormancy_parameters, .planting_day_of_year_by_plant = u16_values, .planting_year_by_plant = i32_values, .canopy_height_m_by_plant = f64_values, .snow_depth_m_by_cell = &.{0}, .canopy_temperature_k_by_plant = temperatures, .canopy_turgor_potential_mpa_by_plant = f64_values, .canopy_total_water_potential_mpa_by_plant = f64_values, .surface_soil_water_potential_mpa_by_cell = &.{-0.1}, .seed_layer_soil_water_potential_mpa_by_plant = f64_values, .emerged_by_plant = emerged, .calendar_by_cell = &.{.{ .day_of_year = 150, .current_year = 2020, .current_daylength_h = 14, .previous_daylength_h = 13.9, .maximum_seasonal_daylength_h = 17, .latitude_degrees_north = 53 }}, .timestep_h = 1 };
    try advanceTile(&context, .{ .first = 0, .end = 1 });
    for (growth_state.branches, 0..) |branch, branch_index| {
        const expected_node_count: f64 = if (branch_index == species_count - 1) 0 else 0.25;
        const expected_leaf_count: f64 = if (branch_index == species_count - 1) 0 else 0.2;
        try std.testing.expectEqual(expected_node_count, branch.initiated_node_count);
        try std.testing.expectEqual(expected_leaf_count, branch.appeared_leaf_count);
    }
    species_parameters[0].growth_habit = .perennial;
    species_parameters[0].phenology_type = .drought_deciduous;
    dormancy_state.branches[0].accumulated_leafoff_h = dormancy_parameters[0].required_leafoff_h;
    growth_state.branches[0].lowest_node_nutrient_remobilization_enabled = true;
    species_parameters[1].phenology_type = .winter_deciduous;
    branch_development.maturity_group[1] = 0;
    branch_development.initial_reproductive_stage[1] = 0;
    branch_development.maturity_group[2] = 0;
    try advanceTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 0.25), growth_state.branches[0].initiated_node_count);
    try std.testing.expectEqual(@as(f64, 0.2), growth_state.branches[0].appeared_leaf_count);
    try std.testing.expect(!growth_state.branches[0].lowest_node_nutrient_remobilization_enabled);
    try std.testing.expectEqual(@as(f64, 0.25), growth_state.branches[1].initiated_node_count);
    try std.testing.expectEqual(@as(f64, 0.2), growth_state.branches[1].appeared_leaf_count);
    try std.testing.expectEqual(@as(f64, 0.5), growth_state.branches[2].initiated_node_count);
    try std.testing.expect(growth_state.branches[2].lowest_node_nutrient_remobilization_enabled);
    try std.testing.expectEqual(@as(u16, 150), growth_state.branches[2].floral_initiation_day);
}

test "GROSUB dormant reseed waits for leafout requirement before reconstruction" {
    const allocator = std.testing.allocator;
    var phenology_state = try phenology.State.init(allocator, 1, 1);
    defer phenology_state.deinit();
    phenology_state.active[0] = true;
    phenology_state.lifecycle_initialized[0] = true;
    phenology_state.reseed_pending[0] = true;
    var growth_state = try stages.State.init(allocator, &.{1});
    defer growth_state.deinit();
    growth_state.branches[0].dead = true;
    var dormancy_state = try dormancy.RuntimeState.init(allocator, 1);
    defer dormancy_state.deinit();
    var branch_development = try phenology.BranchDevelopmentState.init(allocator, 1);
    defer branch_development.deinit();
    var species_parameters = [_]stages.SpeciesParameters{.{
        .growth_habit = .annual,
        .phenology_type = .winter_deciduous,
        .photoperiod_type = .insensitive,
        .maturity_group_node_count = 1,
        .branch_floral_node_requirement = 1,
        .critical_photoperiod_h = 12,
        .photoperiod_sensitivity_h = 0,
        .determinate = true,
        .vegetative_stage_duration = 2,
        .reproductive_stage_duration = 0.667,
    }};
    const dormancy_parameters = [_]dormancy.Parameters{.{
        .required_leafout_h = 2,
        .required_leafoff_h = 10,
        .leafout_temperature_threshold_c = 5,
        .leafoff_temperature_threshold_c = 0,
        .chilling_temperature_c = -5,
        .drought_leafout_total_water_potential_megapascal = -0.1,
        .combined_leafout_turgor_potential_megapascal = 0.1,
        .leafoff_total_water_potential_megapascal = -1.5,
        .drought_leafoff_total_water_potential_megapascal = -2.0,
        .maximum_photoperiod_counter_h = 3600,
        .evergreen_leafoff_remobilization_start_fraction = 0.75,
        .deciduous_leafoff_remobilization_start_fraction = 0.5,
        .full_senescence_duration_h = 480,
    }};
    var emerged = [_]bool{false};
    const context_values = [_]f64{1};
    const temperatures_k = [_]f64{283.15};
    var context: AdvanceContext = .{
        .growth_stages = &growth_state,
        .dormancy_state = &dormancy_state,
        .phenology_state = &phenology_state,
        .branch_development = &branch_development,
        .species_parameters_by_plant = &species_parameters,
        .dormancy_parameters_by_plant = &dormancy_parameters,
        .planting_day_of_year_by_plant = &.{100},
        .planting_year_by_plant = &.{2020},
        .canopy_height_m_by_plant = &context_values,
        .snow_depth_m_by_cell = &.{0},
        .canopy_temperature_k_by_plant = &temperatures_k,
        .canopy_turgor_potential_mpa_by_plant = &context_values,
        .canopy_total_water_potential_mpa_by_plant = &context_values,
        .surface_soil_water_potential_mpa_by_cell = &.{-0.1},
        .seed_layer_soil_water_potential_mpa_by_plant = &context_values,
        .emerged_by_plant = &emerged,
        .calendar_by_cell = &.{.{ .day_of_year = 150, .current_year = 2020, .current_daylength_h = 14, .previous_daylength_h = 13.9, .maximum_seasonal_daylength_h = 17, .latitude_degrees_north = 53 }},
        .timestep_h = 1,
    };
    try advanceTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(phenology_state.active[0]);
    try std.testing.expect(phenology_state.lifecycle_initialized[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 1), dormancy_state.branches[0].accumulated_leafout_h, 1e-12);
    try advanceTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(!phenology_state.active[0]);
    try std.testing.expect(!phenology_state.lifecycle_initialized[0]);
    try std.testing.expect(phenology_state.reseed_pending[0]);
    phenology_state.active[0] = true;
    phenology_state.lifecycle_initialized[0] = true;
    phenology_state.reseed_pending[0] = false;
    emerged[0] = true;
    growth_state.branches[0].dead = false;
    dormancy_state.branches[0].accumulated_leafout_h = 0;
    species_parameters[0].growth_habit = .perennial;
    try advanceTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(!phenology_state.leafout_transition_this_step[0]);
    try advanceTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(phenology_state.leafout_transition_this_step[0]);
}

test "HFUNC emergence requires shoot clearance area and primary root depth together" {
    const allocator = std.testing.allocator;
    var canopy = try canopy_photosynthesis.State.init(allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var roots = try plant_root_system.State.init(allocator, 1, 2, 1);
    defer roots.deinit();
    var growth = try stages.State.init(allocator, &.{2});
    defer growth.deinit();
    growth.branches[0].dead = true;
    canopy.plant_population_count[0] = 10;
    canopy.plant_hypocotyledon_height_m[0] = 0.03;
    canopy.branch_leaf_area_m2[0] = 2.0e-5;
    roots.axis_depth_m[try roots.axisIndex(0, 0, 0)] = 0.04;
    var emerged = [_]bool{false};
    try refreshEmergence(&canopy, &roots, &growth, &.{0.02}, 123, 1.0e-6, 1.0e-6, &emerged);
    try std.testing.expect(emerged[0]);
    try std.testing.expectEqual(@as(u16, 0), growth.branches[0].emergence_day);
    try std.testing.expectEqual(@as(u16, 123), growth.branches[1].emergence_day);
}

test "plant development calendar preserves DAY modulo-four chronology" {
    const base: Calendar = .{
        .day_of_year = 366,
        .current_year = 1900,
        .current_daylength_h = 8,
        .previous_daylength_h = 8,
        .maximum_seasonal_daylength_h = 16,
        .latitude_degrees_north = 53,
    };
    try validateCalendarDate(base);
    var invalid = base;
    invalid.current_year = 1901;
    try std.testing.expectError(
        error.InvalidPlantDevelopmentInput,
        validateCalendarDate(invalid),
    );
    invalid = base;
    invalid.current_year = 0;
    try std.testing.expectError(
        error.InvalidPlantDevelopmentInput,
        validateCalendarDate(invalid),
    );
}

test "GROSUB hypocotyledon height uses first leaf sheath and internode geometry" {
    const allocator = std.testing.allocator;
    var canopy = try canopy_photosynthesis.State.init(allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    canopy.plant_population_per_m2[0] = 100;
    canopy.node_leaf_area_m2[0] = 4.0e-4;
    canopy.node_sheath_height_m[0] = 0.003;
    canopy.node_internode_length_m[0] = 0.004;
    try refreshHypocotyledonHeight(&canopy, &.{0.03});
    try std.testing.expectApproxEqAbs(@as(f64, 0.027), canopy.plant_hypocotyledon_height_m[0], 1.0e-15);
}

test "HFUNC WSTR follows the lowest-order living branch" {
    const allocator = std.testing.allocator;
    var growth = try stages.State.init(allocator, &.{3});
    defer growth.deinit();
    var dormancy_state = try dormancy.RuntimeState.init(allocator, 3);
    defer dormancy_state.deinit();
    growth.branches[0] = .{ .dead = true, .branch_order = 0 };
    growth.branches[1].branch_order = 2;
    growth.branches[2].branch_order = 1;
    dormancy_state.branches[0].accumulated_leafoff_h = 99;
    dormancy_state.branches[1].accumulated_leafoff_h = 7;
    dormancy_state.branches[2].accumulated_leafoff_h = 3;
    try std.testing.expectEqual(@as(f64, 3), try coldOrWaterStressHours(&growth, &dormancy_state, 0));
}

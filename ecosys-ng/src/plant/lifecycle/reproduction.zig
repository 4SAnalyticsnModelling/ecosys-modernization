const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const PlantState = @import("../../state/grid.zig").PlantState;
const canopy_module = @import("../../canopy/photosynthesis/photosynthesis.zig");
const stages_module = @import("growth_stages.zig");
const potential_seed_site_accumulation = @import("../growth/potential_seed_site_accumulation.zig");
const final_grain_number = @import("../growth/final_grain_number.zig");
const maximum_individual_grain_size = @import("../growth/maximum_individual_grain_size.zig");

pub const Controls = struct {
    allocator: std.mem.Allocator,
    potential_sites_per_g_growth: []f64,
    maximum_seeds_per_site: []f64,
    maximum_individual_seed_carbon_g: []f64,
    chilling_temperature_c: []f64,
    stomatal_turgor_shape: []f64,
    shallow_root_profile: []bool,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize) !Controls {
        if (plant_count == 0) return error.InvalidPlantReproductionDimensions;
        var result: Controls = undefined;
        result.allocator = allocator;
        var allocated: usize = 0;
        errdefer inline for (@typeInfo(Controls).@"struct".fields) |field| if (field.type == []f64 and allocated > 0) {
            allocated -= 1;
            allocator.free(@field(result, field.name));
        };
        inline for (@typeInfo(Controls).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, plant_count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        result.shallow_root_profile = try allocator.alloc(bool, plant_count);
        @memset(result.shallow_root_profile, false);
        return result;
    }

    pub fn deinit(self: *Controls) void {
        self.allocator.free(self.shallow_root_profile);
        inline for (@typeInfo(Controls).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn setPlant(self: *Controls, plant: usize, potential_sites_per_g_growth: f64, maximum_seeds_per_site: f64, maximum_individual_seed_carbon_g: f64, chilling_temperature_c: f64, stomatal_turgor_shape: f64, shallow_root_profile: bool) !void {
        if (plant >= self.potential_sites_per_g_growth.len) return error.PlantReproductionIndexOutOfBounds;
        inline for (.{ potential_sites_per_g_growth, maximum_seeds_per_site, maximum_individual_seed_carbon_g }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantReproductionControl;
        // OSTGX is a signed exponential coefficient; supplied PFTs commonly
        // use negative values (for example maize uses -5 MPa-1).
        if (!std.math.isFinite(stomatal_turgor_shape)) return error.InvalidPlantReproductionControl;
        if (!std.math.isFinite(chilling_temperature_c)) return error.InvalidPlantReproductionControl;
        self.potential_sites_per_g_growth[plant] = potential_sites_per_g_growth;
        self.maximum_seeds_per_site[plant] = maximum_seeds_per_site;
        self.maximum_individual_seed_carbon_g[plant] = maximum_individual_seed_carbon_g;
        self.chilling_temperature_c[plant] = chilling_temperature_c;
        self.stomatal_turgor_shape[plant] = stomatal_turgor_shape;
        self.shallow_root_profile[plant] = shallow_root_profile;
    }
};

/// Retained reproduction scratch partitioned by compute-pool participant.
/// Capacity changes are coordinator-only and must complete before dispatch;
/// `workerScratch` then returns disjoint memory for one stable worker index.
/// This replaces two per-cell allocations totaling 61 bytes per global
/// branch (five bools and seven f64s) without changing scratch indexing.
pub const GridWorkspace = struct {
    allocator: std.mem.Allocator,
    worker_count: usize,
    branch_capacity: usize = 0,
    boolean_storage: []bool = &.{},
    numeric_storage: []f64 = &.{},

    const boolean_fields: usize = 5;
    const numeric_fields: usize = 7;

    pub fn init(allocator: std.mem.Allocator, worker_count: usize) !GridWorkspace {
        if (worker_count == 0) return error.InvalidPlantReproductionWorkerCount;
        return .{ .allocator = allocator, .worker_count = worker_count };
    }

    pub fn deinit(self: *GridWorkspace) void {
        if (self.numeric_storage.len != 0) self.allocator.free(self.numeric_storage);
        if (self.boolean_storage.len != 0) self.allocator.free(self.boolean_storage);
        self.* = undefined;
    }

    /// Branch topology may grow between accepted hours. Reserve the current
    /// topology serially; failed growth retains the previous usable storage.
    pub fn ensureBranchCapacity(self: *GridWorkspace, branch_count: usize) !void {
        if (branch_count <= self.branch_capacity) return;
        const boolean_per_worker = try std.math.mul(usize, branch_count, boolean_fields);
        const numeric_per_worker = try std.math.mul(usize, branch_count, numeric_fields);
        const boolean_count = try std.math.mul(usize, self.worker_count, boolean_per_worker);
        const numeric_count = try std.math.mul(usize, self.worker_count, numeric_per_worker);
        const replacement_boolean = try self.allocator.alloc(bool, boolean_count);
        errdefer self.allocator.free(replacement_boolean);
        const replacement_numeric = try self.allocator.alloc(f64, numeric_count);
        errdefer self.allocator.free(replacement_numeric);
        if (self.numeric_storage.len != 0) self.allocator.free(self.numeric_storage);
        if (self.boolean_storage.len != 0) self.allocator.free(self.boolean_storage);
        self.boolean_storage = replacement_boolean;
        self.numeric_storage = replacement_numeric;
        self.branch_capacity = branch_count;
    }

    fn workerScratch(self: *GridWorkspace, worker_index: usize, branch_count: usize) !Scratch {
        if (worker_index >= self.worker_count) return error.PlantReproductionWorkerIndexOutOfBounds;
        if (branch_count > self.branch_capacity) return error.PlantReproductionWorkspaceCapacityTooSmall;
        const boolean_stride = try std.math.mul(usize, self.branch_capacity, boolean_fields);
        const numeric_stride = try std.math.mul(usize, self.branch_capacity, numeric_fields);
        const boolean_first = try std.math.mul(usize, worker_index, boolean_stride);
        const numeric_first = try std.math.mul(usize, worker_index, numeric_stride);
        const boolean_count = try std.math.mul(usize, branch_count, boolean_fields);
        const numeric_count = try std.math.mul(usize, branch_count, numeric_fields);
        return makeScratch(
            self.boolean_storage[boolean_first..][0..boolean_count],
            self.numeric_storage[numeric_first..][0..numeric_count],
            branch_count,
        );
    }
};

const Scratch = struct {
    stem_started: []bool,
    anthesis_started: []bool,
    grain_fill_started: []bool,
    final_number_set: []bool,
    maximum_size_set: []bool,
    branch_shoot_carbon_g_c: []f64,
    reproductive_increment: []f64,
    seed_site_workspace: []f64,
    grain_count_workspace: []f64,
    nutrient_set_workspace: []f64,
    thermal_loss_workspace: []f64,
    grain_size_workspace: []f64,
};

pub const ApplyContext = struct {
    canopy: *canopy_module.State,
    plants: *const PlantState,
    growth_stages: *const stages_module.State,
    controls: *const Controls,
    active_by_plant: []const bool,
    minimum_turgor_potential_megapascal: f64,
    seed_set_parameters: canopy_module.SeedSetParameters,
    structural_presence_threshold_g_per_plant: f64,
    timestep_h: f64,
    workspace: ?*GridWorkspace = null,
};

pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    const branch_count = try validateContext(context);
    if (range.end > context.canopy.cell_count) return error.PlantReproductionDimensionMismatch;
    const boolean_workspace = try context.canopy.allocator.alloc(bool, branch_count * GridWorkspace.boolean_fields);
    defer context.canopy.allocator.free(boolean_workspace);
    const numeric_workspace = try context.canopy.allocator.alloc(f64, branch_count * GridWorkspace.numeric_fields);
    defer context.canopy.allocator.free(numeric_workspace);
    var scratch = makeScratch(boolean_workspace, numeric_workspace, branch_count);
    for (range.first..range.end) |cell| try applyCell(context, cell, &scratch);
}

/// Indexed compute-pool entry point. The caller must reserve workspace
/// capacity serially before dispatching a tile.
pub fn applyOwnedCells(context: *ApplyContext, cells: []const usize, worker_index: usize) !void {
    const branch_count = try validateContext(context);
    for (cells) |cell| if (cell >= context.canopy.cell_count)
        return error.PlantReproductionDimensionMismatch;
    const workspace = context.workspace orelse return error.MissingPlantReproductionWorkspace;
    var scratch = try workspace.workerScratch(worker_index, branch_count);
    for (cells) |cell| try applyCell(context, cell, &scratch);
}

fn validateContext(context: *const ApplyContext) !usize {
    try context.seed_set_parameters.validate();
    const canopy = context.canopy;
    const plant_count = canopy.plant_branch_offsets.len - 1;
    if (context.plants.cell_count * context.plants.species_count != plant_count or context.growth_stages.plant_count != plant_count or context.active_by_plant.len != plant_count or context.controls.potential_sites_per_g_growth.len != plant_count) return error.PlantReproductionDimensionMismatch;
    return canopy.branch_node_offsets.len - 1;
}

fn makeScratch(boolean_workspace: []bool, numeric_workspace: []f64, branch_count: usize) Scratch {
    std.debug.assert(boolean_workspace.len == branch_count * GridWorkspace.boolean_fields);
    std.debug.assert(numeric_workspace.len == branch_count * GridWorkspace.numeric_fields);
    return .{
        .stem_started = boolean_workspace[0..branch_count],
        .anthesis_started = boolean_workspace[branch_count .. branch_count * 2],
        .grain_fill_started = boolean_workspace[branch_count * 2 .. branch_count * 3],
        .final_number_set = boolean_workspace[branch_count * 3 .. branch_count * 4],
        .maximum_size_set = boolean_workspace[branch_count * 4 .. branch_count * 5],
        .branch_shoot_carbon_g_c = numeric_workspace[0..branch_count],
        .reproductive_increment = numeric_workspace[branch_count .. branch_count * 2],
        .seed_site_workspace = numeric_workspace[branch_count * 2 .. branch_count * 3],
        .grain_count_workspace = numeric_workspace[branch_count * 3 .. branch_count * 4],
        .nutrient_set_workspace = numeric_workspace[branch_count * 4 .. branch_count * 5],
        .thermal_loss_workspace = numeric_workspace[branch_count * 5 .. branch_count * 6],
        .grain_size_workspace = numeric_workspace[branch_count * 6 .. branch_count * 7],
    };
}

fn applyCell(context: *ApplyContext, cell: usize, scratch: *Scratch) !void {
    const canopy = context.canopy;
    for (0..canopy.species_count) |species| {
        const plant = cell * canopy.species_count + species;
        if (!context.active_by_plant[plant]) continue;
        const structural_presence_threshold_g = try plantScaledPresenceThresholdG(
            context.structural_presence_threshold_g_per_plant,
            canopy.plant_population_count[plant],
        );
        const response = try canopy_module.canopyWaterGrowthResponse(context.controls.shallow_root_profile[plant], canopy.plant_canopy_turgor_potential_megapascal[plant], context.minimum_turgor_potential_megapascal, context.plants.canopy_water_potential_megapascal[plant], context.controls.stomatal_turgor_shape[plant]);
        const branches = try canopy.branchRange(plant);
        for (branches.first..branches.end) |branch| {
            const stage = context.growth_stages.branches[branch];
            const active = !stage.dead;
            scratch.stem_started[branch] = active and stage.stem_elongation_start_day != 0;
            scratch.anthesis_started[branch] = active and stage.anthesis_day != 0;
            scratch.grain_fill_started[branch] = scratch.anthesis_started[branch] and stage.grain_fill_start_day != 0;
            scratch.final_number_set[branch] = stage.seed_number_set_end_day != 0;
            scratch.maximum_size_set[branch] = stage.seed_size_set_end_day != 0;
            scratch.branch_shoot_carbon_g_c[branch] = try branchShootCarbon(canopy, branch);
            scratch.reproductive_increment[branch] = stage.reproductive_stage_increment;
        }
        try potential_seed_site_accumulation.apply(.{ .potential_seed_site_count = canopy.branch_potential_seed_site_count }, scratch.seed_site_workspace, .{
            .first_branch = branches.first,
            .end_branch = branches.end,
            .stem_elongation_started = scratch.stem_started,
            .anthesis_started = scratch.anthesis_started,
            .branch_shoot_carbon_g_c = scratch.branch_shoot_carbon_g_c,
            .canopy_shoot_carbon_g_c = canopy.plant_total_shoot_carbon_g[plant],
            .canopy_shoot_growth_g_c_per_timestep = canopy.plant_shoot_growth_g_c_per_step[plant],
            .potential_seed_sites_per_g_c_growth = context.controls.potential_sites_per_g_growth[plant],
            .structural_presence_threshold_g_c = structural_presence_threshold_g,
        });
        try final_grain_number.apply(.{ .grain_count = canopy.branch_seed_count }, .{ .grain_count = scratch.grain_count_workspace, .nutrient_set_fraction = scratch.nutrient_set_workspace, .thermal_loss_fraction = scratch.thermal_loss_workspace }, .{
            .first_branch = branches.first,
            .end_branch = branches.end,
            .anthesis_started = scratch.anthesis_started,
            .grain_fill_started = scratch.grain_fill_started,
            .final_grain_number_set = scratch.final_number_set,
            .maximum_grain_size_set = scratch.maximum_size_set,
            .mobile_carbon_g_c_per_g_c = canopy.branch_mobile_carbon_concentration_g_per_g,
            .mobile_nitrogen_g_n_per_g_c = canopy.branch_mobile_nitrogen_concentration_g_per_g,
            .mobile_phosphorus_g_p_per_g_c = canopy.branch_mobile_phosphorus_concentration_g_per_g,
            .potential_seed_sites = canopy.branch_potential_seed_site_count,
            .reproductive_stage_increment = scratch.reproductive_increment,
            .carbon_half_saturation_g_c_per_g_c = context.seed_set_parameters.carbon_half_saturation_g_per_g,
            .nitrogen_half_saturation_g_n_per_g_c = context.seed_set_parameters.nitrogen_half_saturation_g_per_g,
            .phosphorus_half_saturation_g_p_per_g_c = context.seed_set_parameters.phosphorus_half_saturation_g_per_g,
            .canopy_temperature_c = context.plants.canopy_temperature_k[plant] - 273.15,
            .chilling_temperature_c = context.controls.chilling_temperature_c[plant],
            .high_temperature_c = canopy.plant_seed_set_high_temperature_c[plant],
            .seed_loss_fraction_per_c_h = canopy.plant_seed_set_loss_fraction_per_c_h[plant],
            .timestep_h = context.timestep_h,
            .water_growth_fraction = response.growth_fraction,
            .maximum_seeds_per_site = context.controls.maximum_seeds_per_site[plant],
        });
        try maximum_individual_grain_size.apply(.{ .individual_grain_carbon_g_c = canopy.branch_individual_seed_carbon_g }, scratch.grain_size_workspace, .{
            .first_branch = branches.first,
            .end_branch = branches.end,
            .grain_fill_started = scratch.grain_fill_started,
            .maximum_grain_size_set = scratch.maximum_size_set,
            .nutrient_set_fraction = scratch.nutrient_set_workspace,
            .reproductive_stage_increment = scratch.reproductive_increment,
            .water_growth_fraction = response.growth_fraction,
            .maximum_individual_grain_carbon_g_c = context.controls.maximum_individual_seed_carbon_g[plant],
        });
    }
}

fn plantScaledPresenceThresholdG(threshold_g_per_plant: f64, plant_population_count: f64) !f64 {
    if (!std.math.isFinite(threshold_g_per_plant) or threshold_g_per_plant < 0 or
        !std.math.isFinite(plant_population_count) or plant_population_count < 0)
    {
        return error.InvalidPlantReproductionPresenceThreshold;
    }
    const threshold_g = threshold_g_per_plant * plant_population_count;
    if (!std.math.isFinite(threshold_g)) return error.NonFinitePlantReproductionPresenceThreshold;
    return threshold_g;
}

test "GROSUB ZEROP scales the per-plant presence threshold by current population" {
    try std.testing.expectEqual(
        @as(f64, 1.0e-15) * @as(f64, 300.0),
        try plantScaledPresenceThresholdG(1.0e-15, 300.0),
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        try plantScaledPresenceThresholdG(1.0e-15, 0),
    );
    try std.testing.expectError(
        error.InvalidPlantReproductionPresenceThreshold,
        plantScaledPresenceThresholdG(1.0e-15, -1),
    );
}

fn branchShootCarbon(canopy: *const canopy_module.State, branch: usize) !f64 {
    if (branch >= canopy.branch_mobile_carbon_g.len) return error.CanopyBranchIndexOutOfBounds;
    var total = canopy.branch_leaf_carbon_g[branch] + canopy.branch_sheath_carbon_g[branch] + canopy.branch_stalk_carbon_g[branch] + canopy.branch_reserve_carbon_g[branch] + canopy.branch_husk_carbon_g[branch] + canopy.branch_ear_carbon_g[branch] + canopy.branch_grain_carbon_g[branch] + canopy.branch_mobile_carbon_g[branch];
    const nodes = try canopy.nodeRange(branch);
    for (nodes.first..nodes.end) |node| total += canopy.node_c3_nonstructural_carbon_g[node] + canopy.node_c4_mesophyll_nonstructural_carbon_g[node] + canopy.node_bundle_sheath_co2_carbon_g[node] + canopy.node_bundle_sheath_bicarbonate_carbon_g[node];
    if (!std.math.isFinite(total) or total < 0) return error.InvalidBranchShootCarbon;
    return total;
}

test "GROSUB reproduction kernel advances arbitrary runtime plants" {
    const allocator = std.testing.allocator;
    var canopy = try canopy_module.State.init(allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var plants = try PlantState.init(allocator, try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 }));
    defer plants.deinit();
    var stages = try stages_module.State.init(allocator, &.{1});
    defer stages.deinit();
    var controls = try Controls.init(allocator, 1);
    defer controls.deinit();
    try controls.setPlant(0, 3, 4, 0.5, 5, 1, false);
    canopy.branch_leaf_carbon_g[0] = 20;
    canopy.plant_total_shoot_carbon_g[0] = 20;
    canopy.plant_shoot_growth_g_c_per_step[0] = 2;
    canopy.branch_mobile_carbon_concentration_g_per_g[0] = 0.1;
    canopy.branch_mobile_nitrogen_concentration_g_per_g[0] = 0.02;
    canopy.branch_mobile_phosphorus_concentration_g_per_g[0] = 0.004;
    canopy.plant_seed_set_high_temperature_c[0] = 40;
    canopy.plant_seed_set_loss_fraction_per_c_h[0] = 0.01;
    canopy.plant_canopy_turgor_potential_megapascal[0] = 0.2;
    plants.canopy_water_potential_megapascal[0] = -0.5;
    plants.canopy_temperature_k[0] = 298.15;
    stages.branches[0].stem_elongation_start_day = 1;
    var context: ApplyContext = .{ .canopy = &canopy, .plants = &plants, .growth_stages = &stages, .controls = &controls, .active_by_plant = &.{true}, .minimum_turgor_potential_megapascal = 0.1, .seed_set_parameters = canopy_module.compatibilitySeedSetParameters(), .structural_presence_threshold_g_per_plant = 1.0e-12, .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 6), canopy.branch_potential_seed_site_count[0], 1.0e-14);
}

test "GROSUB final grain-number branch sweep rejects a late branch atomically" {
    const allocator = std.testing.allocator;
    var canopy = try canopy_module.State.init(allocator, 1, 1, &.{2}, &.{ 1, 1 }, &.{ 0, 0 });
    defer canopy.deinit();
    var plants = try PlantState.init(allocator, try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 }));
    defer plants.deinit();
    var stages = try stages_module.State.init(allocator, &.{2});
    defer stages.deinit();
    var controls = try Controls.init(allocator, 1);
    defer controls.deinit();
    try controls.setPlant(0, 3, 4, 0.5, 5, 1, false);
    canopy.plant_total_shoot_carbon_g[0] = 2;
    canopy.plant_population_count[0] = 1;
    canopy.branch_leaf_carbon_g[0] = 1;
    canopy.branch_leaf_carbon_g[1] = 1;
    canopy.branch_seed_count[0] = 2;
    canopy.branch_seed_count[1] = 3;
    @memset(canopy.branch_mobile_carbon_concentration_g_per_g, 0.2);
    @memset(canopy.branch_mobile_nitrogen_concentration_g_per_g, 0.1);
    canopy.branch_mobile_phosphorus_concentration_g_per_g[0] = 0.05;
    canopy.branch_mobile_phosphorus_concentration_g_per_g[1] = std.math.nan(f64);
    canopy.plant_seed_set_high_temperature_c[0] = 40;
    canopy.plant_canopy_turgor_potential_megapascal[0] = 0.2;
    plants.canopy_water_potential_megapascal[0] = -0.5;
    plants.canopy_temperature_k[0] = 298.15;
    for (stages.branches) |*stage| {
        stage.anthesis_day = 1;
        stage.reproductive_stage_increment = 0.1;
    }
    var context: ApplyContext = .{ .canopy = &canopy, .plants = &plants, .growth_stages = &stages, .controls = &controls, .active_by_plant = &.{true}, .minimum_turgor_potential_megapascal = 0.1, .seed_set_parameters = canopy_module.compatibilitySeedSetParameters(), .structural_presence_threshold_g_per_plant = 1.0e-12, .timestep_h = 1 };
    try std.testing.expectError(error.InvalidFinalGrainNumberState, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqualSlices(f64, &.{ 2, 3 }, canopy.branch_seed_count);
}

test "source negative stomatal turgor coefficient is retained" {
    var controls = try Controls.init(std.testing.allocator, 1);
    defer controls.deinit();
    try controls.setPlant(0, 1.2, 6, 0.2, -1, -5, false);
    try std.testing.expectEqual(@as(f64, -5), controls.stomatal_turgor_shape[0]);
}

test "reproduction worker workspace retains capacity without steady allocations" {
    var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var workspace = try GridWorkspace.init(counter.allocator(), 4);
    defer workspace.deinit();
    try workspace.ensureBranchCapacity(37);
    try std.testing.expectEqual(@as(usize, 2), counter.alloc_index);
    try std.testing.expectEqual(@as(usize, 2), counter.allocations);
    const expected_bytes = 4 * 37 *
        (GridWorkspace.boolean_fields * @sizeOf(bool) + GridWorkspace.numeric_fields * @sizeOf(f64));
    try std.testing.expectEqual(expected_bytes, counter.allocated_bytes);

    const allocations_after_reserve = counter.alloc_index;
    for (0..100) |_| {
        try workspace.ensureBranchCapacity(37);
        for (0..4) |worker_index| {
            const scratch = try workspace.workerScratch(worker_index, 37);
            try std.testing.expectEqual(@as(usize, 37), scratch.stem_started.len);
            try std.testing.expectEqual(@as(usize, 37), scratch.grain_size_workspace.len);
        }
    }
    try std.testing.expectEqual(allocations_after_reserve, counter.alloc_index);

    const worker_zero = try workspace.workerScratch(0, 37);
    const worker_one = try workspace.workerScratch(1, 37);
    try std.testing.expect(@intFromPtr(worker_zero.stem_started.ptr) != @intFromPtr(worker_one.stem_started.ptr));
    try std.testing.expect(@intFromPtr(worker_zero.grain_size_workspace.ptr) != @intFromPtr(worker_one.grain_size_workspace.ptr));

    // A partially failed growth reserve frees only its replacement prefix and
    // leaves the prior worker partitions valid.
    counter.fail_index = counter.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, workspace.ensureBranchCapacity(38));
    try std.testing.expectEqual(@as(usize, 37), workspace.branch_capacity);
    _ = try workspace.workerScratch(3, 37);
}

test "reproduction worker scratch is bitwise equivalent under disjoint grid concurrency" {
    const allocator = std.testing.allocator;
    var baseline_canopy = try canopy_module.State.init(allocator, 2, 1, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 0, 0 });
    defer baseline_canopy.deinit();
    var plants = try PlantState.init(allocator, try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 2, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 }));
    defer plants.deinit();
    var stages = try stages_module.State.init(allocator, &.{ 1, 1 });
    defer stages.deinit();
    var controls = try Controls.init(allocator, 2);
    defer controls.deinit();
    for (0..2) |plant| {
        try controls.setPlant(plant, 3, 4, 0.5, 5, 1, false);
        baseline_canopy.branch_leaf_carbon_g[plant] = 20 + @as(f64, @floatFromInt(plant));
        baseline_canopy.plant_total_shoot_carbon_g[plant] = baseline_canopy.branch_leaf_carbon_g[plant];
        baseline_canopy.plant_shoot_growth_g_c_per_step[plant] = 2;
        baseline_canopy.branch_mobile_carbon_concentration_g_per_g[plant] = 0.1;
        baseline_canopy.branch_mobile_nitrogen_concentration_g_per_g[plant] = 0.02;
        baseline_canopy.branch_mobile_phosphorus_concentration_g_per_g[plant] = 0.004;
        baseline_canopy.plant_seed_set_high_temperature_c[plant] = 40;
        baseline_canopy.plant_seed_set_loss_fraction_per_c_h[plant] = 0.01;
        baseline_canopy.plant_canopy_turgor_potential_megapascal[plant] = 0.2;
        plants.canopy_water_potential_megapascal[plant] = -0.5;
        plants.canopy_temperature_k[plant] = 298.15;
        stages.branches[plant].stem_elongation_start_day = 1;
    }
    var worker_canopy = try baseline_canopy.clone();
    defer worker_canopy.deinit();
    const active = [_]bool{ true, true };
    var baseline_context: ApplyContext = .{ .canopy = &baseline_canopy, .plants = &plants, .growth_stages = &stages, .controls = &controls, .active_by_plant = &active, .minimum_turgor_potential_megapascal = 0.1, .seed_set_parameters = canopy_module.compatibilitySeedSetParameters(), .structural_presence_threshold_g_per_plant = 1.0e-12, .timestep_h = 1 };
    try applyTile(&baseline_context, .{ .first = 0, .end = 2 });

    var workspace = try GridWorkspace.init(allocator, 2);
    defer workspace.deinit();
    try workspace.ensureBranchCapacity(2);
    var worker_context: ApplyContext = .{ .canopy = &worker_canopy, .plants = &plants, .growth_stages = &stages, .controls = &controls, .active_by_plant = &active, .minimum_turgor_potential_megapascal = 0.1, .seed_set_parameters = canopy_module.compatibilitySeedSetParameters(), .structural_presence_threshold_g_per_plant = 1.0e-12, .timestep_h = 1, .workspace = &workspace };
    const Worker = struct {
        fn run(context: *ApplyContext, cell: usize, worker_index: usize, failed: *std.atomic.Value(bool)) void {
            var cells = [1]usize{cell};
            applyOwnedCells(context, &cells, worker_index) catch {
                failed.store(true, .release);
            };
        }
    };
    var failed = std.atomic.Value(bool).init(false);
    const first = try std.Thread.spawn(.{}, Worker.run, .{ &worker_context, 0, 0, &failed });
    const second = std.Thread.spawn(.{}, Worker.run, .{ &worker_context, 1, 1, &failed }) catch |err| {
        first.join();
        return err;
    };
    first.join();
    second.join();
    try std.testing.expect(!failed.load(.acquire));

    try std.testing.expectEqualSlices(f64, baseline_canopy.branch_potential_seed_site_count, worker_canopy.branch_potential_seed_site_count);
    try std.testing.expectEqualSlices(f64, baseline_canopy.branch_seed_count, worker_canopy.branch_seed_count);
    try std.testing.expectEqualSlices(f64, baseline_canopy.branch_individual_seed_carbon_g, worker_canopy.branch_individual_seed_carbon_g);
}

test "production reproduction scratch reserves serially and stays outside rollback state" {
    const stage_source = @embedFile("../../stages/hourly_vegetation.zig");
    const driver_source = @embedFile("../../ecosys_ng.zig");
    const reserve = std.mem.indexOf(
        u8,
        stage_source,
        "plant_reproduction_workspace.ensureBranchCapacity",
    ) orelse return error.MissingPlantReproductionWorkspaceReserve;
    const dispatch = std.mem.indexOfPos(
        u8,
        stage_source,
        reserve,
        "runIndexedKernelAcrossSerialTiles(context, &reproduction_context, ecosys.plant_reproduction.applyOwnedCells)",
    ) orelse return error.MissingPlantReproductionIndexedDispatch;
    try std.testing.expect(reserve < dispatch);
    try std.testing.expect(std.mem.indexOf(
        u8,
        driver_source,
        "resources.ownDeinit(&plant_reproduction_workspace);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        driver_source,
        "&driver_context.hourly_science_context.*.plant_reproduction_workspace.*",
    ) != null);
}

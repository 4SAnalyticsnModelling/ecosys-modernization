const std = @import("std");
const canopy_photosynthesis = @import("../canopy/photosynthesis/photosynthesis.zig");
const execution_calendar_date = @import("../driver/execution_calendar_date.zig");
const plant_growth_stages = @import("../plant/lifecycle/growth_stages.zig");
const plant_dormancy = @import("../plant/lifecycle/dormancy.zig");
const plant_phenology = @import("../plant/lifecycle/phenology.zig");
const plant_root_system = @import("../plant/root/plant_root_system.zig");

pub const Controls = struct {
    allocator: std.mem.Allocator,
    shoot_branching_carbon_fraction: []f64,
    root_branching_carbon_fraction: []f64,
    growth_habit_code: []u8,
    leaf_phenology_code: []u8,
    aboveground_turnover_type: []u8,
    initial_maturity_group: []f64,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize) !Controls {
        if (plant_count == 0) return error.InvalidPlantTopologyDimensions;
        const shoot = try allocator.alloc(f64, plant_count);
        errdefer allocator.free(shoot);
        const root = try allocator.alloc(f64, plant_count);
        errdefer allocator.free(root);
        const growth_habit = try allocator.alloc(u8, plant_count);
        errdefer allocator.free(growth_habit);
        const leaf_phenology = try allocator.alloc(u8, plant_count);
        errdefer allocator.free(leaf_phenology);
        const turnover_type = try allocator.alloc(u8, plant_count);
        errdefer allocator.free(turnover_type);
        const maturity = try allocator.alloc(f64, plant_count);
        @memset(shoot, 0);
        @memset(root, 0);
        @memset(growth_habit, 0);
        @memset(leaf_phenology, 0);
        @memset(turnover_type, 0);
        @memset(maturity, 0);
        return .{ .allocator = allocator, .shoot_branching_carbon_fraction = shoot, .root_branching_carbon_fraction = root, .growth_habit_code = growth_habit, .leaf_phenology_code = leaf_phenology, .aboveground_turnover_type = turnover_type, .initial_maturity_group = maturity };
    }

    pub fn deinit(self: *Controls) void {
        self.allocator.free(self.initial_maturity_group);
        self.allocator.free(self.aboveground_turnover_type);
        self.allocator.free(self.leaf_phenology_code);
        self.allocator.free(self.growth_habit_code);
        self.allocator.free(self.root_branching_carbon_fraction);
        self.allocator.free(self.shoot_branching_carbon_fraction);
        self.* = undefined;
    }

    pub fn setPlant(self: *Controls, plant: usize, shoot_fraction: f64, root_fraction: f64, growth_habit_code: u8, leaf_phenology_code: u8, aboveground_turnover_type: u8, initial_maturity_group: f64) !void {
        if (plant >= self.shoot_branching_carbon_fraction.len) return error.PlantTopologyIndexOutOfBounds;
        if (!std.math.isFinite(shoot_fraction) or shoot_fraction < 0 or !std.math.isFinite(root_fraction) or root_fraction < 0 or !std.math.isFinite(initial_maturity_group) or initial_maturity_group < 0) return error.InvalidPlantTopologyControl;
        _ = try plant_phenology.maximumBranchNumber(aboveground_turnover_type);
        self.shoot_branching_carbon_fraction[plant] = shoot_fraction;
        self.root_branching_carbon_fraction[plant] = root_fraction;
        self.growth_habit_code[plant] = growth_habit_code;
        self.leaf_phenology_code[plant] = leaf_phenology_code;
        self.aboveground_turnover_type[plant] = aboveground_turnover_type;
        self.initial_maturity_group[plant] = initial_maturity_group;
    }
};

pub const RuntimeStates = struct {
    canopy: *canopy_photosynthesis.State,
    growth_stages: *plant_growth_stages.State,
    dormancy: *plant_dormancy.RuntimeState,
    branch_development: *plant_phenology.BranchDevelopmentState,
};

pub const NewShootBranch = struct {
    sample_count_by_node: []const usize,
    growth_stage: plant_growth_stages.BranchState = .{},
    dormancy: plant_dormancy.State = .{},
    maturity_group: f64,
    seed_initial_stage: f64,
    leafout_initialization_enabled: bool,
    perennial_node_scaling: f64,
    maximum_concurrently_growing_nodes: usize,

    fn validate(self: NewShootBranch) !void {
        if (self.sample_count_by_node.len == 0) return error.NewShootBranchRequiresNode;
        for (self.sample_count_by_node) |count| if (count == 0) return error.NewShootBranchRequiresSample;
        if (!std.math.isFinite(self.maturity_group) or self.maturity_group < 0 or !std.math.isFinite(self.seed_initial_stage) or self.seed_initial_stage < 0 or !std.math.isFinite(self.perennial_node_scaling) or self.perennial_node_scaling < 1 or self.maximum_concurrently_growing_nodes == 0) return error.InvalidNewShootBranch;
    }
};

/// Rebuilds every compact branch-indexed state off to the side and publishes
/// all four replacements only after every allocation and initialization has
/// succeeded. An allocation failure therefore cannot misalign branch indices.
pub fn appendShootBranch(states: RuntimeStates, plant: usize, request: NewShootBranch) !usize {
    try request.validate();
    if (states.canopy.plant_branch_offsets.len != states.growth_stages.plant_branch_offsets.len or states.canopy.branch_node_offsets.len - 1 != states.growth_stages.branches.len or states.growth_stages.branches.len != states.dormancy.branches.len or states.dormancy.branches.len != states.branch_development.branch_count) return error.PlantTopologyStateMismatch;

    var next_canopy = try states.canopy.clone();
    errdefer next_canopy.deinit();
    var next_growth = try states.growth_stages.clone();
    errdefer next_growth.deinit();
    var next_dormancy = try states.dormancy.clone();
    errdefer next_dormancy.deinit();
    var next_development = try states.branch_development.clone();
    errdefer next_development.deinit();

    const canopy_branch = try next_canopy.appendBranch(plant, request.sample_count_by_node);
    const growth_branch = try next_growth.appendBranch(plant, request.growth_stage);
    if (canopy_branch != growth_branch) return error.PlantTopologyInsertionMismatch;
    try next_dormancy.insertBranch(canopy_branch, request.dormancy);
    try next_development.insertBranch(canopy_branch);
    try next_development.initializeRange(canopy_branch, canopy_branch + 1, request.maturity_group, request.seed_initial_stage, request.leafout_initialization_enabled, request.perennial_node_scaling, request.maximum_concurrently_growing_nodes);

    var old_canopy = states.canopy.*;
    var old_growth = states.growth_stages.*;
    var old_dormancy = states.dormancy.*;
    var old_development = states.branch_development.*;
    states.canopy.* = next_canopy;
    states.growth_stages.* = next_growth;
    states.dormancy.* = next_dormancy;
    states.branch_development.* = next_development;
    old_canopy.deinit();
    old_growth.deinit();
    old_dormancy.deinit();
    old_development.deinit();
    return canopy_branch;
}

/// Atomically returns a replanted population to STARTQ's single shoot branch
/// and single initial node while preserving every neighboring plant.
pub fn compactPlantToInitialTopology(states: RuntimeStates, plant: usize) !void {
    if (states.canopy.plant_branch_offsets.len != states.growth_stages.plant_branch_offsets.len or states.canopy.branch_node_offsets.len - 1 != states.growth_stages.branches.len or states.growth_stages.branches.len != states.dormancy.branches.len or states.dormancy.branches.len != states.branch_development.branch_count) return error.PlantTopologyStateMismatch;
    const old_range = try states.growth_stages.branchRange(plant);
    if (old_range.first == old_range.end) return error.PlantInitialTopologyMissingBranch;
    const old_node_range = try states.canopy.nodeRange(old_range.first);
    if (old_range.end - old_range.first == 1 and old_node_range.end - old_node_range.first == 1) return;

    var next_canopy = try states.canopy.clone();
    errdefer next_canopy.deinit();
    var next_growth = try states.growth_stages.clone();
    errdefer next_growth.deinit();
    var next_dormancy = try states.dormancy.clone();
    errdefer next_dormancy.deinit();
    var next_development = try states.branch_development.clone();
    errdefer next_development.deinit();

    try next_canopy.compactPlantToInitialTopology(plant);
    try next_growth.compactPlantToInitialTopology(plant);
    try next_dormancy.removeRange(old_range.first + 1, old_range.end);
    try next_development.removeRange(old_range.first + 1, old_range.end);
    if (next_canopy.branch_node_offsets.len - 1 != next_growth.branches.len or next_growth.branches.len != next_dormancy.branches.len or next_dormancy.branches.len != next_development.branch_count) return error.PlantTopologyCompactionMismatch;

    var old_canopy = states.canopy.*;
    var old_growth = states.growth_stages.*;
    var old_dormancy = states.dormancy.*;
    var old_development = states.branch_development.*;
    states.canopy.* = next_canopy;
    states.growth_stages.* = next_growth;
    states.dormancy.* = next_dormancy;
    states.branch_development.* = next_development;
    old_canopy.deinit();
    old_growth.deinit();
    old_dormancy.deinit();
    old_development.deinit();
}

pub const RootAxisContext = struct {
    roots: *plant_root_system.State,
    canopy: *const canopy_photosynthesis.State,
    growth_stages: *const plant_growth_stages.State,
    branch_development: *const plant_phenology.BranchDevelopmentState,
    active_by_plant: []const bool,
    root_branching_carbon_fraction: []const f64,
    minimum_root_turgor_potential_megapascal: f64,
};

/// Applies the HFUNC NRT predicate once per hour. The deepest layer containing
/// root carbon is NG; before root growth, the runtime planting layer is used.
pub fn advanceRootAxes(context: RootAxisContext) !usize {
    const plant_count = context.roots.plant_count;
    if (context.canopy.plant_branch_offsets.len != plant_count + 1 or context.growth_stages.plant_count != plant_count or context.active_by_plant.len != plant_count or context.root_branching_carbon_fraction.len != plant_count) return error.PlantTopologyStateMismatch;
    var activated: usize = 0;
    for (0..plant_count) |plant| {
        if (!context.active_by_plant[plant]) continue;
        const branch_range = try context.growth_stages.branchRange(plant);
        if (branch_range.first == branch_range.end) continue;
        const main_branch = (try context.growth_stages.mainLivingBranch(plant)) orelse continue;
        const canopy_range = try context.canopy.branchRange(plant);
        if (canopy_range.first != main_branch or canopy_range.end != branch_range.end or main_branch >= context.branch_development.branch_count) return error.PlantTopologyStateMismatch;
        var deepest_layer = context.roots.planting_layer_by_plant[plant];
        for (0..context.roots.soil_layer_count) |layer| {
            const root = try context.roots.layerIndex(plant, 0, layer);
            if (context.roots.total_carbon_g[root] > 0) deepest_layer = layer;
        }
        const root = try context.roots.layerIndex(plant, 0, deepest_layer);
        var reserve_carbon_g = context.canopy.plant_seed_storage_carbon_g[plant];
        for (canopy_range.first..canopy_range.end) |branch| reserve_carbon_g += context.canopy.branch_reserve_carbon_g[branch];
        const changed = try plant_phenology.activateNextRootAxis(context.roots, plant, context.roots.turgor_water_potential_megapascal[root], context.minimum_root_turgor_potential_megapascal, context.growth_stages.branches[main_branch].initiated_node_count, context.branch_development.perennial_node_scaling[main_branch], context.branch_development.initial_reproductive_stage[main_branch], reserve_carbon_g, context.canopy.plant_mobile_carbon_concentration_g_per_g[plant], context.root_branching_carbon_fraction[plant]);
        activated += @intFromBool(changed);
    }
    return activated;
}

pub const ShootBranchContext = struct {
    states: RuntimeStates,
    roots: *const plant_root_system.State,
    controls: *const Controls,
    active_by_plant: []const bool,
    emerged_by_plant: []const bool,
    day_of_year: u16,
    execution_year: u16,
    minimum_root_turgor_potential_megapascal: f64,
};

/// Evaluates HFUNC shoot branching serially because successful decisions
/// rebuild compact topology. Hourly numerical kernels remain grid-parallel.
pub fn advanceShootBranches(context: ShootBranchContext) !usize {
    const plant_count = context.roots.plant_count;
    if (context.active_by_plant.len != plant_count or context.emerged_by_plant.len != plant_count or context.controls.shoot_branching_carbon_fraction.len != plant_count) return error.PlantTopologyStateMismatch;
    _ = execution_calendar_date.fromDayOfYear(
        context.day_of_year,
        context.execution_year,
    ) catch return error.InvalidPlantTopologyDate;
    var initiated: usize = 0;
    for (0..plant_count) |plant| {
        if (!context.active_by_plant[plant]) continue;
        const range = try context.states.growth_stages.branchRange(plant);
        if (range.first == range.end) continue;
        const main = (try context.states.growth_stages.mainLivingBranch(plant)) orelse continue;
        if (main >= context.states.branch_development.branch_count) return error.PlantTopologyStateMismatch;
        var deepest_layer = context.roots.planting_layer_by_plant[plant];
        for (0..context.roots.soil_layer_count) |layer| if (context.roots.total_carbon_g[try context.roots.layerIndex(plant, 0, layer)] > 0) {
            deepest_layer = layer;
        };
        const root = try context.roots.layerIndex(plant, 0, deepest_layer);
        var reserve_carbon_g = context.states.canopy.plant_seed_storage_carbon_g[plant];
        for (range.first..range.end) |branch| reserve_carbon_g += context.states.canopy.branch_reserve_carbon_g[branch];
        const main_stage = context.states.growth_stages.branches[main];
        const decision = try plant_phenology.shootBranchDecision(false, true, context.states.canopy.plant_population_per_m2[plant], context.roots.turgor_water_potential_megapascal[root], context.minimum_root_turgor_potential_megapascal, context.controls.growth_habit_code[plant], context.controls.leaf_phenology_code[plant], context.controls.aboveground_turnover_type[plant], main_stage.floral_initiation_day, range.end - range.first, reserve_carbon_g, context.states.canopy.plant_mobile_carbon_concentration_g_per_g[plant], context.controls.shoot_branching_carbon_fraction[plant], range.end, main, main_stage.initiated_node_count, range.end - range.first, context.states.branch_development.maximum_concurrently_growing_nodes[main], context.states.branch_development.perennial_node_scaling[main], context.states.branch_development.initial_reproductive_stage[main], context.controls.initial_maturity_group[plant]);
        if (!decision.initiate) continue;
        const seed_stage = context.states.branch_development.initial_reproductive_stage[main];
        const branch_emerged = context.emerged_by_plant[plant] or main_stage.emergence_day != 0;
        _ = try appendShootBranch(context.states, plant, .{
            .sample_count_by_node = &.{1},
            .growth_stage = .{
                .branch_order = decision.branch_order,
                .emergence_day = if (branch_emerged) context.day_of_year else 0,
                .initiated_node_count = seed_stage,
                .appeared_leaf_count = seed_stage,
            },
            .dormancy = .{
                .accumulated_leafout_h = if (branch_emerged) 0.5 * context.states.dormancy.branches[main].accumulated_leafout_h else 0,
                .leafout_disabled = branch_emerged,
                .leafoff_disabled = branch_emerged and context.controls.growth_habit_code[plant] == 0 and context.controls.leaf_phenology_code[plant] == 1,
            },
            .maturity_group = decision.maturity_group,
            .seed_initial_stage = seed_stage,
            .leafout_initialization_enabled = context.states.branch_development.leafout_initialization_enabled[main],
            .perennial_node_scaling = context.states.branch_development.perennial_node_scaling[main],
            .maximum_concurrently_growing_nodes = context.states.branch_development.maximum_concurrently_growing_nodes[main],
        });
        initiated += 1;
    }
    return initiated;
}

test "HFUNC shoot insertion keeps every runtime branch ledger aligned" {
    const allocator = std.testing.allocator;
    var canopy = try canopy_photosynthesis.State.init(allocator, 1, 2, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 1, 1 });
    defer canopy.deinit();
    var growth = try plant_growth_stages.State.init(allocator, &.{ 1, 1 });
    defer growth.deinit();
    var dormancy = try plant_dormancy.RuntimeState.init(allocator, 2);
    defer dormancy.deinit();
    var development = try plant_phenology.BranchDevelopmentState.init(allocator, 2);
    defer development.deinit();
    canopy.branch_mobile_carbon_g[1] = 9;
    growth.branches[1].initiated_node_count = 9;
    dormancy.branches[1].accumulated_leafout_h = 9;
    dormancy.branches[1].reproductive_growth_disabled = true;
    dormancy.branches[1].reproductive_litterfall_delay_h = 42;
    development.maturity_group[1] = 9;

    const inserted = try appendShootBranch(.{ .canopy = &canopy, .growth_stages = &growth, .dormancy = &dormancy, .branch_development = &development }, 0, .{ .sample_count_by_node = &.{ 2, 1 }, .growth_stage = .{ .initiated_node_count = 2 }, .maturity_group = 7, .seed_initial_stage = 2, .leafout_initialization_enabled = true, .perennial_node_scaling = 3, .maximum_concurrently_growing_nodes = 12 });
    try std.testing.expectEqual(@as(usize, 1), inserted);
    try std.testing.expectEqual(@as(usize, 3), canopy.branch_node_offsets.len - 1);
    try std.testing.expectEqual(@as(usize, 3), growth.branches.len);
    try std.testing.expectEqual(@as(usize, 3), dormancy.branches.len);
    try std.testing.expectEqual(@as(usize, 3), development.branch_count);
    try std.testing.expectEqual(@as(f64, 2), growth.branches[1].initiated_node_count);
    try std.testing.expectEqual(@as(f64, 7), development.maturity_group[1]);
    try std.testing.expectEqual(@as(f64, 9), canopy.branch_mobile_carbon_g[2]);
    try std.testing.expectEqual(@as(f64, 9), growth.branches[2].initiated_node_count);
    try std.testing.expectEqual(@as(f64, 9), dormancy.branches[2].accumulated_leafout_h);
    try std.testing.expect(dormancy.branches[2].reproductive_growth_disabled);
    try std.testing.expectEqual(@as(f64, 42), dormancy.branches[2].reproductive_litterfall_delay_h);
    try std.testing.expectEqual(@as(f64, 9), development.maturity_group[2]);
}

test "replant compaction atomically restores aligned STARTQ topology" {
    const allocator = std.testing.allocator;
    var canopy = try canopy_photosynthesis.State.init(allocator, 1, 2, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 2, 3 });
    defer canopy.deinit();
    var growth = try plant_growth_stages.State.init(allocator, &.{ 1, 1 });
    defer growth.deinit();
    var dormancy = try plant_dormancy.RuntimeState.init(allocator, 2);
    defer dormancy.deinit();
    var development = try plant_phenology.BranchDevelopmentState.init(allocator, 2);
    defer development.deinit();
    const states: RuntimeStates = .{ .canopy = &canopy, .growth_stages = &growth, .dormancy = &dormancy, .branch_development = &development };
    _ = try appendShootBranch(states, 0, .{ .sample_count_by_node = &.{ 4, 1 }, .maturity_group = 7, .seed_initial_stage = 1, .leafout_initialization_enabled = false, .perennial_node_scaling = 2, .maximum_concurrently_growing_nodes = 8 });
    _ = try canopy.appendNode((try canopy.branchRange(0)).first, 5);
    // appendNode changes only node/sample topology and leaves branch ledgers aligned.
    canopy.plant_mobile_carbon_g[1] = 19;
    growth.branches[(try growth.branchRange(1)).first].initiated_node_count = 9;

    try compactPlantToInitialTopology(states, 0);

    const first = try canopy.branchRange(0);
    const neighbor = try canopy.branchRange(1);
    try std.testing.expectEqual(@as(usize, 1), first.end - first.first);
    try std.testing.expectEqual(@as(usize, 1), (try canopy.nodeRange(first.first)).end - (try canopy.nodeRange(first.first)).first);
    try std.testing.expectEqual(canopy.branch_node_offsets.len - 1, growth.branches.len);
    try std.testing.expectEqual(growth.branches.len, dormancy.branches.len);
    try std.testing.expectEqual(dormancy.branches.len, development.branch_count);
    try std.testing.expectEqual(@as(f64, 19), canopy.plant_mobile_carbon_g[1]);
    try std.testing.expectEqual(@as(f64, 9), growth.branches[neighbor.first].initiated_node_count);
}

test "HFUNC root topology uses deepest rooted layer and runtime trait threshold" {
    const allocator = std.testing.allocator;
    var canopy = try canopy_photosynthesis.State.init(allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var growth = try plant_growth_stages.State.init(allocator, &.{1});
    defer growth.deinit();
    var development = try plant_phenology.BranchDevelopmentState.init(allocator, 1);
    defer development.deinit();
    var roots = try plant_root_system.State.init(allocator, 1, 3, 17);
    defer roots.deinit();
    try development.initializeRange(0, 1, 10, 1, false, 2, 4);
    growth.branches[0].initiated_node_count = 3;
    canopy.plant_seed_storage_carbon_g[0] = 1;
    roots.planting_layer_by_plant[0] = 0;
    roots.total_carbon_g[try roots.layerIndex(0, 0, 2)] = 1;
    roots.turgor_water_potential_megapascal[try roots.layerIndex(0, 0, 0)] = 0;
    roots.turgor_water_potential_megapascal[try roots.layerIndex(0, 0, 2)] = 0.2;
    try std.testing.expectEqual(@as(usize, 1), try advanceRootAxes(.{ .roots = &roots, .canopy = &canopy, .growth_stages = &growth, .branch_development = &development, .active_by_plant = &.{true}, .root_branching_carbon_fraction = &.{0.1}, .minimum_root_turgor_potential_megapascal = 0.1 }));
    try std.testing.expectEqual(@as(usize, 1), roots.active_root_axis_count[0]);
}

test "HFUNC root threshold is visible to same-hour UPTAKE before GROSUB pool mutation" {
    const allocator = std.testing.allocator;
    var canopy = try canopy_photosynthesis.State.init(allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var growth = try plant_growth_stages.State.init(allocator, &.{1});
    defer growth.deinit();
    var development = try plant_phenology.BranchDevelopmentState.init(allocator, 1);
    defer development.deinit();
    var roots = try plant_root_system.State.init(allocator, 1, 1, 3);
    defer roots.deinit();

    try development.initializeRange(0, 1, 10, 0, false, 1, 4);
    growth.branches[0].initiated_node_count = 3;
    roots.active_root_axis_count[0] = 1;
    roots.turgor_water_potential_megapascal[try roots.layerIndex(0, 0, 0)] = 0.2;
    canopy.plant_mobile_carbon_concentration_g_per_g[0] = 0.1000001;

    // HFUNC admits axis two from the hour-entry concentration. Its NRT update
    // is immediately observable by same-hour UPTAKE/GROSUB traversals.
    try std.testing.expectEqual(@as(usize, 1), try advanceRootAxes(.{
        .roots = &roots,
        .canopy = &canopy,
        .growth_stages = &growth,
        .branch_development = &development,
        .active_by_plant = &.{true},
        .root_branching_carbon_fraction = &.{0.1},
        .minimum_root_turgor_potential_megapascal = 0.1,
    }));
    const same_hour_uptake_axis_count = roots.active_root_axis_count[0];
    try std.testing.expectEqual(@as(usize, 2), same_hour_uptake_axis_count);

    // A later GROSUB consumption below PR cannot retroactively change the
    // HFUNC decision made at the source-ordered boundary.
    canopy.plant_mobile_carbon_concentration_g_per_g[0] = 0.0999999;
    try std.testing.expectEqual(@as(usize, 2), roots.active_root_axis_count[0]);
}

test "HFUNC shoot predicate publishes a coordinated dynamic branch" {
    const allocator = std.testing.allocator;
    var canopy = try canopy_photosynthesis.State.init(allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var growth = try plant_growth_stages.State.init(allocator, &.{1});
    defer growth.deinit();
    var dormancy = try plant_dormancy.RuntimeState.init(allocator, 1);
    defer dormancy.deinit();
    var development = try plant_phenology.BranchDevelopmentState.init(allocator, 1);
    defer development.deinit();
    var roots = try plant_root_system.State.init(allocator, 1, 1, 20);
    defer roots.deinit();
    var controls = try Controls.init(allocator, 1);
    defer controls.deinit();
    try controls.setPlant(0, 0.1, 0.1, 1, 0, 0, 8);
    try development.initializeRange(0, 1, 8, 1, false, 2, 4);
    growth.branches[0].initiated_node_count = 5;
    canopy.plant_population_per_m2[0] = 100;
    canopy.plant_mobile_carbon_concentration_g_per_g[0] = 0.2;
    roots.turgor_water_potential_megapascal[try roots.layerIndex(0, 0, 0)] = 0.2;
    const states: RuntimeStates = .{ .canopy = &canopy, .growth_stages = &growth, .dormancy = &dormancy, .branch_development = &development };
    growth.branches[0].emergence_day = 90;
    dormancy.branches[0].accumulated_leafout_h = 8;
    try std.testing.expectEqual(@as(usize, 1), try advanceShootBranches(.{ .states = states, .roots = &roots, .controls = &controls, .active_by_plant = &.{true}, .emerged_by_plant = &.{true}, .day_of_year = 123, .execution_year = 2000, .minimum_root_turgor_potential_megapascal = 0.1 }));
    const appended = (try growth.branchRange(0)).end - 1;
    try std.testing.expectEqual(@as(u16, 123), growth.branches[appended].emergence_day);
    try std.testing.expectApproxEqAbs(@as(f64, 4), dormancy.branches[appended].accumulated_leafout_h, 1.0e-15);
    try std.testing.expect(dormancy.branches[appended].leafout_disabled);
    try std.testing.expectEqual(@as(usize, 2), (try canopy.branchRange(0)).end);
    try std.testing.expectEqual(@as(f64, 8), development.maturity_group[1]);

    const branch_count_before = (try canopy.branchRange(0)).end;
    try std.testing.expectEqual(@as(usize, 0), try advanceShootBranches(.{ .states = states, .roots = &roots, .controls = &controls, .active_by_plant = &.{false}, .emerged_by_plant = &.{true}, .day_of_year = 366, .execution_year = 1900, .minimum_root_turgor_potential_megapascal = 0.1 }));
    try std.testing.expectError(
        error.InvalidPlantTopologyDate,
        advanceShootBranches(.{ .states = states, .roots = &roots, .controls = &controls, .active_by_plant = &.{false}, .emerged_by_plant = &.{true}, .day_of_year = 366, .execution_year = 1901, .minimum_root_turgor_potential_megapascal = 0.1 }),
    );
    try std.testing.expectEqual(branch_count_before, (try canopy.branchRange(0)).end);
}

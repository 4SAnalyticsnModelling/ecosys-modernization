const std = @import("std");
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");

pub const GrowthHabit = enum { annual, perennial };
pub const PhenologyType = enum { evergreen, winter_deciduous, drought_deciduous, winter_and_drought_deciduous, drought_shortening_day, drought_lengthening_day };
/// READQ IPTYP encoding: 0 day-neutral, 1 short-day, 2 long-day.
pub const PhotoperiodType = enum { insensitive, short_day, long_day };

pub fn photoperiodTypeFromReadq(code: u8) !PhotoperiodType {
    return switch (code) {
        0 => .insensitive,
        1 => .short_day,
        2 => .long_day,
        else => error.InvalidPhotoperiodType,
    };
}

pub fn growthHabitFromReadq(code: u8) GrowthHabit {
    return if (code == 0) .annual else .perennial;
}

pub fn phenologyTypeFromReadq(code: u8) !PhenologyType {
    return switch (code) {
        0 => .evergreen,
        1 => .winter_deciduous,
        2 => .drought_deciduous,
        3 => .winter_and_drought_deciduous,
        4 => .drought_shortening_day,
        5 => .drought_lengthening_day,
        else => error.InvalidPhenologyType,
    };
}

pub const BranchState = struct {
    dead: bool = false,
    branch_order: usize = 0,
    emergence_day: u16 = 0,
    floral_initiation_day: u16 = 0,
    stem_elongation_start_day: u16 = 0,
    stem_elongation_midpoint_day: u16 = 0,
    stem_elongation_end_day: u16 = 0,
    anthesis_day: u16 = 0,
    grain_fill_start_day: u16 = 0,
    seed_number_set_end_day: u16 = 0,
    seed_size_set_end_day: u16 = 0,
    initiated_node_count: f64 = 0,
    appeared_leaf_count: f64 = 0,
    nodes_at_floral_initiation: f64 = 0,
    nodes_at_anthesis: f64 = 0,
    maximum_active_leaf_node: f64 = 0,
    vegetative_stage_normalized: f64 = 0,
    reproductive_stage_normalized: f64 = 0,
    vegetative_stage_increment: f64 = 0,
    reproductive_stage_increment: f64 = 0,
    accumulated_vegetative_stage: f64 = 0,
    accumulated_reproductive_stage: f64 = 0,
    newest_growing_leaf_ordinal: usize = 0,
    active_leaf_count: usize = 0,
    lowest_node_nutrient_remobilization_enabled: bool = false,
    new_leaf_remobilization_enabled: bool = false,
};

/// GROSUB spring PSTG/VSTG/TGSTG/IDAY reset. Fully deciduous branches return
/// to the seed node count; other perennial branches retain node number while
/// starting a new seasonal milestone sequence.
pub fn resetBranchForSeasonalLeafout(state: *BranchState, day_of_year: u16, fully_deciduous: bool, seed_initial_node_count: f64) !void {
    if (day_of_year == 0 or day_of_year > 366 or !std.math.isFinite(seed_initial_node_count) or seed_initial_node_count < 0)
        return error.InvalidSeasonalLeafoutReset;
    const nodes_at_seasonal_leafout = state.initiated_node_count;
    state.emergence_day = day_of_year;
    state.floral_initiation_day = 0;
    state.stem_elongation_start_day = 0;
    state.stem_elongation_midpoint_day = 0;
    state.stem_elongation_end_day = 0;
    state.anthesis_day = 0;
    state.grain_fill_start_day = 0;
    state.seed_number_set_end_day = 0;
    state.seed_size_set_end_day = 0;
    state.nodes_at_floral_initiation = nodes_at_seasonal_leafout;
    state.nodes_at_anthesis = 0;
    state.maximum_active_leaf_node = 0;
    state.vegetative_stage_normalized = 0;
    state.reproductive_stage_normalized = 0;
    state.vegetative_stage_increment = 0;
    state.reproductive_stage_increment = 0;
    state.accumulated_vegetative_stage = 0;
    state.accumulated_reproductive_stage = 0;
    state.newest_growing_leaf_ordinal = 0;
    state.active_leaf_count = 0;
    state.lowest_node_nutrient_remobilization_enabled = false;
    state.new_leaf_remobilization_enabled = false;
    if (fully_deciduous) {
        state.initiated_node_count = seed_initial_node_count;
        state.appeared_leaf_count = 0;
    }
}

test "GROSUB seasonal leafout resets milestones and deciduous node state" {
    var branch: BranchState = .{
        .emergence_day = 1,
        .floral_initiation_day = 2,
        .stem_elongation_start_day = 3,
        .stem_elongation_midpoint_day = 4,
        .stem_elongation_end_day = 5,
        .anthesis_day = 6,
        .grain_fill_start_day = 7,
        .seed_number_set_end_day = 8,
        .seed_size_set_end_day = 9,
        .initiated_node_count = 20,
        .appeared_leaf_count = 18,
        .accumulated_vegetative_stage = 2,
        .accumulated_reproductive_stage = 3,
    };
    try resetBranchForSeasonalLeafout(&branch, 150, true, 2);
    try std.testing.expectEqual(@as(u16, 150), branch.emergence_day);
    try std.testing.expectEqual(@as(u16, 0), branch.seed_size_set_end_day);
    try std.testing.expectEqual(@as(f64, 2), branch.initiated_node_count);
    try std.testing.expectEqual(@as(f64, 20), branch.nodes_at_floral_initiation);
    try std.testing.expectEqual(@as(f64, 0), branch.appeared_leaf_count);
    try std.testing.expectEqual(@as(f64, 0), branch.accumulated_reproductive_stage);
}

pub const RuntimeInputs = struct {
    day_of_year: u16,
    current_year: i32,
    planting_day_of_year: u16,
    planting_year: i32,
    current_daylength_h: f64,
    previous_daylength_h: f64,
    canopy_height_m: f64,
    snow_depth_m: f64,
    accumulated_leafout_h: f64,
    required_leafout_h: f64,
    accumulated_leafoff_h: f64,
    required_leafoff_h: f64,
    leafout_disabled: bool,
};

pub const SpeciesParameters = struct {
    growth_habit: GrowthHabit,
    phenology_type: PhenologyType,
    photoperiod_type: PhotoperiodType,
    maturity_group_node_count: f64,
    branch_floral_node_requirement: f64,
    critical_photoperiod_h: f64,
    photoperiod_sensitivity_h: f64,
    determinate: bool,
    vegetative_stage_duration: f64,
    reproductive_stage_duration: f64,
};

pub const BranchRange = struct { first: usize, end: usize };

/// Heap-owned runtime branch stages. Prefix offsets permit every plant to
/// carry a different branch count and remove the historical fixed extents.
pub const State = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    plant_branch_offsets: []usize,
    branches: []BranchState,

    pub fn init(allocator: std.mem.Allocator, branch_count_by_plant: []const usize) !State {
        if (branch_count_by_plant.len == 0) return error.InvalidGrowthStageDimensions;
        const offsets = try allocator.alloc(usize, try std.math.add(usize, branch_count_by_plant.len, 1));
        errdefer allocator.free(offsets);
        offsets[0] = 0;
        for (branch_count_by_plant, 0..) |count, plant| offsets[plant + 1] = try std.math.add(usize, offsets[plant], count);
        const branches = try allocator.alloc(BranchState, offsets[offsets.len - 1]);
        @memset(branches, .{});
        return .{ .allocator = allocator, .plant_count = branch_count_by_plant.len, .plant_branch_offsets = offsets, .branches = branches };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.branches);
        self.allocator.free(self.plant_branch_offsets);
        self.* = undefined;
    }

    pub fn branchRange(self: State, plant: usize) !BranchRange {
        if (plant >= self.plant_count) return error.GrowthStagePlantIndexOutOfBounds;
        return .{ .first = self.plant_branch_offsets[plant], .end = self.plant_branch_offsets[plant + 1] };
    }

    /// HFUNC NB1: living branch with the lowest branch order NBTB.
    pub fn mainLivingBranch(self: State, plant: usize) !?usize {
        const range = try self.branchRange(plant);
        var selected: ?usize = null;
        var selected_order: usize = std.math.maxInt(usize);
        for (range.first..range.end) |branch| {
            const state = self.branches[branch];
            if (state.dead) continue;
            if (state.branch_order < selected_order) {
                selected = branch;
                selected_order = state.branch_order;
            }
        }
        return selected;
    }

    /// HFUNC NB1: the fixed main-stalk/trunk branch index, set once when the
    /// PFT is (re)constructed (`hfunc.f:142,159,161-179`, gated by IFLGC==1)
    /// and never reassigned afterward -- in particular grosub.f never
    /// reassigns NB1, so a branch that later dies remains "the main branch"
    /// for the rest of the run. `branch_order` (NBTB) is likewise assigned
    /// once per branch at creation (`phenology.shootBranchDecision`'s
    /// `next_order - 1`) and never mutated afterward, including across
    /// natural branch death and reconstruction/compaction, which only ever
    /// copies or preserves it. The branch with the globally lowest
    /// `branch_order` therefore always identifies the same physical branch
    /// that was alive and had the lowest order at the most recent
    /// reconstruction (mirroring the IDTHB-gated scan at hfunc.f:161-179,
    /// which only had one live candidate branch at that instant), and stays
    /// pinned to it even after that branch dies. Unlike `mainLivingBranch`,
    /// this deliberately does not skip dead branches: callers that need to
    /// detect the death of the true main stalk (grosub.f:3664-3665's DEATH OF
    /// PFT IF MAIN STALK OF TREE DIES rule) must use this, not
    /// `mainLivingBranch`, or the check is structurally unreachable.
    pub fn mainStalkBranch(self: State, plant: usize) !?usize {
        const range = try self.branchRange(plant);
        if (range.first == range.end) return null;
        var selected = range.first;
        var selected_order = self.branches[range.first].branch_order;
        for (range.first + 1..range.end) |branch| {
            const order = self.branches[branch].branch_order;
            if (order < selected_order) {
                selected = branch;
                selected_order = order;
            }
        }
        return selected;
    }

    pub fn clearPlantForReconstruction(self: *State, plant: usize) !BranchRange {
        const range = try self.branchRange(plant);
        @memset(self.branches[range.first..range.end], .{});
        return range;
    }

    pub fn compactPlantToInitialTopology(self: *State, plant: usize) !void {
        const range = try self.branchRange(plant);
        if (range.end - range.first <= 1) return;
        const counts = try self.allocator.alloc(usize, self.plant_count);
        defer self.allocator.free(counts);
        for (counts, 0..) |*count, index| count.* = if (index == plant) 1 else self.plant_branch_offsets[index + 1] - self.plant_branch_offsets[index];
        var replacement = try State.init(self.allocator, counts);
        errdefer replacement.deinit();
        const remove_first = range.first + 1;
        @memcpy(replacement.branches[0..remove_first], self.branches[0..remove_first]);
        @memcpy(replacement.branches[remove_first..], self.branches[range.end..]);
        var previous = self.*;
        self.* = replacement;
        previous.deinit();
    }

    pub fn clone(self: State) !State {
        const counts = try self.allocator.alloc(usize, self.plant_count);
        defer self.allocator.free(counts);
        for (counts, 0..) |*count, plant| count.* = self.plant_branch_offsets[plant + 1] - self.plant_branch_offsets[plant];
        const result = try State.init(self.allocator, counts);
        @memcpy(result.branches, self.branches);
        return result;
    }

    pub fn appendBranch(self: *State, plant: usize, initial: BranchState) !usize {
        const range = try self.branchRange(plant);
        const inserted = range.end;
        const counts = try self.allocator.alloc(usize, self.plant_count);
        defer self.allocator.free(counts);
        for (counts, 0..) |*count, index| count.* = self.plant_branch_offsets[index + 1] - self.plant_branch_offsets[index] + @intFromBool(index == plant);
        var replacement = try State.init(self.allocator, counts);
        errdefer replacement.deinit();
        @memcpy(replacement.branches[0..inserted], self.branches[0..inserted]);
        replacement.branches[inserted] = initial;
        @memcpy(replacement.branches[inserted + 1 ..], self.branches[inserted..]);
        var previous = self.*;
        self.* = replacement;
        previous.deinit();
        return inserted;
    }

    pub fn validateFinite(self: State) !void {
        for (self.branches, 0..) |branch, index| inline for (@typeInfo(BranchState).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(branch, field.name))) {
            std.log.err("non-finite growth-stage state: branch={d} field={s} value={e}", .{ index, field.name, @field(branch, field.name) });
            return error.NonFiniteGrowthStageState;
        };
    }
};

test "HFUNC NB1 selects the lowest-order living runtime branch" {
    var state = try State.init(std.testing.allocator, &.{4});
    defer state.deinit();
    state.branches[0] = .{ .dead = true, .branch_order = 0 };
    state.branches[1] = .{ .branch_order = 5 };
    state.branches[2] = .{ .branch_order = 2 };
    state.branches[3] = .{ .dead = true, .branch_order = 1 };
    try std.testing.expectEqual(@as(?usize, 2), try state.mainLivingBranch(0));
    state.branches[2].dead = true;
    try std.testing.expectEqual(@as(?usize, 1), try state.mainLivingBranch(0));
    state.branches[1].dead = true;
    try std.testing.expectEqual(@as(?usize, null), try state.mainLivingBranch(0));
}

/// Ports HFUNC's floral-initiation through grain-fill stage chain. Calling
/// code owns a runtime-sized slice of BranchState; no branch ceiling exists.
pub fn advanceBranch(state: *BranchState, node_increment: f64, inputs: RuntimeInputs, parameters: SpeciesParameters, is_primary_branch: bool, primary_branch_anthesis_started: bool) !void {
    try validate(state.*, node_increment, inputs, parameters);
    const vegetative_duration = parameters.vegetative_stage_duration;
    const reproductive_duration = parameters.reproductive_stage_duration;
    if (state.floral_initiation_day != 0) {
        state.vegetative_stage_normalized = (state.initiated_node_count - state.nodes_at_floral_initiation) / parameters.maturity_group_node_count;
        state.vegetative_stage_increment = node_increment / (parameters.maturity_group_node_count * vegetative_duration);
        state.accumulated_vegetative_stage += state.vegetative_stage_increment;
    }
    if (state.anthesis_day != 0) {
        state.reproductive_stage_normalized = (state.initiated_node_count - state.nodes_at_anthesis) / parameters.maturity_group_node_count;
        state.reproductive_stage_increment = node_increment / (parameters.maturity_group_node_count * reproductive_duration);
        state.accumulated_reproductive_stage += state.reproductive_stage_increment;
        state.lowest_node_nutrient_remobilization_enabled = true;
    } else state.lowest_node_nutrient_remobilization_enabled = false;

    const dormant_exit = inputs.accumulated_leafoff_h > inputs.required_leafoff_h;
    const forced_deciduous_progression = ((parameters.phenology_type == .winter_deciduous or parameters.phenology_type == .winter_and_drought_deciduous) and parameters.growth_habit == .perennial and parameters.photoperiod_type != .short_day and inputs.current_daylength_h < inputs.previous_daylength_h and inputs.leafout_disabled and dormant_exit) or
        (parameters.phenology_type == .drought_deciduous and parameters.growth_habit == .annual and inputs.leafout_disabled and dormant_exit);

    // Preserve the original ELSEIF chain: at most one calendar milestone per call.
    if (state.floral_initiation_day == 0) {
        const seasonal_trigger = inputs.accumulated_leafout_h >= inputs.required_leafout_h or
            (inputs.current_year == inputs.planting_year and inputs.day_of_year >= inputs.planting_day_of_year and inputs.current_daylength_h > inputs.previous_daylength_h) or
            (((parameters.growth_habit == .perennial and (parameters.phenology_type == .winter_deciduous or parameters.phenology_type == .winter_and_drought_deciduous)) or (parameters.growth_habit == .annual and parameters.phenology_type == .evergreen)) and inputs.canopy_height_m >= inputs.snow_depth_m and inputs.current_daylength_h < inputs.previous_daylength_h);
        if (state.initiated_node_count > parameters.branch_floral_node_requirement + state.nodes_at_floral_initiation and seasonal_trigger) {
            var photoperiod_difference_h: f64 = if (parameters.photoperiod_type == .insensitive) 0 else @max(0, parameters.critical_photoperiod_h - inputs.current_daylength_h);
            if (parameters.photoperiod_type == .short_day and inputs.current_daylength_h >= inputs.previous_daylength_h) photoperiod_difference_h = 0;
            const photoperiod_trigger = parameters.photoperiod_type == .insensitive or
                (parameters.photoperiod_type == .short_day and photoperiod_difference_h > parameters.photoperiod_sensitivity_h) or
                (parameters.photoperiod_type == .long_day and photoperiod_difference_h < parameters.photoperiod_sensitivity_h and (parameters.growth_habit == .perennial or parameters.phenology_type != .winter_deciduous or dormant_exit)) or
                (((parameters.growth_habit == .perennial and (parameters.phenology_type == .winter_deciduous or parameters.phenology_type == .winter_and_drought_deciduous)) or (parameters.growth_habit == .annual and parameters.phenology_type == .evergreen)) and inputs.canopy_height_m >= inputs.snow_depth_m and inputs.current_daylength_h < inputs.previous_daylength_h);
            if (photoperiod_trigger) {
                state.floral_initiation_day = inputs.day_of_year;
                state.nodes_at_floral_initiation = state.initiated_node_count;
                if (parameters.growth_habit == .annual and !parameters.determinate) state.maximum_active_leaf_node = state.initiated_node_count;
            }
        }
    } else if (state.stem_elongation_start_day == 0) {
        if (state.vegetative_stage_normalized > 0.25 * vegetative_duration or forced_deciduous_progression) state.stem_elongation_start_day = inputs.day_of_year;
    } else if (state.stem_elongation_midpoint_day == 0) {
        if (state.vegetative_stage_normalized > 0.50 * vegetative_duration or forced_deciduous_progression) {
            state.stem_elongation_midpoint_day = inputs.day_of_year;
            if (parameters.growth_habit == .annual and parameters.determinate) state.maximum_active_leaf_node = state.initiated_node_count;
        }
    } else if (state.stem_elongation_end_day == 0) {
        if (state.vegetative_stage_normalized > vegetative_duration or forced_deciduous_progression) state.stem_elongation_end_day = inputs.day_of_year;
    } else if (state.anthesis_day == 0) {
        if ((state.appeared_leaf_count > state.nodes_at_floral_initiation or (parameters.growth_habit == .perennial and state.stem_elongation_end_day != 0) or forced_deciduous_progression) and (is_primary_branch or primary_branch_anthesis_started)) {
            state.anthesis_day = inputs.day_of_year;
            state.nodes_at_anthesis = state.initiated_node_count;
        }
    } else if (state.grain_fill_start_day == 0) {
        if (state.reproductive_stage_normalized > 0.50 * reproductive_duration or forced_deciduous_progression) state.grain_fill_start_day = inputs.day_of_year;
    } else if (state.seed_number_set_end_day == 0) {
        if (state.reproductive_stage_normalized > reproductive_duration) state.seed_number_set_end_day = inputs.day_of_year;
    } else if (state.seed_size_set_end_day == 0) {
        if (state.reproductive_stage_normalized > 1.50 * reproductive_duration) state.seed_size_set_end_day = inputs.day_of_year;
    }
    refreshActiveLeafIndex(state);
}

/// HFUNC KVSTG/KLEAF/IFLGP without the historical 24-slot storage ceiling.
/// The topology allocator, rather than this scientific calculation, owns
/// physical node capacity in ecosys-ng.
pub fn refreshActiveLeafIndex(state: *BranchState) void {
    const previous = state.newest_growing_leaf_ordinal;
    const effective_leaf_stage = if (state.maximum_active_leaf_node <= 1.0e-6)
        state.appeared_leaf_count
    else
        @min(state.appeared_leaf_count, state.maximum_active_leaf_node);
    state.newest_growing_leaf_ordinal = @as(usize, @intFromFloat(@floor(@max(0.0, effective_leaf_stage)))) + 1;
    state.active_leaf_count = state.newest_growing_leaf_ordinal;
    state.new_leaf_remobilization_enabled = state.newest_growing_leaf_ordinal > previous;
}

fn validate(state: BranchState, node_increment: f64, inputs: RuntimeInputs, parameters: SpeciesParameters) !void {
    inline for (@typeInfo(BranchState).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(state, field.name))) return error.NonFiniteGrowthStageState;
    inline for (@typeInfo(RuntimeInputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteGrowthStageInput;
    inline for (@typeInfo(SpeciesParameters).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteGrowthStageParameter;
    if (!std.math.isFinite(node_increment) or node_increment < 0 or parameters.maturity_group_node_count <= 0 or parameters.branch_floral_node_requirement < 0 or parameters.vegetative_stage_duration <= 0 or parameters.reproductive_stage_duration <= 0) return error.InvalidGrowthStageInput;
    try validateRuntimeDate(inputs.day_of_year, inputs.current_year);
    try validateRuntimeDate(inputs.planting_day_of_year, inputs.planting_year);
}

fn validateRuntimeDate(day_of_year: u16, runtime_year: i32) !void {
    const year = std.math.cast(u16, runtime_year) orelse
        return error.InvalidGrowthStageInput;
    const maximum_day: u16 =
        if (execution_calendar_date.isLeapYear(year)) 366 else 365;
    if (year == 0 or day_of_year == 0 or day_of_year > maximum_day)
        return error.InvalidGrowthStageInput;
}

test "growth milestones preserve one-stage-per-call Fortran ordering" {
    var state: BranchState = .{ .initiated_node_count = 12, .appeared_leaf_count = 12 };
    const inputs: RuntimeInputs = .{ .day_of_year = 150, .current_year = 2020, .planting_day_of_year = 100, .planting_year = 2020, .current_daylength_h = 14, .previous_daylength_h = 13.9, .canopy_height_m = 1, .snow_depth_m = 0, .accumulated_leafout_h = 100, .required_leafout_h = 50, .accumulated_leafoff_h = 0, .required_leafoff_h = 100, .leafout_disabled = false };
    const parameters: SpeciesParameters = .{ .growth_habit = .annual, .phenology_type = .evergreen, .photoperiod_type = .insensitive, .maturity_group_node_count = 5, .branch_floral_node_requirement = 10, .critical_photoperiod_h = 12, .photoperiod_sensitivity_h = 1, .determinate = false, .vegetative_stage_duration = 2, .reproductive_stage_duration = 0.667 };
    try advanceBranch(&state, 0.1, inputs, parameters, true, false);
    try std.testing.expectEqual(@as(u16, 150), state.floral_initiation_day);
    try std.testing.expectEqual(@as(u16, 0), state.stem_elongation_start_day);
    state.initiated_node_count = 15;
    try advanceBranch(&state, 0.1, inputs, parameters, true, false);
    try std.testing.expectEqual(@as(u16, 150), state.stem_elongation_start_day);
    try std.testing.expectEqual(@as(u16, 0), state.stem_elongation_midpoint_day);
}

test "growth stage dates preserve DAY modulo-four chronology" {
    try validateRuntimeDate(366, 1900);
    try std.testing.expectError(
        error.InvalidGrowthStageInput,
        validateRuntimeDate(366, 1901),
    );
    try std.testing.expectError(
        error.InvalidGrowthStageInput,
        validateRuntimeDate(1, 0),
    );
    try std.testing.expectError(
        error.InvalidGrowthStageInput,
        validateRuntimeDate(1, -1),
    );
}

test "growth-stage state supports arbitrary runtime plants and branch counts" {
    const counts = [_]usize{ 1, 0, 2, 4, 1, 3, 2, 5, 1 };
    var state = try State.init(std.testing.allocator, &counts);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 9), state.plant_count);
    try std.testing.expectEqual(@as(usize, 19), state.branches.len);
    try std.testing.expectEqual(BranchRange{ .first = 8, .end = 11 }, try state.branchRange(5));
    try state.validateFinite();
}

test "secondary branch anthesis waits for the primary branch" {
    var state: BranchState = .{ .floral_initiation_day = 100, .stem_elongation_start_day = 110, .stem_elongation_midpoint_day = 120, .stem_elongation_end_day = 130, .initiated_node_count = 10, .appeared_leaf_count = 11, .nodes_at_floral_initiation = 8 };
    const inputs: RuntimeInputs = .{ .day_of_year = 140, .current_year = 2020, .planting_day_of_year = 90, .planting_year = 2020, .current_daylength_h = 14, .previous_daylength_h = 13.9, .canopy_height_m = 1, .snow_depth_m = 0, .accumulated_leafout_h = 100, .required_leafout_h = 50, .accumulated_leafoff_h = 0, .required_leafoff_h = 100, .leafout_disabled = false };
    const parameters: SpeciesParameters = .{ .growth_habit = .annual, .phenology_type = .evergreen, .photoperiod_type = .insensitive, .maturity_group_node_count = 5, .branch_floral_node_requirement = 8, .critical_photoperiod_h = 12, .photoperiod_sensitivity_h = 1, .determinate = false, .vegetative_stage_duration = 2, .reproductive_stage_duration = 0.667 };
    try advanceBranch(&state, 0.1, inputs, parameters, false, false);
    try std.testing.expectEqual(@as(u16, 0), state.anthesis_day);
    try advanceBranch(&state, 0.1, inputs, parameters, false, true);
    try std.testing.expectEqual(@as(u16, 140), state.anthesis_day);
}

test "READQ photoperiod codes preserve short-day and long-day source branches" {
    try std.testing.expectEqual(PhotoperiodType.short_day, try photoperiodTypeFromReadq(1));
    try std.testing.expectEqual(PhotoperiodType.long_day, try photoperiodTypeFromReadq(2));
    try std.testing.expectError(error.InvalidPhotoperiodType, photoperiodTypeFromReadq(3));

    const common: SpeciesParameters = .{ .growth_habit = .annual, .phenology_type = .drought_deciduous, .photoperiod_type = .short_day, .maturity_group_node_count = 5, .branch_floral_node_requirement = 1, .critical_photoperiod_h = 14, .photoperiod_sensitivity_h = 1, .determinate = false, .vegetative_stage_duration = 2, .reproductive_stage_duration = 0.667 };
    const inputs: RuntimeInputs = .{ .day_of_year = 200, .current_year = 2020, .planting_day_of_year = 100, .planting_year = 2020, .current_daylength_h = 12, .previous_daylength_h = 12.1, .canopy_height_m = 1, .snow_depth_m = 0, .accumulated_leafout_h = 10, .required_leafout_h = 1, .accumulated_leafoff_h = 0, .required_leafoff_h = 1, .leafout_disabled = false };
    var short_day: BranchState = .{ .initiated_node_count = 2 };
    try advanceBranch(&short_day, 0, inputs, common, true, false);
    try std.testing.expectEqual(@as(u16, 200), short_day.floral_initiation_day);
    var long_day: BranchState = .{ .initiated_node_count = 2 };
    var long_parameters = common;
    long_parameters.photoperiod_type = .long_day;
    try advanceBranch(&long_day, 0, inputs, long_parameters, true, false);
    try std.testing.expectEqual(@as(u16, 0), long_day.floral_initiation_day);
}

test "HFUNC completes IDAY 7 8 and 9 in separate hourly calls" {
    const parameters: SpeciesParameters = .{ .growth_habit = .annual, .phenology_type = .evergreen, .photoperiod_type = .insensitive, .maturity_group_node_count = 2, .branch_floral_node_requirement = 1, .critical_photoperiod_h = 12, .photoperiod_sensitivity_h = 1, .determinate = false, .vegetative_stage_duration = 2, .reproductive_stage_duration = 0.667 };
    const inputs: RuntimeInputs = .{ .day_of_year = 210, .current_year = 2020, .planting_day_of_year = 100, .planting_year = 2020, .current_daylength_h = 12, .previous_daylength_h = 12, .canopy_height_m = 1, .snow_depth_m = 0, .accumulated_leafout_h = 1, .required_leafout_h = 1, .accumulated_leafoff_h = 0, .required_leafoff_h = 1, .leafout_disabled = false };
    var state: BranchState = .{ .floral_initiation_day = 100, .stem_elongation_start_day = 110, .stem_elongation_midpoint_day = 120, .stem_elongation_end_day = 130, .anthesis_day = 140, .nodes_at_anthesis = 1, .initiated_node_count = 2 };
    try advanceBranch(&state, 0, inputs, parameters, true, true);
    try std.testing.expectEqual(@as(u16, 210), state.grain_fill_start_day);
    state.initiated_node_count = 3;
    try advanceBranch(&state, 0, inputs, parameters, true, true);
    try std.testing.expectEqual(@as(u16, 210), state.seed_number_set_end_day);
    state.initiated_node_count = 4;
    try advanceBranch(&state, 0, inputs, parameters, true, true);
    try std.testing.expectEqual(@as(u16, 210), state.seed_size_set_end_day);
}

test "HFUNC active leaf ordinal has no fixed 24-node ceiling" {
    var state: BranchState = .{ .appeared_leaf_count = 40.75 };
    refreshActiveLeafIndex(&state);
    try std.testing.expectEqual(@as(usize, 41), state.newest_growing_leaf_ordinal);
    try std.testing.expectEqual(@as(usize, 41), state.active_leaf_count);
    try std.testing.expect(state.new_leaf_remobilization_enabled);
    refreshActiveLeafIndex(&state);
    try std.testing.expect(!state.new_leaf_remobilization_enabled);
    state.maximum_active_leaf_node = 12.5;
    refreshActiveLeafIndex(&state);
    try std.testing.expectEqual(@as(usize, 13), state.newest_growing_leaf_ordinal);
}

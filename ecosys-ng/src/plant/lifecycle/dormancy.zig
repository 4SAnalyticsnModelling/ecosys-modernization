const std = @import("std");
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");
const stages = @import("growth_stages.zig");

pub const State = struct {
    accumulated_leafout_h: f64 = 0,
    accumulated_leafoff_h: f64 = 0,
    lengthening_photoperiod_h: f64 = 0,
    shortening_photoperiod_h: f64 = 0,
    leafout_disabled: bool = false,
    leafoff_disabled: bool = false,
    shoot_remobilization_enabled: bool = false,
    phenological_remobilization_enabled: bool = false,
    remobilization_elapsed_h: f64 = 0,
    /// Legacy IFLGR: reproductive growth is disabled while end-of-season
    /// reproductive and stalk material turns over.
    reproductive_growth_disabled: bool = false,
    /// Legacy FLGQ, accumulated end-of-season litterfall delay (h).
    reproductive_litterfall_delay_h: f64 = 0,
};

pub const RuntimeState = struct {
    allocator: std.mem.Allocator,
    branches: []State,

    pub fn init(allocator: std.mem.Allocator, branch_count: usize) !RuntimeState {
        if (branch_count == 0) return error.InvalidDormancyDimensions;
        const branches = try allocator.alloc(State, branch_count);
        @memset(branches, .{});
        return .{ .allocator = allocator, .branches = branches };
    }

    pub fn deinit(self: *RuntimeState) void {
        self.allocator.free(self.branches);
        self.* = undefined;
    }

    pub fn clone(self: RuntimeState) !RuntimeState {
        const result = try RuntimeState.init(self.allocator, self.branches.len);
        @memcpy(result.branches, self.branches);
        return result;
    }

    pub fn insertBranch(self: *RuntimeState, index: usize, initial: State) !void {
        if (index > self.branches.len) return error.DormancyBranchIndexOutOfBounds;
        var replacement = try RuntimeState.init(self.allocator, try std.math.add(usize, self.branches.len, 1));
        errdefer replacement.deinit();
        @memcpy(replacement.branches[0..index], self.branches[0..index]);
        replacement.branches[index] = initial;
        @memcpy(replacement.branches[index + 1 ..], self.branches[index..]);
        var previous = self.*;
        self.* = replacement;
        previous.deinit();
    }

    pub fn clearRangeForReconstruction(self: *RuntimeState, first: usize, end: usize) !void {
        if (first > end or end > self.branches.len) return error.DormancyBranchIndexOutOfBounds;
        @memset(self.branches[first..end], .{});
    }

    pub fn removeRange(self: *RuntimeState, first: usize, end: usize) !void {
        if (first > end or end > self.branches.len) return error.DormancyBranchIndexOutOfBounds;
        if (first == end) return;
        var replacement = try RuntimeState.init(self.allocator, self.branches.len - (end - first));
        errdefer replacement.deinit();
        @memcpy(replacement.branches[0..first], self.branches[0..first]);
        @memcpy(replacement.branches[first..], self.branches[end..]);
        var previous = self.*;
        self.* = replacement;
        previous.deinit();
    }

    pub fn validateFinite(self: RuntimeState) !void {
        for (self.branches) |branch| try validateState(branch);
    }
};

pub const Parameters = struct {
    required_leafout_h: f64,
    required_leafoff_h: f64,
    leafout_temperature_threshold_c: f64,
    leafoff_temperature_threshold_c: f64,
    chilling_temperature_c: f64,
    drought_leafout_total_water_potential_megapascal: f64,
    combined_leafout_turgor_potential_megapascal: f64,
    leafoff_total_water_potential_megapascal: f64,
    /// GROSUB's own local PSILY(IGTYP) (grosub.f:50,214: DATA
    /// -200.0,-2.0,-2.0,-2.0), the canopy total water potential threshold
    /// gating the FLGZ/IFLGZ/IFLGY drought leaf-abscission accumulator
    /// (grosub.f:786-789). This is declared and initialized independently
    /// of, and numerically differs from, HFUNC's own local PSILY that
    /// drives `advance()`'s leafout/leafoff phenology state machine
    /// (`leafoff_total_water_potential_megapascal` above); the two must
    /// not share a single field.
    drought_leafoff_total_water_potential_megapascal: f64,
    maximum_photoperiod_counter_h: f64,
    evergreen_leafoff_remobilization_start_fraction: f64,
    deciduous_leafoff_remobilization_start_fraction: f64,
    full_senescence_duration_h: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.NonFiniteDormancyParameter;
        if (self.required_leafout_h < 0 or self.required_leafoff_h < 0 or self.maximum_photoperiod_counter_h < 0 or self.full_senescence_duration_h <= 0 or self.evergreen_leafoff_remobilization_start_fraction < 0 or self.evergreen_leafoff_remobilization_start_fraction > 1 or self.deciduous_leafoff_remobilization_start_fraction < 0 or self.deciduous_leafoff_remobilization_start_fraction > 1) return error.InvalidDormancyParameter;
    }
};

pub const RemobilizationInputs = struct {
    timestep_h: f64,
    canopy_temperature_c: f64,
    canopy_total_water_potential_megapascal: f64,
};

/// GROSUB IFLGZ/IFLGY/FLGZ transition. Elapsed time advances only while the
/// phenology-specific temperature or water gate is open and resets only when
/// the outer maturity/leafoff trigger closes, matching the source state
/// machine.
pub fn advanceRemobilization(
    state: *State,
    inputs: RemobilizationInputs,
    parameters: Parameters,
    growth_habit: stages.GrowthHabit,
    phenology_type: stages.PhenologyType,
    seed_number_set_complete: bool,
) !void {
    try parameters.validate();
    inline for (.{ inputs.timestep_h, inputs.canopy_temperature_c, inputs.canopy_total_water_potential_megapascal }) |value| if (!std.math.isFinite(value)) return error.InvalidRemobilizationState;
    if (!std.math.isFinite(state.accumulated_leafoff_h) or !std.math.isFinite(state.remobilization_elapsed_h) or state.accumulated_leafoff_h < 0 or state.remobilization_elapsed_h < 0 or inputs.timestep_h <= 0) return error.InvalidRemobilizationState;
    const start_fraction = if (phenology_type == .evergreen)
        parameters.evergreen_leafoff_remobilization_start_fraction
    else
        parameters.deciduous_leafoff_remobilization_start_fraction;
    const shoot_enabled = (growth_habit == .perennial and state.accumulated_leafoff_h >= start_fraction * parameters.required_leafoff_h) or
        (growth_habit == .annual and seed_number_set_complete);
    var phenological_enabled = false;
    if (shoot_enabled) {
        phenological_enabled = growth_habit == .annual or phenology_type == .evergreen or
            ((phenology_type == .winter_deciduous or phenology_type == .winter_and_drought_deciduous) and inputs.canopy_temperature_c < parameters.leafoff_temperature_threshold_c) or
            (phenology_type != .evergreen and phenology_type != .winter_deciduous and inputs.canopy_total_water_potential_megapascal < parameters.drought_leafoff_total_water_potential_megapascal);
        if (phenological_enabled) state.remobilization_elapsed_h += inputs.timestep_h;
    } else {
        state.remobilization_elapsed_h = 0;
    }
    if (!std.math.isFinite(state.remobilization_elapsed_h)) return error.NonFiniteRemobilizationState;
    state.shoot_remobilization_enabled = shoot_enabled;
    state.phenological_remobilization_enabled = phenological_enabled;
}

pub const Inputs = struct {
    day_of_year: u16,
    execution_year: u16,
    latitude_deg_n: f64,
    timestep_h: f64,
    current_daylength_h: f64,
    previous_daylength_h: f64,
    maximum_seasonal_daylength_h: f64,
    canopy_temperature_c: f64,
    canopy_turgor_potential_megapascal: f64,
    canopy_total_water_potential_megapascal: f64,
    surface_soil_water_potential_megapascal: f64,
    seed_layer_soil_water_potential_megapascal: f64,
    emerged: bool,
    floral_initiated: bool,
};

/// Ports the HFUNC leafout/leafoff block. A runtime-sized State slice may be
/// allocated per cell, species, and branch; no Fortran branch ceiling remains.
pub fn advance(state: *State, inputs: Inputs, parameters: Parameters, growth_habit: stages.GrowthHabit, phenology_type: stages.PhenologyType) !void {
    try parameters.validate();
    try validateStateAndInputs(state.*, inputs);
    const daylength_increasing = inputs.current_daylength_h >= inputs.previous_daylength_h;
    if (daylength_increasing) {
        state.lengthening_photoperiod_h += inputs.timestep_h;
        state.shortening_photoperiod_h = 0;
    } else {
        state.lengthening_photoperiod_h = 0;
        state.shortening_photoperiod_h += inputs.timestep_h;
    }

    switch (phenology_type) {
        .evergreen => advanceEvergreen(state, inputs, parameters, daylength_increasing),
        .winter_deciduous => advanceWinterDeciduous(state, inputs, parameters, growth_habit, daylength_increasing),
        .drought_deciduous, .drought_shortening_day, .drought_lengthening_day => advanceDroughtDeciduous(state, inputs, parameters, phenology_type),
        .winter_and_drought_deciduous => advanceCombinedDeciduous(state, inputs, parameters, daylength_increasing),
    }
    try validateStateAndInputs(state.*, inputs);
}

fn advanceEvergreen(state: *State, inputs: Inputs, parameters: Parameters, daylength_increasing: bool) void {
    if (daylength_increasing) {
        state.accumulated_leafout_h = state.lengthening_photoperiod_h;
        if (state.accumulated_leafout_h >= parameters.required_leafout_h or solsticeDay(inputs.latitude_deg_n, inputs.day_of_year, 173, 355)) {
            state.accumulated_leafoff_h = 0;
            state.leafoff_disabled = false;
        }
    } else {
        state.accumulated_leafoff_h = state.shortening_photoperiod_h;
        if (state.accumulated_leafoff_h >= parameters.required_leafoff_h or solsticeDay(inputs.latitude_deg_n, inputs.day_of_year, 355, 173)) {
            state.accumulated_leafout_h = 0;
            state.leafout_disabled = false;
        }
    }
}

fn advanceWinterDeciduous(state: *State, inputs: Inputs, parameters: Parameters, growth_habit: stages.GrowthHabit, daylength_increasing: bool) void {
    if ((daylength_increasing or (!daylength_increasing and state.accumulated_leafoff_h < parameters.required_leafoff_h)) and !state.leafout_disabled) {
        if (inputs.canopy_temperature_c >= parameters.leafout_temperature_threshold_c) state.accumulated_leafout_h += inputs.timestep_h;
        if (state.accumulated_leafout_h < parameters.required_leafout_h and inputs.canopy_temperature_c < parameters.chilling_temperature_c) state.accumulated_leafout_h = @max(0, state.accumulated_leafout_h - inputs.timestep_h);
        if ((state.accumulated_leafout_h >= parameters.required_leafout_h and growth_habit == .perennial) or solsticeDay(inputs.latitude_deg_n, inputs.day_of_year, 173, 355)) state.accumulated_leafoff_h = 0;
    }
    if (inputs.floral_initiated or (!daylength_increasing and inputs.current_daylength_h < 12)) state.leafoff_disabled = false;
    if (((!daylength_increasing and state.leafoff_disabled == false and inputs.floral_initiated) or (inputs.current_daylength_h > inputs.previous_daylength_h and growth_habit == .annual)) and inputs.canopy_temperature_c <= parameters.leafoff_temperature_threshold_c) state.accumulated_leafoff_h += inputs.timestep_h;
    if (state.accumulated_leafoff_h >= parameters.required_leafoff_h and state.leafout_disabled) {
        state.accumulated_leafout_h = 0;
        state.leafout_disabled = false;
    }
}

fn advanceDroughtDeciduous(state: *State, inputs: Inputs, parameters: Parameters, phenology_type: stages.PhenologyType) void {
    if (!state.leafout_disabled) {
        if (inputs.canopy_total_water_potential_megapascal >= parameters.drought_leafout_total_water_potential_megapascal) state.accumulated_leafout_h += inputs.timestep_h;
        if (state.accumulated_leafout_h < parameters.required_leafout_h and inputs.canopy_total_water_potential_megapascal < parameters.leafoff_total_water_potential_megapascal) state.accumulated_leafout_h = @max(0, state.accumulated_leafout_h - inputs.timestep_h);
        if (state.accumulated_leafout_h >= parameters.required_leafout_h) {
            state.accumulated_leafoff_h = 0;
            if (inputs.floral_initiated) state.leafoff_disabled = false;
        }
    }
    if (inputs.floral_initiated) state.leafoff_disabled = false;
    if (state.leafout_disabled and !state.leafoff_disabled) {
        const water_potential = if (inputs.emerged) inputs.canopy_total_water_potential_megapascal else @min(inputs.seed_layer_soil_water_potential_megapascal, inputs.surface_soil_water_potential_megapascal);
        if (water_potential < parameters.leafoff_total_water_potential_megapascal) state.accumulated_leafoff_h += inputs.timestep_h;
        if (phenology_type == .drought_shortening_day and state.shortening_photoperiod_h > parameters.maximum_photoperiod_counter_h) state.accumulated_leafoff_h = state.shortening_photoperiod_h else if (phenology_type == .drought_lengthening_day and state.lengthening_photoperiod_h > parameters.maximum_photoperiod_counter_h) state.accumulated_leafoff_h = state.lengthening_photoperiod_h;
        if (state.accumulated_leafoff_h >= parameters.required_leafoff_h and state.leafout_disabled) {
            state.accumulated_leafout_h = 0;
            state.leafout_disabled = false;
        }
    }
}

fn advanceCombinedDeciduous(state: *State, inputs: Inputs, parameters: Parameters, daylength_increasing: bool) void {
    if ((daylength_increasing or inputs.current_daylength_h >= inputs.maximum_seasonal_daylength_h - 2) and !state.leafout_disabled) {
        if (inputs.canopy_temperature_c >= parameters.leafout_temperature_threshold_c and inputs.canopy_turgor_potential_megapascal > parameters.combined_leafout_turgor_potential_megapascal) state.accumulated_leafout_h += inputs.timestep_h;
        if (state.accumulated_leafout_h < parameters.required_leafout_h and (inputs.canopy_temperature_c < parameters.chilling_temperature_c or inputs.canopy_turgor_potential_megapascal < parameters.combined_leafout_turgor_potential_megapascal)) state.accumulated_leafout_h = @max(0, state.accumulated_leafout_h - inputs.timestep_h);
        if (state.accumulated_leafout_h >= parameters.required_leafout_h) {
            state.accumulated_leafoff_h = 0;
            if (inputs.floral_initiated) state.leafoff_disabled = false;
        }
    }
    if (inputs.floral_initiated) state.leafoff_disabled = false;
    if ((!daylength_increasing or inputs.current_daylength_h < 24 - inputs.maximum_seasonal_daylength_h + 2) and !state.leafoff_disabled) {
        if (inputs.canopy_temperature_c <= parameters.leafoff_temperature_threshold_c or inputs.canopy_total_water_potential_megapascal < parameters.leafoff_total_water_potential_megapascal) state.accumulated_leafoff_h += inputs.timestep_h;
        if (state.accumulated_leafoff_h >= parameters.required_leafoff_h and state.leafout_disabled) {
            state.accumulated_leafout_h = 0;
            state.leafout_disabled = false;
        }
    }
}

fn solsticeDay(latitude_deg_n: f64, day: u16, north_day: u16, south_day: u16) bool {
    return (latitude_deg_n > 0 and day == north_day) or (latitude_deg_n < 0 and day == south_day);
}

fn validateStateAndInputs(state: State, inputs: Inputs) !void {
    try validateState(state);
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteDormancyInput;
    _ = execution_calendar_date.fromDayOfYear(
        inputs.day_of_year,
        inputs.execution_year,
    ) catch return error.InvalidDormancyInput;
    if (inputs.timestep_h <= 0 or inputs.current_daylength_h < 0 or inputs.current_daylength_h > 24 or inputs.previous_daylength_h < 0 or inputs.previous_daylength_h > 24 or inputs.maximum_seasonal_daylength_h < 0 or inputs.maximum_seasonal_daylength_h > 24) return error.InvalidDormancyInput;
}

fn validateState(state: State) !void {
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(state, field.name)) or @field(state, field.name) < 0)) return error.InvalidDormancyState;
}

fn testParameters() Parameters {
    return .{ .required_leafout_h = 2, .required_leafoff_h = 2, .leafout_temperature_threshold_c = 5, .leafoff_temperature_threshold_c = 0, .chilling_temperature_c = -5, .drought_leafout_total_water_potential_megapascal = -0.1, .combined_leafout_turgor_potential_megapascal = 0.1, .leafoff_total_water_potential_megapascal = -1.5, .drought_leafoff_total_water_potential_megapascal = -2.0, .maximum_photoperiod_counter_h = 3600, .evergreen_leafoff_remobilization_start_fraction = 0.75, .deciduous_leafoff_remobilization_start_fraction = 0.5, .full_senescence_duration_h = 480 };
}

fn testInputs() Inputs {
    return .{ .day_of_year = 100, .execution_year = 2000, .latitude_deg_n = 53, .timestep_h = 1, .current_daylength_h = 13, .previous_daylength_h = 12.9, .maximum_seasonal_daylength_h = 17, .canopy_temperature_c = 10, .canopy_turgor_potential_megapascal = 0.2, .canopy_total_water_potential_megapascal = -0.05, .surface_soil_water_potential_megapascal = -0.1, .seed_layer_soil_water_potential_megapascal = -0.1, .emerged = true, .floral_initiated = false };
}

test "winter deciduous leafout accumulates warm hours and reverses under chilling" {
    var state: State = .{};
    var inputs = testInputs();
    try advance(&state, inputs, testParameters(), .perennial, .winter_deciduous);
    try std.testing.expectEqual(@as(f64, 1), state.accumulated_leafout_h);
    inputs.canopy_temperature_c = -10;
    try advance(&state, inputs, testParameters(), .perennial, .winter_deciduous);
    try std.testing.expectEqual(@as(f64, 0), state.accumulated_leafout_h);
}

test "dormancy state is heap sized for arbitrary runtime branches" {
    var state = try RuntimeState.init(std.testing.allocator, 37);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 37), state.branches.len);
    try state.validateFinite();
}

test "runtime dormancy owns branch-local reproductive turnover state" {
    var state = try RuntimeState.init(std.testing.allocator, 2);
    defer state.deinit();
    state.branches[1].reproductive_growth_disabled = true;
    state.branches[1].reproductive_litterfall_delay_h = 239;
    try state.validateFinite();
    try std.testing.expect(state.branches[1].reproductive_growth_disabled);
    try std.testing.expectEqual(@as(f64, 239), state.branches[1].reproductive_litterfall_delay_h);

    state.branches[1].reproductive_litterfall_delay_h = std.math.nan(f64);
    try std.testing.expectError(error.InvalidDormancyState, state.validateFinite());
}

test "branch reconstruction clears IFLGR and FLGQ for dead-branch reset" {
    var state = try RuntimeState.init(std.testing.allocator, 2);
    defer state.deinit();
    state.branches[1].reproductive_growth_disabled = true;
    state.branches[1].reproductive_litterfall_delay_h = 120;
    try state.clearRangeForReconstruction(1, 2);
    try std.testing.expect(!state.branches[1].reproductive_growth_disabled);
    try std.testing.expectEqual(@as(f64, 0), state.branches[1].reproductive_litterfall_delay_h);
}

test "GROSUB remobilization gates preserve elapsed time and reset semantics" {
    const parameters = testParameters();
    var state: State = .{ .accumulated_leafoff_h = 1 };
    var inputs: RemobilizationInputs = .{ .timestep_h = 1, .canopy_temperature_c = -1, .canopy_total_water_potential_megapascal = -0.05 };
    try advanceRemobilization(&state, inputs, parameters, .perennial, .winter_deciduous, false);
    try std.testing.expect(state.shoot_remobilization_enabled);
    try std.testing.expect(state.phenological_remobilization_enabled);
    try std.testing.expectEqual(@as(f64, 1), state.remobilization_elapsed_h);

    inputs.canopy_temperature_c = 1;
    try advanceRemobilization(&state, inputs, parameters, .perennial, .winter_deciduous, false);
    try std.testing.expect(state.shoot_remobilization_enabled);
    try std.testing.expect(!state.phenological_remobilization_enabled);
    try std.testing.expectEqual(@as(f64, 1), state.remobilization_elapsed_h);

    state.accumulated_leafoff_h = 0;
    try advanceRemobilization(&state, inputs, parameters, .perennial, .winter_deciduous, false);
    try std.testing.expect(!state.shoot_remobilization_enabled);
    try std.testing.expectEqual(@as(f64, 0), state.remobilization_elapsed_h);
}

test "annual seed-set enables remobilization independently of leafoff hours" {
    const parameters = testParameters();
    var state: State = .{};
    const inputs: RemobilizationInputs = .{ .timestep_h = 1, .canopy_temperature_c = 10, .canopy_total_water_potential_megapascal = -0.05 };
    try advanceRemobilization(&state, inputs, parameters, .annual, .evergreen, true);
    try std.testing.expect(state.shoot_remobilization_enabled);
    try std.testing.expect(state.phenological_remobilization_enabled);
    try std.testing.expectEqual(@as(f64, 1), state.remobilization_elapsed_h);
}

test "GROSUB drought leaf-abscission gate uses its own PSILY, not HFUNC's" {
    const parameters = testParameters();
    var state: State = .{ .accumulated_leafoff_h = 2 };
    // -1.7 MPa is below HFUNC's leafout/leafoff PSILY (-1.5) but not below
    // GROSUB's own, distinct PSILY (-2.0): grosub.f:50,214,786-789 vs
    // hfunc.f:31,51. The accumulator must gate on the latter.
    const inputs: RemobilizationInputs = .{ .timestep_h = 1, .canopy_temperature_c = 10, .canopy_total_water_potential_megapascal = -1.7 };
    try advanceRemobilization(&state, inputs, parameters, .perennial, .drought_deciduous, false);
    try std.testing.expect(state.shoot_remobilization_enabled);
    try std.testing.expect(!state.phenological_remobilization_enabled);
    try std.testing.expectEqual(@as(f64, 0), state.remobilization_elapsed_h);

    var state2: State = .{ .accumulated_leafoff_h = 2 };
    const inputs2: RemobilizationInputs = .{ .timestep_h = 1, .canopy_temperature_c = 10, .canopy_total_water_potential_megapascal = -2.5 };
    try advanceRemobilization(&state2, inputs2, parameters, .perennial, .drought_deciduous, false);
    try std.testing.expect(state2.phenological_remobilization_enabled);
    try std.testing.expectEqual(@as(f64, 1), state2.remobilization_elapsed_h);
}

test "drought deciduous pre-emergence uses driest surface or seed layer" {
    var state: State = .{ .leafout_disabled = true };
    var inputs = testInputs();
    inputs.emerged = false;
    inputs.floral_initiated = true;
    inputs.surface_soil_water_potential_megapascal = -2;
    try advance(&state, inputs, testParameters(), .annual, .drought_deciduous);
    try std.testing.expectEqual(@as(f64, 1), state.accumulated_leafoff_h);
}

test "evergreen counters follow photoperiod direction" {
    var state: State = .{};
    var inputs = testInputs();
    try advance(&state, inputs, testParameters(), .perennial, .evergreen);
    try std.testing.expectEqual(@as(f64, 1), state.lengthening_photoperiod_h);
    inputs.current_daylength_h = 12;
    inputs.previous_daylength_h = 13;
    try advance(&state, inputs, testParameters(), .perennial, .evergreen);
    try std.testing.expectEqual(@as(f64, 0), state.lengthening_photoperiod_h);
    try std.testing.expectEqual(@as(f64, 1), state.shortening_photoperiod_h);
}

test "dormancy inputs preserve DAY modulo-four chronology" {
    var state: State = .{};
    var inputs = testInputs();
    inputs.day_of_year = 366;
    inputs.execution_year = 1900;
    try advance(&state, inputs, testParameters(), .perennial, .evergreen);

    const before = state;
    inputs.execution_year = 1901;
    try std.testing.expectError(
        error.InvalidDormancyInput,
        advance(&state, inputs, testParameters(), .perennial, .evergreen),
    );
    try std.testing.expectEqualDeep(before, state);

    inputs.day_of_year = 1;
    inputs.execution_year = 0;
    try std.testing.expectError(
        error.InvalidDormancyInput,
        advance(&state, inputs, testParameters(), .perennial, .evergreen),
    );
}

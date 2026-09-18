const std = @import("std");

pub const Parameters = struct {
    reaction_rate_per_h: f64,
    minimum_competition_fraction: f64,
    negligible_demand_g_n: f64,
    nitrous_oxide_product_fraction: f64,
    dinitrogen_product_fraction: f64,
    dissolved_organic_nitrogen_product_fraction: f64,
};

pub const Zone = struct {
    nitrous_acid_concentration_g_n_per_m3: f64,
    nitrite_g_n: f64,
    dissolved_fraction: f64,
    reaction_volume_fraction: f64,
    previous_total_nitrite_demand_g_n: f64,
    previous_unlimited_reduction_g_n: f64,
};

pub const CalculationInputs = struct {
    non_band: Zone,
    band: Zone,
    water_volume_m3: f64,
    temperature_response: f64,
    timestep_h: f64,
};

pub const CalculationResult = struct {
    non_band_nitrite_reduction_g_n: f64,
    band_nitrite_reduction_g_n: f64,
    non_band_unlimited_reduction_g_n: f64,
    band_unlimited_reduction_g_n: f64,
    nitrous_oxide_production_g_n: f64,
    dinitrogen_production_g_n: f64,
    dissolved_organic_nitrogen_production_g_n: f64,
};

/// Legacy routine: NITRO.F lines 2920--2972.
///
/// Calculates one soil layer's non-band and fertilizer-band abiotic nitrite
/// reduction without mutating persistent state. Nitrogen masses are g N,
/// water volume is m3, concentration is g N m-3, and timestep is h.
pub fn calculate(inputs: CalculationInputs, parameters: Parameters) !CalculationResult {
    try validateCalculation(inputs, parameters);
    const non_band = calculateZone(inputs.non_band, inputs, parameters);
    const band = calculateZone(inputs.band, inputs, parameters);
    const total_reduction_g_n = non_band.reduction_g_n + band.reduction_g_n;
    return .{
        .non_band_nitrite_reduction_g_n = non_band.reduction_g_n,
        .band_nitrite_reduction_g_n = band.reduction_g_n,
        .non_band_unlimited_reduction_g_n = non_band.unlimited_g_n,
        .band_unlimited_reduction_g_n = band.unlimited_g_n,
        .nitrous_oxide_production_g_n = total_reduction_g_n *
            parameters.nitrous_oxide_product_fraction,
        .dinitrogen_production_g_n = total_reduction_g_n *
            parameters.dinitrogen_product_fraction,
        .dissolved_organic_nitrogen_production_g_n = total_reduction_g_n *
            parameters.dissolved_organic_nitrogen_product_fraction,
    };
}

const ZoneResult = struct {
    reduction_g_n: f64,
    unlimited_g_n: f64,
};

fn calculateZone(
    zone: Zone,
    inputs: CalculationInputs,
    parameters: Parameters,
) ZoneResult {
    const competition = if (zone.previous_total_nitrite_demand_g_n >
        parameters.negligible_demand_g_n)
        @max(
            parameters.minimum_competition_fraction,
            zone.previous_unlimited_reduction_g_n /
                zone.previous_total_nitrite_demand_g_n,
        )
    else
        parameters.minimum_competition_fraction * zone.dissolved_fraction;
    const unlimited_g_n = parameters.reaction_rate_per_h *
        zone.nitrous_acid_concentration_g_n_per_m3 *
        inputs.water_volume_m3 *
        zone.reaction_volume_fraction *
        inputs.temperature_response *
        inputs.timestep_h;
    return .{
        .reduction_g_n = @max(0, @min(zone.nitrite_g_n * competition, unlimited_g_n)),
        .unlimited_g_n = unlimited_g_n,
    };
}

fn validateCalculation(inputs: CalculationInputs, parameters: Parameters) !void {
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        const value = @field(parameters, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidChemodenitrificationInput;
    }
    if (parameters.negligible_demand_g_n <= 0 or
        @abs(parameters.nitrous_oxide_product_fraction +
            parameters.dinitrogen_product_fraction +
            parameters.dissolved_organic_nitrogen_product_fraction - 1) > 1e-12)
        return error.InvalidChemodenitrificationInput;
    inline for (.{
        inputs.water_volume_m3,
        inputs.temperature_response,
        inputs.timestep_h,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidChemodenitrificationInput;
    inline for (.{ inputs.non_band, inputs.band }) |zone| {
        inline for (@typeInfo(Zone).@"struct".fields) |field| {
            const value = @field(zone, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidChemodenitrificationInput;
        }
        if (zone.dissolved_fraction > 1 or zone.reaction_volume_fraction > 1)
            return error.InvalidChemodenitrificationInput;
    }
}

pub const Inputs = struct {
    preceding_total_non_band_competition: f64,
    preceding_total_band_competition: f64,
    previous_total_non_band_nitrite_demand_g_n: []const f64,
    previous_total_band_nitrite_demand_g_n: []const f64,
    previous_non_band_chemodenitrification_capacity_g_n: []const f64,
    previous_band_chemodenitrification_capacity_g_n: []const f64,
    non_band_nitrite_fraction: []const f64,
    band_nitrite_fraction: []const f64,
    non_band_nitrous_acid_concentration_g_n_m3: []const f64,
    band_nitrous_acid_concentration_g_n_m3: []const f64,
    micropore_water_m3: []const f64,
    non_band_reactive_water_fraction: []const f64,
    band_reactive_water_fraction: []const f64,
    temperature_response: []const f64,
    non_band_nitrite_g_n: []const f64,
    band_nitrite_g_n: []const f64,
    minimum_competition: f64,
    negligible_demand_g_n: f64,
    reaction_rate_m3_per_g_n_h: f64 = 0.0005,
    biochemical_time_fraction_h: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    unit_count: usize,
    total_non_band_competition: f64,
    total_band_competition: f64,
    non_band_competition: []f64,
    band_competition: []f64,
    non_band_capacity_g_n: []f64,
    band_capacity_g_n: []f64,
    non_band_nitrite_reduction_g_n: []f64,
    band_nitrite_reduction_g_n: []f64,
    non_band_nitrous_oxide_production_g_n: []f64,
    band_nitrous_oxide_production_g_n: []f64,
    dinitrogen_production_g_n: []f64,
    dissolved_organic_nitrogen_production_g_n: []f64,

    pub fn init(allocator: std.mem.Allocator, unit_count: usize) !State {
        if (unit_count == 0) return error.InvalidChemodenitrificationDimensions;
        var state: State = undefined;
        state.allocator = allocator;
        state.unit_count = unit_count;
        state.total_non_band_competition = 0;
        state.total_band_competition = 0;
        var allocated: usize = 0;
        errdefer {
            inline for (@typeInfo(State).@"struct".fields) |field| {
                if (field.type == []f64 and allocated > 0) {
                    allocated -= 1;
                    allocator.free(@field(state, field.name));
                }
            }
        }
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(state, field.name) = try allocator.alloc(f64, unit_count);
            @memset(@field(state, field.name), 0);
            allocated += 1;
        };
        return state;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field|
            if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

/// Exact NITRO.F 2920--2972 abiotic nitrous-acid chemodenitrification.
pub fn calculateBatch(state: *State, inputs: Inputs) !void {
    try validate(state, inputs);
    const temporary = try state.allocator.alloc([10]f64, state.unit_count);
    defer state.allocator.free(temporary);
    var total_non_band = inputs.preceding_total_non_band_competition;
    var total_band = inputs.preceding_total_band_competition;
    for (0..state.unit_count) |unit| {
        const non_band_competition = if (inputs.previous_total_non_band_nitrite_demand_g_n[unit] >
            inputs.negligible_demand_g_n)
            @max(inputs.minimum_competition, inputs.previous_non_band_chemodenitrification_capacity_g_n[unit] /
                inputs.previous_total_non_band_nitrite_demand_g_n[unit])
        else
            inputs.minimum_competition * inputs.non_band_nitrite_fraction[unit];
        const band_competition = if (inputs.previous_total_band_nitrite_demand_g_n[unit] >
            inputs.negligible_demand_g_n)
            @max(inputs.minimum_competition, inputs.previous_band_chemodenitrification_capacity_g_n[unit] /
                inputs.previous_total_band_nitrite_demand_g_n[unit])
        else
            inputs.minimum_competition * inputs.band_nitrite_fraction[unit];
        const non_band_capacity = inputs.reaction_rate_m3_per_g_n_h *
            inputs.non_band_nitrous_acid_concentration_g_n_m3[unit] *
            inputs.micropore_water_m3[unit] *
            inputs.non_band_reactive_water_fraction[unit] *
            inputs.temperature_response[unit] * inputs.biochemical_time_fraction_h;
        const band_capacity = inputs.reaction_rate_m3_per_g_n_h *
            inputs.band_nitrous_acid_concentration_g_n_m3[unit] *
            inputs.micropore_water_m3[unit] *
            inputs.band_reactive_water_fraction[unit] *
            inputs.temperature_response[unit] * inputs.biochemical_time_fraction_h;
        const non_band_supply =
            inputs.non_band_nitrite_g_n[unit] * non_band_competition;
        const band_supply = inputs.band_nitrite_g_n[unit] * band_competition;
        const non_band_reduction = @max(0, @min(
            non_band_supply,
            non_band_capacity,
        ));
        const band_reduction = @max(0, @min(
            band_supply,
            band_capacity,
        ));
        temporary[unit] = .{
            non_band_competition, band_competition,                            non_band_capacity,        band_capacity,
            non_band_reduction,   band_reduction,                              0.5 * non_band_reduction, 0.5 * band_reduction,
            0,                    0.5 * (non_band_reduction + band_reduction),
        };
        inline for (.{
            non_band_supply,
            band_supply,
            non_band_capacity,
            band_capacity,
        }) |value| if (!std.math.isFinite(value))
            return error.NonFiniteChemodenitrificationResult;
        for (temporary[unit]) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.NonFiniteChemodenitrificationResult;
        total_non_band += non_band_competition;
        total_band += band_competition;
    }
    if (!std.math.isFinite(total_non_band) or !std.math.isFinite(total_band))
        return error.NonFiniteChemodenitrificationResult;
    state.total_non_band_competition = total_non_band;
    state.total_band_competition = total_band;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        const index = comptime stateFieldIndex(field.name);
        for (temporary, 0..) |values, unit| @field(state, field.name)[unit] = values[index];
    };
}

fn stateFieldIndex(comptime name: []const u8) usize {
    var index: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        if (comptime std.mem.eql(u8, field.name, name)) return index;
        index += 1;
    };
    unreachable;
}

fn validate(state: *const State, inputs: Inputs) !void {
    const n = state.unit_count;
    inline for (.{
        inputs.preceding_total_non_band_competition,
        inputs.preceding_total_band_competition,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidChemodenitrificationInput;
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (field.type == []const f64) {
        const values = @field(inputs, field.name);
        if (values.len != n) return error.InvalidChemodenitrificationDimensions;
        for (values) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidChemodenitrificationInput;
    };
    inline for (.{
        inputs.minimum_competition,        inputs.negligible_demand_g_n,
        inputs.reaction_rate_m3_per_g_n_h, inputs.biochemical_time_fraction_h,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidChemodenitrificationInput;
}

fn fixture() Inputs {
    return .{
        .preceding_total_non_band_competition = 0.25,
        .preceding_total_band_competition = 0.5,
        .previous_total_non_band_nitrite_demand_g_n = &.{10},
        .previous_total_band_nitrite_demand_g_n = &.{4},
        .previous_non_band_chemodenitrification_capacity_g_n = &.{2},
        .previous_band_chemodenitrification_capacity_g_n = &.{2},
        .non_band_nitrite_fraction = &.{0.6},
        .band_nitrite_fraction = &.{0.4},
        .non_band_nitrous_acid_concentration_g_n_m3 = &.{2},
        .band_nitrous_acid_concentration_g_n_m3 = &.{1},
        .micropore_water_m3 = &.{10},
        .non_band_reactive_water_fraction = &.{0.6},
        .band_reactive_water_fraction = &.{0.4},
        .temperature_response = &.{2},
        .non_band_nitrite_g_n = &.{20},
        .band_nitrite_g_n = &.{10},
        .minimum_competition = 0.01,
        .negligible_demand_g_n = 1e-12,
        .reaction_rate_m3_per_g_n_h = 0.0005,
        .biochemical_time_fraction_h = 1,
    };
}

test "chemodenitrification preserves previous-demand competition" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try calculateBatch(&state, fixture());
    try std.testing.expectApproxEqAbs(0.2, state.non_band_competition[0], 1e-12);
    try std.testing.expectApproxEqAbs(0.5, state.band_competition[0], 1e-12);
    try std.testing.expectApproxEqAbs(0.45, state.total_non_band_competition, 1e-12);
    try std.testing.expectApproxEqAbs(1, state.total_band_competition, 1e-12);
    try std.testing.expect(state.non_band_nitrite_reduction_g_n[0] > 0);
}

test "products split equally between N2O and dissolved organic nitrogen" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try calculateBatch(&state, fixture());
    const reduction = state.non_band_nitrite_reduction_g_n[0] +
        state.band_nitrite_reduction_g_n[0];
    try std.testing.expectApproxEqAbs(
        0.5 * reduction,
        state.non_band_nitrous_oxide_production_g_n[0] +
            state.band_nitrous_oxide_production_g_n[0],
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        0.5 * reduction,
        state.dissolved_organic_nitrogen_production_g_n[0],
        1e-12,
    );
    try std.testing.expectEqual(0, state.dinitrogen_production_g_n[0]);
}

test "fallback competition uses minimum times zone fraction" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var inputs = fixture();
    inputs.previous_total_non_band_nitrite_demand_g_n = &.{0};
    try calculateBatch(&state, inputs);
    try std.testing.expectApproxEqAbs(0.006, state.non_band_competition[0], 1e-12);
}

test "invalid input leaves state unchanged" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.dissolved_organic_nitrogen_production_g_n[0] = 7;
    var inputs = fixture();
    inputs.temperature_response = &.{std.math.nan(f64)};
    try std.testing.expectError(error.InvalidChemodenitrificationInput, calculateBatch(&state, inputs));
    try std.testing.expectEqual(7, state.dissolved_organic_nitrogen_production_g_n[0]);
}

test "NITRO 2920-2972 pre-cap overflow preserves chemodenitrification state" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.non_band_nitrite_reduction_g_n[0] = 7;
    state.total_non_band_competition = 8;
    var inputs = fixture();
    inputs.non_band_nitrite_g_n = &.{std.math.floatMax(f64)};
    inputs.previous_non_band_chemodenitrification_capacity_g_n =
        &.{std.math.floatMax(f64)};
    try std.testing.expectError(
        error.NonFiniteChemodenitrificationResult,
        calculateBatch(&state, inputs),
    );
    try std.testing.expectEqual(7, state.non_band_nitrite_reduction_g_n[0]);
    try std.testing.expectEqual(8, state.total_non_band_competition);
}

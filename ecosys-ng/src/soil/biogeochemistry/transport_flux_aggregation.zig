const std = @import("std");

const source_substrate_class_count = 5;
const source_residue_fraction_count = 2;
const source_population_count = 7;

pub const Inputs = struct {
    complex_count: usize,
    substrate_class_count: usize,
    residue_fraction_count: usize,
    population_count: usize,
    existing_dissolved_carbon_change_g_c: []const f64,
    existing_dissolved_nitrogen_change_g_n: []const f64,
    existing_dissolved_phosphorus_change_g_p: []const f64,
    existing_acetate_change_g_c: []const f64,
    substrate_dissolved_carbon_product_g_c: []const f64,
    substrate_dissolved_nitrogen_product_g_n: []const f64,
    substrate_dissolved_phosphorus_product_g_p: []const f64,
    residue_decomposition_carbon_g_c: []const f64,
    residue_decomposition_nitrogen_g_n: []const f64,
    residue_decomposition_phosphorus_g_p: []const f64,
    sorbed_decomposition_carbon_g_c: []const f64,
    sorbed_decomposition_nitrogen_g_n: []const f64,
    sorbed_decomposition_phosphorus_g_p: []const f64,
    sorbed_decomposition_acetate_g_c: []const f64,
    dissolved_carbon_uptake_g_c: []const f64,
    dissolved_nitrogen_uptake_g_n: []const f64,
    dissolved_phosphorus_uptake_g_p: []const f64,
    acetate_uptake_g_c: []const f64,
    fermentation_acetate_production_g_c: []const f64,
    carbon_sorption_g_c: []const f64,
    nitrogen_sorption_g_n: []const f64,
    phosphorus_sorption_g_p: []const f64,
    acetate_sorption_g_c: []const f64,
    total_non_band_ammonium_exchange_g_n: f64,
    total_band_ammonium_exchange_g_n: f64,
    total_non_band_nitrate_exchange_g_n: f64,
    total_band_nitrate_exchange_g_n: f64,
    total_non_band_dihydrogen_phosphate_exchange_g_p: f64,
    total_band_dihydrogen_phosphate_exchange_g_p: f64,
    total_non_band_hydrogen_phosphate_exchange_g_p: f64,
    total_band_hydrogen_phosphate_exchange_g_p: f64,
    non_band_ammonium_oxidation_g_n: f64,
    band_ammonium_oxidation_g_n: f64,
    non_band_nitrite_oxidation_g_n: f64,
    band_nitrite_oxidation_g_n: f64,
    non_band_nitrate_reduction_g_n: f64,
    band_nitrate_reduction_g_n: f64,
    non_band_nitrite_reduction_g_n: f64,
    band_nitrite_reduction_g_n: f64,
    non_band_chemodenitrification_nitrite_g_n: f64,
    band_chemodenitrification_nitrite_g_n: f64,
    fixed_dinitrogen_g_n: f64,
    temperature_response: f64,
    biologically_active_water_m3: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    backing: []f64,
    complex_count: usize,
    dissolved_carbon_change_g_c: []f64,
    dissolved_nitrogen_change_g_n: []f64,
    dissolved_phosphorus_change_g_p: []f64,
    acetate_change_g_c: []f64,
    non_band_ammonium_change_g_n: f64 = 0,
    band_ammonium_change_g_n: f64 = 0,
    non_band_nitrate_change_g_n: f64 = 0,
    band_nitrate_change_g_n: f64 = 0,
    non_band_nitrite_change_g_n: f64 = 0,
    band_nitrite_change_g_n: f64 = 0,
    non_band_dihydrogen_phosphate_change_g_p: f64 = 0,
    band_dihydrogen_phosphate_change_g_p: f64 = 0,
    non_band_hydrogen_phosphate_change_g_p: f64 = 0,
    band_hydrogen_phosphate_change_g_p: f64 = 0,
    dinitrogen_fixation_g_n: f64 = 0,
    transport_temperature_response: f64 = 0,
    transport_active_water_m3: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, complex_count: usize) !State {
        if (complex_count == 0) return error.InvalidTransportFluxDimensions;
        const backing = try allocator.alloc(f64, complex_count * 4);
        @memset(backing, 0);
        return .{
            .allocator = allocator,
            .backing = backing,
            .complex_count = complex_count,
            .dissolved_carbon_change_g_c = backing[0..complex_count],
            .dissolved_nitrogen_change_g_n = backing[complex_count .. 2 * complex_count],
            .dissolved_phosphorus_change_g_p = backing[2 * complex_count .. 3 * complex_count],
            .acetate_change_g_c = backing[3 * complex_count ..],
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.backing);
        self.* = undefined;
    }
};

/// Exact NITRO.F 4061--4099 TRNSFR/REDIST organic and mineral flux assembly.
pub fn calculate(state: *State, inputs: Inputs) !void {
    try validate(state, inputs);
    const temporary = try state.allocator.alloc([4]f64, state.complex_count);
    defer state.allocator.free(temporary);
    for (0..state.complex_count) |complex| {
        var carbon = inputs.existing_dissolved_carbon_change_g_c[complex];
        var nitrogen = inputs.existing_dissolved_nitrogen_change_g_n[complex];
        var phosphorus = inputs.existing_dissolved_phosphorus_change_g_p[complex];
        var acetate = inputs.existing_acetate_change_g_c[complex];
        for (0..source_substrate_class_count) |class| {
            const item = complex * inputs.substrate_class_count + class;
            carbon += inputs.substrate_dissolved_carbon_product_g_c[item];
            nitrogen += inputs.substrate_dissolved_nitrogen_product_g_n[item];
            phosphorus += inputs.substrate_dissolved_phosphorus_product_g_p[item];
        }
        for (0..source_residue_fraction_count) |fraction| {
            const item = complex * inputs.residue_fraction_count + fraction;
            carbon += inputs.residue_decomposition_carbon_g_c[item];
            nitrogen += inputs.residue_decomposition_nitrogen_g_n[item];
            phosphorus += inputs.residue_decomposition_phosphorus_g_p[item];
        }
        carbon += inputs.sorbed_decomposition_carbon_g_c[complex];
        nitrogen += inputs.sorbed_decomposition_nitrogen_g_n[complex];
        phosphorus += inputs.sorbed_decomposition_phosphorus_g_p[complex];
        acetate += inputs.sorbed_decomposition_acetate_g_c[complex];
        for (0..source_population_count) |population| {
            const item = complex * inputs.population_count + population;
            carbon -= inputs.dissolved_carbon_uptake_g_c[item];
            nitrogen -= inputs.dissolved_nitrogen_uptake_g_n[item];
            phosphorus -= inputs.dissolved_phosphorus_uptake_g_p[item];
            acetate -= inputs.acetate_uptake_g_c[item];
            acetate += inputs.fermentation_acetate_production_g_c[item];
        }
        carbon -= inputs.carbon_sorption_g_c[complex];
        nitrogen -= inputs.nitrogen_sorption_g_n[complex];
        phosphorus -= inputs.phosphorus_sorption_g_p[complex];
        acetate -= inputs.acetate_sorption_g_c[complex];
        temporary[complex] = .{ carbon, nitrogen, phosphorus, acetate };
    }
    for (temporary) |values| inline for (values) |value|
        if (!std.math.isFinite(value)) return error.InvalidTransportFluxResult;
    var result = state.*;
    result.non_band_ammonium_change_g_n =
        -inputs.total_non_band_ammonium_exchange_g_n -
        inputs.non_band_ammonium_oxidation_g_n;
    result.band_ammonium_change_g_n =
        -inputs.total_band_ammonium_exchange_g_n -
        inputs.band_ammonium_oxidation_g_n;
    result.non_band_nitrate_change_g_n =
        -inputs.total_non_band_nitrate_exchange_g_n +
        inputs.non_band_nitrite_oxidation_g_n -
        inputs.non_band_nitrate_reduction_g_n;
    result.band_nitrate_change_g_n =
        -inputs.total_band_nitrate_exchange_g_n +
        inputs.band_nitrite_oxidation_g_n -
        inputs.band_nitrate_reduction_g_n;
    result.non_band_nitrite_change_g_n =
        inputs.non_band_ammonium_oxidation_g_n -
        inputs.non_band_nitrite_oxidation_g_n +
        inputs.non_band_nitrate_reduction_g_n -
        inputs.non_band_nitrite_reduction_g_n -
        inputs.non_band_chemodenitrification_nitrite_g_n;
    result.band_nitrite_change_g_n =
        inputs.band_ammonium_oxidation_g_n -
        inputs.band_nitrite_oxidation_g_n +
        inputs.band_nitrate_reduction_g_n -
        inputs.band_nitrite_reduction_g_n -
        inputs.band_chemodenitrification_nitrite_g_n;
    result.non_band_dihydrogen_phosphate_change_g_p =
        -inputs.total_non_band_dihydrogen_phosphate_exchange_g_p;
    result.band_dihydrogen_phosphate_change_g_p =
        -inputs.total_band_dihydrogen_phosphate_exchange_g_p;
    result.non_band_hydrogen_phosphate_change_g_p =
        -inputs.total_non_band_hydrogen_phosphate_exchange_g_p;
    result.band_hydrogen_phosphate_change_g_p =
        -inputs.total_band_hydrogen_phosphate_exchange_g_p;
    result.dinitrogen_fixation_g_n = inputs.fixed_dinitrogen_g_n;
    result.transport_temperature_response = inputs.temperature_response;
    result.transport_active_water_m3 = inputs.biologically_active_water_m3;
    inline for (@typeInfo(State).@"struct".fields) |field| {
        if (field.type == f64 and !std.math.isFinite(@field(result, field.name)))
            return error.InvalidTransportFluxResult;
    }
    for (temporary, 0..) |values, complex| {
        state.dissolved_carbon_change_g_c[complex] = values[0];
        state.dissolved_nitrogen_change_g_n[complex] = values[1];
        state.dissolved_phosphorus_change_g_p[complex] = values[2];
        state.acetate_change_g_c[complex] = values[3];
    }
    inline for (@typeInfo(State).@"struct".fields) |field| {
        if (field.type == f64) @field(state, field.name) = @field(result, field.name);
    }
}

fn validate(state: *const State, inputs: Inputs) !void {
    if (inputs.complex_count != state.complex_count or
        inputs.substrate_class_count < source_substrate_class_count or
        inputs.residue_fraction_count < source_residue_fraction_count or
        inputs.population_count < source_population_count)
        return error.InvalidTransportFluxDimensions;
    inline for (.{
        inputs.existing_dissolved_carbon_change_g_c,
        inputs.existing_dissolved_nitrogen_change_g_n,
        inputs.existing_dissolved_phosphorus_change_g_p,
        inputs.existing_acetate_change_g_c,
        inputs.sorbed_decomposition_carbon_g_c,
        inputs.sorbed_decomposition_nitrogen_g_n,
        inputs.sorbed_decomposition_phosphorus_g_p,
        inputs.sorbed_decomposition_acetate_g_c,
        inputs.carbon_sorption_g_c,
        inputs.nitrogen_sorption_g_n,
        inputs.phosphorus_sorption_g_p,
        inputs.acetate_sorption_g_c,
    }) |values| if (values.len != state.complex_count)
        return error.InvalidTransportFluxDimensions;
    const substrate_items = std.math.mul(
        usize,
        state.complex_count,
        inputs.substrate_class_count,
    ) catch return error.InvalidTransportFluxDimensions;
    inline for (.{
        inputs.substrate_dissolved_carbon_product_g_c,
        inputs.substrate_dissolved_nitrogen_product_g_n,
        inputs.substrate_dissolved_phosphorus_product_g_p,
    }) |values| if (values.len != substrate_items) return error.InvalidTransportFluxDimensions;
    const residue_items = std.math.mul(
        usize,
        state.complex_count,
        inputs.residue_fraction_count,
    ) catch return error.InvalidTransportFluxDimensions;
    inline for (.{
        inputs.residue_decomposition_carbon_g_c,     inputs.residue_decomposition_nitrogen_g_n,
        inputs.residue_decomposition_phosphorus_g_p,
    }) |values| if (values.len != residue_items) return error.InvalidTransportFluxDimensions;
    const population_items = std.math.mul(
        usize,
        state.complex_count,
        inputs.population_count,
    ) catch return error.InvalidTransportFluxDimensions;
    inline for (.{
        inputs.dissolved_carbon_uptake_g_c,         inputs.dissolved_nitrogen_uptake_g_n,
        inputs.dissolved_phosphorus_uptake_g_p,     inputs.acetate_uptake_g_c,
        inputs.fermentation_acetate_production_g_c,
    }) |values| if (values.len != population_items) return error.InvalidTransportFluxDimensions;
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (field.type == []const f64) {
            for (@field(inputs, field.name)) |value| if (!std.math.isFinite(value))
                return error.InvalidTransportFluxInput;
        } else if (field.type == f64) {
            const value = @field(inputs, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidTransportFluxInput;
        }
    }
}

fn fixture() Inputs {
    return .{
        .complex_count = 1,
        .substrate_class_count = 5,
        .residue_fraction_count = 2,
        .population_count = 7,
        .existing_dissolved_carbon_change_g_c = &.{1},
        .existing_dissolved_nitrogen_change_g_n = &.{0.5},
        .existing_dissolved_phosphorus_change_g_p = &.{0.25},
        .existing_acetate_change_g_c = &.{0},
        .substrate_dissolved_carbon_product_g_c = &.{ 1, 2, 0, 0, 0 },
        .substrate_dissolved_nitrogen_product_g_n = &.{ 0.1, 0.2, 0, 0, 0 },
        .substrate_dissolved_phosphorus_product_g_p = &.{ 0.05, 0.1, 0, 0, 0 },
        .residue_decomposition_carbon_g_c = &.{ 0.5, 1 },
        .residue_decomposition_nitrogen_g_n = &.{ 0.05, 0.1 },
        .residue_decomposition_phosphorus_g_p = &.{ 0.025, 0.05 },
        .sorbed_decomposition_carbon_g_c = &.{0.5},
        .sorbed_decomposition_nitrogen_g_n = &.{0.05},
        .sorbed_decomposition_phosphorus_g_p = &.{0.025},
        .sorbed_decomposition_acetate_g_c = &.{0.5},
        .dissolved_carbon_uptake_g_c = &.{ 1, 1, 0, 0, 0, 0, 0 },
        .dissolved_nitrogen_uptake_g_n = &.{ 0.1, 0.1, 0, 0, 0, 0, 0 },
        .dissolved_phosphorus_uptake_g_p = &.{ 0.05, 0.05, 0, 0, 0, 0, 0 },
        .acetate_uptake_g_c = &.{ 0.25, 0.25, 0, 0, 0, 0, 0 },
        .fermentation_acetate_production_g_c = &.{ 0.5, 0, 0, 0, 0, 0, 0 },
        .carbon_sorption_g_c = &.{0.5},
        .nitrogen_sorption_g_n = &.{0.05},
        .phosphorus_sorption_g_p = &.{0.025},
        .acetate_sorption_g_c = &.{0.1},
        .total_non_band_ammonium_exchange_g_n = 1,
        .total_band_ammonium_exchange_g_n = 2,
        .total_non_band_nitrate_exchange_g_n = 1,
        .total_band_nitrate_exchange_g_n = 2,
        .total_non_band_dihydrogen_phosphate_exchange_g_p = 1,
        .total_band_dihydrogen_phosphate_exchange_g_p = 2,
        .total_non_band_hydrogen_phosphate_exchange_g_p = 1,
        .total_band_hydrogen_phosphate_exchange_g_p = 2,
        .non_band_ammonium_oxidation_g_n = 3,
        .band_ammonium_oxidation_g_n = 4,
        .non_band_nitrite_oxidation_g_n = 2,
        .band_nitrite_oxidation_g_n = 3,
        .non_band_nitrate_reduction_g_n = 1,
        .band_nitrate_reduction_g_n = 2,
        .non_band_nitrite_reduction_g_n = 0.5,
        .band_nitrite_reduction_g_n = 1,
        .non_band_chemodenitrification_nitrite_g_n = 0.25,
        .band_chemodenitrification_nitrite_g_n = 0.5,
        .fixed_dinitrogen_g_n = 0.2,
        .temperature_response = 0.8,
        .biologically_active_water_m3 = 2,
    };
}

test "organic transport deltas aggregate all products uptake and sorption" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try calculate(&state, fixture());
    try std.testing.expectApproxEqAbs(3.5, state.dissolved_carbon_change_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(0.4, state.acetate_change_g_c[0], 1e-12);
}

test "organic transport preserves source acetate subtraction then addition order" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var inputs = fixture();
    inputs.existing_acetate_change_g_c = &.{1.0e16};
    inputs.sorbed_decomposition_acetate_g_c = &.{0};
    inputs.acetate_uptake_g_c = &.{ 1.0e16, 0, 0, 0, 0, 0, 0 };
    inputs.fermentation_acetate_production_g_c = &.{ 1, 0, 0, 0, 0, 0, 0 };
    inputs.acetate_sorption_g_c = &.{0};
    try calculate(&state, inputs);
    try std.testing.expectEqual(@as(f64, 1), state.acetate_change_g_c[0]);
}

test "runtime axes beyond source role counts remain scientifically inactive" {
    const substrate_carbon = [_]f64{ 1, 2, 0, 0, 0, 100 };
    const substrate_nitrogen = [_]f64{ 0.1, 0.2, 0, 0, 0, 100 };
    const substrate_phosphorus = [_]f64{ 0.05, 0.1, 0, 0, 0, 100 };
    const residue_carbon = [_]f64{ 0.5, 1, 100 };
    const residue_nitrogen = [_]f64{ 0.05, 0.1, 100 };
    const residue_phosphorus = [_]f64{ 0.025, 0.05, 100 };
    const uptake_carbon = [_]f64{ 1, 1, 0, 0, 0, 0, 0, 100 };
    const uptake_nitrogen = [_]f64{ 0.1, 0.1, 0, 0, 0, 0, 0, 100 };
    const uptake_phosphorus = [_]f64{ 0.05, 0.05, 0, 0, 0, 0, 0, 100 };
    const acetate_uptake = [_]f64{ 0.25, 0.25, 0, 0, 0, 0, 0, 100 };
    const acetate_production = [_]f64{ 0.5, 0, 0, 0, 0, 0, 0, 100 };
    var inputs = fixture();
    inputs.substrate_class_count = 6;
    inputs.residue_fraction_count = 3;
    inputs.population_count = 8;
    inputs.substrate_dissolved_carbon_product_g_c = &substrate_carbon;
    inputs.substrate_dissolved_nitrogen_product_g_n = &substrate_nitrogen;
    inputs.substrate_dissolved_phosphorus_product_g_p = &substrate_phosphorus;
    inputs.residue_decomposition_carbon_g_c = &residue_carbon;
    inputs.residue_decomposition_nitrogen_g_n = &residue_nitrogen;
    inputs.residue_decomposition_phosphorus_g_p = &residue_phosphorus;
    inputs.dissolved_carbon_uptake_g_c = &uptake_carbon;
    inputs.dissolved_nitrogen_uptake_g_n = &uptake_nitrogen;
    inputs.dissolved_phosphorus_uptake_g_p = &uptake_phosphorus;
    inputs.acetate_uptake_g_c = &acetate_uptake;
    inputs.fermentation_acetate_production_g_c = &acetate_production;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try calculate(&state, inputs);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), state.dissolved_carbon_change_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), state.acetate_change_g_c[0], 1e-12);
}

test "mineral flux equations preserve nitrification and denitrification signs" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try calculate(&state, fixture());
    try std.testing.expectEqual(-4, state.non_band_ammonium_change_g_n);
    try std.testing.expectEqual(0, state.non_band_nitrate_change_g_n);
    try std.testing.expectApproxEqAbs(1.25, state.non_band_nitrite_change_g_n, 1e-12);
}

test "phosphate and environmental transport ledgers are copied exactly" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try calculate(&state, fixture());
    try std.testing.expectEqual(-2, state.band_dihydrogen_phosphate_change_g_p);
    try std.testing.expectEqual(0.8, state.transport_temperature_response);
    try std.testing.expectEqual(2, state.transport_active_water_m3);
}

test "invalid input leaves state unchanged" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.dissolved_carbon_change_g_c[0] = 7;
    var inputs = fixture();
    inputs.temperature_response = std.math.nan(f64);
    try std.testing.expectError(error.InvalidTransportFluxInput, calculate(&state, inputs));
    try std.testing.expectEqual(7, state.dissolved_carbon_change_g_c[0]);
}

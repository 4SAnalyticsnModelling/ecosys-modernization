//! Per-cell microbial thermal adaptation (`OFFSET`).
//!
//! Initialization is the exact two-slope `STARTS.F:510--514` calculation.
//! Climate-change mode 2 refreshes the same state with the distinct single-
//! slope `WTHR.F:412--416` calculation. A temperature difference in Celsius is
//! numerically identical in kelvin, so consumers add this value to `TKS`.

const std = @import("std");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    thermal_adaptation_offset_k: []f64,

    /// Initializes the authoritative per-cell state from `STARTS.F`'s ATCS.
    pub fn init(
        allocator: std.mem.Allocator,
        mean_annual_soil_temperature_c: []const f64,
    ) !State {
        const offsets = try allocator.alloc(
            f64,
            mean_annual_soil_temperature_c.len,
        );
        errdefer allocator.free(offsets);
        try derive(offsets, mean_annual_soil_temperature_c, sourceParameters());
        return .{
            .allocator = allocator,
            .cell_count = mean_annual_soil_temperature_c.len,
            .thermal_adaptation_offset_k = offsets,
        };
    }

    /// Constructs checkpoint-owned state without re-deriving it from climate.
    pub fn initFromOffsets(
        allocator: std.mem.Allocator,
        thermal_adaptation_offset_k: []const f64,
    ) !State {
        if (thermal_adaptation_offset_k.len == 0)
            return error.MicrobialThermalAdaptationDimensionMismatch;
        for (thermal_adaptation_offset_k) |offset_k|
            if (!std.math.isFinite(offset_k))
                return error.NonFiniteMicrobialThermalAdaptationOffset;
        return .{
            .allocator = allocator,
            .cell_count = thermal_adaptation_offset_k.len,
            .thermal_adaptation_offset_k = try allocator.dupe(
                f64,
                thermal_adaptation_offset_k,
            ),
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.thermal_adaptation_offset_k);
        self.* = undefined;
    }

    /// Exact mode-2 `WTHR.F:412--416` refresh. `DTA` is cumulative climate
    /// change for the current day; the refresh is absolute from `ATCAI`, not a
    /// recurrence from yesterday's ATCS/OFFSET.
    pub fn refreshClimateMode2(
        self: *State,
        initial_mean_annual_air_temperature_c: []const f64,
        daily_average_air_temperature_change_c: f64,
    ) !void {
        if (initial_mean_annual_air_temperature_c.len != self.cell_count)
            return error.MicrobialThermalAdaptationDimensionMismatch;
        if (!std.math.isFinite(daily_average_air_temperature_change_c))
            return error.NonFiniteMicrobialThermalAdaptationClimateChange;

        // Validate every cell first so a bad late input cannot partially
        // replace the live offsets.
        for (initial_mean_annual_air_temperature_c) |initial_air_c| {
            if (!std.math.isFinite(initial_air_c))
                return error.NonFiniteMeanAnnualAirTemperature;
            const soil_change_c = 0.5 * daily_average_air_temperature_change_c;
            const next_soil_c = initial_air_c + soil_change_c;
            const candidate = 0.333 *
                (15.0 - std.math.clamp(next_soil_c, 0.0, 30.0));
            if (!std.math.isFinite(candidate))
                return error.MicrobialThermalAdaptationOverflow;
        }

        const soil_change_c = 0.5 * daily_average_air_temperature_change_c;
        for (
            initial_mean_annual_air_temperature_c,
            self.thermal_adaptation_offset_k,
        ) |initial_air_c, *offset_k| {
            const next_soil_c = initial_air_c + soil_change_c;
            offset_k.* = 0.333 *
                (15.0 - std.math.clamp(next_soil_c, 0.0, 30.0));
        }
    }
};

pub const Parameters = struct {
    branch_temperature_c: f64,
    minimum_effective_temperature_c: f64,
    maximum_effective_temperature_c: f64,
    cold_response_c_per_c: f64,
    warm_response_c_per_c: f64,
};

/// Exact source-order translation of legacy `STARTS` lines 510--514.
pub fn derive(
    thermal_adaptation_offset_c: []f64,
    mean_annual_soil_temperature_c: []const f64,
    parameters: Parameters,
) !void {
    const cell_count = mean_annual_soil_temperature_c.len;
    if (cell_count == 0 or thermal_adaptation_offset_c.len != cell_count)
        return error.MicrobialThermalAdaptationDimensionMismatch;
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        const value = @field(parameters, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteMicrobialThermalAdaptationParameter;
    }
    if (parameters.minimum_effective_temperature_c >
        parameters.branch_temperature_c or
        parameters.branch_temperature_c >
            parameters.maximum_effective_temperature_c or
        parameters.cold_response_c_per_c < 0 or
        parameters.warm_response_c_per_c < 0)
    {
        return error.InvalidMicrobialThermalAdaptationParameter;
    }
    for (mean_annual_soil_temperature_c) |temperature_c| {
        if (!std.math.isFinite(temperature_c))
            return error.NonFiniteMeanAnnualSoilTemperature;
        const candidate =
            if (temperature_c <= parameters.branch_temperature_c)
                parameters.cold_response_c_per_c *
                    (parameters.branch_temperature_c -
                        @max(
                            parameters.minimum_effective_temperature_c,
                            temperature_c,
                        ))
            else
                parameters.warm_response_c_per_c *
                    (parameters.branch_temperature_c -
                        @min(
                            parameters.maximum_effective_temperature_c,
                            temperature_c,
                        ));
        if (!std.math.isFinite(candidate))
            return error.MicrobialThermalAdaptationOverflow;
    }

    for (mean_annual_soil_temperature_c, thermal_adaptation_offset_c) |
        temperature_c,
        *offset_c,
    | {
        if (temperature_c <= parameters.branch_temperature_c) {
            offset_c.* = parameters.cold_response_c_per_c *
                (parameters.branch_temperature_c -
                    @max(
                        parameters.minimum_effective_temperature_c,
                        temperature_c,
                    ));
        } else {
            offset_c.* = parameters.warm_response_c_per_c *
                (parameters.branch_temperature_c -
                    @min(
                        parameters.maximum_effective_temperature_c,
                        temperature_c,
                    ));
        }
    }
}

pub fn sourceParameters() Parameters {
    return .{
        .branch_temperature_c = 15.0,
        .minimum_effective_temperature_c = 0.0,
        .maximum_effective_temperature_c = 30.0,
        .cold_response_c_per_c = 0.333,
        .warm_response_c_per_c = 0.167,
    };
}

test "state derives exact per-cell STARTS offsets" {
    var state = try State.init(std.testing.allocator, &.{ 5.4, 20.0 });
    defer state.deinit();

    try std.testing.expectApproxEqAbs(
        @as(f64, 3.1968),
        state.thermal_adaptation_offset_k[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.835),
        state.thermal_adaptation_offset_k[1],
        1e-15,
    );
}

test "mode 2 refresh is absolute daily WTHR state and atomic" {
    var state = try State.init(std.testing.allocator, &.{ 5.0, 20.0 });
    defer state.deinit();

    try state.refreshClimateMode2(&.{ 5.0, 20.0 }, 4.0);
    try std.testing.expectApproxEqAbs(
        @as(f64, 2.664),
        state.thermal_adaptation_offset_k[0],
        1e-15,
    );
    // WTHR deliberately retains the 0.333 slope above 15 C.
    try std.testing.expectApproxEqAbs(
        @as(f64, -2.331),
        state.thermal_adaptation_offset_k[1],
        1e-15,
    );
    const before = try std.testing.allocator.dupe(
        f64,
        state.thermal_adaptation_offset_k,
    );
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.NonFiniteMeanAnnualAirTemperature,
        state.refreshClimateMode2(&.{ 5.0, std.math.nan(f64) }, 6.0),
    );
    try std.testing.expectEqualSlices(
        f64,
        before,
        state.thermal_adaptation_offset_k,
    );
}

test "restored state resumes mode 2 refresh reproducibly" {
    var uninterrupted = try State.init(std.testing.allocator, &.{ 5.4, 17.0 });
    defer uninterrupted.deinit();
    try uninterrupted.refreshClimateMode2(&.{ 5.4, 17.0 }, 1.25);

    var restored = try State.initFromOffsets(
        std.testing.allocator,
        uninterrupted.thermal_adaptation_offset_k,
    );
    defer restored.deinit();

    try uninterrupted.refreshClimateMode2(&.{ 5.4, 17.0 }, 2.5);
    try restored.refreshClimateMode2(&.{ 5.4, 17.0 }, 2.5);
    try std.testing.expectEqualSlices(
        f64,
        uninterrupted.thermal_adaptation_offset_k,
        restored.thermal_adaptation_offset_k,
    );
}

test "STARTS thermal adaptation reproduces both source branches and clamps" {
    var offsets = [_]f64{0.0} ** 7;
    try derive(
        &offsets,
        &.{ -10.0, 0.0, 10.0, 15.0, 20.0, 30.0, 40.0 },
        sourceParameters(),
    );

    try std.testing.expectApproxEqAbs(@as(f64, 4.995), offsets[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4.995), offsets[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.665), offsets[2], 1e-15);
    try std.testing.expectEqual(@as(f64, 0.0), offsets[3]);
    try std.testing.expectApproxEqAbs(@as(f64, -0.835), offsets[4], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -2.505), offsets[5], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -2.505), offsets[6], 1e-15);
}

test "runtime parameters control thermal adaptation without fixed constants" {
    var offsets = [_]f64{ 9.0, 9.0, 9.0 };
    try derive(&offsets, &.{ 5.0, 12.0, 25.0 }, .{
        .branch_temperature_c = 12.0,
        .minimum_effective_temperature_c = 2.0,
        .maximum_effective_temperature_c = 22.0,
        .cold_response_c_per_c = 0.4,
        .warm_response_c_per_c = 0.2,
    });
    for (offsets, [_]f64{ 2.8, 0.0, -2.0 }) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-15);
    }
}

test "late nonfinite temperature preserves every offset" {
    var offsets = [_]f64{ 7.0, 8.0 };
    const before = offsets;
    try std.testing.expectError(
        error.NonFiniteMeanAnnualSoilTemperature,
        derive(
            &offsets,
            &.{ 10.0, std.math.nan(f64) },
            sourceParameters(),
        ),
    );
    try std.testing.expectEqualSlices(f64, &before, &offsets);
}

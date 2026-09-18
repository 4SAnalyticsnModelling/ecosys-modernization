//! Persistent per-cell canopy/ground atmospheric carrier.
//!
//! Source order matters. `hour1.f:2443-2449` converts the *carried* TKQ and
//! CO2Q/CH4Q/OXYQ before the current hour's processes run. After those
//! processes, `hour1.f:4791-4796` and `redist.f:4373-4377,10991-11002`
//! publish the TKQ and gas mixing ratios consumed by the following hour.

const std = @import("std");
const mass_concentration = @import("atmospheric_gas_mass_concentration.zig");
const bulk_air = @import("../redistribution/canopy/bulk_air_temperature_vapor.zig");
const gas_closeout = @import("../redistribution/canopy/gas_closeout.zig");
const gas = @import("../soil/gas/transport.zig");

pub const persisted_field_count: usize = 9;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    persisted_storage: []f64,
    bulk_temperature_k: []f64, // TKQ
    bulk_vapor_m3_per_m3: []f64, // VPQ
    canopy_co2_umol_mol: []f64, // CO2Q
    canopy_ch4_umol_mol: []f64, // CH4Q
    canopy_o2_umol_mol: []f64, // OXYQ
    canopy_oxygen_content_g_o: []f64, // OXYC
    cumulative_co2_exchange_g_c: []f64, // ZCNET
    cumulative_ch4_exchange_g_c: []f64, // ZHNET
    cumulative_o2_exchange_g_o: []f64, // ZONET
    /// Derived at the beginning of each hour, cell-major `gas.Species` order.
    mass_concentration_g_per_m3: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        initial_temperature_k: []const f64,
        initial_vapor_m3_per_m3: []const f64,
        initial_mixing_ratios: []const mass_concentration.MixingRatios,
    ) !State {
        const cells = initial_temperature_k.len;
        if (cells == 0 or initial_vapor_m3_per_m3.len != cells or
            initial_mixing_ratios.len != cells)
            return error.CanopyGasCarrierDimensionMismatch;
        const storage = try allocator.alloc(
            f64,
            try std.math.mul(usize, cells, persisted_field_count),
        );
        errdefer allocator.free(storage);
        var result: State = .{
            .allocator = allocator,
            .cell_count = cells,
            .persisted_storage = storage,
            .bulk_temperature_k = storage[0 * cells ..][0..cells],
            .bulk_vapor_m3_per_m3 = storage[1 * cells ..][0..cells],
            .canopy_co2_umol_mol = storage[2 * cells ..][0..cells],
            .canopy_ch4_umol_mol = storage[3 * cells ..][0..cells],
            .canopy_o2_umol_mol = storage[4 * cells ..][0..cells],
            .canopy_oxygen_content_g_o = storage[5 * cells ..][0..cells],
            .cumulative_co2_exchange_g_c = storage[6 * cells ..][0..cells],
            .cumulative_ch4_exchange_g_c = storage[7 * cells ..][0..cells],
            .cumulative_o2_exchange_g_o = storage[8 * cells ..][0..cells],
            .mass_concentration_g_per_m3 = undefined,
        };
        result.mass_concentration_g_per_m3 = try allocator.alloc(
            f64,
            try std.math.mul(usize, cells, gas.species_count),
        );
        errdefer allocator.free(result.mass_concentration_g_per_m3);
        @memcpy(result.bulk_temperature_k, initial_temperature_k);
        @memcpy(result.bulk_vapor_m3_per_m3, initial_vapor_m3_per_m3);
        @memset(result.canopy_oxygen_content_g_o, 0);
        @memset(result.cumulative_co2_exchange_g_c, 0);
        @memset(result.cumulative_ch4_exchange_g_c, 0);
        @memset(result.cumulative_o2_exchange_g_o, 0);
        for (initial_mixing_ratios, 0..) |initial_ratios, cell| {
            result.canopy_co2_umol_mol[cell] = initial_ratios.carbon_dioxide_umol_mol;
            result.canopy_ch4_umol_mol[cell] = initial_ratios.methane_umol_mol;
            result.canopy_o2_umol_mol[cell] = initial_ratios.oxygen_umol_mol;
        }
        try result.validate();
        try result.refreshMassConcentrations(initial_mixing_ratios);
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.mass_concentration_g_per_m3);
        self.allocator.free(self.persisted_storage);
        self.* = undefined;
    }

    pub fn validate(self: *const State) !void {
        if (self.cell_count == 0 or self.mass_concentration_g_per_m3.len !=
            self.cell_count * gas.species_count)
            return error.CanopyGasCarrierDimensionMismatch;
        inline for (persistedConstFields(self)) |values| {
            if (values.len != self.cell_count)
                return error.CanopyGasCarrierDimensionMismatch;
            for (values) |value| if (!std.math.isFinite(value))
                return error.NonFiniteCanopyGasCarrier;
        }
        for (0..self.cell_count) |cell| {
            if (self.bulk_temperature_k[cell] <= 0 or
                self.bulk_vapor_m3_per_m3[cell] < 0 or
                self.canopy_co2_umol_mol[cell] < 0 or
                self.canopy_ch4_umol_mol[cell] < 0 or
                self.canopy_o2_umol_mol[cell] < 0 or
                self.canopy_oxygen_content_g_o[cell] < 0)
                return error.InvalidCanopyGasCarrier;
        }
    }

    /// HOUR1 2443-2449. Uses prior-hour carried TKQ/CO2Q/CH4Q/OXYQ and
    /// publishes all cells only after every conversion succeeds.
    pub fn refreshMassConcentrations(
        self: *State,
        atmospheric_background: []const mass_concentration.MixingRatios,
    ) !void {
        if (atmospheric_background.len != self.cell_count)
            return error.CanopyGasCarrierDimensionMismatch;
        const candidate = try self.allocator.alloc(f64, self.mass_concentration_g_per_m3.len);
        defer self.allocator.free(candidate);
        for (atmospheric_background, 0..) |background, cell| {
            var carried = background;
            carried.carbon_dioxide_umol_mol = self.canopy_co2_umol_mol[cell];
            carried.methane_umol_mol = self.canopy_ch4_umol_mol[cell];
            carried.oxygen_umol_mol = self.canopy_o2_umol_mol[cell];
            const converted = try mass_concentration.convert(
                carried,
                self.bulk_temperature_k[cell],
            );
            const first = cell * gas.species_count;
            candidate[first + @intFromEnum(gas.Species.carbon_dioxide)] = converted.carbon_dioxide_g_m3;
            candidate[first + @intFromEnum(gas.Species.methane)] = converted.methane_g_m3;
            candidate[first + @intFromEnum(gas.Species.oxygen)] = converted.oxygen_g_m3;
            candidate[first + @intFromEnum(gas.Species.nitrogen)] = converted.nitrogen_g_m3;
            candidate[first + @intFromEnum(gas.Species.nitrous_oxide)] = converted.nitrous_oxide_g_m3;
            candidate[first + @intFromEnum(gas.Species.ammonia)] = converted.ammonia_g_m3;
            candidate[first + @intFromEnum(gas.Species.hydrogen)] = converted.hydrogen_g_m3;
        }
        @memcpy(self.mass_concentration_g_per_m3, candidate);
    }

    pub fn concentrationsForCell(self: *const State, cell: usize) ![]const f64 {
        if (cell >= self.cell_count) return error.CanopyGasCarrierCellOutOfBounds;
        return self.mass_concentration_g_per_m3[cell * gas.species_count ..][0..gas.species_count];
    }

    /// DAY 89--91 resets ZCNET/ZHNET/ZONET after the completed day's output.
    /// The next-hour physical carrier remains intact.
    pub fn resetDailyExchange(self: *State) void {
        @memset(self.cumulative_co2_exchange_g_c, 0);
        @memset(self.cumulative_ch4_exchange_g_c, 0);
        @memset(self.cumulative_o2_exchange_g_o, 0);
    }

    pub const CloseoutInputs = struct {
        plants_per_cell: usize,
        living_radiation_fraction: []const f64, // FRADP
        standing_dead_radiation_fraction: []const f64, // FRADQ
        living_air_temperature_k: []const f64, // TKQC
        standing_dead_air_temperature_k: []const f64, // TKQD
        living_air_vapor_pressure_kpa: []const f64, // VPQC carrier in production
        standing_dead_air_vapor_pressure_kpa: []const f64, // VPQD carrier
        vapor_fraction_conversion_k_per_kpa: f64,
        ground_temperature_k: []const f64, // TKQGX
        ground_vapor_m3_per_m3: []const f64, // VPQGX
        ground_radiation_fraction: []const f64, // FRADG
        atmospheric_background: []const mass_concentration.MixingRatios,
        cell_area_m2: []const f64,
        aerodynamic_resistance_h_m: []const f64, // RAB
        canopy_height_m: []const f64, // ZT
        co2_net_input_g_c_step: []const f64, // XCNET
        ch4_net_input_g_c_step: []const f64, // XHNET
        o2_net_input_g_o_step: []const f64, // XONET
        timestep_h: f64,
    };

    /// HOUR1 4791-4796 + REDIST 4373-4377,10991-11002. The complete next-hour
    /// carrier is staged, including cumulative ledgers, before any live field
    /// is changed.
    pub fn closeAcceptedHour(self: *State, inputs: CloseoutInputs) !void {
        try validateCloseoutDimensions(self.*, inputs);
        if (!std.math.isFinite(inputs.timestep_h) or inputs.timestep_h <= 0 or
            !std.math.isFinite(inputs.vapor_fraction_conversion_k_per_kpa) or
            inputs.vapor_fraction_conversion_k_per_kpa <= 0)
            return error.InvalidCanopyGasCarrierCloseout;

        var candidates: [persisted_field_count][]f64 = undefined;
        var allocated: usize = 0;
        defer for (candidates[0..allocated]) |values| self.allocator.free(values);
        inline for (&candidates, persistedConstFields(self)) |*candidate, source| {
            candidate.* = try self.allocator.dupe(f64, source);
            allocated += 1;
        }
        const candidate_bulk_temperature = candidates[0];
        const candidate_bulk_vapor = candidates[1];
        const candidate_co2 = candidates[2];
        const candidate_ch4 = candidates[3];
        const candidate_o2 = candidates[4];
        const candidate_oxygen_content = candidates[5];
        const candidate_cumulative_co2 = candidates[6];
        const candidate_cumulative_ch4 = candidates[7];
        const candidate_cumulative_o2 = candidates[8];

        const ambient_co2 = try self.allocator.alloc(f64, self.cell_count);
        defer self.allocator.free(ambient_co2);
        const ambient_ch4 = try self.allocator.alloc(f64, self.cell_count);
        defer self.allocator.free(ambient_ch4);
        const ambient_o2 = try self.allocator.alloc(f64, self.cell_count);
        defer self.allocator.free(ambient_o2);
        const timestep = try self.allocator.alloc(f64, self.cell_count);
        defer self.allocator.free(timestep);

        for (0..self.cell_count) |cell| {
            var weighted_temperature: f64 = 0;
            var weighted_vapor: f64 = 0;
            var canopy_fraction: f64 = 0;
            for (0..inputs.plants_per_cell) |species| {
                const plant = cell * inputs.plants_per_cell + species;
                const live = inputs.living_radiation_fraction[plant];
                const dead = inputs.standing_dead_radiation_fraction[plant];
                inline for (.{ live, dead }) |fraction| if (!std.math.isFinite(fraction) or fraction < 0)
                    return error.InvalidCanopyGasCarrierCloseout;
                const live_temperature = inputs.living_air_temperature_k[plant];
                const dead_temperature = inputs.standing_dead_air_temperature_k[plant];
                const live_pressure = inputs.living_air_vapor_pressure_kpa[plant];
                const dead_pressure = inputs.standing_dead_air_vapor_pressure_kpa[plant];
                inline for (.{ live_temperature, dead_temperature, live_pressure, dead_pressure }) |value|
                    if (!std.math.isFinite(value)) return error.InvalidCanopyGasCarrierCloseout;
                if (live_temperature <= 0 or dead_temperature <= 0 or live_pressure < 0 or dead_pressure < 0)
                    return error.InvalidCanopyGasCarrierCloseout;
                weighted_temperature += live_temperature * live + dead_temperature * dead;
                weighted_vapor += live_pressure * inputs.vapor_fraction_conversion_k_per_kpa / live_temperature * live +
                    dead_pressure * inputs.vapor_fraction_conversion_k_per_kpa / dead_temperature * dead;
                canopy_fraction += live + dead;
            }
            const ground_fraction = inputs.ground_radiation_fraction[cell];
            if (!std.math.isFinite(canopy_fraction) or !std.math.isFinite(ground_fraction) or
                canopy_fraction < 0 or canopy_fraction > 1.0 + 1.0e-10 or
                ground_fraction < 0 or ground_fraction > 1.0 or
                @abs(canopy_fraction + ground_fraction - 1.0) > 1.0e-10)
                return error.InvalidCanopyGasRadiationClosure;
            const canopy_temperature = if (canopy_fraction > 0)
                weighted_temperature / canopy_fraction
            else
                inputs.ground_temperature_k[cell];
            const canopy_vapor = if (canopy_fraction > 0)
                weighted_vapor / canopy_fraction
            else
                inputs.ground_vapor_m3_per_m3[cell];
            const blended = try bulk_air.blend(.{
                .ground_temperature_k = inputs.ground_temperature_k[cell],
                .canopy_temperature_k = canopy_temperature,
                .ground_vapor_m3_per_m3 = inputs.ground_vapor_m3_per_m3[cell],
                .canopy_vapor_m3_per_m3 = canopy_vapor,
                .ground_radiation_fraction = ground_fraction,
            });
            candidate_bulk_temperature[cell] = blended.bulk_temperature_k;
            candidate_bulk_vapor[cell] = blended.bulk_vapor_m3_per_m3;
            ambient_co2[cell] = inputs.atmospheric_background[cell].carbon_dioxide_umol_mol;
            ambient_ch4[cell] = inputs.atmospheric_background[cell].methane_umol_mol;
            ambient_o2[cell] = inputs.atmospheric_background[cell].oxygen_umol_mol;
            timestep[cell] = inputs.timestep_h;
        }

        const closeout_inputs: gas_closeout.Inputs = .{
            .cell_area_m2 = inputs.cell_area_m2,
            .canopy_air_temperature_k = candidate_bulk_temperature,
            .atmosphere_co2_umol_mol = ambient_co2,
            .atmosphere_ch4_umol_mol = ambient_ch4,
            .atmosphere_o2_umol_mol = ambient_o2,
            .aerodynamic_resistance_h_m = inputs.aerodynamic_resistance_h_m,
            .timestep_h = timestep,
            .canopy_height_m = inputs.canopy_height_m,
            .co2_net_input_g_c_step = inputs.co2_net_input_g_c_step,
            .ch4_net_input_g_c_step = inputs.ch4_net_input_g_c_step,
            .o2_net_input_g_o_step = inputs.o2_net_input_g_o_step,
        };
        const closeout_state: gas_closeout.State = .{
            .canopy_co2_umol_mol = candidate_co2,
            .canopy_ch4_umol_mol = candidate_ch4,
            .canopy_o2_umol_mol = candidate_o2,
            .canopy_oxygen_content_g_o = candidate_oxygen_content,
            .cumulative_co2_exchange_g_c = candidate_cumulative_co2,
            .cumulative_ch4_exchange_g_c = candidate_cumulative_ch4,
            .cumulative_o2_exchange_g_o = candidate_cumulative_o2,
        };
        for (0..self.cell_count) |cell| _ = try gas_closeout.closeCell(cell, closeout_inputs, closeout_state);

        inline for (persistedFields(self), candidates) |target, candidate| @memcpy(target, candidate);
    }
};

pub fn persistedConstFields(state: *const State) [persisted_field_count][]const f64 {
    return .{
        state.bulk_temperature_k,
        state.bulk_vapor_m3_per_m3,
        state.canopy_co2_umol_mol,
        state.canopy_ch4_umol_mol,
        state.canopy_o2_umol_mol,
        state.canopy_oxygen_content_g_o,
        state.cumulative_co2_exchange_g_c,
        state.cumulative_ch4_exchange_g_c,
        state.cumulative_o2_exchange_g_o,
    };
}

pub fn persistedFields(state: *State) [persisted_field_count][]f64 {
    return .{
        state.bulk_temperature_k,
        state.bulk_vapor_m3_per_m3,
        state.canopy_co2_umol_mol,
        state.canopy_ch4_umol_mol,
        state.canopy_o2_umol_mol,
        state.canopy_oxygen_content_g_o,
        state.cumulative_co2_exchange_g_c,
        state.cumulative_ch4_exchange_g_c,
        state.cumulative_o2_exchange_g_o,
    };
}

fn validateCloseoutDimensions(state: State, inputs: State.CloseoutInputs) !void {
    const cells = state.cell_count;
    const plants = std.math.mul(usize, cells, inputs.plants_per_cell) catch
        return error.CanopyGasCarrierDimensionMismatch;
    if (inputs.atmospheric_background.len != cells)
        return error.CanopyGasCarrierDimensionMismatch;
    inline for (.{
        inputs.living_radiation_fraction.len,
        inputs.standing_dead_radiation_fraction.len,
        inputs.living_air_temperature_k.len,
        inputs.standing_dead_air_temperature_k.len,
        inputs.living_air_vapor_pressure_kpa.len,
        inputs.standing_dead_air_vapor_pressure_kpa.len,
    }) |length| if (length != plants) return error.CanopyGasCarrierDimensionMismatch;
    inline for (.{
        inputs.ground_temperature_k.len,
        inputs.ground_vapor_m3_per_m3.len,
        inputs.ground_radiation_fraction.len,
        inputs.cell_area_m2.len,
        inputs.aerodynamic_resistance_h_m.len,
        inputs.canopy_height_m.len,
        inputs.co2_net_input_g_c_step.len,
        inputs.ch4_net_input_g_c_step.len,
        inputs.o2_net_input_g_o_step.len,
    }) |length| if (length != cells) return error.CanopyGasCarrierDimensionMismatch;
}

fn ratios(co2: f64) mass_concentration.MixingRatios {
    return .{
        .carbon_dioxide_umol_mol = co2,
        .methane_umol_mol = 2,
        .oxygen_umol_mol = 210_000,
        .nitrogen_umol_mol = 780_000,
        .nitrous_oxide_umol_mol = 0.33,
        .ammonia_umol_mol = 0.02,
        .hydrogen_umol_mol = 0.001,
    };
}

test "DAY resets only canopy exchange diagnostics and preserves next-hour carrier" {
    var state = try State.init(std.testing.allocator, &.{290}, &.{0.01}, &.{ratios(410)});
    defer state.deinit();
    state.canopy_oxygen_content_g_o[0] = 7;
    state.cumulative_co2_exchange_g_c[0] = 1;
    state.cumulative_ch4_exchange_g_c[0] = 2;
    state.cumulative_o2_exchange_g_o[0] = 3;
    state.resetDailyExchange();
    try std.testing.expectEqual(@as(f64, 0), state.cumulative_co2_exchange_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0), state.cumulative_ch4_exchange_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0), state.cumulative_o2_exchange_g_o[0]);
    try std.testing.expectEqual(@as(f64, 290), state.bulk_temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 410), state.canopy_co2_umol_mol[0]);
    try std.testing.expectEqual(@as(f64, 7), state.canopy_oxygen_content_g_o[0]);
}

test "HOUR1 carrier is per-cell and applies prior TKQ before current closeout" {
    var state = try State.init(std.testing.allocator, &.{ 273.15, 303.15 }, &.{ 0.01, 0.02 }, &.{ ratios(400), ratios(410) });
    defer state.deinit();
    const first_before = (try state.concentrationsForCell(0))[@intFromEnum(gas.Species.carbon_dioxide)];
    const second_before = (try state.concentrationsForCell(1))[@intFromEnum(gas.Species.carbon_dioxide)];
    try std.testing.expect(first_before > second_before);
    const old_mass = try std.testing.allocator.dupe(f64, state.mass_concentration_g_per_m3);
    defer std.testing.allocator.free(old_mass);
    try state.closeAcceptedHour(.{
        .plants_per_cell = 1,
        .living_radiation_fraction = &.{ 0.5, 0.25 },
        .standing_dead_radiation_fraction = &.{ 0.0, 0.25 },
        .living_air_temperature_k = &.{ 290, 300 },
        .standing_dead_air_temperature_k = &.{ 285, 280 },
        .living_air_vapor_pressure_kpa = &.{ 1.0, 1.2 },
        .standing_dead_air_vapor_pressure_kpa = &.{ 0.8, 0.6 },
        .vapor_fraction_conversion_k_per_kpa = 100,
        .ground_temperature_k = &.{ 280, 290 },
        .ground_vapor_m3_per_m3 = &.{ 0.01, 0.02 },
        .ground_radiation_fraction = &.{ 0.5, 0.5 },
        .atmospheric_background = &.{ ratios(420), ratios(430) },
        .cell_area_m2 = &.{ 10, 20 },
        .aerodynamic_resistance_h_m = &.{ 0, 0 },
        .canopy_height_m = &.{ 2, 3 },
        .co2_net_input_g_c_step = &.{ 0, 0 },
        .ch4_net_input_g_c_step = &.{ 0, 0 },
        .o2_net_input_g_o_step = &.{ 0, 0 },
        .timestep_h = 1,
    });
    // Closeout publishes only next-hour carried state, not the active carrier.
    try std.testing.expectEqualSlices(f64, old_mass, state.mass_concentration_g_per_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 285), state.bulk_temperature_k[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 290), state.bulk_temperature_k[1], 1e-12);
    try state.refreshMassConcentrations(&.{ ratios(420), ratios(430) });
    try std.testing.expect((try state.concentrationsForCell(0))[0] != first_before);
    try std.testing.expect((try state.concentrationsForCell(1))[0] != second_before);
}

test "bare ground closeout and late-cell failure are atomic" {
    var state = try State.init(std.testing.allocator, &.{ 280, 281 }, &.{ 0.01, 0.02 }, &.{ ratios(400), ratios(410) });
    defer state.deinit();
    const before = state.bulk_temperature_k[0];
    try std.testing.expectError(error.InvalidCanopyGasRadiationClosure, state.closeAcceptedHour(.{
        .plants_per_cell = 1,
        .living_radiation_fraction = &.{ 0, 0.6 },
        .standing_dead_radiation_fraction = &.{ 0, 0 },
        .living_air_temperature_k = &.{ 290, 300 },
        .standing_dead_air_temperature_k = &.{ 290, 300 },
        .living_air_vapor_pressure_kpa = &.{ 1, 1 },
        .standing_dead_air_vapor_pressure_kpa = &.{ 1, 1 },
        .vapor_fraction_conversion_k_per_kpa = 100,
        .ground_temperature_k = &.{ 285, 286 },
        .ground_vapor_m3_per_m3 = &.{ 0.02, 0.02 },
        .ground_radiation_fraction = &.{ 1, 0.5 },
        .atmospheric_background = &.{ ratios(400), ratios(410) },
        .cell_area_m2 = &.{ 1, 1 },
        .aerodynamic_resistance_h_m = &.{ 0, 0 },
        .canopy_height_m = &.{ 0, 0 },
        .co2_net_input_g_c_step = &.{ 0, 0 },
        .ch4_net_input_g_c_step = &.{ 0, 0 },
        .o2_net_input_g_o_step = &.{ 0, 0 },
        .timestep_h = 1,
    }));
    try std.testing.expectEqual(before, state.bulk_temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 400), state.canopy_co2_umol_mol[0]);
}

const std = @import("std");
const snow = @import("../soil/solute/snow_solute_transport.zig");

/// Runtime-sized accepted precipitation and irrigation chemistry before it
/// branches into snow, litter, non-band soil, and band soil destinations.
/// Values retain each carrier's tracked-element grams.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    daily_input_g: []f64,
    daily_salt_input_mol: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.EmptyAtmosphericSoluteInputGrid;
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, cell_count, snow.species_count),
        );
        errdefer allocator.free(values);
        const salt_values = try allocator.alloc(
            f64,
            try std.math.mul(usize, cell_count, snow.salt_species_count),
        );
        @memset(values, 0);
        @memset(salt_values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .daily_input_g = values,
            .daily_salt_input_mol = salt_values,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.daily_salt_input_mol);
        self.allocator.free(self.daily_input_g);
        self.* = undefined;
    }

    pub fn resetDaily(self: *State) void {
        @memset(self.daily_input_g, 0);
        @memset(self.daily_salt_input_mol, 0);
    }

    /// Adds one fully assembled hour atomically. `snow_input_g` is the branch
    /// retained by snow; `direct_input` holds the mutually exclusive branch
    /// routed directly to litter and topsoil.
    pub fn accumulateAcceptedHour(
        self: *State,
        snow_input_g: []const f64,
        snow_input_salt_mol: []const f64,
        direct_input: []const snow.SurfaceDischarge,
    ) !void {
        if (snow_input_g.len != self.daily_input_g.len or
            snow_input_salt_mol.len != self.daily_salt_input_mol.len or
            direct_input.len != self.cell_count)
            return error.AtmosphericSoluteInputDimensionMismatch;

        for (0..self.cell_count) |cell| {
            const first = cell * snow.species_count;
            for (0..snow.species_count) |species| {
                const direct = direct_input[cell];
                const increment =
                    snow_input_g[first + species] +
                    direct.litter_g[species] +
                    direct.soil_nonband_g[species] +
                    direct.soil_band_g[species];
                const next = self.daily_input_g[first + species] + increment;
                if (!std.math.isFinite(increment) or increment < 0)
                    return error.InvalidAtmosphericSoluteInput;
                if (!std.math.isFinite(next))
                    return error.AtmosphericSoluteInputOverflow;
            }
            const salt_first = cell * snow.salt_species_count;
            for (0..snow.salt_species_count) |species| {
                const direct = direct_input[cell];
                const increment = snow_input_salt_mol[salt_first + species] +
                    direct.litter_salt_mol[species] +
                    direct.soil_nonband_salt_mol[species] +
                    direct.soil_band_salt_mol[species];
                const next = self.daily_salt_input_mol[salt_first + species] + increment;
                if (!std.math.isFinite(increment) or increment < 0)
                    return error.InvalidAtmosphericSoluteInput;
                if (!std.math.isFinite(next)) return error.AtmosphericSoluteInputOverflow;
            }
        }
        for (0..self.cell_count) |cell| {
            const first = cell * snow.species_count;
            for (0..snow.species_count) |species| {
                const direct = direct_input[cell];
                self.daily_input_g[first + species] +=
                    snow_input_g[first + species] +
                    direct.litter_g[species] +
                    direct.soil_nonband_g[species] +
                    direct.soil_band_g[species];
            }
            const salt_first = cell * snow.salt_species_count;
            for (0..snow.salt_species_count) |species| {
                const direct = direct_input[cell];
                self.daily_salt_input_mol[salt_first + species] +=
                    snow_input_salt_mol[salt_first + species] +
                    direct.litter_salt_mol[species] +
                    direct.soil_nonband_salt_mol[species] +
                    direct.soil_band_salt_mol[species];
            }
        }
    }

    pub fn speciesInputG(
        self: State,
        cell: usize,
        species: snow.Species,
    ) !f64 {
        if (cell >= self.cell_count)
            return error.AtmosphericSoluteInputCellOutOfBounds;
        return self.daily_input_g[
            cell * snow.species_count + @intFromEnum(species)
        ];
    }
};

test "accepted atmospheric input recombines snow litter and both soil zones" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    var snow_input = [_]f64{0} ** (2 * snow.species_count);
    var direct = [_]snow.SurfaceDischarge{ .{}, .{} };
    const species = @intFromEnum(snow.Species.ammonium_nitrogen);
    snow_input[species] = 1;
    direct[0].litter_g[species] = 2;
    direct[0].soil_nonband_g[species] = 3;
    direct[0].soil_band_g[species] = 4;
    direct[1].soil_band_g[species] = 5;
    var snow_salt_input = [_]f64{0} ** (2 * snow.salt_species_count);
    snow_salt_input[@intFromEnum(snow.SaltSpecies.calcium_sulfate)] = 6;
    direct[0].litter_salt_mol[@intFromEnum(snow.SaltSpecies.calcium_sulfate)] = 7;
    direct[0].soil_nonband_salt_mol[@intFromEnum(snow.SaltSpecies.calcium_sulfate)] = 8;
    direct[0].soil_band_salt_mol[@intFromEnum(snow.SaltSpecies.calcium_sulfate)] = 9;
    try state.accumulateAcceptedHour(&snow_input, &snow_salt_input, &direct);
    try std.testing.expectEqual(
        @as(f64, 10),
        try state.speciesInputG(0, .ammonium_nitrogen),
    );
    try std.testing.expectEqual(
        @as(f64, 5),
        try state.speciesInputG(1, .ammonium_nitrogen),
    );
    try std.testing.expectEqual(@as(f64, 30), state.daily_salt_input_mol[@intFromEnum(snow.SaltSpecies.calcium_sulfate)]);
}

test "invalid late atmospheric carrier leaves the daily ledger unchanged" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.daily_input_g[0] = 7;
    var snow_input = [_]f64{0} ** (2 * snow.species_count);
    snow_input[snow.species_count + 3] = std.math.nan(f64);
    const direct = [_]snow.SurfaceDischarge{ .{}, .{} };
    try std.testing.expectError(
        error.InvalidAtmosphericSoluteInput,
        state.accumulateAcceptedHour(&snow_input, &([_]f64{0} ** (2 * snow.salt_species_count)), &direct),
    );
    try std.testing.expectEqual(@as(f64, 7), state.daily_input_g[0]);
}

test "invalid late dynamic salt leaves both atmospheric ledgers unchanged" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.daily_input_g[0] = 7;
    state.daily_salt_input_mol[0] = 11;
    const snow_input = [_]f64{0} ** (2 * snow.species_count);
    var snow_salt_input = [_]f64{0} ** (2 * snow.salt_species_count);
    snow_salt_input[snow_salt_input.len - 1] = std.math.nan(f64);
    const direct = [_]snow.SurfaceDischarge{ .{}, .{} };
    try std.testing.expectError(
        error.InvalidAtmosphericSoluteInput,
        state.accumulateAcceptedHour(&snow_input, &snow_salt_input, &direct),
    );
    try std.testing.expectEqual(@as(f64, 7), state.daily_input_g[0]);
    try std.testing.expectEqual(@as(f64, 11), state.daily_salt_input_mol[0]);
}

test "production binds exact WATSUB atmospheric chemistry routing once before accepted publication" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_process_driver.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "surface_precipitation.routePrecipitationSolutes("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "surface_precipitation.preRedistributionLitterWaterM3PerH("),
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "partitionAcceptedDirectLiquid(") == null);
    const route = std.mem.indexOf(u8, source, "surface_precipitation.routePrecipitationSolutes(") orelse
        return error.MissingAtmosphericSoluteRouteBinding;
    const chemistry = std.mem.indexOfPos(u8, source, route, "snow_solute_transport.atmosphericInputG(") orelse
        return error.MissingAtmosphericSoluteChemistryBinding;
    const solve = std.mem.indexOfPos(u8, source, chemistry, "solveSnowSurfaceEnergyAndSoilTransport(") orelse
        return error.MissingAcceptedAtmosphericSolve;
    const publish = std.mem.indexOfPos(u8, source, solve, "atmospheric_solute_input_ledger.accumulateAcceptedHour(") orelse
        return error.MissingAcceptedAtmosphericPublication;
    try std.testing.expect(route < chemistry and chemistry < solve and solve < publish);
}

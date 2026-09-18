const std = @import("std");
const atmosphere = @import("../soil/gas/atmosphere_exchange.zig");
const solver = @import("../soil/gas/coupled_gas_solver.zig");
const snapshot = @import("coupled_gas_failure_snapshot.zig");
const gas = @import("../soil/gas/transport.zig");

pub const Options = struct {
    write_buffer_bytes: usize = 64 * 1024,
    replace_existing: bool = true,
};

/// Destination and I/O ownership supplied by the outer-hour transaction.
/// Both soil and surface-litter wrappers use this common request so every
/// production caller of the coupled solver can publish an identical replay.
pub const Request = struct {
    io: std.Io,
    directory: std.Io.Dir,
    file_path: []const u8,
    options: Options = .{},
};

/// Maps live solver input into the immutable diagnostic schema. Accepted-flux
/// ledgers are intentionally omitted because a failure has no accepted state_update.
/// Everything the residual reads is carried, including the REDIST bubble
/// receiver map: it selects where released gas lands, so dropping it would
/// make a replay solve a different system than the one that failed.
pub fn inputView(inputs: solver.Inputs) snapshot.InputView {
    return .{
        .faces = inputs.faces,
        .face_conductance_m3_per_step = inputs.face_conductance_m3_per_step,
        .atmospheric_boundaries = inputs.atmospheric_boundaries,
        .subsurface_boundaries = inputs.subsurface_boundaries,
        .water_volume_m3 = inputs.water_volume_m3,
        .band_water_volume_m3 = inputs.band_water_volume_m3,
        .nonband_air_volume_m3 = inputs.nonband_air_volume_m3,
        .band_air_volume_m3 = inputs.band_air_volume_m3,
        .mass_solubility_ratio = inputs.mass_solubility_ratio,
        .gas_water_exchange_rate_per_step = inputs.gas_water_exchange_rate_per_step,
        .band_gas_water_exchange_rate_per_step = inputs.band_gas_water_exchange_rate_per_step,
        .bubbling_enabled = inputs.bubbling_enabled,
        .minimum_carrier_volume_m3 = inputs.minimum_carrier_volume_m3,
        .bubble_receiver_cell_by_cell = inputs.bubble_receiver_cell_by_cell,
    };
}

pub fn solverOptions(options: solver.Options) snapshot.SolverOptions {
    return .{
        .absolute_tolerance_g_by_species = options.absolute_tolerance_g_by_species,
        .absolute_tolerance_g = options.absolute_tolerance_g,
        .relative_tolerance = options.relative_tolerance,
        .picard_relaxation = options.picard_relaxation,
        .directional_probe_fraction = options.directional_probe_fraction,
        .minimum_newton_fraction = options.minimum_newton_fraction,
        .maximum_newton_fraction = options.maximum_newton_fraction,
        .divergence_patience = options.divergence_patience,
        .divergence_growth_factor = options.divergence_growth_factor,
        .transport_iteration_fraction = options.transport_iteration_fraction,
        .max_iterations = options.max_iterations,
        .accept_physically_conserved_ceiling = options.accept_physically_conserved_ceiling,
        .krylov_restart_max = options.krylov_restart_max,
        .krylov_relative_tolerance = options.krylov_relative_tolerance,
    };
}

pub fn replayInputs(replay_case: *snapshot.ReplayCase) solver.Inputs {
    const inputs = replay_case.inputs();
    return .{
        .faces = inputs.faces,
        .face_conductance_m3_per_step = inputs.face_conductance_m3_per_step,
        .atmospheric_boundaries = inputs.atmospheric_boundaries,
        .subsurface_boundaries = inputs.subsurface_boundaries,
        .water_volume_m3 = inputs.water_volume_m3,
        .band_water_volume_m3 = inputs.band_water_volume_m3,
        .nonband_air_volume_m3 = inputs.nonband_air_volume_m3,
        .band_air_volume_m3 = inputs.band_air_volume_m3,
        .mass_solubility_ratio = inputs.mass_solubility_ratio,
        .gas_water_exchange_rate_per_step = inputs.gas_water_exchange_rate_per_step,
        .band_gas_water_exchange_rate_per_step = inputs.band_gas_water_exchange_rate_per_step,
        .bubbling_enabled = inputs.bubbling_enabled,
        .minimum_carrier_volume_m3 = inputs.minimum_carrier_volume_m3,
        .bubble_receiver_cell_by_cell = inputs.bubble_receiver_cell_by_cell,
    };
}

pub fn replayOptions(options: snapshot.SolverOptions) solver.Options {
    return .{
        .absolute_tolerance_g_by_species = options.absolute_tolerance_g_by_species,
        .absolute_tolerance_g = options.absolute_tolerance_g,
        .relative_tolerance = options.relative_tolerance,
        .picard_relaxation = options.picard_relaxation,
        .directional_probe_fraction = options.directional_probe_fraction,
        .minimum_newton_fraction = options.minimum_newton_fraction,
        .maximum_newton_fraction = options.maximum_newton_fraction,
        .divergence_patience = options.divergence_patience,
        .divergence_growth_factor = options.divergence_growth_factor,
        .transport_iteration_fraction = options.transport_iteration_fraction,
        .max_iterations = options.max_iterations,
        .accept_physically_conserved_ceiling = options.accept_physically_conserved_ceiling,
        .krylov_restart_max = options.krylov_restart_max,
        .krylov_relative_tolerance = options.krylov_relative_tolerance,
    };
}

/// Captures before opening a file, then publishes through `File.Atomic`.
/// Failed writes leave the previous final file untouched and discard the
/// unnamed sibling temporary file.
pub fn captureAndWrite(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    file_path: []const u8,
    state: *const gas.State,
    inputs: solver.Inputs,
    options: solver.Options,
    reporter_options: Options,
) !void {
    if (file_path.len == 0 or reporter_options.write_buffer_bytes == 0)
        return error.InvalidCoupledGasFailureReportPath;
    var replay_case = try snapshot.capture(
        allocator,
        state,
        inputView(inputs),
        solverOptions(options),
    );
    defer replay_case.deinit();

    const buffer = try allocator.alloc(u8, reporter_options.write_buffer_bytes);
    defer allocator.free(buffer);
    var atomic_file = try directory.createFileAtomic(io, file_path, .{
        .replace = reporter_options.replace_existing,
    });
    defer atomic_file.deinit(io);
    var writer = atomic_file.file.writerStreaming(io, buffer);
    try snapshot.write(allocator, &writer.interface, &replay_case);
    try writer.interface.flush();
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

/// Best-effort diagnostics must never mask the scientific solver failure.
/// The returned error is always exactly `solver_error`.
pub fn reportPreservingSolverError(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    file_path: []const u8,
    state: *const gas.State,
    inputs: solver.Inputs,
    options: solver.Options,
    reporter_options: Options,
    solver_error: anyerror,
) anyerror {
    captureAndWrite(
        allocator,
        io,
        directory,
        file_path,
        state,
        inputs,
        options,
        reporter_options,
    ) catch |reporter_error| {
        std.log.warn(
            "coupled gas failure snapshot could not be published: path={s} reporter_error={s} preserved_solver_error={s}",
            .{ file_path, @errorName(reporter_error), @errorName(solver_error) },
        );
    };
    return solver_error;
}

const TestFixture = struct {
    state: gas.State,
    faces: [1]gas.Face,
    conductance: [gas.species_count]f64,
    boundaries: [1]atmosphere.Boundary,
    water: [2]f64,
    band_water: [2]f64,
    solubility: [2 * gas.species_count]f64,
    exchange: [2 * gas.species_count]f64,
    band_exchange: [2 * gas.species_count]f64,
    bubbling: [2]bool,
    bubble_receivers: [2]?usize,

    fn init(allocator: std.mem.Allocator) !TestFixture {
        var state = try gas.State.init(allocator, 2);
        state.air_volume_m3[0] = 1;
        state.air_volume_m3[1] = 2;
        state.temperature_k[0] = 290;
        state.temperature_k[1] = 291;
        for (state.gaseous_mass_g, 0..) |*value, index|
            value.* = @floatFromInt(index + 1);
        for (state.dissolved_mass_g, 0..) |*value, index|
            value.* = @as(f64, @floatFromInt(index + 1)) / 10;
        return .{
            .state = state,
            .faces = .{.{ .first_cell = 0, .second_cell = 1 }},
            .conductance = [_]f64{0.01} ** gas.species_count,
            .boundaries = .{.{
                .cell_index = 0,
                .aerodynamic_conductance_m3_per_step = 0.1,
                .interior_conductance_m3_per_step = [_]f64{0.2} ** gas.species_count,
                .atmospheric_concentration_g_per_m3 = [_]f64{0.001} ** gas.species_count,
            }},
            .water = .{ 0.3, 0.4 },
            .band_water = .{ 0.01, 0.02 },
            .solubility = [_]f64{0.8} ** (2 * gas.species_count),
            .exchange = [_]f64{0.1} ** (2 * gas.species_count),
            .band_exchange = [_]f64{0.05} ** (2 * gas.species_count),
            .bubbling = .{ true, false },
            .bubble_receivers = .{ 1, null },
        };
    }

    fn deinit(self: *TestFixture) void {
        self.state.deinit();
    }

    fn inputs(self: *TestFixture) solver.Inputs {
        return .{
            .faces = &self.faces,
            .face_conductance_m3_per_step = &self.conductance,
            .atmospheric_boundaries = &self.boundaries,
            .water_volume_m3 = &self.water,
            .band_water_volume_m3 = &self.band_water,
            .mass_solubility_ratio = &self.solubility,
            .gas_water_exchange_rate_per_step = &self.exchange,
            .band_gas_water_exchange_rate_per_step = &self.band_exchange,
            .bubbling_enabled = &self.bubbling,
            .bubble_receiver_cell_by_cell = &self.bubble_receivers,
        };
    }
};

test "reporter publishes an atomic snapshot readable as an owned replay case" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const options: solver.Options = .{
        .absolute_tolerance_g_by_species = .{ 1e-10, 2e-10, 3e-10, 4e-10, 5e-10, 6e-10, 7e-10 },
        .max_iterations = 80,
        .accept_physically_conserved_ceiling = true,
        .krylov_restart_max = 7,
        .krylov_relative_tolerance = 3e-4,
    };
    try captureAndWrite(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "gas-failure.bin",
        &fixture.state,
        fixture.inputs(),
        options,
        .{ .write_buffer_bytes = 31 },
    );
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "gas-failure.bin",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var restored = try snapshot.read(std.testing.allocator, &reader, .{});
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored.state.cell_count);
    try std.testing.expectEqualSlices(
        f64,
        fixture.state.gaseous_mass_g,
        restored.state.gaseous_mass_g,
    );
    try std.testing.expectEqual(options.max_iterations, restored.options.max_iterations);
    const mapped_inputs = replayInputs(&restored);
    try std.testing.expectEqual(@as(usize, 1), mapped_inputs.faces.len);
    // The replay must solve the same system, so the receiver map has to
    // survive capture, serialization, and mapping back into solver inputs.
    try std.testing.expectEqualSlices(
        ?usize,
        &fixture.bubble_receivers,
        mapped_inputs.bubble_receiver_cell_by_cell.?,
    );
    const replayed_options = replayOptions(restored.options);
    try std.testing.expectEqualSlices(
        f64,
        &options.absolute_tolerance_g_by_species,
        &replayed_options.absolute_tolerance_g_by_species,
    );
    try std.testing.expect(std.math.isNan(replayed_options.absolute_tolerance_g));
    try std.testing.expectEqual(options.relative_tolerance, replayed_options.relative_tolerance);
    try std.testing.expectEqual(options.picard_relaxation, replayed_options.picard_relaxation);
    try std.testing.expectEqual(options.directional_probe_fraction, replayed_options.directional_probe_fraction);
    try std.testing.expectEqual(options.minimum_newton_fraction, replayed_options.minimum_newton_fraction);
    try std.testing.expectEqual(options.maximum_newton_fraction, replayed_options.maximum_newton_fraction);
    try std.testing.expectEqual(options.transport_iteration_fraction, replayed_options.transport_iteration_fraction);
    try std.testing.expectEqual(options.max_iterations, replayed_options.max_iterations);
    try std.testing.expectEqual(options.accept_physically_conserved_ceiling, replayed_options.accept_physically_conserved_ceiling);
    try std.testing.expectEqual(options.krylov_restart_max, replayed_options.krylov_restart_max);
    try std.testing.expectEqual(options.krylov_relative_tolerance, replayed_options.krylov_relative_tolerance);
}

test "reporter failure preserves solver error and publishes no partial final file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const inputs = fixture.inputs();
    const preserved = reportPreservingSolverError(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "gas-failure.bin",
        &fixture.state,
        inputs,
        .{ .max_iterations = 80 },
        .{ .write_buffer_bytes = 0 },
        error.CoupledGasSolverDidNotConverge,
    );
    try std.testing.expectEqual(error.CoupledGasSolverDidNotConverge, preserved);
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(std.testing.io, "gas-failure.bin", .{}),
    );
}

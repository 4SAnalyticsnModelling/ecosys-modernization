const std = @import("std");
const atmosphere = @import("../soil/gas/atmosphere_exchange.zig");
const gas = @import("../soil/gas/transport.zig");

const magic = "ECOSGAS!";
/// Version written by `write`. Version 2 adds the REDIST `LL=MIN(L,LG)` bubble
/// receiver map, which version 1 omitted even though the solver residual reads
/// it. Version 1 snapshots are still decodable, because the archived Ottawa
/// captures are the only real production evidence available and discarding them
/// would be worse than reading them. They are instead flagged: a decoded v1
/// case carries `bubble_receiver_map_captured = false`, and any caller that
/// replays one must report that its bubbling destinations were not recorded.
// Version 3 adds the NH3 non-band/band air-zone volumes read by the residual.
// Version 4 preserves the species-typed nonlinear absolute tolerance vector;
// versions 1--3 carried only the now-deprecated homogeneous scalar.
// Version 5 preserves the residual-explosion controls added to the production
// coupled solver. Version 6 preserves the physical-publication policy and
// Krylov restart width. Version 7 preserves the GMRES relative residual target;
// older snapshots replay with the historical Krylov controls.
// Version 8 preserves the per-cell legacy ZEROS2 carrier minimum. Snapshots at
// version 7 or below decode it as empty, which reproduces their own capture-time
// behaviour but is strictly harder than a production run that has the floor, so
// a pre-8 capture is not evidence about a post-8 production failure.
const format_version: u32 = 8;
const minimum_readable_version: u32 = 1;
const checksum_seed: u64 = 0x45434f5347415346;

pub const Limits = struct {
    maximum_payload_bytes: usize = 256 * 1024 * 1024,
    maximum_cells: usize = 10_000_000,
    maximum_faces: usize = 40_000_000,
    maximum_boundaries: usize = 40_000_000,
};

/// Solver controls captured verbatim at failure. Keep this schema explicit so
/// format evolution is independent from the live solver's source layout.
pub const SolverOptions = struct {
    absolute_tolerance_g_by_species: [gas.species_count]f64 = @splat(1e-12),
    absolute_tolerance_g: f64 = std.math.nan(f64),
    relative_tolerance: f64 = 1e-8,
    picard_relaxation: f64 = 0.5,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    maximum_newton_fraction: f64 = 1.0,
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    transport_iteration_fraction: f64 = 1,
    max_iterations: u16,
    accept_physically_conserved_ceiling: bool = false,
    krylov_restart_max: usize = 12,
    krylov_relative_tolerance: f64 = 0.01,
};

pub const InputView = struct {
    faces: []const gas.Face,
    face_conductance_m3_per_step: []const f64,
    atmospheric_boundaries: []const atmosphere.Boundary,
    subsurface_boundaries: []const atmosphere.Boundary,
    water_volume_m3: []const f64,
    band_water_volume_m3: []const f64,
    nonband_air_volume_m3: []const f64 = &.{},
    band_air_volume_m3: []const f64 = &.{},
    mass_solubility_ratio: []const f64,
    gas_water_exchange_rate_per_step: []const f64,
    band_gas_water_exchange_rate_per_step: []const f64,
    bubbling_enabled: []const bool,
    /// Legacy `ZEROS2(NY,NX)` per cell: the carrier volume below which the
    /// oracle performs no gaseous transport and no bubbling
    /// (`ecosys_f77/trnsfr.f:5303-5306`, `:5880-5889`). Empty means the caller
    /// supplied no floor, which is the pre-2026-09-10 behaviour and is what a
    /// snapshot older than format version 8 decodes to. It is a solver-visible
    /// input that changes which faces exist, so it must round-trip: replaying
    /// with an empty floor against a production run that had one makes the
    /// replay strictly harder than production.
    minimum_carrier_volume_m3: []const f64 = &.{},
    /// REDIST bubble destination per cell. `null` for the whole map means the
    /// caller supplied no map and the solver releases into the source cell;
    /// a `null` entry means no gas-phase route exists and the released mass
    /// leaves as a boundary flux. Both are solver-visible inputs and both
    /// must round-trip, so the distinction is preserved on the wire.
    bubble_receiver_cell_by_cell: ?[]const ?usize = null,
};

/// Heap-owned, self-contained input to one coupled gas solve. Diagnostic
/// ledgers are deliberately excluded because they are outputs, not replay
/// inputs. Array ordering is cell-major and follows `gas.Species`.
pub const ReplayCase = struct {
    allocator: std.mem.Allocator,
    state: gas.State,
    faces: []gas.Face,
    face_conductance_m3_per_step: []f64,
    atmospheric_boundaries: []atmosphere.Boundary,
    subsurface_boundaries: []atmosphere.Boundary,
    water_volume_m3: []f64,
    band_water_volume_m3: []f64,
    nonband_air_volume_m3: []f64,
    band_air_volume_m3: []f64,
    mass_solubility_ratio: []f64,
    gas_water_exchange_rate_per_step: []f64,
    band_gas_water_exchange_rate_per_step: []f64,
    bubbling_enabled: []bool,
    /// Empty for a snapshot older than format version 8, whose carrier minimum
    /// was never recorded. Such a replay solves with no floor, which admits
    /// faces production would have skipped, so its result is not evidence about
    /// a failure captured from a run that had the floor.
    minimum_carrier_volume_m3: []f64,
    bubble_receiver_cell_by_cell: ?[]?usize,
    /// False only for a decoded version 1 snapshot, whose bubble receiver map
    /// was never recorded. A replay of such a case solves the solver's default
    /// release-into-source-cell system, which may differ from the system that
    /// failed, so the result is not evidence about that failure's bubbling.
    bubble_receiver_map_captured: bool = true,
    options: SolverOptions,

    pub fn deinit(self: *ReplayCase) void {
        if (self.bubble_receiver_cell_by_cell) |receivers|
            self.allocator.free(receivers);
        self.allocator.free(self.minimum_carrier_volume_m3);
        self.allocator.free(self.bubbling_enabled);
        self.allocator.free(self.band_gas_water_exchange_rate_per_step);
        self.allocator.free(self.gas_water_exchange_rate_per_step);
        self.allocator.free(self.mass_solubility_ratio);
        self.allocator.free(self.band_air_volume_m3);
        self.allocator.free(self.nonband_air_volume_m3);
        self.allocator.free(self.band_water_volume_m3);
        self.allocator.free(self.water_volume_m3);
        self.allocator.free(self.subsurface_boundaries);
        self.allocator.free(self.atmospheric_boundaries);
        self.allocator.free(self.face_conductance_m3_per_step);
        self.allocator.free(self.faces);
        self.state.deinit();
        self.* = undefined;
    }

    pub fn inputs(self: *const ReplayCase) InputView {
        return .{
            .faces = self.faces,
            .face_conductance_m3_per_step = self.face_conductance_m3_per_step,
            .atmospheric_boundaries = self.atmospheric_boundaries,
            .subsurface_boundaries = self.subsurface_boundaries,
            .water_volume_m3 = self.water_volume_m3,
            .band_water_volume_m3 = self.band_water_volume_m3,
            .nonband_air_volume_m3 = self.nonband_air_volume_m3,
            .band_air_volume_m3 = self.band_air_volume_m3,
            .mass_solubility_ratio = self.mass_solubility_ratio,
            .gas_water_exchange_rate_per_step = self.gas_water_exchange_rate_per_step,
            .band_gas_water_exchange_rate_per_step = self.band_gas_water_exchange_rate_per_step,
            .bubbling_enabled = self.bubbling_enabled,
            .minimum_carrier_volume_m3 = self.minimum_carrier_volume_m3,
            .bubble_receiver_cell_by_cell = self.bubble_receiver_cell_by_cell,
        };
    }
};

/// Captures one solver invocation without retaining any caller-owned storage.
/// All dimensions and physical domains are checked before the first allocation;
/// subsequent allocation failures unwind atomically.
pub fn capture(
    allocator: std.mem.Allocator,
    source_state: *const gas.State,
    source_inputs: InputView,
    options: SolverOptions,
) !ReplayCase {
    try validateView(source_state, source_inputs, options, .{});
    var state = try source_state.clone(allocator);
    errdefer state.deinit();
    const faces = try allocator.dupe(gas.Face, source_inputs.faces);
    errdefer allocator.free(faces);
    const face_conductance = try allocator.dupe(
        f64,
        source_inputs.face_conductance_m3_per_step,
    );
    errdefer allocator.free(face_conductance);
    const atmospheric_boundaries = try allocator.dupe(
        atmosphere.Boundary,
        source_inputs.atmospheric_boundaries,
    );
    errdefer allocator.free(atmospheric_boundaries);
    const subsurface_boundaries = try allocator.dupe(
        atmosphere.Boundary,
        source_inputs.subsurface_boundaries,
    );
    errdefer allocator.free(subsurface_boundaries);
    const water = try allocator.dupe(f64, source_inputs.water_volume_m3);
    errdefer allocator.free(water);
    const band_water = try allocator.dupe(f64, source_inputs.band_water_volume_m3);
    errdefer allocator.free(band_water);
    const nonband_air = try allocator.dupe(f64, source_inputs.nonband_air_volume_m3);
    errdefer allocator.free(nonband_air);
    const band_air = try allocator.dupe(f64, source_inputs.band_air_volume_m3);
    errdefer allocator.free(band_air);
    const solubility = try allocator.dupe(f64, source_inputs.mass_solubility_ratio);
    errdefer allocator.free(solubility);
    const exchange = try allocator.dupe(
        f64,
        source_inputs.gas_water_exchange_rate_per_step,
    );
    errdefer allocator.free(exchange);
    const band_exchange = try allocator.dupe(
        f64,
        source_inputs.band_gas_water_exchange_rate_per_step,
    );
    errdefer allocator.free(band_exchange);
    const bubbling = try allocator.dupe(bool, source_inputs.bubbling_enabled);
    errdefer allocator.free(bubbling);
    const carrier_minimum = try allocator.dupe(f64, source_inputs.minimum_carrier_volume_m3);
    errdefer allocator.free(carrier_minimum);
    const receivers: ?[]?usize = if (source_inputs.bubble_receiver_cell_by_cell) |source|
        try allocator.dupe(?usize, source)
    else
        null;
    return .{
        .allocator = allocator,
        .state = state,
        .faces = faces,
        .face_conductance_m3_per_step = face_conductance,
        .atmospheric_boundaries = atmospheric_boundaries,
        .subsurface_boundaries = subsurface_boundaries,
        .water_volume_m3 = water,
        .band_water_volume_m3 = band_water,
        .nonband_air_volume_m3 = nonband_air,
        .band_air_volume_m3 = band_air,
        .mass_solubility_ratio = solubility,
        .gas_water_exchange_rate_per_step = exchange,
        .band_gas_water_exchange_rate_per_step = band_exchange,
        .bubbling_enabled = bubbling,
        .minimum_carrier_volume_m3 = carrier_minimum,
        .bubble_receiver_cell_by_cell = receivers,
        .bubble_receiver_map_captured = true,
        .options = options,
    };
}

pub fn write(allocator: std.mem.Allocator, writer: anytype, replay_case: *const ReplayCase) !void {
    try validate(replay_case.*, .{});
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try writePayload(&payload.writer, replay_case);
    const bytes = payload.written();
    try writer.writeAll(magic);
    try writer.writeInt(u32, format_version, .little);
    try writer.writeInt(u64, @intCast(bytes.len), .little);
    try writer.writeInt(u64, std.hash.Wyhash.hash(checksum_seed, bytes), .little);
    try writer.writeAll(bytes);
}

pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) !ReplayCase {
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic))
        return error.InvalidCoupledGasSnapshotMagic;
    const version = try reader.takeInt(u32, .little);
    if (version < minimum_readable_version or version > format_version)
        return error.UnsupportedCoupledGasSnapshotVersion;
    const payload_length_u64 = try reader.takeInt(u64, .little);
    const expected_checksum = try reader.takeInt(u64, .little);
    const payload_length = std.math.cast(usize, payload_length_u64) orelse
        return error.CoupledGasSnapshotLimitExceeded;
    if (payload_length > limits.maximum_payload_bytes)
        return error.CoupledGasSnapshotLimitExceeded;
    const payload = try allocator.alloc(u8, payload_length);
    defer allocator.free(payload);
    reader.readSliceAll(payload) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedCoupledGasSnapshot,
        else => return err,
    };
    if (std.hash.Wyhash.hash(checksum_seed, payload) != expected_checksum)
        return error.CoupledGasSnapshotChecksumMismatch;
    rejectTrailing(reader) catch |err| return err;
    var payload_reader: std.Io.Reader = .fixed(payload);
    var result = try readPayload(allocator, &payload_reader, limits, version);
    errdefer result.deinit();
    rejectTrailing(&payload_reader) catch
        return error.InvalidCoupledGasSnapshotPayloadLength;
    try validate(result, limits);
    return result;
}

fn writePayload(writer: anytype, replay_case: *const ReplayCase) !void {
    try writer.writeInt(u64, @intCast(replay_case.state.cell_count), .little);
    try writer.writeInt(u64, @intCast(replay_case.faces.len), .little);
    try writer.writeInt(u64, @intCast(replay_case.atmospheric_boundaries.len), .little);
    try writer.writeInt(u64, @intCast(replay_case.subsurface_boundaries.len), .little);
    try writeF64Slice(writer, replay_case.state.air_volume_m3);
    try writeF64Slice(writer, replay_case.state.temperature_k);
    try writeF64Slice(writer, replay_case.state.water_vapor_mol);
    try writeF64Slice(writer, replay_case.state.gaseous_mass_g);
    try writeF64Slice(writer, replay_case.state.dissolved_mass_g);
    try writeF64Slice(writer, replay_case.state.macropore_dissolved_mass_g);
    try writeF64Slice(writer, replay_case.state.band_dissolved_mass_g);
    for (replay_case.faces) |face| {
        try writer.writeInt(u64, @intCast(face.first_cell), .little);
        try writer.writeInt(u64, @intCast(face.second_cell), .little);
    }
    try writeF64Slice(writer, replay_case.face_conductance_m3_per_step);
    try writeBoundaries(writer, replay_case.atmospheric_boundaries);
    try writeBoundaries(writer, replay_case.subsurface_boundaries);
    try writeF64Slice(writer, replay_case.water_volume_m3);
    try writeF64Slice(writer, replay_case.band_water_volume_m3);
    if (replay_case.nonband_air_volume_m3.len == 0) {
        try writer.writeByte(0);
    } else {
        try writer.writeByte(1);
        try writeF64Slice(writer, replay_case.nonband_air_volume_m3);
        try writeF64Slice(writer, replay_case.band_air_volume_m3);
    }
    try writeF64Slice(writer, replay_case.mass_solubility_ratio);
    try writeF64Slice(writer, replay_case.gas_water_exchange_rate_per_step);
    try writeF64Slice(writer, replay_case.band_gas_water_exchange_rate_per_step);
    for (replay_case.bubbling_enabled) |enabled|
        try writer.writeByte(@intFromBool(enabled));
    // One presence byte for the whole map, then one presence byte plus index
    // per cell, so "no map" and "map of all nulls" stay distinguishable.
    if (replay_case.bubble_receiver_cell_by_cell) |receivers| {
        try writer.writeByte(1);
        for (receivers) |receiver| {
            if (receiver) |cell| {
                try writer.writeByte(1);
                try writer.writeInt(u64, @intCast(cell), .little);
            } else {
                try writer.writeByte(0);
            }
        }
    } else {
        try writer.writeByte(0);
    }
    try writeSolverOptions(writer, replay_case.options);
    // Appended last, so a reader for an older version never reaches it. One
    // presence byte keeps "no floor supplied" distinct from a per-cell floor
    // that happens to be all zeros.
    if (replay_case.minimum_carrier_volume_m3.len == 0) {
        try writer.writeByte(0);
    } else {
        try writer.writeByte(1);
        try writeF64Slice(writer, replay_case.minimum_carrier_volume_m3);
    }
}

fn readPayload(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: Limits,
    version: u32,
) !ReplayCase {
    const cell_count = try readCount(reader, limits.maximum_cells);
    const face_count = try readCount(reader, limits.maximum_faces);
    const atmospheric_count = try readCount(reader, limits.maximum_boundaries);
    const subsurface_count = try readCount(reader, limits.maximum_boundaries);
    if (cell_count == 0) return error.InvalidCoupledGasSnapshotDimensions;
    var state = try gas.State.init(allocator, cell_count);
    errdefer state.deinit();
    try readF64Slice(reader, state.air_volume_m3);
    try readF64Slice(reader, state.temperature_k);
    try readF64Slice(reader, state.water_vapor_mol);
    try readF64Slice(reader, state.gaseous_mass_g);
    try readF64Slice(reader, state.dissolved_mass_g);
    try readF64Slice(reader, state.macropore_dissolved_mass_g);
    try readF64Slice(reader, state.band_dissolved_mass_g);

    const faces = try allocator.alloc(gas.Face, face_count);
    errdefer allocator.free(faces);
    for (faces) |*face| face.* = .{
        .first_cell = try readIndex(reader),
        .second_cell = try readIndex(reader),
    };
    const conductance_count = try std.math.mul(usize, face_count, gas.species_count);
    const face_conductance = try allocF64(allocator, reader, conductance_count);
    errdefer allocator.free(face_conductance);
    const atmospheric_boundaries = try readBoundaries(allocator, reader, atmospheric_count);
    errdefer allocator.free(atmospheric_boundaries);
    const subsurface_boundaries = try readBoundaries(allocator, reader, subsurface_count);
    errdefer allocator.free(subsurface_boundaries);
    const water = try allocF64(allocator, reader, cell_count);
    errdefer allocator.free(water);
    const band_water = try allocF64(allocator, reader, cell_count);
    errdefer allocator.free(band_water);
    const has_air_zones = if (version >= 3) switch (try reader.takeByte()) {
        0 => false,
        1 => true,
        else => return error.InvalidCoupledGasSnapshotBoolean,
    } else false;
    const nonband_air = try allocF64(allocator, reader, if (has_air_zones) cell_count else 0);
    errdefer allocator.free(nonband_air);
    const band_air = try allocF64(allocator, reader, if (has_air_zones) cell_count else 0);
    errdefer allocator.free(band_air);
    const component_count = std.math.mul(usize, cell_count, gas.species_count) catch
        return error.CoupledGasSnapshotLimitExceeded;
    const solubility = try allocF64(allocator, reader, component_count);
    errdefer allocator.free(solubility);
    const exchange = try allocF64(allocator, reader, component_count);
    errdefer allocator.free(exchange);
    const band_exchange = try allocF64(allocator, reader, component_count);
    errdefer allocator.free(band_exchange);
    const bubbling = try allocator.alloc(bool, cell_count);
    errdefer allocator.free(bubbling);
    for (bubbling) |*enabled| enabled.* = switch (try reader.takeByte()) {
        0 => false,
        1 => true,
        else => return error.InvalidCoupledGasSnapshotBoolean,
    };
    const receivers: ?[]?usize = if (version < 2) null else switch (try reader.takeByte()) {
        0 => null,
        1 => blk: {
            const map = try allocator.alloc(?usize, cell_count);
            errdefer allocator.free(map);
            for (map) |*receiver| receiver.* = switch (try reader.takeByte()) {
                0 => null,
                1 => try readIndex(reader),
                else => return error.InvalidCoupledGasSnapshotBoolean,
            };
            break :blk map;
        },
        else => return error.InvalidCoupledGasSnapshotBoolean,
    };
    errdefer if (receivers) |map| allocator.free(map);
    const options = try readSolverOptions(reader, version);
    const has_carrier_minimum = if (version >= 8) switch (try reader.takeByte()) {
        0 => false,
        1 => true,
        else => return error.InvalidCoupledGasSnapshotBoolean,
    } else false;
    const carrier_minimum = try allocF64(
        allocator,
        reader,
        if (has_carrier_minimum) cell_count else 0,
    );
    errdefer allocator.free(carrier_minimum);
    return .{
        .allocator = allocator,
        .state = state,
        .faces = faces,
        .face_conductance_m3_per_step = face_conductance,
        .atmospheric_boundaries = atmospheric_boundaries,
        .subsurface_boundaries = subsurface_boundaries,
        .water_volume_m3 = water,
        .band_water_volume_m3 = band_water,
        .nonband_air_volume_m3 = nonband_air,
        .band_air_volume_m3 = band_air,
        .mass_solubility_ratio = solubility,
        .gas_water_exchange_rate_per_step = exchange,
        .band_gas_water_exchange_rate_per_step = band_exchange,
        .bubbling_enabled = bubbling,
        .minimum_carrier_volume_m3 = carrier_minimum,
        .bubble_receiver_cell_by_cell = receivers,
        .bubble_receiver_map_captured = version >= 2,
        .options = options,
    };
}

fn writeBoundaries(writer: anytype, boundaries: []const atmosphere.Boundary) !void {
    for (boundaries) |boundary| {
        try writer.writeInt(u64, @intCast(boundary.cell_index), .little);
        try writeF64(writer, boundary.aerodynamic_conductance_m3_per_step);
        try writeF64Slice(writer, &boundary.interior_conductance_m3_per_step);
        try writeF64Slice(writer, &boundary.atmospheric_concentration_g_per_m3);
        try writeF64(writer, boundary.pressure_exchange_fraction);
    }
}

fn writeSolverOptions(writer: anytype, options: SolverOptions) !void {
    // Keep the original seven-scalar prefix stable for straightforward
    // backwards-fixture construction and append the typed vector in v4.
    try writeF64(writer, options.absolute_tolerance_g);
    try writeF64(writer, options.relative_tolerance);
    try writeF64(writer, options.picard_relaxation);
    try writeF64(writer, options.directional_probe_fraction);
    try writeF64(writer, options.minimum_newton_fraction);
    try writeF64(writer, options.maximum_newton_fraction);
    try writeF64(writer, options.transport_iteration_fraction);
    try writer.writeInt(u16, options.max_iterations, .little);
    try writeF64Slice(writer, &options.absolute_tolerance_g_by_species);
    try writer.writeInt(u16, options.divergence_patience, .little);
    try writeF64(writer, options.divergence_growth_factor);
    try writer.writeByte(@intFromBool(options.accept_physically_conserved_ceiling));
    try writer.writeInt(u64, @intCast(options.krylov_restart_max), .little);
    try writeF64(writer, options.krylov_relative_tolerance);
}

fn readSolverOptions(reader: *std.Io.Reader, version: u32) !SolverOptions {
    var options: SolverOptions = .{
        .absolute_tolerance_g = try readF64(reader),
        .relative_tolerance = try readF64(reader),
        .picard_relaxation = try readF64(reader),
        .directional_probe_fraction = try readF64(reader),
        .minimum_newton_fraction = try readF64(reader),
        .maximum_newton_fraction = try readF64(reader),
        .transport_iteration_fraction = try readF64(reader),
        .max_iterations = try reader.takeInt(u16, .little),
    };
    if (version >= 4) {
        try readF64Slice(reader, &options.absolute_tolerance_g_by_species);
    } else {
        // Historical captures used a single homogeneous floor. Expanding it
        // exactly retains their original acceptance problem.
        options.absolute_tolerance_g_by_species = @splat(options.absolute_tolerance_g);
    }
    if (version >= 5) {
        options.divergence_patience = try reader.takeInt(u16, .little);
        options.divergence_growth_factor = try readF64(reader);
    }
    if (version >= 6) {
        options.accept_physically_conserved_ceiling = switch (try reader.takeByte()) {
            0 => false,
            1 => true,
            else => return error.InvalidCoupledGasSnapshotBoolean,
        };
        options.krylov_restart_max = std.math.cast(
            usize,
            try reader.takeInt(u64, .little),
        ) orelse return error.CoupledGasSnapshotLimitExceeded;
    }
    if (version >= 7)
        options.krylov_relative_tolerance = try readF64(reader);
    return options;
}

fn readBoundaries(allocator: std.mem.Allocator, reader: *std.Io.Reader, count: usize) ![]atmosphere.Boundary {
    const boundaries = try allocator.alloc(atmosphere.Boundary, count);
    errdefer allocator.free(boundaries);
    for (boundaries) |*boundary| {
        boundary.cell_index = try readIndex(reader);
        boundary.aerodynamic_conductance_m3_per_step = try readF64(reader);
        try readF64Slice(reader, &boundary.interior_conductance_m3_per_step);
        try readF64Slice(reader, &boundary.atmospheric_concentration_g_per_m3);
        boundary.pressure_exchange_fraction = try readF64(reader);
    }
    return boundaries;
}

fn validate(replay_case: ReplayCase, limits: Limits) !void {
    try validateView(&replay_case.state, replay_case.inputs(), replay_case.options, limits);
}

fn validateView(
    state: *const gas.State,
    inputs: InputView,
    options: SolverOptions,
    limits: Limits,
) !void {
    const cells = state.cell_count;
    const components = std.math.mul(usize, cells, gas.species_count) catch
        return error.InvalidCoupledGasSnapshotDimensions;
    if (state.air_volume_m3.len != cells or
        state.temperature_k.len != cells or
        state.water_vapor_mol.len != cells or
        state.gaseous_mass_g.len != components or
        state.dissolved_mass_g.len != components or
        state.macropore_dissolved_mass_g.len != components or
        state.band_dissolved_mass_g.len != components)
        return error.InvalidCoupledGasSnapshotDimensions;
    if ((limits.maximum_cells != 0 and cells > limits.maximum_cells) or
        (limits.maximum_faces != 0 and inputs.faces.len > limits.maximum_faces) or
        (limits.maximum_boundaries != 0 and
            (inputs.atmospheric_boundaries.len > limits.maximum_boundaries or
                inputs.subsurface_boundaries.len > limits.maximum_boundaries)))
        return error.CoupledGasSnapshotLimitExceeded;
    const face_components = std.math.mul(usize, inputs.faces.len, gas.species_count) catch
        return error.InvalidCoupledGasSnapshotDimensions;
    if (inputs.face_conductance_m3_per_step.len != face_components or
        inputs.water_volume_m3.len != cells or
        inputs.band_water_volume_m3.len != cells or
        !((inputs.nonband_air_volume_m3.len == 0 and inputs.band_air_volume_m3.len == 0) or
            (inputs.nonband_air_volume_m3.len == cells and inputs.band_air_volume_m3.len == cells)) or
        inputs.mass_solubility_ratio.len != components or
        inputs.gas_water_exchange_rate_per_step.len != components or
        inputs.band_gas_water_exchange_rate_per_step.len != components or
        inputs.bubbling_enabled.len != cells)
        return error.InvalidCoupledGasSnapshotDimensions;
    for (inputs.faces) |face|
        if (face.first_cell >= cells or face.second_cell >= cells or face.first_cell == face.second_cell)
            return error.InvalidCoupledGasSnapshotTopology;
    if (inputs.bubble_receiver_cell_by_cell) |receivers| {
        if (receivers.len != cells) return error.InvalidCoupledGasSnapshotDimensions;
        for (receivers) |receiver| if (receiver) |cell|
            if (cell >= cells) return error.InvalidCoupledGasSnapshotTopology;
    }
    for (inputs.atmospheric_boundaries) |boundary|
        try validateBoundary(boundary, cells);
    for (inputs.subsurface_boundaries) |boundary|
        try validateBoundary(boundary, cells);
    inline for (std.meta.fields(gas.State)) |field| if (field.type == []f64)
        try validateFiniteNonnegative(@field(state, field.name));
    for (state.temperature_k) |temperature_k|
        if (temperature_k <= 0) return error.InvalidCoupledGasSnapshotValue;
    try validateFiniteNonnegative(inputs.face_conductance_m3_per_step);
    try validateFiniteNonnegative(inputs.water_volume_m3);
    try validateFiniteNonnegative(inputs.band_water_volume_m3);
    try validateFiniteNonnegative(inputs.nonband_air_volume_m3);
    try validateFiniteNonnegative(inputs.band_air_volume_m3);
    try validateFiniteNonnegative(inputs.gas_water_exchange_rate_per_step);
    try validateFiniteNonnegative(inputs.band_gas_water_exchange_rate_per_step);
    for (inputs.mass_solubility_ratio) |value|
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidCoupledGasSnapshotValue;
    for (options.absolute_tolerance_g_by_species) |tolerance_g|
        if (!std.math.isFinite(tolerance_g) or tolerance_g <= 0)
            return error.InvalidCoupledGasSnapshotValue;
    if ((!std.math.isNan(options.absolute_tolerance_g) and
        (!std.math.isFinite(options.absolute_tolerance_g) or options.absolute_tolerance_g <= 0)) or
        !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or
        !std.math.isFinite(options.picard_relaxation) or
        options.picard_relaxation <= 0 or
        options.picard_relaxation > 1 or
        !std.math.isFinite(options.directional_probe_fraction) or
        options.directional_probe_fraction <= 0 or
        !std.math.isFinite(options.minimum_newton_fraction) or
        options.minimum_newton_fraction <= 0 or
        !std.math.isFinite(options.maximum_newton_fraction) or
        options.maximum_newton_fraction < options.minimum_newton_fraction or
        options.divergence_patience == 0 or
        !std.math.isFinite(options.divergence_growth_factor) or
        options.divergence_growth_factor < 1 or
        !std.math.isFinite(options.transport_iteration_fraction) or
        options.transport_iteration_fraction <= 0 or
        options.transport_iteration_fraction > 1 or
        options.max_iterations == 0 or
        options.krylov_restart_max == 0 or
        !std.math.isFinite(options.krylov_relative_tolerance) or
        options.krylov_relative_tolerance <= 0 or
        options.krylov_relative_tolerance >= 1)
        return error.InvalidCoupledGasSnapshotValue;
}

fn validateBoundary(boundary: atmosphere.Boundary, cells: usize) !void {
    if (boundary.cell_index >= cells or
        !std.math.isFinite(boundary.aerodynamic_conductance_m3_per_step) or
        boundary.aerodynamic_conductance_m3_per_step < 0 or
        !std.math.isFinite(boundary.pressure_exchange_fraction) or
        boundary.pressure_exchange_fraction < 0 or
        boundary.pressure_exchange_fraction > 1)
        return error.InvalidCoupledGasSnapshotBoundary;
    try validateFiniteNonnegative(&boundary.interior_conductance_m3_per_step);
    try validateFiniteNonnegative(&boundary.atmospheric_concentration_g_per_m3);
}

fn validateFiniteNonnegative(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidCoupledGasSnapshotValue;
}

fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| try writeF64(writer, value);
}

fn writeF64(writer: anytype, value: f64) !void {
    try writer.writeInt(u64, @bitCast(value), .little);
}

fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| value.* = try readF64(reader);
}

fn readF64(reader: *std.Io.Reader) !f64 {
    return @bitCast(try reader.takeInt(u64, .little));
}

fn allocF64(allocator: std.mem.Allocator, reader: *std.Io.Reader, count: usize) ![]f64 {
    const values = try allocator.alloc(f64, count);
    errdefer allocator.free(values);
    try readF64Slice(reader, values);
    return values;
}

fn readCount(reader: *std.Io.Reader, maximum: usize) !usize {
    const value = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse
        return error.CoupledGasSnapshotLimitExceeded;
    if (value > maximum) return error.CoupledGasSnapshotLimitExceeded;
    return value;
}

fn readIndex(reader: *std.Io.Reader) !usize {
    return std.math.cast(usize, try reader.takeInt(u64, .little)) orelse
        error.CoupledGasSnapshotLimitExceeded;
}

fn rejectTrailing(reader: *std.Io.Reader) !void {
    if (reader.peekByte()) |_|
        return error.TrailingCoupledGasSnapshotData
    else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
}

fn makeReplayCase(allocator: std.mem.Allocator) !ReplayCase {
    var state = try gas.State.init(allocator, 2);
    errdefer state.deinit();
    state.air_volume_m3[0] = 1;
    state.air_volume_m3[1] = 2;
    state.temperature_k[0] = 290;
    state.temperature_k[1] = 291;
    state.water_vapor_mol[0] = 0.01;
    state.water_vapor_mol[1] = 0.02;
    for (state.gaseous_mass_g, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    for (state.dissolved_mass_g, 0..) |*value, index| value.* = @as(f64, @floatFromInt(index + 1)) / 10;

    const faces = try allocator.dupe(gas.Face, &.{.{ .first_cell = 0, .second_cell = 1 }});
    errdefer allocator.free(faces);
    const conductance = try allocator.alloc(f64, gas.species_count);
    errdefer allocator.free(conductance);
    @memset(conductance, 0.01);
    const boundaries = try allocator.dupe(atmosphere.Boundary, &.{.{
        .cell_index = 0,
        .aerodynamic_conductance_m3_per_step = 0.1,
        .interior_conductance_m3_per_step = [_]f64{0.2} ** gas.species_count,
        .atmospheric_concentration_g_per_m3 = [_]f64{0.001} ** gas.species_count,
    }});
    errdefer allocator.free(boundaries);
    const subsurface = try allocator.alloc(atmosphere.Boundary, 0);
    errdefer allocator.free(subsurface);
    const water = try allocator.dupe(f64, &.{ 0.3, 0.4 });
    errdefer allocator.free(water);
    const band_water = try allocator.dupe(f64, &.{ 0.01, 0.02 });
    errdefer allocator.free(band_water);
    const nonband_air = try allocator.dupe(f64, &.{ 0.75, 0.5 });
    errdefer allocator.free(nonband_air);
    const band_air = try allocator.dupe(f64, &.{ 0.25, 1.5 });
    errdefer allocator.free(band_air);
    const components = 2 * gas.species_count;
    const solubility = try allocator.alloc(f64, components);
    errdefer allocator.free(solubility);
    @memset(solubility, 0.8);
    const exchange = try allocator.alloc(f64, components);
    errdefer allocator.free(exchange);
    @memset(exchange, 0.1);
    const band_exchange = try allocator.alloc(f64, components);
    errdefer allocator.free(band_exchange);
    @memset(band_exchange, 0.05);
    const bubbling = try allocator.dupe(bool, &.{ true, false });
    errdefer allocator.free(bubbling);
    // Cell 0 releases into cell 1; cell 1 has no gas-phase route, so its
    // release is a boundary loss. Both branches are exercised on the wire.
    const receivers = try allocator.dupe(?usize, &[_]?usize{ 1, null });
    errdefer allocator.free(receivers);
    // Distinct per-cell values so a swap or a broadcast would be caught.
    const carrier_minimum = try allocator.dupe(f64, &.{ 1e-6, 2e-6 });
    return .{
        .allocator = allocator,
        .state = state,
        .faces = faces,
        .face_conductance_m3_per_step = conductance,
        .atmospheric_boundaries = boundaries,
        .subsurface_boundaries = subsurface,
        .water_volume_m3 = water,
        .band_water_volume_m3 = band_water,
        .nonband_air_volume_m3 = nonband_air,
        .band_air_volume_m3 = band_air,
        .mass_solubility_ratio = solubility,
        .gas_water_exchange_rate_per_step = exchange,
        .band_gas_water_exchange_rate_per_step = band_exchange,
        .bubbling_enabled = bubbling,
        .minimum_carrier_volume_m3 = carrier_minimum,
        .bubble_receiver_cell_by_cell = receivers,
        .options = .{ .max_iterations = 80 },
    };
}

// The carrier minimum decides which faces exist at all
// (`ecosys_f77/trnsfr.f:5303-5306`), so a snapshot that drops it replays a
// different system than the one that failed -- and specifically an easier-to-
// admit, harder-to-solve one, because a missing floor admits faces production
// skipped. Format version 8 carries it.
test "carrier minimum round-trips per cell and pre-8 snapshots decode as absent" {
    var original = try makeReplayCase(std.testing.allocator);
    defer original.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(std.testing.allocator, &bytes.writer, &original);
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{});
    defer restored.deinit();
    try std.testing.expectEqualSlices(
        f64,
        original.minimum_carrier_volume_m3,
        restored.minimum_carrier_volume_m3,
    );
    // The value must survive the adapter into the live solver's input struct,
    // not merely the wire format.
    try std.testing.expectEqualSlices(
        f64,
        original.minimum_carrier_volume_m3,
        restored.inputs().minimum_carrier_volume_m3,
    );

    // "No floor supplied" must stay distinguishable from a per-cell floor, and
    // must not be conflated with an all-zero floor.
    var absent = try makeReplayCase(std.testing.allocator);
    defer absent.deinit();
    std.testing.allocator.free(absent.minimum_carrier_volume_m3);
    absent.minimum_carrier_volume_m3 = &.{};
    var absent_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer absent_bytes.deinit();
    try write(std.testing.allocator, &absent_bytes.writer, &absent);
    var absent_reader: std.Io.Reader = .fixed(absent_bytes.written());
    var restored_absent = try read(std.testing.allocator, &absent_reader, .{});
    defer restored_absent.deinit();
    try std.testing.expectEqual(@as(usize, 0), restored_absent.minimum_carrier_volume_m3.len);

    var zeroed = try makeReplayCase(std.testing.allocator);
    defer zeroed.deinit();
    @memset(zeroed.minimum_carrier_volume_m3, 0);
    var zeroed_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer zeroed_bytes.deinit();
    try write(std.testing.allocator, &zeroed_bytes.writer, &zeroed);
    var zeroed_reader: std.Io.Reader = .fixed(zeroed_bytes.written());
    var restored_zeroed = try read(std.testing.allocator, &zeroed_reader, .{});
    defer restored_zeroed.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored_zeroed.minimum_carrier_volume_m3.len);
    try std.testing.expect(!std.mem.eql(u8, absent_bytes.written(), zeroed_bytes.written()));
}

test "coupled gas failure snapshot is bit preserving and self-contained" {
    var original = try makeReplayCase(std.testing.allocator);
    defer original.deinit();
    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try write(std.testing.allocator, &first.writer, &original);
    var reader: std.Io.Reader = .fixed(first.written());
    var restored = try read(std.testing.allocator, &reader, .{});
    defer restored.deinit();
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try write(std.testing.allocator, &second.writer, &restored);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
}

test "coupled gas failure snapshot rejects corruption truncation version and trailing bytes" {
    var replay_case = try makeReplayCase(std.testing.allocator);
    defer replay_case.deinit();
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try write(std.testing.allocator, &encoded.writer, &replay_case);

    const corrupted = try std.testing.allocator.dupe(u8, encoded.written());
    defer std.testing.allocator.free(corrupted);
    corrupted[magic.len + 4 + 8 + 8] ^= 1;
    var corrupt_reader: std.Io.Reader = .fixed(corrupted);
    try std.testing.expectError(error.CoupledGasSnapshotChecksumMismatch, read(std.testing.allocator, &corrupt_reader, .{}));

    var truncated_reader: std.Io.Reader = .fixed(encoded.written()[0 .. encoded.written().len - 1]);
    try std.testing.expectError(error.TruncatedCoupledGasSnapshot, read(std.testing.allocator, &truncated_reader, .{}));

    const wrong_version = try std.testing.allocator.dupe(u8, encoded.written());
    defer std.testing.allocator.free(wrong_version);
    wrong_version[magic.len] = format_version + 1;
    var version_reader: std.Io.Reader = .fixed(wrong_version);
    try std.testing.expectError(error.UnsupportedCoupledGasSnapshotVersion, read(std.testing.allocator, &version_reader, .{}));

    const below_minimum = try std.testing.allocator.dupe(u8, encoded.written());
    defer std.testing.allocator.free(below_minimum);
    below_minimum[magic.len] = minimum_readable_version - 1;
    var below_reader: std.Io.Reader = .fixed(below_minimum);
    try std.testing.expectError(error.UnsupportedCoupledGasSnapshotVersion, read(std.testing.allocator, &below_reader, .{}));

    const trailing = try std.testing.allocator.alloc(u8, encoded.written().len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..encoded.written().len], encoded.written());
    trailing[trailing.len - 1] = 0;
    var trailing_reader: std.Io.Reader = .fixed(trailing);
    try std.testing.expectError(error.TrailingCoupledGasSnapshotData, read(std.testing.allocator, &trailing_reader, .{}));
}

test "coupled gas failure snapshot enforces allocation bounds before payload decoding" {
    var replay_case = try makeReplayCase(std.testing.allocator);
    defer replay_case.deinit();
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try write(std.testing.allocator, &encoded.writer, &replay_case);
    var reader: std.Io.Reader = .fixed(encoded.written());
    try std.testing.expectError(error.CoupledGasSnapshotLimitExceeded, read(std.testing.allocator, &reader, .{ .maximum_payload_bytes = 16 }));
}

test "capture deep copies every replay input and state array" {
    var source = try makeReplayCase(std.testing.allocator);
    defer source.deinit();
    var captured = try capture(
        std.testing.allocator,
        &source.state,
        source.inputs(),
        source.options,
    );
    defer captured.deinit();

    const captured_gas_bits: u64 = @bitCast(captured.state.gaseous_mass_g[0]);
    const captured_conductance_bits: u64 =
        @bitCast(captured.face_conductance_m3_per_step[0]);
    const captured_boundary_bits: u64 = @bitCast(
        captured.atmospheric_boundaries[0]
            .atmospheric_concentration_g_per_m3[0],
    );
    source.state.gaseous_mass_g[0] = 999;
    source.faces[0].second_cell = 0;
    source.face_conductance_m3_per_step[0] = 888;
    source.atmospheric_boundaries[0]
        .atmospheric_concentration_g_per_m3[0] = 777;
    source.water_volume_m3[0] = 666;
    source.bubbling_enabled[0] = false;

    try std.testing.expectEqual(
        captured_gas_bits,
        @as(u64, @bitCast(captured.state.gaseous_mass_g[0])),
    );
    try std.testing.expectEqual(@as(usize, 1), captured.faces[0].second_cell);
    try std.testing.expectEqual(
        captured_conductance_bits,
        @as(u64, @bitCast(captured.face_conductance_m3_per_step[0])),
    );
    try std.testing.expectEqual(
        captured_boundary_bits,
        @as(
            u64,
            @bitCast(
                captured.atmospheric_boundaries[0]
                    .atmospheric_concentration_g_per_m3[0],
            ),
        ),
    );
    try std.testing.expectEqual(@as(f64, 0.3), captured.water_volume_m3[0]);
    try std.testing.expect(captured.bubbling_enabled[0]);

    // The receiver map is a solver input, so it must be deep copied too.
    source.bubble_receiver_cell_by_cell.?[0] = 0;
    try std.testing.expectEqual(
        @as(?usize, 1),
        captured.bubble_receiver_cell_by_cell.?[0],
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        captured.bubble_receiver_cell_by_cell.?[1],
    );
}

test "bubble receiver map round-trips and distinguishes absent from all-null" {
    var with_map = try makeReplayCase(std.testing.allocator);
    defer with_map.deinit();
    var mapped: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer mapped.deinit();
    try write(std.testing.allocator, &mapped.writer, &with_map);
    var mapped_reader: std.Io.Reader = .fixed(mapped.written());
    var restored_mapped = try read(std.testing.allocator, &mapped_reader, .{});
    defer restored_mapped.deinit();
    try std.testing.expectEqualSlices(
        ?usize,
        with_map.bubble_receiver_cell_by_cell.?,
        restored_mapped.bubble_receiver_cell_by_cell.?,
    );

    // "No map at all" means release into the source cell, which is a
    // physically different destination from "a map whose entries are all
    // null" (release as a boundary loss). The encoding must not conflate them.
    var absent = try makeReplayCase(std.testing.allocator);
    defer absent.deinit();
    std.testing.allocator.free(absent.bubble_receiver_cell_by_cell.?);
    absent.bubble_receiver_cell_by_cell = null;
    var absent_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer absent_bytes.deinit();
    try write(std.testing.allocator, &absent_bytes.writer, &absent);
    var absent_reader: std.Io.Reader = .fixed(absent_bytes.written());
    var restored_absent = try read(std.testing.allocator, &absent_reader, .{});
    defer restored_absent.deinit();
    try std.testing.expectEqual(
        @as(?[]?usize, null),
        restored_absent.bubble_receiver_cell_by_cell,
    );

    var all_null = try makeReplayCase(std.testing.allocator);
    defer all_null.deinit();
    for (all_null.bubble_receiver_cell_by_cell.?) |*receiver| receiver.* = null;
    var all_null_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer all_null_bytes.deinit();
    try write(std.testing.allocator, &all_null_bytes.writer, &all_null);
    var all_null_reader: std.Io.Reader = .fixed(all_null_bytes.written());
    var restored_all_null = try read(std.testing.allocator, &all_null_reader, .{});
    defer restored_all_null.deinit();
    try std.testing.expectEqual(
        @as(usize, 2),
        restored_all_null.bubble_receiver_cell_by_cell.?.len,
    );
    try std.testing.expect(!std.mem.eql(u8, absent_bytes.written(), all_null_bytes.written()));
}

test "snapshot rejects an out-of-range bubble receiver cell" {
    var replay_case = try makeReplayCase(std.testing.allocator);
    defer replay_case.deinit();
    replay_case.bubble_receiver_cell_by_cell.?[0] = 2;
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try std.testing.expectError(
        error.InvalidCoupledGasSnapshotTopology,
        write(std.testing.allocator, &encoded.writer, &replay_case),
    );
}

test "version 1 snapshot decodes but is flagged as missing its bubble receiver map" {
    // The archived Ottawa captures are version 1. They must stay readable
    // because they are the only real production coupled-gas evidence, but a
    // replay of one is not evidence about bubbling destinations. Build a
    // version 1 payload by writing an absent-map case, deleting the single
    // presence byte version 2 added, and relabelling the version.
    var replay_case = try makeReplayCase(std.testing.allocator);
    defer replay_case.deinit();
    std.testing.allocator.free(replay_case.bubble_receiver_cell_by_cell.?);
    replay_case.bubble_receiver_cell_by_cell = null;
    std.testing.allocator.free(replay_case.nonband_air_volume_m3);
    replay_case.nonband_air_volume_m3 = try std.testing.allocator.alloc(f64, 0);
    std.testing.allocator.free(replay_case.band_air_volume_m3);
    replay_case.band_air_volume_m3 = try std.testing.allocator.alloc(f64, 0);
    // Same for the version 8 carrier minimum: leave only its presence byte to
    // delete, so the byte surgery below stays a fixed offset.
    std.testing.allocator.free(replay_case.minimum_carrier_volume_m3);
    replay_case.minimum_carrier_volume_m3 = try std.testing.allocator.alloc(f64, 0);
    // Versions 1--3 required the homogeneous scalar; v4 permits the live
    // typed-vector mode whose compatibility scalar is NaN.
    replay_case.options.absolute_tolerance_g = 1e-12;
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try write(std.testing.allocator, &encoded.writer, &replay_case);

    const version_seven = encoded.written();
    const legacy_option_bytes = 7 * @sizeOf(f64) + @sizeOf(u16);
    const typed_tolerance_bytes = gas.species_count * @sizeOf(f64);
    const divergence_option_bytes = @sizeOf(u16) + @sizeOf(f64);
    const solver_policy_option_bytes = @sizeOf(u8) + @sizeOf(u64);
    const krylov_tolerance_option_bytes = @sizeOf(f64);
    // Version 8 appends the carrier-minimum presence byte AFTER the options, so
    // it is not part of `option_bytes`; it is stripped as a trailing byte below.
    const carrier_minimum_presence_bytes = @sizeOf(u8);
    const option_bytes = legacy_option_bytes + typed_tolerance_bytes + divergence_option_bytes + solver_policy_option_bytes + krylov_tolerance_option_bytes;
    const header = magic.len + 4 + 8 + 8;
    const component_count = replay_case.state.cell_count * gas.species_count;
    const boundary_bytes = (replay_case.atmospheric_boundaries.len + replay_case.subsurface_boundaries.len) *
        (3 + 2 * gas.species_count) * @sizeOf(u64);
    const air_presence = header + 4 * @sizeOf(u64) +
        3 * replay_case.state.cell_count * @sizeOf(f64) +
        4 * component_count * @sizeOf(f64) +
        2 * replay_case.faces.len * @sizeOf(u64) +
        replay_case.face_conductance_m3_per_step.len * @sizeOf(f64) +
        boundary_bytes +
        2 * replay_case.state.cell_count * @sizeOf(f64);
    const without_carrier_minimum = version_seven.len - carrier_minimum_presence_bytes;
    const bubble_presence = without_carrier_minimum - option_bytes - 1;
    const version_seven_without_new_options = without_carrier_minimum - typed_tolerance_bytes - divergence_option_bytes - solver_policy_option_bytes - krylov_tolerance_option_bytes;
    const legacy = try std.testing.allocator.alloc(u8, without_carrier_minimum - 2 - typed_tolerance_bytes - divergence_option_bytes - solver_policy_option_bytes - krylov_tolerance_option_bytes);
    defer std.testing.allocator.free(legacy);
    @memcpy(legacy[0..air_presence], version_seven[0..air_presence]);
    @memcpy(legacy[air_presence .. bubble_presence - 1], version_seven[air_presence + 1 .. bubble_presence]);
    @memcpy(legacy[bubble_presence - 1 ..], version_seven[bubble_presence + 1 .. version_seven_without_new_options]);
    legacy[magic.len] = 1;
    const payload = legacy[header..];
    std.mem.writeInt(u64, legacy[magic.len + 4 ..][0..8], payload.len, .little);
    std.mem.writeInt(
        u64,
        legacy[magic.len + 4 + 8 ..][0..8],
        std.hash.Wyhash.hash(checksum_seed, payload),
        .little,
    );

    var reader: std.Io.Reader = .fixed(legacy);
    var restored = try read(std.testing.allocator, &reader, .{});
    defer restored.deinit();
    try std.testing.expect(!restored.bubble_receiver_map_captured);
    try std.testing.expectEqual(
        @as(?[]?usize, null),
        restored.bubble_receiver_cell_by_cell,
    );
    // The state itself still round-trips, so a v1 replay remains useful for
    // everything except bubbling destinations.
    try std.testing.expectEqualSlices(
        f64,
        replay_case.state.gaseous_mass_g,
        restored.state.gaseous_mass_g,
    );
    try std.testing.expectEqualSlices(
        f64,
        &([_]f64{1e-12} ** gas.species_count),
        &restored.options.absolute_tolerance_g_by_species,
    );
    try std.testing.expect(!restored.options.accept_physically_conserved_ceiling);
    try std.testing.expectEqual(@as(usize, 12), restored.options.krylov_restart_max);
    try std.testing.expectEqual(@as(f64, 0.01), restored.options.krylov_relative_tolerance);
    // A freshly captured case is always faithful, so the flag records archive
    // provenance rather than merely echoing an absent map.
    try std.testing.expect(replay_case.bubble_receiver_map_captured);
}

test "capture validates before allocation and rejects incomplete replay input" {
    var source = try makeReplayCase(std.testing.allocator);
    defer source.deinit();
    var inputs = source.inputs();
    inputs.water_volume_m3 = inputs.water_volume_m3[0..1];
    try std.testing.expectError(
        error.InvalidCoupledGasSnapshotDimensions,
        capture(std.testing.allocator, &source.state, inputs, source.options),
    );

    inputs = source.inputs();
    var invalid_options = source.options;
    invalid_options.maximum_newton_fraction = 0.01;
    try std.testing.expectError(
        error.InvalidCoupledGasSnapshotValue,
        capture(std.testing.allocator, &source.state, inputs, invalid_options),
    );
}

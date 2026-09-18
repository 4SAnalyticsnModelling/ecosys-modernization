const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const solver = @import("reaction_solver.zig");

const magic = "ECOSSOL!";
const legacy_format_version: u32 = 1;
const format_version: u32 = 2;
const checksum_seed: u64 = 0x45434f53534f4c46;

/// Snapshot v1 predated separate concentration- and soil-mass-based absolute
/// tolerances. Keep its exact in-memory field set here so archived production
/// failures remain replayable after the solver options evolved. New snapshots
/// use v2 and the frozen unit-specific schema below.
const LegacyOptionsV1 = struct {
    absolute_tolerance: f64 = 1e-11,
    relative_tolerance: f64 = 1e-8,
    picard_relaxation: f64 = 0.5,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    maximum_newton_fraction: f64 = 1.5,
    max_iterations: u16 = 60,
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    anderson_recovery: bool = true,

    fn upgrade(self: LegacyOptionsV1) solver.Options {
        return .{
            .absolute_tolerance_mol_per_m3 = self.absolute_tolerance,
            .absolute_tolerance_mol_per_megagram = self.absolute_tolerance,
            .relative_tolerance = self.relative_tolerance,
            .picard_relaxation = self.picard_relaxation,
            .directional_probe_fraction = self.directional_probe_fraction,
            .minimum_newton_fraction = self.minimum_newton_fraction,
            .maximum_newton_fraction = self.maximum_newton_fraction,
            .max_iterations = self.max_iterations,
            .divergence_patience = self.divergence_patience,
            .divergence_growth_factor = self.divergence_growth_factor,
            .anderson_recovery = self.anderson_recovery,
        };
    }
};

/// Version 1 was not bumped when the two unit-specific absolute tolerances
/// replaced `absolute_tolerance`. Consequently, production archives contain
/// both the original 64-byte options payload and this 72-byte payload under
/// the same version number. This frozen wire type decodes the latter and is
/// also the options schema written by version 2; do not replace it with
/// `solver.Options`, whose in-memory layout may evolve again.
const OptionsWithUnitTolerances = struct {
    absolute_tolerance_mol_per_m3: f64 = 1e-11,
    absolute_tolerance_mol_per_megagram: f64 = 1e-11,
    relative_tolerance: f64 = 1e-8,
    picard_relaxation: f64 = 0.5,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    maximum_newton_fraction: f64 = 1.0,
    max_iterations: u16 = 60,
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    anderson_recovery: bool = true,

    fn fromCurrent(options: solver.Options) OptionsWithUnitTolerances {
        return .{
            .absolute_tolerance_mol_per_m3 = options.absolute_tolerance_mol_per_m3,
            .absolute_tolerance_mol_per_megagram = options.absolute_tolerance_mol_per_megagram,
            .relative_tolerance = options.relative_tolerance,
            .picard_relaxation = options.picard_relaxation,
            .directional_probe_fraction = options.directional_probe_fraction,
            .minimum_newton_fraction = options.minimum_newton_fraction,
            .maximum_newton_fraction = options.maximum_newton_fraction,
            .max_iterations = options.max_iterations,
            .divergence_patience = options.divergence_patience,
            .divergence_growth_factor = options.divergence_growth_factor,
            .anderson_recovery = options.anderson_recovery,
        };
    }

    fn upgrade(self: OptionsWithUnitTolerances) solver.Options {
        return .{
            .absolute_tolerance_mol_per_m3 = self.absolute_tolerance_mol_per_m3,
            .absolute_tolerance_mol_per_megagram = self.absolute_tolerance_mol_per_megagram,
            .relative_tolerance = self.relative_tolerance,
            .picard_relaxation = self.picard_relaxation,
            .directional_probe_fraction = self.directional_probe_fraction,
            .minimum_newton_fraction = self.minimum_newton_fraction,
            .maximum_newton_fraction = self.maximum_newton_fraction,
            .max_iterations = self.max_iterations,
            .divergence_patience = self.divergence_patience,
            .divergence_growth_factor = self.divergence_growth_factor,
            .anderson_recovery = self.anderson_recovery,
        };
    }
};

const OptionsEncoding = enum {
    legacy_single_tolerance,
    unit_specific_tolerances,
};

pub const Context = extern struct {
    execution_id: u64 = 0,
    scenario_id: u64 = 0,
    repeat_id: u64 = 0,
    scene_id: u64 = 0,
    scene_hour: u64 = 0,
    year: u64 = 0,
    day_of_year: u64 = 0,
    hour: u64 = 0,
    global_cell_id: u64 = 0,
    soil_layer_id: u64 = 0,
    packed_cell_index: u64 = 0,
};

pub const ReplayCase = struct {
    allocator: std.mem.Allocator,
    state: chemistry.State,
    parameters: chemistry.ReactionParameters,
    options: solver.Options,
    context: Context,

    pub fn deinit(self: *ReplayCase) void {
        self.state.deinit();
        self.* = undefined;
    }
};

pub fn capture(
    allocator: std.mem.Allocator,
    source: *const chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    options: solver.Options,
    context: Context,
) !ReplayCase {
    if (cell_index >= source.cell_count)
        return error.ChemistryCellIndexOutOfBounds;
    var state = try chemistry.State.init(allocator, 1);
    errdefer state.deinit();
    const count = chemistry.State.packedComponentCount();
    const packed_values = try allocator.alloc(f64, count);
    defer allocator.free(packed_values);
    try source.packCell(cell_index, packed_values);
    try state.unpackCell(0, packed_values);
    return .{
        .allocator = allocator,
        .state = state,
        .parameters = parameters,
        .options = options,
        .context = context,
    };
}

pub fn write(
    allocator: std.mem.Allocator,
    writer: anytype,
    replay_case: *const ReplayCase,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try payload.writer.writeAll(std.mem.asBytes(&replay_case.context));
    try payload.writer.writeAll(std.mem.asBytes(&replay_case.parameters));
    const snapshot_options = OptionsWithUnitTolerances.fromCurrent(
        replay_case.options,
    );
    try payload.writer.writeAll(std.mem.asBytes(&snapshot_options));
    var packed_values: [chemistry.State.packedComponentCount()]f64 = undefined;
    try replay_case.state.packCell(0, &packed_values);
    try payload.writer.writeAll(std.mem.asBytes(&packed_values));
    const bytes = payload.written();
    try writer.writeAll(magic);
    try writer.writeInt(u32, format_version, .little);
    try writer.writeInt(u64, @intCast(bytes.len), .little);
    try writer.writeInt(
        u64,
        std.hash.Wyhash.hash(checksum_seed, bytes),
        .little,
    );
    try writer.writeAll(bytes);
}

pub fn read(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !ReplayCase {
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic))
        return error.InvalidSoluteSnapshotMagic;
    const version = try reader.takeInt(u32, .little);
    if (version != legacy_format_version and version != format_version)
        return error.UnsupportedSoluteSnapshotVersion;
    const payload_size = std.math.cast(
        usize,
        try reader.takeInt(u64, .little),
    ) orelse return error.InvalidSoluteSnapshotSize;
    const checksum = try reader.takeInt(u64, .little);
    const payload_without_options = @sizeOf(Context) +
        @sizeOf(chemistry.ReactionParameters) +
        chemistry.State.packedComponentCount() * @sizeOf(f64);
    const legacy_payload_size = payload_without_options +
        @sizeOf(LegacyOptionsV1);
    const unit_specific_payload_size = payload_without_options +
        @sizeOf(OptionsWithUnitTolerances);
    const options_encoding: OptionsEncoding = switch (version) {
        legacy_format_version => if (payload_size == legacy_payload_size)
            .legacy_single_tolerance
        else if (payload_size == unit_specific_payload_size)
            .unit_specific_tolerances
        else
            return error.InvalidSoluteSnapshotSize,
        format_version => if (payload_size == unit_specific_payload_size)
            .unit_specific_tolerances
        else
            return error.InvalidSoluteSnapshotSize,
        else => unreachable,
    };
    const payload = try allocator.alloc(u8, payload_size);
    defer allocator.free(payload);
    reader.readSliceAll(payload) catch
        return error.TruncatedSoluteSnapshot;
    if (std.hash.Wyhash.hash(checksum_seed, payload) != checksum)
        return error.SoluteSnapshotChecksumMismatch;
    if (reader.peekByte()) |_|
        return error.TrailingSoluteSnapshotData
    else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    var context = std.mem.zeroes(Context);
    var parameters = std.mem.zeroes(chemistry.ReactionParameters);
    var options = std.mem.zeroes(solver.Options);
    var offset: usize = 0;
    @memcpy(std.mem.asBytes(&context), payload[offset..][0..@sizeOf(Context)]);
    offset += @sizeOf(Context);
    @memcpy(
        std.mem.asBytes(&parameters),
        payload[offset..][0..@sizeOf(chemistry.ReactionParameters)],
    );
    offset += @sizeOf(chemistry.ReactionParameters);
    const options_size: usize = switch (options_encoding) {
        .legacy_single_tolerance => @sizeOf(LegacyOptionsV1),
        .unit_specific_tolerances => @sizeOf(OptionsWithUnitTolerances),
    };
    switch (options_encoding) {
        .legacy_single_tolerance => {
            var legacy_options = std.mem.zeroes(LegacyOptionsV1);
            @memcpy(
                std.mem.asBytes(&legacy_options),
                payload[offset..][0..@sizeOf(LegacyOptionsV1)],
            );
            options = legacy_options.upgrade();
        },
        .unit_specific_tolerances => {
            var snapshot_options = std.mem.zeroes(OptionsWithUnitTolerances);
            @memcpy(
                std.mem.asBytes(&snapshot_options),
                payload[offset..][0..@sizeOf(OptionsWithUnitTolerances)],
            );
            options = snapshot_options.upgrade();
        },
    }
    offset += options_size;
    var packed_values: [chemistry.State.packedComponentCount()]f64 = undefined;
    @memcpy(std.mem.asBytes(&packed_values), payload[offset..]);
    var state = try chemistry.State.init(allocator, 1);
    errdefer state.deinit();
    try state.unpackCell(0, &packed_values);
    return .{
        .allocator = allocator,
        .state = state,
        .parameters = parameters,
        .options = options,
        .context = context,
    };
}

test "solute failure snapshot is self contained checksummed and replayable" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var packed_values: [chemistry.State.packedComponentCount()]f64 =
        [_]f64{1} ** chemistry.State.packedComponentCount();
    try state.unpackCell(0, &packed_values);
    var parameters = std.mem.zeroes(chemistry.ReactionParameters);
    parameters.fractions = .{
        .ammonium_non_band = 1,
        .ammonium_band = 0,
        .nitrate_non_band = 1,
        .nitrate_band = 0,
        .phosphate_non_band = 1,
        .phosphate_band = 0,
    };
    const options: solver.Options = .{ .max_iterations = 1 };
    var search_options = options;
    search_options.search_reference_concentrations = &packed_values;
    var captured = try capture(
        std.testing.allocator,
        &state,
        0,
        parameters,
        search_options,
        .{ .scene_hour = 3, .packed_cell_index = 0 },
    );
    defer captured.deinit();
    state.aqueous[0].hydroxide = 99;
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try write(std.testing.allocator, &encoded.writer, &captured);
    try std.testing.expectEqual(
        format_version,
        std.mem.readInt(
            u32,
            encoded.written()[magic.len..][0..@sizeOf(u32)],
            .little,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, @sizeOf(Context) +
            @sizeOf(chemistry.ReactionParameters) +
            @sizeOf(OptionsWithUnitTolerances) +
            chemistry.State.packedComponentCount() * @sizeOf(f64)),
        std.mem.readInt(
            u64,
            encoded.written()[magic.len + @sizeOf(u32) ..][0..@sizeOf(u64)],
            .little,
        ),
    );
    var reader: std.Io.Reader = .fixed(encoded.written());
    var restored = try read(std.testing.allocator, &reader);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 3), restored.context.scene_hour);
    try std.testing.expectEqual(@as(f64, 1), restored.state.aqueous[0].hydroxide);
    try std.testing.expectEqual(options, restored.options);
    const saved_version_byte = encoded.written()[magic.len];
    encoded.written()[magic.len] = 99;
    var unsupported_reader: std.Io.Reader = .fixed(encoded.written());
    try std.testing.expectError(
        error.UnsupportedSoluteSnapshotVersion,
        read(std.testing.allocator, &unsupported_reader),
    );
    encoded.written()[magic.len] = saved_version_byte;
    encoded.written()[encoded.written().len - 1] ^= 1;
    var corrupt_reader: std.Io.Reader = .fixed(encoded.written());
    try std.testing.expectError(
        error.SoluteSnapshotChecksumMismatch,
        read(std.testing.allocator, &corrupt_reader),
    );
}

test "v1 solute failure snapshot upgrades one absolute tolerance to both units" {
    var context = std.mem.zeroes(Context);
    context.scene_hour = 19;
    var parameters = std.mem.zeroes(chemistry.ReactionParameters);
    var legacy_options = std.mem.zeroes(LegacyOptionsV1);
    legacy_options.absolute_tolerance = 2.5e-10;
    legacy_options.relative_tolerance = 3.0e-8;
    legacy_options.picard_relaxation = 0.4;
    legacy_options.directional_probe_fraction = 0.25;
    legacy_options.minimum_newton_fraction = 0.02;
    legacy_options.maximum_newton_fraction = 1.25;
    legacy_options.max_iterations = 77;
    legacy_options.divergence_patience = 6;
    legacy_options.divergence_growth_factor = 500;
    legacy_options.anderson_recovery = true;
    const packed_values =
        [_]f64{1} ** chemistry.State.packedComponentCount();

    var payload: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer payload.deinit();
    try payload.writer.writeAll(std.mem.asBytes(&context));
    try payload.writer.writeAll(std.mem.asBytes(&parameters));
    try payload.writer.writeAll(std.mem.asBytes(&legacy_options));
    try payload.writer.writeAll(std.mem.asBytes(&packed_values));

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try encoded.writer.writeAll(magic);
    try encoded.writer.writeInt(u32, legacy_format_version, .little);
    try encoded.writer.writeInt(u64, payload.written().len, .little);
    try encoded.writer.writeInt(
        u64,
        std.hash.Wyhash.hash(checksum_seed, payload.written()),
        .little,
    );
    try encoded.writer.writeAll(payload.written());

    var reader: std.Io.Reader = .fixed(encoded.written());
    var restored = try read(std.testing.allocator, &reader);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 19), restored.context.scene_hour);
    try std.testing.expectEqual(
        legacy_options.absolute_tolerance,
        restored.options.absolute_tolerance_mol_per_m3,
    );
    try std.testing.expectEqual(
        legacy_options.absolute_tolerance,
        restored.options.absolute_tolerance_mol_per_megagram,
    );
    try std.testing.expectEqual(
        legacy_options.relative_tolerance,
        restored.options.relative_tolerance,
    );
    try std.testing.expectEqual(
        legacy_options.max_iterations,
        restored.options.max_iterations,
    );
    try std.testing.expectEqual(
        legacy_options.anderson_recovery,
        restored.options.anderson_recovery,
    );
}

test "v1 expanded solute snapshot preserves distinct unit tolerances" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(LegacyOptionsV1));
    try std.testing.expectEqual(
        @as(usize, 72),
        @sizeOf(OptionsWithUnitTolerances),
    );

    var context = std.mem.zeroes(Context);
    context.scene_hour = 27;
    var parameters = std.mem.zeroes(chemistry.ReactionParameters);
    var snapshot_options = std.mem.zeroes(OptionsWithUnitTolerances);
    snapshot_options.absolute_tolerance_mol_per_m3 = 2.0e-9;
    snapshot_options.absolute_tolerance_mol_per_megagram = 7.0e-12;
    snapshot_options.relative_tolerance = 4.0e-8;
    snapshot_options.picard_relaxation = 0.35;
    snapshot_options.directional_probe_fraction = 0.4;
    snapshot_options.minimum_newton_fraction = 0.01;
    snapshot_options.maximum_newton_fraction = 0.9;
    snapshot_options.max_iterations = 71;
    snapshot_options.divergence_patience = 7;
    snapshot_options.divergence_growth_factor = 800;
    snapshot_options.anderson_recovery = true;
    const packed_values =
        [_]f64{1} ** chemistry.State.packedComponentCount();

    var payload: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer payload.deinit();
    try payload.writer.writeAll(std.mem.asBytes(&context));
    try payload.writer.writeAll(std.mem.asBytes(&parameters));
    try payload.writer.writeAll(std.mem.asBytes(&snapshot_options));
    try payload.writer.writeAll(std.mem.asBytes(&packed_values));

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try encoded.writer.writeAll(magic);
    try encoded.writer.writeInt(u32, legacy_format_version, .little);
    try encoded.writer.writeInt(u64, payload.written().len, .little);
    try encoded.writer.writeInt(
        u64,
        std.hash.Wyhash.hash(checksum_seed, payload.written()),
        .little,
    );
    try encoded.writer.writeAll(payload.written());

    var reader: std.Io.Reader = .fixed(encoded.written());
    var restored = try read(std.testing.allocator, &reader);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 27), restored.context.scene_hour);
    try std.testing.expectEqual(
        snapshot_options.absolute_tolerance_mol_per_m3,
        restored.options.absolute_tolerance_mol_per_m3,
    );
    try std.testing.expectEqual(
        snapshot_options.absolute_tolerance_mol_per_megagram,
        restored.options.absolute_tolerance_mol_per_megagram,
    );
    try std.testing.expectEqual(
        snapshot_options.relative_tolerance,
        restored.options.relative_tolerance,
    );
    try std.testing.expectEqual(
        snapshot_options.max_iterations,
        restored.options.max_iterations,
    );
    try std.testing.expectEqual(
        snapshot_options.anderson_recovery,
        restored.options.anderson_recovery,
    );
}

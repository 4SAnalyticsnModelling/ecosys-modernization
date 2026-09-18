const std = @import("std");
const GroundAir = @import("../../surface/ground_air_exchange.zig").State;
const SurfaceAerodynamics = @import("../../surface/aerodynamics.zig").State;
const AtmosphericCarrier = @import("../../atmosphere/canopy_gas_state.zig");

pub const ground_air_field_count: usize = 4;
pub const aerodynamic_field_count: usize = 5;

pub const View = struct {
    ground_air: *const GroundAir,
    surface_aerodynamics: *const SurfaceAerodynamics,
    atmospheric_carrier: *const AtmosphericCarrier.State,
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    ground_air_fields: [ground_air_field_count][]f64,
    ground_air_iteration_count: []u16,
    aerodynamic_fields: [aerodynamic_field_count][]f64,
    atmospheric_carrier_fields: [AtmosphericCarrier.persisted_field_count][]f64,

    pub fn deinit(self: *Snapshot) void {
        for (self.atmospheric_carrier_fields) |values| self.allocator.free(values);
        for (self.aerodynamic_fields) |values| self.allocator.free(values);
        self.allocator.free(self.ground_air_iteration_count);
        for (self.ground_air_fields) |values| self.allocator.free(values);
        self.* = undefined;
    }

    pub fn validate(self: Snapshot) !void {
        if (self.cell_count == 0 or
            self.ground_air_iteration_count.len != self.cell_count)
            return error.SurfaceBoundaryCheckpointDimensionMismatch;
        for (self.ground_air_fields) |values| {
            if (values.len != self.cell_count)
                return error.SurfaceBoundaryCheckpointDimensionMismatch;
            try validateFinite(values);
        }
        for (self.aerodynamic_fields) |values| {
            if (values.len != self.cell_count)
                return error.SurfaceBoundaryCheckpointDimensionMismatch;
            try validateFinite(values);
        }
        for (self.atmospheric_carrier_fields) |values| {
            if (values.len != self.cell_count)
                return error.SurfaceBoundaryCheckpointDimensionMismatch;
            try validateFinite(values);
        }
        for (0..self.cell_count) |cell| {
            if (self.ground_air_fields[0][cell] <= 0 or
                self.ground_air_fields[1][cell] < 0 or
                self.ground_air_fields[2][cell] <= 0 or
                self.ground_air_fields[3][cell] <= 0 or
                self.aerodynamic_fields[0][cell] < 0 or
                self.aerodynamic_fields[1][cell] <= 0 or
                self.aerodynamic_fields[2][cell] <= 0 or
                self.aerodynamic_fields[3][cell] < 0 or
                self.aerodynamic_fields[4][cell] < 0 or
                self.atmospheric_carrier_fields[0][cell] <= 0 or
                self.atmospheric_carrier_fields[1][cell] < 0 or
                self.atmospheric_carrier_fields[2][cell] < 0 or
                self.atmospheric_carrier_fields[3][cell] < 0 or
                self.atmospheric_carrier_fields[4][cell] < 0 or
                self.atmospheric_carrier_fields[5][cell] < 0)
                return error.InvalidSurfaceBoundaryCheckpointState;
        }
    }

    pub fn restoreInto(
        self: Snapshot,
        ground_air: *GroundAir,
        surface_aerodynamics: *SurfaceAerodynamics,
        atmospheric_carrier: *AtmosphericCarrier.State,
    ) !void {
        try self.validate();
        try validateTargetDimensions(.{
            .ground_air = ground_air,
            .surface_aerodynamics = surface_aerodynamics,
            .atmospheric_carrier = atmospheric_carrier,
        });
        if (ground_air.cell_count != self.cell_count)
            return error.SurfaceBoundaryCheckpointDimensionMismatch;
        inline for (groundAirFields(ground_air), self.ground_air_fields) |target, source|
            @memcpy(target, source);
        @memcpy(ground_air.iteration_count, self.ground_air_iteration_count);
        inline for (
            aerodynamicFields(surface_aerodynamics),
            self.aerodynamic_fields,
        ) |target, source| @memcpy(target, source);
        inline for (
            AtmosphericCarrier.persistedFields(atmospheric_carrier),
            self.atmospheric_carrier_fields,
        ) |target, source| @memcpy(target, source);
    }
};

pub fn write(writer: anytype, view: View) !void {
    try validateView(view);
    try writer.writeInt(u64, @intCast(view.ground_air.cell_count), .little);
    inline for (groundAirConstFields(view.ground_air)) |values|
        try writeF64Slice(writer, values);
    for (view.ground_air.iteration_count) |value|
        try writer.writeInt(u16, value, .little);
    inline for (aerodynamicConstFields(view.surface_aerodynamics)) |values|
        try writeF64Slice(writer, values);
    inline for (AtmosphericCarrier.persistedConstFields(view.atmospheric_carrier)) |values|
        try writeF64Slice(writer, values);
}

pub fn read(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    expected_cell_count: usize,
) !Snapshot {
    if (try reader.takeInt(u64, .little) != expected_cell_count)
        return error.SurfaceBoundaryCheckpointDimensionMismatch;
    var result: Snapshot = .{
        .allocator = allocator,
        .cell_count = expected_cell_count,
        .ground_air_fields = undefined,
        .ground_air_iteration_count = undefined,
        .aerodynamic_fields = undefined,
        .atmospheric_carrier_fields = undefined,
    };
    var ground_allocated: usize = 0;
    var aerodynamic_allocated: usize = 0;
    var iterations_allocated = false;
    var carrier_allocated: usize = 0;
    errdefer {
        for (result.atmospheric_carrier_fields[0..carrier_allocated]) |values|
            allocator.free(values);
        for (result.aerodynamic_fields[0..aerodynamic_allocated]) |values|
            allocator.free(values);
        if (iterations_allocated) allocator.free(result.ground_air_iteration_count);
        for (result.ground_air_fields[0..ground_allocated]) |values|
            allocator.free(values);
    }
    for (&result.ground_air_fields) |*values| {
        values.* = try allocator.alloc(f64, expected_cell_count);
        ground_allocated += 1;
        try readF64Slice(reader, values.*);
    }
    result.ground_air_iteration_count =
        try allocator.alloc(u16, expected_cell_count);
    iterations_allocated = true;
    for (result.ground_air_iteration_count) |*value|
        value.* = try reader.takeInt(u16, .little);
    for (&result.aerodynamic_fields) |*values| {
        values.* = try allocator.alloc(f64, expected_cell_count);
        aerodynamic_allocated += 1;
        try readF64Slice(reader, values.*);
    }
    for (&result.atmospheric_carrier_fields) |*values| {
        values.* = try allocator.alloc(f64, expected_cell_count);
        carrier_allocated += 1;
        try readF64Slice(reader, values.*);
    }
    try result.validate();
    return result;
}

pub fn validateView(view: View) !void {
    try validateTargetDimensions(view);
    const cells = view.ground_air.cell_count;
    inline for (groundAirConstFields(view.ground_air)) |values|
        try validateFinite(values);
    inline for (aerodynamicConstFields(view.surface_aerodynamics)) |values|
        try validateFinite(values);
    inline for (AtmosphericCarrier.persistedConstFields(view.atmospheric_carrier)) |values|
        try validateFinite(values);
    for (0..cells) |cell| {
        if (view.ground_air.temperature_k[cell] <= 0 or
            view.ground_air.vapor_volume_fraction[cell] < 0 or
            view.ground_air.heat_capacity_megajoules_per_k[cell] <= 0 or
            view.ground_air.air_volume_m3[cell] <= 0 or
            view.surface_aerodynamics.zero_plane_displacement_m[cell] < 0 or
            view.surface_aerodynamics.effective_roughness_height_m[cell] <= 0 or
            view.surface_aerodynamics.wind_reference_height_m[cell] <= 0 or
            view.surface_aerodynamics.bulk_richardson_coefficient_k[cell] < 0 or
            view.surface_aerodynamics.isothermal_aerodynamic_resistance_h_per_m[cell] < 0 or
            view.atmospheric_carrier.bulk_temperature_k[cell] <= 0 or
            view.atmospheric_carrier.bulk_vapor_m3_per_m3[cell] < 0 or
            view.atmospheric_carrier.canopy_co2_umol_mol[cell] < 0 or
            view.atmospheric_carrier.canopy_ch4_umol_mol[cell] < 0 or
            view.atmospheric_carrier.canopy_o2_umol_mol[cell] < 0 or
            view.atmospheric_carrier.canopy_oxygen_content_g_o[cell] < 0)
            return error.InvalidSurfaceBoundaryCheckpointState;
    }
}

pub fn validateTargetDimensions(view: View) !void {
    const cells = view.ground_air.cell_count;
    if (cells == 0 or view.surface_aerodynamics.cell_count != cells or
        view.atmospheric_carrier.cell_count != cells or
        view.ground_air.iteration_count.len != cells)
        return error.SurfaceBoundaryCheckpointDimensionMismatch;
    inline for (groundAirConstFields(view.ground_air)) |values|
        if (values.len != cells)
            return error.SurfaceBoundaryCheckpointDimensionMismatch;
    inline for (aerodynamicConstFields(view.surface_aerodynamics)) |values|
        if (values.len != cells)
            return error.SurfaceBoundaryCheckpointDimensionMismatch;
    inline for (AtmosphericCarrier.persistedConstFields(view.atmospheric_carrier)) |values|
        if (values.len != cells)
            return error.SurfaceBoundaryCheckpointDimensionMismatch;
}

fn groundAirConstFields(state: *const GroundAir) [ground_air_field_count][]const f64 {
    return .{
        state.temperature_k,
        state.vapor_volume_fraction,
        state.heat_capacity_megajoules_per_k,
        state.air_volume_m3,
    };
}

fn groundAirFields(state: *GroundAir) [ground_air_field_count][]f64 {
    return .{
        state.temperature_k,
        state.vapor_volume_fraction,
        state.heat_capacity_megajoules_per_k,
        state.air_volume_m3,
    };
}

fn aerodynamicConstFields(
    state: *const SurfaceAerodynamics,
) [aerodynamic_field_count][]const f64 {
    return .{
        state.zero_plane_displacement_m,
        state.effective_roughness_height_m,
        state.wind_reference_height_m,
        state.bulk_richardson_coefficient_k,
        state.isothermal_aerodynamic_resistance_h_per_m,
    };
}

fn aerodynamicFields(
    state: *SurfaceAerodynamics,
) [aerodynamic_field_count][]f64 {
    return .{
        state.zero_plane_displacement_m,
        state.effective_roughness_height_m,
        state.wind_reference_height_m,
        state.bulk_richardson_coefficient_k,
        state.isothermal_aerodynamic_resistance_h_per_m,
    };
}

fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value))
            return error.NonFiniteSurfaceBoundaryCheckpoint;
        try writer.writeInt(u64, @bitCast(value), .little);
    }
}

fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*))
            return error.NonFiniteSurfaceBoundaryCheckpoint;
    }
}

fn validateFinite(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value))
        return error.NonFiniteSurfaceBoundaryCheckpoint;
}

/// A minimal owner for the three states this section persists.
///
/// The field arrays are allocated directly and the `State` structs are wired to
/// point at them, rather than going through each state's own `init`.
/// `GroundAir.init` requires a fully populated `Parameters` that this section
/// never reads, and `SurfaceAerodynamics.init` seeds values this test
/// immediately overwrites. Mirrors `TestSurfaceBoundary` in
/// `soil_geometry_checkpoint.zig`, which builds the same three states the same
/// way for the enclosing section's tests.
const RoundTripStates = struct {
    allocator: std.mem.Allocator,
    ground_air: GroundAir,
    aerodynamics: SurfaceAerodynamics,
    atmospheric_carrier: AtmosphericCarrier.State,
    ground_fields: [ground_air_field_count][]f64,
    iterations: []u16,
    aerodynamic_fields: [aerodynamic_field_count][]f64,

    fn init(allocator: std.mem.Allocator, cell_count: usize, seed: f64) !RoundTripStates {
        var result: RoundTripStates = undefined;
        result.allocator = allocator;
        var ground_allocated: usize = 0;
        var aerodynamic_allocated: usize = 0;
        var iterations_allocated = false;
        errdefer {
            for (result.aerodynamic_fields[0..aerodynamic_allocated]) |values|
                allocator.free(values);
            if (iterations_allocated) allocator.free(result.iterations);
            for (result.ground_fields[0..ground_allocated]) |values|
                allocator.free(values);
        }
        for (&result.ground_fields) |*values| {
            values.* = try allocator.alloc(f64, cell_count);
            ground_allocated += 1;
        }
        result.iterations = try allocator.alloc(u16, cell_count);
        iterations_allocated = true;
        for (&result.aerodynamic_fields) |*values| {
            values.* = try allocator.alloc(f64, cell_count);
            aerodynamic_allocated += 1;
        }
        result.ground_air = undefined;
        result.ground_air.cell_count = cell_count;
        result.ground_air.temperature_k = result.ground_fields[0];
        result.ground_air.vapor_volume_fraction = result.ground_fields[1];
        result.ground_air.heat_capacity_megajoules_per_k = result.ground_fields[2];
        result.ground_air.air_volume_m3 = result.ground_fields[3];
        result.ground_air.iteration_count = result.iterations;
        result.aerodynamics = undefined;
        result.aerodynamics.cell_count = cell_count;
        result.aerodynamics.zero_plane_displacement_m = result.aerodynamic_fields[0];
        result.aerodynamics.effective_roughness_height_m = result.aerodynamic_fields[1];
        result.aerodynamics.wind_reference_height_m = result.aerodynamic_fields[2];
        result.aerodynamics.bulk_richardson_coefficient_k = result.aerodynamic_fields[3];
        result.aerodynamics.isothermal_aerodynamic_resistance_h_per_m =
            result.aerodynamic_fields[4];

        const temperatures = try allocator.alloc(f64, cell_count);
        defer allocator.free(temperatures);
        const vapors = try allocator.alloc(f64, cell_count);
        defer allocator.free(vapors);
        const MixingRatios =
            @import("../../atmosphere/atmospheric_gas_mass_concentration.zig").MixingRatios;
        const ratios = try allocator.alloc(MixingRatios, cell_count);
        defer allocator.free(ratios);
        for (0..cell_count) |cell| {
            const cell_f: f64 = @floatFromInt(cell);
            temperatures[cell] = 275 + seed + 2 * cell_f;
            vapors[cell] = 0.004 + 0.0001 * (seed + cell_f);
            // EVERY ratio carries `seed`, not just carbon dioxide. The first
            // draft seeded only CO2, temperature and vapor, which left
            // `canopy_ch4_umol_mol` and `canopy_o2_umol_mol` identical between
            // the source and the target -- and the vacuity guard below caught
            // it. Those two would then have compared equal after a restore
            // that never touched them.
            ratios[cell] = .{
                .carbon_dioxide_umol_mol = 390 + seed + 11 * cell_f,
                .methane_umol_mol = 1.7 + 0.1 * (seed + cell_f),
                .oxygen_umol_mol = 180_000 + 7_000 * (seed + cell_f),
                .nitrogen_umol_mol = 780_000 - 4_000 * (seed + cell_f),
                .nitrous_oxide_umol_mol = 0.30 + 0.01 * (seed + cell_f),
                .ammonia_umol_mol = 0.01 + 0.02 * (seed + cell_f),
                .hydrogen_umol_mol = 0.001 + 0.0005 * (seed + cell_f),
            };
        }
        result.atmospheric_carrier = try AtmosphericCarrier.State.init(
            allocator,
            temperatures,
            vapors,
            ratios,
        );

        // Every persisted array gets a DISTINCT, admissible value per field and
        // per cell, so a field that is written into the wrong slot, or dropped,
        // cannot coincidentally match. `seed` separates the source states from
        // the restore targets.
        for (0..cell_count) |cell| {
            const cell_f: f64 = @floatFromInt(cell);
            result.ground_air.temperature_k[cell] = 281.5 + seed + cell_f;
            result.ground_air.vapor_volume_fraction[cell] = 0.0031 + 0.0002 * (seed + cell_f);
            result.ground_air.heat_capacity_megajoules_per_k[cell] = 0.42 + 0.01 * (seed + cell_f);
            result.ground_air.air_volume_m3[cell] = 1.75 + 0.05 * (seed + cell_f);
            result.ground_air.iteration_count[cell] = @intFromFloat(3 + seed + cell_f);
            result.aerodynamics.zero_plane_displacement_m[cell] = 0.07 + 0.01 * (seed + cell_f);
            result.aerodynamics.effective_roughness_height_m[cell] = 0.011 + 0.002 * (seed + cell_f);
            result.aerodynamics.wind_reference_height_m[cell] = 2.4 + 0.1 * (seed + cell_f);
            result.aerodynamics.bulk_richardson_coefficient_k[cell] = 0.19 + 0.02 * (seed + cell_f);
            result.aerodynamics.isothermal_aerodynamic_resistance_h_per_m[cell] =
                0.0044 + 0.0003 * (seed + cell_f);
        }
        // Four carriers that `State.init` zeroes rather than deriving from the
        // mixing ratios, so they must be seeded here or they would be identical
        // in both fixtures. `canopy_oxygen_content_g_o` (index 5) was the
        // second thing the vacuity guard caught.
        //
        // Indices 6-8 are the cumulative exchanges, which `validate`
        // deliberately does NOT bound below by zero because they are signed net
        // quantities. Seeding two of them negative is what proves the sign
        // survives the round trip; index 5 must stay non-negative, which
        // `validate` does require.
        const carrier = AtmosphericCarrier.persistedFields(&result.atmospheric_carrier);
        for (0..cell_count) |cell| {
            const cell_f: f64 = @floatFromInt(cell);
            carrier[5][cell] = 240 + seed + 3 * cell_f;
            carrier[6][cell] = -(1.5 + seed + cell_f);
            carrier[7][cell] = -(0.25 + 0.1 * (seed + cell_f));
            carrier[8][cell] = 2.75 + seed + cell_f;
        }
        return result;
    }

    fn deinit(self: *RoundTripStates) void {
        self.atmospheric_carrier.deinit();
        for (self.aerodynamic_fields) |values| self.allocator.free(values);
        self.allocator.free(self.iterations);
        for (self.ground_fields) |values| self.allocator.free(values);
        self.* = undefined;
    }

    fn view(self: *const RoundTripStates) View {
        return .{
            .ground_air = &self.ground_air,
            .surface_aerodynamics = &self.aerodynamics,
            .atmospheric_carrier = &self.atmospheric_carrier,
        };
    }
};

test "surface boundary checkpoint round trip restores every persisted field" {
    // This module had NO tests of its own. `soil_geometry_checkpoint.zig` calls
    // its `write` (:286) and `read` (:442) inside the enclosing section, and
    // mutates five of these fields before the round trip -- but measured
    // 2026-09-12, NOT ONE of that module's tests asserts a surface-boundary
    // field survives, and 13 of the 18 persisted arrays are never even
    // mutated. So the code path was executed and never checked: dropping a
    // field would have been invisible.
    const cell_count = 4;
    var source = try RoundTripStates.init(std.testing.allocator, cell_count, 0);
    defer source.deinit();
    // Different seed, so every target value differs from its source.
    var target = try RoundTripStates.init(std.testing.allocator, cell_count, 5);
    defer target.deinit();

    // Vacuity guard, asserted BEFORE the restore. If the two fixtures happened
    // to agree, the equality checks below would pass without the restore doing
    // anything at all.
    inline for (groundAirConstFields(&source.ground_air), groundAirConstFields(&target.ground_air)) |a, b|
        for (a, b) |x, y| try std.testing.expect(x != y);
    inline for (aerodynamicConstFields(&source.aerodynamics), aerodynamicConstFields(&target.aerodynamics)) |a, b|
        for (a, b) |x, y| try std.testing.expect(x != y);
    inline for (
        AtmosphericCarrier.persistedConstFields(&source.atmospheric_carrier),
        AtmosphericCarrier.persistedConstFields(&target.atmospheric_carrier),
    ) |a, b| for (a, b) |x, y| try std.testing.expect(x != y);
    for (source.ground_air.iteration_count, target.ground_air.iteration_count) |x, y|
        try std.testing.expect(x != y);

    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, source.view());
    var reader: std.Io.Reader = .fixed(bytes.written());
    var snapshot = try read(std.testing.allocator, &reader, cell_count);
    defer snapshot.deinit();
    try snapshot.restoreInto(
        &target.ground_air,
        &target.aerodynamics,
        &target.atmospheric_carrier,
    );

    // Bit-exact, not approximate: this is serialization, and `writeF64Slice`
    // stores the raw bit pattern, so anything other than equality is a defect.
    inline for (groundAirConstFields(&source.ground_air), groundAirConstFields(&target.ground_air)) |a, b|
        try std.testing.expectEqualSlices(f64, a, b);
    inline for (aerodynamicConstFields(&source.aerodynamics), aerodynamicConstFields(&target.aerodynamics)) |a, b|
        try std.testing.expectEqualSlices(f64, a, b);
    inline for (
        AtmosphericCarrier.persistedConstFields(&source.atmospheric_carrier),
        AtmosphericCarrier.persistedConstFields(&target.atmospheric_carrier),
    ) |a, b| try std.testing.expectEqualSlices(f64, a, b);
    try std.testing.expectEqualSlices(
        u16,
        source.ground_air.iteration_count,
        target.ground_air.iteration_count,
    );

    // The signed cumulative carriers kept their sign. Checked explicitly
    // because `validate` deliberately does not bound them below by zero, so a
    // sign error here would pass every validator in this file.
    const restored_carrier = AtmosphericCarrier.persistedFields(&target.atmospheric_carrier);
    try std.testing.expect(restored_carrier[6][0] < 0);
    try std.testing.expect(restored_carrier[7][0] < 0);
}

test "surface boundary checkpoint rejects a cell-count disagreement and a short read" {
    var source = try RoundTripStates.init(std.testing.allocator, 3, 0);
    defer source.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, source.view());

    // A reader expecting a different cell count must fail on the header rather
    // than allocate and misinterpret the payload.
    var wrong: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(
        error.SurfaceBoundaryCheckpointDimensionMismatch,
        read(std.testing.allocator, &wrong, 4),
    );

    // A truncated payload must fail rather than return a partly populated
    // snapshot. Cutting the last byte cannot be absorbed by any field.
    const written = bytes.written();
    var truncated: std.Io.Reader = .fixed(written[0 .. written.len - 1]);
    try std.testing.expectError(
        error.EndOfStream,
        read(std.testing.allocator, &truncated, 3),
    );
}

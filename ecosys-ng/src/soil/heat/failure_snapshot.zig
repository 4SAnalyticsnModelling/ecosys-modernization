//! Self-contained diagnostic input to one heat solve. The JSON schema follows
//! the named scientific fields; missing/extra fields fail closed after changes.
//! Allocators, read-only diagnostics and test hooks are never serialized.
const std = @import("std");
const types = @import("solver_types.zig");
const grid_module = @import("../../state/grid.zig");

pub const maximum_bytes = 16 * 1024 * 1024;
pub const file_name = "ecosys-ng-heat-failure.json";
pub const Input = struct {
    grid: grid_module.GridState,
    faces: []const types.Face,
    properties: types.Properties,
    water_fluxes: types.WaterHeatFluxes,
    options: types.Options,
};

fn omitted(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "allocator") or
        std.mem.eql(u8, name, "diagnostic_trace") or
        std.mem.eql(u8, name, "recovery_routing_test_control") or
        std.mem.eql(u8, name, "failure_report_io");
}

fn writeData(stream: *std.json.Stringify, value: anytype) std.json.Stringify.Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |info| {
            try stream.beginObject();
            inline for (info.fields) |field| {
                if (comptime !omitted(field.name)) {
                    try stream.objectField(field.name);
                    try writeData(stream, @field(value, field.name));
                }
            }
            try stream.endObject();
        },
        .optional => if (value) |present| try writeData(stream, present) else try stream.write(null),
        .pointer => |pointer| switch (pointer.size) {
            .one => try writeData(stream, value.*),
            .slice => {
                try stream.beginArray();
                for (value) |element| try writeData(stream, element);
                try stream.endArray();
            },
            else => @compileError("unsupported heat snapshot pointer"),
        },
        .array => {
            try stream.beginArray();
            for (value) |element| try writeData(stream, element);
            try stream.endArray();
        },
        else => try stream.write(value),
    }
}

const Envelope = struct {
    input: Input,
    pub fn jsonStringify(self: Envelope, stream: *std.json.Stringify) !void {
        try stream.beginObject();
        try stream.objectField("format");
        try stream.write("ecosys-heat-v1");
        try stream.objectField("input");
        try writeData(stream, self.input);
        try stream.endObject();
    }
};

pub fn encode(allocator: std.mem.Allocator, input: Input) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, Envelope{ .input = input }, .{});
}

fn readData(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (value != .object) return error.InvalidHeatSnapshotShape;
            var result: T = undefined;
            var expected: usize = 0;
            inline for (info.fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "allocator")) {
                    @field(result, field.name) = allocator;
                } else if (comptime omitted(field.name)) {
                    @field(result, field.name) = null;
                } else {
                    expected += 1;
                    @field(result, field.name) = try readData(field.type, allocator, value.object.get(field.name) orelse return error.HeatSnapshotSchemaMismatch);
                }
            }
            if (value.object.count() != expected) return error.HeatSnapshotSchemaMismatch;
            return result;
        },
        .optional => |optional| return if (value == .null) null else try readData(optional.child, allocator, value),
        .pointer => |pointer| switch (pointer.size) {
            .one => {
                const result = try allocator.create(pointer.child);
                result.* = try readData(pointer.child, allocator, value);
                return result;
            },
            .slice => {
                if (value != .array or value.array.items.len > 1_000_000) return error.InvalidHeatSnapshotShape;
                const result = try allocator.alloc(pointer.child, value.array.items.len);
                for (result, value.array.items) |*out, element| out.* = try readData(pointer.child, allocator, element);
                return result;
            },
            else => @compileError("unsupported heat snapshot pointer"),
        },
        .array => |array| {
            if (value != .array or value.array.items.len != array.len) return error.InvalidHeatSnapshotShape;
            var result: T = undefined;
            for (&result, value.array.items) |*out, element| out.* = try readData(array.child, allocator, element);
            return result;
        },
        else => return std.json.parseFromValueLeaky(T, allocator, value, .{}),
    }
}

/// All returned storage belongs to the caller's arena. Do not call grid.deinit.
pub fn decode(arena: std.mem.Allocator, bytes: []const u8) !Input {
    if (bytes.len > maximum_bytes) return error.HeatSnapshotTooLarge;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (value != .object or value.object.count() != 2) return error.InvalidHeatSnapshotShape;
    const format = value.object.get("format") orelse return error.HeatSnapshotSchemaMismatch;
    if (format != .string or !std.mem.eql(u8, format.string, "ecosys-heat-v1")) return error.HeatSnapshotSchemaMismatch;
    const result = try readData(Input, arena, value.object.get("input") orelse return error.HeatSnapshotSchemaMismatch);
    const grid = result.grid;
    if (grid.cell_count == 0 or grid.soil_layer_capacity == 0 or
        grid.layer_count != try std.math.mul(usize, grid.cell_count, grid.soil_layer_capacity)) return error.InvalidHeatSnapshotShape;
    inline for (@typeInfo(grid_module.GridState).@"struct".fields) |field| {
        if (field.type == []f64 or field.type == []usize) {
            const count = if (comptime std.mem.eql(u8, field.name, "surface_temperature_k") or
                std.mem.eql(u8, field.name, "active_soil_layer_count") or
                std.mem.eql(u8, field.name, "maximum_rooting_layer_count")) grid.cell_count else grid.layer_count;
            if (@field(grid, field.name).len != count) return error.InvalidHeatSnapshotShape;
        }
    }
    return result;
}

/// Called only after rejection, while grid and coupling still hold solve-entry
/// state. Atomic replacement retains the latest failed bounded attempt.
pub fn report(io: std.Io, allocator: std.mem.Allocator, input: Input) !void {
    return reportTo(io, allocator, input, file_name, true);
}

/// Temporary first-day science diagnostic; separate from terminal failures.
/// The first cold entry can belong to a subsequently rejected hourly attempt.
pub fn reportFirstColdInput(io: std.Io, allocator: std.mem.Allocator, input: Input) !void {
    const path = "ecosys-ng-first-cold-heat.json";
    const existing = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return reportTo(io, allocator, input, path, false),
        else => return err,
    };
    existing.close(io);
}

fn reportTo(io: std.Io, allocator: std.mem.Allocator, input: Input, path: []const u8, replace: bool) !void {
    const bytes = try encode(allocator, input);
    defer allocator.free(bytes);
    if (bytes.len > maximum_bytes) return error.HeatSnapshotTooLarge;
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = replace });
    defer file.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try file.file.sync(io);
    try file.replace(io);
}

test "heat failure snapshot round trips sensible heat inputs and reproduces a solve" {
    const config = @import("../../core/config.zig");
    const solve = @import("solver_solve.zig").solve;
    const cfg = try config.SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-10, .max_nonlinear_iterations = 16 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 270;
    const input: Input = .{ .grid = grid, .faces = &.{.{ .source_cell = 0, .destination_cell = 1, .source_path_length_m = 0.1, .destination_path_length_m = 0.1, .face_area_m2 = 1 }}, .properties = @import("solver_fixtures.zig").testProperties(), .water_fluxes = .{ .liquid_water_m3 = &.{0}, .vapor_m3 = &.{0}, .macropore_water_m3 = &.{0} }, .options = .{ .max_iterations = 16 } };
    const bytes = try encode(std.testing.allocator, input);
    defer std.testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var replay = try decode(arena.allocator(), bytes);
    const again = try encode(std.testing.allocator, replay);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
    var original_flux: [1]f64 = undefined;
    var replay_flux: [1]f64 = undefined;
    const original = try solve(std.testing.allocator, &grid, input.faces, input.properties, input.water_fluxes, &original_flux, input.options);
    const result = try solve(std.testing.allocator, &replay.grid, replay.faces, replay.properties, replay.water_fluxes, &replay_flux, replay.options);
    try std.testing.expectEqualDeep(original, result);
    try std.testing.expectEqualSlices(f64, grid.soil_temperature_k, replay.grid.soil_temperature_k);
    try std.testing.expectEqualSlices(f64, &original_flux, &replay_flux);
}

test "Ottawa hour635 captured heat input closes within its original budget" {
    try expectCapturedHeatInputCloses(@embedFile("ottawa_hour635_failure.json"));
}

test "Ottawa day29 heat retry closes without a storage-normalization barrier" {
    try expectCapturedHeatInputCloses(@embedFile("ottawa_day29_heat_retry.json"));
}

test "heat evaluation cache is bitwise identical and resets between captured solves" {
    const allocator = std.testing.allocator;
    var cached = try types.Workspace.init(allocator, 12, 11, 256);
    defer cached.deinit();
    var uncached = try types.Workspace.init(allocator, 12, 11, 256);
    defer uncached.deinit();
    uncached.enthalpy_evaluation_cache.?.deinit(allocator);
    uncached.enthalpy_evaluation_cache = null;
    // Reuse one workspace across different water/retention/temperature inputs,
    // then revisit the first input. No cached parameter may cross a solve.
    for ([_][]const u8{
        @embedFile("ottawa_day29_heat_retry.json"),
        @embedFile("ottawa_hour635_failure.json"),
        @embedFile("ottawa_day29_heat_retry.json"),
    }) |bytes| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var a = try decode(arena.allocator(), bytes);
        var b = try decode(arena.allocator(), bytes);
        var a_flux: [11]f64 = undefined;
        var b_flux: [11]f64 = undefined;
        const solve = @import("solver_solve.zig").solveWithWorkspace;
        const a_result = try solve(&cached, &a.grid, a.faces, a.properties, a.water_fluxes, &a_flux, a.options);
        const b_result = try solve(&uncached, &b.grid, b.faces, b.properties, b.water_fluxes, &b_flux, b.options);
        try std.testing.expectEqualDeep(b_result, a_result);
        inline for (std.meta.fields(types.Result)) |field| {
            if (field.type == f64)
                try std.testing.expectEqual(@as(u64, @bitCast(@field(b_result, field.name))), @as(u64, @bitCast(@field(a_result, field.name))));
        }
        inline for (std.meta.fields(grid_module.GridState)) |field| {
            if (field.type == []f64)
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(@field(b.grid, field.name)), std.mem.sliceAsBytes(@field(a.grid, field.name)));
        }
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&b_flux), std.mem.asBytes(&a_flux));
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(uncached.accepted_conservation_representability_megajoules), std.mem.sliceAsBytes(cached.accepted_conservation_representability_megajoules));
        try std.testing.expect(cached.enthalpy_evaluation_cache.?.parameter_misses > 0);
        try std.testing.expect(cached.enthalpy_evaluation_cache.?.parameter_misses <= a.grid.layer_count);
        try std.testing.expect(cached.enthalpy_evaluation_cache.?.state_hits > 0);
    }
}

fn allocateHeatCacheWorkspace(allocator: std.mem.Allocator) !void {
    var workspace = try types.Workspace.init(allocator, 2, 1, 2);
    defer workspace.deinit();
}

test "heat evaluation cache preserves actual phase for zero non-phase heat" {
    const misc = @import("solver_misc.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var input = try decode(allocator, @embedFile("ottawa_day29_heat_retry.json"));
    const count = input.grid.layer_count;
    const zero = try allocator.alloc(f64, count);
    @memset(zero, 0);
    input.properties.cell_heat_source_megajoules = zero;
    input.properties.geothermal_boundary = null;
    input.properties.dirichlet_thermal_boundaries = null;
    var workspace = try types.Workspace.init(allocator, count, 0, 0);
    const coupling = input.properties.enthalpy_coupling.?;
    const phase: misc.PhaseBuffers = .{
        .matrix_liquid_m3 = workspace.matrix_liquid_m3,
        .matrix_ice_m3 = workspace.matrix_ice_m3,
        .macropore_liquid_m3 = workspace.macropore_liquid_m3,
        .macropore_ice_m3 = workspace.macropore_ice_m3,
        .macropore_enabled = coupling.macropore_mualem_van_genuchten.len != 0,
        .ice_density_megagrams_per_m3 = coupling.ice_density_megagrams_per_m3,
        .evaluation_cache = &workspace.enthalpy_evaluation_cache.?,
    };
    @memcpy(workspace.current, input.grid.soil_temperature_k);
    for ([_]f64{ 0, 0.01, 0.01, 0 }) |offset| {
        workspace.current[0] = input.grid.soil_temperature_k[0] + offset;
        try @import("solver_residual.zig").residualAt(
            &.{},
            input.properties,
            .{ .liquid_water_m3 = &.{}, .vapor_m3 = &.{}, .macropore_water_m3 = &.{} },
            input.grid.soil_temperature_k,
            workspace.current,
            workspace.target,
            workspace.residual,
            workspace.scratch,
            &.{},
            phase,
            input.options,
        );
        try std.testing.expectEqualSlices(f64, coupling.matrix_liquid_water_m3, phase.matrix_liquid_m3);
        try std.testing.expectEqualSlices(f64, coupling.matrix_ice_water_equivalent_m3, phase.matrix_ice_m3);
        try std.testing.expectEqualSlices(f64, coupling.macropore_liquid_water_m3, phase.macropore_liquid_m3);
        try std.testing.expectEqualSlices(f64, coupling.macropore_ice_water_equivalent_m3, phase.macropore_ice_m3);
        for (workspace.residual, input.grid.soil_temperature_k, workspace.current) |actual, base, trial|
            try std.testing.expectEqual(base - trial, actual);
    }
}

test "heat evaluation cache workspace allocation failures release all scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateHeatCacheWorkspace, .{});
}

fn expectCapturedHeatInputCloses(bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var input = try decode(allocator, bytes);
    var workspace = try types.Workspace.init(allocator, input.grid.layer_count, input.faces.len, input.options.dense_newton_max_components);
    const output = try allocator.alloc(f64, input.faces.len);
    const result = try @import("solver_solve.zig").solveWithWorkspace(&workspace, &input.grid, input.faces, input.properties, input.water_fluxes, output, input.options);
    try std.testing.expect(result.iterations <= input.options.max_iterations);
    try std.testing.expect(result.maximum_scaled_conservation_residual <= 1);
    try input.grid.validateFinite();
}

test "heat conductivity reconstructs current bulk phases independent of stale fractions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var input = try decode(allocator, @embedFile("ottawa_hour635_failure.json"));
    const coupling = input.properties.enthalpy_coupling.?;
    const stale = try allocator.alloc(f64, input.grid.layer_count);
    @memset(stale, 0);
    input.properties.liquid_water_fraction = stale;
    input.properties.ice_fraction = stale;
    input.properties.air_fraction = stale;
    input.properties.fraction_of_pore_volume_air_filled = stale;
    const matrix_liquid = try allocator.dupe(f64, coupling.matrix_liquid_water_m3);
    const matrix_ice = try allocator.dupe(f64, coupling.matrix_ice_water_equivalent_m3);
    const macro_liquid = try allocator.dupe(f64, coupling.macropore_liquid_water_m3);
    const macro_ice = try allocator.dupe(f64, coupling.macropore_ice_water_equivalent_m3);
    matrix_liquid[0] = 0.003;
    matrix_ice[0] = 0.001;
    macro_liquid[0] = 0.00001;
    macro_ice[0] = 0.00002;
    const phase: @import("solver_misc.zig").PhaseBuffers = .{
        .matrix_liquid_m3 = matrix_liquid,
        .matrix_ice_m3 = matrix_ice,
        .macropore_liquid_m3 = macro_liquid,
        .macropore_ice_m3 = macro_ice,
        .macropore_enabled = true,
        .ice_density_megagrams_per_m3 = coupling.ice_density_megagrams_per_m3,
    };
    const actual = try @import("solver_enthalpy.zig").cellConductivityInputs(input.properties, 0, 1, phase);
    const bulk_volume = coupling.matrix_pore_capacity_m3[0] /
        coupling.mualem_van_genuchten[0].saturated_water_content_m3_per_m3 +
        coupling.macropore_porous_medium_volume_m3[0];
    const pore_volume = coupling.matrix_pore_capacity_m3[0] +
        coupling.macropore_porous_medium_volume_m3[0] *
            coupling.macropore_mualem_van_genuchten[0].saturated_water_content_m3_per_m3;
    const physical_ice = 0.00102 / coupling.ice_density_megagrams_per_m3;
    const air_volume = pore_volume - 0.00301 - physical_ice;
    try std.testing.expectApproxEqAbs(0.00301 / bulk_volume, actual.liquid_water_fraction, 1e-14);
    try std.testing.expectApproxEqAbs(physical_ice / bulk_volume, actual.ice_fraction, 1e-14);
    try std.testing.expectApproxEqAbs(air_volume / bulk_volume, actual.air_fraction, 1e-14);
    try std.testing.expectApproxEqAbs(air_volume / pore_volume, actual.fraction_of_pore_volume_air_filled, 1e-14);
    matrix_ice[0] = 0;
    macro_ice[0] = 0;
    const thawed = try @import("solver_enthalpy.zig").cellConductivityInputs(input.properties, 0, 1, phase);
    try std.testing.expectEqual(@as(f64, 0), thawed.ice_fraction);
}

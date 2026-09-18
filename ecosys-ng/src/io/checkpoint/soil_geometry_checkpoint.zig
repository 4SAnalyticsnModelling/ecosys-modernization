const std = @import("std");
const Geometry = @import("../../soil/profile/layer_geometry.zig").State;
const Hydrology = @import("../../transport/hydrology.zig").State;
const Surface = @import("../../surface/precipitation.zig").RuntimeState;
const Erosion = @import("../../soil/profile/erosion.zig").RuntimeState;
const Suspended = @import("../../erosion/suspended_constituents.zig");
const Climate = @import("../input/climate_change.zig").State;
const ErodedMinerals = @import("../../soil/profile/erosion_mineral_bridge.zig").State;
const Runtime = @import("soil_runtime_checkpoint.zig");
const SurfaceBoundary = @import("surface_boundary_checkpoint.zig");
const WaterTable = @import("water_table_checkpoint.zig");
const SurfaceLitterGeometry = @import("../../surface/litter_geometry_step.zig").State;
const AdaptiveHourSchedule = @import("../../state/adaptive_hour_schedule.zig").State;

const magic = "ECOSGEOM";
// Version 23 persists the adaptive fixed-hour schedule. Although it changes no
// acceptance criterion, omitting it changes the first attempted substep rung
// after resume and can select a different admissible nonlinear trajectory.
// Version 22 is intentionally rejected because exact replay cannot reconstruct
// these hints from the physical checkpoint state.
const version: u32 = 23;
const test_suspended_layout: Suspended.Layout = .{
    .organic_cnp_count = 1,
    .nitrogen_fertilizer_count = 1,
    .dry_mineral_fertilizer_count = 1,
    .chemistry_live_and_pending_count = 1,
};
const default_adaptive_hour_schedule: AdaptiveHourSchedule = .{};

pub const View = struct {
    geometry: *const Geometry,
    hydrology: *const Hydrology,
    surface: *const Surface,
    erosion: *const Erosion,
    suspended: *const Suspended.State,
    climate: *const Climate,
    eroded_minerals: *const ErodedMinerals,
    runtime: ?Runtime.View,
    surface_boundary: ?SurfaceBoundary.View,
    water_table: ?WaterTable.View = null,
    adaptive_hour_schedule: *const AdaptiveHourSchedule = &default_adaptive_hour_schedule,
    surface_litter_geometry: *const SurfaceLitterGeometry,
    surface_litter_ice_m3: []const f64,
    delayed_live_canopy_combustion_heat_megajoules: []const f64,
    delayed_standing_dead_combustion_heat_megajoules: []const f64,
    delayed_subsurface_combustion_heat_megajoules: []const f64,
    delayed_root_uptake_heat_megajoules: []const f64,
    delayed_surface_combustion_heat_megajoules: []const f64,
};

pub const Limits = struct {
    maximum_columns: usize,
    maximum_rows: usize,
    maximum_soil_layers: usize,
    maximum_snow_layers: usize,
    maximum_plants: usize,
    maximum_suspended_components: usize = 4096,
};

pub const Owned = struct {
    geometry: Geometry,
    hydrology: Hydrology,
    surface: Surface,
    erosion: Erosion,
    suspended: Suspended.State,
    climate: Climate,
    eroded_minerals: ErodedMinerals,
    runtime: Runtime.Snapshot,
    surface_boundary: SurfaceBoundary.Snapshot,
    water_table: ?WaterTable.Snapshot,
    adaptive_hour_schedule: AdaptiveHourSchedule,
    surface_litter_geometry: SurfaceLitterGeometry,
    surface_litter_ice_m3: []f64,
    allocator: std.mem.Allocator,
    delayed_live_canopy_combustion_heat_megajoules: []f64,
    delayed_standing_dead_combustion_heat_megajoules: []f64,
    delayed_subsurface_combustion_heat_megajoules: []f64,
    delayed_root_uptake_heat_megajoules: []f64,
    delayed_surface_combustion_heat_megajoules: []f64,

    pub noinline fn deinit(self: *Owned) void {
        if (self.water_table) |*water_table| water_table.deinit();
        self.surface_litter_geometry.deinit();
        self.surface_boundary.deinit();
        self.allocator.free(self.surface_litter_ice_m3);
        self.runtime.deinit();
        self.allocator.free(self.delayed_surface_combustion_heat_megajoules);
        self.allocator.free(self.delayed_root_uptake_heat_megajoules);
        self.allocator.free(self.delayed_subsurface_combustion_heat_megajoules);
        self.allocator.free(self.delayed_standing_dead_combustion_heat_megajoules);
        self.allocator.free(self.delayed_live_canopy_combustion_heat_megajoules);
        self.eroded_minerals.deinit();
        self.suspended.deinit();
        self.erosion.deinit();
        self.surface.deinit();
        self.hydrology.deinit();
        self.geometry.deinit();
        self.* = undefined;
    }
};

const ReadHeader = struct {
    columns: usize,
    rows: usize,
    soil_layers: usize,
    snow_layers: usize,
    plants: usize,
    cells: usize,
};

/// Owns every allocation made while decoding a checkpoint. Keeping the single
/// error cleanup in `read` prevents each subsequent I/O error edge from
/// cloning all previously registered `errdefer` bodies into one large LLVM
/// function. The reverse order here is the exact registration order used by
/// the former individual `errdefer` statements.
const ReadBuilder = struct {
    allocator: std.mem.Allocator,
    geometry: ?Geometry = null,
    hydrology: ?Hydrology = null,
    surface: ?Surface = null,
    surface_litter_geometry: ?SurfaceLitterGeometry = null,
    erosion: ?Erosion = null,
    eroded_minerals: ?ErodedMinerals = null,
    delayed_live_heat: ?[]f64 = null,
    delayed_dead_heat: ?[]f64 = null,
    delayed_subsurface_heat: ?[]f64 = null,
    delayed_root_uptake_heat: ?[]f64 = null,
    delayed_surface_heat: ?[]f64 = null,
    surface_litter_ice_m3: ?[]f64 = null,
    suspended: ?Suspended.State = null,
    runtime: ?Runtime.Snapshot = null,
    surface_boundary: ?SurfaceBoundary.Snapshot = null,
    water_table: ?WaterTable.Snapshot = null,
    adaptive_hour_schedule: AdaptiveHourSchedule = .{},
    climate: Climate = .{},
    layer_cells: usize = 0,

    noinline fn deinit(self: *ReadBuilder) void {
        if (self.water_table) |*value| value.deinit();
        if (self.surface_boundary) |*value| value.deinit();
        if (self.runtime) |*value| value.deinit();
        if (self.suspended) |*value| value.deinit();
        if (self.surface_litter_ice_m3) |value| self.allocator.free(value);
        if (self.delayed_surface_heat) |value| self.allocator.free(value);
        if (self.delayed_root_uptake_heat) |value| self.allocator.free(value);
        if (self.delayed_subsurface_heat) |value| self.allocator.free(value);
        if (self.delayed_dead_heat) |value| self.allocator.free(value);
        if (self.delayed_live_heat) |value| self.allocator.free(value);
        if (self.eroded_minerals) |*value| value.deinit();
        if (self.erosion) |*value| value.deinit();
        if (self.surface_litter_geometry) |*value| value.deinit();
        if (self.surface) |*value| value.deinit();
        if (self.hydrology) |*value| value.deinit();
        if (self.geometry) |*value| value.deinit();
        self.* = undefined;
    }

    noinline fn allocatePrimary(self: *ReadBuilder, header: ReadHeader) !void {
        self.geometry = try Geometry.init(
            self.allocator,
            header.cells,
            header.soil_layers,
        );
        self.hydrology = try Hydrology.init(
            self.allocator,
            header.columns,
            header.rows,
            header.soil_layers,
            header.snow_layers,
        );
        self.surface = try Surface.init(self.allocator, header.cells);
        self.surface_litter_geometry =
            try SurfaceLitterGeometry.init(self.allocator, header.cells);
        self.erosion = try Erosion.init(
            self.allocator,
            header.columns,
            header.rows,
        );
        self.eroded_minerals = try ErodedMinerals.init(
            self.allocator,
            header.cells,
        );
        self.layer_cells = try std.math.mul(
            usize,
            header.cells,
            header.soil_layers,
        );
        self.delayed_live_heat = try self.allocator.alloc(f64, header.plants);
        self.delayed_dead_heat = try self.allocator.alloc(f64, header.plants);
        self.delayed_subsurface_heat = try self.allocator.alloc(
            f64,
            self.layer_cells,
        );
        self.delayed_root_uptake_heat = try self.allocator.alloc(
            f64,
            self.layer_cells,
        );
        self.delayed_surface_heat = try self.allocator.alloc(f64, header.cells);
        self.surface_litter_ice_m3 = try self.allocator.alloc(f64, header.cells);
    }

    noinline fn finish(self: *ReadBuilder) Owned {
        return .{
            .geometry = self.geometry.?,
            .hydrology = self.hydrology.?,
            .surface = self.surface.?,
            .erosion = self.erosion.?,
            .suspended = self.suspended.?,
            .climate = self.climate,
            .eroded_minerals = self.eroded_minerals.?,
            .runtime = self.runtime.?,
            .surface_boundary = self.surface_boundary.?,
            .water_table = self.water_table,
            .adaptive_hour_schedule = self.adaptive_hour_schedule,
            .surface_litter_geometry = self.surface_litter_geometry.?,
            .surface_litter_ice_m3 = self.surface_litter_ice_m3.?,
            .allocator = self.allocator,
            .delayed_live_canopy_combustion_heat_megajoules = self.delayed_live_heat.?,
            .delayed_standing_dead_combustion_heat_megajoules = self.delayed_dead_heat.?,
            .delayed_subsurface_combustion_heat_megajoules = self.delayed_subsurface_heat.?,
            .delayed_root_uptake_heat_megajoules = self.delayed_root_uptake_heat.?,
            .delayed_surface_combustion_heat_megajoules = self.delayed_surface_heat.?,
        };
    }
};

pub fn write(writer: anytype, view: View) !void {
    try validate(view);
    const runtime = view.runtime orelse
        return error.MissingSoilRuntimeCheckpointState;
    const surface_boundary = view.surface_boundary orelse
        return error.MissingSurfaceBoundaryCheckpointState;
    try writer.writeAll(magic);
    try writer.writeInt(u32, version, .little);
    try writer.writeInt(u64, @intCast(view.hydrology.columns), .little);
    try writer.writeInt(u64, @intCast(view.hydrology.rows), .little);
    try writer.writeInt(u64, @intCast(view.hydrology.soil_layer_capacity), .little);
    try writer.writeInt(u64, @intCast(view.hydrology.snow_layer_capacity), .little);
    try writer.writeInt(u64, @intCast(view.delayed_live_canopy_combustion_heat_megajoules.len), .little);
    try writeUsizeSlice(writer, view.geometry.first_active_layer);
    try writeUsizeSlice(writer, view.geometry.active_layer_count);
    inline for (@typeInfo(Geometry).@"struct".fields) |field| {
        if (field.type == []f64) try writeF64Slice(writer, @field(view.geometry, field.name));
    }
    inline for (@typeInfo(Hydrology).@"struct".fields) |field| {
        if (field.type == []f64) try writeF64Slice(writer, @field(view.hydrology, field.name));
    }
    inline for (@typeInfo(Surface).@"struct".fields) |field| switch (field.type) {
        []f64 => try writeF64Slice(writer, @field(view.surface, field.name)),
        []bool => try writeBoolSlice(writer, @field(view.surface, field.name)),
        else => {},
    };
    inline for (@typeInfo(SurfaceLitterGeometry).@"struct".fields) |field|
        if (field.type == []f64)
            try writeF64Slice(
                writer,
                @field(view.surface_litter_geometry, field.name),
            );
    try writeF64Slice(writer, view.erosion.surface_sediment_megagrams);
    try writeF64Slice(writer, view.erosion.minimum_surface_mineral_mass_megagrams);
    try writeF64Slice(writer, view.erosion.surface_soil_mass_megagrams);
    try writeBoolSlice(writer, view.erosion.surface_soil_mass_initialized);
    try writer.writeInt(u64, @intCast(view.suspended.layout.organic_cnp_count), .little);
    try writer.writeInt(u64, @intCast(view.suspended.layout.nitrogen_fertilizer_count), .little);
    try writer.writeInt(u64, @intCast(view.suspended.layout.dry_mineral_fertilizer_count), .little);
    try writer.writeInt(u64, @intCast(view.suspended.layout.chemistry_live_and_pending_count), .little);
    try writeF64Slice(writer, view.suspended.pools);
    for (view.climate.modifiers) |modifier| inline for (@typeInfo(@TypeOf(modifier)).@"struct".fields) |field| {
        const value = @field(modifier, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteSoilGeometryCheckpoint;
        try writer.writeInt(u64, @bitCast(value), .little);
    };
    try writer.writeByte(@intFromBool(view.eroded_minerals.initialized));
    try writeF64Slice(writer, view.eroded_minerals.workspace.pools);
    try writeF64Slice(writer, view.eroded_minerals.workspace.exported);
    try writeF64Slice(writer, view.delayed_live_canopy_combustion_heat_megajoules);
    try writeF64Slice(writer, view.delayed_standing_dead_combustion_heat_megajoules);
    try writeF64Slice(writer, view.delayed_subsurface_combustion_heat_megajoules);
    try writeF64Slice(writer, view.delayed_root_uptake_heat_megajoules);
    try writeF64Slice(writer, view.delayed_surface_combustion_heat_megajoules);
    try writeF64Slice(writer, view.surface_litter_ice_m3);
    try writer.writeByte(view.adaptive_hour_schedule.preferred_substep_count);
    try writer.writeByte(view.adaptive_hour_schedule.coarsening_probe_cooldown_hours);
    try writer.writeByte(@intFromBool(view.adaptive_hour_schedule.freeze_flow_coupling_floor_active));
    try Runtime.write(writer, runtime);
    try SurfaceBoundary.write(writer, surface_boundary);
    if (view.water_table) |water_table| {
        try writer.writeByte(1);
        try WaterTable.write(writer, water_table);
    } else {
        try writer.writeByte(0);
    }
}

pub noinline fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) !Owned {
    var builder: ReadBuilder = .{ .allocator = allocator };
    errdefer builder.deinit();
    const header = try readHeader(reader, limits);
    try builder.allocatePrimary(header);
    try readPrimaryState(&builder, reader, limits);
    try readNestedState(&builder, reader, header.cells);
    if (reader.peekByte()) |_| {
        return error.TrailingSoilGeometryCheckpointData;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    const result = builder.finish();
    try validate(.{ .geometry = &result.geometry, .hydrology = &result.hydrology, .surface = &result.surface, .erosion = &result.erosion, .suspended = &result.suspended, .climate = &result.climate, .eroded_minerals = &result.eroded_minerals, .runtime = null, .surface_boundary = null, .adaptive_hour_schedule = &result.adaptive_hour_schedule, .surface_litter_geometry = &result.surface_litter_geometry, .surface_litter_ice_m3 = result.surface_litter_ice_m3, .delayed_live_canopy_combustion_heat_megajoules = result.delayed_live_canopy_combustion_heat_megajoules, .delayed_standing_dead_combustion_heat_megajoules = result.delayed_standing_dead_combustion_heat_megajoules, .delayed_subsurface_combustion_heat_megajoules = result.delayed_subsurface_combustion_heat_megajoules, .delayed_root_uptake_heat_megajoules = result.delayed_root_uptake_heat_megajoules, .delayed_surface_combustion_heat_megajoules = result.delayed_surface_combustion_heat_megajoules });
    return result;
}

noinline fn readHeader(reader: *std.Io.Reader, limits: Limits) !ReadHeader {
    if (limits.maximum_columns == 0 or limits.maximum_rows == 0 or limits.maximum_soil_layers == 0 or limits.maximum_snow_layers == 0) return error.InvalidSoilGeometryCheckpointLimits;
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic)) return error.InvalidSoilGeometryCheckpointMagic;
    const file_version = try reader.takeInt(u32, .little);
    if (file_version != version)
        return error.UnsupportedSoilGeometryCheckpointVersion;
    const columns = try bounded(reader, limits.maximum_columns, error.SoilGeometryCheckpointColumnLimitExceeded);
    const rows = try bounded(reader, limits.maximum_rows, error.SoilGeometryCheckpointRowLimitExceeded);
    const soil_layers = try bounded(reader, limits.maximum_soil_layers, error.SoilGeometryCheckpointSoilLayerLimitExceeded);
    const snow_layers = try bounded(reader, limits.maximum_snow_layers, error.SoilGeometryCheckpointSnowLayerLimitExceeded);
    const plants = try bounded(reader, limits.maximum_plants, error.SoilGeometryCheckpointPlantLimitExceeded);
    if (columns == 0 or rows == 0 or soil_layers == 0 or snow_layers == 0) return error.InvalidSoilGeometryCheckpointDimensions;
    return .{
        .columns = columns,
        .rows = rows,
        .soil_layers = soil_layers,
        .snow_layers = snow_layers,
        .plants = plants,
        .cells = try std.math.mul(usize, columns, rows),
    };
}

noinline fn readPrimaryState(
    builder: *ReadBuilder,
    reader: *std.Io.Reader,
    limits: Limits,
) !void {
    const geometry = &builder.geometry.?;
    const hydrology = &builder.hydrology.?;
    const surface = &builder.surface.?;
    const surface_litter_geometry = &builder.surface_litter_geometry.?;
    const erosion = &builder.erosion.?;
    const eroded_minerals = &builder.eroded_minerals.?;
    try readUsizeSlice(reader, geometry.first_active_layer);
    try readUsizeSlice(reader, geometry.active_layer_count);
    try readGeometrySlices(reader, geometry);
    try readHydrologySlices(reader, hydrology);
    try readSurfaceSlices(reader, surface);
    try readSurfaceLitterGeometrySlices(reader, surface_litter_geometry);
    try readF64Slice(reader, erosion.surface_sediment_megagrams);
    try readF64Slice(reader, erosion.minimum_surface_mineral_mass_megagrams);
    try readF64Slice(reader, erosion.surface_soil_mass_megagrams);
    try readBoolSlice(reader, erosion.surface_soil_mass_initialized);
    if (limits.maximum_suspended_components == 0)
        return error.InvalidSoilGeometryCheckpointLimits;
    const suspended_layout: Suspended.Layout = .{
        .organic_cnp_count = try bounded(reader, limits.maximum_suspended_components, error.SoilGeometryCheckpointSuspendedLayoutLimitExceeded),
        .nitrogen_fertilizer_count = try bounded(reader, limits.maximum_suspended_components, error.SoilGeometryCheckpointSuspendedLayoutLimitExceeded),
        .dry_mineral_fertilizer_count = try bounded(reader, limits.maximum_suspended_components, error.SoilGeometryCheckpointSuspendedLayoutLimitExceeded),
        .chemistry_live_and_pending_count = try bounded(reader, limits.maximum_suspended_components, error.SoilGeometryCheckpointSuspendedLayoutLimitExceeded),
    };
    if (try suspended_layout.componentCount() > limits.maximum_suspended_components)
        return error.SoilGeometryCheckpointSuspendedLayoutLimitExceeded;
    builder.suspended = try Suspended.State.initBorrowingSediment(
        builder.allocator,
        erosion.surface_sediment_megagrams,
        suspended_layout,
    );
    try readF64Slice(reader, builder.suspended.?.pools);
    try readClimate(reader, &builder.climate);
    eroded_minerals.initialized = switch (try reader.takeByte()) {
        0 => false,
        1 => true,
        else => return error.InvalidSoilGeometryCheckpointBoolean,
    };
    try readF64Slice(reader, eroded_minerals.workspace.pools);
    try readF64Slice(reader, eroded_minerals.workspace.exported);
    try readF64Slice(reader, builder.delayed_live_heat.?);
    try readF64Slice(reader, builder.delayed_dead_heat.?);
    try readF64Slice(reader, builder.delayed_subsurface_heat.?);
    try readF64Slice(reader, builder.delayed_root_uptake_heat.?);
    try readF64Slice(reader, builder.delayed_surface_heat.?);
    try readF64Slice(reader, builder.surface_litter_ice_m3.?);
    builder.adaptive_hour_schedule.preferred_substep_count = try reader.takeByte();
    builder.adaptive_hour_schedule.coarsening_probe_cooldown_hours = try reader.takeByte();
    builder.adaptive_hour_schedule.freeze_flow_coupling_floor_active = switch (try reader.takeByte()) {
        0 => false,
        1 => true,
        else => return error.InvalidSoilGeometryCheckpointBoolean,
    };
    try builder.adaptive_hour_schedule.validate();
}

noinline fn readGeometrySlices(reader: *std.Io.Reader, geometry: *Geometry) !void {
    inline for (@typeInfo(Geometry).@"struct".fields) |field| {
        if (field.type == []f64) try readF64Slice(reader, @field(geometry, field.name));
    }
}

noinline fn readHydrologySlices(reader: *std.Io.Reader, hydrology: *Hydrology) !void {
    inline for (@typeInfo(Hydrology).@"struct".fields) |field| {
        if (field.type == []f64)
            try readF64Slice(reader, @field(hydrology, field.name));
    }
}

noinline fn readSurfaceSlices(reader: *std.Io.Reader, surface: *Surface) !void {
    inline for (@typeInfo(Surface).@"struct".fields) |field| switch (field.type) {
        []f64 => try readF64Slice(reader, @field(surface, field.name)),
        []bool => try readBoolSlice(reader, @field(surface, field.name)),
        else => {},
    };
}

noinline fn readSurfaceLitterGeometrySlices(
    reader: *std.Io.Reader,
    surface_litter_geometry: *SurfaceLitterGeometry,
) !void {
    inline for (@typeInfo(SurfaceLitterGeometry).@"struct".fields) |field|
        if (field.type == []f64)
            try readF64Slice(
                reader,
                @field(surface_litter_geometry, field.name),
            );
}

noinline fn readClimate(reader: *std.Io.Reader, climate: *Climate) !void {
    for (&climate.modifiers) |*modifier| inline for (@typeInfo(@TypeOf(modifier.*)).@"struct".fields) |field| {
        @field(modifier.*, field.name) = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(@field(modifier.*, field.name))) return error.NonFiniteSoilGeometryCheckpoint;
    };
}

noinline fn readNestedState(
    builder: *ReadBuilder,
    reader: *std.Io.Reader,
    cells: usize,
) !void {
    builder.runtime = try Runtime.read(builder.allocator, reader, builder.layer_cells);
    builder.surface_boundary = try SurfaceBoundary.read(
        builder.allocator,
        reader,
        cells,
    );
    builder.water_table = switch (try reader.takeByte()) {
        0 => null,
        1 => try WaterTable.read(builder.allocator, reader, cells),
        else => return error.InvalidSoilGeometryCheckpointBoolean,
    };
}

noinline fn validate(view: View) !void {
    const geometry = view.geometry;
    const hydrology = view.hydrology;
    try view.adaptive_hour_schedule.validate();
    const cells = std.math.mul(usize, hydrology.columns, hydrology.rows) catch return error.InvalidSoilGeometryCheckpointDimensions;
    const layer_cells = try std.math.mul(usize, cells, hydrology.soil_layer_capacity);
    if (hydrology.columns == 0 or hydrology.rows == 0 or hydrology.soil_layer_capacity == 0 or hydrology.snow_layer_capacity == 0 or geometry.cell_count != cells or geometry.layer_capacity != hydrology.soil_layer_capacity or view.surface.cell_count != cells or view.surface_litter_geometry.cell_count != cells or view.erosion.cell_count != cells or view.suspended.cell_count != cells or view.suspended.sediment_megagrams.ptr != view.erosion.surface_sediment_megagrams.ptr or view.delayed_live_canopy_combustion_heat_megajoules.len == 0 or view.delayed_standing_dead_combustion_heat_megajoules.len != view.delayed_live_canopy_combustion_heat_megajoules.len or view.delayed_subsurface_combustion_heat_megajoules.len != layer_cells or view.delayed_root_uptake_heat_megajoules.len != layer_cells or view.delayed_surface_combustion_heat_megajoules.len != cells or view.surface_litter_ice_m3.len != cells) return error.InvalidSoilGeometryCheckpointDimensions;
    try view.suspended.validate();
    for (0..cells) |cell| {
        const first = geometry.first_active_layer[cell];
        const count = geometry.active_layer_count[cell];
        if (count == 0 or first >= geometry.layer_capacity or count > geometry.layer_capacity - first) return error.InvalidCheckpointActiveSoilLayerRange;
        const boundary_base = cell * (geometry.layer_capacity + 1);
        const layer_base = cell * geometry.layer_capacity;
        for (first..first + count) |layer| {
            const top = geometry.boundary_depth_m[boundary_base + layer];
            const bottom = geometry.boundary_depth_m[boundary_base + layer + 1];
            const top_without_freeze = geometry.boundary_depth_without_freeze_m[boundary_base + layer];
            const bottom_without_freeze = geometry.boundary_depth_without_freeze_m[boundary_base + layer + 1];
            if (bottom <= top or bottom_without_freeze <= top_without_freeze or geometry.layer_thickness_m[layer_base + layer] <= 0) return error.InvalidCheckpointSoilLayerGeometry;
        }
    }
    for (view.climate.modifiers) |modifier| inline for (@typeInfo(@TypeOf(modifier)).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(modifier, field.name))) return error.NonFiniteSoilGeometryCheckpoint;
    };
    if (view.eroded_minerals.workspace.cell_count != cells or view.eroded_minerals.workspace.component_count != @import("../../soil/profile/erosion_mineral_bridge.zig").component_count) return error.InvalidSoilGeometryCheckpointDimensions;
    try validateFinite(view.eroded_minerals.workspace.pools);
    try validateFinite(view.eroded_minerals.workspace.exported);
    try validateFinite(view.delayed_live_canopy_combustion_heat_megajoules);
    try validateFinite(view.delayed_standing_dead_combustion_heat_megajoules);
    try validateFinite(view.delayed_subsurface_combustion_heat_megajoules);
    try validateFinite(view.delayed_root_uptake_heat_megajoules);
    try validateFinite(view.delayed_surface_combustion_heat_megajoules);
    try validateFinite(view.surface_litter_ice_m3);
    inline for (@typeInfo(SurfaceLitterGeometry).@"struct".fields) |field|
        if (field.type == []f64)
            try validateFinite(@field(view.surface_litter_geometry, field.name));
    for (0..cells) |cell| {
        const litter = view.surface_litter_geometry;
        inline for (.{
            litter.water_retention_capacity_m3[cell],
            litter.dry_litter_volume_m3[cell],
            litter.expanded_total_volume_m3[cell],
            litter.dry_mass_megagrams[cell],
            litter.pore_volume_m3[cell],
            litter.air_volume_m3[cell],
            litter.porosity_m3_per_m3[cell],
            litter.field_capacity_m3_per_m3[cell],
            litter.wilting_point_m3_per_m3[cell],
        }) |value| if (value < 0)
            return error.InvalidCheckpointSurfaceLitterGeometry;
        if (litter.air_volume_m3[cell] > litter.pore_volume_m3[cell] or
            litter.pore_volume_m3[cell] >
                litter.expanded_total_volume_m3[cell] or
            litter.porosity_m3_per_m3[cell] > 1 or
            litter.field_capacity_m3_per_m3[cell] >
                litter.porosity_m3_per_m3[cell] or
            litter.wilting_point_m3_per_m3[cell] >
                litter.field_capacity_m3_per_m3[cell])
            return error.InvalidCheckpointSurfaceLitterGeometry;
        if (litter.previous_charcoal_carbon_g_c[cell] < 0 or
            (litter.retention_refresh_pending[cell] != 0 and
                litter.retention_refresh_pending[cell] != 1))
            return error.InvalidCheckpointSurfaceLitterGeometry;
    }
    inline for (.{ view.delayed_live_canopy_combustion_heat_megajoules, view.delayed_standing_dead_combustion_heat_megajoules, view.delayed_subsurface_combustion_heat_megajoules, view.delayed_surface_combustion_heat_megajoules }) |values| for (values) |value| if (value < 0) return error.InvalidCheckpointDelayedCombustionHeat;
    for (view.surface_litter_ice_m3) |value| if (value < 0)
        return error.InvalidCheckpointSurfaceLitterIce;
    for (view.eroded_minerals.workspace.pools) |value| if (value < -1e-14) return error.InvalidSoilGeometryCheckpointInventory;
    for (view.eroded_minerals.workspace.exported) |value| if (value < -1e-14) return error.InvalidSoilGeometryCheckpointInventory;
    inline for (@typeInfo(Geometry).@"struct".fields) |field| {
        if (field.type == []f64) try validateFinite(@field(geometry, field.name));
    }
    try hydrology.validateFinite();
    inline for (@typeInfo(Surface).@"struct".fields) |field| if (field.type == []f64) try validateFinite(@field(view.surface, field.name));
    if (view.runtime) |runtime| try Runtime.validateView(runtime);
    if (view.surface_boundary) |surface_boundary|
        try SurfaceBoundary.validateView(surface_boundary);
    if (view.water_table) |water_table|
        try WaterTable.validateView(water_table);
    try validateFinite(view.erosion.surface_sediment_megagrams);
    try validateFinite(view.erosion.minimum_surface_mineral_mass_megagrams);
    try validateFinite(view.erosion.surface_soil_mass_megagrams);
    for (0..cells) |cell| {
        if (view.erosion.surface_sediment_megagrams[cell] < -1e-14 or
            view.erosion.minimum_surface_mineral_mass_megagrams[cell] < -1e-14 or
            view.erosion.surface_soil_mass_megagrams[cell] < -1e-14)
            return error.InvalidSoilGeometryCheckpointInventory;
        if (view.erosion.surface_soil_mass_initialized[cell] and
            (view.erosion.minimum_surface_mineral_mass_megagrams[cell] <= 0 or
                view.erosion.surface_soil_mass_megagrams[cell] <= 0))
            return error.InvalidCheckpointSurfaceSoilMass;
    }
    inline for (.{ hydrology.micropore_water_volume_m3, hydrology.macropore_water_volume_m3, hydrology.matrix_air_volume_m3, hydrology.macropore_air_volume_m3, hydrology.air_volume_m3, hydrology.water_vapor_volume_m3, hydrology.snow_surface_carrier_volume_m3, hydrology.snow_liquid_water_volume_m3 }) |values| {
        for (values) |value| if (value < -1e-14) return error.InvalidSoilGeometryCheckpointInventory;
    }
}

noinline fn validateFinite(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilGeometryCheckpoint;
}

noinline fn bounded(reader: *std.Io.Reader, limit: usize, too_large: anyerror) !usize {
    const value = try reader.takeInt(u64, .little);
    if (value > limit or value > std.math.maxInt(usize)) return too_large;
    return @intCast(value);
}

noinline fn writeUsizeSlice(writer: anytype, values: []const usize) !void {
    for (values) |value| try writer.writeInt(u64, @intCast(value), .little);
}

noinline fn readUsizeSlice(reader: *std.Io.Reader, values: []usize) !void {
    for (values) |*value| {
        const stored = try reader.takeInt(u64, .little);
        if (stored > std.math.maxInt(usize)) return error.InvalidCheckpointInteger;
        value.* = @intCast(stored);
    }
}

noinline fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteSoilGeometryCheckpoint;
        try writer.writeInt(u64, @bitCast(value), .little);
    }
}

noinline fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*)) return error.NonFiniteSoilGeometryCheckpoint;
    }
}
noinline fn writeBoolSlice(writer: anytype, values: []const bool) !void {
    for (values) |value| try writer.writeByte(@intFromBool(value));
}
noinline fn readBoolSlice(reader: *std.Io.Reader, values: []bool) !void {
    for (values) |*value| value.* = switch (try reader.takeByte()) {
        0 => false,
        1 => true,
        else => return error.InvalidSoilGeometryCheckpointBoolean,
    };
}

const TestRuntime = struct {
    allocator: std.mem.Allocator,
    properties: @import("../../soil/water/solver_properties.zig").State,
    thermal: @import("../../soil/heat/thermal.zig").State,
    solver_fields: [Runtime.solver_field_count][]f64,
    thermal_fields: [Runtime.thermal_field_count][]f64,
    retention_curve: []@import("../../soil/water/retention.zig").ResolvedCurve,
    mualem_van_genuchten_parameters: []@import("../../soil/water/retention.zig").MualemVanGenuchtenParameters,
    chemistry_layer_parameters: []@import("../../soil/solute/chemistry_state.zig").ReactionParameters,

    fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        layer_capacity: usize,
    ) !TestRuntime {
        const layer_count = try std.math.mul(usize, cell_count, layer_capacity);
        var result: TestRuntime = undefined;
        result.allocator = allocator;
        var solver_allocated: usize = 0;
        var thermal_allocated: usize = 0;
        errdefer {
            for (result.thermal_fields[0..thermal_allocated]) |values|
                allocator.free(values);
            for (result.solver_fields[0..solver_allocated]) |values|
                allocator.free(values);
        }
        for (&result.solver_fields) |*values| {
            values.* = try allocator.alloc(f64, layer_count);
            @memset(values.*, 0);
            solver_allocated += 1;
        }
        for (&result.thermal_fields) |*values| {
            values.* = try allocator.alloc(f64, layer_count);
            @memset(values.*, 0);
            thermal_allocated += 1;
        }
        result.retention_curve = try allocator.alloc(@import("../../soil/water/retention.zig").ResolvedCurve, layer_count);
        errdefer allocator.free(result.retention_curve);
        result.mualem_van_genuchten_parameters = try allocator.alloc(@import("../../soil/water/retention.zig").MualemVanGenuchtenParameters, layer_count);
        errdefer allocator.free(result.mualem_van_genuchten_parameters);
        result.chemistry_layer_parameters = try allocator.alloc(
            @import("../../soil/solute/chemistry_state.zig").ReactionParameters,
            layer_count,
        );
        errdefer allocator.free(result.chemistry_layer_parameters);
        result.properties = undefined;
        result.properties.layer_count = layer_count;
        inline for (@typeInfo(Runtime.SolverField).@"enum".fields, 0..) |field, index|
            @field(result.properties, field.name) = result.solver_fields[index];
        result.properties.retention_curve = result.retention_curve;
        result.properties.mualem_van_genuchten_parameters = result.mualem_van_genuchten_parameters;
        result.thermal = undefined;
        result.thermal.cell_count = cell_count;
        result.thermal.soil_layer_capacity = layer_capacity;
        inline for (@typeInfo(Runtime.ThermalField).@"enum".fields, 0..) |field, index|
            @field(result.thermal, field.name) = result.thermal_fields[index];
        @memset(result.properties.matrix_bulk_volume_m3, 0.5);
        @memset(result.properties.layer_volume_m3, 1);
        @memset(result.properties.layer_thickness_m, 1);
        @memset(result.properties.initial_layer_thickness_m, 1);
        @memset(result.properties.layer_midpoint_depth_m, 0.5);
        @memset(result.properties.layer_bottom_depth_m, 1);
        @memset(result.properties.bulk_density_megagrams_per_m3, 1);
        @memset(result.properties.reference_bulk_density_megagrams_per_m3, 1);
        @memset(result.properties.porosity_fraction, 0.5);
        @memset(result.properties.micropore_fraction, 1);
        @memset(result.properties.macropore_fraction, 0);
        @memset(result.properties.rock_fraction, 0);
        @memset(result.properties.supplied_field_capacity_fraction, -1);
        @memset(result.properties.supplied_wilting_point_fraction, -1);
        @memset(result.properties.field_capacity_water_potential_megapascal, -0.033);
        @memset(result.properties.wilting_point_water_potential_megapascal, -1.5);
        @memset(result.properties.supplied_vertical_saturated_hydraulic_conductivity_m_per_h, -1);
        @memset(result.properties.supplied_lateral_saturated_hydraulic_conductivity_m_per_h, -1);
        @memset(result.properties.supplied_lateral_conductivity_m2_per_h_megapascal, -1);
        @memset(result.properties.field_capacity_fraction, 0.25);
        @memset(result.properties.wilting_point_fraction, 0.1);
        @memset(result.properties.saturation_water_potential_megapascal, -0.001);
        const curve: @import("../../soil/water/retention.zig").ResolvedCurve = .{
            .porosity_fraction = 0.5,
            .curve = .{
                .field_capacity_fraction = 0.25,
                .wilting_point_fraction = 0.1,
                .saturation_water_potential_megapascal = -0.001,
                .field_capacity_water_potential_megapascal = -0.033,
                .wilting_point_water_potential_megapascal = -1.5,
                .minimum_water_potential_megapascal = -15000,
                .saturation_to_field_shape = 2,
                .below_wilting_shape = 1,
            },
        };
        @memset(result.retention_curve, curve);
        const mualem = try @import("../../soil/water/retention.zig").carselParrishDefault(.loam, 0.5);
        @memset(result.mualem_van_genuchten_parameters, mualem);
        for (result.chemistry_layer_parameters) |*parameters| {
            parameters.cation_exchange_capacity_mol_charge_per_megagram = 1;
            parameters.cation_exchange_parameters.selectivity = .{
                .calcium_ammonium = 1,
                .calcium_hydrogen = 1,
                .calcium_aluminum_and_iron = 1,
                .calcium_magnesium = 1,
                .calcium_sodium = 1,
                .calcium_potassium = 1,
            };
        }
        @memset(result.properties.rainfall_conductivity_multiplier, 1);
        @memset(result.thermal.layer_volume_m3, 1);
        @memset(result.thermal.layer_thickness_m, 1);
        @memset(result.thermal.porosity_fraction, 0.5);
        @memset(result.thermal.dry_solid_heat_capacity_megajoules_per_m3_k, 1);
        @memset(result.thermal.solid_thermal_conductivity_numerator_m_megajoules_per_h_k, 1);
        @memset(result.thermal.solid_thermal_conductivity_denominator, 1);
        @memset(result.thermal.total_heat_capacity_megajoules_per_m3_k, 2);
        @memset(result.thermal.thermal_conductivity_m_megajoules_per_h_k, 0.5);
        return result;
    }

    fn deinit(self: *TestRuntime) void {
        self.allocator.free(self.chemistry_layer_parameters);
        self.allocator.free(self.mualem_van_genuchten_parameters);
        self.allocator.free(self.retention_curve);
        for (self.thermal_fields) |values| self.allocator.free(values);
        for (self.solver_fields) |values| self.allocator.free(values);
        self.* = undefined;
    }

    fn view(self: *const TestRuntime) Runtime.View {
        return .{
            .soil_properties = &self.properties,
            .soil_thermal = &self.thermal,
            .soil_chemistry_layer_parameters = self.chemistry_layer_parameters,
        };
    }
};

const TestSurfaceBoundary = struct {
    allocator: std.mem.Allocator,
    ground_air: @import("../../surface/ground_air_exchange.zig").State,
    aerodynamics: @import("../../surface/aerodynamics.zig").State,
    atmospheric_carrier: @import("../../atmosphere/canopy_gas_state.zig").State,
    ground_fields: [SurfaceBoundary.ground_air_field_count][]f64,
    iterations: []u16,
    aerodynamic_fields: [SurfaceBoundary.aerodynamic_field_count][]f64,

    fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
    ) !TestSurfaceBoundary {
        var result: TestSurfaceBoundary = undefined;
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
            @memset(values.*, 1);
            ground_allocated += 1;
        }
        result.iterations = try allocator.alloc(u16, cell_count);
        @memset(result.iterations, 0);
        iterations_allocated = true;
        for (&result.aerodynamic_fields) |*values| {
            values.* = try allocator.alloc(f64, cell_count);
            @memset(values.*, 1);
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
        result.aerodynamics.zero_plane_displacement_m =
            result.aerodynamic_fields[0];
        result.aerodynamics.effective_roughness_height_m =
            result.aerodynamic_fields[1];
        result.aerodynamics.wind_reference_height_m =
            result.aerodynamic_fields[2];
        result.aerodynamics.bulk_richardson_coefficient_k =
            result.aerodynamic_fields[3];
        result.aerodynamics.isothermal_aerodynamic_resistance_h_per_m =
            result.aerodynamic_fields[4];
        const temperatures = try allocator.alloc(f64, cell_count);
        defer allocator.free(temperatures);
        const vapors = try allocator.alloc(f64, cell_count);
        defer allocator.free(vapors);
        const ratios = try allocator.alloc(
            @import("../../atmosphere/atmospheric_gas_mass_concentration.zig").MixingRatios,
            cell_count,
        );
        defer allocator.free(ratios);
        for (0..cell_count) |cell| {
            const cell_f: f64 = @floatFromInt(cell);
            temperatures[cell] = 275 + 2 * cell_f;
            vapors[cell] = 0.004 + 0.0001 * cell_f;
            ratios[cell] = .{
                .carbon_dioxide_umol_mol = 390 + 11 * cell_f,
                .methane_umol_mol = 1.7 + 0.1 * cell_f,
                .oxygen_umol_mol = 180_000 + 7_000 * cell_f,
                .nitrogen_umol_mol = 780_000 - 4_000 * cell_f,
                .nitrous_oxide_umol_mol = 0.30 + 0.01 * cell_f,
                .ammonia_umol_mol = 0.01 + 0.02 * cell_f,
                .hydrogen_umol_mol = 0.001 + 0.0005 * cell_f,
            };
        }
        result.atmospheric_carrier = try @import("../../atmosphere/canopy_gas_state.zig").State.init(
            allocator,
            temperatures,
            vapors,
            ratios,
        );
        @memset(result.ground_air.temperature_k, 280);
        @memset(result.ground_air.vapor_volume_fraction, 0.005);
        @memset(result.aerodynamics.zero_plane_displacement_m, 0);
        return result;
    }

    fn deinit(self: *TestSurfaceBoundary) void {
        self.atmospheric_carrier.deinit();
        for (self.aerodynamic_fields) |values| self.allocator.free(values);
        self.allocator.free(self.iterations);
        for (self.ground_fields) |values| self.allocator.free(values);
        self.* = undefined;
    }

    fn view(self: *const TestSurfaceBoundary) SurfaceBoundary.View {
        return .{
            .ground_air = &self.ground_air,
            .surface_aerodynamics = &self.aerodynamics,
            .atmospheric_carrier = &self.atmospheric_carrier,
        };
    }
};

test "soil geometry checkpoint round trips arbitrary grid layers flux ledgers and post-tillage Gapon owner" {
    var geometry = try Geometry.init(std.testing.allocator, 6, 7);
    defer geometry.deinit();
    geometry.first_active_layer[5] = 2;
    geometry.active_layer_count[5] = 4;
    geometry.boundary_depth_m[5 * 8 + 3] = 3.25;
    geometry.layer_thickness_m[5 * 7 + 2] = 1.25;
    var hydrology = try Hydrology.init(std.testing.allocator, 3, 2, 7, 4);
    defer hydrology.deinit();
    var surface = try Surface.init(std.testing.allocator, 6);
    defer surface.deinit();
    var surface_litter_geometry =
        try SurfaceLitterGeometry.init(std.testing.allocator, 6);
    defer surface_litter_geometry.deinit();
    var erosion = try Erosion.init(std.testing.allocator, 3, 2);
    defer erosion.deinit();
    var suspended = try Suspended.State.initBorrowingSediment(std.testing.allocator, erosion.surface_sediment_megagrams, test_suspended_layout);
    defer suspended.deinit();
    var climate: Climate = .{};
    var eroded_minerals = try ErodedMinerals.init(std.testing.allocator, 6);
    defer eroded_minerals.deinit();
    var runtime = try TestRuntime.init(std.testing.allocator, 6, 7);
    defer runtime.deinit();
    var surface_boundary =
        try TestSurfaceBoundary.init(std.testing.allocator, 6);
    defer surface_boundary.deinit();
    surface_boundary.ground_air.temperature_k[5] = 267.25;
    surface_boundary.ground_air.vapor_volume_fraction[5] = 0.0027;
    surface_boundary.aerodynamics.effective_roughness_height_m[5] = 0.13;
    surface_boundary.atmospheric_carrier.bulk_temperature_k[5] = 269.5;
    surface_boundary.atmospheric_carrier.canopy_co2_umol_mol[5] = 397.25;
    runtime.properties.matrix_bulk_volume_m3[41] = 0.73;
    runtime.properties.layer_volume_m3[41] = 1.25;
    runtime.properties.layer_thickness_m[41] = 1.25;
    runtime.properties.initial_layer_thickness_m[41] = 0.31;
    runtime.properties.bulk_density_megagrams_per_m3[41] = 1.37;
    runtime.properties.reference_bulk_density_megagrams_per_m3[41] = 1.18;
    runtime.properties.porosity_fraction[41] = 0.42;
    runtime.properties.retention_curve[41].porosity_fraction = 0.42;
    runtime.properties.mualem_van_genuchten_parameters[41].saturated_water_content_m3_per_m3 = 0.42;
    runtime.properties.charcoal_retention_increment_fraction[41] = 0.01;
    runtime.properties.field_capacity_fraction[41] = 0.26;
    runtime.properties.retention_curve[41].curve.field_capacity_fraction = 0.26;
    runtime.thermal.layer_volume_m3[41] = 0.44;
    runtime.thermal.layer_thickness_m[41] = 0.044;
    runtime.thermal.porosity_fraction[41] = 0.42;
    runtime.thermal.dry_solid_heat_capacity_megajoules_per_m3_k[41] = 1.67;
    runtime.thermal.total_heat_capacity_megajoules_per_m3_k[41] = 2.91;
    runtime.thermal.thermal_conductivity_m_megajoules_per_h_k[41] = 0.0042;
    // A nonuniform tuple is the authoritative result of a depth-weighted
    // REDIST mix. Preserve all six members bit-for-bit across restart; GKCH is
    // invariant under tillage but still belongs to the persistent tuple.
    runtime.chemistry_layer_parameters[41]
        .cation_exchange_parameters.selectivity = .{
        .calcium_ammonium = 1.125,
        .calcium_hydrogen = 7.25,
        .calcium_aluminum_and_iron = 2.375,
        .calcium_magnesium = 3.5,
        .calcium_sodium = 4.625,
        .calcium_potassium = 5.75,
    };
    runtime.chemistry_layer_parameters[41]
        .cation_exchange_capacity_mol_charge_per_megagram = 12.875;
    hydrology.micropore_water_volume_m3[41] = 2.5;
    hydrology.heat_face_flux_megajoules_per_step[125] = -3.5;
    hydrology.snow_liquid_water_volume_m3[23] = 0.4;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    surface.solid_snow_water_equivalent_m3[5] = 0.7;
    surface_litter_geometry.expanded_total_volume_m3[5] = 0.41;
    surface_litter_geometry.pore_volume_m3[5] = 0.30;
    surface_litter_geometry.air_volume_m3[5] = 0.17;
    surface_litter_geometry.porosity_m3_per_m3[5] = 0.63;
    surface_litter_geometry.field_capacity_m3_per_m3[5] = 0.31;
    surface_litter_geometry.wilting_point_m3_per_m3[5] = 0.12;
    surface_litter_geometry.previous_charcoal_carbon_g_c[5] = 3.25;
    surface_litter_geometry.retention_refresh_pending[5] = 1;
    erosion.surface_sediment_megagrams[5] = 0.25;
    erosion.minimum_surface_mineral_mass_megagrams[5] = 4.25;
    erosion.surface_soil_mass_megagrams[5] = 4.5;
    erosion.surface_soil_mass_initialized[5] = true;
    climate.modifiers[2].precipitation = 1.25;
    eroded_minerals.initialized = true;
    eroded_minerals.workspace.pools[5] = 2.75;
    var live_heat = [_]f64{0} ** 12;
    var dead_heat = [_]f64{0} ** 12;
    var subsurface_heat = [_]f64{0} ** 42;
    var root_uptake_heat = [_]f64{0} ** 42;
    var surface_heat = [_]f64{0} ** 6;
    var surface_ice = [_]f64{0} ** 6;
    live_heat[11] = 1.25;
    dead_heat[10] = 2.5;
    subsurface_heat[41] = 3.75;
    root_uptake_heat[40] = -4.25;
    surface_heat[5] = 5;
    surface_ice[5] = 0.375;
    suspended.pools[suspended.pools.len - 1] = 6.25;
    const adaptive_hour_schedule: AdaptiveHourSchedule = .{
        .preferred_substep_count = 8,
        .coarsening_probe_cooldown_hours = 17,
        .freeze_flow_coupling_floor_active = true,
    };
    try write(&bytes.writer, .{ .geometry = &geometry, .hydrology = &hydrology, .surface = &surface, .erosion = &erosion, .suspended = &suspended, .climate = &climate, .eroded_minerals = &eroded_minerals, .runtime = runtime.view(), .surface_boundary = surface_boundary.view(), .adaptive_hour_schedule = &adaptive_hour_schedule, .surface_litter_geometry = &surface_litter_geometry, .surface_litter_ice_m3 = &surface_ice, .delayed_live_canopy_combustion_heat_megajoules = &live_heat, .delayed_standing_dead_combustion_heat_megajoules = &dead_heat, .delayed_subsurface_combustion_heat_megajoules = &subsurface_heat, .delayed_root_uptake_heat_megajoules = &root_uptake_heat, .delayed_surface_combustion_heat_megajoules = &surface_heat });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_columns = 10, .maximum_rows = 10, .maximum_soil_layers = 20, .maximum_snow_layers = 10, .maximum_plants = 20 });
    defer restored.deinit();
    try std.testing.expectEqualSlices(usize, geometry.first_active_layer, restored.geometry.first_active_layer);
    try std.testing.expectEqualSlices(f64, geometry.boundary_depth_m, restored.geometry.boundary_depth_m);
    try std.testing.expectEqualSlices(f64, hydrology.heat_face_flux_megajoules_per_step, restored.hydrology.heat_face_flux_megajoules_per_step);
    try std.testing.expectEqualSlices(f64, hydrology.snow_liquid_water_volume_m3, restored.hydrology.snow_liquid_water_volume_m3);
    try std.testing.expectEqualSlices(f64, surface.solid_snow_water_equivalent_m3, restored.surface.solid_snow_water_equivalent_m3);
    inline for (@typeInfo(SurfaceLitterGeometry).@"struct".fields) |field| if (field.type == []f64)
        try std.testing.expectEqualSlices(f64, @field(surface_litter_geometry, field.name), @field(restored.surface_litter_geometry, field.name));
    try std.testing.expectEqualSlices(f64, erosion.surface_sediment_megagrams, restored.erosion.surface_sediment_megagrams);
    try std.testing.expectEqualSlices(f64, erosion.minimum_surface_mineral_mass_megagrams, restored.erosion.minimum_surface_mineral_mass_megagrams);
    try std.testing.expectEqualSlices(f64, erosion.surface_soil_mass_megagrams, restored.erosion.surface_soil_mass_megagrams);
    try std.testing.expectEqualSlices(bool, erosion.surface_soil_mass_initialized, restored.erosion.surface_soil_mass_initialized);
    try std.testing.expectEqualSlices(f64, suspended.pools, restored.suspended.pools);
    try std.testing.expect(restored.suspended.sediment_megagrams.ptr == restored.erosion.surface_sediment_megagrams.ptr);
    try std.testing.expectEqual(climate.modifiers[2], restored.climate.modifiers[2]);
    try std.testing.expectEqualSlices(f64, eroded_minerals.workspace.pools, restored.eroded_minerals.workspace.pools);
    try std.testing.expectEqualSlices(f64, &live_heat, restored.delayed_live_canopy_combustion_heat_megajoules);
    try std.testing.expectEqualSlices(f64, &dead_heat, restored.delayed_standing_dead_combustion_heat_megajoules);
    try std.testing.expectEqualSlices(f64, &subsurface_heat, restored.delayed_subsurface_combustion_heat_megajoules);
    try std.testing.expectEqualSlices(f64, &root_uptake_heat, restored.delayed_root_uptake_heat_megajoules);
    try std.testing.expectEqualSlices(f64, &surface_heat, restored.delayed_surface_combustion_heat_megajoules);
    try std.testing.expectEqualSlices(f64, &surface_ice, restored.surface_litter_ice_m3);
    try std.testing.expectEqual(adaptive_hour_schedule, restored.adaptive_hour_schedule);
    try std.testing.expectEqual(
        surface_boundary.ground_air.temperature_k[5],
        restored.surface_boundary.ground_air_fields[0][5],
    );
    try std.testing.expectEqual(
        surface_boundary.aerodynamics.effective_roughness_height_m[5],
        restored.surface_boundary.aerodynamic_fields[1][5],
    );
    try std.testing.expectEqual(
        surface_boundary.atmospheric_carrier.canopy_co2_umol_mol[5],
        restored.surface_boundary.atmospheric_carrier_fields[2][5],
    );
    try std.testing.expect(
        restored.surface_boundary.atmospheric_carrier_fields[0][0] !=
            restored.surface_boundary.atmospheric_carrier_fields[0][1],
    );
    try std.testing.expect(
        restored.surface_boundary.atmospheric_carrier_fields[2][0] !=
            restored.surface_boundary.atmospheric_carrier_fields[2][1],
    );
    var target_surface_boundary =
        try TestSurfaceBoundary.init(std.testing.allocator, 6);
    defer target_surface_boundary.deinit();
    @memset(target_surface_boundary.aerodynamics.wind_reference_height_m, 0);
    @memset(
        target_surface_boundary.aerodynamics
            .isothermal_aerodynamic_resistance_h_per_m,
        0,
    );
    try restored.surface_boundary.restoreInto(
        &target_surface_boundary.ground_air,
        &target_surface_boundary.aerodynamics,
        &target_surface_boundary.atmospheric_carrier,
    );
    try std.testing.expectEqual(
        surface_boundary.ground_air.temperature_k[5],
        target_surface_boundary.ground_air.temperature_k[5],
    );
    try std.testing.expectEqual(
        surface_boundary.aerodynamics.effective_roughness_height_m[5],
        target_surface_boundary.aerodynamics.effective_roughness_height_m[5],
    );
    try std.testing.expectEqual(
        surface_boundary.atmospheric_carrier.bulk_temperature_k[5],
        target_surface_boundary.atmospheric_carrier.bulk_temperature_k[5],
    );
    inline for (
        @import("../../atmosphere/canopy_gas_state.zig").persistedConstFields(
            &surface_boundary.atmospheric_carrier,
        ),
        @import("../../atmosphere/canopy_gas_state.zig").persistedConstFields(
            &target_surface_boundary.atmospheric_carrier,
        ),
    ) |expected, actual| try std.testing.expectEqualSlices(f64, expected, actual);
    const restart_background = [_]@import("../../atmosphere/atmospheric_gas_mass_concentration.zig").MixingRatios{
        .{ .carbon_dioxide_umol_mol = 390, .methane_umol_mol = 1.7, .oxygen_umol_mol = 180_000, .nitrogen_umol_mol = 780_000, .nitrous_oxide_umol_mol = 0.30, .ammonia_umol_mol = 0.01, .hydrogen_umol_mol = 0.001 },
        .{ .carbon_dioxide_umol_mol = 510, .methane_umol_mol = 2.4, .oxygen_umol_mol = 230_000, .nitrogen_umol_mol = 760_000, .nitrous_oxide_umol_mol = 0.42, .ammonia_umol_mol = 0.08, .hydrogen_umol_mol = 0.004 },
        .{ .carbon_dioxide_umol_mol = 420, .methane_umol_mol = 1.9, .oxygen_umol_mol = 205_000, .nitrogen_umol_mol = 770_000, .nitrous_oxide_umol_mol = 0.34, .ammonia_umol_mol = 0.02, .hydrogen_umol_mol = 0.002 },
        .{ .carbon_dioxide_umol_mol = 430, .methane_umol_mol = 2.0, .oxygen_umol_mol = 207_000, .nitrogen_umol_mol = 768_000, .nitrous_oxide_umol_mol = 0.35, .ammonia_umol_mol = 0.03, .hydrogen_umol_mol = 0.002 },
        .{ .carbon_dioxide_umol_mol = 440, .methane_umol_mol = 2.1, .oxygen_umol_mol = 209_000, .nitrogen_umol_mol = 766_000, .nitrous_oxide_umol_mol = 0.36, .ammonia_umol_mol = 0.04, .hydrogen_umol_mol = 0.003 },
        .{ .carbon_dioxide_umol_mol = 450, .methane_umol_mol = 2.2, .oxygen_umol_mol = 211_000, .nitrogen_umol_mol = 764_000, .nitrous_oxide_umol_mol = 0.37, .ammonia_umol_mol = 0.05, .hydrogen_umol_mol = 0.003 },
    };
    try surface_boundary.atmospheric_carrier.refreshMassConcentrations(&restart_background);
    try target_surface_boundary.atmospheric_carrier.refreshMassConcentrations(&restart_background);
    try std.testing.expectEqualSlices(
        f64,
        surface_boundary.atmospheric_carrier.mass_concentration_g_per_m3,
        target_surface_boundary.atmospheric_carrier.mass_concentration_g_per_m3,
    );
    try std.testing.expect(
        target_surface_boundary.atmospheric_carrier.mass_concentration_g_per_m3[
            @intFromEnum(@import("../../soil/gas/transport.zig").Species.ammonia)
        ] != target_surface_boundary.atmospheric_carrier.mass_concentration_g_per_m3[
            @import("../../soil/gas/transport.zig").species_count +
                @intFromEnum(@import("../../soil/gas/transport.zig").Species.ammonia)
        ],
    );
    try std.testing.expectEqual(
        runtime.properties.matrix_bulk_volume_m3[41],
        restored.runtime.solver_fields[
            @intFromEnum(Runtime.SolverField.matrix_bulk_volume_m3)
        ][41],
    );
    try std.testing.expectEqual(
        runtime.properties.initial_layer_thickness_m[41],
        restored.runtime.solver_fields[
            @intFromEnum(Runtime.SolverField.initial_layer_thickness_m)
        ][41],
    );
    try std.testing.expectEqual(
        runtime.properties.reference_bulk_density_megagrams_per_m3[41],
        restored.runtime.solver_fields[
            @intFromEnum(Runtime.SolverField.reference_bulk_density_megagrams_per_m3)
        ][41],
    );
    try std.testing.expectEqual(
        runtime.properties.charcoal_retention_increment_fraction[41],
        restored.runtime.solver_fields[@intFromEnum(Runtime.SolverField.charcoal_retention_increment_fraction)][41],
    );
    try std.testing.expectEqual(
        runtime.properties.retention_curve[41],
        restored.runtime.retention_curve[41],
    );
    try std.testing.expectEqual(
        runtime.thermal.dry_solid_heat_capacity_megajoules_per_m3_k[41],
        restored.runtime.thermal_fields[
            @intFromEnum(
                Runtime.ThermalField.dry_solid_heat_capacity_megajoules_per_m3_k,
            )
        ][41],
    );
    try std.testing.expectEqual(
        runtime.chemistry_layer_parameters[41]
            .cation_exchange_capacity_mol_charge_per_megagram,
        restored.runtime
            .reaction_cation_exchange_capacity_mol_charge_per_megagram[41],
    );
    try std.testing.expectEqual(
        runtime.chemistry_layer_parameters[41]
            .cation_exchange_parameters.selectivity,
        restored.runtime.exchange_selectivity[41],
    );
    var target_runtime = try TestRuntime.init(std.testing.allocator, 6, 7);
    defer target_runtime.deinit();
    try restored.runtime.restoreInto(
        &target_runtime.properties,
        &target_runtime.thermal,
        target_runtime.chemistry_layer_parameters,
    );
    try std.testing.expectEqual(
        runtime.properties.bulk_density_megagrams_per_m3[41],
        target_runtime.properties.bulk_density_megagrams_per_m3[41],
    );
    try std.testing.expectEqual(
        runtime.properties.initial_layer_thickness_m[41],
        target_runtime.properties.initial_layer_thickness_m[41],
    );
    try std.testing.expectEqual(
        runtime.properties.reference_bulk_density_megagrams_per_m3[41],
        target_runtime.properties.reference_bulk_density_megagrams_per_m3[41],
    );
    try std.testing.expectEqual(
        runtime.properties.charcoal_retention_increment_fraction[41],
        target_runtime.properties.charcoal_retention_increment_fraction[41],
    );
    try std.testing.expectEqual(
        runtime.properties.mualem_van_genuchten_parameters[41],
        target_runtime.properties.mualem_van_genuchten_parameters[41],
    );
    try std.testing.expectEqual(
        runtime.thermal.total_heat_capacity_megajoules_per_m3_k[41],
        target_runtime.thermal.total_heat_capacity_megajoules_per_m3_k[41],
    );
    try std.testing.expectEqual(
        runtime.thermal.layer_thickness_m[41],
        target_runtime.thermal.layer_thickness_m[41],
    );
    try std.testing.expectEqual(
        runtime.chemistry_layer_parameters[41]
            .cation_exchange_capacity_mol_charge_per_megagram,
        target_runtime.chemistry_layer_parameters[41]
            .cation_exchange_capacity_mol_charge_per_megagram,
    );
    try std.testing.expectEqual(
        runtime.chemistry_layer_parameters[41]
            .cation_exchange_parameters.selectivity,
        target_runtime.chemistry_layer_parameters[41]
            .cation_exchange_parameters.selectivity,
    );
    try std.testing.expect(
        target_runtime.thermal.layer_thickness_m[41] !=
            geometry.layer_thickness_m[41],
    );
}

test "soil geometry checkpoint applies limits before allocation" {
    var geometry = try Geometry.init(std.testing.allocator, 6, 7);
    defer geometry.deinit();
    var hydrology = try Hydrology.init(std.testing.allocator, 3, 2, 7, 4);
    defer hydrology.deinit();
    var surface = try Surface.init(std.testing.allocator, 6);
    defer surface.deinit();
    var surface_litter_geometry =
        try SurfaceLitterGeometry.init(std.testing.allocator, 6);
    defer surface_litter_geometry.deinit();
    var erosion = try Erosion.init(std.testing.allocator, 3, 2);
    defer erosion.deinit();
    var suspended = try Suspended.State.initBorrowingSediment(std.testing.allocator, erosion.surface_sediment_megagrams, test_suspended_layout);
    defer suspended.deinit();
    var climate: Climate = .{};
    var eroded_minerals = try ErodedMinerals.init(std.testing.allocator, 6);
    defer eroded_minerals.deinit();
    var runtime = try TestRuntime.init(std.testing.allocator, 6, 7);
    defer runtime.deinit();
    var surface_boundary =
        try TestSurfaceBoundary.init(std.testing.allocator, 6);
    defer surface_boundary.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    const plant_heat = [_]f64{0} ** 12;
    const subsurface_heat = [_]f64{0} ** 42;
    const surface_heat = [_]f64{0} ** 6;
    try write(&bytes.writer, .{ .geometry = &geometry, .hydrology = &hydrology, .surface = &surface, .erosion = &erosion, .suspended = &suspended, .climate = &climate, .eroded_minerals = &eroded_minerals, .runtime = runtime.view(), .surface_boundary = surface_boundary.view(), .surface_litter_geometry = &surface_litter_geometry, .surface_litter_ice_m3 = &surface_heat, .delayed_live_canopy_combustion_heat_megajoules = &plant_heat, .delayed_standing_dead_combustion_heat_megajoules = &plant_heat, .delayed_subsurface_combustion_heat_megajoules = &subsurface_heat, .delayed_root_uptake_heat_megajoules = &subsurface_heat, .delayed_surface_combustion_heat_megajoules = &surface_heat });
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.SoilGeometryCheckpointSoilLayerLimitExceeded, read(std.testing.allocator, &reader, .{ .maximum_columns = 3, .maximum_rows = 2, .maximum_soil_layers = 6, .maximum_snow_layers = 4, .maximum_plants = 12 }));
}

test "soil geometry checkpoint rejects pre-root-uptake-heat schema" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try bytes.writer.writeAll(magic);
    try bytes.writer.writeInt(u32, 12, .little);
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(
        error.UnsupportedSoilGeometryCheckpointVersion,
        read(std.testing.allocator, &reader, .{
            .maximum_columns = 1,
            .maximum_rows = 1,
            .maximum_soil_layers = 1,
            .maximum_snow_layers = 1,
            .maximum_plants = 1,
        }),
    );
}

test "soil geometry checkpoint rejects pre-material-refresh schema" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try bytes.writer.writeAll(magic);
    try bytes.writer.writeInt(u32, 15, .little);
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(
        error.UnsupportedSoilGeometryCheckpointVersion,
        read(std.testing.allocator, &reader, .{
            .maximum_columns = 1,
            .maximum_rows = 1,
            .maximum_soil_layers = 1,
            .maximum_snow_layers = 1,
            .maximum_plants = 1,
        }),
    );
}

test "soil geometry checkpoint rejects pre-Gapon-persistence schema" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try bytes.writer.writeAll(magic);
    try bytes.writer.writeInt(u32, 21, .little);
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(
        error.UnsupportedSoilGeometryCheckpointVersion,
        read(std.testing.allocator, &reader, .{
            .maximum_columns = 1,
            .maximum_rows = 1,
            .maximum_soil_layers = 1,
            .maximum_snow_layers = 1,
            .maximum_plants = 1,
        }),
    );
}

test "soil geometry checkpoint rejects pre-adaptive-schedule schema" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try bytes.writer.writeAll(magic);
    try bytes.writer.writeInt(u32, 22, .little);
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(
        error.UnsupportedSoilGeometryCheckpointVersion,
        read(std.testing.allocator, &reader, .{
            .maximum_columns = 1,
            .maximum_rows = 1,
            .maximum_soil_layers = 1,
            .maximum_snow_layers = 1,
            .maximum_plants = 1,
        }),
    );
}

fn readValidCheckpointWithAllocator(
    allocator: std.mem.Allocator,
    checkpoint_bytes: []const u8,
) !void {
    var reader: std.Io.Reader = .fixed(checkpoint_bytes);
    var restored = try read(allocator, &reader, .{
        .maximum_columns = 1,
        .maximum_rows = 1,
        .maximum_soil_layers = 1,
        .maximum_snow_layers = 1,
        .maximum_plants = 1,
    });
    restored.deinit();
}

test "soil geometry checkpoint rejects corruption nonfinite state every truncation and allocation failure" {
    var geometry = try Geometry.init(std.testing.allocator, 1, 1);
    defer geometry.deinit();
    var hydrology = try Hydrology.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var surface = try Surface.init(std.testing.allocator, 1);
    defer surface.deinit();
    var surface_litter_geometry =
        try SurfaceLitterGeometry.init(std.testing.allocator, 1);
    defer surface_litter_geometry.deinit();
    var erosion = try Erosion.init(std.testing.allocator, 1, 1);
    defer erosion.deinit();
    var suspended = try Suspended.State.initBorrowingSediment(std.testing.allocator, erosion.surface_sediment_megagrams, test_suspended_layout);
    defer suspended.deinit();
    var climate: Climate = .{};
    var eroded_minerals = try ErodedMinerals.init(std.testing.allocator, 1);
    defer eroded_minerals.deinit();
    var runtime = try TestRuntime.init(std.testing.allocator, 1, 1);
    defer runtime.deinit();
    var surface_boundary =
        try TestSurfaceBoundary.init(std.testing.allocator, 1);
    defer surface_boundary.deinit();
    geometry.boundary_depth_m[0] = std.math.nan(f64);
    var invalid: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid.deinit();
    const heat = [_]f64{0};
    try std.testing.expectError(error.NonFiniteSoilGeometryCheckpoint, write(&invalid.writer, .{ .geometry = &geometry, .hydrology = &hydrology, .surface = &surface, .erosion = &erosion, .suspended = &suspended, .climate = &climate, .eroded_minerals = &eroded_minerals, .runtime = runtime.view(), .surface_boundary = surface_boundary.view(), .surface_litter_geometry = &surface_litter_geometry, .surface_litter_ice_m3 = &heat, .delayed_live_canopy_combustion_heat_megajoules = &heat, .delayed_standing_dead_combustion_heat_megajoules = &heat, .delayed_subsurface_combustion_heat_megajoules = &heat, .delayed_root_uptake_heat_megajoules = &heat, .delayed_surface_combustion_heat_megajoules = &heat }));
    geometry.boundary_depth_m[0] = 0;
    runtime.properties.field_capacity_fraction[0] = 0.26;
    var invalid_runtime: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid_runtime.deinit();
    try std.testing.expectError(error.InvalidSoilRuntimeCheckpointState, write(&invalid_runtime.writer, .{ .geometry = &geometry, .hydrology = &hydrology, .surface = &surface, .erosion = &erosion, .suspended = &suspended, .climate = &climate, .eroded_minerals = &eroded_minerals, .runtime = runtime.view(), .surface_boundary = surface_boundary.view(), .surface_litter_geometry = &surface_litter_geometry, .surface_litter_ice_m3 = &heat, .delayed_live_canopy_combustion_heat_megajoules = &heat, .delayed_standing_dead_combustion_heat_megajoules = &heat, .delayed_subsurface_combustion_heat_megajoules = &heat, .delayed_root_uptake_heat_megajoules = &heat, .delayed_surface_combustion_heat_megajoules = &heat }));
    runtime.properties.field_capacity_fraction[0] = 0.25;
    runtime.properties.micropore_fraction[0] = 1.1;
    var invalid_metadata: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid_metadata.deinit();
    try std.testing.expectError(error.InvalidSoilRuntimeCheckpointState, write(&invalid_metadata.writer, .{ .geometry = &geometry, .hydrology = &hydrology, .surface = &surface, .erosion = &erosion, .suspended = &suspended, .climate = &climate, .eroded_minerals = &eroded_minerals, .runtime = runtime.view(), .surface_boundary = surface_boundary.view(), .surface_litter_geometry = &surface_litter_geometry, .surface_litter_ice_m3 = &heat, .delayed_live_canopy_combustion_heat_megajoules = &heat, .delayed_standing_dead_combustion_heat_megajoules = &heat, .delayed_subsurface_combustion_heat_megajoules = &heat, .delayed_root_uptake_heat_megajoules = &heat, .delayed_surface_combustion_heat_megajoules = &heat }));
    runtime.properties.micropore_fraction[0] = 1;
    runtime.chemistry_layer_parameters[0]
        .cation_exchange_capacity_mol_charge_per_megagram = std.math.nan(f64);
    var invalid_reaction_parameters: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid_reaction_parameters.deinit();
    try std.testing.expectError(error.InvalidSoilRuntimeCheckpointState, write(&invalid_reaction_parameters.writer, .{ .geometry = &geometry, .hydrology = &hydrology, .surface = &surface, .erosion = &erosion, .suspended = &suspended, .climate = &climate, .eroded_minerals = &eroded_minerals, .runtime = runtime.view(), .surface_boundary = surface_boundary.view(), .surface_litter_geometry = &surface_litter_geometry, .surface_litter_ice_m3 = &heat, .delayed_live_canopy_combustion_heat_megajoules = &heat, .delayed_standing_dead_combustion_heat_megajoules = &heat, .delayed_subsurface_combustion_heat_megajoules = &heat, .delayed_root_uptake_heat_megajoules = &heat, .delayed_surface_combustion_heat_megajoules = &heat }));
    runtime.chemistry_layer_parameters[0]
        .cation_exchange_capacity_mol_charge_per_megagram = 1;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .geometry = &geometry, .hydrology = &hydrology, .surface = &surface, .erosion = &erosion, .suspended = &suspended, .climate = &climate, .eroded_minerals = &eroded_minerals, .runtime = runtime.view(), .surface_boundary = surface_boundary.view(), .surface_litter_geometry = &surface_litter_geometry, .surface_litter_ice_m3 = &heat, .delayed_live_canopy_combustion_heat_megajoules = &heat, .delayed_standing_dead_combustion_heat_megajoules = &heat, .delayed_subsurface_combustion_heat_megajoules = &heat, .delayed_root_uptake_heat_megajoules = &heat, .delayed_surface_combustion_heat_megajoules = &heat });
    const valid_checkpoint = bytes.written();
    for (0..valid_checkpoint.len) |end| {
        var truncated: std.Io.Reader = .fixed(valid_checkpoint[0..end]);
        try std.testing.expectError(
            error.EndOfStream,
            read(std.testing.allocator, &truncated, .{
                .maximum_columns = 1,
                .maximum_rows = 1,
                .maximum_soil_layers = 1,
                .maximum_snow_layers = 1,
                .maximum_plants = 1,
            }),
        );
    }
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        readValidCheckpointWithAllocator,
        .{valid_checkpoint},
    );
    try bytes.writer.writeByte(0xff);
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.TrailingSoilGeometryCheckpointData, read(std.testing.allocator, &reader, .{ .maximum_columns = 1, .maximum_rows = 1, .maximum_soil_layers = 1, .maximum_snow_layers = 1, .maximum_plants = 1 }));
}

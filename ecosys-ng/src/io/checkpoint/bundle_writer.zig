const std = @import("std");
const manifest_module = @import("manifest.zig");
const bundle_io = @import("bundle_io.zig");
const checkpoint = @import("checkpoint.zig");
const metadata_checkpoint = @import("plant_checkpoint_metadata.zig");
const development_checkpoint = @import("plant_development_checkpoint.zig");
const root_checkpoint = @import("plant_root_checkpoint.zig");
const canopy_checkpoint = @import("canopy_state_checkpoint.zig");
const biogeochemistry_checkpoint = @import("soil_biogeochemistry_checkpoint.zig");
const organic_checkpoint = @import("soil_organic_checkpoint.zig");
const transport_checkpoint = @import("transport_state_checkpoint.zig");
const geometry_checkpoint = @import("soil_geometry_checkpoint.zig");
const mass_balance_checkpoint = @import("landscape_mass_balance_checkpoint.zig");
const accounting_checkpoint = @import("plant_accounting_checkpoint.zig");
const GridState = @import("../../state/grid.zig").GridState;
const PlantState = @import("../../state/grid.zig").PlantState;
const RootState = @import("../../plant/root/plant_root_system.zig").State;

pub const LiveView = struct {
    grid: *const GridState,
    plants: *const PlantState,
    plant_metadata_cells: []const metadata_checkpoint.CellView,
    plant_development: development_checkpoint.View,
    plant_roots: *const RootState,
    plant_canopy: canopy_checkpoint.View,
    soil_biogeochemistry: biogeochemistry_checkpoint.View,
    soil_organic_matter: organic_checkpoint.View,
    transport: transport_checkpoint.View,
    soil_geometry_and_hydrology: geometry_checkpoint.View,
    landscape_mass_balance: mass_balance_checkpoint.State,
    plant_accounting: accounting_checkpoint.View,
};

pub const Settings = struct {
    section_write_buffer_bytes: usize,
    section_verify_buffer_bytes: usize,
    manifest_write_buffer_bytes: usize,
    manifest_file_name: []const u8 = "restart.manifest",
};

/// Writes every owner under a generation-specific name. Only after all eleven
/// files have been synchronized and independently digested is the manifest
/// atomically replaced, making the new simulation instant visible to readers.
pub fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    generation: u64,
    instant: manifest_module.SimulationInstant,
    output: manifest_module.OutputIdentitySource,
    shape: manifest_module.RuntimeShape,
    live: LiveView,
    settings: Settings,
) !void {
    if (generation == 0) return error.InvalidCheckpointGeneration;
    try validateSettings(settings);
    try validateShape(shape, live);
    var names: [manifest_module.section_count][]u8 = undefined;
    var name_count: usize = 0;
    defer for (names[0..name_count]) |name| allocator.free(name);
    inline for (@typeInfo(manifest_module.Section).@"enum".fields, 0..) |field, index| {
        names[index] = try std.fmt.allocPrint(allocator, "{d}.{s}.bin", .{ generation, field.name });
        name_count += 1;
    }

    var descriptors: [manifest_module.section_count]manifest_module.EntryDescriptor = undefined;
    const write_bytes = settings.section_write_buffer_bytes;
    const verify_bytes = settings.section_verify_buffer_bytes;
    descriptors[0] = try bundle_io.publishSectionAtomic(allocator, io, directory, .grid_and_plants, names[0], write_bytes, verify_bytes, CoupledContext{ .grid = live.grid, .plants = live.plants }, writeCoupled);
    descriptors[1] = try bundle_io.publishSectionAtomic(allocator, io, directory, .plant_metadata, names[1], write_bytes, verify_bytes, MetadataContext{ .instant = instant, .cells = live.plant_metadata_cells }, writeMetadata);
    descriptors[2] = try bundle_io.publishSectionAtomic(allocator, io, directory, .plant_development, names[2], write_bytes, verify_bytes, live.plant_development, writeDevelopment);
    descriptors[3] = try bundle_io.publishSectionAtomic(allocator, io, directory, .plant_roots, names[3], write_bytes, verify_bytes, live.plant_roots, writeRoots);
    descriptors[4] = try bundle_io.publishSectionAtomic(allocator, io, directory, .plant_canopy, names[4], write_bytes, verify_bytes, live.plant_canopy, writeCanopy);
    descriptors[5] = try bundle_io.publishSectionAtomic(allocator, io, directory, .soil_biogeochemistry, names[5], write_bytes, verify_bytes, live.soil_biogeochemistry, writeBiogeochemistry);
    descriptors[6] = try bundle_io.publishSectionAtomic(allocator, io, directory, .soil_organic_matter, names[6], write_bytes, verify_bytes, live.soil_organic_matter, writeOrganic);
    descriptors[7] = try bundle_io.publishSectionAtomic(allocator, io, directory, .solute_gas_and_snow_transport, names[7], write_bytes, verify_bytes, live.transport, writeTransport);
    descriptors[8] = try bundle_io.publishSectionAtomic(allocator, io, directory, .soil_geometry_and_hydrology, names[8], write_bytes, verify_bytes, live.soil_geometry_and_hydrology, writeGeometry);
    descriptors[9] = try bundle_io.publishSectionAtomic(allocator, io, directory, .landscape_mass_balance, names[9], write_bytes, verify_bytes, live.landscape_mass_balance, writeMassBalance);
    descriptors[10] = try bundle_io.publishSectionAtomic(allocator, io, directory, .plant_accounting, names[10], write_bytes, verify_bytes, live.plant_accounting, writeAccounting);

    var manifest = try manifest_module.buildFromDescriptors(allocator, generation, instant, output, shape, &descriptors);
    defer manifest.deinit();
    try manifest_module.publishAtomic(allocator, io, directory, settings.manifest_file_name, manifest, settings.manifest_write_buffer_bytes);
}

fn validateSettings(settings: Settings) !void {
    if (settings.section_write_buffer_bytes == 0 or
        settings.section_verify_buffer_bytes == 0 or
        settings.manifest_write_buffer_bytes == 0)
        return error.InvalidCheckpointBundleBufferSize;
    if (!safeFileName(settings.manifest_file_name))
        return error.InvalidCheckpointFileName;
}

fn safeFileName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
        return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (name[0] == ' ' or name[name.len - 1] == ' ' or name[name.len - 1] == '.')
        return false;
    for (name) |byte| {
        if (byte == 0 or byte < 0x20 or
            std.mem.indexOfScalar(u8, "/\\<>:\"|?*", byte) != null)
            return false;
    }
    return true;
}

fn validateShape(shape: manifest_module.RuntimeShape, live: LiveView) !void {
    const cells = std.math.mul(usize, shape.columns, shape.rows) catch return error.CheckpointLiveShapeMismatch;
    const plants = std.math.mul(usize, cells, shape.plant_species_per_cell) catch return error.CheckpointLiveShapeMismatch;
    try accounting_checkpoint.validateView(live.plant_accounting, plants);
    try mass_balance_checkpoint.validateShape(live.landscape_mass_balance, .{
        .cell_count = cells,
        .soil_layer_capacity = shape.soil_layers,
        .snow_layer_capacity = shape.snow_layers,
    });
    if (live.grid.cell_count != cells or live.grid.soil_layer_capacity != shape.soil_layers or live.plants.cell_count != cells or live.plants.species_count != shape.plant_species_per_cell or live.plant_roots.plant_count != plants or live.plant_roots.soil_layer_count != shape.soil_layers or live.plant_roots.root_axis_count != shape.root_axes_per_plant or live.plant_canopy.canopy.cell_count != cells or live.plant_canopy.canopy.species_count != shape.plant_species_per_cell or live.plant_canopy.layer_distribution.cell_count != cells or live.plant_canopy.layer_distribution.species_count != shape.plant_species_per_cell or live.plant_metadata_cells.len != cells or live.soil_biogeochemistry.microbial_thermal_adaptation.cell_count != cells or live.soil_biogeochemistry.fertilizer.cell_count != cells or live.soil_biogeochemistry.fertilizer.layer_capacity != shape.soil_layers or live.soil_biogeochemistry.fertilizer_band.cell_count != cells or live.soil_biogeochemistry.fertilizer_band.layer_capacity != shape.soil_layers or live.soil_biogeochemistry.nutrient_competition.soil_layer_count != cells * shape.soil_layers or live.soil_biogeochemistry.nutrient_competition.surface_cell_count != cells or live.soil_organic_matter.surface.layer_count != cells or live.soil_organic_matter.litter_chemistry.cells.len != cells or live.soil_organic_matter.litter_fertilizer.cells.len != cells or live.soil_organic_matter.litter_fertilizer.formulation.len != cells or live.soil_organic_matter.surface_respiration.cell_count != cells or live.soil_organic_matter.surface_denitrification.cell_count != cells or live.soil_organic_matter.surface_fire_exchange.layer_count != cells or live.soil_organic_matter.litter_salt_ingress.cell_count != cells or live.soil_organic_matter.litter_salt_ingress.soil_layer_capacity != shape.soil_layers or live.transport.organic.layer_count != cells * shape.soil_layers or live.transport.litter_gas.cell_count != cells or live.transport.snow.cell_count != cells or live.transport.snow.layer_capacity != shape.snow_layers or live.soil_geometry_and_hydrology.geometry.cell_count != cells or live.soil_geometry_and_hydrology.geometry.layer_capacity != shape.soil_layers or live.soil_geometry_and_hydrology.surface_litter_geometry.cell_count != cells or live.soil_geometry_and_hydrology.erosion.cell_count != cells or live.soil_geometry_and_hydrology.suspended.cell_count != cells or live.soil_geometry_and_hydrology.suspended.sediment_megagrams.ptr != live.soil_geometry_and_hydrology.erosion.surface_sediment_megagrams.ptr or live.soil_geometry_and_hydrology.eroded_minerals.workspace.cell_count != cells) return error.CheckpointLiveShapeMismatch;
    const layer_cells = std.math.mul(usize, cells, shape.soil_layers) catch return error.CheckpointLiveShapeMismatch;
    if (live.soil_geometry_and_hydrology.delayed_live_canopy_combustion_heat_megajoules.len != plants or live.soil_geometry_and_hydrology.delayed_standing_dead_combustion_heat_megajoules.len != plants or live.soil_geometry_and_hydrology.delayed_subsurface_combustion_heat_megajoules.len != layer_cells or live.soil_geometry_and_hydrology.delayed_root_uptake_heat_megajoules.len != layer_cells or live.soil_geometry_and_hydrology.delayed_surface_combustion_heat_megajoules.len != cells or live.soil_geometry_and_hydrology.surface_litter_ice_m3.len != cells) return error.CheckpointLiveShapeMismatch;
    const runtime = live.soil_geometry_and_hydrology.runtime orelse
        return error.MissingSoilRuntimeCheckpointState;
    try @import("soil_runtime_checkpoint.zig").validateView(runtime);
    const surface_boundary =
        live.soil_geometry_and_hydrology.surface_boundary orelse
        return error.MissingSurfaceBoundaryCheckpointState;
    try @import("surface_boundary_checkpoint.zig").validateView(
        surface_boundary,
    );
    const water_table = live.soil_geometry_and_hydrology.water_table orelse
        return error.MissingWaterTableCheckpointState;
    try @import("water_table_checkpoint.zig").validateView(water_table);
}

const CoupledContext = struct { grid: *const GridState, plants: *const PlantState };
fn writeCoupled(writer: anytype, context: CoupledContext) !void {
    try checkpoint.writeCoupled(writer, context.grid.*, context.plants.*);
}
const MetadataContext = struct { instant: manifest_module.SimulationInstant, cells: []const metadata_checkpoint.CellView };
fn writeMetadata(writer: anytype, context: MetadataContext) !void {
    try metadata_checkpoint.write(writer, context.instant.day_of_year, context.instant.year, context.cells);
}
fn writeDevelopment(writer: anytype, view: development_checkpoint.View) !void {
    try development_checkpoint.write(writer, view);
}
fn writeRoots(writer: anytype, state: *const RootState) !void {
    try root_checkpoint.write(writer, state.*);
}
fn writeCanopy(writer: anytype, view: canopy_checkpoint.View) !void {
    try canopy_checkpoint.write(writer, view);
}
fn writeBiogeochemistry(writer: anytype, view: biogeochemistry_checkpoint.View) !void {
    try biogeochemistry_checkpoint.write(writer, view);
}
fn writeOrganic(writer: anytype, view: organic_checkpoint.View) !void {
    try organic_checkpoint.write(writer, view);
}
fn writeTransport(writer: anytype, view: transport_checkpoint.View) !void {
    try transport_checkpoint.write(writer, view);
}
fn writeGeometry(writer: anytype, view: geometry_checkpoint.View) !void {
    try geometry_checkpoint.write(writer, view);
}
fn writeMassBalance(writer: anytype, state: mass_balance_checkpoint.State) !void {
    try mass_balance_checkpoint.write(writer, state);
}
fn writeAccounting(writer: anytype, view: accounting_checkpoint.View) !void {
    try accounting_checkpoint.write(writer, view);
}

test "bundle writer rejects invalid settings before generation I/O" {
    inline for (.{
        Settings{
            .section_write_buffer_bytes = 0,
            .section_verify_buffer_bytes = 8,
            .manifest_write_buffer_bytes = 8,
        },
        Settings{
            .section_write_buffer_bytes = 8,
            .section_verify_buffer_bytes = 0,
            .manifest_write_buffer_bytes = 8,
        },
        Settings{
            .section_write_buffer_bytes = 8,
            .section_verify_buffer_bytes = 8,
            .manifest_write_buffer_bytes = 0,
        },
    }) |settings| try std.testing.expectError(
        error.InvalidCheckpointBundleBufferSize,
        validateSettings(settings),
    );

    inline for (.{
        "",
        "../restart.manifest",
        "subdir/restart.manifest",
        "subdir\\restart.manifest",
        " restart.manifest",
        "restart.manifest ",
        "restart.",
        "restart:1.manifest",
        "restart|1.manifest",
        "restart?1.manifest",
    }) |name| try std.testing.expectError(
        error.InvalidCheckpointFileName,
        validateSettings(.{
            .section_write_buffer_bytes = 8,
            .section_verify_buffer_bytes = 8,
            .manifest_write_buffer_bytes = 8,
            .manifest_file_name = name,
        }),
    );
}

test "bundle writer accepts portable runtime settings" {
    inline for (.{ "restart", "restart-1.manifest", "restart.1.manifest" }) |name|
        try validateSettings(.{
            .section_write_buffer_bytes = 8,
            .section_verify_buffer_bytes = 8,
            .manifest_write_buffer_bytes = 8,
            .manifest_file_name = name,
        });
}

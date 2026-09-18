const std = @import("std");
const Solute = @import("../../soil/solute/transport.zig").State;
const AqueousSpecies = @import("../../soil/solute/transport_species.zig").AqueousSpecies;
const GasModule = @import("../../soil/gas/transport.zig");
const Gas = GasModule.State;
const AmmoniaBridge = @import("../../soil/gas/ammonia_phase_bridge.zig");
const LitterAmmoniaBridge = @import("../../surface/litter_ammonia_phase_bridge.zig");
const SnowModule = @import("../../soil/solute/snow_solute_transport.zig");
const Snow = SnowModule.State;
const SnowSurfaceExchange = @import("../../soil/water/snow_surface_atmosphere_exchange.zig");
const Surface = @import("../../soil/solute/surface_solute_routing.zig").State;
const MineralNitrogen = @import("../../soil/biogeochemistry/mineral_nitrogen_transport.zig").State;
const OrganicTransport = @import("../../soil/organic/transport.zig").State;
const magic = "ECOSTRNS";
// Version 12 requires the canonical 54-coordinate aqueous layout. Version 11
// carried only the original 50 soil coordinates, so accepting it would swap a
// short owner into 54-wide runtime workspaces and fail after restart. Version
// 10's soil and surface-litter aqueous NH3 gas slots remain transient: they
// stay on the wire for fixed-layout decoding but are cleared after read and
// rebuilt from chemistry.
const version: u32 = 12;
pub const View = struct { micropore: *const Solute, macropore: *const Solute, mineral_nitrogen: *const MineralNitrogen, organic: *const OrganicTransport, gas: *const Gas, litter_gas: *const Gas, snow: *const Snow, surface: *const Surface };
pub const Limits = struct { maximum_transport_cells: usize, maximum_solute_species: usize, maximum_snow_cells: usize, maximum_snow_layers: usize };
pub const Owned = struct {
    micropore: Solute,
    macropore: Solute,
    mineral_nitrogen: MineralNitrogen,
    organic: OrganicTransport,
    gas: Gas,
    litter_gas: Gas,
    snow: Snow,
    surface: Surface,
    pub fn deinit(self: *Owned) void {
        self.surface.deinit();
        self.snow.deinit();
        self.litter_gas.deinit();
        self.gas.deinit();
        self.organic.deinit();
        self.mineral_nitrogen.deinit();
        self.macropore.deinit();
        self.micropore.deinit();
        self.* = undefined;
    }
};

/// Checkpoint and live transport owners must use the same canonical coordinate
/// space. This check is intentionally independent of numerical-state
/// validation so rollback can still validate layout after a failed solve.
pub fn validateCanonicalSpeciesDimensions(view: View) !void {
    if (view.micropore.species_count != AqueousSpecies.count or
        view.macropore.species_count != AqueousSpecies.count or
        view.surface.species_count != AqueousSpecies.count)
        return error.InvalidTransportCheckpointSpeciesCount;
    const micropore_amount_count = std.math.mul(usize, view.micropore.cell_count, AqueousSpecies.count) catch
        return error.InvalidTransportCheckpointDimensions;
    const macropore_amount_count = std.math.mul(usize, view.macropore.cell_count, AqueousSpecies.count) catch
        return error.InvalidTransportCheckpointDimensions;
    const surface_cells = std.math.mul(usize, view.surface.columns, view.surface.rows) catch
        return error.InvalidTransportCheckpointDimensions;
    const surface_amount_count = std.math.mul(usize, surface_cells, AqueousSpecies.count) catch
        return error.InvalidTransportCheckpointDimensions;
    if (view.micropore.water_volume_m3.len != view.micropore.cell_count or
        view.micropore.amount_mol.len != micropore_amount_count or
        view.macropore.water_volume_m3.len != view.macropore.cell_count or
        view.macropore.amount_mol.len != macropore_amount_count or
        view.surface.carrier_volume_m3.len != surface_cells or
        view.surface.amount_mol.len != surface_amount_count)
        return error.InvalidTransportCheckpointDimensions;
}

pub fn write(writer: anytype, view: View) !void {
    try validate(view);
    try writer.writeAll(magic);
    try writer.writeInt(u32, version, .little);
    try writer.writeInt(u64, @intCast(view.micropore.cell_count), .little);
    try writer.writeInt(u64, @intCast(view.micropore.species_count), .little);
    try writer.writeInt(u64, @intCast(view.snow.cell_count), .little);
    try writer.writeInt(u64, @intCast(view.snow.layer_capacity), .little);
    try writer.writeInt(u64, @intCast(view.surface.columns), .little);
    try writer.writeInt(u64, @intCast(view.surface.rows), .little);
    try writer.writeInt(u64, @intCast(view.surface.species_count), .little);
    inline for (.{ view.micropore.water_volume_m3, view.micropore.amount_mol, view.macropore.water_volume_m3, view.macropore.amount_mol, view.gas.air_volume_m3, view.gas.temperature_k, view.gas.water_vapor_mol, view.gas.gaseous_mass_g, view.gas.dissolved_mass_g, view.gas.macropore_dissolved_mass_g, view.gas.band_dissolved_mass_g }) |values| try writeF64Slice(writer, values);
    inline for (.{ view.mineral_nitrogen.matrix.water_volume_m3, view.mineral_nitrogen.matrix.amount_mol, view.mineral_nitrogen.macropore.water_volume_m3, view.mineral_nitrogen.macropore.amount_mol, view.mineral_nitrogen.boundary_export_g_n_per_step }) |values| try writeF64Slice(writer, values);
    inline for (.{ view.organic.micropore_amount_g, view.organic.macropore_amount_g, view.organic.boundary_net_flux_g }) |values| try writeF64Slice(writer, values);
    inline for (.{ view.litter_gas.air_volume_m3, view.litter_gas.temperature_k, view.litter_gas.water_vapor_mol, view.litter_gas.gaseous_mass_g, view.litter_gas.dissolved_mass_g, view.litter_gas.macropore_dissolved_mass_g, view.litter_gas.band_dissolved_mass_g }) |values| try writeF64Slice(writer, values);
    try writeBoolSlice(writer, view.snow.active);
    inline for (.{ view.snow.solid_snow_water_equivalent_m3, view.snow.liquid_water_volume_m3, view.snow.vapor_water_equivalent_m3, view.snow.ice_volume_m3, view.snow.air_filled_volume_m3, view.snow.total_layer_volume_m3, view.snow.target_layer_volume_m3, view.snow.layer_thickness_m, view.snow.cumulative_depth_m, view.snow.snow_density_megagrams_per_m3, view.snow.temperature_k, view.snow.heat_capacity_megajoules_per_k, view.snow.horizontal_area_m2 }) |values| try writeF64Slice(writer, values);
    try writeF64Slice(writer, view.snow.amount_g);
    try writeBoolSlice(writer, view.snow.dynamic_salts_by_cell);
    try writeF64Slice(writer, view.snow.salt_amount_mol);
    try writeF64Slice(writer, view.surface.carrier_volume_m3);
    try writeF64Slice(writer, view.surface.amount_mol);
}

pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) !Owned {
    if (limits.maximum_transport_cells == 0 or limits.maximum_solute_species == 0 or limits.maximum_snow_cells == 0 or limits.maximum_snow_layers == 0) return error.InvalidTransportCheckpointLimits;
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic)) return error.InvalidTransportCheckpointMagic;
    if (try reader.takeInt(u32, .little) != version) return error.UnsupportedTransportCheckpointVersion;
    const cells = try bounded(reader, limits.maximum_transport_cells, error.TransportCheckpointCellLimitExceeded);
    const species = try bounded(reader, limits.maximum_solute_species, error.TransportCheckpointSpeciesLimitExceeded);
    const snow_cells = try bounded(reader, limits.maximum_snow_cells, error.TransportCheckpointSnowCellLimitExceeded);
    const snow_layers = try bounded(reader, limits.maximum_snow_layers, error.TransportCheckpointSnowLayerLimitExceeded);
    const surface_columns = try bounded(reader, limits.maximum_transport_cells, error.TransportCheckpointCellLimitExceeded);
    const surface_rows = try bounded(reader, limits.maximum_transport_cells, error.TransportCheckpointCellLimitExceeded);
    const surface_species = try bounded(reader, limits.maximum_solute_species, error.TransportCheckpointSpeciesLimitExceeded);
    if (cells == 0 or species == 0 or snow_cells == 0 or snow_layers == 0) return error.InvalidTransportCheckpointDimensions;
    // Reject stale 50-coordinate and otherwise incompatible owners before the
    // first allocation or payload read. Macropore shares the soil species
    // header; surface carries its own width on the wire.
    if (species != AqueousSpecies.count or surface_species != AqueousSpecies.count)
        return error.InvalidTransportCheckpointSpeciesCount;
    var micropore = try Solute.init(allocator, cells, species);
    errdefer micropore.deinit();
    var macropore = try Solute.init(allocator, cells, species);
    errdefer macropore.deinit();
    var mineral_nitrogen = try MineralNitrogen.init(allocator, cells);
    errdefer mineral_nitrogen.deinit();
    var organic_transport = try OrganicTransport.init(allocator, cells);
    errdefer organic_transport.deinit();
    var gas = try Gas.init(allocator, cells);
    errdefer gas.deinit();
    var litter_gas = try Gas.init(allocator, snow_cells);
    errdefer litter_gas.deinit();
    var snow = try Snow.init(allocator, snow_cells, snow_layers);
    errdefer snow.deinit();
    var surface = try Surface.init(allocator, surface_columns, surface_rows, surface_species);
    errdefer surface.deinit();
    inline for (.{ micropore.water_volume_m3, micropore.amount_mol, macropore.water_volume_m3, macropore.amount_mol, gas.air_volume_m3, gas.temperature_k, gas.water_vapor_mol, gas.gaseous_mass_g, gas.dissolved_mass_g, gas.macropore_dissolved_mass_g, gas.band_dissolved_mass_g }) |values| try readF64Slice(reader, values);
    inline for (.{ mineral_nitrogen.matrix.water_volume_m3, mineral_nitrogen.matrix.amount_mol, mineral_nitrogen.macropore.water_volume_m3, mineral_nitrogen.macropore.amount_mol, mineral_nitrogen.boundary_export_g_n_per_step }) |values| try readF64Slice(reader, values);
    try AmmoniaBridge.clearTransient(&gas);
    inline for (.{ organic_transport.micropore_amount_g, organic_transport.macropore_amount_g, organic_transport.boundary_net_flux_g }) |values| try readF64Slice(reader, values);
    inline for (.{ litter_gas.air_volume_m3, litter_gas.temperature_k, litter_gas.water_vapor_mol, litter_gas.gaseous_mass_g, litter_gas.dissolved_mass_g, litter_gas.macropore_dissolved_mass_g, litter_gas.band_dissolved_mass_g }) |values| try readF64Slice(reader, values);
    try LitterAmmoniaBridge.clearTransient(&litter_gas);
    try readBoolSlice(reader, snow.active);
    inline for (.{ snow.solid_snow_water_equivalent_m3, snow.liquid_water_volume_m3, snow.vapor_water_equivalent_m3, snow.ice_volume_m3, snow.air_filled_volume_m3, snow.total_layer_volume_m3, snow.target_layer_volume_m3, snow.layer_thickness_m, snow.cumulative_depth_m, snow.snow_density_megagrams_per_m3, snow.temperature_k, snow.heat_capacity_megajoules_per_k, snow.horizontal_area_m2 }) |values| try readF64Slice(reader, values);
    try readF64Slice(reader, snow.amount_g);
    try readBoolSlice(reader, snow.dynamic_salts_by_cell);
    try readF64Slice(reader, snow.salt_amount_mol);
    try readF64Slice(reader, surface.carrier_volume_m3);
    try readF64Slice(reader, surface.amount_mol);
    if (reader.peekByte()) |_| return error.TrailingTransportCheckpointData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    const result = Owned{ .micropore = micropore, .macropore = macropore, .mineral_nitrogen = mineral_nitrogen, .organic = organic_transport, .gas = gas, .litter_gas = litter_gas, .snow = snow, .surface = surface };
    try validate(.{ .micropore = &result.micropore, .macropore = &result.macropore, .mineral_nitrogen = &result.mineral_nitrogen, .organic = &result.organic, .gas = &result.gas, .litter_gas = &result.litter_gas, .snow = &result.snow, .surface = &result.surface });
    return result;
}

fn validate(view: View) !void {
    try validateCanonicalSpeciesDimensions(view);
    if (view.micropore.cell_count == 0 or view.micropore.species_count == 0 or view.macropore.cell_count != view.micropore.cell_count or view.macropore.species_count != view.micropore.species_count or view.mineral_nitrogen.cell_count != view.micropore.cell_count or view.organic.layer_count != view.micropore.cell_count or view.gas.cell_count != view.micropore.cell_count or view.snow.cell_count == 0 or view.litter_gas.cell_count != view.snow.cell_count or view.snow.layer_capacity == 0 or view.surface.columns == 0 or view.surface.rows == 0 or view.surface.species_count != view.micropore.species_count or try std.math.mul(usize, view.surface.columns, view.surface.rows) != view.snow.cell_count) return error.InvalidTransportCheckpointDimensions;
    if (view.snow.dynamic_salts_by_cell.len != view.snow.cell_count or view.snow.salt_amount_mol.len != view.snow.cell_count * view.snow.layer_capacity * @import("../../soil/solute/snow_solute_transport.zig").salt_species_count) return error.InvalidTransportCheckpointDimensions;
    inline for (.{ view.micropore.water_volume_m3, view.micropore.amount_mol, view.macropore.water_volume_m3, view.macropore.amount_mol, view.gas.air_volume_m3, view.gas.water_vapor_mol, view.gas.gaseous_mass_g, view.gas.dissolved_mass_g, view.gas.macropore_dissolved_mass_g, view.gas.band_dissolved_mass_g, view.snow.solid_snow_water_equivalent_m3, view.snow.liquid_water_volume_m3, view.snow.vapor_water_equivalent_m3, view.snow.ice_volume_m3, view.snow.air_filled_volume_m3, view.snow.total_layer_volume_m3, view.snow.target_layer_volume_m3, view.snow.layer_thickness_m, view.snow.cumulative_depth_m, view.snow.snow_density_megagrams_per_m3, view.snow.temperature_k, view.snow.heat_capacity_megajoules_per_k, view.snow.horizontal_area_m2, view.snow.amount_g, view.snow.salt_amount_mol, view.surface.carrier_volume_m3, view.surface.amount_mol }) |values| try validateNonnegative(values);
    inline for (.{ view.litter_gas.air_volume_m3, view.litter_gas.water_vapor_mol, view.litter_gas.gaseous_mass_g, view.litter_gas.dissolved_mass_g, view.litter_gas.macropore_dissolved_mass_g, view.litter_gas.band_dissolved_mass_g }) |values| try validateNonnegative(values);
    inline for (.{ view.mineral_nitrogen.matrix.water_volume_m3, view.mineral_nitrogen.matrix.amount_mol, view.mineral_nitrogen.macropore.water_volume_m3, view.mineral_nitrogen.macropore.amount_mol, view.mineral_nitrogen.boundary_export_g_n_per_step }) |values| try validateNonnegative(values);
    inline for (.{ view.organic.micropore_amount_g, view.organic.macropore_amount_g }) |values| try validateNonnegative(values);
    for (view.organic.boundary_net_flux_g) |value| if (!std.math.isFinite(value)) return error.InvalidTransportCheckpointInventory;
    for (view.gas.temperature_k) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidTransportCheckpointTemperature;
    for (view.litter_gas.temperature_k) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidTransportCheckpointTemperature;
}
fn validateNonnegative(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value) or value < -1e-14) return error.InvalidTransportCheckpointInventory;
}
fn bounded(reader: *std.Io.Reader, limit: usize, comptime too_large: anyerror) !usize {
    const value = try reader.takeInt(u64, .little);
    if (value > limit or value > std.math.maxInt(usize)) return too_large;
    return @intCast(value);
}
fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteTransportCheckpoint;
        try writer.writeInt(u64, @bitCast(value), .little);
    }
}
fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*)) return error.NonFiniteTransportCheckpoint;
    }
}
fn writeBoolSlice(writer: anytype, values: []const bool) !void {
    for (values) |value| try writer.writeByte(@intFromBool(value));
}
fn readBoolSlice(reader: *std.Io.Reader, values: []bool) !void {
    for (values) |*value| value.* = switch (try reader.takeByte()) {
        0 => false,
        1 => true,
        else => return error.InvalidTransportCheckpointBoolean,
    };
}

fn applyTestSnowSurfaceStep(state: *Snow, time_step_hours: f64, outputs: *[7][2]f64) !void {
    const parameters: SnowSurfaceExchange.Parameters = .{
        .vapor_volume_prefactor_k = 2.173e-3,
        .equilibrium_relative_humidity = 0.61,
        .clausius_clapeyron_temperature_k = 5360,
        .reference_inverse_temperature_per_k = 3.661e-3,
        .liquid_evaporation_latent_heat_megajoules_per_m3 = 2465,
        .snow_sublimation_latent_heat_megajoules_per_m3 = 2834,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        .ice_density_megagrams_per_m3 = 0.917,
        .pure_water_melting_temperature_k = 273.15,
    };
    var equilibrium_latent = [_]f64{ 0, 0 };
    var equilibrium_reference = [_]f64{ 0, 0 };
    try SnowSurfaceExchange.equilibrateSurface(std.testing.allocator, state, parameters, .{
        .donor_availability_fraction = 1,
        .latent_heat_megajoules = &equilibrium_latent,
        .reference_state_heat_megajoules = &equilibrium_reference,
        .cell_area_m2 = &.{ 1, 1 },
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
        .energy_conservation_relative_tolerance = 1e-10,
    });
    try SnowSurfaceExchange.applyAccepted(std.testing.allocator, state, parameters, .{
        .physical_time_step_hours = time_step_hours,
        .donor_availability_fraction = 1,
        .cell_area_m2 = &.{ 1, 1 },
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
        .energy_conservation_relative_tolerance = 1e-10,
        .minimum_temperature_k = 173.15,
        .maximum_temperature_k = 373.15,
        .vapor_conductance_m3_per_h = &.{ 1, 0.75 },
        .sensible_conductance_megajoules_per_h_k = &.{ 0.001, 0.002 },
        .accepted_ground_air_vapor_fraction = &.{ 0, 0 },
        .accepted_ground_air_temperature_k = &.{ 275, 276 },
        .radiative_heat_megajoules_per_h = &.{ 0.01, 0.02 },
        .evaporation_m3 = &outputs[0],
        .condensation_m3 = &outputs[1],
        .boundary_heat_megajoules = &outputs[2],
        .latent_heat_megajoules = &outputs[3],
        .carrier_sensible_heat_megajoules = &outputs[4],
        .air_sensible_heat_megajoules = &outputs[5],
        .radiative_heat_megajoules = &outputs[6],
    });
}

test "transport checkpoint round trips runtime snow and resumes exchange identically" {
    var micro = try Solute.init(std.testing.allocator, 6, AqueousSpecies.count);
    defer micro.deinit();
    var macro = try Solute.init(std.testing.allocator, 6, AqueousSpecies.count);
    defer macro.deinit();
    var mineral_nitrogen = try MineralNitrogen.init(std.testing.allocator, 6);
    defer mineral_nitrogen.deinit();
    var organic_transport = try OrganicTransport.init(std.testing.allocator, 6);
    defer organic_transport.deinit();
    var gas = try Gas.init(std.testing.allocator, 6);
    defer gas.deinit();
    var litter_gas = try Gas.init(std.testing.allocator, 2);
    defer litter_gas.deinit();
    var snow = try Snow.init(std.testing.allocator, 2, 4);
    defer snow.deinit();
    try snow.initializePhysicalState(&.{ 0.08, 0.11 }, &.{ 1, 1.5 }, &.{ 268, 269 }, &.{ 0.02, 0.04, 0.08, 0.16 }, 0.1, .{ .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .pure_water_melting_temperature_k = 273.15 });
    const initial_snow_concentrations: SnowModule.InitialChemicalConcentrations = .{
        .primary_g_per_m3 = [_]f64{0.25} ** SnowModule.primary_species_count,
        .static_ion_g_per_m3 = [_]f64{0.5} ** SnowModule.static_ion_species_count,
        .salt_mol_per_m3 = [_]f64{0.01} ** SnowModule.salt_species_count,
    };
    try SnowModule.initializeChemicalState(
        &snow,
        &.{ initial_snow_concentrations, initial_snow_concentrations },
        &.{ false, true },
        0.917,
        SnowModule.activation_heat_capacity_megajoules_per_m2_k,
    );
    try std.testing.expect(snow.amount_g[0] > 0);
    try std.testing.expect(snow.salt_amount_mol[4 * SnowModule.salt_species_count] > 0);
    var first_half_outputs = [_][2]f64{.{ 0, 0 }} ** 7;
    try applyTestSnowSurfaceStep(&snow, 0.5, &first_half_outputs);
    try std.testing.expect(first_half_outputs[0][0] > 0);
    try std.testing.expect(first_half_outputs[3][0] < 0);
    var surface = try Surface.init(std.testing.allocator, 2, 1, AqueousSpecies.count);
    defer surface.deinit();
    micro.water_volume_m3[5] = 2;
    const appended_species = [_]AqueousSpecies{
        .non_band_hpo4,
        .non_band_h2po4,
        .band_hpo4,
        .band_h2po4,
    };
    for (appended_species, 0..) |species, offset| {
        const index = 5 * AqueousSpecies.count + @intFromEnum(species);
        micro.amount_mol[index] = 3 + @as(f64, @floatFromInt(offset));
        macro.amount_mol[index] = 7 + @as(f64, @floatFromInt(offset));
        surface.amount_mol[AqueousSpecies.count + @intFromEnum(species)] =
            11 + @as(f64, @floatFromInt(offset));
    }
    mineral_nitrogen.matrix.water_volume_m3[5] = 0.25;
    mineral_nitrogen.macropore.amount_mol[mineral_nitrogen.macropore.amount_mol.len - 1] = 4.5;
    mineral_nitrogen.boundary_export_g_n_per_step[5] = 0.125;
    organic_transport.macropore_amount_g[organic_transport.macropore_amount_g.len - 1] = 4.75;
    organic_transport.boundary_net_flux_g[organic_transport.boundary_net_flux_g.len - 1] = -0.375;
    gas.temperature_k[5] = 280;
    gas.gaseous_mass_g[gas.gaseous_mass_g.len - 1] = 5;
    gas.macropore_dissolved_mass_g[gas.macropore_dissolved_mass_g.len - 1] = 5.25;
    const transient_ammonia = @intFromEnum(GasModule.Species.ammonia);
    gas.dissolved_mass_g[transient_ammonia] = 91;
    gas.band_dissolved_mass_g[transient_ammonia] = 92;
    gas.macropore_dissolved_mass_g[transient_ammonia] = 93;
    litter_gas.gaseous_mass_g[transient_ammonia] = 94;
    litter_gas.dissolved_mass_g[transient_ammonia] = 95;
    litter_gas.band_dissolved_mass_g[transient_ammonia] = 96;
    litter_gas.macropore_dissolved_mass_g[transient_ammonia] = 97;
    litter_gas.dissolved_mass_g[litter_gas.dissolved_mass_g.len - 1] = 5.5;
    snow.active[7] = true;
    snow.liquid_water_volume_m3[7] = 0.1;
    snow.solid_snow_water_equivalent_m3[7] = 0.2;
    snow.temperature_k[7] = 268;
    snow.amount_g[snow.amount_g.len - 1] = 6;
    snow.dynamic_salts_by_cell[1] = true;
    snow.salt_amount_mol[snow.salt_amount_mol.len - 1] = 6.5;
    snow.salt_amount_mol[7 * SnowModule.salt_species_count + @intFromEnum(SnowModule.SaltSpecies.phosphate)] = 6.75;
    snow.salt_amount_mol[7 * SnowModule.salt_species_count + @intFromEnum(SnowModule.SaltSpecies.phosphoric_acid)] = 6.875;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    surface.amount_mol[34] = 7.25;
    surface.amount_mol[35] = 7.5;
    try write(&bytes.writer, .{ .micropore = &micro, .macropore = &macro, .mineral_nitrogen = &mineral_nitrogen, .organic = &organic_transport, .gas = &gas, .litter_gas = &litter_gas, .snow = &snow, .surface = &surface });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_transport_cells = 20, .maximum_solute_species = 100, .maximum_snow_cells = 10, .maximum_snow_layers = 20 });
    defer restored.deinit();
    try std.testing.expectEqualSlices(f64, micro.amount_mol, restored.micropore.amount_mol);
    try std.testing.expectEqualSlices(f64, macro.amount_mol, restored.macropore.amount_mol);
    try std.testing.expectEqualSlices(f64, mineral_nitrogen.matrix.water_volume_m3, restored.mineral_nitrogen.matrix.water_volume_m3);
    try std.testing.expectEqualSlices(f64, mineral_nitrogen.macropore.amount_mol, restored.mineral_nitrogen.macropore.amount_mol);
    try std.testing.expectEqualSlices(f64, mineral_nitrogen.boundary_export_g_n_per_step, restored.mineral_nitrogen.boundary_export_g_n_per_step);
    try std.testing.expectEqualSlices(f64, organic_transport.micropore_amount_g, restored.organic.micropore_amount_g);
    try std.testing.expectEqualSlices(f64, organic_transport.macropore_amount_g, restored.organic.macropore_amount_g);
    try std.testing.expectEqualSlices(f64, organic_transport.boundary_net_flux_g, restored.organic.boundary_net_flux_g);
    try std.testing.expectEqualSlices(f64, gas.gaseous_mass_g, restored.gas.gaseous_mass_g);
    try std.testing.expectEqual(@as(f64, 0), restored.gas.dissolved_mass_g[transient_ammonia]);
    try std.testing.expectEqual(@as(f64, 0), restored.gas.band_dissolved_mass_g[transient_ammonia]);
    try std.testing.expectEqual(@as(f64, 0), restored.gas.macropore_dissolved_mass_g[transient_ammonia]);
    try std.testing.expectEqual(@as(f64, 5.25), restored.gas.macropore_dissolved_mass_g[restored.gas.macropore_dissolved_mass_g.len - 1]);
    try std.testing.expectEqual(@as(f64, 94), restored.litter_gas.gaseous_mass_g[transient_ammonia]);
    try std.testing.expectEqual(@as(f64, 0), restored.litter_gas.dissolved_mass_g[transient_ammonia]);
    try std.testing.expectEqual(@as(f64, 0), restored.litter_gas.band_dissolved_mass_g[transient_ammonia]);
    try std.testing.expectEqual(@as(f64, 0), restored.litter_gas.macropore_dissolved_mass_g[transient_ammonia]);
    try std.testing.expectEqual(@as(f64, 5.5), restored.litter_gas.dissolved_mass_g[restored.litter_gas.dissolved_mass_g.len - 1]);
    try std.testing.expectEqualSlices(bool, snow.active, restored.snow.active);
    try std.testing.expectEqualSlices(f64, snow.solid_snow_water_equivalent_m3, restored.snow.solid_snow_water_equivalent_m3);
    try std.testing.expectEqualSlices(f64, snow.temperature_k, restored.snow.temperature_k);
    try std.testing.expectEqualSlices(f64, snow.amount_g, restored.snow.amount_g);
    try std.testing.expectEqualSlices(bool, snow.dynamic_salts_by_cell, restored.snow.dynamic_salts_by_cell);
    try std.testing.expectEqualSlices(f64, snow.salt_amount_mol, restored.snow.salt_amount_mol);
    try std.testing.expectEqualSlices(f64, surface.amount_mol, restored.surface.amount_mol);
    try std.testing.expectEqual(@as(f64, 6.75), restored.snow.salt_amount_mol[7 * SnowModule.salt_species_count + @intFromEnum(SnowModule.SaltSpecies.phosphate)]);
    try std.testing.expectEqual(@as(f64, 6.875), restored.snow.salt_amount_mol[7 * SnowModule.salt_species_count + @intFromEnum(SnowModule.SaltSpecies.phosphoric_acid)]);
    try std.testing.expectEqual(@as(f64, 7.25), restored.surface.amount_mol[34]);
    try std.testing.expectEqual(@as(f64, 7.5), restored.surface.amount_mol[35]);
    for (appended_species, 0..) |species, offset| {
        const layer_index = 5 * AqueousSpecies.count + @intFromEnum(species);
        const surface_index = AqueousSpecies.count + @intFromEnum(species);
        try std.testing.expectEqual(3 + @as(f64, @floatFromInt(offset)), restored.micropore.amount_mol[layer_index]);
        try std.testing.expectEqual(7 + @as(f64, @floatFromInt(offset)), restored.macropore.amount_mol[layer_index]);
        try std.testing.expectEqual(11 + @as(f64, @floatFromInt(offset)), restored.surface.amount_mol[surface_index]);
    }

    var uninterrupted_outputs = [_][2]f64{.{ 0, 0 }} ** 7;
    var restarted_outputs = [_][2]f64{.{ 0, 0 }} ** 7;
    try applyTestSnowSurfaceStep(&snow, 0.5, &uninterrupted_outputs);
    try applyTestSnowSurfaceStep(&restored.snow, 0.5, &restarted_outputs);
    try std.testing.expectEqualSlices(bool, snow.active, restored.snow.active);
    inline for (.{
        snow.solid_snow_water_equivalent_m3,
        snow.liquid_water_volume_m3,
        snow.vapor_water_equivalent_m3,
        snow.ice_volume_m3,
        snow.air_filled_volume_m3,
        snow.total_layer_volume_m3,
        snow.layer_thickness_m,
        snow.cumulative_depth_m,
        snow.snow_density_megagrams_per_m3,
        snow.temperature_k,
        snow.heat_capacity_megajoules_per_k,
    }, .{
        restored.snow.solid_snow_water_equivalent_m3,
        restored.snow.liquid_water_volume_m3,
        restored.snow.vapor_water_equivalent_m3,
        restored.snow.ice_volume_m3,
        restored.snow.air_filled_volume_m3,
        restored.snow.total_layer_volume_m3,
        restored.snow.layer_thickness_m,
        restored.snow.cumulative_depth_m,
        restored.snow.snow_density_megagrams_per_m3,
        restored.snow.temperature_k,
        restored.snow.heat_capacity_megajoules_per_k,
    }) |uninterrupted, restarted| try std.testing.expectEqualSlices(f64, uninterrupted, restarted);
    for (uninterrupted_outputs, restarted_outputs) |uninterrupted, restarted|
        try std.testing.expectEqualSlices(f64, &uninterrupted, &restarted);
}

test "transport checkpoint enforces snow layer limit before allocation" {
    var micro = try Solute.init(std.testing.allocator, 1, AqueousSpecies.count);
    defer micro.deinit();
    var macro = try Solute.init(std.testing.allocator, 1, AqueousSpecies.count);
    defer macro.deinit();
    var mineral_nitrogen = try MineralNitrogen.init(std.testing.allocator, 1);
    defer mineral_nitrogen.deinit();
    var organic_transport = try OrganicTransport.init(std.testing.allocator, 1);
    defer organic_transport.deinit();
    var gas = try Gas.init(std.testing.allocator, 1);
    defer gas.deinit();
    var litter_gas = try Gas.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    var snow = try Snow.init(std.testing.allocator, 1, 4);
    defer snow.deinit();
    var surface = try Surface.init(std.testing.allocator, 1, 1, AqueousSpecies.count);
    defer surface.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .micropore = &micro, .macropore = &macro, .mineral_nitrogen = &mineral_nitrogen, .organic = &organic_transport, .gas = &gas, .litter_gas = &litter_gas, .snow = &snow, .surface = &surface });
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.TransportCheckpointSnowLayerLimitExceeded, read(std.testing.allocator, &reader, .{ .maximum_transport_cells = 1, .maximum_solute_species = AqueousSpecies.count, .maximum_snow_cells = 1, .maximum_snow_layers = 3 }));
}

test "transport checkpoint rejects trailing corruption" {
    var micro = try Solute.init(std.testing.allocator, 1, AqueousSpecies.count);
    defer micro.deinit();
    var macro = try Solute.init(std.testing.allocator, 1, AqueousSpecies.count);
    defer macro.deinit();
    var mineral_nitrogen = try MineralNitrogen.init(std.testing.allocator, 1);
    defer mineral_nitrogen.deinit();
    var organic_transport = try OrganicTransport.init(std.testing.allocator, 1);
    defer organic_transport.deinit();
    var gas = try Gas.init(std.testing.allocator, 1);
    defer gas.deinit();
    var litter_gas = try Gas.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    var snow = try Snow.init(std.testing.allocator, 1, 1);
    defer snow.deinit();
    var surface = try Surface.init(std.testing.allocator, 1, 1, AqueousSpecies.count);
    defer surface.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .micropore = &micro, .macropore = &macro, .mineral_nitrogen = &mineral_nitrogen, .organic = &organic_transport, .gas = &gas, .litter_gas = &litter_gas, .snow = &snow, .surface = &surface });
    try bytes.writer.writeByte(0xff);
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.TrailingTransportCheckpointData, read(std.testing.allocator, &reader, .{ .maximum_transport_cells = 1, .maximum_solute_species = AqueousSpecies.count, .maximum_snow_cells = 1, .maximum_snow_layers = 1 }));
}

test "transport checkpoint rejects legacy v11 and short v12 species layouts before payload" {
    var legacy: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer legacy.deinit();
    try legacy.writer.writeAll(magic);
    try legacy.writer.writeInt(u32, 11, .little);
    // The stale header documents the rejected v11 50-coordinate layout. No
    // payload is needed because version ownership is decided first.
    inline for (.{ 1, 50, 1, 1, 1, 1, 50 }) |value|
        try legacy.writer.writeInt(u64, value, .little);
    var legacy_reader: std.Io.Reader = .fixed(legacy.written());
    try std.testing.expectError(
        error.UnsupportedTransportCheckpointVersion,
        read(std.testing.allocator, &legacy_reader, .{
            .maximum_transport_cells = 1,
            .maximum_solute_species = AqueousSpecies.count,
            .maximum_snow_cells = 1,
            .maximum_snow_layers = 1,
        }),
    );

    var short: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer short.deinit();
    try short.writer.writeAll(magic);
    try short.writer.writeInt(u32, version, .little);
    inline for (.{ 1, 50, 1, 1, 1, 1, 50 }) |value|
        try short.writer.writeInt(u64, value, .little);
    var short_reader: std.Io.Reader = .fixed(short.written());
    try std.testing.expectError(
        error.InvalidTransportCheckpointSpeciesCount,
        read(std.testing.allocator, &short_reader, .{
            .maximum_transport_cells = 1,
            .maximum_solute_species = AqueousSpecies.count,
            .maximum_snow_cells = 1,
            .maximum_snow_layers = 1,
        }),
    );
}

test "species mismatch rejects checkpoint publication without bytes or state mutation" {
    var micro = try Solute.init(std.testing.allocator, 1, AqueousSpecies.count);
    defer micro.deinit();
    var macro = try Solute.init(std.testing.allocator, 1, AqueousSpecies.count);
    defer macro.deinit();
    var mineral_nitrogen = try MineralNitrogen.init(std.testing.allocator, 1);
    defer mineral_nitrogen.deinit();
    var organic_transport = try OrganicTransport.init(std.testing.allocator, 1);
    defer organic_transport.deinit();
    var gas = try Gas.init(std.testing.allocator, 1);
    defer gas.deinit();
    var litter_gas = try Gas.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    var snow = try Snow.init(std.testing.allocator, 1, 1);
    defer snow.deinit();
    var short_surface = try Surface.init(std.testing.allocator, 1, 1, 50);
    defer short_surface.deinit();
    micro.amount_mol[0] = 17;
    short_surface.amount_mol[0] = 23;

    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try std.testing.expectError(
        error.InvalidTransportCheckpointSpeciesCount,
        write(&bytes.writer, .{
            .micropore = &micro,
            .macropore = &macro,
            .mineral_nitrogen = &mineral_nitrogen,
            .organic = &organic_transport,
            .gas = &gas,
            .litter_gas = &litter_gas,
            .snow = &snow,
            .surface = &short_surface,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), bytes.written().len);
    try std.testing.expectEqual(@as(f64, 17), micro.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 23), short_surface.amount_mol[0]);
}

const std = @import("std");
const Microbial = @import("../../soil/microbial/state.zig").State;
const Chemistry = @import("../../soil/solute/chemistry_state.zig").State;
const AvailableNutrients = @import("../../soil/nutrients/plant_available_nutrients.zig").State;
const ElementalPool = @import("../../soil/microbial/metabolism.zig").ElementalPool;
const Fertilizer = @import("../../management/fertilizer_nitrogen_inventory.zig").State;
const MineralFertilizer = @import("../../management/mineral_fertilizer_inventory.zig").State;
const ReactiveNitrogen = @import("../../soil/nutrients/reactive_nitrogen_state.zig").State;
const MicrobialPhosphorus = @import("../../soil/microbial/phosphorus_state.zig").State;
const NutrientCompetition = @import("../../soil/nutrients/competition_history.zig");
const FertilizerBand = @import("../../management/fertilizer_band_state.zig").State;
const MicrobialThermalAdaptation = @import("../../soil/biogeochemistry/microbial_thermal_adaptation_initialization.zig").State;
const fertilizer_band_checkpoint = @import("../../management/fertilizer_band_state.zig");
const magic = "ECOSBIOG";
const version: u32 = 12;
pub const View = struct { microbial: *const Microbial, microbial_thermal_adaptation: *const MicrobialThermalAdaptation, chemistry: *const Chemistry, available_nutrients: *const AvailableNutrients, fertilizer: *const Fertilizer, mineral_fertilizer: *const MineralFertilizer, fertilizer_band: *const FertilizerBand, reactive_nitrogen: *const ReactiveNitrogen, microbial_phosphorus: *const MicrobialPhosphorus, nutrient_competition: *const NutrientCompetition.State };
pub const Limits = struct { maximum_cells: usize, maximum_layers: usize, maximum_substrates: usize, maximum_populations: usize };
pub const Owned = struct {
    microbial: Microbial,
    microbial_thermal_adaptation: MicrobialThermalAdaptation,
    chemistry: Chemistry,
    available_nutrients: AvailableNutrients,
    fertilizer: Fertilizer,
    mineral_fertilizer: MineralFertilizer,
    fertilizer_band: FertilizerBand,
    reactive_nitrogen: ReactiveNitrogen,
    microbial_phosphorus: MicrobialPhosphorus,
    nutrient_competition: NutrientCompetition.State,
    pub fn deinit(self: *Owned) void {
        self.nutrient_competition.deinit();
        self.microbial_phosphorus.deinit();
        self.reactive_nitrogen.deinit();
        self.mineral_fertilizer.deinit();
        self.fertilizer_band.deinit();
        self.fertilizer.deinit();
        self.available_nutrients.deinit();
        self.chemistry.deinit();
        self.microbial_thermal_adaptation.deinit();
        self.microbial.deinit();
        self.* = undefined;
    }
};

pub fn write(writer: anytype, view: View) !void {
    try validate(view);
    try writer.writeAll(magic);
    try writer.writeInt(u32, version, .little);
    inline for (.{ view.microbial.cell_count, view.microbial.layer_count, view.microbial.substrate_count, view.microbial.population_count }) |value| try writer.writeInt(u64, @intCast(value), .little);
    try writeF64Slice(writer, view.microbial_thermal_adaptation.thermal_adaptation_offset_k);
    for (view.microbial.nonstructural) |pool| try writePool(writer, pool);
    for (view.microbial.structural) |pool| try writePool(writer, pool);
    const component_count = Chemistry.packedComponentCount();
    try writer.writeInt(u64, @intCast(component_count), .little);
    const buffer = try view.chemistry.allocator.alloc(f64, component_count);
    defer view.chemistry.allocator.free(buffer);
    for (0..view.chemistry.cell_count) |cell| {
        try view.chemistry.packCell(cell, buffer);
        try writeF64Slice(writer, buffer);
    }
    try writeF64Slice(writer, view.chemistry.water_equilibrium_balance_mol);
    try writeF64Slice(writer, view.chemistry.dry_reference_water_m3);
    for (view.chemistry.pending_cation_exchange_mol) |value| try writeStructF64(writer, value);
    try writeF64Slice(writer, view.chemistry.pending_carboxyl_bound_hydrogen_mol);
    for (view.chemistry.pending_non_band_phosphate_mol) |value| try writeStructF64(writer, value);
    for (view.chemistry.pending_band_phosphate_mol) |value| try writeStructF64(writer, value);
    for (view.chemistry.pending_geochemistry_solids_mol) |value| try writeStructF64(writer, value);
    inline for (@typeInfo(AvailableNutrients).@"struct".fields) |field| if (field.type == []f64) try writeF64Slice(writer, @field(view.available_nutrients, field.name));
    for (view.fertilizer.soil) |inventory| inline for (@typeInfo(@TypeOf(inventory)).@"struct".fields) |field| try writer.writeInt(u64, @bitCast(@field(inventory, field.name)), .little);
    try writeF64Slice(writer, view.fertilizer.initial_urease_inhibition_fraction);
    try writeF64Slice(writer, view.fertilizer.current_urease_inhibition_fraction);
    try writer.writeAll(view.fertilizer.formulation);
    for (view.mineral_fertilizer.soil) |inventory| try writeStructF64(writer, inventory);
    for (view.mineral_fertilizer.surface) |inventory| try writeStructF64(writer, inventory);
    try writeF64Slice(writer, view.mineral_fertilizer.daily_phosphorus_input_g_p);
    try fertilizer_band_checkpoint.writeCheckpoint(writer, view.fertilizer_band);
    inline for (@typeInfo(ReactiveNitrogen).@"struct".fields) |field| if (field.type == []f64) try writeF64Slice(writer, @field(view.reactive_nitrogen, field.name));
    inline for (@typeInfo(MicrobialPhosphorus).@"struct".fields) |field| if (field.type == []f64) try writeF64Slice(writer, @field(view.microbial_phosphorus, field.name));
    for (view.nutrient_competition.soil_previous_total) |values| try writeF64Slice(writer, values);
    for (view.nutrient_competition.surface_previous_total) |values| try writeF64Slice(writer, values);
    for (view.nutrient_competition.surface_mineral_previous_capacity) |values| try writeF64Slice(writer, values);
    for (view.nutrient_competition.topsoil_residual_previous_capacity) |values| try writeF64Slice(writer, values);
    try writeF64Slice(writer, view.nutrient_competition.surface_ammonia_oxidation_previous_capacity);
    try writeF64Slice(writer, view.nutrient_competition.surface_denitrification_previous_capacity);
}

pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) !Owned {
    if (limits.maximum_cells == 0 or limits.maximum_layers == 0 or limits.maximum_substrates == 0 or limits.maximum_populations == 0) return error.InvalidSoilBiogeochemistryCheckpointLimits;
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic)) return error.InvalidSoilBiogeochemistryCheckpointMagic;
    if (try reader.takeInt(u32, .little) != version) return error.UnsupportedSoilBiogeochemistryCheckpointVersion;
    const cells = try bounded(reader, limits.maximum_cells, error.SoilBiogeochemistryCheckpointCellLimitExceeded);
    const layers = try bounded(reader, limits.maximum_layers, error.SoilBiogeochemistryCheckpointLayerLimitExceeded);
    const substrates = try bounded(reader, limits.maximum_substrates, error.SoilBiogeochemistryCheckpointSubstrateLimitExceeded);
    const populations = try bounded(reader, limits.maximum_populations, error.SoilBiogeochemistryCheckpointPopulationLimitExceeded);
    if (cells == 0 or layers == 0 or substrates == 0 or populations == 0) return error.InvalidSoilBiogeochemistryCheckpointDimensions;
    const thermal_offsets = try allocator.alloc(f64, cells);
    defer allocator.free(thermal_offsets);
    try readF64Slice(reader, thermal_offsets);
    var microbial_thermal_adaptation = try MicrobialThermalAdaptation.initFromOffsets(allocator, thermal_offsets);
    errdefer microbial_thermal_adaptation.deinit();
    var microbial = try Microbial.init(allocator, cells, layers, substrates, populations);
    errdefer microbial.deinit();
    for (microbial.nonstructural) |*pool| pool.* = try readPool(reader);
    for (microbial.structural) |*pool| pool.* = try readPool(reader);
    const component_count = try bounded(reader, Chemistry.packedComponentCount(), error.SoilChemistryCheckpointComponentMismatch);
    if (component_count != Chemistry.packedComponentCount()) return error.SoilChemistryCheckpointComponentMismatch;
    const chemistry_cells = try std.math.mul(usize, cells, layers);
    var chemistry = try Chemistry.init(allocator, chemistry_cells);
    errdefer chemistry.deinit();
    const buffer = try allocator.alloc(f64, component_count);
    defer allocator.free(buffer);
    for (0..chemistry_cells) |cell| {
        try readF64Slice(reader, buffer);
        try chemistry.unpackCell(cell, buffer);
    }
    try readF64Slice(reader, chemistry.water_equilibrium_balance_mol);
    try readF64Slice(reader, chemistry.dry_reference_water_m3);
    for (chemistry.pending_cation_exchange_mol) |*value| try readStructF64(reader, value);
    try readF64Slice(reader, chemistry.pending_carboxyl_bound_hydrogen_mol);
    for (chemistry.pending_non_band_phosphate_mol) |*value| try readStructF64(reader, value);
    for (chemistry.pending_band_phosphate_mol) |*value| try readStructF64(reader, value);
    for (chemistry.pending_geochemistry_solids_mol) |*value| try readStructF64(reader, value);
    var available_nutrients = try AvailableNutrients.init(allocator, chemistry_cells);
    errdefer available_nutrients.deinit();
    inline for (@typeInfo(AvailableNutrients).@"struct".fields) |field| if (field.type == []f64) try readF64Slice(reader, @field(available_nutrients, field.name));
    var fertilizer = try Fertilizer.init(allocator, cells, layers);
    errdefer fertilizer.deinit();
    var mineral_fertilizer = try MineralFertilizer.init(allocator, cells, layers);
    errdefer mineral_fertilizer.deinit();
    const process_units = try std.math.mul(usize, substrates, populations);
    var reactive_nitrogen = try ReactiveNitrogen.init(allocator, chemistry_cells, process_units);
    errdefer reactive_nitrogen.deinit();
    var microbial_phosphorus = try MicrobialPhosphorus.init(allocator, chemistry_cells, process_units);
    errdefer microbial_phosphorus.deinit();
    var nutrient_competition = try NutrientCompetition.State.init(allocator, chemistry_cells, cells);
    errdefer nutrient_competition.deinit();
    for (fertilizer.soil) |*inventory| {
        inline for (@typeInfo(@TypeOf(inventory.*)).@"struct".fields) |field| {
            @field(inventory, field.name) = @bitCast(try reader.takeInt(u64, .little));
        }
    }
    try readF64Slice(reader, fertilizer.initial_urease_inhibition_fraction);
    try readF64Slice(reader, fertilizer.current_urease_inhibition_fraction);
    const formulations = try reader.take(fertilizer.formulation.len);
    @memcpy(fertilizer.formulation, formulations);
    for (mineral_fertilizer.soil) |*inventory| try readStructF64(reader, inventory);
    for (mineral_fertilizer.surface) |*inventory| try readStructF64(reader, inventory);
    try readF64Slice(reader, mineral_fertilizer.daily_phosphorus_input_g_p);
    var fertilizer_band = try fertilizer_band_checkpoint.readEmbeddedCheckpoint(
        allocator,
        reader,
        .{ .maximum_cells = limits.maximum_cells, .maximum_layers = limits.maximum_layers },
    );
    errdefer fertilizer_band.deinit();
    inline for (@typeInfo(ReactiveNitrogen).@"struct".fields) |field| if (field.type == []f64) try readF64Slice(reader, @field(reactive_nitrogen, field.name));
    inline for (@typeInfo(MicrobialPhosphorus).@"struct".fields) |field| if (field.type == []f64) try readF64Slice(reader, @field(microbial_phosphorus, field.name));
    for (nutrient_competition.soil_previous_total) |values| try readF64Slice(reader, values);
    for (nutrient_competition.surface_previous_total) |values| try readF64Slice(reader, values);
    for (nutrient_competition.surface_mineral_previous_capacity) |values| try readF64Slice(reader, values);
    for (nutrient_competition.topsoil_residual_previous_capacity) |values| try readF64Slice(reader, values);
    try readF64Slice(reader, nutrient_competition.surface_ammonia_oxidation_previous_capacity);
    try readF64Slice(reader, nutrient_competition.surface_denitrification_previous_capacity);
    if (reader.peekByte()) |_| return error.TrailingSoilBiogeochemistryCheckpointData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    const result = Owned{ .microbial = microbial, .microbial_thermal_adaptation = microbial_thermal_adaptation, .chemistry = chemistry, .available_nutrients = available_nutrients, .fertilizer = fertilizer, .mineral_fertilizer = mineral_fertilizer, .fertilizer_band = fertilizer_band, .reactive_nitrogen = reactive_nitrogen, .microbial_phosphorus = microbial_phosphorus, .nutrient_competition = nutrient_competition };
    try validate(.{ .microbial = &result.microbial, .microbial_thermal_adaptation = &result.microbial_thermal_adaptation, .chemistry = &result.chemistry, .available_nutrients = &result.available_nutrients, .fertilizer = &result.fertilizer, .mineral_fertilizer = &result.mineral_fertilizer, .fertilizer_band = &result.fertilizer_band, .reactive_nitrogen = &result.reactive_nitrogen, .microbial_phosphorus = &result.microbial_phosphorus, .nutrient_competition = &result.nutrient_competition });
    return result;
}

fn validate(view: View) !void {
    const process_units = try std.math.mul(usize, view.microbial.substrate_count, view.microbial.population_count);
    if (view.microbial.cell_count == 0 or view.microbial.layer_count == 0 or view.microbial.substrate_count == 0 or view.microbial.population_count == 0 or view.microbial_thermal_adaptation.cell_count != view.microbial.cell_count or view.microbial_thermal_adaptation.thermal_adaptation_offset_k.len != view.microbial.cell_count or view.chemistry.cell_count != try std.math.mul(usize, view.microbial.cell_count, view.microbial.layer_count) or view.available_nutrients.layer_count != view.chemistry.cell_count or view.fertilizer.cell_count != view.microbial.cell_count or view.fertilizer.layer_capacity != view.microbial.layer_count or view.fertilizer.soil.len != view.chemistry.cell_count or view.mineral_fertilizer.cell_count != view.microbial.cell_count or view.mineral_fertilizer.layer_capacity != view.microbial.layer_count or view.mineral_fertilizer.soil.len != view.chemistry.cell_count or view.mineral_fertilizer.surface.len != view.microbial.cell_count or view.fertilizer_band.cell_count != view.microbial.cell_count or view.fertilizer_band.layer_capacity != view.microbial.layer_count or view.reactive_nitrogen.layer_count != view.chemistry.cell_count or view.reactive_nitrogen.process_unit_count_per_layer != process_units or view.microbial_phosphorus.layer_count != view.chemistry.cell_count or view.microbial_phosphorus.process_unit_count_per_layer != process_units or view.nutrient_competition.soil_layer_count != view.chemistry.cell_count or view.nutrient_competition.surface_cell_count != view.microbial.cell_count) return error.InvalidSoilBiogeochemistryCheckpointDimensions;
    for (view.microbial_thermal_adaptation.thermal_adaptation_offset_k) |offset_k| if (!std.math.isFinite(offset_k)) return error.NonFiniteSoilBiogeochemistryCheckpoint;
    for (view.microbial.nonstructural) |pool| try validatePool(pool);
    for (view.microbial.structural) |pool| try validatePool(pool);
    const buffer = try view.chemistry.allocator.alloc(f64, Chemistry.packedComponentCount());
    defer view.chemistry.allocator.free(buffer);
    for (0..view.chemistry.cell_count) |cell| {
        try view.chemistry.packCell(cell, buffer);
        for (buffer) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilBiogeochemistryCheckpoint;
    }
    if (view.chemistry.water_equilibrium_balance_mol.len != view.chemistry.cell_count or
        view.chemistry.dry_reference_water_m3.len != view.chemistry.cell_count or
        view.chemistry.pending_cation_exchange_mol.len != view.chemistry.cell_count or
        view.chemistry.pending_carboxyl_bound_hydrogen_mol.len != view.chemistry.cell_count or
        view.chemistry.pending_non_band_phosphate_mol.len != view.chemistry.cell_count or
        view.chemistry.pending_band_phosphate_mol.len != view.chemistry.cell_count or
        view.chemistry.pending_geochemistry_solids_mol.len != view.chemistry.cell_count)
        return error.InvalidSoilBiogeochemistryCheckpointDimensions;
    for (view.chemistry.water_equilibrium_balance_mol) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSoilBiogeochemistryCheckpoint;
    for (view.chemistry.dry_reference_water_m3) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilBiogeochemistryCheckpointPool;
    for (view.chemistry.pending_cation_exchange_mol) |value| try validateStructF64(value);
    for (view.chemistry.pending_carboxyl_bound_hydrogen_mol) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilBiogeochemistryCheckpointPool;
    for (view.chemistry.pending_non_band_phosphate_mol) |value| try validateStructF64(value);
    for (view.chemistry.pending_band_phosphate_mol) |value| try validateStructF64(value);
    for (view.chemistry.pending_geochemistry_solids_mol) |value| try validateStructF64(value);
    inline for (@typeInfo(AvailableNutrients).@"struct".fields) |field| if (field.type == []f64) {
        for (@field(view.available_nutrients, field.name)) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteSoilBiogeochemistryCheckpoint;
            if (!std.mem.endsWith(u8, field.name, "change_g_c_per_h") and !std.mem.endsWith(u8, field.name, "change_g_n_per_h") and !std.mem.endsWith(u8, field.name, "change_g_p_per_h") and value < -1e-14) return error.InvalidSoilBiogeochemistryCheckpointPool;
        }
    };
    for (view.fertilizer.soil) |inventory| inline for (@typeInfo(@TypeOf(inventory)).@"struct".fields) |field| {
        const value = @field(inventory, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteSoilBiogeochemistryCheckpoint;
        if (value < -1e-14) return error.InvalidSoilBiogeochemistryCheckpointPool;
    };
    for (view.fertilizer.initial_urease_inhibition_fraction, view.fertilizer.current_urease_inhibition_fraction, view.fertilizer.formulation) |initial, current, formulation| {
        _ = formulation;
        if (!std.math.isFinite(initial) or !std.math.isFinite(current) or initial < 0 or initial > 1 or current < 0 or current > 1) return error.InvalidSoilFertilizerCheckpointState;
    }
    for (view.mineral_fertilizer.soil) |inventory| try validateStructF64(inventory);
    for (view.mineral_fertilizer.surface) |inventory| try validateStructF64(inventory);
    for (view.mineral_fertilizer.daily_phosphorus_input_g_p) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilFertilizerCheckpointState;
    for (0..view.chemistry.cell_count) |layer| try view.reactive_nitrogen.validateLayer(layer);
    inline for (@typeInfo(MicrobialPhosphorus).@"struct".fields) |field| if (field.type == []f64) for (@field(view.microbial_phosphorus, field.name)) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilMicrobialPhosphorusCheckpointState;
    try view.nutrient_competition.validate();
}
fn validatePool(pool: ElementalPool) !void {
    inline for (@typeInfo(ElementalPool).@"struct".fields) |field| {
        const value = @field(pool, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteSoilBiogeochemistryCheckpoint;
        if (value < -1e-14) return error.NegativeSoilBiogeochemistryPool;
    }
}
fn writePool(writer: anytype, pool: ElementalPool) !void {
    try validatePool(pool);
    inline for (@typeInfo(ElementalPool).@"struct".fields) |field| try writer.writeInt(u64, @bitCast(@field(pool, field.name)), .little);
}
fn readPool(reader: *std.Io.Reader) !ElementalPool {
    var pool: ElementalPool = undefined;
    inline for (@typeInfo(ElementalPool).@"struct".fields) |field| @field(pool, field.name) = @bitCast(try reader.takeInt(u64, .little));
    try validatePool(pool);
    return pool;
}
fn writeStructF64(writer: anytype, value: anytype) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| try writer.writeInt(u64, @bitCast(@field(value, field.name)), .little);
}
fn readStructF64(reader: *std.Io.Reader, value: anytype) !void {
    inline for (@typeInfo(@TypeOf(value.*)).@"struct".fields) |field| @field(value, field.name) = @bitCast(try reader.takeInt(u64, .little));
}
fn validateStructF64(value: anytype) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| if (!std.math.isFinite(@field(value, field.name)) or @field(value, field.name) < 0) return error.InvalidSoilFertilizerCheckpointState;
}
fn bounded(reader: *std.Io.Reader, limit: usize, comptime too_large: anyerror) !usize {
    const value = try reader.takeInt(u64, .little);
    if (value > limit or value > std.math.maxInt(usize)) return too_large;
    return @intCast(value);
}
fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteSoilBiogeochemistryCheckpoint;
        try writer.writeInt(u64, @bitCast(value), .little);
    }
}
fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*)) return error.NonFiniteSoilBiogeochemistryCheckpoint;
    }
}

fn testFertilizerBand(cells: usize, layers: usize) !FertilizerBand {
    const active = try std.testing.allocator.alloc(usize, cells);
    defer std.testing.allocator.free(active);
    @memset(active, layers);
    const extent = try std.math.mul(usize, cells, layers);
    const upper = try std.testing.allocator.alloc(f64, extent);
    defer std.testing.allocator.free(upper);
    const lower = try std.testing.allocator.alloc(f64, extent);
    defer std.testing.allocator.free(lower);
    const thickness = try std.testing.allocator.alloc(f64, extent);
    defer std.testing.allocator.free(thickness);
    for (0..cells) |cell| for (0..layers) |layer| {
        const index = cell * layers + layer;
        upper[index] = @as(f64, @floatFromInt(layer)) * 0.1;
        lower[index] = upper[index] + 0.1;
        thickness[index] = 0.1;
    };
    return FertilizerBand.initFromPlantNutrientParameters(
        std.testing.allocator,
        cells,
        layers,
        active,
        upper,
        lower,
        thickness,
        .{
            .initial_ammonium_band_fraction = 0.2,
            .initial_nitrate_band_fraction = 0.3,
            .initial_phosphate_band_fraction = 0.4,
            .initial_h2po4_fraction = 0.7,
            .initial_ammonium_band_row_spacing_m = 0.5,
            .initial_nitrate_band_row_spacing_m = 0.6,
            .initial_phosphate_band_row_spacing_m = 0.7,
        },
    );
}

test "soil biogeochemistry checkpoint round trips microbial populations and complete chemistry vectors" {
    var microbial = try Microbial.init(std.testing.allocator, 2, 3, 4, 5);
    defer microbial.deinit();
    var microbial_thermal_adaptation = try MicrobialThermalAdaptation.initFromOffsets(std.testing.allocator, &.{ 3.1968, -0.835 });
    defer microbial_thermal_adaptation.deinit();
    const index = try microbial.populationIndex(1, 2, 3, 4);
    microbial.nonstructural[index] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 };
    microbial.structural[index * 2 + 1] = .{ .carbon_g_c = 20, .nitrogen_g_n = 2, .phosphorus_g_p = 0.4 };
    var chemistry = try Chemistry.init(std.testing.allocator, 6);
    defer chemistry.deinit();
    var available_nutrients = try AvailableNutrients.init(std.testing.allocator, 6);
    defer available_nutrients.deinit();
    var fertilizer = try Fertilizer.init(std.testing.allocator, 2, 3);
    defer fertilizer.deinit();
    var mineral_fertilizer = try MineralFertilizer.init(std.testing.allocator, 2, 3);
    defer mineral_fertilizer.deinit();
    var fertilizer_band = try testFertilizerBand(2, 3);
    defer fertilizer_band.deinit();
    var reactive_nitrogen = try ReactiveNitrogen.init(std.testing.allocator, 6, 20);
    defer reactive_nitrogen.deinit();
    var microbial_phosphorus = try MicrobialPhosphorus.init(std.testing.allocator, 6, 20);
    defer microbial_phosphorus.deinit();
    var nutrient_competition = try NutrientCompetition.State.init(std.testing.allocator, 6, 2);
    defer nutrient_competition.deinit();
    chemistry.water_mol_per_m3[5] = 55.5;
    chemistry.water_equilibrium_balance_mol[5] = -0.0125;
    chemistry.dry_reference_water_m3[5] = 0.042;
    chemistry.carboxyl_bound_hydrogen_mol_per_megagram[5] = 0.75;
    chemistry.pending_cation_exchange_mol[5].calcium = 1.25;
    chemistry.pending_carboxyl_bound_hydrogen_mol[5] = 0.5;
    chemistry.pending_non_band_phosphate_mol[5].adsorbed_hpo4_mol_p_per_megagram = 2.5;
    chemistry.pending_band_phosphate_mol[5].hydroxyapatite_solid_mol_per_m3 = 3.5;
    chemistry.pending_geochemistry_solids_mol[5].calcite_solid_mol_per_m3 = 4.5;
    available_nutrients.mineral_g_element[0] = 8;
    fertilizer.soil[5].banded_urea_mol_n = 9;
    fertilizer.initial_urease_inhibition_fraction[5] = 1;
    fertilizer.current_urease_inhibition_fraction[5] = 0.75;
    fertilizer.formulation[5] = 4;
    mineral_fertilizer.soil[5].banded_monocalcium_phosphate_mol = 7;
    mineral_fertilizer.surface[1].hydroxyapatite_mol = 3;
    mineral_fertilizer.daily_phosphorus_input_g_p[1] = 31;
    reactive_nitrogen.previous_total_non_band_nitrate_demand_g_n[5] = 0.125;
    reactive_nitrogen.previous_band_nitrite_reduction_capacity_g_n[119] = 0.25;
    microbial_phosphorus.previous_total_band_hpo4_demand_g_p[5] = 0.375;
    microbial_phosphorus.previous_non_band_h2po4_capacity_g_p[119] = 0.5;
    nutrient_competition.soil_previous_total[@intFromEnum(NutrientCompetition.SoilPool.ammonium_non_band)][5] = 0.625;
    nutrient_competition.surface_previous_total[@intFromEnum(NutrientCompetition.SurfacePool.nitrate)][1] = 0.6875;
    nutrient_competition.surface_mineral_previous_capacity[@intFromEnum(NutrientCompetition.SurfacePool.h2po4)][NutrientCompetition.surface_mineral_competitor_count + 3] = 0.75;
    nutrient_competition.topsoil_residual_previous_capacity[@intFromEnum(NutrientCompetition.SurfacePool.hpo4)][NutrientCompetition.surface_mineral_competitor_count + 4] = 0.8125;
    nutrient_competition.surface_ammonia_oxidation_previous_capacity[1] = 0.875;
    nutrient_competition.surface_denitrification_previous_capacity[NutrientCompetition.surface_denitrifier_count + 2] = 0.9375;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .microbial = &microbial, .microbial_thermal_adaptation = &microbial_thermal_adaptation, .chemistry = &chemistry, .available_nutrients = &available_nutrients, .fertilizer = &fertilizer, .mineral_fertilizer = &mineral_fertilizer, .fertilizer_band = &fertilizer_band, .reactive_nitrogen = &reactive_nitrogen, .microbial_phosphorus = &microbial_phosphorus, .nutrient_competition = &nutrient_competition });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_cells = 10, .maximum_layers = 20, .maximum_substrates = 20, .maximum_populations = 30 });
    defer restored.deinit();
    try std.testing.expectEqualDeep(microbial.nonstructural[index], restored.microbial.nonstructural[index]);
    try std.testing.expectEqualDeep(microbial.structural[index * 2 + 1], restored.microbial.structural[index * 2 + 1]);
    try std.testing.expectEqualSlices(f64, microbial_thermal_adaptation.thermal_adaptation_offset_k, restored.microbial_thermal_adaptation.thermal_adaptation_offset_k);
    const count = Chemistry.packedComponentCount();
    const a = try std.testing.allocator.alloc(f64, count);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(f64, count);
    defer std.testing.allocator.free(b);
    for (0..6) |cell| {
        try chemistry.packCell(cell, a);
        try restored.chemistry.packCell(cell, b);
        try std.testing.expectEqualSlices(f64, a, b);
    }
    try std.testing.expectEqualSlices(
        f64,
        chemistry.water_equilibrium_balance_mol,
        restored.chemistry.water_equilibrium_balance_mol,
    );
    try std.testing.expectEqualSlices(
        f64,
        chemistry.dry_reference_water_m3,
        restored.chemistry.dry_reference_water_m3,
    );
    try std.testing.expectEqualDeep(chemistry.pending_cation_exchange_mol[5], restored.chemistry.pending_cation_exchange_mol[5]);
    try std.testing.expectEqualSlices(f64, chemistry.pending_carboxyl_bound_hydrogen_mol, restored.chemistry.pending_carboxyl_bound_hydrogen_mol);
    try std.testing.expectEqualDeep(chemistry.pending_non_band_phosphate_mol[5], restored.chemistry.pending_non_band_phosphate_mol[5]);
    try std.testing.expectEqualDeep(chemistry.pending_band_phosphate_mol[5], restored.chemistry.pending_band_phosphate_mol[5]);
    try std.testing.expectEqualDeep(chemistry.pending_geochemistry_solids_mol[5], restored.chemistry.pending_geochemistry_solids_mol[5]);
    try std.testing.expectEqualSlices(f64, available_nutrients.mineral_g_element, restored.available_nutrients.mineral_g_element);
    try std.testing.expectEqualDeep(fertilizer.soil[5], restored.fertilizer.soil[5]);
    try std.testing.expectEqual(@as(f64, 0.75), restored.fertilizer.current_urease_inhibition_fraction[5]);
    try std.testing.expectEqual(@as(u8, 4), restored.fertilizer.formulation[5]);
    try std.testing.expectEqualDeep(mineral_fertilizer.soil[5], restored.mineral_fertilizer.soil[5]);
    try std.testing.expectEqualDeep(mineral_fertilizer.surface[1], restored.mineral_fertilizer.surface[1]);
    try std.testing.expectEqual(@as(f64, 31), restored.mineral_fertilizer.daily_phosphorus_input_g_p[1]);
    try std.testing.expectEqual(@as(f64, 0.125), restored.reactive_nitrogen.previous_total_non_band_nitrate_demand_g_n[5]);
    try std.testing.expectEqual(@as(f64, 0.25), restored.reactive_nitrogen.previous_band_nitrite_reduction_capacity_g_n[119]);
    try std.testing.expectEqual(@as(f64, 0.375), restored.microbial_phosphorus.previous_total_band_hpo4_demand_g_p[5]);
    try std.testing.expectEqual(@as(f64, 0.5), restored.microbial_phosphorus.previous_non_band_h2po4_capacity_g_p[119]);
    try std.testing.expectEqual(@as(f64, 0.625), restored.nutrient_competition.soil_previous_total[@intFromEnum(NutrientCompetition.SoilPool.ammonium_non_band)][5]);
    try std.testing.expectEqual(@as(f64, 0.6875), restored.nutrient_competition.surface_previous_total[@intFromEnum(NutrientCompetition.SurfacePool.nitrate)][1]);
    try std.testing.expectEqual(@as(f64, 0.75), restored.nutrient_competition.surface_mineral_previous_capacity[@intFromEnum(NutrientCompetition.SurfacePool.h2po4)][NutrientCompetition.surface_mineral_competitor_count + 3]);
    try std.testing.expectEqual(@as(f64, 0.8125), restored.nutrient_competition.topsoil_residual_previous_capacity[@intFromEnum(NutrientCompetition.SurfacePool.hpo4)][NutrientCompetition.surface_mineral_competitor_count + 4]);
    try std.testing.expectEqual(@as(f64, 0.875), restored.nutrient_competition.surface_ammonia_oxidation_previous_capacity[1]);
    try std.testing.expectEqual(@as(f64, 0.9375), restored.nutrient_competition.surface_denitrification_previous_capacity[NutrientCompetition.surface_denitrifier_count + 2]);
}

test "soil biogeochemistry checkpoint enforces population limit before allocation" {
    var microbial = try Microbial.init(std.testing.allocator, 1, 1, 1, 5);
    defer microbial.deinit();
    var microbial_thermal_adaptation = try MicrobialThermalAdaptation.initFromOffsets(std.testing.allocator, &.{3.1968});
    defer microbial_thermal_adaptation.deinit();
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var available_nutrients = try AvailableNutrients.init(std.testing.allocator, 1);
    defer available_nutrients.deinit();
    var fertilizer = try Fertilizer.init(std.testing.allocator, 1, 1);
    defer fertilizer.deinit();
    var mineral_fertilizer = try MineralFertilizer.init(std.testing.allocator, 1, 1);
    defer mineral_fertilizer.deinit();
    var fertilizer_band = try testFertilizerBand(1, 1);
    defer fertilizer_band.deinit();
    var reactive_nitrogen = try ReactiveNitrogen.init(std.testing.allocator, 1, 5);
    defer reactive_nitrogen.deinit();
    var microbial_phosphorus = try MicrobialPhosphorus.init(std.testing.allocator, 1, 5);
    defer microbial_phosphorus.deinit();
    var nutrient_competition = try NutrientCompetition.State.init(std.testing.allocator, 1, 1);
    defer nutrient_competition.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .microbial = &microbial, .microbial_thermal_adaptation = &microbial_thermal_adaptation, .chemistry = &chemistry, .available_nutrients = &available_nutrients, .fertilizer = &fertilizer, .mineral_fertilizer = &mineral_fertilizer, .fertilizer_band = &fertilizer_band, .reactive_nitrogen = &reactive_nitrogen, .microbial_phosphorus = &microbial_phosphorus, .nutrient_competition = &nutrient_competition });
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.SoilBiogeochemistryCheckpointPopulationLimitExceeded, read(std.testing.allocator, &reader, .{ .maximum_cells = 1, .maximum_layers = 1, .maximum_substrates = 1, .maximum_populations = 4 }));
}

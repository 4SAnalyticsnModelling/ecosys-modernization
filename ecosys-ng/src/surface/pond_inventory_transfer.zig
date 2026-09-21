const std = @import("std");
const organic_module = @import("../soil/organic/initialization.zig");
const gas_module = @import("../soil/gas/transport.zig");
const surface_fertilizer_module = @import("litter_fertilizer.zig");
const soil_fertilizer_module = @import("../management/fertilizer_nitrogen_inventory.zig");
const mineral_fertilizer_module = @import("../management/mineral_fertilizer_inventory.zig");
const conservation_sidecar = @import("pond_conservation_sidecar.zig");

pub const Owners = struct {
    surface_organic: *organic_module.State,
    soil_organic: *organic_module.State,
    surface_gas: *gas_module.State,
    soil_gas: *gas_module.State,
    surface_nitrogen_fertilizer: *surface_fertilizer_module.State,
    soil_nitrogen_fertilizer: *soil_fertilizer_module.State,
    mineral_fertilizer: *mineral_fertilizer_module.State,
};

pub const Inputs = struct {
    cell: usize,
    destination_soil_layer: usize,
    fraction: f64,
};

/// Exact extensive inventory moved by the REDIST L=0 particulate subset.
/// This is evaluated from the authoritative donor operands before mutation;
/// it deliberately excludes dissolved organic matter, gases, dissolved
/// acetate, and soil-only mineral-fertilizer fields.
pub fn acceptedParticulateTransfer(owners: Owners, inputs: Inputs) !conservation_sidecar.Transfer {
    _ = try validateIndicesAndFraction(owners, inputs);
    try validateParticulateFractionToSoil(owners, inputs);
    var result = try acceptedOrganicTransfer(owners.surface_organic, inputs.cell, inputs.fraction, true);
    result.nitrogen_mol = inputs.fraction * (owners.surface_nitrogen_fertilizer.cells[inputs.cell].ammonium_mol_n +
        owners.surface_nitrogen_fertilizer.cells[inputs.cell].ammonia_mol_n +
        owners.surface_nitrogen_fertilizer.cells[inputs.cell].urea_mol_n +
        owners.surface_nitrogen_fertilizer.cells[inputs.cell].nitrate_mol_n);
    const fertilizer = owners.mineral_fertilizer.surface[inputs.cell];
    try addMineralFertilizer(&result, fertilizer, inputs.fraction, true);
    try result.validate();
    return result;
}

/// Exact extensive inventory moved by a full pond-domain collapse. Gas mass
/// arrays already store grams of their tracked element. Water vapor is omitted
/// here because `pond_water_heat_transfer` publishes its canonical converted
/// water-equivalent and heat exactly once.
pub fn acceptedSurfaceTransfer(owners: Owners, inputs: Inputs) !conservation_sidecar.Transfer {
    _ = try validate(owners, inputs);
    var result = try acceptedOrganicTransfer(owners.surface_organic, inputs.cell, inputs.fraction, false);
    result.nitrogen_mol = inputs.fraction * (owners.surface_nitrogen_fertilizer.cells[inputs.cell].ammonium_mol_n +
        owners.surface_nitrogen_fertilizer.cells[inputs.cell].ammonia_mol_n +
        owners.surface_nitrogen_fertilizer.cells[inputs.cell].urea_mol_n +
        owners.surface_nitrogen_fertilizer.cells[inputs.cell].nitrate_mol_n);
    const base = inputs.cell * gas_module.species_count;
    inline for (@typeInfo(gas_module.Species).@"enum".fields) |field| {
        const species: gas_module.Species = @enumFromInt(field.value);
        // Dissolved NH3 in this gas state is a derived mirror: aqueous NH3 is
        // owned and transferred by litter/soil chemistry.  The canonical gas
        // censuses therefore count gaseous NH3 only.  Other species retain
        // both represented gas-state phases.
        const amount = inputs.fraction * (owners.surface_gas.gaseous_mass_g[base + field.value] +
            if (species == .ammonia) 0 else owners.surface_gas.dissolved_mass_g[base + field.value]);
        switch (species) {
            .carbon_dioxide, .methane => result.carbon_g += amount,
            .oxygen => result.oxygen_g += amount,
            .nitrogen, .nitrous_oxide, .ammonia => result.nitrogen_g += amount,
            .hydrogen => result.hydrogen_g += amount,
        }
    }
    try addMineralFertilizer(&result, owners.mineral_fertilizer.surface[inputs.cell], inputs.fraction, false);
    try result.validate();
    return result;
}

/// Exact particulate inventories moved from one soil-water-column layer.
/// `source_soil_layer` is runtime-logical; the flattened organic/fertilizer
/// owner is derived with the authoritative fertilizer layer capacity.
pub fn acceptedSoilParticulateTransfer(
    owners: Owners,
    cell: usize,
    source_soil_layer: usize,
    fraction: f64,
) !conservation_sidecar.Transfer {
    if (cell >= owners.soil_nitrogen_fertilizer.cell_count or
        source_soil_layer >= owners.soil_nitrogen_fertilizer.layer_capacity or
        !std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
        return error.SurfacePondTransferIndexOutOfBounds;
    const source = cell * owners.soil_nitrogen_fertilizer.layer_capacity + source_soil_layer;
    if (source >= owners.soil_organic.layer_count)
        return error.SurfacePondTransferDimensionMismatch;
    var result = try acceptedOrganicTransfer(owners.soil_organic, source, fraction, true);
    const fertilizer = owners.soil_nitrogen_fertilizer.soil[source];
    result.nitrogen_mol += fraction * (fertilizer.broadcast_ammonium_mol_n +
        fertilizer.broadcast_ammonia_mol_n +
        fertilizer.broadcast_urea_mol_n +
        fertilizer.broadcast_nitrate_mol_n);
    try result.validate();
    return result;
}

fn acceptedOrganicTransfer(
    source: *const organic_module.State,
    layer: usize,
    fraction: f64,
    particulate_only: bool,
) !conservation_sidecar.Transfer {
    var result: conservation_sidecar.Transfer = .{};
    inline for (.{
        .{ "microbial", organic_module.microbial_substrate_count * organic_module.microbial_population_count * organic_module.kinetic_fraction_count },
        .{ "residue", organic_module.substrate_count * organic_module.residue_fraction_count },
        .{ "adsorbed", organic_module.substrate_count },
        .{ "structural", organic_module.substrate_count * organic_module.structural_fraction_count },
    }) |descriptor| {
        const values = @field(source, descriptor[0]);
        for (0..descriptor[1]) |offset| {
            const pool = values[layer * descriptor[1] + offset];
            result.carbon_g += fraction * pool.carbon_g_c;
            result.nitrogen_g += fraction * pool.nitrogen_g_n;
            result.phosphorus_g += fraction * pool.phosphorus_g_p;
        }
    }
    for (0..organic_module.substrate_count) |offset|
        result.carbon_g += fraction * source.adsorbed_acetate_carbon_g_c[layer * organic_module.substrate_count + offset];
    if (!particulate_only) {
        for (0..organic_module.substrate_count) |offset| {
            const pool = source.dissolved[layer * organic_module.substrate_count + offset];
            result.carbon_g += fraction * (pool.carbon_g_c + source.dissolved_acetate_carbon_g_c[layer * organic_module.substrate_count + offset]);
            result.nitrogen_g += fraction * pool.nitrogen_g_n;
            result.phosphorus_g += fraction * pool.phosphorus_g_p;
        }
    }
    try result.validate();
    return result;
}

fn addMineralFertilizer(
    result: *conservation_sidecar.Transfer,
    source: mineral_fertilizer_module.Inventory,
    fraction: f64,
    particulate_only: bool,
) !void {
    inline for (std.meta.fields(mineral_fertilizer_module.Inventory)) |field| {
        const included_in_particulate = comptime std.mem.eql(u8, field.name, "broadcast_monocalcium_phosphate_mol") or
            std.mem.eql(u8, field.name, "hydroxyapatite_mol");
        const moved = fraction * @field(source, field.name) *
            @as(f64, if (particulate_only and !included_in_particulate) 0 else 1);
        if (comptime std.mem.indexOf(u8, field.name, "monocalcium_phosphate") != null) {
            result.phosphorus_mol += 2 * moved;
            result.calcium_mol += moved;
        } else if (comptime std.mem.eql(u8, field.name, "hydroxyapatite_mol")) {
            result.phosphorus_mol += 3 * moved;
            result.calcium_mol += 5 * moved;
        } else if (comptime std.mem.eql(u8, field.name, "calcite_mol")) {
            result.carbon_mol += moved;
            result.calcium_mol += moved;
        } else if (comptime std.mem.eql(u8, field.name, "gypsum_mol")) {
            result.calcium_mol += moved;
            result.sulfur_mol += moved;
        } else if (comptime std.mem.startsWith(u8, field.name, "aluminum_")) {
            result.aluminum_mol += moved;
            result.silicon_mol += 0.75 * moved;
        } else if (comptime std.mem.startsWith(u8, field.name, "iron_")) {
            result.iron_mol += moved;
            result.silicon_mol += 0.75 * moved;
        } else if (comptime std.mem.startsWith(u8, field.name, "calcium_")) {
            result.calcium_mol += moved;
            result.silicon_mol += 0.5 * moved;
        } else if (comptime std.mem.startsWith(u8, field.name, "magnesium_")) {
            result.magnesium_mol += moved;
            result.silicon_mol += 0.5 * moved;
        } else if (comptime std.mem.startsWith(u8, field.name, "sodium_")) {
            result.sodium_mol += moved;
            result.silicon_mol += 0.25 * moved;
        } else if (comptime std.mem.startsWith(u8, field.name, "potassium_")) {
            result.potassium_mol += moved;
            result.silicon_mol += 0.25 * moved;
        }
    }
}

/// Cross-domain portion of REDIST L0=0 pond transfer. All surface owners are
/// validated before any soil or surface inventory changes.
pub fn transferSurfaceFractionToSoil(owners: Owners, inputs: Inputs) !void {
    const destination = try validate(owners, inputs);
    transferOrganic(owners.surface_organic, inputs.cell, owners.soil_organic, destination, inputs.fraction);
    transferGas(owners.surface_gas, inputs.cell, owners.soil_gas, destination, inputs.fraction);
    transferNitrogenFertilizer(owners.surface_nitrogen_fertilizer, inputs.cell, owners.soil_nitrogen_fertilizer, destination, inputs.fraction);
    transferMineralFertilizer(owners.mineral_fertilizer, inputs.cell, destination, inputs.fraction);
}

pub fn validateSurfaceFractionToSoil(owners: Owners, inputs: Inputs) !void {
    _ = try validate(owners, inputs);
}

/// REDIST line-333 settling subset represented by separated runtime owners.
/// Dissolved organic matter and gases are intentionally excluded.
pub fn validateParticulateFractionToSoil(owners: Owners, inputs: Inputs) !void {
    const destination = try validateIndicesAndFraction(owners, inputs);
    try validateParticulateOrganic(owners.surface_organic, inputs.cell, owners.soil_organic, destination, inputs.fraction);
    try validateNitrogenFertilizer(owners.surface_nitrogen_fertilizer.cells[inputs.cell], owners.soil_nitrogen_fertilizer.soil[destination], inputs.fraction);
    try validateParticulateMineralFertilizer(owners.mineral_fertilizer.surface[inputs.cell], owners.mineral_fertilizer.soil[destination], inputs.fraction);
}

pub fn transferParticulateFractionToSoil(owners: Owners, inputs: Inputs) !void {
    try validateParticulateFractionToSoil(owners, inputs);
    const destination = inputs.cell * owners.soil_nitrogen_fertilizer.layer_capacity + inputs.destination_soil_layer;
    transferParticulateOrganic(owners.surface_organic, inputs.cell, owners.soil_organic, destination, inputs.fraction);
    transferNitrogenFertilizer(owners.surface_nitrogen_fertilizer, inputs.cell, owners.soil_nitrogen_fertilizer, destination, inputs.fraction);
    transferParticulateMineralFertilizer(owners.mineral_fertilizer, inputs.cell, destination, inputs.fraction);
}

fn validate(owners: Owners, inputs: Inputs) !usize {
    const destination = try validateIndicesAndFraction(owners, inputs);
    try validateOrganic(owners.surface_organic, inputs.cell, owners.soil_organic, destination, inputs.fraction);
    try validateGas(owners.surface_gas, inputs.cell, owners.soil_gas, destination, inputs.fraction);
    try validateNitrogenFertilizer(owners.surface_nitrogen_fertilizer.cells[inputs.cell], owners.soil_nitrogen_fertilizer.soil[destination], inputs.fraction);
    try validateStructPair(mineral_fertilizer_module.Inventory, owners.mineral_fertilizer.surface[inputs.cell], owners.mineral_fertilizer.soil[destination], inputs.fraction);
    return destination;
}

fn validateIndicesAndFraction(owners: Owners, inputs: Inputs) !usize {
    if (!std.math.isFinite(inputs.fraction) or inputs.fraction < 0 or inputs.fraction > 1) return error.InvalidSurfacePondTransferFraction;
    if (inputs.cell >= owners.surface_organic.layer_count or inputs.cell >= owners.surface_gas.cell_count or inputs.cell >= owners.surface_nitrogen_fertilizer.cells.len or inputs.cell >= owners.mineral_fertilizer.cell_count or inputs.destination_soil_layer >= owners.soil_nitrogen_fertilizer.layer_capacity) return error.SurfacePondTransferIndexOutOfBounds;
    const destination = inputs.cell * owners.soil_nitrogen_fertilizer.layer_capacity + inputs.destination_soil_layer;
    if (destination >= owners.soil_organic.layer_count or destination >= owners.soil_gas.cell_count or destination >= owners.soil_nitrogen_fertilizer.soil.len or destination >= owners.mineral_fertilizer.soil.len) return error.SurfacePondTransferDimensionMismatch;
    return destination;
}

fn validateParticulateOrganic(source: *const organic_module.State, source_layer: usize, destination: *const organic_module.State, destination_layer: usize, fraction: f64) !void {
    inline for (.{
        .{ "microbial", organic_module.microbial_substrate_count * organic_module.microbial_population_count * organic_module.kinetic_fraction_count },
        .{ "residue", organic_module.substrate_count * organic_module.residue_fraction_count },
        .{ "adsorbed", organic_module.substrate_count },
        .{ "structural", organic_module.substrate_count * organic_module.structural_fraction_count },
    }) |descriptor| {
        const source_values = @field(source, descriptor[0]);
        const destination_values = @field(destination, descriptor[0]);
        for (0..descriptor[1]) |offset| try validateStructPair(organic_module.ElementPool, source_values[source_layer * descriptor[1] + offset], destination_values[destination_layer * descriptor[1] + offset], fraction);
    }
    for (0..organic_module.substrate_count) |offset| try validateNumberPair(source.adsorbed_acetate_carbon_g_c[source_layer * organic_module.substrate_count + offset], destination.adsorbed_acetate_carbon_g_c[destination_layer * organic_module.substrate_count + offset], fraction);
    for (0..organic_module.substrate_count * organic_module.structural_fraction_count) |offset| try validateNumberPair(source.colonized_structural_carbon_g_c[source_layer * organic_module.substrate_count * organic_module.structural_fraction_count + offset], destination.colonized_structural_carbon_g_c[destination_layer * organic_module.substrate_count * organic_module.structural_fraction_count + offset], fraction);
}

fn transferParticulateOrganic(source: *organic_module.State, source_layer: usize, destination: *organic_module.State, destination_layer: usize, fraction: f64) void {
    inline for (.{
        .{ "microbial", organic_module.microbial_substrate_count * organic_module.microbial_population_count * organic_module.kinetic_fraction_count },
        .{ "residue", organic_module.substrate_count * organic_module.residue_fraction_count },
        .{ "adsorbed", organic_module.substrate_count },
        .{ "structural", organic_module.substrate_count * organic_module.structural_fraction_count },
    }) |descriptor| {
        const source_values = @field(source, descriptor[0]);
        const destination_values = @field(destination, descriptor[0]);
        for (0..descriptor[1]) |offset| transferStruct(organic_module.ElementPool, &source_values[source_layer * descriptor[1] + offset], &destination_values[destination_layer * descriptor[1] + offset], fraction);
    }
    for (0..organic_module.substrate_count) |offset| transferNumber(&source.adsorbed_acetate_carbon_g_c[source_layer * organic_module.substrate_count + offset], &destination.adsorbed_acetate_carbon_g_c[destination_layer * organic_module.substrate_count + offset], fraction);
    for (0..organic_module.substrate_count * organic_module.structural_fraction_count) |offset| transferNumber(&source.colonized_structural_carbon_g_c[source_layer * organic_module.substrate_count * organic_module.structural_fraction_count + offset], &destination.colonized_structural_carbon_g_c[destination_layer * organic_module.substrate_count * organic_module.structural_fraction_count + offset], fraction);
}

fn validateOrganic(source: *const organic_module.State, source_layer: usize, destination: *const organic_module.State, destination_layer: usize, fraction: f64) !void {
    inline for (.{
        .{ "microbial", organic_module.microbial_substrate_count * organic_module.microbial_population_count * organic_module.kinetic_fraction_count },
        .{ "residue", organic_module.substrate_count * organic_module.residue_fraction_count },
        .{ "dissolved", organic_module.substrate_count },
        .{ "adsorbed", organic_module.substrate_count },
        .{ "structural", organic_module.substrate_count * organic_module.structural_fraction_count },
    }) |descriptor| {
        const name = descriptor[0];
        const stride: usize = descriptor[1];
        const source_values = @field(source, name);
        const destination_values = @field(destination, name);
        for (0..stride) |offset| try validateStructPair(organic_module.ElementPool, source_values[source_layer * stride + offset], destination_values[destination_layer * stride + offset], fraction);
    }
    inline for (.{ "dissolved_acetate_carbon_g_c", "adsorbed_acetate_carbon_g_c" }) |name| {
        const source_values = @field(source, name);
        const destination_values = @field(destination, name);
        for (0..organic_module.substrate_count) |offset| try validateNumberPair(source_values[source_layer * organic_module.substrate_count + offset], destination_values[destination_layer * organic_module.substrate_count + offset], fraction);
    }
    for (0..organic_module.substrate_count * organic_module.structural_fraction_count) |offset| try validateNumberPair(
        source.colonized_structural_carbon_g_c[source_layer * organic_module.substrate_count * organic_module.structural_fraction_count + offset],
        destination.colonized_structural_carbon_g_c[destination_layer * organic_module.substrate_count * organic_module.structural_fraction_count + offset],
        fraction,
    );
}

fn transferOrganic(source: *organic_module.State, source_layer: usize, destination: *organic_module.State, destination_layer: usize, fraction: f64) void {
    inline for (.{
        .{ "microbial", organic_module.microbial_substrate_count * organic_module.microbial_population_count * organic_module.kinetic_fraction_count },
        .{ "residue", organic_module.substrate_count * organic_module.residue_fraction_count },
        .{ "dissolved", organic_module.substrate_count },
        .{ "adsorbed", organic_module.substrate_count },
        .{ "structural", organic_module.substrate_count * organic_module.structural_fraction_count },
    }) |descriptor| {
        const name = descriptor[0];
        const stride: usize = descriptor[1];
        const source_values = @field(source, name);
        const destination_values = @field(destination, name);
        for (0..stride) |offset| transferStruct(organic_module.ElementPool, &source_values[source_layer * stride + offset], &destination_values[destination_layer * stride + offset], fraction);
    }
    inline for (.{ "dissolved_acetate_carbon_g_c", "adsorbed_acetate_carbon_g_c" }) |name| {
        const source_values = @field(source, name);
        const destination_values = @field(destination, name);
        for (0..organic_module.substrate_count) |offset| transferNumber(&source_values[source_layer * organic_module.substrate_count + offset], &destination_values[destination_layer * organic_module.substrate_count + offset], fraction);
    }
    for (0..organic_module.substrate_count * organic_module.structural_fraction_count) |offset| transferNumber(
        &source.colonized_structural_carbon_g_c[source_layer * organic_module.substrate_count * organic_module.structural_fraction_count + offset],
        &destination.colonized_structural_carbon_g_c[destination_layer * organic_module.substrate_count * organic_module.structural_fraction_count + offset],
        fraction,
    );
}

fn validateGas(source: *const gas_module.State, source_cell: usize, destination: *const gas_module.State, destination_cell: usize, fraction: f64) !void {
    try validateNumberPair(source.water_vapor_mol[source_cell], destination.water_vapor_mol[destination_cell], fraction);
    for (0..gas_module.species_count) |species| {
        const source_index = source_cell * gas_module.species_count + species;
        const destination_index = destination_cell * gas_module.species_count + species;
        try validateNumberPair(source.gaseous_mass_g[source_index], destination.gaseous_mass_g[destination_index], fraction);
        try validateNumberPair(source.dissolved_mass_g[source_index], destination.dissolved_mass_g[destination_index], fraction);
    }
}

fn transferGas(source: *gas_module.State, source_cell: usize, destination: *gas_module.State, destination_cell: usize, fraction: f64) void {
    transferNumber(&source.water_vapor_mol[source_cell], &destination.water_vapor_mol[destination_cell], fraction);
    for (0..gas_module.species_count) |species| {
        const source_index = source_cell * gas_module.species_count + species;
        const destination_index = destination_cell * gas_module.species_count + species;
        transferNumber(&source.gaseous_mass_g[source_index], &destination.gaseous_mass_g[destination_index], fraction);
        transferNumber(&source.dissolved_mass_g[source_index], &destination.dissolved_mass_g[destination_index], fraction);
    }
}

fn validateNitrogenFertilizer(source: surface_fertilizer_module.Inventory, destination: @import("../soil/nutrients/fertilizer_dissolution.zig").FertilizerState, fraction: f64) !void {
    inline for (.{
        .{ "ammonium_mol_n", "broadcast_ammonium_mol_n" },
        .{ "ammonia_mol_n", "broadcast_ammonia_mol_n" },
        .{ "urea_mol_n", "broadcast_urea_mol_n" },
        .{ "nitrate_mol_n", "broadcast_nitrate_mol_n" },
    }) |names| try validateNumberPair(@field(source, names[0]), @field(destination, names[1]), fraction);
}

fn transferNitrogenFertilizer(source_state: *surface_fertilizer_module.State, cell: usize, destination_state: *soil_fertilizer_module.State, destination: usize, fraction: f64) void {
    inline for (.{
        .{ "ammonium_mol_n", "broadcast_ammonium_mol_n" },
        .{ "ammonia_mol_n", "broadcast_ammonia_mol_n" },
        .{ "urea_mol_n", "broadcast_urea_mol_n" },
        .{ "nitrate_mol_n", "broadcast_nitrate_mol_n" },
    }) |names| transferNumber(&@field(source_state.cells[cell], names[0]), &@field(destination_state.soil[destination], names[1]), fraction);
}

fn transferMineralFertilizer(state: *mineral_fertilizer_module.State, cell: usize, destination: usize, fraction: f64) void {
    transferStruct(mineral_fertilizer_module.Inventory, &state.surface[cell], &state.soil[destination], fraction);
}

const particulate_surface_mineral_fields = .{
    "broadcast_monocalcium_phosphate_mol",
    "hydroxyapatite_mol",
};

/// The only dry mineral-fertilizer owners that management can place on L=0
/// are broadcast MCP and hydroxyapatite. These are the pending extensive forms
/// of REDIST PCAPM/PCAPH (`redist.f:513--527`). Banded MCP, calcite, gypsum,
/// and ground silicates are soil-only stores and must never follow L0 settling.
fn validateParticulateMineralFertilizer(source: mineral_fertilizer_module.Inventory, destination: mineral_fertilizer_module.Inventory, fraction: f64) !void {
    inline for (particulate_surface_mineral_fields) |field_name|
        try validateNumberPair(@field(source, field_name), @field(destination, field_name), fraction);
}

fn transferParticulateMineralFertilizer(state: *mineral_fertilizer_module.State, cell: usize, destination: usize, fraction: f64) void {
    inline for (particulate_surface_mineral_fields) |field_name|
        transferNumber(&@field(state.surface[cell], field_name), &@field(state.soil[destination], field_name), fraction);
}

fn validateStructPair(comptime T: type, source: T, destination: T, fraction: f64) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| try validateNumberPair(@field(source, field.name), @field(destination, field.name), fraction);
}

fn validateNumberPair(source: f64, destination: f64, fraction: f64) !void {
    if (!std.math.isFinite(source) or source < 0 or !std.math.isFinite(destination) or destination < 0 or !std.math.isFinite(destination + fraction * source)) return error.InvalidSurfacePondInventory;
}

fn transferStruct(comptime T: type, source: *T, destination: *T, fraction: f64) void {
    inline for (@typeInfo(T).@"struct".fields) |field| transferNumber(&@field(source.*, field.name), &@field(destination.*, field.name), fraction);
}

fn transferNumber(source: *f64, destination: *f64, fraction: f64) void {
    const moved = fraction * source.*;
    destination.* += moved;
    source.* -= moved;
}

test "surface pond inventories transfer atomically into selected soil layer" {
    var surface_organic = try organic_module.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic = try organic_module.State.init(std.testing.allocator, 2);
    defer soil_organic.deinit();
    var surface_gas = try gas_module.State.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var soil_gas = try gas_module.State.init(std.testing.allocator, 2);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer_module.State.init(std.testing.allocator, 1);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer_module.State.init(std.testing.allocator, 1, 2);
    defer soil_n.deinit();
    var mineral = try mineral_fertilizer_module.State.init(std.testing.allocator, 1, 2);
    defer mineral.deinit();
    surface_organic.microbial[0].carbon_g_c = 8;
    surface_gas.gaseous_mass_g[0] = 6;
    surface_n.cells[0].ammonium_mol_n = 4;
    mineral.surface[0].gypsum_mol = 2;
    const owners: Owners = .{ .surface_organic = &surface_organic, .soil_organic = &soil_organic, .surface_gas = &surface_gas, .soil_gas = &soil_gas, .surface_nitrogen_fertilizer = &surface_n, .soil_nitrogen_fertilizer = &soil_n, .mineral_fertilizer = &mineral };
    try transferSurfaceFractionToSoil(owners, .{ .cell = 0, .destination_soil_layer = 1, .fraction = 0.25 });
    try std.testing.expectEqual(@as(f64, 6), surface_organic.microbial[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 2), soil_organic.microbial[organic_module.microbial_substrate_count * organic_module.microbial_population_count * organic_module.kinetic_fraction_count].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1.5), soil_gas.gaseous_mass_g[gas_module.species_count]);
    try std.testing.expectEqual(@as(f64, 1), soil_n.soil[1].broadcast_ammonium_mol_n);
    try std.testing.expectEqual(@as(f64, 0.5), mineral.soil[1].gypsum_mol);
}

test "pond sidecars count canonical gas and chemistry mirrors exactly once" {
    const chemistry_transfer = @import("pond_chemistry_transfer.zig");
    const surface_chemistry_module = @import("litter_chemistry.zig");
    const soil_chemistry_module = @import("../soil/solute/chemistry_state.zig");

    var surface_organic = try organic_module.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic = try organic_module.State.init(std.testing.allocator, 1);
    defer soil_organic.deinit();
    var surface_gas = try gas_module.State.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var soil_gas = try gas_module.State.init(std.testing.allocator, 1);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer_module.State.init(std.testing.allocator, 1);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer_module.State.init(std.testing.allocator, 1, 1);
    defer soil_n.deinit();
    var mineral = try mineral_fertilizer_module.State.init(std.testing.allocator, 1, 1);
    defer mineral.deinit();
    var surface_chemistry = try surface_chemistry_module.State.init(std.testing.allocator, 1);
    defer surface_chemistry.deinit();
    var soil_chemistry = try soil_chemistry_module.State.init(std.testing.allocator, 1);
    defer soil_chemistry.deinit();

    const ammonia = @intFromEnum(gas_module.Species.ammonia);
    const carbon_dioxide = @intFromEnum(gas_module.Species.carbon_dioxide);
    surface_gas.gaseous_mass_g[ammonia] = 7;
    surface_gas.dissolved_mass_g[ammonia] = 11; // non-owning gas mirror
    surface_chemistry.cells[0].ammonia_mol_per_m3 = 13; // canonical aqueous owner
    surface_gas.gaseous_mass_g[carbon_dioxide] = 5;
    surface_gas.dissolved_mass_g[carbon_dioxide] = 11;
    surface_chemistry.cells[0].carbon_dioxide_mol_per_m3 = 13;

    const inventory_accepted = try acceptedSurfaceTransfer(.{
        .surface_organic = &surface_organic,
        .soil_organic = &soil_organic,
        .surface_gas = &surface_gas,
        .soil_gas = &soil_gas,
        .surface_nitrogen_fertilizer = &surface_n,
        .soil_nitrogen_fertilizer = &soil_n,
        .mineral_fertilizer = &mineral,
    }, .{ .cell = 0, .destination_soil_layer = 0, .fraction = 0.25 });
    const chemistry_accepted = try chemistry_transfer.acceptedSurfaceTransfer(
        &surface_chemistry,
        &soil_chemistry,
        0,
        0,
        .{
            .surface_water_before_m3 = 2,
            .soil_shared_water_before_m3 = 2,
            .soil_phosphate_non_band_water_before_m3 = 2,
            .surface_water_after_m3 = 1.5,
            .soil_shared_water_after_m3 = 2.5,
            .soil_phosphate_non_band_water_after_m3 = 2.5,
            .surface_dry_mass_before_megagrams = 1,
            .soil_dry_mass_before_megagrams = 1,
            .surface_dry_mass_after_megagrams = 0.75,
            .soil_dry_mass_after_megagrams = 1.25,
            .dissolved_chemistry_fraction = 0.25,
            .cell_area_m2 = 1,
        },
        false,
        0.25,
    );
    const accepted = try inventory_accepted.add(chemistry_accepted);

    // Gas N is grams of tracked N and contains only the canonical gaseous
    // owner.  Aqueous NH3 is present once, on the chemistry native-mole lane.
    try std.testing.expectEqual(@as(f64, 1.75), accepted.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 6.5), accepted.nitrogen_mol);
    try std.testing.expectEqual(@as(f64, 0), inventory_accepted.nitrogen_mol);
    try std.testing.expectEqual(@as(f64, 0), chemistry_accepted.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 4), inventory_accepted.carbon_g);
    try std.testing.expectEqual(@as(f64, 0), chemistry_accepted.carbon_mol);
    try std.testing.expectEqual(@as(f64, 4), accepted.carbon_g + 12 * accepted.carbon_mol);
}

test "late invalid particulate inventory leaves every surface and soil owner unchanged" {
    var surface_organic = try organic_module.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic = try organic_module.State.init(std.testing.allocator, 1);
    defer soil_organic.deinit();
    var surface_gas = try gas_module.State.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var soil_gas = try gas_module.State.init(std.testing.allocator, 1);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer_module.State.init(std.testing.allocator, 1);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer_module.State.init(std.testing.allocator, 1, 1);
    defer soil_n.deinit();
    var mineral = try mineral_fertilizer_module.State.init(std.testing.allocator, 1, 1);
    defer mineral.deinit();
    surface_organic.microbial[0].carbon_g_c = 8;
    surface_gas.gaseous_mass_g[0] = 6;
    mineral.surface[0].broadcast_monocalcium_phosphate_mol = std.math.nan(f64);
    const owners: Owners = .{ .surface_organic = &surface_organic, .soil_organic = &soil_organic, .surface_gas = &surface_gas, .soil_gas = &soil_gas, .surface_nitrogen_fertilizer = &surface_n, .soil_nitrogen_fertilizer = &soil_n, .mineral_fertilizer = &mineral };
    try std.testing.expectError(error.InvalidSurfacePondInventory, transferParticulateFractionToSoil(owners, .{ .cell = 0, .destination_soil_layer = 0, .fraction = 0.5 }));
    try std.testing.expectEqual(@as(f64, 8), surface_organic.microbial[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), soil_organic.microbial[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 6), surface_gas.gaseous_mass_g[0]);
}

test "REDIST L0 dry mineral settling moves only source-reachable P fields" {
    var surface_organic = try organic_module.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic = try organic_module.State.init(std.testing.allocator, 1);
    defer soil_organic.deinit();
    var surface_gas = try gas_module.State.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var soil_gas = try gas_module.State.init(std.testing.allocator, 1);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer_module.State.init(std.testing.allocator, 1);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer_module.State.init(std.testing.allocator, 1, 1);
    defer soil_n.deinit();
    var mineral = try mineral_fertilizer_module.State.init(std.testing.allocator, 1, 1);
    defer mineral.deinit();
    mineral.surface[0] = .{
        .broadcast_monocalcium_phosphate_mol = 8,
        .banded_monocalcium_phosphate_mol = 12,
        .hydroxyapatite_mol = 16,
        .calcite_mol = 20,
        .gypsum_mol = 24,
        .potassium_ground_silicate_mol = 28,
    };
    const owners: Owners = .{
        .surface_organic = &surface_organic,
        .soil_organic = &soil_organic,
        .surface_gas = &surface_gas,
        .soil_gas = &soil_gas,
        .surface_nitrogen_fertilizer = &surface_n,
        .soil_nitrogen_fertilizer = &soil_n,
        .mineral_fertilizer = &mineral,
    };
    try transferParticulateFractionToSoil(owners, .{ .cell = 0, .destination_soil_layer = 0, .fraction = 0.25 });
    try std.testing.expectEqual(@as(f64, 6), mineral.surface[0].broadcast_monocalcium_phosphate_mol);
    try std.testing.expectEqual(@as(f64, 2), mineral.soil[0].broadcast_monocalcium_phosphate_mol);
    try std.testing.expectEqual(@as(f64, 12), mineral.surface[0].hydroxyapatite_mol);
    try std.testing.expectEqual(@as(f64, 4), mineral.soil[0].hydroxyapatite_mol);
    try std.testing.expectEqual(@as(f64, 12), mineral.surface[0].banded_monocalcium_phosphate_mol);
    try std.testing.expectEqual(@as(f64, 20), mineral.surface[0].calcite_mol);
    try std.testing.expectEqual(@as(f64, 24), mineral.surface[0].gypsum_mol);
    try std.testing.expectEqual(@as(f64, 28), mineral.surface[0].potassium_ground_silicate_mol);
    try std.testing.expectEqual(@as(f64, 0), mineral.soil[0].banded_monocalcium_phosphate_mol);
    try std.testing.expectEqual(@as(f64, 0), mineral.soil[0].calcite_mol);
    try std.testing.expectEqual(@as(f64, 0), mineral.soil[0].gypsum_mol);
    try std.testing.expectEqual(@as(f64, 0), mineral.soil[0].potassium_ground_silicate_mol);
}

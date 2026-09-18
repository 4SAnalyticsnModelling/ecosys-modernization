const std = @import("std");
const organic = @import("../../soil/organic/initialization.zig");
const State = organic.State;
const Pool = organic.ElementPool;
const litter_chemistry = @import("../../surface/litter_chemistry.zig");
const litter_fertilizer = @import("../../surface/litter_fertilizer.zig");
const surface_respiration = @import("../../surface/microbial_respiration_step.zig");
const surface_autotrophic = @import("../../surface/autotrophic_complex_step.zig");
const surface_denitrification = @import("../../surface/denitrification_step.zig");
const fire_exchange = @import("../../soil/biogeochemistry/organic_matter_fire_exchange.zig");
const litter_salt_ingress = @import("../../plant/salt/litter_ingress.zig");
const magic = "ECOSORGN";
// Version 16 persists the dry litter chemistry reference-water carrier.
// Version 17 adds the signed hourly litter TBH2O balance owner.
// Version 18 adds the dedicated surface K=5 autotrophic history/flux state.
// Version 19 adds signed litter/topsoil K=5 mineral-exchange ownership.
// Version 20 persists the independent surface-litter pH state.
const version: u32 = 20;
pub const View = struct { profile: *const State, surface: *const State, litter_chemistry: *const litter_chemistry.State, litter_fertilizer: *const litter_fertilizer.State, surface_respiration: *const surface_respiration.State, surface_autotrophic: *const surface_autotrophic.State, surface_denitrification: *const surface_denitrification.State, surface_fire_exchange: *const fire_exchange.State, litter_salt_ingress: *const litter_salt_ingress.State };
pub const Limits = struct { maximum_profile_layers: usize, maximum_surface_cells: usize };
pub const Owned = struct {
    profile: State,
    surface: State,
    litter_chemistry: litter_chemistry.State,
    litter_fertilizer: litter_fertilizer.State,
    surface_respiration: surface_respiration.State,
    surface_autotrophic: surface_autotrophic.State,
    surface_denitrification: surface_denitrification.State,
    surface_fire_exchange: fire_exchange.State,
    litter_salt_ingress: litter_salt_ingress.State,
    pub fn deinit(self: *Owned) void {
        self.litter_salt_ingress.deinit();
        self.surface_fire_exchange.deinit();
        self.surface_denitrification.deinit();
        self.surface_autotrophic.deinit();
        self.surface_respiration.deinit();
        self.litter_fertilizer.deinit();
        self.litter_chemistry.deinit();
        self.surface.deinit();
        self.profile.deinit();
        self.* = undefined;
    }
};
pub fn write(writer: anytype, view: View) !void {
    try validate(view);
    try writer.writeAll(magic);
    try writer.writeInt(u32, version, .little);
    try writer.writeInt(u64, @intCast(view.profile.layer_count), .little);
    try writer.writeInt(u64, @intCast(view.surface.layer_count), .little);
    try writer.writeInt(u64, @intCast(view.litter_salt_ingress.cell_count), .little);
    try writer.writeInt(u64, @intCast(view.litter_salt_ingress.soil_layer_capacity), .little);
    try writer.writeInt(u16, @intCast(litter_salt_ingress.salt_count), .little);
    inline for (.{ view.profile.*, view.surface.* }) |state| {
        inline for (.{ state.microbial, state.residue, state.dissolved, state.adsorbed, state.structural }) |pools| for (pools) |pool| try writePool(writer, pool);
        try writeF64Slice(writer, state.dissolved_acetate_carbon_g_c);
        try writeF64Slice(writer, state.adsorbed_acetate_carbon_g_c);
        try writeF64Slice(writer, state.colonized_structural_carbon_g_c);
    }
    for (view.litter_chemistry.cells) |cell| try writeNumericStruct(litter_chemistry.Cell, writer, cell);
    try writeF64Slice(writer, view.litter_chemistry.ph);
    try writeF64Slice(writer, view.litter_chemistry.mineral_reference_water_m3);
    try writeF64Slice(writer, view.litter_chemistry.dry_reference_water_m3);
    try writeF64Slice(writer, view.litter_chemistry.water_equilibrium_balance_mol);
    for (view.litter_fertilizer.cells) |cell| try writeNumericStruct(litter_fertilizer.Inventory, writer, cell);
    try writer.writeAll(view.litter_fertilizer.formulation);
    inline for (.{ view.surface_respiration.unlimited_respiration_g_c, view.surface_respiration.substrate_limited_respiration_g_c, view.surface_respiration.potential_oxygen_demand_g_o, view.surface_respiration.previous_oxygen_demand_g_o, view.surface_respiration.previous_doc_respiration_g_c, view.surface_respiration.previous_acetate_respiration_g_c }) |values| try writeF64Slice(writer, values);
    inline for (@typeInfo(surface_autotrophic.State).@"struct".fields) |field| if (field.type == []f64) try writeF64Slice(writer, @field(view.surface_autotrophic, field.name));
    inline for (@typeInfo(surface_denitrification.State).@"struct".fields) |field| if (field.type == []f64) try writeF64Slice(writer, @field(view.surface_denitrification, field.name));
    try writeF64Slice(writer, view.surface_fire_exchange.pending_surface_ammonium_mol_n);
    try writeF64Slice(writer, view.surface_fire_exchange.pending_surface_phosphate_mol_p);
    try writeF64Slice(writer, view.surface_fire_exchange.pending_surface_salt_mol);
    try writeF64Slice(writer, view.litter_salt_ingress.pending_mol);
}
pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) !Owned {
    if (limits.maximum_profile_layers == 0 or limits.maximum_surface_cells == 0) return error.InvalidSoilOrganicCheckpointLimit;
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic)) return error.InvalidSoilOrganicCheckpointMagic;
    if (try reader.takeInt(u32, .little) != version) return error.UnsupportedSoilOrganicCheckpointVersion;
    const profile_count = try bounded(reader, limits.maximum_profile_layers, error.SoilOrganicCheckpointLayerLimitExceeded);
    const surface_count = try bounded(reader, limits.maximum_surface_cells, error.SoilOrganicCheckpointSurfaceLimitExceeded);
    const ingress_cell_count = try bounded(reader, limits.maximum_surface_cells, error.SoilOrganicCheckpointSurfaceLimitExceeded);
    const ingress_layer_capacity = try bounded(reader, limits.maximum_profile_layers, error.SoilOrganicCheckpointLayerLimitExceeded);
    if (try reader.takeInt(u16, .little) != litter_salt_ingress.salt_count)
        return error.UnsupportedPlantLitterSaltSpeciesLayout;
    if (ingress_cell_count != surface_count or
        profile_count % surface_count != 0 or
        ingress_layer_capacity != profile_count / surface_count)
        return error.InvalidPlantLitterSaltCheckpointDimensions;
    var profile = try State.init(allocator, profile_count);
    errdefer profile.deinit();
    var surface = try State.init(allocator, surface_count);
    errdefer surface.deinit();
    var surface_chemistry = try litter_chemistry.State.init(allocator, surface_count);
    errdefer surface_chemistry.deinit();
    var surface_fertilizer = try litter_fertilizer.State.init(allocator, surface_count);
    errdefer surface_fertilizer.deinit();
    var respiration_state = try surface_respiration.State.init(allocator, surface_count);
    errdefer respiration_state.deinit();
    var autotrophic_state = try surface_autotrophic.State.init(allocator, surface_count);
    errdefer autotrophic_state.deinit();
    var denitrification_state = try surface_denitrification.State.init(allocator, surface_count);
    errdefer denitrification_state.deinit();
    var surface_fire_state = try fire_exchange.State.init(allocator, surface_count, organic.microbial_substrate_count);
    errdefer surface_fire_state.deinit();
    var litter_salt_state = try litter_salt_ingress.State.init(allocator, ingress_cell_count, ingress_layer_capacity);
    errdefer litter_salt_state.deinit();
    inline for (.{ &profile, &surface }) |state| {
        try readPoolSlice(reader, state.microbial);
        try readPoolSlice(reader, state.residue);
        try readPoolSlice(reader, state.dissolved);
        try readPoolSlice(reader, state.adsorbed);
        try readPoolSlice(reader, state.structural);
        try readF64Slice(reader, state.dissolved_acetate_carbon_g_c);
        try readF64Slice(reader, state.adsorbed_acetate_carbon_g_c);
        try readF64Slice(reader, state.colonized_structural_carbon_g_c);
    }
    for (surface_chemistry.cells) |*cell| cell.* = try readNumericStruct(litter_chemistry.Cell, reader);
    try readF64Slice(reader, surface_chemistry.ph);
    try readNonnegativeF64Slice(reader, surface_chemistry.mineral_reference_water_m3);
    try readNonnegativeF64Slice(reader, surface_chemistry.dry_reference_water_m3);
    try readF64Slice(reader, surface_chemistry.water_equilibrium_balance_mol);
    for (surface_fertilizer.cells) |*cell| cell.* = try readNumericStruct(litter_fertilizer.Inventory, reader);
    @memcpy(surface_fertilizer.formulation, try reader.take(surface_count));
    inline for (.{ respiration_state.unlimited_respiration_g_c, respiration_state.substrate_limited_respiration_g_c, respiration_state.potential_oxygen_demand_g_o, respiration_state.previous_oxygen_demand_g_o, respiration_state.previous_doc_respiration_g_c, respiration_state.previous_acetate_respiration_g_c }) |values| try readF64Slice(reader, values);
    inline for (@typeInfo(surface_autotrophic.State).@"struct".fields) |field| if (field.type == []f64) try readF64Slice(reader, @field(autotrophic_state, field.name));
    inline for (@typeInfo(surface_denitrification.State).@"struct".fields) |field| if (field.type == []f64) try readF64Slice(reader, @field(denitrification_state, field.name));
    try readF64Slice(reader, surface_fire_state.pending_surface_ammonium_mol_n);
    try readF64Slice(reader, surface_fire_state.pending_surface_phosphate_mol_p);
    try readF64Slice(reader, surface_fire_state.pending_surface_salt_mol);
    try readNonnegativeF64Slice(reader, litter_salt_state.pending_mol);
    if (reader.peekByte()) |_| return error.TrailingSoilOrganicCheckpointData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    const result = Owned{ .profile = profile, .surface = surface, .litter_chemistry = surface_chemistry, .litter_fertilizer = surface_fertilizer, .surface_respiration = respiration_state, .surface_autotrophic = autotrophic_state, .surface_denitrification = denitrification_state, .surface_fire_exchange = surface_fire_state, .litter_salt_ingress = litter_salt_state };
    try validate(.{ .profile = &result.profile, .surface = &result.surface, .litter_chemistry = &result.litter_chemistry, .litter_fertilizer = &result.litter_fertilizer, .surface_respiration = &result.surface_respiration, .surface_autotrophic = &result.surface_autotrophic, .surface_denitrification = &result.surface_denitrification, .surface_fire_exchange = &result.surface_fire_exchange, .litter_salt_ingress = &result.litter_salt_ingress });
    return result;
}
fn validate(view: View) !void {
    if (view.litter_chemistry.cells.len != view.surface.layer_count or view.litter_chemistry.ph.len != view.surface.layer_count or view.litter_chemistry.mineral_reference_water_m3.len != view.surface.layer_count or view.litter_chemistry.dry_reference_water_m3.len != view.surface.layer_count or view.litter_chemistry.water_equilibrium_balance_mol.len != view.surface.layer_count or view.litter_fertilizer.cells.len != view.surface.layer_count or view.litter_fertilizer.formulation.len != view.surface.layer_count or view.surface_respiration.cell_count != view.surface.layer_count or view.surface_autotrophic.cell_count != view.surface.layer_count or view.surface_denitrification.cell_count != view.surface.layer_count or view.surface_fire_exchange.layer_count != view.surface.layer_count or view.surface_fire_exchange.substrate_count != organic.microbial_substrate_count or view.litter_salt_ingress.cell_count != view.surface.layer_count or view.profile.layer_count != view.litter_salt_ingress.cell_count * view.litter_salt_ingress.soil_layer_capacity or view.litter_salt_ingress.pending_mol.len != view.litter_salt_ingress.cell_count * (view.litter_salt_ingress.soil_layer_capacity + 1) * litter_salt_ingress.salt_count) return error.InvalidSoilOrganicCheckpointDimensions;
    inline for (.{ view.profile.*, view.surface.* }) |state| {
        if (state.layer_count == 0) return error.InvalidSoilOrganicCheckpointDimensions;
        inline for (.{ state.microbial, state.residue, state.dissolved, state.adsorbed, state.structural }) |pools| for (pools) |pool| try validatePool(pool);
        inline for (.{ state.dissolved_acetate_carbon_g_c, state.adsorbed_acetate_carbon_g_c }) |values| for (values) |value| if (!std.math.isFinite(value) or value < -1e-14) return error.InvalidSoilOrganicCheckpointPool;
        for (state.colonized_structural_carbon_g_c) |value| if (!std.math.isFinite(value) or value < -1e-14) return error.InvalidSoilOrganicCheckpointPool;
    }
    for (view.litter_chemistry.cells) |cell| try validateNumericStruct(litter_chemistry.Cell, cell);
    for (view.litter_chemistry.ph) |ph|
        if (!std.math.isFinite(ph)) return error.InvalidSoilOrganicCheckpointPool;
    inline for (.{ view.litter_chemistry.mineral_reference_water_m3, view.litter_chemistry.dry_reference_water_m3 }) |carrier|
        for (carrier) |water|
            if (!std.math.isFinite(water) or water < 0)
                return error.InvalidSoilOrganicCheckpointPool;
    for (view.litter_chemistry.water_equilibrium_balance_mol) |value|
        if (!std.math.isFinite(value)) return error.InvalidSoilOrganicCheckpointPool;
    for (view.litter_fertilizer.cells) |cell| try validateNumericStruct(litter_fertilizer.Inventory, cell);
    for (view.litter_fertilizer.formulation) |formulation| if (formulation > 4) return error.InvalidSoilOrganicCheckpointPool;
    inline for (.{ view.surface_respiration.unlimited_respiration_g_c, view.surface_respiration.substrate_limited_respiration_g_c, view.surface_respiration.potential_oxygen_demand_g_o, view.surface_respiration.previous_oxygen_demand_g_o, view.surface_respiration.previous_doc_respiration_g_c, view.surface_respiration.previous_acetate_respiration_g_c }) |values| for (values) |value| if (!std.math.isFinite(value) or value < -1e-14) return error.InvalidSoilOrganicCheckpointPool;
    inline for (@typeInfo(surface_autotrophic.State).@"struct".fields) |field| if (field.type == []f64) {
        const signed_exchange = std.mem.indexOf(u8, field.name, "_exchange_g_") != null;
        for (@field(view.surface_autotrophic, field.name)) |value| if (!std.math.isFinite(value) or (!signed_exchange and value < -1e-14)) return error.InvalidSoilOrganicCheckpointPool;
    };
    inline for (@typeInfo(surface_denitrification.State).@"struct".fields) |field| if (field.type == []f64) for (@field(view.surface_denitrification, field.name)) |value| if (!std.math.isFinite(value) or value < -1e-14) return error.InvalidSoilOrganicCheckpointPool;
    inline for (.{ view.surface_fire_exchange.pending_surface_ammonium_mol_n, view.surface_fire_exchange.pending_surface_phosphate_mol_p, view.surface_fire_exchange.pending_surface_salt_mol }) |values| for (values) |value| if (!std.math.isFinite(value) or value < -1e-14) return error.InvalidSoilOrganicCheckpointPool;
    for (view.litter_salt_ingress.pending_mol) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantLitterSaltCheckpointInventory;
}

fn writeNumericStruct(comptime T: type, writer: anytype, value: T) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const number = @field(value, field.name);
            if (!std.math.isFinite(number) or number < -1e-14) return error.InvalidSoilOrganicCheckpointPool;
            try writer.writeInt(u64, @bitCast(number), .little);
        },
        .@"struct" => try writeNumericStruct(field.type, writer, @field(value, field.name)),
        else => @compileError("unsupported litter chemistry checkpoint field"),
    };
}

fn readNumericStruct(comptime T: type, reader: *std.Io.Reader) !T {
    var value: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => @field(value, field.name) = @bitCast(try reader.takeInt(u64, .little)),
        .@"struct" => @field(value, field.name) = try readNumericStruct(field.type, reader),
        else => @compileError("unsupported litter chemistry checkpoint field"),
    };
    try validateNumericStruct(T, value);
    return value;
}

fn validateNumericStruct(comptime T: type, value: T) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => if (!std.math.isFinite(@field(value, field.name)) or @field(value, field.name) < -1e-14) return error.InvalidSoilOrganicCheckpointPool,
        .@"struct" => try validateNumericStruct(field.type, @field(value, field.name)),
        else => unreachable,
    };
}
fn bounded(reader: *std.Io.Reader, limit: usize, comptime too_large: anyerror) !usize {
    const value = try reader.takeInt(u64, .little);
    if (value == 0 or value > limit or value > std.math.maxInt(usize)) return too_large;
    return @intCast(value);
}
fn validatePool(pool: Pool) !void {
    inline for (@typeInfo(Pool).@"struct".fields) |field| {
        const value = @field(pool, field.name);
        if (!std.math.isFinite(value) or value < -1e-14) return error.InvalidSoilOrganicCheckpointPool;
    }
}
fn writePool(writer: anytype, pool: Pool) !void {
    try validatePool(pool);
    inline for (@typeInfo(Pool).@"struct".fields) |field| try writer.writeInt(u64, @bitCast(@field(pool, field.name)), .little);
}
fn readPool(reader: *std.Io.Reader) !Pool {
    var pool: Pool = undefined;
    inline for (@typeInfo(Pool).@"struct".fields) |field| @field(pool, field.name) = @bitCast(try reader.takeInt(u64, .little));
    try validatePool(pool);
    return pool;
}
fn readPoolSlice(reader: *std.Io.Reader, pools: []Pool) !void {
    for (pools) |*pool| pool.* = try readPool(reader);
}
fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.InvalidSoilOrganicCheckpointPool;
        try writer.writeInt(u64, @bitCast(value), .little);
    }
}
fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*)) return error.InvalidSoilOrganicCheckpointPool;
    }
}
fn readNonnegativeF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*) or value.* < 0)
            return error.InvalidPlantLitterSaltCheckpointInventory;
    }
}

test "soil organic checkpoint round trips every runtime organic pool" {
    var source = try State.init(std.testing.allocator, 9);
    defer source.deinit();
    var surface = try State.init(std.testing.allocator, 3);
    defer surface.deinit();
    var surface_chemistry = try litter_chemistry.State.init(std.testing.allocator, 3);
    defer surface_chemistry.deinit();
    var surface_fertilizer = try litter_fertilizer.State.init(std.testing.allocator, 3);
    defer surface_fertilizer.deinit();
    var respiration_state = try surface_respiration.State.init(std.testing.allocator, 3);
    defer respiration_state.deinit();
    var autotrophic_state = try surface_autotrophic.State.init(std.testing.allocator, 3);
    defer autotrophic_state.deinit();
    var denitrification_state = try surface_denitrification.State.init(std.testing.allocator, 3);
    defer denitrification_state.deinit();
    var surface_fire_state = try fire_exchange.State.init(std.testing.allocator, 3, organic.microbial_substrate_count);
    defer surface_fire_state.deinit();
    var litter_salt_state = try litter_salt_ingress.State.init(std.testing.allocator, 3, 3);
    defer litter_salt_state.deinit();
    source.microbial[source.microbial.len - 1] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 };
    source.residue[source.residue.len - 1] = .{ .carbon_g_c = 20, .nitrogen_g_n = 2, .phosphorus_g_p = 0.4 };
    source.dissolved[source.dissolved.len - 1] = .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.06 };
    source.adsorbed[source.adsorbed.len - 1] = .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.08 };
    source.dissolved_acetate_carbon_g_c[source.dissolved_acetate_carbon_g_c.len - 1] = 1.25;
    source.adsorbed_acetate_carbon_g_c[source.adsorbed_acetate_carbon_g_c.len - 1] = 2.25;
    source.structural[source.structural.len - 1] = .{ .carbon_g_c = 30, .nitrogen_g_n = 3, .phosphorus_g_p = 0.6 };
    source.colonized_structural_carbon_g_c[source.colonized_structural_carbon_g_c.len - 1] = 5;
    surface.microbial[0] = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.1 };
    surface.residue[0] = .{ .carbon_g_c = 5.5, .nitrogen_g_n = 0.55, .phosphorus_g_p = 0.11 };
    surface.dissolved[surface.dissolved.len - 1] = .{ .carbon_g_c = 6, .nitrogen_g_n = 0.6, .phosphorus_g_p = 0.12 };
    surface.adsorbed[0] = .{ .carbon_g_c = 6.5, .nitrogen_g_n = 0.65, .phosphorus_g_p = 0.13 };
    surface.dissolved_acetate_carbon_g_c[0] = 0.75;
    surface.adsorbed_acetate_carbon_g_c[0] = 0.875;
    surface.structural[0] = .{ .carbon_g_c = 7, .nitrogen_g_n = 0.7, .phosphorus_g_p = 0.14 };
    surface.colonized_structural_carbon_g_c[0] = 0.9375;
    surface_chemistry.cells[2].ammonium_mol_per_m3 = 0.75;
    surface_chemistry.cells[2].ammonia_mol_per_m3 = 0.25;
    surface_chemistry.cells[2].exchange.calcium_mol_per_megagram = 2.5;
    surface_chemistry.ph[0] = 5.75;
    surface_chemistry.ph[1] = 6.0;
    surface_chemistry.ph[2] = 6.25;
    surface_fertilizer.cells[2].urea_mol_n = 8.5;
    surface_fertilizer.formulation[2] = 4;
    respiration_state.previous_doc_respiration_g_c[respiration_state.previous_doc_respiration_g_c.len - 1] = 9.5;
    respiration_state.previous_oxygen_demand_g_o[respiration_state.previous_oxygen_demand_g_o.len - 1] = 4.75;
    autotrophic_state.previous_oxygen_demand_g_o[autotrophic_state.previous_oxygen_demand_g_o.len - 1] = 3.875;
    autotrophic_state.labile_maintenance_respiration_g_c[autotrophic_state.labile_maintenance_respiration_g_c.len - 1] = 0.9375;
    autotrophic_state.resistant_maintenance_respiration_g_c[autotrophic_state.resistant_maintenance_respiration_g_c.len - 1] = 0.46875;
    autotrophic_state.surface_ammonium_exchange_g_n[autotrophic_state.surface_ammonium_exchange_g_n.len - 1] = -0.234375;
    autotrophic_state.topsoil_hpo4_exchange_g_p[autotrophic_state.topsoil_hpo4_exchange_g_p.len - 1] = 0.1171875;
    denitrification_state.nitrite_g_n[2] = 1.75;
    surface_chemistry.mineral_reference_water_m3[2] = 0.375;
    surface_chemistry.dry_reference_water_m3[2] = 0.625;
    surface_chemistry.water_equilibrium_balance_mol[2] = -0.03125;
    denitrification_state.previous_nitrate_capacity_g_n[denitrification_state.previous_nitrate_capacity_g_n.len - 1] = 2.75;
    surface_fire_state.pending_surface_ammonium_mol_n[2] = 0.125;
    surface_fire_state.pending_surface_phosphate_mol_p[2] = 0.0625;
    surface_fire_state.pending_surface_salt_mol[2 * fire_exchange.salt_species_count + 7] = 0.03125;
    litter_salt_state.pending_mol[litter_salt_state.pending_mol.len - 1] = 0.015625;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .profile = &source, .surface = &surface, .litter_chemistry = &surface_chemistry, .litter_fertilizer = &surface_fertilizer, .surface_respiration = &respiration_state, .surface_autotrophic = &autotrophic_state, .surface_denitrification = &denitrification_state, .surface_fire_exchange = &surface_fire_state, .litter_salt_ingress = &litter_salt_state });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_profile_layers = 20, .maximum_surface_cells = 10 });
    defer restored.deinit();
    try std.testing.expectEqualSlices(Pool, source.microbial, restored.profile.microbial);
    try std.testing.expectEqualSlices(Pool, source.residue, restored.profile.residue);
    try std.testing.expectEqualSlices(Pool, source.dissolved, restored.profile.dissolved);
    try std.testing.expectEqualSlices(Pool, source.adsorbed, restored.profile.adsorbed);
    try std.testing.expectEqualSlices(f64, source.dissolved_acetate_carbon_g_c, restored.profile.dissolved_acetate_carbon_g_c);
    try std.testing.expectEqualSlices(f64, source.adsorbed_acetate_carbon_g_c, restored.profile.adsorbed_acetate_carbon_g_c);
    try std.testing.expectEqualSlices(Pool, source.structural, restored.profile.structural);
    try std.testing.expectEqualSlices(f64, source.colonized_structural_carbon_g_c, restored.profile.colonized_structural_carbon_g_c);
    try std.testing.expectEqualSlices(Pool, surface.microbial, restored.surface.microbial);
    try std.testing.expectEqualSlices(Pool, surface.residue, restored.surface.residue);
    try std.testing.expectEqualSlices(Pool, surface.dissolved, restored.surface.dissolved);
    try std.testing.expectEqualSlices(Pool, surface.adsorbed, restored.surface.adsorbed);
    try std.testing.expectEqualSlices(f64, surface.dissolved_acetate_carbon_g_c, restored.surface.dissolved_acetate_carbon_g_c);
    try std.testing.expectEqualSlices(f64, surface.adsorbed_acetate_carbon_g_c, restored.surface.adsorbed_acetate_carbon_g_c);
    try std.testing.expectEqualSlices(Pool, surface.structural, restored.surface.structural);
    try std.testing.expectEqualSlices(f64, surface.colonized_structural_carbon_g_c, restored.surface.colonized_structural_carbon_g_c);
    try std.testing.expectEqualDeep(surface_chemistry.cells, restored.litter_chemistry.cells);
    try std.testing.expectEqualSlices(f64, surface_chemistry.ph, restored.litter_chemistry.ph);
    try std.testing.expectEqualSlices(
        f64,
        surface_chemistry.mineral_reference_water_m3,
        restored.litter_chemistry.mineral_reference_water_m3,
    );
    try std.testing.expectEqualSlices(
        f64,
        surface_chemistry.dry_reference_water_m3,
        restored.litter_chemistry.dry_reference_water_m3,
    );
    try std.testing.expectEqualSlices(
        f64,
        surface_chemistry.water_equilibrium_balance_mol,
        restored.litter_chemistry.water_equilibrium_balance_mol,
    );
    try std.testing.expectEqualDeep(surface_fertilizer.cells, restored.litter_fertilizer.cells);
    try std.testing.expectEqualSlices(u8, surface_fertilizer.formulation, restored.litter_fertilizer.formulation);
    try std.testing.expectEqualSlices(f64, respiration_state.previous_doc_respiration_g_c, restored.surface_respiration.previous_doc_respiration_g_c);
    try std.testing.expectEqualSlices(f64, respiration_state.previous_oxygen_demand_g_o, restored.surface_respiration.previous_oxygen_demand_g_o);
    try std.testing.expectEqualSlices(f64, autotrophic_state.previous_oxygen_demand_g_o, restored.surface_autotrophic.previous_oxygen_demand_g_o);
    try std.testing.expectEqualSlices(f64, autotrophic_state.labile_maintenance_respiration_g_c, restored.surface_autotrophic.labile_maintenance_respiration_g_c);
    try std.testing.expectEqualSlices(f64, autotrophic_state.resistant_maintenance_respiration_g_c, restored.surface_autotrophic.resistant_maintenance_respiration_g_c);
    try std.testing.expectEqualSlices(f64, autotrophic_state.surface_ammonium_exchange_g_n, restored.surface_autotrophic.surface_ammonium_exchange_g_n);
    try std.testing.expectEqualSlices(f64, autotrophic_state.topsoil_hpo4_exchange_g_p, restored.surface_autotrophic.topsoil_hpo4_exchange_g_p);
    try std.testing.expectEqualSlices(f64, denitrification_state.nitrite_g_n, restored.surface_denitrification.nitrite_g_n);
    try std.testing.expectEqualSlices(f64, denitrification_state.previous_nitrate_capacity_g_n, restored.surface_denitrification.previous_nitrate_capacity_g_n);
    try std.testing.expectEqualSlices(f64, surface_fire_state.pending_surface_ammonium_mol_n, restored.surface_fire_exchange.pending_surface_ammonium_mol_n);
    try std.testing.expectEqualSlices(f64, surface_fire_state.pending_surface_phosphate_mol_p, restored.surface_fire_exchange.pending_surface_phosphate_mol_p);
    try std.testing.expectEqualSlices(f64, surface_fire_state.pending_surface_salt_mol, restored.surface_fire_exchange.pending_surface_salt_mol);
    try std.testing.expectEqualSlices(f64, litter_salt_state.pending_mol, restored.litter_salt_ingress.pending_mol);
    try std.testing.expectEqual(
        @as(u64, @bitCast(litter_salt_state.pending_mol[litter_salt_state.pending_mol.len - 1])),
        @as(u64, @bitCast(restored.litter_salt_ingress.pending_mol[restored.litter_salt_ingress.pending_mol.len - 1])),
    );

    const corrupted_species = try std.testing.allocator.dupe(u8, bytes.written());
    defer std.testing.allocator.free(corrupted_species);
    corrupted_species[44] = 7;
    var corrupted_species_reader: std.Io.Reader = .fixed(corrupted_species);
    try std.testing.expectError(
        error.UnsupportedPlantLitterSaltSpeciesLayout,
        read(std.testing.allocator, &corrupted_species_reader, .{ .maximum_profile_layers = 20, .maximum_surface_cells = 10 }),
    );

    const corrupted_dimensions = try std.testing.allocator.dupe(u8, bytes.written());
    defer std.testing.allocator.free(corrupted_dimensions);
    corrupted_dimensions[28] = 2;
    var corrupted_dimensions_reader: std.Io.Reader = .fixed(corrupted_dimensions);
    try std.testing.expectError(
        error.InvalidPlantLitterSaltCheckpointDimensions,
        read(std.testing.allocator, &corrupted_dimensions_reader, .{ .maximum_profile_layers = 20, .maximum_surface_cells = 10 }),
    );

    var truncated_reader: std.Io.Reader = .fixed(bytes.written()[0 .. bytes.written().len - 1]);
    try std.testing.expectError(
        error.EndOfStream,
        read(std.testing.allocator, &truncated_reader, .{ .maximum_profile_layers = 20, .maximum_surface_cells = 10 }),
    );
}

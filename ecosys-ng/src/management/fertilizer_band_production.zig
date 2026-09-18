const std = @import("std");
const band_state = @import("fertilizer_band_state.zig");
const geometry = @import("hourly_fertilizer_band_geometry.zig");
const phase = @import("fertilizer_band_phase_coordinator.zig");
const repartition = @import("fertilizer_band_inventory_repartition.zig");
const nitrogen = @import("fertilizer_nitrogen_inventory.zig");
const mineral = @import("mineral_fertilizer_inventory.zig");
const nutrient_parameters = @import("../plant/root/plant_root_nutrient_uptake.zig");
const chemistry_module = @import("../soil/solute/chemistry_state.zig");
const cation_exchange = @import("../soil/solute/cation_exchange.zig");
const aqueous_network = @import("../soil/solute/aqueous_network.zig");
const reactive_nitrogen_module = @import("../soil/nutrients/reactive_nitrogen_state.zig");
const phosphate_network = @import("../soil/solute/phosphate_network.zig");

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    geometry: geometry.Workspace,
    upper_depth_m: []f64,
    lower_depth_m: []f64,
    diffusivity_m2_per_h: []f64,
    tortuosity: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !Workspace {
        var geometry_workspace = try geometry.Workspace.init(allocator, layer_count);
        errdefer geometry_workspace.deinit();
        const upper = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(upper);
        const lower = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(lower);
        const diffusivity = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(diffusivity);
        const tortuosity = try allocator.alloc(f64, layer_count);
        return .{ .allocator = allocator, .geometry = geometry_workspace, .upper_depth_m = upper, .lower_depth_m = lower, .diffusivity_m2_per_h = diffusivity, .tortuosity = tortuosity };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.tortuosity);
        self.allocator.free(self.diffusivity_m2_per_h);
        self.allocator.free(self.lower_depth_m);
        self.allocator.free(self.upper_depth_m);
        self.geometry.deinit();
        self.* = undefined;
    }
};

/// HOUR1 (`hour1.f:4888-5155`) production boundary. Cell coordinators own
/// generation state; the reusable heap workspace owns all temporary arrays.
pub fn prepareHour(
    state: *band_state.State,
    token: phase.HourToken,
    layer_thickness_m: []const f64,
    matrix_liquid_water_m3: []const f64,
    matrix_pore_capacity_m3: []const f64,
    soil_temperature_k: []const f64,
    active_layer_count_by_cell: []const usize,
    minimum_layer_thickness_m: f64,
    parameters: nutrient_parameters.RuntimeParameters,
    workspace: *Workspace,
) !void {
    const layer_count = state.cell_count * state.layer_capacity;
    if (layer_thickness_m.len != layer_count or matrix_liquid_water_m3.len != layer_count or matrix_pore_capacity_m3.len != layer_count or soil_temperature_k.len != layer_count or active_layer_count_by_cell.len != state.cell_count or workspace.upper_depth_m.len != state.layer_capacity) return error.FertilizerBandProductionDimensionMismatch;
    if (!std.math.isFinite(minimum_layer_thickness_m) or minimum_layer_thickness_m < 0) return error.InvalidFertilizerBandProductionInput;
    try parameters.validate();
    for (state.coordinators) |*coordinator| {
        const metadata = coordinator.persistentMetadata();
        if (metadata.phase != .idle) return error.FertilizerBandHourStillPending;
        if (token.value == 0 or token.value <= metadata.last_completed_token) return error.StaleFertilizerBandHourToken;
    }

    const upper = workspace.upper_depth_m;
    const lower = workspace.lower_depth_m;
    const effective_diffusivity = workspace.diffusivity_m2_per_h;
    const tortuosity = workspace.tortuosity;
    for (0..state.cell_count) |cell| {
        const active_count = active_layer_count_by_cell[cell];
        if (active_count == 0 or active_count > state.layer_capacity) return error.InvalidFertilizerBandActiveLayerCount;
        const base = cell * state.layer_capacity;
        var depth_m: f64 = 0;
        for (0..state.layer_capacity) |layer| {
            const index = base + layer;
            upper[layer] = depth_m;
            depth_m += layer_thickness_m[index];
            lower[layer] = depth_m;
            const pore = matrix_pore_capacity_m3[index];
            const liquid = matrix_liquid_water_m3[index];
            if (!std.math.isFinite(pore) or pore < 0 or !std.math.isFinite(liquid) or liquid < 0) return error.InvalidFertilizerBandProductionInput;
            const water_fraction = if (pore > 0) std.math.clamp(liquid / pore, 0, 1) else 0;
            tortuosity[layer] = parameters.liquid_tortuosity_coefficient * water_fraction * water_fraction;
        }
        const coordinator = try state.coordinator(cell);
        try coordinator.beginHour(token);
        inline for (std.enums.values(phase.Family)) |family| {
            const nutrient_index: usize = @intFromEnum(family);
            const view = try state.geometry(cell, family);
            const uniform_profile = view.active and
                @abs(view.upper_edge_depth_m) <= 1.0e-12 and
                @abs(view.lower_edge_depth_m - lower[active_count - 1]) <= 1.0e-12;
            for (0..state.layer_capacity) |layer| effective_diffusivity[layer] = if (uniform_profile)
                0
            else
                try parameters.diffusivityM2PerH(nutrient_index, soil_temperature_k[base + layer]);
            try state.prepareFamily(cell, token, family, .{
                .upper_depth_m = upper,
                .lower_depth_m = lower,
                .thickness_m = layer_thickness_m[base..][0..state.layer_capacity],
                .first_active_layer = 0,
                .last_active_layer = active_count - 1,
                .minimum_active_thickness_m = minimum_layer_thickness_m,
                .structural_presence_threshold = 1.0e-12,
            }, .{
                .diffusivity_m2_per_h = effective_diffusivity,
                .tortuosity = tortuosity,
                .timestep_h = 1,
            }, &workspace.geometry);
        }
    }
}

/// SOLUTE (`solute.f:3750-3915`) production boundary for authoritative
/// undissolved stores. Complete validation precedes each cell's source-order
/// NH4, NO3, PO4 state_update.
pub fn consumeUndissolved(
    allocator: std.mem.Allocator,
    state: *band_state.State,
    token: phase.HourToken,
    nitrogen_state: *nitrogen.State,
    mineral_state: *mineral.State,
    chemistry: *chemistry_module.State,
    reactive_nitrogen: *reactive_nitrogen_module.State,
    salinity_enabled_by_cell: []const bool,
) !void {
    const layer_count = state.cell_count * state.layer_capacity;
    if (nitrogen_state.cell_count != state.cell_count or nitrogen_state.layer_capacity != state.layer_capacity or mineral_state.cell_count != state.cell_count or mineral_state.layer_capacity != state.layer_capacity or chemistry.cell_count != layer_count or reactive_nitrogen.layer_count != layer_count or salinity_enabled_by_cell.len != state.cell_count) return error.FertilizerBandProductionDimensionMismatch;
    for (state.coordinators) |*coordinator| {
        const metadata = coordinator.persistentMetadata();
        if (metadata.current_token != token.value) return error.FertilizerBandHourTokenMismatch;
        if (metadata.phase != .intervening_science) return error.InvalidFertilizerBandCoordinatorPhase;
    }
    for (nitrogen_state.soil, mineral_state.soil) |nitrogen_inventory, mineral_inventory| {
        inline for (@typeInfo(@TypeOf(nitrogen_inventory)).@"struct".fields) |field| {
            const value = @field(nitrogen_inventory, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidBandInventoryState;
        }
        inline for (.{ mineral_inventory.broadcast_monocalcium_phosphate_mol, mineral_inventory.banded_monocalcium_phosphate_mol }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidBandInventoryState;
    }
    const count = state.layer_capacity;
    const first = try allocator.alloc(f64, count);
    defer allocator.free(first);
    const second = try allocator.alloc(f64, count);
    defer allocator.free(second);
    const third = try allocator.alloc(f64, count);
    defer allocator.free(third);
    const fourth = try allocator.alloc(f64, count);
    defer allocator.free(fourth);
    const fifth = try allocator.alloc(f64, count);
    defer allocator.free(fifth);
    const sixth = try allocator.alloc(f64, count);
    defer allocator.free(sixth);
    const seventh = try allocator.alloc(f64, count);
    defer allocator.free(seventh);
    const eighth = try allocator.alloc(f64, count);
    defer allocator.free(eighth);
    const ninth = try allocator.alloc(f64, count);
    defer allocator.free(ninth);
    const tenth = try allocator.alloc(f64, count);
    defer allocator.free(tenth);
    const next_exchange = try allocator.dupe(cation_exchange.Cations, chemistry.cation_exchange_mol_per_megagram);
    defer allocator.free(next_exchange);
    const next_aqueous = try allocator.dupe(aqueous_network.State, chemistry.aqueous);
    defer allocator.free(next_aqueous);
    const next_non_band_nitrite_g_n = try allocator.dupe(f64, reactive_nitrogen.non_band_nitrite_g_n);
    defer allocator.free(next_non_band_nitrite_g_n);
    const next_band_nitrite_g_n = try allocator.dupe(f64, reactive_nitrogen.band_nitrite_g_n);
    defer allocator.free(next_band_nitrite_g_n);
    const next_non_band_phosphate = try allocator.dupe(phosphate_network.State, chemistry.non_band_phosphate);
    defer allocator.free(next_non_band_phosphate);
    const next_band_phosphate = try allocator.dupe(phosphate_network.State, chemistry.band_phosphate);
    defer allocator.free(next_band_phosphate);
    for (0..state.cell_count) |cell| {
        const coordinator = try state.coordinator(cell);
        const base = cell * count;
        const relative_ammonium_change = coordinator.persistentRelativeChanges()[0..count];
        const relative_nitrate_change = coordinator.persistentRelativeChanges()[count .. 2 * count];
        const relative_phosphate_change = coordinator.persistentRelativeChanges()[2 * count .. 3 * count];
        for (0..count) |layer| {
            const fractions = try state.zoneFractions(cell, layer);
            const exchange = chemistry.cation_exchange_mol_per_megagram[base + layer];
            const next = try repartitionConcentrations(exchange.ammonium_non_band, exchange.ammonium_band, fractions.ammonium_non_band, fractions.ammonium_band, relative_ammonium_change[layer]);
            next_exchange[base + layer].ammonium_non_band = next.non_band;
            next_exchange[base + layer].ammonium_band = next.band;
            const aqueous = chemistry.aqueous[base + layer];
            const next_ammonium = try repartitionConcentrations(aqueous.ammonium_non_band, aqueous.ammonium_band, fractions.ammonium_non_band, fractions.ammonium_band, relative_ammonium_change[layer]);
            const next_ammonia = try repartitionConcentrations(aqueous.ammonia_non_band, aqueous.ammonia_band, fractions.ammonium_non_band, fractions.ammonium_band, relative_ammonium_change[layer]);
            next_aqueous[base + layer].ammonium_non_band = next_ammonium.non_band;
            next_aqueous[base + layer].ammonium_band = next_ammonium.band;
            next_aqueous[base + layer].ammonia_non_band = next_ammonia.non_band;
            next_aqueous[base + layer].ammonia_band = next_ammonia.band;
            const next_nitrate = try repartitionConcentrations(aqueous.nitrate_non_band, aqueous.nitrate_band, fractions.nitrate_non_band, fractions.nitrate_band, relative_nitrate_change[layer]);
            next_aqueous[base + layer].nitrate_non_band = next_nitrate.non_band;
            next_aqueous[base + layer].nitrate_band = next_nitrate.band;
            const next_nitrite = try repartitionExtensivePair(
                reactive_nitrogen.non_band_nitrite_g_n[base + layer],
                reactive_nitrogen.band_nitrite_g_n[base + layer],
                relative_nitrate_change[layer],
            );
            next_non_band_nitrite_g_n[base + layer] = next_nitrite.non_band;
            next_band_nitrite_g_n[base + layer] = next_nitrite.band;
            try stagePhosphatePair(
                &next_non_band_phosphate[base + layer],
                &next_band_phosphate[base + layer],
                chemistry.non_band_phosphate[base + layer],
                chemistry.band_phosphate[base + layer],
                fractions.phosphate_non_band,
                fractions.phosphate_band,
                relative_phosphate_change[layer],
                salinity_enabled_by_cell[cell],
            );
        }
    }

    for (0..state.cell_count) |cell| {
        const coordinator = try state.coordinator(cell);
        try coordinator.markInterveningScienceComplete(token);
        const base = cell * count;
        for (0..count) |layer| {
            const inventory = nitrogen_state.soil[base + layer];
            first[layer] = inventory.broadcast_ammonium_mol_n;
            second[layer] = inventory.banded_ammonium_mol_n;
            third[layer] = inventory.broadcast_ammonia_mol_n;
            fourth[layer] = inventory.banded_ammonia_mol_n;
            fifth[layer] = inventory.broadcast_urea_mol_n;
            sixth[layer] = inventory.banded_urea_mol_n;
            seventh[layer] = inventory.broadcast_nitrate_mol_n;
            eighth[layer] = inventory.banded_nitrate_mol_n;
            ninth[layer] = mineral_state.soil[base + layer].broadcast_monocalcium_phosphate_mol;
            tenth[layer] = mineral_state.soil[base + layer].banded_monocalcium_phosphate_mol;
        }
        const ammonium_pools = [_]repartition.Pool{
            immediate("undissolved ammonium", first, second),
            immediate("undissolved ammonia", third, fourth),
            immediate("undissolved urea", fifth, sixth),
        };
        _ = try coordinator.consumeFamily(token, .ammonium, &ammonium_pools);
        const nitrate_pools = [_]repartition.Pool{immediate("undissolved nitrate", seventh, eighth)};
        _ = try coordinator.consumeFamily(token, .nitrate, &nitrate_pools);
        const phosphate_pools = [_]repartition.Pool{immediate("undissolved monocalcium phosphate", ninth, tenth)};
        _ = try coordinator.consumeFamily(token, .phosphate, &phosphate_pools);
        for (0..count) |layer| {
            nitrogen_state.soil[base + layer].broadcast_ammonium_mol_n = first[layer];
            nitrogen_state.soil[base + layer].banded_ammonium_mol_n = second[layer];
            nitrogen_state.soil[base + layer].broadcast_ammonia_mol_n = third[layer];
            nitrogen_state.soil[base + layer].banded_ammonia_mol_n = fourth[layer];
            nitrogen_state.soil[base + layer].broadcast_urea_mol_n = fifth[layer];
            nitrogen_state.soil[base + layer].banded_urea_mol_n = sixth[layer];
            nitrogen_state.soil[base + layer].broadcast_nitrate_mol_n = seventh[layer];
            nitrogen_state.soil[base + layer].banded_nitrate_mol_n = eighth[layer];
            mineral_state.soil[base + layer].broadcast_monocalcium_phosphate_mol = ninth[layer];
            mineral_state.soil[base + layer].banded_monocalcium_phosphate_mol = tenth[layer];
            chemistry.cation_exchange_mol_per_megagram[base + layer] = next_exchange[base + layer];
            chemistry.aqueous[base + layer] = next_aqueous[base + layer];
            reactive_nitrogen.non_band_nitrite_g_n[base + layer] = next_non_band_nitrite_g_n[base + layer];
            reactive_nitrogen.band_nitrite_g_n[base + layer] = next_band_nitrite_g_n[base + layer];
            chemistry.non_band_phosphate[base + layer] = next_non_band_phosphate[base + layer];
            chemistry.band_phosphate[base + layer] = next_band_phosphate[base + layer];
        }
    }
}

fn stagePhosphatePair(
    next_non_band: *phosphate_network.State,
    next_band: *phosphate_network.State,
    current_non_band: phosphate_network.State,
    current_band: phosphate_network.State,
    new_non_band_fraction: f64,
    new_band_fraction: f64,
    relative_non_band_change: f64,
    dynamic_salts: bool,
) !void {
    inline for (.{
        "dissolved_hpo4_mol_p_per_m3",
        "dissolved_h2po4_mol_p_per_m3",
        "deprotonated_site_mol_per_megagram",
        "hydroxyl_site_mol_per_megagram",
        "protonated_site_mol_per_megagram",
        "adsorbed_hpo4_mol_p_per_megagram",
        "adsorbed_h2po4_mol_p_per_megagram",
        "aluminum_phosphate_solid_mol_per_m3",
        "iron_phosphate_solid_mol_per_m3",
        "dicalcium_phosphate_solid_mol_per_m3",
        "hydroxyapatite_solid_mol_per_m3",
        "monocalcium_phosphate_solid_mol_per_m3",
    }) |name| try stageNamedConcentrationPair(next_non_band, next_band, current_non_band, current_band, name, new_non_band_fraction, new_band_fraction, relative_non_band_change);
    if (dynamic_salts) inline for (.{
        "dissolved_po4_mol_p_per_m3",
        "dissolved_h3po4_mol_p_per_m3",
        "iron_hpo4_pair_mol_per_m3",
        "iron_h2po4_pair_mol_per_m3",
        "calcium_po4_pair_mol_per_m3",
        "calcium_hpo4_pair_mol_per_m3",
        "calcium_h2po4_pair_mol_per_m3",
        "magnesium_hpo4_pair_mol_per_m3",
    }) |name| try stageNamedConcentrationPair(next_non_band, next_band, current_non_band, current_band, name, new_non_band_fraction, new_band_fraction, relative_non_band_change);
}

fn stageNamedConcentrationPair(
    next_non_band: *phosphate_network.State,
    next_band: *phosphate_network.State,
    current_non_band: phosphate_network.State,
    current_band: phosphate_network.State,
    comptime name: []const u8,
    new_non_band_fraction: f64,
    new_band_fraction: f64,
    relative_non_band_change: f64,
) !void {
    const next = try repartitionConcentrations(@field(current_non_band, name), @field(current_band, name), new_non_band_fraction, new_band_fraction, relative_non_band_change);
    @field(next_non_band.*, name) = next.non_band;
    @field(next_band.*, name) = next.band;
}

const ConcentrationPair = struct { non_band: f64, band: f64 };
const ExtensivePair = struct { non_band: f64, band: f64 };

fn repartitionExtensivePair(
    non_band: f64,
    band: f64,
    relative_non_band_change: f64,
) !ExtensivePair {
    inline for (.{ non_band, band, relative_non_band_change }) |value| if (!std.math.isFinite(value)) return error.InvalidBandInventoryState;
    if (non_band < 0 or band < 0 or relative_non_band_change < -1 or relative_non_band_change > 0) return error.InvalidBandInventoryState;
    const transfer = relative_non_band_change * non_band;
    const next_non_band = non_band + transfer;
    const next_band = band - transfer;
    if (!std.math.isFinite(next_non_band) or !std.math.isFinite(next_band) or next_non_band < 0 or next_band < 0) return error.InvalidBandInventoryState;
    return .{ .non_band = next_non_band, .band = next_band };
}

/// Reconstructs the pre-HOUR1 zone fractions from FVL and conserves the
/// extensive inventory while publishing concentrations in the new geometry.
fn repartitionConcentrations(
    non_band_concentration: f64,
    band_concentration: f64,
    new_non_band_fraction: f64,
    new_band_fraction: f64,
    relative_non_band_change: f64,
) !ConcentrationPair {
    inline for (.{ non_band_concentration, band_concentration, new_non_band_fraction, new_band_fraction, relative_non_band_change }) |value| if (!std.math.isFinite(value)) return error.InvalidBandInventoryState;
    if (non_band_concentration < 0 or band_concentration < 0 or new_non_band_fraction < 0 or new_band_fraction < 0 or @abs(new_non_band_fraction + new_band_fraction - 1) > 1.0e-12 or relative_non_band_change < -1 or relative_non_band_change > 0) return error.InvalidBandInventoryState;
    if (relative_non_band_change == 0) return .{ .non_band = non_band_concentration, .band = band_concentration };
    const retained_fraction = 1 + relative_non_band_change;
    if (retained_fraction <= 0 or new_band_fraction <= 0) return error.InvalidBandInventoryState;
    const old_non_band_fraction = new_non_band_fraction / retained_fraction;
    const old_band_fraction = 1 - old_non_band_fraction;
    if (old_non_band_fraction < 0 or old_non_band_fraction > 1 or old_band_fraction < 0) return error.InvalidBandInventoryState;
    const transferred = -relative_non_band_change * old_non_band_fraction * non_band_concentration;
    const next_band = (old_band_fraction * band_concentration + transferred) / new_band_fraction;
    if (!std.math.isFinite(next_band) or next_band < 0) return error.InvalidBandInventoryState;
    return .{ .non_band = non_band_concentration, .band = next_band };
}

fn immediate(name: []const u8, non_band: []f64, band: []f64) repartition.Pool {
    return .{ .name = name, .inventory_unit = .moles, .storage = .{ .immediate = .{ .non_band_inventory = non_band, .band_inventory = band } } };
}

test "production boundaries reject stale and duplicate hour consumption" {
    var state = try band_state.State.init(std.testing.allocator, .{
        .cell_count = 1,
        .layer_capacity = 1,
        .active_layer_count_by_cell = &.{1},
        .layer_upper_depth_m = &.{0},
        .layer_lower_depth_m = &.{0.1},
        .layer_thickness_m = &.{0.1},
        .initial_band_fraction_by_family = .{ 0, 0, 0 },
        .row_spacing_m_by_cell_family = &.{ 1, 1, 1 },
    });
    defer state.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 1);
    defer workspace.deinit();
    const token: phase.HourToken = .{ .value = 7 };
    try prepareHour(&state, token, &.{0.1}, &.{0.02}, &.{0.04}, &.{283.15}, &.{1}, 1e-6, nutrient_parameters.compatibilityRuntimeParameters(), &workspace);
    var nitrogen_state = try nitrogen.State.init(std.testing.allocator, 1, 1);
    defer nitrogen_state.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, 1, 1);
    defer mineral_state.deinit();
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var reactive_nitrogen = try reactive_nitrogen_module.State.init(std.testing.allocator, 1, 1);
    defer reactive_nitrogen.deinit();
    chemistry.cation_exchange_mol_per_megagram[0].ammonium_non_band = std.math.nan(f64);
    try std.testing.expectError(error.InvalidBandInventoryState, consumeUndissolved(std.testing.allocator, &state, token, &nitrogen_state, &mineral_state, &chemistry, &reactive_nitrogen, &.{false}));
    try std.testing.expectEqual(phase.Phase.intervening_science, (try state.coordinator(0)).persistentMetadata().phase);
    chemistry.cation_exchange_mol_per_megagram[0].ammonium_non_band = 0;
    chemistry.aqueous[0].ammonia_band = std.math.nan(f64);
    try std.testing.expectError(error.InvalidBandInventoryState, consumeUndissolved(std.testing.allocator, &state, token, &nitrogen_state, &mineral_state, &chemistry, &reactive_nitrogen, &.{false}));
    try std.testing.expectEqual(phase.Phase.intervening_science, (try state.coordinator(0)).persistentMetadata().phase);
    chemistry.aqueous[0].ammonia_band = 0;
    chemistry.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 = std.math.nan(f64);
    try std.testing.expectError(error.InvalidBandInventoryState, consumeUndissolved(std.testing.allocator, &state, token, &nitrogen_state, &mineral_state, &chemistry, &reactive_nitrogen, &.{false}));
    try std.testing.expectEqual(phase.Phase.intervening_science, (try state.coordinator(0)).persistentMetadata().phase);
    chemistry.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 = 0;
    try consumeUndissolved(std.testing.allocator, &state, token, &nitrogen_state, &mineral_state, &chemistry, &reactive_nitrogen, &.{false});
    try std.testing.expectError(error.FertilizerBandHourTokenMismatch, consumeUndissolved(std.testing.allocator, &state, token, &nitrogen_state, &mineral_state, &chemistry, &reactive_nitrogen, &.{false}));
    try std.testing.expectError(error.StaleFertilizerBandHourToken, prepareHour(&state, token, &.{0.1}, &.{0.02}, &.{0.04}, &.{283.15}, &.{1}, 1e-6, nutrient_parameters.compatibilityRuntimeParameters(), &workspace));
}

test "exchangeable ammonium concentration repartition conserves extensive moles" {
    const result = try repartitionConcentrations(10, 2, 0.7, 0.3, -0.125);
    const before = 0.8 * 10 + 0.2 * 2;
    const after = 0.7 * result.non_band + 0.3 * result.band;
    try std.testing.expectApproxEqAbs(before, after, 1.0e-14);
    try std.testing.expectEqual(@as(f64, 10), result.non_band);
}

test "band expansion preserves fraction-weighted CEC site capacity" {
    const next_non_band_fraction: f64 = 0.7;
    const next_band_fraction: f64 = 0.3;
    const ammonium = try repartitionConcentrations(
        10,
        2,
        next_non_band_fraction,
        next_band_fraction,
        -0.125,
    );
    const shared_cation_charge: f64 = 17;
    const before = 0.8 * 10 + 0.2 * 2 + shared_cation_charge;
    const after = next_non_band_fraction * ammonium.non_band +
        next_band_fraction * ammonium.band + shared_cation_charge;
    try std.testing.expectApproxEqAbs(before, after, 1.0e-14);
}

test "aqueous ammonium and ammonia use zone water fractions conservatively" {
    const ammonium = try repartitionConcentrations(8, 1, 0.72, 0.28, -0.1);
    const ammonia = try repartitionConcentrations(3, 0.5, 0.72, 0.28, -0.1);
    const old_non_band_fraction = 0.8;
    const old_band_fraction = 0.2;
    try std.testing.expectApproxEqAbs(
        old_non_band_fraction * 8 + old_band_fraction * 1,
        0.72 * ammonium.non_band + 0.28 * ammonium.band,
        1.0e-14,
    );
    try std.testing.expectApproxEqAbs(
        old_non_band_fraction * 3 + old_band_fraction * 0.5,
        0.72 * ammonia.non_band + 0.28 * ammonia.band,
        1.0e-14,
    );
}

test "nitrate concentration and extensive nitrite repartition conserve nitrogen" {
    const nitrate = try repartitionConcentrations(6, 2, 0.72, 0.28, -0.1);
    const nitrite = try repartitionExtensivePair(8, 3, -0.1);
    try std.testing.expectApproxEqAbs(
        0.8 * 6 + 0.2 * 2,
        0.72 * nitrate.non_band + 0.28 * nitrate.band,
        1.0e-14,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 11), nitrite.non_band + nitrite.band, 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 7.2), nitrite.non_band, 1.0e-14);
}

test "complete phosphate family conserves each carrier and honors dynamic salt gate" {
    var current_non_band = std.mem.zeroes(phosphate_network.State);
    var current_band = std.mem.zeroes(phosphate_network.State);
    current_non_band.dissolved_h2po4_mol_p_per_m3 = 10;
    current_band.dissolved_h2po4_mol_p_per_m3 = 2;
    current_non_band.adsorbed_hpo4_mol_p_per_megagram = 5;
    current_band.adsorbed_hpo4_mol_p_per_megagram = 1;
    current_non_band.aluminum_phosphate_solid_mol_per_m3 = 3;
    current_band.aluminum_phosphate_solid_mol_per_m3 = 0.5;
    current_non_band.iron_hpo4_pair_mol_per_m3 = 4;
    current_band.iron_hpo4_pair_mol_per_m3 = 1;
    var next_non_band = current_non_band;
    var next_band = current_band;
    try stagePhosphatePair(&next_non_band, &next_band, current_non_band, current_band, 0.72, 0.28, -0.1, true);
    inline for (.{
        "dissolved_h2po4_mol_p_per_m3",
        "adsorbed_hpo4_mol_p_per_megagram",
        "aluminum_phosphate_solid_mol_per_m3",
        "iron_hpo4_pair_mol_per_m3",
    }) |name| try std.testing.expectApproxEqAbs(
        0.8 * @field(current_non_band, name) + 0.2 * @field(current_band, name),
        0.72 * @field(next_non_band, name) + 0.28 * @field(next_band, name),
        1.0e-14,
    );
    next_non_band = current_non_band;
    next_band = current_band;
    try stagePhosphatePair(&next_non_band, &next_band, current_non_band, current_band, 0.72, 0.28, -0.1, false);
    try std.testing.expectEqual(current_band.iron_hpo4_pair_mol_per_m3, next_band.iron_hpo4_pair_mol_per_m3);
}

const std = @import("std");
const schedule = @import("fertilizer_schedule.zig");
const chemistry_module = @import("../soil/solute/chemistry_state.zig");
const surface_chemistry_module = @import("../surface/litter_chemistry.zig");
const charge_classification = @import("../soil/solute/charge_classification.zig");

pub const Inventory = struct {
    broadcast_monocalcium_phosphate_mol: f64 = 0,
    banded_monocalcium_phosphate_mol: f64 = 0,
    hydroxyapatite_mol: f64 = 0,
    calcite_mol: f64 = 0,
    gypsum_mol: f64 = 0,
    aluminum_ground_silicate_mol: f64 = 0,
    iron_ground_silicate_mol: f64 = 0,
    calcium_ground_silicate_mol: f64 = 0,
    magnesium_ground_silicate_mol: f64 = 0,
    sodium_ground_silicate_mol: f64 = 0,
    potassium_ground_silicate_mol: f64 = 0,
};

/// Extensive HOUR1 mineral-fertilizer stores. Concentration-based SOLUTE
/// owners consume these pools using their current runtime water volumes.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    layer_capacity: usize,
    soil: []Inventory,
    surface: []Inventory,
    daily_phosphorus_input_g_p: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_capacity: usize) !State {
        if (cell_count == 0 or layer_capacity == 0) return error.ZeroMineralFertilizerExtent;
        const soil_count = try std.math.mul(usize, cell_count, layer_capacity);
        const soil = try allocator.alloc(Inventory, soil_count);
        errdefer allocator.free(soil);
        const surface = try allocator.alloc(Inventory, cell_count);
        errdefer allocator.free(surface);
        const daily_phosphorus = try allocator.alloc(f64, cell_count);
        @memset(soil, .{});
        @memset(surface, .{});
        @memset(daily_phosphorus, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .layer_capacity = layer_capacity, .soil = soil, .surface = surface, .daily_phosphorus_input_g_p = daily_phosphorus };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.daily_phosphorus_input_g_p);
        self.allocator.free(self.surface);
        self.allocator.free(self.soil);
        self.* = undefined;
    }

    pub fn resetDaily(self: *State) void {
        @memset(self.daily_phosphorus_input_g_p, 0);
    }
};

pub fn applyEvent(
    state: *State,
    cell: usize,
    cell_area_m2: f64,
    surface_litter_cover_fraction: f64,
    active_layer_thickness_m: []const f64,
    event: schedule.Event,
) !void {
    if (cell >= state.cell_count or active_layer_thickness_m.len == 0 or active_layer_thickness_m.len > state.layer_capacity) return error.MineralFertilizerIndexOutOfBounds;
    if (!std.math.isFinite(cell_area_m2) or cell_area_m2 <= 0 or !validFraction(surface_litter_cover_fraction) or !std.math.isFinite(event.application_depth_m) or event.application_depth_m < 0) return error.InvalidMineralFertilizerApplication;
    for (active_layer_thickness_m) |thickness| if (!std.math.isFinite(thickness) or thickness <= 0) return error.InvalidMineralFertilizerApplication;
    const p = event.phosphorus_g_per_m2;
    inline for (.{ p.broadcast_monocalcium_phosphate, p.banded_monocalcium_phosphate, p.broadcast_hydroxyapatite, event.calcium_carbonate_g_ca_per_m2, event.calcium_sulfate_g_ca_per_m2 }) |amount|
        if (!std.math.isFinite(amount) or amount < 0) return error.InvalidMineralFertilizerApplication;

    const layer = try layerAtDepth(active_layer_thickness_m, event.application_depth_m);
    const soil_index = cell * state.layer_capacity + layer;
    var next_soil = state.soil[soil_index];
    var next_surface = state.surface[cell];
    const n = event.nitrogen_g_per_m2;
    const banded_nitrogen = n.banded_ammonium + n.banded_ammonia + n.banded_urea + n.banded_nitrate;
    const surface_target = event.application_depth_m == 0 and banded_nitrogen == 0 and p.banded_monocalcium_phosphate == 0 and event.calcium_carbonate_g_ca_per_m2 == 0 and event.calcium_sulfate_g_ca_per_m2 == 0;
    const monocalcium_mol = p.broadcast_monocalcium_phosphate * cell_area_m2 / 62.0;
    const hydroxyapatite_mol = p.broadcast_hydroxyapatite * cell_area_m2 / 93.0;
    if (surface_target) {
        const bare_fraction = 1.0 - surface_litter_cover_fraction;
        next_surface.broadcast_monocalcium_phosphate_mol += monocalcium_mol * surface_litter_cover_fraction;
        next_surface.hydroxyapatite_mol += hydroxyapatite_mol * surface_litter_cover_fraction;
        next_soil.broadcast_monocalcium_phosphate_mol += monocalcium_mol * bare_fraction;
        next_soil.hydroxyapatite_mol += hydroxyapatite_mol * bare_fraction;
    } else {
        next_soil.broadcast_monocalcium_phosphate_mol += monocalcium_mol;
        next_soil.hydroxyapatite_mol += hydroxyapatite_mol;
    }
    next_soil.banded_monocalcium_phosphate_mol += p.banded_monocalcium_phosphate * cell_area_m2 / 62.0;
    next_soil.calcite_mol += event.calcium_carbonate_g_ca_per_m2 * cell_area_m2 / 40.0;
    if (event.fertilizer_formulation < 10) {
        next_soil.gypsum_mol += event.calcium_sulfate_g_ca_per_m2 * cell_area_m2 / 40.0;
    } else {
        const each_ground_silicate_mol = event.calcium_sulfate_g_ca_per_m2 * cell_area_m2 / (92.0 * 6.0);
        next_soil.aluminum_ground_silicate_mol += each_ground_silicate_mol;
        next_soil.iron_ground_silicate_mol += each_ground_silicate_mol;
        next_soil.calcium_ground_silicate_mol += each_ground_silicate_mol;
        next_soil.magnesium_ground_silicate_mol += each_ground_silicate_mol;
        next_soil.sodium_ground_silicate_mol += each_ground_silicate_mol;
        next_soil.potassium_ground_silicate_mol += each_ground_silicate_mol;
    }
    try validateInventory(next_soil);
    try validateInventory(next_surface);
    const phosphorus_g_p = (p.broadcast_monocalcium_phosphate + p.banded_monocalcium_phosphate + p.broadcast_hydroxyapatite) * cell_area_m2;
    const next_daily_phosphorus = state.daily_phosphorus_input_g_p[cell] + phosphorus_g_p;
    if (!std.math.isFinite(next_daily_phosphorus)) return error.MineralFertilizerApplicationOverflow;
    state.soil[soil_index] = next_soil;
    state.surface[cell] = next_surface;
    state.daily_phosphorus_input_g_p[cell] = next_daily_phosphorus;
}

/// Publishes every wetted extensive store into the concentration-based
/// SOLUTE owners. Dry destinations retain their pending inventory. Validation
/// is completed for the entire runtime domain before any owner is changed.
pub const PublishTolerance = struct {
    water_volume_m3: f64,
    fraction: f64,
    relative: f64,
};

pub fn publishWetted(
    state: *State,
    soil_chemistry: *chemistry_module.State,
    surface_chemistry: *surface_chemistry_module.State,
    soil_water_volume_m3: []const f64,
    surface_water_volume_m3: []const f64,
    fractions_source: anytype,
    tolerance: PublishTolerance,
) !void {
    if (soil_chemistry.cell_count != state.soil.len or soil_water_volume_m3.len != state.soil.len or surface_chemistry.cells.len != state.cell_count or surface_water_volume_m3.len != state.cell_count) return error.MineralFertilizerChemistryDimensionMismatch;
    if (!std.math.isFinite(tolerance.water_volume_m3) or tolerance.water_volume_m3 < 0 or
        !std.math.isFinite(tolerance.fraction) or tolerance.fraction < 0 or
        !std.math.isFinite(tolerance.relative) or tolerance.relative < 0 or tolerance.relative >= 1)
        return error.InvalidMineralFertilizerChemistryInput;
    for (soil_water_volume_m3, 0..) |water_m3, index| {
        if (!std.math.isFinite(water_m3) or water_m3 < 0) return error.InvalidMineralFertilizerChemistryInput;
        const fractions = try conservativeFractionsAt(fractions_source, index, tolerance);
        if (waterIsPresent(water_m3, tolerance)) try validateSoilStateUpdate(state.soil[index], soil_chemistry, index, water_m3, fractions);
    }
    for (surface_water_volume_m3, 0..) |water_m3, cell| {
        if (!std.math.isFinite(water_m3) or water_m3 < 0) return error.InvalidMineralFertilizerChemistryInput;
        if (waterIsPresent(water_m3, tolerance)) try validateSurfaceStateUpdate(state.surface[cell], surface_chemistry.cells[cell], water_m3);
    }
    for (soil_water_volume_m3, 0..) |water_m3, index| {
        if (!waterIsPresent(water_m3, tolerance)) continue;
        const fractions = try conservativeFractionsAt(fractions_source, index, tolerance);
        publishSoil(state.soil[index], soil_chemistry, index, water_m3, fractions);
        state.soil[index] = .{};
    }
    for (surface_water_volume_m3, 0..) |water_m3, cell| {
        if (!waterIsPresent(water_m3, tolerance)) continue;
        publishSurface(state.surface[cell], &surface_chemistry.cells[cell], water_m3);
        state.surface[cell] = .{};
    }
}

fn conservativeFractionsAt(source: anytype, index: usize, tolerance: PublishTolerance) !charge_classification.ZoneFractions {
    var fractions = if (comptime @TypeOf(source) == charge_classification.ZoneFractions)
        source
    else
        try source.scienceZoneFractionsForFlatIndex(index);
    if (!validFraction(fractions.phosphate_non_band) or !validFraction(fractions.phosphate_band))
        return error.InvalidMineralFertilizerChemistryInput;
    const phosphate_fraction_sum = fractions.phosphate_non_band + fractions.phosphate_band;
    const fraction_tolerance = tolerance.fraction + tolerance.relative * @max(@abs(phosphate_fraction_sum), 1);
    if (phosphate_fraction_sum <= 0 or @abs(phosphate_fraction_sum - 1) > fraction_tolerance)
        return error.InvalidMineralFertilizerChemistryInput;
    fractions.phosphate_non_band /= phosphate_fraction_sum;
    fractions.phosphate_band /= phosphate_fraction_sum;
    return fractions;
}

fn waterIsPresent(water_m3: f64, tolerance: PublishTolerance) bool {
    return water_m3 > tolerance.water_volume_m3 + tolerance.relative * @abs(water_m3);
}

fn validateSoilStateUpdate(inventory: Inventory, chemistry: *const chemistry_module.State, index: usize, water_m3: f64, fractions: charge_classification.ZoneFractions) !void {
    const inverse_water = 1.0 / water_m3;
    // `issue-099`: mirrors `publishSoil`'s zone-water divisor and its
    // zero-volume-band amalgamation exactly. Validating the old
    // full-layer-water arithmetic here would pass values the publish no longer
    // produces.
    const band_divisor = zoneConcentrationDivisor(water_m3, fractions.phosphate_band);
    const non_band_divisor = zoneConcentrationDivisor(water_m3, fractions.phosphate_non_band);
    const broadcast_to_band = inventory.broadcast_monocalcium_phosphate_mol * fractions.phosphate_band;
    const broadcast_to_non_band = inventory.broadcast_monocalcium_phosphate_mol * fractions.phosphate_non_band;
    const prospective_band = chemistry.band_phosphate[index].monocalcium_phosphate_solid_mol_per_m3 +
        if (band_divisor) |divisor| (broadcast_to_band + inventory.banded_monocalcium_phosphate_mol) / divisor else 0;
    const prospective_non_band = chemistry.non_band_phosphate[index].monocalcium_phosphate_solid_mol_per_m3 +
        if (non_band_divisor) |non_band|
            (if (band_divisor == null) broadcast_to_non_band + broadcast_to_band + inventory.banded_monocalcium_phosphate_mol else broadcast_to_non_band) / non_band
        else
            0;
    inline for (.{
        prospective_non_band,
        prospective_band,
        chemistry.non_band_phosphate[index].hydroxyapatite_solid_mol_per_m3 +
            (if (non_band_divisor) |non_band| inventory.hydroxyapatite_mol * fractions.phosphate_non_band / non_band else 0) +
            (if (band_divisor == null) (if (non_band_divisor) |non_band| inventory.hydroxyapatite_mol * fractions.phosphate_band / non_band else 0) else 0),
        chemistry.band_phosphate[index].hydroxyapatite_solid_mol_per_m3 +
            (if (band_divisor) |divisor| inventory.hydroxyapatite_mol * fractions.phosphate_band / divisor else 0),
        chemistry.geochemistry_solids[index].calcite_solid_mol_per_m3 + inventory.calcite_mol * inverse_water,
        chemistry.geochemistry_solids[index].gypsum_solid_mol_per_m3 + inventory.gypsum_mol * inverse_water,
        chemistry.geochemistry_solids[index].aluminum_ground_silicate_mol_per_m3 + inventory.aluminum_ground_silicate_mol * inverse_water,
        chemistry.geochemistry_solids[index].iron_ground_silicate_mol_per_m3 + inventory.iron_ground_silicate_mol * inverse_water,
        chemistry.geochemistry_solids[index].calcium_ground_silicate_mol_per_m3 + inventory.calcium_ground_silicate_mol * inverse_water,
        chemistry.geochemistry_solids[index].magnesium_ground_silicate_mol_per_m3 + inventory.magnesium_ground_silicate_mol * inverse_water,
        chemistry.geochemistry_solids[index].sodium_ground_silicate_mol_per_m3 + inventory.sodium_ground_silicate_mol * inverse_water,
        chemistry.geochemistry_solids[index].potassium_ground_silicate_mol_per_m3 + inventory.potassium_ground_silicate_mol * inverse_water,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.MineralFertilizerChemistryOverflow;
}

/// `issue-099`. These are per-zone CONCENTRATIONS, and the census recovers an
/// amount from them as `concentration * water_m3 * zone_fraction`
/// (`landscape_mass_inventory_phosphorus_ions.phosphateImmobileInventory`),
/// matching the legacy convention `CNH4B = ZNH4B/(VOLW*VLNHB)` stated six times
/// at `hour1.f:3826-3858`. So depositing an amount requires dividing by the
/// ZONE water `water_m3 * zone_fraction`, not by `water_m3` alone. Dividing by
/// the full layer water made the round trip return `amount * zone_fraction`,
/// and because ecosys-ng never arms the phosphate band at all (the `IFPOB` gate
/// at `hour1.f:411-412` has no port, so `phosphate_band` is permanently zero)
/// that factor was zero and **every banded phosphate application was silently
/// annihilated** -- measured as a 5.0 g P and 8.064516129032258e-2 mol Ca loss
/// at hour 3,275, matching the booked input to eleven digits.
///
/// `zoneConcentrationDivisor` returns null for a zone with no volume, which
/// cannot hold solute at all; the caller then routes that zone's amount to the
/// surviving zone, exactly as `hour1.f:4970-4973` amalgamates a vanished band.
fn zoneConcentrationDivisor(water_m3: f64, zone_fraction: f64) ?f64 {
    if (zone_fraction <= 0) return null;
    const divisor = water_m3 * zone_fraction;
    return if (divisor > 0) divisor else null;
}

fn publishSoil(inventory: Inventory, chemistry: *chemistry_module.State, index: usize, water_m3: f64, fractions: charge_classification.ZoneFractions) void {
    const inverse_water = 1.0 / water_m3;
    // Monocalcium phosphate: split the broadcast fraction across the zones and
    // send the banded amount to the band, then convert each zone's amount with
    // that zone's own water. A zero-volume band cannot hold its amount, so it
    // is amalgamated into the non-band zone instead of being divided away.
    const band_divisor = zoneConcentrationDivisor(water_m3, fractions.phosphate_band);
    const non_band_divisor = zoneConcentrationDivisor(water_m3, fractions.phosphate_non_band);
    const broadcast_to_band = inventory.broadcast_monocalcium_phosphate_mol * fractions.phosphate_band;
    const broadcast_to_non_band = inventory.broadcast_monocalcium_phosphate_mol * fractions.phosphate_non_band;
    if (band_divisor) |divisor| {
        chemistry.band_phosphate[index].monocalcium_phosphate_solid_mol_per_m3 +=
            (broadcast_to_band + inventory.banded_monocalcium_phosphate_mol) / divisor;
        if (non_band_divisor) |non_band| chemistry.non_band_phosphate[index].monocalcium_phosphate_solid_mol_per_m3 +=
            broadcast_to_non_band / non_band;
    } else if (non_band_divisor) |non_band| {
        chemistry.non_band_phosphate[index].monocalcium_phosphate_solid_mol_per_m3 +=
            (broadcast_to_non_band + broadcast_to_band + inventory.banded_monocalcium_phosphate_mol) / non_band;
    }
    // Hydroxyapatite is zone-split by the same phosphate fractions and so has
    // the identical `issue-099` defect. Fixed together: leaving two divisor
    // conventions inside one function would be a trap for the next reader.
    if (non_band_divisor) |non_band| chemistry.non_band_phosphate[index].hydroxyapatite_solid_mol_per_m3 +=
        inventory.hydroxyapatite_mol * fractions.phosphate_non_band / non_band;
    if (band_divisor) |divisor| {
        chemistry.band_phosphate[index].hydroxyapatite_solid_mol_per_m3 +=
            inventory.hydroxyapatite_mol * fractions.phosphate_band / divisor;
    } else if (non_band_divisor) |non_band| {
        chemistry.non_band_phosphate[index].hydroxyapatite_solid_mol_per_m3 +=
            inventory.hydroxyapatite_mol * fractions.phosphate_band / non_band;
    }
    chemistry.geochemistry_solids[index].calcite_solid_mol_per_m3 += inventory.calcite_mol * inverse_water;
    chemistry.geochemistry_solids[index].gypsum_solid_mol_per_m3 += inventory.gypsum_mol * inverse_water;
    chemistry.geochemistry_solids[index].aluminum_ground_silicate_mol_per_m3 += inventory.aluminum_ground_silicate_mol * inverse_water;
    chemistry.geochemistry_solids[index].iron_ground_silicate_mol_per_m3 += inventory.iron_ground_silicate_mol * inverse_water;
    chemistry.geochemistry_solids[index].calcium_ground_silicate_mol_per_m3 += inventory.calcium_ground_silicate_mol * inverse_water;
    chemistry.geochemistry_solids[index].magnesium_ground_silicate_mol_per_m3 += inventory.magnesium_ground_silicate_mol * inverse_water;
    chemistry.geochemistry_solids[index].sodium_ground_silicate_mol_per_m3 += inventory.sodium_ground_silicate_mol * inverse_water;
    chemistry.geochemistry_solids[index].potassium_ground_silicate_mol_per_m3 += inventory.potassium_ground_silicate_mol * inverse_water;
}

fn validateSurfaceStateUpdate(inventory: Inventory, chemistry: surface_chemistry_module.Cell, water_m3: f64) !void {
    const inverse_water = 1.0 / water_m3;
    inline for (.{
        chemistry.phosphate_minerals.monocalcium_phosphate_mol_per_m3 + (inventory.broadcast_monocalcium_phosphate_mol + inventory.banded_monocalcium_phosphate_mol) * inverse_water,
        chemistry.phosphate_minerals.hydroxyapatite_mol_per_m3 + inventory.hydroxyapatite_mol * inverse_water,
        chemistry.salt_minerals.calcite_mol_per_m3 + inventory.calcite_mol * inverse_water,
        chemistry.salt_minerals.gypsum_mol_per_m3 + inventory.gypsum_mol * inverse_water,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.MineralFertilizerChemistryOverflow;
    inline for (.{ inventory.aluminum_ground_silicate_mol, inventory.iron_ground_silicate_mol, inventory.calcium_ground_silicate_mol, inventory.magnesium_ground_silicate_mol, inventory.sodium_ground_silicate_mol, inventory.potassium_ground_silicate_mol }) |value|
        if (value != 0) return error.SurfaceGroundSilicateHasNoChemistryOwner;
}

fn publishSurface(inventory: Inventory, chemistry: *surface_chemistry_module.Cell, water_m3: f64) void {
    const inverse_water = 1.0 / water_m3;
    chemistry.phosphate_minerals.monocalcium_phosphate_mol_per_m3 += (inventory.broadcast_monocalcium_phosphate_mol + inventory.banded_monocalcium_phosphate_mol) * inverse_water;
    chemistry.phosphate_minerals.hydroxyapatite_mol_per_m3 += inventory.hydroxyapatite_mol * inverse_water;
    chemistry.salt_minerals.calcite_mol_per_m3 += inventory.calcite_mol * inverse_water;
    chemistry.salt_minerals.gypsum_mol_per_m3 += inventory.gypsum_mol * inverse_water;
}

fn layerAtDepth(thickness_m: []const f64, depth_m: f64) !usize {
    var bottom_m: f64 = 0;
    for (thickness_m, 0..) |thickness, layer| {
        bottom_m += thickness;
        if (depth_m <= bottom_m) return layer;
    }
    return error.FertilizerApplicationBelowSoilProfile;
}

fn validFraction(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 1;
}

fn validateInventory(inventory: Inventory) !void {
    inline for (@typeInfo(Inventory).@"struct".fields) |field| {
        const value = @field(inventory, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.MineralFertilizerApplicationOverflow;
    }
}

test "HOUR1 mineral fertilizer conversions route cover bands gypsum and ground rock" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    var event: schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 0 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 0, .broadcast_ammonia = 0, .broadcast_urea = 0, .broadcast_nitrate = 0, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 0, .banded_nitrate = 0 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 62, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 93 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .manure_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .application_depth_m = 0,
        .band_row_width_m = 0,
        .fertilizer_formulation = 1,
        .plant_residue_type = 0,
        .manure_type = 0,
    };
    try applyEvent(&state, 0, 2, 0.25, &.{ 0.1, 0.2 }, event);
    try std.testing.expectEqual(@as(f64, 0.5), state.surface[0].broadcast_monocalcium_phosphate_mol);
    try std.testing.expectEqual(@as(f64, 1.5), state.soil[0].broadcast_monocalcium_phosphate_mol);
    try std.testing.expectEqual(@as(f64, 0.5), state.surface[0].hydroxyapatite_mol);
    try std.testing.expectEqual(@as(f64, 1.5), state.soil[0].hydroxyapatite_mol);
    event.phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 62, .broadcast_hydroxyapatite = 0 };
    event.calcium_carbonate_g_ca_per_m2 = 40;
    event.calcium_sulfate_g_ca_per_m2 = 92;
    event.fertilizer_formulation = 10;
    try applyEvent(&state, 0, 1, 0.25, &.{ 0.1, 0.2 }, event);
    try std.testing.expectEqual(@as(f64, 1), state.soil[0].banded_monocalcium_phosphate_mol);
    try std.testing.expectEqual(@as(f64, 1), state.soil[0].calcite_mol);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 6.0), state.soil[0].aluminum_ground_silicate_mol, 1e-15);
    try std.testing.expectEqual(@as(f64, 372), state.daily_phosphorus_input_g_p[0]);
}

test "wetted mineral inventory publishes conservatively while dry litter remains pending" {
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.soil[0] = .{ .broadcast_monocalcium_phosphate_mol = 2, .banded_monocalcium_phosphate_mol = 3, .hydroxyapatite_mol = 4, .calcite_mol = 5, .gypsum_mol = 6 };
    state.surface[0] = .{ .broadcast_monocalcium_phosphate_mol = 7, .hydroxyapatite_mol = 8 };
    var soil = try chemistry_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    var surface = try surface_chemistry_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    const fractions: charge_classification.ZoneFractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 0.75, .phosphate_band = 0.25 };
    const tolerance: PublishTolerance = .{ .water_volume_m3 = 1e-12, .fraction = 1e-12, .relative = 1e-12 };
    try publishWetted(&state, &soil, &surface, &.{2}, &.{0}, fractions, tolerance);
    // `issue-099` UPDATED THESE EXPECTATIONS, and that needs justifying rather
    // than assuming. The previous values (0.75, 1.75, 1.5, 0.5) encoded a
    // divisor of the FULL layer water. The census recovers an amount as
    // `concentration * water_m3 * zone_fraction`
    // (`landscape_mass_inventory_phosphorus_ions.phosphateImmobileInventory`),
    // which is the legacy convention stated six times at `hour1.f:3826-3858`
    // (`CNH4B = ZNH4B/(VOLW*VLNHB)`). Under that recovery the old publish
    // returned `amount * zone_fraction`, not `amount`. These are therefore the
    // values a mass-conserving publish must produce, and the identity is
    // asserted explicitly below rather than left implicit in the constants.
    //
    // broadcast 2, banded 3, hydroxyapatite 4; water 2; f_nb 0.75, f_b 0.25.
    try std.testing.expectEqual(@as(f64, 1.0), soil.non_band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 7.0), soil.band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 2.0), soil.non_band_phosphate[0].hydroxyapatite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 2.0), soil.band_phosphate[0].hydroxyapatite_solid_mol_per_m3);
    // The identity the constants above exist to satisfy: every mole in comes
    // back out under the census's own recovery.
    const water_m3: f64 = 2;
    try std.testing.expectApproxEqAbs(
        @as(f64, 2 + 3),
        soil.non_band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3 * water_m3 * 0.75 +
            soil.band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3 * water_m3 * 0.25,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 4),
        soil.non_band_phosphate[0].hydroxyapatite_solid_mol_per_m3 * water_m3 * 0.75 +
            soil.band_phosphate[0].hydroxyapatite_solid_mol_per_m3 * water_m3 * 0.25,
        1e-14,
    );
    try std.testing.expectEqual(@as(f64, 2.5), soil.geochemistry_solids[0].calcite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), state.soil[0].calcite_mol);
    try std.testing.expectEqual(@as(f64, 7), state.surface[0].broadcast_monocalcium_phosphate_mol);
    try publishWetted(&state, &soil, &surface, &.{2}, &.{4}, fractions, tolerance);
    try std.testing.expectEqual(@as(f64, 1.75), surface.cells[0].phosphate_minerals.monocalcium_phosphate_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 2), surface.cells[0].phosphate_minerals.hydroxyapatite_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), state.surface[0].hydroxyapatite_mol);
}

test "wetted mineral inventory projects tolerated phosphate fractions conservatively" {
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.soil[0].broadcast_monocalcium_phosphate_mol = 2;
    var soil = try chemistry_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    var surface = try surface_chemistry_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    const fractions: charge_classification.ZoneFractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 0.75, .phosphate_band = 0.2500005 };
    try publishWetted(
        &state,
        &soil,
        &surface,
        &.{2},
        &.{0},
        fractions,
        .{ .water_volume_m3 = 1e-12, .fraction = 1e-12, .relative = 1e-6 },
    );
    // `issue-099`: the previous form was `2 * (nb + b)`, i.e. a recovery with
    // NO zone fraction, which holds only under the superseded full-layer-water
    // divisor. The census recovers per zone as
    // `concentration * water_m3 * zone_fraction`, so that is the identity to
    // assert. `conservativeFractionsAt` normalises the tolerated 0.75/0.2500005
    // pair, so the normalised fractions are used here exactly as the publish saw
    // them -- which is also what makes this a test of the tolerated-fraction
    // path rather than of the nominal one.
    const fraction_sum: f64 = 0.75 + 0.2500005;
    const normalized_non_band: f64 = 0.75 / fraction_sum;
    const normalized_band: f64 = 0.2500005 / fraction_sum;
    const published_mol = 2 * (soil.non_band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3 * normalized_non_band +
        soil.band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3 * normalized_band);
    try std.testing.expectApproxEqAbs(@as(f64, 2), published_mol, 1e-14);
    try std.testing.expectEqual(@as(f64, 0), state.soil[0].broadcast_monocalcium_phosphate_mol);
}

test "issue-099: a zero-volume phosphate band amalgamates into non-band instead of annihilating the deposit" {
    // Hour 3,275 of the Ottawa deck: a banded monocalcium phosphate application
    // of 5.0 g P deposits 8.064516129032258e-2 mol, and the census recovers an
    // amount as `concentration * water_m3 * zone_fraction`. ecosys-ng never arms
    // the phosphate band (`hour1.f:411-412`'s `IFPOB` gate has no port), so
    // `phosphate_band` is zero, and the pre-fix publish divided by the full
    // layer water -- making the recovered amount `amount * 0`. The entire
    // deposit vanished, matching the booked input to eleven digits.
    const water_m3: f64 = 2.3726722163396864e-2;
    const banded_mol: f64 = 8.064516129032258e-2;
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    const fractions: charge_classification.ZoneFractions = .{
        .ammonium_non_band = 1,
        .ammonium_band = 0,
        .nitrate_non_band = 1,
        .nitrate_band = 0,
        .phosphate_non_band = 1,
        .phosphate_band = 0,
    };
    const inventory: Inventory = .{ .banded_monocalcium_phosphate_mol = banded_mol };
    publishSoil(inventory, &chemistry, 0, water_m3, fractions);

    // The band has no volume, so it must stay empty rather than receive a
    // concentration that the census would multiply by zero.
    try std.testing.expectEqual(
        @as(f64, 0),
        chemistry.band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3,
    );
    // Mass conservation, which is the identity this whole investigation reduced
    // to: recovered == concentration * water * zone_fraction == the amount in.
    const recovered = chemistry.non_band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3 *
        water_m3 * fractions.phosphate_non_band;
    try std.testing.expectApproxEqAbs(banded_mol, recovered, 1e-17);
}

test "issue-099: a phosphate band WITH volume round trips through its own zone water" {
    // The complement: with a real band the amount must land in the band zone and
    // survive `concentration * water * f_band` exactly. Guards against a fix that
    // simply routes everything to non-band.
    const water_m3: f64 = 2.3726722163396864e-2;
    const band_fraction: f64 = 1.644736842105263e-2;
    const banded_mol: f64 = 8.064516129032258e-2;
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    const fractions: charge_classification.ZoneFractions = .{
        .ammonium_non_band = 1,
        .ammonium_band = 0,
        .nitrate_non_band = 1,
        .nitrate_band = 0,
        .phosphate_non_band = 1 - band_fraction,
        .phosphate_band = band_fraction,
    };
    const inventory: Inventory = .{ .banded_monocalcium_phosphate_mol = banded_mol };
    publishSoil(inventory, &chemistry, 0, water_m3, fractions);
    try std.testing.expectEqual(
        @as(f64, 0),
        chemistry.non_band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3,
    );
    const recovered = chemistry.band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3 *
        water_m3 * band_fraction;
    try std.testing.expectApproxEqAbs(banded_mol, recovered, 1e-17);
}

const std = @import("std");
const compute = @import("../core/compute.zig");
const grid = @import("../state/grid.zig");
const config = @import("../core/config.zig");
const chemistry = @import("../soil/solute/chemistry_state.zig");
const zones = @import("../soil/solute/charge_classification.zig");
const organic = @import("../soil/organic/initialization.zig");
const respiration = @import("microbial_respiration_step.zig");
const litter_exchange = @import("microbial_mineral_exchange_step.zig");
const competition_history = @import("../soil/nutrients/competition_history.zig");

pub const TopsoilMineralInputs = struct {
    ammonium_non_band_g_n: f64,
    ammonium_band_g_n: f64,
    nitrate_non_band_g_n: f64,
    nitrate_band_g_n: f64,
    nitrite_non_band_g_n: f64,
    nitrite_band_g_n: f64,
    hydrogen_phosphate_non_band_g_p: f64,
    hydrogen_phosphate_band_g_p: f64,
    dihydrogen_phosphate_non_band_g_p: f64,
    dihydrogen_phosphate_band_g_p: f64,
};

pub const TopsoilMineralTotals = struct {
    ammonium_g_n: f64,
    nitrate_g_n: f64,
    nitrite_g_n: f64,
    hydrogen_phosphate_g_p: f64,
    dihydrogen_phosphate_g_p: f64,
};

/// Exact NITRO.F 260--269 surface-branch totals for the runtime NU topsoil.
///
/// Each non-band + band addition retains source order and is clamped only
/// after addition. Returning the complete five-field tuple prevents a late
/// invalid phosphate input from publishing earlier nitrogen totals.
pub fn calculateTopsoilMineralTotals(
    inputs: TopsoilMineralInputs,
) !TopsoilMineralTotals {
    inline for (std.meta.fields(TopsoilMineralInputs)) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteTopsoilMineralInput;
    const result: TopsoilMineralTotals = .{
        .ammonium_g_n = @max(
            0,
            inputs.ammonium_non_band_g_n + inputs.ammonium_band_g_n,
        ),
        .nitrate_g_n = @max(
            0,
            inputs.nitrate_non_band_g_n + inputs.nitrate_band_g_n,
        ),
        .nitrite_g_n = @max(
            0,
            inputs.nitrite_non_band_g_n + inputs.nitrite_band_g_n,
        ),
        .hydrogen_phosphate_g_p = @max(
            0,
            inputs.hydrogen_phosphate_non_band_g_p +
                inputs.hydrogen_phosphate_band_g_p,
        ),
        .dihydrogen_phosphate_g_p = @max(
            0,
            inputs.dihydrogen_phosphate_non_band_g_p +
                inputs.dihydrogen_phosphate_band_g_p,
        ),
    };
    inline for (std.meta.fields(TopsoilMineralTotals)) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteTopsoilMineralTotal;
    return result;
}

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    ammonium_exchange_g_n: []f64,
    nitrate_exchange_g_n: []f64,
    h2po4_exchange_g_p: []f64,
    hpo4_exchange_g_p: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceTopsoilExchangeCells;
        const count = try std.math.mul(usize, cell_count, respiration.unit_count_per_cell);
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64 and allocated > 0) {
            allocated -= 1;
            allocator.free(@field(result, field.name));
        };
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    model_grid: *const grid.GridState,
    topsoil_chemistry: *const chemistry.State,
    zone_fractions: zones.ZoneFractions,
    zone_fractions_by_layer: []const zones.ZoneFractions = &.{},
    surface_organic: *const organic.State,
    litter_exchange: *const litter_exchange.State,
    growth_temperature_response: []const f64,
    matric_plus_osmotic_potential_megapascal: []const f64,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    microbial_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    labile_biomass_fraction: f64,
    microbial_surface_area_m2_per_g_c: f64,
    nitrogen_molar_mass_g_per_mol: f64,
    parameters: litter_exchange.Parameters,
    timestep_h: f64,
    autotrophic_active_biomass_g_c: []const f64 = &.{},
    nutrient_competition: ?*const competition_history.State = null,
    nutrient_competition_attempt: ?*competition_history.Attempt = null,
    minimum_competition_fraction: f64 = 0.001,
    negligible_nitrogen_g_n: f64 = 0,
    negligible_phosphorus_g_p: f64 = 0,
    /// `solute.f:610`-style `ZEROS2` floor (issue-073 Finding B):
    /// `calculateZoneExchange`/`calculateZoneExchangeWithHistory` guarded
    /// `water <= 0` (exact-zero only); `calculateAcceptedZoneExchange` now
    /// short-circuits both paths at this floor before delegating.
    negligible_water_volume_m3: f64 = 0,
};

/// NITRO L=0 residual RINH4R/RINO3R/RIPO4R/RIP14R against NU topsoil.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| {
        const top = try context.model_grid.layerIndex(cell, 0);
        const zone_fractions = if (context.zone_fractions_by_layer.len == 0) context.zone_fractions else context.zone_fractions_by_layer[top];
        const water = context.model_grid.matrix_liquid_water_m3[top];
        const aqueous = context.topsoil_chemistry.aqueous[top];
        const phosphate_non_band = context.topsoil_chemistry.non_band_phosphate[top];
        const phosphate_band = context.topsoil_chemistry.band_phosphate[top];
        var active: [respiration.unit_count_per_cell]f64 = undefined;
        var total_active: f64 = 0;
        for (0..respiration.litter_complex_count) |complex| for (0..respiration.source_population_count) |population| {
            const local = complex * respiration.source_population_count + population;
            const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
            active[local] = context.surface_organic.microbial[microbial].carbon_g_c / context.labile_biomass_fraction;
            total_active += active[local];
        };
        if (context.autotrophic_active_biomass_g_c.len != 0) {
            const first = cell * 4;
            for (context.autotrophic_active_biomass_g_c[first .. first + 4]) |value| total_active += value;
        }
        for (0..respiration.litter_complex_count) |complex| for (0..respiration.source_population_count) |population| {
            const local = complex * respiration.source_population_count + population;
            const unit = cell * respiration.unit_count_per_cell + local;
            const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
            const nonstructural = context.surface_organic.microbial[microbial + 2];
            const ratio = (complex * organic.microbial_population_count + population) * organic.kinetic_fraction_count + 2;
            const remaining_n = nonstructural.carbon_g_c * context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio] - nonstructural.nitrogen_g_n - context.litter_exchange.ammonium_exchange_g_n[unit] - context.litter_exchange.nitrate_exchange_g_n[unit];
            const remaining_p = nonstructural.carbon_g_c * context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio] - nonstructural.phosphorus_g_p - context.litter_exchange.h2po4_exchange_g_p[unit] - context.litter_exchange.hpo4_exchange_g_p[unit];
            const share = if (total_active > 0) active[local] / total_active else 0;
            const activity = context.growth_temperature_response[cell] * @exp((if (population == 2) @as(f64, 0.05) else 0.10) * context.matric_plus_osmotic_potential_megapascal[cell]);
            const area_activity = context.microbial_surface_area_m2_per_g_c * active[local] * activity * context.timestep_h;
            const ammonium = try calculateAcceptedZoneExchange(context.*, .ammonium, top, cell, local, remaining_n, aqueous.ammonium_non_band * context.nitrogen_molar_mass_g_per_mol, aqueous.ammonium_band * context.nitrogen_molar_mass_g_per_mol, water, zone_fractions.ammonium_non_band, zone_fractions.ammonium_band, context.parameters.ammonium_minimum_concentration_g_n_per_m3, context.parameters.ammonium_half_saturation_g_n_per_m3, context.parameters.ammonium_maximum_uptake_g_n_per_m2_h * area_activity, share, false);
            const remaining_nitrate = @max(0, remaining_n - ammonium.exchange);
            const nitrate = try calculateAcceptedZoneExchange(context.*, .nitrate, top, cell, local, remaining_nitrate, aqueous.nitrate_non_band * context.nitrogen_molar_mass_g_per_mol, aqueous.nitrate_band * context.nitrogen_molar_mass_g_per_mol, water, zone_fractions.nitrate_non_band, zone_fractions.nitrate_band, context.parameters.nitrate_minimum_concentration_g_n_per_m3, context.parameters.nitrate_half_saturation_g_n_per_m3, context.parameters.nitrate_maximum_uptake_g_n_per_m2_h * area_activity, share, true);
            const h2po4 = try calculateAcceptedZoneExchange(context.*, .h2po4, top, cell, local, remaining_p, phosphate_non_band.dissolved_h2po4_mol_p_per_m3 * context.parameters.phosphorus_molar_mass_g_per_mol, phosphate_band.dissolved_h2po4_mol_p_per_m3 * context.parameters.phosphorus_molar_mass_g_per_mol, water, zone_fractions.phosphate_non_band, zone_fractions.phosphate_band, context.parameters.phosphate_minimum_concentration_g_p_per_m3, context.parameters.phosphate_half_saturation_g_p_per_m3, context.parameters.phosphate_maximum_uptake_g_p_per_m2_h * area_activity, share, false);
            const remaining_hpo4 = @max(0, remaining_p - h2po4.exchange);
            const hpo4 = try calculateAcceptedZoneExchange(context.*, .hpo4, top, cell, local, remaining_hpo4, phosphate_non_band.dissolved_hpo4_mol_p_per_m3 * context.parameters.phosphorus_molar_mass_g_per_mol, phosphate_band.dissolved_hpo4_mol_p_per_m3 * context.parameters.phosphorus_molar_mass_g_per_mol, water, zone_fractions.phosphate_non_band, zone_fractions.phosphate_band, 0.25 * context.parameters.phosphate_minimum_concentration_g_p_per_m3, context.parameters.phosphate_half_saturation_g_p_per_m3, 0.25 * context.parameters.phosphate_maximum_uptake_g_p_per_m2_h * area_activity, share, false);
            context.result.ammonium_exchange_g_n[unit] = ammonium.exchange;
            context.result.nitrate_exchange_g_n[unit] = nitrate.exchange;
            context.result.h2po4_exchange_g_p[unit] = h2po4.exchange;
            context.result.hpo4_exchange_g_p[unit] = hpo4.exchange;
            if (context.nutrient_competition_attempt) |attempt| try attempt.recordTopsoilResidual(top, cell, local, .{ ammonium.capacity, nitrate.capacity, h2po4.capacity, hpo4.capacity });
        };
    }
}

pub fn calculateZoneExchange(demand: f64, non_band_concentration: f64, band_concentration: f64, water: f64, non_band_fraction: f64, band_fraction: f64, minimum: f64, half: f64, capacity: f64, share: f64, source_uses_maximum: bool) f64 {
    if (demand <= 0 or water <= 0) return 0;
    const non_band_available = @max(0, non_band_concentration - minimum);
    const band_available = @max(0, band_concentration - minimum);
    const response = non_band_fraction * non_band_available / (non_band_available + half) + band_fraction * band_available / (band_available + half);
    const unlimited = (if (source_uses_maximum) @max(demand, capacity) else @min(demand, capacity)) * response;
    const amount = water * (non_band_fraction * non_band_concentration + band_fraction * band_concentration);
    return @max(0, @min(unlimited, share * @max(0, amount - minimum * water)));
}

pub const ZoneExchangeResult = struct { exchange: f64 = 0, capacity: f64 = 0 };

fn calculateAcceptedZoneExchange(context: ApplyContext, pool: competition_history.SurfacePool, layer: usize, cell: usize, competitor: usize, demand: f64, non_band_concentration: f64, band_concentration: f64, water: f64, non_band_fraction: f64, band_fraction: f64, minimum: f64, half: f64, maximum_capacity: f64, fallback: f64, source_uses_maximum: bool) !ZoneExchangeResult {
    // issue-073 Finding B: widen the shared `water <= 0` exact-zero guard
    // both `calculateZoneExchange` and `calculateZoneExchangeWithHistory`
    // apply internally to the established `negligible_water_volume_m3`
    // floor, at the single call point both paths share.
    if (water <= context.negligible_water_volume_m3) return .{};
    if (context.nutrient_competition) |accepted| {
        const soil_pool: competition_history.SoilPool = switch (pool) {
            .ammonium => .ammonium_non_band,
            .nitrate => .nitrate_non_band,
            .h2po4 => .h2po4_non_band,
            .hpo4 => .hpo4_non_band,
        };
        const total = try accepted.soilTotal(soil_pool, layer);
        const previous = try accepted.topsoilResidualCapacity(pool, cell, competitor);
        const negligible = switch (pool) {
            .ammonium, .nitrate => context.negligible_nitrogen_g_n,
            .h2po4, .hpo4 => context.negligible_phosphorus_g_p,
        };
        return calculateZoneExchangeWithHistory(demand, non_band_concentration, band_concentration, water, non_band_fraction, band_fraction, minimum, half, maximum_capacity, total, previous, fallback, context.minimum_competition_fraction, negligible, source_uses_maximum);
    }
    return .{ .exchange = calculateZoneExchange(demand, non_band_concentration, band_concentration, water, non_band_fraction, band_fraction, minimum, half, maximum_capacity, fallback, source_uses_maximum) };
}

pub fn calculateZoneExchangeWithHistory(demand: f64, non_band_concentration: f64, band_concentration: f64, water: f64, non_band_fraction: f64, band_fraction: f64, minimum: f64, half: f64, maximum_capacity: f64, previous_total: f64, previous_capacity: f64, fallback: f64, minimum_competition_fraction: f64, negligible: f64, source_uses_maximum: bool) ZoneExchangeResult {
    if (demand <= 0 or water <= 0) return .{};
    const non_band_available = @max(0, non_band_concentration - minimum);
    const band_available = @max(0, band_concentration - minimum);
    const limited_demand = if (source_uses_maximum) @max(demand, maximum_capacity) else @min(demand, maximum_capacity);
    const capacity = limited_demand * (non_band_fraction * non_band_available / (non_band_available + half) + band_fraction * band_available / (band_available + half));
    const share = @max(minimum_competition_fraction, if (previous_total > negligible) previous_capacity / previous_total else fallback);
    const amount = water * (non_band_concentration * non_band_fraction + band_concentration * band_fraction);
    return .{ .exchange = @max(0, @min(capacity, share * @max(0, amount - minimum * water))), .capacity = capacity };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const ratios = organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    if (range.first > range.end or range.end > context.result.cell_count or context.model_grid.cell_count != context.result.cell_count or context.topsoil_chemistry.cell_count != context.model_grid.layer_count or context.surface_organic.layer_count != context.result.cell_count or context.litter_exchange.cell_count != context.result.cell_count or context.growth_temperature_response.len != context.result.cell_count or context.matric_plus_osmotic_potential_megapascal.len != context.result.cell_count or context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != ratios or context.microbial_phosphorus_to_carbon_g_p_per_g_c.len != ratios or (context.autotrophic_active_biomass_g_c.len != 0 and context.autotrophic_active_biomass_g_c.len != context.result.cell_count * 4) or (context.zone_fractions_by_layer.len != 0 and context.zone_fractions_by_layer.len != context.model_grid.layer_count)) return error.SurfaceTopsoilExchangeDimensionMismatch;
    for (context.autotrophic_active_biomass_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceTopsoilExchangeParameter;
    const fractions_to_validate = if (context.zone_fractions_by_layer.len == 0) @as([]const zones.ZoneFractions, &.{context.zone_fractions}) else context.zone_fractions_by_layer;
    for (fractions_to_validate) |fractions| inline for (@typeInfo(zones.ZoneFractions).@"struct".fields) |field| if (!std.math.isFinite(@field(fractions, field.name)) or @field(fractions, field.name) < 0 or @field(fractions, field.name) > 1) return error.InvalidSurfaceTopsoilExchangeParameter;
    if (!std.math.isFinite(context.minimum_competition_fraction) or context.minimum_competition_fraction < 0 or !std.math.isFinite(context.negligible_nitrogen_g_n) or context.negligible_nitrogen_g_n < 0 or !std.math.isFinite(context.negligible_phosphorus_g_p) or context.negligible_phosphorus_g_p < 0 or !std.math.isFinite(context.negligible_water_volume_m3) or context.negligible_water_volume_m3 < 0) return error.InvalidSurfaceTopsoilExchangeParameter;
    if ((context.nutrient_competition == null) != (context.nutrient_competition_attempt == null)) return error.IncompleteSurfaceTopsoilNutrientCompetitionBinding;
}

test "residual litter deficit draws from runtime topsoil zones" {
    const runtime_config = try config.SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid.GridState.init(std.testing.allocator, runtime_config);
    defer model_grid.deinit();
    model_grid.matrix_liquid_water_m3[0] = 1;
    var topsoil = try chemistry.State.init(std.testing.allocator, 1);
    defer topsoil.deinit();
    topsoil.aqueous[0].ammonium_non_band = 1;
    topsoil.aqueous[0].nitrate_non_band = 1;
    topsoil.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 1;
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    surface.microbial[0].carbon_g_c = 0.55;
    surface.microbial[2].carbon_g_c = 1;
    var litter = try litter_exchange.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const n = [_]f64{0.1} ** 105;
    const p = [_]f64{0.01} ** 105;
    var context: ApplyContext = .{ .result = &state, .model_grid = &model_grid, .topsoil_chemistry = &topsoil, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .surface_organic = &surface, .litter_exchange = &litter, .growth_temperature_response = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &n, .microbial_phosphorus_to_carbon_g_p_per_g_c = &p, .labile_biomass_fraction = 0.55, .microbial_surface_area_m2_per_g_c = 3, .nitrogen_molar_mass_g_per_mol = 14, .parameters = .{ .ammonium_maximum_uptake_g_n_per_m2_h = 0.014, .ammonium_minimum_concentration_g_n_per_m3 = 0.0125, .ammonium_half_saturation_g_n_per_m3 = 0.4, .nitrate_maximum_uptake_g_n_per_m2_h = 0.014, .nitrate_minimum_concentration_g_n_per_m3 = 0.03, .nitrate_half_saturation_g_n_per_m3 = 0.35, .phosphate_maximum_uptake_g_p_per_m2_h = 0.003, .phosphate_minimum_concentration_g_p_per_m3 = 0.009, .phosphate_half_saturation_g_p_per_m3 = 0.18, .phosphorus_molar_mass_g_per_mol = 31 }, .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.ammonium_exchange_g_n[0] > 0);
    try std.testing.expect(state.h2po4_exchange_g_p[0] > 0);
}

test "NITRO 260-269 topsoil mineral totals preserve addition and clamp order" {
    const totals = try calculateTopsoilMineralTotals(.{
        .ammonium_non_band_g_n = -2,
        .ammonium_band_g_n = 3,
        .nitrate_non_band_g_n = -4,
        .nitrate_band_g_n = 1,
        .nitrite_non_band_g_n = 0.25,
        .nitrite_band_g_n = 0.75,
        .hydrogen_phosphate_non_band_g_p = 2,
        .hydrogen_phosphate_band_g_p = -0.5,
        .dihydrogen_phosphate_non_band_g_p = -1,
        .dihydrogen_phosphate_band_g_p = 0.25,
    });
    try std.testing.expectEqual(@as(f64, 1), totals.ammonium_g_n);
    try std.testing.expectEqual(@as(f64, 0), totals.nitrate_g_n);
    try std.testing.expectEqual(@as(f64, 1), totals.nitrite_g_n);
    try std.testing.expectEqual(@as(f64, 1.5), totals.hydrogen_phosphate_g_p);
    try std.testing.expectEqual(@as(f64, 0), totals.dihydrogen_phosphate_g_p);
}

test "issue-073 Finding B: a near-zero-but-nonzero topsoil water is skipped instead of feeding an unfloored exchange" {
    // OLD: `calculateZoneExchange`/`calculateZoneExchangeWithHistory` only
    // guarded `water <= 0` (exact-zero only). NEW:
    // `calculateAcceptedZoneExchange` now short-circuits both paths at the
    // shared `negligible_water_volume_m3` floor before either can run on a
    // tiny-but-nonzero carrier.
    const runtime_config = try config.SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid.GridState.init(std.testing.allocator, runtime_config);
    defer model_grid.deinit();
    const negligible_water_volume_m3: f64 = 1e-6;
    model_grid.matrix_liquid_water_m3[0] = negligible_water_volume_m3 / 2; // tiny-but-nonzero, below the floor
    var topsoil = try chemistry.State.init(std.testing.allocator, 1);
    defer topsoil.deinit();
    topsoil.aqueous[0].ammonium_non_band = 1;
    topsoil.aqueous[0].nitrate_non_band = 1;
    topsoil.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 1;
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    surface.microbial[0].carbon_g_c = 0.55;
    surface.microbial[2].carbon_g_c = 1;
    var litter = try litter_exchange.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const n = [_]f64{0.1} ** 105;
    const p = [_]f64{0.01} ** 105;
    var context: ApplyContext = .{ .result = &state, .model_grid = &model_grid, .topsoil_chemistry = &topsoil, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .surface_organic = &surface, .litter_exchange = &litter, .growth_temperature_response = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &n, .microbial_phosphorus_to_carbon_g_p_per_g_c = &p, .labile_biomass_fraction = 0.55, .microbial_surface_area_m2_per_g_c = 3, .nitrogen_molar_mass_g_per_mol = 14, .parameters = .{ .ammonium_maximum_uptake_g_n_per_m2_h = 0.014, .ammonium_minimum_concentration_g_n_per_m3 = 0.0125, .ammonium_half_saturation_g_n_per_m3 = 0.4, .nitrate_maximum_uptake_g_n_per_m2_h = 0.014, .nitrate_minimum_concentration_g_n_per_m3 = 0.03, .nitrate_half_saturation_g_n_per_m3 = 0.35, .phosphate_maximum_uptake_g_p_per_m2_h = 0.003, .phosphate_minimum_concentration_g_p_per_m3 = 0.009, .phosphate_half_saturation_g_p_per_m3 = 0.18, .phosphorus_molar_mass_g_per_mol = 31 }, .timestep_h = 1, .negligible_water_volume_m3 = negligible_water_volume_m3 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 0), state.ammonium_exchange_g_n[0]);
    try std.testing.expectEqual(@as(f64, 0), state.h2po4_exchange_g_p[0]);
}

test "NITRO topsoil mineral totals reject a non-finite late phosphate input" {
    var inputs: TopsoilMineralInputs = std.mem.zeroes(TopsoilMineralInputs);
    inputs.dihydrogen_phosphate_band_g_p = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteTopsoilMineralInput,
        calculateTopsoilMineralTotals(inputs),
    );
}

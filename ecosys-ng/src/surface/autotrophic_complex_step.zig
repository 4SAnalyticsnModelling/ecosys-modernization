const std = @import("std");
const compute = @import("../core/compute.zig");
const organic = @import("../soil/organic/initialization.zig");
const chemistry = @import("litter_chemistry.zig");
const denitrification = @import("denitrification_step.zig");
const gas = @import("../soil/gas/transport.zig");
const microbial_environment = @import("microbial_environment_step.zig");
const surface_respiration = @import("microbial_respiration_step.zig");
const respiration_activity = @import("../soil/microbial/respiration_activity.zig");
const metabolism = @import("../soil/microbial/metabolism.zig");
const methanogenesis = @import("../soil/microbial/methanogenesis.zig");
const methane_step = @import("../soil/gas/methane_step.zig");
const nitrogen_parameters = @import("../soil/nutrients/nitrogen_parameters.zig");
const competition_history = @import("../soil/nutrients/competition_history.zig");
const surface_turnover = @import("microbial_turnover_step.zig");
const surface_mineral_exchange = @import("microbial_mineral_exchange_step.zig");
const topsoil_mineral_exchange = @import("topsoil_mineral_exchange_step.zig");
const soil_chemistry = @import("../soil/solute/chemistry_state.zig");
const zones = @import("../soil/solute/charge_classification.zig");

/// Source NITRO populations N=1,2,3,5 in the autotrophic K=5 complex.
pub const active_population_count: usize = 4;
pub const source_population_by_active = [active_population_count]usize{ 0, 1, 2, 4 };

pub const Role = enum { ammonia_oxidizer, nitrite_oxidizer, methanotroph, hydrogenotroph };

pub fn roleForActive(active: usize) Role {
    return switch (active) {
        0 => .ammonia_oxidizer,
        1 => .nitrite_oxidizer,
        2 => .methanotroph,
        3 => .hydrogenotroph,
        else => unreachable,
    };
}

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    active_biomass_g_c: []f64,
    nutrient_activity_fraction: []f64,
    potential_primary_reaction: []f64,
    potential_respiration_g_c: []f64,
    potential_carbon_uptake_g_c: []f64,
    potential_nonstructural_carbon_gain_g_c: []f64,
    potential_oxygen_demand_g_o: []f64,
    previous_oxygen_demand_g_o: []f64,
    labile_maintenance_respiration_g_c: []f64,
    resistant_maintenance_respiration_g_c: []f64,
    maintenance_respiration_g_c: []f64,
    actual_primary_reaction: []f64,
    actual_respiration_g_c: []f64,
    actual_carbon_uptake_g_c: []f64,
    actual_nonstructural_carbon_gain_g_c: []f64,
    mineral_exchange_share: []f64,
    surface_ammonium_exchange_g_n: []f64,
    surface_nitrate_exchange_g_n: []f64,
    surface_h2po4_exchange_g_p: []f64,
    surface_hpo4_exchange_g_p: []f64,
    topsoil_ammonium_exchange_g_n: []f64,
    topsoil_nitrate_exchange_g_n: []f64,
    topsoil_h2po4_exchange_g_p: []f64,
    topsoil_hpo4_exchange_g_p: []f64,

    /// Releases the successfully allocated `[]f64` prefix from `init` in
    /// field order without duplicating the unrolled reflected loop at every
    /// fallible allocation edge.
    noinline fn deinitAllocatedPrefix(self: *State, allocated_count: usize) void {
        var remaining = allocated_count;
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                if (remaining == 0) return;
                self.allocator.free(@field(self, field.name));
                remaining -= 1;
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceAutotrophicCells;
        const count = try std.math.mul(usize, cell_count, active_population_count);
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated);
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

test "surface autotrophic state releases every partial allocation prefix" {
    const allocation_count = comptime count: {
        var count: usize = 0;
        for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) count += 1;
        }
        break :count count;
    };

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            State.init(failing.allocator(), 2),
        );
    }
}

pub const MineralExchangeTotals = struct { immobilization_g_n: f64 = 0, immobilization_g_p: f64 = 0 };

/// Signed hourly K=5 exchange published to daily mineralization diagnostics.
/// Positive is immobilization into OMC3; negative is mineralization back to
/// litter mineral pools, matching NITRO TRINH4/TRIPO4 sign convention.
pub fn mineralExchangeTotalsForCell(state: *const State, cell: usize) !MineralExchangeTotals {
    if (cell >= state.cell_count) return error.SurfaceAutotrophicCellOutOfBounds;
    var result: MineralExchangeTotals = .{};
    const first = cell * active_population_count;
    for (first..first + active_population_count) |unit| {
        result.immobilization_g_n += state.surface_ammonium_exchange_g_n[unit] + state.surface_nitrate_exchange_g_n[unit] + state.topsoil_ammonium_exchange_g_n[unit] + state.topsoil_nitrate_exchange_g_n[unit];
        result.immobilization_g_p += state.surface_h2po4_exchange_g_p[unit] + state.surface_hpo4_exchange_g_p[unit] + state.topsoil_h2po4_exchange_g_p[unit] + state.topsoil_hpo4_exchange_g_p[unit];
    }
    if (!std.math.isFinite(result.immobilization_g_n) or !std.math.isFinite(result.immobilization_g_p)) return error.InvalidSurfaceAutotrophicState;
    return result;
}

pub const PrepareContext = struct {
    result: *State,
    surface_organic: *const organic.State,
    litter_chemistry: *const chemistry.State,
    litter_denitrification: *const denitrification.State,
    litter_gas: *const gas.State,
    environment: *const microbial_environment.State,
    litter_water_m3: []const f64,
    litter_temperature_k: []const f64,
    matric_plus_osmotic_potential_megapascal: []const f64,
    heterotrophic_respiration: *const surface_respiration.State,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    microbial_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    parameters: nitrogen_parameters.Parameters,
    nitrogen_molar_mass_g_per_mol: f64,
    timestep_h: f64,
    nutrient_competition: ?*const competition_history.State = null,
    nutrient_competition_attempt: ?*competition_history.Attempt = null,
    minimum_competition_fraction: f64 = 0.001,
    negligible_nitrogen_g_n: f64 = 0,
};

/// Prepares K=5 reaction and oxygen demand without mutating any scientific
/// owner. The four records are appended to the 21 heterotrophic records by
/// `microbial_oxygen_driver`, so all 25 populations compete in one O2 solve.
pub fn prepareTile(context: *PrepareContext, range: compute.CellRange) !void {
    try validatePrepare(context.*, range);
    for (range.first..range.end) |cell| try prepareCell(context, cell);
}

fn prepareCell(context: *PrepareContext, cell: usize) !void {
    const water = context.litter_water_m3[cell];
    const p = context.parameters;
    const methane = p.methane orelse return error.MissingSurfaceMethaneParameters;
    const co2_index = try gas.massIndex(cell, .carbon_dioxide, context.litter_gas.cell_count);
    const methane_index = try gas.massIndex(cell, .methane, context.litter_gas.cell_count);
    const hydrogen_index = try gas.massIndex(cell, .hydrogen, context.litter_gas.cell_count);
    const co2_concentration = if (water > 0) context.litter_gas.dissolved_mass_g[co2_index] / water else 0;
    const co2_activity = co2_concentration / (co2_concentration + p.nitrifier_environment.aqueous_co2_half_saturation_g_c_per_m3);
    const water_response = @exp(p.nitrifier_environment.water_potential_sensitivity_per_megapascal * context.matric_plus_osmotic_potential_megapascal[cell]);
    const temperature_water = context.environment.growth_temperature_response[cell] * water_response;
    const ph = context.litter_chemistry.ph[cell];
    if (!std.math.isFinite(ph)) return error.InvalidSurfaceLitterPh;
    const ph_response = try metabolism.maintenancePhResponse(
        ph,
        p.heterotrophic_respiration.acidity_half_response_mol_per_m3,
    );
    var fermentation_hydrogen_g_h: f64 = 0;
    // NITRO.F 351--410 and 648--660: K=5 uses the total colonized surface
    // structural litter (TOSA), not a fictitious K=5 substrate pool, for the
    // low-biomass maintenance/decomposition response.
    var total_colonized_structural_g_c: f64 = 0;
    for (0..surface_respiration.litter_complex_count) |complex| {
        for (0..organic.structural_fraction_count) |fraction|
            total_colonized_structural_g_c += context.surface_organic.colonized_structural_carbon_g_c[(cell * organic.substrate_count + complex) * organic.structural_fraction_count + fraction];
    }
    const heterotroph_base = cell * surface_respiration.unit_count_per_cell;
    for (0..surface_respiration.unit_count_per_cell) |unit| {
        const population = unit % surface_respiration.source_population_count;
        if (respiration_activity.sourceMetabolism(population) == .fermenting_heterotroph)
            fermentation_hydrogen_g_h += 0.111 * context.heterotrophic_respiration.substrate_limited_respiration_g_c[heterotroph_base + unit];
    }

    // FOMA at L=0 is the common active-biomass fallback denominator for the
    // complete K=1..3,N=1..7 and K=5,N=1,2,3,5 source-order population set.
    var total_active_biomass_g_c: f64 = 0;
    for (0..surface_respiration.litter_complex_count) |complex| for (0..surface_respiration.source_population_count) |population| {
        const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
        total_active_biomass_g_c += context.surface_organic.microbial[microbial].carbon_g_c / p.nitrifier_environment.labile_biomass_fraction;
    };
    for (source_population_by_active) |source_population| {
        const microbial = microbialBase(cell, source_population);
        total_active_biomass_g_c += context.surface_organic.microbial[microbial].carbon_g_c / p.nitrifier_environment.labile_biomass_fraction;
    }

    for (0..active_population_count) |active| {
        const index = cell * active_population_count + active;
        const source_population = source_population_by_active[active];
        const microbial = microbialBase(cell, source_population);
        const labile = context.surface_organic.microbial[microbial];
        const resistant = context.surface_organic.microbial[microbial + 1];
        const ratio_base = (organic.autotrophic_substrate_index * organic.microbial_population_count + source_population) * organic.kinetic_fraction_count;
        const target = Ratios{
            .n = context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_base],
            .p = context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio_base],
        };
        const actual_n = if (labile.carbon_g_c > 0) labile.nitrogen_g_n / labile.carbon_g_c else target.n;
        const actual_p = if (labile.carbon_g_c > 0) labile.phosphorus_g_p / labile.carbon_g_c else target.p;
        const n_factor = @min(1, @max(0.1, std.math.pow(f64, actual_n / target.n, 0.25)));
        const p_factor = @min(1, @max(0.1, std.math.pow(f64, actual_p / target.p, 0.25)));
        const nutrient = @min(n_factor, p_factor);
        const active_biomass = labile.carbon_g_c / p.nitrifier_environment.labile_biomass_fraction;
        const active_resistant_carbon = @max(0, @min(active_biomass * (1 - p.nitrifier_environment.labile_biomass_fraction), resistant.carbon_g_c));
        const active_resistant_n = if (resistant.carbon_g_c > 0) resistant.nitrogen_g_n * active_resistant_carbon / resistant.carbon_g_c else 0;
        const microbial_density = if (total_colonized_structural_g_c > 0) active_biomass / total_colonized_structural_g_c else 0;
        const maintenance_density_response = if (total_colonized_structural_g_c > 0) microbial_density / (microbial_density + p.heterotrophic_respiration.maintenance_density_half_saturation_g_c_per_g_c) else 1;
        const maintenance_value = try metabolism.maintenance(.{
            .labile_nitrogen_g_n = labile.nitrogen_g_n,
            .resistant_nitrogen_g_n = active_resistant_n,
            .specific_maintenance_g_c_per_g_n_h = p.heterotrophic_respiration.specific_maintenance_respiration_g_c_per_g_n_per_h,
            .temperature_response = context.environment.maintenance_temperature_response[cell],
            .ph_response = ph_response,
            .low_carbon_response = maintenance_density_response,
            .timestep_h = context.timestep_h,
            .oxygen_limited_respiration_g_c = 0,
        });
        const maintenance = maintenance_value.total_maintenance_g_c;

        var primary: f64 = 0;
        var respiration_g_c: f64 = 0;
        var uptake_g_c: f64 = 0;
        var gain_g_c: f64 = 0;
        var oxygen_g_o: f64 = 0;
        switch (roleForActive(active)) {
            .ammonia_oxidizer => {
                const concentration = context.litter_chemistry.cells[cell].ammonium_mol_per_m3 * context.nitrogen_molar_mass_g_per_mol;
                const available = concentration * water;
                const unlimited = p.nitrification.ammonia_oxidation_rate_g_n_per_g_c_h * temperature_water * nutrient * co2_activity * active_biomass * context.timestep_h;
                const capacity = unlimited * concentration / (concentration + p.nitrification.ammonium_half_saturation_g_n_per_m3);
                if (context.nutrient_competition) |accepted| {
                    const previous_total = try accepted.surfaceTotal(.ammonium, cell);
                    const previous_capacity = try accepted.surfaceAmmoniaOxidationCapacity(cell);
                    const fallback = if (total_active_biomass_g_c > 0) active_biomass / total_active_biomass_g_c else 0;
                    const share = @max(context.minimum_competition_fraction, if (previous_total > context.negligible_nitrogen_g_n) previous_capacity / previous_total else fallback);
                    primary = @min(available * share, capacity);
                    try context.nutrient_competition_attempt.?.recordSurfaceAmmoniaOxidation(cell, capacity);
                } else {
                    primary = @min(available, capacity);
                }
                respiration_g_c = primary * p.nitrification.ammonia_oxidizer_carbon_efficiency_g_c_per_g_n * p.nitrification.growth_respiration_fraction;
                uptake_g_c = grossAutotrophicUptake(respiration_g_c, maintenance, p.nitrification.growth_respiration_fraction);
                gain_g_c = uptake_g_c - respiration_g_c;
                oxygen_g_o = p.nitrification.oxygen_per_ammonium_n_g_o_per_g_n * primary + p.nitrification.oxygen_per_respired_carbon_g_o_per_g_c * respiration_g_c;
            },
            .nitrite_oxidizer => {
                const available = context.litter_denitrification.nitrite_g_n[cell];
                const concentration = if (water > 0) available / water else 0;
                const unlimited = p.nitrification.nitrite_oxidation_rate_g_n_per_g_c_h * temperature_water * nutrient * co2_activity * active_biomass * context.timestep_h;
                primary = @min(available, unlimited * concentration / (concentration + p.nitrification.nitrite_half_saturation_g_n_per_m3));
                respiration_g_c = primary * p.nitrification.nitrite_oxidizer_carbon_efficiency_g_c_per_g_n * p.nitrification.growth_respiration_fraction;
                uptake_g_c = grossAutotrophicUptake(respiration_g_c, maintenance, p.nitrification.growth_respiration_fraction);
                gain_g_c = uptake_g_c - respiration_g_c;
                oxygen_g_o = p.nitrification.oxygen_per_nitrite_n_g_o_per_g_n * primary + p.nitrification.oxygen_per_respired_carbon_g_o_per_g_c * respiration_g_c;
            },
            .methanotroph => {
                const aqueous = context.litter_gas.dissolved_mass_g[methane_index];
                const available = aqueous + context.litter_gas.gaseous_mass_g[methane_index];
                const concentration = if (water > 0) aqueous / water else 0;
                const kinetic = methane.methanotroph_specific_oxidation_per_h * temperature_water * nutrient * active_biomass * context.timestep_h * concentration / (concentration + methane.methane_half_saturation_g_c_per_m3);
                primary = @min(available, kinetic);
                respiration_g_c = primary * methane.methanotroph_biomass_conversion_efficiency_g_c_per_g_c * methane.methanotroph_growth_respiration_g_c_per_g_c;
                uptake_g_c = grossAutotrophicUptake(respiration_g_c, maintenance, methane.methanotroph_growth_respiration_g_c_per_g_c);
                if (primary + uptake_g_c > available and primary + uptake_g_c > 0) {
                    const scale = available / (primary + uptake_g_c);
                    primary *= scale;
                    respiration_g_c *= scale;
                    uptake_g_c *= scale;
                }
                gain_g_c = uptake_g_c - respiration_g_c;
                oxygen_g_o = 5.333 * primary + 2.667 * respiration_g_c;
            },
            .hydrogenotroph => {
                const aqueous_hydrogen = context.litter_gas.dissolved_mass_g[hydrogen_index];
                const concentration = if (water > 0) aqueous_hydrogen / water else 0;
                const feedback = try methane_step.hydrogenFeedbackEnergy_kj_per_mol(context.litter_temperature_k[cell], concentration, methane.hydrogen_product_inhibition_g_h_per_m3, 8.3143e-3, std.math.floatMin(f64), 4);
                const value = try methanogenesis.hydrogenotrophic(.{
                    .aqueous_hydrogen_concentration_g_h_per_m3 = concentration,
                    .aqueous_hydrogen_g_h = aqueous_hydrogen,
                    .fermentation_hydrogen_production_g_h = fermentation_hydrogen_g_h,
                    .temperature_water_response = temperature_water,
                    .nutrient_limitation_fraction = nutrient,
                    .aqueous_co2_limitation_fraction = co2_activity,
                    .active_biomass_g_c = active_biomass,
                    .timestep_h = context.timestep_h,
                    .hydrogen_feedback_energy_kj_per_mol = feedback,
                }, .{
                    .hydrogen_half_saturation_g_h_per_m3 = methane.hydrogen_half_saturation_g_h_per_m3,
                    .specific_co2_reduction_g_c_per_g_c_h = methane.hydrogenotrophic_specific_co2_reduction_g_c_per_g_c_h,
                    .reference_energy_yield_kj_per_g_c = methane.hydrogenotrophic_reference_energy_yield_kj_per_g_c,
                    .growth_energy_requirement_kj_per_g_c = methane.methanogen_growth_energy_requirement_kj_per_g_c,
                    .minimum_growth_respiration_fraction = methane.minimum_growth_respiration_fraction,
                    .hydrogen_supply_conversion_g_c_per_g_h = methane.hydrogen_supply_conversion_g_c_per_g_h,
                    .fermentation_hydrogen_to_pool_fraction = methane.fermentation_hydrogen_to_pool_fraction,
                });
                respiration_g_c = value.co2_reduction_g_c;
                uptake_g_c = grossAutotrophicUptake(respiration_g_c, maintenance, value.growth_respiration_fraction);
                if (uptake_g_c > context.litter_gas.dissolved_mass_g[co2_index] and uptake_g_c > 0) {
                    const scale = context.litter_gas.dissolved_mass_g[co2_index] / uptake_g_c;
                    respiration_g_c *= scale;
                    uptake_g_c *= scale;
                }
                primary = respiration_g_c / methane.hydrogen_supply_conversion_g_c_per_g_h;
                gain_g_c = uptake_g_c - respiration_g_c;
            },
        }
        inline for (.{ active_biomass, nutrient, primary, respiration_g_c, uptake_g_c, gain_g_c, oxygen_g_o, maintenance }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceAutotrophicFlux;
        context.result.active_biomass_g_c[index] = active_biomass;
        context.result.nutrient_activity_fraction[index] = nutrient;
        context.result.potential_primary_reaction[index] = primary;
        context.result.potential_respiration_g_c[index] = respiration_g_c;
        context.result.potential_carbon_uptake_g_c[index] = uptake_g_c;
        context.result.potential_nonstructural_carbon_gain_g_c[index] = gain_g_c;
        context.result.potential_oxygen_demand_g_o[index] = oxygen_g_o;
        context.result.labile_maintenance_respiration_g_c[index] = maintenance_value.labile_respiration_g_c;
        context.result.resistant_maintenance_respiration_g_c[index] = maintenance_value.resistant_respiration_g_c;
        context.result.maintenance_respiration_g_c[index] = maintenance;
    }
    // NITRO.F FNH4X/FNO3X/FPO4X/FP14X allocate every mineral pool across
    // all active N,K records. Preserve the common 21+4 denominator here,
    // before any surface state update can change the hour-start biomass.
    const first = cell * active_population_count;
    for (0..active_population_count) |active| context.result.mineral_exchange_share[first + active] = if (total_active_biomass_g_c > 0) context.result.active_biomass_g_c[first + active] / total_active_biomass_g_c else 0;
}

pub const ApplyContext = struct {
    state: *State,
    surface_organic: *organic.State,
    litter_chemistry: *chemistry.State,
    litter_denitrification: *denitrification.State,
    litter_gas: *gas.State,
    litter_water_m3: []const f64,
    topsoil_chemistry: *soil_chemistry.State,
    topsoil_water_m3: []const f64,
    zone_fractions: zones.ZoneFractions,
    zone_fractions_by_layer: []const zones.ZoneFractions = &.{},
    oxygen_satisfaction_fraction: []const f64,
    oxygen_unit_count_per_cell: usize,
    first_autotrophic_oxygen_unit: usize,
    topsoil_organic: *organic.State,
    soil_layer_capacity: usize,
    topsoil_humus_partition: []const [2]f64,
    humification_fraction: []const f64,
    growth_temperature_response: []const f64,
    matric_plus_osmotic_potential_megapascal: []const f64,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    microbial_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    humus_nitrogen_per_carbon_g_n_per_g_c: f64,
    humus_phosphorus_per_carbon_g_p_per_g_c: f64,
    negligible_carbon_g_c: f64,
    turnover_parameters: surface_turnover.Parameters,
    parameters: nitrogen_parameters.Parameters,
    nitrogen_molar_mass_g_per_mol: f64,
    phosphorus_molar_mass_g_per_mol: f64,
    mineral_exchange_parameters: surface_mineral_exchange.Parameters,
    nutrient_competition: ?*const competition_history.State = null,
    nutrient_competition_attempt: ?*competition_history.Attempt = null,
    minimum_competition_fraction: f64 = 0.001,
    negligible_nitrogen_g_n: f64 = 0,
    negligible_phosphorus_g_p: f64 = 0,
    microbial_surface_area_m2_per_g_c: f64,
    timestep_h: f64,
    /// Exact accepted K=5 turnover products whose recipient is NU topsoil.
    /// Indexed by cell and active source population. Output-only and never
    /// persisted: each accepted surface batch consumes it immediately.
    accepted_topsoil_organic_transfer: ?[]organic.ElementPool = null,
};

const CellResult = struct {
    chemistry: chemistry.Cell,
    nitrite_g_n: f64,
    carbon_dioxide_g_c: f64,
    methane_g_c: f64,
    gaseous_methane_g_c: f64,
    hydrogen_g_h: f64,
    topsoil_ammonium_non_band_mol_per_m3: f64,
    topsoil_ammonium_band_mol_per_m3: f64,
    topsoil_nitrate_non_band_mol_per_m3: f64,
    topsoil_nitrate_band_mol_per_m3: f64,
    topsoil_h2po4_non_band_mol_p_per_m3: f64,
    topsoil_h2po4_band_mol_p_per_m3: f64,
    topsoil_hpo4_non_band_mol_p_per_m3: f64,
    topsoil_hpo4_band_mol_p_per_m3: f64,
    microbial: [active_population_count * organic.kinetic_fraction_count]organic.ElementPool,
    surface_residue: [surface_respiration.litter_complex_count * organic.residue_fraction_count]organic.ElementPool,
    topsoil_humus: [2]organic.ElementPool,
    topsoil_humus_colonized_g_c: [2]f64,
    topsoil_particulate: organic.ElementPool,
    topsoil_particulate_colonized_g_c: f64,
    actual_primary: [active_population_count]f64,
    actual_respiration: [active_population_count]f64,
    actual_uptake: [active_population_count]f64,
    actual_gain: [active_population_count]f64,
    surface_ammonium_exchange: [active_population_count]f64,
    surface_nitrate_exchange: [active_population_count]f64,
    surface_h2po4_exchange: [active_population_count]f64,
    surface_hpo4_exchange: [active_population_count]f64,
    topsoil_ammonium_exchange: [active_population_count]f64,
    topsoil_nitrate_exchange: [active_population_count]f64,
    topsoil_h2po4_exchange: [active_population_count]f64,
    topsoil_hpo4_exchange: [active_population_count]f64,
    surface_mineral_capacity: [active_population_count][competition_history.surface_pool_count]f64,
    topsoil_residual_capacity: [active_population_count][competition_history.surface_pool_count]f64,
    topsoil_organic_transfer: [active_population_count]organic.ElementPool,
};

/// Atomically publishes K=5 transformations into the dedicated surface
/// organic, litter chemistry and litter gas owners. A later bad cell leaves
/// the complete tile unchanged so the hourly transaction can retry safely.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validateApply(context.*, range);
    for (range.first..range.end) |cell| {
        var cell_context = context.*;
        if (context.zone_fractions_by_layer.len != 0)
            cell_context.zone_fractions = context.zone_fractions_by_layer[cell * context.soil_layer_capacity];
        _ = try calculateCell(cell_context, cell);
    }
    for (range.first..range.end) |cell| {
        var cell_context = context.*;
        if (context.zone_fractions_by_layer.len != 0)
            cell_context.zone_fractions = context.zone_fractions_by_layer[cell * context.soil_layer_capacity];
        const value = try calculateCell(cell_context, cell);
        if (context.nutrient_competition_attempt) |attempt| {
            for (0..active_population_count) |active| {
                const competitor = competition_history.surface_heterotroph_count + active;
                try attempt.recordSurfaceMineral(cell, competitor, value.surface_mineral_capacity[active]);
                try attempt.recordTopsoilResidual(cell * context.soil_layer_capacity, cell, competitor, value.topsoil_residual_capacity[active]);
            }
        }
        context.litter_chemistry.cells[cell] = value.chemistry;
        context.litter_denitrification.nitrite_g_n[cell] = value.nitrite_g_n;
        context.litter_gas.dissolved_mass_g[try gas.massIndex(cell, .carbon_dioxide, context.litter_gas.cell_count)] = value.carbon_dioxide_g_c;
        context.litter_gas.dissolved_mass_g[try gas.massIndex(cell, .methane, context.litter_gas.cell_count)] = value.methane_g_c;
        context.litter_gas.gaseous_mass_g[try gas.massIndex(cell, .methane, context.litter_gas.cell_count)] = value.gaseous_methane_g_c;
        context.litter_gas.dissolved_mass_g[try gas.massIndex(cell, .hydrogen, context.litter_gas.cell_count)] = value.hydrogen_g_h;
        const topsoil_layer = cell * context.soil_layer_capacity;
        context.topsoil_chemistry.aqueous[topsoil_layer].ammonium_non_band = value.topsoil_ammonium_non_band_mol_per_m3;
        context.topsoil_chemistry.aqueous[topsoil_layer].ammonium_band = value.topsoil_ammonium_band_mol_per_m3;
        context.topsoil_chemistry.aqueous[topsoil_layer].nitrate_non_band = value.topsoil_nitrate_non_band_mol_per_m3;
        context.topsoil_chemistry.aqueous[topsoil_layer].nitrate_band = value.topsoil_nitrate_band_mol_per_m3;
        context.topsoil_chemistry.non_band_phosphate[topsoil_layer].dissolved_h2po4_mol_p_per_m3 = value.topsoil_h2po4_non_band_mol_p_per_m3;
        context.topsoil_chemistry.band_phosphate[topsoil_layer].dissolved_h2po4_mol_p_per_m3 = value.topsoil_h2po4_band_mol_p_per_m3;
        context.topsoil_chemistry.non_band_phosphate[topsoil_layer].dissolved_hpo4_mol_p_per_m3 = value.topsoil_hpo4_non_band_mol_p_per_m3;
        context.topsoil_chemistry.band_phosphate[topsoil_layer].dissolved_hpo4_mol_p_per_m3 = value.topsoil_hpo4_band_mol_p_per_m3;
        for (0..surface_respiration.litter_complex_count) |complex| {
            for (0..organic.residue_fraction_count) |component|
                context.surface_organic.residue[(cell * organic.substrate_count + complex) * organic.residue_fraction_count + component] = value.surface_residue[complex * organic.residue_fraction_count + component];
        }
        for (0..2) |humus_class| {
            const humus_index = (topsoil_layer * organic.substrate_count + 4) * organic.structural_fraction_count + humus_class;
            context.topsoil_organic.structural[humus_index] = value.topsoil_humus[humus_class];
            context.topsoil_organic.colonized_structural_carbon_g_c[humus_index] = value.topsoil_humus_colonized_g_c[humus_class];
        }
        const particulate_index = (topsoil_layer * organic.substrate_count + 3) * organic.structural_fraction_count;
        context.topsoil_organic.structural[particulate_index] = value.topsoil_particulate;
        context.topsoil_organic.colonized_structural_carbon_g_c[particulate_index] = value.topsoil_particulate_colonized_g_c;
        for (0..active_population_count) |active| {
            const base = microbialBase(cell, source_population_by_active[active]);
            for (0..organic.kinetic_fraction_count) |fraction| context.surface_organic.microbial[base + fraction] = value.microbial[active * organic.kinetic_fraction_count + fraction];
            const index = cell * active_population_count + active;
            context.state.actual_primary_reaction[index] = value.actual_primary[active];
            context.state.actual_respiration_g_c[index] = value.actual_respiration[active];
            context.state.actual_carbon_uptake_g_c[index] = value.actual_uptake[active];
            context.state.actual_nonstructural_carbon_gain_g_c[index] = value.actual_gain[active];
            context.state.surface_ammonium_exchange_g_n[index] = value.surface_ammonium_exchange[active];
            context.state.surface_nitrate_exchange_g_n[index] = value.surface_nitrate_exchange[active];
            context.state.surface_h2po4_exchange_g_p[index] = value.surface_h2po4_exchange[active];
            context.state.surface_hpo4_exchange_g_p[index] = value.surface_hpo4_exchange[active];
            context.state.topsoil_ammonium_exchange_g_n[index] = value.topsoil_ammonium_exchange[active];
            context.state.topsoil_nitrate_exchange_g_n[index] = value.topsoil_nitrate_exchange[active];
            context.state.topsoil_h2po4_exchange_g_p[index] = value.topsoil_h2po4_exchange[active];
            context.state.topsoil_hpo4_exchange_g_p[index] = value.topsoil_hpo4_exchange[active];
            if (context.accepted_topsoil_organic_transfer) |activity|
                activity[index] = value.topsoil_organic_transfer[active];
            context.state.previous_oxygen_demand_g_o[index] = context.state.potential_oxygen_demand_g_o[index];
        }
    }
}

fn calculateCell(context: ApplyContext, cell: usize) !CellResult {
    const water = context.litter_water_m3[cell];
    var result: CellResult = undefined;
    result.chemistry = context.litter_chemistry.cells[cell];
    result.nitrite_g_n = context.litter_denitrification.nitrite_g_n[cell];
    const co2_index = try gas.massIndex(cell, .carbon_dioxide, context.litter_gas.cell_count);
    const methane_index = try gas.massIndex(cell, .methane, context.litter_gas.cell_count);
    const hydrogen_index = try gas.massIndex(cell, .hydrogen, context.litter_gas.cell_count);
    result.carbon_dioxide_g_c = context.litter_gas.dissolved_mass_g[co2_index];
    result.methane_g_c = context.litter_gas.dissolved_mass_g[methane_index];
    result.gaseous_methane_g_c = context.litter_gas.gaseous_mass_g[methane_index];
    result.hydrogen_g_h = context.litter_gas.dissolved_mass_g[hydrogen_index];
    const topsoil_layer = cell * context.soil_layer_capacity;
    const topsoil_aqueous = context.topsoil_chemistry.aqueous[topsoil_layer];
    const topsoil_non_band_phosphate = context.topsoil_chemistry.non_band_phosphate[topsoil_layer];
    const topsoil_band_phosphate = context.topsoil_chemistry.band_phosphate[topsoil_layer];
    result.topsoil_ammonium_non_band_mol_per_m3 = topsoil_aqueous.ammonium_non_band;
    result.topsoil_ammonium_band_mol_per_m3 = topsoil_aqueous.ammonium_band;
    result.topsoil_nitrate_non_band_mol_per_m3 = topsoil_aqueous.nitrate_non_band;
    result.topsoil_nitrate_band_mol_per_m3 = topsoil_aqueous.nitrate_band;
    result.topsoil_h2po4_non_band_mol_p_per_m3 = topsoil_non_band_phosphate.dissolved_h2po4_mol_p_per_m3;
    result.topsoil_h2po4_band_mol_p_per_m3 = topsoil_band_phosphate.dissolved_h2po4_mol_p_per_m3;
    result.topsoil_hpo4_non_band_mol_p_per_m3 = topsoil_non_band_phosphate.dissolved_hpo4_mol_p_per_m3;
    result.topsoil_hpo4_band_mol_p_per_m3 = topsoil_band_phosphate.dissolved_hpo4_mol_p_per_m3;
    for (0..active_population_count) |active| {
        const base = microbialBase(cell, source_population_by_active[active]);
        for (0..organic.kinetic_fraction_count) |fraction| result.microbial[active * organic.kinetic_fraction_count + fraction] = context.surface_organic.microbial[base + fraction];
    }
    var total_surface_residue_g_c: f64 = 0;
    for (0..surface_respiration.litter_complex_count) |complex| for (0..organic.residue_fraction_count) |component| {
        const local = complex * organic.residue_fraction_count + component;
        result.surface_residue[local] = context.surface_organic.residue[(cell * organic.substrate_count + complex) * organic.residue_fraction_count + component];
        total_surface_residue_g_c += result.surface_residue[local].carbon_g_c;
    };
    for (0..2) |humus_class| {
        const humus_index = (topsoil_layer * organic.substrate_count + 4) * organic.structural_fraction_count + humus_class;
        result.topsoil_humus[humus_class] = context.topsoil_organic.structural[humus_index];
        result.topsoil_humus_colonized_g_c[humus_class] = context.topsoil_organic.colonized_structural_carbon_g_c[humus_index];
    }
    const particulate_index = (topsoil_layer * organic.substrate_count + 3) * organic.structural_fraction_count;
    result.topsoil_particulate = context.topsoil_organic.structural[particulate_index];
    result.topsoil_particulate_colonized_g_c = context.topsoil_organic.colonized_structural_carbon_g_c[particulate_index];
    var total_colonized_structural_g_c: f64 = 0;
    for (0..surface_respiration.litter_complex_count) |complex| {
        for (0..organic.structural_fraction_count) |component|
            total_colonized_structural_g_c += context.surface_organic.colonized_structural_carbon_g_c[(cell * organic.substrate_count + complex) * organic.structural_fraction_count + component];
    }
    result.actual_primary = .{0} ** active_population_count;
    result.actual_respiration = .{0} ** active_population_count;
    result.actual_uptake = .{0} ** active_population_count;
    result.actual_gain = .{0} ** active_population_count;
    result.surface_ammonium_exchange = .{0} ** active_population_count;
    result.surface_nitrate_exchange = .{0} ** active_population_count;
    result.surface_h2po4_exchange = .{0} ** active_population_count;
    result.surface_hpo4_exchange = .{0} ** active_population_count;
    result.topsoil_ammonium_exchange = .{0} ** active_population_count;
    result.topsoil_nitrate_exchange = .{0} ** active_population_count;
    result.topsoil_h2po4_exchange = .{0} ** active_population_count;
    result.topsoil_hpo4_exchange = .{0} ** active_population_count;
    result.surface_mineral_capacity = .{.{0} ** competition_history.surface_pool_count} ** active_population_count;
    result.topsoil_residual_capacity = .{.{0} ** competition_history.surface_pool_count} ** active_population_count;
    result.topsoil_organic_transfer = [_]organic.ElementPool{.{}} ** active_population_count;

    const ammonium_before = result.chemistry.ammonium_mol_per_m3 * water * context.nitrogen_molar_mass_g_per_mol;
    const nitrate_before = result.chemistry.nitrate_mol_per_m3 * water * context.nitrogen_molar_mass_g_per_mol;
    var ammonium = ammonium_before;
    var nitrate = nitrate_before;
    const h2po4_before = result.chemistry.h2po4_mol_p_per_m3 * water * context.phosphorus_molar_mass_g_per_mol;
    var h2po4 = h2po4_before;
    const hpo4_before = result.chemistry.hpo4_mol_p_per_m3 * water * context.phosphorus_molar_mass_g_per_mol;
    var hpo4 = hpo4_before;
    _ = context.parameters.methane orelse return error.MissingSurfaceMethaneParameters;
    for (0..active_population_count) |active| {
        var accepted_topsoil_organic: organic.ElementPool = .{};
        const index = cell * active_population_count + active;
        const aerobic = active != 3;
        const oxygen_index = cell * context.oxygen_unit_count_per_cell + context.first_autotrophic_oxygen_unit + active;
        const fraction = if (aerobic) context.oxygen_satisfaction_fraction[oxygen_index] else 1;
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidSurfaceAutotrophicOxygenFraction;
        const primary = context.state.potential_primary_reaction[index] * fraction;
        const respiration_g_c = context.state.potential_respiration_g_c[index] * fraction;
        const methane_parameters = context.parameters.methane orelse return error.MissingSurfaceMethaneParameters;
        const growth_respiration_fraction = switch (roleForActive(active)) {
            .ammonia_oxidizer, .nitrite_oxidizer => context.parameters.nitrification.growth_respiration_fraction,
            .methanotroph => methane_parameters.methanotroph_growth_respiration_g_c_per_g_c,
            .hydrogenotroph => 1,
        };
        // Source CGOMX is recomputed after WFN is known. Maintenance is not
        // multiplied by the O2 fraction; low O2 first services maintenance and
        // only the remaining respiration drives growth.
        const uptake_g_c = if (aerobic)
            grossAutotrophicUptake(respiration_g_c, context.state.maintenance_respiration_g_c[index], growth_respiration_fraction)
        else
            context.state.potential_carbon_uptake_g_c[index];
        const gain_g_c = uptake_g_c - respiration_g_c;
        switch (roleForActive(active)) {
            .ammonia_oxidizer => {
                if (primary > ammonium) return error.InsufficientSurfaceAutotrophicAmmonium;
                ammonium -= primary;
                result.nitrite_g_n += primary;
                if (uptake_g_c > result.carbon_dioxide_g_c) return error.InsufficientSurfaceAutotrophicCarbonDioxide;
                result.carbon_dioxide_g_c -= uptake_g_c;
                result.carbon_dioxide_g_c += respiration_g_c;
            },
            .nitrite_oxidizer => {
                if (primary > result.nitrite_g_n) return error.InsufficientSurfaceAutotrophicNitrite;
                result.nitrite_g_n -= primary;
                nitrate += primary;
                if (uptake_g_c > result.carbon_dioxide_g_c) return error.InsufficientSurfaceAutotrophicCarbonDioxide;
                result.carbon_dioxide_g_c -= uptake_g_c;
                result.carbon_dioxide_g_c += respiration_g_c;
            },
            .methanotroph => {
                var debit = primary + uptake_g_c;
                const aqueous_debit = @min(debit, result.methane_g_c);
                result.methane_g_c -= aqueous_debit;
                debit -= aqueous_debit;
                if (debit > result.gaseous_methane_g_c) return error.InsufficientSurfaceAutotrophicMethane;
                result.gaseous_methane_g_c -= debit;
                result.carbon_dioxide_g_c += primary + respiration_g_c;
            },
            .hydrogenotroph => {
                if (primary > result.hydrogen_g_h or uptake_g_c > result.carbon_dioxide_g_c) return error.InsufficientSurfaceHydrogenotrophicSubstrate;
                result.hydrogen_g_h -= primary;
                result.carbon_dioxide_g_c -= uptake_g_c;
                result.methane_g_c += respiration_g_c;
            },
        }
        const source_population = source_population_by_active[active];
        const ratio_base = (organic.autotrophic_substrate_index * organic.microbial_population_count + source_population) * organic.kinetic_fraction_count;
        const labile_target_n = context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_base];
        const resistant_target_n = context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_base + 1];
        const labile_target_p = context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio_base];
        const resistant_target_p = context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio_base + 1];
        const nonstructural_before = result.microbial[active * organic.kinetic_fraction_count + 2];
        // NITRO.F 2094--2288 uses the hour-start nonstructural C,N,P pool and
        // the nonstructural (+2) source ratio. The previous adapter incorrectly
        // used this hour's carbon gain and the labile (+0) ratio, suppressing
        // release and changing starvation feedback.
        const nonstructural_target_n = context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_base + 2];
        const nonstructural_target_p = context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio_base + 2];
        const nitrogen_demand = nonstructural_before.carbon_g_c * nonstructural_target_n - nonstructural_before.nitrogen_g_n;
        const phosphorus_demand = nonstructural_before.carbon_g_c * nonstructural_target_p - nonstructural_before.phosphorus_g_p;
        const share = context.state.mineral_exchange_share[index];
        const competitor = competition_history.surface_heterotroph_count + active;
        const activity = context.growth_temperature_response[cell] * @exp((if (source_population == 2) @as(f64, 0.05) else 0.10) * context.matric_plus_osmotic_potential_megapascal[cell]);
        const area_activity = context.microbial_surface_area_m2_per_g_c * context.state.active_biomass_g_c[index] * activity * context.timestep_h;
        const exchange_parameters = context.mineral_exchange_parameters;
        const surface_ammonium_result = try acceptedSurfaceExchange(context, .ammonium, cell, competitor, nitrogen_demand, ammonium, if (water > 0) ammonium / water else 0, exchange_parameters.ammonium_minimum_concentration_g_n_per_m3, exchange_parameters.ammonium_half_saturation_g_n_per_m3, exchange_parameters.ammonium_maximum_uptake_g_n_per_m2_h * area_activity, share, water);
        const surface_ammonium = surface_ammonium_result.exchange;
        const surface_nitrate_demand = @max(0, nitrogen_demand - surface_ammonium);
        const surface_nitrate_result = try acceptedSurfaceExchange(context, .nitrate, cell, competitor, surface_nitrate_demand, nitrate, if (water > 0) nitrate / water else 0, exchange_parameters.nitrate_minimum_concentration_g_n_per_m3, exchange_parameters.nitrate_half_saturation_g_n_per_m3, exchange_parameters.nitrate_maximum_uptake_g_n_per_m2_h * area_activity, share, water);
        const surface_nitrate = surface_nitrate_result.exchange;
        const surface_h2po4_result = try acceptedSurfaceExchange(context, .h2po4, cell, competitor, phosphorus_demand, h2po4, if (water > 0) h2po4 / water else 0, exchange_parameters.phosphate_minimum_concentration_g_p_per_m3, exchange_parameters.phosphate_half_saturation_g_p_per_m3, exchange_parameters.phosphate_maximum_uptake_g_p_per_m2_h * area_activity, share, water);
        const surface_h2po4 = surface_h2po4_result.exchange;
        const surface_hpo4_demand = @max(0, phosphorus_demand - surface_h2po4);
        const surface_hpo4_result = try acceptedSurfaceExchange(context, .hpo4, cell, competitor, surface_hpo4_demand, hpo4, if (water > 0) hpo4 / water else 0, 0.25 * exchange_parameters.phosphate_minimum_concentration_g_p_per_m3, exchange_parameters.phosphate_half_saturation_g_p_per_m3, 0.25 * exchange_parameters.phosphate_maximum_uptake_g_p_per_m2_h * area_activity, share, water);
        const surface_hpo4 = surface_hpo4_result.exchange;
        result.surface_mineral_capacity[active] = .{ surface_ammonium_result.capacity, surface_nitrate_result.capacity, surface_h2po4_result.capacity, surface_hpo4_result.capacity };
        ammonium -= surface_ammonium;
        nitrate -= surface_nitrate;
        h2po4 -= surface_h2po4;
        hpo4 -= surface_hpo4;

        // L=0 residual demand draws from source NU topsoil only after litter
        // NH4->NO3 and H2PO4->HPO4 (NITRO.F 2324--2478).
        const residual_n = @max(0, nitrogen_demand - surface_ammonium - surface_nitrate);
        const residual_p = @max(0, phosphorus_demand - surface_h2po4 - surface_hpo4);
        const topsoil_water = context.topsoil_water_m3[topsoil_layer];
        const topsoil_ammonium_result = try acceptedTopsoilExchange(context, .ammonium, topsoil_layer, cell, competitor, residual_n, result.topsoil_ammonium_non_band_mol_per_m3 * context.nitrogen_molar_mass_g_per_mol, result.topsoil_ammonium_band_mol_per_m3 * context.nitrogen_molar_mass_g_per_mol, topsoil_water, context.zone_fractions.ammonium_non_band, context.zone_fractions.ammonium_band, exchange_parameters.ammonium_minimum_concentration_g_n_per_m3, exchange_parameters.ammonium_half_saturation_g_n_per_m3, exchange_parameters.ammonium_maximum_uptake_g_n_per_m2_h * area_activity, share, false);
        const topsoil_ammonium = topsoil_ammonium_result.exchange;
        const topsoil_nitrate_demand = @max(0, residual_n - topsoil_ammonium);
        const topsoil_nitrate_result = try acceptedTopsoilExchange(context, .nitrate, topsoil_layer, cell, competitor, topsoil_nitrate_demand, result.topsoil_nitrate_non_band_mol_per_m3 * context.nitrogen_molar_mass_g_per_mol, result.topsoil_nitrate_band_mol_per_m3 * context.nitrogen_molar_mass_g_per_mol, topsoil_water, context.zone_fractions.nitrate_non_band, context.zone_fractions.nitrate_band, exchange_parameters.nitrate_minimum_concentration_g_n_per_m3, exchange_parameters.nitrate_half_saturation_g_n_per_m3, exchange_parameters.nitrate_maximum_uptake_g_n_per_m2_h * area_activity, share, true);
        const topsoil_nitrate = topsoil_nitrate_result.exchange;
        const topsoil_h2po4_result = try acceptedTopsoilExchange(context, .h2po4, topsoil_layer, cell, competitor, residual_p, result.topsoil_h2po4_non_band_mol_p_per_m3 * context.phosphorus_molar_mass_g_per_mol, result.topsoil_h2po4_band_mol_p_per_m3 * context.phosphorus_molar_mass_g_per_mol, topsoil_water, context.zone_fractions.phosphate_non_band, context.zone_fractions.phosphate_band, exchange_parameters.phosphate_minimum_concentration_g_p_per_m3, exchange_parameters.phosphate_half_saturation_g_p_per_m3, exchange_parameters.phosphate_maximum_uptake_g_p_per_m2_h * area_activity, share, false);
        const topsoil_h2po4 = topsoil_h2po4_result.exchange;
        const topsoil_hpo4_demand = @max(0, residual_p - topsoil_h2po4);
        const topsoil_hpo4_result = try acceptedTopsoilExchange(context, .hpo4, topsoil_layer, cell, competitor, topsoil_hpo4_demand, result.topsoil_hpo4_non_band_mol_p_per_m3 * context.phosphorus_molar_mass_g_per_mol, result.topsoil_hpo4_band_mol_p_per_m3 * context.phosphorus_molar_mass_g_per_mol, topsoil_water, context.zone_fractions.phosphate_non_band, context.zone_fractions.phosphate_band, 0.25 * exchange_parameters.phosphate_minimum_concentration_g_p_per_m3, exchange_parameters.phosphate_half_saturation_g_p_per_m3, 0.25 * exchange_parameters.phosphate_maximum_uptake_g_p_per_m2_h * area_activity, share, false);
        const topsoil_hpo4 = topsoil_hpo4_result.exchange;
        result.topsoil_residual_capacity[active] = .{ topsoil_ammonium_result.capacity, topsoil_nitrate_result.capacity, topsoil_h2po4_result.capacity, topsoil_hpo4_result.capacity };
        if (topsoil_water > 0) {
            const ammonium_delta = topsoil_ammonium / (topsoil_water * context.nitrogen_molar_mass_g_per_mol);
            const nitrate_delta = topsoil_nitrate / (topsoil_water * context.nitrogen_molar_mass_g_per_mol);
            const h2po4_delta = topsoil_h2po4 / (topsoil_water * context.phosphorus_molar_mass_g_per_mol);
            const hpo4_delta = topsoil_hpo4 / (topsoil_water * context.phosphorus_molar_mass_g_per_mol);
            if (context.zone_fractions.ammonium_non_band > 0) result.topsoil_ammonium_non_band_mol_per_m3 -= ammonium_delta;
            if (context.zone_fractions.ammonium_band > 0) result.topsoil_ammonium_band_mol_per_m3 -= ammonium_delta;
            if (context.zone_fractions.nitrate_non_band > 0) result.topsoil_nitrate_non_band_mol_per_m3 -= nitrate_delta;
            if (context.zone_fractions.nitrate_band > 0) result.topsoil_nitrate_band_mol_per_m3 -= nitrate_delta;
            if (context.zone_fractions.phosphate_non_band > 0) {
                result.topsoil_h2po4_non_band_mol_p_per_m3 -= h2po4_delta;
                result.topsoil_hpo4_non_band_mol_p_per_m3 -= hpo4_delta;
            }
            if (context.zone_fractions.phosphate_band > 0) {
                result.topsoil_h2po4_band_mol_p_per_m3 -= h2po4_delta;
                result.topsoil_hpo4_band_mol_p_per_m3 -= hpo4_delta;
            }
        }
        result.surface_ammonium_exchange[active] = surface_ammonium;
        result.surface_nitrate_exchange[active] = surface_nitrate;
        result.surface_h2po4_exchange[active] = surface_h2po4;
        result.surface_hpo4_exchange[active] = surface_hpo4;
        result.topsoil_ammonium_exchange[active] = topsoil_ammonium;
        result.topsoil_nitrate_exchange[active] = topsoil_nitrate;
        result.topsoil_h2po4_exchange[active] = topsoil_h2po4;
        result.topsoil_hpo4_exchange[active] = topsoil_hpo4;
        const accepted_n = surface_ammonium + surface_nitrate + topsoil_ammonium + topsoil_nitrate;
        const accepted_p = surface_h2po4 + surface_hpo4 + topsoil_h2po4 + topsoil_hpo4;
        const recycling = try metabolism.recyclingFractions(toMetabolic(nonstructural_before), labile_target_n, labile_target_p, .{
            .minimum_carbon_fraction = context.turnover_parameters.minimum_carbon_recycling_fraction,
            .carbon_range_fraction = context.turnover_parameters.carbon_recycling_range_fraction,
            .maximum_nitrogen_fraction = context.turnover_parameters.maximum_nitrogen_recycling_fraction,
            .maximum_phosphorus_fraction = context.turnover_parameters.maximum_phosphorus_recycling_fraction,
        });
        const temperature_water_response = context.growth_temperature_response[cell] * @exp(context.parameters.nitrifier_environment.water_potential_sensitivity_per_megapascal * context.matric_plus_osmotic_potential_megapascal[cell]);
        const assimilated = try metabolism.assimilateNonstructural(.{
            // NITRO evaluates CGOMS from the accepted hour-start OMC(3),
            // before this hour's autotrophic gain and turnover are published.
            .nonstructural = toMetabolic(nonstructural_before),
            .temperature_water_response = temperature_water_response,
            .nonstructural_to_structural_rate_per_h = context.parameters.nonsymbiotic_nitrogen_fixation.nonstructural_to_structural_rate_per_h,
            .timestep_h = context.timestep_h,
            .structural_partition = .{ context.parameters.nitrifier_environment.labile_biomass_fraction, 1 - context.parameters.nitrifier_environment.labile_biomass_fraction },
            .maximum_nitrogen_per_carbon = .{ labile_target_n, resistant_target_n },
            .maximum_phosphorus_per_carbon = .{ labile_target_p, resistant_target_p },
        });
        const labile_before = result.microbial[active * organic.kinetic_fraction_count];
        const resistant_before = result.microbial[active * organic.kinetic_fraction_count + 1];
        const active_biomass = if (context.parameters.nitrifier_environment.labile_biomass_fraction > 0) labile_before.carbon_g_c / context.parameters.nitrifier_environment.labile_biomass_fraction else 0;
        const density = if (total_colonized_structural_g_c > context.negligible_carbon_g_c) active_biomass / total_colonized_structural_g_c else 0;
        const decomposition_density_response = if (total_colonized_structural_g_c > context.negligible_carbon_g_c) density / (density + context.parameters.heterotrophic_respiration.decomposition_density_half_saturation_g_c_per_g_c) else 1;
        const water_response = @exp(context.parameters.nitrifier_environment.water_potential_sensitivity_per_megapascal * context.matric_plus_osmotic_potential_megapascal[cell]);
        const structural_before = [_]organic.ElementPool{ labile_before, resistant_before };
        var basal: [2]metabolism.DecompositionResult = undefined;
        const basal_rates = [_]f64{ context.turnover_parameters.basal_decomposition_rate_per_h[0], context.turnover_parameters.basal_decomposition_rate_per_h[1] };
        for (0..2) |component| basal[component] = try metabolism.decompose(.{
            .pool = toMetabolic(structural_before[component]),
            .temperature_response = context.growth_temperature_response[cell],
            .water_response = water_response,
            .basal_decomposition_rate_per_h = basal_rates[component],
            .microbial_carbon_response = decomposition_density_response,
            .timestep_h = context.timestep_h,
            .recycling = recycling,
            .humification_fraction = context.humification_fraction[cell],
            .humus_nitrogen_per_carbon_g_n_per_g_c = context.humus_nitrogen_per_carbon_g_n_per_g_c,
            .humus_phosphorus_per_carbon_g_p_per_g_c = context.humus_phosphorus_per_carbon_g_p_per_g_c,
        });
        const maintenance_total = context.state.maintenance_respiration_g_c[index];
        const accelerated = try metabolism.acceleratedSenescence(.{
            .structural = .{ toMetabolic(labile_before), toMetabolic(resistant_before) },
            .component_maintenance_respiration_g_c = .{ context.state.labile_maintenance_respiration_g_c[index], context.state.resistant_maintenance_respiration_g_c[index] },
            .total_maintenance_respiration_g_c = maintenance_total,
            .senescence_respiration_deficit_g_c = @max(0, maintenance_total - respiration_g_c),
            .recycling = recycling,
            .active_nitrogen_per_carbon_g_n_per_g_c = if (labile_before.carbon_g_c > context.negligible_carbon_g_c) labile_before.nitrogen_g_n / labile_before.carbon_g_c else labile_target_n,
            .active_phosphorus_per_carbon_g_p_per_g_c = if (labile_before.carbon_g_c > context.negligible_carbon_g_c) labile_before.phosphorus_g_p / labile_before.carbon_g_c else labile_target_p,
            .humification_fraction = context.humification_fraction[cell],
            .humus_nitrogen_per_carbon_g_n_per_g_c = context.humus_nitrogen_per_carbon_g_n_per_g_c,
            .humus_phosphorus_per_carbon_g_p_per_g_c = context.humus_phosphorus_per_carbon_g_p_per_g_c,
            .negligible_g_c = context.negligible_carbon_g_c,
        });
        var structural_transfer: organic.ElementPool = .{};
        var recycled_to_nonstructural: organic.ElementPool = .{};
        for (0..2) |component| {
            const transfer = assimilated.structural[component];
            structural_transfer = addPool(structural_transfer, fromMetabolic(transfer));
            const senescence = accelerated.component[component];
            result.microbial[active * organic.kinetic_fraction_count + component] = subtractPool(addPool(structural_before[component], fromMetabolic(transfer)), addPool(fromMetabolic(basal[component].decomposed), fromMetabolic(senescence.decomposed)));
            recycled_to_nonstructural = addPool(recycled_to_nonstructural, fromMetabolic(basal[component].recycled));
            recycled_to_nonstructural.nitrogen_g_n += senescence.recycled.nitrogen_g_n;
            recycled_to_nonstructural.phosphorus_g_p += senescence.recycled.phosphorus_g_p;
            // Source R3MMC is maintenance-deficit respiration, not retained
            // nonstructural carbon (NITRO.F 3795--3804).
            result.carbon_dioxide_g_c += senescence.recycled.carbon_g_c;
            const residue_product = addPool(fromMetabolic(basal[component].microbial_residue), fromMetabolic(senescence.microbial_residue));
            if (total_surface_residue_g_c > context.negligible_carbon_g_c) {
                for (0..surface_respiration.litter_complex_count) |complex| {
                    var complex_residue_g_c: f64 = 0;
                    for (0..organic.residue_fraction_count) |residue_component|
                        complex_residue_g_c += context.surface_organic.residue[(cell * organic.substrate_count + complex) * organic.residue_fraction_count + residue_component].carbon_g_c;
                    const destination = complex * organic.residue_fraction_count + component;
                    result.surface_residue[destination] = addPool(result.surface_residue[destination], scalePool(residue_product, complex_residue_g_c / total_surface_residue_g_c));
                }
            } else {
                // NITRO's no-residue fallback names K=3 even for L=0 where
                // KL=2. Route that intended fallback explicitly to the first
                // soil-layer particulate owner instead of losing the transfer.
                result.topsoil_particulate = addPool(result.topsoil_particulate, residue_product);
                result.topsoil_particulate_colonized_g_c += residue_product.carbon_g_c;
                accepted_topsoil_organic = addPool(accepted_topsoil_organic, residue_product);
            }
            const humified = addPool(fromMetabolic(basal[component].humified), fromMetabolic(senescence.humified));
            for (0..2) |humus_class| {
                const destination = scalePool(humified, context.topsoil_humus_partition[cell][humus_class]);
                result.topsoil_humus[humus_class] = addPool(result.topsoil_humus[humus_class], destination);
                result.topsoil_humus_colonized_g_c[humus_class] += destination.carbon_g_c;
                accepted_topsoil_organic = addPool(accepted_topsoil_organic, destination);
            }
        }
        result.microbial[active * organic.kinetic_fraction_count + 2] = addPool(subtractPool(addPool(nonstructural_before, .{ .carbon_g_c = gain_g_c, .nitrogen_g_n = accepted_n, .phosphorus_g_p = accepted_p }), structural_transfer), recycled_to_nonstructural);
        result.actual_primary[active] = primary;
        result.actual_respiration[active] = respiration_g_c;
        result.actual_uptake[active] = uptake_g_c;
        result.actual_gain[active] = gain_g_c;
        result.topsoil_organic_transfer[active] = accepted_topsoil_organic;
    }
    // Concentrations are retained while the litter is dry.  There is no
    // aqueous inventory to transform in that state, and zeroing a retained
    // concentration here would create an unaccounted mineral loss when water
    // returns.
    if (water > 0) {
        result.chemistry.ammonium_mol_per_m3 = ammonium / (water * context.nitrogen_molar_mass_g_per_mol);
        result.chemistry.nitrate_mol_per_m3 = nitrate / (water * context.nitrogen_molar_mass_g_per_mol);
        result.chemistry.h2po4_mol_p_per_m3 = h2po4 / (water * context.phosphorus_molar_mass_g_per_mol);
        result.chemistry.hpo4_mol_p_per_m3 = hpo4 / (water * context.phosphorus_molar_mass_g_per_mol);
    }
    inline for (.{ ammonium, nitrate, h2po4, hpo4, result.nitrite_g_n, result.carbon_dioxide_g_c, result.methane_g_c, result.gaseous_methane_g_c, result.hydrogen_g_h, result.topsoil_ammonium_non_band_mol_per_m3, result.topsoil_ammonium_band_mol_per_m3, result.topsoil_nitrate_non_band_mol_per_m3, result.topsoil_nitrate_band_mol_per_m3, result.topsoil_h2po4_non_band_mol_p_per_m3, result.topsoil_h2po4_band_mol_p_per_m3, result.topsoil_hpo4_non_band_mol_p_per_m3, result.topsoil_hpo4_band_mol_p_per_m3 }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceAutotrophicState;
    inline for (.{ result.surface_ammonium_exchange, result.surface_nitrate_exchange, result.surface_h2po4_exchange, result.surface_hpo4_exchange, result.topsoil_ammonium_exchange, result.topsoil_nitrate_exchange, result.topsoil_h2po4_exchange, result.topsoil_hpo4_exchange }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.InvalidSurfaceAutotrophicState;
    for (result.microbial) |pool| inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceAutotrophicState;
    for (result.surface_residue) |pool| try validatePool(pool);
    for (result.topsoil_organic_transfer) |pool| try validatePool(pool);
    for (result.topsoil_humus) |pool| try validatePool(pool);
    for (result.topsoil_humus_colonized_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceAutotrophicState;
    try validatePool(result.topsoil_particulate);
    if (!std.math.isFinite(result.topsoil_particulate_colonized_g_c) or result.topsoil_particulate_colonized_g_c < 0) return error.InvalidSurfaceAutotrophicState;
    return result;
}

const Ratios = struct { n: f64, p: f64 };

fn microbialBase(cell: usize, source_population: usize) usize {
    return ((cell * organic.microbial_substrate_count + organic.autotrophic_substrate_index) * organic.microbial_population_count + source_population) * organic.kinetic_fraction_count;
}

fn toMetabolic(value: organic.ElementPool) metabolism.ElementalPool {
    return .{ .carbon_g_c = value.carbon_g_c, .nitrogen_g_n = value.nitrogen_g_n, .phosphorus_g_p = value.phosphorus_g_p };
}

fn fromMetabolic(value: metabolism.ElementalPool) organic.ElementPool {
    return .{ .carbon_g_c = value.carbon_g_c, .nitrogen_g_n = value.nitrogen_g_n, .phosphorus_g_p = value.phosphorus_g_p };
}

fn addPool(a: organic.ElementPool, b: organic.ElementPool) organic.ElementPool {
    return .{ .carbon_g_c = a.carbon_g_c + b.carbon_g_c, .nitrogen_g_n = a.nitrogen_g_n + b.nitrogen_g_n, .phosphorus_g_p = a.phosphorus_g_p + b.phosphorus_g_p };
}

fn subtractPool(a: organic.ElementPool, b: organic.ElementPool) organic.ElementPool {
    return .{ .carbon_g_c = a.carbon_g_c - b.carbon_g_c, .nitrogen_g_n = a.nitrogen_g_n - b.nitrogen_g_n, .phosphorus_g_p = a.phosphorus_g_p - b.phosphorus_g_p };
}

fn scalePool(value: organic.ElementPool, fraction: f64) organic.ElementPool {
    return .{ .carbon_g_c = value.carbon_g_c * fraction, .nitrogen_g_n = value.nitrogen_g_n * fraction, .phosphorus_g_p = value.phosphorus_g_p * fraction };
}

fn validatePool(pool: organic.ElementPool) !void {
    inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceAutotrophicState;
}

fn grossAutotrophicUptake(respiration_g_c: f64, maintenance_g_c: f64, growth_respiration_fraction: f64) f64 {
    if (growth_respiration_fraction <= 0) return respiration_g_c;
    return @min(maintenance_g_c, respiration_g_c) + @max(0, respiration_g_c - maintenance_g_c) / growth_respiration_fraction;
}

fn acceptedSurfaceExchange(context: ApplyContext, pool: competition_history.SurfacePool, cell: usize, competitor: usize, demand: f64, amount: f64, concentration: f64, minimum: f64, half: f64, capacity: f64, fallback: f64, water: f64) !surface_mineral_exchange.ExchangeResult {
    if (context.nutrient_competition) |accepted| {
        const negligible = switch (pool) {
            .ammonium, .nitrate => context.negligible_nitrogen_g_n,
            .h2po4, .hpo4 => context.negligible_phosphorus_g_p,
        };
        return surface_mineral_exchange.calculateExchangeWithHistory(
            demand,
            amount,
            concentration,
            minimum,
            half,
            capacity,
            try accepted.surfaceTotal(pool, cell),
            try accepted.surfaceMineralCapacity(pool, cell, competitor),
            fallback,
            context.minimum_competition_fraction,
            negligible,
            water,
        );
    }
    return .{ .exchange = surface_mineral_exchange.calculateExchange(demand, amount, concentration, minimum, half, capacity, fallback, water) };
}

fn acceptedTopsoilExchange(context: ApplyContext, pool: competition_history.SurfacePool, layer: usize, cell: usize, competitor: usize, demand: f64, non_band_concentration: f64, band_concentration: f64, water: f64, non_band_fraction: f64, band_fraction: f64, minimum: f64, half: f64, capacity: f64, fallback: f64, source_uses_maximum: bool) !topsoil_mineral_exchange.ZoneExchangeResult {
    if (context.nutrient_competition) |accepted| {
        const soil_pool: competition_history.SoilPool = switch (pool) {
            .ammonium => .ammonium_non_band,
            .nitrate => .nitrate_non_band,
            .h2po4 => .h2po4_non_band,
            .hpo4 => .hpo4_non_band,
        };
        const negligible = switch (pool) {
            .ammonium, .nitrate => context.negligible_nitrogen_g_n,
            .h2po4, .hpo4 => context.negligible_phosphorus_g_p,
        };
        return topsoil_mineral_exchange.calculateZoneExchangeWithHistory(
            demand,
            non_band_concentration,
            band_concentration,
            water,
            non_band_fraction,
            band_fraction,
            minimum,
            half,
            capacity,
            try accepted.soilTotal(soil_pool, layer),
            try accepted.topsoilResidualCapacity(pool, cell, competitor),
            fallback,
            context.minimum_competition_fraction,
            negligible,
            source_uses_maximum,
        );
    }
    return .{ .exchange = topsoil_mineral_exchange.calculateZoneExchange(demand, non_band_concentration, band_concentration, water, non_band_fraction, band_fraction, minimum, half, capacity, fallback, source_uses_maximum) };
}

fn validatePrepare(context: PrepareContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    const ratio_count = organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.litter_chemistry.cells.len != cells or context.litter_chemistry.ph.len != cells or context.litter_denitrification.cell_count != cells or context.litter_gas.cell_count != cells or context.environment.biologically_active_water_m3.len != cells or context.heterotrophic_respiration.cell_count != cells) return error.SurfaceAutotrophicDimensionMismatch;
    inline for (.{ context.litter_water_m3, context.litter_temperature_k, context.matric_plus_osmotic_potential_megapascal }) |values| if (values.len != cells) return error.SurfaceAutotrophicDimensionMismatch;
    if (context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != ratio_count or context.microbial_phosphorus_to_carbon_g_p_per_g_c.len != ratio_count) return error.SurfaceAutotrophicDimensionMismatch;
    if (!std.math.isFinite(context.nitrogen_molar_mass_g_per_mol) or context.nitrogen_molar_mass_g_per_mol <= 0 or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.InvalidSurfaceAutotrophicParameter;
    if (!std.math.isFinite(context.minimum_competition_fraction) or context.minimum_competition_fraction < 0 or !std.math.isFinite(context.negligible_nitrogen_g_n) or context.negligible_nitrogen_g_n < 0) return error.InvalidSurfaceAutotrophicParameter;
    if ((context.nutrient_competition == null) != (context.nutrient_competition_attempt == null)) return error.IncompleteSurfaceAutotrophicNutrientCompetitionBinding;
    if (context.nutrient_competition) |accepted| if (accepted.surface_cell_count != cells) return error.SurfaceAutotrophicDimensionMismatch;
    try nitrogen_parameters.validate(context.parameters);
    if (context.parameters.methane == null) return error.MissingSurfaceMethaneParameters;
}

fn validateApply(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.state.cell_count;
    const ratio_count = organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.litter_chemistry.cells.len != cells or context.litter_chemistry.ph.len != cells or context.litter_denitrification.cell_count != cells or context.litter_gas.cell_count != cells or context.litter_water_m3.len != cells or context.oxygen_unit_count_per_cell < context.first_autotrophic_oxygen_unit + active_population_count or context.oxygen_satisfaction_fraction.len != cells * context.oxygen_unit_count_per_cell or context.soil_layer_capacity == 0 or context.topsoil_organic.layer_count != cells * context.soil_layer_capacity or context.topsoil_chemistry.cell_count != cells * context.soil_layer_capacity or context.topsoil_water_m3.len != cells * context.soil_layer_capacity or context.topsoil_humus_partition.len != cells or context.humification_fraction.len != cells or context.growth_temperature_response.len != cells or context.matric_plus_osmotic_potential_megapascal.len != cells or context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != ratio_count or context.microbial_phosphorus_to_carbon_g_p_per_g_c.len != ratio_count or (context.zone_fractions_by_layer.len != 0 and context.zone_fractions_by_layer.len != cells * context.soil_layer_capacity) or (context.accepted_topsoil_organic_transfer != null and context.accepted_topsoil_organic_transfer.?.len != cells * active_population_count)) return error.SurfaceAutotrophicDimensionMismatch;
    inline for (.{ context.nitrogen_molar_mass_g_per_mol, context.phosphorus_molar_mass_g_per_mol, context.timestep_h, context.humus_nitrogen_per_carbon_g_n_per_g_c, context.humus_phosphorus_per_carbon_g_p_per_g_c, context.negligible_carbon_g_c, context.microbial_surface_area_m2_per_g_c }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSurfaceAutotrophicParameter;
    inline for (@typeInfo(surface_mineral_exchange.Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(context.mineral_exchange_parameters, field.name)) or @field(context.mineral_exchange_parameters, field.name) <= 0) return error.InvalidSurfaceAutotrophicParameter;
    if (!std.math.isFinite(context.minimum_competition_fraction) or context.minimum_competition_fraction < 0 or !std.math.isFinite(context.negligible_nitrogen_g_n) or context.negligible_nitrogen_g_n < 0 or !std.math.isFinite(context.negligible_phosphorus_g_p) or context.negligible_phosphorus_g_p < 0) return error.InvalidSurfaceAutotrophicParameter;
    if ((context.nutrient_competition == null) != (context.nutrient_competition_attempt == null)) return error.IncompleteSurfaceAutotrophicNutrientCompetitionBinding;
    if (context.nutrient_competition) |accepted| if (accepted.surface_cell_count != cells or accepted.soil_layer_count != context.topsoil_chemistry.cell_count) return error.SurfaceAutotrophicDimensionMismatch;
    const fractions_to_validate = if (context.zone_fractions_by_layer.len == 0) @as([]const zones.ZoneFractions, &.{context.zone_fractions}) else context.zone_fractions_by_layer;
    for (fractions_to_validate) |fractions| inline for (@typeInfo(zones.ZoneFractions).@"struct".fields) |field| if (!std.math.isFinite(@field(fractions, field.name)) or @field(fractions, field.name) < 0 or @field(fractions, field.name) > 1) return error.InvalidSurfaceAutotrophicParameter;
    for (context.state.mineral_exchange_share) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSurfaceAutotrophicParameter;
    for (context.topsoil_humus_partition) |partition| if (!std.math.isFinite(partition[0]) or !std.math.isFinite(partition[1]) or partition[0] < 0 or partition[1] < 0 or @abs(partition[0] + partition[1] - 1) > 1e-12) return error.InvalidSurfaceAutotrophicParameter;
    for (context.humification_fraction) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSurfaceAutotrophicParameter;
    try nitrogen_parameters.validate(context.parameters);
}

test "surface autotrophic population map preserves source N=1,2,3,5 only" {
    try std.testing.expectEqual([_]usize{ 0, 1, 2, 4 }, source_population_by_active);
    try std.testing.expectEqual(Role.ammonia_oxidizer, roleForActive(0));
    try std.testing.expectEqual(Role.hydrogenotroph, roleForActive(3));
}

test "surface K5 signed mineral exchange totals preserve daily mineralization convention" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.surface_ammonium_exchange_g_n[0] = 2;
    state.surface_nitrate_exchange_g_n[1] = -3;
    state.topsoil_ammonium_exchange_g_n[2] = 5;
    state.surface_h2po4_exchange_g_p[0] = -7;
    state.topsoil_hpo4_exchange_g_p[3] = 11;
    const totals = try mineralExchangeTotalsForCell(&state, 0);
    try std.testing.expectEqual(@as(f64, 4), totals.immobilization_g_n);
    try std.testing.expectEqual(@as(f64, 4), totals.immobilization_g_p);
}

fn testMineralExchangeParameters() surface_mineral_exchange.Parameters {
    return .{ .ammonium_maximum_uptake_g_n_per_m2_h = 0.014, .ammonium_minimum_concentration_g_n_per_m3 = 0.0125, .ammonium_half_saturation_g_n_per_m3 = 0.4, .nitrate_maximum_uptake_g_n_per_m2_h = 0.014, .nitrate_minimum_concentration_g_n_per_m3 = 0.03, .nitrate_half_saturation_g_n_per_m3 = 0.35, .phosphate_maximum_uptake_g_p_per_m2_h = 0.003, .phosphate_minimum_concentration_g_p_per_m3 = 0.009, .phosphate_half_saturation_g_p_per_m3 = 0.18, .phosphorus_molar_mass_g_per_mol = 31 };
}

fn focusedExchangeContext(state: *State, surface: *organic.State, litter: *chemistry.State, denit: *denitrification.State, gas_state: *gas.State, topsoil_organic: *organic.State, topsoil_chemistry_state: *soil_chemistry.State, litter_water: []const f64, topsoil_water: []const f64, oxygen: []const f64, microbial_n: []const f64, microbial_p: []const f64) !ApplyContext {
    return .{
        .state = state,
        .surface_organic = surface,
        .litter_chemistry = litter,
        .litter_denitrification = denit,
        .litter_gas = gas_state,
        .litter_water_m3 = litter_water,
        .topsoil_chemistry = topsoil_chemistry_state,
        .topsoil_water_m3 = topsoil_water,
        .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
        .oxygen_satisfaction_fraction = oxygen,
        .oxygen_unit_count_per_cell = surface_respiration.unit_count_per_cell + active_population_count,
        .first_autotrophic_oxygen_unit = surface_respiration.unit_count_per_cell,
        .topsoil_organic = topsoil_organic,
        .soil_layer_capacity = 1,
        .topsoil_humus_partition = if (state.cell_count == 1) &.{.{ 0.5, 0.5 }} else &.{ .{ 0.5, 0.5 }, .{ 0.5, 0.5 } },
        .humification_fraction = if (state.cell_count == 1) &.{0.2} else &.{ 0.2, 0.2 },
        .growth_temperature_response = if (state.cell_count == 1) &.{1} else &.{ 1, 1 },
        .matric_plus_osmotic_potential_megapascal = if (state.cell_count == 1) &.{0} else &.{ 0, 0 },
        .microbial_nitrogen_to_carbon_g_n_per_g_c = microbial_n,
        .microbial_phosphorus_to_carbon_g_p_per_g_c = microbial_p,
        .humus_nitrogen_per_carbon_g_n_per_g_c = 0.167,
        .humus_phosphorus_per_carbon_g_p_per_g_c = 0.0167,
        .negligible_carbon_g_c = 1e-12,
        .turnover_parameters = .{ .basal_decomposition_rate_per_h = .{ 0.01, 0.001 }, .minimum_carbon_recycling_fraction = 0.167, .carbon_recycling_range_fraction = 0.333, .maximum_nitrogen_recycling_fraction = 0.333, .maximum_phosphorus_recycling_fraction = 0.333, .dissolved_priming_rate_per_h = 0.01, .microbial_priming_rate_per_h = 0.001 },
        .parameters = try nitrogen_parameters.sourceParameters(),
        .nitrogen_molar_mass_g_per_mol = 14,
        .phosphorus_molar_mass_g_per_mol = 31,
        .mineral_exchange_parameters = testMineralExchangeParameters(),
        .microbial_surface_area_m2_per_g_c = 1.0e6,
        .timestep_h = 1,
    };
}

test "surface K5 mineral exchange uses nonstructural ratios and permits release" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var topsoil = try organic.State.init(std.testing.allocator, 1);
    defer topsoil.deinit();
    var litter = try chemistry.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    @memset(litter.ph, 6);
    var topsoil_chemistry_state = try soil_chemistry.State.init(std.testing.allocator, 1);
    defer topsoil_chemistry_state.deinit();
    var denit = try denitrification.State.init(std.testing.allocator, 1);
    defer denit.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var microbial_n = [_]f64{0.1} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    var microbial_p = [_]f64{0.01} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const first_ratio = (organic.autotrophic_substrate_index * organic.microbial_population_count + source_population_by_active[0]) * organic.kinetic_fraction_count;
    microbial_n[first_ratio] = 10;
    microbial_p[first_ratio] = 10;
    surface.microbial[microbialBase(0, source_population_by_active[0]) + 2] = .{ .carbon_g_c = 10, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    surface.microbial[microbialBase(0, source_population_by_active[1]) + 2] = .{ .carbon_g_c = 1, .nitrogen_g_n = 1, .phosphorus_g_p = 0.1 };
    state.active_biomass_g_c[0] = 1;
    state.active_biomass_g_c[1] = 1;
    state.mineral_exchange_share[0] = 0.5;
    state.mineral_exchange_share[1] = 0.5;
    litter.cells[0].ammonium_mol_per_m3 = 1;
    litter.cells[0].h2po4_mol_p_per_m3 = 1;
    const oxygen = [_]f64{1} ** (surface_respiration.unit_count_per_cell + active_population_count);
    const n_before = (try organicElementTotals(&surface, 0)).nitrogen_g_n + 14 * litter.cells[0].ammonium_mol_per_m3;
    const p_before = (try organicElementTotals(&surface, 0)).phosphorus_g_p + 31 * litter.cells[0].h2po4_mol_p_per_m3;
    var context = try focusedExchangeContext(&state, &surface, &litter, &denit, &gas_state, &topsoil, &topsoil_chemistry_state, &.{1}, &.{1}, &oxygen, &microbial_n, &microbial_p);
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.surface_ammonium_exchange_g_n[0] > 0 and state.surface_ammonium_exchange_g_n[0] <= 1);
    try std.testing.expect(state.surface_h2po4_exchange_g_p[0] > 0 and state.surface_h2po4_exchange_g_p[0] <= 0.1);
    try std.testing.expect(state.surface_ammonium_exchange_g_n[1] < 0);
    try std.testing.expect(state.surface_h2po4_exchange_g_p[1] < 0);
    const n_after = (try organicElementTotals(&surface, 0)).nitrogen_g_n + 14 * litter.cells[0].ammonium_mol_per_m3;
    const p_after = (try organicElementTotals(&surface, 0)).phosphorus_g_p + 31 * litter.cells[0].h2po4_mol_p_per_m3;
    try std.testing.expectApproxEqAbs(n_before, n_after, 128 * std.math.floatEps(f64) * @max(1, n_before));
    try std.testing.expectApproxEqAbs(p_before, p_after, 128 * std.math.floatEps(f64) * @max(1, p_before));
}

test "surface K5 mineral exchange follows alternate species then topsoil fallback" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    var surface = try organic.State.init(std.testing.allocator, 2);
    defer surface.deinit();
    var topsoil = try organic.State.init(std.testing.allocator, 2);
    defer topsoil.deinit();
    var litter = try chemistry.State.init(std.testing.allocator, 2);
    defer litter.deinit();
    @memset(litter.ph, 6);
    var topsoil_chemistry_state = try soil_chemistry.State.init(std.testing.allocator, 2);
    defer topsoil_chemistry_state.deinit();
    var denit = try denitrification.State.init(std.testing.allocator, 2);
    defer denit.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    const microbial_n = [_]f64{0.1} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const microbial_p = [_]f64{0.01} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    for (0..2) |cell| {
        surface.microbial[microbialBase(cell, source_population_by_active[0]) + 2] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
        state.active_biomass_g_c[cell * active_population_count] = 1;
        state.mineral_exchange_share[cell * active_population_count] = 1;
    }
    litter.cells[0].nitrate_mol_per_m3 = 1;
    litter.cells[0].hpo4_mol_p_per_m3 = 1;
    topsoil_chemistry_state.aqueous[1].ammonium_non_band = 1;
    topsoil_chemistry_state.non_band_phosphate[1].dissolved_h2po4_mol_p_per_m3 = 1;
    const oxygen = [_]f64{1} ** (2 * (surface_respiration.unit_count_per_cell + active_population_count));
    var context = try focusedExchangeContext(&state, &surface, &litter, &denit, &gas_state, &topsoil, &topsoil_chemistry_state, &.{ 1, 1 }, &.{ 1, 1 }, &oxygen, &microbial_n, &microbial_p);
    try applyTile(&context, .{ .first = 0, .end = 2 });
    try std.testing.expectEqual(@as(f64, 0), state.surface_ammonium_exchange_g_n[0]);
    try std.testing.expect(state.surface_nitrate_exchange_g_n[0] > 0);
    try std.testing.expectEqual(@as(f64, 0), state.surface_h2po4_exchange_g_p[0]);
    try std.testing.expect(state.surface_hpo4_exchange_g_p[0] > 0);
    const second = active_population_count;
    try std.testing.expectEqual(@as(f64, 0), state.surface_ammonium_exchange_g_n[second]);
    try std.testing.expect(state.topsoil_ammonium_exchange_g_n[second] > 0);
    try std.testing.expect(state.topsoil_h2po4_exchange_g_p[second] > 0);
}

test "surface autotrophic apply is atomic on a late invalid cell" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    var organic_state = try organic.State.init(std.testing.allocator, 2);
    defer organic_state.deinit();
    var topsoil_organic = try organic.State.init(std.testing.allocator, 2);
    defer topsoil_organic.deinit();
    var topsoil_chemistry_state = try soil_chemistry.State.init(std.testing.allocator, 2);
    defer topsoil_chemistry_state.deinit();
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 2);
    defer chemistry_state.deinit();
    @memset(chemistry_state.ph, 6);
    var denit = try denitrification.State.init(std.testing.allocator, 2);
    defer denit.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    @memset(state.potential_primary_reaction, 0);
    const cell_zero_labile = microbialBase(0, source_population_by_active[0]);
    organic_state.microbial[cell_zero_labile] = .{ .carbon_g_c = 4, .nitrogen_g_n = 0.668, .phosphorus_g_p = 0.0668 };
    organic_state.microbial[cell_zero_labile + 1] = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.25, .phosphorus_g_p = 0.025 };
    organic_state.residue[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    state.labile_maintenance_respiration_g_c[0] = 0.4;
    state.resistant_maintenance_respiration_g_c[0] = 0.2;
    state.maintenance_respiration_g_c[0] = 0.6;
    state.surface_ammonium_exchange_g_n[0] = -0.25;
    topsoil_chemistry_state.aqueous[0].ammonium_non_band = 0.75;
    state.potential_primary_reaction[active_population_count] = 2;
    chemistry_state.cells[0].ammonium_mol_per_m3 = 1;
    chemistry_state.cells[1].ammonium_mol_per_m3 = 0;
    const parameters = try nitrogen_parameters.sourceParameters();
    const microbial_n = [_]f64{0.167} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const microbial_p = [_]f64{0.0167} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const before = chemistry_state.cells[0];
    const topsoil_chemistry_before = topsoil_chemistry_state.aqueous[0];
    const surface_carbon_before = try organic_state.totalCarbon_g_c(0);
    const topsoil_carbon_before = try topsoil_organic.totalCarbon_g_c(0);
    const gas_carbon_before = gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)];
    var oxygen = [_]f64{1} ** (2 * (surface_respiration.unit_count_per_cell + active_population_count));
    var context: ApplyContext = .{ .state = &state, .surface_organic = &organic_state, .litter_chemistry = &chemistry_state, .litter_denitrification = &denit, .litter_gas = &gas_state, .litter_water_m3 = &.{ 1, 1 }, .topsoil_chemistry = &topsoil_chemistry_state, .topsoil_water_m3 = &.{ 1, 1 }, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .oxygen_satisfaction_fraction = &oxygen, .oxygen_unit_count_per_cell = surface_respiration.unit_count_per_cell + active_population_count, .first_autotrophic_oxygen_unit = surface_respiration.unit_count_per_cell, .topsoil_organic = &topsoil_organic, .soil_layer_capacity = 1, .topsoil_humus_partition = &.{ .{ 0.5, 0.5 }, .{ 0.5, 0.5 } }, .humification_fraction = &.{ 0.2, 0.2 }, .growth_temperature_response = &.{ 1, 1 }, .matric_plus_osmotic_potential_megapascal = &.{ 0, 0 }, .microbial_nitrogen_to_carbon_g_n_per_g_c = &microbial_n, .microbial_phosphorus_to_carbon_g_p_per_g_c = &microbial_p, .humus_nitrogen_per_carbon_g_n_per_g_c = 0.167, .humus_phosphorus_per_carbon_g_p_per_g_c = 0.0167, .negligible_carbon_g_c = 1e-12, .turnover_parameters = .{ .basal_decomposition_rate_per_h = .{ 0.01, 0.001 }, .minimum_carbon_recycling_fraction = 0.167, .carbon_recycling_range_fraction = 0.333, .maximum_nitrogen_recycling_fraction = 0.333, .maximum_phosphorus_recycling_fraction = 0.333, .dissolved_priming_rate_per_h = 0.01, .microbial_priming_rate_per_h = 0.001 }, .parameters = parameters, .nitrogen_molar_mass_g_per_mol = 14, .phosphorus_molar_mass_g_per_mol = 31, .mineral_exchange_parameters = testMineralExchangeParameters(), .microbial_surface_area_m2_per_g_c = 3, .timestep_h = 1 };
    try std.testing.expectError(error.InsufficientSurfaceAutotrophicAmmonium, applyTile(&context, .{ .first = 0, .end = 2 }));
    try std.testing.expectEqualDeep(before, chemistry_state.cells[0]);
    try std.testing.expectEqualDeep(topsoil_chemistry_before, topsoil_chemistry_state.aqueous[0]);
    try std.testing.expectEqual(surface_carbon_before, try organic_state.totalCarbon_g_c(0));
    try std.testing.expectEqual(topsoil_carbon_before, try topsoil_organic.totalCarbon_g_c(0));
    try std.testing.expectEqual(gas_carbon_before, gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)]);
    try std.testing.expectEqual(@as(f64, 0), state.actual_respiration_g_c[0]);
    try std.testing.expectEqual(@as(f64, -0.25), state.surface_ammonium_exchange_g_n[0]);
}

test "surface ammonia and nitrite oxidizers return respiratory carbon and close carbon" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.potential_primary_reaction[0] = 1;
    state.potential_respiration_g_c[0] = 0.1;
    state.potential_carbon_uptake_g_c[0] = 0.2;
    state.potential_nonstructural_carbon_gain_g_c[0] = 0.1;
    state.potential_primary_reaction[1] = 0.5;
    state.potential_respiration_g_c[1] = 0.05;
    state.potential_carbon_uptake_g_c[1] = 0.1;
    state.potential_nonstructural_carbon_gain_g_c[1] = 0.05;
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    var topsoil_organic = try organic.State.init(std.testing.allocator, 1);
    defer topsoil_organic.deinit();
    var topsoil_chemistry_state = try soil_chemistry.State.init(std.testing.allocator, 1);
    defer topsoil_chemistry_state.deinit();
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    @memset(chemistry_state.ph, 6);
    chemistry_state.cells[0].ammonium_mol_per_m3 = 1;
    chemistry_state.cells[0].h2po4_mol_p_per_m3 = 1;
    var denit = try denitrification.State.init(std.testing.allocator, 1);
    defer denit.deinit();
    denit.nitrite_g_n[0] = 2;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = 10;
    const parameters = try nitrogen_parameters.sourceParameters();
    const microbial_n = [_]f64{0.167} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const microbial_p = [_]f64{0.0167} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const carbon_before = try organic_state.totalCarbon_g_c(0) + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)];
    const oxygen = [_]f64{1} ** (surface_respiration.unit_count_per_cell + active_population_count);
    var context: ApplyContext = .{ .state = &state, .surface_organic = &organic_state, .litter_chemistry = &chemistry_state, .litter_denitrification = &denit, .litter_gas = &gas_state, .litter_water_m3 = &.{1}, .topsoil_chemistry = &topsoil_chemistry_state, .topsoil_water_m3 = &.{1}, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .oxygen_satisfaction_fraction = &oxygen, .oxygen_unit_count_per_cell = oxygen.len, .first_autotrophic_oxygen_unit = surface_respiration.unit_count_per_cell, .topsoil_organic = &topsoil_organic, .soil_layer_capacity = 1, .topsoil_humus_partition = &.{.{ 0.5, 0.5 }}, .humification_fraction = &.{0.2}, .growth_temperature_response = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &microbial_n, .microbial_phosphorus_to_carbon_g_p_per_g_c = &microbial_p, .humus_nitrogen_per_carbon_g_n_per_g_c = 0.167, .humus_phosphorus_per_carbon_g_p_per_g_c = 0.0167, .negligible_carbon_g_c = 1e-12, .turnover_parameters = .{ .basal_decomposition_rate_per_h = .{ 0.01, 0.001 }, .minimum_carbon_recycling_fraction = 0.167, .carbon_recycling_range_fraction = 0.333, .maximum_nitrogen_recycling_fraction = 0.333, .maximum_phosphorus_recycling_fraction = 0.333, .dissolved_priming_rate_per_h = 0.01, .microbial_priming_rate_per_h = 0.001 }, .parameters = parameters, .nitrogen_molar_mass_g_per_mol = 14, .phosphorus_molar_mass_g_per_mol = 31, .mineral_exchange_parameters = testMineralExchangeParameters(), .microbial_surface_area_m2_per_g_c = 3, .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const carbon_after = try organic_state.totalCarbon_g_c(0) + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)];
    try std.testing.expectApproxEqAbs(carbon_before, carbon_after, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 9.85), gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), try organic_state.totalCarbon_g_c(0), 1e-14);
}

test "surface autotrophs retain dry litter mineral concentrations" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    var topsoil_organic = try organic.State.init(std.testing.allocator, 1);
    defer topsoil_organic.deinit();
    var topsoil_chemistry_state = try soil_chemistry.State.init(std.testing.allocator, 1);
    defer topsoil_chemistry_state.deinit();
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    @memset(chemistry_state.ph, 6);
    chemistry_state.cells[0].ammonium_mol_per_m3 = 1.25;
    chemistry_state.cells[0].nitrate_mol_per_m3 = 2.5;
    chemistry_state.cells[0].h2po4_mol_p_per_m3 = 0.75;
    const before = chemistry_state.cells[0];
    var denit = try denitrification.State.init(std.testing.allocator, 1);
    defer denit.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    const oxygen = [_]f64{1} ** (surface_respiration.unit_count_per_cell + active_population_count);
    const microbial_n = [_]f64{0.167} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const microbial_p = [_]f64{0.0167} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    var context: ApplyContext = .{ .state = &state, .surface_organic = &organic_state, .litter_chemistry = &chemistry_state, .litter_denitrification = &denit, .litter_gas = &gas_state, .litter_water_m3 = &.{0}, .topsoil_chemistry = &topsoil_chemistry_state, .topsoil_water_m3 = &.{0}, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .oxygen_satisfaction_fraction = &oxygen, .oxygen_unit_count_per_cell = oxygen.len, .first_autotrophic_oxygen_unit = surface_respiration.unit_count_per_cell, .topsoil_organic = &topsoil_organic, .soil_layer_capacity = 1, .topsoil_humus_partition = &.{.{ 0.5, 0.5 }}, .humification_fraction = &.{0.2}, .growth_temperature_response = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &microbial_n, .microbial_phosphorus_to_carbon_g_p_per_g_c = &microbial_p, .humus_nitrogen_per_carbon_g_n_per_g_c = 0.167, .humus_phosphorus_per_carbon_g_p_per_g_c = 0.0167, .negligible_carbon_g_c = 1e-12, .turnover_parameters = .{ .basal_decomposition_rate_per_h = .{ 0.01, 0.001 }, .minimum_carbon_recycling_fraction = 0.167, .carbon_recycling_range_fraction = 0.333, .maximum_nitrogen_recycling_fraction = 0.333, .maximum_phosphorus_recycling_fraction = 0.333, .dissolved_priming_rate_per_h = 0.01, .microbial_priming_rate_per_h = 0.001 }, .parameters = try nitrogen_parameters.sourceParameters(), .nitrogen_molar_mass_g_per_mol = 14, .phosphorus_molar_mass_g_per_mol = 31, .mineral_exchange_parameters = testMineralExchangeParameters(), .microbial_surface_area_m2_per_g_c = 3, .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqualDeep(before, chemistry_state.cells[0]);
}

const OrganicElementTotals = struct { carbon_g_c: f64 = 0, nitrogen_g_n: f64 = 0, phosphorus_g_p: f64 = 0 };

fn organicElementTotals(state: *const organic.State, layer: usize) !OrganicElementTotals {
    if (layer >= state.layer_count) return error.OrganicInitializationLayerOutOfBounds;
    var result: OrganicElementTotals = .{};
    const pool_arrays = .{
        .{ state.microbial, organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count },
        .{ state.residue, organic.substrate_count * organic.residue_fraction_count },
        .{ state.dissolved, organic.substrate_count },
        .{ state.adsorbed, organic.substrate_count },
        .{ state.structural, organic.substrate_count * organic.structural_fraction_count },
    };
    inline for (pool_arrays) |entry| {
        for (entry[0][layer * entry[1] ..][0..entry[1]]) |pool| {
            result.carbon_g_c += pool.carbon_g_c;
            result.nitrogen_g_n += pool.nitrogen_g_n;
            result.phosphorus_g_p += pool.phosphorus_g_p;
        }
    }
    for (state.dissolved_acetate_carbon_g_c[layer * organic.substrate_count ..][0..organic.substrate_count]) |value| result.carbon_g_c += value;
    for (state.adsorbed_acetate_carbon_g_c[layer * organic.substrate_count ..][0..organic.substrate_count]) |value| result.carbon_g_c += value;
    return result;
}

test "surface K5 basal turnover and oxygen-limited senescence conserve C N P and route products" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const active: usize = 0;
    state.potential_respiration_g_c[active] = 0.25;
    state.potential_carbon_uptake_g_c[active] = 0.25;
    state.labile_maintenance_respiration_g_c[active] = 0.6;
    state.resistant_maintenance_respiration_g_c[active] = 0.4;
    state.maintenance_respiration_g_c[active] = 1;

    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    const microbial = microbialBase(0, source_population_by_active[active]);
    surface.microbial[microbial] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1.67, .phosphorus_g_p = 0.167 };
    surface.microbial[microbial + 1] = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.625, .phosphorus_g_p = 0.0625 };
    surface.residue[0] = .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.03 };
    surface.residue[organic.residue_fraction_count] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    surface.colonized_structural_carbon_g_c[0] = 20;

    var topsoil = try organic.State.init(std.testing.allocator, 1);
    defer topsoil.deinit();
    var topsoil_chemistry_state = try soil_chemistry.State.init(std.testing.allocator, 1);
    defer topsoil_chemistry_state.deinit();
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    @memset(chemistry_state.ph, 6);
    chemistry_state.cells[0].ammonium_mol_per_m3 = 1;
    chemistry_state.cells[0].nitrate_mol_per_m3 = 0.5;
    chemistry_state.cells[0].h2po4_mol_p_per_m3 = 0.25;
    var denit = try denitrification.State.init(std.testing.allocator, 1);
    defer denit.deinit();
    denit.nitrite_g_n[0] = 0.75;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    const co2 = @intFromEnum(gas.Species.carbon_dioxide);
    gas_state.dissolved_mass_g[co2] = 5;

    var microbial_n = [_]f64{0.167} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    var microbial_p = [_]f64{0.0167} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const ratio = (organic.autotrophic_substrate_index * organic.microbial_population_count + source_population_by_active[active]) * organic.kinetic_fraction_count;
    microbial_n[ratio + 1] = 0.125;
    microbial_p[ratio + 1] = 0.0125;
    var oxygen = [_]f64{1} ** (surface_respiration.unit_count_per_cell + active_population_count);
    oxygen[surface_respiration.unit_count_per_cell + active] = 0.4;
    const parameters = try nitrogen_parameters.sourceParameters();
    const surface_before = try organicElementTotals(&surface, 0);
    const soil_before = try organicElementTotals(&topsoil, 0);
    const carbon_before = surface_before.carbon_g_c + soil_before.carbon_g_c + gas_state.dissolved_mass_g[co2];
    const nitrogen_before = surface_before.nitrogen_g_n + soil_before.nitrogen_g_n +
        14 * (chemistry_state.cells[0].ammonium_mol_per_m3 + chemistry_state.cells[0].nitrate_mol_per_m3) + denit.nitrite_g_n[0];
    const phosphorus_before = surface_before.phosphorus_g_p + soil_before.phosphorus_g_p + 31 * chemistry_state.cells[0].h2po4_mol_p_per_m3;
    const residue_zero_before = surface.residue[0].carbon_g_c;
    const residue_one_before = surface.residue[organic.residue_fraction_count].carbon_g_c;
    const labile_before = surface.microbial[microbial].carbon_g_c;

    var accepted_topsoil_organic = [_]organic.ElementPool{.{}} ** active_population_count;
    var context: ApplyContext = .{
        .state = &state,
        .surface_organic = &surface,
        .litter_chemistry = &chemistry_state,
        .litter_denitrification = &denit,
        .litter_gas = &gas_state,
        .litter_water_m3 = &.{1},
        .topsoil_chemistry = &topsoil_chemistry_state,
        .topsoil_water_m3 = &.{1},
        .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
        .oxygen_satisfaction_fraction = &oxygen,
        .oxygen_unit_count_per_cell = oxygen.len,
        .first_autotrophic_oxygen_unit = surface_respiration.unit_count_per_cell,
        .topsoil_organic = &topsoil,
        .soil_layer_capacity = 1,
        .topsoil_humus_partition = &.{.{ 0.25, 0.75 }},
        .humification_fraction = &.{0.2},
        .growth_temperature_response = &.{1},
        .matric_plus_osmotic_potential_megapascal = &.{0},
        .microbial_nitrogen_to_carbon_g_n_per_g_c = &microbial_n,
        .microbial_phosphorus_to_carbon_g_p_per_g_c = &microbial_p,
        .humus_nitrogen_per_carbon_g_n_per_g_c = 0.167,
        .humus_phosphorus_per_carbon_g_p_per_g_c = 0.0167,
        .negligible_carbon_g_c = 1e-12,
        .turnover_parameters = .{
            .basal_decomposition_rate_per_h = .{ 0.01, 0.001 },
            .minimum_carbon_recycling_fraction = 0.167,
            .carbon_recycling_range_fraction = 0.333,
            .maximum_nitrogen_recycling_fraction = 0.333,
            .maximum_phosphorus_recycling_fraction = 0.333,
            .dissolved_priming_rate_per_h = 0.01,
            .microbial_priming_rate_per_h = 0.001,
        },
        .parameters = parameters,
        .nitrogen_molar_mass_g_per_mol = 14,
        .phosphorus_molar_mass_g_per_mol = 31,
        .mineral_exchange_parameters = testMineralExchangeParameters(),
        .microbial_surface_area_m2_per_g_c = 3,
        .timestep_h = 1,
        .accepted_topsoil_organic_transfer = &accepted_topsoil_organic,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });

    const surface_after = try organicElementTotals(&surface, 0);
    const soil_after = try organicElementTotals(&topsoil, 0);
    const carbon_after = surface_after.carbon_g_c + soil_after.carbon_g_c + gas_state.dissolved_mass_g[co2];
    const nitrogen_after = surface_after.nitrogen_g_n + soil_after.nitrogen_g_n +
        14 * (chemistry_state.cells[0].ammonium_mol_per_m3 + chemistry_state.cells[0].nitrate_mol_per_m3) + denit.nitrite_g_n[0];
    const phosphorus_after = surface_after.phosphorus_g_p + soil_after.phosphorus_g_p + 31 * chemistry_state.cells[0].h2po4_mol_p_per_m3;
    const roundoff = 128 * std.math.floatEps(f64);
    try std.testing.expectApproxEqAbs(carbon_before, carbon_after, roundoff * @max(1, carbon_before));
    try std.testing.expectApproxEqAbs(nitrogen_before, nitrogen_after, roundoff * @max(1, nitrogen_before));
    try std.testing.expectApproxEqAbs(phosphorus_before, phosphorus_after, roundoff * @max(1, phosphorus_before));
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.actual_respiration_g_c[active], roundoff);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.actual_carbon_uptake_g_c[active], roundoff);
    try std.testing.expect(gas_state.dissolved_mass_g[co2] > 5);
    try std.testing.expect(surface.microbial[microbial].carbon_g_c < labile_before);
    const residue_zero_gain = surface.residue[0].carbon_g_c - residue_zero_before;
    const residue_one_gain = surface.residue[organic.residue_fraction_count].carbon_g_c - residue_one_before;
    try std.testing.expect(residue_zero_gain > 0 and residue_one_gain > 0);
    try std.testing.expectApproxEqAbs(residue_zero_gain, 3 * residue_one_gain, roundoff * @max(1, residue_zero_gain));
    const humus_zero = topsoil.structural[(4 * organic.structural_fraction_count)].carbon_g_c;
    const humus_one = topsoil.structural[(4 * organic.structural_fraction_count) + 1].carbon_g_c;
    try std.testing.expect(humus_zero > 0);
    try std.testing.expectApproxEqAbs(humus_one, 3 * humus_zero, roundoff * @max(1, humus_one));
    try std.testing.expectApproxEqAbs(soil_after.carbon_g_c - soil_before.carbon_g_c, accepted_topsoil_organic[active].carbon_g_c, roundoff * @max(1, soil_after.carbon_g_c));
    try std.testing.expectApproxEqAbs(soil_after.nitrogen_g_n - soil_before.nitrogen_g_n, accepted_topsoil_organic[active].nitrogen_g_n, roundoff * @max(1, soil_after.nitrogen_g_n));
    try std.testing.expectApproxEqAbs(soil_after.phosphorus_g_p - soil_before.phosphorus_g_p, accepted_topsoil_organic[active].phosphorus_g_p, roundoff * @max(1, soil_after.phosphorus_g_p));
}

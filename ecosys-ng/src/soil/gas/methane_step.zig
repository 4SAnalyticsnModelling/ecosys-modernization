const std = @import("std");
const compute = @import("../../core/compute.zig");
const gas = @import("transport.zig");
const anaerobic = @import("../microbial/anaerobic_growth_respiration.zig");
const methanogenesis = @import("../microbial/methanogenesis.zig");
const oxidation = @import("methane_oxidation.zig");
const microbial = @import("../microbial/state.zig");
const metabolism = @import("../microbial/metabolism.zig");
const respiration_activity = @import("../microbial/respiration_activity.zig");
const organic = @import("../organic/initialization.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const oxygen_allocation = @import("oxygen_allocation.zig");

pub const Parameters = struct {
    hydrogenotrophic: methanogenesis.HydrogenotrophicParameters,
    methane_half_saturation_g_c_per_m3: f64,
    methane_solubility_water_to_air: f64,
    gas_exchange_rate_per_step: f64,
    biomass_conversion_efficiency_g_c_per_g_c: f64,
    methanotroph_growth_respiration_g_c_per_g_c: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    gaseous_methane_after_g_c: []f64,
    aqueous_methane_after_g_c: []f64,
    hydrogenotrophic_methane_g_c: []f64,
    hydrogenotrophic_carbon_dioxide_uptake_g_c: []f64,
    hydrogenotrophic_nonstructural_carbon_gain_g_c: []f64,
    hydrogen_consumption_g_h: []f64,
    // `methane_oxidation_combustion_g_c` is the full CH4->CO2 combustion
    // term (5.333 g O2 per g C); `methane_oxidation_respiration_g_c` is the
    // growth respiration term (2.667 g O2 per g C). Gross CH4 uptake is
    // routed separately to respiration plus methanotroph nonstructural C.
    methane_oxidation_combustion_g_c: []f64,
    methane_oxidation_respiration_g_c: []f64,
    methanotroph_methane_uptake_g_c: []f64,
    methanotroph_nonstructural_carbon_gain_g_c: []f64,
    oxygen_demand_g_o: []f64,
    solver_iterations: []u16,
    fermentation_hydrogen_production_g_h: []f64,
    acetotrophic_methane_production_g_c: []f64,
    hydrogenotroph_active_biomass_g_c: []f64,
    methanotroph_active_biomass_g_c: []f64,
    hydrogenotroph_maintenance_respiration_g_c: []f64,
    methanotroph_maintenance_respiration_g_c: []f64,
    temperature_water_response: []f64,
    hydrogenotroph_nutrient_limitation_fraction: []f64,
    methanotroph_nutrient_limitation_fraction: []f64,
    aqueous_co2_limitation_fraction: []f64,
    hydrogen_feedback_energy_kj_per_mol: []f64,
    unoxidized_gaseous_methane_after_g_c: []f64,
    unoxidized_aqueous_methane_after_g_c: []f64,
    potential_gaseous_methane_after_g_c: []f64,
    potential_aqueous_methane_after_g_c: []f64,
    potential_methane_oxidation_combustion_g_c: []f64,
    potential_methane_oxidation_respiration_g_c: []f64,
    potential_methanotroph_methane_uptake_g_c: []f64,
    potential_methanotroph_nonstructural_carbon_gain_g_c: []f64,
    potential_oxygen_demand_g_o: []f64,

    /// Releases the successfully allocated `[]f64` prefix from `init` in
    /// field order. This reflected cleanup is deliberately out of line so
    /// each fallible allocation does not receive another unrolled copy.
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

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        @setEvalBranchQuota(3000);
        if (layer_count == 0) return error.InvalidSoilMethaneDimensions;
        var result: State = undefined;
        result.allocator = allocator;
        result.layer_count = layer_count;
        var allocated_f64: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated_f64);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, layer_count);
            allocated_f64 += 1;
            @memset(@field(result, field.name), 0);
        };
        result.solver_iterations = try allocator.alloc(u16, layer_count);
        @memset(result.solver_iterations, 0);
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.solver_iterations);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

test "soil methane state releases every partial allocation prefix" {
    const f64_allocation_count = comptime count: {
        var count: usize = 0;
        for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) count += 1;
        }
        break :count count;
    };

    // Include the final `solver_iterations` allocation after the reflected
    // f64 fields; its failure must release the complete f64 prefix.
    for (0..f64_allocation_count + 1) |fail_index| {
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

pub const PrepareContext = struct {
    result: *State,
    microbial_state: *const microbial.State,
    flux_workspace: *fluxes.State,
    gas_state: *const gas.State,
    water_volume_m3: []const f64,
    soil_temperature_k: []const f64,
    matric_plus_osmotic_potential_megapascal: []const f64,
    autotrophic_substrate_index: usize,
    hydrogenotroph_population_index: usize,
    methanotroph_population_index: usize,
    labile_biomass_fraction: f64,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    microbial_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    aqueous_co2_half_saturation_g_c_per_m3: f64,
    hydrogen_product_inhibition_g_h_per_m3: f64,
    gas_constant_kj_per_mol_k: f64,
    minimum_hydrogen_concentration_g_h_per_m3: f64,
    hydrogen_feedback_stoichiometric_exponent: f64,
    thermal_adaptation_offset_k_by_cell: []const f64,
    methanotroph_specific_oxidation_per_h: f64,
    parameters: Parameters,
    timestep_h: f64,
    solver_options: oxidation.Options,
};

/// Exact NITRO.F 341--347 aqueous CO2 constraint on autotrophic uptake.
pub fn aqueousCo2LimitationFraction(
    aqueous_co2_concentration_g_c_per_m3: f64,
    half_saturation_g_c_per_m3: f64,
) !f64 {
    if (!std.math.isFinite(aqueous_co2_concentration_g_c_per_m3) or
        aqueous_co2_concentration_g_c_per_m3 < 0 or
        !std.math.isFinite(half_saturation_g_c_per_m3) or
        half_saturation_g_c_per_m3 <= 0)
        return error.InvalidAqueousCarbonDioxideLimitation;
    const result = aqueous_co2_concentration_g_c_per_m3 /
        (aqueous_co2_concentration_g_c_per_m3 + half_saturation_g_c_per_m3);
    if (!std.math.isFinite(result) or result < 0 or result > 1)
        return error.NonFiniteAqueousCarbonDioxideLimitation;
    return result;
}

/// Exact NITRO.F 556--557 GH2X operation order.
pub fn hydrogenFeedbackEnergy_kj_per_mol(
    soil_temperature_k: f64,
    aqueous_hydrogen_concentration_g_h_per_m3: f64,
    product_inhibition_g_h_per_m3: f64,
    gas_constant_kj_per_mol_k: f64,
    minimum_hydrogen_concentration_g_h_per_m3: f64,
    stoichiometric_exponent: f64,
) !f64 {
    inline for (.{
        soil_temperature_k,
        aqueous_hydrogen_concentration_g_h_per_m3,
        product_inhibition_g_h_per_m3,
        gas_constant_kj_per_mol_k,
        minimum_hydrogen_concentration_g_h_per_m3,
        stoichiometric_exponent,
    }) |value| if (!std.math.isFinite(value))
        return error.InvalidHydrogenFeedbackEnvironment;
    if (soil_temperature_k <= 0 or
        aqueous_hydrogen_concentration_g_h_per_m3 < 0 or
        product_inhibition_g_h_per_m3 <= 0 or
        gas_constant_kj_per_mol_k <= 0 or
        minimum_hydrogen_concentration_g_h_per_m3 <= 0 or
        stoichiometric_exponent <= 0)
        return error.InvalidHydrogenFeedbackEnvironment;
    const bounded_concentration = @max(
        minimum_hydrogen_concentration_g_h_per_m3,
        aqueous_hydrogen_concentration_g_h_per_m3,
    );
    const feedback = gas_constant_kj_per_mol_k * soil_temperature_k *
        anaerobic.sourceOrderedLogPositiveRatioPower(
            bounded_concentration,
            product_inhibition_g_h_per_m3,
            stoichiometric_exponent,
        );
    if (!std.math.isFinite(feedback))
        return error.NonFiniteHydrogenFeedbackEnvironment;
    return feedback;
}

const PreparedLayer = struct {
    fermentation_hydrogen_g_h: f64,
    acetotrophic_methane_g_c: f64,
    active_hydrogen_g_c: f64,
    active_methane_g_c: f64,
    hydrogen_maintenance_g_c: f64,
    methane_maintenance_g_c: f64,
    temperature_water: f64,
    hydrogen_nutrient: f64,
    methane_nutrient: f64,
    co2_limitation: f64,
    hydrogen_feedback: f64,
    unoxidized: oxidation.Result,
    potential: oxidation.Result,
    oxygen_fallback_active_fraction: f64,
};

/// NITRO.F 1291--1444 prepares methanogenesis and CH4-unlimited oxidation
/// before the sole shared O2 allocation. The prepared N=3,K=5 demand is
/// published into the ordinary process-unit workspace so it competes with
/// every other aerobic population at 1458--1486.
pub fn prepareTile(context: *PrepareContext, range: compute.CellRange) !void {
    try validatePrepare(context.*, range);
    // Tile preflight: failed preparation cannot leak a demand into the shared
    // O2 owner or leave a partial derived methane record behind.
    for (range.first..range.end) |layer| _ = try calculatePreparedLayer(context.*, layer);
    for (range.first..range.end) |layer| {
        const value = try calculatePreparedLayer(context.*, layer);
        const methane_unit = layer * context.flux_workspace.process_unit_count_per_layer + context.autotrophic_substrate_index * context.microbial_state.population_count + context.methanotroph_population_index;
        context.result.fermentation_hydrogen_production_g_h[layer] = value.fermentation_hydrogen_g_h;
        context.result.acetotrophic_methane_production_g_c[layer] = value.acetotrophic_methane_g_c;
        context.result.hydrogenotroph_active_biomass_g_c[layer] = value.active_hydrogen_g_c;
        context.result.methanotroph_active_biomass_g_c[layer] = value.active_methane_g_c;
        context.result.hydrogenotroph_maintenance_respiration_g_c[layer] = value.hydrogen_maintenance_g_c;
        context.result.methanotroph_maintenance_respiration_g_c[layer] = value.methane_maintenance_g_c;
        context.result.temperature_water_response[layer] = value.temperature_water;
        context.result.hydrogenotroph_nutrient_limitation_fraction[layer] = value.hydrogen_nutrient;
        context.result.methanotroph_nutrient_limitation_fraction[layer] = value.methane_nutrient;
        context.result.aqueous_co2_limitation_fraction[layer] = value.co2_limitation;
        context.result.hydrogen_feedback_energy_kj_per_mol[layer] = value.hydrogen_feedback;
        context.result.unoxidized_gaseous_methane_after_g_c[layer] = value.unoxidized.gaseous_methane_g_c;
        context.result.unoxidized_aqueous_methane_after_g_c[layer] = value.unoxidized.aqueous_methane_g_c;
        context.result.potential_gaseous_methane_after_g_c[layer] = value.potential.gaseous_methane_g_c;
        context.result.potential_aqueous_methane_after_g_c[layer] = value.potential.aqueous_methane_g_c;
        context.result.potential_methane_oxidation_combustion_g_c[layer] = value.potential.methane_oxidation_g_c;
        context.result.potential_methane_oxidation_respiration_g_c[layer] = value.potential.growth_respiration_g_c;
        context.result.potential_methanotroph_methane_uptake_g_c[layer] = value.potential.methane_carbon_uptake_g_c;
        context.result.potential_methanotroph_nonstructural_carbon_gain_g_c[layer] = value.potential.nonstructural_carbon_gain_g_c;
        context.result.potential_oxygen_demand_g_o[layer] = value.potential.oxygen_demand_g_o;
        context.result.solver_iterations[layer] = value.potential.iterations;
        context.flux_workspace.aerobic_oxygen_demand_g_o[methane_unit] = value.potential.oxygen_demand_g_o;
        context.flux_workspace.aerobic_active_biomass_g_c[methane_unit] = value.active_methane_g_c;
        context.flux_workspace.aerobic_fallback_active_fraction[methane_unit] = value.oxygen_fallback_active_fraction;
    }
}

fn calculatePreparedLayer(context: PrepareContext, layer: usize) !PreparedLayer {
    var fermentation_hydrogen_g_h: f64 = 0;
    var acetotrophic_methane_g_c: f64 = 0;
    const populations = context.microbial_state.population_count;
    const first = layer * context.flux_workspace.process_unit_count_per_layer;
    for (0..@min(context.microbial_state.substrate_count, organic.substrate_count)) |substrate| for (0..populations) |population| {
        const unit = first + substrate * populations + population;
        const respiration_g_c = context.flux_workspace.substrate_limited_respiration_g_c[unit];
        switch (respiration_activity.sourceMetabolism(population)) {
            .fermenting_heterotroph => fermentation_hydrogen_g_h += 0.111 * respiration_g_c,
            .acetotrophic_methanogen => acetotrophic_methane_g_c += 0.5 * respiration_g_c,
            .aerobic_heterotroph => {},
        }
    };
    const substrate = context.autotrophic_substrate_index;
    const hydrogen_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, context.hydrogenotroph_population_index);
    const methane_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, context.methanotroph_population_index);
    const hydrogen_unit = first + substrate * populations + context.hydrogenotroph_population_index;
    const methane_unit = first + substrate * populations + context.methanotroph_population_index;
    const hydrogen_labile = context.microbial_state.structural[hydrogen_index * 2];
    const methane_labile = context.microbial_state.structural[methane_index * 2];
    const active_hydrogen = hydrogen_labile.carbon_g_c / context.labile_biomass_fraction;
    const active_methane = methane_labile.carbon_g_c / context.labile_biomass_fraction;
    const hydrogen_nutrient = try populationNutrientLimitation(context, hydrogen_labile, substrate, context.hydrogenotroph_population_index);
    const methane_nutrient = try populationNutrientLimitation(context, methane_labile, substrate, context.methanotroph_population_index);
    const temperature_water = try metabolism.growthTemperatureResponse(context.soil_temperature_k[layer], context.thermal_adaptation_offset_k_by_cell[layer / context.microbial_state.layer_count]) * @exp(0.1 * context.matric_plus_osmotic_potential_megapascal[layer]);
    const water_m3 = context.water_volume_m3[layer];
    const methane_mass_index = try gas.massIndex(layer, .methane, context.result.layer_count);
    if (water_m3 <= 0) {
        // nitro.f:1398 `IF(VOLWM(M,L).GT.ZEROS2)` skips CH4 dissolution/oxidation
        // on a dry layer. It does not fatal, and it does not destroy CH4 mass.
        const held = oxidation.Result{
            .gaseous_methane_g_c = context.gas_state.gaseous_mass_g[methane_mass_index],
            .aqueous_methane_g_c = context.gas_state.dissolved_mass_g[methane_mass_index],
            .methane_oxidation_g_c = 0,
            .growth_respiration_g_c = 0,
            .methane_carbon_uptake_g_c = 0,
            .nonstructural_carbon_gain_g_c = 0,
            .gas_to_water_exchange_g_c = 0,
            .oxygen_demand_g_o = 0,
            .iterations = 0,
            .newton_raphson_steps = 0,
            .picard_steps = 0,
            .residual_g_c = 0,
        };
        return .{
            .fermentation_hydrogen_g_h = fermentation_hydrogen_g_h,
            .acetotrophic_methane_g_c = acetotrophic_methane_g_c,
            .active_hydrogen_g_c = active_hydrogen,
            .active_methane_g_c = active_methane,
            .hydrogen_maintenance_g_c = context.flux_workspace.total_maintenance_respiration_g_c[hydrogen_unit],
            .methane_maintenance_g_c = context.flux_workspace.total_maintenance_respiration_g_c[methane_unit],
            .temperature_water = temperature_water,
            .hydrogen_nutrient = hydrogen_nutrient,
            .methane_nutrient = methane_nutrient,
            .co2_limitation = 0,
            .hydrogen_feedback = 0,
            .unoxidized = held,
            .potential = held,
            .oxygen_fallback_active_fraction = 0,
        };
    }
    const co2_index = try gas.massIndex(layer, .carbon_dioxide, context.result.layer_count);
    const hydrogen_mass_index = try gas.massIndex(layer, .hydrogen, context.result.layer_count);
    const co2 = context.gas_state.dissolved_mass_g[co2_index] / water_m3;
    const h2 = context.gas_state.dissolved_mass_g[hydrogen_mass_index] / water_m3;
    const co2_limitation = try aqueousCo2LimitationFraction(co2, context.aqueous_co2_half_saturation_g_c_per_m3);
    const hydrogen_feedback = try hydrogenFeedbackEnergy_kj_per_mol(context.soil_temperature_k[layer], h2, context.hydrogen_product_inhibition_g_h_per_m3, context.gas_constant_kj_per_mol_k, context.minimum_hydrogen_concentration_g_h_per_m3, context.hydrogen_feedback_stoichiometric_exponent);
    const hydrogen_result = try methanogenesis.hydrogenotrophic(.{
        .aqueous_hydrogen_concentration_g_h_per_m3 = h2,
        .aqueous_hydrogen_g_h = context.gas_state.dissolved_mass_g[hydrogen_mass_index],
        .fermentation_hydrogen_production_g_h = fermentation_hydrogen_g_h,
        .temperature_water_response = temperature_water,
        .nutrient_limitation_fraction = hydrogen_nutrient,
        .aqueous_co2_limitation_fraction = co2_limitation,
        .active_biomass_g_c = active_hydrogen,
        .timestep_h = context.timestep_h,
        .hydrogen_feedback_energy_kj_per_mol = hydrogen_feedback,
    }, context.parameters.hydrogenotrophic);
    const hydrogen_routing = try routeAutotrophicCarbon(hydrogen_result.co2_reduction_g_c, context.flux_workspace.total_maintenance_respiration_g_c[hydrogen_unit], hydrogen_result.growth_respiration_fraction, context.gas_state.dissolved_mass_g[co2_index]);
    const methane_production_g_c = acetotrophic_methane_g_c + hydrogen_routing.respiration_g_c;
    const kinetic_maximum_oxidation = context.methanotroph_specific_oxidation_per_h * temperature_water * methane_nutrient * active_methane * context.timestep_h;
    const common: oxidation.Inputs = .{
        .gaseous_methane_g_c = context.gas_state.gaseous_mass_g[methane_mass_index],
        .aqueous_methane_g_c = context.gas_state.dissolved_mass_g[methane_mass_index],
        .gaseous_methane_flux_g_c = 0,
        .aqueous_methane_flux_g_c = 0,
        .methanogenesis_g_c = methane_production_g_c,
        .water_volume_m3 = water_m3,
        .air_volume_m3 = context.gas_state.air_volume_m3[layer],
        .methane_solubility_water_to_air = context.parameters.methane_solubility_water_to_air,
        .gas_exchange_rate_per_step = context.parameters.gas_exchange_rate_per_step,
        .gas_exchange_enabled = context.gas_state.air_volume_m3[layer] > 0,
        .methane_half_saturation_g_c_per_m3 = context.parameters.methane_half_saturation_g_c_per_m3,
        .maximum_methane_oxidation_g_c = kinetic_maximum_oxidation,
        .biomass_conversion_efficiency_g_c_per_g_c = context.parameters.biomass_conversion_efficiency_g_c_per_g_c,
        .growth_respiration_g_c_per_g_c = context.parameters.methanotroph_growth_respiration_g_c_per_g_c,
        .maintenance_respiration_g_c = context.flux_workspace.total_maintenance_respiration_g_c[methane_unit],
    };
    const potential = try oxidation.solve(common, context.solver_options);
    var unoxidized_inputs = common;
    unoxidized_inputs.maximum_methane_oxidation_g_c = 0;
    const unoxidized = try oxidation.solve(unoxidized_inputs, context.solver_options);
    var total_active = active_methane;
    for (context.flux_workspace.aerobic_active_biomass_g_c[first .. first + context.flux_workspace.process_unit_count_per_layer], 0..) |active, local| {
        if (local != substrate * populations + context.methanotroph_population_index) total_active += active;
    }
    const fallback = if (total_active > 0) active_methane / total_active else 0;
    inline for (.{ fermentation_hydrogen_g_h, acetotrophic_methane_g_c, active_hydrogen, active_methane, temperature_water, hydrogen_nutrient, methane_nutrient, co2_limitation, fallback }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilMethaneInput;
    // GH2X is a signed thermodynamic feedback. It is negative below the H2KI
    // reference, zero at the reference, and positive above it (NITRO.F
    // 556--557); only non-finiteness is invalid.
    if (!std.math.isFinite(hydrogen_feedback))
        return error.InvalidSoilMethaneInput;
    return .{
        .fermentation_hydrogen_g_h = fermentation_hydrogen_g_h,
        .acetotrophic_methane_g_c = acetotrophic_methane_g_c,
        .active_hydrogen_g_c = active_hydrogen,
        .active_methane_g_c = active_methane,
        .hydrogen_maintenance_g_c = context.flux_workspace.total_maintenance_respiration_g_c[hydrogen_unit],
        .methane_maintenance_g_c = context.flux_workspace.total_maintenance_respiration_g_c[methane_unit],
        .temperature_water = temperature_water,
        .hydrogen_nutrient = hydrogen_nutrient,
        .methane_nutrient = methane_nutrient,
        .co2_limitation = co2_limitation,
        .hydrogen_feedback = hydrogen_feedback,
        .unoxidized = unoxidized,
        .potential = potential,
        .oxygen_fallback_active_fraction = fallback,
    };
}

fn populationNutrientLimitation(context: PrepareContext, labile: microbial.ElementalPool, substrate: usize, population: usize) !f64 {
    const ratio = (substrate * context.microbial_state.population_count + population) * organic.kinetic_fraction_count;
    const target_n = context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio];
    const target_p = context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio];
    if (!std.math.isFinite(target_n) or target_n <= 0 or !std.math.isFinite(target_p) or target_p <= 0) return error.InvalidSoilMethaneTargetRatio;
    return nutrientLimitation(labile, target_n, target_p);
}

fn nutrientLimitation(labile: microbial.ElementalPool, target_n: f64, target_p: f64) !f64 {
    if (!std.math.isFinite(target_n) or target_n <= 0 or !std.math.isFinite(target_p) or target_p <= 0) return error.InvalidSoilMethaneTargetRatio;
    const actual_n = if (labile.carbon_g_c > 0) labile.nitrogen_g_n / labile.carbon_g_c else target_n;
    const actual_p = if (labile.carbon_g_c > 0) labile.phosphorus_g_p / labile.carbon_g_c else target_p;
    const n_factor = @min(1.0, @max(0.1, std.math.pow(f64, actual_n / target_n, 0.25)));
    const p_factor = @min(1.0, @max(0.1, std.math.pow(f64, actual_p / target_p, 0.25)));
    const result = @min(n_factor, p_factor);
    if (!std.math.isFinite(result)) return error.InvalidSoilMethaneTargetRatio;
    return result;
}

fn validatePrepare(context: PrepareContext, range: compute.CellRange) !void {
    const n = context.result.layer_count;
    const ratio_count = context.microbial_state.substrate_count * context.microbial_state.population_count * organic.kinetic_fraction_count;
    if (range.first > range.end or range.end > n or context.gas_state.cell_count != n or context.flux_workspace.layer_count != n or context.flux_workspace.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or context.water_volume_m3.len != n or context.soil_temperature_k.len != n or context.matric_plus_osmotic_potential_megapascal.len != n or context.thermal_adaptation_offset_k_by_cell.len != context.microbial_state.cell_count or context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != ratio_count or context.microbial_phosphorus_to_carbon_g_p_per_g_c.len != ratio_count) return error.InvalidSoilMethaneDimensions;
    for (context.thermal_adaptation_offset_k_by_cell) |offset_k| if (!std.math.isFinite(offset_k)) return error.NonFiniteMicrobialThermalAdaptationOffset;
    if (context.autotrophic_substrate_index >= context.microbial_state.substrate_count or context.hydrogenotroph_population_index >= context.microbial_state.population_count or context.methanotroph_population_index >= context.microbial_state.population_count or context.labile_biomass_fraction <= 0 or context.hydrogen_product_inhibition_g_h_per_m3 <= 0 or !std.math.isFinite(context.aqueous_co2_half_saturation_g_c_per_m3) or context.aqueous_co2_half_saturation_g_c_per_m3 <= 0 or !std.math.isFinite(context.gas_constant_kj_per_mol_k) or context.gas_constant_kj_per_mol_k <= 0 or !std.math.isFinite(context.minimum_hydrogen_concentration_g_h_per_m3) or context.minimum_hydrogen_concentration_g_h_per_m3 <= 0 or !std.math.isFinite(context.hydrogen_feedback_stoichiometric_exponent) or context.hydrogen_feedback_stoichiometric_exponent <= 0 or !std.math.isFinite(context.methanotroph_specific_oxidation_per_h) or context.methanotroph_specific_oxidation_per_h < 0 or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.InvalidSoilMethaneInput;
}

test "NITRO 341-347 aqueous CO2 limitation preserves source quotient" {
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.8),
        try aqueousCo2LimitationFraction(4, 1),
        1e-15,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        try aqueousCo2LimitationFraction(0, 1),
    );
}

test "NITRO aqueous CO2 limitation rejects invalid runtime half saturation" {
    try std.testing.expectError(
        error.InvalidAqueousCarbonDioxideLimitation,
        aqueousCo2LimitationFraction(1, 0),
    );
    try std.testing.expectError(
        error.InvalidAqueousCarbonDioxideLimitation,
        aqueousCo2LimitationFraction(std.math.nan(f64), 1),
    );
}

test "NITRO 556-557 hydrogen feedback preserves source operation order" {
    const expected = 8.3143e-3 * 300 *
        @log(std.math.pow(f64, @max(1.0e-3, 2.0) / 1.0, 4.0));
    try std.testing.expectEqual(
        expected,
        try hydrogenFeedbackEnergy_kj_per_mol(
            300,
            2,
            1,
            8.3143e-3,
            1.0e-3,
            4,
        ),
    );
    try std.testing.expectError(
        error.InvalidHydrogenFeedbackEnvironment,
        hydrogenFeedbackEnergy_kj_per_mol(300, -1, 1, 8.3143e-3, 1.0e-3, 4),
    );
}

test "NITRO hydrogen feedback remains finite across intermediate power range" {
    const gas_constant: f64 = 8.3143e-3;
    const temperature: f64 = 300;
    const exponent: f64 = 4;

    // The source power overflows in binary64 although its logarithm and final
    // feedback energy are finite.
    const high_concentration: f64 = 1e100;
    const high_expected = gas_constant * temperature * exponent *
        @log(high_concentration);
    const high_feedback = try hydrogenFeedbackEnergy_kj_per_mol(
        temperature,
        high_concentration,
        1,
        gas_constant,
        1e-3,
        exponent,
    );
    try std.testing.expect(std.math.isFinite(high_feedback));
    try std.testing.expectApproxEqRel(high_expected, high_feedback, 1e-15);

    // The ratio itself overflows, but log(c/k) is still representable.
    const extreme_feedback = try hydrogenFeedbackEnergy_kj_per_mol(
        temperature,
        std.math.floatMax(f64),
        std.math.floatMin(f64),
        gas_constant,
        1e-3,
        exponent,
    );
    const extreme_expected = gas_constant * temperature * exponent *
        (@log(std.math.floatMax(f64)) - @log(std.math.floatMin(f64)));
    try std.testing.expect(std.math.isFinite(extreme_feedback));
    try std.testing.expectApproxEqRel(extreme_expected, extreme_feedback, 1e-15);

    // Conversely, a representable numerator/reference pair may underflow
    // during division.  Its logarithmic feedback remains finite.
    const tiny_feedback = try hydrogenFeedbackEnergy_kj_per_mol(
        temperature,
        0,
        1e100,
        gas_constant,
        std.math.floatMin(f64),
        exponent,
    );
    const tiny_expected = gas_constant * temperature * exponent *
        (@log(std.math.floatMin(f64)) - @log(@as(f64, 1e100)));
    try std.testing.expect(std.math.isFinite(tiny_feedback));
    try std.testing.expectApproxEqRel(tiny_expected, tiny_feedback, 1e-15);
}

pub const ApplyContext = struct {
    result: *State,
    gas_state: *const gas.State,
    oxygen_state: *const oxygen_allocation.State,
    process_unit_count_per_layer: usize,
    microbial_population_count: usize,
    autotrophic_substrate_index: usize,
    methanotroph_population_index: usize,
    water_volume_m3: []const f64,
    fermentation_hydrogen_production_g_h: []const f64,
    acetotrophic_methane_production_g_c: []const f64,
    hydrogenotroph_active_biomass_g_c: []const f64,
    methanotroph_active_biomass_g_c: []const f64,
    hydrogenotroph_maintenance_respiration_g_c: []const f64,
    methanotroph_maintenance_respiration_g_c: []const f64,
    temperature_water_response: []const f64,
    hydrogenotroph_nutrient_limitation_fraction: []const f64,
    methanotroph_nutrient_limitation_fraction: []const f64,
    aqueous_co2_limitation_fraction: []const f64,
    hydrogen_feedback_energy_kj_per_mol: []const f64,
    parameters: Parameters,
    timestep_h: f64,
};

const RoutedCarbon = struct {
    respiration_g_c: f64,
    gross_uptake_g_c: f64,
    nonstructural_gain_g_c: f64,
};

const LayerResult = struct {
    gaseous_methane_after_g_c: f64,
    aqueous_methane_after_g_c: f64,
    hydrogenotrophic_methane_g_c: f64,
    hydrogenotrophic_carbon_dioxide_uptake_g_c: f64,
    hydrogenotrophic_nonstructural_carbon_gain_g_c: f64,
    hydrogen_consumption_g_h: f64,
    methane_oxidation_combustion_g_c: f64,
    methane_oxidation_respiration_g_c: f64,
    methanotroph_methane_uptake_g_c: f64,
    methanotroph_nonstructural_carbon_gain_g_c: f64,
    oxygen_demand_g_o: f64,
    solver_iterations: u16,
};

/// Ports NITRO hydrogenotrophic `VMXA/H2GSX/RGOMP` and replaces its
/// NPH x NPT methane dissolution/oxidation loops with one bounded implicit
/// Newton-Raphson/Picard solve per runtime layer.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    // Preflight the complete tile so a rejected later layer cannot leave an
    // earlier result published into the hourly transaction.
    for (range.first..range.end) |layer| _ = try calculateLayer(context.*, layer);
    for (range.first..range.end) |layer| {
        const value = try calculateLayer(context.*, layer);
        inline for (@typeInfo(LayerResult).@"struct".fields) |field|
            @field(context.result, field.name)[layer] = @field(value, field.name);
    }
}

test "NITRO population-specific FCNP does not couple methane guild starvation" {
    const hydrogenotroph = try nutrientLimitation(.{ .carbon_g_c = 1, .nitrogen_g_n = 1.0e-4, .phosphorus_g_p = 1.0e-5 }, 0.10, 0.01);
    const methanotroph = try nutrientLimitation(.{ .carbon_g_c = 1, .nitrogen_g_n = 0.20, .phosphorus_g_p = 0.02 }, 0.20, 0.02);
    try std.testing.expect(hydrogenotroph < methanotroph);
    try std.testing.expectEqual(@as(f64, 1), methanotroph);
    const independently_starved_methanotroph = try nutrientLimitation(.{ .carbon_g_c = 1, .nitrogen_g_n = 2.0e-4, .phosphorus_g_p = 2.0e-5 }, 0.20, 0.02);
    try std.testing.expectEqual(hydrogenotroph, independently_starved_methanotroph);
}

test "N=3 K=5 methanotroph publishes demand before shared oxygen and consumes accepted fraction once" {
    const substrate_count = organic.microbial_substrate_count;
    const population_count = organic.microbial_population_count;
    const process_units = substrate_count * population_count;
    const methanotroph_population: usize = 2;
    const hydrogenotroph_population: usize = 4;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, substrate_count, population_count);
    defer microbial_state.deinit();
    const methane_population = try microbial_state.populationIndex(0, 0, organic.autotrophic_substrate_index, methanotroph_population);
    const hydrogen_population = try microbial_state.populationIndex(0, 0, organic.autotrophic_substrate_index, hydrogenotroph_population);
    microbial_state.structural[methane_population * 2] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    microbial_state.structural[hydrogen_population * 2] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    var flux = try fluxes.State.init(std.testing.allocator, 1, process_units);
    defer flux.deinit();
    flux.aerobic_active_biomass_g_c[0] = 10;
    const methane_unit = organic.autotrophic_substrate_index * population_count + methanotroph_population;
    const hydrogen_unit = organic.autotrophic_substrate_index * population_count + hydrogenotroph_population;
    flux.total_maintenance_respiration_g_c[methane_unit] = 0.01;
    flux.total_maintenance_respiration_g_c[hydrogen_unit] = 0.01;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.air_volume_m3[0] = 1;
    gas_state.gaseous_mass_g[@intFromEnum(gas.Species.methane)] = 1;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.methane)] = 0.2;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.hydrogen)] = 2;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = 10;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const ratio_count = substrate_count * population_count * organic.kinetic_fraction_count;
    const target_n = [_]f64{0.1} ** ratio_count;
    const target_p = [_]f64{0.01} ** ratio_count;
    const parameters: Parameters = .{
        .hydrogenotrophic = .{ .hydrogen_half_saturation_g_h_per_m3 = 0.01, .specific_co2_reduction_g_c_per_g_c_h = 0.1, .reference_energy_yield_kj_per_g_c = 11, .growth_energy_requirement_kj_per_g_c = 37.5, .minimum_growth_respiration_fraction = 0.4, .hydrogen_supply_conversion_g_c_per_g_h = 1.5, .fermentation_hydrogen_to_pool_fraction = 0.111 },
        .methane_half_saturation_g_c_per_m3 = 0.01,
        .methane_solubility_water_to_air = 0.03,
        .gas_exchange_rate_per_step = 0.5,
        .biomass_conversion_efficiency_g_c_per_g_c = 0.4,
        .methanotroph_growth_respiration_g_c_per_g_c = 0.5,
    };
    var prepare: PrepareContext = .{
        .result = &state,
        .microbial_state = &microbial_state,
        .flux_workspace = &flux,
        .gas_state = &gas_state,
        .water_volume_m3 = &.{1},
        .soil_temperature_k = &.{298.15},
        .matric_plus_osmotic_potential_megapascal = &.{0},
        .autotrophic_substrate_index = organic.autotrophic_substrate_index,
        .hydrogenotroph_population_index = hydrogenotroph_population,
        .methanotroph_population_index = methanotroph_population,
        .labile_biomass_fraction = 0.55,
        .microbial_nitrogen_to_carbon_g_n_per_g_c = &target_n,
        .microbial_phosphorus_to_carbon_g_p_per_g_c = &target_p,
        .aqueous_co2_half_saturation_g_c_per_m3 = 1,
        .hydrogen_product_inhibition_g_h_per_m3 = 1,
        .gas_constant_kj_per_mol_k = 8.3143e-3,
        .minimum_hydrogen_concentration_g_h_per_m3 = 1e-6,
        .hydrogen_feedback_stoichiometric_exponent = 4,
        .thermal_adaptation_offset_k_by_cell = &.{0},
        .methanotroph_specific_oxidation_per_h = 0.1,
        .parameters = parameters,
        .timestep_h = 1,
        .solver_options = .{ .absolute_tolerance_g_c = 1e-12, .relative_tolerance = 1e-9, .derivative_floor = 1e-14, .picard_relaxation = 0.5, .gas_max_iterations = 80 },
    };
    try prepareTile(&prepare, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.potential_oxygen_demand_g_o[0] > 0);
    try std.testing.expectEqual(state.potential_oxygen_demand_g_o[0], flux.aerobic_oxygen_demand_g_o[methane_unit]);
    try std.testing.expectEqual(state.methanotroph_active_biomass_g_c[0], flux.aerobic_active_biomass_g_c[methane_unit]);
    try std.testing.expect(flux.aerobic_fallback_active_fraction[methane_unit] > 0 and flux.aerobic_fallback_active_fraction[methane_unit] < 1);

    // Source GH2X is negative below H2KI and remains a valid energy feedback;
    // preparation must not classify its sign as a negative mass or rate.
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.hydrogen)] = 1e-6;
    try prepareTile(&prepare, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.hydrogen_feedback_energy_kj_per_mol[0] < 0);
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.hydrogen)] = 2;
    try prepareTile(&prepare, .{ .first = 0, .end = 1 });

    var oxygen_state = try oxygen_allocation.State.init(std.testing.allocator, 1, 1, process_units);
    defer oxygen_state.deinit();
    const accepted_fraction = 0.2;
    oxygen_state.demand_satisfaction_fraction[methane_unit] = accepted_fraction;
    oxygen_state.oxygen_uptake_g_o[methane_unit] = accepted_fraction * state.potential_oxygen_demand_g_o[0];
    var apply: ApplyContext = .{
        .result = &state,
        .gas_state = &gas_state,
        .oxygen_state = &oxygen_state,
        .process_unit_count_per_layer = process_units,
        .microbial_population_count = population_count,
        .autotrophic_substrate_index = organic.autotrophic_substrate_index,
        .methanotroph_population_index = methanotroph_population,
        .water_volume_m3 = &.{1},
        .fermentation_hydrogen_production_g_h = state.fermentation_hydrogen_production_g_h,
        .acetotrophic_methane_production_g_c = state.acetotrophic_methane_production_g_c,
        .hydrogenotroph_active_biomass_g_c = state.hydrogenotroph_active_biomass_g_c,
        .methanotroph_active_biomass_g_c = state.methanotroph_active_biomass_g_c,
        .hydrogenotroph_maintenance_respiration_g_c = state.hydrogenotroph_maintenance_respiration_g_c,
        .methanotroph_maintenance_respiration_g_c = state.methanotroph_maintenance_respiration_g_c,
        .temperature_water_response = state.temperature_water_response,
        .hydrogenotroph_nutrient_limitation_fraction = state.hydrogenotroph_nutrient_limitation_fraction,
        .methanotroph_nutrient_limitation_fraction = state.methanotroph_nutrient_limitation_fraction,
        .aqueous_co2_limitation_fraction = state.aqueous_co2_limitation_fraction,
        .hydrogen_feedback_energy_kj_per_mol = state.hydrogen_feedback_energy_kj_per_mol,
        .parameters = parameters,
        .timestep_h = 1,
    };
    const potential_oxidation = state.potential_methane_oxidation_combustion_g_c[0];
    const potential_oxygen = state.potential_oxygen_demand_g_o[0];
    try applyTile(&apply, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(accepted_fraction * potential_oxidation, state.methane_oxidation_combustion_g_c[0], 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(accepted_fraction * potential_oxygen, state.oxygen_demand_g_o[0], 64 * std.math.floatEps(f64));
    try std.testing.expectEqual(oxygen_state.oxygen_uptake_g_o[methane_unit], state.oxygen_demand_g_o[0]);
}

fn calculateLayer(context: ApplyContext, layer: usize) !LayerResult {
    const water_m3 = context.water_volume_m3[layer];
    if (water_m3 <= 0) {
        const methane_index = try gas.massIndex(layer, .methane, context.gas_state.cell_count);
        return .{
            .gaseous_methane_after_g_c = context.gas_state.gaseous_mass_g[methane_index],
            .aqueous_methane_after_g_c = context.gas_state.dissolved_mass_g[methane_index],
            .hydrogenotrophic_methane_g_c = 0,
            .hydrogenotrophic_carbon_dioxide_uptake_g_c = 0,
            .hydrogenotrophic_nonstructural_carbon_gain_g_c = 0,
            .hydrogen_consumption_g_h = 0,
            .methane_oxidation_combustion_g_c = 0,
            .methane_oxidation_respiration_g_c = 0,
            .methanotroph_methane_uptake_g_c = 0,
            .methanotroph_nonstructural_carbon_gain_g_c = 0,
            .oxygen_demand_g_o = 0,
            .solver_iterations = 0,
        };
    }
    const hydrogen_index = try gas.massIndex(layer, .hydrogen, context.gas_state.cell_count);
    const carbon_dioxide_index = try gas.massIndex(layer, .carbon_dioxide, context.gas_state.cell_count);
    const aqueous_hydrogen_g_h = context.gas_state.dissolved_mass_g[hydrogen_index];
    const hydrogen_result = try methanogenesis.hydrogenotrophic(.{
        .aqueous_hydrogen_concentration_g_h_per_m3 = aqueous_hydrogen_g_h / water_m3,
        .aqueous_hydrogen_g_h = aqueous_hydrogen_g_h,
        .fermentation_hydrogen_production_g_h = context.fermentation_hydrogen_production_g_h[layer],
        .temperature_water_response = context.temperature_water_response[layer],
        .nutrient_limitation_fraction = context.hydrogenotroph_nutrient_limitation_fraction[layer],
        .aqueous_co2_limitation_fraction = context.aqueous_co2_limitation_fraction[layer],
        .active_biomass_g_c = context.hydrogenotroph_active_biomass_g_c[layer],
        .timestep_h = context.timestep_h,
        .hydrogen_feedback_energy_kj_per_mol = context.hydrogen_feedback_energy_kj_per_mol[layer],
    }, context.parameters.hydrogenotrophic);
    const hydrogen_routing = try routeAutotrophicCarbon(
        hydrogen_result.co2_reduction_g_c,
        context.hydrogenotroph_maintenance_respiration_g_c[layer],
        hydrogen_result.growth_respiration_fraction,
        context.gas_state.dissolved_mass_g[carbon_dioxide_index],
    );
    const hydrogen_consumption_g_h = hydrogen_routing.respiration_g_c / context.parameters.hydrogenotrophic.hydrogen_supply_conversion_g_c_per_g_h;
    const methane_unit = layer * context.process_unit_count_per_layer + context.autotrophic_substrate_index * context.microbial_population_count + context.methanotroph_population_index;
    const fraction = context.oxygen_state.demand_satisfaction_fraction[methane_unit];
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidSoilMethanotrophOxygenFraction;
    const gaseous_after = lerp(context.result.unoxidized_gaseous_methane_after_g_c[layer], context.result.potential_gaseous_methane_after_g_c[layer], fraction);
    const aqueous_after = lerp(context.result.unoxidized_aqueous_methane_after_g_c[layer], context.result.potential_aqueous_methane_after_g_c[layer], fraction);
    const methane_oxidation = context.result.potential_methane_oxidation_combustion_g_c[layer] * fraction;
    const methane_respiration = context.result.potential_methane_oxidation_respiration_g_c[layer] * fraction;
    const methane_uptake = context.result.potential_methanotroph_methane_uptake_g_c[layer] * fraction;
    const methane_gain = context.result.potential_methanotroph_nonstructural_carbon_gain_g_c[layer] * fraction;
    const oxygen_demand = context.result.potential_oxygen_demand_g_o[layer] * fraction;
    const allocated_oxygen = context.oxygen_state.oxygen_uptake_g_o[methane_unit];
    const oxygen_scale = @max(@max(context.result.potential_oxygen_demand_g_o[layer], allocated_oxygen), 1);
    if (@abs(oxygen_demand - allocated_oxygen) > 64 * std.math.floatEps(f64) * oxygen_scale) return error.SoilMethanotrophOxygenAllocationMismatch;
    inline for (.{ hydrogen_consumption_g_h, fraction, gaseous_after, aqueous_after, methane_oxidation, methane_respiration, methane_uptake, methane_gain, oxygen_demand }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteSoilMethaneResult;
    return .{
        .gaseous_methane_after_g_c = gaseous_after,
        .aqueous_methane_after_g_c = aqueous_after,
        .hydrogenotrophic_methane_g_c = hydrogen_routing.respiration_g_c,
        .hydrogenotrophic_carbon_dioxide_uptake_g_c = hydrogen_routing.gross_uptake_g_c,
        .hydrogenotrophic_nonstructural_carbon_gain_g_c = hydrogen_routing.nonstructural_gain_g_c,
        .hydrogen_consumption_g_h = hydrogen_consumption_g_h,
        .methane_oxidation_combustion_g_c = methane_oxidation,
        .methane_oxidation_respiration_g_c = methane_respiration,
        .methanotroph_methane_uptake_g_c = methane_uptake,
        .methanotroph_nonstructural_carbon_gain_g_c = methane_gain,
        .oxygen_demand_g_o = oxygen_demand,
        .solver_iterations = context.result.solver_iterations[layer],
    };
}

fn lerp(a: f64, b: f64, fraction: f64) f64 {
    return a + fraction * (b - a);
}

fn routeAutotrophicCarbon(requested_respiration_g_c: f64, maintenance_g_c: f64, echz: f64, donor_g_c: f64) !RoutedCarbon {
    inline for (.{ requested_respiration_g_c, maintenance_g_c, echz, donor_g_c }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilMethaneResult;
    if (requested_respiration_g_c < 0 or maintenance_g_c < 0 or echz <= 0 or echz > 1 or donor_g_c < 0) return error.InvalidSoilMethaneInput;
    const accepted_respiration = @min(requested_respiration_g_c, if (donor_g_c <= maintenance_g_c)
        donor_g_c
    else
        maintenance_g_c + echz * (donor_g_c - maintenance_g_c));
    const maintenance = @min(maintenance_g_c, accepted_respiration);
    const gross = maintenance + (accepted_respiration - maintenance) / echz;
    const accepted_gross = @min(gross, donor_g_c);
    return .{ .respiration_g_c = accepted_respiration, .gross_uptake_g_c = accepted_gross, .nonstructural_gain_g_c = accepted_gross - accepted_respiration };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const n = context.result.layer_count;
    if (range.first > range.end or range.end > n or context.gas_state.cell_count != n or context.oxygen_state.layer_count * context.oxygen_state.cell_count != n or context.oxygen_state.population_count != context.process_unit_count_per_layer or context.microbial_population_count == 0 or context.process_unit_count_per_layer % context.microbial_population_count != 0 or context.autotrophic_substrate_index >= context.process_unit_count_per_layer / context.microbial_population_count or context.methanotroph_population_index >= context.microbial_population_count) return error.InvalidSoilMethaneDimensions;
    inline for (.{ context.water_volume_m3, context.fermentation_hydrogen_production_g_h, context.acetotrophic_methane_production_g_c, context.hydrogenotroph_active_biomass_g_c, context.methanotroph_active_biomass_g_c, context.hydrogenotroph_maintenance_respiration_g_c, context.methanotroph_maintenance_respiration_g_c, context.temperature_water_response, context.hydrogenotroph_nutrient_limitation_fraction, context.methanotroph_nutrient_limitation_fraction, context.aqueous_co2_limitation_fraction, context.hydrogen_feedback_energy_kj_per_mol }) |values| if (values.len != n) return error.InvalidSoilMethaneDimensions;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.InvalidSoilMethaneInput;
}

test "tiled hydrogenotrophic methanogenesis and implicit methanotrophy conserve carbon" {
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.air_volume_m3[0] = 1;
    gas_state.gaseous_mass_g[@intFromEnum(gas.Species.methane)] = 1;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.methane)] = 0.2;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.hydrogen)] = 0.1;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.oxygen)] = 1;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = 1;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const parameters: Parameters = .{
        .hydrogenotrophic = .{ .hydrogen_half_saturation_g_h_per_m3 = 0.01, .specific_co2_reduction_g_c_per_g_c_h = 0.1, .reference_energy_yield_kj_per_g_c = 1, .growth_energy_requirement_kj_per_g_c = 10, .minimum_growth_respiration_fraction = 0.05, .hydrogen_supply_conversion_g_c_per_g_h = 1.5, .fermentation_hydrogen_to_pool_fraction = 0.111 },
        .methane_half_saturation_g_c_per_m3 = 0.01,
        .methane_solubility_water_to_air = 0.03,
        .gas_exchange_rate_per_step = 0.5,
        .biomass_conversion_efficiency_g_c_per_g_c = 0.4,
        .methanotroph_growth_respiration_g_c_per_g_c = 0.5,
    };
    const h = try methanogenesis.hydrogenotrophic(.{ .aqueous_hydrogen_concentration_g_h_per_m3 = 0.1, .aqueous_hydrogen_g_h = 0.1, .fermentation_hydrogen_production_g_h = 0.01, .temperature_water_response = 1, .nutrient_limitation_fraction = 1, .aqueous_co2_limitation_fraction = 1, .active_biomass_g_c = 1, .timestep_h = 1, .hydrogen_feedback_energy_kj_per_mol = 0 }, parameters.hydrogenotrophic);
    const h_route = try routeAutotrophicCarbon(h.co2_reduction_g_c, 0.01, h.growth_respiration_fraction, 1);
    const methane_inputs: oxidation.Inputs = .{ .gaseous_methane_g_c = 1, .aqueous_methane_g_c = 0.2, .gaseous_methane_flux_g_c = 0, .aqueous_methane_flux_g_c = 0, .methanogenesis_g_c = 0.05 + h_route.respiration_g_c, .water_volume_m3 = 1, .air_volume_m3 = 1, .methane_solubility_water_to_air = parameters.methane_solubility_water_to_air, .gas_exchange_rate_per_step = parameters.gas_exchange_rate_per_step, .gas_exchange_enabled = true, .methane_half_saturation_g_c_per_m3 = parameters.methane_half_saturation_g_c_per_m3, .maximum_methane_oxidation_g_c = 0.1, .biomass_conversion_efficiency_g_c_per_g_c = parameters.biomass_conversion_efficiency_g_c_per_g_c, .growth_respiration_g_c_per_g_c = parameters.methanotroph_growth_respiration_g_c_per_g_c, .maintenance_respiration_g_c = 0.01 };
    const options: oxidation.Options = .{ .absolute_tolerance_g_c = 1e-12, .relative_tolerance = 1e-10, .derivative_floor = 1e-14, .picard_relaxation = 0.5, .gas_max_iterations = 80 };
    const potential = try oxidation.solve(methane_inputs, options);
    var unoxidized_inputs = methane_inputs;
    unoxidized_inputs.maximum_methane_oxidation_g_c = 0;
    const unoxidized = try oxidation.solve(unoxidized_inputs, options);
    state.unoxidized_gaseous_methane_after_g_c[0] = unoxidized.gaseous_methane_g_c;
    state.unoxidized_aqueous_methane_after_g_c[0] = unoxidized.aqueous_methane_g_c;
    state.potential_gaseous_methane_after_g_c[0] = potential.gaseous_methane_g_c;
    state.potential_aqueous_methane_after_g_c[0] = potential.aqueous_methane_g_c;
    state.potential_methane_oxidation_combustion_g_c[0] = potential.methane_oxidation_g_c;
    state.potential_methane_oxidation_respiration_g_c[0] = potential.growth_respiration_g_c;
    state.potential_methanotroph_methane_uptake_g_c[0] = potential.methane_carbon_uptake_g_c;
    state.potential_methanotroph_nonstructural_carbon_gain_g_c[0] = potential.nonstructural_carbon_gain_g_c;
    state.potential_oxygen_demand_g_o[0] = potential.oxygen_demand_g_o;
    state.solver_iterations[0] = potential.iterations;
    var oxygen_state = try oxygen_allocation.State.init(std.testing.allocator, 1, 1, 1);
    defer oxygen_state.deinit();
    oxygen_state.demand_satisfaction_fraction[0] = 1;
    oxygen_state.oxygen_uptake_g_o[0] = potential.oxygen_demand_g_o;
    var context: ApplyContext = .{
        .result = &state,
        .gas_state = &gas_state,
        .oxygen_state = &oxygen_state,
        .process_unit_count_per_layer = 1,
        .microbial_population_count = 1,
        .autotrophic_substrate_index = 0,
        .methanotroph_population_index = 0,
        .water_volume_m3 = &.{1},
        .fermentation_hydrogen_production_g_h = &.{0.01},
        .acetotrophic_methane_production_g_c = &.{0.05},
        .hydrogenotroph_active_biomass_g_c = &.{1},
        .methanotroph_active_biomass_g_c = &.{1},
        .hydrogenotroph_maintenance_respiration_g_c = &.{0.01},
        .methanotroph_maintenance_respiration_g_c = &.{0.01},
        .temperature_water_response = &.{1},
        .hydrogenotroph_nutrient_limitation_fraction = &.{1},
        .methanotroph_nutrient_limitation_fraction = &.{1},
        .aqueous_co2_limitation_fraction = &.{1},
        .hydrogen_feedback_energy_kj_per_mol = &.{0},
        .parameters = parameters,
        .timestep_h = 1,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const methane_before = 1.2 + 0.05 + state.hydrogenotrophic_methane_g_c[0];
    const methane_after = state.gaseous_methane_after_g_c[0] + state.aqueous_methane_after_g_c[0] + state.methane_oxidation_combustion_g_c[0] + state.methanotroph_methane_uptake_g_c[0];
    try std.testing.expectApproxEqAbs(methane_before, methane_after, 1e-9);
    try std.testing.expect(state.solver_iterations[0] < 80);
    try std.testing.expect(state.hydrogenotrophic_methane_g_c[0] > 0);
    try std.testing.expectApproxEqAbs(state.hydrogenotrophic_carbon_dioxide_uptake_g_c[0] - state.hydrogenotrophic_methane_g_c[0], state.hydrogenotrophic_nonstructural_carbon_gain_g_c[0], 1e-14);
    try std.testing.expectApproxEqAbs(state.methanotroph_methane_uptake_g_c[0] - state.methane_oxidation_respiration_g_c[0], state.methanotroph_nonstructural_carbon_gain_g_c[0], 1e-14);
    try std.testing.expect(state.oxygen_demand_g_o[0] > 0);
}

test "hydrogen product feedback changes ECHZ and conservatively changes methanogen biomass routing" {
    const parameters: methanogenesis.HydrogenotrophicParameters = .{
        .hydrogen_half_saturation_g_h_per_m3 = 0.01,
        .specific_co2_reduction_g_c_per_g_c_h = 0.125,
        .reference_energy_yield_kj_per_g_c = 11,
        .growth_energy_requirement_kj_per_g_c = 37.5,
        .minimum_growth_respiration_fraction = 0.4,
        .hydrogen_supply_conversion_g_c_per_g_h = 1.5,
        .fermentation_hydrogen_to_pool_fraction = 0.111,
    };
    const common = .{
        .aqueous_hydrogen_g_h = 2.0,
        .fermentation_hydrogen_production_g_h = 0.0,
        .temperature_water_response = 1.0,
        .nutrient_limitation_fraction = 1.0,
        .aqueous_co2_limitation_fraction = 1.0,
        .active_biomass_g_c = 8.0,
        .timestep_h = 1.0,
    };
    const low_feedback = try hydrogenFeedbackEnergy_kj_per_mol(300, 0.01, 1, 8.3143e-3, 1e-3, 4);
    const high_feedback = try hydrogenFeedbackEnergy_kj_per_mol(300, 2, 1, 8.3143e-3, 1e-3, 4);
    const low = try methanogenesis.hydrogenotrophic(.{
        .aqueous_hydrogen_concentration_g_h_per_m3 = 0.01,
        .aqueous_hydrogen_g_h = common.aqueous_hydrogen_g_h,
        .fermentation_hydrogen_production_g_h = common.fermentation_hydrogen_production_g_h,
        .temperature_water_response = common.temperature_water_response,
        .nutrient_limitation_fraction = common.nutrient_limitation_fraction,
        .aqueous_co2_limitation_fraction = common.aqueous_co2_limitation_fraction,
        .active_biomass_g_c = common.active_biomass_g_c,
        .timestep_h = common.timestep_h,
        .hydrogen_feedback_energy_kj_per_mol = low_feedback,
    }, parameters);
    const high = try methanogenesis.hydrogenotrophic(.{
        .aqueous_hydrogen_concentration_g_h_per_m3 = 2,
        .aqueous_hydrogen_g_h = common.aqueous_hydrogen_g_h,
        .fermentation_hydrogen_production_g_h = common.fermentation_hydrogen_production_g_h,
        .temperature_water_response = common.temperature_water_response,
        .nutrient_limitation_fraction = common.nutrient_limitation_fraction,
        .aqueous_co2_limitation_fraction = common.aqueous_co2_limitation_fraction,
        .active_biomass_g_c = common.active_biomass_g_c,
        .timestep_h = common.timestep_h,
        .hydrogen_feedback_energy_kj_per_mol = high_feedback,
    }, parameters);
    try std.testing.expect(high.growth_respiration_fraction < low.growth_respiration_fraction);
    const low_route = try routeAutotrophicCarbon(0.2, 0, low.growth_respiration_fraction, 10);
    const high_route = try routeAutotrophicCarbon(0.2, 0, high.growth_respiration_fraction, 10);
    try std.testing.expect(high_route.nonstructural_gain_g_c > low_route.nonstructural_gain_g_c);
    try std.testing.expectApproxEqAbs(low_route.gross_uptake_g_c, low_route.respiration_g_c + low_route.nonstructural_gain_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(high_route.gross_uptake_g_c, high_route.respiration_g_c + high_route.nonstructural_gain_g_c, 1e-15);
}

test "failed methane tile leaves every published layer unchanged" {
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    for (0..2) |layer| {
        gas_state.air_volume_m3[layer] = 1;
        gas_state.gaseous_mass_g[try gas.massIndex(layer, .methane, 2)] = 1;
        gas_state.dissolved_mass_g[try gas.massIndex(layer, .methane, 2)] = 0.2;
        gas_state.dissolved_mass_g[try gas.massIndex(layer, .hydrogen, 2)] = 0.1;
        gas_state.dissolved_mass_g[try gas.massIndex(layer, .oxygen, 2)] = 1;
        gas_state.dissolved_mass_g[try gas.massIndex(layer, .carbon_dioxide, 2)] = 1;
    }
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) @memset(@field(state, field.name), 7);
    @memset(state.solver_iterations, 9);
    var oxygen_state = try oxygen_allocation.State.init(std.testing.allocator, 2, 1, 1);
    defer oxygen_state.deinit();
    @memset(oxygen_state.demand_satisfaction_fraction, 1);
    @memset(oxygen_state.oxygen_uptake_g_o, 7);
    var context: ApplyContext = .{
        .result = &state,
        .gas_state = &gas_state,
        .oxygen_state = &oxygen_state,
        .process_unit_count_per_layer = 1,
        .microbial_population_count = 1,
        .autotrophic_substrate_index = 0,
        .methanotroph_population_index = 0,
        .water_volume_m3 = &.{ 1, 1 },
        .fermentation_hydrogen_production_g_h = &.{ 0.01, 0.01 },
        .acetotrophic_methane_production_g_c = &.{ 0.05, 0.05 },
        .hydrogenotroph_active_biomass_g_c = &.{ 1, 1 },
        .methanotroph_active_biomass_g_c = &.{ 1, 1 },
        .hydrogenotroph_maintenance_respiration_g_c = &.{ 0.01, 0.01 },
        .methanotroph_maintenance_respiration_g_c = &.{ 0.01, 0.01 },
        .temperature_water_response = &.{ 1, -1 },
        .hydrogenotroph_nutrient_limitation_fraction = &.{ 1, 1 },
        .methanotroph_nutrient_limitation_fraction = &.{ 1, 1 },
        .aqueous_co2_limitation_fraction = &.{ 1, 1 },
        .hydrogen_feedback_energy_kj_per_mol = &.{ 0, 0 },
        .parameters = .{
            .hydrogenotrophic = .{ .hydrogen_half_saturation_g_h_per_m3 = 0.01, .specific_co2_reduction_g_c_per_g_c_h = 0.125, .reference_energy_yield_kj_per_g_c = 11, .growth_energy_requirement_kj_per_g_c = 37.5, .minimum_growth_respiration_fraction = 0.4, .hydrogen_supply_conversion_g_c_per_g_h = 1.5, .fermentation_hydrogen_to_pool_fraction = 0.111 },
            .methane_half_saturation_g_c_per_m3 = 0.0012,
            .methane_solubility_water_to_air = 0.03,
            .gas_exchange_rate_per_step = 0.5,
            .biomass_conversion_efficiency_g_c_per_g_c = 0.75,
            .methanotroph_growth_respiration_g_c_per_g_c = 0.27322404371584696,
        },
        .timestep_h = 1,
    };
    try std.testing.expectError(error.InvalidHydrogenotrophicMethanogenesis, applyTile(&context, .{ .first = 0, .end = 2 }));
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(state, field.name)) |value| try std.testing.expectEqual(@as(f64, 7), value);
    for (state.solver_iterations) |value| try std.testing.expectEqual(@as(u16, 9), value);
}

test "SOIL-METHANE-DRY-LAYER-001 nitro.f:1398 skips CH4 oxidation when VOLW is zero instead of fatal" {
    const substrate_count = organic.microbial_substrate_count;
    const population_count = organic.microbial_population_count;
    const process_units = substrate_count * population_count;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, substrate_count, population_count);
    defer microbial_state.deinit();
    var flux = try fluxes.State.init(std.testing.allocator, 1, process_units);
    defer flux.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.air_volume_m3[0] = 1;
    gas_state.gaseous_mass_g[@intFromEnum(gas.Species.methane)] = 1.25;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.methane)] = 0.5;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const ratio_count = substrate_count * population_count * organic.kinetic_fraction_count;
    const target_n = [_]f64{0.1} ** ratio_count;
    const target_p = [_]f64{0.01} ** ratio_count;
    var prepare: PrepareContext = .{
        .result = &state,
        .microbial_state = &microbial_state,
        .flux_workspace = &flux,
        .gas_state = &gas_state,
        .water_volume_m3 = &.{0},
        .soil_temperature_k = &.{298.15},
        .matric_plus_osmotic_potential_megapascal = &.{0},
        .autotrophic_substrate_index = organic.autotrophic_substrate_index,
        .hydrogenotroph_population_index = 4,
        .methanotroph_population_index = 2,
        .labile_biomass_fraction = 0.55,
        .microbial_nitrogen_to_carbon_g_n_per_g_c = &target_n,
        .microbial_phosphorus_to_carbon_g_p_per_g_c = &target_p,
        .aqueous_co2_half_saturation_g_c_per_m3 = 1,
        .hydrogen_product_inhibition_g_h_per_m3 = 1,
        .gas_constant_kj_per_mol_k = 8.3143e-3,
        .minimum_hydrogen_concentration_g_h_per_m3 = 1e-6,
        .hydrogen_feedback_stoichiometric_exponent = 4,
        .thermal_adaptation_offset_k_by_cell = &.{0},
        .methanotroph_specific_oxidation_per_h = 0.1,
        .parameters = .{
            .hydrogenotrophic = .{ .hydrogen_half_saturation_g_h_per_m3 = 0.01, .specific_co2_reduction_g_c_per_g_c_h = 0.1, .reference_energy_yield_kj_per_g_c = 11, .growth_energy_requirement_kj_per_g_c = 37.5, .minimum_growth_respiration_fraction = 0.4, .hydrogen_supply_conversion_g_c_per_g_h = 1.5, .fermentation_hydrogen_to_pool_fraction = 0.111 },
            .methane_half_saturation_g_c_per_m3 = 0.01,
            .methane_solubility_water_to_air = 0.03,
            .gas_exchange_rate_per_step = 0.5,
            .biomass_conversion_efficiency_g_c_per_g_c = 0.4,
            .methanotroph_growth_respiration_g_c_per_g_c = 0.5,
        },
        .timestep_h = 1,
        .solver_options = .{ .absolute_tolerance_g_c = 1e-12, .relative_tolerance = 1e-9, .derivative_floor = 1e-14, .picard_relaxation = 0.5, .gas_max_iterations = 80 },
    };
    try prepareTile(&prepare, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 0), state.potential_oxygen_demand_g_o[0]);
    try std.testing.expectEqual(@as(f64, 1.25), state.potential_gaseous_methane_after_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0.5), state.potential_aqueous_methane_after_g_c[0]);
}

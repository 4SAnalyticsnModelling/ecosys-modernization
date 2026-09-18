const std = @import("std");
const compute = @import("../core/compute.zig");
const organic = @import("../soil/organic/initialization.zig");
const respiration = @import("../soil/microbial/respiration_activity.zig");
const gas = @import("../soil/gas/transport.zig");
const metabolism = @import("../soil/microbial/metabolism.zig");

pub const litter_complex_count: usize = 3;
pub const source_population_count: usize = organic.microbial_population_count;
pub const unit_count_per_cell: usize = litter_complex_count * source_population_count;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    unlimited_respiration_g_c: []f64,
    substrate_limited_respiration_g_c: []f64,
    potential_oxygen_demand_g_o: []f64,
    previous_oxygen_demand_g_o: []f64,
    previous_doc_respiration_g_c: []f64,
    previous_acetate_respiration_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceMicrobialRespirationCells;
        const count = try std.math.mul(usize, cell_count, unit_count_per_cell);
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

pub const Parameters = struct {
    populations: [source_population_count]respiration.PopulationParameters,
    target_nitrogen_per_carbon_g_n_per_g_c: [unit_count_per_cell]f64,
    target_phosphorus_per_carbon_g_p_per_g_c: [unit_count_per_cell]f64,
    doc_respiration_requirement_g_c_per_g_c: [source_population_count]f64,
    acetate_respiration_requirement_g_c_per_g_c: [source_population_count]f64,
    labile_biomass_fraction: f64,
    doc_half_saturation_g_c_per_m3: f64,
    acetate_half_saturation_g_c_per_m3: f64,
    minimum_competition_fraction: f64,
    specific_maintenance_respiration_g_c_per_g_n_per_h: f64,
    decomposition_density_half_saturation_g_c_per_g_c: f64,
    maintenance_density_half_saturation_g_c_per_g_c: f64,
    acidity_half_response_mol_per_m3: f64,
    nitrogen_fixation_yield_g_n_per_g_c: [source_population_count]f64,
    dinitrogen_half_saturation_g_n_per_m3: f64,
    nonstructural_to_structural_rate_per_h: f64,
    denitrification_growth_respiration_requirement_g_c_per_g_c: f64,
};

pub const ApplyContext = struct {
    result: *State,
    surface_organic: *const organic.State,
    biologically_active_water_m3: []const f64,
    growth_temperature_response: []const f64,
    matric_plus_osmotic_potential_megapascal: []const f64,
    /// Authoritative litter aqueous-gas owner and its water-volume basis,
    /// matching `surface_denitrification_step`'s identical pairing. Needed
    /// only for source `NITRO.F` 325, `OXYI`: layer-level O2 inhibition of
    /// fermentation, which `NITRO.F`'s single `L=0..NL` loop applies
    /// uniformly to the surface-litter layer (`L.EQ.0`) exactly like every
    /// soil layer.
    litter_gas: *const gas.State,
    litter_water_m3: []const f64,
    timestep_h: f64,
    parameters: Parameters,
};

/// Source `NITRO.F` 325, `OXYI`, computed once per cell before the substrate
/// and population loops that consume it at source line 960, exactly
/// mirroring `soil_heterotrophic_respiration_step.layerFermentationOxygenInhibition`.
fn cellFermentationOxygenInhibition(context: ApplyContext, cell: usize) !f64 {
    const water_m3 = context.litter_water_m3[cell];
    if (!(water_m3 > 0)) return 1;
    const index = try gas.massIndex(cell, .oxygen, context.litter_gas.cell_count);
    const concentration_g_o_per_m3 = context.litter_gas.dissolved_mass_g[index] / water_m3;
    return try metabolism.fermentationOxygenInhibition(concentration_g_o_per_m3);
}

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| {
        var colonized_and_sorbed_g_c: [litter_complex_count]f64 = undefined;
        var active_biomass_g_c: [unit_count_per_cell]f64 = undefined;
        var total_active_by_complex_g_c: [litter_complex_count]f64 = .{ 0, 0, 0 };
        var total_previous_doc_by_complex_g_c: [litter_complex_count]f64 = .{ 0, 0, 0 };
        var total_previous_acetate_by_complex_g_c: [litter_complex_count]f64 = .{ 0, 0, 0 };
        var total_raw_doc_share: [litter_complex_count]f64 = .{ 0, 0, 0 };
        var total_raw_acetate_share: [litter_complex_count]f64 = .{ 0, 0, 0 };
        for (0..litter_complex_count) |complex| {
            var colonized: f64 = 0;
            for (0..organic.structural_fraction_count) |fraction| colonized += context.surface_organic.colonized_structural_carbon_g_c[(cell * organic.substrate_count + complex) * organic.structural_fraction_count + fraction];
            for (0..organic.residue_fraction_count) |fraction| colonized += context.surface_organic.residue[(cell * organic.substrate_count + complex) * organic.residue_fraction_count + fraction].carbon_g_c;
            const mobile = cell * organic.substrate_count + complex;
            colonized += context.surface_organic.adsorbed[mobile].carbon_g_c + context.surface_organic.adsorbed_acetate_carbon_g_c[mobile];
            colonized_and_sorbed_g_c[complex] = colonized;
            for (0..source_population_count) |population| {
                const unit = complex * source_population_count + population;
                const microbial = (((cell * organic.microbial_substrate_count + complex) * source_population_count + population) * organic.kinetic_fraction_count);
                active_biomass_g_c[unit] = context.surface_organic.microbial[microbial].carbon_g_c / context.parameters.labile_biomass_fraction;
                total_active_by_complex_g_c[complex] += active_biomass_g_c[unit];
                const state_index = cell * unit_count_per_cell + unit;
                total_previous_doc_by_complex_g_c[complex] += context.result.previous_doc_respiration_g_c[state_index];
                total_previous_acetate_by_complex_g_c[complex] += context.result.previous_acetate_respiration_g_c[state_index];
            }
            for (0..source_population_count) |population| {
                const unit = complex * source_population_count + population;
                const state_index = cell * unit_count_per_cell + unit;
                const fallback = if (total_active_by_complex_g_c[complex] > 0) active_biomass_g_c[unit] / total_active_by_complex_g_c[complex] else 1;
                total_raw_doc_share[complex] += @max(context.parameters.minimum_competition_fraction, if (total_previous_doc_by_complex_g_c[complex] > 0) context.result.previous_doc_respiration_g_c[state_index] / total_previous_doc_by_complex_g_c[complex] else fallback);
                total_raw_acetate_share[complex] += @max(context.parameters.minimum_competition_fraction, if (total_previous_acetate_by_complex_g_c[complex] > 0) context.result.previous_acetate_respiration_g_c[state_index] / total_previous_acetate_by_complex_g_c[complex] else fallback);
            }
        }
        const total_colonized = colonized_and_sorbed_g_c[0] + colonized_and_sorbed_g_c[1] + colonized_and_sorbed_g_c[2];
        const oxygen_inhibition = try cellFermentationOxygenInhibition(context.*, cell);
        for (0..litter_complex_count) |complex| for (0..source_population_count) |population| {
            const unit = complex * source_population_count + population;
            const state_index = cell * unit_count_per_cell + unit;
            context.result.previous_oxygen_demand_g_o[state_index] = context.result.potential_oxygen_demand_g_o[state_index];
            const microbial = (((cell * organic.microbial_substrate_count + complex) * source_population_count + population) * organic.kinetic_fraction_count);
            const labile = context.surface_organic.microbial[microbial];
            const target_n = context.parameters.target_nitrogen_per_carbon_g_n_per_g_c[unit];
            const target_p = context.parameters.target_phosphorus_per_carbon_g_p_per_g_c[unit];
            const actual_n = if (labile.carbon_g_c > 0) labile.nitrogen_g_n / labile.carbon_g_c else target_n;
            const actual_p = if (labile.carbon_g_c > 0) labile.phosphorus_g_p / labile.carbon_g_c else target_p;
            const nutrient = @min(@min(1, @max(0.1, std.math.pow(f64, actual_n / target_n, 0.25))), @min(1, @max(0.1, std.math.pow(f64, actual_p / target_p, 0.25))));
            const water = @exp((if (population == 2) @as(f64, 0.05) else 0.10) * context.matric_plus_osmotic_potential_megapascal[cell]);
            const unlimited = context.parameters.populations[population].substrate_unlimited_respiration_per_h * nutrient * water * active_biomass_g_c[unit] * context.timestep_h;
            context.result.unlimited_respiration_g_c[state_index] = switch (context.parameters.populations[population].metabolism) {
                .aerobic_heterotroph, .fermenting_heterotroph => unlimited,
                .acetotrophic_methanogen => 0,
            };
            const fallback = if (total_active_by_complex_g_c[complex] > 0) active_biomass_g_c[unit] / total_active_by_complex_g_c[complex] else 1;
            const doc_share = @max(context.parameters.minimum_competition_fraction, if (total_previous_doc_by_complex_g_c[complex] > 0) context.result.previous_doc_respiration_g_c[state_index] / total_previous_doc_by_complex_g_c[complex] else fallback) / @max(1, total_raw_doc_share[complex]);
            const acetate_share = @max(context.parameters.minimum_competition_fraction, if (total_previous_acetate_by_complex_g_c[complex] > 0) context.result.previous_acetate_respiration_g_c[state_index] / total_previous_acetate_by_complex_g_c[complex] else fallback) / @max(1, total_raw_acetate_share[complex]);
            const mobile = cell * organic.substrate_count + complex;
            const substrate_fraction = if (total_colonized > 0) colonized_and_sorbed_g_c[complex] / total_colonized else 1;
            const effective_water_m3 = context.biologically_active_water_m3[cell] * substrate_fraction;
            const doc_concentration_g_c_per_m3 = if (effective_water_m3 > 0) context.surface_organic.dissolved[mobile].carbon_g_c / effective_water_m3 else 0;
            const acetate_concentration_g_c_per_m3 = if (effective_water_m3 > 0) context.surface_organic.dissolved_acetate_carbon_g_c[mobile] / effective_water_m3 else 0;
            switch (context.parameters.populations[population].metabolism) {
                .fermenting_heterotroph => {
                    // NITRO RGOFZ/RGOFX/RGOMP. ROQCS retains unconstrained
                    // microbial demand for competition in the following step.
                    const doc_demand = unlimited * doc_concentration_g_c_per_m3 / (doc_concentration_g_c_per_m3 + context.parameters.doc_half_saturation_g_c_per_m3) * oxygen_inhibition * context.growth_temperature_response[cell];
                    const doc_supply = context.surface_organic.dissolved[mobile].carbon_g_c * doc_share * context.parameters.doc_respiration_requirement_g_c_per_g_c[population] * context.timestep_h;
                    context.result.substrate_limited_respiration_g_c[state_index] = @min(doc_supply, doc_demand);
                    context.result.potential_oxygen_demand_g_o[state_index] = 0;
                    context.result.previous_doc_respiration_g_c[state_index] = doc_demand;
                    context.result.previous_acetate_respiration_g_c[state_index] = 0;
                    continue;
                },
                .acetotrophic_methanogen => {
                    // NITRO RGOGZ/RGOGX/RGOMP. Acetotroph activity does not
                    // enter ROQCD and therefore unlimited_respiration remains 0.
                    const acetate_demand = unlimited * acetate_concentration_g_c_per_m3 / (acetate_concentration_g_c_per_m3 + context.parameters.acetate_half_saturation_g_c_per_m3) * context.growth_temperature_response[cell];
                    const acetate_supply = context.surface_organic.dissolved_acetate_carbon_g_c[mobile] * acetate_share * context.parameters.acetate_respiration_requirement_g_c_per_g_c[population] * context.timestep_h;
                    context.result.substrate_limited_respiration_g_c[state_index] = @min(acetate_supply, acetate_demand);
                    context.result.potential_oxygen_demand_g_o[state_index] = 0;
                    context.result.previous_doc_respiration_g_c[state_index] = 0;
                    context.result.previous_acetate_respiration_g_c[state_index] = acetate_demand;
                    continue;
                },
                .aerobic_heterotroph => {},
            }
            const limited = try respiration.aerobicSubstrateLimitedRespiration(.{
                .unlimited_respiration_g_c = unlimited,
                .dissolved_organic_carbon_g_c = context.surface_organic.dissolved[mobile].carbon_g_c,
                .dissolved_acetate_carbon_g_c = context.surface_organic.dissolved_acetate_carbon_g_c[mobile],
                .biologically_active_water_m3 = context.biologically_active_water_m3[cell],
                .substrate_complex_fraction = substrate_fraction,
                .doc_half_saturation_g_c_per_m3 = context.parameters.doc_half_saturation_g_c_per_m3,
                .acetate_half_saturation_g_c_per_m3 = context.parameters.acetate_half_saturation_g_c_per_m3,
                .doc_biological_demand_fraction = doc_share,
                .acetate_biological_demand_fraction = acetate_share,
                .doc_respiration_requirement_g_c_per_g_c = context.parameters.doc_respiration_requirement_g_c_per_g_c[population],
                .acetate_respiration_requirement_g_c_per_g_c = context.parameters.acetate_respiration_requirement_g_c_per_g_c[population],
                .temperature_response = context.growth_temperature_response[cell],
                .timestep_h = context.timestep_h,
            });
            context.result.substrate_limited_respiration_g_c[state_index] = limited.substrate_limited_respiration_g_c;
            context.result.potential_oxygen_demand_g_o[state_index] = limited.potential_oxygen_demand_g_o;
            context.result.previous_doc_respiration_g_c[state_index] = limited.doc_respiration_g_c;
            context.result.previous_acetate_respiration_g_c[state_index] = limited.acetate_respiration_g_c;
        };
    }
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.biologically_active_water_m3.len != cells or context.growth_temperature_response.len != cells or context.matric_plus_osmotic_potential_megapascal.len != cells or context.litter_gas.cell_count != cells or context.litter_water_m3.len != cells or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.SurfaceMicrobialRespirationDimensionMismatch;
    inline for (.{ context.parameters.labile_biomass_fraction, context.parameters.doc_half_saturation_g_c_per_m3, context.parameters.acetate_half_saturation_g_c_per_m3, context.parameters.minimum_competition_fraction, context.parameters.specific_maintenance_respiration_g_c_per_g_n_per_h, context.parameters.decomposition_density_half_saturation_g_c_per_g_c, context.parameters.maintenance_density_half_saturation_g_c_per_g_c, context.parameters.acidity_half_response_mol_per_m3 }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSurfaceMicrobialRespirationParameter;
    if (context.parameters.labile_biomass_fraction > 1) return error.InvalidSurfaceMicrobialRespirationParameter;
    inline for (context.parameters.target_nitrogen_per_carbon_g_n_per_g_c ++ context.parameters.target_phosphorus_per_carbon_g_p_per_g_c) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSurfaceMicrobialRespirationParameter;
    for (context.parameters.nitrogen_fixation_yield_g_n_per_g_c) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceMicrobialRespirationParameter;
    inline for (.{ context.parameters.dinitrogen_half_saturation_g_n_per_m3, context.parameters.nonstructural_to_structural_rate_per_h, context.parameters.denitrification_growth_respiration_requirement_g_c_per_g_c }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSurfaceMicrobialRespirationParameter;
}

test "surface respiration tile retains separate DOC acetate demand and O2 potential" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.microbial[0] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    organic_state.dissolved[0].carbon_g_c = 3;
    organic_state.dissolved_acetate_carbon_g_c[0] = 1;
    organic_state.adsorbed[0].carbon_g_c = 1;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.potential_oxygen_demand_g_o[0] = 7;
    var litter_gas = try gas.State.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    const populations = [_]respiration.PopulationParameters{.{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0.125 }} ** source_population_count;
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .biologically_active_water_m3 = &.{1}, .growth_temperature_response = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .litter_gas = &litter_gas, .litter_water_m3 = &.{1}, .timestep_h = 1, .parameters = .{ .populations = populations, .target_nitrogen_per_carbon_g_n_per_g_c = .{0.1} ** unit_count_per_cell, .target_phosphorus_per_carbon_g_p_per_g_c = .{0.01} ** unit_count_per_cell, .doc_respiration_requirement_g_c_per_g_c = .{0.5} ** source_population_count, .acetate_respiration_requirement_g_c_per_g_c = .{0.25} ** source_population_count, .labile_biomass_fraction = 0.55, .doc_half_saturation_g_c_per_m3 = 12, .acetate_half_saturation_g_c_per_m3 = 12, .minimum_competition_fraction = 0.001, .specific_maintenance_respiration_g_c_per_g_n_per_h = 0.01, .decomposition_density_half_saturation_g_c_per_g_c = 0.01, .maintenance_density_half_saturation_g_c_per_g_c = 1e-6, .acidity_half_response_mol_per_m3 = 1, .nitrogen_fixation_yield_g_n_per_g_c = .{0} ** source_population_count, .dinitrogen_half_saturation_g_n_per_m3 = 0.14, .nonstructural_to_structural_rate_per_h = 0.25, .denitrification_growth_respiration_requirement_g_c_per_g_c = 0.7142857142857143 } };
    context.parameters.denitrification_growth_respiration_requirement_g_c_per_g_c = 0.7142857142857143;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.unlimited_respiration_g_c[0] > 0);
    try std.testing.expect(state.previous_doc_respiration_g_c[0] > 0);
    try std.testing.expect(state.previous_acetate_respiration_g_c[0] > 0);
    try std.testing.expectEqual(@as(f64, 7), state.previous_oxygen_demand_g_o[0]);
    try std.testing.expectApproxEqAbs(2.667 * state.substrate_limited_respiration_g_c[0], state.potential_oxygen_demand_g_o[0], 1e-15);
}

test "surface anaerobic populations retain demand history without oxygen demand" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.microbial[0] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    organic_state.microbial[4 * organic.kinetic_fraction_count] = organic_state.microbial[0];
    organic_state.dissolved[0].carbon_g_c = 3;
    organic_state.dissolved_acetate_carbon_g_c[0] = 2;
    organic_state.adsorbed[0].carbon_g_c = 1;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var litter_gas = try gas.State.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    var populations = [_]respiration.PopulationParameters{.{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0 }} ** source_population_count;
    populations[0] = .{ .metabolism = .fermenting_heterotroph, .substrate_unlimited_respiration_per_h = 0.125 };
    populations[4] = .{ .metabolism = .acetotrophic_methanogen, .substrate_unlimited_respiration_per_h = 0.125 };
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .biologically_active_water_m3 = &.{1}, .growth_temperature_response = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .litter_gas = &litter_gas, .litter_water_m3 = &.{1}, .timestep_h = 1, .parameters = .{ .populations = populations, .target_nitrogen_per_carbon_g_n_per_g_c = .{0.1} ** unit_count_per_cell, .target_phosphorus_per_carbon_g_p_per_g_c = .{0.01} ** unit_count_per_cell, .doc_respiration_requirement_g_c_per_g_c = .{0.5} ** source_population_count, .acetate_respiration_requirement_g_c_per_g_c = .{0.25} ** source_population_count, .labile_biomass_fraction = 0.55, .doc_half_saturation_g_c_per_m3 = 12, .acetate_half_saturation_g_c_per_m3 = 12, .minimum_competition_fraction = 0.001, .specific_maintenance_respiration_g_c_per_g_n_per_h = 0.01, .decomposition_density_half_saturation_g_c_per_g_c = 0.01, .maintenance_density_half_saturation_g_c_per_g_c = 1e-6, .acidity_half_response_mol_per_m3 = 1, .nitrogen_fixation_yield_g_n_per_g_c = .{0} ** source_population_count, .dinitrogen_half_saturation_g_n_per_m3 = 0.14, .nonstructural_to_structural_rate_per_h = 0.25, .denitrification_growth_respiration_requirement_g_c_per_g_c = 0.7142857142857143 } };
    context.parameters.denitrification_growth_respiration_requirement_g_c_per_g_c = 0.7142857142857143;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.unlimited_respiration_g_c[0] > 0);
    try std.testing.expect(state.previous_doc_respiration_g_c[0] > 0);
    try std.testing.expectEqual(@as(f64, 0), state.potential_oxygen_demand_g_o[0]);
    try std.testing.expectEqual(@as(f64, 0), state.unlimited_respiration_g_c[4]);
    try std.testing.expect(state.previous_acetate_respiration_g_c[4] > 0);
    try std.testing.expectEqual(@as(f64, 0), state.potential_oxygen_demand_g_o[4]);
}

test "NITRO 325 OXYI suppresses surface-litter fermentation toward zero as aqueous O2 rises" {
    // Regression pin for a fresh-domain audit finding: the sibling
    // surface-litter fermentation branch reproduced the soil-layer defect
    // NITRO-OXYI-FERMENTATION-001 fixed for `heterotrophic_respiration_step`
    // -- OXYI was entirely absent from this kernel's DOC-Monod demand, so
    // surface fermentation ran unsuppressed regardless of litter aeration.
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.microbial[0] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    organic_state.dissolved[0].carbon_g_c = 3;
    organic_state.adsorbed[0].carbon_g_c = 1;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var populations = [_]respiration.PopulationParameters{.{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0 }} ** source_population_count;
    populations[0] = .{ .metabolism = .fermenting_heterotroph, .substrate_unlimited_respiration_per_h = 0.125 };
    const parameters: Parameters = .{ .populations = populations, .target_nitrogen_per_carbon_g_n_per_g_c = .{0.1} ** unit_count_per_cell, .target_phosphorus_per_carbon_g_p_per_g_c = .{0.01} ** unit_count_per_cell, .doc_respiration_requirement_g_c_per_g_c = .{0.5} ** source_population_count, .acetate_respiration_requirement_g_c_per_g_c = .{0.25} ** source_population_count, .labile_biomass_fraction = 0.55, .doc_half_saturation_g_c_per_m3 = 12, .acetate_half_saturation_g_c_per_m3 = 12, .minimum_competition_fraction = 0.001, .specific_maintenance_respiration_g_c_per_g_n_per_h = 0.01, .decomposition_density_half_saturation_g_c_per_g_c = 0.01, .maintenance_density_half_saturation_g_c_per_g_c = 1e-6, .acidity_half_response_mol_per_m3 = 1, .nitrogen_fixation_yield_g_n_per_g_c = .{0} ** source_population_count, .dinitrogen_half_saturation_g_n_per_m3 = 0.14, .nonstructural_to_structural_rate_per_h = 0.25, .denitrification_growth_respiration_requirement_g_c_per_g_c = 0.7142857142857143 };

    var anoxic_gas = try gas.State.init(std.testing.allocator, 1);
    defer anoxic_gas.deinit();
    var anoxic_context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .biologically_active_water_m3 = &.{1}, .growth_temperature_response = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .litter_gas = &anoxic_gas, .litter_water_m3 = &.{1}, .timestep_h = 1, .parameters = parameters };
    try applyTile(&anoxic_context, .{ .first = 0, .end = 1 });
    const anoxic_demand = state.previous_doc_respiration_g_c[0];

    var aerated_gas = try gas.State.init(std.testing.allocator, 1);
    defer aerated_gas.deinit();
    // 15 g O across 1 m3 litter water = 15 g O m-3, far past OXYI's 2.5 g O
    // m-3 half-inhibition point, so OXYI collapses toward 0.
    aerated_gas.dissolved_mass_g[try gas.massIndex(0, .oxygen, 1)] = 15;
    var aerated_state = try State.init(std.testing.allocator, 1);
    defer aerated_state.deinit();
    var aerated_context: ApplyContext = .{ .result = &aerated_state, .surface_organic = &organic_state, .biologically_active_water_m3 = &.{1}, .growth_temperature_response = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .litter_gas = &aerated_gas, .litter_water_m3 = &.{1}, .timestep_h = 1, .parameters = parameters };
    try applyTile(&aerated_context, .{ .first = 0, .end = 1 });
    const aerated_demand = aerated_state.previous_doc_respiration_g_c[0];

    try std.testing.expect(anoxic_demand > 0);
    try std.testing.expect(aerated_demand < anoxic_demand * 1e-3);
    try std.testing.expect(aerated_demand >= 0);
}

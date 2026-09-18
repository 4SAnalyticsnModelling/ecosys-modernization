const std = @import("std");
const compute = @import("../../core/compute.zig");
const grid = @import("../../state/grid.zig");
const organic = @import("../organic/initialization.zig");
const microbial = @import("state.zig");
const metabolism = @import("metabolism.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const nitrogen_parameters = @import("../nutrients/nitrogen_parameters.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    process_unit_count_per_layer: usize,
    basal: []metabolism.DecompositionResult,
    senescence: []metabolism.DecompositionResult,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize, process_unit_count_per_layer: usize) !State {
        if (layer_count == 0 or process_unit_count_per_layer == 0) return error.InvalidSoilMicrobialTurnoverDimensions;
        const count = try std.math.mul(usize, try std.math.mul(usize, layer_count, process_unit_count_per_layer), 2);
        const basal = try allocator.alloc(metabolism.DecompositionResult, count);
        errdefer allocator.free(basal);
        const senescence = try allocator.alloc(metabolism.DecompositionResult, count);
        @memset(basal, zeroResult());
        @memset(senescence, zeroResult());
        return .{ .allocator = allocator, .layer_count = layer_count, .process_unit_count_per_layer = process_unit_count_per_layer, .basal = basal, .senescence = senescence };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.senescence);
        self.allocator.free(self.basal);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    microbial_state: *const microbial.State,
    organic_state: *const organic.State,
    maintenance_fluxes: *const fluxes.State,
    model_grid: *const grid.GridState,
    clay_mass_fraction: []const f64,
    /// SOIL-EHUM-001. HOUR1's live `AMIN1(0.55E+06, ORGC/BKVL)`, g C per Mg
    /// soil. Production sources this from `soil_solver_properties`, which
    /// derives it once at initialization rather than refreshing it hourly
    /// like legacy; that staleness is a known, smaller, separately tracked
    /// divergence (see the register entry), not introduced by this field.
    soil_organic_carbon_g_per_megagram: []const f64,
    matric_plus_osmotic_potential_megapascal: []const f64,
    thermal_adaptation_offset_k_by_cell: []const f64,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    microbial_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    substrate_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    substrate_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    parameters: nitrogen_parameters.Parameters,
    timestep_h: f64,
    negligible_carbon_g_c: f64,
};

/// NITRO RCC*, SPOMX/RXOM*/R3OM*/RDOM*, RHOM*/RCOM*, and the
/// maintenance-deficit RXMM*/R3MM*/RHMM*/RCMM* sequence.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const populations = context.microbial_state.population_count;
    const substrates = context.microbial_state.substrate_count;
    const turnover = context.parameters.microbial_turnover;
    const labile_fraction = context.parameters.nitrifier_environment.labile_biomass_fraction;
    for (range.first..range.end) |layer| for (0..substrates) |substrate| {
        const colonized_g_c = colonizedAndSorbedCarbon(context.organic_state, layer, substrate);
        for (0..populations) |population| {
            const unit = layer * context.result.process_unit_count_per_layer + substrate * populations + population;
            if (!microbial.nitroPopulationEnabled(substrate, population)) {
                context.result.basal[unit * 2] = zeroResult();
                context.result.basal[unit * 2 + 1] = zeroResult();
                context.result.senescence[unit * 2] = zeroResult();
                context.result.senescence[unit * 2 + 1] = zeroResult();
                continue;
            }
            const runtime_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
            const labile = context.microbial_state.structural[runtime_index * 2];
            const resistant = context.microbial_state.structural[runtime_index * 2 + 1];
            const nonstructural = context.microbial_state.nonstructural[runtime_index];
            const ratio = (substrate * populations + population) * 3;
            const recycling = try metabolism.recyclingFractions(nonstructural, context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio], context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio], .{
                .minimum_carbon_fraction = turnover.minimum_carbon_recycling_fraction,
                .carbon_range_fraction = turnover.carbon_recycling_range_fraction,
                .maximum_nitrogen_fraction = turnover.maximum_nitrogen_recycling_fraction,
                .maximum_phosphorus_fraction = turnover.maximum_phosphorus_recycling_fraction,
            });
            const active_g_c = labile.carbon_g_c / labile_fraction;
            const density = if (colonized_g_c > context.negligible_carbon_g_c) (active_g_c / colonized_g_c) / (active_g_c / colonized_g_c + context.parameters.heterotrophic_respiration.decomposition_density_half_saturation_g_c_per_g_c) else 1;
            const temperature = try metabolism.growthTemperatureResponse(context.model_grid.soil_temperature_k[layer], context.thermal_adaptation_offset_k_by_cell[layer / context.microbial_state.layer_count]);
            // NITRO.F 593--604: WFNG uses the fungal-specific 0.05 MPa-1
            // sensitivity only for the fungal population (source N=3, this
            // codebase's population index 2) within the heterotrophic
            // substrate complexes (source K<=4, this codebase's substrate
            // index < organic.substrate_count). The autotrophic complex
            // (K=5) always uses the bacterial sensitivity, even at
            // population index 2, since the fungal distinction does not
            // apply there (line 602--604's unconditional WFNG=EXP(0.10*PSISG)).
            const is_fungus = substrate < organic.substrate_count and population == 2;
            const water_sensitivity_per_megapascal: f64 = if (is_fungus) 0.05 else context.parameters.heterotrophic_respiration.water_potential_sensitivity_per_megapascal;
            const water = @exp(water_sensitivity_per_megapascal * context.matric_plus_osmotic_potential_megapascal[layer]);
            const humification = turnover.humification_intercept + turnover.humification_clay_coefficient * @min(turnover.humification_maximum_clay_fraction, context.clay_mass_fraction[layer]) + turnover.humification_organic_carbon_coefficient_per_g_per_megagram * context.soil_organic_carbon_g_per_megagram[layer];
            const pools = [2]metabolism.ElementalPool{ labile, resistant };
            const rates = [2]f64{ turnover.labile_basal_decomposition_rate_per_h, turnover.resistant_basal_decomposition_rate_per_h };
            for (0..2) |component| context.result.basal[unit * 2 + component] = try metabolism.decompose(.{
                .pool = pools[component],
                .temperature_response = @sqrt(temperature),
                .water_response = water,
                .basal_decomposition_rate_per_h = rates[component],
                .microbial_carbon_response = density,
                .timestep_h = context.timestep_h,
                .recycling = recycling,
                .humification_fraction = humification,
                .humus_nitrogen_per_carbon_g_n_per_g_c = context.substrate_nitrogen_to_carbon_g_n_per_g_c[4],
                .humus_phosphorus_per_carbon_g_p_per_g_c = context.substrate_phosphorus_to_carbon_g_p_per_g_c[4],
            });
            const active_n = if (labile.carbon_g_c > context.negligible_carbon_g_c) labile.nitrogen_g_n / labile.carbon_g_c else context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio];
            const active_p = if (labile.carbon_g_c > context.negligible_carbon_g_c) labile.phosphorus_g_p / labile.carbon_g_c else context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio];
            const accelerated = try metabolism.acceleratedSenescence(.{
                .structural = pools,
                .component_maintenance_respiration_g_c = .{ context.maintenance_fluxes.labile_maintenance_respiration_g_c[unit], context.maintenance_fluxes.resistant_maintenance_respiration_g_c[unit] },
                .total_maintenance_respiration_g_c = context.maintenance_fluxes.total_maintenance_respiration_g_c[unit],
                .senescence_respiration_deficit_g_c = context.maintenance_fluxes.senescence_respiration_deficit_g_c[unit],
                .recycling = recycling,
                .active_nitrogen_per_carbon_g_n_per_g_c = active_n,
                .active_phosphorus_per_carbon_g_p_per_g_c = active_p,
                .humification_fraction = humification,
                .humus_nitrogen_per_carbon_g_n_per_g_c = context.substrate_nitrogen_to_carbon_g_n_per_g_c[4],
                .humus_phosphorus_per_carbon_g_p_per_g_c = context.substrate_phosphorus_to_carbon_g_p_per_g_c[4],
                .negligible_g_c = context.negligible_carbon_g_c,
            });
            context.result.senescence[unit * 2] = accelerated.component[0];
            context.result.senescence[unit * 2 + 1] = accelerated.component[1];
        }
    };
}

fn colonizedAndSorbedCarbon(state: *const organic.State, layer: usize, substrate: usize) f64 {
    // The sixth microbial complex contains autotrophs and has no matching
    // organic substrate pool in STARTS.  Its density response is therefore
    // unbounded by colonized heterotrophic substrate carbon.
    if (substrate >= organic.substrate_count) return 0;
    const mobile = layer * organic.substrate_count + substrate;
    var total = state.adsorbed[mobile].carbon_g_c + state.adsorbed_acetate_carbon_g_c[mobile];
    for (0..organic.structural_fraction_count) |fraction| total += state.colonized_structural_carbon_g_c[mobile * organic.structural_fraction_count + fraction];
    for (0..organic.residue_fraction_count) |fraction| total += state.residue[mobile * organic.residue_fraction_count + fraction].carbon_g_c;
    return total;
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.model_grid.layer_count;
    const ratio_count = context.microbial_state.substrate_count * context.microbial_state.population_count * 3;
    if (range.first > range.end or range.end > layers or context.result.layer_count != layers or context.organic_state.layer_count != layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.microbial_state.substrate_count > organic.microbial_substrate_count or context.result.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or context.maintenance_fluxes.process_unit_count_per_layer != context.result.process_unit_count_per_layer or context.clay_mass_fraction.len != layers or context.soil_organic_carbon_g_per_megagram.len != layers or context.matric_plus_osmotic_potential_megapascal.len != layers or context.thermal_adaptation_offset_k_by_cell.len != context.microbial_state.cell_count or context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != ratio_count or context.microbial_phosphorus_to_carbon_g_p_per_g_c.len != ratio_count or context.substrate_nitrogen_to_carbon_g_n_per_g_c.len <= 4 or context.substrate_phosphorus_to_carbon_g_p_per_g_c.len <= 4) return error.SoilMicrobialTurnoverDimensionMismatch;
    for (context.thermal_adaptation_offset_k_by_cell) |offset_k| if (!std.math.isFinite(offset_k)) return error.NonFiniteMicrobialThermalAdaptationOffset;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0 or !std.math.isFinite(context.negligible_carbon_g_c) or context.negligible_carbon_g_c < 0) return error.InvalidSoilMicrobialTurnoverInput;
}

fn zeroResult() metabolism.DecompositionResult {
    const zero: metabolism.ElementalPool = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    return .{ .decomposed = zero, .recycled = zero, .humified = zero, .microbial_residue = zero };
}

test "runtime soil turnover conserves basal and senescence products" {
    var model_grid = try grid.GridState.init(std.testing.allocator, .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 });
    defer model_grid.deinit();
    model_grid.soil_temperature_k[0] = 293.15;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer microbial_state.deinit();
    microbial_state.structural[0] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 };
    microbial_state.structural[1] = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.1 };
    microbial_state.nonstructural[0] = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.04 };
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.adsorbed[0].carbon_g_c = 20;
    var maintenance = try fluxes.State.init(std.testing.allocator, 1, 1);
    defer maintenance.deinit();
    maintenance.labile_maintenance_respiration_g_c[0] = 0.6;
    maintenance.resistant_maintenance_respiration_g_c[0] = 0.4;
    maintenance.total_maintenance_respiration_g_c[0] = 1;
    maintenance.senescence_respiration_deficit_g_c[0] = 0.2;
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    const source =
        "soil_nitrification 0.001 0.0002 7000 14 1.4 1.4 0.125 0.125 0.3 0.1 0.5 2.667 3.429 1.143\n" ++
        "soil_denitrification 0.001 1.4 1.4 0.014 1 0.429 0.429 0.214 0.875\nsoil_autotrophic_denitrification 0.5 0.333\n" ++
        "soil_chemodenitrification 0.0005 0.001 1e-12 0.5 0 0.5\nnitrous_acid_dissociation_mol_per_m3 0.45\nsoil_microbial_thermal_adaptation_offset_k 0\n" ++
        "soil_nitrifier_indices 5 0 1 1\nsoil_nitrifier_environment 0.55 0.1 0.1 0.01 0.01 12 0.1\n" ++
        "soil_oxygen_uptake 1e-6 2.3866348449e11 0.064 -1.5e4 0.5 12 12 0.5 0.7 0.001 1e-12\n" ++
        "soil_heterotrophic_respiration 0.125 0.1 0.01 12 12 0.5 0.42016806722689076 0.1 2.667 0.01 0.01 1e-6 1 0.7142857142857143\n" ++
        "soil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\n" ++
        "soil_nonsymbiotic_nitrogen_fixation 5 6 0.25 0.02 0.14 0.25\n" ++
        "soil_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.150 0.300 0.333 0.25 2.0 5.0 1.0 0.5 0.182e-6";
    var context: ApplyContext = .{ .result = &state, .microbial_state = &microbial_state, .organic_state = &organic_state, .maintenance_fluxes = &maintenance, .model_grid = &model_grid, .clay_mass_fraction = &.{0.2}, .soil_organic_carbon_g_per_megagram = &.{14850}, .matric_plus_osmotic_potential_megapascal = &.{0}, .thermal_adaptation_offset_k_by_cell = &.{0}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &.{ 0.1, 0.1, 0.1 }, .microbial_phosphorus_to_carbon_g_p_per_g_c = &.{ 0.02, 0.02, 0.02 }, .substrate_nitrogen_to_carbon_g_n_per_g_c = &.{ 0.1, 0.1, 0.1, 0.1, 0.1 }, .substrate_phosphorus_to_carbon_g_p_per_g_c = &.{ 0.02, 0.02, 0.02, 0.02, 0.02 }, .parameters = try nitrogen_parameters.parse(source), .timestep_h = 1, .negligible_carbon_g_c = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.basal[0].decomposed.carbon_g_c > 0);
    try std.testing.expect(state.senescence[0].decomposed.carbon_g_c > 0);
    for ([_]metabolism.DecompositionResult{ state.basal[0], state.basal[1], state.senescence[0], state.senescence[1] }) |value| {
        try std.testing.expectApproxEqAbs(value.decomposed.carbon_g_c, value.recycled.carbon_g_c + value.humified.carbon_g_c + value.microbial_residue.carbon_g_c, 1e-12);
        try std.testing.expectApproxEqAbs(value.decomposed.nitrogen_g_n, value.recycled.nitrogen_g_n + value.humified.nitrogen_g_n + value.microbial_residue.nitrogen_g_n, 1e-12);
        try std.testing.expectApproxEqAbs(value.decomposed.phosphorus_g_p, value.recycled.phosphorus_g_p + value.humified.phosphorus_g_p + value.microbial_residue.phosphorus_g_p, 1e-12);
    }
}

test "autotrophic microbial complex does not require a sixth organic substrate pool" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.adsorbed[4].carbon_g_c = 3;

    try std.testing.expectEqual(@as(f64, 3), colonizedAndSorbedCarbon(&organic_state, 0, 4));
    try std.testing.expectEqual(@as(f64, 0), colonizedAndSorbedCarbon(&organic_state, 0, 5));
}

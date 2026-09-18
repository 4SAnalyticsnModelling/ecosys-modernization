const std = @import("std");
const compute = @import("../../core/compute.zig");
const gas = @import("../gas/transport.zig");
const grid = @import("../../state/grid.zig");
const microbial = @import("state.zig");
const metabolism = @import("metabolism.zig");
const nitrification_step = @import("nitrification_step.zig");
const nitrogen_parameters = @import("../nutrients/nitrogen_parameters.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    process_unit_count_per_layer: usize,
    roles: []nitrification_step.Role,
    temperature_water_activity: []f64,
    nitrogen_phosphorus_activity: []f64,
    aqueous_co2_activity: []f64,
    active_biomass_g_c: []f64,
    microbial_active_fraction: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize, process_unit_count_per_layer: usize) !State {
        if (layer_count == 0 or process_unit_count_per_layer == 0) return error.InvalidNitrifierEnvironmentDimensions;
        const count = try std.math.mul(usize, layer_count, process_unit_count_per_layer);
        const roles = try allocator.alloc(nitrification_step.Role, count);
        errdefer allocator.free(roles);
        var result: State = undefined;
        result.allocator = allocator;
        result.layer_count = layer_count;
        result.process_unit_count_per_layer = process_unit_count_per_layer;
        result.roles = roles;
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
        @memset(roles, .inactive);
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.allocator.free(self.roles);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    microbial_state: *const microbial.State,
    model_grid: *const grid.GridState,
    gas_state: *const gas.State,
    /// NITRO.F 254 (`PSISG=PSISM+PSISO`), consumed unconditionally for the
    /// autotrophic complex (`K=5`) by the WFNG water term at 602--604. Must
    /// be the matric-plus-osmotic total, not bare matric potential, so
    /// saline/sodic layers suppress the autotrophic nitrifier/denitrifier
    /// population the same way `nitro.f` suppresses every other population
    /// (see `turnover_step.zig`, `heterotrophic_respiration_step.zig`,
    /// `assimilation_step.zig`, `nitrogen_exchange_step.zig`,
    /// `phosphorus_exchange_step.zig`, `maintenance_step.zig`, all of which
    /// already source this from `soil_hourly_workspace`).
    matric_plus_osmotic_potential_megapascal: []const f64,
    thermal_adaptation_offset_k_by_cell: []const f64,
    parameters: nitrogen_parameters.Parameters,
};

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const populations = context.microbial_state.population_count;
    const indices = context.parameters.nitrifier_indices;
    const environment = context.parameters.nitrifier_environment;
    for (range.first..range.end) |layer| {
        const first = layer * context.result.process_unit_count_per_layer;
        @memset(context.result.roles[first .. first + context.result.process_unit_count_per_layer], .inactive);
        const ammonia_unit = first + indices.autotrophic_substrate_index * populations + indices.ammonia_oxidizer_population_index;
        const nitrite_unit = first + indices.autotrophic_substrate_index * populations + indices.nitrite_oxidizer_population_index;
        context.result.roles[ammonia_unit] = .ammonia_oxidizer;
        context.result.roles[nitrite_unit] = .nitrite_oxidizer;
        const temperature = try metabolism.growthTemperatureResponse(context.model_grid.soil_temperature_k[layer], context.thermal_adaptation_offset_k_by_cell[layer / context.microbial_state.layer_count]);
        const water = @exp(environment.water_potential_sensitivity_per_megapascal * context.matric_plus_osmotic_potential_megapascal[layer]);
        const water_m3 = context.model_grid.matrix_liquid_water_m3[layer];
        const co2_index = try gas.massIndex(layer, .carbon_dioxide, context.gas_state.cell_count);
        const co2_concentration = if (water_m3 > 0) context.gas_state.dissolved_mass_g[co2_index] / water_m3 else 0;
        const co2_activity = co2_concentration / (co2_concentration + environment.aqueous_co2_half_saturation_g_c_per_m3);
        const units = [2]usize{ ammonia_unit, nitrite_unit };
        const target_n = [2]f64{ environment.ammonia_oxidizer_target_nitrogen_per_carbon_g_n_per_g_c, environment.nitrite_oxidizer_target_nitrogen_per_carbon_g_n_per_g_c };
        const target_p = [2]f64{ environment.ammonia_oxidizer_target_phosphorus_per_carbon_g_p_per_g_c, environment.nitrite_oxidizer_target_phosphorus_per_carbon_g_p_per_g_c };
        var active: [2]f64 = undefined;
        var total_active: f64 = 0;
        for (units, 0..) |unit, role| {
            const labile = context.microbial_state.structural[unit * 2];
            active[role] = labile.carbon_g_c / environment.labile_biomass_fraction;
            total_active += active[role];
            const actual_n = if (labile.carbon_g_c > 0) labile.nitrogen_g_n / labile.carbon_g_c else target_n[role];
            const actual_p = if (labile.carbon_g_c > 0) labile.phosphorus_g_p / labile.carbon_g_c else target_p[role];
            const n_factor = @min(1, @max(0.1, std.math.pow(f64, actual_n / target_n[role], 0.25)));
            const p_factor = @min(1, @max(0.1, std.math.pow(f64, actual_p / target_p[role], 0.25)));
            context.result.temperature_water_activity[unit] = temperature * water;
            context.result.nitrogen_phosphorus_activity[unit] = @min(n_factor, p_factor);
            context.result.aqueous_co2_activity[unit] = co2_activity;
            context.result.active_biomass_g_c[unit] = active[role];
        }
        for (units, 0..) |unit, role| context.result.microbial_active_fraction[unit] = if (total_active > 0) active[role] / total_active else 0;
    }
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.model_grid.layer_count;
    if (range.first > range.end or range.end > layers or context.result.layer_count != layers or context.gas_state.cell_count != layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.matric_plus_osmotic_potential_megapascal.len != layers or context.thermal_adaptation_offset_k_by_cell.len != context.microbial_state.cell_count) return error.NitrifierEnvironmentDimensionMismatch;
    for (context.thermal_adaptation_offset_k_by_cell) |offset_k| if (!std.math.isFinite(offset_k)) return error.NonFiniteMicrobialThermalAdaptationOffset;
    const expected_units = try std.math.mul(usize, context.microbial_state.substrate_count, context.microbial_state.population_count);
    if (context.result.process_unit_count_per_layer != expected_units) return error.NitrifierEnvironmentDimensionMismatch;
    const indices = context.parameters.nitrifier_indices;
    if (indices.autotrophic_substrate_index >= context.microbial_state.substrate_count or indices.ammonia_oxidizer_population_index >= context.microbial_state.population_count or indices.nitrite_oxidizer_population_index >= context.microbial_state.population_count) return error.NitrifierRuntimeIndexOutOfBounds;
    try nitrogen_parameters.validate(context.parameters);
}

test "nitrifier environment consumes the authoritative per-cell offset" {
    var model_grid = try grid.GridState.init(std.testing.allocator, .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1, .worker_threads = 1, .tile_cells = 1, .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .mass_balance_tolerance = 1e-12, .negligible_quantity_threshold = 1e-12, .max_nonlinear_iterations = 20, .picard_relaxation = 0.5 });
    defer model_grid.deinit();
    @memset(model_grid.soil_temperature_k, 298.15);
    @memset(model_grid.matrix_liquid_water_m3, 1);
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[try gas.massIndex(0, .carbon_dioxide, 2)] = 12;
    gas_state.dissolved_mass_g[try gas.massIndex(1, .carbon_dioxide, 2)] = 12;
    var microbial_state = try microbial.State.init(std.testing.allocator, 2, 1, 6, 7);
    defer microbial_state.deinit();
    const ammonia = try microbial_state.populationIndex(0, 0, 5, 0);
    const nitrite = try microbial_state.populationIndex(0, 0, 5, 1);
    const adapted_ammonia = try microbial_state.populationIndex(1, 0, 5, 0);
    const adapted_nitrite = try microbial_state.populationIndex(1, 0, 5, 1);
    microbial_state.structural[ammonia * 2] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    microbial_state.structural[nitrite * 2] = .{ .carbon_g_c = 1.1, .nitrogen_g_n = 0.11, .phosphorus_g_p = 0.011 };
    microbial_state.structural[adapted_ammonia * 2] = microbial_state.structural[ammonia * 2];
    microbial_state.structural[adapted_nitrite * 2] = microbial_state.structural[nitrite * 2];
    var result = try State.init(std.testing.allocator, 2, 42);
    defer result.deinit();
    const source = "soil_nitrification 0.001 0.0002 7000 14 1.4 1.4 0.125 0.125 0.3 0.1 0.5 2.667 3.429 1.143\nsoil_denitrification 0.001 1.4 1.4 0.014 1 0.429 0.429 0.214 0.875\nsoil_autotrophic_denitrification 0.5 0.333\nsoil_chemodenitrification 0.0005 0.001 1e-12 0.5 0 0.5\nnitrous_acid_dissociation_mol_per_m3 0.45\nsoil_microbial_thermal_adaptation_offset_k 0\nsoil_nitrifier_indices 5 0 1 1\nsoil_nitrifier_environment 0.55 0.1 0.1 0.01 0.01 12 0.1\nsoil_oxygen_uptake 1e-6 2.3866348449e11 0.064 -1.5e4 0.5 12 12 0.5 0.7 0.001 1e-12\nsoil_heterotrophic_respiration 0.125 0.1 0.01 12 12 0.5 0.42016806722689076 0.1 2.667 0.01 0.01 1e-6 1 0.7142857142857143\nsoil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\nsoil_nonsymbiotic_nitrogen_fixation 5 6 0.25 0.02 0.14 0.25\nsoil_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.150 0.300 0.333";
    var context: ApplyContext = .{ .result = &result, .microbial_state = &microbial_state, .model_grid = &model_grid, .gas_state = &gas_state, .matric_plus_osmotic_potential_megapascal = &.{ 0, 0 }, .thermal_adaptation_offset_k_by_cell = &.{ 0, 3.1968 }, .parameters = try nitrogen_parameters.parse(source ++ " 0.25 2.0 5.0 1.0 0.5 0.182e-6") };
    try applyTile(&context, .{ .first = 0, .end = 2 });
    try std.testing.expectEqual(nitrification_step.Role.ammonia_oxidizer, result.roles[ammonia]);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.active_biomass_g_c[ammonia], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), result.microbial_active_fraction[nitrite], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.aqueous_co2_activity[ammonia], 1e-15);
    try std.testing.expect(
        result.temperature_water_activity[adapted_ammonia] >
            result.temperature_water_activity[ammonia],
    );
}

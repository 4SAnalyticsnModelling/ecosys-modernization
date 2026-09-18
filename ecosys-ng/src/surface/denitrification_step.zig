const std = @import("std");
const compute = @import("../core/compute.zig");
const gas = @import("../soil/gas/transport.zig");
const organic = @import("../soil/organic/initialization.zig");
const denitrification = @import("../soil/microbial/denitrification.zig");
const chemistry = @import("litter_chemistry.zig");
const respiration = @import("microbial_respiration_step.zig");
const oxygen = @import("microbial_oxygen_driver.zig");
const competition_history = @import("../soil/nutrients/competition_history.zig");

pub const denitrifier_population: usize = 1; // NITRO N=2

pub const ChemodenitrificationParameters = struct {
    nitrous_acid_reduction_rate_per_h: f64,
    nitrous_acid_dissociation_mol_per_m3: f64,
    nitrous_oxide_yield_g_n_per_g_n: f64,
    dissolved_organic_nitrogen_yield_g_n_per_g_n: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    nitrite_g_n: []f64,
    previous_total_nitrate_demand_g_n: []f64,
    previous_total_nitrite_demand_g_n: []f64,
    previous_total_nitrous_oxide_demand_g_n: []f64,
    previous_nitrate_capacity_g_n: []f64,
    previous_nitrite_capacity_g_n: []f64,
    previous_nitrous_oxide_capacity_g_n: []f64,
    nitrate_reduction_g_n: []f64,
    nitrite_reduction_g_n: []f64,
    nitrous_oxide_reduction_g_n: []f64,
    respiration_g_c: []f64,
    previous_chemodenitrification_capacity_g_n: []f64,
    chemodenitrification_nitrite_reduction_g_n: []f64,
    chemodenitrification_nitrous_oxide_production_g_n: []f64,
    chemodenitrification_dissolved_organic_nitrogen_production_g_n: []f64,

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
        if (cell_count == 0) return error.ZeroSurfaceDenitrificationCells;
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            const count = if (std.mem.eql(u8, field.name, "nitrite_g_n") or std.mem.startsWith(u8, field.name, "previous_total_") or std.mem.startsWith(u8, field.name, "previous_chemo") or std.mem.startsWith(u8, field.name, "chemodenitrification_")) cell_count else try std.math.mul(usize, cell_count, respiration.litter_complex_count);
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

test "surface denitrification state releases every partial allocation prefix" {
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

pub const ApplyContext = struct {
    result: *State,
    surface_organic: *const organic.State,
    litter_chemistry: *const chemistry.State,
    litter_gas: *const gas.State,
    litter_water_m3: []const f64,
    biologically_active_water_m3: []const f64,
    growth_temperature_response: []const f64,
    respiration: *const respiration.State,
    oxygen: *const oxygen.State,
    /// Prepared K=5 N=1,2,3,5 active biomass included in source TOMA/FOMA.
    autotrophic_active_biomass_g_c: []const f64 = &.{},
    microbial_parameters: respiration.Parameters,
    parameters: denitrification.Parameters,
    chemodenitrification_parameters: ChemodenitrificationParameters,
    nitrogen_molar_mass_g_per_mol: f64,
    timestep_h: f64,
    negligible_water_volume_m3: f64,
    negligible_nitrogen_g_n: f64,
    nutrient_competition: ?*const competition_history.State = null,
    nutrient_competition_attempt: ?*competition_history.Attempt = null,
};

/// Derives NITRO's L=0, K=1..3, N=2 NO3 -> NO2 -> N2O -> N2 pathway.
/// Inventories are not mutated here; the later atomic C/N/gas transaction
/// state_updates all competing microbial potentials together.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| {
        const water_m3 = context.litter_water_m3[cell];
        const active_water_m3 = context.biologically_active_water_m3[cell];
        const nitrate_concentration_g_n_per_m3 = context.litter_chemistry.cells[cell].nitrate_mol_per_m3 * context.nitrogen_molar_mass_g_per_mol;
        const nitrate_g_n = nitrate_concentration_g_n_per_m3 * water_m3;
        const nitrite_g_n = context.result.nitrite_g_n[cell];
        const nitrite_concentration_g_n_per_m3 = if (water_m3 > 0) nitrite_g_n / water_m3 else 0;
        const n2o_index = cell * gas.species_count + @intFromEnum(gas.Species.nitrous_oxide);
        const n2o_g_n = context.litter_gas.dissolved_mass_g[n2o_index];
        const n2o_concentration_g_n_per_m3 = if (water_m3 > 0) n2o_g_n / water_m3 else 0;

        var total_active_g_c: f64 = 0;
        var complex_active_g_c: [respiration.litter_complex_count]f64 = undefined;
        var total_doc_demand_g_c: [respiration.litter_complex_count]f64 = .{0} ** respiration.litter_complex_count;
        var total_raw_doc_share: [respiration.litter_complex_count]f64 = .{0} ** respiration.litter_complex_count;
        for (0..respiration.litter_complex_count) |complex| {
            var active: f64 = 0;
            for (0..respiration.source_population_count) |population| {
                const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
                active += context.surface_organic.microbial[microbial].carbon_g_c / context.microbial_parameters.labile_biomass_fraction;
                total_doc_demand_g_c[complex] += context.respiration.previous_doc_respiration_g_c[cell * respiration.unit_count_per_cell + complex * respiration.source_population_count + population];
            }
            complex_active_g_c[complex] = active;
            total_active_g_c += active;
            for (0..respiration.source_population_count) |population| {
                const unit = cell * respiration.unit_count_per_cell + complex * respiration.source_population_count + population;
                const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
                const population_active_g_c = context.surface_organic.microbial[microbial].carbon_g_c / context.microbial_parameters.labile_biomass_fraction;
                const fallback = if (active > 0) population_active_g_c / active else 0;
                total_raw_doc_share[complex] += @max(context.microbial_parameters.minimum_competition_fraction, if (total_doc_demand_g_c[complex] > 0) context.respiration.previous_doc_respiration_g_c[unit] / total_doc_demand_g_c[complex] else fallback);
            }
        }
        if (context.autotrophic_active_biomass_g_c.len != 0) {
            const first = cell * 4;
            for (context.autotrophic_active_biomass_g_c[first .. first + 4]) |active|
                total_active_g_c += active;
        }

        var next_total_nitrate_demand: f64 = 0;
        var next_total_nitrite_demand: f64 = 0;
        var next_total_n2o_demand: f64 = 0;
        for (0..respiration.litter_complex_count) |complex| {
            const compact = cell * respiration.litter_complex_count + complex;
            const unit = cell * respiration.unit_count_per_cell + complex * respiration.source_population_count + denitrifier_population;
            const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + denitrifier_population) * organic.kinetic_fraction_count;
            const active_g_c = context.surface_organic.microbial[microbial].carbon_g_c / context.microbial_parameters.labile_biomass_fraction;
            const active_fraction = if (complex_active_g_c[complex] > 0) active_g_c / complex_active_g_c[complex] else 0;
            const total_active_fraction = if (total_active_g_c > 0) active_g_c / total_active_g_c else 0;
            const substrate_fraction = if (total_active_g_c > 0) complex_active_g_c[complex] / total_active_g_c else 0;
            const doc_share = @max(context.microbial_parameters.minimum_competition_fraction, if (total_doc_demand_g_c[complex] > 0) context.respiration.previous_doc_respiration_g_c[unit] / total_doc_demand_g_c[complex] else active_fraction) / @max(1, total_raw_doc_share[complex]);
            const oxygen_fraction = context.oxygen.allocation.demand_satisfaction_fraction[unit];
            const aerobic_doc_respiration_g_c = context.respiration.previous_doc_respiration_g_c[unit] * oxygen_fraction;
            const residual_doc_after_aerobic_g_c = @max(0, context.surface_organic.dissolved[cell * organic.substrate_count + complex].carbon_g_c * doc_share - aerobic_doc_respiration_g_c);
            const available_doc_g_c = residual_doc_after_aerobic_g_c * context.microbial_parameters.denitrification_growth_respiration_requirement_g_c_per_g_c;
            const oxygen_demand_g_o = context.respiration.potential_oxygen_demand_g_o[unit];
            const oxygen_reduction_g_o = oxygen_demand_g_o * oxygen_fraction;
            const zone: denitrification.Zone = .{
                .nitrate_fraction = 1,
                .nitrite_fraction = 1,
                .nitrate_concentration_g_n_per_m3 = nitrate_concentration_g_n_per_m3,
                .nitrite_concentration_g_n_per_m3 = nitrite_concentration_g_n_per_m3,
                .nitrate_amount_g_n = nitrate_g_n,
                .nitrite_amount_g_n = nitrite_g_n,
                .previous_total_nitrate_demand_g_n = if (context.nutrient_competition) |accepted| try accepted.surfaceTotal(.nitrate, cell) else context.result.previous_total_nitrate_demand_g_n[cell],
                .previous_nitrate_reduction_capacity_g_n = if (context.nutrient_competition) |accepted| try accepted.surfaceDenitrificationCapacity(cell, complex) else context.result.previous_nitrate_capacity_g_n[compact],
                .previous_total_nitrite_demand_g_n = context.result.previous_total_nitrite_demand_g_n[cell],
                .previous_nitrite_reduction_capacity_g_n = context.result.previous_nitrite_capacity_g_n[compact],
                .fallback_available_fraction = 1,
            };
            const potential = try denitrification.calculateHeterotrophicPotential(.{
                .non_band = zone,
                .band = zeroZone(),
                .oxygen_demand_g_o = oxygen_demand_g_o,
                .oxygen_reduction_g_o = oxygen_reduction_g_o,
                .biologically_active_water_m3 = active_water_m3,
                .substrate_complex_fraction = substrate_fraction,
                .available_doc_g_c = available_doc_g_c,
                .microbial_active_fraction = total_active_fraction,
                .nitrous_oxide_concentration_g_n_per_m3 = n2o_concentration_g_n_per_m3,
                .nitrous_oxide_amount_g_n = n2o_g_n,
                .previous_total_nitrous_oxide_demand_g_n = context.result.previous_total_nitrous_oxide_demand_g_n[cell],
                .previous_nitrous_oxide_reduction_capacity_g_n = context.result.previous_nitrous_oxide_capacity_g_n[compact],
                .timestep_h = context.timestep_h,
                .negligible_water_volume_m3 = context.negligible_water_volume_m3,
                .negligible_nitrogen_g_n = context.negligible_nitrogen_g_n,
            }, context.parameters);
            context.result.nitrate_reduction_g_n[compact] = potential.non_band_nitrate_reduction_g_n;
            context.result.nitrite_reduction_g_n[compact] = potential.non_band_nitrite_reduction_g_n;
            context.result.nitrous_oxide_reduction_g_n[compact] = potential.nitrous_oxide_reduction_g_n;
            context.result.respiration_g_c[compact] = potential.nitrate_reduction_respiration_g_c + potential.nitrite_reduction_respiration_g_c + potential.nitrous_oxide_reduction_respiration_g_c;
            context.result.previous_nitrate_capacity_g_n[compact] = potential.non_band_nitrate_capacity_g_n;
            context.result.previous_nitrite_capacity_g_n[compact] = potential.non_band_nitrite_capacity_g_n;
            context.result.previous_nitrous_oxide_capacity_g_n[compact] = potential.nitrous_oxide_capacity_g_n;
            if (context.nutrient_competition_attempt) |attempt|
                try attempt.recordSurfaceDenitrification(cell, complex, potential.non_band_nitrate_capacity_g_n);
            next_total_nitrate_demand += potential.non_band_nitrate_capacity_g_n;
            next_total_nitrite_demand += potential.non_band_nitrite_capacity_g_n;
            next_total_n2o_demand += potential.nitrous_oxide_capacity_g_n;
        }
        const chemo = context.chemodenitrification_parameters;
        const previous_total_nitrite_demand = context.result.previous_total_nitrite_demand_g_n[cell];
        const allocation_fraction = if (previous_total_nitrite_demand > context.negligible_nitrogen_g_n)
            @max(context.parameters.minimum_competition_fraction, context.result.previous_chemodenitrification_capacity_g_n[cell] / previous_total_nitrite_demand)
        else
            context.parameters.minimum_competition_fraction;
        const hydrogen_mol_per_m3 = @max(0, context.litter_chemistry.cells[cell].hydrogen_mol_per_m3);
        const nitrous_acid_fraction = hydrogen_mol_per_m3 / (hydrogen_mol_per_m3 + chemo.nitrous_acid_dissociation_mol_per_m3);
        const nitrous_acid_g_n_per_m3 = nitrite_concentration_g_n_per_m3 * nitrous_acid_fraction;
        const chemo_capacity_g_n = chemo.nitrous_acid_reduction_rate_per_h * nitrous_acid_g_n_per_m3 * active_water_m3 * context.growth_temperature_response[cell] * context.timestep_h;
        const chemo_reduction_g_n = @max(0, @min(nitrite_g_n * allocation_fraction, chemo_capacity_g_n));
        context.result.chemodenitrification_nitrite_reduction_g_n[cell] = chemo_reduction_g_n;
        context.result.chemodenitrification_nitrous_oxide_production_g_n[cell] = chemo_reduction_g_n * chemo.nitrous_oxide_yield_g_n_per_g_n;
        context.result.chemodenitrification_dissolved_organic_nitrogen_production_g_n[cell] = chemo_reduction_g_n * chemo.dissolved_organic_nitrogen_yield_g_n_per_g_n;
        context.result.previous_chemodenitrification_capacity_g_n[cell] = chemo_capacity_g_n;
        next_total_nitrite_demand += chemo_capacity_g_n;
        context.result.previous_total_nitrate_demand_g_n[cell] = next_total_nitrate_demand;
        context.result.previous_total_nitrite_demand_g_n[cell] = next_total_nitrite_demand;
        context.result.previous_total_nitrous_oxide_demand_g_n[cell] = next_total_n2o_demand;
    }
}

fn zeroZone() denitrification.Zone {
    return .{ .nitrate_fraction = 0, .nitrite_fraction = 0, .nitrate_concentration_g_n_per_m3 = 0, .nitrite_concentration_g_n_per_m3 = 0, .nitrate_amount_g_n = 0, .nitrite_amount_g_n = 0, .previous_total_nitrate_demand_g_n = 0, .previous_nitrate_reduction_capacity_g_n = 0, .previous_total_nitrite_demand_g_n = 0, .previous_nitrite_reduction_capacity_g_n = 0, .fallback_available_fraction = 0 };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.litter_chemistry.cells.len != cells or context.litter_gas.cell_count != cells or context.litter_water_m3.len != cells or context.biologically_active_water_m3.len != cells or context.growth_temperature_response.len != cells or context.respiration.cell_count != cells or context.oxygen.cell_count != cells or (context.autotrophic_active_biomass_g_c.len != 0 and context.autotrophic_active_biomass_g_c.len != cells * 4)) return error.SurfaceDenitrificationDimensionMismatch;
    for (context.autotrophic_active_biomass_g_c) |active| if (!std.math.isFinite(active) or active < 0) return error.InvalidSurfaceDenitrificationRuntimeParameter;
    if (!std.math.isFinite(context.nitrogen_molar_mass_g_per_mol) or context.nitrogen_molar_mass_g_per_mol <= 0 or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0 or !std.math.isFinite(context.negligible_water_volume_m3) or context.negligible_water_volume_m3 < 0 or !std.math.isFinite(context.negligible_nitrogen_g_n) or context.negligible_nitrogen_g_n < 0) return error.InvalidSurfaceDenitrificationRuntimeParameter;
    if ((context.nutrient_competition == null) != (context.nutrient_competition_attempt == null)) return error.IncompleteSurfaceDenitrificationNutrientCompetitionBinding;
    if (context.nutrient_competition) |accepted| if (accepted.surface_cell_count != cells) return error.SurfaceDenitrificationDimensionMismatch;
    const chemo = context.chemodenitrification_parameters;
    inline for (.{ chemo.nitrous_acid_reduction_rate_per_h, chemo.nitrous_acid_dissociation_mol_per_m3, chemo.nitrous_oxide_yield_g_n_per_g_n, chemo.dissolved_organic_nitrogen_yield_g_n_per_g_n }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceDenitrificationRuntimeParameter;
    if (chemo.nitrous_acid_dissociation_mol_per_m3 <= 0 or @abs(chemo.nitrous_oxide_yield_g_n_per_g_n + chemo.dissolved_organic_nitrogen_yield_g_n_per_g_n - 1) > 1e-12) return error.InvalidSurfaceDenitrificationRuntimeParameter;
}

test "surface denitrification derives source sequential respiration without mutation" {
    var surface_organic = try organic.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    surface_organic.microbial[organic.kinetic_fraction_count * denitrifier_population] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    surface_organic.dissolved[0].carbon_g_c = 10;
    var litter_chemistry = try chemistry.State.init(std.testing.allocator, 1);
    defer litter_chemistry.deinit();
    litter_chemistry.cells[0].nitrate_mol_per_m3 = 1;
    litter_chemistry.cells[0].hydrogen_mol_per_m3 = 0.45;
    var litter_gas = try gas.State.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    litter_gas.dissolved_mass_g[@intFromEnum(gas.Species.nitrous_oxide)] = 1;
    var respiration_state = try respiration.State.init(std.testing.allocator, 1);
    defer respiration_state.deinit();
    respiration_state.potential_oxygen_demand_g_o[denitrifier_population] = 4;
    respiration_state.previous_doc_respiration_g_c[denitrifier_population] = 0.1;
    var oxygen_state = try oxygen.State.init(std.testing.allocator, 1);
    defer oxygen_state.deinit();
    oxygen_state.allocation.demand_satisfaction_fraction[denitrifier_population] = 0.25;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.nitrite_g_n[0] = 2;
    var microbial_parameters: respiration.Parameters = undefined;
    microbial_parameters.labile_biomass_fraction = 0.55;
    microbial_parameters.minimum_competition_fraction = 0.001;
    microbial_parameters.denitrification_growth_respiration_requirement_g_c_per_g_c = 0.7142857142857143;
    var context: ApplyContext = .{ .result = &state, .surface_organic = &surface_organic, .litter_chemistry = &litter_chemistry, .litter_gas = &litter_gas, .litter_water_m3 = &.{1}, .biologically_active_water_m3 = &.{1}, .growth_temperature_response = &.{1}, .respiration = &respiration_state, .oxygen = &oxygen_state, .microbial_parameters = microbial_parameters, .parameters = .{ .minimum_competition_fraction = 0.001, .nitrate_half_saturation_g_n_per_m3 = 1.4, .nitrite_half_saturation_g_n_per_m3 = 1.4, .nitrous_oxide_half_saturation_g_n_per_m3 = 0.014, .product_inhibition_rate_g_n_per_m3_step = 1, .carbon_per_nitrate_n_g_c_per_g_n = 0.429, .carbon_per_nitrite_n_g_c_per_g_n = 0.429, .carbon_per_nitrous_oxide_n_g_c_per_g_n = 0.214, .nitrate_n_per_unmet_oxygen_g_n_per_g_o = 0.875 }, .chemodenitrification_parameters = .{ .nitrous_acid_reduction_rate_per_h = 0.0005, .nitrous_acid_dissociation_mol_per_m3 = 0.45, .nitrous_oxide_yield_g_n_per_g_n = 0.5, .dissolved_organic_nitrogen_yield_g_n_per_g_n = 0.5 }, .nitrogen_molar_mass_g_per_mol = 14, .timestep_h = 1, .negligible_water_volume_m3 = 1e-12, .negligible_nitrogen_g_n = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.nitrate_reduction_g_n[0] > 0);
    try std.testing.expect(state.respiration_g_c[0] > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0005), state.chemodenitrification_nitrite_reduction_g_n[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00025), state.chemodenitrification_nitrous_oxide_production_g_n[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00025), state.chemodenitrification_dissolved_organic_nitrogen_production_g_n[0], 1e-15);
    try std.testing.expectEqual(@as(f64, 1), litter_chemistry.cells[0].nitrate_mol_per_m3);
}

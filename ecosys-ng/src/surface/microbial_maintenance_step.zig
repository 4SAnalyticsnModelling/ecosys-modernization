const std = @import("std");
const compute = @import("../core/compute.zig");
const organic = @import("../soil/organic/initialization.zig");
const chemistry = @import("litter_chemistry.zig");
const metabolism = @import("../soil/microbial/metabolism.zig");
const respiration = @import("microbial_respiration_step.zig");
const oxygen = @import("microbial_oxygen_driver.zig");
const environment = @import("microbial_environment_step.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    maintenance_density_response: []f64,
    labile_maintenance_respiration_g_c: []f64,
    resistant_maintenance_respiration_g_c: []f64,
    total_maintenance_respiration_g_c: []f64,
    growth_respiration_g_c: []f64,
    senescence_respiration_deficit_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceMicrobialMaintenanceCells;
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
    surface_organic: *const organic.State,
    litter_chemistry: *const chemistry.State,
    respiration: *const respiration.State,
    oxygen: *const oxygen.State,
    environment: *const environment.State,
    timestep_h: f64,
    parameters: respiration.Parameters,
};

/// NITRO OMC2/OMN2, COMC/RMOMK, HOUR1 FPH, and RMOMC/RGOMT/RXOMT.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| {
        const ph = context.litter_chemistry.ph[cell];
        if (!std.math.isFinite(ph)) return error.InvalidSurfaceLitterPh;
        var has_active_biomass = false;
        for (0..respiration.litter_complex_count) |complex| {
            for (0..respiration.source_population_count) |population| {
                const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
                if (context.surface_organic.microbial[microbial].carbon_g_c > 0 or
                    context.surface_organic.microbial[microbial + 1].carbon_g_c > 0)
                {
                    has_active_biomass = true;
                    break;
                }
            }
            if (has_active_biomass) break;
        }
        if (!has_active_biomass) {
            const first = cell * respiration.unit_count_per_cell;
            const end = first + respiration.unit_count_per_cell;
            @memset(context.result.maintenance_density_response[first..end], 0);
            @memset(context.result.labile_maintenance_respiration_g_c[first..end], 0);
            @memset(context.result.resistant_maintenance_respiration_g_c[first..end], 0);
            @memset(context.result.total_maintenance_respiration_g_c[first..end], 0);
            @memset(context.result.growth_respiration_g_c[first..end], 0);
            @memset(context.result.senescence_respiration_deficit_g_c[first..end], 0);
            continue;
        }
        const ph_response = try metabolism.maintenancePhResponse(ph, context.parameters.acidity_half_response_mol_per_m3);
        for (0..respiration.litter_complex_count) |complex| {
            var colonized_substrate_g_c: f64 = 0;
            for (0..organic.structural_fraction_count) |fraction| colonized_substrate_g_c += context.surface_organic.colonized_structural_carbon_g_c[(cell * organic.substrate_count + complex) * organic.structural_fraction_count + fraction];
            for (0..organic.residue_fraction_count) |fraction| colonized_substrate_g_c += context.surface_organic.residue[(cell * organic.substrate_count + complex) * organic.residue_fraction_count + fraction].carbon_g_c;
            const mobile = cell * organic.substrate_count + complex;
            colonized_substrate_g_c += context.surface_organic.adsorbed[mobile].carbon_g_c + context.surface_organic.adsorbed_acetate_carbon_g_c[mobile];
            for (0..respiration.source_population_count) |population| {
                const unit = complex * respiration.source_population_count + population;
                const state_index = cell * respiration.unit_count_per_cell + unit;
                const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
                const labile = context.surface_organic.microbial[microbial];
                const resistant = context.surface_organic.microbial[microbial + 1];
                const active_biomass_g_c = labile.carbon_g_c / context.parameters.labile_biomass_fraction;
                const active_resistant_carbon_g_c = @max(0, @min(active_biomass_g_c * (1 - context.parameters.labile_biomass_fraction), resistant.carbon_g_c));
                const active_resistant_fraction = if (resistant.carbon_g_c > 0) active_resistant_carbon_g_c / resistant.carbon_g_c else 0;
                const active_resistant_nitrogen_g_n = @max(0, active_resistant_fraction * resistant.nitrogen_g_n);
                const concentration = if (colonized_substrate_g_c > 0) active_biomass_g_c / colonized_substrate_g_c else 0;
                const density_response = if (colonized_substrate_g_c > 0) concentration / (concentration + context.parameters.maintenance_density_half_saturation_g_c_per_g_c) else 1;
                const oxygen_fraction = if (context.oxygen.populations[state_index].is_aerobic) context.oxygen.allocation.demand_satisfaction_fraction[state_index] else 1;
                const actual_respiration_g_c = context.respiration.substrate_limited_respiration_g_c[state_index] * oxygen_fraction;
                const value = try metabolism.maintenance(.{
                    .labile_nitrogen_g_n = labile.nitrogen_g_n,
                    .resistant_nitrogen_g_n = active_resistant_nitrogen_g_n,
                    .specific_maintenance_g_c_per_g_n_h = context.parameters.specific_maintenance_respiration_g_c_per_g_n_per_h,
                    .temperature_response = context.environment.maintenance_temperature_response[cell],
                    .ph_response = ph_response,
                    .low_carbon_response = density_response,
                    .timestep_h = context.timestep_h,
                    .oxygen_limited_respiration_g_c = actual_respiration_g_c,
                });
                context.result.maintenance_density_response[state_index] = density_response;
                context.result.labile_maintenance_respiration_g_c[state_index] = value.labile_respiration_g_c;
                context.result.resistant_maintenance_respiration_g_c[state_index] = value.resistant_respiration_g_c;
                context.result.total_maintenance_respiration_g_c[state_index] = value.total_maintenance_g_c;
                context.result.growth_respiration_g_c[state_index] = value.growth_respiration_g_c;
                context.result.senescence_respiration_deficit_g_c[state_index] = value.senescence_respiration_deficit_g_c;
            }
        }
    }
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.litter_chemistry.cells.len != cells or context.litter_chemistry.ph.len != cells or context.respiration.cell_count != cells or context.oxygen.cell_count != cells or context.environment.biologically_active_water_m3.len != cells) return error.SurfaceMicrobialMaintenanceDimensionMismatch;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.InvalidSurfaceMicrobialMaintenanceTimestep;
}

test "surface maintenance reproduces active resistant nitrogen and pH response" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.microbial[0] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    organic_state.microbial[1] = .{ .carbon_g_c = 0.60, .nitrogen_g_n = 0.06, .phosphorus_g_p = 0.006 };
    organic_state.adsorbed[0].carbon_g_c = 10;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.cells[0].hydrogen_mol_per_m3 = 1e-3;
    chemistry_state.ph[0] = 6;
    var respiration_state = try respiration.State.init(std.testing.allocator, 1);
    defer respiration_state.deinit();
    respiration_state.substrate_limited_respiration_g_c[0] = 1;
    var oxygen_state = try oxygen.State.init(std.testing.allocator, 1);
    defer oxygen_state.deinit();
    oxygen_state.populations[0].is_aerobic = false;
    var environment_state = try environment.State.init(std.testing.allocator, 1);
    defer environment_state.deinit();
    environment_state.maintenance_temperature_response[0] = 1;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var parameters: respiration.Parameters = undefined;
    parameters.labile_biomass_fraction = 0.55;
    parameters.specific_maintenance_respiration_g_c_per_g_n_per_h = 0.01;
    parameters.maintenance_density_half_saturation_g_c_per_g_c = 1e-6;
    parameters.acidity_half_response_mol_per_m3 = 1;
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .litter_chemistry = &chemistry_state, .respiration = &respiration_state, .oxygen = &oxygen_state, .environment = &environment_state, .timestep_h = 1, .parameters = parameters };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.resistant_maintenance_respiration_g_c[0] > 0);
    try std.testing.expect(state.total_maintenance_respiration_g_c[0] > state.labile_maintenance_respiration_g_c[0]);
    try std.testing.expect(state.growth_respiration_g_c[0] > 0);

    const retained_ph_respiration = state.total_maintenance_respiration_g_c[0];
    chemistry_state.cells[0].hydrogen_mol_per_m3 = 0;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(retained_ph_respiration, state.total_maintenance_respiration_g_c[0]);

    organic_state.microbial[0] = .{};
    organic_state.microbial[1] = .{};
    chemistry_state.cells[0].hydrogen_mol_per_m3 = 0;
    @memset(state.total_maintenance_respiration_g_c, 1);
    try applyTile(&context, .{ .first = 0, .end = 1 });
    for (state.total_maintenance_respiration_g_c) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
}

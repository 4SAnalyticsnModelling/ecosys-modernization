const std = @import("std");
const compute = @import("../core/compute.zig");
const gas = @import("../soil/gas/transport.zig");
const organic = @import("../soil/organic/initialization.zig");
const metabolism = @import("../soil/microbial/metabolism.zig");
const respiration = @import("microbial_respiration_step.zig");
const maintenance = @import("microbial_maintenance_step.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    respiration_required_g_c: []f64,
    fixation_respiration_g_c: []f64,
    fixed_nitrogen_g_n: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceNitrogenFixationCells;
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
    maintenance: *const maintenance.State,
    litter_gas: *const gas.State,
    litter_water_m3: []const f64,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    parameters: respiration.Parameters,
    timestep_h: f64,
};

/// NITRO RGN2P/RGN2F/RN2FX for aerobic and anaerobic diazotrophs.
///
/// Corrected formulation, `docs/model_changes.md` NITRO-N2FIX-SUPPLY. As in
/// the soil owner, the source's Monod ratio on `CZ2GS = Z2GS/VOLW` is
/// intensive and cannot bound an extensive draw, so litter fixation is
/// additionally limited by the dissolved N2 mass actually present and
/// apportioned across the competing diazotroph populations by demand.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const n2_offset = @intFromEnum(gas.Species.nitrogen);
    for (range.first..range.end) |cell| {
        const dissolved_n2_g_n = @max(0, context.litter_gas.dissolved_mass_g[cell * gas.species_count + n2_offset]);
        const n2_concentration_g_n_per_m3 = if (context.litter_water_m3[cell] > 0) dissolved_n2_g_n / context.litter_water_m3[cell] else 0;
        var cell_demand_g_n: f64 = 0;
        for (0..respiration.litter_complex_count) |complex| for (0..respiration.source_population_count) |population| {
            const unit = complex * respiration.source_population_count + population;
            const index = cell * respiration.unit_count_per_cell + unit;
            const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
            const nonstructural = context.surface_organic.microbial[microbial + 2];
            const ratio_index = (complex * organic.microbial_population_count + population) * organic.kinetic_fraction_count + 2;
            const value = try metabolism.nonsymbioticNitrogenFixation(.{
                .is_diazotroph = population == 5 or population == 6,
                .nonstructural_carbon_g_c = nonstructural.carbon_g_c,
                .nonstructural_nitrogen_g_n = nonstructural.nitrogen_g_n,
                .maximum_nitrogen_per_carbon_g_n_per_g_c = context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_index],
                .nitrogen_fixation_yield_g_n_per_g_c = context.parameters.nitrogen_fixation_yield_g_n_per_g_c[population],
                .growth_respiration_g_c = context.maintenance.growth_respiration_g_c[index],
                .aqueous_dinitrogen_concentration_g_n_per_m3 = n2_concentration_g_n_per_m3,
                .dinitrogen_half_saturation_g_n_per_m3 = context.parameters.dinitrogen_half_saturation_g_n_per_m3,
                .nonstructural_to_structural_rate_per_h = context.parameters.nonstructural_to_structural_rate_per_h,
                .timestep_h = context.timestep_h,
            });
            context.result.respiration_required_g_c[index] = value.respiration_required_g_c;
            context.result.fixation_respiration_g_c[index] = value.fixation_respiration_g_c;
            context.result.fixed_nitrogen_g_n[index] = value.fixed_nitrogen_g_n;
            cell_demand_g_n += value.fixed_nitrogen_g_n;
        };
        if (cell_demand_g_n > dissolved_n2_g_n) {
            const supply_share = if (cell_demand_g_n > 0) dissolved_n2_g_n / cell_demand_g_n else 0;
            if (!std.math.isFinite(supply_share) or supply_share < 0 or supply_share > 1) return error.InvalidSurfaceNitrogenFixationSupplyShare;
            const first = cell * respiration.unit_count_per_cell;
            for (first..first + respiration.unit_count_per_cell) |index| {
                context.result.fixed_nitrogen_g_n[index] *= supply_share;
                context.result.fixation_respiration_g_c[index] *= supply_share;
            }
            std.log.debug("litter dissolved N2 limits fixation: cell={d} demand_g_n={e} available_g_n={e} share={e}", .{ cell, cell_demand_g_n, dissolved_n2_g_n, supply_share });
        }
    }
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.maintenance.cell_count != cells or context.litter_gas.cell_count != cells or context.litter_water_m3.len != cells) return error.SurfaceNitrogenFixationDimensionMismatch;
    if (context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.SurfaceNitrogenFixationDimensionMismatch;
}

test "surface diazotrophs alone fix dissolved dinitrogen" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    const diazotroph = (5 * organic.kinetic_fraction_count) + 2;
    organic_state.microbial[diazotroph] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    var maintenance_state = try maintenance.State.init(std.testing.allocator, 1);
    defer maintenance_state.deinit();
    maintenance_state.growth_respiration_g_c[5] = 1;
    var litter_gas = try gas.State.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    litter_gas.dissolved_mass_g[@intFromEnum(gas.Species.nitrogen)] = 1;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var parameters: respiration.Parameters = undefined;
    parameters.nitrogen_fixation_yield_g_n_per_g_c = .{ 0, 0, 0, 0, 0, 0.25, 0.02 };
    parameters.dinitrogen_half_saturation_g_n_per_m3 = 0.14;
    parameters.nonstructural_to_structural_rate_per_h = 0.25;
    const ratios = [_]f64{0.1} ** (organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .maintenance = &maintenance_state, .litter_gas = &litter_gas, .litter_water_m3 = &.{1}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &ratios, .parameters = parameters, .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.fixation_respiration_g_c[5] > 0);
    try std.testing.expectApproxEqAbs(state.fixation_respiration_g_c[5] * 0.25, state.fixed_nitrogen_g_n[5], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), state.fixation_respiration_g_c[0]);
}

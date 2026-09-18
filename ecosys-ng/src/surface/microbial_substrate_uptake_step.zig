const std = @import("std");
const compute = @import("../core/compute.zig");
const organic = @import("../soil/organic/initialization.zig");
const metabolism = @import("../soil/microbial/metabolism.zig");
const respiration = @import("microbial_respiration_step.zig");
const oxygen = @import("microbial_oxygen_driver.zig");
const maintenance = @import("microbial_maintenance_step.zig");
const fixation = @import("nonsymbiotic_nitrogen_fixation_step.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    denitrification_respiration_g_c: []f64,
    aerobic_growth_respiration_requirement_g_c_per_g_c: []f64,
    total_carbon_uptake_g_c: []f64,
    doc_uptake_g_c: []f64,
    acetate_uptake_g_c: []f64,
    dissolved_organic_nitrogen_uptake_g_n: []f64,
    dissolved_organic_phosphorus_uptake_g_p: []f64,
    nonstructural_carbon_gain_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceMicrobialSubstrateUptakeCells;
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
    respiration: *const respiration.State,
    oxygen: *const oxygen.State,
    maintenance: *const maintenance.State,
    nitrogen_fixation: *const fixation.State,
    parameters: respiration.Parameters,
    denitrification_growth_respiration_requirement_g_c_per_g_c: f64,
};

/// NITRO CGOMX/CGOMD/CGOMC, CGOQC/CGOAC, and CGOMN/CGOMP.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| for (0..respiration.litter_complex_count) |complex| {
        var total_active_biomass_g_c: f64 = 0;
        var active_biomass_g_c: [respiration.source_population_count]f64 = undefined;
        for (0..respiration.source_population_count) |population| {
            const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
            active_biomass_g_c[population] = context.surface_organic.microbial[microbial].carbon_g_c / context.parameters.labile_biomass_fraction;
            total_active_biomass_g_c += active_biomass_g_c[population];
        }
        const mobile = cell * organic.substrate_count + complex;
        const dissolved = context.surface_organic.dissolved[mobile];
        const dissolved_nitrogen_per_doc = if (dissolved.carbon_g_c > 0) dissolved.nitrogen_g_n / dissolved.carbon_g_c else 0;
        const dissolved_phosphorus_per_doc = if (dissolved.carbon_g_c > 0) dissolved.phosphorus_g_p / dissolved.carbon_g_c else 0;
        for (0..respiration.source_population_count) |population| {
            const unit = complex * respiration.source_population_count + population;
            const index = cell * respiration.unit_count_per_cell + unit;
            const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
            const labile = context.surface_organic.microbial[microbial];
            const target_n = context.parameters.target_nitrogen_per_carbon_g_n_per_g_c[unit];
            const target_p = context.parameters.target_phosphorus_per_carbon_g_p_per_g_c[unit];
            const actual_n = if (labile.carbon_g_c > 0) labile.nitrogen_g_n / labile.carbon_g_c else target_n;
            const actual_p = if (labile.carbon_g_c > 0) labile.phosphorus_g_p / labile.carbon_g_c else target_p;
            const nitrogen_limitation = @min(1, @max(0.1, std.math.pow(f64, actual_n / target_n, 0.25)));
            const phosphorus_limitation = @min(1, @max(0.1, std.math.pow(f64, actual_p / target_p, 0.25)));
            const doc_respiration = context.respiration.previous_doc_respiration_g_c[index];
            const acetate_respiration = context.respiration.previous_acetate_respiration_g_c[index];
            const respiration_sum = doc_respiration + acetate_respiration;
            const population_metabolism = context.parameters.populations[population].metabolism;
            const doc_fraction: f64 = if (respiration_sum > 0) doc_respiration / respiration_sum else switch (population_metabolism) {
                .aerobic_heterotroph, .fermenting_heterotroph => 1,
                .acetotrophic_methanogen => 0,
            };
            const acetate_fraction = 1 - doc_fraction;
            const requirement = context.parameters.doc_respiration_requirement_g_c_per_g_c[population] * doc_fraction + context.parameters.acetate_respiration_requirement_g_c_per_g_c[population] * acetate_fraction;
            if (!std.math.isFinite(requirement) or requirement <= 0) return error.InvalidSurfaceAerobicGrowthRespirationRequirement;
            const oxygen_fraction = if (context.oxygen.populations[index].is_aerobic) context.oxygen.allocation.demand_satisfaction_fraction[index] else 1;
            const actual_respiration = context.respiration.substrate_limited_respiration_g_c[index] * oxygen_fraction;
            const value = try metabolism.respirationDrivenSubstrateUptake(.{
                .is_heterotroph = true,
                .maintenance_respiration_g_c = context.maintenance.total_maintenance_respiration_g_c[index],
                .aerobic_respiration_g_c = actual_respiration,
                .growth_respiration_g_c = context.maintenance.growth_respiration_g_c[index],
                .fixation_respiration_g_c = context.nitrogen_fixation.fixation_respiration_g_c[index],
                .aerobic_growth_respiration_fraction_g_c_per_g_c = requirement,
                .denitrification_respiration_g_c = context.result.denitrification_respiration_g_c[index],
                .denitrification_growth_respiration_fraction_g_c_per_g_c = context.denitrification_growth_respiration_requirement_g_c_per_g_c,
                .doc_fraction_of_aerobic_carbon = doc_fraction,
                .acetate_fraction_of_aerobic_carbon = acetate_fraction,
                .dissolved_organic_nitrogen_g_n = dissolved.nitrogen_g_n,
                .dissolved_organic_phosphorus_g_p = dissolved.phosphorus_g_p,
                .population_biomass_fraction = if (total_active_biomass_g_c > 0) active_biomass_g_c[population] / total_active_biomass_g_c else 1,
                .dissolved_nitrogen_per_doc_g_n_per_g_c = dissolved_nitrogen_per_doc,
                .dissolved_phosphorus_per_doc_g_p_per_g_c = dissolved_phosphorus_per_doc,
                .nitrogen_limitation_fraction = nitrogen_limitation,
                .phosphorus_limitation_fraction = phosphorus_limitation,
            });
            context.result.aerobic_growth_respiration_requirement_g_c_per_g_c[index] = requirement;
            context.result.total_carbon_uptake_g_c[index] = value.total_carbon_g_c;
            context.result.doc_uptake_g_c[index] = value.doc_g_c;
            context.result.acetate_uptake_g_c[index] = value.acetate_g_c;
            context.result.dissolved_organic_nitrogen_uptake_g_n[index] = value.dissolved_organic_nitrogen_g_n;
            context.result.dissolved_organic_phosphorus_uptake_g_p[index] = value.dissolved_organic_phosphorus_g_p;
            context.result.nonstructural_carbon_gain_g_c[index] = value.total_carbon_g_c - actual_respiration - context.result.denitrification_respiration_g_c[index] - context.nitrogen_fixation.fixation_respiration_g_c[index];
        }

        // Limit the summed uptake against the donor pools, exactly as the soil
        // path does at `soil/biogeochemistry/substrate_uptake_step.zig:91-108`.
        // This was missing here, and its absence is what stopped the Ottawa
        // deck at hour 2141: microbial acetate uptake of 1.54e-10 g C was taken
        // from a pool holding exactly zero, which
        // `surface/organic_priming_step.zig` then correctly rejected as
        // `SurfaceOrganicPrimingUptakeOverdraw`.
        //
        // The soil comment states the mechanism and it applies identically
        // here: NITRO limits each population's respiration against its
        // competition share before converting back to CGOQC/CGOAC, and mixed
        // growth efficiencies plus maintenance can make the converted sum
        // exceed a dissolved pool by roundoff-sized amounts. Scaling all
        // populations by one donor-derived factor keeps the allocation
        // independent of population order and exactly conservative. With
        // `available == 0` the factor is 0 and every uptake becomes 0, which is
        // the correct answer the surface path previously failed to give.
        //
        // This is not a tolerance: it is the substrate availability limit the
        // source applies, and it withdraws nothing that is not there.
        const first_unit = cell * respiration.unit_count_per_cell + complex * respiration.source_population_count;
        var aggregate_doc_uptake_g_c: f64 = 0;
        var aggregate_acetate_uptake_g_c: f64 = 0;
        for (0..respiration.source_population_count) |population| {
            aggregate_doc_uptake_g_c += context.result.doc_uptake_g_c[first_unit + population];
            aggregate_acetate_uptake_g_c += context.result.acetate_uptake_g_c[first_unit + population];
        }
        const available_acetate_g_c = context.surface_organic.dissolved_acetate_carbon_g_c[mobile];
        const doc_scale = if (aggregate_doc_uptake_g_c > dissolved.carbon_g_c and aggregate_doc_uptake_g_c > 0)
            dissolved.carbon_g_c / aggregate_doc_uptake_g_c
        else
            1;
        const acetate_scale = if (aggregate_acetate_uptake_g_c > available_acetate_g_c and aggregate_acetate_uptake_g_c > 0)
            available_acetate_g_c / aggregate_acetate_uptake_g_c
        else
            1;
        if (doc_scale < 1 or acetate_scale < 1) {
            for (0..respiration.source_population_count) |population| {
                context.result.doc_uptake_g_c[first_unit + population] *= doc_scale;
                context.result.acetate_uptake_g_c[first_unit + population] *= acetate_scale;
            }
        }
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.respiration.cell_count != cells or context.oxygen.cell_count != cells or context.maintenance.cell_count != cells or context.nitrogen_fixation.cell_count != cells) return error.SurfaceMicrobialSubstrateUptakeDimensionMismatch;
    if (!std.math.isFinite(context.denitrification_growth_respiration_requirement_g_c_per_g_c) or context.denitrification_growth_respiration_requirement_g_c_per_g_c <= 0) return error.InvalidSurfaceDenitrificationGrowthRespirationRequirement;
}

test "surface substrate uptake reproduces CGOQC CGOAC and CGROMC" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.microbial[0] = .{ .carbon_g_c = 0.55, .nitrogen_g_n = 0.055, .phosphorus_g_p = 0.0055 };
    organic_state.dissolved[0] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 };
    var respiration_state = try respiration.State.init(std.testing.allocator, 1);
    defer respiration_state.deinit();
    respiration_state.substrate_limited_respiration_g_c[0] = 0.2;
    respiration_state.previous_doc_respiration_g_c[0] = 0.15;
    respiration_state.previous_acetate_respiration_g_c[0] = 0.05;
    var oxygen_state = try oxygen.State.init(std.testing.allocator, 1);
    defer oxygen_state.deinit();
    oxygen_state.populations[0].is_aerobic = false;
    var maintenance_state = try maintenance.State.init(std.testing.allocator, 1);
    defer maintenance_state.deinit();
    maintenance_state.total_maintenance_respiration_g_c[0] = 0.02;
    maintenance_state.growth_respiration_g_c[0] = 0.18;
    var fixation_state = try fixation.State.init(std.testing.allocator, 1);
    defer fixation_state.deinit();
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var parameters: respiration.Parameters = undefined;
    parameters.populations = [_]@import("../soil/microbial/respiration_activity.zig").PopulationParameters{.{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0 }} ** respiration.source_population_count;
    parameters.labile_biomass_fraction = 0.55;
    parameters.target_nitrogen_per_carbon_g_n_per_g_c = .{0.1} ** respiration.unit_count_per_cell;
    parameters.target_phosphorus_per_carbon_g_p_per_g_c = .{0.01} ** respiration.unit_count_per_cell;
    parameters.doc_respiration_requirement_g_c_per_g_c = .{0.5} ** respiration.source_population_count;
    parameters.acetate_respiration_requirement_g_c_per_g_c = .{0.25} ** respiration.source_population_count;
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .respiration = &respiration_state, .oxygen = &oxygen_state, .maintenance = &maintenance_state, .nitrogen_fixation = &fixation_state, .parameters = parameters, .denitrification_growth_respiration_requirement_g_c_per_g_c = 1.0 / (1.0 + 10.0 / 25.0) };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.total_carbon_uptake_g_c[0] > 0.2);
    try std.testing.expect(state.doc_uptake_g_c[0] > state.acetate_uptake_g_c[0]);
    try std.testing.expectApproxEqAbs(state.total_carbon_uptake_g_c[0] - 0.2, state.nonstructural_carbon_gain_g_c[0], 1e-15);
}

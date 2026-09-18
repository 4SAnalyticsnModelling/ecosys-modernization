const std = @import("std");
const fertilizer = @import("litter_fertilizer.zig");
const litter_chemistry = @import("litter_chemistry.zig");
const organic = @import("../soil/organic/initialization.zig");
const chemistry_parameters = @import("../soil/chemistry/parameters.zig");
const compute = @import("../core/compute.zig");

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    fluxes: []fertilizer.Fluxes,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !Diagnostics {
        if (cell_count == 0) return error.ZeroLitterCellCount;
        const fluxes = try allocator.alloc(fertilizer.Fluxes, cell_count);
        @memset(fluxes, zeroFluxes());
        return .{ .allocator = allocator, .fluxes = fluxes };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.allocator.free(self.fluxes);
        self.* = undefined;
    }

    pub fn reset(self: *Diagnostics) void {
        @memset(self.fluxes, zeroFluxes());
    }
};

pub const ApplyContext = struct {
    state: *fertilizer.State,
    chemistry: *litter_chemistry.State,
    surface_organic: *const organic.State,
    litter_water_m3: []const f64,
    dry_litter_volume_m3: []const f64,
    biologically_active_water_m3: []const f64,
    active_biomass_respiration_g_c_per_step: []const f64,
    microbial_temperature_factor: []const f64,
    litter_dry_mass_megagrams_per_g_c: f64,
    step_duration_h: f64,
    parameters: chemistry_parameters.SurfaceFertilizerParameters,
    diagnostics: *Diagnostics,
};

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validateDimensions(context.*, range);
    for (range.first..range.end) |cell| {
        const water_m3 = context.litter_water_m3[cell];
        const dry_litter_volume_m3 = context.dry_litter_volume_m3[cell];
        const dry_mass_megagrams = try context.surface_organic.totalCarbon_g_c(cell) * context.litter_dry_mass_megagrams_per_g_c;
        const parameters = try context.parameters.forFormulation(context.state.formulation[cell], context.step_duration_h);
        context.diagnostics.fluxes[cell] = try fertilizer.calculateAndApplyToChemistry(context.state, context.chemistry, cell, .{
            .litter_water_volume_m3 = water_m3,
            .litter_water_volume_fraction = if (dry_litter_volume_m3 > 0) @min(1, water_m3 / dry_litter_volume_m3) else 0,
            .litter_dry_mass_megagrams = dry_mass_megagrams,
            .biologically_active_water_volume_m3 = context.biologically_active_water_m3[cell],
            .active_biomass_respiration_g_c_per_step = context.active_biomass_respiration_g_c_per_step[cell],
            .microbial_temperature_factor = context.microbial_temperature_factor[cell],
            .step_duration_h = context.step_duration_h,
        }, parameters);
    }
}

fn validateDimensions(context: ApplyContext, range: compute.CellRange) !void {
    const count = context.state.cells.len;
    if (range.first > range.end or range.end > count or context.chemistry.cells.len != count or context.surface_organic.layer_count != count or context.diagnostics.fluxes.len != count) return error.SurfaceFertilizerStepDimensionMismatch;
    inline for (.{ context.litter_water_m3, context.dry_litter_volume_m3, context.biologically_active_water_m3, context.active_biomass_respiration_g_c_per_step, context.microbial_temperature_factor }) |values| if (values.len != count) return error.SurfaceFertilizerStepDimensionMismatch;
    if (context.state.formulation.len != count or !std.math.isFinite(context.litter_dry_mass_megagrams_per_g_c) or context.litter_dry_mass_megagrams_per_g_c <= 0 or !std.math.isFinite(context.step_duration_h) or context.step_duration_h <= 0) return error.InvalidSurfaceFertilizerStepInput;
    for (range.first..range.end) |cell| {
        inline for (.{ context.litter_water_m3[cell], context.dry_litter_volume_m3[cell], context.biologically_active_water_m3[cell], context.active_biomass_respiration_g_c_per_step[cell], context.microbial_temperature_factor[cell] }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceFertilizerStepInput;
        // FERTILIZER-TFNQ-FRACTION-DOMAIN-001: no upper cap on
        // `microbial_temperature_factor`. It is NITRO's TFNQ (`nitro.f:316`,
        // `:4098`), an unbounded Arrhenius ratio, and the physical bound lives
        // on urea availability in the flux itself. The formulation code range
        // below is a genuine enumeration bound and stays.
        if (context.state.formulation[cell] > 4) return error.InvalidSurfaceFertilizerStepInput;
    }
}

fn zeroFluxes() fertilizer.Fluxes {
    return .{ .ammonium_dissolution_mol_n = 0, .ammonia_dissolution_mol_n = 0, .urea_hydrolysis_mol_n = 0, .nitrate_dissolution_mol_n = 0 };
}

test "tiled surface fertilizer step consumes explicit microbial drivers" {
    var state = try fertilizer.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].ammonium_mol_n = 10;
    state.cells[0].urea_mol_n = 2;
    var chemistry = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var surface_organic = try organic.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    surface_organic.microbial[0].carbon_g_c = 1_000_000;
    var diagnostics = try Diagnostics.init(std.testing.allocator, 1);
    defer diagnostics.deinit();
    var context: ApplyContext = .{
        .state = &state,
        .chemistry = &chemistry,
        .surface_organic = &surface_organic,
        .litter_water_m3 = &.{1},
        .dry_litter_volume_m3 = &.{2},
        .biologically_active_water_m3 = &.{1},
        .active_biomass_respiration_g_c_per_step = &.{10},
        .microbial_temperature_factor = &.{1},
        .litter_dry_mass_megagrams_per_g_c = 1e-6,
        .step_duration_h = 1,
        .parameters = .{ .ammonium_dissolution_fraction_per_h = 1, .ammonia_dissolution_fraction_per_h = 1, .nitrate_dissolution_fraction_per_h = 1, .minimum_urea_half_saturation_mol_n_per_megagram = 0.05, .microbial_activity_inhibition_g_c_per_m3_per_h = 50, .specific_urea_hydrolysis_mol_n_per_g_c_per_h = 0.03, .fast_release_inhibition_decline_fraction_per_h = 0.05, .normal_release_inhibition_decline_fraction_per_h = 0.01, .slow_release_inhibition_decline_fraction_per_h = 0.005 },
        .diagnostics = &diagnostics,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    // SOLUTE THETW0 is water / dry litter volume: 1 / 2.
    try std.testing.expectEqual(@as(f64, 5), diagnostics.fluxes[0].ammonium_dissolution_mol_n);
    try std.testing.expect(diagnostics.fluxes[0].urea_hydrolysis_mol_n > 0);
    try std.testing.expect(chemistry.cells[0].ammonia_mol_per_m3 > 0);
    try std.testing.expect(state.cells[0].urea_mol_n < 2);
}

const std = @import("std");
const builtin = @import("builtin");
const compute = @import("../core/compute.zig");
const chemistry = @import("litter_chemistry.zig");
const extensive = @import("litter_extensive_changes.zig");
const organic = @import("../soil/organic/initialization.zig");
const chemistry_parameters = @import("../soil/chemistry/parameters.zig");
const chemistry_initialization = @import("../soil/chemistry/initialization.zig");
const cation_exchange = @import("../soil/solute/cation_exchange.zig");
const water_equilibrium = @import("../soil/solute/water_equilibrium.zig");
const gas = @import("../soil/gas/transport.zig");

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    changes: []extensive.Changes,
    iterations: []u16,
    newton_raphson_steps: []u16,
    picard_steps: []u16,
    maximum_scaled_residual: []f64,
    solved: []bool,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !Diagnostics {
        if (cell_count == 0) return error.ZeroLitterChemistryCellCount;
        const changes = try allocator.alloc(extensive.Changes, cell_count);
        errdefer allocator.free(changes);
        const iterations = try allocator.alloc(u16, cell_count);
        errdefer allocator.free(iterations);
        const newton = try allocator.alloc(u16, cell_count);
        errdefer allocator.free(newton);
        const picard = try allocator.alloc(u16, cell_count);
        errdefer allocator.free(picard);
        const residual = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(residual);
        const solved = try allocator.alloc(bool, cell_count);
        var result = Diagnostics{ .allocator = allocator, .changes = changes, .iterations = iterations, .newton_raphson_steps = newton, .picard_steps = picard, .maximum_scaled_residual = residual, .solved = solved };
        result.reset();
        return result;
    }

    pub fn deinit(self: *Diagnostics) void {
        self.allocator.free(self.solved);
        self.allocator.free(self.maximum_scaled_residual);
        self.allocator.free(self.picard_steps);
        self.allocator.free(self.newton_raphson_steps);
        self.allocator.free(self.iterations);
        self.allocator.free(self.changes);
        self.* = undefined;
    }

    pub fn reset(self: *Diagnostics) void {
        @memset(self.changes, std.mem.zeroes(extensive.Changes));
        @memset(self.iterations, 0);
        @memset(self.newton_raphson_steps, 0);
        @memset(self.picard_steps, 0);
        @memset(self.maximum_scaled_residual, 0);
        @memset(self.solved, false);
    }
};

pub const ApplyContext = struct {
    state: *chemistry.State,
    surface_organic: *const organic.State,
    litter_water_m3: []const f64,
    chemistry_parameters: chemistry_parameters.Parameters,
    cation_selectivity_by_cell: []const cation_exchange.Selectivity,
    litter_dry_mass_megagrams: []const f64,
    salinity_enabled_by_cell: []const bool,
    solver_options: chemistry.Options,
    diagnostics: *Diagnostics,
};

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    const count = context.state.cells.len;
    if (context.state.ph.len != count or context.surface_organic.layer_count != count or context.litter_water_m3.len != count or context.litter_dry_mass_megagrams.len != count or context.cation_selectivity_by_cell.len != count or context.salinity_enabled_by_cell.len != count or context.diagnostics.changes.len != count or range.first > range.end or range.end > count) return error.LitterChemistryStepDimensionMismatch;
    for (range.first..range.end) |cell| applyCell(context, cell) catch |err| {
        std.log.warn("litter chemistry hourly rejection: cell={d} error={s} water_m3={e} dry_mass_megagrams={e} dynamic_salts={} state={any}", .{ cell, @errorName(err), context.litter_water_m3[cell], context.litter_dry_mass_megagrams[cell], context.salinity_enabled_by_cell[cell], context.state.cells[cell] });
        return err;
    };
}

/// Seeds the litter chemistry CO2 coordinate from the authoritative gas
/// inventory before the equilibrium runs.
///
/// `publishAcceptedCarbonDioxideChanges` states the ownership rule: aqueous CO2
/// storage is counted only by gas state, while carbonate, bicarbonate and
/// calcite are owned by litter chemistry. Nothing enforced it. Chemistry
/// evolved its own `carbon_dioxide_mol_per_m3` stock, gas transport separately
/// drained `dissolved_mass_g`, and the two were never reconciled -- so
/// `litter_reaction_rates.zig:748` drove the reverse of
/// `HCO3- + H+ <-> CO2 + H2O` against a stock the gas inventory no longer had.
/// The real deck at year1998 day98 hour11 asked to remove 7.803710377437666e-6
/// g C from an inventory of 2.6192956654847446e-6 g C: a 2.98x overdraw, 66% of
/// its own scale, which is real science and not a roundoff floor.
///
/// The oracle keeps ONE aqueous CO2 array shared between the solute chemistry
/// and gas transport, so one inventory is the faithful translation.
pub fn seedCarbonDioxideFromGasInventory(
    state: *chemistry.State,
    gas_state: *const gas.State,
    litter_water_m3: []const f64,
    carbon_g_per_mol: f64,
    negligible_water_volume_m3: f64,
) !void {
    if (gas_state.cell_count != state.cells.len or litter_water_m3.len != state.cells.len)
        return error.LitterChemistryGasDimensionMismatch;
    if (!std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0)
        return error.InvalidCarbonMolarMass;
    if (!std.math.isFinite(negligible_water_volume_m3) or negligible_water_volume_m3 <= 0)
        return error.InvalidLitterCarbonDioxideFloor;
    const species = @intFromEnum(gas.Species.carbon_dioxide);
    for (state.cells, 0..) |*cell, index| {
        const water_m3 = litter_water_m3[index];
        // With no resolvable water there is no aqueous phase to hold a
        // concentration. Leaving the previous value would reintroduce exactly
        // the stale-stock divergence this function exists to remove.
        if (!(water_m3 > negligible_water_volume_m3)) {
            cell.carbon_dioxide_mol_per_m3 = 0;
            continue;
        }
        const dissolved_g_c = gas_state.dissolved_mass_g[index * gas.species_count + species];
        const concentration = @max(0, dissolved_g_c) / carbon_g_per_mol / water_m3;
        if (!std.math.isFinite(concentration)) return error.InvalidLitterCarbonDioxideSeed;
        cell.carbon_dioxide_mol_per_m3 = concentration;
    }
}

/// Publishes the accepted aqueous CO2 coordinate change to the authoritative
/// litter gas inventory. Carbonate, bicarbonate, and calcite remain owned by
/// litter chemistry, while aqueous CO2 storage is counted only by gas state.
/// Returns the total carbon the negligibility floor had to create, in g C, so
/// the caller can account it. A roundoff-sized negative inventory is clamped
/// rather than fatal -- the oracle clamps with AMAX1 against an area-scaled
/// ZEROS floor (`ecosys_f77/starts.f:93-94,269-270`) and never aborts -- but
/// nothing is discarded silently: the amount is returned AND logged.
pub fn publishAcceptedCarbonDioxideChanges(
    gas_state: *gas.State,
    diagnostics: *const Diagnostics,
    carbon_g_per_mol: f64,
    negligible_carbon_g_c: f64,
    relative_tolerance: f64,
) !f64 {
    if (gas_state.cell_count != diagnostics.changes.len or
        diagnostics.solved.len != diagnostics.changes.len)
        return error.LitterChemistryGasDimensionMismatch;
    if (!std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0)
        return error.InvalidCarbonMolarMass;
    if (!std.math.isFinite(negligible_carbon_g_c) or negligible_carbon_g_c < 0 or
        !std.math.isFinite(relative_tolerance) or relative_tolerance < 0)
        return error.InvalidLitterCarbonDioxideFloor;
    const species = @intFromEnum(gas.Species.carbon_dioxide);
    // Validate every cell before mutating any, so a rejection leaves the
    // inventory untouched. "invalid litter chemistry CO2 state_update is
    // atomic" pins that, and the clamp below must not weaken it: the clamp is
    // a pure function of `next`, so the apply pass recomputes it identically
    // without carrying decisions between the passes.
    var clamped_carbon_g_c: f64 = 0;
    for (diagnostics.changes, diagnostics.solved, 0..) |change, solved, cell| {
        if (!solved) continue;
        const delta_g_c = change.carbon_dioxide_mol * carbon_g_per_mol;
        const index = cell * gas.species_count + species;
        const next = gas_state.dissolved_mass_g[index] + delta_g_c;
        if (!std.math.isFinite(delta_g_c) or !std.math.isFinite(next)) {
            if (!builtin.is_test) std.log.err(
                "litter carbon dioxide state update not finite: cell={d} dissolved_g_c={e} delta_g_c={e} next_g_c={e} carbon_g_per_mol={e}",
                .{ cell, gas_state.dissolved_mass_g[index], delta_g_c, next, carbon_g_per_mol },
            );
            return error.InvalidLitterCarbonDioxideStateUpdate;
        }
        if (next < 0) {
            const limit = negligible_carbon_g_c + relative_tolerance *
                @max(@abs(gas_state.dissolved_mass_g[index]), @abs(delta_g_c));
            if (-next > limit) {
                if (!builtin.is_test) std.log.err(
                    "litter carbon dioxide state update overdraws the dissolved inventory: cell={d} dissolved_g_c={e} delta_g_c={e} next_g_c={e} limit_g_c={e}",
                    .{ cell, gas_state.dissolved_mass_g[index], delta_g_c, next, limit },
                );
                return error.InvalidLitterCarbonDioxideStateUpdate;
            }
            clamped_carbon_g_c += -next;
        }
    }
    if (clamped_carbon_g_c > 0) {
        std.log.warn(
            "litter carbon dioxide negligibility floor created carbon: total_g_c={e}",
            .{clamped_carbon_g_c},
        );
    }
    for (diagnostics.changes, diagnostics.solved, 0..) |change, solved, cell| {
        if (!solved) continue;
        const index = cell * gas.species_count + species;
        gas_state.dissolved_mass_g[index] = @max(
            0,
            gas_state.dissolved_mass_g[index] + change.carbon_dioxide_mol * carbon_g_per_mol,
        );
    }
    return clamped_carbon_g_c;
}

fn applyCell(context: *ApplyContext, cell: usize) !void {
    const carbon_g_c = try context.surface_organic.totalCarbon_g_c(cell);
    const water_m3 = context.litter_water_m3[cell];
    if (!std.math.isFinite(water_m3) or water_m3 < 0) return error.InvalidLitterWaterVolume;
    try context.state.renormalizeMinerals(cell, water_m3);
    if (carbon_g_c == 0 or water_m3 == 0) return;
    const dry_mass_megagrams = context.litter_dry_mass_megagrams[cell];
    if (!std.math.isFinite(dry_mass_megagrams) or dry_mass_megagrams <= 0) return error.InvalidLitterDryMass;
    const density = dry_mass_megagrams / water_m3;
    const capacity = try chemistry_initialization.surfaceLitterCationExchangeCapacity_mol_charge_per_megagram_litter(carbon_g_c, dry_mass_megagrams, context.chemistry_parameters.surface_litter.carboxyl_sites_mol_per_megagram_c);
    const before = context.state.cells[cell];
    const balance_before = context.state.water_equilibrium_balance_mol[cell];
    const activity = try chemistry.activityCoefficients(before, water_m3);
    const rates_context = context.chemistry_parameters.forSurfaceLitter(activity, context.cation_selectivity_by_cell[cell], capacity, density, context.salinity_enabled_by_cell[cell]);
    // SOLUTE.F resets PH(0) from the starting H/OH water equilibrium before
    // evaluating the remaining hourly transformations. Later H mass changes
    // do not overwrite PH; dry and fixed-pH branches retain it.
    const source_ph = if (rates_context.dynamic_salts)
        try startingDynamicPh(
            before.hydrogen_mol_per_m3,
            before.hydroxide_mol_per_m3,
            rates_context.parameters.activity.monovalent_activity_coefficient,
            rates_context.parameters.water_activity_product_mol2_per_m6,
            rates_context.parameters.negligible_water_ion_concentration_mol_per_m3,
        )
    else
        context.state.ph[cell];
    if (!std.math.isFinite(source_ph)) return error.InvalidSurfaceLitterPh;
    const result = extensive.applyHourlyCellAndCapture(context.state, cell, &rates_context, context.solver_options, .{ .litter_water_volume_m3 = water_m3, .litter_dry_mass_megagrams = dry_mass_megagrams }, &context.diagnostics.changes[cell]) catch |err| {
        context.state.cells[cell] = before;
        return err;
    };
    context.state.publishAcceptedWaterEquilibriumBalance(
        cell,
        result.accepted_water_equilibrium_extent_mol_per_m3,
        water_m3,
    ) catch |err| {
        context.state.cells[cell] = before;
        context.state.water_equilibrium_balance_mol[cell] = balance_before;
        return err;
    };
    context.diagnostics.iterations[cell] = result.iterations;
    context.diagnostics.newton_raphson_steps[cell] = result.newton_raphson_steps;
    context.diagnostics.picard_steps[cell] = result.picard_steps;
    context.diagnostics.maximum_scaled_residual[cell] = result.maximum_scaled_residual;
    context.diagnostics.solved[cell] = true;
    context.state.ph[cell] = source_ph;
}

fn startingDynamicPh(
    hydrogen_mol_per_m3: f64,
    hydroxide_mol_per_m3: f64,
    monovalent_activity_coefficient: f64,
    water_activity_product_mol2_per_m6: f64,
    negligible_concentration_mol_per_m3: f64,
) !f64 {
    const water = try water_equilibrium.solve(.{
        .hydrogen_concentration_mol_per_m3 = hydrogen_mol_per_m3,
        .hydroxide_concentration_mol_per_m3 = hydroxide_mol_per_m3,
        .monovalent_activity_coefficient = monovalent_activity_coefficient,
        .water_activity_product_mol2_per_m6 = water_activity_product_mol2_per_m6,
        .negligible_concentration_mol_per_m3 = negligible_concentration_mol_per_m3,
    });
    const hydrogen_activity = water.hydrogen_concentration_mol_per_m3 *
        monovalent_activity_coefficient;
    if (!std.math.isFinite(hydrogen_activity) or hydrogen_activity <= 0)
        return error.InvalidLitterHydrogenActivity;
    const ph = -@log10(hydrogen_activity * 1.0e-3);
    if (!std.math.isFinite(ph)) return error.InvalidSurfaceLitterPh;
    return ph;
}

test "dynamic litter pH is projected independently from zero hydrogen mass" {
    try std.testing.expectApproxEqAbs(
        @as(f64, 7),
        try startingDynamicPh(0, 0, 1, 1.0e-8, 1.0e-20),
        1.0e-14,
    );
}

test "dry litter cells skip without mutating chemistry" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.ph[0] = 6.25;
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var diagnostics = try Diagnostics.init(std.testing.allocator, 1);
    defer diagnostics.deinit();
    var context: ApplyContext = undefined;
    context.state = &state;
    context.surface_organic = &surface;
    context.litter_water_m3 = &.{0};
    context.cation_selectivity_by_cell = &.{.{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }};
    context.litter_dry_mass_megagrams = &.{0};
    context.salinity_enabled_by_cell = &.{false};
    context.solver_options = .{};
    context.diagnostics = &diagnostics;
    // Unused because zero carbon/water exits before parameter evaluation.
    context.chemistry_parameters = undefined;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(!diagnostics.solved[0]);
    try std.testing.expectEqual(std.mem.zeroes(chemistry.Cell), state.cells[0]);
    try std.testing.expectEqual(@as(f64, 6.25), state.ph[0]);
}

test "accepted litter chemistry CO2 change closes authoritative gas carbon" {
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    var diagnostics = try Diagnostics.init(std.testing.allocator, 2);
    defer diagnostics.deinit();
    const co2 = @intFromEnum(gas.Species.carbon_dioxide);
    gas_state.dissolved_mass_g[co2] = 10;
    gas_state.dissolved_mass_g[gas.species_count + co2] = 20;
    diagnostics.solved[0] = true;
    diagnostics.changes[0].carbon_dioxide_mol = -0.25;
    diagnostics.changes[0].bicarbonate_mol = 0.25;

    try std.testing.expectEqual(@as(f64, 0), try publishAcceptedCarbonDioxideChanges(&gas_state, &diagnostics, 12, 1e-10, 1e-12));
    try std.testing.expectEqual(@as(f64, 7), gas_state.dissolved_mass_g[co2]);
    try std.testing.expectEqual(@as(f64, 20), gas_state.dissolved_mass_g[gas.species_count + co2]);
    try std.testing.expectEqual(
        @as(f64, 10),
        gas_state.dissolved_mass_g[co2] + diagnostics.changes[0].bicarbonate_mol * 12,
    );
}

test "litter CO2 seed makes gas state the single inventory of record" {
    var state = try chemistry.State.init(std.testing.allocator, 2);
    defer state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    const co2 = @intFromEnum(gas.Species.carbon_dioxide);
    // A stale chemistry stock that the gas inventory does not support is
    // exactly the divergence that killed the deck at day 98: chemistry held
    // enough CO2 to run the reverse association, gas state did not.
    state.cells[0].carbon_dioxide_mol_per_m3 = 1000;
    state.cells[1].carbon_dioxide_mol_per_m3 = 1000;
    gas_state.dissolved_mass_g[co2] = 24;
    gas_state.dissolved_mass_g[gas.species_count + co2] = 6;

    try seedCarbonDioxideFromGasInventory(&state, &gas_state, &.{ 2, 0 }, 12, 1e-14);

    // 24 g C / 12 g per mol / 2 m3 = 1 mol m-3, replacing the stale 1000.
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.cells[0].carbon_dioxide_mol_per_m3, 1e-15);
    // No resolvable water means no aqueous phase; the stale stock must not
    // survive, or the divergence is reintroduced for dry litter.
    try std.testing.expectEqual(@as(f64, 0), state.cells[1].carbon_dioxide_mol_per_m3);
}

test "litter CO2 seed rejects a negative inventory rather than importing it" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = -5;
    try seedCarbonDioxideFromGasInventory(&state, &gas_state, &.{1}, 12, 1e-14);
    // Clamped at zero: a negative concentration is not a physical domain, and
    // importing one would put the equilibrium solver outside its own bounds.
    try std.testing.expectEqual(@as(f64, 0), state.cells[0].carbon_dioxide_mol_per_m3);
    try std.testing.expectError(
        error.InvalidCarbonMolarMass,
        seedCarbonDioxideFromGasInventory(&state, &gas_state, &.{1}, 0, 1e-14),
    );
    try std.testing.expectError(
        error.LitterChemistryGasDimensionMismatch,
        seedCarbonDioxideFromGasInventory(&state, &gas_state, &.{ 1, 1 }, 12, 1e-14),
    );
}

test "invalid litter chemistry CO2 state_update is atomic" {
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    var diagnostics = try Diagnostics.init(std.testing.allocator, 2);
    defer diagnostics.deinit();
    const co2 = @intFromEnum(gas.Species.carbon_dioxide);
    gas_state.dissolved_mass_g[co2] = 10;
    gas_state.dissolved_mass_g[gas.species_count + co2] = 1;
    @memset(diagnostics.solved, true);
    diagnostics.changes[0].carbon_dioxide_mol = 0.5;
    diagnostics.changes[1].carbon_dioxide_mol = -1;
    try std.testing.expectError(
        error.InvalidLitterCarbonDioxideStateUpdate,
        publishAcceptedCarbonDioxideChanges(&gas_state, &diagnostics, 12, 1e-10, 1e-12),
    );
    try std.testing.expectEqual(@as(f64, 10), gas_state.dissolved_mass_g[co2]);
    try std.testing.expectEqual(@as(f64, 1), gas_state.dissolved_mass_g[gas.species_count + co2]);
}

test "wet litter tile converges synthetic equilibrium conservatively" {
    const source =
        "aqueous_constants 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1\n" ++
        "aqueous_kinetics 0.2 0.2 0.1 0.1\n" ++
        "phosphate_constants 1 1 1 1 1 1 1 1\n" ++
        "phosphate_surface 1 1 1 1 1 1 0.1 0.2\n" ++
        "phosphate_minerals 1 1 1 1 1 1 0.1 0.1 0.1\n" ++
        "phosphate_kinetics 0.2 0.1\n" ++
        "cation_kinetics 0.2 0.1\n" ++
        "geochemistry_products 1 1 1 1 1 1 1 1 1 1\n" ++
        "geochemistry_kinetics 0.2 0.2 0.1 0.1 1 0 0\n" ++
        "water_equilibrium 1 1e-30 55555.555555555555\n" ++
        "surface_litter 1 0\n" ++
        "surface_fertilizer 1 1 1 0.05 50 0.03 0.05 0.01 0.005\n";
    const parameters = try chemistry_parameters.parse(source);
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.ph[0] = 6;
    state.cells[0].hydrogen_mol_per_m3 = 1;
    state.cells[0].hydroxide_mol_per_m3 = 1;
    state.cells[0].aluminum_mol_per_m3 = 1;
    state.cells[0].iron_mol_per_m3 = 1;
    state.cells[0].calcium_mol_per_m3 = 1;
    state.cells[0].magnesium_mol_per_m3 = 1;
    state.cells[0].sodium_mol_per_m3 = 1;
    state.cells[0].potassium_mol_per_m3 = 1;
    state.cells[0].hpo4_mol_p_per_m3 = 1;
    state.cells[0].h2po4_mol_p_per_m3 = 1;
    state.cells[0].phosphate_minerals = .{ .aluminum_phosphate_mol_per_m3 = 1, .iron_phosphate_mol_per_m3 = 1, .dicalcium_phosphate_mol_per_m3 = 1, .hydroxyapatite_mol_per_m3 = 1, .monocalcium_phosphate_mol_per_m3 = 1 };
    try state.bindMineralReferenceWater(&.{1});
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    surface.structural[0].carbon_g_c = 1;
    const phosphorus_before = state.cells[0].hpo4_mol_p_per_m3 +
        state.cells[0].h2po4_mol_p_per_m3 +
        state.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3 +
        state.cells[0].phosphate_minerals.iron_phosphate_mol_per_m3 +
        state.cells[0].phosphate_minerals.dicalcium_phosphate_mol_per_m3 +
        3 * state.cells[0].phosphate_minerals.hydroxyapatite_mol_per_m3 +
        2 * state.cells[0].phosphate_minerals.monocalcium_phosphate_mol_per_m3;
    var diagnostics = try Diagnostics.init(std.testing.allocator, 1);
    defer diagnostics.deinit();
    var context = ApplyContext{
        .state = &state,
        .surface_organic = &surface,
        .litter_water_m3 = &.{1},
        .chemistry_parameters = parameters,
        .cation_selectivity_by_cell = &.{.{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }},
        .litter_dry_mass_megagrams = &.{1},
        .salinity_enabled_by_cell = &.{false},
        .solver_options = .{ .absolute_tolerance_mol_per_m3 = 1e-10, .absolute_tolerance_mol_per_megagram = 1e-10, .relative_tolerance = 1e-8, .picard_relaxation = 0.5, .max_iterations = 60 },
        .diagnostics = &diagnostics,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const phosphorus_after = state.cells[0].hpo4_mol_p_per_m3 +
        state.cells[0].h2po4_mol_p_per_m3 +
        state.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3 +
        state.cells[0].phosphate_minerals.iron_phosphate_mol_per_m3 +
        state.cells[0].phosphate_minerals.dicalcium_phosphate_mol_per_m3 +
        3 * state.cells[0].phosphate_minerals.hydroxyapatite_mol_per_m3 +
        2 * state.cells[0].phosphate_minerals.monocalcium_phosphate_mol_per_m3;
    try std.testing.expectApproxEqAbs(phosphorus_before, phosphorus_after, 1e-12);
    try std.testing.expect(diagnostics.solved[0]);
    try std.testing.expectEqual(@as(f64, 6), state.ph[0]);
}

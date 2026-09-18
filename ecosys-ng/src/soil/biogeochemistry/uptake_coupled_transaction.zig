const std = @import("std");

const canopy_energy = @import("../../canopy/energy/water_energy_state_update.zig");
const minimum_stomatal = @import("../../canopy/energy/minimum_stomatal_resistance.zig");
const root_water = @import("../../plant/root/water_uptake_state_update.zig");
const root_gas_content = @import("../../plant/root/gas_content_state_update.zig");
const root_gas_withdrawal = @import("../../plant/root/gas_withdrawal_state_update.zig");
const root_nutrient = @import("../../plant/root/nutrient_uptake_state_update.zig");

const water_heat_capacity_megajoules_per_m3_k = 4.19;

pub const gas_count = root_gas_content.gas_count;
pub const nutrient_count = root_nutrient.nutrient_count;

/// `uptake.f` 466--474 and 1225--1228: UPTAKE calls `STOMATE` before canopy
/// iteration and again before its final pass. This compatibility hook keeps
/// that ordering for standalone callers. Production instead performs both
/// temperature-dependent calls inside `canopy_coupled_convergence`, commits
/// `RSMN` with the accepted canopy/root state in `hourly_snow_energy`, and then
/// lets GROSUB consume that same-hour carrier. Its later EXTRACT aggregation
/// transaction must therefore leave this hook null; rerunning STOMATE there
/// would publish a post-UPTAKE value that neither the accepted fluxes nor
/// same-hour GROSUB consumed.
pub const Stomate = struct {
    /// One `canopy_minimum_stomatal_resistance.Inputs` per plant, in the same
    /// cell-major/species-major order as every other plant array here.
    resistance_inputs_by_plant: []const minimum_stomatal.Inputs,
    /// Destination for `RSMN`, that is
    /// `plant_minimum_water_vapor_resistance_h_per_m`.
    minimum_stomatal_resistance_h_per_m_by_plant: []f64,
    /// `RSMH`, the cuticular resistance from the PFT file. `stomate.f` 661
    /// takes `AMIN1(RSMH, ...)`, so `RSMN <= RSMH` is a source invariant that
    /// every downstream consumer relies on.
    cuticular_resistance_h_per_m_by_plant: []const f64,
};

/// The five UPTAKE/EXTRACT state_update owners that must advance together.
/// Each already validates its own inputs and publishes atomically; this
/// transaction is what makes the *set* atomic, so a partially advanced hour
/// can never be observed by REDIST, NITRO, or the output writers.
pub const Owners = struct {
    canopy_energy: *canopy_energy.State,
    root_water: *root_water.State,
    root_gas_content: *root_gas_content.State,
    root_gas_withdrawal: *root_gas_withdrawal.State,
    root_nutrient: *root_nutrient.State,
};

/// Shared traversal shape. Every owner is required to agree on it, because
/// `uptake.f` walks one cell/species/domain/layer nest for all of these
/// quantities; disagreement means two owners described different plants.
pub const Shape = struct {
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
};

pub const Inputs = struct {
    shape: Shape,
    /// Optional compatibility owner for standalone transaction callers. The
    /// production one-hour coupled canopy solve already owns and publishes the
    /// two source-mandated STOMATE passes, so production deliberately omits it.
    stomate: ?Stomate = null,
    canopy_energy: canopy_energy.Inputs,
    /// Persistent EXTRACT `ENGYX` carry. Mutated by the canopy owner, so it is
    /// snapshotted and rolled back with the published arrays.
    previous_canopy_water_energy_megajoules_by_plant: []f64,
    root_water: root_water.Inputs,
    root_gas_content: root_gas_content.Inputs,
    root_gas_withdrawal: root_gas_withdrawal.Inputs,
    root_nutrient: root_nutrient.Inputs,
};

pub const Dimensions = struct {
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
};

/// Preallocated rollback scratch. `apply` is allocation-free, as required for
/// a kernel that runs inside the hourly loop.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    dimensions: Dimensions,
    scratch: []f64,

    pub fn init(allocator: std.mem.Allocator, dimensions: Dimensions) !Workspace {
        if (dimensions.cell_count == 0 or dimensions.species_count == 0 or
            dimensions.soil_layer_capacity == 0 or
            dimensions.root_domain_capacity == 0)
            return error.InvalidUptakeTransactionDimensions;
        const scratch = try allocator.alloc(f64, try scratchLength(dimensions));
        @memset(scratch, 0);
        return .{
            .allocator = allocator,
            .dimensions = dimensions,
            .scratch = scratch,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.scratch);
        self.* = undefined;
    }
};

fn scratchLength(dimensions: Dimensions) !usize {
    const plant_count = try std.math.mul(
        usize,
        dimensions.cell_count,
        dimensions.species_count,
    );
    const layer_count = try std.math.mul(
        usize,
        dimensions.cell_count,
        dimensions.soil_layer_capacity,
    );
    // canopy: 2 plant arrays + 2 cell arrays + the persistent previous carry
    var total = try std.math.mul(usize, plant_count, 3);
    total = try std.math.add(usize, total, try std.math.mul(usize, dimensions.cell_count, 2));
    // root water: density, uptake, convective heat
    total = try std.math.add(usize, total, try std.math.mul(usize, layer_count, 3));
    // root gas content and nutrient uptake
    total = try std.math.add(usize, total, try std.math.mul(usize, layer_count, gas_count));
    total = try std.math.add(usize, total, try std.math.mul(usize, layer_count, nutrient_count));
    // root gas withdrawal: cell aggregate plus exact soil-layer provenance
    total = try std.math.add(usize, total, try std.math.mul(usize, dimensions.cell_count, gas_count));
    total = try std.math.add(usize, total, try std.math.mul(usize, layer_count, gas_count));
    // STOMATE `RSMN`: one plant array for the rollback snapshot, and one more
    // used as the owner's own compute scratch so `apply` stays allocation-free
    // and so a mid-array failure cannot leave a half-written destination.
    total = try std.math.add(usize, total, try std.math.mul(usize, plant_count, 2));
    return total;
}

const Cursor = struct {
    scratch: []f64,
    used: usize = 0,

    fn take(self: *Cursor, length: usize) []f64 {
        const slice = self.scratch[self.used .. self.used + length];
        self.used += length;
        return slice;
    }

    fn save(self: *Cursor, source: []const f64) void {
        @memcpy(self.take(source.len), source);
    }
};

/// Snapshot, compute, validate, then publish once.
///
/// The owners publish into their own arrays, so "publish once" is achieved by
/// snapshotting every destination first and restoring it on any failure. That
/// keeps the observable contract identical to a staged state_update while reusing
/// the already validated per-owner kernels rather than re-translating them.
///
/// Ordering follows `uptake.f`: canopy energy and water close before root
/// water uptake, which closes before root gas exchange, which closes before
/// nutrient uptake, because each later stage reads the earlier stage's
/// accepted state.
pub fn apply(workspace: *const Workspace, owners: Owners, inputs: Inputs) !void {
    try checkOwnerDimensions(workspace.dimensions, owners);
    try checkSharedShape(workspace.dimensions, inputs);

    var cursor: Cursor = .{ .scratch = workspace.scratch };
    const canopy_plant_energy = cursor.used;
    cursor.save(owners.canopy_energy.water_energy_megajoules_by_plant);
    cursor.save(owners.canopy_energy.water_energy_change_megajoules_per_h_by_plant);
    cursor.save(owners.canopy_energy.water_energy_megajoules_by_cell);
    cursor.save(owners.canopy_energy.water_energy_change_megajoules_per_h_by_cell);
    cursor.save(inputs.previous_canopy_water_energy_megajoules_by_plant);
    cursor.save(owners.root_water.root_length_density_m_per_m3);
    cursor.save(owners.root_water.water_uptake_m3_per_h);
    cursor.save(owners.root_water.convective_water_heat_megajoules_per_h);
    for (owners.root_gas_content.total_g_by_gas_and_layer) |values| cursor.save(values);
    for (owners.root_gas_withdrawal.loss_g_element_per_h_by_gas_and_cell) |values| cursor.save(values);
    for (owners.root_gas_withdrawal.loss_g_element_per_h_by_gas_and_layer) |values| cursor.save(values);
    for (owners.root_nutrient.uptake_g_element_per_h_by_nutrient_and_layer) |values| cursor.save(values);
    const plant_count = workspace.dimensions.cell_count * workspace.dimensions.species_count;
    if (inputs.stomate) |stomate| cursor.save(stomate.minimum_stomatal_resistance_h_per_m_by_plant);
    const compute_scratch = workspace.scratch[workspace.scratch.len - plant_count ..];
    std.debug.assert(cursor.used <= workspace.scratch.len - plant_count);
    std.debug.assert(canopy_plant_energy == 0);

    errdefer restore(workspace, owners, inputs);

    // `uptake.f` 474: STOMATE runs first in the hourly pass and publishes
    // `RSMN`, which the canopy energy balance below then reads.
    if (inputs.stomate) |stomate| {
        try minimum_stomatal.computeRuntimePlants(
            stomate.resistance_inputs_by_plant,
            compute_scratch,
            stomate.minimum_stomatal_resistance_h_per_m_by_plant,
        );
    }

    try canopy_energy.refresh(
        owners.canopy_energy,
        inputs.canopy_energy,
        inputs.previous_canopy_water_energy_megajoules_by_plant,
    );
    try root_water.refresh(owners.root_water, inputs.root_water);
    try root_gas_content.refresh(owners.root_gas_content, inputs.root_gas_content);
    try root_gas_withdrawal.refresh(
        owners.root_gas_withdrawal,
        inputs.root_gas_withdrawal,
    );
    try root_nutrient.refresh(owners.root_nutrient, inputs.root_nutrient);

    try checkCoupling(owners, inputs);
}

fn restore(workspace: *const Workspace, owners: Owners, inputs: Inputs) void {
    var cursor: Cursor = .{ .scratch = workspace.scratch };
    load(&cursor, owners.canopy_energy.water_energy_megajoules_by_plant);
    load(&cursor, owners.canopy_energy.water_energy_change_megajoules_per_h_by_plant);
    load(&cursor, owners.canopy_energy.water_energy_megajoules_by_cell);
    load(&cursor, owners.canopy_energy.water_energy_change_megajoules_per_h_by_cell);
    load(&cursor, inputs.previous_canopy_water_energy_megajoules_by_plant);
    load(&cursor, owners.root_water.root_length_density_m_per_m3);
    load(&cursor, owners.root_water.water_uptake_m3_per_h);
    load(&cursor, owners.root_water.convective_water_heat_megajoules_per_h);
    for (owners.root_gas_content.total_g_by_gas_and_layer) |values| load(&cursor, values);
    for (owners.root_gas_withdrawal.loss_g_element_per_h_by_gas_and_cell) |values| load(&cursor, values);
    for (owners.root_gas_withdrawal.loss_g_element_per_h_by_gas_and_layer) |values| load(&cursor, values);
    for (owners.root_nutrient.uptake_g_element_per_h_by_nutrient_and_layer) |values| load(&cursor, values);
    if (inputs.stomate) |stomate| load(&cursor, stomate.minimum_stomatal_resistance_h_per_m_by_plant);
}

fn load(cursor: *Cursor, destination: []f64) void {
    @memcpy(destination, cursor.take(destination.len));
}

fn checkOwnerDimensions(dimensions: Dimensions, owners: Owners) !void {
    const agrees =
        owners.canopy_energy.cell_count == dimensions.cell_count and
        owners.canopy_energy.species_count == dimensions.species_count and
        owners.root_water.cell_count == dimensions.cell_count and
        owners.root_water.species_count == dimensions.species_count and
        owners.root_water.soil_layer_capacity == dimensions.soil_layer_capacity and
        owners.root_water.root_domain_capacity == dimensions.root_domain_capacity and
        owners.root_gas_content.cell_count == dimensions.cell_count and
        owners.root_gas_content.species_count == dimensions.species_count and
        owners.root_gas_content.soil_layer_capacity == dimensions.soil_layer_capacity and
        owners.root_gas_content.root_domain_capacity == dimensions.root_domain_capacity and
        owners.root_gas_withdrawal.cell_count == dimensions.cell_count and
        owners.root_gas_withdrawal.species_count == dimensions.species_count and
        owners.root_gas_withdrawal.soil_layer_capacity == dimensions.soil_layer_capacity and
        owners.root_gas_withdrawal.root_domain_capacity == dimensions.root_domain_capacity and
        owners.root_nutrient.cell_count == dimensions.cell_count and
        owners.root_nutrient.species_count == dimensions.species_count and
        owners.root_nutrient.soil_layer_capacity == dimensions.soil_layer_capacity and
        owners.root_nutrient.root_domain_capacity == dimensions.root_domain_capacity;
    if (!agrees) return error.UptakeTransactionOwnerDimensionMismatch;
}

/// The three owners that take a traversal shape must be given the same one.
/// Distinct slices are permitted; disagreeing values are not, because that
/// would publish two different plant sets in one hour.
fn checkSharedShape(dimensions: Dimensions, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        dimensions.cell_count,
        dimensions.species_count,
    );
    if (inputs.shape.active_soil_layer_count_by_cell.len != dimensions.cell_count or
        inputs.shape.active_by_plant.len != plant_count or
        inputs.shape.root_domain_count_by_plant.len != plant_count or
        inputs.previous_canopy_water_energy_megajoules_by_plant.len != plant_count)
        return error.InvalidUptakeTransactionDimensions;
    if (inputs.stomate) |stomate| {
        if (stomate.resistance_inputs_by_plant.len != plant_count or
            stomate.minimum_stomatal_resistance_h_per_m_by_plant.len != plant_count or
            stomate.cuticular_resistance_h_per_m_by_plant.len != plant_count)
            return error.InvalidUptakeTransactionDimensions;
    }
    for (inputs.shape.active_soil_layer_count_by_cell) |active|
        if (active > dimensions.soil_layer_capacity)
            return error.InvalidUptakeTransactionDimensions;
    for (inputs.shape.root_domain_count_by_plant, inputs.shape.active_by_plant) |domains, active|
        if (active and (domains == 0 or domains > dimensions.root_domain_capacity))
            return error.InvalidUptakeTransactionDimensions;

    inline for (.{
        inputs.root_water.active_soil_layer_count_by_cell,
        inputs.root_gas_content.active_soil_layer_count_by_cell,
        inputs.root_nutrient.active_soil_layer_count_by_cell,
    }) |values| if (!std.mem.eql(usize, values, inputs.shape.active_soil_layer_count_by_cell))
        return error.UptakeTransactionShapeMismatch;
    inline for (.{
        inputs.root_water.active_by_plant,
        inputs.root_gas_content.active_by_plant,
        inputs.root_nutrient.active_by_plant,
    }) |values| if (!std.mem.eql(bool, values, inputs.shape.active_by_plant))
        return error.UptakeTransactionShapeMismatch;
    inline for (.{
        inputs.root_water.root_domain_count_by_plant,
        inputs.root_gas_content.root_domain_count_by_plant,
        inputs.root_nutrient.root_domain_count_by_plant,
    }) |values| if (!std.mem.eql(u8, values, inputs.shape.root_domain_count_by_plant))
        return error.UptakeTransactionShapeMismatch;
}

/// Cross-owner invariants that no single owner can see. These are physical,
/// not comparisons against legacy output.
fn checkCoupling(owners: Owners, inputs: Inputs) !void {
    // `stomate.f` 661: `RSMN=AMIN1(RSMH,AMAX1(RSMY,RSX*0.641))`. Both bounds
    // are load bearing downstream: `canopy_surface_exchange.refresh` rejects
    // `RSMH < RSMN`, and `canopy_carboxylation` computes the deep-root water
    // stress as `(RSMN/RC)^0.667`, which is only a fraction while `RSMN <= RC`
    // and `RC` is itself bounded below by `RSMN`. A zero `RSMN` is admissible
    // to the individual owners and silently zeroes that stress term, so the
    // positivity check belongs here, where the producer and its consumers are
    // visible together.
    if (inputs.stomate) |stomate| {
        for (
            stomate.minimum_stomatal_resistance_h_per_m_by_plant,
            stomate.cuticular_resistance_h_per_m_by_plant,
            inputs.shape.active_by_plant,
        ) |minimum, cuticular, active| {
            if (!std.math.isFinite(minimum) or minimum < 0)
                return error.UptakeTransactionInvalidMinimumStomatalResistance;
            if (minimum > cuticular)
                return error.UptakeTransactionMinimumStomatalResistanceAboveCuticular;
            if (active and cuticular > 0 and minimum == 0)
                return error.UptakeTransactionMinimumStomatalResistanceUnpublished;
        }
    }

    const layer_capacity = owners.root_water.soil_layer_capacity;
    for (0..owners.root_water.cell_count) |cell| {
        const active = inputs.shape.active_soil_layer_count_by_cell[cell];
        for (0..layer_capacity) |layer| {
            const index = cell * layer_capacity + layer;
            const water = owners.root_water.water_uptake_m3_per_h[index];
            const heat = owners.root_water.convective_water_heat_megajoules_per_h[index];

            if (layer >= active) {
                // An inactive layer must not carry uptake of any kind.
                if (water != 0 or heat != 0) return error.UptakeTransactionInactiveLayerPublished;
                for (owners.root_gas_content.total_g_by_gas_and_layer) |values|
                    if (values[index] != 0) return error.UptakeTransactionInactiveLayerPublished;
                for (owners.root_nutrient.uptake_g_element_per_h_by_nutrient_and_layer) |values|
                    if (values[index] != 0) return error.UptakeTransactionInactiveLayerPublished;
                continue;
            }

            // Convective heat is water carried at the layer temperature, so
            // the two must never disagree in sign.
            if ((water < 0) != (heat < 0) or (water > 0) != (heat > 0))
                return error.UptakeTransactionWaterHeatSignMismatch;
            const temperature = inputs.root_water.soil_temperature_k_by_layer[index];
            const expected = water * water_heat_capacity_megajoules_per_m3_k * temperature;
            if (@abs(heat - expected) > 1e-9 * @max(1.0, @abs(expected)))
                return error.UptakeTransactionWaterHeatClosureLost;

            // Root gas inventories are masses; nutrient uptake is an accepted
            // positive withdrawal from the soil pool.
            for (owners.root_gas_content.total_g_by_gas_and_layer) |values|
                if (!(values[index] >= 0)) return error.UptakeTransactionNegativeRootGasContent;
            for (owners.root_nutrient.uptake_g_element_per_h_by_nutrient_and_layer) |values|
                if (!(values[index] >= 0)) return error.UptakeTransactionNegativeNutrientUptake;
        }
    }

    // A cell with no active plant cannot withdraw gas from the atmosphere.
    for (0..owners.root_gas_withdrawal.cell_count) |cell| {
        var any_active = false;
        for (0..owners.root_gas_withdrawal.species_count) |species| {
            if (inputs.shape.active_by_plant[cell * owners.root_gas_withdrawal.species_count + species]) {
                any_active = true;
                break;
            }
        }
        if (any_active) continue;
        for (owners.root_gas_withdrawal.loss_g_element_per_h_by_gas_and_cell) |values|
            if (values[cell] != 0) return error.UptakeTransactionWithdrawalWithoutActivePlant;
    }
}

const TestFixture = struct {
    canopy: canopy_energy.State,
    water: root_water.State,
    gas: root_gas_content.State,
    withdrawal: root_gas_withdrawal.State,
    nutrient: root_nutrient.State,
    workspace: Workspace,

    fn init(dimensions: Dimensions) !TestFixture {
        const allocator = std.testing.allocator;
        return .{
            .canopy = try canopy_energy.State.init(
                allocator,
                dimensions.cell_count,
                dimensions.species_count,
            ),
            .water = try root_water.State.init(
                allocator,
                dimensions.cell_count,
                dimensions.species_count,
                dimensions.soil_layer_capacity,
                dimensions.root_domain_capacity,
            ),
            .gas = try root_gas_content.State.init(
                allocator,
                dimensions.cell_count,
                dimensions.species_count,
                dimensions.soil_layer_capacity,
                dimensions.root_domain_capacity,
            ),
            .withdrawal = try root_gas_withdrawal.State.init(
                allocator,
                dimensions.cell_count,
                dimensions.species_count,
                dimensions.soil_layer_capacity,
                dimensions.root_domain_capacity,
            ),
            .nutrient = try root_nutrient.State.init(
                allocator,
                dimensions.cell_count,
                dimensions.species_count,
                dimensions.soil_layer_capacity,
                dimensions.root_domain_capacity,
            ),
            .workspace = try Workspace.init(allocator, dimensions),
        };
    }

    fn deinit(self: *TestFixture) void {
        self.workspace.deinit();
        self.nutrient.deinit();
        self.withdrawal.deinit();
        self.gas.deinit();
        self.water.deinit();
        self.canopy.deinit();
    }

    fn owners(self: *TestFixture) Owners {
        return .{
            .canopy_energy = &self.canopy,
            .root_water = &self.water,
            .root_gas_content = &self.gas,
            .root_gas_withdrawal = &self.withdrawal,
            .root_nutrient = &self.nutrient,
        };
    }
};

// One cell, one species, two layers, one root domain.
const test_dimensions: Dimensions = .{
    .cell_count = 1,
    .species_count = 1,
    .soil_layer_capacity = 2,
    .root_domain_capacity = 1,
};

const test_active_layers = [_]usize{2};
const test_active = [_]bool{true};
const test_domains = [_]u8{1};
const test_soil_temperature = [_]f64{ 280, 290 };
const test_root_density = [_]f64{ 1, 2 };
const test_water_uptake = [_]f64{ -1, -2 };
const test_root_gas = [_]f64{ 1, 2 };
const test_withdrawal = [_]f64{-1};
const test_withdrawal_by_root = [_]f64{ -0.5, -0.5 };
const test_nutrient_uptake = [_]f64{ 0.5, 0.25 };

fn testInputs(previous: []f64) Inputs {
    var gaseous: [gas_count][]const f64 = undefined;
    for (&gaseous) |*slice| slice.* = &test_root_gas;
    var withdrawal: [gas_count][]const f64 = undefined;
    for (&withdrawal) |*slice| slice.* = &test_withdrawal;
    var withdrawal_by_root: [gas_count][]const f64 = undefined;
    for (&withdrawal_by_root) |*slice| slice.* = &test_withdrawal_by_root;
    var nutrients: [nutrient_count][]const f64 = undefined;
    for (&nutrients) |*slice| slice.* = &test_nutrient_uptake;
    return .{
        .shape = .{
            .active_soil_layer_count_by_cell = &test_active_layers,
            .active_by_plant = &test_active,
            .root_domain_count_by_plant = &test_domains,
        },
        .canopy_energy = .{
            .air_temperature_k_by_cell = &.{285},
            .canopy_temperature_k_by_plant = &.{288},
            .living_surface_water_m3_by_plant = &.{1},
            .standing_dead_surface_water_m3_by_plant = &.{0.5},
            .living_retention_m3_per_h_by_plant = &.{0.1},
            .standing_dead_retention_m3_per_h_by_plant = &.{0.05},
        },
        .previous_canopy_water_energy_megajoules_by_plant = previous,
        .root_water = .{
            .active_soil_layer_count_by_cell = &test_active_layers,
            .active_by_plant = &test_active,
            .root_domain_count_by_plant = &test_domains,
            .plant_population_count = &.{10},
            .cell_area_m2 = &.{1},
            .soil_temperature_k_by_layer = &test_soil_temperature,
            .root_length_density_m_per_m3 = &test_root_density,
            .water_uptake_m3_per_h = &test_water_uptake,
        },
        .root_gas_content = .{
            .active_soil_layer_count_by_cell = &test_active_layers,
            .active_by_plant = &test_active,
            .root_domain_count_by_plant = &test_domains,
            .gaseous_g_by_gas = gaseous,
            .aqueous_g_by_gas = gaseous,
        },
        .root_gas_withdrawal = .{
            .loss_g_element_per_h_by_gas_and_plant = withdrawal,
            .loss_g_element_per_h_by_gas_and_root = withdrawal_by_root,
        },
        .root_nutrient = .{
            .active_soil_layer_count_by_cell = &test_active_layers,
            .active_by_plant = &test_active,
            .root_domain_count_by_plant = &test_domains,
            .uptake_g_element_per_h_by_nutrient_and_root = nutrients,
        },
    };
}

test "coupled uptake transaction publishes every owner once" {
    var fixture = try TestFixture.init(test_dimensions);
    defer fixture.deinit();
    var previous = [_]f64{0};
    try apply(&fixture.workspace, fixture.owners(), testInputs(&previous));

    try std.testing.expectApproxEqAbs(
        4.19 * 1.5 * 288,
        fixture.canopy.water_energy_megajoules_by_plant[0],
        1e-12,
    );
    try std.testing.expectEqualSlices(f64, &.{ -1, -2 }, fixture.water.water_uptake_m3_per_h);
    try std.testing.expectApproxEqAbs(
        -2 * 4.19 * 290,
        fixture.water.convective_water_heat_megajoules_per_h[1],
        1e-12,
    );
    // gaseous plus aqueous of the same fixture slice
    try std.testing.expectEqual(@as(f64, 4), fixture.gas.total_g_by_gas_and_layer[0][1]);
    try std.testing.expectEqual(@as(f64, -1), fixture.withdrawal.loss_g_element_per_h_by_gas_and_cell[3][0]);
    try std.testing.expectEqualSlices(
        f64,
        &.{ -0.5, -0.5 },
        fixture.withdrawal.loss_g_element_per_h_by_gas_and_layer[3],
    );
    try std.testing.expectEqual(
        @as(f64, 0.25),
        fixture.nutrient.uptake_g_element_per_h_by_nutrient_and_layer[7][1],
    );
    try std.testing.expectApproxEqAbs(
        fixture.canopy.water_energy_megajoules_by_plant[0],
        previous[0],
        1e-12,
    );
}

test "a late owner failure rolls back every earlier owner and the energy carry" {
    var fixture = try TestFixture.init(test_dimensions);
    defer fixture.deinit();
    var previous = [_]f64{0};
    try apply(&fixture.workspace, fixture.owners(), testInputs(&previous));

    const canopy_before = try std.testing.allocator.dupe(
        f64,
        fixture.canopy.water_energy_megajoules_by_plant,
    );
    defer std.testing.allocator.free(canopy_before);
    const water_before = try std.testing.allocator.dupe(
        f64,
        fixture.water.water_uptake_m3_per_h,
    );
    defer std.testing.allocator.free(water_before);
    const gas_before = try std.testing.allocator.dupe(
        f64,
        fixture.gas.total_g_by_gas_and_layer[0],
    );
    defer std.testing.allocator.free(gas_before);
    const withdrawal_layer_before = try std.testing.allocator.dupe(
        f64,
        fixture.withdrawal.loss_g_element_per_h_by_gas_and_layer[0],
    );
    defer std.testing.allocator.free(withdrawal_layer_before);
    const previous_before = previous[0];

    // The nutrient owner is last; make only it fail.
    var inputs = testInputs(&previous);
    inputs.canopy_energy.canopy_temperature_k_by_plant = &.{300};
    const broken = [_]f64{ 0.5, std.math.nan(f64) };
    var nutrients: [nutrient_count][]const f64 = undefined;
    for (&nutrients) |*slice| slice.* = &broken;
    inputs.root_nutrient.uptake_g_element_per_h_by_nutrient_and_root = nutrients;

    try std.testing.expectError(
        error.NonFiniteRootNutrientStateUpdateInput,
        apply(&fixture.workspace, fixture.owners(), inputs),
    );

    try std.testing.expectEqualSlices(
        f64,
        canopy_before,
        fixture.canopy.water_energy_megajoules_by_plant,
    );
    try std.testing.expectEqualSlices(f64, water_before, fixture.water.water_uptake_m3_per_h);
    try std.testing.expectEqualSlices(f64, gas_before, fixture.gas.total_g_by_gas_and_layer[0]);
    try std.testing.expectEqualSlices(
        f64,
        withdrawal_layer_before,
        fixture.withdrawal.loss_g_element_per_h_by_gas_and_layer[0],
    );
    try std.testing.expectEqual(previous_before, previous[0]);
}

test "a disagreeing traversal shape is rejected before anything is published" {
    var fixture = try TestFixture.init(test_dimensions);
    defer fixture.deinit();
    var previous = [_]f64{0};
    var inputs = testInputs(&previous);
    const disagreeing = [_]usize{1};
    inputs.root_gas_content.active_soil_layer_count_by_cell = &disagreeing;
    try std.testing.expectError(
        error.UptakeTransactionShapeMismatch,
        apply(&fixture.workspace, fixture.owners(), inputs),
    );
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, fixture.water.water_uptake_m3_per_h);
    try std.testing.expectEqual(@as(f64, 0), previous[0]);
}

test "convective heat that contradicts its water uptake fails the coupling check" {
    var fixture = try TestFixture.init(test_dimensions);
    defer fixture.deinit();
    var previous = [_]f64{0};
    var inputs = testInputs(&previous);
    // A positive uptake in layer 1 against a negative one in layer 0 is legal
    // per owner; what is not legal is a temperature that breaks the closure.
    inputs.root_water.soil_temperature_k_by_layer = &.{ 280, 290 };
    try apply(&fixture.workspace, fixture.owners(), inputs);

    // Corrupt the published heat directly to prove the check would catch a
    // future owner that stopped deriving heat from water.
    fixture.water.convective_water_heat_megajoules_per_h[1] = 1;
    try std.testing.expectError(
        error.UptakeTransactionWaterHeatSignMismatch,
        checkCoupling(fixture.owners(), inputs),
    );
    fixture.water.convective_water_heat_megajoules_per_h[1] = -1;
    try std.testing.expectError(
        error.UptakeTransactionWaterHeatClosureLost,
        checkCoupling(fixture.owners(), inputs),
    );
}

test "an owner whose dimensions differ from the workspace is rejected" {
    var fixture = try TestFixture.init(test_dimensions);
    defer fixture.deinit();
    var other = try Workspace.init(std.testing.allocator, .{
        .cell_count = 2,
        .species_count = 1,
        .soil_layer_capacity = 2,
        .root_domain_capacity = 1,
    });
    defer other.deinit();
    var previous = [_]f64{0};
    try std.testing.expectError(
        error.UptakeTransactionOwnerDimensionMismatch,
        apply(&other, fixture.owners(), testInputs(&previous)),
    );
}

fn testStomateInputs() minimum_stomatal.Inputs {
    return .{
        .photosynthesis_active = true,
        .canopy_co2_fixation_umol_per_s = 100,
        .negligible_fixation_umol_per_s = 1.0e-12,
        .canopy_radiation_fraction = 1,
        .co2_concentration_difference_umol_per_m3 = 100,
        .horizontal_cell_area_m2 = 1,
        .seconds_per_hour = 3600,
        .cuticular_water_vapor_resistance_h_per_m = 0.01,
        .co2_to_water_cuticular_resistance_ratio = 1.56,
        .minimum_co2_stomatal_resistance_h_per_m = 2.78e-3,
        .co2_to_water_stomatal_resistance_ratio = 0.641,
    };
}

test "the transaction publishes STOMATE RSMN in the same hour as the five owners" {
    var fixture = try TestFixture.init(test_dimensions);
    defer fixture.deinit();
    var previous = [_]f64{0};
    var inputs = testInputs(&previous);
    const resistance_inputs = [_]minimum_stomatal.Inputs{testStomateInputs()};
    var minimum = [_]f64{0};
    const cuticular = [_]f64{0.01};
    inputs.stomate = .{
        .resistance_inputs_by_plant = &resistance_inputs,
        .minimum_stomatal_resistance_h_per_m_by_plant = &minimum,
        .cuticular_resistance_h_per_m_by_plant = &cuticular,
    };
    try apply(&fixture.workspace, fixture.owners(), inputs);

    // stomate.f 661 with this fixture: RSX = 1*100*1/(100*3600) = 2.7778e-4,
    // RSX*0.641 = 1.7806e-4, below RSMY = 2.78e-3, so AMAX1 selects RSMY and
    // AMIN1 keeps it because RSMH = 0.01 is larger.
    try std.testing.expectApproxEqAbs(2.78e-3, minimum[0], 1e-15);
    try std.testing.expect(minimum[0] <= cuticular[0]);
    // The five owners still published, so RSMN did not displace them.
    try std.testing.expectEqualSlices(f64, &.{ -1, -2 }, fixture.water.water_uptake_m3_per_h);
}

test "a late owner failure also rolls back the STOMATE RSMN state_update" {
    var fixture = try TestFixture.init(test_dimensions);
    defer fixture.deinit();
    var previous = [_]f64{0};
    var inputs = testInputs(&previous);
    const resistance_inputs = [_]minimum_stomatal.Inputs{testStomateInputs()};
    var minimum = [_]f64{41};
    const cuticular = [_]f64{0.01};
    inputs.stomate = .{
        .resistance_inputs_by_plant = &resistance_inputs,
        .minimum_stomatal_resistance_h_per_m_by_plant = &minimum,
        .cuticular_resistance_h_per_m_by_plant = &cuticular,
    };
    const broken = [_]f64{ 0.5, std.math.nan(f64) };
    var nutrients: [nutrient_count][]const f64 = undefined;
    for (&nutrients) |*slice| slice.* = &broken;
    inputs.root_nutrient.uptake_g_element_per_h_by_nutrient_and_root = nutrients;

    try std.testing.expectError(
        error.NonFiniteRootNutrientStateUpdateInput,
        apply(&fixture.workspace, fixture.owners(), inputs),
    );
    // The prior hour's RSMN survives untouched, exactly as the five owners do.
    try std.testing.expectEqual(@as(f64, 41), minimum[0]);
}

test "an unpublished RSMN for an active plant is rejected, not silently zero" {
    var fixture = try TestFixture.init(test_dimensions);
    defer fixture.deinit();
    var previous = [_]f64{0};
    var inputs = testInputs(&previous);
    const resistance_inputs = [_]minimum_stomatal.Inputs{testStomateInputs()};
    var minimum = [_]f64{0};
    const cuticular = [_]f64{0.01};
    inputs.stomate = .{
        .resistance_inputs_by_plant = &resistance_inputs,
        .minimum_stomatal_resistance_h_per_m_by_plant = &minimum,
        .cuticular_resistance_h_per_m_by_plant = &cuticular,
    };
    // This is the production defect UPTAKE-003 records: no producer ran, so
    // RSMN stayed at its zeroed allocation while an active plant read it.
    try std.testing.expectError(
        error.UptakeTransactionMinimumStomatalResistanceUnpublished,
        checkCoupling(fixture.owners(), inputs),
    );

    // And the other source bound: RSMN may never exceed RSMH.
    minimum[0] = 0.02;
    try std.testing.expectError(
        error.UptakeTransactionMinimumStomatalResistanceAboveCuticular,
        checkCoupling(fixture.owners(), inputs),
    );
}

test "a STOMATE array whose length differs from the plant count is rejected" {
    var fixture = try TestFixture.init(test_dimensions);
    defer fixture.deinit();
    var previous = [_]f64{0};
    var inputs = testInputs(&previous);
    const resistance_inputs = [_]minimum_stomatal.Inputs{ testStomateInputs(), testStomateInputs() };
    var minimum = [_]f64{0};
    const cuticular = [_]f64{0.01};
    inputs.stomate = .{
        .resistance_inputs_by_plant = &resistance_inputs,
        .minimum_stomatal_resistance_h_per_m_by_plant = &minimum,
        .cuticular_resistance_h_per_m_by_plant = &cuticular,
    };
    try std.testing.expectError(
        error.InvalidUptakeTransactionDimensions,
        apply(&fixture.workspace, fixture.owners(), inputs),
    );
    try std.testing.expectEqual(@as(f64, 0), previous[0]);
}

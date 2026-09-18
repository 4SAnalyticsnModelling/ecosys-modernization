const std = @import("std");
const admission = @import("rooted_layer_eligibility.zig");

pub const nutrient_pool_count = 8;
pub const salt_species_count = 8;

pub const CarbonNitrogenPhosphorus = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

pub const NutrientRespirationCost = struct {
    actual_cost_g_c: f64 = 0,
    oxygen_unlimited_g_c: f64 = 0,
    carbon_unlimited_g_c: f64 = 0,
};

pub const RespirationFlux = struct {
    /// Source `RCO2A`, negative for a root-to-CO2 carbon flux.
    actual_signed_g_c: f64 = 0,
    oxygen_unlimited_g_c: f64 = 0,
    carbon_unlimited_g_c: f64 = 0,
};

/// Process gates are supplied by their scientific owners. Topology admission
/// never infers them from area, activity, water volume, or chemistry.
pub const ProcessSelection = struct {
    nutrient: bool,
    organic: bool,
    dynamic_salt: bool,
};

pub const StagedTuple = struct {
    coordinate: admission.Coordinate,
    selected: ProcessSelection,
    nutrient_uptake_g_element: [nutrient_pool_count]f64,
    nutrient_respiration_cost: NutrientRespirationCost,
    /// Signed source RDFOM convention: positive soil-to-root uptake.
    organic_exchange_by_substrate: []const CarbonNitrogenPhosphorus,
    /// Signed soil-to-root ion transfer in mol, ordered Al, Fe, Ca, Mg, Na,
    /// K, SO4, Cl.
    salt_exchange_mol: [salt_species_count]f64,
    hydrogen_charge_mol: f64,
};

pub const State = struct {
    root_mobile_by_tuple: []CarbonNitrogenPhosphorus,
    root_respiration_by_tuple: []RespirationFlux,
    root_salt_mol_by_tuple_species: []f64,
    soil_mineral_g_element_by_layer_pool: []f64,
    soil_organic_by_layer_substrate: []CarbonNitrogenPhosphorus,
    soil_salt_mol_by_layer_species: []f64,
    hydrogen_charge_mol_by_layer: []f64,
};

pub const Inputs = struct {
    expected_admission: []const admission.Coordinate,
    staged_by_tuple: []const StagedTuple,
    soil_layer_count: usize,
    organic_substrate_count: usize,
};

/// Replays immutable GROSUB state_updates in admitted tuple order against
/// caller-owned scratch, then atomically publishes every root and soil field.
pub fn apply(authoritative: State, scratch: State, inputs: Inputs) !void {
    try validateDimensions(authoritative, inputs);
    try validateDimensions(scratch, inputs);
    if (inputs.staged_by_tuple.len != inputs.expected_admission.len)
        return error.MissingRootTransactionTuple;
    try validateAdmission(inputs.expected_admission, inputs.soil_layer_count);
    for (inputs.staged_by_tuple, inputs.expected_admission) |staged, expected| {
        if (!std.meta.eql(staged.coordinate, expected))
            return error.RootTransactionTupleMismatch;
        try validateStaged(staged, inputs.organic_substrate_count);
    }

    copyState(scratch, authoritative);
    for (inputs.staged_by_tuple, 0..) |staged, tuple| {
        const layer = staged.coordinate.soil_layer;
        if (staged.selected.dynamic_salt)
            try replayCharge(scratch, staged, layer);
        if (staged.selected.nutrient)
            try replayNutrientRespiration(scratch, staged, tuple);
        if (staged.selected.organic)
            try replayOrganic(scratch, staged, tuple, layer, inputs.organic_substrate_count);
        if (staged.selected.nutrient)
            try replayMineralUptake(scratch, staged, tuple, layer);
        if (staged.selected.dynamic_salt)
            try replaySalt(scratch, staged, tuple, layer);
    }
    copyState(authoritative, scratch);
}

fn replayNutrientRespiration(state: State, staged: StagedTuple, tuple: usize) !void {
    const mobile = &state.root_mobile_by_tuple[tuple];
    const respiration = staged.nutrient_respiration_cost;
    mobile.carbon_g_c = try boundedNext(mobile.carbon_g_c, -respiration.actual_cost_g_c);
    state.root_respiration_by_tuple[tuple].actual_signed_g_c = try finiteSum(state.root_respiration_by_tuple[tuple].actual_signed_g_c, -respiration.actual_cost_g_c);
    state.root_respiration_by_tuple[tuple].oxygen_unlimited_g_c = try finiteSum(state.root_respiration_by_tuple[tuple].oxygen_unlimited_g_c, respiration.oxygen_unlimited_g_c);
    state.root_respiration_by_tuple[tuple].carbon_unlimited_g_c = try finiteSum(state.root_respiration_by_tuple[tuple].carbon_unlimited_g_c, respiration.carbon_unlimited_g_c);
}

fn replayMineralUptake(state: State, staged: StagedTuple, tuple: usize, layer: usize) !void {
    const mobile = &state.root_mobile_by_tuple[tuple];
    for (staged.nutrient_uptake_g_element, 0..) |uptake, pool| {
        const soil_index = layer * nutrient_pool_count + pool;
        state.soil_mineral_g_element_by_layer_pool[soil_index] = try boundedNext(state.soil_mineral_g_element_by_layer_pool[soil_index], -uptake);
        if (pool < 4)
            mobile.nitrogen_g_n = try finiteSum(mobile.nitrogen_g_n, uptake)
        else
            mobile.phosphorus_g_p = try finiteSum(mobile.phosphorus_g_p, uptake);
    }
}

fn replayOrganic(state: State, staged: StagedTuple, tuple: usize, layer: usize, substrate_count: usize) !void {
    const mobile = &state.root_mobile_by_tuple[tuple];
    for (staged.organic_exchange_by_substrate, 0..) |exchange, substrate| {
        const soil = &state.soil_organic_by_layer_substrate[layer * substrate_count + substrate];
        soil.carbon_g_c = try boundedNext(soil.carbon_g_c, -exchange.carbon_g_c);
        soil.nitrogen_g_n = try boundedNext(soil.nitrogen_g_n, -exchange.nitrogen_g_n);
        soil.phosphorus_g_p = try boundedNext(soil.phosphorus_g_p, -exchange.phosphorus_g_p);
        mobile.carbon_g_c = try boundedNext(mobile.carbon_g_c, exchange.carbon_g_c);
        mobile.nitrogen_g_n = try boundedNext(mobile.nitrogen_g_n, exchange.nitrogen_g_n);
        mobile.phosphorus_g_p = try boundedNext(mobile.phosphorus_g_p, exchange.phosphorus_g_p);
    }
}

fn replaySalt(state: State, staged: StagedTuple, tuple: usize, layer: usize) !void {
    for (staged.salt_exchange_mol, 0..) |exchange, species| {
        const root_index = tuple * salt_species_count + species;
        const soil_index = layer * salt_species_count + species;
        state.soil_salt_mol_by_layer_species[soil_index] = try boundedNext(state.soil_salt_mol_by_layer_species[soil_index], -exchange);
        state.root_salt_mol_by_tuple_species[root_index] = try boundedNext(state.root_salt_mol_by_tuple_species[root_index], exchange);
    }
}

fn replayCharge(state: State, staged: StagedTuple, layer: usize) !void {
    state.hydrogen_charge_mol_by_layer[layer] = try finiteSum(state.hydrogen_charge_mol_by_layer[layer], staged.hydrogen_charge_mol);
}

fn validateAdmission(coordinates: []const admission.Coordinate, layer_count: usize) !void {
    for (coordinates, 0..) |coordinate, index| {
        if (coordinate.soil_layer >= layer_count) return error.RootTransactionLayerOutOfBounds;
        if (index == 0) continue;
        const previous = coordinates[index - 1];
        const ordered = coordinate.plant > previous.plant or
            (coordinate.plant == previous.plant and coordinate.biological_domain > previous.biological_domain) or
            (coordinate.plant == previous.plant and coordinate.biological_domain == previous.biological_domain and coordinate.soil_layer > previous.soil_layer);
        if (!ordered) {
            if (std.meta.eql(coordinate, previous)) return error.DuplicateRootTransactionTuple;
            return error.InvalidRootTransactionTupleOrder;
        }
    }
}

fn validateStaged(staged: StagedTuple, substrate_count: usize) !void {
    if (staged.organic_exchange_by_substrate.len != substrate_count)
        return error.RootTransactionSubstrateCountMismatch;
    inline for (.{ staged.nutrient_respiration_cost.actual_cost_g_c, staged.nutrient_respiration_cost.oxygen_unlimited_g_c, staged.nutrient_respiration_cost.carbon_unlimited_g_c, staged.hydrogen_charge_mol }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteRootTransactionInput;
    if (staged.nutrient_respiration_cost.actual_cost_g_c < 0 or staged.nutrient_respiration_cost.oxygen_unlimited_g_c < 0 or staged.nutrient_respiration_cost.carbon_unlimited_g_c < 0)
        return error.InvalidRootTransactionInput;
    for (staged.nutrient_uptake_g_element) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidRootTransactionInput;
    for (staged.organic_exchange_by_substrate) |exchange| try validateCnp(exchange, false);
    for (staged.salt_exchange_mol) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteRootTransactionInput;
    if (!staged.selected.nutrient and (!allZero(staged.nutrient_uptake_g_element) or !std.meta.eql(staged.nutrient_respiration_cost, NutrientRespirationCost{})))
        return error.DisabledRootProcessHasResults;
    if (!staged.selected.organic) for (staged.organic_exchange_by_substrate) |exchange|
        if (!std.meta.eql(exchange, CarbonNitrogenPhosphorus{})) return error.DisabledRootProcessHasResults;
    if (!staged.selected.dynamic_salt and (!allZero(staged.salt_exchange_mol) or staged.hydrogen_charge_mol != 0))
        return error.DisabledRootProcessHasResults;
}

fn validateDimensions(state: State, inputs: Inputs) !void {
    const tuples = inputs.expected_admission.len;
    const root_salt_count = std.math.mul(usize, tuples, salt_species_count) catch return error.RootTransactionDimensionOverflow;
    const mineral_count = std.math.mul(usize, inputs.soil_layer_count, nutrient_pool_count) catch return error.RootTransactionDimensionOverflow;
    const organic_count = std.math.mul(usize, inputs.soil_layer_count, inputs.organic_substrate_count) catch return error.RootTransactionDimensionOverflow;
    const soil_salt_count = std.math.mul(usize, inputs.soil_layer_count, salt_species_count) catch return error.RootTransactionDimensionOverflow;
    if (inputs.soil_layer_count == 0 or inputs.organic_substrate_count == 0 or
        state.root_mobile_by_tuple.len != tuples or state.root_respiration_by_tuple.len != tuples or
        state.root_salt_mol_by_tuple_species.len != root_salt_count or
        state.soil_mineral_g_element_by_layer_pool.len != mineral_count or
        state.soil_organic_by_layer_substrate.len != organic_count or
        state.soil_salt_mol_by_layer_species.len != soil_salt_count or
        state.hydrogen_charge_mol_by_layer.len != inputs.soil_layer_count)
        return error.RootTransactionDimensionMismatch;
    for (state.root_mobile_by_tuple) |value| try validateCnp(value, true);
    for (state.root_respiration_by_tuple) |value| {
        if (!std.math.isFinite(value.actual_signed_g_c) or value.actual_signed_g_c > 0)
            return error.InvalidRootTransactionState;
        inline for (.{ value.oxygen_unlimited_g_c, value.carbon_unlimited_g_c }) |field|
            if (!std.math.isFinite(field) or field < 0) return error.InvalidRootTransactionState;
    }
    for (state.soil_organic_by_layer_substrate) |value| try validateCnp(value, true);
    inline for (.{ state.root_salt_mol_by_tuple_species, state.soil_mineral_g_element_by_layer_pool, state.soil_salt_mol_by_layer_species }) |values|
        for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootTransactionState;
    for (state.hydrogen_charge_mol_by_layer) |value| if (!std.math.isFinite(value)) return error.InvalidRootTransactionState;
}

fn validateCnp(value: CarbonNitrogenPhosphorus, require_nonnegative: bool) !void {
    inline for (.{ value.carbon_g_c, value.nitrogen_g_n, value.phosphorus_g_p }) |field|
        if (!std.math.isFinite(field) or (require_nonnegative and field < 0))
            return error.InvalidRootTransactionState;
}

fn boundedNext(current: f64, delta: f64) !f64 {
    const result = current + delta;
    if (!std.math.isFinite(result)) return error.NonFiniteRootTransactionResult;
    if (result < 0) return error.InsufficientRootTransactionInventory;
    return result;
}

fn finiteSum(current: f64, delta: f64) !f64 {
    const result = current + delta;
    if (!std.math.isFinite(result)) return error.NonFiniteRootTransactionResult;
    return result;
}

fn allZero(values: [8]f64) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

fn copyState(destination: State, source: State) void {
    @memcpy(destination.root_mobile_by_tuple, source.root_mobile_by_tuple);
    @memcpy(destination.root_respiration_by_tuple, source.root_respiration_by_tuple);
    @memcpy(destination.root_salt_mol_by_tuple_species, source.root_salt_mol_by_tuple_species);
    @memcpy(destination.soil_mineral_g_element_by_layer_pool, source.soil_mineral_g_element_by_layer_pool);
    @memcpy(destination.soil_organic_by_layer_substrate, source.soil_organic_by_layer_substrate);
    @memcpy(destination.soil_salt_mol_by_layer_species, source.soil_salt_mol_by_layer_species);
    @memcpy(destination.hydrogen_charge_mol_by_layer, source.hydrogen_charge_mol_by_layer);
}

const TestStorage = struct {
    mobile: [2]CarbonNitrogenPhosphorus = .{ .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 1 }, .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 1 } },
    respiration: [2]RespirationFlux = .{ .{}, .{} },
    root_salt: [16]f64 = .{1} ** 16,
    mineral: [8]f64 = .{10} ** 8,
    organic: [2]CarbonNitrogenPhosphorus = .{ .{ .carbon_g_c = 5, .nitrogen_g_n = 5, .phosphorus_g_p = 5 }, .{ .carbon_g_c = 5, .nitrogen_g_n = 5, .phosphorus_g_p = 5 } },
    soil_salt: [8]f64 = .{10} ** 8,
    charge: [1]f64 = .{0},

    fn state(self: *TestStorage, tuple_count: usize) State {
        return self.stateRange(0, tuple_count);
    }

    fn stateRange(self: *TestStorage, first_tuple: usize, tuple_count: usize) State {
        return .{ .root_mobile_by_tuple = self.mobile[first_tuple..][0..tuple_count], .root_respiration_by_tuple = self.respiration[first_tuple..][0..tuple_count], .root_salt_mol_by_tuple_species = self.root_salt[first_tuple * salt_species_count ..][0 .. tuple_count * salt_species_count], .soil_mineral_g_element_by_layer_pool = &self.mineral, .soil_organic_by_layer_substrate = &self.organic, .soil_salt_mol_by_layer_species = &self.soil_salt, .hydrogen_charge_mol_by_layer = &self.charge };
    }
};

fn testStaged(coordinate: admission.Coordinate, organic: []const CarbonNitrogenPhosphorus) StagedTuple {
    return .{ .coordinate = coordinate, .selected = .{ .nutrient = true, .organic = true, .dynamic_salt = true }, .nutrient_uptake_g_element = .{1} ** 8, .nutrient_respiration_cost = .{ .actual_cost_g_c = 1, .oxygen_unlimited_g_c = 2, .carbon_unlimited_g_c = 3 }, .organic_exchange_by_substrate = organic, .salt_exchange_mol = .{0.5} ** 8, .hydrogen_charge_mol = 0.25 };
}

test "combined replay preserves respiration organic mineral salt order and closure" {
    const coordinates = [_]admission.Coordinate{.{ .plant = 0, .biological_domain = 0, .soil_layer = 0 }};
    const organic = [_]CarbonNitrogenPhosphorus{ .{ .carbon_g_c = 2, .nitrogen_g_n = -0.5, .phosphorus_g_p = 0.25 }, .{ .carbon_g_c = -1, .nitrogen_g_n = 0.5, .phosphorus_g_p = -0.25 } };
    const stages = [_]StagedTuple{testStaged(coordinates[0], &organic)};
    var state_store = TestStorage{};
    var scratch_store = TestStorage{};
    try apply(state_store.state(1), scratch_store.state(1), .{ .expected_admission = &coordinates, .staged_by_tuple = &stages, .soil_layer_count = 1, .organic_substrate_count = 2 });
    try std.testing.expectEqual(@as(f64, 10), state_store.mobile[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 5), state_store.mobile[0].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 5), state_store.mobile[0].phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, -1), state_store.respiration[0].actual_signed_g_c);
    try std.testing.expectEqual(@as(f64, 9), state_store.mineral[0]);
    try std.testing.expectEqual(@as(f64, 11), state_store.root_salt[0] + state_store.soil_salt[0]);
    try std.testing.expectEqual(@as(f64, 0.25), state_store.charge[0]);
    try std.testing.expectEqual(@as(f64, 20), state_store.mobile[0].carbon_g_c + state_store.organic[0].carbon_g_c + state_store.organic[1].carbon_g_c - state_store.respiration[0].actual_signed_g_c);
}

test "early XZHYS charge failure is atomic and actual RCO2A is negative" {
    const coordinate: admission.Coordinate = .{ .plant = 0, .biological_domain = 0, .soil_layer = 0 };
    const organic = [_]CarbonNitrogenPhosphorus{ .{}, .{} };
    var stage = testStaged(coordinate, &organic);
    stage.hydrogen_charge_mol = std.math.floatMax(f64);
    var state_store = TestStorage{};
    state_store.charge[0] = std.math.floatMax(f64);
    state_store.mobile[0].carbon_g_c = 0;
    const before = state_store;
    var scratch_store = TestStorage{};
    try std.testing.expectError(error.NonFiniteRootTransactionResult, apply(state_store.state(1), scratch_store.state(1), .{ .expected_admission = &.{coordinate}, .staged_by_tuple = &.{stage}, .soil_layer_count = 1, .organic_substrate_count = 2 }));
    try std.testing.expectEqualDeep(before, state_store);
}

test "sequential shared depletion fails late and rolls back authoritative state" {
    const coordinates = [_]admission.Coordinate{ .{ .plant = 0, .biological_domain = 0, .soil_layer = 0 }, .{ .plant = 0, .biological_domain = 1, .soil_layer = 0 } };
    const organic = [_]CarbonNitrogenPhosphorus{ .{}, .{} };
    var stages = [_]StagedTuple{ testStaged(coordinates[0], &organic), testStaged(coordinates[1], &organic) };
    stages[0].nutrient_uptake_g_element = .{6} ** 8;
    stages[1].nutrient_uptake_g_element = .{6} ** 8;
    var state_store = TestStorage{};
    const before = state_store;
    var scratch_store = TestStorage{};
    try std.testing.expectError(error.InsufficientRootTransactionInventory, apply(state_store.state(2), scratch_store.state(2), .{ .expected_admission = &coordinates, .staged_by_tuple = &stages, .soil_layer_count = 1, .organic_substrate_count = 2 }));
    try std.testing.expectEqualDeep(before, state_store);
}

test "any negative intermediate fails without a silent tolerance clamp" {
    const coordinate: admission.Coordinate = .{ .plant = 0, .biological_domain = 0, .soil_layer = 0 };
    const organic = [_]CarbonNitrogenPhosphorus{ .{}, .{} };
    var stage = testStaged(coordinate, &organic);
    stage.nutrient_respiration_cost.actual_cost_g_c = 1.0e-15;
    stage.nutrient_uptake_g_element = .{0} ** 8;
    stage.salt_exchange_mol = .{0} ** 8;
    stage.hydrogen_charge_mol = 0;
    var state_store = TestStorage{};
    state_store.mobile[0].carbon_g_c = 0;
    const before = state_store;
    var scratch_store = TestStorage{};
    try std.testing.expectError(error.InsufficientRootTransactionInventory, apply(state_store.state(1), scratch_store.state(1), .{ .expected_admission = &.{coordinate}, .staged_by_tuple = &.{stage}, .soil_layer_count = 1, .organic_substrate_count = 2 }));
    try std.testing.expectEqualDeep(before, state_store);
}

test "disabled salt leaves ion and charge state unchanged" {
    const coordinates = [_]admission.Coordinate{.{ .plant = 0, .biological_domain = 0, .soil_layer = 0 }};
    const organic = [_]CarbonNitrogenPhosphorus{ .{}, .{} };
    var stage = testStaged(coordinates[0], &organic);
    stage.selected.dynamic_salt = false;
    stage.salt_exchange_mol = .{0} ** 8;
    stage.hydrogen_charge_mol = 0;
    var state_store = TestStorage{};
    const salt_before = state_store.root_salt;
    var scratch_store = TestStorage{};
    try apply(state_store.state(1), scratch_store.state(1), .{ .expected_admission = &coordinates, .staged_by_tuple = &.{stage}, .soil_layer_count = 1, .organic_substrate_count = 2 });
    try std.testing.expectEqualDeep(salt_before, state_store.root_salt);
    try std.testing.expectEqual(@as(f64, 0), state_store.charge[0]);
}

test "ordered tuple decomposition is identical to one combined replay" {
    const coordinates = [_]admission.Coordinate{ .{ .plant = 0, .biological_domain = 0, .soil_layer = 0 }, .{ .plant = 0, .biological_domain = 1, .soil_layer = 0 } };
    const organic = [_]CarbonNitrogenPhosphorus{ .{ .carbon_g_c = 0.25, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.05 }, .{ .carbon_g_c = -0.1, .nitrogen_g_n = 0, .phosphorus_g_p = 0 } };
    var stages = [_]StagedTuple{ testStaged(coordinates[0], &organic), testStaged(coordinates[1], &organic) };
    stages[0].nutrient_uptake_g_element = .{0.5} ** 8;
    stages[1].nutrient_uptake_g_element = .{0.25} ** 8;
    var whole = TestStorage{};
    var split = TestStorage{};
    var whole_scratch = TestStorage{};
    var split_scratch = TestStorage{};
    try apply(whole.state(2), whole_scratch.state(2), .{ .expected_admission = &coordinates, .staged_by_tuple = &stages, .soil_layer_count = 1, .organic_substrate_count = 2 });
    try apply(split.stateRange(0, 1), split_scratch.stateRange(0, 1), .{ .expected_admission = coordinates[0..1], .staged_by_tuple = stages[0..1], .soil_layer_count = 1, .organic_substrate_count = 2 });
    try apply(split.stateRange(1, 1), split_scratch.stateRange(1, 1), .{ .expected_admission = coordinates[1..2], .staged_by_tuple = stages[1..2], .soil_layer_count = 1, .organic_substrate_count = 2 });
    try std.testing.expectEqualDeep(whole, split);
}

test "tuple mismatch missing duplicate and disabled-result inputs fail" {
    const coordinate: admission.Coordinate = .{ .plant = 0, .biological_domain = 0, .soil_layer = 0 };
    const organic = [_]CarbonNitrogenPhosphorus{ .{}, .{} };
    var state_store = TestStorage{};
    var scratch_store = TestStorage{};
    try std.testing.expectError(error.MissingRootTransactionTuple, apply(state_store.state(1), scratch_store.state(1), .{ .expected_admission = &.{coordinate}, .staged_by_tuple = &.{}, .soil_layer_count = 1, .organic_substrate_count = 2 }));
    var wrong = testStaged(.{ .plant = 1, .biological_domain = 0, .soil_layer = 0 }, &organic);
    try std.testing.expectError(error.RootTransactionTupleMismatch, apply(state_store.state(1), scratch_store.state(1), .{ .expected_admission = &.{coordinate}, .staged_by_tuple = &.{wrong}, .soil_layer_count = 1, .organic_substrate_count = 2 }));
    try std.testing.expectError(error.DuplicateRootTransactionTuple, apply(state_store.state(2), scratch_store.state(2), .{ .expected_admission = &.{ coordinate, coordinate }, .staged_by_tuple = &.{ wrong, wrong }, .soil_layer_count = 1, .organic_substrate_count = 2 }));
    wrong = testStaged(coordinate, &organic);
    wrong.selected.dynamic_salt = false;
    try std.testing.expectError(error.DisabledRootProcessHasResults, apply(state_store.state(1), scratch_store.state(1), .{ .expected_admission = &.{coordinate}, .staged_by_tuple = &.{wrong}, .soil_layer_count = 1, .organic_substrate_count = 2 }));
}

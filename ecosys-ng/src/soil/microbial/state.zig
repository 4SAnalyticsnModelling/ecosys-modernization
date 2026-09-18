const std = @import("std");
const metabolism = @import("metabolism.zig");

pub const ElementalPool = metabolism.ElementalPool;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    layer_count: usize,
    substrate_count: usize,
    population_count: usize,
    nonstructural: []ElementalPool,
    structural: []ElementalPool,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_count: usize, substrate_count: usize, population_count: usize) !State {
        if (cell_count == 0 or layer_count == 0 or substrate_count == 0 or population_count == 0) return error.InvalidMicrobialStateDimensions;
        var count = try std.math.mul(usize, cell_count, layer_count);
        count = try std.math.mul(usize, count, substrate_count);
        count = try std.math.mul(usize, count, population_count);
        const nonstructural = try allocator.alloc(ElementalPool, count);
        errdefer allocator.free(nonstructural);
        const structural = try allocator.alloc(ElementalPool, try std.math.mul(usize, count, 2));
        const zero: ElementalPool = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
        @memset(nonstructural, zero);
        @memset(structural, zero);
        return .{ .allocator = allocator, .cell_count = cell_count, .layer_count = layer_count, .substrate_count = substrate_count, .population_count = population_count, .nonstructural = nonstructural, .structural = structural };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.nonstructural);
        self.allocator.free(self.structural);
        self.* = undefined;
    }

    pub fn populationIndex(self: State, cell_index: usize, layer_index: usize, substrate_index: usize, population_index: usize) !usize {
        if (cell_index >= self.cell_count or layer_index >= self.layer_count or substrate_index >= self.substrate_count or population_index >= self.population_count) return error.MicrobialStateIndexOutOfBounds;
        return (((cell_index * self.layer_count + layer_index) * self.substrate_count + substrate_index) * self.population_count + population_index);
    }
};

pub const Fluxes = struct {
    assimilation: [2]ElementalPool,
    decomposition: [2]metabolism.DecompositionResult,
    senescence: [2]metabolism.DecompositionResult,
    total_carbon_uptake_g_c: f64,
    aerobic_respiration_g_c: f64,
    denitrification_respiration_g_c: f64,
    fixation_respiration_g_c: f64,
    dissolved_organic_nitrogen_uptake_g_n: f64,
    mineral_nitrogen_exchange_g_n: f64,
    fixed_nitrogen_g_n: f64,
    dissolved_organic_phosphorus_uptake_g_p: f64,
    mineral_phosphorus_exchange_g_p: f64,
    humus_partition: [2]f64,
};

pub const StateUpdateResult = struct { co2_emission_g_c: f64 };

/// NITRO K=5 permits one-based populations 1,2,3,5 only.
pub fn nitroPopulationEnabled(zero_based_substrate: usize, zero_based_population: usize) bool {
    return zero_based_substrate != 5 or zero_based_population <= 2 or zero_based_population == 4;
}

pub const NonstructuralStateUpdate = struct {
    current: ElementalPool,
    assimilation: [2]ElementalPool,
    basal_recycled: [2]ElementalPool,
    senescence_recycled: [2]ElementalPool,
    net_carbon_uptake_g_c: f64,
    dissolved_organic_nitrogen_uptake_g_n: f64,
    mineral_nitrogen_exchange_g_n: f64,
    fixed_nitrogen_g_n: f64,
    dissolved_organic_phosphorus_uptake_g_p: f64,
    mineral_phosphorus_exchange_g_p: f64,
};

/// NITRO 3821--3839 in source operation order for OMC/OMN/OMP(M=3).
pub fn calculateNonstructuralStateUpdate(inputs: NonstructuralStateUpdate) !ElementalPool {
    try validateNonstructuralPool(inputs.current);
    var next = inputs.current;
    for (0..2) |component| {
        try validatePool(inputs.assimilation[component]);
        try validatePool(inputs.basal_recycled[component]);
        try validatePool(inputs.senescence_recycled[component]);
        next.carbon_g_c = next.carbon_g_c - inputs.assimilation[component].carbon_g_c + inputs.basal_recycled[component].carbon_g_c;
        next.nitrogen_g_n = next.nitrogen_g_n - inputs.assimilation[component].nitrogen_g_n + inputs.basal_recycled[component].nitrogen_g_n + inputs.senescence_recycled[component].nitrogen_g_n;
        next.phosphorus_g_p = next.phosphorus_g_p - inputs.assimilation[component].phosphorus_g_p + inputs.basal_recycled[component].phosphorus_g_p + inputs.senescence_recycled[component].phosphorus_g_p;
    }
    inline for (.{ inputs.net_carbon_uptake_g_c, inputs.dissolved_organic_nitrogen_uptake_g_n, inputs.mineral_nitrogen_exchange_g_n, inputs.fixed_nitrogen_g_n, inputs.dissolved_organic_phosphorus_uptake_g_p, inputs.mineral_phosphorus_exchange_g_p }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteMicrobialStateFlux;
    next.carbon_g_c = next.carbon_g_c + inputs.net_carbon_uptake_g_c;
    next.nitrogen_g_n = next.nitrogen_g_n + inputs.dissolved_organic_nitrogen_uptake_g_n + inputs.mineral_nitrogen_exchange_g_n + inputs.fixed_nitrogen_g_n;
    next.phosphorus_g_p = next.phosphorus_g_p + inputs.dissolved_organic_phosphorus_uptake_g_p + inputs.mineral_phosphorus_exchange_g_p;
    try validateNonstructuralPool(next);
    return next;
}

/// `MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001`. The nonstructural pool is
/// `OMC/OMN/OMP(3,...)`, and the oracle deliberately allows it to go negative in
/// storage while clamping it on every read:
///
/// ```fortran
/// nitro.f:3824  OMC(3,N,K,L,NY,NX)=OMC(3,N,K,L,NY,NX)-CGOMS(M,N,K)+R3OMC(M,N,K)
/// nitro.f:3832  OMC(3,N,K,L,NY,NX)=OMC(3,N,K,L,NY,NX)+CGROMC
/// nitro.f:2094  OMC3=AMAX1(0.0,OMC(3,N,K,L,NY,NX))
/// nitro.f:2532  OMC3=AMAX1(0.0,OMC(3,N,K,L,NY,NX))
/// ```
///
/// The two write sites carry no `AMAX1`, and the two read sites carry one -- which
/// is only necessary because the stored value can be negative. So a negative
/// nonstructural pool is a state the oracle computes without complaint and
/// defends against at the point of use.
///
/// The translation instead made it **fatal in storage**, which stopped the deck at
/// hour 2,678 on `carbon_g_c = -1.2936078130910764e-7` with nitrogen and
/// phosphorus still positive -- the invented-guard-domain class recorded in
/// `project_invented_guard_domain_defect_class`, where the guard is the deviation
/// rather than the state.
///
/// Finiteness stays fatal: NaN or infinity is never a state the oracle produces.
/// The structural, residue, humus and flux pools keep the strict `validatePool`,
/// because the oracle's `AMAX1` appears only on `OMC(3,...)`.
fn validateNonstructuralPool(pool: ElementalPool) !void {
    inline for (@typeInfo(ElementalPool).@"struct".fields) |field|
        if (!std.math.isFinite(@field(pool, field.name))) return error.InvalidMicrobialStatePool;
}

/// Applies NITRO's final microbial pool equations for one runtime-indexed
/// population. All destinations are staged and checked before mutation.
///
/// MICROBIAL-STATE-UPDATE-DEAD-001: this is a reference implementation with
/// zero production callers. The live production path hand-duplicates this
/// same math in `src/soil/nutrients/nitrogen_state_update.zig` (see
/// `validateMicrobialDecompositionBalance` there for the equivalent
/// `decomposed == recycled + humified + microbial_residue` invariant,
/// enforced at the point production actually runs). A fix applied only
/// here has no effect on the simulation.
pub fn state_update(state: *State, population_index: usize, residue: *[2]ElementalPool, humus: *[2]ElementalPool, fluxes: Fluxes) !StateUpdateResult {
    if (population_index >= state.nonstructural.len) return error.MicrobialStateIndexOutOfBounds;
    try validatePool(state.nonstructural[population_index]);
    for (0..2) |component| {
        try validatePool(state.structural[population_index * 2 + component]);
        try validatePool(residue[component]);
        try validatePool(humus[component]);
        try validatePool(fluxes.assimilation[component]);
        try validateDecomposition(fluxes.decomposition[component]);
        try validateDecomposition(fluxes.senescence[component]);
    }
    inline for (.{ fluxes.total_carbon_uptake_g_c, fluxes.aerobic_respiration_g_c, fluxes.denitrification_respiration_g_c, fluxes.fixation_respiration_g_c, fluxes.dissolved_organic_nitrogen_uptake_g_n, fluxes.mineral_nitrogen_exchange_g_n, fluxes.fixed_nitrogen_g_n, fluxes.dissolved_organic_phosphorus_uptake_g_p, fluxes.mineral_phosphorus_exchange_g_p }) |value| if (!std.math.isFinite(value)) return error.NonFiniteMicrobialStateFlux;
    inline for (fluxes.humus_partition) |fraction| if (!std.math.isFinite(fraction) or fraction < 0) return error.InvalidHumusPartition;
    if (@abs(fluxes.humus_partition[0] + fluxes.humus_partition[1] - 1) > 1e-12) return error.InvalidHumusPartition;
    if (fluxes.total_carbon_uptake_g_c < 0 or fluxes.aerobic_respiration_g_c < 0 or fluxes.denitrification_respiration_g_c < 0 or fluxes.fixation_respiration_g_c < 0 or fluxes.dissolved_organic_nitrogen_uptake_g_n < 0 or fluxes.fixed_nitrogen_g_n < 0 or fluxes.dissolved_organic_phosphorus_uptake_g_p < 0) return error.InvalidMicrobialStateFlux;

    var next_nonstructural = state.nonstructural[population_index];
    var next_structural = [2]ElementalPool{ state.structural[population_index * 2], state.structural[population_index * 2 + 1] };
    var next_residue = residue.*;
    var next_humus = humus.*;
    const net_carbon_uptake = fluxes.total_carbon_uptake_g_c - fluxes.aerobic_respiration_g_c - fluxes.denitrification_respiration_g_c - fluxes.fixation_respiration_g_c;
    var co2_emission = fluxes.fixation_respiration_g_c;
    for (0..2) |component| {
        next_structural[component] = add(next_structural[component], fluxes.assimilation[component]);
        next_structural[component] = subtract(next_structural[component], fluxes.decomposition[component].decomposed);
        next_structural[component] = subtract(next_structural[component], fluxes.senescence[component].decomposed);
        next_nonstructural = subtract(next_nonstructural, fluxes.assimilation[component]);
        next_nonstructural = add(next_nonstructural, fluxes.decomposition[component].recycled);
        next_nonstructural.nitrogen_g_n += fluxes.senescence[component].recycled.nitrogen_g_n;
        next_nonstructural.phosphorus_g_p += fluxes.senescence[component].recycled.phosphorus_g_p;
        co2_emission += fluxes.senescence[component].recycled.carbon_g_c;
        next_residue[component] = add(next_residue[component], fluxes.decomposition[component].microbial_residue);
        next_residue[component] = add(next_residue[component], fluxes.senescence[component].microbial_residue);
        const combined_humus = add(fluxes.decomposition[component].humified, fluxes.senescence[component].humified);
        for (0..2) |humus_class| next_humus[humus_class] = add(next_humus[humus_class], scale(combined_humus, fluxes.humus_partition[humus_class]));
    }
    next_nonstructural.carbon_g_c += net_carbon_uptake;
    next_nonstructural.nitrogen_g_n += fluxes.dissolved_organic_nitrogen_uptake_g_n + fluxes.mineral_nitrogen_exchange_g_n + fluxes.fixed_nitrogen_g_n;
    next_nonstructural.phosphorus_g_p += fluxes.dissolved_organic_phosphorus_uptake_g_p + fluxes.mineral_phosphorus_exchange_g_p;
    try validatePool(next_nonstructural);
    for (next_structural) |pool| try validatePool(pool);
    for (next_residue) |pool| try validatePool(pool);
    for (next_humus) |pool| try validatePool(pool);
    state.nonstructural[population_index] = next_nonstructural;
    state.structural[population_index * 2] = next_structural[0];
    state.structural[population_index * 2 + 1] = next_structural[1];
    residue.* = next_residue;
    humus.* = next_humus;
    return .{ .co2_emission_g_c = co2_emission };
}

fn add(a: ElementalPool, b: ElementalPool) ElementalPool {
    return .{ .carbon_g_c = a.carbon_g_c + b.carbon_g_c, .nitrogen_g_n = a.nitrogen_g_n + b.nitrogen_g_n, .phosphorus_g_p = a.phosphorus_g_p + b.phosphorus_g_p };
}

fn subtract(a: ElementalPool, b: ElementalPool) ElementalPool {
    return .{ .carbon_g_c = a.carbon_g_c - b.carbon_g_c, .nitrogen_g_n = a.nitrogen_g_n - b.nitrogen_g_n, .phosphorus_g_p = a.phosphorus_g_p - b.phosphorus_g_p };
}

fn scale(pool: ElementalPool, fraction: f64) ElementalPool {
    return .{ .carbon_g_c = pool.carbon_g_c * fraction, .nitrogen_g_n = pool.nitrogen_g_n * fraction, .phosphorus_g_p = pool.phosphorus_g_p * fraction };
}

fn validatePool(pool: ElementalPool) !void {
    // Frontier blocker after PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001
    // was fixed: the deck now reaches hour 2,678 and stops here. The guard is
    // magnitude-gated at `-1e-14`, so unlike the invented-guard-domain class this
    // rejects a genuinely negative pool rather than a guessed domain -- but which
    // element and by how much decides whether the producer is over-drawing a real
    // pool or a rounding floor is too tight. Name it in the log rather than
    // inferring it.
    inline for (@typeInfo(ElementalPool).@"struct".fields) |field| if (!std.math.isFinite(@field(pool, field.name)) or @field(pool, field.name) < -1e-14) {
        std.log.info("microbial pool rejected: field={s} value={e} carbon_g_c={e} nitrogen_g_n={e} phosphorus_g_p={e}", .{
            field.name,
            @field(pool, field.name),
            pool.carbon_g_c,
            pool.nitrogen_g_n,
            pool.phosphorus_g_p,
        });
        return error.InvalidMicrobialStatePool;
    };
}

fn validateDecomposition(value: metabolism.DecompositionResult) !void {
    try validatePool(value.decomposed);
    try validatePool(value.recycled);
    try validatePool(value.humified);
    try validatePool(value.microbial_residue);
    inline for (@typeInfo(ElementalPool).@"struct".fields) |field| if (@abs(@field(value.decomposed, field.name) - @field(value.recycled, field.name) - @field(value.humified, field.name) - @field(value.microbial_residue, field.name)) > 1e-12 * @max(1, @field(value.decomposed, field.name))) return error.InvalidMicrobialDecompositionBalance;
}

fn emptyDecomposition() metabolism.DecompositionResult {
    const zero: ElementalPool = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    return .{ .decomposed = zero, .recycled = zero, .humified = zero, .microbial_residue = zero };
}

test "runtime microbial transaction conserves closed C N P system" {
    var state = try State.init(std.testing.allocator, 2, 3, 4, 11);
    defer state.deinit();
    const index = try state.populationIndex(1, 2, 3, 10);
    state.nonstructural[index] = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.1 };
    state.structural[index * 2] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 };
    state.structural[index * 2 + 1] = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.1 };
    var residue = [2]ElementalPool{ .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.02 }, .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.02 } };
    var humus = [2]ElementalPool{ .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.02 }, .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.02 } };
    const decomposition = try metabolism.decompose(.{ .pool = state.structural[index * 2], .temperature_response = 1, .water_response = 1, .basal_decomposition_rate_per_h = 0.1, .microbial_carbon_response = 1, .timestep_h = 1, .recycling = .{ .carbon = 0.3, .nitrogen = 0.4, .phosphorus = 0.5 }, .humification_fraction = 0.2, .humus_nitrogen_per_carbon_g_n_per_g_c = 0.1, .humus_phosphorus_per_carbon_g_p_per_g_c = 0.02 });
    const before_c = state.nonstructural[index].carbon_g_c + state.structural[index * 2].carbon_g_c + state.structural[index * 2 + 1].carbon_g_c + residue[0].carbon_g_c + residue[1].carbon_g_c + humus[0].carbon_g_c + humus[1].carbon_g_c;
    const result = try state_update(&state, index, &residue, &humus, .{ .assimilation = .{ .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 }, .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 } }, .decomposition = .{ decomposition, emptyDecomposition() }, .senescence = .{ emptyDecomposition(), emptyDecomposition() }, .total_carbon_uptake_g_c = 0, .aerobic_respiration_g_c = 0, .denitrification_respiration_g_c = 0, .fixation_respiration_g_c = 0, .dissolved_organic_nitrogen_uptake_g_n = 0, .mineral_nitrogen_exchange_g_n = 0, .fixed_nitrogen_g_n = 0, .dissolved_organic_phosphorus_uptake_g_p = 0, .mineral_phosphorus_exchange_g_p = 0, .humus_partition = .{ 0.6, 0.4 } });
    const after_c = state.nonstructural[index].carbon_g_c + state.structural[index * 2].carbon_g_c + state.structural[index * 2 + 1].carbon_g_c + residue[0].carbon_g_c + residue[1].carbon_g_c + humus[0].carbon_g_c + humus[1].carbon_g_c + result.co2_emission_g_c;
    try std.testing.expectApproxEqAbs(before_c, after_c, 1e-13);
}

test "invalid microbial transaction rolls back every destination" {
    var state = try State.init(std.testing.allocator, 1, 1, 1, 1);
    defer state.deinit();
    state.nonstructural[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    state.structural[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    state.structural[1] = state.structural[0];
    var residue = [2]ElementalPool{ state.structural[0], state.structural[0] };
    var humus = residue;
    const before_nonstructural = state.nonstructural[0];
    const before_residue = residue;
    var excessive = emptyDecomposition();
    excessive.decomposed.carbon_g_c = 2;
    excessive.microbial_residue.carbon_g_c = 2;
    try std.testing.expectError(error.InvalidMicrobialStatePool, state_update(&state, 0, &residue, &humus, .{ .assimilation = .{ .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 }, .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 } }, .decomposition = .{ excessive, emptyDecomposition() }, .senescence = .{ emptyDecomposition(), emptyDecomposition() }, .total_carbon_uptake_g_c = 0, .aerobic_respiration_g_c = 0, .denitrification_respiration_g_c = 0, .fixation_respiration_g_c = 0, .dissolved_organic_nitrogen_uptake_g_n = 0, .mineral_nitrogen_exchange_g_n = 0, .fixed_nitrogen_g_n = 0, .dissolved_organic_phosphorus_uptake_g_p = 0, .mineral_phosphorus_exchange_g_p = 0, .humus_partition = .{ 0.5, 0.5 } }));
    try std.testing.expectEqualDeep(before_nonstructural, state.nonstructural[0]);
    try std.testing.expectEqualDeep(before_residue, residue);
}

test "NITRO 3821-3839 nonstructural state_update preserves source order and C N P balance" {
    const next = try calculateNonstructuralStateUpdate(.{
        .current = .{ .carbon_g_c = 10, .nitrogen_g_n = 2, .phosphorus_g_p = 0.8 },
        .assimilation = .{
            .{ .carbon_g_c = 1, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.05 },
            .{ .carbon_g_c = 2, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.07 },
        },
        .basal_recycled = .{
            .{ .carbon_g_c = 0.4, .nitrogen_g_n = 0.08, .phosphorus_g_p = 0.02 },
            .{ .carbon_g_c = 0.5, .nitrogen_g_n = 0.09, .phosphorus_g_p = 0.03 },
        },
        .senescence_recycled = .{
            .{ .carbon_g_c = 9, .nitrogen_g_n = 0.04, .phosphorus_g_p = 0.01 },
            .{ .carbon_g_c = 9, .nitrogen_g_n = 0.05, .phosphorus_g_p = 0.015 },
        },
        .net_carbon_uptake_g_c = 3,
        .dissolved_organic_nitrogen_uptake_g_n = 0.6,
        .mineral_nitrogen_exchange_g_n = -0.1,
        .fixed_nitrogen_g_n = 0.2,
        .dissolved_organic_phosphorus_uptake_g_p = 0.12,
        .mineral_phosphorus_exchange_g_p = -0.02,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 10.9), next.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.46), next.nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.855), next.phosphorus_g_p, 1e-14);
}

test "NITRO nonstructural state_update rejects invalid late input" {
    try std.testing.expectError(error.NonFiniteMicrobialStateFlux, calculateNonstructuralStateUpdate(.{
        .current = .{ .carbon_g_c = 1, .nitrogen_g_n = 1, .phosphorus_g_p = 1 },
        .assimilation = .{
            .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
            .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        },
        .basal_recycled = .{
            .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
            .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        },
        .senescence_recycled = .{
            .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
            .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        },
        .net_carbon_uptake_g_c = 0,
        .dissolved_organic_nitrogen_uptake_g_n = 0,
        .mineral_nitrogen_exchange_g_n = 0,
        .fixed_nitrogen_g_n = 0,
        .dissolved_organic_phosphorus_uptake_g_p = 0,
        .mineral_phosphorus_exchange_g_p = std.math.nan(f64),
    }));
}

test "NITRO autotrophic population gate preserves one-based N 1 2 3 and 5" {
    try std.testing.expect(nitroPopulationEnabled(5, 0));
    try std.testing.expect(nitroPopulationEnabled(5, 2));
    try std.testing.expect(!nitroPopulationEnabled(5, 3));
    try std.testing.expect(nitroPopulationEnabled(5, 4));
    try std.testing.expect(!nitroPopulationEnabled(5, 5));
    try std.testing.expect(nitroPopulationEnabled(4, 6));
}

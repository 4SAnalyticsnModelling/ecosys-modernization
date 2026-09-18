const std = @import("std");
const RootState = @import("plant_root_system.zig").State;
const SoilState = @import("../../soil/organic/initialization.zig").State;
const OrganicPool = @import("../../soil/organic/initialization.zig").ElementPool;

pub const substrate_count: usize = @import("plant_root_system.zig").organic_substrate_count;

pub const Parameters = struct {
    maximum_root_carbon_concentration_g_c_per_m3: f64,
    root_mobile_nitrogen_exchange_fraction: f64,
    root_mobile_phosphorus_exchange_fraction: f64,
    exchange_rate_per_h: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.NonFiniteRootExudationParameter;
        if (self.maximum_root_carbon_concentration_g_c_per_m3 <= 0 or
            self.root_mobile_nitrogen_exchange_fraction < 0 or self.root_mobile_nitrogen_exchange_fraction > 1 or
            self.root_mobile_phosphorus_exchange_fraction < 0 or self.root_mobile_phosphorus_exchange_fraction > 1 or
            self.exchange_rate_per_h < 0)
            return error.InvalidRootExudationParameter;
    }
};

pub fn compatibilityParameters() Parameters {
    return .{
        .maximum_root_carbon_concentration_g_c_per_m3 = 1.0e3,
        .root_mobile_nitrogen_exchange_fraction = 0.1,
        .root_mobile_phosphorus_exchange_fraction = 0.1,
        .exchange_rate_per_h = 1.0e-3,
    };
}

pub const Input = struct {
    soil_water_volume_m3: f64,
    root_water_volume_m3: f64,
    soil_dissolved_carbon_g_c: f64,
    soil_dissolved_nitrogen_g_n: f64,
    soil_dissolved_phosphorus_g_p: f64,
    root_nonstructural_carbon_g_c: f64,
    root_nonstructural_nitrogen_g_n: f64,
    root_nonstructural_phosphorus_g_p: f64,
    maximum_root_carbon_concentration_g_c_per_m3: f64,
    root_mobile_nitrogen_exchange_fraction: f64,
    root_mobile_phosphorus_exchange_fraction: f64,
    exchange_rate_per_h: f64,
    timestep_h: f64,
    significance_threshold_g: f64,
};

/// Positive values are soil uptake by the root; negative values are exudation,
/// retaining the RDFOMC/RDFOMN/RDFOMP source sign convention.
pub const Result = struct { carbon_g_c: f64, nitrogen_g_n: f64, phosphorus_g_p: f64 };
pub const TransactionMapping = [substrate_count]Result;

pub fn mapTransactionResult(staged_results: []const Result) !TransactionMapping {
    if (staged_results.len != substrate_count) return error.RootExudationSubstrateCountMismatch;
    var mapped: TransactionMapping = undefined;
    for (staged_results, 0..) |result, substrate| {
        inline for (@typeInfo(Result).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteRootExudationResult;
        mapped[substrate] = result;
    }
    return mapped;
}

pub const Competitor = struct { plant: usize, domain: usize, layer: usize };

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    competitor_capacity: usize,
    competitors: []Competitor,
    admission_index_by_competitor: []usize,
    staged_results: []Result,

    pub fn init(allocator: std.mem.Allocator, competitor_capacity: usize) !Workspace {
        if (competitor_capacity == 0) return error.ZeroRootExudationCompetitorCapacity;
        const competitors = try allocator.alloc(Competitor, competitor_capacity);
        errdefer allocator.free(competitors);
        const admission_indices = try allocator.alloc(usize, competitor_capacity);
        errdefer allocator.free(admission_indices);
        const staged = try allocator.alloc(Result, try std.math.mul(usize, competitor_capacity, substrate_count));
        @memset(staged, .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 });
        return .{ .allocator = allocator, .competitor_capacity = competitor_capacity, .competitors = competitors, .admission_index_by_competitor = admission_indices, .staged_results = staged };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.staged_results);
        self.allocator.free(self.admission_index_by_competitor);
        self.allocator.free(self.competitors);
        self.* = undefined;
    }

    pub fn stageLayer(
        self: *Workspace,
        roots: *const RootState,
        soil: *const SoilState,
        soil_layer: usize,
        biologically_active_water_m3: f64,
        substrate_fraction: []const f64,
        parameters: Parameters,
        minimum_water_m3: f64,
        significance_threshold_g_c: f64,
        competitor_count: usize,
    ) !void {
        if (competitor_count > self.competitor_capacity) return error.RootExudationCompetitorOutOfBounds;
        if (substrate_fraction.len != substrate_count or !std.math.isFinite(biologically_active_water_m3) or biologically_active_water_m3 < 0 or !std.math.isFinite(minimum_water_m3) or minimum_water_m3 < 0 or !std.math.isFinite(significance_threshold_g_c) or significance_threshold_g_c < 0) return error.InvalidRootExudationWorkspaceInput;
        try parameters.validate();
        for (self.competitors[0..competitor_count], 0..) |competitor, competitor_index| {
            const root = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
            for (0..substrate_count) |substrate| {
                const fraction = substrate_fraction[substrate];
                if (!std.math.isFinite(fraction) or fraction < 0) return error.InvalidRootExudationWorkspaceInput;
                const output = &self.staged_results[competitor_index * substrate_count + substrate];
                const soil_index = soil_layer * substrate_count + substrate;
                const dissolved = soil.dissolved[soil_index];
                const soil_water = biologically_active_water_m3 * fraction;
                output.* = if (soil_water > minimum_water_m3 and roots.aqueous_volume_m3[root] > minimum_water_m3)
                    try calculate(.{
                        .soil_water_volume_m3 = soil_water,
                        .root_water_volume_m3 = roots.aqueous_volume_m3[root],
                        .soil_dissolved_carbon_g_c = dissolved.carbon_g_c,
                        .soil_dissolved_nitrogen_g_n = dissolved.nitrogen_g_n,
                        .soil_dissolved_phosphorus_g_p = dissolved.phosphorus_g_p,
                        .root_nonstructural_carbon_g_c = roots.mobile_carbon_g[root],
                        .root_nonstructural_nitrogen_g_n = roots.mobile_nitrogen_g[root],
                        .root_nonstructural_phosphorus_g_p = roots.mobile_phosphorus_g[root],
                        .maximum_root_carbon_concentration_g_c_per_m3 = parameters.maximum_root_carbon_concentration_g_c_per_m3,
                        .root_mobile_nitrogen_exchange_fraction = parameters.root_mobile_nitrogen_exchange_fraction,
                        .root_mobile_phosphorus_exchange_fraction = parameters.root_mobile_phosphorus_exchange_fraction,
                        .exchange_rate_per_h = parameters.exchange_rate_per_h,
                        .timestep_h = 1,
                        .significance_threshold_g = significance_threshold_g_c,
                    })
                else
                    .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
            }
        }
    }

    pub fn state_updateLayer(self: *Workspace, roots: *RootState, soil: *SoilState, soil_layer: usize, competitor_count: usize) !void {
        if (competitor_count > self.competitor_capacity) return error.RootExudationCompetitorOutOfBounds;
        // Every root/domain/layer competitor is unique. Validate all soil and
        // root destinations before publishing any of them.
        for (0..competitor_count) |first| for (first + 1..competitor_count) |second| {
            const a = self.competitors[first];
            const b = self.competitors[second];
            if (a.plant == b.plant and a.domain == b.domain and a.layer == b.layer) return error.DuplicateRootExudationCompetitor;
        };
        for (0..substrate_count) |substrate| {
            var total: Result = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
            for (0..competitor_count) |competitor_index| {
                const result = self.staged_results[competitor_index * substrate_count + substrate];
                total.carbon_g_c += result.carbon_g_c;
                total.nitrogen_g_n += result.nitrogen_g_n;
                total.phosphorus_g_p += result.phosphorus_g_p;
            }
            const soil_index = soil_layer * substrate_count + substrate;
            const dissolved = soil.dissolved[soil_index];
            inline for (.{
                dissolved.carbon_g_c - total.carbon_g_c,
                dissolved.nitrogen_g_n - total.nitrogen_g_n,
                dissolved.phosphorus_g_p - total.phosphorus_g_p,
            }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootExudationStateUpdate;
            inline for (.{
                dissolved.carbon_g_c - total.carbon_g_c,
                dissolved.nitrogen_g_n - total.nitrogen_g_n,
                dissolved.phosphorus_g_p - total.phosphorus_g_p,
            }) |value| if (value < 0) return error.InsufficientElementForRootExudation;
        }
        for (self.competitors[0..competitor_count], 0..) |competitor, competitor_index| {
            const root = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
            var root_delta: Result = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
            for (0..substrate_count) |substrate| {
                const result = self.staged_results[competitor_index * substrate_count + substrate];
                root_delta.carbon_g_c += result.carbon_g_c;
                root_delta.nitrogen_g_n += result.nitrogen_g_n;
                root_delta.phosphorus_g_p += result.phosphorus_g_p;
            }
            inline for (.{
                roots.mobile_carbon_g[root] + root_delta.carbon_g_c,
                roots.mobile_nitrogen_g[root] + root_delta.nitrogen_g_n,
                roots.mobile_phosphorus_g[root] + root_delta.phosphorus_g_p,
            }) |value| if (!std.math.isFinite(value) or value < 0) return error.InsufficientElementForRootExudation;
        }
        for (self.competitors[0..competitor_count], 0..) |competitor, competitor_index| {
            const root = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
            for (0..substrate_count) |substrate| {
                const result = self.staged_results[competitor_index * substrate_count + substrate];
                const soil_index = soil_layer * substrate_count + substrate;
                const root_substrate = try roots.substrateIndex(competitor.plant, competitor.domain, competitor.layer, substrate);
                soil.dissolved[soil_index].carbon_g_c -= result.carbon_g_c;
                soil.dissolved[soil_index].nitrogen_g_n -= result.nitrogen_g_n;
                soil.dissolved[soil_index].phosphorus_g_p -= result.phosphorus_g_p;
                roots.mobile_carbon_g[root] += result.carbon_g_c;
                roots.mobile_nitrogen_g[root] += result.nitrogen_g_n;
                roots.mobile_phosphorus_g[root] += result.phosphorus_g_p;
                roots.exudate_carbon_exchange_g_c_per_h[root_substrate] += result.carbon_g_c;
                roots.exudate_nitrogen_exchange_g_n_per_h[root_substrate] += result.nitrogen_g_n;
                roots.exudate_phosphorus_exchange_g_p_per_h[root_substrate] += result.phosphorus_g_p;
            }
        }
    }

    pub fn advanceLayer(self: *Workspace, roots: *RootState, soil: *SoilState, soil_layer: usize, biologically_active_water_m3: f64, substrate_fraction: []const f64, parameters: Parameters, minimum_water_m3: f64, significance_threshold_g_c: f64, competitor_count: usize) !void {
        try self.stageLayer(roots, soil, soil_layer, biologically_active_water_m3, substrate_fraction, parameters, minimum_water_m3, significance_threshold_g_c, competitor_count);
        try self.state_updateLayer(roots, soil, soil_layer, competitor_count);
    }
};

pub const GridWorkspace = struct {
    allocator: std.mem.Allocator,
    per_cell: []Workspace,
    admission_capacity_per_cell: usize,
    transaction_organic_storage: []TransactionMapping,
    transaction_organic_selected: []bool,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, competitor_capacity_per_cell: usize) !GridWorkspace {
        return initWithAdmissionCapacity(allocator, cell_count, competitor_capacity_per_cell, competitor_capacity_per_cell);
    }

    pub fn initWithAdmissionCapacity(allocator: std.mem.Allocator, cell_count: usize, competitor_capacity_per_cell: usize, admission_capacity_per_cell: usize) !GridWorkspace {
        if (cell_count == 0) return error.ZeroRootExudationGridCells;
        if (admission_capacity_per_cell == 0) return error.ZeroRootExudationAdmissionCapacity;
        const cells = try allocator.alloc(Workspace, cell_count);
        errdefer allocator.free(cells);
        var initialized: usize = 0;
        errdefer for (cells[0..initialized]) |*cell| cell.deinit();
        for (cells) |*cell| {
            cell.* = try Workspace.init(allocator, competitor_capacity_per_cell);
            initialized += 1;
        }
        const admission_count = try std.math.mul(usize, cell_count, admission_capacity_per_cell);
        const transaction_organic_storage = try allocator.alloc(TransactionMapping, admission_count);
        errdefer allocator.free(transaction_organic_storage);
        const transaction_organic_selected = try allocator.alloc(bool, admission_count);
        @memset(transaction_organic_selected, false);
        return .{ .allocator = allocator, .per_cell = cells, .admission_capacity_per_cell = admission_capacity_per_cell, .transaction_organic_storage = transaction_organic_storage, .transaction_organic_selected = transaction_organic_selected };
    }

    pub fn transactionOrganicBuffer(self: *GridWorkspace, cell: usize) ![]TransactionMapping {
        if (cell >= self.per_cell.len) return error.RootExudationGridCellOutOfBounds;
        return self.transaction_organic_storage[cell * self.admission_capacity_per_cell ..][0..self.admission_capacity_per_cell];
    }

    pub fn transactionOrganicSelection(self: *GridWorkspace, cell: usize) ![]bool {
        if (cell >= self.per_cell.len) return error.RootExudationGridCellOutOfBounds;
        return self.transaction_organic_selected[cell * self.admission_capacity_per_cell ..][0..self.admission_capacity_per_cell];
    }

    pub fn deinit(self: *GridWorkspace) void {
        for (self.per_cell) |*cell| cell.deinit();
        self.allocator.free(self.transaction_organic_selected);
        self.allocator.free(self.transaction_organic_storage);
        self.allocator.free(self.per_cell);
        self.* = undefined;
    }
};

pub fn calculate(input: Input) !Result {
    inline for (@typeInfo(Input).@"struct".fields) |field| if (!std.math.isFinite(@field(input, field.name))) return error.NonFiniteRootExudationInput;
    if (input.soil_water_volume_m3 <= 0 or input.root_water_volume_m3 <= 0 or input.soil_dissolved_carbon_g_c < 0 or input.soil_dissolved_nitrogen_g_n < 0 or input.soil_dissolved_phosphorus_g_p < 0 or input.root_nonstructural_carbon_g_c < 0 or input.root_nonstructural_nitrogen_g_n < 0 or input.root_nonstructural_phosphorus_g_p < 0 or input.maximum_root_carbon_concentration_g_c_per_m3 <= 0 or input.root_mobile_nitrogen_exchange_fraction < 0 or input.root_mobile_nitrogen_exchange_fraction > 1 or input.root_mobile_phosphorus_exchange_fraction < 0 or input.root_mobile_phosphorus_exchange_fraction > 1 or input.exchange_rate_per_h < 0 or input.timestep_h < 0 or input.significance_threshold_g < 0) return error.InvalidRootExudationInput;
    const total_water = input.soil_water_volume_m3 + input.root_water_volume_m3;
    const exchange_fraction = input.exchange_rate_per_h * input.timestep_h;
    const exchangeable_root_carbon = @min(input.maximum_root_carbon_concentration_g_c_per_m3 * input.root_water_volume_m3, input.root_nonstructural_carbon_g_c);
    const carbon = exchange_fraction * (input.soil_dissolved_carbon_g_c * input.root_water_volume_m3 - exchangeable_root_carbon * input.soil_water_volume_m3) / total_water;
    var nitrogen: f64 = 0;
    var phosphorus: f64 = 0;
    if (input.soil_dissolved_carbon_g_c > input.significance_threshold_g and input.root_nonstructural_carbon_g_c > input.significance_threshold_g) {
        const total_carbon = input.soil_dissolved_carbon_g_c + input.root_nonstructural_carbon_g_c;
        const exchangeable_nitrogen = input.root_mobile_nitrogen_exchange_fraction * input.root_nonstructural_nitrogen_g_n;
        const exchangeable_phosphorus = input.root_mobile_phosphorus_exchange_fraction * input.root_nonstructural_phosphorus_g_p;
        nitrogen = exchange_fraction * (input.soil_dissolved_nitrogen_g_n * input.root_nonstructural_carbon_g_c - exchangeable_nitrogen * input.soil_dissolved_carbon_g_c) / total_carbon;
        phosphorus = exchange_fraction * (input.soil_dissolved_phosphorus_g_p * input.root_nonstructural_carbon_g_c - exchangeable_phosphorus * input.soil_dissolved_carbon_g_c) / total_carbon;
    }
    const result = Result{ .carbon_g_c = carbon, .nitrogen_g_n = nitrogen, .phosphorus_g_p = phosphorus };
    inline for (@typeInfo(Result).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteRootExudationResult;
    return result;
}

/// Atomic RDFOM*/XOQ* state_update. Positive exchange removes dissolved
/// material from soil and adds it to the root mobile pool; negative exchange
/// is exudation. The soil change ledger therefore receives the opposite sign.
pub fn state_update(
    soil_dissolved_carbon_g_c: *f64,
    soil_dissolved_nitrogen_g_n: *f64,
    soil_dissolved_phosphorus_g_p: *f64,
    root_mobile_carbon_g_c: *f64,
    root_mobile_nitrogen_g_n: *f64,
    root_mobile_phosphorus_g_p: *f64,
    soil_carbon_change_g_c: *f64,
    soil_nitrogen_change_g_n: *f64,
    soil_phosphorus_change_g_p: *f64,
    exchange: Result,
) !void {
    const current = .{ soil_dissolved_carbon_g_c.*, soil_dissolved_nitrogen_g_n.*, soil_dissolved_phosphorus_g_p.*, root_mobile_carbon_g_c.*, root_mobile_nitrogen_g_n.*, root_mobile_phosphorus_g_p.*, soil_carbon_change_g_c.*, soil_nitrogen_change_g_n.*, soil_phosphorus_change_g_p.* };
    inline for (current) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootExudationStateUpdateInput;
    inline for (@typeInfo(Result).@"struct".fields) |field| if (!std.math.isFinite(@field(exchange, field.name))) return error.NonFiniteRootExudationResult;
    inline for (.{ soil_dissolved_carbon_g_c.*, soil_dissolved_nitrogen_g_n.*, soil_dissolved_phosphorus_g_p.*, root_mobile_carbon_g_c.*, root_mobile_nitrogen_g_n.*, root_mobile_phosphorus_g_p.* }) |value| if (value < 0) return error.InvalidRootExudationStateUpdateInput;

    const next_soil_c = soil_dissolved_carbon_g_c.* - exchange.carbon_g_c;
    const next_soil_n = soil_dissolved_nitrogen_g_n.* - exchange.nitrogen_g_n;
    const next_soil_p = soil_dissolved_phosphorus_g_p.* - exchange.phosphorus_g_p;
    const next_root_c = root_mobile_carbon_g_c.* + exchange.carbon_g_c;
    const next_root_n = root_mobile_nitrogen_g_n.* + exchange.nitrogen_g_n;
    const next_root_p = root_mobile_phosphorus_g_p.* + exchange.phosphorus_g_p;
    const next_change_c = soil_carbon_change_g_c.* - exchange.carbon_g_c;
    const next_change_n = soil_nitrogen_change_g_n.* - exchange.nitrogen_g_n;
    const next_change_p = soil_phosphorus_change_g_p.* - exchange.phosphorus_g_p;
    const next = .{ next_soil_c, next_soil_n, next_soil_p, next_root_c, next_root_n, next_root_p, next_change_c, next_change_n, next_change_p };
    inline for (next) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootExudationStateUpdate;
    inline for (.{ next_soil_c, next_soil_n, next_soil_p, next_root_c, next_root_n, next_root_p }) |value| if (value < 0) return error.InsufficientElementForRootExudation;

    soil_dissolved_carbon_g_c.* = next_soil_c;
    soil_dissolved_nitrogen_g_n.* = next_soil_n;
    soil_dissolved_phosphorus_g_p.* = next_soil_p;
    root_mobile_carbon_g_c.* = next_root_c;
    root_mobile_nitrogen_g_n.* = next_root_n;
    root_mobile_phosphorus_g_p.* = next_root_p;
    soil_carbon_change_g_c.* = next_change_c;
    soil_nitrogen_change_g_n.* = next_change_n;
    soil_phosphorus_change_g_p.* = next_change_p;
}

pub fn sumSubstrateExchange(carbon_g_c: []const f64, nitrogen_g_n: []const f64, phosphorus_g_p: []const f64) !Result {
    if (carbon_g_c.len != 5 or nitrogen_g_n.len != 5 or phosphorus_g_p.len != 5) return error.RootExudationSubstrateCountMismatch;
    var total: Result = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    for (carbon_g_c, nitrogen_g_n, phosphorus_g_p) |carbon, nitrogen, phosphorus| {
        inline for (.{ carbon, nitrogen, phosphorus }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootExudationResult;
        total.carbon_g_c += carbon;
        total.nitrogen_g_n += nitrogen;
        total.phosphorus_g_p += phosphorus;
    }
    inline for (@typeInfo(Result).@"struct".fields) |field| if (!std.math.isFinite(@field(total, field.name))) return error.NonFiniteRootExudationResult;
    return total;
}

test "UPTAKE C N P exudation retains concentration and stoichiometric equations" {
    const input = Input{ .soil_water_volume_m3 = 2, .root_water_volume_m3 = 1, .soil_dissolved_carbon_g_c = 3, .soil_dissolved_nitrogen_g_n = 0.4, .soil_dissolved_phosphorus_g_p = 0.08, .root_nonstructural_carbon_g_c = 6, .root_nonstructural_nitrogen_g_n = 1, .root_nonstructural_phosphorus_g_p = 0.2, .maximum_root_carbon_concentration_g_c_per_m3 = 1000, .root_mobile_nitrogen_exchange_fraction = 0.1, .root_mobile_phosphorus_exchange_fraction = 0.1, .exchange_rate_per_h = 0.2, .timestep_h = 0.5, .significance_threshold_g = 1.0e-12 };
    const result = try calculate(input);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1) * (3.0 * 1.0 - 6.0 * 2.0) / 3.0, result.carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1) * (0.4 * 6.0 - 0.1 * 3.0) / 9.0, result.nitrogen_g_n, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1) * (0.08 * 6.0 - 0.02 * 3.0) / 9.0, result.phosphorus_g_p, 1.0e-12);
}

test "UPTAKE exudation state_update conserves C N P and reverses soil ledger sign" {
    var soil_c: f64 = 2;
    var soil_n: f64 = 1;
    var soil_p: f64 = 0.5;
    var root_c: f64 = 3;
    var root_n: f64 = 0.4;
    var root_p: f64 = 0.2;
    var change_c: f64 = 0;
    var change_n: f64 = 0;
    var change_p: f64 = 0;
    const before = .{ soil_c + root_c, soil_n + root_n, soil_p + root_p };
    try state_update(&soil_c, &soil_n, &soil_p, &root_c, &root_n, &root_p, &change_c, &change_n, &change_p, .{ .carbon_g_c = -0.5, .nitrogen_g_n = 0.2, .phosphorus_g_p = -0.1 });
    try std.testing.expectApproxEqAbs(before[0], soil_c + root_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(before[1], soil_n + root_n, 1.0e-12);
    try std.testing.expectApproxEqAbs(before[2], soil_p + root_p, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), change_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), change_n, 1.0e-12);
    const total = try sumSubstrateExchange(&.{ -0.5, 1, 2, 3, 4 }, &.{ 0.2, 0, 0, 0, 0 }, &.{ -0.1, 0, 0, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), total.carbon_g_c, 1.0e-12);
}

test "five-substrate exudation workspace supports runtime competitors and rolls back atomically" {
    var roots = try RootState.init(std.testing.allocator, 7, 1, 1);
    defer roots.deinit();
    var soil = try SoilState.init(std.testing.allocator, 1);
    defer soil.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 7);
    defer workspace.deinit();
    for (0..substrate_count) |substrate| {
        soil.dissolved[substrate] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    }
    for (0..7) |plant| {
        const root = try roots.layerIndex(plant, 0, 0);
        roots.aqueous_volume_m3[root] = 0.1;
        roots.mobile_carbon_g[root] = 2;
        roots.mobile_nitrogen_g[root] = 0.2;
        roots.mobile_phosphorus_g[root] = 0.02;
        workspace.competitors[plant] = .{ .plant = plant, .domain = 0, .layer = 0 };
    }
    const fractions = [_]f64{0.2} ** substrate_count;
    var carbon_before: f64 = 0;
    for (soil.dissolved) |pool| carbon_before += pool.carbon_g_c;
    for (roots.mobile_carbon_g) |value| carbon_before += value;
    try workspace.stageLayer(&roots, &soil, 0, 1, &fractions, compatibilityParameters(), 1.0e-14, 1.0e-12, 7);
    try workspace.state_updateLayer(&roots, &soil, 0, 7);
    var carbon_after: f64 = 0;
    for (soil.dissolved) |pool| carbon_after += pool.carbon_g_c;
    for (roots.mobile_carbon_g) |value| carbon_after += value;
    try std.testing.expectApproxEqAbs(carbon_before, carbon_after, 1.0e-12);

    const soil_before_failure = soil.dissolved[0].carbon_g_c;
    const root_before_failure = roots.mobile_carbon_g[0];
    for (0..7) |competitor| workspace.staged_results[competitor * substrate_count] = .{ .carbon_g_c = 10, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    try std.testing.expectError(error.InsufficientElementForRootExudation, workspace.state_updateLayer(&roots, &soil, 0, 7));
    try std.testing.expectEqual(soil_before_failure, soil.dissolved[0].carbon_g_c);
    try std.testing.expectEqual(root_before_failure, roots.mobile_carbon_g[0]);
}

test "RDFOM advance is bit-identical to immutable stage then state_update in shared source order" {
    var combined_roots = try RootState.init(std.testing.allocator, 2, 1, 1);
    defer combined_roots.deinit();
    var staged_roots = try RootState.init(std.testing.allocator, 2, 1, 1);
    defer staged_roots.deinit();
    var combined_soil = try SoilState.init(std.testing.allocator, 1);
    defer combined_soil.deinit();
    var staged_soil = try SoilState.init(std.testing.allocator, 1);
    defer staged_soil.deinit();
    var combined = try Workspace.init(std.testing.allocator, 2);
    defer combined.deinit();
    var staged = try Workspace.init(std.testing.allocator, 2);
    defer staged.deinit();
    for (0..substrate_count) |substrate| {
        const pool = OrganicPool{ .carbon_g_c = 2 + @as(f64, @floatFromInt(substrate)), .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.08 };
        combined_soil.dissolved[substrate] = pool;
        staged_soil.dissolved[substrate] = pool;
    }
    for (0..2) |plant| {
        const competitor: Competitor = .{ .plant = plant, .domain = 0, .layer = 0 };
        combined.competitors[plant] = competitor;
        staged.competitors[plant] = competitor;
        combined.admission_index_by_competitor[plant] = plant + 1;
        staged.admission_index_by_competitor[plant] = plant + 1;
        const combined_root = try combined_roots.layerIndex(plant, 0, 0);
        const staged_root = try staged_roots.layerIndex(plant, 0, 0);
        combined_roots.aqueous_volume_m3[combined_root] = 0.2;
        staged_roots.aqueous_volume_m3[staged_root] = 0.2;
        combined_roots.mobile_carbon_g[combined_root] = 3 + @as(f64, @floatFromInt(plant));
        staged_roots.mobile_carbon_g[staged_root] = combined_roots.mobile_carbon_g[combined_root];
        combined_roots.mobile_nitrogen_g[combined_root] = 0.3;
        staged_roots.mobile_nitrogen_g[staged_root] = 0.3;
        combined_roots.mobile_phosphorus_g[combined_root] = 0.06;
        staged_roots.mobile_phosphorus_g[staged_root] = 0.06;
    }
    const fractions = [_]f64{0.2} ** substrate_count;
    try combined.advanceLayer(&combined_roots, &combined_soil, 0, 1, &fractions, compatibilityParameters(), 1.0e-14, 1.0e-12, 2);
    const root_before_stage = try std.testing.allocator.dupe(f64, staged_roots.mobile_carbon_g);
    defer std.testing.allocator.free(root_before_stage);
    const soil_before_stage = try std.testing.allocator.dupe(OrganicPool, staged_soil.dissolved);
    defer std.testing.allocator.free(soil_before_stage);
    try staged.stageLayer(&staged_roots, &staged_soil, 0, 1, &fractions, compatibilityParameters(), 1.0e-14, 1.0e-12, 2);
    try std.testing.expectEqualSlices(f64, root_before_stage, staged_roots.mobile_carbon_g);
    try std.testing.expectEqualSlices(OrganicPool, soil_before_stage, staged_soil.dissolved);
    try staged.state_updateLayer(&staged_roots, &staged_soil, 0, 2);
    try std.testing.expectEqualSlices(OrganicPool, combined_soil.dissolved, staged_soil.dissolved);
    try std.testing.expectEqualSlices(f64, combined_roots.mobile_carbon_g, staged_roots.mobile_carbon_g);
    try std.testing.expectEqualSlices(f64, combined_roots.mobile_nitrogen_g, staged_roots.mobile_nitrogen_g);
    try std.testing.expectEqualSlices(f64, combined_roots.mobile_phosphorus_g, staged_roots.mobile_phosphorus_g);
    try std.testing.expectEqualSlices(Result, combined.staged_results, staged.staged_results);
}

test "RDFOM signed uptake and exudation conserve C N P with late rollback and disabled selection" {
    var roots = try RootState.init(std.testing.allocator, 2, 1, 1);
    defer roots.deinit();
    var soil = try SoilState.init(std.testing.allocator, 1);
    defer soil.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 2);
    defer workspace.deinit();
    for (0..2) |plant| workspace.competitors[plant] = .{ .plant = plant, .domain = 0, .layer = 0 };
    for (0..substrate_count) |substrate| soil.dissolved[substrate] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.02 };
    for (0..2) |plant| {
        const root = try roots.layerIndex(plant, 0, 0);
        roots.mobile_carbon_g[root] = 2;
        roots.mobile_nitrogen_g[root] = 0.2;
        roots.mobile_phosphorus_g[root] = 0.04;
    }
    workspace.staged_results[0] = .{ .carbon_g_c = 0.2, .nitrogen_g_n = -0.01, .phosphorus_g_p = 0.002 };
    workspace.staged_results[substrate_count] = .{ .carbon_g_c = -0.1, .nitrogen_g_n = 0.02, .phosphorus_g_p = -0.001 };
    const before = .{ totalOrganicElement(&roots, &soil, .carbon), totalOrganicElement(&roots, &soil, .nitrogen), totalOrganicElement(&roots, &soil, .phosphorus) };
    try workspace.state_updateLayer(&roots, &soil, 0, 2);
    try std.testing.expectEqual(before[0], totalOrganicElement(&roots, &soil, .carbon));
    try std.testing.expectEqual(before[1], totalOrganicElement(&roots, &soil, .nitrogen));
    try std.testing.expectEqual(before[2], totalOrganicElement(&roots, &soil, .phosphorus));

    const soil_before = try std.testing.allocator.dupe(OrganicPool, soil.dissolved);
    defer std.testing.allocator.free(soil_before);
    const root_before = try std.testing.allocator.dupe(f64, roots.mobile_carbon_g);
    defer std.testing.allocator.free(root_before);
    workspace.staged_results[substrate_count + substrate_count - 1] = .{ .carbon_g_c = soil.dissolved[substrate_count - 1].carbon_g_c + 1, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    try std.testing.expectError(error.InsufficientElementForRootExudation, workspace.state_updateLayer(&roots, &soil, 0, 2));
    try std.testing.expectEqualSlices(OrganicPool, soil_before, soil.dissolved);
    try std.testing.expectEqualSlices(f64, root_before, roots.mobile_carbon_g);
    var grid = try GridWorkspace.initWithAdmissionCapacity(std.testing.allocator, 1, 2, 4);
    defer grid.deinit();
    try std.testing.expectEqualSlices(bool, &[_]bool{false} ** 4, try grid.transactionOrganicSelection(0));
}

test "root exudation rejects sub-legacy-tolerance soil overdraw atomically" {
    var roots = try RootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    var soil = try SoilState.init(std.testing.allocator, 1);
    defer soil.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 1);
    defer workspace.deinit();
    workspace.competitors[0] = .{ .plant = 0, .domain = 0, .layer = 0 };
    @memset(workspace.staged_results, .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 });
    soil.dissolved[0].carbon_g_c = 1;
    roots.mobile_carbon_g[0] = 1;
    workspace.staged_results[0].carbon_g_c = 1 + 5e-13;
    const soil_before = try std.testing.allocator.dupe(OrganicPool, soil.dissolved);
    defer std.testing.allocator.free(soil_before);
    const root_before = try std.testing.allocator.dupe(f64, roots.mobile_carbon_g);
    defer std.testing.allocator.free(root_before);
    try std.testing.expectError(error.InsufficientElementForRootExudation, workspace.state_updateLayer(&roots, &soil, 0, 1));
    try std.testing.expectEqualSlices(OrganicPool, soil_before, soil.dissolved);
    try std.testing.expectEqualSlices(f64, root_before, roots.mobile_carbon_g);
}

const OrganicElement = enum { carbon, nitrogen, phosphorus };

fn totalOrganicElement(roots: *const RootState, soil: *const SoilState, element: OrganicElement) f64 {
    var total: f64 = 0;
    for (soil.dissolved) |pool| total += switch (element) {
        .carbon => pool.carbon_g_c,
        .nitrogen => pool.nitrogen_g_n,
        .phosphorus => pool.phosphorus_g_p,
    };
    const values = switch (element) {
        .carbon => roots.mobile_carbon_g,
        .nitrogen => roots.mobile_nitrogen_g,
        .phosphorus => roots.mobile_phosphorus_g,
    };
    for (values) |value| total += value;
    return total;
}

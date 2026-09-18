const std = @import("std");
const snow = @import("../solute/snow_solute_transport.zig");

// REDIST 7405-7514 selects an adjacent source/destination and one fraction;
// 7516-7549 moves every phase, sensible heat, and primary solute to the
// recipient; 7571-7610 moves dynamic salts; 7619-7689 applies the identical
// donor loss. Fixed snow-layer slots therefore remain separate conservation
// control volumes even while their geometry and contents are relayered.

pub const Report = struct {
    transfers: usize,
    maximum_fraction: f64,
};

pub const Direction = struct {
    solid_snow_water_equivalent_m3: []f64,
    liquid_water_m3: []f64,
    vapor_water_equivalent_m3: []f64,
    ice_volume_m3: []f64,
    sensible_heat_megajoules: []f64,
    amount_g: []f64,
    salt_amount_mol: []f64,

    fn init(allocator: std.mem.Allocator, layer_count: usize) !Direction {
        const solid = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(solid);
        const liquid = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(liquid);
        const vapor = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(vapor);
        const ice = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(ice);
        const heat = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(heat);
        const amount = try allocator.alloc(f64, try std.math.mul(usize, layer_count, snow.species_count));
        errdefer allocator.free(amount);
        const salt = try allocator.alloc(f64, try std.math.mul(usize, layer_count, snow.salt_species_count));
        errdefer allocator.free(salt);
        var result: Direction = .{
            .solid_snow_water_equivalent_m3 = solid,
            .liquid_water_m3 = liquid,
            .vapor_water_equivalent_m3 = vapor,
            .ice_volume_m3 = ice,
            .sensible_heat_megajoules = heat,
            .amount_g = amount,
            .salt_amount_mol = salt,
        };
        result.reset();
        return result;
    }

    fn deinit(self: *Direction, allocator: std.mem.Allocator) void {
        allocator.free(self.solid_snow_water_equivalent_m3);
        allocator.free(self.liquid_water_m3);
        allocator.free(self.vapor_water_equivalent_m3);
        allocator.free(self.ice_volume_m3);
        allocator.free(self.sensible_heat_megajoules);
        allocator.free(self.amount_g);
        allocator.free(self.salt_amount_mol);
        self.* = undefined;
    }

    fn reset(self: *Direction) void {
        inline for (.{
            self.solid_snow_water_equivalent_m3,
            self.liquid_water_m3,
            self.vapor_water_equivalent_m3,
            self.ice_volume_m3,
            self.sensible_heat_megajoules,
            self.amount_g,
            self.salt_amount_mol,
        }) |values| @memset(values, 0);
    }

    fn addTransfer(
        self: *Direction,
        interface_lower_layer: usize,
        source_layer: usize,
        fraction: f64,
        solid: []const f64,
        liquid: []const f64,
        vapor: []const f64,
        ice: []const f64,
        sensible_energy_megajoules: f64,
        amount_g: []const f64,
        salt_amount_mol: []const f64,
    ) !void {
        self.solid_snow_water_equivalent_m3[interface_lower_layer] = try checkedAdd(
            self.solid_snow_water_equivalent_m3[interface_lower_layer],
            fraction * solid[source_layer],
        );
        self.liquid_water_m3[interface_lower_layer] = try checkedAdd(
            self.liquid_water_m3[interface_lower_layer],
            fraction * liquid[source_layer],
        );
        self.vapor_water_equivalent_m3[interface_lower_layer] = try checkedAdd(
            self.vapor_water_equivalent_m3[interface_lower_layer],
            fraction * vapor[source_layer],
        );
        self.ice_volume_m3[interface_lower_layer] = try checkedAdd(
            self.ice_volume_m3[interface_lower_layer],
            fraction * ice[source_layer],
        );
        self.sensible_heat_megajoules[interface_lower_layer] = try checkedAdd(
            self.sensible_heat_megajoules[interface_lower_layer],
            fraction * sensible_energy_megajoules,
        );
        for (0..snow.species_count) |species| {
            const source_index = source_layer * snow.species_count + species;
            const destination_index = interface_lower_layer * snow.species_count + species;
            self.amount_g[destination_index] = try checkedAdd(
                self.amount_g[destination_index],
                fraction * amount_g[source_index],
            );
        }
        for (0..snow.salt_species_count) |species| {
            const source_index = source_layer * snow.salt_species_count + species;
            const destination_index = interface_lower_layer * snow.salt_species_count + species;
            self.salt_amount_mol[destination_index] = try checkedAdd(
                self.salt_amount_mol[destination_index],
                fraction * salt_amount_mol[source_index],
            );
        }
    }

    fn validateAdd(self: Direction, other: Direction) !void {
        inline for (.{
            .{ self.solid_snow_water_equivalent_m3, other.solid_snow_water_equivalent_m3 },
            .{ self.liquid_water_m3, other.liquid_water_m3 },
            .{ self.vapor_water_equivalent_m3, other.vapor_water_equivalent_m3 },
            .{ self.ice_volume_m3, other.ice_volume_m3 },
            .{ self.sensible_heat_megajoules, other.sensible_heat_megajoules },
            .{ self.amount_g, other.amount_g },
            .{ self.salt_amount_mol, other.salt_amount_mol },
        }) |pair| {
            if (pair[0].len != pair[1].len) return error.SnowRelayeringAcceptedTransferDimensionMismatch;
            for (pair[0], pair[1]) |total, increment| _ = try checkedAdd(total, increment);
        }
    }

    fn addValidated(self: *Direction, other: Direction) void {
        inline for (.{
            .{ self.solid_snow_water_equivalent_m3, other.solid_snow_water_equivalent_m3 },
            .{ self.liquid_water_m3, other.liquid_water_m3 },
            .{ self.vapor_water_equivalent_m3, other.vapor_water_equivalent_m3 },
            .{ self.ice_volume_m3, other.ice_volume_m3 },
            .{ self.sensible_heat_megajoules, other.sensible_heat_megajoules },
            .{ self.amount_g, other.amount_g },
            .{ self.salt_amount_mol, other.salt_amount_mol },
        }) |pair| {
            for (pair[0], pair[1]) |*total, increment| total.* += increment;
        }
    }
};

/// Direction-separated, interface-indexed accepted transfers. Index `i > 0`
/// denotes the interface between flat snow layers `i-1` and `i` in one cell;
/// index zero of each cell remains exactly zero.
pub const AcceptedTransfers = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    downward: Direction,
    upward: Direction,
    touched_by_layer: []bool,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !AcceptedTransfers {
        if (layer_count == 0) return error.InvalidSnowRelayeringAcceptedTransferDimension;
        var downward = try Direction.init(allocator, layer_count);
        errdefer downward.deinit(allocator);
        var upward = try Direction.init(allocator, layer_count);
        errdefer upward.deinit(allocator);
        const touched = try allocator.alloc(bool, layer_count);
        errdefer allocator.free(touched);
        @memset(touched, false);
        return .{ .allocator = allocator, .layer_count = layer_count, .downward = downward, .upward = upward, .touched_by_layer = touched };
    }

    pub fn deinit(self: *AcceptedTransfers) void {
        self.downward.deinit(self.allocator);
        self.upward.deinit(self.allocator);
        self.allocator.free(self.touched_by_layer);
        self.* = undefined;
    }

    pub fn reset(self: *AcceptedTransfers) void {
        self.downward.reset();
        self.upward.reset();
        @memset(self.touched_by_layer, false);
    }

    pub fn add(self: *AcceptedTransfers, other: AcceptedTransfers) !void {
        if (self.layer_count != other.layer_count or
            self.touched_by_layer.len != self.layer_count or
            other.touched_by_layer.len != other.layer_count)
            return error.SnowRelayeringAcceptedTransferDimensionMismatch;
        // Validate both directions before the first write so a rejected
        // substep cannot partially alter the hourly accepted sidecar.
        try self.downward.validateAdd(other.downward);
        try self.upward.validateAdd(other.upward);
        self.downward.addValidated(other.downward);
        self.upward.addValidated(other.upward);
        for (self.touched_by_layer, other.touched_by_layer) |*touched, increment|
            touched.* = touched.* or increment;
    }
};

pub const Tolerances = struct {
    volume_absolute_m3: f64,
    heat_capacity_absolute_megajoules_per_k: f64,
    relative: f64,

    fn validate(self: Tolerances) !void {
        inline for (.{ self.volume_absolute_m3, self.heat_capacity_absolute_megajoules_per_k }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowRelayeringTolerance;
        if (!std.math.isFinite(self.relative) or self.relative <= 0 or self.relative >= 1)
            return error.InvalidSnowRelayeringTolerance;
    }

    fn volume(self: Tolerances, scale_m3: f64) f64 {
        return self.volume_absolute_m3 + self.relative * @abs(scale_m3);
    }

    fn heatCapacity(self: Tolerances, scale_megajoules_per_k: f64) f64 {
        return self.heat_capacity_absolute_megajoules_per_k + self.relative * @abs(scale_megajoules_per_k);
    }
};

/// REDIST snow relayering for runtime layer counts. Every physical constituent,
/// sensible energy, and tracked solute moves by the same source fraction. The
/// complete candidate state is validated before atomic state_update.
pub fn apply(allocator: std.mem.Allocator, state: *snow.State, thermodynamics: snow.ThermodynamicParameters, tolerances: Tolerances) !Report {
    return applyInternal(allocator, state, thermodynamics, tolerances, null);
}

pub fn applyAccepted(
    allocator: std.mem.Allocator,
    state: *snow.State,
    thermodynamics: snow.ThermodynamicParameters,
    tolerances: Tolerances,
    accepted: *AcceptedTransfers,
) !Report {
    return applyInternal(allocator, state, thermodynamics, tolerances, accepted);
}

fn applyInternal(
    allocator: std.mem.Allocator,
    state: *snow.State,
    thermodynamics: snow.ThermodynamicParameters,
    tolerances: Tolerances,
    accepted: ?*AcceptedTransfers,
) !Report {
    inline for (@typeInfo(snow.ThermodynamicParameters).@"struct".fields) |field| {
        const value = @field(thermodynamics, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidSnowRelayeringThermodynamics;
    }
    try tolerances.validate();
    if (accepted) |transfers| {
        try validateAcceptedTransfers(transfers, state.active.len);
        transfers.reset();
    }
    errdefer if (accepted) |transfers| transfers.reset();
    const solid = try allocator.dupe(f64, state.solid_snow_water_equivalent_m3);
    defer allocator.free(solid);
    const liquid = try allocator.dupe(f64, state.liquid_water_volume_m3);
    defer allocator.free(liquid);
    const vapor = try allocator.dupe(f64, state.vapor_water_equivalent_m3);
    defer allocator.free(vapor);
    const ice = try allocator.dupe(f64, state.ice_volume_m3);
    defer allocator.free(ice);
    const temperature = try allocator.dupe(f64, state.temperature_k);
    defer allocator.free(temperature);
    const heat_capacity = try allocator.dupe(f64, state.heat_capacity_megajoules_per_k);
    defer allocator.free(heat_capacity);
    const amount_g = try allocator.dupe(f64, state.amount_g);
    defer allocator.free(amount_g);
    const salt_amount_mol = try allocator.dupe(f64, state.salt_amount_mol);
    defer allocator.free(salt_amount_mol);
    var report: Report = .{ .transfers = 0, .maximum_fraction = 0 };

    for (0..state.cell_count) |cell| {
        for (0..state.layer_capacity -| 1) |layer| {
            const current = cell * state.layer_capacity + layer;
            const lower = current + 1;
            const density = state.snow_density_megagrams_per_m3[current];
            const lower_density = state.snow_density_megagrams_per_m3[lower];
            inline for (.{ density, lower_density, state.target_layer_volume_m3[current], solid[current], liquid[current], vapor[current], ice[current], temperature[current], temperature[lower], heat_capacity[current], heat_capacity[lower] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSnowRelayeringState;
            if (density <= 0 or lower_density <= 0 or state.target_layer_volume_m3[current] < 0 or solid[current] < 0 or liquid[current] < 0 or vapor[current] < 0 or ice[current] < 0 or temperature[current] <= 0 or temperature[lower] <= 0 or heat_capacity[current] < 0 or heat_capacity[lower] < 0) return error.InvalidSnowRelayeringState;
            const current_volume_m3 = solid[current] / density + liquid[current] + ice[current];
            const lower_volume_m3 = solid[lower] / lower_density + liquid[lower] + ice[lower];
            const volume_scale_m3 = @max(state.target_layer_volume_m3[current], @max(current_volume_m3, lower_volume_m3));
            const negligible_volume_m3 = tolerances.volume(volume_scale_m3);
            if (current_volume_m3 <= negligible_volume_m3) continue;
            const volume_deficit_m3 = state.target_layer_volume_m3[current] - current_volume_m3;
            var source: usize = undefined;
            var destination: usize = undefined;
            var fraction: f64 = 0;
            if (volume_deficit_m3 > negligible_volume_m3 and lower_volume_m3 > negligible_volume_m3) {
                source = lower;
                destination = current;
                fraction = @min(1, volume_deficit_m3 / lower_volume_m3);
            } else if (volume_deficit_m3 < -negligible_volume_m3 and current_volume_m3 >= state.target_layer_volume_m3[current]) {
                source = current;
                destination = lower;
                fraction = @min(1, -volume_deficit_m3 / current_volume_m3);
            } else continue;
            if (!std.math.isFinite(fraction) or fraction <= 0 or fraction > 1) return error.InvalidSnowRelayeringFraction;
            const retained = 1 - fraction;
            const source_energy_megajoules = heat_capacity[source] * temperature[source];
            const destination_energy_megajoules = heat_capacity[destination] * temperature[destination];
            if (accepted) |transfers| {
                const direction = if (source == current) &transfers.downward else &transfers.upward;
                try direction.addTransfer(
                    lower,
                    source,
                    fraction,
                    solid,
                    liquid,
                    vapor,
                    ice,
                    source_energy_megajoules,
                    amount_g,
                    salt_amount_mol,
                );
                transfers.touched_by_layer[source] = true;
                transfers.touched_by_layer[destination] = true;
            }
            solid[destination] += fraction * solid[source];
            liquid[destination] += fraction * liquid[source];
            vapor[destination] += fraction * vapor[source];
            ice[destination] += fraction * ice[source];
            solid[source] *= retained;
            liquid[source] *= retained;
            vapor[source] *= retained;
            ice[source] *= retained;
            heat_capacity[destination] = thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * solid[destination] + thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (liquid[destination] + vapor[destination]) + thermodynamics.ice_heat_capacity_megajoules_per_m3_k * ice[destination];
            heat_capacity[source] = thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * solid[source] + thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (liquid[source] + vapor[source]) + thermodynamics.ice_heat_capacity_megajoules_per_m3_k * ice[source];
            if (heat_capacity[destination] > tolerances.heatCapacity(heat_capacity[destination])) temperature[destination] = (destination_energy_megajoules + fraction * source_energy_megajoules) / heat_capacity[destination] else temperature[destination] = temperature[source];
            if (heat_capacity[source] > tolerances.heatCapacity(heat_capacity[source])) temperature[source] = retained * source_energy_megajoules / heat_capacity[source] else temperature[source] = temperature[destination];
            for (0..snow.species_count) |species| {
                const source_amount = source * snow.species_count + species;
                const destination_amount = destination * snow.species_count + species;
                amount_g[destination_amount] += fraction * amount_g[source_amount];
                amount_g[source_amount] *= retained;
            }
            for (0..snow.salt_species_count) |species| {
                const source_amount = source * snow.salt_species_count + species;
                const destination_amount = destination * snow.salt_species_count + species;
                salt_amount_mol[destination_amount] += fraction * salt_amount_mol[source_amount];
                salt_amount_mol[source_amount] *= retained;
            }
            report.transfers += 1;
            report.maximum_fraction = @max(report.maximum_fraction, fraction);
        }
    }
    inline for (.{ solid, liquid, vapor, ice, temperature, heat_capacity, amount_g, salt_amount_mol }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowRelayeringResult;
    @memcpy(state.solid_snow_water_equivalent_m3, solid);
    @memcpy(state.liquid_water_volume_m3, liquid);
    @memcpy(state.vapor_water_equivalent_m3, vapor);
    @memcpy(state.ice_volume_m3, ice);
    @memcpy(state.temperature_k, temperature);
    @memcpy(state.heat_capacity_megajoules_per_k, heat_capacity);
    @memcpy(state.amount_g, amount_g);
    @memcpy(state.salt_amount_mol, salt_amount_mol);
    for (state.active, solid, liquid, vapor, ice) |*active, solid_m3, liquid_m3, vapor_m3, ice_m3| {
        const total_volume_m3 = solid_m3 + liquid_m3 + vapor_m3 + ice_m3;
        active.* = total_volume_m3 > tolerances.volume(total_volume_m3);
    }
    state.refreshAllGeometry();
    return report;
}

fn validateAcceptedTransfers(transfers: *const AcceptedTransfers, layer_count: usize) !void {
    if (transfers.layer_count != layer_count or transfers.touched_by_layer.len != layer_count)
        return error.SnowRelayeringAcceptedTransferDimensionMismatch;
    inline for (.{ transfers.downward, transfers.upward }) |direction| {
        inline for (.{
            direction.solid_snow_water_equivalent_m3.len,
            direction.liquid_water_m3.len,
            direction.vapor_water_equivalent_m3.len,
            direction.ice_volume_m3.len,
            direction.sensible_heat_megajoules.len,
        }) |length| if (length != layer_count)
            return error.SnowRelayeringAcceptedTransferDimensionMismatch;
        if (direction.amount_g.len != try std.math.mul(usize, layer_count, snow.species_count) or
            direction.salt_amount_mol.len != try std.math.mul(usize, layer_count, snow.salt_species_count))
            return error.SnowRelayeringAcceptedTransferDimensionMismatch;
    }
}

fn checkedAdd(left: f64, right: f64) !f64 {
    const result = left + right;
    if (!std.math.isFinite(result) or result < 0) return error.InvalidSnowRelayeringAcceptedTransfer;
    return result;
}

test "runtime relayering conserves physical content solutes and energy" {
    var state = try snow.State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.12}, &.{1}, &.{268}, &.{ 0.05, 0.10, 0.20 }, 0.05, snow.test_thermodynamics);
    // Force the first layer above its runtime target and give all layers solute.
    state.solid_snow_water_equivalent_m3[0] += 0.003;
    state.amount_g[0] = 2;
    state.amount_g[snow.species_count] = 3;
    state.salt_amount_mol[0] = 0.2;
    state.salt_amount_mol[snow.salt_species_count] = 0.3;
    state.refreshAllGeometry();
    const solid_before = try std.testing.allocator.dupe(f64, state.solid_snow_water_equivalent_m3);
    defer std.testing.allocator.free(solid_before);
    const amount_before = try std.testing.allocator.dupe(f64, state.amount_g);
    defer std.testing.allocator.free(amount_before);
    const sensible_before = try std.testing.allocator.alloc(f64, state.active.len);
    defer std.testing.allocator.free(sensible_before);
    for (sensible_before, state.heat_capacity_megajoules_per_k, state.temperature_k) |*energy, capacity, temperature|
        energy.* = capacity * temperature;
    var water_before: f64 = 0;
    var energy_before: f64 = 0;
    for (state.solid_snow_water_equivalent_m3, state.liquid_water_volume_m3, state.vapor_water_equivalent_m3, state.ice_volume_m3, state.heat_capacity_megajoules_per_k, state.temperature_k) |solid_m3, liquid_m3, vapor_m3, ice_m3, capacity, temperature_k| {
        water_before += solid_m3 + liquid_m3 + vapor_m3 + ice_m3;
        energy_before += capacity * temperature_k;
    }
    var accepted = try AcceptedTransfers.init(std.testing.allocator, state.active.len);
    defer accepted.deinit();
    const report = try applyAccepted(std.testing.allocator, &state, snow.test_thermodynamics, .{
        .volume_absolute_m3 = 1e-15,
        .heat_capacity_absolute_megajoules_per_k = 2e-15,
        .relative = 1e-12,
    }, &accepted);
    var water_after: f64 = 0;
    var energy_after: f64 = 0;
    for (state.solid_snow_water_equivalent_m3, state.liquid_water_volume_m3, state.vapor_water_equivalent_m3, state.ice_volume_m3, state.heat_capacity_megajoules_per_k, state.temperature_k) |solid_m3, liquid_m3, vapor_m3, ice_m3, capacity, temperature_k| {
        water_after += solid_m3 + liquid_m3 + vapor_m3 + ice_m3;
        energy_after += capacity * temperature_k;
    }
    try std.testing.expect(report.transfers > 0);
    try std.testing.expectApproxEqAbs(water_before, water_after, 1e-14);
    try std.testing.expectApproxEqAbs(energy_before, energy_after, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5), state.amount_g[0] + state.amount_g[snow.species_count] + state.amount_g[2 * snow.species_count], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.salt_amount_mol[0] + state.salt_amount_mol[snow.salt_species_count] + state.salt_amount_mol[2 * snow.salt_species_count], 1e-14);
    for (0..state.layer_capacity) |layer| {
        const incoming_solid = accepted.downward.solid_snow_water_equivalent_m3[layer] +
            (if (layer + 1 < state.layer_capacity) accepted.upward.solid_snow_water_equivalent_m3[layer + 1] else 0);
        const outgoing_solid = accepted.upward.solid_snow_water_equivalent_m3[layer] +
            (if (layer + 1 < state.layer_capacity) accepted.downward.solid_snow_water_equivalent_m3[layer + 1] else 0);
        try std.testing.expectApproxEqAbs(
            solid_before[layer] + incoming_solid - outgoing_solid,
            state.solid_snow_water_equivalent_m3[layer],
            128 * std.math.floatEps(f64),
        );
        const species_index = layer * snow.species_count;
        const incoming_amount = accepted.downward.amount_g[species_index] +
            (if (layer + 1 < state.layer_capacity) accepted.upward.amount_g[(layer + 1) * snow.species_count] else 0);
        const outgoing_amount = accepted.upward.amount_g[species_index] +
            (if (layer + 1 < state.layer_capacity) accepted.downward.amount_g[(layer + 1) * snow.species_count] else 0);
        try std.testing.expectApproxEqAbs(
            amount_before[species_index] + incoming_amount - outgoing_amount,
            state.amount_g[species_index],
            128 * std.math.floatEps(f64),
        );
        const incoming_heat = accepted.downward.sensible_heat_megajoules[layer] +
            (if (layer + 1 < state.layer_capacity) accepted.upward.sensible_heat_megajoules[layer + 1] else 0);
        const outgoing_heat = accepted.upward.sensible_heat_megajoules[layer] +
            (if (layer + 1 < state.layer_capacity) accepted.downward.sensible_heat_megajoules[layer + 1] else 0);
        try std.testing.expectApproxEqAbs(
            sensible_before[layer] + incoming_heat - outgoing_heat,
            state.heat_capacity_megajoules_per_k[layer] * state.temperature_k[layer],
            512 * std.math.floatEps(f64) * @max(1, @abs(sensible_before[layer])),
        );
    }
}

test "accepted relayering records exact upward lower-to-upper donor fraction" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(
        &.{0.075},
        &.{1},
        &.{268},
        &.{ 0.05, 0.10 },
        0.05,
        snow.test_thermodynamics,
    );
    const upper_volume = state.total_layer_volume_m3[0];
    const lower_volume = state.total_layer_volume_m3[1];
    state.target_layer_volume_m3[0] = upper_volume + 0.5 * lower_volume;
    state.amount_g[snow.species_count + @intFromEnum(snow.Species.carbon_dioxide_carbon)] = 8;
    state.salt_amount_mol[snow.salt_species_count + @intFromEnum(snow.SaltSpecies.calcium_carbonate)] = 4;
    state.dynamic_salts_by_cell[0] = true;
    const lower_solid_before = state.solid_snow_water_equivalent_m3[1];
    const lower_energy_before = state.heat_capacity_megajoules_per_k[1] * state.temperature_k[1];
    var accepted = try AcceptedTransfers.init(std.testing.allocator, 2);
    defer accepted.deinit();
    const report = try applyAccepted(
        std.testing.allocator,
        &state,
        snow.test_thermodynamics,
        .{
            .volume_absolute_m3 = 1e-15,
            .heat_capacity_absolute_megajoules_per_k = 2e-15,
            .relative = 1e-12,
        },
        &accepted,
    );
    try std.testing.expectEqual(@as(usize, 1), report.transfers);
    try std.testing.expect(accepted.touched_by_layer[0] and accepted.touched_by_layer[1]);
    try std.testing.expectApproxEqAbs(
        0.5 * lower_solid_before,
        accepted.upward.solid_snow_water_equivalent_m3[1],
        64 * std.math.floatEps(f64),
    );
    try std.testing.expectApproxEqAbs(
        0.5 * lower_energy_before,
        accepted.upward.sensible_heat_megajoules[1],
        128 * std.math.floatEps(f64) * @max(1, lower_energy_before),
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4), accepted.upward.amount_g[snow.species_count], 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 2), accepted.upward.salt_amount_mol[snow.salt_species_count + @intFromEnum(snow.SaltSpecies.calcium_carbonate)], 64 * std.math.floatEps(f64));
    try std.testing.expectEqual(@as(f64, 0), accepted.downward.solid_snow_water_equivalent_m3[1]);
    try std.testing.expectApproxEqAbs(
        lower_solid_before - accepted.upward.solid_snow_water_equivalent_m3[1],
        state.solid_snow_water_equivalent_m3[1],
        64 * std.math.floatEps(f64),
    );
}

test "rejected relayering clears accepted sidecar and leaves state unchanged" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(
        &.{0.075},
        &.{1},
        &.{268},
        &.{ 0.05, 0.10 },
        0.05,
        snow.test_thermodynamics,
    );
    state.solid_snow_water_equivalent_m3[0] += 0.001;
    state.amount_g[0] = std.math.floatMax(f64);
    state.amount_g[snow.species_count] = std.math.floatMax(f64);
    state.refreshAllGeometry();
    const solid_before = state.solid_snow_water_equivalent_m3[0];
    const amount_before = state.amount_g[snow.species_count];
    var accepted = try AcceptedTransfers.init(std.testing.allocator, 2);
    defer accepted.deinit();
    try std.testing.expectError(
        error.InvalidSnowRelayeringResult,
        applyAccepted(
            std.testing.allocator,
            &state,
            snow.test_thermodynamics,
            .{
                .volume_absolute_m3 = 1e-15,
                .heat_capacity_absolute_megajoules_per_k = 2e-15,
                .relative = 1e-12,
            },
            &accepted,
        ),
    );
    try std.testing.expectEqual(solid_before, state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expectEqual(amount_before, state.amount_g[snow.species_count]);
    try std.testing.expect(!accepted.touched_by_layer[0] and !accepted.touched_by_layer[1]);
    try std.testing.expectEqual(@as(f64, 0), accepted.downward.solid_snow_water_equivalent_m3[1]);
    try std.testing.expectEqual(@as(f64, 0), accepted.downward.amount_g[snow.species_count]);
}

test "hourly accepted relayering sidecar addition is atomic on invalid increment" {
    var total = try AcceptedTransfers.init(std.testing.allocator, 2);
    defer total.deinit();
    var increment = try AcceptedTransfers.init(std.testing.allocator, 2);
    defer increment.deinit();
    total.downward.solid_snow_water_equivalent_m3[1] = 1;
    total.touched_by_layer[0] = true;
    increment.downward.solid_snow_water_equivalent_m3[1] = 2;
    increment.downward.liquid_water_m3[1] = std.math.inf(f64);
    increment.touched_by_layer[1] = true;
    try std.testing.expectError(
        error.InvalidSnowRelayeringAcceptedTransfer,
        total.add(increment),
    );
    try std.testing.expectEqual(@as(f64, 1), total.downward.solid_snow_water_equivalent_m3[1]);
    try std.testing.expectEqual(@as(f64, 0), total.downward.liquid_water_m3[1]);
    try std.testing.expect(total.touched_by_layer[0]);
    try std.testing.expect(!total.touched_by_layer[1]);
}

test "snow relayering keeps volume and heat-capacity thresholds distinct" {
    const tolerances: Tolerances = .{
        .volume_absolute_m3 = 1e-14,
        .heat_capacity_absolute_megajoules_per_k = 1e-10,
        .relative = 1e-12,
    };
    try tolerances.validate();
    try std.testing.expect(tolerances.volume(2) != tolerances.heatCapacity(2));
    try std.testing.expectApproxEqAbs(@as(f64, 2.01e-12), tolerances.volume(2), 1e-25);
    try std.testing.expectApproxEqAbs(@as(f64, 1.02e-10), tolerances.heatCapacity(2), 1e-23);
}

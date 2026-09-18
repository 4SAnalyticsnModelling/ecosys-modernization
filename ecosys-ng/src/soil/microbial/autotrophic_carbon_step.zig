const std = @import("std");
const compute = @import("../../core/compute.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const oxygen = @import("../gas/oxygen_allocation.zig");
const nitrification = @import("nitrification_step.zig");
const parameters_module = @import("../nutrients/nitrogen_parameters.zig");
const gas = @import("../gas/transport.zig");
const microbial = @import("state.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    process_unit_count_per_layer: usize,
    carbon_dioxide_uptake_g_c: []f64,
    respiratory_carbon_dioxide_g_c: []f64,
    nonstructural_carbon_gain_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize, process_unit_count_per_layer: usize) !State {
        if (layer_count == 0 or process_unit_count_per_layer == 0) return error.InvalidAutotrophicCarbonDimensions;
        const n = try std.math.mul(usize, layer_count, process_unit_count_per_layer);
        const uptake = try allocator.alloc(f64, n);
        errdefer allocator.free(uptake);
        const respiration = try allocator.alloc(f64, n);
        errdefer allocator.free(respiration);
        const gain = try allocator.alloc(f64, n);
        @memset(uptake, 0);
        @memset(respiration, 0);
        @memset(gain, 0);
        return .{ .allocator = allocator, .layer_count = layer_count, .process_unit_count_per_layer = process_unit_count_per_layer, .carbon_dioxide_uptake_g_c = uptake, .respiratory_carbon_dioxide_g_c = respiration, .nonstructural_carbon_gain_g_c = gain };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.nonstructural_carbon_gain_g_c);
        self.allocator.free(self.respiratory_carbon_dioxide_g_c);
        self.allocator.free(self.carbon_dioxide_uptake_g_c);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    flux_workspace: *const fluxes.State,
    oxygen_state: *const oxygen.State,
    roles: []const nitrification.Role,
    redox_satisfaction_fraction: []const f64,
    parameters: parameters_module.Parameters,
};

/// NITRO `RGOMT/RGOMD/CGOMX/CGOMD/CGOMC/CGROMC` for autotrophic
/// NH3 and NO2 oxidizers after the shared oxygen/redox solves.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const p = context.parameters.nitrification;
    const anaerobic_efficiency = context.parameters.autotrophic_denitrification.anaerobic_growth_respiration_fraction;
    const units_per_layer = context.result.process_unit_count_per_layer;
    for (range.first..range.end) |layer| {
        const first = layer * units_per_layer;
        for (first..first + units_per_layer) |unit| {
            context.result.carbon_dioxide_uptake_g_c[unit] = 0;
            context.result.respiratory_carbon_dioxide_g_c[unit] = 0;
            context.result.nonstructural_carbon_gain_g_c[unit] = 0;
            const role = context.roles[unit];
            if (role == .inactive) continue;
            const oxygen_fraction = context.oxygen_state.demand_satisfaction_fraction[unit];
            const oxidation_g_n = switch (role) {
                .ammonia_oxidizer => context.flux_workspace.non_band_ammonia_oxidation_potential_g_n[unit] + context.flux_workspace.band_ammonia_oxidation_potential_g_n[unit],
                .nitrite_oxidizer => context.flux_workspace.non_band_nitrite_oxidation_potential_g_n[unit] + context.flux_workspace.band_nitrite_oxidation_potential_g_n[unit],
                .inactive => unreachable,
            } * oxygen_fraction;
            const carbon_efficiency = switch (role) {
                .ammonia_oxidizer => p.ammonia_oxidizer_carbon_efficiency_g_c_per_g_n,
                .nitrite_oxidizer => p.nitrite_oxidizer_carbon_efficiency_g_c_per_g_n,
                .inactive => unreachable,
            };
            const aerobic_respiration = oxidation_g_n * carbon_efficiency * p.growth_respiration_fraction;
            const maintenance = context.flux_workspace.total_maintenance_respiration_g_c[unit];
            const aerobic_growth_respiration = @max(0, aerobic_respiration - maintenance);
            const aerobic_uptake = @min(maintenance, aerobic_respiration) + if (p.growth_respiration_fraction > 0) aerobic_growth_respiration / p.growth_respiration_fraction else 0;
            const denitrification_respiration = context.flux_workspace.denitrification_respiration_g_c[unit] * context.redox_satisfaction_fraction[unit];
            const denitrification_uptake = if (anaerobic_efficiency > 0) denitrification_respiration / anaerobic_efficiency else 0;
            const respiration = aerobic_respiration + denitrification_respiration;
            const uptake = aerobic_uptake + denitrification_uptake;
            const gain = uptake - respiration;
            inline for (.{ oxidation_g_n, aerobic_respiration, maintenance, aerobic_uptake, denitrification_respiration, denitrification_uptake, respiration, uptake, gain }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteAutotrophicCarbonFlux;
            context.result.carbon_dioxide_uptake_g_c[unit] = uptake;
            context.result.respiratory_carbon_dioxide_g_c[unit] = respiration;
            context.result.nonstructural_carbon_gain_g_c[unit] = gain;
        }
    }
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const n = try std.math.mul(usize, context.result.layer_count, context.result.process_unit_count_per_layer);
    if (range.first > range.end or range.end > context.result.layer_count or context.flux_workspace.layer_count != context.result.layer_count or context.flux_workspace.process_unit_count_per_layer != context.result.process_unit_count_per_layer or context.roles.len != n or context.oxygen_state.demand_satisfaction_fraction.len != n or context.redox_satisfaction_fraction.len != n) return error.InvalidAutotrophicCarbonDimensions;
    for (context.redox_satisfaction_fraction) |fraction| if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.NonFiniteAutotrophicCarbonFlux;
    try parameters_module.validate(context.parameters);
}

pub const StateUpdateContext = struct {
    state: *const State,
    gas_state: *gas.State,
    microbial_state: *microbial.State,
    autotrophic_substrate_index: usize,
    absolute_tolerance_g_c: f64,
    relative_tolerance: f64,
};

const LayerTransfer = struct {
    co2_index: usize,
    donor_before_g_c: f64,
    requested_g_c: f64,
    accepted_g_c: f64,
    recipient_scale: f64,
};

/// Publishes the already validated `CGROMC` transfer. Each layer is checked
/// completely before either CO2 or microbial storage is modified. This is
/// also the live nitrifier CO2 debit. The former unread NITRO aggregation
/// shadow was removed; `biogeochemical_gas_aggregation.zig` remains only a
/// pure reference-equation oracle.
pub fn state_updateTile(context: *StateUpdateContext, range: compute.CellRange) !void {
    const flattened_layers = std.math.mul(usize, context.microbial_state.cell_count, context.microbial_state.layer_count) catch return error.InvalidAutotrophicCarbonStateUpdate;
    const units_per_layer = std.math.mul(usize, context.microbial_state.substrate_count, context.microbial_state.population_count) catch return error.InvalidAutotrophicCarbonStateUpdate;
    if (range.first > range.end or range.end > context.state.layer_count or context.gas_state.cell_count != context.state.layer_count or flattened_layers != context.state.layer_count or units_per_layer != context.state.process_unit_count_per_layer or context.autotrophic_substrate_index >= context.microbial_state.substrate_count or !std.math.isFinite(context.absolute_tolerance_g_c) or context.absolute_tolerance_g_c < 0 or !std.math.isFinite(context.relative_tolerance) or context.relative_tolerance <= 0 or context.relative_tolerance >= 1) return error.InvalidAutotrophicCarbonStateUpdate;

    // Preflight the complete tile. A bad later layer must not leave an earlier
    // layer debited or credited when the caller retries a substep.
    for (range.first..range.end) |layer| _ = try prepareLayerTransfer(context.*, layer);

    const populations = context.microbial_state.population_count;
    for (range.first..range.end) |layer| {
        const transfer = try prepareLayerTransfer(context.*, layer);
        const first = layer * context.state.process_unit_count_per_layer;
        var accepted_so_far_g_c: f64 = 0;
        for (0..populations) |population| {
            const unit = first + context.autotrophic_substrate_index * populations + population;
            const requested = context.state.nonstructural_carbon_gain_g_c[unit];
            const gain = if (population + 1 == populations)
                transfer.accepted_g_c - accepted_so_far_g_c
            else
                requested * transfer.recipient_scale;
            if (gain == 0) continue;
            context.microbial_state.nonstructural[unit].carbon_g_c += gain;
            accepted_so_far_g_c += gain;
        }
        context.gas_state.dissolved_mass_g[transfer.co2_index] = transfer.donor_before_g_c - transfer.accepted_g_c;
    }
}

fn prepareLayerTransfer(context: StateUpdateContext, layer: usize) !LayerTransfer {
    const populations = context.microbial_state.population_count;
    const first = layer * context.state.process_unit_count_per_layer;
    const co2_index = try gas.massIndex(layer, .carbon_dioxide, context.gas_state.cell_count);
    const donor = context.gas_state.dissolved_mass_g[co2_index];
    if (!std.math.isFinite(donor) or donor < 0) return error.InvalidAutotrophicCarbonStateUpdate;

    var requested: f64 = 0;
    for (0..populations) |population| {
        const unit = first + context.autotrophic_substrate_index * populations + population;
        const gain = context.state.nonstructural_carbon_gain_g_c[unit];
        const recipient = context.microbial_state.nonstructural[unit].carbon_g_c;
        if (!std.math.isFinite(gain) or gain < 0 or !std.math.isFinite(recipient) or recipient < 0) return error.InvalidAutotrophicCarbonStateUpdate;
        requested += gain;
        if (!std.math.isFinite(requested)) return error.InvalidAutotrophicCarbonStateUpdate;
    }

    const scale_g_c = @max(donor, requested);
    const relative_g_c = context.relative_tolerance * scale_g_c;
    const roundoff_g_c = 64.0 * std.math.floatEps(f64) * scale_g_c;
    const scaled_g_c = @max(relative_g_c, roundoff_g_c);
    const admissibility_g_c = @min(context.absolute_tolerance_g_c, scaled_g_c) + scaled_g_c;
    if (!std.math.isFinite(admissibility_g_c) or requested > donor + admissibility_g_c) return error.InsufficientAutotrophicCarbonDioxide;

    // A request above its donor only by scaled numerical noise is projected
    // over every recipient. This prevents both carbon creation and ordering
    // bias while retaining the requested population split.
    const accepted = @min(requested, donor);
    const recipient_scale = if (requested > donor and requested > 0) donor / requested else 1;
    var accepted_so_far: f64 = 0;
    for (0..populations) |population| {
        const unit = first + context.autotrophic_substrate_index * populations + population;
        const gain = if (population + 1 == populations)
            accepted - accepted_so_far
        else
            context.state.nonstructural_carbon_gain_g_c[unit] * recipient_scale;
        const next = context.microbial_state.nonstructural[unit].carbon_g_c + gain;
        if (!std.math.isFinite(gain) or gain < 0 or !std.math.isFinite(next) or next < 0) return error.InvalidAutotrophicCarbonStateUpdate;
        accepted_so_far += gain;
    }
    return .{ .co2_index = co2_index, .donor_before_g_c = donor, .requested_g_c = requested, .accepted_g_c = accepted, .recipient_scale = recipient_scale };
}

test "oxygen-limited nitrifier carbon uptake preserves NITRO maintenance-growth split" {
    var flux = try fluxes.State.init(std.testing.allocator, 1, 1);
    defer flux.deinit();
    flux.non_band_ammonia_oxidation_potential_g_n[0] = 2;
    flux.total_maintenance_respiration_g_c[0] = 0.1;
    var oxygen_state = try oxygen.State.init(std.testing.allocator, 1, 1, 1);
    defer oxygen_state.deinit();
    oxygen_state.demand_satisfaction_fraction[0] = 0.5;
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    const parameters = try parameters_module.parse(
        "soil_nitrification 0.001 0.0002 7000 14 1.4 1.4 0.125 0.125 0.3 0.1 0.5 2.667 3.429 1.143\n" ++
            "soil_denitrification 0.001 1.4 1.4 0.014 1 0.429 0.429 0.214 0.875\nsoil_autotrophic_denitrification 0.5 0.333\nsoil_chemodenitrification 0.0005 0.001 1e-12 0.5 0 0.5\nnitrous_acid_dissociation_mol_per_m3 0.45\nsoil_microbial_thermal_adaptation_offset_k 0\nsoil_nitrifier_indices 0 0 1 1\nsoil_nitrifier_environment 0.55 0.1 0.1 0.01 0.01 12 0.1\nsoil_oxygen_uptake 1e-6 2.3866348449e11 0.064 -1.5e4 0.5 12 12 0.5 0.7 0.001 1e-12\nsoil_heterotrophic_respiration 0.125 0.1 0.01 12 12 0.5 0.42016806722689076 0.1 2.667 0.01 0.01 1e-6 1 0.7142857142857143\nsoil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\nsoil_nonsymbiotic_nitrogen_fixation 0 1 0.25 0.02 0.14 0.25\nsoil_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.150 0.300 0.333 0.25 2.0 5.0 1.0 0.5 0.182e-6",
    );
    var redox = [1]f64{0};
    var context: ApplyContext = .{ .result = &state, .flux_workspace = &flux, .oxygen_state = &oxygen_state, .roles = &.{.ammonia_oxidizer}, .redox_satisfaction_fraction = &redox, .parameters = parameters };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    // RGOMO=1*0.3*0.5=0.15; RGOMT=0.05; CGOMX=0.1+0.05/0.5=0.2.
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), state.carbon_dioxide_uptake_g_c[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), state.nonstructural_carbon_gain_g_c[0], 1e-15);
    // Source CGOMD=RGOMD/ENOX. A 0.04 potential at redox=0.25 gives
    // RGOMD=0.01, CGOMD=0.02, and an additional retained 0.01 g C.
    flux.denitrification_respiration_g_c[0] = 0.04;
    redox[0] = 0.25;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.22), state.carbon_dioxide_uptake_g_c[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.16), state.respiratory_carbon_dioxide_g_c[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), state.nonstructural_carbon_gain_g_c[0], 1e-15);
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = 1;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer microbial_state.deinit();
    const carbon_before = gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] + microbial_state.nonstructural[0].carbon_g_c;
    var state_update_context: StateUpdateContext = .{ .state = &state, .gas_state = &gas_state, .microbial_state = &microbial_state, .autotrophic_substrate_index = 0, .absolute_tolerance_g_c = 1e-12, .relative_tolerance = 1e-10 };
    try state_updateTile(&state_update_context, .{ .first = 0, .end = 1 });
    const carbon_after = gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] + microbial_state.nonstructural[0].carbon_g_c;
    try std.testing.expectApproxEqAbs(carbon_before, carbon_after, 1e-15);
}

test "autotrophic carbon roundoff projection cannot create recipient carbon" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.nonstructural_carbon_gain_g_c[0] = 0.4;
    state.nonstructural_carbon_gain_g_c[1] = 0.6000000005;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = 1;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 2);
    defer microbial_state.deinit();
    var context: StateUpdateContext = .{ .state = &state, .gas_state = &gas_state, .microbial_state = &microbial_state, .autotrophic_substrate_index = 0, .absolute_tolerance_g_c = 1e-6, .relative_tolerance = 1e-9 };

    try state_updateTile(&context, .{ .first = 0, .end = 1 });

    const recipient_total = microbial_state.nonstructural[0].carbon_g_c + microbial_state.nonstructural[1].carbon_g_c;
    try std.testing.expectEqual(@as(f64, 0), gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)]);
    try std.testing.expectApproxEqAbs(@as(f64, 1), recipient_total, 8.0 * std.math.floatEps(f64));
}

test "autotrophic carbon deficit rejects the complete tile atomically" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    state.nonstructural_carbon_gain_g_c[0] = 0.2;
    state.nonstructural_carbon_gain_g_c[1] = 0.2;
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = 1;
    gas_state.dissolved_mass_g[gas.species_count + @intFromEnum(gas.Species.carbon_dioxide)] = 0.1;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 2, 1, 1);
    defer microbial_state.deinit();
    var context: StateUpdateContext = .{ .state = &state, .gas_state = &gas_state, .microbial_state = &microbial_state, .autotrophic_substrate_index = 0, .absolute_tolerance_g_c = 1e-6, .relative_tolerance = 1e-9 };

    try std.testing.expectError(error.InsufficientAutotrophicCarbonDioxide, state_updateTile(&context, .{ .first = 0, .end = 2 }));
    try std.testing.expectEqual(@as(f64, 1), gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)]);
    try std.testing.expectEqual(@as(f64, 0.1), gas_state.dissolved_mass_g[gas.species_count + @intFromEnum(gas.Species.carbon_dioxide)]);
    try std.testing.expectEqual(@as(f64, 0), microbial_state.nonstructural[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), microbial_state.nonstructural[1].carbon_g_c);
}

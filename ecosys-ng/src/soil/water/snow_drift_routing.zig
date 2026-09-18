const std = @import("std");
const snow = @import("../solute/snow_solute_transport.zig");
const routing = @import("../solute/surface_solute_routing.zig");
const surface_aqueous = @import("../../surface/aqueous_runoff_transport.zig");
const solute_species = @import("../solute/transport_species.zig");
const cell_conservation = @import("../../validation/hourly_cell_conservation.zig");
const landscape_boundary = @import("../../validation/landscape_boundary_balance.zig");
const ice_units = @import("../../core/ice_units.zig");

pub const DownhillDirections = struct {
    east: []const bool,
    west: []const bool,
    south: []const bool,
    north: []const bool,
};

pub const AcceptedFluxes = struct {
    source_carrier_m3: []f64,
    total_m3: []f64,
    east_m3: []f64,
    west_m3: []f64,
    south_m3: []f64,
    north_m3: []f64,
};

pub const PhysicalInputs = struct {
    ground_surface_elevation_m: []const f64,
    wind_speed_m_per_h: []const f64,
    east_west_fraction: []const f64,
    north_south_fraction: []const f64,
    downhill: DownhillDirections,
    boundaries: routing.BoundaryConditions,
    timestep_h: f64,
    thermodynamics: snow.ThermodynamicParameters,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    elevation_absolute_tolerance_m: f64,
    relative_tolerance: f64,
    ion_molar_mass_g_per_mol: @import("snow_surface_discharge.zig").IonMolarMassesGPerMol,
    accepted_fluxes: AcceptedFluxes,
    /// Accepted-substep schedules accumulate physical movement across their
    /// component steps while publishing the latest source carrier image.
    accumulate_accepted_fluxes: bool = false,
    cell_boundary_ledger: *cell_conservation.BoundaryLedger,
    landscape_boundary_ledger: *landscape_boundary.State,
};

pub const PhysicalResult = struct {
    internal_direction_count: usize = 0,
    open_boundary_direction_count: usize = 0,
    boundary_solid_snow_water_equivalent_m3: f64 = 0,
    boundary_liquid_water_m3: f64 = 0,
    boundary_ice_volume_m3: f64 = 0,
    boundary_water_equivalent_m3: f64 = 0,
    boundary_heat_megajoules: f64 = 0,
};

const Direction = enum { east, south, west, north };
const direction_order = [_]Direction{ .east, .south, .west, .north };

const ConservedTransfer = struct {
    activity: cell_conservation.IntercellTransfer,
    /// REDIST SSS/SSH pseudo-ion count: every non-oxygen formula atom.
    legacy_ion_mol: f64,
};

const PhysicalCandidateWorkspace = struct {
    allocator: std.mem.Allocator,
    core_allocation_count: u8 = 0,
    solid: []f64 = undefined,
    liquid: []f64 = undefined,
    ice: []f64 = undefined,
    energy: []f64 = undefined,
    heat_capacity: []f64 = undefined,
    temperature: []f64 = undefined,
    amount: []f64 = undefined,
    salt: []f64 = undefined,
    active: []bool = undefined,
    cell_activity: []cell_conservation.BoundaryActivity = undefined,
    accepted_fluxes: [6][]f64 = undefined,
    accepted_flux_count: u8 = 0,
    ledger_cells: []cell_conservation.BoundaryActivity = undefined,
    ledger_cells_allocated: bool = false,

    noinline fn init(
        allocator: std.mem.Allocator,
        state: *const snow.State,
        cells: usize,
        accepted_destinations: [6][]f64,
        accumulate_accepted_fluxes: bool,
    ) !PhysicalCandidateWorkspace {
        var workspace: PhysicalCandidateWorkspace = .{ .allocator = allocator };
        errdefer workspace.deinit();
        workspace.solid = try allocator.dupe(f64, state.solid_snow_water_equivalent_m3);
        workspace.core_allocation_count = 1;
        workspace.liquid = try allocator.dupe(f64, state.liquid_water_volume_m3);
        workspace.core_allocation_count = 2;
        workspace.ice = try allocator.dupe(f64, state.ice_volume_m3);
        workspace.core_allocation_count = 3;
        workspace.energy = try allocator.alloc(f64, state.heat_capacity_megajoules_per_k.len);
        workspace.core_allocation_count = 4;
        workspace.heat_capacity = try allocator.dupe(f64, state.heat_capacity_megajoules_per_k);
        workspace.core_allocation_count = 5;
        workspace.temperature = try allocator.dupe(f64, state.temperature_k);
        workspace.core_allocation_count = 6;
        workspace.amount = try allocator.dupe(f64, state.amount_g);
        workspace.core_allocation_count = 7;
        workspace.salt = try allocator.dupe(f64, state.salt_amount_mol);
        workspace.core_allocation_count = 8;
        workspace.active = try allocator.dupe(bool, state.active);
        workspace.core_allocation_count = 9;
        workspace.cell_activity = try allocator.alloc(cell_conservation.BoundaryActivity, cells);
        workspace.core_allocation_count = 10;
        @memset(workspace.cell_activity, .{});
        for (&workspace.accepted_fluxes, accepted_destinations, 0..) |*values, destination, index| {
            values.* = try allocator.alloc(f64, cells);
            if (accumulate_accepted_fluxes and index > 0)
                @memcpy(values.*, destination)
            else
                @memset(values.*, 0);
            workspace.accepted_flux_count += 1;
        }
        return workspace;
    }

    noinline fn allocateLedgerCells(
        workspace: *PhysicalCandidateWorkspace,
        source: []const cell_conservation.BoundaryActivity,
    ) !void {
        std.debug.assert(!workspace.ledger_cells_allocated);
        workspace.ledger_cells = try workspace.allocator.dupe(cell_conservation.BoundaryActivity, source);
        workspace.ledger_cells_allocated = true;
    }

    fn deinit(workspace: *PhysicalCandidateWorkspace) void {
        if (workspace.ledger_cells_allocated) workspace.allocator.free(workspace.ledger_cells);
        while (workspace.accepted_flux_count > 0) {
            workspace.accepted_flux_count -= 1;
            workspace.allocator.free(workspace.accepted_fluxes[workspace.accepted_flux_count]);
        }
        if (workspace.core_allocation_count >= 10) workspace.allocator.free(workspace.cell_activity);
        if (workspace.core_allocation_count >= 9) workspace.allocator.free(workspace.active);
        if (workspace.core_allocation_count >= 8) workspace.allocator.free(workspace.salt);
        if (workspace.core_allocation_count >= 7) workspace.allocator.free(workspace.amount);
        if (workspace.core_allocation_count >= 6) workspace.allocator.free(workspace.temperature);
        if (workspace.core_allocation_count >= 5) workspace.allocator.free(workspace.heat_capacity);
        if (workspace.core_allocation_count >= 4) workspace.allocator.free(workspace.energy);
        if (workspace.core_allocation_count >= 3) workspace.allocator.free(workspace.ice);
        if (workspace.core_allocation_count >= 2) workspace.allocator.free(workspace.liquid);
        if (workspace.core_allocation_count >= 1) workspace.allocator.free(workspace.solid);
        workspace.* = undefined;
    }
};

/// WATSUB 3876--4100 physical wind-drift producer and topology transaction.
/// `QSX=1e-7*UA*dt`; each eligible lower neighbor receives its source-order
/// FSLOPE share of top-layer snow, liquid water, ice, sensible heat and every
/// represented solute. All candidates and both conservation ledgers are
/// staged before any authoritative owner changes.
pub fn produceAndRoute(
    allocator: std.mem.Allocator,
    state: *snow.State,
    columns: usize,
    rows: usize,
    inputs: PhysicalInputs,
) !PhysicalResult {
    const cells = try std.math.mul(usize, columns, rows);
    if (cells != state.cell_count or inputs.cell_boundary_ledger.cells.len != cells)
        return error.SnowDriftDimensionMismatch;
    inline for (.{
        inputs.ground_surface_elevation_m.len,
        inputs.wind_speed_m_per_h.len,
        inputs.east_west_fraction.len,
        inputs.north_south_fraction.len,
        inputs.downhill.east.len,
        inputs.downhill.west.len,
        inputs.downhill.south.len,
        inputs.downhill.north.len,
        inputs.boundaries.east_open.len,
        inputs.boundaries.west_open.len,
        inputs.boundaries.south_open.len,
        inputs.boundaries.north_open.len,
        inputs.accepted_fluxes.source_carrier_m3.len,
        inputs.accepted_fluxes.total_m3.len,
        inputs.accepted_fluxes.east_m3.len,
        inputs.accepted_fluxes.west_m3.len,
        inputs.accepted_fluxes.south_m3.len,
        inputs.accepted_fluxes.north_m3.len,
    }) |length| if (length != cells) return error.SnowDriftDimensionMismatch;
    inline for (@typeInfo(snow.ThermodynamicParameters).@"struct".fields) |field| {
        const value = @field(inputs.thermodynamics, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidSnowDriftInput;
    }
    inline for (.{
        inputs.timestep_h,
        inputs.ice_density_megagrams_per_m3,
        inputs.latent_heat_of_fusion_megajoules_per_m3,
        inputs.elevation_absolute_tolerance_m,
        inputs.relative_tolerance,
    }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSnowDriftInput;
    if (inputs.ice_density_megagrams_per_m3 > 1) return error.InvalidSnowDriftInput;
    inline for (@typeInfo(@TypeOf(inputs.ion_molar_mass_g_per_mol)).@"struct".fields) |field| {
        const value = @field(inputs.ion_molar_mass_g_per_mol, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidSnowDriftInput;
    }

    const accepted_destinations = [_][]f64{
        inputs.accepted_fluxes.source_carrier_m3,
        inputs.accepted_fluxes.total_m3,
        inputs.accepted_fluxes.east_m3,
        inputs.accepted_fluxes.west_m3,
        inputs.accepted_fluxes.south_m3,
        inputs.accepted_fluxes.north_m3,
    };
    var candidate_workspace = try PhysicalCandidateWorkspace.init(
        allocator,
        state,
        cells,
        accepted_destinations,
        inputs.accumulate_accepted_fluxes,
    );
    defer candidate_workspace.deinit();
    const solid_candidate = candidate_workspace.solid;
    const liquid_candidate = candidate_workspace.liquid;
    const ice_candidate = candidate_workspace.ice;
    const energy_candidate = candidate_workspace.energy;
    const heat_capacity_candidate = candidate_workspace.heat_capacity;
    const temperature_candidate = candidate_workspace.temperature;
    const amount_candidate = candidate_workspace.amount;
    const salt_candidate = candidate_workspace.salt;
    const active_candidate = candidate_workspace.active;
    const cell_activity_delta = candidate_workspace.cell_activity;
    const accepted_flux_candidates = candidate_workspace.accepted_fluxes;

    for (state.heat_capacity_megajoules_per_k, state.temperature_k, energy_candidate) |capacity, temperature, *energy| {
        if (!std.math.isFinite(capacity) or capacity < 0 or !std.math.isFinite(temperature) or temperature <= 0)
            return error.InvalidSnowDriftState;
        energy.* = capacity * temperature;
        if (!std.math.isFinite(energy.*)) return error.InvalidSnowDriftState;
    }
    for (state.solid_snow_water_equivalent_m3, state.liquid_water_volume_m3, state.vapor_water_equivalent_m3, state.ice_volume_m3) |solid, liquid, vapor, ice| {
        inline for (.{ solid, liquid, vapor, ice }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDriftState;
    }
    for (state.amount_g) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDriftState;
    for (state.salt_amount_mol) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDriftState;

    var result: PhysicalResult = .{};
    var external_transfer: cell_conservation.IntercellTransfer = .{};
    var external_legacy_ion_mol: f64 = 0;
    for (0..cells) |cell| {
        const wind = inputs.wind_speed_m_per_h[cell];
        const ground = inputs.ground_surface_elevation_m[cell];
        const ew = inputs.east_west_fraction[cell];
        const ns = inputs.north_south_fraction[cell];
        inline for (.{ wind, ground, ew, ns }) |value|
            if (!std.math.isFinite(value)) return error.InvalidSnowDriftInput;
        if (wind < 0 or ew < 0 or ew > 1 or ns < 0 or ns > 1)
            return error.InvalidSnowDriftInput;
        const slope_sum = ew + ns;
        const slope_tolerance = inputs.relative_tolerance * @max(1, @abs(slope_sum));
        if (@abs(slope_sum - 1) > slope_tolerance) return error.InvalidSnowDriftSlopePartition;
        const top = try state.layerIndex(cell, 0);
        const depth = state.cumulative_depth_m[(cell + 1) * state.layer_capacity - 1];
        if (!std.math.isFinite(depth) or depth < 0) return error.InvalidSnowDriftState;
        const carrier = state.solid_snow_water_equivalent_m3[top] +
            state.liquid_water_volume_m3[top] + state.ice_volume_m3[top];
        if (!std.math.isFinite(carrier) or carrier < 0) return error.InvalidSnowDriftState;
        accepted_flux_candidates[0][cell] = carrier;
        if (depth == 0 or carrier == 0 or wind == 0) continue;

        const q_sx = 1.0e-7 * wind * inputs.timestep_h;
        if (!std.math.isFinite(q_sx) or q_sx < 0) return error.InvalidSnowDriftInput;
        const source_surface = ground + depth;
        if (!std.math.isFinite(source_surface)) return error.InvalidSnowDriftInput;
        var total_fraction: f64 = 0;
        for (direction_order) |direction| {
            if (!eligibleDirection(state, columns, rows, cell, source_surface, direction, inputs)) continue;
            total_fraction += q_sx * axisFraction(direction, ew, ns);
        }
        if (!std.math.isFinite(total_fraction) or total_fraction < 0) return error.InvalidSnowDriftInput;
        if (total_fraction > 1) return error.SnowDriftExceedsDonorInventory;
        if (total_fraction == 0) continue;

        const transferred_capacity_total = phaseCapacity(
            state.solid_snow_water_equivalent_m3[top] * total_fraction,
            state.liquid_water_volume_m3[top] * total_fraction,
            state.ice_volume_m3[top] * total_fraction,
            inputs.thermodynamics,
        );
        solid_candidate[top] -= state.solid_snow_water_equivalent_m3[top] * total_fraction;
        liquid_candidate[top] -= state.liquid_water_volume_m3[top] * total_fraction;
        ice_candidate[top] -= state.ice_volume_m3[top] * total_fraction;
        energy_candidate[top] -= transferred_capacity_total * state.temperature_k[top];
        for (0..snow.species_count) |species| {
            const component = top * snow.species_count + species;
            amount_candidate[component] -= state.amount_g[component] * total_fraction;
        }
        for (0..snow.salt_species_count) |species| {
            const component = top * snow.salt_species_count + species;
            salt_candidate[component] -= state.salt_amount_mol[component] * total_fraction;
        }

        for (direction_order) |direction| {
            if (!eligibleDirection(state, columns, rows, cell, source_surface, direction, inputs)) continue;
            const fraction = q_sx * axisFraction(direction, ew, ns);
            if (fraction == 0) continue;
            const solid = state.solid_snow_water_equivalent_m3[top] * fraction;
            const liquid = state.liquid_water_volume_m3[top] * fraction;
            const ice = state.ice_volume_m3[top] * fraction;
            const transfer_carrier = solid + liquid + ice;
            accepted_flux_candidates[1][cell] += transfer_carrier;
            accepted_flux_candidates[directionFluxIndex(direction)][cell] += transfer_carrier;
            const sensible_capacity = phaseCapacity(solid, liquid, ice, inputs.thermodynamics);
            const sensible_heat = sensible_capacity * state.temperature_k[top];
            const conserved = try conservedTransfer(
                state,
                top,
                fraction,
                solid,
                liquid,
                ice,
                sensible_heat,
                inputs,
            );
            const transfer = conserved.activity;
            if (neighborIndex(columns, rows, cell, direction)) |destination_cell| {
                const destination = try state.layerIndex(destination_cell, 0);
                solid_candidate[destination] += solid;
                liquid_candidate[destination] += liquid;
                ice_candidate[destination] += ice;
                energy_candidate[destination] += sensible_heat;
                for (0..snow.species_count) |species|
                    amount_candidate[destination * snow.species_count + species] +=
                        state.amount_g[top * snow.species_count + species] * fraction;
                for (0..snow.salt_species_count) |species|
                    salt_candidate[destination * snow.salt_species_count + species] +=
                        state.salt_amount_mol[top * snow.salt_species_count + species] * fraction;
                try addTransferActivity(&cell_activity_delta[cell], transfer, .output);
                try addTransferActivity(&cell_activity_delta[destination_cell], transfer, .input);
                result.internal_direction_count += 1;
            } else {
                try addTransferActivity(&cell_activity_delta[cell], transfer, .output);
                try addTransfer(&external_transfer, transfer);
                external_legacy_ion_mol += conserved.legacy_ion_mol;
                if (!std.math.isFinite(external_legacy_ion_mol))
                    return error.SnowDriftLedgerOverflow;
                result.open_boundary_direction_count += 1;
                result.boundary_solid_snow_water_equivalent_m3 += solid;
                result.boundary_liquid_water_m3 += liquid;
                result.boundary_ice_volume_m3 += ice;
                result.boundary_water_equivalent_m3 += transfer.water_m3;
                result.boundary_heat_megajoules += transfer.heat_megajoules;
            }
        }
    }

    for (0..cells) |cell| {
        const top = try state.layerIndex(cell, 0);
        inline for (.{ solid_candidate[top], liquid_candidate[top], ice_candidate[top], energy_candidate[top] }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDriftCandidate;
        const capacity = phaseCapacity(
            solid_candidate[top],
            liquid_candidate[top] + state.vapor_water_equivalent_m3[top],
            ice_candidate[top],
            inputs.thermodynamics,
        );
        if (!std.math.isFinite(capacity) or capacity < 0) return error.InvalidSnowDriftCandidate;
        heat_capacity_candidate[top] = capacity;
        if (capacity > 0) {
            const temperature = energy_candidate[top] / capacity;
            if (!std.math.isFinite(temperature) or temperature <= 0) return error.InvalidSnowDriftCandidate;
            temperature_candidate[top] = temperature;
        } else if (energy_candidate[top] != 0) return error.InvalidSnowDriftCandidate;
        const density = state.snow_density_megagrams_per_m3[top];
        if (!std.math.isFinite(density) or density < 0 or (solid_candidate[top] > 0 and density == 0))
            return error.InvalidSnowDriftCandidate;
        const total_volume = (if (density > 0) solid_candidate[top] / density else 0) + liquid_candidate[top] + ice_candidate[top];
        if (!std.math.isFinite(total_volume) or total_volume < 0 or !std.math.isFinite(state.horizontal_area_m2[top]) or state.horizontal_area_m2[top] <= 0)
            return error.InvalidSnowDriftCandidate;
        active_candidate[top] = total_volume > 0 or state.vapor_water_equivalent_m3[top] > 0 or
            hasPositive(amount_candidate[top * snow.species_count ..][0..snow.species_count]) or
            hasPositive(salt_candidate[top * snow.salt_species_count ..][0..snow.salt_species_count]);
    }
    for (amount_candidate) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDriftCandidate;
    for (salt_candidate) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDriftCandidate;

    try candidate_workspace.allocateLedgerCells(inputs.cell_boundary_ledger.cells);
    const ledger_cells_candidate = candidate_workspace.ledger_cells;
    var ledger_candidate: cell_conservation.BoundaryLedger = .{ .allocator = allocator, .cells = ledger_cells_candidate };
    for (cell_activity_delta, 0..) |activity, cell| try ledger_candidate.accumulate(cell, activity);
    var landscape_candidate = inputs.landscape_boundary_ledger.*;
    try landscape_candidate.accumulateAccepted(.{
        .water_outflow_m3 = external_transfer.water_m3,
        .heat_output_megajoules = external_transfer.heat_megajoules,
        .oxygen_output_g = external_transfer.oxygen_g,
        .carbon_output_g_c = external_transfer.carbon_g,
        .nitrogen_output_g_n = external_transfer.nitrogen_g,
        .phosphorus_output_g_p = external_transfer.phosphorus_g,
        .ion_output_mol = external_legacy_ion_mol,
    });

    @memcpy(state.solid_snow_water_equivalent_m3, solid_candidate);
    @memcpy(state.liquid_water_volume_m3, liquid_candidate);
    @memcpy(state.ice_volume_m3, ice_candidate);
    @memcpy(state.heat_capacity_megajoules_per_k, heat_capacity_candidate);
    @memcpy(state.temperature_k, temperature_candidate);
    @memcpy(state.amount_g, amount_candidate);
    @memcpy(state.salt_amount_mol, salt_candidate);
    @memcpy(state.active, active_candidate);
    state.refreshAllGeometry();
    @memcpy(inputs.cell_boundary_ledger.cells, ledger_cells_candidate);
    inputs.landscape_boundary_ledger.* = landscape_candidate;
    inline for (accepted_destinations, accepted_flux_candidates) |destination, candidate| @memcpy(destination, candidate);
    return result;
}

fn eligibleDirection(state: *const snow.State, columns: usize, rows: usize, cell: usize, source_surface: f64, direction: Direction, inputs: PhysicalInputs) bool {
    if (neighborIndex(columns, rows, cell, direction)) |destination| {
        const destination_depth = state.cumulative_depth_m[(destination + 1) * state.layer_capacity - 1];
        const destination_surface = inputs.ground_surface_elevation_m[destination] + destination_depth;
        if (!std.math.isFinite(destination_surface)) return false;
        const tolerance = inputs.elevation_absolute_tolerance_m + inputs.relative_tolerance * @max(@abs(source_surface), @abs(destination_surface));
        return source_surface > destination_surface + tolerance;
    }
    return isOpen(direction, cell, inputs.boundaries) and isDownhill(direction, cell, inputs.downhill);
}

fn neighborIndex(columns: usize, rows: usize, cell: usize, direction: Direction) ?usize {
    const column = cell % columns;
    const row = cell / columns;
    return switch (direction) {
        .east => if (column + 1 < columns) cell + 1 else null,
        .south => if (row + 1 < rows) cell + columns else null,
        .west => if (column > 0) cell - 1 else null,
        .north => if (row > 0) cell - columns else null,
    };
}

fn axisFraction(direction: Direction, east_west: f64, north_south: f64) f64 {
    return switch (direction) {
        .east, .west => east_west,
        .south, .north => north_south,
    };
}

fn directionFluxIndex(direction: Direction) usize {
    return switch (direction) {
        .east => 2,
        .west => 3,
        .south => 4,
        .north => 5,
    };
}

fn isOpen(direction: Direction, cell: usize, boundaries: routing.BoundaryConditions) bool {
    return switch (direction) {
        .east => boundaries.east_open[cell],
        .south => boundaries.south_open[cell],
        .west => boundaries.west_open[cell],
        .north => boundaries.north_open[cell],
    };
}

fn isDownhill(direction: Direction, cell: usize, downhill: DownhillDirections) bool {
    return switch (direction) {
        .east => downhill.east[cell],
        .south => downhill.south[cell],
        .west => downhill.west[cell],
        .north => downhill.north[cell],
    };
}

fn phaseCapacity(solid: f64, liquid: f64, ice: f64, thermodynamics: snow.ThermodynamicParameters) f64 {
    return thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * solid +
        thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * liquid +
        thermodynamics.ice_heat_capacity_megajoules_per_m3_k * ice;
}

fn expectedCapacity(state: *const snow.State, layer: usize, thermodynamics: snow.ThermodynamicParameters) f64 {
    return phaseCapacity(
        state.solid_snow_water_equivalent_m3[layer],
        state.liquid_water_volume_m3[layer] + state.vapor_water_equivalent_m3[layer],
        state.ice_volume_m3[layer],
        thermodynamics,
    );
}

fn conservedTransfer(state: *const snow.State, layer: usize, fraction: f64, solid: f64, liquid: f64, ice: f64, sensible_heat: f64, inputs: PhysicalInputs) !ConservedTransfer {
    const solid_correction_per_m3 = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        inputs.thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k,
        inputs.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.latent_heat_of_fusion_megajoules_per_m3,
        inputs.thermodynamics.pure_water_melting_temperature_k,
    );
    const ice_capacity_we = try ice_units.heatCapacityPerWaterEquivalentM3K(
        inputs.thermodynamics.ice_heat_capacity_megajoules_per_m3_k,
        inputs.ice_density_megagrams_per_m3,
    );
    const ice_correction_per_m3 = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        ice_capacity_we,
        inputs.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.latent_heat_of_fusion_megajoules_per_m3,
        inputs.thermodynamics.pure_water_melting_temperature_k,
    );
    const ice_we = try ice_units.waterEquivalentM3FromPhysicalVolume(
        ice,
        inputs.ice_density_megagrams_per_m3,
    );
    var result: cell_conservation.IntercellTransfer = .{
        .water_m3 = solid + liquid + ice_we,
        .heat_megajoules = sensible_heat +
            solid_correction_per_m3 * solid + ice_correction_per_m3 * ice_we,
    };
    const amounts = state.amount_g[layer * snow.species_count ..][0..snow.species_count];
    result.carbon_g += fraction * (amounts[@intFromEnum(snow.Species.carbon_dioxide_carbon)] + amounts[@intFromEnum(snow.Species.methane_carbon)]);
    result.oxygen_g += fraction * amounts[@intFromEnum(snow.Species.oxygen)];
    result.nitrogen_g += fraction * (amounts[@intFromEnum(snow.Species.dinitrogen_nitrogen)] + amounts[@intFromEnum(snow.Species.nitrous_oxide_nitrogen)] + amounts[@intFromEnum(snow.Species.ammonium_nitrogen)] + amounts[@intFromEnum(snow.Species.ammonia_nitrogen)] + amounts[@intFromEnum(snow.Species.nitrate_nitrogen)]);
    result.phosphorus_g += fraction * (amounts[@intFromEnum(snow.Species.hydrogen_phosphate_phosphorus)] + amounts[@intFromEnum(snow.Species.dihydrogen_phosphate_phosphorus)]);
    var legacy_ion_mol = fraction * (2 * amounts[@intFromEnum(snow.Species.hydrogen_phosphate_phosphorus)] / snow.phosphorus_g_per_mol +
        3 * amounts[@intFromEnum(snow.Species.dihydrogen_phosphate_phosphorus)] / snow.phosphorus_g_per_mol +
        amounts[@intFromEnum(snow.Species.aluminum)] / inputs.ion_molar_mass_g_per_mol.aluminum +
        amounts[@intFromEnum(snow.Species.iron)] / inputs.ion_molar_mass_g_per_mol.iron +
        amounts[@intFromEnum(snow.Species.calcium)] / inputs.ion_molar_mass_g_per_mol.calcium +
        amounts[@intFromEnum(snow.Species.magnesium)] / inputs.ion_molar_mass_g_per_mol.magnesium +
        amounts[@intFromEnum(snow.Species.sodium)] / inputs.ion_molar_mass_g_per_mol.sodium +
        amounts[@intFromEnum(snow.Species.potassium)] / inputs.ion_molar_mass_g_per_mol.potassium +
        amounts[@intFromEnum(snow.Species.sulfate_sulfur)] / inputs.ion_molar_mass_g_per_mol.sulfur +
        amounts[@intFromEnum(snow.Species.chloride)] / inputs.ion_molar_mass_g_per_mol.chloride);
    result.aluminum_mol += fraction * amounts[@intFromEnum(snow.Species.aluminum)] / inputs.ion_molar_mass_g_per_mol.aluminum;
    result.iron_mol += fraction * amounts[@intFromEnum(snow.Species.iron)] / inputs.ion_molar_mass_g_per_mol.iron;
    result.calcium_mol += fraction * amounts[@intFromEnum(snow.Species.calcium)] / inputs.ion_molar_mass_g_per_mol.calcium;
    result.magnesium_mol += fraction * amounts[@intFromEnum(snow.Species.magnesium)] / inputs.ion_molar_mass_g_per_mol.magnesium;
    result.sodium_mol += fraction * amounts[@intFromEnum(snow.Species.sodium)] / inputs.ion_molar_mass_g_per_mol.sodium;
    result.potassium_mol += fraction * amounts[@intFromEnum(snow.Species.potassium)] / inputs.ion_molar_mass_g_per_mol.potassium;
    result.sulfur_mol += fraction * amounts[@intFromEnum(snow.Species.sulfate_sulfur)] / inputs.ion_molar_mass_g_per_mol.sulfur;
    result.chloride_mol += fraction * amounts[@intFromEnum(snow.Species.chloride)] / inputs.ion_molar_mass_g_per_mol.chloride;
    const salts = state.salt_amount_mol[layer * snow.salt_species_count ..][0..snow.salt_species_count];
    for (salts, 0..) |amount_mol, species| {
        const aqueous_species = snow.aqueousSpeciesForSalt(@enumFromInt(species));
        const formula = surface_aqueous.formula(aqueous_species);
        const transferred_mol = amount_mol * fraction;
        result.carbon_g += transferred_mol * formula.carbon_mol * 12;
        result.phosphorus_g += transferred_mol * formula.phosphorus_mol * snow.phosphorus_g_per_mol;
        inline for (.{
            .{ "aluminum_mol", "aluminum_mol" }, .{ "iron_mol", "iron_mol" },
            .{ "calcium_mol", "calcium_mol" },   .{ "magnesium_mol", "magnesium_mol" },
            .{ "sodium_mol", "sodium_mol" },     .{ "potassium_mol", "potassium_mol" },
            .{ "sulfur_mol", "sulfur_mol" },     .{ "chloride_mol", "chloride_mol" },
            .{ "silicon_mol", "silicon_mol" },
        }) |names| @field(result, names[0]) += transferred_mol * @field(formula, names[1]);
        legacy_ion_mol += transferred_mol * solute_species.legacyIonCount(aqueous_species);
    }
    inline for (@typeInfo(cell_conservation.IntercellTransfer).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0)
            return error.InvalidSnowDriftCandidate;
    if (!std.math.isFinite(legacy_ion_mol) or legacy_ion_mol < 0)
        return error.InvalidSnowDriftCandidate;
    return .{ .activity = result, .legacy_ion_mol = legacy_ion_mol };
}

fn addTransferActivity(activity: *cell_conservation.BoundaryActivity, transfer: cell_conservation.IntercellTransfer, direction: enum { input, output }) !void {
    return switch (direction) {
        .input => addTransferActivityDirection(activity, transfer, true),
        .output => addTransferActivityDirection(activity, transfer, false),
    };
}

fn addTransferActivityDirection(activity: *cell_conservation.BoundaryActivity, transfer: cell_conservation.IntercellTransfer, comptime input: bool) !void {
    inline for (.{
        .{ "water_m3", "water_input_m3", "water_output_m3" },
        .{ "heat_megajoules", "heat_input_megajoules", "heat_output_megajoules" },
        .{ "oxygen_g", "oxygen_input_g", "oxygen_output_g" },
        .{ "hydrogen_g", "hydrogen_input_g", "hydrogen_output_g" },
        .{ "carbon_g", "carbon_input_g", "carbon_output_g" },
        .{ "nitrogen_g", "nitrogen_input_g", "nitrogen_output_g" },
        .{ "phosphorus_g", "phosphorus_input_g", "phosphorus_output_g" },
        .{ "aluminum_mol", "aluminum_input_mol", "aluminum_output_mol" },
        .{ "iron_mol", "iron_input_mol", "iron_output_mol" },
        .{ "calcium_mol", "calcium_input_mol", "calcium_output_mol" },
        .{ "magnesium_mol", "magnesium_input_mol", "magnesium_output_mol" },
        .{ "sodium_mol", "sodium_input_mol", "sodium_output_mol" },
        .{ "potassium_mol", "potassium_input_mol", "potassium_output_mol" },
        .{ "sulfur_mol", "sulfur_input_mol", "sulfur_output_mol" },
        .{ "chloride_mol", "chloride_input_mol", "chloride_output_mol" },
        .{ "silicon_mol", "silicon_input_mol", "silicon_output_mol" },
    }) |names| {
        const activity_name = if (input) names[1] else names[2];
        const next = @field(activity, activity_name) + @field(transfer, names[0]);
        if (!std.math.isFinite(next)) return error.SnowDriftLedgerOverflow;
        @field(activity, activity_name) = next;
    }
}

fn addTransfer(total: *cell_conservation.IntercellTransfer, transfer: cell_conservation.IntercellTransfer) !void {
    inline for (@typeInfo(cell_conservation.IntercellTransfer).@"struct".fields) |field| {
        const next = @field(total, field.name) + @field(transfer, field.name);
        if (!std.math.isFinite(next)) return error.SnowDriftLedgerOverflow;
        @field(total, field.name) = next;
    }
}

fn hasPositive(values: []const f64) bool {
    for (values) |value| if (value > 0) return true;
    return false;
}

fn testIonMolarMasses() @import("snow_surface_discharge.zig").IonMolarMassesGPerMol {
    return .{
        .aluminum = 26.9815385,
        .iron = 55.845,
        .calcium = 40.078,
        .magnesium = 24.305,
        .sodium = 22.98976928,
        .potassium = 39.0983,
        .sulfur = 32.065,
        .chloride = 35.453,
    };
}

fn allocatePhysicalCandidateWorkspaceForFailureTest(allocator: std.mem.Allocator) !void {
    var state = try snow.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    var accepted: [6][2]f64 = @splat(@splat(0));
    var workspace = try PhysicalCandidateWorkspace.init(
        allocator,
        &state,
        2,
        .{ &accepted[0], &accepted[1], &accepted[2], &accepted[3], &accepted[4], &accepted[5] },
        false,
    );
    defer workspace.deinit();
    try workspace.allocateLedgerCells(&.{ .{}, .{} });
}

test "snow drift candidate workspace releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocatePhysicalCandidateWorkspaceForFailureTest,
        .{},
    );
}

test "WATSUB QSX physical drift conserves phases heat and every solute between cells" {
    var state = try snow.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.1, 0.02 }, &.{ 1, 1 }, &.{ 260, 270 }, &.{1}, 0.1, snow.test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.004;
    state.ice_volume_m3[0] = 0.003;
    state.liquid_water_volume_m3[1] = 0.001;
    state.ice_volume_m3[1] = 0.002;
    for (0..2) |layer| state.heat_capacity_megajoules_per_k[layer] = expectedCapacity(&state, layer, snow.test_thermodynamics);
    state.refreshAllGeometry();
    for (try state.amounts(0, 0), 0..) |*amount, species| amount.* = @floatFromInt(species + 1);
    @memset(try state.saltAmounts(0, 0), 1);
    state.dynamic_salts_by_cell[0] = true;

    const solid_before = state.solid_snow_water_equivalent_m3[0] + state.solid_snow_water_equivalent_m3[1];
    const liquid_before = state.liquid_water_volume_m3[0] + state.liquid_water_volume_m3[1];
    const ice_before = state.ice_volume_m3[0] + state.ice_volume_m3[1];
    const energy_before = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0] + state.heat_capacity_megajoules_per_k[1] * state.temperature_k[1];
    var amounts_before: [snow.species_count]f64 = undefined;
    var salts_before: [snow.salt_species_count]f64 = undefined;
    for (&amounts_before, 0..) |*amount, species| amount.* = state.amount_g[species] + state.amount_g[snow.species_count + species];
    for (&salts_before, 0..) |*amount, species| amount.* = state.salt_amount_mol[species] + state.salt_amount_mol[snow.salt_species_count + species];

    var cell_ledger = try cell_conservation.BoundaryLedger.init(std.testing.allocator, 2);
    defer cell_ledger.deinit();
    var landscape_ledger: landscape_boundary.State = .{};
    var accepted: [6][2]f64 = undefined;
    const no = [_]bool{ false, false };
    const result = try produceAndRoute(std.testing.allocator, &state, 2, 1, .{
        .ground_surface_elevation_m = &.{ 10, 0 },
        .wind_speed_m_per_h = &.{ 10_000, 0 },
        .east_west_fraction = &.{ 1, 1 },
        .north_south_fraction = &.{ 0, 0 },
        .downhill = .{ .east = &no, .west = &no, .south = &no, .north = &no },
        .boundaries = .{ .east_open = &no, .west_open = &no, .south_open = &no, .north_open = &no },
        .timestep_h = 1,
        .thermodynamics = snow.test_thermodynamics,
        .ice_density_megagrams_per_m3 = 0.917,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .elevation_absolute_tolerance_m = 1e-12,
        .relative_tolerance = 1e-12,
        .ion_molar_mass_g_per_mol = testIonMolarMasses(),
        .accepted_fluxes = .{ .source_carrier_m3 = &accepted[0], .total_m3 = &accepted[1], .east_m3 = &accepted[2], .west_m3 = &accepted[3], .south_m3 = &accepted[4], .north_m3 = &accepted[5] },
        .cell_boundary_ledger = &cell_ledger,
        .landscape_boundary_ledger = &landscape_ledger,
    });
    try std.testing.expectEqual(@as(usize, 1), result.internal_direction_count);
    try std.testing.expectEqual(@as(usize, 0), result.open_boundary_direction_count);
    try std.testing.expectApproxEqAbs(solid_before, state.solid_snow_water_equivalent_m3[0] + state.solid_snow_water_equivalent_m3[1], 1e-15);
    try std.testing.expectApproxEqAbs(liquid_before, state.liquid_water_volume_m3[0] + state.liquid_water_volume_m3[1], 1e-15);
    try std.testing.expectApproxEqAbs(ice_before, state.ice_volume_m3[0] + state.ice_volume_m3[1], 1e-15);
    try std.testing.expectApproxEqAbs(energy_before, state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0] + state.heat_capacity_megajoules_per_k[1] * state.temperature_k[1], 1e-12);
    for (amounts_before, 0..) |amount, species| try std.testing.expectApproxEqAbs(amount, state.amount_g[species] + state.amount_g[snow.species_count + species], 1e-15);
    for (salts_before, 0..) |amount, species| try std.testing.expectApproxEqAbs(amount, state.salt_amount_mol[species] + state.salt_amount_mol[snow.salt_species_count + species], 1e-15);
    inline for (.{
        .{ "water_output_m3", "water_input_m3" },           .{ "heat_output_megajoules", "heat_input_megajoules" },
        .{ "oxygen_output_g", "oxygen_input_g" },           .{ "hydrogen_output_g", "hydrogen_input_g" },
        .{ "carbon_output_g", "carbon_input_g" },           .{ "nitrogen_output_g", "nitrogen_input_g" },
        .{ "phosphorus_output_g", "phosphorus_input_g" },   .{ "aluminum_output_mol", "aluminum_input_mol" },
        .{ "iron_output_mol", "iron_input_mol" },           .{ "calcium_output_mol", "calcium_input_mol" },
        .{ "magnesium_output_mol", "magnesium_input_mol" }, .{ "sodium_output_mol", "sodium_input_mol" },
        .{ "potassium_output_mol", "potassium_input_mol" }, .{ "sulfur_output_mol", "sulfur_input_mol" },
        .{ "chloride_output_mol", "chloride_input_mol" },   .{ "silicon_output_mol", "silicon_input_mol" },
    }) |names| try std.testing.expectEqual(@field(cell_ledger.cells[0], names[0]), @field(cell_ledger.cells[1], names[1]));
    try std.testing.expectEqual(@as(f64, 0), landscape_ledger.cumulative.water_outflow_m3);
}

test "open QSX drift books physical and all-element boundary activity" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{260}, &.{1}, 0.1, snow.test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.004;
    state.ice_volume_m3[0] = 0.003;
    state.heat_capacity_megajoules_per_k[0] = expectedCapacity(&state, 0, snow.test_thermodynamics);
    state.refreshAllGeometry();
    @memset(try state.amounts(0, 0), 1);
    @memset(try state.saltAmounts(0, 0), 1);
    const state_amount_before = state.amount_g[0];
    const yes = [_]bool{true};
    const no = [_]bool{false};
    var cell_ledger = try cell_conservation.BoundaryLedger.init(std.testing.allocator, 1);
    defer cell_ledger.deinit();
    var landscape_ledger: landscape_boundary.State = .{};
    var accepted: [6][1]f64 = undefined;
    const result = try produceAndRoute(std.testing.allocator, &state, 1, 1, .{
        .ground_surface_elevation_m = &.{0},
        .wind_speed_m_per_h = &.{10_000},
        .east_west_fraction = &.{1},
        .north_south_fraction = &.{0},
        .downhill = .{ .east = &yes, .west = &no, .south = &no, .north = &no },
        .boundaries = .{ .east_open = &yes, .west_open = &no, .south_open = &no, .north_open = &no },
        .timestep_h = 0.5,
        .thermodynamics = snow.test_thermodynamics,
        .ice_density_megagrams_per_m3 = 0.917,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .elevation_absolute_tolerance_m = 1e-12,
        .relative_tolerance = 1e-12,
        .ion_molar_mass_g_per_mol = testIonMolarMasses(),
        .accepted_fluxes = .{ .source_carrier_m3 = &accepted[0], .total_m3 = &accepted[1], .east_m3 = &accepted[2], .west_m3 = &accepted[3], .south_m3 = &accepted[4], .north_m3 = &accepted[5] },
        .cell_boundary_ledger = &cell_ledger,
        .landscape_boundary_ledger = &landscape_ledger,
    });
    try std.testing.expectEqual(@as(usize, 1), result.open_boundary_direction_count);
    try std.testing.expect(result.boundary_water_equivalent_m3 > 0);
    try std.testing.expect(result.boundary_heat_megajoules > 0);
    try std.testing.expectEqual(result.boundary_water_equivalent_m3, cell_ledger.cells[0].water_output_m3);
    try std.testing.expectEqual(result.boundary_water_equivalent_m3, landscape_ledger.cumulative.water_outflow_m3);
    try std.testing.expectEqual(result.boundary_heat_megajoules, landscape_ledger.cumulative.heat_output_megajoules);
    const transfer_fraction: f64 = 0.0005;
    const transferred_solid = 0.01 * transfer_fraction;
    const transferred_liquid = 0.004 * transfer_fraction;
    const transferred_ice_physical = 0.003 * transfer_fraction;
    const ice_density: f64 = 0.917;
    const ice_capacity_we = snow.test_thermodynamics.ice_heat_capacity_megajoules_per_m3_k / ice_density;
    const solid_enthalpy_per_m3 = snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
        snow.test_thermodynamics.pure_water_melting_temperature_k - 333 +
        snow.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k *
            (260 - snow.test_thermodynamics.pure_water_melting_temperature_k);
    const ice_enthalpy_per_we_m3 = snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
        snow.test_thermodynamics.pure_water_melting_temperature_k - 333 +
        ice_capacity_we * (260 - snow.test_thermodynamics.pure_water_melting_temperature_k);
    const expected_boundary_heat = solid_enthalpy_per_m3 * transferred_solid +
        snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * 260 * transferred_liquid +
        ice_enthalpy_per_we_m3 * transferred_ice_physical * ice_density;
    try std.testing.expectApproxEqAbs(expected_boundary_heat, result.boundary_heat_megajoules, 1e-14);
    try std.testing.expect(landscape_ledger.cumulative.carbon_output_g_c > 0);
    try std.testing.expect(landscape_ledger.cumulative.nitrogen_output_g_n > 0);
    try std.testing.expect(landscape_ledger.cumulative.phosphorus_output_g_p > 0);
    try std.testing.expect(landscape_ledger.cumulative.ion_output_mol > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.000005), result.boundary_solid_snow_water_equivalent_m3, 1e-15);
    try std.testing.expectApproxEqAbs(state_amount_before * 0.9995, state.amount_g[0], 1e-15);
}

test "accepted QSX schedules apply dt to each updated donor image" {
    const Outcome = struct {
        remaining_solid_m3: f64,
        remaining_amount_g: f64,
        remaining_salt_mol: f64,
        accepted_total_m3: f64,
        boundary_water_m3: f64,
    };
    const Schedule = struct {
        fn run(substep_count: u8) !Outcome {
            var state = try snow.State.init(std.testing.allocator, 1, 1);
            defer state.deinit();
            try state.initializePhysicalState(&.{0.1}, &.{1}, &.{260}, &.{1}, 0.1, snow.test_thermodynamics);
            @memset(try state.amounts(0, 0), 1);
            @memset(try state.saltAmounts(0, 0), 1);
            const yes = [_]bool{true};
            const no = [_]bool{false};
            var cell_ledger = try cell_conservation.BoundaryLedger.init(std.testing.allocator, 1);
            defer cell_ledger.deinit();
            var landscape_ledger: landscape_boundary.State = .{};
            var accepted: [6][1]f64 = @splat(@splat(0));
            const timestep_h = 1 / @as(f64, @floatFromInt(substep_count));
            for (0..substep_count) |_| _ = try produceAndRoute(std.testing.allocator, &state, 1, 1, .{
                .ground_surface_elevation_m = &.{0},
                .wind_speed_m_per_h = &.{10_000},
                .east_west_fraction = &.{1},
                .north_south_fraction = &.{0},
                .downhill = .{ .east = &yes, .west = &no, .south = &no, .north = &no },
                .boundaries = .{ .east_open = &yes, .west_open = &no, .south_open = &no, .north_open = &no },
                .timestep_h = timestep_h,
                .thermodynamics = snow.test_thermodynamics,
                .ice_density_megagrams_per_m3 = 0.917,
                .latent_heat_of_fusion_megajoules_per_m3 = 333,
                .elevation_absolute_tolerance_m = 1e-12,
                .relative_tolerance = 1e-12,
                .ion_molar_mass_g_per_mol = testIonMolarMasses(),
                .accepted_fluxes = .{ .source_carrier_m3 = &accepted[0], .total_m3 = &accepted[1], .east_m3 = &accepted[2], .west_m3 = &accepted[3], .south_m3 = &accepted[4], .north_m3 = &accepted[5] },
                .accumulate_accepted_fluxes = true,
                .cell_boundary_ledger = &cell_ledger,
                .landscape_boundary_ledger = &landscape_ledger,
            });
            try std.testing.expectEqual(cell_ledger.cells[0].water_output_m3, landscape_ledger.cumulative.water_outflow_m3);
            return .{
                .remaining_solid_m3 = state.solid_snow_water_equivalent_m3[0],
                .remaining_amount_g = state.amount_g[0],
                .remaining_salt_mol = state.salt_amount_mol[0],
                .accepted_total_m3 = accepted[1][0],
                .boundary_water_m3 = landscape_ledger.cumulative.water_outflow_m3,
            };
        }
    };

    const initial_solid_m3: f64 = 0.01;
    const one = try Schedule.run(1);
    const two = try Schedule.run(2);
    const four = try Schedule.run(4);
    const Case = struct { outcome: Outcome, substep_count: u8 };
    for ([_]Case{ .{ .outcome = one, .substep_count = 1 }, .{ .outcome = two, .substep_count = 2 }, .{ .outcome = four, .substep_count = 4 } }) |case| {
        const count: f64 = @floatFromInt(case.substep_count);
        const remaining_fraction = std.math.pow(f64, 1 - 0.001 / count, count);
        try std.testing.expectApproxEqAbs(initial_solid_m3 * remaining_fraction, case.outcome.remaining_solid_m3, 1e-15);
        try std.testing.expectApproxEqAbs(remaining_fraction, case.outcome.remaining_amount_g, 1e-15);
        try std.testing.expectApproxEqAbs(remaining_fraction, case.outcome.remaining_salt_mol, 1e-15);
        try std.testing.expectApproxEqAbs(initial_solid_m3 * (1 - remaining_fraction), case.outcome.accepted_total_m3, 1e-15);
        try std.testing.expectApproxEqAbs(case.outcome.accepted_total_m3, case.outcome.boundary_water_m3, 1e-15);
    }
    // Re-evaluating the updated donor is intentionally distinct from a
    // one-shot hour; this guards against moving QSX back outside the accepted
    // 60/30/15-minute schedule.
    try std.testing.expect(one.remaining_solid_m3 < two.remaining_solid_m3);
    try std.testing.expect(two.remaining_solid_m3 < four.remaining_solid_m3);
}

test "late QSX ledger overflow rolls back every physical chemical and accounting owner" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{260}, &.{1}, 0.1, snow.test_thermodynamics);
    @memset(try state.amounts(0, 0), 1);
    state.amount_g[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = std.math.floatMax(f64);
    @memset(try state.saltAmounts(0, 0), 1);
    const solid_before = state.solid_snow_water_equivalent_m3[0];
    const amount_before = state.amount_g[0];
    const salt_before = state.salt_amount_mol[0];
    var cell_ledger = try cell_conservation.BoundaryLedger.init(std.testing.allocator, 1);
    defer cell_ledger.deinit();
    var landscape_ledger: landscape_boundary.State = .{};
    landscape_ledger.cumulative.carbon_output_g_c = std.math.floatMax(f64);
    const ledger_before = landscape_ledger;
    var accepted: [6][1]f64 = @splat(@splat(42));
    const accepted_before = accepted;
    const yes = [_]bool{true};
    const no = [_]bool{false};
    var wind = [_]f64{10_000};
    const inputs: PhysicalInputs = .{
        .ground_surface_elevation_m = &.{0},
        .wind_speed_m_per_h = &wind,
        .east_west_fraction = &.{1},
        .north_south_fraction = &.{0},
        .downhill = .{ .east = &yes, .west = &no, .south = &no, .north = &no },
        .boundaries = .{ .east_open = &yes, .west_open = &no, .south_open = &no, .north_open = &no },
        .timestep_h = 1,
        .thermodynamics = snow.test_thermodynamics,
        .ice_density_megagrams_per_m3 = 0.917,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .elevation_absolute_tolerance_m = 1e-12,
        .relative_tolerance = 1e-12,
        .ion_molar_mass_g_per_mol = testIonMolarMasses(),
        .accepted_fluxes = .{ .source_carrier_m3 = &accepted[0], .total_m3 = &accepted[1], .east_m3 = &accepted[2], .west_m3 = &accepted[3], .south_m3 = &accepted[4], .north_m3 = &accepted[5] },
        .cell_boundary_ledger = &cell_ledger,
        .landscape_boundary_ledger = &landscape_ledger,
    };
    try std.testing.expectError(error.LandscapeBoundaryLedgerOverflow, produceAndRoute(std.testing.allocator, &state, 1, 1, inputs));
    try std.testing.expectEqual(solid_before, state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expectEqual(amount_before, state.amount_g[0]);
    try std.testing.expectEqual(salt_before, state.salt_amount_mol[0]);
    try std.testing.expectEqualDeep(ledger_before, landscape_ledger);
    try std.testing.expectEqualDeep(cell_conservation.BoundaryActivity{}, cell_ledger.cells[0]);
    try std.testing.expectEqualDeep(accepted_before, accepted);

    // Source-demand above one full top-layer inventory fails closed; no
    // proportional clipping may mask a physically impossible drift request.
    landscape_ledger = .{};
    wind[0] = 20_000_000;
    try std.testing.expectError(error.SnowDriftExceedsDonorInventory, produceAndRoute(std.testing.allocator, &state, 1, 1, inputs));
    try std.testing.expectEqual(solid_before, state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expectEqual(amount_before, state.amount_g[0]);
    try std.testing.expectEqual(salt_before, state.salt_amount_mol[0]);
    try std.testing.expectEqualDeep(cell_conservation.BoundaryActivity{}, cell_ledger.cells[0]);
    try std.testing.expectEqualDeep(accepted_before, accepted);
}

/// Routes every tracked inventory in snow layer 1 using QST/QSTN and VOLSL(1).
/// The gram carriers and exact 41-species salt-mol carrier share one transport
/// fraction and one atomic state_update.
pub fn route(allocator: std.mem.Allocator, state: *snow.State, columns: usize, rows: usize, carrier_volume_m3: []const f64, total_transfer_m3: []const f64, directions: routing.Directions, boundaries: routing.BoundaryConditions, maximum_transport_fraction: f64, exported_g: []f64, exported_salt_mol: []f64) !void {
    const cells = try std.math.mul(usize, columns, rows);
    if (cells != state.cell_count or carrier_volume_m3.len != cells or total_transfer_m3.len != cells or directions.east_m3.len != cells or directions.west_m3.len != cells or directions.south_m3.len != cells or directions.north_m3.len != cells or boundaries.east_open.len != cells or boundaries.west_open.len != cells or boundaries.south_open.len != cells or boundaries.north_open.len != cells or exported_g.len != snow.species_count or exported_salt_mol.len != snow.salt_species_count) return error.SnowDriftDimensionMismatch;
    if (!std.math.isFinite(maximum_transport_fraction) or maximum_transport_fraction < 0 or maximum_transport_fraction > 1) return error.InvalidSnowDriftInput;
    const candidate = try allocator.dupe(f64, state.amount_g);
    defer allocator.free(candidate);
    const salt_candidate = try allocator.dupe(f64, state.salt_amount_mol);
    defer allocator.free(salt_candidate);
    const active_candidate = try allocator.dupe(bool, state.active);
    defer allocator.free(active_candidate);
    const exported_candidate_g = try allocator.alloc(f64, snow.species_count);
    defer allocator.free(exported_candidate_g);
    const exported_candidate_salt_mol = try allocator.alloc(f64, snow.salt_species_count);
    defer allocator.free(exported_candidate_salt_mol);
    @memset(exported_candidate_g, 0);
    @memset(exported_candidate_salt_mol, 0);
    for (0..cells) |cell| {
        const carrier = carrier_volume_m3[cell];
        const total = total_transfer_m3[cell];
        if (!std.math.isFinite(carrier) or carrier < 0 or !std.math.isFinite(total) or total < 0) return error.InvalidSnowDriftInput;
        const directional = [_]f64{ directions.east_m3[cell], directions.west_m3[cell], directions.south_m3[cell], directions.north_m3[cell] };
        var directional_sum: f64 = 0;
        for (directional) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDriftInput;
            directional_sum += value;
        }
        if (directional_sum > total + 64 * std.math.floatEps(f64) * @max(1, total)) return error.DirectionalSnowDriftExceedsTotal;
        if (total == 0) continue;
        const transported_fraction = if (carrier > 0) @min(maximum_transport_fraction, total / carrier) else maximum_transport_fraction;
        const column = cell % columns;
        const row = cell / columns;
        const neighbors = [_]?usize{ if (column + 1 < columns) cell + 1 else null, if (column > 0) cell - 1 else null, if (row + 1 < rows) cell + columns else null, if (row > 0) cell - columns else null };
        const open = [_]bool{ boundaries.east_open[cell], boundaries.west_open[cell], boundaries.south_open[cell], boundaries.north_open[cell] };
        const source_layer = try state.layerIndex(cell, 0);
        for (directional, neighbors, open) |direction_volume, neighbor, is_open| {
            if (direction_volume == 0 or (neighbor == null and !is_open)) continue;
            const fraction = transported_fraction * direction_volume / total;
            for (0..snow.species_count) |species| {
                const source = source_layer * snow.species_count + species;
                const flux = state.amount_g[source] * fraction;
                candidate[source] -= flux;
                if (neighbor) |destination_cell| {
                    const destination_layer = try state.layerIndex(destination_cell, 0);
                    candidate[destination_layer * snow.species_count + species] += flux;
                    if (flux > 0) active_candidate[destination_layer] = true;
                } else exported_candidate_g[species] += flux;
            }
            for (0..snow.salt_species_count) |species| {
                const source = source_layer * snow.salt_species_count + species;
                const flux = state.salt_amount_mol[source] * fraction;
                salt_candidate[source] -= flux;
                if (neighbor) |destination_cell| {
                    const destination_layer = try state.layerIndex(destination_cell, 0);
                    salt_candidate[destination_layer * snow.salt_species_count + species] += flux;
                    if (flux > 0) active_candidate[destination_layer] = true;
                } else exported_candidate_salt_mol[species] += flux;
            }
        }
    }
    for (candidate) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDriftCandidate;
    for (salt_candidate) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDriftCandidate;
    @memcpy(state.amount_g, candidate);
    @memcpy(state.salt_amount_mol, salt_candidate);
    @memcpy(state.active, active_candidate);
    @memcpy(exported_g, exported_candidate_g);
    @memcpy(exported_salt_mol, exported_candidate_salt_mol);
}

test "snow drift conserves ten species and activates receiving snow" {
    var state = try snow.State.init(std.testing.allocator, 2, 2);
    defer state.deinit();
    state.active[0] = true;
    @memset(try state.amounts(0, 0), 4);
    const east = [_]f64{ 0.5, 0 };
    const zero = [_]f64{ 0, 0 };
    const no = [_]bool{ false, false };
    var exported: [snow.species_count]f64 = undefined;
    var exported_salt: [snow.salt_species_count]f64 = undefined;
    state.salt_amount_mol[0] = 2;
    try route(std.testing.allocator, &state, 2, 1, &[_]f64{ 2, 0 }, &[_]f64{ 0.5, 0 }, .{ .east_m3 = &east, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero }, .{ .east_open = &no, .west_open = &no, .south_open = &no, .north_open = &no }, 0.5, &exported, &exported_salt);
    try std.testing.expect(state.active[2]);
    for (0..snow.species_count) |species| try std.testing.expectApproxEqAbs(@as(f64, 4), state.amount_g[species] + state.amount_g[2 * snow.species_count + species], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.salt_amount_mol[0] + state.salt_amount_mol[2 * snow.salt_species_count], 1e-14);
}

test "open snow boundary accounts exported mass" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.amount_g[0] = 8;
    const one = [_]f64{1};
    const zero = [_]f64{0};
    const yes = [_]bool{true};
    const no = [_]bool{false};
    var exported: [snow.species_count]f64 = undefined;
    var exported_salt: [snow.salt_species_count]f64 = undefined;
    state.salt_amount_mol[0] = 6;
    try route(std.testing.allocator, &state, 1, 1, &[_]f64{2}, &one, .{ .east_m3 = &one, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero }, .{ .east_open = &yes, .west_open = &no, .south_open = &no, .north_open = &no }, 1, &exported, &exported_salt);
    try std.testing.expectEqual(@as(f64, 4), state.amount_g[0]);
    try std.testing.expectEqual(@as(f64, 4), exported[0]);
    try std.testing.expectEqual(@as(f64, 3), state.salt_amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 3), exported_salt[0]);
}

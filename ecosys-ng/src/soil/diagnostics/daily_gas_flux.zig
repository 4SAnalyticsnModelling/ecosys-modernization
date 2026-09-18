const std = @import("std");
const gas = @import("../gas/transport.zig");
const RootSystem = @import("../../plant/root/plant_root_system.zig").State;
const root_disturbance = @import("../../plant/root/plant_root_disturbance.zig");
const output_binding = @import("hourly_output_binding.zig");

/// Heap-owned DAY accumulators for accepted soil/litter atmospheric exchange
/// plus source-signed root withdrawal. Values retain tracked-element units.
pub const RedistSurfaceGasIncrements = struct {
    carbon_surface_input_g_c: f64,
    carbon_subsurface_output_g_c: f64,
    oxygen_surface_input_g_o: f64,
    oxygen_subsurface_output_g_o: f64,
    hydrogen_surface_input_g_h: f64,
    hydrogen_subsurface_output_g_h: f64,
};

/// Accepted current-hour elemental exchange through atmospheric and physical
/// external gas faces. Signs are control-volume signs: positive is external
/// atmosphere/boundary to ecosystem, negative is ecosystem to external.
pub const HourlyElementActivity = struct {
    carbon_net_input_g_c: f64 = 0,
    oxygen_net_input_g_o: f64 = 0,
    nitrogen_net_input_g_n: f64 = 0,
    hydrogen_net_input_g_h: f64 = 0,

    pub fn add(self: HourlyElementActivity, other: HourlyElementActivity) !HourlyElementActivity {
        var result: HourlyElementActivity = .{};
        inline for (std.meta.fields(HourlyElementActivity)) |field|
            @field(result, field.name) = try addFinite(@field(self, field.name), @field(other, field.name));
        return result;
    }
};

/// Exact current-hour producer breakdown for one transported gas species.
/// Soil/litter/root terms retain their source signs. The accepted legacy
/// algebra is soil+litter boundary + source-signed root withdrawal - positive
/// atmosphere-to-root exchange. `net_exchange_g` is the value consumed by the
/// local/hourly elemental conservation gate.
pub const HourlySpeciesActivity = struct {
    soil_boundary_exchange_g: f64,
    litter_boundary_exchange_g: f64,
    root_withdrawal_exchange_g: f64,
    root_atmosphere_to_root_exchange_g: f64,
    net_exchange_g: f64,

    pub fn signedComponentSumG(self: HourlySpeciesActivity) !f64 {
        var total = try addFinite(
            self.soil_boundary_exchange_g,
            self.litter_boundary_exchange_g,
        );
        total = try addFinite(total, self.root_withdrawal_exchange_g);
        return addFinite(total, -self.root_atmosphere_to_root_exchange_g);
    }

    /// Normally zero. A nonzero finite value can only be the f64 reduction-
    /// order difference between the legacy litter-first boundary sum and this
    /// independently regrouped component diagnostic.
    pub fn componentClosureResidualG(self: HourlySpeciesActivity) !f64 {
        return addFinite(self.net_exchange_g, -(try self.signedComponentSumG()));
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    soil_litter_boundary_mass_g_by_cell_and_species: []f64,
    tracked_element_mass_g_by_cell_and_species: []f64,
    redist_carbon_surface_input_g_c_by_cell: []f64,
    redist_carbon_subsurface_output_g_c_by_cell: []f64,
    redist_oxygen_surface_input_g_o_by_cell: []f64,
    redist_oxygen_subsurface_output_g_o_by_cell: []f64,
    redist_hydrogen_surface_input_g_h_by_cell: []f64,
    redist_hydrogen_subsurface_output_g_h_by_cell: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroDailyGasFluxCells;
        const count = try std.math.mul(usize, cell_count, gas.species_count);
        const boundary = try allocator.alloc(f64, count);
        errdefer allocator.free(boundary);
        const combined = try allocator.alloc(f64, count);
        const redist_carbon_surface_input = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(redist_carbon_surface_input);
        const redist_carbon_subsurface_output = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(redist_carbon_subsurface_output);
        const redist_oxygen_surface_input = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(redist_oxygen_surface_input);
        const redist_oxygen_subsurface_output = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(redist_oxygen_subsurface_output);
        const redist_hydrogen_surface_input = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(redist_hydrogen_surface_input);
        const redist_hydrogen_subsurface_output = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(redist_hydrogen_subsurface_output);
        @memset(boundary, 0);
        @memset(combined, 0);
        @memset(redist_carbon_surface_input, 0);
        @memset(redist_carbon_subsurface_output, 0);
        @memset(redist_oxygen_surface_input, 0);
        @memset(redist_oxygen_subsurface_output, 0);
        @memset(redist_hydrogen_surface_input, 0);
        @memset(redist_hydrogen_subsurface_output, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .soil_litter_boundary_mass_g_by_cell_and_species = boundary,
            .tracked_element_mass_g_by_cell_and_species = combined,
            .redist_carbon_surface_input_g_c_by_cell = redist_carbon_surface_input,
            .redist_carbon_subsurface_output_g_c_by_cell = redist_carbon_subsurface_output,
            .redist_oxygen_surface_input_g_o_by_cell = redist_oxygen_surface_input,
            .redist_oxygen_subsurface_output_g_o_by_cell = redist_oxygen_subsurface_output,
            .redist_hydrogen_surface_input_g_h_by_cell = redist_hydrogen_surface_input,
            .redist_hydrogen_subsurface_output_g_h_by_cell = redist_hydrogen_subsurface_output,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.soil_litter_boundary_mass_g_by_cell_and_species);
        self.allocator.free(self.tracked_element_mass_g_by_cell_and_species);
        self.allocator.free(self.redist_carbon_surface_input_g_c_by_cell);
        self.allocator.free(self.redist_carbon_subsurface_output_g_c_by_cell);
        self.allocator.free(self.redist_oxygen_surface_input_g_o_by_cell);
        self.allocator.free(self.redist_oxygen_subsurface_output_g_o_by_cell);
        self.allocator.free(self.redist_hydrogen_surface_input_g_h_by_cell);
        self.allocator.free(self.redist_hydrogen_subsurface_output_g_h_by_cell);
        self.* = undefined;
    }

    pub fn reset(self: *State) void {
        @memset(self.soil_litter_boundary_mass_g_by_cell_and_species, 0);
        @memset(self.tracked_element_mass_g_by_cell_and_species, 0);
        @memset(self.redist_carbon_surface_input_g_c_by_cell, 0);
        @memset(self.redist_carbon_subsurface_output_g_c_by_cell, 0);
        @memset(self.redist_oxygen_surface_input_g_o_by_cell, 0);
        @memset(self.redist_oxygen_subsurface_output_g_o_by_cell, 0);
        @memset(self.redist_hydrogen_surface_input_g_h_by_cell, 0);
        @memset(self.redist_hydrogen_subsurface_output_g_h_by_cell, 0);
    }

    pub fn accumulateRedistSurfaceGasHour(
        self: *State,
        cell: usize,
        carbon_surface_input_g_c: f64,
        carbon_subsurface_output_g_c: f64,
        oxygen_surface_input_g_o: f64,
        oxygen_subsurface_output_g_o: f64,
        hydrogen_surface_input_g_h: f64,
        hydrogen_subsurface_output_g_h: f64,
    ) !void {
        if (cell >= self.cell_count) return error.DailyGasFluxCellOutOfBounds;
        const values = .{
            carbon_surface_input_g_c,
            carbon_subsurface_output_g_c,
            oxygen_surface_input_g_o,
            oxygen_subsurface_output_g_o,
            hydrogen_surface_input_g_h,
            hydrogen_subsurface_output_g_h,
        };
        inline for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteDailyGasFlux;

        self.redist_carbon_surface_input_g_c_by_cell[cell] += carbon_surface_input_g_c;
        self.redist_carbon_subsurface_output_g_c_by_cell[cell] += carbon_subsurface_output_g_c;
        self.redist_oxygen_surface_input_g_o_by_cell[cell] += oxygen_surface_input_g_o;
        self.redist_oxygen_subsurface_output_g_o_by_cell[cell] += oxygen_subsurface_output_g_o;
        self.redist_hydrogen_surface_input_g_h_by_cell[cell] += hydrogen_surface_input_g_h;
        self.redist_hydrogen_subsurface_output_g_h_by_cell[cell] += hydrogen_subsurface_output_g_h;
    }

    pub fn getRedistSurfaceGasTotals(self: *const State) !RedistSurfaceGasIncrements {
        if (self.cell_count == 0) return error.ZeroDailyGasFluxCells;
        var totals = RedistSurfaceGasIncrements{
            .carbon_surface_input_g_c = 0,
            .carbon_subsurface_output_g_c = 0,
            .oxygen_surface_input_g_o = 0,
            .oxygen_subsurface_output_g_o = 0,
            .hydrogen_surface_input_g_h = 0,
            .hydrogen_subsurface_output_g_h = 0,
        };
        for (0..self.cell_count) |cell| {
            totals.carbon_surface_input_g_c = addFinite(totals.carbon_surface_input_g_c, self.redist_carbon_surface_input_g_c_by_cell[cell]) catch return error.NonFiniteDailyGasFlux;
            totals.carbon_subsurface_output_g_c = addFinite(totals.carbon_subsurface_output_g_c, self.redist_carbon_subsurface_output_g_c_by_cell[cell]) catch return error.NonFiniteDailyGasFlux;
            totals.oxygen_surface_input_g_o = addFinite(totals.oxygen_surface_input_g_o, self.redist_oxygen_surface_input_g_o_by_cell[cell]) catch return error.NonFiniteDailyGasFlux;
            totals.oxygen_subsurface_output_g_o = addFinite(totals.oxygen_subsurface_output_g_o, self.redist_oxygen_subsurface_output_g_o_by_cell[cell]) catch return error.NonFiniteDailyGasFlux;
            totals.hydrogen_surface_input_g_h = addFinite(totals.hydrogen_surface_input_g_h, self.redist_hydrogen_surface_input_g_h_by_cell[cell]) catch return error.NonFiniteDailyGasFlux;
            totals.hydrogen_subsurface_output_g_h = addFinite(totals.hydrogen_subsurface_output_g_h, self.redist_hydrogen_subsurface_output_g_h_by_cell[cell]) catch return error.NonFiniteDailyGasFlux;
        }
        return totals;
    }

    pub fn accumulateHour(
        self: *State,
        roots: ?*const RootSystem,
        plant_species_count: usize,
        soil_layer_count: usize,
        soil_atmospheric_flux_g_per_h: []const f64,
        litter_atmospheric_flux_g_per_h: []const f64,
    ) !void {
        if (soil_layer_count == 0 or soil_atmospheric_flux_g_per_h.len != self.cell_count * soil_layer_count * gas.species_count or litter_atmospheric_flux_g_per_h.len != self.cell_count * gas.species_count) return error.DailyGasFluxDimensionMismatch;
        // Validate the complete grid before changing any daily accumulator.
        for (0..self.cell_count) |cell| {
            const withdrawal = if (roots) |root_state|
                try root_disturbance.rootGasWithdrawalForCell(root_state, cell, plant_species_count)
            else
                root_disturbance.CellRootGasWithdrawal{};
            for (0..gas.species_count) |species_index| {
                const species: gas.Species = @enumFromInt(species_index);
                const root_atmosphere_exchange = if (roots) |root_state| try rootAtmosphereExchangeGPerH(root_state, cell, plant_species_count, species) else 0;
                const boundary_increment = try boundaryHourIncrement(cell, soil_layer_count, species, soil_atmospheric_flux_g_per_h, litter_atmospheric_flux_g_per_h);
                const increment = try combinedHourIncrement(species, withdrawal, root_atmosphere_exchange, boundary_increment);
                const index = cell * gas.species_count + species_index;
                const next_boundary = self.soil_litter_boundary_mass_g_by_cell_and_species[index] + boundary_increment;
                const next = self.tracked_element_mass_g_by_cell_and_species[index] + increment;
                if (!std.math.isFinite(next_boundary) or !std.math.isFinite(next)) return error.NonFiniteDailyGasFlux;
            }
        }
        for (0..self.cell_count) |cell| {
            const withdrawal = if (roots) |root_state|
                root_disturbance.rootGasWithdrawalForCell(root_state, cell, plant_species_count) catch unreachable
            else
                root_disturbance.CellRootGasWithdrawal{};
            for (0..gas.species_count) |species_index| {
                const species: gas.Species = @enumFromInt(species_index);
                const root_atmosphere_exchange = if (roots) |root_state| rootAtmosphereExchangeGPerH(root_state, cell, plant_species_count, species) catch unreachable else 0;
                const boundary_increment = boundaryHourIncrement(cell, soil_layer_count, species, soil_atmospheric_flux_g_per_h, litter_atmospheric_flux_g_per_h) catch unreachable;
                const increment = combinedHourIncrement(species, withdrawal, root_atmosphere_exchange, boundary_increment) catch unreachable;
                const index = cell * gas.species_count + species_index;
                self.soil_litter_boundary_mass_g_by_cell_and_species[index] += boundary_increment;
                self.tracked_element_mass_g_by_cell_and_species[index] += increment;
            }
        }
    }

    /// Reconstructs the exact producer values consumed by `accumulateHour`
    /// without consulting or differencing cumulative DAY arrays.
    pub fn currentHourElementActivityForCell(
        self: *const State,
        roots: ?*const RootSystem,
        plant_species_count: usize,
        soil_layer_count: usize,
        soil_atmospheric_flux_g_per_h: []const f64,
        litter_atmospheric_flux_g_per_h: []const f64,
        cell: usize,
    ) !HourlyElementActivity {
        if (cell >= self.cell_count or soil_layer_count == 0 or
            soil_atmospheric_flux_g_per_h.len != self.cell_count * soil_layer_count * gas.species_count or
            litter_atmospheric_flux_g_per_h.len != self.cell_count * gas.species_count)
            return error.DailyGasFluxDimensionMismatch;
        const withdrawal = if (roots) |root_state|
            try root_disturbance.rootGasWithdrawalForCell(root_state, cell, plant_species_count)
        else
            root_disturbance.CellRootGasWithdrawal{};
        var result: HourlyElementActivity = .{};
        for (0..gas.species_count) |species_index| {
            const species: gas.Species = @enumFromInt(species_index);
            const root_atmosphere_exchange = if (roots) |root_state|
                try rootAtmosphereExchangeGPerH(root_state, cell, plant_species_count, species)
            else
                0;
            const species_activity = try speciesActivityFromProducers(
                cell,
                soil_layer_count,
                species,
                soil_atmospheric_flux_g_per_h,
                litter_atmospheric_flux_g_per_h,
                withdrawal,
                root_atmosphere_exchange,
            );
            switch (species) {
                .carbon_dioxide, .methane => result.carbon_net_input_g_c = try addFinite(result.carbon_net_input_g_c, species_activity.net_exchange_g),
                .oxygen => result.oxygen_net_input_g_o = try addFinite(result.oxygen_net_input_g_o, species_activity.net_exchange_g),
                .nitrogen, .nitrous_oxide, .ammonia => result.nitrogen_net_input_g_n = try addFinite(result.nitrogen_net_input_g_n, species_activity.net_exchange_g),
                .hydrogen => result.hydrogen_net_input_g_h = try addFinite(result.hydrogen_net_input_g_h, species_activity.net_exchange_g),
            }
        }
        return result;
    }

    /// Exposes the exact four-term producer provenance used by the hourly
    /// conservation reconstruction without consulting cumulative DAY arrays.
    pub fn currentHourSpeciesActivityForCell(
        self: *const State,
        roots: ?*const RootSystem,
        plant_species_count: usize,
        soil_layer_count: usize,
        soil_atmospheric_flux_g_per_h: []const f64,
        litter_atmospheric_flux_g_per_h: []const f64,
        cell: usize,
        species: gas.Species,
    ) !HourlySpeciesActivity {
        if (cell >= self.cell_count or soil_layer_count == 0 or
            soil_atmospheric_flux_g_per_h.len != self.cell_count * soil_layer_count * gas.species_count or
            litter_atmospheric_flux_g_per_h.len != self.cell_count * gas.species_count)
            return error.DailyGasFluxDimensionMismatch;
        const withdrawal = if (roots) |root_state|
            try root_disturbance.rootGasWithdrawalForCell(
                root_state,
                cell,
                plant_species_count,
            )
        else
            root_disturbance.CellRootGasWithdrawal{};
        const root_atmosphere_exchange = if (roots) |root_state|
            try rootAtmosphereExchangeGPerH(
                root_state,
                cell,
                plant_species_count,
                species,
            )
        else
            0;
        return speciesActivityFromProducers(
            cell,
            soil_layer_count,
            species,
            soil_atmospheric_flux_g_per_h,
            litter_atmospheric_flux_g_per_h,
            withdrawal,
            root_atmosphere_exchange,
        );
    }

    /// Retained production adapter for the nitrogen-only state_update. A1 must
    /// replace its call with `accumulateSubsurfacePhysicalBoundaryHour`; the two
    /// entry points must never be invoked for the same accepted transport step.
    pub fn accumulateSubsurfaceNitrogenBoundaryHour(
        self: *State,
        soil_layer_capacity: usize,
        active_soil_layer_count: []const usize,
        subsurface_flux_g_per_h: []const f64,
    ) !void {
        try self.accumulateSubsurfaceBoundarySpeciesHour(
            soil_layer_capacity,
            active_soil_layer_count,
            subsurface_flux_g_per_h,
            &.{ .nitrogen, .nitrous_oxide, .ammonia },
        );
    }

    /// Adds accepted tracked-element gas exchange through physical external
    /// subsurface faces. Values are signed extensive grams per accepted hour:
    /// positive is external domain to ecosystem. Internal/lateral faces and
    /// inactive capacity slots are excluded by their transport/state owners.
    /// This publishes O2 and H2 into the same DAY storage that the landscape
    /// boundary ledger already direction-splits, not into the REDIST diagnostic
    /// fields. Carbon uses the dedicated daily-carbon drainage owner.
    pub fn accumulateSubsurfacePhysicalBoundaryHour(
        self: *State,
        soil_layer_capacity: usize,
        active_soil_layer_count: []const usize,
        subsurface_flux_g_per_h: []const f64,
    ) !void {
        try self.accumulateSubsurfaceBoundarySpeciesHour(
            soil_layer_capacity,
            active_soil_layer_count,
            subsurface_flux_g_per_h,
            &.{ .nitrogen, .nitrous_oxide, .ammonia, .oxygen, .hydrogen },
        );
    }

    /// Reconstructs the complete current-hour physical subsurface-boundary
    /// element exchange for the hourly conservation gate, excluding inactive
    /// capacity slots and every internal/lateral face. Carbon is included here
    /// even though the cumulative DAY owner above deliberately leaves it to the
    /// dedicated daily-carbon drainage owner; the hourly gate must account the
    /// CO2/CH4 storage that the same accepted dry-gas transaction exported.
    pub fn currentHourSubsurfacePhysicalActivityForCell(
        self: *const State,
        soil_layer_capacity: usize,
        active_soil_layer_count: []const usize,
        subsurface_flux_g_per_h: []const f64,
        cell: usize,
    ) !HourlyElementActivity {
        const cell_layer_count = std.math.mul(usize, self.cell_count, soil_layer_capacity) catch
            return error.DailyGasFluxDimensionMismatch;
        const expected_flux_count = std.math.mul(usize, cell_layer_count, gas.species_count) catch
            return error.DailyGasFluxDimensionMismatch;
        if (cell >= self.cell_count or soil_layer_capacity == 0 or
            active_soil_layer_count.len != self.cell_count or
            active_soil_layer_count[cell] == 0 or active_soil_layer_count[cell] > soil_layer_capacity or
            subsurface_flux_g_per_h.len != expected_flux_count)
            return error.DailyGasFluxDimensionMismatch;
        var result: HourlyElementActivity = .{};
        inline for (.{ gas.Species.carbon_dioxide, gas.Species.methane, gas.Species.nitrogen, gas.Species.nitrous_oxide, gas.Species.ammonia, gas.Species.oxygen, gas.Species.hydrogen }) |species| {
            const increment = try subsurfaceBoundaryIncrement(
                cell,
                soil_layer_capacity,
                active_soil_layer_count[cell],
                subsurface_flux_g_per_h,
                species,
            );
            switch (species) {
                .carbon_dioxide, .methane => result.carbon_net_input_g_c = try addFinite(result.carbon_net_input_g_c, increment),
                .nitrogen, .nitrous_oxide, .ammonia => result.nitrogen_net_input_g_n = try addFinite(result.nitrogen_net_input_g_n, increment),
                .oxygen => result.oxygen_net_input_g_o = try addFinite(result.oxygen_net_input_g_o, increment),
                .hydrogen => result.hydrogen_net_input_g_h = try addFinite(result.hydrogen_net_input_g_h, increment),
            }
        }
        return result;
    }

    fn accumulateSubsurfaceBoundarySpeciesHour(
        self: *State,
        soil_layer_capacity: usize,
        active_soil_layer_count: []const usize,
        subsurface_flux_g_per_h: []const f64,
        species_values: []const gas.Species,
    ) !void {
        const cell_layer_count = std.math.mul(usize, self.cell_count, soil_layer_capacity) catch
            return error.DailyGasFluxDimensionMismatch;
        const expected_flux_count = std.math.mul(usize, cell_layer_count, gas.species_count) catch
            return error.DailyGasFluxDimensionMismatch;
        if (soil_layer_capacity == 0 or active_soil_layer_count.len != self.cell_count or
            subsurface_flux_g_per_h.len != expected_flux_count)
            return error.DailyGasFluxDimensionMismatch;
        for (active_soil_layer_count) |active|
            if (active == 0 or active > soil_layer_capacity) return error.DailyGasFluxDimensionMismatch;
        for (subsurface_flux_g_per_h) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteDailyGasFlux;

        // Preflight every sum and destination before publishing any species or
        // cell, so a late overflow leaves both accepted DAY arrays untouched.
        for (0..self.cell_count) |cell|
            for (species_values) |species_value| {
                const increment_g = try subsurfaceBoundaryIncrement(
                    cell,
                    soil_layer_capacity,
                    active_soil_layer_count[cell],
                    subsurface_flux_g_per_h,
                    species_value,
                );
                const index = cell * gas.species_count + @intFromEnum(species_value);
                _ = try addFinite(self.soil_litter_boundary_mass_g_by_cell_and_species[index], increment_g);
                _ = try addFinite(self.tracked_element_mass_g_by_cell_and_species[index], increment_g);
            };

        for (0..self.cell_count) |cell|
            for (species_values) |species_value| {
                const increment_g = subsurfaceBoundaryIncrement(
                    cell,
                    soil_layer_capacity,
                    active_soil_layer_count[cell],
                    subsurface_flux_g_per_h,
                    species_value,
                ) catch unreachable;
                const index = cell * gas.species_count + @intFromEnum(species_value);
                self.soil_litter_boundary_mass_g_by_cell_and_species[index] = addFinite(
                    self.soil_litter_boundary_mass_g_by_cell_and_species[index],
                    increment_g,
                ) catch unreachable;
                self.tracked_element_mass_g_by_cell_and_species[index] = addFinite(
                    self.tracked_element_mass_g_by_cell_and_species[index],
                    increment_g,
                ) catch unreachable;
            };
    }

    pub fn get(self: *const State, cell: usize, species: gas.Species) !f64 {
        if (cell >= self.cell_count) return error.DailyGasFluxCellOutOfBounds;
        return self.tracked_element_mass_g_by_cell_and_species[cell * gas.species_count + @intFromEnum(species)];
    }

    /// Exact DAY `UCO2G`, `UCH4G`, `UOXYG`, `UH2GG`, ... owner: cumulative
    /// snowpack+litter+soil exchange only. Root withdrawal remains available
    /// through `get` for consumers that explicitly require the combined
    /// ecosystem exchange.
    pub fn getSoilLitterBoundary(self: *const State, cell: usize, species: gas.Species) !f64 {
        if (cell >= self.cell_count) return error.DailyGasFluxCellOutOfBounds;
        return self.soil_litter_boundary_mass_g_by_cell_and_species[cell * gas.species_count + @intFromEnum(species)];
    }
};

test "external subsurface nitrogen excludes inactive capacity layers" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var flux = [_]f64{0} ** (2 * gas.species_count);
    flux[@intFromEnum(gas.Species.nitrogen)] = 3;
    flux[gas.species_count + @intFromEnum(gas.Species.nitrogen)] = -1;
    try state.accumulateSubsurfaceNitrogenBoundaryHour(2, &.{1}, &flux);
    try std.testing.expectEqual(@as(f64, 3), try state.getSoilLitterBoundary(0, .nitrogen));
    try std.testing.expectEqual(@as(f64, 3), try state.get(0, .nitrogen));
}

test "accepted external subsurface oxygen and hydrogen exclude inactive capacity slots" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var flux = [_]f64{0} ** (2 * gas.species_count);
    const oxygen = @intFromEnum(gas.Species.oxygen);
    const hydrogen = @intFromEnum(gas.Species.hydrogen);
    flux[oxygen] = 6.25;
    flux[hydrogen] = -0.125;
    flux[gas.species_count + oxygen] = -91.0;
    flux[gas.species_count + hydrogen] = 73.0;

    try state.accumulateSubsurfacePhysicalBoundaryHour(2, &.{1}, &flux);

    try std.testing.expectEqual(@as(f64, 6.25), try state.getSoilLitterBoundary(0, .oxygen));
    try std.testing.expectEqual(@as(f64, 6.25), try state.get(0, .oxygen));
    try std.testing.expectEqual(@as(f64, -0.125), try state.getSoilLitterBoundary(0, .hydrogen));
    try std.testing.expectEqual(@as(f64, -0.125), try state.get(0, .hydrogen));
}

test "accepted external subsurface oxygen retains signed algebraic hourly sum" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var input_flux = [_]f64{0} ** gas.species_count;
    var output_flux = [_]f64{0} ** gas.species_count;
    const oxygen = @intFromEnum(gas.Species.oxygen);
    input_flux[oxygen] = 9.5;
    output_flux[oxygen] = -4.0;

    try state.accumulateSubsurfacePhysicalBoundaryHour(1, &.{1}, &input_flux);
    try state.accumulateSubsurfacePhysicalBoundaryHour(1, &.{1}, &output_flux);

    try std.testing.expectEqual(@as(f64, 5.5), try state.getSoilLitterBoundary(0, .oxygen));
    try std.testing.expectEqual(@as(f64, 5.5), try state.get(0, .oxygen));
    try std.testing.expectEqual(@as(f64, 0), state.redist_oxygen_surface_input_g_o_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 0), state.redist_oxygen_subsurface_output_g_o_by_cell[0]);
}

test "accepted external subsurface physical state_update is atomic on late overflow" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const nitrogen = @intFromEnum(gas.Species.nitrogen);
    const oxygen = @intFromEnum(gas.Species.oxygen);
    state.soil_litter_boundary_mass_g_by_cell_and_species[oxygen] = std.math.floatMax(f64);
    state.tracked_element_mass_g_by_cell_and_species[oxygen] = std.math.floatMax(f64);
    const boundary_before = state.soil_litter_boundary_mass_g_by_cell_and_species[oxygen];
    const tracked_before = state.tracked_element_mass_g_by_cell_and_species[oxygen];
    var flux = [_]f64{0} ** gas.species_count;
    flux[nitrogen] = 7;
    flux[oxygen] = std.math.floatMax(f64);

    try std.testing.expectError(
        error.NonFiniteDailyGasFlux,
        state.accumulateSubsurfacePhysicalBoundaryHour(1, &.{1}, &flux),
    );

    try std.testing.expectEqual(@as(f64, 0), try state.getSoilLitterBoundary(0, .nitrogen));
    try std.testing.expectEqual(@as(f64, 0), try state.get(0, .nitrogen));
    try std.testing.expectEqual(boundary_before, try state.getSoilLitterBoundary(0, .oxygen));
    try std.testing.expectEqual(tracked_before, try state.get(0, .oxygen));
}

fn addFinite(first: f64, second: f64) !f64 {
    const result = first + second;
    if (!std.math.isFinite(result)) return error.NonFiniteDailyGasFlux;
    return result;
}

fn subsurfaceBoundaryIncrement(
    cell: usize,
    soil_layer_capacity: usize,
    active_soil_layer_count: usize,
    subsurface_flux_g_per_h: []const f64,
    species_value: gas.Species,
) !f64 {
    const first_layer = cell * soil_layer_capacity;
    const species = @intFromEnum(species_value);
    var increment_g: f64 = 0;
    for (first_layer..first_layer + active_soil_layer_count) |layer|
        increment_g = try addFinite(
            increment_g,
            subsurface_flux_g_per_h[layer * gas.species_count + species],
        );
    return increment_g;
}

fn boundaryHourIncrement(cell: usize, soil_layer_count: usize, species: gas.Species, soil_flux: []const f64, litter_flux: []const f64) !f64 {
    return output_binding.gasBoundaryExchangeG(soil_flux, litter_flux, cell * soil_layer_count, soil_layer_count, cell, species);
}

fn speciesActivityFromProducers(
    cell: usize,
    soil_layer_count: usize,
    species: gas.Species,
    soil_flux: []const f64,
    litter_flux: []const f64,
    withdrawal: root_disturbance.CellRootGasWithdrawal,
    root_atmosphere_exchange_g_per_h: f64,
) !HourlySpeciesActivity {
    const boundary = try output_binding.gasBoundaryExchangeComponentsG(
        soil_flux,
        litter_flux,
        cell * soil_layer_count,
        soil_layer_count,
        cell,
        species,
    );
    const root_withdrawal_exchange_g = rootWithdrawalForSpecies(
        species,
        withdrawal,
    );
    const net_exchange_g = try combinedHourIncrement(
        species,
        withdrawal,
        root_atmosphere_exchange_g_per_h,
        boundary.total_exchange_g,
    );
    return .{
        .soil_boundary_exchange_g = boundary.soil_exchange_g,
        .litter_boundary_exchange_g = boundary.litter_exchange_g,
        .root_withdrawal_exchange_g = root_withdrawal_exchange_g,
        .root_atmosphere_to_root_exchange_g = root_atmosphere_exchange_g_per_h,
        .net_exchange_g = net_exchange_g,
    };
}

fn rootWithdrawalForSpecies(
    species: gas.Species,
    withdrawal: root_disturbance.CellRootGasWithdrawal,
) f64 {
    return switch (species) {
        .carbon_dioxide => withdrawal.carbon_dioxide_g_c_per_h,
        .oxygen => withdrawal.oxygen_g_o_per_h,
        .methane => withdrawal.methane_g_c_per_h,
        .nitrous_oxide => withdrawal.nitrous_oxide_g_n_per_h,
        .ammonia => withdrawal.ammonia_g_n_per_h,
        .hydrogen => withdrawal.hydrogen_g_h_per_h,
        .nitrogen => 0,
    };
}

fn combinedHourIncrement(species: gas.Species, withdrawal: root_disturbance.CellRootGasWithdrawal, root_atmosphere_exchange_g_per_h: f64, boundary: f64) !f64 {
    const root_flux = rootWithdrawalForSpecies(species, withdrawal);
    // Accepted root flux is positive atmosphere -> root, whereas DAY gas
    // output is positive ecosystem -> atmosphere.
    const result = boundary + root_flux - root_atmosphere_exchange_g_per_h;
    if (!std.math.isFinite(result)) return error.NonFiniteDailyGasFlux;
    return result;
}

fn rootAtmosphereExchangeGPerH(roots: *const RootSystem, cell: usize, plant_species_count: usize, species: gas.Species) !f64 {
    if (plant_species_count == 0 or roots.plant_count % plant_species_count != 0 or cell >= roots.plant_count / plant_species_count)
        return error.DailyGasFluxDimensionMismatch;
    const transaction_gas: ?usize = switch (species) {
        .carbon_dioxide => 0,
        .methane => 1,
        .nitrous_oxide => 2,
        .ammonia => 3,
        .hydrogen => 4,
        .oxygen => 5,
        .nitrogen => null,
    };
    const gas_slot = transaction_gas orelse return 0;
    var total: f64 = 0;
    const first_plant = cell * plant_species_count;
    for (first_plant..first_plant + plant_species_count) |plant|
        for (0..@import("../../plant/root/plant_root_system.zig").biological_domain_count) |domain|
            for (0..roots.soil_layer_count) |layer| {
                const root = try roots.layerIndex(plant, domain, layer);
                total += roots.atmosphere_to_root_gas_exchange_g_per_h[root * @import("../../plant/root/plant_root_system.zig").transported_root_gas_count + gas_slot];
            };
    if (!std.math.isFinite(total)) return error.NonFiniteDailyGasFlux;
    return total;
}

test "DAY gas accumulator combines boundaries and runtime root species" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var roots = try RootSystem.init(std.testing.allocator, 7, 2, 1);
    defer roots.deinit();
    roots.withdrawal_carbon_dioxide_loss_g_c_per_h[6] = -2;
    roots.withdrawal_hydrogen_loss_g_h_per_h[0] = -0.5;
    const carbon_root = try roots.layerIndex(6, 0, 0);
    const hydrogen_root = try roots.layerIndex(0, 0, 0);
    roots.atmosphere_to_root_gas_exchange_g_per_h[carbon_root * 6] = 0.75;
    roots.atmosphere_to_root_gas_exchange_g_per_h[hydrogen_root * 6 + 4] = 0.25;
    var soil = [_]f64{0} ** (2 * gas.species_count);
    var litter = [_]f64{0} ** gas.species_count;
    soil[@intFromEnum(gas.Species.carbon_dioxide)] = 3;
    litter[@intFromEnum(gas.Species.carbon_dioxide)] = 1;
    litter[@intFromEnum(gas.Species.hydrogen)] = 1.5;
    try state.accumulateHour(&roots, 7, 2, &soil, &litter);
    try state.accumulateHour(&roots, 7, 2, &soil, &litter);
    try std.testing.expectEqual(@as(f64, 8), try state.getSoilLitterBoundary(0, .carbon_dioxide));
    try std.testing.expectEqual(@as(f64, 3), try state.getSoilLitterBoundary(0, .hydrogen));
    try std.testing.expectEqual(@as(f64, 2.5), try state.get(0, .carbon_dioxide));
    try std.testing.expectEqual(@as(f64, 1.5), try state.get(0, .hydrogen));
    state.reset();
    try std.testing.expectEqual(@as(f64, 0), try state.getSoilLitterBoundary(0, .carbon_dioxide));
    try std.testing.expectEqual(@as(f64, 0), try state.get(0, .carbon_dioxide));
}

test "current-hour gas activity is cell local and matches producer sign algebra" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var roots = try RootSystem.init(std.testing.allocator, 2, 2, 1);
    defer roots.deinit();
    roots.withdrawal_carbon_dioxide_loss_g_c_per_h[1] = -2;
    roots.withdrawal_hydrogen_loss_g_h_per_h[0] = -0.5;
    const carbon_root = try roots.layerIndex(1, 0, 0);
    const hydrogen_root = try roots.layerIndex(0, 0, 0);
    roots.atmosphere_to_root_gas_exchange_g_per_h[carbon_root * 6] = 0.75;
    roots.atmosphere_to_root_gas_exchange_g_per_h[hydrogen_root * 6 + 4] = 0.25;
    var soil = [_]f64{0} ** (2 * gas.species_count);
    var litter = [_]f64{0} ** gas.species_count;
    soil[@intFromEnum(gas.Species.carbon_dioxide)] = 3;
    litter[@intFromEnum(gas.Species.carbon_dioxide)] = 1;
    litter[@intFromEnum(gas.Species.hydrogen)] = 1.5;

    const activity = try state.currentHourElementActivityForCell(
        &roots,
        2,
        2,
        &soil,
        &litter,
        0,
    );
    try std.testing.expectEqual(@as(f64, 1.25), activity.carbon_net_input_g_c);
    try std.testing.expectEqual(@as(f64, 0.75), activity.hydrogen_net_input_g_h);
    try std.testing.expectEqual(@as(f64, 0), activity.oxygen_net_input_g_o);
    try std.testing.expectEqual(@as(f64, 0), activity.nitrogen_net_input_g_n);
}

test "componentwise hourly ammonia accounting closes locally and matches nitrogen activity" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    var roots = try RootSystem.init(std.testing.allocator, 2, 2, 1);
    defer roots.deinit();

    roots.withdrawal_ammonia_loss_g_n_per_h[0] = -0.25;
    const cell_zero_root = try roots.layerIndex(0, 0, 0);
    roots.atmosphere_to_root_gas_exchange_g_per_h[
        cell_zero_root * @import("../../plant/root/plant_root_system.zig").transported_root_gas_count + 3
    ] = 0.125;
    // Large cell-one terms prove that the component diagnostic and elemental
    // conservation reconstruction do not hide cancellation across cells.
    roots.withdrawal_ammonia_loss_g_n_per_h[1] = -50;
    const cell_one_root = try roots.layerIndex(1, 0, 0);
    roots.atmosphere_to_root_gas_exchange_g_per_h[
        cell_one_root * @import("../../plant/root/plant_root_system.zig").transported_root_gas_count + 3
    ] = 25;

    var soil = [_]f64{0} ** (4 * gas.species_count);
    var litter = [_]f64{0} ** (2 * gas.species_count);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    const nitrogen = @intFromEnum(gas.Species.nitrogen);
    soil[ammonia] = 1.5;
    soil[gas.species_count + ammonia] = -0.25;
    litter[ammonia] = 0.5;
    soil[nitrogen] = 2;
    litter[nitrogen] = 0.25;
    soil[2 * gas.species_count + ammonia] = 100;
    litter[gas.species_count + ammonia] = 200;

    const ammonia_activity = try state.currentHourSpeciesActivityForCell(
        &roots,
        1,
        2,
        &soil,
        &litter,
        0,
        .ammonia,
    );
    try std.testing.expectEqual(@as(f64, 1.25), ammonia_activity.soil_boundary_exchange_g);
    try std.testing.expectEqual(@as(f64, 0.5), ammonia_activity.litter_boundary_exchange_g);
    try std.testing.expectEqual(@as(f64, -0.25), ammonia_activity.root_withdrawal_exchange_g);
    try std.testing.expectEqual(@as(f64, 0.125), ammonia_activity.root_atmosphere_to_root_exchange_g);
    try std.testing.expectEqual(@as(f64, 1.375), ammonia_activity.net_exchange_g);
    try std.testing.expectEqual(@as(f64, 1.375), try ammonia_activity.signedComponentSumG());
    try std.testing.expectEqual(@as(f64, 0), try ammonia_activity.componentClosureResidualG());

    const hourly = try state.currentHourElementActivityForCell(
        &roots,
        1,
        2,
        &soil,
        &litter,
        0,
    );
    try std.testing.expectEqual(@as(f64, 3.625), hourly.nitrogen_net_input_g_n);

    try state.accumulateHour(&roots, 1, 2, &soil, &litter);
    try std.testing.expectEqual(
        ammonia_activity.net_exchange_g,
        try state.get(0, .ammonia),
    );
    const accumulated_nitrogen =
        (try state.get(0, .nitrogen)) +
        (try state.get(0, .nitrous_oxide)) +
        (try state.get(0, .ammonia));
    try std.testing.expectEqual(
        hourly.nitrogen_net_input_g_n,
        accumulated_nitrogen,
    );
}

test "current-hour subsurface gas activity excludes inactive capacity slots" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var flux = [_]f64{0} ** (2 * gas.species_count);
    flux[@intFromEnum(gas.Species.oxygen)] = 4;
    flux[@intFromEnum(gas.Species.carbon_dioxide)] = -2;
    flux[@intFromEnum(gas.Species.methane)] = 0.75;
    flux[@intFromEnum(gas.Species.nitrogen)] = -1;
    flux[@intFromEnum(gas.Species.nitrous_oxide)] = 2.5;
    flux[@intFromEnum(gas.Species.hydrogen)] = -3.25;
    flux[gas.species_count + @intFromEnum(gas.Species.oxygen)] = 99;
    flux[gas.species_count + @intFromEnum(gas.Species.carbon_dioxide)] = 88;
    flux[gas.species_count + @intFromEnum(gas.Species.methane)] = -66;
    flux[gas.species_count + @intFromEnum(gas.Species.ammonia)] = 77;
    flux[gas.species_count + @intFromEnum(gas.Species.hydrogen)] = 55;

    const activity = try state.currentHourSubsurfacePhysicalActivityForCell(
        2,
        &.{1},
        &flux,
        0,
    );
    try std.testing.expectEqual(@as(f64, 4), activity.oxygen_net_input_g_o);
    try std.testing.expectEqual(@as(f64, 1.5), activity.nitrogen_net_input_g_n);
    try std.testing.expectEqual(@as(f64, -1.25), activity.carbon_net_input_g_c);
    try std.testing.expectEqual(@as(f64, -3.25), activity.hydrogen_net_input_g_h);
}

test "failed DAY gas accumulation leaves every cell unchanged" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.tracked_element_mass_g_by_cell_and_species[0] = 4;
    var soil = [_]f64{0} ** (2 * gas.species_count);
    var litter = [_]f64{0} ** (2 * gas.species_count);
    litter[gas.species_count] = std.math.nan(f64);
    try std.testing.expectError(error.NonFiniteGasOutputBoundaryExchange, state.accumulateHour(null, 1, 1, &soil, &litter));
    try std.testing.expectEqual(@as(f64, 4), state.tracked_element_mass_g_by_cell_and_species[0]);
}

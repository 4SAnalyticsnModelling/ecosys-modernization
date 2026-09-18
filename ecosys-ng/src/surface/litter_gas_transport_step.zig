const std = @import("std");
const gas = @import("../soil/gas/transport.zig");
const atmosphere = @import("../soil/gas/atmosphere_exchange.zig");
const solver = @import("../soil/gas/coupled_gas_solver.zig");
const gas_failure_reporter = @import("../validation/coupled_gas_failure_reporter.zig");
const litter_chemistry = @import("litter_chemistry.zig");
const ammonia_bridge = @import("litter_ammonia_phase_bridge.zig");
const litter_geometry = @import("litter_geometry_step.zig");
const precipitation = @import("precipitation.zig");
const ice_units = @import("../core/ice_units.zig");

pub const RuntimeParameters = struct {
    reference_temperature_k: f64 = 298.15,
    temperature_exponent: f64 = 1.75,
    free_air_diffusivity_m2_per_h: [gas.species_count]f64 = .{ 4.68e-2, 7.80e-2, 6.43e-2, 5.57e-2, 5.57e-2, 6.67e-2, 5.57e-2 },
    penman_tortuosity: f64 = 0.66,
    minimum_air_fraction: f64 = 1e-12,
    ice_density_megagrams_per_m3: f64 = ice_units.reference_ice_density_megagrams_per_m3,
};

pub const AmmoniaOwner = struct {
    chemistry: *litter_chemistry.State,
    nitrogen_molar_mass_g_per_mol: f64,
    absolute_tolerance_g_n: f64,
    relative_tolerance: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    boundaries: []atmosphere.Boundary,
    water_volume_m3: []f64,
    band_water_volume_m3: []f64,
    mass_solubility_ratio: []f64,
    gas_water_exchange_rate_per_step: []f64,
    band_gas_water_exchange_rate_per_step: []f64,
    bubbling_enabled: []bool,
    atmospheric_flux_g_per_h: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceLitterGasCellCount;
        const components = try std.math.mul(usize, cell_count, gas.species_count);
        const boundaries = try allocator.alloc(atmosphere.Boundary, cell_count);
        errdefer allocator.free(boundaries);
        const water = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(water);
        const band_water = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(band_water);
        const solubility = try allocator.alloc(f64, components);
        errdefer allocator.free(solubility);
        const exchange = try allocator.alloc(f64, components);
        errdefer allocator.free(exchange);
        const band_exchange = try allocator.alloc(f64, components);
        errdefer allocator.free(band_exchange);
        const bubbling = try allocator.alloc(bool, cell_count);
        errdefer allocator.free(bubbling);
        const atmospheric_flux = try allocator.alloc(f64, components);
        errdefer allocator.free(atmospheric_flux);
        @memset(water, 0);
        @memset(band_water, 0);
        @memset(boundaries, std.mem.zeroes(atmosphere.Boundary));
        @memset(solubility, 0);
        @memset(exchange, 0);
        @memset(band_exchange, 0);
        @memset(bubbling, false);
        @memset(atmospheric_flux, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .boundaries = boundaries, .water_volume_m3 = water, .band_water_volume_m3 = band_water, .mass_solubility_ratio = solubility, .gas_water_exchange_rate_per_step = exchange, .band_gas_water_exchange_rate_per_step = band_exchange, .bubbling_enabled = bubbling, .atmospheric_flux_g_per_h = atmospheric_flux };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.atmospheric_flux_g_per_h);
        self.allocator.free(self.bubbling_enabled);
        self.allocator.free(self.band_gas_water_exchange_rate_per_step);
        self.allocator.free(self.gas_water_exchange_rate_per_step);
        self.allocator.free(self.mass_solubility_ratio);
        self.allocator.free(self.band_water_volume_m3);
        self.allocator.free(self.water_volume_m3);
        self.allocator.free(self.boundaries);
        self.* = undefined;
    }

    pub fn advance(
        self: *State,
        gas_state: *gas.State,
        ammonia_owner: AmmoniaOwner,
        geometry: *const litter_geometry.State,
        litter_water_m3: []const f64,
        litter_ice_m3: []const f64,
        cell_area_m2: []const f64,
        atmospheric_conductance_m3_per_step: []const f64,
        atmospheric_concentration_g_per_m3: []const f64,
        solubility_parameters: gas.SurfaceSolubilityParameters,
        exchange_parameters: precipitation.GasExchangeParameters,
        parameters: RuntimeParameters,
        options: solver.Options,
    ) !solver.Result {
        return self.advanceWithFailureReport(
            gas_state,
            ammonia_owner,
            geometry,
            litter_water_m3,
            litter_ice_m3,
            cell_area_m2,
            atmospheric_conductance_m3_per_step,
            atmospheric_concentration_g_per_m3,
            solubility_parameters,
            exchange_parameters,
            parameters,
            options,
            null,
        );
    }

    pub fn advanceWithFailureReport(
        self: *State,
        gas_state: *gas.State,
        ammonia_owner: AmmoniaOwner,
        geometry: *const litter_geometry.State,
        litter_water_m3: []const f64,
        litter_ice_m3: []const f64,
        cell_area_m2: []const f64,
        atmospheric_conductance_m3_per_step: []const f64,
        atmospheric_concentration_g_per_m3: []const f64,
        solubility_parameters: gas.SurfaceSolubilityParameters,
        exchange_parameters: precipitation.GasExchangeParameters,
        parameters: RuntimeParameters,
        options: solver.Options,
        failure_report: ?gas_failure_reporter.Request,
    ) !solver.Result {
        try gas_state.validateShape();
        const air_before = try self.allocator.dupe(f64, gas_state.air_volume_m3);
        defer self.allocator.free(air_before);
        const gaseous_before = try self.allocator.dupe(f64, gas_state.gaseous_mass_g);
        defer self.allocator.free(gaseous_before);
        const dissolved_before = try self.allocator.dupe(f64, gas_state.dissolved_mass_g);
        defer self.allocator.free(dissolved_before);
        const macropore_before = try self.allocator.dupe(f64, gas_state.macropore_dissolved_mass_g);
        defer self.allocator.free(macropore_before);
        const band_before = try self.allocator.dupe(f64, gas_state.band_dissolved_mass_g);
        defer self.allocator.free(band_before);
        const boundaries_before = try self.allocator.dupe(atmosphere.Boundary, self.boundaries);
        defer self.allocator.free(boundaries_before);
        const water_before = try self.allocator.dupe(f64, self.water_volume_m3);
        defer self.allocator.free(water_before);
        const band_water_before = try self.allocator.dupe(f64, self.band_water_volume_m3);
        defer self.allocator.free(band_water_before);
        const solubility_before = try self.allocator.dupe(f64, self.mass_solubility_ratio);
        defer self.allocator.free(solubility_before);
        const exchange_before = try self.allocator.dupe(f64, self.gas_water_exchange_rate_per_step);
        defer self.allocator.free(exchange_before);
        const band_exchange_before = try self.allocator.dupe(f64, self.band_gas_water_exchange_rate_per_step);
        defer self.allocator.free(band_exchange_before);
        const bubbling_before = try self.allocator.dupe(bool, self.bubbling_enabled);
        defer self.allocator.free(bubbling_before);
        const atmospheric_flux_before = try self.allocator.dupe(f64, self.atmospheric_flux_g_per_h);
        defer self.allocator.free(atmospheric_flux_before);
        const chemistry_ammonia_before = try self.allocator.alloc(f64, ammonia_owner.chemistry.cells.len);
        defer self.allocator.free(chemistry_ammonia_before);
        for (ammonia_owner.chemistry.cells, chemistry_ammonia_before) |cell, *value|
            value.* = cell.ammonia_mol_per_m3;
        errdefer {
            @memcpy(gas_state.air_volume_m3, air_before);
            @memcpy(gas_state.gaseous_mass_g, gaseous_before);
            @memcpy(gas_state.dissolved_mass_g, dissolved_before);
            @memcpy(gas_state.macropore_dissolved_mass_g, macropore_before);
            @memcpy(gas_state.band_dissolved_mass_g, band_before);
            @memcpy(self.boundaries, boundaries_before);
            @memcpy(self.water_volume_m3, water_before);
            @memcpy(self.band_water_volume_m3, band_water_before);
            @memcpy(self.mass_solubility_ratio, solubility_before);
            @memcpy(self.gas_water_exchange_rate_per_step, exchange_before);
            @memcpy(self.band_gas_water_exchange_rate_per_step, band_exchange_before);
            @memcpy(self.bubbling_enabled, bubbling_before);
            @memcpy(self.atmospheric_flux_g_per_h, atmospheric_flux_before);
            for (ammonia_owner.chemistry.cells, chemistry_ammonia_before) |*cell, value|
                cell.ammonia_mol_per_m3 = value;
        }
        try ammonia_bridge.refreshTransientFromChemistry(
            ammonia_owner.chemistry,
            gas_state,
            litter_water_m3,
            ammonia_owner.nitrogen_molar_mass_g_per_mol,
        );
        @memset(self.atmospheric_flux_g_per_h, 0);
        if (gas_state.cell_count != self.cell_count or geometry.cell_count != self.cell_count or litter_water_m3.len != self.cell_count or litter_ice_m3.len != self.cell_count or cell_area_m2.len != self.cell_count or atmospheric_conductance_m3_per_step.len != self.cell_count or atmospheric_concentration_g_per_m3.len != self.cell_count * gas.species_count) return error.SurfaceLitterGasDimensionMismatch;
        if (!std.math.isFinite(parameters.reference_temperature_k) or parameters.reference_temperature_k <= 0 or !std.math.isFinite(parameters.temperature_exponent) or parameters.temperature_exponent < 0 or !std.math.isFinite(parameters.penman_tortuosity) or parameters.penman_tortuosity < 0 or !std.math.isFinite(parameters.minimum_air_fraction) or parameters.minimum_air_fraction < 0) return error.InvalidSurfaceLitterGasParameter;
        _ = ice_units.physicalVolumeM3FromWaterEquivalent(0, parameters.ice_density_megagrams_per_m3) catch return error.InvalidSurfaceLitterGasParameter;
        for (0..self.cell_count) |cell| {
            const volume = geometry.expanded_total_volume_m3[cell];
            const porosity = geometry.porosity_m3_per_m3[cell];
            const air_volume = geometry.air_volume_m3[cell];
            const area = cell_area_m2[cell];
            const thickness = if (area > 0) volume / area else 0;
            if (!std.math.isFinite(volume) or volume < 0 or !std.math.isFinite(porosity) or porosity < 0 or !std.math.isFinite(air_volume) or air_volume < 0 or air_volume > volume or !std.math.isFinite(area) or area <= 0 or !std.math.isFinite(litter_water_m3[cell]) or litter_water_m3[cell] < 0 or !std.math.isFinite(litter_ice_m3[cell]) or litter_ice_m3[cell] < 0) return error.InvalidSurfaceLitterGasState;
            gas_state.air_volume_m3[cell] = air_volume;
            // Freeze-out: ice excludes dissolved gases. When all pore space is
            // occupied by ice and liquid, air_volume = 0 and the gas-water
            // exchange rate is zero (litterGasExchange requires air_m3 > 0).
            // Without this transfer, dissolved mass accumulates in the shrinking
            // liquid volume, producing physically impossible concentrations.
            // The atmospheric boundary (atmosphericDiffusiveFluxG, air_volume=0
            // branch) then immediately expels the degassed mass to atmosphere.
            if (air_volume <= 0) {
                const start = cell * gas.species_count;
                const dissolved = gas_state.dissolved_mass_g[start..][0..gas.species_count];
                const gaseous = gas_state.gaseous_mass_g[start..][0..gas.species_count];
                for (dissolved, gaseous) |*d, *g| {
                    g.* += d.*;
                    d.* = 0;
                }
            }
            self.water_volume_m3[cell] = litter_water_m3[cell];
            const solubility = try gas.surfaceSolubilityWaterToAir(gas_state.temperature_k[cell], solubility_parameters);
            var whole_step_exchange = exchange_parameters;
            whole_step_exchange.iteration_fraction = 1;
            const physical_ice_volume_m3 = try ice_units.physicalVolumeM3FromWaterEquivalent(
                litter_ice_m3[cell],
                parameters.ice_density_megagrams_per_m3,
            );
            const exchange = try precipitation.litterGasExchange(geometry.pore_volume_m3[cell], physical_ice_volume_m3, litter_water_m3[cell], air_volume, geometry.water_retention_capacity_m3[cell], whole_step_exchange);
            var interior: [gas.species_count]f64 = undefined;
            const air_fraction = if (volume > 0) air_volume / volume else 0;
            const diffusion_geometry_m = if (thickness > 0 and porosity > 0 and air_fraction > parameters.minimum_air_fraction)
                air_fraction * parameters.penman_tortuosity * air_fraction / porosity * area / thickness
            else
                0;
            const temperature_factor = std.math.pow(f64, gas_state.temperature_k[cell] / parameters.reference_temperature_k, parameters.temperature_exponent);
            for (0..gas.species_count) |species| {
                const component = cell * gas.species_count + species;
                interior[species] = diffusion_geometry_m * parameters.free_air_diffusivity_m2_per_h[species] * temperature_factor;
                self.mass_solubility_ratio[component] = solubility[species];
                self.gas_water_exchange_rate_per_step[component] = exchange.air_water_rate_per_step;
            }
            self.boundaries[cell] = .{
                .cell_index = cell,
                .aerodynamic_conductance_m3_per_step = atmospheric_conductance_m3_per_step[cell],
                .interior_conductance_m3_per_step = interior,
                .atmospheric_concentration_g_per_m3 = atmospheric_concentration_g_per_m3[cell * gas.species_count ..][0..gas.species_count].*,
            };
        }
        const solve_inputs: solver.Inputs = .{
            .faces = &.{},
            .face_conductance_m3_per_step = &.{},
            .atmospheric_boundaries = self.boundaries,
            .water_volume_m3 = self.water_volume_m3,
            .band_water_volume_m3 = self.band_water_volume_m3,
            .mass_solubility_ratio = self.mass_solubility_ratio,
            .gas_water_exchange_rate_per_step = self.gas_water_exchange_rate_per_step,
            .band_gas_water_exchange_rate_per_step = self.band_gas_water_exchange_rate_per_step,
            .bubbling_enabled = self.bubbling_enabled,
            .atmospheric_flux_g_by_component = self.atmospheric_flux_g_per_h,
        };
        var solve_options = options;
        solve_options.emit_failure_diagnostics = failure_report != null;
        const result = solver.solve(
            self.allocator,
            gas_state,
            solve_inputs,
            solve_options,
        ) catch |err| {
            if (failure_report) |report|
                return gas_failure_reporter.reportPreservingSolverError(
                    self.allocator,
                    report.io,
                    report.directory,
                    report.file_path,
                    gas_state,
                    solve_inputs,
                    solve_options,
                    report.options,
                    err,
                );
            return err;
        };
        // The coupled solve publishes F(current) and captures the atmospheric
        // flux from that same current iterate.  Enforce that contract at the
        // owning wrapper before any chemistry mirror can obscure which side
        // introduced a conservation defect.
        for (0..self.cell_count) |cell| for (0..gas.species_count) |species| {
            if (species == @intFromEnum(gas.Species.ammonia)) continue;
            const component = cell * gas.species_count + species;
            const before_total_g = gaseous_before[component] +
                dissolved_before[component] +
                macropore_before[component] +
                band_before[component];
            const after_total_g = gas_state.gaseous_mass_g[component] +
                gas_state.dissolved_mass_g[component] +
                gas_state.macropore_dissolved_mass_g[component] +
                gas_state.band_dissolved_mass_g[component];
            const accepted_atmospheric_g = self.atmospheric_flux_g_per_h[component];
            const closure_g = after_total_g - before_total_g - accepted_atmospheric_g;
            const scale_g = @max(
                1,
                @max(
                    @max(@abs(before_total_g), @abs(after_total_g)),
                    @abs(accepted_atmospheric_g),
                ),
            );
            const arithmetic_limit_g = 256 * std.math.floatEps(f64) * scale_g;
            if (!std.math.isFinite(closure_g) or @abs(closure_g) > arithmetic_limit_g) {
                std.log.err(
                    "surface litter gas owner closure failure: cell={d} species={d} before_g={e} after_g={e} atmospheric_g={e} residual_g={e} arithmetic_limit_g={e}",
                    .{ cell, species, before_total_g, after_total_g, accepted_atmospheric_g, closure_g, arithmetic_limit_g },
                );
                return error.SurfaceLitterGasOwnerClosureFailure;
            }
        };
        try ammonia_bridge.publishTransientToChemistry(
            ammonia_owner.chemistry,
            gas_state,
            litter_water_m3,
            ammonia_owner.nitrogen_molar_mass_g_per_mol,
            ammonia_owner.absolute_tolerance_g_n,
            ammonia_owner.relative_tolerance,
        );
        return result;
    }
};

test "PARR couples atmosphere and litter diffusivity in one local solve" {
    var geometry = try litter_geometry.State.init(std.testing.allocator, 1);
    defer geometry.deinit();
    geometry.expanded_total_volume_m3[0] = 2;
    geometry.pore_volume_m3[0] = 1;
    geometry.air_volume_m3[0] = 0.5;
    geometry.porosity_m3_per_m3[0] = 0.5;
    geometry.water_retention_capacity_m3[0] = 0.5;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var chemistry_state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    gas_state.temperature_k[0] = 298.15;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var atmospheric = [_]f64{0} ** gas.species_count;
    atmospheric[0] = 1;
    const unit_solubility = gas.SurfaceSolubilityParameters{ .reference_water_to_air = [_]f64{1} ** gas.species_count, .log_intercept = [_]f64{0} ** gas.species_count, .temperature_coefficient_per_c = [_]f64{0} ** gas.species_count };
    const result = try state.advance(&gas_state, .{ .chemistry = &chemistry_state, .nitrogen_molar_mass_g_per_mol = 14, .absolute_tolerance_g_n = 1e-12, .relative_tolerance = 1e-9 }, &geometry, &.{0.5}, &.{0}, &.{2}, &.{0.1}, &atmospheric, unit_solubility, .{ .reference_time_h = 1, .wet_exponent = 12, .dry_exponent = 12, .transition_water_fraction = 0.5, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 }, .{}, .{ .max_iterations = 80 });
    try std.testing.expect(state.boundaries[0].interior_conductance_m3_per_step[0] > 0);
    try std.testing.expect(state.gas_water_exchange_rate_per_step[0] > 0);
    try std.testing.expect(gas_state.gaseous_mass_g[0] + gas_state.dissolved_mass_g[0] > 0);
    try std.testing.expectApproxEqAbs(gas_state.gaseous_mass_g[0] + gas_state.dissolved_mass_g[0], state.atmospheric_flux_g_per_h[0], 1e-12);
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expectEqual(result.anderson_steps, result.picard_steps);
    try std.testing.expect(result.maximum_scaled_residual <= 1);
}

test "litter ammonia phase exchange conserves chemistry plus gaseous owner" {
    var geometry = try litter_geometry.State.init(std.testing.allocator, 1);
    defer geometry.deinit();
    geometry.expanded_total_volume_m3[0] = 1;
    geometry.pore_volume_m3[0] = 1;
    geometry.air_volume_m3[0] = 0.5;
    geometry.porosity_m3_per_m3[0] = 1;
    geometry.water_retention_capacity_m3[0] = 1;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.temperature_k[0] = 298.15;
    var chemistry_state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 1;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const atmosphere_zero = [_]f64{0} ** gas.species_count;
    const unit_solubility = gas.SurfaceSolubilityParameters{ .reference_water_to_air = [_]f64{1} ** gas.species_count, .log_intercept = [_]f64{0} ** gas.species_count, .temperature_coefficient_per_c = [_]f64{0} ** gas.species_count };
    const initial_g_n: f64 = 0.5 * 14;
    _ = try state.advance(
        &gas_state,
        .{ .chemistry = &chemistry_state, .nitrogen_molar_mass_g_per_mol = 14, .absolute_tolerance_g_n = 1e-12, .relative_tolerance = 1e-9 },
        &geometry,
        &.{0.5},
        &.{0},
        &.{1},
        &.{0},
        &atmosphere_zero,
        unit_solubility,
        .{ .reference_time_h = 1, .wet_exponent = 1, .dry_exponent = 1, .transition_water_fraction = 0.5, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 },
        .{},
        .{ .absolute_tolerance_g = 1e-12, .relative_tolerance = 1e-9, .max_iterations = 80 },
    );
    const ammonia = @intFromEnum(gas.Species.ammonia);
    const aqueous_g_n = chemistry_state.cells[0].ammonia_mol_per_m3 * 0.5 * 14;
    try std.testing.expect(gas_state.gaseous_mass_g[ammonia] > 0);
    // Pressure displacement is an atmospheric boundary input even when the
    // diffusive conductance is zero. It must close explicitly, not disappear
    // inside the phase transfer.
    try std.testing.expectApproxEqAbs(
        initial_g_n + state.atmospheric_flux_g_per_h[ammonia],
        aqueous_g_n + gas_state.gaseous_mass_g[ammonia],
        1e-11,
    );
    try std.testing.expectApproxEqAbs(aqueous_g_n, gas_state.dissolved_mass_g[ammonia], 1e-12);
    try std.testing.expect(state.atmospheric_flux_g_per_h[ammonia] > 0);
}

test "surface litter gas transaction rolls back gas chemistry and workspaces on later invalid cell" {
    var geometry = try litter_geometry.State.init(std.testing.allocator, 2);
    defer geometry.deinit();
    for (0..2) |cell| {
        geometry.expanded_total_volume_m3[cell] = 2;
        geometry.pore_volume_m3[cell] = 1;
        geometry.air_volume_m3[cell] = 0.5;
        geometry.porosity_m3_per_m3[cell] = 0.5;
        geometry.water_retention_capacity_m3[cell] = 0.5;
    }
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    @memset(gas_state.temperature_k, 298.15);
    gas_state.gaseous_mass_g[0] = 3;
    gas_state.dissolved_mass_g[0] = 4;
    var chemistry_state = try litter_chemistry.State.init(std.testing.allocator, 2);
    defer chemistry_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 2;
    chemistry_state.cells[1].ammonia_mol_per_m3 = 5;
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.water_volume_m3[0] = 9;
    state.atmospheric_flux_g_per_h[0] = 7;
    const gaseous_before = try std.testing.allocator.dupe(f64, gas_state.gaseous_mass_g);
    defer std.testing.allocator.free(gaseous_before);
    const dissolved_before = try std.testing.allocator.dupe(f64, gas_state.dissolved_mass_g);
    defer std.testing.allocator.free(dissolved_before);
    const water_before = try std.testing.allocator.dupe(f64, state.water_volume_m3);
    defer std.testing.allocator.free(water_before);
    const flux_before = try std.testing.allocator.dupe(f64, state.atmospheric_flux_g_per_h);
    defer std.testing.allocator.free(flux_before);
    const atmospheric = [_]f64{0} ** (2 * gas.species_count);
    const unit_solubility = gas.SurfaceSolubilityParameters{ .reference_water_to_air = [_]f64{1} ** gas.species_count, .log_intercept = [_]f64{0} ** gas.species_count, .temperature_coefficient_per_c = [_]f64{0} ** gas.species_count };
    try std.testing.expectError(error.InvalidSurfaceLitterGasState, state.advance(
        &gas_state,
        .{ .chemistry = &chemistry_state, .nitrogen_molar_mass_g_per_mol = 14, .absolute_tolerance_g_n = 1e-12, .relative_tolerance = 1e-9 },
        &geometry,
        &.{ 0.5, 0.5 },
        &.{ 0, 0 },
        &.{ 2, 0 },
        &.{ 0.1, 0.1 },
        &atmospheric,
        unit_solubility,
        .{ .reference_time_h = 1, .wet_exponent = 12, .dry_exponent = 12, .transition_water_fraction = 0.5, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 },
        .{},
        .{ .max_iterations = 80 },
    ));
    try std.testing.expectEqualSlices(f64, gaseous_before, gas_state.gaseous_mass_g);
    try std.testing.expectEqualSlices(f64, dissolved_before, gas_state.dissolved_mass_g);
    try std.testing.expectEqualSlices(f64, water_before, state.water_volume_m3);
    try std.testing.expectEqualSlices(f64, flux_before, state.atmospheric_flux_g_per_h);
    try std.testing.expectEqual(@as(f64, 2), chemistry_state.cells[0].ammonia_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 5), chemistry_state.cells[1].ammonia_mol_per_m3);
}

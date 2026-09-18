const std = @import("std");
const compute = @import("../core/compute.zig");
const gas_transport = @import("../soil/gas/transport.zig");
const organic = @import("../soil/organic/initialization.zig");
const oxygen_allocation = @import("../soil/gas/oxygen_allocation.zig");
const oxygen_solver = @import("../soil/gas/oxygen_solver.zig");
const surface_oxygen = @import("microbial_oxygen.zig");
const respiration = @import("microbial_respiration_step.zig");
const autotrophic = @import("autotrophic_complex_step.zig");
const litter_geometry = @import("litter_geometry_step.zig");
const litter_water_environment = @import("litter_water_environment.zig");
const precipitation = @import("precipitation.zig");
const gas_parameters = @import("gas_parameters.zig");
const ice_units = @import("../core/ice_units.zig");

pub const heterotrophic_unit_count_per_cell: usize = respiration.unit_count_per_cell;
pub const unit_count_per_cell: usize = heterotrophic_unit_count_per_cell + autotrophic.active_population_count;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    allocation: oxygen_allocation.State,
    populations: []oxygen_allocation.Population,
    gaseous_oxygen_flux_g_o: []f64,
    aqueous_oxygen_flux_g_o: []f64,
    oxygen_solubility_water_to_air: []f64,
    gas_exchange_rate_per_step: []f64,
    maximum_aqueous_oxygen_concentration_g_o_per_m3: []f64,
    oxygen_limited_activity_g_c_per_step: []f64,
    respiration_carbon_dioxide_g_c_per_step: []f64,
    fermentation_acetate_g_c_per_step: []f64,
    respiration_methane_g_c_per_step: []f64,
    respiration_hydrogen_g_h_per_step: []f64,

    noinline fn deinitAllocatedF64Prefix(self: *State, allocated_count: usize) void {
        var remaining = allocated_count;
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                if (remaining == 0) return;
                self.allocator.free(@field(self, field.name));
                remaining -= 1;
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceMicrobialOxygenCells;
        var allocation = try oxygen_allocation.State.init(allocator, cell_count, 1, unit_count_per_cell);
        errdefer allocation.deinit();
        const population_count = try std.math.mul(usize, cell_count, unit_count_per_cell);
        const populations = try allocator.alloc(oxygen_allocation.Population, population_count);
        errdefer allocator.free(populations);
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        result.allocation = allocation;
        result.populations = populations;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedF64Prefix(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, cell_count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        @memset(populations, .{ .is_aerobic = false, .previous_oxygen_demand_g_o = 0, .fallback_active_fraction = 0, .uptake_conductance_m3_per_step = 0, .oxygen_half_saturation_g_o_per_m3 = 1, .maximum_oxygen_uptake_g_o = 0 });
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.allocator.free(self.populations);
        self.allocation.deinit();
        self.* = undefined;
    }
};

test "surface microbial oxygen state releases every nested allocation prefix" {
    var reached_success = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var state = State.init(failing.allocator(), 2) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        state.deinit();
        reached_success = true;
        break;
    }
    try std.testing.expect(reached_success);
}

pub const ApplyContext = struct {
    result: *State,
    litter_gas: *gas_transport.State,
    surface_organic: *const organic.State,
    respiration: *const respiration.State,
    autotrophic: *const autotrophic.State,
    geometry: *const litter_geometry.State,
    water_environment: *const litter_water_environment.State,
    litter_water_m3: []const f64,
    litter_ice_m3: []const f64,
    ice_density_megagrams_per_m3: f64 = ice_units.reference_ice_density_megagrams_per_m3,
    parameters: gas_parameters.Parameters,
    timestep_h: f64,
    solver_options: oxygen_solver.Options,
};

/// Prepares NITRO FOXYX/DIFOX inputs, executes the implicit surface O2 solve,
/// then aggregates oxygen-limited ROQCD. WATSUB has already deposited accepted
/// snow/direct precipitation chemistry into the extensive gas owner. Biology
/// consumes that inventory; deriving another oxygen source from water ingress
/// would duplicate atmospheric oxygen and evade its boundary ledger.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| {
        const solubility = try gas_transport.surfaceSolubilityWaterToAir(context.litter_gas.temperature_k[cell], context.parameters.solubility);
        context.result.oxygen_solubility_water_to_air[cell] = solubility[@intFromEnum(gas_transport.Species.oxygen)];
        // Keep the existing zero-valued solver work arrays and checkpoint
        // layout. Neither is a new boundary source in this production owner.
        context.result.gaseous_oxygen_flux_g_o[cell] = 0;
        context.result.aqueous_oxygen_flux_g_o[cell] = 0;
        var whole_step_exchange = context.parameters.exchange;
        whole_step_exchange.iteration_fraction = 1;
        const physical_ice_volume_m3 = try ice_units.physicalVolumeM3FromWaterEquivalent(
            context.litter_ice_m3[cell],
            context.ice_density_megagrams_per_m3,
        );
        const exchange = try precipitation.litterGasExchange(
            context.geometry.pore_volume_m3[cell],
            physical_ice_volume_m3,
            context.litter_water_m3[cell],
            context.geometry.air_volume_m3[cell],
            context.geometry.water_retention_capacity_m3[cell],
            whole_step_exchange,
        );
        context.result.gas_exchange_rate_per_step[cell] = exchange.air_water_rate_per_step;
        context.result.maximum_aqueous_oxygen_concentration_g_o_per_m3[cell] = context.parameters.maximum_aqueous_oxygen_concentration_g_o_per_m3;
        const diffusivity = try surface_oxygen.aqueousOxygenDiffusivity_m2_per_step(context.parameters.reference_aqueous_oxygen_diffusivity_m2_per_h, context.litter_gas.temperature_k[cell], context.timestep_h);
        var total_active_biomass_g_c: f64 = 0;
        var active_biomass_g_c: [unit_count_per_cell]f64 = undefined;
        for (0..respiration.litter_complex_count) |complex| for (0..respiration.source_population_count) |population| {
            const unit = complex * respiration.source_population_count + population;
            const microbial = (((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count);
            active_biomass_g_c[unit] = context.surface_organic.microbial[microbial].carbon_g_c / context.parameters.microbial_respiration.labile_biomass_fraction;
            total_active_biomass_g_c += active_biomass_g_c[unit];
        };
        for (0..autotrophic.active_population_count) |active| {
            const unit = heterotrophic_unit_count_per_cell + active;
            active_biomass_g_c[unit] = context.autotrophic.active_biomass_g_c[cell * autotrophic.active_population_count + active];
            total_active_biomass_g_c += active_biomass_g_c[unit];
        }
        for (0..heterotrophic_unit_count_per_cell) |unit| {
            const population = unit % respiration.source_population_count;
            const index = cell * unit_count_per_cell + unit;
            const respiration_index = cell * heterotrophic_unit_count_per_cell + unit;
            const aerobic = context.parameters.microbial_respiration.populations[population].metabolism == .aerobic_heterotroph;
            context.result.populations[index] = .{
                .is_aerobic = aerobic,
                .previous_oxygen_demand_g_o = context.respiration.previous_oxygen_demand_g_o[respiration_index],
                .fallback_active_fraction = if (total_active_biomass_g_c > 0) active_biomass_g_c[unit] / total_active_biomass_g_c else 1,
                .uptake_conductance_m3_per_step = try oxygen_solver.uptakeConductance_m3_per_step(.{
                    .microbial_radius_m = context.parameters.microbial_radius_m,
                    .water_film_thickness_m = context.water_environment.water_film_thickness_m[cell],
                    .tortuosity = exchange.aqueous_tortuosity,
                    .aqueous_oxygen_diffusivity_m2_per_step = diffusivity,
                    .microbial_count_per_g_c = context.parameters.microbial_count_per_g_c,
                    .active_biomass_g_c = active_biomass_g_c[unit],
                }),
                .oxygen_half_saturation_g_o_per_m3 = context.parameters.oxygen_half_saturation_g_o_per_m3,
                .maximum_oxygen_uptake_g_o = context.respiration.potential_oxygen_demand_g_o[respiration_index],
            };
        }
        for (0..autotrophic.active_population_count) |active| {
            const unit = heterotrophic_unit_count_per_cell + active;
            const index = cell * unit_count_per_cell + unit;
            const autotrophic_index = cell * autotrophic.active_population_count + active;
            const aerobic = active != autotrophic.active_population_count - 1;
            context.result.populations[index] = .{
                .is_aerobic = aerobic,
                .previous_oxygen_demand_g_o = context.autotrophic.previous_oxygen_demand_g_o[autotrophic_index],
                .fallback_active_fraction = if (total_active_biomass_g_c > 0) active_biomass_g_c[unit] / total_active_biomass_g_c else 1,
                .uptake_conductance_m3_per_step = try oxygen_solver.uptakeConductance_m3_per_step(.{
                    .microbial_radius_m = context.parameters.microbial_radius_m,
                    .water_film_thickness_m = context.water_environment.water_film_thickness_m[cell],
                    .tortuosity = exchange.aqueous_tortuosity,
                    .aqueous_oxygen_diffusivity_m2_per_step = diffusivity,
                    .microbial_count_per_g_c = context.parameters.microbial_count_per_g_c,
                    .active_biomass_g_c = active_biomass_g_c[unit],
                }),
                .oxygen_half_saturation_g_o_per_m3 = context.parameters.oxygen_half_saturation_g_o_per_m3,
                .maximum_oxygen_uptake_g_o = context.autotrophic.potential_oxygen_demand_g_o[autotrophic_index],
            };
        }
    }
    // With no liquid water, water stress drives biological O2 demand to zero.
    // Avoid presenting a zero-capacity aqueous phase to the implicit solver.
    var wet_start = range.first;
    while (wet_start < range.end) {
        while (wet_start < range.end and context.litter_water_m3[wet_start] <= 0) : (wet_start += 1) try state_updateDryCell(context, wet_start);
        if (wet_start == range.end) break;
        var wet_end = wet_start + 1;
        while (wet_end < range.end and context.litter_water_m3[wet_end] > 0) : (wet_end += 1) {}
        var oxygen_context: surface_oxygen.ApplyContext = .{
            .result = &context.result.allocation,
            .litter_gas = context.litter_gas,
            .litter_water_m3 = context.litter_water_m3,
            .gaseous_oxygen_flux_g_o = context.result.gaseous_oxygen_flux_g_o,
            .aqueous_oxygen_flux_g_o = context.result.aqueous_oxygen_flux_g_o,
            .oxygen_solubility_water_to_air = context.result.oxygen_solubility_water_to_air,
            .gas_exchange_rate_per_step = context.result.gas_exchange_rate_per_step,
            .maximum_aqueous_oxygen_concentration_g_o_per_m3 = context.result.maximum_aqueous_oxygen_concentration_g_o_per_m3,
            .populations = context.result.populations,
            .allocation_parameters = .{ .minimum_allocation_fraction = context.parameters.minimum_allocation_fraction, .negligible_demand_g_o = context.parameters.negligible_oxygen_demand_g_o },
            .solver_options = context.solver_options,
        };
        try surface_oxygen.applyTile(&oxygen_context, .{ .first = wet_start, .end = wet_end });
        wet_start = wet_end;
    }
    for (range.first..range.end) |cell| {
        var activity: f64 = 0;
        var carbon_dioxide_g_c: f64 = 0;
        var acetate_g_c: f64 = 0;
        var methane_g_c: f64 = 0;
        var hydrogen_g_h: f64 = 0;
        const base = cell * unit_count_per_cell;
        const respiration_base = cell * heterotrophic_unit_count_per_cell;
        for (0..heterotrophic_unit_count_per_cell) |unit| {
            const population = unit % respiration.source_population_count;
            const metabolism = context.parameters.microbial_respiration.populations[population].metabolism;
            const aerobic = context.result.populations[base + unit].is_aerobic;
            const oxygen_fraction = if (aerobic) context.result.allocation.demand_satisfaction_fraction[base + unit] else 1;
            activity += context.respiration.unlimited_respiration_g_c[respiration_base + unit] * oxygen_fraction;
            const actual_respiration_g_c = context.respiration.substrate_limited_respiration_g_c[respiration_base + unit] * oxygen_fraction;
            switch (metabolism) {
                .aerobic_heterotroph => carbon_dioxide_g_c += actual_respiration_g_c,
                .fermenting_heterotroph => {
                    carbon_dioxide_g_c += 0.333 * actual_respiration_g_c;
                    acetate_g_c += 0.667 * actual_respiration_g_c;
                    hydrogen_g_h += 0.111 * actual_respiration_g_c;
                },
                .acetotrophic_methanogen => {
                    carbon_dioxide_g_c += 0.5 * actual_respiration_g_c;
                    methane_g_c += 0.5 * actual_respiration_g_c;
                },
            }
        }
        for (0..autotrophic.active_population_count) |active| {
            const unit = heterotrophic_unit_count_per_cell + active;
            const oxygen_fraction = if (active != autotrophic.active_population_count - 1) context.result.allocation.demand_satisfaction_fraction[base + unit] else 1;
            activity += context.autotrophic.potential_respiration_g_c[cell * autotrophic.active_population_count + active] * oxygen_fraction;
        }
        inline for (.{ activity, carbon_dioxide_g_c, acetate_g_c, methane_g_c, hydrogen_g_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteSurfaceRespirationProduct;
        context.result.oxygen_limited_activity_g_c_per_step[cell] = activity;
        context.result.respiration_carbon_dioxide_g_c_per_step[cell] = carbon_dioxide_g_c;
        context.result.fermentation_acetate_g_c_per_step[cell] = acetate_g_c;
        context.result.respiration_methane_g_c_per_step[cell] = methane_g_c;
        context.result.respiration_hydrogen_g_h_per_step[cell] = hydrogen_g_h;
        context.result.gaseous_oxygen_flux_g_o[cell] = 0;
        context.result.aqueous_oxygen_flux_g_o[cell] = 0;
    }
}

fn state_updateDryCell(context: *ApplyContext, cell: usize) !void {
    const oxygen_index = try gas_transport.massIndex(cell, .oxygen, context.result.cell_count);
    const gas_after_flux = context.litter_gas.gaseous_mass_g[oxygen_index] + context.result.gaseous_oxygen_flux_g_o[cell];
    const water_after_flux = context.litter_gas.dissolved_mass_g[oxygen_index] + context.result.aqueous_oxygen_flux_g_o[cell];
    if (!std.math.isFinite(gas_after_flux) or gas_after_flux < 0 or !std.math.isFinite(water_after_flux) or water_after_flux < 0) return error.NegativeAvailableOxygen;
    context.litter_gas.gaseous_mass_g[oxygen_index] = gas_after_flux;
    context.litter_gas.dissolved_mass_g[oxygen_index] = water_after_flux;
    const base = cell * unit_count_per_cell;
    @memset(context.result.allocation.oxygen_uptake_g_o[base .. base + unit_count_per_cell], 0);
    @memset(context.result.allocation.demand_satisfaction_fraction[base .. base + unit_count_per_cell], 0);
    @memset(context.result.allocation.iterations[base .. base + unit_count_per_cell], 0);
    context.result.gaseous_oxygen_flux_g_o[cell] = 0;
    context.result.aqueous_oxygen_flux_g_o[cell] = 0;
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    if (range.first > range.end or range.end > cells or context.litter_gas.cell_count != cells or context.surface_organic.layer_count != cells or context.respiration.cell_count != cells or context.autotrophic.cell_count != cells or context.geometry.cell_count != cells or context.water_environment.cell_count != cells or context.result.allocation.cell_count != cells or context.result.allocation.population_count != unit_count_per_cell) return error.SurfaceMicrobialOxygenDriverDimensionMismatch;
    inline for (.{ context.litter_water_m3, context.litter_ice_m3 }) |values| if (values.len != cells) return error.SurfaceMicrobialOxygenDriverDimensionMismatch;
    _ = ice_units.physicalVolumeM3FromWaterEquivalent(0, context.ice_density_megagrams_per_m3) catch return error.InvalidSurfaceMicrobialOxygenInput;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.InvalidSurfaceMicrobialOxygenTimestep;
}

test "surface oxygen driver consumes accepted precipitation inventory without a second input" {
    var gas = try gas_transport.State.init(std.testing.allocator, 1);
    defer gas.deinit();
    gas.temperature_k[0] = 298.15;
    gas.air_volume_m3[0] = 1;
    gas.gaseous_mass_g[@intFromEnum(gas_transport.Species.oxygen)] = 0.001;
    var surface_organic = try organic.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    for (0..respiration.unit_count_per_cell) |unit| surface_organic.microbial[unit * organic.kinetic_fraction_count].carbon_g_c = 0.55;
    var respiration_state = try respiration.State.init(std.testing.allocator, 1);
    defer respiration_state.deinit();
    var autotrophic_state = try autotrophic.State.init(std.testing.allocator, 1);
    defer autotrophic_state.deinit();
    autotrophic_state.active_biomass_g_c[0] = 0.55;
    autotrophic_state.active_biomass_g_c[3] = 0.55;
    autotrophic_state.potential_oxygen_demand_g_o[0] = 1;
    autotrophic_state.potential_respiration_g_c[0] = 0.25;
    @memset(respiration_state.unlimited_respiration_g_c, 1);
    @memset(respiration_state.potential_oxygen_demand_g_o, 1);
    @memset(respiration_state.substrate_limited_respiration_g_c, 1);
    var geometry = try litter_geometry.State.init(std.testing.allocator, 1);
    defer geometry.deinit();
    geometry.pore_volume_m3[0] = 2;
    geometry.air_volume_m3[0] = 1;
    geometry.water_retention_capacity_m3[0] = 1;
    var water_environment = try litter_water_environment.State.init(std.testing.allocator, 1);
    defer water_environment.deinit();
    water_environment.water_film_thickness_m[0] = 1e-6;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var parameters: gas_parameters.Parameters = undefined;
    parameters.atmospheric_concentration_g_per_m3 = .{0} ** gas_transport.species_count;
    parameters.atmospheric_concentration_g_per_m3[@intFromEnum(gas_transport.Species.oxygen)] = 0.2;
    parameters.solubility = .{ .reference_water_to_air = .{1} ** gas_transport.species_count, .log_intercept = .{0} ** gas_transport.species_count, .temperature_coefficient_per_c = .{0} ** gas_transport.species_count };
    parameters.precipitation_activity_log = .{0} ** gas_transport.species_count;
    // Compatibility input must not fractionate this once-per-hour local solve.
    parameters.exchange = .{ .reference_time_h = 1, .wet_exponent = 12, .dry_exponent = 12, .transition_water_fraction = 0.5, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 };
    parameters.oxygen_half_saturation_g_o_per_m3 = 0.064;
    parameters.reference_aqueous_oxygen_diffusivity_m2_per_h = 8.57e-6;
    parameters.microbial_radius_m = 1e-6;
    parameters.microbial_count_per_g_c = 2.387e11;
    parameters.minimum_allocation_fraction = 0.001;
    parameters.negligible_oxygen_demand_g_o = 1e-12;
    parameters.maximum_aqueous_oxygen_concentration_g_o_per_m3 = 1;
    parameters.microbial_respiration.labile_biomass_fraction = 0.55;
    parameters.microbial_respiration.populations = .{
        .{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 1 },
        .{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 1 },
        .{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 1 },
        .{ .metabolism = .fermenting_heterotroph, .substrate_unlimited_respiration_per_h = 1 },
        .{ .metabolism = .acetotrophic_methanogen, .substrate_unlimited_respiration_per_h = 1 },
        .{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 1 },
        .{ .metabolism = .fermenting_heterotroph, .substrate_unlimited_respiration_per_h = 1 },
    };
    // WATSUB's accepted-discharge owner has already deposited atmospheric
    // chemistry before NITRO. Exercise that real producer, not a second
    // hand-written addition to the litter oxygen pool.
    const discharge_owner = @import("../soil/water/snow_surface_discharge.zig");
    const snow = @import("../soil/solute/snow_solute_transport.zig");
    const litter_chemistry_module = @import("litter_chemistry.zig");
    const soil_chemistry_module = @import("../soil/solute/chemistry_state.zig");
    const surface_routing = @import("../soil/solute/surface_solute_routing.zig");
    const species = @import("../soil/solute/transport_species.zig");
    var soil_gas = try gas_transport.State.init(std.testing.allocator, 1);
    defer soil_gas.deinit();
    var litter_chemistry = try litter_chemistry_module.State.init(std.testing.allocator, 1);
    defer litter_chemistry.deinit();
    var soil_chemistry = try soil_chemistry_module.State.init(std.testing.allocator, 1);
    defer soil_chemistry.deinit();
    var surface_aqueous = try surface_routing.State.init(std.testing.allocator, 1, 1, species.AqueousSpecies.count);
    defer surface_aqueous.deinit();
    var discharge = [_]snow.SurfaceDischarge{.{}};
    discharge[0].litter_g[@intFromEnum(snow.Species.oxygen)] = 0.1 * 0.2;
    try discharge_owner.state_update(std.testing.allocator, .{
        .discharge = &discharge,
        .litter_water_volume_m3 = &.{1},
        .topsoil_water_volume_m3 = &.{1},
        .soil_layer_capacity = 1,
        .nitrogen_molar_mass_g_per_mol = 14,
        .phosphorus_molar_mass_g_per_mol = 31,
        .ion_molar_mass_g_per_mol = .{ .aluminum = 27, .iron = 55.8, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
        .surface_aqueous = &surface_aqueous,
    }, &gas, &soil_gas, &litter_chemistry, &soil_chemistry);
    try std.testing.expectEqual(discharge[0].litter_g[@intFromEnum(snow.Species.oxygen)], gas.dissolved_mass_g[@intFromEnum(gas_transport.Species.oxygen)]);
    var context: ApplyContext = .{ .result = &state, .litter_gas = &gas, .surface_organic = &surface_organic, .respiration = &respiration_state, .autotrophic = &autotrophic_state, .geometry = &geometry, .water_environment = &water_environment, .litter_water_m3 = &.{1}, .litter_ice_m3 = &.{0}, .parameters = parameters, .timestep_h = 1, .solver_options = .{ .absolute_tolerance_g_o = 1e-12, .relative_tolerance = 1e-8, .derivative_floor = 1e-14, .picard_relaxation = 0.5, .gas_max_iterations = 80 } };
    const oxygen_before = gas.gaseous_mass_g[@intFromEnum(gas_transport.Species.oxygen)] + gas.dissolved_mass_g[@intFromEnum(gas_transport.Species.oxygen)];
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.gas_exchange_rate_per_step[0] > 0);
    // Six anaerobic units (two populations x three complexes) retain WFN=1.
    try std.testing.expect(state.oxygen_limited_activity_g_c_per_step[0] >= 6);
    try std.testing.expect(state.oxygen_limited_activity_g_c_per_step[0] < 18);
    const product_carbon = state.respiration_carbon_dioxide_g_c_per_step[0] + state.fermentation_acetate_g_c_per_step[0] + state.respiration_methane_g_c_per_step[0];
    var actual_respiration_carbon: f64 = 0;
    for (0..respiration.unit_count_per_cell) |unit| {
        const fraction = if (state.populations[unit].is_aerobic) state.allocation.demand_satisfaction_fraction[unit] else 1;
        actual_respiration_carbon += respiration_state.substrate_limited_respiration_g_c[unit] * fraction;
    }
    try std.testing.expectApproxEqAbs(actual_respiration_carbon, product_carbon, 1e-12);
    try std.testing.expect(state.fermentation_acetate_g_c_per_step[0] > 0);
    try std.testing.expect(state.respiration_methane_g_c_per_step[0] > 0);
    try std.testing.expect(state.respiration_hydrogen_g_h_per_step[0] > 0);
    try std.testing.expectEqual(@as(usize, 25), state.allocation.population_count);
    const first_autotroph = heterotrophic_unit_count_per_cell;
    try std.testing.expect(state.populations[first_autotroph].is_aerobic);
    try std.testing.expect(!state.populations[first_autotroph + 3].is_aerobic);
    // A heterotroph and the appended K=5 ammonia oxidizer both receive a
    // positive share of the same scarce oxygen inventory; the H2 methanogen
    // remains anaerobic and cannot consume from it.
    try std.testing.expect(state.allocation.oxygen_uptake_g_o[0] > 0);
    try std.testing.expect(state.allocation.oxygen_uptake_g_o[first_autotroph] > 0);
    try std.testing.expect(state.allocation.demand_satisfaction_fraction[first_autotroph] < 1);
    try std.testing.expectEqual(@as(f64, 0), state.allocation.oxygen_uptake_g_o[first_autotroph + 3]);
    var oxygen_uptake: f64 = 0;
    for (state.allocation.oxygen_uptake_g_o) |value| oxygen_uptake += value;
    const oxygen_after = gas.gaseous_mass_g[@intFromEnum(gas_transport.Species.oxygen)] + gas.dissolved_mass_g[@intFromEnum(gas_transport.Species.oxygen)];
    try std.testing.expectApproxEqAbs(oxygen_before, oxygen_after + oxygen_uptake, 1e-10);
}

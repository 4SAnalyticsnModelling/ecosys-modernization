const std = @import("std");
const Grid = @import("../../state/grid.zig").GridState;
const Roots = @import("plant_root_system.zig").State;
pub const root_gas_count: usize = 6;
pub const salt_species_count: usize = 8;
pub const organic_fraction_count: usize = 5;
pub const competition_demand_count: usize = 9;
pub const nutrient_uptake_count: usize = 8;

fn gasSlices(values: []f64, layer_count: usize, first_block: usize) [root_gas_count][]f64 {
    var result: [root_gas_count][]f64 = undefined;
    for (&result, 0..) |*slice, gas| {
        const first = (first_block + gas) * layer_count;
        slice.* = values[first .. first + layer_count];
    }
    return result;
}

/// Runtime layer owner for EXTRACT RTDNT, TUPWTR, and TUPHT.
pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    total_root_length_density_m_per_m3: []f64,
    total_water_uptake_m3_per_h: []f64,
    convective_water_heat_megajoules_per_h: []f64,
    /// CO2-C, O2-O, CH4-C, N2O-N, NH3-N, and H2-H by runtime soil layer.
    total_root_gas_content_g: [root_gas_count][]f64,
    total_soil_to_root_gas_exchange_g_per_h: [root_gas_count][]f64,
    total_aqueous_to_gaseous_root_exchange_g_per_h: [root_gas_count][]f64,
    total_atmosphere_to_root_gas_exchange_g_per_h: [root_gas_count][]f64,
    total_salt_uptake_mol_per_h: []f64,
    total_exudate_carbon_change_g_c_per_h: []f64,
    total_exudate_nitrogen_change_g_n_per_h: []f64,
    total_exudate_phosphorus_change_g_p_per_h: []f64,
    total_competition_demand_by_layer: [competition_demand_count][]f64,
    total_nutrient_uptake_by_layer: [nutrient_uptake_count][]f64,
    soil_oxygen_uptake_g_o_per_h: []f64,
    root_pool_oxygen_uptake_g_o_per_h: []f64,
    total_nitrogen_fixation_g_n_per_h: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.EmptyRootUptakeLedger;
        const values = try allocator.alloc(f64, try std.math.mul(usize, layer_count, 6 + 4 * root_gas_count));
        errdefer allocator.free(values);
        const salts = try allocator.alloc(f64, try std.math.mul(usize, layer_count, salt_species_count));
        errdefer allocator.free(salts);
        const exudates = try allocator.alloc(f64, try std.math.mul(usize, layer_count, 3 * organic_fraction_count));
        errdefer allocator.free(exudates);
        const competition = try allocator.alloc(f64, try std.math.mul(usize, layer_count, competition_demand_count));
        errdefer allocator.free(competition);
        const nutrients = try allocator.alloc(f64, try std.math.mul(usize, layer_count, nutrient_uptake_count));
        errdefer allocator.free(nutrients);
        @memset(values, 0);
        @memset(salts, 0);
        @memset(exudates, 0);
        @memset(competition, 0);
        @memset(nutrients, 0);
        return .{
            .allocator = allocator,
            .layer_count = layer_count,
            .total_root_length_density_m_per_m3 = values[0..layer_count],
            .total_water_uptake_m3_per_h = values[layer_count .. 2 * layer_count],
            .convective_water_heat_megajoules_per_h = values[2 * layer_count .. 3 * layer_count],
            .total_root_gas_content_g = .{
                values[3 * layer_count .. 4 * layer_count],
                values[4 * layer_count .. 5 * layer_count],
                values[5 * layer_count .. 6 * layer_count],
                values[6 * layer_count .. 7 * layer_count],
                values[7 * layer_count .. 8 * layer_count],
                values[8 * layer_count .. 9 * layer_count],
            },
            .total_soil_to_root_gas_exchange_g_per_h = gasSlices(values, layer_count, 9),
            .total_aqueous_to_gaseous_root_exchange_g_per_h = gasSlices(values, layer_count, 15),
            .total_atmosphere_to_root_gas_exchange_g_per_h = gasSlices(values, layer_count, 21),
            .soil_oxygen_uptake_g_o_per_h = values[27 * layer_count .. 28 * layer_count],
            .root_pool_oxygen_uptake_g_o_per_h = values[28 * layer_count .. 29 * layer_count],
            .total_nitrogen_fixation_g_n_per_h = values[29 * layer_count .. 30 * layer_count],
            .total_salt_uptake_mol_per_h = salts,
            .total_exudate_carbon_change_g_c_per_h = exudates[0 .. layer_count * organic_fraction_count],
            .total_exudate_nitrogen_change_g_n_per_h = exudates[layer_count * organic_fraction_count .. 2 * layer_count * organic_fraction_count],
            .total_exudate_phosphorus_change_g_p_per_h = exudates[2 * layer_count * organic_fraction_count ..],
            .total_competition_demand_by_layer = .{
                competition[0 * layer_count .. 1 * layer_count],
                competition[1 * layer_count .. 2 * layer_count],
                competition[2 * layer_count .. 3 * layer_count],
                competition[3 * layer_count .. 4 * layer_count],
                competition[4 * layer_count .. 5 * layer_count],
                competition[5 * layer_count .. 6 * layer_count],
                competition[6 * layer_count .. 7 * layer_count],
                competition[7 * layer_count .. 8 * layer_count],
                competition[8 * layer_count .. 9 * layer_count],
            },
            .total_nutrient_uptake_by_layer = .{
                nutrients[0 * layer_count .. 1 * layer_count],
                nutrients[1 * layer_count .. 2 * layer_count],
                nutrients[2 * layer_count .. 3 * layer_count],
                nutrients[3 * layer_count .. 4 * layer_count],
                nutrients[4 * layer_count .. 5 * layer_count],
                nutrients[5 * layer_count .. 6 * layer_count],
                nutrients[6 * layer_count .. 7 * layer_count],
                nutrients[7 * layer_count .. 8 * layer_count],
            },
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.total_nutrient_uptake_by_layer[0].ptr[0 .. self.layer_count * nutrient_uptake_count]);
        self.allocator.free(self.total_competition_demand_by_layer[0].ptr[0 .. self.layer_count * competition_demand_count]);
        self.allocator.free(self.total_exudate_carbon_change_g_c_per_h.ptr[0 .. self.layer_count * 3 * organic_fraction_count]);
        self.allocator.free(self.total_salt_uptake_mol_per_h);
        self.allocator.free(self.total_root_length_density_m_per_m3.ptr[0 .. self.layer_count * (6 + 4 * root_gas_count)]);
        self.* = undefined;
    }
};

pub fn refresh(
    state: *State,
    grid: *const Grid,
    roots: *const Roots,
    species_count: usize,
    biological_domain_count_by_plant: []const u8,
    plant_population_count: []const f64,
    cell_area_m2: []const f64,
    salinity_enabled_by_cell: []const bool,
) !void {
    if (species_count == 0 or roots.plant_count != grid.cell_count * species_count or
        roots.soil_layer_count != grid.soil_layer_capacity or state.layer_count != grid.layer_count or
        biological_domain_count_by_plant.len != roots.plant_count or
        plant_population_count.len != roots.plant_count or cell_area_m2.len != grid.cell_count or
        salinity_enabled_by_cell.len != grid.cell_count)
        return error.RootUptakeLedgerDimensionMismatch;
    for (0..grid.cell_count) |cell| {
        if (!std.math.isFinite(cell_area_m2[cell]) or cell_area_m2[cell] <= 0)
            return error.InvalidRootUptakeLedgerGeometry;
        for (0..grid.active_soil_layer_count[cell]) |local_layer| {
            const layer = try grid.layerIndex(cell, local_layer);
            if (!std.math.isFinite(grid.soil_temperature_k[layer]) or grid.soil_temperature_k[layer] <= 0)
                return error.InvalidRootUptakeLedgerTemperature;
        }
    }
    for (0..roots.plant_count) |plant| {
        const domain_count = biological_domain_count_by_plant[plant];
        if (domain_count == 0 or domain_count > @import("plant_root_system.zig").biological_domain_count)
            return error.InvalidRootUptakeLedgerDomainCount;
        if (!std.math.isFinite(plant_population_count[plant]) or plant_population_count[plant] < 0)
            return error.InvalidRootUptakeLedgerPopulation;
        const cell = plant / species_count;
        for (0..domain_count) |domain| for (0..grid.active_soil_layer_count[cell]) |local_layer| {
            const root = try roots.layerIndex(plant, domain, local_layer);
            inline for (.{ roots.water_uptake_m3_per_h[root], roots.root_length_density_m_per_m3[root] }) |value|
                if (!std.math.isFinite(value)) return error.NonFiniteRootUptakeLedgerInput;
            inline for (.{
                roots.gaseous_carbon_dioxide_g_c[root], roots.aqueous_carbon_dioxide_g_c[root],
                roots.gaseous_oxygen_g_o[root],         roots.aqueous_oxygen_g_o[root],
                roots.gaseous_methane_g_c[root],        roots.aqueous_methane_g_c[root],
                roots.gaseous_nitrous_oxide_g_n[root],  roots.aqueous_nitrous_oxide_g_n[root],
                roots.gaseous_ammonia_g_n[root],        roots.aqueous_ammonia_g_n[root],
                roots.gaseous_hydrogen_g_h[root],       roots.aqueous_hydrogen_g_h[root],
            }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootGasLedgerInput;
            inline for (.{
                roots.oxygen_demand_g_o_per_h[root],
                roots.oxygen_uptake_from_soil_g_o_per_h[root],
                roots.oxygen_uptake_from_root_pool_g_o_per_h[root],
                roots.fixation_uptake_g_n_per_h_by_layer[root],
                roots.ammonium_demand_nonband_g_n_per_h[root],
                roots.nitrate_demand_nonband_g_n_per_h[root],
                roots.phosphate_h2_demand_nonband_g_p_per_h[root],
                roots.phosphate_h_demand_nonband_g_p_per_h[root],
                roots.ammonium_demand_band_g_n_per_h[root],
                roots.nitrate_demand_band_g_n_per_h[root],
                roots.phosphate_h2_demand_band_g_p_per_h[root],
                roots.phosphate_h_demand_band_g_p_per_h[root],
            }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootCompetitionDemand;
            inline for (.{
                roots.ammonium_uptake_nonband_g_n_per_h[root],
                roots.nitrate_uptake_nonband_g_n_per_h[root],
                roots.phosphate_h2_uptake_nonband_g_p_per_h[root],
                roots.phosphate_h_uptake_nonband_g_p_per_h[root],
                roots.ammonium_uptake_band_g_n_per_h[root],
                roots.nitrate_uptake_band_g_n_per_h[root],
                roots.phosphate_h2_uptake_band_g_p_per_h[root],
                roots.phosphate_h_uptake_band_g_p_per_h[root],
            }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootNutrientUptake;
            if (salinity_enabled_by_cell[cell]) for (0..salt_species_count) |salt| {
                const value = roots.salt_uptake_mol_per_h[root * salt_species_count + salt];
                if (!std.math.isFinite(value)) return error.NonFiniteRootSaltUptake;
            };
            for (0..organic_fraction_count) |fraction| {
                const substrate = root * organic_fraction_count + fraction;
                inline for (.{
                    roots.exudate_carbon_exchange_g_c_per_h[substrate],
                    roots.exudate_nitrogen_exchange_g_n_per_h[substrate],
                    roots.exudate_phosphorus_exchange_g_p_per_h[substrate],
                }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootExudateExchange;
            }
        };
    }

    @memset(state.total_root_length_density_m_per_m3, 0);
    @memset(state.total_water_uptake_m3_per_h, 0);
    @memset(state.convective_water_heat_megajoules_per_h, 0);
    inline for (state.total_root_gas_content_g) |values| @memset(values, 0);
    inline for (state.total_soil_to_root_gas_exchange_g_per_h) |values| @memset(values, 0);
    inline for (state.total_aqueous_to_gaseous_root_exchange_g_per_h) |values| @memset(values, 0);
    inline for (state.total_atmosphere_to_root_gas_exchange_g_per_h) |values| @memset(values, 0);
    @memset(state.total_salt_uptake_mol_per_h, 0);
    @memset(state.total_exudate_carbon_change_g_c_per_h, 0);
    @memset(state.total_exudate_nitrogen_change_g_n_per_h, 0);
    @memset(state.total_exudate_phosphorus_change_g_p_per_h, 0);
    inline for (state.total_competition_demand_by_layer) |values| @memset(values, 0);
    inline for (state.total_nutrient_uptake_by_layer) |values| @memset(values, 0);
    @memset(state.soil_oxygen_uptake_g_o_per_h, 0);
    @memset(state.root_pool_oxygen_uptake_g_o_per_h, 0);
    @memset(state.total_nitrogen_fixation_g_n_per_h, 0);
    for (0..roots.plant_count) |plant| {
        const cell = plant / species_count;
        for (0..biological_domain_count_by_plant[plant]) |domain| for (0..grid.active_soil_layer_count[cell]) |local_layer| {
            const layer = grid.layerIndex(cell, local_layer) catch unreachable;
            const root = roots.layerIndex(plant, domain, local_layer) catch unreachable;
            if (domain == 0) state.total_root_length_density_m_per_m3[layer] +=
                roots.root_length_density_m_per_m3[root] * plant_population_count[plant] / cell_area_m2[cell];
            const uptake_m3_per_h = roots.water_uptake_m3_per_h[root];
            state.total_water_uptake_m3_per_h[layer] += uptake_m3_per_h;
            state.convective_water_heat_megajoules_per_h[layer] += uptake_m3_per_h * 4.19 * grid.soil_temperature_k[layer];
            inline for (.{
                .{ roots.gaseous_carbon_dioxide_g_c, roots.aqueous_carbon_dioxide_g_c },
                .{ roots.gaseous_oxygen_g_o, roots.aqueous_oxygen_g_o },
                .{ roots.gaseous_methane_g_c, roots.aqueous_methane_g_c },
                .{ roots.gaseous_nitrous_oxide_g_n, roots.aqueous_nitrous_oxide_g_n },
                .{ roots.gaseous_ammonia_g_n, roots.aqueous_ammonia_g_n },
                .{ roots.gaseous_hydrogen_g_h, roots.aqueous_hydrogen_g_h },
            }, 0..) |phases, gas| state.total_root_gas_content_g[gas][layer] += phases[0][root] + phases[1][root];
            const transaction_order_by_output_gas = [_]usize{ 0, 5, 1, 2, 3, 4 };
            inline for (transaction_order_by_output_gas, 0..) |transaction_gas, output_gas| {
                const transaction = root * root_gas_count + transaction_gas;
                const soil_exchange = roots.soil_to_root_gas_exchange_g_per_h[transaction];
                const phase_exchange = roots.aqueous_to_gaseous_root_exchange_g_per_h[transaction];
                const atmosphere_exchange = roots.atmosphere_to_root_gas_exchange_g_per_h[transaction];
                inline for (.{ soil_exchange, phase_exchange, atmosphere_exchange }) |value|
                    if (!std.math.isFinite(value)) return error.NonFiniteRootGasTransaction;
                state.total_soil_to_root_gas_exchange_g_per_h[output_gas][layer] += soil_exchange;
                state.total_aqueous_to_gaseous_root_exchange_g_per_h[output_gas][layer] += phase_exchange;
                state.total_atmosphere_to_root_gas_exchange_g_per_h[output_gas][layer] += atmosphere_exchange;
            }
            if (salinity_enabled_by_cell[cell]) {
                for (0..salt_species_count) |salt|
                    state.total_salt_uptake_mol_per_h[layer * salt_species_count + salt] +=
                        roots.salt_uptake_mol_per_h[root * salt_species_count + salt];
            }
            for (0..organic_fraction_count) |fraction| {
                const source = root * organic_fraction_count + fraction;
                const destination = layer * organic_fraction_count + fraction;
                // EXTRACT TDFOM* receives the opposite sign from RDFOM*.
                state.total_exudate_carbon_change_g_c_per_h[destination] -= roots.exudate_carbon_exchange_g_c_per_h[source];
                state.total_exudate_nitrogen_change_g_n_per_h[destination] -= roots.exudate_nitrogen_exchange_g_n_per_h[source];
                state.total_exudate_phosphorus_change_g_p_per_h[destination] -= roots.exudate_phosphorus_exchange_g_p_per_h[source];
            }
            inline for (.{
                roots.oxygen_demand_g_o_per_h,
                roots.ammonium_demand_nonband_g_n_per_h,
                roots.nitrate_demand_nonband_g_n_per_h,
                roots.phosphate_h2_demand_nonband_g_p_per_h,
                roots.phosphate_h_demand_nonband_g_p_per_h,
                roots.ammonium_demand_band_g_n_per_h,
                roots.nitrate_demand_band_g_n_per_h,
                roots.phosphate_h2_demand_band_g_p_per_h,
                roots.phosphate_h_demand_band_g_p_per_h,
            }, 0..) |demand, kind| state.total_competition_demand_by_layer[kind][layer] += demand[root];
            inline for (.{
                roots.ammonium_uptake_nonband_g_n_per_h,
                roots.nitrate_uptake_nonband_g_n_per_h,
                roots.phosphate_h2_uptake_nonband_g_p_per_h,
                roots.phosphate_h_uptake_nonband_g_p_per_h,
                roots.ammonium_uptake_band_g_n_per_h,
                roots.nitrate_uptake_band_g_n_per_h,
                roots.phosphate_h2_uptake_band_g_p_per_h,
                roots.phosphate_h_uptake_band_g_p_per_h,
            }, 0..) |uptake, kind| state.total_nutrient_uptake_by_layer[kind][layer] += uptake[root];
            state.soil_oxygen_uptake_g_o_per_h[layer] += roots.oxygen_uptake_from_soil_g_o_per_h[root];
            state.root_pool_oxygen_uptake_g_o_per_h[layer] += roots.oxygen_uptake_from_root_pool_g_o_per_h[root];
            state.total_nitrogen_fixation_g_n_per_h[layer] += roots.fixation_uptake_g_n_per_h_by_layer[root];
        };
    }
    inline for (.{
        state.total_root_length_density_m_per_m3,
        state.total_water_uptake_m3_per_h,
        state.convective_water_heat_megajoules_per_h,
    }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootUptakeLedger;
    inline for (state.total_root_gas_content_g) |values| for (values) |value|
        if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootGasLedger;
    inline for (.{
        state.total_soil_to_root_gas_exchange_g_per_h,
        state.total_aqueous_to_gaseous_root_exchange_g_per_h,
        state.total_atmosphere_to_root_gas_exchange_g_per_h,
    }) |transactions| inline for (transactions) |values| for (values) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteRootGasTransactionLedger;
    inline for (.{
        state.total_salt_uptake_mol_per_h,
        state.total_exudate_carbon_change_g_c_per_h,
        state.total_exudate_nitrogen_change_g_n_per_h,
        state.total_exudate_phosphorus_change_g_p_per_h,
    }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootBoundaryLedger;
    inline for (state.total_competition_demand_by_layer) |values| for (values) |value|
        if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootCompetitionLedger;
    inline for (state.total_nutrient_uptake_by_layer) |values| for (values) |value|
        if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootNutrientUptakeLedger;
    inline for (.{ state.soil_oxygen_uptake_g_o_per_h, state.root_pool_oxygen_uptake_g_o_per_h, state.total_nitrogen_fixation_g_n_per_h }) |values|
        for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootOxygenBoundaryLedger;
}

pub fn atmosphereToRootForCellGPerH(state: *const State, grid: *const Grid, cell: usize, gas: usize) !f64 {
    if (cell >= grid.cell_count or gas >= root_gas_count or state.layer_count != grid.layer_count)
        return error.RootUptakeLedgerDimensionMismatch;
    var total: f64 = 0;
    for (0..grid.active_soil_layer_count[cell]) |local_layer|
        total += state.total_atmosphere_to_root_gas_exchange_g_per_h[gas][try grid.layerIndex(cell, local_layer)];
    if (!std.math.isFinite(total)) return error.NonFiniteRootGasTransactionLedger;
    return total;
}

pub const CanopyGasBoundary = struct {
    carbon_dioxide_net_input_g_c_per_h: f64,
    methane_net_input_g_c_per_h: f64,
    oxygen_net_input_g_o_per_h: f64,
};

/// EXTRACT 784--789 and REDIST 6530--6578: root gaseous-atmosphere exchange
/// is a direct canopy-air boundary flux, not an internal root/soil transfer.
/// The accepted root transport ledger is positive atmosphere -> root, while
/// GROSUB/EXTRACT root gas withdrawal retains its negative loss sign; REDIST
/// adds both source-signed terms to XCNET/XHNET/XONET.
pub fn canopyGasBoundaryForCell(
    state: *const State,
    grid: *const Grid,
    root_gas_withdrawal_g_element_per_h_by_gas_and_cell: [root_gas_count][]const f64,
    cell: usize,
) !CanopyGasBoundary {
    if (cell >= grid.cell_count) return error.RootUptakeLedgerDimensionMismatch;
    inline for (root_gas_withdrawal_g_element_per_h_by_gas_and_cell) |values|
        if (values.len != grid.cell_count) return error.RootUptakeLedgerDimensionMismatch;
    const result: CanopyGasBoundary = .{
        .carbon_dioxide_net_input_g_c_per_h = try atmosphereToRootForCellGPerH(state, grid, cell, 0) +
            root_gas_withdrawal_g_element_per_h_by_gas_and_cell[0][cell],
        .oxygen_net_input_g_o_per_h = try atmosphereToRootForCellGPerH(state, grid, cell, 1) +
            root_gas_withdrawal_g_element_per_h_by_gas_and_cell[1][cell],
        .methane_net_input_g_c_per_h = try atmosphereToRootForCellGPerH(state, grid, cell, 2) +
            root_gas_withdrawal_g_element_per_h_by_gas_and_cell[2][cell],
    };
    inline for (@typeInfo(CanopyGasBoundary).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteRootGasTransactionLedger;
    return result;
}

test "REDIST canopy carrier receives per-cell root atmosphere uptake and signed withdrawal" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 20 },
    );
    var grid = try Grid.init(std.testing.allocator, config);
    defer grid.deinit();
    var state = try State.init(std.testing.allocator, grid.layer_count);
    defer state.deinit();

    // Cell 0 takes 3 g C CO2, 4 g C CH4 and 5 g O O2 from canopy air over
    // two layers. Cell 1 deliberately carries different one-layer totals so
    // a global/same-cell shortcut cannot pass.
    state.total_atmosphere_to_root_gas_exchange_g_per_h[0][0] = 1;
    state.total_atmosphere_to_root_gas_exchange_g_per_h[0][1] = 2;
    state.total_atmosphere_to_root_gas_exchange_g_per_h[2][0] = 1;
    state.total_atmosphere_to_root_gas_exchange_g_per_h[2][1] = 3;
    state.total_atmosphere_to_root_gas_exchange_g_per_h[1][0] = 2;
    state.total_atmosphere_to_root_gas_exchange_g_per_h[1][1] = 3;
    state.total_atmosphere_to_root_gas_exchange_g_per_h[0][2] = 20;
    state.total_atmosphere_to_root_gas_exchange_g_per_h[2][2] = 30;
    state.total_atmosphere_to_root_gas_exchange_g_per_h[1][2] = 40;
    grid.active_soil_layer_count[1] = 1;

    const withdrawal: [root_gas_count][]const f64 = .{
        &.{ -0.5, -2 }, // CO2 release offsets the positive atmosphere sink.
        &.{ -1.5, -4 }, // O2 release retains the same source sign.
        &.{ -1.0, -6 }, // CH4 release retains the same source sign.
        &.{ 0, 0 },
        &.{ 0, 0 },
        &.{ 0, 0 },
    };
    const first = try canopyGasBoundaryForCell(&state, &grid, withdrawal, 0);
    try std.testing.expectEqual(@as(f64, 2.5), first.carbon_dioxide_net_input_g_c_per_h);
    try std.testing.expectEqual(@as(f64, 3), first.methane_net_input_g_c_per_h);
    try std.testing.expectEqual(@as(f64, 3.5), first.oxygen_net_input_g_o_per_h);
    const second = try canopyGasBoundaryForCell(&state, &grid, withdrawal, 1);
    try std.testing.expectEqual(@as(f64, 18), second.carbon_dioxide_net_input_g_c_per_h);
    try std.testing.expectEqual(@as(f64, 24), second.methane_net_input_g_c_per_h);
    try std.testing.expectEqual(@as(f64, 36), second.oxygen_net_input_g_o_per_h);
}

test "EXTRACT root uptake ledger supports seven species and preserves source signs" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 7 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 20 },
    );
    var grid = try Grid.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 290;
    var roots = try Roots.init(std.testing.allocator, 7, 2, 1);
    defer roots.deinit();
    for (0..7) |plant| for (0..2) |domain| for (0..2) |layer| {
        const root = try roots.layerIndex(plant, domain, layer);
        roots.root_length_density_m_per_m3[root] = @floatFromInt(plant + 1);
        roots.water_uptake_m3_per_h[root] = -0.01 * @as(f64, @floatFromInt(layer + 1));
        roots.gaseous_carbon_dioxide_g_c[root] = 1;
        roots.aqueous_carbon_dioxide_g_c[root] = 2;
        roots.soil_to_root_gas_exchange_g_per_h[root * root_gas_count] = 1;
        roots.aqueous_to_gaseous_root_exchange_g_per_h[root * root_gas_count] = -0.5;
        roots.atmosphere_to_root_gas_exchange_g_per_h[root * root_gas_count] = 0.25;
        roots.soil_to_root_gas_exchange_g_per_h[root * root_gas_count + 5] = 2;
        roots.salt_uptake_mol_per_h[root * salt_species_count] = 0.5;
        roots.exudate_carbon_exchange_g_c_per_h[root * organic_fraction_count] = -0.25;
        roots.oxygen_demand_g_o_per_h[root] = 0.75;
        roots.oxygen_uptake_from_soil_g_o_per_h[root] = 0.2;
        roots.oxygen_uptake_from_root_pool_g_o_per_h[root] = 0.1;
        roots.fixation_uptake_g_n_per_h_by_layer[root] = 0.05;
        roots.ammonium_uptake_nonband_g_n_per_h[root] = 0.3;
    };
    var state = try State.init(std.testing.allocator, grid.layer_count);
    defer state.deinit();
    try refresh(&state, &grid, &roots, 7, &.{ 2, 2, 2, 2, 2, 2, 2 }, &.{ 10, 10, 10, 10, 10, 10, 10 }, &.{5}, &.{true});
    try std.testing.expectApproxEqAbs(@as(f64, 56), state.total_root_length_density_m_per_m3[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.14), state.total_water_uptake_m3_per_h[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.14 * 4.19 * 280), state.convective_water_heat_megajoules_per_h[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 42), state.total_root_gas_content_g[0][0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 14), state.total_soil_to_root_gas_exchange_g_per_h[0][0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -7), state.total_aqueous_to_gaseous_root_exchange_g_per_h[0][0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), state.total_atmosphere_to_root_gas_exchange_g_per_h[0][0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7), try atmosphereToRootForCellGPerH(&state, &grid, 0, 0), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 28), state.total_soil_to_root_gas_exchange_g_per_h[1][0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7), state.total_salt_uptake_mol_per_h[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), state.total_exudate_carbon_change_g_c_per_h[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), state.total_competition_demand_by_layer[0][0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.8), state.soil_oxygen_uptake_g_o_per_h[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4), state.root_pool_oxygen_uptake_g_o_per_h[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), state.total_nitrogen_fixation_g_n_per_h[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4.2), state.total_nutrient_uptake_by_layer[0][0], 1e-12);
}

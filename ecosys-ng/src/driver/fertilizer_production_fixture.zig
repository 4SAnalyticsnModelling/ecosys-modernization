const std = @import("std");
const ecosys = @import("ecosys_ng");

/// Calls the actual composition-root phase with real scientific owners. Only
/// unrelated driver configuration is reduced to the fields that phase reads.
pub fn verifyLimeOnly(comptime advance: anytype, comptime Hour: type) !void {
    try verifyApplication(advance, Hour, .lime);
}

pub fn verifyGypsumOnly(comptime advance: anytype, comptime Hour: type) !void {
    try verifyApplication(advance, Hour, .gypsum);
}

pub fn verifyOrganic(comptime advance: anytype, comptime Hour: type) !void {
    try verifyApplication(advance, Hour, .organic_surface);
    try verifyApplication(advance, Hour, .organic_soil);
}

const Application = enum { lime, gypsum, organic_surface, organic_soil };

fn verifyApplication(comptime advance: anytype, comptime Hour: type, application: Application) !void {
    const is_organic = application == .organic_surface or application == .organic_soil;
    const allocator = std.testing.allocator;
    const cells = 3;
    const layers = 2;
    const areas: []const f64 = &.{ 0.5, 2, 3 };
    const active_layers: []const usize = &.{ 1, 2, 1 };
    const noon: []const u8 = &.{ 11, 12, 13 };
    var grid = .{ .cell_count = cells, .active_soil_layer_count = active_layers };
    var properties = .{ .layer_thickness_m = @as([]const f64, &.{ 0.2, 0.3, 0.1, 0.2, 0.4, 0.5 }) };
    var config = .{ .soil_layers = layers };
    var runscript = .{ .fertilizer_nitrogen_molar_mass_g_per_mol = @as(f64, 14) };
    var pass = .{ .scene_index = @as(usize, 0) };
    var catalog = ecosys.fertilizer_schedule.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("Ottawa", switch (application) {
        .lime => @embedFile("../validation/testdata/ottawa/runottawa_input_files/management/soil/fertilizer/f25fr98"),
        .gypsum => "15041998 0 0 0 0 0 0 0 0 0 0 0 0 360 0 0 0 0 0 0 0 0 0 0 0\n",
        .organic_surface => "15041998 0 0 0 0 0 0 0 0 0 0 0 0 0 10 1 0.1 5 0.5 0.05 0 0 0 0 0\n",
        .organic_soil => "15041998 0 0 0 0 0 0 0 0 0 0 0 0 0 10 1 0.1 5 0.5 0.05 0.15 0 0 0 0\n",
    });
    var indices = [_]?usize{ 0, 0, 0 };
    var maps = [_]?ecosys.fertilizer_management_dispatch.ScheduleMap{.{ .allocator = allocator, .catalog_index_by_cell = &indices }};
    var soil_n = try ecosys.fertilizer_nitrogen_inventory.State.init(allocator, cells, layers);
    defer soil_n.deinit();
    var surface_n = try ecosys.surface_litter_fertilizer.State.init(allocator, cells);
    defer surface_n.deinit();
    var reactive_n = try ecosys.soil_reactive_nitrogen_state.State.init(allocator, cells * layers, 1);
    defer reactive_n.deinit();
    var minerals = try ecosys.mineral_fertilizer_inventory.State.init(allocator, cells, layers);
    defer minerals.deinit();
    const organic = ecosys.soil_organic_initialization;
    var soil_organic = try organic.State.init(allocator, cells * layers);
    defer soil_organic.deinit();
    var surface_organic = try organic.State.init(allocator, cells);
    defer surface_organic.deinit();
    var parameters = try ecosys.soil_organic_parameters.sourceParameters(allocator);
    defer parameters.deinit();
    var organic_c = [_]f64{0} ** cells;
    var biome_c = [_]f64{0} ** cells;
    var organic_n = [_]f64{0} ** cells;
    var organic_p = [_]f64{0} ** cells;
    const organic_c_slice: []f64 = &organic_c;
    const biome_c_slice: []f64 = &biome_c;
    const organic_n_slice: []f64 = &organic_n;
    const organic_p_slice: []f64 = &organic_p;
    var hourly = try ecosys.hourly_cell_conservation.BoundaryLedger.init(allocator, cells);
    defer hourly.deinit();
    var local = try ecosys.fertilizer_management_dispatch.LocalActivityState.init(allocator, cells, layers);
    defer local.deinit();
    var layer_ledger = try ecosys.layer_local_conservation.Ledger.init(allocator, try ecosys.layer_local_conservation.Layout.init(cells, layers, 1));
    defer layer_ledger.deinit();
    var landscape: ecosys.landscape_mass_balance_checkpoint.State = .{ .boundary_ledger = .{}, .monitor = null };
    defer landscape.deinit();
    var census: ecosys.stage_execution_census.Census = .{};
    const driver = .{
        .fertilizer_schedule_maps = &maps,
        .fertilizer_catalog = &catalog,
        .fertilizer_local_activity = &local,
        .canopy_cell_area_m2 = &areas,
        .state = &grid,
        .soil_solver_property_state = &properties,
        .surface_organic_state = &surface_organic,
        .hourly_cell_boundary_ledger = &hourly,
        .soil_fertilizer_inventory = &soil_n,
        .surface_litter_fertilizer_state = &surface_n,
        .soil_reactive_nitrogen_state = &reactive_n,
        .runscript = &runscript,
        .mineral_fertilizer_inventory = &minerals,
        .soil_organic_state = &soil_organic,
        .organic_parameters = &parameters,
        .config = &config,
        .daily_organic_fertilizer_carbon_input_g_c = &organic_c_slice,
        .daily_biome_organic_carbon_input_g_c = &biome_c_slice,
        .daily_organic_fertilizer_phosphorus_input_g_p = &organic_p_slice,
        .daily_organic_fertilizer_nitrogen_input_g_n = &organic_n_slice,
        .hourly_layer_boundary_ledger = &layer_ledger,
        .landscape_mass_balance_state = &landscape,
        .stage_census = &census,
    };
    const advancing = .{ .pass = &pass, .solar_noon_hour_by_cell = &noon };
    const audit = ecosys.mass_balance_audit;
    for (1..25) |source_hour| {
        hourly.reset();
        layer_ledger.reset();
        census.observeHour(source_hour);
        const hour: Hour = .{
            .timestamp = .{ .year = 1998, .month = 4, .day_of_month = 15, .day_of_year = 105, .hour = @intCast(source_hour), .minute = 0 },
            .current_year = 1998,
            .current_day_of_year = 105,
            .begins_day = source_hour == 1,
        };
        try advance(driver, advancing, &hour);
        var totals = std.mem.zeroes(audit.Totals);
        for (areas, 0..) |area, cell| {
            totals.landscape_area_m2 += area;
            const expected_mol: f64 = if (source_hour >= noon[cell]) 9 * area else 0;
            try std.testing.expectEqual(if (application == .lime) expected_mol else 0, minerals.soil[cell * layers].calcite_mol);
            try std.testing.expectEqual(if (application == .gypsum) expected_mol else 0, minerals.soil[cell * layers].gypsum_mol);
            try std.testing.expectEqual(@as(f64, 0), minerals.soil[cell * layers + 1].calcite_mol);
            // Independent CaCO3 stoichiometry: one mole of C per mole of Ca.
            totals.carbon_dioxide_carbon_g += minerals.soil[cell * layers].calcite_mol * 12;
            const expected_input: f64 = if (source_hour == noon[cell]) (if (application == .lime) @as(f64, 108) else if (is_organic) @as(f64, 15) else 0) * area else 0;
            try std.testing.expectEqual(expected_input, hourly.cells[cell].carbon_input_g);
            const expected_organic_c: f64 = if (is_organic and source_hour >= noon[cell]) 15 * area else 0;
            try std.testing.expectEqual(expected_organic_c, organic_c[cell]);
            // This is a parallel NBP diagnostic, not another material input.
            try std.testing.expectEqual(expected_organic_c, biome_c[cell]);
            const surface_c = try surface_organic.totalCarbon_g_c(cell);
            try std.testing.expectApproxEqAbs(if (application == .organic_surface) expected_organic_c else 0, surface_c, 1e-12);
            totals.organic_carbon_g += surface_c;
            for (0..layers) |layer| {
                const soil_c = try soil_organic.totalCarbon_g_c(cell * layers + layer);
                // Depth 0.15 m selects layer 1 only in the two-layer cell.
                const destination_layer: usize = if (cell == 1) 1 else 0;
                try std.testing.expectApproxEqAbs(if (application == .organic_soil and layer == destination_layer) expected_organic_c else 0, soil_c, 1e-12);
                totals.organic_carbon_g += soil_c;
            }
        }
        // Preview the real daily adapter without repeatedly accumulating a
        // cumulative day. The live day is published only once, at hour 24.
        var daily_candidate = landscape.boundary_ledger;
        try daily_candidate.accumulateAcceptedFertilizer(soil_n.daily_nitrogen_input_g_n, &organic_n, minerals.daily_phosphorus_input_g_p, &organic_p, &organic_c);
        try daily_candidate.publish(&totals);
        // Before the repair, the first noon has +54 g C unexplained: exactly
        // the Ottawa +108 g C/m2 failure at this cell's half-square-metre area.
        if (is_organic) {
            try std.testing.expectApproxEqAbs(@as(f64, 0), (try audit.balance(totals)).carbon_g, 1e-12);
        } else {
            try std.testing.expectEqual(@as(f64, 0), (try audit.balance(totals)).carbon_g);
        }
        if (source_hour == 24) landscape.boundary_ledger = daily_candidate;
    }
    try std.testing.expectEqual(if (application == .lime) @as(f64, 594) else 0, landscape.boundary_ledger.cumulative.mineral_fertilizer_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), landscape.boundary_ledger.cumulative.carbon_dioxide_input_g_c);
    try std.testing.expectEqual(if (is_organic) @as(f64, 82.5) else 0, landscape.boundary_ledger.cumulative.organic_fertilizer_carbon_g_c);
    try std.testing.expectEqual(@as(u64, 3), census.get(.fertilizer_application).entries);
}

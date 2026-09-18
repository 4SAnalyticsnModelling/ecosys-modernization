const std = @import("std");
const output_record = @import("record.zig");
const output_selection = @import("selection.zig");
const output_stream_bank = @import("stream_bank.zig");
const output_hour_transaction = @import("hour_transaction.zig");

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    variables: []output_record.Variable,
    owned_names: [][]u8,

    pub fn deinit(self: *Catalog) void {
        for (self.owned_names) |name| self.allocator.free(name);
        self.allocator.free(self.owned_names);
        self.allocator.free(self.variables);
        self.* = undefined;
    }
};

pub fn hourlyCatalog(
    allocator: std.mem.Allocator,
    species_count: usize,
    soil_layer_count: usize,
) !Catalog {
    if (species_count == 0 or soil_layer_count == 0)
        return error.InvalidVisualizationCatalogDimensions;
    const species_values = try std.math.mul(usize, 2, species_count);
    const layer_values = try std.math.mul(usize, 2, soil_layer_count);
    const count = try std.math.add(
        usize,
        try std.math.add(usize, 10, species_values),
        layer_values,
    );
    var result = try initCatalog(allocator, count);
    errdefer result.deinit();
    var index: usize = 0;
    for (0..species_count) |species| {
        try setCatalogVariable(
            &result,
            index,
            "species_{d}_gross_primary_productivity",
            .{species + 1},
            "kg_C_m-2_s-1",
        );
        index += 1;
    }
    for (0..species_count) |species| {
        try setCatalogVariable(
            &result,
            index,
            "species_{d}_respiration",
            .{species + 1},
            "kg_C_m-2_s-1",
        );
        index += 1;
    }
    const ecosystem_names = [_][]const u8{
        "ecosystem_gross_primary_productivity",
        "ecosystem_net_primary_productivity",
        "ecosystem_autotrophic_respiration",
        "ecosystem_heterotrophic_respiration",
        "net_biome_productivity",
        "carbon_dioxide_flux",
        "methane_flux",
        "net_radiation",
        "latent_heat_flux",
        "sensible_heat_flux",
    };
    for (ecosystem_names, 0..) |name, offset| {
        try setCatalogVariable(
            &result,
            index,
            "{s}",
            .{name},
            if (offset < 7) "kg_C_m-2_s-1" else "W_m-2",
        );
        index += 1;
    }
    for (0..soil_layer_count) |layer| {
        try setCatalogVariable(
            &result,
            index,
            "soil_layer_{d}_volumetric_water",
            .{layer + 1},
            "m3_m-3",
        );
        index += 1;
    }
    for (0..soil_layer_count) |layer| {
        try setCatalogVariable(
            &result,
            index,
            "soil_layer_{d}_temperature",
            .{layer + 1},
            "K",
        );
        index += 1;
    }
    std.debug.assert(index == count);
    return result;
}

pub fn dailyCatalog(
    allocator: std.mem.Allocator,
    species_count: usize,
    organic_carbon_layer_count: usize,
) !Catalog {
    if (species_count == 0 or organic_carbon_layer_count == 0)
        return error.InvalidVisualizationCatalogDimensions;
    const species_values = try std.math.mul(usize, 4, species_count);
    const count = try std.math.add(
        usize,
        try std.math.add(usize, 7, species_values),
        organic_carbon_layer_count,
    );
    var result = try initCatalog(allocator, count);
    errdefer result.deinit();
    var index: usize = 0;
    for (0..species_count) |species| {
        try setCatalogVariable(
            &result,
            index,
            "species_{d}_transpiration",
            .{species + 1},
            "mm_d-1",
        );
        index += 1;
    }
    const landscape_names = [_][]const u8{
        "evapotranspiration",
        "soil_evaporation",
        "runoff",
        "subsurface_outflow",
        "water_table_depth",
        "snow_depth",
        "leaf_area_index",
    };
    const landscape_units = [_][]const u8{
        "mm_d-1",
        "mm_d-1",
        "mm_d-1",
        "mm_d-1",
        "m",
        "m",
        "m2_m-2",
    };
    for (landscape_names, landscape_units) |name, unit| {
        try setCatalogVariable(&result, index, "{s}", .{name}, unit);
        index += 1;
    }
    inline for ([_][]const u8{ "leaf", "stalk", "root" }) |organ| {
        for (0..species_count) |species| {
            try setCatalogVariable(
                &result,
                index,
                "species_{d}_{s}_carbon",
                .{ species + 1, organ },
                "kg_C_m-2",
            );
            index += 1;
        }
    }
    for (0..organic_carbon_layer_count) |layer| {
        try setCatalogVariable(
            &result,
            index,
            "soil_layer_{d}_organic_carbon",
            .{layer},
            "kg_C_m-2",
        );
        index += 1;
    }
    std.debug.assert(index == count);
    return result;
}

fn initCatalog(allocator: std.mem.Allocator, count: usize) !Catalog {
    const variables = try allocator.alloc(output_record.Variable, count);
    errdefer allocator.free(variables);
    const owned_names = try allocator.alloc([]u8, count);
    errdefer allocator.free(owned_names);
    for (owned_names) |*name| name.* = @constCast(&.{});
    return .{
        .allocator = allocator,
        .variables = variables,
        .owned_names = owned_names,
    };
}

fn setCatalogVariable(
    catalog: *Catalog,
    index: usize,
    comptime format: []const u8,
    arguments: anytype,
    unit: []const u8,
) !void {
    const name = try std.fmt.allocPrint(
        catalog.allocator,
        format,
        arguments,
    );
    catalog.owned_names[index] = name;
    catalog.variables[index] = .{ .name = name, .unit = unit };
}

pub const Streams = struct {
    allocator: std.mem.Allocator,
    visualization_start_year: u16,
    visualization_end_year: u16,
    scene_enabled: bool,
    hourly_catalog: Catalog,
    daily_catalog: Catalog,
    hourly_enabled: []bool,
    daily_enabled: []bool,
    hourly_bank: output_stream_bank.Bank,
    daily_bank: output_stream_bank.Bank,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        enabled: bool,
        cell_count: usize,
        species_count: usize,
        soil_layer_count: usize,
        visualization_start_year: u16,
        visualization_end_year: u16,
        stream_buffer_bytes: usize,
    ) !Streams {
        return initInternal(allocator, io, directory, enabled, cell_count, species_count, soil_layer_count, visualization_start_year, visualization_end_year, stream_buffer_bytes, null);
    }

    pub fn initTransactional(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        enabled: bool,
        cell_count: usize,
        species_count: usize,
        soil_layer_count: usize,
        visualization_start_year: u16,
        visualization_end_year: u16,
        stream_buffer_bytes: usize,
        coordinator: *output_hour_transaction.Coordinator,
    ) !Streams {
        return initInternal(allocator, io, directory, enabled, cell_count, species_count, soil_layer_count, visualization_start_year, visualization_end_year, stream_buffer_bytes, coordinator);
    }

    fn initInternal(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        enabled: bool,
        cell_count: usize,
        species_count: usize,
        soil_layer_count: usize,
        visualization_start_year: u16,
        visualization_end_year: u16,
        stream_buffer_bytes: usize,
        coordinator: ?*output_hour_transaction.Coordinator,
    ) !Streams {
        if (visualization_end_year < visualization_start_year)
            return error.InvalidVisualizationYearWindow;
        var hourly_catalog = try hourlyCatalog(
            allocator,
            species_count,
            soil_layer_count,
        );
        errdefer hourly_catalog.deinit();
        var daily_catalog = try dailyCatalog(
            allocator,
            species_count,
            try std.math.add(usize, soil_layer_count, 1),
        );
        errdefer daily_catalog.deinit();
        const hourly_enabled =
            try allocator.alloc(bool, hourly_catalog.variables.len);
        errdefer allocator.free(hourly_enabled);
        @memset(hourly_enabled, true);
        const daily_enabled =
            try allocator.alloc(bool, daily_catalog.variables.len);
        errdefer allocator.free(daily_enabled);
        @memset(daily_enabled, true);
        var hourly_bank = if (coordinator) |resolved|
            try output_stream_bank.Bank.initTransactional(allocator, io, directory, enabled, cell_count, hourly_catalog.variables.len, stream_buffer_bytes, .tab, resolved, .carbon)
        else
            try output_stream_bank.Bank.init(allocator, io, directory, enabled, cell_count, hourly_catalog.variables.len, stream_buffer_bytes, .tab);
        errdefer hourly_bank.deinit();
        var daily_bank = if (coordinator) |resolved|
            try output_stream_bank.Bank.initTransactional(allocator, io, directory, enabled, cell_count, daily_catalog.variables.len, stream_buffer_bytes, .tab, resolved, .carbon)
        else
            try output_stream_bank.Bank.init(allocator, io, directory, enabled, cell_count, daily_catalog.variables.len, stream_buffer_bytes, .tab);
        errdefer daily_bank.deinit();
        return .{
            .allocator = allocator,
            .visualization_start_year = visualization_start_year,
            .visualization_end_year = visualization_end_year,
            .scene_enabled = enabled,
            .hourly_catalog = hourly_catalog,
            .daily_catalog = daily_catalog,
            .hourly_enabled = hourly_enabled,
            .daily_enabled = daily_enabled,
            .hourly_bank = hourly_bank,
            .daily_bank = daily_bank,
        };
    }

    pub fn deinit(self: *Streams) void {
        self.daily_bank.deinit();
        self.hourly_bank.deinit();
        self.allocator.free(self.daily_enabled);
        self.allocator.free(self.hourly_enabled);
        self.daily_catalog.deinit();
        self.hourly_catalog.deinit();
        self.* = undefined;
    }

    pub fn configureScene(
        self: *Streams,
        enabled: bool,
        visualization_start_year: u16,
        visualization_end_year: u16,
    ) !void {
        if (visualization_end_year < visualization_start_year)
            return error.InvalidVisualizationYearWindow;
        if (enabled and !self.hourly_bank.enabled)
            return error.VisualizationStreamsWereNotAllocated;
        self.scene_enabled = enabled;
        self.visualization_start_year = visualization_start_year;
        self.visualization_end_year = visualization_end_year;
    }

    pub fn writeHourly(
        self: *Streams,
        cell: usize,
        longitude_degrees_east: f64,
        latitude_degrees_north: f64,
        timestamp: output_record.Timestamp,
        pass: output_record.PassOrdinals,
        values: []const f64,
    ) !bool {
        return self.write(
            true,
            cell,
            longitude_degrees_east,
            latitude_degrees_north,
            timestamp,
            pass,
            values,
        );
    }

    pub fn writeDaily(
        self: *Streams,
        cell: usize,
        longitude_degrees_east: f64,
        latitude_degrees_north: f64,
        timestamp: output_record.Timestamp,
        pass: output_record.PassOrdinals,
        values: []const f64,
    ) !bool {
        return self.write(
            false,
            cell,
            longitude_degrees_east,
            latitude_degrees_north,
            timestamp,
            pass,
            values,
        );
    }

    pub fn calculateAndWriteHourly(
        self: *Streams,
        cell: usize,
        longitude_degrees_east: f64,
        latitude_degrees_north: f64,
        timestamp: output_record.Timestamp,
        pass: output_record.PassOrdinals,
        inputs: HourlyInputs,
    ) !bool {
        if (!self.scene_enabled or !self.hourly_bank.enabled or
            timestamp.year < self.visualization_start_year or
            timestamp.year > self.visualization_end_year)
            return false;
        const row = try self.hourly_bank.row(cell);
        try hourlyInto(row, inputs);
        return self.writeHourly(
            cell,
            longitude_degrees_east,
            latitude_degrees_north,
            timestamp,
            pass,
            row,
        );
    }

    pub fn calculateAndWriteDaily(
        self: *Streams,
        cell: usize,
        longitude_degrees_east: f64,
        latitude_degrees_north: f64,
        timestamp: output_record.Timestamp,
        pass: output_record.PassOrdinals,
        inputs: DailyInputs,
    ) !bool {
        if (!self.scene_enabled or !self.daily_bank.enabled or
            timestamp.year < self.visualization_start_year or
            timestamp.year > self.visualization_end_year)
            return false;
        const row = try self.daily_bank.row(cell);
        try dailyInto(row, inputs);
        return self.writeDaily(
            cell,
            longitude_degrees_east,
            latitude_degrees_north,
            timestamp,
            pass,
            row,
        );
    }

    pub fn finish(self: *Streams) !void {
        try self.hourly_bank.finish();
        try self.daily_bank.finish();
    }

    fn write(
        self: *Streams,
        hourly_output: bool,
        cell: usize,
        longitude_degrees_east: f64,
        latitude_degrees_north: f64,
        timestamp: output_record.Timestamp,
        pass: output_record.PassOrdinals,
        values: []const f64,
    ) !bool {
        if (!self.scene_enabled or
            timestamp.year < self.visualization_start_year or
            timestamp.year > self.visualization_end_year)
            return false;
        const bank = if (hourly_output)
            &self.hourly_bank
        else
            &self.daily_bank;
        if (!bank.enabled) return false;
        const catalog = if (hourly_output)
            self.hourly_catalog.variables
        else
            self.daily_catalog.variables;
        const enabled_variables = if (hourly_output)
            self.hourly_enabled
        else
            self.daily_enabled;
        if (values.len != catalog.len)
            return error.VisualizationStreamRecordDimensionMismatch;
        const row = try bank.row(cell);
        if (row.ptr != values.ptr) @memcpy(row, values);
        // Same self-describing convention as the model's other output, so a
        // visualization file is locatable without knowing the grid layout. The
        // earlier `visual_hourly_c<column>_r<row>_<year>.txt` form used grid
        // indices, which for a single-cell run were always `c1_r1`.
        const file_name = try output_record.buildOutputFileName(
            self.allocator,
            latitude_degrees_north,
            longitude_degrees_east,
            .soil_or_eco,
            timestamp.year,
            pass,
            cell + 1,
            if (hourly_output) "visual_hourly" else "visual_daily",
        );
        defer self.allocator.free(file_name);
        const selection: output_selection.Selection = .{
            .allocator = self.allocator,
            .first_date = .{ .day = 1, .month = 1 },
            .last_date = .{ .day = 31, .month = 12 },
            .enabled_variables = enabled_variables,
        };
        return bank.streams[cell].write(
            file_name,
            catalog,
            selection,
            enabled_variables,
            .{
                .timestamp = timestamp,
                // The filename carries a stable cell key; the row preserves
                // the physical site coordinates the user entered.
                .longitude_degrees_east = longitude_degrees_east,
                .latitude_degrees_north = latitude_degrees_north,
                .values = row,
            },
        );
    }
};

pub const HourlyInputs = struct {
    cell_area_m2: f64,
    species_cumulative_gross_carbon_g: []const f64,
    species_cumulative_respired_carbon_g: []const f64,
    ecosystem_gross_primary_productivity_g: f64,
    ecosystem_net_primary_productivity_g: f64,
    ecosystem_autotrophic_respiration_g: f64,
    ecosystem_heterotrophic_respiration_g: f64,
    net_biome_productivity_g: f64,
    carbon_dioxide_flux_g: f64,
    methane_flux_g: f64,
    net_radiation_megajoules_h: f64,
    latent_heat_flux_megajoules_h: f64,
    sensible_heat_flux_megajoules_h: f64,
    liquid_water_m3_by_layer: []const f64,
    air_volume_m3_by_layer: []const f64,
    macropore_water_m3_by_layer: []const f64,
    total_volume_m3_by_layer: []const f64,
    soil_temperature_k_by_layer: []const f64,
};

pub const Record = struct {
    allocator: std.mem.Allocator,
    values: []f64,
    pub fn deinit(self: *Record) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

/// VISUAL hourly order generalized as: species GPP, species respiration,
/// seven ecosystem carbon fluxes, three energy fluxes, water profile, and
/// temperature profile.
pub fn hourly(allocator: std.mem.Allocator, inputs: HourlyInputs) !Record {
    const layers = inputs.liquid_water_m3_by_layer.len;
    const values = try allocator.alloc(f64, 10 + 2 * inputs.species_cumulative_gross_carbon_g.len + 2 * layers);
    errdefer allocator.free(values);
    try hourlyInto(values, inputs);
    return .{ .allocator = allocator, .values = values };
}

/// Allocation-free production kernel. Callers retain one runtime-sized row
/// per active tile/cell stream and overwrite it after the accepted hourly
/// science transaction.
pub fn hourlyInto(values: []f64, inputs: HourlyInputs) !void {
    try positiveArea(inputs.cell_area_m2);
    if (inputs.species_cumulative_gross_carbon_g.len != inputs.species_cumulative_respired_carbon_g.len) return error.VisualizationSpeciesDimensionMismatch;
    const layers = inputs.liquid_water_m3_by_layer.len;
    inline for (.{ inputs.air_volume_m3_by_layer, inputs.macropore_water_m3_by_layer, inputs.total_volume_m3_by_layer, inputs.soil_temperature_k_by_layer }) |slice| if (slice.len != layers) return error.VisualizationSoilDimensionMismatch;
    const expected_count = try std.math.add(
        usize,
        try std.math.add(
            usize,
            10,
            try std.math.mul(
                usize,
                2,
                inputs.species_cumulative_gross_carbon_g.len,
            ),
        ),
        try std.math.mul(usize, 2, layers),
    );
    if (values.len != expected_count)
        return error.VisualizationOutputDimensionMismatch;
    inline for (.{
        inputs.species_cumulative_gross_carbon_g,
        inputs.species_cumulative_respired_carbon_g,
        inputs.liquid_water_m3_by_layer,
        inputs.air_volume_m3_by_layer,
        inputs.macropore_water_m3_by_layer,
        inputs.total_volume_m3_by_layer,
        inputs.soil_temperature_k_by_layer,
    }) |slice| try finiteSlice(slice);
    inline for (.{
        inputs.ecosystem_gross_primary_productivity_g,
        inputs.ecosystem_net_primary_productivity_g,
        inputs.ecosystem_autotrophic_respiration_g,
        inputs.ecosystem_heterotrophic_respiration_g,
        inputs.net_biome_productivity_g,
        inputs.carbon_dioxide_flux_g,
        inputs.methane_flux_g,
        inputs.net_radiation_megajoules_h,
        inputs.latent_heat_flux_megajoules_h,
        inputs.sensible_heat_flux_megajoules_h,
    }) |value| try finite(value);
    for (
        inputs.liquid_water_m3_by_layer,
        inputs.air_volume_m3_by_layer,
        inputs.macropore_water_m3_by_layer,
        inputs.total_volume_m3_by_layer,
        inputs.soil_temperature_k_by_layer,
    ) |liquid, air, macropore_water, volume, temperature| {
        if (liquid < 0 or air < 0 or macropore_water < 0 or volume <= 0 or
            temperature <= 0)
            return error.InvalidVisualizationSoilState;
    }
    const carbon_rate = 0.001 / (inputs.cell_area_m2 * 3600.0);
    var i: usize = 0;
    for (inputs.species_cumulative_gross_carbon_g) |value| {
        values[i] = value * carbon_rate;
        i += 1;
    }
    for (inputs.species_cumulative_respired_carbon_g) |value| {
        values[i] = -value * carbon_rate;
        i += 1;
    }
    for ([_]f64{ inputs.ecosystem_gross_primary_productivity_g * carbon_rate, inputs.ecosystem_net_primary_productivity_g * carbon_rate, -inputs.ecosystem_autotrophic_respiration_g * carbon_rate, -inputs.ecosystem_heterotrophic_respiration_g * carbon_rate, inputs.net_biome_productivity_g * carbon_rate, -inputs.carbon_dioxide_flux_g * carbon_rate, -inputs.methane_flux_g * carbon_rate, inputs.net_radiation_megajoules_h * 277.8 / inputs.cell_area_m2, -inputs.latent_heat_flux_megajoules_h * 277.8 / inputs.cell_area_m2, -inputs.sensible_heat_flux_megajoules_h * 277.8 / inputs.cell_area_m2 }) |value| {
        values[i] = value;
        i += 1;
    }
    for (0..layers) |layer| {
        const volume = inputs.total_volume_m3_by_layer[layer];
        values[i] = (inputs.liquid_water_m3_by_layer[layer] + @min(inputs.air_volume_m3_by_layer[layer], inputs.macropore_water_m3_by_layer[layer])) / volume;
        i += 1;
    }
    for (inputs.soil_temperature_k_by_layer) |value| {
        values[i] = value;
        i += 1;
    }
    std.debug.assert(i == values.len);
    try finiteSlice(values);
}

pub const DailyInputs = struct {
    cell_area_m2: f64,
    cumulative_transpiration_source_m3_by_species: []const f64,
    cumulative_evapotranspiration_m3: f64,
    cumulative_runoff_m3: f64,
    cumulative_outflow_m3: f64,
    water_table_bottom_depth_m: f64,
    active_surface_depth_m: f64,
    snow_depth_m: f64,
    total_leaf_area_m2: f64,
    leaf_carbon_g_by_species: []const f64,
    stalk_carbon_g_by_species: []const f64,
    root_carbon_g_by_species: []const f64,
    organic_carbon_g_by_layer_including_surface: []const f64,
};

/// VISUAL daily order generalized as: transpiration by runtime species,
/// evapotranspiration, residual soil evaporation, runoff, outflow, water-table
/// depth, snow depth, LAI, species leaf/stalk/root C, and SOC profile.
pub fn daily(allocator: std.mem.Allocator, inputs: DailyInputs) !Record {
    const species = inputs.cumulative_transpiration_source_m3_by_species.len;
    const values = try allocator.alloc(f64, 7 + 4 * species + inputs.organic_carbon_g_by_layer_including_surface.len);
    errdefer allocator.free(values);
    try dailyInto(values, inputs);
    return .{ .allocator = allocator, .values = values };
}

/// Allocation-free daily VISUAL kernel for the reusable stream-bank row.
pub fn dailyInto(values: []f64, inputs: DailyInputs) !void {
    try positiveArea(inputs.cell_area_m2);
    const species = inputs.cumulative_transpiration_source_m3_by_species.len;
    if (inputs.leaf_carbon_g_by_species.len != species or inputs.stalk_carbon_g_by_species.len != species or inputs.root_carbon_g_by_species.len != species) return error.VisualizationSpeciesDimensionMismatch;
    const expected_count = try std.math.add(
        usize,
        try std.math.add(
            usize,
            7,
            try std.math.mul(usize, 4, species),
        ),
        inputs.organic_carbon_g_by_layer_including_surface.len,
    );
    if (values.len != expected_count)
        return error.VisualizationOutputDimensionMismatch;
    inline for (.{
        inputs.cumulative_transpiration_source_m3_by_species,
        inputs.leaf_carbon_g_by_species,
        inputs.stalk_carbon_g_by_species,
        inputs.root_carbon_g_by_species,
        inputs.organic_carbon_g_by_layer_including_surface,
    }) |slice| try finiteSlice(slice);
    inline for (.{
        inputs.cumulative_evapotranspiration_m3,
        inputs.cumulative_runoff_m3,
        inputs.cumulative_outflow_m3,
        inputs.water_table_bottom_depth_m,
        inputs.active_surface_depth_m,
        inputs.snow_depth_m,
        inputs.total_leaf_area_m2,
    }) |value| try finite(value);
    if (inputs.cumulative_evapotranspiration_m3 < 0 or
        inputs.cumulative_runoff_m3 < 0 or
        inputs.cumulative_outflow_m3 < 0 or
        inputs.snow_depth_m < 0 or
        inputs.total_leaf_area_m2 < 0)
        return error.InvalidVisualizationDailyState;
    for (inputs.cumulative_transpiration_source_m3_by_species) |source|
        if (source > 0) return error.InvalidVisualizationTranspirationSign;
    inline for (.{
        inputs.leaf_carbon_g_by_species,
        inputs.stalk_carbon_g_by_species,
        inputs.root_carbon_g_by_species,
        inputs.organic_carbon_g_by_layer_including_surface,
    }) |pool| for (pool) |value|
        if (value < 0) return error.InvalidVisualizationCarbonPool;
    var i: usize = 0;
    var transpiration_sum_mm: f64 = 0;
    for (inputs.cumulative_transpiration_source_m3_by_species) |source| {
        const value = -1000.0 * source / inputs.cell_area_m2;
        values[i] = value;
        transpiration_sum_mm += value;
        i += 1;
    }
    const evapotranspiration_mm = 1000.0 * inputs.cumulative_evapotranspiration_m3 / inputs.cell_area_m2;
    for ([_]f64{ evapotranspiration_mm, evapotranspiration_mm - transpiration_sum_mm, 1000.0 * inputs.cumulative_runoff_m3 / inputs.cell_area_m2, 1000.0 * inputs.cumulative_outflow_m3 / inputs.cell_area_m2, -(inputs.water_table_bottom_depth_m - inputs.active_surface_depth_m), inputs.snow_depth_m, inputs.total_leaf_area_m2 / inputs.cell_area_m2 }) |value| {
        values[i] = value;
        i += 1;
    }
    inline for (.{ inputs.leaf_carbon_g_by_species, inputs.stalk_carbon_g_by_species, inputs.root_carbon_g_by_species }) |pool| {
        for (pool) |value| {
            values[i] = 0.001 * value / inputs.cell_area_m2;
            i += 1;
        }
    }
    for (inputs.organic_carbon_g_by_layer_including_surface) |value| {
        values[i] = 0.001 * value / inputs.cell_area_m2;
        i += 1;
    }
    std.debug.assert(i == values.len);
    try finiteSlice(values);
}

fn positiveArea(value: f64) !void {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidVisualizationArea;
}
fn finite(value: f64) !void {
    if (!std.math.isFinite(value)) return error.NonFiniteVisualizationOutput;
}
fn finiteSlice(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteVisualizationOutput;
}

test "VISUAL hourly expands beyond three species and eleven layers" {
    const species = [_]f64{ 3600, 7200, 10800, 14400, 18000, 21600, 25200 };
    const respiration = [_]f64{ 360, 720, 1080, 1440, 1800, 2160, 2520 };
    const liquid = [_]f64{1} ** 13;
    const air = [_]f64{2} ** 13;
    const macro = [_]f64{0.5} ** 13;
    const volume = [_]f64{10} ** 13;
    const temperature = [_]f64{280} ** 13;
    var output = try hourly(std.testing.allocator, .{ .cell_area_m2 = 2, .species_cumulative_gross_carbon_g = &species, .species_cumulative_respired_carbon_g = &respiration, .ecosystem_gross_primary_productivity_g = 0, .ecosystem_net_primary_productivity_g = 0, .ecosystem_autotrophic_respiration_g = 0, .ecosystem_heterotrophic_respiration_g = 0, .net_biome_productivity_g = 0, .carbon_dioxide_flux_g = 0, .methane_flux_g = 0, .net_radiation_megajoules_h = 2, .latent_heat_flux_megajoules_h = 1, .sensible_heat_flux_megajoules_h = 0.5, .liquid_water_m3_by_layer = &liquid, .air_volume_m3_by_layer = &air, .macropore_water_m3_by_layer = &macro, .total_volume_m3_by_layer = &volume, .soil_temperature_k_by_layer = &temperature });
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 50), output.values.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0005), output.values[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), output.values[24], 1e-15);
}

test "VISUAL hourly allocation-free kernel exactly matches owned record" {
    const species = [_]f64{ 3600, 7200 };
    const respiration = [_]f64{ 360, 720 };
    const liquid = [_]f64{ 1, 2, 3 };
    const air = [_]f64{ 2, 2, 2 };
    const macro = [_]f64{ 0.5, 0.5, 0.5 };
    const volume = [_]f64{ 10, 10, 10 };
    const temperature = [_]f64{ 280, 281, 282 };
    const inputs: HourlyInputs = .{
        .cell_area_m2 = 2,
        .species_cumulative_gross_carbon_g = &species,
        .species_cumulative_respired_carbon_g = &respiration,
        .ecosystem_gross_primary_productivity_g = 3,
        .ecosystem_net_primary_productivity_g = 2,
        .ecosystem_autotrophic_respiration_g = 1,
        .ecosystem_heterotrophic_respiration_g = 0.5,
        .net_biome_productivity_g = 1.5,
        .carbon_dioxide_flux_g = 0.25,
        .methane_flux_g = 0.125,
        .net_radiation_megajoules_h = 2,
        .latent_heat_flux_megajoules_h = 1,
        .sensible_heat_flux_megajoules_h = 0.5,
        .liquid_water_m3_by_layer = &liquid,
        .air_volume_m3_by_layer = &air,
        .macropore_water_m3_by_layer = &macro,
        .total_volume_m3_by_layer = &volume,
        .soil_temperature_k_by_layer = &temperature,
    };
    var owned = try hourly(std.testing.allocator, inputs);
    defer owned.deinit();
    const reusable = try std.testing.allocator.alloc(f64, owned.values.len);
    defer std.testing.allocator.free(reusable);
    try hourlyInto(reusable, inputs);
    try std.testing.expectEqualSlices(f64, owned.values, reusable);
    try std.testing.expectError(
        error.VisualizationOutputDimensionMismatch,
        hourlyInto(reusable[0 .. reusable.len - 1], inputs),
    );
}

test "VISUAL kernels reject complete invalid records before mutating reusable rows" {
    var hourly_row = [_]f64{42} ** 14;
    const invalid_temperature = [_]f64{std.math.nan(f64)};
    try std.testing.expectError(
        error.NonFiniteVisualizationOutput,
        hourlyInto(&hourly_row, .{
            .cell_area_m2 = 1,
            .species_cumulative_gross_carbon_g = &.{0},
            .species_cumulative_respired_carbon_g = &.{0},
            .ecosystem_gross_primary_productivity_g = 0,
            .ecosystem_net_primary_productivity_g = 0,
            .ecosystem_autotrophic_respiration_g = 0,
            .ecosystem_heterotrophic_respiration_g = 0,
            .net_biome_productivity_g = 0,
            .carbon_dioxide_flux_g = 0,
            .methane_flux_g = 0,
            .net_radiation_megajoules_h = 0,
            .latent_heat_flux_megajoules_h = 0,
            .sensible_heat_flux_megajoules_h = 0,
            .liquid_water_m3_by_layer = &.{0},
            .air_volume_m3_by_layer = &.{1},
            .macropore_water_m3_by_layer = &.{0},
            .total_volume_m3_by_layer = &.{1},
            .soil_temperature_k_by_layer = &invalid_temperature,
        }),
    );
    try std.testing.expectEqualSlices(
        f64,
        &([_]f64{42} ** 14),
        &hourly_row,
    );

    var daily_row = [_]f64{24} ** 12;
    try std.testing.expectError(
        error.InvalidVisualizationCarbonPool,
        dailyInto(&daily_row, .{
            .cell_area_m2 = 1,
            .cumulative_transpiration_source_m3_by_species = &.{0},
            .cumulative_evapotranspiration_m3 = 0,
            .cumulative_runoff_m3 = 0,
            .cumulative_outflow_m3 = 0,
            .water_table_bottom_depth_m = 1,
            .active_surface_depth_m = 0,
            .snow_depth_m = 0,
            .total_leaf_area_m2 = 0,
            .leaf_carbon_g_by_species = &.{0},
            .stalk_carbon_g_by_species = &.{0},
            .root_carbon_g_by_species = &.{0},
            .organic_carbon_g_by_layer_including_surface = &.{-1},
        }),
    );
    try std.testing.expectEqualSlices(
        f64,
        &([_]f64{24} ** 12),
        &daily_row,
    );
}

test "VISUAL daily residual evaporation sums arbitrary species" {
    const transpiration = [_]f64{ -0.001, -0.002, -0.003, -0.004, -0.005, -0.006, -0.007 };
    const zeros = [_]f64{0} ** 7;
    const soc = [_]f64{ 1000, 2000, 3000 };
    var output = try daily(std.testing.allocator, .{ .cell_area_m2 = 2, .cumulative_transpiration_source_m3_by_species = &transpiration, .cumulative_evapotranspiration_m3 = 0.03, .cumulative_runoff_m3 = 0.002, .cumulative_outflow_m3 = 0.004, .water_table_bottom_depth_m = 2, .active_surface_depth_m = 0.2, .snow_depth_m = 0.1, .total_leaf_area_m2 = 4, .leaf_carbon_g_by_species = &zeros, .stalk_carbon_g_by_species = &zeros, .root_carbon_g_by_species = &zeros, .organic_carbon_g_by_layer_including_surface = &soc });
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 38), output.values.len);
    try std.testing.expectApproxEqAbs(@as(f64, 15), output.values[7], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), output.values[8], 1e-15);
    var reusable: [38]f64 = undefined;
    try dailyInto(&reusable, .{ .cell_area_m2 = 2, .cumulative_transpiration_source_m3_by_species = &transpiration, .cumulative_evapotranspiration_m3 = 0.03, .cumulative_runoff_m3 = 0.002, .cumulative_outflow_m3 = 0.004, .water_table_bottom_depth_m = 2, .active_surface_depth_m = 0.2, .snow_depth_m = 0.1, .total_leaf_area_m2 = 4, .leaf_carbon_g_by_species = &zeros, .stalk_carbon_g_by_species = &zeros, .root_carbon_g_by_species = &zeros, .organic_carbon_g_by_layer_including_surface = &soc });
    try std.testing.expectEqualSlices(f64, output.values, &reusable);
}

test "VISUAL runtime catalogs align with arbitrary species and layer records" {
    var hourly_catalog = try hourlyCatalog(std.testing.allocator, 7, 13);
    defer hourly_catalog.deinit();
    var daily_catalog = try dailyCatalog(std.testing.allocator, 7, 14);
    defer daily_catalog.deinit();
    try std.testing.expectEqual(@as(usize, 50), hourly_catalog.variables.len);
    try std.testing.expectEqual(@as(usize, 49), daily_catalog.variables.len);
    try std.testing.expectEqualStrings(
        "species_7_respiration",
        hourly_catalog.variables[13].name,
    );
    try std.testing.expectEqualStrings(
        "soil_layer_13_temperature",
        hourly_catalog.variables[49].name,
    );
    try std.testing.expectEqualStrings(
        "soil_layer_0_organic_carbon",
        daily_catalog.variables[35].name,
    );
    try std.testing.expectEqualStrings(
        "soil_layer_13_organic_carbon",
        daily_catalog.variables[48].name,
    );
}

test "VISUAL streams are bounded tab delimited and year gated" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var streams = try Streams.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        true,
        1,
        2,
        3,
        2001,
        2002,
        64,
    );
    defer streams.deinit();
    const hourly_values = [_]f64{1} ** 20;
    const daily_values = [_]f64{2} ** 19;
    try streams.configureScene(false, 2001, 2002);
    try std.testing.expect(!try streams.writeHourly(
        0,
        -75.7,
        45.3,
        .{
            .year = 2001,
            .day_of_year = 1,
            .month = 1,
            .day = 1,
            .hour = 0,
        },
        .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 },
        &hourly_values,
    ));
    try streams.configureScene(true, 2001, 2002);
    try std.testing.expect(!try streams.writeHourly(
        0,
        -75.7,
        45.3,
        .{
            .year = 2000,
            .day_of_year = 1,
            .month = 1,
            .day = 1,
            .hour = 0,
        },
        .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 },
        &hourly_values,
    ));
    try std.testing.expect(try streams.writeHourly(
        0,
        -75.7,
        45.3,
        .{
            .year = 2001,
            .day_of_year = 1,
            .month = 1,
            .day = 1,
            .hour = 1,
        },
        .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 },
        &hourly_values,
    ));
    try std.testing.expect(try streams.writeDaily(
        0,
        -75.7,
        45.3,
        .{
            .year = 2002,
            .day_of_year = 365,
            .month = 12,
            .day = 31,
            .hour = 23,
        },
        .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = 1 },
        &daily_values,
    ));
    try streams.finish();
    const hourly_text = try temporary.dir.readFileAlloc(
        std.testing.io,
        "lat_45.30_lon_-75.70_soil_or_eco_2001_exec01_scenario01_rep01_scene01_cell01_pop00_visual_hourly.txt",
        std.testing.allocator,
        .limited(16 * 1024),
    );
    defer std.testing.allocator.free(hourly_text);
    const daily_text = try temporary.dir.readFileAlloc(
        std.testing.io,
        "lat_45.30_lon_-75.70_soil_or_eco_2002_exec01_scenario01_rep01_scene01_cell01_pop00_visual_daily.txt",
        std.testing.allocator,
        .limited(16 * 1024),
    );
    defer std.testing.allocator.free(daily_text);
    try std.testing.expect(std.mem.indexOfScalar(u8, hourly_text, '\t') != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        hourly_text,
        "species_2_respiration[kg_C_m-2_s-1]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        daily_text,
        "soil_layer_3_organic_carbon[kg_C_m-2]",
    ) != null);
}

test "VISUAL output identity separates co-located cells and repeated-year scenes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var streams = try Streams.init(std.testing.allocator, std.testing.io, temporary.dir, true, 2, 2, 3, 2001, 2001, 64);
    defer streams.deinit();
    const timestamp: output_record.Timestamp = .{ .year = 2001, .day_of_year = 1, .month = 1, .day = 1, .hour = 0 };
    for (1..3) |scene| {
        const pass: output_record.PassOrdinals = .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = @intCast(scene) };
        for (0..2) |cell| {
            const values = [_]f64{@floatFromInt(scene * 10 + cell)} ** 20;
            try std.testing.expect(try streams.writeHourly(cell, -75.7, 45.3, timestamp, pass, &values));
        }
    }
    try streams.finish();
    for (1..3) |scene| {
        const pass: output_record.PassOrdinals = .{ .execution_number = 1, .scenario_number = 1, .repeat_number = 1, .scene_number = @intCast(scene) };
        for (0..2) |cell| {
            const name = try output_record.buildOutputFileName(std.testing.allocator, 45.3, -75.7, .soil_or_eco, 2001, pass, cell + 1, "visual_hourly");
            defer std.testing.allocator.free(name);
            const bytes = try temporary.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(16 * 1024));
            defer std.testing.allocator.free(bytes);
            // Exactly one header and one row in each of four distinct files.
            try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\n"));
            const value = try std.fmt.allocPrint(std.testing.allocator, "\t{e}", .{@as(f64, @floatFromInt(scene * 10 + cell))});
            defer std.testing.allocator.free(value);
            try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, bytes, value));
        }
    }
}

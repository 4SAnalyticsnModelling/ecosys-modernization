//! Single end-of-hour REDIST soil-geometry owner.

const std = @import("std");
const ecosys = @import("ecosys_ng");
const tile_kernels = @import("tile_kernels.zig");
const diagnostics = @import("diagnostics.zig");

const HourlyGeometryCarrier = struct {
    matrix_zone_fraction: f64,
    organic_carbon_g_per_megagram: f64,
};

/// Builds only intensive geometry views. A zero-density active layer is a
/// valid open-water slot: its extensive organic owner is left untouched and
/// the unavailable per-mineral-mass view is published as zero.
fn hourlyGeometryCarrier(
    layer_volume_m3: f64,
    matrix_volume_m3: f64,
    bulk_density_megagrams_per_m3: f64,
    organic_carbon_g_c: f64,
) !HourlyGeometryCarrier {
    inline for (.{ layer_volume_m3, matrix_volume_m3, bulk_density_megagrams_per_m3, organic_carbon_g_c }) |value|
        if (!std.math.isFinite(value)) return error.InvalidHourlySoilGeometryCarrier;
    if (layer_volume_m3 <= 0 or matrix_volume_m3 <= 0 or
        matrix_volume_m3 > layer_volume_m3 or
        bulk_density_megagrams_per_m3 < 0 or organic_carbon_g_c < 0)
        return error.InvalidHourlySoilGeometryCarrier;
    const soil_mass_megagrams = matrix_volume_m3 * bulk_density_megagrams_per_m3;
    if (!std.math.isFinite(soil_mass_megagrams))
        return error.InvalidHourlySoilGeometryCarrier;
    return .{
        .matrix_zone_fraction = matrix_volume_m3 / layer_volume_m3,
        .organic_carbon_g_per_megagram = if (soil_mass_megagrams > 0)
            organic_carbon_g_c / soil_mass_megagrams
        else
            0,
    };
}

fn relayeringTolerance(context: anytype) !ecosys.soil_profile_relayering_activity.Tolerance {
    if (context.canopy_cell_area_m2.len != context.grid.cell_count)
        return error.HourlySoilGeometryDimensionMismatch;
    var minimum_area_m2 = std.math.inf(f64);
    for (context.canopy_cell_area_m2) |area_m2| {
        if (!std.math.isFinite(area_m2) or area_m2 <= 0)
            return error.InvalidHourlySoilGeometryCellArea;
        minimum_area_m2 = @min(minimum_area_m2, area_m2);
    }
    const absolute = context.config.mass_balance_absolute_tolerance;
    const scaled = struct {
        fn amount(per_area: f64, area_m2: f64) !f64 {
            const value = per_area * area_m2;
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidHourlySoilGeometryConservationTolerance;
            return value;
        }
    }.amount;
    const carbon = try scaled(absolute.carbon_g_m2, minimum_area_m2);
    const nitrogen = try scaled(absolute.nitrogen_g_m2, minimum_area_m2);
    const phosphorus = try scaled(absolute.phosphorus_g_m2, minimum_area_m2);
    const ions = try scaled(absolute.ions_mol_m2, minimum_area_m2);
    const exchange = try scaled(absolute.exchange_capacity_mol_m2, minimum_area_m2);
    return .{
        // One sidecar serves every cell. The smallest cell supplies the
        // strictest extensive floor, so a large cell cannot hide a local
        // producer mismatch in a smaller one.
        .absolute = .{
            .water_m3 = try scaled(absolute.water_m, minimum_area_m2),
            .heat_megajoules = try scaled(absolute.heat_megajoules_m2, minimum_area_m2),
            .oxygen_g = try scaled(absolute.oxygen_g_m2, minimum_area_m2),
            .hydrogen_g = try scaled(absolute.hydrogen_g_m2, minimum_area_m2),
            .residue_carbon_g = carbon,
            .organic_carbon_g = carbon,
            .carbon_dioxide_carbon_g = carbon,
            .plant_carbon_g = carbon,
            .plant_nitrogen_g = nitrogen,
            .plant_phosphorus_g = phosphorus,
            .residue_nitrogen_g = nitrogen,
            .organic_nitrogen_g = nitrogen,
            .dinitrogen_nitrogen_g = nitrogen,
            .ammonium_nitrogen_g = nitrogen,
            .nitrate_nitrogen_g = nitrogen,
            .residue_phosphorus_g = phosphorus,
            .organic_phosphorus_g = phosphorus,
            .phosphate_phosphorus_g = phosphorus,
            .aluminum_mol = ions,
            .iron_mol = ions,
            .calcium_mol = ions,
            .magnesium_mol = ions,
            .sodium_mol = ions,
            .potassium_mol = ions,
            .sulfur_mol = ions,
            .chloride_mol = ions,
            .silicon_mol = ions,
            .ion_inventory_mol = ions,
            .sand_megagrams = try scaled(absolute.sand_megagrams_m2, minimum_area_m2),
            .silt_megagrams = try scaled(absolute.silt_megagrams_m2, minimum_area_m2),
            .clay_megagrams = try scaled(absolute.clay_megagrams_m2, minimum_area_m2),
            .rock_additive = try scaled(absolute.rock_additive_m2, minimum_area_m2),
            .cation_exchange_capacity_mol = exchange,
            .anion_exchange_capacity_mol = exchange,
        },
        .relative = context.config.mass_balance_relative_tolerance,
    };
}

pub fn finalize(context: anytype) !void {
    var rollback = try GeometryRollbackSnapshot.capture(context.allocator, context);
    defer rollback.deinit();
    errdefer rollback.restore();
    const workspace = context.soil_profile_relayering_workspace;
    const properties = context.soil_solver_properties;
    const geometry = context.soil_geometry;
    const layer_count = context.grid.layer_count;
    const cell_count = context.grid.cell_count;
    const cap = context.grid.soil_layer_capacity;
    if (properties.initial_layer_thickness_m.len != layer_count or
        properties.reference_bulk_density_megagrams_per_m3.len != layer_count or
        workspace.ice_volume_delta_m3.len != layer_count or
        workspace.matrix_zone_fraction.len != layer_count or
        workspace.organic_carbon_g_per_megagram.len != layer_count or
        workspace.reset_organic_accumulation_by_layer.len != layer_count or
        workspace.live_layer_thickness_m.len != layer_count or
        workspace.surface_soil_volume_m3_by_cell.len != cell_count or
        workspace.receiving_soil_bulk_density_megagrams_per_m3_by_cell.len != cell_count or
        workspace.disturbance_mode_by_cell.len != cell_count)
        return error.HourlySoilGeometryDimensionMismatch;

    for (0..layer_count) |index| {
        const layer_volume_m3 = properties.layer_volume_m3[index];
        const matrix_volume_m3 = properties.matrix_bulk_volume_m3[index];
        const organic_carbon_g_c = try context.soil_organic.totalCarbon_g_c(index);
        const carrier = try hourlyGeometryCarrier(
            layer_volume_m3,
            matrix_volume_m3,
            properties.bulk_density_megagrams_per_m3[index],
            organic_carbon_g_c,
        );
        workspace.matrix_zone_fraction[index] = carrier.matrix_zone_fraction;
        workspace.organic_carbon_g_per_megagram[index] = carrier.organic_carbon_g_per_megagram;
    }
    var negligible_ice_volume_change_m3 = std.math.inf(f64);
    var negligible_sediment_megagrams = std.math.inf(f64);
    var negligible_carbon_change_g_c = std.math.inf(f64);
    const mineral_geometry: ecosys.surface_pond_particulate_settling.MineralColumnGeometry = .{
        .cell_count = cell_count,
        .soil_layer_capacity = cap,
        .surface_soil_layer_by_cell = geometry.first_active_layer,
        .active_soil_layer_count_by_cell = geometry.active_layer_count,
        .soil_bulk_density_megagrams_per_m3 = properties.bulk_density_megagrams_per_m3,
        .matrix_bulk_volume_m3 = properties.matrix_bulk_volume_m3,
    };
    for (0..cell_count) |cell| {
        const first = geometry.first_active_layer[cell];
        const active = geometry.active_layer_count[cell];
        if (active == 0 or first + active > cap)
            return error.InvalidHourlySoilGeometryActiveRange;
        const mineral_layer = try ecosys.surface_pond_particulate_settling.firstMineralLayer(
            mineral_geometry,
            cell,
        );
        const top = cell * cap + mineral_layer;
        workspace.surface_soil_volume_m3_by_cell[cell] =
            properties.layer_volume_m3[top];
        workspace.receiving_soil_bulk_density_megagrams_per_m3_by_cell[cell] =
            properties.reference_bulk_density_megagrams_per_m3[top];
        const mode = context.site_by_cell[cell].erosion_mode;
        workspace.disturbance_mode_by_cell[cell] = mode;
        if (mode == 1 or mode == 3) {
            const sediment_scale_megagrams =
                @abs(context.net_sediment_megagrams_per_h[cell]) +
                context.surface_erosion.pond_settled_sediment_megagrams[cell];
            negligible_sediment_megagrams = @min(
                negligible_sediment_megagrams,
                context.config.physical_tolerance.soilMass(sediment_scale_megagrams),
            );
        }
        for (0..active) |offset| {
            const index = cell * cap + first + offset;
            if (mode >= 0)
                negligible_ice_volume_change_m3 = @min(
                    negligible_ice_volume_change_m3,
                    context.config.physical_tolerance.waterVolume(
                        @abs(workspace.ice_volume_delta_m3[index]),
                    ),
                );
            if (mode == 2 or mode == 3)
                negligible_carbon_change_g_c = @min(
                    negligible_carbon_change_g_c,
                    context.config.physical_tolerance.carbon(
                        @abs(context.soil_organic_carbon_change_g_c_per_h[index]),
                    ),
                );
        }
    }
    if (!std.math.isFinite(negligible_ice_volume_change_m3))
        negligible_ice_volume_change_m3 = context.config.physical_tolerance.waterVolume(0);
    if (!std.math.isFinite(negligible_sediment_megagrams))
        negligible_sediment_megagrams = context.config.physical_tolerance.soilMass(0);
    if (!std.math.isFinite(negligible_carbon_change_g_c))
        negligible_carbon_change_g_c = context.config.physical_tolerance.carbon(0);
    try ecosys.soil_geometry_change_assembly.buildOrganicAccumulationReset(
        workspace.reset_organic_accumulation_by_layer,
        geometry,
        workspace.organic_carbon_g_per_megagram,
        context.runscript.soil_geometry_parameters.organic_horizon_threshold_g_c_per_megagram,
    );

    // The remap reads cached thermal capacities. Refresh them from the final
    // accepted water/phase carriers immediately before the transaction.
    try tile_kernels.runKernelAcrossSerialTiles(
        context,
        context.soil_thermal_context,
        ecosys.soil_thermal.updateTile,
    );
    const nutrient_zone_fractions_by_layer = try context.allocator.alloc(
        ecosys.soil_profile_relayering.NutrientZoneFractions,
        layer_count,
    );
    defer context.allocator.free(nutrient_zone_fractions_by_layer);
    for (nutrient_zone_fractions_by_layer, 0..) |*fractions, layer| {
        const live = try context.fertilizer_band.scienceZoneFractionsForFlatIndex(layer);
        fractions.* = .{
            .ammonium_non_band = live.ammonium_non_band,
            .ammonium_band = live.ammonium_band,
            .nitrate_non_band = live.nitrate_non_band,
            .nitrate_band = live.nitrate_band,
            .phosphate_non_band = live.phosphate_non_band,
            .phosphate_band = live.phosphate_band,
        };
    }
    if (nutrient_zone_fractions_by_layer.len == 0) return error.HourlySoilGeometryDimensionMismatch;
    const ice_heat_capacity_per_water_equivalent_m3_k =
        try ecosys.ice_units.heatCapacityPerWaterEquivalentM3K(
            context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
            context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
        );
    var science: ecosys.soil_profile_relayering.Context = .{
        .grid = context.grid,
        .soil_thermal = context.soil_thermal,
        .gas_transport = context.gas_transport,
        .soil_organic = context.soil_organic,
        .soil_chemistry = context.soil_chemistry,
        .reactive_nitrogen = context.soil_reactive_nitrogen,
        .soil_fertilizer_inventory = context.soil_fertilizer_inventory,
        .mineral_fertilizer_inventory = context.mineral_fertilizer_inventory,
        .transport_owners = .{
            .micropore_solute = context.micropore_solute_state,
            .macropore_solute = context.macropore_solute_state,
            .mineral_nitrogen = context.mineral_nitrogen_transport,
            .organic = context.soil_organic_transport,
        },
        .soil_properties = properties,
        .plant_roots = if (context.plant_roots.*) |*roots| roots else null,
        .plant_population_count = if (context.plant_water_workspace.*) |*water|
            water.plant_population_count
        else
            &.{},
        .root_presence_floor_per_plant = context.soil_numerical_scales.calculation_floor,
        .fertilizer_band = context.fertilizer_band,
        .soil_geometry = geometry,
        .live_layer_thickness_m = workspace.live_layer_thickness_m,
        .transport_hydrology = context.transport_hydrology,
        .soil_face_geometry = context.soil_face_geometry,
        .soil_transport_faces = context.soil_transport_faces,
        .transport_geometry_floor_m = context.soil_numerical_scales.geometry_floor_m,
        .water_heat_parameters = .{
            .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
            .ice_heat_capacity_megajoules_per_m3_k = ice_heat_capacity_per_water_equivalent_m3_k,
            .minimum_heat_capacity_megajoules_per_k = 0,
        },
        .salinity_enabled_by_cell = context.salinity_enabled_by_cell,
        .nutrient_zone_fractions = nutrient_zone_fractions_by_layer[0],
        .nutrient_zone_fractions_by_layer = nutrient_zone_fractions_by_layer,
        .plant_populations = context.config.plant_populations,
        .minimum_layer_thickness_m = context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
        .horizontal_cell_width_m = context.horizontal_cell_width_m,
        .vertical_cell_width_m = context.vertical_cell_width_m,
        .rebase_thermal_volume_to_geometry = true,
    };
    var activity_sidecar = try ecosys.soil_profile_relayering_activity.Sidecar.init(
        context.allocator,
        cell_count,
        cap,
        try relayeringTolerance(context),
    );
    defer activity_sidecar.deinit();
    var snapshot: ecosys.relayering_layer_snapshot.Context = .{
        .inputs = diagnostics.landscapeMassBalanceInputs(context),
    };
    science.local_activity = try snapshot.binding(&activity_sidecar, science);
    try ecosys.soil_profile_relayering.applyEndOfHourGeometry(science, workspace, .{
        .disturbance_mode_by_cell = workspace.disturbance_mode_by_cell,
        .total_ice_volume_change_m3 = workspace.ice_volume_delta_m3,
        .soil_matrix_fraction = workspace.matrix_zone_fraction,
        .net_sediment_megagrams_by_cell = context.net_sediment_megagrams_per_h,
        .snow_deposited_sediment_megagrams_by_cell = context.surface_erosion.pond_settled_sediment_megagrams,
        .horizontal_area_m2_by_cell = context.canopy_cell_area_m2,
        .surface_soil_mass_megagrams_by_cell = context.surface_erosion.surface_soil_mass_megagrams,
        .surface_soil_volume_m3_by_cell = workspace.surface_soil_volume_m3_by_cell,
        .receiving_soil_bulk_density_megagrams_per_m3_by_cell = workspace.receiving_soil_bulk_density_megagrams_per_m3_by_cell,
        .organic_carbon_change_after_erosion_cancellation_g_c = context.soil_organic_carbon_change_g_c_per_h,
        .macropore_fraction = properties.macropore_fraction,
        .reference_bulk_density_megagrams_per_m3 = properties.reference_bulk_density_megagrams_per_m3,
        .initial_layer_thickness_m = properties.initial_layer_thickness_m,
        .current_layer_thickness_m = geometry.layer_thickness_m,
        .reset_organic_accumulation_by_layer = workspace.reset_organic_accumulation_by_layer,
        .ice_to_water_specific_volume_difference = context.runscript.soil_geometry_parameters.ice_to_water_specific_volume_difference,
        .organic_carbon_specific_volume_m3_per_g = context.runscript.soil_geometry_parameters.organic_carbon_specific_volume_m3_per_g,
        // A single scalar threshold is required by the translated assemblers.
        // Use the strictest locally scaled tolerance among enabled cells/layers,
        // so a large domain driver cannot suppress a smaller local disturbance.
        .negligible_ice_volume_change_m3 = negligible_ice_volume_change_m3,
        .negligible_sediment_megagrams = negligible_sediment_megagrams,
        .negligible_carbon_change_g_c = negligible_carbon_change_g_c,
    });
    try ecosys.layer_local_conservation.accumulateSoilRelayeringActivity(
        context.hourly_layer_boundary_ledger,
        &activity_sidecar,
        context.soil_geometry.first_active_layer,
        context.grid.active_soil_layer_count,
    );
    // ISSUE-065 (sixteenth pass): the fifteenth addendum refuted the erosion
    // LOCAL soil<->surface exchange (`erosion_chemistry_bridge.zig`) as
    // nitrogen's remaining ~8.14e-3 g N mechanism (it books exactly zero
    // ammonium transfer at hour 2894) and named REDIST layer<->layer
    // relayering (this exact call) as the sharpest untraced candidate, since
    // `layer_local_conservation.inventory.Storage` (the `Record.transfer`
    // shape) carries an `ammonium_nitrogen_g` field. `stageBoundary`'s own
    // per-field conservation gate (`relayering_activity.zig:253-274`) enforces
    // donor-loss == recipient-gain to within tolerance for every field
    // including this one, and `RelayeringActivityConservationFailure` has
    // never fired in this issue's entire history -- so if this boundary
    // records a nonzero transfer, it is by construction internally
    // conserving (moves mass from layer 0 to layer 1, does not destroy it).
    // Logging the accepted boundary record for cell 0's layer0/layer1
    // boundary (`upper_layer=0`) directly answers whether this mechanism
    // records any transfer at all at hour 2894, and rules it in or out as a
    // net-cell-level mass sink independent of that internal guarantee.
    if (context.executed_weather_hours.* >= 2888 and context.executed_weather_hours.* < 2896 and cell_count > 0) {
        const boundary = try activity_sidecar.record(0, 0);
        std.log.info(
            "DRY_CARRIER_TRACE site=redist_relayering_boundary hour={d} cell=0 upper_layer=0 direction={s} ammonium_nitrogen_g={e} nitrate_nitrogen_g={e} phosphate_phosphorus_g={e} carbon_dioxide_carbon_g={e}",
            .{
                context.executed_weather_hours.* + 1,
                @tagName(boundary.direction),
                boundary.transfer.ammonium_nitrogen_g,
                boundary.transfer.nitrate_nitrogen_g,
                boundary.transfer.phosphate_phosphorus_g,
                boundary.transfer.carbon_dioxide_carbon_g,
            },
        );
    }
}

const SavedMemoryRegion = struct {
    destination: [*]u8,
    bytes: []u8,
};

/// Transaction snapshot limited to state the REDIST remap can mutate. The
/// remap never replaces backing allocations, so restoring these buffers is
/// safe and makes a failed end-of-hour attempt leave no scientific side effect.
const GeometryRollbackSnapshot = struct {
    allocator: std.mem.Allocator,
    regions: std.ArrayList(SavedMemoryRegion) = .empty,

    fn capture(allocator: std.mem.Allocator, context: anytype) !GeometryRollbackSnapshot {
        @setEvalBranchQuota(100_000);
        var self: GeometryRollbackSnapshot = .{ .allocator = allocator };
        errdefer self.deinit();
        const Context = @TypeOf(context);
        inline for (@typeInfo(Context).@"struct".fields) |field|
            if (comptime isGeometryTransactionalField(field.name))
                try self.captureTopValue(@field(context, field.name));
        return self;
    }

    fn restore(self: *const GeometryRollbackSnapshot) void {
        for (self.regions.items) |region|
            @memcpy(region.destination[0..region.bytes.len], region.bytes);
    }

    fn deinit(self: *GeometryRollbackSnapshot) void {
        for (self.regions.items) |region| self.allocator.free(region.bytes);
        self.regions.deinit(self.allocator);
        self.* = undefined;
    }

    fn saveBytes(self: *GeometryRollbackSnapshot, destination: []u8) !void {
        if (destination.len == 0) return;
        const bytes = try self.allocator.dupe(u8, destination);
        errdefer self.allocator.free(bytes);
        try self.regions.append(self.allocator, .{
            .destination = destination.ptr,
            .bytes = bytes,
        });
    }

    fn captureTopValue(self: *GeometryRollbackSnapshot, value: anytype) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .pointer => |pointer| {
                if (pointer.is_const) return;
                switch (pointer.size) {
                    .slice => try self.captureSlice(T, value),
                    .one => switch (@typeInfo(pointer.child)) {
                        .@"opaque", .@"fn" => {},
                        else => {
                            try self.saveBytes(std.mem.asBytes(value));
                            try self.captureOwnedBuffers(pointer.child, value);
                        },
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn captureSlice(self: *GeometryRollbackSnapshot, comptime Slice: type, values: Slice) !void {
        const pointer = @typeInfo(Slice).pointer;
        if (pointer.is_const) return;
        try self.saveBytes(std.mem.sliceAsBytes(values));
        if (comptime typeMayOwnBuffers(pointer.child))
            for (values) |*value| try self.captureOwnedBuffers(pointer.child, value);
    }

    fn captureOwnedBuffers(self: *GeometryRollbackSnapshot, comptime T: type, value: *T) !void {
        switch (@typeInfo(T)) {
            .pointer => |pointer| if (pointer.size == .slice and !pointer.is_const)
                try self.captureSlice(T, value.*),
            .@"struct" => |structure| inline for (structure.fields) |field|
                if (comptime typeMayOwnBuffers(field.type))
                    try self.captureOwnedBuffers(field.type, &@field(value.*, field.name)),
            .optional => |optional| if (value.*) |*payload|
                if (comptime typeMayOwnBuffers(optional.child))
                    try self.captureOwnedBuffers(optional.child, payload),
            .array => |array| if (comptime typeMayOwnBuffers(array.child))
                for (value) |*element| try self.captureOwnedBuffers(array.child, element),
            else => {},
        }
    }
};

fn typeMayOwnBuffers(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and !pointer.is_const,
        .@"struct" => |structure| blk: {
            inline for (structure.fields) |field|
                if (typeMayOwnBuffers(field.type)) break :blk true;
            break :blk false;
        },
        .optional => |optional| typeMayOwnBuffers(optional.child),
        .array => |array| typeMayOwnBuffers(array.child),
        else => false,
    };
}

fn isGeometryTransactionalField(comptime name: []const u8) bool {
    const names = [_][]const u8{
        "grid",
        "soil_thermal",
        "gas_transport",
        "soil_organic",
        "soil_chemistry",
        "soil_reactive_nitrogen",
        "soil_fertilizer_inventory",
        "mineral_fertilizer_inventory",
        "micropore_solute_state",
        "macropore_solute_state",
        "mineral_nitrogen_transport",
        "soil_organic_transport",
        "soil_solver_properties",
        "plant_roots",
        "fertilizer_band",
        "soil_geometry",
        "transport_hydrology",
        "soil_transport_faces",
        "soil_face_geometry",
        "soil_profile_relayering_workspace",
    };
    inline for (names) |candidate|
        if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

test "hourly geometry preserves zero-density open-water slots and selects mineral receiver" {
    const water = try hourlyGeometryCarrier(2, 1.5, 0, 7);
    try std.testing.expectEqual(@as(f64, 0.75), water.matrix_zone_fraction);
    try std.testing.expectEqual(@as(f64, 0), water.organic_carbon_g_per_megagram);
    try std.testing.expectError(
        error.InvalidHourlySoilGeometryCarrier,
        hourlyGeometryCarrier(2, 1.5, -1e-12, 0),
    );

    const mineral = try ecosys.surface_pond_particulate_settling.firstMineralLayer(.{
        .cell_count = 1,
        .soil_layer_capacity = 3,
        .surface_soil_layer_by_cell = &.{0},
        .active_soil_layer_count_by_cell = &.{3},
        .soil_bulk_density_megagrams_per_m3 = &.{ 0, 0, 1.3 },
        .matrix_bulk_volume_m3 = &.{ 0.4, 0.6, 0.8 },
    }, 0);
    try std.testing.expectEqual(@as(usize, 2), mineral);
}

test "production owner follows DORGC publication and excludes pond from geometry transaction" {
    const allocator = std.testing.allocator;
    const owner_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_geometry_disturbance.zig",
        allocator,
        .limited(512 * 1024),
    );
    defer allocator.free(owner_source);
    const tests_begin = std.mem.indexOf(u8, owner_source, "test \"production owner") orelse return error.MissingGeometryOwnerTestBoundary;
    const production_source = owner_source[0..tests_begin];
    try std.testing.expect(std.mem.indexOf(u8, production_source, "soil_profile_relayering.applyEndOfHourGeometry") != null);
    try std.testing.expect(std.mem.indexOf(u8, production_source, "ice_units.heatCapacityPerWaterEquivalentM3K") != null);
    try std.testing.expect(std.mem.indexOf(u8, production_source, ".ice_heat_capacity_megajoules_per_m3_k = ice_heat_capacity_per_water_equivalent_m3_k") != null);
    try std.testing.expect(std.mem.indexOf(u8, production_source, ".fertilizer_band = context.fertilizer_band") != null);
    try std.testing.expect(std.mem.indexOf(u8, production_source, ".transport_owners = .{") != null);
    inline for (.{ "context.micropore_solute_state", "context.macropore_solute_state", "context.mineral_nitrogen_transport", "context.soil_organic_transport" }) |binding|
        try std.testing.expect(std.mem.indexOf(u8, production_source, binding) != null);
    try std.testing.expect(std.mem.indexOf(u8, production_source, "pond_boundary_change_m") == null);
    try std.testing.expect(std.mem.indexOf(u8, production_source, "disturbance_mode_by_cell") != null);

    const sediment_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_sediment.zig",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(sediment_source);
    const local_carbon_publication = std.mem.indexOf(u8, sediment_source, "soil_erosion_organic_bridge.publishLocalCarbonNetChangeMapped(") orelse return error.MissingErosionOrganicPublication;
    const erosion_route = std.mem.indexOf(u8, sediment_source, "suspended_constituents.route(") orelse return error.MissingErosionConstituentRoute;
    const vegetation_call = std.mem.indexOf(u8, sediment_source, "group_vegetation.finalizeRedistAndLedgers(") orelse return error.MissingVegetationFinalizeCall;
    try std.testing.expect(local_carbon_publication < erosion_route);
    try std.testing.expect(erosion_route < vegetation_call);

    const vegetation_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_vegetation.zig",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(vegetation_source);
    const dorge_publish = std.mem.indexOf(u8, vegetation_source, "soil_organic_carbon_change.publishAcceptedHourlyChange(") orelse return error.MissingDorgePublish;
    const geometry_finalize = std.mem.indexOf(u8, vegetation_source, "geometry_disturbance.finalize(context)") orelse return error.MissingGeometryFinalize;
    try std.testing.expect(dorge_publish < geometry_finalize);

    const heat_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(heat_source);
    try std.testing.expect(std.mem.indexOf(u8, heat_source, "applyLayerRedistribution(") == null);
}

test "geometry rollback restores selected state and owned buffers byte exactly" {
    const Nested = struct { values: []f64 };
    const State = struct { marker: u32, nested: Nested };
    var grid_values = [_]f64{ 1, 2 };
    var geometry_values = [_]f64{ 3, 4 };
    var unrelated_values = [_]f64{5};
    var macropore_values = [_]f64{ 6, 7 };
    var hydrology_values = [_]f64{ 8, 9 };
    var grid = State{ .marker = 7, .nested = .{ .values = &grid_values } };
    var soil_geometry = State{ .marker = 8, .nested = .{ .values = &geometry_values } };
    var unrelated = State{ .marker = 9, .nested = .{ .values = &unrelated_values } };
    var macropore_solute_state = State{ .marker = 10, .nested = .{ .values = &macropore_values } };
    var transport_hydrology = State{ .marker = 11, .nested = .{ .values = &hydrology_values } };
    const context = .{
        .grid = &grid,
        .soil_geometry = &soil_geometry,
        .macropore_solute_state = &macropore_solute_state,
        .transport_hydrology = &transport_hydrology,
        .unrelated = &unrelated,
    };
    var snapshot = try GeometryRollbackSnapshot.capture(std.testing.allocator, context);
    defer snapshot.deinit();
    grid.marker = 70;
    grid.nested.values[0] = -1;
    soil_geometry.marker = 80;
    soil_geometry.nested.values[1] = -2;
    unrelated.marker = 90;
    unrelated.nested.values[0] = -3;
    macropore_solute_state.marker = 100;
    macropore_solute_state.nested.values[0] = -4;
    transport_hydrology.marker = 110;
    transport_hydrology.nested.values[1] = -5;
    snapshot.restore();
    try std.testing.expectEqual(@as(u32, 7), grid.marker);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, &grid_values);
    try std.testing.expectEqual(@as(u32, 8), soil_geometry.marker);
    try std.testing.expectEqualSlices(f64, &.{ 3, 4 }, &geometry_values);
    try std.testing.expectEqual(@as(u32, 90), unrelated.marker);
    try std.testing.expectEqualSlices(f64, &.{-3}, &unrelated_values);
    try std.testing.expectEqual(@as(u32, 10), macropore_solute_state.marker);
    try std.testing.expectEqualSlices(f64, &.{ 6, 7 }, &macropore_values);
    try std.testing.expectEqual(@as(u32, 11), transport_hydrology.marker);
    try std.testing.expectEqualSlices(f64, &.{ 8, 9 }, &hydrology_values);
}

test "geometry rollback restores fertilizer band geometry and coordinator phase" {
    var band = try ecosys.fertilizer_band_state.State.init(std.testing.allocator, .{
        .cell_count = 1,
        .layer_capacity = 2,
        .active_layer_count_by_cell = &.{2},
        .layer_upper_depth_m = &.{ 0, 0.1 },
        .layer_lower_depth_m = &.{ 0.1, 0.3 },
        .layer_thickness_m = &.{ 0.1, 0.2 },
        .initial_band_fraction_by_family = .{ 0.2, 0.3, 0.4 },
        .row_spacing_m_by_cell_family = &.{ 0.5, 0.6, 0.7 },
    });
    defer band.deinit();
    const context = .{ .fertilizer_band = &band };
    var snapshot = try GeometryRollbackSnapshot.capture(std.testing.allocator, context);
    defer snapshot.deinit();
    const original_width = band.band_width_m[0];
    band.band_width_m[0] = 99;
    try (try band.coordinator(0)).beginHour(.{ .value = 1 });
    snapshot.restore();
    try std.testing.expectEqual(original_width, band.band_width_m[0]);
    try std.testing.expectEqual(
        ecosys.fertilizer_band_phase_coordinator.Phase.idle,
        (try band.coordinator(0)).persistentMetadata().phase,
    );
}

const std = @import("std");
const SimulationConfig = @import("../../core/config.zig").SimulationConfig;
const GridState = @import("../../state/grid.zig").GridState;
const thermal_module = @import("../heat/thermal.zig");
const gas = @import("../gas/transport.zig");
const organic = @import("../organic/initialization.zig");
const chemistry_module = @import("../solute/chemistry_state.zig");
const nutrient_zone_module = @import("../solute/charge_classification.zig");
const solute_transport = @import("../solute/transport.zig");
const solute_transport_species = @import("../solute/transport_species.zig");
const mineral_nitrogen_transport_module = @import("../biogeochemistry/mineral_nitrogen_transport.zig");
const organic_transport_module = @import("../organic/transport.zig");
const reactive = @import("../nutrients/reactive_nitrogen_state.zig");
const nitrogen_fertilizer = @import("../../management/fertilizer_nitrogen_inventory.zig");
const mineral_fertilizer = @import("../../management/mineral_fertilizer_inventory.zig");
const properties = @import("../water/solver_properties.zig");
const RootSystem = @import("../../plant/root/plant_root_system.zig");
const fertilizer_band_module = @import("../../management/fertilizer_band_state.zig");
const Geometry = @import("layer_geometry.zig");
const face_geometry_module = @import("../water/face_geometry.zig");
const transport_module = @import("../../transport/hydrology.zig");
const geometry_transaction = @import("geometry_disturbance_transaction.zig");

const water_heat_remap = @import("../water/heat_layer_remap.zig");
const gas_remap = @import("../gas/layer_remap.zig");
const organic_remap = @import("../organic/layer_remap.zig");
const chemistry_remap = @import("../chemistry/layer_remap.zig");
const nitrite_remap = @import("../microbial/nitrite_layer_remap.zig");
const fertilizer_remap = @import("../nutrients/fertilizer_layer_remap.zig");
const mineral_remap = @import("../nutrients/mineral_layer_remap.zig");
const root_remap = @import("../../plant/root/plant_root_layer_remap.zig");
const relayering_activity = @import("relayering_activity.zig");

test {
    _ = relayering_activity;
}

// STARTS sets ZERO=1e-15 m for REDIST's nonzero boundary-change gate. This is
// distinct from DLYRM, the minimum accepted layer geometry.
const redistribution_zero_m: f64 = 1e-15;

/// Heap-owned scratch for one hourly geometry change transaction.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    disturbance_transaction: geometry_transaction.Workspace,
    /// Scratch: per-layer ice volume delta extracted from the water-heat solver result.
    /// Size: cell_count * layer_capacity.
    ice_volume_delta_m3: []f64,
    /// Scratch: matrix zone fraction (matrix_bulk_volume / layer_volume) per layer.
    /// Size: cell_count * layer_capacity.
    matrix_zone_fraction: []f64,
    organic_carbon_g_per_megagram: []f64,
    reset_organic_accumulation_by_layer: []bool,
    surface_soil_volume_m3_by_cell: []f64,
    receiving_soil_bulk_density_megagrams_per_m3_by_cell: []f64,
    disturbance_mode_by_cell: []i32,
    /// Source-order live DLYR carrier. Each internal boundary change is
    /// applied immediately before its REDIST pair, so earlier changes affect
    /// later pairs while future boundary changes do not.
    live_layer_thickness_m: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_capacity: usize) !Workspace {
        if (cell_count == 0 or layer_capacity == 0) return error.InvalidSoilRelayeringDimensions;
        const layer_count = try std.math.mul(usize, cell_count, layer_capacity);
        var transaction = try geometry_transaction.Workspace.init(allocator, cell_count, layer_capacity);
        errdefer transaction.deinit();
        const ice_delta = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(ice_delta);
        @memset(ice_delta, 0);
        const mzf = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(mzf);
        @memset(mzf, 1);
        const organic_carbon = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(organic_carbon);
        @memset(organic_carbon, 0);
        const reset_organic = try allocator.alloc(bool, layer_count);
        errdefer allocator.free(reset_organic);
        @memset(reset_organic, false);
        const surface_volume = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(surface_volume);
        @memset(surface_volume, 0);
        const receiving_density = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(receiving_density);
        @memset(receiving_density, 0);
        const modes = try allocator.alloc(i32, cell_count);
        errdefer allocator.free(modes);
        @memset(modes, -1);
        const live_thickness = try allocator.alloc(f64, layer_count);
        return .{
            .allocator = allocator,
            .disturbance_transaction = transaction,
            .ice_volume_delta_m3 = ice_delta,
            .matrix_zone_fraction = mzf,
            .organic_carbon_g_per_megagram = organic_carbon,
            .reset_organic_accumulation_by_layer = reset_organic,
            .surface_soil_volume_m3_by_cell = surface_volume,
            .receiving_soil_bulk_density_megagrams_per_m3_by_cell = receiving_density,
            .disturbance_mode_by_cell = modes,
            .live_layer_thickness_m = live_thickness,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.live_layer_thickness_m);
        self.allocator.free(self.disturbance_mode_by_cell);
        self.allocator.free(self.receiving_soil_bulk_density_megagrams_per_m3_by_cell);
        self.allocator.free(self.surface_soil_volume_m3_by_cell);
        self.allocator.free(self.reset_organic_accumulation_by_layer);
        self.allocator.free(self.organic_carbon_g_per_megagram);
        self.allocator.free(self.matrix_zone_fraction);
        self.allocator.free(self.ice_volume_delta_m3);
        self.disturbance_transaction.deinit();
        self.* = undefined;
    }
};

pub const Context = struct {
    grid: *GridState,
    soil_thermal: *thermal_module.State,
    gas_transport: *gas.State,
    soil_organic: *organic.State,
    soil_chemistry: *chemistry_module.State,
    reactive_nitrogen: *reactive.State,
    soil_fertilizer_inventory: *nitrogen_fertilizer.State,
    mineral_fertilizer_inventory: *mineral_fertilizer.State,
    /// Persistent TRNSFR pore-domain owners. Production binds all four as one
    /// unit; matrix inventories follow FX while macropore inventories follow
    /// the FHOL-gated FHO fraction.
    transport_owners: ?TransportOwners = null,
    /// Optional: when non-null, solid chemistry and mineral transfer are applied
    /// and geometry thickness is synced into properties after applyDisturbances.
    soil_properties: ?*properties.State,
    plant_roots: ?*RootSystem.State,
    /// STARTQ `PP` and `ZEROP`: live population and per-plant structural
    /// threshold used by REDIST's root-presence gate.
    plant_population_count: []const f64 = &.{},
    root_presence_floor_per_plant: f64 = redistribution_zero_m,
    /// Authoritative REDIST WDN*B/DPN*B/VL*B fertilizer-band geometry.
    /// Production always binds this owner; focused remap tests may omit it.
    fertilizer_band: ?*fertilizer_band_module.State = null,
    soil_geometry: *Geometry.State,
    /// Optional transaction scratch for source-order live DLYR. Production
    /// binds Workspace storage; direct focused calls may use thermal scratch.
    live_layer_thickness_m: ?[]f64 = null,
    transport_hydrology: ?*transport_module.State = null,
    /// Optional: when non-null (along with soil_transport_faces), face geometry
    /// is refreshed after applyDisturbances.
    soil_face_geometry: ?*face_geometry_module.State,
    soil_transport_faces: ?*transport_module.SoilFaces,
    /// STARTS `DLYRM`, distinct from the runscript's lower geometry-validity
    /// floor. Runtime transport requires strict thickness `> DLYRM`.
    transport_geometry_floor_m: f64 = 1.0e-6,
    water_heat_parameters: water_heat_remap.Parameters,
    salinity_enabled_by_cell: []const bool,
    nutrient_zone_fractions: NutrientZoneFractions,
    nutrient_zone_fractions_by_layer: []const NutrientZoneFractions = &.{},
    plant_populations: usize,
    minimum_layer_thickness_m: f64,
    horizontal_cell_width_m: []const f64,
    vertical_cell_width_m: []const f64,
    /// EXEC-002 remediation switch. When true, the soil-thermal layer volume is
    /// conservatively restated onto the accepted geometry after the transfers.
    /// Focused callers default off; production explicitly enables it.
    rebase_thermal_volume_to_geometry: bool = false,
    /// Optional producer-owned, attempt-atomic local conservation output.
    /// Production supplies the canonical snapshot adapter; focused science
    /// tests may omit it. Each internal face is sampled immediately before and
    /// after its complete source-ordered REDIST mutation.
    local_activity: ?relayering_activity.Binding = null,
};

pub const TransportOwners = struct {
    micropore_solute: *solute_transport.State,
    macropore_solute: *solute_transport.State,
    mineral_nitrogen: *mineral_nitrogen_transport_module.State,
    organic: *organic_transport_module.State,
};

pub const NutrientZoneFractions = struct {
    ammonium_non_band: f64,
    ammonium_band: f64,
    nitrate_non_band: f64,
    nitrate_band: f64,
    phosphate_non_band: f64,
    phosphate_band: f64,
};

/// REDIST DO 245 (NN=1): applies inter-soil-layer pool redistribution for all
/// active cells, then state_updates the geometry change. Pool remaps run in source
/// order matching Fortran REDIST: water/heat → gas → organic → chemistry
/// (aqueous then solid) → nitrite → fertilizer → mineral → plant roots.
/// The geometry transaction is applied only after all pool transfers complete.
///
/// geometry_changes must cover freeze-thaw, SOC, erosion, and pond boundary
/// changes for the current hour as assembled by soil_geometry_disturbance_transaction
/// or soil_geometry_change_assembly helpers. Zero arrays are acceptable when a
/// driver is inactive.
pub fn applyLayerRedistribution(ctx: Context, geometry_changes: Geometry.DisturbanceChanges) !void {
    if (ctx.grid.cell_count == 0) return;
    if (ctx.salinity_enabled_by_cell.len != ctx.grid.cell_count)
        return error.SoilRelayeringSalinityDimensionMismatch;
    if (ctx.nutrient_zone_fractions_by_layer.len != 0 and ctx.nutrient_zone_fractions_by_layer.len != ctx.grid.layer_count)
        return error.SoilRelayeringNutrientZoneDimensionMismatch;
    if (ctx.soil_thermal.layer_thickness_m.len != ctx.grid.layer_count or
        ctx.soil_geometry.layer_thickness_m.len != ctx.grid.layer_count)
        return error.SoilRelayeringThermalGeometryDimensionMismatch;
    const live_layer_thickness_m = ctx.live_layer_thickness_m orelse
        ctx.soil_thermal.layer_thickness_m;
    if (live_layer_thickness_m.len != ctx.grid.layer_count)
        return error.SoilRelayeringThermalGeometryDimensionMismatch;
    @memcpy(live_layer_thickness_m, ctx.soil_geometry.layer_thickness_m);
    if (ctx.soil_properties) |props| {
        if (props.layer_count != ctx.grid.layer_count or
            props.macropore_fraction.len != ctx.grid.layer_count)
            return error.SoilRelayeringPropertyDimensionMismatch;
    }

    if (ctx.local_activity) |binding| {
        try binding.sidecar.validateLayout(ctx.grid.cell_count, ctx.grid.soil_layer_capacity);
        try binding.sidecar.beginAttempt();
    }
    errdefer if (ctx.local_activity) |binding| binding.sidecar.abortAttempt();

    // Validate geometry changes before touching any pool state.
    try Geometry.validateDisturbances(ctx.soil_geometry, geometry_changes, ctx.minimum_layer_thickness_m);

    const cap = ctx.grid.soil_layer_capacity;
    // REDIST's solid owners are extensive, while the Zig chemistry view is
    // concentration based. Track the live extensive carrier independently of
    // VOLX/BKDS so sequential boundary transfers do not mutate HOUR1's physical
    // properties. HOUR1 rebuilds VOLX from accepted geometry after REDIST.
    var live_soil_mass_megagrams: ?[]f64 = null;
    defer if (live_soil_mass_megagrams) |values|
        if (ctx.soil_properties) |props| props.allocator.free(values);
    if (ctx.soil_properties) |props| {
        const values = try props.allocator.alloc(f64, ctx.grid.layer_count);
        live_soil_mass_megagrams = values;
        for (values, 0..) |*value, index| {
            value.* = props.bulk_density_megagrams_per_m3[index] * props.matrix_bulk_volume_m3[index];
            if (!std.math.isFinite(value.*) or value.* < 0)
                return error.InvalidRelayeringSoilMass;
        }
    }

    for (0..ctx.grid.cell_count) |cell| {
        const active = ctx.grid.active_soil_layer_count[cell];
        if (active < 2) continue;
        const first = ctx.soil_geometry.first_active_layer[cell];
        const bnd_base = cell * (cap + 1);

        for (0..active - 1) |offset| {
            const layer = first + offset;
            const g = cell * cap + layer;

            // DDLYRX: total change at the bottom boundary of layer `layer`.
            const bnd_idx = bnd_base + layer + 1;
            const ddlyrx = geometry_changes.pond_m[bnd_idx] + geometry_changes.freeze_thaw_m[bnd_idx] + geometry_changes.erosion_m[bnd_idx] + geometry_changes.organic_carbon_m[bnd_idx];

            // REDIST 8210-8216 refreshes the anchor DLYR at this loop
            // position, but leaves the lower neighbor on its prior live DLYR
            // until that layer becomes the next anchor. Only the last pair
            // refreshes both. This source-order carrier is observable in the
            // WDN*B*DLYR remap and in FX's donor denominator.
            refreshLiveLayerThicknessForBoundary(
                live_layer_thickness_m,
                ctx.soil_geometry,
                geometry_changes,
                cell,
                first,
                active,
                layer,
            );

            if (@abs(ddlyrx) <= redistribution_zero_m) continue;

            // DDLYRX > 0: layer expands upward, pull material from the layer below.
            // DDLYRX < 0: layer contracts, push material to the layer below.
            const src_global: usize = if (ddlyrx > 0) g + 1 else g;
            const dst_global: usize = if (ddlyrx > 0) g else g + 1;
            const src_layer: usize = if (ddlyrx > 0) layer + 1 else layer;
            const dst_layer: usize = if (ddlyrx > 0) layer else layer + 1;

            const src_thickness = live_layer_thickness_m[src_global];
            const dst_thickness = live_layer_thickness_m[dst_global];
            if (!std.math.isFinite(src_thickness) or !std.math.isFinite(dst_thickness))
                return error.InvalidRelayeringLayerThickness;
            // REDIST uses FX=1 when live donor DLYR is at or below DLYRM. It does
            // not skip thin donors, and it does not gate on thermal matrix volume:
            // retained macropore carriers still follow their independent FHO path.
            const fx = redistributionFraction(@abs(ddlyrx), src_thickness, ctx.transport_geometry_floor_m);
            if (fx == 0) continue;
            // REDIST 9490--9492 admits the soil-content block only when both
            // live DLYR endpoints strictly exceed STARTS DLYRM. FX may still
            // saturate to one for other REDIST branches, but those are not a
            // license to move soil owners through an inactive endpoint.
            if (src_thickness <= ctx.transport_geometry_floor_m or
                dst_thickness <= ctx.transport_geometry_floor_m)
                continue;

            const zero_volume_m3 = redistribution_zero_m *
                ctx.horizontal_cell_width_m[cell] * ctx.vertical_cell_width_m[cell];
            const src_matrix_volume_before = if (ctx.soil_properties) |props|
                props.matrix_bulk_volume_m3[src_global]
            else
                ctx.soil_thermal.layer_volume_m3[src_global];
            const dst_matrix_volume_before = if (ctx.soil_properties) |props|
                props.matrix_bulk_volume_m3[dst_global]
            else
                ctx.soil_thermal.layer_volume_m3[dst_global];
            inline for (.{ src_matrix_volume_before, dst_matrix_volume_before, zero_volume_m3 }) |value|
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidRelayeringLayerVolume;
            // REDIST 10322--10555 wraps soil organic matter and below-ground
            // plant pools in this VOLX gate. Macropore organic owners also
            // remain inside it, then apply their separate FHOL/FHO gate.
            const organic_root_fraction = if (src_matrix_volume_before > zero_volume_m3 and
                dst_matrix_volume_before > zero_volume_m3) fx else 0;

            // REDIST 9611 and 10110 gate every macropore carrier on FHOL at
            // both endpoints. FHOL is the runtime property owner; the grid
            // capacity is the equivalent fallback for focused tests that do
            // not construct the full properties table.
            const source_macropore_fraction = if (ctx.soil_properties) |props|
                props.macropore_fraction[src_global]
            else
                gridMacroporePresence(ctx.grid, src_global);
            const destination_macropore_fraction = if (ctx.soil_properties) |props|
                props.macropore_fraction[dst_global]
            else
                gridMacroporePresence(ctx.grid, dst_global);
            inline for (.{ source_macropore_fraction, destination_macropore_fraction }) |value|
                if (!std.math.isFinite(value) or value < 0 or value > 1)
                    return error.InvalidRelayeringMacroporeFraction;
            const fho = if (source_macropore_fraction > 0 and destination_macropore_fraction > 0)
                fx
            else
                0;

            // Save water volumes and the current zonal carriers before either
            // REDIST band geometry or water/heat changes them.
            const src_water_before = ctx.grid.matrix_liquid_water_m3[src_global];
            const dst_water_before = ctx.grid.matrix_liquid_water_m3[dst_global];
            const src_zone_fractions_before = try currentNutrientZoneFractions(
                ctx,
                cell,
                src_layer,
                src_global,
            );
            const dst_zone_fractions_before = try currentNutrientZoneFractions(
                ctx,
                cell,
                dst_layer,
                dst_global,
            );
            const live_soil_mass_view: []const f64 = if (live_soil_mass_megagrams) |values|
                values
            else
                &.{};
            const donor_before_activity = if (ctx.local_activity) |binding|
                try binding.sidecar.captureLayer(binding.snapshot_source, cell, src_layer, live_soil_mass_view)
            else
                null;
            const recipient_before_activity = if (ctx.local_activity) |binding|
                try binding.sidecar.captureLayer(binding.snapshot_source, cell, dst_layer, live_soil_mass_view)
            else
                null;

            // REDIST 9494-9589 precedes water, solute, adsorbed, and
            // precipitated transfers. It moves WDN*B*DLYR and DPN*B, then
            // rebuilds VL*B/VL* on the accepted post-disturbance layer
            // thickness. Concentration owners below therefore use old zone
            // volumes before and these new zone volumes after the transfer.
            if (ctx.fertilizer_band) |band_state| {
                const boundary_post_thickness_m = live_layer_thickness_m[g];
                const source_post_thickness_m = live_layer_thickness_m[src_global];
                const destination_post_thickness_m = live_layer_thickness_m[dst_global];
                const boundary_bottom_depth_m = stagedLayerBottomFromSurface(
                    ctx.soil_geometry,
                    geometry_changes,
                    cell,
                    first,
                    layer,
                );
                try band_state.remapSoilLayerPair(
                    cell,
                    first,
                    layer,
                    src_layer,
                    dst_layer,
                    fx,
                    boundary_post_thickness_m,
                    source_post_thickness_m,
                    destination_post_thickness_m,
                    boundary_bottom_depth_m,
                );
            }
            const src_zone_fractions_after = try currentNutrientZoneFractions(
                ctx,
                cell,
                src_layer,
                src_global,
            );
            const dst_zone_fractions_after = try currentNutrientZoneFractions(
                ctx,
                cell,
                dst_layer,
                dst_global,
            );
            if (ctx.transport_owners) |owners|
                try validateTransportOwnerLayerFractions(
                    owners,
                    ctx.grid.layer_count,
                    src_global,
                    dst_global,
                    fx,
                    fho,
                    organic_root_fraction,
                    if (organic_root_fraction > 0) fho else 0,
                    dst_zone_fractions_after,
                );

            // 1. Water / heat.
            try water_heat_remap.transferLayerFractions(
                ctx.grid,
                ctx.soil_thermal,
                src_global,
                dst_global,
                fx,
                fho,
                ctx.water_heat_parameters,
            );

            // FHOL is intensive: the donor keeps its property, while the
            // recipient receives the exact source weighted update at
            // redist.f:9613. Grid macropore capacity and phase stores above
            // are extensive and therefore move donor-to-recipient.
            if (ctx.soil_properties) |props| {
                if (fho > 0)
                    props.macropore_fraction[dst_global] =
                        (1 - fx) * destination_macropore_fraction +
                        fx * source_macropore_fraction;
            }

            // 2. Gas (gaseous, dissolved, band-dissolved species). REDIST gates
            // band NH3 on recipient VLNHB geometry, independent of whether the
            // band happens to be dry during this transfer.
            try gas_remap.transferLayerFractions(
                ctx.gas_transport,
                src_global,
                dst_global,
                dst_zone_fractions_after.ammonium_band,
                fx,
                fho,
            );

            // 3. Organic matter.
            try organic_remap.transferLayerFraction(
                ctx.soil_organic,
                src_global,
                dst_global,
                organic_root_fraction,
            );

            if (ctx.transport_owners) |owners|
                transferTransportOwnerLayerFractions(
                    owners,
                    src_global,
                    dst_global,
                    fx,
                    fho,
                    organic_root_fraction,
                    if (organic_root_fraction > 0) fho else 0,
                    ctx.grid.matrix_liquid_water_m3,
                    ctx.grid.macropore_liquid_water_m3,
                    dst_zone_fractions_after,
                );

            // 4a. Aqueous chemistry (concentration-based, before/after volumes).
            const src_water_after = ctx.grid.matrix_liquid_water_m3[src_global];
            const dst_water_after = ctx.grid.matrix_liquid_water_m3[dst_global];
            const src_zones_before = waterZones(src_water_before, src_zone_fractions_before);
            const dst_zones_before = waterZones(dst_water_before, dst_zone_fractions_before);
            const src_zones_after = waterZones(src_water_after, src_zone_fractions_after);
            const dst_zones_after = waterZones(dst_water_after, dst_zone_fractions_after);
            try chemistry_remap.transferAqueousLayerFraction(
                ctx.soil_chemistry,
                src_global,
                dst_global,
                src_zones_before,
                dst_zones_before,
                src_zones_after,
                dst_zones_after,
                ctx.salinity_enabled_by_cell[cell],
                fx,
            );

            // 4b. Solid chemistry and 7. Mineral: both need soil mass, which
            // requires soil_properties. Skip when not provided (e.g. in tests).
            if (ctx.soil_properties) |props| {
                // Solid chemistry is defined per Mg of mineral matrix. Total
                // layer volume includes the separate macropore domain and is
                // not its carrier; using it creates adsorbed mass whenever
                // freeze-thaw relayering changes the matrix share.
                const live_mass = live_soil_mass_megagrams.?;
                const src_mass_before = live_mass[src_global];
                const dst_mass_before = live_mass[dst_global];

                // 4b. REDIST moves adsorbed/precipitated/geochemical solids only
                // upward (L0 > L1). Downward physical relayering still rebases
                // concentrations onto the new carriers with a zero transfer.
                const solid_transfer_fraction = if (src_layer > dst_layer) fx else 0;
                {
                    const moved_mass = fx * src_mass_before;
                    try chemistry_remap.transferSolidLayerFraction(
                        ctx.soil_chemistry,
                        src_global,
                        dst_global,
                        src_mass_before,
                        dst_mass_before,
                        src_water_before,
                        dst_water_before,
                        .{
                            .source_before = chemistryZoneFractions(src_zone_fractions_before),
                            .destination_before = chemistryZoneFractions(dst_zone_fractions_before),
                            .source_after = chemistryZoneFractions(src_zone_fractions_after),
                            .destination_after = chemistryZoneFractions(dst_zone_fractions_after),
                        },
                        src_mass_before - moved_mass,
                        dst_mass_before + moved_mass,
                        src_water_after,
                        dst_water_after,
                        solid_transfer_fraction,
                    );
                }

                // 7. Mineral / sediment and its physical carrier. The legacy
                // soil branch transfers FX of SAND/SILT/CLAY for every FX > 0.
                const src_mass_after = src_mass_before - fx * src_mass_before;
                const dst_mass_after = dst_mass_before + fx * src_mass_before;
                try mineral_remap.transferLayerFraction(
                    props,
                    src_global,
                    dst_global,
                    fx,
                    solid_transfer_fraction,
                    src_mass_after,
                    dst_mass_after,
                );
                live_mass[src_global] = src_mass_after;
                live_mass[dst_global] = dst_mass_after;
            }

            // 5. Nitrite.
            try nitrite_remap.transferLayerFraction(
                ctx.reactive_nitrogen,
                src_global,
                dst_global,
                dst_zone_fractions_after.nitrate_band,
                fx,
            );

            // 6. Fertilizer (cell-relative layer indices).
            try fertilizer_remap.transferCellLayerFraction(
                ctx.soil_fertilizer_inventory,
                ctx.mineral_fertilizer_inventory,
                cell,
                layer,
                src_layer,
                dst_layer,
                fx,
            );

            // 8. Plant roots (loop over all plants in this cell).
            if (ctx.plant_roots) |roots| {
                try root_remap.transferPondedCellLayerFraction(
                    roots,
                    cell,
                    ctx.plant_populations,
                    ctx.plant_population_count,
                    ctx.root_presence_floor_per_plant,
                    src_layer,
                    dst_layer,
                    organic_root_fraction,
                );
            }
            if (ctx.local_activity) |binding| {
                const donor_after_activity = try binding.sidecar.captureLayer(
                    binding.snapshot_source,
                    cell,
                    src_layer,
                    live_soil_mass_view,
                );
                const recipient_after_activity = try binding.sidecar.captureLayer(
                    binding.snapshot_source,
                    cell,
                    dst_layer,
                    live_soil_mass_view,
                );
                try binding.sidecar.stageBoundary(
                    cell,
                    src_layer,
                    dst_layer,
                    donor_before_activity.?,
                    recipient_before_activity.?,
                    donor_after_activity,
                    recipient_after_activity,
                );
            }
        }
    }

    // StateUpdate geometry after all pool transfers succeed.
    try Geometry.applyDisturbances(ctx.soil_geometry, geometry_changes, ctx.minimum_layer_thickness_m);
    @memcpy(ctx.soil_thermal.layer_thickness_m, ctx.soil_geometry.layer_thickness_m);
    // EXEC-002: `soil_thermal.layer_volume_m3` drifts from the state_updateted
    // `layer_thickness_m * cell_area_m2` here. The drift is confined to the top
    // active layer, whose upper face is a free surface with no paired transfer
    // (2.8e-2 relative there, 5.3e-16 for every deeper layer). Because the EXEC
    // heat census forms extensive capacity as `dry_capacity_per_m3 * volume`,
    // that drift reads as created heat.
    //
    // `rebaseThermalVolumeToGeometry` conservatively rebuilds the intensive dry
    // heat capacity on the accepted geometry while retaining all phase-carried
    // heat. Focused callers may leave it disabled; the production stage enables
    // it so the heat census and the water/heat state update share one volume.
    if (ctx.rebase_thermal_volume_to_geometry) try rebaseThermalVolumeToGeometry(ctx, cap);
    if (ctx.soil_properties) |props| {
        @memcpy(props.layer_thickness_m, ctx.soil_geometry.layer_thickness_m);
        @memcpy(props.layer_midpoint_depth_m, ctx.soil_geometry.layer_midpoint_depth_from_surface_m);
        @memcpy(props.layer_bottom_depth_m, ctx.soil_geometry.layer_bottom_depth_from_surface_m);
        // `matrix_bulk_volume_m3` was moved between layers above, but
        // `layer_volume_m3` was left at its initialization value. Consumers
        // divide one by the other: `matrix_zone_fraction` and
        // `soil_matrix_fraction` in `ecosys_ng.zig` both do, and the latter
        // feeds the next hour's freeze-thaw boundary change. Leaving them
        // inconsistent lets a transfer silently change a fraction that is
        // supposed to describe the same layer. Restate the total volume from the
        // state_updateted geometry so the ratio stays meaningful.
        for (0..ctx.grid.cell_count) |cell| {
            const area_m2 = ctx.horizontal_cell_width_m[cell] * ctx.vertical_cell_width_m[cell];
            if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidRelayeringCellArea;
            const active = ctx.grid.active_soil_layer_count[cell];
            const first = ctx.soil_geometry.first_active_layer[cell];
            for (0..active) |offset| {
                const layer = first + offset;
                const g = cell * cap + layer;
                const volume_m3 = ctx.soil_geometry.layer_thickness_m[g] * area_m2;
                const matrix_fraction = props.micropore_fraction[g];
                const density = props.bulk_density_megagrams_per_m3[g];
                if (!std.math.isFinite(volume_m3) or volume_m3 <= 0 or
                    !std.math.isFinite(matrix_fraction) or matrix_fraction <= 0 or matrix_fraction > 1 or
                    !std.math.isFinite(density) or density < 0)
                    return error.InvalidRelayeringLayerVolume;
                const matrix_volume_m3 = volume_m3 * matrix_fraction;
                const accepted_soil_mass_megagrams = density * matrix_volume_m3;
                try chemistry_remap.rebaseSolidSoilMassCarrier(
                    ctx.soil_chemistry,
                    g,
                    live_soil_mass_megagrams.?[g],
                    accepted_soil_mass_megagrams,
                    chemistryZoneFractions(try currentNutrientZoneFractions(ctx, cell, layer, g)),
                );
                try mineral_remap.rebaseLayerCarrier(props, g, accepted_soil_mass_megagrams);
                props.layer_volume_m3[g] = volume_m3;
                props.matrix_bulk_volume_m3[g] = matrix_volume_m3;
            }
        }
    }
    if (ctx.transport_owners) |owners| {
        @memcpy(owners.micropore_solute.water_volume_m3, ctx.grid.matrix_liquid_water_m3);
        @memcpy(owners.macropore_solute.water_volume_m3, ctx.grid.macropore_liquid_water_m3);
        @memcpy(owners.mineral_nitrogen.matrix.water_volume_m3, ctx.grid.matrix_liquid_water_m3);
        @memcpy(owners.mineral_nitrogen.macropore.water_volume_m3, ctx.grid.macropore_liquid_water_m3);
    }
    if (ctx.transport_hydrology) |hydrology| {
        @memcpy(hydrology.micropore_water_volume_m3, ctx.grid.matrix_liquid_water_m3);
        @memcpy(hydrology.macropore_water_volume_m3, ctx.grid.macropore_liquid_water_m3);
        @memcpy(hydrology.matrix_air_volume_m3, ctx.grid.matrix_air_volume_m3);
        @memcpy(hydrology.macropore_air_volume_m3, ctx.grid.macropore_air_volume_m3);
        @memcpy(hydrology.air_volume_m3, ctx.grid.air_volume_m3);
        @memcpy(hydrology.water_vapor_volume_m3, ctx.grid.water_vapor_volume_m3);
        try hydrology.validateFinite();
    }
    if (ctx.soil_transport_faces) |tf| {
        const hydrology = ctx.transport_hydrology orelse
            return error.RelayeringTransportFacesRequireHydrology;
        try tf.refreshMapped(
            hydrology,
            ctx.grid,
            ctx.soil_geometry,
            ctx.transport_geometry_floor_m,
        );
    }
    if (ctx.soil_face_geometry) |fg| if (ctx.soil_transport_faces) |tf| {
        try fg.refreshMapped(
            ctx.grid,
            tf,
            ctx.soil_geometry.layer_thickness_m,
            ctx.horizontal_cell_width_m,
            ctx.vertical_cell_width_m,
        );
    };
    if (ctx.local_activity) |binding| try binding.sidecar.commitAttempt();
}

fn gridMacroporePresence(grid: *const GridState, index: usize) f64 {
    return if (grid.macropore_pore_capacity_m3[index] > 0) 1 else 0;
}

fn redistributionFraction(abs_boundary_change_m: f64, donor_thickness_m: f64, minimum_layer_thickness_m: f64) f64 {
    if (donor_thickness_m <= minimum_layer_thickness_m) return 1;
    return @min(1.0, abs_boundary_change_m / donor_thickness_m);
}

fn validateTransportOwnerLayerFractions(
    owners: TransportOwners,
    layer_count: usize,
    source: usize,
    destination: usize,
    matrix_fraction: f64,
    macropore_fraction: f64,
    organic_matrix_fraction: f64,
    organic_macropore_fraction: f64,
    destination_zone_fractions: NutrientZoneFractions,
) !void {
    if (owners.micropore_solute.cell_count != layer_count or
        owners.macropore_solute.cell_count != layer_count or
        owners.mineral_nitrogen.cell_count != layer_count or
        owners.organic.layer_count != layer_count)
        return error.RelayeringTransportOwnerDimensionMismatch;
    try validateMicroporeSoluteLayerFraction(
        owners.micropore_solute,
        source,
        destination,
        matrix_fraction,
        destination_zone_fractions,
    );
    try validateAqueousTransportLayerFraction(owners.macropore_solute, source, destination, macropore_fraction);
    try validateMineralNitrogenLayerFraction(
        &owners.mineral_nitrogen.matrix,
        source,
        destination,
        matrix_fraction,
        destination_zone_fractions,
    );
    try validateAqueousTransportLayerFraction(&owners.mineral_nitrogen.macropore, source, destination, macropore_fraction);
    try validatePackedLayerFraction(owners.organic.micropore_amount_g, layer_count, source, destination, organic_matrix_fraction);
    try validatePackedLayerFraction(owners.organic.macropore_amount_g, layer_count, source, destination, organic_macropore_fraction);
}

fn validateAqueousTransportLayerFraction(
    state: *const solute_transport.State,
    source: usize,
    destination: usize,
    fraction: f64,
) !void {
    if (state.species_count == 0 or state.water_volume_m3.len != state.cell_count or
        state.amount_mol.len != state.cell_count * state.species_count)
        return error.RelayeringTransportOwnerDimensionMismatch;
    const source_first = source * state.species_count;
    const destination_first = destination * state.species_count;
    for (0..state.species_count) |species|
        try validateTransferPair(
            state.amount_mol[source_first + species],
            state.amount_mol[destination_first + species],
            fraction,
        );
}

fn validateMicroporeSoluteLayerFraction(
    state: *const solute_transport.State,
    source: usize,
    destination: usize,
    fraction: f64,
    destination_zone_fractions: NutrientZoneFractions,
) !void {
    if (state.species_count != solute_transport_species.AqueousSpecies.count or
        state.water_volume_m3.len != state.cell_count or
        state.amount_mol.len != state.cell_count * state.species_count)
        return error.RelayeringTransportOwnerDimensionMismatch;
    const source_first = source * state.species_count;
    const destination_first = destination * state.species_count;
    inline for (std.enums.values(solute_transport_species.AqueousSpecies)) |species| {
        const component = @intFromEnum(species);
        try validateTransferPair(
            state.amount_mol[source_first + component],
            state.amount_mol[destination_first + component],
            microporeSoluteTransferFraction(species, fraction, destination_zone_fractions),
        );
    }
}

fn validatePackedLayerFraction(
    values: []const f64,
    layer_count: usize,
    source: usize,
    destination: usize,
    fraction: f64,
) !void {
    if (values.len % layer_count != 0) return error.RelayeringTransportOwnerDimensionMismatch;
    const per_layer = values.len / layer_count;
    for (0..per_layer) |component|
        try validateTransferPair(
            values[source * per_layer + component],
            values[destination * per_layer + component],
            fraction,
        );
}

fn validateTransferPair(source: f64, destination: f64, fraction: f64) !void {
    const moved = fraction * source;
    inline for (.{ source, destination, moved, source - moved, destination + moved }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidRelayeringTransportOwnerState;
}

fn transferTransportOwnerLayerFractions(
    owners: TransportOwners,
    source: usize,
    destination: usize,
    matrix_fraction: f64,
    macropore_fraction: f64,
    organic_matrix_fraction: f64,
    organic_macropore_fraction: f64,
    matrix_water_m3: []const f64,
    macropore_water_m3: []const f64,
    destination_zone_fractions: NutrientZoneFractions,
) void {
    transferMicroporeSoluteLayerFraction(
        owners.micropore_solute,
        source,
        destination,
        matrix_fraction,
        matrix_water_m3,
        destination_zone_fractions,
    );
    transferAqueousTransportLayerFraction(owners.macropore_solute, source, destination, macropore_fraction, macropore_water_m3);
    transferMineralNitrogenLayerFraction(
        &owners.mineral_nitrogen.matrix,
        source,
        destination,
        matrix_fraction,
        matrix_water_m3,
        destination_zone_fractions,
    );
    transferAqueousTransportLayerFraction(&owners.mineral_nitrogen.macropore, source, destination, macropore_fraction, macropore_water_m3);
    transferPackedLayerFraction(owners.organic.micropore_amount_g, owners.organic.layer_count, source, destination, organic_matrix_fraction);
    transferPackedLayerFraction(owners.organic.macropore_amount_g, owners.organic.layer_count, source, destination, organic_macropore_fraction);
}

fn validateMineralNitrogenLayerFraction(
    state: *const solute_transport.State,
    source: usize,
    destination: usize,
    fraction: f64,
    destination_zone_fractions: NutrientZoneFractions,
) !void {
    if (state.species_count != mineral_nitrogen_transport_module.species_count or
        state.water_volume_m3.len != state.cell_count or
        state.amount_mol.len != state.cell_count * state.species_count)
        return error.RelayeringTransportOwnerDimensionMismatch;
    const source_first = source * state.species_count;
    const destination_first = destination * state.species_count;
    inline for (std.enums.values(mineral_nitrogen_transport_module.Species)) |species| {
        const component = @intFromEnum(species);
        try validateTransferPair(
            state.amount_mol[source_first + component],
            state.amount_mol[destination_first + component],
            mineralNitrogenTransferFraction(species, fraction, destination_zone_fractions),
        );
    }
}

fn transferMineralNitrogenLayerFraction(
    state: *solute_transport.State,
    source: usize,
    destination: usize,
    fraction: f64,
    water_m3: []const f64,
    destination_zone_fractions: NutrientZoneFractions,
) void {
    const source_first = source * state.species_count;
    const destination_first = destination * state.species_count;
    inline for (std.enums.values(mineral_nitrogen_transport_module.Species)) |species| {
        const component = @intFromEnum(species);
        transferPair(
            state.amount_mol,
            source_first + component,
            destination_first + component,
            mineralNitrogenTransferFraction(species, fraction, destination_zone_fractions),
        );
    }
    state.water_volume_m3[source] = water_m3[source];
    state.water_volume_m3[destination] = water_m3[destination];
}

fn mineralNitrogenTransferFraction(
    species: mineral_nitrogen_transport_module.Species,
    fraction: f64,
    destination_zone_fractions: NutrientZoneFractions,
) f64 {
    return switch (species) {
        .ammonium_band, .ammonia_band => if (destination_zone_fractions.ammonium_band > 0) fraction else 0,
        .nitrate_band, .nitrite_band => if (destination_zone_fractions.nitrate_band > 0) fraction else 0,
        else => fraction,
    };
}

fn transferAqueousTransportLayerFraction(
    state: *solute_transport.State,
    source: usize,
    destination: usize,
    fraction: f64,
    water_m3: []const f64,
) void {
    const source_first = source * state.species_count;
    const destination_first = destination * state.species_count;
    for (0..state.species_count) |species|
        transferPair(state.amount_mol, source_first + species, destination_first + species, fraction);
    state.water_volume_m3[source] = water_m3[source];
    state.water_volume_m3[destination] = water_m3[destination];
}

fn transferMicroporeSoluteLayerFraction(
    state: *solute_transport.State,
    source: usize,
    destination: usize,
    fraction: f64,
    water_m3: []const f64,
    destination_zone_fractions: NutrientZoneFractions,
) void {
    const source_first = source * state.species_count;
    const destination_first = destination * state.species_count;
    inline for (std.enums.values(solute_transport_species.AqueousSpecies)) |species| {
        const component = @intFromEnum(species);
        transferPair(
            state.amount_mol,
            source_first + component,
            destination_first + component,
            microporeSoluteTransferFraction(species, fraction, destination_zone_fractions),
        );
    }
    state.water_volume_m3[source] = water_m3[source];
    state.water_volume_m3[destination] = water_m3[destination];
}

fn microporeSoluteTransferFraction(
    species: solute_transport_species.AqueousSpecies,
    fraction: f64,
    destination_zone_fractions: NutrientZoneFractions,
) f64 {
    return switch (species) {
        .band_phosphate,
        .band_phosphoric_acid,
        .band_iron_hpo4,
        .band_iron_h2po4,
        .band_calcium_phosphate,
        .band_calcium_hpo4,
        .band_calcium_h2po4,
        .band_magnesium_hpo4,
        .band_hpo4,
        .band_h2po4,
        => if (destination_zone_fractions.phosphate_band > 0) fraction else 0,
        else => fraction,
    };
}

fn transferPackedLayerFraction(
    values: []f64,
    layer_count: usize,
    source: usize,
    destination: usize,
    fraction: f64,
) void {
    const per_layer = values.len / layer_count;
    for (0..per_layer) |component|
        transferPair(values, source * per_layer + component, destination * per_layer + component, fraction);
}

fn transferPair(values: []f64, source: usize, destination: usize, fraction: f64) void {
    const moved = fraction * values[source];
    values[source] -= moved;
    values[destination] += moved;
}

/// End-of-hour GEOM-ASSEMBLE entry point. All accepted pond, freeze-thaw,
/// erosion, and cancellation-adjusted SOC legs are consumed together. The
/// transaction guard rejects any second or leg-by-leg state_update before pool or
/// geometry mutation, while `applyLayerRedistribution` remains the sole owner of
/// extensive/intensive remaps and `Geometry.applyDisturbances`.
pub fn applyStagedGeometryTransaction(ctx: Context, transaction: *geometry_transaction.Workspace) !void {
    try transaction.state_updateOnce(ctx, applyLayerRedistribution);
}

pub const EndOfHourInputs = geometry_transaction.Inputs;

/// Owns the single accepted end-of-hour REDIST geometry transaction. A retry
/// always discards the prior staged legs before assembling fresh accepted
/// drivers; pond remains zero inside `geometry_transaction.stage`.
pub fn applyEndOfHourGeometry(
    ctx: Context,
    workspace: *Workspace,
    inputs: EndOfHourInputs,
) !void {
    try workspace.disturbance_transaction.resetForNextHour();
    try geometry_transaction.stage(
        &workspace.disturbance_transaction,
        ctx.soil_geometry,
        inputs,
    );
    try applyStagedGeometryTransaction(ctx, &workspace.disturbance_transaction);
}

/// Restates the soil-thermal layer volume onto the state_updateted geometry without
/// moving energy. The extensive dry and total heat capacities are held fixed, so
/// the EXEC heat census sees the same energy before and after; only the
/// per-volume densities and the porosity fraction are restated.
///
/// Every active layer is restated. Deeper layers normally differ only by f64
/// rounding, while the free surface can differ materially; treating them
/// uniformly keeps geometry, solver properties, and thermal carriers exact.
fn rebaseThermalVolumeToGeometry(ctx: Context, cap: usize) !void {
    for (0..ctx.grid.cell_count) |cell| {
        const area_m2 = ctx.horizontal_cell_width_m[cell] * ctx.vertical_cell_width_m[cell];
        if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidRelayeringCellArea;
        const active = ctx.grid.active_soil_layer_count[cell];
        const first = ctx.soil_geometry.first_active_layer[cell];
        for (first..first + active) |layer| {
            const g = cell * cap + layer;
            const geometry_volume_m3 = ctx.soil_geometry.layer_thickness_m[g] * area_m2;
            if (!std.math.isFinite(geometry_volume_m3) or geometry_volume_m3 <= 0) return error.InvalidRelayeringLayerVolume;
            const previous_volume_m3 = ctx.soil_thermal.layer_volume_m3[g];
            if (!std.math.isFinite(previous_volume_m3) or previous_volume_m3 < 0) return error.InvalidRelayeringLayerVolume;
            if (previous_volume_m3 == geometry_volume_m3) continue;
            const extensive_dry = ctx.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[g] * previous_volume_m3;
            const extensive_total = if (previous_volume_m3 > 0)
                ctx.soil_thermal.total_heat_capacity_megajoules_per_m3_k[g] * previous_volume_m3
            else
                ctx.water_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
                    (ctx.grid.matrix_liquid_water_m3[g] + ctx.grid.macropore_liquid_water_m3[g] + ctx.grid.water_vapor_volume_m3[g]) +
                    ctx.water_heat_parameters.ice_heat_capacity_megajoules_per_m3_k *
                        (ctx.grid.matrix_ice_water_m3[g] + ctx.grid.macropore_ice_water_m3[g]);
            ctx.soil_thermal.layer_volume_m3[g] = geometry_volume_m3;
            ctx.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[g] = extensive_dry / geometry_volume_m3;
            ctx.soil_thermal.total_heat_capacity_megajoules_per_m3_k[g] = extensive_total / geometry_volume_m3;
            ctx.soil_thermal.porosity_fraction[g] =
                (ctx.grid.matrix_pore_capacity_m3[g] + ctx.grid.macropore_pore_capacity_m3[g]) / geometry_volume_m3;
            inline for (.{
                ctx.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[g],
                ctx.soil_thermal.total_heat_capacity_megajoules_per_m3_k[g],
                ctx.soil_thermal.porosity_fraction[g],
            }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRelayeringThermalRebase;
        }
    }
}

fn currentNutrientZoneFractions(
    ctx: Context,
    cell: usize,
    layer: usize,
    global_layer: usize,
) !NutrientZoneFractions {
    if (ctx.fertilizer_band) |band_state| {
        const live = try band_state.zoneFractions(cell, layer);
        return .{
            .ammonium_non_band = live.ammonium_non_band,
            .ammonium_band = live.ammonium_band,
            .nitrate_non_band = live.nitrate_non_band,
            .nitrate_band = live.nitrate_band,
            .phosphate_non_band = live.phosphate_non_band,
            .phosphate_band = live.phosphate_band,
        };
    }
    return if (ctx.nutrient_zone_fractions_by_layer.len == 0)
        ctx.nutrient_zone_fractions
    else
        ctx.nutrient_zone_fractions_by_layer[global_layer];
}

fn chemistryZoneFractions(fractions: NutrientZoneFractions) nutrient_zone_module.ZoneFractions {
    return .{
        .ammonium_non_band = fractions.ammonium_non_band,
        .ammonium_band = fractions.ammonium_band,
        .nitrate_non_band = fractions.nitrate_non_band,
        .nitrate_band = fractions.nitrate_band,
        .phosphate_non_band = fractions.phosphate_non_band,
        .phosphate_band = fractions.phosphate_band,
    };
}

fn stagedBoundaryDepth(
    geometry: *const Geometry.State,
    changes: Geometry.DisturbanceChanges,
    cell: usize,
    boundary: usize,
) f64 {
    const index = cell * (geometry.layer_capacity + 1) + boundary;
    return geometry.boundary_depth_m[index] +
        changes.pond_m[index] +
        changes.freeze_thaw_m[index] +
        changes.erosion_m[index] +
        changes.organic_carbon_m[index];
}

fn stagedLayerThickness(
    geometry: *const Geometry.State,
    changes: Geometry.DisturbanceChanges,
    cell: usize,
    layer: usize,
) f64 {
    return stagedBoundaryDepth(geometry, changes, cell, layer + 1) -
        stagedBoundaryDepth(geometry, changes, cell, layer);
}

fn refreshLiveLayerThicknessForBoundary(
    live_layer_thickness_m: []f64,
    geometry: *const Geometry.State,
    changes: Geometry.DisturbanceChanges,
    cell: usize,
    first_active_layer: usize,
    active_layer_count: usize,
    boundary_layer: usize,
) void {
    const layer_base = cell * geometry.layer_capacity;
    live_layer_thickness_m[layer_base + boundary_layer] = stagedLayerThickness(
        geometry,
        changes,
        cell,
        boundary_layer,
    );
    if (boundary_layer + 1 == first_active_layer + active_layer_count - 1)
        live_layer_thickness_m[layer_base + boundary_layer + 1] = stagedLayerThickness(
            geometry,
            changes,
            cell,
            boundary_layer + 1,
        );
}

fn stagedLayerBottomFromSurface(
    geometry: *const Geometry.State,
    changes: Geometry.DisturbanceChanges,
    cell: usize,
    first_active_layer: usize,
    layer: usize,
) f64 {
    return stagedBoundaryDepth(geometry, changes, cell, layer + 1) -
        stagedBoundaryDepth(geometry, changes, cell, first_active_layer);
}

/// Build the distinct runtime nutrient carriers used by concentration state.
fn waterZones(shared_m3: f64, fractions: NutrientZoneFractions) chemistry_remap.ZoneWaterVolumes {
    return .{
        .shared_m3 = shared_m3,
        .ammonium_non_band_m3 = shared_m3 * fractions.ammonium_non_band,
        .ammonium_band_m3 = shared_m3 * fractions.ammonium_band,
        .nitrate_non_band_m3 = shared_m3 * fractions.nitrate_non_band,
        .nitrate_band_m3 = shared_m3 * fractions.nitrate_band,
        .phosphate_non_band_m3 = shared_m3 * fractions.phosphate_non_band,
        .phosphate_band_m3 = shared_m3 * fractions.phosphate_band,
    };
}

test "REDIST live DLYR exposes prior but not future boundary changes" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 3);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.1, 0.2, 0.3 }, 0, 1e-9);
    const zero = [_]f64{0} ** 4;
    const boundary_change = [_]f64{ 0, 0.02, 0.03, 0 };
    const changes: Geometry.DisturbanceChanges = .{
        .pond_m = &zero,
        .freeze_thaw_m = &boundary_change,
        .erosion_m = &zero,
        .organic_carbon_m = &zero,
    };
    var live = [_]f64{ 0.1, 0.2, 0.3 };

    refreshLiveLayerThicknessForBoundary(&live, &geometry, changes, 0, 0, 3, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.12), live[0], 1e-15);
    // REDIST 8213 does not refresh the lower layer until the last pair.
    try std.testing.expectEqual(@as(f64, 0.2), live[1]);
    try std.testing.expectEqual(@as(f64, 0.3), live[2]);

    refreshLiveLayerThicknessForBoundary(&live, &geometry, changes, 0, 0, 3, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.21), live[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.27), live[2], 1e-15);
}

const TestWaterSnapshotContext = struct {
    grid: *const GridState,

    fn capture(
        raw: *anyopaque,
        cell: usize,
        layer: usize,
        _: []const f64,
    ) !@import("../../validation/landscape_mass_inventory_support.zig").Storage {
        const self: *TestWaterSnapshotContext = @ptrCast(@alignCast(raw));
        if (cell >= self.grid.cell_count or layer >= self.grid.soil_layer_capacity)
            return error.TestWaterSnapshotOutOfBounds;
        const index = cell * self.grid.soil_layer_capacity + layer;
        return .{ .water_m3 = self.grid.matrix_liquid_water_m3[index] +
            self.grid.macropore_liquid_water_m3[index] +
            self.grid.matrix_ice_water_m3[index] +
            self.grid.macropore_ice_water_m3[index] +
            self.grid.water_vapor_volume_m3[index] };
    }
};

test "sub-floor nonzero layer redistribution conserves and moves water" {
    const allocator = std.testing.allocator;

    var geometry = try Geometry.State.init(allocator, 1, 3);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.1, 0.2, 0.3 }, 0, 1e-9);

    const cfg = try SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 3, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-6, .absolute_tolerance = 1e-6, .max_nonlinear_iterations = 10 },
    );
    var grid = try GridState.init(allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.05;
    grid.matrix_liquid_water_m3[1] = 0.10;
    grid.matrix_liquid_water_m3[2] = 0.15;
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 278;
    grid.soil_temperature_k[2] = 275;
    // active_soil_layer_count already set to 3 by GridState.init

    // Thermal state — use undefined + stack slices (no allocator needed).
    var thermal_lv = [_]f64{ 0.05, 0.10, 0.15 };
    var thermal_dry = [_]f64{ 1.0, 1.0, 1.0 };
    var thermal_total = [_]f64{ 2.0, 2.0, 2.0 };
    var thermal_porosity = [_]f64{ 0.4, 0.4, 0.4 };
    var thermal_thickness = [_]f64{ 0.1, 0.2, 0.3 };
    var thermal_state: thermal_module.State = undefined;
    thermal_state.layer_volume_m3 = &thermal_lv;
    thermal_state.layer_thickness_m = &thermal_thickness;
    thermal_state.dry_solid_heat_capacity_megajoules_per_m3_k = &thermal_dry;
    thermal_state.total_heat_capacity_megajoules_per_m3_k = &thermal_total;
    thermal_state.porosity_fraction = &thermal_porosity;

    const total_water_before = grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1] + grid.matrix_liquid_water_m3[2];

    // Simulate layer 0 expanding (bottom boundary pushes down 0.02 m):
    // DDLYRX > 0 at boundary between layer 0 and layer 1 → pull from layer 1.
    var ft_change = [_]f64{0} ** 4; // 1 cell × (3+1) boundaries
    ft_change[1] = 0.001; // nonzero movement below the 0.01 m geometry floor

    var zero_change = [_]f64{0} ** 4;
    const geometry_changes = Geometry.DisturbanceChanges{
        .pond_m = &zero_change,
        .freeze_thaw_m = &ft_change,
        .erosion_m = &zero_change,
        .organic_carbon_m = &zero_change,
    };

    var gas_state = try gas.State.init(allocator, 3);
    defer gas_state.deinit();
    var organic_state = try organic.State.init(allocator, 3);
    defer organic_state.deinit();
    var chem_state = try chemistry_module.State.init(allocator, 3);
    defer chem_state.deinit();
    var reactive_state = try reactive.State.init(allocator, 3, 1);
    defer reactive_state.deinit();
    var nfert_state = try nitrogen_fertilizer.State.init(allocator, 1, 3);
    defer nfert_state.deinit();
    var mfert_state = try mineral_fertilizer.State.init(allocator, 1, 3);
    defer mfert_state.deinit();
    var snapshot_context = TestWaterSnapshotContext{ .grid = &grid };
    var local_activity = try relayering_activity.Sidecar.init(
        allocator,
        1,
        3,
        .{
            .absolute = .{ .water_m3 = 32 * std.math.floatEps(f64) },
            .relative = 32 * std.math.floatEps(f64),
        },
    );
    defer local_activity.deinit();

    try applyLayerRedistribution(.{
        .grid = &grid,
        .soil_thermal = &thermal_state,
        .gas_transport = &gas_state,
        .soil_organic = &organic_state,
        .soil_chemistry = &chem_state,
        .reactive_nitrogen = &reactive_state,
        .soil_fertilizer_inventory = &nfert_state,
        .mineral_fertilizer_inventory = &mfert_state,
        .soil_properties = null,
        .plant_roots = null,
        .soil_geometry = &geometry,
        .soil_face_geometry = null,
        .soil_transport_faces = null,
        .water_heat_parameters = .{
            .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
            .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
            .minimum_heat_capacity_megajoules_per_k = 1e-6,
        },
        .salinity_enabled_by_cell = &.{false},
        .nutrient_zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
        .plant_populations = 0,
        .minimum_layer_thickness_m = 0.01,
        .horizontal_cell_width_m = &.{1},
        .vertical_cell_width_m = &.{1},
        .local_activity = .{
            .sidecar = &local_activity,
            .snapshot_source = .{
                .context = &snapshot_context,
                .capture_fn = TestWaterSnapshotContext.capture,
            },
        },
    }, geometry_changes);

    const total_water_after = grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1] + grid.matrix_liquid_water_m3[2];
    try std.testing.expectApproxEqAbs(total_water_before, total_water_after, 1e-14);
    // Layer 0 expanded (pulled from layer 1), so layer 1 loses water and layer 0 gains.
    try std.testing.expect(grid.matrix_liquid_water_m3[0] > 0.05);
    try std.testing.expect(grid.matrix_liquid_water_m3[1] < 0.10);
    const accepted = try local_activity.record(0, 0);
    try std.testing.expectEqual(relayering_activity.Direction.lower_to_upper, accepted.direction);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.10) - grid.matrix_liquid_water_m3[1],
        accepted.transfer.water_m3,
        32 * std.math.floatEps(f64),
    );

    // Without the EXEC-002 rebase the thermal volume no longer matches the
    // state_updateted geometry, which is exactly the drift the census sees.
    var worst_relative_mismatch: f64 = 0;
    for (0..3) |layer| {
        const geometry_volume_m3 = geometry.layer_thickness_m[layer] * 1.0;
        const scale = @max(@abs(geometry_volume_m3), @abs(thermal_state.layer_volume_m3[layer]));
        if (scale > 0)
            worst_relative_mismatch = @max(worst_relative_mismatch, @abs(thermal_state.layer_volume_m3[layer] - geometry_volume_m3) / scale);
    }
    try std.testing.expect(worst_relative_mismatch > 1e-6);
}

test "REDIST fraction saturates at DLYRM while content endpoints remain strict" {
    try std.testing.expectEqual(@as(f64, 1), redistributionFraction(1e-8, 1e-6, 1e-6));
    try std.testing.expectEqual(@as(f64, 1), redistributionFraction(1e-8, 0, 1e-6));
    try std.testing.expectEqual(@as(f64, 1), redistributionFraction(1e-8, 5e-7, 1e-6));
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), redistributionFraction(1e-3, 0.1, 1e-6), 1e-15);
}

test "EXEC-002 rebase aligns thermal volume with geometry and preserves census energy" {
    const allocator = std.testing.allocator;
    const config = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 3, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 },
    );
    var grid = try GridState.init(allocator, config);
    defer grid.deinit();

    var geometry = try Geometry.State.init(allocator, 1, 3);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.1, 0.2, 0.3 }, 0, 1e-9);

    var thermal_state: thermal_module.State = undefined;
    var thermal_volume = [_]f64{ 0.1, 0.2, 0.3 };
    var thermal_dry = [_]f64{ 1.0, 1.1, 1.2 };
    var thermal_total = [_]f64{ 2.0, 2.1, 2.2 };
    var thermal_porosity = [_]f64{ 0.4, 0.4, 0.4 };
    var thermal_thickness = [_]f64{ 0.1, 0.2, 0.3 };
    thermal_state.layer_volume_m3 = &thermal_volume;
    thermal_state.layer_thickness_m = &thermal_thickness;
    thermal_state.dry_solid_heat_capacity_megajoules_per_m3_k = &thermal_dry;
    thermal_state.total_heat_capacity_megajoules_per_m3_k = &thermal_total;
    thermal_state.porosity_fraction = &thermal_porosity;
    for (0..3) |layer| {
        grid.soil_temperature_k[layer] = 275 + @as(f64, @floatFromInt(layer));
        grid.matrix_pore_capacity_m3[layer] = 0.4 * thermal_volume[layer];
        grid.macropore_pore_capacity_m3[layer] = 0;
    }

    // Detach the top layer's volume from geometry the way the free surface does.
    // Only that layer is rebased, so the census energy of layer 0 must be
    // preserved while layers 1 and 2 are left untouched.
    thermal_volume[0] += 0.02;
    const untouched_volume_1 = thermal_volume[1];
    const untouched_volume_2 = thermal_volume[2];
    var census_energy_before: f64 = 0;
    for (0..3) |layer| census_energy_before += thermal_total[layer] * thermal_volume[layer] * grid.soil_temperature_k[layer];

    try rebaseThermalVolumeToGeometry(.{
        .grid = &grid,
        .soil_thermal = &thermal_state,
        .gas_transport = undefined,
        .soil_organic = undefined,
        .soil_chemistry = undefined,
        .reactive_nitrogen = undefined,
        .soil_fertilizer_inventory = undefined,
        .mineral_fertilizer_inventory = undefined,
        .soil_properties = null,
        .plant_roots = null,
        .soil_geometry = &geometry,
        .soil_face_geometry = null,
        .soil_transport_faces = null,
        .water_heat_parameters = .{
            .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
            .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
            .minimum_heat_capacity_megajoules_per_k = 1e-6,
        },
        .salinity_enabled_by_cell = &.{false},
        .nutrient_zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
        .plant_populations = 0,
        .minimum_layer_thickness_m = 1e-9,
        .horizontal_cell_width_m = &.{1},
        .vertical_cell_width_m = &.{1},
    }, 3);

    // The top layer is realigned with geometry.
    try std.testing.expectApproxEqRel(geometry.layer_thickness_m[0], thermal_volume[0], 1e-15);
    // Deeper layers already agree physically; rebuilding their geometry can
    // change the last bit (for example 0.2 -> 0.20000000000000004). Assert
    // scaled closure rather than a representation-identical decimal.
    inline for (.{
        .{ untouched_volume_1, thermal_volume[1] },
        .{ untouched_volume_2, thermal_volume[2] },
    }) |pair| {
        const scale = @max(@abs(pair[0]), @abs(pair[1]));
        try std.testing.expectApproxEqAbs(pair[0], pair[1], 16 * std.math.floatEps(f64) * scale);
    }
    var census_energy_after: f64 = 0;
    for (0..3) |layer| census_energy_after += thermal_total[layer] * thermal_volume[layer] * grid.soil_temperature_k[layer];
    try std.testing.expectApproxEqRel(census_energy_before, census_energy_after, 1e-12);
    // Porosity of the rebased layer is recomputed from live pore capacity.
    try std.testing.expectApproxEqRel(grid.matrix_pore_capacity_m3[0] / thermal_volume[0], thermal_porosity[0], 1e-12);
}

test "EXEC-002 rebase restores a zero-volume layer with retained macropore heat" {
    const allocator = std.testing.allocator;
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-8, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(allocator, config);
    defer grid.deinit();
    var geometry = try Geometry.State.init(allocator, 1, 1);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{0.1}, 0, 1e-9);
    var thermal_volume = [_]f64{0};
    var thermal_dry = [_]f64{0};
    var thermal_total = [_]f64{0};
    var thermal_porosity = [_]f64{0};
    var thermal_thickness = [_]f64{0.1};
    var thermal_state: thermal_module.State = undefined;
    thermal_state.layer_volume_m3 = &thermal_volume;
    thermal_state.layer_thickness_m = &thermal_thickness;
    thermal_state.dry_solid_heat_capacity_megajoules_per_m3_k = &thermal_dry;
    thermal_state.total_heat_capacity_megajoules_per_m3_k = &thermal_total;
    thermal_state.porosity_fraction = &thermal_porosity;
    grid.macropore_liquid_water_m3[0] = 0.02;
    grid.macropore_ice_water_m3[0] = 0.01;
    grid.macropore_pore_capacity_m3[0] = 0.04;
    grid.soil_temperature_k[0] = 275;
    const expected_capacity = 4.19 * 0.02 + 1.9274 * 0.01;

    try rebaseThermalVolumeToGeometry(.{
        .grid = &grid,
        .soil_thermal = &thermal_state,
        .gas_transport = undefined,
        .soil_organic = undefined,
        .soil_chemistry = undefined,
        .reactive_nitrogen = undefined,
        .soil_fertilizer_inventory = undefined,
        .mineral_fertilizer_inventory = undefined,
        .soil_properties = null,
        .plant_roots = null,
        .soil_geometry = &geometry,
        .soil_face_geometry = null,
        .soil_transport_faces = null,
        .water_heat_parameters = .{ .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 1e-8 },
        .salinity_enabled_by_cell = &.{false},
        .nutrient_zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
        .plant_populations = 0,
        .minimum_layer_thickness_m = 1e-9,
        .horizontal_cell_width_m = &.{1},
        .vertical_cell_width_m = &.{1},
    }, 1);

    try std.testing.expectApproxEqAbs(@as(f64, 0.1), thermal_volume[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected_capacity, thermal_total[0] * thermal_volume[0], 1e-14);
    try std.testing.expectApproxEqAbs(expected_capacity * 275, thermal_total[0] * thermal_volume[0] * grid.soil_temperature_k[0], 1e-12);
}

test "DISC-WATSUB-002 relayering refills a recipient emptied earlier in the same hour" {
    // Measured on `Arctic Fen CH` cell 0, hour 1: boundary `layer=0` transferred
    // ALL of layer 1 into layer 0 at `fx=1.0`, and boundary `layer=1` then chose
    // that emptied layer 1 as its DESTINATION. The geometry thickness still read
    // a healthy `2e-2` because the geometry state_update is deferred to after the loop,
    // while the live `soil_thermal.layer_volume_m3` was already `0` and the layer
    // temperature had become a meaningless `9.2e2 K`.
    //
    // `redist.f:8468`/`:8498` gate only on donor `DLYR(3,L0)`. This test pins
    // source order: a live donor must refill the zero-volume recipient rather
    // than silently skipping every coupled pool transfer.
    const allocator = std.testing.allocator;

    var geometry = try Geometry.State.init(allocator, 1, 3);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.02, 0.025, 0.3 }, 0, 1e-9);

    const cfg = try SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 3, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-6, .absolute_tolerance = 1e-6, .max_nonlinear_iterations = 10 },
    );
    var grid = try GridState.init(allocator, cfg);
    defer grid.deinit();

    var thermal_lv = [_]f64{ 1.0, 0.0, 1.5 }; // layer 1 already emptied
    var thermal_dry = [_]f64{ 1.0, 0.0, 1.0 };
    var thermal_total = [_]f64{ 2.0, 0.0, 2.0 };
    var thermal_porosity = [_]f64{ 0.4, 0.0, 0.4 };
    var thermal_thickness = [_]f64{ 0.02, 0.025, 0.3 };
    var thermal_state: thermal_module.State = undefined;
    thermal_state.layer_volume_m3 = &thermal_lv;
    thermal_state.layer_thickness_m = &thermal_thickness;
    thermal_state.dry_solid_heat_capacity_megajoules_per_m3_k = &thermal_dry;
    thermal_state.total_heat_capacity_megajoules_per_m3_k = &thermal_total;
    thermal_state.porosity_fraction = &thermal_porosity;

    grid.matrix_liquid_water_m3[0] = 0.05;
    grid.matrix_liquid_water_m3[1] = 0; // emptied
    grid.matrix_liquid_water_m3[2] = 0.15;
    grid.soil_temperature_k[0] = 275;
    // The stale temperature is irrelevant because the recipient has no heat
    // capacity; its accepted temperature comes entirely from incoming material.
    grid.soil_temperature_k[1] = 920.1111879438225;
    grid.soil_temperature_k[2] = 270;

    // A boundary change at the layer1/layer2 face, which would select the emptied
    // layer 1 as one endpoint.
    var ft_change = [_]f64{0} ** 4;
    ft_change[2] = 0.01;
    var zero_change = [_]f64{0} ** 4;

    var gas_state = try gas.State.init(allocator, 3);
    defer gas_state.deinit();
    var organic_state = try organic.State.init(allocator, 3);
    defer organic_state.deinit();
    var chem_state = try chemistry_module.State.init(allocator, 3);
    defer chem_state.deinit();
    var reactive_state = try reactive.State.init(allocator, 3, 1);
    defer reactive_state.deinit();
    var nfert_state = try nitrogen_fertilizer.State.init(allocator, 1, 3);
    defer nfert_state.deinit();
    var mfert_state = try mineral_fertilizer.State.init(allocator, 1, 3);
    defer mfert_state.deinit();

    const water_before = grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1] + grid.matrix_liquid_water_m3[2];

    try applyLayerRedistribution(.{
        .grid = &grid,
        .soil_thermal = &thermal_state,
        .gas_transport = &gas_state,
        .soil_organic = &organic_state,
        .soil_chemistry = &chem_state,
        .reactive_nitrogen = &reactive_state,
        .soil_fertilizer_inventory = &nfert_state,
        .mineral_fertilizer_inventory = &mfert_state,
        .soil_properties = null,
        .plant_roots = null,
        .soil_geometry = &geometry,
        .soil_face_geometry = null,
        .soil_transport_faces = null,
        .water_heat_parameters = .{
            .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
            .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
            .minimum_heat_capacity_megajoules_per_k = 1e-6,
        },
        .salinity_enabled_by_cell = &.{false},
        .nutrient_zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
        .plant_populations = 0,
        .minimum_layer_thickness_m = 1e-9,
        .horizontal_cell_width_m = &.{1},
        .vertical_cell_width_m = &.{1},
    }, .{
        .pond_m = &zero_change,
        .freeze_thaw_m = &ft_change,
        .erosion_m = &zero_change,
        .organic_carbon_m = &zero_change,
    });

    const water_after = grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1] + grid.matrix_liquid_water_m3[2];
    try std.testing.expectApproxEqAbs(water_before, water_after, 1e-14);
    try std.testing.expect(grid.matrix_liquid_water_m3[1] > 0);
    try std.testing.expect(thermal_state.layer_volume_m3[1] > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 270), grid.soil_temperature_k[1], 1e-12);
}

test "DISC-WATSUB-002 zero-matrix donor still transfers FHOL macropore owners" {
    const allocator = std.testing.allocator;
    var geometry = try Geometry.State.init(allocator, 1, 3);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.02, 0.025, 0.3 }, 0, 1e-9);
    const cfg = try SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 3, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-6, .absolute_tolerance = 1e-6, .max_nonlinear_iterations = 10 });
    var grid = try GridState.init(allocator, cfg);
    defer grid.deinit();
    var thermal_lv = [_]f64{ 1, 0, 1.5 };
    var thermal_dry = [_]f64{ 1, 0, 1 };
    var thermal_total = [_]f64{ 2, 0, 2 };
    var thermal_porosity = [_]f64{ 0.4, 0, 0.4 };
    var thermal_thickness = [_]f64{ 0.02, 0.025, 0.3 };
    var thermal_state: thermal_module.State = undefined;
    thermal_state.layer_volume_m3 = &thermal_lv;
    thermal_state.layer_thickness_m = &thermal_thickness;
    thermal_state.dry_solid_heat_capacity_megajoules_per_m3_k = &thermal_dry;
    thermal_state.total_heat_capacity_megajoules_per_m3_k = &thermal_total;
    thermal_state.porosity_fraction = &thermal_porosity;
    grid.soil_temperature_k[0] = 275;
    grid.soil_temperature_k[1] = 270;
    grid.soil_temperature_k[2] = 265;
    grid.macropore_liquid_water_m3[1] = 0.12;
    grid.macropore_ice_water_m3[1] = 0.03;
    grid.macropore_pore_capacity_m3[1] = 0.2;
    grid.macropore_air_volume_m3[1] = 0.05;
    grid.macropore_liquid_water_m3[2] = 0.02;
    grid.macropore_ice_water_m3[2] = 0.01;
    grid.macropore_pore_capacity_m3[2] = 0.1;
    grid.macropore_air_volume_m3[2] = 0.02;

    var gas_state = try gas.State.init(allocator, 3);
    defer gas_state.deinit();
    gas_state.macropore_dissolved_mass_g[gas.species_count] = 4;
    var organic_state = try organic.State.init(allocator, 3);
    defer organic_state.deinit();
    var chem_state = try chemistry_module.State.init(allocator, 3);
    defer chem_state.deinit();
    var reactive_state = try reactive.State.init(allocator, 3, 1);
    defer reactive_state.deinit();
    var nfert_state = try nitrogen_fertilizer.State.init(allocator, 1, 3);
    defer nfert_state.deinit();
    var mfert_state = try mineral_fertilizer.State.init(allocator, 1, 3);
    defer mfert_state.deinit();

    var boundary_change = [_]f64{0} ** 4;
    boundary_change[2] = -0.01;
    var zero = [_]f64{0} ** 4;
    const macro_water_before = grid.macropore_liquid_water_m3[1] + grid.macropore_liquid_water_m3[2];
    const macro_ice_before = grid.macropore_ice_water_m3[1] + grid.macropore_ice_water_m3[2];
    try applyLayerRedistribution(.{
        .grid = &grid,
        .soil_thermal = &thermal_state,
        .gas_transport = &gas_state,
        .soil_organic = &organic_state,
        .soil_chemistry = &chem_state,
        .reactive_nitrogen = &reactive_state,
        .soil_fertilizer_inventory = &nfert_state,
        .mineral_fertilizer_inventory = &mfert_state,
        .soil_properties = null,
        .plant_roots = null,
        .soil_geometry = &geometry,
        .soil_face_geometry = null,
        .soil_transport_faces = null,
        .water_heat_parameters = .{ .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 1e-8 },
        .salinity_enabled_by_cell = &.{false},
        .nutrient_zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
        .plant_populations = 0,
        .minimum_layer_thickness_m = 1e-9,
        .horizontal_cell_width_m = &.{1},
        .vertical_cell_width_m = &.{1},
        .rebase_thermal_volume_to_geometry = true,
    }, .{ .pond_m = &zero, .freeze_thaw_m = &boundary_change, .erosion_m = &zero, .organic_carbon_m = &zero });

    try std.testing.expect(grid.macropore_liquid_water_m3[1] < 0.12);
    try std.testing.expectApproxEqAbs(macro_water_before, grid.macropore_liquid_water_m3[1] + grid.macropore_liquid_water_m3[2], 1e-14);
    try std.testing.expectApproxEqAbs(macro_ice_before, grid.macropore_ice_water_m3[1] + grid.macropore_ice_water_m3[2], 1e-14);
    try std.testing.expect(gas_state.macropore_dissolved_mass_g[gas.species_count] < 4);
    try std.testing.expectApproxEqAbs(@as(f64, 4), gas_state.macropore_dissolved_mass_g[gas.species_count] + gas_state.macropore_dissolved_mass_g[2 * gas.species_count], 1e-14);
    try std.testing.expect(thermal_state.layer_volume_m3[1] > 0);
}

test "REDIST pore transport owners follow matrix FX and macropore FHO without mass loss" {
    var micropore = try solute_transport.State.init(std.testing.allocator, 2, solute_transport_species.AqueousSpecies.count);
    defer micropore.deinit();
    var macropore = try solute_transport.State.init(std.testing.allocator, 2, 2);
    defer macropore.deinit();
    var mineral_nitrogen = try mineral_nitrogen_transport_module.State.init(std.testing.allocator, 2);
    defer mineral_nitrogen.deinit();
    var organic_transport = try organic_transport_module.State.init(std.testing.allocator, 2);
    defer organic_transport.deinit();
    const owners: TransportOwners = .{
        .micropore_solute = &micropore,
        .macropore_solute = &macropore,
        .mineral_nitrogen = &mineral_nitrogen,
        .organic = &organic_transport,
    };
    micropore.amount_mol[0] = 8;
    macropore.amount_mol[0] = 12;
    mineral_nitrogen.matrix.amount_mol[0] = 16;
    mineral_nitrogen.matrix.amount_mol[@intFromEnum(mineral_nitrogen_transport_module.Species.ammonium_band)] = 8;
    mineral_nitrogen.macropore.amount_mol[0] = 20;
    organic_transport.micropore_amount_g[0] = 24;
    organic_transport.macropore_amount_g[0] = 28;
    const matrix_water = [_]f64{ 0.6, 0.4 };
    const macropore_water = [_]f64{ 0.15, 0.25 };

    const destination_fractions: NutrientZoneFractions = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 };
    try validateTransportOwnerLayerFractions(owners, 2, 0, 1, 0.25, 0.5, 0.25, 0.5, destination_fractions);
    transferTransportOwnerLayerFractions(owners, 0, 1, 0.25, 0.5, 0.25, 0.5, &matrix_water, &macropore_water, destination_fractions);

    try std.testing.expectEqual(@as(f64, 6), micropore.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 2), micropore.amount_mol[solute_transport_species.AqueousSpecies.count]);
    try std.testing.expectEqual(@as(f64, 6), macropore.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 6), macropore.amount_mol[2]);
    try std.testing.expectEqual(@as(f64, 12), mineral_nitrogen.matrix.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 4), mineral_nitrogen.matrix.amount_mol[mineral_nitrogen_transport_module.species_count]);
    try std.testing.expectEqual(@as(f64, 6), mineral_nitrogen.matrix.amount_mol[@intFromEnum(mineral_nitrogen_transport_module.Species.ammonium_band)]);
    try std.testing.expectEqual(@as(f64, 2), mineral_nitrogen.matrix.amount_mol[mineral_nitrogen_transport_module.species_count + @intFromEnum(mineral_nitrogen_transport_module.Species.ammonium_band)]);
    try std.testing.expectEqual(@as(f64, 10), mineral_nitrogen.macropore.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 10), mineral_nitrogen.macropore.amount_mol[mineral_nitrogen_transport_module.species_count]);
    try std.testing.expectEqual(@as(f64, 18), organic_transport.micropore_amount_g[0]);
    try std.testing.expectEqual(@as(f64, 6), organic_transport.micropore_amount_g[organic_transport_module.component_count]);
    try std.testing.expectEqual(@as(f64, 14), organic_transport.macropore_amount_g[0]);
    try std.testing.expectEqual(@as(f64, 14), organic_transport.macropore_amount_g[organic_transport_module.component_count]);
    try std.testing.expectEqualSlices(f64, &matrix_water, micropore.water_volume_m3);
    try std.testing.expectEqualSlices(f64, &macropore_water, macropore.water_volume_m3);
    try std.testing.expectEqualSlices(f64, &matrix_water, mineral_nitrogen.matrix.water_volume_m3);
    try std.testing.expectEqualSlices(f64, &macropore_water, mineral_nitrogen.macropore.water_volume_m3);
}

test "REDIST micropore transport retains every phosphate species for an absent recipient band" {
    var state = try solute_transport.State.init(
        std.testing.allocator,
        2,
        solute_transport_species.AqueousSpecies.count,
    );
    defer state.deinit();
    inline for (std.enums.values(solute_transport_species.AqueousSpecies)) |species| {
        const component = @intFromEnum(species);
        if (microporeSoluteTransferFraction(species, 0.25, .{
            .ammonium_non_band = 1,
            .ammonium_band = 0,
            .nitrate_non_band = 1,
            .nitrate_band = 0,
            .phosphate_non_band = 1,
            .phosphate_band = 0,
        }) == 0) state.amount_mol[component] = 1 + @as(f64, @floatFromInt(component));
    }
    state.amount_mol[@intFromEnum(solute_transport_species.AqueousSpecies.non_band_phosphate)] = 8;
    const water = [_]f64{ 0.5, 0.5 };
    const destination_fractions: NutrientZoneFractions = .{
        .ammonium_non_band = 1,
        .ammonium_band = 0,
        .nitrate_non_band = 1,
        .nitrate_band = 0,
        .phosphate_non_band = 1,
        .phosphate_band = 0,
    };
    try validateMicroporeSoluteLayerFraction(&state, 0, 1, 0.25, destination_fractions);
    transferMicroporeSoluteLayerFraction(&state, 0, 1, 0.25, &water, destination_fractions);
    inline for (std.enums.values(solute_transport_species.AqueousSpecies)) |species| {
        const component = @intFromEnum(species);
        if (microporeSoluteTransferFraction(species, 0.25, destination_fractions) == 0) {
            try std.testing.expectEqual(@as(f64, 1) + @as(f64, @floatFromInt(component)), state.amount_mol[component]);
            try std.testing.expectEqual(@as(f64, 0), state.amount_mol[state.species_count + component]);
        }
    }
    const non_band = @intFromEnum(solute_transport_species.AqueousSpecies.non_band_phosphate);
    try std.testing.expectEqual(@as(f64, 6), state.amount_mol[non_band]);
    try std.testing.expectEqual(@as(f64, 2), state.amount_mol[state.species_count + non_band]);
}

test "REDIST mineral nitrogen mirror does not enter an absent recipient band" {
    var state = try mineral_nitrogen_transport_module.State.init(std.testing.allocator, 2);
    defer state.deinit();
    const band = @intFromEnum(mineral_nitrogen_transport_module.Species.ammonium_band);
    state.matrix.amount_mol[band] = 8;
    const water = [_]f64{ 0.5, 0.5 };
    const destination_fractions: NutrientZoneFractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 };
    try validateMineralNitrogenLayerFraction(&state.matrix, 0, 1, 0.25, destination_fractions);
    transferMineralNitrogenLayerFraction(&state.matrix, 0, 1, 0.25, &water, destination_fractions);
    try std.testing.expectEqual(@as(f64, 8), state.matrix.amount_mol[band]);
    try std.testing.expectEqual(@as(f64, 0), state.matrix.amount_mol[mineral_nitrogen_transport_module.species_count + band]);
}

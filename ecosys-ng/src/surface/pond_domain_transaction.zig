const std = @import("std");
const inventory = @import("pond_inventory_transfer.zig");
const chemistry = @import("pond_chemistry_transfer.zig");
const surface_chemistry_module = @import("litter_chemistry.zig");
const soil_chemistry_module = @import("../soil/solute/chemistry_state.zig");
const water_heat = @import("pond_water_heat_transfer.zig");
const geometry = @import("../soil/profile/layer_geometry.zig");
const transition_module = @import("pond_transition_step.zig");
const soil_properties_module = @import("../soil/water/solver_properties.zig");
const face_geometry_module = @import("../soil/water/face_geometry.zig");
const transport_module = @import("../transport/hydrology.zig");
const solute_transport_module = @import("../soil/solute/transport.zig");
const aqueous_species_module = @import("../soil/solute/transport_species.zig");
const aqueous_bridge = @import("../soil/solute/aqueous_transport_bridge.zig");
const conservation_sidecar = @import("pond_conservation_sidecar.zig");

const pond_base_changed_species = [_]aqueous_species_module.AqueousSpecies{
    .hydrogen,
    .hydroxide,
    .aluminum,
    .iron,
    .calcium,
    .magnesium,
    .sodium,
    .potassium,
    .non_band_hpo4,
    .non_band_h2po4,
};
const pond_optional_salt_changed_species = [_]aqueous_species_module.AqueousSpecies{
    .chloride,
    .sulfate,
};
const pond_carbonate_changed_species = [_]aqueous_species_module.AqueousSpecies{
    .carbonate,
    .bicarbonate,
};

/// Heap-owned scratch storage for one atomic, whole-grid surface-pond
/// transaction. A complete preflight precedes every mutation.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    pond_boundary_change_m: []f64,
    zero_boundary_change_m: []f64,
    /// Accepted REDIST L=0 particulate surface->soil provenance.
    particulate_active: []bool,
    particulate_destination_soil_layer: []usize,
    particulate_transfer: []conservation_sidecar.Transfer,
    particulate_soil_active_by_source: []bool,
    particulate_soil_destination_layer_by_source: []usize,
    particulate_soil_transfer_by_source: []conservation_sidecar.Transfer,
    /// Accepted full pond-domain surface->soil provenance.
    domain_active: []bool,
    domain_destination_soil_layer: []usize,
    domain_transfer: []conservation_sidecar.Transfer,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_capacity: usize) !Workspace {
        const count = try std.math.mul(usize, cell_count, try std.math.add(usize, layer_capacity, 1));
        const pond = try allocator.alloc(f64, count);
        errdefer allocator.free(pond);
        const zero = try allocator.alloc(f64, count);
        errdefer allocator.free(zero);
        const particulate_active = try allocator.alloc(bool, cell_count);
        errdefer allocator.free(particulate_active);
        const particulate_destination = try allocator.alloc(usize, cell_count);
        errdefer allocator.free(particulate_destination);
        const particulate_transfer = try allocator.alloc(conservation_sidecar.Transfer, cell_count);
        errdefer allocator.free(particulate_transfer);
        const soil_count = try std.math.mul(usize, cell_count, layer_capacity);
        const particulate_soil_active = try allocator.alloc(bool, soil_count);
        errdefer allocator.free(particulate_soil_active);
        const particulate_soil_destination = try allocator.alloc(usize, soil_count);
        errdefer allocator.free(particulate_soil_destination);
        const particulate_soil_transfer = try allocator.alloc(conservation_sidecar.Transfer, soil_count);
        errdefer allocator.free(particulate_soil_transfer);
        const domain_active = try allocator.alloc(bool, cell_count);
        errdefer allocator.free(domain_active);
        const domain_destination = try allocator.alloc(usize, cell_count);
        errdefer allocator.free(domain_destination);
        const domain_transfer = try allocator.alloc(conservation_sidecar.Transfer, cell_count);
        @memset(pond, 0);
        @memset(zero, 0);
        @memset(particulate_active, false);
        @memset(particulate_destination, 0);
        @memset(particulate_transfer, .{});
        @memset(particulate_soil_active, false);
        @memset(particulate_soil_destination, 0);
        @memset(particulate_soil_transfer, .{});
        @memset(domain_active, false);
        @memset(domain_destination, 0);
        @memset(domain_transfer, .{});
        return .{
            .allocator = allocator,
            .pond_boundary_change_m = pond,
            .zero_boundary_change_m = zero,
            .particulate_active = particulate_active,
            .particulate_destination_soil_layer = particulate_destination,
            .particulate_transfer = particulate_transfer,
            .particulate_soil_active_by_source = particulate_soil_active,
            .particulate_soil_destination_layer_by_source = particulate_soil_destination,
            .particulate_soil_transfer_by_source = particulate_soil_transfer,
            .domain_active = domain_active,
            .domain_destination_soil_layer = domain_destination,
            .domain_transfer = domain_transfer,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.domain_transfer);
        self.allocator.free(self.domain_destination_soil_layer);
        self.allocator.free(self.domain_active);
        self.allocator.free(self.particulate_transfer);
        self.allocator.free(self.particulate_soil_transfer_by_source);
        self.allocator.free(self.particulate_soil_destination_layer_by_source);
        self.allocator.free(self.particulate_soil_active_by_source);
        self.allocator.free(self.particulate_destination_soil_layer);
        self.allocator.free(self.particulate_active);
        self.allocator.free(self.zero_boundary_change_m);
        self.allocator.free(self.pond_boundary_change_m);
        self.* = undefined;
    }

    pub fn particulateSidecar(self: *Workspace) conservation_sidecar.CellSidecar {
        return .{
            .active = self.particulate_active,
            .destination_soil_layer = self.particulate_destination_soil_layer,
            .transfer = self.particulate_transfer,
        };
    }

    pub fn domainSidecar(self: *Workspace) conservation_sidecar.CellSidecar {
        return .{
            .active = self.domain_active,
            .destination_soil_layer = self.domain_destination_soil_layer,
            .transfer = self.domain_transfer,
        };
    }

    pub fn particulateSoilLayerSidecar(self: *Workspace) conservation_sidecar.SoilLayerSidecar {
        return .{
            .active_by_source = self.particulate_soil_active_by_source,
            .destination_soil_layer_by_source = self.particulate_soil_destination_layer_by_source,
            .transfer_by_source = self.particulate_soil_transfer_by_source,
        };
    }
};

pub const Owners = struct {
    inventories: inventory.Owners,
    surface_chemistry: *surface_chemistry_module.State,
    soil_chemistry: *soil_chemistry_module.State,
    /// Authoritative extensive owner for mobile matrix solutes. Soil
    /// chemistry is its concentration mirror between reaction solves.
    micropore_solutes: *solute_transport_module.State,
    water_heat: water_heat.Owners,
    soil_geometry: *geometry.State,
    soil_properties: *soil_properties_module.State,
    soil_faces: *const transport_module.SoilFaces,
    soil_face_geometry: *face_geometry_module.State,
};

pub const Inputs = struct {
    transitions: *const transition_module.State,
    salinity_enabled_by_cell: []const bool,
    water_heat_parameters: water_heat.Parameters,
    minimum_heat_capacity_megajoules_per_k: []const f64,
    minimum_soil_layer_thickness_m: f64,
    horizontal_cell_width_m: []const f64,
    vertical_cell_width_m: []const f64,
    ammonium_non_band_water_fraction_by_cell: []const f64,
    nitrate_non_band_water_fraction_by_cell: []const f64,
    phosphate_non_band_water_fraction_by_cell: []const f64,
    phosphate_band_water_fraction_by_cell: []const f64,
    water_molar_mass_g_per_mol: f64 = 18.01528,
    liquid_water_density_g_per_m3: f64 = 1.0e6,
};

pub fn apply(workspace: *Workspace, owners: Owners, inputs: Inputs) !void {
    const grid = owners.water_heat.grid;
    const boundary_count = grid.cell_count * (grid.soil_layer_capacity + 1);
    if (inputs.transitions.cell_count != grid.cell_count or
        owners.soil_geometry.cell_count != grid.cell_count or
        owners.soil_geometry.layer_capacity != grid.soil_layer_capacity or
        workspace.pond_boundary_change_m.len != boundary_count or
        workspace.zero_boundary_change_m.len != boundary_count or
        owners.soil_properties.layer_count != grid.layer_count or
        owners.soil_properties.layer_thickness_m.len != grid.layer_count or
        owners.soil_properties.layer_midpoint_depth_m.len != grid.layer_count or
        owners.soil_properties.layer_bottom_depth_m.len != grid.layer_count or
        owners.micropore_solutes.cell_count != grid.layer_count or
        owners.micropore_solutes.species_count != aqueous_species_module.AqueousSpecies.count or
        inputs.salinity_enabled_by_cell.len != grid.cell_count or
        inputs.minimum_heat_capacity_megajoules_per_k.len != grid.cell_count or
        inputs.ammonium_non_band_water_fraction_by_cell.len != grid.cell_count or
        inputs.nitrate_non_band_water_fraction_by_cell.len != grid.cell_count or
        inputs.phosphate_non_band_water_fraction_by_cell.len != grid.cell_count or
        inputs.phosphate_band_water_fraction_by_cell.len != grid.cell_count or
        inputs.horizontal_cell_width_m.len != grid.cell_count or
        inputs.vertical_cell_width_m.len != grid.cell_count or
        !std.math.isFinite(inputs.water_molar_mass_g_per_mol) or
        inputs.water_molar_mass_g_per_mol <= 0 or
        !std.math.isFinite(inputs.liquid_water_density_g_per_m3) or
        inputs.liquid_water_density_g_per_m3 <= 0)
        return error.SurfacePondDomainDimensionMismatch;
    for (0..grid.cell_count) |cell| {
        inline for (.{
            inputs.ammonium_non_band_water_fraction_by_cell[cell],
            inputs.nitrate_non_band_water_fraction_by_cell[cell],
        }) |zone_fraction|
            if (!std.math.isFinite(zone_fraction) or zone_fraction <= 0 or zone_fraction > 1)
                return error.InvalidSurfacePondMineralNitrogenZoneFraction;
        inline for (.{
            inputs.phosphate_non_band_water_fraction_by_cell[cell],
            inputs.phosphate_band_water_fraction_by_cell[cell],
        }) |zone_fraction|
            if (!std.math.isFinite(zone_fraction) or zone_fraction < 0 or zone_fraction > 1)
                return error.InvalidSurfacePondPhosphateZoneFraction;
        const phosphate_fraction_sum = inputs.phosphate_non_band_water_fraction_by_cell[cell] +
            inputs.phosphate_band_water_fraction_by_cell[cell];
        if (@abs(phosphate_fraction_sum - 1) > 32 * std.math.floatEps(f64) * @max(1.0, @abs(phosphate_fraction_sum)))
            return error.InvalidSurfacePondPhosphateZoneFraction;
    }
    try owners.micropore_solutes.validateFinite();

    @memset(workspace.pond_boundary_change_m, 0);
    @memset(workspace.zero_boundary_change_m, 0);

    // Domain-wide validation guarantees that a late invalid cell cannot leave
    // earlier cells partially transferred.
    for (0..grid.cell_count) |cell| {
        if (!inputs.transitions.active[cell]) continue;
        const layer = inputs.transitions.destination_soil_layer[cell];
        const fraction = inputs.transitions.transfer_fraction[cell];
        const destination = cell * grid.soil_layer_capacity + layer;
        const carriers = try carrierVolumes(owners, cell, destination, fraction, inputs.water_heat_parameters.ice_density_megagrams_per_m3, inputs.ammonium_non_band_water_fraction_by_cell[cell], inputs.nitrate_non_band_water_fraction_by_cell[cell], inputs.phosphate_non_band_water_fraction_by_cell[cell], inputs.horizontal_cell_width_m[cell] * inputs.vertical_cell_width_m[cell]);
        // HEAT-001: the state_update pass now reads the pre-move carbon, so the
        // preflight must validate against that same operand.
        const organic_carbon_g_c = try owners.inventories.surface_organic.totalCarbon_g_c(cell);
        const surface_vapor_water_equivalent_m3 = try vaporWaterEquivalentAndValidateMirror(
            owners,
            cell,
            destination,
            inputs.water_molar_mass_g_per_mol,
            inputs.liquid_water_density_g_per_m3,
        );
        var heat_parameters = inputs.water_heat_parameters;
        heat_parameters.minimum_heat_capacity_megajoules_per_k = inputs.minimum_heat_capacity_megajoules_per_k[cell];
        try inventory.validateSurfaceFractionToSoil(owners.inventories, .{ .cell = cell, .destination_soil_layer = layer, .fraction = fraction });
        try chemistry.validateSurfaceFractionToSoil(owners.surface_chemistry, owners.soil_chemistry, cell, destination, carriers, inputs.salinity_enabled_by_cell[cell], fraction);
        try water_heat.validateSurfaceFractionToSoil(owners.water_heat, .{ .cell = cell, .destination_soil_layer = layer, .fraction = fraction, .surface_organic_carbon_g_c = organic_carbon_g_c, .surface_vapor_water_equivalent_m3 = surface_vapor_water_equivalent_m3, .parameters = heat_parameters });
        const boundary = cell * (grid.soil_layer_capacity + 1) + layer;
        const change = inputs.transitions.boundary_change_m[cell];
        if (!std.math.isFinite(change)) return error.InvalidSurfacePondBoundaryChange;
        workspace.pond_boundary_change_m[boundary] += change;
    }

    const changes = geometry.DisturbanceChanges{
        .pond_m = workspace.pond_boundary_change_m,
        .freeze_thaw_m = workspace.zero_boundary_change_m,
        .erosion_m = workspace.zero_boundary_change_m,
        .organic_carbon_m = workspace.zero_boundary_change_m,
    };
    try geometry.validateDisturbances(owners.soil_geometry, changes, inputs.minimum_soil_layer_thickness_m);
    try owners.soil_face_geometry.validateMapped(grid, owners.soil_faces, owners.soil_geometry.layer_thickness_m, inputs.horizontal_cell_width_m, inputs.vertical_cell_width_m);

    // Sidecar publication begins only after the complete domain, geometry and
    // face preflight. A rejected transaction therefore retains the previously
    // accepted hour's provenance unchanged.
    workspace.domainSidecar().clear();
    for (0..grid.cell_count) |cell| {
        if (!inputs.transitions.active[cell]) continue;
        const layer = inputs.transitions.destination_soil_layer[cell];
        const fraction = inputs.transitions.transfer_fraction[cell];
        const destination = cell * grid.soil_layer_capacity + layer;
        const carriers = carrierVolumes(owners, cell, destination, fraction, inputs.water_heat_parameters.ice_density_megagrams_per_m3, inputs.ammonium_non_band_water_fraction_by_cell[cell], inputs.nitrate_non_band_water_fraction_by_cell[cell], inputs.phosphate_non_band_water_fraction_by_cell[cell], inputs.horizontal_cell_width_m[cell] * inputs.vertical_cell_width_m[cell]) catch unreachable;
        var heat_parameters = inputs.water_heat_parameters;
        heat_parameters.minimum_heat_capacity_megajoules_per_k = inputs.minimum_heat_capacity_megajoules_per_k[cell];
        const moved_surface_volume_m3 = fraction * owners.water_heat.surface_geometry.dry_litter_volume_m3[cell];
        // HEAT-001: read the surface organic carbon *before* the inventory
        // transfer removes `fraction` of it. `water_heat` scales the capacity it
        // is handed by `fraction` (moved) and `1 - fraction` (retained), so the
        // operand must be the pre-move carbon for both halves to match the EXEC
        // census.
        //
        // With the pre-move carbon `C`, the kernel moves `f * c * C` into the
        // destination's published dry capacity and retains `(1-f) * c * C` at
        // the surface. The census, which derives surface capacity from the live
        // organic pools, reads exactly `c * (1-f) * C` after the transfer, so
        // both halves agree.
        //
        // Passing the post-move carbon `(1-f) * C` instead moved only
        // `f * (1-f) * c * C` while the census still removed `f * c * C` from
        // the surface, leaving `f^2 * c * C * T` of sensible heat unaccounted
        // for every hour a pond transition was active. The prior comment here
        // claimed the pre-move read double counted and was worth `+4.923e7 MJ`;
        // that figure is retired. The `+4.9e7` term was the stale destination
        // heat capacity documented in
        // `docs/traceability/surface_pond_transaction_stale_capacity_defect.md`,
        // which this transaction read from `soil_thermal`'s cached table while
        // publishing its result from the live carriers.
        const organic_carbon_g_c = owners.inventories.surface_organic.totalCarbon_g_c(cell) catch unreachable;
        const surface_vapor_water_equivalent_m3 = vaporWaterEquivalentAndValidateMirror(
            owners,
            cell,
            destination,
            inputs.water_molar_mass_g_per_mol,
            inputs.liquid_water_density_g_per_m3,
        ) catch unreachable;
        var accepted = inventory.acceptedSurfaceTransfer(owners.inventories, .{
            .cell = cell,
            .destination_soil_layer = layer,
            .fraction = fraction,
        }) catch unreachable;
        accepted = accepted.add(chemistry.acceptedSurfaceTransfer(
            owners.surface_chemistry,
            owners.soil_chemistry,
            cell,
            destination,
            carriers,
            inputs.salinity_enabled_by_cell[cell],
            fraction,
        ) catch unreachable) catch unreachable;
        accepted = accepted.add(water_heat.acceptedTransfer(owners.water_heat, .{
            .cell = cell,
            .destination_soil_layer = layer,
            .fraction = fraction,
            .surface_organic_carbon_g_c = organic_carbon_g_c,
            .surface_vapor_water_equivalent_m3 = surface_vapor_water_equivalent_m3,
            .parameters = heat_parameters,
        }) catch unreachable) catch unreachable;
        inventory.transferSurfaceFractionToSoil(owners.inventories, .{ .cell = cell, .destination_soil_layer = layer, .fraction = fraction }) catch unreachable;
        chemistry.transferSurfaceFractionToSoil(owners.surface_chemistry, owners.soil_chemistry, cell, destination, carriers, inputs.salinity_enabled_by_cell[cell], fraction) catch unreachable;
        water_heat.transferSurfaceFractionToSoil(owners.water_heat, .{ .cell = cell, .destination_soil_layer = layer, .fraction = fraction, .surface_organic_carbon_g_c = organic_carbon_g_c, .surface_vapor_water_equivalent_m3 = surface_vapor_water_equivalent_m3, .parameters = heat_parameters }) catch unreachable;
        // Soil gas vapor is a pressure-solver mirror; canonical storage is the
        // grid water-equivalent owner just committed by `water_heat`.
        owners.inventories.soil_gas.water_vapor_mol[destination] =
            owners.water_heat.grid.water_vapor_volume_m3[destination] *
            inputs.liquid_water_density_g_per_m3 /
            inputs.water_molar_mass_g_per_mol;
        owners.soil_properties.matrix_bulk_volume_m3[destination] += moved_surface_volume_m3;
        owners.soil_properties.layer_volume_m3[destination] = owners.water_heat.soil_thermal.layer_volume_m3[destination];
        owners.soil_properties.bulk_density_megagrams_per_m3[destination] =
            carriers.soil_dry_mass_after_megagrams / owners.soil_properties.matrix_bulk_volume_m3[destination];
        // Keep the prior HOUR1 constitutive tuple coherent through the accepted
        // hour boundary. The pond transaction owns live pore capacity and
        // geometry, while the next HOUR1 material refresh atomically rebuilds
        // scalar porosity, retention, and Mualem parameters from those owners.
        // `soil_thermal.porosity_fraction` spans matrix plus macropores over the
        // total layer volume and is therefore not the matrix retention porosity.
        workspace.domain_destination_soil_layer[cell] = layer;
        workspace.domain_transfer[cell] = accepted;
        workspace.domain_active[cell] = true;
    }
    geometry.applyDisturbances(owners.soil_geometry, changes, inputs.minimum_soil_layer_thickness_m) catch unreachable;
    // Chemistry transfer changes only the listed mobile concentrations while
    // water/heat transfer changes their shared carrier. Publish those species
    // and dilute every unchanged transport-owned species without altering its
    // extensive amount.
    for (0..grid.cell_count) |cell| {
        if (!inputs.transitions.active[cell]) continue;
        const destination = cell * grid.soil_layer_capacity +
            inputs.transitions.destination_soil_layer[cell];
        aqueous_bridge.synchronizeCellAfterCarrierChange(
            owners.soil_chemistry,
            owners.micropore_solutes,
            destination,
            grid.matrix_liquid_water_m3[destination],
            if (inputs.salinity_enabled_by_cell[cell])
                &pond_base_changed_species ++ pond_optional_salt_changed_species ++ pond_carbonate_changed_species
            else
                &pond_base_changed_species ++ pond_carbonate_changed_species,
            aqueous_bridge.ZoneFractions{
                .phosphate_non_band = inputs.phosphate_non_band_water_fraction_by_cell[cell],
                .phosphate_band = inputs.phosphate_band_water_fraction_by_cell[cell],
            },
        ) catch unreachable;
    }
    @memcpy(owners.soil_properties.layer_thickness_m, owners.soil_geometry.layer_thickness_m);
    @memcpy(owners.soil_properties.layer_midpoint_depth_m, owners.soil_geometry.layer_midpoint_depth_from_surface_m);
    @memcpy(owners.soil_properties.layer_bottom_depth_m, owners.soil_geometry.layer_bottom_depth_from_surface_m);
    owners.soil_face_geometry.refreshMapped(grid, owners.soil_faces, owners.soil_properties.layer_thickness_m, inputs.horizontal_cell_width_m, inputs.vertical_cell_width_m) catch unreachable;
}

fn vaporWaterEquivalentAndValidateMirror(
    owners: Owners,
    cell: usize,
    destination: usize,
    water_molar_mass_g_per_mol: f64,
    liquid_water_density_g_per_m3: f64,
) !f64 {
    const surface_mol = owners.inventories.surface_gas.water_vapor_mol[cell];
    const soil_mol = owners.inventories.soil_gas.water_vapor_mol[destination];
    const canonical_soil_mol = owners.water_heat.grid.water_vapor_volume_m3[destination] *
        liquid_water_density_g_per_m3 / water_molar_mass_g_per_mol;
    inline for (.{ surface_mol, soil_mol, canonical_soil_mol }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSurfacePondVaporState;
    const scale = @max(1.0, @max(@abs(soil_mol), @abs(canonical_soil_mol)));
    if (@abs(soil_mol - canonical_soil_mol) > 128 * std.math.floatEps(f64) * scale)
        return error.SurfacePondSoilVaporMirrorMismatch;
    const water_equivalent_m3 = surface_mol * water_molar_mass_g_per_mol /
        liquid_water_density_g_per_m3;
    if (!std.math.isFinite(water_equivalent_m3) or water_equivalent_m3 < 0)
        return error.InvalidSurfacePondVaporState;
    return water_equivalent_m3;
}

fn carrierVolumes(owners: Owners, cell: usize, destination: usize, fraction: f64, ice_density_megagrams_per_m3: f64, ammonium_non_band_water_fraction: f64, nitrate_non_band_water_fraction: f64, phosphate_non_band_water_fraction: f64, cell_area_m2: f64) !chemistry.CarrierVolumes {
    if (destination >= owners.soil_properties.layer_count) return error.SurfacePondDomainDimensionMismatch;
    const surface_water = owners.water_heat.surface_liquid_water_m3[cell];
    const surface_ice = owners.water_heat.surface_ice_m3[cell];
    const soil_water = owners.water_heat.grid.matrix_liquid_water_m3[destination];
    const soil_ice = owners.water_heat.grid.matrix_ice_water_m3[destination];
    const surface_dry_mass = owners.water_heat.surface_geometry.dry_mass_megagrams[cell];
    // Exchange concentrations and the landscape inventory both use mineral
    // matrix dry mass. Using total layer volume here silently changes every
    // adsorbed amount whenever a layer has a distinct macropore volume.
    const soil_dry_mass = owners.soil_properties.bulk_density_megagrams_per_m3[destination] *
        owners.soil_properties.matrix_bulk_volume_m3[destination];
    // Mirror the partial-transfer logic from surface_pond_water_heat_transfer so that
    // chemistry dilution volumes are consistent with the actual water movement.
    const natural_new_pore = owners.water_heat.grid.matrix_pore_capacity_m3[destination] +
        fraction * owners.water_heat.surface_geometry.pore_volume_m3[cell];
    const wanted_water_ice = fraction * (surface_water + surface_ice / ice_density_megagrams_per_m3);
    const water_transfer_scale = if (wanted_water_ice > 0.0)
        @min(1.0, @max(0.0, natural_new_pore - soil_water - soil_ice / ice_density_megagrams_per_m3) / wanted_water_ice)
    else
        1.0;
    const actual_liquid_in = fraction * surface_water * water_transfer_scale;
    return .{
        .surface_water_before_m3 = surface_water,
        .soil_shared_water_before_m3 = soil_water,
        .soil_phosphate_non_band_water_before_m3 = soil_water * phosphate_non_band_water_fraction,
        .surface_water_after_m3 = surface_water - actual_liquid_in,
        .soil_shared_water_after_m3 = soil_water + actual_liquid_in,
        .soil_phosphate_non_band_water_after_m3 = (soil_water + actual_liquid_in) * phosphate_non_band_water_fraction,
        .surface_dry_mass_before_megagrams = surface_dry_mass,
        .soil_dry_mass_before_megagrams = soil_dry_mass,
        .surface_dry_mass_after_megagrams = (1 - fraction) * surface_dry_mass,
        .soil_dry_mass_after_megagrams = soil_dry_mass + fraction * surface_dry_mass,
        .ammonium_non_band_water_fraction = ammonium_non_band_water_fraction,
        .nitrate_non_band_water_fraction = nitrate_non_band_water_fraction,
        // Scale dissolved chemistry transfer by the fraction of litter water
        // that actually moves into soil. When pore capacity is full (scale=0),
        // no dissolved species transfer regardless of the dry-mass fraction.
        .dissolved_chemistry_fraction = fraction * water_transfer_scale,
        .cell_area_m2 = cell_area_m2,
    };
}

test "pond carrier synchronization preserves untouched phosphate species" {
    var soil_chemistry = try soil_chemistry_module.State.init(std.testing.allocator, 1);
    defer soil_chemistry.deinit();
    var transport = try solute_transport_module.State.init(
        std.testing.allocator,
        1,
        aqueous_species_module.AqueousSpecies.count,
    );
    defer transport.deinit();
    transport.water_volume_m3[0] = 1;
    transport.amount_mol[@intFromEnum(aqueous_species_module.AqueousSpecies.non_band_phosphate)] = 7;
    transport.amount_mol[@intFromEnum(aqueous_species_module.AqueousSpecies.non_band_hpo4)] = 3;
    soil_chemistry.non_band_phosphate[0].dissolved_po4_mol_p_per_m3 = 99;
    soil_chemistry.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 5;

    try aqueous_bridge.synchronizeCellAfterCarrierChange(
        &soil_chemistry,
        &transport,
        0,
        2,
        &pond_base_changed_species ++ pond_carbonate_changed_species,
        aqueous_bridge.ZoneFractions{
            .phosphate_non_band = 0.25,
            .phosphate_band = 0.75,
        },
    );

    try std.testing.expectEqual(
        @as(f64, 7),
        transport.amount_mol[@intFromEnum(aqueous_species_module.AqueousSpecies.non_band_phosphate)],
    );
    try std.testing.expectEqual(
        @as(f64, 14),
        soil_chemistry.non_band_phosphate[0].dissolved_po4_mol_p_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 2.5),
        transport.amount_mol[@intFromEnum(aqueous_species_module.AqueousSpecies.non_band_hpo4)],
    );
    try std.testing.expectEqual(
        @as(f64, 5),
        soil_chemistry.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3,
    );
}

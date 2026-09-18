const std = @import("std");
const builtin = @import("builtin");
const grid_module = @import("../../state/grid.zig");
const gas = @import("transport.zig");
const gas_faces = @import("face_assembly.zig");
const gas_solver = @import("coupled_gas_solver.zig");
const gas_failure_reporter = @import("../../validation/coupled_gas_failure_reporter.zig");
const gas_failure_snapshot = @import("../../validation/coupled_gas_failure_snapshot.zig");
const gas_atmosphere = @import("atmosphere_exchange.zig");
const hydrology_module = @import("../../transport/hydrology.zig");
const geometry_module = @import("../water/face_geometry.zig");
const surface_precipitation = @import("../../surface/precipitation.zig");
const boundary_topology = @import("../profile/boundary_topology.zig");
const ice_units = @import("../../core/ice_units.zig");

pub const RuntimeParameters = struct {
    reference_temperature_k: f64 = 298.15,
    temperature_exponent: f64 = 1.75,
    free_air_diffusivity_m2_per_h: [gas.species_count]f64 = .{ 4.68e-2, 7.80e-2, 6.43e-2, 5.57e-2, 5.57e-2, 6.67e-2, 5.57e-2 },
    penman_tortuosity: f64 = 0.66,
    minimum_air_filled_porosity_m3_per_m3: f64 = 1e-12,
    /// Legacy `ZERO2` from `starts.f:94` -- "minimum values used for all
    /// calculations" -- which `starts.f:270` area-scales per horizontal cell
    /// to `ZEROS2(NY,NX) = ZERO2 * DH * DV`. Carried here in m3 per m2 of
    /// plan area so the area factor stays runtime state rather than becoming
    /// a compiled volume. This is the volumetric partner of
    /// `minimum_air_filled_porosity_m3_per_m3` (`THETX`): `trnsfr.f:5303-5306`
    /// requires BOTH, and a layer thinner than this value clears the
    /// dimensionless test while holding an unresolvable carrier volume.
    minimum_carrier_volume_m3_per_m2: f64 = 1e-6,
    water_density_g_per_m3: f64 = 1.0e6,
    water_molar_mass_g_per_mol: f64 = 18,
};

pub const SurfaceBoundaryInputs = struct {
    /// WATSUB `PARG`, already including `RATG + RAGS + RAS`.
    atmospheric_conductance_m3_per_step: []const f64,
    cell_area_m2: []const f64,
    top_layer_thickness_m: []const f64,
    /// Cell-major atmospheric carrier in `gas.Species` order.
    atmospheric_concentration_g_per_m3: []const f64,
};

pub const SubsurfaceBoundaryInputs = struct {
    topology: *const boundary_topology.State,
    layer_thickness_m: []const f64,
    /// Cell-major external carrier in `gas.Species` order.
    external_concentration_g_per_m3: []const f64,
};

pub const FailureReportRequest = gas_failure_reporter.Request;

pub const TemporaryProfileCounters = struct {
    setup_ns: i96 = 0,
    faces_ns: i96 = 0,
    boundaries_ns: i96 = 0,
    solver_ns: i96 = 0,
    publication_ns: i96 = 0,
};

pub const TemporaryProfile = struct {
    io: std.Io,
    counters: *TemporaryProfileCounters,
};

pub const AmmoniumBandFractionProvider = struct {
    context: *const anyopaque,
    at: *const fn (context: *const anyopaque, layer: usize) anyerror!f64,
};

/// Rebinds the pressure solver's molar vapor mirror from canonical soil-water
/// storage. Validate the complete source first so a malformed carrier cannot
/// leave a partially refreshed mirror.
pub fn synchronizeWaterVaporMolarMirror(
    water_vapor_mol: []f64,
    water_vapor_volume_m3: []const f64,
    water_density_g_per_m3: f64,
    water_molar_mass_g_per_mol: f64,
) !void {
    if (water_vapor_mol.len != water_vapor_volume_m3.len)
        return error.SoilGasDimensionMismatch;
    if (!std.math.isFinite(water_density_g_per_m3) or
        water_density_g_per_m3 <= 0 or
        !std.math.isFinite(water_molar_mass_g_per_mol) or
        water_molar_mass_g_per_mol <= 0)
        return error.InvalidSoilGasRuntimeParameter;
    for (water_vapor_volume_m3) |volume_m3| {
        const amount_mol = volume_m3 * water_density_g_per_m3 /
            water_molar_mass_g_per_mol;
        if (!std.math.isFinite(volume_m3) or volume_m3 < 0 or
            !std.math.isFinite(amount_mol) or amount_mol < 0)
            return error.InvalidSoilGasWaterVaporState;
    }
    for (water_vapor_mol, water_vapor_volume_m3) |*amount_mol, volume_m3|
        amount_mol.* = volume_m3 * water_density_g_per_m3 /
            water_molar_mass_g_per_mol;
}

pub const AdvanceRequest = struct {
    grid: *const grid_module.GridState,
    hydrology: *const hydrology_module.State,
    soil_faces: *const hydrology_module.SoilFaces,
    geometry: *const geometry_module.State,
    matrix_bulk_volume_m3: []const f64,
    total_porosity_fraction: []const f64,
    field_capacity_fraction: []const f64,
    gas_state: *gas.State,
    solubility_parameters: gas.SurfaceSolubilityParameters,
    exchange_parameters: surface_precipitation.GasExchangeParameters,
    ice_density_megagrams_per_m3: f64 = ice_units.reference_ice_density_megagrams_per_m3,
    ammonium_band_fraction: f64 = 0,
    ammonium_band_fraction_provider: ?AmmoniumBandFractionProvider = null,
    surface_boundary_inputs: ?SurfaceBoundaryInputs,
    subsurface_boundary_inputs: ?SubsurfaceBoundaryInputs,
    parameters: RuntimeParameters,
    solver_options: gas_solver.Options,
    /// Internal transport step; the external model clock remains one hour.
    time_step_hours: f64 = 1,
    failure_report: ?FailureReportRequest = null,
    temporary_profile: ?TemporaryProfile = null,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    air_filled_porosity_m3_per_m3: []f64,
    free_air_diffusivity_m2_per_step: []f64,
    band_water_volume_m3: []f64,
    nonband_air_volume_m3: []f64,
    band_air_volume_m3: []f64,
    /// Area-scaled legacy `ZEROS2`, one value per layer of every column.
    minimum_carrier_volume_m3: []f64,
    mass_solubility_ratio: []f64,
    gas_water_exchange_rate_per_step: []f64,
    band_gas_water_exchange_rate_per_step: []f64,
    bubbling_enabled: []bool,
    surface_boundaries: []gas_atmosphere.Boundary,
    subsurface_boundaries: []gas_atmosphere.Boundary,
    atmospheric_flux_g_per_h: []f64,
    substep_atmospheric_flux_g: []f64,
    subsurface_flux_g_per_h: []f64,
    substep_subsurface_flux_g: []f64,
    accepted_face_flux_g_per_h: []f64,
    substep_face_flux_g: []f64,
    accepted_bubble_transfer_g_per_step: []f64,
    substep_bubble_transfer_g: []f64,
    accepted_faces: []gas.Face,
    bubble_receiver_cell_by_cell: []?usize,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.ZeroSoilGasLayerCount;
        const components = try std.math.mul(usize, layer_count, gas.species_count);
        const air = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(air);
        const diffusivity = try allocator.alloc(f64, components);
        errdefer allocator.free(diffusivity);
        const band_water = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(band_water);
        const nonband_air = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(nonband_air);
        const band_air = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(band_air);
        const minimum_carrier_volume = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(minimum_carrier_volume);
        const solubility = try allocator.alloc(f64, components);
        errdefer allocator.free(solubility);
        const exchange = try allocator.alloc(f64, components);
        errdefer allocator.free(exchange);
        const band_exchange = try allocator.alloc(f64, components);
        errdefer allocator.free(band_exchange);
        const bubbling = try allocator.alloc(bool, layer_count);
        errdefer allocator.free(bubbling);
        const boundaries = try allocator.alloc(gas_atmosphere.Boundary, layer_count);
        errdefer allocator.free(boundaries);
        const subsurface_boundaries = try allocator.alloc(gas_atmosphere.Boundary, 0);
        errdefer allocator.free(subsurface_boundaries);
        const atmospheric_flux = try allocator.alloc(f64, components);
        errdefer allocator.free(atmospheric_flux);
        const substep_flux = try allocator.alloc(f64, components);
        errdefer allocator.free(substep_flux);
        const subsurface_flux = try allocator.alloc(f64, components);
        errdefer allocator.free(subsurface_flux);
        const substep_subsurface_flux = try allocator.alloc(f64, components);
        errdefer allocator.free(substep_subsurface_flux);
        const accepted_face_flux = try allocator.alloc(f64, 0);
        errdefer allocator.free(accepted_face_flux);
        const substep_face_flux = try allocator.alloc(f64, 0);
        errdefer allocator.free(substep_face_flux);
        const accepted_bubble_transfer = try allocator.alloc(f64, components);
        errdefer allocator.free(accepted_bubble_transfer);
        const substep_bubble_transfer = try allocator.alloc(f64, components);
        errdefer allocator.free(substep_bubble_transfer);
        const accepted_faces = try allocator.alloc(gas.Face, 0);
        errdefer allocator.free(accepted_faces);
        @memset(air, 0);
        @memset(diffusivity, 0);
        @memset(band_water, 0);
        @memset(nonband_air, 0);
        @memset(band_air, 0);
        @memset(minimum_carrier_volume, 0);
        @memset(solubility, 0);
        @memset(exchange, 0);
        @memset(band_exchange, 0);
        @memset(bubbling, true);
        @memset(atmospheric_flux, 0);
        @memset(substep_flux, 0);
        @memset(subsurface_flux, 0);
        @memset(substep_subsurface_flux, 0);
        @memset(accepted_bubble_transfer, 0);
        @memset(substep_bubble_transfer, 0);
        const bubble_receivers = try allocator.alloc(?usize, layer_count);
        errdefer allocator.free(bubble_receivers);
        @memset(bubble_receivers, null);
        return .{ .allocator = allocator, .air_filled_porosity_m3_per_m3 = air, .free_air_diffusivity_m2_per_step = diffusivity, .band_water_volume_m3 = band_water, .nonband_air_volume_m3 = nonband_air, .band_air_volume_m3 = band_air, .minimum_carrier_volume_m3 = minimum_carrier_volume, .mass_solubility_ratio = solubility, .gas_water_exchange_rate_per_step = exchange, .band_gas_water_exchange_rate_per_step = band_exchange, .bubbling_enabled = bubbling, .surface_boundaries = boundaries, .subsurface_boundaries = subsurface_boundaries, .atmospheric_flux_g_per_h = atmospheric_flux, .substep_atmospheric_flux_g = substep_flux, .subsurface_flux_g_per_h = subsurface_flux, .substep_subsurface_flux_g = substep_subsurface_flux, .accepted_face_flux_g_per_h = accepted_face_flux, .substep_face_flux_g = substep_face_flux, .accepted_bubble_transfer_g_per_step = accepted_bubble_transfer, .substep_bubble_transfer_g = substep_bubble_transfer, .accepted_faces = accepted_faces, .bubble_receiver_cell_by_cell = bubble_receivers };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.bubble_receiver_cell_by_cell);
        self.allocator.free(self.accepted_faces);
        self.allocator.free(self.substep_bubble_transfer_g);
        self.allocator.free(self.accepted_bubble_transfer_g_per_step);
        self.allocator.free(self.substep_face_flux_g);
        self.allocator.free(self.accepted_face_flux_g_per_h);
        self.allocator.free(self.substep_subsurface_flux_g);
        self.allocator.free(self.subsurface_flux_g_per_h);
        self.allocator.free(self.substep_atmospheric_flux_g);
        self.allocator.free(self.atmospheric_flux_g_per_h);
        self.allocator.free(self.subsurface_boundaries);
        self.allocator.free(self.surface_boundaries);
        self.allocator.free(self.bubbling_enabled);
        self.allocator.free(self.band_gas_water_exchange_rate_per_step);
        self.allocator.free(self.gas_water_exchange_rate_per_step);
        self.allocator.free(self.mass_solubility_ratio);
        self.allocator.free(self.minimum_carrier_volume_m3);
        self.allocator.free(self.band_air_volume_m3);
        self.allocator.free(self.nonband_air_volume_m3);
        self.allocator.free(self.band_water_volume_m3);
        self.allocator.free(self.free_air_diffusivity_m2_per_step);
        self.allocator.free(self.air_filled_porosity_m3_per_m3);
        self.* = undefined;
    }

    /// Deep-copy the complete gas-step owner, including the topology-sized
    /// slices that `advance` may resize.  This is intentionally separate from
    /// the authoritative gas inventory: retry and outer-hour transactions must
    /// also recover the exact coefficient/face workspace and published flux
    /// shape from before a failed attempt.
    pub fn clone(self: *const State, allocator: std.mem.Allocator) !State {
        var result = try State.init(allocator, self.air_filled_porosity_m3_per_m3.len);
        errdefer result.deinit();
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (comptime isMutableSlice(field.type)) {
                const source = @field(self, field.name);
                var destination = @field(result, field.name);
                if (destination.len != source.len) {
                    destination = try allocator.realloc(destination, source.len);
                    @field(result, field.name) = destination;
                }
                @memcpy(destination, source);
            }
        }
        return result;
    }

    /// Restore contents and slice descriptors atomically.  Same-shaped retry
    /// workspaces are copied in place; a changed topology is restored through a
    /// fully constructed replacement so allocation failure leaves `self`
    /// untouched.
    pub fn restoreExact(self: *State, source: *const State) !void {
        var same_shape = true;
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (comptime isMutableSlice(field.type))
                same_shape = same_shape and
                    @field(self, field.name).len == @field(source, field.name).len;
        }
        if (!same_shape) {
            var replacement = try source.clone(self.allocator);
            var previous = self.*;
            self.* = replacement;
            previous.deinit();
            replacement = undefined;
            return;
        }
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (comptime isMutableSlice(field.type))
                @memcpy(@field(self, field.name), @field(source, field.name));
        }
    }

    pub fn advance(self: *State, request: AdvanceRequest) !gas_solver.Result {
        const grid = request.grid;
        const hydrology = request.hydrology;
        const soil_faces = request.soil_faces;
        const geometry = request.geometry;
        const matrix_bulk_volume_m3 = request.matrix_bulk_volume_m3;
        const total_porosity_fraction = request.total_porosity_fraction;
        const field_capacity_fraction = request.field_capacity_fraction;
        const gas_state = request.gas_state;
        const solubility_parameters = request.solubility_parameters;
        const exchange_parameters = request.exchange_parameters;
        const ice_density_megagrams_per_m3 = request.ice_density_megagrams_per_m3;
        const surface_boundary_inputs = request.surface_boundary_inputs;
        const subsurface_boundary_inputs = request.subsurface_boundary_inputs;
        const parameters = request.parameters;
        const solver_options = request.solver_options;
        const time_step_hours = request.time_step_hours;
        const temporary_profile = request.temporary_profile;
        var temporary_profile_section_start: std.Io.Timestamp = if (temporary_profile) |profile|
            std.Io.Clock.now(.boot, profile.io)
        else
            undefined;
        if (!std.math.isFinite(time_step_hours) or time_step_hours <= 0 or time_step_hours > 1)
            return error.InvalidSoilGasInternalTimestep;
        try validate(self, grid, hydrology, matrix_bulk_volume_m3, total_porosity_fraction, field_capacity_fraction, gas_state, request.ammonium_band_fraction, parameters);
        if (soil_faces.active_by_layer.len != grid.layer_count or
            soil_faces.active_by_face.len != soil_faces.micropore_faces.len)
            return error.SoilGasDimensionMismatch;
        try synchronizeWaterVaporMolarMirror(
            gas_state.water_vapor_mol,
            grid.water_vapor_volume_m3,
            parameters.water_density_g_per_m3,
            parameters.water_molar_mass_g_per_mol,
        );
        // Coefficients remain hourly rates; the solver's transport fraction and
        // water/gas exchange fraction apply the internal dt exactly once.
        @memset(self.atmospheric_flux_g_per_h, 0);
        @memset(self.subsurface_flux_g_per_h, 0);
        @memset(self.accepted_bubble_transfer_g_per_step, 0);
        @memset(self.air_filled_porosity_m3_per_m3, 0);
        @memset(self.band_water_volume_m3, 0);
        // Inactive DLYRM cells remain identity rows in the fixed-capacity
        // coupled solve. Preserve their authoritative air-zone total while
        // every transport/exchange coefficient remains zero.
        @memcpy(self.nonband_air_volume_m3, gas_state.air_volume_m3);
        @memset(self.band_air_volume_m3, 0);
        @memset(self.free_air_diffusivity_m2_per_step, 0);
        @memset(self.mass_solubility_ratio, 1);
        @memset(self.gas_water_exchange_rate_per_step, 0);
        @memset(self.band_gas_water_exchange_rate_per_step, 0);
        @memset(self.bubbling_enabled, false);
        // `starts.f:269-270` `ZEROS2(NY,NX) = ZERO2 * DH * DV`. The plan area
        // is the runtime horizontal cell area already supplied for the
        // surface boundary; every layer of a column shares it, exactly as the
        // source indexes `ZEROS2` by `(NY,NX)` alone. A caller that owns no
        // cell area leaves the floor at zero, which reduces every guarded
        // site to the bare positivity test it had before this was translated.
        @memset(self.minimum_carrier_volume_m3, 0);
        if (surface_boundary_inputs) |boundary_inputs| {
            if (boundary_inputs.cell_area_m2.len != grid.cell_count)
                return error.SoilGasSurfaceBoundaryDimensionMismatch;
            if (!std.math.isFinite(parameters.minimum_carrier_volume_m3_per_m2) or
                parameters.minimum_carrier_volume_m3_per_m2 < 0)
                return error.InvalidSoilGasRuntimeParameter;
            for (0..grid.cell_count) |cell| {
                const plan_area_m2 = boundary_inputs.cell_area_m2[cell];
                if (!std.math.isFinite(plan_area_m2) or plan_area_m2 <= 0)
                    return error.InvalidSoilGasSurfaceGeometry;
                const minimum_m3 = parameters.minimum_carrier_volume_m3_per_m2 * plan_area_m2;
                if (!std.math.isFinite(minimum_m3) or minimum_m3 < 0)
                    return error.InvalidSoilGasRuntimeParameter;
                const first = cell * grid.soil_layer_capacity;
                @memset(
                    self.minimum_carrier_volume_m3[first..][0..grid.soil_layer_capacity],
                    minimum_m3,
                );
            }
        }
        var step_exchange = exchange_parameters;
        step_exchange.iteration_fraction = time_step_hours;
        for (0..grid.layer_count) |layer| {
            if (!soil_faces.active_by_layer[layer]) continue;
            const ammonium_band_fraction = if (request.ammonium_band_fraction_provider) |provider|
                try provider.at(provider.context, layer)
            else
                request.ammonium_band_fraction;
            if (!std.math.isFinite(ammonium_band_fraction) or ammonium_band_fraction < 0 or ammonium_band_fraction > 1)
                return error.InvalidSoilGasBandFraction;
            // Fortran VOLPM is the combined micropore+macropore gaseous
            // carrier. Matrix-only air remains appropriate for the aqueous
            // air-water exchange geometry below, but must not size gas
            // concentrations, pressure capacity, or interlayer diffusion.
            const air_fraction = std.math.clamp(grid.air_volume_m3[layer] / matrix_bulk_volume_m3[layer], 0, total_porosity_fraction[layer]);
            self.air_filled_porosity_m3_per_m3[layer] = air_fraction;
            const temperature_factor = std.math.pow(f64, grid.soil_temperature_k[layer] / parameters.reference_temperature_k, parameters.temperature_exponent);
            const solubility = try gas.surfaceSolubilityWaterToAir(grid.soil_temperature_k[layer], solubility_parameters);
            const air_volume = grid.air_volume_m3[layer];
            const matrix_air_volume = grid.matrix_air_volume_m3[layer];
            const physical_ice_volume_m3 = try ice_units.physicalVolumeM3FromWaterEquivalent(
                grid.matrix_ice_water_m3[layer],
                ice_density_megagrams_per_m3,
            );
            // watsub.f:1103 `Z3S=AMAX1(Z3SX,FC(L)/POROS(L))`: the wet/dry
            // exchange-rate transition point is a per-layer field-capacity
            // fraction of porosity, floored at the runscript minimum
            // (`Z3SX`), not the flat minimum alone. `oxygen_step.zig`'s
            // `airWaterExchangeRate` already computes this correctly for
            // oxygen; this mirrors it for the shared multi-species rate.
            step_exchange.transition_water_fraction = @max(
                exchange_parameters.transition_water_fraction,
                field_capacity_fraction[layer] / total_porosity_fraction[layer],
            );
            const exchange = try surface_precipitation.litterGasExchange(grid.matrix_pore_capacity_m3[layer], physical_ice_volume_m3, grid.matrix_liquid_water_m3[layer], matrix_air_volume, field_capacity_fraction[layer] * matrix_bulk_volume_m3[layer], step_exchange);
            self.band_water_volume_m3[layer] = ammonium_band_fraction * grid.matrix_liquid_water_m3[layer];
            self.nonband_air_volume_m3[layer] = (1 - ammonium_band_fraction) * air_volume;
            self.band_air_volume_m3[layer] = ammonium_band_fraction * air_volume;
            gas_state.air_volume_m3[layer] = air_volume;
            // Freeze-out: when a layer is completely frozen (air_volume = 0),
            // ice excludes all dissolved gas. Transfer dissolved mass to the
            // gaseous phase before the solver runs. The atmospheric boundary
            // (top layer) drains gaseous mass; interior frozen-layer gaseous
            // mass remains until thaw enables inter-layer gas diffusion.
            if (air_volume <= 0) {
                const start = layer * gas.species_count;
                const dissolved = gas_state.dissolved_mass_g[start..][0..gas.species_count];
                const gaseous = gas_state.gaseous_mass_g[start..][0..gas.species_count];
                for (dissolved, gaseous, 0..) |*d, *g, species| {
                    // Aqueous NH3 is a transient mirror of the mineral-N
                    // owner and must not be consumed by a generic gas cache
                    // normalization. Its two zones are handled below by the
                    // explicit same-base phase equations.
                    if (species == @intFromEnum(gas.Species.ammonia)) continue;
                    g.* += d.*;
                    d.* = 0;
                }
            }
            gas_state.temperature_k[layer] = grid.soil_temperature_k[layer];
            for (0..gas.species_count) |species| {
                const component = layer * gas.species_count + species;
                self.free_air_diffusivity_m2_per_step[component] = parameters.free_air_diffusivity_m2_per_h[species] * temperature_factor;
                self.mass_solubility_ratio[component] = solubility[species];
                self.gas_water_exchange_rate_per_step[component] = exchange.air_water_rate_per_step;
                self.band_gas_water_exchange_rate_per_step[component] = if (species == @intFromEnum(gas.Species.ammonia)) exchange.air_water_rate_per_step else 0;
            }
            self.bubbling_enabled[layer] = true;
        }
        try self.refreshBubbleReceivers(grid, gas_state, soil_faces.active_by_layer, parameters.minimum_air_filled_porosity_m3_per_m3);
        if (temporary_profile) |profile| {
            const now = std.Io.Clock.now(.boot, profile.io);
            profile.counters.setup_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
            temporary_profile_section_start = now;
        }
        var face_set = try gas_faces.buildMapped(self.allocator, soil_faces, geometry, self.air_filled_porosity_m3_per_m3, total_porosity_fraction, self.free_air_diffusivity_m2_per_step, parameters.penman_tortuosity, parameters.minimum_air_filled_porosity_m3_per_m3);
        defer face_set.deinit();
        const face_component_count = try std.math.mul(
            usize,
            face_set.faces.len,
            gas.species_count,
        );
        const topology_face_component_count = try std.math.mul(
            usize,
            soil_faces.micropore_faces.len,
            gas.species_count,
        );
        self.accepted_face_flux_g_per_h = try self.allocator.realloc(
            self.accepted_face_flux_g_per_h,
            topology_face_component_count,
        );
        self.substep_face_flux_g = try self.allocator.realloc(
            self.substep_face_flux_g,
            face_component_count,
        );
        self.accepted_faces = try self.allocator.realloc(
            self.accepted_faces,
            soil_faces.micropore_faces.len,
        );
        if (temporary_profile) |profile| {
            const now = std.Io.Clock.now(.boot, profile.io);
            profile.counters.faces_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
            temporary_profile_section_start = now;
        }
        const atmospheric_boundaries = if (surface_boundary_inputs) |inputs|
            try self.refreshSurfaceBoundaries(grid, soil_faces.active_by_layer, total_porosity_fraction, inputs, parameters)
        else
            self.surface_boundaries[0..0];
        const subsurface_boundaries = if (subsurface_boundary_inputs) |inputs|
            try self.refreshSubsurfaceBoundaries(grid, soil_faces.active_by_layer, matrix_bulk_volume_m3, total_porosity_fraction, inputs, parameters)
        else
            self.subsurface_boundaries[0..0];
        if (temporary_profile) |profile| {
            const now = std.Io.Clock.now(.boot, profile.io);
            profile.counters.boundaries_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
            temporary_profile_section_start = now;
        }
        const solve_inputs: gas_solver.Inputs = .{
            .faces = face_set.faces,
            .face_conductance_m3_per_step = face_set.conductance_m3_per_step,
            .atmospheric_boundaries = atmospheric_boundaries,
            .subsurface_boundaries = subsurface_boundaries,
            .water_volume_m3 = grid.matrix_liquid_water_m3,
            .band_water_volume_m3 = self.band_water_volume_m3,
            .nonband_air_volume_m3 = self.nonband_air_volume_m3,
            .band_air_volume_m3 = self.band_air_volume_m3,
            .minimum_carrier_volume_m3 = self.minimum_carrier_volume_m3,
            .mass_solubility_ratio = self.mass_solubility_ratio,
            .gas_water_exchange_rate_per_step = self.gas_water_exchange_rate_per_step,
            .band_gas_water_exchange_rate_per_step = self.band_gas_water_exchange_rate_per_step,
            .bubbling_enabled = self.bubbling_enabled,
            .bubble_receiver_cell_by_cell = self.bubble_receiver_cell_by_cell,
            .atmospheric_flux_g_by_component = self.substep_atmospheric_flux_g,
            .subsurface_flux_g_by_component = self.substep_subsurface_flux_g,
            .face_flux_g_by_component = self.substep_face_flux_g,
            .bubble_transfer_g_by_component = self.substep_bubble_transfer_g,
        };
        var step_options = solver_options;
        step_options.transport_iteration_fraction = time_step_hours;
        // TEMP_DIAGNOSTIC: retain terminal-rung solver detail even if the
        // failure-report request is lost before reaching this call. Remove
        // after the Ottawa gas frontier has been captured and replayed.
        step_options.emit_failure_diagnostics = request.failure_report != null or
            time_step_hours == 1.0 / 64.0;
        const result = gas_solver.solve(self.allocator, gas_state, solve_inputs, step_options) catch |err| {
            if (!builtin.is_test) std.log.warn(
                "TEMP_DIAGNOSTIC soil-gas transport solve failed: time_step_hours={e} failure_report_bound={} error={s}",
                .{ time_step_hours, request.failure_report != null, @errorName(err) },
            );
            @memset(self.atmospheric_flux_g_per_h, 0);
            @memset(self.subsurface_flux_g_per_h, 0);
            @memset(self.accepted_face_flux_g_per_h, 0);
            @memset(self.accepted_bubble_transfer_g_per_step, 0);
            if (request.failure_report) |report| return gas_failure_reporter.reportPreservingSolverError(
                self.allocator,
                report.io,
                report.directory,
                report.file_path,
                gas_state,
                solve_inputs,
                step_options,
                report.options,
                err,
            );
            return err;
        };
        if (temporary_profile) |profile| {
            const now = std.Io.Clock.now(.boot, profile.io);
            profile.counters.solver_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
            temporary_profile_section_start = now;
        }
        @memcpy(self.atmospheric_flux_g_per_h, self.substep_atmospheric_flux_g);
        @memcpy(self.subsurface_flux_g_per_h, self.substep_subsurface_flux_g);
        @memcpy(self.accepted_bubble_transfer_g_per_step, self.substep_bubble_transfer_g);
        // The hourly transaction accumulates one component vector per
        // micropore-topology face. Gas faces with no air are absent from the
        // active solve, but must remain present as explicit zeroes so the
        // accepted ledger has a stable shape across water substeps.
        @memset(self.accepted_face_flux_g_per_h, 0);
        for (face_set.source_face_indices, 0..) |source_face, active_face| {
            const source_start = source_face * gas.species_count;
            const active_start = active_face * gas.species_count;
            @memcpy(
                self.accepted_face_flux_g_per_h[source_start..][0..gas.species_count],
                self.substep_face_flux_g[active_start..][0..gas.species_count],
            );
        }
        for (soil_faces.micropore_faces, 0..) |face, source_face| {
            self.accepted_faces[source_face] = .{
                .first_cell = face.first_cell,
                .second_cell = face.second_cell,
            };
        }
        if (temporary_profile) |profile|
            profile.counters.publication_ns += temporary_profile_section_start
                .durationTo(std.Io.Clock.now(.boot, profile.io)).nanoseconds;
        return result;
    }

    /// REDIST 1722-1756 and 6539-6565: select `LG` before transport and map
    /// each bubbling layer to `LL=MIN(L,LG)`. A column without a viable gas
    /// layer retains null so the solver publishes bubbling as a boundary loss.
    fn refreshBubbleReceivers(self: *State, grid: *const grid_module.GridState, gas_state: *const gas.State, active_by_layer: []const bool, minimum_air_fraction: f64) !void {
        if (active_by_layer.len != grid.layer_count)
            return error.SoilGasDimensionMismatch;
        @memset(self.bubble_receiver_cell_by_cell, null);
        for (0..grid.cell_count) |cell| {
            const first = cell * grid.soil_layer_capacity;
            const active = grid.active_soil_layer_count[cell];
            var barrier = false;
            var lowest: ?usize = null;
            for (0..active) |local_layer| {
                const layer = first + local_layer;
                if (!active_by_layer[layer]) continue;
                // REDIST VTGAS excludes VVPRG: LG selection considers only
                // the seven tracked dry gases, while atmospheric capacity is
                // evaluated independently from air volume and temperature.
                var total_gas_mol: f64 = 0;
                const masses = try gas_state.gaseousMassesConst(layer);
                for (masses, gas.g_per_mol_tracked) |mass_g, g_per_mol|
                    total_gas_mol += mass_g / g_per_mol;
                const capacity_mol = @max(0, 1.2194e4 * gas_state.air_volume_m3[layer] / gas_state.temperature_k[layer]);
                if (self.air_filled_porosity_m3_per_m3[layer] < minimum_air_fraction or total_gas_mol > capacity_mol)
                    barrier = true;
                if (!barrier and self.air_filled_porosity_m3_per_m3[layer] >= minimum_air_fraction)
                    lowest = local_layer;
            }
            for (0..active) |local_layer| {
                const layer = first + local_layer;
                if (!active_by_layer[layer]) continue;
                self.bubble_receiver_cell_by_cell[layer] = if (lowest) |lowest_local|
                    first + @min(local_layer, lowest_local)
                else
                    null;
            }
        }
    }

    fn refreshSubsurfaceBoundaries(self: *State, grid: *const grid_module.GridState, active_by_layer: []const bool, matrix_bulk_volume_m3: []const f64, total_porosity_fraction: []const f64, inputs: SubsurfaceBoundaryInputs, parameters: RuntimeParameters) ![]const gas_atmosphere.Boundary {
        if (active_by_layer.len != grid.layer_count or inputs.layer_thickness_m.len != grid.layer_count or matrix_bulk_volume_m3.len != grid.layer_count or total_porosity_fraction.len != grid.layer_count or inputs.external_concentration_g_per_m3.len != grid.cell_count * gas.species_count) return error.SoilGasSubsurfaceBoundaryDimensionMismatch;
        self.subsurface_boundaries = try self.allocator.realloc(self.subsurface_boundaries, inputs.topology.faces.len);
        var boundary_count: usize = 0;
        for (inputs.topology.faces) |face| {
            const layer = face.layer_index;
            if (layer >= grid.layer_count) return error.SoilGasSubsurfaceBoundaryDimensionMismatch;
            if (!active_by_layer[layer]) continue;
            const air_fraction = self.air_filled_porosity_m3_per_m3[layer];
            // TRNSFR 5303-5306 permits gas transport only when both sides of
            // a face have THETPM > THETX. Perimeter/profile-bottom topology
            // supplies the external side of that same face family, so do not
            // bind its pressure-displacement term when the interior carrier
            // is at or below the shared water/gas air-fraction threshold.
            // Diffusive conductance naturally approaches zero there, but the
            // pressure term does not; omitting the boundary is therefore the
            // required gate rather than a numerical optimization.
            if (air_fraction <= parameters.minimum_air_filled_porosity_m3_per_m3) continue;
            const cell = layer / grid.soil_layer_capacity;
            const exchange_fraction = std.math.clamp(face.natural_exchange_fraction + face.artificial_exchange_fraction, 0, 1);
            const path_m = if (face.is_lower_boundary) inputs.layer_thickness_m[layer] else face.directional_layer_width_m;
            const face_area_m2 = matrix_bulk_volume_m3[layer] / path_m;
            const porosity = total_porosity_fraction[layer];
            if (!std.math.isFinite(path_m) or path_m <= 0 or !std.math.isFinite(face_area_m2) or face_area_m2 <= 0 or porosity <= 0) return error.InvalidSoilGasSubsurfaceGeometry;
            const diffusion_geometry_m = exchange_fraction * air_fraction * parameters.penman_tortuosity * air_fraction / porosity * face_area_m2 / path_m;
            var interior: [gas.species_count]f64 = undefined;
            for (&interior, 0..) |*conductance, species| conductance.* = diffusion_geometry_m * self.free_air_diffusivity_m2_per_step[layer * gas.species_count + species];
            self.subsurface_boundaries[boundary_count] = .{
                .cell_index = layer,
                // The topology exchange fraction and path are already folded
                // into the soil-side conductance; a very large outer
                // conductance makes the series limit equal to that value.
                .aerodynamic_conductance_m3_per_step = std.math.floatMax(f64),
                .interior_conductance_m3_per_step = interior,
                .atmospheric_concentration_g_per_m3 = inputs.external_concentration_g_per_m3[cell * gas.species_count ..][0..gas.species_count].*,
                .pressure_exchange_fraction = exchange_fraction,
            };
            boundary_count += 1;
        }
        return self.subsurface_boundaries[0..boundary_count];
    }

    fn refreshSurfaceBoundaries(self: *State, grid: *const grid_module.GridState, active_by_layer: []const bool, total_porosity_fraction: []const f64, inputs: SurfaceBoundaryInputs, parameters: RuntimeParameters) ![]const gas_atmosphere.Boundary {
        const cell_count = grid.cell_count;
        if (active_by_layer.len != grid.layer_count or inputs.atmospheric_conductance_m3_per_step.len != cell_count or inputs.cell_area_m2.len != cell_count or inputs.top_layer_thickness_m.len != grid.layer_count or inputs.atmospheric_concentration_g_per_m3.len != cell_count * gas.species_count or self.surface_boundaries.len < cell_count) return error.SoilGasSurfaceBoundaryDimensionMismatch;
        var boundary_count: usize = 0;
        for (0..cell_count) |cell| {
            const top = cell * grid.soil_layer_capacity;
            if (!active_by_layer[top]) continue;
            const air_fraction = self.air_filled_porosity_m3_per_m3[top];
            // TRNSFR 3532-3534 wraps both surface diffusion and convective
            // pressure displacement in THETPM > THETX. Keep the translated
            // boundary absent at equality as well as below the threshold.
            if (air_fraction <= parameters.minimum_air_filled_porosity_m3_per_m3) continue;
            const porosity = total_porosity_fraction[top];
            const area = inputs.cell_area_m2[cell];
            const thickness = inputs.top_layer_thickness_m[top];
            if (!std.math.isFinite(area) or area <= 0 or !std.math.isFinite(thickness) or thickness <= 0) return error.InvalidSoilGasSurfaceGeometry;
            const diffusion_geometry_m = air_fraction * parameters.penman_tortuosity * air_fraction / porosity * area / thickness;
            var interior: [gas.species_count]f64 = undefined;
            for (&interior, 0..) |*conductance, species| conductance.* = diffusion_geometry_m * self.free_air_diffusivity_m2_per_step[top * gas.species_count + species];
            self.surface_boundaries[boundary_count] = .{
                .cell_index = top,
                .aerodynamic_conductance_m3_per_step = inputs.atmospheric_conductance_m3_per_step[cell],
                .interior_conductance_m3_per_step = interior,
                .atmospheric_concentration_g_per_m3 = inputs.atmospheric_concentration_g_per_m3[cell * gas.species_count ..][0..gas.species_count].*,
            };
            boundary_count += 1;
        }
        return self.surface_boundaries[0..boundary_count];
    }
};

test "soil gas vapor mirror synchronization is exact and atomic" {
    var mirror = [_]f64{ 7, 11 };
    const canonical = [_]f64{ 0.001, 0.0025 };
    const density: f64 = 1.0e6;
    const molar_mass: f64 = 18.01528;

    try synchronizeWaterVaporMolarMirror(&mirror, &canonical, density, molar_mass);
    try std.testing.expectEqual(canonical[0] * density / molar_mass, mirror[0]);
    try std.testing.expectEqual(canonical[1] * density / molar_mass, mirror[1]);

    const accepted = mirror;
    try std.testing.expectError(
        error.InvalidSoilGasWaterVaporState,
        synchronizeWaterVaporMolarMirror(&mirror, &.{ 0.003, -0.001 }, density, molar_mass),
    );
    try std.testing.expectEqualDeep(accepted, mirror);
    try std.testing.expectError(
        error.SoilGasDimensionMismatch,
        synchronizeWaterVaporMolarMirror(mirror[0..1], &canonical, density, molar_mass),
    );
    try std.testing.expectEqualDeep(accepted, mirror);
}

fn isMutableSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and !pointer.is_const,
        else => false,
    };
}

fn validate(self: *const State, grid: *const grid_module.GridState, hydrology: *const hydrology_module.State, bulk: []const f64, porosity: []const f64, field_capacity: []const f64, gas_state: *const gas.State, band_fraction: f64, p: RuntimeParameters) !void {
    _ = hydrology;
    if (bulk.len != grid.layer_count or porosity.len != grid.layer_count or field_capacity.len != grid.layer_count or gas_state.cell_count != grid.layer_count or
        self.air_filled_porosity_m3_per_m3.len != grid.layer_count or self.band_water_volume_m3.len != grid.layer_count or
        self.nonband_air_volume_m3.len != grid.layer_count or self.band_air_volume_m3.len != grid.layer_count or
        self.minimum_carrier_volume_m3.len != grid.layer_count)
        return error.SoilGasDimensionMismatch;
    if (!std.math.isFinite(band_fraction) or band_fraction < 0 or band_fraction > 1) return error.InvalidSoilGasBandFraction;
    inline for (.{ p.reference_temperature_k, p.temperature_exponent, p.penman_tortuosity, p.minimum_air_filled_porosity_m3_per_m3, p.minimum_carrier_volume_m3_per_m2, p.water_density_g_per_m3, p.water_molar_mass_g_per_mol }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilGasRuntimeParameter;
    if (p.reference_temperature_k == 0 or p.water_density_g_per_m3 == 0 or p.water_molar_mass_g_per_mol == 0) return error.InvalidSoilGasRuntimeParameter;
    for (p.free_air_diffusivity_m2_per_h) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilGasRuntimeParameter;
    for (bulk, porosity, field_capacity, grid.soil_temperature_k) |volume, pore, capacity, temperature| if (!std.math.isFinite(volume) or volume <= 0 or !std.math.isFinite(pore) or pore <= 0 or !std.math.isFinite(capacity) or capacity < 0 or !std.math.isFinite(temperature) or temperature <= 0) return error.InvalidSoilGasLayerState;
}

test "soil gas step exact restore recovers resized descriptors and backing state" {
    var live = try State.init(std.testing.allocator, 2);
    defer live.deinit();
    live.air_filled_porosity_m3_per_m3[0..2].* = .{ 0.2, 0.3 };
    live.atmospheric_flux_g_per_h[0] = 4.5;
    var entry = try live.clone(std.testing.allocator);
    defer entry.deinit();

    live.accepted_face_flux_g_per_h = try live.allocator.realloc(
        live.accepted_face_flux_g_per_h,
        2 * gas.species_count,
    );
    live.substep_face_flux_g = try live.allocator.realloc(
        live.substep_face_flux_g,
        gas.species_count,
    );
    live.accepted_faces = try live.allocator.realloc(live.accepted_faces, 2);
    live.subsurface_boundaries = try live.allocator.realloc(live.subsurface_boundaries, 1);
    @memset(live.accepted_face_flux_g_per_h, 9);
    @memset(live.substep_face_flux_g, 8);
    live.air_filled_porosity_m3_per_m3[0] = 0.9;
    live.atmospheric_flux_g_per_h[0] = -12;

    try live.restoreExact(&entry);
    try std.testing.expectEqual(@as(usize, 0), live.accepted_face_flux_g_per_h.len);
    try std.testing.expectEqual(@as(usize, 0), live.substep_face_flux_g.len);
    try std.testing.expectEqual(@as(usize, 0), live.accepted_faces.len);
    try std.testing.expectEqual(@as(usize, 0), live.subsurface_boundaries.len);
    try std.testing.expectEqualSlices(f64, &.{ 0.2, 0.3 }, live.air_filled_porosity_m3_per_m3);
    try std.testing.expectEqual(@as(f64, 4.5), live.atmospheric_flux_g_per_h[0]);

    const same_shape_pointer = live.air_filled_porosity_m3_per_m3.ptr;
    live.air_filled_porosity_m3_per_m3[1] = 0.99;
    try live.restoreExact(&entry);
    try std.testing.expectEqual(same_shape_pointer, live.air_filled_porosity_m3_per_m3.ptr);
    try std.testing.expectEqualSlices(f64, &.{ 0.2, 0.3 }, live.air_filled_porosity_m3_per_m3);
}

test "mapped soil gas step conserves internal gaseous inventory" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.matrix_air_volume_m3, 0.25);
    @memset(grid.air_volume_m3, 0.25);
    @memset(grid.matrix_liquid_water_m3, 0.25);
    @memset(grid.soil_temperature_k, 298.15);
    var snow = try @import("../solute/snow_solute_transport.zig").State.init(std.testing.allocator, 2, 1);
    defer snow.deinit();
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &grid, &faces, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 1, 1 });
    defer geometry.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    gas_state.gaseous_mass_g[0] = 2;
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    const solubility = gas.SurfaceSolubilityParameters{ .reference_water_to_air = [_]f64{1} ** gas.species_count, .log_intercept = [_]f64{0} ** gas.species_count, .temperature_coefficient_per_c = [_]f64{0} ** gas.species_count };
    _ = try state.advance(.{
        .grid = &grid,
        .hydrology = &hydrology,
        .soil_faces = &faces,
        .geometry = &geometry,
        .matrix_bulk_volume_m3 = &.{ 1, 1 },
        .total_porosity_fraction = &.{ 0.5, 0.5 },
        .field_capacity_fraction = &.{ 0.3, 0.3 },
        .gas_state = &gas_state,
        .solubility_parameters = solubility,
        .exchange_parameters = .{ .reference_time_h = 1, .wet_exponent = 12, .dry_exponent = 12, .transition_water_fraction = 0.5, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 },
        .ammonium_band_fraction = 0,
        .surface_boundary_inputs = null,
        .subsurface_boundary_inputs = null,
        .parameters = .{},
        .solver_options = .{ .max_iterations = 80 },
    });
    try std.testing.expectEqual(
        faces.micropore_faces.len * gas.species_count,
        state.accepted_face_flux_g_per_h.len,
    );
    try std.testing.expectEqual(
        faces.micropore_faces.len,
        state.accepted_faces.len,
    );
    try std.testing.expectEqual(@as(usize, 0), state.accepted_faces[0].first_cell);
    try std.testing.expectEqual(@as(usize, 1), state.accepted_faces[0].second_cell);
    try std.testing.expect(state.accepted_face_flux_g_per_h[0] > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 2), gas_state.gaseous_mass_g[0] + gas_state.gaseous_mass_g[gas.species_count] + gas_state.dissolved_mass_g[0] + gas_state.dissolved_mass_g[gas.species_count], 1e-12);
    try std.testing.expect(gas_state.gaseous_mass_g[gas.species_count] > 0);
    try std.testing.expect(gas_state.dissolved_mass_g[0] + gas_state.dissolved_mass_g[gas.species_count] > 0);

    // A water substep can close one endpoint of a topology face. Its
    // published gas ledger must retain that face's zero-filled slot so an
    // hourly accumulator can add successive substeps without shape changes.
    grid.matrix_air_volume_m3[1] = 0;
    grid.air_volume_m3[1] = 0;
    _ = try state.advance(.{
        .grid = &grid,
        .hydrology = &hydrology,
        .soil_faces = &faces,
        .geometry = &geometry,
        .matrix_bulk_volume_m3 = &.{ 1, 1 },
        .total_porosity_fraction = &.{ 0.5, 0.5 },
        .field_capacity_fraction = &.{ 0.3, 0.3 },
        .gas_state = &gas_state,
        .solubility_parameters = solubility,
        .exchange_parameters = .{ .reference_time_h = 1, .wet_exponent = 12, .dry_exponent = 12, .transition_water_fraction = 0.5, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 },
        .ammonium_band_fraction = 0,
        .surface_boundary_inputs = null,
        .subsurface_boundary_inputs = null,
        .parameters = .{},
        .solver_options = .{ .max_iterations = 80 },
    });
    try std.testing.expectEqual(
        faces.micropore_faces.len * gas.species_count,
        state.accepted_face_flux_g_per_h.len,
    );
    try std.testing.expectEqual(faces.micropore_faces.len, state.accepted_faces.len);
    for (state.accepted_face_flux_g_per_h) |flux|
        try std.testing.expectEqual(@as(f64, 0), flux);

    // DLYRM is independent of transient air filling: even after restoring air,
    // an inactive fixed-capacity face/layer cannot exchange or publish gas.
    grid.matrix_air_volume_m3[1] = 0.25;
    grid.air_volume_m3[1] = 0.25;
    faces.active_by_face[0] = false;
    faces.active_by_layer[1] = false;
    const inactive_start = gas.species_count;
    gas_state.gaseous_mass_g[inactive_start] = 3;
    gas_state.dissolved_mass_g[inactive_start] = 4;
    gas_state.band_dissolved_mass_g[inactive_start] = 5;
    _ = try state.advance(.{
        .grid = &grid,
        .hydrology = &hydrology,
        .soil_faces = &faces,
        .geometry = &geometry,
        .matrix_bulk_volume_m3 = &.{ 1, 1 },
        .total_porosity_fraction = &.{ 0.5, 0.5 },
        .field_capacity_fraction = &.{ 0.3, 0.3 },
        .gas_state = &gas_state,
        .solubility_parameters = solubility,
        .exchange_parameters = .{ .reference_time_h = 1, .wet_exponent = 12, .dry_exponent = 12, .transition_water_fraction = 0.5, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 },
        .ammonium_band_fraction = 0,
        .surface_boundary_inputs = null,
        .subsurface_boundary_inputs = null,
        .parameters = .{},
        .solver_options = .{ .max_iterations = 80 },
    });
    try std.testing.expectEqual(@as(f64, 3), gas_state.gaseous_mass_g[inactive_start]);
    try std.testing.expectEqual(@as(f64, 4), gas_state.dissolved_mass_g[inactive_start]);
    try std.testing.expectEqual(@as(f64, 5), gas_state.band_dissolved_mass_g[inactive_start]);
    for (state.accepted_face_flux_g_per_h) |flux|
        try std.testing.expectEqual(@as(f64, 0), flux);
}

test "air-water exchange rate uses each layer's own field-capacity fraction of porosity, not one flat transition" {
    // watsub.f:1103 `Z3S=AMAX1(Z3SX,FC(L)/POROS(L))`: two layers at the
    // identical relative water content must fall on opposite sides of the
    // wet/dry branch when their field-capacity-to-porosity ratios straddle
    // that water content, even though a single global transition constant
    // would put both layers on the same side.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    @memset(grid.matrix_pore_capacity_m3, 1);
    @memset(grid.matrix_air_volume_m3, 0.5);
    @memset(grid.air_volume_m3, 0.5);
    @memset(grid.matrix_liquid_water_m3, 0.4);
    @memset(grid.soil_temperature_k, 298.15);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    // No water movement between the two columns: isolates each layer's own
    // local air-water exchange rate from the coupled inter-cell solve.
    faces.active_by_face[0] = false;
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &grid, &faces, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 1, 1 });
    defer geometry.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    const solubility = gas.SurfaceSolubilityParameters{ .reference_water_to_air = [_]f64{1} ** gas.species_count, .log_intercept = [_]f64{0} ** gas.species_count, .temperature_coefficient_per_c = [_]f64{0} ** gas.species_count };
    _ = try state.advance(.{
        .grid = &grid,
        .hydrology = &hydrology,
        .soil_faces = &faces,
        .geometry = &geometry,
        .matrix_bulk_volume_m3 = &.{ 1, 1 },
        .total_porosity_fraction = &.{ 1, 1 },
        // relative_water = 0.4/1 = 0.4 in both cells. Cell 0's ratio (0.3)
        // sits below it (wet branch); cell 1's (0.6) sits above it (dry
        // branch). A flat transition constant could not separate them.
        .field_capacity_fraction = &.{ 0.3, 0.6 },
        .gas_state = &gas_state,
        .solubility_parameters = solubility,
        .exchange_parameters = .{ .reference_time_h = 1, .wet_exponent = 12, .dry_exponent = 2, .transition_water_fraction = 0.1, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 },
        .ammonium_band_fraction = 0,
        .surface_boundary_inputs = null,
        .subsurface_boundary_inputs = null,
        .parameters = .{},
        .solver_options = .{ .max_iterations = 80 },
    });
    const wet_rate = state.gas_water_exchange_rate_per_step[0];
    const dry_rate = state.gas_water_exchange_rate_per_step[gas.species_count];
    // Cell 0 (wet branch, exponent 12, relative_water - Z3S = 0.1):
    // rate_per_h = 1/exp(1.2); rate = -expm1(-rate_per_h).
    const wet_rate_per_h: f64 = 1.0 / @exp(@as(f64, 1.2));
    const expected_wet = -std.math.expm1(-wet_rate_per_h);
    // Cell 1 (dry branch, exponent 2, relative_water - Z3S = -0.2):
    // rate_per_h = 1/exp(-0.4); rate = -expm1(-rate_per_h).
    const dry_rate_per_h: f64 = 1.0 / @exp(@as(f64, -0.4));
    const expected_dry = -std.math.expm1(-dry_rate_per_h);
    try std.testing.expectApproxEqAbs(expected_wet, wet_rate, 1e-12);
    try std.testing.expectApproxEqAbs(expected_dry, dry_rate, 1e-12);
    // The two rates must differ substantially -- a flat transition constant
    // would have put both cells on the same branch and produced equal rates.
    try std.testing.expect(@abs(wet_rate - dry_rate) > 0.3);
}

test "VOLPM keeps surface gas capacity when matrix air is saturated but macropore air remains" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.matrix_air_volume_m3, 0);
    @memset(grid.macropore_air_volume_m3, 0.25);
    @memset(grid.air_volume_m3, 0.25);
    @memset(grid.water_vapor_volume_m3, 0.01);
    @memset(grid.matrix_liquid_water_m3, 0.25);
    @memset(grid.soil_temperature_k, 298.15);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &grid, &faces, &.{1}, &.{1}, &.{1});
    defer geometry.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const solubility = gas.SurfaceSolubilityParameters{ .reference_water_to_air = [_]f64{1} ** gas.species_count, .log_intercept = [_]f64{0} ** gas.species_count, .temperature_coefficient_per_c = [_]f64{0} ** gas.species_count };
    var atmosphere = [_]f64{0} ** gas.species_count;
    atmosphere[0] = 1;
    const result = try state.advance(.{
        .grid = &grid,
        .hydrology = &hydrology,
        .soil_faces = &faces,
        .geometry = &geometry,
        .matrix_bulk_volume_m3 = &.{1},
        .total_porosity_fraction = &.{0.5},
        .field_capacity_fraction = &.{0.3},
        .gas_state = &gas_state,
        .solubility_parameters = solubility,
        .exchange_parameters = .{ .reference_time_h = 1, .wet_exponent = 12, .dry_exponent = 12, .transition_water_fraction = 0.5, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 },
        .ammonium_band_fraction = 0,
        .surface_boundary_inputs = .{
            .atmospheric_conductance_m3_per_step = &.{0.1},
            .cell_area_m2 = &.{2},
            .top_layer_thickness_m = &.{1},
            .atmospheric_concentration_g_per_m3 = &atmosphere,
        },
        .subsurface_boundary_inputs = null,
        .parameters = .{},
        .solver_options = .{ .max_iterations = 80 },
    });
    const top_layer_conductance = 0.25 * 0.66 * 0.25 / 0.5 * 2 * 4.68e-2;
    try std.testing.expectEqual(@as(f64, 0.25), gas_state.air_volume_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.25), state.air_filled_porosity_m3_per_m3[0]);
    // `starts.f:269-270` `ZEROS2(NY,NX) = ZERO2 * DH * DV`. This is the only
    // place the production floor becomes a volume, so pin the whole chain:
    // the default `ZERO2` times the runtime cell plan area supplied for the
    // surface boundary. A refactor that drops the area, drops the parameter,
    // or stops filling the slice silently returns every guarded site to the
    // bare positivity test that this workstream removed.
    try std.testing.expectEqual(@as(f64, 1e-6 * 2), state.minimum_carrier_volume_m3[0]);
    const represented_vapor_m3 = gas_state.water_vapor_mol[0] *
        @as(f64, 18) / @as(f64, 1.0e6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), represented_vapor_m3 / gas_state.air_volume_m3[0], 1e-15);
    try std.testing.expectApproxEqAbs(top_layer_conductance, state.surface_boundaries[0].interior_conductance_m3_per_step[0], 1e-15);
    try std.testing.expect(gas_state.gaseous_mass_g[0] > 0);
    try std.testing.expectApproxEqAbs(gas_state.gaseous_mass_g[0] + gas_state.dissolved_mass_g[0] + gas_state.band_dissolved_mass_g[0], state.atmospheric_flux_g_per_h[0], 1e-12);
    try std.testing.expect(result.newton_raphson_steps > 0);
    try std.testing.expectEqual(result.anderson_steps, result.picard_steps);
    try std.testing.expect(result.maximum_scaled_residual <= 1);

    faces.active_by_layer[0] = false;
    const gaseous_before = gas_state.gaseous_mass_g[0];
    const dissolved_before = gas_state.dissolved_mass_g[0];
    state.atmospheric_flux_g_per_h[0] = 99;
    _ = try state.advance(.{
        .grid = &grid,
        .hydrology = &hydrology,
        .soil_faces = &faces,
        .geometry = &geometry,
        .matrix_bulk_volume_m3 = &.{1},
        .total_porosity_fraction = &.{0.5},
        .field_capacity_fraction = &.{0.3},
        .gas_state = &gas_state,
        .solubility_parameters = solubility,
        .exchange_parameters = .{ .reference_time_h = 1, .wet_exponent = 12, .dry_exponent = 12, .transition_water_fraction = 0.5, .iteration_fraction = 0, .aqueous_tortuosity_coefficient = 0.7 },
        .ammonium_band_fraction = 0,
        .surface_boundary_inputs = .{
            .atmospheric_conductance_m3_per_step = &.{0.1},
            .cell_area_m2 = &.{2},
            .top_layer_thickness_m = &.{1},
            .atmospheric_concentration_g_per_m3 = &atmosphere,
        },
        .subsurface_boundary_inputs = null,
        .parameters = .{},
        .solver_options = .{ .max_iterations = 80 },
    });
    try std.testing.expectEqual(gaseous_before, gas_state.gaseous_mass_g[0]);
    try std.testing.expectEqual(dissolved_before, gas_state.dissolved_mass_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.atmospheric_flux_g_per_h[0]);
}

test "solver catch path preserves failure and publishes a readable snapshot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    @memset(grid.matrix_pore_capacity_m3, 1);
    @memset(grid.matrix_air_volume_m3, 1);
    @memset(grid.air_volume_m3, 1);
    @memset(grid.matrix_liquid_water_m3, 1);
    @memset(grid.soil_temperature_k, 298.15);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var geometry = try geometry_module.State.initMapped(
        std.testing.allocator,
        &grid,
        &faces,
        &.{1},
        &.{1},
        &.{1},
    );
    defer geometry.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.gaseous_mass_g[0] = 2;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const solubility: gas.SurfaceSolubilityParameters = .{
        .reference_water_to_air = [_]f64{1} ** gas.species_count,
        .log_intercept = [_]f64{0} ** gas.species_count,
        .temperature_coefficient_per_c = [_]f64{0} ** gas.species_count,
    };
    try std.testing.expectError(
        error.CoupledGasSolverDidNotConverge,
        state.advance(.{
            .grid = &grid,
            .hydrology = &hydrology,
            .soil_faces = &faces,
            .geometry = &geometry,
            .matrix_bulk_volume_m3 = &.{1},
            .total_porosity_fraction = &.{1},
            .field_capacity_fraction = &.{1},
            .gas_state = &gas_state,
            .solubility_parameters = solubility,
            .exchange_parameters = .{
                .reference_time_h = 1,
                .wet_exponent = 12,
                .dry_exponent = 12,
                .transition_water_fraction = 0.5,
                .iteration_fraction = 0,
                .aqueous_tortuosity_coefficient = 0.7,
            },
            .ammonium_band_fraction = 0,
            .surface_boundary_inputs = null,
            .subsurface_boundary_inputs = null,
            .parameters = .{},
            .solver_options = .{
                .absolute_tolerance_g = 1e-20,
                .relative_tolerance = 1e-20,
                .max_iterations = 1,
            },
            .failure_report = .{
                .io = std.testing.io,
                .directory = temporary.dir,
                .file_path = "cell0-hour1-gas-failure.bin",
                .options = .{ .write_buffer_bytes = 37 },
            },
        }),
    );
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "cell0-hour1-gas-failure.bin",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var replay_case = try gas_failure_snapshot.read(
        std.testing.allocator,
        &reader,
        .{},
    );
    defer replay_case.deinit();
    try std.testing.expectEqual(@as(usize, 1), replay_case.state.cell_count);
    try std.testing.expectEqual(@as(f64, 2), replay_case.state.gaseous_mass_g[0]);
    try std.testing.expectEqual(@as(u16, 1), replay_case.options.max_iterations);
}

test "runtime perimeter face builds source geometry and exchange fraction" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.air_filled_porosity_m3_per_m3[0] = 0.25;
    @memset(state.free_air_diffusivity_m2_per_step, 0.04);
    var face = boundary_topology.Face{
        .cell_index = 0,
        .layer_index = 0,
        .direction = .east,
        .direction_sign = -1,
        .directional_layer_width_m = 2,
        .slope_sine = 0,
        .natural_water_table_distance_m = 1,
        .natural_exchange_fraction = 0.4,
        .artificial_water_table_distance_m = 0,
        .artificial_exchange_fraction = 0,
        .surface_runoff_fraction = 0,
        .is_lower_boundary = false,
    };
    var water_table_mode = [_]u8{0};
    var zero_slope = [_]f64{0};
    const topology = boundary_topology.State{
        .allocator = std.testing.allocator,
        .faces = (&face)[0..1],
        .water_table_mode = &water_table_mode,
        .natural_water_table_reference_depth_m = &.{},
        .natural_water_table_depth_m = &.{},
        .internal_water_table_depth_m = &.{},
        .active_layer_depth_m = &.{},
        .artificial_water_table_depth_m = &.{},
        .artificial_water_table_reference_depth_m = &.{},
        .initial_surface_boundary_depth_m = &.{},
        .natural_water_table_surface_slope = &zero_slope,
        .artificial_water_table_surface_slope = &zero_slope,
    };
    const boundaries = try state.refreshSubsurfaceBoundaries(&grid, &.{true}, &.{8}, &.{0.5}, .{
        .topology = &topology,
        .layer_thickness_m = &.{1},
        .external_concentration_g_per_m3 = &([_]f64{0} ** gas.species_count),
    }, .{});
    // AREA = bulk/path = 4 m2; conductance geometry is
    // exchange * air * 0.66 * air / porosity * AREA / path.
    const expected: f64 = 0.4 * 0.25 * 0.66 * 0.25 / 0.5 * 4.0 / 2.0 * 0.04;
    try std.testing.expectApproxEqAbs(expected, boundaries[0].interior_conductance_m3_per_step[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), boundaries[0].pressure_exchange_fraction, 1e-15);

    const closed_subsurface = try state.refreshSubsurfaceBoundaries(&grid, &.{true}, &.{8}, &.{0.5}, .{
        .topology = &topology,
        .layer_thickness_m = &.{1},
        .external_concentration_g_per_m3 = &([_]f64{0} ** gas.species_count),
    }, .{ .minimum_air_filled_porosity_m3_per_m3 = 0.25 });
    try std.testing.expectEqual(@as(usize, 0), closed_subsurface.len);
    const below_threshold_subsurface = try state.refreshSubsurfaceBoundaries(&grid, &.{true}, &.{8}, &.{0.5}, .{
        .topology = &topology,
        .layer_thickness_m = &.{1},
        .external_concentration_g_per_m3 = &([_]f64{0} ** gas.species_count),
    }, .{ .minimum_air_filled_porosity_m3_per_m3 = 0.251 });
    try std.testing.expectEqual(@as(usize, 0), below_threshold_subsurface.len);
    const open_subsurface = try state.refreshSubsurfaceBoundaries(&grid, &.{true}, &.{8}, &.{0.5}, .{
        .topology = &topology,
        .layer_thickness_m = &.{1},
        .external_concentration_g_per_m3 = &([_]f64{0} ** gas.species_count),
    }, .{ .minimum_air_filled_porosity_m3_per_m3 = 0.249 });
    try std.testing.expectEqual(@as(usize, 1), open_subsurface.len);

    const surface_inputs: SurfaceBoundaryInputs = .{
        .atmospheric_conductance_m3_per_step = &.{0.1},
        .cell_area_m2 = &.{4},
        .top_layer_thickness_m = &.{2},
        .atmospheric_concentration_g_per_m3 = &([_]f64{0} ** gas.species_count),
    };
    const closed_surface = try state.refreshSurfaceBoundaries(&grid, &.{true}, &.{0.5}, surface_inputs, .{ .minimum_air_filled_porosity_m3_per_m3 = 0.25 });
    try std.testing.expectEqual(@as(usize, 0), closed_surface.len);
    const below_threshold_surface = try state.refreshSurfaceBoundaries(&grid, &.{true}, &.{0.5}, surface_inputs, .{ .minimum_air_filled_porosity_m3_per_m3 = 0.251 });
    try std.testing.expectEqual(@as(usize, 0), below_threshold_surface.len);
    const open_surface = try state.refreshSurfaceBoundaries(&grid, &.{true}, &.{0.5}, surface_inputs, .{ .minimum_air_filled_porosity_m3_per_m3 = 0.249 });
    try std.testing.expectEqual(@as(usize, 1), open_surface.len);
}

const std = @import("std");
const builtin = @import("builtin");
const transport = @import("../solute/transport.zig");
const solver = @import("../solute/transport_solver.zig");
const scoped_conservation = @import("../../validation/scoped_conservation.zig");
const chemistry_module = @import("../solute/chemistry_state.zig");
const reactive_module = @import("../nutrients/reactive_nitrogen_state.zig");
const grid_module = @import("../../state/grid.zig");
const hydrology_module = @import("../../transport/hydrology.zig");
const geometry_module = @import("../water/face_geometry.zig");
const nutrient_parameters_module = @import("../../plant/root/plant_root_nutrient_uptake.zig");

pub const Species = enum(u8) {
    ammonium_non_band,
    ammonium_band,
    ammonia_non_band,
    ammonia_band,
    nitrate_non_band,
    nitrate_band,
    nitrite_non_band,
    nitrite_band,
};

pub const species_count = @typeInfo(Species).@"enum".fields.len;

pub const ZoneFractions = struct {
    ammonium_non_band: f64,
    ammonium_band: f64,
    nitrate_non_band: f64,
    nitrate_band: f64,
};

/// Runtime-owned aqueous mineral-N inventories. Matrix and macropore amounts
/// remain distinct, matching the separate Z...S and Z...SH stores in TRNSFR.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    matrix: transport.State,
    macropore: transport.State,
    /// Positive values are nitrogen lost through an external boundary.
    boundary_export_g_n_per_step: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        var matrix = try transport.State.init(allocator, cell_count, species_count);
        errdefer matrix.deinit();
        var macropore = try transport.State.init(allocator, cell_count, species_count);
        errdefer macropore.deinit();
        const boundary_export = try allocator.alloc(f64, cell_count);
        @memset(boundary_export, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .matrix = matrix,
            .macropore = macropore,
            .boundary_export_g_n_per_step = boundary_export,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.boundary_export_g_n_per_step);
        self.macropore.deinit();
        self.matrix.deinit();
        self.* = undefined;
    }

    /// Imports authoritative reaction-state concentrations into the matrix
    /// domain. Macropore inventories are deliberately not overwritten: STARTE
    /// initializes them to zero and subsequent transport owns their history.
    ///
    /// ISSUE-065 (twelfth addendum): a cell whose live water has collapsed to
    /// (or below) the shared `ZEROS2` floor within the hour still has a
    /// physically meaningful concentration, defined relative to
    /// `chemistry.dry_reference_water_m3[cell]` (the layer's own remembered
    /// pre-collapse carrier -- see `water_carrier_rebase.zig`'s
    /// `rememberDryCarrier`), not relative to the (now near-zero) live water.
    /// Multiplying by the raw live water here silently zeroed the true
    /// extensive amount, the identical carrier-basis-mismatch defect class
    /// already fixed at three sibling sites this issue
    /// (`erosion_chemistry_bridge.zig`'s `erosionWaterCarrierM3`,
    /// `aqueous_transport_bridge.zig`'s `exportCarrierM3`,
    /// `water_carrier_rebase.zig`'s `sourceWaterM3` itself). `water_volume_m3`
    /// still receives the *raw* live water (unchanged): that field is also the
    /// live transport carrier `advance()`'s own face-flux physics reads, and
    /// substituting it here would silently change diffusion/convection
    /// behavior for a genuinely dry layer. Only the concentration-to-amount
    /// conversion below is substituted -- mirroring exactly how
    /// `aqueous_transport_bridge.zig`'s `exportChemistry` never rewrites
    /// `transport_state.water_volume_m3` either. `publishMatrix` below
    /// substitutes the identical carrier on the unpack side so the round trip
    /// stays symmetric and never divides a preserved nonzero amount by a raw
    /// zero.
    pub fn initializeMatrix(
        self: *State,
        chemistry: *const chemistry_module.State,
        reactive: *const reactive_module.State,
        matrix_water_volume_m3: []const f64,
        fractions_source: anytype,
        nitrogen_molar_mass_g_per_mol: f64,
        negligible_water_volume_m3: f64,
    ) !void {
        try validateBinding(self, chemistry, reactive, matrix_water_volume_m3, fractions_source, nitrogen_molar_mass_g_per_mol);
        if (!std.math.isFinite(negligible_water_volume_m3) or negligible_water_volume_m3 < 0)
            return error.InvalidMineralNitrogenTransportInput;
        @memcpy(self.matrix.water_volume_m3, matrix_water_volume_m3);
        for (0..self.cell_count) |cell| {
            const fractions = try bindingFractionsAt(fractions_source, cell);
            const aqueous = chemistry.aqueous[cell];
            const dry_reference_water_m3 = chemistry.dry_reference_water_m3[cell];
            if (!std.math.isFinite(dry_reference_water_m3) or dry_reference_water_m3 < 0)
                return error.InvalidMineralNitrogenTransportInput;
            const water = carrierM3(matrix_water_volume_m3[cell], dry_reference_water_m3, negligible_water_volume_m3);
            const amounts = try self.matrix.cellAmounts(cell);
            amounts[index(.ammonium_non_band)] = aqueous.ammonium_non_band * water * fractions.ammonium_non_band;
            amounts[index(.ammonium_band)] = aqueous.ammonium_band * water * fractions.ammonium_band;
            amounts[index(.ammonia_non_band)] = aqueous.ammonia_non_band * water * fractions.ammonium_non_band;
            amounts[index(.ammonia_band)] = aqueous.ammonia_band * water * fractions.ammonium_band;
            amounts[index(.nitrate_non_band)] = aqueous.nitrate_non_band * water * fractions.nitrate_non_band;
            amounts[index(.nitrate_band)] = aqueous.nitrate_band * water * fractions.nitrate_band;
            amounts[index(.nitrite_non_band)] = reactive.non_band_nitrite_g_n[cell] / nitrogen_molar_mass_g_per_mol;
            amounts[index(.nitrite_band)] = reactive.band_nitrite_g_n[cell] / nitrogen_molar_mass_g_per_mol;
        }
        try self.validate();
    }

    /// Captures the authoritative matrix inventory before hourly water
    /// movement. This is the TRNSFR `ZNH4S -> ZNH4S2` ownership boundary.
    pub fn captureHourStartMatrix(
        self: *State,
        chemistry: *const chemistry_module.State,
        reactive: *const reactive_module.State,
        matrix_water_volume_m3: []const f64,
        fractions_source: anytype,
        nitrogen_molar_mass_g_per_mol: f64,
        negligible_water_volume_m3: f64,
    ) !void {
        try self.initializeMatrix(
            chemistry,
            reactive,
            matrix_water_volume_m3,
            fractions_source,
            nitrogen_molar_mass_g_per_mol,
            negligible_water_volume_m3,
        );
    }

    /// Refreshes the extensive matrix inventory after reaction or surface-
    /// pond state_updates have changed the concentration-based chemistry owner.
    /// Macropore amounts remain transport-owned and are not modified.
    pub fn refreshMatrixFromReactionState(
        self: *State,
        chemistry: *const chemistry_module.State,
        reactive: *const reactive_module.State,
        matrix_water_volume_m3: []const f64,
        fractions_source: anytype,
        nitrogen_molar_mass_g_per_mol: f64,
        negligible_water_volume_m3: f64,
    ) !void {
        try self.initializeMatrix(
            chemistry,
            reactive,
            matrix_water_volume_m3,
            fractions_source,
            nitrogen_molar_mass_g_per_mol,
            negligible_water_volume_m3,
        );
    }

    pub fn validate(self: *const State) !void {
        if (self.matrix.cell_count != self.cell_count or self.macropore.cell_count != self.cell_count or self.matrix.species_count != species_count or self.macropore.species_count != species_count) return error.InvalidMineralNitrogenTransportDimensions;
        for (self.matrix.amount_mol, self.macropore.amount_mol) |matrix_amount, macropore_amount| {
            if (!std.math.isFinite(matrix_amount) or matrix_amount < 0 or !std.math.isFinite(macropore_amount) or macropore_amount < 0) return error.InvalidMineralNitrogenTransportState;
        }
    }

    /// Publishes only the matrix domain back to reaction state. Macropore
    /// inventory stays transport-owned and cannot be silently collapsed.
    ///
    /// ISSUE-065 (twelfth addendum): the divisor here must be the identical
    /// substituted carrier `initializeMatrix` used to pack the amount being
    /// unpacked, or a preserved nonzero amount over a raw zero live-water
    /// carrier trips `MineralNitrogenInZeroWaterDomain` as a pure side effect
    /// of the pack-side fix -- not a new science finding. Nothing mutates
    /// `self.matrix.water_volume_m3[cell]` or `chemistry.dry_reference_water_m3[cell]`
    /// between the last `initializeMatrix`-family call and this one (`advance`'s
    /// face-flux transport only changes `amount_mol`), so recomputing the same
    /// substitution from those two fields here reproduces the exact carrier
    /// the pack side used, making the round trip symmetric.
    pub fn publishMatrix(
        self: *const State,
        chemistry: *chemistry_module.State,
        reactive: *reactive_module.State,
        fractions_source: anytype,
        nitrogen_molar_mass_g_per_mol: f64,
        negligible_water_volume_m3: f64,
    ) !void {
        try validateBinding(self, chemistry, reactive, self.matrix.water_volume_m3, fractions_source, nitrogen_molar_mass_g_per_mol);
        if (!std.math.isFinite(negligible_water_volume_m3) or negligible_water_volume_m3 < 0)
            return error.InvalidMineralNitrogenTransportInput;
        for (0..self.cell_count) |cell| {
            const fractions = try bindingFractionsAt(fractions_source, cell);
            const dry_reference_water_m3 = chemistry.dry_reference_water_m3[cell];
            if (!std.math.isFinite(dry_reference_water_m3) or dry_reference_water_m3 < 0)
                return error.InvalidMineralNitrogenTransportInput;
            const water = carrierM3(self.matrix.water_volume_m3[cell], dry_reference_water_m3, negligible_water_volume_m3);
            const amounts = try self.matrix.cellAmountsConst(cell);
            const nh4_non_band_conc = try concentration(amounts[index(.ammonium_non_band)], water, fractions.ammonium_non_band);
            if (nh4_non_band_conc > 1000) std.log.warn(
                "large ammonium from transport publish: cell={d} conc_mol_m3={e} amount_mol={e} water_m3={e}",
                .{ cell, nh4_non_band_conc, amounts[index(.ammonium_non_band)], water },
            );
            chemistry.aqueous[cell].ammonium_non_band = nh4_non_band_conc;
            chemistry.aqueous[cell].ammonium_band = try concentration(amounts[index(.ammonium_band)], water, fractions.ammonium_band);
            chemistry.aqueous[cell].ammonia_non_band = try concentration(amounts[index(.ammonia_non_band)], water, fractions.ammonium_non_band);
            chemistry.aqueous[cell].ammonia_band = try concentration(amounts[index(.ammonia_band)], water, fractions.ammonium_band);
            chemistry.aqueous[cell].nitrate_non_band = try concentration(amounts[index(.nitrate_non_band)], water, fractions.nitrate_non_band);
            chemistry.aqueous[cell].nitrate_band = try concentration(amounts[index(.nitrate_band)], water, fractions.nitrate_band);
            reactive.non_band_nitrite_g_n[cell] = amounts[index(.nitrite_non_band)] * nitrogen_molar_mass_g_per_mol;
            reactive.band_nitrite_g_n[cell] = amounts[index(.nitrite_band)] * nitrogen_molar_mass_g_per_mol;
        }
    }
};

pub const FaceParameters = struct {
    allocator: std.mem.Allocator,
    matrix_conductance_m3_per_step: []f64,
    macropore_conductance_m3_per_step: []f64,
    mobility_fraction: []f64,

    pub fn init(allocator: std.mem.Allocator, face_count: usize) !FaceParameters {
        const count = try std.math.mul(usize, face_count, species_count);
        const matrix = try allocator.alloc(f64, count);
        errdefer allocator.free(matrix);
        const macropore = try allocator.alloc(f64, count);
        errdefer allocator.free(macropore);
        const mobility_values = try allocator.alloc(f64, count);
        @memset(matrix, 0);
        @memset(macropore, 0);
        @memset(mobility_values, 1);
        return .{ .allocator = allocator, .matrix_conductance_m3_per_step = matrix, .macropore_conductance_m3_per_step = macropore, .mobility_fraction = mobility_values };
    }

    pub fn deinit(self: *FaceParameters) void {
        self.allocator.free(self.mobility_fraction);
        self.allocator.free(self.macropore_conductance_m3_per_step);
        self.allocator.free(self.matrix_conductance_m3_per_step);
        self.* = undefined;
    }

    pub fn refresh(
        self: *FaceParameters,
        grid: *const grid_module.GridState,
        faces: *const hydrology_module.SoilFaces,
        geometry: *const geometry_module.State,
        matrix_bulk_volume_m3: []const f64,
        bulk_density_megagrams_per_m3: []const f64,
        nutrient_parameters: nutrient_parameters_module.RuntimeParameters,
        step_h: f64,
    ) !void {
        if (matrix_bulk_volume_m3.len != grid.layer_count or bulk_density_megagrams_per_m3.len != grid.layer_count or faces.active_by_layer.len != grid.layer_count or faces.active_by_face.len != faces.micropore_faces.len or faces.micropore_faces.len != geometry.face_area_m2.len or self.matrix_conductance_m3_per_step.len != faces.micropore_faces.len * species_count) return error.MineralNitrogenFaceDimensionMismatch;
        if (!std.math.isFinite(step_h) or step_h <= 0) return error.InvalidMineralNitrogenFaceInput;
        try nutrient_parameters.validate();
        for (matrix_bulk_volume_m3, bulk_density_megagrams_per_m3, grid.soil_temperature_k, faces.active_by_layer) |volume, density, temperature, active| {
            if (!std.math.isFinite(volume) or volume < 0 or !std.math.isFinite(density) or density < 0 or !std.math.isFinite(temperature)) return error.InvalidMineralNitrogenFaceInput;
            if (active and temperature <= 0) return error.InvalidMineralNitrogenFaceInput;
        }
        for (faces.micropore_faces, 0..) |face, face_index| {
            if (!faces.active_by_face[face_index]) {
                const first = face_index * species_count;
                @memset(self.matrix_conductance_m3_per_step[first..][0..species_count], 0);
                @memset(self.macropore_conductance_m3_per_step[first..][0..species_count], 0);
                @memset(self.mobility_fraction[first..][0..species_count], 0);
                continue;
            }
            const first = face.first_cell;
            const second = face.second_cell;
            const path_m = geometry.source_path_length_m[face_index] + geometry.destination_path_length_m[face_index];
            const area_m2 = geometry.face_area_m2[face_index];
            if (!std.math.isFinite(path_m) or path_m <= 0 or !std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidMineralNitrogenFaceGeometry;
            const first_macro_fraction = macroporeFraction(grid, first);
            const second_macro_fraction = macroporeFraction(grid, second);
            const first_theta = if (matrix_bulk_volume_m3[first] > 0) std.math.clamp(grid.matrix_liquid_water_m3[first] / matrix_bulk_volume_m3[first], 0, 1) else 0;
            const second_theta = if (matrix_bulk_volume_m3[second] > 0) std.math.clamp(grid.matrix_liquid_water_m3[second] / matrix_bulk_volume_m3[second], 0, 1) else 0;
            const first_tortuosity = if (matrix_bulk_volume_m3[first] > 0 and bulk_density_megagrams_per_m3[first] > 0)
                nutrient_parameters.liquid_tortuosity_coefficient * first_theta * first_theta * (1 - first_macro_fraction)
            else
                nutrient_parameters.liquid_tortuosity_coefficient;
            const second_tortuosity = if (matrix_bulk_volume_m3[second] > 0 and bulk_density_megagrams_per_m3[second] > 0)
                nutrient_parameters.liquid_tortuosity_coefficient * second_theta * second_theta * (1 - second_macro_fraction)
            else
                nutrient_parameters.liquid_tortuosity_coefficient;
            const matrix_tortuosity_per_m = (first_tortuosity + second_tortuosity) / path_m;
            const first_macro_theta = if (grid.macropore_pore_capacity_m3[first] > 0) std.math.clamp(grid.macropore_liquid_water_m3[first] / grid.macropore_pore_capacity_m3[first], 0, 1) else 0;
            const second_macro_theta = if (grid.macropore_pore_capacity_m3[second] > 0) std.math.clamp(grid.macropore_liquid_water_m3[second] / grid.macropore_pore_capacity_m3[second], 0, 1) else 0;
            const macropore_tortuosity_per_m = (@min(1.0, 2.8 * first_macro_theta * first_macro_theta * first_macro_theta) * first_macro_fraction + @min(1.0, 2.8 * second_macro_theta * second_macro_theta * second_macro_theta) * second_macro_fraction) / path_m;
            const water_velocity_m_per_step = @abs(faces.micropore_water_flux_m3_per_step[face_index]) / area_m2;
            const mean_distance_m = 0.5 * path_m;
            const dispersion_m2_per_step = 0.20 * std.math.pow(f64, mean_distance_m, 1.07) * step_h * @min(step_h, water_velocity_m_per_step);
            for (0..species_count) |species_index| {
                const nutrient_index: usize = switch (@as(Species, @enumFromInt(species_index))) {
                    .ammonium_non_band, .ammonium_band, .ammonia_non_band, .ammonia_band => 0,
                    .nitrate_non_band, .nitrate_band, .nitrite_non_band, .nitrite_band => 1,
                };
                const diffusivity = try nutrient_parameters.diffusivityM2PerH(nutrient_index, grid.soil_temperature_k[second]) * step_h;
                if (!std.math.isFinite(diffusivity) or diffusivity < 0) return error.InvalidMineralNitrogenDiffusivity;
                const component = face_index * species_count + species_index;
                self.matrix_conductance_m3_per_step[component] = (diffusivity * matrix_tortuosity_per_m + dispersion_m2_per_step) * area_m2;
                self.macropore_conductance_m3_per_step[component] = diffusivity * macropore_tortuosity_per_m * area_m2;
                // Inventories are already extensive within their band/non-band
                // water share, so applying the zone fraction again would
                // incorrectly square its effect on convection and diffusion.
                self.mobility_fraction[component] = 1;
            }
        }
    }
};

test "active zero bulk volume uses flat WATSUB tortuosity for mineral nitrogen" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    @memset(grid.matrix_liquid_water_m3, 0);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_liquid_water_m3, 0);
    @memset(grid.macropore_pore_capacity_m3, 0);
    @memset(grid.soil_temperature_k, 298.15);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &grid, &faces, &.{ 0.1, 0.1 }, &.{1}, &.{1});
    defer geometry.deinit();
    var parameters = try FaceParameters.init(std.testing.allocator, faces.micropore_faces.len);
    defer parameters.deinit();

    try parameters.refresh(&grid, &faces, &geometry, &.{ 0, 1 }, &.{ 1, 1 }, nutrient_parameters_module.compatibilityRuntimeParameters(), 1);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4e-5), parameters.matrix_conductance_m3_per_step[@intFromEnum(Species.ammonium_non_band)], 1e-12);
    try std.testing.expectEqual(@as(f64, 0), parameters.macropore_conductance_m3_per_step[@intFromEnum(Species.ammonium_non_band)]);
    try parameters.refresh(&grid, &faces, &geometry, &.{ 1, 1 }, &.{ 0, 1 }, nutrient_parameters_module.compatibilityRuntimeParameters(), 1);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4e-5), parameters.matrix_conductance_m3_per_step[@intFromEnum(Species.ammonium_non_band)], 1e-12);
}

pub const AdvanceInputs = struct {
    /// Runtime STARTE/WATSUB DLYRM activity, one entry per fixed-capacity layer.
    active_by_layer: []const bool,
    matrix_water_volume_m3: []const f64,
    macropore_water_volume_m3: []const f64,
    layer_volume_m3: []const f64,
    macropore_spacing_m: []const f64,
    micropore_diffusivity_m2_per_h: []const f64,
    matrix_faces: []const transport.Face,
    macropore_faces: []const transport.Face,
    matrix_conductance_m3_per_step: []const f64,
    macropore_conductance_m3_per_step: []const f64,
    mobility_fraction: []const f64,
    matrix_external_water_flux_m3_per_step: []const f64,
    macropore_external_water_flux_m3_per_step: []const f64,
    macropore_to_matrix_water_flux_m3_per_step: []const f64 = &.{},
    maximum_convective_fraction: f64,
    pore_exchange_step_fraction: f64,
    nitrogen_molar_mass_g_per_mol: f64,
    solver_options: solver.Options,
    /// Accepted signed face fluxes in mol N, indexed face-major/species.
    /// Positive is first_cell -> second_cell. Both outputs must be supplied
    /// together; they remain unchanged unless the complete two-domain step
    /// and boundary transaction succeeds.
    matrix_face_flux_mol_by_component: ?[]f64 = null,
    macropore_face_flux_mol_by_component: ?[]f64 = null,
    /// Conservation acceptance is independent of nonlinear convergence. The
    /// physical absolute floor is supplied in g N m-2 and converted to mol N
    /// using the accepted cell area and nitrogen molar mass.
    conservation_absolute_tolerance_g_n_per_m2: f64 = 0,
    conservation_relative_tolerance: f64 = 512 * std.math.floatEps(f64),
    soil_layer_capacity: usize = 0,
    horizontal_cell_area_m2: []const f64 = &.{},
    /// Test-only accepted-state corruption used to prove that equal and
    /// opposite local defects cannot cancel into acceptance.
    test_conservation_perturbation_mol_by_component: ?[]const f64 = null,
};

pub const AdvanceResult = struct {
    matrix: solver.Result,
    macropore: solver.Result,
};

/// Runs only converged mineral-N transport kernels. It never repeats the full
/// model cycle; NPH is solely the hybrid Newton/Picard iteration ceiling.
pub fn advance(allocator: std.mem.Allocator, state: *State, inputs: AdvanceInputs) !AdvanceResult {
    try validateAdvanceInputs(state, inputs);
    const matrix_before = try allocator.dupe(f64, state.matrix.amount_mol);
    defer allocator.free(matrix_before);
    const macropore_before = try allocator.dupe(f64, state.macropore.amount_mol);
    defer allocator.free(macropore_before);
    const matrix_water_before = try allocator.dupe(f64, state.matrix.water_volume_m3);
    defer allocator.free(matrix_water_before);
    const macropore_water_before = try allocator.dupe(f64, state.macropore.water_volume_m3);
    defer allocator.free(macropore_water_before);
    const boundary_export_before = try allocator.dupe(f64, state.boundary_export_g_n_per_step);
    defer allocator.free(boundary_export_before);
    const face_component_count = try std.math.mul(usize, inputs.matrix_faces.len, species_count);
    // Local closure needs the accepted face ledgers even when the caller does
    // not request their publication.
    const matrix_face_candidate = try allocator.alloc(f64, face_component_count);
    defer allocator.free(matrix_face_candidate);
    const macropore_face_candidate = try allocator.alloc(f64, face_component_count);
    defer allocator.free(macropore_face_candidate);
    const boundary_export_candidate_g_n = try allocator.alloc(f64, state.cell_count);
    defer allocator.free(boundary_export_candidate_g_n);
    @memset(boundary_export_candidate_g_n, 0);
    const external_inputs_mol_by_component = try allocator.alloc(f64, state.matrix.amount_mol.len);
    defer allocator.free(external_inputs_mol_by_component);
    @memset(external_inputs_mol_by_component, 0);
    const external_outputs_mol_by_component = try allocator.alloc(f64, state.matrix.amount_mol.len);
    defer allocator.free(external_outputs_mol_by_component);
    @memset(external_outputs_mol_by_component, 0);
    const pore_exchange_activity_mol = try allocator.alloc(f64, state.matrix.amount_mol.len);
    defer allocator.free(pore_exchange_activity_mol);
    @memset(pore_exchange_activity_mol, 0);
    var state_updateted = false;
    defer if (!state_updateted) {
        @memcpy(state.matrix.amount_mol, matrix_before);
        @memcpy(state.macropore.amount_mol, macropore_before);
        @memcpy(state.matrix.water_volume_m3, matrix_water_before);
        @memcpy(state.macropore.water_volume_m3, macropore_water_before);
        @memcpy(state.boundary_export_g_n_per_step, boundary_export_before);
    };

    @memcpy(state.matrix.water_volume_m3, inputs.matrix_water_volume_m3);
    @memcpy(state.macropore.water_volume_m3, inputs.macropore_water_volume_m3);
    var matrix_options = inputs.solver_options;
    matrix_options.face_flux_mol_by_component = matrix_face_candidate;
    var macropore_options = inputs.solver_options;
    macropore_options.face_flux_mol_by_component = macropore_face_candidate;
    const matrix_result = try solver.solve(allocator, &state.matrix, inputs.matrix_faces, inputs.matrix_conductance_m3_per_step, inputs.mobility_fraction, .{ .maximum_convective_fraction = inputs.maximum_convective_fraction }, matrix_options);
    const macropore_result = try solver.solve(allocator, &state.macropore, inputs.macropore_faces, inputs.macropore_conductance_m3_per_step, inputs.mobility_fraction, .{ .maximum_convective_fraction = inputs.maximum_convective_fraction }, macropore_options);
    try recordFaceTransfers(inputs.matrix_faces, matrix_face_candidate, external_inputs_mol_by_component, external_outputs_mol_by_component);
    try recordFaceTransfers(inputs.macropore_faces, macropore_face_candidate, external_inputs_mol_by_component, external_outputs_mol_by_component);

    for (0..state.cell_count) |cell| {
        if (!inputs.active_by_layer[cell]) continue;
        const base = cell * species_count;
        try applyOutwardBoundary(&state.matrix, cell, inputs.matrix_external_water_flux_m3_per_step[cell], inputs.maximum_convective_fraction, inputs.nitrogen_molar_mass_g_per_mol, &boundary_export_candidate_g_n[cell], external_outputs_mol_by_component[base..][0..species_count]);
        try applyOutwardBoundary(&state.macropore, cell, inputs.macropore_external_water_flux_m3_per_step[cell], inputs.maximum_convective_fraction, inputs.nitrogen_molar_mass_g_per_mol, &boundary_export_candidate_g_n[cell], external_outputs_mol_by_component[base..][0..species_count]);
        for (0..species_count) |species_index| {
            const component = cell * species_count + species_index;
            const convective_exchange = try transport.calculateConvectivePoreExchangeFlux(
                state.matrix.amount_mol[component],
                state.macropore.amount_mol[component],
                state.matrix.water_volume_m3[cell],
                state.macropore.water_volume_m3[cell],
                if (inputs.macropore_to_matrix_water_flux_m3_per_step.len == 0) 0 else inputs.macropore_to_matrix_water_flux_m3_per_step[cell],
                inputs.maximum_convective_fraction,
            );
            try transport.state_updatePoreExchange(&state.matrix.amount_mol[component], &state.macropore.amount_mol[component], convective_exchange);
            const exchange = try transport.calculatePoreExchangeFlux(
                state.matrix.amount_mol[component],
                state.macropore.amount_mol[component],
                state.matrix.water_volume_m3[cell],
                state.macropore.water_volume_m3[cell],
                inputs.layer_volume_m3[cell],
                inputs.pore_exchange_step_fraction,
                inputs.macropore_spacing_m[cell],
                inputs.micropore_diffusivity_m2_per_h[cell],
            );
            try transport.state_updatePoreExchange(&state.matrix.amount_mol[component], &state.macropore.amount_mol[component], exchange);
            pore_exchange_activity_mol[component] = @abs(convective_exchange) + @abs(exchange);
        }
    }
    if (inputs.test_conservation_perturbation_mol_by_component) |perturbation|
        for (state.matrix.amount_mol, perturbation) |*amount, change| {
            amount.* += change;
            if (!std.math.isFinite(amount.*) or amount.* < 0)
                return error.InvalidMineralNitrogenConservationTestControl;
        };
    try state.validate();
    try requireLocalConservation(
        matrix_before,
        macropore_before,
        state.matrix.amount_mol,
        state.macropore.amount_mol,
        external_inputs_mol_by_component,
        external_outputs_mol_by_component,
        pore_exchange_activity_mol,
        inputs,
    );
    @memcpy(state.boundary_export_g_n_per_step, boundary_export_candidate_g_n);
    if (inputs.matrix_face_flux_mol_by_component) |output|
        @memcpy(output, matrix_face_candidate);
    if (inputs.macropore_face_flux_mol_by_component) |output|
        @memcpy(output, macropore_face_candidate);
    state_updateted = true;
    return .{ .matrix = matrix_result, .macropore = macropore_result };
}

fn applyOutwardBoundary(domain: *transport.State, cell: usize, outward_water_m3: f64, maximum_fraction: f64, nitrogen_molar_mass: f64, boundary_export_g_n: *f64, external_outputs_mol_by_species: []f64) !void {
    if (outward_water_m3 <= 0) return;
    const water = domain.water_volume_m3[cell];
    const fraction = if (water > 0) @min(maximum_fraction, outward_water_m3 / water) else 0;
    const amounts = try domain.cellAmounts(cell);
    if (external_outputs_mol_by_species.len != amounts.len)
        return error.MineralNitrogenTransportDimensionMismatch;
    for (amounts, external_outputs_mol_by_species) |*amount, *external_output| {
        const exported = amount.* * fraction;
        amount.* -= exported;
        external_output.* += exported;
        boundary_export_g_n.* += exported * nitrogen_molar_mass;
        if (!std.math.isFinite(amount.*) or amount.* < 0 or !std.math.isFinite(external_output.*) or
            !std.math.isFinite(boundary_export_g_n.*))
            return error.InvalidMineralNitrogenBoundaryExport;
    }
}

fn recordFaceTransfers(
    faces: []const transport.Face,
    face_flux_mol_by_component: []const f64,
    external_inputs: []f64,
    external_outputs: []f64,
) !void {
    if (face_flux_mol_by_component.len != faces.len * species_count or
        external_inputs.len != external_outputs.len or external_inputs.len % species_count != 0)
        return error.MineralNitrogenTransportDimensionMismatch;
    const cells = external_inputs.len / species_count;
    for (faces, 0..) |face, face_index| {
        if (face.first_cell >= cells or face.second_cell >= cells)
            return error.MineralNitrogenTransportFaceIndexOutOfBounds;
        for (0..species_count) |species_index| {
            const first = face.first_cell * species_count + species_index;
            const second = face.second_cell * species_count + species_index;
            const flux = face_flux_mol_by_component[face_index * species_count + species_index];
            if (!std.math.isFinite(flux)) return error.NonFiniteMineralNitrogenConservationTerm;
            if (flux >= 0)
                external_outputs[first] += flux
            else {
                external_inputs[first] -= flux;
            }
            if (flux >= 0)
                external_inputs[second] += flux
            else {
                external_outputs[second] -= flux;
            }
            if (!std.math.isFinite(external_inputs[first]) or !std.math.isFinite(external_inputs[second]) or
                !std.math.isFinite(external_outputs[first]) or !std.math.isFinite(external_outputs[second]))
                return error.NonFiniteMineralNitrogenConservationTerm;
        }
    }
}

fn requireLocalConservation(
    matrix_before: []const f64,
    macropore_before: []const f64,
    matrix_after: []const f64,
    macropore_after: []const f64,
    external_inputs_mol_by_component: []const f64,
    external_outputs_mol_by_component: []const f64,
    pore_exchange_activity_mol: []const f64,
    inputs: AdvanceInputs,
) !void {
    if (matrix_before.len != macropore_before.len or matrix_before.len != matrix_after.len or
        matrix_before.len != macropore_after.len or matrix_before.len != external_inputs_mol_by_component.len or
        matrix_before.len != external_outputs_mol_by_component.len or
        matrix_before.len != pore_exchange_activity_mol.len or matrix_before.len % species_count != 0)
        return error.MineralNitrogenTransportDimensionMismatch;
    const cells = matrix_before.len / species_count;
    const layer_capacity = if (inputs.soil_layer_capacity == 0) cells else inputs.soil_layer_capacity;
    for (0..cells) |cell| {
        const horizontal_cell = cell / layer_capacity;
        for (0..species_count) |species_index| {
            const component = cell * species_count + species_index;
            const storage_before = matrix_before[component] + macropore_before[component];
            const storage_after = matrix_after[component] + macropore_after[component];
            const representation_floor = 64 * std.math.floatEps(f64) *
                @max(1, @max(@abs(storage_before), @abs(storage_after)));
            const configured_absolute_mol = if (inputs.horizontal_cell_area_m2.len == 0)
                0
            else
                inputs.conservation_absolute_tolerance_g_n_per_m2 *
                    inputs.horizontal_cell_area_m2[horizontal_cell] /
                    inputs.nitrogen_molar_mass_g_per_mol;
            const exchange = pore_exchange_activity_mol[component];
            const closure = try scoped_conservation.evaluate(.{
                .storage_before = storage_before,
                .storage_after = storage_after,
                .external_inputs = external_inputs_mol_by_component[component],
                .external_outputs = external_outputs_mol_by_component[component],
                .internal_production = exchange,
                .internal_consumption = exchange,
            }, .{
                .absolute = @max(configured_absolute_mol, representation_floor),
                .relative = inputs.conservation_relative_tolerance,
            });
            if (!closure.accepted) {
                if (!builtin.is_test) std.log.err(
                    "mineral-N local conservation failure: layer={d} species={s} residual_mol_n={e} absolute_mol_n={e} normalized_relative={e} limit_mol_n={e}",
                    .{ cell, @tagName(@as(Species, @enumFromInt(species_index))), closure.residual, closure.absolute, closure.normalized_relative, closure.acceptance_limit },
                );
                return error.MineralNitrogenLocalConservationFailure;
            }
        }
    }
}

fn validateBinding(state: *const State, chemistry: *const chemistry_module.State, reactive: *const reactive_module.State, water: []const f64, fractions_source: anytype, molar_mass: f64) !void {
    if (chemistry.cell_count != state.cell_count or reactive.layer_count != state.cell_count or water.len != state.cell_count) return error.MineralNitrogenBindingDimensionMismatch;
    if (!std.math.isFinite(molar_mass) or molar_mass <= 0) return error.InvalidMineralNitrogenBinding;
    for (water, 0..) |value, cell| {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidMineralNitrogenBinding;
        try validateFractions(try bindingFractionsAt(fractions_source, cell));
    }
}

fn bindingFractionsAt(source: anytype, cell: usize) !ZoneFractions {
    if (comptime @TypeOf(source) == ZoneFractions) return source;
    const fractions = try source.scienceZoneFractionsForFlatIndex(cell);
    return .{
        .ammonium_non_band = fractions.ammonium_non_band,
        .ammonium_band = fractions.ammonium_band,
        .nitrate_non_band = fractions.nitrate_non_band,
        .nitrate_band = fractions.nitrate_band,
    };
}

fn validateAdvanceInputs(state: *const State, inputs: AdvanceInputs) !void {
    try state.validate();
    const cells = state.cell_count;
    if (inputs.active_by_layer.len != cells or inputs.matrix_water_volume_m3.len != cells or inputs.macropore_water_volume_m3.len != cells or inputs.layer_volume_m3.len != cells or inputs.macropore_spacing_m.len != cells or inputs.micropore_diffusivity_m2_per_h.len != cells or inputs.matrix_external_water_flux_m3_per_step.len != cells or inputs.macropore_external_water_flux_m3_per_step.len != cells or (inputs.macropore_to_matrix_water_flux_m3_per_step.len != 0 and inputs.macropore_to_matrix_water_flux_m3_per_step.len != cells)) return error.MineralNitrogenTransportDimensionMismatch;
    if (inputs.matrix_faces.len != inputs.macropore_faces.len) return error.MineralNitrogenTransportDimensionMismatch;
    const components = try std.math.mul(usize, inputs.matrix_faces.len, species_count);
    if (inputs.matrix_conductance_m3_per_step.len != components or inputs.macropore_conductance_m3_per_step.len != components or inputs.mobility_fraction.len != components) return error.MineralNitrogenTransportDimensionMismatch;
    if ((inputs.matrix_face_flux_mol_by_component == null) != (inputs.macropore_face_flux_mol_by_component == null)) return error.MineralNitrogenTransportDimensionMismatch;
    if (inputs.matrix_face_flux_mol_by_component) |values|
        if (values.len != components or inputs.macropore_face_flux_mol_by_component.?.len != components)
            return error.MineralNitrogenTransportDimensionMismatch;
    if (inputs.test_conservation_perturbation_mol_by_component) |perturbation| {
        if (!builtin.is_test) return error.InvalidMineralNitrogenConservationTestControl;
        if (perturbation.len != state.matrix.amount_mol.len)
            return error.MineralNitrogenTransportDimensionMismatch;
    }
    if (inputs.horizontal_cell_area_m2.len != 0) {
        if (inputs.soil_layer_capacity == 0 or cells % inputs.soil_layer_capacity != 0 or
            inputs.horizontal_cell_area_m2.len != cells / inputs.soil_layer_capacity)
            return error.MineralNitrogenTransportDimensionMismatch;
        for (inputs.horizontal_cell_area_m2) |area_m2|
            if (!std.math.isFinite(area_m2) or area_m2 <= 0)
                return error.InvalidMineralNitrogenConservationTolerance;
    }
    for (inputs.matrix_faces, inputs.macropore_faces) |matrix_face, macropore_face| {
        if (matrix_face.first_cell >= cells or matrix_face.second_cell >= cells or
            macropore_face.first_cell >= cells or macropore_face.second_cell >= cells)
            return error.MineralNitrogenTransportFaceIndexOutOfBounds;
    }
    if (!std.math.isFinite(inputs.maximum_convective_fraction) or inputs.maximum_convective_fraction < 0 or inputs.maximum_convective_fraction > 1 or !std.math.isFinite(inputs.pore_exchange_step_fraction) or inputs.pore_exchange_step_fraction < 0 or inputs.pore_exchange_step_fraction > 1 or !std.math.isFinite(inputs.nitrogen_molar_mass_g_per_mol) or inputs.nitrogen_molar_mass_g_per_mol <= 0) return error.InvalidMineralNitrogenTransportInput;
    if (!std.math.isFinite(inputs.conservation_absolute_tolerance_g_n_per_m2) or inputs.conservation_absolute_tolerance_g_n_per_m2 < 0 or !std.math.isFinite(inputs.conservation_relative_tolerance) or inputs.conservation_relative_tolerance <= 0) return error.InvalidMineralNitrogenConservationTolerance;
}

fn index(species: Species) usize {
    return @intFromEnum(species);
}

/// ISSUE-065 (twelfth addendum): mirrors `erosion_chemistry_bridge.zig`'s
/// `erosionWaterCarrierM3`, `aqueous_transport_bridge.zig`'s
/// `exportCarrierM3`, and `water_carrier_rebase.zig`'s `sourceWaterM3`
/// exactly. Substitutes the layer's remembered pre-collapse carrier whenever
/// live water is at or below the shared `ZEROS2` floor, so `initializeMatrix`
/// (pack) and `publishMatrix` (unpack) agree on the same nonzero basis for a
/// degenerate layer instead of one silently using raw (possibly zero) live
/// water.
fn carrierM3(live_water_m3: f64, dry_reference_water_m3: f64, negligible_water_volume_m3: f64) f64 {
    return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
}

fn concentration(amount_mol: f64, water_m3: f64, fraction: f64) !f64 {
    if (fraction == 0 or water_m3 == 0) {
        if (amount_mol > 1e-12) return error.MineralNitrogenInZeroWaterDomain;
        return 0;
    }
    const value = amount_mol / (water_m3 * fraction);
    if (!std.math.isFinite(value) or value < 0) return error.InvalidMineralNitrogenConcentration;
    return value;
}

fn validateFractions(fractions: ZoneFractions) !void {
    inline for (@typeInfo(ZoneFractions).@"struct".fields) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidMineralNitrogenZoneFraction;
    }
    if (@abs(fractions.ammonium_non_band + fractions.ammonium_band - 1) > 1e-12 or @abs(fractions.nitrate_non_band + fractions.nitrate_band - 1) > 1e-12) return error.InvalidMineralNitrogenZoneFraction;
}

fn macroporeFraction(grid: *const grid_module.GridState, cell: usize) f64 {
    const total = grid.matrix_pore_capacity_m3[cell] + grid.macropore_pore_capacity_m3[cell];
    return if (total > 0) std.math.clamp(grid.macropore_pore_capacity_m3[cell] / total, 0, 1) else 0;
}

test "matrix and macropore mineral nitrogen remain distinct and conservative" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.matrix.amount_mol[index(.nitrate_non_band)] = 2;
    const face = [_]transport.Face{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }};
    const conductance = [_]f64{0.1} ** species_count;
    const mobility = [_]f64{1} ** species_count;
    var matrix_face_flux = [_]f64{0} ** species_count;
    var macropore_face_flux = [_]f64{0} ** species_count;
    const result = try advance(std.testing.allocator, &state, .{
        .active_by_layer = &.{ true, true },
        .matrix_water_volume_m3 = &.{ 1, 1 },
        .macropore_water_volume_m3 = &.{ 0, 0 },
        .layer_volume_m3 = &.{ 1, 1 },
        .macropore_spacing_m = &.{ 0.1, 0.1 },
        .micropore_diffusivity_m2_per_h = &.{ 1e-9, 1e-9 },
        .matrix_faces = &face,
        .macropore_faces = &face,
        .matrix_conductance_m3_per_step = &conductance,
        .macropore_conductance_m3_per_step = &conductance,
        .mobility_fraction = &mobility,
        .matrix_external_water_flux_m3_per_step = &.{ 0, 0 },
        .macropore_external_water_flux_m3_per_step = &.{ 0, 0 },
        .maximum_convective_fraction = 1,
        .pore_exchange_step_fraction = 1,
        .nitrogen_molar_mass_g_per_mol = 14,
        .solver_options = .{ .max_iterations = 40 },
        .matrix_face_flux_mol_by_component = &matrix_face_flux,
        .macropore_face_flux_mol_by_component = &macropore_face_flux,
    });
    try std.testing.expect(result.matrix.iterations < 40);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.matrix.amount_mol[index(.nitrate_non_band)] + state.matrix.amount_mol[species_count + index(.nitrate_non_band)], 1e-10);
    try std.testing.expectApproxEqAbs(
        state.matrix.amount_mol[species_count + index(.nitrate_non_band)],
        matrix_face_flux[index(.nitrate_non_band)],
        1e-12,
    );
    for (state.macropore.amount_mol) |amount| try std.testing.expectEqual(@as(f64, 0), amount);
}

test "boundary export ledger is positive nitrogen loss" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.matrix.amount_mol[index(.ammonium_non_band)] = 2;
    const result = try advance(std.testing.allocator, &state, .{
        .active_by_layer = &.{true},
        .matrix_water_volume_m3 = &.{1},
        .macropore_water_volume_m3 = &.{0},
        .layer_volume_m3 = &.{1},
        .macropore_spacing_m = &.{0.1},
        .micropore_diffusivity_m2_per_h = &.{1e-9},
        .matrix_faces = &.{},
        .macropore_faces = &.{},
        .matrix_conductance_m3_per_step = &.{},
        .macropore_conductance_m3_per_step = &.{},
        .mobility_fraction = &.{},
        .matrix_external_water_flux_m3_per_step = &.{0.25},
        .macropore_external_water_flux_m3_per_step = &.{0},
        .maximum_convective_fraction = 1,
        .pore_exchange_step_fraction = 1,
        .nitrogen_molar_mass_g_per_mol = 14,
        .solver_options = .{ .max_iterations = 4 },
    });
    _ = result;
    try std.testing.expectApproxEqAbs(@as(f64, 7), state.boundary_export_g_n_per_step[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), state.matrix.amount_mol[index(.ammonium_non_band)], 1e-12);
}

test "DLYRM-inactive layer excludes mineral nitrogen boundary and pore exchange" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.matrix.amount_mol[index(.ammonium_non_band)] = 2;
    state.macropore.amount_mol[index(.ammonium_non_band)] = 1;
    _ = try advance(std.testing.allocator, &state, .{
        .active_by_layer = &.{false},
        .matrix_water_volume_m3 = &.{1},
        .macropore_water_volume_m3 = &.{1},
        .layer_volume_m3 = &.{1},
        .macropore_spacing_m = &.{0.1},
        .micropore_diffusivity_m2_per_h = &.{1},
        .matrix_faces = &.{},
        .macropore_faces = &.{},
        .matrix_conductance_m3_per_step = &.{},
        .macropore_conductance_m3_per_step = &.{},
        .mobility_fraction = &.{},
        .matrix_external_water_flux_m3_per_step = &.{0.5},
        .macropore_external_water_flux_m3_per_step = &.{0.5},
        .maximum_convective_fraction = 1,
        .pore_exchange_step_fraction = 1,
        .nitrogen_molar_mass_g_per_mol = 14,
        .solver_options = .{ .max_iterations = 4 },
    });
    try std.testing.expectEqual(@as(f64, 2), state.matrix.amount_mol[index(.ammonium_non_band)]);
    try std.testing.expectEqual(@as(f64, 1), state.macropore.amount_mol[index(.ammonium_non_band)]);
    try std.testing.expectEqual(@as(f64, 0), state.boundary_export_g_n_per_step[0]);
}

test "failed advance rolls back boundary export ledger, not just amount_mol" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.matrix.amount_mol[index(.nitrate_non_band)] = 2;
    // Sentinel from a prior successful hour: a failed advance() must leave
    // this untouched, matching the fact that amount_mol is also unchanged.
    state.boundary_export_g_n_per_step[0] = 42;
    state.boundary_export_g_n_per_step[1] = 7;
    const matrix_before = try std.testing.allocator.dupe(f64, state.matrix.amount_mol);
    defer std.testing.allocator.free(matrix_before);
    const face = [_]transport.Face{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }};
    const conductance = [_]f64{0.1} ** species_count;
    const mobility = [_]f64{1} ** species_count;
    var unpublished_matrix_face_flux = [_]f64{31} ** species_count;
    var unpublished_macropore_face_flux = [_]f64{37} ** species_count;
    try std.testing.expectError(error.SoluteTransportSolverDidNotConverge, advance(std.testing.allocator, &state, .{
        .active_by_layer = &.{ true, true },
        .matrix_water_volume_m3 = &.{ 1, 1 },
        .macropore_water_volume_m3 = &.{ 0, 0 },
        .layer_volume_m3 = &.{ 1, 1 },
        .macropore_spacing_m = &.{ 0.1, 0.1 },
        .micropore_diffusivity_m2_per_h = &.{ 1e-9, 1e-9 },
        .matrix_faces = &face,
        .macropore_faces = &face,
        .matrix_conductance_m3_per_step = &conductance,
        .macropore_conductance_m3_per_step = &conductance,
        .mobility_fraction = &mobility,
        .matrix_external_water_flux_m3_per_step = &.{ 0, 0 },
        .macropore_external_water_flux_m3_per_step = &.{ 0, 0 },
        .maximum_convective_fraction = 1,
        .pore_exchange_step_fraction = 1,
        .nitrogen_molar_mass_g_per_mol = 14,
        .solver_options = .{ .absolute_tolerance_mol = 1e-20, .relative_tolerance = 1e-20, .max_iterations = 1 },
        .matrix_face_flux_mol_by_component = &unpublished_matrix_face_flux,
        .macropore_face_flux_mol_by_component = &unpublished_macropore_face_flux,
    }));
    try std.testing.expectEqualSlices(f64, matrix_before, state.matrix.amount_mol);
    try std.testing.expectEqual(@as(f64, 42), state.boundary_export_g_n_per_step[0]);
    try std.testing.expectEqual(@as(f64, 7), state.boundary_export_g_n_per_step[1]);
    try std.testing.expectEqual(@as(f64, 31), unpublished_matrix_face_flux[0]);
    try std.testing.expectEqual(@as(f64, 37), unpublished_macropore_face_flux[0]);
}

test "local conservation rejects cancelling defects and publishes no failed transaction outputs" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    const nitrate = index(.nitrate_non_band);
    state.matrix.amount_mol[nitrate] = 1;
    state.matrix.amount_mol[species_count + nitrate] = 1;
    state.matrix.water_volume_m3[0] = 3;
    state.matrix.water_volume_m3[1] = 4;
    state.macropore.water_volume_m3[0] = 5;
    state.macropore.water_volume_m3[1] = 6;
    state.boundary_export_g_n_per_step[0] = 41;
    state.boundary_export_g_n_per_step[1] = 43;
    const matrix_before = try std.testing.allocator.dupe(f64, state.matrix.amount_mol);
    defer std.testing.allocator.free(matrix_before);
    const macropore_before = try std.testing.allocator.dupe(f64, state.macropore.amount_mol);
    defer std.testing.allocator.free(macropore_before);
    const matrix_water_before = state.matrix.water_volume_m3[0..2].*;
    const macropore_water_before = state.macropore.water_volume_m3[0..2].*;
    const boundary_before = state.boundary_export_g_n_per_step[0..2].*;
    var matrix_face_output = [_]f64{47} ** species_count;
    var macropore_face_output = [_]f64{53} ** species_count;
    const matrix_face_before = matrix_face_output;
    const macropore_face_before = macropore_face_output;
    var perturbation = [_]f64{0} ** (2 * species_count);
    perturbation[nitrate] = 0.1;
    perturbation[species_count + nitrate] = -0.1;
    const face = [_]transport.Face{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }};
    const zero_conductance = [_]f64{0} ** species_count;
    const mobility = [_]f64{1} ** species_count;
    try std.testing.expectError(error.MineralNitrogenLocalConservationFailure, advance(std.testing.allocator, &state, .{
        .active_by_layer = &.{ true, true },
        .matrix_water_volume_m3 = &.{ 1, 1 },
        .macropore_water_volume_m3 = &.{ 0, 0 },
        .layer_volume_m3 = &.{ 1, 1 },
        .macropore_spacing_m = &.{ 0.1, 0.1 },
        .micropore_diffusivity_m2_per_h = &.{ 0, 0 },
        .matrix_faces = &face,
        .macropore_faces = &face,
        .matrix_conductance_m3_per_step = &zero_conductance,
        .macropore_conductance_m3_per_step = &zero_conductance,
        .mobility_fraction = &mobility,
        .matrix_external_water_flux_m3_per_step = &.{ 0, 0 },
        .macropore_external_water_flux_m3_per_step = &.{ 0, 0 },
        .maximum_convective_fraction = 1,
        .pore_exchange_step_fraction = 0,
        .nitrogen_molar_mass_g_per_mol = 14,
        .conservation_absolute_tolerance_g_n_per_m2 = 0,
        .conservation_relative_tolerance = 1.0e-12,
        .soil_layer_capacity = 2,
        .horizontal_cell_area_m2 = &.{1},
        .test_conservation_perturbation_mol_by_component = &perturbation,
        .solver_options = .{ .max_iterations = 8 },
        .matrix_face_flux_mol_by_component = &matrix_face_output,
        .macropore_face_flux_mol_by_component = &macropore_face_output,
    }));
    try std.testing.expectEqualSlices(f64, matrix_before, state.matrix.amount_mol);
    try std.testing.expectEqualSlices(f64, macropore_before, state.macropore.amount_mol);
    try std.testing.expectEqualDeep(matrix_water_before, state.matrix.water_volume_m3[0..2].*);
    try std.testing.expectEqualDeep(macropore_water_before, state.macropore.water_volume_m3[0..2].*);
    try std.testing.expectEqualDeep(boundary_before, state.boundary_export_g_n_per_step[0..2].*);
    try std.testing.expectEqualDeep(matrix_face_before, matrix_face_output);
    try std.testing.expectEqualDeep(macropore_face_before, macropore_face_output);
}

test "production mineral nitrogen transport binds physical conservation tolerances" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    const call = std.mem.indexOf(u8, source, "ecosys.mineral_nitrogen_transport.advance") orelse
        return error.MissingMineralNitrogenProductionAdvance;
    const call_body = source[call..@min(source.len, call + 5000)];
    inline for (.{
        ".conservation_absolute_tolerance_g_n_per_m2 = context.config.mass_balance_absolute_tolerance.nitrogen_g_m2",
        ".conservation_relative_tolerance = context.config.mass_balance_relative_tolerance",
        ".soil_layer_capacity = context.grid.soil_layer_capacity",
        ".horizontal_cell_area_m2 = context.canopy_cell_area_m2",
    }) |binding| if (std.mem.indexOf(u8, call_body, binding) == null)
        return error.MissingMineralNitrogenProductionConservationBinding;
}

test "production initializes mineral nitrogen ownership before hour-one census" {
    const main_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        std.testing.allocator,
        .limited(32 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_source);
    const driver_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_process_driver.zig",
        std.testing.allocator,
        .limited(8 * 1024 * 1024),
    );
    defer std.testing.allocator.free(driver_source);

    const initialization_function = std.mem.indexOf(
        u8,
        main_source,
        "noinline fn initializeTransportConservationOwners(",
    ) orelse return error.MissingTransportConservationInitialization;
    const matrix_initialization = std.mem.indexOfPos(
        u8,
        main_source,
        initialization_function,
        "try owners.mineral_nitrogen_transport_state.initializeMatrix(",
    ) orelse return error.MissingInitialMineralNitrogenOwnership;
    const next_owner = std.mem.indexOfPos(
        u8,
        main_source,
        matrix_initialization,
        "owners.surface_transport_state =",
    ) orelse return error.MissingSurfaceTransportInitialization;
    if (std.mem.indexOf(
        u8,
        main_source[matrix_initialization..next_owner],
        "inputs.fertilizer_band_state,",
    ) == null) return error.InitialMineralNitrogenUsesNonAuthoritativeFractions;

    const owner_setup = std.mem.indexOf(
        u8,
        main_source,
        "try initializeTransportConservationOwners(",
    ) orelse return error.MissingTransportOwnerSetup;
    const timeline = std.mem.indexOf(
        u8,
        main_source,
        "try runTimeline(&timeline_context,",
    ) orelse return error.MissingProductionTimeline;
    try std.testing.expect(owner_setup < timeline);

    const prepare_hour = std.mem.indexOf(
        u8,
        main_source,
        "noinline fn prepareHourlyScience(",
    ) orelse return error.MissingPrepareHourlyScience;
    const advance_hour = std.mem.indexOfPos(
        u8,
        main_source,
        prepare_hour,
        "noinline fn advanceHour(",
    ) orelse return error.MissingAdvanceHour;
    const timeline_hour = std.mem.indexOfPos(
        u8,
        main_source,
        advance_hour,
        "noinline fn runTimeline(",
    ) orelse return error.MissingRunTimeline;
    const prepare_phase = main_source[prepare_hour..advance_hour];
    const advance_phase = main_source[advance_hour..timeline_hour];
    const census = std.mem.indexOf(
        u8,
        prepare_phase,
        "try diagnostics.reconstructLayerMassBalanceScopes(",
    ) orelse return error.MissingHourStartStorageCensus;
    const ledger_reset = std.mem.indexOfPos(
        u8,
        prepare_phase,
        census,
        "driver_context.hourly_cell_boundary_ledger.*.reset()",
    ) orelse return error.MissingHourlyLedgerReset;
    const prepare_science = std.mem.indexOf(
        u8,
        advance_phase,
        "try prepareHourlyScience(",
    ) orelse return error.MissingHourlySciencePreparation;
    const execute_science = std.mem.indexOfPos(
        u8,
        advance_phase,
        prepare_science,
        "executeHourlyScience(",
    ) orelse return error.MissingHourlyScienceExecution;
    try std.testing.expect(census < ledger_reset);
    try std.testing.expect(prepare_science < execute_science);

    const export_chemistry = std.mem.indexOf(
        u8,
        driver_source,
        "try ecosys.soil_aqueous_transport_bridge.exportChemistry(",
    ) orelse return error.MissingHourlyChemistryExport;
    const capture = std.mem.indexOfPos(
        u8,
        driver_source,
        export_chemistry,
        "try context.mineral_nitrogen_transport.captureHourStartMatrix(",
    ) orelse return error.MissingHourlyMineralNitrogenCapture;
    try std.testing.expect(export_chemistry < capture);
}

test "hour-start capture conserves zoned ammonium through wetting and drying" {
    const fractions: ZoneFractions = .{
        .ammonium_non_band = 0.75,
        .ammonium_band = 0.25,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
    };
    for ([_]f64{ 2, 0.5 }) |water_after_m3| {
        var state = try State.init(std.testing.allocator, 1);
        defer state.deinit();
        var chemistry = try chemistry_module.State.init(std.testing.allocator, 1);
        defer chemistry.deinit();
        var reactive = try reactive_module.State.init(std.testing.allocator, 1, 1);
        defer reactive.deinit();
        chemistry.aqueous[0].ammonium_non_band = 2;
        chemistry.aqueous[0].ammonium_band = 4;
        state.macropore.amount_mol[index(.ammonium_non_band)] = 0.125;
        try state.captureHourStartMatrix(&chemistry, &reactive, &.{1}, fractions, 14, 0);
        _ = try advance(std.testing.allocator, &state, .{
            .active_by_layer = &.{true},
            .matrix_water_volume_m3 = &.{water_after_m3},
            .macropore_water_volume_m3 = &.{0.1},
            .layer_volume_m3 = &.{2},
            .macropore_spacing_m = &.{0.1},
            .micropore_diffusivity_m2_per_h = &.{1e-9},
            .matrix_faces = &.{},
            .macropore_faces = &.{},
            .matrix_conductance_m3_per_step = &.{},
            .macropore_conductance_m3_per_step = &.{},
            .mobility_fraction = &.{},
            .matrix_external_water_flux_m3_per_step = &.{0},
            .macropore_external_water_flux_m3_per_step = &.{0},
            .maximum_convective_fraction = 1,
            .pore_exchange_step_fraction = 0,
            .nitrogen_molar_mass_g_per_mol = 14,
            .solver_options = .{ .max_iterations = 4 },
        });
        try state.publishMatrix(&chemistry, &reactive, fractions, 14, 0);
        try std.testing.expectApproxEqAbs(@as(f64, 1.5), state.matrix.amount_mol[index(.ammonium_non_band)], 1e-15);
        try std.testing.expectApproxEqAbs(@as(f64, 1), state.matrix.amount_mol[index(.ammonium_band)], 1e-15);
        try std.testing.expectApproxEqAbs(@as(f64, 0.125), state.macropore.amount_mol[index(.ammonium_non_band)], 1e-15);
        try std.testing.expectApproxEqAbs(2 / water_after_m3, chemistry.aqueous[0].ammonium_non_band, 1e-15);
        try std.testing.expectApproxEqAbs(4 / water_after_m3, chemistry.aqueous[0].ammonium_band, 1e-15);
    }
}

test "issue-065: OLD raw-carrier initializeMatrix/publishMatrix would destroy mineral-N mass at hour 2894's exact degenerate water content" {
    // Reconstructs cell 0/layer 0's own recorded hour-2894 state (eleventh
    // addendum, Step 3): live water collapsed to exactly zero while
    // `dry_reference_water_m3` correctly holds the pre-collapse carrier
    // (`6.058232575064708e-3`), and a nonzero, still-valid ammonium
    // concentration is present. The un-substituted arithmetic
    // `concentration * live_water_m3` this test exercises directly is
    // exactly what the pre-fix `initializeMatrix` computed (silently zeroing
    // the true extensive amount), and the reverse division by the same raw
    // zero is exactly what the pre-fix `publishMatrix` would have needed to
    // invert -- undefined for a nonzero amount, which is why a naive
    // pack-only fix risks a new `MineralNitrogenInZeroWaterDomain` error.
    const live_water_m3: f64 = 0;
    const dry_reference_water_m3: f64 = 6.058232575064708e-3;
    const ammonium_non_band_conc: f64 = 1.8677e-2;
    try std.testing.expectEqual(@as(f64, 0), ammonium_non_band_conc * live_water_m3);
    try std.testing.expect(ammonium_non_band_conc * dry_reference_water_m3 > 1e-4);
}

test "issue-065: NEW initializeMatrix/publishMatrix round trip preserves mineral-N mass at hour 2894's exact and near-zero degenerate water content" {
    const fractions: ZoneFractions = .{
        .ammonium_non_band = 1,
        .ammonium_band = 0,
        .nitrate_non_band = 1,
        .nitrate_band = 0,
    };
    const dry_reference_water_m3: f64 = 6.058232575064708e-3;
    const negligible_water_volume_m3: f64 = 1.0e-6;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var reactive = try reactive_module.State.init(std.testing.allocator, 1, 1);
    defer reactive.deinit();
    chemistry.aqueous[0].ammonium_non_band = 1.8677e-2;
    chemistry.dry_reference_water_m3[0] = dry_reference_water_m3;

    // Exactly zero live water, matching hour 2894's post-collapse instant:
    // the true extensive amount must be preserved, not zeroed.
    try state.initializeMatrix(&chemistry, &reactive, &.{0}, fractions, 14, negligible_water_volume_m3);
    const expected_amount_mol = chemistry.aqueous[0].ammonium_non_band * dry_reference_water_m3;
    try std.testing.expectEqual(expected_amount_mol, state.matrix.amount_mol[index(.ammonium_non_band)]);
    try std.testing.expect(state.matrix.amount_mol[index(.ammonium_non_band)] > 0);

    // publishMatrix must invert the identical substitution symmetrically --
    // not trip MineralNitrogenInZeroWaterDomain on the preserved amount.
    try state.publishMatrix(&chemistry, &reactive, fractions, 14, negligible_water_volume_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 1.8677e-2), chemistry.aqueous[0].ammonium_non_band, 1e-15);

    // Near-zero but still-below-floor live water behaves identically.
    try state.initializeMatrix(&chemistry, &reactive, &.{1.0e-9}, fractions, 14, negligible_water_volume_m3);
    try std.testing.expectEqual(expected_amount_mol, state.matrix.amount_mol[index(.ammonium_non_band)]);

    // Live water above the floor is used unchanged (no-op substitution).
    try state.initializeMatrix(&chemistry, &reactive, &.{2}, fractions, 14, negligible_water_volume_m3);
    try std.testing.expectEqual(@as(f64, 2) * chemistry.aqueous[0].ammonium_non_band, state.matrix.amount_mol[index(.ammonium_non_band)]);
}

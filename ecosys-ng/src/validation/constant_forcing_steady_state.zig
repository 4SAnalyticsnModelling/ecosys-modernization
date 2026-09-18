//! Oracle-independent evidence that CONSTANT forcing drives the production
//! soil heat solver to a steady state, and that the steady state it reaches is
//! the analytical series-resistance conduction profile.
//!
//! Why this file exists. `docs/validation.md` ranks analytical/manufactured
//! solutions (tier 3) above conservation closure, and solver-tolerance
//! convergence (tier 6) is its own tier. The standing goal lists three
//! sensitivity tests and records that this is the one member that does not need
//! the production deck to reach emergence: `2x fertilizer -> N2O up` and
//! `+2 K -> earlier emergence` both need day 138, and the deck stops at 94.
//!
//! Why it is worth having. Nothing here consults legacy output, so it cannot
//! fabricate agreement by matching a number the Fortran happened to print. The
//! claim is a property of conduction itself: hold both ends of a column at
//! fixed temperatures and the interior must stop changing, at a profile whose
//! heat flux is the same through every face. A solver that lost energy at a
//! face, double-counted a boundary, or drifted under repetition would fail this
//! even while reproducing legacy output on a transient.
//!
//! What it does NOT do. It does not restate the conduction law. Face
//! conductance is MEASURED by evaluating the production `calculateFaceFlux` at
//! a one-kelvin difference (`faceConductance`), and cell conductivity comes
//! from the production `calculateCellConductivity`. Only the geometry
//! (`area / distance`) and the series-addition structure are stated here, and
//! the series structure is the physics under test.
//!
//! Two premises the analytical solution rests on are asserted rather than
//! assumed, because both are properties of this fixture and not of conduction
//! in general:
//!   1. conductivity does not vary with the face temperature difference --
//!      true only because the turbulence coefficients are zero, which pins
//!      both Nusselt numbers at one;
//!   2. the pair-equilibration limiter in `calculateFaceFlux` never binds --
//!      if it did, the flux would not be linear in the temperature difference
//!      and no series-resistance profile would exist.

const std = @import("std");
const config_module = @import("../core/config.zig");
const grid_module = @import("../state/grid.zig");
const heat_flux = @import("../soil/heat/flux.zig");
const heat_solver = @import("../soil/heat/solver.zig");

/// One vertical column of uniform-thickness layers held between two Dirichlet
/// thermal boundaries. Defaults are ordinary temperate-soil magnitudes; none of
/// them is a calibrated value and none is load-bearing for the properties under
/// test, which hold for any admissible column.
pub const Parameters = struct {
    layer_count: usize = 5,
    layer_thickness_m: f64 = 0.2,
    face_area_m2: f64 = 1.0,
    /// 1 MJ K-1 for a 0.2 m3 layer. Higher than a real mineral soil so that
    /// the pair-equilibration ceiling stays far from the conductive flux; see
    /// `the pair-equilibration limiter never binds on this column`.
    heat_capacity_megajoules_per_k: f64 = 1.0,
    surface_temperature_k: f64 = 295.0,
    base_temperature_k: f64 = 275.0,
    /// Solid conductivity ramps from the shallowest layer to the deepest, so
    /// every face has a DIFFERENT resistance and the steady profile is
    /// piecewise linear with a distinct slope per face. A straight line
    /// between the two boundary temperatures does not satisfy it, which is
    /// what makes the fixed-point test discriminating.
    ///
    /// Alternating two values instead does not work, and the first draft of
    /// this file made that mistake: `calculateFaceFlux`'s conductance is
    /// symmetric in the two endpoint conductivities, so with equal layer
    /// thicknesses a low/high alternation gives every face the SAME harmonic
    /// conductance and the interior profile comes out straight.
    shallow_solid_conductivity_numerator_m_megajoules_per_h_k: f64 = 0.010,
    deep_solid_conductivity_numerator_m_megajoules_per_h_k: f64 = 0.040,
    solid_conductivity_denominator: f64 = 1.0,
    bulk_density_megagrams_per_m3: f64 = 1.0,
    liquid_water_fraction: f64 = 0.2,
    air_fraction: f64 = 0.3,
    /// The solver's own declared convergence criteria, exposed so that the
    /// distance between the solver's fixed point and the analytical one can be
    /// measured AS A FUNCTION of them rather than attributed to them.
    solver_absolute_tolerance_k: f64 = 1e-10,
    solver_relative_tolerance: f64 = 1e-10,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field|
            if (field.type == f64 and !std.math.isFinite(@field(self, field.name)))
                return error.NonFiniteSteadyStateParameter;
        // Two layers is the smallest column with an interior face, and an
        // equal pair of boundary temperatures would make the steady state
        // isothermal and the test vacuous.
        if (self.layer_count < 2 or
            self.layer_thickness_m <= 0 or
            self.face_area_m2 <= 0 or
            self.heat_capacity_megajoules_per_k <= 0 or
            self.shallow_solid_conductivity_numerator_m_megajoules_per_h_k <= 0 or
            self.deep_solid_conductivity_numerator_m_megajoules_per_h_k <= 0 or
            self.solid_conductivity_denominator <= 0 or
            self.bulk_density_megagrams_per_m3 <= 0 or
            self.liquid_water_fraction < 0 or
            self.air_fraction < 0 or
            self.solver_absolute_tolerance_k <= 0 or
            self.solver_relative_tolerance <= 0 or
            self.solver_absolute_tolerance_k >= 1 or
            self.solver_relative_tolerance >= 1 or
            self.surface_temperature_k == self.base_temperature_k)
            return error.InvalidSteadyStateParameter;
        // Every state the column can hold lies between the two boundary
        // temperatures, so bounding those bounds the whole march inside the
        // solver's own [173.15, 373.15] K physical domain.
        const lowest = @min(self.surface_temperature_k, self.base_temperature_k);
        const highest = @max(self.surface_temperature_k, self.base_temperature_k);
        if (lowest < 200 or highest > 340) return error.InvalidSteadyStateParameter;
    }

    pub fn solidConductivityNumeratorMMegajoulesPerHK(self: Parameters, layer: usize) f64 {
        const depth_fraction = @as(f64, @floatFromInt(layer)) /
            @as(f64, @floatFromInt(self.layer_count - 1));
        return self.shallow_solid_conductivity_numerator_m_megajoules_per_h_k +
            depth_fraction *
                (self.deep_solid_conductivity_numerator_m_megajoules_per_h_k -
                    self.shallow_solid_conductivity_numerator_m_megajoules_per_h_k);
    }

    /// A Dirichlet boundary plane sits on the outer face of the end layer, so
    /// its distance to that layer's centre is half the thickness.
    pub fn boundaryDistanceM(self: Parameters) f64 {
        return 0.5 * self.layer_thickness_m;
    }
};

/// The single conductive flux every face carries once the column is steady,
/// with the resistance it was derived from.
pub const SteadyProfile = struct {
    flux_megajoules_per_hour: f64,
    total_resistance_k_hours_per_megajoule: f64,
};

pub const FaceConductance = struct {
    megajoules_per_hour_k: f64,
    /// True if `calculateFaceFlux` clipped the conductive flux to the
    /// pair-equilibration ceiling. Because both the ceiling and the unlimited
    /// flux are exactly linear in the temperature difference, this verdict does
    /// not depend on the difference it was measured at.
    equilibration_limiter_bound: bool,
};

pub const MarchReport = struct {
    hours: usize,
    largest_hourly_change_k: f64,
    final_hourly_change_k: f64,
    /// Distance from the analytical steady profile before the first hour. This
    /// is how far the march actually had to travel; asserting it is large is
    /// what stops "the column stopped changing" from being satisfied by a
    /// column that started where it finished.
    initial_deviation_k: f64,
    /// Distance from the analytical steady profile at the end of the march.
    final_deviation_k: f64,
    /// False if any hour left the column further from the steady profile than
    /// the hour before it. Constant forcing must not overshoot here: the
    /// operator is a contraction toward its own fixed point.
    deviation_decreased_every_hour: bool,
    /// Both taken from the final accepted state. `acceptedBoundaryHeat`
    /// recomputes these from the committed temperatures on a separate code
    /// path from the residual, so their equality is independent evidence that
    /// the column is storing nothing.
    final_boundary_input_megajoules: f64,
    final_boundary_output_megajoules: f64,
    largest_solver_iterations: u16,
};

/// A ready-to-march column. Owns its grid, solver workspace and every property
/// array; `deinit` releases all of them.
pub const Column = struct {
    arena: std.heap.ArenaAllocator,
    parameters: Parameters,
    grid: grid_module.GridState,
    workspace: heat_solver.Workspace,
    properties: heat_solver.Properties,
    faces: []heat_solver.Face,
    water_fluxes: heat_solver.WaterHeatFluxes,
    heat_flux_megajoules: []f64,
    options: heat_solver.Options,
    /// Writable view of the Dirichlet temperatures the `properties` above
    /// expose as const, so a test can move a boundary and re-march.
    boundary_temperature_k: []f64,
    previous_temperature_k: []f64,

    pub fn init(allocator: std.mem.Allocator, parameters: Parameters) !Column {
        try parameters.validate();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const scratch = arena.allocator();
        const count = parameters.layer_count;

        // One horizontal cell, `count` layers: `GridState` sizes its soil
        // arrays as cell_count * soil_layers, so this is a pure column and the
        // solver's cell index is the layer index.
        const cfg = try config_module.SimulationConfig.init(
            .{
                .lon_count = 1,
                .lat_count = 1,
                .soil_layers = count,
                .plant_populations = 1,
            },
            .{ .worker_threads = 1, .tile_cells = 1 },
            .{
                .relative_tolerance = 1e-10,
                .absolute_tolerance = 1e-13,
                .max_nonlinear_iterations = 200,
            },
        );
        var grid = try grid_module.GridState.init(allocator, cfg);
        errdefer grid.deinit();

        const heat_capacity = try scratch.alloc(f64, count);
        @memset(heat_capacity, parameters.heat_capacity_megajoules_per_k);
        const zero_by_layer = try scratch.alloc(f64, count);
        @memset(zero_by_layer, 0);
        const bulk_density = try scratch.alloc(f64, count);
        @memset(bulk_density, parameters.bulk_density_megagrams_per_m3);
        const liquid_water_fraction = try scratch.alloc(f64, count);
        @memset(liquid_water_fraction, parameters.liquid_water_fraction);
        const air_fraction = try scratch.alloc(f64, count);
        @memset(air_fraction, parameters.air_fraction);
        const solid_numerator = try scratch.alloc(f64, count);
        for (solid_numerator, 0..) |*value, layer|
            value.* = parameters.solidConductivityNumeratorMMegajoulesPerHK(layer);
        const solid_denominator = try scratch.alloc(f64, count);
        @memset(solid_denominator, parameters.solid_conductivity_denominator);
        const is_top = try scratch.alloc(bool, count);
        @memset(is_top, false);
        is_top[0] = true;

        const faces = try scratch.alloc(heat_solver.Face, count - 1);
        for (faces, 0..) |*face, index| face.* = .{
            .source_cell = index,
            .destination_cell = index + 1,
            // Equal path entries are the FULL layer thickness, not the
            // half-distance to the centre: `calculateFaceFlux` puts TWICE the
            // conductivity product over the two weighted path terms, so it is
            // the two half-thickness resistances that add. Same STARTS/WATSUB
            // DLYR convention as `production_freezing_column_validation.zig`.
            .source_path_length_m = parameters.layer_thickness_m,
            .destination_path_length_m = parameters.layer_thickness_m,
            .face_area_m2 = parameters.face_area_m2,
        };
        const face_zero = try scratch.alloc(f64, faces.len);
        @memset(face_zero, 0);
        const heat_flux_megajoules = try scratch.alloc(f64, faces.len);
        @memset(heat_flux_megajoules, 0);

        const boundary_cell_index = try scratch.alloc(usize, 2);
        boundary_cell_index[0] = 0;
        boundary_cell_index[1] = count - 1;
        const boundary_temperature_k = try scratch.alloc(f64, 2);
        boundary_temperature_k[0] = parameters.surface_temperature_k;
        boundary_temperature_k[1] = parameters.base_temperature_k;
        const boundary_distance_m = try scratch.alloc(f64, 2);
        @memset(boundary_distance_m, parameters.boundaryDistanceM());
        const boundary_area_m2 = try scratch.alloc(f64, 2);
        @memset(boundary_area_m2, parameters.face_area_m2);

        const previous_temperature_k = try scratch.alloc(f64, count);
        @memset(previous_temperature_k, 0);

        const options: heat_solver.Options = .{
            .max_iterations = 200,
            .absolute_tolerance_k = parameters.solver_absolute_tolerance_k,
            .relative_tolerance = parameters.solver_relative_tolerance,
            .dense_newton_max_components = 256,
        };
        var workspace = try heat_solver.Workspace.init(
            allocator,
            count,
            faces.len,
            options.dense_newton_max_components,
        );
        errdefer workspace.deinit();

        return .{
            .arena = arena,
            .parameters = parameters,
            .grid = grid,
            .workspace = workspace,
            .faces = faces,
            .water_fluxes = .{
                .liquid_water_m3 = face_zero,
                .vapor_m3 = face_zero,
                .macropore_water_m3 = face_zero,
            },
            .heat_flux_megajoules = heat_flux_megajoules,
            .options = options,
            .boundary_temperature_k = boundary_temperature_k,
            .previous_temperature_k = previous_temperature_k,
            .properties = .{
                .heat_capacity_megajoules_per_k = heat_capacity,
                .minimum_heat_capacity_megajoules_per_k = zero_by_layer,
                .bulk_density_megagrams_per_m3 = bulk_density,
                .liquid_water_fraction = liquid_water_fraction,
                .ice_fraction = zero_by_layer,
                .air_fraction = air_fraction,
                .fraction_of_pore_volume_air_filled = air_fraction,
                .solid_conductivity_numerator_m_megajoules_per_h_k = solid_numerator,
                .solid_conductivity_denominator = solid_denominator,
                .is_top_soil_layer = is_top,
                .top_snow_heat_capacity_megajoules_per_k = zero_by_layer,
                .maximum_negligible_snow_heat_capacity_megajoules_per_k = zero_by_layer,
                .snow_storage_heat_flux_megajoules = zero_by_layer,
                .cell_heat_source_megajoules = zero_by_layer,
                .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
                // Zero Rayleigh coefficients pin both Nusselt numbers at one.
                // This is what makes conductivity independent of the face
                // temperature difference, and therefore what makes a
                // series-resistance steady state exist at all.
                .turbulence = .{
                    .water_fraction_threshold = 1,
                    .air_fraction_threshold = 1,
                    .water_rayleigh_coefficient = 0,
                    .air_rayleigh_coefficient = 0,
                    .water_nusselt_denominator = 1,
                    .air_nusselt_denominator = 1,
                },
                .time_step_hours = 1,
                .dirichlet_thermal_boundaries = .{
                    .cell_index = boundary_cell_index,
                    .temperature_k = boundary_temperature_k,
                    .distance_from_cell_center_m = boundary_distance_m,
                    .face_area_m2 = boundary_area_m2,
                },
            },
        };
    }

    pub fn deinit(self: *Column) void {
        self.workspace.deinit();
        self.grid.deinit();
        self.arena.deinit();
    }

    pub fn temperatureK(self: *Column) []f64 {
        return self.grid.soil_temperature_k;
    }

    /// Cell conductivity as the PRODUCTION correlation computes it, so every
    /// resistance below is built from the model's own value rather than a
    /// restatement of it.
    pub fn layerConductivityMMegajoulesPerHK(
        self: Column,
        layer: usize,
        temperature_difference_k: f64,
    ) !f64 {
        if (layer >= self.parameters.layer_count)
            return error.SteadyStateLayerOutOfRange;
        return heat_flux.calculateCellConductivity(.{
            .bulk_density_megagrams_per_m3 = self.parameters.bulk_density_megagrams_per_m3,
            .liquid_water_fraction = self.parameters.liquid_water_fraction,
            .ice_fraction = 0,
            .air_fraction = self.parameters.air_fraction,
            .fraction_of_pore_volume_air_filled = self.parameters.air_fraction,
            .solid_conductivity_numerator_m_megajoules_per_h_k = self.parameters
                .solidConductivityNumeratorMMegajoulesPerHK(layer),
            .solid_conductivity_denominator = self.parameters.solid_conductivity_denominator,
            .temperature_difference_k = temperature_difference_k,
        }, self.properties.turbulence);
    }

    /// `acceptedBoundaryHeatInto` drives a Dirichlet face with the plain
    /// linear form `conductivity * area * difference / distance`, so the
    /// resistance is `distance / (conductivity * area)`.
    pub fn dirichletResistanceKHoursPerMegajoule(self: Column, layer: usize) !f64 {
        const conductivity = try self.layerConductivityMMegajoulesPerHK(layer, 0);
        return self.parameters.boundaryDistanceM() /
            (conductivity * self.parameters.face_area_m2);
    }

    /// How much a one-kelvin error in the two end layers changes the total
    /// boundary heat. A settled state sits inside the solver's tolerance ball
    /// rather than exactly on the steady state, so it is still gaining or
    /// losing energy by at most this times that settling error -- which is the
    /// honest bound on how closely the two boundary fluxes can be expected to
    /// match, and is derived here rather than chosen.
    pub fn boundaryConductanceSumMegajoulesPerHourK(self: Column) !f64 {
        const top = try self.dirichletResistanceKHoursPerMegajoule(0);
        const base = try self.dirichletResistanceKHoursPerMegajoule(
            self.parameters.layer_count - 1,
        );
        return 1.0 / top + 1.0 / base;
    }

    /// The conductance the production flux law actually applies, measured by
    /// evaluating `calculateFaceFlux` across a one-kelvin difference instead of
    /// restating its expression. Also reports whether the pair-equilibration
    /// ceiling clipped the result.
    pub fn faceConductance(self: Column, face_index: usize) !FaceConductance {
        if (face_index >= self.faces.len) return error.SteadyStateFaceOutOfRange;
        const face = self.faces[face_index];
        const probe_difference_k: f64 = 1;
        const source_conductivity = try self.layerConductivityMMegajoulesPerHK(
            face.source_cell,
            probe_difference_k,
        );
        const destination_conductivity = try self.layerConductivityMMegajoulesPerHK(
            face.destination_cell,
            probe_difference_k,
        );
        const reference_temperature_k = 0.5 *
            (self.parameters.surface_temperature_k + self.parameters.base_temperature_k);
        const flux = try heat_flux.calculateFaceFlux(.{
            .source_temperature_k = reference_temperature_k + probe_difference_k,
            .destination_temperature_k = reference_temperature_k,
            .source_heat_capacity_megajoules_per_k = self.parameters.heat_capacity_megajoules_per_k,
            .destination_heat_capacity_megajoules_per_k = self.parameters.heat_capacity_megajoules_per_k,
            .source_minimum_heat_capacity_megajoules_per_k = 0,
            .destination_minimum_heat_capacity_megajoules_per_k = 0,
            .source_is_top_soil_layer = self.properties.is_top_soil_layer[face.source_cell],
            .top_snow_heat_capacity_megajoules_per_k = 0,
            .maximum_negligible_snow_heat_capacity_megajoules_per_k = 0,
            .snow_storage_heat_flux_megajoules = 0,
            .liquid_water_flux_m3 = 0,
            .vapor_flux_m3 = 0,
            .macropore_water_flux_m3 = 0,
            .liquid_water_heat_capacity_megajoules_per_m3_k = self.properties
                .liquid_water_heat_capacity_megajoules_per_m3_k,
            .source_thermal_conductivity_m_megajoules_per_h_k = source_conductivity,
            .destination_thermal_conductivity_m_megajoules_per_h_k = destination_conductivity,
            .source_path_length_m = face.source_path_length_m,
            .destination_path_length_m = face.destination_path_length_m,
            .face_area_m2 = face.face_area_m2,
            .time_fraction = self.properties.time_step_hours,
        });
        return .{
            // The unlimited conductive flux is `conductance * difference *
            // area * time_fraction`, and the probe difference is one kelvin.
            .megajoules_per_hour_k = flux.conductive_unlimited_megajoules / probe_difference_k,
            .equilibration_limiter_bound = flux.conductive_limited_megajoules !=
                flux.conductive_unlimited_megajoules,
        };
    }

    /// The analytical steady state: one flux through the whole chain, so the
    /// resistances add in series and each face drops `flux * resistance`.
    /// Nothing about the solver's iteration is used to derive this.
    pub fn analyticalSteadyProfile(self: Column, temperature_k: []f64) !SteadyProfile {
        const count = self.parameters.layer_count;
        if (temperature_k.len != count)
            return error.SteadyStateProfileDimensionMismatch;
        const top_resistance = try self.dirichletResistanceKHoursPerMegajoule(0);
        const base_resistance = try self.dirichletResistanceKHoursPerMegajoule(count - 1);
        var total = top_resistance + base_resistance;
        for (0..self.faces.len) |face_index|
            total += 1.0 / (try self.faceConductance(face_index)).megajoules_per_hour_k;
        if (!std.math.isFinite(total) or total <= 0)
            return error.InvalidSteadyStateResistance;
        const flux = (self.parameters.surface_temperature_k -
            self.parameters.base_temperature_k) / total;
        temperature_k[0] = self.parameters.surface_temperature_k - flux * top_resistance;
        for (1..count) |layer|
            temperature_k[layer] = temperature_k[layer - 1] -
                flux / (try self.faceConductance(layer - 1)).megajoules_per_hour_k;
        return .{
            .flux_megajoules_per_hour = flux,
            .total_resistance_k_hours_per_megajoule = total,
        };
    }

    pub fn setUniformTemperature(self: *Column, temperature_k: f64) void {
        @memset(self.grid.soil_temperature_k, temperature_k);
    }

    /// A deliberately wrong start: the boundary temperatures reversed, so the
    /// gradient the column must reach points the opposite way from the one it
    /// begins with.
    pub fn setInvertedTemperature(self: *Column) void {
        const count = self.parameters.layer_count;
        const span = self.parameters.base_temperature_k - self.parameters.surface_temperature_k;
        for (self.grid.soil_temperature_k, 0..) |*value, layer|
            value.* = self.parameters.base_temperature_k -
                span * @as(f64, @floatFromInt(layer)) / @as(f64, @floatFromInt(count - 1));
    }

    /// One hour of the production hourly heat operator, with the forcing held
    /// exactly constant.
    pub fn advanceHour(self: *Column) !heat_solver.Result {
        return heat_solver.solveWithWorkspace(
            &self.workspace,
            &self.grid,
            self.faces,
            self.properties,
            self.water_fluxes,
            self.heat_flux_megajoules,
            self.options,
        );
    }

    pub fn march(
        self: *Column,
        hours: usize,
        steady_temperature_k: []const f64,
    ) !MarchReport {
        if (hours == 0) return error.SteadyStateMarchTooShort;
        if (steady_temperature_k.len != self.parameters.layer_count)
            return error.SteadyStateProfileDimensionMismatch;
        var previous_deviation_k = deviation(self.grid.soil_temperature_k, steady_temperature_k);
        var report: MarchReport = .{
            .hours = hours,
            .largest_hourly_change_k = 0,
            .final_hourly_change_k = 0,
            .initial_deviation_k = previous_deviation_k,
            .final_deviation_k = 0,
            .deviation_decreased_every_hour = true,
            .final_boundary_input_megajoules = 0,
            .final_boundary_output_megajoules = 0,
            .largest_solver_iterations = 0,
        };
        for (0..hours) |_| {
            @memcpy(self.previous_temperature_k, self.grid.soil_temperature_k);
            const result = try self.advanceHour();
            report.largest_solver_iterations =
                @max(report.largest_solver_iterations, result.iterations);
            report.final_boundary_input_megajoules = result.boundary_heat_input_megajoules;
            report.final_boundary_output_megajoules = result.boundary_heat_output_megajoules;
            var change_k: f64 = 0;
            for (self.grid.soil_temperature_k, self.previous_temperature_k) |now, before|
                change_k = @max(change_k, @abs(now - before));
            report.final_hourly_change_k = change_k;
            report.largest_hourly_change_k = @max(report.largest_hourly_change_k, change_k);
            const current_deviation_k =
                deviation(self.grid.soil_temperature_k, steady_temperature_k);
            // A tie is not a failure: once the column is at its fixed point to
            // the last representable bit, the deviation stops decreasing
            // because there is nowhere left to go.
            if (current_deviation_k > previous_deviation_k)
                report.deviation_decreased_every_hour = false;
            previous_deviation_k = current_deviation_k;
            report.final_deviation_k = current_deviation_k;
        }
        return report;
    }
};

fn deviation(temperature_k: []const f64, reference_k: []const f64) f64 {
    var largest: f64 = 0;
    for (temperature_k, reference_k) |value, target|
        largest = @max(largest, @abs(value - target));
    return largest;
}

/// Measured amplification from the solver's DECLARED scaled convergence
/// tolerance to the temperature error of the state it actually settles on.
///
/// This is the central quantitative result of this module, and it is a
/// measurement, not an estimate. Marching the default column to a standstill
/// (`final_hourly_change_k` reaches exactly zero, so the accepted state has
/// genuinely stopped moving) at five tolerances, 2026-09-12, Debug:
///
/// | declared tolerance | distance from the analytical steady state |
/// | --- | --- |
/// | `1e-8`  | `1.1008e-4` K |
/// | `1e-10` | `1.0813e-6` K |
/// | `1e-12` | `1.0896e-8` K |
/// | `1e-14` | `1.0982e-10` K |
/// | `1e-16` | `3.5811e-12` K |
///
/// Four decades of exact first-order scaling, gain between `1.081e4` and
/// `1.101e4`, then a floor. Read it as: the solver does not land ON its fixed
/// point, it lands anywhere inside the ball its own tolerance admits, and that
/// ball is about ten thousand times wider in kelvin than the tolerance number
/// suggests. Anyone quoting `absolute_tolerance_k` as a temperature accuracy is
/// out by that factor.
pub const settled_error_gain_k: f64 = 1.1e4;

/// Where the tolerance stops governing and f64 representation takes over. The
/// `1e-16` row above is below one part in `1e13` of a 291 K temperature, so it
/// is the arithmetic, not the solver.
pub const settled_error_representation_floor_k: f64 = 4.0e-12;

/// Stated headroom over the four measurements, which span `1.081e4`-`1.101e4`.
/// A factor of two leaves room for release-mode reassociation without turning
/// the bound into an acceptance escape; the first-order scaling test below is
/// what actually pins the gain, to within a factor of two either way.
pub const settled_error_headroom: f64 = 2.0;

/// The honest bound on how close a converged march can come to the analytical
/// steady state, given what the solver was asked to converge to.
pub fn settledErrorBoundK(parameters: Parameters) f64 {
    const tolerance = @max(
        parameters.solver_absolute_tolerance_k,
        parameters.solver_relative_tolerance,
    );
    return settled_error_representation_floor_k +
        settled_error_headroom * settled_error_gain_k * tolerance;
}

test "conductivity does not vary with the face temperature difference" {
    // First premise of the analytical solution. It holds only because the
    // turbulence coefficients are zero, which pins both Nusselt numbers at
    // one; with a real Rayleigh coefficient conductivity would depend on the
    // gradient, the flux law would be nonlinear, and no series-resistance
    // steady state would exist to compare against.
    var column = try Column.init(std.testing.allocator, .{});
    defer column.deinit();
    for (0..column.parameters.layer_count) |layer| {
        const reference = try column.layerConductivityMMegajoulesPerHK(layer, 0);
        for ([_]f64{ 1, -1, 20, -20, 1e6 }) |difference_k|
            try std.testing.expectEqual(
                reference,
                try column.layerConductivityMMegajoulesPerHK(layer, difference_k),
            );
    }
}

test "the pair-equilibration limiter never binds on this column" {
    // Second premise. `calculateFaceFlux` clips the conductive flux to the
    // energy needed to equalize the pair. That ceiling and the unlimited flux
    // are both exactly linear in the temperature difference, so one probe
    // settles the verdict for every state the march can reach -- which is why
    // this is checkable at all rather than being a per-hour worry.
    var column = try Column.init(std.testing.allocator, .{});
    defer column.deinit();
    try std.testing.expect(column.faces.len > 0);
    for (0..column.faces.len) |face_index| {
        const conductance = try column.faceConductance(face_index);
        try std.testing.expect(!conductance.equilibration_limiter_bound);
        try std.testing.expect(conductance.megajoules_per_hour_k > 0);
    }
}

test "the analytical steady conduction profile is an exact fixed point of the production hourly solver" {
    // The central claim, and it holds EXACTLY: handed the series-resistance
    // profile, the production hourly operator returns it bit-for-bit
    // unchanged (measured drift `0e0`, 2026-09-12, Debug). Three independent
    // things have to agree for that: the interior flux law, the Dirichlet
    // boundary law, and the series-addition structure derived here.
    var column = try Column.init(std.testing.allocator, .{});
    defer column.deinit();
    const steady = try std.testing.allocator.alloc(f64, column.parameters.layer_count);
    defer std.testing.allocator.free(steady);
    const profile = try column.analyticalSteadyProfile(steady);
    try std.testing.expect(profile.flux_megajoules_per_hour > 0);

    // The profile must be genuinely piecewise linear. Measured drops are
    // 6.1605, 3.8655, 2.8336 and 2.2407 K, so a straight line between the two
    // boundary temperatures is nowhere near a solution and the fixed-point
    // check below cannot be satisfied by mere interpolation.
    try std.testing.expect(@abs((steady[0] - steady[1]) - (steady[1] - steady[2])) > 2);

    @memcpy(column.temperatureK(), steady);
    const result = try column.advanceHour();
    const drift_k = deviation(column.temperatureK(), steady);
    // Bound stated from arithmetic, not tuned: each cell's update is a
    // cancelling sum of at most four terms (two faces, one boundary, the base
    // temperature), so a genuine fixed point can be off by a few ULP of the
    // temperature itself and no more. Sixteen ULP at 291 K is 5.2e-13 K.
    const representation_floor_k =
        16 * std.math.floatEps(f64) * @max(@abs(steady[0]), @abs(steady[steady.len - 1]));
    try std.testing.expect(drift_k <= representation_floor_k);

    // Independent of the residual: `acceptedBoundaryHeat` recomputes both
    // boundary fluxes from the COMMITTED temperatures on its own code path. At
    // a steady state the column stores nothing, so the two must match, and
    // both must equal the analytically derived flux.
    try std.testing.expectApproxEqRel(
        profile.flux_megajoules_per_hour,
        result.boundary_heat_input_megajoules,
        1e-12,
    );
    try std.testing.expectApproxEqRel(
        result.boundary_heat_input_megajoules,
        result.boundary_heat_output_megajoules,
        1e-12,
    );
}

test "a uniform column reaches the textbook linear steady profile" {
    // The classical manufactured solution: constant conductivity and constant
    // thickness give equal temperature drops across every face. The ramped
    // default column deliberately does not have this property, so this test is
    // what shows the curvature above comes from the conductivity profile and
    // not from anything the solver added.
    var column = try Column.init(std.testing.allocator, .{
        .shallow_solid_conductivity_numerator_m_megajoules_per_h_k = 0.02,
        .deep_solid_conductivity_numerator_m_megajoules_per_h_k = 0.02,
    });
    defer column.deinit();
    const steady = try std.testing.allocator.alloc(f64, column.parameters.layer_count);
    defer std.testing.allocator.free(steady);
    _ = try column.analyticalSteadyProfile(steady);
    const first_drop_k = steady[0] - steady[1];
    try std.testing.expect(first_drop_k > 0);
    for (1..steady.len - 1) |layer|
        try std.testing.expectApproxEqRel(first_drop_k, steady[layer] - steady[layer + 1], 1e-12);

    @memcpy(column.temperatureK(), steady);
    _ = try column.advanceHour();
    const representation_floor_k = 16 * std.math.floatEps(f64) * @abs(steady[0]);
    try std.testing.expect(deviation(column.temperatureK(), steady) <= representation_floor_k);
}

test "constant forcing drives an arbitrary initial profile to the analytical steady state" {
    var column = try Column.init(std.testing.allocator, .{});
    defer column.deinit();
    const steady = try std.testing.allocator.alloc(f64, column.parameters.layer_count);
    defer std.testing.allocator.free(steady);
    _ = try column.analyticalSteadyProfile(steady);

    column.setUniformTemperature(285);
    const report = try column.march(1200, steady);
    try std.testing.expect(report.deviation_decreased_every_hour);
    // The march has to have actually travelled: an isothermal start is 8.99 K
    // from the steady profile, so "it stopped changing" is not satisfiable by a
    // column that began where it ended.
    try std.testing.expect(report.initial_deviation_k > 5);
    // And it has to have genuinely stopped, not merely slowed. This reaches
    // exactly zero in the measured run.
    try std.testing.expectEqual(@as(f64, 0), report.final_hourly_change_k);
    try std.testing.expect(report.final_deviation_k <= settledErrorBoundK(column.parameters));

    // The settled state sits inside the tolerance ball, not exactly on the
    // steady state, so the column is still storing a trickle -- and the two
    // boundary fluxes must differ by exactly that much. Bound derived from the
    // settling error and the boundary conductances rather than picked: 8.98e-8
    // MJ measured against a 7.0e-7 MJ bound. An earlier draft asserted a flat
    // 1e-8 MJ here, which is tighter than the solver's own tolerance permits
    // and would have read as a conservation defect.
    const imbalance_bound_megajoules = settledErrorBoundK(column.parameters) *
        try column.boundaryConductanceSumMegajoulesPerHourK();
    try std.testing.expectApproxEqAbs(
        report.final_boundary_input_megajoules,
        report.final_boundary_output_megajoules,
        imbalance_bound_megajoules,
    );
    // And it is a trickle: seven orders below the flux the column carries.
    try std.testing.expect(imbalance_bound_megajoules <
        1e-5 * report.final_boundary_input_megajoules);
}

test "the settled state converges first-order in the solver's declared tolerance" {
    // Tier 6 of `docs/validation.md`, and the result that makes the bound above
    // honest rather than magic. The solver does not land ON its fixed point; it
    // lands anywhere inside the ball its own tolerance admits, and that ball is
    // `settled_error_gain_k` times wider in kelvin than the tolerance number
    // reads. Asserting the RATIO across three decades pins the gain, so this
    // test fails both if the solver loses accuracy and if it silently stops
    // honouring the tolerance it was given.
    for ([_]f64{ 1e-8, 1e-10, 1e-12 }) |tolerance| {
        var column = try Column.init(std.testing.allocator, .{
            .solver_absolute_tolerance_k = tolerance,
            .solver_relative_tolerance = tolerance,
        });
        defer column.deinit();
        const steady = try std.testing.allocator.alloc(f64, column.parameters.layer_count);
        defer std.testing.allocator.free(steady);
        _ = try column.analyticalSteadyProfile(steady);
        column.setUniformTemperature(285);
        const report = try column.march(1200, steady);
        try std.testing.expectEqual(@as(f64, 0), report.final_hourly_change_k);
        const gain = report.final_deviation_k / tolerance;
        try std.testing.expect(gain > settled_error_gain_k / settled_error_headroom);
        try std.testing.expect(gain < settled_error_gain_k * settled_error_headroom);
    }
    // Below the fourth decade the tolerance stops governing: at `1e-16` the
    // measured error is `3.581e-12` K, which is representation rather than
    // convergence, so the first-order law above must NOT be extrapolated there.
    var floored = try Column.init(std.testing.allocator, .{
        .solver_absolute_tolerance_k = 1e-16,
        .solver_relative_tolerance = 1e-16,
    });
    defer floored.deinit();
    const steady = try std.testing.allocator.alloc(f64, floored.parameters.layer_count);
    defer std.testing.allocator.free(steady);
    _ = try floored.analyticalSteadyProfile(steady);
    floored.setUniformTemperature(285);
    const report = try floored.march(1200, steady);
    try std.testing.expect(report.final_deviation_k > settled_error_gain_k * 1e-16);
    try std.testing.expect(report.final_deviation_k <= settled_error_representation_floor_k);
}

test "two different initial profiles reach the same steady state" {
    // Uniqueness of the fixed point. The inverted start begins with the
    // gradient pointing the wrong way, 18.99 K from the steady profile, so it
    // has to cross that profile rather than approach it from one side.
    var column = try Column.init(std.testing.allocator, .{});
    defer column.deinit();
    const count = column.parameters.layer_count;
    const steady = try std.testing.allocator.alloc(f64, count);
    defer std.testing.allocator.free(steady);
    _ = try column.analyticalSteadyProfile(steady);
    const from_uniform = try std.testing.allocator.alloc(f64, count);
    defer std.testing.allocator.free(from_uniform);
    const bound_k = settledErrorBoundK(column.parameters);

    column.setUniformTemperature(285);
    const uniform_report = try column.march(1200, steady);
    @memcpy(from_uniform, column.temperatureK());

    column.setInvertedTemperature();
    const inverted_report = try column.march(1200, steady);
    try std.testing.expect(inverted_report.initial_deviation_k >
        uniform_report.initial_deviation_k);
    try std.testing.expect(inverted_report.final_deviation_k <= bound_k);
    // Both settle inside the same tolerance ball, so they can differ by at most
    // its width. They in fact agree far better than that -- 1.04e-8 K measured,
    // against a 2.2e-6 K ball -- and that tighter number is pinned separately
    // so a regression in it is visible.
    for (column.temperatureK(), from_uniform) |from_inverted, uniform| {
        try std.testing.expectApproxEqAbs(uniform, from_inverted, bound_k);
        try std.testing.expectApproxEqAbs(uniform, from_inverted, 1e-7);
    }
}

test "moving one boundary temperature moves the fixed point by the predicted amount" {
    // Non-vacuity control. Everything above would also pass on a solver that
    // ignored its boundaries and froze the initial state, so the response to a
    // CHANGE in the constant forcing is checked too -- and checked against the
    // analytical profile for the new boundary, not against a tolerance.
    var column = try Column.init(std.testing.allocator, .{});
    defer column.deinit();
    const count = column.parameters.layer_count;
    const steady = try std.testing.allocator.alloc(f64, count);
    defer std.testing.allocator.free(steady);
    _ = try column.analyticalSteadyProfile(steady);
    column.setUniformTemperature(285);
    _ = try column.march(1200, steady);

    const warmed_base_k = column.parameters.base_temperature_k + 5;
    column.parameters.base_temperature_k = warmed_base_k;
    column.boundary_temperature_k[1] = warmed_base_k;
    const warmed_steady = try std.testing.allocator.alloc(f64, count);
    defer std.testing.allocator.free(warmed_steady);
    const warmed_profile = try column.analyticalSteadyProfile(warmed_steady);
    // Warming the lower boundary must shrink the downward flux and lift every
    // layer. Neither is asserted by construction anywhere above.
    try std.testing.expect(warmed_profile.flux_megajoules_per_hour > 0);
    for (warmed_steady, steady) |warmed, original|
        try std.testing.expect(warmed > original);

    const report = try column.march(1200, warmed_steady);
    // The fixed point genuinely moved: the column started this march at the
    // OLD steady state, 4.75 K from the new one.
    try std.testing.expect(report.initial_deviation_k > 3);
    try std.testing.expect(report.final_deviation_k <= settledErrorBoundK(column.parameters));
}

test "a degenerate or out-of-domain column is rejected instead of silently succeeding" {
    // An isothermal pair of boundaries has a steady state, but it is the
    // uniform profile, which every check above would pass without exercising
    // conduction at all.
    try std.testing.expectError(
        error.InvalidSteadyStateParameter,
        Column.init(std.testing.allocator, .{ .surface_temperature_k = 280, .base_temperature_k = 280 }),
    );
    // One layer has no interior face, so there is no series structure to test.
    try std.testing.expectError(
        error.InvalidSteadyStateParameter,
        Column.init(std.testing.allocator, .{ .layer_count = 1 }),
    );
    try std.testing.expectError(
        error.InvalidSteadyStateParameter,
        Column.init(std.testing.allocator, .{ .layer_thickness_m = 0 }),
    );
    // Outside the band that keeps the whole march inside the solver's own
    // [173.15, 373.15] K physical domain.
    try std.testing.expectError(
        error.InvalidSteadyStateParameter,
        Column.init(std.testing.allocator, .{ .surface_temperature_k = 350 }),
    );
    // A tolerance of one or more is not a convergence criterion.
    try std.testing.expectError(
        error.InvalidSteadyStateParameter,
        Column.init(std.testing.allocator, .{ .solver_relative_tolerance = 1 }),
    );
    try std.testing.expectError(
        error.NonFiniteSteadyStateParameter,
        Column.init(std.testing.allocator, .{ .face_area_m2 = std.math.nan(f64) }),
    );
}

test "dimensions and indices are checked rather than assumed" {
    var column = try Column.init(std.testing.allocator, .{});
    defer column.deinit();
    var wrong_size: [2]f64 = undefined;
    try std.testing.expectError(
        error.SteadyStateProfileDimensionMismatch,
        column.analyticalSteadyProfile(&wrong_size),
    );
    try std.testing.expectError(
        error.SteadyStateLayerOutOfRange,
        column.layerConductivityMMegajoulesPerHK(column.parameters.layer_count, 0),
    );
    try std.testing.expectError(
        error.SteadyStateFaceOutOfRange,
        column.faceConductance(column.faces.len),
    );
    const steady = try std.testing.allocator.alloc(f64, column.parameters.layer_count);
    defer std.testing.allocator.free(steady);
    try std.testing.expectError(
        error.SteadyStateMarchTooShort,
        column.march(0, steady),
    );
    try std.testing.expectError(
        error.SteadyStateProfileDimensionMismatch,
        column.march(1, &wrong_size),
    );
}

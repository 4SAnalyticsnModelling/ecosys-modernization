const std = @import("std");
const builtin = @import("builtin");
const grid_module = @import("../state/grid.zig");
const hydrology_module = @import("../transport/hydrology.zig");
const solute = @import("../soil/solute/transport.zig");
const solute_solver = @import("../soil/solute/transport_solver.zig");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const snow_solver = @import("../soil/water/snow_transport_solver.zig");
const surface = @import("../soil/solute/surface_solute_routing.zig");
const gas = @import("../soil/gas/transport.zig");
const gas_solver = @import("../soil/gas/coupled_gas_solver.zig");
const snow_drift = @import("../soil/water/snow_drift_routing.zig");
const external_solute = @import("../soil/solute/external_boundaries.zig");
const charge_classification = @import("../soil/solute/charge_classification.zig");
const transport_species = @import("../soil/solute/transport_species.zig");
const scoped_conservation = @import("../validation/scoped_conservation.zig");

pub const ZoneFractionProvider = struct {
    context: *const anyopaque,
    at: *const fn (*const anyopaque, usize) anyerror!charge_classification.ZoneFractions,
};

pub const Inputs = struct {
    micropore_diffusive_conductance_m3_per_step: []const f64,
    macropore_diffusive_conductance_m3_per_step: []const f64,
    micropore_mobility_fraction: []const f64,
    macropore_mobility_fraction: []const f64,
    maximum_convective_fraction: f64,
    /// Runtime geometric layer volume (`VOLT`) used by TRNSFRS XFRS exchange.
    layer_volume_m3: []const f64,
    /// Per-layer macropore spacing (`PHOL`-derived) used to set the physical
    /// micropore/macropore exchange rate (SOLUTE-XFRS-PHYSICAL).
    macropore_spacing_m: []const f64,
    /// Per-layer, temperature-adjusted micropore diffusivity (already
    /// tortuosity/temperature-scaled by the caller) for the same exchange.
    micropore_diffusivity_m2_per_h: []const f64,
    /// Fraction of the hourly exchange applied by this converged solve.
    pore_exchange_step_fraction: f64,
    boundary_mobility_fraction: []const f64,
    recharge_concentration_mol_per_m3: []const f64,
    solute_solver_options: solute_solver.Options,
    gas_solver_inputs: gas_solver.Inputs,
    gas_solver_options: gas_solver.Options,
    snow_atmospheric_top_input_g: []const f64,
    snow_surface_partitions: []const snow.SurfacePartition,
    snow_solver_options: snow_solver.Options,
    snow_drift_boundaries: surface.BoundaryConditions,
    snow_drift_maximum_transport_fraction: f64,
    runoff_boundaries: surface.BoundaryConditions,
    runoff_maximum_transport_fraction: f64,
};

pub const Outputs = struct {
    snow_surface_discharge: []snow.SurfaceDischarge,
    runoff_exported_mol: []f64,
    snow_drift_exported_g: []f64,
    snow_drift_exported_salt_mol: []f64,
};

pub const Result = struct {
    micropore: solute_solver.Result,
    macropore: solute_solver.Result,
    gas: gas_solver.Result,
    snowpack: snow_solver.Result,
};

pub const SoilSoluteInputs = struct {
    micropore_diffusive_conductance_m3_per_step: []const f64,
    macropore_diffusive_conductance_m3_per_step: []const f64,
    micropore_mobility_fraction: []const f64,
    macropore_mobility_fraction: []const f64,
    layer_volume_m3: []const f64,
    /// Per-layer macropore spacing (`PHOL`-derived) used to set the physical
    /// micropore/macropore exchange rate (SOLUTE-XFRS-PHYSICAL).
    macropore_spacing_m: []const f64,
    /// Per-layer, temperature-adjusted micropore diffusivity (already
    /// tortuosity/temperature-scaled by the caller) for the same exchange.
    micropore_diffusivity_m2_per_h: []const f64,
    maximum_convective_fraction: f64,
    pore_exchange_step_fraction: f64,
    boundary_mobility_fraction: []const f64,
    /// STARTE-equilibrated, unweighted base concentrations. Production binds
    /// the live fertilizer-zone geometry at every accepted transport attempt.
    recharge_concentration_mol_per_m3: []const f64,
    recharge_zone_fraction_provider: ?ZoneFractionProvider = null,
    /// Optional cell-major signed boundary ledger; positive enters the model.
    boundary_net_flux_mol_by_cell: ?[]f64 = null,
    /// Optional exact accepted ledgers indexed face × runtime species.
    micropore_face_flux_mol_by_component: ?[]f64 = null,
    macropore_face_flux_mol_by_component: ?[]f64 = null,
    /// Conservation acceptance is independent of nonlinear convergence.
    /// Production supplies the configured per-area amount tolerance and the
    /// horizontal cell areas; isolated callers retain only a representation
    /// floor plus this separate relative tolerance.
    conservation_absolute_tolerance_mol_per_m2: f64 = 0,
    conservation_relative_tolerance: f64 = 512 * std.math.floatEps(f64),
    horizontal_cell_area_m2: []const f64 = &.{},
    /// Test-only accepted-state corruption used to prove local cancellation
    /// cannot pass the gate. Rejected in non-test builds.
    test_conservation_perturbation_mol_by_component: ?[]const f64 = null,
    solver_options: solute_solver.Options,
};

pub const SoilSoluteResult = struct {
    micropore: solute_solver.Result,
    macropore: solute_solver.Result,
};

/// Converges the two implicit face systems against heap-owned scratch states
/// and publishes exact accepted ledgers without mutating authoritative soil
/// inventories. This is the first pass of the serial out-of-core transaction.
pub fn solveSoilFaceFluxesDeferred(
    allocator: std.mem.Allocator,
    grid: *const grid_module.GridState,
    faces: *const hydrology_module.SoilFaces,
    micropore: *const solute.State,
    macropore: *const solute.State,
    inputs: SoilSoluteInputs,
) !SoilSoluteResult {
    if (micropore.cell_count != grid.layer_count or
        macropore.cell_count != grid.layer_count or
        micropore.species_count != macropore.species_count)
        return error.TransportStepDimensionMismatch;
    const face_components = try std.math.mul(
        usize,
        faces.micropore_faces.len,
        micropore.species_count,
    );
    const micropore_ledger =
        inputs.micropore_face_flux_mol_by_component orelse
        return error.DeferredTransportRequiresMicroporeFaceLedger;
    const macropore_ledger =
        inputs.macropore_face_flux_mol_by_component orelse
        return error.DeferredTransportRequiresMacroporeFaceLedger;
    if (micropore_ledger.len != face_components or
        macropore_ledger.len != face_components or
        inputs.micropore_diffusive_conductance_m3_per_step.len !=
            face_components or
        inputs.macropore_diffusive_conductance_m3_per_step.len !=
            face_components or
        inputs.micropore_mobility_fraction.len != face_components or
        inputs.macropore_mobility_fraction.len != face_components)
        return error.TransportStepFaceParameterSizeMismatch;
    var micropore_scratch = try solute.State.init(
        allocator,
        micropore.cell_count,
        micropore.species_count,
    );
    defer micropore_scratch.deinit();
    var macropore_scratch = try solute.State.init(
        allocator,
        macropore.cell_count,
        macropore.species_count,
    );
    defer macropore_scratch.deinit();
    @memcpy(
        micropore_scratch.water_volume_m3,
        grid.matrix_liquid_water_m3,
    );
    @memcpy(
        macropore_scratch.water_volume_m3,
        grid.macropore_liquid_water_m3,
    );
    @memcpy(micropore_scratch.amount_mol, micropore.amount_mol);
    @memcpy(macropore_scratch.amount_mol, macropore.amount_mol);
    var micropore_options = inputs.solver_options;
    micropore_options.face_flux_mol_by_component = micropore_ledger;
    var macropore_options = inputs.solver_options;
    macropore_options.face_flux_mol_by_component = macropore_ledger;
    const micropore_result = try solute_solver.solve(
        allocator,
        &micropore_scratch,
        faces.micropore_faces,
        inputs.micropore_diffusive_conductance_m3_per_step,
        inputs.micropore_mobility_fraction,
        .{
            .maximum_convective_fraction = inputs.maximum_convective_fraction,
        },
        micropore_options,
    );
    const macropore_result = try solute_solver.solve(
        allocator,
        &macropore_scratch,
        faces.macropore_faces,
        inputs.macropore_diffusive_conductance_m3_per_step,
        inputs.macropore_mobility_fraction,
        .{
            .maximum_convective_fraction = inputs.maximum_convective_fraction,
        },
        macropore_options,
    );
    return .{
        .micropore = micropore_result,
        .macropore = macropore_result,
    };
}

/// Applies only cell-local external-boundary and dual-domain exchange after
/// accepted face ledgers have been state_updateted from Morton tile files.
pub fn advanceSoilLocalSoluteProcesses(
    allocator: std.mem.Allocator,
    grid: *const grid_module.GridState,
    hydrology: *hydrology_module.State,
    active_by_layer: []const bool,
    micropore: *solute.State,
    macropore: *solute.State,
    inputs: SoilSoluteInputs,
) !void {
    if (micropore.cell_count != grid.layer_count or
        macropore.cell_count != grid.layer_count or
        micropore.species_count != macropore.species_count or
        inputs.layer_volume_m3.len != grid.layer_count or
        inputs.macropore_spacing_m.len != grid.layer_count or
        inputs.micropore_diffusivity_m2_per_h.len != grid.layer_count or
        active_by_layer.len != grid.layer_count or
        inputs.boundary_mobility_fraction.len != micropore.species_count or
        inputs.recharge_concentration_mol_per_m3.len !=
            micropore.amount_mol.len)
        return error.TransportStepDimensionMismatch;
    if (inputs.boundary_net_flux_mol_by_cell) |ledger|
        if (ledger.len != micropore.amount_mol.len)
            return error.TransportStepDimensionMismatch;
    if (!std.math.isFinite(inputs.pore_exchange_step_fraction) or
        inputs.pore_exchange_step_fraction < 0 or
        inputs.pore_exchange_step_fraction > 1)
        return error.InvalidPoreExchangeStepFraction;
    @memcpy(micropore.water_volume_m3, grid.matrix_liquid_water_m3);
    @memcpy(macropore.water_volume_m3, grid.macropore_liquid_water_m3);
    const micro_before = try allocator.dupe(f64, micropore.amount_mol);
    defer allocator.free(micro_before);
    const macro_before = try allocator.dupe(f64, macropore.amount_mol);
    defer allocator.free(macro_before);
    var state_updateted = false;
    defer if (!state_updateted) {
        @memcpy(micropore.amount_mol, micro_before);
        @memcpy(macropore.amount_mol, macro_before);
    };
    const boundary_flux_mol = try allocator.alloc(
        f64,
        micropore.species_count,
    );
    defer allocator.free(boundary_flux_mol);
    const recharge_scratch = if (inputs.recharge_zone_fraction_provider != null)
        try allocator.alloc(f64, micropore.species_count)
    else
        null;
    defer if (recharge_scratch) |scratch| allocator.free(scratch);
    const boundary_ledger = try allocator.alloc(
        f64,
        micropore.amount_mol.len,
    );
    defer allocator.free(boundary_ledger);
    @memset(boundary_ledger, 0);
    for (0..grid.layer_count) |cell| {
        if (!active_by_layer[cell]) continue;
        const recharge = try rechargeConcentrationsForLayer(
            inputs.recharge_concentration_mol_per_m3[cell * micropore.species_count ..][0..micropore.species_count],
            cell,
            inputs.recharge_zone_fraction_provider,
            recharge_scratch,
        );
        try external_solute.calculateNetFluxMol(
            micropore,
            .{
                .cell_index = cell,
                .outward_water_flux_m3_per_step = hydrology.micropore_external_water_flux_m3_per_step[cell],
            },
            inputs.maximum_convective_fraction,
            inputs.boundary_mobility_fraction,
            recharge,
            boundary_flux_mol,
            false,
        );
        for (
            boundary_flux_mol,
            boundary_ledger[cell * micropore.species_count ..][0..micropore.species_count],
        ) |change, *total| total.* += change;
        try external_solute.state_updateCellNetFlux(
            micropore,
            cell,
            boundary_flux_mol,
        );
        try external_solute.calculateNetFluxMol(
            macropore,
            .{
                .cell_index = cell,
                .outward_water_flux_m3_per_step = hydrology.macropore_external_water_flux_m3_per_step[cell],
            },
            inputs.maximum_convective_fraction,
            inputs.boundary_mobility_fraction,
            recharge,
            boundary_flux_mol,
            true,
        );
        for (
            boundary_flux_mol,
            boundary_ledger[cell * micropore.species_count ..][0..micropore.species_count],
        ) |change, *total| total.* += change;
        try external_solute.state_updateCellNetFlux(
            macropore,
            cell,
            boundary_flux_mol,
        );
    }
    for (0..grid.layer_count) |cell| {
        if (!active_by_layer[cell]) continue;
        for (0..micropore.species_count) |species_index| {
            const component =
                cell * micropore.species_count + species_index;
            const convective_flux_mol = try solute.calculateConvectivePoreExchangeFlux(
                micropore.amount_mol[component],
                macropore.amount_mol[component],
                micropore.water_volume_m3[cell],
                macropore.water_volume_m3[cell],
                hydrology.macropore_to_matrix_water_flux_m3_per_step[cell],
                inputs.maximum_convective_fraction,
            );
            try solute.state_updatePoreExchange(
                &micropore.amount_mol[component],
                &macropore.amount_mol[component],
                convective_flux_mol,
            );
            const flux_mol = try solute.calculatePoreExchangeFlux(
                micropore.amount_mol[component],
                macropore.amount_mol[component],
                micropore.water_volume_m3[cell],
                macropore.water_volume_m3[cell],
                inputs.layer_volume_m3[cell],
                inputs.pore_exchange_step_fraction,
                inputs.macropore_spacing_m[cell],
                inputs.micropore_diffusivity_m2_per_h[cell],
            );
            try solute.state_updatePoreExchange(
                &micropore.amount_mol[component],
                &macropore.amount_mol[component],
                flux_mol,
            );
        }
    }
    if (inputs.boundary_net_flux_mol_by_cell) |ledger|
        @memcpy(ledger, boundary_ledger);
    state_updateted = true;
}

/// Advances only the soil aqueous portion of TRNSFRS from an already converged
/// water-flux snapshot. This is independently transactional so callers do not
/// need to fabricate gas, snow, or runoff inputs to activate soil transport.
pub fn advanceSoilSolutes(allocator: std.mem.Allocator, grid: *const grid_module.GridState, hydrology: *hydrology_module.State, faces: *const hydrology_module.SoilFaces, micropore: *solute.State, macropore: *solute.State, inputs: SoilSoluteInputs) !SoilSoluteResult {
    if (micropore.cell_count != grid.layer_count or macropore.cell_count != grid.layer_count or micropore.species_count != macropore.species_count or inputs.layer_volume_m3.len != grid.layer_count or inputs.macropore_spacing_m.len != grid.layer_count or inputs.micropore_diffusivity_m2_per_h.len != grid.layer_count or inputs.boundary_mobility_fraction.len != micropore.species_count or inputs.recharge_concentration_mol_per_m3.len != micropore.amount_mol.len) return error.TransportStepDimensionMismatch;
    if (inputs.boundary_net_flux_mol_by_cell) |ledger| if (ledger.len != micropore.amount_mol.len) return error.TransportStepDimensionMismatch;
    if (!std.math.isFinite(inputs.pore_exchange_step_fraction) or inputs.pore_exchange_step_fraction < 0 or inputs.pore_exchange_step_fraction > 1) return error.InvalidPoreExchangeStepFraction;
    const face_components = try std.math.mul(usize, faces.micropore_faces.len, micropore.species_count);
    if (inputs.micropore_diffusive_conductance_m3_per_step.len != face_components or inputs.macropore_diffusive_conductance_m3_per_step.len != face_components or inputs.micropore_mobility_fraction.len != face_components or inputs.macropore_mobility_fraction.len != face_components) return error.TransportStepFaceParameterSizeMismatch;
    if (inputs.micropore_face_flux_mol_by_component) |fluxes| if (fluxes.len != face_components) return error.TransportStepFaceFluxOutputSizeMismatch;
    if (inputs.macropore_face_flux_mol_by_component) |fluxes| if (fluxes.len != face_components) return error.TransportStepFaceFluxOutputSizeMismatch;
    if (!std.math.isFinite(inputs.conservation_absolute_tolerance_mol_per_m2) or inputs.conservation_absolute_tolerance_mol_per_m2 < 0 or
        !std.math.isFinite(inputs.conservation_relative_tolerance) or inputs.conservation_relative_tolerance < 0 or
        (inputs.horizontal_cell_area_m2.len != 0 and inputs.horizontal_cell_area_m2.len != grid.cell_count))
        return error.InvalidSoilSoluteConservationTolerance;
    if (inputs.test_conservation_perturbation_mol_by_component) |perturbation| {
        if (!builtin.is_test) return error.InvalidSoilSoluteConservationTestControl;
        if (perturbation.len != micropore.amount_mol.len) return error.TransportStepDimensionMismatch;
    }
    @memcpy(micropore.water_volume_m3, grid.matrix_liquid_water_m3);
    @memcpy(macropore.water_volume_m3, grid.macropore_liquid_water_m3);
    const micro_before = try allocator.dupe(f64, micropore.amount_mol);
    defer allocator.free(micro_before);
    const macro_before = try allocator.dupe(f64, macropore.amount_mol);
    defer allocator.free(macro_before);
    const micropore_face_flux_scratch = try allocator.alloc(f64, face_components);
    defer allocator.free(micropore_face_flux_scratch);
    const macropore_face_flux_scratch = try allocator.alloc(f64, face_components);
    defer allocator.free(macropore_face_flux_scratch);
    var state_updateted = false;
    defer if (!state_updateted) {
        @memcpy(micropore.amount_mol, micro_before);
        @memcpy(macropore.amount_mol, macro_before);
    };
    var micropore_options = inputs.solver_options;
    micropore_options.face_flux_mol_by_component = micropore_face_flux_scratch;
    var macropore_options = inputs.solver_options;
    macropore_options.face_flux_mol_by_component = macropore_face_flux_scratch;
    const micro_result = try solute_solver.solve(allocator, micropore, faces.micropore_faces, inputs.micropore_diffusive_conductance_m3_per_step, inputs.micropore_mobility_fraction, .{ .maximum_convective_fraction = inputs.maximum_convective_fraction }, micropore_options);
    const macro_result = try solute_solver.solve(allocator, macropore, faces.macropore_faces, inputs.macropore_diffusive_conductance_m3_per_step, inputs.macropore_mobility_fraction, .{ .maximum_convective_fraction = inputs.maximum_convective_fraction }, macropore_options);
    const boundary_flux_mol = try allocator.alloc(f64, micropore.species_count);
    defer allocator.free(boundary_flux_mol);
    const recharge_scratch = if (inputs.recharge_zone_fraction_provider != null)
        try allocator.alloc(f64, micropore.species_count)
    else
        null;
    defer if (recharge_scratch) |scratch| allocator.free(scratch);
    const boundary_ledger = try allocator.alloc(f64, micropore.amount_mol.len);
    defer allocator.free(boundary_ledger);
    @memset(boundary_ledger, 0);
    for (0..grid.layer_count) |cell| {
        if (!faces.active_by_layer[cell]) continue;
        const recharge = try rechargeConcentrationsForLayer(
            inputs.recharge_concentration_mol_per_m3[cell * micropore.species_count ..][0..micropore.species_count],
            cell,
            inputs.recharge_zone_fraction_provider,
            recharge_scratch,
        );
        try external_solute.calculateNetFluxMol(micropore, .{ .cell_index = cell, .outward_water_flux_m3_per_step = hydrology.micropore_external_water_flux_m3_per_step[cell] }, inputs.maximum_convective_fraction, inputs.boundary_mobility_fraction, recharge, boundary_flux_mol, false);
        for (boundary_flux_mol, boundary_ledger[cell * micropore.species_count ..][0..micropore.species_count]) |change, *total| total.* += change;
        try external_solute.state_updateCellNetFlux(micropore, cell, boundary_flux_mol);
        try external_solute.calculateNetFluxMol(macropore, .{ .cell_index = cell, .outward_water_flux_m3_per_step = hydrology.macropore_external_water_flux_m3_per_step[cell] }, inputs.maximum_convective_fraction, inputs.boundary_mobility_fraction, recharge, boundary_flux_mol, true);
        for (boundary_flux_mol, boundary_ledger[cell * micropore.species_count ..][0..micropore.species_count]) |change, *total| total.* += change;
        try external_solute.state_updateCellNetFlux(macropore, cell, boundary_flux_mol);
    }
    for (0..grid.layer_count) |cell| {
        if (!faces.active_by_layer[cell]) continue;
        for (0..micropore.species_count) |species_index| {
            const component = cell * micropore.species_count + species_index;
            const convective_flux_mol = try solute.calculateConvectivePoreExchangeFlux(micropore.amount_mol[component], macropore.amount_mol[component], micropore.water_volume_m3[cell], macropore.water_volume_m3[cell], hydrology.macropore_to_matrix_water_flux_m3_per_step[cell], inputs.maximum_convective_fraction);
            try solute.state_updatePoreExchange(&micropore.amount_mol[component], &macropore.amount_mol[component], convective_flux_mol);
            const flux_mol = try solute.calculatePoreExchangeFlux(micropore.amount_mol[component], macropore.amount_mol[component], micropore.water_volume_m3[cell], macropore.water_volume_m3[cell], inputs.layer_volume_m3[cell], inputs.pore_exchange_step_fraction, inputs.macropore_spacing_m[cell], inputs.micropore_diffusivity_m2_per_h[cell]);
            try solute.state_updatePoreExchange(&micropore.amount_mol[component], &macropore.amount_mol[component], flux_mol);
        }
    }
    if (inputs.test_conservation_perturbation_mol_by_component) |perturbation|
        for (micropore.amount_mol, perturbation) |*amount, change| {
            amount.* += change;
            if (!std.math.isFinite(amount.*) or amount.* < 0)
                return error.InvalidSoilSoluteConservationTestControl;
        };
    try requireLocalSoilSoluteConservation(
        allocator,
        grid,
        faces,
        micro_before,
        macro_before,
        micropore.amount_mol,
        macropore.amount_mol,
        boundary_ledger,
        micropore_face_flux_scratch,
        macropore_face_flux_scratch,
        micropore.species_count,
        inputs,
    );
    if (inputs.boundary_net_flux_mol_by_cell) |ledger| @memcpy(ledger, boundary_ledger);
    if (inputs.micropore_face_flux_mol_by_component) |ledger|
        @memcpy(ledger, micropore_face_flux_scratch);
    if (inputs.macropore_face_flux_mol_by_component) |ledger|
        @memcpy(ledger, macropore_face_flux_scratch);
    state_updateted = true;
    return .{ .micropore = micro_result, .macropore = macro_result };
}

fn rechargeConcentrationsForLayer(
    base_mol_per_m3: []const f64,
    layer: usize,
    provider: ?ZoneFractionProvider,
    scratch: ?[]f64,
) ![]const f64 {
    const source = provider orelse return base_mol_per_m3;
    if (base_mol_per_m3.len != transport_species.AqueousSpecies.count)
        return error.TransportStepSpeciesIdentityMismatch;
    const output = scratch orelse return error.TransportStepMissingRechargeScratch;
    if (output.len != base_mol_per_m3.len)
        return error.TransportStepDimensionMismatch;
    const fractions = try source.at(source.context, layer);
    try validateRechargeZoneFractions(fractions);
    inline for (@typeInfo(transport_species.AqueousSpecies).@"enum".fields) |field| {
        const species: transport_species.AqueousSpecies = @enumFromInt(field.value);
        const concentration = base_mol_per_m3[field.value];
        if (!std.math.isFinite(concentration) or concentration < 0)
            return error.InvalidRechargeConcentration;
        output[field.value] = concentration * transport_species.zoneFraction(species, .{
            .phosphate_non_band = fractions.phosphate_non_band,
            .phosphate_band = fractions.phosphate_band,
        });
    }
    return output;
}

fn validateRechargeZoneFractions(fractions: charge_classification.ZoneFractions) !void {
    const values = [_]f64{
        fractions.ammonium_non_band,
        fractions.ammonium_band,
        fractions.nitrate_non_band,
        fractions.nitrate_band,
        fractions.phosphate_non_band,
        fractions.phosphate_band,
    };
    for (values) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidRechargeZoneFractions;
    const pair_tolerance = 64 * std.math.floatEps(f64);
    if (@abs(fractions.ammonium_non_band + fractions.ammonium_band - 1) > pair_tolerance or
        @abs(fractions.nitrate_non_band + fractions.nitrate_band - 1) > pair_tolerance or
        @abs(fractions.phosphate_non_band + fractions.phosphate_band - 1) > pair_tolerance)
        return error.InvalidRechargeZoneFractions;
}

test "recharge applies live per-layer phosphate fractions without mutating its base reservoir" {
    const Provider = struct {
        fn at(_: *const anyopaque, layer: usize) anyerror!charge_classification.ZoneFractions {
            const phosphate_band: f64 = if (layer == 0) 0.2 else 0.8;
            return .{
                .ammonium_non_band = 0.7,
                .ammonium_band = 0.3,
                .nitrate_non_band = 0.6,
                .nitrate_band = 0.4,
                .phosphate_non_band = 1 - phosphate_band,
                .phosphate_band = phosphate_band,
            };
        }
    };
    var base: [transport_species.AqueousSpecies.count]f64 = undefined;
    @memset(&base, 1);
    const base_before = base;
    var scratch: [transport_species.AqueousSpecies.count]f64 = undefined;
    const provider: ZoneFractionProvider = .{
        .context = @ptrCast(&base),
        .at = Provider.at,
    };

    const layer_zero = try rechargeConcentrationsForLayer(&base, 0, provider, &scratch);
    try std.testing.expectEqual(@as(f64, 1), layer_zero[@intFromEnum(transport_species.AqueousSpecies.calcium)]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), layer_zero[@intFromEnum(transport_species.AqueousSpecies.non_band_hpo4)], 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), layer_zero[@intFromEnum(transport_species.AqueousSpecies.band_hpo4)], 64 * std.math.floatEps(f64));

    const layer_one = try rechargeConcentrationsForLayer(&base, 1, provider, &scratch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), layer_one[@intFromEnum(transport_species.AqueousSpecies.non_band_hpo4)], 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), layer_one[@intFromEnum(transport_species.AqueousSpecies.band_hpo4)], 64 * std.math.floatEps(f64));
    try std.testing.expectEqualSlices(f64, &base_before, &base);
}

/// Independent per-layer x species closure over both pore domains. Pore
/// exchange cancels inside the local scope; every accepted face and signed
/// domain-boundary amount remains explicit, so opposing layer defects cannot
/// disappear in a column or domain reduction.
fn requireLocalSoilSoluteConservation(
    allocator: std.mem.Allocator,
    grid: *const grid_module.GridState,
    faces: *const hydrology_module.SoilFaces,
    micropore_before: []const f64,
    macropore_before: []const f64,
    micropore_after: []const f64,
    macropore_after: []const f64,
    boundary_net_flux_mol: []const f64,
    micropore_face_flux_mol: []const f64,
    macropore_face_flux_mol: []const f64,
    species_count: usize,
    inputs: SoilSoluteInputs,
) !void {
    const signed_activity = try allocator.dupe(f64, boundary_net_flux_mol);
    defer allocator.free(signed_activity);
    for (faces.micropore_faces, faces.macropore_faces, 0..) |micro_face, macro_face, face| {
        if (!faces.active_by_face[face]) continue;
        for (0..species_count) |species| {
            const face_component = face * species_count + species;
            const micro_flux = micropore_face_flux_mol[face_component];
            signed_activity[micro_face.first_cell * species_count + species] -= micro_flux;
            signed_activity[micro_face.second_cell * species_count + species] += micro_flux;
            const macro_flux = macropore_face_flux_mol[face_component];
            signed_activity[macro_face.first_cell * species_count + species] -= macro_flux;
            signed_activity[macro_face.second_cell * species_count + species] += macro_flux;
        }
    }
    for (0..grid.layer_count) |layer| {
        if (!faces.active_by_layer[layer]) continue;
        const horizontal_cell = layer / grid.soil_layer_capacity;
        for (0..species_count) |species| {
            const component = layer * species_count + species;
            const storage_before = micropore_before[component] + macropore_before[component];
            const storage_after = micropore_after[component] + macropore_after[component];
            const representation_floor = 64 * std.math.floatEps(f64) *
                @max(1, @max(@abs(storage_before), @abs(storage_after)));
            const configured_absolute = if (inputs.horizontal_cell_area_m2.len == 0)
                0
            else
                inputs.conservation_absolute_tolerance_mol_per_m2 * inputs.horizontal_cell_area_m2[horizontal_cell];
            const closure = try scoped_conservation.evaluate(.{
                .storage_before = storage_before,
                .storage_after = storage_after,
                .external_inputs = if (signed_activity[component] >= 0) signed_activity[component] else 0,
                .external_outputs = if (signed_activity[component] < 0) -signed_activity[component] else 0,
            }, .{
                .absolute = @max(configured_absolute, representation_floor),
                .relative = inputs.conservation_relative_tolerance,
            });
            if (!closure.accepted) {
                if (!builtin.is_test) std.log.err(
                    "soil aqueous local conservation failure: layer={d} species={d} residual_mol={e} absolute_mol={e} normalized_relative={e} limit_mol={e}",
                    .{ layer, species, closure.residual, closure.absolute, closure.normalized_relative, closure.acceptance_limit },
                );
                return error.SoilSoluteLocalConservationFailure;
            }
        }
    }
}

/// Executes the water-driven transport kernels from one consistent hydrology
/// snapshot. All four inventories roll back if any solver or routing stage
/// fails; output buffers are published only after the complete step succeeds.
pub fn advance(allocator: std.mem.Allocator, grid: *const grid_module.GridState, hydrology: *hydrology_module.State, micropore: *solute.State, macropore: *solute.State, gas_state: *gas.State, snowpack: *snow.State, surface_water: *surface.State, inputs: Inputs, outputs: Outputs) !Result {
    try hydrology.syncStorage(grid, snowpack);
    if (micropore.cell_count != grid.layer_count or macropore.cell_count != grid.layer_count or gas_state.cell_count != grid.layer_count or micropore.species_count != macropore.species_count or inputs.layer_volume_m3.len != grid.layer_count or inputs.macropore_spacing_m.len != grid.layer_count or inputs.micropore_diffusivity_m2_per_h.len != grid.layer_count or surface_water.carrier_volume_m3.len != grid.cell_count or outputs.snow_surface_discharge.len != grid.cell_count or outputs.runoff_exported_mol.len != surface_water.species_count or outputs.snow_drift_exported_g.len != snow.species_count or outputs.snow_drift_exported_salt_mol.len != snow.salt_species_count) return error.TransportStepDimensionMismatch;
    if (!std.math.isFinite(inputs.pore_exchange_step_fraction) or inputs.pore_exchange_step_fraction < 0 or inputs.pore_exchange_step_fraction > 1) return error.InvalidPoreExchangeStepFraction;
    @memcpy(micropore.water_volume_m3, hydrology.micropore_water_volume_m3);
    @memcpy(macropore.water_volume_m3, hydrology.macropore_water_volume_m3);
    @memcpy(gas_state.air_volume_m3, hydrology.air_volume_m3);
    @memcpy(surface_water.carrier_volume_m3, hydrology.runoff_total_m3_per_step);
    var faces = try hydrology_module.buildSoilFaces(allocator, hydrology, grid);
    defer faces.deinit();
    const face_components = try std.math.mul(usize, faces.micropore_faces.len, micropore.species_count);
    if (inputs.micropore_diffusive_conductance_m3_per_step.len != face_components or inputs.macropore_diffusive_conductance_m3_per_step.len != face_components or inputs.micropore_mobility_fraction.len != face_components or inputs.macropore_mobility_fraction.len != face_components) return error.TransportStepFaceParameterSizeMismatch;

    const micropore_before = try allocator.dupe(f64, micropore.amount_mol);
    defer allocator.free(micropore_before);
    const macropore_before = try allocator.dupe(f64, macropore.amount_mol);
    defer allocator.free(macropore_before);
    const snow_before = try allocator.dupe(f64, snowpack.amount_g);
    defer allocator.free(snow_before);
    const snow_salt_before = try allocator.dupe(f64, snowpack.salt_amount_mol);
    defer allocator.free(snow_salt_before);
    const snow_active_before = try allocator.dupe(bool, snowpack.active);
    defer allocator.free(snow_active_before);
    const surface_before = try allocator.dupe(f64, surface_water.amount_mol);
    defer allocator.free(surface_before);
    const gas_before = try allocator.dupe(f64, gas_state.gaseous_mass_g);
    defer allocator.free(gas_before);
    const dissolved_gas_before = try allocator.dupe(f64, gas_state.dissolved_mass_g);
    defer allocator.free(dissolved_gas_before);
    const band_gas_before = try allocator.dupe(f64, gas_state.band_dissolved_mass_g);
    defer allocator.free(band_gas_before);
    var state_updateted = false;
    defer if (!state_updateted) {
        @memcpy(micropore.amount_mol, micropore_before);
        @memcpy(macropore.amount_mol, macropore_before);
        @memcpy(snowpack.amount_g, snow_before);
        @memcpy(snowpack.salt_amount_mol, snow_salt_before);
        @memcpy(snowpack.active, snow_active_before);
        @memcpy(surface_water.amount_mol, surface_before);
        @memcpy(gas_state.gaseous_mass_g, gas_before);
        @memcpy(gas_state.dissolved_mass_g, dissolved_gas_before);
        @memcpy(gas_state.band_dissolved_mass_g, band_gas_before);
    };

    const micropore_result = try solute_solver.solve(allocator, micropore, faces.micropore_faces, inputs.micropore_diffusive_conductance_m3_per_step, inputs.micropore_mobility_fraction, .{ .maximum_convective_fraction = inputs.maximum_convective_fraction }, inputs.solute_solver_options);
    const macropore_result = try solute_solver.solve(allocator, macropore, faces.macropore_faces, inputs.macropore_diffusive_conductance_m3_per_step, inputs.macropore_mobility_fraction, .{ .maximum_convective_fraction = inputs.maximum_convective_fraction }, inputs.solute_solver_options);
    // TRNSFRS exchanges every dissolved species between pore domains after
    // directional transport. Each pair is conservative and the surrounding
    // transaction rolls the complete hourly state back on any failure.
    for (0..grid.layer_count) |cell| {
        const base = cell * micropore.species_count;
        for (0..micropore.species_count) |species_index| {
            const component = base + species_index;
            const convective_flux_mol = try solute.calculateConvectivePoreExchangeFlux(
                micropore.amount_mol[component],
                macropore.amount_mol[component],
                micropore.water_volume_m3[cell],
                macropore.water_volume_m3[cell],
                hydrology.macropore_to_matrix_water_flux_m3_per_step[cell],
                inputs.maximum_convective_fraction,
            );
            try solute.state_updatePoreExchange(
                &micropore.amount_mol[component],
                &macropore.amount_mol[component],
                convective_flux_mol,
            );
            const flux_mol = try solute.calculatePoreExchangeFlux(
                micropore.amount_mol[component],
                macropore.amount_mol[component],
                micropore.water_volume_m3[cell],
                macropore.water_volume_m3[cell],
                inputs.layer_volume_m3[cell],
                inputs.pore_exchange_step_fraction,
                inputs.macropore_spacing_m[cell],
                inputs.micropore_diffusivity_m2_per_h[cell],
            );
            try solute.state_updatePoreExchange(&micropore.amount_mol[component], &macropore.amount_mol[component], flux_mol);
        }
    }
    const gas_result = try gas_solver.solve(allocator, gas_state, inputs.gas_solver_inputs, inputs.gas_solver_options);

    const discharge_scratch = try allocator.alloc(snow.SurfaceDischarge, grid.cell_count);
    defer allocator.free(discharge_scratch);
    const snow_result = try snow_solver.solve(allocator, snowpack, .{
        .atmospheric_top_input_g = inputs.snow_atmospheric_top_input_g,
        .transport_water_volume_m3 = hydrology.snow_liquid_water_volume_m3,
        .water_flux_to_lower_m3 = hydrology.snow_downward_water_flux_m3_per_step,
        .litter_water_flux_m3 = hydrology.snow_to_litter_water_flux_m3_per_step,
        .soil_micropore_water_flux_m3 = hydrology.snow_to_soil_micropore_flux_m3_per_step,
        .soil_macropore_water_flux_m3 = hydrology.snow_to_soil_macropore_flux_m3_per_step,
        .surface_partitions = inputs.snow_surface_partitions,
    }, inputs.snow_solver_options, discharge_scratch);

    const snow_export_scratch = try allocator.alloc(f64, snow.species_count);
    defer allocator.free(snow_export_scratch);
    const snow_salt_export_scratch = try allocator.alloc(f64, snow.salt_species_count);
    defer allocator.free(snow_salt_export_scratch);
    try snow_drift.route(allocator, snowpack, hydrology.columns, hydrology.rows, hydrology.snow_surface_carrier_volume_m3, hydrology.snow_transfer_total_m3_per_step, .{
        .east_m3 = hydrology.snow_transfer_east_m3_per_step,
        .west_m3 = hydrology.snow_transfer_west_m3_per_step,
        .south_m3 = hydrology.snow_transfer_south_m3_per_step,
        .north_m3 = hydrology.snow_transfer_north_m3_per_step,
    }, inputs.snow_drift_boundaries, inputs.snow_drift_maximum_transport_fraction, snow_export_scratch, snow_salt_export_scratch);

    const export_scratch = try allocator.alloc(f64, surface_water.species_count);
    defer allocator.free(export_scratch);
    _ = try surface.route(allocator, surface_water, hydrology.runoff_total_m3_per_step, .{
        .east_m3 = hydrology.runoff_east_m3_per_step,
        .west_m3 = hydrology.runoff_west_m3_per_step,
        .south_m3 = hydrology.runoff_south_m3_per_step,
        .north_m3 = hydrology.runoff_north_m3_per_step,
    }, inputs.runoff_boundaries, inputs.runoff_maximum_transport_fraction, export_scratch);

    @memcpy(outputs.snow_surface_discharge, discharge_scratch);
    @memcpy(outputs.runoff_exported_mol, export_scratch);
    @memcpy(outputs.snow_drift_exported_g, snow_export_scratch);
    @memcpy(outputs.snow_drift_exported_salt_mol, snow_salt_export_scratch);
    state_updateted = true;
    return .{ .micropore = micropore_result, .macropore = macropore_result, .gas = gas_result, .snowpack = snow_result };
}

fn partitions() snow.SurfacePartition {
    return .{ .litter_cover_fraction = 0.5, .bare_soil_fraction = 0.5, .nonband_ammonium_fraction = 1, .band_ammonium_fraction = 0, .nonband_nitrate_fraction = 1, .band_nitrate_fraction = 0, .nonband_phosphate_fraction = 1, .band_phosphate_fraction = 0 };
}

test "soil solute transaction publishes both accepted runtime-species face ledgers" {
    const runtime_species_count: usize = 9;
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 2,
            .lat_count = 1,
            .soil_layers = 1,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    @memset(grid.matrix_liquid_water_m3, 1);
    @memset(grid.macropore_liquid_water_m3, 1);
    var hydrology = try hydrology_module.State.init(
        std.testing.allocator,
        2,
        1,
        1,
        1,
    );
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(
        std.testing.allocator,
        &hydrology,
        &grid,
    );
    defer faces.deinit();
    var micropore = try solute.State.init(
        std.testing.allocator,
        2,
        runtime_species_count,
    );
    defer micropore.deinit();
    var macropore = try solute.State.init(
        std.testing.allocator,
        2,
        runtime_species_count,
    );
    defer macropore.deinit();
    @memset(micropore.water_volume_m3, 1);
    @memset(macropore.water_volume_m3, 1);
    for (0..runtime_species_count) |species| {
        micropore.amount_mol[species] = @floatFromInt(species + 1);
        macropore.amount_mol[species] = @floatFromInt(species + 2);
    }
    const face_component_count =
        faces.micropore_faces.len * runtime_species_count;
    const conductance = try std.testing.allocator.alloc(
        f64,
        face_component_count,
    );
    defer std.testing.allocator.free(conductance);
    @memset(conductance, 0.1);
    const mobility = try std.testing.allocator.alloc(
        f64,
        face_component_count,
    );
    defer std.testing.allocator.free(mobility);
    @memset(mobility, 1);
    const recharge = [_]f64{0} ** (2 * runtime_species_count);
    var micropore_face_flux =
        [_]f64{0} ** runtime_species_count;
    var macropore_face_flux =
        [_]f64{0} ** runtime_species_count;
    _ = try advanceSoilSolutes(
        std.testing.allocator,
        &grid,
        &hydrology,
        &faces,
        &micropore,
        &macropore,
        .{
            .micropore_diffusive_conductance_m3_per_step = conductance,
            .macropore_diffusive_conductance_m3_per_step = conductance,
            .micropore_mobility_fraction = mobility,
            .macropore_mobility_fraction = mobility,
            .layer_volume_m3 = &.{ 2, 2 },
            .macropore_spacing_m = &.{ 1, 1 },
            .micropore_diffusivity_m2_per_h = &.{ 0, 0 },
            .maximum_convective_fraction = 1,
            .pore_exchange_step_fraction = 0,
            .boundary_mobility_fraction = &([_]f64{1} ** runtime_species_count),
            .recharge_concentration_mol_per_m3 = &recharge,
            .micropore_face_flux_mol_by_component = &micropore_face_flux,
            .macropore_face_flux_mol_by_component = &macropore_face_flux,
            .solver_options = .{ .max_iterations = 80 },
        },
    );
    for (micropore_face_flux, macropore_face_flux) |micro, macro| {
        try std.testing.expect(micro > 0);
        try std.testing.expect(macro > 0);
    }
}

test "soil solute local gate rejects exact domain cancellation and rolls back" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    @memset(grid.matrix_liquid_water_m3, 1);
    @memset(grid.macropore_liquid_water_m3, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var micropore = try solute.State.init(std.testing.allocator, 2, 1);
    defer micropore.deinit();
    var macropore = try solute.State.init(std.testing.allocator, 2, 1);
    defer macropore.deinit();
    @memset(micropore.amount_mol, 1);
    @memset(macropore.amount_mol, 1);
    const micropore_before = micropore.amount_mol[0..2].*;
    const macropore_before = macropore.amount_mol[0..2].*;
    const face_count = faces.micropore_faces.len;
    const zeros = try std.testing.allocator.alloc(f64, face_count);
    defer std.testing.allocator.free(zeros);
    @memset(zeros, 0);
    var boundary_output = [_]f64{ 71, 72 };
    const boundary_before = boundary_output;
    const micro_face_output = try std.testing.allocator.alloc(f64, face_count);
    defer std.testing.allocator.free(micro_face_output);
    @memset(micro_face_output, 73);
    const micro_face_before = try std.testing.allocator.dupe(f64, micro_face_output);
    defer std.testing.allocator.free(micro_face_before);
    const macro_face_output = try std.testing.allocator.alloc(f64, face_count);
    defer std.testing.allocator.free(macro_face_output);
    @memset(macro_face_output, 74);
    const macro_face_before = try std.testing.allocator.dupe(f64, macro_face_output);
    defer std.testing.allocator.free(macro_face_before);
    try std.testing.expectError(error.SoilSoluteLocalConservationFailure, advanceSoilSolutes(
        std.testing.allocator,
        &grid,
        &hydrology,
        &faces,
        &micropore,
        &macropore,
        .{
            .micropore_diffusive_conductance_m3_per_step = zeros,
            .macropore_diffusive_conductance_m3_per_step = zeros,
            .micropore_mobility_fraction = zeros,
            .macropore_mobility_fraction = zeros,
            .layer_volume_m3 = &.{ 1, 1 },
            .macropore_spacing_m = &.{ 1, 1 },
            .micropore_diffusivity_m2_per_h = &.{ 0, 0 },
            .maximum_convective_fraction = 1,
            .pore_exchange_step_fraction = 0,
            .boundary_mobility_fraction = &.{1},
            .recharge_concentration_mol_per_m3 = &.{ 0, 0 },
            .boundary_net_flux_mol_by_cell = &boundary_output,
            .micropore_face_flux_mol_by_component = micro_face_output,
            .macropore_face_flux_mol_by_component = macro_face_output,
            .conservation_relative_tolerance = 1e-12,
            .test_conservation_perturbation_mol_by_component = &.{ 1e-5, -1e-5 },
            .solver_options = .{ .max_iterations = 8 },
        },
    ));
    try std.testing.expectEqualDeep(micropore_before, micropore.amount_mol[0..2].*);
    try std.testing.expectEqualDeep(macropore_before, macropore.amount_mol[0..2].*);
    try std.testing.expectEqualDeep(boundary_before, boundary_output);
    try std.testing.expectEqualSlices(f64, micro_face_before, micro_face_output);
    try std.testing.expectEqualSlices(f64, macro_face_before, macro_face_output);
}

test "DLYRM-inactive layer excludes aqueous boundary and pore exchange" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.matrix_liquid_water_m3[0] = 1;
    grid.macropore_liquid_water_m3[0] = 1;
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    hydrology.micropore_external_water_flux_m3_per_step[0] = 0.5;
    hydrology.macropore_external_water_flux_m3_per_step[0] = 0.5;
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    faces.active_by_layer[0] = false;
    var micropore = try solute.State.init(std.testing.allocator, 1, 1);
    defer micropore.deinit();
    var macropore = try solute.State.init(std.testing.allocator, 1, 1);
    defer macropore.deinit();
    micropore.amount_mol[0] = 2;
    macropore.amount_mol[0] = 1;
    var boundary_ledger = [_]f64{99};
    _ = try advanceSoilSolutes(std.testing.allocator, &grid, &hydrology, &faces, &micropore, &macropore, .{
        .micropore_diffusive_conductance_m3_per_step = &.{},
        .macropore_diffusive_conductance_m3_per_step = &.{},
        .micropore_mobility_fraction = &.{},
        .macropore_mobility_fraction = &.{},
        .layer_volume_m3 = &.{1},
        .macropore_spacing_m = &.{0.1},
        .micropore_diffusivity_m2_per_h = &.{1},
        .maximum_convective_fraction = 1,
        .pore_exchange_step_fraction = 1,
        .boundary_mobility_fraction = &.{1},
        .recharge_concentration_mol_per_m3 = &.{0},
        .boundary_net_flux_mol_by_cell = &boundary_ledger,
        .solver_options = .{ .max_iterations = 4 },
    });
    try std.testing.expectEqual(@as(f64, 2), micropore.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 1), macropore.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 0), boundary_ledger[0]);
}

test "DLYRM vertical promotion bypasses a zero-volume thin layer conservatively" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 3, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 3;
    @memcpy(grid.matrix_liquid_water_m3, &[_]f64{ 1, 0, 1 });
    @memset(grid.macropore_liquid_water_m3, 0);

    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 3, 1);
    defer hydrology.deinit();
    // +z flux owned by the upper fixed-capacity slot. The source oracle scans
    // past the DLYRM layer and applies this transfer to the first deeper thick
    // layer; the dormant middle slot must publish exact zero.
    hydrology.micropore_face_flux_m3_per_step[2] = 0.2;
    hydrology.micropore_face_flux_m3_per_step[5] = 9;
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    const layer_geometry = @import("../soil/profile/layer_geometry.zig");
    var geometry = try layer_geometry.State.init(std.testing.allocator, 1, 3);
    defer geometry.deinit();
    try layer_geometry.initializeCell(&geometry, 0, 0, &.{ 2.0e-6, 1.0e-6, 3.0e-6 }, 0, 1.0e-9);
    // Preserve the strict equality boundary despite cumulative-depth rounding.
    geometry.layer_thickness_m[1] = 1.0e-6;
    try faces.refreshMapped(&hydrology, &grid, &geometry, 1.0e-6);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, faces.active_by_layer);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, faces.active_by_face);
    try std.testing.expectEqual(@as(usize, 2), faces.micropore_faces[0].second_cell);
    try std.testing.expectEqual(@as(f64, 0), hydrology.micropore_face_flux_m3_per_step[5]);

    var micropore = try solute.State.init(std.testing.allocator, 3, 1);
    defer micropore.deinit();
    var macropore = try solute.State.init(std.testing.allocator, 3, 1);
    defer macropore.deinit();
    @memcpy(micropore.amount_mol, &[_]f64{ 4, 7, 0 });
    // A nonzero dormant inventory proves the zero-volume layer is not changed
    // by either a face transfer or local micropore/macropore exchange.
    @memcpy(macropore.amount_mol, &[_]f64{ 0, 5, 0 });
    var micro_face_ledger = [_]f64{ 99, 99 };
    var macro_face_ledger = [_]f64{ 99, 99 };
    var boundary_ledger = [_]f64{ 99, 99, 99 };
    const before_total = micropore.amount_mol[0] + micropore.amount_mol[2];
    _ = try advanceSoilSolutes(std.testing.allocator, &grid, &hydrology, &faces, &micropore, &macropore, .{
        .micropore_diffusive_conductance_m3_per_step = &.{ 0, 0 },
        .macropore_diffusive_conductance_m3_per_step = &.{ 0, 0 },
        .micropore_mobility_fraction = &.{ 1, 0 },
        .macropore_mobility_fraction = &.{ 1, 0 },
        .layer_volume_m3 = &.{ 1, 0, 1 },
        .macropore_spacing_m = &.{ 0.1, 0.1, 0.1 },
        .micropore_diffusivity_m2_per_h = &.{ 0, 0, 0 },
        .maximum_convective_fraction = 1,
        .pore_exchange_step_fraction = 1,
        .boundary_mobility_fraction = &.{1},
        .recharge_concentration_mol_per_m3 = &.{ 0, 0, 0 },
        .boundary_net_flux_mol_by_cell = &boundary_ledger,
        .micropore_face_flux_mol_by_component = &micro_face_ledger,
        .macropore_face_flux_mol_by_component = &macro_face_ledger,
        .conservation_relative_tolerance = 1e-12,
        .solver_options = .{ .max_iterations = 20 },
    });
    try std.testing.expect(micro_face_ledger[0] > 0);
    try std.testing.expectEqual(@as(f64, 0), micro_face_ledger[1]);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, &macro_face_ledger);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, &boundary_ledger);
    try std.testing.expectEqual(@as(f64, 7), micropore.amount_mol[1]);
    try std.testing.expectEqual(@as(f64, 5), macropore.amount_mol[1]);
    try std.testing.expectApproxEqAbs(
        before_total,
        micropore.amount_mol[0] + micropore.amount_mol[2],
        64 * std.math.floatEps(f64),
    );
    try std.testing.expectApproxEqAbs(
        micro_face_ledger[0],
        4 - micropore.amount_mol[0],
        64 * std.math.floatEps(f64),
    );
    try std.testing.expectApproxEqAbs(
        micro_face_ledger[0],
        micropore.amount_mol[2],
        64 * std.math.floatEps(f64),
    );
}

test "hourly transport coupling advances pore domains and snow atomically" {
    const config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    @memset(grid.matrix_liquid_water_m3, 1);
    @memset(grid.macropore_liquid_water_m3, 1);
    var micro = try solute.State.init(std.testing.allocator, 2, 1);
    defer micro.deinit();
    var macro = try solute.State.init(std.testing.allocator, 2, 1);
    defer macro.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    @memset(gas_state.temperature_k, 300);
    micro.amount_mol[0] = 1;
    micro.amount_mol[1] = 1;
    macro.amount_mol[0] = 4;
    var snowpack = try snow.State.init(std.testing.allocator, 2, 1);
    defer snowpack.deinit();
    var surface_water = try surface.State.init(std.testing.allocator, 2, 1, 1);
    defer surface_water.deinit();
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    var snow_discharge: [2]snow.SurfaceDischarge = undefined;
    var runoff_export: [1]f64 = undefined;
    var snow_drift_export: [snow.species_count]f64 = undefined;
    var snow_drift_salt_export: [snow.salt_species_count]f64 = undefined;
    const no = [_]bool{ false, false };
    const zero_snow_input = [_]f64{0} ** (2 * snow.species_count);
    const gas_water = [_]f64{ 0, 0 };
    const gas_solubility = [_]f64{1} ** (2 * gas.species_count);
    const gas_exchange = [_]f64{0} ** (2 * gas.species_count);
    const no_bubbling = [_]bool{ false, false };
    const result = try advance(std.testing.allocator, &grid, &hydrology, &micro, &macro, &gas_state, &snowpack, &surface_water, .{
        .micropore_diffusive_conductance_m3_per_step = &[_]f64{0.1},
        .macropore_diffusive_conductance_m3_per_step = &[_]f64{0.1},
        .micropore_mobility_fraction = &[_]f64{1},
        .macropore_mobility_fraction = &[_]f64{1},
        .maximum_convective_fraction = 1,
        .layer_volume_m3 = &[_]f64{ 2, 2 },
        .macropore_spacing_m = &[_]f64{ 1, 1 },
        .micropore_diffusivity_m2_per_h = &[_]f64{ 1e-6, 1e-6 },
        .pore_exchange_step_fraction = 1,
        .boundary_mobility_fraction = &[_]f64{1},
        .recharge_concentration_mol_per_m3 = &[_]f64{ 0, 0 },
        .solute_solver_options = .{ .max_iterations = 20 },
        .gas_solver_inputs = .{ .faces = &.{}, .face_conductance_m3_per_step = &.{}, .atmospheric_boundaries = &.{}, .water_volume_m3 = &gas_water, .band_water_volume_m3 = &gas_water, .mass_solubility_ratio = &gas_solubility, .gas_water_exchange_rate_per_step = &gas_exchange, .band_gas_water_exchange_rate_per_step = &gas_exchange, .bubbling_enabled = &no_bubbling },
        .gas_solver_options = .{ .max_iterations = 80 },
        .snow_atmospheric_top_input_g = &zero_snow_input,
        .snow_surface_partitions = &[_]snow.SurfacePartition{ partitions(), partitions() },
        .snow_solver_options = .{},
        .snow_drift_boundaries = .{ .east_open = &no, .west_open = &no, .south_open = &no, .north_open = &no },
        .snow_drift_maximum_transport_fraction = 1,
        .runoff_boundaries = .{ .east_open = &no, .west_open = &no, .south_open = &no, .north_open = &no },
        .runoff_maximum_transport_fraction = 1,
    }, .{ .snow_surface_discharge = &snow_discharge, .runoff_exported_mol = &runoff_export, .snow_drift_exported_g = &snow_drift_export, .snow_drift_exported_salt_mol = &snow_drift_salt_export });
    try std.testing.expect(result.micropore.iterations < 20);
    try std.testing.expectApproxEqAbs(@as(f64, 6), micro.amount_mol[0] + micro.amount_mol[1] + macro.amount_mol[0] + macro.amount_mol[1], 1e-12);
    try std.testing.expect(micro.amount_mol[0] > 1);
}

test "late transport failure rolls back earlier pore solve" {
    const config = try @import("../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    @memset(grid.matrix_liquid_water_m3, 1);
    @memset(grid.macropore_liquid_water_m3, 1);
    var micro = try solute.State.init(std.testing.allocator, 2, 1);
    defer micro.deinit();
    var macro = try solute.State.init(std.testing.allocator, 2, 1);
    defer macro.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    @memset(gas_state.temperature_k, 300);
    micro.amount_mol[0] = 1;
    micro.amount_mol[1] = 1;
    macro.amount_mol[0] = 4;
    var snowpack = try snow.State.init(std.testing.allocator, 2, 1);
    defer snowpack.deinit();
    var surface_water = try surface.State.init(std.testing.allocator, 2, 1, 1);
    defer surface_water.deinit();
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    var snow_discharge: [2]snow.SurfaceDischarge = undefined;
    var runoff_export: [1]f64 = undefined;
    var snow_drift_export: [snow.species_count]f64 = undefined;
    var snow_drift_salt_export: [snow.salt_species_count]f64 = undefined;
    const no = [_]bool{ false, false };
    const zero_snow_input = [_]f64{0} ** (2 * snow.species_count);
    const gas_water = [_]f64{ 0, 0 };
    const gas_solubility = [_]f64{1} ** (2 * gas.species_count);
    const gas_exchange = [_]f64{0} ** (2 * gas.species_count);
    const no_bubbling = [_]bool{ false, false };
    try std.testing.expectError(error.SoluteTransportSolverDidNotConverge, advance(std.testing.allocator, &grid, &hydrology, &micro, &macro, &gas_state, &snowpack, &surface_water, .{
        .micropore_diffusive_conductance_m3_per_step = &[_]f64{0.1},
        .macropore_diffusive_conductance_m3_per_step = &[_]f64{0.1},
        .micropore_mobility_fraction = &[_]f64{1},
        .macropore_mobility_fraction = &[_]f64{1},
        .maximum_convective_fraction = 1,
        .layer_volume_m3 = &[_]f64{ 2, 2 },
        .macropore_spacing_m = &[_]f64{ 1, 1 },
        .micropore_diffusivity_m2_per_h = &[_]f64{ 0, 0 },
        .pore_exchange_step_fraction = 1,
        .boundary_mobility_fraction = &[_]f64{1},
        .recharge_concentration_mol_per_m3 = &[_]f64{ 0, 0 },
        .solute_solver_options = .{ .absolute_tolerance_mol = 1e-20, .relative_tolerance = 1e-20, .max_iterations = 1 },
        .gas_solver_inputs = .{ .faces = &.{}, .face_conductance_m3_per_step = &.{}, .atmospheric_boundaries = &.{}, .water_volume_m3 = &gas_water, .band_water_volume_m3 = &gas_water, .mass_solubility_ratio = &gas_solubility, .gas_water_exchange_rate_per_step = &gas_exchange, .band_gas_water_exchange_rate_per_step = &gas_exchange, .bubbling_enabled = &no_bubbling },
        .gas_solver_options = .{ .max_iterations = 80 },
        .snow_atmospheric_top_input_g = &zero_snow_input,
        .snow_surface_partitions = &[_]snow.SurfacePartition{ partitions(), partitions() },
        .snow_solver_options = .{},
        .snow_drift_boundaries = .{ .east_open = &no, .west_open = &no, .south_open = &no, .north_open = &no },
        .snow_drift_maximum_transport_fraction = 1,
        .runoff_boundaries = .{ .east_open = &no, .west_open = &no, .south_open = &no, .north_open = &no },
        .runoff_maximum_transport_fraction = 1,
    }, .{ .snow_surface_discharge = &snow_discharge, .runoff_exported_mol = &runoff_export, .snow_drift_exported_g = &snow_drift_export, .snow_drift_exported_salt_mol = &snow_drift_salt_export }));
    try std.testing.expectEqual(@as(f64, 1), micro.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 1), micro.amount_mol[1]);
    try std.testing.expectEqual(@as(f64, 4), macro.amount_mol[0]);
}

//! `solver` declarations: hydraulics.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const numerics = @import("../../core/numerics.zig");
const grid_module = @import("../../state/grid.zig");
const retention = @import("retention.zig");
const water_flux = @import("flux.zig");
const kirchhoff = @import("kirchhoff.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const water_boundary = @import("boundary.zig");
const boundary_topology = @import("../profile/boundary_topology.zig");
const group_types = @import("solver_types.zig");
const ice_units = @import("../../core/ice_units.zig");

pub fn conductivityAt(properties: group_types.Properties, cell: usize, axis: usize, water_fraction: f64, ice_water_equivalent_m3: f64) !f64 {
    return unsaturatedConductivityM2PerHMpa(.{
        .parameters = properties.mualem_van_genuchten_parameters[cell],
        .water_fraction = water_fraction,
        .ice_water_equivalent_m3 = ice_water_equivalent_m3,
        .matrix_bulk_volume_m3 = properties.matrix_bulk_volume_m3[cell],
        .conductivity_multiplier = if (properties.rainfall_conductivity_multiplier.len == 0) 1 else properties.rainfall_conductivity_multiplier[cell],
        .frozen_hydraulic_impedance_exponent = properties.frozen_hydraulic_impedance_exponent,
        .ice_density_megagrams_per_m3 = properties.ice_density_megagrams_per_m3,
        .gravitational_water_potential_mpa_per_m = properties.gravitational_water_potential_mpa_per_m,
        .saturated_hydraulic_conductivity_override_m_per_h = lateralSaturatedConductivityOverrideMPerH(properties, cell, axis),
    });
}

/// `SOIL-HCOND-AXIS-ISOTROPY-001`. `axis` is the runtime `Axis` enum value
/// (`x = 0, y = 1, z = 2`, `solver_types.zig`) reduced to an integer by every
/// call site. `z` is vertical, mirroring `ecosys_f77/hour1.f:2281-2293`'s
/// `N.EQ.3` branch; `x`/`y` are lateral, mirroring that loop's `SCNH` branch.
/// Returns `null` for the vertical axis (the parameters' own embedded
/// saturated conductivity already is the vertical value) and whenever the
/// caller did not supply a lateral array, so every pre-existing caller that
/// only ever populates `mualem_van_genuchten_parameters` keeps its previous,
/// isotropic behaviour bit-for-bit.
const vertical_axis: usize = @intFromEnum(group_types.Axis.z);

fn lateralSaturatedConductivityOverrideMPerH(properties: group_types.Properties, cell: usize, axis: usize) ?f64 {
    if (axis == vertical_axis) return null;
    if (properties.lateral_saturated_hydraulic_conductivity_m_per_h.len == 0) return null;
    return properties.lateral_saturated_hydraulic_conductivity_m_per_h[cell];
}

pub const UnsaturatedConductivityInputs = struct {
    parameters: retention.MualemVanGenuchtenParameters,
    water_fraction: f64,
    ice_water_equivalent_m3: f64,
    matrix_bulk_volume_m3: f64,
    conductivity_multiplier: f64 = 1,
    frozen_hydraulic_impedance_exponent: f64 = 0,
    ice_density_megagrams_per_m3: f64 = ice_units.reference_ice_density_megagrams_per_m3,
    gravitational_water_potential_mpa_per_m: f64 = 0.00980665,
    /// `SOIL-HCOND-AXIS-ISOTROPY-001`. When set, replaces
    /// `parameters.saturated_hydraulic_conductivity_m_per_h` as the scalar
    /// multiplying the dimensionless Mualem shape, e.g. for a lateral face
    /// whose saturated conductivity differs from the vertical value baked
    /// into `parameters`. `null` preserves the previous behaviour exactly.
    saturated_hydraulic_conductivity_override_m_per_h: ?f64 = null,
    kirchhoff_cache: ?*kirchhoff.Cache = null,
};

/// The single unsaturated-conductivity evaluation in the model: pure
/// Mualem-van Genuchten K(h) with the Richards potential unit conversion, the
/// rainfall-impact multiplier, and the frozen impedance factor. The
/// dimensionless relative-conductivity shape is always this cell's own
/// retention curve; direction enters only through which saturated
/// conductivity scales it (`saturated_hydraulic_conductivity_override_m_per_h`),
/// exactly as `ecosys_f77/hour1.f:2281-2293` multiplies one shared `YK*SUM1/SUM2`
/// shape by a direction-specific `SCNV`/`SCNH` scalar. Every consumer
/// (Richards faces, dual-domain exchange, root uptake resistance) must route
/// through here so that the plant and the soil never disagree about K at the
/// same water content.
pub fn unsaturatedConductivityM2PerHMpa(inputs: UnsaturatedConductivityInputs) !f64 {
    if (inputs.matrix_bulk_volume_m3 <= 0 or
        !std.math.isFinite(inputs.water_fraction) or
        !std.math.isFinite(inputs.ice_water_equivalent_m3) or
        !std.math.isFinite(inputs.conductivity_multiplier) or
        inputs.conductivity_multiplier < 0 or
        inputs.gravitational_water_potential_mpa_per_m <= 0)
        return error.InvalidUnsaturatedConductivityInput;
    const parameters = inputs.parameters;
    const bounded_water_content = std.math.clamp(
        inputs.water_fraction,
        parameters.residual_water_content_m3_per_m3,
        parameters.saturated_water_content_m3_per_m3,
    );
    const pressure_head_m = try parameters.pressureHeadAtWaterContent(bounded_water_content);
    const conductivity_m_per_h = try axisScaledHydraulicConductivityMPerH(parameters, pressure_head_m, inputs.saturated_hydraulic_conductivity_override_m_per_h);
    const ice_content_m3_per_m3 = (try ice_units.physicalVolumeM3FromWaterEquivalent(inputs.ice_water_equivalent_m3, inputs.ice_density_megagrams_per_m3)) / inputs.matrix_bulk_volume_m3;
    const result = conductivity_m_per_h / inputs.gravitational_water_potential_mpa_per_m *
        inputs.conductivity_multiplier *
        frozenHydraulicImpedance(inputs.frozen_hydraulic_impedance_exponent, ice_content_m3_per_m3, parameters);
    if (!std.math.isFinite(result) or result < 0) return error.NonFiniteUnsaturatedConductivity;
    return result;
}

/// `hydraulicConductivityMPerH` with the saturated-conductivity scalar
/// replaced by `override_m_per_h` when supplied. The relative-conductivity
/// shape factors out of `hydraulicConductivityMPerH` exactly as
/// `parameters.saturated_hydraulic_conductivity_m_per_h * relative(Se)`
/// (`retention.zig`'s `hydraulicConductivityMPerH`), so recomposing the two
/// pieces here with a substituted scalar reproduces the same shape scaled by
/// a different axis's saturated conductivity, matching
/// `ecosys_f77/hour1.f:2281-2293`'s shared-shape, direction-specific-scalar
/// structure.
fn axisScaledHydraulicConductivityMPerH(
    parameters: retention.MualemVanGenuchtenParameters,
    pressure_head_m: f64,
    override_m_per_h: ?f64,
) !f64 {
    const saturated_hydraulic_conductivity_m_per_h = override_m_per_h orelse parameters.saturated_hydraulic_conductivity_m_per_h;
    if (!std.math.isFinite(saturated_hydraulic_conductivity_m_per_h) or saturated_hydraulic_conductivity_m_per_h < 0)
        return error.InvalidUnsaturatedConductivityInput;
    const effective_saturation = try parameters.effectiveSaturationAtPressureHead(pressure_head_m);
    const relative_conductivity = try parameters.relativeHydraulicConductivityAtEffectiveSaturation(effective_saturation);
    return saturated_hydraulic_conductivity_m_per_h * relative_conductivity;
}

/// Interval-averaged (Kirchhoff) counterpart of
/// `unsaturatedConductivityM2PerHMpa`. `PR-KIRCHHOFF-DESIGN`.
///
/// The endpoint form above evaluates `K` at this cell's own water content,
/// which makes the face conductance collapse when either cell is dry
/// (`kirchhoff.zig` header). This form replaces the endpoint `K` with its
/// average over the matric interval the face spans, so the face reproduces the
/// Darcy-Buckingham integral between the two cell states instead of the
/// endpoint product.
///
/// Only the constitutive `K` changes. The Richards unit conversion, the
/// rainfall-impact multiplier and the frozen impedance factor are applied
/// exactly as in the endpoint form, so a face whose two cells share a matric
/// state is bit-identical to the previous kernel.
pub fn intervalAveragedConductivityM2PerHMpa(
    inputs: UnsaturatedConductivityInputs,
    neighbour_pressure_head_m: f64,
) !f64 {
    try inputs.parameters.validate();
    try validateIntervalAveragedConductivityInputs(
        inputs,
        neighbour_pressure_head_m,
        null,
    );
    const parameters = inputs.parameters;
    const own_content = std.math.clamp(
        inputs.water_fraction,
        parameters.residual_water_content_m3_per_m3,
        parameters.saturated_water_content_m3_per_m3,
    );
    const own_head_m = try parameters.pressureHeadAtWaterContentAssumeValid(
        own_content,
    );
    return intervalAveragedConductivityM2PerHMpaAssumeValid(
        inputs,
        own_head_m,
        neighbour_pressure_head_m,
    );
}

fn validateIntervalAveragedConductivityInputs(
    inputs: UnsaturatedConductivityInputs,
    neighbour_pressure_head_m: f64,
    own_pressure_head_m: ?f64,
) !void {
    if (inputs.matrix_bulk_volume_m3 <= 0 or
        !std.math.isFinite(inputs.water_fraction) or
        !std.math.isFinite(neighbour_pressure_head_m) or
        (own_pressure_head_m != null and
            !std.math.isFinite(own_pressure_head_m.?)) or
        !std.math.isFinite(inputs.ice_water_equivalent_m3) or
        !std.math.isFinite(inputs.conductivity_multiplier) or
        inputs.conductivity_multiplier < 0 or
        inputs.gravitational_water_potential_mpa_per_m <= 0)
        return error.InvalidUnsaturatedConductivityInput;
}

fn intervalAveragedConductivityM2PerHMpaAssumeValid(
    inputs: UnsaturatedConductivityInputs,
    own_head_m: f64,
    neighbour_pressure_head_m: f64,
) !f64 {
    const parameters = inputs.parameters;
    // `SOIL-HCOND-AXIS-ISOTROPY-001`: `kirchhoff.zig` always scales its
    // integrand by `parameters.saturated_hydraulic_conductivity_m_per_h`
    // (the vertical scalar). Integrate the unit-Ksat shape instead and
    // rescale by the axis-appropriate saturated conductivity afterward --
    // linear in `saturated_hydraulic_conductivity_m_per_h` throughout
    // `integrateConductivityOverHead`, so this is exact, not an
    // approximation.
    var shape_parameters = parameters;
    shape_parameters.saturated_hydraulic_conductivity_m_per_h = 1;
    // Continuity of `psi`, not of `Se`, at the interface: this cell's own
    // curve is integrated out to the neighbour's matric potential. That is
    // the physically correct interface condition when the two sides carry
    // different Mualem-van Genuchten parameters.
    const bounded_neighbour_head_m = @min(0.0, neighbour_pressure_head_m);
    const relative_conductivity_m_per_h = if (inputs.kirchhoff_cache) |cache|
        try cache.getOrComputeAssumeValid(shape_parameters, own_head_m, bounded_neighbour_head_m)
    else
        try kirchhoff.intervalAveragedConductivityMPerHAssumeValid(
            shape_parameters,
            own_head_m,
            bounded_neighbour_head_m,
        );
    const saturated_hydraulic_conductivity_m_per_h = inputs.saturated_hydraulic_conductivity_override_m_per_h orelse parameters.saturated_hydraulic_conductivity_m_per_h;
    if (!std.math.isFinite(saturated_hydraulic_conductivity_m_per_h) or saturated_hydraulic_conductivity_m_per_h < 0)
        return error.InvalidUnsaturatedConductivityInput;
    const conductivity_m_per_h = relative_conductivity_m_per_h * saturated_hydraulic_conductivity_m_per_h;
    const ice_content_m3_per_m3 = (try ice_units.physicalVolumeM3FromWaterEquivalent(inputs.ice_water_equivalent_m3, inputs.ice_density_megagrams_per_m3)) / inputs.matrix_bulk_volume_m3;
    const result = conductivity_m_per_h / inputs.gravitational_water_potential_mpa_per_m *
        inputs.conductivity_multiplier *
        frozenHydraulicImpedance(inputs.frozen_hydraulic_impedance_exponent, ice_content_m3_per_m3, parameters);
    if (!std.math.isFinite(result) or result < 0) return error.NonFiniteUnsaturatedConductivity;
    return result;
}

/// Interval-averaged conductivity for one cell of a face, given the neighbour's
/// water fraction. Mirrors `conductivityAt`.
pub fn intervalAveragedConductivityAt(
    properties: group_types.Properties,
    cell: usize,
    axis: usize,
    water_fraction: f64,
    neighbour_pressure_head_m: f64,
    ice_water_equivalent_m3: f64,
) !f64 {
    return intervalAveragedConductivityM2PerHMpa(.{
        .parameters = properties.mualem_van_genuchten_parameters[cell],
        .water_fraction = water_fraction,
        .ice_water_equivalent_m3 = ice_water_equivalent_m3,
        .matrix_bulk_volume_m3 = properties.matrix_bulk_volume_m3[cell],
        .conductivity_multiplier = if (properties.rainfall_conductivity_multiplier.len == 0) 1 else properties.rainfall_conductivity_multiplier[cell],
        .frozen_hydraulic_impedance_exponent = properties.frozen_hydraulic_impedance_exponent,
        .ice_density_megagrams_per_m3 = properties.ice_density_megagrams_per_m3,
        .gravitational_water_potential_mpa_per_m = properties.gravitational_water_potential_mpa_per_m,
        .saturated_hydraulic_conductivity_override_m_per_h = lateralSaturatedConductivityOverrideMPerH(properties, cell, axis),
        .kirchhoff_cache = properties.kirchhoff_cache,
    }, neighbour_pressure_head_m);
}

pub fn intervalAveragedConductivityAtKnownHeadAssumeValid(
    properties: group_types.Properties,
    cell: usize,
    axis: usize,
    water_fraction: f64,
    own_pressure_head_m: f64,
    neighbour_pressure_head_m: f64,
    ice_water_equivalent_m3: f64,
) !f64 {
    const inputs: UnsaturatedConductivityInputs = .{
        .parameters = properties.mualem_van_genuchten_parameters[cell],
        .water_fraction = water_fraction,
        .ice_water_equivalent_m3 = ice_water_equivalent_m3,
        .matrix_bulk_volume_m3 = properties.matrix_bulk_volume_m3[cell],
        .conductivity_multiplier = if (properties.rainfall_conductivity_multiplier.len == 0) 1 else properties.rainfall_conductivity_multiplier[cell],
        .frozen_hydraulic_impedance_exponent = properties.frozen_hydraulic_impedance_exponent,
        .ice_density_megagrams_per_m3 = properties.ice_density_megagrams_per_m3,
        .gravitational_water_potential_mpa_per_m = properties.gravitational_water_potential_mpa_per_m,
        .saturated_hydraulic_conductivity_override_m_per_h = lateralSaturatedConductivityOverrideMPerH(properties, cell, axis),
        .kirchhoff_cache = properties.kirchhoff_cache,
    };
    try validateIntervalAveragedConductivityInputs(
        inputs,
        neighbour_pressure_head_m,
        own_pressure_head_m,
    );
    return intervalAveragedConductivityM2PerHMpaAssumeValid(
        inputs,
        own_pressure_head_m,
        neighbour_pressure_head_m,
    );
}

/// Matric pressure head of a cell at a given water fraction, in m. This is the
/// quantity exchanged across a face by `intervalAveragedConductivityAt`, since
/// the interface condition is continuity of potential.
pub fn pressureHeadMAt(properties: group_types.Properties, cell: usize, water_fraction: f64) !f64 {
    const parameters = properties.mualem_van_genuchten_parameters[cell];
    return parameters.pressureHeadAtWaterContent(std.math.clamp(
        water_fraction,
        parameters.residual_water_content_m3_per_m3,
        parameters.saturated_water_content_m3_per_m3,
    ));
}

pub fn pressureHeadMAtAssumeValid(properties: group_types.Properties, cell: usize, water_fraction: f64) !f64 {
    const parameters = properties.mualem_van_genuchten_parameters[cell];
    return parameters.pressureHeadAtWaterContentAssumeValid(std.math.clamp(
        water_fraction,
        parameters.residual_water_content_m3_per_m3,
        parameters.saturated_water_content_m3_per_m3,
    ));
}

pub fn matricPotentialMpaAt(properties: group_types.Properties, cell: usize, water_fraction: f64) !f64 {
    const parameters = properties.mualem_van_genuchten_parameters[cell];
    const bounded_water_content = std.math.clamp(
        water_fraction,
        parameters.residual_water_content_m3_per_m3,
        parameters.saturated_water_content_m3_per_m3,
    );
    return try parameters.pressureHeadAtWaterContent(bounded_water_content) *
        properties.gravitational_water_potential_mpa_per_m;
}

pub fn matricPotentialMpaAtAssumeValid(properties: group_types.Properties, cell: usize, water_fraction: f64) !f64 {
    const parameters = properties.mualem_van_genuchten_parameters[cell];
    const bounded_water_content = std.math.clamp(
        water_fraction,
        parameters.residual_water_content_m3_per_m3,
        parameters.saturated_water_content_m3_per_m3,
    );
    return try parameters.pressureHeadAtWaterContentAssumeValid(bounded_water_content) *
        properties.gravitational_water_potential_mpa_per_m;
}

pub fn frozenHydraulicImpedance(
    exponent: f64,
    ice_content_m3_per_m3: f64,
    parameters: retention.MualemVanGenuchtenParameters,
) f64 {
    const available_water_content =
        parameters.saturated_water_content_m3_per_m3 -
        parameters.residual_water_content_m3_per_m3;
    const fractional_ice_content = std.math.clamp(
        ice_content_m3_per_m3 / available_water_content,
        0,
        1,
    );
    return std.math.pow(f64, 10, -exponent * fractional_ice_content);
}

pub fn macroporeFrozenHydraulicImpedance(
    properties: group_types.Properties,
    grid: *const grid_module.GridState,
    cell: usize,
) f64 {
    if (grid.macropore_pore_capacity_m3[cell] <= 0) return 1;
    return frozenHydraulicImpedance(
        properties.frozen_hydraulic_impedance_exponent,
        grid.macropore_ice_water_m3[cell] /
            properties.ice_density_megagrams_per_m3 /
            grid.macropore_pore_capacity_m3[cell],
        properties.macropore_mualem_van_genuchten_parameters[cell],
    );
}

pub fn saturationMatricPotentialMpa(properties: group_types.Properties, cell: usize) f64 {
    _ = properties;
    _ = cell;
    return 0;
}

pub fn waterPressureMpaPerM() f64 {
    return 1000.0 * 9.80665 / 1_000_000.0;
}

pub fn poreCapacityRoundoffToleranceM3(capacity_m3: f64) f64 {
    // This is representational admissibility, not nonlinear convergence and
    // not conservation acceptance. Use an explicit machine-roundoff absolute
    // floor plus a capacity-scaled relative term; no universal model-scale
    // volume threshold is hidden here.
    const roundoff = 64.0 * std.math.floatEps(f64);
    return roundoff + roundoff * @abs(capacity_m3);
}

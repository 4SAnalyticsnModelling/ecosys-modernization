//! `solver` declarations: fixtures.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const grid_module = @import("../../state/grid.zig");
const heat = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const numerics = @import("../../core/numerics.zig");
const boundary_topology_module = @import("../profile/boundary_topology.zig");
const water_boundary = @import("../water/boundary.zig");
const enthalpy = @import("../water/enthalpy_balance.zig");
const retention = @import("../water/retention.zig");
const group_types = @import("solver_types.zig");

pub fn testProperties() group_types.Properties {
    const values = struct {
        const capacity = [_]f64{ 2, 2 };
        const zero = [_]f64{ 0, 0 };
        const density = [_]f64{ 1, 1 };
        const liquid = [_]f64{ 0.2, 0.2 };
        const air = [_]f64{ 0.3, 0.3 };
        const numerator = [_]f64{ 0.01, 0.01 };
        const denominator = [_]f64{ 1, 1 };
        const top = [_]bool{ true, false };
    };
    return .{ .heat_capacity_megajoules_per_k = &values.capacity, .minimum_heat_capacity_megajoules_per_k = &values.zero, .bulk_density_megagrams_per_m3 = &values.density, .liquid_water_fraction = &values.liquid, .ice_fraction = &values.zero, .air_fraction = &values.air, .fraction_of_pore_volume_air_filled = &values.air, .solid_conductivity_numerator_m_megajoules_per_h_k = &values.numerator, .solid_conductivity_denominator = &values.denominator, .is_top_soil_layer = &values.top, .top_snow_heat_capacity_megajoules_per_k = &values.zero, .maximum_negligible_snow_heat_capacity_megajoules_per_k = &values.zero, .snow_storage_heat_flux_megajoules = &values.zero, .cell_heat_source_megajoules = &values.zero, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .turbulence = .{ .water_fraction_threshold = 1, .air_fraction_threshold = 1, .water_rayleigh_coefficient = 0, .air_rayleigh_coefficient = 0, .water_nusselt_denominator = 1, .air_nusselt_denominator = 1 } };
}

//! **A5 DISPOSITION, corrected 2026-09-01 (register GRIDCELL-ACC-WRITEONLY-001):
//! `reset` IS called from production** (`ecosys_ng.zig:681` and `:3633`), and the
//! twelve compound-assignment writes into this array (canopy CO2/CH4/O2 exchange
//! plus six signed `redist` boundary terms) are real production writes, not test
//! code. The "never production bound" claim below was false. What remains true:
//! the array has zero production *readers* anywhere in `src/` -- it is written and
//! reset every hour but never consumed, so it is a dead accumulator kept only as a
//! potential debugging hook, not active flux accounting. Do not delete the reset
//! call or the twelve writes without first checking whether any legacy-equivalent
//! hourly diagnostic should be wired to read this array instead.
//!
//! Legacy source: `ecosys_f77/hour1.f` lines 2408--2432. This module is an exact,
//! tested, source-order translation of that range.
//!
//! Classification: diagnostic-only. This kernel resets legacy running totals that no
//! production module accumulates and no production module reads. Production
//! reconstructs the equivalent totals on demand in
//! `landscape_mass_balance_runtime.reconstruct`, which cannot drift from the
//! state it summarizes. Binding a reset for an accumulator that nothing
//! accumulates would add cost and no behaviour.
//!
//! Superseded by: `landscape_mass_balance_runtime.reconstruct`, called at `ecosys_ng.zig:5906`.
//!
//! Verified by field census (`tools/a5_hour1_field_census.ps1`): of its 31
//! fields, `soil_co2_carbon_g`, `total_organic_matter_g`,
//! `ionic_charge_equivalents`, and `canopy_evapotranspiration_m3_timestep`
//! appear in NO other `src/*.zig` file at all. Production does not accumulate
//! these legacy `UCO2S`/`TOMT`/`UNH4`-style grid-cell running totals.
//!
//! Do not bind this module, and do not delete it: the tests are a source-order
//! comparison oracle for the range above. Full argument and the census behind
//! it: `docs/traceability/hour1_2039_5200_binding_survey.md`.
const std = @import("std");

/// Per-grid-cell values reset by HOUR1 before hourly process accumulation.
/// Mass totals use legacy grid-cell units (g element), water uses m3, canopy
/// temperatures use K, vapor pressure uses kPa, and hourly exchanges retain
/// their legacy per-timestep units.
pub const GridCellAccumulators = struct {
    soil_co2_carbon_g: f64, // UCO2S
    total_organic_matter_g: f64, // TOMT
    total_organic_nitrogen_g: f64, // TONT
    total_organic_phosphorus_g: f64, // TOPT
    water_volume_m3: f64, // UVOLW
    litter_carbon_g: f64, // URSDC
    humus_carbon_g: f64, // UORGC
    litter_nitrogen_g: f64, // URSDN
    humus_nitrogen_g: f64, // UORGN
    litter_phosphorus_g: f64, // URSDP
    humus_phosphorus_g: f64, // UORGP
    ammonium_nitrogen_g: f64, // UNH4
    nitrate_nitrogen_g: f64, // UNO3
    phosphate_phosphorus_g: f64, // UPO4
    exchangeable_phosphorus_g: f64, // UPX4
    precipitated_phosphorus_g: f64, // UPP4
    ionic_charge_equivalents: f64, // UION
    canopy_surface_temperature_k: f64, // TKCT
    canopy_air_temperature_k: f64, // TKQT
    canopy_vapor_pressure_kpa: f64, // VPQT
    canopy_evapotranspiration_m3_timestep: f64, // TEVAPP
    canopy_co2_exchange_g_c_timestep: f64, // XCNET
    canopy_ch4_exchange_g_c_timestep: f64, // XHNET
    canopy_o2_exchange_g_o_timestep: f64, // XONET
    redist_carbon_surface_input_g_c_timestep: f64, // CO2GIN
    redist_carbon_subsurface_output_g_c_timestep: f64, // TCOU
    redist_oxygen_surface_input_g_o_timestep: f64, // OXYGIN
    redist_oxygen_subsurface_output_g_o_timestep: f64, // OXYGOU
    redist_hydrogen_surface_input_g_h_timestep: f64, // H2GIN
    redist_hydrogen_subsurface_output_g_h_timestep: f64, // H2GOU
    canopy_combustion_g_c_timestep: f64, // RCGCK
};

/// Translates `hour1.f` lines 2408--2432 in source assignment order.
pub fn reset(accumulators: *GridCellAccumulators) void {
    accumulators.soil_co2_carbon_g = 0.0;
    accumulators.total_organic_matter_g = 0.0;
    accumulators.total_organic_nitrogen_g = 0.0;
    accumulators.total_organic_phosphorus_g = 0.0;
    accumulators.water_volume_m3 = 0.0;
    accumulators.litter_carbon_g = 0.0;
    accumulators.humus_carbon_g = 0.0;
    accumulators.litter_nitrogen_g = 0.0;
    accumulators.humus_nitrogen_g = 0.0;
    accumulators.litter_phosphorus_g = 0.0;
    accumulators.humus_phosphorus_g = 0.0;
    accumulators.ammonium_nitrogen_g = 0.0;
    accumulators.nitrate_nitrogen_g = 0.0;
    accumulators.phosphate_phosphorus_g = 0.0;
    accumulators.exchangeable_phosphorus_g = 0.0;
    accumulators.precipitated_phosphorus_g = 0.0;
    accumulators.ionic_charge_equivalents = 0.0;
    accumulators.canopy_surface_temperature_k = 0.0;
    accumulators.canopy_air_temperature_k = 0.0;
    accumulators.canopy_vapor_pressure_kpa = 0.0;
    accumulators.canopy_evapotranspiration_m3_timestep = 0.0;
    accumulators.canopy_co2_exchange_g_c_timestep = 0.0;
    accumulators.canopy_ch4_exchange_g_c_timestep = 0.0;
    accumulators.canopy_o2_exchange_g_o_timestep = 0.0;
    accumulators.redist_carbon_surface_input_g_c_timestep = 0.0;
    accumulators.redist_carbon_subsurface_output_g_c_timestep = 0.0;
    accumulators.redist_oxygen_surface_input_g_o_timestep = 0.0;
    accumulators.redist_oxygen_subsurface_output_g_o_timestep = 0.0;
    accumulators.redist_hydrogen_surface_input_g_h_timestep = 0.0;
    accumulators.redist_hydrogen_subsurface_output_g_h_timestep = 0.0;
    accumulators.canopy_combustion_g_c_timestep = 0.0;
}

test "reset clears every hourly grid-cell accumulator" {
    var accumulators: GridCellAccumulators = undefined;
    inline for (std.meta.fields(GridCellAccumulators), 0..) |field, index| {
        @field(accumulators, field.name) = @floatFromInt(index + 1);
    }

    reset(&accumulators);

    inline for (std.meta.fields(GridCellAccumulators)) |field| {
        try std.testing.expectEqual(@as(f64, 0.0), @field(accumulators, field.name));
    }
}

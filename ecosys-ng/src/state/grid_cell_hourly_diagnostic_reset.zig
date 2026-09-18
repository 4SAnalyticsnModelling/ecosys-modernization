//! **A5 DISPOSITION: never production bound.**
//!
//! Legacy source: `ecosys_f77/hour1.f` lines 3015--3064. This module is an exact,
//! tested, source-order translation of that range and is imported only by
//! `src/module_index.zig`, so it is reachable by `zig build test` and unreachable
//! from `executeHourlyScience`. That is intentional and must stay that way.
//!
//! Classification: diagnostic-only. This kernel resets legacy running totals that no
//! production module accumulates and no production module reads. Production
//! reconstructs the equivalent totals on demand in
//! `landscape_mass_balance_runtime.reconstruct`, which cannot drift from the
//! state it summarizes. Binding a reset for an accumulator that nothing
//! accumulates would add cost and no behaviour.
//!
//! Superseded by: `landscape_mass_balance_runtime.reconstruct`.
//!
//! Field census: 54 declared fields, only 17 of which appear anywhere else
//! in `src/`, and those 17 are generic timestep-flux names owned by transport
//! modules rather than by any diagnostic accumulator.
//!
//! Do not bind this module, and do not delete it: the tests are a source-order
//! comparison oracle for the range above. Full argument and the census behind
//! it: `docs/traceability/hour1_2039_5200_binding_survey.md`.
const std = @import("std");

pub const WaterAndHeat = struct {
    runoff_water_m3_timestep: f64, // FLWR
    runoff_vapor_m3_timestep: f64, // FLVR
    runoff_heat_j_timestep: f64, // HFLWR
    vapor_water_flux_m3_timestep: f64, // XWFLVR
    vapor_heat_flux_j_timestep: f64, // XHFLVR
    freeze_water_flux_m3_timestep: f64, // XWFLFR
    freeze_heat_flux_j_timestep: f64, // XHFLFR
    ice_heat_j_timestep: f64, // HEATI
    soil_heat_j_timestep: f64, // HEATS
    evaporation_heat_j_timestep: f64, // HEATE
    vapor_heat_j_timestep: f64, // HEATV
    sensible_heat_j_timestep: f64, // HEATH
};

pub const GasDiffusion = struct {
    soil_carbon_dioxide_g_timestep: f64, // XCODFS
    soil_methane_g_timestep: f64, // XCHDFS
    soil_oxygen_g_timestep: f64, // XOXDFS
    soil_nitrogen_g_timestep: f64, // XNGDFS
    soil_nitrous_oxide_g_timestep: f64, // XN2DFS
    soil_ammonia_g_timestep: f64, // XN3DFS
    soil_nitrogen_balance_g_timestep: f64, // XNBDFS
    soil_hydrogen_g_timestep: f64, // XHGDFS
    residue_carbon_dioxide_g_timestep: f64, // XCODFR
    residue_methane_g_timestep: f64, // XCHDFR
    residue_oxygen_g_timestep: f64, // XOXDFR
    residue_nitrogen_g_timestep: f64, // XNGDFR
    residue_nitrous_oxide_g_timestep: f64, // XN2DFR
    residue_ammonia_g_timestep: f64, // XN3DFR
    residue_hydrogen_g_timestep: f64, // XHGDFR
};

pub const EcosystemTotals = struct {
    plant_water_volume_m3: f64, // TVOLWP
    canopy_water_volume_m3: f64, // TVOLWC
    ground_evaporation_m3_timestep: f64, // TEVAPG
    canopy_evaporation_m3_timestep: f64, // TEVAPC
    canopy_heat_flux_j_timestep: f64, // THFLXC
    canopy_energy_j_timestep: f64, // TENGYC
    carbon_dioxide_g_timestep: f64, // TCO2Z
    oxygen_g_timestep: f64, // TOXYZ
    methane_g_timestep: f64, // TCH4Z
    nitrous_oxide_g_timestep: f64, // TN2OZ
    ammonia_g_timestep: f64, // TNH3Z
    hydrogen_g_timestep: f64, // TH2GZ
    canopy_carbon_snow_g: f64, // ZCSNC
    canopy_nitrogen_snow_g: f64, // ZZSNC
    canopy_phosphorus_snow_g: f64, // ZPSNC
    standing_biomass_g: f64, // WTSTGT
    precipitation_m3_timestep: f64, // PPT
};

pub const LateralTotals = struct {
    snow_water_m3_timestep: f64, // XFLWSX
    liquid_water_m3_timestep: f64, // XFLWWX
    vapor_water_m3_timestep: f64, // XFLWVX
    ice_water_m3_timestep: f64, // XFLWIX
    heat_j_timestep: f64, // XHFLWX
    maximum_canopy_height_m: f64, // ZT
};

pub const GridCellDiagnostics = struct {
    water_and_heat: WaterAndHeat,
    gas_diffusion: GasDiffusion,
    ecosystem_totals: EcosystemTotals,
    lateral_totals: LateralTotals,
};

/// Translates `hour1.f` lines 3015--3064 in source assignment order.
pub fn reset(diagnostics: *GridCellDiagnostics) void {
    inline for (std.meta.fields(WaterAndHeat)) |field| {
        @field(diagnostics.water_and_heat, field.name) = 0.0;
    }
    inline for (std.meta.fields(GasDiffusion)) |field| {
        @field(diagnostics.gas_diffusion, field.name) = 0.0;
    }
    inline for (std.meta.fields(EcosystemTotals)) |field| {
        @field(diagnostics.ecosystem_totals, field.name) = 0.0;
    }
    inline for (std.meta.fields(LateralTotals)) |field| {
        @field(diagnostics.lateral_totals, field.name) = 0.0;
    }
}

test "grid-cell hourly reset clears every diagnostic field" {
    var diagnostics: GridCellDiagnostics = undefined;
    inline for (std.meta.fields(GridCellDiagnostics)) |group_field| {
        inline for (std.meta.fields(group_field.type)) |field| {
            @field(@field(diagnostics, group_field.name), field.name) = 11.0;
        }
    }

    reset(&diagnostics);

    inline for (std.meta.fields(GridCellDiagnostics)) |group_field| {
        inline for (std.meta.fields(group_field.type)) |field| {
            try std.testing.expectEqual(
                @as(f64, 0.0),
                @field(@field(diagnostics, group_field.name), field.name),
            );
        }
    }
}

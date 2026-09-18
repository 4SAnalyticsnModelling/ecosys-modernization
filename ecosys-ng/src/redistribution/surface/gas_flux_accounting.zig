const std = @import("std");

/// Gas boundary fluxes for one species at the soil-atmosphere interface
/// (g step-1 or g C step-1).
pub const SurfaceGasFluxes = struct {
    /// X*DFS. Soil surface exchange flux from trnsfr.f (g step-1).
    soil_surface_exchange_g: f64,
    /// X*FLG(3,NU). Convective+diffusive flux at mineral reference layer
    /// (g step-1).
    mineral_layer_convective_g: f64,
    /// T*Z. Bulk gas mass transfer term (g step-1).
    bulk_mass_transfer_g: f64,
    /// X*FLG(3,0). Convective+diffusive flux at surface litter (g step-1).
    litter_layer_convective_g: f64,
    /// X*DFR. Litter gas volatilization from trnsfr.f (g step-1).
    litter_volatilization_g: f64,
};

/// Water fluxes carrying dissolved gas (m3 step-1).
pub const AqueousFluxes = struct {
    /// FLQGQ. Water flux to snowpack or mineral surface from rain (m3 step-1).
    rain_to_surface_m3: f64,
    /// FLQRQ. Water flux to litter from rain (m3 step-1).
    rain_to_litter_m3: f64,
    /// FLQGI. Water flux to snowpack or mineral surface from irrigation
    /// (m3 step-1).
    irrigation_to_surface_m3: f64,
    /// FLQRI. Water flux to litter from irrigation (m3 step-1).
    irrigation_to_litter_m3: f64,
};

/// CO2 and CH4 specific inputs for lines 4465--4482.
pub const CarbonGasInputs = struct {
    co2_fluxes: SurfaceGasFluxes,
    ch4_fluxes: SurfaceGasFluxes,
    aqueous: AqueousFluxes,
    /// CCOR. CO2 concentration in rain (g m-3).
    co2_rain_concentration_g_per_m3: f64,
    /// CCOQ. CO2 concentration in irrigation (g m-3).
    co2_irrigation_concentration_g_per_m3: f64,
    /// CCHR. CH4 concentration in rain (g m-3).
    ch4_rain_concentration_g_per_m3: f64,
    /// CCHQ. CH4 concentration in irrigation (g m-3).
    ch4_irrigation_concentration_g_per_m3: f64,
    /// PRECU. Subsurface irrigation rate (m3 h-1).
    subsurface_irrigation_m3_per_h: f64,
    /// TRCO2(0). CO2 transfer from surface litter to subsurface (g C step-1).
    litter_subsurface_co2_transfer_g: f64,
    /// XNFH. Timestep (h step-1).
    timestep_h: f64,
};

/// O2 and H2 specific inputs for lines 4492--4507.
pub const OxygenHydrogenInputs = struct {
    o2_fluxes: SurfaceGasFluxes,
    h2_fluxes: SurfaceGasFluxes,
    aqueous: AqueousFluxes,
    /// COXR. O2 concentration in rain (g m-3).
    o2_rain_concentration_g_per_m3: f64,
    /// COXQ. O2 concentration in irrigation (g m-3).
    o2_irrigation_concentration_g_per_m3: f64,
    /// PRECU. Subsurface irrigation rate (m3 h-1).
    subsurface_irrigation_m3_per_h: f64,
    /// RUPOXO(0). Microbial O2 uptake in litter from nitro.f (g O step-1).
    litter_microbial_o2_uptake_g: f64,
    /// ROGOX(0). O2-limited litter O2 uptake from nitro.f (g O step-1).
    litter_o2_limited_uptake_g: f64,
    /// RC4OX(0). CH4 combustion O2 demand from nitro.f (g C step-1);
    /// multiplied by 2.667 (O:C mass ratio) to get g O.
    litter_ch4_combustion_g_c: f64,
    /// RH2GO(0). H2 output from litter (g H step-1).
    litter_h2_output_g: f64,
    /// XNFH. Timestep (h step-1).
    timestep_h: f64,
};

pub const CarbonGasIncrements = struct {
    /// CI. CO2 surface input (g C step-1). Added to XCNET, UCO2G, HCO2G, CO2GIN.
    co2_surface_input_g: f64,
    /// CH. CH4 surface input (g C step-1). Added to XHNET, UCH4G, HCH4G, CO2GIN.
    ch4_surface_input_g: f64,
    /// CO. Signed CO2 contribution to TCOU (g C step-1); subsurface
    /// irrigation produces a negative value in the source convention.
    co2_subsurface_flux_g: f64,
    /// CX. Signed CH4 contribution to TCOU (g C step-1); subsurface
    /// irrigation produces a negative value in the source convention.
    ch4_subsurface_flux_g: f64,
    /// Exact line-4482 increment: CO + CX - TRCO2(0) (g C step-1).
    total_subsurface_carbon_flux_g: f64,
};

pub const OxygenHydrogenIncrements = struct {
    /// OI. O2 surface input (g O step-1). Added to XONET, UOXYG, HOXYG, OXYGIN.
    o2_surface_input_g: f64,
    /// OO. O2 subsurface output magnitude (g O step-1). Added to OXYGOU.
    o2_subsurface_out_g: f64,
    /// HI. H2 surface input (g H step-1). Added to H2GIN.
    h2_surface_input_g: f64,
    /// HO = RH2GO(0). H2 output from litter (g H step-1). Added to H2GOU.
    h2_subsurface_out_g: f64,
};

fn gasInput(fluxes: SurfaceGasFluxes, rain_water: f64, irrigation_water: f64, rain_conc: f64, irr_conc: f64) f64 {
    return fluxes.soil_surface_exchange_g +
        fluxes.mineral_layer_convective_g +
        fluxes.bulk_mass_transfer_g +
        fluxes.litter_layer_convective_g +
        fluxes.litter_volatilization_g +
        rain_water * rain_conc +
        irrigation_water * irr_conc;
}

fn validateFluxes(fluxes: SurfaceGasFluxes) bool {
    return std.math.isFinite(fluxes.soil_surface_exchange_g) and
        std.math.isFinite(fluxes.mineral_layer_convective_g) and
        std.math.isFinite(fluxes.bulk_mass_transfer_g) and
        std.math.isFinite(fluxes.litter_layer_convective_g) and
        std.math.isFinite(fluxes.litter_volatilization_g);
}

fn validateAqueous(aq: AqueousFluxes) bool {
    return std.math.isFinite(aq.rain_to_surface_m3) and
        std.math.isFinite(aq.rain_to_litter_m3) and
        std.math.isFinite(aq.irrigation_to_surface_m3) and
        std.math.isFinite(aq.irrigation_to_litter_m3);
}

fn aqueousFluxesAreNonnegative(aq: AqueousFluxes) bool {
    return aq.rain_to_surface_m3 >= 0 and
        aq.rain_to_litter_m3 >= 0 and
        aq.irrigation_to_surface_m3 >= 0 and
        aq.irrigation_to_litter_m3 >= 0;
}

/// Direct translation of REDIST lines 4465--4482.
///
/// Computes CO2 and CH4 surface input (CI, CH) and subsurface output
/// (CO, CX) in source order. The production binding adds these to the
/// running accumulators (XCNET, XHNET, UCO2G, HCO2G, UCH4G, HCH4G,
/// CO2GIN, TCOU).
pub fn computeCarbonGas(inp: CarbonGasInputs) !CarbonGasIncrements {
    if (!std.math.isFinite(inp.timestep_h) or inp.timestep_h <= 0)
        return error.InvalidSurfaceGasFluxTimestep;
    if (!validateFluxes(inp.co2_fluxes) or !validateFluxes(inp.ch4_fluxes) or
        !validateAqueous(inp.aqueous) or
        !std.math.isFinite(inp.co2_rain_concentration_g_per_m3) or
        !std.math.isFinite(inp.co2_irrigation_concentration_g_per_m3) or
        !std.math.isFinite(inp.ch4_rain_concentration_g_per_m3) or
        !std.math.isFinite(inp.ch4_irrigation_concentration_g_per_m3) or
        !std.math.isFinite(inp.subsurface_irrigation_m3_per_h) or
        !std.math.isFinite(inp.litter_subsurface_co2_transfer_g))
        return error.InvalidSurfaceGasFluxInput;
    if (!aqueousFluxesAreNonnegative(inp.aqueous) or
        inp.co2_rain_concentration_g_per_m3 < 0 or
        inp.co2_irrigation_concentration_g_per_m3 < 0 or
        inp.ch4_rain_concentration_g_per_m3 < 0 or
        inp.ch4_irrigation_concentration_g_per_m3 < 0 or
        inp.subsurface_irrigation_m3_per_h < 0)
    {
        return error.NegativeSurfaceAqueousGasInput;
    }

    const aq = inp.aqueous;
    const rain_water = aq.rain_to_surface_m3 + aq.rain_to_litter_m3;
    const irr_water = aq.irrigation_to_surface_m3 + aq.irrigation_to_litter_m3;

    const ci = gasInput(inp.co2_fluxes, rain_water, irr_water, inp.co2_rain_concentration_g_per_m3, inp.co2_irrigation_concentration_g_per_m3);
    const ch = gasInput(inp.ch4_fluxes, rain_water, irr_water, inp.ch4_rain_concentration_g_per_m3, inp.ch4_irrigation_concentration_g_per_m3);

    // Lines 4473--4474 retain their negative source sign. These are ledger
    // contributions, not unsigned outflow magnitudes.
    const co = -inp.subsurface_irrigation_m3_per_h *
        inp.co2_irrigation_concentration_g_per_m3 * inp.timestep_h;
    const cx = -inp.subsurface_irrigation_m3_per_h *
        inp.ch4_irrigation_concentration_g_per_m3 * inp.timestep_h;
    const result = CarbonGasIncrements{
        .co2_surface_input_g = ci,
        .ch4_surface_input_g = ch,
        .co2_subsurface_flux_g = co,
        .ch4_subsurface_flux_g = cx,
        .total_subsurface_carbon_flux_g = co + cx -
            inp.litter_subsurface_co2_transfer_g,
    };
    inline for (@typeInfo(CarbonGasIncrements).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteSurfaceGasFluxIncrement;
    return result;
}

/// Direct translation of REDIST lines 4492--4507.
///
/// Computes O2 and H2 surface input/output in source order.
pub fn computeOxygenHydrogen(inp: OxygenHydrogenInputs) !OxygenHydrogenIncrements {
    if (!std.math.isFinite(inp.timestep_h) or inp.timestep_h <= 0)
        return error.InvalidSurfaceGasFluxTimestep;
    if (!validateFluxes(inp.o2_fluxes) or !validateFluxes(inp.h2_fluxes) or
        !validateAqueous(inp.aqueous) or
        !std.math.isFinite(inp.o2_rain_concentration_g_per_m3) or
        !std.math.isFinite(inp.o2_irrigation_concentration_g_per_m3) or
        !std.math.isFinite(inp.subsurface_irrigation_m3_per_h) or
        !std.math.isFinite(inp.litter_microbial_o2_uptake_g) or
        !std.math.isFinite(inp.litter_o2_limited_uptake_g) or
        !std.math.isFinite(inp.litter_ch4_combustion_g_c) or
        !std.math.isFinite(inp.litter_h2_output_g))
        return error.InvalidSurfaceGasFluxInput;
    if (!aqueousFluxesAreNonnegative(inp.aqueous) or
        inp.o2_rain_concentration_g_per_m3 < 0 or
        inp.o2_irrigation_concentration_g_per_m3 < 0 or
        inp.subsurface_irrigation_m3_per_h < 0)
    {
        return error.NegativeSurfaceAqueousGasInput;
    }

    const aq = inp.aqueous;
    const rain_water = aq.rain_to_surface_m3 + aq.rain_to_litter_m3;
    const irr_water = aq.irrigation_to_surface_m3 + aq.irrigation_to_litter_m3;

    const oi = gasInput(inp.o2_fluxes, rain_water, irr_water, inp.o2_rain_concentration_g_per_m3, inp.o2_irrigation_concentration_g_per_m3);

    // Lines 4498-4499: OO = RUPOXO(0) - PRECU*COXQ*XNFH + ROGOX(0) + RC4OX(0)*2.667
    const oo = inp.litter_microbial_o2_uptake_g -
        inp.subsurface_irrigation_m3_per_h *
            inp.o2_irrigation_concentration_g_per_m3 * inp.timestep_h +
        inp.litter_o2_limited_uptake_g +
        inp.litter_ch4_combustion_g_c * 2.667;

    // Lines 4503-4504: HI = XHGDFS + XHGFLG(3,NU) + TH2GZ + XHGFLG(3,0) + XHGDFR
    const hi = inp.h2_fluxes.soil_surface_exchange_g +
        inp.h2_fluxes.mineral_layer_convective_g +
        inp.h2_fluxes.bulk_mass_transfer_g +
        inp.h2_fluxes.litter_layer_convective_g +
        inp.h2_fluxes.litter_volatilization_g;

    const result = OxygenHydrogenIncrements{
        .o2_surface_input_g = oi,
        .o2_subsurface_out_g = oo,
        .h2_surface_input_g = hi,
        .h2_subsurface_out_g = inp.litter_h2_output_g,
    };
    inline for (@typeInfo(OxygenHydrogenIncrements).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteSurfaceGasFluxIncrement;
    return result;
}

fn defaultAqueous() AqueousFluxes {
    return .{
        .rain_to_surface_m3 = 0.001,
        .rain_to_litter_m3 = 0.002,
        .irrigation_to_surface_m3 = 0.0005,
        .irrigation_to_litter_m3 = 0.001,
    };
}

fn defaultCo2Fluxes() SurfaceGasFluxes {
    return .{
        .soil_surface_exchange_g = 0.5,
        .mineral_layer_convective_g = 0.1,
        .bulk_mass_transfer_g = 0.3,
        .litter_layer_convective_g = 0.05,
        .litter_volatilization_g = 0.02,
    };
}

test "REDIST surface CO2 flux sums gas inputs in source order" {
    const result = try computeCarbonGas(.{
        .co2_fluxes = defaultCo2Fluxes(),
        .ch4_fluxes = std.mem.zeroes(SurfaceGasFluxes),
        .aqueous = defaultAqueous(),
        .co2_rain_concentration_g_per_m3 = 0.6,
        .co2_irrigation_concentration_g_per_m3 = 0.4,
        .ch4_rain_concentration_g_per_m3 = 0.0,
        .ch4_irrigation_concentration_g_per_m3 = 0.0,
        .subsurface_irrigation_m3_per_h = 0.001,
        .litter_subsurface_co2_transfer_g = 0.0,
        .timestep_h = 1.0,
    });
    const aq = defaultAqueous();
    const rain_water = aq.rain_to_surface_m3 + aq.rain_to_litter_m3;
    const irr_water = aq.irrigation_to_surface_m3 + aq.irrigation_to_litter_m3;
    const expected_ci = 0.5 + 0.1 + 0.3 + 0.05 + 0.02 +
        rain_water * 0.6 + irr_water * 0.4;
    try std.testing.expectApproxEqRel(expected_ci, result.co2_surface_input_g, 1.0e-14);
}

test "REDIST surface carbon subsurface flux preserves source sign and TRCO2 term" {
    const result = try computeCarbonGas(.{
        .co2_fluxes = std.mem.zeroes(SurfaceGasFluxes),
        .ch4_fluxes = std.mem.zeroes(SurfaceGasFluxes),
        .aqueous = std.mem.zeroes(AqueousFluxes),
        .co2_rain_concentration_g_per_m3 = 0.0,
        .co2_irrigation_concentration_g_per_m3 = 0.5,
        .ch4_rain_concentration_g_per_m3 = 0.0,
        .ch4_irrigation_concentration_g_per_m3 = 0.25,
        .subsurface_irrigation_m3_per_h = 0.002,
        .litter_subsurface_co2_transfer_g = 0.0003,
        .timestep_h = 1.0,
    });
    const co: f64 = -0.002 * 0.5 * 1.0;
    const cx: f64 = -0.002 * 0.25 * 1.0;
    try std.testing.expectEqual(co, result.co2_subsurface_flux_g);
    try std.testing.expectEqual(cx, result.ch4_subsurface_flux_g);
    try std.testing.expectEqual(
        co + cx - 0.0003,
        result.total_subsurface_carbon_flux_g,
    );
}

test "REDIST surface gas accounting rejects negative aqueous inputs" {
    var aqueous = defaultAqueous();
    aqueous.rain_to_litter_m3 = -1.0e-6;
    try std.testing.expectError(
        error.NegativeSurfaceAqueousGasInput,
        computeCarbonGas(.{
            .co2_fluxes = defaultCo2Fluxes(),
            .ch4_fluxes = std.mem.zeroes(SurfaceGasFluxes),
            .aqueous = aqueous,
            .co2_rain_concentration_g_per_m3 = 0.6,
            .co2_irrigation_concentration_g_per_m3 = 0.4,
            .ch4_rain_concentration_g_per_m3 = 0.0,
            .ch4_irrigation_concentration_g_per_m3 = 0.0,
            .subsurface_irrigation_m3_per_h = 0.001,
            .litter_subsurface_co2_transfer_g = 0.0,
            .timestep_h = 1.0,
        }),
    );
}

test "REDIST surface O2 flux includes CH4 combustion stoichiometry" {
    const result = try computeOxygenHydrogen(.{
        .o2_fluxes = std.mem.zeroes(SurfaceGasFluxes),
        .h2_fluxes = std.mem.zeroes(SurfaceGasFluxes),
        .aqueous = std.mem.zeroes(AqueousFluxes),
        .o2_rain_concentration_g_per_m3 = 0.0,
        .o2_irrigation_concentration_g_per_m3 = 0.0,
        .subsurface_irrigation_m3_per_h = 0.0,
        .litter_microbial_o2_uptake_g = 0.1,
        .litter_o2_limited_uptake_g = 0.05,
        .litter_ch4_combustion_g_c = 0.03,
        .litter_h2_output_g = 0.0,
        .timestep_h = 1.0,
    });
    // OO = 0.1 + 0 + 0.05 + 0.03*2.667
    try std.testing.expectApproxEqRel(
        0.1 + 0.05 + 0.03 * 2.667,
        result.o2_subsurface_out_g,
        1.0e-14,
    );
}

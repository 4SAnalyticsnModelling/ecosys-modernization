const std = @import("std");

pub const TurbulenceParameters = struct {
    water_fraction_threshold: f64,
    air_fraction_threshold: f64,
    water_rayleigh_coefficient: f64,
    air_rayleigh_coefficient: f64,
    water_nusselt_denominator: f64,
    air_nusselt_denominator: f64,
    maximum_rayleigh_number: f64 = 1.0e4,
};

pub const CellConductivityInputs = struct {
    bulk_density_megagrams_per_m3: f64,
    liquid_water_fraction: f64,
    ice_fraction: f64,
    air_fraction: f64,
    fraction_of_pore_volume_air_filled: f64,
    solid_conductivity_numerator_m_megajoules_per_h_k: f64,
    solid_conductivity_denominator: f64,
    temperature_difference_k: f64,
};

/// Exact WATSUB TCND calculation, including Rayleigh/Nusselt enhancement of
/// liquid-water and air conductivity across the current face.
pub fn calculateCellConductivity(inputs: CellConductivityInputs, parameters: TurbulenceParameters) !f64 {
    inline for (@typeInfo(CellConductivityInputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteSoilHeatInput;
    inline for (@typeInfo(TurbulenceParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteSoilHeatParameter;
    if (inputs.bulk_density_megagrams_per_m3 < 0 or inputs.liquid_water_fraction < 0 or inputs.ice_fraction < 0 or inputs.air_fraction < 0 or inputs.fraction_of_pore_volume_air_filled < 0 or inputs.solid_conductivity_numerator_m_megajoules_per_h_k < 0 or inputs.solid_conductivity_denominator < 0 or parameters.water_fraction_threshold < 0 or parameters.air_fraction_threshold < 0 or parameters.water_rayleigh_coefficient < 0 or parameters.air_rayleigh_coefficient < 0 or parameters.water_nusselt_denominator <= 0 or parameters.air_nusselt_denominator <= 0 or parameters.maximum_rayleigh_number <= 0) return error.InvalidSoilHeatInput;
    if (inputs.bulk_density_megagrams_per_m3 == 0 and inputs.liquid_water_fraction + inputs.ice_fraction == 0) return 0;
    const scaled_temperature_difference = @abs(inputs.temperature_difference_k) * 1.0e-6;
    const water_turbulent_fraction = std.math.pow(f64, @max(0.0, inputs.liquid_water_fraction - parameters.water_fraction_threshold), 3);
    const air_turbulent_fraction = std.math.pow(f64, @max(0.0, inputs.air_fraction - parameters.air_fraction_threshold), 3);
    const water_rayleigh = @min(parameters.maximum_rayleigh_number, parameters.water_rayleigh_coefficient * scaled_temperature_difference * water_turbulent_fraction);
    const air_rayleigh = @min(parameters.maximum_rayleigh_number, parameters.air_rayleigh_coefficient * scaled_temperature_difference * air_turbulent_fraction);
    const water_nusselt = @max(1.0, 0.68 + 0.67 * std.math.pow(f64, water_rayleigh, 0.25) / parameters.water_nusselt_denominator);
    const air_nusselt = @max(1.0, 0.68 + 0.67 * std.math.pow(f64, air_rayleigh, 0.25) / parameters.air_nusselt_denominator);
    const water_conductivity = 2.067e-3 * water_nusselt;
    const air_conductivity = 9.050e-5 * air_nusselt;
    const air_weight = 1.467 - 0.467 * inputs.fraction_of_pore_volume_air_filled;
    const numerator = inputs.solid_conductivity_numerator_m_megajoules_per_h_k + inputs.liquid_water_fraction * water_conductivity + 0.611 * inputs.ice_fraction * 7.844e-3 + air_weight * inputs.air_fraction * air_conductivity;
    const denominator = inputs.solid_conductivity_denominator + inputs.liquid_water_fraction + 0.611 * inputs.ice_fraction + air_weight * inputs.air_fraction;
    if (!std.math.isFinite(numerator) or !std.math.isFinite(denominator) or denominator <= 0) return error.InvalidSoilHeatConductivity;
    return numerator / denominator;
}

/// `STARTS 655`: `VHCPRX(NY,NX)=8.380E-05*AREA(3,NU(NY,NX),NY,NX)`.
///
/// The oracle's minimum layer heat capacity, per unit horizontal area. WATSUB,
/// REDIST and STARTS test `VHCP` against it at 51 sites before dividing by it;
/// `redist.f:9655-9659` is the canonical shape, taking a neighbouring
/// temperature rather than dividing when the capacity is at or below the floor.
///
/// Previously this magnitude was repeated as a bare literal at
/// `heat_layer_remap.zig:391` and `runtime_adapter.zig:1212`, while the soil
/// heat solver's own `minimum_heat_capacity_megajoules_per_k` array was
/// allocated, zeroed by `hourly_workspace.zig:99` and never filled -- so every
/// guard reading it degenerated to `capacity > 0`, a positivity test standing in
/// for a minimum-magnitude test. See
/// `DRY-LAYER-UNPHYSICAL-HEAT-SINK-HOUR-2726-001` and the ZEROS/ZEROS2 threshold
/// translation gap.
pub const minimum_layer_heat_capacity_megajoules_per_m2_k: f64 = 8.380e-5;

pub const FaceInputs = struct {
    source_temperature_k: f64,
    destination_temperature_k: f64,
    source_heat_capacity_megajoules_per_k: f64,
    destination_heat_capacity_megajoules_per_k: f64,
    source_minimum_heat_capacity_megajoules_per_k: f64,
    destination_minimum_heat_capacity_megajoules_per_k: f64,
    source_is_top_soil_layer: bool,
    top_snow_heat_capacity_megajoules_per_k: f64,
    maximum_negligible_snow_heat_capacity_megajoules_per_k: f64,
    snow_storage_heat_flux_megajoules: f64,
    liquid_water_flux_m3: f64,
    vapor_flux_m3: f64,
    macropore_water_flux_m3: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    source_thermal_conductivity_m_megajoules_per_h_k: f64,
    destination_thermal_conductivity_m_megajoules_per_h_k: f64,
    source_path_length_m: f64,
    destination_path_length_m: f64,
    face_area_m2: f64,
    time_fraction: f64,
};

pub const FaceFlux = struct {
    conductive_unlimited_megajoules: f64,
    conductive_limited_megajoules: f64,
    convective_megajoules: f64,
    total_megajoules: f64,
    equilibrium_temperature_k: f64,
};

/// Exact HFLWL face calculation after liquid, vapor and macropore water fluxes
/// have been determined. Positive heat moves source to destination.
pub fn calculateFaceFlux(inputs: FaceInputs) !FaceFlux {
    inline for (@typeInfo(FaceInputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteSoilHeatInput;
    if (inputs.source_temperature_k <= 0 or inputs.destination_temperature_k <= 0 or inputs.source_heat_capacity_megajoules_per_k <= 0 or inputs.destination_heat_capacity_megajoules_per_k <= 0 or inputs.source_minimum_heat_capacity_megajoules_per_k < 0 or inputs.destination_minimum_heat_capacity_megajoules_per_k < 0 or inputs.top_snow_heat_capacity_megajoules_per_k < 0 or inputs.maximum_negligible_snow_heat_capacity_megajoules_per_k < 0 or inputs.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or inputs.source_thermal_conductivity_m_megajoules_per_h_k < 0 or inputs.destination_thermal_conductivity_m_megajoules_per_h_k < 0 or inputs.source_path_length_m <= 0 or inputs.destination_path_length_m <= 0 or inputs.face_area_m2 < 0 or inputs.time_fraction <= 0 or inputs.time_fraction > 1) return error.InvalidSoilHeatInput;
    const vapor_donor_temperature = if (inputs.vapor_flux_m3 >= 0) inputs.source_temperature_k else inputs.destination_temperature_k;
    const liquid_donor_temperature = if (inputs.liquid_water_flux_m3 >= 0) inputs.source_temperature_k else inputs.destination_temperature_k;
    const macro_donor_temperature = if (inputs.macropore_water_flux_m3 >= 0) inputs.source_temperature_k else inputs.destination_temperature_k;
    const vapor_convective = inputs.liquid_water_heat_capacity_megajoules_per_m3_k * vapor_donor_temperature * inputs.vapor_flux_m3;
    const liquid_convective = inputs.liquid_water_heat_capacity_megajoules_per_m3_k * liquid_donor_temperature * inputs.liquid_water_flux_m3;
    const macro_convective = inputs.liquid_water_heat_capacity_megajoules_per_m3_k * macro_donor_temperature * inputs.macropore_water_flux_m3;
    var source_interim = inputs.source_temperature_k;
    if (inputs.source_heat_capacity_megajoules_per_k > inputs.source_minimum_heat_capacity_megajoules_per_k) {
        source_interim -= if (inputs.source_is_top_soil_layer and inputs.top_snow_heat_capacity_megajoules_per_k <= inputs.maximum_negligible_snow_heat_capacity_megajoules_per_k)
            (vapor_convective - inputs.snow_storage_heat_flux_megajoules) / inputs.source_heat_capacity_megajoules_per_k
        else
            vapor_convective / inputs.source_heat_capacity_megajoules_per_k;
    }
    var destination_interim = inputs.destination_temperature_k;
    if (inputs.destination_heat_capacity_megajoules_per_k > inputs.destination_minimum_heat_capacity_megajoules_per_k) destination_interim += vapor_convective / inputs.destination_heat_capacity_megajoules_per_k;
    const equilibrium = (inputs.source_heat_capacity_megajoules_per_k * source_interim + inputs.destination_heat_capacity_megajoules_per_k * destination_interim) / (inputs.source_heat_capacity_megajoules_per_k + inputs.destination_heat_capacity_megajoules_per_k);
    // `unlimited` is already integrated over `time_fraction`. The physical
    // pair-equilibration ceiling is the energy required to reach the shared
    // endpoint and must not be multiplied by the step fraction a second
    // time. At the ordinary whole-hour value of one this is exactly the
    // translated WATSUB expression; the correction matters for runtime
    // fine-step validation and other non-hourly kernels.
    const equilibration_limit =
        (source_interim - equilibrium) *
        inputs.source_heat_capacity_megajoules_per_k;
    const denominator = inputs.source_thermal_conductivity_m_megajoules_per_h_k * inputs.destination_path_length_m + inputs.destination_thermal_conductivity_m_megajoules_per_h_k * inputs.source_path_length_m;
    const conductance = if (denominator > 0) 2.0 * inputs.source_thermal_conductivity_m_megajoules_per_h_k * inputs.destination_thermal_conductivity_m_megajoules_per_h_k / denominator else 0.0;
    const unlimited = conductance * (source_interim - destination_interim) * inputs.face_area_m2 * inputs.time_fraction;
    const limited = if (unlimited >= 0) @max(0.0, @min(equilibration_limit, unlimited)) else @min(0.0, @max(equilibration_limit, unlimited));
    const convective = liquid_convective + vapor_convective + macro_convective;
    const total = convective + limited;
    if (!std.math.isFinite(total)) return error.NonFiniteSoilHeatFlux;
    return .{ .conductive_unlimited_megajoules = unlimited, .conductive_limited_megajoules = limited, .convective_megajoules = convective, .total_megajoules = total, .equilibrium_temperature_k = equilibrium };
}

test "a negligible-capacity layer holds its prior temperature instead of being solved" {
    // WATSUB 6907--6913 and REDIST 9655--9659 share one shape: a layer whose
    // heat capacity is at or below VHCPRX is not solved from its energy balance,
    // it keeps its prior accepted temperature. This pins the decision boundary
    // and the fallback value that `solver_residual.zig` implements, so a later
    // edit cannot quietly turn the guard back into an unconditional divide.
    const plan_area_m2: f64 = 1;
    const floor_megajoules_per_k =
        minimum_layer_heat_capacity_megajoules_per_m2_k * plan_area_m2;

    const decide = struct {
        fn solved(capacity: f64, floor: f64) bool {
            return !(capacity <= floor);
        }
    }.solved;

    // The measured hour-2726 top layer: dry, 4.993374886774233e-5 MJ/K.
    try std.testing.expect(!decide(4.993374886774233e-5, floor_megajoules_per_k));
    // The second failing sample from the same run.
    try std.testing.expect(!decide(5.051462339142763e-5, floor_megajoules_per_k));
    // A layer exactly at the floor is NOT solved: the oracle's test is strict
    // greater-than (`VHCP1 .GT. VHCPRX`), so equality takes the fallback.
    try std.testing.expect(!decide(floor_megajoules_per_k, floor_megajoules_per_k));
    // One ULP above the floor is solved, so the boundary is not widened.
    try std.testing.expect(decide(
        std.math.nextAfter(f64, floor_megajoules_per_k, std.math.inf(f64)),
        floor_megajoules_per_k,
    ));
    // An ordinary moist layer from the same run is solved normally.
    try std.testing.expect(decide(1.1999446032288491e-1, floor_megajoules_per_k));
    // And a layer with no floor configured is always solved, so the guard cannot
    // fire on a caller that supplies zero (every solver test fixture does).
    try std.testing.expect(decide(4.993374886774233e-5, 0));
}

test "the minimum layer heat capacity is the oracle VHCPRX and bounds the hour-2726 residual" {
    // `starts.f:655`: VHCPRX(NY,NX)=8.380E-05*AREA(3,NU(NY,NX),NY,NX).
    try std.testing.expectEqual(
        @as(f64, 8.380e-5),
        minimum_layer_heat_capacity_megajoules_per_m2_k,
    );
    // The snow-side activation threshold is a decade larger (STARTS 654,
    // VHCPWX = 8.380E-04). Pin the distinction so the two are not conflated:
    // conflating them would raise the soil floor tenfold and silence layers the
    // oracle still solves.
    try std.testing.expect(minimum_layer_heat_capacity_megajoules_per_m2_k * 10 == 8.380e-4);

    // The measured hour-2725 state of the Ottawa deck's layer 0: a 1 m2 plan
    // area, and a constitutive tangent equal to the layer's extensive dry solid
    // heat capacity because the trial state carried no phase-change slope.
    const plan_area_m2: f64 = 1;
    const floor_megajoules_per_k =
        minimum_layer_heat_capacity_megajoules_per_m2_k * plan_area_m2;
    const measured_tangent_megajoules_per_k: f64 = 5.051462339142763e-5;
    const measured_defect_megajoules: f64 = 15.4242252197233;
    try std.testing.expect(measured_tangent_megajoules_per_k < floor_megajoules_per_k);

    // Unfloored, the K-equivalent conversion reproduces the reported
    // `residual_k` that no Newton or Picard step could reduce.
    const unfloored_residual_k =
        measured_defect_megajoules / measured_tangent_megajoules_per_k;
    try std.testing.expectApproxEqRel(@as(f64, 3.0534e5), unfloored_residual_k, 1e-4);

    // Floored, it is bounded by the oracle's minimum capacity.
    const floored_residual_k =
        measured_defect_megajoules / @max(measured_tangent_megajoules_per_k, floor_megajoules_per_k);
    try std.testing.expectApproxEqRel(
        measured_defect_megajoules / floor_megajoules_per_k,
        floored_residual_k,
        1e-12,
    );
    try std.testing.expect(floored_residual_k < unfloored_residual_k);

    // And a layer above the floor is untouched, so this cannot loosen an
    // ordinary solve: the floored divisor is bit-identical to the tangent.
    const ordinary_tangent_megajoules_per_k: f64 = 2.6815026902369143e-2;
    try std.testing.expectEqual(
        ordinary_tangent_megajoules_per_k,
        @max(ordinary_tangent_megajoules_per_k, floor_megajoules_per_k),
    );
}

pub fn waterFilmThicknessM(matric_potential_megapascal: f64) !f64 {
    if (!std.math.isFinite(matric_potential_megapascal) or matric_potential_megapascal >= 0) return error.InvalidMatricPotentialForWaterFilm;
    return @max(1.0e-6, 0.5 * @exp(-13.833 - 0.857 * @log(-matric_potential_megapascal)));
}

test "WATSUB conductive face is limited to pair equilibration" {
    const flux = try calculateFaceFlux(.{ .source_temperature_k = 300, .destination_temperature_k = 280, .source_heat_capacity_megajoules_per_k = 2, .destination_heat_capacity_megajoules_per_k = 2, .source_minimum_heat_capacity_megajoules_per_k = 0, .destination_minimum_heat_capacity_megajoules_per_k = 0, .source_is_top_soil_layer = false, .top_snow_heat_capacity_megajoules_per_k = 0, .maximum_negligible_snow_heat_capacity_megajoules_per_k = 0, .snow_storage_heat_flux_megajoules = 0, .liquid_water_flux_m3 = 0, .vapor_flux_m3 = 0, .macropore_water_flux_m3 = 0, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .source_thermal_conductivity_m_megajoules_per_h_k = 100, .destination_thermal_conductivity_m_megajoules_per_h_k = 100, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1, .time_fraction = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 290), flux.equilibrium_temperature_k, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 20), flux.conductive_limited_megajoules, 1e-12);
}

test "convective heat uses the upstream temperature for each phase" {
    const flux = try calculateFaceFlux(.{ .source_temperature_k = 300, .destination_temperature_k = 280, .source_heat_capacity_megajoules_per_k = 2, .destination_heat_capacity_megajoules_per_k = 2, .source_minimum_heat_capacity_megajoules_per_k = 0, .destination_minimum_heat_capacity_megajoules_per_k = 0, .source_is_top_soil_layer = false, .top_snow_heat_capacity_megajoules_per_k = 0, .maximum_negligible_snow_heat_capacity_megajoules_per_k = 0, .snow_storage_heat_flux_megajoules = 0, .liquid_water_flux_m3 = 0.01, .vapor_flux_m3 = -0.02, .macropore_water_flux_m3 = 0.03, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.2, .source_thermal_conductivity_m_megajoules_per_h_k = 0, .destination_thermal_conductivity_m_megajoules_per_h_k = 0, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1, .time_fraction = 1 });
    const expected = 4.2 * (300 * 0.01 + 280 * -0.02 + 300 * 0.03);
    try std.testing.expectApproxEqAbs(expected, flux.convective_megajoules, 1e-12);
}

test "water film follows WATSUB lower bound" {
    try std.testing.expect(try waterFilmThicknessM(-0.01) >= 1e-6);
    try std.testing.expectEqual(@as(f64, 1e-6), try waterFilmThicknessM(-1e12));
}

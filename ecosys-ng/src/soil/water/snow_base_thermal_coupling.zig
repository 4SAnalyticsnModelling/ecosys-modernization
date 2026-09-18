//! Continuous conductive heat exchange at the base of the snowpack.
//!
//! WATSUB forms two conductive faces under the lowest active snow layer that
//! are entirely distinct from the meltwater carrier heat already owned by
//! `snow_surface_transfer_heat.zig`. Both live inside the source's
//! `DO 9880 L=1,JS` sweep, in the `ICHKL.EQ.0` branch that runs exactly once
//! per column on the lowest active layer (`watsub.f:1423--1424`, `:1475`,
//! `:1624`, `:2293`).
//!
//! Snow to bare soil surface, `watsub.f:1773--1796`:
//!
//! ```fortran
//!       WTHET2=1.467-0.467*THETPY(NUM(NY,NX),NY,NX)
//!       TCNDS=(STC(NUM(NY,NX),NY,NX)+THETWX(NUM(NY,NX),NY,NX)
//!      2*2.067E-03+0.611*THETIX(NUM(NY,NX),NY,NX)*7.844E-03
//!      3+WTHET2*THETPX(NUM(NY,NX),NY,NX)*9.050E-05)
//!      4/(DTC(NUM(NY,NX),NY,NX)+THETWX(NUM(NY,NX),NY,NX)
//!      5+0.611*THETIX(NUM(NY,NX),NY,NX)
//!      6+WTHET2*THETPX(NUM(NY,NX),NY,NX))
//!       IF(BARE(NY,NX).GT.ZERO)THEN
//!       ATCNDS=2.0*TCND1W*TCNDS/(TCND1W*DLYR(3,NUM(NY,NX),NY,NX)
//!      2+TCNDS*DLYRS0(L,NY,NX))
//!       ELSE
//!       ATCNDS=0.0
//!       ENDIF
//!       HFLWC=ATCNDS*(TK02(L)-TKS2)*AREA(3,NUM(NY,NX),NY,NX)
//!      2*FSNW(NY,NX)*BARE(NY,NX)*XNPYX
//!       TKY=(TK02(L)*VHCPWM2(L,NY,NX)
//!      2+TKS2*VHCP1(NUM(NY,NX),NY,NX))
//!      3/(VHCPWM2(L,NY,NX)+VHCP1(NUM(NY,NX),NY,NX))
//!       HFLWX=(TK02(L)-TKY)*VHCPWM2(L,NY,NX)
//!       IF(HFLWC.GE.0.0)THEN
//!       HFLWS1=AMAX1(0.0,AMIN1(HFLWX,HFLWC))
//!       ELSE
//!       HFLWS1=AMIN1(0.0,AMAX1(HFLWX,HFLWC))
//!       ENDIF
//! ```
//!
//! Snow to surface litter, `watsub.f:1861--1872` and `:2025--2033`:
//!
//! ```fortran
//!       THETRR=AMAX1(0.0,1.0-THETPX(0,NY,NX)-THETWX(0,NY,NX)
//!      2-THETIX(0,NY,NX))
//!       TCNDR=(0.779*THETRR*9.050E-04+0.622*THETWX(0,NY,NX)
//!      2*2.067E-03+0.380*THETIX(0,NY,NX)*7.844E-03+THETPX(0,NY,NX)
//!      3*9.050E-05)/(0.779*THETRR+0.622*THETWX(0,NY,NX)
//!      4+0.380*THETIX(0,NY,NX)+THETPX(0,NY,NX))
//!       IF(TCND1W.GT.ZERO.AND.TCNDR.GT.ZERO)THEN
//!       ATCNDR=2.0*TCND1W*TCNDR
//!      2/(TCND1W*DLYRR(NY,NX)+TCNDR*DLYRS0(L,NY,NX))
//!       ELSE
//!       ATCNDR=0.0
//!       ENDIF
//!       ...
//!       TKY=(TK022*VHCPWM2(L,NY,NX)+TKR22*VHCPR2)
//!      2/(VHCPWM2(L,NY,NX)+VHCPR2)
//!       HFLWX=(TK022-TKY)*VHCPWM2(L,NY,NX)*XNPR
//!       HFLWC=ATCNDR*(TK022-TKR22)*AREA(3,NUM(NY,NX),NY,NX)
//!      2*FSNW(NY,NX)*CVRD(NY,NX)*XNPQX
//!       IF(HFLWC.GE.0.0)THEN
//!       HFLWSRX=AMAX1(0.0,AMIN1(HFLWX,HFLWC))
//!       ELSE
//!       HFLWSRX=AMIN1(0.0,AMAX1(HFLWX,HFLWC))
//!       ENDIF
//! ```
//!
//! Snow loses both, `watsub.f:2259`:
//! `THFLWWX=HFLW0W(L,NY,NX)-HFLVSR-HFLWSR-HFLVS1-HFLWS1`, and each recipient
//! gains its own, `watsub.f:2235` (`HFLWLT` to soil) and `:2241` (`HFLWRT` to
//! litter).
//!
//! Two deliberate, documented departures from the literal source text:
//!
//!  1. **No substep-count divisor.** The source's litter bound carries `XNPR`
//!     (`= 1/NPR`, `wthr.f:611`) because `HFLWSRX` is re-evaluated inside the
//!     shorter `XNPQX` residue loop and accumulated (`watsub.f:2164`). Per
//!     `MIGRATION.md`, `NPR`/`NPS`/`NPRS` are iteration ceilings in ecosys-ng,
//!     not time-splitting factors; each lane is evaluated once per accepted
//!     substep with that substep's own `time_step_hours`, exactly as
//!     `snow_heat_conduction.zig` already does for the internal snow faces.
//!  2. **The snow-side equalization capacity is apportioned by cover.** The
//!     source applies the full `VHCPWM2(L)` to both lanes independently, so
//!     their two bounds can jointly overshoot the pack's own joint equilibrium
//!     and invert the gradient; the source is protected only by the `XNPR`
//!     shrink that departure 1 removes. Because `BARE + CVRD = 1` exactly, the
//!     two apportioned snow capacities sum to `VHCPWM2(L)`, so the accepted
//!     pair can never remove more than one joint equalization. This is
//!     bit-identical to the source whenever a single lane carries the whole
//!     footprint (`BARE = 1` or `CVRD = 1`).
//!
//! This module moves energy only. No water crosses either face, so the
//! recipient heat capacities are unchanged and the water census is untouched
//! by construction.

const std = @import("std");
const snow_heat_conduction = @import("snow_heat_conduction.zig");

pub const Interface = struct {
    /// WATSUB `ATCNDS`/`ATCNDR` after the area and cover scaling
    /// (MJ h-1 K-1).
    conductance_megajoules_per_h_k: f64,
    /// WATSUB `HFLWC`, the conductance-form flux before the limiter (MJ).
    unlimited_heat_megajoules: f64,
    /// WATSUB `HFLWS1`/`HFLWSRX`. Positive moves heat out of the snowpack base
    /// and into the recipient (MJ).
    accepted_heat_megajoules: f64,
};

pub const zero_interface: Interface = .{
    .conductance_megajoules_per_h_k = 0,
    .unlimited_heat_megajoules = 0,
    .accepted_heat_megajoules = 0,
};

pub const Inputs = struct {
    /// WATSUB `TK02(L)`, the lowest active snow layer's interim temperature.
    snow_temperature_k: f64,
    /// WATSUB `TKS2` (soil lane) or `TKR22` (litter lane).
    recipient_temperature_k: f64,
    /// WATSUB `VHCPWM2(L,NY,NX)`.
    snow_heat_capacity_megajoules_per_k: f64,
    /// WATSUB `VHCP1(NUM(NY,NX),NY,NX)` (soil lane) or `VHCPR2` (litter lane).
    recipient_heat_capacity_megajoules_per_k: f64,
    /// WATSUB `TCND1W` (`watsub.f:1448`).
    snow_conductivity_m_megajoules_per_h_k: f64,
    /// WATSUB `TCNDS` (`watsub.f:1774`) or `TCNDR` (`watsub.f:1863`).
    recipient_conductivity_m_megajoules_per_h_k: f64,
    /// WATSUB `DLYRS0(L,NY,NX)`.
    snow_thickness_m: f64,
    /// WATSUB `DLYR(3,NUM(NY,NX),NY,NX)` (soil lane) or `DLYRR(NY,NX)`
    /// (litter lane).
    recipient_thickness_m: f64,
    /// WATSUB `AREA(3,NUM(NY,NX),NY,NX)`.
    horizontal_area_m2: f64,
    /// WATSUB `FSNW(NY,NX)`, frozen before same-substep precipitation changes
    /// snow depth.
    snow_cover_fraction: f64,
    /// WATSUB `BARE(NY,NX)` for the soil lane, `CVRD(NY,NX)` for the litter
    /// lane. The two partition the footprint exactly.
    recipient_cover_fraction: f64,
    /// WATSUB `XNPYX`/`XNPQX`. Physical integration factor, not an inventory
    /// availability fraction.
    time_step_hours: f64,
};

/// WATSUB 1781--1782 and 1868--1869 harmonic interface conductance, per unit
/// ground area (MJ m-2 h-1 K-1).
///
/// The pairing is crossed: the snow conductivity multiplies the *recipient*
/// thickness and the recipient conductivity multiplies the *snow* thickness.
/// A degenerate zero denominator yields zero conductance, matching the same
/// guard `snow_heat_conduction.solve` applies to the internal snow faces.
pub fn interfaceConductanceMegajoulesPerM2HK(
    snow_conductivity_m_megajoules_per_h_k: f64,
    recipient_conductivity_m_megajoules_per_h_k: f64,
    snow_thickness_m: f64,
    recipient_thickness_m: f64,
) !f64 {
    inline for (.{
        snow_conductivity_m_megajoules_per_h_k,
        recipient_conductivity_m_megajoules_per_h_k,
        snow_thickness_m,
        recipient_thickness_m,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidSnowBaseConductanceInput;
    if (snow_conductivity_m_megajoules_per_h_k <= 0 or
        recipient_conductivity_m_megajoules_per_h_k <= 0) return 0;
    const denominator = snow_conductivity_m_megajoules_per_h_k * recipient_thickness_m +
        recipient_conductivity_m_megajoules_per_h_k * snow_thickness_m;
    if (!(denominator > 0)) return 0;
    const conductance = 2 * snow_conductivity_m_megajoules_per_h_k *
        recipient_conductivity_m_megajoules_per_h_k / denominator;
    if (!std.math.isFinite(conductance) or conductance < 0)
        return error.InvalidSnowBaseConductance;
    return conductance;
}

/// WATSUB 1861--1866 `THETRR`/`TCNDR`, surface-litter thermal conductivity
/// (MJ m-1 h-1 K-1) from the current litter air, water, and ice
/// concentrations. There is no other owner of this quantity in the tree; the
/// soil-surface twin `TCNDS` is already owned by `soil/heat/thermal.zig`.
///
/// The dry-litter, water, and ice weights (`0.779`, `0.622`, `0.380`) differ
/// from the mineral-soil weights, so this is not a reuse of `TCNDS`.
pub fn litterConductivityMMegajoulesPerHK(
    water_fraction_m3_per_m3: f64,
    ice_fraction_m3_per_m3: f64,
    air_fraction_m3_per_m3: f64,
) !f64 {
    inline for (.{ water_fraction_m3_per_m3, ice_fraction_m3_per_m3, air_fraction_m3_per_m3 }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterConductivityState;
    const dry_fraction = @max(0, 1 - air_fraction_m3_per_m3 -
        water_fraction_m3_per_m3 - ice_fraction_m3_per_m3);
    const numerator = 0.779 * dry_fraction * 9.050e-4 +
        0.622 * water_fraction_m3_per_m3 * 2.067e-3 +
        0.380 * ice_fraction_m3_per_m3 * 7.844e-3 +
        air_fraction_m3_per_m3 * 9.050e-5;
    const denominator = 0.779 * dry_fraction +
        0.622 * water_fraction_m3_per_m3 +
        0.380 * ice_fraction_m3_per_m3 +
        air_fraction_m3_per_m3;
    if (!(denominator > 0)) return 0;
    const conductivity = numerator / denominator;
    if (!std.math.isFinite(conductivity) or conductivity < 0)
        return error.InvalidLitterConductivityState;
    return conductivity;
}

/// WATSUB 1786--1796 (`HFLWS1`) and 2025--2033 (`HFLWSRX`). Forms the
/// conductance flux, then keeps the limited value through the shared
/// `HFLWX` joint-equilibrium bound so a single number can be debited from the
/// snowpack and credited to the recipient.
pub fn acceptedInterfaceHeat(inputs: Inputs) !Interface {
    inline for (std.meta.fields(Inputs)) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) {
            std.log.err(
                "non-finite snow base thermal coupling input: field={s} value={e}",
                .{ field.name, value },
            );
            return error.NonFiniteSnowBaseThermalInput;
        }
    }
    if (inputs.snow_temperature_k <= 0 or inputs.recipient_temperature_k <= 0 or
        inputs.snow_heat_capacity_megajoules_per_k < 0 or
        inputs.recipient_heat_capacity_megajoules_per_k < 0 or
        inputs.snow_conductivity_m_megajoules_per_h_k < 0 or
        inputs.recipient_conductivity_m_megajoules_per_h_k < 0 or
        inputs.snow_thickness_m < 0 or inputs.recipient_thickness_m < 0 or
        inputs.horizontal_area_m2 <= 0 or
        inputs.snow_cover_fraction < 0 or inputs.snow_cover_fraction > 1 or
        inputs.recipient_cover_fraction < 0 or inputs.recipient_cover_fraction > 1 or
        inputs.time_step_hours <= 0 or inputs.time_step_hours > 1)
        return error.InvalidSnowBaseThermalInput;

    // WATSUB 1780--1785 and 1867--1872 make the conductance exactly zero when
    // the recipient does not occupy the footprint or either material has no
    // conductivity. WATSUB 1425 (snow) and 1846 (litter) additionally require
    // both owners to hold heat capacity before the branch is entered at all,
    // so an empty pack or an absent recipient transfers nothing.
    if (inputs.recipient_cover_fraction <= 0 or inputs.snow_cover_fraction <= 0 or
        inputs.snow_heat_capacity_megajoules_per_k <= 0 or
        inputs.recipient_heat_capacity_megajoules_per_k <= 0)
        return zero_interface;

    const areal_conductance = try interfaceConductanceMegajoulesPerM2HK(
        inputs.snow_conductivity_m_megajoules_per_h_k,
        inputs.recipient_conductivity_m_megajoules_per_h_k,
        inputs.snow_thickness_m,
        inputs.recipient_thickness_m,
    );
    if (areal_conductance == 0) return zero_interface;
    const conductance = areal_conductance * inputs.horizontal_area_m2 *
        inputs.snow_cover_fraction * inputs.recipient_cover_fraction;
    if (!std.math.isFinite(conductance) or conductance < 0)
        return error.InvalidSnowBaseThermalConductance;
    const unlimited_heat = conductance *
        (inputs.snow_temperature_k - inputs.recipient_temperature_k) *
        inputs.time_step_hours;
    // Departure 2 (see the module header): the snow-side equalization capacity
    // belongs to this lane's share of the footprint, so the soil and litter
    // lanes together cannot pass the pack's own joint equilibrium.
    const lane_snow_capacity = inputs.snow_heat_capacity_megajoules_per_k *
        inputs.recipient_cover_fraction;
    const accepted_heat = try snow_heat_conduction.acceptedEqualizingHeat(
        unlimited_heat,
        inputs.snow_temperature_k,
        inputs.recipient_temperature_k,
        lane_snow_capacity,
        inputs.recipient_heat_capacity_megajoules_per_k,
    );
    if (!std.math.isFinite(unlimited_heat) or !std.math.isFinite(accepted_heat))
        return error.InvalidSnowBaseThermalHeat;
    return .{
        .conductance_megajoules_per_h_k = conductance,
        .unlimited_heat_megajoules = unlimited_heat,
        .accepted_heat_megajoules = accepted_heat,
    };
}

/// Applies signed conductive heat to a recipient whose heat capacity does not
/// change, because no water crosses this face. Returns the recipient's new
/// temperature.
pub fn acceptedRecipientTemperatureK(
    heat_capacity_megajoules_per_k: f64,
    temperature_k: f64,
    signed_heat_megajoules: f64,
) !f64 {
    inline for (.{ heat_capacity_megajoules_per_k, temperature_k, signed_heat_megajoules }) |value|
        if (!std.math.isFinite(value)) return error.InvalidSnowBaseRecipientState;
    if (heat_capacity_megajoules_per_k <= 0 or temperature_k <= 0)
        return error.InvalidSnowBaseRecipientState;
    const next = temperature_k + signed_heat_megajoules / heat_capacity_megajoules_per_k;
    if (!std.math.isFinite(next) or next <= 0) {
        std.log.err(
            "invalid snow base conduction recipient temperature: capacity_megajoules_per_k={e} temperature_k={e} signed_heat_megajoules={e} candidate_k={e}",
            .{ heat_capacity_megajoules_per_k, temperature_k, signed_heat_megajoules, next },
        );
        return error.InvalidSnowBaseRecipientTemperature;
    }
    return next;
}

fn testInputs() Inputs {
    return .{
        .snow_temperature_k = 272,
        .recipient_temperature_k = 266,
        .snow_heat_capacity_megajoules_per_k = 0.08,
        .recipient_heat_capacity_megajoules_per_k = 1.4,
        .snow_conductivity_m_megajoules_per_h_k = snow_heat_conduction.conductivityMMegajoulesPerHK(
            testConductionParameters(),
            0.25,
        ),
        .recipient_conductivity_m_megajoules_per_h_k = 4.0e-3,
        .snow_thickness_m = 0.4,
        .recipient_thickness_m = 0.05,
        .horizontal_area_m2 = 1,
        .snow_cover_fraction = 1,
        .recipient_cover_fraction = 1,
        .time_step_hours = 1,
    };
}

fn testConductionParameters() snow_heat_conduction.Parameters {
    return .{
        .conductivity_scale_m_megajoules_per_h_k = 0.0036,
        .conductivity_density_exponent_m3_per_megagram = 2.650,
        .conductivity_log10_intercept = -1.652,
        .maximum_effective_density_megagrams_per_m3 = 0.6,
        .ice_density_megagrams_per_m3 = 0.92,
    };
}

test "snow base conduction moves heat downward when the pack is warmer" {
    const interface = try acceptedInterfaceHeat(testInputs());
    try std.testing.expect(interface.conductance_megajoules_per_h_k > 0);
    try std.testing.expect(interface.unlimited_heat_megajoules > 0);
    try std.testing.expect(interface.accepted_heat_megajoules > 0);
    try std.testing.expect(interface.accepted_heat_megajoules <=
        interface.unlimited_heat_megajoules);
}

test "snow base conduction reverses sign when the recipient is warmer" {
    var inputs = testInputs();
    inputs.snow_temperature_k = 266;
    inputs.recipient_temperature_k = 272;
    const interface = try acceptedInterfaceHeat(inputs);
    try std.testing.expect(interface.unlimited_heat_megajoules < 0);
    try std.testing.expect(interface.accepted_heat_megajoules < 0);
    const mirrored = try acceptedInterfaceHeat(testInputs());
    try std.testing.expectApproxEqRel(
        mirrored.unlimited_heat_megajoules,
        -interface.unlimited_heat_megajoules,
        16 * std.math.floatEps(f64),
    );
}

test "snow base conduction books one equal and opposite value on both sides" {
    const inputs = testInputs();
    const interface = try acceptedInterfaceHeat(inputs);
    const snow_after = try acceptedRecipientTemperatureK(
        inputs.snow_heat_capacity_megajoules_per_k,
        inputs.snow_temperature_k,
        -interface.accepted_heat_megajoules,
    );
    const recipient_after = try acceptedRecipientTemperatureK(
        inputs.recipient_heat_capacity_megajoules_per_k,
        inputs.recipient_temperature_k,
        interface.accepted_heat_megajoules,
    );
    const before = inputs.snow_heat_capacity_megajoules_per_k * inputs.snow_temperature_k +
        inputs.recipient_heat_capacity_megajoules_per_k * inputs.recipient_temperature_k;
    const after = inputs.snow_heat_capacity_megajoules_per_k * snow_after +
        inputs.recipient_heat_capacity_megajoules_per_k * recipient_after;
    try std.testing.expectApproxEqAbs(before, after, 64 * std.math.floatEps(f64) * before);
    try std.testing.expect(snow_after < inputs.snow_temperature_k);
    try std.testing.expect(recipient_after > inputs.recipient_temperature_k);
}

test "snow base conduction never passes joint equilibrium" {
    // A very thin, low-capacity pack against a large recipient: the
    // conductance form vastly exceeds the available energy, so the HFLWX bound
    // must bind and must stop exactly at the equilibrium temperature.
    var inputs = testInputs();
    inputs.snow_heat_capacity_megajoules_per_k = 1e-4;
    inputs.snow_thickness_m = 1e-4;
    const interface = try acceptedInterfaceHeat(inputs);
    try std.testing.expect(interface.accepted_heat_megajoules <
        interface.unlimited_heat_megajoules);
    const equilibrium = (inputs.snow_temperature_k * inputs.snow_heat_capacity_megajoules_per_k +
        inputs.recipient_temperature_k * inputs.recipient_heat_capacity_megajoules_per_k) /
        (inputs.snow_heat_capacity_megajoules_per_k +
            inputs.recipient_heat_capacity_megajoules_per_k);
    const snow_after = try acceptedRecipientTemperatureK(
        inputs.snow_heat_capacity_megajoules_per_k,
        inputs.snow_temperature_k,
        -interface.accepted_heat_megajoules,
    );
    const recipient_after = try acceptedRecipientTemperatureK(
        inputs.recipient_heat_capacity_megajoules_per_k,
        inputs.recipient_temperature_k,
        interface.accepted_heat_megajoules,
    );
    try std.testing.expectApproxEqAbs(equilibrium, snow_after, 1e-9);
    try std.testing.expect(snow_after >= recipient_after);
    try std.testing.expect(snow_after >= equilibrium - 1e-9);
}

test "cover-apportioned bounds keep the two lanes inside one joint equalization" {
    // Same recipient temperature and capacity on both lanes, a stiff pack, and
    // an even footprint split. The literal source form would allow each lane
    // its own full-capacity bound; the apportioned form must sum to at most a
    // single joint equalization against the combined recipient mass.
    var soil = testInputs();
    soil.snow_heat_capacity_megajoules_per_k = 1e-4;
    soil.snow_thickness_m = 1e-4;
    soil.recipient_cover_fraction = 0.5;
    var litter = soil;
    litter.recipient_conductivity_m_megajoules_per_h_k = 1.0e-3;
    const soil_interface = try acceptedInterfaceHeat(soil);
    const litter_interface = try acceptedInterfaceHeat(litter);
    const total = soil_interface.accepted_heat_megajoules +
        litter_interface.accepted_heat_megajoules;
    const combined_recipient_capacity = soil.recipient_heat_capacity_megajoules_per_k +
        litter.recipient_heat_capacity_megajoules_per_k;
    const joint_equilibrium = (soil.snow_temperature_k * soil.snow_heat_capacity_megajoules_per_k +
        soil.recipient_temperature_k * combined_recipient_capacity) /
        (soil.snow_heat_capacity_megajoules_per_k + combined_recipient_capacity);
    const joint_bound = (soil.snow_temperature_k - joint_equilibrium) *
        soil.snow_heat_capacity_megajoules_per_k;
    try std.testing.expect(total > 0);
    try std.testing.expect(total <= (soil.snow_temperature_k - soil.recipient_temperature_k) *
        soil.snow_heat_capacity_megajoules_per_k);
    try std.testing.expect(joint_bound > 0);
    const snow_after = try acceptedRecipientTemperatureK(
        soil.snow_heat_capacity_megajoules_per_k,
        soil.snow_temperature_k,
        -total,
    );
    try std.testing.expect(snow_after >= soil.recipient_temperature_k);
}

test "snow base conduction is zero without snow cover, pack, or recipient" {
    var bare = testInputs();
    bare.snow_cover_fraction = 0;
    try std.testing.expectEqual(zero_interface, try acceptedInterfaceHeat(bare));

    var empty_pack = testInputs();
    empty_pack.snow_heat_capacity_megajoules_per_k = 0;
    try std.testing.expectEqual(zero_interface, try acceptedInterfaceHeat(empty_pack));

    var uncovered = testInputs();
    uncovered.recipient_cover_fraction = 0;
    try std.testing.expectEqual(zero_interface, try acceptedInterfaceHeat(uncovered));

    var absent_recipient = testInputs();
    absent_recipient.recipient_heat_capacity_megajoules_per_k = 0;
    try std.testing.expectEqual(zero_interface, try acceptedInterfaceHeat(absent_recipient));

    var nonconductive = testInputs();
    nonconductive.recipient_conductivity_m_megajoules_per_h_k = 0;
    try std.testing.expectEqual(zero_interface, try acceptedInterfaceHeat(nonconductive));

    var isothermal = testInputs();
    isothermal.recipient_temperature_k = isothermal.snow_temperature_k;
    const flat = try acceptedInterfaceHeat(isothermal);
    try std.testing.expectEqual(@as(f64, 0), flat.accepted_heat_megajoules);
}

test "mid-winter base conduction cools the soil at a rate the deck cannot hide" {
    // Bounded stand-in for the observed winter regression: the modern
    // sub-snow profile relaxed to isothermal at +3.2 .. +4.1 degrees C under a
    // pack whose density stalled at 0.243 Mg m-3, while the measured modern
    // ground heat flux never left [-7.31, +15.32] W m-2 against legacy's
    // [-800.9, +412.0]. This test asserts the restored face has the predicted
    // sign and a magnitude the deck's own diagnostic range cannot contain.
    const parameters = testConductionParameters();
    const megajoules_per_hour_to_watts: f64 = 1.0e6 / 3600.0;
    const observed_modern_ground_flux_ceiling_watts_per_m2: f64 = 15.32;
    var winter = testInputs();
    winter.snow_temperature_k = 263.15;
    winter.recipient_temperature_k = 277.15;
    winter.snow_conductivity_m_megajoules_per_h_k =
        snow_heat_conduction.conductivityMMegajoulesPerHK(parameters, 0.243);
    winter.snow_thickness_m = 0.10;
    winter.recipient_conductivity_m_megajoules_per_h_k = 4.0e-3;
    winter.recipient_thickness_m = 0.05;
    // A whole active column, so the two-body equalization bound does not
    // truncate the one-hour rate being measured.
    winter.recipient_heat_capacity_megajoules_per_k = 2.5;
    winter.snow_heat_capacity_megajoules_per_k = 2.5;
    const modern = try acceptedInterfaceHeat(winter);
    // Predicted direction: heat leaves the warm soil for the cold pack.
    try std.testing.expect(modern.accepted_heat_megajoules < 0);
    try std.testing.expectEqual(modern.unlimited_heat_megajoules, modern.accepted_heat_megajoules);
    const modern_watts_per_m2 = @abs(modern.accepted_heat_megajoules) *
        megajoules_per_hour_to_watts / winter.horizontal_area_m2;
    try std.testing.expect(modern_watts_per_m2 > observed_modern_ground_flux_ceiling_watts_per_m2);
    // Predicted magnitude: enough to move a 1 m, 2.5 MJ K-1 column by several
    // degrees over the 40-day window the regression was measured across.
    const window_hours: f64 = 40 * 24;
    const column_cooling_k = @abs(modern.accepted_heat_megajoules) * window_hours /
        winter.recipient_heat_capacity_megajoules_per_k;
    try std.testing.expect(column_cooling_k > 2);

    // Legacy's denser pack conducts harder still, so the missing face also
    // explains the density feedback: a colder pack compacts, and a denser pack
    // conducts more.
    var legacy = winter;
    legacy.snow_conductivity_m_megajoules_per_h_k =
        snow_heat_conduction.conductivityMMegajoulesPerHK(parameters, 0.375);
    legacy.snow_thickness_m = 0.10 / 1.25;
    const legacy_interface = try acceptedInterfaceHeat(legacy);
    try std.testing.expect(@abs(legacy_interface.accepted_heat_megajoules) >
        @abs(modern.accepted_heat_megajoules));
}

test "snow base conductance uses the crossed WATSUB harmonic pairing" {
    const snow_conductivity: f64 = 3.0e-4;
    const recipient_conductivity: f64 = 6.0e-3;
    const snow_thickness: f64 = 0.4;
    const recipient_thickness: f64 = 0.05;
    const expected = 2 * snow_conductivity * recipient_conductivity /
        (snow_conductivity * recipient_thickness + recipient_conductivity * snow_thickness);
    try std.testing.expectEqual(expected, try interfaceConductanceMegajoulesPerM2HK(
        snow_conductivity,
        recipient_conductivity,
        snow_thickness,
        recipient_thickness,
    ));
    // The crossed pairing is not symmetric under swapping the two thicknesses.
    try std.testing.expect(expected != try interfaceConductanceMegajoulesPerM2HK(
        snow_conductivity,
        recipient_conductivity,
        recipient_thickness,
        snow_thickness,
    ));
    try std.testing.expectEqual(@as(f64, 0), try interfaceConductanceMegajoulesPerM2HK(
        snow_conductivity,
        recipient_conductivity,
        0,
        0,
    ));
}

test "litter conductivity reproduces the WATSUB TCNDR weights" {
    const water: f64 = 0.2;
    const ice: f64 = 0.1;
    const air: f64 = 0.5;
    const dry = 1 - water - ice - air;
    const expected = (0.779 * dry * 9.050e-4 + 0.622 * water * 2.067e-3 +
        0.380 * ice * 7.844e-3 + air * 9.050e-5) /
        (0.779 * dry + 0.622 * water + 0.380 * ice + air);
    try std.testing.expectEqual(
        expected,
        try litterConductivityMMegajoulesPerHK(water, ice, air),
    );
    // Saturated litter is far more conductive than air-filled litter.
    const wet = try litterConductivityMMegajoulesPerHK(0.9, 0, 0.1);
    const dryer = try litterConductivityMMegajoulesPerHK(0.05, 0, 0.95);
    try std.testing.expect(wet > dryer);
    // WATSUB's THETRR complement makes an all-zero-fraction litter pure dry
    // residue, so the limit is the dry-residue conductivity, not zero. The
    // zero-denominator guard is unreachable through this formulation and is
    // retained only as a defensive floor for direct callers.
    try std.testing.expectApproxEqRel(
        @as(f64, 9.050e-4),
        try litterConductivityMMegajoulesPerHK(0, 0, 0),
        16 * std.math.floatEps(f64),
    );
    try std.testing.expectError(
        error.InvalidLitterConductivityState,
        litterConductivityMMegajoulesPerHK(-0.1, 0, 0.5),
    );
}

test "snow conductivity helper matches the source J Glaciology law" {
    const parameters = testConductionParameters();
    const density: f64 = 0.243;
    try std.testing.expectEqual(
        0.0036 * std.math.pow(f64, 10, 2.650 * density - 1.652),
        snow_heat_conduction.conductivityMMegajoulesPerHK(parameters, density),
    );
    // The observed modern/legacy density pair from the winter regression:
    // legacy's denser pack is more than twice as conductive.
    const modern = snow_heat_conduction.conductivityMMegajoulesPerHK(parameters, 0.243);
    const legacy = snow_heat_conduction.conductivityMMegajoulesPerHK(parameters, 0.375);
    try std.testing.expect(legacy / modern > 2);
    try std.testing.expectEqual(
        parameters.maximum_effective_density_megagrams_per_m3,
        snow_heat_conduction.effectiveDensityMegagramsPerM3(parameters, 10, 0, 0, 1, 0.05),
    );
    try std.testing.expectEqual(
        @as(f64, 0.05),
        snow_heat_conduction.effectiveDensityMegagramsPerM3(parameters, 0, 0, 0, 0, 0.05),
    );
}

const std = @import("std");

pub const Cations = struct {
    ammonium_non_band: f64,
    ammonium_band: f64,
    hydrogen: f64,
    aluminum: f64,
    iron: f64,
    calcium: f64,
    magnesium: f64,
    sodium: f64,
    potassium: f64,
};

pub const SourceIterationStage = enum {
    before_iteration_ceiling,
    iteration_ceiling,
};

pub const Selectivity = struct {
    calcium_ammonium: f64,
    calcium_hydrogen: f64,
    calcium_aluminum_and_iron: f64,
    calcium_magnesium: f64,
    calcium_sodium: f64,
    calcium_potassium: f64,
};

pub const Inputs = struct {
    cation_exchange_capacity_mol_charge_per_megagram: f64,
    aqueous_concentration_mol_per_m3: Cations,
    aqueous_activity_mol_per_m3: Cations,
    exchange_concentration_mol_per_megagram: Cations,
    ammonium_non_band_fraction: f64,
    ammonium_band_fraction: f64,
    soil_mass_per_water_volume_megagrams_per_m3: f64,
};

pub const Parameters = struct {
    selectivity: Selectivity,
    substrate_limit_fraction: f64,
    maximum_adsorption_mol_charge_per_m3_step: f64,
};

pub const SourceEquationControls = struct {
    /// Runtime replacement for SOLUTE.F `ZEROC` in the activity roots.
    minimum_activity_mol_per_m3: f64,
};

/// Runtime layer gate corresponding to SOLUTE.F line 1213. The extensive
/// capacity (`XCEC`, mol) is distinct from the mass-specific concentration
/// (`CCEC`, mol charge Mg-1) used by the equilibrium equations.
pub const LayerAdmission = struct {
    cation_exchange_capacity_mol: f64,
    minimum_exchange_capacity_mol: f64,
};

/// Positive values adsorb aqueous cations. Trivalent and divalent values are
/// returned in moles of ion per Mg; their charge-weighted sum is exactly zero.
pub fn calculate(inputs: Inputs, parameters: Parameters) !Cations {
    try validate(inputs, parameters);
    if (inputs.cation_exchange_capacity_mol_charge_per_megagram == 0) return zeroCations();

    const equilibrium_charge = try equilibriumCharge(inputs, parameters.selectivity);
    var current_charge = inputs.exchange_concentration_mol_per_megagram;
    current_charge.aluminum *= 3;
    current_charge.iron *= 3;
    current_charge.calcium *= 2;
    current_charge.magnesium *= 2;
    normalizeSiteCharge(
        &current_charge,
        inputs.cation_exchange_capacity_mol_charge_per_megagram,
        inputs.ammonium_non_band_fraction,
        inputs.ammonium_band_fraction,
    );

    const rate_fraction_per_megagram = parameters.substrate_limit_fraction / inputs.soil_mass_per_water_volume_megagrams_per_m3;
    const maximum_per_megagram = parameters.maximum_adsorption_mol_charge_per_m3_step / inputs.soil_mass_per_water_volume_megagrams_per_m3;
    var raw: Cations = undefined;
    inline for (@typeInfo(Cations).@"struct".fields) |field| {
        const name = field.name;
        // SOLUTE.F applies XMIN in charge equivalents:
        //   Al/Fe: FIONC * 3 * min(exchange ion mol, aqueous ion mol)
        //   Ca/Mg: FIONC * 2 * min(exchange ion mol, aqueous ion mol)
        // `current_charge` is already charge-weighted, so the aqueous side
        // must receive the same valence before the minimum is taken. The
        // substrate limit itself uses the unnormalized X*1 inventory, not
        // the FY-normalized X*Y current term used in the driving force.
        const available = availableCharge(
            name,
            @field(inputs.exchange_concentration_mol_per_megagram, name),
            @field(inputs.aqueous_concentration_mol_per_m3, name),
        );
        const limit = rate_fraction_per_megagram * available;
        @field(raw, name) = std.math.clamp(@field(equilibrium_charge, name) - @field(current_charge, name), -@min(maximum_per_megagram, limit), @min(maximum_per_megagram, limit));
    }

    closeSiteChargeAndConvertToIonMoles(
        &raw,
        inputs.ammonium_non_band_fraction,
        inputs.ammonium_band_fraction,
    );
    return raw;
}

/// Direct state update for SOLUTE.F 2392--2400. Exchange concentrations are
/// not floor-clamped in the source and the block is skipped at `M == MRXN`.
pub fn applySourceOrderStateUpdate(
    current: Cations,
    changes: Cations,
    stage: SourceIterationStage,
) !Cations {
    inline for (@typeInfo(Cations).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(current, field.name)) or
            @field(current, field.name) < 0 or
            !std.math.isFinite(@field(changes, field.name)))
            return error.InvalidCationExchangeStateUpdate;
    }
    if (stage == .iteration_ceiling) return current;

    var next = current;
    inline for (.{
        "ammonium_non_band",
        "ammonium_band",
        "hydrogen",
        "aluminum",
        "iron",
        "calcium",
        "magnesium",
        "sodium",
        "potassium",
    }) |name| {
        @field(next, name) = @field(current, name) + @field(changes, name);
        if (!std.math.isFinite(@field(next, name)) or @field(next, name) < 0)
            return error.InvalidCationExchangeStateUpdate;
    }
    return next;
}

/// Direct source-order translation shared by SOLUTE.F lines 1210--1365 and
/// the repeated restricted-domain block at lines 3351--3508.
///
/// NH4 exchanger coordinates are concentrations on their respective zone
/// geometry. Their contributions to the whole-layer CEC therefore carry the
/// corresponding zone fractions, exactly as in STARTE initialization.
pub fn calculateSourceOrder(
    inputs: Inputs,
    parameters: Parameters,
    controls: SourceEquationControls,
) !Cations {
    try validate(inputs, parameters);
    if (!std.math.isFinite(controls.minimum_activity_mol_per_m3) or
        controls.minimum_activity_mol_per_m3 <= 0)
        return error.InvalidCationExchangeParameter;
    if (inputs.cation_exchange_capacity_mol_charge_per_megagram == 0)
        return zeroCations();

    const equilibrium_charge = try sourceOrderEquilibriumCharge(
        inputs,
        parameters.selectivity,
        controls.minimum_activity_mol_per_m3,
    );
    var current_charge = inputs.exchange_concentration_mol_per_megagram;
    current_charge.aluminum *= 3;
    current_charge.iron *= 3;
    current_charge.calcium *= 2;
    current_charge.magnesium *= 2;
    normalizeSiteCharge(
        &current_charge,
        inputs.cation_exchange_capacity_mol_charge_per_megagram,
        inputs.ammonium_non_band_fraction,
        inputs.ammonium_band_fraction,
    );

    const substrate_fraction_per_megagram =
        parameters.substrate_limit_fraction /
        inputs.soil_mass_per_water_volume_megagrams_per_m3;
    const maximum_per_megagram =
        parameters.maximum_adsorption_mol_charge_per_m3_step /
        inputs.soil_mass_per_water_volume_megagrams_per_m3;
    var raw = sourceOrderRawChargeChanges(
        inputs,
        equilibrium_charge,
        current_charge,
        substrate_fraction_per_megagram,
        maximum_per_megagram,
    );
    closeSiteChargeAndConvertToIonMoles(
        &raw,
        inputs.ammonium_non_band_fraction,
        inputs.ammonium_band_fraction,
    );
    return raw;
}

/// Applies the strict SOLUTE.F admission tests at lines 1213 and 3351 and the
/// corresponding zero assignments at 1366--1375 and 3509--3519.
pub fn calculateSourceOrderForLayer(
    inputs: Inputs,
    parameters: Parameters,
    controls: SourceEquationControls,
    admission: LayerAdmission,
) !Cations {
    if (!std.math.isFinite(admission.cation_exchange_capacity_mol) or
        admission.cation_exchange_capacity_mol < 0 or
        !std.math.isFinite(admission.minimum_exchange_capacity_mol) or
        admission.minimum_exchange_capacity_mol < 0)
        return error.InvalidCationExchangeInput;
    if (admission.cation_exchange_capacity_mol <=
        admission.minimum_exchange_capacity_mol)
        return zeroCations();
    return calculateSourceOrder(inputs, parameters, controls);
}

fn sourceOrderRawChargeChanges(
    inputs: Inputs,
    equilibrium_charge: Cations,
    current_charge: Cations,
    substrate_fraction_per_megagram: f64,
    maximum_per_megagram: f64,
) Cations {
    const exchange = inputs.exchange_concentration_mol_per_megagram;
    const aqueous = inputs.aqueous_concentration_mol_per_m3;
    return .{
        .ammonium_non_band = boundedChargeChange(
            equilibrium_charge.ammonium_non_band - current_charge.ammonium_non_band,
            substrate_fraction_per_megagram * @min(exchange.ammonium_non_band, aqueous.ammonium_non_band),
            maximum_per_megagram,
        ),
        .ammonium_band = boundedChargeChange(
            equilibrium_charge.ammonium_band - current_charge.ammonium_band,
            substrate_fraction_per_megagram * @min(exchange.ammonium_band, aqueous.ammonium_band),
            maximum_per_megagram,
        ),
        .hydrogen = boundedChargeChange(
            equilibrium_charge.hydrogen - current_charge.hydrogen,
            substrate_fraction_per_megagram * @min(exchange.hydrogen, aqueous.hydrogen),
            maximum_per_megagram,
        ),
        .aluminum = boundedChargeChange(
            equilibrium_charge.aluminum - current_charge.aluminum,
            substrate_fraction_per_megagram * 3 * @min(exchange.aluminum, aqueous.aluminum),
            maximum_per_megagram,
        ),
        .iron = boundedChargeChange(
            equilibrium_charge.iron - current_charge.iron,
            substrate_fraction_per_megagram * 3 * @min(exchange.iron, aqueous.iron),
            maximum_per_megagram,
        ),
        .calcium = boundedChargeChange(
            equilibrium_charge.calcium - current_charge.calcium,
            substrate_fraction_per_megagram * 2 * @min(exchange.calcium, aqueous.calcium),
            maximum_per_megagram,
        ),
        .magnesium = boundedChargeChange(
            equilibrium_charge.magnesium - current_charge.magnesium,
            substrate_fraction_per_megagram * 2 * @min(exchange.magnesium, aqueous.magnesium),
            maximum_per_megagram,
        ),
        .sodium = boundedChargeChange(
            equilibrium_charge.sodium - current_charge.sodium,
            substrate_fraction_per_megagram * @min(exchange.sodium, aqueous.sodium),
            maximum_per_megagram,
        ),
        .potassium = boundedChargeChange(
            equilibrium_charge.potassium - current_charge.potassium,
            substrate_fraction_per_megagram * @min(exchange.potassium, aqueous.potassium),
            maximum_per_megagram,
        ),
    };
}

fn boundedChargeChange(
    driving_charge_mol_per_megagram: f64,
    substrate_limit_mol_charge_per_megagram: f64,
    maximum_mol_charge_per_megagram: f64,
) f64 {
    const limit = @min(
        substrate_limit_mol_charge_per_megagram,
        maximum_mol_charge_per_megagram,
    );
    return std.math.clamp(driving_charge_mol_per_megagram, -limit, limit);
}

fn closeSiteChargeAndConvertToIonMoles(
    changes: *Cations,
    ammonium_non_band_fraction: f64,
    ammonium_band_fraction: f64,
) void {
    // An inactive fertilizer-water zone owns neither exchanger sites nor an
    // aqueous carrier. SOLUTE's zone fractions make its site weight exactly
    // zero; clear that coordinate before charge closure so the equilibrium
    // calculation cannot emit a flux whose aqueous counterpart has no owner.
    if (ammonium_non_band_fraction == 0)
        changes.ammonium_non_band = 0;
    if (ammonium_band_fraction == 0)
        changes.ammonium_band = 0;
    var total: f64 = 0;
    var magnitude: f64 = 0;
    inline for (@typeInfo(Cations).@"struct".fields) |field| {
        const weight = siteCoordinateWeight(
            field.name,
            ammonium_non_band_fraction,
            ammonium_band_fraction,
        );
        total += weight * @field(changes.*, field.name);
        magnitude += weight * @abs(@field(changes.*, field.name));
    }
    if (magnitude == 0) {
        changes.* = zeroCations();
        return;
    }
    inline for (@typeInfo(Cations).@"struct".fields) |field| {
        const value = @field(changes.*, field.name);
        @field(changes.*, field.name) -= total * @abs(value) / magnitude;
    }
    changes.aluminum /= 3;
    changes.iron /= 3;
    changes.calcium /= 2;
    changes.magnesium /= 2;
}

fn availableCharge(
    comptime field_name: []const u8,
    exchange_ion_mol_per_megagram: f64,
    aqueous_ion_mol_per_m3: f64,
) f64 {
    const valence: f64 =
        if (comptime std.mem.eql(u8, field_name, "aluminum") or
        std.mem.eql(u8, field_name, "iron"))
            3
        else if (comptime std.mem.eql(u8, field_name, "calcium") or
        std.mem.eql(u8, field_name, "magnesium"))
            2
        else
            1;
    return valence * @min(
        exchange_ion_mol_per_megagram,
        aqueous_ion_mol_per_m3,
    );
}

/// Exact competitive Gapon equilibrium in moles of ion per Mg. This is the
/// unclipped target underlying `calculate`; exposing it lets a coupled
/// Newton/Picard solver cross capped-rate plateaus without changing the
/// source selectivity equations.
pub fn equilibriumIonConcentration(inputs: Inputs, selectivity: Selectivity) !Cations {
    try validate(inputs, .{
        .selectivity = selectivity,
        .substrate_limit_fraction = 0,
        .maximum_adsorption_mol_charge_per_m3_step = 0,
    });
    if (inputs.cation_exchange_capacity_mol_charge_per_megagram == 0)
        return zeroCations();
    var result = try equilibriumCharge(inputs, selectivity);
    result.aluminum /= 3;
    result.iron /= 3;
    result.calcium /= 2;
    result.magnesium /= 2;
    return result;
}

/// Equilibrium target for the production source-order kernel, including its
/// 0.333 trivalent exponent and runtime minimum activity in the roots.
pub fn sourceOrderEquilibriumIonConcentration(inputs: Inputs, selectivity: Selectivity, controls: SourceEquationControls) !Cations {
    var profile_scope = @import("reaction_diagnostic_control.zig").beginPhase(.exchange_equilibrium);
    defer profile_scope.end();
    try validate(inputs, .{ .selectivity = selectivity, .substrate_limit_fraction = 0, .maximum_adsorption_mol_charge_per_m3_step = 0 });
    if (!std.math.isFinite(controls.minimum_activity_mol_per_m3) or controls.minimum_activity_mol_per_m3 <= 0) return error.InvalidCationExchangeParameter;
    var result = try sourceOrderEquilibriumCharge(inputs, selectivity, controls.minimum_activity_mol_per_m3);
    result.aluminum /= 3;
    result.iron /= 3;
    result.calcium /= 2;
    result.magnesium /= 2;
    return result;
}

fn equilibriumCharge(inputs: Inputs, selectivity: Selectivity) !Cations {
    const activity = inputs.aqueous_activity_mol_per_m3;
    const calcium_root = @sqrt(activity.calcium);
    if (calcium_root == 0) return zeroCations();
    const aluminum_root = std.math.pow(f64, activity.aluminum, 1.0 / 3.0);
    const iron_root = std.math.pow(f64, activity.iron, 1.0 / 3.0);
    const magnesium_root = @sqrt(activity.magnesium);
    const s = selectivity;
    const denominator = 1.0 +
        s.calcium_ammonium * activity.ammonium_non_band / calcium_root * inputs.ammonium_non_band_fraction +
        s.calcium_ammonium * activity.ammonium_band / calcium_root * inputs.ammonium_band_fraction +
        s.calcium_hydrogen * activity.hydrogen / calcium_root +
        3.0 * s.calcium_aluminum_and_iron * (aluminum_root + iron_root) / calcium_root +
        2.0 * s.calcium_magnesium * magnesium_root / calcium_root +
        s.calcium_sodium * activity.sodium / calcium_root +
        s.calcium_potassium * activity.potassium / calcium_root;
    if (!std.math.isFinite(denominator) or denominator <= 0) return error.InvalidCationExchangeEquilibrium;

    const calcium_basis = inputs.cation_exchange_capacity_mol_charge_per_megagram / denominator;
    var equilibrium_charge = Cations{
        .ammonium_non_band = calcium_basis * activity.ammonium_non_band / calcium_root * s.calcium_ammonium,
        .ammonium_band = calcium_basis * activity.ammonium_band / calcium_root * s.calcium_ammonium,
        .hydrogen = calcium_basis * activity.hydrogen / calcium_root * s.calcium_hydrogen,
        .aluminum = calcium_basis * aluminum_root / calcium_root * s.calcium_aluminum_and_iron * 3.0,
        .iron = calcium_basis * iron_root / calcium_root * s.calcium_aluminum_and_iron * 3.0,
        .calcium = calcium_basis * 2.0,
        .magnesium = calcium_basis * magnesium_root / calcium_root * s.calcium_magnesium * 2.0,
        .sodium = calcium_basis * activity.sodium / calcium_root * s.calcium_sodium,
        .potassium = calcium_basis * activity.potassium / calcium_root * s.calcium_potassium,
    };
    normalizeSiteCharge(
        &equilibrium_charge,
        inputs.cation_exchange_capacity_mol_charge_per_megagram,
        inputs.ammonium_non_band_fraction,
        inputs.ammonium_band_fraction,
    );
    return equilibrium_charge;
}

// This kernel serves both soil (starte.f:714-736) and litter
// (starte.f:1828-1841; solute.f:4360-4394) call sites and always applies the
// *3.0/*2.0 valence weights to both the numerator and denominator. It
// deliberately does not reproduce the legacy litter-specific bug where
// those siblings retain the weights in the denominator but drop them from
// the numerator (see
// audit/issues/issue-021-litter-gapon-exchange-unweighted-numerator-undocumented.md)
// -- do not "fix" this to match the legacy defect.
fn sourceOrderEquilibriumCharge(
    inputs: Inputs,
    selectivity: Selectivity,
    minimum_activity_mol_per_m3: f64,
) !Cations {
    const activity = inputs.aqueous_activity_mol_per_m3;
    const aluminum_root = std.math.pow(
        f64,
        @max(minimum_activity_mol_per_m3, activity.aluminum),
        0.333,
    );
    const iron_root = std.math.pow(
        f64,
        @max(minimum_activity_mol_per_m3, activity.iron),
        0.333,
    );
    const calcium_root =
        @sqrt(@max(minimum_activity_mol_per_m3, activity.calcium));
    const magnesium_root =
        @sqrt(@max(minimum_activity_mol_per_m3, activity.magnesium));
    const s = selectivity;
    const calcium_basis = inputs.cation_exchange_capacity_mol_charge_per_megagram /
        (1.0 +
            s.calcium_ammonium * activity.ammonium_non_band / calcium_root *
                inputs.ammonium_non_band_fraction +
            s.calcium_ammonium * activity.ammonium_band / calcium_root *
                inputs.ammonium_band_fraction +
            s.calcium_hydrogen * activity.hydrogen / calcium_root +
            3.0 * s.calcium_aluminum_and_iron *
                (aluminum_root + iron_root) / calcium_root +
            2.0 * s.calcium_magnesium * magnesium_root / calcium_root +
            s.calcium_sodium * activity.sodium / calcium_root +
            s.calcium_potassium * activity.potassium / calcium_root);
    if (!std.math.isFinite(calcium_basis) or calcium_basis < 0)
        return error.InvalidCationExchangeEquilibrium;

    var equilibrium_charge = Cations{
        .ammonium_non_band = calcium_basis *
            activity.ammonium_non_band / calcium_root * s.calcium_ammonium,
        .ammonium_band = calcium_basis *
            activity.ammonium_band / calcium_root * s.calcium_ammonium,
        .hydrogen = calcium_basis * activity.hydrogen / calcium_root *
            s.calcium_hydrogen,
        .aluminum = calcium_basis * aluminum_root / calcium_root *
            s.calcium_aluminum_and_iron * 3.0,
        .iron = calcium_basis * iron_root / calcium_root *
            s.calcium_aluminum_and_iron * 3.0,
        .calcium = calcium_basis * 2.0,
        .magnesium = calcium_basis * magnesium_root / calcium_root *
            s.calcium_magnesium * 2.0,
        .sodium = calcium_basis * activity.sodium / calcium_root *
            s.calcium_sodium,
        .potassium = calcium_basis * activity.potassium / calcium_root *
            s.calcium_potassium,
    };
    normalizeSiteCharge(
        &equilibrium_charge,
        inputs.cation_exchange_capacity_mol_charge_per_megagram,
        inputs.ammonium_non_band_fraction,
        inputs.ammonium_band_fraction,
    );
    return equilibrium_charge;
}

fn normalizeSiteCharge(
    values: *Cations,
    capacity: f64,
    ammonium_non_band_fraction: f64,
    ammonium_band_fraction: f64,
) void {
    var total: f64 = 0;
    inline for (@typeInfo(Cations).@"struct".fields) |field|
        total += siteCoordinateWeight(
            field.name,
            ammonium_non_band_fraction,
            ammonium_band_fraction,
        ) * @field(values.*, field.name);
    if (total == 0) {
        values.* = zeroCations();
        return;
    }
    const scale = capacity / total;
    inline for (@typeInfo(Cations).@"struct".fields) |field| @field(values.*, field.name) *= scale;
}

fn siteCoordinateWeight(
    comptime field_name: []const u8,
    ammonium_non_band_fraction: f64,
    ammonium_band_fraction: f64,
) f64 {
    return if (comptime std.mem.eql(u8, field_name, "ammonium_non_band"))
        ammonium_non_band_fraction
    else if (comptime std.mem.eql(u8, field_name, "ammonium_band"))
        ammonium_band_fraction
    else
        1;
}

fn zeroCations() Cations {
    return .{ .ammonium_non_band = 0, .ammonium_band = 0, .hydrogen = 0, .aluminum = 0, .iron = 0, .calcium = 0, .magnesium = 0, .sodium = 0, .potassium = 0 };
}

fn validate(inputs: Inputs, parameters: Parameters) !void {
    inline for (@typeInfo(Cations).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs.aqueous_concentration_mol_per_m3, field.name)) or @field(inputs.aqueous_concentration_mol_per_m3, field.name) < 0 or
            !std.math.isFinite(@field(inputs.aqueous_activity_mol_per_m3, field.name)) or @field(inputs.aqueous_activity_mol_per_m3, field.name) < 0 or
            !std.math.isFinite(@field(inputs.exchange_concentration_mol_per_megagram, field.name)) or @field(inputs.exchange_concentration_mol_per_megagram, field.name) < 0)
            return error.InvalidCationExchangeInput;
    }
    inline for (@typeInfo(Selectivity).@"struct".fields) |field|
        if (!std.math.isFinite(@field(parameters.selectivity, field.name)) or @field(parameters.selectivity, field.name) < 0) return error.InvalidCationExchangeParameter;
    if (!std.math.isFinite(inputs.cation_exchange_capacity_mol_charge_per_megagram) or inputs.cation_exchange_capacity_mol_charge_per_megagram < 0 or
        !std.math.isFinite(inputs.soil_mass_per_water_volume_megagrams_per_m3) or inputs.soil_mass_per_water_volume_megagrams_per_m3 <= 0 or
        !std.math.isFinite(inputs.ammonium_non_band_fraction) or inputs.ammonium_non_band_fraction < 0 or inputs.ammonium_non_band_fraction > 1 or
        !std.math.isFinite(inputs.ammonium_band_fraction) or inputs.ammonium_band_fraction < 0 or inputs.ammonium_band_fraction > 1 or
        !std.math.isFinite(parameters.substrate_limit_fraction) or parameters.substrate_limit_fraction < 0 or parameters.substrate_limit_fraction > 1 or
        !std.math.isFinite(parameters.maximum_adsorption_mol_charge_per_m3_step) or parameters.maximum_adsorption_mol_charge_per_m3_step < 0)
        return error.InvalidCationExchangeInput;
}

test "multivalent substrate limits compare charge equivalents in each concentration coordinate" {
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.6),
        availableCharge("aluminum", 0.3, 0.2),
        1e-15,
    );
    try std.testing.expectEqual(
        @as(f64, 0.5),
        availableCharge("calcium", 0.25, 0.4),
    );
    try std.testing.expectEqual(
        @as(f64, 0.2),
        availableCharge("sodium", 0.5, 0.2),
    );
    try std.testing.expectEqual(
        @as(f64, 0.1),
        availableCharge("ammonium_non_band", 0.2, 0.1),
    );
}

test "exposed Gapon equilibrium target has zero clipped exchange flux" {
    const aqueous = Cations{
        .ammonium_non_band = 0.2,
        .ammonium_band = 0,
        .hydrogen = 0.05,
        .aluminum = 0.03,
        .iron = 0.02,
        .calcium = 0.5,
        .magnesium = 0.2,
        .sodium = 0.1,
        .potassium = 0.08,
    };
    const selectivity = Selectivity{
        .calcium_ammonium = 1.1,
        .calcium_hydrogen = 0.9,
        .calcium_aluminum_and_iron = 1.2,
        .calcium_magnesium = 0.8,
        .calcium_sodium = 1.3,
        .calcium_potassium = 1.4,
    };
    var inputs = Inputs{
        .cation_exchange_capacity_mol_charge_per_megagram = 2,
        .aqueous_concentration_mol_per_m3 = aqueous,
        .aqueous_activity_mol_per_m3 = aqueous,
        .exchange_concentration_mol_per_megagram = zeroCations(),
        .ammonium_non_band_fraction = 1,
        .ammonium_band_fraction = 0,
        .soil_mass_per_water_volume_megagrams_per_m3 = 1.4,
    };
    inputs.exchange_concentration_mol_per_megagram =
        try equilibriumIonConcentration(inputs, selectivity);
    const flux = try calculate(inputs, .{
        .selectivity = selectivity,
        .substrate_limit_fraction = 0.2,
        .maximum_adsorption_mol_charge_per_m3_step = 0.1,
    });
    inline for (@typeInfo(Cations).@"struct".fields) |field|
        try std.testing.expectApproxEqAbs(
            @as(f64, 0),
            @field(flux, field.name),
            1e-14,
        );
}

test "zero driving force does not divide by zero" {
    const zero = zeroCations();
    const flux = try calculate(.{ .cation_exchange_capacity_mol_charge_per_megagram = 1, .aqueous_concentration_mol_per_m3 = zero, .aqueous_activity_mol_per_m3 = .{ .ammonium_non_band = 0, .ammonium_band = 0, .hydrogen = 0, .aluminum = 0, .iron = 0, .calcium = 1, .magnesium = 0, .sodium = 0, .potassium = 0 }, .exchange_concentration_mol_per_megagram = .{ .ammonium_non_band = 0, .ammonium_band = 0, .hydrogen = 0, .aluminum = 0, .iron = 0, .calcium = 0.5, .magnesium = 0, .sodium = 0, .potassium = 0 }, .ammonium_non_band_fraction = 1, .ammonium_band_fraction = 0, .soil_mass_per_water_volume_megagrams_per_m3 = 1 }, .{ .selectivity = .{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }, .substrate_limit_fraction = 0.2, .maximum_adsorption_mol_charge_per_m3_step = 0.1 });
    try std.testing.expectEqualDeep(zero, flux);
}

test "source-order Gapon target retains trivalent exponent and activity root bounds" {
    const selectivity: Selectivity = .{ .calcium_ammonium = 1.1, .calcium_hydrogen = 0.9, .calcium_aluminum_and_iron = 1.2, .calcium_magnesium = 0.8, .calcium_sodium = 1.3, .calcium_potassium = 1.4 };
    const controls: SourceEquationControls = .{ .minimum_activity_mol_per_m3 = 1e-20 };
    for ([_]f64{ 1e-24, 1e-12, 0.03, 30 }) |metal| {
        const aqueous: Cations = .{ .ammonium_non_band = 0.2, .ammonium_band = 0.4, .hydrogen = 0.05, .aluminum = metal, .iron = metal * 0.7, .calcium = 0.5, .magnesium = 0.2, .sodium = 0.1, .potassium = 0.08 };
        var input: Inputs = .{ .cation_exchange_capacity_mol_charge_per_megagram = 2, .aqueous_concentration_mol_per_m3 = aqueous, .aqueous_activity_mol_per_m3 = aqueous, .exchange_concentration_mol_per_megagram = zeroCations(), .ammonium_non_band_fraction = 0.7, .ammonium_band_fraction = 0.3, .soil_mass_per_water_volume_megagrams_per_m3 = 1.4 };
        input.exchange_concentration_mol_per_megagram = try sourceOrderEquilibriumIonConcentration(input, selectivity, controls);
        const rates = try calculateSourceOrder(input, .{ .selectivity = selectivity, .substrate_limit_fraction = 0.2, .maximum_adsorption_mol_charge_per_m3_step = 0.1 }, controls);
        inline for (std.meta.fields(Cations)) |field| try std.testing.expect(@abs(@field(rates, field.name)) <= 64 * std.math.floatEps(f64) * input.cation_exchange_capacity_mol_charge_per_megagram);
        var charge = input.exchange_concentration_mol_per_megagram;
        charge.aluminum *= 3;
        charge.iron *= 3;
        charge.calcium *= 2;
        charge.magnesium *= 2;
        var total: f64 = 0;
        inline for (std.meta.fields(Cations)) |field| total += siteCoordinateWeight(field.name, 0.7, 0.3) * @field(charge, field.name);
        try std.testing.expectApproxEqAbs(input.cation_exchange_capacity_mol_charge_per_megagram, total, 64 * std.math.floatEps(f64) * input.cation_exchange_capacity_mol_charge_per_megagram);
    }
}

test "inactive ammonium water zone emits no exchange flux" {
    const aqueous = Cations{
        .ammonium_non_band = 0.2,
        .ammonium_band = 2,
        .hydrogen = 0.05,
        .aluminum = 0.03,
        .iron = 0.02,
        .calcium = 0.5,
        .magnesium = 0.2,
        .sodium = 0.1,
        .potassium = 0.08,
    };
    const inputs = Inputs{
        .cation_exchange_capacity_mol_charge_per_megagram = 2,
        .aqueous_concentration_mol_per_m3 = aqueous,
        .aqueous_activity_mol_per_m3 = aqueous,
        .exchange_concentration_mol_per_megagram = .{
            .ammonium_non_band = 0.2,
            .ammonium_band = 0.6,
            .hydrogen = 0.1,
            .aluminum = 0.02,
            .iron = 0.02,
            .calcium = 0.4,
            .magnesium = 0.1,
            .sodium = 0.1,
            .potassium = 0.08,
        },
        .ammonium_non_band_fraction = 1,
        .ammonium_band_fraction = 0,
        .soil_mass_per_water_volume_megagrams_per_m3 = 1.4,
    };
    const parameters = Parameters{
        .selectivity = .{
            .calcium_ammonium = 1.1,
            .calcium_hydrogen = 0.9,
            .calcium_aluminum_and_iron = 1.2,
            .calcium_magnesium = 0.8,
            .calcium_sodium = 1.3,
            .calcium_potassium = 1.4,
        },
        .substrate_limit_fraction = 0.2,
        .maximum_adsorption_mol_charge_per_m3_step = 0.1,
    };
    const optimized = try calculate(inputs, parameters);
    const source_order = try calculateSourceOrder(
        inputs,
        parameters,
        .{ .minimum_activity_mol_per_m3 = 1e-32 },
    );
    try std.testing.expectEqual(@as(f64, 0), optimized.ammonium_band);
    try std.testing.expectEqual(@as(f64, 0), source_order.ammonium_band);
}

test "source-order trivalent roots retain the Fortran 0.333 exponent" {
    const inputs = Inputs{
        .cation_exchange_capacity_mol_charge_per_megagram = 2,
        .aqueous_concentration_mol_per_m3 = zeroCations(),
        .aqueous_activity_mol_per_m3 = .{
            .ammonium_non_band = 0,
            .ammonium_band = 0,
            .hydrogen = 0,
            .aluminum = 8,
            .iron = 1,
            .calcium = 4,
            .magnesium = 0,
            .sodium = 0,
            .potassium = 0,
        },
        .exchange_concentration_mol_per_megagram = zeroCations(),
        .ammonium_non_band_fraction = 1,
        .ammonium_band_fraction = 0,
        .soil_mass_per_water_volume_megagrams_per_m3 = 1,
    };
    const selectivity = Selectivity{
        .calcium_ammonium = 0,
        .calcium_hydrogen = 0,
        .calcium_aluminum_and_iron = 1.25,
        .calcium_magnesium = 0,
        .calcium_sodium = 0,
        .calcium_potassium = 0,
    };
    const charge = try sourceOrderEquilibriumCharge(
        inputs,
        selectivity,
        1e-32,
    );
    const aluminum_root = std.math.pow(f64, 8, 0.333);
    const iron_root = std.math.pow(f64, 1, 0.333);
    const calcium_root = @sqrt(@as(f64, 4));
    const calcium_basis = 2 /
        (1 + 3 * 1.25 * (aluminum_root + iron_root) / calcium_root);
    const total_before_normalization = calcium_basis *
        (2 + 3 * 1.25 * (aluminum_root + iron_root) / calcium_root);
    const scale = 2 / total_before_normalization;
    try std.testing.expectApproxEqAbs(
        scale * calcium_basis * aluminum_root / calcium_root * 1.25 * 3,
        charge.aluminum,
        1e-15,
    );
}

test "SOLUTE 1213 and 3351 layer gates are strict and clear all exchange rates" {
    const inputs = Inputs{
        .cation_exchange_capacity_mol_charge_per_megagram = 1,
        .aqueous_concentration_mol_per_m3 = .{
            .ammonium_non_band = 1,
            .ammonium_band = 0,
            .hydrogen = 0,
            .aluminum = 0,
            .iron = 0,
            .calcium = 1,
            .magnesium = 0,
            .sodium = 0,
            .potassium = 0,
        },
        .aqueous_activity_mol_per_m3 = .{
            .ammonium_non_band = 1,
            .ammonium_band = 0,
            .hydrogen = 0,
            .aluminum = 0,
            .iron = 0,
            .calcium = 1,
            .magnesium = 0,
            .sodium = 0,
            .potassium = 0,
        },
        .exchange_concentration_mol_per_megagram = .{
            .ammonium_non_band = 0.2,
            .ammonium_band = 0,
            .hydrogen = 0,
            .aluminum = 0,
            .iron = 0,
            .calcium = 0.4,
            .magnesium = 0,
            .sodium = 0,
            .potassium = 0,
        },
        .ammonium_non_band_fraction = 1,
        .ammonium_band_fraction = 0,
        .soil_mass_per_water_volume_megagrams_per_m3 = 1,
    };
    const parameters = Parameters{
        .selectivity = .{
            .calcium_ammonium = 1,
            .calcium_hydrogen = 0,
            .calcium_aluminum_and_iron = 0,
            .calcium_magnesium = 0,
            .calcium_sodium = 0,
            .calcium_potassium = 0,
        },
        .substrate_limit_fraction = 1,
        .maximum_adsorption_mol_charge_per_m3_step = 1,
    };
    const controls = SourceEquationControls{
        .minimum_activity_mol_per_m3 = 1e-32,
    };

    const inactive = try calculateSourceOrderForLayer(
        inputs,
        parameters,
        controls,
        .{
            .cation_exchange_capacity_mol = 1e-12,
            .minimum_exchange_capacity_mol = 1e-12,
        },
    );
    try std.testing.expectEqualDeep(zeroCations(), inactive);

    const active = try calculateSourceOrderForLayer(
        inputs,
        parameters,
        controls,
        .{
            .cation_exchange_capacity_mol = 1.0001e-12,
            .minimum_exchange_capacity_mol = 1e-12,
        },
    );
    const direct = try calculateSourceOrder(inputs, parameters, controls);
    try std.testing.expectEqualDeep(direct, active);
}

test {
    _ = @import("cation_exchange_test.zig");
}

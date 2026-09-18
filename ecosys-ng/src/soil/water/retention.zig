//! **A5 DISPOSITION: this module is the intentional replacement, not a
//! superseded kernel.** Recorded here because the other class C entries in
//! `docs/traceability/hour1_2039_5200_binding_survey.md` carry the mirror-image
//! note and a reader arriving from that survey needs to know which side of the
//! replacement this file is on.
//!
//! Legacy source replaced: `ecosys_f77/hour1.f` lines 4107--4170, the
//! three-branch log-log matric water potential, and lines 4225--4227, the
//! lookup hydraulic conductivity. The deviation is recorded in
//! `docs/model_changes.md`, "Improved hydrology and freeze-thaw".
//!
//! Because this is an intentional replacement, legacy agreement can never
//! validate it: the two constitutive relations are different and are expected
//! to disagree. The independent evidence required by `docs/validation.md`
//! instead lives in `src/soil_water_retention_validation.zig`, which covers
//! tiers 1, 2, 3, 4, and 6 and reports the measured reason to prefer the
//! replacement: the legacy curve's water capacity is discontinuous at both
//! branch joints, so quadrature crossing a joint converges at a fitted rate of
//! 1.45 and then stalls, while this curve holds 2.00.
//!
//! The legacy coefficients survive in `compatibilityParameters` and in the
//! `Parameters`/`ResolvedCurve` pair below, which are still needed for the
//! field-capacity and wilting-point anchors the van Genuchten fit consumes and
//! for the NITRO hygroscopic-water inverse. They are not the production
//! potential evaluation.

const std = @import("std");
const numerics = @import("../../core/numerics.zig");

/// Original van Genuchten (1980) retention curve coupled to the Mualem
/// conductivity model. This intentionally does not implement the Ippisch
/// near-saturation modification.
pub const MualemVanGenuchtenParameters = struct {
    residual_water_content_m3_per_m3: f64,
    saturated_water_content_m3_per_m3: f64,
    alpha_per_m: f64,
    n: f64,
    pore_connectivity: f64 = 0.5,
    saturated_hydraulic_conductivity_m_per_h: f64,

    pub fn validate(self: MualemVanGenuchtenParameters) !void {
        inline for (@typeInfo(MualemVanGenuchtenParameters).@"struct".fields) |field| {
            if (!std.math.isFinite(@field(self, field.name)))
                return error.NonFiniteMualemVanGenuchtenParameter;
        }
        if (self.residual_water_content_m3_per_m3 < 0 or
            self.saturated_water_content_m3_per_m3 <= self.residual_water_content_m3_per_m3 or
            self.saturated_water_content_m3_per_m3 > 1 or
            self.alpha_per_m <= 0 or self.n <= 1 or
            self.saturated_hydraulic_conductivity_m_per_h < 0)
        {
            return error.InvalidMualemVanGenuchtenParameter;
        }
    }

    pub fn m(self: MualemVanGenuchtenParameters) f64 {
        return 1.0 - 1.0 / self.n;
    }

    pub fn effectiveSaturationAtPressureHead(
        self: MualemVanGenuchtenParameters,
        pressure_head_m: f64,
    ) !f64 {
        try self.validate();
        return self.effectiveSaturationAtPressureHeadAssumeValid(pressure_head_m);
    }

    fn effectiveSaturationAtPressureHeadAssumeValid(
        self: MualemVanGenuchtenParameters,
        pressure_head_m: f64,
    ) !f64 {
        if (!std.math.isFinite(pressure_head_m))
            return error.NonFinitePressureHead;
        if (pressure_head_m >= 0) return 1;
        const scaled_head = self.alpha_per_m * -pressure_head_m;
        const effective_saturation =
            std.math.pow(f64, 1.0 + std.math.pow(f64, scaled_head, self.n), -self.m());
        if (!std.math.isFinite(effective_saturation))
            return error.NonFiniteEffectiveSaturation;
        return std.math.clamp(effective_saturation, 0, 1);
    }

    pub fn waterContentAtPressureHead(
        self: MualemVanGenuchtenParameters,
        pressure_head_m: f64,
    ) !f64 {
        const effective_saturation =
            try self.effectiveSaturationAtPressureHead(pressure_head_m);
        return self.residual_water_content_m3_per_m3 +
            effective_saturation *
                (self.saturated_water_content_m3_per_m3 -
                    self.residual_water_content_m3_per_m3);
    }

    pub fn pressureHeadAtWaterContent(
        self: MualemVanGenuchtenParameters,
        water_content_m3_per_m3: f64,
    ) !f64 {
        try self.validate();
        return self.pressureHeadAtWaterContentAssumeValid(
            water_content_m3_per_m3,
        );
    }

    /// Invert repeatedly after the caller has validated this parameter set.
    pub fn pressureHeadAtWaterContentAssumeValid(
        self: MualemVanGenuchtenParameters,
        water_content_m3_per_m3: f64,
    ) !f64 {
        if (!std.math.isFinite(water_content_m3_per_m3))
            return error.NonFiniteWaterContent;
        if (water_content_m3_per_m3 < self.residual_water_content_m3_per_m3 or
            water_content_m3_per_m3 > self.saturated_water_content_m3_per_m3)
        {
            return error.WaterContentOutsideRetentionDomain;
        }
        if (water_content_m3_per_m3 == self.saturated_water_content_m3_per_m3)
            return 0;
        const effective_saturation = std.math.clamp(
            (water_content_m3_per_m3 - self.residual_water_content_m3_per_m3) /
                (self.saturated_water_content_m3_per_m3 -
                    self.residual_water_content_m3_per_m3),
            std.math.floatMin(f64),
            1,
        );
        // Evaluate the original van Genuchten inverse in the log domain.
        // At theta_r its mathematical limit is negative infinity; represent
        // that asymptote by the largest pressure magnitude for which both the
        // head and alpha*head remain finite. This avoids silently producing
        // infinity while retaining the unmodified constitutive curve.
        const inverse_saturation_log =
            -@log(effective_saturation) / self.m();
        const inner_log =
            if (inverse_saturation_log > 40)
                inverse_saturation_log
            else
                @log(@exp(inverse_saturation_log) - 1);
        const pressure_magnitude_log =
            inner_log / self.n - @log(self.alpha_per_m);
        const maximum_pressure_magnitude_log =
            @log(std.math.floatMax(f64)) -
            @max(0, @log(self.alpha_per_m));
        const pressure_head_m = -@exp(@min(
            pressure_magnitude_log,
            maximum_pressure_magnitude_log,
        ));
        if (!std.math.isFinite(pressure_head_m))
            return error.NonFinitePressureHead;
        return pressure_head_m;
    }

    /// Normalised wetness `Se = (theta - theta_r) / (theta_s - theta_r)`,
    /// clamped to [0, 1]. This is the curve's own saturation measure, and it
    /// replaces interpolation between porosity and a legacy air-entry water
    /// content wherever a fractional saturation is needed.
    pub fn effectiveSaturationAtWaterContent(
        self: MualemVanGenuchtenParameters,
        water_content_m3_per_m3: f64,
    ) !f64 {
        try self.validate();
        if (!std.math.isFinite(water_content_m3_per_m3))
            return error.NonFiniteWaterContent;
        const span = self.saturated_water_content_m3_per_m3 -
            self.residual_water_content_m3_per_m3;
        if (span <= 0) return error.InvalidRetentionSaturationSpan;
        return std.math.clamp(
            (water_content_m3_per_m3 -
                self.residual_water_content_m3_per_m3) / span,
            0,
            1,
        );
    }

    pub fn waterCapacityPerM(
        self: MualemVanGenuchtenParameters,
        pressure_head_m: f64,
    ) !f64 {
        try self.validate();
        if (!std.math.isFinite(pressure_head_m))
            return error.NonFinitePressureHead;
        if (pressure_head_m >= 0) return 0;
        const absolute_head_m = -pressure_head_m;
        const scaled_head = self.alpha_per_m * absolute_head_m;
        const scaled_to_n = std.math.pow(f64, scaled_head, self.n);
        const capacity_per_m =
            (self.saturated_water_content_m3_per_m3 -
                self.residual_water_content_m3_per_m3) *
            self.m() * self.n * self.alpha_per_m *
            std.math.pow(f64, scaled_head, self.n - 1.0) *
            std.math.pow(f64, 1.0 + scaled_to_n, -self.m() - 1.0);
        if (!std.math.isFinite(capacity_per_m) or capacity_per_m < 0)
            return error.NonFiniteWaterCapacity;
        return capacity_per_m;
    }

    pub fn relativeHydraulicConductivityAtEffectiveSaturation(
        self: MualemVanGenuchtenParameters,
        effective_saturation: f64,
    ) !f64 {
        try self.validate();
        return self.relativeHydraulicConductivityAtEffectiveSaturationAssumeValid(
            effective_saturation,
        );
    }

    fn relativeHydraulicConductivityAtEffectiveSaturationAssumeValid(
        self: MualemVanGenuchtenParameters,
        effective_saturation: f64,
    ) !f64 {
        if (!std.math.isFinite(effective_saturation) or
            effective_saturation < 0 or effective_saturation > 1)
        {
            return error.InvalidEffectiveSaturation;
        }
        if (effective_saturation == 0) return 0;
        if (effective_saturation == 1) return 1;
        const saturation_to_inverse_m =
            std.math.pow(f64, effective_saturation, 1.0 / self.m());
        const mualem_integral =
            1.0 - std.math.pow(f64, 1.0 - saturation_to_inverse_m, self.m());
        const relative_conductivity =
            std.math.pow(f64, effective_saturation, self.pore_connectivity) *
            mualem_integral * mualem_integral;
        if (!std.math.isFinite(relative_conductivity) or
            relative_conductivity < 0 or relative_conductivity > 1)
        {
            return error.NonFiniteRelativeHydraulicConductivity;
        }
        return relative_conductivity;
    }

    pub fn hydraulicConductivityMPerH(
        self: MualemVanGenuchtenParameters,
        pressure_head_m: f64,
    ) !f64 {
        try self.validate();
        return self.hydraulicConductivityMPerHAssumeValid(pressure_head_m);
    }

    /// Evaluate repeatedly after the caller has validated this parameter set.
    pub fn hydraulicConductivityMPerHAssumeValid(
        self: MualemVanGenuchtenParameters,
        pressure_head_m: f64,
    ) !f64 {
        const effective_saturation =
            try self.effectiveSaturationAtPressureHeadAssumeValid(pressure_head_m);
        return self.saturated_hydraulic_conductivity_m_per_h *
            try self.relativeHydraulicConductivityAtEffectiveSaturationAssumeValid(
                effective_saturation,
            );
    }

    /// Pressure head at the inflection of the retention curve, where the water
    /// capacity `dtheta/dh` is maximal. Setting the second derivative to zero
    /// gives `(alpha * |h|)^n = m`, hence
    ///
    ///     h_inflection = -m^(1/n) / alpha
    ///
    /// This exists for **parameter estimation only**. It is the quantity
    /// `fitOriginalMualemVanGenuchten` inverts to remove alpha from the scalar
    /// solve for n, where the inflection head is either supplied per layer in
    /// the run script or defaulted from the Carsel and Parrish texture table.
    /// It is not an air-entry potential and must not be used as a flux
    /// threshold: original van Genuchten (1980) is an air-entry-free curve,
    /// saturating only as `h` approaches zero.
    pub fn inflectionPressureHeadM(self: MualemVanGenuchtenParameters) !f64 {
        try self.validate();
        const pressure_head_m =
            -std.math.pow(f64, self.m(), 1.0 / self.n) / self.alpha_per_m;
        if (!std.math.isFinite(pressure_head_m) or pressure_head_m >= 0)
            return error.NonFiniteInflectionPressureHead;
        return pressure_head_m;
    }

    /// Water content at the retention inflection, the companion of
    /// `inflectionPressureHeadM`. Diagnostic and fitting use only; see the note
    /// there about why this is not an air-entry threshold.
    pub fn inflectionWaterContentM3PerM3(
        self: MualemVanGenuchtenParameters,
    ) !f64 {
        return self.waterContentAtPressureHead(
            try self.inflectionPressureHeadM(),
        );
    }
};

pub const MualemVanGenuchtenFitInputs = struct {
    saturated_water_content_m3_per_m3: f64,
    field_capacity_water_content_m3_per_m3: f64,
    field_capacity_pressure_head_m: f64,
    wilting_point_water_content_m3_per_m3: f64,
    wilting_point_pressure_head_m: f64,
    inflection_pressure_head_m: f64,
    saturated_hydraulic_conductivity_m_per_h: f64,
    pore_connectivity: f64 = 0.5,
};

pub const MualemVanGenuchtenFitOptions = struct {
    minimum_n: f64 = 1.01,
    maximum_n: f64 = 20,
    /// Process-scale floor in volumetric water content. Relative convergence
    /// remains active through `water_content_relative_tolerance`.
    water_content_absolute_tolerance_m3_per_m3: f64 = 1.0e-10,
    water_content_relative_tolerance: f64 = 1.0e-8,
    picard_relaxation: f64 = 0.5,
    maximum_iterations: u16,

    pub fn validate(self: MualemVanGenuchtenFitOptions) !void {
        inline for (@typeInfo(MualemVanGenuchtenFitOptions).@"struct".fields) |field| {
            if (field.type == f64 and !std.math.isFinite(@field(self, field.name)))
                return error.NonFiniteMualemVanGenuchtenFitOption;
        }
        if (self.minimum_n <= 1 or self.maximum_n <= self.minimum_n or
            self.water_content_absolute_tolerance_m3_per_m3 <= 0 or
            self.water_content_relative_tolerance <= 0 or
            self.picard_relaxation <= 0 or self.picard_relaxation > 1 or
            self.maximum_iterations == 0)
        {
            return error.InvalidMualemVanGenuchtenFitOption;
        }
    }
};

pub const MualemVanGenuchtenFitResult = struct {
    parameters: MualemVanGenuchtenParameters,
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    anderson_steps: u16,
    residual_water_content_m3_per_m3: f64,
};

pub const SoilTextureClass = enum {
    sand,
    loamy_sand,
    sandy_loam,
    loam,
    silt_loam,
    silt,
    sandy_clay_loam,
    clay_loam,
    silty_clay_loam,
    sandy_clay,
    silty_clay,
    clay,
};

pub fn classifyUsdaSoilTexture(
    sand_fraction: f64,
    silt_fraction: f64,
    clay_fraction: f64,
) !SoilTextureClass {
    inline for (.{ sand_fraction, silt_fraction, clay_fraction }) |fraction| {
        if (!std.math.isFinite(fraction) or fraction < 0)
            return error.InvalidSoilTextureFraction;
    }
    const mineral_fraction = sand_fraction + silt_fraction + clay_fraction;
    if (!std.math.isFinite(mineral_fraction) or mineral_fraction <= 0)
        return error.SoilTextureFractionsDoNotSumToOne;
    // USDA texture is defined on the fine-earth mineral fraction. Live HOUR1
    // mineral fractions need not sum to one after independent material and
    // bulk-density updates, so normalize only for classification.
    const normalized_sand_fraction = sand_fraction / mineral_fraction;
    const normalized_silt_fraction = silt_fraction / mineral_fraction;
    const normalized_clay_fraction = clay_fraction / mineral_fraction;
    if (normalized_clay_fraction >= 0.4) {
        if (normalized_silt_fraction >= 0.4) return .silty_clay;
        if (normalized_sand_fraction >= 0.45) return .sandy_clay;
        return .clay;
    }
    if (normalized_clay_fraction >= 0.27) {
        if (normalized_sand_fraction >= 0.45) return .sandy_clay;
        if (normalized_sand_fraction <= 0.2) return .silty_clay_loam;
        return .clay_loam;
    }
    if (normalized_clay_fraction >= 0.2 and normalized_sand_fraction >= 0.45)
        return .sandy_clay_loam;
    if (normalized_silt_fraction >= 0.8 and normalized_clay_fraction < 0.12) return .silt;
    if (normalized_silt_fraction >= 0.5 and normalized_sand_fraction < 0.5) return .silt_loam;
    if (normalized_sand_fraction >= 0.85 and normalized_clay_fraction < 0.1) return .sand;
    if (normalized_sand_fraction >= 0.7 and normalized_clay_fraction < 0.15) return .loamy_sand;
    if (normalized_sand_fraction >= 0.43 and normalized_clay_fraction < 0.2) return .sandy_loam;
    if (normalized_clay_fraction >= 0.27) return .clay_loam;
    return .loam;
}

const CarselParrishRow = struct {
    residual_water_content_m3_per_m3: f64,
    saturated_water_content_m3_per_m3: f64,
    alpha_per_cm: f64,
    n: f64,
    saturated_hydraulic_conductivity_cm_per_day: f64,
};

fn carselParrishRow(
    residual_water_content_m3_per_m3: f64,
    saturated_water_content_m3_per_m3: f64,
    alpha_per_cm: f64,
    n: f64,
    saturated_hydraulic_conductivity_cm_per_day: f64,
) CarselParrishRow {
    return .{
        .residual_water_content_m3_per_m3 = residual_water_content_m3_per_m3,
        .saturated_water_content_m3_per_m3 = saturated_water_content_m3_per_m3,
        .alpha_per_cm = alpha_per_cm,
        .n = n,
        .saturated_hydraulic_conductivity_cm_per_day = saturated_hydraulic_conductivity_cm_per_day,
    };
}

/// Carsel-Parrish-type mean parameters copied into ordinary runtime data.
/// Alpha is converted from cm^-1 to m^-1 and Ksat from cm day^-1 to m h^-1.
pub fn carselParrishDefault(
    texture: SoilTextureClass,
    saturated_water_content_m3_per_m3: ?f64,
) !MualemVanGenuchtenParameters {
    const row: CarselParrishRow = switch (texture) {
        .sand => carselParrishRow(0.045, 0.43, 0.145, 2.68, 712.8),
        .loamy_sand => carselParrishRow(0.057, 0.41, 0.124, 2.28, 350.2),
        .sandy_loam => carselParrishRow(0.065, 0.41, 0.075, 1.89, 106.1),
        .loam => carselParrishRow(0.078, 0.43, 0.036, 1.56, 24.96),
        .silt_loam => carselParrishRow(0.067, 0.45, 0.020, 1.41, 10.8),
        .silt => carselParrishRow(0.034, 0.46, 0.016, 1.37, 6.0),
        .sandy_clay_loam => carselParrishRow(0.100, 0.39, 0.059, 1.48, 31.44),
        .clay_loam => carselParrishRow(0.095, 0.41, 0.019, 1.31, 6.24),
        .silty_clay_loam => carselParrishRow(0.089, 0.43, 0.010, 1.23, 1.68),
        .sandy_clay => carselParrishRow(0.100, 0.38, 0.027, 1.23, 2.88),
        .silty_clay => carselParrishRow(0.070, 0.36, 0.005, 1.09, 0.48),
        .clay => carselParrishRow(0.068, 0.38, 0.008, 1.09, 4.80),
    };
    const theta_s = saturated_water_content_m3_per_m3 orelse
        row.saturated_water_content_m3_per_m3;
    const parameters: MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = row.residual_water_content_m3_per_m3,
        .saturated_water_content_m3_per_m3 = theta_s,
        .alpha_per_m = 100.0 * row.alpha_per_cm,
        .n = row.n,
        .saturated_hydraulic_conductivity_m_per_h = row.saturated_hydraulic_conductivity_cm_per_day / 2400.0,
    };
    try parameters.validate();
    return parameters;
}

const RetentionFitEvaluation = struct {
    residual: f64,
    residual_water_content_m3_per_m3: f64,
    alpha_per_m: f64,
};

const RetentionFitContext = struct {
    inputs: MualemVanGenuchtenFitInputs,
    minimum_n: f64,
    maximum_n: f64,
    fixed_point_slope: f64,
};

fn retentionFitResidual(context: *const RetentionFitContext, n: f64) f64 {
    const evaluation = evaluateRetentionFit(context.inputs, n) catch
        return std.math.nan(f64);
    return evaluation.residual;
}

fn retentionFitDerivative(context: *const RetentionFitContext, n: f64) f64 {
    const scale = @max(@abs(n), 1.0);
    const step = @sqrt(std.math.floatEps(f64)) * scale;
    const lower = @max(context.minimum_n, n - step);
    const upper = @min(context.maximum_n, n + step);
    if (!(upper > lower)) return std.math.nan(f64);
    const lower_residual = retentionFitResidual(context, lower);
    const upper_residual = retentionFitResidual(context, upper);
    return (upper_residual - lower_residual) / (upper - lower);
}

/// A diagonally scaled fixed-point image used only as private Anderson history.
/// The bracket secant supplies a physical water-content-per-shape scale; this
/// raw image is never publishable state in `numerics.newtonPicard`.
fn retentionFitPicard(context: *const RetentionFitContext, n: f64) f64 {
    return n - retentionFitResidual(context, n) / context.fixed_point_slope;
}

/// Fits the original van Genuchten curve. For an inflection in water content
/// versus pressure head, `(alpha * |h_inflection|)^n = m`; this removes alpha
/// from the remaining scalar solve for n.
pub fn fitOriginalMualemVanGenuchten(
    inputs: MualemVanGenuchtenFitInputs,
    options: MualemVanGenuchtenFitOptions,
) !MualemVanGenuchtenFitResult {
    try options.validate();
    inline for (@typeInfo(MualemVanGenuchtenFitInputs).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteMualemVanGenuchtenFitInput;
    }
    if (inputs.saturated_water_content_m3_per_m3 <= 0 or
        inputs.saturated_water_content_m3_per_m3 > 1 or
        inputs.field_capacity_water_content_m3_per_m3 <= 0 or
        inputs.field_capacity_water_content_m3_per_m3 >= inputs.saturated_water_content_m3_per_m3 or
        inputs.wilting_point_water_content_m3_per_m3 <= 0 or
        inputs.wilting_point_water_content_m3_per_m3 >= inputs.field_capacity_water_content_m3_per_m3 or
        inputs.field_capacity_pressure_head_m >= 0 or
        inputs.wilting_point_pressure_head_m >= inputs.field_capacity_pressure_head_m or
        inputs.inflection_pressure_head_m >= 0 or
        inputs.saturated_hydraulic_conductivity_m_per_h < 0)
    {
        return error.InvalidMualemVanGenuchtenFitInput;
    }

    const lower = try evaluateRetentionFit(inputs, options.minimum_n);
    const upper = try evaluateRetentionFit(inputs, options.maximum_n);
    if (std.math.signbit(lower.residual) == std.math.signbit(upper.residual))
        return error.MualemVanGenuchtenFitNotBracketed;
    const fixed_point_slope =
        (upper.residual - lower.residual) /
        (options.maximum_n - options.minimum_n);
    if (!std.math.isFinite(fixed_point_slope) or fixed_point_slope == 0)
        return error.InvalidMualemVanGenuchtenFitCandidate;
    const context: RetentionFitContext = .{
        .inputs = inputs,
        .minimum_n = options.minimum_n,
        .maximum_n = options.maximum_n,
        .fixed_point_slope = fixed_point_slope,
    };
    const residual_scale = @max(
        inputs.saturated_water_content_m3_per_m3,
        @max(
            inputs.field_capacity_water_content_m3_per_m3,
            inputs.wilting_point_water_content_m3_per_m3,
        ),
    );
    // Begin in the usual mineral-soil shape range instead of the middle of a
    // deliberately broad safety bracket, where the retention residual becomes
    // nearly flat. Every promoted update remains damped Newton or Anderson.
    const initial_n = std.math.clamp(2.0, options.minimum_n, options.maximum_n);
    const solved = numerics.newtonPicard(
        &context,
        retentionFitResidual,
        retentionFitDerivative,
        retentionFitPicard,
        options.minimum_n,
        options.maximum_n,
        initial_n,
        .{
            .absolute_tolerance = options.water_content_absolute_tolerance_m3_per_m3,
            .relative_tolerance = options.water_content_relative_tolerance,
            .picard_relaxation = options.picard_relaxation,
            .residual_scale = residual_scale,
            .max_iterations = options.maximum_iterations,
            .safeguard_with_bracket = true,
        },
    ) catch |err| {
        std.log.warn(
            "Mualem-van Genuchten Newton-Anderson fit failed: error={s} max_iterations={d} absolute_tolerance={e} relative_tolerance={e}",
            .{ @errorName(err), options.maximum_iterations, options.water_content_absolute_tolerance_m3_per_m3, options.water_content_relative_tolerance },
        );
        return switch (err) {
            error.NewtonPicardDidNotConverge,
            error.NewtonPicardStagnated,
            error.NewtonPicardDiverged,
            => error.MualemVanGenuchtenFitDidNotConverge,
            else => err,
        };
    };
    const evaluation = try evaluateRetentionFit(inputs, solved.root);
    return makeRetentionFitResult(inputs, solved.root, evaluation, solved);
}

fn evaluateRetentionFit(
    inputs: MualemVanGenuchtenFitInputs,
    n: f64,
) !RetentionFitEvaluation {
    const m = 1.0 - 1.0 / n;
    const alpha_per_m =
        std.math.pow(f64, m, 1.0 / n) / -inputs.inflection_pressure_head_m;
    const field_effective_saturation = std.math.pow(
        f64,
        1.0 + std.math.pow(
            f64,
            alpha_per_m * -inputs.field_capacity_pressure_head_m,
            n,
        ),
        -m,
    );
    const wilting_effective_saturation = std.math.pow(
        f64,
        1.0 + std.math.pow(
            f64,
            alpha_per_m * -inputs.wilting_point_pressure_head_m,
            n,
        ),
        -m,
    );
    const field_denominator = 1.0 - field_effective_saturation;
    if (!std.math.isFinite(alpha_per_m) or alpha_per_m <= 0 or
        !std.math.isFinite(field_denominator) or field_denominator <= 0)
    {
        return error.InvalidMualemVanGenuchtenFitCandidate;
    }
    const residual_water_content =
        (inputs.field_capacity_water_content_m3_per_m3 -
            inputs.saturated_water_content_m3_per_m3 *
                field_effective_saturation) /
        field_denominator;
    if (!std.math.isFinite(residual_water_content))
        return error.InvalidMualemVanGenuchtenFitCandidate;
    const predicted_wilting_water_content =
        residual_water_content +
        (inputs.saturated_water_content_m3_per_m3 - residual_water_content) *
            wilting_effective_saturation;
    return .{
        .residual = predicted_wilting_water_content -
            inputs.wilting_point_water_content_m3_per_m3,
        .residual_water_content_m3_per_m3 = residual_water_content,
        .alpha_per_m = alpha_per_m,
    };
}

fn makeRetentionFitResult(
    inputs: MualemVanGenuchtenFitInputs,
    n: f64,
    evaluation: RetentionFitEvaluation,
    solved: numerics.SolveResult,
) !MualemVanGenuchtenFitResult {
    const parameters: MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = evaluation.residual_water_content_m3_per_m3,
        .saturated_water_content_m3_per_m3 = inputs.saturated_water_content_m3_per_m3,
        .alpha_per_m = evaluation.alpha_per_m,
        .n = n,
        .pore_connectivity = inputs.pore_connectivity,
        .saturated_hydraulic_conductivity_m_per_h = inputs.saturated_hydraulic_conductivity_m_per_h,
    };
    try parameters.validate();
    return .{
        .parameters = parameters,
        .iterations = solved.iterations,
        .newton_raphson_steps = solved.newton_raphson_steps,
        .picard_steps = solved.picard_steps,
        .anderson_steps = solved.anderson_steps,
        .residual_water_content_m3_per_m3 = evaluation.residual_water_content_m3_per_m3,
    };
}

/// Runtime science parameters for the HOUR1/WATSUB water-retention functions.
/// Values are loaded by the caller; no parameters.h-sized global state exists.
pub const Parameters = struct {
    saturation_water_potential_megapascal: f64,
    minimum_water_potential_megapascal: f64,
    organic_soil_threshold_g_per_megagram: f64,
    mineral_field_capacity_intercept: f64,
    mineral_field_capacity_sand_coefficient: f64,
    mineral_field_capacity_clay_coefficient: f64,
    mineral_field_capacity_organic_coefficient_per_g_per_megagram: f64,
    mineral_wilting_point_intercept: f64,
    mineral_wilting_point_clay_coefficient: f64,
    mineral_wilting_point_organic_coefficient_per_g_per_megagram: f64,
    organic_bulk_density_threshold_1_megagrams_per_m3: f64,
    organic_bulk_density_threshold_2_megagrams_per_m3: f64,
    organic_field_capacity_1: f64,
    organic_field_capacity_2: f64,
    organic_field_capacity_3: f64,
    organic_wilting_point_1: f64,
    organic_wilting_point_2: f64,
    organic_wilting_point_3: f64,
    maximum_field_capacity_fraction_of_porosity: f64,
    maximum_wilting_point_fraction_of_field_capacity: f64,
    saturation_to_field_shape: f64,
    below_wilting_shape: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.NonFiniteSoilRetentionParameter;
        if (self.saturation_water_potential_megapascal >= 0 or self.minimum_water_potential_megapascal >= self.saturation_water_potential_megapascal or self.organic_soil_threshold_g_per_megagram < 0 or self.organic_bulk_density_threshold_1_megagrams_per_m3 <= 0 or self.organic_bulk_density_threshold_2_megagrams_per_m3 <= self.organic_bulk_density_threshold_1_megagrams_per_m3 or self.maximum_field_capacity_fraction_of_porosity <= 0 or self.maximum_field_capacity_fraction_of_porosity > 1 or self.maximum_wilting_point_fraction_of_field_capacity <= 0 or self.maximum_wilting_point_fraction_of_field_capacity > 1 or self.saturation_to_field_shape <= 0 or self.below_wilting_shape <= 0) return error.InvalidSoilRetentionParameter;
    }
};

/// HOUR1 coefficients used only when an older runscript omits the runtime
/// soil_solver record. The returned value is ordinary runtime data.
pub fn compatibilityParameters() Parameters {
    return .{
        .saturation_water_potential_megapascal = -0.0005,
        .minimum_water_potential_megapascal = -1.5e12,
        .organic_soil_threshold_g_per_megagram = 250_000,
        .mineral_field_capacity_intercept = 0.2576,
        .mineral_field_capacity_sand_coefficient = -0.20,
        .mineral_field_capacity_clay_coefficient = 0.36,
        .mineral_field_capacity_organic_coefficient_per_g_per_megagram = 0.60e-6,
        .mineral_wilting_point_intercept = 0.0260,
        .mineral_wilting_point_clay_coefficient = 0.50,
        .mineral_wilting_point_organic_coefficient_per_g_per_megagram = 0.32e-6,
        .organic_bulk_density_threshold_1_megagrams_per_m3 = 0.075,
        .organic_bulk_density_threshold_2_megagrams_per_m3 = 0.195,
        .organic_field_capacity_1 = 0.27,
        .organic_field_capacity_2 = 0.62,
        .organic_field_capacity_3 = 0.71,
        .organic_wilting_point_1 = 0.04,
        .organic_wilting_point_2 = 0.15,
        .organic_wilting_point_3 = 0.22,
        .maximum_field_capacity_fraction_of_porosity = 0.75,
        .maximum_wilting_point_fraction_of_field_capacity = 0.75,
        .saturation_to_field_shape = 0.5,
        .below_wilting_shape = 0.5,
    };
}

pub const LayerInputs = struct {
    porosity_fraction: f64,
    macropore_fraction: f64,
    sand_fraction: f64,
    clay_fraction: f64,
    organic_carbon_g_per_megagram: f64,
    bulk_density_megagrams_per_m3: f64,
    supplied_field_capacity_fraction: ?f64,
    supplied_wilting_point_fraction: ?f64,
};

pub const Curve = struct {
    field_capacity_fraction: f64,
    wilting_point_fraction: f64,
    saturation_water_potential_megapascal: f64,
    field_capacity_water_potential_megapascal: f64,
    wilting_point_water_potential_megapascal: f64,
    minimum_water_potential_megapascal: f64,
    saturation_to_field_shape: f64,
    below_wilting_shape: f64,
};

pub const ResolvedCurve = struct {
    porosity_fraction: f64,
    curve: Curve,

    pub fn waterPotentialMpa(self: ResolvedCurve, water_fraction: f64) !f64 {
        if (!std.math.isFinite(water_fraction) or water_fraction <= 0) return error.InvalidSoilWaterFraction;
        const water = @min(water_fraction, self.porosity_fraction);
        if (water >= self.porosity_fraction) return self.curve.saturation_water_potential_megapascal;
        const log_water = @log(water);
        const log_porosity = @log(self.porosity_fraction);
        const log_field_capacity = @log(self.curve.field_capacity_fraction);
        const log_wilting_point = @log(self.curve.wilting_point_fraction);
        const log_saturation_potential = @log(-self.curve.saturation_water_potential_megapascal);
        const log_field_potential = @log(-self.curve.field_capacity_water_potential_megapascal);
        const log_wilting_potential = @log(-self.curve.wilting_point_water_potential_megapascal);
        const potential = if (water < self.curve.wilting_point_fraction)
            -@exp(log_wilting_potential + self.curve.below_wilting_shape * ((log_wilting_point - log_water) / (log_field_capacity - log_wilting_point) * (log_wilting_potential - log_field_potential)))
        else if (water < self.curve.field_capacity_fraction)
            -@exp(log_field_potential + ((log_field_capacity - log_water) / (log_field_capacity - log_wilting_point) * (log_wilting_potential - log_field_potential)))
        else
            -@exp(log_saturation_potential + std.math.pow(f64, @max(0.0, (log_porosity - log_water) / (log_porosity - log_field_capacity)), self.curve.saturation_to_field_shape) * (log_field_potential - log_saturation_potential));
        return @max(self.curve.minimum_water_potential_megapascal, potential);
    }

    /// Exact inverse of the HOUR1 log-water branches. NITRO evaluates this at
    /// PSIHY=-1.5e4 MPa to exclude hygroscopic water from active water.
    pub fn waterFractionAtPotentialMpa(self: ResolvedCurve, target_potential_megapascal: f64) !f64 {
        if (!std.math.isFinite(target_potential_megapascal) or target_potential_megapascal >= 0) return error.InvalidTargetWaterPotential;
        const c = self.curve;
        const log_target = @log(-target_potential_megapascal);
        const log_saturation_potential = @log(-c.saturation_water_potential_megapascal);
        const log_field_potential = @log(-c.field_capacity_water_potential_megapascal);
        const log_wilting_potential = @log(-c.wilting_point_water_potential_megapascal);
        const log_porosity = @log(self.porosity_fraction);
        const log_field = @log(c.field_capacity_fraction);
        const log_wilting = @log(c.wilting_point_fraction);
        const log_water = if (target_potential_megapascal < c.wilting_point_water_potential_megapascal)
            log_wilting - (log_target - log_wilting_potential) * (log_field - log_wilting) / (c.below_wilting_shape * (log_wilting_potential - log_field_potential))
        else if (target_potential_megapascal < c.field_capacity_water_potential_megapascal)
            log_field - (log_target - log_field_potential) * (log_field - log_wilting) / (log_wilting_potential - log_field_potential)
        else
            log_porosity - std.math.pow(f64, std.math.clamp((log_target - log_saturation_potential) / (log_field_potential - log_saturation_potential), 0, 1), 1 / c.saturation_to_field_shape) * (log_porosity - log_field);
        const water = std.math.clamp(@exp(log_water), 0, self.porosity_fraction);
        if (!std.math.isFinite(water)) return error.NonFiniteWaterFraction;
        return water;
    }

    /// HOUR1 `THETY`/`THETZ` dry-end water content (`hour1.f:2175--2178`).
    ///
    /// The reference extrapolates the log-log field-capacity-to-wilting
    /// segment below wilting without the `below_wilting_shape` used by
    /// `waterPotentialMpa`.  This is intentionally not the mathematical
    /// inverse above: NITRO consumes the source extrapolation when excluding
    /// hygroscopic water from biologically active soil water.
    pub fn legacyDryEndWaterFractionAtPotentialMpa(self: ResolvedCurve, target_potential_megapascal: f64) !f64 {
        const c = self.curve;
        inline for (.{
            self.porosity_fraction,
            c.field_capacity_fraction,
            c.wilting_point_fraction,
            c.field_capacity_water_potential_megapascal,
            c.wilting_point_water_potential_megapascal,
            target_potential_megapascal,
        }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilRetentionInput;
        if (self.porosity_fraction <= 0 or
            c.field_capacity_fraction <= c.wilting_point_fraction or
            c.wilting_point_fraction <= 0 or
            c.field_capacity_water_potential_megapascal >= 0 or
            c.wilting_point_water_potential_megapascal >= c.field_capacity_water_potential_megapascal or
            target_potential_megapascal >= c.wilting_point_water_potential_megapascal)
            return error.InvalidTargetWaterPotential;

        const log_field_water = @log(c.field_capacity_fraction);
        const log_wilting_water = @log(c.wilting_point_fraction);
        const log_field_potential = @log(-c.field_capacity_water_potential_megapascal);
        const log_wilting_potential = @log(-c.wilting_point_water_potential_megapascal);
        const log_target_potential = @log(-target_potential_megapascal);
        const water = @exp(
            (log_field_potential - log_target_potential) *
                (log_field_water - log_wilting_water) /
                (log_wilting_potential - log_field_potential) +
                log_field_water,
        );
        if (!std.math.isFinite(water) or water < 0 or water > self.porosity_fraction)
            return error.NonFiniteWaterFraction;
        return water;
    }
};

pub fn resolve(parameters: Parameters, inputs: LayerInputs, field_capacity_water_potential_megapascal: f64, wilting_point_water_potential_megapascal: f64) !ResolvedCurve {
    try parameters.validate();
    inline for (.{ inputs.porosity_fraction, inputs.macropore_fraction, inputs.sand_fraction, inputs.clay_fraction, inputs.organic_carbon_g_per_megagram, inputs.bulk_density_megagrams_per_m3, field_capacity_water_potential_megapascal, wilting_point_water_potential_megapascal }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilRetentionInput;
    if (inputs.porosity_fraction <= 0 or inputs.porosity_fraction > 1 or inputs.macropore_fraction < 0 or inputs.macropore_fraction >= 1 or inputs.sand_fraction < 0 or inputs.clay_fraction < 0 or inputs.sand_fraction + inputs.clay_fraction > 1 or inputs.organic_carbon_g_per_megagram < 0 or inputs.bulk_density_megagrams_per_m3 < 0 or field_capacity_water_potential_megapascal >= 0 or wilting_point_water_potential_megapascal >= field_capacity_water_potential_megapascal) return error.InvalidSoilRetentionInput;

    const both_supplied = inputs.supplied_field_capacity_fraction != null and inputs.supplied_wilting_point_fraction != null;
    var field_capacity = if (both_supplied) inputs.supplied_field_capacity_fraction.? else estimateFieldCapacity(parameters, inputs);
    var wilting_point = if (both_supplied) inputs.supplied_wilting_point_fraction.? else estimateWiltingPoint(parameters, inputs);
    // HOUR1 estimates both properties when either ISOIL flag says unknown;
    // only that estimated branch applies the non-macropore correction and
    // the 0.75*POROS / 0.75*FC ceilings.
    if (!both_supplied) {
        field_capacity = @min(parameters.maximum_field_capacity_fraction_of_porosity * inputs.porosity_fraction, field_capacity / (1.0 - inputs.macropore_fraction));
        wilting_point = @min(parameters.maximum_wilting_point_fraction_of_field_capacity * field_capacity, wilting_point / (1.0 - inputs.macropore_fraction));
    }
    if (!std.math.isFinite(field_capacity) or !std.math.isFinite(wilting_point) or wilting_point <= 0 or field_capacity <= wilting_point or field_capacity >= inputs.porosity_fraction) return error.InvalidResolvedSoilRetentionCurve;
    return .{ .porosity_fraction = inputs.porosity_fraction, .curve = .{ .field_capacity_fraction = field_capacity, .wilting_point_fraction = wilting_point, .saturation_water_potential_megapascal = parameters.saturation_water_potential_megapascal, .field_capacity_water_potential_megapascal = field_capacity_water_potential_megapascal, .wilting_point_water_potential_megapascal = wilting_point_water_potential_megapascal, .minimum_water_potential_megapascal = parameters.minimum_water_potential_megapascal, .saturation_to_field_shape = parameters.saturation_to_field_shape, .below_wilting_shape = parameters.below_wilting_shape } };
}

fn estimateFieldCapacity(parameters: Parameters, inputs: LayerInputs) f64 {
    if (inputs.organic_carbon_g_per_megagram < parameters.organic_soil_threshold_g_per_megagram) return parameters.mineral_field_capacity_intercept + parameters.mineral_field_capacity_sand_coefficient * inputs.sand_fraction + parameters.mineral_field_capacity_clay_coefficient * inputs.clay_fraction + parameters.mineral_field_capacity_organic_coefficient_per_g_per_megagram * inputs.organic_carbon_g_per_megagram;
    if (inputs.bulk_density_megagrams_per_m3 < parameters.organic_bulk_density_threshold_1_megagrams_per_m3) return parameters.organic_field_capacity_1;
    if (inputs.bulk_density_megagrams_per_m3 < parameters.organic_bulk_density_threshold_2_megagrams_per_m3) return parameters.organic_field_capacity_2;
    return parameters.organic_field_capacity_3;
}

fn estimateWiltingPoint(parameters: Parameters, inputs: LayerInputs) f64 {
    if (inputs.organic_carbon_g_per_megagram < parameters.organic_soil_threshold_g_per_megagram) return parameters.mineral_wilting_point_intercept + parameters.mineral_wilting_point_clay_coefficient * inputs.clay_fraction + parameters.mineral_wilting_point_organic_coefficient_per_g_per_megagram * inputs.organic_carbon_g_per_megagram;
    if (inputs.bulk_density_megagrams_per_m3 < parameters.organic_bulk_density_threshold_1_megagrams_per_m3) return parameters.organic_wilting_point_1;
    if (inputs.bulk_density_megagrams_per_m3 < parameters.organic_bulk_density_threshold_2_megagrams_per_m3) return parameters.organic_wilting_point_2;
    return parameters.organic_wilting_point_3;
}

test "original Mualem van Genuchten retention is invertible and monotone" {
    const loam: MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.078,
        .saturated_water_content_m3_per_m3 = 0.43,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0.0104,
    };
    try loam.validate();
    try std.testing.expectApproxEqAbs(@as(f64, 0.43), try loam.waterContentAtPressureHead(0), 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0104), try loam.hydraulicConductivityMPerH(0), 1.0e-15);
    const pressure_heads_m = [_]f64{ -0.1, -0.33, -1.5, -15.0 };
    var previous_water_content = loam.saturated_water_content_m3_per_m3;
    var previous_conductivity = loam.saturated_hydraulic_conductivity_m_per_h;
    for (pressure_heads_m) |pressure_head_m| {
        const water_content = try loam.waterContentAtPressureHead(pressure_head_m);
        const reconstructed_head =
            try loam.pressureHeadAtWaterContent(water_content);
        const conductivity =
            try loam.hydraulicConductivityMPerH(pressure_head_m);
        try std.testing.expectApproxEqRel(pressure_head_m, reconstructed_head, 1.0e-12);
        try std.testing.expect(water_content < previous_water_content);
        try std.testing.expect(conductivity < previous_conductivity);
        try std.testing.expect(try loam.waterCapacityPerM(pressure_head_m) > 0);
        previous_water_content = water_content;
        previous_conductivity = conductivity;
    }
}

test "original van Genuchten residual endpoint has finite asymptotic head" {
    const parameters: MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.45,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    const pressure_head_m = try parameters.pressureHeadAtWaterContent(
        parameters.residual_water_content_m3_per_m3,
    );
    try std.testing.expect(std.math.isFinite(pressure_head_m));
    try std.testing.expect(pressure_head_m < 0);
    const recovered = try parameters.waterContentAtPressureHead(pressure_head_m);
    try std.testing.expectApproxEqAbs(
        parameters.residual_water_content_m3_per_m3,
        recovered,
        std.math.floatEps(f64),
    );
}

test "original Mualem van Genuchten excludes nonphysical parameters" {
    var parameters: MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.1,
        .saturated_water_content_m3_per_m3 = 0.5,
        .alpha_per_m = 2,
        .n = 1.5,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    };
    parameters.n = 1;
    try std.testing.expectError(error.InvalidMualemVanGenuchtenParameter, parameters.validate());
    parameters.n = 1.5;
    parameters.saturated_water_content_m3_per_m3 = 0.1;
    try std.testing.expectError(error.InvalidMualemVanGenuchtenParameter, parameters.validate());
}

test "runtime inflection fit recovers original Mualem van Genuchten parameters" {
    const expected: MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.078,
        .saturated_water_content_m3_per_m3 = 0.43,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0.0104,
    };
    const field_capacity_pressure_head_m = -0.33;
    const wilting_point_pressure_head_m = -15;
    const inflection_pressure_head_m = try expected.inflectionPressureHeadM();
    const fitted = try fitOriginalMualemVanGenuchten(.{
        .saturated_water_content_m3_per_m3 = expected.saturated_water_content_m3_per_m3,
        .field_capacity_water_content_m3_per_m3 = try expected.waterContentAtPressureHead(field_capacity_pressure_head_m),
        .field_capacity_pressure_head_m = field_capacity_pressure_head_m,
        .wilting_point_water_content_m3_per_m3 = try expected.waterContentAtPressureHead(wilting_point_pressure_head_m),
        .wilting_point_pressure_head_m = wilting_point_pressure_head_m,
        .inflection_pressure_head_m = inflection_pressure_head_m,
        .saturated_hydraulic_conductivity_m_per_h = expected.saturated_hydraulic_conductivity_m_per_h,
    }, .{ .maximum_iterations = 60 });
    try std.testing.expect(fitted.iterations < 60);
    try std.testing.expect(fitted.newton_raphson_steps > 0);
    try std.testing.expectEqual(fitted.picard_steps, fitted.anderson_steps);
    try std.testing.expectApproxEqRel(expected.n, fitted.parameters.n, 1.0e-8);
    try std.testing.expectApproxEqRel(expected.alpha_per_m, fitted.parameters.alpha_per_m, 1.0e-8);
    try std.testing.expectApproxEqAbs(
        expected.residual_water_content_m3_per_m3,
        fitted.parameters.residual_water_content_m3_per_m3,
        1.0e-9,
    );
}

test "runtime inflection fit obeys its hard nonlinear ceiling" {
    const expected: MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.078,
        .saturated_water_content_m3_per_m3 = 0.43,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0.0104,
    };
    try std.testing.expectError(
        error.MualemVanGenuchtenFitDidNotConverge,
        fitOriginalMualemVanGenuchten(.{
            .saturated_water_content_m3_per_m3 = expected.saturated_water_content_m3_per_m3,
            .field_capacity_water_content_m3_per_m3 = try expected.waterContentAtPressureHead(-0.33),
            .field_capacity_pressure_head_m = -0.33,
            .wilting_point_water_content_m3_per_m3 = try expected.waterContentAtPressureHead(-15),
            .wilting_point_pressure_head_m = -15,
            .inflection_pressure_head_m = try expected.inflectionPressureHeadM(),
            .saturated_hydraulic_conductivity_m_per_h = expected.saturated_hydraulic_conductivity_m_per_h,
        }, .{
            .water_content_absolute_tolerance_m3_per_m3 = 1.0e-14,
            .water_content_relative_tolerance = 1.0e-12,
            .maximum_iterations = 1,
        }),
    );
}

test "runtime retention fit production source cannot reintroduce bisection" {
    const source = @embedFile("retention.zig");
    const fit_start = std.mem.indexOf(u8, source, "pub fn fitOriginalMualemVanGenuchten") orelse
        return error.MissingRuntimeRetentionFit;
    const evaluation_start = std.mem.indexOfPos(u8, source, fit_start, "fn evaluateRetentionFit") orelse
        return error.MissingRuntimeRetentionEvaluation;
    const fit_source = source[fit_start..evaluation_start];
    try std.testing.expect(std.mem.indexOf(u8, fit_source, "numerics.newtonPicard(") != null);
    try std.testing.expect(std.mem.indexOf(u8, fit_source, "bisection") == null);
}

test "van Genuchten inflection head is the water capacity maximum" {
    // The fit eliminates alpha via the closed form for the inflection, so that
    // closed form has to really be the inflection: dtheta/dh maximal, i.e. at
    // least the capacity at any neighbouring head. Checked against a sweep
    // rather than by asserting the closed form against itself.
    const parameters: MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.078,
        .saturated_water_content_m3_per_m3 = 0.43,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0.0104,
    };
    const inflection_head_m = try parameters.inflectionPressureHeadM();
    try std.testing.expect(inflection_head_m < 0);
    const peak_capacity = try parameters.waterCapacityPerM(inflection_head_m);
    for ([_]f64{ 0.2, 0.5, 0.8, 0.95, 1.05, 1.25, 2, 5, 40 }) |scale| {
        const probe_capacity =
            try parameters.waterCapacityPerM(inflection_head_m * scale);
        try std.testing.expect(probe_capacity <= peak_capacity);
    }
    // The inflection must land strictly inside the retention domain for the fit
    // to have a well-posed interior anchor point.
    const inflection_water_content =
        try parameters.inflectionWaterContentM3PerM3();
    try std.testing.expect(inflection_water_content > parameters.residual_water_content_m3_per_m3);
    try std.testing.expect(inflection_water_content < parameters.saturated_water_content_m3_per_m3);
}

test "Carsel and Parrish defaults yield a usable inflection for every texture" {
    // Every texture must supply a non-degenerate default inflection anchor, so
    // that a layer with no measured retention data can still be fitted.
    for (std.enums.values(SoilTextureClass)) |texture| {
        const parameters = try carselParrishDefault(texture, 0.45);
        const inflection_water_content =
            try parameters.inflectionWaterContentM3PerM3();
        try std.testing.expect(inflection_water_content > parameters.residual_water_content_m3_per_m3);
        try std.testing.expect(inflection_water_content < parameters.saturated_water_content_m3_per_m3);
    }
}

test "runtime Carsel Parrish fallback follows USDA texture and supplied porosity" {
    const texture = try classifyUsdaSoilTexture(0.40, 0.40, 0.20);
    try std.testing.expectEqual(SoilTextureClass.loam, texture);
    try std.testing.expectEqual(
        texture,
        try classifyUsdaSoilTexture(1.20, 1.20, 0.60),
    );
    const loam = try carselParrishDefault(texture, 0.47);
    try std.testing.expectApproxEqAbs(@as(f64, 0.078), loam.residual_water_content_m3_per_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.47), loam.saturated_water_content_m3_per_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3.6), loam.alpha_per_m, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.56), loam.n, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0104), loam.saturated_hydraulic_conductivity_m_per_h, 1.0e-15);
}

test "runtime retention parameters reproduce mineral threshold equations" {
    const parameters: Parameters = .{ .saturation_water_potential_megapascal = -0.0005, .minimum_water_potential_megapascal = -1.5e12, .organic_soil_threshold_g_per_megagram = 250_000, .mineral_field_capacity_intercept = 0.2576, .mineral_field_capacity_sand_coefficient = -0.20, .mineral_field_capacity_clay_coefficient = 0.36, .mineral_field_capacity_organic_coefficient_per_g_per_megagram = 0.60e-6, .mineral_wilting_point_intercept = 0.0260, .mineral_wilting_point_clay_coefficient = 0.50, .mineral_wilting_point_organic_coefficient_per_g_per_megagram = 0.32e-6, .organic_bulk_density_threshold_1_megagrams_per_m3 = 0.075, .organic_bulk_density_threshold_2_megagrams_per_m3 = 0.195, .organic_field_capacity_1 = 0.27, .organic_field_capacity_2 = 0.62, .organic_field_capacity_3 = 0.71, .organic_wilting_point_1 = 0.04, .organic_wilting_point_2 = 0.15, .organic_wilting_point_3 = 0.22, .maximum_field_capacity_fraction_of_porosity = 0.75, .maximum_wilting_point_fraction_of_field_capacity = 0.75, .saturation_to_field_shape = 0.5, .below_wilting_shape = 0.5 };
    const resolved = try resolve(parameters, .{ .porosity_fraction = 0.5, .macropore_fraction = 0, .sand_fraction = 0.4, .clay_fraction = 0.2, .organic_carbon_g_per_megagram = 10_000, .bulk_density_megagrams_per_m3 = 1.3, .supplied_field_capacity_fraction = null, .supplied_wilting_point_fraction = null }, -0.01, -1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2556), resolved.curve.field_capacity_fraction, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1292), resolved.curve.wilting_point_fraction, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.01), try resolved.waterPotentialMpa(resolved.curve.field_capacity_fraction), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -1.5), try resolved.waterPotentialMpa(resolved.curve.wilting_point_fraction), 1.0e-12);
    const hygroscopic = try resolved.waterFractionAtPotentialMpa(-1.5e4);
    try std.testing.expectApproxEqRel(@as(f64, -1.5e4), try resolved.waterPotentialMpa(hygroscopic), 1.0e-12);
}

test "HOUR1 dry-end water keeps the unshaped FC-to-WP extrapolation" {
    const resolved: ResolvedCurve = .{
        .porosity_fraction = 0.5,
        .curve = .{
            .field_capacity_fraction = 0.30,
            .wilting_point_fraction = 0.12,
            .saturation_water_potential_megapascal = -0.0005,
            .field_capacity_water_potential_megapascal = -0.033,
            .wilting_point_water_potential_megapascal = -1.5,
            .minimum_water_potential_megapascal = -1.5e12,
            .saturation_to_field_shape = 0.5,
            .below_wilting_shape = 0.5,
        },
    };
    const source_thety = try resolved.legacyDryEndWaterFractionAtPotentialMpa(-1.5e4);
    const shaped_inverse = try resolved.waterFractionAtPotentialMpa(-1.5e4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.013148861858652352), source_thety, 1.0e-15);
    try std.testing.expect(source_thety > 9 * shaped_inverse);
    try std.testing.expectError(
        error.InvalidTargetWaterPotential,
        resolved.legacyDryEndWaterFractionAtPotentialMpa(-1.0),
    );
}

test "resolved retention curve is sensitive to the texture erosion mutates" {
    // HOUR1 recomputes CSAND/CCLAY from the SAND/CLAY inventories at
    // `hour1.f:3659--3666` and then re-derives FC/WP in the disturbance-gated
    // reset loop at `hour1.f:2039--2116` (`IFLGS.NE.0`, set by REDIST sediment
    // transport at `redist.f:8524`). Production resolves the curve once during
    // `solver_properties.initMapped` and never re-resolves it, while
    // `soil/profile/erosion_mineral_bridge.refreshSurfaceProperties` does
    // mutate `sand_mass_fraction`/`clay_mass_fraction` every eroding hour.
    // This guard pins the consequence: the curve is not texture-invariant, so
    // a stale curve after erosion is a real numerical divergence and not a
    // cosmetic one. It restates the pedotransfer through the bound owner only,
    // so it stays valid regardless of how the refresh is eventually wired.
    const parameters = compatibilityParameters();
    const base: LayerInputs = .{ .porosity_fraction = 0.5, .macropore_fraction = 0, .sand_fraction = 0.60, .clay_fraction = 0.10, .organic_carbon_g_per_megagram = 10_000, .bulk_density_megagrams_per_m3 = 1.3, .supplied_field_capacity_fraction = null, .supplied_wilting_point_fraction = null };
    // Selective removal of coarse particles is the direction erosion moves
    // topsoil texture: sand leaves, clay concentrates.
    var eroded = base;
    eroded.sand_fraction = 0.40;
    eroded.clay_fraction = 0.30;
    const before = try resolve(parameters, base, -0.033, -1.5);
    const after = try resolve(parameters, eroded, -0.033, -1.5);
    try std.testing.expect(after.curve.field_capacity_fraction > before.curve.field_capacity_fraction);
    try std.testing.expect(after.curve.wilting_point_fraction > before.curve.wilting_point_fraction);
    // Magnitude, not just sign: -0.20*dSand + 0.36*dClay = 0.112 on FC and
    // 0.50*dClay = 0.100 on WP. A refresh that silently reused the stale curve
    // would be wrong by these amounts, which are large next to FC itself.
    try std.testing.expectApproxEqAbs(@as(f64, 0.112), after.curve.field_capacity_fraction - before.curve.field_capacity_fraction, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.100), after.curve.wilting_point_fraction - before.curve.wilting_point_fraction, 1.0e-12);
    // Falsifiability: when the topsoil texture does not move, re-resolving is
    // a no-op, so the guard above cannot be passing for a trivial reason.
    const unchanged = try resolve(parameters, base, -0.033, -1.5);
    try std.testing.expectEqual(before.curve.field_capacity_fraction, unchanged.curve.field_capacity_fraction);
    try std.testing.expectEqual(before.curve.wilting_point_fraction, unchanged.curve.wilting_point_fraction);
    // And the supplied-data branch is texture-blind, which bounds the blast
    // radius: only layers with a missing ISOIL flag can drift.
    var supplied = eroded;
    supplied.supplied_field_capacity_fraction = 0.30;
    supplied.supplied_wilting_point_fraction = 0.15;
    const supplied_curve = try resolve(parameters, supplied, -0.033, -1.5);
    try std.testing.expectEqual(@as(f64, 0.30), supplied_curve.curve.field_capacity_fraction);
    try std.testing.expectEqual(@as(f64, 0.15), supplied_curve.curve.wilting_point_fraction);
}

test "one missing hydraulic property makes HOUR1 estimate both properties" {
    const parameters = compatibilityParameters();
    const inputs: LayerInputs = .{ .porosity_fraction = 0.5, .macropore_fraction = 0.05, .sand_fraction = 0.4, .clay_fraction = 0.2, .organic_carbon_g_per_megagram = 10_000, .bulk_density_megagrams_per_m3 = 1.3, .supplied_field_capacity_fraction = 0.4, .supplied_wilting_point_fraction = null };
    const resolved = try resolve(parameters, inputs, -0.033, -1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2556 / 0.95), resolved.curve.field_capacity_fraction, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1292 / 0.95), resolved.curve.wilting_point_fraction, 1.0e-12);
}

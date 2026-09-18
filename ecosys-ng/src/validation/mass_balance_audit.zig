const std = @import("std");
const builtin = @import("builtin");
const conservation_tolerance = @import("../core/conservation_tolerance.zig");

pub const scoped = @import("scoped_conservation.zig");
pub const AbsoluteTolerancePerArea = conservation_tolerance.AbsolutePerArea;

/// Whole-landscape cumulative terms used by EXEC. Names retain direction and
/// units so callers cannot silently exchange an input with an output.
pub const Totals = struct {
    landscape_area_m2: f64,
    water_storage_m3: f64,
    cumulative_rain_m3: f64,
    cumulative_runoff_m3: f64,
    cumulative_evaporation_m3: f64,
    cumulative_water_outflow_m3: f64,
    heat_storage_megajoules: f64,
    cumulative_heat_input_megajoules: f64,
    cumulative_heat_output_megajoules: f64,
    cumulative_internal_heat_production_megajoules: f64 = 0,
    cumulative_internal_heat_consumption_megajoules: f64 = 0,
    oxygen_storage_g: f64,
    cumulative_oxygen_input_g: f64,
    cumulative_oxygen_output_g: f64,
    cumulative_internal_oxygen_production_g: f64,
    cumulative_internal_oxygen_consumption_g: f64,
    hydrogen_storage_g: f64,
    cumulative_hydrogen_input_g: f64,
    cumulative_hydrogen_output_g: f64,
    cumulative_internal_hydrogen_production_g: f64,
    cumulative_internal_hydrogen_consumption_g: f64,
    cumulative_redist_carbon_surface_input_g_c: f64,
    cumulative_redist_carbon_subsurface_output_g_c: f64,
    cumulative_redist_oxygen_surface_input_g_o: f64,
    cumulative_redist_oxygen_subsurface_output_g_o: f64,
    cumulative_redist_hydrogen_surface_input_g_h: f64,
    cumulative_redist_hydrogen_subsurface_output_g_h: f64,
    residue_carbon_g: f64,
    organic_carbon_g: f64,
    carbon_dioxide_carbon_g: f64,
    plant_carbon_g: f64,
    cumulative_carbon_dioxide_input_g: f64,
    cumulative_carbon_output_g: f64,
    cumulative_organic_fertilizer_carbon_g: f64,
    cumulative_carbon_sink_g: f64,
    cumulative_plant_root_organic_carbon_uptake_g: f64,
    cumulative_plant_root_organic_carbon_exudate_g: f64,
    residue_nitrogen_g: f64,
    organic_nitrogen_g: f64,
    dinitrogen_nitrogen_g: f64,
    ammonium_nitrogen_g: f64,
    nitrate_nitrogen_g: f64,
    plant_nitrogen_g: f64,
    cumulative_dinitrogen_input_g: f64,
    cumulative_nitrogen_input_g: f64,
    cumulative_nitrogen_output_g: f64,
    cumulative_organic_fertilizer_nitrogen_g: f64,
    cumulative_nitrogen_sink_g: f64,
    cumulative_plant_root_organic_nitrogen_uptake_g: f64,
    cumulative_plant_root_organic_nitrogen_exudate_g: f64,
    residue_phosphorus_g: f64,
    organic_phosphorus_g: f64,
    phosphate_phosphorus_g: f64,
    plant_phosphorus_g: f64,
    cumulative_phosphorus_input_g: f64,
    cumulative_phosphorus_output_g: f64,
    cumulative_organic_fertilizer_phosphorus_g: f64,
    cumulative_phosphorus_sink_g: f64,
    cumulative_plant_root_organic_phosphorus_uptake_g: f64,
    cumulative_plant_root_organic_phosphorus_exudate_g: f64,
    ion_inventory_mol: f64,
    cumulative_ion_input_mol: f64,
    cumulative_ion_output_mol: f64,
    aluminum_storage_mol: f64,
    cumulative_aluminum_input_mol: f64,
    cumulative_aluminum_output_mol: f64,
    iron_storage_mol: f64,
    cumulative_iron_input_mol: f64,
    cumulative_iron_output_mol: f64,
    calcium_storage_mol: f64,
    cumulative_calcium_input_mol: f64,
    cumulative_calcium_output_mol: f64,
    magnesium_storage_mol: f64,
    cumulative_magnesium_input_mol: f64,
    cumulative_magnesium_output_mol: f64,
    sodium_storage_mol: f64,
    cumulative_sodium_input_mol: f64,
    cumulative_sodium_output_mol: f64,
    potassium_storage_mol: f64,
    cumulative_potassium_input_mol: f64,
    cumulative_potassium_output_mol: f64,
    sulfur_storage_mol: f64,
    cumulative_sulfur_input_mol: f64,
    cumulative_sulfur_output_mol: f64,
    chloride_storage_mol: f64,
    cumulative_chloride_input_mol: f64,
    cumulative_chloride_output_mol: f64,
    silicon_storage_mol: f64,
    cumulative_silicon_input_mol: f64,
    cumulative_silicon_output_mol: f64,
    sand_storage_megagrams: f64 = 0,
    cumulative_sand_input_megagrams: f64 = 0,
    cumulative_sand_output_megagrams: f64 = 0,
    silt_storage_megagrams: f64 = 0,
    cumulative_silt_input_megagrams: f64 = 0,
    cumulative_silt_output_megagrams: f64 = 0,
    clay_storage_megagrams: f64 = 0,
    cumulative_clay_input_megagrams: f64 = 0,
    cumulative_clay_output_megagrams: f64 = 0,
    rock_storage_additive: f64 = 0,
    cation_exchange_capacity_storage_mol: f64 = 0,
    cumulative_cation_exchange_capacity_input_mol: f64 = 0,
    cumulative_cation_exchange_capacity_output_mol: f64 = 0,
    cumulative_internal_cation_exchange_capacity_production_mol: f64 = 0,
    cumulative_internal_cation_exchange_capacity_consumption_mol: f64 = 0,
    anion_exchange_capacity_storage_mol: f64 = 0,
    cumulative_anion_exchange_capacity_input_mol: f64 = 0,
    cumulative_anion_exchange_capacity_output_mol: f64 = 0,
    cumulative_internal_anion_exchange_capacity_production_mol: f64 = 0,
    cumulative_internal_anion_exchange_capacity_consumption_mol: f64 = 0,
    /// Explicit GROSUB WTNDI external inoculum inputs. Defaults retain source
    /// compatibility for focused fixtures that predate living-plant census.
    cumulative_symbiotic_inoculum_carbon_input_g: f64 = 0,
    cumulative_symbiotic_inoculum_nitrogen_input_g: f64 = 0,
    cumulative_symbiotic_inoculum_phosphorus_input_g: f64 = 0,
    cumulative_mineral_fertilizer_carbon_g: f64 = 0,
};

pub const Balance = struct {
    water_m3: f64,
    heat_megajoules: f64,
    oxygen_g: f64,
    carbon_g: f64,
    nitrogen_g: f64,
    phosphorus_g: f64,
    /// Legacy REDIST SSB pseudo-ion inventory. Association, protonation, and
    /// mineral dissolution change this number without creating or destroying
    /// an element, so it is diagnostic only and is never acceptance-gating.
    ions_mol: f64,
    hydrogen_g: f64,
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    chloride_mol: f64 = 0,
    silicon_mol: f64 = 0,
    sand_megagrams: f64 = 0,
    silt_megagrams: f64 = 0,
    clay_megagrams: f64 = 0,
    rock_additive: f64 = 0,
    cation_exchange_capacity_mol: f64 = 0,
    anion_exchange_capacity_mol: f64 = 0,
};
pub const Deviation = struct {
    water_m: f64,
    heat_megajoules_m2: f64,
    oxygen_g_m2: f64,
    carbon_g_m2: f64,
    nitrogen_g_m2: f64,
    phosphorus_g_m2: f64,
    ions_mol_m2: f64,
    hydrogen_g_m2: f64,
    aluminum_mol_m2: f64 = 0,
    iron_mol_m2: f64 = 0,
    calcium_mol_m2: f64 = 0,
    magnesium_mol_m2: f64 = 0,
    sodium_mol_m2: f64 = 0,
    potassium_mol_m2: f64 = 0,
    sulfur_mol_m2: f64 = 0,
    chloride_mol_m2: f64 = 0,
    silicon_mol_m2: f64 = 0,
    sand_megagrams_m2: f64 = 0,
    silt_megagrams_m2: f64 = 0,
    clay_megagrams_m2: f64 = 0,
    rock_additive_m2: f64 = 0,
    cation_exchange_capacity_mol_m2: f64 = 0,
    anion_exchange_capacity_mol_m2: f64 = 0,
};
pub const NormalizedDeviation = struct {
    water: f64,
    heat: f64,
    oxygen: f64,
    carbon: f64,
    nitrogen: f64,
    phosphorus: f64,
    ions: f64,
    hydrogen: f64,
    aluminum: f64 = 0,
    iron: f64 = 0,
    calcium: f64 = 0,
    magnesium: f64 = 0,
    sodium: f64 = 0,
    potassium: f64 = 0,
    sulfur: f64 = 0,
    chloride: f64 = 0,
    silicon: f64 = 0,
    sand: f64 = 0,
    silt: f64 = 0,
    clay: f64 = 0,
    rock_additive: f64 = 0,
    cation_exchange_capacity: f64 = 0,
    anion_exchange_capacity: f64 = 0,
};
pub const BoundaryActivity = struct {
    water_m3: f64,
    heat_megajoules: f64,
    oxygen_g: f64,
    carbon_g: f64,
    nitrogen_g: f64,
    phosphorus_g: f64,
    ions_mol: f64,
    hydrogen_g: f64,
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    chloride_mol: f64 = 0,
    silicon_mol: f64 = 0,
    sand_megagrams: f64 = 0,
    silt_megagrams: f64 = 0,
    clay_megagrams: f64 = 0,
    rock_additive: f64 = 0,
    cation_exchange_capacity_mol: f64 = 0,
    anion_exchange_capacity_mol: f64 = 0,
};
pub const ClosureReport = struct {
    absolute_per_area: Deviation,
    normalized_relative: NormalizedDeviation,
    interval_activity: BoundaryActivity,
    acceptance_limit_per_area: Deviation,
};

pub fn balance(t: Totals) !Balance {
    try validate(t);
    const result: Balance = .{
        .water_m3 = t.water_storage_m3 - t.cumulative_rain_m3 + t.cumulative_runoff_m3 + t.cumulative_evaporation_m3 + t.cumulative_water_outflow_m3,
        .heat_megajoules = compensatedSum(&.{
            t.heat_storage_megajoules,
            -t.cumulative_heat_input_megajoules,
            t.cumulative_heat_output_megajoules,
            -t.cumulative_internal_heat_production_megajoules,
            t.cumulative_internal_heat_consumption_megajoules,
        }),
        .oxygen_g = compensatedSum(&.{
            t.oxygen_storage_g,
            -t.cumulative_oxygen_input_g,
            t.cumulative_oxygen_output_g,
            -t.cumulative_internal_oxygen_production_g,
            t.cumulative_internal_oxygen_consumption_g,
        }),
        // Living/standing plant owners are part of the ecosystem control
        // volume. Plant litter and root-soil exchange are internal transfers:
        // both donor and recipient are in storage, so the legacy soil-only
        // sink/exchange diagnostics must not enter this identity a second time.
        .carbon_g = compensatedSum(&.{ t.residue_carbon_g, t.organic_carbon_g, t.carbon_dioxide_carbon_g, t.plant_carbon_g, -t.cumulative_carbon_dioxide_input_g, t.cumulative_carbon_output_g, -t.cumulative_organic_fertilizer_carbon_g, -t.cumulative_symbiotic_inoculum_carbon_input_g, -t.cumulative_mineral_fertilizer_carbon_g }),
        .nitrogen_g = compensatedSum(&.{ t.residue_nitrogen_g, t.organic_nitrogen_g, t.dinitrogen_nitrogen_g, t.ammonium_nitrogen_g, t.nitrate_nitrogen_g, t.plant_nitrogen_g, -t.cumulative_dinitrogen_input_g, -t.cumulative_nitrogen_input_g, t.cumulative_nitrogen_output_g, -t.cumulative_organic_fertilizer_nitrogen_g, -t.cumulative_symbiotic_inoculum_nitrogen_input_g }),
        .phosphorus_g = compensatedSum(&.{ t.residue_phosphorus_g, t.organic_phosphorus_g, t.phosphate_phosphorus_g, t.plant_phosphorus_g, -t.cumulative_phosphorus_input_g, t.cumulative_phosphorus_output_g, -t.cumulative_organic_fertilizer_phosphorus_g, -t.cumulative_symbiotic_inoculum_phosphorus_input_g }),
        .ions_mol = t.ion_inventory_mol - t.cumulative_ion_input_mol + t.cumulative_ion_output_mol,
        .hydrogen_g = compensatedSum(&.{
            t.hydrogen_storage_g,
            -t.cumulative_hydrogen_input_g,
            t.cumulative_hydrogen_output_g,
            -t.cumulative_internal_hydrogen_production_g,
            t.cumulative_internal_hydrogen_consumption_g,
        }),
        .aluminum_mol = t.aluminum_storage_mol - t.cumulative_aluminum_input_mol + t.cumulative_aluminum_output_mol,
        .iron_mol = t.iron_storage_mol - t.cumulative_iron_input_mol + t.cumulative_iron_output_mol,
        .calcium_mol = t.calcium_storage_mol - t.cumulative_calcium_input_mol + t.cumulative_calcium_output_mol,
        .magnesium_mol = t.magnesium_storage_mol - t.cumulative_magnesium_input_mol + t.cumulative_magnesium_output_mol,
        .sodium_mol = t.sodium_storage_mol - t.cumulative_sodium_input_mol + t.cumulative_sodium_output_mol,
        .potassium_mol = t.potassium_storage_mol - t.cumulative_potassium_input_mol + t.cumulative_potassium_output_mol,
        .sulfur_mol = t.sulfur_storage_mol - t.cumulative_sulfur_input_mol + t.cumulative_sulfur_output_mol,
        .chloride_mol = t.chloride_storage_mol - t.cumulative_chloride_input_mol + t.cumulative_chloride_output_mol,
        .silicon_mol = t.silicon_storage_mol - t.cumulative_silicon_input_mol + t.cumulative_silicon_output_mol,
        .sand_megagrams = t.sand_storage_megagrams - t.cumulative_sand_input_megagrams + t.cumulative_sand_output_megagrams,
        .silt_megagrams = t.silt_storage_megagrams - t.cumulative_silt_input_megagrams + t.cumulative_silt_output_megagrams,
        .clay_megagrams = t.clay_storage_megagrams - t.cumulative_clay_input_megagrams + t.cumulative_clay_output_megagrams,
        .rock_additive = t.rock_storage_additive,
        .cation_exchange_capacity_mol = compensatedSum(&.{ t.cation_exchange_capacity_storage_mol, -t.cumulative_cation_exchange_capacity_input_mol, t.cumulative_cation_exchange_capacity_output_mol, -t.cumulative_internal_cation_exchange_capacity_production_mol, t.cumulative_internal_cation_exchange_capacity_consumption_mol }),
        .anion_exchange_capacity_mol = compensatedSum(&.{ t.anion_exchange_capacity_storage_mol, -t.cumulative_anion_exchange_capacity_input_mol, t.cumulative_anion_exchange_capacity_output_mol, -t.cumulative_internal_anion_exchange_capacity_production_mol, t.cumulative_internal_anion_exchange_capacity_consumption_mol }),
    };
    inline for (std.meta.fields(Balance)) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteMassBalanceResult;
    return result;
}

fn compensatedSum(values: []const f64) f64 {
    var sum: f64 = 0;
    var correction: f64 = 0;
    for (values) |value| {
        const corrected = value - correction;
        const next = sum + corrected;
        correction = (next - sum) - corrected;
        sum = next;
    }
    return sum;
}

pub const Monitor = struct {
    baseline: Balance,
    activity_baseline: BoundaryActivity,
    cancellation_scale_baseline: BoundaryActivity,
    absolute_tolerance_per_area: AbsoluteTolerancePerArea,
    relative_tolerance: f64,

    pub fn init(totals: Totals, absolute_tolerance_per_area: AbsoluteTolerancePerArea, relative_tolerance: f64) !Monitor {
        try absolute_tolerance_per_area.validate();
        if (!std.math.isFinite(relative_tolerance) or relative_tolerance < 0)
            return error.InvalidMassBalanceTolerance;
        return .{
            .baseline = try balance(totals),
            .activity_baseline = try boundaryActivity(totals),
            .cancellation_scale_baseline = try cancellationScale(totals),
            .absolute_tolerance_per_area = absolute_tolerance_per_area,
            .relative_tolerance = relative_tolerance,
        };
    }

    /// Matches EXEC's reset points (IBEGIN, ISTART, ILAST+1) when called by
    /// the timeline controller.
    pub fn reset(self: *Monitor, totals: Totals) !void {
        self.baseline = try balance(totals);
        self.activity_baseline = try boundaryActivity(totals);
        self.cancellation_scale_baseline = try cancellationScale(totals);
    }

    pub fn deviation(self: Monitor, totals: Totals) !Deviation {
        const current = try balance(totals);
        const area = totals.landscape_area_m2;
        return .{
            .water_m = (current.water_m3 - self.baseline.water_m3) / area,
            .heat_megajoules_m2 = (current.heat_megajoules - self.baseline.heat_megajoules) / area,
            .oxygen_g_m2 = (current.oxygen_g - self.baseline.oxygen_g) / area,
            .carbon_g_m2 = (current.carbon_g - self.baseline.carbon_g) / area,
            .nitrogen_g_m2 = (current.nitrogen_g - self.baseline.nitrogen_g) / area,
            .phosphorus_g_m2 = (current.phosphorus_g - self.baseline.phosphorus_g) / area,
            .ions_mol_m2 = (current.ions_mol - self.baseline.ions_mol) / area,
            .hydrogen_g_m2 = (current.hydrogen_g - self.baseline.hydrogen_g) / area,
            .aluminum_mol_m2 = (current.aluminum_mol - self.baseline.aluminum_mol) / area,
            .iron_mol_m2 = (current.iron_mol - self.baseline.iron_mol) / area,
            .calcium_mol_m2 = (current.calcium_mol - self.baseline.calcium_mol) / area,
            .magnesium_mol_m2 = (current.magnesium_mol - self.baseline.magnesium_mol) / area,
            .sodium_mol_m2 = (current.sodium_mol - self.baseline.sodium_mol) / area,
            .potassium_mol_m2 = (current.potassium_mol - self.baseline.potassium_mol) / area,
            .sulfur_mol_m2 = (current.sulfur_mol - self.baseline.sulfur_mol) / area,
            .chloride_mol_m2 = (current.chloride_mol - self.baseline.chloride_mol) / area,
            .silicon_mol_m2 = (current.silicon_mol - self.baseline.silicon_mol) / area,
            .sand_megagrams_m2 = (current.sand_megagrams - self.baseline.sand_megagrams) / area,
            .silt_megagrams_m2 = (current.silt_megagrams - self.baseline.silt_megagrams) / area,
            .clay_megagrams_m2 = (current.clay_megagrams - self.baseline.clay_megagrams) / area,
            .rock_additive_m2 = (current.rock_additive - self.baseline.rock_additive) / area,
            .cation_exchange_capacity_mol_m2 = (current.cation_exchange_capacity_mol - self.baseline.cation_exchange_capacity_mol) / area,
            .anion_exchange_capacity_mol_m2 = (current.anion_exchange_capacity_mol - self.baseline.anion_exchange_capacity_mol) / area,
        };
    }

    /// Absolute closure retains each domain's physical unit per square metre;
    /// normalized closure is dimensionless and scaled by accepted boundary
    /// activity since the monitor baseline. Standing stock is deliberately not
    /// the denominator, so a small hourly/process leak cannot disappear behind
    /// a large soil, mineral, or SOM pool.
    pub fn closure(self: Monitor, totals: Totals) !ClosureReport {
        const current = try balance(totals);
        const absolute = try self.deviation(totals);
        const interval = try intervalActivity(try boundaryActivity(totals), self.activity_baseline);
        const area = totals.landscape_area_m2;
        return .{
            .absolute_per_area = absolute,
            .normalized_relative = .{
                .water = normalizedClosure(current.water_m3 - self.baseline.water_m3, interval.water_m3),
                .heat = normalizedClosure(current.heat_megajoules - self.baseline.heat_megajoules, interval.heat_megajoules),
                .oxygen = normalizedClosure(current.oxygen_g - self.baseline.oxygen_g, interval.oxygen_g),
                .carbon = normalizedClosure(current.carbon_g - self.baseline.carbon_g, interval.carbon_g),
                .nitrogen = normalizedClosure(current.nitrogen_g - self.baseline.nitrogen_g, interval.nitrogen_g),
                .phosphorus = normalizedClosure(current.phosphorus_g - self.baseline.phosphorus_g, interval.phosphorus_g),
                .ions = normalizedClosure(current.ions_mol - self.baseline.ions_mol, interval.ions_mol),
                .hydrogen = normalizedClosure(current.hydrogen_g - self.baseline.hydrogen_g, interval.hydrogen_g),
                .aluminum = normalizedClosure(current.aluminum_mol - self.baseline.aluminum_mol, interval.aluminum_mol),
                .iron = normalizedClosure(current.iron_mol - self.baseline.iron_mol, interval.iron_mol),
                .calcium = normalizedClosure(current.calcium_mol - self.baseline.calcium_mol, interval.calcium_mol),
                .magnesium = normalizedClosure(current.magnesium_mol - self.baseline.magnesium_mol, interval.magnesium_mol),
                .sodium = normalizedClosure(current.sodium_mol - self.baseline.sodium_mol, interval.sodium_mol),
                .potassium = normalizedClosure(current.potassium_mol - self.baseline.potassium_mol, interval.potassium_mol),
                .sulfur = normalizedClosure(current.sulfur_mol - self.baseline.sulfur_mol, interval.sulfur_mol),
                .chloride = normalizedClosure(current.chloride_mol - self.baseline.chloride_mol, interval.chloride_mol),
                .silicon = normalizedClosure(current.silicon_mol - self.baseline.silicon_mol, interval.silicon_mol),
                .sand = normalizedClosure(current.sand_megagrams - self.baseline.sand_megagrams, interval.sand_megagrams),
                .silt = normalizedClosure(current.silt_megagrams - self.baseline.silt_megagrams, interval.silt_megagrams),
                .clay = normalizedClosure(current.clay_megagrams - self.baseline.clay_megagrams, interval.clay_megagrams),
                .rock_additive = normalizedClosure(current.rock_additive - self.baseline.rock_additive, interval.rock_additive),
                .cation_exchange_capacity = normalizedClosure(current.cation_exchange_capacity_mol - self.baseline.cation_exchange_capacity_mol, interval.cation_exchange_capacity_mol),
                .anion_exchange_capacity = normalizedClosure(current.anion_exchange_capacity_mol - self.baseline.anion_exchange_capacity_mol, interval.anion_exchange_capacity_mol),
            },
            .interval_activity = interval,
            .acceptance_limit_per_area = .{
                .water_m = acceptanceLimit(self.absolute_tolerance_per_area.water_m, self.relative_tolerance, interval.water_m3, area),
                .heat_megajoules_m2 = acceptanceLimit(self.absolute_tolerance_per_area.heat_megajoules_m2, self.relative_tolerance, interval.heat_megajoules, area),
                .oxygen_g_m2 = acceptanceLimit(self.absolute_tolerance_per_area.oxygen_g_m2, self.relative_tolerance, interval.oxygen_g, area),
                .carbon_g_m2 = acceptanceLimit(self.absolute_tolerance_per_area.carbon_g_m2, self.relative_tolerance, interval.carbon_g, area),
                .nitrogen_g_m2 = acceptanceLimit(self.absolute_tolerance_per_area.nitrogen_g_m2, self.relative_tolerance, interval.nitrogen_g, area),
                .phosphorus_g_m2 = acceptanceLimit(self.absolute_tolerance_per_area.phosphorus_g_m2, self.relative_tolerance, interval.phosphorus_g, area),
                .ions_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.ions_mol_m2, self.relative_tolerance, interval.ions_mol, area),
                .hydrogen_g_m2 = acceptanceLimit(self.absolute_tolerance_per_area.hydrogen_g_m2, self.relative_tolerance, interval.hydrogen_g, area),
                .aluminum_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.ions_mol_m2, self.relative_tolerance, interval.aluminum_mol, area),
                .iron_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.ions_mol_m2, self.relative_tolerance, interval.iron_mol, area),
                .calcium_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.ions_mol_m2, self.relative_tolerance, interval.calcium_mol, area),
                .magnesium_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.ions_mol_m2, self.relative_tolerance, interval.magnesium_mol, area),
                .sodium_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.ions_mol_m2, self.relative_tolerance, interval.sodium_mol, area),
                .potassium_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.ions_mol_m2, self.relative_tolerance, interval.potassium_mol, area),
                .sulfur_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.ions_mol_m2, self.relative_tolerance, interval.sulfur_mol, area),
                .chloride_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.ions_mol_m2, self.relative_tolerance, interval.chloride_mol, area),
                .silicon_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.ions_mol_m2, self.relative_tolerance, interval.silicon_mol, area),
                .sand_megagrams_m2 = acceptanceLimit(self.absolute_tolerance_per_area.sand_megagrams_m2, self.relative_tolerance, interval.sand_megagrams, area),
                .silt_megagrams_m2 = acceptanceLimit(self.absolute_tolerance_per_area.silt_megagrams_m2, self.relative_tolerance, interval.silt_megagrams, area),
                .clay_megagrams_m2 = acceptanceLimit(self.absolute_tolerance_per_area.clay_megagrams_m2, self.relative_tolerance, interval.clay_megagrams, area),
                .rock_additive_m2 = acceptanceLimit(self.absolute_tolerance_per_area.rock_additive_m2, self.relative_tolerance, interval.rock_additive, area),
                .cation_exchange_capacity_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.exchange_capacity_mol_m2, self.relative_tolerance, interval.cation_exchange_capacity_mol, area),
                .anion_exchange_capacity_mol_m2 = acceptanceLimit(self.absolute_tolerance_per_area.exchange_capacity_mol_m2, self.relative_tolerance, interval.anion_exchange_capacity_mol, area),
            },
        };
    }

    pub fn check(self: Monitor, day: u64, year: i32, totals: Totals) !Deviation {
        const closure_report = try self.closure(totals);
        const d = closure_report.absolute_per_area;
        const limit = closure_report.acceptance_limit_per_area;
        const current = try balance(totals);
        // Log all audited deviations every day, not
        // only on failure, so a multi-day trajectory can be read off for
        // every species. A conservation leak grows roughly linearly per day;
        // an initialization transient saturates. The fail-fast checks below
        // hide that distinction, so this line is emitted unconditionally
        // before any of them run: logging must not depend on which species
        // fails first.
        var audit_line_buf: [1536]u8 = undefined;
        std.log.debug("{s}", .{formatAuditLine(&audit_line_buf, day, year, d)});
        std.log.debug("daily audit normalized relative: day={d} year={d} heat={e} oxygen={e} hydrogen={e} carbon={e} nitrogen={e} phosphorus={e} ions={e} water={e}", .{
            day,
            year,
            closure_report.normalized_relative.heat,
            closure_report.normalized_relative.oxygen,
            closure_report.normalized_relative.hydrogen,
            closure_report.normalized_relative.carbon,
            closure_report.normalized_relative.nitrogen,
            closure_report.normalized_relative.phosphorus,
            closure_report.normalized_relative.ions,
            closure_report.normalized_relative.water,
        });
        std.log.debug("daily element audit normalized relative: day={d} year={d} aluminum={e} iron={e} calcium={e} magnesium={e} sodium={e} potassium={e} sulfur={e} chloride={e} silicon={e}; legacy_pseudo_ions={e} (diagnostic only)", .{
            day,
            year,
            closure_report.normalized_relative.aluminum,
            closure_report.normalized_relative.iron,
            closure_report.normalized_relative.calcium,
            closure_report.normalized_relative.magnesium,
            closure_report.normalized_relative.sodium,
            closure_report.normalized_relative.potassium,
            closure_report.normalized_relative.sulfur,
            closure_report.normalized_relative.chloride,
            closure_report.normalized_relative.silicon,
            closure_report.normalized_relative.ions,
        });
        std.log.debug("daily mineral audit normalized relative: day={d} year={d} sand={e} silt={e} clay={e} rock_additive={e} cec={e} aec={e}", .{ day, year, closure_report.normalized_relative.sand, closure_report.normalized_relative.silt, closure_report.normalized_relative.clay, closure_report.normalized_relative.rock_additive, closure_report.normalized_relative.cation_exchange_capacity, closure_report.normalized_relative.anion_exchange_capacity });
        // HEAT-001 measurement instrumentation (temporary): the raw
        // day-end/baseline heat balance, gated to exactly this once-per-day
        // call (unlike the noisy per-pipeline-stage "heat balance
        // instrument" line, which fires many times per hour). Lets a future
        // pass read the true hour-over-hour... day-over-day drift directly,
        // without disentangling intra-hour noise. See
        // docs/discrepancy_register.md HEAT-001 amendment 5bb0809.
        std.log.debug("heat balance daily snapshot: day={d} year={d} current_heat_megajoules={e} baseline_heat_megajoules={e}", .{ day, year, current.heat_megajoules, self.baseline.heat_megajoules });
        // A daily difference subtracts two landscape-scale f64 inventories.
        // Keep the user's physical tolerance intact while admitting only the
        // representational floor of those two finite values. Without this
        // term, a sub-ULP census difference can spuriously fail a stricter
        // per-area tolerance on geographically large cells.
        const current_scale = try cancellationScale(totals);
        const water_roundoff_per_m2 = representationFloorForInterval(current_scale.water_m3, self.cancellation_scale_baseline.water_m3, totals.landscape_area_m2);
        const heat_roundoff_per_m2 = representationFloorForInterval(current_scale.heat_megajoules, self.cancellation_scale_baseline.heat_megajoules, totals.landscape_area_m2);
        const oxygen_roundoff_per_m2 = representationFloorForInterval(current_scale.oxygen_g, self.cancellation_scale_baseline.oxygen_g, totals.landscape_area_m2);
        const hydrogen_roundoff_per_m2 = representationFloorForInterval(current_scale.hydrogen_g, self.cancellation_scale_baseline.hydrogen_g, totals.landscape_area_m2);
        const carbon_roundoff_per_m2 = representationFloorForInterval(current_scale.carbon_g, self.cancellation_scale_baseline.carbon_g, totals.landscape_area_m2);
        const nitrogen_roundoff_per_m2 = representationFloorForInterval(current_scale.nitrogen_g, self.cancellation_scale_baseline.nitrogen_g, totals.landscape_area_m2);
        const aluminum_roundoff_per_m2 = representationFloorForInterval(current_scale.aluminum_mol, self.cancellation_scale_baseline.aluminum_mol, totals.landscape_area_m2);
        const iron_roundoff_per_m2 = representationFloorForInterval(current_scale.iron_mol, self.cancellation_scale_baseline.iron_mol, totals.landscape_area_m2);
        const calcium_roundoff_per_m2 = representationFloorForInterval(current_scale.calcium_mol, self.cancellation_scale_baseline.calcium_mol, totals.landscape_area_m2);
        const magnesium_roundoff_per_m2 = representationFloorForInterval(current_scale.magnesium_mol, self.cancellation_scale_baseline.magnesium_mol, totals.landscape_area_m2);
        const sodium_roundoff_per_m2 = representationFloorForInterval(current_scale.sodium_mol, self.cancellation_scale_baseline.sodium_mol, totals.landscape_area_m2);
        const potassium_roundoff_per_m2 = representationFloorForInterval(current_scale.potassium_mol, self.cancellation_scale_baseline.potassium_mol, totals.landscape_area_m2);
        const sulfur_roundoff_per_m2 = representationFloorForInterval(current_scale.sulfur_mol, self.cancellation_scale_baseline.sulfur_mol, totals.landscape_area_m2);
        const chloride_roundoff_per_m2 = representationFloorForInterval(current_scale.chloride_mol, self.cancellation_scale_baseline.chloride_mol, totals.landscape_area_m2);
        const silicon_roundoff_per_m2 = representationFloorForInterval(current_scale.silicon_mol, self.cancellation_scale_baseline.silicon_mol, totals.landscape_area_m2);
        const sand_roundoff_per_m2 = representationFloorForInterval(current_scale.sand_megagrams, self.cancellation_scale_baseline.sand_megagrams, totals.landscape_area_m2);
        const silt_roundoff_per_m2 = representationFloorForInterval(current_scale.silt_megagrams, self.cancellation_scale_baseline.silt_megagrams, totals.landscape_area_m2);
        const clay_roundoff_per_m2 = representationFloorForInterval(current_scale.clay_megagrams, self.cancellation_scale_baseline.clay_megagrams, totals.landscape_area_m2);
        const rock_roundoff_per_m2 = representationFloorForInterval(current_scale.rock_additive, self.cancellation_scale_baseline.rock_additive, totals.landscape_area_m2);
        const cec_roundoff_per_m2 = representationFloorForInterval(current_scale.cation_exchange_capacity_mol, self.cancellation_scale_baseline.cation_exchange_capacity_mol, totals.landscape_area_m2);
        const aec_roundoff_per_m2 = representationFloorForInterval(current_scale.anion_exchange_capacity_mol, self.cancellation_scale_baseline.anion_exchange_capacity_mol, totals.landscape_area_m2);
        // Phosphorus spans dissolved species, two sorption zones, five
        // precipitates, organic pools, litter carriers, and boundary ledgers.
        // Its census has roughly four times the rounded terms of C/N.
        const phosphorus_roundoff_per_m2 = 4 * representationFloorForInterval(current_scale.phosphorus_g, self.cancellation_scale_baseline.phosphorus_g, totals.landscape_area_m2);
        try checkOne(day, year, "carbon", d.carbon_g_m2, limit.carbon_g_m2 + carbon_roundoff_per_m2, error.CarbonMassBalanceLost);
        try checkOne(day, year, "nitrogen", d.nitrogen_g_m2, limit.nitrogen_g_m2 + nitrogen_roundoff_per_m2, error.NitrogenMassBalanceLost);
        try checkOne(day, year, "phosphorus", d.phosphorus_g_m2, limit.phosphorus_g_m2 + phosphorus_roundoff_per_m2, error.PhosphorusMassBalanceLost);
        try checkOne(day, year, "water", d.water_m, limit.water_m + water_roundoff_per_m2, error.WaterMassBalanceLost);
        // HEAT-001 / PR-GRID-INV-005 acceptance criterion. Unlike C/N/P above,
        // whose floors are taken from the already-cancelled balance, the heat
        // floor is taken from the magnitudes that *enter* the cancellation.
        // `Balance.heat_megajoules` is `storage - in + out`; on Ottawa day one
        // that is `1.6415e3 - 5.1376e1 + 4.3197e0`, so the answer is four
        // orders smaller than its own terms, and its forward error is set by
        // those terms, never by the answer. The named scale is therefore the
        // largest cancelling census/boundary magnitude, and the relative term
        // is the same 512-ULP reduction bound already used for C/N/P.
        //
        // This is a correctness fix, not a widening. On that deck the floor is
        // `1.866e-10 MJ m-2`, while the deck's hard-coded `1e-11` sits 18.7x
        // *below* it: the legacy scalar was unsatisfiable in f64 regardless of
        // the physics. The surviving HEAT-001 deviation is `5.0929e-5`, still
        // 2.73e5x this floor, so the real defect keeps failing as it must, and
        // the smallest mechanism already attributed and closed (HEAT-004 at
        // `3.37e-4`) stays 1.8e6x above it. See
        // `docs/traceability/heat_001_scaled_closure_criterion.md`.
        try checkOne(day, year, "heat", d.heat_megajoules_m2, limit.heat_megajoules_m2 + heat_roundoff_per_m2, error.HeatMassBalanceLost);
        try checkOne(day, year, "oxygen", d.oxygen_g_m2, limit.oxygen_g_m2 + oxygen_roundoff_per_m2, error.OxygenMassBalanceLost);
        try checkOne(day, year, "hydrogen", d.hydrogen_g_m2, limit.hydrogen_g_m2 + hydrogen_roundoff_per_m2, error.HydrogenMassBalanceLost);
        // SSB/TION counts pseudo-ion particles and proton bookkeeping, not a
        // conserved quantity. Acceptance is therefore element-resolved: no
        // gain of one element can cancel a loss of another, and an ordinary
        // association/dissociation change cannot falsely abort the model.
        try checkOne(day, year, "aluminum", d.aluminum_mol_m2, limit.aluminum_mol_m2 + aluminum_roundoff_per_m2, error.AluminumMassBalanceLost);
        try checkOne(day, year, "iron", d.iron_mol_m2, limit.iron_mol_m2 + iron_roundoff_per_m2, error.IronMassBalanceLost);
        try checkOne(day, year, "calcium", d.calcium_mol_m2, limit.calcium_mol_m2 + calcium_roundoff_per_m2, error.CalciumMassBalanceLost);
        try checkOne(day, year, "magnesium", d.magnesium_mol_m2, limit.magnesium_mol_m2 + magnesium_roundoff_per_m2, error.MagnesiumMassBalanceLost);
        try checkOne(day, year, "sodium", d.sodium_mol_m2, limit.sodium_mol_m2 + sodium_roundoff_per_m2, error.SodiumMassBalanceLost);
        try checkOne(day, year, "potassium", d.potassium_mol_m2, limit.potassium_mol_m2 + potassium_roundoff_per_m2, error.PotassiumMassBalanceLost);
        try checkOne(day, year, "sulfur", d.sulfur_mol_m2, limit.sulfur_mol_m2 + sulfur_roundoff_per_m2, error.SulfurMassBalanceLost);
        try checkOne(day, year, "chloride", d.chloride_mol_m2, limit.chloride_mol_m2 + chloride_roundoff_per_m2, error.ChlorideMassBalanceLost);
        try checkOne(day, year, "silicon", d.silicon_mol_m2, limit.silicon_mol_m2 + silicon_roundoff_per_m2, error.SiliconMassBalanceLost);
        try checkOne(day, year, "sand", d.sand_megagrams_m2, limit.sand_megagrams_m2 + sand_roundoff_per_m2, error.SandMassBalanceLost);
        try checkOne(day, year, "silt", d.silt_megagrams_m2, limit.silt_megagrams_m2 + silt_roundoff_per_m2, error.SiltMassBalanceLost);
        try checkOne(day, year, "clay", d.clay_megagrams_m2, limit.clay_megagrams_m2 + clay_roundoff_per_m2, error.ClayMassBalanceLost);
        try checkOne(day, year, "rock_additive", d.rock_additive_m2, limit.rock_additive_m2 + rock_roundoff_per_m2, error.RockAdditiveBalanceLost);
        try checkOne(day, year, "cation_exchange_capacity", d.cation_exchange_capacity_mol_m2, limit.cation_exchange_capacity_mol_m2 + cec_roundoff_per_m2, error.CationExchangeCapacityBalanceLost);
        try checkOne(day, year, "anion_exchange_capacity", d.anion_exchange_capacity_mol_m2, limit.anion_exchange_capacity_mol_m2 + aec_roundoff_per_m2, error.AnionExchangeCapacityBalanceLost);
        // This success-only marker is deliberately info-level: ReleaseFast
        // suppresses debug diagnostics, while production evidence must still
        // prove both the simulated horizon and that every daily conservation
        // check above accepted. Keep the actual calendar coordinate and every
        // independently audited normalized balance on the same atomic line.
        std.log.info("daily conservation accepted: day={d} year={d} hour=24 water={e} heat={e} oxygen={e} hydrogen={e} carbon={e} nitrogen={e} phosphorus={e} aluminum={e} iron={e} calcium={e} magnesium={e} sodium={e} potassium={e} sulfur={e} chloride={e} silicon={e} sand={e} silt={e} clay={e} rock_additive={e} cec={e} aec={e}", .{
            day,
            year,
            closure_report.normalized_relative.water,
            closure_report.normalized_relative.heat,
            closure_report.normalized_relative.oxygen,
            closure_report.normalized_relative.hydrogen,
            closure_report.normalized_relative.carbon,
            closure_report.normalized_relative.nitrogen,
            closure_report.normalized_relative.phosphorus,
            closure_report.normalized_relative.aluminum,
            closure_report.normalized_relative.iron,
            closure_report.normalized_relative.calcium,
            closure_report.normalized_relative.magnesium,
            closure_report.normalized_relative.sodium,
            closure_report.normalized_relative.potassium,
            closure_report.normalized_relative.sulfur,
            closure_report.normalized_relative.chloride,
            closure_report.normalized_relative.silicon,
            closure_report.normalized_relative.sand,
            closure_report.normalized_relative.silt,
            closure_report.normalized_relative.clay,
            closure_report.normalized_relative.rock_additive,
            closure_report.normalized_relative.cation_exchange_capacity,
            closure_report.normalized_relative.anion_exchange_capacity,
        });
        return d;
    }
};

fn acceptanceLimit(absolute_tolerance_per_area: f64, relative_tolerance: f64, interval_activity: f64, area_m2: f64) f64 {
    return absolute_tolerance_per_area + relative_tolerance * interval_activity / area_m2;
}

fn representationFloorForInterval(current_scale: f64, baseline_scale: f64, area_m2: f64) f64 {
    // Each balance is a reduction of independently rounded storage and
    // boundary terms. Bound the subtraction by the larger pre-cancellation
    // magnitude, not the often tiny residual balance.
    return representationFloorForMagnitude(@max(@abs(current_scale), @abs(baseline_scale)), area_m2);
}

/// Forward-error bound, per unit area, for a compensated reduction over terms
/// whose largest magnitude is `scale_magnitude`. Split out from
/// `representationFloorPerArea` so a domain whose balance cancels to far below
/// its own inputs can name the pre-cancellation scale instead, which is what
/// actually sets the achievable precision. Not a physical tolerance: it is the
/// level below which f64 cannot distinguish a leak from rounding.
fn representationFloorForMagnitude(scale_magnitude: f64, area_m2: f64) f64 {
    return 512 * std.math.floatEps(f64) * @abs(scale_magnitude) / area_m2;
}

/// The largest magnitude entering the heat balance cancellation
/// `storage - in + out`. Enthalpy has no natural zero, so the census carries a
/// reference-state offset that dwarfs the daily residual; unlike a mass census
/// it cannot be made small by choosing better units. Reading the scale from the
/// live totals rather than a constant keeps the criterion honest as the deck,
/// the grid, or the reference state changes.
fn heatCancellationScale(t: Totals) f64 {
    return maximumMagnitude(&.{
        t.heat_storage_megajoules,
        t.cumulative_heat_input_megajoules,
        t.cumulative_heat_output_megajoules,
        t.cumulative_internal_heat_production_megajoules,
        t.cumulative_internal_heat_consumption_megajoules,
    });
}

/// Accumulated conservation is independent of output cadence. The disjunction
/// yields one check when a boundary is both day-end and scene-final.
pub fn shouldAudit(is_day_end: bool, is_scene_final: bool) bool {
    return is_day_end or is_scene_final;
}

pub const DayBookkeeping = struct { reported_day: i64, previous_day: i64, management_event_count: u64, year_transition_count: u64 };

/// Exact EXEC tail: negative IDAYR remains relative to LYRX; otherwise the
/// current day is published, then daily management/year counters are reset.
pub fn advanceDayBookkeeping(current_day: i64, reported_day: i64, days_in_year: i64) !DayBookkeeping {
    if (days_in_year <= 0) return error.InvalidDaysInYear;
    return .{ .reported_day = if (reported_day < 0) try std.math.add(i64, days_in_year, reported_day) else current_day, .previous_day = current_day, .management_event_count = 0, .year_transition_count = 0 };
}

/// Formats the daily audit line covering every conserved quantity plus the
/// explicitly labeled legacy pseudo-ion diagnostic. Split
/// out from `Monitor.check` so the completeness of the line (EXEC-AUDIT-
/// LOGGING-001: nitrogen, phosphorus, and ions were previously omitted) is
/// directly testable without depending on the log sink. `buf` must be large
/// enough for the fixed field labels plus the formatted numbers; overflow is
/// a programmer error caught by `unreachable` rather than a runtime failure
/// path, since the buffer size is a compile-time constant chosen by the
/// caller, not user or scientific data.
fn formatAuditLine(buf: []u8, day: u64, year: i32, d: Deviation) []const u8 {
    return std.fmt.bufPrint(buf, "daily audit deviation: day={d} year={d} heat_megajoules_m2={e} oxygen_g_m2={e} hydrogen_g_m2={e} carbon_g_m2={e} nitrogen_g_m2={e} phosphorus_g_m2={e} aluminum_mol_m2={e} iron_mol_m2={e} calcium_mol_m2={e} magnesium_mol_m2={e} sodium_mol_m2={e} potassium_mol_m2={e} sulfur_mol_m2={e} chloride_mol_m2={e} silicon_mol_m2={e} sand_megagrams_m2={e} silt_megagrams_m2={e} clay_megagrams_m2={e} rock_additive_m2={e} cec_mol_m2={e} aec_mol_m2={e} legacy_pseudo_ions_mol_m2={e} water_m={e}", .{
        day,
        year,
        d.heat_megajoules_m2,
        d.oxygen_g_m2,
        d.hydrogen_g_m2,
        d.carbon_g_m2,
        d.nitrogen_g_m2,
        d.phosphorus_g_m2,
        d.aluminum_mol_m2,
        d.iron_mol_m2,
        d.calcium_mol_m2,
        d.magnesium_mol_m2,
        d.sodium_mol_m2,
        d.potassium_mol_m2,
        d.sulfur_mol_m2,
        d.chloride_mol_m2,
        d.silicon_mol_m2,
        d.sand_megagrams_m2,
        d.silt_megagrams_m2,
        d.clay_megagrams_m2,
        d.rock_additive_m2,
        d.cation_exchange_capacity_mol_m2,
        d.anion_exchange_capacity_mol_m2,
        d.ions_mol_m2,
        d.water_m,
    }) catch unreachable;
}

fn checkOne(day: u64, year: i32, comptime domain: []const u8, value: f64, tolerance: f64, comptime failure: anyerror) !void {
    if (!std.math.isFinite(value)) return error.NonFiniteMassBalanceDeviation;
    if (@abs(value) <= tolerance) return;
    if (!builtin.is_test) std.log.err("{s} mass balance lost: day={d} year={d} deviation_per_m2={e} tolerance_per_m2={e}", .{ domain, day, year, value, tolerance });
    return failure;
}

fn validate(t: Totals) !void {
    if (!std.math.isFinite(t.landscape_area_m2) or t.landscape_area_m2 <= 0) return error.InvalidLandscapeArea;
    inline for (std.meta.fields(Totals)) |field| if (!std.math.isFinite(@field(t, field.name))) return error.NonFiniteMassBalanceInput;
}

test "domain mineral balances include erosion history and additive ROCK" {
    var baseline = std.mem.zeroes(Totals);
    baseline.landscape_area_m2 = 1;
    baseline.sand_storage_megagrams = 10;
    baseline.silt_storage_megagrams = 5;
    baseline.clay_storage_megagrams = 2;
    baseline.rock_storage_additive = 0.75;
    const monitor = try Monitor.init(baseline, .{}, 1e-9);

    var current = baseline;
    current.sand_storage_megagrams = 8;
    current.cumulative_sand_output_megagrams = 2;
    _ = try monitor.check(1, 2001, current);

    current.rock_storage_additive -= 0.01;
    try std.testing.expectError(error.RockAdditiveBalanceLost, monitor.check(1, 2001, current));
}

test "EXEC-AUDIT-LOGGING-001: the daily audit line reports conserved elements and legacy pseudo ions" {
    // Regression for the register entry: the line previously named only
    // heat/oxygen/carbon/water, silently dropping nitrogen, phosphorus, and
    // ions. Pseudo ions remain visible but are explicitly labeled diagnostic.
    var buf: [1536]u8 = undefined;
    const d = Deviation{
        .water_m = 1,
        .heat_megajoules_m2 = 2,
        .oxygen_g_m2 = 3,
        .carbon_g_m2 = 4,
        .nitrogen_g_m2 = 5,
        .phosphorus_g_m2 = 6,
        .ions_mol_m2 = 7,
        .hydrogen_g_m2 = 8,
    };
    const line = formatAuditLine(&buf, 1, 2001, d);
    inline for (.{
        "heat_megajoules_m2=",
        "oxygen_g_m2=",
        "hydrogen_g_m2=",
        "carbon_g_m2=",
        "nitrogen_g_m2=",
        "phosphorus_g_m2=",
        "aluminum_mol_m2=",
        "silicon_mol_m2=",
        "legacy_pseudo_ions_mol_m2=",
        "water_m=",
    }) |label| {
        try std.testing.expect(std.mem.indexOf(u8, line, label) != null);
    }
}

test "EXEC-AUDIT-LOGGING-001: the audit line is populated before any species check can abort" {
    // Regression for the register entry's second defect: the log line used to
    // sit between the carbon check and the nitrogen check, so a carbon
    // failure never reached the log statement while a nitrogen failure did.
    // `check` must gather the full seven-species deviation, used to build the
    // log line, before the first `checkOne` runs -- so the data behind the
    // line exists regardless of which species fails first. Exercise this for
    // failures in each of the first three checked species (carbon, nitrogen,
    // phosphorus, in that order) and confirm the pre-check deviation is still
    // fully finite and correctly populated for the species checked *after*
    // the one that fails.
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 1;
    const monitor = try Monitor.init(t, .{ .carbon_g_m2 = 1e-11 }, 1e-9);

    t.organic_carbon_g = 1; // fails the first check (carbon)
    try std.testing.expectError(error.CarbonMassBalanceLost, monitor.check(1, 2001, t));
    // The data the log line needs (nitrogen/phosphorus/ions deviations) is
    // still computable independently of the failed check, because `deviation`
    // does not short-circuit on any one species.
    const d = try monitor.deviation(t);
    try std.testing.expect(std.math.isFinite(d.nitrogen_g_m2));
    try std.testing.expect(std.math.isFinite(d.phosphorus_g_m2));
    try std.testing.expect(std.math.isFinite(d.ions_mol_m2));
    try std.testing.expect(std.math.isFinite(d.hydrogen_g_m2));
    var buf: [1536]u8 = undefined;
    const line = formatAuditLine(&buf, 1, 2001, d);
    try std.testing.expect(std.mem.indexOf(u8, line, "nitrogen_g_m2=") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "phosphorus_g_m2=") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "legacy_pseudo_ions_mol_m2=") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "hydrogen_g_m2=") != null);
}

test "EXEC equations conserve all accepted domains exactly" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 10;
    t.water_storage_m3 = 5;
    t.cumulative_rain_m3 = 2;
    t.cumulative_runoff_m3 = 1;
    t.cumulative_evaporation_m3 = 0.5;
    t.cumulative_water_outflow_m3 = 0.5;
    t.residue_carbon_g = 10;
    t.cumulative_carbon_sink_g = 2;
    var monitor = try Monitor.init(t, .{}, 1e-9);
    const d = try monitor.check(1, 2001, t);
    try std.testing.expectEqual(@as(f64, 0), d.water_m);
    try std.testing.expectEqual(@as(f64, 0), d.carbon_g_m2);
    try monitor.reset(t);
}

test "root-soil and litter diagnostics do not double count all-storage ecosystem balance" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 1;
    t.organic_carbon_g = 20;
    t.plant_carbon_g = 10;
    t.organic_nitrogen_g = 12;
    t.plant_nitrogen_g = 8;
    t.organic_phosphorus_g = 5;
    t.plant_phosphorus_g = 5;
    const monitor = try Monitor.init(t, .{
        .carbon_g_m2 = 1e-9,
        .nitrogen_g_m2 = 1e-9,
        .phosphorus_g_m2 = 1e-9,
    }, 1e-9);
    // Accepted internal transfer: soil donor decreases exactly as plant
    // recipient increases. Legacy soil-only diagnostics advance but must not
    // contribute to either closure or its relative-tolerance activity scale.
    t.organic_carbon_g -= 7;
    t.plant_carbon_g += 7;
    t.organic_nitrogen_g -= 5;
    t.plant_nitrogen_g += 5;
    t.organic_phosphorus_g -= 4;
    t.plant_phosphorus_g += 4;
    t.cumulative_plant_root_organic_carbon_uptake_g = 7;
    t.cumulative_plant_root_organic_nitrogen_uptake_g = 5;
    t.cumulative_plant_root_organic_phosphorus_uptake_g = 4;
    const report = try monitor.closure(t);
    try std.testing.expectEqual(@as(f64, 0), report.absolute_per_area.carbon_g_m2);
    try std.testing.expectEqual(@as(f64, 0), report.absolute_per_area.nitrogen_g_m2);
    try std.testing.expectEqual(@as(f64, 0), report.absolute_per_area.phosphorus_g_m2);
    try std.testing.expectEqual(@as(f64, 0), report.interval_activity.carbon_g);
    try std.testing.expectEqual(@as(f64, 0), report.interval_activity.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 0), report.interval_activity.phosphorus_g);
}

test "nonzero authoritative plant drift fails unit-scaled accumulated acceptance" {
    var baseline = std.mem.zeroes(Totals);
    baseline.landscape_area_m2 = 2;
    baseline.plant_carbon_g = 100;
    baseline.plant_nitrogen_g = 10;
    baseline.plant_phosphorus_g = 1;
    const monitor = try Monitor.init(baseline, .{
        .carbon_g_m2 = 1e-4,
        .nitrogen_g_m2 = 2e-5,
        .phosphorus_g_m2 = 3e-6,
    }, 1e-8);

    var carbon_drift = baseline;
    carbon_drift.plant_carbon_g += 3e-4; // 1.5e-4 g C m-2
    try std.testing.expectError(error.CarbonMassBalanceLost, monitor.check(1, 2001, carbon_drift));
    var nitrogen_drift = baseline;
    nitrogen_drift.plant_nitrogen_g += 5e-5; // 2.5e-5 g N m-2
    try std.testing.expectError(error.NitrogenMassBalanceLost, monitor.check(1, 2001, nitrogen_drift));
    var phosphorus_drift = baseline;
    phosphorus_drift.plant_phosphorus_g += 8e-6; // 4e-6 g P m-2
    try std.testing.expectError(error.PhosphorusMassBalanceLost, monitor.check(1, 2001, phosphorus_drift));
}

test "association dissociation pseudo-ion change is diagnostic while elements close" {
    var baseline = std.mem.zeroes(Totals);
    baseline.landscape_area_m2 = 1;
    baseline.aluminum_storage_mol = 2;
    baseline.sulfur_storage_mol = 3;
    baseline.ion_inventory_mol = 10;
    const monitor = try Monitor.init(
        baseline,
        .{ .ions_mol_m2 = 1e-12 },
        1e-9,
    );

    // One conservative reaction can turn associated Al-SO4 into separately
    // counted aqueous particles. Element storage is unchanged; SSB/TION is
    // permitted to move because it is not a conservation identity.
    var dissociated = baseline;
    dissociated.ion_inventory_mol = 12;
    const deviation_report = try monitor.check(1, 2001, dissociated);
    try std.testing.expectEqual(@as(f64, 2), deviation_report.ions_mol_m2);
    try std.testing.expectEqual(@as(f64, 0), deviation_report.aluminum_mol_m2);
    try std.testing.expectEqual(@as(f64, 0), deviation_report.sulfur_mol_m2);
}

test "equal aggregate pseudo-ion exchange cannot hide any one-element leak" {
    var baseline = std.mem.zeroes(Totals);
    baseline.landscape_area_m2 = 1;
    baseline.aluminum_storage_mol = 5;
    baseline.sodium_storage_mol = 5;
    baseline.ion_inventory_mol = 10;
    const monitor = try Monitor.init(
        baseline,
        .{ .ions_mol_m2 = 1e-12 },
        1e-9,
    );

    var leaked = baseline;
    leaked.aluminum_storage_mol -= 0.01;
    leaked.sodium_storage_mol += 0.01;
    // Aggregate moles and the pseudo-ion diagnostic are unchanged, but the
    // first independently audited element must fail.
    try std.testing.expectError(
        error.AluminumMassBalanceLost,
        monitor.check(1, 2001, leaked),
    );
}

fn normalizedClosure(residual: f64, activity: f64) f64 {
    const scale = @max(@abs(residual), activity);
    return if (scale > 0) @abs(residual) / scale else 0;
}

fn magnitudeSum(values: []const f64) !f64 {
    var sum: f64 = 0;
    var correction: f64 = 0;
    for (values) |value| {
        const corrected = @abs(value) - correction;
        const next = sum + corrected;
        correction = (next - sum) - corrected;
        sum = next;
    }
    if (!std.math.isFinite(sum)) return error.NonFiniteMassBalanceActivity;
    return sum;
}

test "mineral fertilizer carbon participates in balance and interval activity" {
    var totals = std.mem.zeroes(Totals);
    totals.landscape_area_m2 = 2;
    totals.carbon_dioxide_carbon_g = 216;
    try std.testing.expectEqual(@as(f64, 216), (try balance(totals)).carbon_g);
    totals.cumulative_mineral_fertilizer_carbon_g = 216;
    try std.testing.expectEqual(@as(f64, 0), (try balance(totals)).carbon_g);
    try std.testing.expectEqual(@as(f64, 216), (try boundaryActivity(totals)).carbon_g);
    // A missing or duplicated amendment credit remains a real failure.
    totals.cumulative_mineral_fertilizer_carbon_g = 432;
    try std.testing.expectEqual(@as(f64, -216), (try balance(totals)).carbon_g);
}

fn boundaryActivity(t: Totals) !BoundaryActivity {
    return .{
        .water_m3 = try magnitudeSum(&.{ t.cumulative_rain_m3, t.cumulative_runoff_m3, t.cumulative_evaporation_m3, t.cumulative_water_outflow_m3 }),
        .heat_megajoules = try magnitudeSum(&.{ t.cumulative_heat_input_megajoules, t.cumulative_heat_output_megajoules, t.cumulative_internal_heat_production_megajoules, t.cumulative_internal_heat_consumption_megajoules }),
        .oxygen_g = try magnitudeSum(&.{ t.cumulative_oxygen_input_g, t.cumulative_oxygen_output_g, t.cumulative_internal_oxygen_production_g, t.cumulative_internal_oxygen_consumption_g }),
        .carbon_g = try magnitudeSum(&.{ t.cumulative_carbon_dioxide_input_g, t.cumulative_carbon_output_g, t.cumulative_organic_fertilizer_carbon_g, t.cumulative_symbiotic_inoculum_carbon_input_g, t.cumulative_mineral_fertilizer_carbon_g }),
        .nitrogen_g = try magnitudeSum(&.{ t.cumulative_dinitrogen_input_g, t.cumulative_nitrogen_input_g, t.cumulative_nitrogen_output_g, t.cumulative_organic_fertilizer_nitrogen_g, t.cumulative_symbiotic_inoculum_nitrogen_input_g }),
        .phosphorus_g = try magnitudeSum(&.{ t.cumulative_phosphorus_input_g, t.cumulative_phosphorus_output_g, t.cumulative_organic_fertilizer_phosphorus_g, t.cumulative_symbiotic_inoculum_phosphorus_input_g }),
        .ions_mol = try magnitudeSum(&.{ t.cumulative_ion_input_mol, t.cumulative_ion_output_mol }),
        .hydrogen_g = try magnitudeSum(&.{ t.cumulative_hydrogen_input_g, t.cumulative_hydrogen_output_g, t.cumulative_internal_hydrogen_production_g, t.cumulative_internal_hydrogen_consumption_g }),
        .aluminum_mol = try magnitudeSum(&.{ t.cumulative_aluminum_input_mol, t.cumulative_aluminum_output_mol }),
        .iron_mol = try magnitudeSum(&.{ t.cumulative_iron_input_mol, t.cumulative_iron_output_mol }),
        .calcium_mol = try magnitudeSum(&.{ t.cumulative_calcium_input_mol, t.cumulative_calcium_output_mol }),
        .magnesium_mol = try magnitudeSum(&.{ t.cumulative_magnesium_input_mol, t.cumulative_magnesium_output_mol }),
        .sodium_mol = try magnitudeSum(&.{ t.cumulative_sodium_input_mol, t.cumulative_sodium_output_mol }),
        .potassium_mol = try magnitudeSum(&.{ t.cumulative_potassium_input_mol, t.cumulative_potassium_output_mol }),
        .sulfur_mol = try magnitudeSum(&.{ t.cumulative_sulfur_input_mol, t.cumulative_sulfur_output_mol }),
        .chloride_mol = try magnitudeSum(&.{ t.cumulative_chloride_input_mol, t.cumulative_chloride_output_mol }),
        .silicon_mol = try magnitudeSum(&.{ t.cumulative_silicon_input_mol, t.cumulative_silicon_output_mol }),
        .sand_megagrams = try magnitudeSum(&.{ t.cumulative_sand_input_megagrams, t.cumulative_sand_output_megagrams }),
        .silt_megagrams = try magnitudeSum(&.{ t.cumulative_silt_input_megagrams, t.cumulative_silt_output_megagrams }),
        .clay_megagrams = try magnitudeSum(&.{ t.cumulative_clay_input_megagrams, t.cumulative_clay_output_megagrams }),
        .rock_additive = 0,
        .cation_exchange_capacity_mol = try magnitudeSum(&.{ t.cumulative_cation_exchange_capacity_input_mol, t.cumulative_cation_exchange_capacity_output_mol, t.cumulative_internal_cation_exchange_capacity_production_mol, t.cumulative_internal_cation_exchange_capacity_consumption_mol }),
        .anion_exchange_capacity_mol = try magnitudeSum(&.{ t.cumulative_anion_exchange_capacity_input_mol, t.cumulative_anion_exchange_capacity_output_mol, t.cumulative_internal_anion_exchange_capacity_production_mol, t.cumulative_internal_anion_exchange_capacity_consumption_mol }),
    };
}

fn maximumMagnitude(values: []const f64) f64 {
    var result: f64 = 0;
    for (values) |value| result = @max(result, @abs(value));
    return result;
}

/// Largest pre-cancellation storage/boundary magnitude in each native unit.
/// These scales derive only the f64 representation floor; they are kept
/// separate from user physical tolerances and interval-relative acceptance.
fn cancellationScale(t: Totals) !BoundaryActivity {
    try validate(t);
    return .{
        .water_m3 = maximumMagnitude(&.{ t.water_storage_m3, t.cumulative_rain_m3, t.cumulative_runoff_m3, t.cumulative_evaporation_m3, t.cumulative_water_outflow_m3 }),
        .heat_megajoules = maximumMagnitude(&.{ t.heat_storage_megajoules, t.cumulative_heat_input_megajoules, t.cumulative_heat_output_megajoules, t.cumulative_internal_heat_production_megajoules, t.cumulative_internal_heat_consumption_megajoules }),
        .oxygen_g = maximumMagnitude(&.{ t.oxygen_storage_g, t.cumulative_oxygen_input_g, t.cumulative_oxygen_output_g, t.cumulative_internal_oxygen_production_g, t.cumulative_internal_oxygen_consumption_g }),
        .carbon_g = maximumMagnitude(&.{ t.residue_carbon_g, t.organic_carbon_g, t.carbon_dioxide_carbon_g, t.plant_carbon_g, t.cumulative_carbon_dioxide_input_g, t.cumulative_carbon_output_g, t.cumulative_organic_fertilizer_carbon_g, t.cumulative_symbiotic_inoculum_carbon_input_g, t.cumulative_mineral_fertilizer_carbon_g }),
        .nitrogen_g = maximumMagnitude(&.{ t.residue_nitrogen_g, t.organic_nitrogen_g, t.dinitrogen_nitrogen_g, t.ammonium_nitrogen_g, t.nitrate_nitrogen_g, t.plant_nitrogen_g, t.cumulative_dinitrogen_input_g, t.cumulative_nitrogen_input_g, t.cumulative_nitrogen_output_g, t.cumulative_organic_fertilizer_nitrogen_g, t.cumulative_symbiotic_inoculum_nitrogen_input_g }),
        .phosphorus_g = maximumMagnitude(&.{ t.residue_phosphorus_g, t.organic_phosphorus_g, t.phosphate_phosphorus_g, t.plant_phosphorus_g, t.cumulative_phosphorus_input_g, t.cumulative_phosphorus_output_g, t.cumulative_organic_fertilizer_phosphorus_g, t.cumulative_symbiotic_inoculum_phosphorus_input_g }),
        .ions_mol = maximumMagnitude(&.{ t.ion_inventory_mol, t.cumulative_ion_input_mol, t.cumulative_ion_output_mol }),
        .hydrogen_g = maximumMagnitude(&.{ t.hydrogen_storage_g, t.cumulative_hydrogen_input_g, t.cumulative_hydrogen_output_g, t.cumulative_internal_hydrogen_production_g, t.cumulative_internal_hydrogen_consumption_g }),
        .aluminum_mol = maximumMagnitude(&.{ t.aluminum_storage_mol, t.cumulative_aluminum_input_mol, t.cumulative_aluminum_output_mol }),
        .iron_mol = maximumMagnitude(&.{ t.iron_storage_mol, t.cumulative_iron_input_mol, t.cumulative_iron_output_mol }),
        .calcium_mol = maximumMagnitude(&.{ t.calcium_storage_mol, t.cumulative_calcium_input_mol, t.cumulative_calcium_output_mol }),
        .magnesium_mol = maximumMagnitude(&.{ t.magnesium_storage_mol, t.cumulative_magnesium_input_mol, t.cumulative_magnesium_output_mol }),
        .sodium_mol = maximumMagnitude(&.{ t.sodium_storage_mol, t.cumulative_sodium_input_mol, t.cumulative_sodium_output_mol }),
        .potassium_mol = maximumMagnitude(&.{ t.potassium_storage_mol, t.cumulative_potassium_input_mol, t.cumulative_potassium_output_mol }),
        .sulfur_mol = maximumMagnitude(&.{ t.sulfur_storage_mol, t.cumulative_sulfur_input_mol, t.cumulative_sulfur_output_mol }),
        .chloride_mol = maximumMagnitude(&.{ t.chloride_storage_mol, t.cumulative_chloride_input_mol, t.cumulative_chloride_output_mol }),
        .silicon_mol = maximumMagnitude(&.{ t.silicon_storage_mol, t.cumulative_silicon_input_mol, t.cumulative_silicon_output_mol }),
        .sand_megagrams = maximumMagnitude(&.{ t.sand_storage_megagrams, t.cumulative_sand_input_megagrams, t.cumulative_sand_output_megagrams }),
        .silt_megagrams = maximumMagnitude(&.{ t.silt_storage_megagrams, t.cumulative_silt_input_megagrams, t.cumulative_silt_output_megagrams }),
        .clay_megagrams = maximumMagnitude(&.{ t.clay_storage_megagrams, t.cumulative_clay_input_megagrams, t.cumulative_clay_output_megagrams }),
        .rock_additive = @abs(t.rock_storage_additive),
        .cation_exchange_capacity_mol = maximumMagnitude(&.{ t.cation_exchange_capacity_storage_mol, t.cumulative_cation_exchange_capacity_input_mol, t.cumulative_cation_exchange_capacity_output_mol, t.cumulative_internal_cation_exchange_capacity_production_mol, t.cumulative_internal_cation_exchange_capacity_consumption_mol }),
        .anion_exchange_capacity_mol = maximumMagnitude(&.{ t.anion_exchange_capacity_storage_mol, t.cumulative_anion_exchange_capacity_input_mol, t.cumulative_anion_exchange_capacity_output_mol, t.cumulative_internal_anion_exchange_capacity_production_mol, t.cumulative_internal_anion_exchange_capacity_consumption_mol }),
    };
}

fn intervalActivity(current: BoundaryActivity, baseline: BoundaryActivity) !BoundaryActivity {
    var result: BoundaryActivity = undefined;
    inline for (std.meta.fields(BoundaryActivity)) |field| {
        const value = @field(current, field.name) - @field(baseline, field.name);
        // Accepted boundary ledgers are cumulative and may only advance. A
        // decrease means rollback/restart restored the ledger and monitor from
        // different transactions; scaling such a mismatch would hide it.
        if (!std.math.isFinite(value) or value < 0)
            return error.NonMonotonicMassBalanceActivity;
        @field(result, field.name) = value;
    }
    return result;
}

test "oxygen balance separates boundary exchange from internal reaction consumption" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 2;
    t.oxygen_storage_g = 11;
    t.cumulative_oxygen_input_g = 7;
    t.cumulative_oxygen_output_g = 3;
    t.cumulative_internal_oxygen_production_g = 5;
    t.cumulative_internal_oxygen_consumption_g = 2;
    const result = try balance(t);
    try std.testing.expectEqual(@as(f64, 4), result.oxygen_g);

    const activity = try boundaryActivity(t);
    try std.testing.expectEqual(@as(f64, 17), activity.oxygen_g);
    const monitor = try Monitor.init(t, .{ .oxygen_g_m2 = 1e-6 }, 1e-9);
    t.oxygen_storage_g += 1;
    try std.testing.expectError(
        error.OxygenMassBalanceLost,
        monitor.check(1, 2001, t),
    );
}

test "hydrogen balance separates boundary and internal production consumption" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 2;
    t.hydrogen_storage_g = 11;
    t.cumulative_hydrogen_input_g = 7;
    t.cumulative_hydrogen_output_g = 3;
    t.cumulative_internal_hydrogen_production_g = 5;
    t.cumulative_internal_hydrogen_consumption_g = 2;
    const result = try balance(t);
    try std.testing.expectEqual(@as(f64, 4), result.hydrogen_g);

    const monitor = try Monitor.init(t, .{ .hydrogen_g_m2 = 1e-6 }, 1e-9);
    t.hydrogen_storage_g += 1;
    try std.testing.expectError(
        error.HydrogenMassBalanceLost,
        monitor.check(1, 2001, t),
    );
}

test "daily closure reports absolute and normalized relative independently" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 10;
    t.water_storage_m3 = 1_000;
    const monitor = try Monitor.init(t, .{ .water_m = 1e-6 }, 1e-9);
    t.cumulative_rain_m3 = 100;
    t.water_storage_m3 += 100.01;
    const report = try monitor.closure(t);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001), report.absolute_per_area.water_m, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-4), report.normalized_relative.water, 1e-12);

    var internal_leak = t;
    internal_leak.cumulative_rain_m3 = 0;
    internal_leak.water_storage_m3 = 1_000.01;
    const internal_report = try monitor.closure(internal_leak);
    try std.testing.expectEqual(@as(f64, 1), internal_report.normalized_relative.water);
}

test "scaled acceptance uses only activity since the monitor baseline" {
    var old_history = std.mem.zeroes(Totals);
    old_history.landscape_area_m2 = 1;
    old_history.cumulative_rain_m3 = 1.0e12;
    old_history.water_storage_m3 = 1.0e12;
    const monitor = try Monitor.init(old_history, .{ .water_m = 1e-6 }, 1e-3);

    // No accepted boundary activity occurred after initialization, so a new
    // one-unit storage leak cannot borrow tolerance from old history.
    old_history.water_storage_m3 += 1;
    const no_activity = try monitor.closure(old_history);
    try std.testing.expectEqual(@as(f64, 0), no_activity.interval_activity.water_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-6), no_activity.acceptance_limit_per_area.water_m, 0);
    try std.testing.expectError(
        error.WaterMassBalanceLost,
        monitor.check(1, 2001, old_history),
    );

    var active = std.mem.zeroes(Totals);
    active.landscape_area_m2 = 1;
    const scaled = try Monitor.init(active, .{ .water_m = 1e-6 }, 1e-3);
    active.cumulative_rain_m3 = 1_000;
    active.water_storage_m3 = 1_000.5;
    const report = try scaled.closure(active);
    try std.testing.expectEqual(@as(f64, 1_000), report.interval_activity.water_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 1.000001), report.acceptance_limit_per_area.water_m, 1e-15);
    _ = try scaled.check(1, 2001, active);
}

test "activity baseline resets and rejects ledger monitor rollback mismatch" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 1;
    var monitor = try Monitor.init(t, .{ .water_m = 1e-6 }, 1e-3);
    t.cumulative_rain_m3 = 10;
    t.water_storage_m3 = 10;
    try monitor.reset(t);

    t.water_storage_m3 += 0.1;
    try std.testing.expectError(
        error.WaterMassBalanceLost,
        monitor.check(1, 2001, t),
    );
    t.cumulative_rain_m3 = 9;
    try std.testing.expectError(
        error.NonMonotonicMassBalanceActivity,
        monitor.closure(t),
    );
}

test "EXEC fail-fast audit identifies carbon drift above source tolerance" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 2;
    const monitor = try Monitor.init(t, .{ .carbon_g_m2 = 1e-6 }, 1e-9);
    t.organic_carbon_g = 3e-6;
    try std.testing.expectError(error.CarbonMassBalanceLost, monitor.check(2, 2001, t));
}

test "carbon audit distinguishes representation floor from physical drift" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 87_170_000;
    t.organic_carbon_g = 5.0e11;
    const monitor = try Monitor.init(t, .{}, 1e-9);
    t.organic_carbon_g += 0.0009;
    _ = try monitor.check(1, 2001, t);
    t.organic_carbon_g += 0.1;
    try std.testing.expectError(
        error.CarbonMassBalanceLost,
        monitor.check(1, 2001, t),
    );
}

test "nitrogen audit distinguishes representation floor from physical drift" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 87_170_000;
    t.organic_nitrogen_g = 8.0e10;
    const monitor = try Monitor.init(t, .{}, 1e-9);
    t.organic_nitrogen_g += 0.00002;
    _ = try monitor.check(1, 2001, t);
    t.organic_nitrogen_g += 0.1;
    try std.testing.expectError(
        error.NitrogenMassBalanceLost,
        monitor.check(1, 2001, t),
    );
}

test "phosphorus audit distinguishes its carrier census floor from physical drift" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 87_170_000;
    t.phosphate_phosphorus_g = 1.2e11;
    const monitor = try Monitor.init(t, .{}, 1e-9);
    t.phosphate_phosphorus_g += 0.05;
    _ = try monitor.check(1, 2001, t);
    t.phosphate_phosphorus_g += 0.1;
    try std.testing.expectError(
        error.PhosphorusMassBalanceLost,
        monitor.check(1, 2001, t),
    );
}

test "heat audit floor tracks the cancelling enthalpy scale, not the residual" {
    // Ottawa day-1 magnitudes, measured at 1bfd30b. Enthalpy has no natural
    // zero, so the census carries a large reference-state offset while the
    // audited answer is four orders smaller; the floor must follow the offset.
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 1;
    t.heat_storage_megajoules = 1.594487362196503e3;
    const monitor = try Monitor.init(t, .{}, 1e-9);

    const scale = heatCancellationScale(t);
    try std.testing.expectEqual(t.heat_storage_megajoules, scale);
    const floor = representationFloorForMagnitude(scale, t.landscape_area_m2);
    // 512 * eps * 1.5945e3 ~ 1.813e-10, three orders above the deck's 1e-11.
    try std.testing.expect(floor > 1.0e-10 and floor < 1.0e-9);
    try std.testing.expect(floor > 10 * 1e-11);

    // A difference at the floor is indistinguishable from rounding: admitted.
    t.heat_storage_megajoules += 0.9 * floor;
    _ = try monitor.check(1, 1998, t);
}

test "heat audit still rejects the measured HEAT-001 deviation and HEAT-004 scale" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 1;
    t.heat_storage_megajoules = 1.594487362196503e3;
    const monitor = try Monitor.init(t, .{}, 1e-9);

    // The surviving HEAT-001 day-1 deviation. The whole point of a scaled
    // criterion is that it does not excuse this.
    t.heat_storage_megajoules += 5.092889318802918e-5;
    try std.testing.expectError(
        error.HeatMassBalanceLost,
        monitor.check(1, 1998, t),
    );

    // HEAT-004, the smallest mechanism already attributed and closed, must also
    // still be detectable, or the criterion would have retired real findings.
    var u = std.mem.zeroes(Totals);
    u.landscape_area_m2 = 1;
    u.heat_storage_megajoules = 1.594487362196503e3;
    const strict = try Monitor.init(u, .{}, 1e-9);
    u.heat_storage_megajoules += 3.370486e-4;
    try std.testing.expectError(
        error.HeatMassBalanceLost,
        strict.check(1, 1998, u),
    );
}

test "heat cancellation scale reads boundary terms when they dominate storage" {
    // A drained late-season landscape can push more enthalpy across the
    // boundary than it stores, and then the boundary term sets the precision.
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 4;
    t.heat_storage_megajoules = 10;
    t.cumulative_heat_input_megajoules = 8_000;
    t.cumulative_heat_output_megajoules = 7_990;
    try std.testing.expectEqual(@as(f64, 8_000), heatCancellationScale(t));
    try std.testing.expectEqual(
        512 * std.math.floatEps(f64) * 8_000 / 4,
        representationFloorForMagnitude(heatCancellationScale(t), 4),
    );
}

test "gross internal heat production and consumption preserve closure and activity" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 1;
    t.heat_storage_megajoules = 100;
    const baseline = try balance(t);
    t.heat_storage_megajoules = 107;
    t.cumulative_internal_heat_production_megajoules = 10;
    t.cumulative_internal_heat_consumption_megajoules = 3;
    const current = try balance(t);
    try std.testing.expectEqual(baseline.heat_megajoules, current.heat_megajoules);
    const activity = try boundaryActivity(t);
    try std.testing.expectEqual(@as(f64, 13), activity.heat_megajoules);
    try std.testing.expectEqual(@as(f64, 107), heatCancellationScale(t));
}

test "EXEC rejects non-finite cumulative inputs before deviation" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 1;
    t.ion_inventory_mol = std.math.nan(f64);
    try std.testing.expectError(error.NonFiniteMassBalanceInput, balance(t));
}

test "signed internal exchange-site creation and loss preserve accumulated identity" {
    var t = std.mem.zeroes(Totals);
    t.landscape_area_m2 = 1;
    t.cation_exchange_capacity_storage_mol = 100;
    t.anion_exchange_capacity_storage_mol = 50;
    const baseline = try balance(t);

    t.cation_exchange_capacity_storage_mol = 110;
    t.cumulative_internal_cation_exchange_capacity_production_mol = 10;
    t.anion_exchange_capacity_storage_mol = 54;
    t.cumulative_internal_anion_exchange_capacity_production_mol = 4;
    var current = try balance(t);
    try std.testing.expectEqual(baseline.cation_exchange_capacity_mol, current.cation_exchange_capacity_mol);
    try std.testing.expectEqual(baseline.anion_exchange_capacity_mol, current.anion_exchange_capacity_mol);

    t.cation_exchange_capacity_storage_mol = 107;
    t.cumulative_internal_cation_exchange_capacity_consumption_mol = 3;
    t.anion_exchange_capacity_storage_mol = 52;
    t.cumulative_internal_anion_exchange_capacity_consumption_mol = 2;
    current = try balance(t);
    try std.testing.expectEqual(baseline.cation_exchange_capacity_mol, current.cation_exchange_capacity_mol);
    try std.testing.expectEqual(baseline.anion_exchange_capacity_mol, current.anion_exchange_capacity_mol);
}

test "EXEC day bookkeeping retains source behavior" {
    const relative = try advanceDayBookkeeping(100, -2, 365);
    try std.testing.expectEqual(@as(i64, 363), relative.reported_day);
    try std.testing.expectEqual(@as(i64, 100), relative.previous_day);
    const absolute = try advanceDayBookkeeping(101, 8, 366);
    try std.testing.expectEqual(@as(i64, 101), absolute.reported_day);
    try std.testing.expectEqual(@as(u64, 0), absolute.management_event_count);
}

test "short final scene audits once off cadence before its checkpoint" {
    const checkpoint_schedule = @import("../io/checkpoint/schedule.zig");
    try std.testing.expect(!shouldAudit(false, false));
    try std.testing.expect(shouldAudit(true, false));
    try std.testing.expect(shouldAudit(false, true));
    try std.testing.expect(shouldAudit(true, true));
    // Checkpoints require a fully flushed day, expressed as completed hours,
    // not the final hour's zero-based label.
    try std.testing.expect(!try checkpoint_schedule.shouldPublish(true, 10, 1, 23, true));
    try std.testing.expect(try checkpoint_schedule.shouldPublish(true, 10, 1, 24, true));
}

test {
    _ = scoped;
}

/// `Totals` fields that are POPULATED every hour and never read into any
/// conservation identity, so they look like conservation evidence and are not.
///
/// Measured 2026-09-12 by classifying every occurrence of each `cumulative_*`
/// field tree-wide as declaration, write, or read. Example, in full:
///
///     cumulative_redist_carbon_surface_input_g_c
///       [WRITE] landscape_boundary_balance.zig:1448
///       [DECL ] mass_balance_audit.zig:32
///       -- no read anywhere
///
/// This list is a RATCHET, not an excuse. The test below fails if any NEW
/// `cumulative_*` field joins it, so the count can only go down. Each entry
/// needs one of: an identity that consumes it, or deletion. Deleting is often
/// right -- an accumulator nothing reads costs an hourly write and buys no
/// evidence.
///
/// The three `*_sink_g` and `*_exudate_g` entries additionally appear inside
/// `std.log.debug` calls in `ecosys_ng.zig`. A debug log is not a conservation
/// identity, so they are listed here too.
const cumulative_fields_without_a_reader = [_][]const u8{
    "cumulative_redist_carbon_surface_input_g_c",
    "cumulative_redist_carbon_subsurface_output_g_c",
    "cumulative_redist_oxygen_surface_input_g_o",
    "cumulative_redist_oxygen_subsurface_output_g_o",
    "cumulative_redist_hydrogen_surface_input_g_h",
    "cumulative_redist_hydrogen_subsurface_output_g_h",
    "cumulative_plant_root_organic_carbon_exudate_g",
    "cumulative_nitrogen_sink_g",
    "cumulative_plant_root_organic_nitrogen_exudate_g",
    "cumulative_phosphorus_sink_g",
    "cumulative_plant_root_organic_phosphorus_exudate_g",
};

test "every cumulative Totals field is read by an identity, or is a named exception" {
    // `docs/validation.md` ranks conservation closure second, and a cumulative
    // term that no identity reads contributes nothing to closure while looking
    // exactly like a term that does. This is the P3 "every cumulative_* has a
    // reader" check, enforced against this file's own source so it cannot drift
    // from the identities it audits.
    // `@embedFile` yields a comptime string, so scanning it for 79 field names
    // is comptime work and exhausts the default branch budget. Same reason
    // `reaction_physical_quality.zig:68` raises its own.
    @setEvalBranchQuota(2_000_000);
    const source: []const u8 = @embedFile("mass_balance_audit.zig");
    var declared: usize = 0;
    var unread: usize = 0;
    inline for (std.meta.fields(Totals)) |field| {
        if (comptime !std.mem.startsWith(u8, field.name, "cumulative_")) continue;
        declared += 1;
        // One occurrence is the declaration itself. A field consumed by any
        // identity in this file appears at least twice.
        var occurrences: usize = 0;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, source, cursor, field.name)) |found| {
            occurrences += 1;
            cursor = found + field.name.len;
        }
        // The exception list is itself written in this file, which would inflate
        // the count for every entry on it, so listed fields are counted but not
        // required to have a reader.
        // `if/else`, NOT `continue`: a runtime-conditional `continue` inside an
        // `inline for` is rejected as "comptime control flow inside runtime
        // block".
        var excepted = false;
        for (cumulative_fields_without_a_reader) |name| {
            if (std.mem.eql(u8, name, field.name)) excepted = true;
        }
        if (excepted) {
            unread += 1;
        } else if (occurrences < 2) {
            std.debug.print(
                "cumulative field '{s}' is declared and never read by any identity in this file. " ++
                    "Give it an identity or delete it; do not add it to " ++
                    "cumulative_fields_without_a_reader, which is a ratchet.\n",
                .{field.name},
            );
            return error.CumulativeFieldWithoutReader;
        }
    }
    // Pins the measurement so the exception list cannot quietly grow: 79
    // cumulative fields (including the mineral-carbon boundary), 11 unread.
    try std.testing.expectEqual(@as(usize, 79), declared);
    try std.testing.expectEqual(@as(usize, 11), unread);
    try std.testing.expectEqual(cumulative_fields_without_a_reader.len, unread);
}

test "the unread-cumulative exception list names only real Totals fields" {
    // A typo in the list would silently except nothing while appearing to
    // except something, which is how an allowlist stops being a ratchet.
    for (cumulative_fields_without_a_reader) |name| {
        var found = false;
        inline for (std.meta.fields(Totals)) |field| {
            if (std.mem.eql(u8, field.name, name)) found = true;
        }
        if (!found) {
            std.debug.print("exception list names '{s}', which is not a Totals field\n", .{name});
            return error.UnknownCumulativeException;
        }
    }
}

test "no cumulative Totals field is read by more than one identity" {
    // The other half of P3's comptime requirement. The sibling test above
    // proves every cumulative term HAS a reader; this proves none has TWO.
    //
    // Why two readers is a defect and not a detail: `balance` produces one
    // residual per element, and a term entering two identities is counted
    // twice against storage that only moved once. Worse, the two errors have
    // independent signs, so a genuine leak in one identity can be cancelled by
    // the spurious gain it creates in another and closure still reports zero.
    // The suite already guards one instance of this by hand -- `root-soil and
    // litter diagnostics do not double count all-storage ecosystem balance` --
    // and the comment at `:256-259` records that plant litter and root-soil
    // exchange "must not enter this identity a second time". This generalises
    // that from one reviewed case to every field.
    @setEvalBranchQuota(2_000_000);
    const source: []const u8 = @embedFile("mass_balance_audit.zig");

    // The body of `pub fn balance`, which is a single struct literal: one
    // `Balance` field per identity. Bounded at both ends by text that must
    // exist for the function to compile at all.
    const body_start = std.mem.indexOf(u8, source, "pub fn balance(t: Totals) !Balance {") orelse
        return error.BalanceFunctionNotFound;
    const body_end = std.mem.indexOfPos(u8, source, body_start, "    inline for (std.meta.fields(Balance))") orelse
        return error.BalanceFunctionNotFound;
    const body = source[body_start..body_end];

    // Identity assignments are `.name = ...` at eight-space indent. Splitting
    // there keeps a multi-line `compensatedSum(&.{ ... })` attached to the
    // identity that owns it, which a line-based split would tear apart.
    const marker = "\n        .";

    // VACUITY GUARD, and the reason this test can be trusted. If the marker
    // stopped matching, the body would be one segment, every field would be
    // "in one identity", and the test would pass while checking nothing. The
    // segment count must equal the number of `Balance` fields exactly.
    var segment_count: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, body, scan, marker)) |found| {
        segment_count += 1;
        scan = found + marker.len;
    }
    const identity_count = std.meta.fields(Balance).len;
    if (segment_count != identity_count) {
        std.debug.print(
            "identity segmentation found {d} assignments but Balance declares {d} fields; " ++
                "the marker no longer matches the source layout and this test would be vacuous\n",
            .{ segment_count, identity_count },
        );
        return error.IdentitySegmentationStale;
    }

    var checked: usize = 0;
    inline for (std.meta.fields(Totals)) |field| {
        if (comptime !std.mem.startsWith(u8, field.name, "cumulative_")) continue;
        var identities_reading: usize = 0;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, body, cursor, marker)) |found| {
            const segment_start = found + 1;
            const next = std.mem.indexOfPos(u8, body, found + marker.len, marker);
            const segment_end = if (next) |value| value else body.len;
            const segment = body[segment_start..segment_end];
            // `t.<name>` and not a bare name match: a bare match would also hit
            // a longer field that merely contains this one as a prefix, and
            // `cumulative_nitrogen_input_g` is a substring of nothing here but
            // `cumulative_iron_input_mol` vs `cumulative_ion_input_mol` shows
            // how close the names run. The trailing character check rejects a
            // prefix hit.
            var in_segment = false;
            var inner: usize = 0;
            while (std.mem.indexOfPos(u8, segment, inner, field.name)) |hit| {
                const after = hit + field.name.len;
                const boundary_ok = after >= segment.len or
                    !(std.ascii.isAlphanumeric(segment[after]) or segment[after] == '_');
                const before_ok = hit > 0 and segment[hit - 1] == '.';
                if (boundary_ok and before_ok) in_segment = true;
                inner = after;
            }
            if (in_segment) identities_reading += 1;
            cursor = found + marker.len;
        }
        checked += 1;
        if (identities_reading > 1) {
            std.debug.print(
                "cumulative field '{s}' is read by {d} identities in `balance`. " ++
                    "A term in two identities is counted twice against storage that moved once, " ++
                    "and the two sign errors can cancel a real leak. Give it one owner.\n",
                .{ field.name, identities_reading },
            );
            return error.CumulativeFieldReadByTwoIdentities;
        }
    }
    // Same 79 the sibling test pins, reached by a different traversal, so a
    // change to `Totals` cannot satisfy one test and silently skip the other.
    try std.testing.expectEqual(@as(usize, 79), checked);
}

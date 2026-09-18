// **A8a DISPOSITION: superseded, do not bind.** This module zeroes the legacy
// per-face `X*ER`/`X*EB` constituent records field by field on the branch
// where no sediment moves. Production has no such storage to go stale:
// `erosion/sediment_routing.zig` `route` `@memset`s all six face and balance
// arrays on entry (`:62`) and skips a cell before writing when runoff is
// negligible or sediment is zero (`:76`), so an inactive face reads as zero
// rather than stale, and the bridges consume those same arrays. Binding this
// would re-zero zeros.
//
// Group C of docs/traceability/erosion_unbound_family_disposition.md

const std = @import("std");

pub const DisturbanceMode = enum {
    no_effects,
    freeze_thaw,
    freeze_thaw_and_erosion,
    freeze_thaw_and_organic_matter_change,
    freeze_thaw_erosion_and_organic_matter_change,

    fn includesErosion(self: DisturbanceMode) bool {
        return self == .freeze_thaw_and_erosion or
            self == .freeze_thaw_erosion_and_organic_matter_change;
    }
};

/// Source-ordered scalar erosion fluxes from `hour1.f` lines 2541--2589.
pub const ScalarFlux = enum {
    sediment,
    sand,
    silt,
    clay,
    cation_exchange_capacity,
    anion_exchange_capacity,
    ammonium,
    ammonia,
    urea,
    nitrate,
    band_ammonium,
    band_ammonia,
    band_urea,
    band_nitrate,
    dissolved_ammonium,
    adsorbed_ammonium,
    hydrogen,
    aluminum,
    calcium,
    magnesium,
    sodium,
    potassium,
    bicarbonate,
    aluminum_hydroxide_0,
    aluminum_hydroxide_1,
    aluminum_hydroxide_2,
    phosphate_h1,
    phosphate_h2,
    band_aluminum_hydroxide_0,
    band_aluminum_hydroxide_1,
    band_aluminum_hydroxide_2,
    band_phosphate_h1,
    band_phosphate_h2,
    aluminum_oxide_phosphorus,
    iron_oxide_phosphorus,
    calcium_carbonate,
    calcium_sulfate,
    aluminum_sulfate,
    aluminum_phosphate,
    iron_phosphate,
    calcium_phosphate_dicalcium,
    calcium_phosphate_hydroxy,
    calcium_phosphate_mono,
    band_aluminum_phosphate,
    band_iron_phosphate,
    band_calcium_phosphate_dicalcium,
    band_calcium_phosphate_hydroxy,
    band_calcium_phosphate_mono,
};

pub const Dimensions = struct {
    organic_matter_classes: usize,
    organic_components: usize,
    residue_classes: usize,
    residue_components: usize,
    surface_organic_classes: usize,
};

/// All slices are runtime allocated for one direction and boundary side.
/// Elemental and mineral fluxes retain the legacy per-timestep mass units.
pub const Accumulators = struct {
    scalar_fluxes: []f64,
    organic_carbon_component3: []f64, // OMCER(3,NO,K,...)
    organic_carbon_components12: []f64, // OMCER(M,NO,K,...)
    organic_nitrogen_components12: []f64, // OMNER
    organic_phosphorus_components12: []f64, // OMPER
    residue_carbon_components: []f64, // ORCER
    residue_nitrogen_components: []f64, // ORNER
    residue_phosphorus_components: []f64, // ORPER
    humus_carbon: []f64, // OHCER
    humus_nitrogen: []f64, // OHNER
    humus_phosphorus: []f64, // OHPER
    surface_carbon: []f64, // OSCER
    surface_ash: []f64, // OSAER
    surface_nitrogen: []f64, // OSNER
    surface_phosphorus: []f64, // OSPER
};

pub const ResetError = error{DimensionMismatch};

/// Translates `hour1.f` lines 2539--2615. Disabled modes intentionally leave all
/// values untouched, matching the legacy IERSNG branch.
pub fn reset(
    mode: DisturbanceMode,
    dimensions: Dimensions,
    accumulators: *Accumulators,
) ResetError!void {
    if (!mode.includesErosion()) return;

    const scalar_count = std.meta.fields(ScalarFlux).len;
    const organic_count = dimensions.organic_matter_classes * dimensions.organic_components;
    const organic_component_count = organic_count * 2;
    const residue_count = dimensions.residue_classes * dimensions.residue_components;
    if (accumulators.scalar_fluxes.len != scalar_count or
        accumulators.organic_carbon_component3.len != organic_count or
        accumulators.organic_carbon_components12.len != organic_component_count or
        accumulators.organic_nitrogen_components12.len != organic_component_count or
        accumulators.organic_phosphorus_components12.len != organic_component_count or
        accumulators.residue_carbon_components.len != residue_count or
        accumulators.residue_nitrogen_components.len != residue_count or
        accumulators.residue_phosphorus_components.len != residue_count or
        accumulators.humus_carbon.len != dimensions.residue_classes or
        accumulators.humus_nitrogen.len != dimensions.residue_classes or
        accumulators.humus_phosphorus.len != dimensions.residue_classes or
        accumulators.surface_carbon.len != dimensions.surface_organic_classes * dimensions.residue_classes or
        accumulators.surface_ash.len != dimensions.surface_organic_classes * dimensions.residue_classes or
        accumulators.surface_nitrogen.len != dimensions.surface_organic_classes * dimensions.residue_classes or
        accumulators.surface_phosphorus.len != dimensions.surface_organic_classes * dimensions.residue_classes)
    {
        return error.DimensionMismatch;
    }

    for (accumulators.scalar_fluxes) |*value| value.* = 0.0;
    for (0..organic_count) |organic_index| {
        accumulators.organic_carbon_component3[organic_index] = 0.0;
        for (0..2) |component| {
            const index = organic_index * 2 + component;
            accumulators.organic_carbon_components12[index] = 0.0;
            accumulators.organic_nitrogen_components12[index] = 0.0;
            accumulators.organic_phosphorus_components12[index] = 0.0;
        }
    }
    for (0..dimensions.residue_classes) |class| {
        for (0..dimensions.residue_components) |component| {
            const index = class * dimensions.residue_components + component;
            accumulators.residue_carbon_components[index] = 0.0;
            accumulators.residue_nitrogen_components[index] = 0.0;
            accumulators.residue_phosphorus_components[index] = 0.0;
        }
        accumulators.humus_carbon[class] = 0.0;
        accumulators.humus_nitrogen[class] = 0.0;
        accumulators.humus_phosphorus[class] = 0.0;
        for (0..dimensions.surface_organic_classes) |component| {
            const index = class * dimensions.surface_organic_classes + component;
            accumulators.surface_carbon[index] = 0.0;
            accumulators.surface_ash[index] = 0.0;
            accumulators.surface_nitrogen[index] = 0.0;
            accumulators.surface_phosphorus[index] = 0.0;
        }
    }
}

test "erosion-enabled mode clears every runtime-sized accumulator" {
    const allocator = std.testing.allocator;
    const dimensions = Dimensions{
        .organic_matter_classes = 3,
        .organic_components = 4,
        .residue_classes = 2,
        .residue_components = 3,
        .surface_organic_classes = 5,
    };
    var slices: [15][]f64 = undefined;
    const lengths = [_]usize{
        std.meta.fields(ScalarFlux).len, 12, 24, 24, 24,
        6,                               6,  6,  2,  2,
        2,                               10, 10, 10, 10,
    };
    for (&slices, lengths) |*slice, length| {
        slice.* = try allocator.alloc(f64, length);
        @memset(slice.*, 7.0);
    }
    defer for (slices) |slice| allocator.free(slice);
    var accumulators = Accumulators{
        .scalar_fluxes = slices[0],
        .organic_carbon_component3 = slices[1],
        .organic_carbon_components12 = slices[2],
        .organic_nitrogen_components12 = slices[3],
        .organic_phosphorus_components12 = slices[4],
        .residue_carbon_components = slices[5],
        .residue_nitrogen_components = slices[6],
        .residue_phosphorus_components = slices[7],
        .humus_carbon = slices[8],
        .humus_nitrogen = slices[9],
        .humus_phosphorus = slices[10],
        .surface_carbon = slices[11],
        .surface_ash = slices[12],
        .surface_nitrogen = slices[13],
        .surface_phosphorus = slices[14],
    };

    try reset(.freeze_thaw_and_erosion, dimensions, &accumulators);
    for (slices) |slice| for (slice) |value| {
        try std.testing.expectEqual(@as(f64, 0.0), value);
    };
}

test "erosion-disabled mode preserves accumulators" {
    var scalar_fluxes = [_]f64{3.0} ** std.meta.fields(ScalarFlux).len;
    var accumulators: Accumulators = undefined;
    accumulators.scalar_fluxes = &scalar_fluxes;
    try reset(.freeze_thaw, undefined, &accumulators);
    try std.testing.expectEqual(@as(f64, 3.0), scalar_fluxes[0]);
}

// **A8a DISPOSITION: superseded, do not bind.** This module assembles the
// landscape-boundary export ledger for eroded sediment and its C, N, P and
// salt inventories. Production owns that in
// `landscape_boundary_ledger.accumulateAccepted`, called from
// `stages/hourly_science_sediment.zig:145` with element totals reduced by
// `erosion_organic_bridge.exportedElements` (`:128`),
// `erosion_fertilizer_bridge.exported` (`:134`) and
// `erosion_chemistry_bridge.exported` (`:139`), with net sediment published
// separately by `soil_sediment_change.publishAcceptedNetSedimentMg` (`:156`).
// NOTE: the intentional legacy-defect correction documented below (applying
// the boundary direction to the doubled fertilizer-ammonium term that
// `redist.f:1105` omits) is NOT carried into production, which never
// assembles a two-sided record. Inert while this module is unwired, but it
// must be re-argued against the bridge reduction if the path is revived.
//
// Group E of docs/traceability/erosion_unbound_family_disposition.md

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

pub const SaltEquilibriumMode = enum {
    static,
    dynamic,
};

pub const ExternalBoundaryWindow = struct {
    first_column: usize,
    last_column_inclusive: usize,
    first_row: usize,
    last_row_inclusive: usize,
};

pub const Face = enum(u8) {
    east,
    west,
    south,
    north,

    pub const count: usize = @typeInfo(Face).@"enum".fields.len;
};

pub const OrganicDimensions = struct {
    microbial_class_count: usize,
    microbial_group_count: usize,
    microbial_component_count: usize,
    residue_class_count: usize,
    residue_component_count: usize,
    soil_organic_component_count: usize,
};

/// Slices use source traversal order: microbial `(class, group, component)`,
/// residue `(class, component)`, and soil organic `(class, component)`.
pub const OrganicMatterFlux = struct {
    microbial_carbon_g_c_per_step: []const f64,
    microbial_nitrogen_g_n_per_step: []const f64,
    microbial_phosphorus_g_p_per_step: []const f64,
    residue_carbon_g_c_per_step: []const f64,
    residue_nitrogen_g_n_per_step: []const f64,
    residue_phosphorus_g_p_per_step: []const f64,
    adsorbed_carbon_g_c_per_step: []const f64,
    adsorbed_acetate_carbon_g_c_per_step: []const f64,
    adsorbed_nitrogen_g_n_per_step: []const f64,
    adsorbed_phosphorus_g_p_per_step: []const f64,
    soil_organic_carbon_g_c_per_step: []const f64,
    soil_organic_nitrogen_g_n_per_step: []const f64,
    soil_organic_phosphorus_g_p_per_step: []const f64,
};

pub const NitrogenMineralFlux = struct {
    adsorbed_ammonium_non_band_mol_n_per_step: f64 = 0,
    adsorbed_ammonium_band_mol_n_per_step: f64 = 0,
    fertilizer_ammonium_non_band_mol_n_per_step: f64 = 0,
    fertilizer_ammonia_non_band_mol_n_per_step: f64 = 0,
    fertilizer_urea_non_band_mol_n_per_step: f64 = 0,
    fertilizer_nitrate_non_band_mol_n_per_step: f64 = 0,
    fertilizer_ammonium_band_mol_n_per_step: f64 = 0,
    fertilizer_ammonia_band_mol_n_per_step: f64 = 0,
    fertilizer_urea_band_mol_n_per_step: f64 = 0,
    fertilizer_nitrate_band_mol_n_per_step: f64 = 0,
};

pub const PhosphorusMineralFlux = struct {
    adsorbed_hpo4_non_band_mol_p_per_step: f64 = 0,
    adsorbed_h2po4_non_band_mol_p_per_step: f64 = 0,
    adsorbed_hpo4_band_mol_p_per_step: f64 = 0,
    adsorbed_h2po4_band_mol_p_per_step: f64 = 0,
    aluminum_phosphate_non_band_mol_per_step: f64 = 0,
    iron_phosphate_non_band_mol_per_step: f64 = 0,
    calcium_hpo4_non_band_mol_per_step: f64 = 0,
    calcium_h2po4_non_band_mol_per_step: f64 = 0,
    apatite_non_band_mol_per_step: f64 = 0,
    aluminum_phosphate_band_mol_per_step: f64 = 0,
    iron_phosphate_band_mol_per_step: f64 = 0,
    calcium_hpo4_band_mol_per_step: f64 = 0,
    calcium_h2po4_band_mol_per_step: f64 = 0,
    apatite_band_mol_per_step: f64 = 0,
};

pub const MatrixPrecipitateFlux = struct {
    aluminum_hydroxide_mol_per_step: f64 = 0,
    iron_hydroxide_mol_per_step: f64 = 0,
    calcium_carbonate_mol_per_step: f64 = 0,
    calcium_sulfate_mol_per_step: f64 = 0,
};

pub const AdsorbedSaltFlux = struct {
    hydrogen_mol_per_step: f64 = 0,
    aluminum_mol_per_step: f64 = 0,
    iron_mol_per_step: f64 = 0,
    calcium_mol_per_step: f64 = 0,
    magnesium_mol_per_step: f64 = 0,
    sodium_mol_per_step: f64 = 0,
    potassium_mol_per_step: f64 = 0,
    bicarbonate_mol_per_step: f64 = 0,
    deprotonated_site_non_band_mol_per_step: f64 = 0,
    deprotonated_site_band_mol_per_step: f64 = 0,
    hydroxyl_site_non_band_mol_per_step: f64 = 0,
    hydroxyl_site_band_mol_per_step: f64 = 0,
    protonated_site_non_band_mol_per_step: f64 = 0,
    protonated_site_band_mol_per_step: f64 = 0,
    aluminum_hydroxide_2_mol_per_step: f64 = 0,
    iron_hydroxide_2_mol_per_step: f64 = 0,
};

pub const SulfateComplexFlux = struct {
    aluminum_sulfate_soil_mol_per_step: f64 = 0,
    iron_sulfate_soil_mol_per_step: f64 = 0,
    calcium_sulfate_soil_mol_per_step: f64 = 0,
    magnesium_sulfate_soil_mol_per_step: f64 = 0,
    sodium_sulfate_soil_mol_per_step: f64 = 0,
    potassium_sulfate_soil_mol_per_step: f64 = 0,
    aluminum_sulfate_fertilizer_mol_per_step: f64 = 0,
    iron_sulfate_fertilizer_mol_per_step: f64 = 0,
    calcium_sulfate_fertilizer_mol_per_step: f64 = 0,
    magnesium_sulfate_fertilizer_mol_per_step: f64 = 0,
    sodium_sulfate_fertilizer_mol_per_step: f64 = 0,
    potassium_sulfate_fertilizer_mol_per_step: f64 = 0,
};

pub const BoundaryFlux = struct {
    sediment_megagrams_per_step: f64,
    organic: OrganicMatterFlux,
    nitrogen: NitrogenMineralFlux = .{},
    phosphorus: PhosphorusMineralFlux = .{},
    matrix_precipitates: MatrixPrecipitateFlux = .{},
    adsorbed_salts: AdsorbedSaltFlux = .{},
    sulfate_complexes: SulfateComplexFlux = .{},
};

pub const CumulativeOutwardLedger = struct {
    sediment_megagrams: f64 = 0,
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
    ion_components_mol: f64 = 0,
};

pub const CellOutwardLedger = struct {
    sediment_megagrams: f64 = 0,
    organic_carbon_g_c: f64 = 0,
    inorganic_carbon_g_c: f64 = 0,
    organic_nitrogen_g_n: f64 = 0,
    inorganic_nitrogen_g_n: f64 = 0,
    organic_phosphorus_g_p: f64 = 0,
    inorganic_phosphorus_g_p: f64 = 0,
    ion_components_mol: f64 = 0,
};

pub const Inputs = struct {
    lon_count: usize,
    lat_count: usize,
    external_boundary_window: ExternalBoundaryWindow,
    disturbance_mode: DisturbanceMode,
    salt_equilibrium_mode: SaltEquilibriumMode,
    organic_dimensions: OrganicDimensions,
    flux_by_face: [Face.count][]const BoundaryFlux,
    negligible_sediment_megagrams_by_cell: []const f64,
    nitrogen_g_n_per_mol_n: f64,
    phosphorus_g_p_per_mol_p: f64,
};

pub const State = struct {
    cumulative: CumulativeOutwardLedger,
    outward_by_cell: []CellOutwardLedger,
};

/// Accounts for erosion sediment and its C, N, P, and salt inventories.
///
/// Traceability: REDIST.F lines 960--1135 (`ER`, `ZXE`, `ZPE`, `PXE`,
/// `PPE`, `COE`, `ZOE`, `POE`, `SEF`, `SEX`, `SEP`, and `SET`). Runtime
/// organic dimensions replace fixed `K`, `NO`, and `M` extents while retaining
/// their source loop order. The strict sediment threshold gates every coupled
/// inventory.
///
/// REDIST omits `XN` from the doubled fertilizer-ammonium terms at line 1105
/// although all neighboring ion terms apply the boundary direction. Applying
/// the direction here preserves mass-flow sign symmetry and is an intentional
/// legacy-defect correction.
pub fn apply(inputs: Inputs, state: *State) !void {
    const cell_count = try validateDimensions(inputs, state.*);
    try validateInputsAndState(inputs, state.*, cell_count);
    if (!inputs.disturbance_mode.includesErosion()) return;
    try preflightUpdates(inputs, state.*);

    const window = inputs.external_boundary_window;
    for (window.first_column..window.last_column_inclusive + 1) |column| {
        for (window.first_row..window.last_row_inclusive + 1) |row| {
            const cell = row * inputs.lon_count + column;
            for (std.meta.tags(Face)) |face| {
                if (!isExternalFace(face, column, row, window)) continue;
                const flux = inputs.flux_by_face[@intFromEnum(face)][cell];
                if (@abs(flux.sediment_megagrams_per_step) <=
                    inputs.negligible_sediment_megagrams_by_cell[cell]) continue;
                const transfer = calculateTransfer(
                    flux,
                    inwardSign(face),
                    inputs,
                ) catch unreachable;
                state.cumulative =
                    advanceCumulative(state.cumulative, transfer) catch unreachable;
                state.outward_by_cell[cell] =
                    advanceCell(state.outward_by_cell[cell], transfer) catch unreachable;
            }
        }
    }
}

const SignedTransfer = struct {
    sediment_megagrams: f64,
    organic_carbon_g_c: f64,
    exchangeable_carbon_g_c: f64,
    organic_nitrogen_g_n: f64,
    exchangeable_nitrogen_g_n: f64,
    fertilizer_nitrogen_g_n: f64,
    organic_phosphorus_g_p: f64,
    exchangeable_phosphorus_g_p: f64,
    precipitated_phosphorus_g_p: f64,
    ion_components_mol: f64,
};

fn calculateTransfer(
    flux: BoundaryFlux,
    direction: f64,
    inputs: Inputs,
) !SignedTransfer {
    const sediment_megagrams =
        try checkedProduct(direction, flux.sediment_megagrams_per_step);
    const nitrogen = flux.nitrogen;
    const exchangeable_nitrogen_g_n = try massFromMoles(
        direction,
        inputs.nitrogen_g_n_per_mol_n,
        &.{
            nitrogen.adsorbed_ammonium_non_band_mol_n_per_step,
            nitrogen.adsorbed_ammonium_band_mol_n_per_step,
        },
    );
    const fertilizer_nitrogen_g_n = try massFromMoles(
        direction,
        inputs.nitrogen_g_n_per_mol_n,
        &.{
            nitrogen.fertilizer_ammonium_non_band_mol_n_per_step,
            nitrogen.fertilizer_ammonia_non_band_mol_n_per_step,
            nitrogen.fertilizer_urea_non_band_mol_n_per_step,
            nitrogen.fertilizer_nitrate_non_band_mol_n_per_step,
            nitrogen.fertilizer_ammonium_band_mol_n_per_step,
            nitrogen.fertilizer_ammonia_band_mol_n_per_step,
            nitrogen.fertilizer_urea_band_mol_n_per_step,
            nitrogen.fertilizer_nitrate_band_mol_n_per_step,
        },
    );
    const exchangeable_phosphorus_g_p = try exchangeablePhosphorus(
        flux.phosphorus,
        direction,
        inputs.phosphorus_g_p_per_mol_p,
    );
    const precipitated_phosphorus_g_p = try precipitatedPhosphorus(
        flux.phosphorus,
        direction,
        inputs.phosphorus_g_p_per_mol_p,
    );
    const organic = try organicElements(
        flux.organic,
        inputs.organic_dimensions,
        direction,
    );
    return .{
        .sediment_megagrams = sediment_megagrams,
        .organic_carbon_g_c = organic.carbon_g_c,
        .exchangeable_carbon_g_c = 0,
        .organic_nitrogen_g_n = organic.nitrogen_g_n,
        .exchangeable_nitrogen_g_n = exchangeable_nitrogen_g_n,
        .fertilizer_nitrogen_g_n = fertilizer_nitrogen_g_n,
        .organic_phosphorus_g_p = organic.phosphorus_g_p,
        .exchangeable_phosphorus_g_p = exchangeable_phosphorus_g_p,
        .precipitated_phosphorus_g_p = precipitated_phosphorus_g_p,
        .ion_components_mol = if (inputs.salt_equilibrium_mode == .dynamic)
            try dynamicIonComponents(flux, direction)
        else
            0,
    };
}

fn exchangeablePhosphorus(
    phosphorus: PhosphorusMineralFlux,
    direction: f64,
    phosphorus_g_p_per_mol_p: f64,
) !f64 {
    return massFromMoles(direction, phosphorus_g_p_per_mol_p, &.{
        phosphorus.adsorbed_hpo4_non_band_mol_p_per_step,
        phosphorus.adsorbed_h2po4_non_band_mol_p_per_step,
        phosphorus.adsorbed_hpo4_band_mol_p_per_step,
        phosphorus.adsorbed_h2po4_band_mol_p_per_step,
    });
}

fn precipitatedPhosphorus(
    phosphorus: PhosphorusMineralFlux,
    direction: f64,
    phosphorus_g_p_per_mol_p: f64,
) !f64 {
    var phosphorus_g_p = try checkedProduct(
        phosphorus_g_p_per_mol_p,
        try sourceSum(&.{
            phosphorus.aluminum_phosphate_non_band_mol_per_step,
            phosphorus.iron_phosphate_non_band_mol_per_step,
            phosphorus.calcium_hpo4_non_band_mol_per_step,
            phosphorus.aluminum_phosphate_band_mol_per_step,
            phosphorus.iron_phosphate_band_mol_per_step,
            phosphorus.calcium_hpo4_band_mol_per_step,
        }),
    );
    phosphorus_g_p = try checkedSum(
        phosphorus_g_p,
        try checkedProduct(
            try checkedProduct(2, phosphorus_g_p_per_mol_p),
            try sourceSum(&.{
                phosphorus.calcium_h2po4_non_band_mol_per_step,
                phosphorus.calcium_h2po4_band_mol_per_step,
            }),
        ),
    );
    phosphorus_g_p = try checkedSum(
        phosphorus_g_p,
        try checkedProduct(
            try checkedProduct(3, phosphorus_g_p_per_mol_p),
            try sourceSum(&.{
                phosphorus.apatite_non_band_mol_per_step,
                phosphorus.apatite_band_mol_per_step,
            }),
        ),
    );
    return checkedProduct(direction, phosphorus_g_p);
}

const OrganicElements = struct {
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
};

fn organicElements(
    flux: OrganicMatterFlux,
    dimensions: OrganicDimensions,
    direction: f64,
) !OrganicElements {
    var result: OrganicElements = .{
        .carbon_g_c = 0,
        .nitrogen_g_n = 0,
        .phosphorus_g_p = 0,
    };
    var index: usize = 0;
    for (0..dimensions.microbial_class_count) |_| {
        for (0..dimensions.microbial_group_count) |_| {
            for (0..dimensions.microbial_component_count) |_| {
                result.carbon_g_c = try addSigned(
                    result.carbon_g_c,
                    direction,
                    flux.microbial_carbon_g_c_per_step[index],
                );
                result.nitrogen_g_n = try addSigned(
                    result.nitrogen_g_n,
                    direction,
                    flux.microbial_nitrogen_g_n_per_step[index],
                );
                result.phosphorus_g_p = try addSigned(
                    result.phosphorus_g_p,
                    direction,
                    flux.microbial_phosphorus_g_p_per_step[index],
                );
                index += 1;
            }
        }
    }
    var residue_index: usize = 0;
    for (0..dimensions.residue_class_count) |class| {
        for (0..dimensions.residue_component_count) |_| {
            result.carbon_g_c = try addSigned(
                result.carbon_g_c,
                direction,
                flux.residue_carbon_g_c_per_step[residue_index],
            );
            result.nitrogen_g_n = try addSigned(
                result.nitrogen_g_n,
                direction,
                flux.residue_nitrogen_g_n_per_step[residue_index],
            );
            result.phosphorus_g_p = try addSigned(
                result.phosphorus_g_p,
                direction,
                flux.residue_phosphorus_g_p_per_step[residue_index],
            );
            residue_index += 1;
        }
        result.carbon_g_c = try checkedSum(
            result.carbon_g_c,
            try checkedProduct(
                direction,
                try checkedSum(
                    flux.adsorbed_carbon_g_c_per_step[class],
                    flux.adsorbed_acetate_carbon_g_c_per_step[class],
                ),
            ),
        );
        result.nitrogen_g_n = try addSigned(
            result.nitrogen_g_n,
            direction,
            flux.adsorbed_nitrogen_g_n_per_step[class],
        );
        result.phosphorus_g_p = try addSigned(
            result.phosphorus_g_p,
            direction,
            flux.adsorbed_phosphorus_g_p_per_step[class],
        );
        for (0..dimensions.soil_organic_component_count) |component| {
            const soil_index =
                class * dimensions.soil_organic_component_count + component;
            result.carbon_g_c = try addSigned(
                result.carbon_g_c,
                direction,
                flux.soil_organic_carbon_g_c_per_step[soil_index],
            );
            result.nitrogen_g_n = try addSigned(
                result.nitrogen_g_n,
                direction,
                flux.soil_organic_nitrogen_g_n_per_step[soil_index],
            );
            result.phosphorus_g_p = try addSigned(
                result.phosphorus_g_p,
                direction,
                flux.soil_organic_phosphorus_g_p_per_step[soil_index],
            );
        }
    }
    return result;
}

fn dynamicIonComponents(flux: BoundaryFlux, direction: f64) !f64 {
    const nitrogen = flux.nitrogen;
    var fertilizer = try checkedProduct(
        direction,
        try sourceSum(&.{
            nitrogen.fertilizer_ammonia_non_band_mol_n_per_step,
            nitrogen.fertilizer_urea_non_band_mol_n_per_step,
            nitrogen.fertilizer_nitrate_non_band_mol_n_per_step,
            nitrogen.fertilizer_ammonia_band_mol_n_per_step,
            nitrogen.fertilizer_urea_band_mol_n_per_step,
            nitrogen.fertilizer_nitrate_band_mol_n_per_step,
        }),
    );
    fertilizer = try checkedSum(
        fertilizer,
        try checkedProduct(
            try checkedProduct(direction, 2),
            try sourceSum(&.{
                nitrogen.fertilizer_ammonium_non_band_mol_n_per_step,
                nitrogen.fertilizer_ammonium_band_mol_n_per_step,
            }),
        ),
    );
    const exchange = try exchangeIonComponents(
        flux,
        direction,
    );
    const precipitate = try precipitateIonComponents(
        flux,
        direction,
    );
    var total = try checkedSum(fertilizer, exchange);
    total = try checkedSum(total, precipitate);
    return total;
}

fn exchangeIonComponents(flux: BoundaryFlux, direction: f64) !f64 {
    const salt = flux.adsorbed_salts;
    const nitrogen = flux.nitrogen;
    const phosphorus = flux.phosphorus;
    var total = try checkedProduct(
        direction,
        try sourceSum(&.{
            salt.hydrogen_mol_per_step,
            salt.aluminum_mol_per_step,
            salt.iron_mol_per_step,
            salt.calcium_mol_per_step,
            salt.magnesium_mol_per_step,
            salt.sodium_mol_per_step,
            salt.potassium_mol_per_step,
            salt.bicarbonate_mol_per_step,
            salt.deprotonated_site_non_band_mol_per_step,
            salt.deprotonated_site_band_mol_per_step,
        }),
    );
    total = try checkedSum(
        total,
        try weightedSignedSum(direction, 2, &.{
            nitrogen.adsorbed_ammonium_non_band_mol_n_per_step,
            nitrogen.adsorbed_ammonium_band_mol_n_per_step,
            salt.hydroxyl_site_non_band_mol_per_step,
            salt.hydroxyl_site_band_mol_per_step,
        }),
    );
    total = try checkedSum(
        total,
        try weightedSignedSum(direction, 3, &.{
            salt.aluminum_hydroxide_2_mol_per_step,
            salt.iron_hydroxide_2_mol_per_step,
            salt.protonated_site_non_band_mol_per_step,
            salt.protonated_site_band_mol_per_step,
            phosphorus.adsorbed_hpo4_non_band_mol_p_per_step,
            phosphorus.adsorbed_hpo4_band_mol_p_per_step,
        }),
    );
    total = try checkedSum(
        total,
        try weightedSignedSum(direction, 4, &.{
            phosphorus.adsorbed_h2po4_non_band_mol_p_per_step,
            phosphorus.adsorbed_h2po4_band_mol_p_per_step,
        }),
    );
    return total;
}

fn precipitateIonComponents(flux: BoundaryFlux, direction: f64) !f64 {
    const phosphorus = flux.phosphorus;
    const matrix = flux.matrix_precipitates;
    var total = try weightedSignedSum(direction, 2, &.{
        matrix.calcium_carbonate_mol_per_step,
        matrix.calcium_sulfate_mol_per_step,
        phosphorus.aluminum_phosphate_non_band_mol_per_step,
        phosphorus.iron_phosphate_non_band_mol_per_step,
        phosphorus.aluminum_phosphate_band_mol_per_step,
        phosphorus.iron_phosphate_band_mol_per_step,
    });
    total = try checkedSum(
        total,
        try weightedSignedSum(direction, 3, &.{
            phosphorus.calcium_hpo4_non_band_mol_per_step,
            phosphorus.calcium_hpo4_band_mol_per_step,
        }),
    );
    total = try checkedSum(
        total,
        try weightedSignedSum(direction, 4, &.{
            matrix.aluminum_hydroxide_mol_per_step,
            matrix.iron_hydroxide_mol_per_step,
        }),
    );
    total = try checkedSum(
        total,
        try weightedSignedSum(direction, 7, &.{
            phosphorus.calcium_h2po4_non_band_mol_per_step,
            phosphorus.calcium_h2po4_band_mol_per_step,
        }),
    );
    total = try checkedSum(
        total,
        try weightedSignedSum(direction, 9, &.{
            phosphorus.apatite_non_band_mol_per_step,
            phosphorus.apatite_band_mol_per_step,
        }),
    );
    total = try checkedSum(
        total,
        try checkedProduct(
            direction,
            try sourceStructSum(flux.sulfate_complexes),
        ),
    );
    return total;
}

fn advanceCumulative(
    current: CumulativeOutwardLedger,
    transfer: SignedTransfer,
) !CumulativeOutwardLedger {
    var next = current;
    next.sediment_megagrams = try checkedSum(next.sediment_megagrams, -transfer.sediment_megagrams);
    next.carbon_g_c =
        try checkedSum(next.carbon_g_c, -transfer.organic_carbon_g_c);
    next.carbon_g_c =
        try checkedSum(next.carbon_g_c, -transfer.exchangeable_carbon_g_c);
    next.nitrogen_g_n =
        try checkedSum(next.nitrogen_g_n, -transfer.organic_nitrogen_g_n);
    next.nitrogen_g_n =
        try checkedSum(next.nitrogen_g_n, -transfer.exchangeable_nitrogen_g_n);
    next.nitrogen_g_n =
        try checkedSum(next.nitrogen_g_n, -transfer.fertilizer_nitrogen_g_n);
    next.phosphorus_g_p =
        try checkedSum(next.phosphorus_g_p, -transfer.organic_phosphorus_g_p);
    next.phosphorus_g_p = try checkedSum(
        next.phosphorus_g_p,
        -transfer.exchangeable_phosphorus_g_p,
    );
    next.phosphorus_g_p = try checkedSum(
        next.phosphorus_g_p,
        -transfer.precipitated_phosphorus_g_p,
    );
    next.ion_components_mol =
        try checkedSum(next.ion_components_mol, -transfer.ion_components_mol);
    return next;
}

fn advanceCell(
    current: CellOutwardLedger,
    transfer: SignedTransfer,
) !CellOutwardLedger {
    var next = current;
    next.sediment_megagrams = try checkedSum(next.sediment_megagrams, -transfer.sediment_megagrams);
    next.organic_carbon_g_c =
        try checkedSum(next.organic_carbon_g_c, -transfer.organic_carbon_g_c);
    next.inorganic_carbon_g_c = try checkedSum(
        next.inorganic_carbon_g_c,
        -transfer.exchangeable_carbon_g_c,
    );
    next.organic_nitrogen_g_n =
        try checkedSum(next.organic_nitrogen_g_n, -transfer.organic_nitrogen_g_n);
    next.inorganic_nitrogen_g_n = try checkedSum(
        next.inorganic_nitrogen_g_n,
        -transfer.exchangeable_nitrogen_g_n,
    );
    next.inorganic_nitrogen_g_n = try checkedSum(
        next.inorganic_nitrogen_g_n,
        -transfer.fertilizer_nitrogen_g_n,
    );
    next.organic_phosphorus_g_p = try checkedSum(
        next.organic_phosphorus_g_p,
        -transfer.organic_phosphorus_g_p,
    );
    next.inorganic_phosphorus_g_p = try checkedSum(
        next.inorganic_phosphorus_g_p,
        -transfer.exchangeable_phosphorus_g_p,
    );
    next.inorganic_phosphorus_g_p = try checkedSum(
        next.inorganic_phosphorus_g_p,
        -transfer.precipitated_phosphorus_g_p,
    );
    next.ion_components_mol =
        try checkedSum(next.ion_components_mol, -transfer.ion_components_mol);
    return next;
}

fn preflightUpdates(inputs: Inputs, state: State) !void {
    var cumulative = state.cumulative;
    const window = inputs.external_boundary_window;
    for (window.first_column..window.last_column_inclusive + 1) |column| {
        for (window.first_row..window.last_row_inclusive + 1) |row| {
            const cell = row * inputs.lon_count + column;
            var cell_ledger = state.outward_by_cell[cell];
            for (std.meta.tags(Face)) |face| {
                if (!isExternalFace(face, column, row, window)) continue;
                const flux = inputs.flux_by_face[@intFromEnum(face)][cell];
                if (@abs(flux.sediment_megagrams_per_step) <=
                    inputs.negligible_sediment_megagrams_by_cell[cell]) continue;
                const transfer = try calculateTransfer(
                    flux,
                    inwardSign(face),
                    inputs,
                );
                cumulative = try advanceCumulative(cumulative, transfer);
                cell_ledger = try advanceCell(cell_ledger, transfer);
            }
        }
    }
}

fn validateDimensions(inputs: Inputs, state: State) !usize {
    if (inputs.lon_count == 0 or inputs.lat_count == 0)
        return error.InvalidSedimentBoundaryDimensions;
    const cell_count = std.math.mul(
        usize,
        inputs.lon_count,
        inputs.lat_count,
    ) catch return error.InvalidSedimentBoundaryDimensions;
    inline for (inputs.flux_by_face) |values|
        if (values.len != cell_count)
            return error.InvalidSedimentBoundaryDimensions;
    if (inputs.negligible_sediment_megagrams_by_cell.len != cell_count or
        state.outward_by_cell.len != cell_count)
        return error.InvalidSedimentBoundaryDimensions;
    const window = inputs.external_boundary_window;
    if (window.first_column > window.last_column_inclusive or
        window.first_row > window.last_row_inclusive or
        window.last_column_inclusive >= inputs.lon_count or
        window.last_row_inclusive >= inputs.lat_count)
        return error.InvalidSedimentBoundaryWindow;
    return cell_count;
}

fn validateInputsAndState(inputs: Inputs, state: State, cell_count: usize) !void {
    if (!positiveFinite(inputs.nitrogen_g_n_per_mol_n) or
        !positiveFinite(inputs.phosphorus_g_p_per_mol_p))
        return error.InvalidSedimentBoundaryInput;
    inline for (inputs.flux_by_face) |values| {
        for (values) |flux| {
            if (!std.math.isFinite(flux.sediment_megagrams_per_step))
                return error.InvalidSedimentBoundaryInput;
            try validateFiniteStruct(flux.nitrogen);
            try validateFiniteStruct(flux.phosphorus);
            try validateFiniteStruct(flux.matrix_precipitates);
            try validateFiniteStruct(flux.adsorbed_salts);
            try validateFiniteStruct(flux.sulfate_complexes);
            try validateOrganicFlux(flux.organic, inputs.organic_dimensions);
        }
    }
    for (0..cell_count) |cell| {
        if (!nonnegativeFinite(inputs.negligible_sediment_megagrams_by_cell[cell]))
            return error.InvalidSedimentBoundaryInput;
        validateFiniteStruct(state.outward_by_cell[cell]) catch
            return error.InvalidSedimentBoundaryState;
    }
    validateFiniteStruct(state.cumulative) catch
        return error.InvalidSedimentBoundaryState;
}

fn validateOrganicFlux(
    flux: OrganicMatterFlux,
    dimensions: OrganicDimensions,
) !void {
    const microbial_count = checkedLengthProduct(&.{
        dimensions.microbial_class_count,
        dimensions.microbial_group_count,
        dimensions.microbial_component_count,
    }) catch return error.InvalidSedimentBoundaryDimensions;
    const residue_count = checkedLengthProduct(&.{
        dimensions.residue_class_count,
        dimensions.residue_component_count,
    }) catch return error.InvalidSedimentBoundaryDimensions;
    const soil_count = checkedLengthProduct(&.{
        dimensions.residue_class_count,
        dimensions.soil_organic_component_count,
    }) catch return error.InvalidSedimentBoundaryDimensions;
    inline for (.{
        flux.microbial_carbon_g_c_per_step,
        flux.microbial_nitrogen_g_n_per_step,
        flux.microbial_phosphorus_g_p_per_step,
    }) |values| try validateSlice(values, microbial_count);
    inline for (.{
        flux.residue_carbon_g_c_per_step,
        flux.residue_nitrogen_g_n_per_step,
        flux.residue_phosphorus_g_p_per_step,
    }) |values| try validateSlice(values, residue_count);
    inline for (.{
        flux.adsorbed_carbon_g_c_per_step,
        flux.adsorbed_acetate_carbon_g_c_per_step,
        flux.adsorbed_nitrogen_g_n_per_step,
        flux.adsorbed_phosphorus_g_p_per_step,
    }) |values| try validateSlice(values, dimensions.residue_class_count);
    inline for (.{
        flux.soil_organic_carbon_g_c_per_step,
        flux.soil_organic_nitrogen_g_n_per_step,
        flux.soil_organic_phosphorus_g_p_per_step,
    }) |values| try validateSlice(values, soil_count);
}

fn validateSlice(values: []const f64, expected_length: usize) !void {
    if (values.len != expected_length)
        return error.InvalidSedimentBoundaryDimensions;
    for (values) |value|
        if (!std.math.isFinite(value))
            return error.InvalidSedimentBoundaryInput;
}

fn checkedLengthProduct(values: []const usize) !usize {
    var result: usize = 1;
    for (values) |value|
        result = std.math.mul(usize, result, value) catch
            return error.InvalidSedimentBoundaryDimensions;
    return result;
}

fn isExternalFace(
    face: Face,
    column: usize,
    row: usize,
    window: ExternalBoundaryWindow,
) bool {
    return switch (face) {
        .east => column == window.last_column_inclusive,
        .west => column == window.first_column,
        .south => row == window.last_row_inclusive,
        .north => row == window.first_row,
    };
}

fn inwardSign(face: Face) f64 {
    return switch (face) {
        .east, .south => -1,
        .west, .north => 1,
    };
}

fn massFromMoles(
    direction: f64,
    mass_g_per_mol: f64,
    values: []const f64,
) !f64 {
    return checkedProduct(
        try checkedProduct(direction, mass_g_per_mol),
        try sourceSum(values),
    );
}

fn weightedSignedSum(
    direction: f64,
    multiplicity: f64,
    values: []const f64,
) !f64 {
    return checkedProduct(
        try checkedProduct(direction, multiplicity),
        try sourceSum(values),
    );
}

fn addSigned(current: f64, direction: f64, value: f64) !f64 {
    return checkedSum(current, try checkedProduct(direction, value));
}

fn sourceStructSum(value: anytype) !f64 {
    var total: f64 = 0;
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field|
        total = try checkedSum(total, @field(value, field.name));
    return total;
}

fn sourceSum(values: []const f64) !f64 {
    var total: f64 = 0;
    for (values) |value| total = try checkedSum(total, value);
    return total;
}

fn checkedProduct(left: f64, right: f64) !f64 {
    const result = left * right;
    if (!std.math.isFinite(result))
        return error.NonFiniteSedimentBoundaryResult;
    return result;
}

fn checkedSum(current: f64, increment: f64) !f64 {
    const result = current + increment;
    if (!std.math.isFinite(result))
        return error.NonFiniteSedimentBoundaryResult;
    return result;
}

fn validateFiniteStruct(value: anytype) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field|
        if (!std.math.isFinite(@field(value, field.name)))
            return error.InvalidSedimentBoundaryInput;
}

fn positiveFinite(value: f64) bool {
    return std.math.isFinite(value) and value > 0;
}

fn nonnegativeFinite(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field|
        @field(result, field.name) = value;
    return result;
}

fn unitOrganicDimensions() OrganicDimensions {
    return .{
        .microbial_class_count = 1,
        .microbial_group_count = 1,
        .microbial_component_count = 1,
        .residue_class_count = 1,
        .residue_component_count = 1,
        .soil_organic_component_count = 1,
    };
}

fn testFlux(
    sediment_megagrams_per_step: f64,
    scalar_value: f64,
    microbial: []const f64,
    residue: []const f64,
    adsorbed: []const f64,
    soil: []const f64,
) BoundaryFlux {
    return .{
        .sediment_megagrams_per_step = sediment_megagrams_per_step,
        .organic = .{
            .microbial_carbon_g_c_per_step = microbial,
            .microbial_nitrogen_g_n_per_step = microbial,
            .microbial_phosphorus_g_p_per_step = microbial,
            .residue_carbon_g_c_per_step = residue,
            .residue_nitrogen_g_n_per_step = residue,
            .residue_phosphorus_g_p_per_step = residue,
            .adsorbed_carbon_g_c_per_step = adsorbed,
            .adsorbed_acetate_carbon_g_c_per_step = adsorbed,
            .adsorbed_nitrogen_g_n_per_step = adsorbed,
            .adsorbed_phosphorus_g_p_per_step = adsorbed,
            .soil_organic_carbon_g_c_per_step = soil,
            .soil_organic_nitrogen_g_n_per_step = soil,
            .soil_organic_phosphorus_g_p_per_step = soil,
        },
        .nitrogen = filled(NitrogenMineralFlux, scalar_value),
        .phosphorus = filled(PhosphorusMineralFlux, scalar_value),
        .matrix_precipitates = filled(MatrixPrecipitateFlux, scalar_value),
        .adsorbed_salts = filled(AdsorbedSaltFlux, scalar_value),
        .sulfate_complexes = filled(SulfateComplexFlux, scalar_value),
    };
}

fn oneCellInputs(
    dimensions: OrganicDimensions,
    east: []const BoundaryFlux,
    zero: []const BoundaryFlux,
) Inputs {
    return .{
        .lon_count = 1,
        .lat_count = 1,
        .external_boundary_window = .{
            .first_column = 0,
            .last_column_inclusive = 0,
            .first_row = 0,
            .last_row_inclusive = 0,
        },
        .disturbance_mode = .freeze_thaw_and_erosion,
        .salt_equilibrium_mode = .dynamic,
        .organic_dimensions = dimensions,
        .flux_by_face = .{ east, zero, zero, zero },
        .negligible_sediment_megagrams_by_cell = &.{0},
        .nitrogen_g_n_per_mol_n = 14,
        .phosphorus_g_p_per_mol_p = 31,
    };
}

test "REDIST erosion fixture preserves source pool extents and weights" {
    const dimensions: OrganicDimensions = .{
        .microbial_class_count = 6,
        .microbial_group_count = 7,
        .microbial_component_count = 3,
        .residue_class_count = 5,
        .residue_component_count = 2,
        .soil_organic_component_count = 5,
    };
    const microbial_one = [_]f64{1} ** 126;
    const residue_one = [_]f64{1} ** 10;
    const adsorbed_one = [_]f64{1} ** 5;
    const soil_one = [_]f64{1} ** 25;
    const microbial_zero = [_]f64{0} ** 126;
    const residue_zero = [_]f64{0} ** 10;
    const adsorbed_zero = [_]f64{0} ** 5;
    const soil_zero = [_]f64{0} ** 25;
    const east = [_]BoundaryFlux{testFlux(
        1,
        1,
        &microbial_one,
        &residue_one,
        &adsorbed_one,
        &soil_one,
    )};
    const zero = [_]BoundaryFlux{testFlux(
        0,
        0,
        &microbial_zero,
        &residue_zero,
        &adsorbed_zero,
        &soil_zero,
    )};
    var cells = [_]CellOutwardLedger{.{}};
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };

    try apply(oneCellInputs(dimensions, &east, &zero), &state);

    try std.testing.expectEqual(@as(f64, 1), state.cumulative.sediment_megagrams);
    try std.testing.expectEqual(@as(f64, 171), state.cumulative.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 306), state.cumulative.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 786), state.cumulative.phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 124), state.cumulative.ion_components_mol);
    try std.testing.expectEqual(@as(f64, 171), cells[0].organic_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 166), cells[0].organic_nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 140), cells[0].inorganic_nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 166), cells[0].organic_phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 620), cells[0].inorganic_phosphorus_g_p);
}

test "disabled erosion and strict equal threshold leave ledgers unchanged" {
    const one = [_]f64{1};
    const zero_value = [_]f64{0};
    const east = [_]BoundaryFlux{testFlux(1, 1, &one, &one, &one, &one)};
    const zero = [_]BoundaryFlux{testFlux(
        0,
        0,
        &zero_value,
        &zero_value,
        &zero_value,
        &zero_value,
    )};
    const dimensions = unitOrganicDimensions();
    var cells = [_]CellOutwardLedger{.{}};
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };
    var inputs = oneCellInputs(dimensions, &east, &zero);
    inputs.disturbance_mode = .freeze_thaw;
    try apply(inputs, &state);
    inputs.disturbance_mode = .freeze_thaw_and_erosion;
    inputs.negligible_sediment_megagrams_by_cell = &.{1};
    try apply(inputs, &state);
    try std.testing.expectEqualDeep(CumulativeOutwardLedger{}, state.cumulative);
    try std.testing.expectEqualDeep(CellOutwardLedger{}, cells[0]);
}

test "static salt mode excludes ion components but retains nutrient mass" {
    const one = [_]f64{1};
    const zero_value = [_]f64{0};
    const east = [_]BoundaryFlux{testFlux(1, 1, &one, &one, &one, &one)};
    const zero = [_]BoundaryFlux{testFlux(
        0,
        0,
        &zero_value,
        &zero_value,
        &zero_value,
        &zero_value,
    )};
    var cells = [_]CellOutwardLedger{.{}};
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };
    var inputs = oneCellInputs(unitOrganicDimensions(), &east, &zero);
    inputs.salt_equilibrium_mode = .static;
    try apply(inputs, &state);
    try std.testing.expectEqual(@as(f64, 0), state.cumulative.ion_components_mol);
    try std.testing.expectEqual(@as(f64, 144), state.cumulative.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 624), state.cumulative.phosphorus_g_p);
}

test "fertilizer ammonium ion multiplicity follows boundary direction" {
    const one = [_]f64{1};
    var flux = testFlux(0, 0, &one, &one, &one, &one);
    flux.nitrogen.fertilizer_ammonium_non_band_mol_n_per_step = 1;
    flux.nitrogen.fertilizer_ammonium_band_mol_n_per_step = 1;
    try std.testing.expectEqual(
        @as(f64, -4),
        try dynamicIonComponents(flux, -1),
    );
    try std.testing.expectEqual(
        @as(f64, 4),
        try dynamicIonComponents(flux, 1),
    );
}

test "runtime grid conserves global ledgers against per-cell exports" {
    const one = [_]f64{1};
    const zero_value = [_]f64{0};
    const active = testFlux(1, 1, &one, &one, &one, &one);
    const inactive = testFlux(
        0,
        0,
        &zero_value,
        &zero_value,
        &zero_value,
        &zero_value,
    );
    const east = [_]BoundaryFlux{ inactive, active, inactive, active };
    const zero = [_]BoundaryFlux{ inactive, inactive, inactive, inactive };
    var cells = [_]CellOutwardLedger{ .{}, .{}, .{}, .{} };
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };
    try apply(.{
        .lon_count = 2,
        .lat_count = 2,
        .external_boundary_window = .{
            .first_column = 0,
            .last_column_inclusive = 1,
            .first_row = 0,
            .last_row_inclusive = 1,
        },
        .disturbance_mode = .freeze_thaw_erosion_and_organic_matter_change,
        .salt_equilibrium_mode = .dynamic,
        .organic_dimensions = unitOrganicDimensions(),
        .flux_by_face = .{ &east, &zero, &zero, &zero },
        .negligible_sediment_megagrams_by_cell = &.{ 0, 0, 0, 0 },
        .nitrogen_g_n_per_mol_n = 14,
        .phosphorus_g_p_per_mol_p = 31,
    }, &state);

    var sediment_megagrams: f64 = 0;
    var carbon_g_c: f64 = 0;
    var nitrogen_g_n: f64 = 0;
    var phosphorus_g_p: f64 = 0;
    var ion_components_mol: f64 = 0;
    for (cells) |cell| {
        sediment_megagrams += cell.sediment_megagrams;
        carbon_g_c += cell.organic_carbon_g_c + cell.inorganic_carbon_g_c;
        nitrogen_g_n += cell.organic_nitrogen_g_n + cell.inorganic_nitrogen_g_n;
        phosphorus_g_p +=
            cell.organic_phosphorus_g_p + cell.inorganic_phosphorus_g_p;
        ion_components_mol += cell.ion_components_mol;
    }
    try std.testing.expectEqual(state.cumulative.sediment_megagrams, sediment_megagrams);
    try std.testing.expectEqual(state.cumulative.carbon_g_c, carbon_g_c);
    try std.testing.expectEqual(state.cumulative.nitrogen_g_n, nitrogen_g_n);
    try std.testing.expectEqual(state.cumulative.phosphorus_g_p, phosphorus_g_p);
    try std.testing.expectEqual(state.cumulative.ion_components_mol, ion_components_mol);
}

test "invalid late mineral flux is rejected atomically" {
    const one = [_]f64{1};
    var east = [_]BoundaryFlux{
        testFlux(1, 1, &one, &one, &one, &one),
        testFlux(1, 1, &one, &one, &one, &one),
    };
    east[1].adsorbed_salts.iron_mol_per_step = std.math.nan(f64);
    const zero = [_]BoundaryFlux{
        testFlux(0, 0, &one, &one, &one, &one),
        testFlux(0, 0, &one, &one, &one, &one),
    };
    var cells = [_]CellOutwardLedger{ .{ .sediment_megagrams = 2 }, .{} };
    var state: State = .{
        .cumulative = .{ .sediment_megagrams = 3 },
        .outward_by_cell = &cells,
    };
    try std.testing.expectError(error.InvalidSedimentBoundaryInput, apply(.{
        .lon_count = 2,
        .lat_count = 1,
        .external_boundary_window = .{
            .first_column = 0,
            .last_column_inclusive = 1,
            .first_row = 0,
            .last_row_inclusive = 0,
        },
        .disturbance_mode = .freeze_thaw_and_erosion,
        .salt_equilibrium_mode = .dynamic,
        .organic_dimensions = unitOrganicDimensions(),
        .flux_by_face = .{ &east, &zero, &zero, &zero },
        .negligible_sediment_megagrams_by_cell = &.{ 0, 0 },
        .nitrogen_g_n_per_mol_n = 14,
        .phosphorus_g_p_per_mol_p = 31,
    }, &state));
    try std.testing.expectEqual(@as(f64, 3), state.cumulative.sediment_megagrams);
    try std.testing.expectEqual(@as(f64, 2), cells[0].sediment_megagrams);
    try std.testing.expectEqualDeep(CellOutwardLedger{}, cells[1]);
}

test "invalid organic dimensions and boundary window fail explicitly" {
    const one = [_]f64{1};
    const east = [_]BoundaryFlux{testFlux(1, 1, &one, &one, &one, &one)};
    const zero = [_]BoundaryFlux{testFlux(0, 0, &one, &one, &one, &one)};
    var cells = [_]CellOutwardLedger{.{}};
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };
    var inputs = oneCellInputs(unitOrganicDimensions(), &east, &zero);
    inputs.organic_dimensions.microbial_component_count = 2;
    try std.testing.expectError(
        error.InvalidSedimentBoundaryDimensions,
        apply(inputs, &state),
    );
    inputs.organic_dimensions.microbial_component_count = 1;
    inputs.external_boundary_window.first_column = 1;
    try std.testing.expectError(
        error.InvalidSedimentBoundaryWindow,
        apply(inputs, &state),
    );
}

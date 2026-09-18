//! `reaction_solver` declarations: phosphate.
//!
//! Split out of `reaction_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const aqueous_network = @import("aqueous_network.zig");
const phosphate_network = @import("phosphate_network.zig");
const cation_exchange = @import("cation_exchange.zig");
const geochemistry = @import("geochemistry_network.zig");
const aqueous_rates = @import("aqueous_reaction_rates.zig");
const phosphate_rates = @import("phosphate_reaction_rates.zig");
const geochemistry_rates = @import("geochemistry_reaction_rates.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("reaction_search_span.zig");
const group_apply = @import("reaction_solver_apply.zig");
const group_candidates = @import("reaction_solver_candidates.zig");
const group_numerics = @import("reaction_solver_numerics.zig");
const group_numerics2 = @import("reaction_solver_numerics2.zig");
const group_solve = @import("reaction_solver_solve.zig");
const group_types = @import("reaction_solver_types.zig");

const PhosphateExtentBounds = struct {
    lower_mol_per_m3: f64,
    upper_mol_per_m3: f64,
};

pub fn phosphateExtentBounds(
    current: []const f64,
    reaction: group_types.CoupledExtentReaction,
    parameters: chemistry.ReactionParameters,
    options: group_types.Options,
) PhosphateExtentBounds {
    return .{
        .lower_mol_per_m3 = -options.maximum_newton_fraction *
            maximumPhosphateExtent(current, reaction, -1, parameters),
        .upper_mol_per_m3 = options.maximum_newton_fraction *
            maximumPhosphateExtent(current, reaction, 1, parameters),
    };
}

pub fn evaluatePhosphateExtentResiduals(
    scratch: *chemistry.State,
    vector: []const f64,
    parameters: chemistry.ReactionParameters,
    output: []f64,
) !void {
    if (output.len != group_types.coupled_extent_reaction_count)
        return error.PhosphateExtentVectorSizeMismatch;
    try scratch.unpackCell(0, vector);
    const initial_coefficients =
        try scratch.activityCoefficients(0, parameters.fractions);
    const water = try water_equilibrium.solve(.{
        .hydrogen_concentration_mol_per_m3 = scratch.aqueous[0].hydrogen,
        .hydroxide_concentration_mol_per_m3 = scratch.aqueous[0].hydroxide,
        .monovalent_activity_coefficient = initial_coefficients.monovalent_activity_coefficient,
        .water_activity_product_mol2_per_m6 = parameters.water_activity_product_mol2_per_m6,
        .negligible_concentration_mol_per_m3 = parameters.negligible_water_ion_concentration_mol_per_m3,
    });
    scratch.aqueous[0].hydrogen =
        water.hydrogen_concentration_mol_per_m3;
    scratch.aqueous[0].hydroxide =
        water.hydroxide_concentration_mol_per_m3;
    const coefficients =
        try scratch.activityCoefficients(0, parameters.fractions);
    for (0..2) |zone_index| {
        const fraction = phosphateZoneFraction(parameters, zone_index);
        const offset = zone_index * 8;
        if (fraction == 0) {
            @memset(output[offset..][0..8], 0);
            continue;
        }
        const density = phosphateZoneDensity(parameters, zone_index);
        const zone = if (zone_index == 0)
            scratch.non_band_phosphate[0]
        else
            scratch.band_phosphate[0];
        const fluxes = try phosphate_rates.calculate(
            scratch.aqueous[0],
            zone,
            coefficients,
            density,
            parameters.phosphate_constants,
            parameters.phosphate_surface,
            parameters.phosphate_minerals,
            parameters.phosphate_kinetics,
        );
        output[offset] =
            fluxes.aqueous.hpo4_hydrogen_association_mol_p_per_m3;
        output[offset + 1] =
            fluxes.aqueous.iron_hpo4_pairing_mol_p_per_m3;
        output[offset + 2] =
            fluxes.aqueous.iron_h2po4_pairing_mol_p_per_m3;
        output[offset + 3] =
            fluxes.aqueous.calcium_hpo4_pairing_mol_p_per_m3;
        output[offset + 4] =
            fluxes.aqueous.calcium_h2po4_pairing_mol_p_per_m3;
        output[offset + 5] =
            fluxes.surface.h2po4_with_protonated_site_mol_p_per_megagram *
            density;
        output[offset + 6] =
            fluxes.surface.h2po4_with_hydroxyl_site_mol_p_per_megagram *
            density;
        output[offset + 7] =
            fluxes.surface.hpo4_with_hydroxyl_site_mol_p_per_megagram *
            density;
    }
    const aqueous_fluxes = try aqueous_rates.calculate(
        scratch.aqueous[0],
        coefficients,
        parameters.aqueous_constants,
        parameters.aqueous_kinetics,
    );
    output[
        @intFromEnum(
            group_types.CoupledExtentReaction.aqueous_calcium_hydroxide_pairing,
        )
    ] = aqueous_fluxes.calcium_hydroxide_association;
    output[
        @intFromEnum(
            group_types.CoupledExtentReaction.aqueous_calcium_carbonate_pairing,
        )
    ] = aqueous_fluxes.calcium_carbonate_association;
    output[
        @intFromEnum(
            group_types.CoupledExtentReaction.aqueous_calcium_bicarbonate_pairing,
        )
    ] = aqueous_fluxes.calcium_bicarbonate_association;
    output[
        @intFromEnum(
            group_types.CoupledExtentReaction.aqueous_calcium_sulfate_pairing,
        )
    ] = aqueous_fluxes.calcium_sulfate_association;
}

pub fn applyPhosphateExtent(
    vector: []f64,
    reaction: group_types.CoupledExtentReaction,
    extent_mol_per_m3: f64,
    parameters: chemistry.ReactionParameters,
) bool {
    if (!std.math.isFinite(extent_mol_per_m3)) return false;
    const ordinal: usize = @intFromEnum(reaction);
    if (ordinal >= 16) {
        switch (reaction) {
            .aqueous_calcium_hydroxide_pairing => group_apply.applyAqueousCalciumExtent(
                vector,
                "hydroxide",
                "calcium_hydroxide",
                extent_mol_per_m3,
            ),
            .aqueous_calcium_carbonate_pairing => group_apply.applyAqueousCalciumExtent(
                vector,
                "carbonate",
                "calcium_carbonate",
                extent_mol_per_m3,
            ),
            .aqueous_calcium_bicarbonate_pairing => group_apply.applyAqueousCalciumExtent(
                vector,
                "bicarbonate",
                "calcium_bicarbonate",
                extent_mol_per_m3,
            ),
            .aqueous_calcium_sulfate_pairing => group_apply.applyAqueousCalciumExtent(
                vector,
                "sulfate",
                "calcium_sulfate",
                extent_mol_per_m3,
            ),
            else => unreachable,
        }
        for (vector) |value| if (!std.math.isFinite(value)) return false;
        return true;
    }
    const zone_index = ordinal / 8;
    const family = ordinal % 8;
    const fraction = phosphateZoneFraction(parameters, zone_index);
    const density = phosphateZoneDensity(parameters, zone_index);
    if (!std.math.isFinite(fraction) or fraction <= 0 or
        !std.math.isFinite(density) or density <= 0)
    {
        return false;
    }
    switch (family) {
        0 => {
            group_apply.addPacked(
                vector,
                phosphatePackedIndex(zone_index, "dissolved_hpo4_mol_p_per_m3"),
                -extent_mol_per_m3,
            );
            group_apply.addPacked(
                vector,
                phosphatePackedIndex(zone_index, "dissolved_h2po4_mol_p_per_m3"),
                extent_mol_per_m3,
            );
            group_apply.addPacked(
                vector,
                group_numerics2.aqueousPackedIndex("hydrogen"),
                -fraction * extent_mol_per_m3,
            );
        },
        1 => applyPhosphatePairingExtent(
            vector,
            zone_index,
            fraction,
            "iron",
            "dissolved_hpo4_mol_p_per_m3",
            "iron_hpo4_pair_mol_per_m3",
            extent_mol_per_m3,
        ),
        2 => applyPhosphatePairingExtent(
            vector,
            zone_index,
            fraction,
            "iron",
            "dissolved_h2po4_mol_p_per_m3",
            "iron_h2po4_pair_mol_per_m3",
            extent_mol_per_m3,
        ),
        3 => applyPhosphatePairingExtent(
            vector,
            zone_index,
            fraction,
            "calcium",
            "dissolved_hpo4_mol_p_per_m3",
            "calcium_hpo4_pair_mol_per_m3",
            extent_mol_per_m3,
        ),
        4 => applyPhosphatePairingExtent(
            vector,
            zone_index,
            fraction,
            "calcium",
            "dissolved_h2po4_mol_p_per_m3",
            "calcium_h2po4_pair_mol_per_m3",
            extent_mol_per_m3,
        ),
        5 => {
            group_apply.applySiteExchangeExtent(
                vector,
                zone_index,
                density,
                "dissolved_h2po4_mol_p_per_m3",
                "protonated_site_mol_per_megagram",
                "adsorbed_h2po4_mol_p_per_megagram",
                extent_mol_per_m3,
            );
            group_apply.addPacked(
                vector,
                chemistry.State.packedComponentCount() - 1,
                fraction * extent_mol_per_m3,
            );
        },
        6 => {
            group_apply.applySiteExchangeExtent(
                vector,
                zone_index,
                density,
                "dissolved_h2po4_mol_p_per_m3",
                "hydroxyl_site_mol_per_megagram",
                "adsorbed_h2po4_mol_p_per_megagram",
                extent_mol_per_m3,
            );
            group_apply.addPacked(
                vector,
                group_numerics2.aqueousPackedIndex("hydroxide"),
                fraction * extent_mol_per_m3,
            );
        },
        7 => {
            group_apply.applySiteExchangeExtent(
                vector,
                zone_index,
                density,
                "dissolved_hpo4_mol_p_per_m3",
                "hydroxyl_site_mol_per_megagram",
                "adsorbed_hpo4_mol_p_per_megagram",
                extent_mol_per_m3,
            );
            group_apply.addPacked(
                vector,
                group_numerics2.aqueousPackedIndex("hydroxide"),
                fraction * extent_mol_per_m3,
            );
        },
        else => unreachable,
    }
    for (vector) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

fn applyPhosphatePairingExtent(
    vector: []f64,
    zone_index: usize,
    fraction: f64,
    comptime aqueous_metal_name: []const u8,
    comptime dissolved_phosphate_name: []const u8,
    comptime pair_name: []const u8,
    extent_mol_per_m3: f64,
) void {
    group_apply.addPacked(
        vector,
        phosphatePackedIndex(zone_index, dissolved_phosphate_name),
        -extent_mol_per_m3,
    );
    group_apply.addPacked(
        vector,
        phosphatePackedIndex(zone_index, pair_name),
        extent_mol_per_m3,
    );
    group_apply.addPacked(
        vector,
        group_numerics2.aqueousPackedIndex(aqueous_metal_name),
        -fraction * extent_mol_per_m3,
    );
}

pub fn maximumPhosphateExtent(
    vector: []const f64,
    reaction: group_types.CoupledExtentReaction,
    direction: f64,
    parameters: chemistry.ReactionParameters,
) f64 {
    const ordinal: usize = @intFromEnum(reaction);
    if (ordinal >= 16) return switch (reaction) {
        .aqueous_calcium_hydroxide_pairing => group_numerics2.maximumAqueousCalciumExtent(
            vector,
            "hydroxide",
            "calcium_hydroxide",
            direction,
        ),
        .aqueous_calcium_carbonate_pairing => group_numerics2.maximumAqueousCalciumExtent(
            vector,
            "carbonate",
            "calcium_carbonate",
            direction,
        ),
        .aqueous_calcium_bicarbonate_pairing => group_numerics2.maximumAqueousCalciumExtent(
            vector,
            "bicarbonate",
            "calcium_bicarbonate",
            direction,
        ),
        .aqueous_calcium_sulfate_pairing => group_numerics2.maximumAqueousCalciumExtent(
            vector,
            "sulfate",
            "calcium_sulfate",
            direction,
        ),
        else => unreachable,
    };
    const zone_index = ordinal / 8;
    const family = ordinal % 8;
    const fraction = phosphateZoneFraction(parameters, zone_index);
    const density = phosphateZoneDensity(parameters, zone_index);
    if (fraction <= 0 or density <= 0) return 0;
    const hpo4 = vector[
        phosphatePackedIndex(zone_index, "dissolved_hpo4_mol_p_per_m3")
    ];
    const h2po4 = vector[
        phosphatePackedIndex(zone_index, "dissolved_h2po4_mol_p_per_m3")
    ];
    if (direction > 0) return switch (family) {
        0 => @min(
            hpo4,
            vector[group_numerics2.aqueousPackedIndex("hydrogen")] / fraction,
        ),
        1 => @min(hpo4, vector[group_numerics2.aqueousPackedIndex("iron")] / fraction),
        2 => @min(h2po4, vector[group_numerics2.aqueousPackedIndex("iron")] / fraction),
        3 => @min(
            hpo4,
            vector[group_numerics2.aqueousPackedIndex("calcium")] / fraction,
        ),
        4 => @min(h2po4, vector[group_numerics2.aqueousPackedIndex("calcium")] / fraction),
        5 => @min(
            h2po4,
            density * vector[
                phosphatePackedIndex(zone_index, "protonated_site_mol_per_megagram")
            ],
        ),
        6 => @min(
            h2po4,
            density * vector[
                phosphatePackedIndex(zone_index, "hydroxyl_site_mol_per_megagram")
            ],
        ),
        7 => @min(
            hpo4,
            density * vector[
                phosphatePackedIndex(zone_index, "hydroxyl_site_mol_per_megagram")
            ],
        ),
        else => unreachable,
    };
    return switch (family) {
        0 => h2po4,
        1 => vector[
            phosphatePackedIndex(zone_index, "iron_hpo4_pair_mol_per_m3")
        ],
        2 => vector[
            phosphatePackedIndex(zone_index, "iron_h2po4_pair_mol_per_m3")
        ],
        3 => vector[
            phosphatePackedIndex(zone_index, "calcium_hpo4_pair_mol_per_m3")
        ],
        4 => vector[
            phosphatePackedIndex(zone_index, "calcium_h2po4_pair_mol_per_m3")
        ],
        // SOLUTE-037. The three site-exchange desorption limits are the
        // adsorbed pool alone, matching `starte.f` 657--677 and
        // `solute.f` 1018--1054, where every reverse bound reads
        // `XMINN=FIONX*XH2P1` or `FIONX*XH1P1` and NO reverse bound names
        // `AOH1`, `COH1`, or a water term. The forward bounds keep their
        // source co-substrates (`XMINP=FIONX*AMIN1(CH2P1,XOH21)`), which is
        // why only the `direction < 0` branch changes here.
        //
        // The removed `hydroxide / fraction` term treated OH- as a
        // depletable reservoir. It is not one: `starte.f` 440 fixes
        // `AOH1=DPH2O/AHY1` and `solute_water_equilibrium.projectProvisional`
        // re-derives both ions from the water product every candidate, so
        // OH- is a function of pH and is instantly replenished. Capping
        // desorption at the standing OH- concentration is therefore a bound
        // on a quantity that is never consumed.
        //
        // It was also ABSORBING in exactly one direction, which is what
        // gated the corpus. In `Boreal Black Spruce MB` cell 0, OH- is
        // `1.9953e-7 mol m-3` at pH 4.3 while the adsorption side is bounded
        // by `min(H2PO4, density * hydroxyl_site)`, which is seven orders of
        // magnitude larger. So the solver could adsorb freely and could
        // desorb at most `~2e-7` per iteration against a residual of
        // `~4e-2`. `phosphate_non_band.adsorbed_h2po4_mol_p_per_megagram`
        // then ratchets monotonically from its seeded `1.4353e-1` to
        // `4.2723e0`, a 30x accumulation that is still growing (`change =
        // +3.9668e-2`) at the reported stagnation. A one-sided rate bound
        // presents as a plateau and looks like an iteration-budget problem
        // while not being one; no ceiling is raised and no tolerance is
        // relaxed here.
        //
        // The `water_mol_per_m3` term on family 5 is removed for the same
        // source reason. It is numerically inactive (water is `5.5556e4`),
        // so this part is a source-fidelity correction, not a behaviour
        // change.
        5 => density * vector[
            phosphatePackedIndex(zone_index, "adsorbed_h2po4_mol_p_per_megagram")
        ],
        6 => density * vector[
            phosphatePackedIndex(zone_index, "adsorbed_h2po4_mol_p_per_megagram")
        ],
        7 => density * vector[
            phosphatePackedIndex(zone_index, "adsorbed_hpo4_mol_p_per_megagram")
        ],
        else => unreachable,
    };
}

pub fn phosphateExtentCharacteristic(
    vector: []const f64,
    reaction: group_types.CoupledExtentReaction,
    parameters: chemistry.ReactionParameters,
) f64 {
    return @max(
        maximumPhosphateExtent(vector, reaction, 1, parameters),
        maximumPhosphateExtent(vector, reaction, -1, parameters),
    );
}

fn phosphateZoneFraction(
    parameters: chemistry.ReactionParameters,
    zone_index: usize,
) f64 {
    return if (zone_index == 0)
        parameters.fractions.phosphate_non_band
    else
        parameters.fractions.phosphate_band;
}

fn phosphateZoneDensity(
    parameters: chemistry.ReactionParameters,
    zone_index: usize,
) f64 {
    return if (zone_index == 0)
        parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3
    else
        parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
}

pub fn phosphateExtentControlsPackedIndex(index: usize) bool {
    if (index == group_numerics2.aqueousPackedIndex("hydrogen") or
        index == group_numerics2.aqueousPackedIndex("hydroxide") or
        index == group_numerics2.aqueousPackedIndex("iron") or
        index == group_numerics2.aqueousPackedIndex("calcium") or
        index == group_numerics2.aqueousPackedIndex("magnesium") or
        index == group_numerics2.aqueousPackedIndex("carbonate") or
        index == group_numerics2.aqueousPackedIndex("bicarbonate") or
        index == group_numerics2.aqueousPackedIndex("sulfate") or
        index == group_numerics2.aqueousPackedIndex("calcium_hydroxide") or
        index == group_numerics2.aqueousPackedIndex("calcium_carbonate") or
        index == group_numerics2.aqueousPackedIndex("calcium_bicarbonate") or
        index == group_numerics2.aqueousPackedIndex("calcium_sulfate") or
        index == chemistry.State.packedComponentCount() - 1)
    {
        return true;
    }
    return phosphateZoneExtentControlsPackedIndex(index);
}

pub fn phosphateZoneExtentControlsPackedIndex(index: usize) bool {
    for (0..2) |zone_index| {
        inline for (.{
            "dissolved_po4_mol_p_per_m3",
            "dissolved_hpo4_mol_p_per_m3",
            "dissolved_h2po4_mol_p_per_m3",
            "dissolved_h3po4_mol_p_per_m3",
            "iron_hpo4_pair_mol_per_m3",
            "iron_h2po4_pair_mol_per_m3",
            "calcium_hpo4_pair_mol_per_m3",
            "calcium_h2po4_pair_mol_per_m3",
            "protonated_site_mol_per_megagram",
            "hydroxyl_site_mol_per_megagram",
            "adsorbed_h2po4_mol_p_per_megagram",
            "adsorbed_hpo4_mol_p_per_megagram",
        }) |field_name| {
            if (index == phosphatePackedIndex(zone_index, field_name))
                return true;
        }
    }
    return false;
}

pub fn largestPhosphateZoneScaledResidual(
    current: []const f64,
    residual: []const f64,
    options: group_types.Options,
) f64 {
    var largest: f64 = 0;
    for (current, residual, 0..) |value, change, index| {
        if (!phosphateZoneExtentControlsPackedIndex(index)) continue;
        largest = @max(
            largest,
            @abs(change) / group_numerics.residualScale(value, index, options),
        );
    }
    return largest;
}

pub fn phosphatePackedIndex(
    zone_index: usize,
    comptime field_name: []const u8,
) usize {
    const aqueous_count =
        @typeInfo(aqueous_network.State).@"struct".fields.len;
    const phosphate_count =
        @typeInfo(phosphate_network.State).@"struct".fields.len;
    return aqueous_count + zone_index * phosphate_count +
        std.meta.fieldIndex(phosphate_network.State, field_name).?;
}

pub fn phosphateTrustRegionFraction(
    current: []const f64,
    target: []const f64,
    options: group_types.Options,
    maximum_relative_change: f64,
) f64 {
    if (maximum_relative_change <= 0) return 1;
    const aqueous_count = @typeInfo(aqueous_network.State).@"struct".fields.len;
    const phosphate_count = @typeInfo(phosphate_network.State).@"struct".fields.len;
    // Do not let the neighboring HPO4 branch prevent a conservative trial
    // from landing exactly on an H2PO4 nonnegativity boundary. The candidate
    // still must pass the same global monotonic merit test, and the next map
    // evaluation determines whether the boundary remains active.
    for (0..2) |zone| {
        const h2po4_index = aqueous_count + zone * phosphate_count + 2;
        if (current[h2po4_index] > options.absolute_tolerance_mol_per_m3 and
            target[h2po4_index] <= options.absolute_tolerance_mol_per_m3)
            return 1;
    }
    var fraction: f64 = 1;
    for (0..2) |zone| {
        const index = aqueous_count + zone * phosphate_count + 1;
        const from = current[index];
        const to = target[index];
        const change = @abs(to - from);
        if (change == 0) continue;
        const scale = group_numerics.residualScale(from, index, options);
        fraction = @min(
            fraction,
            @max(maximum_relative_change, options.picard_relaxation) *
                @max(@abs(from), scale) / change,
        );
    }
    return std.math.clamp(fraction, std.math.floatEps(f64), 1);
}
pub const tryPhosphateExtentCandidate = group_candidates.__try.tryPhosphateExtentCandidate;
pub const solveBoundedPhosphateExtents = group_solve.__solve.solveBoundedPhosphateExtents;

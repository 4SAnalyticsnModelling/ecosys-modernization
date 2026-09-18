//! Tests for `fertilizer_dissolution.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const aqueous_network = @import("../solute/aqueous_network.zig");
const dissolution_module = @import("fertilizer_dissolution.zig");

test "SOLUTE layer admission preserves strict thickness and water gates" {
    const active: dissolution_module.LayerReactionAdmissionInputs = .{
        .layer_thickness_m = 0.1,
        .minimum_layer_thickness_m = 1.0e-6,
        .water_volume_m3 = 0.02,
        .minimum_water_volume_m3 = 1.0e-12,
    };
    try std.testing.expect(try dissolution_module.admitsLayerReactions(active));

    var boundary = active;
    boundary.layer_thickness_m = boundary.minimum_layer_thickness_m;
    try std.testing.expect(!try dissolution_module.admitsLayerReactions(boundary));
    boundary = active;
    boundary.water_volume_m3 = boundary.minimum_water_volume_m3;
    try std.testing.expect(!try dissolution_module.admitsLayerReactions(boundary));
}

test "SOLUTE layer admission rejects invalid physical inputs" {
    const invalid: dissolution_module.LayerReactionAdmissionInputs = .{
        .layer_thickness_m = 0.1,
        .minimum_layer_thickness_m = 0,
        .water_volume_m3 = std.math.nan(f64),
        .minimum_water_volume_m3 = 0,
    };
    try std.testing.expectError(
        error.InvalidLayerReactionAdmissionInput,
        dissolution_module.admitsLayerReactions(invalid),
    );
}

test "SOLUTE layer zones use soil mass normalization when BKVL is positive" {
    const result = try dissolution_module.prepareLayerZones(.{
        .water_volume_m3 = 8,
        .soil_mass_megagrams = 12,
        .soil_volume_m3 = 10,
        .fractions = .{
            .ammonium_non_band = 0.75,
            .ammonium_band = 0.25,
            .nitrate_non_band = 0.6,
            .nitrate_band = 0.4,
            .phosphate_non_band = 0.8,
            .phosphate_band = 0.2,
        },
        .positive_soil_mass_threshold_megagrams = 1.0e-12,
    });

    try std.testing.expectEqual(@as(f64, 6), result.ammonium_non_band_water_m3);
    try std.testing.expectEqual(@as(f64, 2), result.ammonium_band_water_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 4.8), result.nitrate_non_band_water_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3.2), result.nitrate_band_water_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 6.4), result.phosphate_non_band_water_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.6), result.phosphate_band_water_m3, 1.0e-15);
    try std.testing.expectEqual(@as(f64, 12), result.whole_layer_normalization_basis);
    try std.testing.expectEqual(@as(f64, 9), result.ammonium_non_band_normalization_basis);
    try std.testing.expectEqual(@as(f64, 3), result.ammonium_band_normalization_basis);
    try std.testing.expectApproxEqAbs(@as(f64, 7.2), result.nitrate_non_band_normalization_basis, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4.8), result.nitrate_band_normalization_basis, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9.6), result.phosphate_non_band_normalization_basis, 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), result.phosphate_band_normalization_basis, 1.0e-15);
}

test "SOLUTE layer zones preserve zero-BKVL water-volume fallback" {
    const result = try dissolution_module.prepareLayerZones(.{
        .water_volume_m3 = 8,
        .soil_mass_megagrams = 0,
        .soil_volume_m3 = 10,
        .fractions = .{
            .ammonium_non_band = 0.75,
            .ammonium_band = 0.25,
            .nitrate_non_band = 0.6,
            .nitrate_band = 0.4,
            .phosphate_non_band = 0.8,
            .phosphate_band = 0.2,
        },
        .positive_soil_mass_threshold_megagrams = 1.0e-12,
    });

    try std.testing.expectEqual(@as(f64, 10), result.whole_layer_normalization_basis);
    try std.testing.expectEqual(result.ammonium_non_band_water_m3, result.ammonium_non_band_normalization_basis);
    try std.testing.expectEqual(result.ammonium_band_water_m3, result.ammonium_band_normalization_basis);
    try std.testing.expectEqual(result.nitrate_non_band_water_m3, result.nitrate_non_band_normalization_basis);
    try std.testing.expectEqual(result.nitrate_band_water_m3, result.nitrate_band_normalization_basis);
    try std.testing.expectEqual(result.phosphate_non_band_water_m3, result.phosphate_non_band_normalization_basis);
    try std.testing.expectEqual(result.phosphate_band_water_m3, result.phosphate_band_normalization_basis);
}

test "SOLUTE zone mass-water ratios cancel matched source fractions" {
    const prepared = try dissolution_module.prepareLayerZones(.{
        .water_volume_m3 = 8,
        .soil_mass_megagrams = 12,
        .soil_volume_m3 = 10,
        .fractions = .{
            .ammonium_non_band = 0.75,
            .ammonium_band = 0.25,
            .nitrate_non_band = 0.6,
            .nitrate_band = 0.4,
            .phosphate_non_band = 0.8,
            .phosphate_band = 0.2,
        },
        .positive_soil_mass_threshold_megagrams = 1.0e-12,
    });
    const expected_ammonium_non_band_ratio =
        prepared.ammonium_non_band_normalization_basis /
        prepared.ammonium_non_band_water_m3;
    const expected_ammonium_band_ratio =
        prepared.ammonium_band_normalization_basis /
        prepared.ammonium_band_water_m3;
    const expected_phosphate_non_band_ratio =
        prepared.phosphate_non_band_normalization_basis /
        prepared.phosphate_non_band_water_m3;
    try std.testing.expectEqual(
        expected_ammonium_non_band_ratio,
        try dissolution_module.normalizationBasisPerWaterVolume(
            prepared.ammonium_non_band_normalization_basis,
            prepared.ammonium_non_band_water_m3,
        ),
    );
    try std.testing.expectEqual(
        expected_ammonium_band_ratio,
        try dissolution_module.normalizationBasisPerWaterVolume(
            prepared.ammonium_band_normalization_basis,
            prepared.ammonium_band_water_m3,
        ),
    );
    try std.testing.expectEqual(
        expected_phosphate_non_band_ratio,
        try dissolution_module.normalizationBasisPerWaterVolume(
            prepared.phosphate_non_band_normalization_basis,
            prepared.phosphate_non_band_water_m3,
        ),
    );
}

test "SOLUTE zero-width zone publishes zero normalization ratio" {
    try std.testing.expectEqual(
        @as(f64, 0),
        try dissolution_module.normalizationBasisPerWaterVolume(0, 0),
    );
    try std.testing.expectError(
        error.InvalidLayerZoneNormalization,
        dissolution_module.normalizationBasisPerWaterVolume(1, std.math.nan(f64)),
    );
}

test "SOLUTE lines 327-338 retain fertilizer flux assignment order" {
    const expected_names = [_][]const u8{
        "broadcast_ammonium_non_band_mol_n",
        "broadcast_ammonia_non_band_mol_n",
        "broadcast_urea_non_band_mol_n",
        "broadcast_nitrate_non_band_mol_n",
        "broadcast_ammonium_band_mol_n",
        "broadcast_ammonia_band_mol_n",
        "broadcast_urea_band_mol_n",
        "broadcast_nitrate_band_mol_n",
        "banded_ammonium_mol_n",
        "banded_ammonia_mol_n",
        "banded_urea_mol_n",
        "banded_nitrate_mol_n",
    };
    inline for (@typeInfo(dissolution_module.DissolutionFlux).@"struct".fields, 0..) |field, index|
        try std.testing.expectEqualStrings(expected_names[index], field.name);
}

test "urea hydrolysis uses legacy TOQCK / VOLQ / TFNQ operands" {
    const toqck_g_c_per_step = 45.0;
    const volq_m3 = 3.0;
    const temperature_factor = 1.5;
    const soil_mass_megagrams = 2.0;
    const water_volume_m3 = 6.0;
    const broadcast_urea_mol_n = 10.0;
    const banded_urea_mol_n = 4.0;
    const specific_hydrolysis = 0.2;
    const microbial_activity_inhibition = 15.0;
    const minimum_half_saturation = 0.5;
    const initial_inhibitor = 0.8;
    const current_inhibitor = 0.4;
    const inhibitor_decline = 0.05;
    const timestep_h = 1.0;

    const coqck = @min(0.1e6, toqck_g_c_per_step / (volq_m3 * timestep_h));
    const expected_effective_half_saturation = minimum_half_saturation * (1 + coqck / microbial_activity_inhibition);
    const broadcast_fraction = (broadcast_urea_mol_n / soil_mass_megagrams) / (broadcast_urea_mol_n / soil_mass_megagrams + expected_effective_half_saturation);
    const banded_fraction = (banded_urea_mol_n / soil_mass_megagrams) / (banded_urea_mol_n / soil_mass_megagrams + expected_effective_half_saturation);
    const expected_decline_per_step = inhibitor_decline * timestep_h;
    const expected_inhibitor_decline_rate = expected_decline_per_step * current_inhibitor *
        @max(expected_decline_per_step, 1 - current_inhibitor / initial_inhibitor);
    const expected_next_inhibitor = current_inhibitor - expected_inhibitor_decline_rate;
    const expected_common_hydrolysis_capacity = specific_hydrolysis * timestep_h *
        toqck_g_c_per_step * temperature_factor * (1 - expected_next_inhibitor);
    const result = try dissolution_module.ureaHydrolysis(
        .{
            .broadcast_urea_mol_n = broadcast_urea_mol_n,
            .banded_urea_mol_n = banded_urea_mol_n,
            .soil_mass_megagrams = soil_mass_megagrams,
            .water_volume_m3 = water_volume_m3,
            .biologically_active_water_volume_m3 = volq_m3,
            .total_microbial_respiration_activity_g_c_per_step = toqck_g_c_per_step,
            .temperature_response = temperature_factor,
            .initial_inhibitor_activity = initial_inhibitor,
            .current_inhibitor_activity = current_inhibitor,
            .timestep_h = timestep_h,
        },
        .{
            .minimum_half_saturation_mol_n_per_megagram = minimum_half_saturation,
            .microbial_activity_inhibition_g_c_per_m3_h = microbial_activity_inhibition,
            .specific_hydrolysis_mol_n_per_g_c_h = specific_hydrolysis,
            .inhibitor_decline_rate_per_h = inhibitor_decline,
            .negligible_biologically_active_water_m3 = 1e-12,
            .negligible_inhibitor_activity = 1e-12,
            .negligible_fertilizer_amount_mol_n = 1e-12,
            .negligible_soil_mass_megagrams = 1e-12,
            .negligible_water_volume_m3 = 1e-12,
            .physical_relative_tolerance = 1e-12,
        },
    );
    try std.testing.expectApproxEqAbs(@min(broadcast_urea_mol_n, expected_common_hydrolysis_capacity * broadcast_fraction), result.broadcast_hydrolysis_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(@min(banded_urea_mol_n, expected_common_hydrolysis_capacity * banded_fraction), result.banded_hydrolysis_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_effective_half_saturation, result.effective_half_saturation_mol_n_per_megagram, 1e-12);
    try std.testing.expectApproxEqAbs(expected_next_inhibitor, result.next_inhibitor_activity, 1e-12);
}

test "first fertilizer boundary state_updates legacy-formula hydrolysis and dissolution_module.dissolution to aqueous state" {
    const toqck_g_c_per_step = 90.0;
    const volq_m3 = 4.0;
    const tfnq = 1.25;
    const timestep_h = 1.0;
    const water_volume_m3 = 12.0;
    const soil_mass_megagrams = 8.0;
    const water_content_m3_per_m3 = 0.6;
    const broadcast_urea_mol_n = 10.0;
    const banded_urea_mol_n = 4.0;
    const broadcast_ammonium_mol_n = 6.0;
    const banded_ammonium_mol_n = 2.0;
    const broadcast_ammonia_mol_n = 3.0;
    const banded_ammonia_mol_n = 1.0;
    const broadcast_nitrate_mol_n = 5.0;
    const banded_nitrate_mol_n = 7.0;

    const fractions: dissolution_module.ZoneFractions = .{
        .ammonium_non_band = 0.3,
        .ammonium_band = 0.7,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
    };
    const rates: dissolution_module.DissolutionRates = .{
        .ammonium_per_h = 0.2,
        .ammonia_per_h = 0.1,
        .nitrate_per_h = 0.4,
    };
    const initial_state: dissolution_module.FertilizerState = .{
        .broadcast_ammonium_mol_n = broadcast_ammonium_mol_n,
        .broadcast_ammonia_mol_n = broadcast_ammonia_mol_n,
        .broadcast_urea_mol_n = broadcast_urea_mol_n,
        .broadcast_nitrate_mol_n = broadcast_nitrate_mol_n,
        .banded_ammonium_mol_n = banded_ammonium_mol_n,
        .banded_ammonia_mol_n = banded_ammonia_mol_n,
        .banded_urea_mol_n = banded_urea_mol_n,
        .banded_nitrate_mol_n = banded_nitrate_mol_n,
    };
    const fertilizer_parameters: dissolution_module.UreaParameters = .{
        .minimum_half_saturation_mol_n_per_megagram = 1.5,
        .microbial_activity_inhibition_g_c_per_m3_h = 30,
        .specific_hydrolysis_mol_n_per_g_c_h = 0.018,
        .inhibitor_decline_rate_per_h = 0.0,
        .negligible_biologically_active_water_m3 = 1e-12,
        .negligible_inhibitor_activity = 1e-12,
        .negligible_fertilizer_amount_mol_n = 1e-12,
        .negligible_soil_mass_megagrams = 1e-12,
        .negligible_water_volume_m3 = 1e-12,
        .physical_relative_tolerance = 1e-12,
    };

    const hydrolysis = try dissolution_module.ureaHydrolysis(
        .{
            .broadcast_urea_mol_n = broadcast_urea_mol_n,
            .banded_urea_mol_n = banded_urea_mol_n,
            .soil_mass_megagrams = soil_mass_megagrams,
            .water_volume_m3 = water_volume_m3,
            .biologically_active_water_volume_m3 = volq_m3,
            .total_microbial_respiration_activity_g_c_per_step = toqck_g_c_per_step,
            .temperature_response = tfnq,
            .initial_inhibitor_activity = 1.0,
            .current_inhibitor_activity = 0.2,
            .timestep_h = timestep_h,
        },
        fertilizer_parameters,
    );
    const coqck = @min(1.0e6, toqck_g_c_per_step / (volq_m3 * timestep_h));
    const expected_effective_half_saturation = fertilizer_parameters.minimum_half_saturation_mol_n_per_megagram * (1 + coqck / fertilizer_parameters.microbial_activity_inhibition_g_c_per_m3_h);
    const broadcast_urea_concentration = broadcast_urea_mol_n / soil_mass_megagrams;
    const banded_urea_concentration = banded_urea_mol_n / soil_mass_megagrams;
    const broadcast_limitation = broadcast_urea_concentration / (broadcast_urea_concentration + expected_effective_half_saturation);
    const banded_limitation = banded_urea_concentration / (banded_urea_concentration + expected_effective_half_saturation);
    const expected_common_hydrolysis = fertilizer_parameters.specific_hydrolysis_mol_n_per_g_c_h * toqck_g_c_per_step * tfnq * (1.0 - 0.2);
    const expected_broadcast_hydrolysis_mol_n = @min(broadcast_urea_mol_n, expected_common_hydrolysis * broadcast_limitation);
    const expected_banded_hydrolysis_mol_n = @min(banded_urea_mol_n, expected_common_hydrolysis * banded_limitation);
    try std.testing.expectApproxEqAbs(expected_broadcast_hydrolysis_mol_n, hydrolysis.broadcast_hydrolysis_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_banded_hydrolysis_mol_n, hydrolysis.banded_hydrolysis_mol_n, 1e-12);

    const dissolved = try dissolution_module.dissolution(
        initial_state,
        hydrolysis,
        fractions,
        rates,
        water_content_m3_per_m3,
        timestep_h,
    );
    const expected_dissolution_broadcast_non_band_ammonium = rates.ammonium_per_h * broadcast_ammonium_mol_n * fractions.ammonium_non_band * water_content_m3_per_m3;
    const expected_dissolution_broadcast_band_ammonium = rates.ammonium_per_h * broadcast_ammonium_mol_n * fractions.ammonium_band * water_content_m3_per_m3;
    const expected_dissolution_banded_ammonium = rates.ammonium_per_h * banded_ammonium_mol_n * water_content_m3_per_m3;
    const expected_dissolution_broadcast_non_band_ammonia = rates.ammonia_per_h * broadcast_ammonia_mol_n * fractions.ammonium_non_band;
    const expected_dissolution_broadcast_band_ammonia = rates.ammonia_per_h * broadcast_ammonia_mol_n * fractions.ammonium_band;
    const expected_dissolution_banded_ammonia = rates.ammonia_per_h * banded_ammonia_mol_n;
    const expected_dissolution_non_band_nitrate = rates.nitrate_per_h * broadcast_nitrate_mol_n * fractions.nitrate_non_band * water_content_m3_per_m3;
    const expected_dissolution_broadcast_band_nitrate = rates.nitrate_per_h * broadcast_nitrate_mol_n * fractions.nitrate_band * water_content_m3_per_m3;
    const expected_dissolution_banded_nitrate = rates.nitrate_per_h * banded_nitrate_mol_n * water_content_m3_per_m3;
    const expected_broadcast_urea_to_non_band = expected_broadcast_hydrolysis_mol_n * fractions.ammonium_non_band;
    const expected_broadcast_urea_to_band = expected_broadcast_hydrolysis_mol_n * fractions.ammonium_band;
    const expected_banded_urea_to_band = expected_banded_hydrolysis_mol_n * fractions.ammonium_band;

    try std.testing.expectApproxEqAbs(expected_dissolution_broadcast_non_band_ammonium, dissolved.broadcast_ammonium_non_band_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_dissolution_broadcast_band_ammonium, dissolved.broadcast_ammonium_band_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_dissolution_banded_ammonium, dissolved.banded_ammonium_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_dissolution_broadcast_non_band_ammonia, dissolved.broadcast_ammonia_non_band_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_dissolution_broadcast_band_ammonia, dissolved.broadcast_ammonia_band_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_dissolution_banded_ammonia, dissolved.banded_ammonia_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_broadcast_urea_to_non_band, dissolved.broadcast_urea_non_band_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_broadcast_urea_to_band, dissolved.broadcast_urea_band_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_banded_urea_to_band, dissolved.banded_urea_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_dissolution_non_band_nitrate, dissolved.broadcast_nitrate_non_band_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_dissolution_broadcast_band_nitrate, dissolved.broadcast_nitrate_band_mol_n, 1e-12);
    try std.testing.expectApproxEqAbs(expected_dissolution_banded_nitrate, dissolved.banded_nitrate_mol_n, 1e-12);

    var state = initial_state;
    var aqueous = std.mem.zeroes(aqueous_network.State);
    var gaseous_ammonia_g_n: f64 = 0;
    try dissolution_module.state_updateToRecipients(&state, &aqueous, &gaseous_ammonia_g_n, dissolved, fractions, water_volume_m3, 14);

    try std.testing.expectApproxEqAbs(
        broadcast_urea_mol_n - expected_broadcast_hydrolysis_mol_n,
        state.broadcast_urea_mol_n,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        banded_urea_mol_n - expected_banded_urea_to_band,
        state.banded_urea_mol_n,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        broadcast_ammonium_mol_n -
            expected_dissolution_broadcast_non_band_ammonium -
            expected_dissolution_broadcast_band_ammonium,
        state.broadcast_ammonium_mol_n,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        banded_ammonium_mol_n - expected_dissolution_banded_ammonium,
        state.banded_ammonium_mol_n,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        broadcast_ammonia_mol_n -
            expected_dissolution_broadcast_non_band_ammonia -
            expected_dissolution_broadcast_band_ammonia,
        state.broadcast_ammonia_mol_n,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        banded_ammonia_mol_n - expected_dissolution_banded_ammonia,
        state.banded_ammonia_mol_n,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        broadcast_nitrate_mol_n -
            expected_dissolution_non_band_nitrate -
            expected_dissolution_broadcast_band_nitrate,
        state.broadcast_nitrate_mol_n,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        banded_nitrate_mol_n - expected_dissolution_banded_nitrate,
        state.banded_nitrate_mol_n,
        1e-12,
    );

    const non_band_water_m3 = water_volume_m3 * fractions.ammonium_non_band;
    const band_water_m3 = water_volume_m3 * fractions.ammonium_band;
    const nitrate_non_band_water_m3 = water_volume_m3 * fractions.nitrate_non_band;
    const nitrate_band_water_m3 = water_volume_m3 * fractions.nitrate_band;
    const expected_aqueous_ammonium_non_band = expected_dissolution_broadcast_non_band_ammonium / non_band_water_m3;
    const expected_aqueous_ammonium_band = (expected_dissolution_broadcast_band_ammonium +
        expected_dissolution_banded_ammonium) / band_water_m3;
    const expected_aqueous_ammonia_non_band = expected_broadcast_urea_to_non_band / non_band_water_m3;
    const expected_aqueous_ammonia_band = (expected_broadcast_urea_to_band +
        expected_banded_urea_to_band) / band_water_m3;
    const expected_aqueous_nitrate_non_band = expected_dissolution_non_band_nitrate / nitrate_non_band_water_m3;
    const expected_aqueous_nitrate_band = (expected_dissolution_broadcast_band_nitrate +
        expected_dissolution_banded_nitrate) / nitrate_band_water_m3;

    try std.testing.expectApproxEqAbs(expected_aqueous_ammonium_non_band, aqueous.ammonium_non_band, 1e-12);
    try std.testing.expectApproxEqAbs(expected_aqueous_ammonium_band, aqueous.ammonium_band, 1e-12);
    try std.testing.expectApproxEqAbs(expected_aqueous_ammonia_non_band, aqueous.ammonia_non_band, 1e-12);
    try std.testing.expectApproxEqAbs(expected_aqueous_ammonia_band, aqueous.ammonia_band, 1e-12);
    try std.testing.expectApproxEqAbs(expected_aqueous_nitrate_non_band, aqueous.nitrate_non_band, 1e-12);
    try std.testing.expectApproxEqAbs(expected_aqueous_nitrate_band, aqueous.nitrate_band, 1e-12);
    try std.testing.expectApproxEqAbs(
        14 * (expected_dissolution_broadcast_non_band_ammonia +
            expected_dissolution_broadcast_band_ammonia +
            expected_dissolution_banded_ammonia),
        gaseous_ammonia_g_n,
        1e-12,
    );
}

test "zero biologically active water uses COQCK saturation cap" {
    const toqck_g_c_per_step = 10.0;
    const volq_m3 = 0.0;
    const temperature_factor = 0.8;
    const soil_mass_megagrams = 1.0;
    const water_volume_m3 = 3.0;
    const broadcast_urea_mol_n = 5.0;
    const expected_coqck = 0.1e6;
    const expected_effective_half_saturation = 0.2 * (1 + expected_coqck / 10.0);
    const expected_fraction = (broadcast_urea_mol_n / soil_mass_megagrams) / (broadcast_urea_mol_n / soil_mass_megagrams + expected_effective_half_saturation);
    const expected_next_inhibitor = 0.2 - 0.05 * 0.2 * 0.5;
    const expected_common_capacity = 0.4 * toqck_g_c_per_step *
        temperature_factor * (1 - expected_next_inhibitor);
    const expected_hydrolysis = @min(broadcast_urea_mol_n, expected_common_capacity * expected_fraction);
    const result = try dissolution_module.ureaHydrolysis(
        .{
            .broadcast_urea_mol_n = broadcast_urea_mol_n,
            .banded_urea_mol_n = 0,
            .soil_mass_megagrams = soil_mass_megagrams,
            .water_volume_m3 = water_volume_m3,
            .biologically_active_water_volume_m3 = volq_m3,
            .total_microbial_respiration_activity_g_c_per_step = toqck_g_c_per_step,
            .temperature_response = temperature_factor,
            .initial_inhibitor_activity = 0.4,
            .current_inhibitor_activity = 0.2,
            .timestep_h = 1,
        },
        .{
            .minimum_half_saturation_mol_n_per_megagram = 0.2,
            .microbial_activity_inhibition_g_c_per_m3_h = 10.0,
            .specific_hydrolysis_mol_n_per_g_c_h = 0.4,
            .inhibitor_decline_rate_per_h = 0.05,
            .negligible_biologically_active_water_m3 = 1e-12,
            .negligible_inhibitor_activity = 1e-12,
            .negligible_fertilizer_amount_mol_n = 1e-12,
            .negligible_soil_mass_megagrams = 1e-12,
            .negligible_water_volume_m3 = 1e-12,
            .physical_relative_tolerance = 1e-12,
        },
    );
    try std.testing.expectApproxEqAbs(expected_hydrolysis, result.broadcast_hydrolysis_mol_n, 1e-12);
}

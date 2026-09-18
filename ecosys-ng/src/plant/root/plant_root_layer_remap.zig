const std = @import("std");
const RootSystem = @import("plant_root_system.zig");

const domain_layer_extensive_fields = .{
    "mobile_carbon_g",
    "mobile_nitrogen_g",
    "mobile_phosphorus_g",
    "symbiont_structural_carbon_g_c",
    "symbiont_structural_nitrogen_g_n",
    "symbiont_structural_phosphorus_g_p",
    "symbiont_mobile_carbon_g_c",
    "symbiont_mobile_nitrogen_g_n",
    "symbiont_mobile_phosphorus_g_p",
    "total_carbon_g",
    "primary_root_carbon_g",
    "protein_carbon_g",
    // REDIST treats RRAD1/RRAD2 as transferred layer ledgers, even though
    // their dimensions are lengths. Preserve that source transaction exactly.
    "primary_radius_m",
    "secondary_radius_m",
    "projected_area_m2",
    "active_length_m",
    "aqueous_volume_m3",
    "gaseous_volume_m3",
    "root_length_m_per_plant",
    "root_length_density_m_per_m3",
    "root_surface_area_m2_per_plant",
    "average_secondary_length_m",
    "secondary_axis_count_total",
    "gaseous_carbon_dioxide_g_c",
    "aqueous_carbon_dioxide_g_c",
    "gaseous_oxygen_g_o",
    "aqueous_oxygen_g_o",
    "gaseous_methane_g_c",
    "aqueous_methane_g_c",
    "gaseous_nitrous_oxide_g_n",
    "aqueous_nitrous_oxide_g_n",
    "gaseous_ammonia_g_n",
    "aqueous_ammonia_g_n",
    "gaseous_hydrogen_g_h",
    "aqueous_hydrogen_g_h",
};

const axis_layer_extensive_fields = .{
    "axis_primary_length_m",
    "axis_primary_count",
    "axis_primary_carbon_g",
    "axis_primary_nitrogen_g",
    "axis_primary_phosphorus_g",
    "axis_secondary_length_m",
    "axis_secondary_count",
    "axis_secondary_carbon_g",
    "axis_secondary_nitrogen_g",
    "axis_secondary_phosphorus_g",
};

// REDIST soil-root block 10452 onward. The adjacent root-gas statements
// 10415--10450 are commented out in the reference and therefore are excluded
// from the soil relayer transaction.
const soil_root_domain_layer_extensive_fields = .{
    "mobile_carbon_g",
    "mobile_nitrogen_g",
    "mobile_phosphorus_g",
    "symbiont_structural_carbon_g_c",
    "symbiont_structural_nitrogen_g_n",
    "symbiont_structural_phosphorus_g_p",
    "symbiont_mobile_carbon_g_c",
    "symbiont_mobile_nitrogen_g_n",
    "symbiont_mobile_phosphorus_g_p",
    "total_carbon_g",
    "primary_root_carbon_g",
    "protein_carbon_g",
    "primary_radius_m",
    "secondary_radius_m",
    "projected_area_m2",
    "active_length_m",
    "aqueous_volume_m3",
    "gaseous_volume_m3",
    "root_length_m_per_plant",
    "root_length_density_m_per_m3",
    "root_surface_area_m2_per_plant",
    "average_secondary_length_m",
    "secondary_axis_count_total",
};

/// REDIST ponding transaction for WTRT*, RTLG*, CPOOLR/ZPOOLR/PPOOLR,
/// CO2A/OXYA/.../H2GP, and their runtime-sized ecosys-ng owners. The source
/// fraction is moved, not copied, so every extensive pool is conserved.
pub fn transferLayerFraction(
    roots: *RootSystem.State,
    plant: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    try validateLayerFraction(roots, plant, source_layer, destination_layer, fraction);
    if (fraction == 0) return;

    for (0..RootSystem.biological_domain_count) |domain| {
        const source = try roots.layerIndex(plant, domain, source_layer);
        const destination = try roots.layerIndex(plant, domain, destination_layer);
        inline for (domain_layer_extensive_fields) |field_name| {
            const values = @field(roots, field_name);
            transferPair(values, source, destination, fraction);
        }
        for (0..RootSystem.salt_species_count) |salt| {
            const source_salt = source * RootSystem.salt_species_count + salt;
            const destination_salt = destination * RootSystem.salt_species_count + salt;
            transferPair(roots.salt_content_mol, source_salt, destination_salt, fraction);
        }
        for (0..roots.root_axis_count) |axis| {
            const source_axis = ((plant * RootSystem.biological_domain_count + domain) * roots.soil_layer_count + source_layer) * roots.root_axis_count + axis;
            const destination_axis = ((plant * RootSystem.biological_domain_count + domain) * roots.soil_layer_count + destination_layer) * roots.root_axis_count + axis;
            inline for (axis_layer_extensive_fields) |field_name| {
                const values = @field(roots, field_name);
                transferPair(values, source_axis, destination_axis, fraction);
            }
        }
    }
}

/// Applies one REDIST layer transfer to every runtime species in a cell. All
/// plants are validated before the first mutation.
pub fn transferCellLayerFraction(
    roots: *RootSystem.State,
    cell: usize,
    species_count: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    if (species_count == 0 or roots.plant_count % species_count != 0 or cell >= roots.plant_count / species_count) return error.InvalidRootLayerTransferCell;
    const first_plant = cell * species_count;
    for (first_plant..first_plant + species_count) |plant| try validateLayerFraction(roots, plant, source_layer, destination_layer, fraction);
    for (first_plant..first_plant + species_count) |plant| try transferLayerFraction(roots, plant, source_layer, destination_layer, fraction);
}

/// Exact REDIST ponding gate: WTRTL for the root domain must exceed the
/// runtime species threshold in both layers. Once admitted, both the root and
/// mycorrhizal domains move together. Every admitted species is validated
/// before any species is state_updateted.
pub fn transferPondedCellLayerFraction(
    roots: *RootSystem.State,
    cell: usize,
    species_count: usize,
    plant_population_count: []const f64,
    structural_presence_g_per_plant: f64,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    try validatePondedCellLayerFraction(
        roots,
        cell,
        species_count,
        plant_population_count,
        structural_presence_g_per_plant,
        source_layer,
        destination_layer,
        fraction,
    );
    const first_plant = cell * species_count;
    for (0..species_count) |species| {
        const plant = first_plant + species;
        const source = try roots.layerIndex(plant, 0, source_layer);
        const destination = try roots.layerIndex(plant, 0, destination_layer);
        const threshold =
            structural_presence_g_per_plant * plant_population_count[plant];
        if (roots.total_carbon_g[source] > threshold and roots.total_carbon_g[destination] > threshold)
            try transferSoilRootLayerFraction(roots, plant, source_layer, destination_layer, fraction);
    }
}

pub fn validatePondedCellLayerFraction(
    roots: *const RootSystem.State,
    cell: usize,
    species_count: usize,
    plant_population_count: []const f64,
    structural_presence_g_per_plant: f64,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    if (species_count == 0 or
        roots.plant_count % species_count != 0 or
        cell >= roots.plant_count / species_count or
        plant_population_count.len != roots.plant_count)
        return error.InvalidRootLayerTransferCell;
    if (source_layer >= roots.soil_layer_count or destination_layer >= roots.soil_layer_count or source_layer == destination_layer) return error.InvalidRootLayerTransfer;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
        return error.InvalidRootLayerTransferFraction;
    if (!std.math.isFinite(structural_presence_g_per_plant) or
        structural_presence_g_per_plant < 0)
        return error.InvalidMinimumLivingRootCarbon;
    const first_plant = cell * species_count;
    for (0..species_count) |species| {
        const plant = first_plant + species;
        const population = plant_population_count[plant];
        if (!std.math.isFinite(population) or population < 0)
            return error.InvalidPlantPopulationCount;
        const threshold = structural_presence_g_per_plant * population;
        if (!std.math.isFinite(threshold))
            return error.InvalidMinimumLivingRootCarbon;
        const source = try roots.layerIndex(plant, 0, source_layer);
        const destination = try roots.layerIndex(plant, 0, destination_layer);
        const source_carbon = roots.total_carbon_g[source];
        const destination_carbon = roots.total_carbon_g[destination];
        if (!std.math.isFinite(source_carbon) or source_carbon < 0 or !std.math.isFinite(destination_carbon) or destination_carbon < 0) return error.InvalidRootLayerExtensiveState;
        if (source_carbon > threshold and destination_carbon > threshold)
            try validateSoilRootLayerFraction(roots, plant, source_layer, destination_layer, fraction);
    }
}

fn transferSoilRootLayerFraction(
    roots: *RootSystem.State,
    plant: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    try validateSoilRootLayerFraction(roots, plant, source_layer, destination_layer, fraction);
    if (fraction == 0) return;
    for (0..RootSystem.biological_domain_count) |domain| {
        const source = try roots.layerIndex(plant, domain, source_layer);
        const destination = try roots.layerIndex(plant, domain, destination_layer);
        inline for (soil_root_domain_layer_extensive_fields) |field_name|
            transferPair(@field(roots, field_name), source, destination, fraction);
        for (0..roots.root_axis_count) |axis| {
            const source_axis = ((plant * RootSystem.biological_domain_count + domain) * roots.soil_layer_count + source_layer) * roots.root_axis_count + axis;
            const destination_axis = ((plant * RootSystem.biological_domain_count + domain) * roots.soil_layer_count + destination_layer) * roots.root_axis_count + axis;
            inline for (axis_layer_extensive_fields) |field_name|
                transferPair(@field(roots, field_name), source_axis, destination_axis, fraction);
        }
    }
}

fn validateSoilRootLayerFraction(
    roots: *const RootSystem.State,
    plant: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    if (plant >= roots.plant_count or source_layer >= roots.soil_layer_count or destination_layer >= roots.soil_layer_count or source_layer == destination_layer) return error.InvalidRootLayerTransfer;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidRootLayerTransferFraction;
    if (fraction == 0) return;
    for (0..RootSystem.biological_domain_count) |domain| {
        const source = try roots.layerIndex(plant, domain, source_layer);
        const destination = try roots.layerIndex(plant, domain, destination_layer);
        inline for (soil_root_domain_layer_extensive_fields) |field_name|
            try validatePair(@field(roots, field_name)[source], @field(roots, field_name)[destination], fraction);
        for (0..roots.root_axis_count) |axis| {
            const source_axis = ((plant * RootSystem.biological_domain_count + domain) * roots.soil_layer_count + source_layer) * roots.root_axis_count + axis;
            const destination_axis = ((plant * RootSystem.biological_domain_count + domain) * roots.soil_layer_count + destination_layer) * roots.root_axis_count + axis;
            inline for (axis_layer_extensive_fields) |field_name|
                try validatePair(@field(roots, field_name)[source_axis], @field(roots, field_name)[destination_axis], fraction);
        }
    }
}

pub fn validateLayerFraction(
    roots: *const RootSystem.State,
    plant: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    if (plant >= roots.plant_count or source_layer >= roots.soil_layer_count or destination_layer >= roots.soil_layer_count or source_layer == destination_layer) return error.InvalidRootLayerTransfer;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidRootLayerTransferFraction;
    if (fraction == 0) return;

    // Validate the complete transaction before mutating any field.
    for (0..RootSystem.biological_domain_count) |domain| {
        const source = try roots.layerIndex(plant, domain, source_layer);
        const destination = try roots.layerIndex(plant, domain, destination_layer);
        inline for (domain_layer_extensive_fields) |field_name| {
            const values = @field(roots, field_name);
            try validatePair(values[source], values[destination], fraction);
        }
        for (0..RootSystem.salt_species_count) |salt| {
            const source_salt = source * RootSystem.salt_species_count + salt;
            const destination_salt = destination * RootSystem.salt_species_count + salt;
            try validatePair(roots.salt_content_mol[source_salt], roots.salt_content_mol[destination_salt], fraction);
        }
        for (0..roots.root_axis_count) |axis| {
            const source_axis = ((plant * RootSystem.biological_domain_count + domain) * roots.soil_layer_count + source_layer) * roots.root_axis_count + axis;
            const destination_axis = ((plant * RootSystem.biological_domain_count + domain) * roots.soil_layer_count + destination_layer) * roots.root_axis_count + axis;
            inline for (axis_layer_extensive_fields) |field_name| {
                const values = @field(roots, field_name);
                try validatePair(values[source_axis], values[destination_axis], fraction);
            }
        }
    }
}

fn validatePair(source: f64, destination: f64, fraction: f64) !void {
    const moved = fraction * source;
    const next_source = source - moved;
    const next_destination = destination + moved;
    if (!std.math.isFinite(source) or source < 0 or !std.math.isFinite(destination) or destination < 0 or
        !std.math.isFinite(next_source) or next_source < 0 or !std.math.isFinite(next_destination) or next_destination < 0)
        return error.InvalidRootLayerExtensiveState;
}

fn transferPair(values: []f64, source: usize, destination: usize, fraction: f64) void {
    const moved = fraction * values[source];
    values[source] -= moved;
    values[destination] += moved;
}

test "REDIST root layer transfer conserves arbitrary species axes gases and salts" {
    const species_count: usize = 7;
    var roots = try RootSystem.State.init(std.testing.allocator, species_count, 3, 4);
    defer roots.deinit();
    for (0..species_count) |plant| {
        for (0..RootSystem.biological_domain_count) |domain| {
            const source = try roots.layerIndex(plant, domain, 0);
            const destination = try roots.layerIndex(plant, domain, 1);
            roots.mobile_carbon_g[source] = @floatFromInt(plant + domain + 1);
            roots.gaseous_oxygen_g_o[source] = 2;
            roots.aqueous_methane_g_c[source] = 3;
            roots.primary_radius_m[source] = 0.002;
            roots.secondary_radius_m[source] = 0.001;
            roots.root_length_density_m_per_m3[source] = 12;
            roots.average_secondary_length_m[source] = 0.03;
            roots.secondary_axis_count_total[source] = 9;
            roots.salt_content_mol[source * RootSystem.salt_species_count + 7] = 4;
            for (0..roots.root_axis_count) |axis| {
                const source_axis = ((plant * RootSystem.biological_domain_count + domain) * roots.soil_layer_count) * roots.root_axis_count + axis;
                roots.axis_primary_carbon_g[source_axis] = @floatFromInt(axis + 1);
            }
            try transferLayerFraction(&roots, plant, 0, 1, 0.25);
            try std.testing.expectApproxEqAbs(2.0, roots.gaseous_oxygen_g_o[source] + roots.gaseous_oxygen_g_o[destination], 1e-14);
            try std.testing.expectApproxEqAbs(3.0, roots.aqueous_methane_g_c[source] + roots.aqueous_methane_g_c[destination], 1e-14);
            try std.testing.expectApproxEqAbs(0.002, roots.primary_radius_m[source] + roots.primary_radius_m[destination], 1e-14);
            try std.testing.expectApproxEqAbs(0.001, roots.secondary_radius_m[source] + roots.secondary_radius_m[destination], 1e-14);
            try std.testing.expectApproxEqAbs(12.0, roots.root_length_density_m_per_m3[source] + roots.root_length_density_m_per_m3[destination], 1e-14);
            try std.testing.expectApproxEqAbs(0.03, roots.average_secondary_length_m[source] + roots.average_secondary_length_m[destination], 1e-14);
            try std.testing.expectApproxEqAbs(9.0, roots.secondary_axis_count_total[source] + roots.secondary_axis_count_total[destination], 1e-14);
            try std.testing.expectApproxEqAbs(4.0, roots.salt_content_mol[source * RootSystem.salt_species_count + 7] + roots.salt_content_mol[destination * RootSystem.salt_species_count + 7], 1e-14);
        }
    }
}

test "REDIST root layer transfer validates every pool before mutation" {
    var roots = try RootSystem.State.init(std.testing.allocator, 1, 2, 2);
    defer roots.deinit();
    const source = try roots.layerIndex(0, 0, 0);
    const destination = try roots.layerIndex(0, 0, 1);
    roots.mobile_carbon_g[source] = 5;
    roots.gaseous_oxygen_g_o[source] = 2;
    const late_axis = ((0 * RootSystem.biological_domain_count + 1) * roots.soil_layer_count + 0) * roots.root_axis_count + 1;
    roots.axis_secondary_phosphorus_g[late_axis] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidRootLayerExtensiveState, transferLayerFraction(&roots, 0, 0, 1, 0.5));
    try std.testing.expectEqual(@as(f64, 5), roots.mobile_carbon_g[source]);
    try std.testing.expectEqual(@as(f64, 0), roots.mobile_carbon_g[destination]);
    try std.testing.expectEqual(@as(f64, 2), roots.gaseous_oxygen_g_o[source]);
}

test "REDIST cell root transfer validates every runtime species before mutation" {
    const species_count: usize = 7;
    var roots = try RootSystem.State.init(std.testing.allocator, species_count, 2, 2);
    defer roots.deinit();
    for (0..species_count) |plant| {
        const source = try roots.layerIndex(plant, 0, 0);
        roots.mobile_carbon_g[source] = @floatFromInt(plant + 1);
    }
    const late_source = try roots.layerIndex(species_count - 1, 1, 0);
    roots.gaseous_hydrogen_g_h[late_source] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidRootLayerExtensiveState, transferCellLayerFraction(&roots, 0, species_count, 0, 1, 0.5));
    for (0..species_count) |plant| {
        const source = try roots.layerIndex(plant, 0, 0);
        const destination = try roots.layerIndex(plant, 0, 1);
        try std.testing.expectEqual(@as(f64, @floatFromInt(plant + 1)), roots.mobile_carbon_g[source]);
        try std.testing.expectEqual(@as(f64, 0), roots.mobile_carbon_g[destination]);
    }
}

test "REDIST ponding applies runtime living-root gate and moves both domains" {
    const species_count: usize = 7;
    var roots = try RootSystem.State.init(std.testing.allocator, species_count, 2, 2);
    defer roots.deinit();
    for (0..species_count) |plant| {
        const root_source = try roots.layerIndex(plant, 0, 0);
        const root_destination = try roots.layerIndex(plant, 0, 1);
        const mycorrhiza_source = try roots.layerIndex(plant, 1, 0);
        roots.total_carbon_g[root_source] = if (plant == 3) 0.1 else 2;
        roots.total_carbon_g[root_destination] = 2;
        roots.gaseous_oxygen_g_o[root_source] = 1;
        roots.mobile_carbon_g[mycorrhiza_source] = 4;
    }
    try transferPondedCellLayerFraction(
        &roots,
        0,
        species_count,
        &.{ 5, 5, 5, 5, 5, 5, 5 },
        0.1,
        0,
        1,
        0.25,
    );
    for (0..species_count) |plant| {
        const mycorrhiza_source = try roots.layerIndex(plant, 1, 0);
        const mycorrhiza_destination = try roots.layerIndex(plant, 1, 1);
        if (plant == 3) {
            try std.testing.expectEqual(@as(f64, 4), roots.mobile_carbon_g[mycorrhiza_source]);
            try std.testing.expectEqual(@as(f64, 0), roots.mobile_carbon_g[mycorrhiza_destination]);
        } else {
            try std.testing.expectEqual(@as(f64, 3), roots.mobile_carbon_g[mycorrhiza_source]);
            try std.testing.expectEqual(@as(f64, 1), roots.mobile_carbon_g[mycorrhiza_destination]);
        }
        const root_source = try roots.layerIndex(plant, 0, 0);
        const root_destination = try roots.layerIndex(plant, 0, 1);
        try std.testing.expectEqual(@as(f64, 1), roots.gaseous_oxygen_g_o[root_source]);
        try std.testing.expectEqual(@as(f64, 0), roots.gaseous_oxygen_g_o[root_destination]);
    }
}

test "REDIST living-root gate scales ZEROP by each live plant population" {
    const species_count: usize = 2;
    var roots = try RootSystem.State.init(
        std.testing.allocator,
        species_count,
        2,
        1,
    );
    defer roots.deinit();
    for (0..species_count) |plant| {
        const source = try roots.layerIndex(plant, 0, 0);
        const destination = try roots.layerIndex(plant, 0, 1);
        roots.total_carbon_g[source] = 2;
        roots.total_carbon_g[destination] = 2;
        roots.mobile_carbon_g[source] = 4;
    }

    // Source STARTQ/GROSUB semantics: ZEROP = ZERO * PP. Species zero has
    // ZEROP=1 and transfers; species one has ZEROP=10 and remains unchanged.
    try transferPondedCellLayerFraction(
        &roots,
        0,
        species_count,
        &.{ 10, 100 },
        0.1,
        0,
        1,
        0.25,
    );

    const first_source = try roots.layerIndex(0, 0, 0);
    const first_destination = try roots.layerIndex(0, 0, 1);
    try std.testing.expectEqual(@as(f64, 3), roots.mobile_carbon_g[first_source]);
    try std.testing.expectEqual(@as(f64, 1), roots.mobile_carbon_g[first_destination]);
    const second_source = try roots.layerIndex(1, 0, 0);
    const second_destination = try roots.layerIndex(1, 0, 1);
    try std.testing.expectEqual(@as(f64, 4), roots.mobile_carbon_g[second_source]);
    try std.testing.expectEqual(@as(f64, 0), roots.mobile_carbon_g[second_destination]);
}

//! `photosynthesis` declarations: state.
//!
//! Split out of `photosynthesis.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const c4_mesophyll_bundle_exchange = @import("c4_mesophyll_bundle_exchange.zig");
const branch_organ_growth_state_update = @import("../../plant/growth/branch_organ_growth_state_update.zig");
const leaf_node_growth_state_update = @import("../leaf/node_growth_state_update.zig");
const shoot_recycling_fraction = @import("../../plant/growth/shoot_recycling_fraction.zig");
const reserve_maintenance_respiration = @import("../../plant/growth/reserve_maintenance_respiration.zig");
const shoot_total_senescence_setup = @import("../../plant/growth/shoot_total_senescence_setup.zig");
const node_senescence_remobilization_request = @import("../../plant/growth/node_senescence_remobilization_request.zig");
const c4_leaf_nonstructural_carbon_senescence = @import("../leaf/c4_nonstructural_carbon_senescence.zig");
const node_senescence_cascade_progress = @import("../../plant/growth/node_senescence_cascade_progress.zig");
const perennial_stalk_senescence_setup = @import("../../plant/growth/perennial_stalk_senescence_setup.zig");
const internode_senescence_state_update = @import("../sheath/internode_senescence_state_update.zig");
const residual_stalk_senescence_request = @import("../../plant/growth/residual_stalk_senescence_request.zig");
const residual_stalk_senescence_state_update = @import("../../plant/growth/residual_stalk_senescence_state_update.zig");

/// Compact heap-owned canopy topology. Prefix offsets permit different branch,
/// node, layer/orientation sample counts for every runtime plant population.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    plant_branch_offsets: []usize,
    branch_node_offsets: []usize,
    node_sample_offsets: []usize,
    branch_c3_feedback_fraction: []f64,
    branch_c4_feedback_fraction: []f64,
    branch_carboxylation_umol_per_s: []f64,
    branch_fixed_carbon_g_c_per_h: []f64,
    branch_shoot_carbohydrate_g_c_per_h: []f64,
    branch_mobile_carbon_g: []f64,
    branch_mobile_nitrogen_g: []f64,
    branch_mobile_phosphorus_g: []f64,
    branch_symbiont_mobile_carbon_g: []f64,
    branch_symbiont_mobile_nitrogen_g: []f64,
    branch_symbiont_mobile_phosphorus_g: []f64,
    branch_symbiont_structural_carbon_g: []f64,
    branch_symbiont_structural_nitrogen_g: []f64,
    branch_symbiont_structural_phosphorus_g: []f64,
    branch_symbiotic_fixed_nitrogen_g_n_per_h: []f64,
    branch_symbiotic_respiration_g_c_per_h: []f64,
    branch_canopy_ammonia_exchange_g_n_per_h: []f64,
    branch_salt_content_by_species_mol: []f64,
    branch_combustion_salt_loss_by_species_mol_per_h: []f64,
    branch_mobile_carbon_concentration_g_per_g: []f64,
    branch_mobile_nitrogen_concentration_g_per_g: []f64,
    branch_mobile_phosphorus_concentration_g_per_g: []f64,
    branch_leaf_carbon_g: []f64,
    branch_leaf_nitrogen_g: []f64,
    branch_leaf_phosphorus_g: []f64,
    branch_sheath_carbon_g: []f64,
    branch_sheath_nitrogen_g: []f64,
    branch_sheath_phosphorus_g: []f64,
    branch_stalk_carbon_g: []f64,
    branch_stalk_nitrogen_g: []f64,
    branch_stalk_phosphorus_g: []f64,
    branch_sapwood_carbon_g: []f64,
    branch_reserve_carbon_g: []f64,
    branch_reserve_nitrogen_g: []f64,
    branch_reserve_phosphorus_g: []f64,
    branch_husk_carbon_g: []f64,
    branch_husk_nitrogen_g: []f64,
    branch_husk_phosphorus_g: []f64,
    branch_ear_carbon_g: []f64,
    branch_ear_nitrogen_g: []f64,
    branch_ear_phosphorus_g: []f64,
    branch_grain_carbon_g: []f64,
    branch_grain_nitrogen_g: []f64,
    branch_grain_phosphorus_g: []f64,
    branch_potential_seed_site_count: []f64,
    branch_seed_count: []f64,
    branch_individual_seed_carbon_g: []f64,
    branch_senescing_stalk_carbon_g: []f64,
    branch_senescing_stalk_nitrogen_g: []f64,
    branch_senescing_stalk_phosphorus_g: []f64,
    // GROSUB WGLFX/WGLFNX/WGLFPX/ARLFZ and RCCLX/RCZLX/RCPLX persist between
    // IFLGP leaf-appearance events while the oldest retained node is retired.
    branch_senescing_leaf_carbon_g: []f64,
    branch_senescing_leaf_nitrogen_g: []f64,
    branch_senescing_leaf_phosphorus_g: []f64,
    branch_senescing_leaf_area_m2: []f64,
    branch_senescing_leaf_remobilizable_carbon_g: []f64,
    branch_senescing_leaf_remobilizable_nitrogen_g: []f64,
    branch_senescing_leaf_remobilizable_phosphorus_g: []f64,
    // GROSUB WGSHEX/WGSHNX/WGSHPX/HTSHEX and RCCSX/RCZSX/RCPSX are the
    // independently persisted sheath snapshot for that selected node.
    branch_senescing_sheath_carbon_g: []f64,
    branch_senescing_sheath_nitrogen_g: []f64,
    branch_senescing_sheath_phosphorus_g: []f64,
    branch_senescing_sheath_height_m: []f64,
    branch_senescing_sheath_remobilizable_carbon_g: []f64,
    branch_senescing_sheath_remobilizable_nitrogen_g: []f64,
    branch_senescing_sheath_remobilizable_phosphorus_g: []f64,
    branch_leaf_area_m2: []f64,
    node_leaf_area_m2: []f64,
    node_height_m: []f64,
    node_internode_length_m: []f64,
    node_sheath_height_m: []f64,
    node_leaf_carbon_g: []f64,
    node_leaf_protein_g: []f64,
    node_leaf_nitrogen_g: []f64,
    node_leaf_phosphorus_g: []f64,
    node_sheath_carbon_g: []f64,
    node_sheath_protein_g: []f64,
    node_sheath_nitrogen_g: []f64,
    node_sheath_phosphorus_g: []f64,
    node_internode_carbon_g: []f64,
    node_internode_nitrogen_g: []f64,
    node_internode_phosphorus_g: []f64,
    node_c3_nonstructural_carbon_g: []f64,
    node_c4_mesophyll_nonstructural_carbon_g: []f64,
    node_bundle_sheath_co2_carbon_g: []f64,
    node_bundle_sheath_bicarbonate_carbon_g: []f64,
    node_co2_unlimited_carboxylation_umol_per_m2_s: []f64,
    node_co2_limited_carboxylation_umol_per_m2_s: []f64,
    node_co2_compensation_umol_per_l: []f64,
    node_co2_solubility_umol_per_l_per_umol_per_mol: []f64,
    node_carboxylation_half_saturation_umol_per_l: []f64,
    node_light_saturated_electron_transport_umol_per_m2_s: []f64,
    node_carboxylation_umol_co2_per_umol_electron: []f64,
    node_c4_feedback_fraction: []f64,
    node_pep_carboxylase_surface_density_g_per_m2: []f64,
    node_mesophyll_chlorophyll_surface_density_g_per_m2: []f64,
    node_bundle_sheath_co2_limited_carboxylation_umol_per_m2_s: []f64,
    node_bundle_sheath_light_saturated_electron_transport_umol_per_m2_s: []f64,
    node_bundle_sheath_carboxylation_umol_co2_per_umol_electron: []f64,
    sample_exposed_leaf_area_m2: []f64,
    sample_leaf_area_m2: []f64,
    sample_leaf_carbon_g: []f64,
    sample_leaf_nitrogen_g: []f64,
    sample_leaf_phosphorus_g: []f64,
    sample_stalk_area_m2: []f64,
    sample_layer_lower_height_m: []f64,
    sample_layer_upper_height_m: []f64,
    sample_direct_par_umol_per_m2_s: []f64,
    sample_diffuse_par_umol_per_m2_s: []f64,
    sample_direct_transmission_fraction: []f64,
    sample_diffuse_transmission_fraction: []f64,
    sample_intercellular_co2_umol_per_mol: []f64,
    sample_carboxylation_umol_per_s: []f64,
    sample_bundle_sheath_carboxylation_umol_per_s: []f64,
    plant_carboxylation_umol_per_s: []f64,
    /// STOMATE's `CH2O` (`stomate.f`:87/347/395/570/617): canopy carboxylation
    /// capacity at maximum canopy turgor, using only the branch/node nutrient,
    /// heat, dehardening, and annual-termination feedback (`FDBK`/`FDBK4`),
    /// never the plant's current water-stress or stomatal-resistance state.
    /// This is the correct input for `RSMN` (see `canopy_minimum_stomatal_
    /// resistance`); `plant_carboxylation_umol_per_s` above is GROSUB's actual,
    /// already water-stress-limited fixation and must not be substituted here.
    plant_maximum_turgor_carboxylation_umol_per_s: []f64,
    plant_gross_primary_productivity_g_c_per_h: []f64,
    plant_minimum_water_vapor_resistance_h_per_m: []f64,
    plant_population_per_m2: []f64,
    plant_population_count: []f64,
    plant_population_change_count: []f64,
    plant_stem_diameter_m: []f64,
    plant_standing_dead_population_count: []f64,
    plant_cuticular_water_vapor_resistance_h_per_m: []f64,
    plant_cuticular_co2_resistance_s_per_m: []f64,
    plant_intercellular_oxygen_umol_per_mol: []f64,
    plant_thermal_adaptation_offset_c: []f64,
    plant_chilling_stress_h: []f64,
    plant_heat_stress_h: []f64,
    plant_uptake_growth_temperature_response: []f64,
    plant_minimum_daily_canopy_water_potential_megapascal: []f64,
    plant_leafout_threshold_c: []f64,
    plant_leafoff_threshold_c: []f64,
    plant_seed_set_high_temperature_c: []f64,
    plant_seed_set_loss_fraction_per_c_h: []f64,
    plant_seed_storage_carbon_g: []f64,
    plant_seed_storage_nitrogen_g: []f64,
    plant_seed_storage_phosphorus_g: []f64,
    plant_standing_dead_carbon_g: []f64,
    plant_standing_dead_nitrogen_g: []f64,
    plant_standing_dead_phosphorus_g: []f64,
    plant_charcoal_carbon_g: []f64,
    plant_charcoal_nitrogen_g: []f64,
    plant_charcoal_phosphorus_g: []f64,
    plant_standing_dead_height_m: []f64,
    plant_standing_dead_carbon_by_kinetic_g: []f64,
    plant_standing_dead_nitrogen_by_kinetic_g: []f64,
    plant_standing_dead_phosphorus_by_kinetic_g: []f64,
    plant_canopy_aerodynamic_temperature_k: []f64,
    plant_canopy_aerodynamic_vapor_pressure_kpa: []f64,
    plant_standing_dead_aerodynamic_temperature_k: []f64,
    plant_standing_dead_aerodynamic_vapor_pressure_kpa: []f64,
    plant_standing_dead_surface_temperature_k: []f64,
    plant_phenology_temperature_k: []f64,
    plant_canopy_osmotic_potential_megapascal: []f64,
    plant_canopy_turgor_potential_megapascal: []f64,
    plant_stored_energy_megajoules: []f64,
    plant_transpiration_m3_per_h: []f64,
    plant_hypocotyledon_height_m: []f64,
    plant_mobile_carbon_g: []f64,
    plant_mobile_nitrogen_g: []f64,
    plant_mobile_phosphorus_g: []f64,
    plant_symbiont_mobile_carbon_g: []f64,
    plant_symbiont_mobile_nitrogen_g: []f64,
    plant_symbiont_mobile_phosphorus_g: []f64,
    plant_salt_content_mol: []f64,
    plant_mobile_carbon_concentration_g_per_g: []f64,
    plant_mobile_nitrogen_concentration_g_per_g: []f64,
    plant_mobile_phosphorus_concentration_g_per_g: []f64,
    plant_symbiont_mobile_carbon_concentration_g_per_g: []f64,
    plant_salt_concentration_mol_per_g_c: []f64,
    plant_nitrogen_phosphorus_fixation_constraint_fraction: []f64,
    plant_leaf_sheath_partition_fraction: []f64,
    /// GROSUB WTLS/WTSTK/WVSTK/ARSTP, published together immediately after
    /// a branch disturbance and retained as one coherent downstream snapshot.
    plant_leaf_sheath_carbon_g: []f64,
    plant_stalk_carbon_g: []f64,
    plant_sapwood_carbon_g: []f64,
    plant_stalk_surface_area_m2: []f64,
    plant_total_shoot_carbon_g: []f64,
    plant_previous_total_shoot_carbon_g: []f64,
    plant_shoot_growth_g_c_per_step: []f64,
    plant_combustion_carbon_loss_g_c_per_h: []f64,
    plant_combustion_nitrogen_loss_g_n_per_h: []f64,
    plant_combustion_phosphorus_loss_g_p_per_h: []f64,
    plant_live_combustion_g_c_per_h: []f64,
    plant_standing_dead_combustion_g_c_per_h: []f64,
    plant_fire_carbon_dioxide_emission_g_c_per_h: []f64,
    plant_fire_methane_emission_g_c_per_h: []f64,
    plant_fire_oxygen_consumption_g_o_per_h: []f64,
    plant_fire_charcoal_production_g_c_per_h: []f64,
    plant_fire_heat_release_megajoules_per_h: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, species_count: usize, branch_count_by_plant: []const usize, node_count_by_branch: []const usize, sample_count_by_node: []const usize) !State {
        if (cell_count == 0 or species_count == 0) return error.InvalidCanopyPhotosynthesisDimensions;
        const plant_count = try std.math.mul(usize, cell_count, species_count);
        const plant_kinetic_count = try std.math.mul(usize, plant_count, 4);
        if (branch_count_by_plant.len != plant_count) return error.CanopyBranchCountDimensionMismatch;
        const branch_count = try checkedSum(branch_count_by_plant);
        if (node_count_by_branch.len != branch_count) return error.CanopyNodeCountDimensionMismatch;
        const node_count = try checkedSum(node_count_by_branch);
        if (sample_count_by_node.len != node_count) return error.CanopySampleCountDimensionMismatch;
        const sample_count = try checkedSum(sample_count_by_node);

        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        result.species_count = species_count;
        result.plant_branch_offsets = try makeOffsets(allocator, branch_count_by_plant);
        errdefer allocator.free(result.plant_branch_offsets);
        result.branch_node_offsets = try makeOffsets(allocator, node_count_by_branch);
        errdefer allocator.free(result.branch_node_offsets);
        result.node_sample_offsets = try makeOffsets(allocator, sample_count_by_node);
        errdefer allocator.free(result.node_sample_offsets);
        var float_fields = floatFieldPointers(&result);
        var allocated_f64_fields: usize = 0;
        errdefer freeFloatFields(allocator, float_fields[0..allocated_f64_fields]);
        for (&float_fields, float_field_extent_kinds) |field, extent_kind| {
            field.* = try allocateZeroedFloatField(allocator, fieldExtent(
                extent_kind,
                plant_count,
                plant_kinetic_count,
                branch_count,
                node_count,
                sample_count,
            ));
            allocated_f64_fields += 1;
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        var float_fields = floatFieldPointers(self);
        freeFloatFields(self.allocator, &float_fields);
        self.allocator.free(self.node_sample_offsets);
        self.allocator.free(self.branch_node_offsets);
        self.allocator.free(self.plant_branch_offsets);
        self.* = undefined;
    }

    pub fn plantIndex(self: State, cell: usize, species: usize) !usize {
        if (cell >= self.cell_count or species >= self.species_count) return error.CanopyPlantIndexOutOfBounds;
        return cell * self.species_count + species;
    }

    pub fn branchRange(self: State, plant: usize) !Range {
        if (plant + 1 >= self.plant_branch_offsets.len) return error.CanopyPlantIndexOutOfBounds;
        return .{ .first = self.plant_branch_offsets[plant], .end = self.plant_branch_offsets[plant + 1] };
    }

    pub fn clone(self: State) !State {
        const plant_count = self.plant_branch_offsets.len - 1;
        const branch_count = self.branch_node_offsets.len - 1;
        const node_count = self.node_sample_offsets.len - 1;
        const branch_counts = try self.allocator.alloc(usize, plant_count);
        defer self.allocator.free(branch_counts);
        const node_counts = try self.allocator.alloc(usize, branch_count);
        defer self.allocator.free(node_counts);
        const sample_counts = try self.allocator.alloc(usize, node_count);
        defer self.allocator.free(sample_counts);
        for (branch_counts, 0..) |*count, plant| count.* = self.plant_branch_offsets[plant + 1] - self.plant_branch_offsets[plant];
        for (node_counts, 0..) |*count, branch| count.* = self.branch_node_offsets[branch + 1] - self.branch_node_offsets[branch];
        for (sample_counts, 0..) |*count, node| count.* = self.node_sample_offsets[node + 1] - self.node_sample_offsets[node];
        var result = try State.init(self.allocator, self.cell_count, self.species_count, branch_counts, node_counts, sample_counts);
        var destination_fields = floatFieldPointers(&result);
        const source_fields = constFloatFieldPointers(&self);
        copyFloatFields(&destination_fields, &source_fields);
        return result;
    }

    pub fn nodeRange(self: State, branch: usize) !Range {
        if (branch + 1 >= self.branch_node_offsets.len) return error.CanopyBranchIndexOutOfBounds;
        return .{ .first = self.branch_node_offsets[branch], .end = self.branch_node_offsets[branch + 1] };
    }

    pub fn sampleRange(self: State, node: usize) !Range {
        if (node + 1 >= self.node_sample_offsets.len) return error.CanopyNodeIndexOutOfBounds;
        return .{ .first = self.node_sample_offsets[node], .end = self.node_sample_offsets[node + 1] };
    }

    /// Clears all persistent and diagnostic canopy coordinates owned by one
    /// runtime plant while retaining its allocated compact topology. STARTQ
    /// initialization can then reconstruct the new crop in-place without
    /// carrying harvested organ, mobile-pool, salt, or photosynthetic history.
    pub fn clearPlantForReconstruction(self: *State, plant: usize) !void {
        @setEvalBranchQuota(40_000);
        const plant_count = try std.math.mul(usize, self.cell_count, self.species_count);
        if (plant >= plant_count) return error.CanopyPlantIndexOutOfBounds;
        const branches = try self.branchRange(plant);
        const node_first = self.branch_node_offsets[branches.first];
        const node_end = self.branch_node_offsets[branches.end];
        const sample_first = self.node_sample_offsets[node_first];
        const sample_end = self.node_sample_offsets[node_end];
        var float_fields = floatFieldPointers(self);
        clearPlantFloatFields(
            &float_fields,
            plant,
            branches,
            .{ .first = node_first, .end = node_end },
            .{ .first = sample_first, .end = sample_end },
        );
    }

    /// Atomically restores one previously grown plant to STARTQ's one branch,
    /// one node topology. Other plants retain every value and relative order.
    pub fn compactPlantToInitialTopology(self: *State, plant: usize) !void {
        @setEvalBranchQuota(50_000);
        const plant_count = self.plant_branch_offsets.len - 1;
        if (plant >= plant_count) return error.CanopyPlantIndexOutOfBounds;
        const branches = try self.branchRange(plant);
        if (branches.first == branches.end) return error.CanopyInitialTopologyMissingBranch;
        if (branches.end - branches.first == 1 and self.branch_node_offsets[branches.first + 1] - self.branch_node_offsets[branches.first] == 1) return;
        const retained_node = self.branch_node_offsets[branches.first];
        if (retained_node == self.branch_node_offsets[branches.first + 1]) return error.CanopyInitialTopologyMissingNode;
        const branch_remove_first = branches.first + 1;
        const branch_remove_end = branches.end;
        const node_remove_first = retained_node + 1;
        const node_remove_end = self.branch_node_offsets[branches.end];
        const sample_remove_first = self.node_sample_offsets[node_remove_first];
        const sample_remove_end = self.node_sample_offsets[node_remove_end];

        const branch_counts = try self.allocator.alloc(usize, plant_count);
        defer self.allocator.free(branch_counts);
        for (branch_counts, 0..) |*count, index| count.* = if (index == plant) 1 else self.plant_branch_offsets[index + 1] - self.plant_branch_offsets[index];
        const new_branch_count = (self.branch_node_offsets.len - 1) - (branch_remove_end - branch_remove_first);
        const node_counts = try self.allocator.alloc(usize, new_branch_count);
        defer self.allocator.free(node_counts);
        var destination_branch: usize = 0;
        for (0..self.branch_node_offsets.len - 1) |source_branch| {
            if (source_branch >= branch_remove_first and source_branch < branch_remove_end) continue;
            node_counts[destination_branch] = if (source_branch == branches.first) 1 else self.branch_node_offsets[source_branch + 1] - self.branch_node_offsets[source_branch];
            destination_branch += 1;
        }
        const new_node_count = (self.node_sample_offsets.len - 1) - (node_remove_end - node_remove_first);
        const sample_counts = try self.allocator.alloc(usize, new_node_count);
        defer self.allocator.free(sample_counts);
        var destination_node: usize = 0;
        for (0..self.node_sample_offsets.len - 1) |source_node| {
            if (source_node >= node_remove_first and source_node < node_remove_end) continue;
            sample_counts[destination_node] = self.node_sample_offsets[source_node + 1] - self.node_sample_offsets[source_node];
            destination_node += 1;
        }
        var replacement = try State.init(self.allocator, self.cell_count, self.species_count, branch_counts, node_counts, sample_counts);
        errdefer replacement.deinit();
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            if (comptime std.mem.indexOf(u8, field.name, "_by_species_") != null and std.mem.startsWith(u8, field.name, "branch_"))
                copyRemovingRange(@field(replacement, field.name), @field(self, field.name), branch_remove_first * 8, branch_remove_end * 8)
            else if (comptime std.mem.startsWith(u8, field.name, "branch_"))
                copyRemovingRange(@field(replacement, field.name), @field(self, field.name), branch_remove_first, branch_remove_end)
            else if (comptime std.mem.startsWith(u8, field.name, "node_"))
                copyRemovingRange(@field(replacement, field.name), @field(self, field.name), node_remove_first, node_remove_end)
            else if (comptime std.mem.startsWith(u8, field.name, "sample_"))
                copyRemovingRange(@field(replacement, field.name), @field(self, field.name), sample_remove_first, sample_remove_end)
            else
                @memcpy(@field(replacement, field.name), @field(self, field.name));
        };
        var previous = self.*;
        self.* = replacement;
        previous.deinit();
    }

    /// Inserts a branch after the selected plant's existing branches. Growth is
    /// infrequent relative to hourly kernels, so an atomic compact rebuild keeps
    /// iteration contiguous while removing any compile-time branch/node ceiling.
    pub fn appendBranch(self: *State, plant: usize, sample_count_by_new_node: []const usize) !usize {
        @setEvalBranchQuota(50_000);
        if (plant + 1 >= self.plant_branch_offsets.len) return error.CanopyPlantIndexOutOfBounds;
        const plant_count = self.plant_branch_offsets.len - 1;
        const old_branch_count = self.branch_node_offsets.len - 1;
        const old_node_count = self.node_sample_offsets.len - 1;
        const inserted_branch = self.plant_branch_offsets[plant + 1];
        const inserted_node = self.branch_node_offsets[inserted_branch];
        const inserted_sample = self.node_sample_offsets[inserted_node];
        const added_node_count = sample_count_by_new_node.len;
        const added_sample_count = try checkedSum(sample_count_by_new_node);

        const branch_counts = try self.allocator.alloc(usize, plant_count);
        defer self.allocator.free(branch_counts);
        for (branch_counts, 0..) |*count, index| count.* = self.plant_branch_offsets[index + 1] - self.plant_branch_offsets[index] + @intFromBool(index == plant);
        const node_counts = try self.allocator.alloc(usize, try std.math.add(usize, old_branch_count, 1));
        defer self.allocator.free(node_counts);
        for (0..inserted_branch) |branch| node_counts[branch] = self.branch_node_offsets[branch + 1] - self.branch_node_offsets[branch];
        node_counts[inserted_branch] = added_node_count;
        for (inserted_branch..old_branch_count) |branch| node_counts[branch + 1] = self.branch_node_offsets[branch + 1] - self.branch_node_offsets[branch];
        const sample_counts = try self.allocator.alloc(usize, try std.math.add(usize, old_node_count, added_node_count));
        defer self.allocator.free(sample_counts);
        for (0..inserted_node) |node| sample_counts[node] = self.node_sample_offsets[node + 1] - self.node_sample_offsets[node];
        @memcpy(sample_counts[inserted_node .. inserted_node + added_node_count], sample_count_by_new_node);
        for (inserted_node..old_node_count) |node| sample_counts[node + added_node_count] = self.node_sample_offsets[node + 1] - self.node_sample_offsets[node];

        var replacement = try State.init(self.allocator, self.cell_count, self.species_count, branch_counts, node_counts, sample_counts);
        errdefer replacement.deinit();
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            if (comptime std.mem.indexOf(u8, field.name, "_by_species_") != null and std.mem.startsWith(u8, field.name, "branch_"))
                copyAroundInsertion(@field(replacement, field.name), @field(self, field.name), inserted_branch * 8, 8)
            else if (comptime std.mem.startsWith(u8, field.name, "branch_"))
                copyAroundInsertion(@field(replacement, field.name), @field(self, field.name), inserted_branch, 1)
            else if (comptime std.mem.startsWith(u8, field.name, "node_"))
                copyAroundInsertion(@field(replacement, field.name), @field(self, field.name), inserted_node, added_node_count)
            else if (comptime std.mem.startsWith(u8, field.name, "sample_"))
                copyAroundInsertion(@field(replacement, field.name), @field(self, field.name), inserted_sample, added_sample_count)
            else
                @memcpy(@field(replacement, field.name), @field(self, field.name));
        };
        var previous = self.*;
        self.* = replacement;
        previous.deinit();
        return inserted_branch;
    }

    /// Appends one node to a runtime branch through an atomic compact rebuild.
    /// Existing branch, node, and sample values retain their indices except for
    /// nodes and samples following the insertion point, which shift together.
    pub fn appendNode(self: *State, branch: usize, sample_count: usize) !usize {
        @setEvalBranchQuota(50_000);
        if (branch + 1 >= self.branch_node_offsets.len) return error.CanopyBranchIndexOutOfBounds;
        if (sample_count == 0) return error.InvalidCanopySampleCount;
        const plant_count = self.plant_branch_offsets.len - 1;
        const branch_count = self.branch_node_offsets.len - 1;
        const old_node_count = self.node_sample_offsets.len - 1;
        const inserted_node = self.branch_node_offsets[branch + 1];
        const inserted_sample = self.node_sample_offsets[inserted_node];

        const branch_counts = try self.allocator.alloc(usize, plant_count);
        defer self.allocator.free(branch_counts);
        const node_counts = try self.allocator.alloc(usize, branch_count);
        defer self.allocator.free(node_counts);
        const sample_counts = try self.allocator.alloc(usize, try std.math.add(usize, old_node_count, 1));
        defer self.allocator.free(sample_counts);
        for (branch_counts, 0..) |*count, plant| count.* = self.plant_branch_offsets[plant + 1] - self.plant_branch_offsets[plant];
        for (node_counts, 0..) |*count, index| count.* = self.branch_node_offsets[index + 1] - self.branch_node_offsets[index] + @intFromBool(index == branch);
        for (0..inserted_node) |node| sample_counts[node] = self.node_sample_offsets[node + 1] - self.node_sample_offsets[node];
        sample_counts[inserted_node] = sample_count;
        for (inserted_node..old_node_count) |node| sample_counts[node + 1] = self.node_sample_offsets[node + 1] - self.node_sample_offsets[node];

        var replacement = try State.init(self.allocator, self.cell_count, self.species_count, branch_counts, node_counts, sample_counts);
        errdefer replacement.deinit();
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            if (comptime std.mem.startsWith(u8, field.name, "node_"))
                copyAroundInsertion(@field(replacement, field.name), @field(self, field.name), inserted_node, 1)
            else if (comptime std.mem.startsWith(u8, field.name, "sample_"))
                copyAroundInsertion(@field(replacement, field.name), @field(self, field.name), inserted_sample, sample_count)
            else
                @memcpy(@field(replacement, field.name), @field(self, field.name));
        };
        var previous = self.*;
        self.* = replacement;
        previous.deinit();
        return inserted_node;
    }

    pub fn validateFinite(self: State) !void {
        const float_fields = constFloatFieldPointers(&self);
        try validateFiniteFloatFields(&float_fields);
    }
};

pub const Range = struct { first: usize, end: usize };

pub const ElementalMass = struct { carbon_g: f64 = 0, nitrogen_g: f64 = 0, phosphorus_g: f64 = 0 };

pub fn addElementalMass(left: ElementalMass, right: ElementalMass) ElementalMass {
    return .{ .carbon_g = left.carbon_g + right.carbon_g, .nitrogen_g = left.nitrogen_g + right.nitrogen_g, .phosphorus_g = left.phosphorus_g + right.phosphorus_g };
}

fn checkedSum(counts: []const usize) !usize {
    var total: usize = 0;
    for (counts) |count| total = try std.math.add(usize, total, count);
    return total;
}

fn makeOffsets(allocator: std.mem.Allocator, counts: []const usize) ![]usize {
    const offsets = try allocator.alloc(usize, try std.math.add(usize, counts.len, 1));
    errdefer allocator.free(offsets);
    offsets[0] = 0;
    for (counts, 0..) |count, index| offsets[index + 1] = try std.math.add(usize, offsets[index], count);
    return offsets;
}

const FloatFieldExtent = enum(u8) { plant, plant_kinetic, branch, branch_species, node, sample };

const float_field_count = count: {
    var count: usize = 0;
    for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        count += 1;
    };
    break :count count;
};

const FloatFieldPointers = [float_field_count]*[]f64;
const ConstFloatFieldPointers = [float_field_count]*const []f64;

const float_field_extent_kinds: [float_field_count]FloatFieldExtent = kinds: {
    @setEvalBranchQuota(100_000);
    var result: [float_field_count]FloatFieldExtent = undefined;
    var index: usize = 0;
    for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        result[index] = floatFieldExtentKind(field.name);
        index += 1;
    };
    break :kinds result;
};

const float_field_names: [float_field_count][]const u8 = names: {
    var result: [float_field_count][]const u8 = undefined;
    var index: usize = 0;
    for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        result[index] = field.name;
        index += 1;
    };
    break :names result;
};

fn floatFieldExtentKind(comptime field_name: []const u8) FloatFieldExtent {
    if (std.mem.indexOf(u8, field_name, "_by_kinetic_") != null) return .plant_kinetic;
    if (std.mem.indexOf(u8, field_name, "_by_species_") != null and std.mem.startsWith(u8, field_name, "branch_")) return .branch_species;
    if (std.mem.startsWith(u8, field_name, "plant_")) return .plant;
    if (std.mem.startsWith(u8, field_name, "branch_")) return .branch;
    if (std.mem.startsWith(u8, field_name, "node_")) return .node;
    if (std.mem.startsWith(u8, field_name, "sample_")) return .sample;
    @compileError("runtime canopy field must use a domain prefix: " ++ field_name);
}

noinline fn floatFieldPointers(state: *State) FloatFieldPointers {
    var result: FloatFieldPointers = undefined;
    comptime var index: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        result[index] = &@field(state, field.name);
        index += 1;
    };
    return result;
}

noinline fn constFloatFieldPointers(state: *const State) ConstFloatFieldPointers {
    var result: ConstFloatFieldPointers = undefined;
    comptime var index: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        result[index] = &@field(state, field.name);
        index += 1;
    };
    return result;
}

fn fieldExtent(kind: FloatFieldExtent, plant_count: usize, plant_kinetic_count: usize, branch_count: usize, node_count: usize, sample_count: usize) usize {
    return switch (kind) {
        .plant => plant_count,
        .plant_kinetic => plant_kinetic_count,
        .branch => branch_count,
        .branch_species => branch_count * 8,
        .node => node_count,
        .sample => sample_count,
    };
}

noinline fn allocateZeroedFloatField(allocator: std.mem.Allocator, count: usize) ![]f64 {
    const values = try allocator.alloc(f64, count);
    @memset(values, 0);
    return values;
}

noinline fn freeFloatFields(allocator: std.mem.Allocator, fields: []const *const []f64) void {
    for (fields) |field| allocator.free(field.*);
}

noinline fn copyFloatFields(destination: []const *const []f64, source: []const *const []f64) void {
    for (destination, source) |destination_field, source_field| @memcpy(destination_field.*, source_field.*);
}

noinline fn clearPlantFloatFields(fields: []const *const []f64, plant: usize, branches: Range, nodes: Range, samples: Range) void {
    for (fields, float_field_extent_kinds) |field, extent_kind| switch (extent_kind) {
        .plant => field.*[plant] = 0,
        .plant_kinetic => @memset(field.*[plant * 4 .. (plant + 1) * 4], 0),
        .branch => @memset(field.*[branches.first..branches.end], 0),
        .branch_species => @memset(field.*[branches.first * 8 .. branches.end * 8], 0),
        .node => @memset(field.*[nodes.first..nodes.end], 0),
        .sample => @memset(field.*[samples.first..samples.end], 0),
    };
}

noinline fn validateFiniteFloatFields(fields: []const *const []f64) !void {
    for (fields, float_field_names) |field, field_name| for (field.*, 0..) |value, index| if (!std.math.isFinite(value)) {
        std.log.err("non-finite canopy photosynthesis state: field={s} index={d} value={e}", .{ field_name, index, value });
        return error.NonFiniteCanopyPhotosynthesisState;
    };
}

fn copyAroundInsertion(destination: []f64, source: []const f64, insertion_index: usize, inserted_count: usize) void {
    @memcpy(destination[0..insertion_index], source[0..insertion_index]);
    @memcpy(destination[insertion_index + inserted_count ..], source[insertion_index..]);
}

fn copyRemovingRange(destination: []f64, source: []const f64, first: usize, end: usize) void {
    std.debug.assert(first <= end and end <= source.len and destination.len == source.len - (end - first));
    @memcpy(destination[0..first], source[0..first]);
    @memcpy(destination[first..], source[end..]);
}

test "canopy photosynthesis state releases every partial allocation prefix" {
    const fixed_field_allocation_count: usize = 3;
    for (0..fixed_field_allocation_count + float_field_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            State.init(failing.allocator(), 2, 2, &.{ 2, 1, 1, 1 }, &.{ 2, 1, 1, 1, 1 }, &.{ 1, 2, 1, 3, 2, 1 }),
        );
    }
}

test "canopy photosynthesis runtime field table preserves every field extent and clone value" {
    const branch_counts = [_]usize{ 2, 1, 1, 1 };
    const node_counts = [_]usize{ 2, 1, 1, 1, 1 };
    const sample_counts = [_]usize{ 1, 2, 1, 3, 2, 1 };
    const plant_count: usize = 4;
    const branch_count: usize = 5;
    const node_count: usize = 6;
    const sample_count: usize = 10;

    var state = try State.init(std.testing.allocator, 2, 2, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    var fields = floatFieldPointers(&state);
    for (&fields, float_field_extent_kinds, 0..) |field, extent_kind, field_index| {
        try std.testing.expectEqual(
            fieldExtent(extent_kind, plant_count, plant_count * 4, branch_count, node_count, sample_count),
            field.*.len,
        );
        for (field.*, 0..) |*value, value_index| value.* = @floatFromInt(field_index * 1000 + value_index + 1);
    }

    var cloned = try state.clone();
    defer cloned.deinit();
    const cloned_fields = constFloatFieldPointers(&cloned);
    for (&fields, &cloned_fields) |field, cloned_field| {
        try std.testing.expect(field.*.ptr != cloned_field.*.ptr);
        try std.testing.expectEqualSlices(f64, field.*, cloned_field.*);
    }
}

test "canopy reconstruction clear matches every field domain and preserves neighbors" {
    const branch_counts = [_]usize{ 2, 1 };
    const node_counts = [_]usize{ 2, 1, 1 };
    const sample_counts = [_]usize{ 1, 2, 1, 3 };
    var state = try State.init(std.testing.allocator, 1, 2, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    var fields = floatFieldPointers(&state);
    for (&fields, 0..) |field, field_index| {
        for (field.*, 0..) |*value, value_index| value.* = @floatFromInt(field_index * 1000 + value_index + 1);
    }

    try state.clearPlantForReconstruction(0);
    const target_branches = Range{ .first = 0, .end = 2 };
    const target_nodes = Range{ .first = 0, .end = 3 };
    const target_samples = Range{ .first = 0, .end = 4 };
    for (&fields, float_field_extent_kinds, 0..) |field, extent_kind, field_index| {
        for (field.*, 0..) |value, value_index| {
            const cleared = switch (extent_kind) {
                .plant => value_index == 0,
                .plant_kinetic => value_index < 4,
                .branch => value_index >= target_branches.first and value_index < target_branches.end,
                .branch_species => value_index >= target_branches.first * 8 and value_index < target_branches.end * 8,
                .node => value_index >= target_nodes.first and value_index < target_nodes.end,
                .sample => value_index >= target_samples.first and value_index < target_samples.end,
            };
            const expected: f64 = if (cleared) 0 else @floatFromInt(field_index * 1000 + value_index + 1);
            try std.testing.expectEqual(expected, value);
        }
    }
}

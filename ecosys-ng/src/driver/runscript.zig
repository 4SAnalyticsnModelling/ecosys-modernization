const std = @import("std");
const core_config = @import("../core/config.zig");

const delimited_input = @import("../io/input/delimited_input.zig");

const soil_solver_properties = @import("../soil/water/solver_properties.zig");

const soil_hourly_workspace = @import("../soil/runtime/hourly_workspace.zig");

const soil_process_science = @import("../soil/runtime/process_pipeline.zig");

const soil_gas_transport_step = @import("../soil/gas/transport_step.zig");

const plant_root_gas_exchange = @import("../plant/root/plant_root_gas_exchange.zig");

const plant_root_nutrient_uptake = @import("../plant/root/plant_root_nutrient_uptake.zig");

const plant_root_salt_exchange = @import("../plant/root/plant_root_salt_exchange.zig");

const plant_root_exudation = @import("../plant/root/plant_root_exudation.zig");

const plant_root_mycorrhizal_exchange = @import("../plant/root/plant_root_mycorrhizal_exchange.zig");

const plant_root_porosity = @import("../plant/root/plant_root_porosity.zig");

const plant_root_metabolism = @import("../plant/root/plant_root_metabolism.zig");

const plant_organ_partition = @import("../plant/partition/organ.zig");

const shoot_growth_metabolism = @import("../plant/growth/shoot_growth_metabolism.zig");

const shoot_growth_runtime = @import("../plant/growth/shoot_growth_runtime.zig");

const plant_symbiotic_fixation = @import("../canopy/symbiosis/plant_symbiotic_fixation.zig");

const plant_root_disturbance = @import("../plant/root/plant_root_disturbance.zig");

const soil_combustion = @import("../soil/organic/combustion.zig");

const plant_shoot_root_exchange = @import("../plant/exchange/shoot_root.zig");

const plant_storage_remobilization = @import("../plant/growth/storage_remobilization.zig");

const plant_initialization = @import("../plant/initialization/seed_and_population.zig");

const plant_root_system = @import("../plant/root/plant_root_system.zig");

const plant_phenology = @import("../plant/lifecycle/phenology.zig");

const plant_pool_aggregation = @import("../plant/accounting/pool_aggregation.zig");

const canopy_photosynthesis = @import("../canopy/photosynthesis/photosynthesis.zig");

const canopy_biochemistry = @import("../canopy/photosynthesis/biochemistry.zig");

const canopy_optics = @import("../canopy/radiation/optics.zig");

const canopy_precipitation_retention = @import("../canopy/energy/precipitation_retention.zig");

const soil_plant_available_nutrients = @import("../soil/nutrients/plant_available_nutrients.zig");

const soil_chemistry_initialization = @import("../soil/chemistry/initialization.zig");

const snow_compaction = @import("../soil/water/snow_compaction.zig");

const snow_heat_conduction = @import("../soil/water/snow_heat_conduction.zig");

const snow_vapor_equilibrium = @import("../soil/water/snow_vapor_equilibrium.zig");

const snow_vapor_diffusion = @import("../soil/water/snow_vapor_diffusion.zig");

const surface_gas_boundary_conductance = @import("../surface/gas_boundary_conductance.zig");

const surface_aerodynamics = @import("../surface/aerodynamics.zig");

const surface_runoff = @import("../surface/runoff.zig");

const surface_precipitation = @import("../surface/precipitation.zig");

const ground_air_exchange = @import("../surface/ground_air_exchange.zig");

const canopy_surface_exchange = @import("../canopy/energy/surface_exchange.zig");

const plant_soil_exchange = @import("../plant/exchange/soil.zig");

const spatial_grid = @import("../state/spatial_grid.zig");

pub const Domain = struct {
    west_column: usize,
    north_row: usize,
    east_column: usize,
    south_row: usize,

    pub fn columns(self: Domain) !usize {
        if (self.east_column < self.west_column) return error.InvalidDomain;
        return try std.math.add(usize, self.east_column - self.west_column, 1);
    }

    pub fn rows(self: Domain) !usize {
        if (self.south_row < self.north_row) return error.InvalidDomain;
        return try std.math.add(usize, self.south_row - self.north_row, 1);
    }
};

pub const SceneFiles = struct {
    weather_grid_file: []const u8,
    options: []const u8,
    land_management: []const u8,
    plant_management: []const u8,
    output_editors: [10][]const u8,
};

pub const Scenario = struct {
    first_scene_index: usize,
    scene_count: usize,
    repeat_count: usize,
};

pub const GeothermalControls = struct {
    enabled: bool,
    minimum_source_depth_m: f64,
    source_depth_below_profile_m: f64,
    conductivity_m_megajoules_per_h_k: f64,
    geothermal_flux_megajoules_per_m2_h: f64,
};

pub const SoilGeometryParameters = struct {
    organic_carbon_specific_volume_m3_per_g: f64,
    organic_horizon_threshold_g_c_per_megagram: f64,
    ice_to_water_specific_volume_difference: f64,
    minimum_layer_thickness_m: f64,
};

pub const SeasonalTurnoverParameters = struct {
    litterfall_rate_per_h: f64,
    litterfall_delay_threshold_h: f64,

    pub fn validate(self: SeasonalTurnoverParameters) !void {
        if (!std.math.isFinite(self.litterfall_rate_per_h) or
            !std.math.isFinite(self.litterfall_delay_threshold_h))
            return error.NonFiniteSeasonalTurnoverParameter;
        if (self.litterfall_rate_per_h <= 0 or self.litterfall_rate_per_h > 1 or
            self.litterfall_delay_threshold_h <= 0)
            return error.InvalidSeasonalTurnoverParameter;
    }
};

pub const RunScript = struct {
    allocator: std.mem.Allocator,
    /// Directory (relative to the runscript's own directory) under which all
    /// input file records are resolved. Defaults to "." when the optional
    /// `input_root` leading record is absent, preserving old runscripts.
    input_root: []const u8,
    /// Directory (relative to the runscript's own directory) under which the
    /// structured output tree (logs/tile_io/checkpoints/modelled_outputs) is
    /// created. Empty when the optional `output_root` leading record is
    /// absent, in which case the runscript directory itself is used.
    output_root: []const u8,
    domain: Domain,
    geospatial_bounds: ?spatial_grid.BoundsDegrees,
    tile_row_count: usize,
    tile_column_count: usize,
    lateral_flow_halo_cell_count: usize,
    grid_input_file: []const u8,
    plant_species_count: usize,
    worker_count: usize,
    tile_cell_count: usize,
    relative_tolerance: f64,
    absolute_tolerance: f64,
    nonlinear_tolerance: core_config.NonlinearTolerance,
    mass_balance_tolerance: f64,
    negligible_quantity_threshold: f64,
    mass_balance_relative_tolerance: f64,
    mass_balance_absolute_tolerance: core_config.MassBalanceAbsoluteTolerance,
    physical_tolerance: core_config.PhysicalTolerance,
    max_nonlinear_iterations: u16,
    picard_relaxation: f64,
    soil_solver_parameters: soil_solver_properties.RuntimeParameters,
    soil_process_parameters: soil_hourly_workspace.RuntimeParameters,
    soil_gas_transport_parameters: soil_gas_transport_step.RuntimeParameters,
    soil_phase_heat_parameters: soil_process_science.RuntimeParameters,
    geothermal_controls: GeothermalControls,
    water_table_air_fraction_threshold: f64,
    active_layer_ice_fraction_threshold: f64,
    soil_geometry_parameters: SoilGeometryParameters,
    surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
    surface_pond_activation_heat_capacity_megajoules_per_m2_k: f64,
    soil_longwave_emissivity: f64,
    snow_longwave_emissivity: f64,
    canopy_longwave_emissivity: f64,
    snow_full_cover_depth_m: f64,
    surface_sensible_heat_conductance_megajoules_per_m2_h_k: f64,
    surface_latent_heat_conductance_megajoules_per_m2_h_kpa: f64,
    surface_vapor_activity_fraction: f64,
    minimum_surface_temperature_k: f64,
    maximum_surface_temperature_k: f64,
    snow_layer_bottom_depth_m: []f64,
    initial_snow_density_megagrams_per_m3: f64,
    snow_ice_density_megagrams_per_m3: f64,
    snow_latent_heat_of_fusion_megajoules_per_m3: f64,
    /// REDIST VHCPW coefficient for solid snow water equivalent. Run-owned
    /// so precipitation, phase/vapor producers, and storage census share one
    /// authoritative value.
    snow_solid_heat_capacity_megajoules_per_m3_k: f64,
    snow_phase_damping_divisor: f64,
    snow_compaction_parameters: snow_compaction.Parameters,
    snow_heat_conduction_parameters: snow_heat_conduction.Parameters,
    snow_vapor_parameters: snow_vapor_equilibrium.Parameters,
    snow_vapor_diffusion_parameters: snow_vapor_diffusion.Parameters,
    surface_gas_resistance_parameters: surface_gas_boundary_conductance.Parameters,
    surface_runoff_parameters: surface_runoff.Parameters,
    rainfall_impact_parameters: surface_precipitation.RainfallImpactParameters,
    surface_aerodynamic_parameters: surface_aerodynamics.Parameters,
    ground_air_parameters: ground_air_exchange.Parameters,
    canopy_surface_exchange_parameters: canopy_surface_exchange.Parameters,
    canopy_sensible_surface_resistance_h_per_m: f64,
    canopy_latent_surface_resistance_h_per_m: f64,
    canopy_minimum_resistance_h_per_m: f64,
    canopy_maximum_resistance_h_per_m: f64,
    canopy_ammonia_exchange_parameters: plant_soil_exchange.CanopyAmmoniaExchangeParameters,
    root_axes_per_plant: usize,
    canopy_layer_count: usize,
    canopy_discretization: @import("../canopy/morphology/geometry.zig").Discretization,
    stalk_volume_m3_per_g_c: f64,
    standing_dead_partition_parameters: plant_initialization.StandingDeadPartitionParameters,
    plant_heat_water_parameters: plant_initialization.PlantHeatWaterParameters,
    plant_geometry_parameters: plant_initialization.PlantGeometryParameters,
    phenology_initialization_parameters: plant_initialization.PhenologyInitializationParameters,
    root_initialization_parameters: plant_root_system.InitializationParameters,
    root_morphology_parameters: plant_root_system.MorphologyParameters,
    standing_dead_sapwood_thickness_m: f64,
    standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k: f64,
    standing_dead_emissivity: f64,
    standing_dead_activation_heat_capacity_megajoules_per_m2_k: f64,
    standing_dead_effective_heat_capacity_floor_megajoules_per_m2_k: f64,
    woody_optics_parameters: canopy_optics.WoodyOpticsParameters,
    canopy_retention_parameters: canopy_precipitation_retention.Parameters,
    shoot_control_parameters: plant_initialization.ShootControlParameters,
    c4_carbon_parameters: canopy_photosynthesis.C4CarbonParameters,
    thermal_acclimation_parameters: plant_initialization.ThermalAcclimationParameters,
    canopy_stress_parameters: canopy_biochemistry.StressParameters,
    phenology_parameters: plant_phenology.Parameters,
    plant_pool_parameters: plant_pool_aggregation.RuntimeParameters,
    dynamic_plant_salts: bool,
    seed_set_parameters: canopy_photosynthesis.SeedSetParameters,
    root_gas_parameters: plant_root_gas_exchange.RuntimeParameters,
    root_nutrient_parameters: plant_root_nutrient_uptake.RuntimeParameters,
    root_salt_parameters: plant_root_salt_exchange.Parameters,
    root_mycorrhizal_exchange_parameters: plant_root_mycorrhizal_exchange.Parameters,
    root_exudation_parameters: plant_root_exudation.Parameters,
    root_porosity_parameters: plant_root_porosity.Parameters,
    root_metabolism_parameters: plant_root_metabolism.SecondaryRootParameters,
    organ_partition_parameters: plant_organ_partition.Parameters,
    shoot_metabolism_parameters: shoot_growth_metabolism.Parameters,
    shoot_node_growth_parameters: shoot_growth_runtime.NodeGrowthParameters,
    shoot_senescence_recycling_parameters: shoot_growth_runtime.SenescenceRecyclingParameters,
    seasonal_turnover_parameters: SeasonalTurnoverParameters,
    branch_mobile_exchange_parameters: shoot_growth_runtime.BranchMobileExchangeParameters,
    symbiotic_fixation_parameters: plant_symbiotic_fixation.RuntimeParameters,
    plant_fire_combustion_parameters: plant_root_disturbance.CombustionParameters,
    soil_fire_combustion_parameters: soil_combustion.Parameters,
    shoot_root_exchange_parameters: plant_shoot_root_exchange.Parameters,
    storage_remobilization_parameters: plant_storage_remobilization.Parameters,
    plant_nutrient_initialization: soil_plant_available_nutrients.InitializationParameters,
    microbial_substrate_count: usize,
    microbial_population_count: usize,
    organic_initialization_file: []const u8,
    surface_gas_parameter_file: []const u8,
    soil_nitrogen_parameter_file: []const u8,
    chemistry_initialization: soil_chemistry_initialization.ProfileSolubleParameters,
    chemistry_primary_initialization: soil_chemistry_initialization.PrimaryInitializationParameters,
    chemistry_reaction_file: []const u8,
    fertilizer_nitrogen_molar_mass_g_per_mol: f64,
    execution_repeat_count: usize,
    scenarios: []Scenario,
    scenes: []SceneFiles,

    pub fn deinit(self: *RunScript) void {
        self.allocator.free(self.snow_layer_bottom_depth_m);
        self.allocator.free(self.input_root);
        self.allocator.free(self.output_root);
        self.allocator.free(self.organic_initialization_file);
        self.allocator.free(self.surface_gas_parameter_file);
        self.allocator.free(self.soil_nitrogen_parameter_file);
        self.allocator.free(self.chemistry_reaction_file);
        self.allocator.free(self.grid_input_file);
        for (self.scenes) |scene| {
            self.allocator.free(scene.weather_grid_file);
            self.allocator.free(scene.options);
            self.allocator.free(scene.land_management);
            self.allocator.free(scene.plant_management);
            for (scene.output_editors) |name| self.allocator.free(name);
        }
        self.allocator.free(self.scenes);
        self.allocator.free(self.scenarios);
        self.* = undefined;
    }

    pub fn gridCellCount(self: RunScript) !usize {
        return try std.math.mul(usize, try self.domain.columns(), try self.domain.rows());
    }

    /// Compatibility-only forwarding for the legacy runtime scalar. Production
    /// science consumes `nonlinear_tolerance` or `physical_tolerance` instead.
    pub fn compatibilityLegacyAbsoluteTolerance(self: RunScript) f64 {
        return self.absolute_tolerance;
    }

    /// Compatibility-only forwarding for the legacy untyped presence scalar.
    /// Production science consumes a named field from `physical_tolerance`.
    pub fn compatibilityLegacyPresenceTolerance(self: RunScript) f64 {
        return self.negligible_quantity_threshold;
    }
};

/// Allocations acquired directly by `parse` before ownership is transferred to
/// the returned `RunScript`. Keeping their error cleanup in one out-of-line
/// routine prevents every later `try` from carrying another copy of every
/// preceding `allocator.free` while preserving the same success-path owner.
const ParseOwnership = struct {
    input_root: ?[]u8 = null,
    output_root: ?[]u8 = null,
    snow_layer_bottom_depth_m: ?[]f64 = null,
    organic_initialization_file: ?[]u8 = null,
    surface_gas_parameter_file: ?[]u8 = null,
    soil_nitrogen_parameter_file: ?[]u8 = null,
    chemistry_reaction_file: ?[]u8 = null,
    grid_input_file: ?[]u8 = null,
    scenarios: ?[]Scenario = null,

    noinline fn rollback(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.scenarios) |value| allocator.free(value);
        if (self.grid_input_file) |value| allocator.free(value);
        if (self.chemistry_reaction_file) |value| allocator.free(value);
        if (self.soil_nitrogen_parameter_file) |value| allocator.free(value);
        if (self.surface_gas_parameter_file) |value| allocator.free(value);
        if (self.organic_initialization_file) |value| allocator.free(value);
        if (self.snow_layer_bottom_depth_m) |value| allocator.free(value);
        if (self.output_root) |value| allocator.free(value);
        if (self.input_root) |value| allocator.free(value);
        self.* = .{};
    }
};

pub noinline fn parse(allocator: std.mem.Allocator, source: []const u8) !RunScript {
    const body = extractInputBody(source);
    try rejectEmptyExplicitFields(body);

    var ownership: ParseOwnership = .{};
    errdefer ownership.rollback(allocator);
    var records = RunscriptRecordCursor{ .source = body };
    const input_root = try duplicateOptionalTaggedRecord(allocator, &records, "input_root", ".");
    ownership.input_root = input_root;
    const output_root = try duplicateOptionalTaggedRecord(allocator, &records, "output_root", "");
    ownership.output_root = output_root;
    const header = try parseHeaderRuntimeRecords(allocator, &records);

    const soil_surface = try parseSoilSurfaceRecords(allocator, &records, header.max_nonlinear_iterations);
    ownership.snow_layer_bottom_depth_m = soil_surface.snow_layer_bottom_depth_m;

    const plant_records = try parsePlantInitializationRecords(&records);

    const root_process = try parseRootProcessRecords(&records);

    const plant_growth_process = try parsePlantGrowthProcessRecords(&records);

    var tokens = delimited_input.recordTokens(try records.next("plant_nutrients record"));
    try requireRunscriptRecordTag(&tokens, "plant_nutrients", error.MissingPlantNutrientsRecord);
    const plant_nutrient_initialization: soil_plant_available_nutrients.InitializationParameters = .{
        .initial_ammonium_band_fraction = try nextFloat(&tokens, "initial ammonium band fraction"),
        .initial_nitrate_band_fraction = try nextFloat(&tokens, "initial nitrate band fraction"),
        .initial_phosphate_band_fraction = try nextFloat(&tokens, "initial phosphate band fraction"),
        .initial_h2po4_fraction = try nextFloat(&tokens, "initial H2PO4 fraction of soluble phosphate"),
        .initial_ammonium_band_row_spacing_m = try nextFloat(&tokens, "initial ammonium band row spacing in m"),
        .initial_nitrate_band_row_spacing_m = try nextFloat(&tokens, "initial nitrate band row spacing in m"),
        .initial_phosphate_band_row_spacing_m = try nextFloat(&tokens, "initial phosphate band row spacing in m"),
    };
    try requireRunscriptRecordEnd(&tokens, "plant_nutrients");
    try plant_nutrient_initialization.validate();
    tokens = delimited_input.recordTokens(try records.next("microbial_dimensions record"));
    try requireRunscriptRecordTag(&tokens, "microbial_dimensions", error.MissingMicrobialDimensionsRecord);
    const microbial_substrate_count = try nextRecordUnsigned(&tokens);
    const microbial_population_count = try nextRecordUnsigned(&tokens);
    try requireRunscriptRecordEnd(&tokens, "microbial_dimensions");
    if (microbial_substrate_count == 0 or microbial_population_count == 0) return error.InvalidMicrobialDimensions;
    tokens = delimited_input.recordTokens(try records.next("organic_initialization_file record"));
    try requireRunscriptRecordTag(&tokens, "organic_initialization_file", error.MissingOrganicInitializationFileRecord);
    const organic_initialization_file = try allocator.dupe(u8, tokens.next() orelse return error.ShortRunscriptRecord);
    ownership.organic_initialization_file = organic_initialization_file;
    try requireRunscriptRecordEnd(&tokens, "organic_initialization_file");
    tokens = delimited_input.recordTokens(try records.next("surface_gas_parameter_file record"));
    try requireRunscriptRecordTag(&tokens, "surface_gas_parameter_file", error.MissingSurfaceGasParameterFileRecord);
    const surface_gas_parameter_file = try allocator.dupe(u8, tokens.next() orelse return error.ShortRunscriptRecord);
    ownership.surface_gas_parameter_file = surface_gas_parameter_file;
    try requireRunscriptRecordEnd(&tokens, "surface_gas_parameter_file");
    tokens = delimited_input.recordTokens(try records.next("soil_nitrogen_parameter_file record"));
    try requireRunscriptRecordTag(&tokens, "soil_nitrogen_parameter_file", error.MissingSoilNitrogenParameterFileRecord);
    const soil_nitrogen_parameter_file = try allocator.dupe(u8, tokens.next() orelse return error.ShortRunscriptRecord);
    ownership.soil_nitrogen_parameter_file = soil_nitrogen_parameter_file;
    try requireRunscriptRecordEnd(&tokens, "soil_nitrogen_parameter_file");
    tokens = delimited_input.recordTokens(try records.next("chemistry_initialization record"));
    try requireRunscriptRecordTag(&tokens, "chemistry_initialization", error.MissingChemistryInitializationRecord);
    const chemistry_initialization: soil_chemistry_initialization.ProfileSolubleParameters = .{
        .saturated_paste_phosphate_multiplier = try nextFloat(&tokens, "saturated-paste phosphate multiplier"),
        .water_activity_product_mol2_per_m6 = try nextFloat(&tokens, "water activity product in mol2 m-6"),
        .gibbsite_solubility_product_mol4_per_m12 = try nextFloat(&tokens, "gibbsite solubility product in mol4 m-12"),
        .ferric_hydroxide_solubility_product_mol4_per_m12 = try nextFloat(&tokens, "ferric hydroxide solubility product in mol4 m-12"),
        .phosphate_dissociation = .{
            .h3po4_to_h2po4_mol_per_m3 = try nextFloat(&tokens, "H3PO4 dissociation constant in mol m-3"),
            .h2po4_to_hpo4_mol_per_m3 = try nextFloat(&tokens, "H2PO4 dissociation constant in mol m-3"),
            .hpo4_to_po4_mol_per_m3 = try nextFloat(&tokens, "HPO4 dissociation constant in mol m-3"),
        },
    };
    try requireRunscriptRecordEnd(&tokens, "chemistry_initialization");
    inline for (.{ chemistry_initialization.saturated_paste_phosphate_multiplier, chemistry_initialization.water_activity_product_mol2_per_m6, chemistry_initialization.gibbsite_solubility_product_mol4_per_m12, chemistry_initialization.ferric_hydroxide_solubility_product_mol4_per_m12, chemistry_initialization.phosphate_dissociation.h3po4_to_h2po4_mol_per_m3, chemistry_initialization.phosphate_dissociation.h2po4_to_hpo4_mol_per_m3, chemistry_initialization.phosphate_dissociation.hpo4_to_po4_mol_per_m3 }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidChemistryInitializationParameters;
    if (chemistry_initialization.saturated_paste_phosphate_multiplier > 1) return error.InvalidChemistryInitializationParameters;

    tokens = delimited_input.recordTokens(try records.next("chemistry_units record"));
    try requireRunscriptRecordTag(&tokens, "chemistry_units", error.MissingChemistryUnitsRecord);
    const chemistry_primary_initialization: soil_chemistry_initialization.PrimaryInitializationParameters = .{
        .soluble = chemistry_initialization,
        .molar_mass_g_per_mol = .{
            .nitrogen = try nextFloat(&tokens, "nitrogen molar mass in g mol-1"),
            .phosphorus = try nextFloat(&tokens, "phosphorus molar mass in g mol-1"),
            .aluminum = try nextFloat(&tokens, "aluminum molar mass in g mol-1"),
            .iron = try nextFloat(&tokens, "iron molar mass in g mol-1"),
            .calcium = try nextFloat(&tokens, "calcium molar mass in g mol-1"),
            .magnesium = try nextFloat(&tokens, "magnesium molar mass in g mol-1"),
            .sodium = try nextFloat(&tokens, "sodium molar mass in g mol-1"),
            .potassium = try nextFloat(&tokens, "potassium molar mass in g mol-1"),
            .sulfur = try nextFloat(&tokens, "sulfur molar mass in g mol-1"),
            .chloride = try nextFloat(&tokens, "chloride molar mass in g mol-1"),
        },
        .minimum_ammonium_g_n_per_megagram = try nextFloat(&tokens, "minimum ammonium in g N Mg-1"),
        .minimum_calcium_g_per_megagram = try nextFloat(&tokens, "minimum calcium in g Mg-1"),
        .soil_ammonium_extract_multiplier = try nextFloat(&tokens, "soil ammonium extract multiplier"),
        .extract_mol_per_megagram_to_mol_per_m3 = try nextFloat(&tokens, "extract mol Mg-1 to mol m-3 multiplier"),
    };
    try requireRunscriptRecordEnd(&tokens, "chemistry_units");
    const parameters = chemistry_primary_initialization;
    inline for (@typeInfo(soil_chemistry_initialization.ElementMolarMassesGPerMol).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.molar_mass_g_per_mol, field.name)) or @field(parameters.molar_mass_g_per_mol, field.name) <= 0) return error.InvalidChemistryInitializationParameters;
    inline for (.{ parameters.minimum_ammonium_g_n_per_megagram, parameters.minimum_calcium_g_per_megagram, parameters.soil_ammonium_extract_multiplier, parameters.extract_mol_per_megagram_to_mol_per_m3 }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidChemistryInitializationParameters;
    if (parameters.soil_ammonium_extract_multiplier > 1 or parameters.extract_mol_per_megagram_to_mol_per_m3 <= 0) return error.InvalidChemistryInitializationParameters;

    tokens = delimited_input.recordTokens(try records.next("chemistry_reaction_file record"));
    try requireRunscriptRecordTag(&tokens, "chemistry_reaction_file", error.MissingChemistryReactionFileRecord);
    const chemistry_reaction_file = try allocator.dupe(u8, tokens.next() orelse return error.ShortRunscriptRecord);
    ownership.chemistry_reaction_file = chemistry_reaction_file;
    try requireRunscriptRecordEnd(&tokens, "chemistry_reaction_file");
    tokens = delimited_input.recordTokens(try records.next("fertilizer_units record"));
    try requireRunscriptRecordTag(&tokens, "fertilizer_units", error.MissingFertilizerUnitsRecord);
    const fertilizer_nitrogen_molar_mass_g_per_mol = try nextFloat(&tokens, "fertilizer nitrogen molar mass in g mol-1");
    try requireRunscriptRecordEnd(&tokens, "fertilizer_units");
    if (!std.math.isFinite(fertilizer_nitrogen_molar_mass_g_per_mol) or fertilizer_nitrogen_molar_mass_g_per_mol <= 0) return error.InvalidFertilizerUnits;
    tokens = delimited_input.recordTokens(try records.next("grid_inputs record"));
    try requireRunscriptRecordTag(&tokens, "grid_inputs", error.MissingGridInputsRecord);
    const grid_input_file = try duplicateRequiredRecordString(allocator, &tokens);
    ownership.grid_input_file = grid_input_file;
    try requireRunscriptRecordEnd(&tokens, "grid_inputs");

    var scenarios: std.ArrayList(Scenario) = .empty;
    defer scenarios.deinit(allocator);
    var scenes: std.ArrayList(SceneFiles) = .empty;
    defer {
        for (scenes.items) |scene| freeScene(allocator, scene);
        scenes.deinit(allocator);
    }

    var execution_repeat_count: ?usize = null;
    while (true) {
        var group_tokens = delimited_input.recordTokens(try records.next("scenario group or 0 0 terminator"));
        const scenario_count = try nextRecordUnsigned(&group_tokens);
        const group_repeat_count = try nextRecordUnsigned(&group_tokens);
        try requireRunscriptRecordEnd(&group_tokens, "scenario group");
        if (scenario_count == 0 and group_repeat_count == 0) break;
        if (scenario_count == 0 or group_repeat_count == 0) return error.InvalidScenarioGroup;
        if (execution_repeat_count) |expected| {
            if (group_repeat_count != expected) return error.InconsistentExecutionRepeatCount;
        } else execution_repeat_count = group_repeat_count;

        var scenario_index: usize = 0;
        while (scenario_index < scenario_count) : (scenario_index += 1) {
            var scenario_tokens = delimited_input.recordTokens(try records.next("scenario record"));
            const scene_count = try nextRecordUnsigned(&scenario_tokens);
            const repeat_count = try nextRecordUnsigned(&scenario_tokens);
            try requireRunscriptRecordEnd(&scenario_tokens, "scenario");
            if (scene_count == 0 or repeat_count == 0) return error.EmptyScenario;
            const first_scene_index = scenes.items.len;
            var scene_index: usize = 0;
            while (scene_index < scene_count) : (scene_index += 1) {
                const scene = try parseSceneRecords(allocator, &records);
                errdefer freeScene(allocator, scene);
                try scenes.append(allocator, scene);
            }
            try scenarios.append(allocator, .{
                .first_scene_index = first_scene_index,
                .scene_count = scene_count,
                .repeat_count = repeat_count,
            });
        }
    }
    if (records.nextOptional() != null) return error.TrailingRunscriptData;
    if (scenarios.items.len == 0) return error.NoScenarios;

    const owned_scenarios = try scenarios.toOwnedSlice(allocator);
    ownership.scenarios = owned_scenarios;
    const owned_scenes = try scenes.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .input_root = input_root,
        .output_root = output_root,
        .domain = header.domain,
        .geospatial_bounds = header.geospatial_bounds,
        .tile_row_count = header.tile_row_count,
        .tile_column_count = header.tile_column_count,
        .lateral_flow_halo_cell_count = header.lateral_flow_halo_cell_count,
        .grid_input_file = grid_input_file,
        .plant_species_count = header.plant_species_count,
        .worker_count = header.worker_count,
        .tile_cell_count = header.tile_cell_count,
        .relative_tolerance = header.relative_tolerance,
        .absolute_tolerance = header.absolute_tolerance,
        .nonlinear_tolerance = header.nonlinear_tolerance,
        .mass_balance_tolerance = header.mass_balance_tolerance,
        .negligible_quantity_threshold = header.negligible_quantity_threshold,
        .mass_balance_relative_tolerance = header.mass_balance_relative_tolerance,
        .mass_balance_absolute_tolerance = header.mass_balance_absolute_tolerance,
        .physical_tolerance = header.physical_tolerance,
        .max_nonlinear_iterations = header.max_nonlinear_iterations,
        .picard_relaxation = header.picard_relaxation,
        .soil_solver_parameters = soil_surface.soil_solver_parameters,
        .soil_process_parameters = soil_surface.soil_process_parameters,
        .soil_gas_transport_parameters = soil_surface.soil_gas_transport_parameters,
        .soil_phase_heat_parameters = soil_surface.soil_phase_heat_parameters,
        .geothermal_controls = soil_surface.geothermal_controls,
        .water_table_air_fraction_threshold = soil_surface.water_table_air_fraction_threshold,
        .active_layer_ice_fraction_threshold = soil_surface.active_layer_ice_fraction_threshold,
        .soil_geometry_parameters = soil_surface.soil_geometry_parameters,
        .surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k = soil_surface.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
        .surface_pond_activation_heat_capacity_megajoules_per_m2_k = soil_surface.surface_pond_activation_heat_capacity_megajoules_per_m2_k,
        .soil_longwave_emissivity = soil_surface.soil_longwave_emissivity,
        .snow_longwave_emissivity = soil_surface.snow_longwave_emissivity,
        .canopy_longwave_emissivity = soil_surface.canopy_longwave_emissivity,
        .snow_full_cover_depth_m = soil_surface.snow_full_cover_depth_m,
        .surface_sensible_heat_conductance_megajoules_per_m2_h_k = soil_surface.surface_sensible_heat_conductance_megajoules_per_m2_h_k,
        .surface_latent_heat_conductance_megajoules_per_m2_h_kpa = soil_surface.surface_latent_heat_conductance_megajoules_per_m2_h_kpa,
        .surface_vapor_activity_fraction = soil_surface.surface_vapor_activity_fraction,
        .minimum_surface_temperature_k = soil_surface.minimum_surface_temperature_k,
        .maximum_surface_temperature_k = soil_surface.maximum_surface_temperature_k,
        .snow_layer_bottom_depth_m = soil_surface.snow_layer_bottom_depth_m,
        .initial_snow_density_megagrams_per_m3 = soil_surface.initial_snow_density_megagrams_per_m3,
        .snow_ice_density_megagrams_per_m3 = soil_surface.snow_ice_density_megagrams_per_m3,
        .snow_latent_heat_of_fusion_megajoules_per_m3 = soil_surface.snow_latent_heat_of_fusion_megajoules_per_m3,
        .snow_solid_heat_capacity_megajoules_per_m3_k = soil_surface.snow_solid_heat_capacity_megajoules_per_m3_k,
        .snow_phase_damping_divisor = soil_surface.snow_phase_damping_divisor,
        .snow_compaction_parameters = soil_surface.snow_compaction_parameters,
        .snow_heat_conduction_parameters = soil_surface.snow_heat_conduction_parameters,
        .snow_vapor_parameters = soil_surface.snow_vapor_parameters,
        .snow_vapor_diffusion_parameters = soil_surface.snow_vapor_diffusion_parameters,
        .surface_gas_resistance_parameters = soil_surface.surface_gas_resistance_parameters,
        .surface_runoff_parameters = soil_surface.surface_runoff_parameters,
        .rainfall_impact_parameters = soil_surface.rainfall_impact_parameters,
        .surface_aerodynamic_parameters = soil_surface.surface_aerodynamic_parameters,
        .ground_air_parameters = soil_surface.ground_air_parameters,
        .canopy_surface_exchange_parameters = soil_surface.canopy_surface_exchange_parameters,
        .canopy_sensible_surface_resistance_h_per_m = soil_surface.canopy_sensible_surface_resistance_h_per_m,
        .canopy_latent_surface_resistance_h_per_m = soil_surface.canopy_latent_surface_resistance_h_per_m,
        .canopy_minimum_resistance_h_per_m = soil_surface.canopy_minimum_resistance_h_per_m,
        .canopy_maximum_resistance_h_per_m = soil_surface.canopy_maximum_resistance_h_per_m,
        .canopy_ammonia_exchange_parameters = soil_surface.canopy_ammonia_exchange_parameters,
        .root_axes_per_plant = plant_records.root_axes_per_plant,
        .canopy_layer_count = plant_records.canopy_layer_count,
        .canopy_discretization = plant_records.canopy_discretization,
        .stalk_volume_m3_per_g_c = plant_records.stalk_volume_m3_per_g_c,
        .standing_dead_partition_parameters = plant_records.standing_dead_partition_parameters,
        .plant_heat_water_parameters = plant_records.plant_heat_water_parameters,
        .plant_geometry_parameters = plant_records.plant_geometry_parameters,
        .phenology_initialization_parameters = plant_records.phenology_initialization_parameters,
        .root_initialization_parameters = plant_records.root_initialization_parameters,
        .root_morphology_parameters = plant_records.root_morphology_parameters,
        .standing_dead_sapwood_thickness_m = plant_records.standing_dead_sapwood_thickness_m,
        .standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k = plant_records.standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k,
        .standing_dead_emissivity = plant_records.standing_dead_emissivity,
        .standing_dead_activation_heat_capacity_megajoules_per_m2_k = plant_records.standing_dead_activation_heat_capacity_megajoules_per_m2_k,
        .standing_dead_effective_heat_capacity_floor_megajoules_per_m2_k = plant_records.standing_dead_effective_heat_capacity_floor_megajoules_per_m2_k,
        .woody_optics_parameters = plant_records.woody_optics_parameters,
        .canopy_retention_parameters = plant_records.canopy_retention_parameters,
        .shoot_control_parameters = plant_records.shoot_control_parameters,
        .c4_carbon_parameters = plant_records.c4_carbon_parameters,
        .thermal_acclimation_parameters = plant_records.thermal_acclimation_parameters,
        .canopy_stress_parameters = plant_records.canopy_stress_parameters,
        .phenology_parameters = plant_records.phenology_parameters,
        .plant_pool_parameters = plant_records.plant_pool_parameters,
        .dynamic_plant_salts = plant_records.dynamic_plant_salts,
        .seed_set_parameters = plant_records.seed_set_parameters,
        .root_gas_parameters = root_process.root_gas_parameters,
        .root_nutrient_parameters = root_process.root_nutrient_parameters,
        .root_salt_parameters = root_process.root_salt_parameters,
        .root_mycorrhizal_exchange_parameters = root_process.root_mycorrhizal_exchange_parameters,
        .root_exudation_parameters = root_process.root_exudation_parameters,
        .root_porosity_parameters = root_process.root_porosity_parameters,
        .root_metabolism_parameters = root_process.root_metabolism_parameters,
        .organ_partition_parameters = plant_growth_process.organ_partition_parameters,
        .shoot_metabolism_parameters = plant_growth_process.shoot_metabolism_parameters,
        .shoot_node_growth_parameters = plant_growth_process.shoot_node_growth_parameters,
        .shoot_senescence_recycling_parameters = shoot_growth_runtime.sourceSenescenceRecyclingParameters(),
        .seasonal_turnover_parameters = plant_growth_process.seasonal_turnover_parameters,
        .branch_mobile_exchange_parameters = plant_growth_process.branch_mobile_exchange_parameters,
        .symbiotic_fixation_parameters = plant_growth_process.symbiotic_fixation_parameters,
        .plant_fire_combustion_parameters = plant_growth_process.plant_fire_combustion_parameters,
        .soil_fire_combustion_parameters = plant_growth_process.soil_fire_combustion_parameters,
        .shoot_root_exchange_parameters = plant_growth_process.shoot_root_exchange_parameters,
        .storage_remobilization_parameters = plant_growth_process.storage_remobilization_parameters,
        .plant_nutrient_initialization = plant_nutrient_initialization,
        .microbial_substrate_count = microbial_substrate_count,
        .microbial_population_count = microbial_population_count,
        .organic_initialization_file = organic_initialization_file,
        .surface_gas_parameter_file = surface_gas_parameter_file,
        .soil_nitrogen_parameter_file = soil_nitrogen_parameter_file,
        .chemistry_initialization = chemistry_initialization,
        .chemistry_primary_initialization = chemistry_primary_initialization,
        .chemistry_reaction_file = chemistry_reaction_file,
        .fertilizer_nitrogen_molar_mass_g_per_mol = fertilizer_nitrogen_molar_mass_g_per_mol,
        .execution_repeat_count = execution_repeat_count.?,
        .scenarios = owned_scenarios,
        .scenes = owned_scenes,
    };
}

const SoilSurfaceRecords = struct {
    soil_solver_parameters: soil_solver_properties.RuntimeParameters,
    soil_process_parameters: soil_hourly_workspace.RuntimeParameters,
    soil_gas_transport_parameters: soil_gas_transport_step.RuntimeParameters,
    soil_phase_heat_parameters: soil_process_science.RuntimeParameters,
    geothermal_controls: GeothermalControls,
    water_table_air_fraction_threshold: f64,
    active_layer_ice_fraction_threshold: f64,
    soil_geometry_parameters: SoilGeometryParameters,
    surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
    surface_pond_activation_heat_capacity_megajoules_per_m2_k: f64,
    soil_longwave_emissivity: f64,
    snow_longwave_emissivity: f64,
    canopy_longwave_emissivity: f64,
    snow_full_cover_depth_m: f64,
    surface_sensible_heat_conductance_megajoules_per_m2_h_k: f64,
    surface_latent_heat_conductance_megajoules_per_m2_h_kpa: f64,
    surface_vapor_activity_fraction: f64,
    minimum_surface_temperature_k: f64,
    maximum_surface_temperature_k: f64,
    snow_layer_bottom_depth_m: []f64,
    initial_snow_density_megagrams_per_m3: f64,
    snow_ice_density_megagrams_per_m3: f64,
    snow_latent_heat_of_fusion_megajoules_per_m3: f64,
    snow_solid_heat_capacity_megajoules_per_m3_k: f64,
    snow_phase_damping_divisor: f64,
    snow_compaction_parameters: snow_compaction.Parameters,
    snow_heat_conduction_parameters: snow_heat_conduction.Parameters,
    snow_vapor_parameters: snow_vapor_equilibrium.Parameters,
    snow_vapor_diffusion_parameters: snow_vapor_diffusion.Parameters,
    surface_gas_resistance_parameters: surface_gas_boundary_conductance.Parameters,
    surface_runoff_parameters: surface_runoff.Parameters,
    rainfall_impact_parameters: surface_precipitation.RainfallImpactParameters,
    surface_aerodynamic_parameters: surface_aerodynamics.Parameters,
    ground_air_parameters: ground_air_exchange.Parameters,
    canopy_surface_exchange_parameters: canopy_surface_exchange.Parameters,
    canopy_sensible_surface_resistance_h_per_m: f64,
    canopy_latent_surface_resistance_h_per_m: f64,
    canopy_minimum_resistance_h_per_m: f64,
    canopy_maximum_resistance_h_per_m: f64,
    canopy_ammonia_exchange_parameters: plant_soil_exchange.CanopyAmmoniaExchangeParameters,
};

noinline fn parseSoilSurfaceRecords(
    allocator: std.mem.Allocator,
    records: *RunscriptRecordCursor,
    hard_max_iterations: u16,
) !SoilSurfaceRecords {
    var soil_solver_tokens = delimited_input.recordTokens(try records.next("soil_solver record"));
    try requireRunscriptRecordTag(&soil_solver_tokens, "soil_solver", error.MissingSoilSolverRecord);
    const soil_solver_parameters = try parseSoilSolverParameters(&soil_solver_tokens, hard_max_iterations);
    try requireRunscriptRecordEnd(&soil_solver_tokens, "soil_solver");

    var soil_process_tokens = delimited_input.recordTokens(try records.next("soil_process record"));
    try requireRunscriptRecordTag(&soil_process_tokens, "soil_process", error.MissingSoilProcessRecord);
    var soil_process_parameters: soil_hourly_workspace.RuntimeParameters = .{
        .gravitational_water_potential_mpa_per_m = try nextRecordFloat(&soil_process_tokens),
        .reference_water_vapor_diffusivity_m2_per_h = try nextRecordFloat(&soil_process_tokens),
        .vapor_diffusivity_reference_temperature_k = try nextRecordFloat(&soil_process_tokens),
        .vapor_diffusivity_temperature_exponent = try nextRecordFloat(&soil_process_tokens),
        .vapor_pore_tortuosity = try nextRecordFloat(&soil_process_tokens),
        .osmotic_reflection_coefficient = try nextRecordFloat(&soil_process_tokens),
        .macropore_radius_m = try nextRecordFloat(&soil_process_tokens),
        .macropore_residual_saturation = 0,
        .macropore_van_genuchten_alpha_per_m = 15,
        .macropore_van_genuchten_n = 2.68,
        .macropore_pore_connectivity = 0.5,
        .dual_domain_geometry_factor = 3,
        .dual_domain_scaling_coefficient = 0.4,
        .frozen_hydraulic_impedance_exponent = 7,
        .surface_residue_residual_water_content_m3_per_m3 = 0,
        .surface_residue_van_genuchten_alpha_per_m = 400,
        .surface_residue_van_genuchten_n = 2.5,
        .reference_water_viscosity_megagrams_per_m_s = try nextRecordFloat(&soil_process_tokens),
        .water_viscosity_temperature_intercept = try nextRecordFloat(&soil_process_tokens),
        .water_viscosity_temperature_coefficient_per_c = try nextRecordFloat(&soil_process_tokens),
    };
    try requireRunscriptRecordEnd(&soil_process_tokens, "soil_process");

    var macropore_tokens = delimited_input.recordTokens(try records.next("macropore_van_genuchten record"));
    try requireRunscriptRecordTag(&macropore_tokens, "macropore_van_genuchten", error.MissingMacroporeVanGenuchtenRecord);
    soil_process_parameters.macropore_residual_saturation = try nextRecordFloat(&macropore_tokens);
    soil_process_parameters.macropore_van_genuchten_alpha_per_m = try nextRecordFloat(&macropore_tokens);
    soil_process_parameters.macropore_van_genuchten_n = try nextRecordFloat(&macropore_tokens);
    soil_process_parameters.macropore_pore_connectivity = try nextRecordFloat(&macropore_tokens);
    try requireRunscriptRecordEnd(&macropore_tokens, "macropore_van_genuchten");

    var dual_domain_tokens = delimited_input.recordTokens(try records.next("dual_domain_exchange record"));
    try requireRunscriptRecordTag(&dual_domain_tokens, "dual_domain_exchange", error.MissingDualDomainExchangeRecord);
    soil_process_parameters.dual_domain_geometry_factor = try nextRecordFloat(&dual_domain_tokens);
    soil_process_parameters.dual_domain_scaling_coefficient = try nextRecordFloat(&dual_domain_tokens);
    try requireRunscriptRecordEnd(&dual_domain_tokens, "dual_domain_exchange");

    var frozen_impedance_tokens = delimited_input.recordTokens(try records.next("frozen_hydraulic_impedance record"));
    try requireRunscriptRecordTag(&frozen_impedance_tokens, "frozen_hydraulic_impedance", error.MissingFrozenHydraulicImpedanceRecord);
    soil_process_parameters.frozen_hydraulic_impedance_exponent = try nextRecordFloat(&frozen_impedance_tokens);
    try requireRunscriptRecordEnd(&frozen_impedance_tokens, "frozen_hydraulic_impedance");
    try soil_hourly_workspace.validateRuntimeParameters(soil_process_parameters);

    var residue_freeze_tokens = delimited_input.recordTokens(try records.next("surface_residue_freeze_thaw record"));
    try requireRunscriptRecordTag(&residue_freeze_tokens, "surface_residue_freeze_thaw", error.MissingSurfaceResidueFreezeThawRecord);
    soil_process_parameters.surface_residue_residual_water_content_m3_per_m3 = try nextRecordFloat(&residue_freeze_tokens);
    soil_process_parameters.surface_residue_van_genuchten_alpha_per_m = try nextRecordFloat(&residue_freeze_tokens);
    soil_process_parameters.surface_residue_van_genuchten_n = try nextRecordFloat(&residue_freeze_tokens);
    try requireRunscriptRecordEnd(&residue_freeze_tokens, "surface_residue_freeze_thaw");
    try soil_hourly_workspace.validateRuntimeParameters(soil_process_parameters);

    var soil_gas_tokens = delimited_input.recordTokens(try records.next("soil_gas_transport record"));
    try requireRunscriptRecordTag(&soil_gas_tokens, "soil_gas_transport", error.MissingSoilGasTransportRecord);
    var soil_gas_transport_parameters: soil_gas_transport_step.RuntimeParameters = .{};
    soil_gas_transport_parameters.reference_temperature_k = try nextRecordFloat(&soil_gas_tokens);
    soil_gas_transport_parameters.temperature_exponent = try nextRecordFloat(&soil_gas_tokens);
    for (&soil_gas_transport_parameters.free_air_diffusivity_m2_per_h) |*value| value.* = try nextRecordFloat(&soil_gas_tokens);
    soil_gas_transport_parameters.penman_tortuosity = try nextRecordFloat(&soil_gas_tokens);
    // PR-AIRFRAC-RECONCILE-001: this field is read to keep the shipped record
    // layout intact, then superseded below by `subsurface_state` field 1. Legacy
    // carries ONE constant here (hour1.f:119 THETPW and starts.f:97 THETX are both
    // 1.0E-03); the translation split it in two, and the shipped decks disagree by
    // nine orders of magnitude. The saturation threshold owns it, so a layer cannot
    // be below the internal water table and gas-conductive at the same time.
    const deprecated_soil_gas_air_fraction_floor = try nextRecordFloat(&soil_gas_tokens);
    _ = deprecated_soil_gas_air_fraction_floor;
    soil_gas_transport_parameters.water_density_g_per_m3 = try nextRecordFloat(&soil_gas_tokens);
    soil_gas_transport_parameters.water_molar_mass_g_per_mol = try nextRecordFloat(&soil_gas_tokens);
    try requireRunscriptRecordEnd(&soil_gas_tokens, "soil_gas_transport");

    var soil_phase_tokens = delimited_input.recordTokens(try records.next("soil_phase_heat record"));
    try requireRunscriptRecordTag(&soil_phase_tokens, "soil_phase_heat", error.MissingSoilPhaseHeatRecord);
    const soil_phase_heat_parameters = try parseSoilPhaseHeatParameters(&soil_phase_tokens);
    try requireRunscriptRecordEnd(&soil_phase_tokens, "soil_phase_heat");

    var geothermal_tokens = delimited_input.recordTokens(try records.next("geothermal record"));
    try requireRunscriptRecordTag(&geothermal_tokens, "geothermal", error.MissingGeothermalRecord);
    const geothermal_controls: GeothermalControls = .{
        .enabled = try nextRecordBool(&geothermal_tokens),
        .minimum_source_depth_m = try nextRecordFloat(&geothermal_tokens),
        .source_depth_below_profile_m = try nextRecordFloat(&geothermal_tokens),
        .conductivity_m_megajoules_per_h_k = try nextRecordFloat(&geothermal_tokens),
        .geothermal_flux_megajoules_per_m2_h = try nextRecordFloat(&geothermal_tokens),
    };
    try requireRunscriptRecordEnd(&geothermal_tokens, "geothermal");
    if (!std.math.isFinite(geothermal_controls.minimum_source_depth_m) or geothermal_controls.minimum_source_depth_m <= 0 or !std.math.isFinite(geothermal_controls.source_depth_below_profile_m) or geothermal_controls.source_depth_below_profile_m <= 0 or !std.math.isFinite(geothermal_controls.conductivity_m_megajoules_per_h_k) or geothermal_controls.conductivity_m_megajoules_per_h_k <= 0 or !std.math.isFinite(geothermal_controls.geothermal_flux_megajoules_per_m2_h)) return error.InvalidGeothermalControls;

    var subsurface_tokens = delimited_input.recordTokens(try records.next("subsurface_state record"));
    try requireRunscriptRecordTag(&subsurface_tokens, "subsurface_state", error.MissingSubsurfaceStateRecord);
    const water_table_air_fraction_threshold = try nextRecordFloat(&subsurface_tokens);
    const active_layer_ice_fraction_threshold = try nextRecordFloat(&subsurface_tokens);
    try requireRunscriptRecordEnd(&subsurface_tokens, "subsurface_state");
    // Single owner for the air-filled-porosity threshold: the water side names the
    // saturation state and the gas side must agree with it (AIRFRAC-F1).
    soil_gas_transport_parameters.minimum_air_filled_porosity_m3_per_m3 = water_table_air_fraction_threshold;
    if (!std.math.isFinite(water_table_air_fraction_threshold) or water_table_air_fraction_threshold < 0 or water_table_air_fraction_threshold > 1 or !std.math.isFinite(active_layer_ice_fraction_threshold) or active_layer_ice_fraction_threshold < 0 or active_layer_ice_fraction_threshold > 1) return error.InvalidSubsurfaceStateControls;

    var soil_geometry_tokens = delimited_input.recordTokens(try records.next("soil_geometry record"));
    try requireRunscriptRecordTag(&soil_geometry_tokens, "soil_geometry", error.MissingSoilGeometryRecord);
    const soil_geometry_parameters: SoilGeometryParameters = .{
        .organic_carbon_specific_volume_m3_per_g = try nextRecordFloat(&soil_geometry_tokens),
        .organic_horizon_threshold_g_c_per_megagram = try nextRecordFloat(&soil_geometry_tokens),
        .ice_to_water_specific_volume_difference = try nextRecordFloat(&soil_geometry_tokens),
        .minimum_layer_thickness_m = try nextRecordFloat(&soil_geometry_tokens),
    };
    try requireRunscriptRecordEnd(&soil_geometry_tokens, "soil_geometry");
    inline for (@typeInfo(SoilGeometryParameters).@"struct".fields) |field| {
        const value = @field(soil_geometry_parameters, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidSoilGeometryParameters;
    }
    if (soil_geometry_parameters.ice_to_water_specific_volume_difference >= 1) return error.InvalidSoilGeometryParameters;
    var pond_energy_tokens = delimited_input.recordTokens(try records.next("surface_pond_energy record"));
    try requireRunscriptRecordTag(&pond_energy_tokens, "surface_pond_energy", error.MissingSurfacePondEnergyRecord);
    const surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k = try nextRecordFloat(&pond_energy_tokens);
    const surface_pond_activation_heat_capacity_megajoules_per_m2_k = try nextRecordFloat(&pond_energy_tokens);
    try requireRunscriptRecordEnd(&pond_energy_tokens, "surface_pond_energy");
    if (!std.math.isFinite(surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k) or surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k <= 0 or !std.math.isFinite(surface_pond_activation_heat_capacity_megajoules_per_m2_k) or surface_pond_activation_heat_capacity_megajoules_per_m2_k <= 0) return error.InvalidSurfacePondEnergyControls;

    var surface_energy_tokens = delimited_input.recordTokens(try records.next("surface_energy record"));
    try requireRunscriptRecordTag(&surface_energy_tokens, "surface_energy", error.MissingSurfaceEnergyRecord);
    const soil_longwave_emissivity = try nextRecordFloat(&surface_energy_tokens);
    const snow_longwave_emissivity = try nextRecordFloat(&surface_energy_tokens);
    const canopy_longwave_emissivity = try nextRecordFloat(&surface_energy_tokens);
    const snow_full_cover_depth_m = try nextRecordFloat(&surface_energy_tokens);
    const surface_sensible_heat_conductance_megajoules_per_m2_h_k = try nextRecordFloat(&surface_energy_tokens);
    const surface_latent_heat_conductance_megajoules_per_m2_h_kpa = try nextRecordFloat(&surface_energy_tokens);
    const surface_vapor_activity_fraction = try nextRecordFloat(&surface_energy_tokens);
    const minimum_surface_temperature_k = try nextRecordFloat(&surface_energy_tokens);
    const maximum_surface_temperature_k = try nextRecordFloat(&surface_energy_tokens);
    try requireRunscriptRecordEnd(&surface_energy_tokens, "surface_energy");
    if (!std.math.isFinite(soil_longwave_emissivity) or soil_longwave_emissivity < 0 or soil_longwave_emissivity > 1 or
        !std.math.isFinite(snow_longwave_emissivity) or snow_longwave_emissivity < 0 or snow_longwave_emissivity > 1 or
        !std.math.isFinite(canopy_longwave_emissivity) or canopy_longwave_emissivity < 0 or canopy_longwave_emissivity > 1 or
        !std.math.isFinite(snow_full_cover_depth_m) or snow_full_cover_depth_m <= 0 or
        !std.math.isFinite(surface_sensible_heat_conductance_megajoules_per_m2_h_k) or surface_sensible_heat_conductance_megajoules_per_m2_h_k <= 0 or
        !std.math.isFinite(surface_latent_heat_conductance_megajoules_per_m2_h_kpa) or surface_latent_heat_conductance_megajoules_per_m2_h_kpa < 0 or
        !std.math.isFinite(surface_vapor_activity_fraction) or surface_vapor_activity_fraction < 0 or surface_vapor_activity_fraction > 1 or
        !std.math.isFinite(minimum_surface_temperature_k) or !std.math.isFinite(maximum_surface_temperature_k) or minimum_surface_temperature_k <= 0 or minimum_surface_temperature_k >= maximum_surface_temperature_k) return error.InvalidSurfaceEnergyControls;
    var snow_layer_tokens = delimited_input.recordTokens(try records.next("snow_layers record"));
    try requireRunscriptRecordTag(&snow_layer_tokens, "snow_layers", error.MissingSnowLayersRecord);
    const snow_layer_count = try nextRecordUnsigned(&snow_layer_tokens);
    if (snow_layer_count == 0) return error.NoSnowLayers;
    const snow_layer_bottom_depth_m = try allocator.alloc(f64, snow_layer_count);
    errdefer allocator.free(snow_layer_bottom_depth_m);
    for (snow_layer_bottom_depth_m) |*bottom| bottom.* = try nextRecordFloat(&snow_layer_tokens);
    const initial_snow_density_megagrams_per_m3 = try nextRecordFloat(&snow_layer_tokens);
    const snow_ice_density_megagrams_per_m3 = try nextRecordFloat(&snow_layer_tokens);
    const snow_latent_heat_of_fusion_megajoules_per_m3 = try nextRecordFloat(&snow_layer_tokens);
    const snow_solid_heat_capacity_megajoules_per_m3_k: f64 = 2.095;
    const snow_phase_damping_divisor = try nextRecordFloat(&snow_layer_tokens);
    try requireRunscriptRecordEnd(&snow_layer_tokens, "snow_layers");
    var previous_snow_bottom: f64 = 0;
    for (snow_layer_bottom_depth_m) |bottom| {
        if (!std.math.isFinite(bottom) or bottom <= previous_snow_bottom) return error.InvalidSnowLayerBoundaries;
        previous_snow_bottom = bottom;
    }
    if (!std.math.isFinite(initial_snow_density_megagrams_per_m3) or initial_snow_density_megagrams_per_m3 <= 0 or !std.math.isFinite(snow_ice_density_megagrams_per_m3) or snow_ice_density_megagrams_per_m3 <= 0 or !std.math.isFinite(snow_latent_heat_of_fusion_megajoules_per_m3) or snow_latent_heat_of_fusion_megajoules_per_m3 <= 0 or !std.math.isFinite(snow_phase_damping_divisor) or snow_phase_damping_divisor <= 0) return error.InvalidSnowPhaseParameters;
    var snow_compaction_tokens = delimited_input.recordTokens(try records.next("snow_compaction record"));
    try requireRunscriptRecordTag(&snow_compaction_tokens, "snow_compaction", error.MissingSnowCompactionRecord);
    const snow_compaction_parameters: snow_compaction.Parameters = .{
        .maximum_temperature_metamorphism_density_megagrams_per_m3 = try nextRecordFloat(&snow_compaction_tokens),
        .temperature_metamorphism_rate_per_h = try nextRecordFloat(&snow_compaction_tokens),
        .temperature_metamorphism_exponent_per_c = try nextRecordFloat(&snow_compaction_tokens),
        .viscosity_scale_megagrams_h_per_m3 = try nextRecordFloat(&snow_compaction_tokens),
        .viscosity_temperature_exponent_per_c = try nextRecordFloat(&snow_compaction_tokens),
        .viscosity_density_exponent_m3_per_megagram = try nextRecordFloat(&snow_compaction_tokens),
        .minimum_snowfall_temperature_c = try nextRecordFloat(&snow_compaction_tokens),
        .maximum_snowfall_temperature_c = try nextRecordFloat(&snow_compaction_tokens),
        .snowfall_density_temperature_coefficient_megagrams_per_m3_c_pow_1_5 = try nextRecordFloat(&snow_compaction_tokens),
    };
    try requireRunscriptRecordEnd(&snow_compaction_tokens, "snow_compaction");
    var snow_thermal_tokens = delimited_input.recordTokens(try records.next("snow_thermal record"));
    try requireRunscriptRecordTag(&snow_thermal_tokens, "snow_thermal", error.MissingSnowThermalRecord);
    const snow_heat_conduction_parameters: snow_heat_conduction.Parameters = .{
        .conductivity_scale_m_megajoules_per_h_k = try nextRecordFloat(&snow_thermal_tokens),
        .conductivity_density_exponent_m3_per_megagram = try nextRecordFloat(&snow_thermal_tokens),
        .conductivity_log10_intercept = try nextRecordFloat(&snow_thermal_tokens),
        .maximum_effective_density_megagrams_per_m3 = try nextRecordFloat(&snow_thermal_tokens),
        .ice_density_megagrams_per_m3 = snow_ice_density_megagrams_per_m3,
    };
    try requireRunscriptRecordEnd(&snow_thermal_tokens, "snow_thermal");
    var snow_vapor_tokens = delimited_input.recordTokens(try records.next("snow_vapor record"));
    try requireRunscriptRecordTag(&snow_vapor_tokens, "snow_vapor", error.MissingSnowVaporRecord);
    const snow_vapor_parameters: snow_vapor_equilibrium.Parameters = .{
        .vapor_volume_prefactor_k = try nextRecordFloat(&snow_vapor_tokens),
        .equilibrium_relative_humidity = try nextRecordFloat(&snow_vapor_tokens),
        .clausius_clapeyron_temperature_k = try nextRecordFloat(&snow_vapor_tokens),
        .reference_inverse_temperature_per_k = try nextRecordFloat(&snow_vapor_tokens),
        .liquid_evaporation_latent_heat_megajoules_per_m3 = try nextRecordFloat(&snow_vapor_tokens),
        .snow_sublimation_latent_heat_megajoules_per_m3 = try nextRecordFloat(&snow_vapor_tokens),
        .latent_heat_of_fusion_megajoules_per_m3 = snow_latent_heat_of_fusion_megajoules_per_m3,
        .solid_snow_heat_capacity_megajoules_per_m3_k = snow_solid_heat_capacity_megajoules_per_m3_k,
        .liquid_water_heat_capacity_megajoules_per_m3_k = soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        .ice_heat_capacity_megajoules_per_m3_k = soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
        .ice_density_megagrams_per_m3 = snow_ice_density_megagrams_per_m3,
        .pure_water_melting_temperature_k = soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
    };
    try requireRunscriptRecordEnd(&snow_vapor_tokens, "snow_vapor");
    var snow_vapor_transport_tokens = delimited_input.recordTokens(try records.next("snow_vapor_transport record"));
    try requireRunscriptRecordTag(&snow_vapor_transport_tokens, "snow_vapor_transport", error.MissingSnowVaporTransportRecord);
    const snow_vapor_diffusion_parameters: snow_vapor_diffusion.Parameters = .{
        .reference_vapor_diffusivity_m2_per_h = try nextRecordFloat(&snow_vapor_transport_tokens),
        .reference_temperature_k = try nextRecordFloat(&snow_vapor_transport_tokens),
        .temperature_exponent = try nextRecordFloat(&snow_vapor_transport_tokens),
        .minimum_air_fraction = try nextRecordFloat(&snow_vapor_transport_tokens),
        .vapor_sensible_heat_capacity_megajoules_per_m3_k = try nextRecordFloat(&snow_vapor_transport_tokens),
    };
    try requireRunscriptRecordEnd(&snow_vapor_transport_tokens, "snow_vapor_transport");
    var surface_gas_tokens = delimited_input.recordTokens(try records.next("surface_gas_resistance record"));
    try requireRunscriptRecordTag(&surface_gas_tokens, "surface_gas_resistance", error.MissingSurfaceGasResistanceRecord);
    const surface_gas_resistance_parameters: surface_gas_boundary_conductance.Parameters = .{
        .minimum_richardson_number = try nextRecordFloat(&surface_gas_tokens),
        .maximum_richardson_number = try nextRecordFloat(&surface_gas_tokens),
        .richardson_resistance_multiplier = try nextRecordFloat(&surface_gas_tokens),
        .minimum_aerodynamic_resistance_h_per_m = try nextRecordFloat(&surface_gas_tokens),
        .maximum_aerodynamic_resistance_h_per_m = try nextRecordFloat(&surface_gas_tokens),
        .canopy_drag_length_m = try nextRecordFloat(&surface_gas_tokens),
        .minimum_air_fraction = try nextRecordFloat(&surface_gas_tokens),
    };
    try requireRunscriptRecordEnd(&surface_gas_tokens, "surface_gas_resistance");
    var surface_runoff_tokens = delimited_input.recordTokens(try records.next("surface_runoff record"));
    try requireRunscriptRecordTag(&surface_runoff_tokens, "surface_runoff", error.MissingSurfaceRunoffRecord);
    const surface_runoff_parameters: surface_runoff.Parameters = .{
        .ground_surface_retention_m3_per_m2 = try nextRecordFloat(&surface_runoff_tokens),
        .runoff_roughness_h_per_m_one_third = try nextRecordFloat(&surface_runoff_tokens),
        .maximum_hydraulic_depth_m = try nextRecordFloat(&surface_runoff_tokens),
        .manning_time_conversion_s_per_h = try nextRecordFloat(&surface_runoff_tokens),
        .negligible_water_m3 = try nextRecordFloat(&surface_runoff_tokens),
    };
    try requireRunscriptRecordEnd(&surface_runoff_tokens, "surface_runoff");
    var rainfall_tokens = delimited_input.recordTokens(try records.next("rainfall_impact record"));
    try requireRunscriptRecordTag(&rainfall_tokens, "rainfall_impact", error.MissingRainfallImpactRecord);
    const rainfall_impact_parameters: surface_precipitation.RainfallImpactParameters = .{
        .direct_energy_intercept_j_per_mm = try nextRecordFloat(&rainfall_tokens),
        .direct_energy_log_coefficient_j_per_mm = try nextRecordFloat(&rainfall_tokens),
        .throughfall_energy_height_coefficient_j_per_mm_sqrt_m = try nextRecordFloat(&rainfall_tokens),
        .throughfall_energy_intercept_j_per_mm = try nextRecordFloat(&rainfall_tokens),
        .maximum_canopy_height_m = try nextRecordFloat(&rainfall_tokens),
        .ponding_attenuation_per_mm = try nextRecordFloat(&rainfall_tokens),
        .conductivity_damage_per_j_per_megagram_per_megagram = try nextRecordFloat(&rainfall_tokens),
        .conductivity_recovery_fraction_per_h = try nextRecordFloat(&rainfall_tokens),
    };
    try requireRunscriptRecordEnd(&rainfall_tokens, "rainfall_impact");
    var aerodynamic_tokens = delimited_input.recordTokens(try records.next("surface_aerodynamics record"));
    try requireRunscriptRecordTag(&aerodynamic_tokens, "surface_aerodynamics", error.MissingSurfaceAerodynamicsRecord);
    const surface_aerodynamic_parameters: surface_aerodynamics.Parameters = .{
        .canopy_area_attenuation = try nextRecordFloat(&aerodynamic_tokens),
        .minimum_reference_height_above_displacement_m = try nextRecordFloat(&aerodynamic_tokens),
        .snow_roughness_height_m = try nextRecordFloat(&aerodynamic_tokens),
        .soil_roughness_height_m = try nextRecordFloat(&aerodynamic_tokens),
        .richardson_coefficient_k_m = try nextRecordFloat(&aerodynamic_tokens),
        .neutral_resistance_denominator = try nextRecordFloat(&aerodynamic_tokens),
        .minimum_wind_speed_m_per_h = try nextRecordFloat(&aerodynamic_tokens),
        .minimum_aerodynamic_resistance_h_per_m = try nextRecordFloat(&aerodynamic_tokens),
        .weather_height_includes_displacement = try nextRecordBool(&aerodynamic_tokens),
    };
    try requireRunscriptRecordEnd(&aerodynamic_tokens, "surface_aerodynamics");
    var ground_air_tokens = delimited_input.recordTokens(try records.next("ground_air record"));
    try requireRunscriptRecordTag(&ground_air_tokens, "ground_air", error.MissingGroundAirRecord);
    const ground_air_parameters: ground_air_exchange.Parameters = .{
        .minimum_richardson_number = surface_gas_resistance_parameters.minimum_richardson_number,
        .maximum_richardson_number = surface_gas_resistance_parameters.maximum_richardson_number,
        .richardson_resistance_multiplier = surface_gas_resistance_parameters.richardson_resistance_multiplier,
        .minimum_aerodynamic_resistance_h_per_m = surface_gas_resistance_parameters.minimum_aerodynamic_resistance_h_per_m,
        .maximum_aerodynamic_resistance_h_per_m = surface_gas_resistance_parameters.maximum_aerodynamic_resistance_h_per_m,
        .volumetric_air_heat_capacity_megajoules_per_m3_k = try nextRecordFloat(&ground_air_tokens),
        .minimum_air_column_height_m = try nextRecordFloat(&ground_air_tokens),
        .sensible_heat_conductivity_megajoules_per_m_h_k = try nextRecordFloat(&ground_air_tokens),
        .liquid_water_latent_heat_megajoules_per_m3 = try nextRecordFloat(&ground_air_tokens),
        .saturation_vapor_prefactor_k = try nextRecordFloat(&ground_air_tokens),
        .saturation_relative_humidity = try nextRecordFloat(&ground_air_tokens),
        .saturation_temperature_k = try nextRecordFloat(&ground_air_tokens),
        .saturation_reference_inverse_temperature_per_k = try nextRecordFloat(&ground_air_tokens),
        // GROUND-AIR-VAPOR-CONDENSATION-001: reuse the already-parsed,
        // already-validated snow-side sublimation latent heat and freezing
        // point rather than adding new runscript record fields -- both are
        // the same universal physical constants the snow-vapor solver
        // already uses for ice/water phase change, not snow-specific.
        .sublimation_latent_heat_megajoules_per_m3 = snow_vapor_parameters.snow_sublimation_latent_heat_megajoules_per_m3,
        .pure_water_freezing_temperature_k = soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
    };
    try requireRunscriptRecordEnd(&ground_air_tokens, "ground_air");
    var canopy_surface_tokens = delimited_input.recordTokens(try records.next("canopy_surface_exchange record"));
    try requireRunscriptRecordTag(&canopy_surface_tokens, "canopy_surface_exchange", error.MissingCanopySurfaceExchangeRecord);
    const canopy_sensible_surface_resistance_h_per_m = try nextRecordFloat(&canopy_surface_tokens);
    const canopy_latent_surface_resistance_h_per_m = try nextRecordFloat(&canopy_surface_tokens);
    const canopy_minimum_boundary_resistance_h_per_m = try nextRecordFloat(&canopy_surface_tokens);
    const canopy_maximum_boundary_resistance_h_per_m = try nextRecordFloat(&canopy_surface_tokens);
    const canopy_surface_exchange_parameters: canopy_surface_exchange.Parameters = .{
        .minimum_richardson_number = ground_air_parameters.minimum_richardson_number,
        .maximum_richardson_number = ground_air_parameters.maximum_richardson_number,
        .richardson_resistance_multiplier = ground_air_parameters.richardson_resistance_multiplier,
        .minimum_boundary_resistance_h_per_m = canopy_minimum_boundary_resistance_h_per_m,
        .maximum_boundary_resistance_h_per_m = canopy_maximum_boundary_resistance_h_per_m,
        .saturation_vapor_prefactor_k = ground_air_parameters.saturation_vapor_prefactor_k,
        .saturation_relative_humidity = ground_air_parameters.saturation_relative_humidity,
        .saturation_temperature_k = ground_air_parameters.saturation_temperature_k,
        .saturation_reference_inverse_temperature_per_k = ground_air_parameters.saturation_reference_inverse_temperature_per_k,
        .water_potential_vapor_coefficient_mol_per_m3 = try nextRecordFloat(&canopy_surface_tokens),
        .universal_gas_constant_j_per_mol_k = try nextRecordFloat(&canopy_surface_tokens),
        .latent_heat_of_vaporization_megajoules_per_m3 = ground_air_parameters.liquid_water_latent_heat_megajoules_per_m3,
        .liquid_water_heat_capacity_megajoules_per_m3_k = try nextRecordFloat(&canopy_surface_tokens),
    };
    // RACGM/RACGZ (watsub.f:115-120): the canopy-height-profile aerodynamic
    // resistance clamp bounding RACG/RAGC/RAGD (watsub.f:831, :4265, :4273).
    // Distinct from the RABM/RABZ pair above (starts.f:83), which bounds the
    // isothermal boundary-layer resistances RAB/RABC/RAHC/RAHD.
    const canopy_minimum_resistance_h_per_m = try nextRecordFloat(&canopy_surface_tokens);
    const canopy_maximum_resistance_h_per_m = try nextRecordFloat(&canopy_surface_tokens);
    try requireRunscriptRecordEnd(&canopy_surface_tokens, "canopy_surface_exchange");
    if (!std.math.isFinite(canopy_sensible_surface_resistance_h_per_m) or canopy_sensible_surface_resistance_h_per_m < 0 or !std.math.isFinite(canopy_latent_surface_resistance_h_per_m) or canopy_latent_surface_resistance_h_per_m < 0) return error.InvalidCanopySurfaceResistance;
    if (!std.math.isFinite(canopy_minimum_resistance_h_per_m) or canopy_minimum_resistance_h_per_m <= 0 or !std.math.isFinite(canopy_maximum_resistance_h_per_m) or canopy_maximum_resistance_h_per_m < canopy_minimum_resistance_h_per_m) return error.InvalidCanopyResistanceBounds;
    var canopy_ammonia_tokens = delimited_input.recordTokens(try records.next("canopy_ammonia_exchange record"));
    try requireRunscriptRecordTag(&canopy_ammonia_tokens, "canopy_ammonia_exchange", error.MissingCanopyAmmoniaExchangeRecord);
    const canopy_ammonia_exchange_parameters: plant_soil_exchange.CanopyAmmoniaExchangeParameters = .{
        .minimum_canopy_dry_matter_fraction = try nextRecordFloat(&canopy_ammonia_tokens),
        .water_potential_dry_matter_increment = try nextRecordFloat(&canopy_ammonia_tokens),
        .water_potential_denominator_per_megapascal = try nextRecordFloat(&canopy_ammonia_tokens),
        .water_potential_denominator_offset = try nextRecordFloat(&canopy_ammonia_tokens),
        .canopy_air_volume_ratio_m3_per_g_c = try nextRecordFloat(&canopy_ammonia_tokens),
        .maximum_mobile_nitrogen_transfer_fraction_per_step = try nextRecordFloat(&canopy_ammonia_tokens),
        .solubility_log_intercept = try nextRecordFloat(&canopy_ammonia_tokens),
        .solubility_temperature_coefficient_per_c = try nextRecordFloat(&canopy_ammonia_tokens),
    };
    try requireRunscriptRecordEnd(&canopy_ammonia_tokens, "canopy_ammonia_exchange");
    try canopy_ammonia_exchange_parameters.validate();
    return .{
        .soil_solver_parameters = soil_solver_parameters,
        .soil_process_parameters = soil_process_parameters,
        .soil_gas_transport_parameters = soil_gas_transport_parameters,
        .soil_phase_heat_parameters = soil_phase_heat_parameters,
        .geothermal_controls = geothermal_controls,
        .water_table_air_fraction_threshold = water_table_air_fraction_threshold,
        .active_layer_ice_fraction_threshold = active_layer_ice_fraction_threshold,
        .soil_geometry_parameters = soil_geometry_parameters,
        .surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k = surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
        .surface_pond_activation_heat_capacity_megajoules_per_m2_k = surface_pond_activation_heat_capacity_megajoules_per_m2_k,
        .soil_longwave_emissivity = soil_longwave_emissivity,
        .snow_longwave_emissivity = snow_longwave_emissivity,
        .canopy_longwave_emissivity = canopy_longwave_emissivity,
        .snow_full_cover_depth_m = snow_full_cover_depth_m,
        .surface_sensible_heat_conductance_megajoules_per_m2_h_k = surface_sensible_heat_conductance_megajoules_per_m2_h_k,
        .surface_latent_heat_conductance_megajoules_per_m2_h_kpa = surface_latent_heat_conductance_megajoules_per_m2_h_kpa,
        .surface_vapor_activity_fraction = surface_vapor_activity_fraction,
        .minimum_surface_temperature_k = minimum_surface_temperature_k,
        .maximum_surface_temperature_k = maximum_surface_temperature_k,
        .snow_layer_bottom_depth_m = snow_layer_bottom_depth_m,
        .initial_snow_density_megagrams_per_m3 = initial_snow_density_megagrams_per_m3,
        .snow_ice_density_megagrams_per_m3 = snow_ice_density_megagrams_per_m3,
        .snow_latent_heat_of_fusion_megajoules_per_m3 = snow_latent_heat_of_fusion_megajoules_per_m3,
        .snow_solid_heat_capacity_megajoules_per_m3_k = snow_solid_heat_capacity_megajoules_per_m3_k,
        .snow_phase_damping_divisor = snow_phase_damping_divisor,
        .snow_compaction_parameters = snow_compaction_parameters,
        .snow_heat_conduction_parameters = snow_heat_conduction_parameters,
        .snow_vapor_parameters = snow_vapor_parameters,
        .snow_vapor_diffusion_parameters = snow_vapor_diffusion_parameters,
        .surface_gas_resistance_parameters = surface_gas_resistance_parameters,
        .surface_runoff_parameters = surface_runoff_parameters,
        .rainfall_impact_parameters = rainfall_impact_parameters,
        .surface_aerodynamic_parameters = surface_aerodynamic_parameters,
        .ground_air_parameters = ground_air_parameters,
        .canopy_surface_exchange_parameters = canopy_surface_exchange_parameters,
        .canopy_sensible_surface_resistance_h_per_m = canopy_sensible_surface_resistance_h_per_m,
        .canopy_latent_surface_resistance_h_per_m = canopy_latent_surface_resistance_h_per_m,
        .canopy_minimum_resistance_h_per_m = canopy_minimum_resistance_h_per_m,
        .canopy_maximum_resistance_h_per_m = canopy_maximum_resistance_h_per_m,
        .canopy_ammonia_exchange_parameters = canopy_ammonia_exchange_parameters,
    };
}

const PlantInitializationRecords = struct {
    root_axes_per_plant: usize,
    canopy_layer_count: usize,
    canopy_discretization: @import("../canopy/morphology/geometry.zig").Discretization,
    stalk_volume_m3_per_g_c: f64,
    standing_dead_partition_parameters: plant_initialization.StandingDeadPartitionParameters,
    plant_heat_water_parameters: plant_initialization.PlantHeatWaterParameters,
    plant_geometry_parameters: plant_initialization.PlantGeometryParameters,
    phenology_initialization_parameters: plant_initialization.PhenologyInitializationParameters,
    root_initialization_parameters: plant_root_system.InitializationParameters,
    root_morphology_parameters: plant_root_system.MorphologyParameters,
    standing_dead_sapwood_thickness_m: f64,
    standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k: f64,
    standing_dead_emissivity: f64,
    standing_dead_activation_heat_capacity_megajoules_per_m2_k: f64,
    standing_dead_effective_heat_capacity_floor_megajoules_per_m2_k: f64,
    woody_optics_parameters: canopy_optics.WoodyOpticsParameters,
    canopy_retention_parameters: canopy_precipitation_retention.Parameters,
    shoot_control_parameters: plant_initialization.ShootControlParameters,
    c4_carbon_parameters: canopy_photosynthesis.C4CarbonParameters,
    thermal_acclimation_parameters: plant_initialization.ThermalAcclimationParameters,
    canopy_stress_parameters: canopy_biochemistry.StressParameters,
    phenology_parameters: plant_phenology.Parameters,
    plant_pool_parameters: plant_pool_aggregation.RuntimeParameters,
    dynamic_plant_salts: bool,
    seed_set_parameters: canopy_photosynthesis.SeedSetParameters,
};

noinline fn parsePlantInitializationRecords(records: *RunscriptRecordCursor) !PlantInitializationRecords {
    var plant_structure_tokens = delimited_input.recordTokens(try records.next("plant_structure record"));
    try requireRunscriptRecordTag(&plant_structure_tokens, "plant_structure", error.MissingPlantStructureRecord);
    const root_axes_per_plant = try nextRecordUnsigned(&plant_structure_tokens);
    try requireRunscriptRecordEnd(&plant_structure_tokens, "plant_structure");
    if (root_axes_per_plant == 0) return error.NoRootAxes;
    var canopy_layers_tokens = delimited_input.recordTokens(try records.next("canopy_layers record"));
    try requireRunscriptRecordTag(&canopy_layers_tokens, "canopy_layers", error.MissingCanopyLayersRecord);
    const canopy_layer_count = try nextRecordUnsigned(&canopy_layers_tokens);
    try requireRunscriptRecordEnd(&canopy_layers_tokens, "canopy_layers");
    if (canopy_layer_count == 0) return error.NoCanopyLayers;
    var canopy_geometry_tokens = delimited_input.recordTokens(try records.next("canopy_geometry record"));
    try requireRunscriptRecordTag(&canopy_geometry_tokens, "canopy_geometry", error.MissingCanopyGeometryRecord);
    const stalk_volume_m3_per_g_c = try nextRecordFloat(&canopy_geometry_tokens);
    try requireRunscriptRecordEnd(&canopy_geometry_tokens, "canopy_geometry");
    if (!std.math.isFinite(stalk_volume_m3_per_g_c) or stalk_volume_m3_per_g_c <= 0) return error.InvalidCanopyGeometryControls;
    var canopy_discretization_tokens = delimited_input.recordTokens(try records.next("canopy_discretization record"));
    try requireRunscriptRecordTag(&canopy_discretization_tokens, "canopy_discretization", error.MissingCanopyDiscretizationRecord);
    const canopy_discretization: @import("../canopy/morphology/geometry.zig").Discretization = .{
        .leaf_inclination_class_count = try nextRecordUnsigned(&canopy_discretization_tokens),
        .leaf_azimuth_class_count = try nextRecordUnsigned(&canopy_discretization_tokens),
        .diffuse_sky_sector_count = try nextRecordUnsigned(&canopy_discretization_tokens),
    };
    try requireRunscriptRecordEnd(&canopy_discretization_tokens, "canopy_discretization");
    try @import("../canopy/morphology/geometry.zig").validateDiscretization(canopy_discretization);
    var standing_partition_tokens = delimited_input.recordTokens(try records.next("standing_dead_partition record"));
    try requireRunscriptRecordTag(&standing_partition_tokens, "standing_dead_partition", error.MissingStandingDeadPartitionRecord);
    const standing_dead_partition_parameters: plant_initialization.StandingDeadPartitionParameters = .{
        .carbon_fraction = .{ try nextRecordFloat(&standing_partition_tokens), try nextRecordFloat(&standing_partition_tokens), try nextRecordFloat(&standing_partition_tokens), try nextRecordFloat(&standing_partition_tokens) },
        .nitrogen_weight = .{ try nextRecordFloat(&standing_partition_tokens), try nextRecordFloat(&standing_partition_tokens), try nextRecordFloat(&standing_partition_tokens), try nextRecordFloat(&standing_partition_tokens) },
        .phosphorus_weight = .{ try nextRecordFloat(&standing_partition_tokens), try nextRecordFloat(&standing_partition_tokens), try nextRecordFloat(&standing_partition_tokens), try nextRecordFloat(&standing_partition_tokens) },
    };
    try requireRunscriptRecordEnd(&standing_partition_tokens, "standing_dead_partition");
    try standing_dead_partition_parameters.validate();
    var plant_heat_tokens = delimited_input.recordTokens(try records.next("plant_initial_heat_water record"));
    try requireRunscriptRecordTag(&plant_heat_tokens, "plant_initial_heat_water", error.MissingPlantInitialHeatWaterRecord);
    const plant_heat_water_parameters: plant_initialization.PlantHeatWaterParameters = .{
        .kelvin_offset_k = try nextRecordFloat(&plant_heat_tokens),
        .vapor_pressure_numerator_kpa_k = try nextRecordFloat(&plant_heat_tokens),
        .initial_relative_humidity = try nextRecordFloat(&plant_heat_tokens),
        .vapor_pressure_exponent_temperature_k = try nextRecordFloat(&plant_heat_tokens),
        .vapor_pressure_reference_inverse_temperature_per_k = try nextRecordFloat(&plant_heat_tokens),
        .initial_total_water_potential_megapascal = try nextRecordFloat(&plant_heat_tokens),
    };
    try requireRunscriptRecordEnd(&plant_heat_tokens, "plant_initial_heat_water");
    try plant_heat_water_parameters.validate();
    var plant_geometry_tokens = delimited_input.recordTokens(try records.next("plant_initial_geometry record"));
    try requireRunscriptRecordTag(&plant_geometry_tokens, "plant_initial_geometry", error.MissingPlantInitialGeometryRecord);
    const plant_geometry_parameters: plant_initialization.PlantGeometryParameters = .{
        .seed_volume_m3_per_g_c = try nextRecordFloat(&plant_geometry_tokens),
        .seed_length_multiplier = try nextRecordFloat(&plant_geometry_tokens),
        .seed_shape_volume_factor = try nextRecordFloat(&plant_geometry_tokens),
        .seed_pi = try nextRecordFloat(&plant_geometry_tokens),
        .seed_length_exponent = try nextRecordFloat(&plant_geometry_tokens),
        .seed_surface_area_multiplier = try nextRecordFloat(&plant_geometry_tokens),
        .root_volume_numerator_m3_per_g_c = try nextRecordFloat(&plant_geometry_tokens),
        .root_dry_matter_fraction = try nextRecordFloat(&plant_geometry_tokens),
        .root_porosity_floor = try nextRecordFloat(&plant_geometry_tokens),
        .root_pi = try nextRecordFloat(&plant_geometry_tokens),
    };
    try requireRunscriptRecordEnd(&plant_geometry_tokens, "plant_initial_geometry");
    try plant_geometry_parameters.validate();
    var phenology_initial_tokens = delimited_input.recordTokens(try records.next("plant_initial_phenology record"));
    try requireRunscriptRecordTag(&phenology_initial_tokens, "plant_initial_phenology", error.MissingPlantInitialPhenologyRecord);
    const phenology_initialization_parameters: plant_initialization.PhenologyInitializationParameters = .{
        .perennial_input_scale = try nextRecordFloat(&phenology_initial_tokens),
        .minimum_perennial_node_scaling = try nextRecordFloat(&phenology_initial_tokens),
        .perennial_maximum_concurrently_growing_nodes = try nextRecordUnsigned(&phenology_initial_tokens),
        .early_maturity_group_maximum = try nextRecordFloat(&phenology_initial_tokens),
        .intermediate_maturity_group_maximum = try nextRecordFloat(&phenology_initial_tokens),
        .early_maximum_concurrently_growing_nodes = try nextRecordUnsigned(&phenology_initial_tokens),
        .intermediate_maximum_concurrently_growing_nodes = try nextRecordUnsigned(&phenology_initial_tokens),
        .late_maximum_concurrently_growing_nodes = try nextRecordUnsigned(&phenology_initial_tokens),
    };
    try requireRunscriptRecordEnd(&phenology_initial_tokens, "plant_initial_phenology");
    try phenology_initialization_parameters.validate();
    var root_initial_tokens = delimited_input.recordTokens(try records.next("root_initialization record"));
    try requireRunscriptRecordTag(&root_initial_tokens, "root_initialization", error.MissingRootInitializationRecord);
    const root_initialization_parameters: plant_root_system.InitializationParameters = .{
        .root_nitrogen_to_maximum_protein_multiplier = try nextRecordFloat(&root_initial_tokens),
        .root_phosphorus_to_maximum_protein_multiplier = try nextRecordFloat(&root_initial_tokens),
        .mycorrhizal_radius_m = try nextRecordFloat(&root_initial_tokens),
        .initial_total_water_potential_megapascal = try nextRecordFloat(&root_initial_tokens),
        .osmotic_water_potential_decrement_megapascal = try nextRecordFloat(&root_initial_tokens),
        .initial_active_length_m = try nextRecordFloat(&root_initial_tokens),
        .initial_water_fraction = try nextRecordFloat(&root_initial_tokens),
    };
    try requireRunscriptRecordEnd(&root_initial_tokens, "root_initialization");
    try root_initialization_parameters.validate();
    var root_morphology_tokens = delimited_input.recordTokens(try records.next("root_morphology record"));
    try requireRunscriptRecordTag(&root_morphology_tokens, "root_morphology", error.MissingRootMorphologyRecord);
    const root_morphology_parameters: plant_root_system.MorphologyParameters = .{
        .minimum_average_secondary_length_m = try nextRecordFloat(&root_morphology_tokens),
        .root_elastic_modulus_megapascal = try nextRecordFloat(&root_morphology_tokens),
    };
    try requireRunscriptRecordEnd(&root_morphology_tokens, "root_morphology");
    try root_morphology_parameters.validate();
    var standing_energy_tokens = delimited_input.recordTokens(try records.next("standing_dead_energy record"));
    try requireRunscriptRecordTag(&standing_energy_tokens, "standing_dead_energy", error.MissingStandingDeadEnergyRecord);
    const standing_dead_sapwood_thickness_m = try nextRecordFloat(&standing_energy_tokens);
    const standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k = try nextRecordFloat(&standing_energy_tokens);
    const standing_dead_emissivity = try nextRecordFloat(&standing_energy_tokens);
    const standing_dead_activation_heat_capacity_megajoules_per_m2_k = try nextRecordFloat(&standing_energy_tokens);
    const standing_dead_effective_heat_capacity_floor_megajoules_per_m2_k = try nextRecordFloat(&standing_energy_tokens);
    try requireRunscriptRecordEnd(&standing_energy_tokens, "standing_dead_energy");
    if (!std.math.isFinite(standing_dead_sapwood_thickness_m) or standing_dead_sapwood_thickness_m <= 0 or !std.math.isFinite(standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k) or standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k <= 0 or !std.math.isFinite(standing_dead_emissivity) or standing_dead_emissivity < 0 or standing_dead_emissivity > 1 or !std.math.isFinite(standing_dead_activation_heat_capacity_megajoules_per_m2_k) or standing_dead_activation_heat_capacity_megajoules_per_m2_k <= 0 or !std.math.isFinite(standing_dead_effective_heat_capacity_floor_megajoules_per_m2_k) or standing_dead_effective_heat_capacity_floor_megajoules_per_m2_k <= 0) return error.InvalidStandingDeadEnergyControls;
    var woody_tokens = delimited_input.recordTokens(try records.next("woody_optics record"));
    try requireRunscriptRecordTag(&woody_tokens, "woody_optics", error.MissingWoodyOpticsRecord);
    const woody_optics_parameters: canopy_optics.WoodyOpticsParameters = .{
        .stalk_shortwave_albedo = try nextRecordFloat(&woody_tokens),
        .stalk_par_albedo = try nextRecordFloat(&woody_tokens),
        .standing_dead_shortwave_albedo = try nextRecordFloat(&woody_tokens),
        .standing_dead_par_albedo = try nextRecordFloat(&woody_tokens),
    };
    try requireRunscriptRecordEnd(&woody_tokens, "woody_optics");
    try woody_optics_parameters.validate();
    var retention_tokens = delimited_input.recordTokens(try records.next("canopy_retention record"));
    try requireRunscriptRecordTag(&retention_tokens, "canopy_retention", error.MissingCanopyRetentionRecord);
    const canopy_retention_parameters: canopy_precipitation_retention.Parameters = .{
        .surface_water_capacity_m3_per_m2_by_root_profile = .{ try nextRecordFloat(&retention_tokens), try nextRecordFloat(&retention_tokens), try nextRecordFloat(&retention_tokens), try nextRecordFloat(&retention_tokens) },
        .low_sun_extinction_per_area_index = try nextRecordFloat(&retention_tokens),
        .minimum_solar_angle_sine_for_radiation_shares = try nextRecordFloat(&retention_tokens),
    };
    try requireRunscriptRecordEnd(&retention_tokens, "canopy_retention");
    try canopy_retention_parameters.validate();
    var shoot_tokens = delimited_input.recordTokens(try records.next("shoot_controls record"));
    try requireRunscriptRecordTag(&shoot_tokens, "shoot_controls", error.MissingShootControlsRecord);
    const shoot_control_parameters: plant_initialization.ShootControlParameters = .{
        .seconds_per_hour = try nextRecordFloat(&shoot_tokens),
        .co2_to_water_cuticular_resistance_ratio = try nextRecordFloat(&shoot_tokens),
        .c3_intercellular_oxygen_umol_per_mol = try nextRecordFloat(&shoot_tokens),
        .c4_intercellular_oxygen_umol_per_mol = try nextRecordFloat(&shoot_tokens),
    };
    try requireRunscriptRecordEnd(&shoot_tokens, "shoot_controls");
    try shoot_control_parameters.validate();
    var c4_tokens = delimited_input.recordTokens(try records.next("c4_carbon record"));
    try requireRunscriptRecordTag(&c4_tokens, "c4_carbon", error.MissingC4CarbonRecord);
    const c4_carbon_parameters: canopy_photosynthesis.C4CarbonParameters = .{
        .bundle_sheath_water_g_per_g_c = try nextRecordFloat(&c4_tokens),
        .mesophyll_water_g_per_g_c = try nextRecordFloat(&c4_tokens),
        .co2_concentration_umol_per_l_per_g_c_per_g_leaf_c = try nextRecordFloat(&c4_tokens),
        .decarboxylation_fraction_per_h = try nextRecordFloat(&c4_tokens),
        .co2_decarboxylation_inhibition_umol_per_l = try nextRecordFloat(&c4_tokens),
        .decarboxylated_co2_fraction = try nextRecordFloat(&c4_tokens),
        .leakage_g_c_per_umol_per_l_g_leaf_c_h = try nextRecordFloat(&c4_tokens),
        .mesophyll_feedback_half_saturation_umol_per_l = try nextRecordFloat(&c4_tokens),
        .co2_compensation_umol_per_l = try nextRecordFloat(&c4_tokens),
        .electron_requirement_umol_e_per_umol_co2 = try nextRecordFloat(&c4_tokens),
    };
    try requireRunscriptRecordEnd(&c4_tokens, "c4_carbon");
    try c4_carbon_parameters.validate();
    var thermal_tokens = delimited_input.recordTokens(try records.next("thermal_controls record"));
    try requireRunscriptRecordTag(&thermal_tokens, "thermal_controls", error.MissingThermalControlsRecord);
    const thermal_acclimation_parameters: plant_initialization.ThermalAcclimationParameters = .{
        .adaptation_zone_pivot = try nextRecordFloat(&thermal_tokens),
        .cold_zone_offset_per_zone_c = try nextRecordFloat(&thermal_tokens),
        .warm_zone_offset_per_zone_c = try nextRecordFloat(&thermal_tokens),
        .base_leafout_threshold_c = try nextRecordFloat(&thermal_tokens),
        .base_leafoff_threshold_c = try nextRecordFloat(&thermal_tokens),
        .maximum_leafoff_threshold_c = try nextRecordFloat(&thermal_tokens),
        .soybean_c3_seed_set_base_c = try nextRecordFloat(&thermal_tokens),
        .other_c3_seed_set_base_c = try nextRecordFloat(&thermal_tokens),
        .c4_seed_set_base_c = try nextRecordFloat(&thermal_tokens),
        .seed_set_adaptation_increment_c_per_zone = try nextRecordFloat(&thermal_tokens),
        .soybean_loss_fraction_per_c_h = try nextRecordFloat(&thermal_tokens),
        .other_c3_loss_fraction_per_c_h = try nextRecordFloat(&thermal_tokens),
        .maize_loss_fraction_per_c_h = try nextRecordFloat(&thermal_tokens),
        .other_c4_loss_fraction_per_c_h = try nextRecordFloat(&thermal_tokens),
    };
    try requireRunscriptRecordEnd(&thermal_tokens, "thermal_controls");
    try thermal_acclimation_parameters.validate();
    var stress_tokens = delimited_input.recordTokens(try records.next("canopy_stress record"));
    try requireRunscriptRecordTag(&stress_tokens, "canopy_stress", error.MissingCanopyStressRecord);
    const canopy_stress_parameters: canopy_biochemistry.StressParameters = .{
        .maximum_chilling_h = try nextRecordFloat(&stress_tokens),
        .heat_accumulation_threshold_c = try nextRecordFloat(&stress_tokens),
        .heat_recovery_per_h = try nextRecordFloat(&stress_tokens),
        .growth_temperature = .{
            .gas_constant_j_per_mol_k = try nextRecordFloat(&stress_tokens),
            .temperature_scale_k = try nextRecordFloat(&stress_tokens),
            .arrhenius_log_prefactor = try nextRecordFloat(&stress_tokens),
            .activation_energy_j_per_mol = try nextRecordFloat(&stress_tokens),
            .low_temperature_inactivation_j_per_mol = try nextRecordFloat(&stress_tokens),
            .high_temperature_inactivation_j_per_mol = try nextRecordFloat(&stress_tokens),
        },
    };
    try requireRunscriptRecordEnd(&stress_tokens, "canopy_stress");
    try canopy_stress_parameters.validate();
    var phenology_tokens = delimited_input.recordTokens(try records.next("phenology_controls record"));
    try requireRunscriptRecordTag(&phenology_tokens, "phenology_controls", error.MissingPhenologyControlsRecord);
    const phenology_parameters: plant_phenology.Parameters = .{
        .gas_constant_j_per_mol_k = try nextRecordFloat(&phenology_tokens),
        .temperature_scale_k = try nextRecordFloat(&phenology_tokens),
        .arrhenius_log_prefactor = try nextRecordFloat(&phenology_tokens),
        .activation_energy_j_per_mol = try nextRecordFloat(&phenology_tokens),
        .low_temperature_inactivation_j_per_mol = try nextRecordFloat(&phenology_tokens),
        .high_temperature_inactivation_j_per_mol = try nextRecordFloat(&phenology_tokens),
        .minimum_turgor_potential_megapascal = try nextRecordFloat(&phenology_tokens),
        .oxygen_stress_exponent = try nextRecordFloat(&phenology_tokens),
        .vegetative_stage_duration = try nextRecordFloat(&phenology_tokens),
        .reproductive_stage_duration = try nextRecordFloat(&phenology_tokens),
        .drought_leafout_total_water_potential_megapascal = try nextRecordFloat(&phenology_tokens),
        .nonvascular_leafoff_total_water_potential_megapascal = try nextRecordFloat(&phenology_tokens),
        .vascular_leafoff_total_water_potential_megapascal = try nextRecordFloat(&phenology_tokens),
        .maximum_photoperiod_counter_h = try nextRecordFloat(&phenology_tokens),
        .emergence_area_threshold_m2_per_plant = try nextRecordFloat(&phenology_tokens),
        .emergence_root_depth_margin_m = try nextRecordFloat(&phenology_tokens),
    };
    try requireRunscriptRecordEnd(&phenology_tokens, "phenology_controls");
    try phenology_parameters.validate();
    var pool_tokens = delimited_input.recordTokens(try records.next("plant_pool_controls record"));
    try requireRunscriptRecordTag(&pool_tokens, "plant_pool_controls", error.MissingPlantPoolControlsRecord);
    const dynamic_plant_salts = try nextRecordBool(&pool_tokens);
    const plant_pool_parameters: plant_pool_aggregation.RuntimeParameters = .{
        .branch_structural_presence_g_per_plant = try nextRecordFloat(&pool_tokens),
        .grain_fill_detection_g_c_per_plant = try nextRecordFloat(&pool_tokens),
        .plant_root_structural_presence_g_per_plant = try nextRecordFloat(&pool_tokens),
        .feedback_carbon_concentration_minimum_g_per_g = try nextRecordFloat(&pool_tokens),
        .nitrogen_inhibition_g_n_per_g_c = try nextRecordFloat(&pool_tokens),
        .phosphorus_inhibition_g_p_per_g_c = try nextRecordFloat(&pool_tokens),
    };
    try requireRunscriptRecordEnd(&pool_tokens, "plant_pool_controls");
    try plant_pool_parameters.validate();
    var seed_tokens = delimited_input.recordTokens(try records.next("seed_set_controls record"));
    try requireRunscriptRecordTag(&seed_tokens, "seed_set_controls", error.MissingSeedSetControlsRecord);
    const seed_set_parameters: canopy_photosynthesis.SeedSetParameters = .{
        .carbon_half_saturation_g_per_g = try nextRecordFloat(&seed_tokens),
        .nitrogen_half_saturation_g_per_g = try nextRecordFloat(&seed_tokens),
        .phosphorus_half_saturation_g_per_g = try nextRecordFloat(&seed_tokens),
    };
    try requireRunscriptRecordEnd(&seed_tokens, "seed_set_controls");
    try seed_set_parameters.validate();
    return .{
        .root_axes_per_plant = root_axes_per_plant,
        .canopy_layer_count = canopy_layer_count,
        .canopy_discretization = canopy_discretization,
        .stalk_volume_m3_per_g_c = stalk_volume_m3_per_g_c,
        .standing_dead_partition_parameters = standing_dead_partition_parameters,
        .plant_heat_water_parameters = plant_heat_water_parameters,
        .plant_geometry_parameters = plant_geometry_parameters,
        .phenology_initialization_parameters = phenology_initialization_parameters,
        .root_initialization_parameters = root_initialization_parameters,
        .root_morphology_parameters = root_morphology_parameters,
        .standing_dead_sapwood_thickness_m = standing_dead_sapwood_thickness_m,
        .standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k = standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k,
        .standing_dead_emissivity = standing_dead_emissivity,
        .standing_dead_activation_heat_capacity_megajoules_per_m2_k = standing_dead_activation_heat_capacity_megajoules_per_m2_k,
        .standing_dead_effective_heat_capacity_floor_megajoules_per_m2_k = standing_dead_effective_heat_capacity_floor_megajoules_per_m2_k,
        .woody_optics_parameters = woody_optics_parameters,
        .canopy_retention_parameters = canopy_retention_parameters,
        .shoot_control_parameters = shoot_control_parameters,
        .c4_carbon_parameters = c4_carbon_parameters,
        .thermal_acclimation_parameters = thermal_acclimation_parameters,
        .canopy_stress_parameters = canopy_stress_parameters,
        .phenology_parameters = phenology_parameters,
        .plant_pool_parameters = plant_pool_parameters,
        .dynamic_plant_salts = dynamic_plant_salts,
        .seed_set_parameters = seed_set_parameters,
    };
}

const PlantGrowthProcessRecords = struct {
    organ_partition_parameters: plant_organ_partition.Parameters,
    shoot_metabolism_parameters: shoot_growth_metabolism.Parameters,
    shoot_node_growth_parameters: shoot_growth_runtime.NodeGrowthParameters,
    seasonal_turnover_parameters: SeasonalTurnoverParameters,
    branch_mobile_exchange_parameters: shoot_growth_runtime.BranchMobileExchangeParameters,
    symbiotic_fixation_parameters: plant_symbiotic_fixation.RuntimeParameters,
    plant_fire_combustion_parameters: plant_root_disturbance.CombustionParameters,
    soil_fire_combustion_parameters: soil_combustion.Parameters,
    shoot_root_exchange_parameters: plant_shoot_root_exchange.Parameters,
    storage_remobilization_parameters: plant_storage_remobilization.Parameters,
};

noinline fn parsePlantGrowthProcessRecords(records: *RunscriptRecordCursor) !PlantGrowthProcessRecords {
    var stage8_tokens = delimited_input.recordTokens(try records.next("organ_partition record"));
    try requireRunscriptRecordTag(&stage8_tokens, "organ_partition", error.MissingOrganPartitionRecord);
    var tokens = stage8_tokens;
    const organ_partition_parameters: plant_organ_partition.Parameters = .{
        .initial_leaf_fraction = try nextFloat(&tokens, "initial leaf growth partition fraction"),
        .initial_sheath_fraction = try nextFloat(&tokens, "initial sheath growth partition fraction"),
        .minimum_leaf_fraction_by_determinacy = .{ try nextFloat(&tokens, "minimum determinate leaf partition fraction"), try nextFloat(&tokens, "minimum indeterminate leaf partition fraction") },
        .minimum_sheath_fraction_by_determinacy = .{ try nextFloat(&tokens, "minimum determinate sheath partition fraction"), try nextFloat(&tokens, "minimum indeterminate sheath partition fraction") },
        .leaf_reduction_by_turnover = .{ try nextFloat(&tokens, "turnover-0 leaf partition reduction"), try nextFloat(&tokens, "turnover-1 leaf partition reduction"), try nextFloat(&tokens, "turnover-2 leaf partition reduction"), try nextFloat(&tokens, "turnover-3 leaf partition reduction"), try nextFloat(&tokens, "turnover-4 leaf partition reduction"), try nextFloat(&tokens, "turnover-5 leaf partition reduction") },
        .sheath_reduction_by_turnover = .{ try nextFloat(&tokens, "turnover-0 sheath partition reduction"), try nextFloat(&tokens, "turnover-1 sheath partition reduction"), try nextFloat(&tokens, "turnover-2 sheath partition reduction"), try nextFloat(&tokens, "turnover-3 sheath partition reduction"), try nextFloat(&tokens, "turnover-4 sheath partition reduction"), try nextFloat(&tokens, "turnover-5 sheath partition reduction") },
        .low_reserve_carbon_per_sapwood_g_c_per_g_c = try nextFloat(&tokens, "low reserve carbon per sapwood in g C g-1 C"),
        .low_reserve_redirect_fraction = try nextFloat(&tokens, "low reserve growth redirect fraction"),
    };
    try requireRunscriptRecordEnd(&tokens, "organ_partition");
    try organ_partition_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("shoot_metabolism record"));
    try requireRunscriptRecordTag(&tokens, "shoot_metabolism", error.MissingShootMetabolismRecord);
    const shoot_metabolism_parameters: shoot_growth_metabolism.Parameters = .{
        .maximum_mobile_carbon_oxidation_per_h = try nextFloat(&tokens, "maximum shoot mobile-carbon oxidation fraction per h"),
        .mobile_carbon_respiration_half_saturation_g_c_per_g_c = try nextFloat(&tokens, "shoot mobile-carbon respiration half saturation in g C g-1 C"),
        .maintenance_respiration_g_c_per_g_n_h = try nextFloat(&tokens, "shoot maintenance respiration in g C g-1 N h-1"),
        .minimum_leaf_nutrient_fraction = try nextFloat(&tokens, "minimum leaf nutrient fraction"),
        .nitrogen_assimilation_respiration_g_c_per_g_n = try nextFloat(&tokens, "shoot nitrogen-assimilation respiration in g C g-1 N"),
        .fixation_respiration_credit_g_c_per_g_fixed_c = try nextFloat(&tokens, "shoot fixation respiration credit in g C g-1 fixed C"),
        .mobile_nitrogen_inhibition_g_n_per_g_c = try nextFloat(&tokens, "mobile nitrogen inhibition in g N g-1 C"),
        .mobile_phosphorus_inhibition_g_p_per_g_c = try nextFloat(&tokens, "mobile phosphorus inhibition in g P g-1 C"),
    };
    try requireRunscriptRecordEnd(&tokens, "shoot_metabolism");
    try shoot_metabolism_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("shoot_node_growth record"));
    try requireRunscriptRecordTag(&tokens, "shoot_node_growth", error.MissingShootNodeGrowthRecord);
    const shoot_node_growth_parameters: shoot_growth_runtime.NodeGrowthParameters = .{
        .protein_per_nitrogen_g_protein_per_g_n = try nextFloat(&tokens, "shoot protein per nitrogen in g protein g-1 N"),
        .protein_per_phosphorus_g_protein_per_g_p = try nextFloat(&tokens, "shoot protein per phosphorus in g protein g-1 P"),
        .leaf_mass_exponent = try nextFloat(&tokens, "specific leaf-area mass exponent"),
        .sheath_mass_exponent = try nextFloat(&tokens, "specific sheath-length mass exponent"),
        .internode_mass_exponent = try nextFloat(&tokens, "specific internode-length mass exponent"),
        .minimum_leaf_carbon_g_c_per_m2_cell = try nextFloat(&tokens, "minimum leaf carbon in g C m-2 cell"),
        .minimum_sheath_carbon_g_c_per_m2_cell = try nextFloat(&tokens, "minimum sheath carbon in g C m-2 cell"),
        .minimum_internode_carbon_g_c_per_m2_cell = try nextFloat(&tokens, "minimum internode carbon in g C m-2 cell"),
        .leaf_nutrient_exchange_fraction = try nextFloat(&tokens, "leaf nutrient exchange fraction"),
        .branch_reserve_carbon_exchange_fraction_per_h = try nextFloat(&tokens, "branch reserve carbon exchange fraction per h"),
        .branch_reserve_nutrient_exchange_fraction_per_h = try nextFloat(&tokens, "branch reserve nutrient exchange fraction per h"),
        .minimum_grain_nutrient_fraction = try nextFloat(&tokens, "minimum grain nutrient fraction"),
        .reserve_nitrogen_half_saturation_g_n_per_g_c = try nextFloat(&tokens, "reserve nitrogen half saturation in g N g-1 C"),
        .reserve_phosphorus_half_saturation_g_p_per_g_c = try nextFloat(&tokens, "reserve phosphorus half saturation in g P g-1 C"),
        .physiological_maturity_no_fill_h = try nextFloat(&tokens, "hours without grain fill to physiological maturity"),
        .maximum_previous_stalk_nodes_in_rolling_window = try nextRecordUnsigned(&tokens),
        .annual_leafoff_delay_h_by_phenology = .{
            try nextFloat(&tokens, "evergreen annual leafoff delay in h"),
            try nextFloat(&tokens, "cold-deciduous annual leafoff delay in h"),
            try nextFloat(&tokens, "drought-deciduous annual leafoff delay in h"),
            try nextFloat(&tokens, "combined-deciduous annual leafoff delay in h"),
        },
        .leaf_storage_exchange_fraction_per_h_by_turnover = .{
            try nextFloat(&tokens, "deciduous-herbaceous leaf storage exchange fraction per h"),
            try nextFloat(&tokens, "deciduous-woody leaf storage exchange fraction per h"),
            try nextFloat(&tokens, "needleleaf-evergreen leaf storage exchange fraction per h"),
            try nextFloat(&tokens, "broadleaf-evergreen leaf storage exchange fraction per h"),
            try nextFloat(&tokens, "semi-deciduous leaf storage exchange fraction per h"),
            try nextFloat(&tokens, "semi-evergreen leaf storage exchange fraction per h"),
        },
    };
    try requireRunscriptRecordEnd(&tokens, "shoot_node_growth");
    try shoot_node_growth_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("seasonal_turnover record"));
    try requireRunscriptRecordTag(&tokens, "seasonal_turnover", error.MissingSeasonalTurnoverRecord);
    const seasonal_turnover_parameters: SeasonalTurnoverParameters = .{
        .litterfall_rate_per_h = try nextFloat(&tokens, "end-of-season litterfall rate per h"),
        .litterfall_delay_threshold_h = try nextFloat(&tokens, "end-of-season litterfall delay threshold in h"),
    };
    try requireRunscriptRecordEnd(&tokens, "seasonal_turnover");
    try seasonal_turnover_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("branch_mobile_exchange record"));
    try requireRunscriptRecordTag(&tokens, "branch_mobile_exchange", error.MissingBranchMobileExchangeRecord);
    const branch_mobile_exchange_parameters: shoot_growth_runtime.BranchMobileExchangeParameters = .{
        .carbon_exchange_fraction_per_h = try nextFloat(&tokens, "interbranch mobile carbon exchange fraction per h"),
        .nutrient_exchange_fraction_per_h = try nextFloat(&tokens, "interbranch mobile nutrient exchange fraction per h"),
        .remobilization_redistribution_fraction_per_h = try nextFloat(&tokens, "main-to-lateral remobilization redistribution fraction per h"),
    };
    try requireRunscriptRecordEnd(&tokens, "branch_mobile_exchange");
    try branch_mobile_exchange_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("symbiotic_fixation record"));
    try requireRunscriptRecordTag(&tokens, "symbiotic_fixation", error.MissingSymbioticFixationRecord);
    const symbiotic_fixation_parameters: plant_symbiotic_fixation.RuntimeParameters = .{
        .initial_bacterial_carbon_g_c_per_m2 = try nextFloat(&tokens, "initial symbiotic bacterial carbon in g C m-2"),
        .specific_respiration_per_h = try nextFloat(&tokens, "symbiotic specific respiration per h"),
        .specific_maintenance_g_c_per_g_n_h = try nextFloat(&tokens, "symbiotic maintenance in g C g-1 N h-1"),
        .nitrogen_fixation_yield_g_n_per_g_c = try nextFloat(&tokens, "symbiotic nitrogen fixation yield in g N g-1 C"),
        .nitrogen_inhibition_g_n_per_g_c = try nextFloat(&tokens, "symbiotic nitrogen inhibition in g N g-1 C"),
        .phosphorus_inhibition_g_p_per_g_c = try nextFloat(&tokens, "symbiotic phosphorus inhibition in g P g-1 C"),
        .nonstructural_nitrogen_half_saturation_g_n_per_g_c = try nextFloat(&tokens, "symbiotic mobile nitrogen half saturation in g N g-1 C"),
        .nonstructural_phosphorus_half_saturation_g_p_per_g_c = try nextFloat(&tokens, "symbiotic mobile phosphorus half saturation in g P g-1 C"),
        .excess_nitrogen_inhibition_g_n_per_g_c = try nextFloat(&tokens, "symbiotic excess nitrogen inhibition in g N g-1 C"),
        .excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p = try nextFloat(&tokens, "symbiotic nitrogen phosphorus inhibition in g N g-1 P"),
        .decomposition_rate_per_h = try nextFloat(&tokens, "symbiotic decomposition rate per h"),
        .minimum_carbon_recycling_fraction = try nextFloat(&tokens, "symbiotic minimum carbon recycling fraction"),
        .carbon_recycling_range_fraction = try nextFloat(&tokens, "symbiotic responsive carbon recycling fraction"),
        .maximum_nitrogen_recycling_fraction = try nextFloat(&tokens, "symbiotic maximum nitrogen recycling fraction"),
        .maximum_phosphorus_recycling_fraction = try nextFloat(&tokens, "symbiotic maximum phosphorus recycling fraction"),
        .host_exchange_fraction_per_h_by_fixation_type = .{
            try nextFloat(&tokens, "fixation type 1 host exchange fraction per h"), try nextFloat(&tokens, "fixation type 2 host exchange fraction per h"), try nextFloat(&tokens, "fixation type 3 host exchange fraction per h"),
            try nextFloat(&tokens, "fixation type 4 host exchange fraction per h"), try nextFloat(&tokens, "fixation type 5 host exchange fraction per h"), try nextFloat(&tokens, "fixation type 6 host exchange fraction per h"),
        },
        .decomposition_control_ratio_by_fixation_type = .{
            try nextFloat(&tokens, "fixation type 1 decomposition control ratio"), try nextFloat(&tokens, "fixation type 2 decomposition control ratio"), try nextFloat(&tokens, "fixation type 3 decomposition control ratio"),
            try nextFloat(&tokens, "fixation type 4 decomposition control ratio"), try nextFloat(&tokens, "fixation type 5 decomposition control ratio"), try nextFloat(&tokens, "fixation type 6 decomposition control ratio"),
        },
    };
    try requireRunscriptRecordEnd(&tokens, "symbiotic_fixation");
    try symbiotic_fixation_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("plant_fire_combustion record"));
    try requireRunscriptRecordTag(&tokens, "plant_fire_combustion", error.MissingPlantFireCombustionRecord);
    const plant_fire_combustion_parameters: plant_root_disturbance.CombustionParameters = .{
        .minimum_combustion_temperature_k = try nextFloat(&tokens, "minimum root nodule combustion temperature in K"),
        .maximum_arrhenius_response = try nextFloat(&tokens, "maximum root nodule combustion Arrhenius response"),
        .gas_constant_j_per_mol_k = try nextFloat(&tokens, "root nodule combustion gas constant in J mol-1 K-1"),
        .activation_energy_j_per_mol = try nextFloat(&tokens, "root nodule combustion activation energy in J mol-1"),
        .arrhenius_intercept = try nextFloat(&tokens, "root nodule combustion Arrhenius intercept"),
        .mobile_and_leaf_specific_combustion_g_c_per_m2_h = try nextFloat(&tokens, "mobile and leaf specific combustion in g C m-2 h-1"),
        .nonwoody_structural_specific_combustion_g_c_per_m2_h = try nextFloat(&tokens, "nonwoody structural specific combustion in g C m-2 h-1"),
        .root_structural_specific_combustion_g_c_per_m2_h = try nextFloat(&tokens, "root structural specific combustion in g C m-2 h-1"),
        .woody_structural_specific_combustion_g_c_per_m2_h = try nextFloat(&tokens, "woody structural specific combustion in g C m-2 h-1"),
        .standing_dead_specific_combustion_g_c_per_m2_h = try nextFloat(&tokens, "standing-dead specific combustion in g C m-2 h-1"),
        .charcoal_activation_energy_j_per_mol = try nextFloat(&tokens, "charcoal combustion activation energy in J mol-1"),
        .charcoal_arrhenius_intercept = try nextFloat(&tokens, "charcoal combustion Arrhenius intercept"),
        .charcoal_specific_combustion_g_c_per_m2_h = try nextFloat(&tokens, "charcoal specific combustion in g C m-2 h-1"),
        .oxygen_g_per_g_combusted_carbon = try nextFloat(&tokens, "oxygen consumption in g O per g combusted C"),
        .maximum_aerobic_charcoal_fraction = try nextFloat(&tokens, "maximum aerobic charcoal fraction"),
        .maximum_anaerobic_charcoal_fraction = try nextFloat(&tokens, "maximum anaerobic charcoal fraction"),
        .oxygen_half_saturation_umol_per_mol = try nextFloat(&tokens, "fire oxygen half saturation in umol mol-1"),
        .methane_half_saturation_umol_per_mol = try nextFloat(&tokens, "fire methane half saturation in umol mol-1"),
        .aerobic_combustion_energy_megajoules_per_g_c = try nextFloat(&tokens, "aerobic combustion energy in MJ per g C"),
        .anaerobic_combustion_energy_megajoules_per_g_c = try nextFloat(&tokens, "anaerobic combustion energy in MJ per g C"),
        .methane_combustion_energy_megajoules_per_g_c = try nextFloat(&tokens, "methane combustion energy in MJ per g C"),
    };
    try requireRunscriptRecordEnd(&tokens, "plant_fire_combustion");
    try plant_fire_combustion_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("soil_fire_combustion record"));
    try requireRunscriptRecordTag(&tokens, "soil_fire_combustion", error.MissingSoilFireCombustionRecord);
    const soil_fire_combustion_parameters: soil_combustion.Parameters = .{
        .minimum_combustion_temperature_k = try nextFloat(&tokens, "minimum soil combustion temperature in K"),
        .maximum_arrhenius_response = try nextFloat(&tokens, "maximum soil combustion Arrhenius response"),
        .gas_constant_j_per_mol_k = try nextFloat(&tokens, "soil combustion gas constant in J mol-1 K-1"),
        .activation_energy_j_per_mol = try nextFloat(&tokens, "soil combustion activation energy in J mol-1"),
        .arrhenius_intercept = try nextFloat(&tokens, "soil combustion Arrhenius intercept"),
        .charcoal_activation_energy_j_per_mol = try nextFloat(&tokens, "soil charcoal activation energy in J mol-1"),
        .charcoal_arrhenius_intercept = try nextFloat(&tokens, "soil charcoal Arrhenius intercept"),
        .specific_combustion_by_substrate_g_c_per_m2_h = .{
            try nextFloat(&tokens, "woody residue soil combustion in g C m-2 h-1"),
            try nextFloat(&tokens, "nonwoody residue soil combustion in g C m-2 h-1"),
            try nextFloat(&tokens, "manure soil combustion in g C m-2 h-1"),
            try nextFloat(&tokens, "particulate organic matter combustion in g C m-2 h-1"),
            try nextFloat(&tokens, "humus combustion in g C m-2 h-1"),
            try nextFloat(&tokens, "autotrophic biomass combustion in g C m-2 h-1"),
        },
        .charcoal_specific_combustion_g_c_per_m2_h = try nextFloat(&tokens, "soil charcoal combustion in g C m-2 h-1"),
        .oxygen_g_per_g_combusted_carbon = try nextFloat(&tokens, "subsurface fire oxygen in g O per g C"),
        .maximum_aerobic_charcoal_fraction = try nextFloat(&tokens, "subsurface maximum aerobic charcoal fraction"),
        .maximum_anaerobic_charcoal_fraction = try nextFloat(&tokens, "subsurface maximum anaerobic charcoal fraction"),
        .oxygen_half_saturation_g_o_per_m3 = try nextFloat(&tokens, "subsurface fire oxygen half saturation in g O m-3"),
        .methane_half_saturation_g_c_per_m3 = try nextFloat(&tokens, "subsurface fire methane half saturation in g C m-3"),
        .aerobic_combustion_energy_megajoules_per_g_c = try nextFloat(&tokens, "subsurface aerobic combustion energy in MJ per g C"),
        .anaerobic_combustion_energy_megajoules_per_g_c = try nextFloat(&tokens, "subsurface anaerobic combustion energy in MJ per g C"),
        .methane_combustion_energy_megajoules_per_g_c = try nextFloat(&tokens, "subsurface methane combustion energy in MJ per g C"),
    };
    try requireRunscriptRecordEnd(&tokens, "soil_fire_combustion");
    try soil_fire_combustion_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("shoot_root_exchange record"));
    try requireRunscriptRecordTag(&tokens, "shoot_root_exchange", error.MissingShootRootExchangeRecord);
    const shoot_root_exchange_parameters: plant_shoot_root_exchange.Parameters = .{
        .minimum_partner_structural_ratio = try nextFloat(&tokens, "minimum shoot-root partner structural ratio"),
        .minimum_annual_carbon_exchange_fraction_per_h = try nextFloat(&tokens, "minimum annual shoot-root carbon exchange fraction per h"),
        .annual_leaf_partition_exponent = try nextFloat(&tokens, "annual leaf partition exchange exponent"),
        .salt_exchange_fraction_per_h = try nextFloat(&tokens, "shoot-root salt exchange fraction per h"),
    };
    try requireRunscriptRecordEnd(&tokens, "shoot_root_exchange");
    try shoot_root_exchange_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("storage_remobilization record"));
    try requireRunscriptRecordTag(&tokens, "storage_remobilization", error.MissingStorageRemobilizationRecord);
    const storage_remobilization_parameters: plant_storage_remobilization.Parameters = .{
        .remobilization_duration_h = .{ try nextFloat(&tokens, "annual storage remobilization duration in h"), try nextFloat(&tokens, "perennial storage remobilization duration in h") },
        .storage_carbon_oxidation_fraction_per_h = .{ try nextFloat(&tokens, "annual storage carbon oxidation fraction per h"), try nextFloat(&tokens, "perennial storage carbon oxidation fraction per h") },
        .shoot_carbon_partition_fraction = .{ try nextFloat(&tokens, "annual shoot storage partition fraction"), try nextFloat(&tokens, "perennial shoot storage partition fraction") },
        .root_carbon_partition_fraction = .{ try nextFloat(&tokens, "annual root storage partition fraction"), try nextFloat(&tokens, "perennial root storage partition fraction") },
        .perennial_nutrient_equilibration_fraction_per_h = .{
            try nextFloat(&tokens, "turnover-0 storage nutrient equilibration fraction per h"),
            try nextFloat(&tokens, "turnover-1 storage nutrient equilibration fraction per h"),
            try nextFloat(&tokens, "turnover-2 storage nutrient equilibration fraction per h"),
            try nextFloat(&tokens, "turnover-3 storage nutrient equilibration fraction per h"),
            try nextFloat(&tokens, "turnover-4 storage nutrient equilibration fraction per h"),
            try nextFloat(&tokens, "turnover-5 storage nutrient equilibration fraction per h"),
        },
        .minimum_mobile_nitrogen_per_carbon_g_n_per_g_c = try nextFloat(&tokens, "minimum mobile nitrogen per carbon in g N g-1 C"),
        .maximum_mobile_nitrogen_per_carbon_g_n_per_g_c = try nextFloat(&tokens, "maximum mobile nitrogen per carbon in g N g-1 C"),
        .minimum_mobile_phosphorus_per_carbon_g_p_per_g_c = try nextFloat(&tokens, "minimum mobile phosphorus per carbon in g P g-1 C"),
        .maximum_mobile_phosphorus_per_carbon_g_p_per_g_c = try nextFloat(&tokens, "maximum mobile phosphorus per carbon in g P g-1 C"),
        .depleted_storage_threshold_g_c_per_g_root_c = try nextFloat(&tokens, "depleted seasonal storage threshold in g C g-1 root C"),
    };
    try requireRunscriptRecordEnd(&tokens, "storage_remobilization");
    try storage_remobilization_parameters.validate();
    return .{
        .organ_partition_parameters = organ_partition_parameters,
        .shoot_metabolism_parameters = shoot_metabolism_parameters,
        .shoot_node_growth_parameters = shoot_node_growth_parameters,
        .seasonal_turnover_parameters = seasonal_turnover_parameters,
        .branch_mobile_exchange_parameters = branch_mobile_exchange_parameters,
        .symbiotic_fixation_parameters = symbiotic_fixation_parameters,
        .plant_fire_combustion_parameters = plant_fire_combustion_parameters,
        .soil_fire_combustion_parameters = soil_fire_combustion_parameters,
        .shoot_root_exchange_parameters = shoot_root_exchange_parameters,
        .storage_remobilization_parameters = storage_remobilization_parameters,
    };
}

const RootProcessRecords = struct {
    root_gas_parameters: plant_root_gas_exchange.RuntimeParameters,
    root_nutrient_parameters: plant_root_nutrient_uptake.RuntimeParameters,
    root_salt_parameters: plant_root_salt_exchange.Parameters,
    root_mycorrhizal_exchange_parameters: plant_root_mycorrhizal_exchange.Parameters,
    root_exudation_parameters: plant_root_exudation.Parameters,
    root_porosity_parameters: plant_root_porosity.Parameters,
    root_metabolism_parameters: plant_root_metabolism.SecondaryRootParameters,
};

noinline fn parseRootProcessRecords(records: *RunscriptRecordCursor) !RootProcessRecords {
    var tokens = delimited_input.recordTokens(try records.next("root_gas record"));
    try requireRunscriptRecordTag(&tokens, "root_gas", error.MissingRootGasRecord);
    var root_gas_parameters: plant_root_gas_exchange.RuntimeParameters = blk: {
        var parameters = plant_root_gas_exchange.compatibilityParameters();
        parameters.reference_temperature_k = try nextFloat(&tokens, "root gas reference temperature in K");
        parameters.oxygen_aqueous_diffusivity_m2_per_h_at_reference = try nextFloat(&tokens, "oxygen aqueous diffusivity in m2 h-1 at reference temperature");
        parameters.aqueous_diffusivity_temperature_exponent = try nextFloat(&tokens, "aqueous gas diffusivity temperature exponent");
        parameters.oxygen_solubility_at_25c = try nextFloat(&tokens, "oxygen water-to-air mass solubility at 25 C");
        parameters.oxygen_solubility_activity_coefficient = try nextFloat(&tokens, "oxygen solubility activity coefficient");
        parameters.oxygen_solubility_temperature_intercept = try nextFloat(&tokens, "oxygen solubility temperature intercept");
        parameters.oxygen_solubility_temperature_coefficient_per_c = try nextFloat(&tokens, "oxygen solubility temperature coefficient per C");
        parameters.pure_water_solute_concentration_mol_per_m3 = try nextFloat(&tokens, "pure-water solute concentration in mol m-3");
        parameters.oxygen_to_carbon_respiration_ratio_g_o_per_g_c = try nextFloat(&tokens, "respiration oxygen-to-carbon ratio in g O g-1 C");
        parameters.minimum_soil_water_film_m = try nextFloat(&tokens, "minimum soil water film in m");
        parameters.soil_water_film_scale_m = try nextFloat(&tokens, "soil water film scale in m");
        parameters.soil_water_film_log_intercept = try nextFloat(&tokens, "soil water film log intercept");
        parameters.soil_water_film_potential_exponent = try nextFloat(&tokens, "soil water film potential exponent");
        const oxygen = @intFromEnum(plant_root_gas_exchange.TransportedGas.oxygen);
        parameters.aqueous_diffusivity_m2_per_h_at_reference[oxygen] = parameters.oxygen_aqueous_diffusivity_m2_per_h_at_reference;
        parameters.water_to_air_mass_solubility_at_25c[oxygen] = parameters.oxygen_solubility_at_25c;
        parameters.solubility_activity_coefficient[oxygen] = parameters.oxygen_solubility_activity_coefficient;
        parameters.solubility_temperature_intercept[oxygen] = parameters.oxygen_solubility_temperature_intercept;
        parameters.solubility_temperature_coefficient_per_c[oxygen] = parameters.oxygen_solubility_temperature_coefficient_per_c;
        break :blk parameters;
    };
    try requireRunscriptRecordEnd(&tokens, "root_gas");
    tokens = delimited_input.recordTokens(try records.next("root_gas_transport record"));
    try requireRunscriptRecordTag(&tokens, "root_gas_transport", error.MissingRootGasTransportRecord);
    root_gas_parameters.gaseous_diffusivity_temperature_exponent = try nextFloat(&tokens, "root gaseous diffusivity temperature exponent");
    for (&root_gas_parameters.gaseous_diffusivity_m2_per_h_at_reference) |*value| value.* = try nextFloat(&tokens, "root gaseous diffusivity in m2 h-1 at reference temperature");
    for (&root_gas_parameters.aqueous_diffusivity_m2_per_h_at_reference) |*value| value.* = try nextFloat(&tokens, "root aqueous diffusivity in m2 h-1 at reference temperature");
    for (&root_gas_parameters.water_to_air_mass_solubility_at_25c) |*value| value.* = try nextFloat(&tokens, "root gas water-to-air mass solubility at 25 C");
    for (&root_gas_parameters.solubility_activity_coefficient) |*value| value.* = try nextFloat(&tokens, "root gas solubility activity coefficient");
    for (&root_gas_parameters.solubility_temperature_intercept) |*value| value.* = try nextFloat(&tokens, "root gas solubility temperature intercept");
    for (&root_gas_parameters.solubility_temperature_coefficient_per_c) |*value| value.* = try nextFloat(&tokens, "root gas solubility temperature coefficient per C");
    const oxygen = @intFromEnum(plant_root_gas_exchange.TransportedGas.oxygen);
    root_gas_parameters.oxygen_aqueous_diffusivity_m2_per_h_at_reference = root_gas_parameters.aqueous_diffusivity_m2_per_h_at_reference[oxygen];
    root_gas_parameters.oxygen_solubility_at_25c = root_gas_parameters.water_to_air_mass_solubility_at_25c[oxygen];
    root_gas_parameters.oxygen_solubility_activity_coefficient = root_gas_parameters.solubility_activity_coefficient[oxygen];
    root_gas_parameters.oxygen_solubility_temperature_intercept = root_gas_parameters.solubility_temperature_intercept[oxygen];
    root_gas_parameters.oxygen_solubility_temperature_coefficient_per_c = root_gas_parameters.solubility_temperature_coefficient_per_c[oxygen];
    try requireRunscriptRecordEnd(&tokens, "root_gas_transport");
    try plant_root_gas_exchange.validateRuntimeParameters(root_gas_parameters);
    tokens = delimited_input.recordTokens(try records.next("root_nutrients record"));
    try requireRunscriptRecordTag(&tokens, "root_nutrients", error.MissingRootNutrientsRecord);
    const root_nutrient_parameters: plant_root_nutrient_uptake.RuntimeParameters = .{
        .reference_temperature_k = try nextFloat(&tokens, "root nutrient reference temperature in K"),
        .aqueous_diffusivity_m2_per_h_at_reference = .{
            try nextFloat(&tokens, "ammonium aqueous diffusivity in m2 h-1"),
            try nextFloat(&tokens, "nitrate aqueous diffusivity in m2 h-1"),
            try nextFloat(&tokens, "phosphate aqueous diffusivity in m2 h-1"),
        },
        .aqueous_diffusivity_temperature_exponent = try nextFloat(&tokens, "root nutrient diffusivity temperature exponent"),
        .liquid_tortuosity_coefficient = try nextFloat(&tokens, "root nutrient liquid tortuosity coefficient"),
        .nitrogen_inhibition_by_nitrogen_g_n_per_g_c = try nextFloat(&tokens, "root nitrogen-uptake nitrogen inhibition constant in g N g-1 C"),
        .nitrogen_inhibition_by_phosphorus_g_p_per_g_c = try nextFloat(&tokens, "root nitrogen-uptake phosphorus inhibition constant in g P g-1 C"),
        .phosphorus_inhibition_by_phosphorus_g_p_per_g_c = try nextFloat(&tokens, "root phosphorus-uptake phosphorus inhibition constant in g P g-1 C"),
        .phosphorus_inhibition_by_nitrogen_g_n_per_g_c = try nextFloat(&tokens, "root phosphorus-uptake nitrogen inhibition constant in g N g-1 C"),
        .minimum_population_uptake_fraction_multiplier = try nextFloat(&tokens, "minimum root population uptake fraction multiplier"),
        .phosphorus_molar_mass_g_per_mol = try nextFloat(&tokens, "phosphorus molar mass in g P mol-1"),
    };
    try requireRunscriptRecordEnd(&tokens, "root_nutrients");
    try root_nutrient_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("root_salts record"));
    try requireRunscriptRecordTag(&tokens, "root_salts", error.MissingRootSaltsRecord);
    const root_salt_parameters: plant_root_salt_exchange.Parameters = .{
        .reference_temperature_k = try nextFloat(&tokens, "root salt reference temperature in K"),
        .aqueous_diffusivity_m2_per_h_at_reference = .{
            try nextFloat(&tokens, "aluminum root salt diffusivity in m2 h-1"),
            try nextFloat(&tokens, "iron root salt diffusivity in m2 h-1"),
            try nextFloat(&tokens, "calcium root salt diffusivity in m2 h-1"),
            try nextFloat(&tokens, "magnesium root salt diffusivity in m2 h-1"),
            try nextFloat(&tokens, "sodium root salt diffusivity in m2 h-1"),
            try nextFloat(&tokens, "potassium root salt diffusivity in m2 h-1"),
            try nextFloat(&tokens, "sulfate root salt diffusivity in m2 h-1"),
            try nextFloat(&tokens, "chloride root salt diffusivity in m2 h-1"),
        },
        .aqueous_diffusivity_temperature_exponent = try nextFloat(&tokens, "root salt diffusivity temperature exponent"),
        .root_concentration_inhibition_mol_per_m3 = .{
            try nextFloat(&tokens, "aluminum root concentration inhibition in mol m-3"),
            try nextFloat(&tokens, "iron root concentration inhibition in mol m-3"),
            try nextFloat(&tokens, "calcium root concentration inhibition in mol m-3"),
            try nextFloat(&tokens, "magnesium root concentration inhibition in mol m-3"),
            try nextFloat(&tokens, "sodium root concentration inhibition in mol m-3"),
            try nextFloat(&tokens, "potassium root concentration inhibition in mol m-3"),
            try nextFloat(&tokens, "sulfate root concentration inhibition in mol m-3"),
            try nextFloat(&tokens, "chloride root concentration inhibition in mol m-3"),
        },
    };
    try requireRunscriptRecordEnd(&tokens, "root_salts");
    try root_salt_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("root_mycorrhizal_exchange record"));
    try requireRunscriptRecordTag(&tokens, "root_mycorrhizal_exchange", error.MissingRootMycorrhizalExchangeRecord);
    const root_mycorrhizal_exchange_parameters: plant_root_mycorrhizal_exchange.Parameters = .{
        .minimum_partner_water_volume_ratio = try nextFloat(&tokens, "minimum mycorrhizal partner water-volume ratio"),
        .exchange_fraction_per_h = try nextFloat(&tokens, "root-mycorrhizal exchange fraction per h"),
    };
    try requireRunscriptRecordEnd(&tokens, "root_mycorrhizal_exchange");
    try root_mycorrhizal_exchange_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("root_exudation record"));
    try requireRunscriptRecordTag(&tokens, "root_exudation", error.MissingRootExudationRecord);
    const root_exudation_parameters: plant_root_exudation.Parameters = .{
        .maximum_root_carbon_concentration_g_c_per_m3 = try nextFloat(&tokens, "maximum root mobile carbon concentration in g C m-3"),
        .root_mobile_nitrogen_exchange_fraction = try nextFloat(&tokens, "root mobile nitrogen exchange fraction"),
        .root_mobile_phosphorus_exchange_fraction = try nextFloat(&tokens, "root mobile phosphorus exchange fraction"),
        .exchange_rate_per_h = try nextFloat(&tokens, "root exudation exchange rate per h"),
    };
    try requireRunscriptRecordEnd(&tokens, "root_exudation");
    try root_exudation_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("root_porosity record"));
    try requireRunscriptRecordTag(&tokens, "root_porosity", error.MissingRootPorosityRecord);
    const root_porosity_parameters: plant_root_porosity.Parameters = .{
        .maximum_porosity_fraction = try nextFloat(&tokens, "maximum root porosity fraction"),
        .oxygen_stress_induction_fraction_per_h = try nextFloat(&tokens, "root porosity oxygen-stress induction fraction per h"),
        .relaxation_fraction_per_h = try nextFloat(&tokens, "root porosity relaxation fraction per h"),
    };
    try requireRunscriptRecordEnd(&tokens, "root_porosity");
    try root_porosity_parameters.validate();
    tokens = delimited_input.recordTokens(try records.next("root_metabolism record"));
    try requireRunscriptRecordTag(&tokens, "root_metabolism", error.MissingRootMetabolismRecord);
    const root_metabolism_parameters: plant_root_metabolism.SecondaryRootParameters = .{
        .maximum_substrate_respiration_fraction_per_h = try nextFloat(&tokens, "maximum root substrate respiration fraction per h"),
        .substrate_respiration_half_saturation_g_c_per_g_c = try nextFloat(&tokens, "root substrate respiration half saturation in g C g-1 C"),
        .nitrogen_feedback_half_saturation_g_n_per_g_c = try nextFloat(&tokens, "root nitrogen feedback half saturation in g N g-1 C"),
        .phosphorus_feedback_half_saturation_g_p_per_g_c = try nextFloat(&tokens, "root phosphorus feedback half saturation in g P g-1 C"),
        .maintenance_respiration_g_c_per_g_n_h = try nextFloat(&tokens, "root maintenance respiration in g C g-1 N h-1"),
        .nitrogen_assimilation_respiration_g_c_per_g_n = try nextFloat(&tokens, "nitrogen assimilation respiration in g C g-1 N"),
        .minimum_carbon_recycling_fraction = try nextFloat(&tokens, "minimum root carbon recycling fraction"),
        .responsive_carbon_recycling_fraction = try nextFloat(&tokens, "responsive root carbon recycling fraction"),
        .maximum_nitrogen_recycling_fraction = try nextFloat(&tokens, "maximum root nitrogen recycling fraction"),
        .maximum_phosphorus_recycling_fraction = try nextFloat(&tokens, "maximum root phosphorus recycling fraction"),
        .storage_exchange_fraction_per_h = try nextFloat(&tokens, "root storage exchange fraction per h"),
        .nonwoody_root_fraction_exponent = try nextFloat(&tokens, "nonwoody root fraction exponent"),
        .maintenance_gas_constant_j_per_mol_k = try nextFloat(&tokens, "root maintenance gas constant in J mol-1 K-1"),
        .maintenance_enthalpy_j_per_mol_k = try nextFloat(&tokens, "root maintenance enthalpy coefficient in J mol-1 K-1"),
        .maintenance_activation_energy_j_per_mol = try nextFloat(&tokens, "root maintenance activation energy in J mol-1"),
        .maintenance_low_temperature_inactivation_energy_j_per_mol = try nextFloat(&tokens, "root maintenance low-temperature inactivation energy in J mol-1"),
        .maintenance_normalization_log_intercept = try nextFloat(&tokens, "root maintenance normalization log intercept"),
        .maximum_maintenance_temperature_response = try nextFloat(&tokens, "maximum root maintenance temperature response"),
        .shallow_root_water_response_per_megapascal = try nextFloat(&tokens, "shallow-root water response per MPa"),
        .deep_root_water_response_per_megapascal = try nextFloat(&tokens, "deep-root water response per MPa"),
        .maintenance_water_response_exponent = try nextFloat(&tokens, "root maintenance water response exponent"),
        .root_penetration_reference_radius_m = try nextFloat(&tokens, "root penetration reference radius in m"),
        .acidity_half_effect_hydrogen_activity_mol_per_m3 = try nextFloat(&tokens, "root acidity half-effect hydrogen activity in mol m-3"),
        .maximum_acidity_enhancement = try nextFloat(&tokens, "maximum root acidity enhancement"),
        .shallow_primary_root_sink_multiplier = try nextFloat(&tokens, "shallow primary-root sink multiplier"),
        .intermediate_primary_root_sink_multiplier = try nextFloat(&tokens, "intermediate primary-root sink multiplier"),
        .deep_primary_root_sink_multiplier = try nextFloat(&tokens, "deep primary-root sink multiplier"),
        .deeper_primary_root_sink_multiplier = try nextFloat(&tokens, "deeper primary-root sink multiplier"),
        .annual_termination_hours_without_grain_fill = try nextFloat(&tokens, "annual termination hours without grain fill"),
        .root_protein_carbon_per_nitrogen_g_c_per_g_n = try nextFloat(&tokens, "root protein carbon per nitrogen in g C g-1 N"),
        .root_protein_carbon_per_phosphorus_g_c_per_g_p = try nextFloat(&tokens, "root protein carbon per phosphorus in g C g-1 P"),
        .nutrient_uptake_respiration_g_c_per_g_element = try nextFloat(&tokens, "root nutrient uptake respiration in g C g-1 element"),
        .evergreen_leafoff_remobilization_start_fraction = try nextFloat(&tokens, "evergreen leafoff remobilization start fraction"),
        .deciduous_leafoff_remobilization_start_fraction = try nextFloat(&tokens, "deciduous leafoff remobilization start fraction"),
        .full_senescence_duration_h = try nextFloat(&tokens, "full root senescence duration in h"),
    };
    try requireRunscriptRecordEnd(&tokens, "root_metabolism");
    try root_metabolism_parameters.validate();
    return .{
        .root_gas_parameters = root_gas_parameters,
        .root_nutrient_parameters = root_nutrient_parameters,
        .root_salt_parameters = root_salt_parameters,
        .root_mycorrhizal_exchange_parameters = root_mycorrhizal_exchange_parameters,
        .root_exudation_parameters = root_exudation_parameters,
        .root_porosity_parameters = root_porosity_parameters,
        .root_metabolism_parameters = root_metabolism_parameters,
    };
}

const HeaderRuntimeRecords = struct {
    domain: Domain,
    geospatial_bounds: ?spatial_grid.BoundsDegrees,
    tile_row_count: usize,
    tile_column_count: usize,
    lateral_flow_halo_cell_count: usize,
    plant_species_count: usize,
    worker_count: usize,
    tile_cell_count: usize,
    relative_tolerance: f64,
    absolute_tolerance: f64,
    nonlinear_tolerance: core_config.NonlinearTolerance,
    mass_balance_tolerance: f64,
    negligible_quantity_threshold: f64,
    mass_balance_relative_tolerance: f64,
    mass_balance_absolute_tolerance: core_config.MassBalanceAbsoluteTolerance,
    physical_tolerance: core_config.PhysicalTolerance,
    max_nonlinear_iterations: u16,
    picard_relaxation: f64,
};

noinline fn parseHeaderRuntimeRecords(
    allocator: std.mem.Allocator,
    records: *RunscriptRecordCursor,
) !HeaderRuntimeRecords {
    var header_tokens = delimited_input.recordTokens(try records.next("domain header"));
    const horizontal_cell_count = try nextRecordUnsigned(&header_tokens);
    const vertical_cell_count = try nextRecordUnsigned(&header_tokens);
    const plant_species_count = try nextRecordUnsigned(&header_tokens);
    try requireRunscriptRecordEnd(&header_tokens, "domain header");
    var domain: Domain = .{
        .west_column = 1,
        .north_row = 1,
        .east_column = horizontal_cell_count,
        .south_row = vertical_cell_count,
    };
    if (plant_species_count == 0) return error.NoPlantSpecies;
    _ = try domain.columns();
    _ = try domain.rows();

    var geospatial_tokens = delimited_input.recordTokens(try records.next("geospatial_grid record"));
    try requireRunscriptRecordTag(&geospatial_tokens, "geospatial_grid", error.MissingGeospatialGridRecord);
    const geospatial_bounds: ?spatial_grid.BoundsDegrees = .{
        .minimum_latitude_degrees_north = try nextRecordFloat(&geospatial_tokens),
        .maximum_latitude_degrees_north = try nextRecordFloat(&geospatial_tokens),
        .minimum_longitude_degrees_east = try nextRecordFloat(&geospatial_tokens),
        .maximum_longitude_degrees_east = try nextRecordFloat(&geospatial_tokens),
        .latitude_interval_degrees = try nextRecordFloat(&geospatial_tokens),
        .longitude_interval_degrees = try nextRecordFloat(&geospatial_tokens),
    };
    try requireRunscriptRecordEnd(&geospatial_tokens, "geospatial_grid");

    var tile_tokens = delimited_input.recordTokens(try records.next("tile_layout record"));
    try requireRunscriptRecordTag(&tile_tokens, "tile_layout", error.MissingTileLayoutRecord);
    const tile_row_count = try nextRecordUnsigned(&tile_tokens);
    const tile_column_count = try nextRecordUnsigned(&tile_tokens);
    const lateral_flow_halo_cell_count = try nextRecordUnsigned(&tile_tokens);
    try requireRunscriptRecordEnd(&tile_tokens, "tile_layout");
    if (tile_row_count == 0 or tile_column_count == 0 or lateral_flow_halo_cell_count != 2)
        return error.InvalidTileLayout;
    if (geospatial_bounds) |bounds| {
        var inferred_grid = try spatial_grid.RegularGrid.init(allocator, bounds);
        defer inferred_grid.deinit();
        domain = .{
            .west_column = 1,
            .north_row = 1,
            .east_column = inferred_grid.column_count,
            .south_row = inferred_grid.row_count,
        };
    }
    var runtime_tokens = delimited_input.recordTokens(try records.next("runtime record"));
    try requireRunscriptRecordTag(&runtime_tokens, "runtime", error.MissingRuntimeRecord);
    const worker_count = try nextRecordUnsigned(&runtime_tokens);
    const tile_cell_count = try nextRecordUnsigned(&runtime_tokens);
    const relative_tolerance = try nextRecordFloat(&runtime_tokens);
    const absolute_tolerance = try nextRecordFloat(&runtime_tokens);
    const max_nonlinear_iterations = try nextRecordUnsignedType(u16, &runtime_tokens);
    const picard_relaxation = try nextRecordFloat(&runtime_tokens);
    // Optional trailing fields preserve the old scalar slot for parsing, but
    // never apply it across unlike physical units. If no explicit conservation
    // relative tolerance follows, that legacy number migrates to a
    // dimensionless relative floor. Eight further optional values are explicit
    // per-domain physical floors (water, heat, O, C, N, P, ions, H).
    const mass_balance_tolerance = try optionalRecordFloat(&runtime_tokens, 0);
    const negligible_quantity_threshold = try optionalRecordFloat(&runtime_tokens, absolute_tolerance);
    const explicit_mass_balance_relative_tolerance = try optionalRecordFloatMaybe(&runtime_tokens);
    const mass_balance_relative_tolerance = explicit_mass_balance_relative_tolerance orelse
        @max(core_config.default_mass_balance_relative_tolerance, mass_balance_tolerance);
    const mass_balance_absolute_tolerance: core_config.MassBalanceAbsoluteTolerance = .{
        .water_m = try optionalRecordFloat(&runtime_tokens, 0),
        .heat_megajoules_m2 = try optionalRecordFloat(&runtime_tokens, 0),
        .oxygen_g_m2 = try optionalRecordFloat(&runtime_tokens, 0),
        .carbon_g_m2 = try optionalRecordFloat(&runtime_tokens, 0),
        .nitrogen_g_m2 = try optionalRecordFloat(&runtime_tokens, 0),
        .phosphorus_g_m2 = try optionalRecordFloat(&runtime_tokens, 0),
        .ions_mol_m2 = try optionalRecordFloat(&runtime_tokens, 0),
        .hydrogen_g_m2 = try optionalRecordFloat(&runtime_tokens, 0),
    };
    // Optional typed physical floors follow the legacy/conservation fields so
    // every existing runtime record remains valid without reordering. The old
    // negligible scalar is still parsed for compatibility, but is not copied
    // across unlike units.
    const default_physical_tolerance: core_config.PhysicalTolerance = .{};
    const physical_tolerance: core_config.PhysicalTolerance = .{
        .relative = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.relative),
        .water_volume_m3 = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.water_volume_m3),
        .water_depth_m = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.water_depth_m),
        .heat_megajoules = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.heat_megajoules),
        .temperature_k = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.temperature_k),
        .carbon_g = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.carbon_g),
        .nitrogen_g = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.nitrogen_g),
        .phosphorus_g = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.phosphorus_g),
        .oxygen_g = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.oxygen_g),
        .amount_mol = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.amount_mol),
        .length_m = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.length_m),
        .area_m2 = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.area_m2),
        .soil_mass_megagrams = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.soil_mass_megagrams),
        .dimensionless = try optionalRecordFloat(&runtime_tokens, default_physical_tolerance.dimensionless),
    };
    const migrated_nonlinear_tolerance = core_config.NonlinearTolerance.fromLegacy(relative_tolerance, absolute_tolerance);
    const nonlinear_tolerance: core_config.NonlinearTolerance = .{
        .relative = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.relative),
        .water_volume_m3 = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.water_volume_m3),
        .water_depth_m = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.water_depth_m),
        .heat_megajoules = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.heat_megajoules),
        .temperature_k = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.temperature_k),
        .carbon_g = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.carbon_g),
        .nitrogen_g = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.nitrogen_g),
        .phosphorus_g = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.phosphorus_g),
        .oxygen_g = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.oxygen_g),
        .amount_mol = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.amount_mol),
        .length_m = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.length_m),
        .area_m2 = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.area_m2),
        .soil_mass_megagrams = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.soil_mass_megagrams),
        .dimensionless = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.dimensionless),
        // Appended after every pre-existing runtime field so old runscript
        // records keep their positional meaning.
        .reaction_mol_per_m3 = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.reaction_mol_per_m3),
        .reaction_mol_per_megagram = try optionalRecordFloat(&runtime_tokens, migrated_nonlinear_tolerance.reaction_mol_per_megagram),
    };
    try requireRunscriptRecordEnd(&runtime_tokens, "runtime");
    if (worker_count == 0 or tile_cell_count == 0 or max_nonlinear_iterations == 0 or !std.math.isFinite(picard_relaxation) or picard_relaxation <= 0 or picard_relaxation > 1) return error.InvalidRuntimeControls;
    if (!std.math.isFinite(relative_tolerance) or relative_tolerance <= 0.0 or
        !std.math.isFinite(absolute_tolerance) or absolute_tolerance <= 0.0) return error.InvalidRuntimeControls;
    if (!std.math.isFinite(mass_balance_tolerance) or mass_balance_tolerance < 0.0 or
        !std.math.isFinite(negligible_quantity_threshold) or negligible_quantity_threshold <= 0.0 or
        !std.math.isFinite(mass_balance_relative_tolerance) or mass_balance_relative_tolerance <= 0.0) return error.InvalidRuntimeControls;
    mass_balance_absolute_tolerance.validate() catch return error.InvalidRuntimeControls;
    physical_tolerance.validate() catch return error.InvalidRuntimeControls;
    nonlinear_tolerance.validate() catch return error.InvalidRuntimeControls;
    return .{
        .domain = domain,
        .geospatial_bounds = geospatial_bounds,
        .tile_row_count = tile_row_count,
        .tile_column_count = tile_column_count,
        .lateral_flow_halo_cell_count = lateral_flow_halo_cell_count,
        .plant_species_count = plant_species_count,
        .worker_count = worker_count,
        .tile_cell_count = tile_cell_count,
        .relative_tolerance = relative_tolerance,
        .absolute_tolerance = absolute_tolerance,
        .nonlinear_tolerance = nonlinear_tolerance,
        .mass_balance_tolerance = mass_balance_tolerance,
        .negligible_quantity_threshold = negligible_quantity_threshold,
        .mass_balance_relative_tolerance = mass_balance_relative_tolerance,
        .mass_balance_absolute_tolerance = mass_balance_absolute_tolerance,
        .physical_tolerance = physical_tolerance,
        .max_nonlinear_iterations = max_nonlinear_iterations,
        .picard_relaxation = picard_relaxation,
    };
}

noinline fn parseSoilPhaseHeatParameters(tokens: *delimited_input.TokenIterator) !soil_process_science.RuntimeParameters {
    const result: soil_process_science.RuntimeParameters = .{
        .vapor_equilibrium = .{
            .vapor_density_temperature_coefficient = try nextFloat(tokens, "vapor density temperature coefficient"),
            .molecular_weight_ratio = try nextFloat(tokens, "vapor molecular-weight ratio"),
            .clausius_clapeyron_coefficient_k = try nextFloat(tokens, "Clausius-Clapeyron coefficient in K"),
            .reference_inverse_temperature_per_k = try nextFloat(tokens, "reference inverse temperature per K"),
            .water_molar_mass_g_per_mol = try nextFloat(tokens, "water molar mass in g mol-1"),
            .gas_constant_j_per_mol_k = try nextFloat(tokens, "gas constant in J mol-1 K-1"),
            .latent_heat_of_vaporization_megajoules_per_m3 = try nextFloat(tokens, "latent heat of vaporization in MJ m-3"),
        },
        .freeze_thaw = .{
            .freezing_potential_numerator_k_megapascal = try nextFloat(tokens, "freezing potential numerator in K MPa"),
            .latent_heat_of_fusion_megajoules_per_m3 = try nextFloat(tokens, "latent heat of fusion in MJ m-3"),
            .ice_density_megagrams_per_m3 = try nextFloat(tokens, "ice density in Mg m-3"),
            .heat_capacity_temperature_feedback_per_k = try nextFloat(tokens, "heat-capacity temperature feedback per K"),
            .pure_water_freezing_temperature_k = try nextFloat(tokens, "pure-water freezing temperature in K"),
        },
        .heat_turbulence = .{
            .water_fraction_threshold = try nextFloat(tokens, "water convection threshold"),
            .air_fraction_threshold = try nextFloat(tokens, "air convection threshold"),
            .water_rayleigh_coefficient = try nextFloat(tokens, "water Rayleigh coefficient"),
            .air_rayleigh_coefficient = try nextFloat(tokens, "air Rayleigh coefficient"),
            .water_nusselt_denominator = try nextFloat(tokens, "water Nusselt denominator"),
            .air_nusselt_denominator = try nextFloat(tokens, "air Nusselt denominator"),
            .maximum_rayleigh_number = try nextFloat(tokens, "maximum Rayleigh number"),
        },
        .liquid_water_heat_capacity_megajoules_per_m3_k = try nextFloat(tokens, "liquid-water heat capacity in MJ m-3 K-1"),
        .ice_heat_capacity_megajoules_per_m3_k = try nextFloat(tokens, "ice heat capacity in MJ m-3 K-1"),
    };
    try soil_process_science.validate(result);
    return result;
}

noinline fn parseSoilSolverParameters(tokens: *delimited_input.TokenIterator, hard_max_iterations: u16) !soil_solver_properties.RuntimeParameters {
    const result: soil_solver_properties.RuntimeParameters = .{
        .retention = .{
            .saturation_water_potential_megapascal = try nextFloat(tokens, "saturation water potential in MPa"),
            .minimum_water_potential_megapascal = try nextFloat(tokens, "minimum water potential in MPa"),
            .organic_soil_threshold_g_per_megagram = try nextFloat(tokens, "organic soil threshold in g Mg-1"),
            .mineral_field_capacity_intercept = try nextFloat(tokens, "mineral field-capacity intercept"),
            .mineral_field_capacity_sand_coefficient = try nextFloat(tokens, "mineral field-capacity sand coefficient"),
            .mineral_field_capacity_clay_coefficient = try nextFloat(tokens, "mineral field-capacity clay coefficient"),
            .mineral_field_capacity_organic_coefficient_per_g_per_megagram = try nextFloat(tokens, "mineral field-capacity organic coefficient per g Mg-1"),
            .mineral_wilting_point_intercept = try nextFloat(tokens, "mineral wilting-point intercept"),
            .mineral_wilting_point_clay_coefficient = try nextFloat(tokens, "mineral wilting-point clay coefficient"),
            .mineral_wilting_point_organic_coefficient_per_g_per_megagram = try nextFloat(tokens, "mineral wilting-point organic coefficient per g Mg-1"),
            .organic_bulk_density_threshold_1_megagrams_per_m3 = try nextFloat(tokens, "first organic bulk-density threshold in Mg m-3"),
            .organic_bulk_density_threshold_2_megagrams_per_m3 = try nextFloat(tokens, "second organic bulk-density threshold in Mg m-3"),
            .organic_field_capacity_1 = try nextFloat(tokens, "first organic field capacity"),
            .organic_field_capacity_2 = try nextFloat(tokens, "second organic field capacity"),
            .organic_field_capacity_3 = try nextFloat(tokens, "third organic field capacity"),
            .organic_wilting_point_1 = try nextFloat(tokens, "first organic wilting point"),
            .organic_wilting_point_2 = try nextFloat(tokens, "second organic wilting point"),
            .organic_wilting_point_3 = try nextFloat(tokens, "third organic wilting point"),
            .maximum_field_capacity_fraction_of_porosity = try nextFloat(tokens, "maximum field-capacity fraction of porosity"),
            .maximum_wilting_point_fraction_of_field_capacity = try nextFloat(tokens, "maximum wilting-point fraction of field capacity"),
            .saturation_to_field_shape = try nextFloat(tokens, "saturation-to-field retention shape"),
            .below_wilting_shape = try nextFloat(tokens, "below-wilting retention shape"),
        },
        // Initialization is nonlinear science too: the user runtime ceiling is
        // a hard upper bound, even when the historical fit budget was larger.
        .mualem_van_genuchten_fit_max_iterations = @min(@as(usize, 80), @as(usize, hard_max_iterations)),
        .hydraulic_conductivity_class_count = try nextUnsigned(tokens, "hydraulic conductivity class count"),
        .pore_interaction_exponent = try nextFloat(tokens, "hydraulic pore-interaction exponent"),
        .air_entry_fraction_of_vertical_saturated_conductivity = try nextFloat(tokens, "air-entry conductivity fraction"),
        .mineral_saturated_conductivity_scale_m2_per_h_megapascal = try nextFloat(tokens, "mineral saturated-conductivity scale in m2 h-1 MPa-1"),
        .mineral_reference_water_potential_mpa_magnitude = try nextFloat(tokens, "mineral conductivity reference water-potential magnitude in MPa"),
        .organic_saturated_conductivity_intercept_m2_per_h_megapascal = try nextFloat(tokens, "organic saturated-conductivity intercept in m2 h-1 MPa-1"),
        .organic_saturated_conductivity_scale_m2_per_h_megapascal = try nextFloat(tokens, "organic saturated-conductivity scale in m2 h-1 MPa-1"),
        .organic_saturated_conductivity_bulk_density_base = try nextFloat(tokens, "organic saturated-conductivity bulk-density base"),
        .profile_derivation = .{
            .particulate_carbon_fraction = try nextFloat(tokens, "missing particulate-carbon fraction"),
            .organic_nitrogen_maximum_fraction_of_carbon = try nextFloat(tokens, "maximum organic-nitrogen fraction of carbon"),
            .organic_nitrogen_scale_g_per_megagram = try nextFloat(tokens, "organic-nitrogen derivation scale in g Mg-1"),
            .organic_nitrogen_reference_carbon_g_per_megagram = try nextFloat(tokens, "organic-nitrogen reference carbon in g Mg-1"),
            .organic_nitrogen_exponent = try nextFloat(tokens, "organic-nitrogen derivation exponent"),
            .organic_phosphorus_maximum_fraction_of_carbon = try nextFloat(tokens, "maximum organic-phosphorus fraction of carbon"),
            .organic_phosphorus_scale_g_per_megagram = try nextFloat(tokens, "organic-phosphorus derivation scale in g Mg-1"),
            .organic_phosphorus_reference_carbon_g_per_megagram = try nextFloat(tokens, "organic-phosphorus reference carbon in g Mg-1"),
            .organic_phosphorus_exponent = try nextFloat(tokens, "organic-phosphorus derivation exponent"),
            .cec_conversion_mol_per_megagram_per_cmol_per_kg = try nextFloat(tokens, "CEC conversion from cmol kg-1 to mol Mg-1"),
            .organic_matter_per_carbon = try nextFloat(tokens, "organic-matter to organic-carbon ratio"),
            .organic_matter_cec_cmol_per_kg = try nextFloat(tokens, "organic-matter CEC in cmol kg-1"),
            .clay_cec_cmol_per_kg = try nextFloat(tokens, "clay CEC in cmol kg-1"),
            .silt_cec_cmol_per_kg = try nextFloat(tokens, "silt CEC in cmol kg-1"),
            .sand_cec_cmol_per_kg = try nextFloat(tokens, "sand CEC in cmol kg-1"),
            .minimum_ammonium_g_per_megagram = try nextFloat(tokens, "minimum initial ammonium in g Mg-1"),
            .minimum_calcium_g_per_megagram = try nextFloat(tokens, "minimum initial calcium in g Mg-1"),
        },
    };
    try result.retention.validate();
    try result.profile_derivation.validate();
    if (result.mualem_van_genuchten_fit_max_iterations == 0 or result.hydraulic_conductivity_class_count == 0 or !std.math.isFinite(result.pore_interaction_exponent) or result.pore_interaction_exponent <= 0 or !std.math.isFinite(result.air_entry_fraction_of_vertical_saturated_conductivity) or result.air_entry_fraction_of_vertical_saturated_conductivity < 0 or result.air_entry_fraction_of_vertical_saturated_conductivity > 1 or !std.math.isFinite(result.mineral_saturated_conductivity_scale_m2_per_h_megapascal) or result.mineral_saturated_conductivity_scale_m2_per_h_megapascal < 0 or !std.math.isFinite(result.mineral_reference_water_potential_mpa_magnitude) or result.mineral_reference_water_potential_mpa_magnitude <= 0 or !std.math.isFinite(result.organic_saturated_conductivity_intercept_m2_per_h_megapascal) or result.organic_saturated_conductivity_intercept_m2_per_h_megapascal < 0 or !std.math.isFinite(result.organic_saturated_conductivity_scale_m2_per_h_megapascal) or result.organic_saturated_conductivity_scale_m2_per_h_megapascal < 0 or !std.math.isFinite(result.organic_saturated_conductivity_bulk_density_base) or result.organic_saturated_conductivity_bulk_density_base <= 0) return error.InvalidSoilSolverRuntimeParameters;
    return result;
}

fn parseSceneRecords(allocator: std.mem.Allocator, records: *RunscriptRecordCursor) !SceneFiles {
    var scene: SceneFiles = undefined;
    var allocated: usize = 0;
    errdefer {
        if (allocated >= 1) allocator.free(scene.weather_grid_file);
        if (allocated >= 2) allocator.free(scene.options);
        if (allocated >= 3) allocator.free(scene.land_management);
        if (allocated >= 4) allocator.free(scene.plant_management);
        var index: usize = 0;
        while (index + 4 < allocated) : (index += 1) allocator.free(scene.output_editors[index]);
    }
    var weather_tokens = delimited_input.recordTokens(try records.next("weather_grid record"));
    try requireRunscriptRecordTag(&weather_tokens, "weather_grid", error.MissingWeatherGridRecord);
    scene.weather_grid_file = try duplicateRequiredRecordString(allocator, &weather_tokens);
    allocated += 1;
    try requireRunscriptRecordEnd(&weather_tokens, "weather_grid");
    scene.options = try duplicateSingletonRecord(allocator, records, "options filename");
    allocated += 1;
    scene.land_management = try duplicateSingletonRecord(allocator, records, "land-management filename");
    allocated += 1;
    scene.plant_management = try duplicateSingletonRecord(allocator, records, "plant-management filename");
    allocated += 1;
    for (&scene.output_editors) |*name| {
        name.* = try duplicateSingletonRecord(allocator, records, "output-editor filename");
        allocated += 1;
    }
    return scene;
}

noinline fn duplicateSingletonRecord(allocator: std.mem.Allocator, records: *RunscriptRecordCursor, name: []const u8) ![]u8 {
    var fields = delimited_input.recordTokens(try records.next(name));
    const value = try duplicateRequiredRecordString(allocator, &fields);
    errdefer allocator.free(value);
    try requireRunscriptRecordEnd(&fields, name);
    return value;
}

fn duplicateRequiredRecordString(allocator: std.mem.Allocator, fields: *delimited_input.TokenIterator) ![]u8 {
    const value = fields.next() orelse return error.ShortRunscriptRecord;
    if (value.len == 0) return error.EmptyRunscriptRecordValue;
    return allocator.dupe(u8, value);
}

/// Consumes a leading `tag,value` record when present, returning a duplicate
/// of `value`. When the next record is not tagged `tag`, the cursor is left
/// untouched and a duplicate of `fallback` is returned instead. This keeps
/// `input_root`/`output_root` backward compatible: runscripts written before
/// these records existed parse unchanged.
fn duplicateOptionalTaggedRecord(
    allocator: std.mem.Allocator,
    records: *RunscriptRecordCursor,
    tag: []const u8,
    fallback: []const u8,
) ![]u8 {
    const record = records.nextIfTagged(tag) orelse return allocator.dupe(u8, fallback);
    var fields = delimited_input.recordTokens(record);
    _ = fields.next(); // the tag itself, already matched by nextIfTagged
    const value = try duplicateRequiredRecordString(allocator, &fields);
    errdefer allocator.free(value);
    try requireRunscriptRecordEnd(&fields, tag);
    return value;
}

fn freeScene(allocator: std.mem.Allocator, scene: SceneFiles) void {
    allocator.free(scene.weather_grid_file);
    allocator.free(scene.options);
    allocator.free(scene.land_management);
    allocator.free(scene.plant_management);
    for (scene.output_editors) |name| allocator.free(name);
}

noinline fn next(tokens: *delimited_input.TokenIterator, field: []const u8) ![]const u8 {
    return tokens.next() orelse {
        std.log.warn("runscript ended while reading {s}", .{field});
        return error.UnexpectedEndOfRunscript;
    };
}

const RunscriptRecordCursor = struct {
    source: []const u8,
    offset: usize = 0,

    noinline fn next(self: *RunscriptRecordCursor, record_name: []const u8) ![]const u8 {
        while (self.offset < self.source.len) {
            const start = self.offset;
            const line_end = std.mem.indexOfScalarPos(u8, self.source, start, '\n') orelse self.source.len;
            self.offset = if (line_end < self.source.len) line_end + 1 else line_end;
            const record = self.source[start..line_end];
            var fields = delimited_input.recordTokens(record);
            if (fields.next() != null) return record;
        }
        std.log.err("runscript ended while reading {s}", .{record_name});
        return error.UnexpectedEndOfRunscript;
    }

    fn remaining(self: RunscriptRecordCursor) []const u8 {
        return self.source[self.offset..];
    }

    fn nextOptional(self: *RunscriptRecordCursor) ?[]const u8 {
        while (self.offset < self.source.len) {
            const start = self.offset;
            const line_end = std.mem.indexOfScalarPos(u8, self.source, start, '\n') orelse self.source.len;
            self.offset = if (line_end < self.source.len) line_end + 1 else line_end;
            const record = self.source[start..line_end];
            var fields = delimited_input.recordTokens(record);
            if (fields.next() != null) return record;
        }
        return null;
    }

    /// Consumes and returns the next non-blank record only when its first
    /// token case-insensitively matches `tag`; otherwise restores the cursor
    /// to its pre-call position and returns null. This lets a leading record
    /// stay optional without a general peek/rewind mechanism: the record is
    /// tentatively consumed, inspected, and un-consumed on mismatch.
    fn nextIfTagged(self: *RunscriptRecordCursor, tag: []const u8) ?[]const u8 {
        const saved_offset = self.offset;
        while (self.offset < self.source.len) {
            const start = self.offset;
            const line_end = std.mem.indexOfScalarPos(u8, self.source, start, '\n') orelse self.source.len;
            const next_offset = if (line_end < self.source.len) line_end + 1 else line_end;
            const record = self.source[start..line_end];
            var fields = delimited_input.recordTokens(record);
            const first = fields.next() orelse {
                self.offset = next_offset;
                continue;
            };
            if (std.ascii.eqlIgnoreCase(first, tag)) {
                self.offset = next_offset;
                return record;
            }
            self.offset = saved_offset;
            return null;
        }
        self.offset = saved_offset;
        return null;
    }
};

fn requireRunscriptRecordTag(
    fields: *delimited_input.TokenIterator,
    expected: []const u8,
    missing_error: anyerror,
) !void {
    const actual = fields.next() orelse return error.ShortRunscriptRecord;
    if (!std.ascii.eqlIgnoreCase(actual, expected)) return missing_error;
}

fn requireRunscriptRecordEnd(
    fields: *delimited_input.TokenIterator,
    record_name: []const u8,
) !void {
    if (fields.next()) |trailing| {
        std.log.warn("extra value in {s} record: '{s}'", .{ record_name, trailing });
        return error.LongRunscriptRecord;
    }
}

fn nextRecordUnsigned(fields: *delimited_input.TokenIterator) !usize {
    const token = fields.next() orelse return error.ShortRunscriptRecord;
    return std.fmt.parseUnsigned(usize, token, 10) catch error.InvalidRunscriptInteger;
}

fn nextRecordUnsignedType(comptime T: type, fields: *delimited_input.TokenIterator) !T {
    const token = fields.next() orelse return error.ShortRunscriptRecord;
    return std.fmt.parseUnsigned(T, token, 10) catch error.InvalidRunscriptInteger;
}

fn nextRecordFloat(fields: *delimited_input.TokenIterator) !f64 {
    const token = fields.next() orelse return error.ShortRunscriptRecord;
    return std.fmt.parseFloat(f64, token) catch error.InvalidRunscriptFloat;
}

/// Reads an optional trailing float, yielding `fallback` when the record ends.
/// Lets a record grow new fields without invalidating existing runscripts.
/// A trailing token that is not a float means the record ran past its end
/// (usually two records joined by a missing newline), so it is reported as
/// `LongRunscriptRecord` rather than as a malformed number.
fn optionalRecordFloat(fields: *delimited_input.TokenIterator, fallback: f64) !f64 {
    return (try optionalRecordFloatMaybe(fields)) orelse fallback;
}

fn optionalRecordFloatMaybe(fields: *delimited_input.TokenIterator) !?f64 {
    const token = fields.next() orelse return null;
    return std.fmt.parseFloat(f64, token) catch {
        std.log.warn("unparseable trailing value in runtime record: '{s}'", .{token});
        return error.LongRunscriptRecord;
    };
}

fn nextRecordBool(fields: *delimited_input.TokenIterator) !bool {
    const token = fields.next() orelse return error.ShortRunscriptRecord;
    return delimited_input.parseYesNo(token) catch error.InvalidRunscriptBoolean;
}

fn validatePlantNutrientsRecordArity(body: []const u8) !void {
    var records = delimited_input.records(body);
    while (records.next()) |record| {
        var fields = delimited_input.recordTokens(record);
        const tag = fields.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(tag, "plant_nutrients")) continue;
        var value_count: usize = 0;
        while (fields.next() != null) value_count += 1;
        if (value_count < 7) return error.ShortPlantNutrientsRecord;
        if (value_count > 7) return error.LongPlantNutrientsRecord;
    }
}

noinline fn nextUnsigned(tokens: *delimited_input.TokenIterator, field: []const u8) !usize {
    const token = try next(tokens, field);
    return std.fmt.parseUnsigned(usize, token, 10) catch {
        std.log.err("invalid unsigned integer for {s}: '{s}'", .{ field, token });
        return error.InvalidRunscriptInteger;
    };
}

noinline fn nextUnsignedType(comptime T: type, tokens: *delimited_input.TokenIterator, field: []const u8) !T {
    const token = try next(tokens, field);
    return std.fmt.parseUnsigned(T, token, 10) catch {
        std.log.err("invalid unsigned integer for {s}: '{s}'", .{ field, token });
        return error.InvalidRunscriptInteger;
    };
}

noinline fn nextFloat(tokens: *delimited_input.TokenIterator, field: []const u8) !f64 {
    const token = tokens.next() orelse {
        std.log.warn("runscript record ended while reading {s}", .{field});
        return error.ShortRunscriptRecord;
    };
    const value = std.fmt.parseFloat(f64, token) catch {
        std.log.warn("invalid floating-point value for {s}: '{s}'", .{ field, token });
        return error.InvalidRunscriptFloat;
    };
    return value;
}

noinline fn nextBool(tokens: *delimited_input.TokenIterator, field: []const u8) !bool {
    const token = try next(tokens, field);
    return delimited_input.parseYesNo(token) catch {
        std.log.err("invalid YES/NO value for {s}: '{s}'", .{ field, token });
        return error.InvalidRunscriptBoolean;
    };
}

fn rejectEmptyExplicitFields(body: []const u8) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| if (hasEmptyExplicitField(line))
        return error.EmptyRunscriptRecordValue;
}

fn hasEmptyExplicitField(line: []const u8) bool {
    const content = if (std.mem.indexOfScalar(u8, line, '#')) |comment|
        line[0..comment]
    else
        line;
    const trimmed = std.mem.trim(u8, content, " \r");
    if (trimmed.len == 0) return false;

    var field_start: usize = 0;
    var saw_explicit_delimiter = false;
    for (trimmed, 0..) |byte, index| {
        if (byte != ',' and byte != '|' and byte != '\t') continue;
        if (std.mem.trim(u8, trimmed[field_start..index], " \r").len == 0)
            return true;
        field_start = index + 1;
        saw_explicit_delimiter = true;
    }
    return saw_explicit_delimiter and
        std.mem.trim(u8, trimmed[field_start..], " \r").len == 0;
}

fn extractInputBody(source: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var offset: usize = 0;
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (std.mem.indexOf(u8, line, "<<") != null) {
            const marker_start = std.mem.indexOf(u8, line, "<<").? + 2;
            const marker_tail = std.mem.trim(u8, line[marker_start..], " \t\r");
            var marker_tokens = std.mem.tokenizeAny(u8, marker_tail, " \t\r");
            const marker = marker_tokens.next() orelse return source;
            const body_start = @min(offset + line_with_cr.len + 1, source.len);
            var body_lines = std.mem.splitScalar(u8, source[body_start..], '\n');
            var body_length: usize = 0;
            while (body_lines.next()) |body_line_with_cr| {
                const body_line = std.mem.trim(u8, body_line_with_cr, " \t\r");
                if (std.mem.eql(u8, body_line, marker)) return source[body_start .. body_start + body_length];
                body_length += body_line_with_cr.len + 1;
            }
            return source[body_start..];
        }
        offset += line_with_cr.len + 1;
    }
    return source;
}

const strict_parameter_fixture_records =
    \\geospatial_grid,45,46,-80,-79,1,1
    \\tile_layout,1,1,2
    \\runtime,1,1,1e-9,1e-12,40,0.5
    \\soil_solver,-0.0005,-1.5e12,250000,0.2576,-0.20,0.36,0.60e-6,0.0260,0.50,0.32e-6,0.075,0.195,0.27,0.62,0.71,0.04,0.15,0.22,0.75,0.75,0.5,0.5,100,1.33,0.1,1.54,0.033,0.10,75,1e-15,0.067,0.125,890,10000,0.80,0.0125,120,10000,0.52,10,1.82,200,80,20,5,1,1
    \\soil_process,0.0098,8.96e-2,298.15,1.75,0.66,0.03,0.5e-3,1e-6,0.533,0.0267
    \\macropore_van_genuchten,0,15,2.68,0.5
    \\dual_domain_exchange,3,0.4
    \\frozen_hydraulic_impedance,7
    \\surface_residue_freeze_thaw,0,400,2.5
    \\soil_gas_transport,298.15,1.75,4.68e-2,7.80e-2,6.43e-2,5.57e-2,5.57e-2,6.67e-2,5.57e-2,0.66,1e-12,1e6,18
    \\soil_phase_heat,2.173e-3,0.61,5360,3.661e-3,18,8.3143,2450,9.0959e4,333,0.917,6.2913e-3,273.15,0.333,0.333,13990344827.5862,89223880597.0149,1.09495999584408,4.77823246449888,10000,4.19,1.9274
    \\geothermal,yes,10,1,8.1e-3,2.052e-4
    \\subsurface_state,1e-3,1e-6
    \\soil_geometry,1.82e-6,110000,0.083,1e-9
    \\surface_pond_energy,2.496e-6,0.838e-3
    \\surface_energy,0.97,0.97,0.97,0.07,0.43,0,1,173.15,373.15
    \\snow_layers,5,0.05,0.125,0.25,0.50,1.00,0.05,0.92,333,2.7185
    \\snow_compaction,0.25,1e-5,0.04,0.25,-0.08,23,-15,2,1.7e-3
    \\snow_thermal,0.0036,2.650,-1.652,0.6
    \\snow_vapor,2.173e-3,0.61,5360,3.661e-3,2465,2834
    \\snow_vapor_transport,8.96e-2,298.15,1.75,0,4.19
    \\surface_gas_resistance,-0.10,0.05,10,1e-6,1e6,2e-4,1e-6
    \\surface_runoff,0.005,0.011,1e-3,3600,1e-12
    \\rainfall_impact,8.95,8.44,15.8,5.87,2.5,2,1e-3,5e-4
    \\surface_aerodynamics,0.5,2,0.005,0.025,1.27e8,0.168,1e-12,0.00139,no
    \\ground_air,1.25e-3,5,1.25e-3,2465,2.173e-3,0.61,5360,3.661e-3
    \\canopy_surface_exchange,0.00139,0.0278,0.00139,0.0139,18,8.3143,4.19,0.00278,0.0278
    \\canopy_ammonia_exchange,0.16,0.10,0.05,2,1e-4,0.1,0.513,0.0171
    \\plant_structure,10
    \\canopy_layers,10
    \\canopy_geometry,4e-6
    \\canopy_discretization,4,4,4
    \\standing_dead_partition,0,0.045,0.660,0.295,0.020,0.010,0.010,0.020,0.0020,0.0010,0.0010,0.0020
    \\plant_initial_heat_water,273.15,2.173e-3,0.61,5360,3.661e-3,-1e-3
    \\plant_initial_geometry,5e-6,2,0.75,3.1416,0.33,4,1e-6,0.05,0.01,3.142
    \\plant_initial_phenology,0.005,1,24,10,15,3,4,5
    \\root_initialization,2.5,25,2.5e-6,-0.01,-0.01,1e-3,1
    \\root_morphology,1e-2,5
    \\standing_dead_energy,0.0025,2.496,0.97,0.838e-3,0.838e-4
    \\woody_optics,0.1,0.1,0.1,0.1
    \\canopy_retention,5e-4,2.5e-4,2.5e-4,2.5e-4,0.65,0.05
    \\shoot_controls,3600,1.56,2.10e5,3.96e5
    \\c4_carbon,1.2,4.8,0.083e9,0.025,1000,0.02,5e-7,5e6,0.5,3
    \\thermal_controls,3,2.5,1.25,5,12.5,15,35,27.5,30,2,0.002,0.005,0.010,0.002
    \\canopy_stress,24,60,0.02,8.3143,710,25.229,62500,197500,222500
    \\phenology_controls,8.3143,710,24.269,60000,197500,218500,0.1,0.25,2,0.667,-0.1,-150,-1.5,3600,1e-6,1e-6
    \\plant_pool_controls,no,1e-15,1e-6,1e-6,1e-6,1e-2,1e-3
    \\seed_set_controls,2.5e-2,0.5e-2,0.1e-2
    \\root_gas,298.15,8.57e-6,6,2.925e-2,0.31,0.516,0.0172,5.56e4,2.667,1e-6,0.5,-13.833,-0.857
    \\root_gas_transport,1.75,4.68e-2,7.80e-2,5.57e-2,6.67e-2,5.57e-2,6.43e-2,4.25e-6,7.08e-6,5.72e-6,4.00e-6,7.34e-6,8.57e-6,7.391e-1,3.156e-2,5.241e-1,2.852e2,3.156e-2,2.925e-2,0.14,0.14,0.23,0.07,0.14,0.31,0.843,0.597,0.897,0.513,0.597,0.516,0.0281,0.0199,0.0299,0.0171,0.0199,0.0172
    \\root_nutrients,298.15,4e-6,6e-6,3e-6,6,0.7,1,1,0.01,0.01,1e-4,31
    \\root_salts,298.15,4e-6,4e-6,4e-6,4e-6,4e-6,4e-6,4e-6,4e-6,6,1,1,1,1,1,1,1,1
    \\root_mycorrhizal_exchange,0.05,0.5
    \\root_exudation,1e3,0.1,0.1,1e-3
    \\root_porosity,0.75,0.1,0.01
    \\root_metabolism,0.015,0.025,0.1,0.01,0.010,1.70,0.167,0.333,0.667,0.667,2.5e-5,0.167,8.3143,710,62500,197500,25.216,1e3,0.05,0.10,0.25,1e-3,1,4,0.25,1,2,4,336,2.5,25,0.86,0.75,0.5,480
    \\organ_partition,0.75,0.25,0.0200,0.0500,0.0067,0.0167,0.75,1.50,2,2,1.75,1.50,0.25,0.50,0.67,0.67,0.58,0.50,0.10,0.10
    \\shoot_metabolism,0.015,0.025,0.010,0.333,1.70,0.025,0.1,0.01
    \\shoot_node_growth,2.5,25,-0.333,-0.50,-0.667,0.002,2,2,1e-3,5e-3,5e-2,0.75,0.005,0.001,72,23,360,1440,720,720,5e-3,5e-3,5e-6,5e-6,5e-5,5e-4
    \\seasonal_turnover,2.884e-3,240
    \\branch_mobile_exchange,0.01,0.01,0.05
    \\symbiotic_fixation,1e-4,0.125,0.010,0.25,0.1,0.01,1e-4,1e-5,10,1000,1e-2,0.167,0.333,0.333,0.333,0.20,0.10,0.05,0.20,0.10,0.05,0.50,0.25,0.125,0.050,0.025,0.0125
    \\plant_fire_combustion,473.15,2,8.3143,60000,12.028,1000,1000,1000,1000,2500,120000,20.620,1,2.667,0,0.5,2100,10,0.0375,0.0125,0.0743
    \\soil_fire_combustion,473.15,2,8.3143,60000,12.028,120000,20.620,1000,5000,1000,1000,1000,1000,1,2.667,0,0.5,2.8,0.005,0.0375,0.0125,0.0743
    \\shoot_root_exchange,0.05,0.005,0.25,1
    \\storage_remobilization,45.8,138.4,0.015,0.005,0.25,0.25,0.75,0.75,0.100,0.100,0.010,0.100,0.100,0.100,0.050,0.20,0.005,0.020,0.10
    \\plant_nutrients,0,0,0,1,1,1,1
    \\microbial_dimensions,6,7
    \\organic_initialization_file,organic-parameters
    \\surface_gas_parameter_file,surface-gas-parameters
    \\soil_nitrogen_parameter_file,soil-nitrogen-parameters
    \\chemistry_initialization,0.01,1e-8,1.9e-21,6.3e-26,7.5,6.2e-5,4.8e-10
    \\chemistry_units,14,31,27,56,40,24.3,23,39.1,32,35.5,1,1,0.01,1
    \\chemistry_reaction_file,chemistry-reaction-parameters
    \\fertilizer_units,14
;

// Test-only fixture support. Production parsing never synthesizes omitted
// science records; focused tests use this builder to exercise the strict grammar.
fn parseStrictParameterFixture(allocator: std.mem.Allocator, fragment: []const u8) !RunScript {
    return parseStrictParameterFixtureOmitting(allocator, fragment, null);
}

fn parseStrictParameterFixtureOmitting(
    allocator: std.mem.Allocator,
    fragment: []const u8,
    omitted_tag: ?[]const u8,
) !RunScript {
    const body = extractInputBody(fragment);
    const tail_start = strictFixtureTailStart(body) orelse return error.MissingGridInputsRecord;
    var assembled: std.ArrayList(u8) = .empty;
    defer assembled.deinit(allocator);

    const prefix = body[0..tail_start];
    var prefix_lines = std.mem.splitScalar(u8, prefix, '\n');
    var header_written = false;
    while (prefix_lines.next()) |line| {
        if (strictFixtureTag(line) != null) continue;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        try appendStrictFixtureLine(allocator, &assembled, line);
        header_written = true;
        break;
    }
    if (!header_written) return error.MissingRunscriptValue;

    var canonical_lines = std.mem.splitScalar(u8, strict_parameter_fixture_records, '\n');
    while (canonical_lines.next()) |canonical_line| {
        const canonical_tag = strictFixtureTag(canonical_line) orelse continue;
        if (omitted_tag) |tag| if (std.ascii.eqlIgnoreCase(canonical_tag, tag)) continue;
        try appendStrictFixtureLine(
            allocator,
            &assembled,
            strictFixtureRecord(prefix, canonical_tag) orelse canonical_line,
        );
    }
    const fixture_tail = body[tail_start..];
    if (strictFixtureTailUsesPhysicalSceneRecords(fixture_tail)) {
        try assembled.appendSlice(allocator, fixture_tail);
        return parse(allocator, assembled.items);
    }
    var tail_tokens = delimited_input.tokens(fixture_tail);
    const grid_tag = tail_tokens.next() orelse return error.MissingGridInputsRecord;
    const grid_file = tail_tokens.next() orelse return error.ShortRunscriptRecord;
    try assembled.appendSlice(allocator, grid_tag);
    try assembled.append(allocator, ',');
    try appendStrictFixtureLine(allocator, &assembled, grid_file);
    try assembled.appendSlice(
        allocator,
        "1,1\n1,1\nweather_grid,weather\noptions\nNO\nplants\no1\no2\no3\no4\no5\no6\no7\no8\no9\no10\n0,0\n",
    );
    if (strictFixtureRecord(body, "STOP") != null) try assembled.appendSlice(allocator, "STOP\n");
    return parse(allocator, assembled.items);
}

fn strictFixtureTailUsesPhysicalSceneRecords(tail: []const u8) bool {
    if (std.mem.indexOf(u8, tail, "grid_inputs,") != null or std.mem.indexOf(u8, tail, "grid_inputs |") != null) return true;
    var lines = delimited_input.records(tail);
    while (lines.next()) |line| {
        var fields = delimited_input.recordTokens(line);
        const tag = fields.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(tag, "weather_grid")) continue;
        _ = fields.next() orelse return false;
        return fields.next() == null;
    }
    return false;
}

fn strictFixtureTailStart(source: []const u8) ?usize {
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (strictFixtureTag(line)) |tag| if (std.ascii.eqlIgnoreCase(tag, "grid_inputs")) return offset;
        offset += line.len + 1;
    }
    return null;
}

fn strictFixtureRecord(source: []const u8, wanted_tag: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (strictFixtureTag(line)) |tag| if (std.ascii.eqlIgnoreCase(tag, wanted_tag)) return line;
    }
    return null;
}

fn strictFixtureTag(line: []const u8) ?[]const u8 {
    const content = if (std.mem.indexOfScalar(u8, line, '#')) |comment| line[0..comment] else line;
    var tokens = delimited_input.recordTokens(content);
    const tag = tokens.next() orelse return null;
    if (std.fmt.parseUnsigned(usize, tag, 10)) |_| return null else |_| {}
    return tag;
}

fn appendStrictFixtureLine(allocator: std.mem.Allocator, destination: *std.ArrayList(u8), line: []const u8) !void {
    try destination.appendSlice(allocator, line);
    try destination.append(allocator, '\n');
}

fn expectStrictFixtureLongRecord(tag: []const u8) !void {
    const canonical = strictFixtureRecord(strict_parameter_fixture_records, tag) orelse return error.MissingRunscriptValue;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "1,1,2\n");
    try source.appendSlice(std.testing.allocator, canonical);
    try source.appendSlice(std.testing.allocator, ",extra # comment\ngrid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n");
    try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, source.items));
}

test "strict parameter fixture merges a focused tagged record" {
    const fragment =
        \\1,1,2
        \\geospatial_grid,45,46,-80,-79,1,1
        \\tile_layout,1,1,2
        \\runtime,1,1,1e-9,1e-12,40,0.5
        \\PlAnT_StRuCtUrE,37
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather
        \\options
        \\NO
        \\plants
        \\o1
        \\o2
        \\o3
        \\o4
        \\o5
        \\o6
        \\o7
        \\o8
        \\o9
        \\o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, fragment);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 37), script.root_axes_per_plant);
    try std.testing.expectEqualStrings("grid_inputs", script.grid_input_file);
    try std.testing.expectEqual(core_config.default_mass_balance_relative_tolerance, script.mass_balance_relative_tolerance);
}

test "runtime accepts an independent conservation relative tolerance" {
    const fragment =
        \\1,1,2
        \\runtime,1,1,1e-5,1e-8,40,0.5,2e-7,3e-9,4e-10,1e-12,2e-11,3e-10,4e-9,5e-8,6e-7,7e-6,8e-5
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, fragment);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 2e-7), script.mass_balance_tolerance);
    try std.testing.expectEqual(@as(f64, 3e-9), script.negligible_quantity_threshold);
    try std.testing.expectEqual(@as(f64, 4e-10), script.mass_balance_relative_tolerance);
    try std.testing.expect(script.mass_balance_relative_tolerance != script.relative_tolerance);
    try std.testing.expectEqual(@as(f64, 1e-12), script.mass_balance_absolute_tolerance.water_m);
    try std.testing.expectEqual(@as(f64, 2e-11), script.mass_balance_absolute_tolerance.heat_megajoules_m2);
    try std.testing.expectEqual(@as(f64, 7e-6), script.mass_balance_absolute_tolerance.ions_mol_m2);
    try std.testing.expectEqual(@as(f64, 8e-5), script.mass_balance_absolute_tolerance.hydrogen_g_m2);
}

test "runtime typed physical tolerances are optional, distinct, and scaled" {
    const fragment =
        \\1,1,2
        \\runtime,1,1,1e-5,1e-8,40,0.5,2e-7,3e-9,4e-10,1e-12,2e-11,3e-10,4e-9,5e-8,6e-7,7e-6,8e-5,9e-9,1e-13,2e-13,3e-13,4e-13,5e-13,6e-13,7e-13,8e-13,9e-13,1e-12,2e-12,3e-12,4e-12
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, fragment);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 9e-9), script.physical_tolerance.relative);
    try std.testing.expectEqual(@as(f64, 1e-13), script.physical_tolerance.water_volume_m3);
    try std.testing.expectEqual(@as(f64, 4e-13), script.physical_tolerance.temperature_k);
    try std.testing.expectEqual(@as(f64, 4e-12), script.physical_tolerance.dimensionless);
    try std.testing.expect(script.physical_tolerance.water_volume_m3 != script.physical_tolerance.heat_megajoules);
    try std.testing.expectApproxEqRel(@as(f64, 1e-13 + 18e-9), script.physical_tolerance.waterVolume(2.0), 2 * std.math.floatEps(f64));
}

test "legacy runtime syntax receives typed defaults independent of solver tolerance" {
    const fragment =
        \\1,1,2
        \\runtime,1,1,1e-5,1e-8,40,0.5
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, fragment);
    defer script.deinit();
    const defaults: core_config.PhysicalTolerance = .{};
    try std.testing.expectEqual(defaults.water_volume_m3, script.physical_tolerance.water_volume_m3);
    try std.testing.expectEqual(defaults.carbon_g, script.physical_tolerance.carbon_g);
    try std.testing.expect(script.physical_tolerance.temperature_k != script.absolute_tolerance);
    try std.testing.expectEqual(script.relative_tolerance, script.nonlinear_tolerance.relative);
    try std.testing.expectEqual(script.absolute_tolerance * 1e-2, script.nonlinear_tolerance.water_volume_m3);
    try std.testing.expectEqual(script.absolute_tolerance * 100, script.nonlinear_tolerance.temperature_k);
    try std.testing.expect(script.nonlinear_tolerance.water_volume_m3 != script.nonlinear_tolerance.temperature_k);
    try std.testing.expectEqual(script.absolute_tolerance * 1e-2, script.nonlinear_tolerance.reaction_mol_per_m3);
    try std.testing.expectEqual(script.absolute_tolerance * 1e-2, script.nonlinear_tolerance.reaction_mol_per_megagram);
}

test "production source cannot add consumers of legacy universal tolerance scalars" {
    const Allowed = struct { path: []const u8, maximum_occurrences: usize };
    const allowed = [_]Allowed{};
    const patterns = [_][]const u8{
        "config." ++ "absolute_tolerance",
        "runscript." ++ "absolute_tolerance",
        "config." ++ "negligible_quantity_threshold",
        "runscript." ++ "negligible_quantity_threshold",
    };
    const io = std.testing.io;
    var source_dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer source_dir.close(io);
    var walker = try source_dir.walk(std.testing.allocator);
    defer walker.deinit();
    var total_occurrences: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try source_dir.readFileAlloc(io, entry.path, std.testing.allocator, .limited(8 * 1024 * 1024));
        defer std.testing.allocator.free(source);
        var occurrences: usize = 0;
        for (patterns) |pattern| occurrences += std.mem.count(u8, source, pattern);
        if (occurrences == 0) continue;
        total_occurrences += occurrences;
        var maximum: ?usize = null;
        for (allowed) |item| {
            if (sourcePathEqual(entry.path, item.path)) {
                maximum = item.maximum_occurrences;
                break;
            }
        }
        if (maximum == null or occurrences > maximum.?) {
            std.debug.print("legacy universal tolerance use added in {s}: {d} occurrence(s), allowed {any}\n", .{ entry.path, occurrences, maximum });
            return error.LegacyUniversalToleranceConsumerAdded;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), total_occurrences);
}

fn sourcePathEqual(actual: []const u8, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |actual_byte, expected_byte| {
        const normalized = if (actual_byte == '\\') '/' else actual_byte;
        if (normalized != expected_byte) return false;
    }
    return true;
}

const allocation_failure_runscript_fixture =
    "1,1,2\n" ++
    "grid_inputs,grid-map\n" ++
    "1,1\n" ++
    "1,1\n" ++
    "weather_grid,weather\n" ++
    "NO\n" ++
    "land\n" ++
    "plants\n" ++
    "o1\n" ++
    "o2\n" ++
    "o3\n" ++
    "o4\n" ++
    "o5\n" ++
    "o6\n" ++
    "o7\n" ++
    "o8\n" ++
    "o9\n" ++
    "o10\n" ++
    "0,0\n";

fn parseValidRunscriptWithAllocator(allocator: std.mem.Allocator) !void {
    var script = try parseStrictParameterFixture(
        allocator,
        allocation_failure_runscript_fixture,
    );
    script.deinit();
}

test "runscript parse releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseValidRunscriptWithAllocator,
        .{},
    );
}

test "strict scenario tail supports multiple groups and rejects inconsistent execution repeats" {
    const scene = "WeAtHeR_GrId | weather # mapping\nNO\nland\nplants\no1\no2\no3\no4\no5\no6\no7\no8\no9\no10\n";
    const prefix = "1,1,2\ngrid_inputs | grid-map # input\n";
    var script = try parseStrictParameterFixture(std.testing.allocator, prefix ++ "1,2\n1,3\n" ++ scene ++ "1,2\n1,4\n" ++ scene ++ "0,0\n");
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 2), script.scenarios.len);
    try std.testing.expectEqualStrings("NO", script.scenes[0].options);
    try std.testing.expectError(error.InconsistentExecutionRepeatCount, parseStrictParameterFixture(std.testing.allocator, prefix ++ "1,2\n1,1\n" ++ scene ++ "1,3\n1,1\n" ++ scene ++ "0,0\n"));
}

test "strict scenario tail enforces physical scene records and termination" {
    const prefix = "1,1,2\ngrid_inputs,grid-map\n1,1\n1,1\n";
    const editors = "o1\no2\no3\no4\no5\no6\no7\no8\no9\no10\n";
    try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, prefix ++ "weather_grid,weather,extra\nNO\nland\nplants\n" ++ editors ++ "0,0\n"));
    try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, prefix ++ "weather_grid,weather\nNO\nland\nplants\no1,o2\no3\no4\no5\no6\no7\no8\no9\no10\n0,0\n"));
    try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, prefix ++ "weather_grid,weather\nNO\nland\nplants\no1\no2\no3\no4\no5\no6\no7\no8\no9\n0,0\n"));
    try std.testing.expectError(error.TrailingRunscriptData, parseStrictParameterFixture(std.testing.allocator, prefix ++ "weather_grid,weather\nNO\nland\nplants\n" ++ editors ++ "0,0\ntrailing\n"));
}

test "strict snow through canopy exchange records are individually compulsory" {
    const fragment = "1,1,2\ngrid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    inline for (.{
        .{ "snow_layers", error.MissingSnowLayersRecord },                        .{ "snow_compaction", error.MissingSnowCompactionRecord },
        .{ "snow_thermal", error.MissingSnowThermalRecord },                      .{ "snow_vapor", error.MissingSnowVaporRecord },
        .{ "snow_vapor_transport", error.MissingSnowVaporTransportRecord },       .{ "surface_gas_resistance", error.MissingSurfaceGasResistanceRecord },
        .{ "surface_runoff", error.MissingSurfaceRunoffRecord },                  .{ "rainfall_impact", error.MissingRainfallImpactRecord },
        .{ "surface_aerodynamics", error.MissingSurfaceAerodynamicsRecord },      .{ "ground_air", error.MissingGroundAirRecord },
        .{ "canopy_surface_exchange", error.MissingCanopySurfaceExchangeRecord }, .{ "canopy_ammonia_exchange", error.MissingCanopyAmmoniaExchangeRecord },
    }) |case| try std.testing.expectError(case[1], parseStrictParameterFixtureOmitting(std.testing.allocator, fragment, case[0]));
}

test "strict plant initialization records are individually compulsory" {
    const fragment = "1,1,2\ngrid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    inline for (.{
        .{ "plant_structure", error.MissingPlantStructureRecord },                .{ "canopy_layers", error.MissingCanopyLayersRecord },
        .{ "canopy_geometry", error.MissingCanopyGeometryRecord },                .{ "canopy_discretization", error.MissingCanopyDiscretizationRecord },
        .{ "standing_dead_partition", error.MissingStandingDeadPartitionRecord }, .{ "plant_initial_heat_water", error.MissingPlantInitialHeatWaterRecord },
        .{ "plant_initial_geometry", error.MissingPlantInitialGeometryRecord },   .{ "plant_initial_phenology", error.MissingPlantInitialPhenologyRecord },
        .{ "root_initialization", error.MissingRootInitializationRecord },        .{ "root_morphology", error.MissingRootMorphologyRecord },
        .{ "standing_dead_energy", error.MissingStandingDeadEnergyRecord },
    }) |case| try std.testing.expectError(case[1], parseStrictParameterFixtureOmitting(std.testing.allocator, fragment, case[0]));
}

test "strict canopy phenology and seed records are compulsory and exact" {
    const fragment = "1,1,2\ngrid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    inline for (.{
        .{ "woody_optics", error.MissingWoodyOpticsRecord },             .{ "canopy_retention", error.MissingCanopyRetentionRecord },
        .{ "shoot_controls", error.MissingShootControlsRecord },         .{ "c4_carbon", error.MissingC4CarbonRecord },
        .{ "thermal_controls", error.MissingThermalControlsRecord },     .{ "canopy_stress", error.MissingCanopyStressRecord },
        .{ "phenology_controls", error.MissingPhenologyControlsRecord }, .{ "plant_pool_controls", error.MissingPlantPoolControlsRecord },
        .{ "seed_set_controls", error.MissingSeedSetControlsRecord },
    }) |case| try std.testing.expectError(case[1], parseStrictParameterFixtureOmitting(std.testing.allocator, fragment, case[0]));
    inline for (.{ "woody_optics", "canopy_retention", "shoot_controls", "c4_carbon", "thermal_controls", "canopy_stress", "phenology_controls", "plant_pool_controls", "seed_set_controls" }) |tag|
        try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\n" ++ tag ++ " # short\n" ++ fragment[6..]));
    inline for (.{
        "woody_optics,0.1,0.1,0.1,0.1,extra",                                                                            "canopy_retention,5e-4,2.5e-4,2.5e-4,2.5e-4,0.65,0.05,extra",
        "shoot_controls,3600,1.56,2.10e5,3.96e5,extra",                                                                  "c4_carbon,1.2,4.8,0.083e9,0.025,1000,0.02,5e-7,5e6,0.5,3,extra",
        "thermal_controls,3,2.5,1.25,5,12.5,15,35,27.5,30,2,0.002,0.005,0.010,0.002,extra",                              "canopy_stress,24,60,0.02,8.3143,710,25.229,62500,197500,222500,extra",
        "phenology_controls,8.3143,710,24.269,60000,197500,218500,0.1,0.25,2,0.667,-0.1,-150,-1.5,3600,1e-6,1e-6,extra", "plant_pool_controls,no,1e-15,1e-6,1e-6,1e-6,1e-2,1e-3,extra",
        "seed_set_controls,2.5e-2,0.5e-2,0.1e-2,extra",
    }) |record| try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\n" ++ record ++ " # comment\n" ++ fragment[6..]));
}

test "strict root transport and metabolism records are compulsory and exact" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    inline for (.{
        .{ "root_gas", error.MissingRootGasRecord },                                  .{ "root_gas_transport", error.MissingRootGasTransportRecord },
        .{ "root_nutrients", error.MissingRootNutrientsRecord },                      .{ "root_salts", error.MissingRootSaltsRecord },
        .{ "root_mycorrhizal_exchange", error.MissingRootMycorrhizalExchangeRecord }, .{ "root_exudation", error.MissingRootExudationRecord },
        .{ "root_porosity", error.MissingRootPorosityRecord },                        .{ "root_metabolism", error.MissingRootMetabolismRecord },
    }) |case| try std.testing.expectError(case[1], parseStrictParameterFixtureOmitting(std.testing.allocator, "1,1,2\n" ++ tail, case[0]));
    inline for (.{ "root_gas", "root_gas_transport", "root_nutrients", "root_salts", "root_mycorrhizal_exchange", "root_exudation", "root_porosity", "root_metabolism" }) |tag| {
        try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\n" ++ tag ++ " # short\n" ++ tail));
        try expectStrictFixtureLongRecord(tag);
    }
}

test "strict root records preserve lines and accept flexible syntax" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    var script = try parseStrictParameterFixture(std.testing.allocator, "1,1,2\nRoOt_SaLtS | 298.15 | 4e-6 | 4e-6 | 4e-6 | 4e-6 | 4e-6 | 4e-6 | 4e-6 | 4e-6 | 6 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 # valid\n" ++ tail);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 298.15), script.root_salt_parameters.reference_temperature_k, 1e-12);
    try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nroot_exudation,1e3,0.1\n0.1,1e-3\n" ++ tail));
    try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nroot_porosity,0.75,0.1,0.01,root_metabolism,0.015\n" ++ tail));
}

test "strict shoot allocation and storage records are compulsory and exact" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    inline for (.{
        .{ "organ_partition", error.MissingOrganPartitionRecord },              .{ "shoot_metabolism", error.MissingShootMetabolismRecord },
        .{ "shoot_node_growth", error.MissingShootNodeGrowthRecord },           .{ "seasonal_turnover", error.MissingSeasonalTurnoverRecord },
        .{ "branch_mobile_exchange", error.MissingBranchMobileExchangeRecord }, .{ "symbiotic_fixation", error.MissingSymbioticFixationRecord },
        .{ "plant_fire_combustion", error.MissingPlantFireCombustionRecord },   .{ "soil_fire_combustion", error.MissingSoilFireCombustionRecord },
        .{ "shoot_root_exchange", error.MissingShootRootExchangeRecord },       .{ "storage_remobilization", error.MissingStorageRemobilizationRecord },
    }) |case| try std.testing.expectError(case[1], parseStrictParameterFixtureOmitting(std.testing.allocator, "1,1,2\n" ++ tail, case[0]));
    inline for (.{ "organ_partition", "shoot_metabolism", "shoot_node_growth", "seasonal_turnover", "branch_mobile_exchange", "symbiotic_fixation", "plant_fire_combustion", "soil_fire_combustion", "shoot_root_exchange", "storage_remobilization" }) |tag| {
        try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\n" ++ tag ++ " # short\n" ++ tail));
        try expectStrictFixtureLongRecord(tag);
    }
}

test "strict shoot allocation records preserve lines and flexible syntax" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    var script = try parseStrictParameterFixture(std.testing.allocator, "1,1,2\nOrGaN_PaRtItIoN | 0.75 | 0.25 | 0.02 | 0.05 | 0.0067 | 0.0167 | 0.75 | 1.5 | 2 | 2 | 1.75 | 1.5 | 0.25 | 0.5 | 0.67 | 0.67 | 0.58 | 0.5 | 0.1 | 0.1 # valid\n" ++ tail);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), script.organ_partition_parameters.initial_leaf_fraction, 1e-15);
    try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nshoot_root_exchange,0.1,0.01\n0.5,0.1\n" ++ tail));
    try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nbranch_mobile_exchange,0.1,0.1,0.1,storage_remobilization\n" ++ tail));
    try std.testing.expectError(error.InvalidSeasonalTurnoverParameter, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nseasonal_turnover,0,240\n" ++ tail));
    try std.testing.expectError(error.NonFiniteSeasonalTurnoverParameter, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nseasonal_turnover,nan,240\n" ++ tail));
}

test "strict nutrient chemistry and parameter-file records are compulsory and exact" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    inline for (.{
        .{ "plant_nutrients", error.MissingPlantNutrientsRecord },
        .{ "microbial_dimensions", error.MissingMicrobialDimensionsRecord },
        .{ "organic_initialization_file", error.MissingOrganicInitializationFileRecord },
        .{ "surface_gas_parameter_file", error.MissingSurfaceGasParameterFileRecord },
        .{ "soil_nitrogen_parameter_file", error.MissingSoilNitrogenParameterFileRecord },
        .{ "chemistry_initialization", error.MissingChemistryInitializationRecord },
        .{ "chemistry_units", error.MissingChemistryUnitsRecord },
        .{ "chemistry_reaction_file", error.MissingChemistryReactionFileRecord },
        .{ "fertilizer_units", error.MissingFertilizerUnitsRecord },
    }) |case| try std.testing.expectError(case[1], parseStrictParameterFixtureOmitting(std.testing.allocator, "1,1,2\n" ++ tail, case[0]));

    inline for (.{ "plant_nutrients", "microbial_dimensions", "organic_initialization_file", "surface_gas_parameter_file", "soil_nitrogen_parameter_file", "chemistry_initialization", "chemistry_units", "chemistry_reaction_file", "fertilizer_units" }) |tag| {
        try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\n" ++ tag ++ " # missing compulsory value\n" ++ tail));
        try expectStrictFixtureLongRecord(tag);
    }
}

test "strict nutrient chemistry records preserve lines and accept flexible syntax" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    var script = try parseStrictParameterFixture(std.testing.allocator, "1,1,2\nPlAnT_NuTrIeNtS | 0 | 0 | 0 | 1 | 0.75 | 0.8 | 0.9 # metres\n" ++ tail);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), script.plant_nutrient_initialization.initial_ammonium_band_row_spacing_m, 1e-15);

    try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nchemistry_initialization,0.01,1e-8,1.9e-21\n6.3e-26,7.5,6.2e-5,4.8e-10\n" ++ tail));
    try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nmicrobial_dimensions,6,7,fertilizer_units,14\n" ++ tail));
}

test "strict canopy phenology and seed records preserve lines and flexible syntax" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    var script = try parseStrictParameterFixture(std.testing.allocator, "1,1,2\nPlAnT_PoOl_CoNtRoLs | YeS | 1e-15 | 1e-6 | 1e-6 | 1e-6 | 1e-2 | 1e-3 # valid\n" ++ tail);
    defer script.deinit();
    try std.testing.expect(script.dynamic_plant_salts);
    try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\ncanopy_stress,24,60,0.02\n8.3143,710,25.229,62500,197500,222500\n" ++ tail));
    try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nwoody_optics,0.1,0.1,0.1,0.1,canopy_retention,5e-4\n" ++ tail));
}

test "strict plant initialization records reject short and long physical records" {
    const prefix = "1,1,2\n";
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    inline for (.{ "plant_structure", "canopy_layers", "canopy_geometry", "canopy_discretization", "standing_dead_partition", "plant_initial_heat_water", "plant_initial_geometry", "plant_initial_phenology", "root_initialization", "root_morphology", "standing_dead_energy" }) |tag|
        try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, prefix ++ tag ++ " # short\n" ++ tail));
    inline for (.{
        "plant_structure,10,extra",                                                                              "canopy_layers,10,extra",                                                  "canopy_geometry,4e-6,extra",                                                  "canopy_discretization,4,4,4,extra",
        "standing_dead_partition,0,0.045,0.660,0.295,0.020,0.010,0.010,0.020,0.0020,0.0010,0.0010,0.0020,extra", "plant_initial_heat_water,273.15,2.173e-3,0.61,5360,3.661e-3,-1e-3,extra", "plant_initial_geometry,5e-6,2,0.75,3.1416,0.33,4,1e-6,0.05,0.01,3.142,extra", "plant_initial_phenology,0.005,1,24,10,15,3,4,5,extra",
        "root_initialization,2.5,25,2.5e-6,-0.01,-0.01,1e-3,1,extra",                                            "root_morphology,1e-2,5,extra",                                            "standing_dead_energy,0.0025,2.496,0.97,0.838e-3,0.838e-4,extra",
    }) |record| try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, prefix ++ record ++ " # comment\n" ++ tail));
}

test "strict plant initialization records preserve line boundaries and accept case comments and delimiters" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    var script = try parseStrictParameterFixture(std.testing.allocator, "1,1,2\nStAnDiNg_DeAd_EnErGy | 0.0025 | 2.496 | 0.97 | 0.000838 | 0.0000838 # valid\n" ++ tail);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.0025), script.standing_dead_sapwood_thickness_m, 1e-15);
    try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nroot_initialization,2.5,25,2.5e-6\n-0.01,-0.01,1e-3,1\n" ++ tail));
    try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nroot_morphology,1e-2,5,standing_dead_energy,0.0025,2.496,0.97,0.838e-3,0.838e-4\n" ++ tail));
}

test "strict snow through canopy exchange records reject short and long lines" {
    const prefix = "1,1,2\n";
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    inline for (.{
        "snow_layers",    "snow_compaction", "snow_thermal",         "snow_vapor", "snow_vapor_transport",    "surface_gas_resistance",
        "surface_runoff", "rainfall_impact", "surface_aerodynamics", "ground_air", "canopy_surface_exchange", "canopy_ammonia_exchange",
    }) |tag| try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, prefix ++ tag ++ " # short\n" ++ tail));
    inline for (.{
        "snow_layers,5,0.05,0.125,0.25,0.50,1.00,0.05,0.92,333,2.7185,extra",
        "snow_compaction,0.25,1e-5,0.04,0.25,-0.08,23,-15,2,1.7e-3,extra",
        "snow_thermal,0.0036,2.650,-1.652,0.6,extra",
        "snow_vapor,2.173e-3,0.61,5360,3.661e-3,2465,2834,extra",
        "snow_vapor_transport,8.96e-2,298.15,1.75,0,4.19,extra",
        "surface_gas_resistance,-0.10,0.05,10,1e-6,1e6,2e-4,1e-6,extra",
        "surface_runoff,0.005,0.011,1e-3,3600,1e-12,extra",
        "rainfall_impact,8.95,8.44,15.8,5.87,2.5,2,1e-3,5e-4,extra",
        "surface_aerodynamics,0.5,2,0.005,0.025,1.27e8,0.168,1e-12,0.00139,no,extra",
        "ground_air,1.25e-3,5,1.25e-3,2465,2.173e-3,0.61,5360,3.661e-3,extra",
        "canopy_surface_exchange,0.00139,0.0278,0.00139,0.0139,18,8.3143,4.19,0.00278,0.0278,extra",
        "canopy_ammonia_exchange,0.16,0.10,0.05,2,1e-4,0.1,0.513,0.0171,extra",
    }) |record| try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, prefix ++ record ++ " # comment\n" ++ tail));
}

test "snow layer dynamic arity and physical-line boundaries are strict" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    var script = try parseStrictParameterFixture(std.testing.allocator, "1,1,2\nSnOw_LaYeRs | 3 | 0.1 | 0.3 | 0.8 | 0.05 | 0.92 | 333 | 2.7185 # valid\n" ++ tail);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 3), script.snow_layer_bottom_depth_m.len);
    try std.testing.expectError(error.NoSnowLayers, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nsnow_layers,0,0.05,0.92,333,2.7185\n" ++ tail));
    try std.testing.expectError(error.InvalidSnowLayerBoundaries, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nsnow_layers,3,0.1,0.1,0.8,0.05,0.92,333,2.7185\n" ++ tail));
    try std.testing.expectError(error.ShortRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nsnow_layers,3,0.1,0.3\n0.8,0.05,0.92,333,2.7185\n" ++ tail));
    try std.testing.expectError(error.LongRunscriptRecord, parseStrictParameterFixture(std.testing.allocator, "1,1,2\nsnow_layers,3,0.1,0.3,0.8,0.05,0.92,333,2.7185,snow_compaction,0.25\n" ++ tail));
}

test "strict soil and heat records reject short physical records" {
    inline for (.{
        "soil_solver",
        "soil_process",
        "macropore_van_genuchten",
        "dual_domain_exchange",
        "frozen_hydraulic_impedance",
        "surface_residue_freeze_thaw",
        "soil_gas_transport",
        "soil_phase_heat",
    }) |short_record| {
        const fragment =
            "1,1,2\ngeospatial_grid,45,46,-80,-79,1,1\ntile_layout,1,1,2\nruntime,1,1,1e-9,1e-12,40,0.5\n" ++
            short_record ++
            " # deliberately short\ngrid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
        try std.testing.expectError(
            error.ShortRunscriptRecord,
            parseStrictParameterFixture(std.testing.allocator, fragment),
        );
    }
}

test "strict soil and heat records reject long physical records" {
    inline for (.{
        "soil_solver,-0.0005,-1.5e12,250000,0.2576,-0.20,0.36,0.60e-6,0.0260,0.50,0.32e-6,0.075,0.195,0.27,0.62,0.71,0.04,0.15,0.22,0.75,0.75,0.5,0.5,100,1.33,0.1,1.54,0.033,0.10,75,1e-15,0.067,0.125,890,10000,0.80,0.0125,120,10000,0.52,10,1.82,200,80,20,5,1,1,extra",
        "soil_process,0.0098,8.96e-2,298.15,1.75,0.66,0.03,0.5e-3,1e-6,0.533,0.0267,extra",
        "macropore_van_genuchten,0,15,2.68,0.5,extra",
        "dual_domain_exchange,3,0.4,extra",
        "frozen_hydraulic_impedance,7,extra",
        "surface_residue_freeze_thaw,0,400,2.5,extra",
        "soil_gas_transport,298.15,1.75,4.68e-2,7.80e-2,6.43e-2,5.57e-2,5.57e-2,6.67e-2,5.57e-2,0.66,1e-12,1e6,18,extra",
        "soil_phase_heat,2.173e-3,0.61,5360,3.661e-3,18,8.3143,2450,9.0959e4,333,0.917,6.2913e-3,273.15,0.333,0.333,13990344827.5862,89223880597.0149,1.09495999584408,4.77823246449888,10000,4.19,1.9274,extra",
    }) |long_record| {
        const fragment =
            "1,1,2\ngeospatial_grid,45,46,-80,-79,1,1\ntile_layout,1,1,2\nruntime,1,1,1e-9,1e-12,40,0.5\n" ++
            long_record ++
            " # trailing comment is not data\ngrid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
        try std.testing.expectError(
            error.LongRunscriptRecord,
            parseStrictParameterFixture(std.testing.allocator, fragment),
        );
    }
}

test "strict soil records do not steal split values or accept joined records" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    const prefix = "1,1,2\ngeospatial_grid,45,46,-80,-79,1,1\ntile_layout,1,1,2\nruntime,1,1,1e-9,1e-12,40,0.5\n";
    try std.testing.expectError(
        error.ShortRunscriptRecord,
        parseStrictParameterFixture(
            std.testing.allocator,
            prefix ++ "soil_process,0.0098,8.96e-2,298.15,1.75,0.66,0.03,0.5e-3,1e-6,0.533\n0.0267\n" ++ tail,
        ),
    );
    try std.testing.expectError(
        error.LongRunscriptRecord,
        parseStrictParameterFixture(
            std.testing.allocator,
            prefix ++ "dual_domain_exchange,3,0.4,macropore_van_genuchten,0,15,2.68,0.5\n" ++ tail,
        ),
    );
}

test "strict soil and heat records are individually compulsory" {
    const fragment =
        \\1,1,2
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    inline for (.{
        .{ "soil_solver", error.MissingSoilSolverRecord },
        .{ "soil_process", error.MissingSoilProcessRecord },
        .{ "macropore_van_genuchten", error.MissingMacroporeVanGenuchtenRecord },
        .{ "dual_domain_exchange", error.MissingDualDomainExchangeRecord },
        .{ "frozen_hydraulic_impedance", error.MissingFrozenHydraulicImpedanceRecord },
        .{ "surface_residue_freeze_thaw", error.MissingSurfaceResidueFreezeThawRecord },
        .{ "soil_gas_transport", error.MissingSoilGasTransportRecord },
        .{ "soil_phase_heat", error.MissingSoilPhaseHeatRecord },
    }) |case| try std.testing.expectError(
        case[1],
        parseStrictParameterFixtureOmitting(std.testing.allocator, fragment, case[0]),
    );
}

test "strict thermal boundary records are individually compulsory" {
    const fragment =
        \\1,1,2
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    inline for (.{
        .{ "geothermal", error.MissingGeothermalRecord },
        .{ "subsurface_state", error.MissingSubsurfaceStateRecord },
        .{ "soil_geometry", error.MissingSoilGeometryRecord },
        .{ "surface_pond_energy", error.MissingSurfacePondEnergyRecord },
        .{ "surface_energy", error.MissingSurfaceEnergyRecord },
    }) |case| try std.testing.expectError(
        case[1],
        parseStrictParameterFixtureOmitting(std.testing.allocator, fragment, case[0]),
    );
}

test "strict thermal boundary records reject short long split and joined lines" {
    const tail = "grid_inputs grid_inputs\n1,1\n1,1\nweather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10\n0,0\n";
    const prefix = "1,1,2\n";
    inline for (.{ "geothermal", "subsurface_state", "soil_geometry", "surface_pond_energy", "surface_energy" }) |short_record| try std.testing.expectError(
        error.ShortRunscriptRecord,
        parseStrictParameterFixture(std.testing.allocator, prefix ++ short_record ++ "\n" ++ tail),
    );
    inline for (.{
        "geothermal,yes,10,1,8.1e-3,2.052e-4,extra",
        "subsurface_state,1e-3,1e-6,extra",
        "soil_geometry,1.82e-6,110000,0.083,1e-9,extra",
        "surface_pond_energy,2.496e-6,0.838e-3,extra",
        "surface_energy,0.97,0.97,0.97,0.07,0.43,0,1,173.15,373.15,extra",
    }) |long_record| try std.testing.expectError(
        error.LongRunscriptRecord,
        parseStrictParameterFixture(std.testing.allocator, prefix ++ long_record ++ "\n" ++ tail),
    );
    try std.testing.expectError(
        error.ShortRunscriptRecord,
        parseStrictParameterFixture(std.testing.allocator, prefix ++ "soil_geometry,1.82e-6,110000,0.083\n1e-9\n" ++ tail),
    );
    try std.testing.expectError(
        error.LongRunscriptRecord,
        parseStrictParameterFixture(std.testing.allocator, prefix ++ "surface_pond_energy,2.496e-6,0.838e-3,surface_energy,0.97,0.97,0.97,0.07,0.43,0,1,173.15,373.15\n" ++ tail),
    );
}

test "strict thermal boundary records accept comments mixed delimiters and case" {
    const fragment =
        \\1,1,2
        \\GeOtHeRmAl|YeS|12|2|0.009|0.00021 # boundary
        \\SuBsUrFaCe_StAtE 0.002 0.000003 # fractions
        \\SoIl_GeOmEtRy,1.9e-6|120000 0.09|2e-9 # geometry
        \\SuRfAcE_PoNd_EnErGy|2.6e-6 0.0009 # heat
        \\SuRfAcE_EnErGy|0.95,0.98 0.96|0.08|0.5,0.12 0.9|180,380 # bounds
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, fragment);
    defer script.deinit();
    try std.testing.expect(script.geothermal_controls.enabled);
    try std.testing.expectEqual(@as(f64, 12), script.geothermal_controls.minimum_source_depth_m);
    try std.testing.expectEqual(@as(f64, 0.002), script.water_table_air_fraction_threshold);
    try std.testing.expectEqual(@as(f64, 1.9e-6), script.soil_geometry_parameters.organic_carbon_specific_volume_m3_per_g);
    try std.testing.expectEqual(@as(f64, 2.6e-6), script.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k);
    try std.testing.expectEqual(@as(f64, 0.95), script.soil_longwave_emissivity);
}

test "strict runscript rejects trailing legacy stop record" {
    const fragment =
        \\1,1,2
        \\geospatial_grid,45,46,-80,-79,1,1
        \\tile_layout,1,1,2
        \\runtime,1,1,1e-9,1e-12,40,0.5
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
        \\StOp
    ;
    try std.testing.expectError(
        error.TrailingRunscriptData,
        parseStrictParameterFixture(std.testing.allocator, fragment),
    );
}

test "shell heredoc extraction preserves strict input records" {
    const source = "#!/bin/sh\nmodel << eor\n1,1,2\ngeospatial_grid,45,46,-75,-74,1,1\ntile_layout,1,1,2\nruntime,1,1,1e-8,1e-11,40,0.5\neor\n";
    try std.testing.expectEqualStrings(
        "1,1,2\ngeospatial_grid,45,46,-75,-74,1,1\ntile_layout,1,1,2\nruntime,1,1,1e-8,1e-11,40,0.5\n",
        extractInputBody(source),
    );
}

test "plant nutrients record enforces seven compulsory values on one line" {
    try validatePlantNutrientsRecordArity(
        "plant_nutrients,0,0,0,1,0.75,0.8,0.9 # metres\n",
    );
    try std.testing.expectError(
        error.ShortPlantNutrientsRecord,
        validatePlantNutrientsRecordArity(
            "plant_nutrients|0|0|0|1|0.75|0.8\n",
        ),
    );
    try std.testing.expectError(
        error.LongPlantNutrientsRecord,
        validatePlantNutrientsRecordArity(
            "plant_nutrients 0 0 0 1 0.75 0.8 0.9 1.0\n",
        ),
    );
}

test "runscript empty-field preflight handles comments and shell wrappers" {
    try rejectEmptyExplicitFields(
        "1, 1 | 1\t1 # mixed valid delimiters\n# comment only\n",
    );
    try std.testing.expectError(
        error.EmptyRunscriptRecordValue,
        parse(
            std.testing.allocator,
            "#!/bin/sh\nmodel << eor\n1,1,,1,1\neor\n",
        ),
    );
}

test "plant root axis count is a case-insensitive runtime input" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\PlAnT_StRuCtUrE,37
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 37), script.root_axes_per_plant);
}

test "snow layer count boundaries and density are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\SnOw_LaYeRs,7,0.02,0.05,0.10,0.20,0.40,0.80,1.60,0.075,0.92,333,2.7185
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 7), script.snow_layer_bottom_depth_m.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.6), script.snow_layer_bottom_depth_m[6], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.075), script.initial_snow_density_megagrams_per_m3, 1e-15);
}

test "canopy layer count is a case-insensitive runtime input" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\CaNoPy_LaYeRs|17
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 17), script.canopy_layer_count);
}

test "canopy angular dimensions are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\CaNoPy_DiScReTiZaTiOn|7|9|11
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 7), script.canopy_discretization.leaf_inclination_class_count);
    try std.testing.expectEqual(@as(usize, 9), script.canopy_discretization.leaf_azimuth_class_count);
    try std.testing.expectEqual(@as(usize, 11), script.canopy_discretization.diffuse_sky_sector_count);
}

test "STARTQ standing dead partition coefficients are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\StAnDiNg_DeAd_PaRtItIoN|0.1|0.2|0.3|0.4|1|2|3|4|5|6|7|8
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual([4]f64{ 0.1, 0.2, 0.3, 0.4 }, script.standing_dead_partition_parameters.carbon_fraction);
    try std.testing.expectEqual([4]f64{ 1, 2, 3, 4 }, script.standing_dead_partition_parameters.nitrogen_weight);
    try std.testing.expectEqual([4]f64{ 5, 6, 7, 8 }, script.standing_dead_partition_parameters.phosphorus_weight);
}

test "STARTQ initial plant heat and water coefficients are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\PlAnT_InItIaL_HeAt_WaTeR|270|0.003|0.7|5000|0.004|-0.02
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 270), script.plant_heat_water_parameters.kelvin_offset_k);
    try std.testing.expectEqual(@as(f64, -0.02), script.plant_heat_water_parameters.initial_total_water_potential_megapascal);
}

test "STARTQ seed and root geometry coefficients are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\PlAnT_InItIaL_GeOmEtRy|6e-6|2.1|0.8|3.14|0.34|4.1|2e-6|0.06|0.02|3.141
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 6e-6), script.plant_geometry_parameters.seed_volume_m3_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.02), script.plant_geometry_parameters.root_porosity_floor);
}

test "READQ and STARTQ initial phenology coefficients are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\PlAnT_InItIaL_PhEnOlOgY|0.01|2|36|8|14|4|6|8
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 0.01), script.phenology_initialization_parameters.perennial_input_scale);
    try std.testing.expectEqual(@as(usize, 36), script.phenology_initialization_parameters.perennial_maximum_concurrently_growing_nodes);
    try std.testing.expectEqual(@as(usize, 8), script.phenology_initialization_parameters.late_maximum_concurrently_growing_nodes);
}

test "STARTQ root initialization coefficients are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\RoOt_InItIaLiZaTiOn|3|30|4e-6|-0.02|-0.03|0.002|0.9
        \\rOoT_MoRpHoLoGy|0.015|6.5
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 4e-6), script.root_initialization_parameters.mycorrhizal_radius_m);
    try std.testing.expectEqual(@as(f64, -0.02), script.root_initialization_parameters.initial_total_water_potential_megapascal);
    try std.testing.expectEqual(@as(f64, 0.9), script.root_initialization_parameters.initial_water_fraction);
    try std.testing.expectEqual(@as(f64, 0.015), script.root_morphology_parameters.minimum_average_secondary_length_m);
    try std.testing.expectEqual(@as(f64, 6.5), script.root_morphology_parameters.root_elastic_modulus_megapascal);
}

test "microbial substrate and population dimensions are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\MiCrObIaL_DiMeNsIoNs|11|19
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 11), script.microbial_substrate_count);
    try std.testing.expectEqual(@as(usize, 19), script.microbial_population_count);
}

test "STARTQ canopy geometry is a case-insensitive runtime input" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\CaNoPy_LaYeRs|17
        \\cAnOpY_gEoMeTrY|5.25e-6
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 5.25e-6), script.stalk_volume_m3_per_g_c, 1.0e-15);
}

test "UPTAKE standing-dead energy coefficients are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\StAnDiNg_DeAd_EnErGy|0.003|2.6|0.96|0.0009|0.00009
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), script.standing_dead_sapwood_thickness_m, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.6), script.standing_dead_dry_volume_heat_capacity_megajoules_per_m3_k, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.96), script.standing_dead_emissivity, 1.0e-15);
}

test "HOUR1 woody optics are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\WoOdY_OpTiCs|0.12|0.08|0.2|0.15
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.12), script.woody_optics_parameters.stalk_shortwave_albedo, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), script.woody_optics_parameters.standing_dead_par_albedo, 1.0e-15);
}

test "HOUR1 canopy retention controls are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\CaNoPy_ReTeNtIoN|0.0006|0.0003|0.00035|0.0004|0.7|0.06
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.0006), script.canopy_retention_parameters.surface_water_capacity_m3_per_m2_by_root_profile[0], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), script.canopy_retention_parameters.low_sun_extinction_per_area_index, 1.0e-15);
}

test "STARTQ shoot controls are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\ShOoT_CoNtRoLs|3600|1.56|210000|396000
        \\C4_CaRbOn|1.25|4.75|83000000|0.026|1100|0.03|0.0000006|5100000|0.6|3.2
        \\ThErMaL_CoNtRoLs|3|2.5|1.25|5|12.5|15|35|27.5|30|2|0.002|0.005|0.01|0.002
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 3600), script.shoot_control_parameters.seconds_per_hour);
    try std.testing.expectEqual(@as(f64, 1.56), script.shoot_control_parameters.co2_to_water_cuticular_resistance_ratio);
    try std.testing.expectEqual(@as(f64, 396000), script.shoot_control_parameters.c4_intercellular_oxygen_umol_per_mol);
    try std.testing.expectEqual(@as(f64, 1.25), script.c4_carbon_parameters.bundle_sheath_water_g_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.026), script.c4_carbon_parameters.decarboxylation_fraction_per_h);
    try std.testing.expectEqual(@as(f64, 0.0000006), script.c4_carbon_parameters.leakage_g_c_per_umol_per_l_g_leaf_c_h);
    try std.testing.expectEqual(@as(f64, 5100000), script.c4_carbon_parameters.mesophyll_feedback_half_saturation_umol_per_l);
    try std.testing.expectEqual(@as(f64, 0.6), script.c4_carbon_parameters.co2_compensation_umol_per_l);
    try std.testing.expectEqual(@as(f64, 3.2), script.c4_carbon_parameters.electron_requirement_umol_e_per_umol_co2);
    try std.testing.expectEqual(@as(f64, 35), script.thermal_acclimation_parameters.soybean_c3_seed_set_base_c);
}

test "root gas scientific coefficients are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\RoOt_GaS,300,9e-6,5.5,0.03,0.32,0.52,0.018,56000,2.7,2e-6,0.4,-13.7,-0.8
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 300), script.root_gas_parameters.reference_temperature_k, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.7), script.root_gas_parameters.oxygen_to_carbon_respiration_ratio_g_o_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2e-6), script.root_gas_parameters.minimum_soil_water_film_m, 1.0e-15);
}

test "all transported root gas coefficients are runtime inputs" {
    const source =
        \\1 1 2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\runtime 1 1 1e-8 1e-11 40 0.5
        \\RoOt_GaS_TrAnSpOrT|1.8|0.041|0.072|0.053|0.064|0.055|0.061|4.1e-6|7.1e-6|5.8e-6|4.2e-6|7.5e-6|9.1e-6|0.71|0.032|0.53|280|0.033|0.031|0.15|0.16|0.24|0.08|0.17|0.32|0.84|0.59|0.90|0.51|0.60|0.52|0.028|0.020|0.030|0.017|0.021|0.018
        \\grid_inputs grid_inputs
        \\1 1
        \\1 1
        \\weather_grid weather options no plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0 0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 1.8), script.root_gas_parameters.gaseous_diffusivity_temperature_exponent, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.041), script.root_gas_parameters.gaseous_diffusivity_m2_per_h_at_reference[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9.1e-6), script.root_gas_parameters.aqueous_diffusivity_m2_per_h_at_reference[5], 1e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 280), script.root_gas_parameters.water_to_air_mass_solubility_at_25c[3], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.018), script.root_gas_parameters.solubility_temperature_coefficient_per_c[5], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9.1e-6), script.root_gas_parameters.oxygen_aqueous_diffusivity_m2_per_h_at_reference, 1e-18);
}

test "root nutrient diffusion coefficients are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\RoOt_NuTrIeNtS|300|4.1e-6|6.2e-6|3.3e-6|5.8|0.68|1.1|1.2|0.011|0.012|0.0002|30.97
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 300), script.root_nutrient_parameters.reference_temperature_k, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 6.2e-6), script.root_nutrient_parameters.aqueous_diffusivity_m2_per_h_at_reference[1], 1.0e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 5.8), script.root_nutrient_parameters.aqueous_diffusivity_temperature_exponent, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.68), script.root_nutrient_parameters.liquid_tortuosity_coefficient, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.012), script.root_nutrient_parameters.phosphorus_inhibition_by_nitrogen_g_n_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0002), script.root_nutrient_parameters.minimum_population_uptake_fraction_multiplier, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 30.97), script.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol, 1.0e-15);
}

test "UPTAKE root salt coefficients are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\RoOt_SaLtS|300|1e-6|2e-6|3e-6|4e-6|5e-6|6e-6|7e-6|8e-6|5.9|1e-5|2e-5|3e-5|4e-5|5e-5|6e-5|7e-5|8e-5
        \\RoOt_MyCoRrHiZaL_ExChAnGe|0.07|0.45
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 300), script.root_salt_parameters.reference_temperature_k, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 8e-6), script.root_salt_parameters.aqueous_diffusivity_m2_per_h_at_reference[7], 1.0e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 5.9), script.root_salt_parameters.aqueous_diffusivity_temperature_exponent, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 8e-5), script.root_salt_parameters.root_concentration_inhibition_mol_per_m3[7], 1.0e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 0.07), script.root_mycorrhizal_exchange_parameters.minimum_partner_water_volume_ratio, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.45), script.root_mycorrhizal_exchange_parameters.exchange_fraction_per_h, 1.0e-15);
}

test "UPTAKE root exudation coefficients are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\RoOt_ExUdAtIoN|999|0.11|0.12|0.0011
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 999), script.root_exudation_parameters.maximum_root_carbon_concentration_g_c_per_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.11), script.root_exudation_parameters.root_mobile_nitrogen_exchange_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0011), script.root_exudation_parameters.exchange_rate_per_h, 1.0e-15);
}

test "GROSUB root porosity coefficients are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\RoOt_PoRoSiTy|0.74|0.11|0.012
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.74), script.root_porosity_parameters.maximum_porosity_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.11), script.root_porosity_parameters.oxygen_stress_induction_fraction_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.012), script.root_porosity_parameters.relaxation_fraction_per_h, 1.0e-15);
}

test "GROSUB root metabolism coefficients are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\RoOt_MeTaBoLiSm|0.016|0.026|0.11|0.012|0.009|1.75|0.16|0.34|0.66|0.68|2.6e-5|0.17|8.31|711|62600|197600|25.3|999|0.051|0.101|0.26|0.0011|1.1|4.1|0.26|1.1|2.1|4.1|337|2.6|26|0.87|0.76|0.51|481
        \\OrGaN_PaRtItIoN|0.74|0.26|0.021|0.051|0.007|0.017|0.76|1.51|2.01|2.02|1.76|1.52|0.26|0.51|0.68|0.69|0.59|0.52|0.11|0.12
        \\ShOoT_MeTaBoLiSm|0.016|0.026|0.011|0.34|1.71|0.026|0.11|0.012
        \\ShOoT_NoDe_GrOwTh|2.6|26|-0.334|-0.51|-0.668|0.0021|2.1|2.2|0.0011|0.0051|0.051|0.76|0.0051|0.0011|73|23|361|1441|721|722|0.0052|0.0053|0.0000052|0.0000053|0.000052|0.00052
        \\BrAnCh_MoBiLe_ExChAnGe|0.012|0.013|0.014
        \\SyMbIoTiC_FiXaTiOn|0.00011|0.126|0.011|0.26|0.101|0.0101|0.00011|0.000011|11|1001|0.011|0.168|0.332|0.334|0.335|0.21|0.11|0.051|0.22|0.12|0.052|0.51|0.26|0.126|0.051|0.026|0.013
        \\PlAnT_FiRe_CoMbUsTiOn|474.15|1.9|8.32|60001|12.029|901|902|903|904|905|120001|20.621|1.1|2.668|0.01|0.51|2101|11|0.0376|0.0126|0.0744
        \\SoIl_FiRe_CoMbUsTiOn|475.15|1.8|8.33|60002|12.030|120002|20.622|1001|5001|1002|1003|1004|1005|1.2|2.669|0.02|0.52|2.9|0.006|0.0377|0.0127|0.0745
        \\ShOoT_RoOt_ExChAnGe|0.051|0.0051|0.26|0.91
        \\StOrAgE_ReMoBiLiZaTiOn|46|139|0.016|0.006|0.24|0.26|0.76|0.74|0.11|0.12|0.013|0.14|0.15|0.16|0.051|0.21|0.0051|0.021|0.11
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.016), script.root_metabolism_parameters.maximum_substrate_respiration_fraction_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.026), script.root_metabolism_parameters.substrate_respiration_half_saturation_g_c_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), script.root_metabolism_parameters.nitrogen_assimilation_respiration_g_c_per_g_n, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.6), script.root_metabolism_parameters.root_protein_carbon_per_nitrogen_g_c_per_g_n, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.87), script.root_metabolism_parameters.nutrient_uptake_respiration_g_c_per_g_element, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.16), script.root_metabolism_parameters.minimum_carbon_recycling_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.6e-5), script.root_metabolism_parameters.storage_exchange_fraction_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 8.31), script.root_metabolism_parameters.maintenance_gas_constant_j_per_mol_k, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), script.root_metabolism_parameters.acidity_half_effect_hydrogen_activity_mol_per_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4.1), script.root_metabolism_parameters.deeper_primary_root_sink_multiplier, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 337), script.root_metabolism_parameters.annual_termination_hours_without_grain_fill, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.76), script.root_metabolism_parameters.evergreen_leafoff_remobilization_start_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.51), script.root_metabolism_parameters.deciduous_leafoff_remobilization_start_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 481), script.root_metabolism_parameters.full_senescence_duration_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.74), script.organ_partition_parameters.initial_leaf_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.02), script.organ_partition_parameters.leaf_reduction_by_turnover[3], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.12), script.organ_partition_parameters.low_reserve_redirect_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.016), script.shoot_metabolism_parameters.maximum_mobile_carbon_oxidation_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.34), script.shoot_metabolism_parameters.minimum_leaf_nutrient_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.71), script.shoot_metabolism_parameters.nitrogen_assimilation_respiration_g_c_per_g_n, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.11), script.shoot_metabolism_parameters.mobile_nitrogen_inhibition_g_n_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.334), script.shoot_node_growth_parameters.leaf_mass_exponent, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.2), script.shoot_node_growth_parameters.minimum_internode_carbon_g_c_per_m2_cell, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.051), script.shoot_node_growth_parameters.branch_reserve_nutrient_exchange_fraction_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 73), script.shoot_node_growth_parameters.physiological_maturity_no_fill_h, 1.0e-15);
    try std.testing.expectEqual(@as(usize, 23), script.shoot_node_growth_parameters.maximum_previous_stalk_nodes_in_rolling_window);
    try std.testing.expectEqual(@as([4]f64, .{ 361, 1441, 721, 722 }), script.shoot_node_growth_parameters.annual_leafoff_delay_h_by_phenology);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00052), script.shoot_node_growth_parameters.leaf_storage_exchange_fraction_per_h_by_turnover[5], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.884e-3), script.seasonal_turnover_parameters.litterfall_rate_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 240), script.seasonal_turnover_parameters.litterfall_delay_threshold_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.012), script.branch_mobile_exchange_parameters.carbon_exchange_fraction_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.013), script.branch_mobile_exchange_parameters.nutrient_exchange_fraction_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.014), script.branch_mobile_exchange_parameters.remobilization_redistribution_fraction_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00011), script.symbiotic_fixation_parameters.initial_bacterial_carbon_g_c_per_m2, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.101), script.symbiotic_fixation_parameters.nitrogen_inhibition_g_n_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0101), script.symbiotic_fixation_parameters.phosphorus_inhibition_g_p_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.052), script.symbiotic_fixation_parameters.host_exchange_fraction_per_h_by_fixation_type[5], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.013), script.symbiotic_fixation_parameters.decomposition_control_ratio_by_fixation_type[5], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 474.15), script.plant_fire_combustion_parameters.minimum_combustion_temperature_k, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 901), script.plant_fire_combustion_parameters.mobile_and_leaf_specific_combustion_g_c_per_m2_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 903), script.plant_fire_combustion_parameters.root_structural_specific_combustion_g_c_per_m2_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 905), script.plant_fire_combustion_parameters.standing_dead_specific_combustion_g_c_per_m2_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 120001), script.plant_fire_combustion_parameters.charcoal_activation_energy_j_per_mol, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), script.plant_fire_combustion_parameters.charcoal_specific_combustion_g_c_per_m2_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.668), script.plant_fire_combustion_parameters.oxygen_g_per_g_combusted_carbon, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.51), script.plant_fire_combustion_parameters.maximum_anaerobic_charcoal_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0744), script.plant_fire_combustion_parameters.methane_combustion_energy_megajoules_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 475.15), script.soil_fire_combustion_parameters.minimum_combustion_temperature_k, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 5001), script.soil_fire_combustion_parameters.specific_combustion_by_substrate_g_c_per_m2_h[1], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), script.soil_fire_combustion_parameters.charcoal_specific_combustion_g_c_per_m2_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.9), script.soil_fire_combustion_parameters.oxygen_half_saturation_g_o_per_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.006), script.soil_fire_combustion_parameters.methane_half_saturation_g_c_per_m3, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.051), script.shoot_root_exchange_parameters.minimum_partner_structural_ratio, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0051), script.shoot_root_exchange_parameters.minimum_annual_carbon_exchange_fraction_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.91), script.shoot_root_exchange_parameters.salt_exchange_fraction_per_h, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 46), script.storage_remobilization_parameters.remobilization_duration_h[0], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.16), script.storage_remobilization_parameters.perennial_nutrient_equilibration_fraction_per_h[5], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.051), script.storage_remobilization_parameters.minimum_mobile_nitrogen_per_carbon_g_n_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.21), script.storage_remobilization_parameters.maximum_mobile_nitrogen_per_carbon_g_n_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0051), script.storage_remobilization_parameters.minimum_mobile_phosphorus_per_carbon_g_p_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.021), script.storage_remobilization_parameters.maximum_mobile_phosphorus_per_carbon_g_p_per_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.11), script.storage_remobilization_parameters.depleted_storage_threshold_g_c_per_g_root_c, 1.0e-15);
}

test "HFUNC phenology coefficients are case-insensitive runtime inputs" {
    const source =
        \\1,1,9
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\CaNoPy_StReSs|25|61|0.03|8.31|711|25.3|62600|197600|222600
        \\PhEnOlOgY_CoNtRoLs|8.3143|710|24.269|60000|197500|218500|0.1|0.25|2|0.667|-0.1|-150|-1.5|3600|1e-6|1e-6
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 9), script.plant_species_count);
    try std.testing.expectEqual(@as(f64, 25), script.canopy_stress_parameters.maximum_chilling_h);
    try std.testing.expectEqual(@as(f64, 61), script.canopy_stress_parameters.heat_accumulation_threshold_c);
    try std.testing.expectEqual(@as(f64, 0.03), script.canopy_stress_parameters.heat_recovery_per_h);
    try std.testing.expectEqual(@as(f64, 62600), script.canopy_stress_parameters.growth_temperature.activation_energy_j_per_mol);
    try std.testing.expectEqual(@as(f64, 222600), script.canopy_stress_parameters.growth_temperature.high_temperature_inactivation_j_per_mol);
    try std.testing.expectApproxEqAbs(@as(f64, 24.269), script.phenology_parameters.arrhenius_log_prefactor, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), script.phenology_parameters.oxygen_stress_exponent, 1.0e-15);
}

test "HFUNC plant pool thresholds are case-insensitive runtime inputs" {
    const source =
        \\1,1,8
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\PlAnT_PoOl_CoNtRoLs|YeS|2e-15|4e-6|2e-6|3e-6|0.02|0.002
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expect(script.dynamic_plant_salts);
    try std.testing.expectApproxEqAbs(@as(f64, 4e-6), script.plant_pool_parameters.grain_fill_detection_g_c_per_plant, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), script.plant_pool_parameters.nitrogen_inhibition_g_n_per_g_c, 1.0e-15);
}

test "GROSUB seed set half saturations are case-insensitive runtime inputs" {
    const source =
        \\1,1,8
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\SeEd_SeT_CoNtRoLs|0.03|0.006|0.0012
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), script.seed_set_parameters.carbon_half_saturation_g_per_g, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0012), script.seed_set_parameters.phosphorus_half_saturation_g_per_g, 1.0e-15);
}

test "plant nutrient initial zone and phosphate fractions are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\PlAnT_NuTrIeNtS,0.2,0.3,0.4,0.65,0.5,0.6,0.7
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), script.plant_nutrient_initialization.initial_ammonium_band_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.65), script.plant_nutrient_initialization.initial_h2po4_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), script.plant_nutrient_initialization.initial_nitrate_band_row_spacing_m, 1.0e-15);
}

test "organic initialization parameter filename is case insensitive and extension agnostic" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\OrGaNiC_InItIaLiZaTiOn_FiLe|organic-parameters
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqualStrings("organic-parameters", script.organic_initialization_file);
    try std.testing.expectEqualStrings("grid_inputs", script.grid_input_file);
}

test "surface gas parameter filename is case insensitive and extension agnostic" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\SuRfAcE_GaS_PaRaMeTeR_FiLe|surface-gas.csv
        \\SoIl_NiTrOgEn_PaRaMeTeR_FiLe|soil-nitrogen
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqualStrings("surface-gas.csv", script.surface_gas_parameter_file);
    try std.testing.expectEqualStrings("soil-nitrogen", script.soil_nitrogen_parameter_file);
    try std.testing.expectEqualStrings("grid_inputs", script.grid_input_file);
}

test "STARTE initial phosphate constants are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\ChEmIsTrY_InItIaLiZaTiOn,0.01,1e-8,1.9e-21,6.3e-26,7.5,6.2e-5,4.8e-10
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), script.chemistry_initialization.saturated_paste_phosphate_multiplier, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 6.2e-5), script.chemistry_initialization.phosphate_dissociation.h2po4_to_hpo4_mol_per_m3, 1.0e-15);
}

test "STARTE molar masses and extract conversions are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\chemistry_initialization,0.01,1e-8,1.9e-21,6.3e-26,7.5,6.2e-5,4.8e-10
        \\ChEmIsTrY_UnItS,14,31,27,56,40,24.3,23,39.1,32,35.5,1,1,0.01,1
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 24.3), script.chemistry_primary_initialization.molar_mass_g_per_mol.magnesium, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), script.chemistry_primary_initialization.soil_ammonium_extract_multiplier, 1e-15);
}

test "soil solver scientific coefficients and class count are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\Soil_Solver,-0.0004,-1e10,200000,0.25,-0.2,0.3,5e-7,0.02,0.4,3e-7,0.08,0.2,0.3,0.6,0.7,0.05,0.16,0.23,0.74,0.72,0.55,0.45,73,1.4,0.12,1.5,0.03,0.11,70,2e-15,0.067,0.125,890,10000,0.8,0.0125,120,10000,0.52,10,1.82,200,80,20,5,1,1
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 73), script.soil_solver_parameters.hydraulic_conductivity_class_count);
    try std.testing.expectApproxEqAbs(@as(f64, -0.0004), script.soil_solver_parameters.retention.saturation_water_potential_megapascal, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4), script.soil_solver_parameters.pore_interaction_exponent, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 70), script.soil_solver_parameters.organic_saturated_conductivity_scale_m2_per_h_megapascal, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 890), script.soil_solver_parameters.profile_derivation.organic_nitrogen_scale_g_per_megagram, 1e-15);
}

test "runtime nonlinear ceiling clamps initialization retention fit" {
    const source =
        \\1,1,2
        \\runtime,1,1,1e-9,1e-12,3,0.5
        \\Soil_Solver,-0.0004,-1e10,200000,0.25,-0.2,0.3,5e-7,0.02,0.4,3e-7,0.08,0.2,0.3,0.6,0.7,0.05,0.16,0.23,0.74,0.72,0.55,0.45,73,1.4,0.12,1.5,0.03,0.11,70,2e-15,0.067,0.125,890,10000,0.8,0.0125,120,10000,0.52,10,1.82,200,80,20,5,1,1
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 3), script.soil_solver_parameters.mualem_van_genuchten_fit_max_iterations);
}

test "soil process coefficients are runtime inputs and tag is case insensitive" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\SoIl_PrOcEsS,0.0097,0.08,300,1.8,0.65,0.04,0.0006,1.1e-6,0.52,0.025
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), script.soil_process_parameters.reference_water_vapor_diffusivity_m2_per_h, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), script.soil_process_parameters.osmotic_reflection_coefficient, 1e-15);
}

test "macropore van Genuchten shape is a case-insensitive runtime record" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\MaCrOpOrE_VaN_GeNuChTeN|0.01|16.5|2.75|0.45
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), script.soil_process_parameters.macropore_residual_saturation, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 16.5), script.soil_process_parameters.macropore_van_genuchten_alpha_per_m, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.75), script.soil_process_parameters.macropore_van_genuchten_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.45), script.soil_process_parameters.macropore_pore_connectivity, 1e-15);
}

test "dual domain exchange coefficients are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\DuAl_DoMaIn_ExChAnGe,4.5,0.35
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), script.soil_process_parameters.dual_domain_geometry_factor, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.35), script.soil_process_parameters.dual_domain_scaling_coefficient, 1e-15);
}

test "frozen hydraulic impedance exponent is a case-insensitive runtime input" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\FrOzEn_HyDrAuLiC_ImPeDaNcE|6.25
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(
        @as(f64, 6.25),
        script.soil_process_parameters.frozen_hydraulic_impedance_exponent,
        1e-15,
    );
}

test "surface residue freeze thaw retention is a case-insensitive runtime input" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\SuRfAcE_ReSiDuE_FrEeZe_ThAw|0.03|250|2.2
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), script.soil_process_parameters.surface_residue_residual_water_content_m3_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 250), script.soil_process_parameters.surface_residue_van_genuchten_alpha_per_m, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.2), script.soil_process_parameters.surface_residue_van_genuchten_n, 1e-15);
}

test "REDIST soil geometry coefficients are case-insensitive runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\SoIl_GeOmEtRy|1.9e-6|120000|0.081|2e-9
        \\SuRfAcE_PoNd_EnErGy|2.6e-6|9e-4
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 1.9e-6), script.soil_geometry_parameters.organic_carbon_specific_volume_m3_per_g, 1e-18);
    try std.testing.expectEqual(@as(f64, 120_000), script.soil_geometry_parameters.organic_horizon_threshold_g_c_per_megagram);
    try std.testing.expectApproxEqAbs(@as(f64, 0.081), script.soil_geometry_parameters.ice_to_water_specific_volume_difference, 1e-15);
    try std.testing.expectEqual(@as(f64, 2e-9), script.soil_geometry_parameters.minimum_layer_thickness_m);
    try std.testing.expectEqual(@as(f64, 2.6e-6), script.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k);
    try std.testing.expectEqual(@as(f64, 9e-4), script.surface_pond_activation_heat_capacity_megajoules_per_m2_k);
}

test "seven gas diffusivities and transport constants are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\SoIl_GaS_TrAnSpOrT|299|1.8|0.041|0.072|0.063|0.054|0.055|0.066|0.057|0.64|1e-10|998000|18.1
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 299), script.soil_gas_transport_parameters.reference_temperature_k, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.041), script.soil_gas_transport_parameters.free_air_diffusivity_m2_per_h[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.057), script.soil_gas_transport_parameters.free_air_diffusivity_m2_per_h[6], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 18.1), script.soil_gas_transport_parameters.water_molar_mass_g_per_mol, 1e-15);
}

test "surface runoff controls accept mixed delimiters and case" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\SuRfAcE_RuNoFf|0.006|0.012|0.0009|3601|2e-12
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.006), script.surface_runoff_parameters.ground_surface_retention_m3_per_m2, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0009), script.surface_runoff_parameters.maximum_hydraulic_depth_m, 1e-15);
}

test "rainfall impact coefficients are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\RaInFaLl_ImPaCt,9,8,16,6,3,1.9,0.002,0.0007
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 16), script.rainfall_impact_parameters.throughfall_energy_height_coefficient_j_per_mm_sqrt_m, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.002), script.rainfall_impact_parameters.conductivity_damage_per_j_per_megagram_per_megagram, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0007), script.rainfall_impact_parameters.conductivity_recovery_fraction_per_h, 1e-15);
}

test "soil phase and heat coefficients are runtime inputs" {
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\soil_phase_heat,0.002,0.62,5300,0.0036,18.1,8.31,2400,90000,330,0.92,0.006,273.2,0.3,0.34,1e10,8e10,1.2,1.3,9000,4.2,1.9
        \\GeOtHeRmAl,YeS,12,1.5,0.009,0.00021
        \\SuBsUrFaCe_StAtE,0.002,0.000003
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 2400), script.soil_phase_heat_parameters.vapor_equilibrium.latent_heat_of_vaporization_megajoules_per_m3);
    try std.testing.expectEqual(@as(f64, 9000), script.soil_phase_heat_parameters.heat_turbulence.maximum_rayleigh_number);
    try std.testing.expectEqual(@as(f64, 4.2), script.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k);
    try std.testing.expect(script.geothermal_controls.enabled);
    try std.testing.expectEqual(@as(f64, 12), script.geothermal_controls.minimum_source_depth_m);
    try std.testing.expectEqual(@as(f64, 0.00021), script.geothermal_controls.geothermal_flux_megajoules_per_m2_h);
    try std.testing.expectEqual(@as(f64, 0.002), script.water_table_air_fraction_threshold);
    try std.testing.expectEqual(@as(f64, 0.000003), script.active_layer_ice_fraction_threshold);
}

test "surface energy controls are tagged and case insensitive" {
    const source =
        \\1,1,8
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\Runtime,2,64,1e-8,1e-11,40,0.5
        \\Surface_Energy,0.95,0.98,0.96,0.08,0.5,0.12,0.9,180,380
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), script.soil_longwave_emissivity, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.98), script.snow_longwave_emissivity, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.96), script.canopy_longwave_emissivity, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), script.snow_full_cover_depth_m, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), script.surface_sensible_heat_conductance_megajoules_per_m2_h_k, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.12), script.surface_latent_heat_conductance_megajoules_per_m2_h_kpa, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), script.surface_vapor_activity_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 180), script.minimum_surface_temperature_k, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 380), script.maximum_surface_temperature_k, 1.0e-15);
}

test "canopy surface exchange coefficients are runtime and case insensitive" {
    const source =
        \\1,1,8
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\runtime,1,1,1e-8,1e-11,40,0.5
        \\CaNoPy_SuRfAcE_ExChAnGe,0.0015,0.028,0.0014,0.014,17.9,8.314,4.18,0.003,0.03
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 0.0015), script.canopy_sensible_surface_resistance_h_per_m);
    try std.testing.expectEqual(@as(f64, 0.028), script.canopy_latent_surface_resistance_h_per_m);
    try std.testing.expectEqual(@as(f64, 0.0014), script.canopy_surface_exchange_parameters.minimum_boundary_resistance_h_per_m);
    try std.testing.expectEqual(@as(f64, 0.014), script.canopy_surface_exchange_parameters.maximum_boundary_resistance_h_per_m);
    try std.testing.expectEqual(@as(f64, 17.9), script.canopy_surface_exchange_parameters.water_potential_vapor_coefficient_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 8.314), script.canopy_surface_exchange_parameters.universal_gas_constant_j_per_mol_k);
    try std.testing.expectEqual(@as(f64, 4.18), script.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k);
    try std.testing.expectEqual(@as(f64, 0.003), script.canopy_minimum_resistance_h_per_m);
    try std.testing.expectEqual(@as(f64, 0.03), script.canopy_maximum_resistance_h_per_m);
}

test "canopy ammonia exchange coefficients are runtime and case insensitive" {
    const source =
        \\1,1,8
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\runtime,1,1,1e-8,1e-11,40,0.5
        \\CaNoPy_AmMoNiA_ExChAnGe,0.17,0.11,0.06,2.1,0.00012,0.09,0.52,0.018
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 0.17), script.canopy_ammonia_exchange_parameters.minimum_canopy_dry_matter_fraction);
    try std.testing.expectEqual(@as(f64, 0.11), script.canopy_ammonia_exchange_parameters.water_potential_dry_matter_increment);
    try std.testing.expectEqual(@as(f64, 0.06), script.canopy_ammonia_exchange_parameters.water_potential_denominator_per_megapascal);
    try std.testing.expectEqual(@as(f64, 0.09), script.canopy_ammonia_exchange_parameters.maximum_mobile_nitrogen_transfer_fraction_per_step);
    try std.testing.expectEqual(@as(f64, 0.018), script.canopy_ammonia_exchange_parameters.solubility_temperature_coefficient_per_c);
}

test {
    // Keeps the extracted tests discoverable by `zig build test`,
    // which only reaches files reachable by import.
    _ = @import("runscript_test.zig");
}

test "AIRFRAC-F1 one runtime field feeds both the saturation and the gas-face air threshold" {
    // Legacy carries a single constant: hour1.f:119 THETPW = 1.0E-03 is the
    // minimum air-filled porosity for saturation, and starts.f:97 THETX =
    // 1.0E-03 is the minimum THETPM for gas transport (uptake.f:2344). The
    // translation exposed two runtime fields, and the shipped Ottawa deck sets
    // them to 1e-3 and 1e-12 respectively. Between those two values a layer is
    // simultaneously below the internal water table and an open gas face; both
    // budgets still close individually, so no rung of the balance audit can see
    // it. This asserts the two consumers cannot be given different values.
    //
    // The `soil_gas_transport` record deliberately still parses its field, so
    // shipped decks keep their column layout, but the parsed value is dropped.
    // Hence the fixture below sets it to a value that must NOT survive.
    const source =
        \\1,1,2
        \\geospatial_grid,45,46,-75,-74,1,1
        \\tile_layout,1,1,2
        \\soil_gas_transport,299,1.8,0.041,0.072,0.063,0.054,0.055,0.066,0.057,0.64,1e-12,998000,18.1
        \\subsurface_state,2.5e-3,1e-6
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    var script = try parseStrictParameterFixture(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(f64, 2.5e-3), script.water_table_air_fraction_threshold);
    try std.testing.expectEqual(
        script.water_table_air_fraction_threshold,
        script.soil_gas_transport_parameters.minimum_air_filled_porosity_m3_per_m3,
    );
}

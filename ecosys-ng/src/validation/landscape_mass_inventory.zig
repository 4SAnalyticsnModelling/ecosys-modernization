//! `landscape_mass_inventory`.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_canopy = @import("landscape_mass_inventory_canopy.zig");
const group_gas = @import("landscape_mass_inventory_gas.zig");
const group_misc = @import("landscape_mass_inventory_misc.zig");
const group_plant = @import("landscape_mass_inventory_plant.zig");
const group_nitrogen = @import("landscape_mass_inventory_nitrogen.zig");
const group_organic = @import("landscape_mass_inventory_organic.zig");
const group_phosphorus_ions = @import("landscape_mass_inventory_phosphorus_ions.zig");
const group_snow = @import("landscape_mass_inventory_snow.zig");
const group_support = @import("landscape_mass_inventory_support.zig");
const group_surface = @import("landscape_mass_inventory_surface.zig");
const group_tests = @import("landscape_mass_inventory_tests.zig");

// canopy
pub const aggregateCanopyWaterAndHeat = group_canopy.aggregateCanopyWaterAndHeat;
pub const aggregateCanopyWaterAndHeatCell = group_canopy.aggregateCanopyWaterAndHeatCell;

// gas
pub const aggregateSoilPhysicalAndGas = group_gas.aggregateSoilPhysicalAndGas;
pub const aggregateSoilPhysicalAndGasCell = group_gas.aggregateSoilPhysicalAndGasCell;
pub const aggregateRootGas = group_gas.aggregateRootGas;
pub const aggregateRootGasCell = group_gas.aggregateRootGasCell;

// misc
pub const aggregateSoilMineralTexture = group_misc.aggregateSoilMineralTexture;
pub const aggregateSoilMineralTextureCell = group_misc.aggregateSoilMineralTextureCell;
pub const aggregateSuspendedConstituents = group_misc.aggregateSuspendedConstituents;
pub const aggregateSuspendedConstituentsCell = group_misc.aggregateSuspendedConstituentsCell;
pub const aggregateSuspendedComponentAmounts = group_misc.aggregateSuspendedComponentAmounts;

// nitrogen
pub const aggregateProfileMineralNitrogen = group_nitrogen.aggregateProfileMineralNitrogen;
pub const aggregateProfileMineralNitrogenCell = group_nitrogen.aggregateProfileMineralNitrogenCell;

// organic
pub const aggregateSurfaceOrganic = group_organic.aggregateSurfaceOrganic;
pub const aggregateSurfaceOrganicCell = group_organic.aggregateSurfaceOrganicCell;
pub const aggregateSoilOrganic = group_organic.aggregateSoilOrganic;
pub const aggregateSoilOrganicCell = group_organic.aggregateSoilOrganicCell;
pub const aggregateSoilOrganicTransportMacropore = group_organic.aggregateSoilOrganicTransportMacropore;
pub const aggregateSoilOrganicTransportMacroporeCell = group_organic.aggregateSoilOrganicTransportMacroporeCell;

// plant
pub const aggregatePlantCarbonNitrogenPhosphorus = group_plant.aggregatePlantCarbonNitrogenPhosphorus;
pub const aggregatePlantCarbonNitrogenPhosphorusCell = group_plant.aggregatePlantCarbonNitrogenPhosphorusCell;

// phosphorus ions
pub const aggregateProfilePhosphorusAndIons = group_phosphorus_ions.aggregateProfilePhosphorusAndIons;
pub const aggregateProfilePhosphorusAndIonsCell = group_phosphorus_ions.aggregateProfilePhosphorusAndIonsCell;
// ISSUE-065 ninth pass: exposes the single-layer variant already used in
// production (`layer_mass_inventory.zig`) so a stage-boundary diagnostic can
// call the exact same authoritative computation the failing hourly gate uses
// for `carbon_dioxide_carbon_g`, without duplicating its arithmetic.
pub const aggregateProfilePhosphorusAndIonsLayer = group_phosphorus_ions.aggregateProfilePhosphorusAndIonsLayer;
pub const aggregatePendingSurfaceMinerals = group_phosphorus_ions.aggregatePendingSurfaceMinerals;
pub const aggregatePendingSurfaceMineralsCell = group_phosphorus_ions.aggregatePendingSurfaceMineralsCell;
pub const aggregatePendingPlantLitterSalts = group_phosphorus_ions.aggregatePendingPlantLitterSalts;
pub const aggregatePendingPlantLitterSaltsCell = group_phosphorus_ions.aggregatePendingPlantLitterSaltsCell;
pub const debugIonSubcomponents = group_phosphorus_ions.debugIonSubcomponents;
pub const debugDissolvedAqueousPerSpecies = group_phosphorus_ions.debugDissolvedAqueousPerSpecies;
pub const IonSubcomponents = group_phosphorus_ions.IonSubcomponents;

// snow
pub const aggregateSnow = group_snow.aggregateSnow;
pub const aggregateSnowEnthalpy = group_snow.aggregateSnowEnthalpy;
pub const aggregateSnowEnthalpyCell = group_snow.aggregateSnowEnthalpyCell;
pub const SnowMolarMassesGPerMol = group_snow.MolarMassesGPerMol;

// support
pub const Storage = group_support.Storage;
pub const ElementMoles = group_support.ElementMoles;
pub const aqueousSpeciesElements = group_support.aqueousSpeciesElements;
pub const publishStorage = group_support.publishStorage;
pub const default_latent_heat_of_fusion_megajoules_per_m3 = group_support.default_latent_heat_of_fusion_megajoules_per_m3;
pub const default_pure_water_melting_temperature_k = group_support.default_pure_water_melting_temperature_k;
pub const frozenWaterEnthalpyPerM3 = group_support.frozenWaterEnthalpyPerM3;

// surface
pub const aggregateSurfaceChemistry = group_surface.aggregateSurfaceChemistry;
pub const aggregateSurfaceChemistryCell = group_surface.aggregateSurfaceChemistryCell;
pub const aggregateSurfaceTransportComplexes = group_surface.aggregateSurfaceTransportComplexes;
pub const aggregateSurfaceTransportComplexesCell = group_surface.aggregateSurfaceTransportComplexesCell;
pub const aggregatePendingSurfaceFire = group_surface.aggregatePendingSurfaceFire;
pub const aggregatePendingSurfaceFireCell = group_surface.aggregatePendingSurfaceFireCell;
pub const SurfacePhysicalParameters = group_surface.SurfacePhysicalParameters;
pub const aggregateSurfacePhysicalAndGas = group_surface.aggregateSurfacePhysicalAndGas;
pub const aggregateSurfacePhysicalAndGasCell = group_surface.aggregateSurfacePhysicalAndGasCell;

// tests

test {
    // A bare reference is what makes `zig build test` reach a file.
    _ = group_misc;
    _ = group_phosphorus_ions;
    _ = group_snow;
    _ = group_plant;
    _ = @import("landscape_mass_inventory_tests.zig");
    _ = @import("landscape_mass_inventory_test.zig");
}

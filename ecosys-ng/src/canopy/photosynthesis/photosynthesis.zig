//! `photosynthesis`.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_grazing = @import("photosynthesis_grazing.zig");
const group_harvest = @import("photosynthesis_harvest.zig");
const group_misc = @import("photosynthesis_misc.zig");
const group_mobile = @import("photosynthesis_mobile.zig");
const group_node_layer = @import("photosynthesis_node_layer.zig");
const group_organ_growth = @import("photosynthesis_organ_growth.zig");
const group_reproductive = @import("photosynthesis_reproductive.zig");
const group_senescence = @import("photosynthesis_senescence.zig");
const group_state = @import("photosynthesis_state.zig");
const group_tests = @import("photosynthesis_tests.zig");

// grazing
pub const sourceOrderNonGrazingMobileRetention = group_grazing.sourceOrderNonGrazingMobileRetention;
pub const GrazingPools = group_grazing.GrazingPools;
pub const GrazingAllocation = group_grazing.GrazingAllocation;
pub const SourceOrderAdditionalGrazingRemoval = group_grazing.SourceOrderAdditionalGrazingRemoval;
pub const sourceOrderAdditionalGrazingRemoval = group_grazing.sourceOrderAdditionalGrazingRemoval;
pub const allocateGrazingDemand = group_grazing.allocateGrazingDemand;
pub const grazingCarbonDemandGPerH = group_grazing.grazingCarbonDemandGPerH;
pub const sourceOrderGrazingCarbonDemandGPerH = group_grazing.sourceOrderGrazingCarbonDemandGPerH;

// harvest
pub const HarvestProducts = group_harvest.HarvestProducts;
pub const ReproductiveHarvestResult = group_harvest.ReproductiveHarvestResult;
pub const harvestReproductiveOrgans = group_harvest.harvestReproductiveOrgans;
pub const cuttingHeightForLeafAreaRemoval = group_harvest.cuttingHeightForLeafAreaRemoval;
pub const harvestBranchStalkAndReserve = group_harvest.harvestBranchStalkAndReserve;
pub const harvestBranchMobilePools = group_harvest.harvestBranchMobilePools;
pub const harvestBranchMobilePoolsWithIntermediateRetention = group_harvest.harvestBranchMobilePoolsWithIntermediateRetention;

// misc
pub const C4CarbonFluxes = group_misc.C4CarbonFluxes;
pub const C4CarbonParameters = group_misc.C4CarbonParameters;
pub const sourceC4CarbonParameters = group_misc.sourceC4CarbonParameters;
pub const advanceC4CarbonPools = group_misc.advanceC4CarbonPools;
pub const LeafNutrientRemobilization = group_misc.LeafNutrientRemobilization;
pub const sourceOrderC4IntermediateRetention = group_misc.sourceOrderC4IntermediateRetention;

// mobile
pub const BranchMobilePoolFluxes = group_mobile.BranchMobilePoolFluxes;
pub const BranchMobilePools = group_mobile.BranchMobilePools;
pub const previewBranchMobilePools = group_mobile.previewBranchMobilePools;
pub const updateBranchMobilePools = group_mobile.updateBranchMobilePools;
pub const ReserveFallbackPolicy = group_mobile.ReserveFallbackPolicy;
pub const consumeReserveForRespiration = group_mobile.consumeReserveForRespiration;
pub const ReserveExchange = group_mobile.ReserveExchange;
pub const SourceOrderMobileRemoval = group_mobile.SourceOrderMobileRemoval;
pub const sourceOrderProportionalMobileRemoval = group_mobile.sourceOrderProportionalMobileRemoval;
pub const equilibrateBranchReserves = group_mobile.equilibrateBranchReserves;

// node layer
pub const LayerLeafOutputs = group_node_layer.LayerLeafOutputs;
pub const allocateLeafAcrossCanopyLayers = group_node_layer.allocateLeafAcrossCanopyLayers;
pub const StalkLayerAllocation = group_node_layer.StalkLayerAllocation;
pub const allocateStalkAcrossCanopyLayers = group_node_layer.allocateStalkAcrossCanopyLayers;
pub const NodeSenescenceAllocation = group_node_layer.NodeSenescenceAllocation;
pub const allocateNodeSenescenceDemand = group_node_layer.allocateNodeSenescenceDemand;
pub const state_updateNodeSenescenceDemand = group_node_layer.state_updateNodeSenescenceDemand;
pub const InternodeSenescenceResult = group_node_layer.InternodeSenescenceResult;
pub const state_updateInternodeSenescenceDemand = group_node_layer.state_updateInternodeSenescenceDemand;
pub const remobilizeNodeLeafNutrients = group_node_layer.remobilizeNodeLeafNutrients;
pub const SourceOrderGrazingNodeRemoval = group_node_layer.SourceOrderGrazingNodeRemoval;
pub const sourceOrderGrazingNodeRemoval = group_node_layer.sourceOrderGrazingNodeRemoval;
pub const sourceOrderBranchLayerLeafDemand = group_node_layer.sourceOrderBranchLayerLeafDemand;
pub const LayerHarvestRetention = group_node_layer.LayerHarvestRetention;
pub const RemainingNodeLeaf = group_node_layer.RemainingNodeLeaf;
pub const sourceOrderRemainingNodeLeaf = group_node_layer.sourceOrderRemainingNodeLeaf;
pub const sourceOrderNodeOrganRetention = group_node_layer.sourceOrderNodeOrganRetention;
pub const layerHarvestRetention = group_node_layer.layerHarvestRetention;
pub const LayerLeafHarvestProducts = group_node_layer.LayerLeafHarvestProducts;
pub const NodeOrganHarvestProducts = group_node_layer.NodeOrganHarvestProducts;
pub const harvestLeafLayerSample = group_node_layer.harvestLeafLayerSample;
pub const harvestNodeSheath = group_node_layer.harvestNodeSheath;
pub const internodeHarvestRetention = group_node_layer.internodeHarvestRetention;
pub const state_updateInternodeHarvest = group_node_layer.state_updateInternodeHarvest;
pub const SelectedNodeSenescenceRequest = group_node_layer.SelectedNodeSenescenceRequest;
pub const state_updateSelectedNodeSenescence = group_node_layer.state_updateSelectedNodeSenescence;
pub const senesceLeafAndSheathNode = group_node_layer.senesceLeafAndSheathNode;

// organ growth
pub const LeafGrowth = group_organ_growth.LeafGrowth;
pub const Organ = group_organ_growth.Organ;
pub const organ_count = group_organ_growth.organ_count;
pub const OrganGrowth = group_organ_growth.OrganGrowth;
pub const calculateOrganGrowth = group_organ_growth.calculateOrganGrowth;
pub const applyBranchOrganGrowth = group_organ_growth.applyBranchOrganGrowth;
pub const validateBranchOrganGrowthTransaction = group_organ_growth.validateBranchOrganGrowthTransaction;
pub const distributeLeafGrowth = group_organ_growth.distributeLeafGrowth;
pub const distributeSheathGrowth = group_organ_growth.distributeSheathGrowth;
pub const CanopyWaterGrowthResponse = group_organ_growth.CanopyWaterGrowthResponse;
pub const canopyWaterGrowthResponse = group_organ_growth.canopyWaterGrowthResponse;
pub const RecyclingFractions = group_organ_growth.RecyclingFractions;
pub const recyclingFractions = group_organ_growth.recyclingFractions;
pub const KineticFractions = group_organ_growth.KineticFractions;

// reproductive
pub const PersistentReseedInventories = group_reproductive.PersistentReseedInventories;
pub const capturePersistentReseedInventories = group_reproductive.capturePersistentReseedInventories;
pub const restorePersistentReseedInventories = group_reproductive.restorePersistentReseedInventories;
pub const StalkGrowthResult = group_reproductive.StalkGrowthResult;
pub const accumulatePotentialSeedSites = group_reproductive.accumulatePotentialSeedSites;
pub const SeedSetInputs = group_reproductive.SeedSetInputs;
pub const SeedSetParameters = group_reproductive.SeedSetParameters;
pub const compatibilitySeedSetParameters = group_reproductive.compatibilitySeedSetParameters;
pub const SeedSetResult = group_reproductive.SeedSetResult;
pub const updateSeedNumberAndSize = group_reproductive.updateSeedNumberAndSize;
pub const distributeStalkGrowth = group_reproductive.distributeStalkGrowth;
pub const GrainFillResult = group_reproductive.GrainFillResult;
pub const ReproductiveRetention = group_reproductive.ReproductiveRetention;
pub const SourceOrderReproductiveRetentionInput = group_reproductive.SourceOrderReproductiveRetentionInput;
pub const sourceOrderReproductiveRetention = group_reproductive.sourceOrderReproductiveRetention;
pub const reproductiveRetention = group_reproductive.reproductiveRetention;
pub const sourceOrderBranchStalkRetention = group_reproductive.sourceOrderBranchStalkRetention;
pub const sourceOrderStalkReserveRetention = group_reproductive.sourceOrderStalkReserveRetention;
pub const fillGrainFromReserve = group_reproductive.fillGrainFromReserve;

// senescence
pub const SenescenceProducts = group_senescence.SenescenceProducts;
pub const addSenescenceProducts = group_senescence.addSenescenceProducts;
pub const state_updateResidualStalkSenescenceDemand = group_senescence.state_updateResidualStalkSenescenceDemand;
pub const SenescenceLitterParameters = group_senescence.SenescenceLitterParameters;
pub const BranchSenescenceRequest = group_senescence.BranchSenescenceRequest;
pub const BranchSenescenceResult = group_senescence.BranchSenescenceResult;
pub const state_updateBranchSenescenceDemand = group_senescence.state_updateBranchSenescenceDemand;
pub const SenescenceDemand = group_senescence.SenescenceDemand;
pub const senescenceDemand = group_senescence.senescenceDemand;

// state
pub const State = group_state.State;
pub const Range = group_state.Range;
pub const ElementalMass = group_state.ElementalMass;

// tests

test {
    // A bare reference is what makes `zig build test` reach a file.
    _ = group_state;
    _ = group_node_layer;
    _ = @import("photosynthesis_tests.zig");
    _ = @import("../../validation/canopy_photosynthesis_test.zig");
}

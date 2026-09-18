//! `plant_root_metabolism`.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_axis_sink = @import("plant_root_metabolism_axis_sink.zig");
const group_state_update = @import("plant_root_metabolism_state_update.zig");
const group_growth = @import("plant_root_metabolism_growth.zig");
const group_litter = @import("plant_root_metabolism_litter.zig");
const group_misc = @import("plant_root_metabolism_misc.zig");
const group_respiration = @import("plant_root_metabolism_respiration.zig");

// axis sink
pub const PrimaryRootAxisScaling = group_axis_sink.PrimaryRootAxisScaling;
pub const primaryRootAxisScaling = group_axis_sink.primaryRootAxisScaling;
pub const RootAxisSinkInputs = group_axis_sink.RootAxisSinkInputs;
pub const SourceOrderRootAxisSinkInputs = group_axis_sink.SourceOrderRootAxisSinkInputs;
pub const RootAxisSinkStrength = group_axis_sink.RootAxisSinkStrength;
pub const secondaryRootAxisActive = group_axis_sink.secondaryRootAxisActive;
pub const rootAxisSinkStrength = group_axis_sink.rootAxisSinkStrength;
pub const sourceOrderRootAxisSinkStrength = group_axis_sink.sourceOrderRootAxisSinkStrength;
pub const normalizeRootAxisSinkFractions = group_axis_sink.normalizeRootAxisSinkFractions;

// state_update
pub const SecondaryRootStateUpdateInputs = group_state_update.SecondaryRootStateUpdateInputs;
pub const PrimaryRootStateUpdateInputs = group_state_update.PrimaryRootStateUpdateInputs;
pub const StagedLayerStateUpdateParameters = group_state_update.StagedLayerStateUpdateParameters;
pub const PrimaryRootExtensionPlacement = group_state_update.PrimaryRootExtensionPlacement;
pub const SecondaryRootDeficitLayer = group_state_update.SecondaryRootDeficitLayer;
pub const SecondaryRootDeficitAbsorption = group_state_update.SecondaryRootDeficitAbsorption;
pub const absorbPrimaryDeficitFromSecondaryRoots = group_state_update.absorbPrimaryDeficitFromSecondaryRoots;
pub const primaryRootExtensionPlacement = group_state_update.primaryRootExtensionPlacement;
pub const sourceOrderPrimaryRootExtensionPlacement = group_state_update.sourceOrderPrimaryRootExtensionPlacement;
pub const primaryRootLengthChange = group_state_update.primaryRootLengthChange;
pub const sourceOrderSecondaryAxisCount = group_state_update.sourceOrderSecondaryAxisCount;
pub const state_updateStagedLayerAxes = group_state_update.state_updateStagedLayerAxes;
pub const state_updatePrimaryRoot = group_state_update.state_updatePrimaryRoot;
pub const allocatePrimaryRootRespiration = group_state_update.allocatePrimaryRootRespiration;
pub const state_updateSecondaryRoot = group_state_update.state_updateSecondaryRoot;
pub const assemble = group_state_update.assemble;
pub const state_update = group_state_update.state_update;

// growth
pub const Components = group_growth.Components;
pub const SecondaryRootParameters = group_growth.SecondaryRootParameters;
pub const compatibilitySecondaryRootParameters = group_growth.compatibilitySecondaryRootParameters;
pub const SecondaryRootInputs = group_growth.SecondaryRootInputs;
pub const RuntimePlantParameters = group_growth.RuntimePlantParameters;
pub const SecondaryRootResult = group_growth.SecondaryRootResult;
pub const PrimaryRootInputs = group_growth.PrimaryRootInputs;
pub const secondaryRootMetabolism = group_growth.secondaryRootMetabolism;
pub const primaryRootMetabolism = group_growth.primaryRootMetabolism;

// litter
pub const RecyclingFractions = group_litter.RecyclingFractions;
pub const RootWoodComposition = group_litter.RootWoodComposition;
pub const rootWoodComposition = group_litter.rootWoodComposition;
pub const secondaryRootRecyclingFractions = group_litter.secondaryRootRecyclingFractions;
pub const SecondaryRootSenescenceInputs = group_litter.SecondaryRootSenescenceInputs;
pub const SecondaryRootSenescence = group_litter.SecondaryRootSenescence;
pub const secondaryRootSenescence = group_litter.secondaryRootSenescence;
pub const primaryRootSenescence = group_litter.primaryRootSenescence;
pub const RootLitterFractions = group_litter.RootLitterFractions;
pub const RootLitter = group_litter.RootLitter;
pub const MycorrhizalLossState = group_litter.MycorrhizalLossState;
pub const MycorrhizalLossResult = group_litter.MycorrhizalLossResult;
pub const mycorrhizalLossWithSecondaryRoots = group_litter.mycorrhizalLossWithSecondaryRoots;
pub const LayerPairRootLitter = group_litter.LayerPairRootLitter;
pub const state_updateMycorrhizalLossWithSecondaryRoots = group_litter.state_updateMycorrhizalLossWithSecondaryRoots;
pub const secondaryRootLitter = group_litter.secondaryRootLitter;

// misc
pub const AxisWorkspace = group_misc.AxisWorkspace;
pub const GridWorkspace = group_misc.GridWorkspace;

// respiration
pub const Respiration = group_respiration.Respiration;
pub const nutrientLimitedRootGrowthRespiration = group_respiration.nutrientLimitedRootGrowthRespiration;
pub const RootEnvironmentResponses = group_respiration.RootEnvironmentResponses;
pub const nextLowerRootLayer = group_respiration.nextLowerRootLayer;
pub const rootEnvironmentResponses = group_respiration.rootEnvironmentResponses;
pub const annualTerminationFeedback = group_respiration.annualTerminationFeedback;
pub const rootRespirationActive = group_respiration.rootRespirationActive;
pub const RootRespirationWaterResponses = group_respiration.RootRespirationWaterResponses;
pub const sourceRootRespirationWaterResponses = group_respiration.sourceRootRespirationWaterResponses;
pub const nutrientUptakeRespiration = group_respiration.nutrientUptakeRespiration;

test {
    // A bare reference is what makes `zig build test` reach a file.
    _ = @import("../../validation/plant_root_metabolism_test.zig");
}

const std = @import("std");
const canopy_module = @import("../../canopy/photosynthesis/photosynthesis.zig");
const root_module = @import("../root/plant_root_system.zig");
const removal = @import("harvest.zig");

pub const salt_count = removal.salt_count;

/// Persistent owners matching EXTRACT's plant × exchange-layer × salt layout.
/// Exchange layer zero is shoot litter; soil layer `L` is stored at `L + 1`.
pub const StateUpdateOwners = struct {
    cumulative_harvest_salt_mol_by_plant: []f64,
    litter_salt_mol_by_plant_exchange_layer: []f64,
};

pub const PlantInputs = struct {
    shoot_carbon_g_c: f64,
    current_harvest_carbon_g_c: f64,
    previous_harvest_carbon_g_c: f64,
    shoot_litterfall_carbon_g_c: f64,
    root_litterfall_carbon_g_c_by_layer: []const f64,
    active_root_domain_count: usize,
    carbon_absolute_tolerance_g_c: f64,
    salt_absolute_tolerance_mol: f64,
    physical_relative_tolerance: f64,
};

/// Heap-owned staging storage. It converts the domain-major root owner into
/// GROSUB's layer-major N-within-L order without per-hour allocation.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    layer_root_offsets: []usize,
    root_carbon_g_c: []f64,
    root_salt_mol: []f64,
    shoot_litterfall_salt_mol: []f64,
    root_litterfall_salt_mol_by_layer: []f64,

    pub fn init(allocator: std.mem.Allocator, soil_layer_count: usize) !Workspace {
        if (soil_layer_count == 0) return error.InvalidPlantSaltAdapterDimensions;
        const root_count = std.math.mul(
            usize,
            soil_layer_count,
            root_module.biological_domain_count,
        ) catch return error.InvalidPlantSaltAdapterDimensions;
        const root_salt_count = std.math.mul(usize, root_count, salt_count) catch
            return error.InvalidPlantSaltAdapterDimensions;
        const litter_count = std.math.mul(usize, soil_layer_count, salt_count) catch
            return error.InvalidPlantSaltAdapterDimensions;

        const offsets = try allocator.alloc(usize, soil_layer_count + 1);
        errdefer allocator.free(offsets);
        const root_carbon = try allocator.alloc(f64, root_count);
        errdefer allocator.free(root_carbon);
        const root_salt = try allocator.alloc(f64, root_salt_count);
        errdefer allocator.free(root_salt);
        const shoot_litter = try allocator.alloc(f64, salt_count);
        errdefer allocator.free(shoot_litter);
        const root_litter = try allocator.alloc(f64, litter_count);
        errdefer allocator.free(root_litter);
        @memset(offsets, 0);
        @memset(root_carbon, 0);
        @memset(root_salt, 0);
        @memset(shoot_litter, 0);
        @memset(root_litter, 0);
        return .{
            .allocator = allocator,
            .layer_root_offsets = offsets,
            .root_carbon_g_c = root_carbon,
            .root_salt_mol = root_salt,
            .shoot_litterfall_salt_mol = shoot_litter,
            .root_litterfall_salt_mol_by_layer = root_litter,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.root_litterfall_salt_mol_by_layer);
        self.allocator.free(self.shoot_litterfall_salt_mol);
        self.allocator.free(self.root_salt_mol);
        self.allocator.free(self.root_carbon_g_c);
        self.allocator.free(self.layer_root_offsets);
        self.* = undefined;
    }
};

/// Returns whether a runtime plant slot is backed by an assigned canopy
/// topology. Legacy GROSUB's salt block iterates the configured cell-local
/// `NP0`; Zig's runscript count is a domain-wide capacity, so never-assigned
/// padding slots outside a cell's effective `NP0` must not enter the kernel.
pub fn hasAssignedBranches(canopy: *const canopy_module.State, plant: usize) !bool {
    const branches = try canopy.branchRange(plant);
    return branches.first != branches.end;
}

/// Binds GROSUB 12655–12890 to the authoritative canopy/root salt owners.
/// No allocation occurs here. StateUpdate remains plant-local and is state_updateted
/// only after the removal kernel accepts the complete state.
pub fn applyPlant(
    workspace: *Workspace,
    canopy: *canopy_module.State,
    roots: *root_module.State,
    owners: StateUpdateOwners,
    plant: usize,
    inputs: PlantInputs,
) !void {
    try validateAdapterDimensions(workspace.*, canopy.*, roots.*, owners, plant, inputs);
    const branches = try canopy.branchRange(plant);
    const layer_count = roots.soil_layer_count;
    const active_domains = inputs.active_root_domain_count;
    const active_root_count = try std.math.mul(usize, layer_count, active_domains);
    for (0..layer_count + 1) |boundary| workspace.layer_root_offsets[boundary] = boundary * active_domains;

    for (0..layer_count) |layer| {
        for (0..active_domains) |domain| {
            const staged_root = layer * active_domains + domain;
            const owner_root = try roots.layerIndex(plant, domain, layer);
            workspace.root_carbon_g_c[staged_root] = roots.total_carbon_g[owner_root];
            inline for (@typeInfo(root_module.SaltSpecies).@"enum".fields) |field| {
                const species: root_module.SaltSpecies = @enumFromInt(field.value);
                workspace.root_salt_mol[staged_root * salt_count + field.value] =
                    roots.salt_content_mol[try roots.saltIndex(plant, domain, layer, species)];
            }
        }
    }

    const harvest = owners.cumulative_harvest_salt_mol_by_plant[plant * salt_count ..][0..salt_count];
    var staged: removal.State = .{
        .allocator = workspace.allocator,
        .layer_root_offsets = workspace.layer_root_offsets,
        .branch_salt_mol = canopy.branch_salt_content_by_species_mol[branches.first * salt_count .. branches.end * salt_count],
        .root_salt_mol = workspace.root_salt_mol[0 .. active_root_count * salt_count],
        .cumulative_harvest_salt_mol = harvest,
        .shoot_litterfall_salt_mol = workspace.shoot_litterfall_salt_mol,
        .root_litterfall_salt_mol_by_layer = workspace.root_litterfall_salt_mol_by_layer,
    };
    try removal.removeForHarvestAndLitterfall(&staged, .{
        .shoot_carbon_g_c = inputs.shoot_carbon_g_c,
        .current_harvest_carbon_g_c = inputs.current_harvest_carbon_g_c,
        .previous_harvest_carbon_g_c = inputs.previous_harvest_carbon_g_c,
        .shoot_litterfall_carbon_g_c = inputs.shoot_litterfall_carbon_g_c,
        .root_carbon_g_c = workspace.root_carbon_g_c[0..active_root_count],
        .root_litterfall_carbon_g_c_by_layer = inputs.root_litterfall_carbon_g_c_by_layer,
        .carbon_absolute_tolerance_g_c = inputs.carbon_absolute_tolerance_g_c,
        .salt_absolute_tolerance_mol = inputs.salt_absolute_tolerance_mol,
        .physical_relative_tolerance = inputs.physical_relative_tolerance,
    });

    for (0..layer_count) |layer| {
        for (0..active_domains) |domain| {
            const staged_root = layer * active_domains + domain;
            inline for (@typeInfo(root_module.SaltSpecies).@"enum".fields) |field| {
                const species: root_module.SaltSpecies = @enumFromInt(field.value);
                roots.salt_content_mol[try roots.saltIndex(plant, domain, layer, species)] =
                    workspace.root_salt_mol[staged_root * salt_count + field.value];
            }
        }
    }
    const plant_litter_base = plant * (layer_count + 1) * salt_count;
    @memcpy(
        owners.litter_salt_mol_by_plant_exchange_layer[plant_litter_base..][0..salt_count],
        workspace.shoot_litterfall_salt_mol,
    );
    @memcpy(
        owners.litter_salt_mol_by_plant_exchange_layer[plant_litter_base + salt_count ..][0 .. layer_count * salt_count],
        workspace.root_litterfall_salt_mol_by_layer,
    );
}

fn validateAdapterDimensions(
    workspace: Workspace,
    canopy: canopy_module.State,
    roots: root_module.State,
    owners: StateUpdateOwners,
    plant: usize,
    inputs: PlantInputs,
) !void {
    if (plant >= canopy.cell_count * canopy.species_count or
        plant >= roots.plant_count or
        canopy.cell_count * canopy.species_count != roots.plant_count or
        inputs.active_root_domain_count == 0 or
        inputs.active_root_domain_count > root_module.biological_domain_count or
        inputs.root_litterfall_carbon_g_c_by_layer.len != roots.soil_layer_count or
        workspace.layer_root_offsets.len != roots.soil_layer_count + 1 or
        workspace.root_carbon_g_c.len < roots.soil_layer_count * inputs.active_root_domain_count or
        workspace.root_salt_mol.len < roots.soil_layer_count * inputs.active_root_domain_count * salt_count or
        workspace.shoot_litterfall_salt_mol.len != salt_count or
        workspace.root_litterfall_salt_mol_by_layer.len != roots.soil_layer_count * salt_count or
        owners.cumulative_harvest_salt_mol_by_plant.len != roots.plant_count * salt_count or
        owners.litter_salt_mol_by_plant_exchange_layer.len != roots.plant_count * (roots.soil_layer_count + 1) * salt_count)
        return error.PlantSaltAdapterDimensionMismatch;

    const branches = try canopy.branchRange(plant);
    if (branches.first == branches.end or
        canopy.branch_salt_content_by_species_mol.len !=
            (canopy.plant_branch_offsets[canopy.plant_branch_offsets.len - 1] * salt_count))
        return error.PlantSaltAdapterDimensionMismatch;
}

test "ownership adapter conserves each plant layer and corrects ZEROP X ownership" {
    var canopy = try canopy_module.State.init(
        std.testing.allocator,
        1,
        2,
        &.{ 1, 2 },
        &.{ 1, 1, 1 },
        &.{ 1, 1, 1 },
    );
    defer canopy.deinit();
    var roots = try root_module.State.init(std.testing.allocator, 2, 2, 1);
    defer roots.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 2);
    defer workspace.deinit();
    const harvest = try std.testing.allocator.alloc(f64, 2 * salt_count);
    defer std.testing.allocator.free(harvest);
    const litter = try std.testing.allocator.alloc(f64, 2 * 3 * salt_count);
    defer std.testing.allocator.free(litter);
    @memset(harvest, 0);
    @memset(litter, 0);

    for (0..salt_count) |salt| {
        canopy.branch_salt_content_by_species_mol[salt] = 100;
        canopy.branch_salt_content_by_species_mol[salt_count + salt] = 3;
        canopy.branch_salt_content_by_species_mol[2 * salt_count + salt] = 1;
        for (0..2) |layer| {
            for (0..root_module.biological_domain_count) |domain| {
                const species: root_module.SaltSpecies = @enumFromInt(salt);
                roots.salt_content_mol[try roots.saltIndex(1, domain, layer, species)] = @floatFromInt(domain + 1);
            }
        }
    }
    for (0..2) |layer| {
        for (0..root_module.biological_domain_count) |domain| {
            roots.total_carbon_g[try roots.layerIndex(1, domain, layer)] = 5;
        }
    }

    try applyPlant(&workspace, &canopy, &roots, .{
        .cumulative_harvest_salt_mol_by_plant = harvest,
        .litter_salt_mol_by_plant_exchange_layer = litter,
    }, 1, .{
        .shoot_carbon_g_c = 20,
        .current_harvest_carbon_g_c = 2,
        .previous_harvest_carbon_g_c = 0,
        .shoot_litterfall_carbon_g_c = 2,
        .root_litterfall_carbon_g_c_by_layer = &.{ 10, 0 },
        .active_root_domain_count = 2,
        .carbon_absolute_tolerance_g_c = 1e-12,
        .salt_absolute_tolerance_mol = 1e-14,
        .physical_relative_tolerance = 1e-12,
    });

    for (0..salt_count) |salt| {
        // Plant zero remains untouched: the threshold and owners are selected
        // by the requested plant, the intended NX-index semantics.
        try std.testing.expectEqual(@as(f64, 100), canopy.branch_salt_content_by_species_mol[salt]);
        try std.testing.expectApproxEqAbs(0.4, harvest[salt_count + salt], 1e-14);
        try std.testing.expectApproxEqAbs(0.4, litter[(3 * salt_count) + salt], 1e-14);
        try std.testing.expectApproxEqAbs(1.5, litter[(4 * salt_count) + salt], 1e-14);
        try std.testing.expectEqual(@as(f64, 0), litter[(5 * salt_count) + salt]);
        const shoot_after = canopy.branch_salt_content_by_species_mol[salt_count + salt] +
            canopy.branch_salt_content_by_species_mol[2 * salt_count + salt];
        try std.testing.expectApproxEqAbs(4, shoot_after + harvest[salt_count + salt] + litter[3 * salt_count + salt], 1e-13);
        var root_after: f64 = 0;
        const species: root_module.SaltSpecies = @enumFromInt(salt);
        for (0..2) |layer| {
            for (0..2) |domain| {
                root_after += roots.salt_content_mol[try roots.saltIndex(1, domain, layer, species)];
            }
        }
        try std.testing.expectApproxEqAbs(6, root_after + litter[4 * salt_count + salt], 1e-13);
    }
}

test "capacity-only plant slots are excluded from GROSUB salt removal" {
    var canopy = try canopy_module.State.init(
        std.testing.allocator,
        1,
        5,
        &.{ 1, 0, 0, 0, 0 },
        &.{1},
        &.{1},
    );
    defer canopy.deinit();

    try std.testing.expect(try hasAssignedBranches(&canopy, 0));
    for (1..5) |plant| try std.testing.expect(!try hasAssignedBranches(&canopy, plant));
}

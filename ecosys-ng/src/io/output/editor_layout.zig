//! Resolves a source FOUTS/FOUTP output editor onto a runtime output catalog.
//!
//! ## Why this file is not a `@memcpy`
//!
//! `fouts.f`/`foutp.f` define a fixed 50-slot soil domain and a fixed 50-slot
//! plant domain. Slot identity there is **absolute**: soil daily-carbon slot 42
//! *is* `ECO_HVST_C` and slot 44 *is* `ECO_GPP`, no matter how many soil layers
//! the run has, because every layer sub-block is compiled at a fixed width
//! (`fouts.f:333-377` gives daily carbon 14 `SOC_*` slots, `fouts.f:163-212`
//! gives hourly water 20 `WTR_*` and 20 `ICE_*` slots, and so on).
//!
//! A runtime catalog sizes those same sub-blocks from `SimulationConfig`. When
//! the runtime layer count differs from the source width, catalog index and
//! source slot stop agreeing, and every slot after the first layer block refers
//! to a different variable. Until 2026-09-10 this module copied the choice
//! vector onto the catalog **positionally**, so on the Ottawa deck
//! (`soil_layers = 12`) the deck's `TEMP_16` request emitted canopy-air vapour
//! density, its `ECO_GPP` request emitted net primary productivity, its
//! `O2_1..O2_9` request emitted dissolved oxygen for layers 5..12, and 26
//! requested columns were dropped without a word. See
//! `docs/output_semantics_audit_2026-09-10.md` §3 for the measured evidence.
//!
//! So the mapping is done by **slot identity**: `sourceLayout` states, per
//! editor family, the exact run structure of the source's 50 slots, and
//! `resolve` walks source slots and runtime catalog entries in lockstep.
//!
//! ## Runtime layer width is derived, never passed
//!
//! Every layer block in a family is built from the same `config.soil_layers`
//! (`src/stages/run_support.zig:91-125`), so the runtime width follows from the
//! catalog length and the layout alone:
//!
//!     runtime_variable_count = total_fixed_slots + width * total_values_per_layer
//!
//! Solving that for `width` keeps the layout the single source of truth. If the
//! division does not come out exactly, the catalog and the layout disagree,
//! which is a coding error in this file or in a catalog, and it is fatal.
//!
//! ## Nothing is dropped silently
//!
//! Two configuration cases cannot be honoured, and both are reported rather
//! than skipped:
//!
//!   - the choice addresses a layer beyond the run's profile (`WTR_20` on a
//!     12-layer soil). The source model prints an uninitialised array element
//!     here, which is a legacy defect and not something to reproduce.
//!   - the choice addresses a slot the source itself never named, e.g. plant
//!     carbon slot 8, where `foutp.f:81-87` stops at 7 and the legacy heading
//!     line carries 16 NUL bytes.
//!
//! Both land in `Resolved.unrepresentable` and are logged at `warn` with the
//! domain, the source slot and the reason. They are deliberately not errors:
//! they say the editor file was written for a different `parameters.h`, which a
//! user must be told about but which must not stop a run mid-scene.

const std = @import("std");

const log = std.log.scoped(.output_editor);

pub const source_domain_choice_count: usize = 50;
pub const source_total_choice_count: usize = 2 * source_domain_choice_count;

/// Which half of the source editor a slot belongs to.
pub const Domain = enum { soil, plant };

/// One run of consecutive runtime catalog entries, annotated with the source
/// slot it corresponds to.
///
/// Runs are listed in **catalog** order and each states its own
/// `source_slot`, so a catalog whose order differs from the source's is
/// expressible rather than a silent mismatch. Soil editor index 2 is the one
/// family that needs it today: its catalog keeps each litter entry beside its
/// own layer block while the source puts both litter slots after both blocks.
pub const Run = union(enum) {
    /// `count` catalog entries taking source slots
    /// `source_slot .. source_slot + count - 1`.
    fixed: struct { source_slot: usize, count: usize },
    /// A layer block. The source has `source_layers` layers starting at
    /// `source_slot`; the runtime has however many the catalog was built with.
    /// `values_per_layer` is 1 for every block except the daily-heat
    /// temperature block, which interleaves a maximum and a minimum per layer
    /// (`fouts.f:577-604`).
    layers: struct { source_slot: usize, source_layers: usize, values_per_layer: usize = 1 },

    fn lastSourceSlot(self: Run) usize {
        return switch (self) {
            .fixed => |run| run.source_slot + run.count - 1,
            .layers => |block| block.source_slot + block.source_layers * block.values_per_layer - 1,
        };
    }
};

/// Why a chosen source slot could not be honoured.
pub const UnrepresentableReason = enum {
    /// The slot addresses a soil or root layer the run does not have.
    layer_absent_from_run,
    /// `fouts.f`/`foutp.f` assign no heading and `outs*.f`/`outp*.f` no value
    /// to this slot, so there is nothing to emit.
    slot_unnamed_in_source,
};

pub const Unrepresentable = struct {
    domain: Domain,
    /// One-based source slot within its domain, so it reads the same way as the
    /// `IF(K.EQ.n)` and `IF(L.EQ.n)` ladders in the Fortran.
    source_slot: usize,
    reason: UnrepresentableReason,
    /// One-based layer the slot addresses, or 0 for a non-layer slot.
    layer: usize,
    /// Layers the run actually has in that block, or 0 for a non-layer slot.
    run_layers: usize,
};

pub const Resolved = struct {
    allocator: std.mem.Allocator,
    soil_enabled: []bool,
    plant_enabled: []bool,
    /// Chosen slots this configuration cannot emit. Empty for a compact editor,
    /// which is by construction exactly the runtime catalog.
    unrepresentable: []Unrepresentable,

    pub fn deinit(self: *Resolved) void {
        self.allocator.free(self.unrepresentable);
        self.allocator.free(self.plant_enabled);
        self.allocator.free(self.soil_enabled);
        self.* = undefined;
    }
};

// ------------------------------------------------------------- source layouts
//
// Every entry below is a claim about the Fortran and is cited so it can be
// checked without recompiling. `extent` is the number of slots the source
// actually names; a chosen slot past it is `slot_unnamed_in_source`.

/// Soil editors, `fouts.f` `N=21..30` in runscript order, matching
/// `src/stages/run_support.zig:91-105`. Runs are in catalog order; each states
/// the one-based source slot it occupies, so the whole table can be read
/// straight down `fouts.f`'s heading ladder.
const soil_layouts = [10][]const Run{
    // 0 hourly carbon. fouts.f:99-153 headings, outsh.f:51-104 values.
    // 1-4 fluxes, 5-18 CO2_1..14, 19 CO2_LIT, 20-34 CH4_1..15,
    // 35-49 O2_1..15, 50 O2_LIT.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 4 } },
        .{ .layers = .{ .source_slot = 5, .source_layers = 14 } },
        .{ .fixed = .{ .source_slot = 19, .count = 1 } },
        .{ .layers = .{ .source_slot = 20, .source_layers = 15 } },
        .{ .layers = .{ .source_slot = 35, .source_layers = 15 } },
        .{ .fixed = .{ .source_slot = 50, .count = 1 } },
    },
    // 1 hourly water. fouts.f:160-214, outsh.f:115-169.
    // 1-6 fluxes, 7-26 WTR_1..20, 27 SURF_WTR, 28-47 ICE_1..20, 48 SURF_ICE,
    // 49 ACTV_LYR, 50 WTR_TBL.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 6 } },
        .{ .layers = .{ .source_slot = 7, .source_layers = 20 } },
        .{ .fixed = .{ .source_slot = 27, .count = 1 } },
        .{ .layers = .{ .source_slot = 28, .source_layers = 20 } },
        .{ .fixed = .{ .source_slot = 48, .count = 3 } },
    },
    // 2 hourly nitrogen. fouts.f:221-262, outsh.f:180-220. Extent 37; the
    // source names nothing for 38-50 and `outsh.f` leaves HEAD(M) stale there,
    // so a choice past 37 is unnamed rather than zero.
    //
    // The one family whose catalog order differs from the source's: the source
    // puts N2O_LIT (36) and NH3_LIT (37) after both layer blocks, while
    // `output_catalog.nitrogen` keeps each litter entry beside its own block.
    // Stating the source slot per run is what makes that expressible.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 5 } },
        .{ .layers = .{ .source_slot = 6, .source_layers = 15 } },
        .{ .fixed = .{ .source_slot = 36, .count = 1 } },
        .{ .layers = .{ .source_slot = 21, .source_layers = 15 } },
        .{ .fixed = .{ .source_slot = 37, .count = 1 } },
    },
    // 3 hourly phosphorus. fouts.f:269-275, outsh.f:231-237. Extent 2.
    &.{.{ .fixed = .{ .source_slot = 1, .count = 2 } }},
    // 4 hourly heat. fouts.f:282-322, outsh.f:247-288. Extent 37.
    // 1-13 weather and flux, 14-33 TEMP_1..20, 34 TEMP_LITTER, 35 TEMP_SNOW,
    // 36 TEMP_CAN_AIR, 37 HUM_CAN_AIR.
    //
    // Slots 36 and 37 hold `TCQ` and `VPQ*TKQ/2.173E-03`, canopy-air
    // temperature and humidity, while the catalog names them
    // `litter_temperature` and `litter_water_vapor_density`. The names look
    // wrong against the source, but confirming that needs the value producer,
    // which this change does not touch; recorded as F-01/§8 item 5 of
    // `docs/output_semantics_audit_2026-09-10.md`. The slot *structure* below
    // is what the mapping depends on and it is right either way.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 13 } },
        .{ .layers = .{ .source_slot = 14, .source_layers = 20 } },
        .{ .fixed = .{ .source_slot = 34, .count = 4 } },
    },
    // 5 daily carbon. fouts.f:330-378, outsd.f:50-101.
    // 1-17 pools and fluxes, 18-31 SOC_1..14, 32-50 trailing.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 17 } },
        .{ .layers = .{ .source_slot = 18, .source_layers = 14 } },
        .{ .fixed = .{ .source_slot = 32, .count = 19 } },
    },
    // 6 daily water. fouts.f:386-439, outsd.f:111-167.
    // 1-6, 7-19 WTR_1..13, 20 SURF_WTR, 21-33 ICE_1..13, 34 SURF_ICE,
    // 35-44 PSI_1..10, 45-50 trailing.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 6 } },
        .{ .layers = .{ .source_slot = 7, .source_layers = 13 } },
        .{ .fixed = .{ .source_slot = 20, .count = 1 } },
        .{ .layers = .{ .source_slot = 21, .source_layers = 13 } },
        .{ .fixed = .{ .source_slot = 34, .count = 1 } },
        .{ .layers = .{ .source_slot = 35, .source_layers = 10 } },
        .{ .fixed = .{ .source_slot = 45, .count = 6 } },
    },
    // 7 daily nitrogen. fouts.f:447-500, outsd.f:177-539.
    // 1-14, 15-29 NH4_1..15, 30-44 NO3_1..15, 45 NH4_RES, 46-50 trailing.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 14 } },
        .{ .layers = .{ .source_slot = 15, .source_layers = 15 } },
        .{ .layers = .{ .source_slot = 30, .source_layers = 15 } },
        .{ .fixed = .{ .source_slot = 45, .count = 6 } },
    },
    // 8 daily phosphorus. fouts.f:508-559, outsd.f:549-868.
    // 1-12, 13-27 PO4_1..15, 28-42 EXCH_P_1..15, 43 PO4_RES, 44 EXCH_P_RES,
    // 45-48 trailing. The source names only 48; slots 49-50 stay in the layout
    // so the catalog's two reserved entries line up, and a choice there is
    // reported as unnamed.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 12 } },
        .{ .layers = .{ .source_slot = 13, .source_layers = 15 } },
        .{ .layers = .{ .source_slot = 28, .source_layers = 15 } },
        .{ .fixed = .{ .source_slot = 43, .count = 8 } },
    },
    // 9 daily heat. fouts.f:567-620, outsd.f:879-934.
    // 1-7 weather, 8-35 TMAX_SOIL_n/TMIN_SOIL_n interleaved for n=1..14,
    // 36 TMAX_LITTER, 37 TMIN_LITTER, 38-49 ECND_1..12, 50 TTL_SALT_DISCHG.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 7 } },
        .{ .layers = .{ .source_slot = 8, .source_layers = 14, .values_per_layer = 2 } },
        .{ .fixed = .{ .source_slot = 36, .count = 2 } },
        .{ .layers = .{ .source_slot = 38, .source_layers = 12 } },
        .{ .fixed = .{ .source_slot = 50, .count = 1 } },
    },
};

/// Plant editors, `foutp.f` `N=21..30`, matching
/// `src/stages/run_support.zig:111-125`. `foutp.f`/`outpd.f`/`outph.f` write
/// these as `L=51..100`; the slots below are one-based within the plant domain,
/// so source slot `n` here is the Fortran's `L = 50 + n`.
const plant_layouts = [10][]const Run{
    // 0 hourly carbon. foutp.f:81-87, outph.f:55-61. Extent 7:
    // CAN_CO2_FLUX, CAN_GPP, CAN_RA, [TNC], STOML_RSC, BLYR_RSC, LAI.
    // The Ottawa editor also selects slot 8, which the source never names;
    // that is the origin of the 16 NUL bytes ending `11998f25ch1`'s heading.
    &.{.{ .fixed = .{ .source_slot = 1, .count = 7 } }},
    // 1 hourly water. foutp.f:99-119, outph.f:76-80.
    // 1-6 PSI_CAN, TURG_CAN, STOM_RSC, BLYR_RSC, TRANSPN, O2_STRESS,
    // 7-21 PSI_RT_1..15.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 6 } },
        .{ .layers = .{ .source_slot = 7, .source_layers = 15 } },
    },
    // 2 hourly nitrogen. foutp.f:131-165.
    // 1-5, 6-20 UP_NH4_1..15, 21-35 UP_NO3_1..15.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 5 } },
        .{ .layers = .{ .source_slot = 6, .source_layers = 15 } },
        .{ .layers = .{ .source_slot = 21, .source_layers = 15 } },
    },
    // 3 hourly phosphorus. foutp.f:177-193.
    // 1 PO4_UPTK, 2 [TNP], 3-17 UP_PO4_1..15.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 2 } },
        .{ .layers = .{ .source_slot = 3, .source_layers = 15 } },
    },
    // 4 hourly heat. foutp.f:205-211, outph.f:237-243. Extent 7.
    &.{.{ .fixed = .{ .source_slot = 1, .count = 7 } }},
    // 5 daily carbon. foutp.f:223-264, outpd.f:55-112.
    // 1-20 pools, 21-35 DNS_RT_1..15, 36 C_BALANCE, 37 STG_DEAD_C,
    // 38 FIRE_C_LOSS, 39 BLANK, 40 NPP, 41 CAN_HT, 42 POPN.
    &.{
        .{ .fixed = .{ .source_slot = 1, .count = 20 } },
        .{ .layers = .{ .source_slot = 21, .source_layers = 15 } },
        .{ .fixed = .{ .source_slot = 36, .count = 7 } },
    },
    // 6 daily water. foutp.f:276-279, outpd.f:127-130. Extent 4.
    &.{.{ .fixed = .{ .source_slot = 1, .count = 4 } }},
    // 7 daily nitrogen. foutp.f:291-313, outpd.f:145-182. Extent 23.
    &.{.{ .fixed = .{ .source_slot = 1, .count = 23 } }},
    // 8 daily phosphorus. foutp.f:325-343, outpd.f:197-223. Extent 19.
    &.{.{ .fixed = .{ .source_slot = 1, .count = 19 } }},
    // 9 daily development. foutp.f:355-363, outpd.f:240-285. Extent 9.
    &.{.{ .fixed = .{ .source_slot = 1, .count = 9 } }},
};

/// The source slot structure for one editor family.
pub fn sourceLayout(domain: Domain, editor_index: usize) ![]const Run {
    if (editor_index >= 10) return error.OutputEditorIndexOutOfBounds;
    return switch (domain) {
        .soil => soil_layouts[editor_index],
        .plant => plant_layouts[editor_index],
    };
}

/// Highest source slot a layout names. Runs may be listed out of source order,
/// so this is a maximum rather than a sum.
pub fn layoutExtent(layout: []const Run) usize {
    var highest: usize = 0;
    for (layout) |run| highest = @max(highest, run.lastSourceSlot());
    return highest;
}

fn fixedSlotCount(layout: []const Run) usize {
    var total: usize = 0;
    for (layout) |run| switch (run) {
        .fixed => |fixed| total += fixed.count,
        .layers => {},
    };
    return total;
}

fn valuesPerLayerTotal(layout: []const Run) usize {
    var total: usize = 0;
    for (layout) |run| switch (run) {
        .fixed => {},
        .layers => |block| total += block.values_per_layer,
    };
    return total;
}

/// Every source slot a layout names, exactly once, with no gap. A layout that
/// double-books or skips a slot would map some catalog entry to the wrong
/// variable, so the tables are checked rather than trusted.
fn layoutCoversEachSlotOnce(layout: []const Run) bool {
    const extent = layoutExtent(layout);
    if (extent == 0 or extent > source_domain_choice_count) return false;
    var seen = [_]bool{false} ** source_domain_choice_count;
    for (layout) |run| {
        var slot = switch (run) {
            .fixed => |fixed| fixed.source_slot,
            .layers => |block| block.source_slot,
        };
        const span = run.lastSourceSlot() + 1 - slot;
        while (slot < run.lastSourceSlot() + 1) : (slot += 1) {
            if (slot == 0 or slot > extent or seen[slot - 1]) return false;
            seen[slot - 1] = true;
        }
        if (span == 0) return false;
    }
    for (seen[0..extent]) |covered| if (!covered) return false;
    return true;
}

/// Number of selected entries, i.e. the emitted column count.
pub fn countEnabled(enabled: []const bool) usize {
    var total: usize = 0;
    for (enabled) |on| total += @intFromBool(on);
    return total;
}

/// Recovers the layer width the catalog was built with.
///
/// Every layer block in a family is sized from the same `config.soil_layers`,
/// so the catalog length determines the width exactly. A remainder means the
/// layout in this file and the catalog that produced `variable_count` disagree,
/// which is a coding error rather than a configuration one.
pub fn runLayerWidth(layout: []const Run, variable_count: usize) !usize {
    const fixed = fixedSlotCount(layout);
    const stride = valuesPerLayerTotal(layout);
    if (stride == 0) {
        if (variable_count != fixed) return error.OutputEditorCatalogLayoutMismatch;
        return 0;
    }
    if (variable_count < fixed) return error.OutputEditorCatalogLayoutMismatch;
    const remainder = variable_count - fixed;
    if (remainder % stride != 0) return error.OutputEditorCatalogLayoutMismatch;
    return remainder / stride;
}

// ----------------------------------------------------------------- resolution

const DomainResolution = struct {
    enabled: []bool,
    unrepresentable: []Unrepresentable,
};

fn resolveDomain(
    allocator: std.mem.Allocator,
    domain: Domain,
    layout: []const Run,
    choices: []const bool,
    variable_count: usize,
) !DomainResolution {
    const enabled = try allocator.alloc(bool, variable_count);
    errdefer allocator.free(enabled);
    @memset(enabled, false);

    var skipped: std.ArrayList(Unrepresentable) = .empty;
    errdefer skipped.deinit(allocator);

    const width = try runLayerWidth(layout, variable_count);

    // `cursor` walks the runtime catalog in order; each run says which source
    // slot its entries came from. The two indices advance independently, which
    // is the whole point of the file.
    var cursor: usize = 0;
    for (layout) |run| switch (run) {
        .fixed => |fixed| {
            for (0..fixed.count) |offset| {
                const slot = fixed.source_slot + offset;
                if (cursor >= variable_count) return error.OutputEditorCatalogLayoutMismatch;
                if (slot <= choices.len and choices[slot - 1]) enabled[cursor] = true;
                cursor += 1;
            }
        },
        .layers => |block| {
            for (0..block.source_layers) |layer_index| {
                const layer = layer_index + 1;
                const present = layer <= width;
                for (0..block.values_per_layer) |value_index| {
                    const slot = block.source_slot +
                        layer_index * block.values_per_layer + value_index;
                    if (present) {
                        if (cursor >= variable_count) return error.OutputEditorCatalogLayoutMismatch;
                        if (slot <= choices.len and choices[slot - 1]) enabled[cursor] = true;
                        cursor += 1;
                    } else if (slot <= choices.len and choices[slot - 1]) {
                        try skipped.append(allocator, .{
                            .domain = domain,
                            .source_slot = slot,
                            .reason = .layer_absent_from_run,
                            .layer = layer,
                            .run_layers = width,
                        });
                    }
                }
            }
            // Runtime layers past the source width have no source slot, so a
            // source editor leaves them off. This is the documented behaviour
            // for a runtime catalog wider than the historical fifty slots.
            if (width > block.source_layers)
                cursor += (width - block.source_layers) * block.values_per_layer;
        },
    };
    if (cursor != variable_count) return error.OutputEditorCatalogLayoutMismatch;

    // Choices past everything the source names.
    const extent = layoutExtent(layout);
    var past = extent + 1;
    while (past <= choices.len and past <= source_domain_choice_count) : (past += 1) {
        if (!choices[past - 1]) continue;
        try skipped.append(allocator, .{
            .domain = domain,
            .source_slot = past,
            .reason = .slot_unnamed_in_source,
            .layer = 0,
            .run_layers = 0,
        });
    }

    for (skipped.items) |entry| switch (entry.reason) {
        .layer_absent_from_run => log.warn(
            "{s} editor slot {d} selects layer {d}, but this run has {d} layers in that block; the column is not emitted",
            .{ @tagName(entry.domain), entry.source_slot, entry.layer, entry.run_layers },
        ),
        .slot_unnamed_in_source => log.warn(
            "{s} editor slot {d} is selected but fouts.f/foutp.f name no variable there; the column is not emitted",
            .{ @tagName(entry.domain), entry.source_slot },
        ),
    };

    return .{ .enabled = enabled, .unrepresentable = try skipped.toOwnedSlice(allocator) };
}

/// Resolves the source FOUTS/FOUTP 50+50 editor layout, or a modern compact
/// soil-count + plant-count layout.
///
/// `editor_index` selects the family, because source slot identity is per
/// family: the same slot number means different things in the hourly water
/// editor and the daily nitrogen editor, and the layer block widths differ.
pub fn resolve(
    allocator: std.mem.Allocator,
    editor_index: usize,
    choices: []const bool,
    soil_variable_count: usize,
    plant_variable_count: usize,
) !Resolved {
    if (soil_variable_count == 0 or plant_variable_count == 0) return error.EmptyOutputCatalog;
    const compact_count = try std.math.add(usize, soil_variable_count, plant_variable_count);
    if (choices.len != source_total_choice_count and choices.len != compact_count)
        return error.OutputEditorChoiceCountMismatch;

    if (choices.len == compact_count and choices.len != source_total_choice_count) {
        const soil = try allocator.alloc(bool, soil_variable_count);
        errdefer allocator.free(soil);
        const plant = try allocator.alloc(bool, plant_variable_count);
        errdefer allocator.free(plant);
        @memcpy(soil, choices[0..soil.len]);
        @memcpy(plant, choices[soil.len..]);
        return .{
            .allocator = allocator,
            .soil_enabled = soil,
            .plant_enabled = plant,
            .unrepresentable = try allocator.alloc(Unrepresentable, 0),
        };
    }

    const soil_layout = try sourceLayout(.soil, editor_index);
    const plant_layout = try sourceLayout(.plant, editor_index);

    const soil = try resolveDomain(
        allocator,
        .soil,
        soil_layout,
        choices[0..source_domain_choice_count],
        soil_variable_count,
    );
    errdefer {
        allocator.free(soil.enabled);
        allocator.free(soil.unrepresentable);
    }
    const plant = try resolveDomain(
        allocator,
        .plant,
        plant_layout,
        choices[source_domain_choice_count..][0..source_domain_choice_count],
        plant_variable_count,
    );
    errdefer {
        allocator.free(plant.enabled);
        allocator.free(plant.unrepresentable);
    }

    const merged = try allocator.alloc(
        Unrepresentable,
        soil.unrepresentable.len + plant.unrepresentable.len,
    );
    errdefer allocator.free(merged);
    @memcpy(merged[0..soil.unrepresentable.len], soil.unrepresentable);
    @memcpy(merged[soil.unrepresentable.len..], plant.unrepresentable);
    allocator.free(soil.unrepresentable);
    allocator.free(plant.unrepresentable);

    return .{
        .allocator = allocator,
        .soil_enabled = soil.enabled,
        .plant_enabled = plant.enabled,
        .unrepresentable = merged,
    };
}

// ---------------------------------------------------------------------- tests

/// Turns a one-based slot list into a 100-entry source choice vector, so a test
/// reads the same way as the `YES` lines of a real editor file.
fn sourceChoices(soil_slots: []const usize, plant_slots: []const usize) [source_total_choice_count]bool {
    var choices = [_]bool{false} ** source_total_choice_count;
    for (soil_slots) |slot| choices[slot - 1] = true;
    for (plant_slots) |slot| choices[source_domain_choice_count + slot - 1] = true;
    return choices;
}

fn enabledSlots(allocator: std.mem.Allocator, enabled: []const bool) ![]usize {
    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(allocator);
    for (enabled, 0..) |on, index| if (on) try list.append(allocator, index);
    return list.toOwnedSlice(allocator);
}

test "every layout covers each source slot exactly once" {
    // A layout that double-booked or skipped a slot would silently map some
    // catalog entry to the wrong variable, which is the defect class this file
    // exists to remove, so the tables are verified rather than trusted.
    for (0..10) |index| {
        try std.testing.expect(layoutCoversEachSlotOnce(try sourceLayout(.soil, index)));
        try std.testing.expect(layoutCoversEachSlotOnce(try sourceLayout(.plant, index)));
    }
    // The checker itself must reject a gap and an overlap.
    try std.testing.expect(!layoutCoversEachSlotOnce(&.{
        .{ .fixed = .{ .source_slot = 1, .count = 2 } },
        .{ .fixed = .{ .source_slot = 4, .count = 1 } },
    }));
    try std.testing.expect(!layoutCoversEachSlotOnce(&.{
        .{ .fixed = .{ .source_slot = 1, .count = 3 } },
        .{ .fixed = .{ .source_slot = 3, .count = 1 } },
    }));
}

test "every source layout has the extent fouts.f and foutp.f actually name" {
    // Guards the layout tables against an edit that silently changes a slot
    // count. The numbers come from the heading ladders cited on each entry.
    const soil_extents = [10]usize{ 50, 50, 37, 2, 37, 50, 50, 50, 50, 50 };
    const plant_extents = [10]usize{ 7, 21, 35, 17, 7, 42, 4, 23, 19, 9 };
    for (soil_extents, 0..) |expected, index|
        try std.testing.expectEqual(expected, layoutExtent(try sourceLayout(.soil, index)));
    for (plant_extents, 0..) |expected, index|
        try std.testing.expectEqual(expected, layoutExtent(try sourceLayout(.plant, index)));
    try std.testing.expectError(error.OutputEditorIndexOutOfBounds, sourceLayout(.soil, 10));
}

test "runtime layer width is recovered from the catalog length alone" {
    // The Ottawa deck's twelve layers, against every soil family's real
    // catalog length from src/soil/diagnostics/output_catalog.zig.
    const cases = [_]struct { index: usize, count: usize }{
        .{ .index = 0, .count = 42 }, .{ .index = 1, .count = 34 },
        .{ .index = 2, .count = 31 }, .{ .index = 4, .count = 29 },
        .{ .index = 5, .count = 48 }, .{ .index = 6, .count = 50 },
        .{ .index = 7, .count = 44 }, .{ .index = 8, .count = 44 },
        .{ .index = 9, .count = 46 },
    };
    for (cases) |case| try std.testing.expectEqual(
        @as(usize, 12),
        try runLayerWidth(try sourceLayout(.soil, case.index), case.count),
    );
    // And the historical widths give back exactly fifty-slot catalogs.
    try std.testing.expectEqual(@as(usize, 14), try runLayerWidth(try sourceLayout(.soil, 5), 50));
    try std.testing.expectEqual(@as(usize, 20), try runLayerWidth(try sourceLayout(.soil, 1), 50));
    // A length that no layer width can produce is a coding error, not a
    // configuration one.
    try std.testing.expectError(
        error.OutputEditorCatalogLayoutMismatch,
        runLayerWidth(try sourceLayout(.soil, 1), 35),
    );
    try std.testing.expectError(
        error.OutputEditorCatalogLayoutMismatch,
        runLayerWidth(try sourceLayout(.soil, 3), 3),
    );
}

test "at the historical layer width slot and catalog index coincide" {
    // The pre-2026-09-10 positional copy was correct in exactly this case, so
    // the new path must agree with it here or it has changed behaviour it had
    // no business changing.
    var choices = sourceChoices(&.{ 1, 20, 42, 50 }, &.{ 1, 21, 42 });
    var resolved = try resolve(std.testing.allocator, 5, &choices, 50, 42);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.unrepresentable.len);
    for ([_]usize{ 0, 19, 41, 49 }) |index| try std.testing.expect(resolved.soil_enabled[index]);
    for ([_]usize{ 0, 20, 41 }) |index| try std.testing.expect(resolved.plant_enabled[index]);
    try std.testing.expectEqual(@as(usize, 4), countEnabled(resolved.soil_enabled));
    try std.testing.expectEqual(@as(usize, 3), countEnabled(resolved.plant_enabled));
}

test "f25eh1: TEMP_LITTER is emitted and TEMP_16 is reported, not shifted" {
    // The regression this module existed to cause. The Ottawa hourly-heat
    // editor selects slots 1-24, 29 (TEMP_16) and 34 (TEMP_LITTER). With
    // soil_layers = 12 the catalog is 29 long, and the old positional copy
    // emitted catalog entry 29 -- canopy-air vapour density, named
    // `litter_water_vapor_density` -- for the TEMP_16 request, then dropped
    // TEMP_LITTER entirely.
    var choices = sourceChoices(
        &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 29, 34 },
        &.{ 1, 2, 3, 4, 5, 6 },
    );
    var resolved = try resolve(std.testing.allocator, 4, &choices, 29, 7);
    defer resolved.deinit();

    const slots = try enabledSlots(std.testing.allocator, resolved.soil_enabled);
    defer std.testing.allocator.free(slots);
    // 13 weather/flux entries, soil temperature layers 1-11, and catalog entry
    // 25 (zero-based 25), which is `surface_soil_temperature`: the source's
    // TEMP_LITTER. Catalog entry 28, `litter_water_vapor_density`, is the
    // source's HUM_CAN_AIR at slot 37 and is not selected.
    try std.testing.expectEqualSlices(usize, &.{
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, // 13 fixed
        13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, // soil temperature 1-11
        25, // surface_soil_temperature, i.e. TEMP_LITTER
    }, slots);
    try std.testing.expectEqual(@as(usize, 25), slots.len);

    try std.testing.expectEqual(@as(usize, 1), resolved.unrepresentable.len);
    try std.testing.expectEqual(Domain.soil, resolved.unrepresentable[0].domain);
    try std.testing.expectEqual(@as(usize, 29), resolved.unrepresentable[0].source_slot);
    try std.testing.expectEqual(UnrepresentableReason.layer_absent_from_run, resolved.unrepresentable[0].reason);
    try std.testing.expectEqual(@as(usize, 16), resolved.unrepresentable[0].layer);
    try std.testing.expectEqual(@as(usize, 12), resolved.unrepresentable[0].run_layers);
}

test "f25nd1: NO3 layers 1-10 and the five trailing slots the deck asked for" {
    // The Ottawa daily-nitrogen editor selects 1-24, 30-39, 45-48 and 50.
    // With soil_layers = 12 the catalog is 44 long, and the old positional copy
    // turned the NO3_1..NO3_10 request into nitrate layers 4-12 plus
    // `surface_ammonium_nitrogen_concentration`, then dropped FIRE_SON_LOSS,
    // ECO_HVST_N, NET_N_MIN and N2_FLUX.
    var choices = sourceChoices(
        &.{
            1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12,
            13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
            30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46,
            47, 48, 50,
        },
        &.{ 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22 },
    );
    var resolved = try resolve(std.testing.allocator, 7, &choices, 44, 23);
    defer resolved.deinit();

    const slots = try enabledSlots(std.testing.allocator, resolved.soil_enabled);
    defer std.testing.allocator.free(slots);
    // 14 fixed, ammonium layers 1-10 (catalog 14..23), nitrate layers 1-10
    // (catalog 26..35), surface ammonium (38), then FIRE_SON_LOSS,
    // ECO_HVST_N, NET_N_MIN (39,40,41) and N2_FLUX (43).
    try std.testing.expectEqualSlices(usize, &.{
        0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13,
        14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 26, 27, 28, 29,
        30, 31, 32, 33, 34, 35, 38, 39, 40, 41, 43,
    }, slots);
    try std.testing.expectEqual(@as(usize, 39), slots.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.unrepresentable.len);

    // The plant half is unaffected: its catalog is the same length as its
    // source layout, so identity and position already agreed.
    try std.testing.expectEqual(@as(usize, 21), countEnabled(resolved.plant_enabled));
}

test "the Ottawa deck's whole editor set resolves to the pre-registered column counts" {
    // These are the seven sparse-selection streams from
    // `docs/output_semantics_audit_2026-09-10.md` §3, whose emitted column sets
    // were predicted from the layout arithmetic and then confirmed against the
    // real run. `emitted` is what the slot-identity mapping must now produce;
    // `was` is what the positional copy produced, kept so the diff is explicit.
    const cases = [_]struct {
        name: []const u8,
        editor_index: usize,
        soil_slots: []const usize,
        plant_slots: []const usize,
        soil_count: usize,
        plant_count: usize,
        emitted_soil: usize,
        emitted_plant: usize,
        was_soil: usize,
        unrepresentable: usize,
    }{
        .{
            .name = "f25ch1",
            .editor_index = 0,
            .soil_slots = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43 },
            .plant_slots = &.{ 1, 2, 3, 6, 7, 8 },
            .soil_count = 42,
            .plant_count = 7,
            .emitted_soil = 17,
            .emitted_plant = 5,
            .was_soil = 17,
            .unrepresentable = 2,
        },
        .{
            .name = "f25wh1",
            .editor_index = 1,
            .soil_slots = &.{
                1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16,
                17, 18, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33,
                34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
            },
            .plant_slots = &.{ 1, 2, 3, 4, 5 },
            .soil_count = 34,
            .plant_count = 18,
            .emitted_soil = 32,
            .emitted_plant = 5,
            .was_soil = 33,
            .unrepresentable = 15,
        },
        .{
            .name = "f25nh1",
            .editor_index = 2,
            .soil_slots = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 },
            .plant_slots = &.{},
            .soil_count = 31,
            .plant_count = 29,
            .emitted_soil = 13,
            .emitted_plant = 0,
            .was_soil = 13,
            .unrepresentable = 0,
        },
        .{
            .name = "f25eh1",
            .editor_index = 4,
            .soil_slots = &.{
                1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13,
                14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 29, 34,
            },
            .plant_slots = &.{ 1, 2, 3, 4, 5, 6 },
            .soil_count = 29,
            .plant_count = 7,
            .emitted_soil = 25,
            .emitted_plant = 6,
            .was_soil = 25,
            .unrepresentable = 1,
        },
        .{
            .name = "f25cd1",
            .editor_index = 5,
            .soil_slots = &.{
                1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16,
                18, 19, 20, 21, 22, 23, 24, 25, 42, 44, 45, 46, 47, 49,
            },
            .plant_slots = &.{
                1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16,
                17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 36,
                37, 40, 41,
            },
            .soil_count = 48,
            .plant_count = 39,
            .emitted_soil = 30,
            .emitted_plant = 35,
            .was_soil = 29,
            .unrepresentable = 0,
        },
        .{
            .name = "f25nd1",
            .editor_index = 7,
            .soil_slots = &.{
                1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12,
                13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
                30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46,
                47, 48, 50,
            },
            .plant_slots = &.{ 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22 },
            .soil_count = 44,
            .plant_count = 23,
            .emitted_soil = 39,
            .emitted_plant = 21,
            .was_soil = 34,
            .unrepresentable = 0,
        },
        .{
            .name = "f25pd1",
            .editor_index = 8,
            .soil_slots = &.{
                1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12,
                13, 14, 15, 16, 17, 18, 28, 29, 30, 31, 32, 33,
                44, 45, 46,
            },
            .plant_slots = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 },
            .soil_count = 44,
            .plant_count = 19,
            .emitted_soil = 27,
            .emitted_plant = 18,
            .was_soil = 25,
            .unrepresentable = 0,
        },
    };
    for (cases) |case| {
        var choices = sourceChoices(case.soil_slots, case.plant_slots);
        var resolved = try resolve(
            std.testing.allocator,
            case.editor_index,
            &choices,
            case.soil_count,
            case.plant_count,
        );
        defer resolved.deinit();
        const soil = countEnabled(resolved.soil_enabled);
        const plant = countEnabled(resolved.plant_enabled);
        std.testing.expectEqual(case.emitted_soil, soil) catch |failure| {
            std.debug.print("{s}: soil columns {d}, expected {d}\n", .{ case.name, soil, case.emitted_soil });
            return failure;
        };
        std.testing.expectEqual(case.emitted_plant, plant) catch |failure| {
            std.debug.print("{s}: plant columns {d}, expected {d}\n", .{ case.name, plant, case.emitted_plant });
            return failure;
        };
        std.testing.expectEqual(case.unrepresentable, resolved.unrepresentable.len) catch |failure| {
            std.debug.print("{s}: {d} unrepresentable, expected {d}\n", .{ case.name, resolved.unrepresentable.len, case.unrepresentable });
            return failure;
        };
        // Every emitted column must be one the editor asked for, and the total
        // must never exceed the request: that is the property the positional
        // copy broke.
        try std.testing.expect(soil + resolved.unrepresentable.len >= case.emitted_soil);
    }
}

test "f25wh1: the deck never selects the active layer or water table slots" {
    // Slots 49 and 50 are `NO` in the Ottawa hourly-water editor, yet the
    // positional copy emitted both, which is where the constant `+9999`
    // `active_layer_depth_below_surface` column came from. It must be gone.
    var choices = sourceChoices(&.{
        1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16,
        17, 18, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33,
        34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
    }, &.{ 1, 2, 3, 4, 5 });
    var resolved = try resolve(std.testing.allocator, 1, &choices, 34, 18);
    defer resolved.deinit();
    // Catalog entries 31, 32 and 33 are `surface_volumetric_ice_fraction`,
    // `active_layer_depth_below_surface` and `water_table_depth_below_surface`.
    // Only the first is selected (source slot 48, SURF_ICE). Entries 18 and 31
    // were named `surface_excess_liquid_water_depth`/`..._ice_water_depth`
    // until issue-086's second finding corrected them to the dimensionless
    // fractions they actually carry; the indices are unchanged.
    try std.testing.expect(resolved.soil_enabled[31]);
    try std.testing.expect(!resolved.soil_enabled[32]);
    try std.testing.expect(!resolved.soil_enabled[33]);
    // Source slot 27, SURF_WTR, now reaches catalog entry 18,
    // `surface_volumetric_liquid_water_fraction`, which the positional copy
    // skipped.
    try std.testing.expect(resolved.soil_enabled[18]);
}

test "a runtime catalog wider than the source layout leaves the extra layers off" {
    // Documented behaviour, preserved: a source editor cannot address a layer
    // the source never had a slot for.
    var choices = sourceChoices(&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27 }, &.{1});
    // water(24): 6 fixed + 24 liquid + 1 + 24 ice + 1 + 2 = 58.
    var resolved = try resolve(std.testing.allocator, 1, &choices, 58, 7);
    defer resolved.deinit();
    // Slots 7-26 select liquid layers 1-20; layers 21-24 have no source slot.
    for (6..26) |index| try std.testing.expect(resolved.soil_enabled[index]);
    for (26..30) |index| try std.testing.expect(!resolved.soil_enabled[index]);
    // Slot 27 is SURF_WTR, which sits after all 24 runtime liquid layers.
    try std.testing.expect(resolved.soil_enabled[30]);
    try std.testing.expectEqual(@as(usize, 0), resolved.unrepresentable.len);
}

test "compact editor selects every runtime-expanded variable" {
    const choices = [_]bool{ true, false, true, true, false };
    var resolved = try resolve(std.testing.allocator, 0, &choices, 3, 2);
    defer resolved.deinit();
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, resolved.soil_enabled);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, resolved.plant_enabled);
    try std.testing.expectEqual(@as(usize, 0), resolved.unrepresentable.len);
}

test "an unnamed source slot is reported rather than dropped" {
    // Plant carbon has seven named slots. The Ottawa editor selects an eighth,
    // which is why `11998f25ch1`'s heading line ends in sixteen NUL bytes.
    var choices = sourceChoices(&.{1}, &.{ 1, 8 });
    var resolved = try resolve(std.testing.allocator, 0, &choices, 42, 7);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 1), countEnabled(resolved.plant_enabled));
    try std.testing.expectEqual(@as(usize, 1), resolved.unrepresentable.len);
    try std.testing.expectEqual(Domain.plant, resolved.unrepresentable[0].domain);
    try std.testing.expectEqual(@as(usize, 8), resolved.unrepresentable[0].source_slot);
    try std.testing.expectEqual(
        UnrepresentableReason.slot_unnamed_in_source,
        resolved.unrepresentable[0].reason,
    );
}

test "a catalog whose length no layer width explains is a coding error" {
    var choices = sourceChoices(&.{1}, &.{1});
    try std.testing.expectError(
        error.OutputEditorCatalogLayoutMismatch,
        resolve(std.testing.allocator, 1, &choices, 35, 18),
    );
    try std.testing.expectError(
        error.OutputEditorChoiceCountMismatch,
        resolve(std.testing.allocator, 1, choices[0..99], 34, 18),
    );
    try std.testing.expectError(
        error.EmptyOutputCatalog,
        resolve(std.testing.allocator, 1, &choices, 0, 18),
    );
}

test "the daily heat temperature block advances two slots per layer" {
    // fouts.f:577-604 interleaves TMAX_SOIL_n and TMIN_SOIL_n, so a layer
    // consumes two source slots and two catalog entries.
    var choices = sourceChoices(&.{ 8, 9, 32, 33, 36, 38, 50 }, &.{1});
    var resolved = try resolve(std.testing.allocator, 9, &choices, 46, 9);
    defer resolved.deinit();
    // Slots 8 and 9 are layer 1's maximum and minimum: catalog entries 7 and 8.
    try std.testing.expect(resolved.soil_enabled[7]);
    try std.testing.expect(resolved.soil_enabled[8]);
    // Slots 32 and 33 are layer 13, which a twelve-layer run does not have.
    try std.testing.expectEqual(@as(usize, 2), resolved.unrepresentable.len);
    for (resolved.unrepresentable) |entry| {
        try std.testing.expectEqual(UnrepresentableReason.layer_absent_from_run, entry.reason);
        try std.testing.expectEqual(@as(usize, 13), entry.layer);
    }
    // Slot 36 is TMAX_LITTER: catalog entry 31, straight after 24 temperature
    // entries and 7 fixed ones.
    try std.testing.expect(resolved.soil_enabled[31]);
    // Slot 38 is ECND_1: catalog entry 33. Slot 50 is TTL_SALT_DISCHG: 45.
    try std.testing.expect(resolved.soil_enabled[33]);
    try std.testing.expect(resolved.soil_enabled[45]);
}

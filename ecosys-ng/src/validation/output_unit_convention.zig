//! Enforces the output-heading convention documented in CLAUDE.md and
//! docs/model_changes.md: a heading's unit half is written `name[unit]` with
//! space-separated SI symbols and trailing signed exponents (`g m-3`,
//! `g N m-2 h-1`), never an underscore-joined spelling (`g_per_m3`) and never
//! a lowercase `mg`/`mj` unit prefix, since milligram/megajoule must be
//! spelled out rather than abbreviated with a case-carrying symbol that a
//! snake_case identifier cannot preserve. A handful of dimensionless
//! qualifiers (`fraction`, `count`, `stage`, `enum_code`,
//! `model_concentration`) are words, not unit symbols, and are exempt.
//!
//! This module previously did not exist despite three independent artifacts
//! (CLAUDE.md, docs/model_changes.md, and this file's own former doc-comment
//! reference from src/validation/legacy_comparison.zig) claiming it actively
//! enforced the convention "over every catalog" -- see
//! docs/discrepancy_register.md's OUTPUT-UNIT-CONVENTION-MISSING-001 entry.

const std = @import("std");
const record = @import("../io/output/record.zig");
const soil_output_catalog = @import("../soil/diagnostics/output_catalog.zig");
const plant_output_catalog = @import("../io/output/plant_output_catalog.zig");

const dimensionless_qualifiers = [_][]const u8{
    "fraction", "count", "stage", "enum_code", "model_concentration",
};

fn isDimensionlessQualifier(unit: []const u8) bool {
    for (dimensionless_qualifiers) |qualifier| {
        if (std.mem.eql(u8, unit, qualifier)) return true;
    }
    return false;
}

/// Validates one output heading's unit half.
pub fn validateUnit(unit: []const u8) !void {
    if (unit.len == 0) return error.EmptyOutputUnit;
    if (isDimensionlessQualifier(unit)) return;
    if (std.mem.indexOfScalar(u8, unit, '_') != null) return error.OutputUnitUsesUnderscoreSpelling;
    var tokens = std.mem.splitScalar(u8, unit, ' ');
    while (tokens.next()) |token| {
        if (token.len == 0) return error.OutputUnitHasDoubleSpace;
        if (std.mem.startsWith(u8, token, "mg") or std.mem.startsWith(u8, token, "mj"))
            return error.OutputUnitUsesLowercaseMilligramOrMegajoulePrefix;
    }
}

/// Validates one output heading's identifier half: a snake_case identifier
/// can never distinguish `mg`/`Mg` or `mj`/`MJ`, so it must never carry
/// either abbreviation as a standalone underscore-delimited word.
pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.EmptyOutputName;
    var words = std.mem.splitScalar(u8, name, '_');
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "mg") or std.mem.eql(u8, word, "mj"))
            return error.OutputNameUsesCaseCollapsedUnitAbbreviation;
    }
}

pub fn validateVariable(variable: record.Variable) !void {
    try validateName(variable.name);
    try validateUnit(variable.unit);
}

pub fn validateCatalog(variables: []const record.Variable) !void {
    for (variables) |variable| try validateVariable(variable);
}

test "dimensionless qualifiers are accepted as-is" {
    try validateUnit("fraction");
    try validateUnit("count");
    try validateUnit("stage");
    try validateUnit("enum_code");
    try validateUnit("model_concentration");
}

test "well-formed SI unit strings are accepted" {
    try validateUnit("g m-3");
    try validateUnit("g N m-2 h-1");
    try validateUnit("umol m-2 s-1");
    try validateUnit("umol mol-1");
    try validateUnit("MPa");
    try validateUnit("kPa");
    try validateUnit("m3 m-3");
    try validateUnit("g C m-3 water");
    try validateUnit("g N g-1 C");
    try validateUnit("MJ m-2");
    try validateUnit("dS m-1");
    try validateUnit("mol m-2");
    try validateUnit("number m-2");
    try validateUnit("plants m-2");
}

test "underscore spellings outside the dimensionless whitelist are rejected" {
    try std.testing.expectError(error.OutputUnitUsesUnderscoreSpelling, validateUnit("g_per_m3"));
    try std.testing.expectError(error.OutputUnitUsesUnderscoreSpelling, validateUnit("g_N_per_m2_h"));
}

test "a lowercase mg or mj unit prefix is rejected" {
    try std.testing.expectError(error.OutputUnitUsesLowercaseMilligramOrMegajoulePrefix, validateUnit("mg m-3"));
    try std.testing.expectError(error.OutputUnitUsesLowercaseMilligramOrMegajoulePrefix, validateUnit("mj m-2"));
    try std.testing.expectError(error.OutputUnitUsesLowercaseMilligramOrMegajoulePrefix, validateUnit("g mg-1"));
}

test "an identifier may not carry a case-collapsed mg or mj abbreviation" {
    try std.testing.expectError(error.OutputNameUsesCaseCollapsedUnitAbbreviation, validateName("litter_mg_content"));
    try std.testing.expectError(error.OutputNameUsesCaseCollapsedUnitAbbreviation, validateName("fire_mj_release"));
    try validateName("megagram_soil_organic_carbon");
}

test "every soil diagnostics output catalog satisfies the output heading convention" {
    const allocator = std.testing.allocator;

    var water = try soil_output_catalog.water(allocator, 5);
    defer water.deinit();
    try validateCatalog(water.variables);

    var heat = try soil_output_catalog.heat(allocator, 5);
    defer heat.deinit();
    try validateCatalog(heat.variables);

    var carbon = try soil_output_catalog.carbon(allocator, 3, 3, 3);
    defer carbon.deinit();
    try validateCatalog(carbon.variables);

    var nitrogen = try soil_output_catalog.nitrogen(allocator, 3, 3);
    defer nitrogen.deinit();
    try validateCatalog(nitrogen.variables);

    var phosphorus = try soil_output_catalog.phosphorus(allocator);
    defer phosphorus.deinit();
    try validateCatalog(phosphorus.variables);

    var daily_carbon = try soil_output_catalog.dailyCarbon(allocator, 5);
    defer daily_carbon.deinit();
    try validateCatalog(daily_carbon.variables);

    var daily_water = try soil_output_catalog.dailyWater(allocator, 3, 3, 3);
    defer daily_water.deinit();
    try validateCatalog(daily_water.variables);

    var daily_nitrogen = try soil_output_catalog.dailyNitrogen(allocator, 5);
    defer daily_nitrogen.deinit();
    try validateCatalog(daily_nitrogen.variables);

    var daily_phosphorus = try soil_output_catalog.dailyPhosphorus(allocator, 5);
    defer daily_phosphorus.deinit();
    try validateCatalog(daily_phosphorus.variables);

    var daily_heat = try soil_output_catalog.dailyHeat(allocator, 5, 3);
    defer daily_heat.deinit();
    try validateCatalog(daily_heat.variables);
}

test "every plant output catalog satisfies the output heading convention" {
    const allocator = std.testing.allocator;

    var carbon = try plant_output_catalog.carbon(allocator);
    defer carbon.deinit();
    try validateCatalog(carbon.variables);

    var water = try plant_output_catalog.water(allocator, 5);
    defer water.deinit();
    try validateCatalog(water.variables);

    var nitrogen = try plant_output_catalog.nitrogen(allocator, 5);
    defer nitrogen.deinit();
    try validateCatalog(nitrogen.variables);

    var phosphorus = try plant_output_catalog.phosphorus(allocator, 5);
    defer phosphorus.deinit();
    try validateCatalog(phosphorus.variables);

    var heat = try plant_output_catalog.heat(allocator);
    defer heat.deinit();
    try validateCatalog(heat.variables);

    var daily_carbon = try plant_output_catalog.dailyCarbon(allocator, 5);
    defer daily_carbon.deinit();
    try validateCatalog(daily_carbon.variables);

    var daily_water = try plant_output_catalog.dailyWater(allocator);
    defer daily_water.deinit();
    try validateCatalog(daily_water.variables);

    var daily_nitrogen = try plant_output_catalog.dailyNitrogen(allocator);
    defer daily_nitrogen.deinit();
    try validateCatalog(daily_nitrogen.variables);

    var daily_phosphorus = try plant_output_catalog.dailyPhosphorus(allocator);
    defer daily_phosphorus.deinit();
    try validateCatalog(daily_phosphorus.variables);

    var daily_development = try plant_output_catalog.dailyDevelopment(allocator);
    defer daily_development.deinit();
    try validateCatalog(daily_development.variables);
}

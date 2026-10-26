//! Mechanical Zig 0.17 compatibility shim for the retired field-reflection API.
//!
//! Zig 0.17 removed `std.builtin.Type.StructField` / `EnumField` and
//! `std.meta.fields`; `std.lang.Type` now carries parallel slices
//! (`field_names`, `field_types`, `field_values`, `field_attrs`).  Cycle 1 of
//! the 0.17 migration (2026-10-13) reconstructs the old per-field views so
//! reflection loops keep their `field.name` / `field.type` / `field.value`
//! spelling with a one-token call-site change.
//!
//! The views are returned as comptime-known **arrays by value**, not slices.
//! Under 0.17 (measured, `.tmp/zigprobe` batch p2-p13):
//!   * `inline for` only accepts a comptime-known **array**; a comptime-known
//!     slice is rejected with "inline loop condition must be comptime-known".
//!   * a runtime `for` cannot bind elements of an aggregate that contains a
//!     comptime-only field (`type`, `comptime_int`) in any shape, so every
//!     reflection loop must be an `inline for` (or sit inside `comptime {}`).
//! Call-site shapes that keep working unchanged on the array value: slicing
//! (`views[1..]`, `views[1 .. views.len - 1]`), `.len`, comptime indexing,
//! storing the result in a `const`, and array repeat (`[1]T{x} * views.len`).
//! See `.agent/migrations/zig-0.17.md`, breakage class "field reflection".
//!
//! No behavior change: the views are derived from exactly the same comptime
//! type data, in declaration order.  Every entry point takes comptime-known
//! input (`type` or a `std.lang.Type` payload), so all of these are evaluated
//! at comptime and the returned arrays are comptime-known constants.

pub const FieldView = struct {
    name: [:0]const u8,
    type: type,
};

pub const EnumFieldView = struct {
    name: [:0]const u8,
    value: comptime_int,
};

/// Struct/union field count for `T`; comptime error for every other kind.
fn fieldViewsLen(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_names.len,
        .@"union" => |u| u.field_names.len,
        else => @compileError("typeinfo_compat.fieldViews: " ++ @typeName(T) ++ " is not a struct or union"),
    };
}

/// Enum field count for `T`; comptime error for every other kind.
fn enumFieldViewsLen(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"enum" => |e| e.field_names.len,
        else => @compileError("typeinfo_compat.enumFieldViews: " ++ @typeName(T) ++ " is not an enum"),
    };
}

/// Struct/union field views in declaration order.
/// Replaces the retired `std.meta.fields(T)` and
/// `@typeInfo(T).@"struct"/.@"union".fields`.
pub fn fieldViews(comptime T: type) [fieldViewsLen(T)]FieldView {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| fieldViewsFromInfo(s),
        .@"union" => |u| fieldViewsFromInfo(u),
        else => @compileError("typeinfo_compat.fieldViews: " ++ @typeName(T) ++ " is not a struct or union"),
    };
}

/// Enum field views in declaration order.
/// Replaces the retired `@typeInfo(T).@"enum".fields`.
pub fn enumFieldViews(comptime T: type) [enumFieldViewsLen(T)]EnumFieldView {
    return switch (@typeInfo(T)) {
        .@"enum" => |e| enumFieldViewsFromInfo(e),
        else => @compileError("typeinfo_compat.enumFieldViews: " ++ @typeName(T) ++ " is not an enum"),
    };
}

/// Field views from an already-extracted struct/union typeInfo payload
/// (prong-capture loops: `.@"struct" => |s| ... s.fields`).
///
/// The eval-branch quota is raised in proportion to the field count.  Zig's
/// comptime evaluator aborts any single evaluation after 1000 backwards
/// branches, and this fill loop costs a handful of branches per field, so a
/// wide struct (or this shim called from inside another `inline for`) aborts
/// with "evaluation exceeded 1000 backwards branches" — measured 2026-10-14 on
/// `plant.reset.uptake_flux.allocateFields` (audit/runs/zig017-test-20261014-1).
/// The quota is a compiler resource limit on comptime bookkeeping: it changes
/// no field, no order, no type and no emitted instruction.  It scales with the
/// struct instead of being a blanket constant, so a runaway comptime loop still
/// aborts.
pub fn fieldViewsFromInfo(comptime info: anytype) [info.field_names.len]FieldView {
    return comptime blk: {
        @setEvalBranchQuota(1000 + 64 * info.field_names.len);
        var views: [info.field_names.len]FieldView = undefined;
        for (info.field_names, info.field_types, 0..) |name, field_type, i| {
            views[i] = .{ .name = name, .type = field_type };
        }
        break :blk views;
    };
}

/// Enum field views from an already-extracted enum typeInfo payload
/// (prong-capture loops: `.@"enum" => |e| ... e.fields`).
/// See `fieldViewsFromInfo` for why the eval-branch quota is scaled here too.
pub fn enumFieldViewsFromInfo(comptime info: anytype) [info.field_names.len]EnumFieldView {
    return comptime blk: {
        @setEvalBranchQuota(1000 + 64 * info.field_names.len);
        var views: [info.field_names.len]EnumFieldView = undefined;
        for (info.field_names, info.field_values, 0..) |name, value, i| {
            views[i] = .{ .name = name, .value = value };
        }
        break :blk views;
    };
}

//! `litter_chemistry` declarations: logging.
//!
//! Split out of `litter_chemistry.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ledger = @import("litter_reaction_transformations.zig");
const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const numerics = @import("../core/numerics.zig");
const group_types = @import("litter_chemistry_types.zig");

pub fn logAdmissibleLimits(comptime T: type, comptime prefix: []const u8, current: T, changes: T, limiting_fraction: f64) void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const change = @field(changes, field.name);
            if (change < 0) {
                const fraction = @max(0, @field(current, field.name)) / -change;
                if (fraction <= limiting_fraction * (1 + 1e-10))
                    std.log.warn("litter chemistry active-set limit: field={s}{s} value={e} change={e} fraction={e}", .{ prefix, field.name, @field(current, field.name), change, fraction });
            }
        },
        .@"struct" => logAdmissibleLimits(field.type, prefix ++ field.name ++ ".", @field(current, field.name), @field(changes, field.name), limiting_fraction),
        else => @compileError("litter chemistry contains a non-numeric field"),
    };
}

pub fn logUnconvergedFields(comptime T: type, comptime prefix: []const u8, current: T, changes: T, options: group_types.Options) void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const value = @field(current, field.name);
            const change = @field(changes, field.name);
            const scaled = @abs(change) / options.scaleForField(field.name, value);
            if (scaled > 1)
                std.log.warn("litter chemistry residual: field={s}{s} value={e} change={e} scaled={e}", .{ prefix, field.name, value, change, scaled });
        },
        .@"struct" => logUnconvergedFields(field.type, prefix ++ field.name ++ ".", @field(current, field.name), @field(changes, field.name), options),
        else => @compileError("litter chemistry contains a non-numeric field"),
    };
}

pub fn logInadmissibleDirections(comptime T: type, comptime prefix: []const u8, current: T, changes: T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const value = @field(current, field.name);
            const change = @field(changes, field.name);
            if (change < 0 and value <= std.math.floatEps(f64) * @max(1.0, @abs(change)))
                // The caller returns a typed nonlinear-failure error and may
                // retry the unchanged transaction at a smaller substep. Keep
                // the diagnostic visible without turning an expected,
                // recoverable rejection into a test/runtime error side effect.
                std.log.warn("litter chemistry has no admissible direction: field={s}{s} value={e} change={e}", .{ prefix, field.name, value, change });
        },
        .@"struct" => logInadmissibleDirections(field.type, prefix ++ field.name ++ ".", @field(current, field.name), @field(changes, field.name)),
        else => @compileError("litter chemistry contains a non-numeric field"),
    };
}

//! Mechanical Zig 0.17 compatibility shim for the retired array-repeat operator.
//!
//! Zig 0.17 removed array repeat completely: `**` now parses as two `*`
//! operators and plain `*` is ordinary multiplication.  Measured 2026-10-14
//! against the pinned `/opt/homebrew/bin/zig` 0.17.0 (probes under `.tmp/matrix/`,
//! every shape fails with "incompatible types: '[1]f64' and '<count type>'"):
//!
//!   `[_]u8{0} * 3`             → error   (0.16-era codemod target: NOT valid)
//!   `[_]f64{0.5} * n`          → error
//!   `.{0.5} * n`               → error   (anonymous struct literal × int)
//!   `[_]f64{0.5} ** 3`         → parse error ("whitespace on one side")
//!   `std.mem.zeroes([3]f64)`   → ok      (zero fill only)
//!
//! so every `[_]T{v} ** n` (and `.{v} ** n`) initializer is rewritten by
//! `ecosys-audit/scripts/zig017_repeat_fill_migration.py` into
//!
//!   `array_compat.filled(n, T, @as(T, v))`
//!
//! Cycle 1 of the Zig 0.17 migration (`.agent/migrations/zig-0.17.md`),
//! breakage class "array repeat".
//!
//! No behaviour change: the repeat operator built an array whose every element
//! was a copy of the same initializer, in declaration order; `filled` does the
//! same thing, with the same comptime-known length (`n` was comptime-known in
//! 0.16 too, because a repeat count always was) and the same element type `T`
//! spelled by the rewritten source.

/// `[n]T` with every element set to `value`.
///
/// `n` is comptime-known (the array length is part of the type); `value` is an
/// ordinary value of `T`, exactly like the element of the retired
/// `[_]T{value} ** n` literal, so a comptime-known `value` still folds at
/// comptime and a runtime one still works at runtime.
///
/// `@splat` rather than a fill loop: `filled` is used in comptime positions
/// (static tables, checkpoint headers) where a `for` would be *interpreted*
/// element by element, and 0.17's comptime evaluator aborts any evaluation with
/// more than 1000 backwards branches.  Measured 2026-10-14: the loop version
/// fails with "evaluation exceeded 1000 backwards branches" at `n = 4000`
/// (audit/runs/zig017-fill-build-20261014-7), the `@splat` version compiles a
/// 9000-element fill in either phase.  Element type, length, values and order
/// are identical — this is the same array the repeat operator built.
pub fn filled(comptime n: usize, comptime T: type, value: T) [n]T {
    return @as([n]T, @splat(value));
}

/// Pointer to a `[n]T` of `value`, for the `&([_]T{v} ** n)` call shape that
/// passed a static array literal straight into a slice parameter.
pub fn filledRef(comptime n: usize, comptime T: type, comptime value: T) *const [n]T {
    const storage: [n]T = filled(n, T, value);
    return &storage;
}

test "filled builds the array the retired repeat operator built" {
    const n: usize = 4;
    const zeros = filled(n, f64, @as(f64, 0));
    try @import("std").testing.expectEqual(@as(usize, 4), zeros.len);
    for (zeros) |v| try @import("std").testing.expectEqual(@as(f64, 0), v);

    const scalars = filled(3, usize, @as(usize, 7));
    try @import("std").testing.expectEqual(@as(usize, 7), scalars[2]);

    const Element = struct { a: f64 = 1, b: bool = false };
    const elements = filled(2, Element, @as(Element, .{ .a = 2.5 }));
    try @import("std").testing.expectEqual(@as(f64, 2.5), elements[0].a);
    try @import("std").testing.expect(!elements[1].b);

    const nested = filled(2, [2]f64, @as([2]f64, .{ 1, 2 }));
    try @import("std").testing.expectEqual(@as(f64, 2), nested[1][1]);

    try @import("std").testing.expectEqual(@as(f64, 3), filledRef(2, f64, @as(f64, 3)).*[1]);

    // zero length stays legal (the retired operator allowed it)
    const none = filled(0, f64, @as(f64, 1));
    try @import("std").testing.expectEqual(@as(usize, 0), none.len);
}

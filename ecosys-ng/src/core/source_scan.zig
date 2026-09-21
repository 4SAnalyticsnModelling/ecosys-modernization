// Test-support scanner for the self-referential source-text assertions this
// repository uses to prove that a production call site exists, is correctly
// ordered, or occurs exactly once. Filed against
// `audit/issues/issue-076-crlf-checkout-breaks-hardcoded-lf-multiline-source-scan-tests-seven-failures.md`.
//
// Those tests `@embedFile` or `readFileAlloc` one of the repository's own `.zig`
// files and search it for a multi-line literal written with `\n` line endings.
// That assumption only holds on an LF checkout. With `git config
// core.autocrlf=true` -- this machine's setting, and the default on many Windows
// clones -- every tracked text file arrives CRLF-terminated, so a `\n`-only
// needle cannot match `\r\n`-separated text and the assertion fails while the
// production code it is checking is perfectly correct. issue-076 pinned that
// mechanism across all 7 affected assertions; this module removes the
// assumption instead of normalizing the repository.
//
// The scan is allocation-free and treats a `CR` in the haystack as invisible
// whenever the needle does not itself expect one, so the same needle matches an
// LF and a CRLF checkout identically. Returned indices are offsets into the
// ORIGINAL haystack, so the ordering comparisons these tests perform
// (`index_of_a < index_of_b`) stay valid.
//
// CENSUS NOTE, same class as the banners on `src/index/*_test_index.zig`: this
// file is test support, has no production caller by design, and must never
// acquire one. `tools/census_reach.py` will list it as unbound; that is the
// documented `CENSUS-ORPHAN-FP-001` false positive, not outstanding work.

const std = @import("std");

/// Matches `needle` at `start`, skipping haystack `CR` bytes the needle does
/// not ask for. Returns the exclusive end offset in `haystack` on success.
fn matchEnd(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    var haystack_index = start;
    var needle_index: usize = 0;
    while (needle_index < needle.len) {
        if (haystack_index >= haystack.len) return null;
        const candidate = haystack[haystack_index];
        if (candidate == '\r' and needle[needle_index] != '\r') {
            haystack_index += 1;
            continue;
        }
        if (candidate != needle[needle_index]) return null;
        haystack_index += 1;
        needle_index += 1;
    }
    return haystack_index;
}

/// Offset of the first occurrence of `needle` in `haystack`, ignoring haystack
/// carriage returns. The offset is into `haystack` as given.
pub fn indexOfIgnoringCarriageReturns(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var start: usize = 0;
    while (start < haystack.len) : (start += 1)
        if (matchEnd(haystack, start, needle) != null) return start;
    return null;
}

/// As `indexOfIgnoringCarriageReturns`, but begins the search at `start`.
pub fn indexOfPosIgnoringCarriageReturns(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (start >= haystack.len) return if (needle.len == 0) start else null;
    const found = indexOfIgnoringCarriageReturns(haystack[start..], needle) orelse return null;
    return start + found;
}

pub fn containsIgnoringCarriageReturns(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoringCarriageReturns(haystack, needle) != null;
}

/// Non-overlapping occurrence count, matching `std.mem.count`'s semantics for
/// an LF checkout.
pub fn countIgnoringCarriageReturns(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var total: usize = 0;
    var start: usize = 0;
    while (start < haystack.len) {
        if (matchEnd(haystack, start, needle)) |end| {
            total += 1;
            start = end;
        } else start += 1;
    }
    return total;
}

test "a CRLF haystack matches an LF needle and reports the original offset" {
    const haystack = "alpha\r\nbeta(\r\n    gamma,\r\n)\r\n";
    const needle = "beta(\n    gamma,";
    const found = indexOfIgnoringCarriageReturns(haystack, needle);
    try std.testing.expectEqual(@as(?usize, 7), found);
    try std.testing.expect(containsIgnoringCarriageReturns(haystack, needle));
    // The same needle must still match a plain LF haystack, so the helper is
    // correct on either checkout rather than trading one assumption for another.
    try std.testing.expect(containsIgnoringCarriageReturns("alpha\nbeta(\n    gamma,\n)\n", needle));
}

test "a needle absent from the text is still reported absent" {
    const haystack = "alpha\r\nbeta(\r\n    gamma,\r\n)\r\n";
    try std.testing.expectEqual(
        @as(?usize, null),
        indexOfIgnoringCarriageReturns(haystack, "beta(\n    delta,"),
    );
    try std.testing.expect(!containsIgnoringCarriageReturns(haystack, "omega"));
    try std.testing.expectEqual(
        @as(usize, 0),
        countIgnoringCarriageReturns(haystack, "beta(\n    delta,"),
    );
}

test "ordering comparisons survive because offsets are original-haystack offsets" {
    const haystack = "first(\r\n    a,\r\n);\r\nsecond(\r\n    b,\r\n);\r\n";
    const first = indexOfIgnoringCarriageReturns(haystack, "first(\n    a,").?;
    const second = indexOfIgnoringCarriageReturns(haystack, "second(\n    b,").?;
    try std.testing.expect(first < second);
    try std.testing.expectEqual(@as(usize, 0), first);
}

test "counting is non-overlapping and CR-insensitive" {
    const haystack = "x(\r\n1,\r\n);x(\r\n1,\r\n);x(\r\n1,\r\n);";
    try std.testing.expectEqual(
        @as(usize, 3),
        countIgnoringCarriageReturns(haystack, "x(\n1,\n);"),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        countIgnoringCarriageReturns("x(\n1,\n);x(\n1,\n);x(\n1,\n);", "x(\n1,\n);"),
    );
    try std.testing.expectEqual(@as(usize, 0), countIgnoringCarriageReturns(haystack, ""));
}

test "searching from a position skips earlier occurrences" {
    const haystack = "hit(\r\n0,\r\n);hit(\r\n0,\r\n);";
    const needle = "hit(\n0,\n);";
    const first = indexOfPosIgnoringCarriageReturns(haystack, 0, needle).?;
    const second = indexOfPosIgnoringCarriageReturns(haystack, first + 1, needle).?;
    try std.testing.expect(second > first);
    try std.testing.expectEqual(
        @as(?usize, null),
        indexOfPosIgnoringCarriageReturns(haystack, second + 1, needle),
    );
}

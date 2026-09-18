const std = @import("std");

/// Delimiters accepted by ecosys input records. File extensions carry no
/// meaning: .csv, .txt, and extensionless files use the same parser.
pub const delimiters = " \t,|\r\n";
pub const record_delimiters = " \t,|\r";

pub const TokenIterator = struct {
    source: []const u8,
    index: usize = 0,
    allow_newlines: bool,

    pub fn next(self: *TokenIterator) ?[]const u8 {
        while (self.index < self.source.len) {
            const byte = self.source[self.index];
            if (byte == '#') {
                while (self.index < self.source.len and self.source[self.index] != '\n') self.index += 1;
                if (!self.allow_newlines) return null;
                continue;
            }
            if (std.mem.indexOfScalar(u8, if (self.allow_newlines) delimiters else record_delimiters, byte) != null) {
                self.index += 1;
                continue;
            }
            const start = self.index;
            while (self.index < self.source.len) : (self.index += 1) {
                const current = self.source[self.index];
                if (current == '#' or std.mem.indexOfScalar(u8, if (self.allow_newlines) delimiters else record_delimiters, current) != null) break;
            }
            return self.source[start..self.index];
        }
        return null;
    }
};

pub fn tokens(source: []const u8) TokenIterator {
    return .{ .source = source, .allow_newlines = true };
}

pub fn recordTokens(record: []const u8) TokenIterator {
    return .{ .source = record, .allow_newlines = false };
}

/// Iterates physical input records while ignoring blank and comment-only
/// lines. Returned slices retain their trailing comment; `recordTokens`
/// consistently removes it while counting schema values.
pub const RecordIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *RecordIterator) ?[]const u8 {
        while (self.lines.next()) |line| {
            var fields = recordTokens(line);
            if (fields.next() != null) return line;
        }
        return null;
    }
};

pub fn records(source: []const u8) RecordIterator {
    return .{ .lines = std.mem.splitScalar(u8, source, '\n') };
}

pub fn requireNoTrailingValues(iterator: *TokenIterator) !void {
    if (iterator.next() != null) return error.TrailingInputRecordData;
}

pub fn parseYesNo(text: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(text, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(text, "no")) return false;
    return error.InvalidYesNoValue;
}

pub fn isNo(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "no");
}

test "all supported delimiters are equivalent" {
    var values = tokens("alpha,beta\tgamma delta|epsilon\r\nzeta");
    const expected = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta" };
    for (expected) |item| try std.testing.expectEqualStrings(item, values.next().?);
    try std.testing.expect(values.next() == null);
}

test "hash comments are ignored on separate and trailing lines" {
    var values = tokens(
        \\alpha,beta # units and explanation
        \\# whole-line comment
        \\gamma|delta
    );
    const expected = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    for (expected) |item| try std.testing.expectEqualStrings(item, values.next().?);
    try std.testing.expect(values.next() == null);

    var record = recordTokens("one two # trailing words are not values");
    try std.testing.expectEqualStrings("one", record.next().?);
    try std.testing.expectEqualStrings("two", record.next().?);
    try std.testing.expect(record.next() == null);
}

test "record iterator skips blank and comment-only lines without joining schemas" {
    var input_records = records(
        \\# description
        \\
        \\first,1 # comment
        \\second|2
    );
    var first = recordTokens(input_records.next().?);
    try std.testing.expectEqualStrings("first", first.next().?);
    try std.testing.expectEqualStrings("1", first.next().?);
    try requireNoTrailingValues(&first);
    var second = recordTokens(input_records.next().?);
    try std.testing.expectEqualStrings("second", second.next().?);
    try std.testing.expectEqualStrings("2", second.next().?);
    try requireNoTrailingValues(&second);
    try std.testing.expect(input_records.next() == null);
}

test "boolean controls accept every ASCII casing" {
    try std.testing.expect(try parseYesNo("YES"));
    try std.testing.expect(try parseYesNo("Yes"));
    try std.testing.expect(try parseYesNo("yes"));
    try std.testing.expect(!(try parseYesNo("nO")));
}

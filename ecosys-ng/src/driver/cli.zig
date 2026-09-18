const std = @import("std");

pub const Options = struct {
    runscript_path: []const u8,
    thread_limit: ?usize,
    /// Parse the same input/domain plan as a simulation, then emit its complete
    /// execution timeline without initializing science or creating outputs.
    describe_timeline: bool = false,
    execution_evidence_path: ?[]const u8 = null,
    /// Survey the conservation audits instead of halting on the first breach.
    ///
    /// **This does not relax a single tolerance.** Every audit is evaluated at
    /// exactly the same limits; the only change is that a failure is recorded
    /// and the run continues, instead of aborting the hour. The purpose is to
    /// obtain the full-horizon list of balance defects in one run rather than
    /// discovering them one abort at a time -- the deck currently stops at day
    /// 14 of a 30-year horizon, so a single breach hides everything after it.
    ///
    /// A run with this set is NOT production evidence and cannot be: the
    /// simulation continues from a state the model itself judged
    /// non-conserving, so every number after the first breach is downstream of
    /// an unreconciled error. `production_acceptance.ps1` must fail such a run,
    /// and the startup banner and the end-of-run survey both say so.
    survey_conservation: bool = false,
};

/// Parses the allocation-free production command line. `thread_limit` is a
/// ceiling on total execution participants, including the coordinating caller.
pub fn parse(args: []const [:0]const u8) !Options {
    var runscript_path: ?[]const u8 = null;
    var thread_limit: ?usize = null;
    var survey_conservation = false;
    var describe_timeline = false;
    var execution_evidence_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--execution-evidence")) {
            if (execution_evidence_path != null) return error.DuplicateExecutionEvidenceOption;
            index += 1;
            if (index >= args.len or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.MissingExecutionEvidencePath;
            execution_evidence_path = args[index];
        } else if (std.mem.eql(u8, argument, "--describe-timeline")) {
            if (describe_timeline) return error.DuplicateDescribeTimelineOption;
            describe_timeline = true;
        } else if (std.mem.eql(u8, argument, "--survey-conservation")) {
            if (survey_conservation) return error.DuplicateSurveyConservationOption;
            survey_conservation = true;
        } else if (std.mem.eql(u8, argument, "--threads")) {
            if (thread_limit != null) return error.DuplicateThreadsOption;
            index += 1;
            if (index >= args.len) return error.MissingThreadCount;
            const count = std.fmt.parseUnsigned(usize, args[index], 10) catch
                return error.InvalidThreadCount;
            if (count == 0) return error.InvalidThreadCount;
            thread_limit = count;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownCommandLineOption;
        } else {
            if (runscript_path != null) return error.MultipleRunscriptPaths;
            runscript_path = argument;
        }
    }
    if (describe_timeline and execution_evidence_path != null) return error.IncompatibleExecutionEvidenceOptions;
    return .{
        .runscript_path = runscript_path orelse return error.MissingRunscriptPath,
        .thread_limit = thread_limit,
        .survey_conservation = survey_conservation,
        .describe_timeline = describe_timeline,
        .execution_evidence_path = execution_evidence_path,
    };
}

test "timeline inspection is explicit and rejects duplicate options" {
    const defaults = [_][:0]const u8{ "ecosys_ng", "runottawa" };
    try std.testing.expect(!(try parse(&defaults)).describe_timeline);
    const inspection = [_][:0]const u8{ "ecosys_ng", "--describe-timeline", "runottawa" };
    try std.testing.expect((try parse(&inspection)).describe_timeline);
    const duplicate = [_][:0]const u8{ "ecosys_ng", "--describe-timeline", "--describe-timeline", "runottawa" };
    try std.testing.expectError(error.DuplicateDescribeTimelineOption, parse(&duplicate));
}

test "execution evidence CLI requires one explicit journal path" {
    const defaults = [_][:0]const u8{ "ecosys_ng", "runottawa" };
    try std.testing.expect((try parse(&defaults)).execution_evidence_path == null);
    const journal = [_][:0]const u8{ "ecosys_ng", "--execution-evidence", "new journal.jsonl", "runottawa" };
    try std.testing.expectEqualStrings("new journal.jsonl", (try parse(&journal)).execution_evidence_path.?);
    const duplicate = [_][:0]const u8{ "ecosys_ng", "--execution-evidence", "a", "--execution-evidence", "b", "runottawa" };
    try std.testing.expectError(error.DuplicateExecutionEvidenceOption, parse(&duplicate));
    const missing = [_][:0]const u8{ "ecosys_ng", "runottawa", "--execution-evidence" };
    try std.testing.expectError(error.MissingExecutionEvidencePath, parse(&missing));
    const empty = [_][:0]const u8{ "ecosys_ng", "--execution-evidence", "", "runottawa" };
    try std.testing.expectError(error.MissingExecutionEvidencePath, parse(&empty));
    const option = [_][:0]const u8{ "ecosys_ng", "--execution-evidence", "--describe-timeline", "runottawa" };
    try std.testing.expectError(error.MissingExecutionEvidencePath, parse(&option));
    const incompatible = [_][:0]const u8{ "ecosys_ng", "--describe-timeline", "--execution-evidence", "a", "runottawa" };
    try std.testing.expectError(error.IncompatibleExecutionEvidenceOptions, parse(&incompatible));
}

test "production CLI accepts runscript default and explicit thread ceiling" {
    const default_args = [_][:0]const u8{ "ecosys_ng", "runottawa" };
    const defaults = try parse(&default_args);
    try std.testing.expectEqualStrings("runottawa", defaults.runscript_path);
    try std.testing.expectEqual(@as(?usize, null), defaults.thread_limit);

    const threaded_args = [_][:0]const u8{ "ecosys_ng", "--threads", "4", "runottawa" };
    const threaded = try parse(&threaded_args);
    try std.testing.expectEqualStrings("runottawa", threaded.runscript_path);
    try std.testing.expectEqual(@as(?usize, 4), threaded.thread_limit);
}

test "conservation survey is off unless explicitly requested" {
    // The default matters more than the flag: a run that silently continued
    // past a conservation breach would publish numbers downstream of an
    // unreconciled error while looking like an ordinary run.
    const default_args = [_][:0]const u8{ "ecosys_ng", "runottawa" };
    try std.testing.expect(!(try parse(&default_args)).survey_conservation);

    const surveyed = [_][:0]const u8{ "ecosys_ng", "--survey-conservation", "runottawa" };
    const options = try parse(&surveyed);
    try std.testing.expect(options.survey_conservation);
    try std.testing.expectEqualStrings("runottawa", options.runscript_path);

    const combined = [_][:0]const u8{ "ecosys_ng", "--survey-conservation", "--threads", "4", "runottawa" };
    const both = try parse(&combined);
    try std.testing.expect(both.survey_conservation);
    try std.testing.expectEqual(@as(?usize, 4), both.thread_limit);

    const duplicate = [_][:0]const u8{ "ecosys_ng", "--survey-conservation", "--survey-conservation", "runottawa" };
    try std.testing.expectError(error.DuplicateSurveyConservationOption, parse(&duplicate));
}

test "production CLI rejects ambiguous or invalid thread requests" {
    const missing_path = [_][:0]const u8{"ecosys_ng"};
    try std.testing.expectError(error.MissingRunscriptPath, parse(&missing_path));

    const missing_count = [_][:0]const u8{ "ecosys_ng", "--threads" };
    try std.testing.expectError(error.MissingThreadCount, parse(&missing_count));

    const zero = [_][:0]const u8{ "ecosys_ng", "--threads", "0", "runottawa" };
    try std.testing.expectError(error.InvalidThreadCount, parse(&zero));

    const invalid = [_][:0]const u8{ "ecosys_ng", "--threads", "many", "runottawa" };
    try std.testing.expectError(error.InvalidThreadCount, parse(&invalid));

    const overflow = [_][:0]const u8{ "ecosys_ng", "--threads", "999999999999999999999999999999999999999", "runottawa" };
    try std.testing.expectError(error.InvalidThreadCount, parse(&overflow));

    const duplicate = [_][:0]const u8{ "ecosys_ng", "--threads", "2", "--threads", "4", "runottawa" };
    try std.testing.expectError(error.DuplicateThreadsOption, parse(&duplicate));

    const unknown = [_][:0]const u8{ "ecosys_ng", "--workers", "4", "runottawa" };
    try std.testing.expectError(error.UnknownCommandLineOption, parse(&unknown));

    const multiple_paths = [_][:0]const u8{ "ecosys_ng", "first", "second" };
    try std.testing.expectError(error.MultipleRunscriptPaths, parse(&multiple_paths));
}

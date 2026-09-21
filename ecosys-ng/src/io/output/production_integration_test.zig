const std = @import("std");

const driver_source = @embedFile("../../ecosys_ng.zig");

test "production output identity uses the complete timeline and global storage slots" {
    var lines = std.mem.splitScalar(u8, driver_source, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "const file_name = try ecosys.output_record.buildOutputFileName(") == null) continue;
        count += 1;
        try std.testing.expect(std.mem.indexOf(u8, line, "try ecosys.output_record.PassOrdinals.fromScenePass(accepted_context.pass.*), cell + 1,") != null);
        if (std.mem.indexOf(u8, line, "species_label") != null)
            try std.testing.expect(std.mem.indexOf(u8, line, ".population_number = species + 1") != null);
    }
    try std.testing.expectEqual(@as(usize, 19), count);
    // Visualization uses the same pass conversion and adds its own global cell.
    try std.testing.expectEqual(@as(usize, 21), std.mem.count(u8, driver_source, "PassOrdinals.fromScenePass(accepted_context.pass.*)"));
}

test "model hour driver binds canonical endpoints and distinct consumer clocks" {
    // These assertions bind the separately exercised clock functions to every
    // production output/persistence producer and both advance/resume readers.
    try std.testing.expectEqual(@as(usize, 13), std.mem.count(u8, driver_source, "try accepted_context.timestamp.*.modelHourIndex()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, driver_source, "try checkpoint_timestamp.modelHourIndex()"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, driver_source, ".modelClockHour()"));
    const read_start = try requiredIndex("noinline fn advanceHour(");
    const normalize = try requiredIndex("advance_context.weather_hour_by_stream.*[stream_index].timestamp = try");
    const raw_compare = std.mem.indexOfPos(u8, driver_source, normalize, "sameWeatherTimestamp(") orelse return error.MissingOutputTransactionIntegration;
    const attempt = try requiredIndex("journal.attempt(.{");
    try std.testing.expect(read_start < normalize and normalize < raw_compare and raw_compare < attempt);
    try std.testing.expect(std.mem.indexOf(u8, driver_source, "skipped.timestamp = try skipped.timestamp.modelHour(active_options.start_date.year)") != null);
    try std.testing.expect(std.mem.indexOf(u8, driver_source, "const irrigation_source_hour: u8 = try prepare_context.timestamp.*.modelHourIndex() + 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, driver_source, "if (accepted_context.timestamp.*.hour == 24) 23 else") == null);
}

// issue-076: these helpers search an `@embedFile`'d copy of this repository's
// own driver source, so on a CRLF checkout a needle written with `\n` cannot
// match. Scan CR-insensitively instead of assuming the checkout's line endings.
const source_scan = @import("../../core/source_scan.zig");

fn requiredIndex(needle: []const u8) !usize {
    return source_scan.indexOfIgnoringCarriageReturns(driver_source, needle) orelse
        error.MissingOutputTransactionIntegration;
}

fn requiredIndexIn(source: []const u8, needle: []const u8) !usize {
    return source_scan.indexOfIgnoringCarriageReturns(source, needle) orelse
        error.MissingOutputTransactionIntegration;
}

fn assertEveryOccurrenceBetween(needle: []const u8, first: usize, last: usize, expected_count: usize) !void {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, driver_source, offset, needle)) |position| {
        try std.testing.expect(position > first and position < last);
        count += 1;
        offset = position + needle.len;
    }
    try std.testing.expectEqual(expected_count, count);
}

test "production output writes share one generation and checkpoint acknowledges last" {
    const output_phase_start = try requiredIndex("noinline fn writeAcceptedHourOutputs(");
    const hourly_phase_start = try requiredIndex("noinline fn writeAcceptedHourlyOutputs(");
    const finish_phase_start = try requiredIndex("noinline fn finishAcceptedHourOutputs(");
    const post_science_start = try requiredIndex("noinline fn postScienceAccounting(");
    const accept_phase_start = try requiredIndex("noinline fn acceptHourAndPublish(");
    const prepare_phase_start = try requiredIndex("noinline fn prepareHourlyScience(");
    const output_phase = driver_source[output_phase_start..hourly_phase_start];
    const finish_phase = driver_source[finish_phase_start..post_science_start];
    const accept_phase = driver_source[accept_phase_start..prepare_phase_start];

    const scientific_commit = try requiredIndexIn(accept_phase, "outer_hour_transaction.*.commit();");
    const output_phase_call = try requiredIndexIn(accept_phase, "try writeAcceptedHourOutputs(");
    const begin = output_phase_start + try requiredIndexIn(output_phase, "try driver_context.output_hour_coordinator.*.beginHour(");
    const hourly_call = try requiredIndexIn(output_phase, "try writeAcceptedHourlyOutputs(");
    const daily_call = try requiredIndexIn(output_phase, "try writeAcceptedDailyOutputs(");
    const finish_call = try requiredIndexIn(output_phase, "try finishAcceptedHourOutputs(");
    const commit = finish_phase_start + try requiredIndexIn(finish_phase, "try driver_context.output_hour_coordinator.*.commitHour();");
    const checkpoint_will_publish = finish_phase_start + try requiredIndexIn(finish_phase, "try driver_context.output_hour_coordinator.*.checkpointWillPublish();");
    const checkpoint_publish = finish_phase_start + try requiredIndexIn(finish_phase, "try ecosys.checkpoint_bundle_writer.publish(");
    const checkpoint_did_publish = finish_phase_start + try requiredIndexIn(finish_phase, "try driver_context.output_hour_coordinator.*.checkpointDidPublish(");

    // The explicit call edges are the execution-order boundaries across the
    // noinline phases: science commits, then one output generation runs its
    // hourly, daily, and finish/checkpoint phases in that order.
    try std.testing.expect(scientific_commit < output_phase_call);
    try std.testing.expect(hourly_call < daily_call);
    try std.testing.expect(daily_call < finish_call);
    try assertEveryOccurrenceBetween(".streams[", begin, commit, 20);
    try assertEveryOccurrenceBetween("visualization_streams.*.calculateAndWriteHourly(", begin, commit, 1);
    try assertEveryOccurrenceBetween("visualization_streams.*.calculateAndWriteDaily(", begin, commit, 1);
    try std.testing.expect(commit < checkpoint_will_publish);
    try std.testing.expect(checkpoint_will_publish < checkpoint_publish);
    try std.testing.expect(checkpoint_publish < checkpoint_did_publish);
}

test "production phase extraction preserves timeline call order and main binding" {
    const initialize_start = try requiredIndex("noinline fn initializeTimeline(");
    const finish_start = try requiredIndex("noinline fn finishTimeline(");
    const output_start = try requiredIndex("noinline fn writeAcceptedHourOutputs(");
    const timeline_start = try requiredIndex("noinline fn runTimeline(");
    const main_start = try requiredIndex("pub fn main(");
    try std.testing.expect(initialize_start < finish_start);
    try std.testing.expect(finish_start < output_start);
    try std.testing.expect(output_start < timeline_start);
    try std.testing.expect(timeline_start < main_start);

    const advance_start = try requiredIndex("noinline fn advanceHour(");
    const prepare_start = try requiredIndex("noinline fn prepareHourlyScience(");
    const accept_start = try requiredIndex("noinline fn acceptHourAndPublish(");
    const timeline_phase = driver_source[timeline_start..main_start];
    const advance_phase = driver_source[advance_start..timeline_start];
    const accept_phase = driver_source[accept_start..prepare_start];
    const initialize_call = try requiredIndexIn(timeline_phase, "try initializeTimeline(driver_context)");
    const advance_call = try requiredIndexIn(timeline_phase, "try advanceHour(driver_context,");
    const finish_call = try requiredIndexIn(timeline_phase, "try finishTimeline(driver_context,");
    try std.testing.expect(initialize_call < advance_call);
    try std.testing.expect(advance_call < finish_call);

    const prepare_call = try requiredIndexIn(advance_phase, "try prepareHourlyScience(driver_context,");
    const science_call = try requiredIndexIn(advance_phase, "executeHourlyScience(");
    const post_call = try requiredIndexIn(advance_phase, "try postScienceAccounting(driver_context,");
    const accept_call = try requiredIndexIn(advance_phase, "try acceptHourAndPublish(driver_context,");
    try std.testing.expect(prepare_call < science_call);
    try std.testing.expect(science_call < post_call);
    try std.testing.expect(post_call < accept_call);
    _ = try requiredIndexIn(accept_phase, "try writeAcceptedHourOutputs(driver_context,");

    const main_phase = driver_source[main_start..];
    const context = try requiredIndexIn(main_phase, "const timeline_context = .{");
    const timeline_call = try requiredIndexIn(main_phase, "try runTimeline(&timeline_context,");
    try std.testing.expect(context < timeline_call);
    // Both journaled and unjournaled execution cross the same timeline owner
    // after context initialization; neither branch may bypass it.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, main_phase, "try runTimeline(&timeline_context,"));
    _ = try requiredIndexIn(main_phase, "try runTimeline(&timeline_context, &evidence_writer.interface, path);");
    _ = try requiredIndexIn(main_phase, "try runTimeline(&timeline_context, null, \"\");");
}

test "main resources own long lived allocations before timeline execution" {
    const main_start = try requiredIndex("pub fn main(");
    const main_phase = driver_source[main_start..];
    const resources_init = try requiredIndexIn(main_phase, "var resources = MainResources.init(allocator, init.io);");
    const resources_deinit = try requiredIndexIn(main_phase, "defer resources.deinit();");
    const rollback_owner = try requiredIndexIn(main_phase, "resources.ownDeinit(&outer_hour_transaction_workspace);");
    const run_plan = try requiredIndexIn(main_phase, "var run_plan: RunPlanOwners = undefined;");
    const run_plan_init = try requiredIndexIn(main_phase, "try initializeRunPlan(");
    const output_plan = try requiredIndexIn(main_phase, "var output_plan: OutputPlanOwners = undefined;");
    const output_plan_init = try requiredIndexIn(main_phase, "try initializeOutputPlan(");
    const accounting_outputs = try requiredIndexIn(main_phase, "var accounting_outputs: AccountingOutputOwners = undefined;");
    const accounting_outputs_init = try requiredIndexIn(main_phase, "try initializeAccountingOutputs(");
    const final_owner = try requiredIndexIn(main_phase, "resources.ownDeinit(&lateral_contribution_workspace);");
    const timeline_context = try requiredIndexIn(main_phase, "const timeline_context = .{");
    const timeline_call = try requiredIndexIn(main_phase, "try runTimeline(&timeline_context,");

    try std.testing.expect(resources_init < resources_deinit);
    try std.testing.expect(resources_deinit < rollback_owner);
    try std.testing.expect(rollback_owner < run_plan);
    try std.testing.expect(run_plan < run_plan_init);
    try std.testing.expect(run_plan_init < output_plan);
    try std.testing.expect(output_plan < output_plan_init);
    try std.testing.expect(output_plan_init < accounting_outputs);
    try std.testing.expect(accounting_outputs < accounting_outputs_init);
    try std.testing.expect(accounting_outputs_init < final_owner);
    try std.testing.expect(final_owner < timeline_context);
    try std.testing.expect(timeline_context < timeline_call);

    // Each moved owner is registered exactly once in its final-address
    // initializer; main contains aliases only, never a second cleanup owner.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, driver_source, "resources.ownFree(&owners.source);"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, driver_source, "resources.ownDeinit(&owners.runscript);"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, driver_source, "resources.ownDeinit(&owners.landscape_mass_balance_state);"));
}

test "production initializes every output bank and visualization transactionally" {
    var bank_init_count: usize = 0;
    var offset: usize = 0;
    const bank_init = "output_stream_bank.Bank.initTransactional(";
    while (std.mem.indexOfPos(u8, driver_source, offset, bank_init)) |position| {
        bank_init_count += 1;
        offset = position + bank_init.len;
    }
    try std.testing.expectEqual(@as(usize, 20), bank_init_count);
    _ = try requiredIndex("visualization_output.Streams.initTransactional(");
}

test "hourly soil water output includes accepted ground evaporation" {
    const hourly_start = try requiredIndex("noinline fn writeAcceptedHourlyOutputs(");
    const daily_start = try requiredIndex("noinline fn writeAcceptedDailyOutputs(");
    const hourly_phase = driver_source[hourly_start..daily_start];
    _ = try requiredIndexIn(
        hourly_phase,
        "var evapotranspiration_m3: f64 =\n                    driver_context.ground_surface_evaporation_m3_per_h.*[cell];",
    );
}

test "production resume selects only the canonical root bound into the checkpoint" {
    const output_plan_start = try requiredIndex("noinline fn initializeOutputPlan(");
    const accounting_outputs_start = try requiredIndex("const AccountingOutputOwners = struct {");
    const output_plan_phase = driver_source[output_plan_start..accounting_outputs_start];
    const manifest_read = try requiredIndex("checkpoint_bundle_reader.readManifest(");
    const output_identity = try requiredIndexIn(output_plan_phase, "owners.output_run_identity = ecosys.output_record.runIdentity(source);");
    const manifest_identity_check = try requiredIndexIn(output_plan_phase, "manifest.output.run_identity != owners.output_run_identity");
    const canonical_resume = try requiredIndex("OutputTree.resumeCanonical(");
    const coordinator_init = try requiredIndex("output_hour_transaction.Coordinator.init(");
    try std.testing.expect(manifest_read < canonical_resume);
    try std.testing.expect(canonical_resume < coordinator_init);
    try std.testing.expect(output_identity < manifest_identity_check);
    try std.testing.expect(std.mem.indexOf(u8, driver_source, "OutputTree.resumeExisting(") == null);
    _ = try requiredIndexIn(output_plan_phase, "manifest.output.run_identity != owners.output_run_identity");
    _ = try requiredIndex(".canonical_root = driver_context.output_tree.*.root_path");
    _ = try requiredIndex("restored.manifest.output.fingerprint != selected_output_manifest.output.fingerprint");
}

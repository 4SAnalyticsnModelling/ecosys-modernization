const std = @import("std");
const ecosys = @import("ecosys_ng");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2 and args.len != 3) return error.ExpectedHeatSnapshotPath;
    // Optional `--trace` installs the solver's ready-made per-iteration and
    // per-priced-direction tracing. It changes no control: `diagnostic_trace`
    // is observation-only, and the captured snapshot replays bit-for-bit either
    // way, so a traced run and an untraced run are the same solve.
    const trace = args.len == 3 and std.mem.eql(u8, args[2], "--trace");
    if (args.len == 3 and !trace) return error.UnknownHeatReplayOption;
    const allocator = init.arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(ecosys.heat_failure_snapshot.maximum_bytes));
    var input = try ecosys.heat_failure_snapshot.decode(allocator, bytes);
    if (trace) input.options.diagnostic_trace = &ecosys.soil_heat_solver.debug_print_trace;
    const output = try allocator.alloc(f64, input.faces.len);
    const result = try ecosys.soil_heat_solver.solve(allocator, &input.grid, input.faces, input.properties, input.water_fluxes, output, input.options);
    std.debug.print("heat replay result={any}\ntemperature_k={any}\n", .{ result, input.grid.soil_temperature_k });
}

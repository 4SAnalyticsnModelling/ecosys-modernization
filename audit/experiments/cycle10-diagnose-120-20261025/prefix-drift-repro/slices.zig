const std = @import("std");
fn h(x: f64) u64 { return @bitCast(x); }
pub fn main() !void {
    const cells = try std.heap.page_allocator.alloc(f64, 1);
    cells[0] = 3.39519326554e-313;
    const x = cells[0];
    const pt: f64 = blk: { var t: f64 = 0; for (0..3) |_| t += cells[0] * 0 + 2e-11; break :blk t; };
    var raw: [3]f64 = undefined;
    for (&raw) |*r| r.* = @max(@as(f64, 0.001), 2e-11 / pt);
    var rs: f64 = 0;
    for (raw) |r| rs += r;
    var frac: [3]f64 = undefined;
    for (&frac, 0..) |*fp, i| fp.* = raw[i] / rs;
    var s: f64 = 0;
    for (frac) |fv| s += x * fv;
    std.debug.print("pt={x} raw={x} rs={x} frac={x} slices=", .{ h(pt), h(raw[0]), h(rs), h(frac[0]) });
    for (frac) |fv| std.debug.print("{x} ", .{h(x * fv)});
    std.debug.print("x={x} s={x} delta={any}\n", .{ h(x), h(s), s - x });
}

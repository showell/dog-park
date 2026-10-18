const std = @import("std");

const Step = extern struct { x: i32, y: i32 };
extern fn roc_flee(dx: i32, dy: i32, cx: i32, cy: i32) callconv(.c) Step;

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    std.debug.panic("roc crashed: {s}", .{bytes[0..len]});
}

const world: i32 = 2100 * 256;
const half_world: i32 = @divExact(world, 2);
const wary: i32 = 158 * 256;

fn shortWay(d: i32) i32 {
    const w = @mod(d, world);
    return if (w > half_world) w - world else w;
}

fn sign(v: i32) i32 {
    return if (v > 0) 1 else if (v < 0) -1 else 0;
}

fn fleeZig(dx: i32, dy: i32, cx: i32, cy: i32) Step {
    const ox = shortWay(cx - dx);
    const oy = shortWay(cy - dy);
    const d2 = @as(i64, ox) * ox + @as(i64, oy) * oy;
    if (d2 < @as(i64, wary) * wary) return .{ .x = cx + sign(ox) * 256, .y = cy + sign(oy) * 256 };
    return .{ .x = cx, .y = cy };
}

noinline fn fleeZigCall(dx: i32, dy: i32, cx: i32, cy: i32) Step {
    return fleeZig(dx, dy, cx, cy);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const n = 1 << 20;
    const pts = try std.heap.page_allocator.alloc([4]i32, n);
    var rng = std.Random.DefaultPrng.init(42);
    const r = rng.random();
    for (pts, 0..) |*p, i| {
        // Half near (within 200 px), half anywhere.
        const near = i % 2 == 0;
        const dx = r.intRangeLessThan(i32, 0, world);
        const dy = r.intRangeLessThan(i32, 0, world);
        const spread: i32 = if (near) 200 * 256 else world;
        p.* = .{ dx, dy, dx + r.intRangeLessThan(i32, -spread, spread), dy + r.intRangeLessThan(i32, -spread, spread) };
    }
    for (pts) |p| {
        const a = roc_flee(p[0], p[1], p[2], p[3]);
        const b = fleeZig(p[0], p[1], p[2], p[3]);
        if (a.x != b.x or a.y != b.y) std.debug.panic("differ at {any}: roc {any}, zig {any}", .{ p, a, b });
    }
    std.debug.print("agree on {d} pairs\n", .{n});
    const rounds = 20;
    inline for (.{ "roc", "zig noinline", "zig inline" }) |which| {
        var sum: i64 = 0;
        const t0 = std.Io.Clock.awake.now(io).nanoseconds;
        for (0..rounds) |_| for (pts) |p| {
            const s = if (comptime std.mem.eql(u8, which, "roc")) roc_flee(p[0], p[1], p[2], p[3]) else if (comptime std.mem.eql(u8, which, "zig noinline")) fleeZigCall(p[0], p[1], p[2], p[3]) else fleeZig(p[0], p[1], p[2], p[3]);
            sum +%= s.x +% s.y;
        };
        const ns = std.Io.Clock.awake.now(io).nanoseconds - t0;
        std.debug.print("{s}: {d:.2} ns a call (sum {d})\n", .{ which, @as(f64, @floatFromInt(ns)) / (rounds * n), sum });
    }
}

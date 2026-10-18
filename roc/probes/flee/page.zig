const Step = extern struct { x: i32, y: i32 };
extern fn roc_flee(dx: i32, dy: i32, cx: i32, cy: i32) callconv(.c) Step;

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = bytes;
    _ = len;
    @trap();
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

var pts: [1 << 16][4]i32 = undefined;

export fn fill(seed: u32) void {
    var s: u32 = seed;
    for (&pts, 0..) |*p, i| {
        var v: [4]i32 = undefined;
        for (&v) |*x| {
            s = s *% 1664525 +% 1013904223;
            x.* = @intCast(s % @as(u32, @intCast(world)));
        }
        if (i % 2 == 0) {
            v[2] = v[0] + @rem(v[2], 400 * 256) - 200 * 256;
            v[3] = v[1] + @rem(v[3], 400 * 256) - 200 * 256;
        }
        p.* = v;
    }
}

/// 0: roc, 1: zig. Returns a checksum.
export fn run(which: u32, rounds: u32) i32 {
    var sum: i32 = 0;
    for (0..rounds) |_| for (&pts) |p| {
        const st = if (which == 0) roc_flee(p[0], p[1], p[2], p[3]) else fleeZig(p[0], p[1], p[2], p[3]);
        sum +%= st.x +% st.y;
    };
    return sum;
}

export fn disagree() u32 {
    var n: u32 = 0;
    for (&pts) |p| {
        const a = roc_flee(p[0], p[1], p[2], p[3]);
        const b = fleeZig(p[0], p[1], p[2], p[3]);
        if (a.x != b.x or a.y != b.y) n += 1;
    }
    return n;
}

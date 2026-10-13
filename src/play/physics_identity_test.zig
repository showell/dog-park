//! The physics against `physics_reference.zig` (the physics before its
//! neighbour lists and overlap marks): long seeded dragged sessions, run
//! both ways, every board and every tick's lines compared after every tick.
//! And the tick's pair checks, bounded, so the cost cannot creep back.

const std = @import("std");
const testing = std.testing;
const physics = @import("physics.zig");
const reference = @import("physics_reference.zig");
const Board = physics.Board;
const Point = physics.Point;

fn px(x: i32, y: i32) Point {
    return .{ .x = physics.px(x), .y = physics.px(y) };
}

/// The bench's packed herd: dogs on a 45 px grid around dog 0, leashed, the
/// cows in columns beside them.
fn packedHerd() Board {
    var herd = Board.empty();
    const c0 = 16000;
    herd.place(.dog(0), px(c0, c0));
    herd.hold = .{ .leashed = .{ .dog = 0, .drag = .on } };
    var n: u16 = 1;
    var gy: i32 = -7;
    outer: while (gy <= 7) : (gy += 1) {
        var gx: i32 = -7;
        while (gx <= 7) : (gx += 1) {
            if (@max(@abs(gx), @abs(gy)) <= 1) continue;
            if (n == physics.dog_count) break :outer;
            herd.place(.dog(n), px(c0 + 45 * gx, c0 + 45 * gy));
            n += 1;
        }
    }
    var cow: u16 = 0;
    for ([_]i32{ -440, -375, 375, 440 }) |x| {
        var y: i32 = -330;
        while (y <= 330 and cow < physics.cow_count) : (y += 64) {
            herd.place(.cow(cow), px(c0 + x, c0 + y));
            cow += 1;
        }
    }
    return herd;
}

/// A crowd thrown down at random around dog 0, overlaps and all: the
/// out-from-under path's work.
fn thrownCrowd(r: std.Random) Board {
    var b = Board.empty();
    const c0 = 16000;
    b.place(.dog(0), px(c0, c0));
    b.hold = .{ .leashed = .{ .dog = 0, .drag = .on } };
    for (1..120) |i| b.place(.dog(@intCast(i)), px(c0 + r.intRangeAtMost(i32, -350, 350), c0 + r.intRangeAtMost(i32, -350, 350)));
    for (0..30) |i| b.place(.cow(@intCast(i)), px(c0 + r.intRangeAtMost(i32, -450, 450), c0 + r.intRangeAtMost(i32, -450, 450)));
    return b;
}

fn linesEqual(a: *const physics.Lines, b: *const physics.Lines) bool {
    if (a.len != b.len) return false;
    for (a.slice(), b.slice()) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

const Session = struct { jumps: usize = 0, ticks: usize = 0 };

/// `ticks` ticks of seeded drags (now and then a let-go, then a grab), the
/// physics and the reference side by side from `start`.
fn session(start: Board, seed: u64, ticks: usize) !Session {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var fast = start;
    var slow = start;
    var lf: physics.Lines = .{};
    var ls: physics.Lines = .{};
    var got: Session = .{};
    var t: physics.Tick = 1;
    while (t <= ticks) : (t += 1) {
        var humans: [1]physics.Human = undefined;
        var hn: usize = 0;
        if (fast.hold == .leashed and fast.hold.leashed.drag != .on and r.uintLessThan(u8, 4) == 0) {
            humans[0] = .grab;
            hn = 1;
        } else if (r.uintLessThan(u8, 40) == 0) {
            humans[0] = .letgo;
            hn = 1;
        }
        var raw: [4]physics.Disp = undefined;
        const k = r.uintLessThan(usize, 5);
        for (raw[0..k]) |*d| d.* = .{ .dx = r.intRangeAtMost(i32, -physics.cap, physics.cap), .dy = r.intRangeAtMost(i32, -physics.cap, physics.cap) };
        const drag = physics.mergeAndCap(raw[0..k]);
        const rf = physics.tick(&fast, t, humans[0..hn], drag.slice(), &lf);
        const rs = reference.tick(&slow, t, humans[0..hn], drag.slice(), &ls);
        try testing.expectEqual(rs, rf);
        if (!std.meta.eql(fast, slow) or !linesEqual(&lf, &ls)) {
            std.debug.print("seed {d}: the physics and the reference part at tick {d}\n", .{ seed, t });
            return error.Parted;
        }
        got.jumps += lf.jumped.count();
        got.ticks += 1;
    }
    return got;
}

test "the physics plays long seeded dragged sessions board for board as the reference does: the laid-out park, a packed herd, thrown crowds" {
    var park = Board.laidOut();
    park.hold = .{ .leashed = .{ .dog = 47, .drag = .on } };
    var jumps: usize = 0;
    for (0..3) |seed| jumps += (try session(park, seed, 160)).jumps;
    for (0..3) |seed| jumps += (try session(packedHerd(), 100 + seed, 30)).jumps;
    for (0..6) |seed| {
        var prng = std.Random.DefaultPrng.init(1000 + seed);
        jumps += (try session(thrownCrowd(prng.random()), 2000 + seed, 60)).jumps;
    }
    // The jumps' paths ran, not just the walks.
    try testing.expect(jumps > 0);
}

test "a full drag through the packed herd costs at most 1,000,000 pair checks (sweeps, out-from-under, pushes, list builds; not the wishes' sums)" {
    var b = packedHerd();
    var lines: physics.Lines = .{};
    const full = physics.mergeAndCap(&.{.{ .dx = physics.cap, .dy = physics.cap }});
    _ = physics.tick(&b, 1, &.{}, full.slice(), &lines);
    try testing.expect(lines.pair_checks > 0);
    try testing.expect(lines.pair_checks <= 1_000_000);
}

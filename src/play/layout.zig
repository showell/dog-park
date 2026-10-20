//! **THE FIRST LAYOUT**, in 256ths: where every critter stands when the park
//! starts afresh (the server's first start, and every load). A chicken's
//! starting spot is its home (`home`), where a forager walks back to
//! (docs/PHYSICS.md, "Poop and chickens"). Today's pattern (a dog of each
//! breed in each corner of every park tile, a cow in each white tile, two
//! chickens in each blue one) is roc/world.roc's.
//!
//! **ROC PLACES THEM.** The places are the world's (world.zig, which
//! roc/world.roc says), and so are the kinds and their counts: as many of
//! each as its spots. Any layout will do that keeps to what the
//! physics needs of it: every critter in the world (checked here at
//! compile time) and no two overlapping (the test below). Its own pattern
//! is roc/world.roc's to say and check.

const std = @import("std");
const physics = @import("physics.zig");
const world = @import("world.zig").world;
const px = physics.px;

/// The level the board lays out: Level Two, the last, until a game names
/// its own.
const level = world.levels[world.levels.len - 1];

/// Each kind's spots as the physics' points, made once at compile time,
/// critter n of kind k at `homes[k][n]`.
const homes = h: {
    var out: [physics.kind_count][]const physics.Point = undefined;
    for (world.kinds, level.spots, &out) |k, spots, *ps| {
        var points: [spots.len]physics.Point = undefined;
        for (spots, &points, 0..) |s, *p, n| {
            // Every park point has one name, in [0, world) on each axis.
            if (s.x < 0 or s.y < 0 or s.x >= physics.world or s.y >= physics.world)
                @compileError(std.fmt.comptimePrint("world.zon: {s} {d} starts outside the world, at ({d}, {d})", .{ k.name, n, s.x, s.y }));
            p.* = .{ .x = s.x, .y = s.y };
        }
        const done = points;
        ps.* = &done;
    }
    const all = out;
    break :h all;
};

/// **A CRITTER'S HOME**: where it stands in the first layout, and where a
/// forager walks back to when it has no poop to forage (docs/PHYSICS.md,
/// "Poop and chickens").
pub fn home(c: physics.Critter) physics.Point {
    return homes[@intFromEnum(c.kind)][c.n];
}

/// The first layout, every critter present, no one leashed.
pub fn board() physics.Board {
    var b = physics.Board.empty();
    for (0..physics.kind_count) |k| for (homes[k], 0..) |p, n| b.place(.of(@enumFromInt(k), @intCast(n)), p);
    return b;
}

const testing = std.testing;

test "the first layout: no two critters overlap (a load puts it back without resolving; a first start resolves it, so the two agree only while this holds)" {
    const b = board();
    var all: [physics.critter_count]struct { p: physics.Point, half: i32 } = undefined;
    for (0..physics.kind_count) |k| for (0..physics.counts[k]) |n| {
        const c: physics.Critter = .of(@enumFromInt(k), @intCast(n));
        all[physics.critterIndex(c)] = .{ .p = b.at(c), .half = c.half() };
    };
    for (all, 0..) |a, i| for (all[i + 1 ..]) |c| {
        try testing.expect(!physics.squaresOverlap(a.p, a.half, c.p, c.half));
    };
}

test "the first layout: every critter present, at its home" {
    const b = board();
    for (0..physics.kind_count) |k| for (0..physics.counts[k]) |n| {
        const c: physics.Critter = .of(@enumFromInt(k), @intCast(n));
        try testing.expectEqual(physics.Known.present, b.known(c));
        try testing.expectEqual(b.at(c), home(c));
    };
}

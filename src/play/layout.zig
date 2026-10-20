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

/// Each level's spots as the physics' points, made once at compile time,
/// critter n of kind k at `homes[level][k][n]`; a kind's list as long as
/// that level lays out.
const homes = h: {
    var out: [physics.level_count][physics.kind_count][]const physics.Point = undefined;
    for (world.levels, &out, 0..) |level, *lv, li| {
        const g = physics.Geometry.of(li);
        for (world.kinds, level.spots, lv) |k, spots, *ps| {
            var points: [spots.len]physics.Point = undefined;
            for (spots, &points, 0..) |s, *p, n| {
                // Every park point has one name, in [0, its level's world)
                // on each axis.
                if (s.x < 0 or s.y < 0 or s.x >= g.world or s.y >= g.world)
                    @compileError(std.fmt.comptimePrint("world.zon: level {d}'s {s} {d} starts outside its world, at ({d}, {d})", .{ li + 1, k.name, n, s.x, s.y }));
                p.* = .{ .x = s.x, .y = s.y };
            }
            const done = points;
            ps.* = &done;
        }
    }
    const all = out;
    break :h all;
};

/// **A CRITTER'S HOME** on `level`: where it stands in that level's first
/// layout, and where a forager walks back to when it has no poop to forage
/// (docs/PHYSICS.md, "Poop and chickens"). Only a critter the level lays
/// out has one.
pub fn home(level: physics.Level, c: physics.Critter) physics.Point {
    return homes[level][@intFromEnum(c.kind)][c.n];
}

/// `level`'s first layout: the critters it lays out present, at their
/// homes, every other critter absent, no one leashed.
pub fn board(level: physics.Level) physics.Board {
    var b = physics.Board.emptyAt(level);
    for (0..physics.kind_count) |k| for (homes[level][k], 0..) |p, n| b.place(.of(@enumFromInt(k), @intCast(n)), p);
    return b;
}

const testing = std.testing;

/// No two of a board's present critters overlap, round its level's torus.
fn noOverlap(b: *const physics.Board) !void {
    const g = b.geometry();
    var all: [physics.critter_count]struct { p: physics.Point, half: i32 } = undefined;
    var len: usize = 0;
    for (0..physics.kind_count) |k| for (0..physics.counts[k]) |n| {
        const c: physics.Critter = .of(@enumFromInt(k), @intCast(n));
        if (b.known(c) != .present) continue;
        all[len] = .{ .p = b.at(c), .half = c.half() };
        len += 1;
    };
    for (all[0..len], 0..) |a, i| for (all[i + 1 .. len]) |c| {
        try testing.expect(!g.squaresOverlap(a.p, a.half, c.p, c.half));
    };
}

test "the first layout: no two critters overlap (a load puts it back without resolving; a first start resolves it, so the two agree only while this holds)" {
    const b = board(physics.last_level);
    try noOverlap(&b);
}

test "the first layout: every critter present, at its home" {
    const b = board(physics.last_level);
    for (0..physics.kind_count) |k| for (0..physics.counts[k]) |n| {
        const c: physics.Critter = .of(@enumFromInt(k), @intCast(n));
        try testing.expectEqual(physics.Known.present, b.known(c));
        try testing.expectEqual(b.at(c), home(b.level, c));
    };
}

test "Level One's first layout: 16 dogs and 2 cows present at their homes (and whatever else world.zon lays out there), every other critter absent, all inside its 4 x 4-tile world, no two overlapping" {
    const b = physics.Board.laidOutAt(0);
    const g = b.geometry();
    try testing.expectEqual(@as(physics.Level, 0), b.level);
    try testing.expectEqual(@as(i32, 4), g.world_tiles);
    try testing.expectEqual(physics.px(4 * 350), g.world);
    var present: [physics.kind_count]usize = undefined;
    for (world.levels[0].spots, &present) |spots, *n| n.* = spots.len;
    try testing.expectEqual(@as(usize, 16), present[@intFromEnum(physics.Kind.dog)]);
    try testing.expectEqual(@as(usize, 2), present[@intFromEnum(physics.Kind.cow)]);
    for (0..physics.kind_count) |k| for (0..physics.counts[k]) |n| {
        const c: physics.Critter = .of(@enumFromInt(k), @intCast(n));
        if (n < present[k]) {
            try testing.expectEqual(physics.Known.present, b.known(c));
            try testing.expectEqual(home(0, c), b.at(c));
            try testing.expect(g.holdsPoint(b.at(c)));
        } else {
            try testing.expectEqual(physics.Known.absent, b.known(c));
        }
    };
    try noOverlap(&b);
}

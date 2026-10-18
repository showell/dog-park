//! **THE FIRST LAYOUT**, in 256ths: where every critter stands when the park
//! starts afresh (the server's first start, and every load). A chicken's
//! starting spot is its home (`chickenHome`), where it walks back to
//! (docs/PHYSICS.md, "Poop and chickens"). Today's pattern (a dog of each
//! breed in each corner of every park tile, a cow in each white tile, two
//! chickens in each blue one) is roc/world.roc's.
//!
//! **ROC PLACES THEM.** The places are the world's (world.zig, which
//! roc/world.roc says), and so are the counts: as many dogs, cows and
//! chickens as its lists hold. Any layout will do that keeps to what the
//! physics needs of it: every critter in the world (checked here at
//! compile time) and no two overlapping (the test below). Its own pattern
//! is roc/world.roc's to say and check.

const std = @import("std");
const physics = @import("physics.zig");
const world = @import("world.zig").world;
const px = physics.px;

pub const dog_count: comptime_int = world.dogs.len;
pub const cow_count: comptime_int = world.cows.len;
pub const chicken_count: comptime_int = world.chickens.len;

/// The world's spots as the physics' points, made once at compile time.
fn points(comptime spots: []const @import("world.zig").Spot) [spots.len]physics.Point {
    var out: [spots.len]physics.Point = undefined;
    for (spots, &out) |s, *p| p.* = .{ .x = s.x, .y = s.y };
    return out;
}
comptime {
    // Every park point has one name, in [0, world) on each axis (physics.zig).
    for ([_][]const @import("world.zig").Spot{ world.dogs, world.cows, world.chickens }, [_][]const u8{ "dog", "cow", "chicken" }) |spots, kind| {
        for (spots, 0..) |s, n| if (s.x < 0 or s.y < 0 or s.x >= physics.world or s.y >= physics.world)
            @compileError(std.fmt.comptimePrint("world.zon: {s} {d} starts outside the world, at ({d}, {d})", .{ kind, n, s.x, s.y }));
    }
}
const dogs = points(world.dogs);
const cows = points(world.cows);
const chickens = points(world.chickens);

/// **A CHICKEN'S HOME**: where chicken `n` stands in the first layout, and
/// where it walks back to when it has no poop to forage (docs/PHYSICS.md,
/// "Poop and chickens").
pub fn chickenHome(n: u16) physics.Point {
    return chickens[n];
}

/// The first layout, every critter present, no one leashed.
pub fn board() physics.Board {
    var b = physics.Board.empty();
    for (dogs, 0..) |p, n| b.place(.dog(@intCast(n)), p);
    for (cows, 0..) |p, n| b.place(.cow(@intCast(n)), p);
    for (chickens, 0..) |p, n| b.place(.chicken(@intCast(n)), p);
    return b;
}

const testing = std.testing;

test "the first layout: no two critters overlap (a load puts it back without resolving; a first start resolves it, so the two agree only while this holds)" {
    const b = board();
    var all: [physics.critter_count]struct { p: physics.Point, half: i32 } = undefined;
    for (b.dogs, 0..) |p, i| all[i] = .{ .p = p, .half = physics.dog_half };
    for (b.cows, 0..) |p, i| all[physics.dog_count + i] = .{ .p = p, .half = physics.cow_half };
    for (b.chickens, 0..) |p, i| all[physics.dog_count + physics.cow_count + i] = .{ .p = p, .half = physics.chicken_half };
    for (all, 0..) |a, i| for (all[i + 1 ..]) |c| {
        try testing.expect(!physics.squaresOverlap(a.p, a.half, c.p, c.half));
    };
}

test "the first layout: every critter present, and a chicken's home is where it starts" {
    const b = board();
    for (b.dog_known) |k| try testing.expectEqual(physics.Known.present, k);
    for (b.cow_known) |k| try testing.expectEqual(physics.Known.present, k);
    for (b.chicken_known, b.chickens, 0..) |k, p, n| {
        try testing.expectEqual(physics.Known.present, k);
        try testing.expectEqual(p, chickenHome(@intCast(n)));
    }
}

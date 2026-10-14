//! **THE HERDS, AS NUMBERS** (metal-vmm QUEUE 205(a); the essay's "What a
//! herd is, as a number"): a census of a board, so a rule change is judged
//! on the same play every time (herd_bench.zig) and not only by eye.
//!
//! - **The herd graph:** two dogs of one breed are linked when they are
//!   within `link` of each other (the herd band's outer edge plus `slack`),
//!   by a `Yardstick`: `.rules`, the physics' own distance (the larger
//!   axis), so a herd is held to the band it is held by; or `.eye`, the
//!   straight line, as the screen shows it.
//! - **A herd** is a connected group of that graph of at least `least`
//!   dogs. A dog alone, or two, is no herd.
//! - **Its size** is its dogs; **its length** the most hops between two of
//!   them along the graph (its diameter); **its links** the graph's edges
//!   inside it. A chain has length size − 1 and about 2 links a dog
//!   (`perDog`); a clump is short and has 4 or more.
//! - **Stability** (`kept`): how much of a census's herds a later one
//!   still holds, member by member.
//!
//! Not the physics: nothing here decides a tick, so it is not among the
//! physics hash's sources. A census is O(dogs²): a tool's, not a tick's.

const std = @import("std");
const physics = @import("physics.zig");
const Board = physics.Board;

/// How far past the band's outer edge a link reaches: a dog a pixel-tick
/// or the dead zone outside its band is still in its herd.
pub const slack: i32 = physics.px(20);
/// Two dogs of a breed this close, or closer, are linked.
pub const link: i32 = physics.band_outer + slack;
/// The fewest dogs that make a herd.
pub const least = 3;

const dog_count = physics.dog_count;
const most_herds = dog_count / least;
const none: u16 = std.math.maxInt(u16);
const Set = std.StaticBitSet(dog_count);

pub const Herd = struct {
    breed: u8,
    size: u16,
    length: u16,
    links: u32,
    /// Its lowest-numbered dog: a name that does not depend on order.
    first: u16,

    /// Links a dog: 2 × links / size, about 2 for a chain.
    pub fn perDog(h: Herd) f64 {
        return 2 * @as(f64, @floatFromInt(h.links)) / @as(f64, @floatFromInt(h.size));
    }
};

pub const Census = struct {
    herds: [most_herds]Herd = undefined,
    len: usize = 0,
    /// Each dog's herd, an index into `herds`, or `none`.
    of: [dog_count]u16 = @splat(none),

    pub fn slice(c: *const Census) []const Herd {
        return c.herds[0..c.len];
    }

    /// The herd dog `n` is in, if any.
    pub fn herdOf(c: *const Census, n: u16) ?Herd {
        const k = c.of[n];
        return if (k == none) null else c.herds[k];
    }

    /// Herds of breed `breed`.
    pub fn count(c: *const Census, breed: u8) usize {
        var n: usize = 0;
        for (c.slice()) |h| n += @intFromBool(h.breed == breed);
        return n;
    }

    /// The dogs in any herd.
    pub fn herded(c: *const Census) usize {
        var n: usize = 0;
        for (c.slice()) |h| n += h.size;
        return n;
    }

    /// The largest herd of breed `breed`, if any (the lower `first` on a tie).
    pub fn largest(c: *const Census, breed: u8) ?Herd {
        var best: ?Herd = null;
        for (c.slice()) |h| {
            if (h.breed != breed) continue;
            if (best == null or h.size > best.?.size) best = h;
        }
        return best;
    }
};

/// What a link is measured by: the physics' distance, or the straight line.
pub const Yardstick = enum { rules, eye };

fn linked(yard: Yardstick, a: physics.Point, b: physics.Point) bool {
    const v = physics.delta(a, b);
    return switch (yard) {
        .rules => physics.measure(v) <= physics.measureOf(link),
        .eye => physics.len2(v) <= @as(i64, link) * link,
    };
}

/// The census of a board by `yard`: every present dog, wherever it is.
pub fn census(b: *const Board, yard: Yardstick) Census {
    var adj: [dog_count]Set = undefined;
    for (&adj) |*s| s.* = .initEmpty();
    for (0..dog_count) |i| {
        if (b.dog_known[i] != .present) continue;
        var j = i + physics.breeds;
        while (j < dog_count) : (j += physics.breeds) {
            if (b.dog_known[j] != .present) continue;
            if (!linked(yard, b.dogs[i], b.dogs[j])) continue;
            adj[i].set(j);
            adj[j].set(i);
        }
    }
    var c: Census = .{};
    var seen: Set = .initEmpty();
    var members: [dog_count]u16 = undefined;
    for (0..dog_count) |i| {
        if (seen.isSet(i) or b.dog_known[i] != .present) continue;
        // The component, breadth first: `members` is its queue.
        var n: usize = 0;
        var links: u32 = 0;
        members[0] = @intCast(i);
        seen.set(i);
        n = 1;
        var head: usize = 0;
        while (head < n) : (head += 1) {
            const m = members[head];
            links += @intCast(adj[m].count());
            var it = adj[m].iterator(.{});
            while (it.next()) |o| if (!seen.isSet(o)) {
                seen.set(o);
                members[n] = @intCast(o);
                n += 1;
            };
        }
        if (n < least) continue;
        const k: u16 = @intCast(c.len);
        for (members[0..n]) |m| c.of[m] = k;
        c.herds[c.len] = .{
            .breed = @intCast(i % physics.breeds),
            .size = @intCast(n),
            .length = diameter(&adj, members[0..n]),
            .links = links / 2,
            .first = @intCast(i),
        };
        c.len += 1;
    }
    return c;
}

/// The most hops between two of `members` (one component of `adj`): a
/// breadth-first search from each.
fn diameter(adj: *const [dog_count]Set, members: []const u16) u16 {
    var most: u16 = 0;
    var hops: [dog_count]u16 = undefined;
    var queue: [dog_count]u16 = undefined;
    for (members) |from| {
        for (members) |m| hops[m] = none;
        hops[from] = 0;
        queue[0] = from;
        var n: usize = 1;
        var head: usize = 0;
        while (head < n) : (head += 1) {
            const m = queue[head];
            most = @max(most, hops[m]);
            var it = adj[m].iterator(.{});
            while (it.next()) |o| if (hops[o] == none) {
                hops[o] = hops[m] + 1;
                queue[n] = @intCast(o);
                n += 1;
            };
        }
    }
    return most;
}

/// **STABILITY**: of the dogs in `before`'s herds, the share `after` keeps
/// together: each herd matched to the later herd that holds most of its
/// dogs, counted by the members both hold over the members either does
/// (1 when the herd is the same dogs, 0 when it is gone), weighted by its
/// size. 1 when `before` has no herds.
pub fn kept(before: *const Census, after: *const Census) f64 {
    var weight: f64 = 0;
    var sum: f64 = 0;
    for (before.slice(), 0..) |h, k| {
        // The later herds its dogs are in, and how many of them each.
        var hits: [most_herds]u16 = @splat(0);
        for (0..dog_count) |m| {
            if (before.of[m] != k) continue;
            const a = after.of[m];
            if (a != none) hits[a] += 1;
        }
        var best: usize = 0;
        var best_hits: u16 = 0;
        for (hits[0..after.len], 0..) |n, a| if (n > best_hits) {
            best = a;
            best_hits = n;
        };
        const share: f64 = if (best_hits == 0) 0 else blk: {
            const both: f64 = @floatFromInt(best_hits);
            const either: f64 = @floatFromInt(@as(u32, h.size) + after.herds[best].size - best_hits);
            break :blk both / either;
        };
        const w: f64 = @floatFromInt(h.size);
        weight += w;
        sum += w * share;
    }
    return if (weight == 0) 1 else sum / weight;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn at(x: i32, y: i32) physics.Point {
    return .{ .x = physics.px(x), .y = physics.px(y) };
}

/// Every dog far apart, out of each other's links: `n` of breed 0 in a
/// line `gap` px apart along x from (16000, 16000), placed on top.
fn chain(b: *Board, n: u16, gap: i32, y: i32) void {
    for (0..n) |k| b.place(.dog(@intCast(k * physics.breeds)), at(16000 + gap * @as(i32, @intCast(k)), y));
}

test "the laid-out park has no herds: a tile's dogs are of four breeds, and one breed's are a tile apart" {
    const b = Board.laidOut();
    const c = census(&b, .rules);
    try testing.expectEqual(@as(usize, 0), c.len);
}

test "a line of one breed's dogs a band apart is one herd, a chain: length size − 1, two links a dog but at its ends" {
    var b = Board.empty();
    const gap = @divTrunc(physics.band_inner + physics.band_outer, 2 * 256);
    chain(&b, 10, gap, 16000);
    const c = census(&b, .rules);
    try testing.expectEqual(@as(usize, 1), c.len);
    const h = c.slice()[0];
    try testing.expectEqual(Herd{ .breed = 0, .size = 10, .length = 9, .links = 9, .first = 0 }, h);
    try testing.expect(h.perDog() < 2);
    try testing.expectEqual(@as(usize, 1), c.count(0));
    try testing.expectEqual(@as(usize, 10), c.herded());
}

test "a line broken past the link is two herds; two dogs alone are none" {
    var b = Board.empty();
    const gap = @divTrunc(physics.band_outer, 256);
    chain(&b, 4, gap, 16000);
    // Four more, past the link from the last.
    const far = 16000 + gap * 3 + @divTrunc(link, 256) + 1;
    for (0..4) |k| b.place(.dog(@intCast((4 + k) * physics.breeds)), at(far + gap * @as(i32, @intCast(k)), 16000));
    // Two alone, elsewhere.
    b.place(.dog(40 * physics.breeds), at(20000, 20000));
    b.place(.dog(41 * physics.breeds), at(20000 + gap, 20000));
    const c = census(&b, .rules);
    try testing.expectEqual(@as(usize, 2), c.len);
    for (c.slice()) |h| try testing.expectEqual(@as(u16, 3), h.length);
    try testing.expectEqual(@as(?Herd, null), c.herdOf(40 * physics.breeds));
}

test "a clump is short and dense: a 4 × 4 block a band apart has length 6 or less and three or more links a dog" {
    var b = Board.empty();
    const gap = @divTrunc(physics.band_outer, 256);
    for (0..16) |k| {
        const x: i32 = @intCast(k % 4);
        const y: i32 = @intCast(k / 4);
        b.place(.dog(@intCast(k * physics.breeds)), at(16000 + gap * x, 16000 + gap * y));
    }
    const c = census(&b, .rules);
    try testing.expectEqual(@as(usize, 1), c.len);
    const h = c.slice()[0];
    try testing.expectEqual(@as(u16, 16), h.size);
    try testing.expect(h.length <= 6);
    try testing.expect(h.perDog() >= 3);
}

test "breeds never join: two breeds' lines side by side are two herds, each its own breed" {
    var b = Board.empty();
    const gap = @divTrunc(physics.band_outer, 256);
    for (0..5) |k| {
        const x = 16000 + gap * @as(i32, @intCast(k));
        b.place(.dog(@intCast(k * physics.breeds)), at(x, 16000));
        b.place(.dog(@intCast(k * physics.breeds + 1)), at(x, 16000 + 10));
    }
    const c = census(&b, .rules);
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqual(@as(usize, 1), c.count(0));
    try testing.expectEqual(@as(usize, 1), c.count(1));
}

test "stability: a census keeps all of itself; a herd split in half keeps a half; one scattered keeps none" {
    var b = Board.empty();
    const gap = @divTrunc(physics.band_outer, 256);
    chain(&b, 8, gap, 16000);
    const whole = census(&b, .rules);
    try testing.expectEqual(@as(f64, 1), kept(&whole, &whole));
    // The last four moved past the link: the first four are the herd now.
    const far = @divTrunc(link, 256) + 1;
    for (4..8) |k| b.place(.dog(@intCast(k * physics.breeds)), at(16000 + gap * @as(i32, @intCast(k)) + far, 16000));
    const split = census(&b, .rules);
    try testing.expectEqual(@as(usize, 2), split.len);
    try testing.expectEqual(@as(f64, 0.5), kept(&whole, &split));
    for (0..8) |k| b.place(.dog(@intCast(k * physics.breeds)), at(16000 + 1000 * @as(i32, @intCast(k)), 16000));
    const scattered = census(&b, .rules);
    try testing.expectEqual(@as(f64, 0), kept(&whole, &scattered));
    try testing.expectEqual(@as(f64, 1), kept(&scattered, &whole));
}

test "a link is the band's edge plus the slack, in the physics' distance: a dog just inside is linked, just outside not" {
    // On the diagonal, where the two rulers differ most, and along an axis.
    const p = at(16000, 16000);
    try testing.expect(linked(.rules, p, lineAt(p, link)));
    try testing.expect(!linked(.rules, p, lineAt(p, link + 256)));
    for ([_]Yardstick{ .rules, .eye }) |yard| {
        try testing.expect(linked(yard, p, .{ .x = p.x + link, .y = p.y }));
        try testing.expect(!linked(yard, p, .{ .x = p.x + link + 1, .y = p.y }));
    }
    // The eye's diagonal is the straight line's.
    const d = @divTrunc(link * 7, 10);
    try testing.expect(linked(.eye, p, .{ .x = p.x + d, .y = p.y + d }));
    try testing.expect(!linked(.eye, p, .{ .x = p.x + link * 3 / 4, .y = p.y + link * 3 / 4 }));
}

/// The point on the diagonal from `p` whose physics length is at most `len`
/// and as near it as a 256th allows.
fn lineAt(p: physics.Point, len: i32) physics.Point {
    var k: i32 = 0;
    while (physics.measure(.{ .x = k + 1, .y = k + 1 }) <= physics.measureOf(len)) k += 1;
    return .{ .x = p.x + k, .y = p.y + k };
}

//! **THE NEAREST SPOT CLEAR OF EVERYONE, DETERMINISTICALLY**
//! (docs/PHYSICS.md): where a pushed critter, or one getting out from under
//! an overlap, jumps to. The closest position, by straight-line distance,
//! that overlaps no obstacle and lies wholly in the region, chosen from a
//! finite list of candidates made by the obstacles within reach (a gap of
//! at most 100 px on both axes):
//! - **the ways out:** pressed against each side of each such square,
//!   moving one coordinate and keeping the other;
//! - **the corners:** the x of one way out and the y of another, from one
//!   square or two.
//!
//! Ties go by the rank of the square that made the candidate (a corner:
//! the higher-ranked of its two, then the other's), then the direction (E,
//! S, W, N, NE, SE, SW, NW), then, for two corners of the same two squares,
//! the one whose x comes from the higher-ranked square.
//!
//! **ONE FRAME** (decision 14): the point, the obstacles and the region
//! are given as the caller's copies nearest one anchor (physics'
//! `nearestCopy`), so every gap, way out and candidate here is relative to
//! it; the spot comes back in that frame, and the caller's move wraps it
//! into the world. The torus has no edge to keep a candidate inside.

const std = @import("std");
const physics = @import("physics.zig");
const Point = physics.Point;
const Rect = physics.Rect;

/// An obstacle: a rectangle and its tie rank (twice a critter's rank; a
/// cow's swept area is its cow's, plus one).
pub const Obstacle = struct { rect: Rect, rank: u32 };

pub const Obstacles = struct {
    list: [physics.critter_count + 2]Obstacle = undefined,
    len: usize = 0,

    pub fn add(self: *Obstacles, r: Rect, tie_rank: u32) void {
        self.list[self.len] = .{ .rect = r, .rank = tie_rank };
        self.len += 1;
    }
    pub fn slice(self: *const Obstacles) []const Obstacle {
        return self.list[0..self.len];
    }
};

/// The directions, in tie order.
pub const Dir = enum(u8) { e, s, w, n, ne, se, sw, nw };

const Key = struct {
    d2: i64,
    primary: u32,
    secondary: u32,
    dir: Dir,
    x_rank: u32,

    fn less(a: Key, b: Key) bool {
        if (a.d2 != b.d2) return a.d2 < b.d2;
        if (a.primary != b.primary) return a.primary < b.primary;
        if (a.secondary != b.secondary) return a.secondary < b.secondary;
        if (a.dir != b.dir) return @intFromEnum(a.dir) < @intFromEnum(b.dir);
        return a.x_rank < b.x_rank;
    }
};

/// The gap between two rectangles on an axis: 0 when they meet.
fn gapOn(a: Rect, b: Rect, axis: physics.Axis) i32 {
    const lo = @max(physics.on(b.lo, axis) - physics.on(a.hi, axis), physics.on(a.lo, axis) - physics.on(b.hi, axis));
    return @max(0, lo);
}

/// A way out against obstacle `o`, from its side `dir` (E, S, W or N): the
/// coordinate it sets.
fn wayOut(o: Rect, half: i32, dir: Dir) i32 {
    return switch (dir) {
        .e => o.hi.x + half,
        .w => o.lo.x - half,
        .s => o.hi.y + half,
        .n => o.lo.y - half,
        else => unreachable,
    };
}

/// The corners' directions: x side, then y side.
fn cornerDir(x_side: Dir, y_side: Dir) Dir {
    return switch (x_side) {
        .e => if (y_side == .n) .ne else .se,
        .w => if (y_side == .s) .sw else .nw,
        else => unreachable,
    };
}

/// **THE NEAREST SPOT** for the square of half `half` at `p`, clear of
/// every obstacle, wholly in `region` (all four in one frame); null for
/// nowhere to go.
pub fn nearestSpot(p: Point, half: i32, obstacles: []const Obstacle, region: Rect) ?Point {
    const me = Rect.square(p, half);
    var reach: [physics.critter_count + 2]usize = undefined;
    var n: usize = 0;
    for (obstacles, 0..) |o, i| {
        if (gapOn(me, o.rect, .x) <= physics.jump_reach and gapOn(me, o.rect, .y) <= physics.jump_reach) {
            reach[n] = i;
            n += 1;
        }
    }
    if (n == 0) return null;
    // Only obstacles near some candidate can make one invalid: those
    // meeting the box every candidate's square lies in.
    var box = me;
    for (reach[0..n]) |i| {
        const r = obstacles[i].rect;
        box.lo.x = @min(box.lo.x, r.lo.x - 2 * half);
        box.lo.y = @min(box.lo.y, r.lo.y - 2 * half);
        box.hi.x = @max(box.hi.x, r.hi.x + 2 * half);
        box.hi.y = @max(box.hi.y, r.hi.y + 2 * half);
    }
    var near: [physics.critter_count + 2]usize = undefined;
    var m: usize = 0;
    for (obstacles, 0..) |o, i| {
        if (Rect.overlaps(o.rect, box)) {
            near[m] = i;
            m += 1;
        }
    }
    const ctx: Ctx = .{ .p = p, .half = half, .obstacles = obstacles, .near = near[0..m], .region = region };
    var best: Best = .{};
    for (reach[0..n]) |i| {
        const o = obstacles[i];
        for ([_]Dir{ .e, .s, .w, .n }) |dir| {
            const c: Point = switch (dir) {
                .e, .w => .{ .x = wayOut(o.rect, half, dir), .y = p.y },
                else => .{ .x = p.x, .y = wayOut(o.rect, half, dir) },
            };
            ctx.offer(&best, c, .{ .d2 = 0, .primary = o.rank, .secondary = o.rank, .dir = dir, .x_rank = o.rank });
        }
    }
    for (reach[0..n]) |a| {
        const oa = obstacles[a];
        for ([_]Dir{ .e, .w }) |x_side| {
            const x = wayOut(oa.rect, half, x_side);
            for (reach[0..n]) |b| {
                const ob = obstacles[b];
                for ([_]Dir{ .s, .n }) |y_side| {
                    ctx.offer(&best, .{ .x = x, .y = wayOut(ob.rect, half, y_side) }, .{
                        .d2 = 0,
                        .primary = @min(oa.rank, ob.rank),
                        .secondary = @max(oa.rank, ob.rank),
                        .dir = cornerDir(x_side, y_side),
                        .x_rank = oa.rank,
                    });
                }
            }
        }
    }
    return best.at;
}

const Best = struct { at: ?Point = null, key: Key = undefined };

const Ctx = struct {
    p: Point,
    half: i32,
    obstacles: []const Obstacle,
    near: []const usize,
    region: Rect,

    fn offer(ctx: Ctx, best: *Best, c: Point, key_without_d2: Key) void {
        var key = key_without_d2;
        key.d2 = physics.len2(physics.delta(ctx.p, c));
        if (best.at != null and !key.less(best.key)) return;
        const sq = Rect.square(c, ctx.half);
        if (!ctx.region.holds(sq)) return;
        for (ctx.near) |i| if (Rect.overlaps(ctx.obstacles[i].rect, sq)) return;
        best.* = .{ .at = c, .key = key };
    }
};

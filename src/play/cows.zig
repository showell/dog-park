//! The cows: one in the middle of every white tile, and scared of moving
//! dogs. **THE SERVER MOVES THEM**, as a reaction to a dog's move; the page
//! predicts them with this same file (cows_wasm.zig). Each critter is its
//! sprite's square (a dog `dog_px` a side, a cow `cow_px`), centred on its
//! park point.
//!
//! **A COW ONLY EVER MOVES ACROSS THE DOG'S HEADING**: it clears the path,
//! never runs ahead. It moves when the dog is heading for it, centre to
//! centre within `scare_reach_px` and `scare_cone_degrees`, or when it
//! stands in the dog's PATH: where the dog's square, carried on along its
//! heading, would come within `clearance_px` of the cow's. It moves to the
//! side of the path it is on (the dog's right when dead centre; the other
//! side when the world's edge leaves no room to clear), at half the dog's
//! speed, or faster only when it must: when at half speed the dog would
//! reach it before it is out of the path, it moves as fast as clears the
//! path by the time the dog gets there, and at once if the dog is on it.
//!
//! **THE HEADING IS THE DOG'S, NOT ITS LAST PIXEL'S.** A move is the path
//! the page saw, a whole pixel at a time; a slow drag is steps of 1 to 3 px,
//! which point only a few ways (east, north-east, ...), and a cow near the
//! line would change sides at every step. So the heading at each point is
//! the chord from the latest point at least `heading_px` back along the
//! path (`headingAt`).
//!
//! **A COW STANDS TO A FRACTION OF A PIXEL** (f64): half a 1 px move is half
//! a pixel, kept, so half speed is half at every speed of drag. f64
//! arithmetic is the same on every host (Zig doesn't fuse multiply-adds
//! unasked), so the page's wasm and the server agree to the bit.
//!
//! A step that would take a cow's square out of the world is shortened
//! along its own direction, never clamped (a clamp would leave it moving
//! along the heading).

const std = @import("std");
const dogs = @import("dogs.zig");
const tiles = @import("tiles.zig");
const ParkPoint = dogs.ParkPoint;

/// A cow is known by its place in the list, made once.
pub const CowId = enum(u16) { _ };

/// Where a cow stands, in park pixels, to a fraction. `extern`: the page's
/// wasm hands these to the page as pairs of f64.
pub const CowPoint = extern struct { park_x: f64, park_y: f64 };

/// The squares, as the page draws them (park.js's dog_px and cow_px).
pub const dog_px = 40;
pub const cow_px = 60;

/// How far ahead a dog scares a cow, centre to centre, in park pixels: in
/// a straight line for the cone, along the heading for the path.
pub const scare_reach_px = 400;

/// How far off the dog's heading a cow may be and still be scared: 50
/// degrees, as `along^2 >= cos^2(50) * |toward|^2`, `along` positive
/// (ahead, not behind).
pub const scare_cone_degrees = 50;
const cone_cos_sq = 0.41317591116653485; // cos(50 degrees)^2

/// The least gap a cow keeps between the dog's square and its own: half a
/// dog.
pub const clearance_px = dog_px / 2;

/// How far back along its path the dog's heading is taken from.
pub const heading_px = 24;

/// The most points of the path before a move that a move carries, for its
/// headings (`back`): enough to reach `heading_px` back on any drag but a
/// trembling one.
pub const most_back_points = 32;

/// The longest tick a segment of a path is played in, on each axis.
pub const tick_px = 10;

/// Centre to centre, the squares just touch at `touching_px` on an axis.
const touching_px = (dog_px + cow_px) / 2;

/// How far past the path's edge a cow clears it.
const clear_spare_px = 1;

/// A cow's centre keeps its whole square in the world.
const lowest: f64 = cow_px / 2;
const highest: f64 = tiles.world_px - cow_px / 2;

/// Where a cow stands in its tile: the middle, clear of the white tile's two
/// dogs.
const in_white = tiles.tile_px / 2;

pub const cow_count = tiles.world_tiles * tiles.world_tiles - tiles.world_tiles * tiles.world_tiles / 2;

fn inWorld(at: CowPoint) bool {
    return at.park_x >= lowest and at.park_x <= highest and at.park_y >= lowest and at.park_y <= highest;
}

/// What a dog's move does to one cow.
pub const Reaction = union(enum) {
    /// Not scared: too far, off to the side, behind the dog, the dog didn't
    /// move, or the cow can't step.
    stays,
    /// Scared: where it stepped to.
    steps_to: CowPoint,
};

pub const Heading = struct { hx: i64, hy: i64 };

/// **THE DOG'S HEADING AT `points[k]`**: from the latest earlier point at
/// least `heading_px` away to it, or from the earliest when none is that
/// far. (0, 0) when the dog is where it began.
pub fn headingAt(points: []const ParkPoint, k: usize) Heading {
    const b = points[k];
    var j = k;
    while (j > 0) {
        j -= 1;
        const hx = @as(i64, b.park_x) - points[j].park_x;
        const hy = @as(i64, b.park_y) - points[j].park_y;
        if (hx * hx + hy * hy >= heading_px * heading_px) return .{ .hx = hx, .hy = hy };
    }
    return .{ .hx = @as(i64, b.park_x) - points[0].park_x, .hy = @as(i64, b.park_y) - points[0].park_y };
}

/// **A MOVE, REPLAYED.** `points` is the dog's trail: what came before the
/// move, ending where the server has the dog, then the move's path from
/// `points[first]`. Every cow in `cows` reacts to each segment of the path
/// in turn, with the heading at its end; `moved[i]` is set for each that
/// stepped. The server's /move and the page's prediction both call this.
pub fn replay(cows: []CowPoint, points: []const ParkPoint, first: usize, moved: ?[]bool) void {
    std.debug.assert(first >= 1);
    var k = first;
    while (k < points.len) : (k += 1) {
        const h = headingAt(points, k);
        for (cows, 0..) |*c, i| switch (reaction(h, points[k - 1], points[k], c.*)) {
            .stays => {},
            .steps_to => |p| {
                c.* = p;
                if (moved) |m| m[i] = true;
            },
        };
    }
}

/// **ONE SEGMENT.** The dog, heading `h`, moved from `from` to `to`; the cow
/// at `cow`, after each tick of it.
pub fn reaction(h: Heading, from: ParkPoint, to: ParkPoint, cow: CowPoint) Reaction {
    if (h.hx == 0 and h.hy == 0) return .stays;
    const sx = @as(i64, to.park_x) - from.park_x;
    const sy = @as(i64, to.park_y) - from.park_y;
    if (sx == 0 and sy == 0) return .stays;
    const ticks = @max(1, std.math.divCeil(i64, @max(mag(sx), mag(sy)), tick_px) catch unreachable);
    const n: f64 = @floatFromInt(ticks);
    const tick = std.math.hypot(@as(f64, @floatFromInt(sx)), @as(f64, @floatFromInt(sy))) / n;
    var at = cow;
    var k: i64 = 1;
    while (k <= ticks) : (k += 1) {
        const part = @as(f64, @floatFromInt(k)) / n;
        const dog: Vec = .{
            .x = @as(f64, @floatFromInt(from.park_x)) + @as(f64, @floatFromInt(sx)) * part,
            .y = @as(f64, @floatFromInt(from.park_y)) + @as(f64, @floatFromInt(sy)) * part,
        };
        at = scooted(h, tick, dog, at);
    }
    if (at.park_x == cow.park_x and at.park_y == cow.park_y) return .stays;
    return .{ .steps_to = at };
}

const Vec = struct { x: f64, y: f64 };

/// The cow's place across and along the dog's heading, from the dog's
/// centre: `across` toward the dog's right (with north up and park_y
/// growing south, heading east its right is south), `along` ahead.
const Frame = struct {
    ux: f64,
    uy: f64,
    rx: f64,
    ry: f64,
    dx: f64,
    dy: f64,
    across: f64,
    along: f64,

    fn of(h: Heading, dog: Vec, cow: CowPoint) Frame {
        const hx: f64 = @floatFromInt(h.hx);
        const hy: f64 = @floatFromInt(h.hy);
        const len = std.math.hypot(hx, hy);
        const ux = hx / len;
        const uy = hy / len;
        const dx = cow.park_x - dog.x;
        const dy = cow.park_y - dog.y;
        return .{ .ux = ux, .uy = uy, .rx = -uy, .ry = ux, .dx = dx, .dy = dy, .across = -uy * dx + ux * dy, .along = ux * dx + uy * dy };
    }

    /// Half the path's width: how far across the heading the cow's centre
    /// must be for the squares, the dog's carried on along the heading,
    /// never to come within `clearance_px` (both squares and the clearance,
    /// as wide as they are across this heading).
    fn halfPath(self: Frame) f64 {
        return @as(f64, touching_px) * (@abs(self.rx) + @abs(self.ry)) + clearance_px;
    }

    /// Whether the dog is heading for the cow: centre to centre within
    /// `scare_reach_px`, within `scare_cone_degrees`, and ahead.
    fn inCone(self: Frame) bool {
        const toward_sq = self.dx * self.dx + self.dy * self.dy;
        if (toward_sq > scare_reach_px * scare_reach_px) return false;
        if (self.along <= 0) return false;
        return self.along * self.along >= cone_cos_sq * toward_sq;
    }

    /// **HOW FAR THE DOG HAS TO COME BEFORE IT IS ON THE COW**: the least
    /// distance along its heading, from where it is, at which the squares
    /// would be within `clearance_px` (0 when they are now), or null when
    /// they never would be. Centre to centre, the squares are within the
    /// clearance exactly inside a rounded square: `touching_px` a half
    /// side, its corners rounded by `clearance_px`. So: where the ray from
    /// the cow, back along the heading, first meets that shape.
    fn toCome(self: Frame) ?f64 {
        const t: f64 = touching_px;
        const c: f64 = clearance_px;
        var first: ?f64 = null;
        // The two slabs: wide in x, and wide in y.
        for ([_][2]f64{ .{ t + c, t }, .{ t, t + c } }) |half| {
            if (slabEntry(self.dx, self.dy, -self.ux, -self.uy, half[0], half[1])) |l| first = earlier(first, l);
        }
        // The four corner discs.
        for ([_][2]f64{ .{ t, t }, .{ t, -t }, .{ -t, t }, .{ -t, -t } }) |corner| {
            const px = self.dx - corner[0];
            const py = self.dy - corner[1];
            // |p - l u|^2 = c^2: l^2 - 2 l (u . p) + |p|^2 - c^2 = 0.
            const b = self.ux * px + self.uy * py;
            const disc = b * b - (px * px + py * py - c * c);
            if (disc <= 0) continue;
            const root = @sqrt(disc);
            if (b + root <= 0) continue; // behind the dog
            first = earlier(first, @max(0, b - root));
        }
        return first;
    }

    /// How far the cow at `cow` can go across the heading, to `side`,
    /// before its square leaves the world.
    fn room(self: Frame, cow: CowPoint, side: f64) f64 {
        var most = std.math.inf(f64);
        for ([_][2]f64{ .{ cow.park_x, side * self.rx }, .{ cow.park_y, side * self.ry } }) |axis| {
            const p, const v = axis;
            if (v > 0) most = @min(most, (highest - p) / v);
            if (v < 0) most = @min(most, (lowest - p) / v);
        }
        return @max(0, most);
    }
};

fn earlier(a: ?f64, b: f64) f64 {
    return if (a) |x| @min(x, b) else b;
}

/// Where the ray from (px, py) in direction (vx, vy) first enters the box of
/// half sides (hx, hy) about the origin (0 when it starts inside), or null
/// when it never does.
fn slabEntry(px: f64, py: f64, vx: f64, vy: f64, hx: f64, hy: f64) ?f64 {
    var lo: f64 = 0;
    var hi: f64 = std.math.inf(f64);
    for ([_][3]f64{ .{ px, vx, hx }, .{ py, vy, hy } }) |axis| {
        const p, const v, const h = axis;
        if (v == 0) {
            if (@abs(p) >= h) return null;
            continue;
        }
        const a = (-h - p) / v;
        const b = (h - p) / v;
        lo = @max(lo, @min(a, b));
        hi = @min(hi, @max(a, b));
    }
    return if (lo < hi) lo else null;
}

/// **ONE TICK.** The dog, heading `h`, moved `tick` px to `dog`; where the
/// cow at `cow` is after it.
fn scooted(h: Heading, tick: f64, dog: Vec, cow: CowPoint) CowPoint {
    const f = Frame.of(h, dog, cow);
    const coming: ?f64 = if (f.along <= scare_reach_px) f.toCome() else null;
    if (coming == null and !f.inCone()) return cow;
    // The side it is on, the dog's right when dead centre.
    var side: f64 = if (f.across >= 0) 1 else -1;
    var step = tick / 2;
    if (coming) |left_to_come| {
        // How far across it must go to be out of the path; the other side
        // when the world's edge leaves no room to clear on its own.
        const half_path = f.halfPath();
        var out = half_path - @abs(f.across) + clear_spare_px;
        if (f.room(cow, side) < out) {
            const other = half_path + @abs(f.across) + clear_spare_px;
            if (f.room(cow, -side) >= other) {
                side = -side;
                out = other;
            }
        }
        // As fast as is out of the path when the dog gets there; at once
        // when it gets there this coming tick, or is there already.
        step = @max(step, if (left_to_come <= tick) out else out * tick / left_to_come);
    }
    step = @min(step, f.room(cow, side));
    if (step <= 0) return cow;
    return .{ .park_x = cow.park_x + side * step * f.rx, .park_y = cow.park_y + side * step * f.ry };
}

/// The size of `v`, signed, so it subtracts as one.
fn mag(v: i64) i64 {
    return if (v < 0) -v else v;
}

/// How the cows are written down: `{"cows":[{"id","park_x","park_y"}, ...]}`.
const Written = struct { cows: []const struct { id: u32, park_x: f64, park_y: f64 } };

pub const Cows = struct {
    list: [cow_count]CowPoint,

    /// One cow in the middle of every white tile (a tile is white when its
    /// column plus its row is even), row by row.
    pub fn laidOut() Cows {
        var c: Cows = undefined;
        var n: usize = 0;
        var row: i32 = 0;
        while (row < tiles.world_tiles) : (row += 1) {
            var col: i32 = 0;
            while (col < tiles.world_tiles) : (col += 1) {
                if (@mod(col + row, 2) == 1) continue;
                c.list[n] = .{
                    .park_x = @floatFromInt(col * tiles.tile_px + in_white),
                    .park_y = @floatFromInt(row * tiles.tile_px + in_white),
                };
                n += 1;
            }
        }
        std.debug.assert(n == cow_count);
        return c;
    }

    pub const ReadError = error{ NotCows, WrongCows };

    /// The cows as written: exactly the laid-out cows, in order, each where
    /// it was kept, its whole square in the world.
    pub fn read(bytes: []const u8) ReadError!Cows {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const w = std.json.parseFromSliceLeaky(Written, arena.allocator(), bytes, .{}) catch return error.NotCows;
        if (w.cows.len != cow_count) return error.WrongCows;
        var c = laidOut();
        for (w.cows, &c.list, 0..) |stored, *cow, i| {
            const kept: CowPoint = .{ .park_x = stored.park_x, .park_y = stored.park_y };
            if (stored.id != i or !inWorld(kept)) return error.WrongCows;
            cow.* = kept;
        }
        return c;
    }

    /// Each cow's place as Zig writes an f64, the shortest that reads back
    /// the same, so a kept cow is where it was to the bit.
    pub fn written(self: *const Cows, alloc: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        try out.writer.writeAll("{\"cows\":[");
        for (self.list, 0..) |cow, i| {
            if (i > 0) try out.writer.writeAll(",");
            try out.writer.print("\n{{\"id\":{d},\"park_x\":{d},\"park_y\":{d}}}", .{ i, cow.park_x, cow.park_y });
        }
        try out.writer.writeAll("\n]}\n");
        return out.toOwnedSlice();
    }

    pub fn at(self: *const Cows, cow: CowId) CowPoint {
        return self.list[@intFromEnum(cow)];
    }
};

const testing = std.testing;

fn pt(x: i32, y: i32) ParkPoint {
    return .{ .park_x = x, .park_y = y };
}

fn cp(x: f64, y: f64) CowPoint {
    return .{ .park_x = x, .park_y = y };
}

/// The reaction to one segment, its heading the segment's own.
fn once(from: ParkPoint, to: ParkPoint, cow: CowPoint) Reaction {
    return reaction(.{ .hx = @as(i64, to.park_x) - from.park_x, .hy = @as(i64, to.park_y) - from.park_y }, from, to, cow);
}

fn expectAt(want: CowPoint, got: Reaction) !void {
    const p = switch (got) {
        .steps_to => |p| p,
        .stays => return error.TheCowStayed,
    };
    try testing.expectApproxEqAbs(want.park_x, p.park_x, 1e-9);
    try testing.expectApproxEqAbs(want.park_y, p.park_y, 1e-9);
}

test "the first layout: 50 cows, one in the middle of each white tile" {
    const c = Cows.laidOut();
    try testing.expectEqual(@as(usize, 50), cow_count);
    try testing.expectEqual(cp(250, 250), c.at(@enumFromInt(0)));
    try testing.expectEqual(cp(1250, 250), c.at(@enumFromInt(1)));
    try testing.expectEqual(cp(750, 750), c.at(@enumFromInt(5)));
}

test "the heading: from the latest point 24 px back, or the earliest; a slow drag's pixels steer it no more than its line" {
    try testing.expectEqual(Heading{ .hx = 30, .hy = 0 }, headingAt(&.{ pt(0, 0), pt(30, 0), pt(31, 0) }, 1));
    // Back from (31, 0): (30, 0) is 1 px, (0, 0) 31 px: the chord from it.
    try testing.expectEqual(Heading{ .hx = 31, .hy = 0 }, headingAt(&.{ pt(0, 0), pt(30, 0), pt(31, 0) }, 2));
    // None 24 px back: the earliest.
    try testing.expectEqual(Heading{ .hx = 2, .hy = 1 }, headingAt(&.{ pt(0, 0), pt(1, 0), pt(2, 1) }, 2));
    // A drag at slope (1, -3), a pixel a step: each step is north or
    // north-east, the heading within 3 degrees of the line.
    var buf: [200]ParkPoint = undefined;
    const points = drag(&buf, pt(0, 0), 1, -3, 1);
    for (30..200) |k| {
        const h = headingAt(points, k);
        const off = std.math.atan2(@as(f64, @floatFromInt(h.hx)), -@as(f64, @floatFromInt(h.hy))) - std.math.atan2(@as(f64, 1), 3);
        try testing.expect(@abs(off) < std.math.degreesToRadians(3));
    }
}

test "the reach: a cow on the path 400 px ahead scoots aside, at 401 it stays" {
    // East, 10 px; the cow on the path goes to the dog's right (south), at
    // half speed: the dog is far off.
    try expectAt(cp(1400, 1005), once(pt(990, 1000), pt(1000, 1000), cp(1400, 1000)));
    try testing.expectEqual(Reaction.stays, once(pt(990, 1000), pt(1000, 1000), cp(1401, 1000)));
}

test "the cone: a cow 49 degrees off the heading scoots, one 51 degrees off stays, either side" {
    // About 300 px from the dog: (197, 226) is 48.9 degrees off east,
    // (189, 233) 50.96; both far out of the dog's path.
    try expectAt(cp(1197, 1231), once(pt(990, 1000), pt(1000, 1000), cp(1197, 1226)));
    try testing.expectEqual(Reaction.stays, once(pt(990, 1000), pt(1000, 1000), cp(1189, 1233)));
    try expectAt(cp(1197, 769), once(pt(990, 1000), pt(1000, 1000), cp(1197, 774)));
    try testing.expectEqual(Reaction.stays, once(pt(990, 1000), pt(1000, 1000), cp(1189, 767)));
}

test "a cow behind the dog, beside it and clear, or under a dog that didn't move stays" {
    try testing.expectEqual(Reaction.stays, once(pt(990, 1000), pt(1000, 1000), cp(900, 1000)));
    try testing.expectEqual(Reaction.stays, once(pt(990, 1000), pt(1000, 1000), cp(1000, 1100)));
    try testing.expectEqual(Reaction.stays, once(pt(1000, 1000), pt(1000, 1000), cp(1050, 1000)));
    // Clear of the dog's back corner (25 px), the dog moving off south-east
    // away from it: not in its path.
    try testing.expectEqual(Reaction.stays, once(pt(999, 999), pt(1000, 1000), cp(1009, 925)));
}

test "a cow north of a dog heading north goes east or west, never north: the side it is on, east when dead ahead" {
    try expectAt(cp(1015, 700), once(pt(1000, 1010), pt(1000, 1000), cp(1010, 700)));
    try expectAt(cp(985, 700), once(pt(1000, 1010), pt(1000, 1000), cp(990, 700)));
    try expectAt(cp(1005, 700), once(pt(1000, 1010), pt(1000, 1000), cp(1000, 700)));
    // Heading south-east, (6, 8): across it is (-0.8, 0.6) and (0.8, -0.6);
    // a cow left of the path goes (4, -3), half the dog's 10 px.
    try expectAt(cp(1200 - 4, 1270 + 3), once(pt(994, 992), pt(1000, 1000), cp(1200, 1270)));
}

test "half speed until the dog is close; then as fast as clears the path by the time it arrives; at once when it has" {
    // 300 px ahead: half the dog's 10 px.
    try expectAt(cp(1005, 700), once(pt(1000, 1010), pt(1000, 1000), cp(1000, 700)));
    // 100 px ahead (30 px of travel before the squares are 20 apart), 71 px
    // to go: 71 * 10 / 30 this move.
    try expectAt(cp(1000 + 71.0 * 10.0 / 30.0, 900), once(pt(1000, 1010), pt(1000, 1000), cp(1000, 900)));
    // 70 px ahead, the squares 20 apart: all 71 px now.
    try expectAt(cp(1071, 930), once(pt(1000, 1010), pt(1000, 1000), cp(1000, 930)));
    // 30 px east of the line: 41 px to go.
    try expectAt(cp(1071, 935), once(pt(1000, 1010), pt(1000, 1000), cp(1030, 935)));
}

test "half the dog's speed, exactly: a 1 px move moves a cow half a pixel, 3 px a pixel and a half" {
    try expectAt(cp(1300, 1000.5), once(pt(999, 1000), pt(1000, 1000), cp(1300, 1000)));
    try expectAt(cp(1300, 1001.5), once(pt(997, 1000), pt(1000, 1000), cp(1300, 1000)));
}

test "the world's edge: no room to clear on the cow's side, the other side; no room to scoot, a shorter step or none, never along the heading" {
    // Heading north at x 4950, the cow 10 px east of the line: east it has
    // 10 px before its square leaves the world and needs 61; west is 81,
    // 27 of them now (30 px of travel left).
    try expectAt(cp(4933, 900), once(pt(4950, 1010), pt(4950, 1000), cp(4960, 900)));
    // A cow against the east wall, scared but not in the path, the dog
    // heading north-east: across is south-east, with no room east, so it
    // stays rather than slide along the wall.
    try testing.expectEqual(Reaction.stays, once(pt(4668, 1152), pt(4670, 1150), cp(4970, 1000)));
    // Heading north, the cow 2 px from the east wall, scared (40 degrees
    // off) and out of the path: 2 of its 5 px.
    try expectAt(cp(4970, 800), once(pt(4800, 1010), pt(4800, 1000), cp(4968, 800)));
}

test "a dog jumping 500 px between reports doesn't pass through a cow: it scoots aside, never ahead" {
    const end = switch (once(pt(800, 1000), pt(1300, 1000), cp(1050, 1000))) {
        .steps_to => |p| p,
        .stays => return error.TheCowStayed,
    };
    try testing.expectEqual(@as(f64, 1050), end.park_x);
    try testing.expect(end.park_y >= 1000 + touching_px + clearance_px);
}

/// A drag, a whole pixel at a time, from `from` along (dx, dy), points
/// `stride` px apart, as a page records it: `buf.len` points.
fn drag(buf: []ParkPoint, from: ParkPoint, dx: f64, dy: f64, stride: f64) []ParkPoint {
    const len = std.math.hypot(dx, dy);
    for (buf, 0..) |*p, i| {
        const d = stride * @as(f64, @floatFromInt(i));
        p.* = pt(from.park_x + @as(i32, @intFromFloat(@round(dx / len * d))), from.park_y + @as(i32, @intFromFloat(@round(dy / len * d))));
    }
    return buf;
}

test "a slow drag at an awkward angle (the review's): a cow on the line goes aside, and once 5 px off the line it never changes side; never herded ahead" {
    const cases = [_]struct { dx: f64, dy: f64, stride: f64 }{
        .{ .dx = 1, .dy = -3, .stride = 1 },
        .{ .dx = 1, .dy = -3, .stride = 2 },
        .{ .dx = 3, .dy = 1, .stride = 1 },
        .{ .dx = 10, .dy = 1, .stride = 2 },
    };
    for (cases) |c| {
        var buf: [401]ParkPoint = undefined;
        const n: usize = @intFromFloat(400 / c.stride);
        const points = drag(buf[0 .. n + 1], pt(1000, 1000), c.dx, c.dy, c.stride);
        const len = std.math.hypot(c.dx, c.dy);
        // On the line, 200 px ahead; each point a move, as a page sends a
        // slow drag.
        var cows = [_]CowPoint{cp(1000 + c.dx / len * 200, 1000 + c.dy / len * 200)};
        const start = cows[0];
        // Across the drag's own line, to its right.
        const across = struct {
            fn of(p: CowPoint, s: CowPoint, dx: f64, dy: f64, l: f64) f64 {
                return -dy / l * (p.park_x - s.park_x) + dx / l * (p.park_y - s.park_y);
            }
        }.of;
        var flips_once_aside: usize = 0;
        var side: f64 = 0;
        for (1..points.len) |k| {
            const before = cows[0];
            replay(&cows, points[0 .. k + 1], k, null);
            const moved = across(cows[0], start, c.dx, c.dy, len) - across(before, start, c.dx, c.dy, len);
            if (moved == 0) continue;
            if (@abs(across(before, start, c.dx, c.dy, len)) >= 5) {
                if (side != 0 and std.math.sign(moved) != side) flips_once_aside += 1;
                side = std.math.sign(moved);
            }
        }
        const along = (cows[0].park_x - start.park_x) * c.dx / len + (cows[0].park_y - start.park_y) * c.dy / len;
        const aside = @abs(across(cows[0], start, c.dx, c.dy, len));
        if (@abs(along) >= 3 or flips_once_aside > 0 or aside < 70) {
            std.debug.print("drag ({d}, {d}) at {d} px: the cow went {d:.1} px along and {d:.1} aside, changing side {d} times once 5 px off\n", .{ c.dx, c.dy, c.stride, along, aside, flips_once_aside });
            return error.TheCowWasHerded;
        }
    }
}

/// The gap between a dog's square at `dog` and a cow's at `cow`.
fn gap(dog: ParkPoint, cow: CowPoint) f64 {
    const gx = @max(0, @abs(cow.park_x - @as(f64, @floatFromInt(dog.park_x))) - touching_px);
    const gy = @max(0, @abs(cow.park_y - @as(f64, @floatFromInt(dog.park_y))) - touching_px);
    return std.math.hypot(gx, gy);
}

test "random moves near a cow (seeded): the squares never come within half a dog, and the cow only ever moves across the heading" {
    var prng: std.Random.DefaultPrng = .init(0xc0ffee);
    const rand = prng.random();
    var trials: usize = 0;
    while (trials < 20_000) {
        const dog = pt(rand.intRangeAtMost(i32, 1000, 4000), rand.intRangeAtMost(i32, 1000, 4000));
        const cow = cp(@floatFromInt(dog.park_x + rand.intRangeAtMost(i32, -200, 200)), @floatFromInt(dog.park_y + rand.intRangeAtMost(i32, -200, 200)));
        if (gap(dog, cow) < clearance_px) continue; // a start the rule never leaves
        const to = pt(dog.park_x + rand.intRangeAtMost(i32, -80, 80), dog.park_y + rand.intRangeAtMost(i32, -80, 80));
        if (std.meta.eql(dog, to)) continue;
        trials += 1;
        const end = switch (once(dog, to, cow)) {
            .steps_to => |p| p,
            .stays => cow,
        };
        try testing.expect(gap(to, end) >= clearance_px);
        const hx: f64 = @floatFromInt(to.park_x - dog.park_x);
        const hy: f64 = @floatFromInt(to.park_y - dog.park_y);
        const along = ((end.park_x - cow.park_x) * hx + (end.park_y - cow.park_y) * hy) / std.math.hypot(hx, hy);
        try testing.expect(@abs(along) < 1e-9);
    }
}

test "a replayed move scares every cow ahead of it, and only those, and says which" {
    var c = Cows.laidOut();
    var moved = [_]bool{false} ** cow_count;
    // Dog heading east along row 250 from (0, 250): cow 0 at (250, 250) is
    // 240 px ahead; cow 1 at (1250, 250) is too far.
    replay(&c.list, &.{ pt(0, 250), pt(10, 250) }, 1, &moved);
    try testing.expect(moved[0] and !moved[1]);
    try testing.expectEqual(cp(250, 255), c.at(@enumFromInt(0)));
}

test "cows written read back the same, to the bit; a cow outside the world, missing or out of order does not read" {
    var c = Cows.laidOut();
    c.list[0] = cp(250.123456789, 255.5);
    const bytes = try c.written(testing.allocator);
    defer testing.allocator.free(bytes);
    const back = try Cows.read(bytes);
    try testing.expectEqual(cp(250.123456789, 255.5), back.at(@enumFromInt(0)));
    try testing.expectError(error.NotCows, Cows.read("not json"));
    try testing.expectError(error.WrongCows, Cows.read("{\"cows\":[]}"));
    const outside = try std.mem.replaceOwned(u8, testing.allocator, bytes, "\"park_x\":250.123456789,", "\"park_x\":29.5,");
    defer testing.allocator.free(outside);
    try testing.expectError(error.WrongCows, Cows.read(outside));
    const swapped = try std.mem.replaceOwned(u8, testing.allocator, bytes, "{\"id\":0,", "{\"id\":1,");
    defer testing.allocator.free(swapped);
    try testing.expectError(error.WrongCows, Cows.read(swapped));
}

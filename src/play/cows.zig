//! The cows: one in the middle of every white tile, and scared of moving
//! dogs. **THE SERVER MOVES THEM**, as a reaction to a dog's move. Each
//! critter is its sprite's square (a dog `dog_px` a side, a cow `cow_px`),
//! centred on its park point.
//!
//! **A COW ONLY EVER MOVES ACROSS THE DOG'S HEADING**: it clears the path,
//! never runs ahead. It moves when the dog is heading for it, centre to
//! centre within `scare_reach_px` and `scare_cone_degrees`, or when it
//! stands in the dog's PATH: the band the dog's square sweeps ahead of it,
//! widened by `clearance_px` and by the cow's own square. It moves to the
//! side of the path it is on (the dog's right when dead centre; the other
//! side when the world's edge leaves no room), at half the dog's speed, or
//! faster only when it must: when at half speed the dog would reach it
//! before it is out of the path, it moves as fast as clears the path by the
//! time the dog gets there, and at once if the dog is on it already.
//!
//! A move report is played as ticks of at most `tick_px` on each axis, so a
//! dog that jumps far between reports can't pass through a cow. Whole park
//! pixels; the sideways step is f64, rounded, the same on every host.

const std = @import("std");
const dogs = @import("dogs.zig");
const tiles = @import("tiles.zig");
const ParkPoint = dogs.ParkPoint;

/// A cow is known by its place in the list, made once.
pub const CowId = enum(u16) { _ };

pub const Cow = struct { at: ParkPoint };

/// The squares, as the page draws them (park.js's dog_px and cow_px).
pub const dog_px = 40;
pub const cow_px = 60;

/// How far ahead a dog scares a cow, centre to centre, in park pixels: in
/// a straight line for the cone, along the heading for the path.
pub const scare_reach_px = 400;

/// How far off the dog's heading a cow may be and still be scared: 50
/// degrees, as the test `dot^2 >= cos^2(50) * |heading|^2 * |toward|^2`
/// with cos^2(50 degrees) as `cone_cos_sq_millionths` / 1e6, and the dot
/// product positive (ahead, not behind).
pub const scare_cone_degrees = 50;
const cone_cos_sq_millionths = 413_176;

/// The least gap a cow keeps between the dog's square and its own: half a
/// dog.
pub const clearance_px = dog_px / 2;

/// The longest tick a move report is played in, on each axis.
pub const tick_px = 10;

/// Centre to centre, the squares just touch at `touching_px` on an axis.
const touching_px = (dog_px + cow_px) / 2;

/// Where a cow stands in its tile: the middle, clear of the white tile's two
/// dogs.
const in_white: ParkPoint = .{ .park_x = tiles.tile_px / 2, .park_y = tiles.tile_px / 2 };

pub const cow_count = tiles.world_tiles * tiles.world_tiles - tiles.world_tiles * tiles.world_tiles / 2;

/// A cow's centre kept so its whole square is in the world.
fn keptInWorld(at: ParkPoint) ParkPoint {
    const half = cow_px / 2;
    return .{ .park_x = std.math.clamp(at.park_x, half, tiles.world_px - half), .park_y = std.math.clamp(at.park_y, half, tiles.world_px - half) };
}

fn inWorld(at: ParkPoint) bool {
    return std.meta.eql(keptInWorld(at), at);
}

/// What a dog's move does to one cow.
pub const Reaction = union(enum) {
    /// Not scared: too far, off to the side, behind the dog, the dog didn't
    /// move, or the cow can't step.
    stays,
    /// Scared: where it stepped to.
    steps_to: ParkPoint,
};

/// **THE RULE, OVER ONE MOVE REPORT.** A dog moved from `from` to `to`: the
/// cow at `cow`, after each tick of the move, all across the report's
/// heading.
pub fn reaction(from: ParkPoint, to: ParkPoint, cow: ParkPoint) Reaction {
    const hx: i64 = @as(i64, to.park_x) - from.park_x;
    const hy: i64 = @as(i64, to.park_y) - from.park_y;
    if (hx == 0 and hy == 0) return .stays;
    const ticks = @max(1, std.math.divCeil(i64, @max(mag(hx), mag(hy)), tick_px) catch unreachable);
    const tick = std.math.hypot(@as(f64, @floatFromInt(hx)), @as(f64, @floatFromInt(hy))) / @as(f64, @floatFromInt(ticks));
    var at = cow;
    var k: i64 = 1;
    while (k <= ticks) : (k += 1) {
        const now: ParkPoint = .{
            .park_x = from.park_x + @as(i32, @intCast(@divTrunc(hx * k, ticks))),
            .park_y = from.park_y + @as(i32, @intCast(@divTrunc(hy * k, ticks))),
        };
        at = scooted(hx, hy, tick, now, at);
    }
    if (std.meta.eql(at, cow)) return .stays;
    return .{ .steps_to = at };
}

/// Whether the dog, heading (hx, hy) and now at `to`, heads for the cow at
/// `cow`: centre to centre within `scare_reach_px`, within
/// `scare_cone_degrees` of its heading, and ahead of it.
fn inCone(hx: i64, hy: i64, to: ParkPoint, cow: ParkPoint) bool {
    const tx: i64 = @as(i64, cow.park_x) - to.park_x;
    const ty: i64 = @as(i64, cow.park_y) - to.park_y;
    const toward_sq = tx * tx + ty * ty;
    if (toward_sq > scare_reach_px * scare_reach_px) return false;
    const dot = hx * tx + hy * ty;
    if (dot <= 0) return false;
    const heading_sq = hx * hx + hy * hy;
    return @as(i128, dot) * dot * 1_000_000 >= @as(i128, cone_cos_sq_millionths) * heading_sq * toward_sq;
}

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

    fn of(hx: i64, hy: i64, dog: ParkPoint, cow: ParkPoint) Frame {
        const len = std.math.hypot(@as(f64, @floatFromInt(hx)), @as(f64, @floatFromInt(hy)));
        const ux = @as(f64, @floatFromInt(hx)) / len;
        const uy = @as(f64, @floatFromInt(hy)) / len;
        const dx: f64 = @floatFromInt(@as(i64, cow.park_x) - dog.park_x);
        const dy: f64 = @floatFromInt(@as(i64, cow.park_y) - dog.park_y);
        return .{ .ux = ux, .uy = uy, .rx = -uy, .ry = ux, .dx = dx, .dy = dy, .across = -uy * dx + ux * dy, .along = ux * dx + uy * dy };
    }

    /// Half the path's width: how far across the heading the cow's centre
    /// must be for the squares, the dog's carried on along the heading,
    /// never to come within `clearance_px` (both squares and the clearance,
    /// as wide as they are across this heading).
    fn halfPath(self: Frame) f64 {
        return @as(f64, touching_px) * (@abs(self.rx) + @abs(self.ry)) + clearance_px;
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

/// **ONE TICK.** The dog, heading (hx, hy), moved `tick` px to `to`; where
/// the cow at `cow` is after it.
fn scooted(hx: i64, hy: i64, tick: f64, to: ParkPoint, cow: ParkPoint) ParkPoint {
    const f = Frame.of(hx, hy, to, cow);
    const coming: ?f64 = if (f.along <= scare_reach_px) f.toCome() else null;
    if (coming == null and !inCone(hx, hy, to, cow)) return cow;
    const half_path = f.halfPath();
    const usual = tick / 2;
    // The side it is on, the dog's right when dead centre; how far across it
    // must go to be out of the path (a pixel spare, for the rounding).
    var side: f64 = if (f.across >= 0) 1 else -1;
    var out = half_path - @abs(f.across) + 1;
    if (coming != null and !roomFor(cow, f, side * out)) {
        side = -side;
        out = half_path + @abs(f.across) + 1;
    }
    var step = usual;
    if (coming) |left_to_come| {
        // As fast as is out of the path when the dog gets there; at once
        // when it gets there this coming tick, or is there already.
        step = @max(usual, if (left_to_come <= tick) out else out * tick / left_to_come);
    }
    return keptInWorld(.{
        .park_x = cow.park_x + @as(i32, @intFromFloat(@round(side * step * f.rx))),
        .park_y = cow.park_y + @as(i32, @intFromFloat(@round(side * step * f.ry))),
    });
}

/// Whether the cow at `cow` can move `by` across the heading and stay in
/// the world.
fn roomFor(cow: ParkPoint, f: Frame, by: f64) bool {
    return inWorld(.{
        .park_x = cow.park_x + @as(i32, @intFromFloat(@round(by * f.rx))),
        .park_y = cow.park_y + @as(i32, @intFromFloat(@round(by * f.ry))),
    });
}

/// The size of `v`, signed, so it subtracts as one.
fn mag(v: i64) i64 {
    return if (v < 0) -v else v;
}

/// How the cows are written down: `{"cows":[{"id","park_x","park_y"}, ...]}`.
const Written = struct { cows: []const struct { id: u32, park_x: i32, park_y: i32 } };

/// The cows a move scared, at most all of them.
pub const Scared = struct {
    ids: [cow_count]CowId = undefined,
    len: usize = 0,

    pub fn slice(self: *const Scared) []const CowId {
        return self.ids[0..self.len];
    }
};

pub const Cows = struct {
    list: [cow_count]Cow,

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
                c.list[n] = .{ .at = .{ .park_x = col * tiles.tile_px + in_white.park_x, .park_y = row * tiles.tile_px + in_white.park_y } };
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
            const kept: ParkPoint = .{ .park_x = stored.park_x, .park_y = stored.park_y };
            if (stored.id != i or !inWorld(kept)) return error.WrongCows;
            cow.at = kept;
        }
        return c;
    }

    pub fn written(self: *const Cows, alloc: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        try out.writer.writeAll("{\"cows\":[");
        for (self.list, 0..) |cow, i| {
            if (i > 0) try out.writer.writeAll(",");
            try out.writer.print("\n{{\"id\":{d},\"park_x\":{d},\"park_y\":{d}}}", .{ i, cow.at.park_x, cow.at.park_y });
        }
        try out.writer.writeAll("\n]}\n");
        return out.toOwnedSlice();
    }

    pub fn at(self: *const Cows, cow: CowId) ParkPoint {
        return self.list[@intFromEnum(cow)].at;
    }

    /// A dog moved from `from` to `to`: every cow it scared steps, and the
    /// scared are answered, in id order.
    pub fn react(self: *Cows, from: ParkPoint, to: ParkPoint) Scared {
        var scared: Scared = .{};
        for (&self.list, 0..) |*cow, i| switch (reaction(from, to, cow.at)) {
            .stays => {},
            .steps_to => |p| {
                cow.at = p;
                scared.ids[scared.len] = @enumFromInt(i);
                scared.len += 1;
            },
        };
        return scared;
    }
};

const testing = std.testing;

fn pt(x: i32, y: i32) ParkPoint {
    return .{ .park_x = x, .park_y = y };
}

test "the first layout: 50 cows, one in the middle of each white tile, none in a blue one" {
    const c = Cows.laidOut();
    try testing.expectEqual(@as(usize, 50), cow_count);
    try testing.expectEqual(pt(250, 250), c.at(@enumFromInt(0)));
    try testing.expectEqual(pt(1250, 250), c.at(@enumFromInt(1)));
    try testing.expectEqual(pt(750, 750), c.at(@enumFromInt(5)));
    for (c.list) |cow| {
        const t = tiles.Tile.of(cow.at);
        try testing.expectEqual(@as(i32, 0), @mod(t.col + t.row, 2));
    }
}

test "the reach: a cow on the path 400 px ahead scoots aside, at 401 it stays" {
    // East, 10 px a move; the cow on the path goes to the dog's right
    // (south), at half speed: the dog is far off.
    try testing.expectEqual(Reaction{ .steps_to = pt(1400, 1005) }, reaction(pt(990, 1000), pt(1000, 1000), pt(1400, 1000)));
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1401, 1000)));
}

test "the cone: a cow 49 degrees off the heading scoots, one 51 degrees off stays, either side" {
    // About 300 px from the dog: (197, 226) is 48.9 degrees off east,
    // (189, 233) 50.96; both far out of the dog's path.
    try testing.expectEqual(Reaction{ .steps_to = pt(1197, 1231) }, reaction(pt(990, 1000), pt(1000, 1000), pt(1197, 1226)));
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1189, 1233)));
    try testing.expectEqual(Reaction{ .steps_to = pt(1197, 769) }, reaction(pt(990, 1000), pt(1000, 1000), pt(1197, 774)));
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1189, 767)));
}

test "a cow behind the dog, beside it and clear, or under a dog that didn't move stays" {
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(900, 1000)));
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1000, 1100)));
    try testing.expectEqual(Reaction.stays, reaction(pt(1000, 1000), pt(1000, 1000), pt(1050, 1000)));
    // Clear of the dog's back corner (25 px), the dog moving off south-east
    // away from it: not in its path.
    try testing.expectEqual(Reaction.stays, reaction(pt(999, 999), pt(1000, 1000), pt(1009, 925)));
}

test "a cow north of a dog heading north goes east or west, never north: the side it is on, east when dead ahead" {
    try testing.expectEqual(Reaction{ .steps_to = pt(1015, 700) }, reaction(pt(1000, 1010), pt(1000, 1000), pt(1010, 700)));
    try testing.expectEqual(Reaction{ .steps_to = pt(985, 700) }, reaction(pt(1000, 1010), pt(1000, 1000), pt(990, 700)));
    try testing.expectEqual(Reaction{ .steps_to = pt(1005, 700) }, reaction(pt(1000, 1010), pt(1000, 1000), pt(1000, 700)));
    // Heading south-east, (6, 8): across it is (-8, 6) and (8, -6); a cow
    // left of the path goes (4, -3), half the dog's 10 px, square to it.
    try testing.expectEqual(Reaction{ .steps_to = pt(1200 - 4, 1270 + 3) }, reaction(pt(994, 992), pt(1000, 1000), pt(1200, 1270)));
}

test "half speed until the dog is close; then as fast as clears the path by the time it arrives; at once when it has" {
    // 300 px ahead: half the dog's 10 px.
    try testing.expectEqual(Reaction{ .steps_to = pt(1005, 700) }, reaction(pt(1000, 1010), pt(1000, 1000), pt(1000, 700)));
    // 100 px ahead (30 px of travel before the squares are 20 apart), 71 px
    // to go: 71 * 10 / 30, 24 px this move.
    try testing.expectEqual(Reaction{ .steps_to = pt(1024, 900) }, reaction(pt(1000, 1010), pt(1000, 1000), pt(1000, 900)));
    // 70 px ahead, the squares 20 apart: all 71 px now.
    try testing.expectEqual(Reaction{ .steps_to = pt(1071, 930) }, reaction(pt(1000, 1010), pt(1000, 1000), pt(1000, 930)));
    // 30 px east of the line: 41 px to go.
    try testing.expectEqual(Reaction{ .steps_to = pt(1071, 935) }, reaction(pt(1000, 1010), pt(1000, 1000), pt(1030, 935)));
}

test "half the dog's speed, half away from zero: a 1 px move moves a cow 1 px, 3 px moves it 2" {
    try testing.expectEqual(Reaction{ .steps_to = pt(1300, 1001) }, reaction(pt(999, 1000), pt(1000, 1000), pt(1300, 1000)));
    try testing.expectEqual(Reaction{ .steps_to = pt(1300, 1002) }, reaction(pt(997, 1000), pt(1000, 1000), pt(1300, 1000)));
}

test "the world's edge leaves no room on the cow's side, so it goes the other way, still across the heading" {
    // Heading north at x 4950, the cow 10 px east of the line: east it would
    // go past 4970, its square out of the world; west is 81 px, 27 of them
    // now (30 px of travel left).
    try testing.expectEqual(Reaction{ .steps_to = pt(4933, 900) }, reaction(pt(4950, 1010), pt(4950, 1000), pt(4960, 900)));
}

test "a dog jumping 500 px between reports doesn't pass through a cow: it scoots aside, never ahead" {
    try testing.expectEqual(Reaction{ .steps_to = pt(1050, 1085) }, reaction(pt(800, 1000), pt(1300, 1000), pt(1050, 1000)));
}

/// The gap between a dog's square at `dog` and a cow's at `cow`, squared.
fn gapSq(dog: ParkPoint, cow: ParkPoint) i64 {
    const gx = @max(0, mag(@as(i64, cow.park_x) - dog.park_x) - touching_px);
    const gy = @max(0, mag(@as(i64, cow.park_y) - dog.park_y) - touching_px);
    return gx * gx + gy * gy;
}

test "random moves near a cow (seeded): the squares never come within half a dog, and the cow only ever moves across the heading" {
    var prng: std.Random.DefaultPrng = .init(0xc0ffee);
    const rand = prng.random();
    var trials: usize = 0;
    while (trials < 20_000) {
        const dog = pt(rand.intRangeAtMost(i32, 1000, 4000), rand.intRangeAtMost(i32, 1000, 4000));
        const cow = pt(dog.park_x + rand.intRangeAtMost(i32, -200, 200), dog.park_y + rand.intRangeAtMost(i32, -200, 200));
        if (gapSq(dog, cow) < clearance_px * clearance_px) continue; // a start the rule never leaves
        const to = pt(dog.park_x + rand.intRangeAtMost(i32, -80, 80), dog.park_y + rand.intRangeAtMost(i32, -80, 80));
        if (std.meta.eql(dog, to)) continue;
        trials += 1;
        const end = switch (reaction(dog, to, cow)) {
            .steps_to => |p| p,
            .stays => cow,
        };
        try testing.expect(gapSq(to, end) >= clearance_px * clearance_px);
        // Along the heading, no more than each tick's rounding.
        const hx: f64 = @floatFromInt(to.park_x - dog.park_x);
        const hy: f64 = @floatFromInt(to.park_y - dog.park_y);
        const ticks: f64 = @floatFromInt(@max(1, std.math.divCeil(i64, @max(mag(to.park_x - dog.park_x), mag(to.park_y - dog.park_y)), tick_px) catch unreachable));
        const along = (@as(f64, @floatFromInt(end.park_x - cow.park_x)) * hx + @as(f64, @floatFromInt(end.park_y - cow.park_y)) * hy) / std.math.hypot(hx, hy);
        if (@abs(along) > 0.71 * ticks) {
            std.debug.print("dog {any} -> {any}, cow {any} -> {any}: {d:.2} px along\n", .{ dog, to, cow, end, along });
            return error.TheCowMovedAlong;
        }
    }
}

test "one move scares every cow ahead of it, and only those, in id order" {
    var c = Cows.laidOut();
    // Dog heading east along row 250 from (0, 250): cow 0 at (250, 250) is
    // 240 px ahead; cow 1 at (1250, 250) is too far.
    const scared = c.react(pt(0, 250), pt(10, 250));
    try testing.expectEqual(@as(usize, 1), scared.len);
    try testing.expectEqual(@as(CowId, @enumFromInt(0)), scared.slice()[0]);
    try testing.expectEqual(pt(250, 255), c.at(@enumFromInt(0)));
    try testing.expectEqual(pt(1250, 250), c.at(@enumFromInt(1)));
}

test "cows written read back the same, moves and all; a cow outside the world, missing or out of order does not read" {
    var c = Cows.laidOut();
    _ = c.react(pt(0, 250), pt(10, 250));
    const bytes = try c.written(testing.allocator);
    defer testing.allocator.free(bytes);
    const back = try Cows.read(bytes);
    try testing.expectEqual(pt(250, 255), back.at(@enumFromInt(0)));
    try testing.expectError(error.NotCows, Cows.read("not json"));
    try testing.expectError(error.WrongCows, Cows.read("{\"cows\":[]}"));
    const outside = try std.mem.replaceOwned(u8, testing.allocator, bytes, "\"park_x\":250,\"park_y\":255", "\"park_x\":-1,\"park_y\":255");
    defer testing.allocator.free(outside);
    try testing.expectError(error.WrongCows, Cows.read(outside));
    const swapped = try std.mem.replaceOwned(u8, testing.allocator, bytes, "{\"id\":0,", "{\"id\":1,");
    defer testing.allocator.free(swapped);
    try testing.expectError(error.WrongCows, Cows.read(swapped));
}

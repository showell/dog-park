//! The cows: one in the middle of every white tile, and scared of moving
//! dogs. **THE SERVER MOVES THEM**, as a reaction to a dog's move. Each
//! critter is its sprite's square (a dog `dog_px` a side, a cow `cow_px`),
//! centred on its park point. Two rules, in this order:
//!
//!   - **FAR: a cow clears the path.** A cow a dog is heading for, within
//!     `scare_reach_px` and `scare_cone_degrees` of its heading, steps
//!     perpendicular to the heading, away from the path, at half the dog's
//!     speed. It doesn't try to outrun the dog.
//!   - **NEAR: a cow never lets a dog within half a dog of it.** After the
//!     dog moves, the cow takes the least step that leaves `clearance_px`
//!     between the two squares, however fast that is.
//!
//! A move report is played as ticks of at most `tick_px` on each axis, both
//! rules in each, so a dog that jumps far between reports can't pass
//! through a cow. Over a report, a cow moves at most 1.5 times as far as the
//! dog: half its move (far) and the move itself (near), the dog's move in
//! dog lengths at most the cow's in cow lengths.
//!
//! In whole park pixels, by integer arithmetic but for the near rule's
//! corners (an f64 square root, rounded outward): the same answer on every
//! host.

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

/// How far ahead a dog scares a cow, centre to centre, in park pixels: a cow
/// this far from the dog, or nearer, may be scared.
pub const scare_reach_px = 700;

/// How far off the dog's heading a cow may be and still be scared: 50
/// degrees, as the test `dot^2 >= cos^2(50) * |heading|^2 * |toward|^2`
/// with cos^2(50 degrees) as `cone_cos_sq_millionths` / 1e6, and the dot
/// product positive (ahead, not behind).
pub const scare_cone_degrees = 50;
const cone_cos_sq_millionths = 413_176;

/// The least gap the near rule keeps between a dog's square and a cow's:
/// half a dog.
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

/// **THE RULES, OVER ONE MOVE REPORT.** A dog moved from `from` to `to`: the
/// cow at `cow`, after each tick of the move, the far rule then the near.
pub fn reaction(from: ParkPoint, to: ParkPoint, cow: ParkPoint) Reaction {
    const hx: i64 = @as(i64, to.park_x) - from.park_x;
    const hy: i64 = @as(i64, to.park_y) - from.park_y;
    if (hx == 0 and hy == 0) return .stays;
    const ticks = @max(1, std.math.divCeil(i64, @max(mag(hx), mag(hy)), tick_px) catch unreachable);
    var at = cow;
    var was = from;
    var k: i64 = 1;
    while (k <= ticks) : (k += 1) {
        const now: ParkPoint = .{
            .park_x = from.park_x + @as(i32, @intCast(@divTrunc(hx * k, ticks))),
            .park_y = from.park_y + @as(i32, @intCast(@divTrunc(hy * k, ticks))),
        };
        at = cleared(was, now, fled(was, now, at));
        was = now;
    }
    if (std.meta.eql(at, cow)) return .stays;
    return .{ .steps_to = at };
}

/// **FAR.** One tick, the dog from `from` to `to`: the cow at `cow` is
/// scared when it is within `scare_reach_px` of where the dog is now and
/// within `scare_cone_degrees` of the dog's heading. It steps perpendicular
/// to the heading, away from the dog's path, half as far as the dog moved
/// (half away from zero on each axis), along the world's edge if it meets
/// it. A cow on the path itself steps to the dog's right.
fn fled(from: ParkPoint, to: ParkPoint, cow: ParkPoint) ParkPoint {
    const hx: i64 = @as(i64, to.park_x) - from.park_x;
    const hy: i64 = @as(i64, to.park_y) - from.park_y;
    if (hx == 0 and hy == 0) return cow;
    const tx: i64 = @as(i64, cow.park_x) - to.park_x;
    const ty: i64 = @as(i64, cow.park_y) - to.park_y;
    const toward_sq = tx * tx + ty * ty;
    if (toward_sq > scare_reach_px * scare_reach_px) return cow;
    const dot = hx * tx + hy * ty;
    if (dot <= 0) return cow;
    const heading_sq = hx * hx + hy * hy;
    if (@as(i128, dot) * dot * 1_000_000 < @as(i128, cone_cos_sq_millionths) * heading_sq * toward_sq) return cow;
    const right = rightOf(hx, hy);
    const side: i64 = if (right.x * tx + right.y * ty >= 0) 1 else -1;
    return keptInWorld(.{
        .park_x = cow.park_x + @as(i32, @intCast(halved(side * right.x))),
        .park_y = cow.park_y + @as(i32, @intCast(halved(side * right.y))),
    });
}

/// The dog's right, with north up and park_y growing south: heading east
/// (1, 0), its right is south (0, 1).
fn rightOf(hx: i64, hy: i64) struct { x: i64, y: i64 } {
    return .{ .x = -hy, .y = hx };
}

/// The size of `v`, signed, so it subtracts as one.
fn mag(v: i64) i64 {
    return if (v < 0) -v else v;
}

/// Half, rounded half away from zero: a dog's 1 px step moves a cow 1 px,
/// not 0.
fn halved(v: i64) i64 {
    return @divTrunc(v + std.math.sign(v), 2);
}

/// **NEAR.** The dog, having come from `from`, is at `dog`: the cow at `cow`
/// takes the least step (by its length) that leaves `clearance_px` between
/// the squares and keeps it in the world, or stays if it is clear already
/// or no step does. Out along one axis, or round a corner of the dog's
/// square, radially; the other side of the dog when the world's edge
/// blocks the near one. A cow dead on the dog's centre line steps to the
/// dog's right, and a tie between the two axes goes to the one across the
/// dog's heading: a cow clears the path rather than run ahead.
fn cleared(from: ParkPoint, dog: ParkPoint, cow: ParkPoint) ParkPoint {
    const dx: i64 = @as(i64, cow.park_x) - dog.park_x;
    const dy: i64 = @as(i64, cow.park_y) - dog.park_y;
    const gx = mag(dx) - touching_px;
    const gy = mag(dy) - touching_px;
    if (gx > 0 and gy > 0) {
        if (gx * gx + gy * gy >= clearance_px * clearance_px) return cow;
    } else if (@max(gx, gy) >= clearance_px) return cow;
    const hx: i64 = @as(i64, dog.park_x) - from.park_x;
    const hy: i64 = @as(i64, dog.park_y) - from.park_y;
    const right = rightOf(hx, hy);
    const sx: i64 = if (dx != 0) std.math.sign(dx) else if (right.x != 0) std.math.sign(right.x) else 1;
    const sy: i64 = if (dy != 0) std.math.sign(dy) else if (right.y != 0) std.math.sign(right.y) else 1;
    const reach = touching_px + clearance_px;
    const along_x: ParkPoint = .{ .park_x = dog.park_x + @as(i32, @intCast(sx * reach)), .park_y = cow.park_y };
    const along_y: ParkPoint = .{ .park_x = cow.park_x, .park_y = dog.park_y + @as(i32, @intCast(sy * reach)) };
    const behind_x: ParkPoint = .{ .park_x = dog.park_x - @as(i32, @intCast(sx * reach)), .park_y = cow.park_y };
    const behind_y: ParkPoint = .{ .park_x = cow.park_x, .park_y = dog.park_y - @as(i32, @intCast(sy * reach)) };
    var round: ?ParkPoint = null;
    if (gx > 0 and gy > 0) {
        const r = @sqrt(@as(f64, @floatFromInt(gx * gx + gy * gy)));
        const out = @as(f64, clearance_px) / r;
        const ngx: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(gx)) * out));
        const ngy: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(gy)) * out));
        round = .{ .park_x = dog.park_x + @as(i32, @intCast(sx * (touching_px + ngx))), .park_y = dog.park_y + @as(i32, @intCast(sy * (touching_px + ngy))) };
    }
    // In order of preference on a tie: across the heading first.
    const across_first = mag(hx) >= mag(hy);
    const candidates = [_]?ParkPoint{
        round,
        if (across_first) along_y else along_x,
        if (across_first) along_x else along_y,
        if (across_first) behind_y else behind_x,
        if (across_first) behind_x else behind_y,
    };
    var best: ?ParkPoint = null;
    var best_cost: i64 = std.math.maxInt(i64);
    for (candidates) |maybe| {
        const c = maybe orelse continue;
        if (!inWorld(c)) continue;
        const cx: i64 = @as(i64, c.park_x) - cow.park_x;
        const cy: i64 = @as(i64, c.park_y) - cow.park_y;
        const cost = cx * cx + cy * cy;
        if (cost < best_cost) {
            best = c;
            best_cost = cost;
        }
    }
    return best orelse cow;
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

test "far: a dog heading straight for a cow, at 700 px it steps aside, at 701 it stays" {
    // East, 10 px a move; the cow on the path steps to the dog's right
    // (south), half as far.
    try testing.expectEqual(Reaction{ .steps_to = pt(1700, 1005) }, reaction(pt(990, 1000), pt(1000, 1000), pt(1700, 1000)));
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1701, 1000)));
}

test "far: the cone, a cow 49 degrees off the heading steps aside, one 51 degrees off stays, either side" {
    // About 400 px from the dog: (262, 302) is 49.06 degrees off east,
    // (252, 311) 50.98.
    try testing.expect(reaction(pt(990, 1000), pt(1000, 1000), pt(1000 + 262, 1000 + 302)) != .stays);
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1000 + 252, 1000 + 311)));
    try testing.expect(reaction(pt(990, 1000), pt(1000, 1000), pt(1000 + 262, 1000 - 302)) != .stays);
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1000 + 252, 1000 - 311)));
}

test "a cow behind the dog, beside it and clear, or under a dog that didn't move stays" {
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(900, 1000)));
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1000, 1100)));
    try testing.expectEqual(Reaction.stays, reaction(pt(1000, 1000), pt(1000, 1000), pt(1050, 1000)));
}

test "far: a cow steps away from the path, perpendicular to it: right of the path goes right, left goes left" {
    try testing.expectEqual(Reaction{ .steps_to = pt(1100, 1025) }, reaction(pt(990, 1000), pt(1000, 1000), pt(1100, 1020)));
    try testing.expectEqual(Reaction{ .steps_to = pt(1100, 975) }, reaction(pt(990, 1000), pt(1000, 1000), pt(1100, 980)));
    // Heading south-east, (6, 8): its right is (-8, 6), so a cow on the path
    // steps (-4, 3), half the dog's 10 px, square to its heading.
    try testing.expectEqual(Reaction{ .steps_to = pt(1060 - 4, 1080 + 3) }, reaction(pt(994, 992), pt(1000, 1000), pt(1060, 1080)));
}

test "far: half the dog's speed, half away from zero: a 1 px step moves a cow 1 px, 3 px moves it 2" {
    try testing.expectEqual(Reaction{ .steps_to = pt(1100, 1001) }, reaction(pt(999, 1000), pt(1000, 1000), pt(1100, 1000)));
    try testing.expectEqual(Reaction{ .steps_to = pt(1100, 1002) }, reaction(pt(997, 1000), pt(1000, 1000), pt(1100, 1000)));
}

test "near: the squares 20 px apart is clear; 19 px apart, the cow steps the 1 px" {
    // Dog (40 px) at (1000, 1000), cow (60 px) 70 px east: the squares'
    // edges are 20 px apart. Heading south, so the far rule leaves a cow
    // east of the path alone.
    try testing.expectEqual(pt(1070, 1000), cleared(pt(1000, 990), pt(1000, 1000), pt(1070, 1000)));
    try testing.expectEqual(pt(1070, 1000), cleared(pt(1000, 990), pt(1000, 1000), pt(1069, 1000)));
    try testing.expectEqual(pt(1000, 930), cleared(pt(990, 1000), pt(1000, 1000), pt(1000, 931)));
}

test "near: round a corner the least step is radial, rounded outward" {
    // 60 px east and 60 south: 10 px past touching on each axis, 14.1 px
    // apart corner to corner; out to 20 is 15 and 15 (14.14 rounded up).
    try testing.expectEqual(pt(1065, 1065), cleared(pt(990, 1000), pt(1000, 1000), pt(1060, 1060)));
    // 40 px apart corner to corner (gaps 24 and 32) is clear.
    try testing.expectEqual(pt(1074, 1082), cleared(pt(990, 1000), pt(1000, 1000), pt(1074, 1082)));
}

test "near: a cow dead ahead and overlapping steps across the heading, to the dog's right, not on ahead" {
    // Heading east, the cow on the dog's centre: x and y each want 70 px;
    // the tie goes across, to the right (south).
    try testing.expectEqual(pt(1000, 1070), cleared(pt(990, 1000), pt(1000, 1000), pt(1000, 1000)));
    // Heading south: its right is west.
    try testing.expectEqual(pt(930, 1000), cleared(pt(1000, 990), pt(1000, 1000), pt(1000, 1000)));
    // Overlapping, but nearer an edge on one axis: out the shorter way (the
    // cow 60 px ahead, 5 px off the line: 10 px east beats 65 px south).
    try testing.expectEqual(pt(1070, 1005), cleared(pt(990, 1000), pt(1000, 1000), pt(1060, 1005)));
}

test "near: the world's edge blocks the near way, so the cow takes the next least" {
    // Dog heading east at (4910, 2000), the cow 40 px ahead at (4950,
    // 2000): east would put its centre at 4980, past 4970 (its square out
    // of the world), so south, 70 px.
    try testing.expectEqual(pt(4950, 2070), cleared(pt(4900, 2000), pt(4910, 2000), pt(4950, 2000)));
    // At the south edge, with south blocked too: north, the other side of
    // the dog's line, 70 px (behind it, west, would be 110).
    try testing.expectEqual(pt(4950, 4890), cleared(pt(4900, 4960), pt(4910, 4960), pt(4950, 4960)));
}

test "a dog jumping 500 px between reports doesn't pass through a cow: it is clear of the dog at every tick" {
    const from = pt(800, 1000);
    const to = pt(1300, 1000);
    const end = switch (reaction(from, to, pt(1050, 1000))) {
        .steps_to => |p| p,
        .stays => return error.TheCowStayed,
    };
    try testing.expect(gapSq(to, end) >= clearance_px * clearance_px);
    // And the cow went aside, not ahead: south of the path, by at least the
    // squares' clearance.
    try testing.expect(end.park_y >= 1000 + touching_px + clearance_px);
}

/// The gap between a dog's square at `dog` and a cow's at `cow`, squared.
fn gapSq(dog: ParkPoint, cow: ParkPoint) i64 {
    const gx = @max(0, mag(@as(i64, cow.park_x) - dog.park_x) - touching_px);
    const gy = @max(0, mag(@as(i64, cow.park_y) - dog.park_y) - touching_px);
    return gx * gx + gy * gy;
}

test "random moves near a cow (seeded): the squares are never within half a dog, and the cow moves at most 1.5 times the dog" {
    var prng: std.Random.DefaultPrng = .init(0xc0ffee);
    const rand = prng.random();
    var trials: usize = 0;
    var worst_ratio: f64 = 0;
    while (trials < 20_000) {
        const dog = pt(rand.intRangeAtMost(i32, 1000, 4000), rand.intRangeAtMost(i32, 1000, 4000));
        const cow = pt(dog.park_x + rand.intRangeAtMost(i32, -200, 200), dog.park_y + rand.intRangeAtMost(i32, -200, 200));
        if (gapSq(dog, cow) < clearance_px * clearance_px) continue; // a start the rules never leave
        const to = pt(dog.park_x + rand.intRangeAtMost(i32, -80, 80), dog.park_y + rand.intRangeAtMost(i32, -80, 80));
        trials += 1;
        const end = switch (reaction(dog, to, cow)) {
            .steps_to => |p| p,
            .stays => cow,
        };
        try testing.expect(gapSq(to, end) >= clearance_px * clearance_px);
        const dog_moved = std.math.hypot(@as(f64, @floatFromInt(to.park_x - dog.park_x)), @as(f64, @floatFromInt(to.park_y - dog.park_y)));
        const cow_moved = std.math.hypot(@as(f64, @floatFromInt(end.park_x - cow.park_x)), @as(f64, @floatFromInt(end.park_y - cow.park_y)));
        if (dog_moved > 0) worst_ratio = @max(worst_ratio, cow_moved / dog_moved);
        if (cow_moved > 1.5 * dog_moved) {
            std.debug.print("dog {any} -> {any}, cow {any} -> {any}: {d:.1} px for the dog's {d:.1}\n", .{ dog, to, cow, end, cow_moved, dog_moved });
            return error.TheCowOutran;
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

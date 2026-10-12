//! The cows: one in the middle of every white tile, and scared of moving
//! dogs. **THE SERVER MOVES THEM**, as a reaction to a dog's move: a cow a
//! dog is heading for, near enough and close enough to its path, steps off
//! the path sideways, at half the dog's speed. A cow doesn't try to outrun a
//! dog; it clears the way.
//!
//! All in whole park pixels, by integer arithmetic: the same answer on every
//! host, and no rounding to argue about but the halving.

const std = @import("std");
const dogs = @import("dogs.zig");
const tiles = @import("tiles.zig");
const ParkPoint = dogs.ParkPoint;

/// A cow is known by its place in the list, made once.
pub const CowId = enum(u16) { _ };

pub const Cow = struct { at: ParkPoint };

/// How far ahead a dog scares a cow, in park pixels: a cow this far from
/// the dog, or nearer, may be scared.
pub const scare_reach_px = 300;

/// How far off the dog's heading a cow may be and still be scared: 30
/// degrees, as the test `4 * dot^2 >= 3 * |heading|^2 * |toward|^2` (cos^2
/// 30 degrees is 3/4), with the dot product positive (ahead, not behind).
pub const scare_cone_degrees = 30;

/// Where a cow stands in its tile: the middle, clear of the white tile's two
/// dogs.
const in_white: ParkPoint = .{ .park_x = tiles.tile_px / 2, .park_y = tiles.tile_px / 2 };

pub const cow_count = tiles.world_tiles * tiles.world_tiles - tiles.world_tiles * tiles.world_tiles / 2;

/// What a dog's move does to one cow.
pub const Reaction = union(enum) {
    /// Not scared: too far, off to the side, behind the dog, or the dog
    /// didn't move.
    stays,
    /// Scared: where it stepped to.
    steps_to: ParkPoint,
};

/// **THE RULE.** A dog moved from `from` to `to`; the cow at `cow` is scared
/// when it is within `scare_reach_px` of where the dog is now and within
/// `scare_cone_degrees` of the dog's heading. It steps perpendicular to the
/// heading, away from the dog's path, half as far as the dog moved (half
/// away from zero on each axis), and never out of the world. A cow on the
/// path itself steps to the dog's right.
pub fn reaction(from: ParkPoint, to: ParkPoint, cow: ParkPoint) Reaction {
    const hx: i64 = @as(i64, to.park_x) - from.park_x;
    const hy: i64 = @as(i64, to.park_y) - from.park_y;
    if (hx == 0 and hy == 0) return .stays;
    const tx: i64 = @as(i64, cow.park_x) - to.park_x;
    const ty: i64 = @as(i64, cow.park_y) - to.park_y;
    const toward_sq = tx * tx + ty * ty;
    if (toward_sq > scare_reach_px * scare_reach_px) return .stays;
    const dot = hx * tx + hy * ty;
    if (dot <= 0) return .stays;
    const heading_sq = hx * hx + hy * hy;
    if (4 * dot * dot < 3 * heading_sq * toward_sq) return .stays;
    // The dog's right, with north up and park_y growing south: heading east
    // (1, 0), its right is south (0, 1). The cow goes to whichever side of
    // the path it stands on, the right when on it.
    const right_x = -hy;
    const right_y = hx;
    const side: i64 = if (right_x * tx + right_y * ty >= 0) 1 else -1;
    const stepped = tiles.keptInWorld(.{
        .park_x = cow.park_x + @as(i32, @intCast(halved(side * right_x))),
        .park_y = cow.park_y + @as(i32, @intCast(halved(side * right_y))),
    });
    if (std.meta.eql(stepped, cow)) return .stays;
    return .{ .steps_to = stepped };
}

/// Half, rounded half away from zero: a dog's 1 px step moves a cow 1 px,
/// not 0.
fn halved(v: i64) i64 {
    return @divTrunc(v + std.math.sign(v), 2);
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
    /// it was kept, in the world.
    pub fn read(bytes: []const u8) ReadError!Cows {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const w = std.json.parseFromSliceLeaky(Written, arena.allocator(), bytes, .{}) catch return error.NotCows;
        if (w.cows.len != cow_count) return error.WrongCows;
        var c = laidOut();
        for (w.cows, &c.list, 0..) |stored, *cow, i| {
            const kept: ParkPoint = .{ .park_x = stored.park_x, .park_y = stored.park_y };
            if (stored.id != i or tiles.where(kept) == .outside_world) return error.WrongCows;
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

test "a dog heading straight for a cow: at 300 px it steps aside, at 301 it stays" {
    // East, 10 px a move; the cow on the path steps to the dog's right
    // (south), half as far.
    try testing.expectEqual(Reaction{ .steps_to = pt(1300, 1005) }, reaction(pt(990, 1000), pt(1000, 1000), pt(1300, 1000)));
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1301, 1000)));
}

test "the cone: a cow 29 degrees off the heading steps aside, one 31 degrees off stays" {
    // 200 px from the dog: cos and sin of 29 degrees are 0.8746 and 0.4848,
    // of 31 degrees 0.8572 and 0.5150.
    try testing.expect(reaction(pt(990, 1000), pt(1000, 1000), pt(1000 + 175, 1000 + 97)) != .stays);
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1000 + 171, 1000 + 103)));
    // The same on the other side of the path.
    try testing.expect(reaction(pt(990, 1000), pt(1000, 1000), pt(1000 + 175, 1000 - 97)) != .stays);
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1000 + 171, 1000 - 103)));
}

test "a cow behind the dog, beside it, or under a dog that didn't move stays" {
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(900, 1000)));
    try testing.expectEqual(Reaction.stays, reaction(pt(990, 1000), pt(1000, 1000), pt(1000, 1100)));
    try testing.expectEqual(Reaction.stays, reaction(pt(1000, 1000), pt(1000, 1000), pt(1100, 1000)));
}

test "a cow steps away from the path, perpendicular to it: right of the path goes right, left goes left" {
    // Heading east: south of the path is the dog's right.
    try testing.expectEqual(Reaction{ .steps_to = pt(1100, 1025) }, reaction(pt(990, 1000), pt(1000, 1000), pt(1100, 1020)));
    try testing.expectEqual(Reaction{ .steps_to = pt(1100, 975) }, reaction(pt(990, 1000), pt(1000, 1000), pt(1100, 980)));
    // Heading south-east, (6, 8): its right is (-8, 6), so a cow on the path
    // steps (-4, 3), half the dog's 10 px, square to its heading.
    try testing.expectEqual(Reaction{ .steps_to = pt(1060 - 4, 1080 + 3) }, reaction(pt(994, 992), pt(1000, 1000), pt(1060, 1080)));
}

test "half the dog's speed, half away from zero: a 1 px step moves a cow 1 px, 3 px moves it 2" {
    try testing.expectEqual(Reaction{ .steps_to = pt(1100, 1001) }, reaction(pt(999, 1000), pt(1000, 1000), pt(1100, 1000)));
    try testing.expectEqual(Reaction{ .steps_to = pt(1100, 1002) }, reaction(pt(997, 1000), pt(1000, 1000), pt(1100, 1000)));
    try testing.expectEqual(Reaction{ .steps_to = pt(1100, 1000 + 1000) }, reaction(pt(-1000, 1000), pt(1000, 1000), pt(1100, 1000)));
}

test "a cow at the world's edge steps along it, never out; one that cannot step stays" {
    // Heading (9, 50), its right (-50, 9): half is (-25, 5), and the south
    // edge stops the 5.
    try testing.expectEqual(Reaction{ .steps_to = pt(4974, 4999) }, reaction(pt(4990, 4900), pt(4999, 4950), pt(4999, 4995)));
    // Heading east along the south edge into the corner: its right is
    // south, out of the world, so the cow on the path cannot step.
    try testing.expectEqual(Reaction.stays, reaction(pt(4890, 4999), pt(4900, 4999), pt(4999, 4999)));
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

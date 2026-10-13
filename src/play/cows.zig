//! The cows: one in the middle of every white tile of the populated park
//! (tiles.zig), and scared of moving
//! dogs. **THE SERVER MOVES THEM**, as a reaction to a dog's move; the page
//! predicts them with this same file (cows_wasm.zig). Each critter is its
//! sprite's square (a dog `dog_px` a side, a cow `cow_px`), centred on its
//! point.
//!
//! **A POLICE CAR ON A GRID** (Steve): a dog's step is taken an axis at a
//! time, east-west then north-south, as if it went along the street, paused,
//! then went along the avenue. A dog moving along one axis scares the cows
//! AHEAD of it on that axis, within `scare_box_px` on both axes, and each
//! moves across that axis, away from the dog's line (the dog's right when on
//! it), half as far as the dog moved. Faster only when it must: a cow in the
//! dog's LANE (its square within `clearance_px` of the dog's, were the dog to
//! keep on) moves as fast as clears the lane by the time the dog gets there,
//! and at once when the dog is on it.
//!
//! **ALL IN HALF PIXELS, ALL INTEGERS**: a cow's place is counted in half
//! pixels, so half a 1 px step is one, kept exactly, on every host.
//!
//! A step that would take a cow's square out of the world is shortened,
//! never turned; a cow that cannot clear the lane on its own side goes to the
//! other when that one has room.

const std = @import("std");
const dogs = @import("dogs.zig");
const tiles = @import("tiles.zig");
const ParkPoint = dogs.ParkPoint;

/// A cow is known by its place in the list, made once.
pub const CowId = enum(u16) { _ };

/// Where a cow stands, in HALF park pixels: (half_x / 2, half_y / 2) is its
/// park point. `extern`: the page's wasm hands these over as pairs of i32.
pub const CowPoint = extern struct { half_x: i32, half_y: i32 };

/// The squares, as the page draws them (park.js's dog_px and cow_px).
pub const dog_px = 40;
pub const cow_px = 60;

/// How far a dog's move along an axis reaches: a cow at most this far ahead
/// on that axis, and at most this far off it, is scared.
pub const scare_box_px = 280;

/// The least gap a cow keeps between the dog's square and its own: half a
/// dog.
pub const clearance_px = dog_px / 2;

/// The longest tick a segment's move along an axis is played in.
pub const tick_px = 10;

/// The half-pixels in a pixel.
const halves = 2;

/// The lane's half width, centre to centre, in half pixels: the squares'
/// halves and the clearance. A cow this far off the dog's line, or farther,
/// is out of its lane; this far ahead, the dog is on it.
const lane_halves = (dog_px / 2 + cow_px / 2 + clearance_px) * halves;

/// A cow's centre keeps its whole square in the world.
const lowest = (cow_px / 2) * halves;
const highest = (tiles.world_px - cow_px / 2) * halves;

pub const cow_count = tiles.park_tiles * tiles.park_tiles - tiles.park_tiles * tiles.park_tiles / 2;

fn inWorld(at: CowPoint) bool {
    return at.half_x >= lowest and at.half_x <= highest and at.half_y >= lowest and at.half_y <= highest;
}

/// The park point a cow's square is centred on, rounded down: for its tile.
pub fn parkPoint(at: CowPoint) ParkPoint {
    return .{ .park_x = @divFloor(at.half_x, halves), .park_y = @divFloor(at.half_y, halves) };
}

const Axis = enum { x, y };

/// A cow's coordinate on an axis, and the other.
fn on(at: CowPoint, axis: Axis) i32 {
    return switch (axis) {
        .x => at.half_x,
        .y => at.half_y,
    };
}

fn across(axis: Axis) Axis {
    return switch (axis) {
        .x => .y,
        .y => .x,
    };
}

fn moved(at: CowPoint, axis: Axis, by: i32) CowPoint {
    return switch (axis) {
        .x => .{ .half_x = at.half_x + by, .half_y = at.half_y },
        .y => .{ .half_x = at.half_x, .half_y = at.half_y + by },
    };
}

/// **A MOVE, REPLAYED.** `points` is the dog's path, the first where the
/// server has the dog: every cow in `cows` reacts to each segment in turn;
/// `scared[i]` is set for each that moved. The server's /move and the
/// page's prediction both call this.
pub fn replay(cows: []CowPoint, points: []const ParkPoint, scared: ?[]bool) void {
    var k: usize = 1;
    while (k < points.len) : (k += 1) {
        const from = points[k - 1];
        const to = points[k];
        // Along the street, then along the avenue.
        const corner: ParkPoint = .{ .park_x = to.park_x, .park_y = from.park_y };
        for (cows, 0..) |*c, i| {
            const was = c.*;
            c.* = alongAxis(.x, from, corner, c.*);
            c.* = alongAxis(.y, corner, to, c.*);
            if (scared) |s| {
                if (c.half_x != was.half_x or c.half_y != was.half_y) s[i] = true;
            }
        }
    }
}

/// The dog moved along `axis` from `from` to `to` (the same on the other
/// axis): where the cow at `cow` is after it, tick by tick.
pub fn alongAxis(axis: Axis, from: ParkPoint, to: ParkPoint, cow: CowPoint) CowPoint {
    const start = dogOn(from, axis);
    const travel = dogOn(to, axis) - start;
    if (travel == 0) return cow;
    const ticks = std.math.divCeil(i32, mag(travel), tick_px) catch unreachable;
    var at = cow;
    var k: i32 = 1;
    var done: i32 = 0;
    while (k <= ticks) : (k += 1) {
        const now = @divTrunc(travel * k, ticks);
        const dog = moved(halvesOf(from), axis, now * halves);
        at = scooted(axis, std.math.sign(travel), mag(now - done), dog, at);
        done = now;
    }
    return at;
}

fn dogOn(p: ParkPoint, axis: Axis) i32 {
    return switch (axis) {
        .x => p.park_x,
        .y => p.park_y,
    };
}

/// A dog's park point in half pixels.
fn halvesOf(p: ParkPoint) CowPoint {
    return .{ .half_x = p.park_x * halves, .half_y = p.park_y * halves };
}

/// **ONE TICK.** The dog, its centre at `dog` (half pixels), moved `step` px
/// along `axis`, that way (`way`, 1 or -1); where the cow at `cow` is after
/// it.
fn scooted(axis: Axis, way: i32, step: i32, dog: CowPoint, cow: CowPoint) CowPoint {
    const ahead = (on(cow, axis) - on(dog, axis)) * way;
    const off = on(cow, across(axis)) - on(dog, across(axis));
    if (ahead <= 0 or ahead > scare_box_px * halves or mag(off) > scare_box_px * halves) return cow;
    // Away from the dog's line; on it, to the dog's right (east's right is
    // south, north's is east: with y growing south, (x, y)'s right is
    // (-y, x)).
    var side: i32 = if (off != 0) std.math.sign(off) else switch (axis) {
        .x => way,
        .y => -way,
    };
    // Half as far as the dog: a half pixel for each of its pixels.
    var by: i32 = step;
    if (mag(off) < lane_halves) {
        // In the lane: how far across it must go to be out, and how far the
        // dog has to come before it is on the cow.
        var out = lane_halves - mag(off);
        if (room(cow, across(axis), side) < out) {
            const other = lane_halves + mag(off);
            if (room(cow, across(axis), -side) >= other) {
                side = -side;
                out = other;
            }
        }
        // The dog comes `step * halves` this tick; at that pace, as much as
        // is out by the time it gets there; never less than half speed.
        const left_to_come = ahead - lane_halves;
        const needed = if (left_to_come <= 0) out else std.math.divCeil(i32, out * step * halves, left_to_come) catch unreachable;
        by = @max(step, @min(out, needed));
    }
    by = @min(by, room(cow, across(axis), side));
    if (by <= 0) return cow;
    return moved(cow, across(axis), side * by);
}

/// How far the cow at `cow` can go along `axis`, to `side`, before its square
/// leaves the world, in half pixels.
fn room(cow: CowPoint, axis: Axis, side: i32) i32 {
    return @max(0, if (side > 0) highest - on(cow, axis) else on(cow, axis) - lowest);
}

/// The size of `v`.
fn mag(v: i32) i32 {
    return if (v < 0) -v else v;
}

/// How the cows are written down, in half pixels:
/// `{"cows":[{"id","half_x","half_y"}, ...]}`.
const Written = struct { cows: []const struct { id: u32, half_x: i32, half_y: i32 } };

pub const Cows = struct {
    list: [cow_count]CowPoint,

    /// One cow in the middle of every white tile of the populated park (a
    /// tile is white when its column plus its row is even), row by row.
    pub fn laidOut() Cows {
        var c: Cows = undefined;
        var n: usize = 0;
        var row: i32 = 0;
        while (row < tiles.park_tiles) : (row += 1) {
            var col: i32 = 0;
            while (col < tiles.park_tiles) : (col += 1) {
                if (@mod(col + row, 2) == 1) continue;
                c.list[n] = halvesOf(.{
                    .park_x = tiles.park_offset_px + col * tiles.tile_px + tiles.tile_px / 2,
                    .park_y = tiles.park_offset_px + row * tiles.tile_px + tiles.tile_px / 2,
                });
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
            const kept: CowPoint = .{ .half_x = stored.half_x, .half_y = stored.half_y };
            if (stored.id != i or !inWorld(kept)) return error.WrongCows;
            cow.* = kept;
        }
        return c;
    }

    pub fn written(self: *const Cows, alloc: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        try out.writer.writeAll("{\"cows\":[");
        for (self.list, 0..) |cow, i| {
            if (i > 0) try out.writer.writeAll(",");
            try out.writer.print("\n{{\"id\":{d},\"half_x\":{d},\"half_y\":{d}}}", .{ i, cow.half_x, cow.half_y });
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

/// A cow at (x, y) in half pixels.
fn h(x: i32, y: i32) CowPoint {
    return .{ .half_x = x, .half_y = y };
}

/// One segment of a path, for one cow.
fn after(from: ParkPoint, to: ParkPoint, cow: CowPoint) CowPoint {
    var c = [_]CowPoint{cow};
    replay(&c, &.{ from, to }, null);
    return c[0];
}

test "the first layout: 50 cows, one in the middle of each white tile of the park, 13,500 px in, in half pixels" {
    const c = Cows.laidOut();
    try testing.expectEqual(@as(usize, 50), cow_count);
    try testing.expectEqual(h(27_500, 27_500), c.at(@enumFromInt(0)));
    try testing.expectEqual(h(29_500, 27_500), c.at(@enumFromInt(1)));
    try testing.expectEqual(h(28_500, 28_500), c.at(@enumFromInt(5)));
    try testing.expectEqual(pt(13_750, 13_750), parkPoint(c.at(@enumFromInt(0))));
    try testing.expectEqual(tiles.Tile{ .col = 36, .row = 36 }, tiles.Tile.of(parkPoint(c.at(@enumFromInt(cow_count - 1)))));
}

test "a dog moving 2 px north moves a cow ahead of it 1 px east or west, away from its line" {
    // The cow 300 px north, 100 px east of the dog's line (half pixels
    // double): east, by 2 half pixels.
    try testing.expectEqual(h(2202, 1400), after(pt(1000, 1000), pt(1000, 998), h(2200, 1400)));
    try testing.expectEqual(h(1798, 1400), after(pt(1000, 1000), pt(1000, 998), h(1800, 1400)));
    // A 1 px step: one half pixel.
    try testing.expectEqual(h(2201, 1400), after(pt(1000, 1000), pt(1000, 999), h(2200, 1400)));
    // Moving east 2 px, a cow ahead and north of the line goes north 1 px.
    try testing.expectEqual(h(2600, 1798), after(pt(1000, 1000), pt(1002, 1000), h(2600, 1800)));
}

test "on the dog's line, the cow goes to the dog's right: east's is south, west's north, north's east, south's west" {
    try testing.expectEqual(h(2600, 2002), after(pt(1000, 1000), pt(1002, 1000), h(2600, 2000)));
    try testing.expectEqual(h(1400, 1998), after(pt(1000, 1000), pt(998, 1000), h(1400, 2000)));
    try testing.expectEqual(h(2002, 1400), after(pt(1000, 1000), pt(1000, 998), h(2000, 1400)));
    try testing.expectEqual(h(1998, 2600), after(pt(1000, 1000), pt(1000, 1002), h(2000, 2600)));
}

test "ahead only, and in the box: 400 px ahead and 400 off moves; 401 either way, or behind, stays" {
    // The dog ends at x 1002: 400 px ahead is half x 2804.
    try testing.expectEqual(h(2804, 1798), after(pt(1000, 1000), pt(1002, 1000), h(2804, 1800)));
    try testing.expectEqual(h(2806, 1800), after(pt(1000, 1000), pt(1002, 1000), h(2806, 1800)));
    // 400 px off the line (half y 1200) moves, 401 stays.
    try testing.expectEqual(h(2600, 1198), after(pt(1000, 1000), pt(1002, 1000), h(2600, 1200)));
    try testing.expectEqual(h(2600, 1198), after(pt(1000, 1000), pt(1002, 1000), h(2600, 1198)));
    // Behind: stays.
    try testing.expectEqual(h(1800, 1800), after(pt(1000, 1000), pt(1002, 1000), h(1800, 1800)));
}

test "a diagonal step is the step along x, a pause, then the step along y" {
    const cow = h(2300, 1500);
    const corner = after(pt(1000, 1000), pt(1004, 1000), cow);
    try testing.expectEqual(after(pt(1004, 1000), pt(1004, 1006), corner), after(pt(1000, 1000), pt(1004, 1006), cow));
    // Here: east 4 (the cow ahead, north of the line): north 2 px; then
    // south 6 (the cow behind on y): nothing.
    try testing.expectEqual(h(2300, 1496), after(pt(1000, 1000), pt(1004, 1006), cow));
}

test "in the lane: half speed while there is time; as fast as clears it by the time the dog arrives; at once when it is there" {
    // East, the cow on the line 300 px ahead: 230 px to come, 70 to clear:
    // half speed is enough.
    try testing.expectEqual(h(2600, 2002), after(pt(998, 1000), pt(1000, 1000), h(2600, 2000)));
    // 100 px ahead: 30 px to come, 70 to clear, the dog 10 px a tick: 140
    // half pixels in 3 ticks' worth, 47 this tick (rounded up).
    try testing.expectEqual(h(2200, 2000 + 47), after(pt(990, 1000), pt(1000, 1000), h(2200, 2000)));
    // 70 px ahead: the dog is on it; all 140 half pixels now.
    try testing.expectEqual(h(2140, 2140), after(pt(990, 1000), pt(1000, 1000), h(2140, 2000)));
    // 30 px north of the line, 70 ahead: 40 px to clear, north.
    try testing.expectEqual(h(2140, 1940 - 80), after(pt(990, 1000), pt(1000, 1000), h(2140, 1940)));
}

test "the world's edge: no room to clear on the cow's side, the other side; no room to scoot, a shorter step or none" {
    // The east wall is the world's, at 32,000 px.
    const wall = tiles.world_px;
    try testing.expectEqual(@as(i32, 32_000), wall);
    // Heading north 50 px from the wall, the cow 10 px east of the line, 70
    // px ahead (the dog on it): east it has 10 px and needs 60; west, 80,
    // all now.
    try testing.expectEqual(h(2 * (wall - 40) - 160, 1860), after(pt(wall - 50, 1010), pt(wall - 50, 1000), h(2 * (wall - 40), 1860)));
    // Heading north, the cow 2 px from the east wall, ahead and well off
    // the line: 2 of its 5 px.
    try testing.expectEqual(h(highest, 1600), after(pt(wall - 400, 1010), pt(wall - 400, 1000), h(highest - 4, 1600)));
    // Against the wall already: none.
    try testing.expectEqual(h(highest, 1600), after(pt(wall - 400, 1010), pt(wall - 400, 1000), h(highest, 1600)));
}

test "a dog jumping 500 px between reports doesn't pass through a cow: it clears the lane, never moves ahead" {
    const end = after(pt(800, 1000), pt(1300, 1000), h(2100, 2000));
    try testing.expectEqual(@as(i32, 2100), end.half_x);
    try testing.expect(end.half_y >= 2000 + lane_halves);
}

test "random paths near a cow (seeded): the squares never come within half a dog, and each move is across one axis" {
    var prng: std.Random.DefaultPrng = .init(0xc0ffee);
    const rand = prng.random();
    var trials: usize = 0;
    while (trials < 20_000) {
        var dog = pt(rand.intRangeAtMost(i32, 1000, 4000), rand.intRangeAtMost(i32, 1000, 4000));
        var cow = halvesOf(.{ .park_x = dog.park_x + rand.intRangeAtMost(i32, -200, 200), .park_y = dog.park_y + rand.intRangeAtMost(i32, -200, 200) });
        cow.half_x += rand.intRangeAtMost(i32, 0, 1);
        // Out of each other's lanes on at least one axis: a start the rule
        // never leaves.
        if (@max(mag(cow.half_x - dog.park_x * halves), mag(cow.half_y - dog.park_y * halves)) < lane_halves) continue;
        trials += 1;
        for (0..10) |_| {
            const to = pt(dog.park_x + rand.intRangeAtMost(i32, -15, 15), dog.park_y + rand.intRangeAtMost(i32, -15, 15));
            const corner = pt(to.park_x, dog.park_y);
            const mid = after(dog, corner, cow);
            // Across the axis moved along: x moves y, y moves x.
            try testing.expectEqual(cow.half_x, mid.half_x);
            const end = after(corner, to, mid);
            try testing.expectEqual(mid.half_y, end.half_y);
            try testing.expect(@max(mag(end.half_x - to.park_x * halves), mag(end.half_y - to.park_y * halves)) >= lane_halves);
            dog = to;
            cow = end;
        }
    }
}

test "a replayed move scares every cow ahead of it, and only those, and says which" {
    var c = Cows.laidOut();
    var scared = [_]bool{false} ** cow_count;
    // East along the park's row 250 from its (0, 250): cow 0 at its (250,
    // 250) is 250 px ahead; cow 1 at its (1250, 250) too far.
    const o = tiles.park_offset_px;
    replay(&c.list, &.{ pt(o, o + 250), pt(o + 10, o + 250) }, &scared);
    try testing.expect(scared[0] and !scared[1]);
    try testing.expectEqual(h(2 * o + 500, 2 * o + 510), c.at(@enumFromInt(0)));
}

test "cows written read back the same; a cow outside the world, missing or out of order does not read" {
    var c = Cows.laidOut();
    c.list[0] = h(501, 511);
    const bytes = try c.written(testing.allocator);
    defer testing.allocator.free(bytes);
    const back = try Cows.read(bytes);
    try testing.expectEqual(h(501, 511), back.at(@enumFromInt(0)));
    try testing.expectError(error.NotCows, Cows.read("not json"));
    try testing.expectError(error.WrongCows, Cows.read("{\"cows\":[]}"));
    const outside = try std.mem.replaceOwned(u8, testing.allocator, bytes, "\"half_x\":501,", "\"half_x\":59,");
    defer testing.allocator.free(outside);
    try testing.expectError(error.WrongCows, Cows.read(outside));
    const swapped = try std.mem.replaceOwned(u8, testing.allocator, bytes, "{\"id\":0,", "{\"id\":1,");
    defer testing.allocator.free(swapped);
    try testing.expectError(error.WrongCows, Cows.read(swapped));
}

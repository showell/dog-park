//! The world as a checkerboard of square tiles, `tile_px` a side, each named
//! by its column and row; the populated park within it; and the tiles a
//! human has subscribed to (at most `most_subscribed`), which the human
//! chooses.

const std = @import("std");
const dogs = @import("dogs.zig");

pub const tile_px = 500;
/// The most tiles a page holds at once: 8 x 8, the display's tiles on a
/// large screen with the leash's region partly off it (docs/PHYSICS.md).
pub const most_subscribed = 64;
/// The world is `world_tiles` by `world_tiles` tiles, from tile (0, 0): park
/// points 0 to `world_px` - 1 on each axis. Its edges clamp (a torus later).
pub const world_tiles = 64;
pub const world_px = world_tiles * tile_px;
/// **THE POPULATED PARK**: `park_tiles` by `park_tiles` tiles, its dogs and
/// cows laid out in them (dogs.zig, cows.zig), its top-left corner
/// `park_offset_px` in from the world's on each axis, so its middle is the
/// world's. The rest of the world is empty ground.
pub const park_tiles = 10;
pub const park_offset_px = (world_tiles - park_tiles) / 2 * tile_px;

/// Whether a park point is in the world.
pub const Where = enum { in_world, outside_world };

pub fn where(at: dogs.ParkPoint) Where {
    const in = at.park_x >= 0 and at.park_x < world_px and at.park_y >= 0 and at.park_y < world_px;
    return if (in) .in_world else .outside_world;
}

/// A park point kept in the world: each axis clamped to it.
pub fn keptInWorld(at: dogs.ParkPoint) dogs.ParkPoint {
    return .{ .park_x = std.math.clamp(at.park_x, 0, world_px - 1), .park_y = std.math.clamp(at.park_y, 0, world_px - 1) };
}

pub const Tile = struct {
    col: i32,
    row: i32,

    /// The tile a park point stands in: tile (0, 0) holds 0 to 499 on each
    /// axis, tile (-1, 0) holds park_x -500 to -1.
    pub fn of(at: dogs.ParkPoint) Tile {
        return .{ .col = @divFloor(at.park_x, tile_px), .row = @divFloor(at.park_y, tile_px) };
    }
};

/// A tile as a page names it when it subscribes: one it has the dogs of
/// already (`held`), or one whose dogs it wants sent (`new`).
pub const Named = struct {
    col: i32,
    row: i32,
    is: enum { new, held },

    pub fn tile(self: Named) Tile {
        return .{ .col = self.col, .row = self.row };
    }
};

/// What a subscription came to.
pub const Subscribing = union(enum) {
    /// Done: the set is the tiles named.
    replaced,
    /// Refused, and nothing changed: more than `most_subscribed` tiles named.
    too_many: usize,
    /// Refused, and nothing changed: a tile named is outside the world.
    outside_world: Tile,
};

pub const Subscribed = struct {
    tiles: [most_subscribed]Tile = undefined,
    len: usize = 0,

    pub fn holds(self: *const Subscribed, t: Tile) bool {
        for (self.tiles[0..self.len]) |held| if (std.meta.eql(held, t)) return true;
        return false;
    }

    /// **THE WHOLE SET, EVERY TIME**: the tiles named replace those held, so
    /// a lost answer can't leave the page and the server apart. A tile named
    /// twice is held once.
    pub fn replace(self: *Subscribed, named: []const Named) Subscribing {
        var next: Subscribed = .{};
        for (named) |n| {
            const t = n.tile();
            if (where(.{ .park_x = t.col * tile_px, .park_y = t.row * tile_px }) == .outside_world) return .{ .outside_world = t };
            if (next.holds(t)) continue;
            if (next.len == most_subscribed) return .{ .too_many = named.len };
            next.tiles[next.len] = t;
            next.len += 1;
        }
        self.* = next;
        return .replaced;
    }
};

const testing = std.testing;

test "a tile's edges: 499 is the last of tile 0, 500 the first of tile 1; -1 is tile -1, 0 tile 0; -500 is tile -1, -501 tile -2" {
    try testing.expectEqual(@as(i32, 0), Tile.of(.{ .park_x = 499, .park_y = 0 }).col);
    try testing.expectEqual(@as(i32, 1), Tile.of(.{ .park_x = 500, .park_y = 0 }).col);
    try testing.expectEqual(@as(i32, -1), Tile.of(.{ .park_x = -1, .park_y = 0 }).col);
    try testing.expectEqual(@as(i32, 0), Tile.of(.{ .park_x = 0, .park_y = 0 }).col);
    try testing.expectEqual(@as(i32, -1), Tile.of(.{ .park_x = 0, .park_y = -500 }).row);
    try testing.expectEqual(@as(i32, -2), Tile.of(.{ .park_x = 0, .park_y = -501 }).row);
}

fn namedTiles(n: usize, is: @FieldType(Named, "is")) [most_subscribed + 1]Named {
    var out: [most_subscribed + 1]Named = undefined;
    for (out[0..n], 0..) |*t, i| t.* = .{ .col = @intCast(i % world_tiles), .row = @intCast(i / world_tiles), .is = is };
    return out;
}

test "subscriptions: 64 tiles named is the most; 65 is refused whole, and what was held stands" {
    try testing.expectEqual(@as(usize, 64), most_subscribed);
    const most = most_subscribed;
    var s: Subscribed = .{};
    const first = namedTiles(most, .new);
    try testing.expectEqual(Subscribing.replaced, s.replace(first[0..most]));
    try testing.expectEqual(@as(usize, most), s.len);
    var more = namedTiles(most + 1, .held);
    more[most] = .{ .col = world_tiles - 1, .row = world_tiles - 1, .is = .new };
    try testing.expectEqual(Subscribing{ .too_many = most + 1 }, s.replace(more[0 .. most + 1]));
    try testing.expectEqual(@as(usize, most), s.len);
    try testing.expect(!s.holds(.{ .col = world_tiles - 1, .row = world_tiles - 1 }));
}

test "the world is 64 x 64 tiles, 32,000 px a side; the park, 10 x 10, sits 13,500 px in on each axis, its middle the world's" {
    try testing.expectEqual(@as(i32, 64), world_tiles);
    try testing.expectEqual(@as(i32, 32_000), world_px);
    try testing.expectEqual(@as(i32, 10), park_tiles);
    try testing.expectEqual(@as(i32, 13_500), park_offset_px);
    try testing.expectEqual(@as(i32, 0), @mod(park_offset_px, tile_px));
    try testing.expectEqual(world_px, 2 * park_offset_px + park_tiles * tile_px);
}

test "the world's edges: 0 and 31999 are in it, -1 and 32000 outside; a tile past them is refused" {
    try testing.expectEqual(Where.in_world, where(.{ .park_x = 0, .park_y = 31_999 }));
    try testing.expectEqual(Where.outside_world, where(.{ .park_x = -1, .park_y = 0 }));
    try testing.expectEqual(Where.in_world, where(.{ .park_x = 31_999, .park_y = 0 }));
    try testing.expectEqual(Where.outside_world, where(.{ .park_x = 0, .park_y = 32_000 }));
    var s: Subscribed = .{};
    try testing.expectEqual(Subscribing.replaced, s.replace(&.{.{ .col = 63, .row = 63, .is = .new }}));
    try testing.expectEqual(Subscribing{ .outside_world = .{ .col = 64, .row = 63 } }, s.replace(&.{.{ .col = 64, .row = 63, .is = .new }}));
}

test "a subscription replaces the set: a tile left out is dropped, one named twice is held once" {
    var s: Subscribed = .{};
    _ = s.replace(&.{ .{ .col = 1, .row = 1, .is = .new }, .{ .col = 2, .row = 2, .is = .new } });
    try testing.expectEqual(Subscribing.replaced, s.replace(&.{ .{ .col = 2, .row = 2, .is = .held }, .{ .col = 2, .row = 2, .is = .held } }));
    try testing.expectEqual(@as(usize, 1), s.len);
    try testing.expect(!s.holds(.{ .col = 1, .row = 1 }));
}

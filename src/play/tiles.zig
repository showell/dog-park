//! The park as a checkerboard of square tiles, `tile_px` a side, each named
//! by its column and row; and the tiles a human has subscribed to (at most
//! `most_subscribed`), which the human chooses.

const std = @import("std");
const dogs = @import("dogs.zig");

pub const tile_px = 800;
pub const most_subscribed = 25;
/// The world is `world_tiles` by `world_tiles` tiles, from tile (0, 0): park
/// points 0 to `world_px` - 1 on each axis.
pub const world_tiles = 10;
pub const world_px = world_tiles * tile_px;

/// Whether a park point is in the world.
pub const Where = enum { in_world, outside_world };

pub fn where(at: dogs.ParkPoint) Where {
    const in = at.park_x >= 0 and at.park_x < world_px and at.park_y >= 0 and at.park_y < world_px;
    return if (in) .in_world else .outside_world;
}

pub const Tile = struct {
    col: i32,
    row: i32,

    /// The tile a park point stands in: tile (0, 0) holds 0 to 799 on each
    /// axis, tile (-1, 0) holds park_x -800 to -1.
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

test "a tile's edges: 799 is the last of tile 0, 800 the first of tile 1; -1 is tile -1, 0 tile 0; -800 is tile -1, -801 tile -2" {
    try testing.expectEqual(@as(i32, 0), Tile.of(.{ .park_x = 799, .park_y = 0 }).col);
    try testing.expectEqual(@as(i32, 1), Tile.of(.{ .park_x = 800, .park_y = 0 }).col);
    try testing.expectEqual(@as(i32, -1), Tile.of(.{ .park_x = -1, .park_y = 0 }).col);
    try testing.expectEqual(@as(i32, 0), Tile.of(.{ .park_x = 0, .park_y = 0 }).col);
    try testing.expectEqual(@as(i32, -1), Tile.of(.{ .park_x = 0, .park_y = -800 }).row);
    try testing.expectEqual(@as(i32, -2), Tile.of(.{ .park_x = 0, .park_y = -801 }).row);
}

fn namedTiles(n: usize, is: @FieldType(Named, "is")) [most_subscribed + 1]Named {
    var out: [most_subscribed + 1]Named = undefined;
    for (out[0..n], 0..) |*t, i| t.* = .{ .col = @intCast(i % world_tiles), .row = @intCast(i / world_tiles), .is = is };
    return out;
}

test "subscriptions: 25 tiles named is the most; 26 is refused whole, and what was held stands" {
    var s: Subscribed = .{};
    const first = namedTiles(25, .new);
    try testing.expectEqual(Subscribing.replaced, s.replace(first[0..25]));
    try testing.expectEqual(@as(usize, 25), s.len);
    var more = namedTiles(26, .held);
    more[25] = .{ .col = 9, .row = 9, .is = .new };
    try testing.expectEqual(Subscribing{ .too_many = 26 }, s.replace(more[0..26]));
    try testing.expectEqual(@as(usize, 25), s.len);
    try testing.expect(!s.holds(.{ .col = 9, .row = 9 }));
}

test "the world's edges: 0 and 7999 are in it, -1 and 8000 outside; a tile past them is refused" {
    try testing.expectEqual(Where.in_world, where(.{ .park_x = 0, .park_y = 7999 }));
    try testing.expectEqual(Where.outside_world, where(.{ .park_x = -1, .park_y = 0 }));
    try testing.expectEqual(Where.in_world, where(.{ .park_x = 7999, .park_y = 0 }));
    try testing.expectEqual(Where.outside_world, where(.{ .park_x = 0, .park_y = 8000 }));
    var s: Subscribed = .{};
    try testing.expectEqual(Subscribing.replaced, s.replace(&.{.{ .col = 9, .row = 9, .is = .new }}));
    try testing.expectEqual(Subscribing{ .outside_world = .{ .col = 10, .row = 9 } }, s.replace(&.{.{ .col = 10, .row = 9, .is = .new }}));
}

test "a subscription replaces the set: a tile left out is dropped, one named twice is held once" {
    var s: Subscribed = .{};
    _ = s.replace(&.{ .{ .col = 1, .row = 1, .is = .new }, .{ .col = 2, .row = 2, .is = .new } });
    try testing.expectEqual(Subscribing.replaced, s.replace(&.{ .{ .col = 2, .row = 2, .is = .held }, .{ .col = 2, .row = 2, .is = .held } }));
    try testing.expectEqual(@as(usize, 1), s.len);
    try testing.expect(!s.holds(.{ .col = 1, .row = 1 }));
}

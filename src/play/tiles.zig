//! The world as a checkerboard of square tiles, `tile_px` a side, each named
//! by its column and row; the populated park within it; and the most tiles
//! a page holds at once.

const std = @import("std");
const world = @import("world.zig").world;

/// The world's numbers are world.zig's (roc/print_world.roc says them).
pub const tile_px: comptime_int = world.tile_px;
/// The most tiles a page holds at once: 8 x 8, the display's tiles on a
/// large screen with the leash's region partly off it (docs/PHYSICS.md).
pub const most_subscribed = 64;
/// **THE ROOM**: the largest level's world, `room_tiles` by `room_tiles`
/// tiles, which sizes the arrays. A board's own world, its park and its
/// torus are its level's (physics.zig's `Geometry`).
pub const room_tiles: comptime_int = world.world_tiles;

pub const Tile = struct {
    col: i32,
    row: i32,

    /// The tile a park point (whole pixels) stands in: tile (0, 0) holds 0
    /// to 349 on each axis, tile (-1, 0) holds -350 to -1.
    pub fn of(park_x: i32, park_y: i32) Tile {
        return .{ .col = @divFloor(park_x, tile_px), .row = @divFloor(park_y, tile_px) };
    }
    /// The same tile named in a world `n` tiles a side, [0, `n`) on each
    /// axis: column `n` is column 0, column -1 is column `n` - 1.
    pub fn wrapped(t: Tile, n: i32) Tile {
        return .{ .col = @mod(t.col, n), .row = @mod(t.row, n) };
    }
};

const testing = std.testing;

test "a tile's edges: 349 is the last of tile 0, 350 the first of tile 1; -1 is tile -1, 0 tile 0; -350 is tile -1, -351 tile -2" {
    try testing.expectEqual(@as(i32, 0), Tile.of(tile_px - 1, 0).col);
    try testing.expectEqual(@as(i32, 1), Tile.of(tile_px, 0).col);
    try testing.expectEqual(@as(i32, -1), Tile.of(-1, 0).col);
    try testing.expectEqual(@as(i32, 0), Tile.of(0, 0).col);
    try testing.expectEqual(@as(i32, -1), Tile.of(0, -tile_px).row);
    try testing.expectEqual(@as(i32, -2), Tile.of(0, -tile_px - 1).row);
}

test "a tile wraps into the world: its side is 0, -1 is the last, the last stays" {
    try testing.expectEqual(Tile{ .col = 0, .row = room_tiles - 1 }, (Tile{ .col = room_tiles, .row = -1 }).wrapped(room_tiles));
    try testing.expectEqual(Tile{ .col = room_tiles - 1, .row = 0 }, (Tile{ .col = room_tiles - 1, .row = 0 }).wrapped(room_tiles));
    try testing.expectEqual(Tile{ .col = 0, .row = 3 }, (Tile{ .col = 4, .row = -1 }).wrapped(4));
}

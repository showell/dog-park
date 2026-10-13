//! The world as a checkerboard of square tiles, `tile_px` a side, each named
//! by its column and row; the populated park within it; and the most tiles
//! a page holds at once.

const std = @import("std");

pub const tile_px = 500;
/// The most tiles a page holds at once: 8 x 8, the display's tiles on a
/// large screen with the leash's region partly off it (docs/PHYSICS.md).
pub const most_subscribed = 64;
/// The world is `world_tiles` by `world_tiles` tiles, from tile (0, 0): park
/// points 0 to `world_px` - 1 on each axis. Its edges clamp (a torus later).
pub const world_tiles = 64;
pub const world_px = world_tiles * tile_px;
/// **THE POPULATED PARK**: `park_tiles` by `park_tiles` tiles, its dogs and
/// cows laid out in them (layout.zig), its top-left corner
/// `park_offset_px` in from the world's on each axis, so its middle is the
/// world's. The rest of the world is empty ground.
pub const park_tiles = 10;
pub const park_offset_px = (world_tiles - park_tiles) / 2 * tile_px;

pub const Tile = struct {
    col: i32,
    row: i32,

    /// The tile a park point (whole pixels) stands in: tile (0, 0) holds 0
    /// to 499 on each axis, tile (-1, 0) holds -500 to -1.
    pub fn of(park_x: i32, park_y: i32) Tile {
        return .{ .col = @divFloor(park_x, tile_px), .row = @divFloor(park_y, tile_px) };
    }
};

const testing = std.testing;

test "a tile's edges: 499 is the last of tile 0, 500 the first of tile 1; -1 is tile -1, 0 tile 0; -500 is tile -1, -501 tile -2" {
    try testing.expectEqual(@as(i32, 0), Tile.of(499, 0).col);
    try testing.expectEqual(@as(i32, 1), Tile.of(500, 0).col);
    try testing.expectEqual(@as(i32, -1), Tile.of(-1, 0).col);
    try testing.expectEqual(@as(i32, 0), Tile.of(0, 0).col);
    try testing.expectEqual(@as(i32, -1), Tile.of(0, -500).row);
    try testing.expectEqual(@as(i32, -2), Tile.of(0, -501).row);
}

test "the park sits a whole number of tiles in from the world's edge, its middle the world's" {
    try testing.expectEqual(@as(i32, 0), @mod(park_offset_px, tile_px));
    try testing.expectEqual(world_px, 2 * park_offset_px + park_tiles * tile_px);
    try testing.expect(park_tiles <= world_tiles);
}

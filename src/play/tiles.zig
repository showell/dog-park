//! The world as a checkerboard of square tiles, `tile_px` a side, each named
//! by its column and row; the populated park within it; and the most tiles
//! a page holds at once.

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

pub const Tile = struct {
    col: i32,
    row: i32,

    /// The tile a park point stands in: tile (0, 0) holds 0 to 499 on each
    /// axis, tile (-1, 0) holds park_x -500 to -1.
    pub fn of(at: dogs.ParkPoint) Tile {
        return .{ .col = @divFloor(at.park_x, tile_px), .row = @divFloor(at.park_y, tile_px) };
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

test "the world is 64 x 64 tiles, 32,000 px a side; the park, 10 x 10, sits 13,500 px in on each axis, its middle the world's" {
    try testing.expectEqual(@as(i32, 64), world_tiles);
    try testing.expectEqual(@as(i32, 32_000), world_px);
    try testing.expectEqual(@as(i32, 10), park_tiles);
    try testing.expectEqual(@as(i32, 13_500), park_offset_px);
    try testing.expectEqual(@as(i32, 0), @mod(park_offset_px, tile_px));
    try testing.expectEqual(world_px, 2 * park_offset_px + park_tiles * tile_px);
}

test "the world's edges: 0 and 31999 are in it, -1 and 32000 outside" {
    try testing.expectEqual(Where.in_world, where(.{ .park_x = 0, .park_y = 31_999 }));
    try testing.expectEqual(Where.outside_world, where(.{ .park_x = -1, .park_y = 0 }));
    try testing.expectEqual(Where.in_world, where(.{ .park_x = 31_999, .park_y = 0 }));
    try testing.expectEqual(Where.outside_world, where(.{ .park_x = 0, .park_y = 32_000 }));
}

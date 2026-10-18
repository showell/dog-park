//! The world as a checkerboard of square tiles, `tile_px` a side, each named
//! by its column and row; the populated park within it; and the most tiles
//! a page holds at once.

const std = @import("std");
const world = @import("world.zig").world;

/// The world's numbers are world.zig's (roc/world.roc says them).
pub const tile_px: comptime_int = world.tile_px;
/// The most tiles a page holds at once: 8 x 8, the display's tiles on a
/// large screen with the leash's region partly off it (docs/PHYSICS.md).
pub const most_subscribed = 64;
/// The world is `world_tiles` by `world_tiles` tiles, from tile (0, 0): park
/// points 0 to `world_px` - 1 on each axis. A torus: tile `world_tiles` is
/// tile 0 again, tile -1 the last (`wrapped`).
pub const world_tiles: comptime_int = world.world_tiles;
pub const world_px = world_tiles * tile_px;
/// **THE POPULATED PARK**: `park_tiles` by `park_tiles` tiles, its critters
/// laid out in them (layout.zig), its top-left corner `park_offset_px` in
/// from the world's on each axis, so its middle is the world's. The rest of
/// the world is empty ground.
pub const park_tiles: comptime_int = world.park.tiles;
pub const park_offset_px: comptime_int = world.park.first * tile_px;
comptime {
    if (world.park.first + world.park.tiles > world_tiles) @compileError("world.zon: the park runs past the world's edge");
}

pub const Tile = struct {
    col: i32,
    row: i32,

    /// The tile a park point (whole pixels) stands in: tile (0, 0) holds 0
    /// to 349 on each axis, tile (-1, 0) holds -350 to -1.
    pub fn of(park_x: i32, park_y: i32) Tile {
        return .{ .col = @divFloor(park_x, tile_px), .row = @divFloor(park_y, tile_px) };
    }
    /// The same tile named in the world, [0, `world_tiles`) on each axis:
    /// column 64 is column 0, column -1 is column 63.
    pub fn wrapped(t: Tile) Tile {
        return .{ .col = @mod(t.col, world_tiles), .row = @mod(t.row, world_tiles) };
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

test "a tile wraps into the world: world_tiles is 0, -1 is the last, the last stays" {
    try testing.expectEqual(Tile{ .col = 0, .row = world_tiles - 1 }, (Tile{ .col = world_tiles, .row = -1 }).wrapped());
    try testing.expectEqual(Tile{ .col = world_tiles - 1, .row = 0 }, (Tile{ .col = world_tiles - 1, .row = 0 }).wrapped());
}

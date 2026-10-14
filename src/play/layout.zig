//! **THE FIRST LAYOUT**, in 256ths: where every critter stands when the park
//! starts afresh (the server's first start, and every load). In every tile
//! of the populated park (tiles.zig), four dogs, one of each breed, each
//! near its own corner of the tile: breed 0 north-west, 1 north-east, 2
//! south-west, 3 south-east, so a tile's four dogs are numbered 4k to
//! 4k + 3, tile by tile, row by row. White tiles (column plus row even)
//! also hold a cow in the middle, row by row; blue tiles (column plus row
//! odd) two chickens side by side in the middle, row by row (decision 26).

const std = @import("std");
const tiles = @import("tiles.zig");
const physics = @import("physics.zig");
const px = physics.px;

/// How far in from its corner of the tile a dog stands, on each axis.
pub const corner_in = 75;

pub const dog_count = tiles.park_tiles * tiles.park_tiles * 4;
pub const cow_count = tiles.park_tiles * tiles.park_tiles - tiles.park_tiles * tiles.park_tiles / 2;
pub const chicken_count = 2 * (tiles.park_tiles * tiles.park_tiles / 2);
/// How far each of a blue tile's two chickens stands from its middle.
pub const chicken_off = 15;

/// A park tile's top-left corner, in 256ths.
fn tileCorner(col: i32, row: i32) physics.Point {
    return .{ .x = px(tiles.park_offset_px + col * tiles.tile_px), .y = px(tiles.park_offset_px + row * tiles.tile_px) };
}

/// The first layout, every critter present, no one leashed.
pub fn board() physics.Board {
    const in = px(corner_in);
    const far = px(tiles.tile_px - corner_in);
    const corners = [4]physics.Point{ .{ .x = in, .y = in }, .{ .x = far, .y = in }, .{ .x = in, .y = far }, .{ .x = far, .y = far } };
    var b = physics.Board.empty();
    var d: usize = 0;
    var c: usize = 0;
    var h: usize = 0;
    var row: i32 = 0;
    while (row < tiles.park_tiles) : (row += 1) {
        var col: i32 = 0;
        while (col < tiles.park_tiles) : (col += 1) {
            const at = tileCorner(col, row);
            for (corners) |k| {
                b.place(.dog(@intCast(d)), .{ .x = at.x + k.x, .y = at.y + k.y });
                d += 1;
            }
            const mid: physics.Point = .{ .x = at.x + px(tiles.tile_px / 2), .y = at.y + px(tiles.tile_px / 2) };
            if (@mod(col + row, 2) == 1) {
                for ([2]i32{ -chicken_off, chicken_off }) |off| {
                    b.place(.chicken(@intCast(h)), .{ .x = mid.x + px(off), .y = mid.y });
                    h += 1;
                }
                continue;
            }
            b.place(.cow(@intCast(c)), mid);
            c += 1;
        }
    }
    std.debug.assert(d == dog_count and c == cow_count and h == chicken_count);
    return b;
}

const testing = std.testing;

test "the first layout: four dogs to each tile of the park, breed b in the tile's corner b (NW, NE, SW, SE), numbered tile by tile" {
    const b = board();
    const half = physics.tile / 2;
    const first = tiles.park_offset_px / tiles.tile_px;
    for (b.dogs, b.dog_known, 0..) |at, known, n| {
        try testing.expectEqual(physics.Known.present, known);
        const breed = n % physics.breeds;
        const k: i32 = @intCast(n / physics.breeds);
        const t = physics.tileOf(at);
        try testing.expectEqual(tiles.Tile{ .col = first + @mod(k, tiles.park_tiles), .row = first + @divFloor(k, tiles.park_tiles) }, t);
        const in_x = at.x - t.col * physics.tile;
        const in_y = at.y - t.row * physics.tile;
        try testing.expectEqual(breed % 2 == 1, in_x >= half);
        try testing.expectEqual(breed >= 2, in_y >= half);
    }
}

test "the first layout: a cow in the middle of each white tile of the park, row by row" {
    const b = board();
    var n: usize = 0;
    var row: i32 = 0;
    while (row < tiles.park_tiles) : (row += 1) {
        var col: i32 = 0;
        while (col < tiles.park_tiles) : (col += 1) {
            if (@mod(col + row, 2) == 1) continue;
            const at = tileCorner(col, row);
            try testing.expectEqual(physics.Point{ .x = at.x + physics.tile / 2, .y = at.y + physics.tile / 2 }, b.cows[n]);
            try testing.expectEqual(physics.Known.present, b.cow_known[n]);
            n += 1;
        }
    }
    try testing.expectEqual(cow_count, n);
}

test "the first layout: no two critters overlap (a load puts it back without resolving; a first start resolves it, so the two agree only while this holds)" {
    const b = board();
    var all: [physics.critter_count]struct { p: physics.Point, half: i32 } = undefined;
    for (b.dogs, 0..) |p, i| all[i] = .{ .p = p, .half = physics.dog_half };
    for (b.cows, 0..) |p, i| all[physics.dog_count + i] = .{ .p = p, .half = physics.cow_half };
    for (b.chickens, 0..) |p, i| all[physics.dog_count + physics.cow_count + i] = .{ .p = p, .half = physics.chicken_half };
    for (all, 0..) |a, i| for (all[i + 1 ..]) |c| {
        try testing.expect(!physics.squaresOverlap(a.p, a.half, c.p, c.half));
    };
}

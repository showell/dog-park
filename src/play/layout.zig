//! **THE FIRST LAYOUT**, in 256ths: where every critter stands when the park
//! starts afresh (the server's first start, and every load). In every tile
//! of the populated park (tiles.zig), four dogs, one of each breed, each
//! near its own corner of the tile: breed 0 north-west, 1 north-east, 2
//! south-west, 3 south-east, so a tile's four dogs are numbered 4k to
//! 4k + 3, tile by tile, row by row. White tiles (column plus row even)
//! also hold a cow in the middle, row by row; blue tiles (column plus row
//! odd) two chickens side by side in the middle, row by row: each one's
//! home (`chickenHome`), where it walks back to (docs/PHYSICS.md, "Poop and
//! chickens").
//!
//! **ROC PLACES THEM.** The places are the world's (world.zig, which
//! roc/world.roc says), and so are the counts: as many dogs, cows and
//! chickens as its lists hold. The tests below say what any first layout
//! keeps to, and hold this one to the original (`original`).

const std = @import("std");
const tiles = @import("tiles.zig");
const physics = @import("physics.zig");
const world = @import("world.zig").world;
const px = physics.px;

pub const dog_count: comptime_int = world.dogs.len;
pub const cow_count: comptime_int = world.cows.len;
pub const chicken_count: comptime_int = world.chickens.len;

/// The world's spots as the physics' points, made once at compile time.
fn points(comptime spots: []const @import("world.zig").Spot) [spots.len]physics.Point {
    var out: [spots.len]physics.Point = undefined;
    for (spots, &out) |s, *p| p.* = .{ .x = s.x, .y = s.y };
    return out;
}
const dogs = points(world.dogs);
const cows = points(world.cows);
const chickens = points(world.chickens);

/// **A CHICKEN'S HOME**: where chicken `n` stands in the first layout, and
/// where it walks back to when it has no poop to forage (docs/PHYSICS.md,
/// "Poop and chickens").
pub fn chickenHome(n: u16) physics.Point {
    return chickens[n];
}

/// The first layout, every critter present, no one leashed.
pub fn board() physics.Board {
    var b = physics.Board.empty();
    for (dogs, 0..) |p, n| b.place(.dog(@intCast(n)), p);
    for (cows, 0..) |p, n| b.place(.cow(@intCast(n)), p);
    for (chickens, 0..) |p, n| b.place(.chicken(@intCast(n)), p);
    return b;
}

const testing = std.testing;

/// **THE ORIGINAL**: the first layout as Zig computed it before Roc said it,
/// its numbers frozen here, so the tests can hold the world to it. Remove it
/// when the world is meant to change.
const original = struct {
    const tile_px = 350;
    const park_tiles = 4;
    const park_first = 1;
    const corner_in = 52;
    const chicken_off = 15;

    fn corner(col: i32, row: i32) physics.Point {
        return .{ .x = px((park_first + col) * tile_px), .y = px((park_first + row) * tile_px) };
    }

    fn home(n: u16) physics.Point {
        const per_row = park_tiles / 2;
        const k: i32 = n / 2;
        const row = @divFloor(k, per_row);
        const col = 2 * @mod(k, per_row) + 1 - @mod(row, 2);
        const at = corner(col, row);
        const off: i32 = if (n % 2 == 0) -chicken_off else chicken_off;
        return .{ .x = at.x + px(tile_px / 2 + off), .y = at.y + px(tile_px / 2) };
    }

    fn board() physics.Board {
        const in = px(corner_in);
        const far = px(tile_px - corner_in);
        const corners = [4]physics.Point{ .{ .x = in, .y = in }, .{ .x = far, .y = in }, .{ .x = in, .y = far }, .{ .x = far, .y = far } };
        var b = physics.Board.empty();
        var d: usize = 0;
        var c: usize = 0;
        var h: usize = 0;
        var row: i32 = 0;
        while (row < park_tiles) : (row += 1) {
            var col: i32 = 0;
            while (col < park_tiles) : (col += 1) {
                const at = corner(col, row);
                for (corners) |k| {
                    b.place(.dog(@intCast(d)), .{ .x = at.x + k.x, .y = at.y + k.y });
                    d += 1;
                }
                if (@mod(col + row, 2) == 1) {
                    for (0..2) |_| {
                        b.place(.chicken(@intCast(h)), home(@intCast(h)));
                        h += 1;
                    }
                    continue;
                }
                b.place(.cow(@intCast(c)), .{ .x = at.x + px(tile_px / 2), .y = at.y + px(tile_px / 2) });
                c += 1;
            }
        }
        std.debug.assert(d == dog_count and c == cow_count and h == chicken_count);
        return b;
    }
};

test "the world is the original, exactly: its size, its park, its critters' sizes and breeds, and every critter and chicken's home where Zig put them before Roc said them" {
    try testing.expectEqual(original.tile_px, tiles.tile_px);
    try testing.expectEqual(6, tiles.world_tiles);
    try testing.expectEqual(original.park_tiles, tiles.park_tiles);
    try testing.expectEqual(original.park_first * original.tile_px, tiles.park_offset_px);
    try testing.expectEqual(.{ 28, 42, 20, 12, 4 }, .{ physics.dog_px, physics.cow_px, physics.chicken_px, physics.poop_px, physics.breeds });
    try testing.expect(std.meta.eql(original.board(), board()));
    for (0..chicken_count) |n| try testing.expectEqual(original.home(@intCast(n)), chickenHome(@intCast(n)));
}

/// A park tile's top-left corner, in 256ths.
fn tileCorner(col: i32, row: i32) physics.Point {
    return .{ .x = px(tiles.park_offset_px + col * tiles.tile_px), .y = px(tiles.park_offset_px + row * tiles.tile_px) };
}

test "the first layout: four dogs to each tile of the park, breed b in the tile's corner b (NW, NE, SW, SE), numbered tile by tile" {
    try testing.expectEqual(tiles.park_tiles * tiles.park_tiles * physics.breeds, dog_count);
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

test "a chicken's home is where the first layout puts it: two to each blue tile, either side of its middle, the tiles row by row" {
    const b = board();
    var h: u16 = 0;
    var row: i32 = 0;
    while (row < tiles.park_tiles) : (row += 1) {
        var col: i32 = 0;
        while (col < tiles.park_tiles) : (col += 1) {
            if (@mod(col + row, 2) == 0) continue;
            const at = tileCorner(col, row);
            const mid: physics.Point = .{ .x = at.x + physics.tile / 2, .y = at.y + physics.tile / 2 };
            const west = chickenHome(h);
            const east = chickenHome(h + 1);
            try testing.expectEqual(mid.y, west.y);
            try testing.expectEqual(mid.y, east.y);
            try testing.expect(west.x < mid.x);
            try testing.expectEqual(mid.x - west.x, east.x - mid.x);
            try testing.expectEqual(west, b.chickens[h]);
            try testing.expectEqual(east, b.chickens[h + 1]);
            h += 2;
        }
    }
    try testing.expectEqual(chicken_count, h);
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

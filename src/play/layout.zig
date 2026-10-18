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
//! **ROC PLACES THEM.** roc/layout.roc says the layout. `zig build
//! roc-layout` runs it and writes what it prints to layout.txt, one line
//! per critter (`<kind> <x> <y>`; dogs, then cows, then chickens), which is
//! checked in. This file embeds layout.txt and reads it at compile time, so
//! no build runs Roc, and the physics is the same Zig on every target (the
//! server, the page's wasm, the kernel). The Zig layout below (`zigBoard`,
//! `zigChickenHome`) is the oracle a test holds the table to, for now.

const std = @import("std");
const tiles = @import("tiles.zig");
const physics = @import("physics.zig");
const px = physics.px;

/// How far in from its corner of the tile a dog stands, on each axis.
pub const corner_in = 52;

pub const dog_count = tiles.park_tiles * tiles.park_tiles * 4;
pub const cow_count = tiles.park_tiles * tiles.park_tiles - tiles.park_tiles * tiles.park_tiles / 2;
pub const chicken_count = 2 * (tiles.park_tiles * tiles.park_tiles / 2);
/// How far each of a blue tile's two chickens stands from its middle.
pub const chicken_off = 15;

/// **A CHICKEN'S HOME**: where chicken `n` stands in the first layout, and
/// where it walks back to when it has no poop to forage (docs/PHYSICS.md,
/// "Poop and chickens"). The park's blue tiles, row by row, two chickens
/// to each: in a row of an even-sided park, half the tiles are blue, the
/// odd columns in an even row and the even ones in an odd row.
pub fn chickenHome(n: u16) physics.Point {
    return table.chickens[n];
}

/// The Zig layout's chicken homes: the oracle the table is held to.
fn zigChickenHome(n: u16) physics.Point {
    comptime std.debug.assert(tiles.park_tiles % 2 == 0);
    const per_row = tiles.park_tiles / 2;
    const k: i32 = n / 2;
    const row = @divFloor(k, per_row);
    const col = 2 * @mod(k, per_row) + 1 - @mod(row, 2);
    const at = tileCorner(col, row);
    const off: i32 = if (n % 2 == 0) -chicken_off else chicken_off;
    return .{ .x = at.x + px(tiles.tile_px / 2 + off), .y = at.y + px(tiles.tile_px / 2) };
}

/// **THE TABLE**: layout.txt, read at compile time. Every line names a
/// kind and a point; the kinds come in order, each as many as its count.
const Table = struct {
    dogs: [dog_count]physics.Point,
    cows: [cow_count]physics.Point,
    chickens: [chicken_count]physics.Point,
};

const table: Table = parseTable(@embedFile("layout.txt"));

fn parseTable(comptime text: []const u8) Table {
    @setEvalBranchQuota(100_000);
    var t: Table = undefined;
    var counts = [3]usize{ 0, 0, 0 };
    var last: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = words.next().?;
        const k: usize = if (std.mem.eql(u8, kind, "dog")) 0 else if (std.mem.eql(u8, kind, "cow")) 1 else if (std.mem.eql(u8, kind, "chicken")) 2 else @compileError("layout.txt: a kind that is not dog, cow or chicken: " ++ line);
        if (k < last) @compileError("layout.txt: the kinds out of order (dogs, cows, chickens): " ++ line);
        last = k;
        const p: physics.Point = .{
            .x = std.fmt.parseInt(i32, words.next().?, 10) catch @compileError("layout.txt: x is not a number: " ++ line),
            .y = std.fmt.parseInt(i32, words.next().?, 10) catch @compileError("layout.txt: y is not a number: " ++ line),
        };
        if (words.next() != null) @compileError("layout.txt: more than a kind and a point: " ++ line);
        const n = counts[k];
        switch (k) {
            0 => if (n < dog_count) {
                t.dogs[n] = p;
            },
            1 => if (n < cow_count) {
                t.cows[n] = p;
            },
            else => if (n < chicken_count) {
                t.chickens[n] = p;
            },
        }
        counts[k] += 1;
    }
    if (counts[0] != dog_count or counts[1] != cow_count or counts[2] != chicken_count)
        @compileError(std.fmt.comptimePrint("layout.txt: {d} dogs, {d} cows, {d} chickens; the park holds {d}, {d}, {d}", .{ counts[0], counts[1], counts[2], dog_count, cow_count, chicken_count }));
    return t;
}

/// A park tile's top-left corner, in 256ths.
fn tileCorner(col: i32, row: i32) physics.Point {
    return .{ .x = px(tiles.park_offset_px + col * tiles.tile_px), .y = px(tiles.park_offset_px + row * tiles.tile_px) };
}

/// The first layout, every critter present, no one leashed: the table.
pub fn board() physics.Board {
    var b = physics.Board.empty();
    for (table.dogs, 0..) |p, n| b.place(.dog(@intCast(n)), p);
    for (table.cows, 0..) |p, n| b.place(.cow(@intCast(n)), p);
    for (table.chickens, 0..) |p, n| b.place(.chicken(@intCast(n)), p);
    return b;
}

/// The Zig layout: the oracle the table is held to.
fn zigBoard() physics.Board {
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
                for (0..2) |_| {
                    b.place(.chicken(@intCast(h)), zigChickenHome(@intCast(h)));
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

test "the first layout is the Zig one, exactly: Roc's table (layout.txt) puts every critter, and every chicken's home, where the Zig layout did" {
    try testing.expect(std.meta.eql(zigBoard(), board()));
    for (0..chicken_count) |n| try testing.expectEqual(zigChickenHome(@intCast(n)), chickenHome(@intCast(n)));
}

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

test "a chicken's home is where the first layout puts it: two to each blue tile, chicken_off either side of its middle, the tiles row by row" {
    var h: u16 = 0;
    var row: i32 = 0;
    while (row < tiles.park_tiles) : (row += 1) {
        var col: i32 = 0;
        while (col < tiles.park_tiles) : (col += 1) {
            if (@mod(col + row, 2) == 0) continue;
            const at = tileCorner(col, row);
            const mid = at.y + px(tiles.tile_px / 2);
            try testing.expectEqual(physics.Point{ .x = at.x + px(tiles.tile_px / 2 - chicken_off), .y = mid }, chickenHome(h));
            try testing.expectEqual(physics.Point{ .x = at.x + px(tiles.tile_px / 2 + chicken_off), .y = mid }, chickenHome(h + 1));
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

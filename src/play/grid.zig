//! **A GRID OF CELLS ROUND A TORUS**: up to `cap` members, each an index
//! in [0, `cap`) standing at an integer point, kept by the cell it stands
//! in: a `side` by `side` grid of cells `size` a side over a square torus
//! `side * size` a side. A cell holds a bitset of its members, so a query
//! for a square (`near`) is the union of the cells it meets, walked in
//! index order. It knows nothing of what the members are.
//!
//! The cells' storage is the caller's type (`Store`), anything with
//! `items: [n]u64` and `len`: `Owned` for a grid of its own, or a buffer a
//! borrower reads in place (the physics lends its grid's cells to Roc as
//! they are, roc_physics.zig's `Lent`). Cell `c`'s bits are words
//! `c * words ..` of `items`, member `j` bit `j % 64` of word `j / 64`;
//! cell `c` is `row * side + col`.

const std = @import("std");

/// Storage of a grid's own.
pub fn Owned(comptime T: type, comptime most: usize) type {
    return struct {
        items: [most]T = undefined,
        len: usize = 0,
    };
}

pub fn Grid(comptime cap: usize, comptime side: usize, comptime size: i32, comptime Store: fn (comptime type, comptime usize) type) type {
    return struct {
        /// The words of a cell's bitset.
        pub const words = std.math.divCeil(usize, cap, 64) catch unreachable;
        /// A set of members, in the cells' own word layout.
        pub const Set = std.bit_set.ArrayBitSet(u64, cap);
        pub const Cells = Store(u64, side * side * words);
        /// The torus's side.
        pub const extent: i32 = @as(i32, side) * size;

        cells: Cells = .{},
        /// The cell each member stands in.
        cell_of: [cap]u16 = undefined,

        const Self = @This();

        comptime {
            std.debug.assert(side * side <= std.math.maxInt(u16));
        }

        /// No members.
        pub fn clear(g: *Self) void {
            g.cells.len = side * side * words;
            @memset(&g.cells.items, 0);
        }

        /// The cell point (`x`, `y`) stands in, round the torus.
        pub fn cellOf(x: i32, y: i32) u16 {
            const col: usize = @intCast(@divFloor(@mod(x, extent), size));
            const row: usize = @intCast(@divFloor(@mod(y, extent), size));
            return @intCast(row * side + col);
        }

        /// Member `j`, in no cell yet, stands at (`x`, `y`).
        pub fn add(g: *Self, j: usize, x: i32, y: i32) void {
            const c = cellOf(x, y);
            g.cell_of[j] = c;
            g.set(c, j);
        }

        /// Member `j` moved to (`x`, `y`): its bit moves if its cell did.
        pub fn move(g: *Self, j: usize, x: i32, y: i32) void {
            const c = cellOf(x, y);
            const was = g.cell_of[j];
            if (c == was) return;
            g.word(was, j).* &= ~bit(j);
            g.set(c, j);
            g.cell_of[j] = c;
        }

        /// Every member whose point might lie within `reach` of (`x`, `y`)
        /// on both axes (a superset of those that do): those of the cells
        /// the square meets, round the torus.
        pub fn near(g: *const Self, x: i32, y: i32, reach: i32) Set {
            var out: Set = .initEmpty();
            const xs = Wrapped.of(@mod(x, extent), reach, size, side);
            const ys = Wrapped.of(@mod(y, extent), reach, size, side);
            for (0..ys.n) |ri| {
                const r = ys.at(ri);
                for (0..xs.n) |ci| {
                    const at = (r * side + xs.at(ci)) * words;
                    for (&out.masks, g.cells.items[at..][0..words]) |*o, w| o.* |= w;
                }
            }
            return out;
        }

        /// **THE CELLS HOLD** members 0 to `points.len` - 1 (anything with
        /// `x` and `y`), each in the cell its point stands in and nowhere
        /// else.
        pub fn holds(g: *const Self, points: anytype) bool {
            var bits: usize = 0;
            for (g.cells.items) |w| bits += @popCount(w);
            if (bits != points.len) return false;
            for (points, 0..) |p, j| {
                const c = cellOf(p.x, p.y);
                if (c != g.cell_of[j] or g.cells.items[c * words + j / 64] & bit(j) == 0) return false;
            }
            return true;
        }

        fn set(g: *Self, c: u16, j: usize) void {
            g.word(c, j).* |= bit(j);
        }

        fn word(g: *Self, c: u16, j: usize) *u64 {
            return &g.cells.items[@as(usize, c) * words + j / 64];
        }

        fn bit(j: usize) u64 {
            return @as(u64, 1) << @intCast(j % 64);
        }
    };
}

/// **A RANGE ROUND THE TORUS**: the `n` cells, `size` a side, that a span
/// of `reach` either way of `v` (in [0, `count` * `size`)) meets, from
/// `lo`, each named by `at` in [0, `count`); never more than `count`, so no
/// cell comes twice.
pub const Wrapped = struct {
    lo: i32,
    n: usize,
    count: i32,

    pub fn of(v: i32, reach: i32, size: i32, count: usize) Wrapped {
        const lo = @divFloor(v - reach, size);
        const hi = @divFloor(v + reach, size);
        return .{ .lo = lo, .n = @min(@as(usize, @intCast(hi - lo + 1)), count), .count = @intCast(count) };
    }
    pub fn at(w: Wrapped, i: usize) usize {
        return @intCast(@mod(w.lo + @as(i32, @intCast(i)), w.count));
    }
};

const testing = std.testing;
const P = struct { x: i32, y: i32 };
/// 70 members (two words a cell), 4 by 4 cells of 10.
const G = Grid(70, 4, 10, Owned);

fn members(g: *const G, x: i32, y: i32, reach: i32, out: []usize) []usize {
    const s = g.near(x, y, reach);
    var it = s.iterator(.{});
    var n: usize = 0;
    while (it.next()) |j| : (n += 1) out[n] = j;
    return out[0..n];
}

test "a member is in the cell its point stands in, round the torus" {
    try testing.expectEqual(@as(u16, 0), G.cellOf(0, 0));
    try testing.expectEqual(@as(u16, 1 * 4 + 3), G.cellOf(39, 15));
    try testing.expectEqual(@as(u16, 3 * 4 + 3), G.cellOf(-1, -1));
    try testing.expectEqual(@as(u16, 0), G.cellOf(40, 80));
}

test "a square finds the members of the cells it meets, across the seam, in index order" {
    var g: G = .{};
    g.clear();
    const pts = [_]P{ .{ .x = 1, .y = 1 }, .{ .x = 38, .y = 2 }, .{ .x = 25, .y = 25 }, .{ .x = 3, .y = 39 } };
    // Member 65 too: a second word.
    for (pts, 0..) |p, j| g.add(j, p.x, p.y);
    g.add(65, 39, 39);
    var buf: [70]usize = undefined;
    // A square at the world's corner meets all four corner cells.
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3, 65 }, members(&g, 0, 0, 2, &buf));
    // One inside a cell meets only it.
    try testing.expectEqualSlices(usize, &.{2}, members(&g, 25, 25, 2, &buf));
    // A square wider than the world meets every cell once.
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 65 }, members(&g, 5, 5, 100, &buf));
}

test "a move takes the bit to the new cell, and the cells hold" {
    var g: G = .{};
    g.clear();
    var pts = [_]P{ .{ .x = 1, .y = 1 }, .{ .x = 15, .y = 15 } };
    for (pts, 0..) |p, j| g.add(j, p.x, p.y);
    try testing.expect(g.holds(pts[0..]));
    pts[0] = .{ .x = 35, .y = 1 };
    try testing.expect(!g.holds(pts[0..]));
    g.move(0, 35, 1);
    try testing.expect(g.holds(pts[0..]));
    var buf: [70]usize = undefined;
    try testing.expectEqualSlices(usize, &.{0}, members(&g, 35, 1, 1, &buf));
    try testing.expectEqualSlices(usize, &.{}, members(&g, 5, 5, 1, &buf));
    // A move within a cell changes nothing.
    g.move(1, 16, 16);
    try testing.expect(g.holds(&[_]P{ pts[0], .{ .x = 16, .y = 16 } }));
}

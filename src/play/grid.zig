//! **A GRID OF CELLS ROUND A TORUS**: up to `cap` members, each an index
//! in [0, `cap`) standing at an integer point, kept by the cell it stands
//! in: a `side` by `side` grid of cells `size` a side over a square torus
//! `side * size` a side. A cell holds a bitset of its members. This keeps
//! only the storage and the tests' check of it (`holds`): who files and
//! moves the members is the borrower's (the physics lends its grid's cells
//! to Roc as they are, roc_physics.zig's `Lent`, and roc/Walk.roc keeps
//! them). It knows nothing of what the members are.
//!
//! The cells' storage is the caller's type (`Store`), anything with
//! `items: [n]u64` and `len`: `Owned` for a grid of its own, or a buffer a
//! borrower reads in place. Cell `c`'s bits are words `c * words ..` of
//! `items`, member `j` bit `j % 64` of word `j / 64`; cell `c` is
//! `row * side + col`.

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
        pub const Cells = Store(u64, side * side * words);
        /// The torus's side.
        pub const extent: i32 = @as(i32, side) * size;

        cells: Cells = .{},

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

        /// **THE CELLS HOLD** members 0 to `points.len` - 1 (anything with
        /// `x` and `y`), each in the cell its point stands in and nowhere
        /// else.
        pub fn holds(g: *const Self, points: anytype) bool {
            var bits: usize = 0;
            for (g.cells.items) |w| bits += @popCount(w);
            if (bits != points.len) return false;
            for (points, 0..) |p, j| {
                const c = cellOf(p.x, p.y);
                if (g.cells.items[@as(usize, c) * words + j / 64] & bit(j) == 0) return false;
            }
            return true;
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

/// Member `j` filed at (`x`, `y`), as a borrower would.
fn file(g: *G, j: usize, x: i32, y: i32) void {
    g.cells.items[@as(usize, G.cellOf(x, y)) * G.words + j / 64] |= @as(u64, 1) << @intCast(j % 64);
}

test "a member is in the cell its point stands in, round the torus" {
    try testing.expectEqual(@as(u16, 0), G.cellOf(0, 0));
    try testing.expectEqual(@as(u16, 1 * 4 + 3), G.cellOf(39, 15));
    try testing.expectEqual(@as(u16, 3 * 4 + 3), G.cellOf(-1, -1));
    try testing.expectEqual(@as(u16, 0), G.cellOf(40, 80));
}

test "the cells hold each member in its point's cell, and no more" {
    var g: G = .{};
    g.clear();
    const pts = [_]P{ .{ .x = 1, .y = 1 }, .{ .x = 38, .y = 2 } };
    file(&g, 0, 1, 1);
    file(&g, 1, 38, 2);
    try testing.expect(g.holds(pts[0..]));
    // Moved without its bit, member 1 is not held.
    try testing.expect(!g.holds(&[_]P{ pts[0], .{ .x = 5, .y = 15 } }));
    // An extra bit, in a second word, is too many.
    file(&g, 65, 39, 39);
    try testing.expect(!g.holds(pts[0..]));
}

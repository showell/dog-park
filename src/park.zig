//! The park: a finite rectangle of the park's frame, from (0, 0) to its size,
//! tiling the plane (it wraps, Pac-Man style), and the lattice the dogs are
//! first placed on.
//!
//! **A NAMING FENCE.** Zig has no private fields, so a literal can build
//! anything. `InParkPoint` is made by `Park` alone (`wrap`, `pointOf`,
//! `holding`), and a literal of one outside this file is the bug, visible by
//! name in review.

const std = @import("std");
const frames = @import("frames.zig");
const ParkPoint = frames.ParkPoint;
const PlanePoint = frames.PlanePoint;
const Displacement = frames.Displacement;
const Size = frames.Size;
const Coord = frames.Coord;

/// A rectangle in `frame` (the park's, or the plane's): its top-left corner
/// and its size. Half-open: a point on the right or bottom edge is outside.
fn Rect(comptime frame: frames.Frame) type {
    return struct {
        top_left: P,
        size: Size,

        const P = frames.Point(frame);
        const Self = @This();

        pub fn holds(self: Self, p: P) Containment {
            // In i64, where no difference of these can overflow.
            const x: i64 = p.x.number();
            const y: i64 = p.y.number();
            const left: i64 = self.top_left.x.number();
            const top: i64 = self.top_left.y.number();
            const over: Overhang = .{
                .left = @intCast(@max(0, left - x)),
                .top = @intCast(@max(0, top - y)),
                .right = @intCast(@max(0, x - (left + self.size.width - 1))),
                .bottom = @intCast(@max(0, y - (top + self.size.height - 1))),
            };
            if (std.meta.eql(over, Overhang.none)) return .inside;
            return .{ .outside = over };
        }
    };
}

/// A rectangle of the park, as the index is asked about.
pub const ParkRect = Rect(.park);

/// A rectangle of the plane, as a scene covers: it may straddle a seam, or
/// be wider than the park.
pub const PlaneRect = struct {
    top_left: PlanePoint,
    size: Size,

    pub fn holds(self: PlaneRect, p: PlanePoint) Containment {
        return (Rect(.plane){ .top_left = self.top_left, .size = self.size }).holds(p);
    }

    /// The rectangle grown by `margin` on every side.
    pub fn grownBy(self: PlaneRect, margin: u31) PlaneRect {
        return .{
            .top_left = self.top_left.plus(.{ .dx = -@as(Coord, margin), .dy = -@as(Coord, margin) }),
            .size = .{ .width = self.size.width + margin + margin, .height = self.size.height + margin + margin },
        };
    }

    /// The park rectangles this covers, one for each tile it meets, each
    /// with the offset that carries its dogs back to this rectangle's copy:
    /// at most four for a rectangle no bigger than the park, nine for one no
    /// more than twice its size (what `wire` allows a scene to cover). For a
    /// rectangle within a few park sizes of the origin, as every checked
    /// request's is: one near the coordinate's edge overflows.
    pub fn pieces(self: PlaneRect, p: Park) Pieces {
        const first = p.tileOf(self.top_left);
        return .{ .rect = self, .park = p, .first = first, .next = first };
    }
};

/// One tile's share of a plane rectangle: the park rectangle the index is
/// asked about, and the offset from a park point in it to the copy the
/// plane rectangle holds.
pub const Piece = struct {
    region: ParkRect,
    offset: Displacement,

    /// The copy of a park point of this piece in the plane rectangle cut.
    pub fn toPlane(self: Piece, p: ParkPoint) PlanePoint {
        return p.plus(self.offset);
    }
};

/// A tile of the plane, by column and row from the park's own (0, 0).
pub const Tile = struct { column: Coord, row: Coord };

/// The pieces of a plane rectangle, one at a time, row by row of tiles.
pub const Pieces = struct {
    rect: PlaneRect,
    park: Park,
    first: Tile,
    next: Tile,

    pub fn nextPiece(self: *Pieces) NextPiece {
        if (self.rect.size.width == 0 or self.rect.size.height == 0) return .done;
        const width: Coord = self.park.size.width;
        const height: Coord = self.park.size.height;
        const left = self.rect.top_left.x.number();
        const top = self.rect.top_left.y.number();
        const right = left + self.rect.size.width;
        const bottom = top + self.rect.size.height;
        const tile = self.next;
        const tile_left = tile.column * width;
        const tile_top = tile.row * height;
        if (tile_top >= bottom) return .done;
        // Advance: east along the row, then the next row down.
        if (tile_left + width >= right) {
            self.next = .{ .column = self.first.column, .row = tile.row + 1 };
        } else {
            self.next = .{ .column = tile.column + 1, .row = tile.row };
        }
        const piece_left = @max(left, tile_left);
        const piece_top = @max(top, tile_top);
        const piece_right = @min(right, tile_left + width);
        const piece_bottom = @min(bottom, tile_top + height);
        return .{ .piece = .{
            .region = .{
                .top_left = .at(piece_left - tile_left, piece_top - tile_top),
                .size = .{ .width = @intCast(piece_right - piece_left), .height = @intCast(piece_bottom - piece_top) },
            },
            .offset = .{ .dx = tile_left, .dy = tile_top },
        } };
    }
};

pub const NextPiece = union(enum) {
    piece: Piece,
    done,
};

/// Where a point is, against a rectangle: inside, or outside by how much on
/// each side (at most two of the four are not zero).
pub const Containment = union(enum) {
    inside,
    outside: Overhang,
};

/// How far past each edge a point is (u64: from one coordinate edge to the
/// other is more than a u32).
pub const Overhang = struct {
    left: u64,
    top: u64,
    right: u64,
    bottom: u64,

    pub const none: Overhang = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
};

/// A point the park holds: a dog's canonical place. Made only by `Park`
/// (`wrap`, `pointOf`, `holding`); a dog stands only on one of these.
pub const InParkPoint = struct {
    point: ParkPoint,
};

/// The longest side a park may have: with it, no coordinate built from a
/// park, a checked request (wire.zig) and a drag comes near overflowing.
pub const longest_side: u31 = 1 << 20;

/// How far apart the lattice's spots are, and how big the smallest park is
/// (one spot). One lattice for every park, so a spacing of 0 is not a value.
pub const lattice_spacing: u31 = 100;

/// The park. Its frame's origin is its top-left corner, so its bounds are
/// (0, 0) to its size; a park has no other top-left. Made by `Park.of`,
/// which refuses a park too small to hold one lattice spot, too large, or
/// not a whole number of lattice cells (so the lattice has no seam).
pub const Park = struct {
    size: Size,

    pub fn of(size: Size) Sized {
        if (size.width < lattice_spacing or size.height < lattice_spacing) return .too_small;
        if (size.width > longest_side or size.height > longest_side) return .too_large;
        if (size.width % lattice_spacing != 0 or size.height % lattice_spacing != 0) return .off_lattice;
        return .{ .park = .{ .size = size } };
    }

    /// The park point a plane point is a copy of.
    pub fn wrap(self: Park, p: PlanePoint) InParkPoint {
        return .{ .point = .at(
            @mod(p.x.number(), @as(Coord, self.size.width)),
            @mod(p.y.number(), @as(Coord, self.size.height)),
        ) };
    }

    /// The copy of `p` nearest `near`: on each axis, `near` minus the copy
    /// is in [-size/2, size/2), so a tie goes to the copy east or south.
    pub fn nearestCopy(self: Park, p: InParkPoint, near: PlanePoint) PlanePoint {
        const width: Coord = self.size.width;
        const height: Coord = self.size.height;
        const home = frames.homeCopy(p.point);
        const d = near.minus(home);
        return home.plus(.{
            .dx = @divFloor(d.dx + @divFloor(width, 2), width) * width,
            .dy = @divFloor(d.dy + @divFloor(height, 2), height) * height,
        });
    }

    /// The tile a plane point is on.
    pub fn tileOf(self: Park, p: PlanePoint) Tile {
        return .{
            .column = @divFloor(p.x.number(), @as(Coord, self.size.width)),
            .row = @divFloor(p.y.number(), @as(Coord, self.size.height)),
        };
    }

    /// `p` as a dog's place, if the park holds it.
    pub fn holding(self: Park, p: ParkPoint) Holding {
        return switch (self.holds(p)) {
            .inside => .{ .inside = .{ .point = p } },
            .outside => .outside,
        };
    }

    pub fn bounds(self: Park) ParkRect {
        return .{ .top_left = .at(0, 0), .size = self.size };
    }

    pub fn holds(self: Park, p: ParkPoint) Containment {
        return self.bounds().holds(p);
    }

    /// How many lattice spots fit across and down.
    pub fn extent(self: Park) LatticeExtent {
        return .{ .columns = self.size.width / lattice_spacing, .rows = self.size.height / lattice_spacing };
    }

    /// Where a spot stands, if this park reaches it: half a spacing in from
    /// its cell's corner, so no spot is on an edge.
    pub fn pointOf(self: Park, s: LatticeSpot) SpotPoint {
        const e = self.extent();
        if (s.column >= e.columns or s.row >= e.rows) return .off_park;
        const half = lattice_spacing / 2;
        return .{ .on = .{ .point = .at(
            half + @as(Coord, s.column) * lattice_spacing,
            half + @as(Coord, s.row) * lattice_spacing,
        ) } };
    }
};

pub const Sized = union(enum) {
    park: Park,
    too_small,
    too_large,
    off_lattice,
};

pub const Holding = union(enum) {
    inside: InParkPoint,
    outside,
};

pub const LatticeExtent = struct { columns: u31, rows: u31 };

/// A spot on the lattice, by column and row from the park's top-left. Any
/// park's: `Park.pointOf` says whether this one reaches it.
pub const LatticeSpot = struct {
    column: u31,
    row: u31,
};

pub const SpotPoint = union(enum) {
    on: InParkPoint,
    off_park,
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const small: Park = (Park.of(.{ .width = 1000, .height = 600 })).park;

fn piecesOf(r: PlaneRect, into: []Piece) []Piece {
    var it = r.pieces(small);
    var n: usize = 0;
    while (true) switch (it.nextPiece()) {
        .piece => |p| {
            into[n] = p;
            n += 1;
        },
        .done => return into[0..n],
    };
}

test "a park too small for one lattice spot is not made" {
    try testing.expectEqual(Sized.too_small, Park.of(.{ .width = 0, .height = 600 }));
    try testing.expectEqual(Sized.too_small, Park.of(.{ .width = 1000, .height = lattice_spacing - 1 }));
    try testing.expectEqual(Sized.too_large, Park.of(.{ .width = longest_side + 1, .height = 600 }));
    try testing.expect(Park.of(.{ .width = longest_side - longest_side % lattice_spacing, .height = 5000 }) == .park);
    // Not a whole number of cells: the lattice would have a seam.
    try testing.expectEqual(Sized.off_lattice, Park.of(.{ .width = 1050, .height = 600 }));
}

test "wrapping: a plane point past any edge comes in at the far one" {
    try testing.expectEqual(ParkPoint.at(5, 10), small.wrap(.at(1005, 10)).point);
    try testing.expectEqual(ParkPoint.at(995, 590), small.wrap(.at(-5, -10)).point);
    try testing.expectEqual(ParkPoint.at(0, 0), small.wrap(.at(-3000, 1200)).point);
    try testing.expectEqual(ParkPoint.at(999, 599), small.wrap(.at(999, 599)).point);
}

test "the copy of a park point nearest a plane point, across a seam or tiles away" {
    const dog: InParkPoint = .{ .point = .at(10, 300) };
    try testing.expectEqual(PlanePoint.at(10, 300), small.nearestCopy(dog, .at(400, 300)));
    // Just past the east edge, the dog's copy one tile east is nearer.
    try testing.expectEqual(PlanePoint.at(1010, 300), small.nearestCopy(dog, .at(990, 300)));
    try testing.expectEqual(PlanePoint.at(-2990, -900), small.nearestCopy(dog, .at(-3000, -800)));
    // A tie, half a park away, goes east.
    try testing.expectEqual(PlanePoint.at(1010, 300), small.nearestCopy(dog, .at(510, 300)));
    try testing.expectEqual(PlanePoint.at(10, 300), small.nearestCopy(dog, .at(509, 300)));
    // Every copy wraps back to the dog.
    try testing.expectEqual(dog, small.wrap(small.nearestCopy(dog, .at(-3000, -800))));
}

test "a plane rectangle inside the park is one piece, with no offset" {
    var into: [16]Piece = undefined;
    const ps = piecesOf(.{ .top_left = .at(100, 100), .size = .{ .width = 300, .height = 200 } }, &into);
    try testing.expectEqual(@as(usize, 1), ps.len);
    try testing.expectEqual(Piece{ .region = .{ .top_left = .at(100, 100), .size = .{ .width = 300, .height = 200 } }, .offset = .none }, ps[0]);
}

test "the seam: across the east edge, the north edge, and a corner" {
    var into: [16]Piece = undefined;
    const east = piecesOf(.{ .top_left = .at(900, 100), .size = .{ .width = 300, .height = 200 } }, &into);
    try testing.expectEqual(@as(usize, 2), east.len);
    try testing.expectEqual(Piece{ .region = .{ .top_left = .at(900, 100), .size = .{ .width = 100, .height = 200 } }, .offset = .none }, east[0]);
    try testing.expectEqual(Piece{ .region = .{ .top_left = .at(0, 100), .size = .{ .width = 200, .height = 200 } }, .offset = .{ .dx = 1000, .dy = 0 } }, east[1]);

    const north = piecesOf(.{ .top_left = .at(100, -50), .size = .{ .width = 300, .height = 200 } }, &into);
    try testing.expectEqual(@as(usize, 2), north.len);
    try testing.expectEqual(Piece{ .region = .{ .top_left = .at(100, 550), .size = .{ .width = 300, .height = 50 } }, .offset = .{ .dx = 0, .dy = -600 } }, north[0]);
    try testing.expectEqual(Piece{ .region = .{ .top_left = .at(100, 0), .size = .{ .width = 300, .height = 150 } }, .offset = .none }, north[1]);

    const corner = piecesOf(.{ .top_left = .at(-50, -50), .size = .{ .width = 300, .height = 200 } }, &into);
    try testing.expectEqual(@as(usize, 4), corner.len);
    var area: u64 = 0;
    for (corner) |p| area += @as(u64, p.region.size.width) * p.region.size.height;
    try testing.expectEqual(@as(u64, 300 * 200), area);
}

test "every piece is inside the park, and its offset carries it back into the rectangle" {
    var into: [64]Piece = undefined;
    const rects = [_]PlaneRect{
        .{ .top_left = .at(-50, -50), .size = .{ .width = 300, .height = 200 } },
        .{ .top_left = .at(950, 550), .size = .{ .width = 100, .height = 100 } },
        // Wider than the park: three tiles across, so dogs are drawn twice.
        .{ .top_left = .at(-1500, 100), .size = .{ .width = 2400, .height = 100 } },
        .{ .top_left = .at(-2000, -1200), .size = .{ .width = 1000, .height = 600 } },
    };
    for (rects) |r| {
        var area: u64 = 0;
        for (piecesOf(r, &into)) |p| {
            try testing.expect(p.region.size.width > 0 and p.region.size.height > 0);
            try testing.expect(small.holds(p.region.top_left) == .inside);
            const last: ParkPoint = .at(p.region.top_left.x.number() + p.region.size.width - 1, p.region.top_left.y.number() + p.region.size.height - 1);
            try testing.expect(small.holds(last) == .inside);
            try testing.expect(r.holds(p.toPlane(p.region.top_left)) == .inside);
            try testing.expect(r.holds(p.toPlane(last)) == .inside);
            area += @as(u64, p.region.size.width) * p.region.size.height;
        }
        try testing.expectEqual(@as(u64, r.size.width) * r.size.height, area);
    }
    // An empty rectangle has no pieces.
    try testing.expectEqual(@as(usize, 0), piecesOf(.{ .top_left = .at(0, 0), .size = .{ .width = 0, .height = 5 } }, &into).len);
}

test "a point inside the park, and one past two of its edges, by how much" {
    try testing.expectEqual(Containment.inside, small.holds(.at(0, 0)));
    try testing.expectEqual(Containment.inside, small.holds(.at(999, 599)));
    const out = small.holds(.at(-5, 610));
    try testing.expectEqual(Overhang{ .left = 5, .top = 0, .right = 0, .bottom = 11 }, out.outside);
    // The right and bottom edges are outside: the rectangle is half-open.
    try testing.expect(small.holds(.at(1000, 0)) == .outside);
    try testing.expect(small.holds(.at(0, 600)) == .outside);
}

test "holding a point at the coordinate's edge does not overflow" {
    const r: ParkRect = .{ .top_left = .at(std.math.minInt(Coord), 0), .size = .{ .width = 0, .height = 0 } };
    try testing.expect(r.holds(.at(std.math.maxInt(Coord), 0)) == .outside);
}

test "the lattice: spots 100 apart, the first half a spacing in, every one inside" {
    try testing.expectEqual(LatticeExtent{ .columns = 10, .rows = 6 }, small.extent());
    try testing.expectEqual(ParkPoint.at(50, 50), small.pointOf(.{ .column = 0, .row = 0 }).on.point);
    try testing.expectEqual(ParkPoint.at(950, 550), small.pointOf(.{ .column = 9, .row = 5 }).on.point);
    try testing.expectEqual(SpotPoint.off_park, small.pointOf(.{ .column = 10, .row = 0 }));
    // A spot of a bigger park, or at the column's edge, is off this one.
    try testing.expectEqual(SpotPoint.off_park, small.pointOf(.{ .column = std.math.maxInt(u31), .row = 0 }));
    var column: u31 = 0;
    while (column < small.extent().columns) : (column += 1) {
        var row: u31 = 0;
        while (row < small.extent().rows) : (row += 1) {
            try testing.expect(small.holds(small.pointOf(.{ .column = column, .row = row }).on.point) == .inside);
        }
    }
}

test "a rectangle grown by a margin keeps its centre" {
    const r: PlaneRect = .{ .top_left = .at(100, 100), .size = .{ .width = 50, .height = 40 } };
    const g = r.grownBy(10);
    try testing.expectEqual(PlanePoint.at(90, 90), g.top_left);
    try testing.expectEqual(Size{ .width = 70, .height = 60 }, g.size);
}

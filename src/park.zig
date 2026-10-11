//! The park: a finite rectangle of the park's frame, from (0, 0) to its size,
//! and the lattice the dogs are first placed on.
//!
//! **TWO NAMING FENCES.** Zig has no private fields, so a literal can build
//! anything. `InParkPoint` and `LatticeSpot` are made by `Park` alone
//! (`clamp`, `spot`, `pointOf`), and a literal of either outside this file is
//! the bug, visible by name in review.

const std = @import("std");
const frames = @import("frames.zig");
const ParkPoint = frames.ParkPoint;
const Size = frames.Size;
const Coord = frames.Coord;

/// A rectangle of the park: its top-left corner and its size. Half-open:
/// a point on the right or bottom edge is outside.
pub const ParkRect = struct {
    top_left: ParkPoint,
    size: Size,

    /// The corner just past the rectangle: itself outside it.
    pub fn pastBottomRight(self: ParkRect) ParkPoint {
        return self.top_left.plus(.{ .dx = self.size.width, .dy = self.size.height });
    }

    pub fn holds(self: ParkRect, p: ParkPoint) Containment {
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

    /// The rectangle grown by `margin` on every side.
    pub fn grownBy(self: ParkRect, margin: u31) ParkRect {
        return .{
            .top_left = self.top_left.plus(.{ .dx = -@as(Coord, margin), .dy = -@as(Coord, margin) }),
            .size = .{ .width = self.size.width +| margin +| margin, .height = self.size.height +| margin +| margin },
        };
    }
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

/// A point the park holds. Made only by `Park.clamp` and `Park.pointOf`;
/// a dog stands only on one of these.
pub const InParkPoint = struct {
    point: ParkPoint,
};

/// How far apart the lattice's spots are, and how big the smallest park is
/// (one spot). One lattice for every park, so a spacing of 0 is not a value.
pub const lattice_spacing: u31 = 100;

/// The park. Its frame's origin is its top-left corner, so its bounds are
/// (0, 0) to its size; a park has no other top-left. Made by `Park.of`,
/// which refuses a park too small to hold one lattice spot.
pub const Park = struct {
    size: Size,

    pub fn of(size: Size) Sized {
        if (size.width < lattice_spacing or size.height < lattice_spacing) return .too_small;
        return .{ .park = .{ .size = size } };
    }

    pub fn bounds(self: Park) ParkRect {
        return .{ .top_left = .at(0, 0), .size = self.size };
    }

    pub fn holds(self: Park, p: ParkPoint) Containment {
        return self.bounds().holds(p);
    }

    /// `p` brought inside the park, and whether it had to be.
    pub fn clamp(self: Park, p: ParkPoint) Clamped {
        switch (self.holds(p)) {
            .inside => return .{ .inside = .{ .point = p } },
            .outside => {
                const kept: ParkPoint = .at(
                    std.math.clamp(p.x.number(), 0, @as(Coord, self.size.width) - 1),
                    std.math.clamp(p.y.number(), 0, @as(Coord, self.size.height) - 1),
                );
                return .{ .clamped = .{ .asked = p, .kept = .{ .point = kept } } };
            },
        }
    }

    /// How many lattice spots fit across and down.
    pub fn extent(self: Park) LatticeExtent {
        return .{ .columns = self.size.width / lattice_spacing, .rows = self.size.height / lattice_spacing };
    }

    /// The spot at `column` and `row`, if the park reaches that far.
    pub fn spot(self: Park, column: u31, row: u31) SpotOrOff {
        const e = self.extent();
        if (column >= e.columns or row >= e.rows) return .off_park;
        return .{ .on = .{ .column = column, .row = row } };
    }

    /// Where a spot stands: half a spacing in from its cell's corner, so no
    /// spot is on an edge.
    pub fn pointOf(self: Park, s: LatticeSpot) InParkPoint {
        _ = self;
        const half = lattice_spacing / 2;
        return .{ .point = .at(
            half + @as(Coord, s.column) *| lattice_spacing,
            half + @as(Coord, s.row) *| lattice_spacing,
        ) };
    }
};

pub const Sized = union(enum) {
    park: Park,
    too_small,
};

/// A point brought inside the park: already inside, or moved to its edge.
pub const Clamped = union(enum) {
    inside: InParkPoint,
    clamped: Clamping,

    pub fn point(self: Clamped) InParkPoint {
        return switch (self) {
            .inside => |p| p,
            .clamped => |c| c.kept,
        };
    }
};

/// What the park did to a point outside it: the point asked for, and the
/// nearest it holds.
pub const Clamping = struct {
    asked: ParkPoint,
    kept: InParkPoint,
};

pub const LatticeExtent = struct { columns: u31, rows: u31 };

/// A spot on the lattice, by column and row from the park's top-left.
/// Made only by `Park.spot`.
pub const LatticeSpot = struct {
    column: u31,
    row: u31,
};

pub const SpotOrOff = union(enum) {
    on: LatticeSpot,
    off_park,
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const small: Park = (Park.of(.{ .width = 1000, .height = 600 })).park;

test "a park too small for one lattice spot is not made" {
    try testing.expectEqual(Sized.too_small, Park.of(.{ .width = 0, .height = 600 }));
    try testing.expectEqual(Sized.too_small, Park.of(.{ .width = 1000, .height = lattice_spacing - 1 }));
}

test "a point inside the park, and one past two of its edges, by how much" {
    try testing.expectEqual(Containment.inside, small.holds(.at(0, 0)));
    try testing.expectEqual(Containment.inside, small.holds(.at(999, 599)));
    const out = small.holds(.at(-5, 610));
    try testing.expectEqual(Overhang{ .left = 5, .top = 0, .right = 0, .bottom = 11 }, out.outside);
    // The right and bottom edges are outside: the rectangle is half-open.
    try testing.expect(small.holds(.at(1000, 0)) == .outside);
    try testing.expect(small.holds(small.bounds().pastBottomRight()) == .outside);
}

test "holding a point at the coordinate's edge does not overflow" {
    const r: ParkRect = .{ .top_left = .at(std.math.minInt(Coord), 0), .size = .{ .width = 0, .height = 0 } };
    try testing.expect(r.holds(.at(std.math.maxInt(Coord), 0)) == .outside);
}

test "clamping says whether it moved the point, and keeps it in the park" {
    const in: ParkPoint = .at(10, 10);
    try testing.expectEqual(Clamped{ .inside = .{ .point = in } }, small.clamp(in));
    const c = small.clamp(.at(2000, -40));
    try testing.expectEqual(ParkPoint.at(999, 0), c.clamped.kept.point);
    try testing.expectEqual(ParkPoint.at(2000, -40), c.clamped.asked);
    try testing.expect(small.holds(c.point().point) == .inside);
}

test "the lattice: spots 100 apart, the first half a spacing in, every one inside" {
    try testing.expectEqual(LatticeExtent{ .columns = 10, .rows = 6 }, small.extent());
    try testing.expectEqual(ParkPoint.at(50, 50), small.pointOf(small.spot(0, 0).on).point);
    try testing.expectEqual(ParkPoint.at(950, 550), small.pointOf(small.spot(9, 5).on).point);
    try testing.expectEqual(SpotOrOff.off_park, small.spot(10, 0));
    var column: u31 = 0;
    while (column < small.extent().columns) : (column += 1) {
        var row: u31 = 0;
        while (row < small.extent().rows) : (row += 1) {
            try testing.expect(small.holds(small.pointOf(small.spot(column, row).on).point) == .inside);
        }
    }
}

test "a rectangle grown by a margin keeps its centre" {
    const r: ParkRect = .{ .top_left = .at(100, 100), .size = .{ .width = 50, .height = 40 } };
    const g = r.grownBy(10);
    try testing.expectEqual(ParkPoint.at(90, 90), g.top_left);
    try testing.expectEqual(Size{ .width = 70, .height = 60 }, g.size);
    // A margin as wide as any saturates, without overflowing.
    _ = r.grownBy(std.math.maxInt(u31));
}

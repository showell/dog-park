//! The park: a finite rectangle of the park's frame, from (0, 0) to its size,
//! and the lattice the dogs were first placed on.

const std = @import("std");
const frames = @import("frames.zig");
const ParkPoint = frames.ParkPoint;
const Size = frames.Size;
const Displacement = frames.Displacement;

/// A rectangle of the park: its top-left corner and its size. Half-open:
/// a point on the right or bottom edge is outside.
pub const ParkRect = struct {
    top_left: ParkPoint,
    size: Size,

    pub fn bottomRight(self: ParkRect) ParkPoint {
        return self.top_left.plus(.{ .dx = self.size.width, .dy = self.size.height });
    }

    pub fn holds(self: ParkRect, p: ParkPoint) Containment {
        const br = self.bottomRight();
        const over: Overhang = .{
            .left = @max(0, self.top_left.x -| p.x),
            .top = @max(0, self.top_left.y -| p.y),
            .right = @max(0, p.x -| (br.x - 1)),
            .bottom = @max(0, p.y -| (br.y - 1)),
        };
        if (over.left == 0 and over.top == 0 and over.right == 0 and over.bottom == 0) return .inside;
        return .{ .outside = over };
    }

    /// The rectangle grown by `margin` on every side.
    pub fn grownBy(self: ParkRect, margin: u31) ParkRect {
        return .{
            .top_left = self.top_left.plus(.{ .dx = -@as(frames.Coord, margin), .dy = -@as(frames.Coord, margin) }),
            .size = .{ .width = self.size.width +| 2 * margin, .height = self.size.height +| 2 * margin },
        };
    }
};

/// Where a point is, against a rectangle: inside, or outside by how much on
/// each side (at most two of the four are not zero).
pub const Containment = union(enum) {
    inside,
    outside: Overhang,
};

/// How far past each edge a point is.
pub const Overhang = struct {
    left: frames.Coord,
    top: frames.Coord,
    right: frames.Coord,
    bottom: frames.Coord,
};

/// The park. Its frame's origin is its top-left corner, so its bounds are
/// (0, 0) to its size; a park has no other top-left.
pub const Park = struct {
    size: Size,
    lattice: Lattice,

    pub fn bounds(self: Park) ParkRect {
        return .{ .top_left = .{ .x = 0, .y = 0 }, .size = self.size };
    }

    pub fn holds(self: Park, p: ParkPoint) Containment {
        return self.bounds().holds(p);
    }

    /// `p` brought inside the park, and whether it had to be.
    pub fn clamp(self: Park, p: ParkPoint) Clamped {
        switch (self.holds(p)) {
            .inside => return .{ .inside = p },
            .outside => {
                const kept: ParkPoint = .{
                    // A park with no width keeps x at 0 (it is outside, but nowhere is inside).
                    .x = std.math.clamp(p.x, 0, @max(0, @as(frames.Coord, self.size.width) - 1)),
                    .y = std.math.clamp(p.y, 0, @max(0, @as(frames.Coord, self.size.height) - 1)),
                };
                return .{ .clamped = .{ .asked = p, .kept = kept } };
            },
        }
    }
};

/// A point brought inside the park: already inside, or moved to its edge.
pub const Clamped = union(enum) {
    inside: ParkPoint,
    clamped: struct { asked: ParkPoint, kept: ParkPoint },

    pub fn point(self: Clamped) ParkPoint {
        return switch (self) {
            .inside => |p| p,
            .clamped => |c| c.kept,
        };
    }
};

/// The grid the dogs were first placed on: spots `spacing` apart, the first
/// a half-spacing in from the park's corner, so no spot is on an edge.
pub const Lattice = struct {
    spacing: u31,

    pub const usual: Lattice = .{ .spacing = 100 };

    /// How many spots fit across and down a park of `size`.
    pub fn extent(self: Lattice, size: Size) LatticeExtent {
        return .{ .columns = size.width / self.spacing, .rows = size.height / self.spacing };
    }

    pub fn pointOf(self: Lattice, spot: LatticeSpot) ParkPoint {
        const half = self.spacing / 2;
        return .{
            .x = @as(frames.Coord, half) + @as(frames.Coord, spot.column) * self.spacing,
            .y = @as(frames.Coord, half) + @as(frames.Coord, spot.row) * self.spacing,
        };
    }
};

pub const LatticeExtent = struct { columns: u31, rows: u31 };

/// A spot on the lattice, by column and row from the park's top-left.
pub const LatticeSpot = struct {
    column: u31,
    row: u31,
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const small: Park = .{ .size = .{ .width = 1000, .height = 600 }, .lattice = Lattice.usual };

test "a point inside the park, and one past two of its edges, by how much" {
    try testing.expectEqual(Containment.inside, small.holds(.{ .x = 0, .y = 0 }));
    try testing.expectEqual(Containment.inside, small.holds(.{ .x = 999, .y = 599 }));
    const out = small.holds(.{ .x = -5, .y = 610 });
    try testing.expectEqual(Overhang{ .left = 5, .top = 0, .right = 0, .bottom = 11 }, out.outside);
    // The right and bottom edges are outside: the rectangle is half-open.
    try testing.expect(small.holds(.{ .x = 1000, .y = 0 }) == .outside);
}

test "clamping says whether it moved the point" {
    const in: ParkPoint = .{ .x = 10, .y = 10 };
    try testing.expectEqual(Clamped{ .inside = in }, small.clamp(in));
    const c = small.clamp(.{ .x = 2000, .y = -40 });
    try testing.expectEqual(ParkPoint{ .x = 999, .y = 0 }, c.clamped.kept);
    try testing.expectEqual(ParkPoint{ .x = 999, .y = 0 }, c.point());
    try testing.expect(small.holds(c.point()) == .inside);
}

test "the lattice: spots 100 apart, the first half a spacing in, none on an edge" {
    try testing.expectEqual(LatticeExtent{ .columns = 10, .rows = 6 }, Lattice.usual.extent(small.size));
    try testing.expectEqual(ParkPoint{ .x = 50, .y = 50 }, Lattice.usual.pointOf(.{ .column = 0, .row = 0 }));
    try testing.expectEqual(ParkPoint{ .x = 950, .y = 550 }, Lattice.usual.pointOf(.{ .column = 9, .row = 5 }));
    try testing.expect(small.holds(Lattice.usual.pointOf(.{ .column = 9, .row = 5 })) == .inside);
}

test "a rectangle grown by a margin keeps its centre" {
    const r: ParkRect = .{ .top_left = .{ .x = 100, .y = 100 }, .size = .{ .width = 50, .height = 40 } };
    const g = r.grownBy(10);
    try testing.expectEqual(ParkPoint{ .x = 90, .y = 90 }, g.top_left);
    try testing.expectEqual(Size{ .width = 70, .height = 60 }, g.size);
}

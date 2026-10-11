//! Frames of reference. Every point says, by its type, which frame it is in,
//! and so does each of its coordinates: a viewport point where a park point
//! is meant does not compile, and neither does a park point built from a
//! viewport point's numbers.
//!
//! **ONE SCALE.** A park unit is one CSS pixel at the browser's zoom 1: the
//! frames differ only by where their origin is, never by scale or axes
//! (x right, y down, as the browser's). So a displacement is the same in
//! every frame, and one type serves them all.
//!
//! **THE PARK WRAPS** (docs/WRAP-AMENDMENT.md): it tiles an infinite plane,
//! Pac-Man style. A dog's canonical place is in the park; the viewport, and
//! the copies of dogs it draws, are in the plane. A park point plus a
//! displacement is a plane point, since a move may leave the park's tile;
//! `park.Park.wrap` brings a plane point home.

const std = @import("std");

pub const Frame = enum {
    /// The world, once: its origin is the park's top-left corner, and it
    /// ends at the park's size.
    park,
    /// The infinite plane the park tiles: its origin is the park's, and the
    /// copy of the park one tile east starts at (width, 0).
    plane,
    /// What the human sees; its origin is the viewport's top-left corner.
    viewport,
    /// Centred on the human's own dog.
    own_dog,
};

/// The number inside a coordinate or a displacement. **ARITHMETIC ON IT IS
/// PLAIN, AND OVERFLOW IS A PANIC**: the park's longest side, the wire's
/// checks and the longest drag keep every point a request makes within a few
/// million of the origin, so an overflow is a bug, and it is said, never
/// saturated away.
pub const Coord = i32;

/// One coordinate in `frame`: a number that says its frame, so it cannot be
/// copied into another frame's point, nor done arithmetic with directly.
pub fn Coordinate(comptime frame: Frame) type {
    return enum(Coord) {
        _,

        pub const frame_of = frame;

        pub fn of(n: Coord) @This() {
            return @enumFromInt(n);
        }

        pub fn number(self: @This()) Coord {
            return @intFromEnum(self);
        }
    };
}

/// A position in `frame`. Points in different frames are different types.
/// A point plus a displacement is a point; a point minus a point is a
/// displacement; a point plus a point has no meaning, and no function.
pub fn Point(comptime frame: Frame) type {
    return struct {
        x: C,
        y: C,

        pub const frame_of = frame;
        const C = Coordinate(frame);
        const Self = @This();

        /// The point at these numbers, which are in this frame: the one
        /// place a raw number becomes a point, so it can be looked for.
        pub fn at(x: Coord, y: Coord) Self {
            return .{ .x = .of(x), .y = .of(y) };
        }

        /// Where a displacement from a point of this frame lands: in the
        /// plane, from the park (a move may leave the park's tile), and in
        /// this frame from any other.
        pub const Landing = if (frame == .park) Point(.plane) else Self;

        pub fn plus(self: Self, d: Displacement) Landing {
            return Landing.at(self.x.number() + d.dx, self.y.number() + d.dy);
        }

        /// The displacement that takes `from` to `self`.
        pub fn minus(self: Self, from: Self) Displacement {
            return .{ .dx = self.x.number() - from.x.number(), .dy = self.y.number() - from.y.number() };
        }
    };
}

pub const ParkPoint = Point(.park);
pub const PlanePoint = Point(.plane);
pub const ViewportPoint = Point(.viewport);
pub const OwnDogPoint = Point(.own_dog);

/// A move from one point to another, in any frame (they share a scale).
/// A drag's dx/dy is one of these.
pub const Displacement = struct {
    dx: Coord,
    dy: Coord,

    pub const none: Displacement = .{ .dx = 0, .dy = 0 };

    pub fn plus(self: Displacement, other: Displacement) Displacement {
        return .{ .dx = self.dx + other.dx, .dy = self.dy + other.dy };
    }

    pub fn reversed(self: Displacement) Displacement {
        return .{ .dx = -self.dx, .dy = -self.dy };
    }
};

/// A width and a height, never negative.
pub const Size = struct {
    width: u31,
    height: u31,
};

/// The copy of a park point on the plane's home tile, where the two frames'
/// origins agree: chosen without regard to where anything else is, so it
/// is seldom the copy meant (`park.Park.nearestCopy`, `park.Piece.toPlane`).
pub fn homeCopy(p: ParkPoint) PlanePoint {
    return .at(p.x.number(), p.y.number());
}

/// The region of the plane the human sees: its top-left in the plane, and
/// its size. The conversion between the viewport's frame and the plane's.
pub const Viewport = struct {
    origin: PlanePoint,
    size: Size,

    pub fn toPlane(self: Viewport, p: ViewportPoint) PlanePoint {
        return self.origin.plus(p.minus(.at(0, 0)));
    }

    pub fn fromPlane(self: Viewport, p: PlanePoint) ViewportPoint {
        return ViewportPoint.at(0, 0).plus(p.minus(self.origin));
    }

    pub fn centre(self: Viewport) PlanePoint {
        return self.origin.plus(.{ .dx = self.size.width / 2, .dy = self.size.height / 2 });
    }

    /// The viewport moved by `d`, its size kept: what auto-scrolling does.
    pub fn scrolled(self: Viewport, d: Displacement) Viewport {
        return .{ .origin = self.origin.plus(d), .size = self.size };
    }
};

/// Where the human's own dog is drawn in the plane: the conversion between
/// the own-dog frame and the plane's. Made by `dogs.Drawn.frame`: one from
/// any other plane point is the bug, visible by name.
pub const OwnDogFrame = struct {
    dog_at: PlanePoint,

    pub fn toPlane(self: OwnDogFrame, p: OwnDogPoint) PlanePoint {
        return self.dog_at.plus(p.minus(.at(0, 0)));
    }

    pub fn fromPlane(self: OwnDogFrame, p: PlanePoint) OwnDogPoint {
        return OwnDogPoint.at(0, 0).plus(p.minus(self.dog_at));
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a point plus a displacement, and a point minus a point" {
    const a: PlanePoint = .at(100, 200);
    const d: Displacement = .{ .dx = 7, .dy = -3 };
    try testing.expectEqual(PlanePoint.at(107, 197), a.plus(d));
    try testing.expectEqual(d, a.plus(d).minus(a));
    try testing.expectEqual(Displacement.none, a.minus(a));
}

test "a park point plus a displacement is a plane point: a move may leave the park" {
    const a: ParkPoint = .at(100, 200);
    try testing.expect(@TypeOf(a.plus(.none)) == PlanePoint);
    try testing.expectEqual(PlanePoint.at(-5, 200), a.plus(.{ .dx = -105, .dy = 0 }));
    try testing.expectEqual(homeCopy(a), a.plus(.none));
    try testing.expectEqual(Displacement{ .dx = 3, .dy = 4 }, ParkPoint.at(103, 204).minus(a));
}

test "the frames are distinct types, and so are their coordinates" {
    try testing.expect(ParkPoint != ViewportPoint);
    try testing.expect(ParkPoint != PlanePoint);
    try testing.expect(PlanePoint != ViewportPoint);
    try testing.expect(ParkPoint != OwnDogPoint);
    try testing.expect(ViewportPoint != OwnDogPoint);
    // `.{ .x = seen.x }` for a park point does not compile: the fields differ.
    try testing.expect(@FieldType(ParkPoint, "x") != @FieldType(ViewportPoint, "x"));
    try testing.expect(@FieldType(ParkPoint, "x") != Coord);
}

test "one scale: two viewport points' difference moves a park point as far" {
    const a: ViewportPoint = .at(10, 10);
    const b: ViewportPoint = .at(40, 30);
    try testing.expectEqual(PlanePoint.at(130, 120), ParkPoint.at(100, 100).plus(b.minus(a)));
}

test "the viewport's frame and the plane's, both ways, on any tile" {
    const v: Viewport = .{ .origin = .at(-1000, 500), .size = .{ .width = 800, .height = 600 } };
    const seen: ViewportPoint = .at(40, 60);
    try testing.expectEqual(PlanePoint.at(-960, 560), v.toPlane(seen));
    try testing.expectEqual(seen, v.fromPlane(v.toPlane(seen)));
    const dog: PlanePoint = .at(1234, 987);
    try testing.expectEqual(dog, v.toPlane(v.fromPlane(dog)));
    // The viewport's own corner is the origin in its frame.
    try testing.expectEqual(ViewportPoint.at(0, 0), v.fromPlane(v.origin));
    try testing.expectEqual(PlanePoint.at(-600, 800), v.centre());
}

test "the own-dog frame and the plane's, both ways" {
    const f: OwnDogFrame = .{ .dog_at = .at(300, 400) };
    try testing.expectEqual(OwnDogPoint.at(0, 0), f.fromPlane(f.dog_at));
    const near: OwnDogPoint = .at(-50, 25);
    try testing.expectEqual(PlanePoint.at(250, 425), f.toPlane(near));
    try testing.expectEqual(near, f.fromPlane(f.toPlane(near)));
}

test "scrolling moves the origin, and what a plane point looks like moves the other way" {
    const v: Viewport = .{ .origin = .at(0, 0), .size = .{ .width = 100, .height = 100 } };
    const dog: PlanePoint = .at(50, 50);
    const after = v.scrolled(.{ .dx = 10, .dy = 0 });
    try testing.expectEqual(ViewportPoint.at(40, 50), after.fromPlane(dog));
}

//! Frames of reference. Every point says, by its type, which frame it is in,
//! so a viewport point where a park point is meant does not compile.
//!
//! **ONE SCALE.** A park unit is one CSS pixel at the browser's zoom 1: the
//! frames differ only by where their origin is, never by scale or axes
//! (x right, y down, as the browser's). So a displacement is the same in
//! every frame, and one type serves them all.

const std = @import("std");

pub const Frame = enum {
    /// The whole world; its origin is the park's top-left corner.
    park,
    /// What the human sees; its origin is the viewport's top-left corner.
    viewport,
    /// Centred on the human's own dog.
    own_dog,
};

/// A coordinate. Wide enough for any park; arithmetic saturates rather than
/// wrapping, and the park clamps what saturates (park.zig).
pub const Coord = i32;

/// A position in `frame`. Points in different frames are different types.
/// A point plus a displacement is a point; a point minus a point is a
/// displacement; a point plus a point has no meaning, and no function.
pub fn Point(comptime frame: Frame) type {
    return struct {
        x: Coord,
        y: Coord,

        pub const frame_of = frame;
        const Self = @This();

        pub fn plus(self: Self, d: Displacement) Self {
            return .{ .x = self.x +| d.dx, .y = self.y +| d.dy };
        }

        /// The displacement that takes `from` to `self`.
        pub fn minus(self: Self, from: Self) Displacement {
            return .{ .dx = self.x -| from.x, .dy = self.y -| from.y };
        }
    };
}

pub const ParkPoint = Point(.park);
pub const ViewportPoint = Point(.viewport);
pub const OwnDogPoint = Point(.own_dog);

/// A move from one point to another, in any frame (they share a scale).
/// A drag's dx/dy is one of these.
pub const Displacement = struct {
    dx: Coord,
    dy: Coord,

    pub const none: Displacement = .{ .dx = 0, .dy = 0 };

    pub fn plus(self: Displacement, other: Displacement) Displacement {
        return .{ .dx = self.dx +| other.dx, .dy = self.dy +| other.dy };
    }

    pub fn reversed(self: Displacement) Displacement {
        return .{ .dx = 0 -| self.dx, .dy = 0 -| self.dy };
    }
};

/// A width and a height, never negative.
pub const Size = struct {
    width: u31,
    height: u31,
};

/// The park's region the human sees: its top-left in the park, and its size.
/// The conversion between the viewport's frame and the park's.
pub const Viewport = struct {
    origin: ParkPoint,
    size: Size,

    pub fn toPark(self: Viewport, p: ViewportPoint) ParkPoint {
        return self.origin.plus(.{ .dx = p.x, .dy = p.y });
    }

    pub fn fromPark(self: Viewport, p: ParkPoint) ViewportPoint {
        const d = p.minus(self.origin);
        return .{ .x = d.dx, .y = d.dy };
    }

    /// The viewport moved by `d`, its size kept: what auto-scrolling does.
    pub fn scrolled(self: Viewport, d: Displacement) Viewport {
        return .{ .origin = self.origin.plus(d), .size = self.size };
    }
};

/// Where the human's own dog stands in the park: the conversion between the
/// own-dog frame and the park's.
pub const OwnDogFrame = struct {
    dog_at: ParkPoint,

    pub fn toPark(self: OwnDogFrame, p: OwnDogPoint) ParkPoint {
        return self.dog_at.plus(.{ .dx = p.x, .dy = p.y });
    }

    pub fn fromPark(self: OwnDogFrame, p: ParkPoint) OwnDogPoint {
        const d = p.minus(self.dog_at);
        return .{ .x = d.dx, .y = d.dy };
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a point plus a displacement, and a point minus a point" {
    const a: ParkPoint = .{ .x = 100, .y = 200 };
    const d: Displacement = .{ .dx = 7, .dy = -3 };
    try testing.expectEqual(ParkPoint{ .x = 107, .y = 197 }, a.plus(d));
    try testing.expectEqual(d, a.plus(d).minus(a));
    try testing.expectEqual(Displacement.none, a.minus(a));
}

test "the frames are distinct types" {
    try testing.expect(ParkPoint != ViewportPoint);
    try testing.expect(ParkPoint != OwnDogPoint);
    try testing.expect(ViewportPoint != OwnDogPoint);
}

test "the viewport's frame and the park's, both ways" {
    const v: Viewport = .{ .origin = .{ .x = 1000, .y = 500 }, .size = .{ .width = 800, .height = 600 } };
    const seen: ViewportPoint = .{ .x = 40, .y = 60 };
    try testing.expectEqual(ParkPoint{ .x = 1040, .y = 560 }, v.toPark(seen));
    try testing.expectEqual(seen, v.fromPark(v.toPark(seen)));
    // The viewport's own corner is the origin in its frame.
    try testing.expectEqual(ViewportPoint{ .x = 0, .y = 0 }, v.fromPark(v.origin));
}

test "the own-dog frame and the park's, both ways" {
    const f: OwnDogFrame = .{ .dog_at = .{ .x = 300, .y = 400 } };
    try testing.expectEqual(OwnDogPoint{ .x = 0, .y = 0 }, f.fromPark(f.dog_at));
    const near: OwnDogPoint = .{ .x = -50, .y = 25 };
    try testing.expectEqual(ParkPoint{ .x = 250, .y = 425 }, f.toPark(near));
    try testing.expectEqual(near, f.fromPark(f.toPark(near)));
}

test "scrolling moves the origin, and what a park point looks like moves the other way" {
    const v: Viewport = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 100, .height = 100 } };
    const dog: ParkPoint = .{ .x = 50, .y = 50 };
    const after = v.scrolled(.{ .dx = 10, .dy = 0 });
    try testing.expectEqual(ViewportPoint{ .x = 40, .y = 50 }, after.fromPark(dog));
}

test "arithmetic saturates at the coordinate's edge, never wraps" {
    const far: ParkPoint = .{ .x = std.math.maxInt(Coord), .y = 0 };
    try testing.expectEqual(std.math.maxInt(Coord), far.plus(.{ .dx = 1, .dy = 0 }).x);
}

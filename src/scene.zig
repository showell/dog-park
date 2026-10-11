//! A scene: what one request asks to see, and what it gets back to render.
//! ("Scene", not "frame": a frame here is always a frame of reference.)

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const population = @import("population.zig");
const outcomes = @import("outcomes.zig");

/// What the human's dog does in this request: stays, or is dragged by a
/// displacement (in the own-dog frame, which is every frame's scale).
/// A drag is never of `Displacement.none`: `of` makes that a stay.
pub const Move = union(enum) {
    stay,
    drag: frames.Displacement,

    pub fn of(d: frames.Displacement) Move {
        if (std.meta.eql(d, frames.Displacement.none)) return .stay;
        return .{ .drag = d };
    }
};

/// One request: where the viewport is in the plane, and the move.
pub const SceneRequest = struct {
    viewport: frames.Viewport,
    move: Move,
};

/// How far past the viewport a scene reaches on every side, so some
/// scrolling needs no new request.
pub const margin: u31 = 200;

/// What a request gets back. The dogs are copies in the plane: the browser
/// scrolls within the margin without asking, so it places them through its
/// own current viewport (frames.Viewport.fromPlane), not the one asked with.
pub const Scene = struct {
    /// The viewport asked with; what the scene covers follows from it.
    viewport: frames.Viewport,
    /// The human's own dog, apart from the others, so no flag marks it: its
    /// copy nearest the viewport's centre.
    own: dogs.Drawn,
    /// Every copy of every other dog in `covers()` (a park narrower than the
    /// covered rectangle shows a dog more than once); never the own dog
    /// (population.Near.except).
    others: []const dogs.Drawn,
    others_completeness: population.Completeness,
    park_size: frames.Size,
    /// What became of this request's move; `own` is where it left the dog.
    move: outcomes.MoveOutcome,

    /// The viewport asked for, grown by `margin`: the others are those in it.
    pub fn covers(self: Scene) park.PlaneRect {
        return coverFor(self.viewport);
    }
};

/// The region a scene covers, for the viewport it was asked with.
pub fn coverFor(v: frames.Viewport) park.PlaneRect {
    return (park.PlaneRect{ .top_left = v.origin, .size = v.size }).grownBy(margin);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a move is a stay or a drag, never both: a drag of nothing is a stay" {
    try testing.expectEqual(Move.stay, Move.of(frames.Displacement.none));
    try testing.expectEqual(Move{ .drag = .{ .dx = 3, .dy = 0 } }, Move.of(.{ .dx = 3, .dy = 0 }));
}

test "a scene covers the viewport and its margin" {
    const v: frames.Viewport = .{ .origin = .at(1000, 1000), .size = .{ .width = 800, .height = 600 } };
    const c = coverFor(v);
    try testing.expectEqual(frames.PlanePoint.at(800, 800), c.top_left);
    try testing.expectEqual(frames.Size{ .width = 1200, .height = 1000 }, c.size);
    // The viewport's own corner is inside what it covers.
    try testing.expect(c.holds(v.origin) == .inside);
}

test "a viewport at the park's corner covers past the seam, and that is fine" {
    const v: frames.Viewport = .{ .origin = .at(0, 0), .size = .{ .width = 800, .height = 600 } };
    try testing.expectEqual(frames.PlanePoint.at(-200, -200), coverFor(v).top_left);
}

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

/// One request: where the viewport is in the park, and the move.
pub const SceneRequest = struct {
    viewport: frames.Viewport,
    move: Move,
};

/// How far past the viewport a scene reaches on every side, so some
/// scrolling needs no new request.
pub const margin: u31 = 200;

/// What a request gets back. The dogs are in the park's frame: the browser
/// scrolls within the margin without asking, so it places them through its
/// own current viewport (frames.Viewport.fromPark), not the one asked with.
pub const Scene = struct {
    /// The viewport asked with; what the scene covers follows from it.
    viewport: frames.Viewport,
    /// The human's own dog, apart from the others, so no flag marks it.
    own: dogs.Drawn,
    /// The other dogs in `covers()`: never the own dog (population.Near.except).
    others: []const dogs.Dog,
    others_completeness: population.Completeness,
    park_size: frames.Size,
    /// What became of this request's move; `own` is where it left the dog.
    move: outcomes.MoveOutcome,

    /// The viewport asked for, grown by `margin`: the others are those in it.
    pub fn covers(self: Scene) park.ParkRect {
        return coverFor(self.viewport);
    }
};

/// What a request gets: its scene, or, for a human with no dog yet whose
/// dog could not be placed, why not. A human with no dog has one placed
/// before the scene, so a scene always has an own dog.
pub const SceneAnswer = union(enum) {
    scene: Scene,
    no_room: outcomes.PlacementRefusal,
};

/// The region a scene covers, for the viewport it was asked with.
pub fn coverFor(v: frames.Viewport) park.ParkRect {
    return (park.ParkRect{ .top_left = v.origin, .size = v.size }).grownBy(margin);
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
    try testing.expectEqual(frames.ParkPoint.at(800, 800), c.top_left);
    try testing.expectEqual(frames.Size{ .width = 1200, .height = 1000 }, c.size);
    // The viewport's own corner is inside what it covers.
    try testing.expect(c.holds(v.origin) == .inside);
}

test "a viewport at the park's corner covers past the park's edge, and that is fine" {
    const v: frames.Viewport = .{ .origin = .at(0, 0), .size = .{ .width = 800, .height = 600 } };
    try testing.expectEqual(frames.ParkPoint.at(-200, -200), coverFor(v).top_left);
}

//! A scene: what one request asks to see, and what it gets back to render.
//! ("Scene", not "frame": a frame here is always a frame of reference.)

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");

/// What the human's dog does in this request: stays, or is dragged by a
/// displacement (in the own-dog frame, which is every frame's scale).
pub const Move = union(enum) {
    stay,
    drag: frames.Displacement,

    /// Where the dog asks to be after this move, from where it is.
    pub fn target(self: Move, from: frames.ParkPoint) frames.ParkPoint {
        return switch (self) {
            .stay => from,
            .drag => |d| from.plus(d),
        };
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
    /// The viewport asked for, grown by `margin`: the dogs are those in it.
    covers: park.ParkRect,
    /// The human's own dog, apart from the others, so no flag marks it.
    own: dogs.Dog,
    /// Every other dog in `covers`.
    others: []const dogs.Dog,
    others_completeness: @import("population.zig").Completeness,
    park_size: frames.Size,
};

/// The region a scene covers, for the viewport it was asked with.
pub fn coverFor(v: frames.Viewport) park.ParkRect {
    return (park.ParkRect{ .top_left = v.origin, .size = v.size }).grownBy(margin);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a move is a stay or a drag, never both" {
    const at: frames.ParkPoint = .{ .x = 100, .y = 100 };
    try testing.expectEqual(at, (Move{ .stay = {} }).target(at));
    try testing.expectEqual(frames.ParkPoint{ .x = 130, .y = 90 }, (Move{ .drag = .{ .dx = 30, .dy = -10 } }).target(at));
}

test "a scene covers the viewport and its margin" {
    const v: frames.Viewport = .{ .origin = .{ .x = 1000, .y = 1000 }, .size = .{ .width = 800, .height = 600 } };
    const c = coverFor(v);
    try testing.expectEqual(frames.ParkPoint{ .x = 800, .y = 800 }, c.top_left);
    try testing.expectEqual(frames.Size{ .width = 1200, .height = 1000 }, c.size);
    // The viewport's own corner is inside what it covers.
    try testing.expect(c.holds(v.origin) == .inside);
}

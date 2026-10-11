//! What the server decides, and why: a move kept or refused, a new human's
//! dog placed or not.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const scene = @import("scene.zig");

/// A move's outcome. Kept moves say, by type, whether the park clamped them.
/// Made by `decide`, so an outcome cannot disagree with its move.
pub const MoveOutcome = union(enum) {
    /// The move was a stay: the dog is where it was.
    stayed,
    /// Moved: the dog's new place, inside the park or clamped to its edge.
    moved: park.Clamped,
    refused: MoveRefusal,

    /// Where the dog is after this outcome, given where it was.
    pub fn dogAt(self: MoveOutcome, was: park.InParkPoint) park.InParkPoint {
        return switch (self) {
            .stayed, .refused => was,
            .moved => |c| c.point(),
        };
    }
};

/// Why a move was refused: the browser snaps the dog back, and can say why.
pub const MoveRefusal = enum {
    /// Further in one drag than `longest_drag`: a stale or forged request.
    too_far_at_once,
};

/// What `move` does to a dog at `was` in `p`: the only way a drag reaches a
/// dog, so no drag is applied unchecked or unclamped.
pub fn decide(p: park.Park, was: park.InParkPoint, move: scene.Move) MoveOutcome {
    return switch (move) {
        .stay => .stayed,
        .drag => |d| switch (dragLength(d)) {
            .too_far => .{ .refused = .too_far_at_once },
            .within_limit => .{ .moved = p.clamp(was.point.plus(d)) },
        },
    };
}

/// The longest a dog may be dragged in one request, on either axis.
pub const longest_drag: u31 = 2000;

/// Whether `d` is short enough for one drag.
pub fn dragLength(d: frames.Displacement) DragLength {
    if (@abs(d.dx) > longest_drag or @abs(d.dy) > longest_drag) return .too_far;
    return .within_limit;
}

pub const DragLength = enum { within_limit, too_far };

/// A new human's dog: placed on a lattice spot (its point is the park's
/// `pointOf` that spot), or not, and why.
pub const Placement = union(enum) {
    placed: park.LatticeSpot,
    refused: PlacementRefusal,
};

pub const PlacementRefusal = enum {
    /// Every lattice spot is taken.
    park_full,
    /// The population's memory is full (population.Put.refused_full).
    population_full,
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 600 })).park;
const start: park.InParkPoint = .{ .point = .at(10, 10) };

test "a stay stays, and a refused move leaves the dog where it start" {
    try testing.expectEqual(MoveOutcome.stayed, decide(small, start, .stay));
    try testing.expectEqual(start, decide(small, start, .stay).dogAt(start));
    const far = decide(small, start, .{ .drag = .{ .dx = longest_drag + 1, .dy = 0 } });
    try testing.expectEqual(MoveOutcome{ .refused = .too_far_at_once }, far);
    try testing.expectEqual(start, far.dogAt(start));
}

test "a drag inside the park moves; one past its edge is clamped, and says so" {
    const in = decide(small, start, .{ .drag = .{ .dx = 5, .dy = 5 } });
    try testing.expectEqual(frames.ParkPoint.at(15, 15), in.moved.inside.point);
    const out = decide(small, start, .{ .drag = .{ .dx = -50, .dy = 0 } });
    try testing.expectEqual(frames.ParkPoint.at(-40, 10), out.moved.clamped.asked);
    try testing.expectEqual(frames.ParkPoint.at(0, 10), out.dogAt(start).point);
}

test "a drag of exactly the longest is kept, and clamped at the edge" {
    const edge = decide(small, start, .{ .drag = .{ .dx = longest_drag, .dy = 0 } });
    try testing.expectEqual(frames.ParkPoint.at(999, 10), edge.dogAt(start).point);
}

test "a drag's length, at the limit and past it" {
    try testing.expectEqual(DragLength.within_limit, dragLength(.{ .dx = longest_drag, .dy = -@as(frames.Coord, longest_drag) }));
    try testing.expectEqual(DragLength.too_far, dragLength(.{ .dx = longest_drag + 1, .dy = 0 }));
    try testing.expectEqual(DragLength.too_far, dragLength(.{ .dx = std.math.minInt(frames.Coord), .dy = std.math.minInt(frames.Coord) }));
}

test "a placed dog stands on its spot's point" {
    const placed: Placement = .{ .placed = small.spot(2, 1).on };
    try testing.expectEqual(frames.ParkPoint.at(250, 150), small.pointOf(placed.placed).point);
}

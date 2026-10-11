//! What the server decides of a move, and why: kept or refused.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const scene = @import("scene.zig");

/// A move's outcome. Made by `decide`, so an outcome cannot disagree with
/// its move.
pub const MoveOutcome = union(enum) {
    stayed,
    /// Moved: the dog's new place, wrapped into the park if the move left it.
    moved: park.InParkPoint,
    refused: MoveRefusal,

    /// Where the dog is after this outcome, given where it was.
    pub fn dogAt(self: MoveOutcome, was: park.InParkPoint) park.InParkPoint {
        return switch (self) {
            .stayed, .refused => was,
            .moved => |p| p,
        };
    }
};

/// Why a move was refused: the browser snaps the dog back, and can say why.
pub const MoveRefusal = enum {
    /// Further in one drag than `longest_drag`: a stale or forged request.
    too_far_at_once,
};

/// What `move` does to a dog at `was` in `p`: the only way a drag reaches a
/// dog, so no drag is applied unchecked or unwrapped.
pub fn decide(p: park.Park, was: park.InParkPoint, move: scene.Move) MoveOutcome {
    return switch (move) {
        .stay => .stayed,
        // A drag of nothing, though Move.of never makes one, is a stay.
        .drag => |d| if (std.meta.eql(d, frames.Displacement.none)) .stayed else switch (dragLength(d)) {
            .too_far => .{ .refused = .too_far_at_once },
            .within_limit => .{ .moved = p.wrap(was.point.plus(d)) },
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

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 600 })).park;
const start: park.InParkPoint = .{ .point = .at(10, 10) };

test "a stay stays, and a refused move leaves the dog where it started" {
    try testing.expectEqual(MoveOutcome.stayed, decide(small, start, .stay));
    try testing.expectEqual(MoveOutcome.stayed, decide(small, start, .{ .drag = .none }));
    try testing.expectEqual(start, decide(small, start, .stay).dogAt(start));
    const far = decide(small, start, .{ .drag = .{ .dx = longest_drag + 1, .dy = 0 } });
    try testing.expectEqual(MoveOutcome{ .refused = .too_far_at_once }, far);
    try testing.expectEqual(start, far.dogAt(start));
}

test "a drag inside the park moves; one past its edge wraps to the far side" {
    const in = decide(small, start, .{ .drag = .{ .dx = 5, .dy = 5 } });
    try testing.expectEqual(frames.ParkPoint.at(15, 15), in.moved.point);
    const west = decide(small, start, .{ .drag = .{ .dx = -50, .dy = -20 } });
    try testing.expectEqual(frames.ParkPoint.at(960, 590), west.dogAt(start).point);
}

test "a drag of exactly the longest is kept, and wraps more than a whole park" {
    const far = decide(small, start, .{ .drag = .{ .dx = longest_drag, .dy = longest_drag } });
    try testing.expectEqual(frames.ParkPoint.at(10, 210), far.dogAt(start).point);
}

test "a drag's length, at the limit and past it" {
    try testing.expectEqual(DragLength.within_limit, dragLength(.{ .dx = longest_drag, .dy = -@as(frames.Coord, longest_drag) }));
    try testing.expectEqual(DragLength.too_far, dragLength(.{ .dx = longest_drag + 1, .dy = 0 }));
    try testing.expectEqual(DragLength.too_far, dragLength(.{ .dx = std.math.minInt(frames.Coord), .dy = std.math.minInt(frames.Coord) }));
}

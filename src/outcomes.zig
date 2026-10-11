//! What the server decides, and why: a move kept or refused, a new human's
//! dog placed or not.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");

/// A move's outcome. Kept moves say, by type, whether the park clamped them.
pub const MoveOutcome = union(enum) {
    /// The move was a stay.
    stayed: frames.ParkPoint,
    /// Moved: the dog's new position, inside the park or clamped to its edge.
    moved: park.Clamped,
    refused: MoveRefusal,

    /// Where the dog is after this outcome, given where it was.
    pub fn dogAt(self: MoveOutcome, was: frames.ParkPoint) frames.ParkPoint {
        return switch (self) {
            .stayed => |p| p,
            .moved => |c| c.point(),
            .refused => was,
        };
    }
};

/// Why a move was refused: the browser snaps the dog back, and can say why.
pub const MoveRefusal = enum {
    /// The human has no dog yet (placing one comes first).
    no_dog_yet,
    /// Further in one drag than `longest_drag`: a stale or forged request.
    too_far_at_once,
};

/// The longest a dog may be dragged in one request, on either axis.
pub const longest_drag: u31 = 2000;

/// Whether `d` is short enough for one drag.
pub fn dragLength(d: frames.Displacement) DragLength {
    if (@abs(d.dx) > longest_drag or @abs(d.dy) > longest_drag) return .too_far;
    return .within_limit;
}

pub const DragLength = enum { within_limit, too_far };

/// A new human's dog: placed on a lattice spot, or not, and why.
pub const Placement = union(enum) {
    placed: Placed,
    refused: PlacementRefusal,
};

pub const Placed = struct {
    spot: park.LatticeSpot,
    at: frames.ParkPoint,
};

pub const PlacementRefusal = enum {
    /// Every lattice spot is taken.
    park_full,
    /// The population's memory is full (population.Put.refused_full).
    population_full,
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a refused move leaves the dog where it was; a clamped one at the edge" {
    const was: frames.ParkPoint = .{ .x = 10, .y = 10 };
    try testing.expectEqual(was, (MoveOutcome{ .refused = .too_far_at_once }).dogAt(was));
    const edge: frames.ParkPoint = .{ .x = 0, .y = 10 };
    const clamped: MoveOutcome = .{ .moved = .{ .clamped = .{ .asked = .{ .x = -40, .y = 10 }, .kept = edge } } };
    try testing.expectEqual(edge, clamped.dogAt(was));
}

test "a drag's length, at the limit and past it" {
    try testing.expectEqual(DragLength.within_limit, dragLength(.{ .dx = longest_drag, .dy = -@as(frames.Coord, longest_drag) }));
    try testing.expectEqual(DragLength.too_far, dragLength(.{ .dx = longest_drag + 1, .dy = 0 }));
    try testing.expectEqual(DragLength.too_far, dragLength(.{ .dx = 0, .dy = std.math.minInt(frames.Coord) }));
}

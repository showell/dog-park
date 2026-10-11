//! What crosses to and from the browser, as records whose field names say
//! their frame, so the JavaScript reading them cannot guess wrong either.
//! No JSON here: the box encodes these. A tag is a string the browser
//! switches on ("stay" or "drag"; "moved" or "refused").

const std = @import("std");
const frames = @import("frames.zig");
const dogs = @import("dogs.zig");
const scene = @import("scene.zig");
const outcomes = @import("outcomes.zig");

/// The browser's request: its viewport in the park, and its dog's move.
pub const WireSceneRequest = struct {
    viewport_park_x: frames.Coord,
    viewport_park_y: frames.Coord,
    viewport_width: u31,
    viewport_height: u31,
    move: WireMove,

    pub fn read(self: WireSceneRequest) scene.SceneRequest {
        return .{
            .viewport = .{ .origin = .{ .x = self.viewport_park_x, .y = self.viewport_park_y }, .size = .{ .width = self.viewport_width, .height = self.viewport_height } },
            .move = switch (self.move) {
                .stay => .stay,
                .drag => |d| .{ .drag = .{ .dx = d.own_dog_dx, .dy = d.own_dog_dy } },
            },
        };
    }
};

pub const WireMove = union(enum) {
    stay,
    drag: struct { own_dog_dx: frames.Coord, own_dog_dy: frames.Coord },
};

/// A dog as the browser draws it: where, in the park's frame, and its emoji.
pub const WireDog = struct {
    owner: u64,
    park_x: frames.Coord,
    park_y: frames.Coord,
    emoji: []const u8,

    pub fn of(d: dogs.Dog) WireDog {
        return .{ .owner = d.owner.number(), .park_x = d.at.x, .park_y = d.at.y, .emoji = d.breed.emoji() };
    }
};

/// A scene as the browser renders it.
pub const WireScene = struct {
    covers_park_x: frames.Coord,
    covers_park_y: frames.Coord,
    covers_width: u31,
    covers_height: u31,
    park_width: u31,
    park_height: u31,
    own: WireDog,
    others: []const WireDog,
    others_complete: @import("population.zig").Completeness,
    /// What became of this request's move: the browser keeps its optimistic
    /// drag, or snaps the dog back to `own`.
    move: WireMoveOutcome,
};

pub const WireMoveOutcome = enum { stayed, moved, clamped, refused_no_dog_yet, refused_too_far_at_once };

pub fn moveOutcome(o: outcomes.MoveOutcome) WireMoveOutcome {
    return switch (o) {
        .stayed => .stayed,
        .moved => |c| switch (c) {
            .inside => .moved,
            .clamped => .clamped,
        },
        .refused => |r| switch (r) {
            .no_dog_yet => .refused_no_dog_yet,
            .too_far_at_once => .refused_too_far_at_once,
        },
    };
}

test "a request's drag is the own dog's displacement, and its viewport a park rectangle" {
    const w: WireSceneRequest = .{ .viewport_park_x = 10, .viewport_park_y = 20, .viewport_width = 300, .viewport_height = 200, .move = .{ .drag = .{ .own_dog_dx = 5, .own_dog_dy = -5 } } };
    const r = w.read();
    try std.testing.expectEqual(frames.ParkPoint{ .x = 10, .y = 20 }, r.viewport.origin);
    try std.testing.expectEqual(frames.Displacement{ .dx = 5, .dy = -5 }, r.move.drag);
}

test "a dog on the wire is in the park's frame" {
    const d: dogs.Dog = .{ .owner = @import("humans.zig").HumanId.of(3), .at = .{ .x = 40, .y = 50 }, .breed = .fox };
    const w = WireDog.of(d);
    try std.testing.expectEqual(@as(frames.Coord, 40), w.park_x);
    try std.testing.expectEqualStrings("🦊", w.emoji);
}

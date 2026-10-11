//! What crosses to and from the browser, as records whose field names say
//! their frame, so the JavaScript reading them cannot guess wrong either.
//! No JSON here: the box encodes these. A tag is a string the browser
//! switches on ("stay" or "drag"; "moved" or "refused").
//!
//! **IN BY `read`, OUT BY `of`.** A wire record holds plain numbers, which
//! no type can keep in their frame, so each is made in one place.
//! **NO HUMAN IDS GO OUT**: the own dog comes apart, so the others need no
//! owner, and nobody learns another's id.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const population = @import("population.zig");
const scene = @import("scene.zig");
const outcomes = @import("outcomes.zig");

/// The widest and tallest viewport a request may ask for, and how far past
/// the park its origin may be: enough for any screen, small enough that no
/// coordinate built from a request comes near saturating.
pub const widest_viewport: u31 = 10_000;

/// The browser's request: its viewport in the park, and its dog's move.
pub const WireSceneRequest = struct {
    viewport_park_x: frames.Coord,
    viewport_park_y: frames.Coord,
    viewport_width: u31,
    viewport_height: u31,
    move: WireMove,

    pub fn read(self: WireSceneRequest, p: park.Park) ReadRequest {
        if (self.viewport_width == 0 or self.viewport_height == 0) return .{ .refused = .viewport_empty };
        if (self.viewport_width > widest_viewport or self.viewport_height > widest_viewport) return .{ .refused = .viewport_too_large };
        const origin: frames.ParkPoint = .at(self.viewport_park_x, self.viewport_park_y);
        if (p.bounds().grownBy(widest_viewport).holds(origin) == .outside) return .{ .refused = .viewport_off_park };
        return .{ .request = .{
            .viewport = .{ .origin = origin, .size = .{ .width = self.viewport_width, .height = self.viewport_height } },
            .move = switch (self.move) {
                .stay => .stay,
                .drag => |d| .of(.{ .dx = d.own_dog_dx, .dy = d.own_dog_dy }),
            },
        } };
    }
};

pub const WireMove = union(enum) {
    stay,
    drag: struct { own_dog_dx: frames.Coord, own_dog_dy: frames.Coord },
};

pub const ReadRequest = union(enum) {
    request: scene.SceneRequest,
    refused: RequestRefusal,
};

pub const RequestRefusal = enum { viewport_empty, viewport_too_large, viewport_off_park };

/// A dog as the browser draws it: where, in the park's frame, and its emoji.
pub const WireDog = struct {
    park_x: frames.Coord,
    park_y: frames.Coord,
    emoji: []const u8,

    pub fn of(d: dogs.Drawn) WireDog {
        return .{ .park_x = d.at.point.x.number(), .park_y = d.at.point.y.number(), .emoji = d.breed.emoji() };
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
    others_complete: WireCompleteness,
    /// What became of this request's move: the browser keeps its optimistic
    /// drag, or puts the dog where `own` says.
    move: WireMoveOutcome,

    /// `s` for the wire, its others written into `others_into` (as long as
    /// `s.others`, or longer).
    pub fn of(s: scene.Scene, others_into: []WireDog) WireScene {
        for (s.others, others_into[0..s.others.len]) |d, *w| w.* = .of(d.drawn());
        const c = s.covers();
        return .{
            .covers_park_x = c.top_left.x.number(),
            .covers_park_y = c.top_left.y.number(),
            .covers_width = c.size.width,
            .covers_height = c.size.height,
            .park_width = s.park_size.width,
            .park_height = s.park_size.height,
            .own = .of(s.own),
            .others = others_into[0..s.others.len],
            .others_complete = switch (s.others_completeness) {
                .all_in_region => .all,
                .more_in_region => .more_not_sent,
            },
            .move = switch (s.move) {
                .stayed => .stayed,
                .moved => |c2| switch (c2) {
                    .inside => .moved,
                    .clamped => .clamped,
                },
                .refused => |r| switch (r) {
                    .too_far_at_once => .refused_too_far_at_once,
                },
            },
        };
    }
};

/// The protocol's own names, so renaming an internal enum changes no wire.
pub const WireCompleteness = enum { all, more_not_sent };

pub const WireMoveOutcome = enum { stayed, moved, clamped, refused_too_far_at_once };

/// What the browser gets: a scene, or why its dog could not be placed.
pub const WireAnswer = union(enum) {
    scene: WireScene,
    no_room: enum { park_full, population_full },
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 600 })).park;

fn request(move: WireMove) WireSceneRequest {
    return .{ .viewport_park_x = 10, .viewport_park_y = 20, .viewport_width = 300, .viewport_height = 200, .move = move };
}

test "a request's drag is the own dog's displacement, and its viewport a park rectangle" {
    const r = request(.{ .drag = .{ .own_dog_dx = 5, .own_dog_dy = -5 } }).read(small).request;
    try testing.expectEqual(frames.ParkPoint.at(10, 20), r.viewport.origin);
    try testing.expectEqual(frames.Displacement{ .dx = 5, .dy = -5 }, r.move.drag);
}

test "a request's stay, and its drag of nothing, are both a stay" {
    try testing.expectEqual(scene.Move.stay, request(.stay).read(small).request.move);
    try testing.expectEqual(scene.Move.stay, request(.{ .drag = .{ .own_dog_dx = 0, .own_dog_dy = 0 } }).read(small).request.move);
}

test "a viewport empty, too large, or far off the park is refused, not saturated" {
    var w = request(.stay);
    w.viewport_width = 0;
    try testing.expectEqual(RequestRefusal.viewport_empty, w.read(small).refused);
    w = request(.stay);
    w.viewport_height = widest_viewport + 1;
    try testing.expectEqual(RequestRefusal.viewport_too_large, w.read(small).refused);
    w = request(.stay);
    w.viewport_park_x = std.math.maxInt(frames.Coord);
    try testing.expectEqual(RequestRefusal.viewport_off_park, w.read(small).refused);
    // Scrolled a little past the park's corner is a fine viewport.
    w = request(.stay);
    w.viewport_park_x = -150;
    try testing.expect(w.read(small) == .request);
}

test "a scene on the wire: park-frame dogs, no owners, the clamped move and where it left the dog" {
    const was: park.InParkPoint = .{ .point = .at(10, 10) };
    const move = outcomes.decide(small, was, .{ .drag = .{ .dx = -50, .dy = 0 } });
    const other: dogs.Dog = .{ .owner = .of(3), .at = .{ .point = .at(40, 50) }, .breed = .fox };
    const s: scene.Scene = .{
        .viewport = .{ .origin = .at(0, 0), .size = .{ .width = 300, .height = 200 } },
        .own = .{ .at = move.dogAt(was), .breed = .wolf },
        .others = &.{other},
        .others_completeness = .all_in_region,
        .park_size = small.size,
        .move = move,
    };
    var into: [1]WireDog = undefined;
    const w = WireScene.of(s, &into);
    try testing.expectEqual(WireMoveOutcome.clamped, w.move);
    try testing.expectEqual(@as(frames.Coord, 0), w.own.park_x);
    try testing.expectEqual(@as(frames.Coord, -200), w.covers_park_x);
    try testing.expectEqual(@as(frames.Coord, 40), w.others[0].park_x);
    try testing.expectEqualStrings("🦊", w.others[0].emoji);
    try testing.expect(!@hasField(WireDog, "owner"));
}

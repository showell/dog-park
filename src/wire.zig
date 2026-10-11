//! What crosses to and from the browser, as records whose field names say
//! their frame, so the JavaScript reading them cannot guess wrong either.
//! They cross as JSON through `std.json` (app.zig), and a tag is a string the
//! browser switches on, the union's field name.
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

/// The widest and tallest viewport a request may ask for: enough for any
/// screen, small enough that no coordinate built from a request comes near
/// overflowing.
pub const widest_viewport: u31 = 10_000;

/// How far past the park's home tile a viewport's origin may be (the browser
/// wraps its origin back into the park's range as it scrolls).
pub const farthest_origin_past_park: u31 = 10_000;

/// The browser's request: its viewport in the plane, and its dog's move.
pub const WireSceneRequest = struct {
    viewport_plane_x: frames.Coord,
    viewport_plane_y: frames.Coord,
    viewport_width: u31,
    viewport_height: u31,
    move: WireMove,

    pub fn read(self: WireSceneRequest, p: park.Park) ReadRequest {
        if (self.viewport_width == 0 or self.viewport_height == 0) return .{ .refused = .viewport_empty };
        if (self.viewport_width > widest_viewport or self.viewport_height > widest_viewport) return .{ .refused = .viewport_too_large };
        // A scene covers at most twice the park on an axis, so it is cut into
        // at most nine pieces (park.PlaneRect.pieces), however small the park.
        if (@as(u32, self.viewport_width) + 2 * scene.margin > 2 * @as(u32, p.size.width) or
            @as(u32, self.viewport_height) + 2 * scene.margin > 2 * @as(u32, p.size.height)) return .{ .refused = .viewport_too_large };
        const origin: frames.PlanePoint = .at(self.viewport_plane_x, self.viewport_plane_y);
        const home: park.PlaneRect = .{ .top_left = .at(0, 0), .size = p.size };
        if (home.grownBy(farthest_origin_past_park).holds(origin) == .outside) return .{ .refused = .viewport_far_from_park };
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

pub const RequestRefusal = enum { viewport_empty, viewport_too_large, viewport_far_from_park };

/// A dog as the browser draws it: the copy of it in the plane, and its emoji.
pub const WireDog = struct {
    plane_x: frames.Coord,
    plane_y: frames.Coord,
    emoji: []const u8,

    pub fn of(d: dogs.Drawn) WireDog {
        return .{ .plane_x = d.at.x.number(), .plane_y = d.at.y.number(), .emoji = d.breed.emoji() };
    }
};

/// A scene as the browser renders it.
pub const WireScene = struct {
    covers_plane_x: frames.Coord,
    covers_plane_y: frames.Coord,
    covers_width: u31,
    covers_height: u31,
    park_width: u31,
    park_height: u31,
    /// The asker's own dog, or none free for them (docs/CLAIMS-V1.md): the
    /// browser shows the park read-only then, and keeps asking.
    own: WireOwn,
    others: []const WireDog,
    others_complete: WireCompleteness,

    /// `s` for the wire, its others written into `others_into`: as many as
    /// fit, and if not all did, the scene says more were not sent.
    pub fn of(s: scene.Scene, others_into: []WireDog) WireScene {
        const sent = @min(s.others.len, others_into.len);
        for (s.others[0..sent], others_into[0..sent]) |d, *w| w.* = .of(d);
        const all_sent: WireCompleteness = if (sent == s.others.len) .all else .more_not_sent;
        const c = s.covers();
        return .{
            .covers_plane_x = c.top_left.x.number(),
            .covers_plane_y = c.top_left.y.number(),
            .covers_width = c.size.width,
            .covers_height = c.size.height,
            .park_width = s.park_size.width,
            .park_height = s.park_size.height,
            .own = switch (s.own) {
                .has_dog => |o| .{ .has_dog = .{
                    .plane_x = o.drawn.at.x.number(),
                    .plane_y = o.drawn.at.y.number(),
                    .emoji = o.drawn.breed.emoji(),
                    .is = switch (o.is) {
                        .the_dog_held => .same_dog,
                        .a_dog_newly_theirs => .new_dog,
                    },
                    .move = switch (o.move) {
                        .stayed => .stayed,
                        .moved => .moved,
                        .refused => |r| switch (r) {
                            .too_far_at_once => .refused_too_far_at_once,
                        },
                    },
                } },
                .no_dog_free => .no_dog_free,
            },
            .others = others_into[0..sent],
            .others_complete = switch (s.others_completeness) {
                .all_in_region => all_sent,
                .more_in_region => .more_not_sent,
            },
        };
    }
};

/// The protocol's own names, so renaming an internal enum changes no wire.
pub const WireCompleteness = enum { all, more_not_sent };

pub const WireOwnIs = enum { same_dog, new_dog };

/// The asker's own dog on the wire, `{"has_dog": {...}}`, or
/// `{"no_dog_free": {}}`.
pub const WireOwn = union(enum) {
    has_dog: WireOwnDog,
    no_dog_free,
};

/// The own dog: the copy nearest the viewport's centre (the browser draws
/// the copy nearest its own optimistic place, and on a screen wider than the
/// park every copy in view, from `park_width` and `park_height`), whether it
/// is the dog held or newly theirs (the browser centres on a new one), and
/// what became of this request's move (kept, or refused: the browser puts
/// the dog where this says).
pub const WireOwnDog = struct {
    plane_x: frames.Coord,
    plane_y: frames.Coord,
    emoji: []const u8,
    is: WireOwnIs,
    move: WireMoveOutcome,
};

pub const WireMoveOutcome = enum { stayed, moved, refused_too_far_at_once };

/// What the browser gets: a scene, whose own dog may be none
/// (docs/CLAIMS-V1.md), so there is no other answer; the union is the
/// wire's shape, `{"scene": ...}`, kept for a later one.
pub const WireAnswer = union(enum) {
    scene: WireScene,

    pub fn of(s: scene.Scene, others_into: []WireDog) WireAnswer {
        return .{ .scene = .of(s, others_into) };
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 600 })).park;

fn request(move: WireMove) WireSceneRequest {
    return .{ .viewport_plane_x = 10, .viewport_plane_y = 20, .viewport_width = 300, .viewport_height = 200, .move = move };
}

test "a request's drag is the own dog's displacement, and its viewport a plane rectangle" {
    const r = request(.{ .drag = .{ .own_dog_dx = 5, .own_dog_dy = -5 } }).read(small).request;
    try testing.expectEqual(frames.PlanePoint.at(10, 20), r.viewport.origin);
    try testing.expectEqual(frames.Displacement{ .dx = 5, .dy = -5 }, r.move.drag);
}

test "a request's stay, and its drag of nothing, are both a stay" {
    try testing.expectEqual(scene.Move.stay, request(.stay).read(small).request.move);
    try testing.expectEqual(scene.Move.stay, request(.{ .drag = .{ .own_dog_dx = 0, .own_dog_dy = 0 } }).read(small).request.move);
}

test "a viewport empty, too large, or far from the park is refused, never carried into arithmetic" {
    var w = request(.stay);
    w.viewport_width = 0;
    try testing.expectEqual(RequestRefusal.viewport_empty, w.read(small).refused);
    w = request(.stay);
    w.viewport_height = widest_viewport + 1;
    try testing.expectEqual(RequestRefusal.viewport_too_large, w.read(small).refused);
    // Against the park: a scene would cover more than twice it (600 tall).
    w = request(.stay);
    w.viewport_height = 801;
    try testing.expectEqual(RequestRefusal.viewport_too_large, w.read(small).refused);
    w.viewport_height = 800;
    try testing.expect(w.read(small) == .request);
    w = request(.stay);
    w.viewport_plane_x = std.math.maxInt(frames.Coord);
    try testing.expectEqual(RequestRefusal.viewport_far_from_park, w.read(small).refused);
    w = request(.stay);
    w.viewport_plane_y = -@as(frames.Coord, farthest_origin_past_park) - 1;
    try testing.expectEqual(RequestRefusal.viewport_far_from_park, w.read(small).refused);
    // Scrolled past the park's corner, or a tile away, is a fine viewport.
    w = request(.stay);
    w.viewport_plane_x = -150;
    try testing.expect(w.read(small) == .request);
    w.viewport_plane_x = 1500;
    try testing.expect(w.read(small) == .request);
}

test "a scene on the wire: plane copies, no owners, a move across the seam" {
    const start: park.InParkPoint = small.wrap(.at(10, 10));
    const move = outcomes.decide(small, start, .{ .drag = .{ .dx = -50, .dy = 0 } });
    const viewport: frames.Viewport = .{ .origin = .at(-300, 0), .size = .{ .width = 300, .height = 200 } };
    const other: dogs.Dog = .{ .id = .of(3), .at = small.wrap(.at(940, 50)), .breed = .poodle, .claim = .unclaimed };
    const own: dogs.Dog = .{ .id = .of(4), .at = move.dogAt(start), .breed = .dog_face, .claim = .unclaimed };
    var s: scene.Scene = .{
        .viewport = viewport,
        .own = .{ .has_dog = .{ .drawn = own.drawnNear(small, viewport.centre()), .is = .the_dog_held, .move = move } },
        .others = &.{other.drawnNear(small, viewport.centre())},
        .others_completeness = .all_in_region,
        .park_size = small.size,
    };
    var into: [1]WireDog = undefined;
    const w = WireScene.of(s, &into);
    try testing.expectEqual(WireMoveOutcome.moved, w.own.has_dog.move);
    // The dog went west past the seam: its park point is at 960, its copy
    // near the viewport at -40, just west of where it was dragged from.
    try testing.expectEqual(frames.ParkPoint.at(960, 10), move.dogAt(start).point);
    try testing.expectEqual(@as(frames.Coord, -40), w.own.has_dog.plane_x);
    try testing.expectEqual(@as(frames.Coord, -500), w.covers_plane_x);
    try testing.expectEqual(@as(frames.Coord, -60), w.others[0].plane_x);
    try testing.expectEqualStrings("🐩", w.others[0].emoji);
    try testing.expect(!@hasField(WireDog, "owner"));
    // A buffer too short for the others sends what fits, and says so.
    const short = WireScene.of(s, into[0..0]);
    try testing.expectEqual(@as(usize, 0), short.others.len);
    try testing.expectEqual(WireCompleteness.more_not_sent, short.others_complete);
    // No dog free: the scene comes, its own saying so.
    s.own = .no_dog_free;
    const none = WireScene.of(s, &into);
    try testing.expect(none.own == .no_dog_free);
    const json = try std.json.Stringify.valueAlloc(testing.allocator, WireAnswer{ .scene = none }, .{});
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"own\":{\"no_dog_free\":{}}") != null);
}

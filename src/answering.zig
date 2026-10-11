//! Answering a scene request: a pure function of the park, the population,
//! a known human and the request, to the scene and what changed. No I/O: the
//! world keeps what changed (world.World.keep), the application writes the
//! answer.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const population = @import("population.zig");
const scene = @import("scene.zig");
const outcomes = @import("outcomes.zig");
const placement = @import("placement.zig");
const HumanId = @import("humans.zig").HumanId;

/// What a request changed: nothing, or a dog to keep (a new human's, just
/// placed, or one that moved).
pub const Change = union(enum) {
    nothing,
    keep: dogs.Dog,
};

pub const Answered = struct {
    answer: scene.SceneAnswer,
    change: Change,
};

/// Where a request's answer is written: the others' copies, and room for
/// the dogs one piece of the scene finds before they are carried to the
/// plane. The scene's `others` is the front of `others`.
pub const Room = struct {
    others: []dogs.Drawn,
    found: []dogs.Dog,
};

/// The answer to `human`'s `request` in `p` with `pop` as it is: a human
/// with no dog has one placed first (`space` says whether the population
/// can take one more), then the move is decided, then the others are found
/// in what the scene covers, piece by piece across the seam.
pub fn answer(p: park.Park, pop: population.Population, space: population.Space, human: HumanId, request: scene.SceneRequest, room: Room) Answered {
    const before: Before = switch (pop.lookup(human)) {
        .found => |d| .{ .dog = d, .since = .before_this_request },
        .no_dog => switch (space) {
            .full => return .{ .answer = .{ .no_room = .population_full }, .change = .nothing },
            .room_for_one_more => switch (placement.place(p, pop, human)) {
                .refused => |why| return .{ .answer = .{ .no_room = why }, .change = .nothing },
                .placed => |spot| .{
                    .dog = .{
                        .owner = human,
                        .at = switch (p.pointOf(spot)) {
                            .on => |at| at,
                            .off_park => unreachable, // place answers a spot of this park
                        },
                        .breed = breedOf(human),
                    },
                    .since = .placed_now,
                },
            },
        },
    };
    const move = outcomes.decide(p, before.dog.at, request.move);
    var after = before.dog;
    after.at = move.dogAt(before.dog.at);
    const change: Change = switch (before.since) {
        .placed_now => .{ .keep = after },
        .before_this_request => switch (move) {
            .moved => .{ .keep = after },
            .stayed, .refused => .nothing,
        },
    };
    const others = othersIn(p, pop, human, scene.coverFor(request.viewport), room);
    return .{ .answer = .{ .scene = .{
        .viewport = request.viewport,
        .own = after.drawnNear(p, request.viewport.centre()),
        .others = others.drawn,
        .others_completeness = others.completeness,
        .park_size = p.size,
        .move = move,
    } }, .change = change };
}

const Before = struct {
    dog: dogs.Dog,
    since: enum { before_this_request, placed_now },
};

/// A new human's breed: one of the five, by their id, so it is the same
/// however often they are asked about.
pub fn breedOf(human: HumanId) dogs.Breed {
    const breeds = @typeInfo(dogs.Breed).@"enum".fields.len;
    return @enumFromInt(human.number() % breeds);
}

const Others = struct {
    drawn: []const dogs.Drawn,
    completeness: population.Completeness,
};

/// Every copy of every dog but `human`'s in `covers`, as many as `room`
/// holds.
fn othersIn(p: park.Park, pop: population.Population, human: HumanId, covers: park.PlaneRect, room: Room) Others {
    var n: usize = 0;
    var completeness: population.Completeness = .all_in_region;
    var pieces = covers.pieces(p);
    while (true) switch (pieces.nextPiece()) {
        .done => break,
        .piece => |piece| {
            const most = @min(room.found.len, room.others.len - n);
            const found = pop.near(.{ .region = piece.region, .except = human }, room.found[0..most]);
            if (found.completeness == .more_in_region) completeness = .more_in_region;
            for (found.dogsIn(room.found)) |d| {
                room.others[n] = .{ .at = piece.toPlane(d.at.point), .breed = d.breed };
                n += 1;
            }
        },
    };
    return .{ .drawn = room.others[0..n], .completeness = completeness };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 1000 })).park;
const alice: HumanId = .of(1);
const bob: HumanId = .of(2);

fn asking(origin: frames.PlanePoint, move: scene.Move) scene.SceneRequest {
    return .{ .viewport = .{ .origin = origin, .size = .{ .width = 400, .height = 300 } }, .move = move };
}

const Rig = struct {
    list: population.ListPopulation(32) = .{},
    others: [32]dogs.Drawn = undefined,
    found: [32]dogs.Dog = undefined,

    fn ask(self: *Rig, human: HumanId, r: scene.SceneRequest) Answered {
        const a = answer(small, self.list.population(), .room_for_one_more, human, r, .{ .others = &self.others, .found = &self.found });
        switch (a.change) {
            .keep => |d| _ = self.list.population().put(d),
            .nothing => {},
        }
        return a;
    }
};

test "a human with no dog has one placed at the centre, kept, and shown" {
    var rig: Rig = .{};
    const a = rig.ask(alice, asking(.at(300, 300), .stay));
    const placed = a.change.keep;
    try testing.expectEqual(alice, placed.owner);
    try testing.expectEqual(frames.ParkPoint.at(550, 550), placed.at.point);
    try testing.expectEqual(frames.PlanePoint.at(550, 550), a.answer.scene.own.at);
    try testing.expectEqual(outcomes.MoveOutcome.stayed, a.answer.scene.move);
}

test "a stay changes nothing; a drag moves and is kept; a too-far drag is refused" {
    var rig: Rig = .{};
    _ = rig.ask(alice, asking(.at(300, 300), .stay));
    try testing.expectEqual(Change.nothing, rig.ask(alice, asking(.at(300, 300), .stay)).change);
    const dragged = rig.ask(alice, asking(.at(300, 300), .{ .drag = .{ .dx = 20, .dy = -10 } }));
    try testing.expectEqual(frames.ParkPoint.at(570, 540), dragged.change.keep.at.point);
    try testing.expectEqual(frames.PlanePoint.at(570, 540), dragged.answer.scene.own.at);
    const far = rig.ask(alice, asking(.at(300, 300), .{ .drag = .{ .dx = outcomes.longest_drag + 1, .dy = 0 } }));
    try testing.expectEqual(Change.nothing, far.change);
    try testing.expectEqual(outcomes.MoveOutcome{ .refused = .too_far_at_once }, far.answer.scene.move);
    try testing.expectEqual(frames.PlanePoint.at(570, 540), far.answer.scene.own.at);
}

test "a drag across the seam wraps the dog, drawn on the viewport's side of it" {
    var rig: Rig = .{};
    _ = rig.ask(alice, asking(.at(300, 300), .stay));
    // From (550, 550), 600 east: the park point is 150, and the viewport,
    // at x 900, sees the copy at 1150.
    const a = rig.ask(alice, asking(.at(900, 400), .{ .drag = .{ .dx = 600, .dy = 0 } }));
    try testing.expectEqual(frames.ParkPoint.at(150, 550), a.change.keep.at.point);
    try testing.expectEqual(frames.PlanePoint.at(1150, 550), a.answer.scene.own.at);
}

test "the others are in what the scene covers, copies across the seam, never the asker's own" {
    var rig: Rig = .{};
    _ = rig.list.population().put(.{ .owner = alice, .at = small.wrap(.at(980, 500)), .breed = .dog });
    _ = rig.list.population().put(.{ .owner = bob, .at = small.wrap(.at(20, 500)), .breed = .poodle });
    _ = rig.list.population().put(.{ .owner = .of(3), .at = small.wrap(.at(500, 100)), .breed = .poodle });
    // A viewport straddling the east seam: Bob's dog at 20 is seen at 1020.
    const a = rig.ask(alice, asking(.at(850, 400), .stay)).answer.scene;
    try testing.expectEqual(@as(usize, 1), a.others.len);
    try testing.expectEqual(frames.PlanePoint.at(1020, 500), a.others[0].at);
    for (a.others) |d| try testing.expect(a.covers().holds(d.at) == .inside);
    try testing.expectEqual(frames.PlanePoint.at(980, 500), a.own.at);
    // Asked by Bob, Alice's dog is among the others, on the west side.
    const b = rig.ask(bob, asking(.at(-150, 400), .stay)).answer.scene;
    try testing.expectEqual(@as(usize, 1), b.others.len);
    try testing.expectEqual(frames.PlanePoint.at(-20, 500), b.others[0].at);
}

test "a scene wider than the park shows a dog at every copy in it" {
    var rig: Rig = .{};
    _ = rig.list.population().put(.{ .owner = bob, .at = small.wrap(.at(500, 500)), .breed = .poodle });
    var r = asking(.at(-400, 400), .stay);
    r.viewport.size.width = 1500;
    // Covered from -600 to 1300 across: Bob's copies at -500 and 500.
    const a = rig.ask(alice, r).answer.scene;
    var xs: [2]frames.Coord = undefined;
    var count: usize = 0;
    for (a.others) |d| if (d.breed == .poodle) {
        xs[count] = d.at.x.number();
        count += 1;
    };
    try testing.expectEqual(@as(usize, 2), count);
    std.mem.sort(frames.Coord, &xs, {}, std.sort.asc(frames.Coord));
    try testing.expectEqual([2]frames.Coord{ -500, 500 }, xs);
}

test "a full population answers no room for a new human, and keeps nothing" {
    var list: population.ListPopulation(4) = .{};
    var others: [4]dogs.Drawn = undefined;
    var found: [4]dogs.Dog = undefined;
    const a = answer(small, list.population(), .full, alice, asking(.at(0, 0), .stay), .{ .others = &others, .found = &found });
    try testing.expectEqual(scene.SceneAnswer{ .no_room = .population_full }, a.answer);
    try testing.expectEqual(Change.nothing, a.change);
}

test "the others cut at the room given, and the scene says more are there" {
    var rig: Rig = .{};
    for (0..5) |i| _ = rig.list.population().put(.{ .owner = .of(10 + i), .at = small.wrap(.at(@intCast(400 + 10 * i), 400)), .breed = .dog });
    var others: [3]dogs.Drawn = undefined;
    const a = answer(small, rig.list.population(), .room_for_one_more, alice, asking(.at(300, 300), .stay), .{ .others = &others, .found = &rig.found });
    try testing.expectEqual(@as(usize, 3), a.answer.scene.others.len);
    try testing.expectEqual(population.Completeness.more_in_region, a.answer.scene.others_completeness);
}

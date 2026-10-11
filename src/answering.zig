//! Answering a scene request: a pure function of the park, its dogs, a
//! known human, what they hold, the time and the request, to the scene and
//! what changed. No I/O: the world keeps what changed (world.World.keep),
//! the application writes the answer.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const population = @import("population.zig");
const scene = @import("scene.zig");
const outcomes = @import("outcomes.zig");
const claiming = @import("claiming.zig");
const HumanId = @import("humans.zig").HumanId;
const DogId = dogs.DogId;

/// What a human holds as they ask, as the world knows it: a dog whose claim
/// names them (it may have ended: `answer` asks the claim at `now`), or none.
pub const Holding = union(enum) {
    holds: DogId,
    holds_none,
};

/// What a request changed.
pub const Change = union(enum) {
    nothing,
    /// A dog the human holds moved, and is held for good (its first drag
    /// makes a provisional claim held): written now.
    moved: dogs.Dog,
    /// A dog given to a human with none, provisionally: kept in memory only.
    given: Given,
};

pub const Given = struct {
    dog: dogs.Dog,
    from: claiming.Previously,
};

pub const Answered = struct {
    scene: scene.Scene,
    change: Change,
};

/// Where a request's answer is written: the others' copies, and room for
/// the dogs one piece of the scene finds before they are carried to the
/// plane. The scene's `others` is the front of `others`.
pub const Room = struct {
    others: []dogs.Drawn,
    found: []dogs.Dog,
};

/// The answer to `human`'s `request`, at `now` (docs/CLAIMS-V1.md):
/// - **a dog they hold** (provisionally and in time, or for good) moves as
///   the request says; a move makes a provisional claim held; a stay, or a
///   refused move, changes nothing and writes nothing;
/// - **a human with no dog** (new, or theirs ended undragged) is given the
///   free dog nearest the centre, provisionally until 120 s from now, and
///   their first request stays;
/// - **with no dog free**, none: the scene still comes, with every dog in
///   it among the others.
/// The others are found in what the scene covers, piece by piece across the
/// seam. `all[i]` is dog `i`; `pop` indexes the same dogs by where they are.
pub fn answer(p: park.Park, pop: population.Population, all: []const dogs.Dog, human: HumanId, holding: Holding, now: dogs.Instant, request: scene.SceneRequest, room: Room) Answered {
    const held_dog: ?dogs.Dog = switch (holding) {
        .holds => |id| blk: {
            const d = all[id.number()];
            break :blk if (d.claim.at(now).holder() == human) d else null;
        },
        .holds_none => null,
    };
    var change: Change = .nothing;
    const own: scene.Own = if (held_dog) |before| blk: {
        const move = outcomes.decide(p, before.at, request.move);
        var after = before;
        switch (move) {
            .moved => {
                after.at = move.dogAt(before.at);
                after.claim = .{ .held = .{ .by = human } };
                change = .{ .moved = after };
            },
            .stayed, .refused => {},
        }
        break :blk .{ .has_dog = .{ .drawn = after.drawnNear(p, request.viewport.centre()), .is = .the_dog_held, .move = move } };
    } else switch (claiming.claimFor(p, all, now)) {
        .dog => |free| blk: {
            var given = all[free.dog.number()];
            given.claim = .{ .provisional = .madeAt(human, now) };
            change = .{ .given = .{ .dog = given, .from = free.from } };
            // The first request of a dog stays: they have not seen it yet.
            break :blk .{ .has_dog = .{ .drawn = given.drawnNear(p, request.viewport.centre()), .is = .a_dog_newly_theirs, .move = .stayed } };
        },
        .no_dog_free => .no_dog_free,
    };
    const except: population.Except = switch (change) {
        .moved => |d| .{ .dog = d.id },
        .given => |g| .{ .dog = g.dog.id },
        .nothing => if (held_dog) |d| .{ .dog = d.id } else .nothing,
    };
    // **THE WIRE IS THE GATE**: `request` comes through wire.WireSceneRequest.read,
    // which bounds the viewport; one from anywhere else may overflow coverFor.
    const others = othersIn(p, pop, except, scene.coverFor(request.viewport), room);
    return .{ .scene = .{
        .viewport = request.viewport,
        .own = own,
        .others = others.drawn,
        .others_completeness = others.completeness,
        .park_size = p.size,
    }, .change = change };
}

const Others = struct {
    drawn: []const dogs.Drawn,
    completeness: population.Completeness,
};

/// Every copy of every dog but the asker's own in `covers`, claimed or not,
/// as many as `room` holds.
fn othersIn(p: park.Park, pop: population.Population, except: population.Except, covers: park.PlaneRect, room: Room) Others {
    var n: usize = 0;
    var completeness: population.Completeness = .all_in_region;
    var pieces = covers.pieces(p);
    while (true) switch (pieces.nextPiece()) {
        .done => break,
        .piece => |piece| {
            const most = @min(room.found.len, room.others.len - n);
            const found = pop.near(.{ .region = piece.region, .except = except }, room.found[0..most]);
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
const noon: dogs.Instant = .of(1_790_000_000);

fn asking(origin: frames.PlanePoint, move: scene.Move) scene.SceneRequest {
    return .{ .viewport = .{ .origin = origin, .size = .{ .width = 400, .height = 300 } }, .move = move };
}

fn held(h: HumanId) dogs.Claim {
    return .{ .held = .{ .by = h } };
}

/// A park of a few dogs, kept as the world keeps them: every change put
/// back into the list and the index, and who holds which.
const Rig = struct {
    all: [8]dogs.Dog = undefined,
    count: usize = 0,
    list: population.ListPopulation(8) = .{},
    others: [32]dogs.Drawn = undefined,
    found: [32]dogs.Dog = undefined,

    fn add(self: *Rig, x: frames.Coord, y: frames.Coord, breed: dogs.Breed, claim: dogs.Claim) void {
        const d: dogs.Dog = .{ .id = .of(@intCast(self.count)), .at = small.wrap(.at(x, y)), .breed = breed, .claim = claim };
        self.all[self.count] = d;
        self.count += 1;
        _ = self.list.population().put(d);
    }

    /// The dog whose claim names `human`, ended or not: the world's holders.
    fn holding(self: *const Rig, human: HumanId) Holding {
        for (self.all[0..self.count]) |d| if (d.claim.holder() == human) return .{ .holds = d.id };
        return .holds_none;
    }

    fn keep(self: *Rig, d: dogs.Dog) void {
        self.all[d.id.number()] = d;
        _ = self.list.population().put(d);
    }

    fn ask(self: *Rig, human: HumanId, now: dogs.Instant, r: scene.SceneRequest) Answered {
        const a = answer(small, self.list.population(), self.all[0..self.count], human, self.holding(human), now, r, .{ .others = &self.others, .found = &self.found });
        switch (a.change) {
            .moved => |d| self.keep(d),
            .given => |g| self.keep(g.dog),
            .nothing => {},
        }
        return a;
    }
};

test "a human with no dog is given the free one nearest the centre, provisionally for 120 s, and their first request stays" {
    var rig: Rig = .{};
    rig.add(100, 100, .dog, .unclaimed);
    rig.add(540, 520, .poodle, .unclaimed);
    const a = rig.ask(alice, noon, asking(.at(300, 300), .{ .drag = .{ .dx = 7, .dy = 0 } }));
    try testing.expectEqual(Given{
        .dog = .{ .id = .of(1), .at = small.wrap(.at(540, 520)), .breed = .poodle, .claim = .{ .provisional = .{ .by = alice, .until = noon.after(120) } } },
        .from = .nobody,
    }, a.change.given);
    const own = a.scene.own.has_dog;
    try testing.expectEqual(outcomes.MoveOutcome.stayed, own.move);
    try testing.expectEqual(frames.PlanePoint.at(540, 520), own.drawn.at);
    try testing.expectEqual(scene.OwnIs.a_dog_newly_theirs, own.is);
    // Asked again in time: the same dog, theirs, and nothing written.
    const again = rig.ask(alice, noon.after(119), asking(.at(300, 300), .stay));
    try testing.expectEqual(scene.OwnIs.the_dog_held, again.scene.own.has_dog.is);
    try testing.expectEqual(Change.nothing, again.change);
}

test "a provisional dog's first drag makes it held, for good; a stay or a refused drag writes nothing" {
    var rig: Rig = .{};
    rig.add(550, 550, .dog, .unclaimed);
    _ = rig.ask(alice, noon, asking(.at(300, 300), .stay));
    const far = rig.ask(alice, noon.after(10), asking(.at(300, 300), .{ .drag = .{ .dx = outcomes.longest_drag + 1, .dy = 0 } }));
    try testing.expectEqual(outcomes.MoveOutcome{ .refused = .too_far_at_once }, far.scene.own.has_dog.move);
    try testing.expectEqual(Change.nothing, far.change);
    try testing.expect(rig.all[0].claim == .provisional);
    const dragged = rig.ask(alice, noon.after(60), asking(.at(300, 300), .{ .drag = .{ .dx = 20, .dy = -10 } }));
    try testing.expectEqual(frames.ParkPoint.at(570, 540), dragged.change.moved.at.point);
    try testing.expectEqual(held(alice), dragged.change.moved.claim);
    // Held: a year later still theirs.
    const later = rig.ask(alice, noon.after(365 * 24 * 60 * 60), asking(.at(300, 300), .stay));
    try testing.expectEqual(scene.OwnIs.the_dog_held, later.scene.own.has_dog.is);
    try testing.expectEqual(Change.nothing, later.change);
}

test "a provisional claim not dragged in 120 s ends: the dog is free where it stands, and its human is given one again" {
    var rig: Rig = .{};
    rig.add(550, 550, .dog, .unclaimed);
    _ = rig.ask(alice, noon, asking(.at(300, 300), .stay));
    // At 119 s Bob finds no dog free; at 120 s he is given Alice's.
    try testing.expect(rig.ask(bob, noon.after(119), asking(.at(300, 300), .stay)).scene.own == .no_dog_free);
    const b = rig.ask(bob, noon.after(120), asking(.at(300, 300), .stay));
    try testing.expectEqual(claiming.Previously{ .human = alice }, b.change.given.from);
    try testing.expectEqual(frames.ParkPoint.at(550, 550), b.change.given.dog.at.point);
    // Alice, back, holds none now, and with no dog free, is given none.
    try testing.expect(rig.ask(alice, noon.after(121), asking(.at(300, 300), .stay)).scene.own == .no_dog_free);
}

test "a human whose provisional claim ended is given a dog again, maybe the same one" {
    var rig: Rig = .{};
    rig.add(550, 550, .dog, .unclaimed);
    _ = rig.ask(alice, noon, asking(.at(300, 300), .stay));
    const again = rig.ask(alice, noon.after(500), asking(.at(300, 300), .{ .drag = .{ .dx = 5, .dy = 0 } }));
    // Given anew (it stays: a drag meant for a dog that had ended moves nothing).
    try testing.expectEqual(scene.OwnIs.a_dog_newly_theirs, again.scene.own.has_dog.is);
    try testing.expectEqual(outcomes.MoveOutcome.stayed, again.scene.own.has_dog.move);
    try testing.expectEqual(claiming.Previously{ .human = alice }, again.change.given.from);
}

test "with no dog free, no dog is given: the scene comes with every dog among the others, and nothing changes" {
    var rig: Rig = .{};
    rig.add(400, 400, .dog, held(alice));
    rig.add(420, 400, .poodle, .{ .provisional = .madeAt(bob, noon) });
    const carol: HumanId = .of(3);
    const a = rig.ask(carol, noon.after(1), asking(.at(300, 300), .{ .drag = .{ .dx = 5, .dy = 0 } }));
    try testing.expect(a.scene.own == .no_dog_free);
    try testing.expectEqual(Change.nothing, a.change);
    try testing.expectEqual(@as(usize, 2), a.scene.others.len);
    // Nobody lost a dog.
    try testing.expectEqual(held(alice), rig.all[0].claim);
}

test "a drag across the seam wraps the dog, drawn on the viewport's side of it" {
    var rig: Rig = .{};
    rig.add(550, 550, .dog, held(alice));
    const a = rig.ask(alice, noon, asking(.at(900, 400), .{ .drag = .{ .dx = 600, .dy = 0 } }));
    try testing.expectEqual(frames.ParkPoint.at(150, 550), a.change.moved.at.point);
    try testing.expectEqual(frames.PlanePoint.at(1150, 550), a.scene.own.has_dog.drawn.at);
}

test "the others are every other dog in what the scene covers, claimed or not, copies across the seam" {
    var rig: Rig = .{};
    rig.add(980, 500, .dog, held(alice));
    rig.add(20, 500, .poodle, .unclaimed);
    rig.add(500, 100, .poodle, held(bob));
    // A viewport straddling the east seam: the dog at 20 is seen at 1020.
    const a = rig.ask(alice, noon, asking(.at(850, 400), .stay)).scene;
    try testing.expectEqual(@as(usize, 1), a.others.len);
    try testing.expectEqual(frames.PlanePoint.at(1020, 500), a.others[0].at);
    for (a.others) |d| try testing.expect(a.covers().holds(d.at) == .inside);
    try testing.expectEqual(frames.PlanePoint.at(980, 500), a.own.has_dog.drawn.at);
}

test "a scene wider than the park shows a dog at every copy in it" {
    var rig: Rig = .{};
    rig.add(100, 100, .dog, held(alice));
    rig.add(500, 500, .poodle, .unclaimed);
    var r = asking(.at(-400, 400), .stay);
    r.viewport.size.width = 1500;
    // Covered from -600 to 1300 across: the poodle's copies at -500 and 500.
    const a = rig.ask(alice, noon, r).scene;
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

test "the others cut at the room given, and the scene says more are there" {
    var rig: Rig = .{};
    rig.add(550, 550, .dog, held(alice));
    for (0..5) |i| rig.add(@intCast(400 + 10 * i), 400, .dog, .unclaimed);
    var others: [3]dogs.Drawn = undefined;
    const a = answer(small, rig.list.population(), rig.all[0..rig.count], alice, rig.holding(alice), noon, asking(.at(300, 300), .stay), .{ .others = &others, .found = &rig.found });
    try testing.expectEqual(@as(usize, 3), a.scene.others.len);
    try testing.expectEqual(population.Completeness.more_in_region, a.scene.others_completeness);
}

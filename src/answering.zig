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

/// What a human holds as they ask: a dog, or none (they are new, or their
/// dog was taken over while they were away).
pub const Holding = union(enum) {
    holds: DogId,
    holds_none,
};

/// Whether the asker's device has been here before: a request that came back
/// with the cookie an earlier one set, or a device's first, with none.
/// **A FIRST VISIT'S CLAIM IS SHOWN, NOT KEPT** (docs/FIXED-DOGS.md): the
/// dog shows as theirs, but nothing is written and nobody loses a dog, so a
/// loop of cookie-less requests cannot churn real humans' claims. Their
/// next request, with the cookie, claims for real.
pub const Standing = enum { returning, first_visit };

/// What a request changed.
pub const Change = union(enum) {
    nothing,
    /// A dog the human holds moved: kept now.
    moved: dogs.Dog,
    /// A dog the human holds, only touched (a stay, or a refused move): kept
    /// as the world's touch policy says (world.zig, at most once an hour).
    touched: dogs.Dog,
    /// A dog newly claimed, and from whom.
    claimed: NewClaim,
};

pub const NewClaim = struct {
    dog: dogs.Dog,
    from: Previously,
};

/// Who held a dog before it was claimed.
pub const Previously = union(enum) {
    nobody,
    human: HumanId,
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

/// The answer to `human`'s `request`, at `now`: a human who holds no dog
/// claims one first (claiming.claimFor), then the move is decided, then the
/// others are found in what the scene covers, piece by piece across the
/// seam. `all[i]` is dog `i`; `pop` indexes the same dogs by where they are.
pub fn answer(p: park.Park, pop: population.Population, all: []const dogs.Dog, human: HumanId, standing: Standing, holding: Holding, now: dogs.Instant, request: scene.SceneRequest, room: Room) Answered {
    const touched: dogs.Claim = .{ .claimed = .{ .by = human, .touched = now } };
    var move: outcomes.MoveOutcome = undefined;
    var after: dogs.Dog = undefined;
    var change: Change = undefined;
    switch (holding) {
        .holds => |id| {
            const before = all[id.number()];
            std.debug.assert(before.claim == .claimed and before.claim.claimed.by == human);
            move = outcomes.decide(p, before.at, request.move);
            after = before;
            after.at = move.dogAt(before.at);
            after.claim = touched;
            change = switch (move) {
                .moved => .{ .moved = after },
                .stayed, .refused => .{ .touched = after },
            };
        },
        .holds_none => {
            const claim = claiming.claimFor(p, all);
            const id, const from: Previously = switch (claim) {
                .unclaimed => |id| .{ id, .nobody },
                .taken_over => |t| .{ t.dog, .{ .human = t.from } },
            };
            // The first request of a claim stays: they have not seen their dog yet.
            move = .stayed;
            after = all[id.number()];
            after.claim = touched;
            change = switch (standing) {
                .returning => .{ .claimed = .{ .dog = after, .from = from } },
                .first_visit => .nothing,
            };
        },
    }
    // **THE WIRE IS THE GATE**: `request` comes through wire.WireSceneRequest.read,
    // which bounds the viewport; one from anywhere else may overflow coverFor.
    const others = othersIn(p, pop, after.id, scene.coverFor(request.viewport), room);
    return .{ .scene = .{
        .viewport = request.viewport,
        .own = after.drawnNear(p, request.viewport.centre()),
        .others = others.drawn,
        .others_completeness = others.completeness,
        .park_size = p.size,
        .move = move,
    }, .change = change };
}

const Others = struct {
    drawn: []const dogs.Drawn,
    completeness: population.Completeness,
};

/// Every copy of every dog but `own` in `covers`, claimed or not, as many as
/// `room` holds.
fn othersIn(p: park.Park, pop: population.Population, own: DogId, covers: park.PlaneRect, room: Room) Others {
    var n: usize = 0;
    var completeness: population.Completeness = .all_in_region;
    var pieces = covers.pieces(p);
    while (true) switch (pieces.nextPiece()) {
        .done => break,
        .piece => |piece| {
            const most = @min(room.found.len, room.others.len - n);
            const found = pop.near(.{ .region = piece.region, .except = own }, room.found[0..most]);
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

/// A park of a few dogs, kept as the world keeps them: every change put
/// back into the list and the index.
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

    fn holding(self: *const Rig, human: HumanId) Holding {
        for (self.all[0..self.count]) |d| switch (d.claim) {
            .claimed => |c| if (c.by == human) return .{ .holds = d.id },
            .unclaimed => {},
        };
        return .holds_none;
    }

    fn keep(self: *Rig, d: dogs.Dog) void {
        self.all[d.id.number()] = d;
        _ = self.list.population().put(d);
    }

    fn ask(self: *Rig, human: HumanId, now: dogs.Instant, r: scene.SceneRequest) Answered {
        const a = answer(small, self.list.population(), self.all[0..self.count], human, .returning, self.holding(human), now, r, .{ .others = &self.others, .found = &self.found });
        switch (a.change) {
            .moved, .touched => |d| self.keep(d),
            .claimed => |c| self.keep(c.dog),
            .nothing => {},
        }
        return a;
    }
};

test "a human with no dog claims the unclaimed one nearest the centre, and their first request stays" {
    var rig: Rig = .{};
    rig.add(100, 100, .dog, .unclaimed);
    rig.add(540, 520, .poodle, .unclaimed);
    const a = rig.ask(alice, noon, asking(.at(300, 300), .{ .drag = .{ .dx = 7, .dy = 0 } }));
    try testing.expectEqual(NewClaim{
        .dog = .{ .id = .of(1), .at = small.wrap(.at(540, 520)), .breed = .poodle, .claim = .{ .claimed = .{ .by = alice, .touched = noon } } },
        .from = .nobody,
    }, a.change.claimed);
    try testing.expectEqual(outcomes.MoveOutcome.stayed, a.scene.move);
    try testing.expectEqual(frames.PlanePoint.at(540, 520), a.scene.own.at);
}

test "a drag moves the dog held and touches it; a stay or a refused drag only touches it" {
    var rig: Rig = .{};
    rig.add(550, 550, .dog, .unclaimed);
    _ = rig.ask(alice, noon, asking(.at(300, 300), .stay));
    const later: dogs.Instant = .of(noon.seconds() + 60);
    const dragged = rig.ask(alice, later, asking(.at(300, 300), .{ .drag = .{ .dx = 20, .dy = -10 } }));
    try testing.expectEqual(frames.ParkPoint.at(570, 540), dragged.change.moved.at.point);
    try testing.expectEqual(later, dragged.change.moved.claim.claimed.touched);
    const stay = rig.ask(alice, later, asking(.at(300, 300), .stay));
    try testing.expectEqual(frames.ParkPoint.at(570, 540), stay.change.touched.at.point);
    const far = rig.ask(alice, later, asking(.at(300, 300), .{ .drag = .{ .dx = outcomes.longest_drag + 1, .dy = 0 } }));
    try testing.expectEqual(outcomes.MoveOutcome{ .refused = .too_far_at_once }, far.scene.move);
    try testing.expect(far.change == .touched);
}

test "with every dog claimed, a newcomer takes the stalest, and its old human finds none and claims again" {
    var rig: Rig = .{};
    rig.add(550, 550, .dog, .{ .claimed = .{ .by = alice, .touched = .of(100) } });
    rig.add(100, 100, .poodle, .{ .claimed = .{ .by = bob, .touched = .of(200) } });
    const carol: HumanId = .of(3);
    const c = rig.ask(carol, noon, asking(.at(300, 300), .stay));
    try testing.expectEqual(Previously{ .human = alice }, c.change.claimed.from);
    try testing.expectEqual(dogs.DogId.of(0), c.change.claimed.dog.id);
    // The dog keeps where it stands; it only changes hands.
    try testing.expectEqual(frames.ParkPoint.at(550, 550), c.change.claimed.dog.at.point);
    // Alice holds nothing now, and takes Bob's, the stalest left.
    try testing.expectEqual(Holding.holds_none, rig.holding(alice));
    const a = rig.ask(alice, .of(noon.seconds() + 1), asking(.at(300, 300), .stay));
    try testing.expectEqual(Previously{ .human = bob }, a.change.claimed.from);
}

test "a drag across the seam wraps the dog, drawn on the viewport's side of it" {
    var rig: Rig = .{};
    rig.add(550, 550, .dog, .unclaimed);
    _ = rig.ask(alice, noon, asking(.at(300, 300), .stay));
    const a = rig.ask(alice, noon, asking(.at(900, 400), .{ .drag = .{ .dx = 600, .dy = 0 } }));
    try testing.expectEqual(frames.ParkPoint.at(150, 550), a.change.moved.at.point);
    try testing.expectEqual(frames.PlanePoint.at(1150, 550), a.scene.own.at);
}

test "the others are every other dog in what the scene covers, claimed or not, copies across the seam" {
    var rig: Rig = .{};
    rig.add(980, 500, .dog, .{ .claimed = .{ .by = alice, .touched = noon } });
    rig.add(20, 500, .poodle, .unclaimed);
    rig.add(500, 100, .poodle, .{ .claimed = .{ .by = bob, .touched = noon } });
    // A viewport straddling the east seam: the dog at 20 is seen at 1020.
    const a = rig.ask(alice, noon, asking(.at(850, 400), .stay)).scene;
    try testing.expectEqual(@as(usize, 1), a.others.len);
    try testing.expectEqual(frames.PlanePoint.at(1020, 500), a.others[0].at);
    for (a.others) |d| try testing.expect(a.covers().holds(d.at) == .inside);
    try testing.expectEqual(frames.PlanePoint.at(980, 500), a.own.at);
}

test "a scene wider than the park shows a dog at every copy in it" {
    var rig: Rig = .{};
    rig.add(100, 100, .dog, .{ .claimed = .{ .by = alice, .touched = noon } });
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
    rig.add(550, 550, .dog, .{ .claimed = .{ .by = alice, .touched = noon } });
    for (0..5) |i| rig.add(@intCast(400 + 10 * i), 400, .dog, .unclaimed);
    var others: [3]dogs.Drawn = undefined;
    const a = answer(small, rig.list.population(), rig.all[0..rig.count], alice, .returning, rig.holding(alice), noon, asking(.at(300, 300), .stay), .{ .others = &others, .found = &rig.found });
    try testing.expectEqual(@as(usize, 3), a.scene.others.len);
    try testing.expectEqual(population.Completeness.more_in_region, a.scene.others_completeness);
}

test "a first visit is shown a dog as its own, but keeps nothing and takes nobody's" {
    var rig: Rig = .{};
    rig.add(550, 550, .dog, .{ .claimed = .{ .by = alice, .touched = .of(100) } });
    const carol: HumanId = .of(3);
    const a = answer(small, rig.list.population(), rig.all[0..rig.count], carol, .first_visit, .holds_none, noon, asking(.at(300, 300), .stay), .{ .others = &rig.others, .found = &rig.found });
    try testing.expectEqual(Change.nothing, a.change);
    try testing.expectEqual(frames.PlanePoint.at(550, 550), a.scene.own.at);
    // Alice still holds it.
    try testing.expectEqual(Holding{ .holds = .of(0) }, rig.holding(alice));
}

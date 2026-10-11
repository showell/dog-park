//! Placement: where a new human's dog goes. The first free lattice spot in
//! a square spiral out from the park's centre, so the first humans see each
//! other. **FREE** means no dog within half a spacing of the spot on either
//! axis, edges included, measured across the seam (the park wraps).

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const population = @import("population.zig");
const outcomes = @import("outcomes.zig");
const HumanId = @import("humans.zig").HumanId;

/// The spot for `newcomer`'s dog in `p`, given who is there: the first free
/// one in the spiral, or `park_full`. (A population too full to take the dog
/// is the world's to say: this only looks.)
pub fn place(p: park.Park, pop: population.Population, newcomer: HumanId) outcomes.Placement {
    const extent = p.extent();
    const centre: Offset = .{ .column = extent.columns / 2, .row = extent.rows / 2 };
    var spiral: Spiral = .{};
    // Past this ring, the spiral is wholly off the park.
    const last_ring: Coord = @max(extent.columns, extent.rows);
    while (spiral.ring() <= last_ring) {
        const o = spiral.next();
        const column = centre.column + o.column;
        const row = centre.row + o.row;
        if (column < 0 or row < 0) continue;
        const spot: park.LatticeSpot = .{ .column = @intCast(column), .row = @intCast(row) };
        switch (p.pointOf(spot)) {
            .off_park => continue,
            .on => |at| switch (occupancy(p, pop, at, newcomer)) {
                .free => return .{ .placed = spot },
                .taken => continue,
            },
        }
    }
    return .{ .refused = .park_full };
}

const Coord = frames.Coord;

/// A step from the centre spot, in spots.
pub const Offset = struct { column: Coord, row: Coord };

/// The square spiral's offsets from the centre: (0, 0), then east 1, south
/// 1, west 2, north 2, east 3, south 3, ..., each leg one longer every two.
pub const Spiral = struct {
    at: Offset = .{ .column = 0, .row = 0 },
    leg: Coord = 0,
    taken_on_leg: Coord = 0,
    direction: Direction = .east,
    started: Started = .not_yet,

    const Direction = enum { east, south, west, north };
    const Started = enum { not_yet, yes };

    /// How far from the centre the spiral has reached, in spots.
    pub fn ring(self: Spiral) Coord {
        return @intCast(@max(@abs(self.at.column), @abs(self.at.row)));
    }

    pub fn next(self: *Spiral) Offset {
        if (self.started == .not_yet) {
            self.started = .yes;
            self.leg = 1;
            return self.at;
        }
        switch (self.direction) {
            .east => self.at.column += 1,
            .south => self.at.row += 1,
            .west => self.at.column -= 1,
            .north => self.at.row -= 1,
        }
        self.taken_on_leg += 1;
        if (self.taken_on_leg == self.leg) {
            self.taken_on_leg = 0;
            self.direction = switch (self.direction) {
                .east => .south,
                .south => .west,
                .west => .north,
                .north => .east,
            };
            // The legs grow after south and after north.
            if (self.direction == .west or self.direction == .east) self.leg += 1;
        }
        return self.at;
    }
};

pub const Occupancy = enum { free, taken };

/// Whether a dog stands within half a spacing of `at`, across the seam,
/// other than the newcomer's own (a newcomer has none, but if the world
/// asks again it is not in its own way).
pub fn occupancy(p: park.Park, pop: population.Population, at: park.InParkPoint, newcomer: HumanId) Occupancy {
    const half: Coord = park.lattice_spacing / 2;
    const around: park.PlaneRect = .{
        .top_left = frames.homeCopy(at.point).plus(.{ .dx = -half, .dy = -half }),
        .size = .{ .width = park.lattice_spacing + 1, .height = park.lattice_spacing + 1 },
    };
    var pieces = around.pieces(p);
    // One dog found is enough to know.
    var one: [1]dogs.Dog = undefined;
    while (true) switch (pieces.nextPiece()) {
        .piece => |piece| if (pop.near(.{ .region = piece.region, .except = newcomer }, &one).count > 0) return .taken,
        .done => return .free,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const five: park.Park = (park.Park.of(.{ .width = 500, .height = 500 })).park;

fn dogAt(owner: u64, at: frames.PlanePoint) dogs.Dog {
    return .{ .owner = .of(owner), .at = five.wrap(at), .breed = .dog };
}

test "the spiral: the centre, then east, south, west twice, north twice, east thrice" {
    var s: Spiral = .{};
    const expected = [_]Offset{
        .{ .column = 0, .row = 0 },   .{ .column = 1, .row = 0 },  .{ .column = 1, .row = 1 },
        .{ .column = 0, .row = 1 },   .{ .column = -1, .row = 1 }, .{ .column = -1, .row = 0 },
        .{ .column = -1, .row = -1 }, .{ .column = 0, .row = -1 }, .{ .column = 1, .row = -1 },
        .{ .column = 2, .row = -1 },
    };
    for (expected) |e| try testing.expectEqual(e, s.next());
}

test "the spiral visits every spot of a ring before the next" {
    var s: Spiral = .{};
    var seen: [9 * 9]u8 = @splat(0);
    while (true) {
        const o = s.next();
        if (s.ring() > 4) break;
        seen[@intCast((o.row + 4) * 9 + (o.column + 4))] += 1;
    }
    for (seen) |n| try testing.expectEqual(@as(u8, 1), n);
}

test "the first dog goes to the centre, the next ones spiral out" {
    var list: population.ListPopulation(30) = .{};
    const pop = list.population();
    const centre = place(five, pop, .of(1)).placed;
    try testing.expectEqual(park.LatticeSpot{ .column = 2, .row = 2 }, centre);
    _ = pop.put(.{ .owner = .of(1), .at = five.pointOf(centre).on, .breed = .dog });
    try testing.expectEqual(park.LatticeSpot{ .column = 3, .row = 2 }, place(five, pop, .of(2)).placed);
}

test "a taken spot is skipped, and a dog half a spacing off still takes it, across the seam too" {
    var list: population.ListPopulation(30) = .{};
    const pop = list.population();
    // The centre spot is at (250, 250); a dog 50 off on both axes takes it,
    // and, at the corner of four cells, the three other spots it touches:
    // the spiral's second, east, is skipped too, for its third.
    _ = pop.put(dogAt(1, .at(300, 200)));
    try testing.expectEqual(park.LatticeSpot{ .column = 3, .row = 3 }, place(five, pop, .of(9)).placed);
    // A dog 51 off does not.
    var other: population.ListPopulation(30) = .{};
    _ = other.population().put(dogAt(1, .at(301, 250)));
    try testing.expectEqual(park.LatticeSpot{ .column = 2, .row = 2 }, place(five, other.population(), .of(9)).placed);
    // Across the seam: spot (0, 0) is at (50, 50); a dog at (0, 0) is within
    // half a spacing of it; and spot (4, 4), at (450, 450), is within half
    // a spacing of (0, 0) across the seam, at the plane's (500, 500).
    var corner: population.ListPopulation(30) = .{};
    _ = corner.population().put(dogAt(1, .at(0, 0)));
    try testing.expectEqual(Occupancy.taken, occupancy(five, corner.population(), five.pointOf(.{ .column = 4, .row = 4 }).on, .of(9)));
    try testing.expectEqual(Occupancy.taken, occupancy(five, corner.population(), five.pointOf(.{ .column = 0, .row = 0 }).on, .of(9)));
    try testing.expectEqual(Occupancy.free, occupancy(five, corner.population(), five.pointOf(.{ .column = 1, .row = 1 }).on, .of(9)));
}

test "a full park is refused, and every spot was tried first" {
    var list: population.ListPopulation(30) = .{};
    const pop = list.population();
    var owner: u64 = 1;
    while (true) : (owner += 1) switch (place(five, pop, .of(owner))) {
        .placed => |spot| try testing.expectEqual(population.Put.added, pop.put(.{ .owner = .of(owner), .at = five.pointOf(spot).on, .breed = .dog })),
        .refused => |why| {
            try testing.expectEqual(outcomes.PlacementRefusal.park_full, why);
            break;
        },
    };
    try testing.expectEqual(@as(u64, 26), owner);
}

test "a long thin park is spiralled to its ends" {
    const thin = (park.Park.of(.{ .width = 1000, .height = 100 })).park;
    var list: population.ListPopulation(30) = .{};
    const pop = list.population();
    var owner: u64 = 1;
    while (place(thin, pop, .of(owner)) == .placed) : (owner += 1) {
        _ = pop.put(.{ .owner = .of(owner), .at = thin.pointOf(place(thin, pop, .of(owner)).placed).on, .breed = .dog });
    }
    try testing.expectEqual(@as(u64, 11), owner);
}

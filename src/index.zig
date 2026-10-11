//! The index: the population in a grid of square cells over the park.
//!
//! **A GRID, NOT A QUADTREE.** Dogs start on a lattice and drift; they never
//! pile into the dense clusters a quadtree is built to split. Every question
//! is a rectangle about a viewport's size, which a grid answers from the few
//! cells under it, with no tree to balance. The cells are at most
//! `most_cells_across` on a side, so the grid's memory is bounded by its
//! own constant and the dogs' by `capacity`, all of it taken at `init`.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const contract = @import("population.zig");
const HumanId = @import("humans.zig").HumanId;

/// The smallest cell's side: about half a viewport, so a scene touches a
/// handful of cells.
pub const smallest_cell: u31 = 500;
/// The most cells across or down: a park of the longest side has cells of
/// 4,096 rather than two million of them.
pub const most_cells_across: u31 = 256;

pub const GridPopulation = struct {
    park: park.Park,
    cell_side: u31,
    columns: u31,
    rows: u31,
    /// Each cell's first entry, or `.none`.
    heads: []Slot,
    entries: []Entry,
    used: u32,
    by_owner: std.AutoHashMapUnmanaged(HumanId, Slot),

    /// An entry's place in `entries`, or none: a list's end.
    const Slot = enum(u32) { none = std.math.maxInt(u32), _ };

    const Entry = struct {
        dog: dogs.Dog,
        cell: u32,
        previous: Slot,
        next: Slot,
    };

    pub fn init(allocator: std.mem.Allocator, p: park.Park, capacity: u32) !GridPopulation {
        const longest = @max(p.size.width, p.size.height);
        const cell_side = @max(smallest_cell, std.math.divCeil(u31, longest, most_cells_across) catch unreachable);
        const columns = std.math.divCeil(u31, p.size.width, cell_side) catch unreachable;
        const rows = std.math.divCeil(u31, p.size.height, cell_side) catch unreachable;
        const heads = try allocator.alloc(Slot, @as(usize, columns) * rows);
        errdefer allocator.free(heads);
        @memset(heads, .none);
        const entries = try allocator.alloc(Entry, capacity);
        errdefer allocator.free(entries);
        var by_owner: std.AutoHashMapUnmanaged(HumanId, Slot) = .empty;
        try by_owner.ensureTotalCapacity(allocator, capacity);
        return .{ .park = p, .cell_side = cell_side, .columns = columns, .rows = rows, .heads = heads, .entries = entries, .used = 0, .by_owner = by_owner };
    }

    pub fn deinit(self: *GridPopulation, allocator: std.mem.Allocator) void {
        allocator.free(self.heads);
        allocator.free(self.entries);
        self.by_owner.deinit(allocator);
    }

    pub fn population(self: *GridPopulation) contract.Population {
        return .{ .ptr = self, .vtable = &.{ .near = near, .lookup = lookup, .put = put } };
    }

    fn of(ptr: *anyopaque) *GridPopulation {
        return @ptrCast(@alignCast(ptr));
    }

    fn cellOf(self: *const GridPopulation, at: park.InParkPoint) u32 {
        const column: u32 = @intCast(@divFloor(at.point.x.number(), self.cell_side));
        const row: u32 = @intCast(@divFloor(at.point.y.number(), self.cell_side));
        return row * self.columns + column;
    }

    fn link(self: *GridPopulation, slot: Slot, cell: u32) void {
        const e = &self.entries[@intFromEnum(slot)];
        e.cell = cell;
        e.previous = .none;
        e.next = self.heads[cell];
        if (e.next != .none) self.entries[@intFromEnum(e.next)].previous = slot;
        self.heads[cell] = slot;
    }

    fn unlink(self: *GridPopulation, slot: Slot) void {
        const e = self.entries[@intFromEnum(slot)];
        if (e.previous == .none) self.heads[e.cell] = e.next else self.entries[@intFromEnum(e.previous)].next = e.next;
        if (e.next != .none) self.entries[@intFromEnum(e.next)].previous = e.previous;
    }

    fn near(ptr: *anyopaque, q: contract.Near, into: []dogs.Dog) contract.Found {
        const self = of(ptr);
        const all: contract.Found = .{ .count = 0, .completeness = .all_in_region };
        if (q.region.size.width == 0 or q.region.size.height == 0) return all;
        // The cells under the region, in i64 where nothing overflows, cut to the grid.
        const left: i64 = q.region.top_left.x.number();
        const top: i64 = q.region.top_left.y.number();
        const right = left + q.region.size.width - 1;
        const bottom = top + q.region.size.height - 1;
        const first_column = @max(0, @divFloor(left, self.cell_side));
        const first_row = @max(0, @divFloor(top, self.cell_side));
        const last_column = @min(@as(i64, self.columns) - 1, @divFloor(right, self.cell_side));
        const last_row = @min(@as(i64, self.rows) - 1, @divFloor(bottom, self.cell_side));
        if (first_column > last_column or first_row > last_row) return all;
        var count: u32 = 0;
        var row = first_row;
        while (row <= last_row) : (row += 1) {
            var column = first_column;
            while (column <= last_column) : (column += 1) {
                var slot = self.heads[@intCast(row * self.columns + column)];
                while (slot != .none) : (slot = self.entries[@intFromEnum(slot)].next) {
                    const d = self.entries[@intFromEnum(slot)].dog;
                    if (d.owner == q.except or q.region.holds(d.at.point) == .outside) continue;
                    if (count == into.len) return .{ .count = count, .completeness = .more_in_region };
                    into[count] = d;
                    count += 1;
                }
            }
        }
        return .{ .count = count, .completeness = .all_in_region };
    }

    fn lookup(ptr: *anyopaque, owner: HumanId) contract.Lookup {
        const self = of(ptr);
        const slot = self.by_owner.get(owner) orelse return .no_dog;
        return .{ .found = self.entries[@intFromEnum(slot)].dog };
    }

    fn put(ptr: *anyopaque, dog: dogs.Dog) contract.Put {
        const self = of(ptr);
        const cell = self.cellOf(dog.at);
        if (self.by_owner.get(dog.owner)) |slot| {
            const e = &self.entries[@intFromEnum(slot)];
            const was = e.dog.at;
            e.dog = dog;
            if (e.cell != cell) {
                self.unlink(slot);
                self.link(slot, cell);
            }
            return .{ .replaced = was };
        }
        if (self.used == self.entries.len) return .refused_full;
        const slot: Slot = @enumFromInt(self.used);
        self.used += 1;
        self.entries[@intFromEnum(slot)].dog = dog;
        self.link(slot, cell);
        self.by_owner.putAssumeCapacityNoClobber(dog.owner, slot);
        return .added;
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn byOwner(_: void, a: dogs.Dog, b: dogs.Dog) bool {
    return a.owner.number() < b.owner.number();
}

/// The same operations on the grid and on the list, the oracle; every
/// answer the same (`near`'s as a set: the contract promises no order).
fn agree(seed: u64, size: frames.Size, capacity: comptime_int, owners: u64, operations: usize) !void {
    const p = (park.Park.of(size)).park;
    var grid = try GridPopulation.init(testing.allocator, p, capacity);
    defer grid.deinit(testing.allocator);
    var list: contract.ListPopulation(capacity) = .{};
    const g = grid.population();
    const l = list.population();
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var into_grid: [capacity + 1]dogs.Dog = undefined;
    var into_list: [capacity + 1]dogs.Dog = undefined;
    var all: [capacity + 1]dogs.Dog = undefined;
    const width: frames.Coord = p.size.width;
    const height: frames.Coord = p.size.height;
    for (0..operations) |_| {
        switch (random.uintLessThan(u8, 3)) {
            0 => {
                const at = p.wrap(.at(random.intRangeLessThan(frames.Coord, -width, 2 * width), random.intRangeLessThan(frames.Coord, -height, 2 * height)));
                const dog: dogs.Dog = .{ .owner = .of(random.uintLessThan(u64, owners)), .at = at, .breed = random.enumValue(dogs.Breed) };
                try testing.expectEqual(l.put(dog), g.put(dog));
            },
            1 => {
                const owner: HumanId = .of(random.uintLessThan(u64, owners));
                try testing.expectEqual(l.lookup(owner), g.lookup(owner));
            },
            else => {
                // Any rectangle, some reaching past the park (the index cuts them).
                const region: park.ParkRect = .{
                    .top_left = .at(random.intRangeLessThan(frames.Coord, -200, width), random.intRangeLessThan(frames.Coord, -200, height)),
                    .size = .{ .width = random.uintLessThan(u31, p.size.width + 400), .height = random.uintLessThan(u31, p.size.height + 400) },
                };
                const q: contract.Near = .{ .region = region, .except = .of(random.uintLessThan(u64, owners)) };
                const most = random.uintAtMost(usize, capacity);
                const found_grid = g.near(q, into_grid[0..most]);
                const found_list = l.near(q, into_list[0..most]);
                try testing.expectEqual(found_list.completeness, found_grid.completeness);
                try testing.expectEqual(found_list.count, found_grid.count);
                const every = l.near(q, &all).dogsIn(&all);
                const got = into_grid[0..found_grid.count];
                switch (found_grid.completeness) {
                    .all_in_region => {
                        std.mem.sort(dogs.Dog, got, {}, byOwner);
                        std.mem.sort(dogs.Dog, into_list[0..found_list.count], {}, byOwner);
                        try testing.expectEqualSlices(dogs.Dog, into_list[0..found_list.count], got);
                    },
                    // Cut: as many as asked, each one of the region's.
                    .more_in_region => for (got) |d| {
                        for (every) |e| {
                            if (std.meta.eql(d, e)) break;
                        } else return error.TestUnexpectedResult;
                    },
                }
                for (got) |d| try testing.expect(d.owner != q.except);
            },
        }
    }
}

test "the grid answers as the list does: a 5,000 park, fuller than its capacity" {
    for (0..20) |seed| try agree(seed, .{ .width = 5000, .height = 5000 }, 40, 60, 600);
}

test "the grid answers as the list does: a park of one cell, and a long thin one" {
    for (0..10) |seed| try agree(100 + seed, .{ .width = 300, .height = 300 }, 12, 16, 300);
    for (0..10) |seed| try agree(200 + seed, .{ .width = 20_000, .height = 100 }, 30, 40, 400);
}

test "the grid's memory: cells at most most_cells_across a side, and full at capacity" {
    const p = (park.Park.of(.{ .width = park.longest_side - park.longest_side % park.lattice_spacing, .height = 5000 })).park;
    var grid = try GridPopulation.init(testing.allocator, p, 2);
    defer grid.deinit(testing.allocator);
    try testing.expect(grid.columns <= most_cells_across and grid.rows <= most_cells_across);
    const pop = grid.population();
    const at = p.wrap(.at(0, 0));
    try testing.expectEqual(contract.Put.added, pop.put(.{ .owner = .of(1), .at = at, .breed = .dog }));
    try testing.expectEqual(contract.Put.added, pop.put(.{ .owner = .of(2), .at = at, .breed = .dog }));
    try testing.expectEqual(contract.Put.refused_full, pop.put(.{ .owner = .of(3), .at = at, .breed = .dog }));
    // A full grid still moves the dogs it holds.
    try testing.expectEqual(contract.Put{ .replaced = at }, pop.put(.{ .owner = .of(2), .at = p.wrap(.at(-1, -1)), .breed = .dog }));
}

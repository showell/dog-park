//! The world: the park, its population, and the store under them (webbox's
//! `store` and `counter`). The only module here that touches a disk.
//!
//!   <data>/next-human      the next human's id (webbox.counter)
//!   <data>/dogs/<id>       a dog, its `stored.StoredDog` bytes, one file a
//!                          human, written whole by `store.replace`
//!
//! **ONE HANDLER AT A TIME**: webbox's hosts run one route at a time, so the
//! world needs no lock of its own.
//! **A FOLDER HOLDS AT MOST 65,536 ENTRIES ON FAT** (webbox.store). A dog's
//! name takes at most two (an id past eight digits is a long name), and a
//! stopped write's temporary, one a dog at most, two more: four a dog, so
//! `dogs/` holds `most_dogs` (16,000) and no more. Past it, the folder is
//! the box's to fan out. (The 5,000 park's lattice has 2,500 spots, so
//! placement says the park is full long before.)

const std = @import("std");
const Io = std.Io;
const webbox = @import("webbox");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const contract = @import("population.zig");
const index = @import("index.zig");
const stored = @import("stored.zig");
const HumanId = @import("humans.zig").HumanId;

/// The most dogs a world holds: under FAT's 65,536 entries in `dogs/`.
pub const most_dogs: u32 = 16_000;

/// The park every world is, for now (the build brief: 5,000 by 5,000).
pub const the_park: park.Park = (park.Park.of(.{ .width = 5000, .height = 5000 })).park;

pub const World = struct {
    park: park.Park,
    grid: index.GridPopulation,
    /// The data folder, as the host spells it; lives as long as the world.
    data_dir: []const u8,
    /// Temporaries a stopped `store.replace` left in `dogs/`, passed over.
    left_over: u32,

    /// The world in `data_dir`, every record loaded into the index; or the
    /// record that stops it, named. `base` holds what lives as long as the
    /// world; `scratch` what the loading needs.
    pub fn open(io: Io, base: std.mem.Allocator, scratch: std.mem.Allocator, data_dir: []const u8, p: park.Park, capacity: u32) !Opened {
        var grid = try index.GridPopulation.init(base, p, capacity);
        // The index is the world's once it opens, and freed on any other way out.
        var kept_by: enum { this_call, the_world } = .this_call;
        defer if (kept_by == .this_call) grid.deinit(base);
        const folder = try std.fs.path.join(scratch, &.{ data_dir, "dogs" });
        var left_over: u32 = 0;
        var highest_owner: u64 = 0;
        for (try webbox.store.list(io, scratch, folder)) |entry| {
            // A stop inside `store.replace` leaves its temporary sibling (a
            // file, `~` and eight hex digits, `.tmp`, in either case on FAT);
            // the next replace of that dog writes over it.
            if (entry.kind == .file and entry.name.len == 13 and entry.name[0] == '~' and std.ascii.endsWithIgnoreCase(entry.name, ".tmp")) {
                left_over += 1;
                continue;
            }
            const refused = struct {
                fn of(name: []const u8, why: RecordRefusal) Opened {
                    return .{ .refused = .{ .name = name, .why = why } };
                }
            }.of;
            if (entry.kind != .file) return refused(entry.name, .not_a_file);
            const owner = switch (idOfName(entry.name)) {
                .id => |h| h,
                .not_an_id => return refused(entry.name, .name_not_a_human_id),
            };
            const bytes = webbox.store.read(io, scratch, try std.fs.path.join(scratch, &.{ folder, entry.name }), .limited(@sizeOf(stored.StoredDog) + 1)) catch |e| switch (e) {
                error.StreamTooLong => return refused(entry.name, .wrong_size),
                else => return e,
            };
            if (bytes.len != @sizeOf(stored.StoredDog)) return refused(entry.name, .wrong_size);
            const record = std.mem.bytesToValue(stored.StoredDog, bytes);
            const dog = switch (record.read(p)) {
                .dog => |d| d,
                .unknown_format => return refused(entry.name, .unknown_format),
                .unknown_breed => return refused(entry.name, .unknown_breed),
                .outside_park => return refused(entry.name, .outside_park),
            };
            if (dog.owner != owner) return refused(entry.name, .owner_not_its_name);
            highest_owner = @max(highest_owner, owner.number());
            switch (grid.population().put(dog)) {
                .added => {},
                .refused_full => return refused(entry.name, .more_than_capacity),
                // Two names for one id differ only in case, or in leading zeros:
                // idOfName takes neither, so this is not reached.
                .replaced => unreachable,
            }
        }
        // **THE NEXT ID IS PAST EVERY DOG'S**: a counter lost or restored
        // behind the dogs would hand a new device a human who has a dog, and
        // their dog with it.
        const next = try webbox.counter.peek(io, scratch, try std.fs.path.join(scratch, &.{ data_dir, "next-human" }));
        if (grid.used > 0 and next <= highest_owner) return .{ .refused = .{ .name = "next-human", .why = .next_human_not_past_every_dog } };
        kept_by = .the_world;
        return .{ .world = .{ .park = p, .grid = grid, .data_dir = data_dir, .left_over = left_over } };
    }

    pub fn close(self: *World, base: std.mem.Allocator) void {
        self.grid.deinit(base);
    }

    pub fn population(self: *World) contract.Population {
        return self.grid.population();
    }

    /// Whether the index can take one more human's dog.
    pub fn room(self: *const World) contract.Space {
        return if (self.grid.used < self.grid.entries.len) .room_for_one_more else .full;
    }

    /// A new human's id, handed out once (webbox.counter).
    pub fn newHuman(self: *World, io: Io, scratch: std.mem.Allocator) !HumanId {
        const n = try webbox.counter.next(io, scratch, try std.fs.path.join(scratch, &.{ self.data_dir, "next-human" }));
        const h: HumanId = .of(@intCast(n));
        // `open` saw the counter past every dog; one moved back since is a bug.
        if (self.population().lookup(h) == .found) return error.NewHumanHasADog;
        return h;
    }

    /// **KEEPS A DOG**, written first and then indexed, so the index never
    /// holds a dog the disk does not. A new owner's dog with no room is
    /// `error.PopulationFull`, before anything is written.
    pub fn keep(self: *World, io: Io, scratch: std.mem.Allocator, dog: dogs.Dog) !void {
        if (self.population().lookup(dog.owner) == .no_dog and self.room() == .full) return error.PopulationFull;
        var name: [20]u8 = undefined;
        const path = try std.fs.path.join(scratch, &.{ self.data_dir, "dogs", nameOf(dog.owner, &name) });
        try webbox.store.replace(io, scratch, path, std.mem.asBytes(&stored.StoredDog.of(dog)), .{});
        switch (self.population().put(dog)) {
            .added, .replaced => {},
            .refused_full => unreachable, // room was checked
        }
    }
};

pub const Opened = union(enum) {
    world: World,
    refused: Refused,
};

/// A record that stops the world from opening, by its file's name in
/// `dogs/` (or `next-human`, the counter, beside it).
pub const Refused = struct {
    name: []const u8,
    why: RecordRefusal,
};

pub const RecordRefusal = enum {
    not_a_file,
    name_not_a_human_id,
    wrong_size,
    unknown_format,
    unknown_breed,
    outside_park,
    owner_not_its_name,
    more_than_capacity,
    next_human_not_past_every_dog,
};

/// A human's id as a file's name: its digits.
pub fn nameOf(h: HumanId, buffer: *[20]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{h.number()}) catch unreachable;
}

pub const NameAsId = union(enum) {
    id: HumanId,
    not_an_id,
};

/// The human a file's name names: digits only, canonical (no leading zero),
/// so one id has one name.
pub fn idOfName(name: []const u8) NameAsId {
    if (name.len == 0 or (name.len > 1 and name[0] == '0')) return .not_an_id;
    for (name) |c| if (!std.ascii.isDigit(c)) return .not_an_id;
    const n = std.fmt.parseInt(u64, name, 10) catch return .not_an_id;
    return .{ .id = .of(n) };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const placement = @import("placement.zig");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    tmp: testing.TmpDir,
    data_dir: []const u8,

    fn init(self: *Fixture) !void {
        self.arena = .init(testing.allocator);
        self.threaded = .init(self.arena.allocator(), .{});
        self.tmp = testing.tmpDir(.{});
        self.data_dir = try std.fs.path.join(self.arena.allocator(), &.{ ".zig-cache", "tmp", &self.tmp.sub_path, "data" });
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.threaded.deinit();
        self.arena.deinit();
    }

    fn io(self: *Fixture) Io {
        return self.threaded.io();
    }

    fn open(self: *Fixture) !Opened {
        return World.open(self.io(), testing.allocator, self.arena.allocator(), self.data_dir, the_park, 100);
    }

    fn file(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        const a = self.arena.allocator();
        try webbox.store.write(self.io(), a, try std.fs.path.join(a, &.{ self.data_dir, "dogs", name }), bytes, .{});
    }
};

test "place, move, then a fresh load sees the same dogs" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var w = (try f.open()).world;
    const alice = try w.newHuman(f.io(), a);
    const bob = try w.newHuman(f.io(), a);
    try testing.expect(alice != bob);
    for ([_]HumanId{ alice, bob }) |h| {
        const spot = placement.place(w.park, w.population(), h).placed;
        try w.keep(f.io(), a, .{ .owner = h, .at = w.park.pointOf(spot).on, .breed = .poodle });
    }
    const moved: dogs.Dog = .{ .owner = alice, .at = w.park.wrap(.at(-10, 4990)), .breed = .poodle };
    try w.keep(f.io(), a, moved);
    const bob_dog = w.population().lookup(bob).found;
    w.close(testing.allocator);

    var again = (try f.open()).world;
    defer again.close(testing.allocator);
    try testing.expectEqual(moved, again.population().lookup(alice).found);
    try testing.expectEqual(bob_dog, again.population().lookup(bob).found);
    try testing.expectEqual(@as(u32, 2), again.grid.used);
    // Ids go on from where they were.
    try testing.expectEqual(HumanId.of(3), try again.newHuman(f.io(), a));
}

test "a record that does not read stops the load, named" {
    const Case = struct { name: []const u8, bytes: []const u8, why: RecordRefusal };
    const good = stored.StoredDog.of(.{ .owner = .of(7), .at = the_park.wrap(.at(1, 1)), .breed = .dog });
    var outside = good;
    outside.park_x = 5000;
    var unknown = good;
    unknown.breed_byte = 200;
    const cases = [_]Case{
        .{ .name = "07", .bytes = std.mem.asBytes(&good), .why = .name_not_a_human_id },
        .{ .name = "seven", .bytes = std.mem.asBytes(&good), .why = .name_not_a_human_id },
        .{ .name = "7", .bytes = std.mem.asBytes(&good)[0..23], .why = .wrong_size },
        .{ .name = "7", .bytes = std.mem.asBytes(&good) ++ "x", .why = .wrong_size },
        .{ .name = "7", .bytes = &(@as([4096]u8, @splat(1))), .why = .wrong_size },
        .{ .name = "8", .bytes = std.mem.asBytes(&good), .why = .owner_not_its_name },
        .{ .name = "7", .bytes = std.mem.asBytes(&outside), .why = .outside_park },
        .{ .name = "7", .bytes = std.mem.asBytes(&unknown), .why = .unknown_breed },
    };
    for (cases) |case| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        try f.file(case.name, case.bytes);
        const refused = (try f.open()).refused;
        try testing.expectEqualStrings(case.name, refused.name);
        try testing.expectEqual(case.why, refused.why);
    }
}

test "a counter lost behind the dogs stops the start: a new device would take a dog" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var w = (try f.open()).world;
    const h = try w.newHuman(f.io(), a);
    try w.keep(f.io(), a, .{ .owner = h, .at = the_park.wrap(.at(1, 1)), .breed = .dog });
    w.close(testing.allocator);
    try webbox.store.remove(f.io(), a, try std.fs.path.join(a, &.{ f.data_dir, "next-human" }));
    const refused = (try f.open()).refused;
    try testing.expectEqualStrings("next-human", refused.name);
    try testing.expectEqual(RecordRefusal.next_human_not_past_every_dog, refused.why);
}

test "a replace's leftover temporary is passed over, and counted, in either case; a folder so named is not one" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const good = stored.StoredDog.of(.{ .owner = .of(7), .at = the_park.wrap(.at(1, 1)), .breed = .dog });
    try f.file("7", std.mem.asBytes(&good));
    try f.file("~0badf00d.tmp", "half a reco");
    try f.file("~0BADBEEF.TMP", "and in FAT's case");
    try webbox.store.write(f.io(), a, try std.fs.path.join(a, &.{ f.data_dir, "next-human" }), "8\n", .{});
    var w = (try f.open()).world;
    try testing.expectEqual(@as(u32, 2), w.left_over);
    try testing.expectEqual(@as(u32, 1), w.grid.used);
    w.close(testing.allocator);
    try webbox.store.makeDir(f.io(), a, try std.fs.path.join(a, &.{ f.data_dir, "dogs", "~deadbeef.tmp" }));
    try testing.expectEqual(RecordRefusal.not_a_file, (try f.open()).refused.why);
}

test "a full world refuses a new owner's dog before writing it, and still moves the ones it has" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var w = (try World.open(f.io(), testing.allocator, a, f.data_dir, the_park, 1)).world;
    defer w.close(testing.allocator);
    const at = the_park.wrap(.at(50, 50));
    try w.keep(f.io(), a, .{ .owner = .of(1), .at = at, .breed = .dog });
    try testing.expectEqual(contract.Space.full, w.room());
    try testing.expectError(error.PopulationFull, w.keep(f.io(), a, .{ .owner = .of(2), .at = at, .breed = .dog }));
    try testing.expect(!try webbox.store.has(f.io(), a, try std.fs.path.join(a, &.{ f.data_dir, "dogs", "2" })));
    try w.keep(f.io(), a, .{ .owner = .of(1), .at = the_park.wrap(.at(60, 60)), .breed = .dog });
}

test "a file's name is a human's id, canonical, and back" {
    var buffer: [20]u8 = undefined;
    try testing.expectEqualStrings("18446744073709551615", nameOf(.of(std.math.maxInt(u64)), &buffer));
    try testing.expectEqual(NameAsId{ .id = .of(42) }, idOfName("42"));
    try testing.expectEqual(NameAsId{ .id = .of(0) }, idOfName("0"));
    for ([_][]const u8{ "", "042", "4x", "-1", "+1", "18446744073709551616" }) |bad| {
        try testing.expectEqual(NameAsId.not_an_id, idOfName(bad));
    }
}

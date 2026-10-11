//! The world: the park, its dogs, who holds which, and the store under them
//! (webbox's `store`). The only module here that touches a disk.
//!
//!   <data>/dogs/<dog id>   a dog, its `stored.StoredDog` bytes: where it
//!                          stands, its breed and its claim, written whole
//!                          by `store.replace`
//!
//! **THE DOGS ARE MADE ONCE** (docs/FIXED-DOGS.md): when `dogs/` holds no
//! dog, the park's dogs are made (claiming.makeDogs) and written; otherwise
//! every one of them must be there, and readable, or the start stops,
//! named.
//!
//! **NO ID COUNTER** (docs/CLAIMS-V1.md): a human is 128 random bits
//! (humans.zig), so nothing is handed out in order and nothing is kept for
//! it; a restored `data/` or `auth/` cannot hand a live id out again.
//!
//! **ONE HANDLER AT A TIME**: webbox's hosts run one route at a time, so the
//! world needs no lock of its own.

const std = @import("std");
const Io = std.Io;
const webbox = @import("webbox");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const contract = @import("population.zig");
const index = @import("index.zig");
const stored = @import("stored.zig");
const claiming = @import("claiming.zig");
const answering = @import("answering.zig");
const HumanId = @import("humans.zig").HumanId;
const DogId = dogs.DogId;

/// The park every world is, for now (the build brief: 5,000 by 5,000).
pub const the_park: park.Park = (park.Park.of(.{ .width = 5000, .height = 5000 })).park;

pub const World = struct {
    park: park.Park,
    grid: index.GridPopulation,
    /// Every dog, `all[i]` dog `i`: the truth the grid indexes.
    all: []dogs.Dog,
    /// Who holds which dog, held or provisionally (whose claim may have
    /// ended: `answering.answer` asks the claim at its time). Derived from
    /// the held claims as they load, never stored. **AT MOST ONE ENTRY A
    /// DOG**: an entry names a dog whose claim names its human, and a dog
    /// given anew drops the entry of the human its ended claim named, so
    /// the capacity reserved at open (a dog each) is never passed.
    holders: std.AutoHashMapUnmanaged(HumanId, DogId),
    data_dir: []const u8,
    /// Temporaries a stopped `store.replace` left in `dogs/`, passed over.
    left_over: u32,
    /// Whether this open made the park's dogs.
    made: enum { found, made_now },

    /// The world in `data_dir`, its dogs made if there are none, or loaded
    /// and checked; or what stops it, named. `base` holds what lives as long
    /// as the world; `scratch` what opening needs.
    pub fn open(io: Io, base: std.mem.Allocator, scratch: std.mem.Allocator, data_dir: []const u8, p: park.Park, count: u32, seed: u64) !Opened {
        const folder = try std.fs.path.join(scratch, &.{ data_dir, "dogs" });
        const all = try base.alloc(dogs.Dog, count);
        var kept_by: enum { this_call, the_world } = .this_call;
        defer if (kept_by == .this_call) base.free(all);
        var have: std.DynamicBitSetUnmanaged = try .initEmpty(scratch, count);
        var left_over: u32 = 0;
        // A format 2 record read here (its claim let go): a park of them is
        // never taken for a fresh one whose making was cut short.
        var any_format_2 = false;
        var holders: std.AutoHashMapUnmanaged(HumanId, DogId) = .empty;
        defer if (kept_by == .this_call) holders.deinit(base);
        try holders.ensureTotalCapacity(base, count);
        for (try webbox.store.list(io, scratch, folder)) |entry| {
            // A stop inside `store.replace` leaves its temporary sibling (a
            // file, `~` and eight hex digits, `.tmp`, in either case on FAT);
            // the next replace of that dog writes over it.
            if (entry.kind == .file and isReplaceTemporary(entry.name)) {
                left_over += 1;
                continue;
            }
            const refused = struct {
                fn of(name: []const u8, why: RecordRefusal) Opened {
                    return .{ .refused = .{ .dog_record = .{ .name = name, .why = why } } };
                }
            }.of;
            if (entry.kind != .file) return refused(entry.name, .not_a_file);
            const id = switch (dogIdOfName(entry.name, count)) {
                .id => |id| id,
                .not_a_dog => return refused(entry.name, .name_not_a_dog_id),
            };
            const bytes = webbox.store.read(io, scratch, try std.fs.path.join(scratch, &.{ folder, entry.name }), .limited(@sizeOf(stored.StoredDog) + 1)) catch |e| switch (e) {
                error.StreamTooLong => return refused(entry.name, .wrong_size),
                else => return e,
            };
            const record = stored.readRecord(bytes, p) orelse return refused(entry.name, .wrong_size);
            if (bytes[0] == @intFromEnum(stored.Format.v2)) any_format_2 = true;
            const dog = switch (record) {
                .dog => |d| d,
                .claim_by_no_human => return refused(entry.name, .claim_by_no_human),
                .unclaimed_names_a_human => return refused(entry.name, .unclaimed_names_a_human),
                .unknown_format => return refused(entry.name, .unknown_format),
                .unknown_breed => return refused(entry.name, .unknown_breed),
                .unknown_claim => return refused(entry.name, .unknown_claim),
                .outside_park => return refused(entry.name, .outside_park),
            };
            if (dog.id != id) return refused(entry.name, .id_not_its_name);
            switch (dog.claim) {
                .unclaimed => {},
                .held => |h| if (holders.fetchPutAssumeCapacity(h.by, id) != null) return refused(entry.name, .human_holds_two),
                .provisional => unreachable, // never stored (stored.StoredDog.of)
            }
            all[id.number()] = dog;
            have.set(id.number());
        }
        const found = have.count();
        const made: @FieldType(World, "made") = if (found == 0) blk: {
            // **A FRESH PARK**: no dog yet, so they are made, and written.
            const fresh = switch (try claiming.makeDogs(scratch, p, count, seed)) {
                .made => |m| m,
                .no_dogs, .more_dogs_than_spots => return .{ .refused = .{ .dog_count = .{ .count = count, .spots = @as(u32, p.extent().columns) * p.extent().rows } } },
            };
            @memcpy(all, fresh);
            for (all) |d| try writeDog(io, scratch, data_dir, d);
            break :blk .made_now;
        } else if (found != count and !any_format_2) blk: {
            // **A MAKING CUT SHORT IS FINISHED**: if every dog there is
            // unclaimed and the very dog the seed makes, a fresh park was
            // being written when the machine stopped, and the rest are
            // written now. Anything else is a partial state, not a guess.
            const fresh = switch (try claiming.makeDogs(scratch, p, count, seed)) {
                .made => |m| m,
                .no_dogs, .more_dogs_than_spots => return .{ .refused = .{ .dog_count = .{ .count = count, .spots = @as(u32, p.extent().columns) * p.extent().rows } } },
            };
            var it = have.iterator(.{});
            while (it.next()) |i| if (!std.meta.eql(all[i], fresh[i])) return .{ .refused = .{ .dogs_folder = .{ .found = @intCast(found), .count = count } } };
            var missing = have.iterator(.{ .kind = .unset });
            while (missing.next()) |i| {
                all[i] = fresh[i];
                try writeDog(io, scratch, data_dir, fresh[i]);
            }
            break :blk .made_now;
        } else if (found != count) return .{ .refused = .{ .dogs_folder = .{ .found = @intCast(found), .count = count } } } else .found;
        var grid = try index.GridPopulation.init(base, p, count);
        errdefer grid.deinit(base);
        for (all) |d| switch (grid.population().put(d)) {
            .added => {},
            .replaced, .refused_full => unreachable, // `count` dogs of distinct ids
        };
        kept_by = .the_world;
        return .{ .world = .{
            .park = p,
            .grid = grid,
            .all = all,
            .holders = holders,
            .data_dir = data_dir,
            .left_over = left_over,
            .made = made,
        } };
    }

    pub fn close(self: *World, base: std.mem.Allocator) void {
        self.grid.deinit(base);
        self.holders.deinit(base);
        base.free(self.all);
    }

    pub fn population(self: *World) contract.Population {
        return self.grid.population();
    }

    /// What `human` holds now.
    pub fn holding(self: *const World, human: HumanId) answering.Holding {
        return if (self.holders.get(human)) |id| .{ .holds = id } else .holds_none;
    }

    /// A new human: 128 random bits (humans.zig), drawn again in the case,
    /// one in 2^128 a draw, that they name a human holding a dog.
    pub fn newHuman(self: *const World, io: Io) !HumanId {
        while (true) {
            const h = try HumanId.fresh(io);
            if (!self.holders.contains(h)) return h;
        }
    }

    /// **KEEPS WHAT A REQUEST CHANGED**: a move (a held dog's, or the drag
    /// that makes a provisional claim held) written and then held, so the
    /// world never holds what the disk does not; a dog given provisionally
    /// held in memory only (docs/CLAIMS-V1.md), so a restart forgets it.
    pub fn keep(self: *World, io: Io, scratch: std.mem.Allocator, change: answering.Change) !void {
        switch (change) {
            .nothing => {},
            .moved => |d| {
                try writeDog(io, scratch, self.data_dir, d);
                self.hold(d);
                self.holders.putAssumeCapacity(d.claim.held.by, d.id);
            },
            .given => |g| {
                switch (g.from) {
                    .nobody => {},
                    // Their claim on it ended: they hold it no longer, if
                    // they had not been given another since.
                    .human => |h| if (self.holders.get(h) == g.dog.id) {
                        _ = self.holders.remove(h);
                    },
                }
                self.hold(g.dog);
                self.holders.putAssumeCapacity(g.dog.claim.provisional.by, g.dog.id);
            },
        }
    }

    fn hold(self: *World, d: dogs.Dog) void {
        self.all[d.id.number()] = d;
        switch (self.grid.population().put(d)) {
            .replaced => {},
            .added, .refused_full => unreachable, // every dog is in the grid from the start
        }
    }
};

fn writeDog(io: Io, scratch: std.mem.Allocator, data_dir: []const u8, d: dogs.Dog) !void {
    var name: [10]u8 = undefined;
    const path = try std.fs.path.join(scratch, &.{ data_dir, "dogs", std.fmt.bufPrint(&name, "{d}", .{d.id.number()}) catch unreachable });
    try webbox.store.replace(io, scratch, path, std.mem.asBytes(&stored.StoredDog.of(d)), .{});
}

pub const Opened = union(enum) {
    world: World,
    refused: Refused,
};

/// What stops the world from opening, by what it names (metal-vmm QUEUE
/// 163.3): one dog's record, by its name in `dogs/`; the folder, holding
/// some of the park's dogs and not all; or a dog count the park cannot hold.
pub const Refused = union(enum) {
    dog_record: struct { name: []const u8, why: RecordRefusal },
    dogs_folder: struct { found: u32, count: u32 },
    dog_count: struct { count: u32, spots: u32 },
};

pub const RecordRefusal = enum {
    not_a_file,
    name_not_a_dog_id,
    wrong_size,
    unknown_format,
    unknown_breed,
    unknown_claim,
    outside_park,
    id_not_its_name,
    claim_by_no_human,
    unclaimed_names_a_human,
    human_holds_two,
};

/// A temporary `store.replace` leaves when a stop interrupts it: `~`, eight
/// hex digits, `.tmp`, in either case on FAT.
pub fn isReplaceTemporary(name: []const u8) bool {
    if (name.len != 13 or name[0] != '~' or !std.ascii.endsWithIgnoreCase(name, ".tmp")) return false;
    for (name[1..9]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub const NameAsDog = union(enum) {
    id: DogId,
    not_a_dog,
};

/// The dog a file's name names: digits only, canonical (no leading zero),
/// below the park's `count`.
pub fn dogIdOfName(name: []const u8, count: u32) NameAsDog {
    return switch (canonicalNumber(name)) {
        .number => |n| if (n < count) .{ .id = .of(@intCast(n)) } else .not_a_dog,
        .not_a_number => .not_a_dog,
    };
}

pub const Canonical = union(enum) {
    number: u64,
    not_a_number,
};

/// A name as a number: digits only, canonical (no leading zero), so one
/// number has one name.
pub fn canonicalNumber(name: []const u8) Canonical {
    if (name.len == 0 or (name.len > 1 and name[0] == '0')) return .not_a_number;
    for (name) |c| if (!std.ascii.isDigit(c)) return .not_a_number;
    return .{ .number = std.fmt.parseInt(u64, name, 10) catch return .not_a_number };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const few: u32 = 6;
const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 1000 })).park;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    tmp: testing.TmpDir,
    data_dir: []const u8,

    fn init(self: *Fixture) !void {
        self.arena = .init(testing.allocator);
        self.threaded = .init(self.arena.allocator(), .{});
        self.tmp = testing.tmpDir(.{});
        const root = try std.fs.path.join(self.arena.allocator(), &.{ ".zig-cache", "tmp", &self.tmp.sub_path });
        self.data_dir = try std.fs.path.join(self.arena.allocator(), &.{ root, "data" });
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
        return World.open(self.io(), testing.allocator, self.arena.allocator(), self.data_dir, small, few, claiming.dogs_seed);
    }

    fn dogFile(self: *Fixture, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.data_dir, "dogs", name });
    }

    fn file(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        try webbox.store.write(self.io(), self.arena.allocator(), try self.dogFile(name), bytes, .{});
    }

    fn readDog(self: *Fixture, id: u32) !dogs.Dog {
        var name: [10]u8 = undefined;
        const bytes = try webbox.store.read(self.io(), self.arena.allocator(), try self.dogFile(std.fmt.bufPrint(&name, "{d}", .{id}) catch unreachable), .limited(64));
        return std.mem.bytesToValue(stored.StoredDog, bytes).read(small).dog;
    }
};

const noon: dogs.Instant = .of(1_790_000_000);

fn heldBy(d: dogs.Dog, h: HumanId) dogs.Dog {
    var c = d;
    c.claim = .{ .held = .{ .by = h } };
    return c;
}

fn givenTo(d: dogs.Dog, h: HumanId) dogs.Dog {
    var c = d;
    c.claim = .{ .provisional = .madeAt(h, noon) };
    return c;
}

test "a fresh park makes its dogs and writes them; the next open finds the same dogs" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var w = (try f.open()).world;
    try testing.expectEqual(.made_now, w.made);
    const made = try f.arena.allocator().dupe(dogs.Dog, w.all);
    w.close(testing.allocator);
    var again = (try f.open()).world;
    defer again.close(testing.allocator);
    try testing.expectEqual(.found, again.made);
    try testing.expectEqualSlices(dogs.Dog, made, again.all);
}

test "a dog given is held in memory only; its first drag writes it held, and that comes back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var w = (try f.open()).world;
    const alice = try w.newHuman(f.io());
    const bob = try w.newHuman(f.io());
    try w.keep(f.io(), a, .{ .given = .{ .dog = givenTo(w.all[2], alice), .from = .nobody } });
    try w.keep(f.io(), a, .{ .given = .{ .dog = givenTo(w.all[3], bob), .from = .nobody } });
    try testing.expectEqual(answering.Holding{ .holds = .of(2) }, w.holding(alice));
    // Nothing of a provisional claim is on disk.
    try testing.expectEqual(dogs.Claim.unclaimed, (try f.readDog(2)).claim);
    var moved = heldBy(w.all[2], alice);
    moved.at = small.wrap(.at(-10, 990));
    try w.keep(f.io(), a, .{ .moved = moved });
    w.close(testing.allocator);

    // A restart: Alice's held dog comes back, where she left it; Bob's
    // provisional claim is forgotten.
    var again = (try f.open()).world;
    defer again.close(testing.allocator);
    try testing.expectEqual(answering.Holding{ .holds = .of(2) }, again.holding(alice));
    try testing.expectEqual(answering.Holding.holds_none, again.holding(bob));
    try testing.expectEqual(dogs.Claim.unclaimed, again.all[3].claim);
    try testing.expectEqual(frames.ParkPoint.at(990, 990), again.all[2].at.point);
}

test "a dog given anew drops the holder its ended claim named, unless they were given another" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var w = (try f.open()).world;
    defer w.close(testing.allocator);
    const alice = try w.newHuman(f.io());
    const bob = try w.newHuman(f.io());
    const carol = try w.newHuman(f.io());
    try w.keep(f.io(), a, .{ .given = .{ .dog = givenTo(w.all[0], alice), .from = .nobody } });
    // Alice's claim ended; Bob is given her dog: she holds nothing.
    try w.keep(f.io(), a, .{ .given = .{ .dog = givenTo(w.all[0], bob), .from = .{ .human = alice } } });
    try testing.expectEqual(answering.Holding.holds_none, w.holding(alice));
    // Alice is given dog 1; then Bob's claim on 0 ends and Carol is given it,
    // naming Bob, not Alice: Alice keeps dog 1.
    try w.keep(f.io(), a, .{ .given = .{ .dog = givenTo(w.all[1], alice), .from = .nobody } });
    try w.keep(f.io(), a, .{ .given = .{ .dog = givenTo(w.all[0], carol), .from = .{ .human = bob } } });
    try testing.expectEqual(answering.Holding{ .holds = .of(1) }, w.holding(alice));
    try testing.expectEqual(answering.Holding.holds_none, w.holding(bob));
    try testing.expect(w.holders.count() <= few);
}

test "what does not read stops the open, named by what it is" {
    const Case = struct { name: []const u8, bytes: []const u8, why: RecordRefusal };
    const good = stored.StoredDog.of(.{ .id = .of(1), .at = small.wrap(.at(50, 50)), .breed = .dog, .claim = .unclaimed });
    var outside = good;
    outside.park_x = 1000;
    var unknown = good;
    unknown.breed_byte = 200;
    var nobody = good;
    nobody.claim_tag = .held; // by human 0
    var stray = good;
    stray.held_by = 5; // unclaimed, yet naming someone
    const cases = [_]Case{
        .{ .name = "01", .bytes = std.mem.asBytes(&good), .why = .name_not_a_dog_id },
        .{ .name = "6", .bytes = std.mem.asBytes(&good), .why = .name_not_a_dog_id },
        .{ .name = "1", .bytes = std.mem.asBytes(&good)[0..31], .why = .wrong_size },
        .{ .name = "1", .bytes = std.mem.asBytes(&good) ++ "x", .why = .wrong_size },
        .{ .name = "2", .bytes = std.mem.asBytes(&good), .why = .id_not_its_name },
        .{ .name = "1", .bytes = std.mem.asBytes(&outside), .why = .outside_park },
        .{ .name = "1", .bytes = std.mem.asBytes(&unknown), .why = .unknown_breed },
        .{ .name = "1", .bytes = std.mem.asBytes(&nobody), .why = .claim_by_no_human },
        .{ .name = "1", .bytes = std.mem.asBytes(&stray), .why = .unclaimed_names_a_human },
    };
    for (cases) |case| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        try f.file(case.name, case.bytes);
        const refused = (try f.open()).refused.dog_record;
        try testing.expectEqualStrings(case.name, refused.name);
        try testing.expectEqual(case.why, refused.why);
    }
}

test "two dogs held by one human, or some dogs and not all, stop the open" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var w = (try f.open()).world;
    const alice = try w.newHuman(f.io());
    // Written behind the world's back: two dogs, one holder.
    const one = stored.StoredDog.of(heldBy(w.all[0], alice));
    const two = stored.StoredDog.of(heldBy(w.all[1], alice));
    w.close(testing.allocator);
    try f.file("0", std.mem.asBytes(&one));
    try f.file("1", std.mem.asBytes(&two));
    try testing.expectEqual(RecordRefusal.human_holds_two, (try f.open()).refused.dog_record.why);
    try webbox.store.remove(f.io(), a, try f.dogFile("1"));
    try testing.expectEqual(Refused{ .dogs_folder = .{ .found = few - 1, .count = few } }, (try f.open()).refused);
}

test "a park cannot be made with no dogs, or more than its spots" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try testing.expectEqual(Refused{ .dog_count = .{ .count = 0, .spots = 100 } }, (try World.open(f.io(), testing.allocator, a, f.data_dir, small, 0, 1)).refused);
    try testing.expectEqual(Refused{ .dog_count = .{ .count = 101, .spots = 100 } }, (try World.open(f.io(), testing.allocator, a, f.data_dir, small, 101, 1)).refused);
}

test "a file's name is a dog's id, canonical, below the count" {
    try testing.expectEqual(NameAsDog{ .id = .of(5) }, dogIdOfName("5", few));
    try testing.expectEqual(NameAsDog{ .id = .of(0) }, dogIdOfName("0", few));
    for ([_][]const u8{ "", "05", "6", "4x", "-1", "18446744073709551616" }) |bad| {
        try testing.expectEqual(NameAsDog.not_a_dog, dogIdOfName(bad, few));
    }
}

test "a fresh park whose making was cut short is finished on the next open; a changed dog, or a format 2 park, is not guessed" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var w = (try f.open()).world;
    const made = try a.dupe(dogs.Dog, w.all);
    w.close(testing.allocator);
    // Half the dogs, as a stop half-way through writing them would leave.
    for (few / 2..few) |i| {
        var name: [10]u8 = undefined;
        try webbox.store.remove(f.io(), a, try f.dogFile(std.fmt.bufPrint(&name, "{d}", .{i}) catch unreachable));
    }
    var finished = (try f.open()).world;
    try testing.expectEqual(.made_now, finished.made);
    try testing.expectEqualSlices(dogs.Dog, made, finished.all);
    // A dog changed, then half gone: not a making cut short, so not guessed.
    const bob = try finished.newHuman(f.io());
    try finished.keep(f.io(), a, .{ .moved = heldBy(finished.all[0], bob) });
    finished.close(testing.allocator);
    try webbox.store.remove(f.io(), a, try f.dogFile("5"));
    try testing.expectEqual(Refused{ .dogs_folder = .{ .found = few - 1, .count = few } }, (try f.open()).refused);
}

test "a format 2 park is read with its claims let go, and with dogs missing is refused, never refilled" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var w = (try f.open()).world;
    const made = try a.dupe(dogs.Dog, w.all);
    w.close(testing.allocator);
    // Every dog rewritten as format 2, the first claimed by counter human 1.
    for (made, 0..) |d, i| {
        const v2: stored.StoredDogV2 = .{ .format = .v2, .breed_byte = @intFromEnum(d.breed), .claim_tag = if (i == 0) 1 else 0, .reserved = 0, .dog = d.id.number(), .park_x = d.at.point.x.number(), .park_y = d.at.point.y.number(), .claimed_by = if (i == 0) 1 else 0, .touched = if (i == 0) noon.seconds() else 0 };
        var name: [10]u8 = undefined;
        try webbox.store.replace(f.io(), a, try f.dogFile(std.fmt.bufPrint(&name, "{d}", .{i}) catch unreachable), std.mem.asBytes(&v2), .{});
    }
    var old = (try f.open()).world;
    try testing.expectEqualSlices(dogs.Dog, made, old.all);
    try testing.expectEqual(@as(u32, 0), old.holders.count());
    old.close(testing.allocator);
    try webbox.store.remove(f.io(), a, try f.dogFile("5"));
    try testing.expectEqual(Refused{ .dogs_folder = .{ .found = few - 1, .count = few } }, (try f.open()).refused);
}

test "a replace's temporary is ~, eight hex digits and .tmp, in either case, and nothing else" {
    try testing.expect(isReplaceTemporary("~0badf00d.tmp"));
    try testing.expect(isReplaceTemporary("~0BADF00D.TMP"));
    for ([_][]const u8{ "~0badf00x.tmp", "~0badf00d.tmq", "0badf00d.tmp", "~badf00d.tmp", "~0badf00d0.tmp" }) |name| {
        try testing.expect(!isReplaceTemporary(name));
    }
}

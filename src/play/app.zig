//! Dog Park, played: the server for `solo/`, as webbox serves it
//! (`webbox.site.Site(App)`). It knows the dogs and the cows and where they
//! stand (a dog's move scares the cows ahead of it aside: cows.zig), who
//! each human is (a signed cookie naming a random id), where each human's
//! viewport was, and who holds which dog on a leash.
//!
//!   GET  /           solo/index.html, read from disk each time
//!   GET  /park.js    solo/park.js, read from disk each time
//!   GET  /cows.wasm  the cows' rule (cows.zig), compiled in
//!   GET  /me         your viewport and your leash (a first visit gets its
//!                    cookie here)
//!   POST /tiles      {"tiles": [{"col", "row", "is": "new" | "held"}]}: the
//!                    whole set, replacing yours → the dogs and the cows in
//!                    the tiles named new; refused past 25 tiles
//!   POST /leash      {"dog"}                       → leashed, or held by another
//!   POST /release    {"dog"}                       → released, or not held
//!   POST /move       {"dog", "path": [[park_x, park_y], ...]}: the dog's
//!                    path since the server last had it, at most 100 points
//!                    → moved, kept, and the cows it scared, where they
//!                    stepped to, the cows' rule replayed along the path
//!   POST /viewport   {"park_x", "park_y"}          → kept
//!
//! Every answer is JSON. **THE PAGE IS READ FROM DISK** (`solo/`, from where
//! the server runs: the checkout on Linux, the site disk on metal, where
//! assets.zon's `.site` lays it), so an edit to it shows on a reload, with
//! no rebuild.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const signed_cookie = webbox.signed_cookie;
const dogs = @import("dogs.zig");
const humans = @import("humans.zig");
const tiles = @import("tiles.zig");
const cows = @import("cows.zig");
const HumanId = humans.HumanId;

/// Where the page lives, from the directory the server runs in.
const page_dir = "solo";

/// The longest request body: fifty tiles at about 25 bytes each.
pub const longest_body = 4096;

/// The most any route reads of a body (webbox's body rule): every route's is
/// the same, small.
pub fn bodyLimit(_: []const u8) u64 {
    return longest_body;
}

/// **A HUMAN IS A DEVICE**: a signed cookie naming its random id, for a year.
pub const human_cookie: signed_cookie.Cookie = .{ .name = "dogpark_human", .kind = .{
    .label = "dogpark_human\n",
    .lifetime_secs = 365 * 24 * 60 * 60,
    .skew_secs = 5 * 60,
    .validId = humans.validId,
} };

/// What this process holds: one handler runs at a time (webbox's hosts), so
/// it is shared plainly.
var the_dogs: dogs.Dogs = undefined;
var the_cows: cows.Cows = undefined;
var the_humans: humans.Humans = .{};
/// Lives as long as the process: the humans' table.
var long_lived: std.mem.Allocator = undefined;
var dogs_path: []const u8 = undefined;
var cows_path: []const u8 = undefined;
var data_dir: []const u8 = undefined;
var auth_dir: []const u8 = undefined;

pub const Kept = enum { loaded, laid_out };

pub const StartReport = struct {
    dogs_path: []const u8,
    dogs: Kept,
    cows_path: []const u8,
    cows: Kept,
    secret: enum { found, created },
};

/// The development folders, for a run with no config (a checkout).
const default_roots: webbox.site.Roots = .{ .data_dir = "data", .auth_dir = "auth" };

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    const r = roots orelse default_roots;
    long_lived = base;
    data_dir = r.data_dir;
    auth_dir = r.auth_dir;
    dogs_path = try std.fs.path.join(base, &.{ r.data_dir, "dogs.json" });
    var scratch: std.heap.ArenaAllocator = .init(base);
    defer scratch.deinit();
    const secret: @FieldType(StartReport, "secret") = if (try webbox.site_secret.load(io, scratch.allocator(), r.auth_dir)) |_| .found else blk: {
        try webbox.site_secret.create(io, scratch.allocator(), r.auth_dir);
        break :blk .created;
    };
    cows_path = try std.fs.path.join(base, &.{ r.data_dir, "cows.json" });
    // **A DOGS OR COWS FILE THAT DOES NOT READ STOPS THE START, NAMED**
    // (fail, never warn): the host prints a failed start's error, and this
    // one says what. No print here: the application has no stderr of its
    // own on every host (a kernel has none).
    const dogs_kept: Kept = if (try webbox.store.readOrNull(io, scratch.allocator(), dogs_path, .limited(1024 * 1024))) |bytes| blk: {
        the_dogs = dogs.Dogs.read(bytes) catch return error.DogsFileDoesNotRead;
        break :blk .loaded;
    } else blk: {
        the_dogs = dogs.Dogs.laidOut();
        try keepDogs(io, scratch.allocator());
        break :blk .laid_out;
    };
    const cows_kept: Kept = if (try webbox.store.readOrNull(io, scratch.allocator(), cows_path, .limited(1024 * 1024))) |bytes| blk: {
        the_cows = cows.Cows.read(bytes) catch return error.CowsFileDoesNotRead;
        break :blk .loaded;
    } else blk: {
        the_cows = cows.Cows.laidOut();
        try keepCows(io, scratch.allocator());
        break :blk .laid_out;
    };
    return .{ .dogs_path = dogs_path, .dogs = dogs_kept, .cows_path = cows_path, .cows = cows_kept, .secret = secret };
}

fn keepDogs(io: Io, alloc: std.mem.Allocator) !void {
    try webbox.store.replace(io, alloc, dogs_path, try the_dogs.written(alloc), .{});
}

fn keepCows(io: Io, alloc: std.mem.Allocator) !void {
    try webbox.store.replace(io, alloc, cows_path, try the_cows.written(alloc), .{});
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const path = http.pathOf(try http.target(req, alloc));
    if (std.mem.eql(u8, path, "/")) return pageFile(req, io, alloc, "index.html", "text/html; charset=utf-8");
    if (std.mem.eql(u8, path, "/park.js")) return pageFile(req, io, alloc, "park.js", "text/javascript; charset=utf-8");
    if (std.mem.eql(u8, path, "/cows.wasm")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
        return req.respond(@embedFile("cows.wasm"), .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/wasm" },
            .{ .name = "cache-control", .value = "no-store" },
        } });
    }
    if (std.mem.eql(u8, path, "/me")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
        return me(req, io, alloc);
    }
    if (std.mem.eql(u8, path, "/leash")) return asHuman(req, io, alloc, leash);
    if (std.mem.eql(u8, path, "/release")) return asHuman(req, io, alloc, release);
    if (std.mem.eql(u8, path, "/move")) return asHuman(req, io, alloc, move);
    if (std.mem.eql(u8, path, "/viewport")) return asHuman(req, io, alloc, viewport);
    if (std.mem.eql(u8, path, "/tiles")) return asHuman(req, io, alloc, subscribe);
    return http.notFound(req);
}

// ── who is asking ───────────────────────────────────────────────────────────

fn nowSecs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

const Known = union(enum) { human: HumanId, stranger };

/// The human this request's cookie names, or a stranger (none, or one that
/// doesn't verify).
fn whoIs(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !Known {
    return switch (try signed_cookie.read(human_cookie, io, alloc, req, auth_dir, nowSecs(io))) {
        .none, .invalid => .stranger,
        .no_secret => error.NoSecret,
        .verified => |v| switch (HumanId.parse(v.id)) {
            .id => |h| .{ .human = h },
            .not_an_id => unreachable, // the cookie's kind takes ids only
        },
    };
}

/// `GET /me`: your viewport and your leash; a stranger becomes a human here,
/// with a new random id and its cookie.
fn me(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !void {
    const who: struct { human: HumanId, set_cookie: SetCookie } = switch (try whoIs(req, io, alloc)) {
        .human => |h| .{ .human = h, .set_cookie = .none },
        .stranger => blk: {
            const h = HumanId.random(io);
            const issued = (try signed_cookie.issue(human_cookie, io, alloc, auth_dir, &h.hex(), nowSecs(io))) orelse return error.NoSecret;
            break :blk .{ .human = h, .set_cookie = .{ .header = issued } };
        },
    };
    const human = try humanOf(io, alloc, who.human);
    const Answer = struct { viewport: humans.Viewport, leash: union(enum) { none, dog: u16 } };
    const answer: Answer = .{ .viewport = human.viewport, .leash = switch (human.leash) {
        .none => .none,
        .dog => |d| .{ .dog = @intFromEnum(d) },
    } };
    return json(req, try std.json.Stringify.valueAlloc(alloc, answer, .{}), who.set_cookie);
}

/// The human, made on first sight, with its viewport read from disk.
fn humanOf(io: Io, alloc: std.mem.Allocator, who: HumanId) !*humans.Human {
    const known = the_humans.map.contains(who);
    const human = try the_humans.of(long_lived, who);
    if (!known) {
        if (try webbox.store.readOrNull(io, alloc, try viewportPath(alloc, who), .limited(256))) |bytes| {
            // A viewport file that does not read is the route's error (the
            // host answers 500 and logs its name), never printed here.
            const at = std.json.parseFromSliceLeaky(dogs.ParkPoint, alloc, bytes, .{}) catch return error.ViewportFileDoesNotRead;
            human.viewport = .{ .at = at };
        }
    }
    return human;
}

fn viewportPath(alloc: std.mem.Allocator, who: HumanId) ![]const u8 {
    const name = who.hex();
    return std.fs.path.join(alloc, &.{ data_dir, "humans", &name });
}

/// A request only a human may make: a stranger is told to ask `/me` first.
fn asHuman(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, comptime handle: fn (*std.http.Server.Request, Io, std.mem.Allocator, HumanId) anyerror!void) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    switch (try whoIs(req, io, alloc)) {
        .human => |h| {
            _ = try humanOf(io, alloc, h);
            return handle(req, io, alloc, h);
        },
        .stranger => return req.respond("Who are you? GET /me first.\n", .{ .status = .unauthorized, .keep_alive = false }),
    }
}

// ── what a human asks ───────────────────────────────────────────────────────

fn leash(req: *std.http.Server.Request, _: Io, alloc: std.mem.Allocator, who: HumanId) !void {
    const asked = (try readJson(dogs.LeashRequest, req, alloc)) orelse return;
    const dog = (try dogNamed(req, asked.dog)) orelse return;
    const out = switch (try the_humans.leash(long_lived, who, dog)) {
        .leashed => |l| switch (l.let_go) {
            .none => try std.fmt.allocPrint(alloc, "{{\"leashed\":{d}}}", .{@intFromEnum(l.dog)}),
            .dog => |old| try std.fmt.allocPrint(alloc, "{{\"leashed\":{d},\"let_go\":{d}}}", .{ @intFromEnum(l.dog), @intFromEnum(old) }),
        },
        .held_by_another => |d| try std.fmt.allocPrint(alloc, "{{\"held_by_another\":{d}}}", .{@intFromEnum(d)}),
    };
    return json(req, out, .none);
}

fn release(req: *std.http.Server.Request, _: Io, alloc: std.mem.Allocator, who: HumanId) !void {
    const asked = (try readJson(dogs.LeashRequest, req, alloc)) orelse return;
    const dog = (try dogNamed(req, asked.dog)) orelse return;
    return json(req, try std.fmt.allocPrint(alloc, "{{\"{t}\":{d}}}", .{ try the_humans.release(long_lived, who, dog), @intFromEnum(dog) }), .none);
}

fn move(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: HumanId) !void {
    const asked = (try readJson(dogs.MoveRequest, req, alloc)) orelse return;
    const dog = (try dogNamed(req, asked.dog)) orelse return;
    if (asked.path.len == 0) return badRequest(req, "A move needs a path.\n");
    if (asked.path.len > dogs.most_path_points) return badRequest(req, try std.fmt.allocPrint(alloc, "A path of {d} points is past the {d} a move may carry.\n", .{ asked.path.len, dogs.most_path_points }));
    for (asked.path) |p| {
        if (tiles.where(.{ .park_x = p[0], .park_y = p[1] }) == .outside_world) return badRequest(req, "That is outside the world.\n");
    }
    // **THE PAGE'S OWN STEPS**: the rule replayed segment by segment along
    // the path, as the page predicted it.
    var stepped = [_]bool{false} ** cows.cow_count;
    for (asked.path) |p| {
        const from = the_dogs.at(dog);
        const to: dogs.ParkPoint = .{ .park_x = p[0], .park_y = p[1] };
        the_dogs.moveTo(dog, to);
        const scared = the_cows.react(from, to);
        for (scared.slice()) |c| stepped[@intFromEnum(c)] = true;
    }
    try keepDogs(io, alloc);
    const CowAt = struct { id: u16, park_x: i32, park_y: i32 };
    var moved: std.ArrayList(CowAt) = .empty;
    for (stepped, 0..) |was, i| if (was) {
        const at = the_cows.at(@enumFromInt(i));
        try moved.append(alloc, .{ .id = @intCast(i), .park_x = at.park_x, .park_y = at.park_y });
    };
    if (moved.items.len > 0) try keepCows(io, alloc);
    const end = the_dogs.at(dog);
    const Answer = struct { moved: u16, park_x: i32, park_y: i32, cows: []const CowAt };
    return json(req, try std.json.Stringify.valueAlloc(alloc, Answer{ .moved = @intFromEnum(dog), .park_x = end.park_x, .park_y = end.park_y, .cows = moved.items }, .{}), .none);
}

fn viewport(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, who: HumanId) !void {
    const at = (try readJson(dogs.ParkPoint, req, alloc)) orelse return;
    const human = try humanOf(io, alloc, who);
    human.viewport = .{ .at = at };
    try webbox.store.replace(io, alloc, try viewportPath(alloc, who), try std.json.Stringify.valueAlloc(alloc, at, .{}), .{});
    return json(req, try std.fmt.allocPrint(alloc, "{{\"viewport\":{{\"park_x\":{d},\"park_y\":{d}}}}}", .{ at.park_x, at.park_y }), .none);
}

const TilesRequest = struct { tiles: []const tiles.Named };

/// `POST /tiles`: your subscriptions replaced by the tiles named, and the
/// dogs standing in those named new.
fn subscribe(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, who: HumanId) !void {
    const asked = (try readJson(TilesRequest, req, alloc)) orelse return;
    const human = try humanOf(io, alloc, who);
    switch (human.tiles.replace(asked.tiles)) {
        .outside_world => |t| return badRequest(req, try std.fmt.allocPrint(alloc, "Tile ({d}, {d}) is outside the world.\n", .{ t.col, t.row })),
        .too_many => |n| return req.respond(try std.fmt.allocPrint(alloc, "{{\"too_many\":{d},\"most\":{d}}}", .{ n, tiles.most_subscribed }), .{
            .status = .bad_request,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }),
        .replaced => {
            const Shown = struct { id: usize, emoji: []const u8, park_x: i32, park_y: i32 };
            var shown: std.ArrayList(Shown) = .empty;
            for (the_dogs.list, 0..) |dog, i| {
                const t = tiles.Tile.of(dog.at);
                for (asked.tiles) |n| if (n.is == .new and std.meta.eql(n.tile(), t)) {
                    try shown.append(alloc, .{ .id = i, .emoji = dog.emoji, .park_x = dog.at.park_x, .park_y = dog.at.park_y });
                    break;
                };
            }
            const CowShown = struct { id: usize, park_x: i32, park_y: i32 };
            var cows_shown: std.ArrayList(CowShown) = .empty;
            for (the_cows.list, 0..) |cow, i| {
                const t = tiles.Tile.of(cow.at);
                for (asked.tiles) |n| if (n.is == .new and std.meta.eql(n.tile(), t)) {
                    try cows_shown.append(alloc, .{ .id = i, .park_x = cow.at.park_x, .park_y = cow.at.park_y });
                    break;
                };
            }
            const Answer = struct { subscribed: usize, dogs: []const Shown, cows: []const CowShown };
            return json(req, try std.json.Stringify.valueAlloc(alloc, Answer{ .subscribed = human.tiles.len, .dogs = shown.items, .cows = cows_shown.items }, .{}), .none);
        },
    }
}

/// The dog a request names, or null with a 400 already answered.
fn dogNamed(req: *std.http.Server.Request, asked: u32) !?dogs.DogId {
    return switch (the_dogs.lookup(asked)) {
        .dog => |d| d,
        .no_such_dog => {
            try badRequest(req, "No such dog.\n");
            return null;
        },
    };
}

// ── answering ───────────────────────────────────────────────────────────────

const SetCookie = union(enum) { none, header: []const u8 };

/// A file of the page, read from disk on every request, never cached.
fn pageFile(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, name: []const u8, content_type: []const u8) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    const path = try std.fs.path.join(alloc, &.{ page_dir, name });
    const body = try webbox.store.read(io, alloc, path, .limited(1024 * 1024));
    return req.respond(body, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

/// The body as `T`, or null with a 400 already answered.
fn readJson(comptime T: type, req: *std.http.Server.Request, alloc: std.mem.Allocator) !?T {
    const body = (try http.readLimitedBody(req, alloc, longest_body)) orelse return null;
    return std.json.parseFromSliceLeaky(T, alloc, body, .{}) catch {
        try badRequest(req, "The request did not read.\n");
        return null;
    };
}

fn badRequest(req: *std.http.Server.Request, why: []const u8) !void {
    return req.respond(why, .{ .status = .bad_request, .keep_alive = false });
}

fn json(req: *std.http.Server.Request, body: []const u8, set_cookie: SetCookie) !void {
    const content_type: std.http.Header = .{ .name = "content-type", .value = "application/json" };
    return switch (set_cookie) {
        .none => req.respond(body, .{ .extra_headers = &.{content_type} }),
        .header => |h| req.respond(body, .{ .extra_headers = &.{ content_type, .{ .name = "set-cookie", .value = h } } }),
    };
}

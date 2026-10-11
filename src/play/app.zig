//! Dog Park, played: the server for `solo/`, as webbox serves it
//! (`webbox.site.Site(App)`). It knows the dogs and where they stand, who
//! each human is (a signed cookie naming a random id), where each human's
//! viewport was, and who holds which dog on a leash.
//!
//!   GET  /           solo/index.html, read from disk each time
//!   GET  /park.js    solo/park.js, read from disk each time
//!   GET  /dogs       every dog and its park point
//!   GET  /me         your viewport and your leash (a first visit gets its
//!                    cookie here)
//!   POST /leash      {"dog"}                       → leashed, or held by another
//!   POST /release    {"dog"}                       → released, or not held
//!   POST /move       {"dog", "park_x", "park_y"}   → moved, kept
//!   POST /viewport   {"park_x", "park_y"}          → kept
//!
//! Every answer is JSON. **THE PAGE IS READ FROM DISK** (the checkout's
//! `solo/`), so an edit to it shows on a reload, with no rebuild.

const std = @import("std");
const Io = std.Io;
const webbox = @import("webbox");
const http = webbox.http;
const signed_cookie = webbox.signed_cookie;
const dogs = @import("dogs.zig");
const humans = @import("humans.zig");
const HumanId = humans.HumanId;

/// Where the page lives, from the directory the server runs in.
const page_dir = "solo";

/// The longest request body: a move is under 100 bytes.
pub const longest_body = 512;

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
var the_humans: humans.Humans = .{};
/// Lives as long as the process: the humans' table.
var long_lived: std.mem.Allocator = undefined;
var dogs_path: []const u8 = undefined;
var data_dir: []const u8 = undefined;
var auth_dir: []const u8 = undefined;

pub const StartReport = struct {
    dogs_path: []const u8,
    dogs: enum { loaded, laid_out },
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
    const stored = try webbox.store.readOrNull(io, scratch.allocator(), dogs_path, .limited(64 * 1024));
    if (stored) |bytes| {
        the_dogs = dogs.Dogs.read(bytes) catch |e| {
            // **A DOGS FILE THAT DOES NOT READ STOPS THE START, NAMED** (fail,
            // never warn).
            std.debug.print("dog-park: {s} does not read ({t}); not starting\n", .{ dogs_path, e });
            return e;
        };
        return .{ .dogs_path = dogs_path, .dogs = .loaded, .secret = secret };
    }
    the_dogs = dogs.Dogs.laidOut();
    try keepDogs(io, scratch.allocator());
    return .{ .dogs_path = dogs_path, .dogs = .laid_out, .secret = secret };
}

fn keepDogs(io: Io, alloc: std.mem.Allocator) !void {
    try webbox.store.replace(io, alloc, dogs_path, try the_dogs.written(alloc), .{});
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const path = http.pathOf(try http.target(req, alloc));
    if (std.mem.eql(u8, path, "/")) return pageFile(req, io, alloc, "index.html", "text/html; charset=utf-8");
    if (std.mem.eql(u8, path, "/park.js")) return pageFile(req, io, alloc, "park.js", "text/javascript; charset=utf-8");
    if (std.mem.eql(u8, path, "/dogs")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req);
        return json(req, try the_dogs.written(alloc), .none);
    }
    if (std.mem.eql(u8, path, "/me")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req);
        return me(req, io, alloc);
    }
    if (std.mem.eql(u8, path, "/leash")) return asHuman(req, io, alloc, leash);
    if (std.mem.eql(u8, path, "/release")) return asHuman(req, io, alloc, release);
    if (std.mem.eql(u8, path, "/move")) return asHuman(req, io, alloc, move);
    if (std.mem.eql(u8, path, "/viewport")) return asHuman(req, io, alloc, viewport);
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
    const Answer = struct { viewport: humans.Viewport, leash: union(enum) { none, dog: u8 } };
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
            const at = std.json.parseFromSliceLeaky(dogs.ParkPoint, alloc, bytes, .{}) catch |e| {
                std.debug.print("dog-park: {s} does not read ({t})\n", .{ try viewportPath(alloc, who), e });
                return e;
            };
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
    if (req.head.method != .POST) return http.methodNotAllowed(req);
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
    the_dogs.moveTo(dog, .{ .park_x = asked.park_x, .park_y = asked.park_y });
    try keepDogs(io, alloc);
    const at = the_dogs.at(dog);
    return json(req, try std.fmt.allocPrint(alloc, "{{\"moved\":{d},\"park_x\":{d},\"park_y\":{d}}}", .{ @intFromEnum(dog), at.park_x, at.park_y }), .none);
}

fn viewport(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, who: HumanId) !void {
    const at = (try readJson(dogs.ParkPoint, req, alloc)) orelse return;
    const human = try humanOf(io, alloc, who);
    human.viewport = .{ .at = at };
    try webbox.store.replace(io, alloc, try viewportPath(alloc, who), try std.json.Stringify.valueAlloc(alloc, at, .{}), .{});
    return json(req, try std.fmt.allocPrint(alloc, "{{\"viewport\":{{\"park_x\":{d},\"park_y\":{d}}}}}", .{ at.park_x, at.park_y }), .none);
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
    if (req.head.method != .GET) return http.methodNotAllowed(req);
    const path = try std.fs.path.join(alloc, &.{ page_dir, name });
    const body = try Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1024 * 1024));
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

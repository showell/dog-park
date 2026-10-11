//! Dog Park, played: the server for `solo/`, as webbox serves it
//! (`webbox.site.Site(App)`). It knows the dogs and where they stand, acks a
//! leash, and keeps each move.
//!
//!   GET  /          solo/index.html, read from disk each time
//!   GET  /park.js   solo/park.js, read from disk each time
//!   GET  /dogs      every dog and its park point, JSON
//!   POST /leash     {"dog": id}                      → {"leashed": id}
//!   POST /move      {"dog": id, "park_x", "park_y"}  → the same, kept
//!
//! **THE PAGE IS READ FROM DISK** (the checkout's `solo/`), so an edit to the
//! page shows on a reload, with no rebuild: this is the server we play with.

const std = @import("std");
const Io = std.Io;
const webbox = @import("webbox");
const http = webbox.http;
const dogs = @import("dogs.zig");

/// Where the page lives, from the directory the server runs in.
const page_dir = "solo";

/// The longest request body: a move is under 100 bytes.
pub const longest_body = 512;

/// Every dog, as this process holds them: one handler runs at a time
/// (webbox's hosts), so they are shared plainly.
var the_dogs: dogs.Dogs = undefined;
/// Where they are kept.
var dogs_path: []const u8 = undefined;

pub const StartReport = struct {
    dogs_path: []const u8,
    dogs: enum { loaded, laid_out },
};

/// The development folders, for a run with no config (a checkout).
const default_roots: webbox.site.Roots = .{ .data_dir = "data", .auth_dir = "auth" };

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    const r = roots orelse default_roots;
    dogs_path = try std.fs.path.join(base, &.{ r.data_dir, "dogs.json" });
    var scratch: std.heap.ArenaAllocator = .init(base);
    defer scratch.deinit();
    const stored = try webbox.store.readOrNull(io, scratch.allocator(), dogs_path, .limited(64 * 1024));
    if (stored) |bytes| {
        the_dogs = dogs.Dogs.read(bytes) catch |e| {
            // **A DOGS FILE THAT DOES NOT READ STOPS THE START, NAMED** (fail,
            // never warn).
            std.debug.print("dog-park: {s} does not read ({t}); not starting\n", .{ dogs_path, e });
            return e;
        };
        return .{ .dogs_path = dogs_path, .dogs = .loaded };
    }
    the_dogs = dogs.Dogs.laidOut();
    try keep(io, scratch.allocator());
    return .{ .dogs_path = dogs_path, .dogs = .laid_out };
}

fn keep(io: Io, alloc: std.mem.Allocator) !void {
    try webbox.store.replace(io, alloc, dogs_path, try the_dogs.written(alloc), .{});
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const path = http.pathOf(try http.target(req, alloc));
    if (std.mem.eql(u8, path, "/")) return pageFile(req, io, alloc, "index.html", "text/html; charset=utf-8");
    if (std.mem.eql(u8, path, "/park.js")) return pageFile(req, io, alloc, "park.js", "text/javascript; charset=utf-8");
    if (std.mem.eql(u8, path, "/dogs")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req);
        return json(req, try the_dogs.written(alloc));
    }
    if (std.mem.eql(u8, path, "/leash")) {
        if (req.head.method != .POST) return http.methodNotAllowed(req);
        const asked = (try readJson(dogs.LeashRequest, req, alloc)) orelse return;
        const dog = switch (the_dogs.lookup(asked.dog)) {
            .dog => |d| d,
            .no_such_dog => return badRequest(req, "No such dog.\n"),
        };
        return json(req, try std.fmt.allocPrint(alloc, "{{\"leashed\":{d}}}", .{@intFromEnum(dog)}));
    }
    if (std.mem.eql(u8, path, "/move")) {
        if (req.head.method != .POST) return http.methodNotAllowed(req);
        const asked = (try readJson(dogs.MoveRequest, req, alloc)) orelse return;
        const dog = switch (the_dogs.lookup(asked.dog)) {
            .dog => |d| d,
            .no_such_dog => return badRequest(req, "No such dog.\n"),
        };
        the_dogs.moveTo(dog, .{ .park_x = asked.park_x, .park_y = asked.park_y });
        try keep(io, alloc);
        const at = the_dogs.at(dog);
        return json(req, try std.fmt.allocPrint(alloc, "{{\"moved\":{d},\"park_x\":{d},\"park_y\":{d}}}", .{ @intFromEnum(dog), at.park_x, at.park_y }));
    }
    return http.notFound(req);
}

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

fn json(req: *std.http.Server.Request, body: []const u8) !void {
    return req.respond(body, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

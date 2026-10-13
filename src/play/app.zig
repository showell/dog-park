//! Dog Park, played: the server for `solo/`, as webbox serves it
//! (`webbox.site.Site(App)`). The physics protocol (physics_server.zig)
//! keeps the board, its log and its snapshots under `data/physics/`, seeded
//! once from dogs.json and cows.json (laid out on a first start, then never
//! written again).
//!
//!   GET  /           solo/index.html, read from disk each time
//!   GET  /NAME.js    solo/NAME.js, read from disk each time: the page's
//!                    modules (park.js its entry), NAME `[a-z_]+`
//!   GET  /physics-H.wasm  the physics for the page (physics_page.zig),
//!                    compiled in, H its physics hash: the very code the
//!                    server judges with, cached for good under that name;
//!                    any other H is a 404. The page (index.html) names it:
//!                    `PHYSICS_HASH` in the file is the hash when served
//!   POST /load       the physics protocol's load line → its answer, text
//!   POST /report     a physics report (docs/PHYSICS.md) → its answer, text
//!
//! **THE PAGE IS READ FROM DISK** (`solo/`, from where the server runs: the
//! checkout on Linux, the site disk on metal, where assets.zon's `.site`
//! lays it), so an edit to it shows on a reload, with no rebuild.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const dogs = @import("dogs.zig");
const cows = @import("cows.zig");
const physics_server = @import("physics_server.zig");

/// Where the page lives, from the directory the server runs in.
const page_dir = "solo";

/// The most any route reads of a body (webbox's body rule): a physics
/// report's 64 KiB, and a load's (the same route family); nothing on the
/// page's own routes, which take no body.
pub fn bodyLimit(path: []const u8) u64 {
    if (physicsRoute(path) != null) return physics_server.most_body;
    return 0;
}

const PhysicsRoute = enum { report, load };

fn physicsRoute(path: []const u8) ?PhysicsRoute {
    if (std.mem.eql(u8, path, "/report")) return .report;
    if (std.mem.eql(u8, path, "/load")) return .load;
    return null;
}

/// The physics protocol's server: its own board, log and snapshots. One
/// handler runs at a time (webbox's hosts), so it is shared plainly.
pub var the_physics: physics_server.Server = undefined;

pub const Kept = enum { loaded, laid_out };

pub const StartReport = struct {
    dogs_path: []const u8,
    dogs: Kept,
    cows_path: []const u8,
    cows: Kept,
    physics: physics_server.Server.Started,
};

/// The development folder, for a run with no config (a checkout). The
/// roots' `auth_dir` is the host's (webbox opens both roots); Dog Park
/// keeps nothing there.
const default_data_dir = "data";

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    const data_dir = if (roots) |r| r.data_dir else default_data_dir;
    var scratch: std.heap.ArenaAllocator = .init(base);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const dogs_path = try std.fs.path.join(base, &.{ data_dir, "dogs.json" });
    const cows_path = try std.fs.path.join(base, &.{ data_dir, "cows.json" });
    // **THE SEED**: dogs.json and cows.json, laid out and written on a
    // first start, then only read, to resolve the physics' board when it
    // has none. **A FILE THAT DOES NOT READ STOPS THE START, NAMED** (fail,
    // never warn): the host prints a failed start's error, and this one
    // says what. No print here: the application has no stderr of its own
    // on every host (a kernel has none).
    var the_dogs: dogs.Dogs = undefined;
    const dogs_kept: Kept = if (try webbox.store.readOrNull(io, alloc, dogs_path, .limited(1024 * 1024))) |bytes| blk: {
        the_dogs = dogs.Dogs.read(bytes) catch return error.DogsFileDoesNotRead;
        break :blk .loaded;
    } else blk: {
        the_dogs = dogs.Dogs.laidOut();
        try webbox.store.replace(io, alloc, dogs_path, try the_dogs.written(alloc), .{});
        break :blk .laid_out;
    };
    var the_cows: cows.Cows = undefined;
    const cows_kept: Kept = if (try webbox.store.readOrNull(io, alloc, cows_path, .limited(1024 * 1024))) |bytes| blk: {
        the_cows = cows.Cows.read(bytes) catch return error.CowsFileDoesNotRead;
        break :blk .loaded;
    } else blk: {
        the_cows = cows.Cows.laidOut();
        try webbox.store.replace(io, alloc, cows_path, try the_cows.written(alloc), .{});
        break :blk .laid_out;
    };
    // **THE PHYSICS' BOARD**: its snapshot and log, or the seed, resolved
    // once. A board that won't come back stops the start.
    var dog_points: [dogs.dog_count]dogs.ParkPoint = undefined;
    for (the_dogs.list, &dog_points) |d, *p| p.* = d.at;
    const seed = physics_server.boardOf(&dog_points, &the_cows.list);
    const physics_started = try the_physics.start(io, base, data_dir, &seed, nowMs(io));
    return .{ .dogs_path = dogs_path, .dogs = dogs_kept, .cows_path = cows_path, .cows = cows_kept, .physics = physics_started };
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const path = http.pathOf(try http.target(req, alloc));
    if (std.mem.eql(u8, path, "/")) return indexPage(req, io, alloc);
    if (physicsWasm(path)) {
        if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
        return req.respond(@embedFile("physics.wasm"), .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/wasm" },
            .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" },
        } });
    }
    if (pageScript(path)) |name| return pageFile(req, io, alloc, name, "text/javascript; charset=utf-8");
    if (physicsRoute(path)) |which| return physicsAnswer(req, io, alloc, which);
    return http.notFound(req);
}

fn nowMs(io: Io) u64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_ms));
}

// ── the physics protocol ────────────────────────────────────────────────────

/// `POST /load` and `POST /report`: the text in, the server's answer out, as
/// text. One player, one park (the epoch says which page holds it).
fn physicsAnswer(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, which: PhysicsRoute) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const body = (try http.readLimitedBody(req, alloc, physics_server.most_body)) orelse return;
    const answer = switch (which) {
        .report => try the_physics.report(io, alloc, body),
        .load => try the_physics.load(io, alloc, body),
    };
    return req.respond(answer, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

// ── answering ───────────────────────────────────────────────────────────────

/// The page's script a path names, `/NAME.js` with NAME `[a-z_]+` (one
/// segment, so never outside `solo/`), as its file name; null for any other
/// path.
fn pageScript(path: []const u8) ?[]const u8 {
    if (path.len < 1 or path[0] != '/') return null;
    const name = path[1..];
    if (!std.mem.endsWith(u8, name, ".js")) return null;
    const stem = name[0 .. name.len - ".js".len];
    if (stem.len == 0) return null;
    for (stem) |c| if (!(std.ascii.isLower(c) or c == '_')) return null;
    return name;
}

test "pageScript takes one lower-case name ending .js, and nothing else" {
    try std.testing.expectEqualStrings("park.js", pageScript("/park.js").?);
    try std.testing.expectEqualStrings("blit.js", pageScript("/blit.js").?);
    try std.testing.expectEqualStrings("page_bits.js", pageScript("/page_bits.js").?);
    for ([_][]const u8{ "/", "/.js", "/park.jsx", "/park.json", "/Park.js", "/park2.js", "/a/park.js", "/../park.js", "/..js", "/park.js/", "park.js", "/park-x.js", "/park.js.js" }) |p| {
        try std.testing.expectEqual(@as(?[]const u8, null), pageScript(p));
    }
}

/// The physics hash the page's wasm is named by: `/physics-H.wasm`.
const physics_wasm_path = std.fmt.comptimePrint("/physics-{x:0>8}.wasm", .{@import("physics_wire.zig").physics_hash});

/// Whether a path is the physics wasm's, under this server's own hash.
fn physicsWasm(path: []const u8) bool {
    return std.mem.eql(u8, path, physics_wasm_path);
}

test "the physics wasm is served under this server's hash and no other" {
    try std.testing.expect(physicsWasm(physics_wasm_path));
    try std.testing.expectEqual(@as(usize, "/physics-12345678.wasm".len), physics_wasm_path.len);
    try std.testing.expect(!physicsWasm("/physics.wasm"));
}

/// **THE PAGE NAMES ITS WASM BY HASH**: solo/index.html, read from disk,
/// with every `PHYSICS_HASH` in it the server's physics hash, never cached,
/// so a reload always fetches the wasm the server judges with.
fn indexPage(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    const path = try std.fs.path.join(alloc, &.{ page_dir, "index.html" });
    const raw = (try webbox.store.readOrNull(io, alloc, path, .limited(1024 * 1024))) orelse return http.notFound(req);
    const hash = physics_wasm_path["/physics-".len..][0..8];
    const body = try std.mem.replaceOwned(u8, alloc, raw, "PHYSICS_HASH", hash);
    return req.respond(body, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

/// A page file read from `solo/`, or 404 when there is none of that name.
fn pageFile(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, name: []const u8, content_type: []const u8) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    const path = try std.fs.path.join(alloc, &.{ page_dir, name });
    const body = (try webbox.store.readOrNull(io, alloc, path, .limited(1024 * 1024))) orelse return http.notFound(req);
    return req.respond(body, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

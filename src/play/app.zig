//! Dog Park, played: the server for `solo/`, as webbox serves it
//! (`webbox.site.Site(App)`). The physics protocol (physics_server.zig)
//! keeps the board, its log and its snapshots under `data/physics/`, seeded
//! on a first start from the first layout (`physics.Board.laidOut()`). A
//! dogs.json or cows.json an older server left in the data dir is ignored.
//!
//! **WHO MAY PLAY** (players.zig): at most five devices, each its own game,
//! one playing at a time.
//!
//!   GET  /           solo/landing.html: the Begin Game button
//!   POST /begin      an account (a signed cookie) for a device that has
//!                    none, while one is left; then 303 to /dogpark. Every
//!                    one taken: solo/full.html
//!   GET  /dogpark    solo/index.html, the game, for a device with an
//!                    account; 303 to / for one without
//!   POST /reset      this device's next load starts its game afresh
//!   GET  /NAME.js    solo/NAME.js, read from disk each time: the page's
//!                    modules (park.js its entry), NAME `[a-z_]+`
//!   GET  /physics-H.wasm  the physics for the page (physics_page.zig),
//!                    compiled in, H its physics hash: the very code the
//!                    server judges with, cached for good under that name;
//!                    any other H is a 404. The page (index.html) names it:
//!                    `PHYSICS_HASH` in the file is the hash when served
//!   POST /load       the physics protocol's load line → its answer, text
//!   POST /report     a physics report (docs/PHYSICS.md) → its answer, text
//!                    Both for a device with an account (403 without). A
//!                    report with ticks also needs the turn: 503 `busy N`
//!                    (seconds) while another account holds it
//!
//! **THE PAGE IS READ FROM DISK** (`solo/`, from where the server runs: the
//! checkout on Linux, the site disk on metal, where assets.zon's `.site`
//! lays it), so an edit to it shows on a reload, with no rebuild.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const physics = @import("physics.zig");
const physics_server = @import("physics_server.zig");
const players = @import("players.zig");

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

/// **THE GAMES**, one per account, each the physics protocol's server with
/// its own board, log and snapshots (`<data>/game-<slot>`), started when its
/// player first loads. One handler runs at a time (webbox's hosts), so all
/// of this is shared plainly.
var games: [players.most_players]?*physics_server.Server = @splat(null);
/// A slot whose next load starts its game afresh (`POST /reset`).
var reset_next: [players.most_players]bool = @splat(false);
/// The accounts handed out (players.claimed_file), and the turn.
var claimed: u8 = 0;
var turn: players.Turn = .{};
var long_alloc: std.mem.Allocator = undefined;
var data_root: []const u8 = undefined;
var auth_root: []const u8 = undefined;
/// The cookie's security: main.zig sets it from DOGPARK_INSECURE_COOKIE
/// before the host starts.
pub var cookie_mode: players.CookieMode = .secure;

pub const StartReport = struct {
    claimed: u8,
    secret: enum { found, made },
    cookie_mode: players.CookieMode,
    data_dir: []const u8,
};

/// The development folders, for a run with no config (a checkout): the
/// games' data, and the site secret that signs the cookies.
const default_data_dir = "data";
const default_auth_dir = "auth";

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    long_alloc = base;
    data_root = if (roots) |r| r.data_dir else default_data_dir;
    auth_root = if (roots) |r| r.auth_dir else default_auth_dir;
    // Both roots made here, as the host opens them after the setup: the
    // games' folders come later, at each player's first load.
    try webbox.store.makeDir(io, base, data_root);
    try webbox.store.makeDir(io, base, auth_root);
    claimed = try players.readClaimed(io, base, data_root);
    var secret: @FieldType(StartReport, "secret") = .found;
    if (try webbox.site_secret.load(io, base, auth_root) == null) {
        try webbox.site_secret.create(io, base, auth_root);
        secret = .made;
    }
    return .{ .claimed = claimed, .secret = secret, .cookie_mode = cookie_mode, .data_dir = data_root };
}

/// Slot `s`'s game, started (from its snapshot and log, or the first
/// layout) the first time its player loads.
pub fn game(io: Io, s: players.Slot) !*physics_server.Server {
    if (games[s]) |g| return g;
    const g = try long_alloc.create(physics_server.Server);
    errdefer long_alloc.destroy(g);
    const dir = try std.fmt.allocPrint(long_alloc, "{s}/game-{d}", .{ data_root, s });
    const seed = physics.Board.laidOut();
    _ = try g.start(io, long_alloc, dir, &seed, nowMs(io));
    games[s] = g;
    return g;
}

/// Whether a report carries ticks: a `t T` line (never its first, the
/// header).
fn hasTicks(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\nt ") != null;
}

test "a report has ticks when a line starts `t `, and only then" {
    try std.testing.expect(hasTicks("dogpark 1 physics 0 page 1.1 req 2\nfrom 4 wall 9\nt 5 +0\n"));
    try std.testing.expect(!hasTicks("dogpark 1 physics 0 page 1.1 req 2\nfrom 4\nview 5 1280x800 1,1\nheld 5 1,1\n"));
    try std.testing.expect(!hasTicks("dogpark 1 physics 0 page 1.1 req 2\nfrom 4\n tile t 5\n"));
}

/// The `Cookie` request header's value naming slot `s`, as a browser
/// sends it back: for the route tests and the bench.
pub fn cookieFor(io: Io, alloc: std.mem.Allocator, s: players.Slot) ![]const u8 {
    const set = try players.cookieHeader(cookie_mode, io, alloc, auth_root, s, nowUnix(io));
    return set[0 .. std.mem.indexOfScalar(u8, set, ';') orelse set.len];
}

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const path = http.pathOf(try http.target(req, alloc));
    if (std.mem.eql(u8, path, "/")) return pageFile(req, io, alloc, "landing.html", html_type);
    if (std.mem.eql(u8, path, "/begin")) return begin(req, io, alloc);
    if (std.mem.eql(u8, path, "/dogpark")) return gamePage(req, io, alloc);
    if (std.mem.eql(u8, path, "/reset")) return resetGame(req, io, alloc);
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

const html_type = "text/html; charset=utf-8";
const text_type = "text/plain; charset=utf-8";

fn plain(req: *std.http.Server.Request, status: std.http.Status, text: []const u8) !void {
    return req.respond(text, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = text_type },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

/// `POST /begin`, the landing page's button: a device with an account goes
/// on to the game; one without takes the next slot, while one is left.
fn begin(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const has = try players.slotOfRequest(cookie_mode, io, alloc, req, auth_root, nowUnix(io));
    switch (players.claim(has, claimed)) {
        .has => return http.redirect(req, "/dogpark"),
        .full => return pageBody(req, io, alloc, "full.html", html_type),
        .new => |s| {
            const cookie = try players.cookieHeader(cookie_mode, io, alloc, auth_root, s, nowUnix(io));
            // Counted before the cookie goes, so a crash never hands it out again.
            try players.writeClaimed(io, alloc, data_root, s + 1);
            claimed = s + 1;
            http.declineExpectation(req);
            return req.respond("", .{ .status = .see_other, .extra_headers = &.{
                .{ .name = "location", .value = "/dogpark" },
                .{ .name = "set-cookie", .value = cookie },
            } });
        },
    }
}

/// `GET /dogpark`: the game, for a device with an account.
fn gamePage(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    if (try players.slotOfRequest(cookie_mode, io, alloc, req, auth_root, nowUnix(io)) == null) return http.redirect(req, "/");
    return indexPage(req, io, alloc);
}

/// `POST /reset`: this device's next load starts its game from the first
/// layout. The page reloads after it.
fn resetGame(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const s = (try players.slotOfRequest(cookie_mode, io, alloc, req, auth_root, nowUnix(io))) orelse return plain(req, .forbidden, "no account\n");
    reset_next[s] = true;
    return plain(req, .ok, "reset\n");
}

/// `POST /load` and `POST /report`: the text in, this device's game's
/// answer out, as text, while it holds the turn.
fn physicsAnswer(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, which: PhysicsRoute) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    // The cookie first: a request's headers are gone once its body is read.
    const s = (try players.slotOfRequest(cookie_mode, io, alloc, req, auth_root, nowUnix(io))) orelse return plain(req, .forbidden, "no account\n");
    const body = (try http.readLimitedBody(req, alloc, physics_server.most_body)) orelse return;
    // **ONLY PLAY TAKES THE TURN** (Steve, 2026-10-15: "I'm just trying to
    // prevent contention from all the drags"): a report with ticks in it.
    // A load, and a report of only a view or a held (a pan), never wait.
    if (which == .report and hasTicks(body)) switch (turn.ask(s, nowMs(io))) {
        .granted => {},
        .wait_s => |n| return plain(req, .service_unavailable, try std.fmt.allocPrint(alloc, "busy {d}\n", .{n})),
    };
    const g = try game(io, s);
    const answer = switch (which) {
        .report => try g.report(io, alloc, body),
        .load => blk: {
            const from: physics_server.Server.LoadFrom = if (reset_next[s]) .layout else .kept;
            const a = try g.load(io, alloc, body, from);
            reset_next[s] = false;
            break :blk a;
        },
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

/// A page file read from `solo/`, for a GET, or 404 when there is none of
/// that name.
fn pageFile(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, name: []const u8, content_type: []const u8) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    return pageBody(req, io, alloc, name, content_type);
}

/// A page file read from `solo/` as the answer, whatever the method (the
/// park-is-full page answers Begin Game's POST).
fn pageBody(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, name: []const u8, content_type: []const u8) !void {
    const path = try std.fs.path.join(alloc, &.{ page_dir, name });
    const body = (try webbox.store.readOrNull(io, alloc, path, .limited(1024 * 1024))) orelse return http.notFound(req);
    return req.respond(body, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

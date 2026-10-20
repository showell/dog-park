//! Dog Park, played: the server for `solo/`, as webbox serves it
//! (`webbox.site.Site(App)`).
//!
//! **A PLAYER'S GAMES, ONE A LEVEL** (`data/game-<slot>/`):
//!   level            `L U\n`: the level played and the highest unlocked,
//!                    1-based (Level One is 1); a new player's is `1 1`
//!   level-<n>/physics/  level n's game: the physics protocol's board, log
//!                    and snapshots (physics_server.zig), seeded on its first
//!                    start from the level's first layout
//!                    (`physics.Board.laidOutAt(n - 1)`)
//! Only the level played has a running server; switching snapshots it and
//! starts the other from its own folder, so no level loses its progress.
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
//!   POST /reset      this device's next load starts its level's game afresh
//!   POST /level      `level N\n`: play level N, when N is unlocked, or is
//!                    the next and the level played is won (every one of its
//!                    cows in one herd, admin.zig's `won`): `level N of U`;
//!                    else 409 `refused <why>`. The page then loads afresh
//!   /admin, /admin/login, /admin/host, /admin/log, /admin/game: the operator's pages
//!                    (admin.zig), by the admin key
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
const admin = @import("admin.zig");
const shale = @import("shale.zig");
const wire = @import("physics_wire.zig");

/// Where the page lives, from the directory the server runs in.
const page_dir = "solo";

/// The most any route reads of a body (webbox's body rule): a physics
/// report's 64 KiB, and a load's (the same route family); nothing on the
/// page's own routes, which take no body.
pub fn bodyLimit(path: []const u8) u64 {
    if (physicsRoute(path) != null) return physics_server.most_body;
    if (std.mem.eql(u8, path, "/admin/login")) return admin.most_login_body;
    if (std.mem.eql(u8, path, "/level")) return most_level_body;
    // **AN UPLOAD, SO ITS SENDER IS KNOWN FIRST** (the box's cold review of
    // 214): a cap past webbox's `before_turn_most` makes it one, and an
    // upload is read only once `uploader` names who sent it, from the head:
    // a stranger's 64 KiB is never read, nor charged to the small bodies'
    // budget. The route reads at most `shale.most_body` of it.
    if (std.mem.eql(u8, path, "/admin/script")) return webbox.body.before_turn_most + 1;
    return 0;
}

const PhysicsRoute = enum { report, load };

fn physicsRoute(path: []const u8) ?PhysicsRoute {
    if (std.mem.eql(u8, path, "/report")) return .report;
    if (std.mem.eql(u8, path, "/load")) return .load;
    return null;
}

/// **THE GAMES**, one per account, each the physics protocol's server for
/// the level its player plays, with its own board, log and snapshots
/// (`<data>/game-<slot>/level-<n>`), started when its player first loads. One handler runs at a time (webbox's hosts), so all
/// of this is shared plainly.
var games: [players.most_players]?*physics_server.Server = @splat(null);
/// Each slot's level and the highest it has unlocked (`<data>/game-<slot>/level`),
/// read when its game starts.
var levels: [players.most_players]Levels = @splat(.new);
/// A slot whose next load starts its game afresh (`POST /reset`).
var reset_next: [players.most_players]bool = @splat(false);
/// Each slot's last load or report, Unix ms (0: none this run), for the
/// operator's page.
var last_ms: [players.most_players]u64 = @splat(0);
/// The accounts handed out (players.claimed_file), and the turn.
var claimed: u8 = 0;
/// When this server started, by the wall clock in ms: /version's
/// `started_ms`, so a restart shows as a new value.
var started_ms: u64 = 0;
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
    admin_key: @typeInfo(@typeInfo(@TypeOf(admin.ensureKey)).@"fn".return_type.?).error_union.payload,
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
    // Nothing from another setup (a test's) carries over.
    games = @splat(null);
    levels = @splat(.new);
    reset_next = @splat(false);
    last_ms = @splat(0);
    claimed = try players.readClaimed(io, base, data_root);
    started_ms = nowMs(io);
    var secret: @FieldType(StartReport, "secret") = .found;
    if (try webbox.site_secret.load(io, base, auth_root) == null) {
        try webbox.site_secret.create(io, base, auth_root);
        secret = .made;
    }
    const admin_key = try admin.ensureKey(io, base, auth_root);
    return .{ .claimed = claimed, .secret = secret, .admin_key = admin_key, .cookie_mode = cookie_mode, .data_dir = data_root };
}

/// Slot `s`'s game, its level's, started (from its snapshot and log, or
/// the level's first layout) the first time its player loads.
pub fn game(io: Io, s: players.Slot) !*physics_server.Server {
    if (games[s]) |g| return g;
    var arena: std.heap.ArenaAllocator = .init(long_alloc);
    defer arena.deinit();
    const lv = try readLevels(io, arena.allocator(), s);
    const g = try long_alloc.create(physics_server.Server);
    errdefer long_alloc.destroy(g);
    try startLevel(io, arena.allocator(), g, s, lv, nowMs(io));
    games[s] = g;
    levels[s] = lv;
    return g;
}

/// **A PLAYER'S LEVEL**: the one played, and the highest unlocked, 1-based.
pub const Levels = struct {
    at: u32,
    unlocked: u32,

    pub const new: Levels = .{ .at = 1, .unlocked = 1 };
};

/// The most a `POST /level` body holds: `level N\n`.
const most_level_body = 64;

fn levelsPath(alloc: std.mem.Allocator, s: players.Slot) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/game-{d}/level", .{ data_root, s });
}

/// Slot `s`'s levels from its file; a new player's (`1 1`) written when
/// there is none. A file that does not read stops its game: never a guess.
fn readLevels(io: Io, alloc: std.mem.Allocator, s: players.Slot) !Levels {
    const path = try levelsPath(alloc, s);
    const bytes = (try webbox.store.readOrNull(io, alloc, path, .limited(64))) orelse {
        try writeLevels(io, alloc, s, .new);
        return .new;
    };
    return parseLevels(bytes) orelse error.LevelFileDoesNotRead;
}

fn writeLevels(io: Io, alloc: std.mem.Allocator, s: players.Slot, lv: Levels) !void {
    try webbox.store.replace(io, alloc, try levelsPath(alloc, s), try std.fmt.allocPrint(alloc, "{d} {d}\n", .{ lv.at, lv.unlocked }), .{});
}

/// `L U\n`, 1 <= L <= U <= the levels there are; null for anything else.
fn parseLevels(bytes: []const u8) ?Levels {
    if (!std.mem.endsWith(u8, bytes, "\n")) return null;
    var it = std.mem.splitScalar(u8, bytes[0 .. bytes.len - 1], ' ');
    const at = wire.parseDec(it.next() orelse "", physics.level_count) catch return null;
    const unlocked = wire.parseDec(it.next() orelse "", physics.level_count) catch return null;
    if (it.next() != null or at == 0 or at > unlocked) return null;
    return .{ .at = @intCast(at), .unlocked = @intCast(unlocked) };
}

/// Starts `g` on slot `s`'s level `lv.at`, from its own folder.
fn startLevel(io: Io, alloc: std.mem.Allocator, g: *physics_server.Server, s: players.Slot, lv: Levels, now: u64) !void {
    const dir = try std.fmt.allocPrint(alloc, "{s}/game-{d}/level-{d}", .{ data_root, s, lv.at });
    const seed = physics.Board.laidOutAt(@intCast(lv.at - 1));
    _ = try g.start(io, long_alloc, dir, &seed, now);
    if (g.level() != lv.at) return error.LevelFolderHoldsAnotherLevel;
    g.unlocked = lv.unlocked;
}

/// What `POST /level` does: play level `to`, or refuse, and why.
pub const LevelAnswer = union(enum) {
    to: u32,
    refused: enum { unreadable, no_such_level, locked, not_won },
};

/// **THE LEVEL RULE**: `level N\n` is allowed when N is unlocked, or is
/// the next one and the level played is won.
pub fn decideLevel(body: []const u8, lv: Levels, won: bool) LevelAnswer {
    const line = if (std.mem.endsWith(u8, body, "\n")) body[0 .. body.len - 1] else body;
    if (!std.mem.startsWith(u8, line, "level ")) return .{ .refused = .unreadable };
    const n = wire.parseDec(line["level ".len..], std.math.maxInt(u32)) catch return .{ .refused = .unreadable };
    if (n == 0 or n > physics.level_count) return .{ .refused = .no_such_level };
    if (n <= lv.unlocked) return .{ .to = @intCast(n) };
    if (n > lv.unlocked + 1) return .{ .refused = .locked };
    if (!won) return .{ .refused = .not_won };
    return .{ .to = @intCast(n) };
}

test "the level rule: an unlocked level any time; the next only once the level played is won; nothing else" {
    const one: Levels = .new;
    try std.testing.expectEqual(LevelAnswer{ .to = 1 }, decideLevel("level 1\n", one, false));
    try std.testing.expectEqual(LevelAnswer{ .refused = .not_won }, decideLevel("level 2\n", one, false));
    try std.testing.expectEqual(LevelAnswer{ .to = 2 }, decideLevel("level 2\n", one, true));
    try std.testing.expectEqual(LevelAnswer{ .to = 1 }, decideLevel("level 1\n", .{ .at = 2, .unlocked = 2 }, false));
    try std.testing.expectEqual(LevelAnswer{ .to = 2 }, decideLevel("level 2\n", .{ .at = 1, .unlocked = 2 }, false));
    try std.testing.expectEqual(LevelAnswer{ .refused = .no_such_level }, decideLevel("level 3\n", .{ .at = 2, .unlocked = 2 }, true));
    try std.testing.expectEqual(LevelAnswer{ .refused = .no_such_level }, decideLevel("level 0\n", one, true));
    for ([_][]const u8{ "", "level\n", "level 01\n", "level 2 \n", "levels 2\n", "level x\n" }) |bad| {
        try std.testing.expectEqual(LevelAnswer{ .refused = .unreadable }, decideLevel(bad, one, true));
    }
}

test "the levels file: `L U`, L at most U, both levels there are" {
    try std.testing.expectEqual(Levels{ .at = 1, .unlocked = 2 }, parseLevels("1 2\n").?);
    for ([_][]const u8{ "1 1", "2 1\n", "0 1\n", "1 3\n", "1  1\n", "1 1 1\n", "" }) |bad| {
        try std.testing.expectEqual(@as(?Levels, null), parseLevels(bad));
    }
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
    if (std.mem.eql(u8, path, "/level")) return levelRoute(req, io, alloc);
    if (std.mem.eql(u8, path, "/version")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
        const now = nowMs(io);
        const body = try versionText(alloc, @import("dogpark_build").commit, @import("dogpark_build").roc, started_ms, now, claimed, turnsHeld(&turn, now));
        return req.respond(body, .{ .extra_headers = &.{http.json_ct} });
    }
    if (std.mem.eql(u8, path, "/admin") or std.mem.startsWith(u8, path, "/admin/")) return adminRoute(req, io, alloc, path);
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

/// **WHAT AN OBSERVER ASKS** (`GET /version`, metal-vmm QUEUE 228.2): which
/// commit serves, since when, the time now, and how much is in use: the
/// accounts handed out of the most, and the turns held now of the most. No
/// secret, nobody's name: anyone may ask, as of lynrummy.com's.
fn versionText(alloc: std.mem.Allocator, commit: []const u8, roc: []const u8, started: u64, now: u64, accounts: u8, held: usize) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{"result":"success","app":"dog-park","commit":"{s}","roc":"{s}","started_ms":{d},"now_ms":{d},"accounts":{d},"accounts_most":{d},"turns_held":{d},"turns_most":{d}}}
    , .{ commit, roc, started, now, accounts, players.most_players, held, players.most_playing });
}

/// The turns held at `now`: a holder whose time has run out holds none, though
/// it stays in the list until the next ask.
fn turnsHeld(t: *const players.Turn, now: u64) usize {
    var n: usize = 0;
    for (t.holders[0..t.len]) |h| {
        if (now < h.until_ms) n += 1;
    }
    return n;
}

test "/version says the commit, the Roc that built the physics, the start, the time, the accounts and the turns, as JSON with no secret" {
    const text = try versionText(std.testing.allocator, "47ad787", "nightly-2026-10-18-1df370f", 1_789_000_000_000, 1_789_000_060_000, 3, 2);
    defer std.testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(struct {
        result: []const u8,
        app: []const u8,
        commit: []const u8,
        roc: []const u8,
        started_ms: u64,
        now_ms: u64,
        accounts: u8,
        accounts_most: u8,
        turns_held: usize,
        turns_most: usize,
    }, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("47ad787", parsed.value.commit);
    try std.testing.expectEqualStrings("nightly-2026-10-18-1df370f", parsed.value.roc);
    try std.testing.expectEqual(@as(u64, 1_789_000_060_000), parsed.value.now_ms);
    try std.testing.expectEqual(@as(u8, 3), parsed.value.accounts);
    try std.testing.expectEqual(@as(u8, players.most_players), parsed.value.accounts_most);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.turns_held);
}

test "a turn whose time ran out is not held, though it is still listed" {
    var t: players.Turn = .{};
    _ = t.ask(1, 1000);
    _ = t.ask(2, 1000);
    try std.testing.expectEqual(@as(usize, 2), turnsHeld(&t, 1000));
    try std.testing.expectEqual(@as(usize, 0), turnsHeld(&t, 1000 + players.turn_ms));
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

/// **WHO SENDS AN UPLOAD** (webbox's body rule), from the head: the only
/// upload is a script for the operator's route, and only the operator, by
/// the admin key, may send one; anyone else's is never read.
pub fn uploader(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !?[]const u8 {
    const path = http.pathOf(try http.target(req, alloc));
    if (!std.mem.eql(u8, path, "/admin/script")) return null;
    return if (try admin.isAdmin(req, cookie_mode, io, alloc, auth_root, nowUnix(io))) "admin" else null;
}

/// **BETWEEN REQUESTS** (webbox's `Site.between`): a slice of the
/// operator's background script, if one runs (shale.zig).
pub fn between(io: Io, now: i64) bool {
    return shale.between(io, now);
}

/// What `/admin/log`'s header says the application is: Dog Park bakes in no
/// commit, its physics hash says which build it is (as `/admin/host` does).
const log_names_app = std.fmt.comptimePrint("Dog Park, physics {x:0>8}", .{@import("physics_wire.zig").physics_hash});

/// The operator's pages: the key first (a bearer or the admin cookie),
/// read before any body; the login form is the one way in without it.
fn adminRoute(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, path: []const u8) !void {
    const now = nowUnix(io);
    const signed_in = try admin.isAdmin(req, cookie_mode, io, alloc, auth_root, now);
    if (std.mem.eql(u8, path, "/admin")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
        return admin.front(req, alloc, signed_in);
    }
    if (std.mem.eql(u8, path, "/admin/login")) {
        if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
        return admin.login(req, cookie_mode, io, alloc, auth_root, now);
    }
    if (!signed_in) return admin.forbidden(req);
    // The operator's scripts (shale.zig): a signed one in, the run's state out.
    if (std.mem.eql(u8, path, "/admin/script")) return switch (req.head.method) {
        .POST => shale.post(req, io, alloc, long_alloc, data_root, auth_root, now),
        .GET => shale.status(req),
        else => http.methodNotAllowed(req, .POST),
    };
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    if (std.mem.eql(u8, path, "/admin/host")) return admin.host(req, io, alloc);
    // The host's whole log as plain text, filtered, for an agent (webbox's,
    // angry-gopher's too: metal-vmm QUEUE 221).
    if (std.mem.eql(u8, path, "/admin/log")) return webbox.admin_log.render(req, io, alloc, log_names_app);
    if (std.mem.eql(u8, path, "/admin/game")) return admin.game(req, io, alloc, .{
        .claimed = claimed,
        .turn = &turn,
        .games = &games,
        .last_ms = &last_ms,
        .data_dir = data_root,
        .now_ms = nowMs(io),
    });
    return http.notFound(req);
}

/// `POST /level`: `level N\n` in; `level N of U\n`, or 409 `refused
/// <why>\n`. A switch snapshots the level left and starts the other from
/// its folder; the level file is written first, so a failed start is
/// retried from it at the next load.
fn levelRoute(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const s = (try players.slotOfRequest(cookie_mode, io, alloc, req, auth_root, nowUnix(io))) orelse return plain(req, .forbidden, "no account\n");
    const body = (try http.readLimitedBody(req, alloc, most_level_body)) orelse return;
    last_ms[s] = nowMs(io);
    const g = try game(io, s);
    const lv = levels[s];
    switch (decideLevel(body, lv, admin.won(&g.kept.board))) {
        .refused => |why| return plain(req, .conflict, try std.fmt.allocPrint(alloc, "refused {t}\n", .{why})),
        .to => |n| {
            const next: Levels = .{ .at = n, .unlocked = @max(lv.unlocked, n) };
            if (next.at != lv.at or next.unlocked != lv.unlocked) try writeLevels(io, alloc, s, next);
            levels[s] = next;
            if (next.at != lv.at) {
                errdefer games[s] = null;
                const after = g.started + 1;
                try g.leave(io, alloc);
                try startLevel(io, alloc, g, s, next, @max(nowMs(io), after));
                reset_next[s] = false;
            }
            g.unlocked = next.unlocked;
            return plain(req, .ok, try std.fmt.allocPrint(alloc, "level {d} of {d}\n", .{ next.at, next.unlocked }));
        },
    }
}

/// `POST /reset`: this device's next load starts its level's game from the
/// level's first layout; the other levels' games stay. The page reloads
/// after it.
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
    last_ms[s] = nowMs(io);
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

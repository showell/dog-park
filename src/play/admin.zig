//! **THE OPERATOR'S PAGES** (Steve, 2026-10-15: "a similar /admin/host as we
//! use for Gopher ... and a custom admin screen for the game info").
//!
//!   GET  /admin          the way in: links when signed in, else a form
//!   POST /admin/login    the key in a form: an admin cookie, then /admin/game
//!   GET  /admin/host     the running server: its requests and errors, its
//!                        memory, and whatever the host says about itself
//!   GET  /admin/game     the game: accounts, turns, and each game's state
//!
//! **THE KEY** is `_admin_key` in the auth folder (64 hex digits), made on
//! the first start; the operator reads it from the file. Every admin page
//! takes it as `Authorization: Bearer <key>` (curl, as gopher's /admin/host
//! does), or the signed admin cookie a login sets (a browser). Without
//! either: 403, and nothing about the game.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const webbox = @import("webbox");
const http = webbox.http;
const html = webbox.html;
const signed = webbox.signed;
const signed_cookie = webbox.signed_cookie;
const physics = @import("physics.zig");
const players = @import("players.zig");
const physics_server = @import("physics_server.zig");

const Request = std.http.Server.Request;

/// The admin key's file, in the auth folder.
pub const key_file = "_admin_key";

/// The admin key, made once: 32 random bytes as 64 hex digits, private.
/// Whether it was found or made.
pub fn ensureKey(io: Io, alloc: Alloc, auth_dir: []const u8) !enum { found, made } {
    const path = try std.fs.path.join(alloc, &.{ auth_dir, key_file });
    if (try webbox.store.readOrNull(io, alloc, path, .limited(256)) != null) return .found;
    var b: [32]u8 = undefined;
    io.random(&b);
    const hex = std.fmt.bytesToHex(b, .lower);
    try webbox.store.createNew(io, alloc, path, &hex, .{ .private = true });
    return .made;
}

fn keyOf(io: Io, alloc: Alloc, auth_dir: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(alloc, &.{ auth_dir, key_file });
    const k = (try webbox.store.readOrNull(io, alloc, path, .limited(256))) orelse return null;
    const t = std.mem.trim(u8, k, " \t\r\n");
    if (t.len < 32) return null;
    return t;
}

fn sameKey(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var d: u8 = 0;
    for (a, b) |x, y| d |= x ^ y;
    return d == 0;
}

// ── the cookie ──────────────────────────────────────────────────────────────

const admin_kind: signed.Kind = .{
    .label = "dogpark-admin\n",
    .lifetime_secs = 30 * 24 * 3600,
    .skew_secs = 300,
    .validId = isAdminId,
};

fn isAdminId(id: []const u8) bool {
    return std.mem.eql(u8, id, "admin");
}

fn cookieOf(mode: players.CookieMode) signed_cookie.Cookie {
    return .{ .name = switch (mode) {
        .secure => "__Host-dogpark-admin",
        .insecure => "dogpark-admin",
    }, .kind = admin_kind };
}

fn cookieHeader(mode: players.CookieMode, io: Io, alloc: Alloc, auth_dir: []const u8, now: i64) ![]const u8 {
    const c = cookieOf(mode);
    const secret = (try webbox.site_secret.load(io, alloc, auth_dir)) orelse return error.NoSiteSecret;
    const value = try signed.sign(alloc, c.kind, secret, "admin", now);
    return switch (mode) {
        .secure => signed_cookie.header(c, alloc, value),
        .insecure => std.fmt.allocPrint(alloc, "{s}={s}; Path=/admin; Max-Age={d}; HttpOnly; SameSite=Strict", .{ c.name, value, c.kind.lifetime_secs }),
    };
}

/// Whether this request is the operator's: the bearer, or the admin cookie.
/// Read before any body (a request's headers are gone once it is read).
pub fn isAdmin(req: *Request, mode: players.CookieMode, io: Io, alloc: Alloc, auth_dir: []const u8, now: i64) !bool {
    const key = (try keyOf(io, alloc, auth_dir)) orelse return false;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "authorization")) continue;
        const v = std.mem.trim(u8, h.value, " ");
        if (std.mem.startsWith(u8, v, "Bearer ") and sameKey(std.mem.trim(u8, v["Bearer ".len..], " "), key)) return true;
    }
    return switch (try signed_cookie.read(cookieOf(mode), io, alloc, req, auth_dir, now)) {
        .verified => true,
        .none, .no_secret, .invalid => false,
    };
}

// ── the pages ───────────────────────────────────────────────────────────────

/// What the game's pages read: the app's state, passed in, so this file
/// keeps none of its own.
pub const View = struct {
    claimed: u8,
    turn: *const players.Turn,
    games: []const ?*physics_server.Server,
    last_ms: []const u64,
    data_dir: []const u8,
    now_ms: u64,
};

fn begin(b: *std.ArrayList(u8), alloc: Alloc, title: []const u8, refresh: bool) !void {
    try b.print(alloc,
        \\<!doctype html><html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">{s}
        \\<title>{s}</title><style>
        \\body {{ font: 15px system-ui, sans-serif; margin: 16px; color: #234; background: #f6f8f4; }}
        \\table {{ border-collapse: collapse; margin: 8px 0 20px; }}
        \\td, th {{ border: 1px solid #ccd; padding: 4px 8px; text-align: left; vertical-align: top; }}
        \\th {{ background: #e9f3e1; }} .muted {{ color: #789; }} .bad {{ color: #b22; font-weight: 600; }}
        \\nav a {{ margin-right: 14px; }} pre.log {{ background: #fff; border: 1px solid #ccd; padding: 8px; overflow-x: auto; }}
        \\</style></head><body><nav><a href="/admin/game">The game</a><a href="/admin/host">The server</a><a href="/">The park</a></nav><h1>{s}</h1>
        \\
    , .{ if (refresh) "<meta http-equiv=\"refresh\" content=\"5\">" else "", title, title });
}

fn row(b: *std.ArrayList(u8), alloc: Alloc, label: []const u8, value: []const u8) !void {
    try b.print(alloc, "<tr><td>{s}</td><td>{s}</td></tr>", .{ try html.htmlEscape(alloc, label), try html.htmlEscape(alloc, value) });
}

fn respond(req: *Request, body: []const u8) !void {
    return req.respond(body, .{ .extra_headers = &.{ http.html_ct, .{ .name = "cache-control", .value = "no-store" } } });
}

/// `GET /admin`: links for the operator; the form for anyone else.
pub fn front(req: *Request, alloc: Alloc, signed_in: bool) !void {
    var b: std.ArrayList(u8) = .empty;
    try begin(&b, alloc, "🐕 Dog Park, the operator's", false);
    if (signed_in) {
        try b.appendSlice(alloc, "<p>Signed in.</p>\n");
    } else {
        try b.appendSlice(alloc,
            \\<form method="post" action="/admin/login"><p>The admin key (the auth folder's <code>_admin_key</code>):</p>
            \\<p><input type="password" name="key" size="70" autocomplete="off"> <button type="submit">Sign in</button></p></form>
            \\
        );
    }
    try b.appendSlice(alloc, "</body></html>\n");
    return respond(req, b.items);
}

/// `POST /admin/login`: the form's key, checked; the cookie, then the game.
pub fn login(req: *Request, mode: players.CookieMode, io: Io, alloc: Alloc, auth_dir: []const u8, now: i64) !void {
    const body = (try http.readLimitedBody(req, alloc, most_login_body)) orelse return;
    const key = (try keyOf(io, alloc, auth_dir)) orelse return forbidden(req);
    const given = formField(body, "key") orelse return forbidden(req);
    if (!sameKey(given, key)) return forbidden(req);
    const cookie = try cookieHeader(mode, io, alloc, auth_dir, now);
    http.declineExpectation(req);
    return req.respond("", .{ .status = .see_other, .extra_headers = &.{
        .{ .name = "location", .value = "/admin/game" },
        .{ .name = "set-cookie", .value = cookie },
    } });
}

/// The login form's body, at most.
pub const most_login_body = 1024;

/// A form field's value (`application/x-www-form-urlencoded`): the key is
/// hex, so nothing in it is ever escaped.
fn formField(body: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, body, "\r\n"), '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn forbidden(req: *Request) !void {
    return req.respond("the operator's only: sign in at /admin\n", .{ .status = .forbidden, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

/// `GET /admin/host`: the running server, as gopher's page shows it, less
/// what is gopher's.
pub fn host(req: *Request, io: Io, alloc: Alloc) !void {
    var b: std.ArrayList(u8) = .empty;
    try begin(&b, alloc, "🐕 The running server", true);
    const t = &webbox.traffic.global;
    if (t.n_errors > 0) {
        try b.print(alloc, "<h2>Errors since boot</h2>\n<p class=\"bad\">{d} answers were 500 or over; the newest first:</p>\n<pre class=\"log\">", .{t.n_errors});
        var k: usize = 0;
        while (t.newestError(k)) |e| : (k += 1) {
            var line: std.Io.Writer.Allocating = .init(alloc);
            try webbox.traffic.writeSeen(e, &line.writer);
            try b.print(alloc, "{s}\n", .{try html.htmlEscape(alloc, line.written())});
        }
        try b.appendSlice(alloc, "</pre>\n");
    }
    const mem = webbox.mem_meter.snapshot();
    try b.appendSlice(alloc, "<h2>The application</h2>\n<table>");
    try row(&b, alloc, "physics", std.fmt.comptimePrint("{x:0>8}", .{@import("physics_wire.zig").physics_hash}));
    try row(&b, alloc, "base heap, live", try std.fmt.allocPrint(alloc, "{d} bytes in {d} allocations", .{ mem.live_bytes, mem.live_allocs }));
    {
        var classes: std.Io.Writer.Allocating = .init(alloc);
        try t.writeClasses(&classes.writer);
        try row(&b, alloc, "requests since boot", classes.written());
        var slow: std.Io.Writer.Allocating = .init(alloc);
        for (t.slowest[0..t.n_slowest], 0..) |*one, i| {
            if (i > 0) try slow.writer.writeAll("; ");
            try webbox.traffic.writeSeen(one, &slow.writer);
        }
        try row(&b, alloc, "the slowest", if (t.n_slowest > 0) slow.written() else "none yet");
    }
    try row(&b, alloc, "requests refused at the edge", try webbox.edge.countsText(alloc));
    try b.appendSlice(alloc, "</table>\n<h2>The host</h2>\n");
    const facts = try webbox.host_facts.facts(io, alloc);
    if (facts.len == 0) {
        try b.appendSlice(alloc, "<p class=\"muted\">This host reports nothing about itself.</p>\n");
    } else {
        try b.appendSlice(alloc, "<table>");
        for (facts) |f| try row(&b, alloc, f.label, f.value);
        try b.appendSlice(alloc, "</table>\n");
    }
    try b.appendSlice(alloc, "<h2>The log</h2>\n");
    if (try webbox.host_facts.logText(io, alloc)) |text| {
        try b.print(alloc, "<pre class=\"log\">{s}</pre>\n", .{try html.htmlEscape(alloc, text)});
    } else {
        try b.appendSlice(alloc, "<p class=\"muted\">This host keeps no log of its own to show here (on Linux, its stderr).</p>\n");
    }
    try b.appendSlice(alloc, "</body></html>\n");
    return respond(req, b.items);
}

/// The accounts and turns counted, and the turns' table.
fn turnsSection(b: *std.ArrayList(u8), alloc: Alloc, claimed: u8, turn: *const players.Turn, now_ms: u64) !void {
    try b.print(alloc, "<p>{d} of {d} accounts handed out; {d} of {d} turns held.</p>\n", .{ claimed, players.most_players, turn.len, players.most_playing });
    try b.appendSlice(alloc, "<h2>The turns</h2>\n");
    if (turn.len == 0) {
        try b.appendSlice(alloc, "<p class=\"muted\">Nobody is playing.</p>\n");
    } else {
        try b.appendSlice(alloc, "<table><tr><th>account</th><th>held for another</th></tr>");
        for (turn.holders[0..turn.len]) |h| {
            const left: u64 = if (h.until_ms > now_ms) h.until_ms - now_ms else 0;
            try b.print(alloc, "<tr><td>{d}</td><td>{d} s</td></tr>", .{ h.slot, (left + 999) / 1000 });
        }
        try b.appendSlice(alloc, "</table>\n");
    }
}

/// `GET /admin/game`: the accounts, the turns, and every game started.
pub fn game(req: *Request, io: Io, alloc: Alloc, v: View) !void {
    var b: std.ArrayList(u8) = .empty;
    try begin(&b, alloc, "🐕 The game", true);
    try turnsSection(&b, alloc, v.claimed, v.turn, v.now_ms);
    try b.appendSlice(alloc,
        \\<h2>The games</h2>
        \\<table><tr><th>account</th><th>level</th><th>last request</th><th>leash</th><th>kept tick</th><th>epoch</th><th>herd</th><th>poops</th><th>logs</th><th>findings</th></tr>
    );
    var started: usize = 0;
    for (v.games, 0..) |maybe, slot| {
        const g = maybe orelse continue;
        started += 1;
        const k = &g.kept;
        const leash: []const u8 = if (k.board.leashedDog()) |d| try std.fmt.allocPrint(alloc, "dog {d}", .{d}) else "none";
        const ago = if (v.last_ms[slot] == 0) "never" else try agoText(alloc, v.now_ms -| v.last_ms[slot]);
        var poops: usize = 0;
        for (k.board.poop_known) |p| poops += @intFromBool(p == .present);
        const logs = try logsText(io, alloc, g.dir);
        const f = g.findings;
        const findings = try std.fmt.allocPrint(alloc, "{d} overlaps, {d} idle drags, {d} unreadable, {d} trips{s}", .{
            f.overlaps, f.idle_drags, g.unreadable, g.trips, if (g.stuck) |t| try std.fmt.allocPrint(alloc, "; STUCK at {d}", .{t}) else "",
        });
        const herd = largestHerd(&k.board);
        const cows = presentCows(&k.board);
        try b.print(alloc, "<tr><td>{d}</td><td>{d} of {d}</td><td>{s}</td><td>{s}</td><td>{d}</td><td>{d}</td><td{s}>{d} of {d}</td><td>{d}</td><td>{s}</td><td{s}>{s}</td></tr>", .{
            slot,                                                            g.level(),                                   @max(g.unlocked, g.level()),
            ago,                                                             leash,                                       k.tick,
            g.epoch,                                                         if (won(&k.board)) " class=\"bad\"" else "", herd,
            cows,                                                            poops,                                       try html.htmlEscape(alloc, logs),
            if (f.overlaps > 0 or g.stuck != null) " class=\"bad\"" else "", try html.htmlEscape(alloc, findings),
        });
    }
    try b.appendSlice(alloc, "</table>\n");
    try b.print(alloc, "<p class=\"muted\">{d} games started this run (a game starts at its player's first load); the data: {s}. A herd of all its level's cows is a win.</p>\n", .{ started, try html.htmlEscape(alloc, v.data_dir) });
    try b.appendSlice(alloc, "</body></html>\n");
    return respond(req, b.items);
}

fn agoText(alloc: Alloc, ms: u64) ![]const u8 {
    const s = ms / 1000;
    if (s < 120) return std.fmt.allocPrint(alloc, "{d} s ago", .{s});
    if (s < 7200) return std.fmt.allocPrint(alloc, "{d} min ago", .{s / 60});
    return std.fmt.allocPrint(alloc, "{d} h ago", .{s / 3600});
}

/// A game's logs: how many, and their bytes.
fn logsText(io: Io, alloc: Alloc, dir: []const u8) ![]const u8 {
    var n: usize = 0;
    var bytes: u64 = 0;
    for (try webbox.store.list(io, alloc, dir)) |e| {
        if (!std.mem.startsWith(u8, e.name, "log-")) continue;
        n += 1;
        const st = try webbox.store.stat(io, alloc, try std.fs.path.join(alloc, &.{ dir, e.name }));
        bytes += st.size;
    }
    return std.fmt.allocPrint(alloc, "{d} ({d} KB)", .{ n, bytes / 1000 });
}

/// **THE HERD** the page scores (scene.js's `largestHerd`): cows linked when
/// their centres are at most two cow-widths apart on the larger axis,
/// round the torus; the largest group's size.
pub fn largestHerd(b: *const physics.Board) usize {
    const n = physics.countOf(.cow);
    var parent: [n]usize = undefined;
    for (&parent, 0..) |*p, i| p.* = i;
    const link = physics.measureOf(physics.px(2 * physics.pxOf(.cow)));
    for (0..n) |i| {
        if (b.knownOf(.cow)[i] != .present) continue;
        for (i + 1..n) |j| {
            if (b.knownOf(.cow)[j] != .present) continue;
            if (physics.measure(b.geometry().delta(b.of(.cow)[i], b.of(.cow)[j])) <= link) parent[root(&parent, i)] = root(&parent, j);
        }
    }
    var sizes: [n]usize = @splat(0);
    var most: usize = 0;
    for (0..n) |i| {
        if (b.knownOf(.cow)[i] != .present) continue;
        const r = root(&parent, i);
        sizes[r] += 1;
        most = @max(most, sizes[r]);
    }
    return most;
}

/// The cows the board has: its level's.
pub fn presentCows(b: *const physics.Board) usize {
    var n: usize = 0;
    for (b.knownOf(.cow)) |k| n += @intFromBool(k == .present);
    return n;
}

/// **A WIN**: every cow the board's level lays out in one herd.
pub fn won(b: *const physics.Board) bool {
    const n = presentCows(b);
    return n > 0 and largestHerd(b) == n;
}

fn root(parent: []usize, i: usize) usize {
    var x = i;
    while (parent[x] != x) x = parent[x];
    return x;
}

test "the herd: cows within two cow-widths link, through others, round the torus; the largest group counts" {
    var b = physics.Board.laidOut();
    // As laid out, one cow a white tile: no two within 84 px.
    try std.testing.expectEqual(@as(usize, 1), largestHerd(&b));
    // A chain of three, each 80 px from the next, across the world's seam.
    const w = b.geometry().world;
    b.ofMut(.cow)[0] = .{ .x = physics.px(20), .y = physics.px(500) };
    b.ofMut(.cow)[1] = .{ .x = w - physics.px(60), .y = physics.px(500) };
    b.ofMut(.cow)[2] = .{ .x = w - physics.px(140), .y = physics.px(500) };
    try std.testing.expectEqual(@as(usize, 3), largestHerd(&b));
}

test "a win is every present cow in one herd: Level One's two, touching, round the torus; Level Two's eight" {
    var one = physics.Board.laidOutAt(0);
    try std.testing.expectEqual(@as(usize, 2), presentCows(&one));
    try std.testing.expect(!won(&one));
    const w = one.geometry().world;
    one.ofMut(.cow)[0] = .{ .x = physics.px(10), .y = physics.px(100) };
    one.ofMut(.cow)[1] = .{ .x = w - physics.px(10) - physics.px(physics.pxOf(.cow)), .y = physics.px(100) };
    try std.testing.expect(won(&one));
    var two = physics.Board.laidOut();
    try std.testing.expectEqual(@as(usize, physics.countOf(.cow)), presentCows(&two));
    try std.testing.expect(!won(&two));
}

test "the turns' section counts and lists only the turns held: one whose time ran out is neither, though the turn still lists it" {
    const a = std.testing.allocator;
    var t: players.Turn = .{};
    _ = t.ask(1, 1000);
    _ = t.ask(2, 1000 + players.turn_ms / 2);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(a);
    try turnsSection(&b, a, 2, &t, 1000 + players.turn_ms);
    const one_held = std.fmt.comptimePrint("1 of {d} turns held", .{players.most_playing});
    try std.testing.expect(std.mem.indexOf(u8, b.items, one_held) != null);
    try std.testing.expect(std.mem.indexOf(u8, b.items, "<td>2</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.items, "<td>1</td>") == null);

    b.clearRetainingCapacity();
    try turnsSection(&b, a, 2, &t, 1000 + 2 * players.turn_ms);
    try std.testing.expect(std.mem.indexOf(u8, b.items, "Nobody is playing.") != null);
}

test "a form's field; the key compared whole" {
    try std.testing.expectEqualStrings("abc", formField("key=abc", "key").?);
    try std.testing.expectEqualStrings("abc", formField("x=1&key=abc\r\n", "key").?);
    try std.testing.expectEqual(@as(?[]const u8, null), formField("keys=abc", "key"));
    try std.testing.expect(sameKey("abc", "abc"));
    try std.testing.expect(!sameKey("abc", "abd"));
    try std.testing.expect(!sameKey("abc", "abcd"));
}

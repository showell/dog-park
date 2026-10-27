//! **WHO MAY PLAY** (Steve, 2026-10-15, for the first deployment): at most
//! `most_players` devices get an account, first come, first served, each its
//! own game; at most `most_playing` play at once, each holding a turn while
//! it plays and for `turn_ms` after its last ticking report; the rest wait
//! for one (notes/dog-park-capacity.md sizes both).
//!
//! - **An account** is a slot number, 0 to `most_players - 1`, carried in a
//!   signed cookie (webbox's `signed_cookie`). The count of slots handed out
//!   is kept in the data dir (`players`), so a restart never hands out more.
//! - **The turn** is the server's alone, kept in memory: it is lost on a
//!   restart, which is no harm (the first request after takes it).

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const signed = webbox.signed;
const signed_cookie = webbox.signed_cookie;

/// The most devices that get an account (Steve, 2026-10-15: 80 for now).
pub const most_players = 80;
/// The most accounts playing at once (Steve: 5 for now; the capacity
/// study's 1 vCPU droplet carries about 20 at a typical hand's pace).
pub const most_playing = 5;

/// How long the turn stays with a player after its last request: about the
/// leash's let-go time, so a player resting with a dog leashed keeps it.
pub const turn_ms: u64 = 20_000;

pub const Slot = u8;

// ── accounts ────────────────────────────────────────────────────────────────

/// The file in the data dir holding how many slots are handed out.
pub const claimed_file = "players";

/// How many slots are handed out, as the file says: none when there is no
/// file; a file that doesn't read stops the start (never a silent zero,
/// which would hand the slots out again).
pub fn readClaimed(io: Io, alloc: std.mem.Allocator, data_dir: []const u8) !u8 {
    const path = try std.fs.path.join(alloc, &.{ data_dir, claimed_file });
    const text = (try webbox.store.readOrNull(io, alloc, path, .limited(64))) orelse return 0;
    return parseClaimed(text) orelse error.PlayersFileDoesNotRead;
}

pub fn parseClaimed(text: []const u8) ?u8 {
    const n = std.fmt.parseInt(u8, std.mem.trimEnd(u8, text, "\n"), 10) catch return null;
    if (n > most_players) return null;
    return n;
}

pub fn writeClaimed(io: Io, alloc: std.mem.Allocator, data_dir: []const u8, n: u8) !void {
    const path = try std.fs.path.join(alloc, &.{ data_dir, claimed_file });
    // A replace, never a write: on metal a write removes the old entry
    // before the new one is whole, so a stop between would lose the count
    // and hand the accounts out again.
    try webbox.store.replace(io, alloc, path, try std.fmt.allocPrint(alloc, "{d}\n", .{n}), .{});
}

/// What a device that asks to begin gets.
pub const Claim = union(enum) {
    /// It already had one (its cookie verified).
    has: Slot,
    /// A new one, the next in turn.
    new: Slot,
    /// Every slot is taken.
    full,
};

/// The claim for a device holding `has` (its verified slot, if any) when
/// `claimed` slots are handed out.
pub fn claim(has: ?Slot, claimed: u8) Claim {
    if (has) |s| return .{ .has = s };
    if (claimed >= most_players) return .full;
    return .{ .new = claimed };
}

// ── the cookie ──────────────────────────────────────────────────────────────

/// **THE COOKIE'S SECURITY IS NAMED, NEVER DEFAULTED.** `secure` (the
/// default host behind HTTPS) is `__Host-dogpark`, Secure; `insecure` is
/// for a plain-http development server on an address (no browser keeps a
/// Secure cookie from one), chosen only by `DOGPARK_INSECURE_COOKIE=yes`.
pub const CookieMode = enum { secure, insecure };

const kind: signed.Kind(Slot) = .{
    .label = "dogpark\n",
    .lifetime_secs = 365 * 24 * 3600,
    .skew_secs = 300,
    .parse = slotOf,
};

/// A cookie's id: the slot in decimal, in its one spelling (no sign, no
/// leading zero), below `most_players`. The kind's parser: a verified
/// cookie gives its `Slot`, never a string to read again.
fn slotOf(id: []const u8) ?Slot {
    if (id.len == 0 or id.len > 2 or (id.len > 1 and id[0] == '0')) return null;
    for (id) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u8, id, 10) catch return null;
    if (n >= most_players) return null;
    return n;
}

fn cookieOf(mode: CookieMode) signed_cookie.Cookie(Slot) {
    return .{ .name = switch (mode) {
        .secure => "__Host-dogpark",
        .insecure => "dogpark",
    }, .kind = kind };
}

/// The slot this request's cookie names, or null: none, not verifying, or
/// no secret to read it with.
pub fn slotOfRequest(mode: CookieMode, io: Io, alloc: std.mem.Allocator, req: *std.http.Server.Request, auth_dir: []const u8, now: i64) !?Slot {
    return switch (try signed_cookie.read(cookieOf(mode), io, alloc, req, auth_dir, now)) {
        .verified => |v| v.id,
        .none, .no_secret, .invalid => null,
    };
}

/// The Set-Cookie header for slot `s`, signed now.
pub fn cookieHeader(mode: CookieMode, io: Io, alloc: std.mem.Allocator, auth_dir: []const u8, s: Slot, now: i64) ![]const u8 {
    const c = cookieOf(mode);
    const secret = (try webbox.site_secret.load(io, alloc, auth_dir)) orelse return error.NoSiteSecret;
    var id_buf: [3]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{d}", .{s}) catch unreachable;
    const value = try signed.sign(alloc, c.kind, secret, id, now);
    return switch (mode) {
        .secure => signed_cookie.header(c, alloc, value),
        .insecure => std.fmt.allocPrint(alloc, "{s}={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Lax", .{ c.name, value, c.kind.lifetime_secs }),
    };
}

// ── the turn ────────────────────────────────────────────────────────────────

/// At most `most_playing` at once: each holder, and until when it holds
/// its turn.
pub const Turn = struct {
    holders: [most_playing]Holder = undefined,
    len: usize = 0,

    pub const Holder = struct {
        slot: Slot,
        until_ms: u64,

        /// Whether it holds its turn at `now_ms`. One whose time is up holds
        /// none, though it stays in `holders` until the next ask frees it.
        pub fn holds(h: Holder, now_ms: u64) bool {
            return now_ms < h.until_ms;
        }
    };

    /// The turns held at `now_ms`.
    pub fn held(t: *const Turn, now_ms: u64) usize {
        var n: usize = 0;
        for (t.holders[0..t.len]) |h| n += @intFromBool(h.holds(now_ms));
        return n;
    }

    pub const Asked = union(enum) {
        /// Slot `s` holds a turn now, until `turn_ms` from now.
        granted,
        /// Every turn is held: ask again in this many whole seconds (when
        /// the soonest frees).
        wait_s: u64,
    };

    /// Slot `s` asks for a turn at `now_ms`: a holder's renews; else the
    /// turns whose time is up are freed, and `s` takes one if any is free.
    /// A grant runs `turn_ms` from now.
    pub fn ask(t: *Turn, s: Slot, now_ms: u64) Asked {
        for (t.holders[0..t.len]) |*h| if (h.slot == s) {
            h.until_ms = now_ms + turn_ms;
            return .granted;
        };
        var kept: usize = 0;
        for (t.holders[0..t.len]) |h| if (h.holds(now_ms)) {
            t.holders[kept] = h;
            kept += 1;
        };
        t.len = kept;
        if (t.len < most_playing) {
            t.holders[t.len] = .{ .slot = s, .until_ms = now_ms + turn_ms };
            t.len += 1;
            return .granted;
        }
        var soonest: u64 = std.math.maxInt(u64);
        for (t.holders[0..t.len]) |h| soonest = @min(soonest, h.until_ms);
        return .{ .wait_s = (soonest - now_ms + 999) / 1000 };
    }
};

test "a turn whose time ran out is not held, though it is still listed" {
    var t: Turn = .{};
    _ = t.ask(1, 1000);
    _ = t.ask(2, 1000);
    try std.testing.expectEqual(@as(usize, 2), t.held(1000));
    try std.testing.expectEqual(@as(usize, 0), t.held(1000 + turn_ms));
    try std.testing.expectEqual(@as(usize, 2), t.len);
}

test "claim: a device with a slot keeps it; a new one takes the next; none past the most" {
    try std.testing.expectEqual(Claim{ .has = 3 }, claim(3, most_players));
    try std.testing.expectEqual(Claim{ .new = 0 }, claim(null, 0));
    try std.testing.expectEqual(Claim{ .new = most_players - 1 }, claim(null, most_players - 1));
    try std.testing.expectEqual(Claim.full, claim(null, most_players));
}

test "the players file: a count up to the most reads; anything else does not" {
    try std.testing.expectEqual(@as(?u8, 3), parseClaimed("3\n"));
    try std.testing.expectEqual(@as(?u8, 0), parseClaimed("0"));
    try std.testing.expectEqual(@as(?u8, most_players), parseClaimed(std.fmt.comptimePrint("{d}\n", .{most_players})));
    try std.testing.expectEqual(@as(?u8, null), parseClaimed(std.fmt.comptimePrint("{d}\n", .{most_players + 1})));
    try std.testing.expectEqual(@as(?u8, null), parseClaimed(""));
    try std.testing.expectEqual(@as(?u8, null), parseClaimed("two\n"));
}

test "a cookie id is a slot in decimal, in its one spelling, below the most" {
    try std.testing.expectEqual(@as(?Slot, 0), slotOf("0"));
    try std.testing.expectEqual(@as(?Slot, 4), slotOf("4"));
    try std.testing.expectEqual(@as(?Slot, 79), slotOf("79"));
    for ([_][]const u8{ "80", "", "00", "07", "a", "-1", "+1", "100", "1 " }) |id| try std.testing.expectEqual(@as(?Slot, null), slotOf(id));
}

test "the turns: up to most_playing at once, first come, first served; each held while used, freed turn_ms after its last request; a full house waits for the soonest" {
    var t: Turn = .{};
    for (0..most_playing) |i| try std.testing.expectEqual(Turn.Asked.granted, t.ask(@intCast(i), 1000 + i));
    // Every turn held: the next waits, told the whole seconds till the soonest frees (slot 0's).
    try std.testing.expectEqual(Turn.Asked{ .wait_s = 20 }, t.ask(10, 1000));
    try std.testing.expectEqual(Turn.Asked{ .wait_s = 11 }, t.ask(10, 10_000));
    // A holder's request renews its time; another holder's doesn't free.
    try std.testing.expectEqual(Turn.Asked.granted, t.ask(0, 15_000));
    try std.testing.expectEqual(Turn.Asked{ .wait_s = 1 }, t.ask(10, 20_500));
    // Slot 1's time up (21,001): the asker takes its turn.
    try std.testing.expectEqual(Turn.Asked.granted, t.ask(10, 21_001));
    try std.testing.expectEqual(Turn.Asked{ .wait_s = 1 }, t.ask(11, 21_001));
}

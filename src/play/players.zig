//! **WHO MAY PLAY** (Steve, 2026-10-15, for the first deployment): at most
//! `most_players` devices get an account, first come, first served, each its
//! own game; one plays at a time, holding the turn while it plays and for
//! `turn_ms` after its last request; the rest wait their turn.
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

/// The most devices that get an account.
pub const most_players = 5;

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
    try webbox.store.write(io, alloc, path, try std.fmt.allocPrint(alloc, "{d}\n", .{n}), .{});
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

const kind: signed.Kind = .{
    .label = "dogpark\n",
    .lifetime_secs = 365 * 24 * 3600,
    .skew_secs = 300,
    .validId = validSlot,
};

fn validSlot(id: []const u8) bool {
    return slotOf(id) != null;
}

fn slotOf(id: []const u8) ?Slot {
    if (id.len != 1 or id[0] < '0' or id[0] >= '0' + most_players) return null;
    return id[0] - '0';
}

fn cookieOf(mode: CookieMode) signed_cookie.Cookie {
    return .{ .name = switch (mode) {
        .secure => "__Host-dogpark",
        .insecure => "dogpark",
    }, .kind = kind };
}

/// The slot this request's cookie names, or null: none, not verifying, or
/// no secret to read it with.
pub fn slotOfRequest(mode: CookieMode, io: Io, alloc: std.mem.Allocator, req: *std.http.Server.Request, auth_dir: []const u8, now: i64) !?Slot {
    return switch (try signed_cookie.read(cookieOf(mode), io, alloc, req, auth_dir, now)) {
        .verified => |v| slotOf(v.id),
        .none, .no_secret, .invalid => null,
    };
}

/// The Set-Cookie header for slot `s`, signed now.
pub fn cookieHeader(mode: CookieMode, io: Io, alloc: std.mem.Allocator, auth_dir: []const u8, s: Slot, now: i64) ![]const u8 {
    const c = cookieOf(mode);
    const secret = (try webbox.site_secret.load(io, alloc, auth_dir)) orelse return error.NoSiteSecret;
    const value = try signed.sign(alloc, c.kind, secret, &.{'0' + s}, now);
    return switch (mode) {
        .secure => signed_cookie.header(c, alloc, value),
        .insecure => std.fmt.allocPrint(alloc, "{s}={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Lax", .{ c.name, value, c.kind.lifetime_secs }),
    };
}

// ── the turn ────────────────────────────────────────────────────────────────

/// One player at a time: the holder, and until when it holds the turn.
pub const Turn = struct {
    holder: ?Slot = null,
    until_ms: u64 = 0,

    pub const Asked = union(enum) {
        /// Slot `s` holds the turn now, until `turn_ms` from now.
        granted,
        /// Another holds it: ask again in this many whole seconds.
        wait_s: u64,
    };

    /// Slot `s` asks for the turn at `now_ms`: it is granted when nobody
    /// holds it, when `s` does, or when the holder's time is up; a grant
    /// runs `turn_ms` from now.
    pub fn ask(t: *Turn, s: Slot, now_ms: u64) Asked {
        if (t.holder) |h| if (h != s and now_ms < t.until_ms) return .{ .wait_s = (t.until_ms - now_ms + 999) / 1000 };
        t.holder = s;
        t.until_ms = now_ms + turn_ms;
        return .granted;
    }
};

test "claim: a device with a slot keeps it; a new one takes the next; none past the most" {
    try std.testing.expectEqual(Claim{ .has = 3 }, claim(3, most_players));
    try std.testing.expectEqual(Claim{ .new = 0 }, claim(null, 0));
    try std.testing.expectEqual(Claim{ .new = 4 }, claim(null, 4));
    try std.testing.expectEqual(Claim.full, claim(null, most_players));
}

test "the players file: a count up to the most reads; anything else does not" {
    try std.testing.expectEqual(@as(?u8, 3), parseClaimed("3\n"));
    try std.testing.expectEqual(@as(?u8, 0), parseClaimed("0"));
    try std.testing.expectEqual(@as(?u8, null), parseClaimed("6\n"));
    try std.testing.expectEqual(@as(?u8, null), parseClaimed(""));
    try std.testing.expectEqual(@as(?u8, null), parseClaimed("two\n"));
}

test "a cookie id is one digit naming a slot, and nothing else" {
    try std.testing.expectEqual(@as(?Slot, 0), slotOf("0"));
    try std.testing.expectEqual(@as(?Slot, 4), slotOf("4"));
    for ([_][]const u8{ "5", "", "00", "a", "-1" }) |id| try std.testing.expectEqual(@as(?Slot, null), slotOf(id));
}

test "the turn: first come, first served; held while used; free turn_ms after the last request" {
    var t: Turn = .{};
    try std.testing.expectEqual(Turn.Asked.granted, t.ask(1, 1000));
    // Another waits, told the whole seconds left.
    try std.testing.expectEqual(Turn.Asked{ .wait_s = 20 }, t.ask(2, 1000));
    try std.testing.expectEqual(Turn.Asked{ .wait_s = 11 }, t.ask(2, 10_000));
    // The holder's request renews its time.
    try std.testing.expectEqual(Turn.Asked.granted, t.ask(1, 15_000));
    try std.testing.expectEqual(Turn.Asked{ .wait_s = 1 }, t.ask(2, 34_999));
    // Its time up, the next asker takes it.
    try std.testing.expectEqual(Turn.Asked.granted, t.ask(2, 35_000));
    try std.testing.expectEqual(Turn.Asked{ .wait_s = 20 }, t.ask(1, 35_000));
}

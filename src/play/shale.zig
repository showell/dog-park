//! **THE OPERATOR'S SCRIPTS** (metal-vmm QUEUE 214): webbox's signed Shale
//! route (`script_route`), mounted for monitoring the games' logs from
//! outside. The admin key first, as every `/admin` page; then the signed
//! envelope, its sequence numbers and its log, all webbox's.
//!
//!   POST /admin/script   a signed `mode=background` script (202, its number)
//!                        or a signed `mode=kill`; an atomic one is refused
//!   GET  /admin/script   the background run going, or the one that ended
//!                        last, and what it printed
//!
//! **BACKGROUND ONLY.** A background run only reads, and is stepped a slice
//! at a time between requests (`between`), so play keeps the turn first.
//! An atomic run, which may write and holds the turn until it ends, is off:
//! Steve's one use for a write is removing a rogue user's files, inside a
//! game's folder, and the route's atomic mode cannot be held to a folder.
//!
//! **ITS KEY** is its own, never lynrummy's: `shale.conf` in the auth folder
//! (`public_key = <64 hex>`, `target = <host>`) beside `shale/sequence`, the
//! last number run (README, "Running a script"). With none, the route is
//! off (403 `no_key`).
//!
//! **ONLY WHERE A HOST STEPS IT**: the Linux host calls `between` from its
//! start; metal's kernel does not yet (metal-vmm QUEUE 211, the box's). A
//! background run is accepted only once `between` has been called, so on
//! metal it is refused (501 `no_background`) rather than left never run.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const script = webbox.script;
const script_route = webbox.script_route;

/// **THE ROUTE'S BUDGETS.** A background run holds no turn, so its budgets
/// bound its memory and its total work, not a request's wait: a slice ends
/// after each store call or 100,000 steps (`script_route.slice_steps`), and
/// each builtin's work is capped (`call_bytes`, `call_entries`). A full scan
/// of five games' hour of logs is about 125 MB: 256 MiB read in all, and the
/// steps for it (a step for 16 bytes scanned) with room for the script's own
/// work. The arena and the machine are Shale's defaults' halves at most.
pub const budgets: script.Budgets = .{
    .steps = 50_000_000,
    .arena_bytes = 8 * 1024 * 1024,
    .reads = 10_000,
    .read_bytes = 256 * 1024 * 1024,
    .changes = 0,
};

/// The most a request to the route reads of its body: a script at its
/// budget, and the envelope's lines.
pub const most_body: u64 = script.Budgets.default_source_bytes + script_route.header_bytes;

/// Whether a host has called `between`: only then is a background run
/// accepted (above).
var stepped: bool = false;

/// **ONE SLICE BETWEEN REQUESTS**, for the host (webbox's `Site.between`):
/// whether the run goes on.
pub fn between(io: Io, now: i64) bool {
    stepped = true;
    return script_route.sliceBackground(io, now);
}

/// What the route's reply holds: a status, or a refusal.
var reply_buf: [script.Budgets.default_output_bytes + 4096]u8 = undefined;
/// A background run prints into its own memory; this is never written.
var out_buf: [0]u8 = .{};

/// `POST /admin/script`, the admin key already checked.
pub fn post(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, long: std.mem.Allocator, data_root: []const u8, auth_root: []const u8, now: i64) !void {
    const body = (try http.readLimitedBody(req, alloc, most_body)) orelse return;
    // Atomic is off here (above): refused before anything is checked or
    // spent, its number left for a request that may run.
    if (script_route.parse(body)) |env| {
        if (env.mode == .atomic) return answer(req, .forbidden, "refused (atomic_off): Dog Park runs background scripts only (mode=background); not run\n");
    } else |_| {}
    const paths = try script_route.Paths.under(alloc, auth_root);
    var outcome = try script_route.handle(io, alloc, body, .{
        .paths = paths,
        .data_root = data_root,
        .budgets = budgets,
        .now = now,
        .out = &out_buf,
        .backing = if (stepped) long else null,
    });
    defer outcome.deinit();
    return answer(req, outcome.status(), written(struct {
        fn f(o: *const script_route.Outcome, w: *std.Io.Writer) std.Io.Writer.Error!void {
            return script_route.writeReply(o, w);
        }
    }.f, &outcome));
}

/// `GET /admin/script`, the admin key already checked.
pub fn status(req: *std.http.Server.Request) !void {
    return answer(req, .ok, written(struct {
        fn f(_: void, w: *std.Io.Writer) std.Io.Writer.Error!void {
            return script_route.writeBackgroundStatus(w);
        }
    }.f, {}));
}

/// The room kept at the end of the reply for saying it was cut.
const cut_note = "\n── cut here: the rest is past this reply's room ──\n";

/// **WHAT `write` WROTE, OR SAID TO BE CUT** (the box's cold review of 214:
/// a status past the reply's room was cut off and answered as if whole).
fn written(comptime write: anytype, arg: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(reply_buf[0 .. reply_buf.len - cut_note.len]);
    write(arg, &w) catch {
        const n = w.buffered().len;
        @memcpy(reply_buf[n..][0..cut_note.len], cut_note);
        return reply_buf[0 .. n + cut_note.len];
    };
    return w.buffered();
}

fn answer(req: *std.http.Server.Request, s: std.http.Status, text: []const u8) !void {
    try req.respond(text, .{ .status = s, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
}

test "a reply past its room says it was cut; one within it is whole (the box's cold review of 214)" {
    const long = written(struct {
        fn f(_: void, w: *std.Io.Writer) std.Io.Writer.Error!void {
            for (0..reply_buf.len) |_| try w.writeByte('x');
        }
    }.f, {});
    try std.testing.expect(std.mem.endsWith(u8, long, cut_note));
    try std.testing.expect(long.len <= reply_buf.len);
    const short = written(struct {
        fn f(_: void, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("finished\n");
        }
    }.f, {});
    try std.testing.expectEqualStrings("finished\n", short);
}

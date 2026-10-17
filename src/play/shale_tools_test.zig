//! **DOG PARK'S SHALE SCRIPTS, GOLDEN** (metal-vmm QUEUE 229, chunk 5): each
//! of `tools/shale/` (`accounts`, `games`, `trouble`) run on a data folder
//! shaped as the server writes it (physics_log.zig's own `framed` and
//! `writeSnapshot`), its output word for word. Every run is webbox's gate:
//! its VM held to its tree-walker. Before, only `node tools/test_shale.mjs`
//! against a scratch server checked them.

const std = @import("std");
const webbox = @import("webbox");
const script = webbox.script;
const plog = @import("physics_log.zig");
const physics = @import("physics.zig");
const judge = @import("physics_judge.zig");
const testing = std.testing;

/// The fixture's clock: 2026-10-14T00:00:00Z.
const now_s: i64 = 1791936000;
const now_ms: u64 = @as(u64, @intCast(now_s)) * 1000;
/// A log begun ten minutes ago, and one two hours ago, last written then.
const recent_ms = now_ms - 600_000;
const old_ms = now_ms - 7_200_000;

const Data = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn init(self: *Data) !void {
        self.tmp = testing.tmpDir(.{});
        self.threaded = std.Io.Threaded.init(testing.allocator, .{});
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena.allocator();
        self.root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &self.tmp.sub_path, "data" });
        const io = self.threaded.io();
        const d = self.tmp.dir;
        try d.createDirPath(io, "data/game-0/physics");
        try d.createDirPath(io, "data/game-1/physics");
        try d.writeFile(io, .{ .sub_path = "data/players", .data = "3\n" });
        // Game 0: a snapshot, a recent log with one of every finding, an
        // old one, and a stray file whose name is no log's.
        const kept: judge.Kept = .{ .tick = 1200, .board = physics.Board.laidOut() };
        const snap: plog.Snapshot = .{ .physics = 0x0102_0304, .started = recent_ms, .log_started = recent_ms, .log_offset = 0, .kept = kept };
        try d.writeFile(io, .{ .sub_path = "data/game-0/physics/snapshot", .data = try plog.writeSnapshot(a, &snap) });
        var log: std.ArrayList(u8) = .empty;
        for ([_]struct { plog.Kind, []const u8 }{
            .{ .report, "req 1 tick 10\n" },
            .{ .report, "req 2 tick 20\n" },
            .{ .finding, "req 5 through kept 40: 2 overlaps, 1 drags with no drag on\n" },
            .{ .finding, "req ? number 1 at kept 41\n" },
            .{ .finding, "req 6 differ at tick 44\n" },
            .{ .finding, "stuck at tick 44: the physics disagrees with itself\n" },
            .{ .finding, "refused, a request number used again: req 6\n" },
        }) |e| try log.appendSlice(a, try plog.framed(a, e[0], e[1]));
        const recent = try std.fmt.allocPrint(a, "data/game-0/physics/{s}", .{try plog.logName(a, recent_ms)});
        try d.writeFile(io, .{ .sub_path = recent, .data = log.items });
        const old = try std.fmt.allocPrint(a, "data/game-0/physics/{s}", .{try plog.logName(a, old_ms)});
        try d.writeFile(io, .{ .sub_path = old, .data = try plog.framed(a, .report, "req 0 tick 1\n") });
        // Written then, as the old log was: the hour's edge is its time.
        try d.setTimestamps(io, old, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, @intCast(old_ms)) * std.time.ns_per_ms } } });
        try d.writeFile(io, .{ .sub_path = "data/game-0/physics/log-x", .data = "not a log\n" });
        // Game 1: started, nothing kept yet.
        try d.writeFile(io, .{ .sub_path = "data/game-1/physics/log-" ++ std.fmt.comptimePrint("{d}", .{recent_ms + 1000}), .data = "" });
        try d.writeFile(io, .{ .sub_path = "data/README", .data = "not a game\n" });
    }

    fn deinit(self: *Data) void {
        self.arena.deinit();
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    /// `tools/shale/<name>.shale`, run on the data, finished; its output.
    fn run(self: *Data, name: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        const io = self.threaded.io();
        const src = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "tools/shale/{s}.shale", .{name}), a, .limited(64 * 1024));
        const out = try a.alloc(u8, 64 * 1024);
        var r = script.run(io, testing.allocator, self.root, src, .{}, now_s, out);
        defer r.deinit();
        if (r.stop) |s| {
            std.debug.print("{s}.shale stopped {d}:{d} {s}: {s}\n", .{ name, s.line, s.column, @tagName(s.class), s.message });
            return error.TestUnexpectedResult;
        }
        return a.dupe(u8, r.output);
    }
};

test "tools/shale/accounts.shale: the accounts against the 80, and the games started" {
    var d: Data = undefined;
    try d.init();
    defer d.deinit();
    try testing.expectEqualStrings(
        \\accounts 3 of 80, 77 left
        \\games started 2, accounts that never played 1
        \\
    , try d.run("accounts"));
}

test "tools/shale/accounts.shale: its MOST is players.zig's most_players" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const src = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), "tools/shale/accounts.shale", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(src);
    var want: [32]u8 = undefined;
    const line = try std.fmt.bufPrint(&want, "\nconst MOST = {d}\n", .{@import("players.zig").most_players});
    try testing.expect(std.mem.indexOf(u8, src, line) != null);
}

test "tools/shale/games.shale: each game's last kept tick, its newest log, and its logs" {
    var d: Data = undefined;
    try d.init();
    defer d.deinit();
    try testing.expectEqualStrings(
        \\2 games
        \\game    kept  last_log              last_log_size  logs  bytes
        \\game-0  1200  2026-10-13T23:50:00Z  378 B             2  411 B
        \\game-1  none  2026-10-13T23:50:01Z  0 B               1  0 B
        \\
    , try d.run("games"));
}

test "tools/shale/trouble.shale: each game's findings over the last hour, a stray file in its folder passed by" {
    var d: Data = undefined;
    try d.init();
    defer d.deinit();
    try testing.expectEqualStrings(
        \\2 games, the last hour
        \\game    logs  reports  differs  unreadable  overlaps  idle_drags  stuck  refused
        \\game-0     1        2        1           1         2           1      1        1
        \\game-1     1        0        0           0         0           0      0        0
        \\
    , try d.run("trouble"));
}

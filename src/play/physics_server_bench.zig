//! How long a 16-tick report's round trip through `POST /report` takes,
//! in process (ReleaseSafe, as the server runs): `zig build
//! physics-server-bench`. The play server set up on a temporary data dir,
//! a load, a leash in the park's middle, then 16 ticks of a drag through
//! the park written as the page writes them, routed as webbox's hosts
//! route a request: the parse, the judge's re-run, the log's append, the
//! answer. Each run starts from the same kept tick (the board put back), so
//! every run re-runs and logs all 16 ticks; about a second of runs.

const std = @import("std");
const webbox = @import("webbox");
const app = @import("app.zig");
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const Served = webbox.site.Site(app);

/// About a second of runs, and at least ten.
const budget_ns: i96 = std.time.ns_per_s;
const least_runs = 10;

fn post(io: std.Io, alloc: std.mem.Allocator, hub: *webbox.bus.Hub, body: []const u8) ![]const u8 {
    const raw = try std.fmt.allocPrint(alloc, "POST /report HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ try app.cookieFor(io, alloc, 0), body.len, body });
    var out: std.Io.Writer.Allocating = .init(alloc);
    var reader: std.Io.Reader = .fixed(raw);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    var b = webbox.bus.Bus.of(hub);
    _ = try Served.route(&req, io, alloc, &b);
    try out.writer.flush();
    const all = out.written();
    return all[std.mem.indexOf(u8, all, "\r\n\r\n").? + 4 ..];
}

fn line(list: *std.ArrayList(u8), alloc: std.mem.Allocator, l: wire.Line) !void {
    var buf: [2048]u8 = undefined;
    var w: wire.Text = .{ .buf = &buf };
    try wire.write(&w, l);
    try list.appendSlice(alloc, w.bytes());
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // A game's memory (notes/dog-park-capacity.md): the server state each
    // account's game holds, and the lines a tick writes.
    std.debug.print("a game's server state: {d} bytes; a tick's lines: {d} bytes\n", .{ @sizeOf(@import("physics_server.zig").Server), @sizeOf(physics.Lines) });
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.fmt.allocPrint(a, "/tmp/dogpark-server-bench-{d}", .{std.Io.Clock.real.now(io).nanoseconds});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = try app.setup(io, std.heap.page_allocator, .{ .data_dir = try std.fs.path.join(a, &.{ dir, "data" }), .auth_dir = try std.fs.path.join(a, &.{ dir, "auth" }) });
    var hub = webbox.bus.Hub.init(io, std.heap.page_allocator);
    const s = try app.game(io, 0);

    // The leash, kept, as a page's load and first request leave it.
    _ = try s.load(io, a, try std.fmt.allocPrint(a, "dogpark 1 physics {x:0>8} load 1920x1080\n", .{s.physics_hash}), .layout);
    const dog: u16 = 25;
    s.kept.board.hold = .{ .leashed = .{ .dog = dog, .drag = .on } };
    s.last = 1;
    // 16 ticks of a drag through the park, as the page writes them; the
    // view, every tile the region meets at some tick's start.
    var body: std.ArrayList(u8) = .empty;
    try line(&body, a, .{ .header = .{ .language = wire.language, .physics = s.physics_hash, .epoch = .{ .ms = s.started, .count = s.epoch }, .req = 2 } });
    try line(&body, a, .{ .from = .{ .tick = s.kept.tick, .wall = 1 } });
    var page = s.kept.board;
    var region: wire.TileSet = .{};
    var critter_lines: usize = 0;
    for (0..16) |i| {
        const span = physics.TileSpan.of(physics.region(page.dogs[dog]));
        var r = span.row_lo;
        while (r <= span.row_hi) : (r += 1) {
            var c = span.col_lo;
            while (c <= span.col_hi) : (c += 1) try region.add(physics.TileSpan.at(c, r));
        }
        const t = s.kept.tick + 1 + i;
        const drag = physics.mergeAndCap(&.{.{ .dx = physics.px(12), .dy = physics.px(3) }});
        var lines: physics.Lines = .{};
        if (physics.tick(&page, t, &.{}, drag.slice(), &lines) != null) return error.Refused;
        try line(&body, a, .{ .t = .{ .tick = t, .ms = 63 * i, .drag = drag } });
        for (lines.slice()) |c| {
            try line(&body, a, wire.checkedLine(t, c));
            if (c == .critter) critter_lines += 1;
        }
    }

    s.kept.view = .{ .w = 1920, .h = 1080, .tiles = region };
    s.kept.held = region;
    for (region.slice()) |t| {
        s.kept.sent.add(t);
        s.kept.named.add(t);
    }
    const kept = s.kept;
    const last = s.last;
    var total: i96 = 0;
    var answer: []const u8 = "";
    var runs: usize = 0;
    while (runs < least_runs or total < budget_ns) : (runs += 1) {
        s.kept = kept;
        s.last = last;
        const t0 = std.Io.Clock.awake.now(io).nanoseconds;
        answer = try post(io, a, &hub, body.items);
        total += std.Io.Clock.awake.now(io).nanoseconds - t0;
    }
    const us = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(runs)) / 1000.0;
    std.debug.print("a 16-tick report ({d} bytes, {d} critter lines) through POST /report, judged, logged, answered: {d:.1} us (mean of {d}); its answer: {s}", .{ body.items.len, critter_lines, us, runs, answer });
}

//! How long a tick takes natively: `zig build physics-bench` (ReleaseSafe).
//! - **the park's busiest spot:** the laid-out park, the leashed dog the one
//!   with the most critters seen around it, dragged the cap's 100 px on
//!   both axes (200 pixel-ticks, a walk after each);
//! - **a packed herd:** a tick with the full drag;
//! - **the busiest spot strewn with poop:** the same, with `strewn_poops`
//!   poops on free spots of the region (metal-vmm QUEUE 207: every blocked
//!   step scans every poop in view);
//! - **a server's re-run** of a 8-tick report from the busiest spot.
//! Each is the mean of as many runs from the same board as fit in about a
//! second (at least ten), so a retune that makes a tick dearer doesn't
//! make the bench crawl.

const std = @import("std");
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const judge = @import("physics_judge.zig");
const Board = physics.Board;
const Point = physics.Point;

fn px(x: i32, y: i32) Point {
    return .{ .x = physics.px(x), .y = physics.px(y) };
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn awakeCount(b: *Board) usize {
    const sc = physics.Scene.of(b) orelse return 0;
    return sc.len;
}

/// About a second of runs, and at least ten.
const budget_ns: i96 = std.time.ns_per_s;
const least_runs = 10;

/// The mean microseconds of one tick from `start`.
fn timeTick(io: std.Io, start: *const Board, humans: []const physics.Human, drag: []const physics.Disp) f64 {
    var lines: physics.Lines = .{};
    var sink: usize = 0;
    var runs: usize = 0;
    const t0 = nowNs(io);
    while (runs < least_runs or nowNs(io) - t0 < budget_ns) : (runs += 1) {
        var b = start.*;
        _ = physics.tick(&b, 1, humans, drag, &lines);
        sink +%= lines.len;
    }
    const t1 = nowNs(io);
    std.mem.doNotOptimizeAway(sink);
    return @as(f64, @floatFromInt(t1 - t0)) / @as(f64, @floatFromInt(runs)) / 1000.0;
}

const Herd = struct { board: Board, dogs: u16, cows: u16 };

/// A packed herd: dogs on a 45 px grid around the leashed dog, the cows
/// in columns beside them, every one within 500 px.
fn packedHerd() Herd {
    var herd = Board.empty();
    const c0 = 16000;
    herd.place(.of(.dog, 0), px(c0, c0));
    herd.hold = .{ .leashed = .{ .dog = 0, .drag = .on } };
    var n: u16 = 1;
    var gy: i32 = -7;
    outer: while (gy <= 7) : (gy += 1) {
        var gx: i32 = -7;
        while (gx <= 7) : (gx += 1) {
            if (@max(@abs(gx), @abs(gy)) <= 1) continue;
            if (n == physics.countOf(.dog)) break :outer;
            herd.place(.of(.dog, n), px(c0 + 45 * gx, c0 + 45 * gy));
            n += 1;
        }
    }
    var cow: u16 = 0;
    for ([_]i32{ -440, -375, 375, 440 }) |x| {
        var y: i32 = -330;
        while (y <= 330 and cow < physics.countOf(.cow)) : (y += 64) {
            herd.place(.of(.cow, cow), px(c0 + x, c0 + y));
            cow += 1;
        }
    }
    return .{ .board = herd, .dogs = n, .cows = cow };
}

const Busiest = struct { board: Board, dog: u16, awake: usize };

/// The laid-out park, the leashed dog the one with the most critters awake
/// around it.
fn busiestSpot() Busiest {
    var park = Board.laidOut();
    var busiest: u16 = 0;
    var most: usize = 0;
    for (0..physics.countOf(.dog)) |i| {
        park.hold = .{ .leashed = .{ .dog = @intCast(i), .drag = .on } };
        const n = awakeCount(&park);
        if (n > most) {
            most = n;
            busiest = @intCast(i);
        }
    }
    park.hold = .{ .leashed = .{ .dog = busiest, .drag = .on } };
    return .{ .board = park, .dog = busiest, .awake = most };
}

/// How many poops the strewn spot has, about what a long session's trails
/// leave in one region.
const strewn_poops = 500;

/// The busiest spot, with `strewn_poops` poops in the region, on a 100 px
/// grid's free spots (wide enough for a cow to pass between) outward from the leashed dog (none on a critter or
/// another poop), all ripe but the last.
fn strewnSpot(spot: Busiest) Board {
    var b = spot.board;
    const sc = physics.Scene.of(&b).?;
    const at = b.of(.dog)[spot.dog];
    var n: u16 = 0;
    var ring: i32 = 1;
    while (n < strewn_poops and ring < 30) : (ring += 1) {
        var gy: i32 = -ring;
        while (gy <= ring) : (gy += 1) {
            var gx: i32 = -ring;
            while (gx <= ring) : (gx += 1) {
                if (@max(@abs(gx), @abs(gy)) != ring or n == strewn_poops) continue;
                const q = physics.wrapped(.{ .x = at.x + physics.px(100 * gx), .y = at.y + physics.px(100 * gy) });
                if (!free(&sc, &b, q, n)) continue;
                b.poops[n] = q;
                b.poop_known[n] = .present;
                n += 1;
            }
        }
    }
    b.laid = n;
    return b;
}

fn free(sc: *const physics.Scene, b: *const Board, q: Point, n: u16) bool {
    for (sc.list(), 0..) |o, j| if (physics.squaresOverlap(q, physics.poop_half, sc.pos(j), o.half)) return false;
    for (b.poops[0..n]) |p| if (physics.squaresOverlap(q, physics.poop_half, p, physics.poop_half)) return false;
    return true;
}

fn poopsSeen(b: *Board) usize {
    const sc = physics.Scene.of(b) orelse return 0;
    return sc.poop_listed.count();
}

/// The report's ticks: the page sends a report at its byte budget, and a
/// tick here moves many critters, so 32 would pass the 64 KiB body.
const report_ticks = 8;

/// A `report_ticks`-tick report from the busiest spot, as the page would send it, and
/// the server's kept state before it.
fn busiestReport(spot: Busiest, w: *wire.Text) !judge.Kept {
    const busiest = spot.dog;
    var page = spot.board;
    var lines: physics.Lines = .{};
    try wire.write(w, .{ .header = .{ .language = 1, .physics = 1, .epoch = .{ .ms = 1, .count = 1 }, .req = 1 } });
    try wire.write(w, .{ .from = .{ .tick = 0, .wall = 0 } });
    // The view: every tile the region meets at some tick's start.
    var view: wire.TileSet = .{};
    var t: physics.Tick = 1;
    while (t <= report_ticks) : (t += 1) {
        const span = physics.TileSpan.of(physics.region(page.of(.dog)[busiest]));
        var r = span.row_lo;
        while (r <= span.row_hi) : (r += 1) {
            var c = span.col_lo;
            while (c <= span.col_hi) : (c += 1) try view.add(physics.TileSpan.at(c, r));
        }
        const drag = physics.mergeAndCap(&.{.{ .dx = physics.px(20), .dy = physics.px(if (t % 8 < 4) 10 else -10) }});
        const humans: []const physics.Human = if (page.hold.leashed.drag != .on) &.{.grab} else &.{};
        for (humans) |h| try wire.write(w, switch (h) {
            .grab => .{ .grab = t },
            else => unreachable,
        });
        _ = physics.tick(&page, t, humans, drag.slice(), &lines);
        try wire.write(w, .{ .t = .{ .tick = t, .ms = 0, .drag = drag } });
        for (lines.slice()) |c| try wire.write(w, wire.checkedLine(t, c));
    }
    var kept: judge.Kept = .{ .tick = 0, .board = spot.board };
    kept.board.hold = .none;
    kept.pending[0] = .{ .leash = busiest };
    kept.pending_len = 1;
    kept.view.tiles = view;
    kept.held = view;
    return kept;
}

/// The board moved by `by` tiles on both axes, round the torus: the park
/// across the world's seam.
fn shifted(b: Board, by: i32) Board {
    var out = b;
    const d = by * physics.tile;
    for (&out.points) |*p| p.* = physics.wrapped(.{ .x = p.x + d, .y = p.y + d });
    for (&out.poops) |*p| p.* = physics.wrapped(.{ .x = p.x + d, .y = p.y + d });
    return out;
}

/// **EVERY LINE OF MANY TICKS**, for a diff (`uneven`, in 256ths, is added
/// to the strewn drag's steps: 0 for `lines`, a remainder for `judge`):
/// - each dog of the laid-out park leashed in turn, one full drag, on the
///   park as laid out and on the park moved across the world's seam;
/// - the busiest spot strewn with poop, 96 ticks of a drag that turns,
///   each tick from the last (poops laid, eaten, slots reused);
/// - the packed herd's full drag; the busiest spot's 8-tick report.
fn printLines(io: std.Io, full: physics.Capped, uneven: i32) !void {
    var buf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &buf);
    const out = &ow.interface;
    var text_buf: [1 << 16]u8 = undefined;
    var lines: physics.Lines = .{};
    const tickLines = struct {
        fn f(o: *std.Io.Writer, tb: []u8, ls: *const physics.Lines, t: physics.Tick) !void {
            var w: wire.Text = .{ .buf = tb };
            for (ls.slice()) |c| try wire.write(&w, wire.checkedLine(t, c));
            try o.writeAll(w.bytes());
        }
    }.f;
    for ([_]i32{ 0, tiles_from_middle }) |by| {
        const park = shifted(Board.laidOut(), by);
        for (0..physics.countOf(.dog)) |i| {
            var b = park;
            b.hold = .{ .leashed = .{ .dog = @intCast(i), .drag = .on } };
            _ = physics.tick(&b, 1, &.{}, full.slice(), &lines);
            try out.print("== park +{d} tiles, dog {d}\n", .{ by, i });
            try tickLines(out, &text_buf, &lines, 1);
        }
    }
    const spot = busiestSpot();
    var strewn = strewnSpot(spot);
    var t: physics.Tick = 1;
    while (t <= 96) : (t += 1) {
        const turn: i32 = @intCast(t % 12);
        const drag = physics.mergeAndCap(&.{.{ .dx = physics.px(10 * (turn - 6)) + uneven, .dy = physics.px(if (t % 24 < 12) 40 else -40) - uneven }});
        const humans: []const physics.Human = if (strewn.hold == .leashed and strewn.hold.leashed.drag != .on) &.{.grab} else &.{};
        if (strewn.hold == .none) strewn.hold = .{ .leashed = .{ .dog = spot.dog, .drag = .on } };
        _ = physics.tick(&strewn, t, humans, drag.slice(), &lines);
        try out.print("== strewn tick {d}\n", .{t});
        try tickLines(out, &text_buf, &lines, t);
    }
    var herd = packedHerd();
    _ = physics.tick(&herd.board, 1, &.{}, full.slice(), &lines);
    try out.print("== herd\n", .{});
    try tickLines(out, &text_buf, &lines, 1);
    var report: [65536]u8 = undefined;
    var w: wire.Text = .{ .buf = &report };
    _ = try busiestReport(spot, &w);
    try out.print("== report\n{s}", .{w.bytes()});
    try out.flush();
}

/// The park's middle is this many tiles from the world's origin.
const tiles_from_middle = @divExact(@import("tiles.zig").world_tiles, 2);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const full = physics.mergeAndCap(&.{.{ .dx = physics.cap, .dy = physics.cap }});
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // **FOR THE WALK'S JUDGE** (`-- judge`, `zig build walk-judge`): the
    // `lines` workload, then again under a drag of uneven length, so each
    // pixel-tick's step has a remainder and critters stand between pixels:
    // the leashed dog then sweeps part of a step and slides the rest, which
    // whole-pixel drags never do.
    if (args.len > 1 and std.mem.eql(u8, args[1], "judge")) {
        try printLines(io, full, 0);
        const uneven = physics.mergeAndCap(&.{.{ .dx = physics.cap - 77, .dy = -(physics.cap - 133) }});
        return printLines(io, uneven, 77);
    }
    // **FOR A PROFILER** (`-- herd`): the packed herd's full drag, 20 runs,
    // nothing else, so a profile is that tick's.
    if (args.len > 1 and std.mem.eql(u8, args[1], "herd")) {
        const herd = packedHerd();
        var lines: physics.Lines = .{};
        var sink: usize = 0;
        for (0..20) |_| {
            var b = herd.board;
            _ = physics.tick(&b, 1, &.{}, full.slice(), &lines);
            sink +%= lines.len;
        }
        std.mem.doNotOptimizeAway(sink);
        return;
    }
    // `-- busiest`: the busiest spot's full drag, 20 runs; `-- rerun`: the
    // server's re-run of its 8-tick report, 20 runs.
    if (args.len > 1 and std.mem.eql(u8, args[1], "busiest")) {
        const spot = busiestSpot();
        var lines: physics.Lines = .{};
        var sink: usize = 0;
        for (0..20) |_| {
            var b = spot.board;
            _ = physics.tick(&b, 1, &.{}, full.slice(), &lines);
            sink +%= lines.len;
        }
        std.mem.doNotOptimizeAway(sink);
        return;
    }
    // `-- strewn`: the busiest spot strewn with poop, its full drag, 20 runs.
    if (args.len > 1 and std.mem.eql(u8, args[1], "strewn")) {
        const strewn = strewnSpot(busiestSpot());
        var lines: physics.Lines = .{};
        var sink: usize = 0;
        for (0..20) |_| {
            var b = strewn;
            _ = physics.tick(&b, 1, &.{}, full.slice(), &lines);
            sink +%= lines.len;
        }
        std.mem.doNotOptimizeAway(sink);
        return;
    }
    // `-- lines`: every line of many ticks, in the wire's text, for a
    // before-and-after diff of a change that must not change what the
    // physics does (metal-vmm QUEUE 210).
    if (args.len > 1 and std.mem.eql(u8, args[1], "lines")) return printLines(io, full, 0);
    if (args.len > 1 and std.mem.eql(u8, args[1], "rerun")) {
        var report: [65536]u8 = undefined;
        var w: wire.Text = .{ .buf = &report };
        const kept = try busiestReport(busiestSpot(), &w);
        var answer: [65536]u8 = undefined;
        var findings: judge.Findings = .{};
        for (0..20) |_| {
            var k = kept;
            var out: wire.Text = .{ .buf = &answer };
            if (try judge.judge(&k, 1, w.bytes(), &out, &findings) != .kept) return error.NotKept;
        }
        return;
    }

    // The park's busiest spot.
    const spot = busiestSpot();
    const park = spot.board;
    const busiest = spot.dog;
    const most = spot.awake;
    var lines: physics.Lines = .{};
    var probe = park;
    _ = physics.tick(&probe, 1, &.{}, full.slice(), &lines);
    std.debug.print("park's busiest spot: dog {d}, {d} seen (itself included), the full drag: {d} lines, {d:.1} us a tick\n", .{ busiest, most, lines.len, timeTick(io, &park, &.{}, full.slice()) });

    var strewn = strewnSpot(spot);
    const east = physics.mergeAndCap(&.{.{ .dx = physics.cap, .dy = 0 }});
    probe = strewn;
    _ = physics.tick(&probe, 1, &.{}, full.slice(), &lines);
    std.debug.print("the busiest spot strewn with {d} poops in view: the full drag (the leashed dog {d} px, {s}): {d} lines, {d:.1} us a tick; 100 px east, {d:.1} us\n", .{ poopsSeen(&strewn), @divTrunc(physics.measure(physics.delta(strewn.of(.dog)[busiest], probe.of(.dog)[busiest])), physics.unit), if (probe.hold.leashed.drag == .on) "no bump" else "bumped", lines.len, timeTick(io, &strewn, &.{}, full.slice()), timeTick(io, &strewn, &.{}, east.slice()) });
    probe = park;
    std.debug.print("the busiest spot, no poop, 100 px east: {d:.1} us a tick\n", .{timeTick(io, &probe, &.{}, east.slice())});

    var herd = packedHerd();
    std.debug.print("a packed herd: {d} dogs and {d} cows placed, {d} seen: the full drag {d:.1} us a tick\n", .{ herd.dogs, herd.cows, awakeCount(&herd.board), timeTick(io, &herd.board, &.{}, full.slice()) });

    // A 8-tick report from the busiest spot, re-run by the server.
    var report: [65536]u8 = undefined;
    var w: wire.Text = .{ .buf = &report };
    const kept = try busiestReport(spot, &w);
    var answer: [65536]u8 = undefined;
    var findings: judge.Findings = .{};
    var runs: usize = 0;
    const t0 = nowNs(io);
    var verdict: judge.Verdict = undefined;
    while (runs < least_runs or nowNs(io) - t0 < budget_ns) : (runs += 1) {
        var k = kept;
        var out: wire.Text = .{ .buf = &answer };
        verdict = try judge.judge(&k, 1, w.bytes(), &out, &findings);
    }
    const t1 = nowNs(io);
    var check = kept;
    var out: wire.Text = .{ .buf = &answer };
    _ = try judge.judge(&check, 1, w.bytes(), &out, &findings);
    std.debug.print("a server's re-run of a 8-tick report ({d} bytes) from the busiest spot: {s}, {d:.1} us\n", .{ w.len, std.mem.trimEnd(u8, out.bytes(), "\n"), @as(f64, @floatFromInt(t1 - t0)) / @as(f64, @floatFromInt(runs)) / 1000.0 });
    if (verdict != .kept) return error.NotKept;
}

//! How long a tick takes natively: `zig build physics-bench` (ReleaseSafe).
//! - **the park's busiest spot:** the laid-out park, the leashed dog the one
//!   with the most critters awake around it, dragged the cap's 100 px on
//!   both axes (20 internal steps, every awake cow reacting to each);
//! - **a packed herd:** every critter awake around the leashed dog, a tick
//!   of wishes alone and a tick with the full drag;
//! - **a server's re-run** of a 32-tick report from the busiest spot.
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
    var n: usize = 0;
    const sc = physics.Scene.of(b) orelse return 0;
    for (sc.list()) |s| if (s.awake == .awake) {
        n += 1;
    };
    return n;
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const full = physics.mergeAndCap(&.{.{ .dx = physics.cap, .dy = physics.cap }});

    // The park's busiest spot.
    var park = Board.laidOut();
    var busiest: u16 = 0;
    var most: usize = 0;
    for (0..physics.dog_count) |i| {
        park.hold = .{ .leashed = .{ .dog = @intCast(i), .drag = .on } };
        const n = awakeCount(&park);
        if (n > most) {
            most = n;
            busiest = @intCast(i);
        }
    }
    park.hold = .{ .leashed = .{ .dog = busiest, .drag = .on } };
    var lines: physics.Lines = .{};
    var probe = park;
    _ = physics.tick(&probe, 1, &.{}, full.slice(), &lines);
    std.debug.print("park's busiest spot: dog {d}, {d} awake (itself included), the full drag: {d} lines, {d:.1} us a tick\n", .{ busiest, most, lines.len, timeTick(io, &park, &.{}, full.slice()) });
    std.debug.print("  the same, no drag (wishes alone): {d:.1} us a tick\n", .{timeTick(io, &park, &.{}, &.{})});

    // A packed herd: dogs on a 45 px grid around the leashed dog, the cows
    // in columns beside them, every one within 500 px.
    var herd = Board.empty();
    const c0 = 16000;
    herd.place(.dog(0), px(c0, c0));
    herd.hold = .{ .leashed = .{ .dog = 0, .drag = .on } };
    var n: u16 = 1;
    var gy: i32 = -7;
    outer: while (gy <= 7) : (gy += 1) {
        var gx: i32 = -7;
        while (gx <= 7) : (gx += 1) {
            if (@max(@abs(gx), @abs(gy)) <= 1) continue;
            if (n == physics.dog_count) break :outer;
            herd.place(.dog(n), px(c0 + 45 * gx, c0 + 45 * gy));
            n += 1;
        }
    }
    var cow: u16 = 0;
    for ([_]i32{ -440, -375, 375, 440 }) |x| {
        var y: i32 = -330;
        while (y <= 330 and cow < physics.cow_count) : (y += 64) {
            herd.place(.cow(cow), px(c0 + x, c0 + y));
            cow += 1;
        }
    }
    std.debug.print("a packed herd: {d} dogs and {d} cows placed, {d} awake: wishes alone {d:.1} us, the full drag {d:.1} us a tick\n", .{ n, cow, awakeCount(&herd), timeTick(io, &herd, &.{}, &.{}), timeTick(io, &herd, &.{}, full.slice()) });

    // A 32-tick report from the busiest spot, re-run by the server.
    var page = park;
    var report: [65536]u8 = undefined;
    var w: wire.Text = .{ .buf = &report };
    try wire.write(&w, .{ .header = .{ .language = 1, .physics = 1, .epoch = .{ .ms = 1, .count = 1 }, .req = 1 } });
    try wire.write(&w, .{ .from = .{ .tick = 0, .wall = 0 } });
    // The view: every tile the region meets at some tick's start.
    var view: wire.TileSet = .{};
    var t: physics.Tick = 1;
    while (t <= physics.most_ticks) : (t += 1) {
        const span = physics.TileSpan.of(physics.region(page.dogs[busiest]));
        var r = span.row_lo;
        while (r <= span.row_hi) : (r += 1) {
            var c = span.col_lo;
            while (c <= span.col_hi) : (c += 1) try view.add(physics.TileSpan.at(c, r));
        }
        const drag = physics.mergeAndCap(&.{.{ .dx = physics.px(20), .dy = physics.px(if (t % 8 < 4) 10 else -10) }});
        const humans: []const physics.Human = if (page.hold.leashed.drag != .on) &.{.grab} else &.{};
        for (humans) |h| try wire.write(&w, switch (h) {
            .grab => .{ .grab = t },
            else => unreachable,
        });
        _ = physics.tick(&page, t, humans, drag.slice(), &lines);
        try wire.write(&w, .{ .t = .{ .tick = t, .ms = 0, .drag = drag } });
        for (lines.slice()) |c| try wire.write(&w, wire.checkedLine(t, c));
    }
    var kept: judge.Kept = .{ .tick = 0, .board = park };
    kept.board.hold = .none;
    kept.pending[0] = .{ .leash = busiest };
    kept.pending_len = 1;
    kept.view.tiles = view;
    kept.held = view;
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
    std.debug.print("a server's re-run of a 32-tick report ({d} bytes) from the busiest spot: {s}, {d:.1} us\n", .{ w.len, std.mem.trimEnd(u8, out.bytes(), "\n"), @as(f64, @floatFromInt(t1 - t0)) / @as(f64, @floatFromInt(runs)) / 1000.0 });
    if (verdict != .kept) return error.NotKept;
}

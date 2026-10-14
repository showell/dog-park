//! **THE HERD NUMBERS ON FIXED PLAY** (metal-vmm QUEUE 205(a)): `zig build
//! herds` (with `-Dmetric`, `-Dknobs`). A few recorded drags, the same for
//! every variant of the rules, each played from the laid-out park, and the
//! herds' census (herds.zig) at the let-go and after it, so a rule change
//! is judged on the same play every time. Steve's eye stays the judge.
//!
//! Every script leashes dog 220 (breed 0, in the park's middle tile) and
//! drags it with one displacement a tick, whole pixels: a human's slow
//! walk is 6 px a tick (96 px a second). A bump ends the drag (the leashed
//! dog pressed into someone who did not get out of the way); the script
//! grabs again the next tick, as a human does, and says how far the dog
//! went of what was asked.
//! - `line`: east 1,200 px over 12.5 s, let go.
//! - `stroll`: the same line at half the pace, 3 px a tick, over 25 s.
//! - `swing`: east 600 px, north 600 px, west 600 px (a U-turn back past
//!   its own herd), let go.
//! - `through`: south-east 1,500 px on the diagonal across the other
//!   breeds' corners, let go.
//! - `still`: leashed and held 30 s without a move, let go: herds that
//!   form here formed on their own, not behind a drag.
//! - `passed`: `through`, then dog 220 released and the nearest breed-2
//!   dog led back up the diagonal past the herd for 600 px each way, let
//!   go: does the first herd hold while another is led past it?
//!
//! **THE CENSUS AT THREE TIMES:** the let-go, 10 s after it, and 30 s after
//! (the leash lets go `let_go_ticks` after the drag ends, 20 s as played,
//! and with no dog leashed nothing moves, so 30 s is the board as the
//! release left it).
//!
//! **ITS COLUMNS**, for each time:
//! - `herds` the herds of 3 or more, all breeds; `in` the dogs in them;
//! - `b0..b3` each breed's herds;
//! - `lead` the herd dog 220 is in: its size, length (hops end to end)
//!   and links a dog (2 a chain, 4 or more a clump);
//! - `kept` what share of the let-go's herds the later census keeps
//!   (herds.zig's `kept`);
//! - `big b0..b3` each breed's largest herd, size/length;
//! - all of them by the rules' yardstick (the metric's band), then `eye`
//!   (the dogs in herds), `lead`, `len` and `kept` by the straight line,
//!   one ruler for every metric.

const std = @import("std");
const physics = @import("physics.zig");
const herds = @import("herds.zig");
const Board = physics.Board;

const leashed: u16 = 220;
const secs = physics.ticks_per_second;

const Leg = struct { ticks: u32, dx: i32, dy: i32 };

const Script = struct {
    name: []const u8,
    legs: []const Leg,
    /// After the let-go: release dog 220 at once and lead the nearest dog
    /// of `breed` along `legs`, so the first herd is judged by whether it
    /// holds while another passes it (`kept` at +10 s and +30 s).
    then: ?Then = null,
};

const Then = struct { breed: u8, legs: []const Leg };

const scripts = [_]Script{
    .{ .name = "line", .legs = &.{.{ .ticks = 200, .dx = 6, .dy = 0 }} },
    .{ .name = "stroll", .legs = &.{.{ .ticks = 400, .dx = 3, .dy = 0 }} },
    .{ .name = "swing", .legs = &.{ .{ .ticks = 100, .dx = 6, .dy = 0 }, .{ .ticks = 100, .dx = 0, .dy = -6 }, .{ .ticks = 100, .dx = -6, .dy = 0 } } },
    .{ .name = "through", .legs = &.{.{ .ticks = 250, .dx = 6, .dy = 6 }} },
    .{ .name = "still", .legs = &.{.{ .ticks = 30 * secs, .dx = 0, .dy = 0 }} },
    .{ .name = "passed", .legs = &.{.{ .ticks = 250, .dx = 6, .dy = 6 }}, .then = .{ .breed = 2, .legs = &.{.{ .ticks = 100, .dx = -6, .dy = -6 }} } },
};

/// A census by each yardstick.
const Both = struct {
    rules: herds.Census,
    eye: herds.Census,

    fn of(b: *const Board) Both {
        return .{ .rules = herds.census(b, .rules), .eye = herds.census(b, .eye) };
    }
};

const Played = struct {
    at_letgo: Both,
    after_10: Both,
    after_30: Both,
    /// The drag's bumps (each ends the drag; the script grabs again the
    /// next tick, as a human does), and how far the leashed dog went in
    /// all, in px, against the script's own sum.
    bumps: u32 = 0,
    went: i64 = 0,
    asked: i64 = 0,
};

/// One tick; whether it bumped.
fn step(b: *Board, t: physics.Tick, humans: []const physics.Human, drag: []const physics.Disp) bool {
    var lines: physics.Lines = .{};
    if (physics.tick(b, t, humans, drag, &lines)) |r| std.debug.panic("refused: {t}", .{r});
    for (lines.slice()) |l| if (l == .bump) return true;
    return false;
}

fn play(s: Script) Played {
    var b = Board.laidOut();
    var p: Played = .{ .at_letgo = undefined, .after_10 = undefined, .after_30 = undefined };
    var t: physics.Tick = 1;
    _ = step(&b, t, &.{.{ .leash = leashed }}, &.{});
    var regrab = false;
    for (s.legs) |leg| {
        for (0..leg.ticks) |_| {
            t += 1;
            const d: physics.Disp = .{ .dx = physics.px(leg.dx), .dy = physics.px(leg.dy) };
            const before = b.dogs[leashed];
            const humans: []const physics.Human = if (regrab) &.{.grab} else &.{};
            regrab = step(&b, t, humans, if (leg.dx == 0 and leg.dy == 0) &.{} else &.{d});
            if (regrab) p.bumps += 1;
            const v = physics.delta(before, b.dogs[leashed]);
            p.went += @abs(v.x) + @abs(v.y);
            p.asked += @abs(physics.px(leg.dx)) + @abs(physics.px(leg.dy));
        }
    }
    p.went = @divTrunc(p.went, physics.unit);
    p.asked = @divTrunc(p.asked, physics.unit);
    p.at_letgo = .of(&b);
    t += 1;
    _ = step(&b, t, if (regrab) &.{ .grab, .letgo } else &.{.letgo}, &.{});
    if (s.then) |then| {
        // Released, and the nearest dog of the breed leashed.
        var other: u16 = 0;
        var best: i64 = std.math.maxInt(i64);
        for (b.dogs, 0..) |q, n| {
            if (n % physics.breeds != then.breed) continue;
            const d2 = physics.len2(physics.delta(b.dogs[leashed], q));
            if (d2 < best) {
                best = d2;
                other = @intCast(n);
            }
        }
        t += 1;
        _ = step(&b, t, &.{ .{ .release = leashed }, .{ .leash = other } }, &.{});
        var k: u32 = 0;
        regrab = false;
        for (then.legs) |leg| for (0..leg.ticks) |_| {
            t += 1;
            k += 1;
            const d: physics.Disp = .{ .dx = physics.px(leg.dx), .dy = physics.px(leg.dy) };
            regrab = step(&b, t, if (regrab) &.{.grab} else &.{}, &.{d});
            if (k == 10 * secs) p.after_10 = .of(&b);
        };
        t += 1;
        _ = step(&b, t, if (regrab) &.{ .grab, .letgo } else &.{.letgo}, &.{});
        while (k < 30 * secs) : (k += 1) {
            t += 1;
            _ = step(&b, t, &.{}, &.{});
            if (k == 10 * secs) p.after_10 = .of(&b);
        }
    } else for (1..30 * secs) |k| {
        t += 1;
        _ = step(&b, t, &.{}, &.{});
        if (k == 10 * secs) p.after_10 = .of(&b);
    }
    p.after_30 = .of(&b);
    return p;
}

fn row(name: []const u8, when: []const u8, both: *const Both, first: *const Both) void {
    const c = &both.rules;
    std.debug.print("{s:<8} {s:<7} {d:>5} {d:>4}  {d:>2} {d:>2} {d:>2} {d:>2}", .{ name, when, c.len, c.herded(), c.count(0), c.count(1), c.count(2), c.count(3) });
    if (c.herdOf(leashed)) |h| {
        std.debug.print("   {d:>4} {d:>4} {d:>5.2}", .{ h.size, h.length, h.perDog() });
    } else std.debug.print("   {s:>4} {s:>4} {s:>5}", .{ "-", "-", "-" });
    std.debug.print("  {d:>5.2}", .{herds.kept(&first.rules, c)});
    // Each breed's largest herd: size/length.
    for (0..physics.breeds) |br| {
        if (c.largest(@intCast(br))) |h| {
            std.debug.print("  {d:>3}/{d:<3}", .{ h.size, h.length });
        } else std.debug.print("  {s:>3} {s:<3}", .{ "-", "" });
    }
    // By the eye: the dogs in herds, the lead's size and length, and kept.
    const e = &both.eye;
    std.debug.print("   {d:>4}", .{e.herded()});
    if (e.herdOf(leashed)) |h| {
        std.debug.print(" {d:>4} {d:>4}", .{ h.size, h.length });
    } else std.debug.print(" {s:>4} {s:>4}", .{ "-", "-" });
    std.debug.print("  {d:>5.2}\n", .{herds.kept(&first.eye, e)});
}

pub fn main() void {
    std.debug.print("herds: metric {t}, knobs {t}; a link is {d} px (the band's {d} + {d}), a herd {d} dogs or more\n", .{ physics.metric, physics.knobs, @divTrunc(herds.link, 256), @divTrunc(physics.band_outer, 256), @divTrunc(herds.slack, 256), herds.least });
    std.debug.print("{s:<8} {s:<7} {s:>5} {s:>4}  {s:>2} {s:>2} {s:>2} {s:>2}   {s:>4} {s:>4} {s:>5}  {s:>5}  {s:<7}  {s:<7}  {s:<7}  {s:<7}   {s:>4} {s:>4} {s:>4}  {s:>5}\n", .{ "script", "when", "herds", "in", "b0", "b1", "b2", "b3", "lead", "len", "links", "kept", "big b0", "big b1", "big b2", "big b3", "eye", "lead", "len", "kept" });
    for (scripts) |s| {
        const p = play(s);
        std.debug.print("{s:<8} the drag: {d} of {d} px (axes added), {d} bumps, each grabbed again\n", .{ s.name, p.went, p.asked, p.bumps });
        row(s.name, "let go", &p.at_letgo, &p.at_letgo);
        row(s.name, "+10 s", &p.after_10, &p.at_letgo);
        row(s.name, "+30 s", &p.after_30, &p.at_letgo);
    }
}

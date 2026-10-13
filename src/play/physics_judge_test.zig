//! **THE WORKED EXAMPLE AS A GOLDEN FIXTURE** (docs/PHYSICS.md, test 26):
//! the doc's report, its `kept 1043` answer, and the `.e1` variant's exact
//! `differ` answer, byte for byte; and the page's side, writing that report
//! from its own board.

const std = @import("std");
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const judge_mod = @import("physics_judge.zig");
const tiles = @import("tiles.zig");
const testing = std.testing;
const Board = physics.Board;
const Point = physics.Point;

/// The doc's physics hash (a placeholder there): the judge takes it as its
/// own, so the fixture reads as written.
const doc_hash: u32 = 0x5e0c91a2;

const example_report =
    \\dogpark 1 physics 5e0c91a2 page 1791935990000.3 req 4
    \\from 1040 wall 1791936000000
    \\held 1041 31,34 31,35 31,36 31,37 31,38 32,34 33,34 34,34 35,34 32,37 33,37 34,37 35,37 32,38 33,38 34,38 35,38
    \\t 1041 +0 drag -1.00,0@3 -2.00,0@19
    \\ dog 219 423c.00,46d2.00 > 4239.00,46d2.00
    \\ cow 43 416e.00,4556.00 > 416e.00,4554.80
    \\ dog 223 42d2.00,46d2.00 > 42d1.f0,46d2.00
    \\letgo 1042
    \\t 1042 +63
    \\ dog 223 42d1.f0,46d2.00 > 42d1.e0,46d2.00
    \\t 1043 +125
    \\ dog 223 42d1.e0,46d2.00 > 42d1.d0,46d2.00
    \\
;

fn px(x: i32, y: i32) Point {
    return .{ .x = physics.px(x), .y = physics.px(y) };
}

/// The played board: today's park in the 64 x 64 world, dog 219 at
/// (16956, 18130) and dog 223 150 px east of it; every other dog that was
/// laid out within 500 px of 219 has wandered off (to empty ground far
/// away); the cows where they were laid out.
pub fn exampleBoard() Board {
    var b = Board.laidOut();
    const at219 = px(16956, 18130);
    var far: i32 = 0;
    for (&b.dogs) |*d| {
        if (physics.len2(physics.delta(at219, d.*)) <= @as(i64, physics.awake_reach) * physics.awake_reach + physics.px(40) * physics.px(40)) {
            d.* = px(1000 + 100 * far, 1000);
            far += 1;
        }
    }
    b.dogs[219] = at219;
    b.dogs[223] = px(17106, 18130);
    return b;
}

fn tileSet(cols: [2]i32, rows: [2]i32) wire.TileSet {
    var s: wire.TileSet = .{};
    var r = rows[0];
    while (r <= rows[1]) : (r += 1) {
        var c = cols[0];
        while (c <= cols[1]) : (c += 1) s.add(.{ .col = c, .row = r }) catch unreachable;
    }
    return s;
}

/// The server at `kept 1040`, after request 3: `leash 1041 219` waiting for
/// 1041, the view of the region's 25 tiles (columns 31 to 35, rows 34 to
/// 38) in effect, the viewport's 8 (columns 32 to 35, rows 35 and 36) held.
fn exampleKept() judge_mod.Kept {
    var k: judge_mod.Kept = .{ .tick = 1040, .board = exampleBoard() };
    k.view = .{ .w = 1280, .h = 800, .tiles = tileSet(.{ 31, 35 }, .{ 34, 38 }) };
    k.held = tileSet(.{ 32, 35 }, .{ 35, 36 });
    k.pending[0] = .{ .leash = 219 };
    k.pending_len = 1;
    // Request 3's answer sent the 17 new tiles; the viewport's 8 went out
    // before it.
    for (k.view.tiles.slice()) |t| k.sent.add(t);
    for (k.held.slice()) |t| k.named.add(t);
    return k;
}

fn judged(report: []const u8, buf: []u8, kept: *judge_mod.Kept) ![]const u8 {
    var out: wire.Text = .{ .buf = buf };
    var findings: judge_mod.Findings = .{};
    _ = try judge_mod.judge(kept, doc_hash, report, &out, &findings);
    try testing.expectEqual(@as(usize, 0), findings.overlaps);
    return out.bytes();
}

test "the worked example: the report is kept through 1043" {
    var k = exampleKept();
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings("req 4\nkept 1043\n", try judged(example_report, &buf, &k));
    try testing.expectEqual(@as(physics.Tick, 1043), k.tick);
    try testing.expectEqual(@as(usize, 0), k.pending_len);
    try testing.expectEqual(physics.Drag{ .ended = 1042 }, k.board.hold.leashed.drag);
    // Cow 43 moved 1.5 px north; cow 48 stayed.
    try testing.expectEqual(Point{ .x = physics.px(16750), .y = physics.px(17750) - 384 }, k.board.cows[43]);
    try testing.expectEqual(px(17250, 18250), k.board.cows[48]);
}

const differ_answer = "req 4\n" ++
    "kept 1041\n" ++
    "differ 1042 dog 223 42d1.f0,46d2.00 > 42d1.e0,46d2.00\n" ++
    "state leash 219 drag on view 1280x800" ++
    " 31,34 32,34 33,34 34,34 35,34 31,35 32,35 33,35 34,35 35,35 31,36 32,36 33,36 34,36 35,36" ++
    " 31,37 32,37 33,37 34,37 35,37 31,38 32,38 33,38 34,38 35,38" ++
    " held" ++
    " 31,34 32,34 33,34 34,34 35,34 31,35 32,35 33,35 34,35 35,35 31,36 32,36 33,36 34,36 35,36" ++
    " 31,37 32,37 33,37 34,37 35,37 31,38 32,38 33,38 34,38 35,38\n" ++
    "board 1042 dog 219 4239.00,46d2.00 cow 43 416e.00,4554.80 cow 48 4362.00,474a.00 dog 223 42d1.f0,46d2.00\n";

test "the worked example, dog 223's step at 1042 written .e1: the exact differ answer" {
    const report = try std.mem.replaceOwned(u8, testing.allocator, example_report, " dog 223 42d1.f0,46d2.00 > 42d1.e0,46d2.00", " dog 223 42d1.f0,46d2.00 > 42d1.e1,46d2.00");
    defer testing.allocator.free(report);
    var k = exampleKept();
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings(differ_answer, try judged(report, &buf, &k));
    // Kept through 1041; the drag still on at the start of 1042.
    try testing.expectEqual(@as(physics.Tick, 1041), k.tick);
    try testing.expectEqual(physics.Drag.on, k.board.hold.leashed.drag);
}

test "the worked example: the region is 25 tiles, columns 31 to 35, rows 34 to 38; cows 43 and 48 awake, 432 and 317 px off" {
    var b = exampleBoard();
    b.hold = .{ .leashed = .{ .dog = 219, .drag = .on } };
    const span = physics.TileSpan.of(physics.region(b.dogs[219]));
    try testing.expectEqual(physics.TileSpan{ .col_lo = 31, .col_hi = 35, .row_lo = 34, .row_hi = 38 }, span);
    const sc = physics.Scene.of(&b).?;
    var awake: [8]physics.Critter = undefined;
    var n: usize = 0;
    for (sc.list()) |s| if (s.awake == .awake) {
        awake[n] = s.who;
        n += 1;
    };
    try testing.expectEqualSlices(physics.Critter, &.{ .dog(219), .cow(43), .cow(48), .dog(223) }, awake[0..n]);
    try testing.expectEqual(@as(i64, 432), physics.isqrt(physics.len2(physics.delta(b.dogs[219], b.cows[43]))) >> 8);
    try testing.expectEqual(@as(i64, 317), physics.isqrt(physics.len2(physics.delta(b.dogs[219], b.cows[48]))) >> 8);
}

/// The page's side: its board holds only the critters of the tiles it has
/// (the region's 25), and writing each tick's lines from its own run gives
/// the doc's report, byte for byte.
pub fn pageBoard(server: Board, held: wire.TileSet) Board {
    var b = server;
    for (b.dogs, &b.dog_known) |d, *k| k.* = if (held.holds(physics.tileOf(d))) .present else .absent;
    for (b.cows, &b.cow_known) |c, *k| k.* = if (held.holds(physics.tileOf(c))) .present else .absent;
    return b;
}

test "the worked example from the page's side: its own run writes the doc's report, byte for byte" {
    var b = pageBoard(exampleBoard(), tileSet(.{ 31, 35 }, .{ 34, 38 }));
    var buf: [4096]u8 = undefined;
    var w: wire.Text = .{ .buf = &buf };
    try wire.write(&w, .{ .header = .{ .language = 1, .physics = doc_hash, .epoch = .{ .ms = 1791935990000, .count = 3 }, .req = 4 } });
    try wire.write(&w, .{ .from = .{ .tick = 1040, .wall = 1791936000000 } });
    // The held line in the order the page wrote it.
    var held: wire.TileSet = .{};
    for ([_][2]i32{ .{ 31, 34 }, .{ 31, 35 }, .{ 31, 36 }, .{ 31, 37 }, .{ 31, 38 }, .{ 32, 34 }, .{ 33, 34 }, .{ 34, 34 }, .{ 35, 34 }, .{ 32, 37 }, .{ 33, 37 }, .{ 34, 37 }, .{ 35, 37 }, .{ 32, 38 }, .{ 33, 38 }, .{ 34, 38 }, .{ 35, 38 } }) |cr| try held.add(.{ .col = cr[0], .row = cr[1] });
    try wire.write(&w, .{ .held = .{ .tick = 1041, .tiles = held } });
    // 1041: the leash (request 3's input), the drag.
    var lines: physics.Lines = .{};
    const drag = physics.mergeAndCap(&.{ .{ .dx = -256, .dy = 0, .ms = 3 }, .{ .dx = -512, .dy = 0, .ms = 19 } });
    try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, 1041, &.{.{ .leash = 219 }}, drag.slice(), &lines));
    try wire.write(&w, .{ .t = .{ .tick = 1041, .ms = 0, .drag = drag } });
    for (lines.slice()) |c| try wire.write(&w, wire.checkedLine(1041, c));
    // 1042: the human lets go.
    try wire.write(&w, .{ .letgo = 1042 });
    try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, 1042, &.{.letgo}, &.{}, &lines));
    try wire.write(&w, .{ .t = .{ .tick = 1042, .ms = 63, .drag = .{} } });
    for (lines.slice()) |c| try wire.write(&w, wire.checkedLine(1042, c));
    try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, 1043, &.{}, &.{}, &lines));
    try wire.write(&w, .{ .t = .{ .tick = 1043, .ms = 125, .drag = .{} } });
    for (lines.slice()) |c| try wire.write(&w, wire.checkedLine(1043, c));
    try testing.expectEqualStrings(example_report, w.bytes());
}

test "a report with no ticks is kept at its own from, its inputs waiting for the next tick" {
    var k = exampleKept();
    var buf: [1024]u8 = undefined;
    const report = "dogpark 1 physics 5e0c91a2 page 1791935990000.3 req 4\nfrom 1040\ngrab 1041\n";
    try testing.expectEqualStrings("req 4\nkept 1040\n", try judged(report, &buf, &k));
    try testing.expectEqualSlices(physics.Human, &.{ .{ .leash = 219 }, .grab }, k.pendingSlice());
    try testing.expectEqual(physics.Hold.none, k.board.hold);
}

test "a tick whose region meets a tile not held is refused at its t line" {
    var k = exampleKept();
    var buf: [4096]u8 = undefined;
    const report = "dogpark 1 physics 5e0c91a2 page 1791935990000.3 req 4\nfrom 1040 wall 1791936000000\nt 1041 +0\n";
    const answer = try judged(report, &buf, &k);
    try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1040\ndiffer 1041 none t 1041 +0\nstate leash none drag none view 1280x800"));
    // The kept leash waits for 1041, and the answer says so.
    try testing.expect(std.mem.indexOf(u8, answer, "\ninput leash 1041 219\n") != null);
}

test "the header: another language or physics reloads; an unreadable one gets req ? alone; another from, reload from K" {
    var buf: [256]u8 = undefined;
    var k = exampleKept();
    try testing.expectEqualStrings("req ?\n", try judged("dogpark 1 physics 5E0C91A2 page 1.3 req 4\n", &buf, &k));
    try testing.expectEqualStrings("req 4\nreload language 1\n", try judged("dogpark 2 physics 5e0c91a2 page 1.3 req 4\nfrom 1040\n", &buf, &k));
    try testing.expectEqualStrings("req 4\nreload physics 5e0c91a2\n", try judged("dogpark 1 physics 5e0c91a3 page 1.3 req 4\nfrom 1040\n", &buf, &k));
    try testing.expectEqualStrings("req 4\nreload from 1040\n", try judged("dogpark 1 physics 5e0c91a2 page 1.3 req 4\nfrom 1039\n", &buf, &k));
}

test "a held naming a tile never sent is refused at that line" {
    var k = exampleKept();
    k.sent = .{};
    for (k.held.slice()) |t| k.sent.add(t);
    var buf: [4096]u8 = undefined;
    const answer = try judged(example_report, &buf, &k);
    try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1040\ndiffer 1041 none held 1041 31,34 "));
}

test "a refused input: a leash while one is leashed is differ none at that line" {
    var k = exampleKept();
    var buf: [4096]u8 = undefined;
    const report = "dogpark 1 physics 5e0c91a2 page 1.3 req 4\nfrom 1040 wall 5\nleash 1041 7\n";
    const answer = try judged(report, &buf, &k);
    try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1040\ndiffer 1041 none leash 1041 7\n"));
}

test "a report missing a line the server's run has, and one with a line it doesn't" {
    var buf: [4096]u8 = undefined;
    // Cow 43's line dropped: the server's is named.
    {
        var k = exampleKept();
        const report = try std.mem.replaceOwned(u8, testing.allocator, example_report, " cow 43 416e.00,4556.00 > 416e.00,4554.80\n", "");
        defer testing.allocator.free(report);
        const answer = try judged(report, &buf, &k);
        try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1040\ndiffer 1041 cow 43 416e.00,4556.00 > 416e.00,4554.80\n"));
    }
    // A rest the server's run doesn't have.
    {
        var k = exampleKept();
        const report = try std.mem.replaceOwned(u8, testing.allocator, example_report, "t 1043 +125\n dog 223 42d1.e0,46d2.00 > 42d1.d0,46d2.00\n", "t 1043 +125\n dog 223 42d1.e0,46d2.00 > 42d1.d0,46d2.00\nrest 1043\n");
        defer testing.allocator.free(report);
        const answer = try judged(report, &buf, &k);
        try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1042\ndiffer 1043 none rest 1043\nstate leash 219 drag ended 1042 "));
    }
}

test "a drag with no drag on is ignored and noted as a finding" {
    var k = exampleKept();
    var buf: [4096]u8 = undefined;
    const report = try std.mem.replaceOwned(u8, testing.allocator, example_report, "t 1043 +125\n", "t 1043 +125 drag +1.00,0@5\n");
    defer testing.allocator.free(report);
    var out: wire.Text = .{ .buf = &buf };
    var findings: judge_mod.Findings = .{};
    try testing.expectEqual(judge_mod.Verdict.kept, try judge_mod.judge(&k, doc_hash, report, &out, &findings));
    try testing.expectEqual(@as(usize, 1), findings.idle_drags);
}

test "a tick over the cap is refused at its t line" {
    var k = exampleKept();
    var buf: [4096]u8 = undefined;
    const report = try std.mem.replaceOwned(u8, testing.allocator, example_report, "drag -1.00,0@3 -2.00,0@19", "drag -64.00,0@3 -64.00,0@19");
    defer testing.allocator.free(report);
    const answer = try judged(report, &buf, &k);
    try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1040\ndiffer 1041 none t 1041 +0 drag -64.00,0@3 -64.00,0@19\n"));
}

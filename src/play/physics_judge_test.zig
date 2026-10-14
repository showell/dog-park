//! **THE WORKED EXAMPLE AS A GOLDEN FIXTURE** (docs/PHYSICS.md, test 26):
//! the doc's report, its `kept 1043` answer, and the exact `differ` answer
//! to it with dog 223's step at 1042 a 256th off, byte for byte; and the
//! page's side, writing that report from its own board. The two goldens
//! pin the wire's form and the page and the server agreeing; a retune
//! changes them, and their failures print the new text, which goes here
//! and into the doc. The other tests derive what they check from them.

const std = @import("std");
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const judge_mod = @import("physics_judge.zig");
const tiles = @import("tiles.zig");
const testing = std.testing;
const Board = physics.Board;
const Point = physics.Point;

/// The worked example is the doc's, written under the played knobs: under
/// another tuning (-Dknobs=alt) the same inputs play out otherwise, so its
/// tests skip there, by name; the tests derived from no example still run.
/// The worked example (docs/PHYSICS.md) is the played physics': Steve's
/// knobs and the straight-line metric.
fn playedOnly() !void {
    if (physics.knobs != .played or physics.metric != .euclid) return error.SkipZigTest;
}

/// The doc's physics hash (a placeholder there): the judge takes it as its
/// own, so the fixture reads as written.
const doc_hash: u32 = 0x5e0c91a2;

/// The doc's report, golden: on a retune its test fails with the page's
/// own run printed, which goes here and into the doc.
pub const example_report =
    \\dogpark 1 physics 5e0c91a2 page 1791935990000.3 req 4
    \\from 1040 wall 1791936000000
    \\held 1041 30,32 31,32 32,32 33,32 34,32 35,32 36,32 30,33 31,33 32,33 33,33 34,33 35,33 36,33 30,34 31,34 32,34 33,34 34,34 35,34 36,34 30,35 31,35 36,35 30,36 31,36 36,36 30,37 31,37 32,37 33,37 34,37 35,37 36,37 30,38 31,38 32,38 33,38 34,38 35,38 36,38
    \\t 1041 +0 drag -1.00,0@3 -2.00,0@19
    \\ dog 219 423c.00,463c.00 > 4239.00,463c.00
    \\ cow 43 416e.00,4556.00 > 416e.00,4554.80
    \\ dog 223 42d2.00,463c.00 > 42ce.88,463c.00
    \\letgo 1042
    \\t 1042 +63
    \\ dog 223 42ce.88,463c.00 > 42ce.10,463c.00
    \\t 1043 +125
    \\ dog 223 42ce.10,463c.00 > 42cd.98,463c.00
    \\
;

fn px(x: i32, y: i32) Point {
    return .{ .x = physics.px(x), .y = physics.px(y) };
}

/// The leashed dog, where the example's played board has it.
pub const leashed: u16 = 219;
/// Dog 223, of 219's breed, 150 px east of it.
pub const follower: u16 = 223;

/// The played board: today's park in the 64 x 64 world, dog 219 at
/// (16956, 17980) and dog 223 150 px east of it; every other dog that was
/// laid out within the awake sphere of 219 has wandered off (to empty
/// ground far away); the cows where they were laid out.
pub fn exampleBoard() Board {
    var b = Board.laidOut();
    const at219 = px(16956, 17980);
    var far: i32 = 0;
    for (&b.dogs) |*d| {
        if (physics.len2(physics.delta(at219, d.*)) <= @as(i64, physics.awake_reach + physics.px(40)) * (physics.awake_reach + physics.px(40))) {
            d.* = px(1000 + 100 * far, 1000);
            far += 1;
        }
    }
    b.dogs[leashed] = at219;
    b.dogs[follower] = px(17106, 17980);
    return b;
}

fn tileSet(cols: [2]i32, rows: [2]i32) wire.TileSet {
    var s: wire.TileSet = .{};
    var r = rows[0];
    while (r <= rows[1]) : (r += 1) {
        var c = cols[0];
        while (c <= cols[1]) : (c += 1) s.add(physics.TileSpan.at(c, r)) catch unreachable;
    }
    return s;
}

/// The region's tiles around dog 219: request 3's view.
pub fn exampleRegion() wire.TileSet {
    const span = physics.TileSpan.of(physics.region(exampleBoard().dogs[leashed]));
    return tileSet(.{ span.col_lo, span.col_hi }, .{ span.row_lo, span.row_hi });
}

/// The viewport's 8 tiles (columns 32 to 35, rows 35 and 36), held before
/// the leash.
pub fn exampleViewport() wire.TileSet {
    return tileSet(.{ 32, 35 }, .{ 35, 36 });
}

/// The region's tiles the viewport's aren't: the report's `held 1041`, by
/// row, then column.
pub fn exampleHeld() wire.TileSet {
    var s: wire.TileSet = .{};
    const v = exampleViewport();
    for (exampleRegion().slice()) |t| if (!v.holds(t)) s.add(t) catch unreachable;
    return s;
}

/// The server at `kept 1040`, after request 3: `leash 1041 219` waiting for
/// 1041, the view of the region's tiles in effect, the viewport's 8 held.
pub fn exampleKept() judge_mod.Kept {
    var k: judge_mod.Kept = .{ .tick = 1040, .board = exampleBoard() };
    k.view = .{ .w = 1280, .h = 800, .tiles = exampleRegion() };
    k.held = exampleViewport();
    k.pending[0] = .{ .leash = leashed };
    k.pending_len = 1;
    // Request 3's answer sent the region's new tiles; the viewport's 8 went
    // out before it.
    for (k.view.tiles.slice()) |t| k.sent.add(t);
    for (k.held.slice()) |t| k.named.add(t);
    return k;
}

/// The page's own run of the example: its board holds only the region's
/// tiles' critters; it writes the header, from, the held, and the three
/// ticks (the leash and a 3 px drag west at 1041, a letgo at 1042, 1043).
pub fn examplePageRun(buf: []u8) ![]const u8 {
    var b = pageBoard(exampleBoard(), exampleRegion());
    var w: wire.Text = .{ .buf = buf };
    try wire.write(&w, .{ .header = .{ .language = 1, .physics = doc_hash, .epoch = .{ .ms = 1791935990000, .count = 3 }, .req = 4 } });
    try wire.write(&w, .{ .from = .{ .tick = 1040, .wall = 1791936000000 } });
    try wire.write(&w, .{ .held = .{ .tick = 1041, .tiles = exampleHeld() } });
    var lines: physics.Lines = .{};
    const drag = physics.mergeAndCap(&.{ .{ .dx = -256, .dy = 0, .ms = 3 }, .{ .dx = -512, .dy = 0, .ms = 19 } });
    try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, 1041, &.{.{ .leash = leashed }}, drag.slice(), &lines));
    try wire.write(&w, .{ .t = .{ .tick = 1041, .ms = 0, .drag = drag } });
    for (lines.slice()) |c| try wire.write(&w, wire.checkedLine(1041, c));
    try wire.write(&w, .{ .letgo = 1042 });
    try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, 1042, &.{.letgo}, &.{}, &lines));
    try wire.write(&w, .{ .t = .{ .tick = 1042, .ms = 63, .drag = .{} } });
    for (lines.slice()) |c| try wire.write(&w, wire.checkedLine(1042, c));
    try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, 1043, &.{}, &.{}, &lines));
    try wire.write(&w, .{ .t = .{ .tick = 1043, .ms = 125, .drag = .{} } });
    for (lines.slice()) |c| try wire.write(&w, wire.checkedLine(1043, c));
    return w.bytes();
}

fn judged(report: []const u8, buf: []u8, kept: *judge_mod.Kept) ![]const u8 {
    var out: wire.Text = .{ .buf = buf };
    var findings: judge_mod.Findings = .{};
    _ = try judge_mod.judge(kept, doc_hash, report, &out, &findings);
    try testing.expectEqual(@as(usize, 0), findings.overlaps);
    return out.bytes();
}

test "the worked example from the page's side: its own run writes the doc's report, byte for byte" {
    try playedOnly();
    var buf: [8192]u8 = undefined;
    try testing.expectEqualStrings(example_report, try examplePageRun(&buf));
}

test "the worked example: the report is kept through 1043, the drag ended at the letgo, the leash on" {
    try playedOnly();
    var k = exampleKept();
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings("req 4\nkept 1043\n", try judged(example_report, &buf, &k));
    try testing.expectEqual(@as(physics.Tick, 1043), k.tick);
    try testing.expectEqual(@as(usize, 0), k.pending_len);
    try testing.expectEqual(physics.Hold{ .leashed = .{ .dog = leashed, .drag = .{ .ended = 1042 } } }, k.board.hold);
}

/// The example's critter line for `who` at tick `t`, unindented, as `differ`
/// quotes it.
fn exampleLine(t: physics.Tick, who: []const u8, buf: []u8) ![]const u8 {
    var tick_buf: [32]u8 = undefined;
    const tick_at = std.mem.indexOf(u8, example_report, try std.fmt.bufPrint(&tick_buf, "t {d} ", .{t})).?;
    const at = std.mem.indexOfPos(u8, example_report, tick_at, who).?;
    const eol = std.mem.indexOfScalarPos(u8, example_report, at, '\n').?;
    return std.fmt.bufPrint(buf, "{s}", .{example_report[at + 1 .. eol]});
}

const differ_answer = "req 4\n" ++
    "kept 1041\n" ++
    "differ 1042 dog 223 42ce.88,463c.00 > 42ce.10,463c.00\n" ++
    "state leash 219 drag on view 1280x800" ++
    " 30,32 31,32 32,32 33,32 34,32 35,32 36,32" ++
    " 30,33 31,33 32,33 33,33 34,33 35,33 36,33" ++
    " 30,34 31,34 32,34 33,34 34,34 35,34 36,34" ++
    " 30,35 31,35 32,35 33,35 34,35 35,35 36,35" ++
    " 30,36 31,36 32,36 33,36 34,36 35,36 36,36" ++
    " 30,37 31,37 32,37 33,37 34,37 35,37 36,37" ++
    " 30,38 31,38 32,38 33,38 34,38 35,38 36,38" ++
    " held" ++
    " 30,32 31,32 32,32 33,32 34,32 35,32 36,32" ++
    " 30,33 31,33 32,33 33,33 34,33 35,33 36,33" ++
    " 30,34 31,34 32,34 33,34 34,34 35,34 36,34" ++
    " 30,35 31,35 32,35 33,35 34,35 35,35 36,35" ++
    " 30,36 31,36 32,36 33,36 34,36 35,36 36,36" ++
    " 30,37 31,37 32,37 33,37 34,37 35,37 36,37" ++
    " 30,38 31,38 32,38 33,38 34,38 35,38 36,38" ++
    "\n" ++
    "board 1042 dog 219 4239.00,463c.00 cow 38 4362.00,4362.00 cow 43 416e.00,4554.80 cow 47 3f7a.00,474a.00 cow 48 4362.00,474a.00 dog 223 42ce.88,463c.00\n";

test "the worked example, dog 223's step at 1042 a 256th off: the exact differ answer" {
    try playedOnly();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var line_buf: [128]u8 = undefined;
    const right = try exampleLine(1042, " dog 223 ", &line_buf);
    const last = right[right.len - 1];
    const wrong = try std.fmt.allocPrint(a, "{s}{c}", .{ right[0 .. right.len - 1], @as(u8, if (last == '0') '1' else '0') });
    const tampered = try std.mem.replaceOwned(u8, a, example_report, try std.fmt.allocPrint(a, " {s}\n", .{right}), try std.fmt.allocPrint(a, " {s}\n", .{wrong}));
    var k = exampleKept();
    var buf: [8192]u8 = undefined;
    try testing.expectEqualStrings(differ_answer, try judged(tampered, &buf, &k));
    // Kept through 1041; the drag still on at the start of 1042.
    try testing.expectEqual(@as(physics.Tick, 1041), k.tick);
    try testing.expectEqual(physics.Drag.on, k.board.hold.leashed.drag);
}

test "the worked example's region holds the viewport, and its awake critters are the leashed dog, the cows within the sphere and dog 223" {
    try playedOnly();
    var b = exampleBoard();
    b.hold = .{ .leashed = .{ .dog = leashed, .drag = .on } };
    const region = exampleRegion();
    for (exampleViewport().slice()) |t| try testing.expect(region.holds(t));
    const sc = physics.Scene.of(&b).?;
    var awake: [16]physics.Critter = undefined;
    var n: usize = 0;
    for (sc.list()) |s| if (s.awake == .awake) {
        awake[n] = s.who;
        n += 1;
    };
    try testing.expectEqualSlices(physics.Critter, &.{ .dog(leashed), .cow(38), .cow(43), .cow(47), .cow(48), .dog(follower) }, awake[0..n]);
}

/// The page's side: its board holds only the critters of the tiles it has.
pub fn pageBoard(server: Board, held: wire.TileSet) Board {
    var b = server;
    for (b.dogs, &b.dog_known) |d, *k| k.* = if (held.holds(physics.tileOf(d))) .present else .absent;
    for (b.cows, &b.cow_known) |c, *k| k.* = if (held.holds(physics.tileOf(c))) .present else .absent;
    return b;
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
    var want: [64]u8 = undefined;
    const first = exampleHeld().slice()[0];
    try testing.expect(std.mem.startsWith(u8, answer, try std.fmt.bufPrint(&want, "req 4\nkept 1040\ndiffer 1041 none held 1041 {d},{d} ", .{ first.col, first.row })));
}

test "a refused input: a leash while one is leashed is differ none at that line" {
    var k = exampleKept();
    var buf: [4096]u8 = undefined;
    const report = "dogpark 1 physics 5e0c91a2 page 1.3 req 4\nfrom 1040 wall 5\nleash 1041 7\n";
    const answer = try judged(report, &buf, &k);
    try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1040\ndiffer 1041 none leash 1041 7\n"));
}

test "a report missing a line the server's run has, and one with a line it doesn't" {
    try playedOnly();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [4096]u8 = undefined;
    // Cow 43's line dropped: the server's is named.
    {
        var k = exampleKept();
        var line_buf: [128]u8 = undefined;
        const cow43 = try exampleLine(1041, " cow 43 ", &line_buf);
        const report = try std.mem.replaceOwned(u8, a, example_report, try std.fmt.allocPrint(a, " {s}\n", .{cow43}), "");
        const answer = try judged(report, &buf, &k);
        try testing.expect(std.mem.startsWith(u8, answer, try std.fmt.allocPrint(a, "req 4\nkept 1040\ndiffer 1041 {s}\n", .{cow43})));
    }
    // A rest the server's run doesn't have, after the last tick's lines.
    {
        var k = exampleKept();
        const report = example_report ++ "rest 1043\n";
        const answer = try judged(report, &buf, &k);
        try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1042\ndiffer 1043 none rest 1043\nstate leash 219 drag ended 1042 "));
    }
}

test "a drag with no drag on is ignored and noted as a finding" {
    try playedOnly();
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

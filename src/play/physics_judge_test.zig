//! **THE WORKED EXAMPLE AS A GOLDEN FIXTURE** (docs/PHYSICS.md, "The report"):
//! the doc's report, its `kept 1043` answer, and the exact `differ` answer
//! to it with dog 23's step at 1041 a 256th off; and the
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

/// The doc's physics hash (a placeholder there): the judge takes it as its
/// own, so the fixture reads as written.
const doc_hash: u32 = 0x5e0c91a2;

/// The doc's report, golden: on a retune its test fails with the page's
/// own run printed, which goes here and into the doc.
pub const example_report =
    \\dogpark 2 physics 5e0c91a2 page 1791935990000.3 req 4
    \\from 1040 wall 1791936000000
    \\t 1041 +0 drag -1.00,0@3 -2.00,0@19
    \\ dog 19 3e8.00,3e8.00 > 3e5.00,3e8.00
    \\ cow 2 36b.00,36b.00 > 369.89,369.80
    \\ dog 23 451.00,3e8.00 > 44e.00,3e8.00
    \\letgo 1042
    \\t 1042 +63
    \\t 1043 +125
    \\
;

fn px(x: i32, y: i32) Point {
    return .{ .x = physics.px(x), .y = physics.px(y) };
}

/// The leashed dog, and dog 23, of its breed, 105 px east of it.
pub const leashed: u16 = 19;
pub const follower: u16 = 23;

/// The played board: the park as laid out (the cows in the white tiles'
/// middles, the chickens in the blue), dog 19 at (1000, 1000), 125 px from
/// cow 2 at (875, 875), and dog 23 105 px east of it; every other dog gone
/// from the board, so the example's walk stays small.
pub fn exampleBoard() Board {
    var b = Board.laidOut();
    for (b.knownOfMut(.dog), 0..) |*k, i| {
        if (i != leashed and i != follower) k.* = .absent;
    }
    b.ofMut(.dog)[leashed] = px(1000, 1000);
    b.ofMut(.dog)[follower] = px(1105, 1000);
    return b;
}

fn tileSet(cols: [2]i32, rows: [2]i32) wire.TileSet {
    var s: wire.TileSet = .{};
    var r = rows[0];
    while (r <= rows[1]) : (r += 1) {
        var c = cols[0];
        while (c <= cols[1]) : (c += 1) s.add(physics.room.tileAt(c, r)) catch unreachable;
    }
    return s;
}

/// The region's tiles: the whole world, every tile once.
pub fn exampleRegion() wire.TileSet {
    const span = physics.TileSpan.of(physics.room, physics.room.region(exampleBoard().of(.dog)[leashed]));
    return tileSet(.{ span.col_lo, span.col_hi }, .{ span.row_lo, span.row_hi });
}

/// The server at `kept 1040`, after request 3: `leash 1041 19` waiting for
/// 1041; the page holds the whole world, as it always does, so the region
/// is held already.
pub fn exampleKept() judge_mod.Kept {
    var k: judge_mod.Kept = .{ .tick = 1040, .board = exampleBoard() };
    k.view = .{ .w = 1280, .h = 800, .tiles = exampleRegion() };
    k.held = exampleRegion();
    k.pending[0] = .{ .leash = leashed };
    k.pending_len = 1;
    for (k.view.tiles.slice()) |t| {
        k.sent.add(t);
        k.named.add(t);
    }
    return k;
}

/// The page's own run of the example: it writes the header, from, and the
/// three ticks (the leash and a 3 px drag west at 1041, a letgo at 1042,
/// 1043).
pub fn examplePageRun(buf: []u8) ![]const u8 {
    var b = exampleBoard();
    var w: wire.Text = .{ .buf = buf };
    try wire.write(&w, .{ .header = .{ .language = wire.language, .physics = doc_hash, .epoch = .{ .ms = 1791935990000, .count = 3 }, .req = 4 } });
    try wire.write(&w, .{ .from = .{ .tick = 1040, .wall = 1791936000000 } });
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
    try @import("physics_golden_test.zig").recordedOrSkip("the worked example (docs/PHYSICS.md)");
    var buf: [8192]u8 = undefined;
    try testing.expectEqualStrings(example_report, try examplePageRun(&buf));
}

test "the worked example: the report is kept through 1043, the drag ended at the letgo, the leash on" {
    try @import("physics_golden_test.zig").recordedOrSkip("the worked example (docs/PHYSICS.md)");
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

test "the worked example, dog 23's step at 1041 a 256th off: differ at that line, the server's own line and its state and board at 1041" {
    try @import("physics_golden_test.zig").recordedOrSkip("the worked example (docs/PHYSICS.md)");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var line_buf: [128]u8 = undefined;
    const right = try exampleLine(1041, " dog 23 ", &line_buf);
    const last = right[right.len - 1];
    const wrong = try std.fmt.allocPrint(a, "{s}{c}", .{ right[0 .. right.len - 1], @as(u8, if (last == '0') '1' else '0') });
    const tampered = try std.mem.replaceOwned(u8, a, example_report, try std.fmt.allocPrint(a, " {s}\n", .{right}), try std.fmt.allocPrint(a, " {s}\n", .{wrong}));
    var k = exampleKept();
    var buf: [8192]u8 = undefined;
    const answer = try judged(tampered, &buf, &k);
    try testing.expect(std.mem.startsWith(u8, answer, try std.fmt.allocPrint(a, "req 4\nkept 1040\ndiffer 1041 {s}\nstate leash none drag none laid 0 ", .{right})));
    try testing.expect(std.mem.indexOf(u8, answer, "\ninput leash 1041 19\nboard 1041 ") != null);
    // Nothing of 1041 kept.
    try testing.expectEqual(@as(physics.Tick, 1040), k.tick);
}

test "the worked example's region is the world, and every critter on the board is seen: the two dogs, and every critter of every other kind" {
    var b = exampleBoard();
    b.hold = .{ .leashed = .{ .dog = leashed, .drag = .on } };
    try testing.expectEqual(@as(usize, tiles.room_tiles * tiles.room_tiles), exampleRegion().slice().len);
    const sc = physics.Scene.of(&b).?;
    try testing.expectEqual(@as(usize, 2 + physics.critter_count - physics.countOf(.dog)), sc.len);
}

test "a report with no ticks is kept at its own from, its inputs waiting for the next tick" {
    var k = exampleKept();
    var buf: [1024]u8 = undefined;
    const report = "dogpark 2 physics 5e0c91a2 page 1791935990000.3 req 4\nfrom 1040\ngrab 1041\n";
    try testing.expectEqualStrings("req 4\nkept 1040\n", try judged(report, &buf, &k));
    try testing.expectEqualSlices(physics.Human, &.{ .{ .leash = 19 }, .grab }, k.pendingSlice());
    try testing.expectEqual(physics.Hold.none, k.board.hold);
}

test "a tick whose region meets a tile not held is refused at its t line" {
    // The page always holds the whole world; one that didn't hold a tile
    // the physics sees is refused.
    var k = exampleKept();
    k.held = .{};
    var buf: [4096]u8 = undefined;
    const report = "dogpark 2 physics 5e0c91a2 page 1791935990000.3 req 4\nfrom 1040 wall 1791936000000\nt 1041 +0\n";
    const answer = try judged(report, &buf, &k);
    try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1040\ndiffer 1041 none t 1041 +0\nstate leash none drag none laid 0 view 1280x800"));
    // The kept leash waits for 1041, and the answer says so.
    try testing.expect(std.mem.indexOf(u8, answer, "\ninput leash 1041 19\n") != null);
}

test "the header: another language or physics reloads; an unreadable one gets req ? alone; another from, reload from K" {
    var buf: [256]u8 = undefined;
    var k = exampleKept();
    try testing.expectEqualStrings("req ?\n", try judged("dogpark 2 physics 5E0C91A2 page 1.3 req 4\n", &buf, &k));
    try testing.expectEqualStrings("req 4\nreload language 2\n", try judged("dogpark 3 physics 5e0c91a2 page 1.3 req 4\nfrom 1040\n", &buf, &k));
    try testing.expectEqualStrings("req 4\nreload physics 5e0c91a2\n", try judged("dogpark 2 physics 5e0c91a3 page 1.3 req 4\nfrom 1040\n", &buf, &k));
    try testing.expectEqualStrings("req 4\nreload from 1040\n", try judged("dogpark 2 physics 5e0c91a2 page 1.3 req 4\nfrom 1039\n", &buf, &k));
}

test "a held naming a tile never sent is refused at that line" {
    var k = exampleKept();
    k.sent = .{};
    k.held = .{};
    var buf: [4096]u8 = undefined;
    const report = "dogpark 2 physics 5e0c91a2 page 1791935990000.3 req 4\nfrom 1040\nheld 1041 2,3\n";
    const answer = try judged(report, &buf, &k);
    try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1040\ndiffer 1041 none held 1041 2,3\n"));
}

test "a refused input: a leash while one is leashed is differ none at that line" {
    var k = exampleKept();
    var buf: [4096]u8 = undefined;
    const report = "dogpark 2 physics 5e0c91a2 page 1.3 req 4\nfrom 1040 wall 5\nleash 1041 7\n";
    const answer = try judged(report, &buf, &k);
    try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1040\ndiffer 1041 none leash 1041 7\n"));
}

test "a report missing a line the server's run has, and one with a line it doesn't" {
    try @import("physics_golden_test.zig").recordedOrSkip("the worked example (docs/PHYSICS.md)");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [4096]u8 = undefined;
    // Dog 23's line dropped: the server's is named.
    {
        var k = exampleKept();
        var line_buf: [128]u8 = undefined;
        const dog23 = try exampleLine(1041, " dog 23 ", &line_buf);
        const report = try std.mem.replaceOwned(u8, a, example_report, try std.fmt.allocPrint(a, " {s}\n", .{dog23}), "");
        const answer = try judged(report, &buf, &k);
        try testing.expect(std.mem.startsWith(u8, answer, try std.fmt.allocPrint(a, "req 4\nkept 1040\ndiffer 1041 {s}\n", .{dog23})));
    }
    // A rest the server's run doesn't have, after the last tick's lines.
    {
        var k = exampleKept();
        const report = example_report ++ "rest 1043\n";
        const answer = try judged(report, &buf, &k);
        try testing.expect(std.mem.startsWith(u8, answer, "req 4\nkept 1042\ndiffer 1043 none rest 1043\nstate leash 19 drag ended 1042 laid 0 "));
    }
}

test "a drag with no drag on is ignored and noted as a finding" {
    try @import("physics_golden_test.zig").recordedOrSkip("the worked example (docs/PHYSICS.md)");
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

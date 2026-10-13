//! The report's text: the canonical round trip (docs/PHYSICS.md, test 29):
//! every line the shared Zig writes parses back to the same integers, and
//! every other spelling of them is refused.

const std = @import("std");
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const tiles = @import("tiles.zig");
const testing = std.testing;
const Text = wire.Text;

fn written(line: wire.Line, buf: []u8) []const u8 {
    var w: Text = .{ .buf = buf };
    wire.write(&w, line) catch unreachable;
    return w.bytes()[0 .. w.len - 1];
}

fn roundTrip(line: wire.Line) !void {
    var a: [2048]u8 = undefined;
    var b: [2048]u8 = undefined;
    const text = written(line, &a);
    const back = try wire.parse(text);
    try testing.expect(wire.same(line, back));
    try testing.expectEqualStrings(text, written(back, &b));
}

fn refused(text: []const u8) !void {
    if (wire.parse(text)) |_| {
        std.debug.print("parsed, and should not have: \"{s}\"\n", .{text});
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn tileSet(list: []const [2]i32) wire.TileSet {
    var s: wire.TileSet = .{};
    for (list) |cr| s.add(.{ .col = cr[0], .row = cr[1] }) catch unreachable;
    return s;
}

test "the canonical numbers: d80.40 is 3456.25 px; 0.00; displacements +1.00, -2.80 and 0; the hash, eight digits" {
    var buf: [64]u8 = undefined;
    var w: Text = .{ .buf = &buf };
    try w.hexPoint(3456 * 256 + 64);
    try w.char(' ');
    try w.hexPoint(0);
    try w.char(' ');
    try w.disp(256);
    try w.char(' ');
    try w.disp(-640);
    try w.char(' ');
    try w.disp(0);
    try w.char(' ');
    try w.hash(0xabcd);
    try testing.expectEqualStrings("d80.40 0.00 +1.00 -2.80 0 0000abcd", w.bytes());
    try testing.expectEqual(@as(u32, 3456 * 256 + 64), try wire.parseHexPoint("d80.40", std.math.maxInt(u32)));
    try testing.expectEqual(@as(i32, -640), try wire.parseDisp("-2.80"));
    try testing.expectEqual(@as(i32, 0), try wire.parseDisp("0"));
}

test "every kind of line round-trips: written, parsed, the same integers, written the same" {
    var drag: physics.Capped = .{};
    drag.list[0] = .{ .dx = -256, .dy = 0, .ms = 3 };
    drag.list[1] = .{ .dx = 25600, .dy = -1, .ms = 0 };
    drag.len = 2;
    const lines = [_]wire.Line{
        .{ .header = .{ .language = 1, .physics = 0x5e0c91a2, .epoch = .{ .ms = 1791935990000, .count = 3 }, .req = 4 } },
        .{ .header = .{ .language = 1, .physics = 0, .epoch = .{ .ms = 0, .count = 0 }, .req = 0 } },
        .{ .from = .{ .tick = 1040, .wall = 1791936000000 } },
        .{ .from = .{ .tick = 0, .wall = null } },
        .{ .leash = .{ .tick = 1041, .dog = 219 } },
        .{ .release = .{ .tick = 1121, .dog = 249 } },
        .{ .grab = 7 },
        .{ .letgo = 1042 },
        .{ .rest = 9 },
        .{ .held = .{ .tick = 1041, .tiles = tileSet(&.{ .{ 31, 34 }, .{ 0, 0 }, .{ 63, 63 } }) } },
        .{ .view = .{ .tick = 1041, .w = 1280, .h = 800, .tiles = tileSet(&.{ .{ 31, 34 }, .{ 32, 34 } }) } },
        .{ .view = .{ .tick = 2, .w = 0, .h = 0, .tiles = .{} } },
        .{ .t = .{ .tick = 1041, .ms = 0, .drag = drag } },
        .{ .t = .{ .tick = 1042, .ms = 63, .drag = .{} } },
        .{ .critter = .{ .who = .dog(223), .before = .{ .x = 0x42d200, .y = 0x46d200 }, .after = .{ .x = 0x42d1f0, .y = 0x46d200 } } },
        .{ .critter = .{ .who = .cow(49), .before = .{ .x = 0, .y = physics.world - 1 }, .after = .{ .x = 1, .y = 255 } } },
        .{ .bump = .{ .tick = 5, .who = .cow(0) } },
        .{ .bump = .{ .tick = 5, .who = .dog(17) } },
    };
    for (lines) |l| try roundTrip(l);
}

test "random critter lines and drags round-trip (seeded)" {
    var prng: std.Random.DefaultPrng = .init(29);
    const rand = prng.random();
    for (0..5000) |_| {
        const who: physics.Critter = if (rand.boolean()) .dog(rand.uintLessThan(u16, physics.dog_count)) else .cow(rand.uintLessThan(u16, physics.cow_count));
        const p = struct {
            fn any(r: std.Random) physics.Point {
                return .{ .x = r.intRangeLessThan(i32, 0, physics.world), .y = r.intRangeLessThan(i32, 0, physics.world) };
            }
        };
        try roundTrip(.{ .critter = .{ .who = who, .before = p.any(rand), .after = p.any(rand) } });
        var raw: [20]physics.Disp = undefined;
        const n = rand.uintAtMost(usize, raw.len);
        for (raw[0..n]) |*r| r.* = .{ .dx = rand.intRangeAtMost(i32, -physics.cap, physics.cap), .dy = rand.intRangeAtMost(i32, -physics.cap, physics.cap), .ms = rand.int(u16) };
        try roundTrip(.{ .t = .{ .tick = rand.int(u32), .ms = rand.int(u16), .drag = physics.mergeAndCap(raw[0..n]) } });
    }
}

test "every other spelling is refused: padding, upper case, +0.00, short or long fractions, stray spaces, leading zeros" {
    for ([_][]const u8{
        // Positions.
        " dog 223 042d2.00,46d2.00 > 42d1.f0,46d2.00",
        " dog 223 42D2.00,46d2.00 > 42d1.f0,46d2.00",
        " dog 223 42d2.0,46d2.00 > 42d1.f0,46d2.00",
        " dog 223 42d2.000,46d2.00 > 42d1.f0,46d2.00",
        " dog 223 42d2,46d2.00 > 42d1.f0,46d2.00",
        " dog 223 .00,46d2.00 > 42d1.f0,46d2.00",
        " dog 223 00.00,46d2.00 > 42d1.f0,46d2.00",
        " dog 223 -1.00,46d2.00 > 42d1.f0,46d2.00",
        " dog 223 7d00.00,46d2.00 > 42d1.f0,46d2.00",
        " dog 223 42d2.00,46d2.00 >  42d1.f0,46d2.00",
        " dog 223 42d2.00,46d2.00 > 42d1.f0,46d2.00 ",
        "  dog 223 42d2.00,46d2.00 > 42d1.f0,46d2.00",
        "dog 223 42d2.00,46d2.00 > 42d1.f0,46d2.00",
        " dog 223 42d2.00 46d2.00 > 42d1.f0,46d2.00",
        " dog 0223 42d2.00,46d2.00 > 42d1.f0,46d2.00",
        " dog 250 42d2.00,46d2.00 > 42d1.f0,46d2.00",
        " cow 50 42d2.00,46d2.00 > 42d1.f0,46d2.00",
        " Dog 223 42d2.00,46d2.00 > 42d1.f0,46d2.00",
        // Displacements.
        "t 1041 +0 drag +0.00,0@3",
        "t 1041 +0 drag -0.00,0@3",
        "t 1041 +0 drag +0,0@3",
        "t 1041 +0 drag 1.00,0@3",
        "t 1041 +0 drag +01.00,0@3",
        "t 1041 +0 drag +64.01,0@3",
        "t 1041 +0 drag -1.00,0",
        "t 1041 +0 drag -1.00,0@03",
        "t 1041 +0 drag",
        "t 1041 +0 drag ",
        "t 1041 +0  drag -1.00,0@3",
        "t 1041 0",
        "t 1041 +00",
        "t 01041 +0",
        "t 1041",
        "t 1041 +0 drag 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1 0,0@1",
        // The header and the rest.
        "dogpark 1 physics 5E0C91A2 page 1791935990000.3 req 4",
        "dogpark 1 physics 5e0c91a page 1791935990000.3 req 4",
        "dogpark 1 physics 5e0c91a2 page 1791935990000 req 4",
        "dogpark 01 physics 5e0c91a2 page 1791935990000.3 req 4",
        "dogpark 1 physics 5e0c91a2 page 1791935990000.3 req 4 ",
        "from 1040 wall",
        "from 1040 wal 5",
        "leash 1041",
        "leash 1041 219 7",
        "leash 1041 250",
        "letgo",
        "letgo 1042 1",
        "rest 1042 x",
        "bump 1042 dog",
        "bump 1042 horse 3",
        "held 1041 31,34 31,34",
        "held 1041 64,0",
        "held 1041 31,-1",
        "held 1041 31.34",
        "held 1041 31,34 ",
        "view 1041 1280 31,34",
        "view 1041 1280x 31,34",
        "view 1041 x800",
        "",
        "kept 1041",
        "release 1041 07",
    }) |text| try refused(text);
}

test "a view holds at most 64 tiles: 64 parse, 65 are refused" {
    var buf: [2048]u8 = undefined;
    var w: Text = .{ .buf = &buf };
    try w.str("view 1 1920x1080");
    for (0..64) |i| {
        try w.char(' ');
        try w.dec(i % 64);
        try w.str(",3");
    }
    const v = try wire.parse(w.bytes());
    try testing.expectEqual(@as(usize, 64), v.view.tiles.len);
    try w.str(" 0,4");
    try refused(w.bytes());
}

test "the lines of a text: split on \\n, a last line without one still a line, an empty line returned for the caller to refuse" {
    var it: wire.Lines = .{ .rest = "a\n\nb" };
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("", it.next().?);
    try testing.expectEqualStrings("b", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "tile lists compare as sets" {
    const a: wire.Line = .{ .held = .{ .tick = 1, .tiles = tileSet(&.{ .{ 1, 2 }, .{ 3, 4 } }) } };
    const b: wire.Line = .{ .held = .{ .tick = 1, .tiles = tileSet(&.{ .{ 3, 4 }, .{ 1, 2 } }) } };
    const c: wire.Line = .{ .held = .{ .tick = 1, .tiles = tileSet(&.{.{ 3, 4 }}) } };
    try testing.expect(wire.same(a, b));
    try testing.expect(!wire.same(a, c));
}

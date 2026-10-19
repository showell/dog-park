//! **THE GOLDEN RUNS**: the physics, played, is what it was. Eight drags
//! from the first layout, one leashed dog each (two of every breed), each
//! a seeded wander of up to 100 px a tick through the park, and one long
//! drag; the board hashed after each. They guard the physics' mechanisms
//! against a change meant to change nothing (a refactor, a speed-up).
//!
//! **THEY ARE THE CONFIGURATION'S**: recorded under one world and one set
//! of rules (world.zon, rules.zon, whose hash is `recorded_under`). With
//! another, the game is another game, and they step aside, saying so; a
//! new configuration records its own with `print`. A change meant to
//! change the physics itself records new ones too, with its reason.

const std = @import("std");
const physics = @import("physics.zig");
const Board = physics.Board;

/// Set to print the hashes, and the configuration's, instead of checking
/// them (a new configuration, or a change meant to change the physics).
const print = false;

/// The configuration the hashes were recorded under: world.zon and
/// rules.zon, hashed.
pub const recorded_under: u64 = 0x6ca22f616825fcf5;

/// Steps a recording's test aside under another configuration than the
/// one it was recorded under, saying which recording.
pub fn recordedOrSkip(what: []const u8) error{SkipZigTest}!void {
    if (configuration() == recorded_under) return;
    std.debug.print("{s} steps aside: world.zon or rules.zon is not the configuration it was recorded under\n", .{what});
    return error.SkipZigTest;
}

pub fn configuration() u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(@embedFile("world.zon"));
    h.update(@embedFile("rules.zon"));
    return h.final();
}

const dogs = [8]u16{ 0, 1, 2, 3, 21, 22, 41, 63 };
const ticks = 48;
/// The long run: dog 0 for `long_ticks`, its trail long enough that the
/// herd poops where poop already lies (the ring search) and the chickens
/// forage from afar.
const long_ticks = 400;

const want = [dogs.len + 1]u64{ 0x9a6f4cc5e0f7d950, 0x0922e18850956701, 0x79296e971270c533, 0x7498728c4fc05b73, 0xd8b5463f11b4706d, 0xabc940c5e9df6132, 0xc70b495e4247cbad, 0x25df35e820144db2, 0x9c9252a180ce81c2 };

fn hashOf(b: *const Board) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.sliceAsBytes(&b.points));
    h.update(std.mem.sliceAsBytes(&b.known_at));
    h.update(std.mem.sliceAsBytes(&b.walked));
    h.update(std.mem.sliceAsBytes(&b.poops));
    h.update(std.mem.sliceAsBytes(&b.poop_known));
    h.update(std.mem.asBytes(&b.laid));
    return h.final();
}

/// Dog `dog` leashed in the first layout and dragged `ticks` ticks: a
/// heading that turns now and then, a step of 20 to 100 px on each axis.
fn played(dog: u16, n_ticks: physics.Tick) u64 {
    var b = Board.laidOut();
    b.hold = .{ .leashed = .{ .dog = dog, .drag = .on } };
    var rng = std.Random.DefaultPrng.init(0x5eed_0000 + @as(u64, dog));
    const r = rng.random();
    var hx: i32 = 1;
    var hy: i32 = 0;
    var lines: physics.Lines = .{};
    var t: physics.Tick = 1;
    while (t <= n_ticks) : (t += 1) {
        if (r.uintLessThan(u8, 4) == 0) {
            hx = r.intRangeAtMost(i32, -1, 1);
            hy = r.intRangeAtMost(i32, -1, 1);
            if (hx == 0 and hy == 0) hx = 1;
        }
        const drag = [1]physics.Disp{.{ .dx = physics.px(hx * r.intRangeAtMost(i32, 20, 100)), .dy = physics.px(hy * r.intRangeAtMost(i32, 20, 100)) }};
        if (physics.tick(&b, t, &.{}, &drag, &lines)) |refusal| std.debug.panic("refused: {t}", .{refusal});
    }
    return hashOf(&b);
}

test "the golden runs: under the configuration they were recorded for, eight drags and a long one come out as recorded" {
    if (!print and configuration() != recorded_under) {
        std.debug.print("the golden runs step aside: world.zon or rules.zon is not the configuration they were recorded under (record anew with `print`)\n", .{});
        return error.SkipZigTest;
    }
    var got: [dogs.len + 1]u64 = undefined;
    for (dogs, got[0..dogs.len]) |dog, *h| h.* = played(dog, ticks);
    got[dogs.len] = played(0, long_ticks);
    if (print) {
        std.debug.print("const want = [dogs.len + 1]u64{{", .{});
        for (got) |h| std.debug.print(" 0x{x:0>16},", .{h});
        std.debug.print(" }};\npub const recorded_under: u64 = 0x{x:0>16};\n", .{configuration()});
        return;
    }
    try std.testing.expectEqual(want, got);
}

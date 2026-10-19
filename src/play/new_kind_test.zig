//! **A NEW KIND, MADE IN ROC ALONE** (metal-vmm QUEUE 240; sheep since the park has goats): this test
//! runs only in the sheep world, a copy of this repository with
//! test/new_kind/sheep.patch applied, which touches nothing but roc/*.roc
//! (`zig build new-kind`, tools/new_kind.sh: the patch, then `zig
//! build roc` there, then this). The Zig is these same files, byte for
//! byte; only world.zon, rules.zon and the Roc built are the sheep
//! world's. In this repository's own world there are no sheep, and it
//! steps aside.

const std = @import("std");
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const testing = std.testing;

const has_sheep = @hasField(physics.Kind, "sheep");

test "a new kind, made in Roc alone: laid out, walked with the herds, never overlapping, and written and read on the wire by its name" {
    if (!has_sheep) {
        std.debug.print("the new kind's test steps aside: this world has no sheep (zig build new-kind makes one)\n", .{});
        return error.SkipZigTest;
    }
    const sheep: physics.Kind = @field(physics.Kind, "sheep");
    try testing.expectEqual(@as(usize, 5), physics.kind_count);
    try testing.expect(physics.countOf(sheep) > 0);

    // Laid out, every sheep present at its home.
    var b = physics.Board.laidOut();
    for (b.knownOf(sheep)) |k| try testing.expectEqual(physics.Known.present, k);
    const start: [physics.countOf(sheep)]physics.Point = b.of(sheep)[0..physics.countOf(sheep)].*;

    // Seeded drags through the park, as the invariant test drags: nobody
    // ever overlaps anybody, and some sheep move (they keep from dogs and
    // herd with sheep).
    var prng: std.Random.DefaultPrng = .init(240);
    const rand = prng.random();
    var lines: physics.Lines = .{};
    try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, 1, &.{.{ .leash = 25 }}, &.{}, &lines));
    var found: [8][2]physics.Critter = undefined;
    var heading: [2]i32 = .{ 10, 4 };
    var t: physics.Tick = 2;
    var sheep_lines: usize = 0;
    while (t < 400) : (t += 1) {
        if (rand.uintLessThan(u32, 16) == 0) heading = .{ rand.intRangeAtMost(i32, -12, 12), rand.intRangeAtMost(i32, -12, 12) };
        const drag = [1]physics.Disp{.{ .dx = physics.px(heading[0] + rand.intRangeAtMost(i32, -3, 3)), .dy = physics.px(heading[1] + rand.intRangeAtMost(i32, -3, 3)), .ms = 62 }};
        const humans: []const physics.Human = if (b.hold == .leashed and b.hold.leashed.drag != .on) &.{.grab} else &.{};
        try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, t, humans, &drag, &lines));
        try testing.expectEqual(@as(usize, 0), physics.overlaps(&b, &found));
        for (lines.slice()) |l| switch (l) {
            .critter => |c| if (c.who.kind == sheep) {
                sheep_lines += 1;
            },
            else => {},
        };
    }
    var moved: usize = 0;
    for (start, b.of(sheep)) |was, now| {
        if (was.x != now.x or was.y != now.y) moved += 1;
    }
    try testing.expect(moved > 0 and sheep_lines > 0);
    std.debug.print("the new kind: {d} sheep, {d} moved, {d} sheep lines over {d} ticks, no overlaps\n", .{ physics.countOf(sheep), moved, sheep_lines, t });

    // On the wire a sheep is `sheep N`, read back as itself.
    var buf: [64]u8 = undefined;
    var w: wire.Text = .{ .buf = &buf };
    try w.critter(.of(sheep, 3));
    try testing.expectEqualStrings("sheep 3", w.bytes());
}

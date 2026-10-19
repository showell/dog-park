//! A compile probe, not the page's wiring: the physics, its wire and the
//! server's re-run compiled to wasm32-freestanding (`zig build
//! physics-wasm`), with fixed buffers and no allocator, so nothing in them
//! needs what the page's target lacks. The page's exports come later.

const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const judge = @import("physics_judge.zig");

var board: physics.Board = undefined;
var kept: judge.Kept = undefined;
var text: [64 * 1024]u8 = undefined;
var answer: [64 * 1024]u8 = undefined;
var lines: physics.Lines = .{};

/// One tick of the laid-out park with dog `dog` leashed and dragged.
export fn probeTick(dog: u32, dx: i32, dy: i32) u32 {
    board = physics.Board.laidOut();
    board.hold = .{ .leashed = .{ .dog = @intCast(dog % physics.countOf(.dog)), .drag = .on } };
    const drag = physics.mergeAndCap(&.{.{ .dx = dx, .dy = dy }});
    _ = physics.tick(&board, 1, &.{}, drag.slice(), &lines);
    var w: wire.Text = .{ .buf = &text };
    for (lines.slice()) |c| wire.write(&w, wire.checkedLine(1, c)) catch return 0;
    return @intCast(w.len);
}

/// The server's re-run of the report in `text[0..len]`.
export fn probeJudge(len: u32, hash: u32) u32 {
    kept = .{ .tick = 0, .board = physics.Board.laidOut() };
    var out: wire.Text = .{ .buf = &answer };
    var findings: judge.Findings = .{};
    _ = judge.judge(&kept, hash, text[0..@min(len, text.len)], &out, &findings) catch return 0;
    return @intCast(out.len);
}

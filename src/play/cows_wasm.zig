//! The cows' rule for the page (cows.wasm): cows.zig itself, compiled to
//! wasm32, so the page predicts a cow exactly as the server moves it, the
//! same arithmetic and the same rounding. The page writes the cows it knows
//! into `positions` (park_x, park_y each), asks `react` for each move the
//! server has yet to answer, in the order the server will take them, and
//! reads them back.

const cows = @import("cows.zig");

var positions: [cows.cow_count * 2]i32 = undefined;

/// Where the page writes and reads the cows: `count` pairs of park_x, park_y.
export fn cowPositions() [*]i32 {
    return &positions;
}

/// The most cows `positions` holds.
export fn cowCapacity() u32 {
    return cows.cow_count;
}

/// A dog moved from (from_x, from_y) to (to_x, to_y): the first `count` cows
/// react, as the server's `Cows.react` moves them.
export fn react(count: u32, from_x: i32, from_y: i32, to_x: i32, to_y: i32) void {
    const n = @min(count, cows.cow_count);
    for (0..n) |i| {
        switch (cows.reaction(.{ .park_x = from_x, .park_y = from_y }, .{ .park_x = to_x, .park_y = to_y }, .{ .park_x = positions[2 * i], .park_y = positions[2 * i + 1] })) {
            .stays => {},
            .steps_to => |p| {
                positions[2 * i] = p.park_x;
                positions[2 * i + 1] = p.park_y;
            },
        }
    }
}

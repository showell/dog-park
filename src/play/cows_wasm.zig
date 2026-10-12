//! The cows' rule for the page (cows.wasm): cows.zig itself, compiled to
//! wasm32, so the page predicts a cow exactly as the server moves it. The
//! page writes the cows it knows into `cowPositions` (half_x, half_y each,
//! i32) and a move's points into `pathPoints` (park_x, park_y each, i32:
//! where the server has the dog, then the path), calls `replay`, and reads
//! the cows back.

const dogs = @import("dogs.zig");
const cows = @import("cows.zig");

var positions: [cows.cow_count]cows.CowPoint = undefined;
var raw_points: [1 + dogs.most_path_points][2]i32 = undefined;
var points: [1 + dogs.most_path_points]dogs.ParkPoint = undefined;

/// Where the page writes and reads the cows: pairs of i32, half pixels.
export fn cowPositions() [*]i32 {
    return @ptrCast(&positions);
}

/// The most cows `cowPositions` holds.
export fn cowCapacity() u32 {
    return cows.cow_count;
}

/// Where the page writes a move's points: pairs of i32, park pixels.
export fn pathPoints() [*]i32 {
    return @ptrCast(&raw_points);
}

/// The most points `pathPoints` holds.
export fn pathCapacity() u32 {
    return raw_points.len;
}

/// A move, as the server's /move replays it: the first `count` cows react to
/// the path of `n` points (cows.replay).
export fn replay(count: u32, n: u32) void {
    const m = @min(n, raw_points.len);
    for (raw_points[0..m], points[0..m]) |r, *p| p.* = .{ .park_x = r[0], .park_y = r[1] };
    cows.replay(positions[0..@min(count, cows.cow_count)], points[0..m], null);
}

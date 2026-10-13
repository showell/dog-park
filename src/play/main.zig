//! Dog Park, played, as a Linux process: webbox's Linux host with the play
//! server (app.zig). Run it from the checkout, which holds the page (`solo/`).
//!
//! Run:  zig build play       (serves on http://localhost:9103)

const std = @import("std");
const webbox = @import("webbox");
const hosted = @import("hosted.zig");

pub const site = hosted.site;

pub fn main(init: std.process.Init.Minimal) !void {
    try @import("webbox_linux").linux_host.Server(site).run(init, .{
        .name = "dog-park-play",
        .env = .{
            .port = "DOGPARK_PORT",
            .bind = "DOGPARK_BIND",
            .config = "DOGPARK_CONFIG",
            .trusted_proxy = "DOGPARK_TRUSTED_PROXY",
            .keepalive_ms = "DOGPARK_KEEPALIVE_MS",
        },
        .default_port = 9103,
        .default_trusted_proxy = "127.0.0.1",
        .default_auth_dir = "~/DogParkAuth",
        .routes_hint = "(/, /*.js, /physics-H.wasm, GET /me, POST /tiles, /leash, /release, /move, /viewport, /load, /report)",
        .free_space = unread,
    }, report);
}

/// No floor on the data volume's free space: one small file, rewritten.
fn unread(_: *const std.process.Environ.Map) webbox.free_space.FreeSpace {
    return .unknown;
}

fn report(started: *const site.Started) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    hosted.hosting.describeStart(started.app, &w) catch @panic("Dog Park's start report is past its 1 KiB buffer (hosted.hosting.describeStart)");
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, w.buffered(), "\n"), '\n');
    while (lines.next()) |line| std.debug.print("dog-park-play: {s}\n", .{line});
}

//! Dog Park served as a Linux process: webbox's Linux host (linux_host.zig)
//! with Dog Park's name, its environment variables (DOGPARK_*), its default
//! port, and the lines its setup's report prints.
//!
//! Run:  zig build run        (serves on http://localhost:9101)

const std = @import("std");
const webbox = @import("webbox");
const app = @import("app.zig");

/// Dog Park as webbox serves it: what the Linux host calls.
pub const site = webbox.site.Site(app);

pub fn main(init: std.process.Init.Minimal) !void {
    try webbox.linux_host.Server(site).run(init, .{
        .name = "dog-park",
        .env = .{
            .port = "DOGPARK_PORT",
            .bind = "DOGPARK_BIND",
            .config = "DOGPARK_CONFIG",
            .trusted_proxy = "DOGPARK_TRUSTED_PROXY",
            .keepalive_ms = "DOGPARK_KEEPALIVE_MS",
        },
        .default_port = 9101,
        // Caddy, on the same machine.
        .default_trusted_proxy = "127.0.0.1",
        .default_auth_dir = "~/DogParkAuth",
        .routes_hint = "(/, /park.js, POST /scene)",
        // Every body is read before the turn, up to this (webbox, metal-vmm
        // QUEUE 162): a scene request is the only one with a body.
        .largest_body = app.longest_body,
        .free_space = unread,
    }, report);
}

/// Dog Park sets no floor on the data volume's free space: a dog's record is
/// 24 bytes, rewritten in place.
fn unread(_: *const std.process.Environ.Map) webbox.free_space.FreeSpace {
    return .unknown;
}

fn report(started: *const site.Started) void {
    const r = started.app;
    std.debug.print("dog-park: {d} dog(s) loaded from {s}/dogs\n", .{ r.dogs, r.data_dir });
    if (r.left_over > 0) std.debug.print("dog-park: passed over {d} temporary file(s) a stopped write left in {s}/dogs\n", .{ r.left_over, r.data_dir });
    switch (r.secret) {
        .found => {},
        .created => std.debug.print("dog-park: no signing secret was found, so one was created\n", .{}),
    }
}

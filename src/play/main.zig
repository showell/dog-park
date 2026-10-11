//! Dog Park, played, as a Linux process: webbox's Linux host with the play
//! server (app.zig). Run it from the checkout, which holds the page (`solo/`).
//!
//! Run:  zig build play       (serves on http://localhost:9103)

const std = @import("std");
const webbox = @import("webbox");
const app = @import("app.zig");

pub const site = webbox.site.Site(app);

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
        .routes_hint = "(/, /park.js, GET /me, POST /tiles, /leash, /release, /move, /viewport)",
        .free_space = unread,
    }, report);
}

/// No floor on the data volume's free space: one small file, rewritten.
fn unread(_: *const std.process.Environ.Map) webbox.free_space.FreeSpace {
    return .unknown;
}

fn report(started: *const site.Started) void {
    const r = started.app;
    switch (r.dogs) {
        .loaded => std.debug.print("dog-park-play: the dogs loaded from {s}\n", .{r.dogs_path}),
        .laid_out => std.debug.print("dog-park-play: no dogs were kept, so they were laid out afresh in {s}\n", .{r.dogs_path}),
    }
    switch (r.secret) {
        .found => {},
        .created => std.debug.print("dog-park-play: no signing secret was found, so one was created\n", .{}),
    }
}

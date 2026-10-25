//! Dog Park and the TODO list served together: webbox's Linux host with
//! src/combos/dogpark_todo.zig.
//!
//! Run:  zig build serve-dogpark-todo   (on http://localhost:9113)

const std = @import("std");
const webbox = @import("webbox");
const combo = @import("dogpark_todo.zig");

pub const site = combo.site;
pub const roc_hooks = combo.roc_hooks;

pub fn main(init: std.process.Init.Minimal) !void {
    var env = try std.process.Environ.createMap(init.environ, std.heap.page_allocator);
    defer env.deinit();
    // As Dog Park's own main: plain-http development only.
    if (env.get("DOGPARK_INSECURE_COOKIE")) |v| {
        if (!std.mem.eql(u8, v, "yes")) {
            std.debug.print("dogpark-todo: DOGPARK_INSECURE_COOKIE is \"{s}\": unset it, or set it to yes for plain-http development\n", .{v});
            return error.BadInsecureCookieSetting;
        }
        @import("dog_park").insecureCookie();
    }
    try @import("webbox_linux").linux_host.Server(site).run(init, .{
        .name = "dogpark-todo",
        .env = .{
            .port = "COMBO_PORT",
            .bind = "COMBO_BIND",
            .config = "COMBO_CONFIG",
            .trusted_proxy = "COMBO_TRUSTED_PROXY",
            .keepalive_ms = "COMBO_KEEPALIVE_MS",
        },
        .default_port = 9113,
        .default_trusted_proxy = "127.0.0.1",
        .default_auth_dir = "auth",
        .routes_hint = "(Dog Park at /, the TODO list at /todo/)",
        .free_space = unread,
    }, report);
}

fn unread(_: *const std.process.Environ.Map) webbox.free_space.FreeSpace {
    return .unknown;
}

fn report(started: *const site.Started) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    combo.hosting.describeStart(started.app, &w) catch @panic("the start report is past its 1 KiB buffer");
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, w.buffered(), "\n"), '\n');
    while (lines.next()) |line| std.debug.print("dogpark-todo: {s}\n", .{line});
}

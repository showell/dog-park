//! **DOG PARK, AS A HOST TAKES IT** (webbox's Phase B contract): the play
//! server's `site` (its webbox Site) and `hosting` (what only it can say about
//! itself). Linux's main (main.zig) and zig-metal-unikernel's kernel both host this.

const std = @import("std");
const webbox = @import("webbox");
const app = @import("app.zig");

pub const site = webbox.site.Site(app);

pub const hosting = struct {
    /// What the application is called, where a host names it (metal's boot
    /// banner: "Dog Park's route table").
    pub const name = "Dog Park";
    /// What its data is called, where a host names it.
    pub const data_name = "Dog Park's data";
    /// The largest file a plain read takes whole: the page and its scripts
    /// (app.zig reads each at most 1 MiB).
    pub const whole_read_max = 1024 * 1024;
    /// The largest file worth keeping whole in a host's page cache: the same.
    pub const cache_largest_most = 1024 * 1024;
    /// Its setup's report, a line each, for the host's log.
    pub fn describeStart(r: app.StartReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} of {d} accounts handed out; the site secret {s}; cookies {s}\n", .{ r.claimed, @import("players.zig").most_players, switch (r.secret) {
            .found => "found",
            .made => "made anew",
        }, switch (r.cookie_mode) {
            .secure => "__Host-dogpark, Secure (behind HTTPS)",
            .insecure => "dogpark, NOT Secure (DOGPARK_INSECURE_COOKIE=yes: plain-http development only)",
        } });
        try w.print("the games: {s}/game-<slot>, each started at its player's first load\n", .{r.data_dir});
        try w.print("the operator's pages at /admin: the admin key {s} (the auth folder's _admin_key)\n", .{switch (r.admin_key) {
            .found => "found",
            .made => "made anew",
        }});
    }
};

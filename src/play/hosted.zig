//! **DOG PARK, AS A HOST TAKES IT** (webbox's Phase B contract): the play
//! server's `site` (its webbox Site) and `hosting` (what only it can say about
//! itself). Linux's main (main.zig) and zig-metal-unikernel's kernel both host this.

const std = @import("std");
const webbox = @import("webbox");
const app = @import("app.zig");

pub const site = webbox.site.Site(app);

pub const hosting = struct {
    /// What its data is called, where a host names it.
    pub const data_name = "Dog Park's data";
    /// The largest file a plain read takes whole: the page and its scripts
    /// (app.zig reads each at most 1 MiB).
    pub const whole_read_max = 1024 * 1024;
    /// The largest file worth keeping whole in a host's page cache: the same.
    pub const cache_largest_most = 1024 * 1024;
    /// Its setup's report, a line each, for the host's log.
    pub fn describeStart(r: app.StartReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (r.old_seed) {
            .none => {},
            .ignored => try w.print("an older server's dogs.json or cows.json is in {s}: ignored (the park starts from the first layout)\n", .{r.data_dir}),
        }
        switch (r.physics.board) {
            .applied => |a| try w.print("the physics' board came back from its snapshot and {d} log entries ({d} torn bytes dropped), kept through tick {d}\n", .{ a.entries, a.torn_bytes, r.physics.kept }),
            .resolved => |n| try w.print("the physics' board was resolved afresh from the first layout ({d} moved to clear overlaps)\n", .{n}),
        }
    }
};

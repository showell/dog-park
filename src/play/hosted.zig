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
    /// The largest file a plain read takes whole: the page and its script,
    /// and the dogs' file (app.zig reads each at most 1 MiB).
    pub const whole_read_max = 1024 * 1024;
    /// The largest file worth keeping whole in a host's page cache: the same.
    pub const cache_largest_most = 1024 * 1024;
    /// Its setup's report, a line each, for the host's log.
    pub fn describeStart(r: app.StartReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (r.dogs) {
            .loaded => try w.print("the dogs loaded from {s}\n", .{r.dogs_path}),
            .laid_out => try w.print("no dogs were kept, so they were laid out afresh in {s}\n", .{r.dogs_path}),
        }
        switch (r.cows) {
            .loaded => try w.print("the cows loaded from {s}\n", .{r.cows_path}),
            .laid_out => try w.print("no cows were kept, so they were laid out afresh in {s}\n", .{r.cows_path}),
        }
        switch (r.physics.board) {
            .applied => |a| try w.print("the physics' board came back from its snapshot and {d} log entries ({d} torn bytes dropped), kept through tick {d}\n", .{ a.entries, a.torn_bytes, r.physics.kept }),
            .resolved => |n| try w.print("the physics' board was resolved afresh from the dogs and cows ({d} moved to clear overlaps)\n", .{n}),
        }
    }
};

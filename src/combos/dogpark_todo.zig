//! **DOG PARK AND THE TODO LIST, AS A HOST TAKES THEM** (webbox's combo):
//! the park keeps `/` and everything else; the list (../roc-webbox) is
//! mounted at `/todo`, with its files in `<data>/todo` and `<auth>/todo`.
//! Linux's main (dogpark_todo_main.zig) and zig-metal-unikernel's kernel
//! both host this, and each forwards `roc_hooks` from its own root.

const webbox = @import("webbox");

const combined = webbox.combo.Mount(@import("dog_park"), &.{
    .{ .prefix = "/todo", .root = @import("roc_todo") },
});
pub const site = combined.site;
pub const hosting = combined.hosting;
/// Roc's runtime for both apps (roc-webbox's src/roc_hooks.zig), which they
/// look for in the binary's root.
pub const roc_hooks = @import("roc_hooks");

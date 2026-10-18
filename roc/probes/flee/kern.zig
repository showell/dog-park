const Step = extern struct { x: i32, y: i32 };
extern fn roc_flee(dx: i32, dy: i32, cx: i32, cy: i32) callconv(.c) Step;
export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) noreturn {
    _ = bytes;
    _ = len;
    @trap();
}
export fn _start() callconv(.c) noreturn {
    const s = roc_flee(0, 0, 100 * 256, 0);
    if (s.x != 101 * 256) @trap();
    while (true) {}
}

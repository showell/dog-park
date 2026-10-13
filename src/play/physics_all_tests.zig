//! Every physics test, on its own root: `zig build physics-wasm` runs them
//! compiled to wasm32 (wasi), so the page's target answers as the server's.
//! physics_identity_test.zig is not among them: `zig build slow` runs it.
test {
    _ = @import("physics.zig");
    _ = @import("layout.zig");
    _ = @import("physics_wire.zig");
    _ = @import("physics_judge.zig");
    _ = @import("physics_page.zig");
}

//! **EVERY TEST**, on one root: `zig build test` runs every file's tests
//! from here (the physics' own root, physics_all_tests.zig, is the one the
//! wasm32 run and `zig build physics-test` take).

test {
    _ = @import("tiles.zig");
    _ = @import("app.zig");
    _ = @import("admin.zig");
    _ = @import("shale.zig");
    _ = @import("players.zig");
    _ = @import("physics_all_tests.zig");
    _ = @import("physics_log.zig");
    _ = @import("physics_server.zig");
}

test "the webbox library is reachable" {
    const webbox = @import("webbox");
    try @import("std").testing.expectEqualStrings("/a.js", webbox.http.pathOf("/a.js?h=00"));
}

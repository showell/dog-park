//! Dog Park: everybody owns a dog and drags it around a park. Its data
//! types, one module a concept (docs/TYPES-BRIEF.md).

pub const frames = @import("frames.zig");
pub const park = @import("park.zig");
pub const humans = @import("humans.zig");
pub const dogs = @import("dogs.zig");
pub const population = @import("population.zig");
pub const scene = @import("scene.zig");
pub const outcomes = @import("outcomes.zig");
pub const stored = @import("stored.zig");
pub const wire = @import("wire.zig");
pub const index = @import("index.zig");
pub const placement = @import("placement.zig");
pub const world = @import("world.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

test "the webbox library is reachable" {
    const webbox = @import("webbox");
    try @import("std").testing.expectEqualStrings("/a.js", webbox.http.pathOf("/a.js?h=00"));
}

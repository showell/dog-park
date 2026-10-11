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

test {
    @import("std").testing.refAllDecls(@This());
}

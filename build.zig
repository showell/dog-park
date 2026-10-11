const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Every file's tests run from the package root, src/dog_park.zig, which
    // names each module.
    const root = b.createModule(.{
        .root_source_file = b.path("src/dog_park.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}

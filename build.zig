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
    // webbox is two modules: `webbox`, portable, what the application's code
    // imports; and `webbox_linux`, the Linux host, for a Linux `main` only.
    const webbox_dep = b.dependency("webbox", .{ .target = target, .optimize = optimize });
    const webbox = webbox_dep.module("webbox");
    const webbox_linux = webbox_dep.module("webbox_linux");
    // `host_io`: the one file the application's sources take their `Io`
    // from, std's here; a metal kernel hands the same files its own.
    const host_io = webbox_dep.module("host_io");
    root.addImport("webbox", webbox);
    root.addImport("host_io", host_io);
    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);

    // The Linux server: zig build run, then a browser at localhost:9101.
    const main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main.addImport("webbox", webbox);
    main.addImport("webbox_linux", webbox_linux);
    const exe = b.addExecutable(.{ .name = "dog-park", .root_module = main });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Serve Dog Park on localhost:9101").dependOn(&run.step);

    // The play server, for solo/: zig build play, from the checkout.
    const play_main = b.createModule(.{
        .root_source_file = b.path("src/play/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    play_main.addImport("webbox", webbox);
    play_main.addImport("host_io", host_io);
    play_main.addImport("webbox_linux", webbox_linux);
    const play_exe = b.addExecutable(.{ .name = "dog-park-play", .root_module = play_main });
    b.installArtifact(play_exe);
    const play_run = b.addRunArtifact(play_exe);
    if (b.args) |args| play_run.addArgs(args);
    b.step("play", "Serve the played Dog Park (solo/) on localhost:9103").dependOn(&play_run.step);
}

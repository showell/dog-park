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

    // **THE COWS' RULE FOR THE PAGE**: cows.zig compiled to wasm32, so the
    // page predicts a cow with the server's own arithmetic. Installed to
    // zig-out/web/cows.wasm, where assets.zon's `.embedded` names it for a
    // kernel's build (zig-metal-unikernel), and compiled into this build's play
    // server by the same name.
    const cows_wasm = b.addExecutable(.{ .name = "cows", .root_module = b.createModule(.{
        .root_source_file = b.path("src/play/cows_wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSafe,
        .strip = true,
    }) });
    cows_wasm.entry = .disabled;
    cows_wasm.rdynamic = true;
    b.getInstallStep().dependOn(&b.addInstallArtifact(cows_wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    root.addAnonymousImport("cows.wasm", .{ .root_source_file = cows_wasm.getEmittedBin() });
    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);

    // **THE PHYSICS ON THE PAGE'S TARGET** (docs/PHYSICS.md): physics.zig,
    // its wire and the server's re-run compiled to wasm32-freestanding (a
    // compile probe, zig-out/probe/physics_probe.wasm), and every physics
    // test compiled to wasm32-wasi and run under node, so the page's
    // architecture gives the same answers as the server's.
    const physics_wasm = b.step("physics-wasm", "Compile the physics for wasm32 and run its tests there (needs node)");
    const physics_probe = b.addExecutable(.{ .name = "physics_probe", .root_module = b.createModule(.{
        .root_source_file = b.path("src/play/physics_wasm_probe.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSafe,
        .strip = true,
    }) });
    physics_probe.entry = .disabled;
    physics_probe.rdynamic = true;
    physics_wasm.dependOn(&b.addInstallArtifact(physics_probe, .{ .dest_dir = .{ .override = .{ .custom = "probe" } } }).step);
    const physics_wasi_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/play/physics_all_tests.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi }),
        .optimize = .ReleaseSafe,
    }) });
    const run_wasi = b.addSystemCommand(&.{ "node", "--no-warnings" });
    run_wasi.addFileArg(b.path("tools/run_wasi.mjs"));
    run_wasi.addArtifactArg(physics_wasi_tests);
    run_wasi.expectStdErrMatch(" tests passed.");
    run_wasi.expectExitCode(0);
    run_wasi.has_side_effects = true;
    physics_wasm.dependOn(&run_wasi.step);

    // How long a tick takes natively (ReleaseSafe, as the server runs).
    const physics_bench = b.addExecutable(.{ .name = "physics_bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/play/physics_bench.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    }) });
    b.step("physics-bench", "Time a physics tick natively (ReleaseSafe)").dependOn(&b.addRunArtifact(physics_bench).step);

    // A 32-tick report's round trip through POST /report, in process
    // (ReleaseSafe): the route, the judge's re-run, the log's append.
    const server_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/play/physics_server_bench.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const webbox_rs = b.dependency("webbox", .{ .target = target, .optimize = .ReleaseSafe });
    server_bench_mod.addImport("webbox", webbox_rs.module("webbox"));
    server_bench_mod.addImport("host_io", webbox_rs.module("host_io"));
    server_bench_mod.addAnonymousImport("cows.wasm", .{ .root_source_file = cows_wasm.getEmittedBin() });
    const server_bench = b.addExecutable(.{ .name = "physics_server_bench", .root_module = server_bench_mod });
    b.step("physics-server-bench", "Time a 32-tick report through POST /report (ReleaseSafe)").dependOn(&b.addRunArtifact(server_bench).step);

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
    play_main.addAnonymousImport("cows.wasm", .{ .root_source_file = cows_wasm.getEmittedBin() });
    const play_exe = b.addExecutable(.{ .name = "dog-park-play", .root_module = play_main });
    b.installArtifact(play_exe);
    const play_run = b.addRunArtifact(play_exe);
    if (b.args) |args| play_run.addArgs(args);
    b.step("play", "Serve the played Dog Park (solo/) on localhost:9103").dependOn(&play_run.step);
}

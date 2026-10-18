const std = @import("std");

/// How many samples the seeded fuzz loops take: `fast`, a tenth, for every
/// edit; `full` for the slow tier (`zig build slow`, or -Dfuzz=full).
const Fuzz = enum { fast, full };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fuzz = b.option(Fuzz, "fuzz", "the seeded fuzz loops' size: fast (a tenth, the default) or full") orelse .fast;
    // **-Dstamp=off**: this checkout's commit, and the kernel's two, read
    // `unstamped`, so two builds of the same code are the same bytes
    // (zig-metal-unikernel's build.zig, `Stamp`). On by default.
    const stamp = b.option(Stamp, "stamp", "on (the default): the commits baked in, for /version; off: `unstamped`, so two builds of the same code are byte-identical") orelse .on;

    // webbox is two modules: `webbox`, portable, what the application's code
    // imports; and `webbox_linux`, the Linux host, for a Linux `main` only.
    const webbox_dep = b.dependency("webbox", .{ .target = target, .optimize = optimize });
    const webbox = webbox_dep.module("webbox");
    const webbox_linux = webbox_dep.module("webbox_linux");
    // `host_io`: the one file the application's sources take their `Io`
    // from, std's here; a metal kernel hands the same files its own.
    const host_io = webbox_dep.module("host_io");
    // Shale, portable (`shale`): the park's signed scripts and its suite.
    const shale = b.dependency("shale", .{ .target = target, .optimize = optimize }).module("shale");

    // **THE PHYSICS HASH, ONCE** (physics_wire.zig): a CRC-32 over the
    // files src/play/physics_sources.zon lists, read here at configure
    // time and handed to every module that compiles the physics.
    const physics_mod = physicsOptions(b);
    // **WHICH COMMIT THIS IS** (`dogpark_build`), for /version: the
    // checkout's, `+dirty` when it has uncommitted changes.
    const build_mod = buildOptions(b, stamp);

    const wasm32 = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });

    // **THE PHYSICS FOR THE PAGE** (docs/PHYSICS.md): physics_page.zig's
    // exports over the board, the tick and the wire, compiled to wasm32
    // (ReleaseSafe, as the server runs), the very code the server judges
    // with. Installed to zig-out/web/physics.wasm, where assets.zon's
    // `.embedded` names it for a kernel's build, and compiled into this
    // build's play server by the same name, which serves it as
    // /physics-<hash>.wasm.
    const physics_page_wasm = pageWasm(b, wasm32, .ReleaseSafe, physics_mod);
    const page_wasm_install = b.addInstallArtifact(physics_page_wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    b.getInstallStep().dependOn(&page_wasm_install.step);
    const page_wasm = physics_page_wasm.getEmittedBin();
    // The same in Debug, for the fast tier alone: nothing there needs the
    // served build's speed, and it compiles in about a third of the time.
    // zig-out/web-debug/physics.wasm; `check` and `slow` test the served one.
    const debug_page_wasm = pageWasm(b, wasm32, .Debug, physics_mod);
    const debug_wasm_install = b.addInstallArtifact(debug_page_wasm, .{ .dest_dir = .{ .override = .{ .custom = "web-debug" } } });

    // The play server, for solo/: zig build play, from the checkout.
    const play_main = b.createModule(.{
        .root_source_file = b.path("src/play/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "webbox", .module = webbox },
            .{ .name = "host_io", .module = host_io },
            .{ .name = "webbox_linux", .module = webbox_linux },
            .{ .name = "shale", .module = shale },
            .{ .name = "physics_options", .module = physics_mod },
            .{ .name = "dogpark_build", .module = build_mod },
        },
    });
    play_main.addAnonymousImport("physics.wasm", .{ .root_source_file = page_wasm });
    const play_exe = b.addExecutable(.{ .name = "dog-park-play", .root_module = play_main });
    b.installArtifact(play_exe);
    const play_run = b.addRunArtifact(play_exe);
    if (b.args) |args| play_run.addArgs(args);
    b.step("play", "Serve the played Dog Park (solo/) on port 9103, every interface unless DOGPARK_BIND names one").dependOn(&play_run.step);

    // **DOG PARK ON METAL** (metal-vmm QUEUE 215): zig-metal-unikernel's
    // kernel, a sibling checkout, hosting hosted.zig's `site` in place of
    // main.zig's Linux host. The module names no target or optimize mode
    // (the kernel's) and imports neither webbox, shale nor host_io (the
    // kernel supplies its own); the physics hash and the wasm are this build's, so
    // the kernel never embeds a stale zig-out/web/physics.wasm. Its cookie
    // is Secure (app.cookie_mode's default: nothing on metal reads
    // DOGPARK_INSECURE_COOKIE). Installed to zig-out/bin/dogpark.elf.
    const metal_app = b.createModule(.{
        .root_source_file = b.path("src/play/hosted.zig"),
        .imports = &.{ .{ .name = "physics_options", .module = physics_mod }, .{ .name = "dogpark_build", .module = build_mod } },
    });
    metal_app.addAnonymousImport("physics.wasm", .{ .root_source_file = page_wasm });
    // **THE KERNEL, BESIDE THIS REPO**: ../zig-metal-unikernel, a path
    // dependency. Zig runs a path dependency's build at every configure,
    // lazy or not (measured: `zig build --help` runs its git and python
    // checks, ~0.1 s warm, ~4 s cold), so every build here needs that
    // checkout, as it needs ../zig-webbox.
    const metal_step = b.step("metal", "Build Dog Park as a zig-metal-unikernel kernel, zig-out/bin/dogpark.elf (ReleaseSafe; ../zig-metal-unikernel)");
    if (b.lazyDependency("zig_metal_unikernel", .{ .stamp = stamp })) |kernel| {
        if (b.lazyImport(@This(), "zig_metal_unikernel")) |kernel_build| {
            const dogpark_elf = kernel_build.addAppKernel(b, kernel, .{
                .name = "dogpark.elf",
                .module = metal_app,
                .assets = b.path("assets.zon"),
                .optimize = .ReleaseSafe,
            });
            metal_step.dependOn(&b.addInstallArtifact(dogpark_elf, .{}).step);
        }
    }

    // **THE QEMU GATE** (tools/metal_gate.mjs; README, "The QEMU gate"):
    // dogpark.elf booted under QEMU on a scratch disk, a short session
    // through the page's code, a reboot on the same disk. Last, before a
    // deploy; in none of test, check or slow. Its output is not captured
    // (no expectations: the exit code is the verdict), so the timings show;
    // `--summary all` gives the build's times beside the run's.
    const metal_gate = b.addSystemCommand(&.{ "node", "--no-warnings" });
    metal_gate.addFileArg(b.path("tools/metal_gate.mjs"));
    metal_gate.setCwd(b.path("."));
    metal_gate.has_side_effects = true;
    metal_gate.step.dependOn(metal_step);
    metal_gate.step.dependOn(&page_wasm_install.step);
    b.step("metal-gate", "The QEMU gate: dogpark.elf booted twice on one scratch disk, a session through the page code (last, before a deploy; ~10 s warm)").dependOn(&metal_gate.step);

    // ── the tests ───────────────────────────────────────────────────────────

    const units = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        webbox: *std.Build.Module,
        shale: *std.Build.Module,
        host_io: *std.Build.Module,
        physics_mod: *std.Build.Module,
        build_mod: *std.Build.Module,
        page_wasm: std.Build.LazyPath,

        /// Every file's tests, from src/play/all_tests.zig, natively.
        fn all(u: @This(), size: Fuzz) *std.Build.Step {
            const m = u.module("src/play/all_tests.zig", u.target, u.optimize, size);
            m.addImport("webbox", u.webbox);
            m.addImport("shale", u.shale);
            m.addImport("host_io", u.host_io);
            m.addAnonymousImport("physics.wasm", .{ .root_source_file = u.page_wasm });
            return &u.b.addRunArtifact(u.b.addTest(.{ .root_module = m })).step;
        }

        /// The physics' tests alone (physics_all_tests.zig): no webbox, no
        /// page wasm to build first.
        fn physics(u: @This(), size: Fuzz) *std.Build.Step {
            const m = u.module("src/play/physics_all_tests.zig", u.target, u.optimize, size);
            return &u.b.addRunArtifact(u.b.addTest(.{ .root_module = m })).step;
        }

        /// The physics' tests compiled to wasm32-wasi and run under node,
        /// so the page's architecture gives the server's answers; and a
        /// compile probe of the physics for wasm32-freestanding.
        fn onWasm(u: @This(), wasi_target: std.Build.ResolvedTarget, freestanding: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, size: Fuzz, step: *std.Build.Step) void {
            const probe = u.b.addExecutable(.{ .name = "physics_probe", .root_module = u.b.createModule(.{
                .root_source_file = u.b.path("src/play/physics_wasm_probe.zig"),
                .target = freestanding,
                .optimize = opt,
                .strip = true,
                .imports = &.{.{ .name = "physics_options", .module = u.physics_mod }},
            }) });
            probe.entry = .disabled;
            probe.rdynamic = true;
            step.dependOn(&probe.step);
            const tests = u.b.addTest(.{ .root_module = u.module("src/play/physics_all_tests.zig", wasi_target, opt, size) });
            const run = u.b.addSystemCommand(&.{ "node", "--no-warnings" });
            run.addFileArg(u.b.path("tools/run_wasi.mjs"));
            run.addArtifactArg(tests);
            // "All N tests passed." or "N passed; M skipped; 0 failed.": a
            // skip passes; a failure fails on the exit code.
            run.expectStdErrMatch(" passed");
            run.expectExitCode(0);
            run.has_side_effects = true;
            step.dependOn(&run.step);
        }

        fn module(u: @This(), root: []const u8, t: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, size: Fuzz) *std.Build.Module {
            const test_options = u.b.addOptions();
            test_options.addOption(Fuzz, "fuzz", size);
            return u.b.createModule(.{
                .root_source_file = u.b.path(root),
                .target = t,
                .optimize = opt,
                .imports = &.{
                    .{ .name = "physics_options", .module = u.physics_mod },
                    .{ .name = "test_options", .module = test_options.createModule() },
                    .{ .name = "dogpark_build", .module = u.build_mod },
                },
            });
        }
    }{ .b = b, .target = target, .optimize = optimize, .webbox = webbox, .shale = shale, .host_io = host_io, .physics_mod = physics_mod, .build_mod = build_mod, .page_wasm = page_wasm };

    // **NODE AGAINST A FRESH BUILD**: each node test file after the install
    // (zig-out/web/physics.wasm, zig-out/bin/dog-park-play), each its own
    // process, its exit code the verdict; the fast tier's after the Debug
    // wasm alone (DOGPARK_WASM names it to tools/lib/page_rig.mjs).
    const node_fast = [_][]const u8{ "tools/test_page_modules.mjs", "tools/test_engine.mjs" };
    const node_server = [_][]const u8{ "tools/test_page_physics.mjs", "tools/test_physics_server.mjs", "tools/test_players.mjs", "tools/test_shale.mjs" };
    const check_node = b.step("check-node", "The node tests that need no server (page modules, engine), after zig build's install");
    for (node_fast) |f| {
        const run = nodeRun(b, f);
        run.setEnvironmentVariable("DOGPARK_WASM", "zig-out/web-debug/physics.wasm");
        run.step.dependOn(&debug_wasm_install.step);
        check_node.dependOn(&run.step);
    }

    // **THE TIERS** (README): `test` after every edit; `check` before a
    // commit; `slow` for the full fuzz and the wasm as it is served.
    const test_step = b.step("test", "Fast tier: every Zig unit test natively (the fuzz a tenth) and the node tests that need no server");
    var debug_units = units;
    debug_units.page_wasm = debug_page_wasm.getEmittedBin();
    test_step.dependOn(debug_units.all(fuzz));
    test_step.dependOn(check_node);

    const physics_test = b.step("physics-test", "The physics' tests alone, natively (no webbox, no page wasm)");
    physics_test.dependOn(units.physics(fuzz));

    const physics_wasm = b.step("physics-wasm", "The physics' tests on wasm32 in Debug, under node, and its freestanding compile probe");
    units.onWasm(wasi, wasm32, .Debug, fuzz, physics_wasm);

    const check = b.step("check", "Before a commit: test, physics-wasm (Debug), and the node tests against a scratch server");
    check.dependOn(test_step);
    check.dependOn(physics_wasm);
    for (node_server) |f| check.dependOn(nodeTest(b, f));

    const slow = b.step("slow", "The slow tier: the full fuzz natively, the physics' tests on wasm32 in ReleaseSafe (as served) with the full fuzz, every node test");
    slow.dependOn(units.all(.full));
    units.onWasm(wasi, wasm32, .ReleaseSafe, .full, slow);
    for (node_fast ++ node_server) |f| slow.dependOn(nodeTest(b, f));

    // ── the benches (no tier runs them) ─────────────────────────────────────

    // How long a tick takes natively (ReleaseSafe, as the server runs).
    const physics_bench = b.addExecutable(.{ .name = "physics_bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/play/physics_bench.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "physics_options", .module = physics_mod }},
    }) });
    const physics_bench_run = b.addRunArtifact(physics_bench);
    // `zig build physics-bench -- herd` (or `busiest`, `strewn`, `rerun`): one of the
    // bench's ticks alone, a fixed number of runs, for a profiler (metal-vmm
    // QUEUE 202).
    if (b.args) |args| physics_bench_run.addArgs(args);
    b.step("physics-bench", "Time a physics tick natively (ReleaseSafe); -- herd, busiest, strewn or rerun: that one alone, for a profiler").dependOn(&physics_bench_run.step);

    // A 16-tick report's round trip through POST /report, in process
    // (ReleaseSafe): the route, the judge's re-run, the log's append.
    const webbox_rs = b.dependency("webbox", .{ .target = target, .optimize = .ReleaseSafe });
    const server_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/play/physics_server_bench.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "webbox", .module = webbox_rs.module("webbox") },
            .{ .name = "host_io", .module = webbox_rs.module("host_io") },
            .{ .name = "shale", .module = b.dependency("shale", .{ .target = target, .optimize = .ReleaseSafe }).module("shale") },
            .{ .name = "physics_options", .module = physics_mod },
            .{ .name = "dogpark_build", .module = build_mod },
        },
    });
    server_bench_mod.addAnonymousImport("physics.wasm", .{ .root_source_file = page_wasm });
    const server_bench = b.addExecutable(.{ .name = "physics_server_bench", .root_module = server_bench_mod });
    // **THE FIRST LAYOUT, FROM ROC** (src/play/layout.zig): roc/layout.roc
    // run with `roc` (on the PATH, or -Droc=<path>), its lines written to
    // src/play/layout.txt, which the physics embeds. Not in any tier: only
    // a change to roc/layout.roc needs it, and layout.zig's tests hold the
    // checked-in table to the Zig layout either way.
    const roc = b.option([]const u8, "roc", "the Roc compiler for `roc-layout` (default: `roc` on the PATH)") orelse "roc";
    const roc_run = b.addSystemCommand(&.{ roc, "roc/layout.roc" });
    roc_run.setCwd(b.path("."));
    roc_run.addFileInput(b.path("roc/layout.roc"));
    const roc_write = b.addUpdateSourceFiles();
    roc_write.addCopyFileToSource(roc_run.captureStdOut(.{}), "src/play/layout.txt");
    b.step("roc-layout", "Print the first layout again from roc/layout.roc into src/play/layout.txt (needs roc; -Droc=<path>)").dependOn(&roc_write.step);
    b.step("physics-server-bench", "Time a 16-tick report through POST /report (ReleaseSafe)").dependOn(&b.addRunArtifact(server_bench).step);
}

/// One node test file, run after the install, its exit code the verdict.
fn nodeTest(b: *std.Build, file: []const u8) *std.Build.Step {
    const run = nodeRun(b, file);
    run.step.dependOn(b.getInstallStep());
    return &run.step;
}

/// A node test file, its exit code the verdict; what it needs built first
/// is the caller's to add.
fn nodeRun(b: *std.Build, file: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "node", "--no-warnings" });
    run.addFileArg(b.path(file));
    run.setCwd(b.path("."));
    run.expectExitCode(0);
    run.has_side_effects = true;
    return run;
}

/// The physics for the page (physics_page.zig's exports), compiled to wasm32.
fn pageWasm(b: *std.Build, wasm32: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, physics_mod: *std.Build.Module) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{ .name = "physics", .root_module = b.createModule(.{
        .root_source_file = b.path("src/play/physics_page.zig"),
        .target = wasm32,
        .optimize = optimize,
        .strip = true,
        .imports = &.{.{ .name = "physics_options", .module = physics_mod }},
    }) });
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}

/// Whether a build bakes its commits in (`-Dstamp`), as the kernel's says.
const Stamp = enum { on, off };

/// The build's own facts, `dogpark_build`: the commit, or `unstamped`.
fn buildOptions(b: *std.Build, stamp: Stamp) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "commit", switch (stamp) {
        .on => commitOf(b, b.pathFromRoot(".")),
        .off => "unstamped",
    });
    return options.createModule();
}

/// `git rev-parse --short HEAD` in `dir`, with `+dirty` when its tree has
/// uncommitted changes; `unknown` when git cannot say (as
/// zig-metal-unikernel's build.zig says its own).
fn commitOf(b: *std.Build, dir: []const u8) []const u8 {
    var code: u8 = 0;
    const head = b.runAllowFail(&.{ "git", "-C", dir, "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    const short = std.mem.trim(u8, head, " \n");
    const status = b.runAllowFail(&.{ "git", "-C", dir, "status", "--porcelain", "--untracked-files=no" }, &code, .ignore) catch return short;
    return if (std.mem.trim(u8, status, " \n").len == 0) short else b.fmt("{s}+dirty", .{short});
}

/// The physics' build options, `physics_options`: its hash.
fn physicsOptions(b: *std.Build) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(u32, "physics_hash", physicsHash(b, b.pathFromRoot("src/play")));
    return options.createModule();
}

/// The physics hash: a CRC-32 over the files `dir`/physics_sources.zon
/// lists, in its order: a page and a server built from different physics
/// never agree on the hash.
fn physicsHash(b: *std.Build, dir: []const u8) u32 {
    const io = b.graph.io;
    const list_path = b.fmt("{s}/physics_sources.zon", .{dir});
    const list = std.Io.Dir.cwd().readFileAlloc(io, list_path, b.allocator, .limited(1 << 16)) catch |e|
        std.process.fatal("the physics hash's sources: {s} does not read ({t})", .{ list_path, e });
    const names = std.zon.parse.fromSliceAlloc([]const []const u8, b.allocator, b.allocator.dupeZ(u8, list) catch @panic("out of memory"), null, .{}) catch
        std.process.fatal("{s} is not a list of file names", .{list_path});
    var crc = std.hash.Crc32.init();
    for (names) |name| {
        const path = b.fmt("{s}/{s}", .{ dir, name });
        crc.update(std.Io.Dir.cwd().readFileAlloc(io, path, b.allocator, .limited(1 << 22)) catch |e|
            std.process.fatal("the physics hash's source {s} does not read ({t})", .{ path, e }));
    }
    return crc.final();
}

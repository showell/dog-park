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
    // **THE PHYSICS' ROC, BUILT BY EVERY BUILD** (`rocArchives`): an
    // archive for each of the physics' targets, built into the cache from
    // roc/*.roc and linked wherever the physics is (`linkRoc`); nothing
    // built from Roc is checked in. So every build needs Roc, and without
    // it the build stops while it is configured, saying so (`rocCompiler`).
    const roc = rocCompiler(b);
    // **THE ROC IS PINNED** (roc/roc-version): a release is built by one
    // known Roc, said in /version and covered by the physics hash.
    const roc_lib = rocArchives(b, roc);

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
    // **-Dwalk-judge**: every walk run beside src/play/walk_reference.zig and
    // compared (`zig build walk-judge`); off by default.
    const walk_judge = b.option(bool, "walk-judge", "judge every Roc walk against the plain Zig reference (walk_reference.zig), panicking at a difference") orelse false;
    const physics_mod = physicsOptions(b, walk_judge, false);
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
    const physics_page_wasm = pageWasm(b, wasm32, .safe, physics_mod, roc_lib);
    const page_wasm_install = b.addInstallArtifact(physics_page_wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    b.getInstallStep().dependOn(&page_wasm_install.step);
    const page_wasm = physics_page_wasm.getEmittedBin();
    // The same in Debug, for the fast tier alone: nothing there needs the
    // served build's speed, and it compiles in about a third of the time.
    // zig-out/web-debug/physics.wasm; `check` and `slow` test the served one.
    const debug_page_wasm = pageWasm(b, wasm32, .Debug, physics_mod, roc_lib);
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
    linkRoc(roc_lib, play_main, null);
    const play_exe = b.addExecutable(.{ .name = "dog-park-play", .root_module = play_main });
    // **FOR A COMBINATION** (webbox's combo, with another app beside it):
    // `dog_park`, the park as a host takes it (hosted.zig), its physics and
    // Roc linked as the play server's.
    const dog_park = b.addModule("dog_park", .{
        .root_source_file = b.path("src/play/hosted.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "webbox", .module = webbox },
            .{ .name = "host_io", .module = host_io },
            .{ .name = "shale", .module = shale },
            .{ .name = "physics_options", .module = physics_mod },
            .{ .name = "dogpark_build", .module = build_mod },
        },
    });
    dog_park.addAnonymousImport("physics.wasm", .{ .root_source_file = page_wasm });
    linkRoc(roc_lib, dog_park, null);
    b.installArtifact(play_exe);
    const play_run = b.addRunArtifact(play_exe);
    play_run.addPassthruArgs();
    b.step("play", "Serve the played Dog Park (solo/) on port 9103, every interface unless DOGPARK_BIND names one").dependOn(&play_run.step);

    // **DOG PARK ON METAL** (metal-vmm QUEUE 215): zig-metal-unikernel's
    // kernel, a sibling checkout, hosting hosted.zig's `site` in place of
    // main.zig's Linux host. The module names no target or optimize mode
    // (the kernel's) and imports neither webbox, shale nor host_io (the
    // kernel supplies its own); the physics hash and the wasm are this build's, so
    // the kernel never embeds a stale zig-out/web/physics.wasm. Its cookie
    // is Secure (app.cookie_mode's default: nothing on metal reads
    // DOGPARK_INSECURE_COOKIE). Installed to zig-out/bin/dogpark.elf.
    const metal_app = metalPark(b, physics_mod, build_mod, page_wasm, roc_lib);
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
                .optimize = .safe,
            });
            metal_step.dependOn(&b.addInstallArtifact(dogpark_elf, .{}).step);
        }
    }

    // **COMBINATIONS, DOG PARK THE PRIMARY** (webbox's combo): a combination
    // is built in its primary's repo. Dog Park at `/`, the TODO list
    // (../roc-webbox) at `/todo` (src/combos/dogpark_todo.zig). Both are Roc
    // apps, so its root declares roc-webbox's roc_hooks; the list is built
    // with this build's Roc, so its pin (roc-webbox's roc-version) must
    // agree with roc/roc-version.
    const combo_build = b.step("dogpark-todo", "Build Dog Park with the TODO list at /todo, zig-out/bin/dogpark-todo");
    const combo_serve = b.step("serve-dogpark-todo", "Serve Dog Park at / and the TODO list (../roc-webbox) at /todo/ on port 9113 (COMBO_PORT)");
    const combo_metal = b.step("metal-dogpark-todo", "Build Dog Park with the TODO list at /todo as a zig-metal-unikernel kernel, zig-out/bin/dogpark-todo.elf (ReleaseSafe)");
    if (b.lazyDependency("roc_webbox", .{ .target = target, .optimize = optimize, .roc = roc })) |todo| {
        const combo_exe = b.addExecutable(.{ .name = "dogpark-todo", .root_module = b.createModule(.{
            .root_source_file = b.path("src/combos/dogpark_todo_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webbox", .module = webbox },
                .{ .name = "webbox_linux", .module = webbox_linux },
                .{ .name = "dog_park", .module = dog_park },
                .{ .name = "roc_todo", .module = todo.module("roc_todo") },
                .{ .name = "roc_hooks", .module = todo.module("roc_hooks") },
            },
        }) });
        const combo_install = b.addInstallArtifact(combo_exe, .{});
        combo_build.dependOn(&combo_install.step);
        const combo_run = b.addRunArtifact(combo_exe);
        combo_run.step.dependOn(&combo_install.step);
        // The park's page files (solo/) are read from where it runs.
        combo_run.setCwd(b.path("."));
        combo_serve.dependOn(&combo_run.step);
        if (b.lazyDependency("zig_metal_unikernel", .{ .stamp = stamp })) |kernel| {
            if (b.lazyImport(@This(), "zig_metal_unikernel")) |kernel_build| {
                // A park of its own: the kernel makes a module its machine's
                // in place, and dogpark.elf's is already.
                const park = metalPark(b, physics_mod, build_mod, page_wasm, roc_lib);
                const list = todo.module("roc_todo_metal");
                const combo = b.createModule(.{
                    .root_source_file = b.path("src/combos/dogpark_todo.zig"),
                    .imports = &.{
                        .{ .name = "dog_park", .module = park },
                        .{ .name = "roc_todo", .module = list },
                        .{ .name = "roc_hooks", .module = todo.module("roc_hooks") },
                    },
                });
                const elf = kernel_build.addAppKernel(b, kernel, .{
                    .name = "dogpark-todo.elf",
                    .module = combo,
                    .assets = b.path("assets.zon"),
                    .optimize = .safe,
                    .parts = &.{
                        .{ .module = park, .assets = b.path("assets.zon") },
                        .{ .module = list, .assets = todo.path("assets.zon") },
                    },
                });
                combo_metal.dependOn(&b.addInstallArtifact(elf, .{}).step);
            }
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
        roc_lib: RocLib,

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
            linkRoc(u.roc_lib, probe.root_module, null);
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
            const m = u.b.createModule(.{
                .root_source_file = u.b.path(root),
                .target = t,
                .optimize = opt,
                .imports = &.{
                    .{ .name = "physics_options", .module = u.physics_mod },
                    .{ .name = "test_options", .module = test_options.createModule() },
                    .{ .name = "dogpark_build", .module = u.build_mod },
                },
            });
            linkRoc(u.roc_lib, m, null);
            return m;
        }
    }{ .b = b, .target = target, .optimize = optimize, .webbox = webbox, .shale = shale, .host_io = host_io, .physics_mod = physics_mod, .build_mod = build_mod, .page_wasm = page_wasm, .roc_lib = roc_lib };

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
    units.onWasm(wasi, wasm32, .safe, .full, slow);
    for (node_fast ++ node_server) |f| slow.dependOn(nodeTest(b, f));

    // ── the benches (no tier runs them) ─────────────────────────────────────

    // How long a tick takes natively (ReleaseSafe, as the server runs).
    const physics_bench = b.addExecutable(.{ .name = "physics_bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/play/physics_bench.zig"),
        .target = target,
        .optimize = .safe,
        .imports = &.{.{ .name = "physics_options", .module = physics_mod }},
    }) });
    linkRoc(roc_lib, physics_bench.root_module, null);
    const physics_bench_run = b.addRunArtifact(physics_bench);
    // `zig build physics-bench -- herd` (or `busiest`, `strewn`, `rerun`): one of the
    // bench's ticks alone, a fixed number of runs, for a profiler (metal-vmm
    // QUEUE 202).
    physics_bench_run.addPassthruArgs();
    b.step("physics-bench", "Time a physics tick natively (ReleaseSafe); -- herd, busiest, strewn or rerun: that one alone, for a profiler").dependOn(&physics_bench_run.step);

    // **THE WALK'S JUDGE**: the bench's `-- judge` (its `lines` workload:
    // every dog leashed in turn on two parks, the strewn drag, the packed
    // herd; then again under a drag of uneven length) with every walk judged
    // against walk_reference.zig; its output discarded, it passes only if
    // nothing differed (a difference panics).
    const judged_bench = b.addExecutable(.{ .name = "physics_bench_judged", .root_module = b.createModule(.{
        .root_source_file = b.path("src/play/physics_bench.zig"),
        .target = target,
        .optimize = .safe,
        .imports = &.{.{ .name = "physics_options", .module = physicsOptions(b, true, false) }},
    }) });
    linkRoc(roc_lib, judged_bench.root_module, null);
    const judged_run = b.addRunArtifact(judged_bench);
    judged_run.addArg("judge");
    _ = judged_run.captureStdOut(.{});
    judged_run.expectExitCode(0);
    b.step("walk-judge", "Run the bench's `-- lines` with every Roc walk judged against the plain Zig reference (src/play/walk_reference.zig)").dependOn(&judged_run.step);

    // **THE GAME JUDGE**: the same workload with every tick also played by
    // roc/Game.roc's tick, the one the game on roc-ray plays (roc/native.roc),
    // and the boards compared after it (src/play/roc_game.zig); it passes
    // only if nothing differed (a difference panics).
    const game_bench = b.addExecutable(.{ .name = "physics_bench_game", .root_module = b.createModule(.{
        .root_source_file = b.path("src/play/physics_bench.zig"),
        .target = target,
        .optimize = .safe,
        .imports = &.{.{ .name = "physics_options", .module = physicsOptions(b, false, true) }},
    }) });
    linkRoc(roc_lib, game_bench.root_module, null);
    const game_lib = gameArchive(b, roc);
    game_bench.root_module.addObjectFile(game_lib);
    const game_run = b.addRunArtifact(game_bench);
    game_run.addArg("judge");
    _ = game_run.captureStdOut(.{});
    game_run.expectExitCode(0);
    const game_judge_step = b.step("game-judge", "The bench's `-- lines` and the physics' own tests, every tick also played by roc/Game.roc and the boards compared (src/play/roc_game.zig)");
    game_judge_step.dependOn(&game_run.step);
    // And the physics' own tests, which leash, grab, let go and wait out the
    // timer, as the bench never does: each `tick` they make judged too.
    var judged_units = units;
    judged_units.physics_mod = physicsOptions(b, false, true);
    const judged_tests = judged_units.module("src/play/physics_all_tests.zig", target, optimize, fuzz);
    judged_tests.addObjectFile(game_lib);
    game_judge_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = judged_tests })).step);

    // A 16-tick report's round trip through POST /report, in process
    // (ReleaseSafe): the route, the judge's re-run, the log's append.
    const webbox_rs = b.dependency("webbox", .{ .target = target, .optimize = .safe });
    const server_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/play/physics_server_bench.zig"),
        .target = target,
        .optimize = .safe,
        .imports = &.{
            .{ .name = "webbox", .module = webbox_rs.module("webbox") },
            .{ .name = "host_io", .module = webbox_rs.module("host_io") },
            .{ .name = "shale", .module = b.dependency("shale", .{ .target = target, .optimize = .safe }).module("shale") },
            .{ .name = "physics_options", .module = physics_mod },
            .{ .name = "dogpark_build", .module = build_mod },
        },
    });
    server_bench_mod.addAnonymousImport("physics.wasm", .{ .root_source_file = page_wasm });
    linkRoc(roc_lib, server_bench_mod, null);
    const server_bench = b.addExecutable(.{ .name = "physics_server_bench", .root_module = server_bench_mod });
    // **THE WORLD AND ITS RULES, FROM ROC** (src/play/world.zig,
    // src/play/rules.zig): roc/print_world.roc and roc/print_rules.roc run with `roc`
    // (on the PATH, or -Droc=<path>), what they print written to the files
    // the physics imports (world.zon, rules.zon) and the page reads
    // (solo/world.js). Not in any tier: only a change to a .roc file needs
    // it; the tests hold the checked-in files to the original world, rules
    // and physics (layout.zig, rules.zig, physics_golden_test.zig) and to
    // each other (test_page_modules.mjs) either way.
    //
    // **WHAT IS CHECKED IN IS WHAT THE ROC MAKES** (`roc-fresh`, in
    // `check`): each file this writes, made again and compared byte for
    // byte with the checked-in one, so none is left stale by a .roc change.
    const roc_write = b.addUpdateSourceFiles();
    const roc_fresh = b.step("roc-fresh", "Each file `zig build roc` writes, made again and compared with the checked-in one (needs roc; -Droc=<path>)");
    for ([_][3][]const u8{
        .{ "roc/print_world.roc", "zon", "src/play/world.zon" },
        .{ "roc/print_world.roc", "js", "solo/world.js" },
        .{ "roc/print_rules.roc", "zon", "src/play/rules.zon" },
        .{ "roc/print_page.roc", "words", "solo/words.js" },
        .{ "roc/print_page.roc", "look", "solo/look.js" },
    }) |out| {
        const roc_run = b.addSystemCommand(&.{ roc, out[0], "--", out[1] });
        roc_run.setCwd(b.path("."));
        roc_run.addFileInput(b.path(out[0]));
        // Every module a printer may import: a printer's own list drifted
        // (print_world.roc reads Layout.roc and Wish.roc too).
        for (printed_from) |m| roc_run.addFileInput(b.path(m));
        const made = roc_run.captureStdOut(.{});
        roc_write.addCopyFileToSource(made, out[2]);
        roc_fresh.dependOn(fresh(b, made, out[2]));
    }
    b.step("roc", "Print the world, its rules and the page's words and look again from roc/*.roc into src/play/world.zon, src/play/rules.zon, solo/world.js, solo/words.js and solo/look.js").dependOn(&roc_write.step);
    // **A NEW KIND, IN ROC ALONE** (metal-vmm QUEUE 240): a copy of this
    // repository with test/new_kind/sheep.patch (roc/*.roc only) applied,
    // its world and rules printed there by `zig build roc` (its physics'
    // Roc built by each build there), and src/play/new_kind_test.zig run
    // against the same Zig (tools/new_kind.sh). The test alone, in this world, steps
    // aside: it has no goats.
    const fourth_test = b.step("new-kind-test", "The new kind's test against this checkout's world (it steps aside without a sheep; zig build new-kind makes one)");
    fourth_test.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = units.module("src/play/new_kind_test.zig", target, optimize, fuzz) })).step);
    const fourth = b.addSystemCommand(&.{ "sh", "tools/new_kind.sh", roc });
    fourth.setCwd(b.path("."));
    fourth.has_side_effects = true;
    b.step("new-kind", "A new kind made in Roc alone: sheep.patch on a copy, its world built, the same Zig judged with it (needs roc; -Droc=<path>)").dependOn(&fourth.step);
    // Roc's own tests of the world, the rules, the wish and the walk
    // (`expect`s).
    const roc_test_step = b.step("roc-test", "Roc's own tests: roc/print_world.roc, roc/Rules.roc, roc/Wish.roc and roc/Walk.roc's expects (needs roc; -Droc=<path>)");
    for ([_][]const u8{ "roc/print_world.roc", "roc/Rules.roc", "roc/Wish.roc", "roc/Walk.roc" }) |f| {
        const run = b.addSystemCommand(&.{ roc, "test", f });
        run.setCwd(b.path("."));
        run.addFileInput(b.path(f));
        run.has_side_effects = true;
        roc_test_step.dependOn(&run.step);
    }
    // **THE ROC IS AS `roc fmt` LAYS IT OUT**, in `check` and `roc-test`. A
    // long line is broken by a trailing comma after its last item, which
    // `roc fmt` lays out one item a line (shale's cookbook/roc/roc_commas.shale
    // does it), never by hand: `roc fmt` joins those back.
    const roc_fmt = b.addSystemCommand(&.{ roc, "fmt", "--check", "roc" });
    roc_fmt.setCwd(b.path("."));
    roc_fmt.has_side_effects = true;
    roc_test_step.dependOn(&roc_fmt.step);
    check.dependOn(&roc_fmt.step);
    check.dependOn(roc_fresh);
    b.step("physics-server-bench", "Time a 16-tick report through POST /report (ReleaseSafe)").dependOn(&b.addRunArtifact(server_bench).step);
}

/// A step that fails, naming `checked_in`, unless it is byte for byte
/// `made`.
fn fresh(b: *std.Build, made: std.Build.LazyPath, checked_in: []const u8) *std.Build.Step {
    const cmp = b.addSystemCommand(&.{ "sh", "-c", "cmp -s \"$1\" \"$2\" || { echo \"$3 is not what the Roc makes: zig build roc, then commit it\" >&2; exit 1; }", "sh" });
    cmp.addFileArg(made);
    cmp.addFileArg(b.path(checked_in));
    cmp.addArg(checked_in);
    return &cmp.step;
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
fn pageWasm(b: *std.Build, wasm32: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, physics_mod: *std.Build.Module, roc_lib: RocLib) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{ .name = "physics", .root_module = b.createModule(.{
        .root_source_file = b.path("src/play/physics_page.zig"),
        .target = wasm32,
        .optimize = optimize,
        .strip = true,
        .imports = &.{.{ .name = "physics_options", .module = physics_mod }},
    }) });
    linkRoc(roc_lib, exe.root_module, null);
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}

/// The physics' Roc: an archive for each target the physics compiles for,
/// built from `roc_inputs` (src/play/roc_physics.zig is its seam). The
/// kernel's is `x64v1elf`, x86-64's baseline: SSE2 and no AVX, which
/// zig-metal-unikernel enables at boot (its build.zig, `bareTarget`); Roc's
/// `x64elf` uses AVX, an invalid-opcode fault on metal.
const RocTarget = enum { x64musl, wasm32, x64v1elf };
const RocLib = std.EnumArray(RocTarget, std.Build.LazyPath);
const roc_inputs = [_][]const u8{ "roc/physics.roc", "roc/Wish.roc", "roc/Walk.roc", "roc/World.roc", "roc/Rules.roc", "roc/platform/main.roc" };

/// The Roc the physics is built by: roc/roc-version, one line, as `roc
/// version` ends (a nightly's name). Moving it is a decision: a new Roc
/// is new archives, so judge them (the physics hash covers this file).
const roc_pin = std.mem.trim(u8, @embedFile("roc/roc-version"), " \n");

/// The Roc compiler: -Droc=<path> (from the build root), or `roc` on the
/// PATH. **Every build needs one, and the pinned one** (`roc_pin`): with
/// none, or another, the build stops here, while it is configured, saying
/// so.
fn rocCompiler(b: *std.Build) []const u8 {
    const named = b.option([]const u8, "roc", "the Roc compiler (default: `roc` on the PATH); every build needs one, the version roc/roc-version pins") orelse "roc";
    const none = "Dog Park's physics is built from Roc, and there is no Roc compiler at `{s}`: put Roc {s} (roc/roc-version) on the PATH (../roc-webbox/tools/get_roc.sh installs it), or name it with -Droc=<path>";
    const found = if (std.mem.indexOfScalar(u8, named, '/') == null)
        b.findProgram(.{ .names = &.{named} }) orelse std.process.fatal(none, .{ named, roc_pin })
    else
        b.root.root_dir.handle.realPathFileAlloc(b.graph.io, named, b.allocator) catch std.process.fatal(none, .{ named, roc_pin });
    const said = std.mem.trim(u8, b.run(&.{ found, "version" }), " \n");
    const version = if (std.mem.lastIndexOfScalar(u8, said, ' ')) |i| said[i + 1 ..] else said;
    if (!std.mem.eql(u8, version, roc_pin)) std.process.fatal("Dog Park's physics is pinned to Roc {s} (roc/roc-version), and `{s}` is {s}: put the pinned one on the PATH (../roc-webbox/tools/get_roc.sh) or name it with -Droc=<path>, or move the pin on purpose (a new Roc is new archives: judge them)", .{ roc_pin, found, version });
    return found;
}

/// The physics' Roc built for each target, into the cache. The compiler is
/// an input too, so a new Roc builds them again.
fn rocArchives(b: *std.Build, roc: []const u8) RocLib {
    var lib: RocLib = undefined;
    for (std.enums.values(RocTarget)) |t| {
        const build_roc = b.addSystemCommand(&.{ roc, "build", "roc/physics.roc", b.fmt("--target={t}", .{t}) });
        build_roc.setCwd(b.path("."));
        build_roc.addFileInput(.{ .cwd_relative = roc });
        for (roc_inputs) |f| build_roc.addFileInput(b.path(f));
        lib.set(t, build_roc.addPrefixedOutputFileArg("--output=", b.fmt("physics-{t}.a", .{t})));
    }
    return lib;
}

/// Links the physics' Roc for `m`'s target, or `as`'s when the module takes
/// its target from elsewhere (the kernel's).
fn linkRoc(lib: RocLib, m: *std.Build.Module, as: ?RocTarget) void {
    const t: RocTarget = as orelse blk: {
        const r = m.resolved_target.?.result;
        if (r.cpu.arch.isWasm()) break :blk .wasm32;
        if (r.cpu.arch == .x86_64 and r.os.tag == .freestanding) break :blk .x64v1elf;
        if (r.cpu.arch == .x86_64) break :blk .x64musl;
        std.process.fatal("the physics' Roc: no archive for {t} (it is built for x86-64 and wasm32)", .{r.cpu.arch});
    };
    m.addObjectFile(lib.get(t));
}

/// hosted.zig as the kernel takes it (no target, mode, webbox, shale or
/// host_io: the kernel's), with this build's physics hash, wasm and Roc.
fn metalPark(b: *std.Build, physics_mod: *std.Build.Module, build_mod: *std.Build.Module, page_wasm: std.Build.LazyPath, roc_lib: RocLib) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/play/hosted.zig"),
        .imports = &.{ .{ .name = "physics_options", .module = physics_mod }, .{ .name = "dogpark_build", .module = build_mod } },
    });
    m.addAnonymousImport("physics.wasm", .{ .root_source_file = page_wasm });
    // The kernel's: x86-64, freestanding (the module takes the kernel's target).
    linkRoc(roc_lib, m, .x64v1elf);
    return m;
}

/// Whether a build bakes its commits in (`-Dstamp`), as the kernel's says.
const Stamp = enum { on, off };

/// The build's own facts, `dogpark_build`: the commit, or `unstamped`.
fn buildOptions(b: *std.Build, stamp: Stamp) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "commit", switch (stamp) {
        .on => commitOf(b, pathFromRoot(b, ".")),
        .off => "unstamped",
    });
    options.addOption([]const u8, "roc", roc_pin);
    return options.createModule();
}

/// `git rev-parse --short HEAD` in `dir`, with `+dirty` when its tree has
/// uncommitted changes; `unknown` when git cannot say (as
/// zig-metal-unikernel's build.zig says its own).
fn commitOf(b: *std.Build, dir: []const u8) []const u8 {
    // Asked at configure time, which 0.17 caches: a commit, or a tree that
    // turned clean, must configure the build again, or it bakes in the old
    // answer. Whether a tree is dirty rests on every file in it, which no
    // dependency names.
    b.graph.poisonCache();
    var code: u8 = 0;
    const head = b.runAllowFail(&.{ "git", "-C", dir, "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    const short = std.mem.trim(u8, head, " \n");
    const status = b.runAllowFail(&.{ "git", "-C", dir, "status", "--porcelain", "--untracked-files=no" }, &code, .ignore) catch return short;
    return if (std.mem.trim(u8, status, " \n").len == 0) short else b.fmt("{s}+dirty", .{short});
}

/// The modules roc/'s printers import, every one an input of each print:
/// a change to any prints again.
const printed_from = [_][]const u8{ "roc/World.roc", "roc/Rules.roc", "roc/Layout.roc", "roc/Wish.roc", "roc/Words.roc", "roc/Look.roc" };

/// The physics' build options, `physics_options`: its hash.
fn physicsOptions(b: *std.Build, walk_judge: bool, game_judge: bool) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(u32, "physics_hash", physicsHash(b, pathFromRoot(b, "src/play")));
    options.addOption(bool, "walk_judge", walk_judge);
    options.addOption(bool, "game_judge", game_judge);
    return options.createModule();
}

/// **GAME.ROC'S TICK, AS AN ARCHIVE** (roc/game.roc on
/// roc/game_platform/main.roc), for the game judge's bench: x86-64 only.
fn gameArchive(b: *std.Build, roc: []const u8) std.Build.LazyPath {
    const build_roc = b.addSystemCommand(&.{ roc, "build", "roc/game.roc", "--target=x64musl" });
    build_roc.setCwd(b.path("."));
    build_roc.addFileInput(.{ .cwd_relative = roc });
    for (game_inputs) |f| build_roc.addFileInput(b.path(f));
    return build_roc.addPrefixedOutputFileArg("--output=", "game-x64musl.a");
}

const game_inputs = [_][]const u8{ "roc/game.roc", "roc/game_platform/main.roc", "roc/Game.roc", "roc/Layout.roc", "roc/Look.roc", "roc/Walk.roc", "roc/Wish.roc", "roc/World.roc", "roc/Rules.roc" };

/// The physics hash: a CRC-32 over the files `dir`/physics_sources.zon
/// lists, in its order: a page and a server built from different physics
/// never agree on the hash.
fn physicsHash(b: *std.Build, dir: []const u8) u32 {
    const io = b.graph.io;
    const list_path = b.fmt("{s}/physics_sources.zon", .{dir});
    const list = std.Io.Dir.cwd().readFileAlloc(io, list_path, b.allocator, .limited(1 << 16)) catch |e|
        std.process.fatal("the physics hash's sources: {s} does not read ({t})", .{ list_path, e });
    var diag: std.zon.parse.Diagnostics = undefined;
    const names = std.zon.parse.fromSlice([]const []const u8, .{ .gpa = b.allocator, .arena = b.allocator, .source = b.allocator.dupeSentinel(u8, list, 0) catch @panic("out of memory"), .diagnostics = &diag }) catch
        std.process.fatal("{s} is not a list of file names", .{list_path});
    var crc = std.hash.Crc32.init();
    for (names) |name| {
        const path = b.fmt("{s}/{s}", .{ dir, name });
        crc.update(std.Io.Dir.cwd().readFileAlloc(io, path, b.allocator, .limited(1 << 22)) catch |e|
            std.process.fatal("the physics hash's source {s} does not read ({t})", .{ path, e }));
    }
    return crc.final();
}

/// `builder`'s build root as an absolute path: 0.17's `b.root` may hold a
/// relative one, and these paths are handed to other processes and builds.
fn rootOf(builder: *std.Build) []const u8 {
    return builder.root.root_dir.handle.realPathFileAlloc(builder.graph.io, builder.root.subPathOrDot(), builder.allocator) catch |e|
        std.debug.panic("the build root {f}: {t}", .{ builder.root, e });
}

/// `sub` under this build's root, absolute (0.17 removed `b.pathFromRoot`).
fn pathFromRoot(b: *std.Build, sub: []const u8) []const u8 {
    return b.pathJoin(&.{ rootOf(b), sub });
}

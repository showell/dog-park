# Dog Park

Everybody owns a dog and drags it around a park. There is no object of the
game yet: you leash a dog and drag it, the cows ahead of it scoot aside,
and the other dogs keep their distance or follow (its own breed).

It is a small web application built on `webbox`, the web-server-in-a-box
library ([zig-webbox](https://github.com/showell/zig-webbox), a sibling
checkout at `../zig-webbox`).
It is meant to be the thing a person reads to make their own game: the
park, its routes, its page and its JavaScript are here, and everything that
serves them is the library's.

**Where it runs:** on its own droplet, with its own data. It shares only
the domain and the Caddy in front with lynrummy.com. Developed on Linux.
zig-metal-unikernel's `zig build dogpark` no longer builds it (the physics
hash now comes from this build.zig) and nothing judges it on metal. Not
deployed.

**Status (2026-10-13):** played by Steve, and tuned by playing. The page
(`solo/`) runs the physics (`src/play/physics*.zig`, compiled to wasm) and
reports every tick to the server, which re-runs it and keeps it
([docs/PHYSICS.md](docs/PHYSICS.md)). The server (`src/play/`) speaks
`GET /`, the page's scripts, `GET /physics-<hash>.wasm`, `POST /load` and
`POST /report`; nothing else. Every load starts the park afresh, in its
first layout. The first version's briefs (`docs/*-BRIEF.md` and the
amendments) are history: that app is retired.

    zig build play       # serve on localhost:9103, from the checkout

## The tests: three commands

Times are wall times after an edit to `src/play/physics.zig`, measured
once each on the shared 8 GB box under another job's load (2026-10-13);
treat them as orientation.

    zig build test       # after every edit, ~13 s
    zig build check      # before a commit, ~30 s
    zig build slow       # the slow tier, ~90 s

- **`test`**: every Zig unit test natively, in Debug, with the seeded fuzz
  loops at a tenth (`-Dfuzz=fast`, the default), and the node tests that
  need no server (`tools/test_page_modules.mjs`, `tools/test_engine.mjs`).
  About 4 s of compiles and 4 s of test run.
- **`check`**: `test`, plus the physics' tests compiled to wasm32-wasi in
  Debug and run under node (`physics-wasm`, about 8 s), and the node tests
  against a scratch server (`tools/test_page_physics.mjs`, about 7 to
  11 s, and `tools/test_physics_server.mjs`).
- **`slow`**: the full fuzz natively (about 30 s of run), the physics'
  tests on wasm32 in ReleaseSafe as the page is served with the full fuzz
  (about 23 s to compile), and every node test.

`-Dfuzz=full` gives any step the full fuzz; `zig build physics-test` runs
the physics' tests alone. The benches (`zig build physics-bench`,
`zig build physics-server-bench`, `node tools/bench_page.mjs`) are in no
tier.

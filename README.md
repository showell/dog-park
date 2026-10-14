# Dog Park

Everybody owns a dog and drags it around a park. There is no object of the
game yet: you leash a dog and drag it, and the critters near it react:
dogs of its breed follow it in herds, other breeds and the cows keep
their distance. Nothing moves unless you drag.

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

**Status (2026-10-14):** played by Steve, and tuned by playing. The page
(`solo/`) runs the physics (`src/play/physics*.zig`, compiled to wasm) and
reports every tick to the server, which re-runs it and keeps it
([docs/PHYSICS.md](docs/PHYSICS.md)). The server (`src/play/`) speaks
`GET /`, the page's scripts, `GET /physics-<hash>.wasm`, `POST /load` and
`POST /report`; nothing else. Every load starts the park afresh, in its
first layout. The first version's briefs (`docs/*-BRIEF.md` and the
amendments) are history: that app is retired.

    zig build play       # serve on localhost:9103, from the checkout

## The tests: three commands

Each test has a purpose: the no-overlap invariant, page and server
agreeing, the protocol, the torus and its tiles
([docs/PHYSICS.md](docs/PHYSICS.md) lists them). How the critters move is
tested by playing. A test that no longer proves anything goes.

    zig build test       # after every edit, ~6 s
    zig build check      # before a commit, ~10 s
    zig build slow       # the slow tier, ~40 s

Wall times after an edit to `src/play/physics.zig`, on the box
(2026-10-14).

- **`test`**: every Zig unit test natively, in Debug, with the seeded fuzz
  loops at a tenth (`-Dfuzz=fast`, the default), and the node tests that
  need no server (`tools/test_page_modules.mjs`, `tools/test_engine.mjs`).
- **`check`**: `test`, plus the physics' tests compiled to wasm32-wasi in
  Debug and run under node (`physics-wasm`), and the node tests against a
  scratch server (`tools/test_page_physics.mjs`,
  `tools/test_physics_server.mjs`).
- **`slow`**: the full fuzz natively, the physics' tests on wasm32 in
  ReleaseSafe as the page is served, and every node test.

`-Dfuzz=full` gives any step the full fuzz; `zig build physics-test` runs
the physics' tests alone. The benches (`zig build physics-bench`,
`zig build physics-server-bench`, `node tools/bench_page.mjs`) are in no
tier.

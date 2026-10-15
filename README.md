# Dog Park

Everybody owns a dog and drags it around a park. There is no object of the
game yet: you leash a dog and drag it, and the critters near it react:
dogs of its breed follow it in herds, other breeds keep their distance,
and the cows flee the dogs and herd among themselves. The herds leave a
trail of poop, and chickens wander out to eat it. Nothing moves unless
you drag.

It is a small web application built on `webbox`, the web-server-in-a-box
library ([zig-webbox](https://github.com/showell/zig-webbox), a sibling
checkout at `../zig-webbox`).
It is meant to be the thing a person reads to make their own game: the
park, its routes, its page and its JavaScript are here, and everything that
serves them is the library's.

**Where it runs:** not deployed. Today it runs on Linux; on the box,
`zig build play` serves :9103 as a development server. The plan is its own
droplet and data, sharing only the domain and the Caddy in front with
lynrummy.com, for 80 accounts with up to 5 playing at once
([docs/PHYSICS.md](docs/PHYSICS.md), "Who may play").
zig-metal-unikernel neither builds nor judges it (its 8af778b; the physics
hash comes from this build.zig). This repo builds its own metal kernel,
with `../zig-metal-unikernel` as a dependency (`zig build metal`, below;
metal-vmm QUEUE 215): built, not yet booted or gated.

**Status (2026-10-15):** played by Steve, and tuned by playing. The page
(`solo/`) runs the physics (`src/play/physics*.zig`, compiled to wasm) and
reports every tick to the server, which re-runs it and keeps it
([docs/PHYSICS.md](docs/PHYSICS.md)). The server (`src/play/`) speaks
`GET /` (the landing page), `POST /begin`, `GET /dogpark` (the game),
`POST /reset`, the page's scripts, `GET /physics-<hash>.wasm`, `POST /load`
and `POST /report`, and the operator's pages under `/admin` (below);
nothing else. A load picks the player's game up where
it was; Start over puts it back in its first layout. The first version's briefs (`docs/*-BRIEF.md` and the
amendments) are history: that app is retired.

    zig build play       # serve on localhost:9103, from the checkout

Its cookie is Secure, which a browser keeps only over HTTPS (or from
localhost). A development server on plain http at an address sets
`DOGPARK_INSECURE_COOKIE=yes`.

## Deploying

One Linux droplet, with Caddy in front for HTTPS:
- **The binary:** `zig build -Doptimize=ReleaseSafe`. The server reads the page
  from `solo/` in the directory it runs in, so ship `zig-out/bin/dog-park-play`
  and `solo/` together, and start it from there.
- **The config:** `DOGPARK_CONFIG` names a file with `data_dir = …` and
  `auth_dir = …`.
  - The data dir holds the games (`game-<slot>/`) and the account count
    (`players`). Each game's logs rotate at 1 MiB, and closed logs are kept
    for an hour, at most 25 MB a game ([docs/PHYSICS.md](docs/PHYSICS.md),
    "The log is rotated").
  - The auth dir holds the site secret (`_session_secret`) and the admin
    key (`_admin_key`), both made on the first start.
  - To hand out the 80 accounts again, stop the server and delete
    `players` and `game-*`. To make every old cookie invalid as well,
    delete the secret too.
- **The rest of the environment:**
  - `DOGPARK_PORT` (default 9103);
  - `DOGPARK_BIND`: bind 127.0.0.1 behind Caddy;
  - `DOGPARK_TRUSTED_PROXY` (default 127.0.0.1).

  Never set `DOGPARK_INSECURE_COOKIE` behind HTTPS.
- **The operator's pages:** `/admin/game` (accounts, turns, each game:
  its last request, leash, tick, herd, poops, logs, findings) and
  `/admin/host` (requests, errors, memory, the host's facts), by the admin
  key. Either `curl -H "Authorization: Bearer $(cat <auth>/_admin_key)"`,
  or `/admin`'s form in a browser, which sets an admin cookie.
- **Caddy:** `reverse_proxy 127.0.0.1:9103` for the site's name. Nothing
  streams; every route is a plain request and answer.

### On metal (`zig build metal`): built, and booted by the QEMU gate

    zig build metal      # zig-out/bin/dogpark.elf, ReleaseSafe (~30 s)

zig-metal-unikernel's `addAppKernel` builds `src/play/hosted.zig` (its
`site` and `hosting`) into the kernel, whose own host (its
`probe/gopher.zig`) replaces main.zig's Linux one. This build hands it the
physics hash and the page wasm, so neither can be stale. Every build here
(not only `metal`) needs `../zig-metal-unikernel` and `../zig-webbox`
checked out beside this one, and `../zig-coverage-sdk` at the commit the
kernel pins: Zig runs a path dependency's build at every configure. What differs there:
- **No environment.** main.zig is Linux-only, so nothing reads
  `DOGPARK_INSECURE_COOKIE`: the cookie is Secure (`app.cookie_mode`'s
  default), as it must be behind Caddy.
- **The roots are fixed:** `data/` and `auth/`, on the DigitalOcean volume
  when one is attached (else the boot disk), as for every metal
  application; no config names them. `solo/` is read from the boot disk
  (assets.zon's `.site`); physics.wasm is compiled in (`.embedded`).
- **Durability:** every write reaches the disk, and the disk is flushed
  before any response byte goes out; a failed flush is logged and the
  response still goes out, as on Linux.
- **The machine's settings** are `zig-metal-unikernel.conf` on the boot
  disk (`volume`, `card`, `trusted_proxy`, ...), the kernel's README says
  which.

### The QEMU gate (`zig build metal-gate`): last, before a Dog Park deploy

    zig build metal-gate --summary all   # ~6 s warm on the box; the build's times beside the run's

**Run it last, before a Dog Park deploy, never out of habit.** It is in
none of `test`, `check` or `slow`. tools/metal_gate.mjs boots
zig-out/bin/dogpark.elf under QEMU (microvm, KVM, slirp) on a fresh 64 MiB
GPT disk, FAT16, holding `solo/` and a known `auth/_admin_key` (sgdisk,
mkfs.vfat, mtools; no root; no zig-metal-unikernel.conf: the kernel's
defaults), then:
- `GET /` is 200 with Begin Game; `POST /begin` is a 303 with
  `__Host-dogpark` (Secure, HttpOnly), sent back by hand over http;
- `/dogpark` is 303 without it, 200 with it, naming the physics hash;
  `/physics-<hash>.wasm` is byte for byte zig-out/web/physics.wasm;
- a load, a leash and a short drag through the page's own code
  (tools/lib/page_rig.mjs posting to the guest): every report `kept`,
  never a `differ`, no warning from the page;
- `/admin/game` by the bearer: 1 of 80 accounts, the game's kept tick,
  no finding; 403 without the key or with a wrong one;
- QEMU stopped by its PID, the disk passes `fsck.fat -n`, and the
  physics log's `log-<ms>` name is within the run's wall-clock window
  (the guest's clock);
- a second boot on the same disk: the cookie still reads, the load
  answers the game's kept tick, a second drag is kept, the admin page
  agrees; then fsck again, and the new log's name is later than the
  first's and within its own window.

Any other status, a `differ`, a finding, or an error line in the guest's
serial log (a panic, a request whose outcome is not `ok`, a disk check
with a leak or a problem) fails it with the step and the log's tail; the
scratch disk and logs are kept for a look. Times on the box (2026-10-15),
build cached: disk 1.0 s, each boot 1.1 s, sessions ~1 s each, ~5.5 s in
all. A cold `zig build metal` is ~30 s more.

## The tests: three commands

Each test has a purpose: the no-overlap invariant, page and server
agreeing, the protocol, the torus and its tiles, poop and chickens never
landing anyone on anything
([docs/PHYSICS.md](docs/PHYSICS.md) lists them). How the critters move is
tested by playing. A test that no longer proves anything goes.

    zig build test       # after every edit, ~4 s
    zig build check      # before a commit, ~14 s
    zig build slow       # the slow tier, ~20 s

Wall times after an edit to `src/play/physics.zig`, on the box
(2026-10-15).

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

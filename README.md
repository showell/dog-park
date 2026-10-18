# Dog Park

A small browser game about herding. You leash one dog and drag it through
a park full of critters, and everything near it reacts. **The goal: herd
all eight cows into one bunch.**

## The game

The park is a checkerboard of grass tiles: 64 dogs of four breeds, 8 cows
and 16 chickens. The world wraps around, top to bottom and side to side
(a torus), so walking off one edge brings you back on the other.

- **Press a dog to leash it, and drag.** Dogs of its breed follow it, in
  herds and chains; other breeds keep their distance. A dog only reacts to
  critters that are moving, so the leashed dog leads, and a herd that has
  formed stays together.
- **Cows fear dogs, and like each other.** A cow runs from a moving dog
  and drifts toward a moving cow nearby, nudging its neighbours along. You
  never touch a cow: you herd it with a dog, and the cows keep themselves
  together.
- **The herds leave a trail of poop,** and the chickens wander out to eat
  it: quickly enough that the park doesn't fill up, slowly enough that you
  can see where the herds went.
- **Nothing moves unless you drag.** Let go, and the park waits for you.
  The leash comes off 20 seconds after you stop.
- **Press empty grass and drag** to move your view. **Map** (or `m`)
  shows the whole world, with your view as a rectangle you can drag or
  tap.
- **Try to drag a cow or a chicken,** or walk your dog straight into
  someone, and the park will tell you what it thinks of that.
- The score at the top counts your biggest herd of cows. **Start over**
  puts every critter back where the game began.

Each player gets their own park, kept on the server: close the tab, come
back, and it's where you left it.

## How it works

The page runs the physics itself: the same Zig code as the server,
compiled to WebAssembly, 16 ticks a second. It sends the server what you
did about once a second. The server re-runs it, keeps it, and says whether
it agrees. So a player's park survives a reload, and the server is the
record.

The critters are drawn as text emoji, so each device draws them in its own
platform's emoji font: the dogs, cows and chickens look different on an
iPhone, an Android phone and a desktop. The park and the physics are the
same everywhere; only the pictures differ. (Safari's 3D billboards kept
their emoji as saved bitmaps instead; Dog Park doesn't, for now.)

It is a small web application built on `webbox`, the web-server-in-a-box
library ([zig-webbox](https://github.com/showell/zig-webbox)). It is meant
to be the thing a person reads to make their own game: the park, its
routes, its page and its JavaScript are here, and everything that serves
them is the library's.

- [docs/PHYSICS.md](docs/PHYSICS.md): the rules, the numbers, and the
  report the page sends, in full.
- `src/play/`: the server and the physics (`physics*.zig`).
- `solo/`: the page.

**Who may play:** the first 80 devices to press Begin Game get an account,
and up to 5 can play at once. A sixth waits for a turn, which frees 20
seconds after someone stops dragging (`src/play/players.zig`). The cap of 5
is small on purpose: [the capacity study](https://github.com/showell/essay-repl-server/blob/master/notes/dog-park-capacity.md) puts about 20 turns held at
once on a 1 vCPU / 1 GiB droplet. The study is an estimate for that size,
not a measurement of the deployed droplet.

## Where it runs

**Dog Park is live at https://dogpark.lynrummy.com**, on its own droplet, booted from an image with no Linux on it. The image is the
[zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)
kernel with Dog Park built in, the same way lynrummy.com is served.
Prod's Caddy holds HTTPS and forwards to it over the private network, and
logs every request (`/var/log/caddy/dogpark-access.log` on prod; angry-gopher's
`ops/knocks` reads it). The image is built and rehearsed under QEMU on a
droplet-sized machine. [DEPLOY.md](DEPLOY.md) is the deploy, step by step,
and a new release, which starts every game over.

To see which build the droplet runs: `curl -s
https://dogpark.lynrummy.com/version` (below). A droplet running an image
built before `/version` existed answers 404 there.

## Running it

    zig build play       # serve on port 9103, from the checkout

With `DOGPARK_BIND` unset it listens on **every interface**, so on a
machine with a public address the game is public;
`DOGPARK_BIND=127.0.0.1 zig build play` keeps it to the machine. With no
`DOGPARK_CONFIG`, the games go in `./data` and the auth files in `./auth`
in the checkout, so the local admin key is `auth/_admin_key`.

Every build needs its sibling checkouts beside this one:
- `../zig-webbox`;
- `../shale`;
- `../zig-metal-unikernel`;
- `../zig-coverage-sdk`, holding the code the kernel pins (zig-metal-unikernel's
  `build.zig`, `pinnedSdk`, a hash of the SDK's code; the build fails, saying
  so, on any other).

Zig runs a path dependency's build at every configure, so even a plain
`zig build` needs all three.

The tools: zig 0.16 (`build.zig.zon`), and node for the node tests.
Roc (a nightly of the new compiler) only for `zig build roc`, which
prints the world again from `roc/world.roc` (its size, the park in it and
where every critter starts) into `src/play/world.zon` and `solo/world.js`,
and the rules from `roc/Rules.roc` (what critters do about each other) into
`src/play/rules.zon`; and builds the physics' own Roc, the walk
(`roc/Walk.roc`: who moves each pixel-tick, the nudge, the shove, the
sidestep, the herd's pooper) and the critters' wish in it (`roc/Wish.roc`),
through `roc/physics.roc`, into `roc/lib/` for each target the physics
runs on (x86-64 Linux, wasm32, the kernel's freestanding x86-64), which
every build links (`src/play/roc_physics.zig` is the seam: the lists the
Zig lends Roc, which Roc changes in place; neither side allocates).
Every other build reads the checked-in files; `zig build roc-test` runs
Roc's own tests of the world, the rules, the wish and the walk. While the
Zig tests run, the old Zig walk walks a copy of every pixel-tick beside
Roc's, and any difference is a panic.
Any world and rules that fit their types will play: Zig refuses at compile
time only what the physics can't take (a critter outside the world, a
park past its edge, poop slots not a power of two), and the tests of the
physics hold under any of them. The recordings of today's game (the
golden runs and the worked example in docs/PHYSICS.md) step aside under
another configuration, saying so; record them anew with
`physics_golden_test.zig`'s `print`. The
QEMU gate and the image also need qemu with KVM, sgdisk, mtools and
fsck.fat, and python3 (zig-metal-unikernel's `droplet/app_image.py`).

The cookie is Secure, which a browser keeps only over HTTPS (or from
localhost). A development server on plain http at an address sets
`DOGPARK_INSECURE_COOKIE=yes`.

### On metal

    zig build metal      # zig-out/bin/dogpark.elf, ReleaseSafe

zig-metal-unikernel's `addAppKernel` builds `src/play/hosted.zig` (its
`site` and `hosting`) into the kernel. The kernel's own host replaces
main.zig's Linux one. This build hands the kernel the physics hash and the
page's wasm, so neither can be stale. What differs from Linux:
- **No environment.** The cookie is always Secure, as it must be behind
  Caddy.
- **Fixed folders:** `data/` and `auth/`.
  - They live on a DigitalOcean volume when one is attached, and on the
    boot disk otherwise. The first deploy uses the boot disk, so a new
    release starts with no accounts.
  - `solo/` is read from the boot disk, and physics.wasm is compiled in.
- **Durability:** every write reaches the disk, and the disk is flushed
  before any response byte goes out.
- **The machine's settings** are in `zig-metal-unikernel.conf` on the
  boot disk (`card`, `trusted_proxy`, …). The kernel's README says what
  each setting does.

### The QEMU gate: last, before a deploy

    zig build metal-gate --summary all

**Run it last, before a Dog Park deploy, never out of habit;** it is in no
test tier. `tools/metal_gate.mjs` boots dogpark.elf under QEMU on a fresh
disk, then checks, failing loudly with the step and the guest's log:
- **Getting in:** the landing page, and Begin Game's Secure cookie.
- **The page:** it loads, with byte-identical wasm.
- **A session:** a load, a leash and a drag through the page's own code,
  with every report kept.
- **The admin page:** it works with the key and refuses without it.
- **`/version`:** it answers after each boot, and the second boot's
  `started_ms` is later than the first's. It does not compare the commit it
  serves with the checkout's.
- **A background Shale run:** `games.shale` posted, signed, and run while
  a second client is answered, and what it printed.
- **The guest:** its log has no errors, the log files' names fall in each
  boot's wall-clock window (the guest's clock), and the disk passes `fsck`.
- **A second boot on the same disk:** the cookie still reads, and the game
  is picked up where it was.

Its time is in its step's description (`zig build --help`), measured warm
on the box.

### On Linux, behind Caddy

Linux can serve it too:
- **The binary:** `zig build -Doptimize=ReleaseSafe`. The server reads
  the page from `solo/` in the directory it runs in, so ship
  `zig-out/bin/dog-park-play` and `solo/` together, and start it from
  there.
- **The config:** `DOGPARK_CONFIG` names a file with `data_dir = …` and
  `auth_dir = …`. A file with no `data_dir` is refused; one with no
  `auth_dir` uses `~/DogParkAuth`. Other keys are ignored: the host's
  settings are its environment.
  - The data dir holds the games (`game-<slot>/`) and the account count
    (`players`). Each game's log rotates at 1 MiB. Closed logs are kept
    for an hour, at most 25 MB a game.
  - The auth dir holds the site secret and the admin key, both made on
    the first start.
  - To hand out the accounts again, stop the server and delete `players`
    and `game-*`. Delete the secret too to make every old cookie invalid.
- **The environment** (`src/play/main.zig`):

  | variable | default |
  |---|---|
  | `DOGPARK_PORT` | 9103 |
  | `DOGPARK_BIND` | every interface (bind 127.0.0.1 behind Caddy) |
  | `DOGPARK_CONFIG` | none: `./data` and `./auth` |
  | `DOGPARK_TRUSTED_PROXY` | 127.0.0.1 |
  | `DOGPARK_KEEPALIVE_MS` | webbox's (a quiet stream's ping window, for tests) |
  | `DOGPARK_INSECURE_COOKIE` | unset: the cookie is Secure |

  Never set `DOGPARK_INSECURE_COOKIE` behind HTTPS.
- **Caddy:** `reverse_proxy 127.0.0.1:9103` for the site's name. Every
  route is a plain request and answer.

### What anyone may ask: `/version`

`GET /version` answers small JSON, with no secret and nobody's name: which
commit serves (`+dirty` for a tree with uncommitted changes), `started_ms`
(a restart shows as a new one), `now_ms`, the accounts handed out of the most,
and the turns held now of the most. It is what the [Observatory](https://github.com/showell/observatory) polls
(metal-vmm QUEUE 228); `curl -s <site>/version` is the quickest way to see
which build a machine runs.

### The operator's pages

`/admin/game` shows accounts, turns, and each game's state: its last
request, leash, tick, herd, poops, logs, and any findings. `/admin/host`
shows requests, errors, memory and the host's facts. `/admin/log` is the
host's whole log as plain text, for an agent to fetch and grep, narrowed by
`since=`, `until=`, `request=`, `path=` and `boot=` (zig-webbox's
`admin_log`).

All need the admin key, either as a bearer token
(`curl -H "Authorization: Bearer $(cat <auth>/_admin_key)"`; `<auth>` is
the auth dir, `auth/` in a checkout) or through
`/admin`'s login form in a browser.

### Running a script (Shale, for monitoring)

`POST /admin/script` takes a Shale script, signed, and runs it in the
**background**: it only reads, a slice at a time between requests, so play
keeps the turn first (src/play/shale.zig; the envelope, the sequence numbers
and the run are shale's `script_route`). `GET /admin/script` shows the
run going, or the last one that ended, and what it printed. Both take the
admin key, as the other `/admin` pages do. An atomic script, which could
write, is refused: Dog Park runs background scripts only.

- **The key** is Dog Park's own, never lynrummy's: the private half is
  `~/.shale_signing_key.dogpark.lynrummy.com` on the box, which
  shale's `shale-sign` uses for that target. The droplet's image
  carries the public half (`droplet/image.mjs` makes the pair the first
  time). On Linux, set it by hand in the auth dir: `shale.conf` holding
  `public_key = <64 hex>` and `target = <the host>`, and `shale/sequence`
  holding the Unix seconds now, so nothing signed before it runs. With no
  `shale.conf` the route is off (403 `no_key`).
- **Sign and send:** `shale-sign background <file.shale>
  dogpark.lynrummy.com` writes a signed request (`shale-sign kill
  dogpark.lynrummy.com` ends the run going); POST it with `curl` and the
  admin bearer, then GET `/admin/script` for what it printed. DEPLOY.md's
  step 10 is the whole recipe.
- **The cookbook,** in `tools/shale/`: `games.shale` (each game's kept tick,
  last log and log bytes), `trouble.shale` (each game's last hour: reports,
  differs, `req ?`, overlaps, idle drags, stuck, refused lines) and `accounts.shale`
  (accounts against the 80, games started).
- **The budgets** (`shale.budgets`): 50M steps, an 8 MiB arena, 10,000
  store reads and 256 MiB read in all, no changes; a slice is at most
  100,000 steps or one store call, and each call's work is capped (a
  megabyte a read or scan, 256 entries a walk).
- **Both hosts step it:** Linux on a thread of its own, the metal kernel
  in its main loop, a slice after each request and slices while idle
  (zig-metal-unikernel, metal-vmm QUEUE 216); `/admin/host`'s kernel half
  counts its slices and those over the 50 ms target. The QEMU gate runs
  `games.shale` in the background while a second client is answered.
  Parked (Steve): an output ring and a live stream, for a script that must
  report as it runs.

## The tests

How the critters move is tested by playing. The automated tests each have
a purpose:
- **the physics** ([docs/PHYSICS.md](docs/PHYSICS.md) lists them, file by
  file): critters never overlap; the page and the server agree; the
  protocol; the wrapping world and its tiles; poop and chickens never
  landing anyone on anything;
- **the app** (`src/play/app.zig`, `admin.zig`, `players.zig`): `/version`'s
  answer, the admin key, accounts and turns;
- **the Shale cookbook** (`src/play/shale_tools_test.zig`): each script in
  `tools/shale/` on a fixture store, against golden output;
- **the node tests** (`tools/test_*.mjs`): the page's modules and engine
  with no server (`test_page_modules`, `test_engine`), and against a scratch
  server the page's physics, the physics server, accounts and the admin
  pages (`test_players`), and a signed Shale run (`test_shale`).

A test that no longer proves anything goes. `src/play/all_tests.zig` is the
root of every Zig test.

    zig build physics-test   # the physics' tests alone, natively: the fastest
    zig build test           # after every edit, ~4 s
    zig build check          # before a commit, ~14 s
    zig build slow           # the slow tier, ~20 s

The times were measured warm on the box, and nothing checks them; a cold
cache takes longer.

- **`test`:** every Zig unit test natively, with the seeded fuzz loops at a
  tenth, and the node tests that need no server.
- **`check`:** `test`, plus `physics-wasm` (the physics' tests compiled to
  wasm32 in Debug and run under node, and its freestanding compile probe),
  and the node tests against a scratch server.
- **`slow`:** the full fuzz, the physics' tests on wasm in ReleaseSafe as
  the page is served, and every node test.

`check-node` runs the node tests that need no server alone. `-Dfuzz=full`
gives any step the full fuzz. The benches (`zig build physics-bench`,
`zig build physics-server-bench`, `node tools/bench_page.mjs`) are in no
tier.

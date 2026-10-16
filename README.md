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

It is a small web application built on `webbox`, the web-server-in-a-box
library ([zig-webbox](https://github.com/showell/zig-webbox)). It is meant
to be the thing a person reads to make their own game: the park, its
routes, its page and its JavaScript are here, and everything that serves
them is the library's.

- [docs/PHYSICS.md](docs/PHYSICS.md): the rules, the numbers, and the
  report the page sends, in full.
- `src/play/`: the server and the physics (`physics*.zig`).
- `solo/`: the page.
- The older docs (`docs/*-BRIEF.md` and the amendments) are history: they
  describe the first version, since retired.

**Who may play:** the first 80 devices to press Begin Game get an account,
and up to 5 can play at once. A sixth waits for a turn, which frees 20
seconds after someone stops dragging. These numbers are small on purpose for now; the capacity study puts
the cheapest droplet at about 80 playing at once.

## Where it runs

**Dog Park will go live at https://dogpark.lynrummy.com** on its own
droplet, booted from an image with no Linux on it. The image is the
[zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)
kernel with Dog Park built in, the same way lynrummy.com is served.
Prod's Caddy will hold HTTPS and forward to it over the private network. The image is built and rehearsed under QEMU on a
droplet-sized machine. [DEPLOY.md](DEPLOY.md) is the deploy, step by step.

Today it is played on the development box: `zig build play` serves
`localhost:9103`.

## Running it

    zig build play       # serve on localhost:9103, from the checkout

Every build needs its sibling checkouts beside this one:
- `../zig-webbox`;
- `../zig-metal-unikernel`;
- `../zig-coverage-sdk`, at the commit the kernel pins.

Zig runs a path dependency's build at every configure, so even a plain
`zig build` needs all three.

The cookie is Secure, which a browser keeps only over HTTPS (or from
localhost). A development server on plain http at an address sets
`DOGPARK_INSECURE_COOKIE=yes`.

### On metal

    zig build metal      # zig-out/bin/dogpark.elf, ReleaseSafe (~30 s)

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

    zig build metal-gate --summary all   # ~6 s warm

**Run it last, before a Dog Park deploy, never out of habit;** it is in no
test tier. `tools/metal_gate.mjs` boots dogpark.elf under QEMU on a fresh
disk, then checks, failing loudly with the step and the guest's log:
- **Getting in:** the landing page, and Begin Game's Secure cookie.
- **The page:** it loads, with byte-identical wasm.
- **A session:** a load, a leash and a drag through the page's own code,
  with every report kept.
- **The admin page:** it works with the key and refuses without it.
- **The guest:** its log has no errors, and the disk passes `fsck`.
- **A second boot on the same disk:** the cookie still reads, and the game
  is picked up where it was.

### On Linux, behind Caddy

The metal droplet is the plan, but the Linux server can serve it just as
well:
- **The binary:** `zig build -Doptimize=ReleaseSafe`. The server reads
  the page from `solo/` in the directory it runs in, so ship
  `zig-out/bin/dog-park-play` and `solo/` together, and start it from
  there.
- **The config:** `DOGPARK_CONFIG` names a file with `data_dir = …` and
  `auth_dir = …`.
  - The data dir holds the games (`game-<slot>/`) and the account count
    (`players`). Each game's log rotates at 1 MiB. Closed logs are kept
    for an hour, at most 25 MB a game.
  - The auth dir holds the site secret and the admin key, both made on
    the first start.
  - To hand out the accounts again, stop the server and delete `players`
    and `game-*`. Delete the secret too to make every old cookie invalid.
- **The environment:**
  - `DOGPARK_PORT` (default 9103);
  - `DOGPARK_BIND` (bind 127.0.0.1 behind Caddy);
  - `DOGPARK_TRUSTED_PROXY` (default 127.0.0.1).

  Never set `DOGPARK_INSECURE_COOKIE` behind HTTPS.
- **Caddy:** `reverse_proxy 127.0.0.1:9103` for the site's name. Every
  route is a plain request and answer.

### The operator's pages

`/admin/game` shows accounts, turns, and each game's state: its last
request, leash, tick, herd, poops, logs, and any findings. `/admin/host`
shows requests, errors, memory and the host's facts.

Both need the admin key, either as a bearer token
(`curl -H "Authorization: Bearer $(cat <auth>/_admin_key)"`) or through
`/admin`'s login form in a browser.

### Running a script (Shale, for monitoring)

`POST /admin/script` takes a Shale script, signed, and runs it in the
**background**: it only reads, a slice at a time between requests, so play
keeps the turn first (src/play/shale.zig; the envelope, the sequence numbers
and the run are zig-webbox's `script_route`). `GET /admin/script` shows the
run going, or the last one that ended, and what it printed. Both take the
admin key, as the other `/admin` pages do. An atomic script, which could
write, is refused: Dog Park runs background scripts only.

- **The key** is Dog Park's own, never lynrummy's. Make a pair with
  zig-webbox's `shale-sign keygen`, then, in the auth dir, set it by hand:
  `shale.conf` holding `public_key = <64 hex>` and `target = <the host>`
  (`dogpark.lynrummy.com`), and `shale/sequence` holding the Unix seconds
  now, so nothing signed before it runs. With no `shale.conf` the route is
  off (403 `no_key`).
- **Sign and send** with `shale-sign sign`, adding `mode=background` (or a
  `mode=kill` to end the run going), and `curl` with the admin bearer.
- **The cookbook,** in `tools/shale/`: `games.shale` (each game's kept tick,
  last log and log bytes), `trouble.shale` (each game's last hour: reports,
  `req ?`, overlaps, idle drags, stuck, refused lines) and `accounts.shale`
  (accounts against the 80, games started).
- **The budgets** (`shale.budgets`): 50M steps, an 8 MiB arena, 10,000
  store reads and 256 MiB read in all, no changes; a slice is at most
  100,000 steps or one store call, and each call's work is capped (a
  megabyte a read or scan, 256 entries a walk).
- **On metal, not yet:** the kernel does not step a background run between
  requests (metal-vmm QUEUE 211, the box's), so there the route refuses one
  (501 `no_background`). On Linux, `:9103`, it runs.

## The tests

How the critters move is tested by playing. The automated tests each have
a purpose, and [docs/PHYSICS.md](docs/PHYSICS.md) lists them:
- critters never overlap;
- the page and the server agree;
- the protocol;
- the wrapping world and its tiles;
- poop and chickens never landing anyone on anything.

A test that no longer proves anything goes.

    zig build test       # after every edit, ~4 s
    zig build check      # before a commit, ~14 s
    zig build slow       # the slow tier, ~20 s

- **`test`:** every Zig unit test natively, with the seeded fuzz loops at a
  tenth, and the node tests that need no server.
- **`check`:** `test`, plus the physics' tests compiled to wasm and run
  under node, and the node tests against a scratch server.
- **`slow`:** the full fuzz, the physics' tests on wasm in ReleaseSafe as
  the page is served, and every node test.

`-Dfuzz=full` gives any step the full fuzz; `zig build physics-test` runs
the physics' tests alone. The benches (`zig build physics-bench`,
`zig build physics-server-bench`, `node tools/bench_page.mjs`) are in no
tier.

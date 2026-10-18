# Dog Park's physics, and the report that carries it

**Status: played by Steve** (the small world). The board, the tick, the wire
and the server's re-run are `src/play/physics*.zig`, with the world
said in Roc: `roc/world.roc` says its size, the park in it and the first
layout, and `zig build roc` prints them into `src/play/world.zon`
(which `world.zig` imports, checked in) and `solo/world.js` (the page's
numbers); and what critters do about each other said in Roc too:
`roc/Rules.roc`, which the critters' wish (`roc/Wish.roc`, linked into the
physics) applies, and which `roc/rules.roc` prints into `src/play/rules.zon`
for the Zig's other uses; and the walk, each pixel-tick's moves after the
leashed dog's, in Roc as well (`roc/Walk.roc`). The physics' routes are `/physics-<hash>.wasm`,
`POST /load` and `POST /report` (the README has the rest), and each game
keeps its board under `<data>/game-<slot>/physics`. The page runs the same Zig as
`physics.wasm` (`physics_page.zig`'s exports, in the physics hash, named
by `index.html`); `solo/engine.js` keeps the record and the protocol.
The client-driven design (the essay
[the client drives](https://github.com/showell/essay-repl-server/blob/master/notes/the-client-drives.md)):
the page runs every tick, and the server re-runs, keeps and acks. Steve
tunes the physics by playing it.

**Tested, each with a purpose** (the README has the tiers):
- **the invariant:** no two critters ever overlap and none stands on
  poop, over seeded drags through the whole park that lay poop and shove
  chickens (`physics_test.zig`);
- **poop and chickens:** the trail comes from the herd's tail, going
  around never lands anyone on anything, the leashed dog doesn't bump
  what it can get around, eating, ripeness, the poops by tile
  (`physics_trails_test.zig`);
- **page and server agree:** the same physics compiled to wasm32 passes
  the same tests, and a page holding more tiles writes the same lines;
- **the protocol:** the wire, the judge's answers, the server's log,
  snapshots and restarts, the page's engine (`physics_wire_test.zig`,
  `physics_judge_test.zig`, `physics_server_test.zig`, the node tests);
- **the torus and the tiles:** the seam, the region's wrapped tiles.

The motion itself (who goes where, and how herds feel) is tested by
playing, not by unit tests.

## The rules

- **No randomness, no clock.** A tick is a function of the board and the
  player's inputs; drags are displacements.
- **Positions in 256ths of a pixel; 16 ticks a second;** the world is a
  6 × 6-tile torus of 350 px tiles, 2,100 px a side (decision 14,
  made small 2026-10-15), the park its middle 4 × 4 with a ring of empty
  tiles round it.
- **Distance is the larger axis** (Chebyshev, decision 19): every reach
  is a square, as the critters are.
- **Nothing moves unless the leashed dog is dragged** (decision 21).
- **No two critters ever overlap,** by induction: the first layout has
  none, and no step lands anyone on anyone.

## A tick

1. **The inputs** (`leash`, `grab`, `letgo`, `release`), in order.
2. **The drag, if one is on,** as its x part then its y part, cut into
   **pixel-ticks** of at most 1 px (decision 15). In each:
   - **the leashed dog** takes the step, swept against everyone it sees,
     stopping just short of pressing into anyone. Stopped by a chicken, it
     shoves it; stopped by a poop, or a chicken it can't shove, it slides
     the step's size sideways (decision 30). **A bump ends the drag, not
     the leash:** a dog or a cow in the way, or a slide that fails too;
     the rest of the tick's drag is dropped, the pointer is let go, and
     the let-go timer starts;
   - **then the walk** (below), if the leashed dog moved;
   - **then the poops due:** one for each 700 px its walk passed in the
     step, laid by the herd's deepest dog (below).
3. **The chickens' turn** (decision 31), once, after the drag, bumped or
   not, if the leashed dog's net move over the tick is more than nothing
   (below).
4. **The timer:** the leash comes off 320 ticks (20 s) after the drag
   ended, unless a `grab` came first. Unleashing puts the park to sleep.
5. **The checked lines:** every critter whose place changed over the
   tick, then a `bump`, a `release`, or a `rest` (nothing moved, no input
   but a `view` or `held`, no timer running: the page stops ticking until
   the human acts).

## The walk (decisions 20-22, 30, 31)

**The walk is Roc's** (`roc/Walk.roc`, linked into the physics through
`src/play/roc_physics.zig`): once a pixel-tick, after the leashed dog's
step, the Zig lends it the seen critters (where each stands, the cell it
stands in, what it is), every cell's set of them, the poops by tile and
room for its working lists, all as lists over the Zig's own buffers; Roc
moves the critters in place, keeping the cells as it goes, and hands the
lists back with the visit order and the pooper. Neither side allocates.
The leashed dog's own step (the sweep, the bump, going around), the poop
laid after the walk and the chickens' turn stay Zig's. Its tests are
Roc's (`zig build roc-test`); while the Zig tests run, the Zig walk it
replaced walks a copy of every pixel-tick too, and must agree to the bit.
Its cost (2026-10-18, the busiest spot's full drag, 20 ticks): about 1.4x
the all-Zig walk's natively (144 ms against 105), and on the page's wasm
a 32-tick replay of 7.3 ms against 6.7, a packed herd's full drag 13.5 ms
against 11.8. Why it costs what it does, and the rules that keep Roc
fast, are [ROC-SPEED.md](ROC-SPEED.md).

After each pixel-tick of the leashed dog, up to **48** critters move, one
at a time, out from the leashed dog, **shortest link first.** Only dogs
and cows: chickens have left the walk (decision 31) and take none of its
48.
- the leashed dog lines up its **3** nearest critters, dogs or cows,
  each waiting keyed by its distance from the critter that lined it up;
- the walk visits the waiting critter with the least key (ties to the
  lower rank: cows by number, then dogs by number); it works out its
  wish, steps, and lines up its own 3 nearest not yet visited, from where
  it now stands. A critter already waiting takes the nearer of its keys;
- so a pack close together is walked to its end before a critter farther
  from whoever found it, however near the leashed dog that one is. A
  critter the walk doesn't reach stays put this pixel-tick.

**A critter reacts only to critters in motion:** the leashed dog and the
critters the walk visited before it this pixel-tick, where they now
stand. Its wish is computed in Roc (`roc/Wish.roc`, which the physics
links: the Zig hands it the moving critters near it, who each is to it and
the vectors between them the short way round, and takes back a step and an
anchor). How it reacts is the rules' (`roc/Rules.roc`): for each kind, an
answer to each kind it sees (keep a distance, herd against the nearest,
close in, or nothing), and whether it sums every answer or takes its
nearest moving critter's alone.
- **A dog** keeps `wary` (158 px) from each moving dog of another breed,
  `cow_room` (63 px) from each moving cow, and its place in the herd: its
  **anchor** is the nearest moving dog of its own breed (the leashed dog
  leads its breed). Past the band's outer edge (70 px) it wants to close
  the excess; inside the inner edge (42 px) to open the shortfall; in the
  band it is content.
- **A cow** heeds only its **nearest** moving critter (ties to the lower
  rank), at any distance: a cow within `cow_pull` (245 px), it closes the
  gap to touching (a cow farther off pulls nothing); a dog, it
  keeps `wary` from it (decision 24). Cows are, in effect, a slower breed
  that follows its nearest kin instead of the leashed dog.

Each wish is a step straight away from (or toward) the other, as long as
the shortfall (or the excess); they add up. The step is the total, cut to
the pixel-tick's move for a dog and half of it for a cow; a total under
the **dead zone** (1 px) is no step. **The veto:** a critter takes its
step whole, or not at all if its square there would overlap anyone who
isn't kin. **The nudge**
(decision 25): kin in the way (a cow for a cow, a dog of its breed for a
dog, never the leashed dog) take the same step with it, and nudge their
own kin in turn, up to `nudge_most` (8) in all; if any of them is
blocked, none moves. Nobody is ever pressed into, and still critters
never attract or repel.

**Going around** (decision 30):
- **The shove.** A chicken in the way of a dog or a cow of the step is
  knocked by the step plus as much again sideways, away from that
  critter's centre line (on the line: south, or east for a step north or
  south). It counts only if every chicken shoved lands clear of every
  critter (where the step leaves each one: still, nudged or shoved) and of
  every poop; all is checked before anyone moves, and
  then all move or none. So a chicken slides off the front of a dog
  within about 30 px instead of being plowed ahead. A chicken shoves
  nobody.
- **The sidestep.** A step vetoed by a poop, or by a chicken it can't
  shove, is tried once more: zero the step on the axis where the blocker
  is farther off (a tie zeroes x); on the other, keep the step's own
  part, or, if it has none, go the step's whole size away from the
  blocker (on the line, +). Vetoed again, the critter stays.
- **The leashed dog** is swept, not vetoed: stopped by a chicken, it
  shoves it with the rest of its step; stopped by a poop or a chicken it
  can't shove, it slides the step's size (1 px) sideways, away from it,
  whole or not at all. It bumps only when the slide fails too. There is
  no setback.

## Poop and chickens (decisions 29-31)

The herds leave a trail of poop behind them, and the chickens clean it up:
quickly enough that the park doesn't fill, slowly enough that you see
where the herds went. Neither gets in the way: what's in the way is gone
around, not stopped at.

**The trail** (decision 29):
- **When:** each time the leashed dog's walk (every step it takes,
  counted by its larger axis) passes another 700 px, after that
  pixel-tick's walk.
- **Who:** the deepest dog of the leashed dog's breed in that walk. The
  leashed dog has depth 0; a visited dog whose anchor is dog j has j's
  depth + 1; the greatest depth wins, ties to the dog visited later; with
  no follower, the leashed dog. Depth lives only for that walk.
- **Where:** 30 px (centre to centre) **behind** the pooper: away from its
  anchor; for the leashed dog, back along its step. That spot taken, the
  spots on rings 4 px apart around it, out to 200 px, each ring walked
  clockwise from its north-west corner. A spot must overlap no critter
  and no poop the physics sees. None fits: no poop.
- **Poop stays until a chicken eats it.** The park's poops take 2048
  slots in turn, counted since the load (`laid`, on the `state` line), so
  only the 2049th would take the first one's slot.
- **Poop blocks dogs and cows;** nothing pushes it. A step onto one is
  vetoed, then sidestepped; the leashed dog slides around it.
- **Ripe:** every poop is ripe but the park's newest, the one in slot
  `laid − 1` mod 2048 (`ripe(laid, n)`): it comes free from the slot
  counter.

**Chickens** (two to each blue tile, a 20 px square; decision 31) are no
part of the walk. Every other critter treats one as an obstacle it may
shove (above) and nothing more: no dog or cow reacts to one.
- **The chickens' turn:** once a tick, after the drag, and only if the
  leashed dog's net move over the tick (its larger axis) is more than
  nothing. Every chicken the physics sees, in number order, steps at
  most half that move and at most 8 px:
  - **forage:** toward the nearest ripe poop within 500 px (ties to the
    lower slot), going around what blocks it (the sidestep);
  - **else go home:** toward its spot in the first layout
    (`layout.chickenHome`) when more than 32 px from it, whole or not at
    all: blocked, it waits;
  - **else it stays put,** and writes no line, so the report stays small.
- **Eating:** after its step, a chicken eats every ripe poop its square
  overlaps.
- **No critter ever stands on poop** (`onPoops`, in the server's
  invariant): a dog's or a cow's step never lands on one; a chicken's own
  step is vetoed only by the newest, and it eats a ripe one it lands on
  there and then; a shove lands clear of every poop.

**The cost:** every square that asks about poop asks only the tiles of
the span it could reach (the Scene keeps a list of its poops by tile). A
full drag at the park's busiest spot with 500 poops in view costs what
it does with none (`zig build physics-bench`).

**On the wire:** a tick's checked lines add ` poop N x,y` (slot N holds a
new poop) and ` eaten N` (a poop the region's tiles held is gone), by
slot, after the critter lines. `tile`, `board` and snapshot entries add
`chicken N x,y` and `poop N x,y`, and a dog that has walked carries
`walked H` (hex with a point) after its position. A `board` line names
every poop in the region's tiles; the page drops its others there.

## The numbers

Tuned by playing. The critters' distances from each other (wary, the
herd band, a dog's room from a cow, `cow_pull`), their paces, the
chickens' foraging and the poop's are `roc/Rules.roc`'s; the rest are
constants in `physics.zig`.

| knob | value |
|---|---|
| tick | 16 a second (62.5 ms) |
| pixel-tick | `step_most`, at most 1 px |
| a tick's drag | `cap`, at most 100 px on each axis |
| the walk | `walk_most` 48 critters, `walk_fan` 3 each |
| wary | 158 px |
| herd band | 42 to 70 px |
| a dog's room from a cow | 63 px |
| a cow closes on its nearest moving cow | to touching, only within `cow_pull` 245 px |
| the nudge | `nudge_most` 8 critters, kin only |
| dead zone | 1 px |
| the region | the whole world, always |
| the leash off | 320 ticks (20 s) after the drag ends |
| the squares | dogs 28 px, cows 42 px, chickens 20 px, poop 12 px |
| poop | every 700 px the leashed dog walks, by the herd's deepest dog, 30 px behind it; else on rings 4 px apart out to 200 px; 2048 slots, in turn; all ripe but the newest |
| the leashed dog stopped by poop or a chicken | slides 1 px sideways; shoves a chicken first |
| a shove | the step, plus as much again sideways |
| a chicken | once a tick; sees ripe poop 500 px off; steps at most half the leashed dog's net move, and 8 px; goes home past 32 px off |
| the first layout | `roc/world.roc`, through `world.zon` and `layout.zig`: 64 dogs, four to a tile, one breed per corner; 8 cows, one in each white tile; 16 chickens, two side by side in the middle of each blue tile |
| the goal | the 8 cows in one herd: linked when within two cow-widths (84 px), round the torus (`scene.js`'s `largestHerd`) |

**Arithmetic.** Positions are integer 256ths; every product is `i64`, and
only a quotient comes back to `i32`. A wish's axis is the vector's axis
times the wish's length over the vector's length (`quotientAlong`),
truncated toward zero. Page and server agree to the bit through the same
compiled code. On the wire a position is hex with a point: `d80.40` is
3456 and 64/256 px.

## What the physics sees

**Every critter in the world, always** (2026-10-15). The world is 36
tiles; the region (`physics.region`) is all of them, wherever the leashed
dog stands, so no critter is ever unseen and there is no edge for a step
to keep clear of. The neighbour searches (the walk's rings, the cells, the
poops by tile) wrap round the torus.

**Subscriptions are not the physics** (decision 13). The checkerboard is
how the page learns about critters; the region is what the physics acts
on.
- **Subscriptions are the page's business, driven by the display.** The
  page subscribes enough tiles to use its display fairly fully (not
  necessarily the whole window), **and** every tile meeting the region
  while a dog is leashed. It fetches **proactively,** leashed or not: a
  resize on a large monitor brings in the new tiles at once, dormant
  critters and all, and so does a pan.
- **So subscribing is not an input to the physics.** More tiles change
  what the page knows and draws, never what the physics does: it sees
  only the region's tiles, and the page runs no tick until it holds them
  all (below). This holds for a fixed sequence of the human's other
  inputs: a display can still change *when* reports go (a bigger `view`
  fills the byte budget sooner) and when the page freezes waiting for
  tiles, and so how the pointer's movement is merged into ticks. Given the
  same inputs, the lines are the same.
- **The page waits for the region's tiles.** It runs tick T only when
  every tile in the world meeting T's region is held: named in a `held`
  line at T or before, and still subscribed by the view in effect.
  Otherwise it freezes, as at the 32-tick window (drawing, the pointer's
  movement adding up), until an answer brings the tiles. The server
  answers `differ T none` the `t` line of a tick whose region meets a tile
  not held. So nothing the physics could touch is ever missing on the
  page.
- **How subscriptions travel:** a `view` line in a report, at the tick it
  takes effect, with the viewport's size (decision 2). There is no
  separate request. The server's re-run uses a `view` only for which tiles
  to send and which are still held; the physics never reads it.
- **What the server sends back:** with **every** answer, the critters of every tile the latest kept `view` subscribes
  that the page hasn't yet named in a `held` this epoch, as they stand at
  the answer's last kept tick (current: a critter the physics doesn't see
  doesn't move). The server tracks that per epoch, so a `differ`, or a
  lost answer and a resend, still delivers them. A tile named in a kept
  `held` this epoch is never sent again; the page re-holds it from what it
  kept.
- **A `held T c,r …` line** says the page has those tiles' critters from
  the start of tick T: an input, so the server counts exactly the tiles
  the page did, whenever the acks arrived. The server checks that it names
  only tiles whose critters it has sent this epoch and that the `view` in
  effect at T subscribes; otherwise `differ` at that line.
- **A tick's drag moves the leashed dog at most 100 px on each axis.** A
  faster flick is cut there for that tick (the drag is held to a stricter
  rule, as allowed above). That is why the region is in the square metric.

**A leash, step by step.** The human leashes dog D while the page is idle
at tick K: the page records `leash K+1 D` and a `view K+1` adding the
region's tiles, and sends them (inputs with no tick). It can't run K + 1
until the region's tiles are held, so it freezes until the answer brings
them; then it records `held K+1 …` and runs the tick. Inputs for one tick
may come in two reports this way, as long as its `t` line hasn't been
kept. Right after a leash, or on a drag toward ground the display hasn't
loaded, the park pauses for about one round trip.

A report may carry no ticks at all: a resize, or panning while nothing is
leashed, is just a `view` line. **An input while the page isn't ticking**
(a `view`, a `held`, a `leash`, a `grab`, a `letgo`) takes the last
recorded tick + 1, as a `leash` does; several at one tick apply
in the order written. **At most 16 of the human's inputs a tick**
(`leash`, `grab`, `letgo`, `release`), across reports; the page drops a
17th (freezing makes many at one tick easy) and logs it. Several at one
tick apply in the order recorded, so `grab`, `letgo`, `grab` at one tick
leaves a drag on, with the first drag's displacements played before the
`letgo`. `view` and `held` never count, however long the human
pans: at one tick, **the page coalesces them** to one `view` (the union
of every view written for that tick, so a coalesced view never drops a
tile one of them added, a replay's included) and one `held` naming only
tiles in that view, so a long pan can't grow a
report. During a replay held back at the byte
budget, "the last recorded tick" is the last tick the page has
recorded, never one inside the held-back ticks. While unleashed, any
input other than a `view` or `held` starts the ticking at that tick.

One player and one window, so nothing disagrees. Two windows of
different sizes on one park would each be right about their own physics.
That only matters when there are two players.

**Unleashing puts the park to sleep.** The leash comes off when the human
grabs another dog, or **320 ticks (20 s)** after the drag last ended
(the human let go, or a bump ended it) with no new drag. Grabbing the
leashed dog again at any tick up to and including T + 320 (T the tick
the drag ended) is a new drag (`grab`), and the timer stops: inputs come
before a tick's checked lines, so a `grab` at T + 320 beats the
`release`. While those 320 ticks run, the page keeps ticking (a board can't `rest` during them), so
the release lands on the same tick on both sides. Then every critter
stops where it is, and the page stops ticking until the next leash.

## Wall time

**The physics has no clock.** A tick is a step, not a duration. The page
runs 16 a second by its own clock (`requestAnimationFrame`), and that's
the only place wall time paces anything. A slow laptop ticks slowly and
the physics is unchanged; a page in a background tab doesn't tick at
all, and on its return catches up at most 8 ticks
(`most_catch_up_ticks`, `solo/engine.js`); the rest are dropped, never
owed.

**The report records it anyway,** as data, not proof:
- **`wall`** in the header: the wall-clock time (Unix ms) at the report's
  first tick.
- **`+ms` on each `t` line:** when that tick began, from `wall`.
- **`@ms` on each drag point:** when the pointer was there, from its
  tick's start.

The server keeps these in the log and never checks them. They can't
cause a `differ`. They're there for the day we tune by velocity, for
reading a log ("that drag took 40 ms"), and for seeing a page that
ticks late.

## What the page draws

The page draws on its own frames, between ticks: each critter part way
from where it was at the tick before to where it is now (`between` in
`scene.js`). Under each dog, its number, and its place in the last walk
(`212 #4`); under a cow, its place in the walk when it had one. The walk's
order is drawing data from the wasm (`walkAt`), not on the wire.

## The report

One report per round trip, as moves are sent today: everything since the
last tick the server kept. For now it says a lot. It names every critter
that moved, where it was and where it went, **in rank order** (the
leashed dog, then cows by number, then dogs by number), so the report is the
calculation written out and the server checks it line by line. (The
physics hash `5e0c91a2` in the examples is a placeholder; the real one is
`physics_wire.physics_hash`, a compile-time CRC-32 of the physics' sources.)

```
dogpark 1 physics 5e0c91a2 page 1791935990000.3 req 4
from 1040 wall 1791936000000
t 1041 +0 drag -1.00,0@3 -2.00,0@19
 dog 19 3e8.00,3e8.00 > 3e5.00,3e8.00
 cow 2 36b.00,36b.00 > 369.89,369.80
 dog 23 451.00,3e8.00 > 44e.00,3e8.00
letgo 1042
t 1042 +63
t 1043 +125
```

The numbers follow the rules (the report and its `kept` answer are the
code's own: the golden fixtures in `physics_judge_test.zig`). The board:
the park as laid out (the cows in the white tiles' middles, the chickens
in the blue), with dog 19 at (1000, 1000) and dog 23, of its breed, 105 px
east of it; the other dogs are off the board, so the example stays small.
Request 3 carried `leash 1041 19` as an input with no tick; the page holds
the whole world already, so it runs 1041 at once. The drag is 3 px west:
three pixel-ticks. In each, dog 19 steps 1 px west, then the walk visits
its nearest critters: dog 23 stands 105 px east, 35 past the band's outer
edge, so it steps the full pixel west after 19; cow 2, at (875, 875), is
125 px from dog 19, inside `wary`, and it is its nearest moving critter,
so it backs away (decision 24) at half a pixel-tick's step, along the
line from the dog. 1042 and 1043 have no drag, so nothing moves; the
let-go timer (320 ticks) runs from 1042.

| line | says |
|---|---|
| `dogpark 1 physics H page E req R` | the language's version; the physics' version, a hash of the physics' sources built into both the wasm and the server, so a forgotten version change can't cause endless disagreement; this page load's epoch, which the server issued, unique across the server's runs (its start, Unix ms, a point, and a count: `1791935990000.3`); and the request number (below) |
| `from T wall W` | the tick the report starts after (the last one the server kept), and the wall clock (Unix ms) at its first tick, data only (no `wall` on a report with no ticks) |
| `leash T D` | the human leashed dog D at tick T: the park wakes around it |
| `grab T` | the pointer went down on the leashed dog at tick T: a drag is on, and any let-go timer stops (a `leash` implies it) |
| `letgo T` | the drag ended at tick T because the human let go: the let-go ticks (`let_go_ticks`, 320) start |
| `bump T dog N`, `bump T cow N`, `bump T chicken N`, `bump T poop N` | the drag ended at tick T because the leashed dog pressed into that critter or poop: the let-go ticks start, the leash stays |
| `release T D` | the leash came off dog D at tick T (the let-go ticks ran out, or another dog was grabbed): the park sleeps |
| `held T c,r …` | from the start of tick T, the page holds these tiles' critters (they arrived with an ack): an input, so the server counts exactly the tiles the page did. A tile list (here and in `view`, `state`) is a set: listed in any order, compared as a set |
| `view T WxH c,r …` | from the start of tick T, the viewport's size and the tiles the page subscribes: which tiles the server sends, and which stay held. Never an input to the physics. Written whenever the subscription changes: a leash, a release, a pan, a resize, the region reaching new tiles |
| `t T +ms` | tick T begins, `+ms` after `wall` (data only). `drag` and its displacements in 256ths, when the human dragged during it, each with `@ms` from the tick's start (data only); at most 16 a tick (the shared Zig adds up any more). A tick that bumps carries its whole recorded drag, merged and capped, the displacements after the bump included: the physics drops those, and the server finds the bump itself |
| `dog N a > b`, `cow N a > b` | written with exactly one leading space, the one canonical form (none, or two, is refused); `differ` quotes a critter line unindented, the server's and the report's alike. A critter whose position changed over tick T, from a to b, in cascade order: the leashed dog, then cows by number, then dogs by number. A line is the net move over the tick; a critter that ends the tick where it began is not listed, even if it moved within it |
| `rest T` | no critter's position changed over tick T, the human gave no input but a `view` or `held`, and no let-go timer is running: a fixed point, so the page stops ticking until the human acts again (`drag`, `grab`, `letgo`, `leash`; a `view` or `held` doesn't count). Tick numbers carry on across a rest |

**Why before-and-after, and not a hash.** A hash says *whether* page and
server agree. Lines say *where they first don't*: the tick, the critter,
and which coordinate. The before positions repeat what the previous line
already implies. That redundancy is the point: each line is checkable on
its own, and reads as a diff of the board. Once the physics is trusted,
dropping the before positions, or going to a hash every few ticks, is a
small change to the language. Its version number is there for that.

**The size, and the window.** A critter line is about 41 bytes. The page
runs at most **N = 32 ticks** (2 s) past the last kept tick, so a report
holds at most 32 ticks: a few KB usually. Dog Park's body limit becomes
64 KiB (from 4 KiB; metal's body rule is built for that), and a big herd
on the move could pass it in 32 ticks (50 critters moving every tick is
about 2 KB a tick), so the page also counts **bytes**: it sends as soon
as its unsent text reaches **48 KiB** (when none is in flight), and
freezes the physics while unsent text is at 48 KiB or more, as at the
32-tick window. One tick is far smaller than the 16 KiB of headroom, so a
report never passes 64 KiB. **A replay obeys the same budget:** after a
`differ`, the page regenerates the ticks from T only until the unsent
text reaches 48 KiB, stopping on a tick boundary, and holds the rest of
its recorded inputs, frozen, until the ack; the human's inputs meanwhile
go after the last recorded tick. The parse bounds the lines too: at most one
critter line per critter the page has, a tick, 16 displacements and 16 of
the human's inputs a tick (`view` and `held` don't count), 32 ticks.
A `board` holds only the critters the physics sees and the ones the report named,
so it is bounded the same way.

**Request numbers.** A report's header carries `req R`: 1 for an epoch's
first report, one more for each new request. **One request is in flight
at a time,** and every answer begins `req R`, echoing it. The page acts
only on the answer to its in-flight request (the exchange it came back
on, whose `req` must match), and any such answer ends that request; every
other answer is dropped unread.
- **No answer, or a 5xx: transient.** If no answer comes within 5 s of
  wall time, or the answer is a 5xx (a deploy, a restart, Caddy's 502),
  the page abandons the exchange and sends request R again, **byte for
  byte the same**, waiting 5 s, then 10, 20, 40, and 60 s between every
  later try; anything recorded since waits for R + 1. A transient failure
  never stops the page.
- **Anything else that isn't an answer it can act on stops the page**
  (decision 17): a 413, a body it can't parse, an answer echoing another
  `req`, `req ?`, and every `reload` answer. **The page never reloads on
  its own:** it stops, its screen paused, and logs the why, the last
  report sent and its answer on the console, so Steve can report it.
  Reloading the page (a load, which picks the game up) is the human's act. A
  stop on the first report after a load says the page's reports can't be
  taken.
- **The server keeps its last answer.** A report whose R is the last one
  it answered gets that same answer again: nothing is re-run, logged or
  counted. It keeps a hash of that report's body too: a report reusing R
  with a different body is a page bug, refused (`differ K+1 none` its
  header line), counted as a `differ`, and logged; the stored answer and
  its hash stay the original's. A report whose R is one more is a new request, and from then
  on R is the last answered, whatever the answer (a refusal included).
  Any other R is refused (`differ K+1 none` its header line).
- **`req ?`:** the server couldn't read the header, so it answered no R,
  and the answer is `req ?` alone: no `differ`, state or board. Resending
  the same bytes would garble the same way, so the page stops (above): a
  page bug, and nothing the server can fix. The server counts every `req ?` on one counter for its
  run and logs each as a finding.
- **The server handles requests one at a time,** in the order they
  arrive, so an original and its resend can't both be new.

So a lost answer costs one resend, and the page never meets an answer to
anything but what it last asked.

**The server's answers.** The answer to the example report, when all is
well, and had the page written dog 23's step at 1041 a 256th off:

```
req 4
kept 1043
```
```
req 4
kept 1040
differ 1041 dog 23 451.00,3e8.00 > 44e.00,3e8.00
state leash none drag none laid 0 view 1280x800 (the 36 tiles) held (the 36 tiles)
input leash 1041 19
board 1041 (every critter, as it stood: the two dogs, the cows, the chickens)
```

In the second: nothing of the report is kept (it differs at its first
tick); the server's own line for 1041; at the start of 1041, before its
inputs, nothing leashed, the view of the region's tiles and the
viewport's 8 held; the `leash` request 3 kept for 1041, which the page
plays again; and the critters the report named, as they stood.

| answer line | says |
|---|---|
| `req R` | first in every answer to a report: the report's request number. `req ?`, alone, when the server can't read the header; the page takes it as the answer to the exchange it came back on, and stops |
| `epoch E` | first in a load's answer (a load is not a report and has no `req`; the table's "first in every answer" is for answers to reports): the new epoch; request numbers start at 1 |
| `kept T` | the last kept tick, after this request. With no `differ` after it, the whole report is kept: its ticks through T, and any inputs it carried for T + 1 after its last `t` line (they wait for that tick; a later report may add more for T + 1 before its `t` line). A report with no ticks gets `kept` its own `from` |
| `differ T <line>` | the server's run has this line at tick T, and the report lacks it or writes it differently. The report is kept through T − 1 (the `kept` above), nothing of its own at T |
| `differ T none <line>` | the report has this line at tick T, and the server's run doesn't; also every **refused** line: malformed, out of bounds, an input whose precondition fails (below), or the `t` line of a tick whose region meets a tile not held. A malformed line belongs to the current tick if it looks like a critter, `bump` or `rest` line; anything else after a tick's checked lines, to the next tick |
| `state leash D\|none drag on\|ended E\|none laid N view WxH c,r … held c,r …` | at the start of tick T (K + 1 for a load), before that tick's inputs: who is leashed; whether a drag is on, or the tick E it ended (the release is due at E + `let_go_ticks`), or none (unleashed); the poops the park has laid since its layout; the view and the held tiles in effect, a `view` or `held` an earlier request kept for T included. The server writes tiles row, then column; a tile listed twice in one list is refused |
| `board T dog N a cow M b …` | with `differ`: the server's critters at the start of tick T, in rank order: every one it saw at the start of T (in the region's tiles around the `state` line's leashed dog), and every one the report named |
| `input <line>` | with a load or a `differ`: an input an earlier request already kept for that tick (K + 1, or T), as written, in order, after the `state` line's moment. Only `release`, `leash`, `grab` and `letgo`: a `view` or `held` is in the `state` line. The page plays it at that tick and never sends it again |
| `tile c,r dog N a cow M b …` | in any answer but `req ?`: a subscribed tile's critters not yet named in a kept `held` this epoch, as they stand at the start of the tick after `kept`; the page applies them to its board at the last kept tick, to critters it hasn't received this epoch only |
| `reload language N`, `reload physics H`, `reload epoch`, `reload from K`, `reload differs` | the page speaks another version of the language (N is the server's); its physics isn't the server's (H is the server's); its epoch is not one this run of the server issued; its `from` isn't the last kept tick K (with request numbers only a page bug does that); three requests in a row were answered `differ`. The page stops on each (decision 17); a reload by the human starts again |
| `taken over` | a newer page load holds the park |
| `stuck T` | the physics disagrees with itself at tick T (below): the page shows that, and doesn't tick |

- **`kept T`:** checked, and written to the game's log and synced to disk
  before the answer goes: safe. Every answer also carries the critters of the subscribed tiles the page hasn't named in a
  `held` yet (above).
- **`differ T`:** the first line the server's re-run disagreed with, with
  the server's own version of it: `differ T <the server's line>` when its
  run has a line the report lacks or writes differently (critter, `bump`,
  `rest` or `release` alike), and `differ T none <the report's line>` when
  the report has a line its run doesn't, or a line it refuses. Then the
  `state` at the start of tick T (before its inputs), any `input` lines
  an earlier request kept for T, and the `board`. Everything before tick T is
  kept: the report's ticks through T − 1 are logged and synced before the
  answer goes. If the server's run has a bump the page's didn't, the page
  lets go of the pointer.

**How the page rewinds.** The board in a `differ` holds only some
critters, and the page may already have moved others in ticks it hasn't
sent, so it never rewinds from its current positions. It keeps its own
**board at the last kept tick** (every critter it has, the leash, the
drag or timer, the view, the held tiles), and moves it forward on each
`kept`, replaying the ticks the server kept. On `differ T`, it replays
from that board through T − 1 (ticks the server kept, so the two agree),
lays the server's board over the result (a critter in it takes the
server's position; the rest stand), takes the `state` line's leash, drag,
view and held tiles, and replays its own inputs from T.

**What a rewind can heal.** Page and server run the same compiled code,
so replaying the same inputs reproduces the same lines. A rewind heals
only what went wrong on the page's side: a page bug outside the shared
Zig, state that drifted, a stale or tampered page. A real disagreement
in the shared code comes back each time; the breaker and `stuck` (below)
are for that. Nobody should expect a rewind to fix the rule.

- **`reload`:** the page stops, saying why (decision 17); the human's
  reload picks the game up again. **A server start issues a new epoch,** so
  every open page stops on its next report (`reload epoch`: the server
  restarted), and nothing kept per epoch needs to survive a restart. **The breaker**
  (`reload differs`) counts requests: three in a row on one epoch answered
  `differ` (a repeated answer to a resend counts nothing new; each
  `differ` is logged as a finding, `req N differ at tick T`):
  something is wrong that rewinding won't fix. **The page and its wasm are
  served under the physics hash** (`/physics-5e0c91a2.wasm`; the page that
  names it is never cached), so a reload can't pick up stale code and meet
  `reload physics` again.
- **`stuck T`:** a genuine split in the shared code would otherwise answer
  `reload differs` every three round trips for ever. The server counts its `reload
  differs` with no kept tick between, across epochs; at the third, it
  marks the park stuck at the tick of the last `differ`, logs it as a
  finding, and answers every load `stuck T`. The page says the physics
  disagrees with itself at tick T, and doesn't tick. **Any server start
  clears the mark:** a fix, to the shared Zig or to the page, arrives by a
  deploy, which restarts the server, so that is the one place to clear
  it (simpler than hashing the page too); a split that remains is marked
  again within three round trips.
- **`taken over`:** a newer page load (another tab, a reload) holds the
  park now; this page stops. The server answers only the newest epoch.

**The server reads a report in order,** answering the first thing wrong:
the language version (`reload language`); the physics hash (`reload
physics`); the epoch (`taken over` for an older one this run issued,
`reload epoch` for one it didn't); the request number (above); `from`
(`reload from K` unless it is the last kept tick); then every other line. A
header it can't read at all gets `req ?` alone (above); R stays
unanswered.

**Every field is bounded as it is parsed,** before any arithmetic: ticks
from `from` + 1 to `from` + 32, and inputs at most at `from` + 33 (one
recorded while the page was frozen at the window takes the last tick + 1);
positions in the world; displacements at most 100 px on each axis and at
most 16 a tick; the tick's displacements within the cap (the
absolute x parts add up to at most 100 px, and the y parts); at most 16
of the human's inputs a tick (`view` and `held` never count); tiles in the world, and at most 64 in a `view`; critters
that exist; a `leash` naming a dog the page has (from a `tile` line, held
or not: the leash's region is held before its first tick anyway); at most one line
per critter the page has, a tick; hex that fits; and the canonical form (above).
A report that breaks a bound gets `differ T none` at the offending line
(for the cap, the `t` line), with the state and board: a trap on the
server would be a crash, not a refutation.

**An input whose precondition fails is refused the same way:** a `leash`
while a dog is leashed (its `release` must come first, at that tick), a
`release` naming a dog that isn't leashed, a `grab` with nothing leashed.
**A `letgo` with no drag on is a no-op** in the shared Zig, kept as an
input: after a bump the pointer is still down, and the page may well
record its going up. Nothing is wrong there.

**Loading the page.** The request is one line, `dogpark 1 physics H load
WxH`, with the viewport's size. It picks the game up (below),
clears the stored answer and the last answered request number. A load that gets no
answer within 5 s, or a 5xx, is retried on the same backoff as a report
(5, 10, 20, 40, then every 60 s), never given up. The answer, unless
it is a `reload physics` or `stuck T` (the page stops on either):

```
epoch E
kept K
state leash D|none drag on|ended E'|none view WxH c,r … held c,r …
input <line>
…
tile c,r dog N a cow M b …
…
```

- **What the server does first** (decision 16, as amended 2026-10-15):
  it takes the leash off, so the park sleeps, drops any inputs waiting,
  and snapshots that. The critters stay where they stand. After the
  player asked to start over (`POST /reset`), it puts the park back in
  its first layout instead. Tick numbers carry on: K is the last kept
  tick.
- **What it logs:** at K + 1, a `view` of the viewport's size and a
  `held`, both of the region's tiles; with nothing leashed after the
  reset, both empty. The `state` line is `leash none drag none` with that
  view and held set, and there are no `input` lines. The page's first
  `view` then brings in its display, with the cap's region-first order
 . (The answer's `input` lines and a leashed `state` stay in
  the language for a load that keeps the board; none does today.)
- **What the page does:** it lays out the `tile` lines, and the park
  sleeps until the human leashes a dog. Request numbers start again at 1.
- A second tab does the same and takes over; the first stops on its next
  report (`taken over`).
- **`req ?` to a load** means the page can't write its own load line: it
  stops with a message.

**Why it's cheap to check.** The server keeps the board at its last kept
tick and re-runs the report's ticks over the critters in the region's
tiles, comparing each line it produces with the report's.
`zig build physics-server-bench` times a 16-tick report through the
route.

**The log is the reports, as written.** The server appends each kept
report to the game's log file:
- **While dogs move:** a few KB a second.
- **While the board rests:** nothing.

A report answered with `differ` is logged as far as it was kept (its
ticks through T − 1), so the log holds every kept tick and nothing else.

Every few seconds the server also writes a **snapshot**: every critter's
position; the last kept tick K; the inputs kept for K + 1; who is
leashed, and whether a drag is on or since which tick it ended; and the
physics hash.

**A restart applies the log; it doesn't re-run it.** It loads the last
snapshot, then takes each kept report after it as written: its inputs set
the leash and the drag, its critter lines put critters where they ended,
and its `bump` and `release` lines end drags and leashes. Nothing is
re-run and nothing checked. A report torn by a crash mid-append is
dropped: nothing in it was answered, since an answer goes only after the
sync. Of the two ways to restart, this is the simpler:
- **It survives a physics change.** Steve tunes by deploying, so a log
  tail written under other physics is the usual restart, not an edge. The
  log records what happened, and applying it puts every critter where it
  was; re-running it would need the old physics, or would rewrite history.
- **It needs no per-epoch bookkeeping.** The restart issues a new epoch,
  so every open page stops on its next report, and the view, held tiles,
  tiles sent and last answer are all made again at the next load.

**The log is rotated and kept for an hour** (2026-10-15;
[the capacity study](https://github.com/showell/essay-repl-server/blob/master/notes/dog-park-capacity.md)): the snapshot and the log after it are all a
restart needs, and the logs before are a debugging record, bounded.
- **Rotation:** at a snapshot, a log past `rotate_bytes` (1 MiB) is
  closed. The snapshot names a new log, `log-<its start, ms>`, at its first
  byte, and the server switches to it only once that snapshot is written.
- **Retention:** a closed log goes once its successor began more than
  `keep_logs_ms` (an hour) ago. The oldest also go while a game's closed
  logs pass `most_log_bytes` (25 MB: 80 games, about 2 GB). Each server
  start prunes too, as a start begins a new log.
- **The log being written is never removed.** So a game is restored as
  it stood, and its last hour of play can be read back for a bug.

## Who may play (2026-10-15, the first deployment)

`src/play/players.zig` and `app.zig`:
- **80 accounts, first come, first served** (Steve, 2026-10-15; sized by
  [the capacity study](https://github.com/showell/essay-repl-server/blob/master/notes/dog-park-capacity.md)). The landing page (`GET /`)
  has one button, Begin Game, a form posting to `/begin`. A device with
  no account gets the next one, as a signed cookie naming its slot, and
  goes on to `/dogpark`. After 80, the park is full. The count is kept
  in the data dir (`players`), so a restart hands out no more. A bot that
  only GETs takes nothing.
- **A game per account,** started at its player's first load, kept under
  `<data>/game-<slot>/physics` with its own log and snapshots.
- **Up to 5 playing at once, for play only** (Steve: "I'm just trying to
  prevent contention from all the drags"; 5 for now, where the capacity
  study puts a 1 vCPU droplet at about 20).
  - A report with ticks in it needs a turn. Turns go to the first askers,
    and each lasts 20 s past its holder's last such report.
  - While all 5 are held, the answer is `503 busy N`, N the seconds till
    the soonest frees. The page
    shows "someone else is playing" on screen, asks again in N seconds
    with the same bytes, and counts it as no failure.
  - A load, and a report of only a view or a held (a pan), never wait. A
    second player gets their own game loaded at once, and can look
    around.
- **Each device remembers where it was looking** (localStorage), since a
  load picks the game up. A new game, or Start over, opens on the park's
  middle.
- **No account, no game:** a load or report without a verifying cookie
  is a 403, and the page stops and says to go to the start page.
- **The operator reads, never plays:** `/admin/script` (README, "Running
  a script") runs a signed Shale script in the background, reading the
  games' logs and snapshots between requests. It holds no turn and takes
  no account; a request waits at most one of its slices.
- **Start over** (the page's button) is `POST /reset`. The account's next
  load is the first layout, and the page reloads.
- **The cookie is Secure** (`__Host-dogpark`), for the HTTPS deployment.
  A plain-http development server on an address (like :9103) needs
  `DOGPARK_INSECURE_COOKIE=yes`. The start report says which.

## Decisions in force

1. **A bump ends the drag, never the leash** (2026-10-13).
2. **Unleashing puts the park to sleep** (2026-10-13).
3. **Subscriptions are not the physics** (decision 13, 2026-10-13): the
   display decides the tiles the page holds; the physics sees only the
   region's.
4. **The park is a torus** (decision 14).
5. **Pixel-ticks** (decision 15, "the change that made it fun").
6. **A load picks the game up, its leash off; starting over is the
   player's choice** (decision 16, amended 2026-10-15 for the first
   deployment: it was "every load starts the park afresh"), and **the page
   never reloads on its own** (decision 17): on any trouble it stops, its
   screen paused, and logs why.
7. **Distance is the larger axis** (decision 19).
8. **The walk** (decision 20), **only in a drag, reacting only to
   critters in motion** (decision 21), and **cows walk with the dogs**
   (decision 22, 2026-10-14): no scoot, no pushing, no jumps; every step
   is vetoed whole if it would overlap. Rank only breaks ties.
9. **A small world, seen whole** (2026-10-15, replacing decision 23's
   edge veto): 6 × 6 tiles, the park the middle 4 × 4, the physics seeing
   every critter, the page holding every tile; dogs and cows at 70%, the
   spacings with them. The goal: herd the 8 cows together.
10. **A cow heeds its nearest moving critter** (decision 24, 2026-10-14):
   a cow, it closes in; a dog, it flees.
11. **The nudge** (decision 25, 2026-10-14): a step blocked by kin
   carries them along, up to 8 critters.
12. **Trails without obstruction** (decisions 29 and 31, 2026-10-14;
   permanent, 2026-10-15): the herd poops every 700 px, its deepest dog, 30 px behind
   itself, and poop stays until eaten, an obstacle to dogs and cows;
   chickens leave the walk and take one turn a tick, foraging the
   nearest ripe poop within 500 px or walking home, at most half the
   leashed dog's net move and 8 px; every poop but the newest is ripe.
13. **The sidestep and the shove** (decision 30, 2026-10-14): what's in
   the way is gone around, not stopped at. A step vetoed by a poop or a
   chicken that can't be shoved is tried once more, sideways; a dog or
   cow shoves a chicken by the step plus as much sideways, all checked
   before anyone moves; the leashed dog slides 1 px, and bumps only when
   that fails. No setback.

The history behind each is in git.

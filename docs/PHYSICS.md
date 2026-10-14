# Dog Park's physics, and the report that carries it

**Status: built, and played by Steve** (2026-10-13). The board, the
tick, the wire and the server's re-run are `src/play/physics*.zig`, with
the first layout in `layout.zig`; the server speaks only `GET /`, the
page's scripts, `/physics-<hash>.wasm`, `POST /load` and `POST /report`,
and keeps its own board under `data/physics/`. The page runs the same Zig
as `physics.wasm` (`physics_page.zig`'s exports, in the physics hash,
named by `index.html`); `solo/engine.js` keeps the record and the protocol
(one report in flight, the spacing, byte-identical tries on the backoff,
every answer form, the rewind and replay, the subscription and its
`held`, the stops). **Tested:** 92 Zig tests (`physics_test.zig` 42,
`physics_server_test.zig` 26, `physics_judge_test.zig` 12,
`physics_wire_test.zig` 8, `layout.zig` 2, `physics_identity_test.zig` 2);
all but the server's and the identity test also run compiled to wasm32
(`zig build physics-wasm`, some skipped there); `zig build test`, `check`
and `slow` are the tiers (the README). Page side: `tools/test_engine.mjs`
against a scripted world, and `tools/test_page_physics.mjs` and
`tools/test_physics_server.mjs` against a scratch server. Of the tests to
write first, 1-4, 6, 7, 12, 13, 15, 18, 21-24 and 30 have page-side or
end-to-end tests; the rest are the core's and the server's. **Tuned by
playing** (2026-10-13): the numbers below are `physics.zig`'s, and the
worked example is regenerated from the code.

The client-driven design (the essay
[the client drives](http://143.244.172.148:9100/notes/the-client-drives.md)):
the page runs every tick, and the server re-runs, keeps and acks. The
page's physics is the game: Steve tunes it by playing, and may still
change a foundational assumption here. The server's side (re-running,
keeping, `differ`) is provisional code for debugging that firms up once
the picture does. The cold reviews are folded in below.

Steve's rules, which everything here follows:
- **No randomness.** A tick is a function of the board and the player's
  last action.
- **Lower number means more alpha.**
- **Each tick cascades:** the leashed dog, then the cows, then the other
  dogs from most alpha down.
- **Physics is local to the leashed dog:** nothing acts more than 800 px
  from it (the sphere). What the physics can see reaches 1500 px each way:
  the 3000 px region below, for a jump or a tick's walk.
- **Four breeds,** the dogs with legs.
- **Positions in 256ths of a pixel; 16 ticks a second.**
- **No two critters should share space** (below). Overlaps may still
  slip through, so the page handles one gracefully rather than relying on
  never seeing one.
- **A herd may jam.** Jammed dogs stay jammed while awake; the player
  frees them by leashing an outer dog, and that's part of the game.
- **The leashed dog never flies over anyone.** Unlike a card in Lyn Rummy,
  it can't be carried over a herd: at the first bump during a drag it
  stops and the **drag** ends (the pointer is let go). The **leash** stays
  on: ending a drag and unleashing are different things.
- **The drag may be held to stricter rules** whenever that keeps the
  physics simple: it can stop short of trouble before any critter is
  touched.

## The short version

- **Each tick is a pure function:** the board before, plus what the human
  did during the tick, gives the board after. No randomness, no wall
  clock: drags are displacements, and critters react to them at once,
  whatever their speed. Wall time paces the page and is recorded, never
  computed with.
- **A dog's wishes look only up the cascade:** at the leashed dog, the
  cows and more-alpha dogs, never at dogs further down. A beta never
  pushes an alpha; the board has a direction, and is meant to settle.
  How well it settles is for play to show, not for a proof.
- **A dog wants three things, each with a comfortable band:**
  - to keep its distance from dogs of other breeds above it;
  - to keep near, but not on top of, the nearest more-alpha dog of its
    own breed;
  - to keep clear of the leashed dog and the cows.

  It moves only while something is outside its band. Once all three are
  satisfied, it rests.
- **7.5 px a second on its own,** with positions kept in 256ths of a
  pixel so a slow dog really is slow: 120/256 of a pixel a tick. **And
  pixel-ticks** (decision 15): during a drag, for each pixel the leashed
  dog moves, every awake dog takes a step of at most that pixel, so the
  pack keeps pace with the human.
- **Awake means close and watched.** A critter takes part only if it
  stands in a tile meeting the region around the leashed dog (tiles the
  page always holds before it ticks) *and* it is within 800 px of the
  leashed dog.
  Unleashing puts the whole park to sleep. When a tick moves nothing, the
  human does nothing and no let-go timer is running, the page stops
  ticking and sends nothing until the human acts again (a drag, a grab, a
  let-go, a leash; a `view` or `held` doesn't wake it).
- **The report is text,** one line per tick with the human's input, then
  every critter that moved, before and after, in rank order (the leashed
  dog, cows by number, dogs by number): a proof the server checks line by
  line. Each report carries a request number, and every answer echoes it:
  `kept`, `differ` (naming the first line it disagrees with), `reload`,
  `taken over` or `stuck`.
- **No two critters should share space.** The leashed dog stops at a
  bump and the drag ends; a dog's own step stops where it would press
  into someone; only a cow lands on anyone, and whatever it lands on
  jumps clear, or the cow stops short.

## The cascade, and why it settles

**The drag is a displacement,** in 256ths: how far the pointer moved, added
to where the leashed dog actually is. A dog leashed at d41.35 stays there
when picked up.

**Contact means pressing in.** Squares that touch aren't a collision; a
move is blocked only by the part of it that goes *into* a face it
touches. Sliding along a neighbour, or moving away from one, is free. So
a jammed dog, leashed, can be dragged out of its jam, and a dog resting
against another can still step along it or away.

**A drag is played in pixel-ticks:** each displacement as its x part then
its y part (a street, then an avenue), in internal steps of at most 1 px
(`step_most`). An axis part d is cut into n = ceil(|d| / 1 px) steps:
step i ends at d·i/n, truncated toward zero, in 256ths: 2.5 px is 640,
cut 213, 213, 214. In each step:
1. **the cows react,** by the grid rule (`scoot`), to the step (on the
   torus there is no edge to shape it, decision 14);
2. **then the leashed dog takes it,** swept against where everyone now is,
   stopping **just short** of pressing into anyone (one axis at a time, so
   contact is an exact integer: no rounding);
3. **then every awake dog, by number, takes a wish step** of at most the
   length the leashed dog actually moved in this step (none if it moved
   nothing): the pixel-tick (decision 15).

So a cow in the lane gets its chance to scoot before the dog arrives, and
the dog only bumps what didn't get out of the way.

**A bump ends the drag, not the leash.** When the leashed dog presses
into a critter, the drag ends at that step:
- **the pointer's capture is let go,** so the dog stops following it (a
  shake or some such in the page comes later);
- **the rest of the tick's drag is dropped;** what already happened in
  it stands (the cows reacted to the steps taken);
- **the leash stays on,** exactly as when the human lets go of the dog:
  the park stays awake, and the let-go timer starts (below);
- **the dogs still take their step** at the end of the tick, as in any
  tick.

Across the world's edge the dog goes on: it leaves one side and enters
the opposite one (the torus, decision 14), and so does everyone.

Within a tick, in this order:

1. **For each step of the drag,** as above: the cows react, the leashed
   dog moves, then every awake dog takes a wish step of at most that
   move. Physics never moves the leashed dog otherwise. Cows ignore the
   other dogs, and push them (below).
2. **Then, once per tick, every awake dog, by number, smallest first,**
   takes its own step at the speed (7.5 px a second). Each wish step sees
   the positions of everything above it *as already moved*: the leashed
   dog's new place, the cows' new places, and the more-alpha dogs' new
   places.

So the cows and the dogs both react to every pixel of a drag, and the
dogs creep on at the speed once a tick, drag or not. A critter's report
line is its net move over the tick, however many steps it took.

**What a pixel-tick lets a dog cover.** A tick's drag is capped at 100 px
on each axis, so the leashed dog moves at most 200 px of path (100 along
x, then 100 along y): its Manhattan length. A follower gets one wish step
per pixel of that path, each at most a pixel *long* (Euclidean), so it
can cover up to 200 px, plus the speed's 120/256. On a diagonal drag of
(100, 100) the leashed dog ends 141 px from where it began, and a
follower walking straight at it covers 200: about 1.4 times. That is
deliberate (decision 15): the budget is the human's effort, not the
leashed dog's displacement.

Looking only up the cascade also gives followers for free, as Steve
wanted. A beta's anchor is
always someone more alpha, so a herd forms as a chain or tree hanging off
its most-alpha member. When the player pushes the alpha around, the herd trails
after it, step for step while the player drags, and at 7.5 px a second
after.

## What a dog wants

For one awake dog, call it D, each tick. Only **awake** critters are
anchors, strangers or room-makers; a sleeper the physics sees is just an
obstacle, and a critter outside the **region's tiles** isn't there at all
(below), so the page never needs critters beyond them.

**The leashed dog counts as the most alpha dog of all** (Steve,
2026-10-13): it is above every dog in the cascade, so for these rules it
is more alpha than any of them, whatever its number. **Only its own breed
follows it:** those dogs can anchor on it, so their herd follows the
player. Dogs of other breeds never follow it; they keep their wary
distance and gather in herds of their own breed.

**1. Room from other breeds above it.** For each dog of another breed
above D (the leashed dog included), within the *wary* distance, D wants to be farther away. Its wish
is a step straight away from that dog, as long as the shortfall. These
add up, so a dog squeezed between two strangers is pushed out sideways.

**2. Its place in the herd.** D's *anchor* is the nearest dog of its own
breed that is more alpha (the leashed dog included, if it is of D's
breed), within the *follow* distance; between two equally near, the
higher-ranked: the leashed dog first, then the lower number. If D has no
anchor, it is the herd's head and only keeps its room. Against the anchor:
- **Too far** (beyond the band's outer edge): D wants to step toward it,
  as long as the excess over the edge.
- **Too close** (inside the inner edge): D wants to step away, as long as
  the shortfall. This is
  "near but not on top".
- **In the band:** content.

**3. Room from the cows.** The same as 1, with its own distance. (The
leashed dog needs no rule of its own: other breeds keep their wary
distance from it, and its own breed its herd band.)

**Distances** are Euclidean, centre to centre, compared squared (no root
needed to compare). **"Within N px" means at most N px,** everywhere in
this doc. **When two
centres coincide** (an overlap slipped through), "away" has no direction:
take east.

**The wish arithmetic, in this order.** Each wish, per axis, is the axis
of the centre-to-centre vector times the wish's length, divided by the
distance (`isqrt`, rounded down), the product in `i64` and the quotient
truncated toward zero. The wishes are summed per axis. The step is then
the total if its squared length is at most the speed squared (exact, no
root), else each axis of the total times the speed, divided by the total's
length (`isqrt` of its squared length), truncated toward zero. **Every
comparison of a length with a number is made squared,** the dead zone's
too; `isqrt` appears as a divisor, and as a length in one place: a
wish's length against an edge is `isqrt(d²) − edge` (the excess over a
band's outer edge, or the shortfall inside a distance). The step's limit
is the speed for the once-a-tick step and the leashed dog's move for a
pixel-tick's (`stepAtMost`). With today's numbers every limit is at most
1 px, the dead zone's length, so the first branch runs only for a total
exactly 1 px long against a full 1 px pixel-tick; any shorter total
stays put.

**Cows push dogs.** A cow is bigger than an unleashed dog and isn't afraid
of it; it respects only the leashed dog, which has a human guiding it.
So the cows move first and ignore the other dogs, and a cow step may land
a cow on top of one. That dog gets out from under it at once, during the
cow's step:
- **the step:** to the nearest spot clear of everyone (below);
- **not the usual speed:** it isn't limited to a wish step;
- **then, at its turn, the usual wishes,** including room for the cows.

It's a little jump, and that's fine (Steve's call).

**The step.**
1. Add up the wishes.
2. If the total's squared length is less than the **dead zone**'s squared
   (1 px to start), D stays put this tick: close enough.
3. Otherwise D moves along the total, by the total's length or the
   step's limit (the speed, or a pixel-tick's move), whichever is less, and **stops where it would press into any
   critter the physics sees** (above or below it, awake or asleep): a dog's own step
   never lands it on anyone. Only the cows ever push. Across the world's
   edge it goes on round (decision 14).

The dead zone is there because opposing wishes (an anchor on one side, a
stranger on the other) can overshoot each other: without it, a dog at
the balance point flips 1/256 of a pixel each way, every tick, for ever.
How it feels is for play to decide; stepping half the total is the other
cure.

**Resting.** A tick **rests** when nothing moved in it, the human gave no
input but a `view` or `held`, and no let-go timer is running: then the next tick, a pure
function of the same board and no input, would move nothing either. It's
a fixed point, so the page stops ticking altogether: no reports, no work
for the server, until the human acts again. A jammed herd rests too,
wishes and all; leashing an outer dog wakes it. **What ends a rest:** a
`drag`, `grab`, `letgo` or `leash` (a rest can come with the pointer held
still on the leashed dog, so a let-go can arrive mid-rest, and starts the
timer). A `view` or `held` never does: the region's tiles are always held,
so no change of tiles changes the physics. The page ticks again from that
input's tick (last tick + 1).

**Breeds.** Four, the dogs with legs: 🐕 🐩 🦮 🐕‍🦺. Dog n has look n
mod 4 (`breeds`), and the page draws dog n with look n mod 4. **The first
layout** (`layout.zig`) puts four dogs in every tile of the 10 × 10 park,
one of each breed, each 75 px in from its own corner of the tile (breed 0
north-west, 1 north-east, 2 south-west, 3 south-east), numbered 4k to
4k + 3 tile by tile, row by row: 400 dogs. A cow stands in the middle of
each white tile (column plus row even): 50 cows. So two neighbouring
tiles' facing dogs are 150 px apart and of different breeds, inside the
wary distance: the park is restless from the first drag.

**The numbers,** as tuned by playing (2026-10-13; `physics.zig`):

| | |
|---|---|
Each is a constant in Steve's units: `ticks_per_second`, `perTick` (a
rate a second as 256ths a tick; one that doesn't divide doesn't compile),
`seconds` and `px`.

| knob | `physics.zig` | value |
|---|---|---|
| tick | `ticks_per_second = 16` | 16 a second (62.5 ms; engine.js reads it from the wasm) |
| speed | `perTick(px(15) / 2)` | 7.5 px a second: 120/256 of a pixel a tick |
| pixel-tick | `step_most = px(1)` | a drag's internal step, at most 1 px; after each, every awake dog's step of at most that move (decision 15) |
| dead zone | `px(1)` | 1 px |
| awake (the sphere) | `awake_reach = px(800)` | within 800 px of the leashed dog, centre to centre, at the tick's start |
| wary of another breed | `wary = px(225)` | 225 px centre to centre |
| follow: an anchor within | `follow = px(600)` | 600 px |
| herd band, to the anchor | `band_inner`, `band_outer` | 60 to 100 px, centre to centre |
| room for a cow | `cow_room = px(90)` | 90 px |
| the cows' scare box | `scare_box = px(280)` | 280 px ahead and 280 px off the dog's line |
| a cow's lane | `lane` | 70 px: half a dog, half a cow and a 20 px clearance |
| the region | `region_reach = px(1500)` | 1500 px each way: the 3000 px square, at most 7 × 7 = 49 tiles |
| a tick's drag | `cap = px(100)` | at most 100 px on each axis |
| the leash off | `let_go_ticks = seconds(20)` | 20 s (320 ticks) after the drag ends |
| a jump's reach | `jump_reach = px(100)` | 100 px |
| the squares | `dog_px`, `cow_px` | dogs 40 px, cows 60 px |
| the first layout | `layout.zig` | 400 dogs, four to a tile, one breed per corner; 50 cows |

**What a retune must keep.** These relations between the knobs are
checked; the first three refuse to compile.
- **The region outreaches the rules:** `region_reach` at least
  `region_needs`, the longest of the three chains in "The region's size,
  derived".
- **A cow's room is more than touching:** `cow_room > dog_half +
  cow_half`. Otherwise a cow lets a dog overlap it before it moves off.
- **The wishes' grid fits:** `wary <= follow`, and `follow / wish_cell`
  small enough that the anchor's rings fit the grid's 16 cells. Its cell
  follows `wary`: the smallest at least `wary` that divides the world
  into a multiple of 16 cells a side (250 px played, 400 px alt; decision
  14), and a cell that can't be found doesn't compile.
- **The scare box spans two lanes:** `scare_box >= 2 * lane`. Otherwise
  a cow on the dog's line can't get out of its way in time. The lane
  test states this as its precondition.

`zig build -Dknobs=alt` moves every tuned knob by about half, within these
relations; `zig build slow` runs the physics' tests under it, so a test
that pins a played value instead of a property fails there. The worked
example's tests are the played knobs' and skip under alt.

**Arithmetic.** Every critter's position is an integer count of 256ths of
a pixel, the cows' too, with an integer square root for distances. **Every product is `i64`:** squared distances
(in 256ths, about 7·10^13 along one axis of the 64 × 64 world and
1.3·10^14 on its diagonal, well inside `i64`; about 10^12 within a
region), a wish's direction times its length
(about 8·10^9 at the extremes), and a total scaled to the speed. Only a
quotient comes back to `i32`, and every `i32` holds a position, a
displacement or a distance in the world. Page and server agree to the
bit only through the same compiled code.
- **The whole pixel** is the position shifted right by 8.
- **On the wire,** a position is hex with a point: `d80.40` is 3456 and
  64/256, or 3456.25 px. Exact, and truncated by dropping what follows the
  point.
- **One canonical form,** written by the shared Zig (the page's
  JavaScript never formats a number on the wire): lower case; the whole
  pixels with no leading zeros (`0` for none), a point, then exactly two
  hex digits. A displacement adds a sign, `+1.00` or `-2.80`, and is
  written `0` when it is zero. The physics hash is eight hex digits. The
  parse rejects every other spelling (`differ` at that line), and the
  server compares lines by their parsed integers, never as text.
- **Where a person reads it,** in the page's debugging overlay or a log
  meant for people, it is shown in decimal pixels.
- **Which fields are hex:** positions and displacements (with a point;
  displacements also with a sign) and the physics hash. Everything else
  is decimal: ticks, `+ms` and `@ms`, `wall`, the epoch, critter numbers,
  tiles' `c,r` and the viewport's `WxH`.

## No two critters should share space

**The rule we aim for.** At the end of every tick, no two critters'
squares overlap: dogs 40 px, cows 60 px, centred on their points, awake or
asleep, the leashed dog included. Touching is allowed; overlapping by
1/256 of a pixel is not. In 256ths, squares of sides a and b centred at
p and q overlap exactly when |px − qx| < (a + b)/2 and
|py − qy| < (a + b)/2.

**Edges.** A critter's *point* stands in exactly one tile, half-open as in
`tiles.zig` (a tile holds 0 ≤ x − its left < 500 px). A *square* is
wholly in a tile, the region or the world when it lies within the closed
rectangle: touching a border is inside. **A square or a viewport *meets* a
tile half-open:** when they share some of its interior, so one whose edge
lies on a tile border doesn't meet the tile beyond. So the region's
3000 px span meets at most 7 tiles on an axis.

**What the physics sees.** Every obstacle, reach and overlap check, on
both sides, looks only at the critters **whose point stands in a tile
meeting the region**: the 3000 px square around the leashed dog at the
tick's start (derived below). The page holds every such tile before it
runs the tick (item 14), so it has every such critter; the server knows
every critter in the park and treats the rest as absent, exactly as the
page must. A critter beyond is drawn but not seen, so the tiles the page
subscribes for its display never change a tick. A sleeper just outside
can poke its square up to 30 px into the region past a tile border; an
overlap with it, if one happens, is a finding (below), not a `differ`.
- **The page keeps every critter it received this epoch,** where it last
  had it. When a `view` subscribes again a tile whose critters it already
  received this epoch, the page writes that tile in a `held` line at the
  same tick (no ack to wait for). That is where they are on the server
  too: a critter the physics doesn't see doesn't move. The server never
  resends a tile once a kept `held` has named it this epoch.
- **A `tile` line is applied to the page's board at the last kept tick,**
  and only to critters it hasn't received this epoch. A tile can come twice
  (sent, then a `differ` before its `held` was kept), and the second copy
  never moves a critter the page is already running.
- **A page load resets it:** the page has exactly the critters of the
  load's `tile` lines.

**Where an overlap could come from,** before any rule:
- **The human** drags the leashed dog onto a sleeping dog, a herd, a cow
  pinned against the wall.
- **Cows ignore each other**: the grid rule can step one cow onto another.
- **Cows ignore unleashed dogs,** by design, so a cow lands on a dog.
- **An alpha ignores betas,** by design.
- **A critter getting out from under something** can jump onto a third.
- **A board that breaks the invariant** before the first tick: the
  first layout has no overlaps, but nothing but the start's resolve
  (below) checks that.

**Rank** is the cascade's order: the leashed dog, then cows by number,
then dogs by number. Sleepers never move (and on the torus there is no
edge to press against, decision 14).

**The rules, one per kind of mover:**
- **The leashed dog** stops just short of pressing into any critter it sees, swept
  along each step of the drag, and the drag ends (above). It never
  overlaps anyone.
- **A dog's own step** (its wishes) stops where it would press into any
  critter the physics sees, above or below it, awake or asleep. The step
  is **one straight move** (decision 18): kept in the world per axis;
  then each axis that would press deeper into a square it already
  overlaps is dropped (from Δ = 0 either way is free); then it goes to
  its earliest contact along the segment, the moment a fraction n/d of
  the step (d the step's length on the face's axis), each axis cut to
  `trunc(step × n / d)`: the gap exactly on the face's axis, and never
  past the segment on the other, so the dog is clear of everyone the
  segment is. If it met one face only (x or y), the rest of the other
  axis slides along it, swept on that axis alone; if it met a corner
  exactly, or two squares at once on different faces, it stops there.
- **A cow's grid step** is swept too, per internal step: it stops just
  short of the leashed dog, any sleeper it sees (sleeping dogs aren't
  pushed) and any cow above it; if it already overlaps one of those, that
  axis of its step is held to the never-deepen rule below. A cow it lands
  on below it is pushed like a dog.
- **The cows go by number,** each taking its grid step and then its
  pushes before the next cow moves.
- **A cow's pushes are decided as one set,** against the cow's square at
  the end of its step. The critters under it are placed **in rank
  order**, each at its nearest spot clear of everyone, outside the area
  the cow swept, and clear of the new spots of those already placed. The
  old squares of the critters being pushed don't count as obstacles: they
  are all leaving. A dog the cow's sweep crossed but that isn't under its
  end square isn't pushed (cows ignore dogs; only where a cow ends
  counts). If every one of them finds such a spot, they all jump
  there, at once. If any has none, the cow stops just short of the first
  critter **along its sweep** (any critter the sweep meets, a dog it only
crosses included, so the cow never ends on one; ties by rank), and
**pushes no one**; if it
  already overlaps that critter, it stays where it is on that axis. So no
  critter moves for a push that didn't happen, and no two pushed critters
  land together.

**What this aims at:** only a cow can make an overlap, and each is
undone on the spot, by the jumps or by the cow stopping short. If an
overlap slips through anyway (a case nobody thought of), the page doesn't
fall over:
- **it draws the critters as they are;**
- **the lower-ranked one gets out from under** by the same jump, **if it
  is awake**: a dog at the start of its own step (the jump comes first,
  the wish step after); a cow at its own turn in its next drag step,
  before its grid step. There is no pushing cow and no sweep, so its
  obstacles are every other critter the physics sees, and the candidates
  come from those within reach. **With nowhere to go it stays,** and the
  never-deepen rule below holds it. If the lower-ranked one is asleep,
  nobody jumps until it wakes;
- **an overlap never deepens:** against a critter it already overlaps and
  may not push, a mover's step on each axis may not shrink the gap
  between the two centres on that axis (|Δ|), nor carry its centre past
  the other's (Δ changing sign). From Δ = 0 a step may go either way: that
  grows |Δ|, and no sign changes. That part of the step is dropped (for the
  leashed dog, it is a bump), and moving apart or along is free. A cow
  overlapping a critter it may push (a lower cow, an awake dog) doesn't
  use this rule: its step goes ahead and the push rule above places the
  critter. A cow whose step is zero pushes no one; its overlap is this
  graceful case;
- **the server notes it** in the log as a finding. It does not refute the
  report: the page and the server agreed, and the bug is in the rule,
  which play will show us.

**The nearest spot clear of everyone, deterministically.** It is the
closest position, by straight-line distance, that overlaps no critter and
stays in the world, chosen from a finite list of candidates:
- **The squares that make candidates,** exactly: every obstacle within
  reach (its square comes within 100 px of the pushed critter's on both
  axes: the gap between the squares, axis by axis, is at most 100 px).
  The obstacles are the pushing cow's square at the end of its step, the
  area the cow swept in that internal step (a rectangle), the new squares
  of critters already placed in this push, and every other critter the
  physics sees, as it stands. The old squares of the critters being pushed, the pushed
  critter's own included, make none: they are all leaving.
- **The ways out:** the pushed critter pressed against each side of each
  such square, so a spot just past a third square is found. A way out
  moves one coordinate and keeps the pushed critter's other.
- **The corners** where two ways out meet, from one square or two: the x
  of one, the y of the other.
- **Only spots whose square lies wholly in the region.** The region is
  sized so that ordinary play never meets this limit (below); it is a
  guard. On the torus a spot may lie across the world's edge (decision
  14): every square here is taken as its copy nearest the leashed dog,
  and the spot is wrapped back into the world when the critter jumps.

**Neighbours are always taken in rank order,** whatever order they arrived
in (the page's tiles fill in arrival order; the server's don't). Every
candidate is checked against **every critter the physics sees whose
square overlaps it** (found through the tiles around the candidate, not the pushed
critter's reach: a spot pressed against a neighbour's far side can
overlap a critter the reach never saw), and the nearest valid one
wins. A jump can therefore go as far as the pushed
critter's side, plus the 100 px gap, plus the neighbour's side: about
200 px for a dog pressed past a cow, 220 px for a cow. **Ties** are broken
by the rank of the square that made the candidate (for a corner, the
higher-ranked of its two, then the other's; a way out counts its own
square's rank twice, so it comes before a corner made with that same square
and a lower-ranked one; the swept area ranks with its
cow, just after the cow's own square), then by direction in a fixed
order: east, south, west, north, then the corners NE, SE, SW, NW (a
corner's direction is its x side, then its y side: x from an east side
and y from a north side is NE). Two corners still tied (the same two
squares, each giving the x once) go to the one whose x comes from the
higher-ranked square. The search
stays within that reach, so it is local and cheap; finding none is
"nowhere to go".

**The server checks the invariant on its own,** after every tick, among
the critters the physics sees, and logs any
overlap with the tick and the pair: a finding, not a refutation (above).
That catches a bug in the rule itself, which a re-run of the same code
would repeat faithfully.

**The park on start, and on load.** **Every page load starts the park
afresh** (decision 16): the server puts back the first layout
(`Board.laidOut()`, from `layout.zig`), nothing leashed and no inputs
waiting, and snapshots it before the load's own log entry. The load
resolves nothing: the first layout overlaps no one. The server resolves
a board **once, when it starts on one that has never been resolved**:
the first layout, with no snapshot behind it (a `dogs.json` or
`cows.json` an older server left in the data dir is ignored, and the
start report says so). A board from a snapshot or the log was resolved
already and is never resolved again; an overlap a live page holds is
handled by the graceful rule above. The leashed dog, if any, stays where
it is: nothing outranks it, and on the torus nothing sticks out of the
world (decision 14). Then in rank order (the leashed dog, cows, then
dogs, by number), each critter that overlaps one above it jumps to the
nearest spot clear of everyone, every critter seen and every tile held,
taken around the critter itself (every square as its copy nearest it),
the spot wrapped into the world. It
logs what moved, as the log's first entry, and keeps the result (the
first snapshot). If some critter has nowhere to go, the server does not
start, and says which (fail, never warn).

**Cost.** Each check looks only at critters within about 100 px of the
pushed critter or of a candidate, found through the tiles; a handful per critter per tick.

## Wall time

**The physics has no clock.** A tick is a step, not a duration. The page
runs 16 a second by its own clock (`requestAnimationFrame`), and that's
the only place wall time paces anything. A slow laptop ticks slowly and
the physics is unchanged; a page in a background tab doesn't tick at
all, and catches up nothing.

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
`scene.js`). **A critter the tick names as jumped** (`Lines.jumped`: out
from under, or a push's nearest spot; the wasm's `jumpedAt`) **snaps** to
where it lands, since sliding would draw it through whatever lies
between. Every other move glides, however far a fast drag carried it.
`Lines.jumped` is drawing data only: it is not on the wire.

## What "awake" means

Both, as Steve decided: a critter is awake if the page has it *and* it is
within **800 px of the leashed dog**, at the tick's start (the **sphere of
influence**, `awake_reach`). Exactly: its point stands in a tile meeting
the region (a tile the page always holds before it ticks), and it is
within 800 px.

**The tiles are not the sphere** (decision 13). The checkerboard is how
the page learns about critters; the sphere is what the physics acts on.
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
- **The region** is the 3000 px square centred on the leashed dog at the
  tick's start (after that tick's `leash`, if any): 1500 px each way,
  derived in the next section. It meets at most 49 tiles.
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
recorded tick + 1, as a `leash` does (item 8); several at one tick apply
in the order written. **At most 16 of the human's inputs a tick**
(`leash`, `grab`, `letgo`, `release`), across reports; the page drops a
17th (freezing makes many at one tick easy) and logs it. Several at one
tick apply in the order recorded, so `grab`, `letgo`, `grab` at one tick
leaves a drag on, with the first drag's displacements played before the
`letgo` (item 7). `view` and `held` never count, however long the human
pans: at one tick, **the page coalesces them** to one `view` (the union
of every view written for that tick, so a coalesced view never drops a
tile one of them added, a replay's included) and one `held` naming only
tiles in that view, so a long pan can't grow a
report. During a replay held back at the byte
budget (item 10), "the last recorded tick" is the last tick the page has
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

## The region's size, derived

The region must hold (1) every critter a tick can affect, with everything
its square could press into, and (2) every spot a push can land a critter
on, square and all, with the critters that spot could overlap. Per axis
(the square metric, from the leashed dog's point at the tick's start),
from the rules' own reaches. Two chains bound it.

**A walking dog** (pixel-ticks make this the long one):

| reach | px |
|---|---|
| an awake dog's point: within the sphere, 800 px centre to centre, so on each axis too | 800 |
| its wish steps over the tick: one per pixel-tick, each at most that pixel long, so at most the leashed dog's Manhattan move (100 + 100 under the cap), plus one step at the speed (120/256) | 200.5 |
| its square: half a dog | 20 |
| a critter its square could press into stands within half a cow of it | 30 |
| **total** | **1050.5** |

**A cow's push:**

| reach | px |
|---|---|
| a scared cow's point, at the end of its step (below) | 380.5 |
| what it lands on lies under it: half a cow and half a cow | 60 |
| the landed-on critter's jump: pressed past a square within the 100 px reach, at most 100 + 60 + 60 (a cow) | 220 |
| the landing square must lie inside: half a cow | 30 |
| a critter that could overlap that square stands within half a cow of it | 30 |
| **total** | **720.5** |

A dog pushed this way and then walking the rest of the drag stays inside
the first chain: 380.5 + 50 + 200 (a dog's jump past a cow) + 200.5 + 20
+ 30 = 881.

**Why a scared cow ends within 380.5 px.** A cow's step is *not* bounded
by the dog's: a cow in the 70 px lane clears it in one internal step,
whatever that step's size (`scoot`: `needed = out` once the cow is
within a lane's width ahead), so a 1 px step can move a cow 70 px. What bounds it is
the scare box: a cow moves only while at most 280 px ahead of the dog
after the step and at most 280 px off its line, and only away from the
line: by half the dog's step (half a pixel) or out of the lane (to 70 px
off). So it ends at most 280.5 px off the dog's line and 280 px ahead of
the dog, and the dog is within 100 px of its start on each axis: 380.5. (On the torus
a cow is never short of room, so it always clears the lane on its own
side, decision 14.)

**The verdict: 1500 px each way is enough,** the 3000 px square (three
tiles each side of the leashed dog, at most 7 × 7 = 49 tiles). The
longest reach is 1050.5 px, so **449.5 px to spare**; one tile less
(1000) would not do. A jump's landing square reaches at most 690.5 px, so
the "wholly in the region" check on a jump is a guard ordinary play never
trips: a chain of jumps from an overlap that slipped through is what it
exists for. The leashed dog's own sweep (100 px plus half-squares) is far
inside. The number is used everywhere below: the freeze until the region
is held, the cap's region-first order (item 11) and the load. **Tune any
reach above and this is redone:** the sphere, the cap and the pixel-tick
bound together grow the first chain one for one.

## The report

One report per round trip, as moves are sent today: everything since the
last tick the server kept. For now it says a lot. It names every critter
that moved, where it was and where it went, **in rank order** (the
leashed dog, then cows by number, then dogs by number: a dog a cow pushed
is listed among the dogs, its one net line), so the report is the
calculation written out and the server checks it line by line. (The
physics hash `5e0c91a2` in the examples is a placeholder; the real one is
`physics_wire.physics_hash`, a compile-time CRC-32 of the physics' sources.)

```
dogpark 1 physics 5e0c91a2 page 1791935990000.3 req 4
from 1040 wall 1791936000000
held 1041 30,32 31,32 32,32 33,32 34,32 35,32 36,32 30,33 31,33 32,33 33,33 34,33 35,33 36,33 30,34 31,34 32,34 33,34 34,34 35,34 36,34 30,35 31,35 36,35 30,36 31,36 36,36 30,37 31,37 32,37 33,37 34,37 35,37 36,37 30,38 31,38 32,38 33,38 34,38 35,38 36,38
t 1041 +0 drag -1.00,0@3 -2.00,0@19
 dog 219 423c.00,463c.00 > 4239.00,463c.00
 cow 43 416e.00,4556.00 > 416e.00,4554.80
 dog 223 42d2.00,463c.00 > 42ce.88,463c.00
letgo 1042
t 1042 +63
 dog 223 42ce.88,463c.00 > 42ce.10,463c.00
t 1043 +125
 dog 223 42ce.10,463c.00 > 42cd.98,463c.00
```

The numbers follow the rules, in the 64 × 64-tile world with today's park
moved to its middle (decision 14), at the numbers tuned by playing; the
report and both answers below are the code's own (the golden fixtures in
`physics_judge_test.zig`, regenerated from the page's run on a retune).
Before the leash, nothing was leashed and the page held its viewport's
tiles: 1280 × 800 at x 16316 to 17596 px and y 17700 to 18500 px, columns
32 to 35 and rows 35 and 36. Request 3 carried the leash and its view as
inputs with no tick: `leash 1041 219` and `view 1041 1280x800` with the
region's 49 tiles. The region is the 3000 px square around dog 219 (at
16956, 17980 px: x 15456 to 18456, y 16480 to 19480), columns 30 to 36
and rows 32 to 38, which contains the viewport's 8. The page can't run
1041 until it holds all 49, so it froze until request 3's answer, `kept
1040` with the 41 new tiles' critters; then it wrote the `held 1041`
above and ran the tick. The drag is 3 px west, so three pixel-ticks. Cow
43 (white tile 6,8 of the park, at 16750, 17750 px) is 308 px from dog
219, so awake; the drag west finds it about 206 px ahead and 230 px off
the dog's line, inside the 280 px scare box and out of the 70 px lane,
so it moves north half of each 1 px step, 128 in 256ths three times: 1.5
px (4556.00 to 4554.80). Cows 38, 47 and 48 are awake too (786, 755 and
399 px off) but unscared: 38 and 48 are behind a drag west, and 47 is 706
px ahead, past the box. No dog of another breed is within reach: this is
a played board, not the first layout, so every dog but 219 and 223 has
wandered beyond the sphere, while the cows stand where they were laid
out. Dog 223, of 219's breed (223 mod 4 = 3, as 219), stands 150 px east
of dog 219. Each pixel-tick moves 219 1 px west and then lets 223 step at
most that pixel: it is 151 px from its anchor, 51 past the band's outer
edge, so it steps 1 px west, three times; then its own step at the speed,
−120 in 256ths (`.78`). So 1041 moves it 3.47 px (42d2.00 to 42ce.88),
and 1042 and 1043, with no drag, the speed's 120 each, until it reaches
the band. So the board doesn't rest, and the let-go timer (320 ticks)
runs from 1042. Cow 43 moves only during a drag, so it has no line after
1041.

| line | says |
|---|---|
| `dogpark 1 physics H page E req R` | the language's version; the physics' version, a hash of the physics' sources built into both the wasm and the server, so a forgotten version change can't cause endless disagreement; this page load's epoch, which the server issued, unique across the server's runs (its start, Unix ms, a point, and a count: `1791935990000.3`); and the request number (below) |
| `from T wall W` | the tick the report starts after (the last one the server kept), and the wall clock (Unix ms) at its first tick, data only (no `wall` on a report with no ticks) |
| `leash T D` | the human leashed dog D at tick T: the park wakes around it |
| `grab T` | the pointer went down on the leashed dog at tick T: a drag is on, and any let-go timer stops (a `leash` implies it) |
| `letgo T` | the drag ended at tick T because the human let go: the let-go ticks (`let_go_ticks`, 320) start |
| `bump T dog N`, `bump T cow N` | the drag ended at tick T because the leashed dog pressed into that critter: the let-go ticks start, the leash stays |
| `release T D` | the leash came off dog D at tick T (the let-go ticks ran out, or another dog was grabbed): the park sleeps |
| `held T c,r …` | from the start of tick T, the page holds these tiles' critters (they arrived with an ack): an input, so the server counts exactly the tiles the page did. A tile list (here and in `view`, `state`) is a set: listed in any order, compared as a set |
| `view T WxH c,r …` | from the start of tick T, the viewport's size and the tiles the page subscribes: which tiles the server sends, and which stay held. Never an input to the physics. Written whenever the subscription changes: a leash, a release, a pan, a resize, the region reaching new tiles |
| `t T +ms` | tick T begins, `+ms` after `wall` (data only). `drag` and its displacements in 256ths, when the human dragged during it, each with `@ms` from the tick's start (data only); at most 16 a tick (the shared Zig adds up any more, item 2). A tick that bumps carries its whole recorded drag, merged and capped, the displacements after the bump included: the physics drops those, and the server finds the bump itself |
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
A `board` holds only the awake critters and the ones the report named,
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
  Reloading the page (a load, so the park afresh) is the human's act. A
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
well, and had the page written dog 223's step at 1042 as
`> 42ce.11,463c.00`:

```
req 4
kept 1043
```
```
req 4
kept 1041
differ 1042 dog 223 42ce.88,463c.00 > 42ce.10,463c.00
state leash 219 drag on view 1280x800 (the 49 tiles) held (the same 49)
board 1042 dog 219 4239.00,463c.00 cow 38 4362.00,4362.00 cow 43 416e.00,4554.80 cow 47 3f7a.00,474a.00 cow 48 4362.00,474a.00 dog 223 42ce.88,463c.00
```

In the second: ticks through 1041 are kept; the server's own line for
1042; at the start of 1042, before its inputs, dog 219 leashed with the
drag still on (the `letgo 1042` is an input of the unkept tick), the view
from 1041 and all 49 tiles held (written out in full on the wire); the
six awake critters, as tick 1041 left them: the three the report named,
and cows 38, 47 and 48, which didn't move. No `input` lines: no earlier request kept an input for 1042.
No `tile` lines: every subscribed tile is held.

| answer line | says |
|---|---|
| `req R` | first in every answer to a report: the report's request number. `req ?`, alone, when the server can't read the header; the page takes it as the answer to the exchange it came back on, and stops |
| `epoch E` | first in a load's answer (a load is not a report and has no `req`; the table's "first in every answer" is for answers to reports): the new epoch; request numbers start at 1 |
| `kept T` | the last kept tick, after this request. With no `differ` after it, the whole report is kept: its ticks through T, and any inputs it carried for T + 1 after its last `t` line (they wait for that tick; a later report may add more for T + 1 before its `t` line). A report with no ticks gets `kept` its own `from` |
| `differ T <line>` | the server's run has this line at tick T, and the report lacks it or writes it differently. The report is kept through T − 1 (the `kept` above), nothing of its own at T |
| `differ T none <line>` | the report has this line at tick T, and the server's run doesn't; also every **refused** line: malformed, out of bounds, an input whose precondition fails (below), or the `t` line of a tick whose region meets a tile not held. A malformed line belongs to the current tick if it looks like a critter, `bump` or `rest` line; anything else after a tick's checked lines, to the next tick |
| `state leash D\|none drag on\|ended E\|none view WxH c,r … held c,r …` | at the start of tick T (K + 1 for a load), before that tick's inputs: who is leashed; whether a drag is on, or the tick E it ended (the release is due at E + `let_go_ticks`), or none (unleashed); the view and the held tiles in effect, a `view` or `held` an earlier request kept for T included. The server writes tiles row, then column; a tile listed twice in one list is refused |
| `board T dog N a cow M b …` | with `differ`: the server's critters at the start of tick T, in rank order: every one it had awake at the start of T (around the `state` line's leashed dog), and every one the report named |
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
  reload starts the park afresh. **A server start issues a new epoch,** so
  every open page stops on its next report (`reload epoch`: the server
  restarted), and nothing kept per epoch needs to survive a restart. **The breaker**
  (`reload differs`) counts requests: three in a row on one epoch answered
  `differ` (a repeated answer to a resend counts nothing new):
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
most 16 a tick; the tick's displacements within the cap (item 3: the
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
WxH`, with the viewport's size. It starts the park afresh (above),
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

- **What the server does first** (decision 16): it puts the park back
  in its first layout, nothing leashed and no inputs waiting, and
  snapshots that. Tick numbers carry on: K is the last kept tick, and the
  board at K is the first layout.
- **What it logs:** at K + 1, a `view` of the viewport's size and a
  `held`, both of the region's tiles; with nothing leashed after the
  reset, both empty. The `state` line is `leash none drag none` with that
  view and held set, and there are no `input` lines. The page's first
  `view` then brings in its display, with the cap's region-first order
  (item 11). (The answer's `input` lines and a leashed `state` stay in
  the language for a load that keeps the board; none does today.)
- **What the page does:** it lays out the `tile` lines, and the park
  sleeps until the human leashes a dog. Request numbers start again at 1.
- A second tab does the same and takes over; the first stops on its next
  report (`taken over`).
- **`req ?` to a load** means the page can't write its own load line: it
  stops with a message.

**Why it's cheap to check.** The server keeps the board at its last kept
tick and re-runs the report's ticks: the cascade over the awake critters,
each looking only at critters in the region, comparing each line it
produces with the report's. With tens of awake dogs, a report's worth of
ticks is a small amount of arithmetic, a few milliseconds even on
metal's one core. The judge can hold that to a number.

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

If the log grows too big to keep, it is the first thing to trim: the
snapshots alone are enough to start from.

## For the first implementation (the page)

The third cold review listed the questions someone building the page's
physics first would hit, in order. The simplest answers, adopted until
play says otherwise:

1. **The cows' grid rule is in 256ths** (`scoot`): "half as far" is the
   step halved and truncated; the lane is 70 px centre to centre (17920:
   a dog's half, a cow's half and the 20 px clearance); a cow is scared
   while at most 280 px ahead of the dog after the step and at most 280 px
   off its line, and is awake only within the sphere. There are no edge
   rules: the torus (decision 14) took away `room()`, the shortened step
   and the lane's switch to the other side.
2. **The 100 px cap and merging past 16 displacements a tick happen in
   the shared Zig,** not in JavaScript: the page's run merges and caps,
   and the report carries the displacements as merged and capped. The
   server checks the bound as it parses (a tick over the cap gets `differ`
   at its `t` line, with the board) and its re-run plays what the report
   carries.
3. **The cap is per axis, on the tick's path:** the displacements are
   played in order, each axis with its own 100 px budget for the tick; a
   displacement that crosses a budget has that axis cut to what is left
   (the other axis untouched), and that axis plays no more this tick. The
   budget counts the input, not where the dog ended up after a clamp. It suits x-then-y and needs no square root. (Past 16,
   displacements are first added into the 16th, which keeps the last one's `@ms`.)
4. **A dog's own wish step is swept, stopping where it would press in,**
   as one move (decision 18), sliding along the one face it met. Its edge
   clamp and its sweep can go in either order: both only shorten the step.
5. **`grab T`** records the pointer going down on the leashed dog (a
   `leash T D` implies it): a held, still pointer keeps the let-go timer
   from starting, and a rewind's board needs to know a drag is on.
6. **Inputs and checked lines.** Inputs are taken as given: `leash`,
   `grab`, `letgo`, `view`, `held`, `drag`, and a `release` caused by
   grabbing another dog, which comes before the tick's `t` line. Checked
   lines are recomputed and compared: critter lines, `bump`, `rest`, and a
   `release` the timer caused, which comes after the critter lines. If a replay after
   `differ` loses a bump, the pointer was already let go: it stands as a
   `letgo` at that tick. **If a replay after `differ` gains a bump** (the
   server's run bumped where the page's didn't), that drag is over: the
   page drops its recorded `drag` and `letgo` inputs after the bump until
   its next `grab`, and lets go of the pointer. The server, for its part,
   ignores a `drag` with no drag on, and logs it as a finding. **A replay
   keeps every recorded input word for word,** `view` and `held` included,
   even when the dog's path changes, with one addition: **when a replayed
   tick's region meets a tile not held at that tick,** the page writes
   `view t` adding the tile at that tick, always, and sends it (a trailing
   input if need be), so the server sends the tile. Only the `held t`
   waits for the tile's critters: if the page already has them it writes
   `held t` at once; if not, the replay stops at t, and the later recorded
   inputs wait (frozen, as at the window) until the tile arrives, then the
   replay resumes.
7. **Order within a tick:** inputs before its `t` line, checked lines after
   the critter lines. A `letgo` takes effect after that tick's drag (the
   displacements recorded before the pointer went up still play). A
   `release` caused by grabbing another dog and the new `leash` share a
   tick: `release T D1`, then `leash T D2`. A `bump` that presses two
   critters at once names the higher-ranked. **Displacements on the wire**
   are hex like positions, with a sign: `+1.00`, `-2.80`, and `0` for none.
8. **Tick numbers after a sleep:** a `leash` takes the last tick + 1.
9. **The timer:** a drag ending at tick T releases at tick T +
   `let_go_ticks`, and the dogs still take their step in that tick. A
   `grab` at any tick up to and including that one stops it.
10. **When a report goes:** whenever none is in flight and there is
    something unsent (ticks, a `view` or a `held`), but no sooner than
    250 ms of wall time after the last one went (wall time, so a page that
    isn't ticking still sends), or at once when the unsent text reaches
    48 KiB. One in flight, never more. **At the 32-tick window, at
    48 KiB unsent, or with the next tick's region not all held,** the page
    freezes the physics (it keeps drawing) until
    the ack; the pointer's movement meanwhile adds up and is played,
    capped, at the next tick. A replay after `differ` stops at 48 KiB the
    same way, and the human's inputs meanwhile go after the last recorded
    tick. A `release` ends the ticking: no `rest` after it.
11. **Which tiles are subscribed** is the page's choice (decision 13):
    while a dog is leashed, every tile meeting the region (the 3000 px
    square, at most 7 × 7 = 49 tiles); and, leashed or not, the tiles its
    display can use, fetched as soon as a resize or a pan shows them. A
    W × H viewport meets at most (ceil(W/500) + 1) × (ceil(H/500) + 1)
    tiles: 5 × 4 = 20 for 1920 × 1080, 7 × 4 = 28 for 2560 × 1440,
    9 × 6 = 54 for 3840 × 2160. With the region partly off screen that is
    up to 79, so tiles.zig's cap goes from 25 to **64** (8 × 8; the world
    is 4,096). **Over the cap,** the page subscribes the region's tiles
    first, then the display's nearest the viewport's centre (by the square
    metric; ties by row, then column), so the physics never loses a tile
    to the drawing. A tile is held from the tick of the page's `held` line
    for it until a view drops it.
12. **A push's jump may not land outside the region:** a candidate whose
    square isn't wholly in it is invalid, so a held tile beyond the region
    never offers a spot. The region's size makes this a guard (above).
13. **"The area the cow swept"** is its sweep in that internal step, and
    "the first one it would have pressed into" is broken by rank. **Order
    within a drag:** the input is capped first (item 3), then split into
    internal steps (above); in each internal step the cows react to the
    step, and the dog takes it.
14. **No tick runs until its region is held** ("What awake means"): the
    page freezes, as at the window, until every tile in the world meeting
    the tick's region is held, and the server answers `differ` at a tick
    whose region isn't. This replaces any stall on the drag: the dog never
    moves where the page can't see.
15. **Determinism in the shared Zig:**
    - explicit `i32`/`i64` everywhere, and `u64` for tick numbers (`usize` is 32 bits in wasm and 64
      natively);
    - never iterate a hash map: sort awake critters by number, neighbours
      by rank;
    - both sides built ReleaseSafe, so an overflow traps the same way, and
      the parse bounds every field (above), so a report can't reach one;
    - the page replays the recorded integers, never raw pointer events.
16. **The world is 64 × 64 tiles** (32,000 px a side; Steve's call,
    decision 14): a torus, every critter wrapping across its edges, wider
    than the region plus its reaches so no critter is ever seen twice. **The world and the populated park are two sizes:**
    the 10 × 10-tile park (`tiles.zig`'s `park_tiles`) sits in the world's
    middle, `park_offset_px` (13,500 px) in from its edges on each axis,
    and the first layout (`layout.zig`) fills it: 400 dogs and 50 cows.
    The rest of the world is empty ground (Steve, 2026-10-13). Positions
    reach 8,192,000 in 256ths, squared distances about 1.3·10^14 on the
    diagonal: `i32` and `i64` as above. The tiles divide the world evenly.

**Still open after the first play** (for play to settle):
- **Ending the drag on any press-in** may drop the dog on pointer jitter
  or a clipped corner. Ending it only past a few px of press-in, or just
  clamping without ending, would be stricter-but-calmer drag rules.
- **The pointer drifts from the dog:** a bump, the 100 px cap and a
  freeze waiting for tiles all separate them, since drags are
  displacements.
- **A pushed dog jumps,** up to about 200 px in a tick; the page snaps it
  there (`Lines.jumped`) and glides every other move.
- **The park pauses right after a leash,** or on a drag toward ground the
  display hasn't loaded: no tick runs until the region's tiles arrive,
  usually one round trip.
- **A cow can push a dog into the player's path:** it lands clear of the
  cow's sweep but maybe in the lane ahead, and the next step bumps it.
- **After a bump, the mouse is still down** but the drag is over: the
  human must lift and press again to carry on.
- **Cows move only during drags.** A cow beside a leashed dog held still
  never yields, and the dogs keep their 90 px from it.

## Tests to write first

The ninth to twelfth reviews' lists, to be the implementation's first
tests. **Write these three first:** the worked example as a golden
fixture (26), subscribing more tiles changes nothing (12), and a lost
answer with a trailing `leash` (15). Between them they pin the cow port,
the cascade, the wish arithmetic, the wire format, `differ`, decision 13
and the request numbering.

1. **An unleashed pan:** a report with only a `view` gets its `tile`
   lines, and the page then writes `held`.
2. **A `differ` at `from` + 1** produces a rewind, not a reload.
3. **A lost answer:** after the 5 s timeout, the resend of the same
   request gets the server's stored answer, and the page is unfrozen and
   sending from the new kept tick within one round trip of the resend.
4. **A load after play** (Steve, 2026-10-13: every load starts the park
   afresh): the load gives back the first layout, nothing leashed and
   nothing waiting, and a restart after that load comes back to the same
   board.
5. **A restart under a new physics hash** with a log tail after the
   snapshot: the board is where the tail left it.
6. **A `letgo` at `from` + 33,** recorded while frozen at the 32-tick
   window.
7. **A replay that hits 48 KiB while the human acts:** the new inputs take
   the tick after the last recorded one.
8. **A cow lands on a dog with nothing valid around it** (a packed field
   about 220 px deep, or a wall: a single ring isn't enough, since a spot
   pressed against its outer side is within reach): the cow stops short of
   the first critter along its sweep and pushes no one.
9. **Coincident centres:** "away" goes east.
10. **The leashed dog overlapping an awake dog,** dragged toward it, along
    it, and from Δ = 0: a bump only when |Δ| shrinks or Δ changes sign. (A
    sleeper can't overlap the leashed dog: anything within 40 px of it is
    within 800 px, so awake.)
11. **A wasm-against-native fuzz** of the wish arithmetic at the `i64`
    extremes.
12. **Subscribing more tiles changes nothing:** the same non-tile inputs
    with different `view` and `held` lines (a small display and a large
    one) give the same critter, `bump`, `rest` and `release` lines
    (decision 13).
13. **A leash at the screen's edge,** small display against large, fed
    identical recorded inputs (a real pointer would land on other ticks
    while one of them is frozen): the small one freezes until the region
    arrives, and the lines match.
14. **A cow just outside a region tile,** its square poking into the
    region past a tile border: unseen on both sides, and an overlap with it
    is logged, not refused.
15. **A lost answer and a trailing `leash`:** the byte-identical resend
    gets the stored answer, and R + 1 doesn't repeat the leash.
16. **A reload, then `req 1`,** while the old epoch's stored answer was
    also `req 1`: the load cleared it, so `req 1` is new.
17. **A restart, then an old page** whose epoch counts the same as a new
    one: the epochs differ by the server's start, so `reload epoch`.
18. **`req ?`:** the answer is `req ?` alone, and the page stops rather
    than resending (decision 17).
19. **A torn log tail at restart:** dropped, and the board is where the
    last whole report left it.
20. **A cow on the line 70 px ahead, the drag stepping 1 px:** it moves
    70 px in that one step, and stays within the region.
21. **Thirty unleashed pans:** no refusal and no `stuck`, and the report
    carries one `view` and one `held` for that tick, coalesced, however
    long the panning.
22. **A replay whose path reaches a new tile before its recorded `held`:**
    the page writes `view` at that tick and sends it; with the tile's
    critters already in hand it writes `held` too, and without them it
    stops there, the tile arrives, and the replay resumes.
23. **A tile sent again after a `differ`** doesn't move critters the page
    is running.
24. **A `req ?` loop:** a page that garbles its header ends in its stop
    message, and never rewinds.
25. **The 10 × 10 park in the 64 × 64 world:** the first layout puts
    every critter in the park's tiles, four dogs to a tile and a cow on
    each white one, and the empty world around them reads as empty.
26. **The worked example as a golden fixture:** the report above, its
    `kept 1043` answer, and the exact `differ` answer to its variant with
    dog 223's step at 1042 a 256th off,
    byte for byte.
27. **The cows' grid rule in 256ths** (item 1): the lane, the half step,
    the scare box's edges and the on-line cow's side (its right).
28. **A worst-case push at the region's reach:** a scared cow at its
    farthest from the dog's start, pushing a critter whose jump goes
    outward; it lands inside the region or the cow stops short, the same
    on both sides.
29. **A canonical-form round trip:** every line the shared Zig writes
    parses back to the same integers, and every other spelling of them
    (padding, upper case, `+0.00`) is refused.
30. **A 413:** a body over the limit stops the page at once, never
    resending, with the why on the console (decision 17). **And a
    502:** the page resends R byte-identically on the backoff and never
    stops.

## Decisions (Steve, 2026-10-13)

1. **Alphas never yield.** A herd jammed against an alpha stays jammed;
   that's a puzzle for the player.
2. **Awake:** in a subscribed tile *and* within 800 px of the leashed dog.
   The page always sends its viewport size with its subscriptions, and
   both ride the reports (no separate tile requests): subscriptions only
   change when the leashed dog moves or the screen is resized.
   *(Note: a leash, a release and a pan change them too; and decision 13
   makes them the page's choice, separate from the physics.)*
3. **The anchor:** the nearest more-alpha dog of the breed. As people
   follow the person right in front of them, not the one at the head of
   the line.
4. **Cows push unleashed dogs.** They ignore them, and a dog a cow lands
   on gets out from under it at once.
5. **The numbers** are tuned by playing (the table above); Steve will
   suggest tools for tuning and debugging.
6. **Any unleashing puts the park to sleep,** including the leash's 20 s
   running out.
7. **A herd may jam,** awake or not; leashing an outer dog frees it. That's
   part of the game.
8. **A bump ends the drag, never the leash.** The leashed dog can't be
   dragged over or through anyone: it stops just short, the pointer is
   let go, and the leash stays on (the let-go timer starts). Ending a drag
   and unleashing are different things. A shake in the page comes later.
9. **Drags are played in internal steps,** x then y, so the cows react
   before the dog arrives: steps of at most 1 px, the pixel-ticks
   (decision 15). The drag may be held to stricter rules whenever that
   keeps things simple.
10. **A 1 px dead zone** against jitter, to start.
11. **No settling proofs** until the feel has played out; overlaps that
    slip through are handled gracefully and logged, not refuted.
12. **The leashed dog counts as the most alpha dog,** but only its own
    breed follows it; other breeds keep their distance and herd with
    their own kind (Steve, 2026-10-13).
13. **The tiles are not the sphere of influence** (Steve, 2026-10-13).
    Subscriptions are the page's business, driven by the display: the page
    subscribes enough tiles to use its display fairly fully, and every
    tile that could hold anything the physics can touch around the leashed
    dog. It fetches proactively, leashed or not (a resize on a large
    monitor brings in the new tiles at once, dormant critters and all).
    So the tile set is not the physics' input: the physics uses the known
    set and the sphere (awake = known, in a held tile, within 800 px), and
    subscribing more tiles changes only what the page knows and draws.
    *(As drawn up: the physics sees the region's tiles, all held before a
    tick runs; awake = in them and within 800 px.)*
14. **The park is a torus** (Steve, 2026-10-13; done, 2026-10-14, in
    four chunks): a critter leaving one edge enters the opposite one,
    pacman-style. The world is 64 × 64 tiles (item 16), **wider than the
    region plus its reaches** (a comptime check), so no critter is ever
    seen twice and every rectangle a tick builds stands within half a
    world of the leashed dog. What it took:
    - **`delta(a, b)` takes the short way round**, each axis in
      [−world/2, world/2) (`shortWay`). Every centre-to-centre difference
      already went through it: wishes, the scare box's ahead and off,
      `squaresOverlap`, the sweeps, the step's contact, the jump's
      distances.
    - **Every move wraps into [0, world)** with `@mod` (`wrapped`):
      `moved`, `Scene.put` (so every step, push and jump landing).
      Positions are always in the world, as the page and the parse rely
      on.
    - **The rectangles are taken in one frame.** `Rect` holds corners that
      may lie past the world's edges, and is compared only with rectangles
      of the same frame: in a tick, each point's copy nearest the leashed
      dog where the tick began (`nearestCopy`, `Scene.frame`). The region,
      a cow's swept area and end square, the jump's obstacles and its
      candidates are all built so, and a jump's spot comes back in the
      frame and is wrapped as the critter takes it.
    - **The jump** (`physics_jump.zig`) works in the caller's frame:
      `gapOn`, `wayOut`, the candidate box and `offer` are unchanged, and
      `offer` no longer checks the world (there is no edge to keep a
      candidate inside); a spot must lie wholly in the region still.
    - **The edge rules are gone:** `inWorld` (the drag's and a dog's step
      clamped at the edge), `room()` (a cow's shortened step and the
      lane's switch to the other side) and `world_rect`.
    - **The load's resolve** clamps nothing: a critter that overlaps one
      above it jumps around itself (its obstacles as their copies nearest
      it, inside a square just short of half the world).
    - **The tiles wrap (chunk 3a).** `TileSpan.of` names its first column
      and row in the world and counts on past the last tile across the
      seam (64 is tile 0); `holds` tests a tile in that wrapped range;
      `TileSpan.at` names a tile in the world; `tileOf` wraps a point
      first. The page's `regionTiles`, the server's load region and the
      judge's "region held" name every tile in the world, and the wire's
      tiles stay canonical, [0, 64).
    - **The grids are seam-ready (chunk 1).** Both spatial grids pick
      their cell with `seamCell(need, fold)`: the smallest side at least
      `need` that divides the world into a number of cells a side the fold
      divides, so the world's last cell and its first are neighbours in
      the fold too. The neighbour grid: cell 125 px (need 108 px), 256
      cells a side, fold 32. The wishes' grid: cell 250 px played, 400 px
      alt (need: `wary`), fold 16. A coordinate maps to its cell by floor
      division and a cell to its bucket by `@mod`. The cost: the packed
      herd's drag went from 25.4 to 29.5 ms a tick.
    - **The page (chunk 2)** draws, scrolls and subscribes across the
      seam: it draws a critter at its copy nearest the viewport, and its
      viewport and overview scroll round.
    - **The signature property: translation invariance.** A whole scene
      shifted by any vector, mod the world, plays out exactly shifted:
      `physics_symmetry_test.zig` holds it over its scenes and seeded fuzz,
      the action put across x = 0, y = 0 and the corner. Its one limit is
      the tile grid: which critters a region's tiles hold depends on where
      the tiles fall, so a critter at the far edge of the region's tiles
      may be seen in one place and not in the other; the scenes keep
      everything that matters inside the region. It found the one seam bug
      on its first run (a cow's swept area built from a wrapped end).
15. **Pixel-ticks** (Steve, 2026-10-13: the change that made it fun).
    Each 1 px step of the leashed dog's drag is a pixel-tick: after it,
    every awake dog takes a wish step of at most the length the leashed
    dog moved, so the pack keeps pace with the human instead of crawling
    at 7.5 px a second. The budget is the leashed dog's Manhattan path (x
    steps, then y steps), each follower step Euclidean: on a diagonal a
    follower can cover about 1.4 times the leashed dog's straight-line
    distance. That is deliberate.
16. **Every load starts the park afresh** (Steve, 2026-10-13): `POST
    /load` puts back the first layout, nothing leashed and nothing
    waiting, and snapshots it. A reload is a new game.
17. **The page never reloads on its own** (Steve, 2026-10-13): on any
    answer it can't act on (a `reload`, a 413, `req ?`, an unreadable
    answer, `taken over`, `stuck`), it stops, its screen paused, and
    logs the why, the last report and its answer on the console, so
    Steve can report it. Transient failures (no answer, a 5xx) are still
    retried byte for byte, never a stop.
18. **A step is one move** (Steve, 2026-10-14): a dog's wish step is swept
    as a single straight move, not x then y. Swept by axis, a diagonal
    step that clipped a critter's corner was stopped in one axis order
    and not the other, so the physics was symmetric under the world's
    mirrors but not under the transpose (and so not a quarter turn).
    Integer only: the contact is the exact fraction of the step where it
    first presses in, both axes truncated toward zero at it (odd, so the
    mirrors hold; the same rule on both axes, so the transpose holds);
    the slide goes along a single face only, never preferring x to y.
    `physics_symmetry_test.zig` holds the transpose and a quarter turn
    exact. The drag still plays x then y (decision 9): its displacements
    are the human's, and the cows' grid rule is per axis.

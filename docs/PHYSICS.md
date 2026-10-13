# Dog Park's physics, and the report that carries it

**Status: designed, not built** (2026-10-13). The physics of the other
dogs, the cows' place in it, and the text report the page sends the
server, under the client-driven design (the essay
[the client drives](http://143.244.172.148:9100/notes/the-client-drives.md)):
the page runs every tick, and the server re-runs, keeps and acks.

**The first version is the page's physics.** Steve will tune it by
playing, and may still change a foundational assumption here: it is that
feel-driven. The server's side (re-running, keeping, `differ`) starts as
provisional code for debugging, as the Safari drive and Lyn Rummy's drag
and drop did, and firms up once the picture does. Draft 10, 2026-10-13:
nine cold reviews are folded in below.

Steve's rules, which everything here follows:
- **No randomness.** A tick is a function of the board and the player's
  last action.
- **Lower number means more alpha.**
- **Each tick cascades:** the leashed dog, then the cows, then the other
  dogs from most alpha down.
- **Physics is local to the leashed dog:** nothing acts more than a tile's
  width (500 px) away.
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
- **About 1 px a second,** with positions kept in 256ths of a pixel so a
  slow dog really is slow. At 16 ticks a second that is exactly 16/256 of a
  pixel per tick.
- **Awake means close and watched.** A critter takes part only if the
  page knows it, it stands in a tile the page holds, *and* it is within
  500 px of the leashed dog.
  Unleashing puts the whole park to sleep. When a tick moves nothing, the
  human does nothing and no let-go timer is running, the page stops
  ticking and sends nothing until the human acts again (a drag, a grab, a
  let-go, a leash), or until the tiles it holds change while a dog is
  leashed.
- **The report is text,** one line per tick with the human's input, then
  every critter that moved, before and after, in rank order (the leashed
  dog, cows by number, dogs by number): a proof the server checks line by
  line. Each report carries a request number, and every answer echoes it:
  `kept`, `differ` (naming the first line it disagrees with), `resume`,
  `reload`, `taken over` or `stuck`.
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

**A drag is played the way the cows already play a move:** each
displacement as its x part then its y part (a street, then an avenue),
in internal steps of at most 10 px. An axis part d is cut into
n = ceil(|d| / 10 px) steps, as `cows.zig` cuts a move: step i ends at
d·i/n, truncated toward zero, in 256ths: 25 px is 6400, cut 2133, 2133,
2134 (about 8⅓ px each). In each step:
1. **the step is shaped first** (item 13): at the world's edge, that
   axis's part is clamped so the dog's square stays in the world (the drag
   carries on), and the tile stall cuts it (item 14);
2. **the cows react,** by the grid rule, to the step as shaped;
3. **then the leashed dog takes it,** swept against where everyone now is,
   stopping **just short** of pressing into anyone (one axis at a time, so
   contact is an exact integer: no rounding).

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

The world's edge clamps the dog without ending the drag.

Within a tick, in this order:

1. **For each step of the drag,** as above: the cows react, then the
   leashed dog moves. Physics never moves the leashed dog otherwise.
   Cows ignore the other dogs, and push them (below).
2. **Then, once per tick, every awake dog, by number, smallest first,**
   takes its own step (its wishes). Each sees the positions of everything
   above it *as already moved this tick*: the leashed dog's new place, the
   cows' new places, and the more-alpha dogs' new places.

So the cows react to every step of a drag and the dogs' own wishes run
once a tick. A dog that a cow pushes and that then takes its own step in
the same tick gets one line in the report, its net move, as cows do.

Looking only up the cascade also gives followers for free, as Steve
wanted. A beta's anchor is
always someone more alpha, so a herd forms as a chain or tree hanging off
its most-alpha member. When the player pushes the alpha around, the herd trails
after it at 1 px a second.

## What a dog wants

For one awake dog, call it D, each tick. Only **awake** critters are
anchors, strangers or room-makers; a known sleeper is just an obstacle,
and a critter outside the **known set** isn't there at all (below), so
the page never needs critters further than a tile from the leashed dog.

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
this doc; the tile stall alone is drawn as "nearer than". **When two
centres coincide** (an overlap slipped through), "away" has no direction:
take east, or west at the world's east edge.

**The wish arithmetic, in this order.** Each wish, per axis, is the axis
of the centre-to-centre vector times the wish's length, divided by the
distance (`isqrt`, rounded down), the product in `i64` and the quotient
truncated toward zero. The wishes are summed per axis. The step is then
the total if its squared length is at most the speed squared (exact, no
root), else each axis of the total times the speed, divided by the total's
length (`isqrt` of its squared length), truncated toward zero. **Every
comparison of a length with a number is made squared,** the dead zone's
too; `isqrt` appears only as a divisor. With today's numbers the first
branch never runs: a total inside the speed (16/256 px) is inside the
1 px dead zone too, so the dog stays put. It is there for when the speed
is tuned past the dead zone.

**Cows push dogs.** A cow is bigger than an unleashed dog and isn't afraid
of it; it respects only the leashed dog, which has a human guiding it.
So the cows move first and ignore the other dogs, and a cow step may land
a cow on top of one. That dog gets out from under it at once, during the
cow's step:
- **the step:** to the nearest spot clear of everyone (below);
- **not the usual speed:** it isn't limited to 1 px a second;
- **then, at its turn, the usual wishes,** including room for the cows.

It's a little jump, and that's fine (Steve's call).

**The step.**
1. Add up the wishes.
2. If the total's squared length is less than the **dead zone**'s squared
   (1 px to start), D stays put this tick: close enough.
3. Otherwise D moves along the total, by the total's length or its speed
   per tick, whichever is less, and **stops where it would press into any
   known critter** (above or below it, awake or asleep): a dog's own step
   never lands it on anyone. Only the cows ever push.
4. **At the world's edge,** each axis's part is clamped so D's square
   stays in the world. A part clamped to nothing counts as not moving (for
   `rest`).

The dead zone is there because opposing wishes (an anchor on one side, a
stranger on the other) can overshoot each other: without it, a dog at
the balance point flips 1/256 of a pixel each way, every tick, for ever.
How it feels is for play to decide; stepping half the total is the other
cure.

**Resting.** A tick **rests** when nothing moved in it, the human did
nothing, and no let-go timer is running: then the next tick, a pure
function of the same board and no input, would move nothing either. It's
a fixed point, so the page stops ticking altogether: no reports, no work
for the server, until the human acts again. A jammed herd rests too,
wishes and all; leashing an outer dog wakes it. **What ends a rest:** a
`drag`, `grab`, `letgo` or `leash` (a rest can come with the pointer held
still on the leashed dog, so a let-go can arrive mid-rest, and starts the
timer); and a `view` or `held` that takes effect while a dog is leashed,
which changes who is awake and what is known. The page ticks again from
that input's tick (last tick + 1).

**Breeds.** Four, the dogs with legs: 🐕 🐩 🦮 🐕‍🦺. Dog n has look n
mod 4, so a breed's dogs are every fourth number, spread through the
park. Herds would form as the player leads an alpha among its kind.
- **What it costs:** today's park deals out five looks, the face 🐶
  among them.
- **Why it matters:** the server refuses to start if a kept dog's look
  isn't the one its number gives.
- **So:** going to four needs a one-time change to `dogs.json`, or a fresh
  park.

**Starting numbers,** all to be tuned by playing:

| | |
|---|---|
| tick | 16 a second (62.5 ms) |
| speed | 1 px a second: 16/256 of a pixel a tick |
| awake | within 500 px (one tile) of the leashed dog, centre to centre, at the tick's start |
| wary of another breed | 150 px centre to centre |
| follow: looks for an anchor within | 400 px |
| herd band, to the anchor | 60 to 100 px, centre to centre (two dogs side by side on an axis: squares 20 to 60 px apart) |
| room for a cow | 90 px |

Every distance is under 500 px, so nothing reaches further than a tile's
width.

**Arithmetic.** Every critter's position is an integer count of 256ths of
a pixel, the cows' too (they are in halves today), with an integer
square root for distances. **Every product is `i64`:** squared distances
(in 256ths they reach about 10^12), a wish's direction times its length
(about 8·10^9 at the extremes), and a total scaled to the speed. Only a
quotient comes back to `i32`, and every `i32` holds a position, a
displacement or a distance in the world. The cows' grid rule takes whole pixels today: it
needs a real port to 256ths, not a change of units. The cows taught us that page and server agree
to the bit only through the same compiled code.
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
`tiles.zig` (a tile holds 0 ≤ x − its left < 500 px). A *square* is in the
world, or wholly in a tile, when it lies within the closed rectangle:
touching the world's east wall at x = 5000 px, or a tile's border, is
inside. Gaps to a tile (the stall's) are measured to the closed rectangle
too. **A square or a viewport *meets* a tile half-open:** when they share
some of its interior, so one whose edge lies on a tile border doesn't
meet the tile beyond. So a 1400 px span meets at most 4 tiles on an axis
(item 11).

**The known set, and the region.** Every obstacle, reach and overlap
check, on both sides, looks only at the **known** critters (the ones the
page holds) **whose square meets the region**: the 1400 px square around
the leashed dog at the tick's start ("What awake means"). A known critter
beyond it is drawn, but the physics doesn't see it, so the tiles the page
subscribes for its display never change a tick.
- **A tile's critters join** at the tick its `held` line takes effect.
  The page takes those it doesn't know already; one it knows (it walked
  in) keeps the page's own position.
- **At every `view` line,** each known critter standing in a tile that view
  doesn't subscribe leaves the known set.
- **A critter that walks out of a held tile stays known** until a `view`
  leaves out the tile it then stands in.
- **A page load resets it:** the known set becomes exactly the critters of
  the tiles in the load's `held K+1`.
- **The page keeps every critter it received this epoch,** known or not.
  When a `view` subscribes again a tile whose critters it already
  received this epoch, the page writes that tile in a `held` line at the
  same tick (no ack to wait for), and its critters rejoin where the page
  last had them. That is where they are on the server too: a critter
  outside the known set is absent from both runs, so nothing moves it.
  (Of the two ways to fix a re-subscribed tile, this is the simpler: the
  server never resends a tile within an epoch.)

The server knows every critter in the park, but in its re-run it treats
everyone outside the known set as absent, exactly as the page must. So a
sleeper beyond the tiles the page holds is neither an obstacle nor a
landing spot's problem on either side; an overlap with it, if one
happens, is a finding (below), not a `differ`.

**Where an overlap could come from,** before any rule:
- **The human** drags the leashed dog onto a sleeping dog, a herd, a cow
  pinned against the wall.
- **Cows ignore each other**: the grid rule can step one cow onto another.
- **Cows ignore unleashed dogs,** by design, so a cow lands on a dog.
- **An alpha ignores betas,** by design.
- **A critter getting out from under something** can jump onto a third.
- **The park already has overlaps.** Today nothing prevents them, and
  dogs dragged onto each other in play stay that way. A board loaded
  from `dogs.json` may break the invariant before the first tick.

**Rank** is the cascade's order: the leashed dog, then cows by number,
then dogs by number. Sleepers and the world's edge never move.

**The rules, one per kind of mover:**
- **The leashed dog** stops just short of pressing into any known critter, swept
  along each step of the drag, and the drag ends (above). It never
  overlaps anyone.
- **A dog's own step** (its wishes) stops where it would press into any
  known critter, above or below it, awake or asleep, and keeps its square
  in the world.
- **A cow's grid step** is swept too, per internal step: it stops just
  short of the leashed dog, any known sleeper (sleeping dogs aren't
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
  are all leaving. If every one of them finds such a spot, they all jump
  there, at once. If any has none, the cow stops just short of the first
  critter **along its sweep** (ties by rank), and **pushes no one**; if it
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
  of critters already placed in this push, and every other known critter
  as it stands. The old squares of the critters being pushed, the pushed
  critter's own included, make none: they are all leaving.
- **The ways out:** the pushed critter pressed against each side of each
  such square, so a spot just past a third square is found. A way out
  moves one coordinate and keeps the pushed critter's other.
- **The corners** where two ways out meet, from one square or two: the x
  of one, the y of the other.
- **Only spots whose square lies in the world and wholly in tiles the
  page holds** at that tick (by the `held` lines).

**Neighbours are always taken in rank order,** whatever order they arrived
in (the page's tiles fill in arrival order; the server's don't). Every
candidate is checked against **every known critter whose square overlaps
it** (found through the tiles around the candidate, not the pushed
critter's reach: a spot pressed against a neighbour's far side can
overlap a critter the reach never saw) and the world's edge, and the
nearest valid one wins. A jump can therefore go as far as the pushed
critter's side, plus the 100 px gap, plus the neighbour's side: about
200 px for a dog pressed past a cow, 220 px for a cow. **Ties** are broken
by the rank of the square that made the candidate (for a corner, the
higher-ranked of its two, then the other's; the swept area ranks with its
cow, just after the cow's own square), then by direction in a fixed
order: east, south, west, north, then the corners NE, SE, SW, NW (a
corner's direction is its x side, then its y side: x from an east side
and y from a north side is NE). Two corners still tied (the same two
squares, each giving the x once) go to the one whose x comes from the
higher-ranked square. The search
stays within that reach, so it is local and cheap; finding none is
"nowhere to go".

**The server checks the invariant on its own,** after every tick, among
the known critters, and logs any
overlap with the tick and the pair: a finding, not a refutation (above).
That catches a bug in the rule itself, which a re-run of the same code
would repeat faithfully.

**The park on load.** If the kept positions break the invariant (today's
park can), the server resolves it **once, when it starts on a board that
has never been resolved**: one read from `dogs.json` with no snapshot
behind it. A board from a snapshot or the log was resolved already and
is never resolved again; a page load resolves nothing (an overlap a live
page holds is handled by the graceful rule above). First the
leashed dog, if any, is moved into the world: each axis of its point
clamped so its square lies in the world (`keptInWorld` keeps only the
point in). Nothing outranks it, so it needs no spot. Then in rank order
(cows, then dogs, by number), each critter that overlaps one above it, or
whose square sticks out of the world, jumps to the nearest spot clear of
everyone, everyone treated as awake and known and every tile as held. It
logs what moved, as the log's first entry, and keeps the result (the
first snapshot). If some critter has nowhere to go, the server does not
start, and says which (fail, never warn). Every page loads that board.

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

## What "awake" means

Both, as Steve decided: a critter is awake if the page has it *and* it is
within **500 px of the leashed dog**, at the tick's start (the **sphere of
influence**). Exactly: it is **known**, its point stands in a tile the
page **holds** (its critters arrived: a `held` line), and it is within
500 px. A known dog that walked into a tile the page doesn't hold yet is
asleep, an obstacle.

**The tiles are not the sphere** (decision 13). The checkerboard is how
the page learns about critters; the sphere is what the physics acts on.
- **Subscriptions are the page's business, driven by the display.** The
  page subscribes enough tiles to use its display fairly fully (not
  necessarily the whole window), **and** every tile that could hold
  anything the physics can touch (below). It fetches **proactively,**
  leashed or not: a resize on a large monitor brings in the new tiles at
  once, dormant critters and all, and so does a pan.
- **So subscribing is not an input to the physics.** Subscribing more
  tiles changes what the page knows and draws, never what the physics
  does: the physics looks only at the **region** around the leashed dog
  (the known set, above), and the page always holds the region's tiles
  before the dog can reach them (the stall, item 14).
- **The region** is the 1400 px square centred on the leashed dog at the
  tick's start: the 500 px sphere, plus the most a tick's drag may move
  the dog (below), plus a 100 px margin for what reaches past the sphere
  (a pushed critter's jump, an obstacle beside an awake dog). The page's
  promise is to subscribe every tile meeting it while a dog is leashed.
- **How subscriptions travel:** a `view` line in the next report, at the
  tick it takes effect, with the viewport's size (decision 2). There is no
  separate request. The server sends what it subscribes; its re-run uses a
  `view` only to drop from the known set the critters of tiles the page
  let go of, which lie outside the region (the page never drops a tile
  meeting it).
- **What the server sends back:** with **every** answer that keeps
  anything, the critters of every tile the latest kept `view` subscribes
  that the page hasn't yet named in a `held` this epoch, as they stand at
  the answer's last kept tick. The server tracks that per epoch, so a
  tile's critters can't be lost with an answer: a `differ`, or a lost
  answer and a resend, still delivers them. (They are current: a critter
  in a tile the page doesn't hold is unknown, so nothing moves it.) A tile
  already named in a `held` this epoch is never sent again; the page
  re-holds it from what it kept (the known set, above).
- **Only tiles the page holds count, and the report says when it starts
  holding one.** A subscribed tile's critters arrive with an ack, which
  can come back while the page is already ticks ahead, so the page
  records the moment it starts using them as an input: a **`held T c,r
  …`** line, the tiles it holds from the start of tick T. The server's
  re-run uses exactly those lines, and they define the known set (above).
  So page and server agree on what was an obstacle at every tick, whenever
  the acks arrived. The page never ticks with critters it hasn't seen. The
  server checks that a `held` line names only tiles whose critters it has
  sent this epoch and that the `view` in effect at its tick subscribes;
  otherwise `differ` at that line.
- **A tick's drag moves the leashed dog at most 100 px on each axis.** A
  faster flick is cut there for that tick (the drag is held to a stricter
  rule, as allowed above). Diagonally that is up to 141 px, which is why
  the region and the stall are in the square metric.

A report may carry no ticks at all: a resize, or panning while nothing is
leashed, is just a `view` line. **An input while the page isn't ticking**
(a `view`, a `held`, a `leash`, a `grab`, a `letgo`) takes the last
recorded tick + 1, as a `leash` does (item 8); several at one tick apply
in the order written, at most 16. During a replay held back at the byte
budget (item 10), "the last recorded tick" is the last tick the page has
recorded, never one inside the held-back ticks. While unleashed, any input other than a `view` or `held`
starts the ticking at that tick.

One player and one window, so nothing disagrees. Two windows of
different sizes on one park would each be right about their own physics.
That only matters when there are two players.

**Unleashing puts the park to sleep.** The leash comes off when the human
grabs another dog, or **80 ticks (5 s)** after the drag last ended
(the human let go, or a bump ended it) with no new drag. Grabbing the
leashed dog again at any tick up to and including T + 80 (T the tick the
drag ended) is a new drag (`grab`), and the timer stops: inputs come
before a tick's checked lines, so a `grab` at T + 80 beats the
`release`. While those 80
ticks run, the page keeps ticking (a board can't `rest` during them), so
the release lands on the same tick on both sides. Then every critter
stops where it is, and the page stops ticking until the next leash.

## The report

One report per round trip, as moves are sent today: everything since the
last tick the server kept. For now it says a lot. It names every critter
that moved, where it was and where it went, **in rank order** (the
leashed dog, then cows by number, then dogs by number: a dog a cow pushed
is listed among the dogs, its one net line), so the report is the
calculation written out and the server checks it line by line.

```
dogpark 1 physics 5e0c91a2 page 3 req 4
from 1040 wall 1791936000000
leash 1041 219
view 1041 1280x800 5,7 6,7 7,7 8,7 5,8 6,8 7,8 8,8 5,9 6,9 7,9 8,9
t 1041 +0 drag -1.00,0@3 -2.00,0@19
 dog 219 d80.00,1216.00 > d7d.00,1216.00
 dog 223 e16.00,1216.00 > e15.f0,1216.00
letgo 1042
t 1042 +63
 dog 223 e15.f0,1216.00 > e15.e0,1216.00
t 1043 +125
 dog 223 e15.e0,1216.00 > e15.d0,1216.00
```

The numbers follow the rules. Before the leash, nothing was leashed and
the page held its viewport's tiles: 1280 × 800 at x 2816 to 4096 px and
y 4200 to 5000 px, columns 5 to 8 and rows 8 and 9. The leash brings the
1400 px square around dog 219 (at 3456, 4630 px: x 2756 to 4156, y 3930
to 5000), columns 5 to 8 and rows 7 to 9, so the `view 1041` adds row 7.
Its critters come with the ack, and the page writes `held T 5,7 6,7 7,7
8,7` at the tick it starts using them; until then row 7 is unknown. It
doesn't stall this drag: row 7's nearest edge is y = 4000 px, 630 px
away, nearer than the stall's 700 px, but the drag goes west, along it,
no nearer. No cow and no dog of another
breed is within reach in the held tiles, and dog 223, of
219's breed (223 mod 4 = 3, as 219), stands 150 px east of it. The drag
moves 219 3 px west, so 223 is 153 px from its anchor: 53 px beyond the
band's outer edge. Its one wish is (−13568, 0) in 256ths; scaled to the
speed, its step is −16 (16/256 of a pixel), every tick, until it reaches
the band. So the board doesn't rest, and the 80 ticks run from 1042. A
cow's line looks the same: `cow 23 a > b`.

| line | says |
|---|---|
| `dogpark 1 physics H page E req R` | the language's version; the physics' version, a hash of the physics' sources built into both the wasm and the server, so a forgotten version change can't cause endless disagreement; this page load's epoch, which the server issued; and the request number (below) |
| `from T wall W` | the tick the report starts after (the last one the server kept), and the wall clock (Unix ms) at its first tick, data only (no `wall` on a report with no ticks) |
| `leash T D` | the human leashed dog D at tick T: the park wakes around it |
| `grab T` | the pointer went down on the leashed dog at tick T: a drag is on, and any let-go timer stops (a `leash` implies it) |
| `letgo T` | the drag ended at tick T because the human let go: the 80 ticks start |
| `bump T dog N`, `bump T cow N` | the drag ended at tick T because the leashed dog pressed into that critter: the 80 ticks start, the leash stays |
| `release T D` | the leash came off dog D at tick T (the 80 ticks ran out, or another dog was grabbed): the park sleeps |
| `held T c,r …` | from the start of tick T, the page holds these tiles' critters (they arrived with an ack): an input, so the server counts exactly the tiles the page did |
| `view T WxH c,r …` | from the start of tick T (before that tick's awake set is worked out), the viewport's size and the subscribed tiles: the other half of who is awake, logged with the ticks. Written at a `leash`, a `release`, a pan while unleashed, a resize, and whenever the leashed dog's square meets a different set of tiles |
| `t T +ms` | tick T begins, `+ms` after `wall` (data only). `drag` and its displacements in 256ths, when the human dragged during it, each with `@ms` from the tick's start (data only); at most 16 a tick (the shared Zig adds up any more, item 2). A tick that bumps carries its whole recorded drag, merged and capped, the displacements after the bump included: the physics drops those, and the server finds the bump itself |
| `dog N a > b`, `cow N a > b` | a critter whose position changed over tick T, from a to b, in cascade order: the leashed dog, then cows by number, then dogs by number. A line is the net move over the tick; a critter that ends the tick where it began is not listed, even if it moved within it |
| `rest T` | no critter's position changed over tick T, the human did nothing, and no let-go timer is running: a fixed point, so the page stops ticking until the human acts again (`drag`, `grab`, `letgo`, `leash`), or a change of tiles while leashed. Tick numbers carry on across a rest |

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
critter line per known critter a tick, 16 displacements and 16 inputs a
tick, 32 ticks.
A `board` holds only the awake critters and the ones the report named,
so it is bounded the same way.

**Request numbers.** A report's header carries `req R`: 1 for an epoch's
first report, one more for each new request. **One request is in flight
at a time,** and every answer begins `req R`, echoing it. The page acts
only on the answer to its in-flight request (the exchange it came back
on, whose `req` must match), and any such answer ends that request; every
other answer is dropped unread.
- **No answer:** if none comes within 5 s of wall time, the page abandons
  the exchange and sends request R again, **keeping its number,** rebuilt
  from its current last kept tick with whatever it has recorded since.
- **The server keeps its last answer.** A report whose R is the last one
  it answered gets that same answer again: nothing is re-run, logged or
  counted. A report whose R is one more is a new request. Any other R is
  refused (`differ K+1 none` its header line).

So a lost answer costs one resend, and the page never meets an answer to
anything but what it last asked.

**The server's answers.** The answer to the example report, when all is
well, and had the page written dog 223's step at 1042 as
`> e15.e1,1216.00`:

```
req 4
kept 1043
tile 5,7 …
tile 6,7 …
tile 7,7 …
tile 8,7 …
```
```
req 4
kept 1041
differ 1042 dog 223 e15.f0,1216.00 > e15.e0,1216.00
state leash 219 drag on view 1280x800 5,7 6,7 7,7 8,7 5,8 6,8 7,8 8,8 5,9 6,9 7,9 8,9 held 5,8 6,8 7,8 8,8 5,9 6,9 7,9 8,9
board 1042 dog 219 d7d.00,1216.00 dog 223 e15.f0,1216.00
tile 5,7 …
tile 6,7 …
tile 7,7 …
tile 8,7 …
```

In the second: ticks through 1041 are kept; the server's own line for
1042; at the start of 1042, dog 219 leashed with the drag still on (the
`letgo 1042` is an input of the unkept tick), the view from 1041, and rows
8 and 9 held; the two awake critters, which are also the two the report
named, as tick 1041 left them. Both answers carry row 7's critters, which
the `view 1041` subscribed and the page hasn't yet named in a `held`. What
those lines hold depends on the park, so they are elided here.

| answer line | says |
|---|---|
| `req R` | first in every answer: the report's request number. `req ?` when the server can't read the header; the page takes it as the answer to the exchange it came back on |
| `kept T` | the last kept tick, after this request. With no `differ` or `resume` after it, the whole report is kept: its ticks through T, and any inputs it carried for T + 1 after its last `t` line (they wait for that tick). A report with no ticks gets `kept` its own `from` |
| `differ T <line>` | the server's run has this line at tick T, and the report lacks it or writes it differently. The report is kept through T − 1 (the `kept` above), nothing at T |
| `differ T none <line>` | the report has this line at tick T, and the server's run doesn't; also every **refused** line: malformed, out of bounds, or an input whose precondition fails (below) |
| `resume` | the report's `from` isn't the last kept tick. With request numbers only a page bug does that. What follows is a load's answer (below), in this epoch |
| `state leash D\|none drag on\|ended E\|none view WxH c,r … held c,r …` | at the start of tick T (K + 1 for a load or `resume`): who is leashed; whether a drag is on, or the tick E it ended (the release is due at E + 80), or none (unleashed); the view and the held tiles in effect |
| `board T dog N a cow M b …` | with `differ`: the server's critters at the start of tick T, in rank order: every one it had awake, and every one the report named |
| `input <line>` | with a load or `resume`: an input already kept for K + 1, as written in a report, in order. Only `release`, `leash`, `grab` and `letgo`: a `view` or `held` is in the `state` line. The page plays it at K + 1 and never sends it again |
| `tile c,r dog N a cow M b …` | in any answer: a subscribed tile's critters not yet sent this epoch, as they stand at the start of the tick after `kept` |
| `reload language N`, `reload physics H`, `reload epoch`, `reload differs` | the page speaks another version of the language (N is the server's); its physics isn't the server's (H is the server's); its epoch is not one this run of the server issued; three requests in a row were answered `differ` or `resume` |
| `taken over` | a newer page load holds the park |
| `stuck T` | the physics disagrees with itself at tick T (below): the page shows that, and doesn't tick |

- **`kept T`:** checked, and written to the game's log and synced to disk
  before the answer goes: safe. Every answer that keeps anything also
  carries the critters of the subscribed tiles the page hasn't named in a
  `held` yet (above).
- **`differ T`:** the first line the server's re-run disagreed with, with
  the server's own version of it: `differ T <the server's line>` when its
  run has a line the report lacks or writes differently (critter, `bump`,
  `rest` or `release` alike), and `differ T none <the report's line>` when
  the report has a line its run doesn't, or a line it refuses. Then the
  `state` and `board` at the start of tick T. Everything before tick T is
  kept: the report's ticks through T − 1 are logged and synced before the
  answer goes. If the server's run has a bump the page's didn't, the page
  lets go of the pointer.

**How the page rewinds.** The board in a `differ` holds only some
critters, and the page may already have moved others in ticks it hasn't
sent, so it never rewinds from its current positions. It keeps its own
**board at the last kept tick** (every known critter, the leash, the
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

- **`reload`:** reload and resume from the last kept tick. **A server
  start issues a new epoch,** so every open page reloads (`reload epoch`),
  and nothing kept per epoch needs to survive a restart. **The breaker**
  (`reload differs`) counts requests: three in a row on one epoch answered
  `differ` or `resume` (a repeated answer to a resend counts nothing new):
  something is wrong that rewinding won't fix. **The page and its wasm are
  served under the physics hash** (`/physics-5e0c91a2.wasm`; the page that
  names it is never cached), so a reload can't pick up stale code and loop
  on `reload physics`.
- **`stuck T`:** a genuine split in the shared code would otherwise reload
  every three round trips for ever. The server counts its `reload
  differs` with no kept tick between, across epochs; at the third, it
  marks the park stuck at the tick of the last `differ`, logs it as a
  finding, and answers every load `stuck T`. The page says the physics
  disagrees with itself at tick T, and doesn't tick. A server started with
  other physics (a new hash: the fix) clears the mark.
- **`taken over`:** a newer page load (another tab, a reload) holds the
  park now; this page stops. The server answers only the newest epoch.

**The server reads a report in order,** answering the first thing wrong:
the language version (`reload language`); the physics hash (`reload
physics`); the epoch (`taken over` for an older one this run issued,
`reload epoch` for one it didn't); the request number (above); `from`
(`resume` unless it is the last kept tick); then every other line. A
header it can't read at all gets `req ?` and `differ K+1 none` with the
line, with the state and board at K + 1.

**Every field is bounded as it is parsed,** before any arithmetic: ticks
from `from` + 1 to `from` + 32, and inputs at most at `from` + 33 (one
recorded while the page was frozen at the window takes the last tick + 1);
positions in the world; displacements at most 100 px on each axis and at
most 16 a tick; the tick's displacements within the cap (item 3: the
absolute x parts add up to at most 100 px, and the y parts); at most 16
inputs a tick; tiles in the world, and at most 64 in a `view`; critters
that exist; a `leash` naming a dog in the known set (a dog the page only
drew from an answer's `tile` line must be held first); at most one line
per known critter a tick; hex that fits; and the canonical form (above).
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
WxH`, with the viewport's size. It resolves nothing (above). The answer,
unless it is a `reload` or `stuck T`:

```
epoch E
kept K
state leash D|none drag on|ended E'|none view WxH c,r … held c,r …
input <line>
…
tile c,r dog N a cow M b …
…
```

- **What the server logs:** at K + 1, after the inputs already kept for
  it, a `view` (the viewport's tiles and the region's: the 1400 px square around the
  leashed dog, as those inputs leave it) and a `held` of all of them. They
  replace the old page's tiles, and the known set becomes exactly those
  tiles' critters, every one in a `tile` line. The `state` line gives that
  view and held set; its leash and drag are those at the start of K + 1,
  before the `input` lines.
- **What the page does:** it plays the `input` lines at K + 1 and never
  sends them. If a drag is then on, nobody's pointer is down any more: the
  page's first tick records `letgo K+1` after them, and the 80 ticks
  start. **If the board has a let-go timer running** (or a drag on), the
  page starts ticking at once, at K + 1, so the `release` lands on the
  same tick on both sides. Request numbers start again at 1.
- A second tab does the same and takes over. A `resume` answer is the
  same lines with no `epoch`, and the page takes it the same way,
  dropping its own unkept ticks.

**Why it's cheap to check.** The server keeps the board at its last kept
tick and re-runs the report's ticks: the cascade over the awake critters,
each looking only at neighbours within 500 px, comparing each line it
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
leashed, and whether a drag is on or since which tick it ended; the
park's `stuck` mark, if any; and the physics hash.

**A restart applies the log; it doesn't re-run it.** It loads the last
snapshot, then takes each kept report after it as written: its inputs set
the leash and the drag, its critter lines put critters where they ended,
and its `bump` and `release` lines end drags and leashes. Nothing is
re-run and nothing checked. Of the two ways to restart, this is the
simpler:
- **It survives a physics change.** Steve tunes by deploying, so a log
  tail written under other physics is the usual restart, not an edge. The
  log records what happened, and applying it puts every critter where it
  was; re-running it would need the old physics, or would rewrite history.
- **It needs no per-epoch bookkeeping.** The restart issues a new epoch,
  so every page reloads, and the view, held tiles, known set, tiles sent
  and last answer are all made again at the load.

If the log grows too big to keep, it is the first thing to trim: the
snapshots alone are enough to resume.

## For the first implementation (the page)

The third cold review listed the questions someone building the page's
physics first would hit, in order. The simplest answers, adopted until
play says otherwise:

1. **Cows go to 256ths first,** before any dog physics: port `cows.zig`
   from half pixels, carrying its tests over. "Half as far" becomes the
   step halved and truncated; the lane is 70 px centre to centre (17920: a dog's half, a cow's half and
   the 20 px clearance, as `lane_halves` is today). One change of
   behaviour to expect: a cow in today's 400 px scare box but more than
   500 px from the leashed dog (the box's corners reach 566 px) is now
   asleep.
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
   budget counts the input, not where the dog ended up after a clamp or a
   stall. It suits x-then-y and needs no square root. (Past 16,
   displacements are first added into the 16th.)
4. **A dog's own wish step is swept like the drag:** x then y, stopping
   where it would press in. Sliding along a face comes free.
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
   even when the dog's path changes; the page's next `view` catches up.
7. **Order within a tick:** inputs before its `t` line, checked lines after
   the critter lines. A `letgo` takes effect after that tick's drag (the
   displacements recorded before the pointer went up still play). A
   `release` caused by grabbing another dog and the new `leash` share a
   tick: `release T D1`, then `leash T D2`. A `bump` that presses two
   critters at once names the higher-ranked. **Displacements on the wire**
   are hex like positions, with a sign: `+1.00`, `-2.80`, and `0` for none.
8. **Tick numbers after a sleep:** a `leash` takes the last tick + 1.
9. **The timer:** a drag ending at tick T releases at tick T + 80, and the
   dogs still take their step in that tick. A `grab` at any tick up to and
   including T + 80 stops it.
10. **When a report goes:** whenever none is in flight and there is
    something unsent (ticks, a `view` or a `held`), but no sooner than
    250 ms of wall time after the last one went (wall time, so a page that
    isn't ticking still sends), or at once when the unsent text reaches
    48 KiB. One in flight, never more. **At the 32-tick window, or at
    48 KiB unsent,** the page freezes the physics (it keeps drawing) until
    the ack; the pointer's movement meanwhile adds up and is played,
    capped, at the next tick. A replay after `differ` stops at 48 KiB the
    same way, and the human's inputs meanwhile go after the last recorded
    tick. A `release` ends the ticking: no `rest` after it.
11. **Which tiles are subscribed** is the page's choice (decision 13):
    while a dog is leashed, every tile meeting the region (the 1400 px
    square, at most 4 × 4 = 16 tiles); and, leashed or not, the tiles its
    display can use, fetched as soon as a resize or a pan shows them. A
    W × H viewport meets at most (ceil(W/500) + 1) × (ceil(H/500) + 1)
    tiles: 5 × 4 = 20 for 1920 × 1080, 7 × 4 = 28 for 2560 × 1440,
    9 × 6 = 54 for 3840 × 2160. With the region partly off screen that is
    up to 70, so tiles.zig's cap goes from 25 to **64** (8 × 8; the park
    is 100). **Over the cap,** the page subscribes the region's tiles
    first, then the display's nearest the viewport's centre (by the square
    metric; ties by row, then column), so the physics never loses a tile
    to the drawing. A `view` that leaves out a tile meeting the region is
    logged by the server as a finding, not refused, while the server's
    side is provisional. A view's new tiles count from the tick of the
    page's `held` line for them; tiles dropped from a view stop counting
    at once.
12. **A push's jump may not land outside the tiles the page holds** at
    that tick (by the `held` lines), **nor outside the region**: a
    candidate whose square isn't wholly in held tiles and in the region is
    invalid. So a held tile beyond the region never offers a spot.
13. **"The area the cow swept"** is its sweep in that internal step, and
    "the first one it would have pressed into" is broken by rank. **Order
    within a drag:** the input is capped first (item 3), then split into
    internal steps (above); each internal step is then shaped by the edge
    clamp and the tile stall, the cows react to the step as shaped, and
    the dog takes it.
14. **The drag stalls (without ending) wherever the leashed dog would come
    nearer than 700 px to a tile in the world that the page doesn't hold
    yet**; tiles beyond the world's edge never count. Distance is the
    square metric: from the dog's centre to the tile's closed rectangle,
    the larger of the two axes' gaps. The step is cut where it would cross
    700 px (one axis at a time, as steps are played), so the dog can end
    exactly 700 px away; a step that brings the dog no nearer such a tile
    (away, or along) is allowed, even from inside the 700 px. Nearer than
    700 px is exactly where the region would meet the tile, so the dog
    never moves to where its region reaches a tile the page lacks. Otherwise a
    32-tick report can carry the dog into tiles whose critters haven't
    arrived, and it would walk through a sleeper it can't see.
15. **Determinism in the shared Zig:**
    - explicit `i32`/`i64` everywhere (`usize` is 32 bits in wasm and 64
      natively);
    - never iterate a hash map: sort awake critters by number, neighbours
      by rank;
    - both sides built ReleaseSafe, so an overflow traps the same way, and
      the parse bounds every field (above), so a report can't reach one;
    - the page replays the recorded integers, never raw pointer events.

**Likely to feel wrong first** (the review's guesses, for play to settle):
- **1 px a second may be invisible.** With the park asleep 5 s after you
  let go, a herd trails only about 5 px; expect to want 20 to 60 px a
  second.
- **Ending the drag on any press-in** may drop the dog on pointer jitter
  or a clipped corner. Ending it only past a few px of press-in, or just
  clamping without ending, would be stricter-but-calmer drag rules.
- **The pointer drifts from the dog:** edge clamps, the 100 px cap and the
  tile stall all separate them, since drags are displacements.
- **A pushed dog visibly pops,** up to about 200 px in a tick.
- **A drag stalls right after a leash** when the region reaches past
  the tiles the display already brought in: drags that way wait for the
  first ack (about 250 ms and a round trip). Fetching proactively for the
  display (decision 13) makes that rarer; a margin past the screen would
  make it rarer still, at the cost of more tiles held.
- **Lots of bumps.** Three quarters of the dogs are other breeds and keep
  150 px from the leashed dog, but at 1 px a second they barely retreat,
  so dragging into a mixed crowd bumps and ends the drag often.
- **A cow can push a dog into the player's path:** it lands clear of the
  cow's sweep but maybe in the lane ahead, and the next step bumps it.
- **More stops near the edge of the held tiles.** A jump may not leave
  them, so near that edge more cows stop short and more drags bump.
- **After a bump, the mouse is still down** but the drag is over: the
  human must lift and press again to carry on.
- **Cows move only during drags.** A cow beside a leashed dog held still
  never yields, and the dogs keep their 90 px from it.

## Tests to write first

The ninth review's list, to be the implementation's first tests:

1. **An unleashed pan:** a report with only a `view` gets its `tile`
   lines, and the page then writes `held`.
2. **A `differ` at `from` + 1** produces a rewind, not a reload.
3. **A lost answer:** the resend of the same request gets the server's
   stored answer, and the page is unfrozen and sending from the new kept
   tick within one round trip.
4. **A reload after a kept trailing `leash` or `grab`:** the load's
   `input` lines carry it, and the next three reports are all kept.
5. **A restart under a new physics hash** with a log tail after the
   snapshot: the board is where the tail left it.
6. **A `letgo` at `from` + 33,** recorded while frozen at the 32-tick
   window.
7. **A replay that hits 48 KiB while the human acts:** the new inputs take
   the tick after the last recorded one.
8. **A cow lands on a dog near the edge of the held tiles,** so nothing
   valid lies outward: the cow stops short of the first critter along its
   sweep and pushes no one.
9. **Coincident centres** with the dog's square touching the world's east
   wall: "away" goes west.
10. **The leashed dog overlapping a sleeper,** dragged toward it, along it,
    and from Δ = 0: a bump only when |Δ| shrinks or Δ changes sign.
11. **A wasm-against-native fuzz** of the wish arithmetic at the `i64`
    extremes.
12. **Subscribing more tiles changes nothing:** the same reports run with
    a small display and a large one give the same lines (decision 13).

## Decisions (Steve, 2026-10-13)

1. **Alphas never yield.** A herd jammed against an alpha stays jammed;
   that's a puzzle for the player.
2. **Awake:** in a subscribed tile *and* within 500 px of the leashed dog.
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
5. **The numbers** are guesses, to tune by playing; Steve will suggest tools
   for tuning and debugging.
6. **Any unleashing puts the park to sleep,** including the leash's 5 s
   running out.
7. **A herd may jam,** awake or not; leashing an outer dog frees it. That's
   part of the game.
8. **A bump ends the drag, never the leash.** The leashed dog can't be
   dragged over or through anyone: it stops just short, the pointer is
   let go, and the leash stays on (the let-go timer starts). Ending a drag
   and unleashing are different things. A shake in the page comes later.
9. **Drags are played in steps of at most 10 px,** x then y, as the cows
   play a move, so the cows react before the dog arrives. The drag may be
   held to stricter rules whenever that keeps things simple.
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
    set and the sphere (awake = known, in a held tile, within 500 px), and
    subscribing more tiles changes only what the page knows and draws.

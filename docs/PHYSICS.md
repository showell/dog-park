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
and drop did, and firms up once the picture does. Draft 8, 2026-10-13:
seven cold reviews are folded in below.

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
- **Awake means close and watched.** A critter takes part only if it
  stands in a subscribed tile *and* within 500 px of the leashed dog.
  Unleashing puts the whole park to sleep. When a tick moves nothing, the
  human does nothing and no let-go timer is running, the page stops
  ticking and sends nothing until the human acts again (a drag, a grab, a
  let-go, a leash), or until the tiles it holds change while a dog is
  leashed.
- **The report is text,** one line per tick with the human's input, then
  every critter that moved, before and after, in the order the cascade
  moved them: a proof the server checks line by line. The server answers
  `kept`, `differ` (naming the first line it disagrees with), `reload`, or
  `taken over`.
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
d·i/n, truncated toward zero, in 256ths (25 px goes 8, 8, 9). In each
step:
1. **the cows react first,** by the grid rule, to the step the leashed dog
   is about to take;
2. **then the leashed dog takes it,** swept against where everyone now is,
   stopping **just short** of pressing into anyone (one axis at a time, so
   contact is an exact integer: no rounding). At the world's edge, that
   axis's part of the step is clamped so the dog's square stays in the
   world, and the drag carries on.

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
the total if its length is at most the speed, else each axis of the total
times the speed, divided by the total's length (`isqrt` again), truncated
toward zero.

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
2. If the total is shorter than the **dead zone** (1 px to start), D stays
   put this tick: close enough.
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
too.

**The known set.** Every obstacle, reach and overlap check, on both
sides, looks only at the **known** critters: the ones the page holds.
- **A tile's critters join** at the tick its `held` line takes effect.
  The page takes those it doesn't know already; one it knows (it walked
  in) keeps the page's own position.
- **At every `view` line,** each known critter standing in a tile that view
  doesn't subscribe leaves the known set.
- **A critter that walks out of a held tile stays known** until a `view`
  leaves out the tile it then stands in.
- **A page load resets it:** the known set becomes exactly the critters of
  the tiles in the load's `held K+1`.

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
  before its grid step. If the lower-ranked one is asleep, nobody jumps
  until it wakes;
- **an overlap never deepens:** against a critter it already overlaps and
  may not push, a mover's step on each axis may not shrink the gap
  between the two centres on that axis (|Δ|), nor carry its centre past
  the other's (Δ changing sign). That part of the step is dropped (for the
  leashed dog, it is a bump), and moving apart or along is free. A cow
  overlapping a critter it may push (a lower cow, an awake dog) doesn't
  use this rule: its step goes ahead and the push rule above places the
  critter;
- **the server notes it** in the log as a finding. It does not refute the
  report: the page and the server agreed, and the bug is in the rule,
  which play will show us.

**The nearest spot clear of everyone, deterministically.** It is the
closest position, by straight-line distance, that overlaps no critter and
stays in the world, chosen from a finite list of candidates:
- **The ways out** of every known critter within reach (any whose square
  comes within 100 px of the pushed critter's on both axes: the gap
  between the squares, axis by axis, is at most 100 px), pressed
  against each side of each: not only the square it is under, so a spot
  just past a third square is found. A way out moves one coordinate and
  keeps the pushed critter's other.
- **The corners** where two such ways meet: the x of one, the y of the
  other.
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
200 px for a dog pressed past a cow, 220 px for a cow. Ties are broken by rank of the
neighbour that made the candidate (for a corner, the higher-ranked of
its two, then the other's), then by side (east, south, west, north, with
corners after sides). The search
stays within that reach, so it is local and cheap; finding none is
"nowhere to go".

**The server checks the invariant on its own,** after every tick, among
the known critters, and logs any
overlap with the tick and the pair: a finding, not a refutation (above).
That catches a bug in the rule itself, which a re-run of the same code
would repeat faithfully.

**The park on load.** If the kept positions break the invariant (today's
park can), the server resolves it once, before the first tick. First the
leashed dog, if any, is moved into the world: each axis of its point
clamped so its square lies in the world (`keptInWorld` keeps only the
point in). Nothing outranks it, so it needs no spot. Then in rank order
(cows, then dogs, by number), each critter that overlaps one above it, or
whose square sticks out of the world, jumps to the nearest spot clear of
everyone, everyone treated as awake and known and every tile as held. It
logs what moved and keeps the result. If some
critter has nowhere to go, the server does not start, and says which
(fail, never warn). The page gets the resolved board on load.

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

Both, as Steve decided: a critter is awake if it stands in a **subscribed
tile** *and* within **500 px of the leashed dog**, at the tick's start.

**The subscribed tiles become an input to the physics, so they travel
with the reports.**
- **When it changes:** a page's subscriptions change only when the leashed
  dog moves (and the view follows) or the screen is resized. Either way,
  the change is part of the game's history.
- **How it's sent:** inside the next report, at the tick it takes effect,
  with the viewport's size: a `view` line (below). There is no separate
  request.
- **What the server sends back:** with **every** answer (`kept` or
  `differ`), the critters of every tile the latest kept `view` subscribes
  that the page hasn't yet named in a `held` this epoch, as they stand at
  the answer's last kept tick. The server tracks that per epoch, so a
  tile's critters can't be lost with an answer: a `differ`, or a lost
  answer and a resend, still delivers them. (They are current: a critter
  in a tile the page doesn't hold is unknown, so nothing moves it.)
- **What's logged:** the server applies the set from that tick in its
  re-run, and keeps it in the game's log with the ticks, so a restart's
  replay wakes the same critters.
- **Only tiles the page holds count, and the report says when it starts
  holding one.** A tile subscribed by a `view` wakes nothing until its
  critters have arrived with an ack. The ack can come back while the page
  is already ticks ahead, so the page records the moment it starts using
  them as an input: a **`held T c,r …`** line, the tiles it holds from the
  start of tick T. The server's re-run uses exactly those lines (a tile
  dropped from a `view` stops counting at that view's tick), and they
  define the known set (above). So page and server agree on what was an
  obstacle at every tick, whenever the acks arrived. The page never ticks
  with critters it hasn't seen. The server checks that a `held` line names
  only tiles whose critters it has sent this epoch and that the latest
  `view` subscribes; otherwise `differ` at that line.
- **The page's promise:** it subscribes every tile within 700 px of the
  leashed dog on each axis (the 1400 px square of item 11): the 500 px
  reach, plus the most a tick's drag may move it (below), plus a 100 px
  margin for jumps. A jump can go farther (about 200 px), but never into
  a tile the page doesn't hold (item 12), so a longer one is safe, just
  with fewer spots to choose from. The server knows the viewport, so it
  can hold the page to that.
- **A tick's drag moves the leashed dog at most 100 px on each axis.** A
  faster flick is cut there for that tick (the drag is held to a stricter
  rule, as allowed above). Diagonally that is up to 141 px, which is why
  the promise and the stall are in the square metric.

A report may carry no ticks at all: a resize, or panning while nothing is
leashed, is just a `view` line. **An input while the page isn't ticking**
(a `view`, a `held`, a `leash`, a `grab`, a `letgo`) takes the last
tick + 1, as a `leash` does (item 8); several at one tick apply in the
order written. While unleashed, any input other than a `view` or `held`
starts the ticking at that tick.

One player and one window, so nothing disagrees. Two windows of
different sizes on one park would each be right about their own physics.
That only matters when there are two players.

**Unleashing puts the park to sleep.** The leash comes off when the human
grabs another dog, or **80 ticks (5 s)** after the drag last ended
(the human let go, or a bump ended it) with no new drag. Grabbing the
leashed dog again within the 80 ticks is a new drag (`grab`), and the
timer stops. While those 80
ticks run, the page keeps ticking (a board can't `rest` during them), so
the release lands on the same tick on both sides. Then every critter
stops where it is, and the page stops ticking until the next leash.

## The report

One report per round trip, as moves are sent today: everything since the
last tick the server kept. For now it says a lot. It names every critter
that moved, where it was and where it went, **in the order the cascade
moved them**, so the report is the calculation written out and the server
checks it line by line.

```
dogpark 1 physics 5e0c91a2 page 3
from 1040 wall 1791936000000
leash 1041 219
t 1041 +0 drag -1.00,0@3 -2.00,0@19
 dog 219 d80.00,1216.00 > d7d.00,1216.00
 dog 223 e16.00,1216.00 > e15.f0,1216.00
letgo 1042
t 1042 +63
 dog 223 e15.f0,1216.00 > e15.e0,1216.00
t 1043 +125
 dog 223 e15.e0,1216.00 > e15.d0,1216.00
```

The numbers follow the rules. The tiles around dog 219 are already held,
no cow and no dog of another breed is within reach, and dog 223, of
219's breed (223 mod 4 = 3, as 219), stands 150 px east of it. The drag
moves 219 3 px west, so 223 is 153 px from its anchor: 53 px beyond the
band's outer edge. Its one wish is (−13568, 0) in 256ths; scaled to the
speed, its step is −16 (16/256 of a pixel), every tick, until it reaches
the band. So the board doesn't rest, and the 80 ticks run from 1042. A
cow's line looks the same: `cow 23 a > b`.

| line | says |
|---|---|
| `dogpark 1 physics H page E` | the language's version; the physics' version, a hash of the physics' sources built into both the wasm and the server, so a forgotten version change can't cause endless disagreement; and this page load's epoch, which the server issued |
| `from T wall W` | the tick the report starts after (the last one the server kept), and the wall clock (Unix ms) at its first tick, data only (no `wall` on a report with no ticks) |
| `leash T D` | the human leashed dog D at tick T: the park wakes around it |
| `grab T` | the pointer went down on the leashed dog at tick T: a drag is on, and any let-go timer stops (a `leash` implies it) |
| `letgo T` | the drag ended at tick T because the human let go: the 80 ticks start |
| `bump T dog N`, `bump T cow N` | the drag ended at tick T because the leashed dog pressed into that critter: the 80 ticks start, the leash stays |
| `release T D` | the leash came off dog D at tick T (the 80 ticks ran out, or another dog was grabbed): the park sleeps |
| `held T c,r …` | from the start of tick T, the page holds these tiles' critters (they arrived with an ack): an input, so the server counts exactly the tiles the page did |
| `view T WxH c,r …` | from the start of tick T (before that tick's awake set is worked out), the viewport's size and the subscribed tiles: the other half of who is awake, logged with the ticks |
| `t T +ms` | tick T begins, `+ms` after `wall` (data only). `drag` and its displacements in 256ths, when the human dragged during it, each with `@ms` from the tick's start (data only); at most 16 a tick (the shared Zig adds up any more, item 2) |
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
report never passes 64 KiB. The parse bounds the lines too: at most one
critter line per known critter a tick, 16 displacements a tick, 32 ticks.
A `board` holds only the awake critters and the ones the report named,
so it is bounded the same way.

**The server's answers:**

```
kept 1060
```
```
kept 1041
differ 1042 dog 220 d41.35,1203.f5 > d41.2a,1203.eb
board 1042 dog 219 d7d.00,1217.00 cow 23 d1c.33,1210.1a dog 8 e73.f0,1194.80 dog 220 d41.35,1203.f5 …
leashed 219 drag on since 1041 view 1280x800 5,7 … held 5,7 …
```
```
reload physics 7c2d04b9
```

- **`kept T`:** checked, and written to the game's log and synced to disk
  before the answer goes: safe. Every answer, this one and `differ`, also
  carries the critters of the subscribed tiles the page hasn't named in a
  `held` yet (above).
- **`differ T`:** the first line the server's re-run disagreed with, with
  the server's own version of it: `differ T <the server's line>` when its
  run has a line the report lacks or writes differently (critter, `bump`,
  `rest` or `release` alike), and `differ T none <the report's line>`
  when the report has a line its run doesn't. Then the server's `board` **at the start
  of tick T** (after T − 1, the last tick kept): every critter the server
  had awake, **and every critter the report named** (so one the page woke
  wrongly is put back too), and everything else a rewind needs: who is
  leashed, whether a drag is on or since which tick it ended (for the 80
  ticks), the current view, and the tiles held at T. Everything before
  tick T is kept: the report's ticks through T − 1 are logged and synced
  before the answer goes, as for `kept`. If the server's run has a bump
  the page's didn't, the page lets go of the pointer.

**How the page rewinds.** The board in a `differ` holds only some
critters, and the page may already have moved others in ticks it hasn't
sent, so it never rewinds from its current positions. It keeps its own
**board at the last kept tick** (every known critter, the leash, the
drag or timer, the view, the held tiles), and moves it forward on each
`kept`, replaying the ticks the server kept. On `differ T`, it replays
from that board through T − 1 (ticks the server kept, so the two agree),
lays the server's board over the result (a critter in it takes the
server's position; the rest stand), and replays its own inputs from T.
- **`reload`:** the page's physics is not the server's, or three `differ`s
  came in a row (a circuit breaker: something is wrong that rewinding
  won't fix). Reload and resume from the last kept tick.
- **`taken over`:** a newer page load (another tab, a reload) holds the
  park now; this page stops. The server answers only the newest epoch.
  A report whose `from` isn't the last kept tick (a duplicate, or one
  sent before a reload) gets `kept K`, then `differ K+1 from F` (F the
  report's `from`, K the last kept tick), then the board at the start of
  K + 1. The page rewinds to it as above.
- **No answer:** if none comes within 5 s of wall time, the page sends the
  same report again. If the server had kept it, the resend gets the
  stale-`from` answer, which carries the board and any unheld tiles'
  critters, so nothing is lost either way.

**Every field is bounded as it is parsed,** before any arithmetic: ticks
after `from` and within the 32-tick window, positions in the world,
displacements at most 100 px on each axis and at most 16 a tick, the
tick's displacements within the cap (item 3: the absolute x parts add up
to at most 100 px, and the y parts), tiles in the world, critters that
exist, at most one line per known critter a tick, hex that fits, and the
canonical form (above). A report that breaks a bound gets `differ` at
the offending line (for the cap, the `t` line), with the board: a trap on
the server would be a crash, not a refutation.

**Loading the page** carries the viewport's size. The answer is the
board, the last kept tick K, a new epoch, the view (the viewport's tiles
and the 1400 px square around the leashed dog) and those tiles' critters,
all in one. The server logs a `view K+1 …` and a `held K+1 …` for the new
epoch, which replace the old page's tiles and reset the known set to
exactly those tiles' critters, so the new page's first tick already holds
everything it was sent. If the board has a drag on, nobody's
pointer is down any more: the new page's first tick records `letgo` and
the 80 ticks start. **If the board has a let-go timer running** (or a drag
on), the page starts ticking at once, at K + 1, so the `release` lands on
the same tick on both sides. A second tab does the same and takes over.

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

Every few seconds the server also writes a **snapshot**: everything a
replay starts from. That is every critter's position; the last kept tick;
the epoch; who is leashed, whether a drag is on or since which tick it
ended; the current `view` and the held tiles; the known set (critter
numbers, since a critter that walked out of a held tile is known without
being in one); and the physics hash. A restart loads the last snapshot
and replays the log after it, which is exactly the re-run the server does
for every report anyway. If the log grows too big to keep, it is the
first thing to trim: the snapshots alone are enough to resume.

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
   the shared Zig,** not in JavaScript, so the server reproduces them. The
   report carries the displacements after merging and capping. A report
   whose tick is over the cap gets `differ` at that tick's `t` line, with
   the board (a parse bound, above).
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
   ignores a `drag` with no drag on, and logs it as a finding.
7. **Order within a tick:** inputs before its `t` line, checked lines after
   the critter lines. A `letgo` takes effect after that tick's drag (the
   displacements recorded before the pointer went up still play). A
   `release` caused by grabbing another dog and the new `leash` share a
   tick: `release T D1`, then `leash T D2`. A `bump` that presses two
   critters at once names the higher-ranked. **Displacements on the wire**
   are hex like positions, with a sign: `+1.00`, `-2.80`, and `0` for none.
8. **Tick numbers after a sleep:** a `leash` takes the last tick + 1.
9. **The timer:** a drag ending at tick T releases at tick T + 80, and the
   dogs still take their step in that tick.
10. **When a report goes:** whenever none is in flight and there is
    something unsent (ticks, a `view` or a `held`), but no sooner than
    250 ms of wall time after the last one went (wall time, so a page that
    isn't ticking still sends), or at once when the unsent text reaches
    48 KiB. One in flight, never more. **At the 32-tick window, or at
    48 KiB unsent,** the page freezes the physics (it keeps drawing) until
    the ack; the pointer's movement meanwhile adds up and is played,
    capped, at the next tick. A `release` ends the ticking: no `rest` after
    it.
11. **Which tiles are subscribed:** the viewport's, plus every tile
    meeting the 1400 px square centred on the leashed dog. The square
    meets at most 4 × 4 = 16 tiles; a W × H viewport at most
    (ceil(W/500) + 1) × (ceil(H/500) + 1). A 1920 × 1080 screen can need
    5 × 4 + 16 = 36, past tiles.zig's cap of 25, so the cap goes to **49**
    (7 × 7). A 2560 × 1440 screen needs at most 7 × 4 + 16 = 44, under it;
    only a screen of more than about 33 viewport tiles (4K) passes it.
    **Over the cap,** the page subscribes the square's tiles first, then
    the viewport's nearest the leashed dog (by the square metric of item
    14; ties by row, then column) up to 49, so the physics never loses a
    tile to the drawing. A view that breaks
    the page's promise is logged by the server as a finding, not refused,
    while the server's side is provisional. A view's new tiles count from
    the tick of the page's `held` line for them; tiles dropped from a view
    stop counting at once.
12. **A push's jump may not land outside the tiles the page holds** at
    that tick (by the `held` lines): a candidate whose square isn't wholly
    in held tiles is invalid.
13. **"The area the cow swept"** is its sweep in that internal step, and
    "the first one it would have pressed into" is broken by rank. **Order
    within a drag:** the input is capped first (item 3), then split into
    internal steps (above); each internal step is then shaped by the edge
    clamp and the tile stall, the cows react to the step as shaped, and
    the dog takes it.
14. **The drag stalls (without ending) wherever the leashed dog would come
    nearer than 600 px to a tile in the world that the page doesn't hold
    yet**; tiles beyond the world's edge never count. Distance is the
    square metric: from the dog's centre to the tile's closed rectangle,
    the larger of the two axes' gaps. The step is cut where it would cross
    600 px (one axis at a time, as steps are played), so the dog can end
    exactly 600 px away; a step that brings the dog no nearer such a tile
    (away, or along) is allowed, even from inside the 600 px. Otherwise a
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
- **A drag stalls right after a leash.** With a 1280 × 800 view and the dog
  centred, the next tile beyond the viewport is often within 600 px, so
  drags that way wait for the first ack (about 250 ms and a round trip).
  Subscribing the viewport plus 700 px while unleashed would start every
  leash fully held, at the cost of more tiles (open question 2).
- **Lots of bumps.** Three quarters of the dogs are other breeds and keep
  150 px from the leashed dog, but at 1 px a second they barely retreat,
  so dragging into a mixed crowd bumps and ends the drag often.
- **A cow can push a dog into the player's path:** it lands clear of the
  cow's sweep but maybe in the lane ahead, and the next step bumps it.

## Decisions (Steve, 2026-10-13)

1. **Alphas never yield.** A herd jammed against an alpha stays jammed;
   that's a puzzle for the player.
2. **Awake:** in a subscribed tile *and* within 500 px of the leashed dog.
   The page always sends its viewport size with its subscriptions, and
   both ride the reports (no separate tile requests): subscriptions only
   change when the leashed dog moves or the screen is resized.
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

## Open questions for Steve

1. **Physics tiles and drawing tiles.** Everything awake lies in the
   1400 px square around the leashed dog (at most 16 tiles); the
   viewport's tiles beyond it only draw. Should `view` and `held` carry
   just the square's tiles, with the viewport's subscribed for drawing
   outside the physics and the cap? It doesn't block a first version: the
   cap of 49 covers screens up to 2560 × 1440, and item 11's over-cap rule
   keeps a 4K page's physics whole.
2. **A margin while unleashed.** Should the page subscribe the viewport
   plus 700 px while nothing is leashed, so a new leash never stalls on
   its first ack, at the cost of more tiles held?

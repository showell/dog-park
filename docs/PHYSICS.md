# Dog Park's physics, and the report that carries it

**Status: designed, not built** (2026-10-13). The physics of the other
dogs, the cows' place in it, and the text report the page sends the
server, under the client-driven design (the essay
[the client drives](http://143.244.172.148:9100/notes/the-client-drives.md)):
the page runs every tick, and the server re-runs, keeps and acks.

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
- **No two critters ever share space** (below).

## The short version

- **Each tick is a pure function:** the board before, plus what the human
  did during the tick, gives the board after. No randomness, no wall
  clock: drags are displacements, and critters react to them at once,
  whatever their speed. Wall time paces the page and is recorded, never
  computed with.
- **One rule makes it settle: a dog only answers to those above it in the
  cascade.**
  - **Who's above it:** the leashed dog, the cows, and more alpha dogs.
  - **Who it ignores:** dogs further down, so a beta never pushes an
    alpha.
  - **Why that settles:** every dog's move depends only on dogs that have
    already moved this tick. Nothing can chase anything in a circle, so a
    board left alone comes to rest.
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
  stands in a subscribed tile *and* within 500 px of the leashed dog. Any
  unleashing puts the whole park to sleep: a release, or the leash's 5 s
  running out. When every awake dog rests, the page stops ticking and
  sends nothing.
- **The report is text,** one line per tick with the human's input, then
  every critter that moved, before and after, in the order the cascade
  moved them: a proof the server checks line by line. The server answers
  `kept`, `differ` (naming the first line it disagrees with), or `reload`.
- **No two critters ever share space.** Whoever ranks lower in the
  cascade gets out of the way, a sleeper never moves, and the leashed
  dog stops rather than push a critter that has nowhere to go.

## The cascade, and why it settles

Within a tick, in this order:

1. **The leashed dog** moves along the human's drag. Physics never moves
   it.
2. **The cows** react to the leashed dog, as they do today: the grid
   rule, each part of the move scaring the cows ahead of it. Cows ignore
   the other dogs.
3. **Every awake dog, by number, smallest first.** Each sees the positions
   of everything above it *as already moved this tick*: the leashed dog's
   new place, the cows' new places, and the more-alpha dogs' new places.
   It does not look at dogs below it at all.

That last rule carries the stability:
- **The most alpha awake dog** answers only to the leashed dog and the
  cows. Once the player stops dragging, it settles.
- **The next dog** answers to that one too, which has settled, so it
  settles.
- **And so on down.** Each dog is chasing something that stops, so the
  whole board comes to rest.

Without the rule, two dogs that each step away from the other can
oscillate for ever, and an iteration order or a rounding decides who
wins. With it, the board has a direction: alphas set the scene and betas
fit around them.

It also gives followers for free, as Steve wanted. A beta's anchor is
always someone more alpha, so a herd forms as a chain or tree hanging off
its most-alpha member. When the player pushes the alpha around, the herd trails
after it at 1 px a second.

## What a dog wants

For one awake dog, call it D, each tick:

**1. Room from other breeds above it.** For each dog of another breed
above D, within the *wary* distance, D wants to be farther away. Its wish
is a step straight away from that dog, as long as the shortfall. These
add up, so a dog squeezed between two strangers is pushed out sideways.

**2. Its place in the herd.** D's *anchor* is the nearest dog of its own
breed that is more alpha, within the *follow* distance. If D has no
anchor, it is the herd's head and only keeps its room. Against the anchor:
- **Too far** (beyond the band's outer edge): D wants to step toward it.
- **Too close** (inside the inner edge): D wants to step away. This is
  "near but not on top".
- **In the band:** content.

**3. Room from the leashed dog and the cows.** The same as 1, with its own
distances. The leashed dog is the human's, so everyone gives it room.

**Cows push dogs.** A cow is bigger than an unleashed dog and isn't afraid
of it; it respects only the leashed dog, which has a human guiding it.
So the cows move first and ignore the other dogs, and a cow step may land
a cow on top of one. That dog then gets out from under it at once:
- **the step:** the least that puts its square clear of the cow's;
- **not the usual speed:** it isn't limited to 1 px a second;
- **then the usual wishes,** including room for the cows.

It's a little jump, and that's fine (Steve's call).

**The step.**
1. Add up the wishes.
2. If the total is zero, D rests this tick.
3. Otherwise D moves along the total, by the total's length or its speed
   per tick, whichever is less.

That "whichever is less" is what lets a dog arrive and stop instead of
overshooting and jittering around its place.

**Resting.** A dog all of whose wishes are zero has nothing to do. It
stays put until something above it moves into one of its bands. When
every awake dog rests and the human isn't dragging, the page stops
ticking altogether: no reports, no work for the server, until the next
drag.

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
| herd band, to the anchor | 60 to 100 px: squares 20 to 60 px apart |
| room for the leashed dog | 80 px |
| room for a cow | 90 px |

Every distance is under 500 px, so the invariant holds: nothing reaches
further than a tile's width.

**Two dogs exactly on top of each other** have no "away" direction, and
the rule needs one. Take a fixed answer: the beta steps east, or north if
east is the wall. It will almost never happen, but a determinism bug
waits in exactly that kind of corner.

**Arithmetic.** Every critter's position is an integer count of 256ths of
a pixel, the cows' too (they are in halves today), with an integer
square root for distances. The cows taught us that page and server agree
to the bit only through the same compiled code.
- **The whole pixel** is the position shifted right by 8.
- **On the wire,** a position is hex with a point: `d80.40` is 3456 and
  64/256, or 3456.25 px. Exact, fixed-width, and truncated by dropping
  what follows the point.
- **Where a person reads it,** in the page's debugging overlay or a log
  meant for people, it is shown in decimal pixels.

## No two critters ever share space

**The invariant.** At the end of every tick, no two critters' squares
overlap: dogs 40 px, cows 60 px, centred on their points, awake or
asleep, the leashed dog included. Touching is allowed; overlapping by
1/256 of a pixel is not. In 256ths, squares of sides a and b centred at
p and q overlap exactly when |px − qx| < (a + b)/2 and
|py − qy| < (a + b)/2.

**Why it doesn't hold by itself.** Each piece of the design so far can
break it:
- **The human** drags the leashed dog anywhere: onto a sleeping dog, onto
  a cow pinned against the wall, into a crowd.
- **Cows ignore each other.** The cows' grid rule can step one cow onto
  another.
- **Cows ignore unleashed dogs,** by design, so a cow lands on a dog.
- **An alpha ignores betas,** by design, so an alpha steps onto a beta.
- **A dog getting out from under something** can jump onto a third
  critter.
- **Sleepers never move,** so anything that lands on one has to leave.
- **The park already has overlaps.** Today nothing prevents them, and
  dogs dragged onto each other in play stay that way. A board loaded
  from `dogs.json` may break the invariant before the first tick.

**The rule: rank decides who moves.** Every critter has a rank:
1. **The world's edge and the sleepers.** They never move this tick.
2. **The leashed dog.**
3. **Cows,** by number.
4. **Dogs,** by number.

This is the cascade's order, with the immovable first. In the cascade,
each awake critter, at its turn:
- **Never moves into anyone above it.** Its own step (a cow's grid step, a
  dog's wish) stops at contact with anyone above it: anyone ranked
  higher, or asleep, already in their final place for this tick.
- **Leaves anyone above it that landed on it.** If, before its own step,
  it overlaps someone above it, it first takes the **nearest clear
  spot**: the least move that clears everyone above it, staying in the
  world. Speed doesn't limit this; it's a mini-jump.
- **Ignores anyone below it.** Those are the lower ranks' problem, at
  their own turn.

By the end of the cascade, every critter is clear of everyone above it.
Overlap is symmetric, so no pair overlaps: the invariant holds by
induction down the ranks.

**The nearest clear spot, deterministically.** It is the closest
position, by straight-line distance, that overlaps no one above, chosen
from a finite list of candidates:
- **The four ways out** of each square it overlaps, pressed against that
  square's sides.
- **The corners** where two such ways meet.

Every candidate is checked against everyone above and the world's edge,
and the nearest valid one wins. Ties go in a fixed order: east, south,
west, north. The search looks no further than one square's width, so it
stays local and cheap.

**When there is nowhere to go.** A critter boxed in by sleepers and the
wall can find no clear spot. Then the move that caused the overlap must
not happen:
- **When the cause is the leashed dog,** that segment of the drag is
  undone. The leashed dog stays at the segment's start, and the rest of
  the tick's drag is ignored: the dog is **blocked**, and the page shows
  it stopped short of the pointer.
- **No other critter can cause this.** Every other step already stops at
  contact with anyone above it.
- **So a blocked drag is the only escape hatch,** and the report says
  when it happens (`blocked`, below).

**The server checks the invariant on its own.** Before it compares lines,
it checks every tick's end board for overlaps among the awake critters
and against their sleeping neighbours. An overlap refutes the report even
if the page's replay agreed with the server's. That catches a bug in the
clearing step itself, which a re-run of the same code would repeat
faithfully.

**The park on load.** If the kept positions break the invariant (today's
park can), the server resolves it once, before the first tick: in rank
order, each critter clears the ones above it by the same rule, everyone
treated as awake. It logs what moved, and the page gets the resolved
board from `/tiles` as usual.

**Cost.** Each check looks only at neighbours within about 100 px, found
through the tiles; a handful per critter per tick.

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

**The subscribed tiles become an input to the physics**, and the
mechanism for them already exists: `/tiles`, the page sending the whole
set, each tile new or held, the server answering with the critters in
the new ones. Nothing about that changes. What the physics adds is
*when* a set applies, since `/tiles` and the reports are separate
requests that could arrive in either order:
- **Each `/tiles` request carries a version,** counting up; the server
  keeps the current one.
- **A new set takes effect at a tick boundary, after the server acks
  it.** The page ticks under the old set until the answer comes, then
  switches from its next tick.
- **The report's header names the version** its ticks used. If that is
  not the server's current one, the server answers `differ` with its
  board, and the page catches up.

One player and one window, so nothing disagrees. Two windows of
different sizes on one park would each be right about their own physics.
That only matters when there are two players.

**Any unleashing puts the park to sleep:** a release, or the leash's 5 s
after the player lets go running out. Every critter stops where it is, and the
page stops ticking until the next leash.

## The report

One report per round trip, as moves are sent today: everything since the
last tick the server kept. For now it says a lot. It names every critter
that moved, where it was and where it went, **in the order the cascade
moved them**, so the report is the calculation written out and the server
checks it line by line.

```
dogpark 1 physics 1
from 1040 tiles 7 wall 1791936000000
leash 219
t 1041 +0 drag d80.00,1216.00@3 d7f.00,1216.00@19 d7d.00,1217.00@36
 dog 219 d80.00,1216.00 > d7d.00,1217.00
 cow 23 d1c.33,120e.1a > d1c.33,1210.1a
 dog 4 a10.00,1180.80 > a0f.f0,1180.80
 dog 220 d41.40,1204.00 > d41.35,1203.f5
t 1042 +63
 dog 4 a0f.f0,1180.80 > a0f.e0,1180.80
 dog 220 d41.35,1203.f5 > d41.2a,1203.ea
t 1043..1060 +125
rest 1060
```

| line | says |
|---|---|
| `dogpark 1 physics 1` | the language's version and the physics' version. A mismatch means "reload", nothing else |
| `from T tiles V wall W` | the tick the report starts after (the last one the server kept); the version of the subscribed tiles (as last acked by `/tiles`) its ticks used, the other half of who is awake; and the wall clock (Unix ms) at its first tick, data only |
| `leash D`, `release D` | the human's leash: leashing wakes the park around D, releasing (or the 5 s running out) puts it to sleep |
| `t T +ms` | tick T begins, `+ms` after `wall` (data only). `drag` and its points, when the human dragged during it: the leashed dog's path in whole pixels, written as positions, each with `@ms` from the tick's start (data only) |
| `blocked T x,y` | the leashed dog's drag stopped at x,y in tick T: going on would have put a critter with nowhere to go under it (above) |
| `dog N a > b`, `cow N a > b` | a critter that moved during tick T, from a to b, in cascade order: the leashed dog, then cows by number, then dogs by number. A cow's line is its net move over the tick's drag segments, since cows react to each segment. A critter not listed did not move |
| `t A..B +ms` | ticks A to B in which nothing moved: the human still, every awake dog content. Only possible once the board has settled, so it marks the stretch before `rest` |
| `rest T` | after tick T every awake dog rests: the page stops ticking until the next drag |

**Why before-and-after, and not a hash.** A hash says *whether* page and
server agree. Lines say *where they first don't*: the tick, the critter,
and which coordinate. The before positions repeat what the previous line
already implies. That redundancy is the point: each line is checkable on
its own, and reads as a diff of the board. Once the physics is trusted,
dropping the before positions, or going to a hash every few ticks, is a
small change to the language. Its version number is there for that.

**The size.** While dogs are moving, a tick is maybe 5 to 20 lines of
about 30 bytes. At 16 ticks a second and a report every few hundred
milliseconds, that's a few KB a report. Dog Park's body limit (4 KiB)
goes up to about 64 KiB; metal's body rule is built for that.

**The server's answers:**

```
kept 1060
```
```
kept 1041
differ 1042 dog 220 d41.35,1203.f5 > d41.2a,1203.eb
board 1042 dog 4 a0f.e0,1180.80 dog 220 d41.2a,1203.eb dog 219 d7d.00,1217.00 cow 23 d1c.33,1210.1a …
```
```
reload physics 2
```

- **`kept T`:** checked, written to the game's log on disk, and safe.
- **`differ T`:** the first line the server's re-run disagreed with, with
  the server's own version of it, then the server's `board` at that tick:
  every awake critter. Everything before tick T is kept. The page
  rewinds to the board and replays its own ticks from there.
- **`reload`:** the page's physics is not the server's. Reload and resume
  from the last kept tick.

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

Every few seconds the server also writes a snapshot of the whole board.
A restart then loads the last snapshot and replays the log after it,
which is exactly the re-run the server does for every report anyway. If
the log grows too big to keep, it is the first thing to trim: the
snapshots alone are enough to resume.

## Decisions (Steve, 2026-10-13)

1. **Alphas never yield.** A herd jammed against an alpha stays jammed;
   that's a puzzle for the player.
2. **Awake:** in a subscribed tile *and* within 500 px of the leashed dog.
   Subscriptions stay with `/tiles`, which gains a version; a report names
   the version its ticks used.
3. **The anchor:** the nearest more-alpha dog of the breed. As people
   follow the person right in front of them, not the one at the head of
   the line.
4. **Cows push unleashed dogs.** They ignore them, and a dog a cow lands
   on gets out from under it at once.
5. **The numbers** are guesses, to tune by playing; Steve will suggest tools
   for tuning and debugging.
6. **Any unleashing puts the park to sleep,** including the leash's 5 s
   running out.

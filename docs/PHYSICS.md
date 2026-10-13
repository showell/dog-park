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
and drop did, and firms up once the picture does. Revised 2026-10-13
after a cold review (its findings are folded in below).

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
  Unleashing puts the whole park to sleep. When every awake dog rests,
  the page stops ticking and sends nothing.
- **The report is text,** one line per tick with the human's input, then
  every critter that moved, before and after, in the order the cascade
  moved them: a proof the server checks line by line. The server answers
  `kept`, `differ` (naming the first line it disagrees with), or `reload`.
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
in internal steps of at most 10 px. In each step:
1. **the cows react first,** by the grid rule, to the step the leashed dog
   is about to take;
2. **then the leashed dog takes it,** swept against where everyone now is,
   stopping **just short** of pressing into anyone (each coordinate
   rounded toward where it started, so "just short" never overlaps by a
   256th) or into the world's edge, which stops it dead with no sliding.

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

The world's edge stops the dog without ending the drag.

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
anchors, strangers or room-makers; a sleeper is just an obstacle (below),
so the page never needs critters further than a tile from the leashed
dog.

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
   critter** (above or below it, awake or asleep): a dog's own step never
   lands it on anyone. Only the cows ever push.

The dead zone is there because opposing wishes (an anchor on one side, a
stranger on the other) can overshoot each other: without it, a dog at
the balance point flips 1/256 of a pixel each way, every tick, for ever.
How it feels is for play to decide; stepping half the total is the other
cure.

**Resting.** A tick **rests** when nothing moved in it and the human did
nothing: then the next tick, a pure function of the same board and no
input, would move nothing either. It's a fixed point, so the page stops
ticking altogether: no reports, no work for the server, until the next
drag. A jammed herd rests too, wishes and all; leashing an outer dog
wakes it.

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

Every distance is under 500 px, so nothing reaches further than a tile's
width.

**Arithmetic.** Every critter's position is an integer count of 256ths of
a pixel, the cows' too (they are in halves today), with an integer
square root for distances. Squared distances in 256ths reach about 10^12,
so they are 64-bit. The cows' grid rule takes whole pixels today: it
needs a real port to 256ths, not a change of units. The cows taught us that page and server agree
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

**The rules, one per kind of mover:**
- **The leashed dog** stops just short of pressing into anyone, swept
  along each step of the drag, and the drag ends (above). It never
  overlaps anyone.
- **A dog's own step** (its wishes) stops where it would press into any
  critter, above or below it, awake or asleep.
- **A cow's grid step** is swept too, per internal step: it stops just
  short of the leashed dog, any sleeper (sleeping dogs aren't pushed) and
  any cow above it.
- **A cow's pushes are decided as one set,** against the cow's square at
  the end of its step: every awake dog and lower cow under it needs a
  spot clear of everyone and outside the area the cow swept. If every
  one of them has such a spot, they all jump there, at once. If any has
  none, the cow stops just short of the first one it would have pressed
  into, and **pushes no one**. So no critter moves for a push that didn't
  happen.

**What this aims at:** only a cow can make an overlap, and each is
undone on the spot, by the jumps or by the cow stopping short. If an
overlap slips through anyway (a case nobody thought of), the page doesn't
fall over:
- **it draws the critters as they are;**
- **the lower-ranked one gets out from under** at its next turn, by the
  same jump;
- **the server notes it** in the log as a finding. It does not refute the
  report: the page and the server agreed, and the bug is in the rule,
  which play will show us.

**The nearest spot clear of everyone, deterministically.** It is the
closest position, by straight-line distance, that overlaps no critter and
stays in the world, chosen from a finite list of candidates:
- **The ways out** of every critter within reach (one square's width past
  the pushed critter's own), pressed against each side of each: not only
  the square it is under, so a spot just past a third square is found.
- **The corners** where two such ways meet.

**Neighbours are always taken in rank order,** whatever order they arrived
in (the page's tiles fill in arrival order; the server's don't). Every
candidate is checked against every critter in reach and the world's
edge, and the nearest valid one wins. Ties are broken by rank of the
neighbour that made the candidate, then by side (east, south, west,
north, with corners after sides). The search
stays within that reach, so it is local and cheap; finding none is
"nowhere to go".

**The server checks the invariant on its own,** after every tick, among
the awake critters and against their sleeping neighbours, and logs any
overlap with the tick and the pair: a finding, not a refutation (above).
That catches a bug in the rule itself, which a re-run of the same code
would repeat faithfully.

**The park on load.** If the kept positions break the invariant (today's
park can), the server resolves it once, before the first tick: in rank
order (cows, then dogs, by number), each critter that overlaps one
above it jumps to the nearest spot clear of everyone, everyone treated as
awake. It logs what moved and keeps the result. If some
critter has nowhere to go, the server does not start, and says which
(fail, never warn). The page gets the resolved board on load.

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

**The subscribed tiles become an input to the physics, so they travel
with the reports.**
- **When it changes:** a page's subscriptions change only when the leashed
  dog moves (and the view follows) or the screen is resized. Either way,
  the change is part of the game's history.
- **How it's sent:** inside the next report, at the tick it takes effect,
  with the viewport's size: a `view` line (below). There is no separate
  request.
- **What the server sends back:** the critters in any newly subscribed
  tiles, with its ack.
- **What's logged:** the server applies the set from that tick in its
  re-run, and keeps it in the game's log with the ticks, so a restart's
  replay wakes the same critters.
- **Only tiles the page already held count.** A tick's awake set and its
  obstacles come only from tiles the page held at the report's `from`:
  a tile subscribed during the report wakes nothing until its critters
  have arrived with an ack. So the page never ticks with critters it
  hasn't seen.
- **The page's promise:** it subscribes every tile within 700 px of the
  leashed dog: the 500 px reach, plus the farthest a push's jump can
  land (about 100 px), plus the most a tick's drag may move it (below).
  The server knows the viewport, so it can hold the page to that.
- **A tick's drag moves the leashed dog at most 100 px.** A faster flick
  is cut at 100 px for that tick (the drag is held to a stricter rule,
  as allowed above).

A report may carry no ticks at all: a resize, or panning while nothing is
leashed, is just a `view` line.

One player and one window, so nothing disagrees. Two windows of
different sizes on one park would each be right about their own physics.
That only matters when there are two players.

**Unleashing puts the park to sleep.** The leash comes off when the human
grabs another dog, or **80 ticks (5 s)** after the drag last ended
(the human let go, or a bump ended it) with no new drag. While those 80
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
leash 219 1041
view 1041 1280x800 6,8 7,8 8,8 6,9 7,9 8,9
t 1041 +0 drag -1.00,0@3 -2.00,+1.00@19
 dog 219 d80.00,1216.00 > d7d.00,1217.00
 cow 23 d1c.33,120e.1a > d1c.33,1210.1a
 dog 4 a10.00,1180.80 > a0f.f0,1180.80
 dog 220 d41.40,1204.00 > d41.35,1203.f5
t 1042 +63
 dog 4 a0f.f0,1180.80 > a0f.e0,1180.80
 dog 220 d41.35,1203.f5 > d41.2a,1203.ea
t 1043 +125
rest 1043
```

| line | says |
|---|---|
| `dogpark 1 physics H page E` | the language's version; the physics' version, a hash of the physics' sources built into both the wasm and the server, so a forgotten bump can't cause endless disagreement; and this page load's epoch, which the server issued |
| `from T wall W` | the tick the report starts after (the last one the server kept), and the wall clock (Unix ms) at its first tick, data only |
| `leash D T` | the human leashed dog D at tick T: the park wakes around it |
| `letgo T` | the drag ended at tick T because the human let go: the 80 ticks start |
| `bump T N` | the drag ended at tick T because the leashed dog pressed into critter N: the 80 ticks start, the leash stays |
| `release D T` | the leash came off dog D at tick T (the 80 ticks ran out, or another dog was grabbed): the park sleeps |
| `view T WxH c,r …` | from the start of tick T (before that tick's awake set is worked out), the viewport's size and the subscribed tiles: the other half of who is awake, logged with the ticks |
| `t T +ms` | tick T begins, `+ms` after `wall` (data only). `drag` and its displacements in 256ths, when the human dragged during it, each with `@ms` from the tick's start (data only); at most 16 a tick (the page adds up any more) |
| `dog N a > b`, `cow N a > b` | a critter that moved during tick T, from a to b, in cascade order: the leashed dog, then cows by number, then dogs by number. A cow's line is its net move over the tick's drag segments, since cows react to each segment. A critter not listed did not move |
| `rest T` | tick T moved nothing, the human did nothing, and no let-go timer is running: a fixed point, so the page stops ticking until the next drag. Tick numbers carry on across a rest |

**Why before-and-after, and not a hash.** A hash says *whether* page and
server agree. Lines say *where they first don't*: the tick, the critter,
and which coordinate. The before positions repeat what the previous line
already implies. That redundancy is the point: each line is checkable on
its own, and reads as a diff of the board. Once the physics is trusted,
dropping the before positions, or going to a hash every few ticks, is a
small change to the language. Its version number is there for that.

**The size, and the window.** While dogs are moving, a tick is maybe 5 to
20 lines of about 30 bytes. The page runs at most **N = 32 ticks** (2 s)
past the last kept tick, so a report holds at most 32 ticks, a few KB
usually and well under Dog Park's new body limit of 64 KiB (from 4 KiB;
metal's body rule is built for that). A `board` holds only the awake
critters, so it is bounded the same way.

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

- **`kept T`:** checked, and written to the game's log and synced to disk
  before the answer goes: safe.
- **`differ T`:** the first line the server's re-run disagreed with, with
  the server's own version of it, then the server's `board` at that tick:
  every awake critter, and everything else a rewind needs: who is
  leashed, whether a drag is on or since which tick it ended (for the 80
  ticks), and the current view. Everything before tick T is kept. The page
  rewinds to the board and replays its own ticks from there.
- **`reload`:** the page's physics is not the server's, or three `differ`s
  came in a row (a circuit breaker: something is wrong that rewinding
  won't fix). Reload and resume from the last kept tick.
- **`taken over`:** a newer page load (another tab, a reload) holds the
  park now; this page stops. The server answers only the newest epoch.
  A report whose `from` isn't the last kept tick (a duplicate, or one
  sent before a reload) gets `differ` from the last kept tick, with the
  board.

**Loading the page** gets the board, the last kept tick and a new epoch
in one answer, so a reloaded page knows where to start.

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

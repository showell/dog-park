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
- **No two critters ever share space** (below).
- **A herd may jam.** Jammed dogs stay jammed while awake; the player
  frees them by leashing an outer dog, and that's part of the game.
- **The leashed dog never flies over anyone.** Unlike a card in Lyn Rummy,
  it can't be carried over a herd: at the first contact during a drag it
  stops, and it pops off the leash.

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
- **No two critters ever share space.** The leashed dog stops at the
  first contact and pops off the leash; a dog's own step stops at
  contact; only a cow lands on anyone, and whatever it lands on jumps
  clear at once, or the cow stops short.

## The cascade, and why it settles

**The drag is a displacement,** in 256ths: how far the pointer moved, added
to where the leashed dog actually is. A dog leashed at d41.35 stays there
when picked up.

**A collision ends the drag, before any physics.** The leashed dog moves
along each displacement until its square would touch another critter's
(any critter, awake or asleep) or the world's edge, and stops just short:
the contact is swept along the whole displacement, so no drag, however
fast, carries it over or through anyone. Touching another critter
**releases the leash** at that tick: the pointer's capture is let go, the
dog pops out, and, as with any unleashing, the park sleeps. (A shake or
some such in the page comes later; for v1 the point is that the physics
never has to deal with a leashed dog on top of anything.) The world's
edge only stops it.

Splitting a drag into short steps waits until a demonstration shows it
helps; the cows' grid rule already plays a long move in short ticks of
its own.

Within a tick, in this order:

1. **For each displacement of the drag:**
   - **The leashed dog** moves along it, as above. Physics never moves it
     otherwise.
   - **The cows** react, as they do today: the grid rule, the leashed
     dog's move scaring the cows ahead of it. Cows ignore the other dogs,
     and push them (below).
2. **Then, once per tick, every awake dog, by number, smallest first,**
   takes its own step (its wishes). Each sees the positions of everything
   above it *as already moved this tick*: the leashed dog's new place, the
   cows' new places, and the more-alpha dogs' new places. Its wishes look
   only at those.

So the cows react to every displacement of a drag and the dogs' own
wishes run once a tick.

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
   per tick, whichever is less, and **stops at contact with any critter**
   (above or below it, awake or asleep): a dog's own step never lands it
   on anyone. Only the leashed dog and the cows ever push.

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

Every distance is under 500 px, so the invariant holds: nothing reaches
further than a tile's width.

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
- **The leashed dog** stops just short of the first contact, swept along
  the drag, and the leash lets go (above). It never overlaps anyone.
- **A dog's own step** (its wishes) stops at contact with any critter,
  above or below it, awake or asleep. It never overlaps anyone either.
- **A cow's grid step** stops at contact with the leashed dog, sleepers
  and any cow above it. It may land on a dog or on a cow below it: those
  are the pushes.
- **A pushed critter jumps at once,** during the cow's step, to the
  **nearest spot clear of everyone**: any rank, awake or asleep, and in
  the world. Its jump lands on no one.
- **If it has nowhere to go,** the cow's step stops at contact with it
  instead: the push doesn't happen.

**Why that's enough.** Only a cow's step can make an overlap, and each one
is undone on the spot, by the jump or by the cow stopping short. So the
invariant holds **after every move**, not just at the end of a tick, and
the argument needs no induction over ranks and no undoing of drags.

**The nearest spot clear of everyone, deterministically.** It is the
closest position, by straight-line distance, that overlaps no critter and
stays in the world, chosen from a finite list of candidates:
- **The ways out** of every critter within reach (one square's width past
  the pushed critter's own), pressed against each side of each: not only
  the square it is under, so a spot just past a third square is found.
- **The corners** where two such ways meet.

Neighbours are taken in rank order, every candidate is checked against
every critter in reach and the world's edge, and the nearest valid one
wins. Ties go in a fixed order: east, south, west, north. The search
stays within that reach, so it is local and cheap; finding none is
"nowhere to go".

**The server checks the invariant on its own.** Before it compares lines,
it checks every tick's end board for overlaps among the awake critters
and against their sleeping neighbours. An overlap refutes the report even
if the page's replay agreed with the server's. That catches a bug in the
clearing step itself, which a re-run of the same code would repeat
faithfully.

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
- **The page's promise:** it subscribes every tile within 560 px of the
  leashed dog (a tile's width, plus a cow's half). The server knows the
  viewport, so it can hold the page to that. Then every critter that can
  touch an awake one is known to the page, sleepers included.

A report may carry no ticks at all: a resize, or panning while nothing is
leashed, is just a `view` line.

One player and one window, so nothing disagrees. Two windows of
different sizes on one park would each be right about their own physics.
That only matters when there are two players.

**Any unleashing puts the park to sleep:** a release, or the leash's 5 s
after the player lets go running out. Those 5 s are **80 ticks**, counted
in ticks, so the release lands on the same tick on both sides, and
`release` names it. Every critter stops where it is, and the
page stops ticking until the next leash.

## The report

One report per round trip, as moves are sent today: everything since the
last tick the server kept. For now it says a lot. It names every critter
that moved, where it was and where it went, **in the order the cascade
moved them**, so the report is the calculation written out and the server
checks it line by line.

```
dogpark 1 physics 5e0c91a2 page 3
from 1040 wall 1791936000000
leash 219
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
| `leash D`, `release D T why` | the human's leash: leashing wakes the park around D; a release at tick T puts it to sleep. Why: `hand` (the human let go and the 80 ticks ran out, or grabbed another dog), or `bump N` (the leashed dog touched critter N during the drag and popped out) |
| `view T WxH c,r …` | from tick T, the viewport's size and the subscribed tiles: the other half of who is awake, logged with the ticks |
| `t T +ms` | tick T begins, `+ms` after `wall` (data only). `drag` and its displacements in 256ths, when the human dragged during it, each with `@ms` from the tick's start (data only); at most 16 a tick (the page adds up any more) |
| `dog N a > b`, `cow N a > b` | a critter that moved during tick T, from a to b, in cascade order: the leashed dog, then cows by number, then dogs by number. A cow's line is its net move over the tick's drag segments, since cows react to each segment. A critter not listed did not move |
| `rest T` | tick T moved nothing and the human did nothing: a fixed point, so the page stops ticking until the next drag |

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
  every awake critter. Everything before tick T is kept. The page
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
8. **A collision pops the leashed dog off the leash.** It can't be dragged
   over or through anyone; the drag stops at the first contact, upstream
   of the cascade, and the park sleeps. A shake in the page comes later.
9. **Splitting drags into steps** waits for a demonstration that it helps.
10. **A 1 px dead zone** against jitter, to start.

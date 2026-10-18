# Why the Roc walk costs what it does

**Status: measured 2026-10-18** (the Roc nightly of that date, Zig 0.16,
an Intel Xeon at 2.1 GHz). The walk (`roc/Walk.roc`, with the wish in it,
`roc/Wish.roc`) against the Zig walk it replaced, then kept as the tests'
shim (`zigWalk` and `zigWishOf`, gone from `src/play/physics.zig` since:
commit `203318b` has them). The measure is the
busiest spot's full drag, 20 ticks (`zig build physics-bench -- busiest`):
4000 walks, 192,000 critters visited, 4.7 million wishes' worth of moving
critters looked at. Instructions are callgrind's (an `-Dcpu=x86_64_v2`
build); time is the best of nine runs, native.

| | instructions | time |
|---|---|---|
| the Zig walk, Zig wish | 1.10 G | 105 ms |
| the Zig walk, Roc wish (the shape before the walk moved) | 1.60 G | 135-147 ms |
| the Roc walk as first committed (`e7ac200`) | 2.06 G | 222 ms |
| the Roc walk now | 1.40 G | 144 ms |

Every row walks the same critters to the same places: the shim checked it
pixel-tick by pixel-tick in the tests, and the 14,800 lines of
`physics-bench -- lines` are the same bytes in all of them.

## Where the first cut lost, and what fixed it

Each found by counting what kind of instruction ran where (callgrind's
per-instruction counts against the disassembly), not by guessing.

1. **The export order (17%, with nothing else changed).** The app
   provided both `roc_wish` and `roc_walk`; `roc fmt` sorts the app's
   exports, and with `walk` first the shared wish was compiled into both
   less well: 2.06 G against 1.76 G. The walk is now the only export (the
   shim's walk took the Zig wish), and the order cannot matter.
2. **Atomic refcounts (about a third of the time).** Roc counts references
   atomically (`lock incq`, `lock decq`, some 20 cycles each) for anything
   the host can see, which is every list the physics lends, and there is
   no switch. They cost time without costing many instructions, which is
   why the time was worse than the instruction count said. The first cut
   ran 5.8 million of them, 30 a critter visited; now 0.8 million. They
   come from a list held in two places at once:
   - a field read out of a record that is still alive (`$w.park.crits`
     while `$w` is used after): counted up, then down when the record is
     rebuilt. Each list now has a variable of its own, and every record a
     function hands back is taken apart at once
     (`{ cells: c2, crits: k2 } = step_around(...)`);
   - a list passed to a function that only reads it while the caller keeps
     it (`gather(s, park, ...)`, then `park` used again): Roc took no
     borrow there, so it counted up before the call and down after. Such a
     function now takes the list and hands it back with its answer, so it
     goes through each in turn and is never held twice.
3. **The wish's records and calls (about 300 M instructions).** The wish
   carried the anchor and the nearest as whole records round its loop,
   picked each critter's rule as a tag, and called `contrib` with records
   for every critter in motion; the closure that made each critter's
   record was a call too. LLVM kept all of it on the stack: 172
   instructions a critter, against the Zig's 56. Now the wish is a fold
   (`Wish.start`, `add`, `finish`) over a record of numbers only, each rule
   is numbers (`Flat`), and the walk calls `add` from its own loop: about
   40 instructions a critter in the common case.
4. **Inlining that comes and goes.** A function called from one place is
   inlined; from three, it may not be, and the whole loop around it then
   spills. The ring's cells (`line_up`) are walked by one loop with one
   body, `dx` stepping across a side row, not three calls.

## What is left (1.40 G against 1.10 G, 144 ms against 105)

- **`List.set` is a call** (about 75 M): every write to a list goes
  through a builtin that is not inlined and copies the element with
  `memmove`, about 90 instructions where the Zig writes one word. The walk
  writes some 200 times a walk (a critter visited, a key lowered, a move).
- **Spills** (about 150 M more than the Zig's): loops carrying more values
  than there are registers, the line-up's ring above all; the Zig's
  comptime-known sizes (the cells' words, the critter count) are run-time
  numbers in Roc.
- **The waiting critter**, found by a scan of every critter for each one
  visited (about 70 M), where the Zig keeps them in order as it offers
  them.
- **Checked arithmetic and bounds**: Roc checks every add and every list
  read, as the ReleaseSafe Zig does; the counts are close.

The line-up is cheaper in Roc than in the Zig (532 M against 643 M), and
the step, the veto, the nudge and the shove, is level with it.

## Rules for fast Roc here

- One owner for a list at a time: no field of a live record, no list read
  by a function while its caller keeps it; thread it through and back.
- Numbers, not records or tags, round a hot loop; read a record again
  after the loop rather than carry it.
- A hot helper called from one place only.
- Every constant a constant (`World.roc`'s geometry), never a run-time
  argument: a division by a constant is a multiply.
- Measure after `roc fmt`: what it reorders can change the code.

# Why the Roc walk costs what it does

The walk (`roc/Walk.roc`, with the wish in it, `roc/Wish.roc`) is the
physics' hot path, run natively on the server and as wasm on the page. It
costs about 1.4 times a plain Zig walk's natively. What drives the cost,
found by counting instructions (callgrind's per-instruction counts against
the disassembly), not by guessing, and the rules that keep it down. `zig
build physics-bench -- busiest` is the measure; `-- lines` must stay the
same bytes through any speed-up.

## What costs

- **Atomic refcounts.** Roc counts references atomically (`lock incq`,
  `lock decq`, some 20 cycles each) for anything the host can see, which
  is every list the physics lends, and there is no switch. They cost time
  without costing many instructions. They come from a list held in two
  places at once:
  - a field read out of a record that is still alive (`$w.park.crits`
    while `$w` is used after): counted up, then down when the record is
    rebuilt;
  - a list passed to a function that only reads it while the caller keeps
    it: Roc takes no borrow there, so it counts up before the call and
    down after.

  A list held twice is also a list Roc may copy, and a copy of a lent list
  is a crash: the physics' `roc_alloc` panics (`src/play/roc_physics.zig`).
- **Records and tags round a loop.** LLVM keeps them on the stack. The
  wish is therefore a fold (`Wish.start`, `add`, `finish`) over a record of
  numbers only, each rule is numbers (`Flat`), and the walk calls `add`
  from its own loop.
- **Inlining that comes and goes.** A function called from one place is
  inlined; from three, it may not be, and the whole loop around it then
  spills. The ring's cells (`line_up`) are walked by one loop with one
  body.
- **The export order.** `roc fmt` sorts an app's exports, and the order
  can change how shared code is compiled; the walk is the physics' only
  export.
- **What is left:** `List.set` is a builtin call that copies the element
  with `memmove`, where the Zig writes one word; loops carrying more values
  than there are registers spill (the line-up's ring above all), as
  sizes the Zig knows at compile time are run-time numbers in Roc; the
  waiting critter is found by a scan; and Roc checks every add and list
  read, as ReleaseSafe Zig does.

## Rules for fast Roc here

- One owner for a list at a time: no field of a live record, no list read
  by a function while its caller keeps it; thread it through and back
  (`{ cells: c2, crits: k2 } = step_around(...)`), and take apart every
  record a function hands back at once.
- Numbers, not records or tags, round a hot loop; read a record again
  after the loop rather than carry it.
- A hot helper called from one place only.
- Every constant a constant (`World.roc`'s geometry), never a run-time
  argument: a division by a constant is a multiply.
- Measure after `roc fmt`: what it reorders can change the code.

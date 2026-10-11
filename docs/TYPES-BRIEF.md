# The brief: Dog Park's data types, and nothing else yet

*From the box to CC, 2026-10-11, at Steve's direction. metal-vmm QUEUE item
160. Report in metal-vmm's FEEDBACK.md as usual.*

## What Dog Park is

A finite 2D park, sparsely populated with dogs, originally placed on a
lattice 100 px apart. A dog is an emoji, drawn about 40 px. Each human owns
exactly one dog, and its position is persisted. Signing up is frictionless:
each device gets an implicit identity through a signed cookie. A human
drags their own dog. Dragging to an edge of the screen auto-scrolls the
viewport. A drag is optimistic in the browser, and snaps back if the server
fails it.

Every request for a frame says where the human's viewport is in the park,
and the dx/dy of their dog's move. The server keeps every dog in a spatial
index (a quadtree or similar) and answers only the dogs near the viewport,
with enough margin that some scrolling is local. Later, an SSE stream will
show Alice Bob's dog moving; that comes after the Alice-only version works.
The UI is plain JavaScript.

## Your job: the TYPES, correct by construction

Write Dog Park's data types in Zig 0.16 under `src/`, one module per
concept, each named in `src/dog_park.zig`. The goal is that the types make
wrong programs hard to write and impossible states unrepresentable.

**Steve's rules:**
1. **Avoid bools, nulls (optionals), voids and tuples.** Prefer enums,
   tagged unions and records with named fields. "No move" and "a move" are
   two cases of a union, not an optional; "accepted" and "refused" are an
   enum or a union with the reason, not a bool. When you think an optional
   or a bool really is right, say why in one line beside it.
2. **Names over comments.** A dog park is simple to understand. Don't
   explain x, y, width, height or what a dog is. Spend the words on names,
   and comment only what a name can't carry.
3. **FRAMES OF REFERENCE ARE THE POINT.** Every coordinate says which frame
   it is in, by its type, so mixing them does not compile. At least:
   - **the park** (absolute, the whole world);
   - **the viewport** (relative to what the human sees, its top-left);
   - **relative to a dog**, the human's own (a drag's dx/dy is this: a
     displacement, not a position).

   Positions and displacements are different types too (a point minus a
   point is a displacement; a point plus a point means nothing). Decide
   whether browser pixels and park units are the same scale; if they are,
   say so once, and still keep the frames distinct. Earlier Claude versions
   wrote clumsy and buggy code when they got frames of reference wrong:
   this is where the types earn their keep.
4. **Be restrained about algorithmic code and glue.** No quadtree
   implementation, no physics, no routes, no server, no JSON handling, no
   persistence code. The box assembles those from your types. What does
   belong: the few one-line operations that DEFINE a type's meaning (the
   conversion between two frames; a point plus a displacement), each with a
   test.
5. **Use your own sub-agents as adversaries.** Have them try to write a bug
   the types allow: a viewport coordinate passed where a park one is meant,
   a dog with no owner, a frame request that is both "no move" and a move,
   two dogs for one human. Each attack that works becomes a type change.
   Each use case they demonstrate becomes a small unit test, and we will
   likely keep those tests.

## The checklist of types to draft

Not exhaustive, and the names here are placeholders; choose better ones.

- [ ] **The frames:** a point in the park, in the viewport, and relative to
      a dog; a displacement; the conversions between frames, given what
      they need (a viewport's origin in the park, a dog's position).
- [ ] **The park:** its size; its bounds; the lattice (the spacing, a spot
      on it, a spot's point in the park); what "inside the park" means for
      a point (an enum or a union, not a bool).
- [ ] **Humans and identity:** a human (the device's implicit identity), its
      id, and the relationship "owns exactly one dog".
- [ ] **Dogs:** a dog's id, its owner, its position, its look (the emoji:
      an enum of breeds, not a string); a dog as the population holds it.
- [ ] **The population:** what the spatial index is asked and what it
      answers (a rectangle of the park in, the dogs in it out), as types and
      a declared interface only: no implementation.
- [ ] **A frame request:** the viewport (in the park), and the move (none,
      or a displacement relative to the dog).
- [ ] **A frame to render:** the region it covers (the viewport and its
      margin, in the park), the dogs in it (in which frame? decide, and
      make it the type's), which dog is the human's own, and the park's
      size.
- [ ] **Outcomes and their reasons:** a move accepted (where the dog is
      now, clamped to the park or not: say which, by type) or refused (and
      why); a new human placed (on which lattice spot) or not (and why, such
      as a full park).
- [ ] **What is persisted:** a dog's record as the store keeps it.
- [ ] **The wire:** what crosses to the browser, as records whose field
      names say their frame (so the JavaScript reading them can't guess
      wrong either).

## Where, and when it's done

- Repository: `github.com/showell/dog-park`, on your branch
  `claude/great-wright-i7aste` as usual. No dependency on angry-gopher yet:
  types only.
- **Done when** `zig build test` passes, every type in the checklist has a
  draft or a stated reason it isn't one, the adversaries' attacks and what
  changed because of them are listed in your FEEDBACK entry, and you
  report the open questions you want Steve or the box to settle.

# Amendment: the park wraps around (Steve, 2026-10-11)

*To QUEUE 161 and both briefs. Where this says otherwise, this wins.*

**Pac-Man wrapping.** A dog that moves past the park's east edge comes in
at its west edge, and the same for north and south. To the human it
feels like an infinitely tiled lattice: they never perceive an edge. They
can scroll forever in any direction, and the dogs near the seam are drawn
on its far side as well, so nothing pops in or out.

## What it does to the frames

The park becomes a torus, and that adds a frame:

- **The park** (as now): a dog's canonical position, from (0, 0) up to the
  park's size. `InParkPoint` is a point of this frame, and a dog only
  ever stands on one.
- **The plane, new:** the infinite plane the park tiles. Its origin is the
  park's (0, 0), and the copy of the park one tile east starts at
  (width, 0). **The viewport lives here,** because a viewport can straddle
  a seam, or sit any number of tiles away from where the human started.
  So do the points a scene draws dogs at: the copy of a dog nearest the
  viewport.
- **The viewport and the own dog:** as now. The viewport's origin is a
  plane point.

The conversions, each a type's own one-liner, each tested:
- **plane → park** wraps (floored modulo, by the park's size);
- **park → plane, near a plane point** chooses the copy of a park point
  closest to a given plane point;
- **viewport ↔ plane** is today's viewport conversion, over plane points.

**One scale still:** a displacement is the same in every frame. Adding one
to a park point gives a plane point. Wrapping it gives the park point a dog
moves to.

## What it does to the types (milestone 0, before the index)

- **`Park.wrap(plane point) → InParkPoint` replaces `clamp`** for moves.
  `Clamped` and `Clamping` go if nothing else needs them. **`MoveOutcome.moved`
  carries the `InParkPoint`,** and the wire's `clamped` outcome goes.
- **`Park.of` refuses a size that isn't a multiple of `lattice_spacing`,**
  so the lattice is seamless across the wrap. The 5,000 × 5,000 park is
  fine.
- **The scene covers a plane rectangle:** the viewport and its margin, in
  the plane. **The scene's dogs are plane points,** every copy of a dog that
  falls in the covered rectangle. A screen wider than the park sees a dog
  twice, as an infinite tiling should.
- **The index is still asked about park rectangles.** A pure function cuts
  a plane rectangle into at most four park rectangles, each with the tile
  offset that carries its dogs back into the plane, and the scene asks the
  index once per piece. Test the seam: a viewport across the east edge, the
  north edge, and a corner.
- **The wire:**
  - The request's viewport origin is a plane point. The browser keeps it
    near the park, wrapping its own origin into (0, 0) to the park's size
    as it scrolls. The server refuses one far outside that, as it now
    refuses one far off the park.
  - The answer's dogs are plane points (`plane_x`, `plane_y`).
  - The answer's own dog is its plane point, the copy nearest the viewport.
- **A stored record** still holds a park point, and one outside the park
  still stops the load.
- **Placement's "free within half a spacing" wraps** too: a dog just across
  the seam is near the spot.

## What it does to the browser (milestone 7)

- **There is no edge to clamp the scroll at.** Auto-scroll goes on forever,
  and the viewport's origin wraps back into the park's range as it goes,
  continuously, so nothing on screen jumps.
- **A drag moves the dog in the plane;** the server answers its wrapped
  park point. The browser draws the copy nearest the viewport, so a dog
  dragged across the east edge keeps going east on screen.
- **The blitter is unchanged:** it draws what it is given, at viewport
  points.

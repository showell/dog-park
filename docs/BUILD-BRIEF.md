# The brief: Dog Park, Alice alone, end to end

*From the box to CC, 2026-10-11, at Steve's direction. metal-vmm QUEUE item
161. Builds on your types (QUEUE 160, merged to `main` with the box's nits:
plain arithmetic that panics on overflow, the five dog emoji, little-endian
asserted). Report in metal-vmm's FEEDBACK.md as usual.*

**The goal:** a human opens the page, gets a dog on the lattice, drags it
around the park with auto-scroll, and the dog is where they left it after a
reload. One human at a time is enough: **no SSE yet**; Bob's dog moving
comes after this works.

**The spirit:** structured, not vibe-coded. Pure functions over your types
first, each with its tests; the glue last and thin. Seven milestones below,
**each its own commit**, each passing `zig build test`, and each attacked by
one of your sub-agents before you start the next (an attack that works
becomes a test and a fix). Names over comments, as before; frames of
reference by type, as before.

## The answers to your open questions

1. **The numbers** stand as placeholders: margin 200, longest drag 2000,
   lattice 100 with the first spot half a spacing in, widest viewport
   10,000, longest side 1<<20. Pick a park of 5,000 × 5,000 for now.
2. **A drag past the edge is clamped, not refused**, as you have it. The
   browser puts the dog at `own`.
3. **No "placed just now" in the scene.** The first scene already shows the
   dog; there is nothing more to say.
4. **Little-endian:** done, asserted.
5. **A stored dog outside the park** stops the server at load, naming the
   record (fail, never warn). The park doesn't shrink; if it ever does,
   that's a deliberate migration.
6. **Saturating arithmetic:** gone. Plain arithmetic, so an overflow is a
   panic, since your checks make one a bug.
7. **The emoji on the wire:** yes.

## The milestones

**1. The index.** A quadtree (or a simpler grid, if you can argue it) that
implements `population.Population`.
- **The oracle:** your `ListPopulation`. A seeded random test runs the same
  operations (put, move, lookup, near over random rectangles, the asker
  excepted) on both and requires the same answers. Sort `near`'s results
  for the comparison; the contract doesn't promise an order.
- **Bounded memory:** its capacity is a parameter, and `refused_full` past
  it.

**2. Placement.** A pure function: the park, the population, a new human →
`outcomes.Placement`.
- **Which spot:** the first free lattice spot in a spiral out from the
  park's centre, so the first humans see each other. "Free" means no dog
  within half a spacing of the spot.
- **Tests:** the centre first, the spiral's order, a taken spot skipped,
  a full park refused.

**3. The world.** The park, the population, and the store under them, with
webbox (`../angry-gopher/zig-server`, module `webbox`; the dependency and a
test that reaches it are on `main`).
- **Ids:** a new human's id comes from `webbox.counter` at
  `data/next-human`.
- **Records:** each dog is one file, `data/dogs/<human id>`, holding its
  `StoredDog` bytes, written with `webbox.store.replace`.
- **When it's written:** on every accepted move, for now. That's fine on
  Linux; the box revisits it for metal.
- **Loading:** every record into the index at start. A record that doesn't
  read stops the start, naming it.
- **Tests:** under a temporary folder. Place, move, then a fresh load sees
  the same dogs.

**4. The scene.** A pure function: the world, a known human, a
`scene.SceneRequest` → a `scene.SceneAnswer`, plus what changed (the dog to
write, if it moved).
- **For a human with no dog:** place one first.
- **The decision:** `outcomes.decide`.
- **The others:** `population.near` with the asker excepted.
- **Tests:** a stay, a drag, a clamped drag, a too-far drag, a scene's
  others all inside what it covers, and the own dog never among them.

**5. The application.** `src/app.zig` is a `webbox.site.Site(App)` with a
small route table:
- `GET /`: the page, with its script named by its bytes
  (`webbox.http.scriptTag`);
- `GET /park.js`: `webbox.http.serveEmbedded`;
- `POST /scene`: `wire.WireSceneRequest` in as JSON, `wire.WireAnswer` out
  as JSON. A body over a small cap is a 413, through webbox's `http`.

The rest of the application:
- **Identity:** `webbox.signed_cookie`. Its own `Cookie` is named
  `dogpark_human`, with label `"dogpark_human\n"`, a year's lifetime, and
  digits only, canonical (no leading zero). A request with none is a
  `humans.Visitor.new_device`: the scene's answer carries the new cookie,
  issued with `signed_cookie.issue`. A known human is renewed when due
  (`signed_cookie.renew`).
- **The secret:** `App.setup` creates it the first time
  (`webbox.site_secret.create` when `load` finds none), and says so in its
  start report. Dog Park's droplet is its own, so the frictionless choice
  is the right one.
- **The JSON:** each wire record crosses with `std.json`, and the tags are
  the names your wire types already chose.
- **Tests:** webbox's route tests show how: a canned request through
  `Site(App).route`, the response read back.

**6. The Linux main.** `src/main.zig`:
`webbox.linux_host.Server(site).run` with the name `dog-park`, the variables
`DOGPARK_PORT`, `DOGPARK_BIND`, `DOGPARK_CONFIG`, `DOGPARK_TRUSTED_PROXY`
and `DOGPARK_KEEPALIVE_MS`, the default port 9101, and its report.
- A `zig build run` step.
- **One smoke check,** `ops/smoke`: start it on a side port with a
  temporary config, `GET /`, `POST /scene` twice (the second with the cookie
  the first set), check the JSON, stop it. Seconds, not minutes.

**7. The browser.** Plain JavaScript, no bundler, embedded like any asset.
Structured by the same names as the Zig, in sections:
- **frames:** park ↔ viewport conversions, named as `frames.zig` names
  them. Every variable says its frame (`parkX`, `viewportX`, `ownDogDx`),
  so no number is used in the wrong one.
- **wire:** fetch a scene; the request and the answer exactly as
  `wire.zig` has them.
- **state:** the current viewport (in the park), the last scene, and the
  own dog's optimistic position.
- **drag:** pointer events to a displacement in the own-dog frame. About
  every 80 ms while dragging, send the accumulated displacement. On the
  answer: `moved` keeps it; `clamped` puts the dog at `own`; a refusal or a
  failed request snaps the dog back to the last answer.
- **scroll:** a drag within about 40 px of a screen edge scrolls the
  viewport that way, clamped at the park's edge. Within the scene's covered
  region nothing is asked; near its edge, a new scene.
- **the blitter:** like the safari screensaver's blitter in spirit, written
  fresh, not copied. It **owns no logic**: given a list of
  `{viewportX, viewportY, emoji}`, it clears a canvas and draws each emoji
  at about 40 px, the own dog marked with a ring. Device-pixel-ratio aware.
  Every decision about what to draw, and where, is made before it is
  called.

## Restraint, still

- **No SSE, no admin, no accounts beyond the device cookie, no styling
  beyond a plain page.** Each is a later step.
- **Glue stays thin:** a handler reads the request, calls the pure
  function, writes the answer.
- **Gates stay small:** `zig build test` and `ops/smoke`. No gopher-metal,
  no metal-vmm, no coverage catalog.

## Done when

- Each milestone is a commit that passes `zig build test`, and `ops/smoke`
  passes at the end.
- **Your FEEDBACK says:**
  - each milestone's adversary attacks and what came of them;
  - what you decided that the brief left open;
  - what the box should look at first;
  - how to run it and see a dog (`zig build run`, then a browser at
    `localhost:9101`).
- **If the sibling layout isn't there in your environment**
  (`../angry-gopher` beside `dog-park`), say so at once, rather than
  vendoring webbox.

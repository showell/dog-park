# Amendment: the dogs are fixed; a human claims one (Steve, 2026-10-11)

*QUEUE item 164. Where this says otherwise, this wins over the earlier
briefs.*

**The park has a finite number of dogs, and that number never changes.**
Dogs are made once, when the park's data is first created, and none is ever
created or destroyed after. A human doesn't bring a dog: when they arrive,
they **claim** one and drag it from then on.

## The rules

- **One dog per device, ever.** A human (a device's cookie) holds at most
  one claim, and a dog has at most one claimant.
- **A new human claims an unclaimed dog**: the one nearest the park's
  centre (wrapped distance; ties broken by a fixed order, so it's
  deterministic). The first humans then see each other, as before.
- **When every dog is claimed, the newcomer takes the least recently
  touched dog.** Its previous human loses it, along with its position (it
  keeps where it stands; it just changes hands). Steve: "if I don't log in
  for a couple weeks, I can lose my dog's position. There aren't any real
  stakes there yet."
- **Touched** means the claimant asked for a scene (a move or a stay), not
  only a move: a human who looks but doesn't drag still holds their dog.
- **A human whose dog was taken** finds no claim on their next request and
  claims again, by the same rule, as a new human would. Their id and
  cookie stay.
- **Not yet:** one human's dog on several devices. Each device is its own
  human, as now.

## The numbers (placeholders, like the others)

- **How many dogs:** 400 in the 5,000 × 5,000 park, on lattice spots. The
  park stays sparse: 400 of the 2,500 spots.
- **Where they start:** spots and breeds from a seeded shuffle, made once
  with the data. The seed and the count are named constants, and a test
  pins the first few dogs.

## What it does to the types

- **A dog has its own id again:** `DogId`, `0 ..< dog_count`, fixed. The
  population is keyed by dog, not by owner.
- **The claim is a union, not an optional:** `unclaimed`, or
  `claimed { by: HumanId, touched: <time> }`. Choose the time's type and
  frame (unix seconds is fine) and say so.
- **The human-to-dog direction** is an index the world keeps beside the
  dogs, derived from the claims at load, never stored twice.
- **Placement becomes claiming:** a pure function from the dogs and their
  claims (and the time) to `Claiming { unclaimed: DogId, taken_over: {
  dog, from: HumanId } }`. There is no "park full": with at least one dog,
  a claim always succeeds. `Park.of`, or the world's creation, refuses a
  park with zero dogs or more dogs than lattice spots.
- **The scene** draws claimed and unclaimed dogs alike. The own dog is the
  asker's claim.

## What it does to persistence

- **Each dog is still one file**, now `data/dogs/<dog id>`: where it stands,
  its breed, its claim. A record outside the park, or a claim naming a
  human at or past `next-human`, still stops the load, naming the file.
  Two dogs claimed by one human stops it too.
- **The dogs are created when `data/dogs/` is empty and `next-human` is
  missing**, together: a fresh park. Any other partial state stops the
  load rather than guessing.
- **Touching must not write on every idle request.** A move writes the dog,
  as now. A stay updates `touched` in memory and writes it at most once an
  hour per dog. Losing up to an hour of "touched" in a crash is fine.
- **Fold in 163's part 5** (a restored `data/` handing out live ids): with
  claims on disk, say whether the data generation is still needed, and do
  it here if so.

## What it does to the browser

Nothing it can see, except that a dog it lost shows up as somebody else's.
The answer's own dog is always present, because a request always ends with
the asker holding a claim.

## Open, for CC to decide and report

- When a newcomer takes over a dog, its old human isn't told. A later "you
  lost your dog" message is a browser nicety, not this item's.
- **Cookie-less requests now churn claims:** a curl loop with no cookie
  claims a dog per request, and once all 400 are claimed it takes over the
  least recently touched dog, real humans' included. Cheap defense: a new
  device's claim is kept only once a request comes back with its cookie
  (until then the dog shows as theirs, but its claim isn't written and
  doesn't evict anyone). Do that unless it fights the design, and say
  which you did.

## Done when

Each step is a commit with its tests, attacked by a sub-agent as before.
`zig build test` and `ops/smoke` pass. FEEDBACK lists the attacks, what you
decided, and the numbers.

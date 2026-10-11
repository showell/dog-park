# Amendment: random humans, provisional claims, and sometimes no dog (Steve, 2026-10-11)

*QUEUE item 168. Where this says otherwise, this wins over FIXED-DOGS.md.
The fixed dogs stay: 400 of them, made once, never created or destroyed.*

## Humans are random

**A human's id is 128 random bits**, made when a device first arrives, from
the OS's random source. There is no counter: `auth/next-human`,
`World.reserveThrough` and the "a claim past the counter" refusal all go.
A first visit costs no disk write. A restored `data/` or `auth/` can no
longer hand out a live id, because nothing hands ids out in order.

## A claim is provisional until the dog is dragged

- **A new human is given a dog** (the free one nearest the centre, as now),
  and nobody else is given it while their claim stands.
- **The claim is provisional** until the human drags that dog. Its first
  drag makes the claim held, and that dog is theirs for good.
- **A provisional claim expires 120 seconds after it was made** if the dog
  hasn't been dragged. The dog is free again, where it stands.
- **A provisional claim lives in memory only.** A restart forgets it, and
  the human is given a dog again on their next request.
- **A held claim never expires in v1.** The stalest-claim takeover goes,
  and so do `touched` and its hourly writes. A stay writes nothing.
- **A human whose provisional claim expired** is given a dog again on
  their next request, if one is free (maybe the same one).

The claim is a union, not flags: `unclaimed`, `provisional { by, until }`,
`held { by }`. Expiry is decided by a pure function of the claim and the
time, tested at 119 s and 120 s side by side.

## Sometimes there's no dog

When no dog is free, a human is given none. **The answer says so by type:**
the scene's own dog is `has_dog { ... }` or `no_dog_free`. Nothing is a
refusal: the scene still comes back, with the other dogs.

**The browser shows the park read-only:** no ringed dog and nothing to
drag. The human can still look around: dragging the background pans the
viewport, wrapping as now. Keep asking for scenes at the idle pace. When a
later answer has a dog, the page centres on it and becomes draggable.

## What this replaces

- From FIXED-DOGS.md: `touched`, the stalest-claim takeover, and "a first
  visit's claim is shown, not kept" (a provisional claim is the same idea,
  made exact).
- From CC's 164: the counter beside the secret, and `reserveThrough`.

## Known and accepted for v1

A client that keeps its cookies can hold one dog per cookie, provisionally,
for 120 s at a time, so a script could keep every dog provisional and every
real newcomer read-only. Nothing is at stake yet. A per-address limit is
the later cure, behind the trusted proxy.

## Done when

Each step is a commit with its tests, attacked by a sub-agent as before.
`zig build test` and `ops/smoke` pass, and the node check covers the
read-only page and its switch to a dog. FEEDBACK lists the attacks and what
you decided.

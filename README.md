# Dog Park

Everybody owns a dog and drags it around a park. There is no object of the
game yet: you leash a dog and drag it, the cows ahead of it scoot aside,
and the other dogs keep their distance or follow (its own breed).

It is a small web application built on `webbox`, the web-server-in-a-box
library ([zig-webbox](https://github.com/showell/zig-webbox), a sibling
checkout at `../zig-webbox`).
It is meant to be the thing a person reads to make their own game: the
park, its routes, its page and its JavaScript are here, and everything that
serves them is the library's.

**Where it runs:** on its own droplet, with its own data. It shares only
the domain and the Caddy in front with lynrummy.com. Developed on Linux;
also built as a zig-metal-unikernel kernel (`zig build dogpark` there),
which that repo's tier 3 judges against the Linux build. Not deployed.

**Status (2026-10-13):** played by Steve, and tuned by playing. The page
(`solo/`) runs the physics (`src/play/physics*.zig`, compiled to wasm) and
reports every tick to the server, which re-runs it and keeps it
([docs/PHYSICS.md](docs/PHYSICS.md)). The server (`src/play/`) speaks
`GET /`, the page's scripts, `GET /physics-<hash>.wasm`, `POST /load` and
`POST /report`; nothing else. Every load starts the park afresh, in its
first layout. The first version's briefs (`docs/*-BRIEF.md` and the
amendments) are history: that app is retired.

    zig build play       # serve on localhost:9103, from the checkout

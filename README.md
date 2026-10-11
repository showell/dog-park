# Dog Park

Everybody owns a dog and drags it around a park. There is no object of the
game yet: you move your dog, and you see the other dogs move.

It is a small web application built on `webbox`, the web-server-in-a-box
library that lives in angry-gopher's server (`../angry-gopher/zig-server`).
It is meant to be the thing a person reads to make their own game: the
park, its routes, its page and its JavaScript are here, and everything that
serves them is the library's.

**Where it runs:** on its own droplet, with its own data and accounts. It
shares only the domain and the Caddy in front with lynrummy.com. Developed
on Linux first; on bare metal later, through gopher-metal.

**Status (2026-10-11):** the data types are drafted, one module a concept
under `src/` ([docs/TYPES-BRIEF.md](docs/TYPES-BRIEF.md)); the first
end-to-end version, one human at a time, is being built
([docs/BUILD-BRIEF.md](docs/BUILD-BRIEF.md)). Nothing serves yet.

    zig build test

## THE PHYSICS' PLATFORM: Dog Park's Zig is the host. The app
## (roc/physics.roc) provides the tick's whole drag (Walk.roc's
## `drag_tick`: its pixel-ticks, each the leashed dog's step and then the
## walk, the critters' wish Wish.roc in it), or the forage turn alone, by
## its first argument, as the C function `roc_walk`;
## every build of the physics builds it into an archive for its target
## (build.zig's `rocArchives`), which the Zig links. It allocates nothing, nor calls
## anything of the host's but `roc_crashed`. The walk's arguments are flat,
## each a scalar or a list, so the C function's are what the Zig declares
## (src/play/roc_physics.zig).
platform ""
	requires {
		walk : I32, I32, I32, U32, U32, List(U16), List(Poop), List(Home), List(U64), List(Crit), List(U16), List(U16), List(U16), List(Disp), List(Poop) -> Walked
	}
	exposes []
	packages {}
	provides { "roc_walk": walk_for_host }
	targets: {
		x64musl: {
			inputs: [app],
			output: Archive,
		},
		wasm32: {
			inputs: [app],
			output: Archive,
		},
		x64v1elf: {
			inputs: [app],
			output: Archive,
		},
	}

## The types that cross to the host, each as src/play/roc_physics.zig lays
## it out: a listed poop, a chicken's home, a seen critter, a displacement
## of the drag, and what a call hands back.
Poop : { slot : U16, x : I32, y : I32 }

Disp : { dx : I32, dy : I32 }

Home : { x : I32, y : I32 }

Crit : { half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }

Walked : {
	before : U32,
	bump_at : I32,
	bump_kind : I32,
	cells : List(U64),
	crits : List(Crit),
	depth : List(U16),
	eaten : List(U16),
	from : List(U16),
	moving : List(U16),
	placed : List(Poop),
	poops : List(Poop),
}

walk_for_host : I32, I32, I32, U32, U32, List(U16), List(Poop), List(Home), List(U64), List(Crit), List(U16), List(U16), List(U16), List(Disp), List(Poop) -> Walked
walk_for_host = walk

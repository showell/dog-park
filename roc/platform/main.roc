## THE PHYSICS' PLATFORM: Dog Park's Zig is the host. The app
## (roc/physics.roc) provides one pixel-tick (Walk.roc's `pixel_tick`: the
## leashed dog's step, then the walk, the critters' wish Wish.roc in it)
## as the C function `roc_walk`; `zig build roc` builds it
## into an archive for each of the physics' targets (roc/lib/), which the
## Zig links. It allocates nothing, nor calls anything of the host's but
## `roc_crashed`. The walk's arguments are flat, each a
## scalar or a list, so the C function's are what the Zig declares
## (src/play/roc_physics.zig).
platform ""
	requires {
		walk : I32, I32, I32, U32, U32, List(U16), List({ slot : U16, x : I32, y : I32 }), List(U64), List({ cell : U16, half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }), List(U16), List(U16) -> { anchor : I32, bump_at : I32, bump_kind : I32, cells : List(U64), crits : List({ cell : U16, half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }), depth : List(U16), moving : List(U16), poop_slot : I32, poop_x : I32, poop_y : I32, pooper : I32, step_x : I32, step_y : I32, walked : I32 }
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
		x64elf: {
			inputs: [app],
			output: Archive,
		},
	}

walk_for_host : I32, I32, I32, U32, U32, List(U16), List({ slot : U16, x : I32, y : I32 }), List(U64), List({ cell : U16, half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }), List(U16), List(U16) -> { anchor : I32, bump_at : I32, bump_kind : I32, cells : List(U64), crits : List({ cell : U16, half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }), depth : List(U16), moving : List(U16), poop_slot : I32, poop_x : I32, poop_y : I32, pooper : I32, step_x : I32, step_y : I32, walked : I32 }
walk_for_host = |axis, inc, side, before, laid, from, poops, cells, crits, depth, moving| walk(axis, inc, side, before, laid, from, poops, cells, crits, depth, moving)

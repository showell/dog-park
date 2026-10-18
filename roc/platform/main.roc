## THE PHYSICS' PLATFORM: Dog Park's Zig is the host. The app
## (roc/physics.roc) provides the critters' wish (Wish.roc) and the walk
## (Walk.roc) as the C functions `roc_wish` and `roc_walk`; `zig build
## roc` builds them into an archive for each of the physics' targets
## (roc/lib/), which the Zig links. Neither allocates, nor calls anything
## of the host's but `roc_crashed`. The walk's arguments are flat, each a
## scalar or a list, so the C function's are what the Zig declares
## (src/play/roc_physics.zig).
platform ""
	requires {
		walk : I32, I32, List(U16), List({ slot : U16, x : I32, y : I32 }), List(U64), List({ cell : U16, half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }), List(U16), List(U16) -> { anchor : I32, cells : List(U64), crits : List({ cell : U16, half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }), depth : List(U16), moving : List(U16), pooper : I32 },
		wish : { half : I32, kind : U8 }, List({ ax : I32, ay : I32, half : I32, tx : I32, ty : I32, j : U16, kin : Bool, kind : U8 }) -> { anchor : I32, x : I32, y : I32 }
	}
	exposes []
	packages {}
	provides { "roc_walk": walk_for_host, "roc_wish": wish_for_host }
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

wish_for_host : { half : I32, kind : U8 }, List({ ax : I32, ay : I32, half : I32, tx : I32, ty : I32, j : U16, kin : Bool, kind : U8 }) -> { anchor : I32, x : I32, y : I32 }
wish_for_host = |me, near| wish(me, near)

walk_for_host : I32, I32, List(U16), List({ slot : U16, x : I32, y : I32 }), List(U64), List({ cell : U16, half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }), List(U16), List(U16) -> { anchor : I32, cells : List(U64), crits : List({ cell : U16, half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }), depth : List(U16), moving : List(U16), pooper : I32 }
walk_for_host = |most, side, from, poops, cells, crits, depth, moving| walk(most, side, from, poops, cells, crits, depth, moving)

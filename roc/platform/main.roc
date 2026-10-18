## THE PHYSICS' PLATFORM: Dog Park's Zig is the host. The app
## (roc/physics.roc) provides the critters' wish (Wish.roc) as the C
## function `roc_wish`; `zig build roc` builds it into an archive for each
## of the physics' targets (roc/lib/), which the Zig links. The wish
## allocates nothing and calls nothing of the host's but `roc_crashed`.
platform ""
	requires {
		wish : { half : I32, kind : U8 }, List({ ax : I32, ay : I32, half : I32, tx : I32, ty : I32, j : U16, kin : Bool, kind : U8 }) -> { anchor : I32, x : I32, y : I32 }
	}
	exposes []
	packages {}
	provides { "roc_wish": wish_for_host }
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

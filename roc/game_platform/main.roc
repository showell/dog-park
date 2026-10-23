## THE GAME'S TICK AS A C FUNCTION: Dog Park's Zig is the host. The app
## (roc/game.roc) provides Game.roc's whole tick as `roc_game_tick`, its
## board laid flat, each argument a scalar or a list (src/play/roc_game.zig
## declares the same). Unlike the walk's platform it allocates, through the
## host's allocator (roc_physics.zig's `roc_allocator`). The game judge
## (`zig build game-judge`) builds it for the bench, and runs it beside the
## Zig's every tick.
platform ""
	requires {
		game_tick : U64, U64, U64, U64, U64, U64, U64, List(Crit), List(Pt), List(U32), List(Poop), List(HumanIn), List(Disp) -> Ticked
	}
	exposes []
	packages {}
	provides { "roc_game_tick": game_tick_for_host }
	targets: {
		x64musl: {
			inputs: [app],
			output: Archive,
		},
	}

## The types that cross to the host, each as src/play/roc_game.zig lays it
## out: a critter, a point, a poop, a displacement, an input, and what a
## tick hands back. Every scalar the tick hands back is a U64, so its
## record is laid out by name.
Crit : { half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }

Pt : { x : I32, y : I32 }

Poop : { slot : U16, x : I32, y : I32 }

Disp : { dx : I32, dy : I32 }

HumanIn : { dog : U64, kind : U64 }

Ticked : {
	bump_kind : U64,
	crits : List(Crit),
	drag_at : U64,
	drag_kind : U64,
	hold_dog : U64,
	hold_kind : U64,
	laid : U64,
	poops : List(Poop),
	walked : List(U32),
}

game_tick_for_host : U64, U64, U64, U64, U64, U64, U64, List(Crit), List(Pt), List(U32), List(Poop), List(HumanIn), List(Disp) -> Ticked
game_tick_for_host = game_tick

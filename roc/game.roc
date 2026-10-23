## GAME.ROC'S TICK, as the app the Zig links for the game judge
## (roc/game_platform/main.roc): its arguments made a board and inputs, its
## result laid flat.
##
## - `level`: World.levels' index; `t`: the board's last tick;
## - `hold_kind` 0 free, 1 leashed, `hold_dog` the leashed dog's index in
##   `crits`; `drag_kind` 0 on, 1 ended at tick `drag_at`;
## - `laid`: the poops the park has laid;
## - an input's `kind`: 0 release, 1 leash (each of `dog`), 2 grab, 3 let go;
## - a bump's kind, back: 0 none, 1 a critter, 2 a poop.
app [game_tick] { pf: platform "./game_platform/main.roc" }

import Game
import Walk
import World

game_tick = |level, t, hold_kind, hold_dog, drag_kind, drag_at, laid, crits, homes, walked, poops, humans, disps| {
	lv = match World.levels.get(level) {
		Ok(l) => l
		Err(_) => crash "game.roc: no such level"
	}
	hold = if hold_kind == 0 {
		Free
	} else {
		Leashed({ dog: hold_dog, drag: if (drag_kind == 0) On else Ended(drag_at) })
	}
	board = {
		level: lv,
		geo: Walk.geo_of((lv.world_tiles * World.cell_per_tile).to_i32_wrap()),
		crits,
		homes,
		walked,
		poops,
		laid: laid.to_u32_wrap(),
		hold,
		t,
	}
	inputs = humans.map(
		|h| {
			if h.kind == 0 {
				Release(h.dog)
			} else if h.kind == 1 {
				Leash(h.dog)
			} else if h.kind == 2 {
				Grab
			} else {
				LetGo
			}
		},
	)
	r = Game.tick(board, inputs, disps)
	after = r.board
	{ hold_kind: k, hold_dog: d, drag_kind: dk, drag_at: da } = match after.hold {
		Free => { hold_kind: 0, hold_dog: 0, drag_kind: 0, drag_at: 0 }
		Leashed({ dog, drag: On }) => { hold_kind: 1, hold_dog: dog, drag_kind: 0, drag_at: 0 }
		Leashed({ dog, drag: Ended(e) }) => { hold_kind: 1, hold_dog: dog, drag_kind: 1, drag_at: e }
	}
	{
		bump_kind: match r.bumped {
			NoBump => 0
			Critter(_) => 1
			PoopBump => 2
		},
		crits: after.crits,
		drag_at: da,
		drag_kind: dk,
		hold_dog: d,
		hold_kind: k,
		laid: after.laid.to_u64(),
		poops: after.poops,
		walked: after.walked,
	}
}

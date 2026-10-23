## THE GAME'S TICK, in Roc: a board and one tick of it, the human's inputs
## then the drag, the chickens' turn and the let-go timer, as the physics'
## Zig has them (src/play/physics.zig's `input`, `run` and `mergeAndCap`;
## docs/PHYSICS.md). Each pixel-tick is the walk's own (Walk.roc's
## `pixel_tick`, the walk and the wish in it), lent the critters as the
## Zig lends them: the leashed dog first, then the kinds by rank, each in
## kind-number order, keyed as the walk starts; the poops by tile, each in
## slot order. roc/native.roc plays it; nothing judges it against the Zig yet.
import Layout
import Walk
import World

Game := [].{

	## The physics' clock and its bounds (physics.zig): 16 ticks a second; a
	## tick's drag at most 100 px on each axis, in at most 16 displacements;
	## the leash off 20 s after a drag ends.
	ticks_per_second : U64
	ticks_per_second = 16

	let_go_ticks : U64
	let_go_ticks = 20 * 16

	cap : I32
	cap = 100 * 256

	most_displacements : U64
	most_displacements = 16

	## A leashed dog's drag: on (the pointer is down), or ended at a tick.
	Drag : [On, Ended(U64)]

	## Who is leashed (a dog, by its index in `crits`), if anyone.
	Hold : [Free, Leashed({ dog : U64, drag : Drag })]

	## **A BOARD**: the level; every critter in Layout's order, its home (where
	## a forager goes back to) and how far it has walked; the poops on the
	## park; how many the park has laid (the next takes slot `laid` mod the
	## slots); who is held; the last tick played.
	Board : {
		level : World.Level,
		geo : Walk.Geo,
		crits : List(Walk.Crit),
		homes : List(Walk.Pt),
		walked : List(U32),
		poops : List(Walk.Poop),
		laid : U32,
		hold : Hold,
		t : U64,
	}

	## One of the human's inputs at a tick.
	Human : [Release(U64), Leash(U64), Grab, LetGo]

	## One displacement of a tick's drag, in 256ths.
	Disp : { dx : I32, dy : I32 }

	## What a tick's drag ran into, if anything: a critter of a kind, or a poop.
	Bumped : [NoBump, Critter(U8), PoopBump]

	Ticked : { board : Board, bumped : Bumped }

	## Who nudges whom: a dog its breed (dog n is breed n mod the breeds), a
	## herd kind its own number after the breeds, a chicken nobody.
	no_kin : U8
	no_kin = 255

	## A kind's number, as World.kinds and the walk number it.
	kind_number : Layout.Kind -> U8
	kind_number = |k| match k {
		Dog => 0
		Cow => 1
		Chicken => 2
		Goat => 3
	}

	px_of : Layout.Kind -> I64
	px_of = |k| match k {
		Dog => World.dog_px
		Cow => World.cow_px
		Chicken => World.chicken_px
		Goat => World.goat_px
	}

	## **A LEVEL AS IT STARTS**: every critter at its spot, its home, nobody
	## leashed, no poop.
	start : World.Level -> Board
	start = |lv| {
		var $crits = []
		var $dogs = 0
		for s in Layout.park(lv) {
			kin = match s.kind {
				Dog => ($dogs % World.breeds).to_u8_wrap()
				Cow => World.breeds.to_u8_wrap()
				Goat => (World.breeds + 1).to_u8_wrap()
				Chicken => no_kin
			}
			$crits = $crits.append({
				half: (px_of(s.kind) // 2 * 256).to_i32_wrap(),
				key: Walk.not_lined_up,
				kin,
				kind: kind_number(s.kind),
				x: (s.x * 256).to_i32_wrap(),
				y: (s.y * 256).to_i32_wrap(),
			})
			if s.kind == Dog {
				$dogs = $dogs + 1
			} else {
				{}
			}
		}
		{
			level: lv,
			geo: Walk.geo_of((lv.world_tiles * World.cell_per_tile).to_i32_wrap()),
			crits: $crits,
			homes: $crits.map(|c| Walk.pt(c)),
			walked: List.repeat(0, $crits.len()),
			poops: [],
			laid: 0,
			hold: Free,
			t: 0,
		}
	}

	## The leashed dog (its index in `crits`), and whether its drag is on.
	leashed : Board -> [Nobody, Dog(U64, Bool)]
	leashed = |b| match b.hold {
		Free => Nobody
		Leashed({ dog, drag }) => Dog(dog, drag == On)
	}

	## **MERGED AND CAPPED** (physics.zig's `mergeAndCap`): past 16, the
	## displacements are added into the 16th; then each axis has a 100 px
	## budget for the tick, counted on the input: a displacement that
	## crosses it has that axis cut to what is left, and that axis plays no
	## more this tick.
	merge_and_cap : List(Disp) -> List(Disp)
	merge_and_cap = |raw| {
		var $merged = []
		for d in raw {
			if $merged.len() < most_displacements {
				$merged = $merged.append(d)
			} else {
				last = get_disp($merged, most_displacements - 1)
				$merged = put($merged, most_displacements - 1, { dx: last.dx + d.dx, dy: last.dy + d.dy })
			}
		}
		var $left_x = cap
		var $left_y = cap
		var $out = []
		for d in $merged {
			x = budgeted(d.dx, $left_x)
			y = budgeted(d.dy, $left_y)
			$left_x = x.left
			$left_y = y.left
			$out = $out.append({ dx: x.v, dy: y.v })
		}
		$out
	}

	budgeted : I32, I32 -> { v : I32, left : I32 }
	budgeted = |v, left| {
		size = v.abs()
		if size <= left {
			{ v, left: left - size }
		} else {
			{ v: if (v < 0) 0 - left else left, left: 0 }
		}
	}

	## **ONE TICK** (physics.zig's `tick`): the inputs in order, then the drag
	## when one is on, the chickens' turn after it, the drag ended by a bump
	## or a let-go, and the leash off once its timer runs out. An input whose
	## precondition fails changes nothing.
	tick : Board, List(Human), List(Disp) -> Ticked
	tick = |b0, humans, disps| {
		t = b0.t + 1
		var $hold = b0.hold
		var $letting_go = Bool.False
		for h in humans {
			match h {
				Release(d) => {
					match $hold {
						Leashed(l) => {
							if l.dog == d {
								$hold = Free
								$letting_go = Bool.False
							} else {
								{}
							}
						}
						Free => {}
					}
				}
				Leash(d) => {
					if $hold == Free and d < b0.crits.len() and (get_crit(b0.crits, d)).kind == 0 {
						$hold = Leashed({ dog: d, drag: On })
						$letting_go = Bool.False
					} else {
						{}
					}
				}
				Grab => {
					match $hold {
						Leashed(l) => {
							$hold = Leashed({ dog: l.dog, drag: On })
							$letting_go = Bool.False
						}
						Free => {}
					}
				}
				LetGo => {
					match $hold {
						Leashed(l) => {
							if l.drag == On {
								$letting_go = Bool.True
							} else {
								{}
							}
						}
						Free => {}
					}
				}
			}
		}
		b1 = { ..b0, hold: $hold, t }
		{ board: b2, bumped } = match $hold {
			Leashed({ dog, drag: On }) => {
				dragged = drag_all(b1, dog, merge_and_cap(disps))
				{ board: chickens_turn(dragged.board, dog, get_crit(b1.crits, dog)), bumped: dragged.bumped }
			}
			_ => { board: b1, bumped: NoBump }
		}
		ended = match b2.hold {
			Leashed({ dog, drag: On }) => {
				if bumped != NoBump or $letting_go {
					{ ..b2, hold: Leashed({ dog, drag: Ended(t) }) }
				} else {
					b2
				}
			}
			_ => b2
		}
		released = match ended.hold {
			Leashed({ dog: _, drag: Ended(e) }) => {
				if t >= e + let_go_ticks {
					{ ..ended, hold: Free }
				} else {
					ended
				}
			}
			_ => ended
		}
		{ board: released, bumped }
	}

	## The critters in the order the walk takes them (physics.zig's `Scene`):
	## the leashed dog, then each kind by rank (cows, dogs, chickens, goats),
	## each in kind-number order.
	seen_order : List(Walk.Crit), U64 -> List(U64)
	seen_order = |crits, dog| {
		var $order = [dog]
		for k in [1, 0, 2, 3] {
			var $i = 0
			for c in crits {
				if c.kind == k and $i != dog {
					$order = $order.append($i)
				} else {
					{}
				}
				$i = $i + 1
			}
		}
		$order
	}

	## The critters lent to the walk in its order, keyed as it starts (the
	## leashed dog visited), and filed into the cells.
	park_of : Board, List(U64) -> Walk.Park
	park_of = |b, order| {
		seen = order.map(
			|j| {
				c = get_crit(b.crits, j)
				{ ..c, key: if (j == get_u64(order, 0)) Walk.visited else Walk.not_lined_up }
			},
		)
		words = (seen.len() + 63) // 64
		cells = List.repeat(0, (b.geo.side * b.geo.side).to_u64_wrap() * words)
		Walk.filed(b.geo, { cells, crits: seen })
	}

	## The walk's critters, back in `crits` order.
	put_back : Board, List(U64), List(Walk.Crit) -> Board
	put_back = |b, order, moved| {
		var $crits = b.crits
		var $k = 0
		for j in order {
			$crits = put($crits, j, get_crit(moved, $k))
			$k = $k + 1
		}
		{ ..b, crits: $crits }
	}

	## **THE DRAG** (physics.zig's `playDrag`): each displacement, x then y,
	## cut into pixel-ticks of at most a pixel (the `i`th of `n` to
	## `part * i / n`, toward zero), each a `pixel_tick`, until one bumps.
	drag_all : Board, U64, List(Disp) -> Ticked
	drag_all = |b0, dog, disps| {
		var $b = b0
		var $bumped = NoBump
		for d in disps {
			var $axis = 0
			while $axis < 2 and $bumped == NoBump {
				part = (if ($axis == 0) d.dx else d.dy).to_i64()
				n = ((if (part < 0) 0 - part else part) + 255) // 256
				var $done = 0
				var $i = 1
				while $i <= n and $bumped == NoBump {
					now = part * $i // n
					inc = (now - $done).to_i32_wrap()
					$done = now
					if inc != 0 {
						r = pixel_tick($b, dog, $axis, inc)
						$b = r.board
						$bumped = r.bumped
					} else {
						{}
					}
					$i = $i + 1
				}
				$axis = $axis + 1
			}
		}
		{ board: $b, bumped: $bumped }
	}

	## **ONE PIXEL-TICK**: the walk's (Walk.roc's `pixel_tick`); then the
	## leashed dog's walked count (its 32 bits stop at their top), the poop it
	## laid in its slot (`laid` mod the slots, wrapping), and what it bumped.
	pixel_tick : Board, U64, I32, I32 -> Ticked
	pixel_tick = |b, dog, axis, inc| {
		order = seen_order(b.crits, dog)
		park = park_of(b, order)
		n = park.crits.len()
		before = get_u32(b.walked, dog)
		r = Walk.pixel_tick(lend_poops(b), { depth: List.repeat(0, n), moving: [], park }, axis, inc, before, b.laid)
		moved = put_back(b, order, r.walk.work.park.crits)
		sum = before.to_u64() + r.walked.to_u64_wrap()
		walked = put(b.walked, dog, if (sum > 4294967295) 4294967295 else sum.to_u32_wrap())
		laid_one = r.poop.slot >= 0
		poops = if laid_one {
			slot = r.poop.slot.to_u16_wrap()
			b.poops.keep_if(|q| q.slot != slot).append({ slot, x: r.poop.x, y: r.poop.y })
		} else {
			b.poops
		}
		bumped = if r.bump.kind == Walk.bump_critter {
			Critter((get_crit(park.crits, r.bump.at.to_u64_wrap())).kind)
		} else if r.bump.kind == Walk.bump_poop {
			PoopBump
		} else {
			NoBump
		}
		{ board: { ..moved, walked, poops, laid: if (laid_one) b.laid.plus_wrap(1) else b.laid }, bumped }
	}

	## **THE CHICKENS' TURN** (physics.zig's `chickensTurn`, Walk.roc's
	## `forage_turn`): once a tick, after the drag, only if the leashed dog's
	## net move over it is more than nothing; the poops they ate come off.
	chickens_turn : Board, U64, Walk.Crit -> Board
	chickens_turn = |b, dog, was| {
		net = Walk.measure(Walk.delta(b.geo, Walk.pt(was), Walk.pt(get_crit(b.crits, dog))))
		if net == 0 {
			b
		} else {
			order = seen_order(b.crits, dog)
			park = park_of(b, order)
			homes = order.map(|j| get_pt(b.homes, j))
			t = Walk.forage_turn(lend_poops(b), park, homes, [], net, b.laid)
			moved = put_back(b, order, t.park.crits)
			{ ..moved, poops: moved.poops.keep_if(|p| !t.eaten.contains(p.slot)) }
		}
	}

	## The poops by tile, as the walk reads them: tile `t`'s at
	## `poops[from[t] .. from[t + 1]]`, row by row from the world's (0, 0),
	## each tile's in slot order (physics.zig's `lendPoops`).
	lend_poops : Board -> Walk.Lent
	lend_poops = |b| {
		tiles_n = (b.geo.tiles * b.geo.tiles).to_u64_wrap()
		var $from = []
		var $out = []
		var $t = 0
		while $t < tiles_n {
			$from = $from.append($out.len().to_u16_wrap())
			var $here = []
			for p in b.poops {
				if tile_of(b.geo, p) == $t {
					$here = $here.append(p)
				} else {
					{}
				}
			}
			$out = $out.concat(by_slot($here))
			$t = $t + 1
		}
		{ from: $from.append($out.len().to_u16_wrap()), poops: $out, side: b.geo.side }
	}

	tile_of : Walk.Geo, Walk.Poop -> U64
	tile_of = |g, p| ((p.y // Walk.tile) * g.tiles + p.x // Walk.tile).to_u64_wrap()

	## A few poops in slot order (an insertion sort: a tile holds a handful).
	by_slot : List(Walk.Poop) -> List(Walk.Poop)
	by_slot = |ps| {
		var $out = []
		for p in ps {
			var $before = []
			var $after = []
			for q in $out {
				if q.slot < p.slot {
					$before = $before.append(q)
				} else {
					$after = $after.append(q)
				}
			}
			$out = $before.append(p).concat($after)
		}
		$out
	}

	## **THE HERD** the page scores (solo/scene.js's `largestHerd`): cows
	## linked when their centres are at most two cow-widths apart on the
	## larger axis, round the torus, and through others; the largest group.
	largest_herd : Board -> U64
	largest_herd = |b| {
		cows = b.crits.keep_if(|c| c.kind == 1)
		link = (2 * World.cow_px * 256).to_i32_wrap()
		n = cows.len()
		var $group = List.repeat(0, n).map_with_index(|_, i| i)
		var $changed = Bool.True
		while $changed {
			$changed = Bool.False
			var $i = 0
			while $i < n {
				var $j = $i + 1
				while $j < n {
					near = Walk.measure(Walk.delta(b.geo, Walk.pt(get_crit(cows, $i)), Walk.pt(get_crit(cows, $j)))) <= link
					gi = get_u64($group, $i)
					gj = get_u64($group, $j)
					if near and gi != gj {
						low = if (gi < gj) gi else gj
						$group = put(put($group, $i, low), $j, low)
						$changed = Bool.True
					} else {
						{}
					}
					$j = $j + 1
				}
				$i = $i + 1
			}
		}
		var $most = 0
		for g in $group {
			here = $group.keep_if(|h| h == g).len()
			if here > $most {
				$most = here
			} else {
				{}
			}
		}
		$most
	}

	cows : Board -> U64
	cows = |b| b.crits.keep_if(|c| c.kind == 1).len()

	## **A WIN**: every cow the level lays out in one herd.
	won : Board -> Bool
	won = |b| cows(b) > 0 and largest_herd(b) == cows(b)

	get_crit : List(Walk.Crit), U64 -> Walk.Crit
	get_crit = |l, j| match l.get(j) {
		Ok(c) => c
		Err(_) => crash "Game: no critter there"
	}

	get_pt : List(Walk.Pt), U64 -> Walk.Pt
	get_pt = |l, j| match l.get(j) {
		Ok(p) => p
		Err(_) => crash "Game: no home there"
	}

	get_u64 : List(U64), U64 -> U64
	get_u64 = |l, j| match l.get(j) {
		Ok(v) => v
		Err(_) => crash "Game: no index there"
	}

	get_u32 : List(U32), U64 -> U32
	get_u32 = |l, j| match l.get(j) {
		Ok(v) => v
		Err(_) => crash "Game: no count there"
	}

	get_disp : List(Disp), U64 -> Disp
	get_disp = |l, j| match l.get(j) {
		Ok(v) => v
		Err(_) => crash "Game: no displacement there"
	}

	put : List(a), U64, a -> List(a)
	put = |l, j, v| match l.set(j, v) {
		Ok(m) => m
		Err(_) => crash "Game: no slot there"
	}
}

expect Game.start(World.level_one).crits.len() == 18
expect Game.won(Game.start(World.level_one)) == Bool.False
expect Game.largest_herd(Game.start(World.level_one)) == 1
expect Game.merge_and_cap([{ dx: 30000, dy: 0 }]) == [{ dx: 25600, dy: 0 }]
expect Game.merge_and_cap([{ dx: 20000, dy: 0 }, { dx: -10000, dy: 0 }]) == [{ dx: 20000, dy: 0 }, { dx: -5600, dy: 0 }]

## A leash, then a drag east, moves the leashed dog; a let-go ends the drag
## and keeps the leash; 20 s of ticks later the leash is off.
expect {
	b0 = Game.start(World.level_one)
	x0 = (Game.get_crit(b0.crits, 0)).x
	r = Game.tick(b0, [Leash(0)], [{ dx: 256 * 10, dy: 0 }])
	moved = (Game.get_crit(r.board.crits, 0)).x != x0
	let_go = Game.tick(r.board, [LetGo], [])
	kept = Game.leashed(let_go.board) == Dog(0, Bool.False)
	var $b = let_go.board
	var $k = 0
	while $k < Game.let_go_ticks {
		$b = (Game.tick($b, [], [])).board
		$k = $k + 1
	}
	moved and kept and Game.leashed($b) == Nobody
}

## THE WALK (docs/PHYSICS.md, decisions 20-25, 30), in Roc: one
## pixel-tick's, after the leashed dog's step. Out from the leashed dog
## (seen index 0), shortest link first, the kinds that walk only
## (Rules.roc's `walks`: dogs, cows and goats), at most
## `walk_most`: each critter visited wishes (Wish.roc) from the critters in
## motion, steps at most its pace of the leashed dog's step, whole or not at
## all (the veto, the nudge of its kin, the shove of a chicken), or once
## more sideways round a poop or a chicken; and the herd's deepest dog is
## found, who poops.
##
## The physics' Zig hands it the tick's critters and poops as lists it
## lends (src/play/physics.zig's `walk`, through roc/physics.roc): the
## poops by tile (`Lent`), which the walk only reads; and the critters,
## what each is and where it stands, by seen index and by cell (`Park`),
## with the walk's own working lists (`Work`), which it changes in place and
## hands back. It allocates nothing. Lengths are in 256ths of a pixel; a
## length is a vector's larger axis.

import Rules
import Wish
import World

Walk := [].{

	## A point, or a vector.
	Pt : { x : I32, y : I32 }

	## Seen critter `j`: where it stands (its cell is `cell_at` of it); its
	## square's half side; its kind (0 a dog, 1 a cow, 2 a chicken); its
	## kin, who it nudges and is nudged by (a dog its breed, a cow the
	## breeds' count: every cow is kin to every cow; a chicken 255, none);
	## and its key while it waits to be visited (`not_lined_up`; `visited`,
	## or the leashed dog, which the walk starts from).
	Crit : { half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }

	## A key's two marks, as roc_physics.zig's `not_lined_up` and `visited`
	## number them.
	not_lined_up : I64
	not_lined_up = -1

	visited : I64
	visited = -2

	## A poop the physics sees, and its slot (lower slots block first).
	Poop : { slot : U16, x : I32, y : I32 }

	## The world (World.roc), in 256ths: its side, half of it, a tile's
	## side, the tiles a side, a poop's half side, and the largest critter's.
	world : I32
	world = (World.world_tiles * World.tile_px * 256).to_i32_wrap()

	half_world : I32
	half_world = world // 2

	tile : I32
	tile = (World.tile_px * 256).to_i32_wrap()

	tiles : I32
	tiles = World.world_tiles.to_i32_wrap()

	poop_half : I32
	poop_half = (World.poop_px // 2 * 256).to_i32_wrap()

	biggest_half : I32
	biggest_half = {
		var $most = 0
		for k in World.kinds {
			$most = larger($most, k.px)
		}
		($most // 2 * 256).to_i32_wrap()
	}

	larger : I64, I64 -> I64
	larger = |a, b| if (a > b) a else b

	## **THE CELLS** the critters are kept by (`Park`): a tile cut
	## `cell_per_tile` ways on each axis, so `side` cells a side of the
	## world, each `cell` a side; the physics' Zig keeps the same
	## (src/play/physics.zig's `Scene.seen_cells`), and says how many a
	## side it keeps (`Lent`), which the walk checks.
	cell_per_tile : I32
	cell_per_tile = World.cell_per_tile.to_i32_wrap()

	side : I32
	side = tiles * cell_per_tile

	cell : I32
	cell = tile // cell_per_tile

	## What the walk only reads: the poops by tile, those of tile `t` (row
	## by row from the world's (0, 0)) at `poops[from[t] .. from[t + 1]]`;
	## and how many cells a side of the world the critters are kept by.
	Lent : { from : List(U16), poops : List(Poop), side : I32 }

	## The same, with what the walk works out from it once: the words of a
	## cell's set of critters (`Park`).
	Seen : { from : List(U16), poops : List(Poop), words : U64 }

	## **THE CRITTERS** by seen index (`crits`), and by cell: `cells` holds
	## each cell's set of seen indexes, `words` 64-bit words a cell (cell
	## `c`'s at `cells[c * words ..]`, index `j` bit `j % 64` of its word
	## `j / 64`), each critter in the cell it stands in, `row * side + col`
	## from the world's (0, 0). The walk keeps both as it moves critters.
	Park : { cells : List(U64), crits : List(Crit) }

	## What the walk changes: the park; the herd's depth, by seen index, for
	## the dogs of the leashed dog's breed it visited (`depth`); and the
	## critters in motion, the leashed dog, then each visited in order
	## (`moving`, lent empty).
	Work : { depth : List(U16), moving : List(U16), park : Park }

	## The walk's result: the work, and the deepest dog of the leashed dog's
	## breed (ties to the later visited; the leashed dog, with none), and
	## its anchor (-1, none).
	Walked : { anchor : I32, pooper : I32, work : Work }

	walk_most : U64
	walk_most = Rules.limits.most.to_u64_wrap()

	## How many each visited critter lines up: three (`Three`).
	walk_fan : U64
	walk_fan = 3

	## The most critters one step moves together, the stepper and the kin
	## it nudges; and the most chickens it shoves. Each a lane of a `Lanes`.
	nudge_most : U64
	nudge_most = Rules.limits.nudge_most.to_u64_wrap()

	## A wish shorter than this is no step (Rules.roc's, in 256ths).
	dead_zone : I32
	dead_zone = (Rules.limits.dead_zone * 256).to_i32_wrap()

	## The walk after the leashed dog's step of size `most`.
	walk : Lent, Work, I32 -> Walked
	walk = |lent, work0, most| {
		if lent.side != side {
			crash "Walk: the physics keeps the critters by other cells than World.roc's tiles cut cell_per_tile ways"
		} else {
			{}
		}
		s = {
			from: lent.from,
			poops: lent.poops,
			words: work0.park.cells.len() // (side * side).to_u64_wrap(),
		}

		## **ONE OWNER FOR EACH LIST**: each in a variable of its own, and
		## every park a function hands back taken apart at once. A list read
		## out of a record that is still alive (`w.park.crits`) is shared for
		## the moment: Roc counts it up, and down again, each time, and the
		## lists the host lends are counted atomically (the walk's first cut
		## did 30 of these a visit, more than a third of its time).
		{ depth: depth0, moving: moving0, park: park0 } = work0
		{ cells: cells0, crits: crits0 } = park0
		var $depth = put(depth0, 0, 0)
		var $moving = moving0.append(0)
		herd = (get_c(crits0, 0)).kin
		{ cells: cells1, crits: crits1 } = line_up(s, { cells: cells0, crits: crits0 }, 0)
		var $cells = cells1
		var $crits = crits1
		var $pooper = 0
		var $anchor = -1
		var $count = 0
		var $going = Bool.True
		while $going and $count < walk_most {
			i = least_waiting($crits)
			if i < 0 {
				$going = Bool.False
			} else {
				iu = i.to_u64_wrap()
				me = get_c($crits, iu)
				$crits = put($crits, iu, { ..me, key: visited })
				{ crits: k1, moving: m1, out: wished } = wish_of($crits, $moving, iu)
				$crits = k1
				$moving = m1
				$moving = $moving.append(iu.to_u16_wrap())
				$count = $count + 1
				pace = Wish.mover_of(me.kind).pace
				{ cells: c2, crits: k2 } = step_around(
					s,
					{ cells: $cells, crits: $crits },
					iu,
					step_at_most({ x: wished.x, y: wished.y }, share(pace, most)),
				)
				$cells = c2
				$crits = k2
				if Wish.kind_of(me.kind) == Dog and me.kin == herd and wished.anchor >= 0 {
					a = wished.anchor.to_u64_wrap()
					d = get_u16($depth, a) + 1
					$depth = put($depth, iu, d)
					if d >= get_u16($depth, $pooper.to_u64_wrap()) {
						$pooper = i.to_i32_wrap()
						$anchor = wished.anchor
					} else {
						{}
					}
				} else {
					{}
				}
				{ cells: c3, crits: k3 } = line_up(s, { cells: $cells, crits: $crits }, iu)
				$cells = c3
				$crits = k3
			}
		}
		{
			anchor: $anchor,
			pooper: $pooper,
			work: { depth: $depth, moving: $moving, park: { cells: $cells, crits: $crits } },
		}
	}

	## **ONE PIXEL-TICK** (decision 30): the leashed dog's step `inc` along
	## `axis` (0 x, 1 y; `drag`), then, if it moved, the walk after it, of
	## the size it moved, and where the poop that came due lands (`lay`):
	## the dog had walked `before` (Zig's `Board.walked`), and `laid` poops
	## are laid. Hands back the work; what the dog bumped; its step; how far
	## it walked, each of its moves by its larger axis, for the physics'
	## count; and the poop (`no_poop`, none).
	Ticked : { bump : Bump, poop : Laid, step : Pt, walk : Walked, walked : I32 }

	pixel_tick : Lent, Work, I32, I32, U32, U32 -> Ticked
	pixel_tick = |lent, work0, axis, inc, before, laid| {
		s = {
			from: lent.from,
			poops: lent.poops,
			words: work0.park.cells.len() // (side * side).to_u64_wrap(),
		}
		{ depth, moving, park: park0 } = work0
		{ cells: c0, crits: k0 } = park0
		from = pt(get_c(k0, 0))
		{ bump, park: park1, walked } = drag(s, { cells: c0, crits: k0 }, axis, inc)
		{ cells: c1, crits: k1 } = park1
		step = delta(from, pt(get_c(k1, 0)))
		work1 = { depth, moving, park: { cells: c1, crits: k1 } }
		if step.x == 0 and step.y == 0 {
			{ bump, poop: no_poop, step, walk: { anchor: -1, pooper: 0, work: work1 }, walked }
		} else {
			w = walk(lent, work1, measure(step))
			{ anchor, pooper, work: work2 } = w
			{ depth: d2, moving: m2, park: park2 } = work2
			{ cells: c2, crits: k2 } = park2
			poop = if poops_due(before, walked) == 0 {
				no_poop
			} else {
				lay(s, k2, { anchor, pooper, step, laid })
			}
			{
				bump,
				poop,
				step,
				walk: {
					anchor,
					pooper,
					work: { depth: d2, moving: m2, park: { cells: c2, crits: k2 } },
				},
				walked,
			}
		}
	}

	## **THE HERD POOPS** (decision 29), each `poop_every` the leashed dog
	## walks (Rules.roc's `poop`, in 256ths), counted as Zig's
	## `Scene.walkOn` counts it, in 32 bits that stop at their top. A
	## pixel-tick's walk is under 2 px against a poop each 700, so at most
	## one comes due in it.
	poop_every : U64
	poop_every = (Rules.poop.every * 256).to_u64_wrap()

	poop_back : I32
	poop_back = (Rules.poop.back * 256).to_i32_wrap()

	poop_grid : I32
	poop_grid = (Rules.poop.grid * 256).to_i32_wrap()

	poop_reach : I32
	poop_reach = (Rules.poop.reach * 256).to_i32_wrap()

	poop_slots : U64
	poop_slots = Rules.poop.slots.to_u64_wrap()

	poops_due : U32, I32 -> U64
	poops_due = |before, walked| {
		b = before.to_u64()
		a = b + walked.to_u64_wrap()
		after = if (a > 4294967295) 4294967295 else a
		due = after // poop_every - b // poop_every
		if due > 1 {
			crash "Walk: two poops due in one pixel-tick"
		} else {
			due
		}
	}

	## Where a poop landed, and its slot: `laid` mod the slots. `no_poop`:
	## none due, or no spot it fits.
	Laid : { slot : I32, x : I32, y : I32 }

	no_poop : Laid
	no_poop = { slot: -1, x: 0, y: 0 }

	## Who poops after the walk: the pooper and its anchor (-1, none), by
	## seen index; the leashed dog's step; the poops laid so far.
	Pooping : { anchor : I32, laid : U32, pooper : I32, step : Pt }

	## **WHERE THE POOP LANDS**: the pooper's spot `poop_back` behind
	## itself, away from its anchor (with none, back along the leashed dog's
	## step), if it fits there (`poop_fits`); else the nearest spot that
	## does on rings `poop_grid` apart around it, out to `poop_reach`, each
	## walked clockwise from its north-west corner. With none, no poop.
	lay : Seen, List(Crit), Pooping -> Laid
	lay = |s, crits, how| {
		p = pt(get_c(crits, how.pooper.to_u64_wrap()))
		ahead = if (how.anchor >= 0) pt(
			get_c(
				crits,
				how.anchor.to_u64_wrap(),
			),
		) else plus(p, how.step)
		spot = plus(p, away_from(ahead, p, poop_back))
		slot = (how.laid.to_u64() % poop_slots).to_u16_wrap()
		var $at = wrapped(spot)
		var $found = poop_fits(s, crits, $at, slot)
		var $r = poop_grid
		while !$found and $r <= poop_reach {
			side_n = 2 * $r // poop_grid
			var $k = 0
			while !$found and $k < 4 * side_n {
				off = ($k % side_n) * poop_grid
				corner = $k // side_n
				r = $r
				d = if corner == 0 {
					{ x: off - r, y: 0 - r }
				} else if corner == 1 {
					{ x: r, y: off - r }
				} else if corner == 2 {
					{ x: r - off, y: r }
				} else {
					{ x: 0 - r, y: r - off }
				}
				$at = wrapped(plus(spot, d))
				$found = poop_fits(s, crits, $at, slot)
				$k = $k + 1
			}
			$r = $r + poop_grid
		}
		if ($found) { slot: slot.to_i32(), x: $at.x, y: $at.y } else no_poop
	}

	## A vector `length` long straight away from `from`, for the critter at
	## `p`, each axis truncated toward zero; east when the centres coincide.
	## (The wish's own `away` is its hot loop's: this is the poop's.)
	away_from : Pt, Pt, I32 -> Pt
	away_from = |from, p, length| {
		v = delta(from, p)
		if v.x == 0 and v.y == 0 {
			{ x: length, y: 0 }
		} else {
			l = measure(v).to_i64()
			{
				x: (v.x.to_i64() * length.to_i64() // l).to_i32_wrap(),
				y: (v.y.to_i64() * length.to_i64() // l).to_i32_wrap(),
			}
		}
	}

	## Whether a poop at `q` overlaps no seen critter and no poop the physics
	## sees but the one in `slot`, which it takes the place of. Every
	## critter is looked at, and the poops of the tiles its square meets:
	## a poop comes due each 700 px walked, so this is no hot loop.
	poop_fits : Seen, List(Crit), Pt, U16 -> Bool
	poop_fits = |s, crits, q, slot| {
		var $ok = Bool.True
		var $j = 0
		while $ok and $j < crits.len() {
			c = get_c(crits, $j)
			$ok = !overlap(q, poop_half, pt(c), c.half)
			$j = $j + 1
		}
		reach = 2 * poop_half
		cols = span(q.x, reach, tile, tiles)
		rows = span(q.y, reach, tile, tiles)
		var $r = 0
		while $ok and $r < rows.n {
			row = (rows.lo + $r).mod_by(tiles)
			var $c = 0
			while $ok and $c < cols.n {
				t = (row * tiles + (cols.lo + $c).mod_by(tiles)).to_u64_wrap()
				var $k = (get_u16(s.from, t)).to_u64()
				stop = (get_u16(s.from, t + 1)).to_u64()
				while $ok and $k < stop {
					o = get_poop(s, $k)
					$ok = o.slot == slot or !overlap(q, poop_half, { x: o.x, y: o.y }, poop_half)
					$k = $k + 1
				}
				$c = $c + 1
			}
			$r = $r + 1
		}
		$ok
	}

	## What stopped the leashed dog: nothing (`bump_none`), seen critter
	## `at` (`bump_critter`), or the poop in slot `at` (`bump_poop`); and
	## where it stood (`stood`). The numbers are roc_physics.zig's.
	Bump : { at : I32, kind : I32, stood : Pt }

	bump_none : I32
	bump_none = 0

	bump_critter : I32
	bump_critter = 1

	bump_poop : I32
	bump_poop = 2

	no_bump : Bump
	no_bump = { at: 0, kind: bump_none, stood: { x: 0, y: 0 } }

	## A critter's kin when it has none (roc_physics.zig's `no_kin`, a
	## chicken's): no dog or cow has it.
	no_kin : U8
	no_kin = 255

	## **THE LEASHED DOG'S STEP** (decision 30): `inc` along `axis`,
	## stopping just short of pressing into anyone (`sweep`). Stopped by a
	## chicken, it shoves it with the rest of the step; stopped by a poop,
	## or by a chicken it can't shove, it slides the step's size sideways,
	## away from it, and it bumps only when the slide fails too. A dog or a
	## cow it bumps at once. It nudges no one: for its own step its kin is
	## `no_kin`, and its breed is put back after.
	drag : Seen, Park, I32, I32 -> { bump : Bump, park : Park, walked : I32 }
	drag = |s, park0, axis, inc| {
		{ cells: c0, crits: k0 } = park0
		me = get_c(k0, 0)
		from = pt(me)
		k1 = put(k0, 0, { ..me, kin: no_kin })
		{ by, bump, park: park1 } = sweep(s, { cells: c0, crits: k1 }, axis, inc)
		park2 = if (by != 0) move_to(s, park1, 0, wrapped(plus(from, on_axis(axis, by)))) else park1
		{ park: park3, went, walked: more } = if bump.kind == bump_none {
			{ park: park2, went: Bool.True, walked: 0 }
		} else {
			go_around(s, park2, axis, inc - by, inc.abs(), bump)
		}
		{ cells: c3, crits: k3 } = park3
		k4 = put(k3, 0, { ..get_c(k3, 0), kin: me.kin })
		{
			bump: if (went) no_bump else bump,
			park: { cells: c3, crits: k4 },
			walked: by.abs() + more,
		}
	}

	## The leashed dog, stopped by `bump` with `rest` of its step along
	## `axis` to go: a shove of a chicken, else the slide `size` across,
	## away from what stopped it; whether either went, and how far it walked.
	go_around : Seen, Park, I32, I32, I32, Bump -> { park : Park, went : Bool, walked : I32 }
	go_around = |s, park0, axis, rest, size, bump| {
		{ cells: c0, crits: k0 } = park0
		chicken = bump.kind == bump_critter and Wish.kind_of(
			(
				get_c(
					k0,
					bump.at.to_u64_wrap(),
				)
			).kind,
		) == Chicken
		if bump.kind == bump_critter and !chicken {
			{ park: { cells: c0, crits: k0 }, went: Bool.False, walked: 0 }
		} else {
			{ park: park1, veto: shoved } = if chicken {
				step_whole(s, { cells: c0, crits: k0 }, 0, on_axis(axis, rest))
			} else {
				{ park: { cells: c0, crits: k0 }, veto: { ..went, why: why_poop } }
			}
			if shoved.why == why_went {
				{ park: park1, went: Bool.True, walked: rest.abs() }
			} else {
				{ cells: c1, crits: k1 } = park1
				off = part_on(delta(pt(get_c(k1, 0)), bump.stood), 1 - axis)
				{ park: park2, veto: slid } = step_whole(
					s,
					{ cells: c1, crits: k1 },
					0,
					on_axis(1 - axis, if (off > 0) -size else size),
				)
				{
					park: park2,
					went: slid.why == why_went,
					walked: if (slid.why == why_went) size else 0,
				}
			}
		}
	}

	## **THE SWEEP**: how far the leashed dog (seen index 0) goes along
	## `axis` by `step` against every other seen critter and every poop the
	## physics sees, and what stops it shortest: the lower seen index on a
	## tie, then a poop only if it stops it shorter still, the lower slot on
	## a tie.
	sweep : Seen, Park, I32, I32 -> { bump : Bump, by : I32, park : Park }
	sweep = |s, park, axis, step| {
		{ cells, crits } = park
		me = get_c(crits, 0)
		p = pt(me)
		h = me.half
		near = square_of(p, h + biggest_half + step.abs())
		var $best = step
		var $bump = no_bump
		var $w = 0
		while $w < s.words {
			var $bits = near_word(s, { cells, crits }, near, $w)
			while $bits != 0 {
				j = $w * 64 + $bits.count_trailing_zero_bits().to_u64()
				if j != 0 {
					o = get_c(crits, j)
					got = sweep_limit(p, h, axis, step, pt(o), o.half)
					if got.abs() < $best.abs() {
						$best = got
						$bump = { at: j.to_i32_wrap(), kind: bump_critter, stood: pt(o) }
					} else {
						{}
					}
				} else {
					{}
				}
				$bits = $bits.bitwise_and($bits - 1)
			}
			$w = $w + 1
		}
		reach = h + poop_half + step.abs()
		cols = span(p.x, reach, tile, tiles)
		rows = span(p.y, reach, tile, tiles)
		var $poop_best = step
		var $poop = -1
		var $poop_at = { x: 0, y: 0 }
		var $r = 0
		while $r < rows.n {
			row = (rows.lo + $r).mod_by(tiles)
			var $c = 0
			while $c < cols.n {
				t = (row * tiles + (cols.lo + $c).mod_by(tiles)).to_u64_wrap()
				var $k = (get_u16(s.from, t)).to_u64()
				stop = (get_u16(s.from, t + 1)).to_u64()
				while $k < stop {
					q = get_poop(s, $k)
					slot = q.slot.to_i64()
					got = sweep_limit(p, h, axis, step, { x: q.x, y: q.y }, poop_half)
					if got.abs() < $poop_best.abs() or ($poop >= 0 and got.abs() == $poop_best.abs() and slot < $poop) {
						$poop_best = got
						$poop = slot
						$poop_at = { x: q.x, y: q.y }
					} else {
						{}
					}
					$k = $k + 1
				}
				$c = $c + 1
			}
			$r = $r + 1
		}
		if $poop >= 0 and $poop_best.abs() < $best.abs() {
			{
				bump: { at: $poop.to_i32_wrap(), kind: bump_poop, stood: $poop_at },
				by: $poop_best,
				park: { cells, crits },
			}
		} else {
			{ bump: $bump, by: $best, park: { cells, crits } }
		}
	}

	## How far the square of half `h` at `p` may go along `axis` by `s`
	## (signed) against the square of half `oh` at `o`: contact means
	## pressing in, so touching across the move doesn't block, and against a
	## square it already overlaps a step may not shrink |Δ| on that axis nor
	## change its sign (from Δ = 0 either way is free).
	sweep_limit : Pt, I32, I32, I32, Pt, I32 -> I32
	sweep_limit = |p, h, axis, s, o, oh| {
		d = delta(p, o)
		hs = h + oh
		along = part_on(d, axis)
		if part_on(d, 1 - axis).abs() >= hs or s == 0 {
			s
		} else if along.abs() >= hs {
			if sign(along) != sign(s) {
				s
			} else {
				gap = along.abs() - hs
				if (s.abs() > gap) sign(s) * gap else s
			}
		} else if along == 0 or sign(along) != sign(s) {
			s
		} else {
			0
		}
	}

	## A vector `v` long along `axis` (0 x, 1 y).
	on_axis : I32, I32 -> Pt
	on_axis = |axis, v| if (axis == 0) { x: v, y: 0 } else { x: 0, y: v }

	## A vector's part along `axis`.
	part_on : Pt, I32 -> I32
	part_on = |v, axis| if (axis == 0) v.x else v.y

	sign : I32 -> I32
	sign = |v| if (v > 0) 1 else if (v < 0) -1 else 0

	## `pace` of `v`, rounded toward zero.
	share : Rules.Share, I32 -> I32
	share = |
		pace,
		v,
	| if (pace.num == pace.den) v else (v.to_i64() * pace.num.to_i64() // pace.den.to_i64()).to_i32_wrap()

	## The waiting critter with the least key, ties to the lower index; -1,
	## none.
	least_waiting : List(Crit) -> I64
	least_waiting = |crits| {
		var $best = -1
		var $best_key = 0
		var $j = 0
		for c in crits {
			if c.key >= 0 and ($best < 0 or c.key < $best_key) {
				$best = $j
				$best_key = c.key
			} else {
				{}
			}
			$j = $j + 1
		}
		$best
	}

	## The nearest three so far, by (distance, seen index); -1, none yet.
	Three : { d1 : I32, d2 : I32, d3 : I32, k1 : I64, k2 : I64, k3 : I64 }

	## Critter `from`'s `walk_fan` nearest dogs and cows not yet visited
	## (ties to the lower index), from where it stands now, each waiting
	## keyed by its distance from it, or by the nearer key it already waits
	## with.
	##
	## **RING BY RING**: the cells around its own, out a ring at a time. A
	## critter in a cell `r` rings out is more than `(r - 1)` cells away, so
	## once three are found and the third is at most that, no ring from `r`
	## on holds a nearer one, nor an equal, and the search stops there.
	line_up : Seen, Park, U64 -> Park
	line_up = |s, park, from| {
		{ cells, crits } = park
		p = pt(get_c(crits, from))
		n = side
		pc = p.x // cell
		pr = p.y // cell
		var $t = { d1: 0, d2: 0, d3: 0, k1: -1, k2: -1, k3: -1 }
		var $r = 0
		var $going = Bool.True
		while $going and $r <= n // 2 {
			if $r > 0 and $t.k3 >= 0 and $t.d3.to_i64() <= ($r - 1).to_i64() * cell.to_i64() {
				$going = Bool.False
			} else {
				## Round the torus, ring `r` holds the cells `r` away on the
				## larger axis; at `2r = n`, offset `+r` is `-r`'s cell, so
				## only `-r` is taken.
				## A side row's cells are its two ends, so `dx` steps from one
				## to the other.
				top = if (2 * $r == n) $r - 1 else $r
				var $dy = 0 - $r
				while $dy <= top {
					row = (pr + $dy).mod_by(n)
					edge = $dy == 0 - $r or $dy == $r
					var $dx = 0 - $r
					while $dx <= top {
						## The dogs and cows of the cell not yet visited, offered
						## to the three nearest `p` (here, not in a function: one
						## that took the park took its lists' refcounts up and down).
						base = (row * n + (pc + $dx).mod_by(n)).to_u64_wrap() * s.words
						var $w = 0
						while $w < s.words {
							var $bits = get_u64(cells, base + $w)
							while $bits != 0 {
								j = $w * 64 + $bits.count_trailing_zero_bits().to_u64()
								o = get_c(crits, j)
								if o.key != visited and Wish.walks(o.kind) {
									$t = nearer($t, measure(delta(pt(o), p)), j.to_i64_wrap())
								} else {
									{}
								}
								$bits = $bits.bitwise_and($bits - 1)
							}
							$w = $w + 1
						}
						$dx = if (edge) $dx + 1 else if ($dx == 0 - $r and $r > 0 and top == $r) $r else top + 1
					}
					$dy = $dy + 1
				}
				$r = $r + 1
			}
		}
		{ cells, crits: crits |> offer($t.k1, $t.d1) |> offer($t.k2, $t.d2) |> offer($t.k3, $t.d3) }
	}

	## The three with critter `j`, `d` away, in its place among them.
	nearer : Three, I32, I64 -> Three
	nearer = |t, d, j| {
		if t.k1 < 0 or before(d, j, t.d1, t.k1) {
			{ d1: d, k1: j, d2: t.d1, k2: t.k1, d3: t.d2, k3: t.k2 }
		} else if t.k2 < 0 or before(d, j, t.d2, t.k2) {
			{ ..t, d2: d, k2: j, d3: t.d2, k3: t.k2 }
		} else if t.k3 < 0 or before(d, j, t.d3, t.k3) {
			{ ..t, d3: d, k3: j }
		} else {
			t
		}
	}

	before : I32, I64, I32, I64 -> Bool
	before = |d, j, kd, kj| d < kd or (d == kd and j < kj)

	## `who` waits with `key`, or with the key it already waits with if
	## that is nearer. `who` -1: no one.
	offer : List(Crit), I64, I32 -> List(Crit)
	offer = |crits, who, key| {
		if who < 0 {
			crits
		} else {
			j = who.to_u64_wrap()
			k = key.to_i64()
			c = get_c(crits, j)
			if (c.key >= 0 and c.key <= k) crits else put(crits, j, { ..c, key: k })
		}
	}

	## Seen critter `i`'s wish, from the critters in motion where they now
	## stand.
	wish_of : List(Crit),
	List(U16),
	U64 -> {
		crits : List(Crit),
		moving : List(U16),
		out : Wish.Out,
	}
	wish_of = |crits, moving, i| {
		me = get_c(crits, i)
		wisher = { half: me.half, kind: me.kind }
		var $s = Wish.start
		for j in moving {
			o = get_c(crits, j.to_u64())
			tx = short(o.x - me.x)
			ty = short(o.y - me.y)
			$s = Wish.add(
				wisher,
				$s,
				{
					ax: back(tx),
					ay: back(ty),
					half: o.half,
					tx,
					ty,
					j,
					kin: Wish.kind_of(me.kind) == Dog and Wish.kind_of(o.kind) == Dog and o.kin == me.kin,
					kind: o.kind,
				},
			)
		}
		{ crits, moving, out: Wish.finish(wisher, $s) }
	}

	## A short-way difference turned round: in [-half_world, half_world),
	## the same but at -half_world.
	back : I32 -> I32
	back = |d| if (d == -half_world) d else -d

	## The step a total of wishes comes to, at most `most` on its larger
	## axis: none inside the dead zone; the total itself within `most`;
	## else scaled to it.
	step_at_most : Pt, I32 -> Pt
	step_at_most = |total, most| {
		t = measure(total)
		if t < dead_zone {
			{ x: 0, y: 0 }
		} else if t <= most {
			total
		} else {
			{
				x: (total.x.to_i64() * most.to_i64() // t.to_i64()).to_i32_wrap(),
				y: (total.y.to_i64() * most.to_i64() // t.to_i64()).to_i32_wrap(),
			}
		}
	}

	## Why a step was vetoed (`why`, one of the four below); and where the
	## critter that was blocked stood, and its blocker. A number, not a tag:
	## a veto rides the group's record round the walk's inner loops
	## (ROC-SPEED.md, on records and tags carried round a loop).
	Veto : { at : Pt, blocker : Pt, why : U8 }

	## It went: no veto.
	why_went : U8
	why_went = 0

	## A critter it may not press.
	why_pressed : U8
	why_pressed = 1

	## A chicken it can't shove.
	why_chicken : U8
	why_chicken = 2

	## A poop.
	why_poop : U8
	why_poop = 3

	went : Veto
	went = { at: { x: 0, y: 0 }, blocker: { x: 0, y: 0 }, why: why_went }

	## Critter `i` takes `step` (`step_whole`); vetoed by a poop, or by a
	## chicken it can't shove, it tries once more with `sidestep`'s.
	step_around : Seen, Park, U64, Pt -> Park
	step_around = |s, park, i, step| {
		{ park: tried, veto } = step_whole(s, park, i, step)
		if veto.why == why_chicken or veto.why == why_poop {
			{ park: again, veto: _ } = step_whole(s, tried, i, sidestep(veto, step))
			again
		} else {
			tried
		}
	}

	## The step that goes around a veto's poop or chicken: `step` with the
	## axis on which the blocker is farther off zeroed (a tie zeroes x),
	## and on the other its own part kept, or, that part zero, the step's
	## whole size away from the blocker (on the line, +).
	sidestep : Veto, Pt -> Pt
	sidestep = |v, step| {
		d = delta(v.at, v.blocker)
		size = measure(step)
		if d.x.abs() >= d.y.abs() {
			{ x: 0, y: if (step.y != 0) step.y else if (d.y > 0) -size else size }
		} else {
			{ x: if (step.x != 0) step.x else if (d.x > 0) -size else size, y: 0 }
		}
	}

	## **THE VETO, THE NUDGE AND THE SHOVE** (decisions 25, 30): critter
	## `i` (a dog or a cow, never the leashed dog) takes `step` whole, or not
	## at all. Where its square there would overlap kin, they take the same
	## step with it, and whoever they would overlap is nudged in turn, up to
	## `nudge_most` in all; a chicken one of them would overlap is shoved by
	## the step plus as much again sideways (`shove_aside`), up to
	## `nudge_most` chickens, each landing clear of everyone and every poop.
	## Any other overlap, or a poop, vetoes the lot. All is checked before
	## anyone moves.
	step_whole : Seen, Park, U64, Pt -> { park : Park, veto : Veto }
	step_whole = |s, park, i, step| {
		if step.x == 0 and step.y == 0 {
			{ park, veto: went }
		} else {
			## The park goes through each and comes back, never held by two:
			## a list one function reads while its caller keeps it is counted
			## up and down, atomically.
			{ group: grouped, park: park1 } = gather(s, park, i, step)
			if grouped.veto.why != why_went {
				{ park: park1, veto: grouped.veto }
			} else {
				{ park: park2, veto: cannot } = shove_veto(s, park1, step, grouped)
				if cannot.why != why_went {
					{ park: park2, veto: cannot }
				} else {
					{ park: move_all(s, park2, step, grouped), veto: went }
				}
			}
		}
	}

	## The critters a step moves: the group (the stepper and the kin it
	## nudges, in the order they joined) and the chickens shoved, each with
	## the one of the group that shoves it; or the veto.
	Group : { by : Lanes, group : Lanes, n : U64, ns : U64, shoved : Lanes, veto : Veto }

	## Each of the group in turn, from where it would step to, meets every
	## critter whose square that one's would overlap, in seen index order:
	## a chicken it shoves, kin it nudges into the group, anyone else (or
	## one past the most) a veto.
	gather : Seen, Park, U64, Pt -> { group : Group, park : Park }
	gather = |s, park, i, step| {
		breed = (get_c(park.crits, i)).kin
		var $g = { by: 0, group: lane_put(0, 0, i), n: 1, ns: 0, shoved: 0, veto: went }
		var $k = 0
		while $k < $g.n and $g.veto.why == why_went {
			gk = lane_get($g.group, $k)
			me = get_c(park.crits, gk)
			from = pt(me)
			to = plus(from, step)
			h = me.half
			match poop_under(s, to, h) {
				Found(q) => {
					$g = { ..$g, veto: { at: from, blocker: q, why: why_poop } }
				}
				Clear => {
					near = square_of(to, h + biggest_half)
					var $w = 0
					while $w < s.words and $g.veto.why == why_went {
						var $bits = near_word(s, park, near, $w)
						while $bits != 0 and $g.veto.why == why_went {
							j = $w * 64 + $bits.count_trailing_zero_bits().to_u64()
							o = get_c(park.crits, j)
							if overlap(to, h, pt(o), o.half) and !in_move($g, j) {
								if Wish.kind_of(o.kind) == Chicken {
									if $g.ns == nudge_most {
										$g = {
											..$g,
											veto: { at: from, blocker: pt(o), why: why_chicken },
										}
									} else {
										$g = {
											..$g,
											shoved: lane_put($g.shoved, $g.ns, j),
											by: lane_put($g.by, $g.ns, gk),
											ns: $g.ns + 1,
										}
									}
								} else if j == 0 or o.kin != breed or $g.n == nudge_most {
									$g = {
										..$g,
										veto: { at: from, blocker: pt(o), why: why_pressed },
									}
								} else {
									$g = { ..$g, group: lane_put($g.group, $g.n, j), n: $g.n + 1 }
								}
							} else {
								{}
							}
							$bits = $bits.bitwise_and($bits - 1)
						}
						$w = $w + 1
					}
				}
			}
			$k = $k + 1
		}
		{ group: $g, park }
	}

	## Whether seen critter `j` is in the move: in the group, or shoved.
	in_move : Group, U64 -> Bool
	in_move = |g, j| lanes_hold(g.group, g.n, j) or lanes_hold(g.shoved, g.ns, j)

	## Where shoved chicken `m` lands: its point plus the step, plus the
	## step turned toward its side of its shover's centre line.
	land_of : List(Crit), Pt, Group, U64 -> Pt
	land_of = |crits, step, g, m| {
		p = pt(get_c(crits, lane_get(g.shoved, m)))
		wrapped(
			plus(
				plus(p, step),
				shove_aside(step, delta(pt(get_c(crits, lane_get(g.by, m))), p)),
			),
		)
	}

	## The veto of the first shove that cannot land: on a poop, on a critter
	## not in the move, on one of the group where it steps to, or on a
	## chicken shoved before it.
	shove_veto : Seen, Park, Pt, Group -> { park : Park, veto : Veto }
	shove_veto = |s, park, step, g| {
		crits = park.crits
		var $v = went
		var $m = 0
		while $m < g.ns and $v.why == why_went {
			c = get_c(crits, lane_get(g.shoved, $m))
			ch = c.half
			land = land_of(crits, step, g, $m)
			bad = match poop_under(s, land, ch) {
				Found(_) => Bool.True
				Clear => {
					var $hit = Bool.False
					near = square_of(land, ch + biggest_half)
					var $w = 0
					while !$hit and $w < s.words {
						var $bits = near_word(s, park, near, $w)
						while !$hit and $bits != 0 {
							j = $w * 64 + $bits.count_trailing_zero_bits().to_u64()
							o = get_c(crits, j)
							$hit = overlap(land, ch, pt(o), o.half) and !in_move(g, j)
							$bits = $bits.bitwise_and($bits - 1)
						}
						$w = $w + 1
					}
					var $k = 0
					while !$hit and $k < g.n {
						o = get_c(crits, lane_get(g.group, $k))
						$hit = overlap(land, ch, plus(pt(o), step), o.half)
						$k = $k + 1
					}
					var $e = 0
					while !$hit and $e < $m {
						$hit = overlap(land, ch, land_of(crits, step, g, $e), ch)
						$e = $e + 1
					}
					$hit
				}
			}
			if bad {
				$v = { at: pt(get_c(crits, lane_get(g.by, $m))), blocker: pt(c), why: why_chicken }
			} else {
				{}
			}
			$m = $m + 1
		}
		{ park, veto: $v }
	}

	## The shoved chickens land, then the group steps: each land is from
	## where its chicken and its shover stood, so the chickens go first (no
	## two of either are the same critter, so the order changes nothing
	## else).
	move_all : Seen, Park, Pt, Group -> Park
	move_all = |s, park0, step, g| {
		var $park = park0
		var $m = 0
		while $m < g.ns {
			$park = move_to(s, $park, lane_get(g.shoved, $m), land_of($park.crits, step, g, $m))
			$m = $m + 1
		}
		var $k = 0
		while $k < g.n {
			o = lane_get(g.group, $k)
			$park = move_to(s, $park, o, wrapped(plus(pt(get_c($park.crits, o)), step)))
			$k = $k + 1
		}
		$park
	}

	## The cell a point stands in, round the torus, `row * side + col` (the
	## physics lends some critters off the world's square: src/play/grid.zig's
	## `cellOf` wraps alike).
	cell_at : I32, I32 -> U64
	cell_at = |x, y| ((y.mod_by(world) // cell) * side + x.mod_by(world) // cell).to_u64_wrap()

	## **THE PARK FILED**: each critter's bit in the cell it stands in.
	## The physics lends the cells all clear when it starts a tick's park
	## (src/play/physics.zig's `Scene.init`), and lends them back as this
	## left them for the rest of the tick; filed, the leashed dog's own bit
	## is set, so that bit tells which. Every call files before it walks.
	filed : Park -> Park
	filed = |park0| {
		{ cells: c0, crits: k0 } = park0
		words = c0.len() // (side * side).to_u64_wrap()
		dog0 = get_c(k0, 0)
		if get_u64(c0, cell_at(dog0.x, dog0.y) * words).bitwise_and(1) == 1 {
			{ cells: c0, crits: k0 }
		} else {
			n = k0.len()
			var $cells = c0
			var $j = 0
			while $j < n {
				c = get_c(k0, $j)
				at = cell_at(c.x, c.y) * words + $j // 64
				word = get_u64($cells, at).bitwise_or((1).shl_wrap(($j % 64).to_u8_wrap()))
				$cells = put($cells, at, word)
				$j = $j + 1
			}
			{ cells: $cells, crits: k0 }
		}
	}

	## Seen critter `j` to `p` (in the world), and into its cell there.
	move_to : Seen, Park, U64, Pt -> Park
	move_to = |s, park, j, p| {
		{ cells, crits: crits0 } = park
		c = get_c(crits0, j)
		was_in = cell_at(c.x, c.y)
		now_in = cell_at(p.x, p.y)
		crits = put(crits0, j, { ..c, x: p.x, y: p.y })
		if now_in == was_in {
			{ cells, crits }
		} else {
			bit = (1).shl_wrap((j % 64).to_u8_wrap())
			was = was_in * s.words + j // 64
			now = now_in * s.words + j // 64
			left = get_u64(cells, was).bitwise_and(bit.bitwise_not())
			cells1 = put(cells, was, left)
			came = get_u64(cells1, now).bitwise_or(bit)
			{ crits, cells: put(cells1, now, came) }
		}
	}

	## **THE FORAGE TURN** (decision 31): once a tick, after the drag, when
	## the leashed dog's net move over it, `net`, is more than nothing. Each
	## critter whose kind forages (Wish.roc's `forage_of`; today the
	## chickens), in seen order, steps at most its forage's `pace` of `net`
	## and at most its `step`:
	## - toward the nearest ripe poop it sees within `sight` (ties to the
	##   lower slot), going round what's in its way (`forage_around`);
	## - with none, toward its home (`homes`, by seen index) when more than
	##   `home_band` from it, whole or not at all: blocked, it waits;
	## - else it stays put, and eats nothing.
	## Then it eats every ripe poop its square overlaps: `eaten`, lent empty
	## with room, which the physics' Zig takes off the park after. Ripe is
	## every poop but the newest, slot `laid` - 1, which only blocks. A
	## forager heeds no critter and plans nothing.
	##
	## Its step is its own (`forage_step`), not the walk's `step_whole`: a
	## forager shoves nobody and nudges no kin, and the walk's hot helpers
	## take no caller outside it (docs/ROC-SPEED.md).
	Turned : { eaten : List(U16), park : Park }

	forage_turn : Lent, Park, List(Pt), List(U16), I32, U32 -> Turned
	forage_turn = |lent, park0, homes, eaten0, net, laid| {
		s = {
			from: lent.from,
			poops: lent.poops,
			words: park0.cells.len() // (side * side).to_u64_wrap(),
		}
		{ cells: c0, crits: k0 } = park0
		newest = ((laid.to_u64() + poop_slots - 1) % poop_slots).to_u16_wrap()
		var $cells = c0
		var $crits = k0
		var $eaten = eaten0
		var $j = 0
		n = if (net == 0) 0 else k0.len()
		while $j < n {
			me = get_c($crits, $j)
			match Wish.forage_of(me.kind) {
				Stays => {}
				Forages(f) => {
					share_of = (net.to_i64() * f.pace.num // f.pace.den).to_i32_wrap()
					step_most = (f.step * 256).to_i32_wrap()
					most = if (share_of < step_most) share_of else step_most
					p = pt(me)
					sight = (f.sight * 256).to_i32_wrap()
					near = nearest_ripe(s, $eaten, p, sight, newest)
					if near.slot >= 0 {
						{ cells: c1, crits: k1 } = forage_around(
							s,
							{ cells: $cells, crits: $crits },
							$j,
							forage_at_most(delta(p, near.at), most),
							newest,
						)
						$cells = c1
						$crits = k1
						$eaten = eat_under(s, $eaten, pt(get_c($crits, $j)), me.half, newest)
					} else {
						home = delta(p, get_pt(homes, $j))
						if measure(home) > (f.home_band * 256).to_i32_wrap() {
							{ park: { cells: c1, crits: k1 }, veto: _ } = forage_step(
								s,
								{ cells: $cells, crits: $crits },
								$j,
								forage_at_most(home, most),
								newest,
							)
							$cells = c1
							$crits = k1
							$eaten = eat_under(s, $eaten, pt(get_c($crits, $j)), me.half, newest)
						} else {
							{}
						}
					}
				}
			}
			$j = $j + 1
		}
		{ eaten: $eaten, park: { cells: $cells, crits: $crits } }
	}

	## The nearest ripe poop not yet eaten within `sight` of `p` (its slot,
	## -1 for none, and where), ties to the lower slot.
	nearest_ripe : Seen, List(U16), Pt, I32, U16 -> { at : Pt, slot : I32 }
	nearest_ripe = |s, eaten, p, sight, newest| {
		cols = span(p.x, sight, tile, tiles)
		rows = span(p.y, sight, tile, tiles)
		var $best = -1
		var $best_d = 0
		var $at = { x: 0, y: 0 }
		var $r = 0
		while $r < rows.n {
			row = (rows.lo + $r).mod_by(tiles)
			var $c = 0
			while $c < cols.n {
				t = (row * tiles + (cols.lo + $c).mod_by(tiles)).to_u64_wrap()
				var $k = (get_u16(s.from, t)).to_u64()
				stop = (get_u16(s.from, t + 1)).to_u64()
				while $k < stop {
					q = get_poop(s, $k)
					d = measure(delta(p, { x: q.x, y: q.y }))
					slot = q.slot.to_i32()
					if q.slot != newest and d <= sight and !eaten.contains(q.slot) and ($best < 0 or d < $best_d or (d == $best_d and slot < $best)) {
						$best = slot
						$best_d = d
						$at = { x: q.x, y: q.y }
					} else {
						{}
					}
					$k = $k + 1
				}
				$c = $c + 1
			}
			$r = $r + 1
		}
		{ at: $at, slot: $best }
	}

	## Every ripe poop not yet eaten a square of half `h` at `p` overlaps,
	## after those in `eaten`.
	eat_under : Seen, List(U16), Pt, I32, U16 -> List(U16)
	eat_under = |s, eaten0, p, h, newest| {
		reach = h + poop_half
		cols = span(p.x, reach, tile, tiles)
		rows = span(p.y, reach, tile, tiles)
		var $eaten = eaten0
		var $r = 0
		while $r < rows.n {
			row = (rows.lo + $r).mod_by(tiles)
			var $c = 0
			while $c < cols.n {
				t = (row * tiles + (cols.lo + $c).mod_by(tiles)).to_u64_wrap()
				var $k = (get_u16(s.from, t)).to_u64()
				stop = (get_u16(s.from, t + 1)).to_u64()
				while $k < stop {
					q = get_poop(s, $k)
					if q.slot != newest and overlap(
						p,
						h,
						{ x: q.x, y: q.y },
						poop_half,
					) and !$eaten.contains(q.slot) {
						$eaten = $eaten.append(q.slot)
					} else {
						{}
					}
					$k = $k + 1
				}
				$c = $c + 1
			}
			$r = $r + 1
		}
		$eaten
	}

	## A forager's step toward what it wants, at most `most` (the walk's
	## `step_at_most`, its own copy: none inside the dead zone).
	forage_at_most : Pt, I32 -> Pt
	forage_at_most = |total, most| {
		t = measure(total)
		if t < dead_zone {
			{ x: 0, y: 0 }
		} else if t <= most {
			total
		} else {
			{
				x: (total.x.to_i64() * most.to_i64() // t.to_i64()).to_i32_wrap(),
				y: (total.y.to_i64() * most.to_i64() // t.to_i64()).to_i32_wrap(),
			}
		}
	}

	## **A FORAGER'S STEP** (decisions 30, 31): seen critter `j` takes
	## `step` whole, or not at all. It shoves nobody and has no kin, so any
	## critter it would overlap vetoes it (`why_chicken` for another
	## forager, which the sidestep goes round; `why_pressed` for any other),
	## the first by seen index; and so does the newest poop, the only one it
	## would not eat (`why_poop`).
	forage_step : Seen, Park, U64, Pt, U16 -> { park : Park, veto : Veto }
	forage_step = |s, park, j, step, newest| {
		if step.x == 0 and step.y == 0 {
			{ park, veto: went }
		} else {
			{ cells, crits } = park
			me = get_c(crits, j)
			from = pt(me)
			to = plus(from, step)
			h = me.half
			newest_at = poop_in(s, newest, to, h)
			if newest_at.slot >= 0 {
				{ park: { cells, crits }, veto: { at: from, blocker: newest_at.at, why: why_poop } }
			} else {
				var $k = 0
				var $veto = went
				while $veto.why == why_went and $k < crits.len() {
					o = get_c(crits, $k)
					if $k != j and overlap(to, h, pt(o), o.half) {
						why = match Wish.forage_of(o.kind) {
							Forages(_) => why_chicken
							Stays => why_pressed
						}
						$veto = { at: from, blocker: pt(o), why }
					} else {
						{}
					}
					$k = $k + 1
				}
				if $veto.why == why_went {
					{ park: forage_move(s, { cells, crits }, j, wrapped(to)), veto: went }
				} else {
					{ park: { cells, crits }, veto: $veto }
				}
			}
		}
	}

	## The poop in `slot`, if the physics sees it and a square of half `h`
	## at `p` overlaps it (slot -1, not).
	poop_in : Seen, U16, Pt, I32 -> { at : Pt, slot : I32 }
	poop_in = |s, slot, p, h| {
		reach = h + poop_half
		cols = span(p.x, reach, tile, tiles)
		rows = span(p.y, reach, tile, tiles)
		var $found = { at: { x: 0, y: 0 }, slot: -1 }
		var $r = 0
		while $r < rows.n {
			row = (rows.lo + $r).mod_by(tiles)
			var $c = 0
			while $c < cols.n {
				t = (row * tiles + (cols.lo + $c).mod_by(tiles)).to_u64_wrap()
				var $k = (get_u16(s.from, t)).to_u64()
				stop = (get_u16(s.from, t + 1)).to_u64()
				while $k < stop {
					q = get_poop(s, $k)
					if q.slot == slot and overlap(p, h, { x: q.x, y: q.y }, poop_half) {
						$found = { at: { x: q.x, y: q.y }, slot: q.slot.to_i32() }
					} else {
						{}
					}
					$k = $k + 1
				}
				$c = $c + 1
			}
			$r = $r + 1
		}
		$found
	}

	## **THE FORAGER'S SIDESTEP** (decision 30): `step` (`forage_step`);
	## vetoed by a poop or another forager, once more with the step that
	## goes round it: the axis on which the blocker is farther off zeroed (a
	## tie zeroes x), on the other its own part kept, or, that part zero,
	## the step's size away from the blocker (on the line, +).
	forage_around : Seen, Park, U64, Pt, U16 -> Park
	forage_around = |s, park0, j, step, newest| {
		{ park: park1, veto: v } = forage_step(s, park0, j, step, newest)
		if v.why == why_poop or v.why == why_chicken {
			d = delta(v.at, v.blocker)
			size = measure(step)
			again = if d.x.abs() >= d.y.abs() {
				{ x: 0, y: if (step.y != 0) step.y else if (d.y > 0) 0 - size else size }
			} else {
				{ x: if (step.x != 0) step.x else if (d.x > 0) 0 - size else size, y: 0 }
			}
			{ park: park2, veto: _ } = forage_step(s, park1, j, again, newest)
			park2
		} else {
			park1
		}
	}

	## Seen critter `j` to `p` (wrapped), and to its cell's set (the walk's
	## `move_to`, the forager's own copy).
	forage_move : Seen, Park, U64, Pt -> Park
	forage_move = |s, park, j, p| {
		{ cells, crits: crits0 } = park
		c = get_c(crits0, j)
		was_in = cell_at(c.x, c.y)
		now_in = cell_at(p.x, p.y)
		crits = put(crits0, j, { ..c, x: p.x, y: p.y })
		if now_in == was_in {
			{ cells, crits }
		} else {
			bit = (1).shl_wrap((j % 64).to_u8_wrap())
			was = was_in * s.words + j // 64
			now = now_in * s.words + j // 64
			left = get_u64(cells, was).bitwise_and(bit.bitwise_not())
			cells1 = put(cells, was, left)
			came = get_u64(cells1, now).bitwise_or(bit)
			{ crits, cells: put(cells1, now, came) }
		}
	}

	get_pt : List(Pt), U64 -> Pt
	get_pt = |l, j| match l.get(j) {
		Ok(v) => v
		Err(_) => crash "Walk: no home there"
	}

	## Where a critter stands.
	pt : Crit -> Pt
	pt = |c| { x: c.x, y: c.y }

	## The cells a square `reach` either way of `p` meets, on each axis.
	Square : { cols : Span, rows : Span }

	square_of : Pt, I32 -> Square
	square_of = |p, reach| {
		cols: span(p.x, reach, cell, side),
		rows: span(p.y, reach, cell, side),
	}

	## Word `w` of the set of every critter in the cells of `near`.
	near_word : Seen, Park, Square, U64 -> U64
	near_word = |s, park, near, w| {
		var $u = 0
		var $r = 0
		while $r < near.rows.n {
			row = (near.rows.lo + $r).mod_by(side)
			var $c = 0
			while $c < near.cols.n {
				c = row * side + (near.cols.lo + $c).mod_by(side)
				$u = $u.bitwise_or(get_u64(park.cells, c.to_u64_wrap() * s.words + w))
				$c = $c + 1
			}
			$r = $r + 1
		}
		$u
	}

	## **A SHOVE'S SIDEWAYS PART** (decision 30): `step` turned a right
	## angle, toward the side of the stepper's centre line the chicken is on
	## (`d`, from the stepper to it); a chicken on the line goes to
	## whichever side is south, or east for a step north or south.
	shove_aside : Pt, Pt -> Pt
	shove_aside = |step, d| {
		left = { x: -step.y, y: step.x }
		right = { x: step.y, y: -step.x }
		turn = step.x.to_i64() * d.y.to_i64() - step.y.to_i64() * d.x.to_i64()
		if turn > 0 {
			left
		} else if turn < 0 {
			right
		} else if left.y > 0 or (left.y == 0 and left.x > 0) {
			left
		} else {
			right
		}
	}

	## The place of a poop a square of half `h` at `p` overlaps, the lowest
	## slot's; the poops of the tiles the square meets, round the torus.
	poop_under : Seen, Pt, I32 -> [Found(Pt), Clear]
	poop_under = |s, p, h| {
		reach = h + poop_half
		cols = span(p.x, reach, tile, tiles)
		rows = span(p.y, reach, tile, tiles)
		var $best = -1
		var $at = { x: 0, y: 0 }
		var $r = 0
		while $r < rows.n {
			row = (rows.lo + $r).mod_by(tiles)
			var $c = 0
			while $c < cols.n {
				t = (row * tiles + (cols.lo + $c).mod_by(tiles)).to_u64_wrap()
				var $k = (get_u16(s.from, t)).to_u64()
				stop = (get_u16(s.from, t + 1)).to_u64()
				while $k < stop {
					q = get_poop(s, $k)
					slot = q.slot.to_i64()
					if ($best < 0 or slot < $best) and overlap(
						p,
						h,
						{ x: q.x, y: q.y },
						poop_half,
					) {
						$best = slot
						$at = { x: q.x, y: q.y }
					} else {
						{}
					}
					$k = $k + 1
				}
				$c = $c + 1
			}
			$r = $r + 1
		}
		if ($best < 0) Clear else Found($at)
	}

	## The `n` squares of side `size`, `count` a side of the world, from
	## `lo` (mod `count`), that a span of `reach` either way of `v` meets;
	## never more than `count`, so none comes twice.
	Span : { lo : I32, n : I32 }

	span : I32, I32, I32, I32 -> Span
	span = |v, reach, size, count| {
		w = v.mod_by(world)
		lo = (w - reach).div_floor_by(size)
		hi = (w + reach).div_floor_by(size)
		{ lo, n: if (hi - lo + 1 < count) hi - lo + 1 else count }
	}

	## **THE ONE DIFFERENCE**: from `a` to `b`, per axis, the short way
	## round the torus, each axis in [-world/2, world/2).
	delta : Pt, Pt -> Pt
	delta = |a, b| { x: short(b.x - a.x), y: short(b.y - a.y) }

	short : I32 -> I32
	short = |d| {
		h = half_world
		if d >= h {
			if (d < world + h) d - world else (d + h).mod_by(world) - h
		} else if d >= -h {
			d
		} else if d >= -h - world {
			d + world
		} else {
			(d + h).mod_by(world) - h
		}
	}

	## Two squares overlap: closer than their halves' sum on both axes.
	overlap : Pt, I32, Pt, I32 -> Bool
	overlap = |p, ph, q, qh| {
		d = delta(p, q)
		d.x.abs() < ph + qh and d.y.abs() < ph + qh
	}

	wrapped : Pt -> Pt
	wrapped = |p| { x: p.x.mod_by(world), y: p.y.mod_by(world) }

	plus : Pt, Pt -> Pt
	plus = |p, v| { x: p.x + v.x, y: p.y + v.y }

	## A vector's length: its larger axis.
	measure : Pt -> I32
	measure = |v| {
		mx = v.x.abs()
		my = v.y.abs()
		if (mx > my) mx else my
	}

	## Up to eight seen indexes, sixteen bits each, in the order put.
	Lanes : U128

	lane_get : Lanes, U64 -> U64
	lane_get = |l, k| (l.shr_zf_wrap((16 * k).to_u8_wrap()).bitwise_and(0xFFFF)).to_u64_wrap()

	## `l` with lane `k` (empty till now) set to `v`.
	lane_put : Lanes, U64, U64 -> Lanes
	lane_put = |l, k, v| l.bitwise_or(v.to_u128().shl_wrap((16 * k).to_u8_wrap()))

	## Whether the first `n` lanes hold `v`.
	lanes_hold : Lanes, U64, U64 -> Bool
	lanes_hold = |l, n, v| {
		var $k = 0
		var $found = Bool.False
		while !$found and $k < n {
			$found = lane_get(l, $k) == v
			$k = $k + 1
		}
		$found
	}

	## The lists' reads and writes. An index is always in range (the Zig
	## sizes every list to the seen critters, the cells, `moving` and the
	## poops' tiles to what the walk can reach); out of range is a bug.
	get_c : List(Crit), U64 -> Crit
	get_c = |l, j| match l.get(j) {
		Ok(c) => c
		Err(_) => crash "Walk: no critter there"
	}

	get_poop : Seen, U64 -> Poop
	get_poop = |s, k| match s.poops.get(k) {
		Ok(p) => p
		Err(_) => crash "Walk: no poop there"
	}

	get_u16 : List(U16), U64 -> U16
	get_u16 = |l, j| match l.get(j) {
		Ok(v) => v
		Err(_) => crash "Walk: no U16 there"
	}

	get_u64 : List(U64), U64 -> U64
	get_u64 = |l, j| match l.get(j) {
		Ok(v) => v
		Err(_) => crash "Walk: no cell word there"
	}

	put : List(a), U64, a -> List(a)
	put = |l, j, v| match l.set(j, v) {
		Ok(m) => m
		Err(_) => crash "Walk: no slot there"
	}
}

## Pure-Roc checks of the walk: small parks round a leashed dog at
## (1000, 1000) px, its step a pixel (256). Critters by kind (0 a dog, 1 a
## cow, 2 a chicken), kin and place in whole pixels, in seen index order,
## the leashed dog first; dogs of breed 0, so kin to it.
crit = |kind, kin, x, y| {
	half = if (kind == 1) 21 * 256 else if (kind == 2) 10 * 256 else 14 * 256
	{ half, key: Walk.not_lined_up, kin, kind, x: x * 256, y: y * 256 }
}

dog = |x, y| crit(0, 0, x, y)

## The park of `cs`: each in its cell, the leashed dog visited.
park_of = |cs| {
	var $crits = []
	var $j = 0
	for c in cs {
		$crits = $crits.append({ ..c, key: if ($j == 0) Walk.visited else Walk.not_lined_up })
		$j = $j + 1
	}
	Walk.filed({ cells: List.repeat(0, (Walk.side * Walk.side).to_u64_wrap()), crits: $crits })
}

## The walk of `cs` with no poop, or with one poop at `(px, py)` px in
## tile `t` (row by row, 350 px tiles).
walk_of = |cs| Walk.walk(
	{ from: List.repeat(0, 37), poops: [], side: Walk.side },
	{ depth: List.repeat(0, cs.len()), moving: [], park: park_of(cs) },
	256,
)

walk_poop = |cs, px, py, t| {
	from = List.repeat(0, t + 1).concat(List.repeat(1, 36 - t))
	Walk.walk(
		{ from, poops: [{ slot: 0, x: px * 256, y: py * 256 }], side: Walk.side },
		{ depth: List.repeat(0, cs.len()), moving: [], park: park_of(cs) },
		256,
	)
}

place = |r, j| match r.work.park.crits.get(j) {
	Ok(c) => Walk.pt(c)
	Err(_) => Walk.pt({ half: 0, key: 0, kin: 0, kind: 0, x: -1, y: -1 })
}

## One pixel-tick of `cs`, no poop: the leashed dog's step `inc` along
## `axis` (0 x, 1 y), then the walk if it moved.
tick_of = |cs, axis, inc| Walk.pixel_tick(
	{ from: List.repeat(0, 37), poops: [], side: Walk.side },
	{ depth: List.repeat(0, cs.len()), moving: [], park: park_of(cs) },
	axis,
	inc,
	0,
	0,
)

tick_place = |r, j| place(r.walk, j)

## The leashed dog sweeps up to a dog of another breed a pixel off, and
## bumps it: a dog it never goes round.
expect {
	r = tick_of([dog(1000, 1000), crit(0, 1, 1029, 1000)], 0, 3 * 256)
	tick_place(r, 0) == {
		x: 1001 * 256,
		y: 1000 * 256,
	} and r.bump.kind == Walk.bump_critter and r.bump.at == 1 and r.walked == 256
}

## A chicken touching in front it shoves: the chicken goes the step and a
## step across (south, on the line), the dog goes on, no bump.
expect {
	r = tick_of([dog(1000, 1000), crit(2, 255, 1024, 1000)], 0, 256)
	tick_place(r, 0) == {
		x: 1001 * 256,
		y: 1000 * 256,
	} and tick_place(r, 1) == {
		x: 1025 * 256,
		y: 1001 * 256,
	} and r.bump.kind == Walk.bump_none and r.walked == 256
}

## It nudges no one, its own breed neither: a chicken a pixel ahead (north
## of its line) and kin beside it, the dog sweeps the pixel up to them, and
## the shove with the rest would press the kin, so it slides the step's
## size south, away from the chicken. It walked the pixel and the three.
expect {
	r = tick_of([dog(1000, 1000), crit(2, 255, 1025, 990), dog(1029, 1014)], 0, 3 * 256)
	tick_place(r, 0) == {
		x: 1001 * 256,
		y: 1003 * 256,
	} and r.bump.kind == Walk.bump_none and r.walked == 4 * 256
}

## Two poops touching ahead, one north of its line and one south, stop it
## alike: the lower slot is what stopped it (slot 1, south, listed second),
## so it slides north, away from that one.
expect {
	t = 14
	from = List.repeat(0, t + 1).concat(List.repeat(2, 36 - t))
	poops = [{ slot: 3, x: 1020 * 256, y: 995 * 256 }, { slot: 1, x: 1020 * 256, y: 1005 * 256 }]
	cs = [dog(1000, 1000)]
	r = Walk.pixel_tick(
		{ from, poops, side: Walk.side },
		{ depth: List.repeat(0, cs.len()), moving: [], park: park_of(cs) },
		0,
		256,
		0,
		0,
	)
	tick_place(r, 0) == { x: 1000 * 256, y: 999 * 256 } and r.bump.kind == Walk.bump_none
}

## Alone, the leashed dog walks no one, and is the pooper.
expect {
	r = walk_of([dog(1000, 1000)])
	r.work.moving == [0] and r.pooper == 0 and r.anchor == -1
}

## Kin 100 px east anchors on the leashed dog, 30 px past its band: it
## steps the pixel west, and is the herd's deepest, so the pooper.
expect {
	r = walk_of([dog(1000, 1000), dog(1100, 1000)])
	r.work.moving == [0, 1] and place(r, 1) == {
		x: 1099 * 256,
		y: 1000 * 256,
	} and r.pooper == 1 and r.anchor == 0
}

## The nearer is visited first, and lines up the farther, which then
## anchors on it (the nearer moving kin): the pooper is the farther,
## two deep. Both in the band: neither steps.
expect {
	r = walk_of([dog(1000, 1000), dog(1100, 1000), dog(1050, 1000)])
	r.work.moving == [0, 2, 1] and r.pooper == 1 and r.anchor == 2 and place(r, 1) == {
		x: 1100 * 256,
		y: 1000 * 256,
	}
}

## A cow 100 px from the leashed dog keeps 158 px from it, at half its
## pace: half a pixel east.
expect {
	r = walk_of([dog(1000, 1000), crit(1, 4, 1100, 1000)])
	place(r, 1) == { x: 1100 * 256 + 128, y: 1000 * 256 }
}

## A chicken touching the stepping dog's west side is shoved: the step,
## and as much again to the side (on the line: south).
expect {
	r = walk_of([dog(1000, 1000), dog(1100, 1000), crit(2, 255, 1076, 1000)])
	place(r, 1) == {
		x: 1099 * 256,
		y: 1000 * 256,
	} and place(r, 2) == { x: 1075 * 256, y: 1001 * 256 }
}

## A poop touching its west side vetoes the step; it sidesteps the pixel
## south instead.
expect {
	r = walk_poop([dog(1000, 1000), dog(1100, 1000)], 1080, 1000, 15)
	place(r, 1) == { x: 1100 * 256, y: 1001 * 256 }
}

## Kin 30 px east is inside its band (42 px): it steps the pixel east, away.
## A dog of another breed touching its east side (visited later, farther
## off) vetoes the step, and there is no sidestep round a dog: it stays.
expect {
	r = walk_of([dog(1000, 1000), dog(1030, 1000), crit(0, 1, 1058, 1000)])
	r.work.moving == [0, 1, 2] and place(r, 1) == { x: 1030 * 256, y: 1000 * 256 }
}

## Kin touching its east side instead is nudged along with it; visited
## next, that one keeps its own band from it (28 px, inside 42) and steps
## another pixel east.
expect {
	r = walk_of([dog(1000, 1000), dog(1030, 1000), dog(1058, 1000)])
	place(r, 1) == {
		x: 1031 * 256,
		y: 1000 * 256,
	} and place(r, 2) == { x: 1060 * 256, y: 1000 * 256 }
}

## A critter `x`, `y` in 256ths, not whole pixels.
dog_at = |x, y| { ..dog(0, 0), x, y }

## The walk with poops in tile `t`, slots in order.
walk_poops = |cs, ps, t| {
	from = List.repeat(0, t + 1).concat(List.repeat(ps.len().to_u16_wrap(), 36 - t))
	poops = ps.map_with_index(|q, k| { slot: k.to_u16_wrap(), x: q.x * 256, y: q.y * 256 })
	Walk.walk(
		{ from, poops, side: Walk.side },
		{ depth: List.repeat(0, cs.len()), moving: [], park: park_of(cs) },
		256,
	)
}

## Four kin 100 px off, one each way: three wait (the fan), the lower
## indexes on the tie, and the lowest is visited first.
expect {
	r = walk_of([dog(1000, 1000), dog(1100, 1000), dog(900, 1000), dog(1000, 900), dog(1000, 1100)])
	r.work.moving.get(1) == Ok(1)
}

## Two kin anchored on the leashed dog, one deep each: the pooper is the
## later visited.
expect {
	r = walk_of([dog(1000, 1000), dog(1100, 1000), dog(900, 1000)])
	r.work.moving == [0, 1, 2] and r.pooper == 2 and r.anchor == 0
}

## Two poops where the step would land: the lower slot's, north of the
## line, is the one it goes round, so it sidesteps south.
expect {
	r = walk_poops(
		[dog(1000, 1000), dog(1100, 1000)],
		[{ x: 1080, y: 995 }, { x: 1080, y: 1005 }],
		15,
	)
	place(r, 1) == { x: 1100 * 256, y: 1001 * 256 }
}

## A wish under a pixel is no step: kin 100 256ths past its band's outer
## edge stays.
expect {
	r = walk_of([dog(1000, 1000), dog_at(1070 * 256 + 100, 1000 * 256)])
	place(r, 1) == { x: 1070 * 256 + 100, y: 1000 * 256 }
}

## The line-up searches out ring by ring until it has three: kin in the
## leashed dog's own cell does not stop it short of two farther off, and
## the one nearer the leashed dog than to the first visited goes next.
expect {
	r = walk_of([dog(1000, 1000), dog(1045, 1000), dog(620, 1000), dog(1435, 1000)])
	r.work.moving == [0, 1, 2, 3]
}

## A chicken is never in the walk.
expect {
	r = walk_of([dog(1000, 1000), crit(2, 255, 1100, 1000)])
	r.work.moving == [0]
}

## The leashed dog lines up its three nearest, the third too, and a
## critter waits with the nearer of its keys: the kin 140 px west waits
## with 140 (the leashed dog's), not the 239 the east pair would give it,
## so it goes before the kin far east, which waits with 199.
expect {
	r = walk_of([
		dog(1000, 1000),
		dog(1100, 1000),
		dog(1130, 1000),
		dog(860, 1000),
		dog(1330, 1000),
	])
	r.work.moving == [0, 1, 2, 3, 4]
}

## Where the poop lands (`lay`), for crits `cs` and poops `ps` (each in
## slot its place in the list) all on tile `t`.
lay_of = |cs, ps, t, how| {
	from = List.repeat(0, t + 1).concat(List.repeat(ps.len().to_u16_wrap(), 36 - t))
	poops = ps.map(|q| { slot: q.slot, x: q.x * 256, y: q.y * 256 })
	Walk.lay({ from, poops, words: 1 }, cs, how)
}

lone = { anchor: -1, laid: 0, pooper: 0, step: { x: 0, y: 0 } }

## The pooper with no anchor and no step: its centre is "ahead", so it
## poops east, `back` (30 px) off; the slot is `laid` mod the slots.
expect lay_of([dog(1000, 1000)], [], 14, lone) == { slot: 0, x: 1030 * 256, y: 1000 * 256 }
expect lay_of(
	[dog(1000, 1000)],
	[],
	14,
	{ ..lone, laid: 2049 },
) == { slot: 1, x: 1030 * 256, y: 1000 * 256 }

## No anchor: back along the leashed dog's step (here west, its step east).
expect lay_of(
	[dog(1000, 1000)],
	[],
	14,
	{ ..lone, step: { x: 256, y: 0 } },
) == { slot: 0, x: 970 * 256, y: 1000 * 256 }

## Away from its anchor, each axis truncated toward zero: (-100, -33) px
## scaled to 30 px is (-30, -9.9), -2534.4 256ths, so -2534.
expect lay_of(
	[dog(1000, 1000), dog(1100, 1033)],
	[],
	14,
	{ ..lone, anchor: 1 },
) == { slot: 0, x: 970 * 256, y: 1000 * 256 - 2534 }

## **THE RING ORDER**: the spot (1030, 1000) taken by a poop, every ring
## point nearer than a poop's side (12 px) overlaps it; ring 12 px's
## north-west corner (1018, 988) overlaps the pooper (18 px off, under its
## half and the poop's, 20), so the first free is the next clockwise.
expect lay_of(
	[dog(1000, 1000)],
	[{ slot: 5, x: 1030, y: 1000 }],
	14,
	lone,
) == { slot: 0, x: 1022 * 256, y: 988 * 256 }

## The poop in the slot being laid is the one this takes the place of: it
## blocks nothing.
expect lay_of(
	[dog(1000, 1000)],
	[{ slot: 0, x: 1030, y: 1000 }],
	14,
	lone,
) == { slot: 0, x: 1030 * 256, y: 1000 * 256 }

## A critter blocks: a cow on the spot (half 21 px, the poop's 6) leaves
## free only ring 28 px, from its north-west corner.
expect lay_of(
	[dog(1000, 1000), crit(1, 4, 1030, 1000)],
	[],
	14,
	lone,
) == { slot: 0, x: 1002 * 256, y: 972 * 256 }

## The forage turn of crits `cs` with poops `ps` (each with its slot) all
## on tile `t`, each critter's home `away` px west of where it stands.
turn_of = |cs, ps, t, net, laid, away| {
	from = List.repeat(0, t + 1).concat(List.repeat(ps.len().to_u16_wrap(), 36 - t))
	poops = ps.map(|q| { slot: q.slot, x: q.x * 256, y: q.y * 256 })
	park = park_of(cs)
	Walk.forage_turn(
		{ from, poops, side: Walk.side },
		park,
		park.crits.map(|c| { x: c.x - away * 256, y: c.y }),
		[],
		net,
		laid,
	)
}

hen = |x, y| crit(2, 255, x, y)

## A chicken on a ripe poop eats it, but only when the leashed dog moved
## (`net`): a still dog stills the turn.
expect turn_of(
	[dog(500, 500), hen(1000, 1000)],
	[{ slot: 0, x: 1000, y: 1000 }],
	14,
	0,
	2,
	0,
).eaten == []
expect turn_of(
	[dog(500, 500), hen(1000, 1000)],
	[{ slot: 0, x: 1000, y: 1000 }],
	14,
	512,
	2,
	0,
).eaten == [0]

## The newest poop (slot `laid` - 1) is never eaten: a hen bound home
## (100 px west) steps off it, its sidestep tried, and eats nothing.
expect turn_of(
	[dog(500, 500), hen(1000, 1000)],
	[{ slot: 1, x: 1000, y: 1000 }],
	14,
	512,
	2,
	100,
).eaten == []

## Its home past the band (32 px): a hen with nothing to eat walks home
## 1 px (half the dog's 2 px); within the band it stays put.
expect {
	r = turn_of([dog(500, 500), hen(1000, 1000)], [], 14, 512, 2, 100)
	match r.park.crits.get(1) {
		Ok(c) => Walk.pt(c) == { x: 999 * 256, y: 1000 * 256 }
		Err(_) => Bool.False
	}
}
expect {
	r = turn_of([dog(500, 500), hen(1000, 1000)], [], 14, 512, 2, 32)
	match r.park.crits.get(1) {
		Ok(c) => Walk.pt(c) == { x: 1000 * 256, y: 1000 * 256 }
		Err(_) => Bool.False
	}
}

## Toward a ripe poop 100 px east: at most half the dog's net move (here
## 4 px of 8) and at most its step (8 px).
expect {
	r = turn_of(
		[dog(500, 500), hen(1000, 1000)],
		[{ slot: 0, x: 1100, y: 1000 }],
		14,
		8 * 256,
		2,
		0,
	)
	match r.park.crits.get(1) {
		Ok(c) => Walk.pt(c) == { x: 1004 * 256, y: 1000 * 256 }
		Err(_) => Bool.False
	}
}

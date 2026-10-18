## THE WALK (docs/PHYSICS.md, decisions 20-25, 30), in Roc: one
## pixel-tick's, after the leashed dog's step. Out from the leashed dog
## (seen index 0), shortest link first, dogs and cows only, at most
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

	## Seen critter `j`: where it stands, and the cell it stands in; its
	## square's half side; its kind (0 a dog, 1 a cow, 2 a chicken); its
	## kin, who it nudges and is nudged by (a dog its breed, a cow the
	## breeds' count: every cow is kin to every cow; a chicken 255, none);
	## and its key while it waits to be visited (-1 not lined up; -2
	## visited, or the leashed dog, which the walk starts from).
	Crit : { cell : U16, half : I32, key : I64, kin : U8, kind : U8, x : I32, y : I32 }

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
	biggest_half = (larger(larger(World.dog_px, World.cow_px), World.chicken_px) // 2 * 256).to_i32_wrap()

	larger : I64, I64 -> I64
	larger = |a, b| if (a > b) a else b

	## **THE CELLS** the critters are kept by (`Park`): a tile cut
	## `cell_per_tile` ways on each axis, so `side` cells a side of the
	## world, each `cell` a side; the physics' Zig keeps the same
	## (src/play/physics.zig's `Scene.seen_cells`), and says how many a
	## side it keeps (`Lent`), which the walk checks.
	cell_per_tile : I32
	cell_per_tile = 2

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
	walk_most = 48

	## How many each visited critter lines up: three (`Three`).
	walk_fan : U64
	walk_fan = 3

	## The most critters one step moves together, the stepper and the kin
	## it nudges; and the most chickens it shoves. Each a lane of a `Lanes`.
	nudge_most : U64
	nudge_most = 8

	## A wish shorter than this is no step: a pixel.
	dead_zone : I32
	dead_zone = 256

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
		var $w = work0
		$w = { ..$w, depth: put($w.depth, 0, 0), moving: $w.moving.append(0) }
		herd = (get_c($w.park.crits, 0)).kin
		$w = { ..$w, park: line_up(s, $w.park, 0) }
		var $pooper = 0
		var $anchor = -1
		var $count = 0
		var $going = Bool.True
		while $going and $count < walk_most {
			i = least_waiting($w.park.crits)
			if i < 0 {
				$going = Bool.False
			} else {
				iu = i.to_u64_wrap()
				me = get_c($w.park.crits, iu)
				$w = { ..$w, park: visit($w.park, iu, me) }
				wished = wish_of($w, iu)
				$w = { ..$w, moving: $w.moving.append(iu.to_u16_wrap()) }
				$count = $count + 1
				pace = if (me.kind == 1) Rules.cow.pace else Rules.dog.pace
				$w = { ..$w, park: step_around(s, $w.park, iu, step_at_most({ x: wished.x, y: wished.y }, share(pace, most))) }
				if me.kind == 0 and me.kin == herd and wished.anchor >= 0 {
					a = wished.anchor.to_u64_wrap()
					d = get_u16($w.depth, a) + 1
					$w = { ..$w, depth: put($w.depth, iu, d) }
					if d >= get_u16($w.depth, $pooper.to_u64_wrap()) {
						$pooper = i.to_i32_wrap()
						$anchor = wished.anchor
					} else {
						{}
					}
				} else {
					{}
				}
				$w = { ..$w, park: line_up(s, $w.park, iu) }
			}
		}
		{ anchor: $anchor, pooper: $pooper, work: $w }
	}

	## `pace` of `v`, rounded toward zero.
	share : Rules.Share, I32 -> I32
	share = |pace, v| if (pace.num == pace.den) v else (v.to_i64() * pace.num.to_i64() // pace.den.to_i64()).to_i32_wrap()

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
		p = pt(get_c(park.crits, from))
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
				top = if (2 * $r == n) $r - 1 else $r
				var $dy = (0 - $r)
				while $dy <= top {
					row = (pr + $dy).mod_by(n)
					if $dy == (0 - $r) or $dy == $r {
						var $dx = (0 - $r)
						while $dx <= top {
							$t = offer_cell(s, park, p, row * n + (pc + $dx).mod_by(n), $t)
							$dx = $dx + 1
						}
					} else {
						$t = offer_cell(s, park, p, row * n + (pc - $r).mod_by(n), $t)
						if $r > 0 and top == $r {
							$t = offer_cell(s, park, p, row * n + (pc + $r).mod_by(n), $t)
						} else {
							{}
						}
					}
					$dy = $dy + 1
				}
				$r = $r + 1
			}
		}
		{ cells, crits } = park
		{ cells, crits: crits |> offer($t.k1, $t.d1) |> offer($t.k2, $t.d2) |> offer($t.k3, $t.d3) }
	}

	## The dogs and cows of cell `c` not yet visited, offered to the three
	## nearest `p`.
	offer_cell : Seen, Park, Pt, I32, Three -> Three
	offer_cell = |s, park, p, c, t0| {
		var $t = t0
		base = c.to_u64_wrap() * s.words
		var $w = 0
		while $w < s.words {
			var $bits = get_u64(park.cells, base + $w)
			while $bits != 0 {
				j = $w * 64 + $bits.count_trailing_zero_bits().to_u64()
				o = get_c(park.crits, j)
				if o.key != -2 and o.kind != 2 {
					$t = nearer($t, measure(delta(pt(o), p)), j.to_i64_wrap())
				} else {
					{}
				}
				$bits = $bits.bitwise_and($bits - 1)
			}
			$w = $w + 1
		}
		$t
	}

	## Critter `i`, `me`, is visited.
	visit : Park, U64, Crit -> Park
	visit = |park, i, me| {
		{ cells, crits } = park
		{ cells, crits: put(crits, i, { ..me, key: -2 }) }
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
	wish_of : Work, U64 -> Wish.Out
	wish_of = |w, i| {
		crits = w.park.crits
		me = get_c(crits, i)
		Wish.wish_by(
			{ half: me.half, kind: me.kind },
			w.moving.len(),
			|k| {
				j = get_u16(w.moving, k)
				o = get_c(crits, j.to_u64())
				tx = short(o.x - me.x)
				ty = short(o.y - me.y)
				{
					ax: back(tx),
					ay: back(ty),
					half: o.half,
					tx,
					ty,
					j,
					kin: me.kind == 0 and o.kind == 0 and o.kin == me.kin,
					kind: o.kind,
				}
			},
		)
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

	## Why a step was vetoed (`why`: 0 nothing, it went; 1 a critter it may
	## not press; 2 a chicken it can't shove; 3 a poop); and where the
	## critter that was blocked stood, and its blocker.
	Veto : { at : Pt, blocker : Pt, why : U8 }

	went : Veto
	went = { at: { x: 0, y: 0 }, blocker: { x: 0, y: 0 }, why: 0 }

	## Critter `i` takes `step` (`step_whole`); vetoed by a poop, or by a
	## chicken it can't shove, it tries once more with `sidestep`'s.
	step_around : Seen, Park, U64, Pt -> Park
	step_around = |s, park, i, step| {
		r = step_whole(s, park, i, step)
		if r.veto.why == 2 or r.veto.why == 3 {
			(step_whole(s, r.park, i, sidestep(r.veto, step))).park
		} else {
			r.park
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
			grouped = gather(s, park, i, step)
			if grouped.veto.why != 0 {
				{ park, veto: grouped.veto }
			} else {
				cannot = shove_veto(s, park, step, grouped)
				if cannot.why != 0 {
					{ park, veto: cannot }
				} else {
					{ park: move_all(s, park, step, grouped), veto: went }
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
	gather : Seen, Park, U64, Pt -> Group
	gather = |s, park, i, step| {
		breed = (get_c(park.crits, i)).kin
		var $g = { by: 0, group: lane_put(0, 0, i), n: 1, ns: 0, shoved: 0, veto: went }
		var $k = 0
		while $k < $g.n and $g.veto.why == 0 {
			gk = lane_get($g.group, $k)
			me = get_c(park.crits, gk)
			from = pt(me)
			to = plus(from, step)
			h = me.half
			match poop_under(s, to, h) {
				Found(q) => {
					$g = { ..$g, veto: { at: from, blocker: q, why: 3 } }
				}
				Clear => {
					near = square_of(to, h + biggest_half)
					var $w = 0
					while $w < s.words and $g.veto.why == 0 {
						var $bits = near_word(s, park, near, $w)
						while $bits != 0 and $g.veto.why == 0 {
							j = $w * 64 + $bits.count_trailing_zero_bits().to_u64()
							o = get_c(park.crits, j)
							if overlap(to, h, pt(o), o.half) and !in_move($g, j) {
								if o.kind == 2 {
									if $g.ns == nudge_most {
										$g = { ..$g, veto: { at: from, blocker: pt(o), why: 2 } }
									} else {
										$g = { ..$g, shoved: lane_put($g.shoved, $g.ns, j), by: lane_put($g.by, $g.ns, gk), ns: $g.ns + 1 }
									}
								} else if j == 0 or o.kin != breed or $g.n == nudge_most {
									$g = { ..$g, veto: { at: from, blocker: pt(o), why: 1 } }
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
		$g
	}

	## Whether seen critter `j` is in the move: in the group, or shoved.
	in_move : Group, U64 -> Bool
	in_move = |g, j| lanes_hold(g.group, g.n, j) or lanes_hold(g.shoved, g.ns, j)

	## Where shoved chicken `m` lands: its point plus the step, plus the
	## step turned toward its side of its shover's centre line.
	land_of : List(Crit), Pt, Group, U64 -> Pt
	land_of = |crits, step, g, m| {
		p = pt(get_c(crits, lane_get(g.shoved, m)))
		wrapped(plus(plus(p, step), shove_aside(step, delta(pt(get_c(crits, lane_get(g.by, m))), p))))
	}

	## The veto of the first shove that cannot land: on a poop, on a critter
	## not in the move, on one of the group where it steps to, or on a
	## chicken shoved before it.
	shove_veto : Seen, Park, Pt, Group -> Veto
	shove_veto = |s, park, step, g| {
		crits = park.crits
		var $v = went
		var $m = 0
		while $m < g.ns and $v.why == 0 {
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
				$v = { at: pt(get_c(crits, lane_get(g.by, $m))), blocker: pt(c), why: 2 }
			} else {
				{}
			}
			$m = $m + 1
		}
		$v
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

	## Seen critter `j` to `p` (in the world), and into its cell there.
	move_to : Seen, Park, U64, Pt -> Park
	move_to = |s, park, j, p| {
		{ cells, crits: crits0 } = park
		c = get_c(crits0, j)
		now_in = ((p.y // cell) * side + p.x // cell).to_u16_wrap()
		crits = put(crits0, j, { ..c, x: p.x, y: p.y, cell: now_in })
		if now_in == c.cell {
			{ cells, crits }
		} else {
			bit = (1).shl_wrap((j % 64).to_u8_wrap())
			was = c.cell.to_u64() * s.words + j // 64
			now = now_in.to_u64() * s.words + j // 64
			left = get_u64(cells, was).bitwise_and(bit.bitwise_not())
			cells1 = put(cells, was, left)
			came = get_u64(cells1, now).bitwise_or(bit)
			{ crits, cells: put(cells1, now, came) }
		}
	}

	## Where a critter stands.
	pt : Crit -> Pt
	pt = |c| { x: c.x, y: c.y }

	## The cells a square `reach` either way of `p` meets, on each axis.
	Square : { cols : Span, rows : Span }

	square_of : Pt, I32 -> Square
	square_of = |p, reach| { cols: span(p.x, reach, cell, side), rows: span(p.y, reach, cell, side) }

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
					if ($best < 0 or slot < $best) and overlap(p, h, { x: q.x, y: q.y }, poop_half) {
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
	{ cell: 0, half, key: -1, kin, kind, x: x * 256, y: y * 256 }
}

dog = |x, y| crit(0, 0, x, y)

one : U64
one = 1

## The park of `cs`: each in its cell, the leashed dog visited.
park_of = |cs| {
	var $cells = List.repeat(0, (Walk.side * Walk.side).to_u64_wrap())
	var $crits = []
	var $j = 0
	for c in cs {
		cl = (c.y // Walk.cell) * Walk.side + c.x // Walk.cell
		$crits = $crits.append({ ..c, cell: cl.to_u16_wrap(), key: if ($j == 0) -2 else -1 })
		$cells = $cells.update(cl.to_u64_wrap(), |w| w.bitwise_or(one.shl_wrap($j.to_u8_wrap()))) ?? $cells
		$j = $j + 1
	}
	{ cells: $cells, crits: $crits }
}

## The walk of `cs` with no poop, or with one poop at `(px, py)` px in
## tile `t` (row by row, 350 px tiles).
walk_of = |cs| Walk.walk({ from: List.repeat(0, 37), poops: [], side: Walk.side }, { depth: List.repeat(0, cs.len()), moving: [], park: park_of(cs) }, 256)

walk_poop = |cs, px, py, t| {
	from = List.repeat(0, t + 1).concat(List.repeat(1, 36 - t))
	Walk.walk({ from, poops: [{ slot: 0, x: px * 256, y: py * 256 }], side: Walk.side }, { depth: List.repeat(0, cs.len()), moving: [], park: park_of(cs) }, 256)
}

place = |r, j| match r.work.park.crits.get(j) {
	Ok(c) => Walk.pt(c)
	Err(_) => Walk.pt({ cell: 0, half: 0, key: 0, kin: 0, kind: 0, x: -1, y: -1 })
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
	r.work.moving == [0, 1] and place(r, 1) == { x: 1099 * 256, y: 1000 * 256 } and r.pooper == 1 and r.anchor == 0
}

## The nearer is visited first, and lines up the farther, which then
## anchors on it (the nearer moving kin): the pooper is the farther,
## two deep. Both in the band: neither steps.
expect {
	r = walk_of([dog(1000, 1000), dog(1100, 1000), dog(1050, 1000)])
	r.work.moving == [0, 2, 1] and r.pooper == 1 and r.anchor == 2 and place(r, 1) == { x: 1100 * 256, y: 1000 * 256 }
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
	place(r, 1) == { x: 1099 * 256, y: 1000 * 256 } and place(r, 2) == { x: 1075 * 256, y: 1001 * 256 }
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
	place(r, 1) == { x: 1031 * 256, y: 1000 * 256 } and place(r, 2) == { x: 1060 * 256, y: 1000 * 256 }
}

## A critter `x`, `y` in 256ths, not whole pixels.
dog_at = |x, y| { ..dog(0, 0), x, y }

## The walk with poops in tile `t`, slots in order.
walk_poops = |cs, ps, t| {
	from = List.repeat(0, t + 1).concat(List.repeat(ps.len().to_u16_wrap(), 36 - t))
	poops = ps.map_with_index(|q, k| { slot: k.to_u16_wrap(), x: q.x * 256, y: q.y * 256 })
	Walk.walk({ from, poops, side: Walk.side }, { depth: List.repeat(0, cs.len()), moving: [], park: park_of(cs) }, 256)
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
	r = walk_poops([dog(1000, 1000), dog(1100, 1000)], [{ x: 1080, y: 995 }, { x: 1080, y: 1005 }], 15)
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
	r = walk_of([dog(1000, 1000), dog(1100, 1000), dog(1130, 1000), dog(860, 1000), dog(1330, 1000)])
	r.work.moving == [0, 1, 2, 3, 4]
}

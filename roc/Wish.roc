## WHAT A CRITTER WANTS (docs/PHYSICS.md, decisions 21-24), in Roc: its
## wish, from the moving critters it sees, by the rules (Rules.roc). The
## physics' Zig calls it for each critter the walk visits
## (src/play/physics.zig's `wishOf`, through roc/physics.roc), handing it
## only what the arithmetic needs: who each one is to the wisher, and the
## two vectors between them, already the short way round the world. All
## lengths are in 256ths of a pixel; a length is a vector's larger axis.

import Rules

Wish := [].{

	## One moving critter the wisher sees. `kind`: 0 a dog, 1 a cow, 2 a
	## chicken (physics.zig's `Kind`); `kin`: a dog of the wisher's own
	## breed, and the wisher a dog; `j`: its seen index, for ties (to the
	## lower); `half`: its square's half side; `ax, ay`: from it to the
	## wisher (away), `tx, ty`: from the wisher to it (toward). The two are
	## each other's negation but where an axis is half a world.
	Near : { ax : I32, ay : I32, half : I32, tx : I32, ty : I32, j : U16, kin : Bool, kind : U8 }

	## The wisher: its kind, as `Near`'s, and its square's half side.
	Me : { half : I32, kind : U8 }

	## What it wants: a step `x, y`, and its anchor, the `j` of the critter a
	## `Herd` answer chose, or -1.
	Out : { anchor : I32, x : I32, y : I32 }

	wish : Me, List(Near) -> Out
	wish = |me, near| wish_by(
		me,
		near.len(),
		|k| match near.get(k) {
			Ok(n) => n
			Err(_) => nobody
		},
	)

	## No critter: what `wish` reads past a list's end (it never does).
	nobody : Near
	nobody = { ax: 0, ay: 0, half: 0, tx: 0, ty: 0, j: 0, kin: Bool.False, kind: 0 }

	## The wish from `count` critters, the `k`th `near_at(k)`: for a caller
	## that holds them otherwise than as a list (roc/Walk.roc, which makes
	## each from the walk's own lists as it is read).
	wish_by : Me, U64, (U64 -> Near) -> Out
	wish_by = |me, count, near_at| {
		sees = if (me.kind == 1) Rules.cow else Rules.dog

		## The summed answers; the anchor (the nearest critter a `Herd`
		## answer named; -1, none), its distance and band; and for
		## `Nearest`, the nearest so far (-1, none yet).
		var $x = 0
		var $y = 0
		var $anchor = -1
		var $anchor_d = 0
		var $inner = 0
		var $outer = 0
		var $a = nobody
		var $best = nobody
		var $best_d = -1
		var $k = 0
		while $k < count {
			n = near_at($k)
			$k = $k + 1
			match sees.gathers {
				Each => {
					rule = rule_for(sees, n)
					match rule {
						Herd({ inner, outer }) => {
							d = measure(n.ax.to_i64(), n.ay.to_i64())
							j = n.j.to_i64()
							if $anchor < 0 or d < $anchor_d or (d == $anchor_d and j < $anchor) {
								$anchor = j
								$anchor_d = d
								$inner = px(inner)
								$outer = px(outer)
								$a = n
							} else {
								{}
							}
						}
						_ => {
							w = contrib(rule, me, n)
							$x = $x + w.x
							$y = $y + w.y
						}
					}
				}
				Nearest => {
					d = measure(n.ax.to_i64(), n.ay.to_i64())
					if $best_d < 0 or d < $best_d or (d == $best_d and n.j < $best.j) {
						$best = n
						$best_d = d
					} else {
						{}
					}
				}
			}
		}
		if $best_d >= 0 {
			n = $best
			rule = rule_for(sees, n)
			match rule {
				Herd({ inner, outer }) => {
					$anchor = n.j.to_i64()
					$anchor_d = $best_d
					$inner = px(inner)
					$outer = px(outer)
					$a = n
				}
				_ => {
					w = contrib(rule, me, n)
					$x = $x + w.x
					$y = $y + w.y
				}
			}
		} else {
			{}
		}
		band = if $anchor < 0 {
			{ x: 0, y: 0 }
		} else if $anchor_d > $outer {
			along($a.tx.to_i64(), $a.ty.to_i64(), $anchor_d - $outer)
		} else if $anchor_d < $inner {
			away($a.ax.to_i64(), $a.ay.to_i64(), $inner - $anchor_d)
		} else {
			{ x: 0, y: 0 }
		}
		{ anchor: $anchor.to_i32_wrap(), x: ($x + band.x).to_i32_wrap(), y: ($y + band.y).to_i32_wrap() }
	}

	## The rule for who `n` is to the wisher.
	rule_for : Rules.Sees, Near -> Rules.Rule
	rule_for = |sees, n| if (n.kind == 0 and n.kin) sees.kin else if (n.kind == 0) sees.dog else if (n.kind == 1) sees.cow else sees.chicken

	## What a rule but `Herd` (the anchor's, gathered above) adds.
	contrib : Rules.Rule, Me, Near -> { x : I64, y : I64 }
	contrib = |rule, me, n| {
		ax = n.ax.to_i64()
		ay = n.ay.to_i64()
		match rule {
			Keep(reach) => {
				d = measure(ax, ay)
				r = px(reach)
				if (d > r) { x: 0, y: 0 } else away(ax, ay, r - d)
			}
			Close(reach) => {
				d = measure(ax, ay)
				touch = me.half.to_i64() + n.half.to_i64()
				if (d > touch and d <= px(reach)) along(n.tx.to_i64(), n.ty.to_i64(), d - touch) else { x: 0, y: 0 }
			}
			_ => { x: 0, y: 0 }
		}
	}

	## Whole pixels to 256ths.
	px : I64 -> I64
	px = |n| n * 256

	## A vector's length: its larger axis.
	measure : I64, I64 -> I64
	measure = |x, y| {
		mx = x.abs()
		my = y.abs()
		if (mx > my) mx else my
	}

	## A wish `length` long along `(vx, vy)`: each axis times the length,
	## divided by the vector's length, truncated toward zero.
	along : I64, I64, I64 -> { x : I64, y : I64 }
	along = |vx, vy, length| {
		l = measure(vx, vy)
		{ x: vx * length // l, y: vy * length // l }
	}

	## A wish `length` long along the away vector; east when the critters'
	## centres coincide.
	away : I64, I64, I64 -> { x : I64, y : I64 }
	away = |vx, vy, length| if (vx == 0 and vy == 0) { x: length, y: 0 } else along(vx, vy, length)
}

## Pure-Roc checks of the wish, in 256ths (158 px is 40448).
dog_me = { half: 14 * 256, kind: 0 }

cow_me = { half: 21 * 256, kind: 1 }

nb = |kind, kin, j, x, y| { ax: -x, ay: -y, half: if (kind == 1) 21 * 256 else 14 * 256, tx: x, ty: y, j: j, kin: kin, kind: kind }

## Alone, a critter wants nothing.
expect Wish.wish(dog_me, []) == { anchor: -1, x: 0, y: 0 }

## A dog of another breed 100 px east: room `wary` (158 px) from it, so 58 px
## west.
expect Wish.wish(dog_me, [nb(0, Bool.False, 3, 100 * 256, 0)]) == { anchor: -1, x: -58 * 256, y: 0 }

## Farther than `wary`, nothing.
expect Wish.wish(dog_me, [nb(0, Bool.False, 3, 200 * 256, 0)]) == { anchor: -1, x: 0, y: 0 }

## Its kin 100 px east is its anchor, past the band's outer edge (70 px): it
## closes the 30 px.
expect Wish.wish(dog_me, [nb(0, Bool.True, 5, 100 * 256, 0)]) == { anchor: 5, x: 30 * 256, y: 0 }

## Of two kin the nearer anchors; at an equal distance, the lower index.
expect Wish.wish(dog_me, [nb(0, Bool.True, 9, 60 * 256, 0), nb(0, Bool.True, 4, 0, 60 * 256)]).anchor == 4

## A cow heeds only its nearest: a cow 100 px east (within 245) draws it
## toward touching (42 px apart), though a dog 150 px west would scare it.
expect Wish.wish(cow_me, [nb(1, Bool.False, 2, 100 * 256, 0), nb(0, Bool.False, 7, -150 * 256, 0)]) == { anchor: -1, x: 58 * 256, y: 0 }

## Coinciding centres: away is east.
expect Wish.wish(dog_me, [nb(0, Bool.False, 3, 0, 0)]) == { anchor: -1, x: 158 * 256, y: 0 }

## Inside the band's inner edge (42 px), it opens the shortfall: kin 30 px
## east, so 12 px west; in the band (42 to 70), content.
expect Wish.wish(dog_me, [nb(0, Bool.True, 5, 30 * 256, 0)]) == { anchor: 5, x: -12 * 256, y: 0 }
expect Wish.wish(dog_me, [nb(0, Bool.True, 5, 55 * 256, 0)]) == { anchor: 5, x: 0, y: 0 }

## A dog keeps 63 px from a cow, and the rooms add: a cow 50 px north and
## a dog of another breed 150 px east, so 13 px south and 8 px west.
expect Wish.wish(dog_me, [nb(1, Bool.False, 2, 0, -50 * 256), nb(0, Bool.False, 3, 150 * 256, 0)]) == { anchor: -1, x: -8 * 256, y: 13 * 256 }

## The room and the anchor together: kin 100 px east (closes 30) and a dog
## of another breed 150 px east (8 west): 22 px east.
expect Wish.wish(dog_me, [nb(0, Bool.True, 5, 100 * 256, 0), nb(0, Bool.False, 3, 150 * 256, 0)]) == { anchor: 5, x: 22 * 256, y: 0 }

## A chicken is nothing to a dog.
expect Wish.wish(dog_me, [nb(2, Bool.False, 40, 10 * 256, 0)]) == { anchor: -1, x: 0, y: 0 }

## A cow touching (42 px) or past its pull (245 px) is drawn no closer; a
## dog nearest, it flees by the shortfall inside `wary`.
expect Wish.wish(cow_me, [nb(1, Bool.False, 2, 42 * 256, 0)]) == { anchor: -1, x: 0, y: 0 }
expect Wish.wish(cow_me, [nb(1, Bool.False, 2, 246 * 256, 0)]) == { anchor: -1, x: 0, y: 0 }
expect Wish.wish(cow_me, [nb(0, Bool.False, 7, 0, 100 * 256)]) == { anchor: -1, x: 0, y: -58 * 256 }

## A cow's nearest, at an equal distance, is the lower index: the cow (2,
## east) before the dog (7, north), so it closes in east rather than flees
## south.
expect Wish.wish(cow_me, [nb(0, Bool.False, 7, 0, -100 * 256), nb(1, Bool.False, 2, 100 * 256, 0)]) == { anchor: -1, x: 58 * 256, y: 0 }

## A wish along a diagonal is each axis scaled and truncated toward zero:
## a dog of another breed 100 px east and 37 px south, 58 px short, so
## -58 px and -(37 * 58 / 100) px, truncated: -21.46 px is -5493 256ths.
expect Wish.wish(dog_me, [nb(0, Bool.False, 3, 100 * 256, 37 * 256)]) == { anchor: -1, x: -58 * 256, y: -5493 }

## The vectors as given: the away vector is used for room, the toward one
## for closing in, so at half a world (where both point the same way) each
## rule reads its own.
expect Wish.wish(dog_me, [{ ax: 100 * 256, ay: 0, half: 14 * 256, tx: 100 * 256, ty: 0, j: 3, kin: Bool.False, kind: 0 }]) == { anchor: -1, x: 58 * 256, y: 0 }

## The pull reaches its edge: a cow exactly 245 px east draws it.
expect Wish.wish(cow_me, [nb(1, Bool.False, 2, 245 * 256, 0)]) == { anchor: -1, x: 203 * 256, y: 0 }

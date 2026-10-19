## THE NEIGHBOUR GRID: a square grid of `side` by `side` cells round a
## torus, each holding a set of indexes, `words` 64-bit words a cell, in
## one flat list: cell `c`'s set at `cells[c * words ..]`, index `j` bit
## `j % 64` of its word `j / 64`. Who owns the list keeps it: insert, move
## and query a square; it never allocates once it has its room.
Grid := [].{

	## Index `j` into cell `c`.
	insert : List(U64), U64, U64, U64 -> List(U64)
	insert = |cells, words, c, j| {
		at = c * words + j // 64
		set(cells, at, get(cells, at).bitwise_or(bit_of(j)))
	}

	## Index `j` from cell `was` to another cell `now`.
	move : List(U64), U64, U64, U64, U64 -> List(U64)
	move = |cells, words, was, now, j| {
		b = bit_of(j)
		from = was * words + j // 64
		to = now * words + j // 64
		left = set(cells, from, get(cells, from).bitwise_and(b.bitwise_not()))
		set(left, to, get(left, to).bitwise_or(b))
	}

	## Word `w` of cell `c`'s set.
	word : List(U64), U64, U64, U64 -> U64
	word = |cells, words, c, w| get(cells, c * words + w)

	## A run of `n` cells from `lo` on one axis, round the torus.
	Span : { lo : I32, n : I32 }

	## Word `w` of the union of the sets of the cells in `cols` by `rows`.
	square_word : List(U64), U64, I32, Span, Span, U64 -> U64
	square_word = |cells, words, side, cols, rows, w| {
		var $u = 0
		var $r = 0
		while $r < rows.n {
			row = (rows.lo + $r).mod_by(side)
			var $c = 0
			while $c < cols.n {
				c = row * side + (cols.lo + $c).mod_by(side)
				$u = $u.bitwise_or(get(cells, c.to_u64_wrap() * words + w))
				$c = $c + 1
			}
			$r = $r + 1
		}
		$u
	}

	bit_of : U64 -> U64
	bit_of = |j| one.shl_wrap((j % 64).to_u8_wrap())

	one : U64
	one = 1

	## An index is always in range (the owner sizes the list); out of
	## range is a bug.
	get : List(U64), U64 -> U64
	get = |l, i| match l.get(i) {
		Ok(v) => v
		Err(_) => crash "Grid: no cell word there"
	}

	set : List(U64), U64, U64 -> List(U64)
	set = |l, i, v| match l.set(i, v) {
		Ok(m) => m
		Err(_) => crash "Grid: no cell word there"
	}
}

expect {
	g0 = List.repeat(0, 8)
	g1 = Grid.insert(g0, 2, 1, 70)
	g2 = Grid.move(g1, 2, 1, 3, 70)
	Grid.word(g2, 2, 1, 1) == 0 and Grid.word(g2, 2, 3, 1) == 64
}

expect {
	## 2 by 2 cells, one word: index 0 in cell 3; the square from col 1, 2
	## wide, round the torus, meets it.
	g = Grid.insert(List.repeat(0, 4), 1, 3, 0)
	Grid.square_word(g, 1, 2, { lo: 1, n: 2 }, { lo: 1, n: 1 }, 0) == 1
}

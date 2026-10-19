app [flip] { pf: platform "./platform/main.roc" }

import Grid

one : U64
one = 1

## The same bit set three ways: 0 written here, 1 by a function of this
## module, 2 by Grid.roc's.
flip : I64, List(U64), U64 -> List(U64)
flip = |mode, l, j| {
	if mode == 0 {
		w = match l.get(j // 64) {
			Ok(v) => v
			Err(_) => 0
		}
		match l.set(j // 64, w.bitwise_or(one.shl_wrap((j % 64).to_u8_wrap()))) {
			Ok(out) => out
			Err(_) => crash "out of range"
		}
	} else if mode == 1 {
		local_set(l, j)
	} else if mode == 2 {
		Grid.set_bit(l, j)
	} else {
		m = Grid.set_bit(l, j)
		if l.len() > 3 {
			m
		} else {
			l
		}
	}
}

local_set : List(U64), U64 -> List(U64)
local_set = |l, j| {
	w = match l.get(j // 64) {
		Ok(v) => v
		Err(_) => 0
	}
	match l.set(j // 64, w.bitwise_or(one.shl_wrap((j % 64).to_u8_wrap()))) {
		Ok(out) => out
		Err(_) => crash "out of range"
	}
}

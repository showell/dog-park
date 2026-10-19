Grid := [].{
	set_bit : List(U64), U64 -> List(U64)
	set_bit = |l, j| {
		w = match l.get(j // 64) {
			Ok(v) => v
			Err(_) => 0
		}
		match l.set(j // 64, w.bitwise_or(one.shl_wrap((j % 64).to_u8_wrap()))) {
			Ok(out) => out
			Err(_) => crash "out of range"
		}
	}

	one : U64
	one = 1
}

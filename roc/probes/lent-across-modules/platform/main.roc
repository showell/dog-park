platform ""
	requires {
		flip : I64, List(U64), U64 -> List(U64)
	}
	exposes []
	packages {}
	provides { "roc_flip": flip_for_host }
	targets: {
		x64musl: {
			inputs: [app],
			output: Archive,
		},
	}

flip_for_host : I64, List(U64), U64 -> List(U64)
flip_for_host = flip

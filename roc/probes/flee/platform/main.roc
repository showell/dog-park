platform ""
	requires {
		flee : I32, I32, I32, I32 -> { x : I32, y : I32 }
	}
	exposes []
	packages {}
	provides { "roc_flee": flee_for_host }
	targets: {
		x64musl: {
			inputs: [app],
			output: Archive,
		},
		x64glibc: {
			inputs: [app],
			output: Archive,
		},
		wasm32: {
			inputs: [app],
			output: Archive,
		},
		x64elf: {
			inputs: [app],
			output: Archive,
		},
	}

flee_for_host : I32, I32, I32, I32 -> { x : I32, y : I32 }
flee_for_host = |dx, dy, cx, cy| flee(dx, dy, cx, cy)

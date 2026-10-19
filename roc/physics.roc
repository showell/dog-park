## THE PHYSICS IN ROC, as the app its Zig links (roc/platform/main.roc).
app [walk] { pf: platform "./platform/main.roc" }

import Walk

## One pixel-tick (Walk.roc's `pixel_tick`: the leashed dog's step, then
## the walk), its arguments unpacked into Walk.roc's records and its result
## laid flat for the host.
walk = |axis, inc, side, from, poops, cells, crits, depth, moving| {
	r = Walk.pixel_tick({ from, poops, side }, { depth, moving, park: { cells, crits } }, axis, inc)
	{ anchor: r.walk.anchor, bump_at: r.bump.at, bump_kind: r.bump.kind, cells: r.walk.work.park.cells, crits: r.walk.work.park.crits, depth: r.walk.work.depth, moving: r.walk.work.moving, pooper: r.walk.pooper, step_x: r.step.x, step_y: r.step.y, walked: r.walked }
}

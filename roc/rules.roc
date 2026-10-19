## THE RULES, printed for the physics' Zig: `zig build roc` runs this
## (`roc roc/rules.roc -- zon`) and checks in what it prints,
## src/play/rules.zon, which src/play/rules.zig imports as `Rules`. The
## rules themselves are roc/Rules.roc's.

import Rules

zon_share : Rules.Share -> Str
zon_share = |sh| ".{ .num = ${sh.num.to_str()}, .den = ${sh.den.to_str()} }"

zon_chickens : Rules.Forage -> Str
zon_chickens = |c| ".{ .sight = ${c.sight.to_str()}, .step = ${c.step.to_str()}, .pace = ${zon_share(c.pace)}, .home_band = ${c.home_band.to_str()} }"

zon_poop : Rules.Poop -> Str
zon_poop = |p| ".{ .every = ${p.every.to_str()}, .back = ${p.back.to_str()}, .reach = ${p.reach.to_str()}, .grid = ${p.grid.to_str()}, .slots = ${p.slots.to_str()} }"

zon_limits : Rules.Limits -> Str
zon_limits = |l| ".{ .most = ${l.most.to_str()}, .nudge_most = ${l.nudge_most.to_str()}, .dead_zone = ${l.dead_zone.to_str()} }"

zon : Str
zon =
	\\// THE RULES, printed by roc/rules.roc (`zig build roc`): do not edit;
	\\// edit that and print it again. Read by src/play/rules.zig.
	\\.{
	\\    .wary = ${Rules.wary.to_str()},
	\\    .chickens = ${zon_chickens(Rules.chickens)},
	\\    .poop = ${zon_poop(Rules.poop)},
	\\    .limits = ${zon_limits(Rules.limits)},
	\\}
	\\

main! = |args| {
	match args {
		["zon"] => echo!(zon)
		_ => crash "roc/rules.roc: say `zon`"
	}
	Ok({})
}

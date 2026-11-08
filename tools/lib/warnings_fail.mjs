// Preloaded into every node run zig build makes (`node --import`): a
// warning node raises (a deprecation, an experimental API) is printed as
// node prints it, and fails the run, so no gate passes over one. A type the
// command line names with `--disable-warning=<type>` is not printed by node,
// and still reaches this listener, so it is passed over here too. The exit
// code is set on the way out, as a script may set its own after the warning.
const disabled = new Set(process.execArgv.filter((a) => a.startsWith("--disable-warning=")).map((a) => a.slice("--disable-warning=".length)));
let warned = false;
process.on("warning", (w) => {
  if (!disabled.has(w.name)) warned = true;
});
process.on("exit", () => {
  if (warned) process.exitCode = 1;
});

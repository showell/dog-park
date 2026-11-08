// Preloaded into every node run zig build makes (`node --import`): a
// warning node raises (a deprecation, an experimental API) is printed as
// node prints it, and fails the run, so no gate passes over one. The one
// warning passed over is node's WASI saying it is experimental, by its type
// and its exact words: tools/run_wasi.mjs runs the physics' tests under
// WASI, and node says so on every run. The exit code is set on the way
// out, as a script may set its own after the warning.
const wasi_is_experimental = "WASI is an experimental feature and might change at any time";
let warned = false;
process.on("warning", (w) => {
  if (!(w.name === "ExperimentalWarning" && w.message === wasi_is_experimental)) warned = true;
});
process.on("exit", () => {
  if (warned) process.exitCode = 1;
});

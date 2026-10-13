// Runs a wasm32-wasi program (a Zig test binary) under node's WASI, its
// exit code the program's: `zig build physics-wasm` runs the physics' tests
// this way, compiled for the page's architecture.
//
//   node tools/run_wasi.mjs <program.wasm> [args...]
import { readFileSync } from "node:fs";
import { WASI } from "node:wasi";

const [file, ...args] = process.argv.slice(2);
const wasi = new WASI({ version: "preview1", args: [file, ...args], env: {}, returnOnExit: true });
const { instance } = await WebAssembly.instantiate(readFileSync(file), wasi.getImportObject());
process.exitCode = wasi.start(instance);

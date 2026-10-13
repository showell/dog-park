// A scratch play server for the node tests: zig-out/bin/dog-park-play
// (built by `zig build`) on a free port with a temporary data dir, spawned
// as one process and stopped by its PID, never by a pattern.

import { spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";

export const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const binary = join(root, "zig-out/bin/dog-park-play");

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

async function spawnOn(dir, port) {
  const child = spawn(binary, [], {
    cwd: root,
    env: { ...process.env, DOGPARK_PORT: String(port), DOGPARK_BIND: "127.0.0.1", DOGPARK_CONFIG: join(dir, "config") },
    stdio: ["ignore", "ignore", "pipe"],
  });
  let log = "";
  child.stderr.on("data", (d) => (log += d));
  for (let i = 0; i < 100; i++) {
    if (child.exitCode !== null) throw new Error(`the server stopped:\n${log}`);
    try {
      await fetch(`http://127.0.0.1:${port}/`);
      return { child, log: () => log };
    } catch {
      await new Promise((r) => setTimeout(r, 50));
    }
  }
  process.kill(child.pid, "SIGTERM");
  throw new Error(`the server never answered:\n${log}`);
}

/** A fresh server on a fresh data dir: { base, post(path, text), restart(), stop() }. */
export async function scratchServer() {
  const dir = mkdtempSync(join(tmpdir(), "dogpark-scratch-"));
  writeFileSync(join(dir, "config"), `data_dir=${join(dir, "data")}\nauth_dir=${join(dir, "auth")}\n`);
  // The host's second root: webbox opens it; Dog Park keeps nothing there.
  mkdirSync(join(dir, "auth"));
  const port = await freePort();
  const base = `http://127.0.0.1:${port}`;
  let server = await spawnOn(dir, port);
  const stopIt = async () => {
    if (server.child.exitCode !== null) return;
    const gone = new Promise((r) => server.child.once("exit", r));
    process.kill(server.child.pid, "SIGTERM");
    await gone;
  };
  return {
    base,
    dir,
    log: () => server.log(),
    async post(path, text) {
      const r = await fetch(base + path, { method: "POST", body: text });
      return { status: r.status, text: await r.text() };
    },
    async get(path) {
      const r = await fetch(base + path);
      return { status: r.status, headers: r.headers, body: Buffer.from(await r.arrayBuffer()) };
    },
    async restart() {
      await stopIt();
      server = await spawnOn(dir, port);
    },
    async stop() {
      await stopIt();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

// A scratch play server for the node tests: zig-out/bin/dog-park-play
// (built by `zig build`) on a free port with a temporary data dir, spawned
// as one process and stopped by its PID, never by a pattern.
//
// **READY WHEN IT SAYS SO**: the server is taken as up when its stderr says
// `bound to` (webbox's listening line), with no polling. A port someone took
// between `freePort` and the bind makes the server exit instead: it is
// spawned again on another port, up to three times.
//
// **THE DATA DIR ON TMPFS** (/dev/shm where there is one): the server
// syncs its filesystem before every answer that follows a write, and on
// disk that sync was half of a page test's time. On tmpfs the same sync
// runs and costs nothing; durability is webbox's to test, not these.

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import http from "node:http";
import net from "node:net";

export const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const binary = join(root, "zig-out/bin/dog-park-play");

/** How long a start may take before it is a failure. */
const start_deadline_ms = 10_000;

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

/** The server on `port`: resolves once it is listening ({ child, port, log }), or with { failed: its log } when it exited first. */
function spawnOn(dir, port) {
  const child = spawn(binary, [], {
    cwd: root,
    env: { ...process.env, DOGPARK_PORT: String(port), DOGPARK_BIND: "127.0.0.1", DOGPARK_CONFIG: join(dir, "config") },
    stdio: ["ignore", "ignore", "pipe"],
  });
  let log = "";
  return new Promise((resolve, reject) => {
    const deadline = setTimeout(() => {
      process.kill(child.pid, "SIGTERM");
      reject(new Error(`the server never said it was listening in ${start_deadline_ms} ms:\n${log}`));
    }, start_deadline_ms);
    child.stderr.on("data", (d) => {
      log += d;
      if (/ bound to /.test(log)) {
        clearTimeout(deadline);
        resolve({ child, port, log: () => log });
      }
    });
    child.once("exit", () => {
      clearTimeout(deadline);
      resolve({ failed: log });
    });
  });
}

async function start(dir) {
  let failed = "";
  for (let attempt = 0; attempt < 3; attempt++) {
    const server = await spawnOn(dir, await freePort());
    if (!server.failed) return server;
    failed = server.failed;
    // Only a port taken under it is worth another try.
    if (!/AddressInUse/.test(failed)) break;
  }
  throw new Error(`the server stopped as it started:\n${failed}`);
}

/** A POST through node:http, its body as text. */
function request(port, method, path, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, method, path }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
      res.on("error", reject);
    });
    req.on("error", reject);
    if (body !== undefined) req.setHeader("content-length", Buffer.byteLength(body));
    req.end(body);
  });
}

/** A fresh server on a fresh data dir: { base, port, post(path, text), get(path), restart(), stop() }. */
export async function scratchServer() {
  const dir = mkdtempSync(join(existsSync("/dev/shm") ? "/dev/shm" : tmpdir(), "dogpark-scratch-"));
  writeFileSync(join(dir, "config"), `data_dir=${join(dir, "data")}\nauth_dir=${join(dir, "auth")}\n`);
  // The host's second root: webbox opens it; Dog Park keeps nothing there.
  mkdirSync(join(dir, "auth"));
  let server = await start(dir);
  const stopIt = async () => {
    if (server.child.exitCode !== null || server.child.signalCode !== null) return;
    const gone = new Promise((r) => server.child.once("exit", r));
    process.kill(server.child.pid, "SIGTERM");
    await gone;
  };
  return {
    get base() { return `http://127.0.0.1:${server.port}`; },
    get port() { return server.port; },
    dir,
    log: () => server.log(),
    async post(path, text) {
      const r = await request(server.port, "POST", path, text);
      return { status: r.status, type: r.headers["content-type"], text: r.body.toString() };
    },
    async get(path) {
      const r = await request(server.port, "GET", path);
      return { status: r.status, headers: new Map(Object.entries(r.headers)), body: r.body };
    },
    /** A stop and a start on the same data dir (a new port, maybe). */
    async restart() {
      await stopIt();
      server = await start(dir);
    },
    async stop() {
      await stopIt();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

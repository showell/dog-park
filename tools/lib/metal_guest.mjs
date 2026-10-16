// **A METAL KERNEL UNDER QEMU, AND HTTP TO IT**: what the QEMU gate
// (tools/metal_gate.mjs) and the droplet rehearsal (droplet/rehearse.mjs)
// share. A guest is one QEMU process, started with its serial log in a file
// and a host port forwarded to the guest's port 80; it is ready once the log
// says it is listening, and it is stopped by its PID.
//
// Every failure here throws; the caller names the step it was on.

import { spawn } from "node:child_process";
import { readFileSync, openSync, closeSync } from "node:fs";
import http from "node:http";
import net from "node:net";

export function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

/**
 * **AN ERROR LINE IN THE GUEST'S LOG**: a panic, a request whose outcome is
 * not `ok` (an error's name in its place), an upload's line (the kernel's,
 * for a POST with a body: `/admin/script`'s) not ending `: ok (<status>)`,
 * a disk check with a leak or a problem, a restart after a fatal stop, or a
 * line naming an error or a failure. Expected refusals (303, 403) are `ok`
 * outcomes.
 */
export function errorLines(log) {
  return log.split("\n").map((l) => l.replace(/\r$/, "")).filter((l) =>
    /PANIC|fatal/i.test(l) ||
    (/^\s*upload: /.test(l) ? !/: ok \(\d+\)$/.test(l) : / request \d+: /.test(l) && !/ -> ok, /.test(l)) ||
    (/disk check/.test(l) && !/ 0 leaked, 0 problems$/.test(l)) ||
    /\berror\b|\bfailed\b|\bfailure\b/i.test(l.replace(/\b0 (failed|failures)\b/g, "")));
}

/**
 * Starts `launch(port)`'s `{ command, args, env }` with its output in
 * `serialPath`, and resolves with the guest once the log says the kernel is
 * listening on port 80.
 */
export async function bootGuest({ launch, serialPath, deadlineMs }) {
  const port = await freePort();
  const { command, args, env } = launch(port);
  const out = openSync(serialPath, "w");
  // One process, stopped by its PID: droplet.sh `exec`s QEMU, so its PID is QEMU's.
  const proc = spawn(command, args, { stdio: ["ignore", out, out], env: env ?? process.env });
  closeSync(out);
  const guest = new Guest(proc, port, serialPath);
  const deadline = performance.now() + deadlineMs;
  while (!/\n  listening on port 80\n/.test(guest.serial())) {
    if (guest.exited !== null) throw new Error(`QEMU exited (${guest.exited}) before the kernel listened`);
    if (performance.now() > deadline) throw new Error(`no "listening on port 80" in ${deadlineMs} ms`);
    await new Promise((r) => setTimeout(r, 20));
  }
  return guest;
}

class Guest {
  constructor(proc, port, serialPath) {
    this.proc = proc;
    this.port = port;
    this.serialPath = serialPath;
    /** The requests sent to this boot: the kernel numbers its log lines by them. */
    this.sent = 0;
    this.exited = null;
    proc.once("exit", (code, sig) => { this.exited = `${code ?? sig}`; });
  }

  serial() {
    return readFileSync(this.serialPath, "latin1");
  }

  /** Stops QEMU by its PID and waits for it to go. */
  async stop() {
    if (this.proc.exitCode !== null || this.proc.signalCode !== null) return;
    const gone = new Promise((r) => this.proc.once("exit", r));
    process.kill(this.proc.pid, "SIGTERM");
    await gone;
  }

  /** One request to the guest: { status, headers, body (Buffer), text }. */
  request(method, path, { body, cookie, headers = {} } = {}) {
    this.sent++;
    return new Promise((resolve, reject) => {
      const req = http.request({ host: "127.0.0.1", port: this.port, method, path, agent: false, headers: { ...headers, ...(cookie ? { cookie } : {}) } }, (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const b = Buffer.concat(chunks);
          resolve({ status: res.statusCode, headers: res.headers, body: b, text: b.toString() });
        });
        res.on("error", reject);
      });
      req.setTimeout(10_000, () => req.destroy(new Error(`${method} ${path}: no answer in 10 s`)));
      req.on("error", reject);
      if (body !== undefined) req.setHeader("content-length", Buffer.byteLength(body));
      req.end(body);
    });
  }

  /**
   * **THE LOG LAGS THE ANSWERS**: the kernel writes a request's line to the
   * console after the response, so the log is judged once it holds the last
   * request's line whole, and only its whole lines.
   */
  async checkSerial() {
    const last = new RegExp(` request ${this.sent}: [^\n]*\n`);
    const deadline = performance.now() + 5000;
    while (!last.test(this.serial())) {
      if (performance.now() > deadline) throw new Error(`the guest's log never got request ${this.sent}'s line`);
      await new Promise((r) => setTimeout(r, 20));
    }
    const log = this.serial();
    const bad = errorLines(log.slice(0, log.lastIndexOf("\n") + 1));
    if (bad.length) throw new Error(`the guest's log has error lines:\n  ${bad.join("\n  ")}`);
  }

  /** The log's last `n` lines, for a failure's report. */
  tail(n = 40) {
    return this.serial().split("\n").slice(-n).join("\n");
  }
}

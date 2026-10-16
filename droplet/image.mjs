// **DOG PARK'S BOOT IMAGE, FOR A DROPLET** (DEPLOY.md, step 1). One disk,
// laid out by zig-metal-unikernel's droplet/app_image.py, any application's
// image builder: its boot loader, then dogpark.elf in partition 1, then
// partition 2, a FAT16 filesystem holding solo/, auth/_admin_key and
// zig-metal-unikernel.conf. **THERE IS NO DATA
// VOLUME**: with no `volume` line in the conf and none attached, the kernel
// keeps data/ and auth/ on the boot disk (probe/gopher.zig, "data: the boot
// disk"). So a new image starts Dog Park empty: accounts, games and the
// session secret go with the old one (accepted, Steve 2026-10-15).
//
//     node droplet/image.mjs [out.img]     default ~/dogpark-images/dogpark-<commit>.img
//
// It then writes out.img.gz beside it, prints both sizes and sha256s, and
// boots the image under QEMU (droplet/rehearse.mjs); a failed rehearsal
// fails the build.
//
// **REFUSES** on a dirty tree (this one, ../zig-metal-unikernel or
// ../zig-webbox: each is compiled into the image), unless
// DOGPARK_IMAGE_DIRTY=1, which builds it anyway and says so. **REFUSES**
// without droplet/trusted-proxy (prod's private address, whose
// X-Forwarded-For names the client): without it every request through Caddy
// would count as Caddy's one address.
//
// **THE ADMIN KEY** is ~/.dogpark_admin_key (64 hex digits, mode 600), made
// here from 32 random bytes if it is absent. It is copied into the image and
// never printed.

import { execFileSync } from "node:child_process";
import { randomBytes, createHash } from "node:crypto";
import { existsSync, mkdtempSync, mkdirSync, cpSync, writeFileSync, readFileSync, rmSync, statSync, createReadStream } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { rehearse } from "./rehearse.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const kernelRoot = resolve(root, "../zig-metal-unikernel");
const webboxRoot = resolve(root, "../zig-webbox");
const elf = join(root, "zig-out/bin/dogpark.elf");
export const adminKeyPath = join(homedir(), ".dogpark_admin_key");
const proxyFile = join(root, "droplet/trusted-proxy");
/**
 * **THE DISK SIZE** (the site partition is it, less the GPT's sectors): all of
 * Dog Park's data lives there. A game's
 * logs are capped at about 25 MB (docs/PHYSICS.md), so 80 games could in
 * principle pass 1 GiB; 5 playing at once, with closed logs kept an hour,
 * stays far under it. gzip takes the empty space to almost nothing.
 */
const site_mib = 1024;

const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], ...opts });

function die(why) {
  console.error(`image.mjs: ${why}`);
  process.exit(1);
}

/** Each tree compiled into the image, clean, or the override said loudly. */
function checkTrees() {
  const dirty = [];
  for (const tree of [root, kernelRoot, webboxRoot]) {
    if (run("git", ["-C", tree, "status", "--porcelain"]).trim()) dirty.push(tree);
  }
  if (dirty.length === 0) return;
  if (process.env.DOGPARK_IMAGE_DIRTY === "1") {
    console.error(`image.mjs: DOGPARK_IMAGE_DIRTY=1: BUILDING FROM DIRTY TREES, an image no commit describes:\n  ${dirty.join("\n  ")}`);
    return;
  }
  die(`REFUSING: uncommitted changes in\n  ${dirty.join("\n  ")}\n(DOGPARK_IMAGE_DIRTY=1 builds it anyway, and says so.)`);
}

/** The admin key, made if absent; refused if anyone but its owner can read it. */
export function adminKey() {
  if (!existsSync(adminKeyPath)) {
    writeFileSync(adminKeyPath, randomBytes(32).toString("hex") + "\n", { mode: 0o600, flag: "wx" });
    console.log(`image.mjs: made a new admin key in ${adminKeyPath} (mode 600)`);
  }
  if (statSync(adminKeyPath).mode & 0o077) die(`${adminKeyPath} is readable by others: chmod 600 it`);
  const key = readFileSync(adminKeyPath, "utf8").trim();
  if (!/^[0-9a-f]{64}$/.test(key)) die(`${adminKeyPath} is not 64 hex digits`);
  return key;
}

function trustedProxy() {
  if (!existsSync(proxyFile)) die(`REFUSING: no ${proxyFile}: write prod's private address (where its Caddy reaches the droplet from), or every request through Caddy counts as one address`);
  const proxy = readFileSync(proxyFile, "utf8").trim();
  if (!/^\d+\.\d+\.\d+\.\d+$/.test(proxy)) die(`${proxyFile} is not an IPv4 address: ${JSON.stringify(proxy)}`);
  return proxy;
}

/** The site's files (solo/, auth/_admin_key) and its conf, for app_image.py. */
function siteFiles(work, key, proxy) {
  const content = join(work, "content");
  mkdirSync(join(content, "auth"), { recursive: true });
  cpSync(join(root, "solo"), join(content, "solo"), { recursive: true });
  writeFileSync(join(content, "auth", "_admin_key"), key);
  // As angry-gopher's (zig-metal-unikernel droplet/chat.py), less the volume:
  // a stalled connection let go after 10 s, no `requests` (serve until turned
  // off), only the private card, and Caddy's address believed.
  const conf = join(work, "zig-metal-unikernel.conf");
  writeFileSync(conf, `idle_timeout_ms = 10000\ncard = private\ntrusted_proxy = ${proxy}\n`);
  return { content, conf };
}

function sha256(path) {
  return new Promise((ok, fail) => {
    const h = createHash("sha256");
    createReadStream(path).on("data", (d) => h.update(d)).on("end", () => ok(h.digest("hex"))).on("error", fail);
  });
}

const mib = (path) => `${(statSync(path).size / (1 << 20)).toFixed(1)} MiB`;

async function main() {
  checkTrees();
  const commit = run("git", ["-C", root, "rev-parse", "--short=12", "HEAD"]).trim();
  const kernelCommit = run("git", ["-C", kernelRoot, "rev-parse", "--short=12", "HEAD"]).trim();
  const out = resolve(process.argv[2] ?? join(homedir(), "dogpark-images", `dogpark-${commit}.img`));
  mkdirSync(dirname(out), { recursive: true });

  const proxy = trustedProxy();
  const key = adminKey();

  console.log("image.mjs: zig build metal");
  execFileSync("zig", ["build", "metal"], { cwd: root, stdio: "inherit" });

  const work = mkdtempSync(join(tmpdir(), "dogpark-image-"));
  try {
    const { content, conf } = siteFiles(work, key, proxy);
    try {
      run("python3", [join(kernelRoot, "droplet/app_image.py"), elf, content, conf, out, "--disk-mib", String(site_mib), "--fat", "16", "--label", "DOGPARK"]);
    } catch (e) {
      die(`zig-metal-unikernel's droplet/app_image.py failed:\n${e.stdout}${e.stderr}`);
    }
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
  run("gzip", ["-k", "-f", "-6", out]);
  const gz = `${out}.gz`;
  console.log(`image.mjs: dog-park ${commit}, zig-metal-unikernel ${kernelCommit}, trusted proxy ${proxy}, no volume`);
  console.log(`  ${out}  ${mib(out)}  sha256 ${await sha256(out)}`);
  console.log(`  ${gz}  ${mib(gz)}  sha256 ${await sha256(gz)}`);

  const ok = await rehearse(out);
  if (!ok) die(`the rehearsal failed: do not deploy ${gz}`);
  console.log(`image.mjs: ready to deploy: ${gz}`);
}

await main();

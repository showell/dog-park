import fs from 'node:fs';
const { instance } = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), {});
const e = instance.exports;
e.fill(42);
console.log('disagree', e.disagree());
for (const [w, name] of [[0, 'roc'], [1, 'zig'], [0, 'roc'], [1, 'zig']]) {
  const rounds = 200, n = 1 << 16;
  const t0 = process.hrtime.bigint();
  const sum = e.run(w, rounds);
  const ns = Number(process.hrtime.bigint() - t0);
  console.log(name, (ns / (rounds * n)).toFixed(2), 'ns a call', sum);
}

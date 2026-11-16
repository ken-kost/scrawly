// Compares two runs of the same benchmark (bench/README.md): every median
// (keys `median` and `median_us`) present in both, flagging the ones that
// differ by more than the tolerance (default 15%) relative to the first.
//
//   node bench/compare.mjs A.json B.json [--tolerance 15] [--all]
//
// Groups named frame_aligned (tied to the 60 Hz frame clock), thresholded
// (sums of tasks over 50 ms) and during_load (costs that share the main
// thread with a page's boot) are skipped and counted.
// Medians below the noise floor (--floor, default 1: ms in the client
// results, us in the server's) are listed but not flagged. Exit status 1
// when any median is flagged.

import fs from "node:fs";

const args = process.argv.slice(2);
const files = args.filter((a) => !a.startsWith("--") && !/^\d+(\.\d+)?$/.test(a));
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 ? Number(args[i + 1]) : dflt;
};
const tolerance = opt("--tolerance", 15);
const floor = opt("--floor", 1);
const all = args.includes("--all");
if (files.length !== 2) {
  console.error("usage: node bench/compare.mjs A.json B.json [--tolerance 15] [--floor 1] [--all]");
  process.exit(2);
}
const [a, b] = files.map((f) => JSON.parse(fs.readFileSync(f, "utf8")));

const rows = [];
let skipped = 0;
function walk(x, y, path) {
  if (!x || !y || typeof x !== "object" || typeof y !== "object") return;
  for (const k of Object.keys(x)) {
    if (k === "meta" || k === "bundles") continue;
    const p = path ? `${path}.${k}` : k;
    // Frame-clock-bound and threshold-bound figures (see bench/README.md).
    if (k === "frame_aligned" || k === "thresholded" || k === "during_load") {
      skipped++;
      continue;
    }
    if ((k === "median" || k === "median_us") && typeof x[k] === "number" && typeof y[k] === "number") {
      const base = Math.abs(x[k]);
      const d = base === 0 ? (y[k] === 0 ? 0 : Infinity) : (100 * (y[k] - x[k])) / base;
      const tiny = Math.max(Math.abs(x[k]), Math.abs(y[k])) < floor;
      rows.push({ p, a: x[k], b: y[k], d, flagged: !tiny && Math.abs(d) > tolerance, tiny });
    } else if (typeof x[k] === "object") {
      walk(x[k], y[k], p);
    }
  }
}
walk(a, b, "");

const flagged = rows.filter((r) => r.flagged);
for (const r of all ? rows : flagged) {
  const mark = r.flagged ? "OVER" : r.tiny ? "tiny" : "ok  ";
  console.log(`${mark} ${r.d >= 0 ? "+" : ""}${r.d.toFixed(1)}%  ${r.a} -> ${r.b}  ${r.p}`);
}
const worst = rows.filter((r) => !r.tiny).reduce((m, r) => Math.max(m, Math.abs(r.d)), 0);
console.log(
  `${rows.length} medians compared (${skipped} frame_aligned/thresholded/during_load groups skipped), ` +
    `${rows.filter((r) => r.tiny).length} under the ${floor} floor, ` +
    `${flagged.length} differ by more than ${tolerance}% (largest ${worst.toFixed(1)}%)`
);
process.exit(flagged.length ? 1 : 0);

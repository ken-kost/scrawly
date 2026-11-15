// Writes the benchmark stroke sets (bench/lib/fixture_gen.mjs) to
// bench/fixtures/<canvas>-<count>.json, or with --check verifies that the
// stored files are exactly what the generator makes.
//
//   node bench/fixtures/generate.mjs [--check]

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SEED, strokeSet, summary } from "../lib/fixture_gen.mjs";

const dir = path.dirname(fileURLToPath(import.meta.url));
const check = process.argv.includes("--check");
const SIZES = [100, 300, 500];
let failed = false;

for (const canvas of ["game", "demo"]) {
  const all = strokeSet(canvas, 500);
  for (const n of SIZES) {
    const strokes = all.slice(0, n);
    const body = {
      canvas,
      seed: SEED,
      ...summary(strokes),
      strokes: strokes.map(({ id, kind, path: p, color, width }) => ({ id, kind, path: p, color, width })),
    };
    const file = path.join(dir, `${canvas}-${n}.json`);
    const text = JSON.stringify(body) + "\n";
    if (check) {
      const same = fs.existsSync(file) && fs.readFileSync(file, "utf8") === text;
      console.log(`${same ? "ok  " : "DIFF"} ${path.basename(file)}`);
      if (!same) failed = true;
    } else {
      fs.writeFileSync(file, text);
      const { strokes: _s, ...meta } = body;
      console.log(path.basename(file), JSON.stringify(meta));
    }
  }
}

if (failed) process.exit(1);

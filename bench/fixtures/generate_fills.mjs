// Writes the stroke sets with fills (bench/README.md "Fixtures"):
// bench/fixtures/<canvas>-fills-<count>.json, or with --check verifies that
// the stored files are what this makes.
//
//   PLAYWRIGHT=... CHROME=... node bench/fixtures/generate_fills.mjs [--check]
//
// Each set is the line set of the same canvas (lib/fixture_gen.mjs) with
// every tenth stroke (index 9, 19, ...) replaced by a fill: the fill tool's
// own shape (priv/static/fill_worker.mjs, its raster, flood, trace and
// simplification, run in headless Chromium as the worker runs them) for a
// press at a seeded point over the strokes before it, in a seeded preset
// colour. A press that fills nothing or a too detailed area moves on to the
// next seeded point (at most 40). So 10 / 30 / 50 fills in the 100 / 300 /
// 500 sets, 100 and 300 being prefixes of 500 as for the line sets. The
// worker's raster is Chromium's, so a check needs the same Chromium build
// (Playwright 1181 here).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { SEED, prng, strokeSet, summary } from "../lib/fixture_gen.mjs";

const dir = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(dir, "..", "..");
const WORKER = path.join(ROOT, "priv", "static", "fill_worker.mjs");
const check = process.argv.includes("--check");
const SIZES = [100, 300, 500];
const EVERY = 10;
const TRIES = 40;
const COLORS = ["#0a0a0a", "#d63838", "#2a6df4", "#1f9a4a", "#eab308", "#f97316", "#a855f7", "#ec4899"];

const pwPath = process.env.PLAYWRIGHT || "playwright";
const { chromium } = await import(pwPath.startsWith("/") ? pathToFileURL(pwPath).href : pwPath);
const browser = await chromium.launch({ executablePath: process.env.CHROME || undefined, headless: true });
let failed = false;

try {
  const page = await browser.newPage();
  // A made-up origin, so the page can import the worker module as a module.
  await page.route("http://fixtures.local/**", (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === "/fill_worker.mjs") {
      return route.fulfill({ contentType: "text/javascript", body: fs.readFileSync(WORKER, "utf8") });
    }
    return route.fulfill({ contentType: "text/html", body: "<!doctype html><title>fills</title>" });
  });
  await page.goto("http://fixtures.local/");
  await page.evaluate(async () => {
    const W = await import("/fill_worker.mjs");
    const raster = W.createRaster(
      () => new OffscreenCanvas(W.WIDTH, W.HEIGHT),
      (d) => new Path2D(d)
    );
    // The area for a press at (x, y) over `list`: {path} or {error}.
    window.fillAt = (list, x, y) => {
      const px = raster.pixels("fixture", list);
      return W.areaPath(px, W.WIDTH, W.HEIGHT, x, y, null);
    };
  });

  for (const canvas of ["game", "demo"]) {
    const lines = strokeSet(canvas, 500);
    const all = [];
    for (let i = 0; i < lines.length; i++) {
      if (i % EVERY !== EVERY - 1) {
        all.push(lines[i]);
        continue;
      }
      const rnd = prng(SEED * 7_919 + (canvas === "game" ? 1 : 2) * 104_729 + i);
      const color = COLORS[Math.floor(rnd() * COLORS.length)];
      const plain = all.map((s) => ({ id: s.id, path: s.path, color: s.color, width: s.width, fill: s.fill === true }));
      let made = null;
      for (let t = 0; t < TRIES && !made; t++) {
        const x = Math.round((4 + rnd() * 792) * 10) / 10;
        const y = Math.round((4 + rnd() * 442) * 10) / 10;
        const r = await page.evaluate(([list, x, y]) => window.fillAt(list, x, y), [plain, x, y]);
        if (r && typeof r.path === "string") made = r.path;
      }
      all.push(
        made
          ? { id: `fx-${canvas}-${i}`, kind: "fill", path: made, color, width: 1, fill: true }
          : lines[i]
      );
    }

    for (const n of SIZES) {
      const strokes = all.slice(0, n);
      const body = {
        canvas,
        seed: SEED,
        fills: strokes.filter((s) => s.fill === true).length,
        ...summary(strokes),
        strokes: strokes.map(({ id, kind, path: p, color, width, fill }) =>
          fill === true ? { id, kind, path: p, color, width, fill: true } : { id, kind, path: p, color, width }
        ),
      };
      const file = path.join(dir, `${canvas}-fills-${n}.json`);
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
} finally {
  await browser.close();
}

if (failed) process.exit(1);

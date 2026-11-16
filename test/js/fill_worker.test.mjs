// The fill tool's area (priv/static/fill_worker.mjs, a module Web Worker):
// the flood fill with its tolerance, growing by a pixel, the outlines and
// their holes (a ring, a C, areas touching at a corner, a single pixel),
// dropping the tiny holes, Douglas-Peucker to a byte budget, the path
// format, the raster kept between fills, and the worker's messages. All on
// small hand-made pixel masks and images.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const fw = await import("../../priv/static/fill_worker.mjs");
const {
  VERSION,
  SCALE,
  WIDTH,
  HEIGHT,
  TOLERANCE,
  EPSILONS,
  MAX_PATH_BYTES,
  hexToRgb,
  findSeed,
  floodFill,
  dilate,
  traceOutlines,
  loopArea,
  dropSmallHoles,
  simplifyLoop,
  formatPath,
  fitPath,
  areaPath,
  sharedPrefix,
  wordsFit,
  createRaster,
  handleMessage,
} = fw;

// ── Helpers ──────────────────────────────────────────────────────────

// A mask from rows of "#" (in) and "." (out): {mask, w, h} and the box of
// its pixels, as floodFill gives them.
function maskOf(rows) {
  const h = rows.length;
  const w = rows[0].length;
  const mask = new Uint8Array(w * h);
  let minX = w;
  let minY = h;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (rows[y][x] !== "#") continue;
      mask[y * w + x] = 1;
      minX = Math.min(minX, x);
      maxX = Math.max(maxX, x);
      minY = Math.min(minY, y);
      maxY = Math.max(maxY, y);
    }
  }
  return { area: { mask, minX, minY, maxX, maxY }, w, h };
}

function rowsOf(mask, w, h) {
  const rows = [];
  for (let y = 0; y < h; y++) {
    let r = "";
    for (let x = 0; x < w; x++) r += mask[y * w + x] ? "#" : ".";
    rows.push(r);
  }
  return rows;
}

// An RGBA image from rows of colour letters.
const PALETTE = {
  ".": [255, 255, 255],
  k: [10, 10, 10],
  // A faint anti-aliased edge of a black line: within TOLERANCE of white.
  e: [255 - TOLERANCE, 255 - TOLERANCE, 255 - TOLERANCE],
  // A stronger one: not.
  E: [255 - TOLERANCE - 1, 255, 255],
  r: [220, 38, 38],
  g: [212, 212, 212],
};

function imageOf(rows) {
  const h = rows.length;
  const w = rows[0].length;
  const px = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const c = PALETTE[rows[y][x]];
      const o = (y * w + x) * 4;
      px[o] = c[0];
      px[o + 1] = c[1];
      px[o + 2] = c[2];
      px[o + 3] = 255;
    }
  }
  return { px, w, h };
}

// Whether (x, y) (a pixel's centre) is inside the loops by the evenodd rule.
function evenodd(loops, x, y) {
  let inside = false;
  for (const loop of loops) {
    const n = loop.length / 2;
    for (let i = 0, j = n - 1; i < n; j = i++) {
      const xi = loop[2 * i];
      const yi = loop[2 * i + 1];
      const xj = loop[2 * j];
      const yj = loop[2 * j + 1];
      if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
    }
  }
  return inside;
}

// The traced loops paint exactly the mask, pixel for pixel.
function assertPaints(rows) {
  const { area, w, h } = maskOf(rows);
  const loops = traceOutlines(area, w, h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      assert.equal(evenodd(loops, x + 0.5, y + 0.5), area.mask[y * w + x] === 1, `pixel ${x},${y} of\n${rows.join("\n")}`);
    }
  }
  return loops;
}

const sortedAreas = (loops) => loops.map(loopArea).sort((a, b) => a - b);

// ── Version ──────────────────────────────────────────────────────────

test("the page side asks for this worker's version", () => {
  const src = readFileSync(new URL("../../lib/scrawly_web/pages/fill_tool.mjs", import.meta.url), "utf8");
  assert.match(src, new RegExp("export const FILL_WORKER_VERSION = " + VERSION + ";"));
  assert.equal(WIDTH, 800 * SCALE);
  assert.equal(HEIGHT, 450 * SCALE);
  assert.equal(SCALE, 2);
});

test("the byte budget is StrokeRules' path cap", () => {
  const src = readFileSync(new URL("../../lib/scrawly/games/stroke_rules.ex", import.meta.url), "utf8");
  assert.match(src, /@max_path_bytes 8_000/);
  assert.equal(MAX_PATH_BYTES, 8000);
  assert.deepEqual([...EPSILONS], [0.35, 0.7, 1.4, 2.8]);
});

// ── Colours, seeds ───────────────────────────────────────────────────

test("hexToRgb reads #rrggbb in either case and nothing else", () => {
  assert.deepEqual(hexToRgb("#0a0a0a"), [10, 10, 10]);
  assert.deepEqual(hexToRgb("#FFfF00"), [255, 255, 0]);
  for (const bad of ["0a0a0a", "#0a0a0", "#0a0a0g", null, 12]) assert.equal(hexToRgb(bad), null);
});

test("findSeed: the clicked pixel, else the nearest one of the colour within the radius", () => {
  const { px, w, h } = imageOf(["kkkkk", "kkkkk", "kk.kk", "kkkkk", "kkkkk"]);
  assert.deepEqual(findSeed(px, w, h, 2, 2, [255, 255, 255], TOLERANCE), [2, 2]);
  assert.deepEqual(findSeed(px, w, h, 0, 0, [255, 255, 255], TOLERANCE, 2), [2, 2]);
  assert.equal(findSeed(px, w, h, 0, 0, [255, 255, 255], TOLERANCE, 1), null);
  assert.deepEqual(findSeed(px, w, h, 99, -4, [10, 10, 10], TOLERANCE), [4, 0]);
});

// ── Flood fill ───────────────────────────────────────────────────────

test("floodFill takes in the faint edge within the tolerance and stops at a stronger one", () => {
  const { px, w, h } = imageOf([
    ".....k...",
    ".....k...",
    "eeeeEk...",
    ".....k...",
  ]);
  const area = floodFill(px, w, h, 0, 0, [255, 255, 255], TOLERANCE);
  assert.deepEqual(rowsOf(area.mask, w, h), [
    "#####....",
    "#####....",
    "####.....",
    "#####....",
  ]);
  assert.equal(area.count, 19);
  assert.deepEqual([area.minX, area.minY, area.maxX, area.maxY], [0, 0, 4, 3]);
  // No tolerance: the faint edge is a wall too.
  const strict = floodFill(px, w, h, 0, 0, [255, 255, 255], 0);
  assert.deepEqual(rowsOf(strict.mask, w, h).slice(1, 3), ["#####....", "........."]);
});

test("floodFill is 4-connected: a diagonal line holds it, the canvas edge bounds it", () => {
  const { px, w, h } = imageOf([
    "..k...",
    ".k....",
    "k.....",
    "......",
  ]);
  const area = floodFill(px, w, h, 0, 0, [255, 255, 255], TOLERANCE);
  assert.deepEqual(rowsOf(area.mask, w, h), ["##....", "#.....", "......", "......"]);
  assert.equal(floodFill(px, w, h, 2, 0, [255, 255, 255], TOLERANCE), null);
  assert.equal(floodFill(px, w, h, -1, 0, [255, 255, 255], TOLERANCE), null);
});

test("floodFill fills a closed outline's inside only, with a dot inside left out", () => {
  const { px, w, h } = imageOf([
    "........",
    ".kkkkkk.",
    ".k....k.",
    ".k.r..k.",
    ".k....k.",
    ".kkkkkk.",
    "........",
  ]);
  const area = floodFill(px, w, h, 4, 3, [255, 255, 255], TOLERANCE);
  assert.deepEqual(rowsOf(area.mask, w, h), [
    "........",
    "........",
    "..####..",
    "..#.##..",
    "..####..",
    "........",
    "........",
  ]);
});

test("floodFill grows its stack for a large area", () => {
  const w = 300;
  const h = 200;
  const px = new Uint8ClampedArray(w * h * 4).fill(255);
  // A comb: many runs per row.
  for (let x = 1; x < w; x += 2) for (let y = 0; y < h - 1; y++) px[(y * w + x) * 4] = 0;
  const area = floodFill(px, w, h, 0, 0, [255, 255, 255], TOLERANCE);
  assert.equal(area.count, w * h - (w / 2) * (h - 1));
});

// ── Growing ──────────────────────────────────────────────────────────

test("dilate grows by one pixel in all eight directions, clipped to the canvas", () => {
  const { area, w, h } = maskOf([
    "#.....",
    "......",
    "...#..",
    "......",
  ]);
  const grown = dilate(area, w, h);
  assert.deepEqual(rowsOf(grown.mask, w, h), [
    "##....",
    "#####.",
    "..###.",
    "..###.",
  ]);
  assert.deepEqual([grown.minX, grown.minY, grown.maxX, grown.maxY], [0, 0, 4, 3]);
});

// ── Outlines ─────────────────────────────────────────────────────────

test("a single pixel is one clockwise square", () => {
  const loops = assertPaints(["...", ".#.", "..."]);
  assert.deepEqual(loops, [[1, 1, 2, 1, 2, 2, 1, 2]]);
  assert.equal(loopArea(loops[0]), 1);
});

test("a rectangle has four corners and no collinear vertices", () => {
  const loops = assertPaints(["......", ".####.", ".####.", "......"]);
  assert.deepEqual(loops, [[1, 1, 5, 1, 5, 3, 1, 3]]);
  assert.equal(loopArea(loops[0]), 8);
});

test("a ring is an outline and a hole, the hole counter-clockwise", () => {
  const loops = assertPaints([
    ".......",
    ".#####.",
    ".#...#.",
    ".#...#.",
    ".#####.",
    ".......",
  ]);
  assert.equal(loops.length, 2);
  assert.deepEqual(sortedAreas(loops), [-6, 20]);
});

test("a C shape is one outline, its notch included", () => {
  const loops = assertPaints([
    "......",
    ".####.",
    ".#....",
    ".#....",
    ".####.",
    "......",
  ]);
  assert.equal(loops.length, 1);
  assert.equal(loopArea(loops[0]), 10);
});

test("areas touching at a corner are outlined apart", () => {
  const loops = assertPaints(["#..", ".#.", "..#"]);
  assert.deepEqual(loops, [
    [0, 0, 1, 0, 1, 1, 0, 1],
    [1, 1, 2, 1, 2, 2, 1, 2],
    [2, 2, 3, 2, 3, 3, 2, 3],
  ]);
  const other = assertPaints([".#", "#."]);
  assert.equal(other.length, 2);
  assert.deepEqual(sortedAreas(other), [1, 1]);
});

test("a C closed at a corner is one outline pinched there; the evenodd rule still paints the mask", () => {
  const loops = assertPaints([
    ".....",
    ".###.",
    ".#.#.",
    ".##..",
    ".....",
  ]);
  // The notch reaches the outside through the corner (the area is
  // 4-connected, the rest 8-connected): no hole, one loop.
  assert.equal(loops.length, 1);
  assert.equal(loopArea(loops[0]), 7);
});

test("the canvas edge is part of the outline", () => {
  const loops = assertPaints(["##.", "##.", "..."]);
  assert.deepEqual(loops, [[0, 0, 2, 0, 2, 2, 0, 2]]);
});

test("nested shapes: an outline, its hole, an island in it and the island's hole", () => {
  const loops = assertPaints([
    "#########",
    "#.......#",
    "#.#####.#",
    "#.#...#.#",
    "#.#####.#",
    "#.......#",
    "#########",
  ]);
  assert.equal(loops.length, 4);
  assert.deepEqual(sortedAreas(loops), [-35, -3, 15, 63]);
});

test("dropSmallHoles drops holes under the area and keeps every outline and larger hole", () => {
  const { area, w, h } = maskOf([
    "##########",
    "#.########",
    "######..##",
    "######..##",
    "##########",
  ]);
  const loops = traceOutlines(area, w, h);
  assert.deepEqual(sortedAreas(loops), [-4, -1, 50]);
  assert.deepEqual(sortedAreas(dropSmallHoles(loops, 4)), [-4, 50]);
  assert.deepEqual(sortedAreas(dropSmallHoles(loops, 5)), [50]);
  // An outline is never dropped, however small.
  const dot = traceOutlines(maskOf(["#"]).area, 1, 1);
  assert.equal(dropSmallHoles(dot, 4).length, 1);
});

test("four pixels at a time (word-aligned rows) gives exactly the byte-by-byte result", () => {
  assert.equal(wordsFit(1600), true);
  assert.equal(wordsFit(1599), false);
  // A seeded generator: blobs, specks, diagonal touches, the canvas's edges.
  let seed = 43;
  const rand = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
  for (const [w, h] of [[8, 6], [12, 9], [64, 40], [160, 90]]) {
    for (let round = 0; round < 25; round++) {
      const mask = new Uint8Array(w * h);
      const density = 0.15 + rand() * 0.6;
      for (let i = 0; i < mask.length; i++) mask[i] = rand() < density ? 1 : 0;
      let minX = w, minY = h, maxX = -1, maxY = -1;
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (mask[y * w + x]) { minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y); }
      if (maxX < 0) continue;
      const area = { mask, minX, minY, maxX, maxY };
      const words = dilate(area, w, h);
      const bytes = dilate(area, w, h, true);
      assert.deepEqual(words, bytes, `dilate ${w}x${h} #${round}`);
      assert.deepEqual(traceOutlines(words, w, h), traceOutlines(words, w, h, true), `trace ${w}x${h} #${round}`);
      assert.deepEqual(traceOutlines(area, w, h), traceOutlines(area, w, h, true), `trace raw ${w}x${h} #${round}`);
    }
  }
});

// ── Simplifying ──────────────────────────────────────────────────────

test("simplifyLoop drops a staircase's corners within epsilon and keeps the shape's corners", () => {
  // A right triangle with a staircase hypotenuse: 0,0 -> 8,0 -> down the
  // steps to 0,8.
  const loop = [0, 0, 8, 0];
  for (let k = 8; k > 0; k--) loop.push(k, 9 - k, k - 1, 9 - k);
  const simple = simplifyLoop(loop, 1);
  assert.ok(simple.length / 2 <= 5, JSON.stringify(simple));
  assert.deepEqual(simple.slice(0, 2), [0, 0]);
  // Every dropped vertex is within epsilon of the kept outline.
  const n = simple.length / 2;
  for (let i = 0; i < loop.length; i += 2) {
    let best = Infinity;
    for (let k = 0; k < n; k++) {
      const ax = simple[2 * k];
      const ay = simple[2 * k + 1];
      const bx = simple[(2 * k + 2) % simple.length];
      const by = simple[(2 * k + 3) % simple.length];
      const dx = bx - ax;
      const dy = by - ay;
      const t = Math.max(0, Math.min(1, ((loop[i] - ax) * dx + (loop[i + 1] - ay) * dy) / (dx * dx + dy * dy)));
      best = Math.min(best, Math.hypot(loop[i] - ax - t * dx, loop[i + 1] - ay - t * dy));
    }
    assert.ok(best <= 1 + 1e-9, `vertex ${loop[i]},${loop[i + 1]} is ${best} away`);
  }
  // A tiny epsilon keeps everything.
  assert.equal(simplifyLoop(loop, 0.01).length, loop.length);
});

test("simplifyLoop gives null when fewer than three vertices are left", () => {
  assert.equal(simplifyLoop([0, 0, 1, 0, 1, 1, 0, 1], 5), null);
  assert.equal(simplifyLoop([0, 0, 1, 0], 0.1), null);
  assert.deepEqual(simplifyLoop([0, 0, 4, 0, 4, 4, 0, 4], 1), [0, 0, 4, 0, 4, 4, 0, 4]);
});

// ── The path ─────────────────────────────────────────────────────────

test("formatPath writes M L Z sub-paths in units, one decimal at most", () => {
  assert.equal(formatPath([[1, 1, 2, 1, 2, 2, 1, 2]], 2), "M 0.5 0.5 L 1 0.5 L 1 1 L 0.5 1 Z");
  assert.equal(
    formatPath([[0, 0, 1600, 0, 1600, 900, 0, 900], [3, 4, 3, 7, 9, 7]], 2),
    "M 0 0 L 800 0 L 800 450 L 0 450 Z M 1.5 2 L 1.5 3.5 L 4.5 3.5 Z",
  );
  // What StrokeRules lets a fill's path hold.
  assert.match(formatPath([[0, 0, 1599, 0, 1599, 899]], 2), /^[MLZ0-9. ,-]+$/);
});

test("fitPath doubles epsilon until the path fits the budget, then gives up", () => {
  // A circle of radius 200 px, traced as a pixel staircase.
  const w = 420;
  const h = 420;
  const mask = new Uint8Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (Math.hypot(x + 0.5 - 210, y + 0.5 - 210) <= 200) mask[y * w + x] = 1;
  const loops = traceOutlines({ mask, minX: 0, minY: 0, maxX: w - 1, maxY: h - 1 }, w, h);
  const fine = fitPath(loops, { maxBytes: 100000 });
  assert.equal(fine.epsilon, 0.35);
  const coarse = fitPath(loops, { maxBytes: 900 });
  assert.ok(coarse.epsilon > 0.35, JSON.stringify(coarse));
  assert.ok(coarse.path.length <= 900);
  assert.ok(coarse.path.length < fine.path.length);
  assert.deepEqual(fitPath(loops, { maxBytes: 40 }), { error: "too_detailed" });
});

test("fitPath keeps no hole once the outline around it is gone", () => {
  // An outline that simplifies away (a 1 x 1 unit square at a huge
  // epsilon) and a hole: nothing.
  const outer = [0, 0, 2, 0, 2, 2, 0, 2];
  const hole = [0, 0, 0, 40, 40, 40, 40, 0];
  assert.deepEqual(fitPath([outer, hole], { epsilons: [5] }), { error: "nothing" });
});

// ── The whole area ───────────────────────────────────────────────────

// A canvas-sized white image with a closed square outline drawn in it
// (pixels), `thickness` pixels thick.
function squareOutline(x0, y0, size, thickness, color = [10, 10, 10], w = 200, h = 120) {
  const px = new Uint8ClampedArray(w * h * 4).fill(255);
  for (let y = y0; y < y0 + size; y++) {
    for (let x = x0; x < x0 + size; x++) {
      const edge = x < x0 + thickness || y < y0 + thickness || x >= x0 + size - thickness || y >= y0 + size - thickness;
      if (!edge) continue;
      const o = (y * w + x) * 4;
      px[o] = color[0];
      px[o + 1] = color[1];
      px[o + 2] = color[2];
    }
  }
  return { px, w, h };
}

test("areaPath fills inside a closed outline, grown a pixel into it, and never past it", () => {
  const { px, w, h } = squareOutline(20, 20, 40, 4);
  const r = areaPath(px, w, h, 20, 20, "#ffffff", { scale: 2 });
  // Inside is pixels 24..55; grown by one: 23..56, whose corners are
  // 23..57, i.e. 11.5..28.5 units.
  assert.equal(r.path, "M 11.5 11.5 L 28.5 11.5 L 28.5 28.5 L 11.5 28.5 Z");
  assert.equal(r.epsilon, 0.35);
});

test("areaPath fills the background around a drawing with the drawing as holes", () => {
  const { px, w, h } = squareOutline(20, 20, 40, 4);
  const r = areaPath(px, w, h, 1, 1, "#ffffff", { scale: 2 });
  // The canvas's edge, and the drawing (the outline and the area inside
  // it, another area) as one hole, the outline's outer pixel grown over.
  assert.equal(r.path, "M 0 0 L 100 0 L 100 60 L 0 60 Z M 10.5 29.5 L 29.5 29.5 L 29.5 10.5 L 10.5 10.5 Z");
});

test("areaPath keeps a dot inside the area visible and fills over a speck", () => {
  const w = 60;
  const h = 40;
  const px = new Uint8ClampedArray(w * h * 4).fill(255);
  const paint = (x0, y0, size) => {
    for (let y = y0; y < y0 + size; y++) for (let x = x0; x < x0 + size; x++) px[(y * w + x) * 4 + 1] = 0;
  };
  paint(10, 10, 4); // 2 x 2 units: a dot, kept (shrunk by the growth to 2 x 2 px = 1 unit²)
  paint(40, 10, 1); // a 1-pixel speck: grown over entirely
  const r = areaPath(px, w, h, 0, 0, "#ffffff", { scale: 2 });
  const subpaths = r.path.split(" Z").filter((s) => s.trim() !== "");
  assert.equal(subpaths.length, 2, r.path);
  assert.match(r.path, /M 5.5 6.5 L 6.5 6.5 L 6.5 5.5 L 5.5 5.5 Z$/);
});

test("areaPath: a click with nothing of the area's colour around it fills nothing", () => {
  const { px, w, h } = squareOutline(20, 20, 40, 4);
  assert.deepEqual(areaPath(px, w, h, 10, 10, "#123456", { scale: 2 }), { error: "nothing" });
  assert.deepEqual(areaPath(px, w, h, NaN, 10, "#ffffff", { scale: 2 }), { error: "nothing" });
});

test("areaPath on a line recolours the line itself", () => {
  const { px, w, h } = squareOutline(20, 20, 40, 4);
  const r = areaPath(px, w, h, 10.5, 15, "#0a0a0a", { scale: 2 });
  // The outline's ring, grown by a pixel on both sides.
  assert.equal(r.path, "M 9.5 9.5 L 30.5 9.5 L 30.5 30.5 L 9.5 30.5 Z M 12.5 27.5 L 27.5 27.5 L 27.5 12.5 L 12.5 12.5 Z");
});

test("areaPath with no ref takes the clicked pixel's colour", () => {
  const { px, w, h } = squareOutline(20, 20, 40, 4);
  assert.equal(areaPath(px, w, h, 20, 20, null, { scale: 2 }).path, "M 11.5 11.5 L 28.5 11.5 L 28.5 28.5 L 11.5 28.5 Z");
});

test("areaPath says too detailed when nothing fits", () => {
  const { px, w, h } = squareOutline(20, 20, 40, 4);
  assert.deepEqual(areaPath(px, w, h, 20, 20, "#ffffff", { scale: 2, maxBytes: 10 }), { error: "too_detailed" });
});

// ── Raster ───────────────────────────────────────────────────────────

// A 2D context that records what is drawn.
function fakeCanvas(log) {
  return {
    getContext() {
      return {
        setTransform: (...a) => log.push(["transform", ...a]),
        fillRect: () => log.push(["clear"]),
        stroke: (shape) => log.push(["stroke", shape.d]),
        fill: (shape, rule) => log.push(["fill", shape.d, rule]),
        getImageData: () => {
          log.push(["read"]);
          return { data: new Uint8ClampedArray(4) };
        },
      };
    },
  };
}

test("sharedPrefix: entries painting the same, from the start", () => {
  const a = { id: "a", path: "M 1 1 L 2 2", color: "#000000", width: 2 };
  const b = { id: "b", path: "M 3 3 L 4 4", color: "#000000", width: 2 };
  assert.equal(sharedPrefix([a, b], [a, b, a]), 2);
  assert.equal(sharedPrefix([a, b], [{ ...a }, { ...b, color: "#ffffff" }]), 1);
  assert.equal(sharedPrefix([a], [{ ...a, fill: true }]), 0);
  assert.equal(sharedPrefix([a, b], [b]), 0);
});

test("the raster draws only what the list adds, redraws when it changed, and draws fills evenodd", () => {
  const log = [];
  const raster = createRaster(() => fakeCanvas(log), (d) => ({ d }));
  const a = { id: "a", path: "M 1 1 L 2 2", color: "#000000", width: 2 };
  const b = { id: "b", path: "M 0 0 L 9 0 L 9 9 Z", color: "#ff0000", width: 1, fill: true };
  const c = { id: "c", path: "M 5 5 L 6 6", color: "#000000", width: 4 };

  raster.pixels("game", [a, b]);
  assert.deepEqual(
    log.filter((l) => l[0] !== "transform"),
    [["clear"], ["stroke", a.path], ["fill", b.path, "evenodd"], ["read"]],
  );
  log.length = 0;
  raster.pixels("game", [a, b]);
  assert.deepEqual(log, [], "nothing new: the pixels already read");
  raster.pixels("game", [a, b, c]);
  assert.deepEqual(log, [["stroke", c.path], ["read"]]);
  log.length = 0;
  // An undo: everything again.
  raster.pixels("game", [a, b]);
  assert.deepEqual(log.filter((l) => l[0] !== "transform").map((l) => l[0]), ["clear", "stroke", "fill", "read"]);
  log.length = 0;
  // Another canvas: everything again.
  raster.pixels("board", [a, b]);
  assert.deepEqual(log.filter((l) => l[0] !== "transform").map((l) => l[0]), ["clear", "stroke", "fill", "read"]);
  assert.equal(raster.drawnCount(), 2);
  // Entries without a path are skipped.
  log.length = 0;
  raster.pixels("board", [a, b, { id: "x", path: "" }, null]);
  assert.deepEqual(log, []);
});

test("handleMessage: a fill's reply, prepare's none, and unsupported without a raster", () => {
  const raster = {
    pixels: (_name, _list) => squareOutline(0, 0, 1600, 1, [255, 255, 255], WIDTH, HEIGHT).px,
  };
  const reply = handleMessage(raster, { type: "fill", id: 7, canvas: "game", strokes: [], x: 10, y: 10, ref: "#ffffff" });
  assert.equal(reply.type, "fill");
  assert.equal(reply.id, 7);
  assert.equal(reply.path, "M 0 0 L 800 0 L 800 450 L 0 450 Z");
  assert.ok(reply.ms.raster >= 0 && reply.ms.area >= 0);
  assert.equal(handleMessage(raster, { type: "prepare", canvas: "game", strokes: [] }), null);
  assert.deepEqual(handleMessage(null, { type: "fill", id: 8 }), { type: "fill", id: 8, error: "unsupported" });
  assert.equal(handleMessage(raster, null), null);
  assert.equal(handleMessage(raster, { type: "other" }), null);
  const broken = { pixels: () => { throw new Error("boom"); } };
  assert.deepEqual(handleMessage(broken, { type: "fill", id: 9 }), { type: "fill", id: 9, error: "failed", message: "boom" });
});

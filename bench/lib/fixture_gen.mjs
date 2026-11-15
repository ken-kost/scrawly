// Deterministic stroke sets for the drawing benchmarks (bench/README.md).
//
// Every stroke is built from synthetic pointer points by the app's own
// stroke builder (createStrokeBuilder in stroke_engine.mjs), with the same
// rounding the engine applies to pointer input, so its path is exactly what
// the canvas would commit for that gesture. Stroke `i` of a canvas depends
// only on (canvas, i): the 100- and 300-stroke sets are the first 100 and
// 300 strokes of the 500-stroke set, and the client benchmark regenerates a
// stroke's points (strokePoints) to replay it as a real pointer gesture.
//
// Mix (by stroke count): 45% short (~300 bytes), 30% medium (~1.5 KB), 10%
// long scribbles (3-7 KB, under the engine's 7,000-character split) and 15%
// white eraser strokes (0.6-1.8 KB). Pure functions, no DOM.

import { createStrokeBuilder, roundCoord, SPLIT_AT } from "../../lib/scrawly_web/pages/stroke_engine.mjs";

export const SEED = 36;

// The canvases: viewBox size, the toolbar's colours and widths, and the
// eraser (DrawingToolbar and draw_tools.mjs). Since draw-toolbar (#37) the
// home board (GameDemo) has the game canvas's size and tools, so its strokes
// are made the same way, from their own seed. The baseline runs in results/
// were taken on its earlier 400x225 board (widths 2/4/8, eraser 18). Since
// brush-size (#38) the size is a slider (any width 1..40, the eraser's too);
// the fixtures keep #37's four presets and eraser width, so runs stay
// comparable.
const CANVAS = {
  w: 800,
  h: 450,
  colors: ["#0a0a0a", "#d63838", "#2a6df4", "#1f9a4a", "#eab308", "#f97316", "#a855f7", "#ec4899"],
  widths: [2, 5, 10, 20],
  eraser: { color: "#FFFFFF", width: 20 },
  step: [3, 7],
};

export const CANVASES = { game: CANVAS, demo: CANVAS };

// Target path lengths in characters (= bytes: path data is ASCII).
const KINDS = [
  { kind: "short", share: 0.45, min: 220, max: 380 },
  { kind: "medium", share: 0.3, min: 1200, max: 1800 },
  { kind: "long", share: 0.1, min: 3000, max: SPLIT_AT - 100 },
  { kind: "eraser", share: 0.15, min: 600, max: 1800 },
];

// mulberry32: small, fast, and the same on every JS engine.
export function prng(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function canvasSeed(canvas) {
  return canvas === "game" ? 1 : 2;
}

function pickKind(r) {
  let acc = 0;
  for (const k of KINDS) {
    acc += k.share;
    if (r < acc) return k;
  }
  return KINDS[KINDS.length - 1];
}

// The stroke's style and its points (viewBox units, rounded like pointer
// input), drawn as a smooth random walk that turns harder for scribbles.
export function strokePlan(canvas, index) {
  const c = CANVASES[canvas];
  const rnd = prng(SEED * 1_000_003 + canvasSeed(canvas) * 10_007 + index);
  const k = pickKind(rnd());
  const target = Math.round(k.min + rnd() * (k.max - k.min));
  const eraser = k.kind === "eraser";
  const color = eraser ? c.eraser.color : c.colors[Math.floor(rnd() * c.colors.length)];
  const width = eraser ? c.eraser.width : c.widths[Math.floor(rnd() * c.widths.length)];
  const turn = k.kind === "long" ? 0.9 : k.kind === "short" ? 0.25 : 0.45;
  const margin = 0.04;

  let x = c.w * (margin + rnd() * (1 - 2 * margin));
  let y = c.h * (margin + rnd() * (1 - 2 * margin));
  let heading = rnd() * Math.PI * 2;
  const builder = createStrokeBuilder();
  const points = [[roundCoord(x), roundCoord(y)]];
  builder.start(points[0]);

  // Stop before the target (or the engine's split) would be passed.
  for (let guard = 0; guard < 5000 && builder.length() < target; guard++) {
    heading += (rnd() - 0.5) * 2 * turn;
    const step = c.step[0] + rnd() * (c.step[1] - c.step[0]);
    let nx = x + Math.cos(heading) * step;
    let ny = y + Math.sin(heading) * step;
    if (nx < c.w * margin || nx > c.w * (1 - margin)) {
      heading = Math.PI - heading;
      nx = x + Math.cos(heading) * step;
    }
    if (ny < c.h * margin || ny > c.h * (1 - margin)) {
      heading = -heading;
      ny = y + Math.sin(heading) * step;
    }
    x = nx;
    y = ny;
    const p = [roundCoord(x), roundCoord(y)];
    if (builder.add(p) === false) continue;
    points.push(p);
    if (builder.length() >= SPLIT_AT - 60) break;
  }

  return { id: `fx-${canvas}-${index}`, kind: k.kind, color, width, points, path: builder.path() };
}

// The points of stroke `index` (for replaying it as a gesture).
export function strokePoints(canvas, index) {
  return strokePlan(canvas, index).points;
}

// The first `count` strokes of a canvas, as stored: {id, path, color, width}.
export function strokeSet(canvas, count) {
  const strokes = [];
  for (let i = 0; i < count; i++) {
    const s = strokePlan(canvas, i);
    strokes.push({ id: s.id, kind: s.kind, path: s.path, color: s.color, width: s.width });
  }
  return strokes;
}

export function summary(strokes) {
  const kinds = {};
  let bytes = 0;
  let max = 0;
  for (const s of strokes) {
    kinds[s.kind] = (kinds[s.kind] || 0) + 1;
    bytes += s.path.length;
    max = Math.max(max, s.path.length);
  }
  return { count: strokes.length, path_bytes: bytes, max_path_bytes: max, kinds };
}

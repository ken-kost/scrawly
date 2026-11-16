// The paint model (lib/scrawly_web/pages/paint_model.mjs): the colour a
// canvas shows at a point, from its stroke list. The walk (newest first,
// the canvas white when nothing paints), the hit test it is given (node has
// no Path2D: here a plain function, or a fake 2D context whose geometry is
// polylines), the boxes that spare most strokes a Path2D, and the cache of
// shapes, kept bounded: one record per stroke id, dropped with the stroke,
// with the list, and when the canvas leaves the document.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test } from "node:test";
import assert from "node:assert/strict";

// A 2D context whose paths are polylines through their numbers.
import { fakeContext } from "./support/fake_paint.mjs";

globalThis.window = globalThis;

const MODULE = "../../lib/scrawly_web/pages/paint_model.mjs";
const pm = await import(MODULE);
// Hologram 0.12 puts a copy of the module in every page bundle that can
// reach the importing page: a second URL gives node a second instance.
const copy = await import(MODULE + "?bundle=home");

const { CANVAS_COLOR, WATCH_MS, colorAt, topIndexAt, pathBounds, nearBounds, createShapeCache } = pm;

let made = 0;
const makeShape = (entry) => {
  made += 1;
  return { d: entry.path };
};

// A model on the fake context, with a clock the tests run.
function fakeModel(present = () => true) {
  const ctx = fakeContext();
  const timers = new Map();
  let nextTimer = 0;
  const clock = {
    every: (fn, ms) => {
      timers.set(++nextTimer, { fn, ms });
      return nextTimer;
    },
    stop: (id) => timers.delete(id),
  };
  const model = pm.createPaintModel({ context: () => ctx, makeShape, clock, present });
  const tick = () => [...timers.values()].forEach((t) => t.fn());
  return { model, ctx, timers, tick };
}

const red = { id: "a", path: "M 100 100 L 300 100", color: "#d63838", width: 20 };
const blue = { id: "b", path: "M 200 50 L 200 150", color: "#2a6df4", width: 10 };
const eraser = { id: "c", path: "M 280 100 L 320 100", color: "#ffffff", width: 30 };

// ── The walk ─────────────────────────────────────────────────────────

test("the walk goes newest to oldest and stops at the first entry that paints", () => {
  const strokes = [
    { id: "1", path: "M 0 0", color: "#111111" },
    { id: "2", path: "M 0 0", color: "#222222" },
    { id: "3", path: "M 0 0", color: "#333333" },
  ];
  const asked = [];
  const hits = (wanted) => (entry) => {
    asked.push(entry.id);
    return wanted.includes(entry.id);
  };

  assert.equal(colorAt(strokes, 5, 5, hits(["1", "2"])), "#222222");
  assert.deepEqual(asked, ["3", "2"]);

  asked.length = 0;
  assert.equal(topIndexAt(strokes, 5, 5, hits(["1", "2", "3"])), 2);
  assert.deepEqual(asked, ["3"]);

  asked.length = 0;
  assert.equal(colorAt(strokes, 5, 5, hits([])), CANVAS_COLOR);
  assert.deepEqual(asked, ["3", "2", "1"]);
});

test("an empty canvas, a point nothing paints, or no list at all: the canvas, white", () => {
  const never = () => false;
  assert.equal(CANVAS_COLOR, "#ffffff");
  assert.equal(colorAt([], 10, 10, never), "#ffffff");
  assert.equal(colorAt([red], 10, 10, never), "#ffffff");
  for (const list of [null, undefined, "nope", {}]) {
    assert.equal(colorAt(list, 10, 10, () => true), "#ffffff");
  }
  // Not a point: nothing is asked.
  for (const [x, y] of [[NaN, 1], [1, Infinity], [undefined, 1]]) {
    assert.equal(topIndexAt([red], x, y, () => assert.fail("asked")), -1);
  }
  // Entries without a path paint nothing.
  assert.equal(colorAt([{ id: "x", path: "", color: "#000000" }, null], 1, 1, () => true), "#ffffff");
});

test("the colour is the stroke's, exactly as stored", () => {
  const upper = { id: "u", path: "M 0 0", color: "#FFFFFF" };
  assert.equal(colorAt([upper], 0, 0, () => true), "#FFFFFF");
});

// ── The browser's hit test (on a fake context) ───────────────────────

test("a stroke is tested with its own width, round caps and joins; a fill with its inside", () => {
  const ctx = fakeContext();
  const cache = createShapeCache(makeShape);
  const hits = pm.createCanvasHitTest(ctx, cache);

  // The centre, the edge (half the width out), just past it.
  assert.equal(hits(red, 200, 100), true);
  assert.equal(hits(red, 200, 109.9), true);
  assert.equal(hits(red, 200, 110.1), false);
  // Round caps: past the end, within half the width.
  assert.equal(hits(red, 305, 100), true);
  for (const asked of ctx.asked) {
    assert.deepEqual([asked.kind, asked.width, asked.cap, asked.join], ["stroke", 20, "round", "round"]);
  }

  ctx.asked.length = 0;
  hits(blue, 200, 100);
  assert.equal(ctx.asked[0].width, 10);

  // A fill (#43): its inside, whatever its width.
  const fill = { id: "f", path: "M 10 10 L 60 10 L 60 60 L 10 60 Z", color: "#16a34a", width: 1, fill: true };
  assert.equal(pm.isFill(fill), true);
  assert.equal(pm.isFill(red), false);
  ctx.asked.length = 0;
  assert.equal(hits(fill, 35, 35), true);
  assert.equal(hits(fill, 70, 35), false);
  assert.deepEqual(ctx.asked.map((a) => [a.kind, a.rule]), [["fill", "evenodd"]]);

  // A fill with a hole (the fill tool's outline and a dot it left out),
  // painted evenodd: the hole is not the fill's.
  const holed = { id: "h", path: "M 10 10 L 60 10 L 60 60 L 10 60 Z M 30 30 L 30 40 L 40 40 L 40 30 Z", color: "#16a34a", width: 1, fill: true };
  assert.equal(hits(holed, 20, 20), true);
  assert.equal(hits(holed, 35, 35), false);
});

test("the eyedropper over a fill: its colour inside, what is under it in its hole and outside", () => {
  const { model } = fakeModel();
  // Two holes: one over red, one over the empty canvas.
  const holed = {
    id: "h",
    path: "M 100 50 L 300 50 L 300 150 L 100 150 Z M 140 90 L 140 110 L 160 110 L 160 90 Z M 240 120 L 240 140 L 260 140 L 260 120 Z",
    color: "#16a34a",
    width: 1,
    fill: true,
  };
  const list = [red, holed];
  assert.equal(model.colorAt(list, 120, 70), "#16a34a");
  // The fill was painted over red, except in its hole.
  assert.equal(model.colorAt(list, 200, 100), "#16a34a");
  assert.equal(model.colorAt(list, 150, 100), "#d63838");
  assert.equal(model.colorAt(list, 250, 130), "#ffffff");
  assert.equal(model.colorAt(list, 600, 400), "#ffffff");
  // A stroke drawn over the fill is on top.
  assert.equal(model.colorAt([...list, blue], 200, 100), "#2a6df4");
});

test("overlapping strokes: the newest wins; erased paint and the empty canvas are white", () => {
  const { model } = fakeModel();
  const list = [red, blue, eraser];
  // Red alone, blue over red, the eraser over red's end, nothing.
  assert.equal(model.colorAt(list, 150, 100), "#d63838");
  assert.equal(model.colorAt(list, 200, 100), "#2a6df4");
  assert.equal(model.colorAt(list, 300, 100), "#ffffff");
  assert.equal(model.colorAt(list, 600, 400), "#ffffff");
  // Undo the eraser: red is back there.
  assert.equal(model.colorAt([red, blue], 300, 100), "#d63838");
  // The entry itself, for a caller that wants more than its colour.
  assert.equal(model.strokeAt(list, 200, 100), blue);
  assert.equal(model.strokeAt(list, 600, 400), null);
});

// ── Boxes ────────────────────────────────────────────────────────────

test("pathBounds: the box around every coordinate, or null when it can't be read", () => {
  assert.deepEqual(pathBounds("M 10 20 Q 30 5 40 25 L 35.5 -2.5"), { minX: 10, minY: -2.5, maxX: 40, maxY: 25 });
  assert.deepEqual(pathBounds("M 1 2 L 1 2"), { minX: 1, minY: 2, maxX: 1, maxY: 2 });
  assert.deepEqual(pathBounds("M1,2C3,4,5,6,7,8Z"), { minX: 1, minY: 2, maxX: 7, maxY: 8 });
  assert.deepEqual(pathBounds("M .5 -.25 L 1e2 2E-1"), { minX: 0.5, minY: -0.25, maxX: 100, maxY: 0.2 });
  // Relative commands, an odd count, no numbers, not a string.
  for (const d of ["M 1 2 l 3 4", "m 1 2", "M 1 2 L 3", "", "M", "M - 2", null, 7]) {
    assert.equal(pathBounds(d), null, String(d));
  }
  // A long path's decimals stay close.
  const box = pathBounds("M 719.2 331.9 Q 723 335.7 724.8 337.9");
  assert.ok(Math.abs(box.minX - 719.2) < 1e-9 && Math.abs(box.maxY - 337.9) < 1e-9);
});

test("a point off a stroke's box (grown by half its width) is a miss without a shape", () => {
  const ctx = fakeContext();
  const cache = createShapeCache(makeShape);
  const hits = pm.createCanvasHitTest(ctx, cache);
  made = 0;

  // Within half the width (10) of the box, plus 0.5 for the parse.
  assert.equal(nearBounds(pathBounds(red.path), 200, 110.4, 10), true);
  assert.equal(nearBounds(pathBounds(red.path), 200, 110.6, 10), false);
  assert.equal(nearBounds(pathBounds(red.path), 200, 100.4, 0), true);

  assert.equal(hits(red, 600, 400), false);
  assert.equal(hits(red, 200, 125), false);
  assert.equal(made, 0);
  assert.deepEqual(ctx.asked, []);
  assert.equal(cache.size(), 1);
  assert.equal(cache.shapes(), 0);

  // Near it: the shape is made (once) and asked.
  assert.equal(hits(red, 200, 105), true);
  assert.equal(hits(red, 200, 110.3), false);
  assert.equal(made, 1);
  assert.equal(ctx.asked.length, 2);

  // No box (a relative path): always asked.
  const rel = { id: "r", path: "M 500 300 l 10 0", color: "#000000", width: 4 };
  assert.equal(hits(rel, 10, 10), false);
  assert.equal(ctx.asked.length, 3);
});

// ── The cache ────────────────────────────────────────────────────────

test("one record per stroke id, made on first use, made again for another path", () => {
  const cache = createShapeCache(makeShape);
  made = 0;
  const first = cache.shape(red);
  assert.equal(cache.shape({ ...red }), first);
  // Equal text in another string (a server echo) is the same path.
  assert.equal(cache.shape({ ...red, path: ["M 100 100", "L 300 100"].join(" ") }), first);
  assert.equal(made, 1);

  const other = cache.shape({ ...red, path: "M 0 0 L 5 5" });
  assert.notEqual(other, first);
  assert.equal(made, 2);
  assert.equal(cache.size(), 1);

  // No id: made each time, never held.
  cache.shape({ path: "M 1 1" });
  cache.shape({ path: "M 1 1" });
  assert.equal(made, 4);
  assert.equal(cache.size(), 1);
});

test("forget, retain and clear drop records; the model stays bounded by its list", () => {
  const { model } = fakeModel();
  const list = [red, blue, eraser];
  model.colorAt(list, 600, 400);
  assert.equal(model.size(), 3);
  // Only blue's and red's boxes reach (200, 100): two shapes.
  model.colorAt(list, 200, 100);
  assert.equal(model.shapes(), 1);

  model.forget("b");
  assert.equal(model.has("b"), false);
  assert.equal(model.size(), 2);
  // An unknown id changes nothing.
  model.forget("zzz");
  assert.equal(model.size(), 2);

  model.retain([red, { id: "new", path: "M 1 1", color: "#000000", width: 2 }]);
  assert.deepEqual([model.has("a"), model.has("c"), model.has("new")], [true, false, false]);

  model.retain([]);
  assert.equal(model.size(), 0);

  model.colorAt(list, 150, 100);
  model.clear();
  assert.equal(model.size(), 0);

  // A long session: as many records as strokes, never more.
  const many = Array.from({ length: 50 }, (_, i) => ({ id: "s" + i, path: `M ${i} 0 L ${i} 10`, color: "#000000", width: 2 }));
  for (let n = 1; n <= many.length; n++) model.colorAt(many.slice(0, n), 400, 400);
  assert.equal(model.size(), 50);
  for (let n = many.length; n > 0; n--) model.forget("s" + (n - 1));
  assert.equal(model.size(), 0);
});

test("while it holds records it checks its canvas is shown, and drops them once it isn't", () => {
  let shown = true;
  const { model, timers, tick } = fakeModel(() => shown);
  assert.equal(timers.size, 0);

  model.colorAt([red], 200, 100);
  assert.equal(model.watching(), true);
  assert.deepEqual([...timers.values()].map((t) => t.ms), [WATCH_MS]);
  // One timer however many picks.
  model.colorAt([red, blue], 200, 100);
  assert.equal(timers.size, 1);

  tick();
  assert.equal(model.size(), 2);

  // The page was left: the records go, and so does the timer.
  shown = false;
  tick();
  assert.equal(model.size(), 0);
  assert.equal(timers.size, 0);

  // Emptied by its owner: no timer either.
  shown = true;
  model.colorAt([red], 200, 100);
  assert.equal(timers.size, 1);
  model.retain([]);
  assert.equal(timers.size, 0);
  model.colorAt([red], 200, 100);
  model.forget("a");
  assert.equal(timers.size, 0);
});

test("an injected hit test runs the walk without shapes (node has no Path2D)", () => {
  const seen = [];
  const model = pm.createPaintModel({
    hitTest: (entry, x, y) => {
      seen.push([entry.id, x, y]);
      return entry.id === "a";
    },
  });
  assert.equal(model.colorAt([red, blue], 7, 8), "#d63838");
  assert.deepEqual(seen, [["b", 7, 8], ["a", 7, 8]]);
  assert.equal(model.size(), 0);
  assert.equal(model.watching(), false);
});

test("one model per canvas name, shared by every bundle's copy of the module", () => {
  const game = pm.paintModel("test-game", { hitTest: () => true });
  assert.equal(copy.paintModel("test-game"), game);
  assert.notEqual(pm.paintModel("test-board", { hitTest: () => false }), game);
  assert.equal(copy.paintModel("test-game").colorAt([red], 0, 0), "#d63838");
});

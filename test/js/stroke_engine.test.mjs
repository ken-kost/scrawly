// Geometry of the native stroke engine (lib/scrawly_web/pages/stroke_engine.mjs).
// Run with `node --test test/js/*.test.mjs`; test/scrawly_web/js_unit_test.exs
// runs it as part of `mix test`.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  SPLIT_AT,
  MIN_DISTANCE,
  roundCoord,
  toViewBox,
  midpoint,
  createStrokeBuilder,
  startDelta,
} from "../../lib/scrawly_web/pages/stroke_engine.mjs";

// The server's path format (Scrawly.Games.StrokeRules.valid_path?/1).
const VALID_PATH = /^[MLQCZmlqcz0-9eE.,\- ]+$/;

test("roundCoord rounds to one decimal and never yields NaN or -0", () => {
  assert.equal(roundCoord(12.345), 12.3);
  assert.equal(roundCoord(12.35), 12.4);
  assert.equal(roundCoord(0.1 + 0.2), 0.3);
  assert.equal(roundCoord(-0.04), 0);
  assert.ok(!Object.is(roundCoord(-0.04), -0));
  assert.equal(roundCoord(NaN), null);
  assert.equal(roundCoord(Infinity), null);
  assert.equal(roundCoord(undefined), null);
  assert.equal(roundCoord("3"), null);
  // Clamped: plain decimal notation only.
  assert.equal(String(roundCoord(1e25)), "100000");
  assert.equal(String(roundCoord(-1e25)), "-100000");
});

test("toViewBox maps client pixels through the inverse screen CTM", () => {
  // An 800x450 viewBox shown 724 px wide at (100, 50): scale 800/724.
  const s = 800 / 724;
  const inverse = { a: s, b: 0, c: 0, d: s, e: -100 * s, f: -50 * s };
  assert.deepEqual(toViewBox(inverse, 100, 50), [0, 0]);
  assert.deepEqual(toViewBox(inverse, 824, 457.25), [800, 450]);
  assert.deepEqual(toViewBox(inverse, 462, 253.625), [400, 225]);
  // Outside the canvas (pointer capture): negative and out-of-range values.
  assert.deepEqual(toViewBox(inverse, 90, 40), [-11, -11]);
  assert.equal(toViewBox(inverse, NaN, 10), null);
  assert.equal(toViewBox(null, 1, 1), null);
});

test("toViewBox handles letterboxing (meet) offsets", () => {
  // A 400x225 viewBox in a 360x220 box: scale 0.9, content centered with
  // (220 - 202.5) / 2 = 8.75 px bands above and below.
  const k = 1 / 0.9;
  const inverse = { a: k, b: 0, c: 0, d: k, e: 0, f: -8.75 * k };
  assert.deepEqual(toViewBox(inverse, 0, 8.75), [0, 0]);
  assert.deepEqual(toViewBox(inverse, 360, 211.25), [400, 225]);
});

test("midpoint is rounded", () => {
  assert.deepEqual(midpoint([0, 0], [1, 1]), [0.5, 0.5]);
  assert.deepEqual(midpoint([0.1, 0.2], [0.2, 0.3]), [0.2, 0.3]);
});

test("a tap commits a zero-length segment (a round-cap dot)", () => {
  const b = createStrokeBuilder();
  assert.equal(b.start([10, 20.5]), "M 10 20.5");
  assert.equal(b.path(), "M 10 20.5 L 10 20.5");
  assert.equal(b.length(), b.path().length);
});

test("points closer than the minimum distance are dropped", () => {
  const b = createStrokeBuilder();
  b.start([10, 10]);
  assert.equal(MIN_DISTANCE, 1);
  assert.equal(b.add([10.5, 10.5]), false);
  assert.equal(b.add([10, 10]), false);
  assert.equal(b.path(), "M 10 10 L 10 10");
  // Exactly the minimum distance is kept.
  assert.equal(b.add([11, 10]), "");
  assert.equal(b.path(), "M 10 10 L 11 10");
});

test("quadratic midpoint curves: only final segments are emitted", () => {
  const b = createStrokeBuilder();
  const deltas = [b.start([0, 0])];
  deltas.push(b.add([10, 0]));
  assert.equal(deltas[1], "");
  assert.equal(b.path(), "M 0 0 L 10 0");

  deltas.push(b.add([10, 10]));
  assert.equal(deltas[2], " Q 10 0 10 5");
  assert.equal(b.path(), "M 0 0 Q 10 0 10 5 L 10 10");

  deltas.push(b.add([0, 10]));
  assert.equal(deltas[3], " Q 10 10 5 10");
  assert.equal(b.path(), "M 0 0 Q 10 0 10 5 Q 10 10 5 10 L 0 10");

  // What viewers append (the deltas) is the committed path minus the tail.
  const tail = " L 0 10";
  assert.equal(deltas.join("") + tail, b.path());
  assert.equal(b.length(), b.path().length);
  assert.deepEqual(b.lastPoint(), [0, 10]);
});

test("a fast circle stays in the server's path format and has no NaN", () => {
  const b = createStrokeBuilder();
  b.start([400, 125]);
  for (let i = 1; i <= 64; i++) {
    const a = (i / 64) * 2 * Math.PI;
    b.add([roundCoord(300 + 100 * Math.cos(a)), roundCoord(125 + 100 * Math.sin(a))]);
  }
  const path = b.path();
  assert.match(path, VALID_PATH);
  assert.ok(!path.includes("NaN"));
  assert.ok((path.match(/Q/g) || []).length >= 60);
});

test("a long gesture reaches SPLIT_AT well below the demo board's 8,000 cap", () => {
  const b = createStrokeBuilder();
  b.start([-1234.5, -1234.5]);
  let x = -1234.5;
  let longest = 0;
  while (b.length() < SPLIT_AT) {
    x = roundCoord(x + 1.3);
    b.add([x, roundCoord(-1234.5 + (x % 7))]);
    longest = b.length();
  }
  // The engine splits as soon as length() >= SPLIT_AT: one segment past it.
  assert.ok(longest >= SPLIT_AT);
  assert.ok(longest < SPLIT_AT + 60, "split stroke is " + longest + " characters");
  assert.ok(longest < 8000);
  assert.match(b.path(), VALID_PATH);
  assert.equal(SPLIT_AT, 7000);

  // The next stroke continues from the same point.
  const from = b.lastPoint();
  const next = createStrokeBuilder();
  assert.equal(next.start(from), "M " + from[0] + " " + from[1]);
});

test("startDelta starts a viewer's path that joined mid-stroke", () => {
  assert.equal(startDelta("M 1 2 Q 3 4 5 6"), "M 1 2 Q 3 4 5 6");
  assert.equal(startDelta(" Q 3 4 5 6 Q 7 8 9 10"), "M 5 6 Q 7 8 9 10");
  assert.equal(startDelta(" Q -3.5 4 -5.5 6.1"), "M -5.5 6.1");
  assert.equal(startDelta(" L 7 8 L 9 10"), "M 7 8 L 9 10");
  assert.equal(startDelta(" Z"), null);
  assert.equal(startDelta(""), null);
  assert.equal(startDelta(null), null);
});

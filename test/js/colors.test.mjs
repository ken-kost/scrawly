// The colour picker's math (lib/scrawly_web/pages/colors.mjs): hex parsing,
// HSV <-> #rrggbb, the wheel's geometry, and the saved colours' rules.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  MAX_SAVED,
  SAVED_KEY,
  addSavedColor,
  hexToRgb,
  hsvFromHex,
  hsvToHex,
  hsvToRgb,
  parseHex,
  removeSavedColor,
  rgbToHex,
  rgbToHsv,
  savedColorsFrom,
  wheelHsv,
  wheelPoint,
} from "../../lib/scrawly_web/pages/colors.mjs";

// Every channel value in steps of 17 (0, 17, ..., 255) and a seeded spread
// of others: 4,913 + 3,000 colours.
function sampleColors() {
  const out = [];
  for (let r = 0; r <= 255; r += 17)
    for (let g = 0; g <= 255; g += 17) for (let b = 0; b <= 255; b += 17) out.push({ r, g, b });
  let seed = 40;
  const next = () => (seed = (seed * 1103515245 + 12345) % 2147483648) % 256;
  for (let i = 0; i < 3000; i++) out.push({ r: next(), g: next(), b: next() });
  return out;
}

function assertWithinOne(hex, expected, label) {
  const a = hexToRgb(hex);
  const e = hexToRgb(expected);
  for (const c of ["r", "g", "b"]) {
    assert.ok(Math.abs(a[c] - e[c]) <= 1, `${label}: ${hex} vs ${expected} (${c})`);
  }
}

// ── Hex ──────────────────────────────────────────────────────────────

test("parseHex takes #rrggbb and rrggbb, in either case, as lowercase #rrggbb", () => {
  assert.equal(parseHex("#a1b2c3"), "#a1b2c3");
  assert.equal(parseHex("A1B2C3"), "#a1b2c3");
  assert.equal(parseHex("#ABCDEF"), "#abcdef");
  assert.equal(parseHex("#aBcDeF"), "#abcdef");
  assert.equal(parseHex("000000"), "#000000");
});

test("parseHex rejects anything else", () => {
  for (const bad of [
    "",
    "#",
    "#abc",
    "abc",
    "#abcde",
    "#abcdef0",
    "##abcdef",
    "#abcdeg",
    " #abcdef",
    "#abcdef ",
    "+abcdef",
    "-abcdef",
    "0xabcdef",
    "red",
    "rgb(0, 0, 0)",
    "#ab cdef",
    null,
    undefined,
    123456,
    ["#abcdef"],
    { hex: "#abcdef" },
  ]) {
    assert.equal(parseHex(bad), null, JSON.stringify(bad));
  }
});

test("hexToRgb and rgbToHex are inverse; rgbToHex rounds and clamps", () => {
  for (const rgb of sampleColors()) assert.deepEqual(hexToRgb(rgbToHex(rgb)), rgb);
  assert.deepEqual(hexToRgb("#ff8000"), { r: 255, g: 128, b: 0 });
  assert.equal(hexToRgb("nope"), null);
  assert.equal(rgbToHex({ r: 254.6, g: -3, b: 300 }), "#ff00ff");
  assert.equal(rgbToHex({ r: 0.4, g: 15.5, b: 16 }), "#001010");
});

// ── HSV ──────────────────────────────────────────────────────────────

test("HSV to #rrggbb for the wheel's landmarks", () => {
  assert.equal(hsvToHex({ h: 0, s: 1, v: 1 }), "#ff0000");
  assert.equal(hsvToHex({ h: 60, s: 1, v: 1 }), "#ffff00");
  assert.equal(hsvToHex({ h: 120, s: 1, v: 1 }), "#00ff00");
  assert.equal(hsvToHex({ h: 180, s: 1, v: 1 }), "#00ffff");
  assert.equal(hsvToHex({ h: 240, s: 1, v: 1 }), "#0000ff");
  assert.equal(hsvToHex({ h: 300, s: 1, v: 1 }), "#ff00ff");
  assert.equal(hsvToHex({ h: 360, s: 1, v: 1 }), "#ff0000");
  assert.equal(hsvToHex({ h: -120, s: 1, v: 1 }), "#0000ff");
  assert.equal(hsvToHex({ h: 200, s: 0, v: 1 }), "#ffffff");
  assert.equal(hsvToHex({ h: 200, s: 1, v: 0 }), "#000000");
  assert.equal(hsvToHex({ h: 0, s: 0.5, v: 1 }), "#ff8080");
  // Out of range is clamped, junk is 0.
  assert.equal(hsvToHex({ h: 0, s: 7, v: 2 }), "#ff0000");
  assert.equal(hsvToHex({ h: "x", s: null, v: 1 }), "#ffffff");
});

test("#rrggbb -> HSV -> #rrggbb is exact (within 1 per channel) for every sample", () => {
  for (const rgb of sampleColors()) {
    const hex = rgbToHex(rgb);
    const hsv = rgbToHsv(rgb);
    assert.ok(hsv.h >= 0 && hsv.h < 360 && hsv.s >= 0 && hsv.s <= 1 && hsv.v >= 0 && hsv.v <= 1, hex);
    assertWithinOne(hsvToHex(hsv), hex, "hsv");
    assertWithinOne(hsvToHex(hsvFromHex(hex, { h: 77, s: 0.3, v: 0.6 })), hex, "hsvFromHex");
  }
});

test("HSV -> #rrggbb -> HSV -> #rrggbb is stable", () => {
  for (let h = 0; h < 360; h += 7.5)
    for (const s of [0, 0.13, 0.5, 0.77, 1])
      for (const v of [0.05, 0.4, 0.81, 1]) {
        const hex = hsvToHex({ h, s, v });
        assert.equal(hsvToHex(rgbToHsv(hexToRgb(hex))), hex);
        const raw = hsvToRgb({ h, s, v });
        for (const c of ["r", "g", "b"]) assert.ok(raw[c] >= 0 && raw[c] <= 255);
      }
});

test("hsvFromHex keeps the wheel's hue for a grey and its hue and saturation for black", () => {
  const prev = { h: 210, s: 0.6, v: 0.9 };
  assert.deepEqual(hsvFromHex("#808080", prev), { h: 210, s: 0, v: 128 / 255 });
  assert.deepEqual(hsvFromHex("#000000", prev), { h: 210, s: 0.6, v: 0 });
  // The wheel's own HSV when it already makes this colour (finer than hex).
  const fine = { h: 12.34, s: 0.567, v: 0.891 };
  assert.deepEqual(hsvFromHex(hsvToHex(fine), fine), fine);
  // Otherwise the colour's own.
  const red = hsvFromHex("#FF0000", prev);
  assert.deepEqual(red, { h: 0, s: 1, v: 1 });
  assert.equal(hsvFromHex("#zzzzzz", prev), null);
  assert.deepEqual(hsvFromHex("#000000", null), { h: 0, s: 0, v: 0 });
});

// ── The wheel ────────────────────────────────────────────────────────

test("the wheel: red at the right, counter-clockwise, saturation by distance", () => {
  const R = 76;
  assert.deepEqual(wheelHsv(0, 0, R), { h: 0, s: 0 });
  assert.deepEqual(wheelHsv(R, 0, R), { h: 0, s: 1 });
  assert.deepEqual(wheelHsv(0, -R, R), { h: 90, s: 1 });
  assert.deepEqual(wheelHsv(-R / 2, 0, R), { h: 180, s: 0.5 });
  assert.deepEqual(wheelHsv(0, R, R), { h: 270, s: 1 });
  // Beyond the rim: the rim.
  assert.deepEqual(wheelHsv(3 * R, 0, R), { h: 0, s: 1 });
  const p = wheelPoint(90, 0.5, R);
  assert.ok(Math.abs(p.x) < 1e-9 && Math.abs(p.y + R / 2) < 1e-9);
});

test("#rrggbb -> a point on the wheel (+ brightness) -> #rrggbb, within 1 per channel", () => {
  for (const R of [76, 50.5]) {
    for (const rgb of sampleColors()) {
      const hex = rgbToHex(rgb);
      const hsv = hsvFromHex(hex, null);
      const p = wheelPoint(hsv.h, hsv.s, R);
      // As a pointer reports it: to the hundredth of a CSS pixel.
      const x = Math.round(p.x * 100) / 100;
      const y = Math.round(p.y * 100) / 100;
      const back = wheelHsv(x, y, R);
      assertWithinOne(hsvToHex({ h: back.h, s: back.s, v: hsv.v }), hex, `wheel R=${R}`);
    }
  }
});

// ── Saved colours ────────────────────────────────────────────────────

test("saving puts the colour first, once (in any case), and keeps 12", () => {
  assert.equal(MAX_SAVED, 12);
  assert.equal(SAVED_KEY, "scrawly:saved-colors");
  assert.deepEqual(addSavedColor([], "#AABBCC"), ["#aabbcc"]);
  assert.deepEqual(addSavedColor(["#111111", "#222222"], "#333333"), ["#333333", "#111111", "#222222"]);
  // Saved already: moves to the front, still once.
  assert.deepEqual(addSavedColor(["#111111", "#222222", "#333333"], "#222222"), [
    "#222222",
    "#111111",
    "#333333",
  ]);
  assert.deepEqual(addSavedColor(["#aabbcc", "#111111"], "#AABBCC"), ["#aabbcc", "#111111"]);
  // A 13th drops the oldest.
  const twelve = Array.from({ length: 12 }, (_, i) => "#0000" + (10 + i).toString(16).padStart(2, "0"));
  const thirteen = addSavedColor(twelve, "#ffffff");
  assert.equal(thirteen.length, 12);
  assert.equal(thirteen[0], "#ffffff");
  assert.deepEqual(thirteen.slice(1), twelve.slice(0, 11));
  assert.ok(!thirteen.includes(twelve[11]));
  // Not a colour: the list as it was (a copy).
  const list = ["#111111"];
  for (const bad of [null, "red", "#12345", 7]) {
    const out = addSavedColor(list, bad);
    assert.deepEqual(out, list);
    assert.notEqual(out, list);
  }
  assert.deepEqual(addSavedColor(null, "#123456"), ["#123456"]);
});

test("removing takes the colour out in any case; others stay in order", () => {
  assert.deepEqual(removeSavedColor(["#111111", "#aabbcc", "#222222"], "#AABBCC"), ["#111111", "#222222"]);
  assert.deepEqual(removeSavedColor(["#111111"], "#999999"), ["#111111"]);
  assert.deepEqual(removeSavedColor(["#111111"], null), ["#111111"]);
  assert.deepEqual(removeSavedColor(undefined, "#111111"), []);
});

test("reading tolerates a missing key, junk, a non-array and non-colour entries", () => {
  for (const raw of [null, undefined, "", "not json", "{", "{}", '{"a": 1}', '"#aabbcc"', "12", "null", "true"]) {
    assert.deepEqual(savedColorsFrom(raw), [], String(raw));
  }
  assert.deepEqual(savedColorsFrom("[]"), []);
  assert.deepEqual(
    savedColorsFrom(JSON.stringify(["#AABBCC", "red", 7, null, "aabbcc", "#abc", "#aabbcc", "#123456 ", "#00ff00", {}, []])),
    ["#aabbcc", "#00ff00"],
  );
  const twenty = Array.from({ length: 20 }, (_, i) => "#0000" + (16 + i).toString(16));
  assert.deepEqual(savedColorsFrom(JSON.stringify(twenty)), twenty.slice(0, 12));
});

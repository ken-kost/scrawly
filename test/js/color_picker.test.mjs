// The colour panel's native side (lib/scrawly_web/pages/color_picker.mjs):
// the throttle that brings the page's state along, the wheel's pixels, its
// keys, the swatch grid's arrows, the saved colours in localStorage, and the
// panel's events on a fake panel (a drag writes the tool at once and sends
// throttled actions; the hex field; the brightness; "+ save"; removal;
// Escape).
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { installFakeDom } from "./support/fake_dom.mjs";

const { dispatched } = installFakeDom();

// localStorage, swappable per test.
const store = new Map();
let storageMode = "ok";
globalThis.localStorage = {
  getItem(k) {
    if (storageMode === "throw") throw new Error("SecurityError");
    return store.has(k) ? store.get(k) : null;
  },
  setItem(k, v) {
    if (storageMode === "throw" || storageMode === "full") throw new Error("QuotaExceededError");
    store.set(k, String(v));
  },
};

const picker = await import("../../lib/scrawly_web/pages/color_picker.mjs");
const tools = await import("../../lib/scrawly_web/pages/draw_tools.mjs");
const colors = await import("../../lib/scrawly_web/pages/colors.mjs");
const controls = await import("../../lib/scrawly_web/pages/draw_controls.mjs");

const {
  DARK_V,
  PICK_HTML,
  THROTTLE_MS,
  createThrottle,
  forgetColor,
  gridMove,
  paintWheel,
  saveColor,
  savedColors,
  wheelKey,
  wheelValue,
} = picker;
const { SAVED_KEY, hexToRgb, hsvToHex, rgbToHsv } = colors;

beforeEach(() => {
  store.clear();
  storageMode = "ok";
  dispatched.length = 0;
  tools.resetDrawTool();
});


// ── A fake clock for the throttle ────────────────────────────────────

function fakeClock() {
  let now = 0;
  let timers = [];
  let id = 0;
  return {
    now: () => now,
    set(fn, ms) {
      timers.push({ id: ++id, at: now + ms, fn });
      return id;
    },
    clear(i) {
      timers = timers.filter((t) => t.id !== i);
    },
    advance(ms) {
      const end = now + ms;
      for (;;) {
        const due = timers.filter((t) => t.at <= end).sort((a, b) => a.at - b.at)[0];
        if (!due) break;
        timers = timers.filter((t) => t !== due);
        now = due.at;
        due.fn();
      }
      now = end;
    },
  };
}

// ── Pure parts ───────────────────────────────────────────────────────

test("the throttle: the first value at once, the latest of each window after it, flush sends now", () => {
  const clock = fakeClock();
  const sent = [];
  const t = createThrottle((v) => sent.push([clock.now(), v]), 100, clock);
  t.push("a");
  assert.deepEqual(sent, [[0, "a"]]);
  clock.advance(30);
  t.push("b");
  clock.advance(30);
  t.push("c");
  assert.equal(sent.length, 1);
  clock.advance(40);
  assert.deepEqual(sent[1], [100, "c"]);
  // Quiet: nothing more.
  clock.advance(500);
  assert.equal(sent.length, 2);
  // After a quiet spell the next value goes at once again.
  t.push("d");
  assert.deepEqual(sent[2], [600, "d"]);
  // flush: a pending value now, then nothing pending.
  clock.advance(10);
  t.push("e");
  t.flush();
  assert.deepEqual(sent[3], [610, "e"]);
  t.flush();
  clock.advance(1000);
  assert.equal(sent.length, 4);
});

test("the throttle over a 1 s drag at 60 Hz sends about one value per 100 ms, the last one last", () => {
  const clock = fakeClock();
  const sent = [];
  const t = createThrottle((v) => sent.push(v), THROTTLE_MS, clock);
  let i = 0;
  for (; i < 60; i++) {
    t.push(i);
    clock.advance(1000 / 60);
  }
  t.flush();
  assert.ok(sent.length >= 10 && sent.length <= 12, String(sent.length));
  assert.equal(sent.at(-1), 59);
});

test("the wheel's pixels: white in the middle, red at the right, transparent outside, an anti-aliased rim", () => {
  const px = 152;
  const data = new Uint8ClampedArray(px * px * 4);
  paintWheel(data, px);
  const at = (x, y) => Array.from(data.slice((y * px + x) * 4, (y * px + x) * 4 + 4));
  const [r, g, b, a] = at(75, 75);
  assert.ok(r > 250 && g > 250 && b > 250 && a === 255, "centre");
  const red = at(150, 76);
  assert.ok(red[0] === 255 && red[1] < 10 && red[2] < 10, "right: red " + red);
  const top = at(76, 2);
  // Hue 90: rgb(128, 255, 0).
  assert.ok(Math.abs(top[0] - 128) < 10 && top[1] === 255 && top[2] < 10, "top " + top);
  assert.deepEqual(at(0, 0), [0, 0, 0, 0]);
  assert.deepEqual(at(151, 151), [0, 0, 0, 0]);
  const rim = at(0, 76)[3];
  assert.ok(rim > 0 && rim < 255, "rim alpha " + rim);
});

test("a pick on a wheel too dark to see starts at full brightness", () => {
  assert.equal(wheelValue(0), 1);
  assert.equal(wheelValue(0.04), 1);
  assert.equal(wheelValue(DARK_V - 0.01), 1);
  assert.equal(wheelValue(DARK_V), DARK_V);
  assert.equal(wheelValue(0.5), 0.5);
});

test("the wheel's arrow keys turn the hue and change the saturation; Shift is bigger steps", () => {
  const hsv = { h: 10, s: 0.5, v: 0.8 };
  assert.deepEqual(wheelKey(hsv, "ArrowRight", false), { h: 15, s: 0.5, v: 0.8 });
  assert.deepEqual(wheelKey(hsv, "ArrowLeft", false), { h: 5, s: 0.5, v: 0.8 });
  assert.deepEqual(wheelKey(hsv, "ArrowLeft", true), { h: 340, s: 0.5, v: 0.8 });
  assert.deepEqual(wheelKey({ ...hsv, h: 358 }, "ArrowRight", false), { h: 3, s: 0.5, v: 0.8 });
  assert.deepEqual(wheelKey(hsv, "ArrowUp", false), { h: 10, s: 0.55, v: 0.8 });
  assert.deepEqual(wheelKey(hsv, "ArrowDown", true), { h: 10, s: 0.2, v: 0.8 });
  assert.deepEqual(wheelKey({ ...hsv, s: 0.98 }, "ArrowUp", true).s, 1);
  assert.deepEqual(wheelKey({ ...hsv, s: 0.02 }, "ArrowDown", false).s, 0);
  // Black: the key picks at full brightness.
  assert.equal(wheelKey({ h: 0, s: 0, v: 0.03 }, "ArrowUp", false).v, 1);
  assert.equal(wheelKey(hsv, "Enter", false), null);
  assert.equal(wheelKey(hsv, "e", false), null);
});

test("arrows move through the grid by one and by a row; off the edge stays; Home / End", () => {
  // 24 presets in rows of 12, then 3 saved colours.
  assert.equal(gridMove(0, 27, 12, "ArrowRight"), 1);
  assert.equal(gridMove(0, 27, 12, "ArrowLeft"), 0);
  assert.equal(gridMove(5, 27, 12, "ArrowDown"), 17);
  assert.equal(gridMove(17, 27, 12, "ArrowUp"), 5);
  assert.equal(gridMove(5, 27, 12, "ArrowUp"), 5);
  assert.equal(gridMove(13, 27, 12, "ArrowDown"), 25);
  // Down from a column the saved row doesn't reach: its last swatch.
  assert.equal(gridMove(20, 27, 12, "ArrowDown"), 26);
  assert.equal(gridMove(26, 27, 12, "ArrowDown"), 26);
  assert.equal(gridMove(26, 27, 12, "ArrowRight"), 26);
  // Without saved colours, down from the second row stays.
  assert.equal(gridMove(20, 24, 12, "ArrowDown"), 20);
  assert.equal(gridMove(9, 27, 12, "Home"), 0);
  assert.equal(gridMove(9, 27, 12, "End"), 26);
  assert.equal(gridMove(9, 27, 12, "Enter"), null);
});

test("the panel's controls carry every hook the module looks for", () => {
  for (const hook of [
    "data-color-wheel",
    "data-color-shade",
    "data-color-marker",
    "data-color-now",
    "data-color-was",
    "data-color-hex",
    "data-color-save",
    "data-color-value",
    "<canvas",
    'role="slider"',
    'aria-label="hex colour"',
    'aria-label="brightness"',
  ]) {
    assert.ok(PICK_HTML.includes(hook), hook);
  }
  // No page state in it: nothing a render could make stale.
  assert.ok(!/style=|value="#/.test(PICK_HTML));
});

// ── Saved colours in localStorage ─────────────────────────────────────

test("saved colours: none at first; + save stores the tool's colour, newest first, 12 kept", () => {
  assert.deepEqual(savedColors(), []);
  tools.setDrawTool({ color: "#123456" });
  assert.deepEqual(saveColor(), ["#123456"]);
  tools.setDrawTool({ color: "#abcdef", tool: "eraser" });
  assert.deepEqual(saveColor(), ["#abcdef", "#123456"]);
  assert.deepEqual(JSON.parse(store.get(SAVED_KEY)), ["#abcdef", "#123456"]);
  // Again: to the front, once.
  tools.setDrawTool({ color: "#123456" });
  assert.deepEqual(saveColor(), ["#123456", "#abcdef"]);
  for (let i = 0; i < 12; i++) {
    tools.setDrawTool({ color: "#0000" + (16 + i).toString(16) });
    saveColor();
  }
  const list = savedColors();
  assert.equal(list.length, 12);
  assert.equal(list[0], "#00001b");
  assert.ok(!list.includes("#abcdef"));
  assert.deepEqual(forgetColor("#00001B"), list.slice(1));
  assert.deepEqual(savedColors(), list.slice(1));
});

test("saved colours: a corrupt or foreign value reads as none, or as its colours", () => {
  for (const raw of ["oops", "{}", "42", '"#aabbcc"', "[1, 2]"]) {
    store.set(SAVED_KEY, raw);
    assert.deepEqual(savedColors(), [], raw);
  }
  store.set(SAVED_KEY, '["#AABBCC", "junk", "#aabbcc", "#00ff00"]');
  assert.deepEqual(savedColors(), ["#aabbcc", "#00ff00"]);
  // Saving over junk starts a clean list.
  store.set(SAVED_KEY, "oops");
  tools.setDrawTool({ color: "#ff0000" });
  assert.deepEqual(saveColor(), ["#ff0000"]);
});

test("saved colours: storage that throws (private mode, full) never breaks the page", () => {
  storageMode = "throw";
  assert.deepEqual(savedColors(), []);
  tools.setDrawTool({ color: "#ff0000" });
  assert.deepEqual(saveColor(), ["#ff0000"]);
  assert.deepEqual(forgetColor("#ff0000"), []);
  storageMode = "full";
  store.set(SAVED_KEY, '["#00ff00"]');
  assert.deepEqual(saveColor(), ["#ff0000", "#00ff00"]);
  assert.deepEqual(JSON.parse(store.get(SAVED_KEY)), ["#00ff00"]);
});

// ── The panel, on a fake DOM ──────────────────────────────────────────

// Elements matched by "[attr]", ".class", a tag, or a descendant pair of
// those; enough for the module's selectors.
class El {
  constructor(tag, attrs = {}, cls = "") {
    this.tagName = tag.toUpperCase();
    this.attrs = { ...attrs };
    this.classes = cls.split(" ").filter(Boolean);
    this.children = [];
    this.parent = null;
    this.style = {
      setProperty(k, v) {
        this[k] = v;
      },
    };
    this.value = "";
    this.isConnected = true;
    this.clientWidth = 0;
    this.offsetParent = {};
    this.offsetTop = 0;
  }
  add(...kids) {
    for (const k of kids) {
      k.parent = this;
      this.children.push(k);
    }
    return this;
  }
  hasAttribute(n) {
    return n in this.attrs;
  }
  getAttribute(n) {
    return n in this.attrs ? this.attrs[n] : null;
  }
  setAttribute(n, v) {
    this.attrs[n] = String(v);
  }
  removeAttribute(n) {
    delete this.attrs[n];
  }
  matchesOne(sel) {
    if (sel.startsWith("[")) return sel.slice(1, -1) in this.attrs;
    if (sel.startsWith(".")) return this.classes.includes(sel.slice(1));
    return this.tagName === sel.toUpperCase();
  }
  matches(sel) {
    const parts = sel.split(" ");
    if (!this.matchesOne(parts.at(-1))) return false;
    if (parts.length === 1) return true;
    let n = this.parent;
    while (n) {
      if (n.matchesOne(parts[0])) return true;
      n = n.parent;
    }
    return false;
  }
  closest(sel) {
    let n = this;
    while (n) {
      if (n.matches(sel)) return n;
      n = n.parent;
    }
    return null;
  }
  get firstChild() {
    return this.children[0] || null;
  }
  all(sel, out = []) {
    for (const c of this.children) {
      if (c.matches(sel)) out.push(c);
      c.all(sel, out);
    }
    return out;
  }
  querySelector(sel) {
    return this.all(sel)[0] || null;
  }
  querySelectorAll(sel) {
    return this.all(sel);
  }
  focus() {
    focused = this;
  }
}

let focused = null;

// DrawingToolbar's colour control; its [data-color-pick] fills from
// PICK_HTML (the fake builds the same hooks).
function renderControl(saved = []) {
  const control = new El("div", { "data-color-control": "" }, "color-control");
  const chip = new El("button", { "data-color-open": "" }, "tool-btn color-chip");
  const sheet = new El("div", {}, "color-sheet");
  const grid = new El("div", { "data-swatch-grid": "" }, "color-grid");
  const presets = new El("div", {}, "swatches");
  for (let i = 0; i < 24; i++) {
    const b = new El("button", {}, "swatch");
    b.offsetTop = i < 12 ? 0 : 24;
    presets.add(b);
  }
  const savedRow = new El("div", {}, "saved-colors");
  saved.forEach((c) => {
    const s = new El("button", { "data-saved-color": c }, "swatch");
    s.offsetTop = 48;
    const x = new El("button", { "data-color-forget": c }, "saved-remove");
    savedRow.add(new El("span", {}, "saved-item").add(s, x));
  });
  grid.add(presets, savedRow);
  const pick = new El("div", { "data-color-pick": "" }, "color-pick");
  const built = [];
  Object.defineProperty(pick, "innerHTML", {
    set(html) {
      pick.html = html;
      const wheel = new El("div", { "data-color-wheel": "" }, "color-wheel");
      wheel.clientWidth = 152;
      wheel.getBoundingClientRect = () => ({ left: 100, top: 200, width: 152, height: 152 });
      wheel.captured = [];
      wheel.setPointerCapture = (id) => wheel.captured.push(id);
      wheel.add(
        new El("canvas", {}, "color-wheel-canvas"),
        new El("span", { "data-color-shade": "" }),
        new El("span", { "data-color-marker": "" }),
      );
      const side = new El("div", {}, "color-side").add(
        new El("span", { "data-color-now": "" }),
        new El("button", { "data-color-was": "" }),
        new El("input", { "data-color-hex": "" }),
        new El("button", { "data-color-save": "" }),
      );
      pick.add(wheel, side, new El("input", { "data-color-value": "" }));
      built.push(html);
    },
  });
  control.add(chip, sheet.add(grid, new El("div", {}, "color-panel").add(pick)));
  const q = (s) => control.querySelector(s);
  return {
    control,
    chip,
    pick,
    built,
    grid,
    presets: presets.children,
    saved: savedRow.children.map((i) => i.children[0]),
    removes: savedRow.children.map((i) => i.children[1]),
    get wheel() {
      return q("[data-color-wheel]");
    },
    get hex() {
      return q("[data-color-hex]");
    },
    get value() {
      return q("[data-color-value]");
    },
    get marker() {
      return q("[data-color-marker]");
    },
    get shade() {
      return q("[data-color-shade]");
    },
    get now() {
      return q("[data-color-now]");
    },
    get was() {
      return q("[data-color-was]");
    },
    get save() {
      return q("[data-color-save]");
    },
  };
}

// Installed once per tab, here with the fake clock (draw_controls.mjs's
// install would then find it installed).
const clock = fakeClock();
picker.installColorPicker(clock);

const fire = (type, e) => globalThis.__fire(type, e);
const ev = (target, extra = {}) => ({
  target,
  defaultPrevented: false,
  preventDefault() {
    this.defaultPrevented = true;
  },
  ...extra,
});
const picked = () => dispatched.filter((d) => d.name === "color_picked").map((d) => d.params.color);

function open(ui) {
  fire("click", ev(ui.chip));
}

test("the chip prepares the panel: builds its controls once and fills them from the tool", () => {
  tools.setDrawTool({ color: "#3366cc" });
  const ui = renderControl();
  open(ui);
  assert.deepEqual(ui.built, [PICK_HTML]);
  assert.equal(ui.hex.value, "#3366cc");
  assert.equal(ui.was.style.background, "#3366cc");
  assert.equal(ui.was.getAttribute("aria-label"), "back to #3366cc");
  assert.equal(ui.now.style.background, "#3366cc");
  const hsv = rgbToHsv(hexToRgb("#3366cc"));
  assert.equal(ui.value.value, String(Math.round(hsv.v * 100)));
  assert.equal(ui.wheel.getAttribute("aria-valuenow"), String(Math.round(hsv.h)));
  assert.match(ui.wheel.getAttribute("aria-valuetext"), /^hue \d+°, saturation \d+%$/);
  assert.match(ui.marker.style.transform, /^translate\([\d.]+px, [\d.]+px\)$/);
  // Opening sends nothing.
  assert.deepEqual(dispatched, []);
  open(ui);
  assert.equal(ui.built.length, 1);
});

test("a 1 s drag on the wheel writes the tool on every move and sends ~10 throttled actions", () => {
  tools.setDrawTool({ color: "#0a0a0a", tool: "eraser" });
  const ui = renderControl();
  open(ui);
  clock.advance(1000);
  const cx = 100 + 76;
  const cy = 200 + 76;
  const at = (i) => ({ x: cx + 60 * Math.cos(i / 10), y: cy - 60 * Math.sin(i / 10) });
  let p = at(0);
  fire("pointerdown", ev(ui.wheel, { pointerId: 7, pointerType: "mouse", button: 0, clientX: p.x, clientY: p.y }));
  assert.deepEqual(ui.wheel.captured, [7]);
  const models = [];
  for (let i = 1; i <= 60; i++) {
    clock.advance(1000 / 60);
    p = at(i);
    fire("pointermove", ev(ui.wheel, { pointerId: 7, clientX: p.x, clientY: p.y }));
    const tool = tools.currentTool();
    models.push(tool.color);
    // At once: the brush, in the colour under the pointer, shown in the panel.
    assert.equal(tool.tool, "brush");
    assert.equal(ui.hex.value, tool.color);
    assert.equal(ui.now.style.background, tool.color);
  }
  // A pointer that isn't the drag's changes nothing.
  const before = tools.currentTool().color;
  fire("pointermove", ev(ui.wheel, { pointerId: 8, clientX: cx, clientY: cy }));
  assert.equal(tools.currentTool().color, before);
  fire("pointerup", ev(ui.wheel, { pointerId: 7 }));

  assert.ok(new Set(models).size > 30, "the colour follows the pointer");
  // The wheel at full brightness although the tool was black.
  const hsv = rgbToHsv(hexToRgb(models.at(-1)));
  assert.ok(Math.abs(hsv.v - 1) < 0.01 && hsv.s > 0.7, JSON.stringify(hsv));
  const sent = picked();
  assert.ok(sent.length >= 10 && sent.length <= 12, `${sent.length} actions`);
  assert.equal(sent.at(-1), tools.currentTool().color);
  assert.ok(dispatched.every((d) => d.name === "color_picked" && d.target === "page"));
  // Nothing after the drag.
  clock.advance(1000);
  assert.equal(picked().length, sent.length);
});

test("with the fill selected the panel keeps the fill, and color_picked says so", () => {
  tools.setDrawTool({ color: "#0a0a0a", tool: "fill" });
  const ui = renderControl();
  open(ui);
  clock.advance(1000);
  fire("pointerdown", ev(ui.wheel, { pointerId: 9, pointerType: "mouse", button: 0, clientX: 100 + 76 + 50, clientY: 200 + 76 }));
  fire("pointerup", ev(ui.wheel, { pointerId: 9 }));
  assert.equal(tools.currentTool().tool, "fill");
  const sent = dispatched.filter((d) => d.name === "color_picked").at(-1);
  assert.deepEqual(sent.params, { color: tools.currentTool().color, tool: "fill" });
  tools.setDrawTool({ tool: "brush" });
});

test("a right-button press on the wheel picks nothing", () => {
  const ui = renderControl();
  open(ui);
  fire("pointerdown", ev(ui.wheel, { pointerId: 3, pointerType: "mouse", button: 2, clientX: 250, clientY: 276 }));
  assert.equal(tools.currentTool().color, tools.DEFAULT_TOOL.color);
  assert.deepEqual(dispatched, []);
});

test("the brightness slider changes v only: the shade, the colour; its change sends the last", () => {
  tools.setDrawTool({ color: "#ff0000" });
  const ui = renderControl();
  open(ui);
  const marker = ui.marker.style.transform;
  clock.advance(1000);
  for (const v of [80, 60, 40]) {
    ui.value.value = String(v);
    fire("input", ev(ui.value));
    clock.advance(10);
  }
  assert.equal(tools.currentTool().color, hsvToHex({ h: 0, s: 1, v: 0.4 }));
  assert.equal(ui.shade.style.opacity, String(1 - 0.4));
  assert.equal(ui.marker.style.transform, marker);
  assert.equal(ui.value.style["--color-value-top"], "#ff0000");
  assert.equal(picked().length, 1);
  fire("change", ev(ui.value));
  assert.deepEqual(picked(), [hsvToHex({ h: 0, s: 1, v: 0.8 }), "#660000"]);
});

test("the hex field: a whole colour applies at once (in either case, with or without #)", () => {
  const ui = renderControl();
  open(ui);
  ui.hex.value = "12AB9";
  fire("input", ev(ui.hex));
  assert.equal(tools.currentTool().color, tools.DEFAULT_TOOL.color);
  ui.hex.value = "12AB9F";
  fire("input", ev(ui.hex));
  assert.equal(tools.currentTool().color, "#12ab9f");
  assert.deepEqual(picked(), ["#12ab9f"]);
  // The field keeps what is typed while typing; Enter writes it out in full.
  assert.equal(ui.hex.value, "12AB9F");
  fire("keydown", ev(ui.hex, { key: "Enter" }));
  assert.equal(ui.hex.value, "#12ab9f");
  ui.hex.value = " #FFEEDD ";
  fire("input", ev(ui.hex));
  assert.equal(tools.currentTool().color, "#ffeedd");
});

test("the hex field: anything else is marked on Enter and put back on leaving", () => {
  tools.setDrawTool({ color: "#00ff00" });
  const ui = renderControl();
  open(ui);
  ui.hex.value = "#00ff0g";
  fire("input", ev(ui.hex));
  const enter = ev(ui.hex, { key: "Enter" });
  fire("keydown", enter);
  assert.equal(ui.hex.getAttribute("aria-invalid"), "true");
  assert.ok(enter.defaultPrevented);
  fire("change", ev(ui.hex));
  assert.equal(ui.hex.value, "#00ff00");
  assert.equal(ui.hex.getAttribute("aria-invalid"), null);
  assert.equal(tools.currentTool().color, "#00ff00");
  assert.deepEqual(dispatched, []);
});

test("the old colour beside the new one takes the tool back to it", () => {
  tools.setDrawTool({ color: "#abcdef" });
  const ui = renderControl();
  open(ui);
  ui.hex.value = "#000080";
  fire("input", ev(ui.hex));
  fire("click", ev(ui.was));
  assert.equal(tools.currentTool().color, "#abcdef");
  assert.equal(picked().at(-1), "#abcdef");
});

test("the open panel follows a colour picked elsewhere, but not during its own drag", () => {
  const ui = renderControl();
  open(ui);
  tools.setDrawTool({ color: "#ff8800" });
  assert.equal(ui.hex.value, "#ff8800");
  fire("pointerdown", ev(ui.wheel, { pointerId: 1, pointerType: "touch", button: 0, clientX: 176, clientY: 230 }));
  const dragging = ui.hex.value;
  tools.setDrawTool({ color: "#112233" });
  assert.equal(ui.hex.value, dragging);
  fire("pointerup", ev(ui.wheel, { pointerId: 1 }));
  tools.setDrawTool({ color: "#445566" });
  assert.equal(ui.hex.value, "#445566");
});

test("the wheel's keys pick like a drag; key up sends the last", () => {
  tools.setDrawTool({ color: "#ff0000" });
  const ui = renderControl();
  open(ui);
  clock.advance(1000);
  const right = ev(ui.wheel, { key: "ArrowRight", shiftKey: false });
  fire("keydown", right);
  assert.ok(right.defaultPrevented);
  assert.equal(tools.currentTool().color, hsvToHex({ h: 5, s: 1, v: 1 }));
  fire("keydown", ev(ui.wheel, { key: "ArrowDown", shiftKey: true }));
  assert.equal(tools.currentTool().color, hsvToHex({ h: 5, s: 0.7, v: 1 }));
  assert.equal(picked().length, 1);
  fire("keyup", ev(ui.wheel, { key: "ArrowDown" }));
  assert.deepEqual(picked(), [hsvToHex({ h: 5, s: 1, v: 1 }), hsvToHex({ h: 5, s: 0.7, v: 1 })]);
  // Other keys go on to the drawing shortcuts.
  const e = ev(ui.wheel, { key: "e" });
  fire("keydown", e);
  assert.equal(e.defaultPrevented, false);
});

test("+ save stores the tool's colour and sends the list; x and Delete remove one", () => {
  tools.setDrawTool({ color: "#123456" });
  let ui = renderControl();
  open(ui);
  fire("click", ev(ui.save));
  assert.deepEqual(JSON.parse(store.get(SAVED_KEY)), ["#123456"]);
  assert.deepEqual(dispatched.at(-1), { name: "saved_colors", target: "page", params: { colors: ["#123456"] } });
  tools.setDrawTool({ color: "#654321" });
  fire("click", ev(ui.save));
  assert.deepEqual(dispatched.at(-1).params.colors, ["#654321", "#123456"]);

  ui = renderControl(["#654321", "#123456"]);
  fire("click", ev(ui.removes[1]));
  assert.deepEqual(dispatched.at(-1), { name: "saved_colors", target: "page", params: { colors: ["#654321"] } });
  const del = ev(ui.saved[0], { key: "Delete" });
  fire("keydown", del);
  assert.ok(del.defaultPrevented);
  assert.deepEqual(dispatched.at(-1).params.colors, []);
  assert.equal(store.get(SAVED_KEY), "[]");
  // Delete on a preset does nothing.
  const n = dispatched.length;
  fire("keydown", ev(ui.presets[3], { key: "Delete" }));
  assert.equal(dispatched.length, n);
});

test("arrows move focus in the swatch grid, into the saved row and back", () => {
  const ui = renderControl(["#111111", "#222222"]);
  const key = (target, k) => {
    const e = ev(target, { key: k });
    fire("keydown", e);
    return e;
  };
  assert.ok(key(ui.presets[0], "ArrowRight").defaultPrevented);
  assert.equal(focused, ui.presets[1]);
  key(ui.presets[1], "ArrowDown");
  assert.equal(focused, ui.presets[13]);
  key(ui.presets[13], "ArrowDown");
  assert.equal(focused, ui.saved[1]);
  key(ui.saved[1], "ArrowUp");
  assert.equal(focused, ui.presets[13]);
  key(ui.presets[13], "End");
  assert.equal(focused, ui.saved[1]);
  // Modified arrows are the browser's.
  const ctrl = ev(ui.presets[0], { key: "ArrowRight", ctrlKey: true });
  fire("keydown", ctrl);
  assert.equal(ctrl.defaultPrevented, false);
});

test("Escape inside the panel hands focus to the chip and nothing else", () => {
  const ui = renderControl();
  open(ui);
  focused = null;
  const esc = ev(ui.hex, { key: "Escape" });
  fire("keydown", esc);
  assert.equal(focused, ui.chip);
  // The page's own Escape binding closes the panel: this one doesn't stop it.
  assert.equal(esc.defaultPrevented, false);
  assert.deepEqual(dispatched, []);
  assert.equal(controls.matchShortcut({ key: "Escape" }, ["undo", "brush", "eraser", "size"]), null);
});

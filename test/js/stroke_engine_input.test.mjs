// The stroke engine's pointer input (lib/scrawly_web/pages/stroke_engine.mjs)
// against a fake DOM: which presses start a gesture (the main and the
// secondary button of a mouse or a pen, primary pointers only), that the
// press reaches getTool and its tool holds for the whole gesture (a Ctrl
// gesture stays the eraser after Ctrl is let go), and that a canvas that can
// be drawn on opens no context menu (nor does a right-button gesture's
// release, where Windows opens it) while the rest of the page keeps it.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { installFakeDom, FakeEl } from "./support/fake_dom.mjs";

const { root } = installFakeDom();

// The engine's clock (performance.now), moved by the tests.
let clock = 1000;
Object.defineProperty(globalThis, "performance", { value: { now: () => clock }, configurable: true, writable: true });

const engineModule = await import("../../lib/scrawly_web/pages/stroke_engine.mjs");
const tools = await import("../../lib/scrawly_web/pages/draw_tools.mjs");
const { createStrokeEngine, gestureButton } = engineModule;

const SVG_ID = "test-canvas-svg";

function renderCanvas() {
  root.children = [];
  const svg = new FakeEl("svg", SVG_ID);
  svg.getScreenCTM = () => ({ inverse: () => ({ a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }) });
  svg.setPointerCapture = () => {};
  svg.hasPointerCapture = () => false;
  svg.releasePointerCapture = () => {};
  svg.appendChild(new FakeEl("g", "test-strokes"));
  svg.appendChild(new FakeEl("path", "test-active-path"));
  root.appendChild(svg);
  return svg;
}

// What the engine hands its owner, and the presses getTool saw.
let calls;
let presses;
let svg;
let engine;
let nextId;

function makeEngine() {
  return createStrokeEngine({
    svgId: SVG_ID,
    activePathId: "test-active-path",
    canStart: () => ({ owner: "test" }),
    // As drawing_manager.mjs and demo_board.mjs do.
    getTool: (_ctx, press) => {
      presses.push(press);
      return tools.gestureStroke(tools.currentTool(), press);
    },
    newStrokeId: () => "s-" + ++nextId,
    onStart: (s) => calls.push(["start", s.id, s.color, s.width]),
    onSegments: (s) => calls.push(["segments", s.id, s.color, s.width]),
    onEnd: (s) => calls.push(["end", s.id, s.color, s.width]),
  });
}

beforeEach(() => {
  calls = [];
  presses = [];
  nextId = 0;
  svg = renderCanvas();
  engine = makeEngine();
  engine.enable();
  tools.setDrawTool({ tool: "brush", color: "#d63838", size: 12 });
});

function press(fields = {}) {
  const e = {
    target: svg.children[0],
    pointerId: 1,
    isPrimary: true,
    pointerType: "mouse",
    button: 0,
    buttons: 1,
    ctrlKey: false,
    metaKey: false,
    clientX: 10,
    clientY: 10,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true;
    },
    ...fields,
  };
  globalThis.__fire("pointerdown", e);
  return e;
}

const move = (x, y, fields = {}) =>
  globalThis.__fire("pointermove", { pointerId: 1, buttons: 1, clientX: x, clientY: y, ctrlKey: false, ...fields });
const release = (fields = {}) => globalThis.__fire("pointerup", { pointerId: 1, ...fields });

// A drag from (10, 10) through three points, released.
function drag(down, moves = {}) {
  press(down);
  for (const [x, y] of [[30, 10], [30, 30], [50, 30]]) move(x, y, moves);
  release();
}

const colors = () => [...new Set(calls.map((c) => c[2] + "@" + c[3]))];

// ── Which presses start a gesture ────────────────────────────────────

test("a mouse or a pen starts with its main or its secondary button only", () => {
  for (const pointerType of ["mouse", "pen"]) {
    assert.equal(gestureButton(pointerType, 0), true, pointerType);
    assert.equal(gestureButton(pointerType, 2), true, pointerType);
    for (const button of [1, 3, 4, 5, -1, undefined]) {
      assert.equal(gestureButton(pointerType, button), false, `${pointerType} ${button}`);
    }
  }
  // Touch has no buttons to choose from: as before.
  assert.equal(gestureButton("touch", 0), true);
});

test("a right-button press starts a gesture, for a mouse and a pen", () => {
  for (const pointerType of ["mouse", "pen"]) {
    calls = [];
    const e = press({ pointerType, button: 2, buttons: 2 });
    assert.equal(engine.isDrawing(), true, pointerType);
    // No text selection or native drag, as for the main button.
    assert.equal(e.defaultPrevented, true);
    move(40, 10, { buttons: 2 });
    release();
    assert.equal(engine.isDrawing(), false);
    assert.deepEqual(calls.map((c) => c[0]), ["start", "end"], pointerType);
  }
});

test("the middle, back and forward buttons, a pen's eraser button and secondary pointers start nothing", () => {
  for (const fields of [
    { button: 1, buttons: 4 },
    { button: 3, buttons: 8 },
    { button: 4, buttons: 16 },
    { pointerType: "pen", button: 5, buttons: 32 },
    { isPrimary: false },
    { pointerType: "touch", isPrimary: false },
  ]) {
    const e = press(fields);
    assert.equal(engine.isDrawing(), false, JSON.stringify(fields));
    assert.equal(e.defaultPrevented, false, JSON.stringify(fields));
  }
  assert.deepEqual(calls, []);
  assert.deepEqual(presses, []);

  // A touch still draws, as before.
  press({ pointerType: "touch", button: 0 });
  assert.equal(engine.isDrawing(), true);
  release();
});

test("a right-button drag that stays held keeps drawing (buttons is 2, not 0)", () => {
  press({ button: 2, buttons: 2 });
  move(30, 10, { buttons: 2 });
  move(30, 30, { buttons: 2 });
  assert.equal(engine.isDrawing(), true);
  // Every button up, with no pointerup seen: the release was missed.
  move(50, 30, { buttons: 0 });
  assert.equal(engine.isDrawing(), false);
  assert.equal(calls.at(-1)[0], "end");
});

// ── The press chooses the gesture's tool ─────────────────────────────

test("getTool gets the press itself", () => {
  const e = press({ button: 2, ctrlKey: true, clientX: 12 });
  release();
  assert.deepEqual(presses, [e]);
});

test("a gesture pressed with Ctrl stays the eraser after Ctrl is let go", () => {
  press({ ctrlKey: true });
  // Ctrl comes up mid-gesture: the moves (and the key events, which the
  // engine doesn't follow) say so.
  globalThis.__fire("keyup", { key: "Control", ctrlKey: false });
  for (const [x, y] of [[30, 10], [30, 30], [50, 30]]) move(x, y, { ctrlKey: false });
  release({ ctrlKey: false });

  assert.deepEqual(calls.map((c) => c[0]), ["start", "segments", "segments", "end"]);
  // White at the slider's size, from the press to the commit.
  assert.deepEqual(colors(), [tools.ERASER.color + "@12"]);

  // Released: the next press, without Ctrl, draws with the selected brush.
  calls = [];
  drag({});
  assert.deepEqual(colors(), ["#d63838@12"]);

  // Holding Ctrl down only after the press doesn't make it erase either.
  calls = [];
  drag({}, { ctrlKey: true });
  assert.deepEqual(colors(), ["#d63838@12"]);
});

test("a right-button drag erases to its end; the selected tool stays the brush", () => {
  const heard = [];
  const stop = tools.onToolChange((t) => heard.push(t));
  drag({ button: 2, buttons: 2 }, { buttons: 2 });
  stop();

  assert.deepEqual(colors(), [tools.ERASER.color + "@12"]);
  assert.deepEqual(tools.currentTool(), { tool: "brush", color: "#d63838", size: 12 });
  assert.deepEqual(heard, []);
});

test("Cmd (metaKey) is not Ctrl: a Cmd+drag draws with the brush", () => {
  drag({ metaKey: true });
  assert.deepEqual(colors(), ["#d63838@12"]);
});

test("the selected tool changing mid-gesture (E, the slider) doesn't change the stroke", () => {
  press({ ctrlKey: true });
  move(30, 10);
  tools.setDrawTool({ tool: "brush", size: 30 });
  move(30, 30);
  move(50, 30);
  release();
  assert.deepEqual(colors(), [tools.ERASER.color + "@12"]);
});

test("gestureStyle: the gesture's tool while it is drawn, null otherwise", () => {
  assert.equal(engine.gestureStyle(), null);
  press({ button: 2, buttons: 2 });
  assert.deepEqual(engine.gestureStyle(), { color: tools.ERASER.color, width: 12, tool: "eraser" });
  // A copy.
  engine.gestureStyle().tool = "brush";
  assert.equal(engine.gestureStyle().tool, "eraser");
  release();
  assert.equal(engine.gestureStyle(), null);

  press({});
  assert.deepEqual(engine.gestureStyle(), { color: "#d63838", width: 12, tool: "brush" });
  release();
});

// ── The context menu ─────────────────────────────────────────────────

function contextmenu(target) {
  const e = {
    target,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true;
    },
  };
  globalThis.__fire("contextmenu", e);
  return e.defaultPrevented;
}

test("no context menu on a canvas that can be drawn on; elsewhere the page keeps it", () => {
  const stroke = svg.children[0];
  assert.equal(contextmenu(stroke), true);
  assert.equal(contextmenu(svg), true);

  // Linux and macOS open it at the press: the right button's gesture has
  // just started.
  press({ button: 2, buttons: 2 });
  assert.equal(contextmenu(stroke), true);
  release();
  clock += 1000;

  // Anything outside the canvas.
  const button = new FakeEl("button");
  root.appendChild(button);
  assert.equal(contextmenu(button), false);
  assert.equal(contextmenu(null), false);

  // An svg no engine draws on (an icon).
  const icon = new FakeEl("svg", "some-icon");
  root.appendChild(icon);
  assert.equal(contextmenu(icon), false);

  // A canvas that can't be drawn on (a viewer's, the drawer between turns).
  engine.disable();
  assert.equal(contextmenu(stroke), false);
  engine.enable();
  assert.equal(contextmenu(stroke), true);
});

test("the menu a right-button gesture's release opens (Windows) is suppressed, off the canvas too", () => {
  const outside = new FakeEl("button");
  root.appendChild(outside);

  // Released off the canvas: the menu opens where the pointer is.
  press({ button: 2, buttons: 2 });
  move(30, 10, { buttons: 2 });
  release();
  clock += 5;
  assert.equal(contextmenu(outside), true);
  // Only that one: the next right-click there has its menu.
  assert.equal(contextmenu(outside), false);

  // A main-button gesture's release opens none, so none is expected.
  drag({ ctrlKey: true });
  clock += 5;
  assert.equal(contextmenu(outside), false);

  // Long after the release, the menu is the page's.
  press({ button: 2, buttons: 2 });
  release();
  clock += 1000;
  assert.equal(contextmenu(outside), false);
});

test("a re-rendered canvas (same svg id) is guarded like the old one; one listener for every copy", async () => {
  const copy = await import("../../lib/scrawly_web/pages/stroke_engine.mjs?bundle=home");
  copy.createStrokeEngine({ svgId: "other-svg", newStrokeId: () => "x", onEnd() {} }).enable();
  svg = renderCanvas();
  assert.equal(contextmenu(svg.children[0]), true);

  // One contextmenu listener however many engines and copies registered.
  let prevented = 0;
  globalThis.__fire("contextmenu", { target: svg, preventDefault: () => (prevented += 1) });
  assert.equal(prevented, 1);
});

// ── A press that is no stroke (the colour picker) ────────────────────

test("takePress gets the press and its viewBox point; a taken press starts no gesture", () => {
  const taken = [];
  const takeIt = { value: true };
  engine = createStrokeEngine({
    svgId: SVG_ID,
    activePathId: "test-active-path",
    canStart: () => ({ owner: "test" }),
    takePress: (ctx, e, point) => {
      taken.push({ ctx, button: e.button, altKey: e.altKey === true, point });
      return takeIt.value;
    },
    getTool: (_ctx, p) => {
      presses.push(p);
      return tools.gestureStroke(tools.currentTool(), p);
    },
    newStrokeId: () => "s-" + ++nextId,
    onStart: (s) => calls.push(["start", s.id]),
    onSegments: (s) => calls.push(["segments", s.id]),
    onEnd: (s) => calls.push(["end", s.id]),
  });
  engine.enable();

  // The CTM's inverse maps client to viewBox: here the identity.
  const e = press({ clientX: 120.04, clientY: 33.36, altKey: true });
  assert.deepEqual(taken, [{ ctx: { owner: "test" }, button: 0, altKey: true, point: [120, 33.4] }]);
  // No gesture, no getTool, no stroke id used, no callback; but the press
  // is the canvas's (no text selection or native drag).
  assert.equal(engine.isDrawing(), false);
  assert.equal(e.defaultPrevented, true);
  assert.deepEqual(presses, []);
  assert.equal(nextId, 0);
  move(140, 40);
  release();
  assert.deepEqual(calls, []);

  // Declined: an ordinary gesture.
  takeIt.value = false;
  drag({});
  assert.deepEqual([calls[0][0], calls.at(-1)[0]], ["start", "end"]);
  assert.equal(engine.isDrawing(), false);
  assert.equal(taken.length, 2);
});

test("takePress is not asked for presses the engine ignores (disabled, other buttons, mid-gesture)", () => {
  let asked = 0;
  engine = createStrokeEngine({
    svgId: SVG_ID,
    activePathId: "test-active-path",
    canStart: () => ({ owner: "test" }),
    takePress: () => {
      asked += 1;
      return false;
    },
    getTool: (_ctx, p) => tools.gestureStroke(tools.currentTool(), p),
    newStrokeId: () => "s-" + ++nextId,
    onEnd: () => {},
  });
  press({});
  assert.equal(asked, 0, "disabled: a viewer's canvas");
  engine.enable();
  press({ button: 1, buttons: 4 });
  assert.equal(asked, 0, "the middle button");
  press({});
  assert.equal(asked, 1);
  // A second pointer while drawing.
  press({ pointerId: 2, isPrimary: false });
  assert.equal(asked, 1);
  release();
});

test("every stroke of one gesture carries its gesture id: the first stroke's, through every split", () => {
  const ends = [];
  engine = createStrokeEngine({
    svgId: SVG_ID,
    activePathId: "test-active-path",
    canStart: () => ({ owner: "test" }),
    getTool: (_ctx, p) => tools.gestureStroke(tools.currentTool(), p),
    newStrokeId: () => "s-" + ++nextId,
    onEnd: (s) => ends.push([s.id, s.gesture]),
    splitAt: 200,
  });
  engine.enable();

  press({});
  for (let i = 1; i <= 60; i++) move(10 + i * 3, 10 + (i % 2) * 4);
  release();
  assert.ok(ends.length >= 3, `split into ${ends.length}`);
  assert.deepEqual(ends.map((e) => e[1]), ends.map(() => "s-1"));

  // The next gesture has its own.
  drag({});
  assert.deepEqual(ends.at(-1), ["s-" + nextId, "s-" + nextId]);
});

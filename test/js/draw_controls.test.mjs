// The drawing toolbar's native input (lib/scrawly_web/pages/draw_controls.mjs):
// the size slider writes the tool model at once; every drawing shortcut goes
// through one keydown listener and its typing guard; the size keys step the
// slider like a drag; a shortcut is live only with its toolbar control.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { installFakeDom } from "./support/fake_dom.mjs";

const { dispatched } = installFakeDom();

const controls = await import("../../lib/scrawly_web/pages/draw_controls.mjs");
const tools = await import("../../lib/scrawly_web/pages/draw_tools.mjs");
// Hologram 0.12 puts a copy of the module in every page bundle.
const copy = await import("../../lib/scrawly_web/pages/draw_controls.mjs?bundle=home");

const { isTypingTarget, matchShortcut } = controls;

// ── Fakes: elements, a toolbar, keydowns ──────────────────────────────

const el = (tagName, extra = {}) => ({ tagName, ...extra });

// The slider: its `input` events go through window's listeners, like a real
// one's (and a drag's).
const inputEvents = [];
function makeSlider(value) {
  return {
    tagName: "INPUT",
    type: "range",
    value: String(value),
    hasAttribute: (name) => name === "data-draw-size",
    dispatchEvent(ev) {
      inputEvents.push(ev.type);
      globalThis.__fire(ev.type, { type: ev.type, target: this });
      return true;
    },
  };
}

// DrawingToolbar with `shortcuts` (or none rendered).
let toolbar = null;
let slider = null;
function renderToolbar(names, size = tools.currentTool().size) {
  slider = makeSlider(size);
  toolbar = {
    getAttribute: (name) => (name === "data-draw-shortcuts" ? names : null),
    querySelector: (sel) => (sel === "input[data-draw-size]" && names.includes("size") ? slider : null),
  };
}
document.querySelector = (sel) => (sel === "[data-draw-shortcuts]" ? toolbar : null);

const BODY = el("BODY");

function keydown(key, mods = {}, target = BODY) {
  const e = {
    key,
    target,
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    shiftKey: false,
    repeat: false,
    isComposing: false,
    defaultPrevented: false,
    ...mods,
    preventDefault() {
      this.defaultPrevented = true;
    },
  };
  globalThis.__fire("keydown", e);
  return e;
}

const actions = () => dispatched.map((d) => [d.name, d.target]);

controls.installDrawControls();
// Every copy installs; the listeners exist once.
copy.installDrawControls();

beforeEach(() => {
  dispatched.length = 0;
  inputEvents.length = 0;
  tools.resetDrawTool();
  // The game toolbar's names (DrawingToolbar.shortcut_names/1).
  renderToolbar("undo brush eraser picker size");
});

// ── The typing guard ──────────────────────────────────────────────────

test("a text field, a textarea, a select and a contenteditable are typing targets", () => {
  for (const type of [undefined, "", "text", "email", "password", "search", "number", "url", "tel"]) {
    assert.equal(isTypingTarget(el("INPUT", { type })), true, `input ${type}`);
  }
  assert.equal(isTypingTarget(el("TEXTAREA")), true);
  assert.equal(isTypingTarget(el("SELECT")), true);
  assert.equal(isTypingTarget(el("DIV", { isContentEditable: true })), true);
  assert.equal(isTypingTarget(el("SPAN", { isContentEditable: true })), true);
});

test("the slider, buttons, checkboxes and the page itself are not", () => {
  for (const type of ["range", "checkbox", "radio", "button", "submit", "reset", "color", "file"]) {
    assert.equal(isTypingTarget(el("INPUT", { type })), false, `input ${type}`);
  }
  for (const target of [BODY, el("BUTTON"), el("svg"), el("DIV", { isContentEditable: false })]) {
    assert.equal(isTypingTarget(target), false, target.tagName);
  }
  for (const target of [null, undefined, globalThis, "input"]) {
    assert.equal(isTypingTarget(target), false, String(target));
  }
});

// ── Which key is which shortcut ───────────────────────────────────────

const ALL = ["undo", "brush", "eraser", "picker", "size"];
const ev = (key, mods = {}) => ({ key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, repeat: false, ...mods });

test("E is the eraser, Shift+E too; with Ctrl, Cmd or Alt, or held, it is nothing", () => {
  const eraser = { control: "eraser", action: "toggle_eraser" };
  assert.deepEqual(matchShortcut(ev("e"), ALL), eraser);
  assert.deepEqual(matchShortcut(ev("E", { shiftKey: true }), ALL), eraser);

  for (const mod of ["ctrlKey", "metaKey", "altKey", "repeat"]) {
    assert.equal(matchShortcut(ev("e", { [mod]: true }), ALL), null, mod);
  }
});

test("B is the brush, Shift+B too; with Ctrl, Cmd or Alt, or held, it is nothing", () => {
  const brush = { control: "brush", action: "select_brush" };
  assert.deepEqual(matchShortcut(ev("b"), ALL), brush);
  assert.deepEqual(matchShortcut(ev("B", { shiftKey: true }), ALL), brush);

  for (const mod of ["ctrlKey", "metaKey", "altKey", "repeat"]) {
    assert.equal(matchShortcut(ev("b", { [mod]: true }), ALL), null, mod);
  }
  // Live only with its control (the toolbar names it with the eraser).
  assert.equal(matchShortcut(ev("b"), ["undo", "eraser", "size"]), null);
});

test("I is the colour picker, Shift+I too; with Ctrl, Cmd or Alt, or held, it is nothing", () => {
  const picker = { control: "picker", action: "toggle_picker" };
  assert.deepEqual(matchShortcut(ev("i"), ALL), picker);
  assert.deepEqual(matchShortcut(ev("I", { shiftKey: true }), ALL), picker);

  // Ctrl+I, Cmd+I (the browser's), Alt+I, a held key.
  for (const mod of ["ctrlKey", "metaKey", "altKey", "repeat"]) {
    assert.equal(matchShortcut(ev("i", { [mod]: true }), ALL), null, mod);
  }
  // Live only with its control (the board and the game both name it).
  assert.equal(matchShortcut(ev("i"), ["undo", "brush", "eraser", "size"]), null);

  // Pressed: the page's toggle_picker, the key kept from the browser.
  const e = keydown("i");
  assert.equal(e.defaultPrevented, true);
  assert.deepEqual(actions(), [["toggle_picker", "page"]]);
});

test("Ctrl+Z and Cmd+Z undo (both at once: once); with Shift or held, nothing", () => {
  const undo = { control: "undo", action: "undo_drawing" };
  assert.deepEqual(matchShortcut(ev("z", { ctrlKey: true }), ALL), undo);
  assert.deepEqual(matchShortcut(ev("z", { metaKey: true }), ALL), undo);
  assert.deepEqual(matchShortcut(ev("z", { ctrlKey: true, metaKey: true }), ALL), undo);

  assert.equal(matchShortcut(ev("z"), ALL), null);
  assert.equal(matchShortcut(ev("Z", { ctrlKey: true, shiftKey: true }), ALL), null);
  assert.equal(matchShortcut(ev("z", { metaKey: true, repeat: true }), ALL), null);
});

test("[ and ] step the size by 1, by 5 with Shift, and repeat while held", () => {
  const size = (step) => ({ control: "size", step });
  assert.deepEqual(matchShortcut(ev("["), ALL), size(-1));
  assert.deepEqual(matchShortcut(ev("]"), ALL), size(1));
  assert.deepEqual(matchShortcut(ev("{", { shiftKey: true }), ALL), size(-5));
  assert.deepEqual(matchShortcut(ev("}", { shiftKey: true }), ALL), size(5));
  assert.deepEqual(matchShortcut(ev("]", { repeat: true }), ALL), size(1));
  // AltGr (Ctrl+Alt) or a Mac's Alt, where that is how "[" is typed.
  assert.deepEqual(matchShortcut(ev("[", { ctrlKey: true, altKey: true }), ALL), size(-1));
  assert.deepEqual(matchShortcut(ev("]", { altKey: true }), ALL), size(1));

  // Cmd+[ is the browser's Back; Ctrl+[ is not ours either.
  assert.equal(matchShortcut(ev("[", { metaKey: true }), ALL), null);
  assert.equal(matchShortcut(ev("]", { ctrlKey: true }), ALL), null);
});

test("a shortcut is live only with its control; composing text is never one", () => {
  assert.equal(matchShortcut(ev("e"), ["undo", "size"]), null);
  assert.equal(matchShortcut(ev("z", { ctrlKey: true }), ["eraser", "size"]), null);
  assert.equal(matchShortcut(ev("]"), ["undo", "eraser"]), null);
  assert.equal(matchShortcut(ev("e"), []), null);
  assert.equal(matchShortcut(ev("e"), undefined), null);
  assert.equal(matchShortcut(ev("e", { isComposing: true }), ALL), null);
  assert.equal(matchShortcut({ type: "keydown" }, ALL), null);
  assert.equal(matchShortcut(ev("x"), ALL), null);
});

// ── The listener ──────────────────────────────────────────────────────

test("a shortcut dispatches the page's toolbar action and keeps the key from the browser", () => {
  const e = keydown("e");
  const b = keydown("b");
  const z = keydown("z", { ctrlKey: true });
  assert.deepEqual(actions(), [
    ["toggle_eraser", "page"],
    ["select_brush", "page"],
    ["undo_drawing", "page"],
  ]);
  assert.equal(e.defaultPrevented, true);
  assert.equal(b.defaultPrevented, true);
  assert.equal(z.defaultPrevented, true);
});

test("Ctrl, held for a Ctrl+drag, is no shortcut", () => {
  const ctrl = keydown("Control", { ctrlKey: true });
  const held = keydown("Control", { ctrlKey: true, repeat: true });
  assert.equal(ctrl.defaultPrevented, false);
  assert.equal(held.defaultPrevented, false);
  assert.deepEqual(actions(), []);
});

test("while focus is in a field, no shortcut fires and the key keeps its meaning", () => {
  const fields = [
    el("INPUT", { type: "email" }),
    el("INPUT", { type: "password" }),
    el("INPUT", { type: "text" }),
    el("TEXTAREA"),
    el("SELECT"),
    el("DIV", { isContentEditable: true }),
  ];
  for (const field of fields) {
    const events = [
      keydown("e", {}, field),
      keydown("b", {}, field),
      keydown("i", {}, field),
      keydown("B", { shiftKey: true }, field),
      keydown("z", { ctrlKey: true }, field),
      keydown("z", { metaKey: true }, field),
      keydown("[", {}, field),
      keydown("}", { shiftKey: true }, field),
    ];
    assert.deepEqual(
      events.map((e) => e.defaultPrevented),
      [false, false, false, false, false, false, false, false],
      field.tagName
    );
  }
  assert.deepEqual(actions(), []);
  assert.deepEqual(inputEvents, []);
  assert.equal(tools.currentTool().size, tools.DEFAULT_TOOL.size);
});

test("with the slider focused (after a drag) the shortcuts still work", () => {
  keydown("e", {}, slider);
  keydown("]", {}, slider);
  assert.deepEqual(actions(), [["toggle_eraser", "page"]]);
  assert.equal(slider.value, String(tools.DEFAULT_TOOL.size + 1));
});

test("the size keys step the slider like a drag: its value, an input event, the model", () => {
  renderToolbar("eraser size", 10);
  tools.setDrawTool({ tool: "eraser", size: 10 });

  const e = keydown("]");
  assert.equal(e.defaultPrevented, true);
  assert.equal(slider.value, "11");
  assert.deepEqual(inputEvents, ["input"]);
  // The model has it at once (the eraser stays the eraser).
  assert.deepEqual(tools.currentTool(), { ...tools.DEFAULT_TOOL, tool: "eraser", size: 11 });

  keydown("{", { shiftKey: true });
  assert.equal(tools.currentTool().size, 6);
  keydown("[", { repeat: true });
  assert.equal(tools.currentTool().size, 5);

  // No Hologram action of their own: the slider's binding brings the state.
  assert.deepEqual(actions(), []);
});

test("the size stays within 1..40; at an end a size key changes nothing", () => {
  renderToolbar("size", 38);
  tools.setDrawTool({ size: 38 });

  keydown("}", { shiftKey: true });
  assert.equal(tools.currentTool().size, 40);
  inputEvents.length = 0;
  keydown("]");
  assert.deepEqual(inputEvents, []);
  assert.equal(slider.value, "40");

  renderToolbar("size", 3);
  tools.setDrawTool({ size: 3 });
  keydown("{", { shiftKey: true });
  assert.equal(tools.currentTool().size, 1);
  inputEvents.length = 0;
  keydown("[");
  assert.deepEqual(inputEvents, []);
});

test("a key steps from the model's size, not from a slider a render set back", () => {
  renderToolbar("size", 15);
  tools.setDrawTool({ size: 5 });
  // GamePage's countdown re-rendered while the slider's state still said 15
  // (its throttled :select_size not in yet): the controlled slider shows 15.
  slider.value = "15";

  keydown("{", { shiftKey: true });
  assert.equal(tools.currentTool().size, 1);
  assert.equal(slider.value, "1");
});

test("no toolbar with shortcuts, or not this one's: nothing happens", () => {
  toolbar = null;
  const e = keydown("e");
  keydown("z", { ctrlKey: true });
  keydown("]");
  assert.equal(e.defaultPrevented, false);

  // A toolbar without the undo control.
  renderToolbar("brush eraser size");
  const z = keydown("z", { ctrlKey: true });
  assert.equal(z.defaultPrevented, false);

  // Shortcuts without the size control.
  renderToolbar("undo eraser");
  keydown("]");

  assert.deepEqual(actions(), []);
  assert.deepEqual(inputEvents, []);
});

test("a key some element already handled is left alone", () => {
  const e = { key: "e", target: BODY, defaultPrevented: true, preventDefault() {} };
  globalThis.__fire("keydown", e);
  assert.deepEqual(actions(), []);
});

test("dragging the slider writes the model on every input; other inputs don't", () => {
  renderToolbar("size", 4);
  for (const v of [5, 9, 23, 40, 1]) {
    slider.value = String(v);
    globalThis.__fire("input", { type: "input", target: slider });
    assert.equal(tools.currentTool().size, v);
  }

  slider.value = "abc";
  globalThis.__fire("input", { type: "input", target: slider });
  assert.equal(tools.currentTool().size, 1);

  const chat = { tagName: "INPUT", type: "text", value: "17", hasAttribute: () => false };
  globalThis.__fire("input", { type: "input", target: chat });
  globalThis.__fire("input", { type: "input", target: null });
  assert.equal(tools.currentTool().size, 1);
});

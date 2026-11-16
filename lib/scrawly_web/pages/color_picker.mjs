// The drawing toolbar's colour panel, native side (DrawingToolbar renders the
// markup, for the game's drawer and the home board alike):
//
// * The wheel (`[data-color-wheel]`): hue and saturation at full brightness,
//   painted once per tab and device pixel ratio onto an offscreen canvas
//   (paintWheel) and copied into the panel's `<canvas>` when the panel is
//   prepared; repainted only when the device pixel ratio changes (zoom, a
//   move to another screen). Brightness never repaints it: a black layer over
//   it at opacity 1 - v (`[data-color-shade]`), which is HSV's own v x rgb.
// * Dragging on the wheel, its arrow keys, the brightness slider, the hex
//   field and the "before" swatch write the tool model at once
//   (draw_tools.mjs setDrawTool: the brush in that colour, or the fill
//   while the fill is selected, colorTool), so a stroke right after uses it. The page's state (the chip, the size dot) follows with
//   its `color_picked` action, throttled: at most one per THROTTLE_MS while
//   the value moves, the last one always sent (createThrottle). No Hologram
//   action per pointer move, and none that pushes the tool back over a newer
//   one (`color_picked` doesn't push). A pick on a wheel too dark to choose
//   from (black, the default colour) starts at full brightness (wheelValue).
// * The panel is prepared (painted, filled from the tool) by a capture-phase
//   click on its chip, before the chip's own action opens it, so it shows
//   ready. While it exists it follows the tool (onToolChange: a preset or a
//   saved colour picked with the panel open), except during its own drags.
// * The swatch grid (`[data-swatch-grid]`: the presets, then the saved
//   colours) is one Tab stop (DrawingToolbar's tabindex); the arrow keys
//   move between swatches, Delete on a saved one removes it.
// * Escape inside the panel puts focus back on the chip before the page's
//   `<window $key_down.escape>` binding closes the panel.
// * The saved colours ("my colours"): localStorage under SAVED_KEY, shared by
//   every page of the origin (the game and the home board). The pages load
//   them after mount (JS.call savedColors) and render them; "+ save" and the
//   removals (a saved swatch's x, `[data-color-forget]`, or Delete) store the
//   new list here and send it to the page (`saved_colors`). Nothing about
//   them is ever rendered by the server.
//
// The panel's controls (wheel, the new and the old colour, hex field,
// "+ save", brightness) are built here, into DrawingToolbar's empty
// `[data-color-pick]`, when the panel is first prepared (PICK_HTML): they
// carry no page state, and as template markup they would cost each page
// bundle several KB of compiled code. Hologram leaves a JS-filled element
// alone while its template gives it no children, and so never renders an
// older colour into them.
//
// Hologram 0.12 copies this module into every page bundle that can reach the
// importing page, so its state and listeners live in one window slot,
// installed once per tab (installColorPicker, from draw_controls.mjs). The
// colour math is colors.mjs; createThrottle and paintWheel here are pure too
// (test/js/color_picker.test.mjs).

import { colorTool, currentTool, onToolChange, setDrawTool } from "./draw_tools.mjs";
import {
  SAVED_KEY,
  addSavedColor,
  hsvFromHex,
  hsvToHex,
  hsvToRgb,
  parseHex,
  removeSavedColor,
  savedColorsFrom,
  wheelHsv,
  wheelPoint,
} from "./colors.mjs";

const SLOT = "__scrawlyColorPicker";
export const THROTTLE_MS = 100;
// The wheel's CSS size (app.css .color-wheel), for when it isn't laid out.
export const WHEEL_SIZE = 152;
// Arrow keys on the wheel: hue in degrees, saturation in [0, 1]; Shift x.
export const HUE_STEP = 5;
export const SAT_STEP = 0.05;
export const SHIFT_TIMES = 6;
// Below this brightness the wheel is all but black (the default colour is
// black): picking on it starts at full brightness instead (wheelValue).
export const DARK_V = 0.2;

const CONTROL = "[data-color-control]";
const CHIP = "[data-color-open]";
const WHEEL = "[data-color-wheel]";
const GRID = "[data-swatch-grid]";

// The panel's controls (app.css styles them).
export const PICK_HTML =
  '<div class="color-pick-row">' +
  '<div class="color-wheel" data-color-wheel tabindex="0" role="slider"' +
  ' aria-label="colour wheel: hue and saturation" aria-valuemin="0" aria-valuemax="359">' +
  '<canvas class="color-wheel-canvas" aria-hidden="true"></canvas>' +
  '<span class="color-wheel-shade" data-color-shade></span>' +
  '<span class="color-wheel-marker" data-color-marker></span></div>' +
  '<div class="color-side"><div class="color-compare">' +
  '<span class="color-now" data-color-now title="new colour"></span>' +
  '<button type="button" class="color-was" data-color-was title="back to the colour before"></button></div>' +
  '<input type="text" class="app-input mono color-hex" data-color-hex maxlength="7" spellcheck="false"' +
  ' autocomplete="off" autocapitalize="off" aria-label="hex colour" placeholder="#rrggbb">' +
  '<button type="button" class="tool-btn color-save" data-color-save>+ save</button></div></div>' +
  '<input type="range" class="color-value" data-color-value min="0" max="100" step="1" aria-label="brightness">';

// ── Pure parts ───────────────────────────────────────────────────────

// Calls `send(value)` at most once per `ms` while values keep coming: the
// first at once, then the latest of each window when it ends. flush() sends
// a pending value now (a drag's end). `clock` is {now, set, clear}.
export function createThrottle(send, ms, clock) {
  let pending;
  let has = false;
  let timer = null;
  let last = -Infinity;

  function fire() {
    timer = null;
    if (!has) return;
    const value = pending;
    has = false;
    pending = undefined;
    last = clock.now();
    send(value);
  }

  return {
    push(value) {
      pending = value;
      has = true;
      if (timer !== null) return;
      const wait = last + ms - clock.now();
      if (wait <= 0) fire();
      else timer = clock.set(fire, wait);
    },
    flush() {
      if (timer !== null) clock.clear(timer);
      fire();
    },
  };
}

// Fills `data` (RGBA, px x px) with the wheel at full brightness: hue by
// angle, saturation by distance (colors.mjs wheelHsv), its rim anti-aliased,
// transparent outside.
export function paintWheel(data, px) {
  const r = px / 2;
  for (let y = 0; y < px; y++) {
    for (let x = 0; x < px; x++) {
      const dx = x + 0.5 - r;
      const dy = y + 0.5 - r;
      const edge = r - Math.hypot(dx, dy);
      if (edge <= 0) continue;
      const hs = wheelHsv(dx, dy, r);
      const c = hsvToRgb({ h: hs.h, s: hs.s, v: 1 });
      const i = (y * px + x) * 4;
      data[i] = c.r;
      data[i + 1] = c.g;
      data[i + 2] = c.b;
      data[i + 3] = Math.min(1, edge) * 255;
    }
  }
}

// The brightness a pick on the wheel keeps: the current one, or full when
// the wheel is too dark to choose from (a hue picked on a black wheel is
// meant to be seen).
export function wheelValue(v) {
  return v < DARK_V ? 1 : v;
}

// The HSV an arrow key moves `hsv` to on the wheel, or null for other keys:
// left / right turn the hue, up / down change the saturation.
// left / right turn the hue, up / down change the saturation (at
// wheelValue's brightness).
export function wheelKey(hsv, key, shift) {
  const k = shift ? SHIFT_TIMES : 1;
  const v = wheelValue(hsv.v);
  const sat = (d) => Math.min(1, Math.max(0, Math.round((hsv.s + d * SAT_STEP * k) * 100) / 100));
  switch (key) {
    case "ArrowRight":
      return { ...hsv, h: (hsv.h + HUE_STEP * k) % 360, v };
    case "ArrowLeft":
      return { ...hsv, h: (hsv.h - HUE_STEP * k + 360) % 360, v };
    case "ArrowUp":
      return { ...hsv, s: sat(1), v };
    case "ArrowDown":
      return { ...hsv, s: sat(-1), v };
    default:
      return null;
  }
}

// The index an arrow key (or Home / End) moves focus to among `count`
// swatches laid out `columns` to a row (the first row's count), from
// `index`; null for other keys. Moves off the grid stay put, except down
// into a shorter last row (the saved colours), which lands on its end.
export function gridMove(index, count, columns, key) {
  const cols = Math.max(1, columns);
  const to = {
    ArrowRight: index + 1,
    ArrowLeft: index - 1,
    ArrowDown: index + cols,
    ArrowUp: index - cols,
    Home: 0,
    End: count - 1,
  }[key];
  if (to === undefined) return null;
  if (to >= 0 && to < count) return to;
  // Down into a shorter last row: its last swatch.
  const last = count - 1;
  return key === "ArrowDown" && Math.floor(last / cols) > Math.floor(index / cols) ? last : index;
}

// ── Saved colours (the pages' actions call these) ─────────────────────

function storage() {
  try {
    return window.localStorage || null;
  } catch (_e) {
    return null;
  }
}

function writeSaved(list) {
  try {
    storage().setItem(SAVED_KEY, JSON.stringify(list));
  } catch (_e) {
    // Storage full or off: the list still shows until the page is left.
  }
  return list;
}

// The saved colours, newest first ([] when none, or when the stored value
// is missing or corrupt).
export function savedColors() {
  try {
    const s = storage();
    return savedColorsFrom(s ? s.getItem(SAVED_KEY) : null);
  } catch (_e) {
    return [];
  }
}

// Saves the tool's colour (the model's: the page's state may still lag a
// drag by a throttle window) and returns the list.
export function saveColor() {
  return writeSaved(addSavedColor(savedColors(), currentTool().color));
}

// Removes `color` and returns the list.
export function forgetColor(color) {
  return writeSaved(removeSavedColor(savedColors(), color));
}

function sendSaved(list) {
  if (globalThis.Hologram) globalThis.Hologram.dispatchAction("saved_colors", "page", { colors: list });
}

// ── The panel ────────────────────────────────────────────────────────

function picker() {
  return window[SLOT];
}

function within(target, selector) {
  return target && typeof target.closest === "function" ? target.closest(selector) : null;
}

function part(control, attr) {
  return control.querySelector("[" + attr + "]");
}

function dpr() {
  return window.devicePixelRatio || 1;
}

function wheelImage(px) {
  const st = picker();
  if (st.image && st.image.width === px) return st.image;
  const c = document.createElement("canvas");
  c.width = px;
  c.height = px;
  const ctx = c.getContext("2d");
  const img = ctx.createImageData(px, px);
  paintWheel(img.data, px);
  ctx.putImageData(img, 0, 0);
  st.image = c;
  return c;
}

// The wheel into `control`'s canvas, at the device pixel ratio, unless it is
// there already.
function paint(control) {
  const canvas = control.querySelector(WHEEL + " canvas");
  if (!canvas || typeof canvas.getContext !== "function") return;
  const px = Math.round((canvas.clientWidth || WHEEL_SIZE) * dpr());
  if (canvas.__scrawlyWheelPx === px) return;
  canvas.width = px;
  canvas.height = px;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  ctx.drawImage(wheelImage(px), 0, 0);
  canvas.__scrawlyWheelPx = px;
}

function radius(control) {
  const wheel = control.querySelector(WHEEL);
  return (wheel && wheel.clientWidth ? wheel.clientWidth : WHEEL_SIZE) / 2;
}

// Shows `hsv` (`hex`) in `control`'s panel. `from` is the control the value
// came from, which keeps its own text while it is being used.
function show(control, hsv, hex, from, r) {
  const wheel = control.querySelector(WHEEL);
  const marker = part(control, "data-color-marker");
  const shade = part(control, "data-color-shade");
  const value = part(control, "data-color-value");
  const field = part(control, "data-color-hex");
  const now = part(control, "data-color-now");
  const rr = r || radius(control);
  if (marker) {
    const p = wheelPoint(hsv.h, hsv.s, rr);
    marker.style.transform = "translate(" + (rr + p.x).toFixed(1) + "px, " + (rr + p.y).toFixed(1) + "px)";
    marker.style.background = hex;
  }
  if (shade) shade.style.opacity = String(1 - hsv.v);
  if (value) {
    if (from !== "value") value.value = String(Math.round(hsv.v * 100));
    value.style.setProperty("--color-value-top", hsvToHex({ h: hsv.h, s: hsv.s, v: 1 }));
  }
  if (field && from !== "hex") {
    field.value = hex;
    field.removeAttribute("aria-invalid");
  }
  if (now) now.style.background = hex;
  if (wheel) {
    wheel.setAttribute("aria-valuenow", String(Math.round(hsv.h) % 360));
    wheel.setAttribute(
      "aria-valuetext",
      "hue " + (Math.round(hsv.h) % 360) + "°, saturation " + Math.round(hsv.s * 100) + "%",
    );
  }
}

// Fills `control`'s panel from the tool (building its controls the first
// time), remembers the colour it opened with (the "before" swatch) and
// paints its wheel.
function prepare(control) {
  const st = picker();
  const hex = currentTool().color;
  const pick = control.querySelector("[data-color-pick]");
  if (pick && !pick.firstChild) pick.innerHTML = PICK_HTML;
  st.control = control;
  st.was = hex;
  st.hsv = hsvFromHex(hex, st.hsv) || st.hsv;
  paint(control);
  const was = part(control, "data-color-was");
  if (was) {
    was.style.background = hex;
    was.setAttribute("aria-label", "back to " + hex);
  }
  show(control, st.hsv, hex, null);
}

// A colour picked in the panel: into the model now, into the page's state
// throttled (or now, with `flush`).
function pick(control, hsv, from, flush, r) {
  const st = picker();
  const hex = hsvToHex(hsv);
  st.hsv = hsv;
  st.writing = true;
  try {
    setDrawTool({ tool: colorTool(currentTool().tool), color: hex });
  } finally {
    st.writing = false;
  }
  show(control, hsv, hex, from, r);
  st.send.push(hex);
  if (flush) st.send.flush();
}

function controlOf(target) {
  const control = within(target, CONTROL);
  if (control && picker().control !== control) prepare(control);
  return control;
}

function pickAt(e) {
  const d = picker().drag;
  const hs = wheelHsv(e.clientX - d.cx, e.clientY - d.cy, d.r);
  pick(d.control, { h: hs.h, s: hs.s, v: d.v }, "wheel", false, d.r);
}

function onPointerDown(e) {
  const wheel = within(e.target, WHEEL);
  if (!wheel || (e.pointerType === "mouse" && e.button !== 0)) return;
  const control = controlOf(wheel);
  if (!control) return;
  const rect = wheel.getBoundingClientRect();
  const r = rect.width / 2 || WHEEL_SIZE / 2;
  const v = wheelValue(picker().hsv.v);
  picker().drag = { id: e.pointerId, control, cx: rect.left + r, cy: rect.top + r, r, v };
  try {
    wheel.setPointerCapture(e.pointerId);
  } catch (_e) {
    // A synthetic event has no active pointer to capture.
  }
  pickAt(e);
}

function onPointerMove(e) {
  const d = picker().drag;
  if (d && e.pointerId === d.id) pickAt(e);
}

function onPointerUp(e) {
  const st = picker();
  if (!st.drag || e.pointerId !== st.drag.id) return;
  st.drag = null;
  st.send.flush();
}

function onInput(e) {
  const el = e.target;
  if (!el || typeof el.hasAttribute !== "function") return;
  if (el.hasAttribute("data-color-value")) {
    const control = controlOf(el);
    const v = Math.min(100, Math.max(0, Number(el.value) || 0)) / 100;
    if (control) pick(control, { ...picker().hsv, v }, "value", false);
  } else if (el.hasAttribute("data-color-hex")) {
    const hex = parseHex(String(el.value).trim());
    const control = controlOf(el);
    if (!hex || !control) return;
    el.removeAttribute("aria-invalid");
    pick(control, hsvFromHex(hex, picker().hsv), "hex", true);
  }
}

// The brightness slider's drag ended; a hex field left with a non-colour
// shows the tool's colour again.
function onChange(e) {
  const el = e.target;
  if (!el || typeof el.hasAttribute !== "function") return;
  if (el.hasAttribute("data-color-value")) picker().send.flush();
  else if (el.hasAttribute("data-color-hex") && !parseHex(String(el.value).trim())) {
    el.value = currentTool().color;
    el.removeAttribute("aria-invalid");
  }
}

function swatches(grid) {
  return Array.from(grid.querySelectorAll(".swatch")).filter((b) => b.offsetParent !== null);
}

function moveInGrid(e, grid) {
  const items = swatches(grid);
  const index = items.indexOf(e.target);
  if (index < 0) return false;
  const top = items[0].offsetTop;
  let columns = 0;
  while (columns < items.length && items[columns].offsetTop === top) columns++;
  const to = gridMove(index, items.length, columns, e.key);
  if (to === null) return false;
  items[to].focus();
  return true;
}

// Delete / Backspace on a saved swatch: removes it, and focus goes to the
// swatch before it once the page has rendered the list without it.
function forgetFocused(e, grid) {
  const color = e.target.getAttribute("data-saved-color");
  if (!color) return false;
  const items = swatches(grid);
  const index = items.indexOf(e.target);
  sendSaved(forgetColor(color));
  requestAnimationFrame(() => {
    const left = swatches(grid);
    const next = left[Math.max(0, Math.min(index, left.length) - 1)];
    if (next) next.focus();
  });
  return true;
}

// Capture phase on window: before the toolbar's other keys
// (draw_controls.mjs, bubble phase, which skips what is handled here) and
// before the page's Escape binding.
function onKeyDown(e) {
  const t = e.target;
  if (e.key === "Escape") {
    const control = within(t, CONTROL);
    if (control && within(t, ".color-sheet")) {
      const chip = control.querySelector(CHIP);
      if (chip) chip.focus();
    }
    return;
  }
  if (e.ctrlKey || e.metaKey || e.altKey) return;

  if (t && typeof t.hasAttribute === "function" && t.hasAttribute("data-color-hex") && e.key === "Enter") {
    const hex = parseHex(String(t.value).trim());
    if (hex) t.value = hex;
    else t.setAttribute("aria-invalid", "true");
    e.preventDefault();
    return;
  }

  const wheel = within(t, WHEEL);
  if (wheel && wheel === t) {
    const control = controlOf(wheel);
    const next = control && wheelKey(picker().hsv, e.key, e.shiftKey);
    if (!next) return;
    e.preventDefault();
    pick(control, next, "wheel", false);
    return;
  }

  const grid = within(t, GRID);
  if (!grid) return;
  const handled =
    e.key === "Delete" || e.key === "Backspace" ? forgetFocused(e, grid) : moveInGrid(e, grid);
  if (handled) e.preventDefault();
}

function onKeyUp(e) {
  if (within(e.target, WHEEL)) picker().send.flush();
}

function onClick(e) {
  const chip = within(e.target, CHIP);
  if (chip) {
    const control = within(chip, CONTROL);
    if (control) prepare(control);
    return;
  }
  const was = within(e.target, "[data-color-was]");
  if (was) {
    const control = controlOf(was);
    const st = picker();
    const hsv = control && hsvFromHex(st.was, st.hsv);
    if (hsv) pick(control, hsv, null, true);
    return;
  }
  if (within(e.target, "[data-color-save]")) {
    picker().send.flush();
    sendSaved(saveColor());
    return;
  }
  const forget = within(e.target, "[data-color-forget]");
  if (forget) sendSaved(forgetColor(forget.getAttribute("data-color-forget")));
}

// The tool changed elsewhere (a preset, a saved colour, the page's push):
// the open panel follows, unless it is the panel's own change.
function onTool(tool) {
  const st = picker();
  if (st.writing || st.drag || !st.control || !st.control.isConnected) return;
  if (tool.color === hsvToHex(st.hsv)) return;
  st.hsv = hsvFromHex(tool.color, st.hsv) || st.hsv;
  show(st.control, st.hsv, tool.color, null);
}

// A new device pixel ratio: repaint the panel's wheel (and listen for the
// next change).
function watchRatio() {
  const st = picker();
  if (typeof window.matchMedia !== "function") return;
  const mq = window.matchMedia("(resolution: " + dpr() + "dppx)");
  const changed = () => {
    if (typeof mq.removeEventListener === "function") mq.removeEventListener("change", changed);
    if (st.control && st.control.isConnected) paint(st.control);
    watchRatio();
  };
  if (typeof mq.addEventListener === "function") mq.addEventListener("change", changed);
}

// With the model's tool by then (the brush, or the fill a colour choice
// keeps, or the tool a pick went back to): the page's state follows both.
function dispatchPicked(color) {
  if (globalThis.Hologram) {
    globalThis.Hologram.dispatchAction("color_picked", "page", { color: color, tool: currentTool().tool });
  }
}

// A colour set natively elsewhere (the colour picker tool, eyedropper.mjs,
// has already put it in the model): the page's state follows now, through
// the panel's throttle, so a trailing panel value can't arrive after it.
export function reportColor(color) {
  const st = window[SLOT];
  if (!st) {
    dispatchPicked(color);
    return;
  }
  st.send.push(color);
  st.send.flush();
}

const CLOCK = {
  now: () => (typeof performance !== "undefined" ? performance.now() : Date.now()),
  set: (fn, ms) => setTimeout(fn, ms),
  clear: (id) => clearTimeout(id),
};

// Once per tab (`clock`, the throttle's, is for tests).
export function installColorPicker(clock = CLOCK) {
  if (window[SLOT]) return;
  window[SLOT] = {
    hsv: hsvFromHex(currentTool().color, null),
    was: currentTool().color,
    control: null,
    drag: null,
    writing: false,
    image: null,
    send: createThrottle(dispatchPicked, THROTTLE_MS, clock),
  };
  window.addEventListener("pointerdown", onPointerDown, true);
  window.addEventListener("pointermove", onPointerMove, { passive: true });
  window.addEventListener("pointerup", onPointerUp, true);
  window.addEventListener("pointercancel", onPointerUp, true);
  window.addEventListener("input", onInput, true);
  window.addEventListener("change", onChange, true);
  window.addEventListener("keydown", onKeyDown, true);
  window.addEventListener("keyup", onKeyUp, true);
  window.addEventListener("click", onClick, true);
  onToolChange(onTool);
  watchRatio();
}

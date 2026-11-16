// The colour picker on both canvases (eyedropper.mjs through
// drawing_manager.mjs and demo_board.mjs) against a fake DOM and a fake 2D
// context (support/fake_paint.mjs): a press with the picker, or Alt with
// the brush, picks the colour under it from the stroke list and draws
// nothing; the tool after a pick; Ctrl and the right button still erase;
// nothing reaches the server or a viewer; and each canvas's paint model
// keeps its shapes in step with its list (bounded: forgotten with an undo,
// a rollback or a trim, kept to the list on a rebase or a snapshot, dropped
// on a clear, a new page, the board's end and when the page is left).
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, mock, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { installFakeDom, renderGamePage, renderOtherPage, tap, drawnIds, FakeEl } from "./support/fake_dom.mjs";
import { installFakePaint, FakePath2D } from "./support/fake_paint.mjs";

const { root, dispatched } = installFakeDom();
installFakePaint();
mock.timers.enable({ apis: ["setTimeout", "setInterval"] });

// What demo_board.mjs uses of Phoenix.Socket: its pushes (with their
// replies, which the tests answer) and the channel's handlers.
const pushes = [];
const handlers = {};
globalThis.Phoenix = {
  Socket: class {
    connect() {}
    disconnect() {}
    channel() {
      const joined = { receive: () => joined };
      return {
        on(event, fn) {
          handlers[event] = fn;
        },
        join: () => joined,
        leave() {},
        push(event, payload) {
          const reply = {
            hooks: {},
            receive(status, fn) {
              this.hooks[status] = fn;
              return this;
            },
          };
          pushes.push({ event, payload, reply });
          return reply;
        },
      };
    }
  },
};

const dm = await import("../../lib/scrawly_web/pages/drawing_manager.mjs");
const board = await import("../../lib/scrawly_web/pages/demo_board.mjs");
const tools = await import("../../lib/scrawly_web/pages/draw_tools.mjs");
const { paintModel, WATCH_MS } = await import("../../lib/scrawly_web/pages/paint_model.mjs");

// The drawer's committed strokes (the op queue sends one op at a time).
const history = () => window.__scrawlyGameCanvas.history;
const queued = () => window.__scrawlyGameCanvas.queue.map((entry) => entry.op);
const picked = () => dispatched.filter((d) => d.name === "color_picked").map((d) => d.params.color);
const game = () => paintModel("game");
const boardModel = () => paintModel("board");

// Straight strokes, so the fake context's geometry is exact.
const RED = { id: "room-red", path: "M 100 100 L 300 100", color: "#d63838", width: 20 };
const BLUE = { id: "room-blue", path: "M 200 50 L 200 150", color: "#2a6df4", width: 10 };
const ERASED = { id: "room-erased", path: "M 280 100 L 320 100", color: "#ffffff", width: 30 };
const STROKES = [RED, BLUE, ERASED];

function mountDrawer(mount, strokes = STROKES) {
  const svg = renderGamePage(root, { mount });
  dm.mountCanvas(mount);
  tools.setDrawTool({ tool: "brush", color: "#0a0a0a", size: 4 });
  dm.restoreStrokes(strokes);
  dm.setDrawingEnabled(true);
  return svg;
}

let mount = 0;
let svg;

beforeEach(() => {
  dispatched.length = 0;
  mount += 1;
  svg = mountDrawer(mount);
});

// ── Picking on the game canvas (the drawer's history) ───────────────

test("with the picker a press picks the colour under it and draws nothing; the brush comes back in it", () => {
  tools.setDrawTool({ tool: "picker" });
  tap(svg, 150, 100);

  assert.deepEqual(drawnIds(), STROKES.map((s) => s.id));
  assert.deepEqual(queued(), []);
  assert.deepEqual(picked(), ["#d63838"]);
  assert.deepEqual(tools.currentTool(), { tool: "brush", color: "#d63838", size: 4 });

  // The next press draws with the brush in the picked colour.
  tap(svg, 500, 400);
  assert.equal(drawnIds().length, 4);
  assert.deepEqual([queued().at(-1).kind, queued().at(-1).color, queued().at(-1).width], ["commit", "#d63838", 4]);
});

test("the stroke's exact colour at its centre and at its edge; past the edge, what is under it", () => {
  for (const [x, y, color] of [
    [150, 100, "#d63838"],
    // Red is 20 wide: its edge is 10 from the centre line.
    [150, 109.8, "#d63838"],
    [150, 90.2, "#d63838"],
    [150, 110.4, "#ffffff"],
    // Round caps: just past the end.
    [95, 100, "#d63838"],
  ]) {
    tools.setDrawTool({ tool: "picker", color: "#0a0a0a" });
    tap(svg, x, y);
    assert.equal(tools.currentTool().color, color, `${x},${y}`);
  }
});

test("overlapping strokes give the newest; erased paint and the empty canvas give white, a colour", () => {
  for (const [x, y, color] of [
    // Blue was drawn over red.
    [200, 100, "#2a6df4"],
    [200, 140, "#2a6df4"],
    // The eraser's white over red's end.
    [300, 100, "#ffffff"],
    // Nothing there.
    [600, 400, "#ffffff"],
  ]) {
    tools.setDrawTool({ tool: "picker", color: "#0a0a0a" });
    tap(svg, x, y);
    assert.equal(tools.currentTool().color, color, `${x},${y}`);
    assert.equal(tools.currentTool().tool, "brush");
  }
  assert.deepEqual(picked(), ["#2a6df4", "#2a6df4", "#ffffff", "#ffffff"]);

  // White is painted like any colour.
  tap(svg, 500, 300);
  assert.equal(history().at(-1).color, "#ffffff");
});

test("Alt+press with the brush picks and keeps the brush; with the eraser it erases", () => {
  tools.setDrawTool({ tool: "brush", color: "#0a0a0a" });
  tap(svg, 200, 100, 1, { altKey: true });
  assert.deepEqual(queued(), []);
  assert.deepEqual(tools.currentTool(), { tool: "brush", color: "#2a6df4", size: 4 });

  tap(svg, 600, 300);
  assert.equal(history().at(-1).color, "#2a6df4");

  tools.setDrawTool({ tool: "eraser" });
  tap(svg, 150, 100, 1, { altKey: true });
  assert.equal(history().at(-1).color, tools.ERASER.color);
  assert.equal(tools.currentTool().color, "#2a6df4");
});

test("after a pick, the picker gives way to the tool before it: the eraser comes back as the brush", () => {
  tools.setDrawTool({ tool: "eraser" });
  tools.setDrawTool({ tool: "picker" });
  tap(svg, 150, 100);
  assert.deepEqual(tools.currentTool(), { tool: "brush", color: "#d63838", size: 4 });
});

test("Ctrl and the right button still erase with the picker selected; it stays selected", () => {
  tools.setDrawTool({ tool: "picker", color: "#123456" });
  tap(svg, 400, 300, 1, { ctrlKey: true });
  tap(svg, 410, 300, 1, { button: 2, buttons: 2 });
  assert.deepEqual(queued().map((o) => [o.kind, o.color]), [["commit", "#ffffff"], ["commit", "#ffffff"]]);
  assert.deepEqual(picked(), []);
  assert.deepEqual(tools.currentTool(), { tool: "picker", color: "#123456", size: 4 });
});

test("a touch with the picker picks too", () => {
  tools.setDrawTool({ tool: "picker" });
  tap(svg, 200, 60, 1, { pointerType: "touch" });
  assert.deepEqual(picked(), ["#2a6df4"]);
  assert.deepEqual(queued(), []);
});

test("off the drawing (a viewer, between turns) a press picks nothing", () => {
  dm.setDrawingEnabled(false);
  tools.setDrawTool({ tool: "picker", color: "#123456" });
  tap(svg, 150, 100);
  tap(svg, 150, 100, 1, { altKey: true });
  assert.deepEqual(picked(), []);
  assert.equal(tools.currentTool().tool, "picker");

  // A viewer's page: no drawer group, no history.
  svg = renderGamePage(root, { mount: mount + 100, drawer: false });
  dm.mountCanvas(mount + 100);
  tools.setDrawTool({ tool: "picker" });
  tap(svg, 150, 100);
  assert.deepEqual(picked(), []);
});

test("only the colour leaves the page: one color_picked, nothing for the room", () => {
  // (The mount told the page about undo, :undo_available.)
  dispatched.length = 0;
  tools.setDrawTool({ tool: "picker" });
  tap(svg, 150, 100);
  assert.deepEqual(
    dispatched.map((d) => d.name),
    ["color_picked"]
  );
});

// ── The game's paint model in step with the history ─────────────────

// A pick where nothing paints tests (and so records) every stroke.
function pickNothing() {
  tools.setDrawTool({ tool: "picker" });
  tap(svg, 700, 420);
}

const held = (model, list) => list.map((s) => model.has(s.id));

test("drawing costs the model nothing: shapes are made on the first pick", () => {
  const before = FakePath2D.made;
  assert.equal(game().size(), 0);
  tools.setDrawTool({ tool: "brush" });
  for (const x of [400, 420, 440]) tap(svg, x, 300);
  assert.equal(game().size(), 0);
  assert.equal(FakePath2D.made, before);

  pickNothing();
  assert.equal(game().size(), 6);
  // No stroke is near (700, 420): boxes only, no Path2D.
  assert.equal(game().shapes(), 0);

  // A commit after that adds nothing either, until the next pick.
  tools.setDrawTool({ tool: "brush" });
  tap(svg, 460, 300);
  assert.equal(game().size(), 6);
});

test("an undo forgets its stroke; another tab's undo too", () => {
  tools.setDrawTool({ tool: "brush" });
  tap(svg, 400, 300);
  const mine = drawnIds().at(-1);
  pickNothing();
  assert.equal(game().has(mine), true);

  dm.undoStroke();
  assert.equal(game().has(mine), false);
  dm.forgetStroke(BLUE.id);
  assert.deepEqual(held(game(), STROKES), [true, false, true]);
});

test("a rebase, a resync or a rejection keeps the shapes of the strokes still there", () => {
  pickNothing();
  dm.rebaseCanvas([RED, ERASED]);
  assert.deepEqual(held(game(), STROKES), [true, false, true]);

  dm.setStrokes([RED]);
  assert.deepEqual(held(game(), STROKES), [true, false, false]);

  dm.restoreStrokes([BLUE]);
  assert.deepEqual(held(game(), STROKES), [true, false, false]);
});

test("a clear, another tab's clear, a new turn and a new page drop every shape", () => {
  for (const empty of [
    () => dm.clearDrawing(),
    () => dm.applyRoomClear("another-tab"),
    () => dm.setDrawingPath(""),
    () => dm.mountCanvas(mount + 50),
  ]) {
    svg = mountDrawer(++mount);
    pickNothing();
    assert.equal(game().size(), 3);
    empty();
    assert.equal(game().size(), 0, String(empty));
  }
});

test("a restore: the same page instance keeps its shapes, another one drops them", () => {
  pickNothing();
  renderGamePage(root, { mount });
  dm.restoreCanvas(mount);
  assert.equal(game().size(), 3);

  renderGamePage(root, { mount: mount + 1 });
  dm.restoreCanvas(mount + 1);
  assert.equal(game().size(), 0);
});

test("leaving the page drops the shapes at the next check; the history waits for a restore", () => {
  pickNothing();
  assert.equal(game().watching(), true);
  mock.timers.tick(WATCH_MS);
  assert.equal(game().size(), 3);

  renderOtherPage(root);
  mock.timers.tick(WATCH_MS);
  assert.equal(game().size(), 0);
  assert.equal(game().watching(), false);

  // Back to the same instance: its strokes, and picks work again.
  svg = renderGamePage(root, { mount });
  dm.restoreCanvas(mount);
  dm.setDrawingEnabled(true);
  tools.setDrawTool({ tool: "picker" });
  tap(svg, 150, 100);
  assert.equal(tools.currentTool().color, "#d63838");
});

// ── The home board (its store: confirmed, then pending) ─────────────

function renderBoard() {
  root.children = [];
  const el = new FakeEl("svg", "demo-board-svg");
  el.getScreenCTM = () => ({ inverse: () => ({ a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }) });
  el.setPointerCapture = () => {};
  el.hasPointerCapture = () => false;
  el.releasePointerCapture = () => {};
  el.appendChild(new FakeEl("g", "demo-board-strokes"));
  el.appendChild(new FakeEl("g", "demo-board-overlay"));
  el.appendChild(new FakeEl("path", "demo-board-active-path"));
  root.appendChild(el);
  return el;
}

const serverStroke = (s) => ({ stroke_id: s.id, path: s.path, color: s.color, width: s.width });
const completed = () => pushes.filter((p) => p.event === "stroke_complete");

function connectBoard(strokes = [RED, BLUE]) {
  const el = renderBoard();
  tools.setDrawTool({ tool: "brush", color: "#0a0a0a", size: 4 });
  board.connectDemoBoard();
  handlers.strokes({ strokes: strokes.map(serverStroke) });
  return el;
}

function pickOnBoard(el, x, y, press = {}) {
  tools.setDrawTool({ tool: "picker" });
  tap(el, x, y, 1, press);
  return tools.currentTool().color;
}

test("the board picks from confirmed and pending strokes, never from a peer's stroke in progress", () => {
  const el = connectBoard();
  dispatched.length = 0;
  pushes.length = 0;

  assert.equal(pickOnBoard(el, 150, 100), "#d63838");
  assert.equal(pickOnBoard(el, 200, 100), "#2a6df4");
  assert.equal(completed().length, 0);

  // My stroke, pending (no echo yet), over blue.
  tools.setDrawTool({ tool: "brush", color: "#16a34a", size: 12 });
  tap(el, 200, 120);
  assert.equal(completed().length, 1);
  assert.equal(pickOnBoard(el, 200, 120), "#16a34a");

  // A peer's stroke still being drawn: not paint yet.
  handlers.stroke_chunk({ stroke_id: "peer-1", seq: 1, delta: "M 600 300 L 640 300", color: "#9333ea", width: 30 });
  assert.equal(pickOnBoard(el, 620, 300), "#ffffff");
  // Once it is stored, it is.
  handlers.stroke({ stroke_id: "peer-1", path: "M 600 300 L 640 300", color: "#9333ea", width: 30 });
  assert.equal(pickOnBoard(el, 620, 300), "#9333ea");

  // Alt with the brush, as on the game canvas; nothing went to the channel.
  tools.setDrawTool({ tool: "brush" });
  tap(el, 150, 100, 1, { altKey: true });
  assert.deepEqual(tools.currentTool(), { tool: "brush", color: "#d63838", size: 12 });
  assert.equal(completed().length, 1);
  assert.deepEqual(pushes.map((p) => p.event).filter((e) => e !== "stroke_chunk" && e !== "stroke_complete"), []);
  assert.ok(picked().length >= 6);
});

test("the board's model follows its store: rollback, an echo with another path, snapshot, clear", () => {
  const el = connectBoard();
  tools.setDrawTool({ tool: "brush", color: "#16a34a", size: 6 });
  tap(el, 500, 300);
  tap(el, 520, 300);
  const [first, second] = completed().slice(-2);
  const mine = [first.payload.stroke_id, second.payload.stroke_id];

  pickOnBoard(el, 700, 420);
  assert.equal(boardModel().size(), 4);

  // Rejected: the stroke and its shape go.
  first.reply.hooks.error();
  assert.equal(boardModel().has(mine[0]), false);

  // The server's echo with another path than mine: made again at the next
  // pick (one record per id all along).
  handlers.stroke({ ...second.payload, path: "M 520 300 L 560 300" });
  assert.equal(boardModel().has(mine[1]), false);
  assert.equal(pickOnBoard(el, 555, 300), "#16a34a");
  assert.equal(boardModel().has(mine[1]), true);

  // A snapshot keeps what it still holds.
  handlers.strokes({ strokes: [serverStroke(RED)] });
  assert.equal(boardModel().has(RED.id), true);
  assert.equal(boardModel().has(BLUE.id), false);
  assert.equal(boardModel().has(mine[1]), false);

  pickOnBoard(el, 700, 420);
  handlers.cleared();
  assert.equal(boardModel().size(), 0);
  assert.equal(pickOnBoard(el, 150, 100), "#ffffff");
});

test("the board's 500-stroke trim forgets the oldest; its end drops every shape", () => {
  const many = Array.from({ length: 500 }, (_, i) => ({
    id: "fx-" + i,
    path: `M ${i} 10 L ${i} 20`,
    color: "#0a0a0a",
    width: 2,
  }));
  const el = connectBoard(many);
  pickOnBoard(el, 700, 420);
  assert.equal(boardModel().size(), 500);

  handlers.stroke({ stroke_id: "peer-501", path: "M 700 100 L 720 100", color: "#dc2626", width: 4 });
  assert.equal(boardModel().has("fx-0"), false);
  assert.equal(boardModel().size(), 499);

  board.disconnectDemoBoard();
  assert.equal(boardModel().size(), 0);
});

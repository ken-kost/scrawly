// The fill tool (fill_tool.mjs) on both canvases (drawing_manager.mjs and
// demo_board.mjs) against a fake DOM, a fake 2D context
// (support/fake_paint.mjs) and a fake Worker standing in for
// priv/static/fill_worker.mjs: a press with the fill sends the canvas's
// list and the point to the worker and draws no stroke; its shape comes
// back as one more entry, committed like a stroke (the game's op queue with
// `fill: true`, the board's "stroke_complete"), painted evenodd, undone in
// one press; an area already in the colour sends nothing; one fill at a
// time; a reply for a canvas that moved on is dropped; "too detailed" and
// failures show a notice for a moment; Ctrl and the right button still
// erase, Alt still picks; the worker draws ahead when the fill is chosen
// and stops when idle; the eyedropper picks a fill's colour.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, mock, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { installFakeDom, renderGamePage, tap, drawnIds, FakeEl } from "./support/fake_dom.mjs";
import { installFakePaint } from "./support/fake_paint.mjs";

const { root, dispatched } = installFakeDom();
installFakePaint();
mock.timers.enable({ apis: ["setTimeout", "setInterval"] });

// The fill worker: what the page posts, and replies the tests send.
const workers = [];
globalThis.Worker = class {
  constructor(url, opts) {
    this.url = url;
    this.opts = opts;
    this.sent = [];
    this.terminated = false;
    workers.push(this);
  }
  postMessage(msg) {
    this.sent.push(JSON.parse(JSON.stringify(msg)));
  }
  terminate() {
    this.terminated = true;
  }
  reply(data) {
    this.onmessage({ data });
  }
};

// What demo_board.mjs uses of Phoenix.Socket.
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

const fillTool = await import("../../lib/scrawly_web/pages/fill_tool.mjs");
const dm = await import("../../lib/scrawly_web/pages/drawing_manager.mjs");
const board = await import("../../lib/scrawly_web/pages/demo_board.mjs");
const tools = await import("../../lib/scrawly_web/pages/draw_tools.mjs");
const ring = await import("../../lib/scrawly_web/pages/size_ring.mjs");

const { NOTICES, NOTICE_MS, TIMEOUT_MS, IDLE_MS, FILL_WORKER_URL } = fillTool;

const history = () => window.__scrawlyGameCanvas.history;
const queued = () => window.__scrawlyGameCanvas.queue.map((entry) => entry.op);
const worker = () => workers.at(-1);
const fills = () => worker().sent.filter((m) => m.type === "fill");
const lastFill = () => fills().at(-1);
const nodeOf = (id) => document.getElementById("game-canvas-drawer-strokes").children.find((c) => c.getAttribute("data-stroke-id") === id);

// An outlined square (four straight strokes) and a red stroke.
const OUTLINE = [
  { id: "o1", path: "M 100 100 L 300 100", color: "#0a0a0a", width: 4 },
  { id: "o2", path: "M 300 100 L 300 300", color: "#0a0a0a", width: 4 },
  { id: "o3", path: "M 300 300 L 100 300", color: "#0a0a0a", width: 4 },
  { id: "o4", path: "M 100 300 L 100 100", color: "#0a0a0a", width: 4 },
];
const RED = { id: "red", path: "M 500 100 L 700 100", color: "#d63838", width: 20 };
const STROKES = [...OUTLINE, RED];
const SQUARE = "M 101 101 L 299 101 L 299 299 L 101 299 Z";

function mountDrawer(mount, strokes = STROKES) {
  const svg = renderGamePage(root, { mount });
  const notice = new FakeEl("span", "game-canvas-notice");
  root.appendChild(notice);
  dm.mountCanvas(mount);
  tools.setDrawTool({ tool: "fill", color: "#2563eb", size: 4 });
  dm.restoreStrokes(strokes);
  dm.setDrawingEnabled(true);
  return svg;
}

let mount = 0;
let svg;

beforeEach(() => {
  fillTool.resetFillWorker();
  workers.length = 0;
  dispatched.length = 0;
  pushes.length = 0;
  mount += 1;
  svg = mountDrawer(mount);
});

// ── Pure parts ───────────────────────────────────────────────────────

test("sameColor ignores case; plainEntries keeps what the worker needs", () => {
  assert.equal(fillTool.sameColor("#AbCdEf", "#abcdef"), true);
  assert.equal(fillTool.sameColor("#abcdef", "#abcdee"), false);
  assert.equal(fillTool.sameColor(null, "#abcdef"), false);
  assert.deepEqual(
    fillTool.plainEntries([
      { id: "a", path: "M 1 1 L 2 2", color: "#000000", width: 3, el: {}, mine: true, gesture: "g" },
      { id: "b", path: "M 0 0 L 1 0 L 1 1 Z", color: "#ff0000", width: 1, fill: true },
      { id: "c", path: "" },
      null,
    ]),
    [
      { id: "a", path: "M 1 1 L 2 2", color: "#000000", width: 3, fill: false },
      { id: "b", path: "M 0 0 L 1 0 L 1 1 Z", color: "#ff0000", width: 1, fill: true },
    ],
  );
  assert.deepEqual(fillTool.plainEntries(undefined), []);
});

test("replyOutcome: a path to commit, a notice, or nothing", () => {
  assert.deepEqual(fillTool.replyOutcome({ path: SQUARE }), { path: SQUARE });
  assert.deepEqual(fillTool.replyOutcome({ error: "too_detailed" }), { notice: NOTICES.too_detailed });
  assert.deepEqual(fillTool.replyOutcome({ error: "unsupported" }), { notice: NOTICES.unsupported });
  assert.deepEqual(fillTool.replyOutcome({ error: "failed" }), { notice: NOTICES.failed });
  assert.deepEqual(fillTool.replyOutcome({ error: "nothing" }), {});
  assert.deepEqual(fillTool.replyOutcome(null), {});
  assert.equal(NOTICES.too_detailed, "that area is too detailed to fill");
});

// ── The game canvas ──────────────────────────────────────────────────

test("a press with the fill sends the history and the point to a module worker, and draws no stroke", () => {
  tap(svg, 200, 200);
  assert.equal(worker().url, FILL_WORKER_URL);
  assert.deepEqual(worker().opts, { type: "module" });
  assert.equal(FILL_WORKER_URL, "/fill_worker.mjs?v=" + fillTool.FILL_WORKER_VERSION);
  const msg = lastFill();
  assert.equal(msg.canvas, "game");
  assert.deepEqual([msg.x, msg.y, msg.ref], [200, 200, "#ffffff"]);
  assert.deepEqual(msg.strokes.map((s) => s.id), STROKES.map((s) => s.id));
  assert.deepEqual(msg.strokes[0], { ...OUTLINE[0], fill: false });
  assert.deepEqual(queued(), []);
  assert.deepEqual(drawnIds(), STROKES.map((s) => s.id));
  assert.equal(fillTool.fillPending(), true);
});

test("the shape comes back as one entry, committed like a stroke with fill: true, painted evenodd", () => {
  tap(svg, 200, 200);
  worker().reply({ type: "fill", id: lastFill().id, path: SQUARE, epsilon: 0.35 });

  const f = history().at(-1);
  assert.deepEqual({ ...f, id: undefined, gesture: undefined }, {
    id: undefined,
    gesture: undefined,
    path: SQUARE,
    color: "#2563eb",
    width: 1,
    fill: true,
  });
  // A gesture of its own.
  assert.equal(f.gesture, f.id);
  assert.deepEqual(queued().at(-1), {
    op_epoch: queued().at(-1).op_epoch,
    op_seq: queued().at(-1).op_seq,
    kind: "commit",
    stroke_id: f.id,
    path: SQUARE,
    color: "#2563eb",
    width: 1,
    fill: true,
  });
  const node = nodeOf(f.id);
  assert.deepEqual(node.attrs, {
    d: SQUARE,
    fill: "#2563eb",
    "fill-rule": "evenodd",
    stroke: "none",
    "data-completed": "true",
    "data-stroke-id": f.id,
  });
  assert.equal(fillTool.fillPending(), false);
  // The tool stays on the fill.
  assert.equal(tools.currentTool().tool, "fill");
});

test("one undo takes one fill back", () => {
  tap(svg, 200, 200);
  worker().reply({ type: "fill", id: lastFill().id, path: SQUARE });
  const id = history().at(-1).id;
  tap(svg, 600, 400);
  worker().reply({ type: "fill", id: lastFill().id, path: "M 0 0 L 800 0 L 800 450 L 0 450 Z M 101 101 L 101 299 L 299 299 L 299 101 Z" });
  const second = history().at(-1).id;

  dm.undoStroke();
  assert.deepEqual(history().map((s) => s.id), [...STROKES.map((s) => s.id), id]);
  assert.deepEqual(queued().filter((o) => o.kind === "undo").map((o) => o.stroke_id), [second]);
  dm.undoStroke();
  assert.deepEqual(history().map((s) => s.id), STROKES.map((s) => s.id));
});

test("an area already in the colour sends nothing", () => {
  tools.setDrawTool({ color: "#ffffff" });
  tap(svg, 200, 200);
  tools.setDrawTool({ color: "#D63838" });
  tap(svg, 600, 100);
  assert.equal(workers.length === 0 || fills().length === 0, true);
  assert.deepEqual(queued(), []);
  // In another colour it does.
  tap(svg, 200, 200);
  assert.equal(lastFill().ref, "#ffffff");
});

test("filling inside a fill starts from the fill's colour; the eyedropper picks it", () => {
  tap(svg, 200, 200);
  worker().reply({ type: "fill", id: lastFill().id, path: SQUARE });
  tools.setDrawTool({ color: "#16a34a" });
  tap(svg, 200, 200);
  assert.equal(lastFill().ref, "#2563eb");
  assert.equal(lastFill().strokes.at(-1).fill, true);
  worker().reply({ type: "fill", id: lastFill().id, path: SQUARE });

  tools.setDrawTool({ tool: "picker" });
  tap(svg, 150, 150);
  assert.deepEqual(tools.currentTool(), { tool: "fill", color: "#16a34a", size: 4 });
  assert.deepEqual(dispatched.filter((d) => d.name === "color_picked").map((d) => d.params), [{ color: "#16a34a", tool: "fill" }]);
});

test("one fill at a time: a press while one is worked out is taken and does nothing", () => {
  tap(svg, 200, 200);
  tap(svg, 600, 400);
  assert.equal(fills().length, 1);
  assert.deepEqual(queued(), []);
  worker().reply({ type: "fill", id: lastFill().id, path: SQUARE });
  tap(svg, 600, 400);
  assert.equal(fills().length, 2);
});

test("a reply for another request, or after the canvas moved on, commits nothing", () => {
  tap(svg, 200, 200);
  const id = lastFill().id;
  worker().reply({ type: "fill", id: id + 99, path: SQUARE });
  assert.equal(fillTool.fillPending(), true);
  // A new turn (the canvas reset) before the reply.
  dm.setDrawingPath("");
  worker().reply({ type: "fill", id, path: SQUARE });
  assert.deepEqual(history(), []);
  assert.deepEqual(queued(), []);
  assert.equal(fillTool.fillPending(), false);

  // Drawing turned off (time up).
  dm.restoreStrokes(STROKES);
  tap(svg, 200, 200);
  const next = lastFill().id;
  dm.setDrawingEnabled(false);
  worker().reply({ type: "fill", id: next, path: SQUARE });
  assert.equal(history().some((s) => s.fill), false);
});

test("too detailed: a notice for a moment, nothing committed", () => {
  tap(svg, 200, 200);
  worker().reply({ type: "fill", id: lastFill().id, error: "too_detailed" });
  const notice = document.getElementById("game-canvas-notice");
  assert.equal(notice.textContent, "that area is too detailed to fill");
  assert.deepEqual(queued(), []);
  mock.timers.tick(NOTICE_MS);
  assert.equal(notice.textContent, "");
  // "nothing" says nothing.
  tap(svg, 200, 200);
  worker().reply({ type: "fill", id: lastFill().id, error: "nothing" });
  assert.equal(notice.textContent, "");
});

test("a worker that fails to load, or never answers, fails the fill and is started again", () => {
  tap(svg, 200, 200);
  const first = worker();
  first.onerror({ preventDefault() {} });
  assert.equal(first.terminated, true);
  assert.equal(document.getElementById("game-canvas-notice").textContent, NOTICES.failed);
  assert.equal(fillTool.fillPending(), false);

  tap(svg, 200, 200);
  const second = worker();
  assert.notEqual(second, first);
  mock.timers.tick(TIMEOUT_MS);
  assert.equal(second.terminated, true);
  assert.equal(fillTool.fillPending(), false);
  // A late reply from it changes nothing.
  second.reply({ type: "fill", id: 1, path: SQUARE });
  assert.equal(history().some((s) => s.fill), false);
});

test("a worker that can't draw answers unsupported: the notice says so", () => {
  tap(svg, 200, 200);
  worker().reply({ type: "ready", version: 1, raster: false });
  worker().reply({ type: "fill", id: lastFill().id, error: "unsupported" });
  assert.equal(document.getElementById("game-canvas-notice").textContent, NOTICES.unsupported);
});

test("Ctrl and the right button still erase with the fill selected; Alt picks", () => {
  tap(svg, 400, 400, 1, { ctrlKey: true });
  tap(svg, 410, 400, 1, { button: 2, buttons: 2 });
  assert.deepEqual(queued().map((o) => [o.kind, o.color, o.fill]), [["commit", "#ffffff", undefined], ["commit", "#ffffff", undefined]]);
  tap(svg, 600, 100, 1, { altKey: true });
  assert.deepEqual(tools.currentTool(), { tool: "fill", color: "#d63838", size: 4 });
  assert.equal(workers.length === 0 || fills().length === 0, true);
});

test("a touch fills too; with the brush a press draws", () => {
  tap(svg, 200, 200, 1, { pointerType: "touch" });
  assert.equal(fills().length, 1);
  worker().reply({ type: "fill", id: lastFill().id, error: "nothing" });
  tools.setDrawTool({ tool: "brush" });
  tap(svg, 200, 200);
  assert.equal(fills().length, 1);
  assert.equal(queued().at(-1).kind, "commit");
});

test("choosing the fill draws the canvas ahead in the worker; idle, the worker stops", () => {
  tools.setDrawTool({ tool: "brush" });
  tools.setDrawTool({ tool: "fill" });
  const prep = worker().sent.filter((m) => m.type === "prepare");
  assert.equal(prep.length, 1);
  assert.equal(prep[0].canvas, "game");
  assert.deepEqual(prep[0].strokes.map((s) => s.id), STROKES.map((s) => s.id));
  mock.timers.tick(IDLE_MS);
  assert.equal(worker().terminated, true);
  // The next press starts another.
  tap(svg, 200, 200);
  assert.equal(workers.length, 2);
  assert.equal(fills().length, 1);
});

test("a fill survives a rebase, a rejection keeps the room's flag, and other tabs' fills are adopted", () => {
  tap(svg, 200, 200);
  worker().reply({ type: "fill", id: lastFill().id, path: SQUARE });
  const id = history().at(-1).id;
  // The room hasn't stored it yet: the rebase keeps it from the queue.
  dm.rebaseCanvas(STROKES);
  assert.deepEqual(history().at(-1), { id, path: SQUARE, color: "#2563eb", width: 1, fill: true, gesture: id });
  assert.equal(nodeOf(id).getAttribute("fill-rule"), "evenodd");

  dm.setStrokes([...STROKES, { id: "room-fill", path: SQUARE, color: "#9333ea", width: 1, fill: true }]);
  assert.deepEqual(history().at(-1), { id: "room-fill", path: SQUARE, color: "#9333ea", width: 1, fill: true });

  dm.adoptStroke({ id: "other-tab", path: SQUARE, color: "#ca8a04", width: 1, fill: true });
  assert.equal(nodeOf("other-tab").getAttribute("fill"), "#ca8a04");
  dm.adoptStroke({ id: "other-line", path: "M 1 1 L 2 2", color: "#ca8a04", width: 3, fill: false });
  assert.deepEqual(history().at(-1), { id: "other-line", path: "M 1 1 L 2 2", color: "#ca8a04", width: 3 });
});

test("while a press would fill, a mouse over the canvas shows the crosshair; the ring hides", () => {
  assert.equal(ring.ringLook({ tool: "fill", color: "#000000", size: 9 }, null, "mouse", false, false), null);
  // Ctrl held: the eraser's ring.
  assert.deepEqual(ring.ringLook({ tool: "fill", color: "#000000", size: 9 }, null, "mouse", true, false), { size: 9, eraser: true });
});

// ── The home board ───────────────────────────────────────────────────

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
  root.appendChild(new FakeEl("span", "demo-board-notice"));
  return el;
}

const serverStroke = (s) => ({ stroke_id: s.id, path: s.path, color: s.color, width: s.width, ...(s.fill ? { fill: true } : {}) });
const completed = () => pushes.filter((p) => p.event === "stroke_complete");
const boardNodes = () => document.getElementById("demo-board-strokes").children;

function connectBoard(strokes = STROKES) {
  const el = renderBoard();
  tools.setDrawTool({ tool: "fill", color: "#2563eb", size: 4 });
  board.connectDemoBoard();
  handlers.strokes({ strokes: strokes.map(serverStroke) });
  return el;
}

test("the board: a fill is pushed as stroke_complete with fill: true and its own gesture, painted evenodd", () => {
  const el = connectBoard();
  tap(el, 200, 200);
  const msg = lastFill();
  assert.equal(msg.canvas, "board");
  assert.equal(msg.ref, "#ffffff");
  assert.deepEqual(msg.strokes.map((s) => s.id), STROKES.map((s) => s.id));
  worker().reply({ type: "fill", id: msg.id, path: SQUARE });

  const push = completed().at(-1);
  assert.deepEqual({ ...push.payload, stroke_id: undefined, gesture: undefined }, {
    stroke_id: undefined,
    gesture: undefined,
    path: SQUARE,
    color: "#2563eb",
    width: 1,
    fill: true,
  });
  assert.equal(push.payload.gesture, push.payload.stroke_id);
  const node = boardNodes().at(-1);
  assert.equal(node.getAttribute("fill"), "#2563eb");
  assert.equal(node.getAttribute("fill-rule"), "evenodd");
  assert.equal(node.getAttribute("stroke"), "none");
  assert.equal(node.getAttribute("stroke-width"), null);

  // The echo confirms it as a fill; a snapshot keeps it one.
  push.reply.hooks.ok({});
  handlers.stroke({ ...serverStroke({ id: push.payload.stroke_id, path: SQUARE, color: "#2563eb", width: 1, fill: true }), mine: true });
  assert.equal(boardNodes().at(-1).getAttribute("fill"), "#2563eb");
  handlers.strokes({ strokes: [...STROKES.map(serverStroke), { stroke_id: push.payload.stroke_id, path: SQUARE, color: "#2563eb", width: 1, fill: true, mine: true }] });
  assert.equal(boardNodes().at(-1).getAttribute("fill-rule"), "evenodd");
  assert.equal(boardNodes()[0].getAttribute("fill"), "none");

  // One undo takes the fill back.
  board.undoBoard();
  assert.equal(boardNodes().length, STROKES.length);
  board.disconnectDemoBoard();
});

test("the board: a peer's fill arrives painted; the next fill and the eyedropper see it", () => {
  const el = connectBoard();
  handlers.stroke({ stroke_id: "peer-fill", path: SQUARE, color: "#9333ea", width: 1, fill: true });
  assert.equal(boardNodes().at(-1).getAttribute("fill"), "#9333ea");
  tap(el, 200, 200);
  assert.equal(lastFill().ref, "#9333ea");
  assert.equal(lastFill().strokes.at(-1).fill, true);
  worker().reply({ type: "fill", id: lastFill().id, error: "nothing" });

  tools.setDrawTool({ tool: "picker" });
  tap(el, 150, 150);
  assert.deepEqual(tools.currentTool(), { tool: "fill", color: "#9333ea", size: 4 });
  board.disconnectDemoBoard();
});

test("the board: a clear between the press and the reply drops the fill", () => {
  const el = connectBoard();
  tap(el, 200, 200);
  handlers.cleared({});
  const before = completed().length;
  worker().reply({ type: "fill", id: lastFill().id, path: SQUARE });
  assert.equal(completed().length, before);
  assert.equal(boardNodes().length, 0);
  board.disconnectDemoBoard();
});

test("the game: the drawer's clear between the press and the reply drops the fill", () => {
  tap(svg, 200, 200);
  dm.clearDrawing();
  worker().reply({ type: "fill", id: lastFill().id, path: SQUARE });
  assert.deepEqual(history(), []);
  assert.deepEqual(queued().map((o) => o.kind), ["clear"]);
});

test("the board: too detailed shows its notice; a reply after the board ended commits nothing", () => {
  const el = connectBoard();
  tap(el, 200, 200);
  worker().reply({ type: "fill", id: lastFill().id, error: "too_detailed" });
  assert.equal(document.getElementById("demo-board-notice").textContent, NOTICES.too_detailed);
  tap(el, 200, 200);
  board.disconnectDemoBoard();
  const before = completed().length;
  worker().reply({ type: "fill", id: lastFill().id, path: SQUARE });
  assert.equal(completed().length, before);
});

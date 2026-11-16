// The in-game canvas module (lib/scrawly_web/pages/drawing_manager.mjs)
// against a fake DOM: tool state per page instance, one shared state for
// every bundle's copy of the module, the op queue across page instances and
// Back/Forward restores, a drawer's second tab, and viewers' live overlays.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, mock, beforeEach } from "node:test";
import assert from "node:assert/strict";

import {
  installFakeDom,
  renderGamePage,
  renderOtherPage,
  tap,
  scribble,
  drawnIds,
  overlayIds,
} from "./support/fake_dom.mjs";

const { root, dispatched } = installFakeDom();
mock.timers.enable({ apis: ["setTimeout"] });

const MODULE = "../../lib/scrawly_web/pages/drawing_manager.mjs";
// Hologram 0.12 puts a copy of the module in every page bundle that can
// reach GamePage: a second URL gives node a second module instance.
const dm = await import(MODULE);
const copy = await import(MODULE + "?bundle=home");
// GamePage pushes its toolbar's tool to draw_tools.mjs (setDrawTool).
const tools = await import("../../lib/scrawly_web/pages/draw_tools.mjs");
const channels = await import("../../lib/scrawly_web/pages/room_channels.mjs");

const ops = () => dispatched.filter((d) => d.name === "send_stroke_op").map((d) => d.params);
const lastOp = () => ops().at(-1);

// A fresh drawer page instance (what GamePage :mounted does).
function mountDrawer(mount, strokes = []) {
  const svg = renderGamePage(root, { mount });
  dm.mountCanvas(mount);
  tools.setDrawTool({ tool: "brush", color: "#0a0a0a", size: 2 });
  dm.restoreStrokes(strokes);
  dm.setDrawingEnabled(true);
  return svg;
}

const S1 = { id: "room-1", path: "M 1 1 L 2 2", color: "#000000", width: 2 };

beforeEach(() => {
  dispatched.length = 0;
});

test("the eraser of an earlier page instance doesn't leak into the next one", () => {
  // Instance 1: the drawer turns the eraser on (GamePage toggle_eraser).
  const first = mountDrawer(1);
  tools.setDrawTool({ tool: "eraser", color: "#d63838", size: 5 });
  tap(first);
  // The eraser: white, at the slider's size.
  assert.equal(lastOp().color, tools.ERASER.color);
  assert.equal(lastOp().width, 5);
  dm.ackStrokeOp(lastOp().op_seq);

  // Instance 2: mountCanvas puts the default tool back before :mounted
  // pushes the page's own.
  const svg = renderGamePage(root, { mount: 2 });
  dm.mountCanvas(2);
  dm.setDrawingEnabled(true);
  tap(svg);
  assert.equal(lastOp().kind, "commit");
  assert.equal(lastOp().color, tools.DEFAULT_TOOL.color);
  assert.equal(lastOp().width, tools.DEFAULT_TOOL.size);
  dm.ackStrokeOp(lastOp().op_seq);

  // The page's tool (pushed on :mounted, after a restore and on every
  // change) is the one drawn with, read when the stroke starts.
  tools.setDrawTool({ tool: "brush", color: "#d63838", size: 10 });
  tap(svg, 30, 30);
  assert.equal(lastOp().color, "#d63838");
  assert.equal(lastOp().width, 10);
  dm.ackStrokeOp(lastOp().op_seq);
});

test("a right-button or Ctrl tap erases at the slider's size; the toolbar's brush stays", () => {
  const svg = mountDrawer(3);
  tools.setDrawTool({ tool: "brush", color: "#2a6df4", size: 14 });

  for (const press of [{ button: 2, buttons: 2 }, { ctrlKey: true }, { button: 2, ctrlKey: true }]) {
    tap(svg, 20, 20, 1, press);
    // What the room (and through it every viewer) gets: an ordinary
    // eraser stroke, white at the size.
    assert.equal(lastOp().kind, "commit", JSON.stringify(press));
    assert.deepEqual([lastOp().color, lastOp().width], [tools.ERASER.color, 14], JSON.stringify(press));
    dm.ackStrokeOp(lastOp().op_seq);
  }
  assert.deepEqual(tools.currentTool(), { tool: "brush", color: "#2a6df4", size: 14 });

  // No Ctrl, or Cmd: the brush.
  for (const press of [{}, { metaKey: true }]) {
    tap(svg, 25, 25, 1, press);
    assert.deepEqual([lastOp().color, lastOp().width], ["#2a6df4", 14], JSON.stringify(press));
    dm.ackStrokeOp(lastOp().op_seq);
  }
});

test("every bundle's copy acts on the same canvas, queue and generation", () => {
  const svg = mountDrawer(3);
  assert.equal(copy.gamePageGeneration(), dm.gamePageGeneration());

  tap(svg);
  const op = lastOp();
  // The other copy (bound by another bundle) acks the op this one queued.
  copy.ackStrokeOp(op.op_seq);
  tap(svg, 20, 20);
  assert.equal(ops().length, 2, "the ack released the head, so the next op went out");
  assert.equal(lastOp().op_epoch, op.op_epoch, "one epoch per tab");

  // A mount through the other copy drops this copy's queue and history.
  const unacked = lastOp().op_seq;
  copy.mountCanvas(4);
  renderGamePage(root, { mount: 4 });
  dispatched.length = 0;
  mock.timers.tick(20_000);
  assert.equal(ops().length, 0, `op ${unacked} of the old instance was never resent`);
  assert.deepEqual(drawnIds(), []);
  assert.equal(copy.gamePageGeneration(), dm.gamePageGeneration());
});

test("leaving the page pauses the queue; restoring that instance resumes it", () => {
  const svg = mountDrawer(5, [S1]);
  tap(svg);
  const op = lastOp();
  const drawn = drawnIds();
  assert.deepEqual(drawn, ["room-1", op.stroke_id]);

  // A header link: the page is gone before the room answered.
  renderOtherPage(root);
  dispatched.length = 0;
  mock.timers.tick(60_000);
  assert.equal(ops().length, 0, "nothing goes to another page's actions");

  // Back: the same instance is restored. Its canvas is back at once and
  // the queued op is sent again (the room ignores it if it got it).
  renderGamePage(root, { mount: 5 });
  dm.restoreCanvas(5);
  assert.deepEqual(drawnIds(), drawn);
  assert.equal(ops().length, 1);
  assert.equal(lastOp().op_seq, op.op_seq);

  // The resync's snapshot: the room's strokes plus the op still queued.
  dm.rebaseCanvas([S1]);
  assert.deepEqual(drawnIds(), drawn);
  dm.ackStrokeOp(op.op_seq);
  dm.rebaseCanvas([S1, { id: op.stroke_id, path: op.path, color: op.color, width: op.width }]);
  assert.deepEqual(drawnIds(), drawn, "no duplicate once the room has it");
});

test("another page instance never sends or shows the old instance's ops", () => {
  const svg = mountDrawer(6);
  tap(svg);
  const op = lastOp();

  // Back/Forward shows instance 7 (a different room) before the op's retry.
  renderGamePage(root, { mount: 7 });
  dispatched.length = 0;
  mock.timers.tick(5_000);
  assert.equal(ops().length, 0, `op ${op.op_seq} paused: the marker is another instance's`);

  dm.restoreCanvas(7);
  dm.rebaseCanvas([S1]);
  mock.timers.tick(60_000);
  assert.equal(ops().length, 0);
  assert.deepEqual(drawnIds(), ["room-1"]);
});

test("the room's strokes plus queued commits, undos and clears", () => {
  const svg = mountDrawer(8, [S1]);
  tap(svg);
  const first = lastOp();
  tap(svg, 40, 40);
  dm.undoStroke();
  dm.clearDrawing();
  tap(svg, 50, 50);
  const queued = ops();
  assert.equal(queued.length, 1, "only the head is in flight");

  // Nothing applied yet: room [S1] + commit, commit, undo, clear, commit.
  dm.rebaseCanvas([S1]);
  assert.equal(drawnIds().length, 1);
  assert.notEqual(drawnIds()[0], first.stroke_id);
});

test("an unanswered op is resent until the room answers, never dropped", () => {
  const svg = mountDrawer(9);
  tap(svg);
  const op = lastOp();

  mock.timers.tick(5_000);
  mock.timers.tick(5_000);
  assert.equal(ops().length, 3);
  // Then every 15 s, for as long as the page is shown.
  mock.timers.tick(5_000);
  assert.equal(ops().length, 3);
  mock.timers.tick(10_000);
  assert.equal(ops().length, 4);
  for (let i = 0; i < 6; i++) mock.timers.tick(15_000);
  assert.equal(ops().length, 10);
  assert.ok(ops().every((o) => o.op_seq === op.op_seq));

  // A reply without a seq (it can't be matched to an op) releases nothing.
  dm.rejectStrokeOp(null);
  dm.ackStrokeOp(undefined);
  tap(svg, 30, 30);
  assert.equal(ops().length, 10, "the second op waits behind the head");

  dm.ackStrokeOp(op.op_seq);
  assert.equal(ops().length, 11);
  assert.notEqual(lastOp().op_seq, op.op_seq);
  dm.ackStrokeOp(lastOp().op_seq);
});

test("a rejection applies only to the op at the head", () => {
  const svg = mountDrawer(10, [S1]);
  tap(svg);
  const op = lastOp();

  assert.equal(dm.applyRejectedStrokes(op.op_seq - 1, []), false);
  assert.equal(dm.applyRejectedStrokes(null, []), false);
  assert.equal(drawnIds().length, 2);

  assert.equal(dm.applyRejectedStrokes(op.op_seq, [S1]), true);
  assert.deepEqual(drawnIds(), ["room-1"]);
});

test("a drawer's second tab follows the strokes, undos and clears of the first", () => {
  const svg = mountDrawer(11, [S1]);
  tap(svg);
  const own = lastOp();
  dm.ackStrokeOp(own.op_seq);

  // Its own stroke coming back (:stroke_completed) changes nothing.
  dm.adoptStroke({ id: own.stroke_id, path: own.path, color: own.color, width: own.width });
  assert.deepEqual(drawnIds(), ["room-1", own.stroke_id]);

  // The other tab's live chunks, then its completed stroke: the overlay goes,
  // the stroke joins this canvas.
  dm.applyRemoteChunk("tab2-a", 1, "M 5 5 L 6 6", "#2a6df4", 5);
  assert.deepEqual(overlayIds(), ["tab2-a"]);
  dm.adoptStroke({ id: "tab2-a", path: "M 5 5 L 6 6", color: "#2a6df4", width: 5 });
  assert.deepEqual(overlayIds(), []);
  assert.deepEqual(drawnIds(), ["room-1", own.stroke_id, "tab2-a"]);

  // The other tab undoes it.
  dm.forgetStroke("tab2-a");
  assert.deepEqual(drawnIds(), ["room-1", own.stroke_id]);

  // Its own clear's echo is ignored (a stroke drawn after it stays)...
  dm.clearDrawing();
  const clear = lastOp();
  dm.ackStrokeOp(clear.op_seq);
  tap(svg, 60, 60);
  const after = lastOp();
  dm.applyRoomClear(clear.op_epoch);
  assert.deepEqual(drawnIds(), [after.stroke_id]);

  // ...the other tab's clear empties it, but for strokes still queued here.
  dm.applyRoomClear("another-tab-epoch");
  assert.deepEqual(drawnIds(), [after.stroke_id]);
  dm.ackStrokeOp(after.op_seq);
  dm.applyRoomClear("another-tab-epoch");
  assert.deepEqual(drawnIds(), []);
});

test("viewers keep the live preview of a stroke still being drawn", () => {
  renderGamePage(root, { mount: 12, drawer: false });
  dm.mountCanvas(12);

  dm.applyRemoteChunk("done", 1, "M 1 1 L 2 2", "#000000", 2);
  dm.applyRemoteChunk("live", 1, "M 3 3 L 4 4", "#000000", 2);
  assert.deepEqual(overlayIds(), ["done", "live"]);

  // A snapshot holds "done" only: "live" keeps its preview.
  dm.settleRemoteStrokes(["room-1", "done"]);
  assert.deepEqual(overlayIds(), ["live"]);
  dm.applyRemoteChunk("done", 2, " L 9 9", "#000000", 2);
  assert.deepEqual(overlayIds(), ["live"], "a finished stroke's late chunk is ignored");

  // A clear drops the overlays, but a stroke drawn after it comes back
  // with its next chunk.
  dm.clearRemoteStrokes();
  assert.deepEqual(overlayIds(), []);
  dm.applyRemoteChunk("live", 2, " L 5 5", "#000000", 2);
  assert.deepEqual(overlayIds(), ["live"]);

  // A new turn closes them for good.
  dm.setDrawingPath("");
  dm.applyRemoteChunk("live", 3, " L 6 6", "#000000", 2);
  assert.deepEqual(overlayIds(), []);
});

test("room_channels.mjs: the rooms a restored page drops", () => {
  channels.noteRoomChannel("room-a");
  channels.noteRoomChannel("room-b");
  channels.noteRoomChannel("room-a");
  channels.noteRoomChannel("");
  assert.deepEqual(channels.takeStaleRoomChannels("room-a"), ["room-b"]);
  assert.deepEqual(channels.takeStaleRoomChannels(null), ["room-a"]);
  assert.deepEqual(channels.takeStaleRoomChannels(null), []);

  for (let i = 0; i < 30; i++) channels.noteRoomChannel("r" + i);
  assert.equal(channels.takeStaleRoomChannels(null).length, 20);
});

// ── Undo: whole gestures ───────────────────────────────────────────────

const undoReports = () => dispatched.filter((d) => d.name === "undo_available").map((d) => d.params.available);

// Acks the head until the queue is empty (the room applied every op).
function drainOps() {
  for (let i = 0; i < 100 && window.__scrawlyGameCanvas.queue.length > 0; i++) {
    dm.ackStrokeOp(window.__scrawlyGameCanvas.queue[0].op.op_seq);
  }
}

test("one undo takes back a whole split gesture: one undo op per stroke, in queue order", () => {
  const svg = mountDrawer(20, [S1]);
  tap(svg, 30, 30);
  drainOps();
  const before = drawnIds();

  scribble(svg);
  const parts = drawnIds().slice(before.length);
  assert.ok(parts.length >= 2, `split into ${parts.length}`);
  const gesture = window.__scrawlyGameCanvas.history.at(-1).gesture;
  assert.equal(gesture, parts[0]);
  drainOps();

  dispatched.length = 0;
  dm.undoStroke();
  assert.deepEqual(drawnIds(), before, "the whole scribble left the canvas at once");

  // One undo op per stroke, newest first, each with its own op_seq after
  // the last one: only the head is in flight, the next goes on its ack.
  const sent = [];
  for (let i = 0; i < parts.length; i++) {
    const op = lastOp();
    assert.equal(op.kind, "undo");
    sent.push(op);
    dm.ackStrokeOp(op.op_seq);
  }
  assert.deepEqual(sent.map((o) => o.stroke_id), parts.slice().reverse());
  assert.ok(sent.every((o, i) => i === 0 || o.op_seq === sent[i - 1].op_seq + 1));
  assert.ok(sent.every((o) => o.op_epoch === sent[0].op_epoch));
  assert.equal(window.__scrawlyGameCanvas.queue.length, 0);

  // The next press takes the tap, alone.
  dm.undoStroke();
  assert.deepEqual(drawnIds(), ["room-1"]);
  assert.equal(lastOp().kind, "undo");
  drainOps();
});

test("an undo before the room acked the gesture's commits queues behind them", () => {
  const svg = mountDrawer(21);
  scribble(svg);
  const parts = drawnIds();
  dm.undoStroke();
  assert.deepEqual(drawnIds(), []);

  const kinds = window.__scrawlyGameCanvas.queue.map((q) => q.op.kind);
  assert.deepEqual(kinds, [...parts.map(() => "commit"), ...parts.map(() => "undo")]);
  // What the room will hold once they're applied: nothing.
  dm.rebaseCanvas([]);
  assert.deepEqual(drawnIds(), []);
  drainOps();
});

test("strokes from the room (a reload) undo one per press; a rebase keeps this tab's gestures", () => {
  // A reload: the history comes from the room, without gestures.
  const room = ["r-a", "r-b", "r-c"].map((id) => ({ ...S1, id }));
  mountDrawer(22, room);
  dm.undoStroke();
  assert.deepEqual(drawnIds(), ["r-a", "r-b"]);
  drainOps();

  // Back/Forward: the same instance, rebased on the room's snapshot.
  const svg = mountDrawer(23);
  scribble(svg);
  const parts = drawnIds();
  drainOps();
  renderOtherPage(root);
  renderGamePage(root, { mount: 23 });
  dm.restoreCanvas(23);
  const fromRoom = window.__scrawlyGameCanvas.history.map((s) => ({ id: s.id, path: s.path, color: s.color, width: s.width }));
  dm.rebaseCanvas(fromRoom);
  dm.setDrawingEnabled(true);
  dm.undoStroke();
  assert.deepEqual(drawnIds(), [], `all ${parts.length} parts with one press`);
  drainOps();
});

test("the page hears when there is something to undo, and only then", () => {
  const svg = mountDrawer(24);
  assert.deepEqual(undoReports(), []);
  tap(svg, 10, 10);
  tap(svg, 20, 20);
  assert.deepEqual(undoReports(), [true]);
  dm.undoStroke();
  assert.deepEqual(undoReports(), [true]);
  dm.undoStroke();
  assert.deepEqual(undoReports(), [true, false]);
  drainOps();

  // A mount with the room's strokes: on at once.
  dispatched.length = 0;
  mountDrawer(25, [S1]);
  assert.deepEqual(undoReports(), [true]);
  dm.clearDrawing();
  assert.deepEqual(undoReports(), [true, false]);
  drainOps();

  // Another page in the document hears nothing.
  dispatched.length = 0;
  const own = mountDrawer(26);
  renderOtherPage(root);
  dm.adoptStroke({ id: "tab2-x", path: "M 1 1 L 2 2", color: "#000000", width: 2 });
  assert.deepEqual(undoReports(), []);
  renderGamePage(root, { mount: 26 });
  dm.restoreCanvas(26);
  assert.deepEqual(undoReports(), [true], "the restored page is told");
  void own;

  // Viewers never draw: never told.
  dispatched.length = 0;
  renderGamePage(root, { mount: 27, drawer: false });
  dm.mountCanvas(27);
  dm.applyRemoteChunk("v-1", 1, "M 1 1 L 2 2", "#000000", 2);
  assert.deepEqual(undoReports(), []);
});

test("lastGesture: the newest stroke's gesture, newest first; one stroke without", () => {
  assert.deepEqual(dm.lastGesture([]), []);
  assert.deepEqual(dm.lastGesture([{ id: "a" }, { id: "b" }]), ["b"]);
  assert.deepEqual(
    dm.lastGesture([{ id: "a", gesture: "a" }, { id: "x" }, { id: "b", gesture: "a" }, { id: "c", gesture: "a" }]),
    ["c", "b", "a"]
  );
  assert.deepEqual(dm.lastGesture([{ id: "a", gesture: "a" }, { id: "b", gesture: "b" }]), ["b"]);
  // A fill (#43) is an entry with an id like any other.
  assert.deepEqual(dm.lastGesture([{ id: "a", gesture: "a" }, { id: "f", fill: true }]), ["f"]);
});

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
const channels = await import("../../lib/scrawly_web/pages/room_channels.mjs");

const ops = () => dispatched.filter((d) => d.name === "send_stroke_op").map((d) => d.params);
const lastOp = () => ops().at(-1);

// A fresh drawer page instance (what GamePage :mounted does).
function mountDrawer(mount, strokes = []) {
  const svg = renderGamePage(root, { mount });
  dm.mountCanvas(mount);
  dm.setToolColor("#000000");
  dm.setToolWidth(2);
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
  mountDrawer(1);
  dm.setToolColor("#FFFFFF");
  dm.setToolWidth(20);

  // Instance 2: mountCanvas puts the default tool back before :mounted
  // pushes the page's own.
  const svg = renderGamePage(root, { mount: 2 });
  dm.mountCanvas(2);
  dm.setDrawingEnabled(true);
  tap(svg);
  assert.equal(lastOp().kind, "commit");
  assert.equal(lastOp().color, "#000000");
  assert.equal(lastOp().width, 2);
  dm.ackStrokeOp(lastOp().op_seq);

  // The page's tool (pushed on :mounted and after a restore) is the one drawn with.
  dm.setToolColor("#d63838");
  dm.setToolWidth(10);
  tap(svg, 30, 30);
  assert.equal(lastOp().color, "#d63838");
  assert.equal(lastOp().width, 10);
  dm.ackStrokeOp(lastOp().op_seq);
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

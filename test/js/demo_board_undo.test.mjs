// The home board's identity and undo (lib/scrawly_web/pages/demo_board.mjs)
// against a fake DOM and a fake Phoenix socket: the board token the page
// hands over (and a fresh one when the board refuses it), the `mine` flags
// the server sends, and undo: a press hides my newest gesture at once and
// asks the server, which answers with the ids it removed; a press right
// after the release waits for the stroke's reply (a rejected stroke spends
// it, an accepted one is then undone), and nothing of anyone else's goes.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, mock, beforeEach, after } from "node:test";
import assert from "node:assert/strict";

import { installFakeDom, FakeEl, tap, scribble } from "./support/fake_dom.mjs";
import { installFakePhoenix } from "./support/fake_phoenix.mjs";

const { root, dispatched } = installFakeDom();
const phoenix = installFakePhoenix();
mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
let clock = 1000;
globalThis.performance = { now: () => clock };

const board = await import("../../lib/scrawly_web/pages/demo_board.mjs");
const tools = await import("../../lib/scrawly_web/pages/draw_tools.mjs");
const { SPLIT_AT } = await import("../../lib/scrawly_web/pages/stroke_engine.mjs");

// GameDemo's markup.
function renderBoard() {
  root.children = [];
  const svg = new FakeEl("svg", "demo-board-svg");
  svg.getScreenCTM = () => ({ inverse: () => ({ a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }) });
  svg.setPointerCapture = () => {};
  svg.hasPointerCapture = () => false;
  svg.releasePointerCapture = () => {};
  svg.appendChild(new FakeEl("g", "demo-board-strokes"));
  svg.appendChild(new FakeEl("g", "demo-board-overlay"));
  svg.appendChild(new FakeEl("path", "demo-board-active-path"));
  root.appendChild(svg);
  return svg;
}

const ch = () => phoenix.channel();
const pushes = (event) => ch().pushes.filter((p) => p.event === event);
const drawn = () => document.getElementById("demo-board-strokes").children.map((el) => el.getAttribute("data-stroke-id"));
const store = () => window.__scrawlyDemoBoard.strokes.map((e) => e.id);
const asked = () => dispatched.filter((d) => d.name === "board_token_refused").length;
const undoReports = () => dispatched.filter((d) => d.name === "undo_available").map((d) => d.params.available);

const S = (id, mine) => ({ stroke_id: id, path: "M 1 1 L 2 2", color: "#0a0a0a", width: 4, ...(mine ? { mine: true } : {}) });

// HomePage: the token (:board_token_ready), the join, the snapshot.
function connect(strokes = [], token = "tok-1") {
  const svg = renderBoard();
  tools.setDrawTool({ tool: "brush", color: "#0a0a0a", size: 4 });
  board.connectDemoBoard(token);
  ch().joinReply.answer("ok", { draw: true });
  ch().emit("strokes", { strokes });
  return svg;
}

// My stroke, pushed: its reply and echo, as the server sends them.
function accept(push) {
  push.reply.answer("ok", {});
  ch().emit("stroke", { ...push.payload, mine: true });
}

beforeEach(() => {
  dispatched.length = 0;
  clock += 60_000;
});

after(() => board.disconnectDemoBoard());

test("the socket connects with the page's token; a new token reconnects it", () => {
  connect();
  assert.deepEqual(phoenix.socket().connects, [{ board_token: "tok-1" }]);
  assert.equal(asked(), 0);

  // The same token again (a second reply): nothing to do.
  board.connectDemoBoard("tok-1");
  assert.equal(phoenix.socket().connects.length, 1);

  // A fresh one: the socket reconnects with it, without asking for another.
  board.connectDemoBoard("tok-2");
  assert.deepEqual(phoenix.socket().connects, [{ board_token: "tok-1" }, { board_token: "tok-2" }]);
  assert.equal(asked(), 0);
});

test("a board that may not draw asks the page for a token, at most every 30 s", () => {
  connect([], null);
  assert.deepEqual(phoenix.socket().connects, [{}]);
  // connect() answered the join with draw: true; a refusing join:
  ch().joinReply.answer("ok", { draw: false });
  assert.equal(asked(), 1);
  ch().joinReply.answer("ok", { draw: false });
  assert.equal(asked(), 1, "not again within 30 s");

  clock += 30_000;
  ch().joinReply.answer("ok", { draw: false });
  assert.equal(asked(), 2);

  // A stroke refused as unauthorized goes, and asks (after 30 s).
  const svg = document.getElementById("demo-board-svg");
  clock += 30_000;
  tap(svg, 40, 40);
  const push = pushes("stroke_complete").at(-1);
  assert.deepEqual(store(), [push.payload.stroke_id]);
  push.reply.answer("error", { reason: "unauthorized" });
  assert.deepEqual(store(), []);
  assert.equal(asked(), 3);

  // The server closed the socket (the user's tokens were revoked): asks
  // at once; the page's token reconnects it.
  phoenix.socket().serverClose();
  assert.equal(asked(), 4);
  board.connectDemoBoard("tok-3");
  assert.deepEqual(phoenix.socket().connects.at(-1), { board_token: "tok-3" });
  assert.equal(asked(), 4, "our own disconnect is no server close");
});

test("a stroke goes with its gesture; a long scribble's strokes share one", () => {
  const svg = connect();
  tap(svg, 40, 40);
  const one = pushes("stroke_complete").at(-1).payload;
  assert.equal(one.gesture, one.stroke_id);

  const before = pushes("stroke_complete").length;
  scribble(svg);
  const parts = pushes("stroke_complete").slice(before).map((p) => p.payload);
  assert.ok(parts.length >= 2, `split into ${parts.length}`);
  assert.ok(parts.every((p) => p.path.length < SPLIT_AT + 100));
  assert.ok(parts.every((p) => p.gesture === parts[0].stroke_id));
});

test("undo hides my newest stroke at once and the server's ids go; never anyone else's", () => {
  connect([S("a-1"), S("m-1", true), S("b-1"), S("m-2", true), S("b-2")]);
  assert.deepEqual(undoReports(), [true]);

  board.undoBoard();
  assert.deepEqual(drawn(), ["a-1", "m-1", "b-1", "b-2"], "hidden at once");
  assert.equal(pushes("undo").length, 1);
  assert.deepEqual(pushes("undo")[0].payload, {}, "a client names no stroke");

  pushes("undo")[0].reply.answer("ok", { stroke_ids: ["m-2"] });
  ch().emit("stroke_removed", { stroke_ids: ["m-2"] });
  assert.deepEqual(store(), ["a-1", "m-1", "b-1", "b-2"]);

  board.undoBoard();
  pushes("undo")[1].reply.answer("ok", { stroke_ids: ["m-1"] });
  assert.deepEqual(drawn(), ["a-1", "b-1", "b-2"]);
  assert.deepEqual(undoReports(), [true, false]);

  // Nothing of mine left: nothing to send.
  board.undoBoard();
  assert.equal(pushes("undo").length, 2);

  // Another visitor's undo takes only their ids.
  ch().emit("stroke_removed", { stroke_ids: ["b-2", "nope"] });
  assert.deepEqual(drawn(), ["a-1", "b-1"]);
});

test("what the server didn't remove comes back at its place", () => {
  connect([S("a-1"), S("m-1", true), S("b-1")]);
  board.undoBoard();
  assert.deepEqual(drawn(), ["a-1", "b-1"]);
  assert.deepEqual(undoReports(), [true, false]);

  pushes("undo")[0].reply.answer("error", { reason: "rate_limited" });
  assert.deepEqual(drawn(), ["a-1", "m-1", "b-1"]);
  assert.deepEqual(undoReports(), [true, false, true]);

  // A timeout too; an unauthorized one also asks for a token.
  board.undoBoard();
  pushes("undo")[1].reply.answer("timeout");
  assert.deepEqual(drawn(), ["a-1", "m-1", "b-1"]);
  board.undoBoard();
  pushes("undo")[2].reply.answer("error", { reason: "unauthorized" });
  assert.deepEqual(drawn(), ["a-1", "m-1", "b-1"]);
  assert.equal(asked(), 1);

  // The server removed another stroke of mine than the one shown newest
  // (another tab of mine drew it): that one goes, mine comes back.
  ch().emit("stroke", S("m-2", true));
  board.undoBoard();
  assert.deepEqual(drawn(), ["a-1", "m-1", "b-1"]);
  pushes("undo")[3].reply.answer("ok", { stroke_ids: ["m-1"] });
  assert.deepEqual(drawn(), ["a-1", "b-1", "m-2"]);
});

test("undo right after the release waits for the stroke's reply, then undoes that stroke", () => {
  const svg = connect([S("a-1"), S("m-old", true)]);
  tap(svg, 40, 40);
  const stroke = pushes("stroke_complete").at(-1);
  const id = stroke.payload.stroke_id;

  board.undoBoard();
  assert.deepEqual(drawn(), ["a-1", "m-old"], "hidden at once");
  assert.equal(pushes("undo").length, 0, "waits: the server may still reject it");

  // Accepted (its echo keeps it hidden), then undone.
  accept(stroke);
  assert.equal(pushes("undo").length, 1);
  assert.deepEqual(drawn(), ["a-1", "m-old"]);
  pushes("undo")[0].reply.answer("ok", { stroke_ids: [id] });
  ch().emit("stroke_removed", { stroke_ids: [id] });
  assert.deepEqual(store(), ["a-1", "m-old"]);
  assert.deepEqual(drawn(), ["a-1", "m-old"]);
});

test("undo of a stroke the server then rejects is spent on it: no older stroke goes", () => {
  const svg = connect([S("a-1"), S("m-old", true)]);
  tap(svg, 40, 40);
  const stroke = pushes("stroke_complete").at(-1);

  board.undoBoard();
  stroke.reply.answer("error", { reason: "rate_limited" });
  assert.equal(pushes("undo").length, 0);
  assert.deepEqual(drawn(), ["a-1", "m-old"]);
  assert.deepEqual(store(), ["a-1", "m-old"]);

  // A timeout (never sent) too.
  tap(svg, 50, 50);
  board.undoBoard();
  pushes("stroke_complete").at(-1).reply.answer("timeout");
  assert.equal(pushes("undo").length, 0);
  assert.deepEqual(drawn(), ["a-1", "m-old"]);
});

test("presses go one at a time, in order, each with the gesture it hid", () => {
  const svg = connect([S("m-1", true), S("a-1")]);
  tap(svg, 40, 40);
  const pending = pushes("stroke_complete").at(-1);

  board.undoBoard();
  board.undoBoard();
  assert.deepEqual(drawn(), ["a-1"]);
  assert.equal(pushes("undo").length, 0, "the second waits behind the first");

  accept(pending);
  assert.equal(pushes("undo").length, 1);
  pushes("undo")[0].reply.answer("ok", { stroke_ids: [pending.payload.stroke_id] });
  assert.equal(pushes("undo").length, 1 + 1);
  pushes("undo")[1].reply.answer("ok", { stroke_ids: ["m-1"] });
  assert.deepEqual(store(), ["a-1"]);
  assert.deepEqual(undoReports().at(-1), false);
});

test("a long scribble disappears with one press", () => {
  const svg = connect([S("a-1")]);
  const before = pushes("stroke_complete").length;
  scribble(svg);
  const parts = pushes("stroke_complete").slice(before);
  assert.ok(parts.length >= 2);
  // Another visitor's stroke lands between the parts on the server.
  accept(parts[0]);
  ch().emit("stroke", S("b-1"));
  for (const p of parts.slice(1)) accept(p);

  board.undoBoard();
  assert.deepEqual(drawn(), ["a-1", "b-1"]);
  assert.equal(pushes("undo").length, 1, "one request for the gesture");
  const ids = parts.map((p) => p.payload.stroke_id);
  pushes("undo")[0].reply.answer("ok", { stroke_ids: ids });
  assert.deepEqual(store(), ["a-1", "b-1"]);
});

test("after a reload my strokes come marked mine, without gestures: the server's ids decide", () => {
  // The snapshot of a reloaded page: a split gesture of mine, two strokes.
  connect([S("m-1a", true), S("b-1"), S("m-1b", true)]);
  board.undoBoard();
  assert.deepEqual(drawn(), ["m-1a", "b-1"], "the newest stroke hides at once");
  pushes("undo")[0].reply.answer("ok", { stroke_ids: ["m-1a", "m-1b"] });
  assert.deepEqual(drawn(), ["b-1"], "the server removed the whole gesture");
});

test("a snapshot during an undo keeps its strokes hidden", () => {
  connect([S("a-1"), S("m-1", true)]);
  board.undoBoard();
  // A rejoin's snapshot before the reply.
  ch().emit("strokes", { strokes: [S("a-1"), S("m-1", true), S("c-1")] });
  assert.deepEqual(drawn(), ["a-1", "c-1"]);
  pushes("undo")[0].reply.answer("ok", { stroke_ids: ["m-1"] });
  assert.deepEqual(store(), ["a-1", "c-1"]);
});

test("a stroke the 500 cap trimmed can't be undone", () => {
  const many = [S("m-0", true), ...Array.from({ length: 499 }, (_, i) => S("x-" + i))];
  connect(many);
  assert.deepEqual(undoReports(), [true]);
  ch().emit("stroke", S("x-499"));
  assert.equal(store().length, 500);
  assert.equal(store().includes("m-0"), false);
  assert.deepEqual(undoReports(), [true, false]);
  board.undoBoard();
  assert.equal(pushes("undo").length, 0);
});

test("a clear spends a waiting press", () => {
  const svg = connect([S("m-1", true)]);
  tap(svg, 40, 40);
  const pending = pushes("stroke_complete").at(-1);
  board.undoBoard();
  ch().emit("cleared", {});
  pending.reply.answer("ok", {});
  assert.equal(pushes("undo").length, 0);
  assert.deepEqual(store(), []);
});

test("pure helpers: the gesture a press takes, what is shown", () => {
  const e = (id, mine, gesture, hidden) => ({ id, mine, gesture, hidden });
  assert.deepEqual(board.lastOwnGesture([]), []);
  assert.deepEqual(board.lastOwnGesture([e("a", false, "a")]), []);
  assert.deepEqual(
    board.lastOwnGesture([e("m1", true, "g"), e("a", false, "a"), e("m2", true, "g"), e("m3", true, "h", true)]),
    ["m2", "m1"]
  );
  // An entry without a gesture is its own; a fill (#43) is a stroke like any.
  assert.deepEqual(board.lastOwnGesture([e("m1", true), { id: "f1", mine: true, fill: true }]), ["f1"]);

  const shown = [e("a", false), e("b", true)];
  assert.equal(board.shownStrokes(shown), shown);
  assert.deepEqual(board.shownStrokes([e("a"), e("b", true, "b", true)]).map((x) => x.id), ["a"]);
  assert.equal(board.hasOwnStroke([e("a", false), e("b", true, "b", true)]), false);
  assert.equal(board.hasOwnStroke([e("b", true)]), true);
});

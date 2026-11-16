// A viewer's canvas in drawing_manager.mjs (#44): the room's strokes are
// JS-owned, one node each in #game-canvas-strokes, and GamePage hands every
// stroke broadcast over with its seq (the gap rule stays GamePage's). What
// this keeps from the template it replaced: list order, fills, undo by id,
// clears, snapshots that never go back in time and never drop strokes that
// came after them, the live overlays' hand-over, and Back/Forward restores.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { installFakeDom, renderGamePage, overlayIds } from "./support/fake_dom.mjs";

const { root, dispatched } = installFakeDom();
const dm = await import("../../lib/scrawly_web/pages/drawing_manager.mjs");

const S1 = { id: "s-1", path: "M 1 1 L 2 2", color: "#000000", width: 2 };
const S2 = { id: "s-2", path: "M 3 3 L 4 4", color: "#d63838", width: 5 };
const S3 = { id: "s-3", path: "M 5 5 L 6 6", color: "#2a6df4", width: 10 };
const FILL = { id: "f-1", path: "M 0 0 L 10 0 L 10 10 Z", color: "#1f9a4a", width: 1, fill: true };

// The ids, in order, of the strokes drawn in the viewers' group.
function shownIds() {
  const group = document.getElementById("game-canvas-strokes");
  return group.children.map((c) => c.getAttribute("data-stroke-id"));
}

function node(id) {
  return document.getElementById("game-canvas-strokes").children.find((c) => c.getAttribute("data-stroke-id") === id);
}

// A fresh viewer page instance: GamePage :mounted with init's canvas.
function mountViewer(mount, canvas, seq) {
  renderGamePage(root, { mount, drawer: false });
  dm.mountCanvas(mount);
  dm.showViewerStrokes(canvas, seq);
}

beforeEach(() => {
  dispatched.length = 0;
});

test("init's canvas, a JSON string, is drawn in order; a fill paints its inside", () => {
  mountViewer(1, JSON.stringify([S1, FILL, S2]), 10);
  assert.deepEqual(shownIds(), ["s-1", "f-1", "s-2"]);
  assert.equal(node("s-2").getAttribute("stroke"), "#d63838");
  assert.equal(node("s-2").getAttribute("stroke-width"), "5");
  assert.equal(node("f-1").getAttribute("fill"), "#1f9a4a");
  assert.equal(node("f-1").getAttribute("fill-rule"), "evenodd");
  assert.equal(node("f-1").getAttribute("stroke"), "none");
  // The drawer's group isn't rendered for a viewer, and nothing goes to it.
  assert.equal(document.getElementById("game-canvas-drawer-strokes"), null);
});

test("an empty or broken canvas string draws nothing", () => {
  mountViewer(2, "", 1);
  assert.deepEqual(shownIds(), []);
  mountViewer(3, "not json", 1);
  assert.deepEqual(shownIds(), []);
  mountViewer(4, [S1], 1);
  assert.deepEqual(shownIds(), ["s-1"], "a list works too");
});

test("a stroke appends one node and takes over its live overlay", () => {
  mountViewer(5, JSON.stringify([S1]), 10);
  dm.applyRemoteChunk("s-2", 1, "M 3 3 L 4 4", "#d63838", 5);
  assert.deepEqual(overlayIds(), ["s-2"]);
  const first = node("s-1");

  dm.applyViewerStroke(S2, 11);
  assert.deepEqual(shownIds(), ["s-1", "s-2"]);
  assert.equal(node("s-1"), first, "the nodes already drawn stay as they are");
  assert.deepEqual(overlayIds(), []);
  dm.applyRemoteChunk("s-2", 2, " L 9 9", "#d63838", 5);
  assert.deepEqual(overlayIds(), [], "a late chunk of a finished stroke is ignored");

  // The same stroke again (a snapshot brought it first) isn't drawn twice.
  dm.applyViewerStroke(S2, 11);
  assert.deepEqual(shownIds(), ["s-1", "s-2"]);
  // A fill keeps its flag.
  dm.applyViewerStroke(FILL, 12);
  assert.equal(node("f-1").getAttribute("fill-rule"), "evenodd");
});

test("an undo removes that stroke, and an older snapshot can't bring it back", () => {
  mountViewer(6, JSON.stringify([S1, S2]), 10);
  dm.undoViewerStroke("s-1", 12);
  assert.deepEqual(shownIds(), ["s-2"]);
  // A resync reply built before the undo (seq 11) changes nothing.
  assert.equal(dm.applyViewerSnapshot([S1, S2], 11), false);
  assert.deepEqual(shownIds(), ["s-2"]);
  // One built after it is taken.
  assert.equal(dm.applyViewerSnapshot([S2, S3], 13), true);
  assert.deepEqual(shownIds(), ["s-2", "s-3"]);
});

test("a snapshot keeps the strokes that came after it, and settles their overlays", () => {
  mountViewer(7, JSON.stringify([S1]), 10);
  dm.applyViewerStroke(S2, 12);
  dm.applyRemoteChunk("live", 1, "M 7 7 L 8 8", "#000000", 2);
  dm.applyRemoteChunk("s-3", 1, "M 5 5 L 6 6", "#2a6df4", 10);

  // The snapshot (seq 11) holds s-1 and s-3; s-2 came after it (seq 12).
  assert.equal(dm.applyViewerSnapshot(JSON.stringify([S1, S3]), 11), true);
  assert.deepEqual(shownIds(), ["s-1", "s-3", "s-2"]);
  assert.deepEqual(overlayIds(), ["live"], "the stroke still being drawn keeps its preview");

  // A stroke the snapshot already holds isn't kept twice.
  dm.applyViewerStroke(S3, 13);
  assert.deepEqual(shownIds(), ["s-1", "s-3", "s-2"]);
});

test("a clear empties the canvas; a stroke drawn after it comes back with its chunk", () => {
  mountViewer(8, JSON.stringify([S1, S2]), 10);
  // (An id of its own: a new page instance closes the ids of the overlays
  // an earlier one left, like the previous test's.)
  dm.applyRemoteChunk("live-8", 1, "M 7 7 L 8 8", "#000000", 2);
  dm.clearViewerStrokes(11);
  assert.deepEqual(shownIds(), []);
  assert.deepEqual(overlayIds(), []);
  dm.applyRemoteChunk("live-8", 2, " L 9 9", "#000000", 2);
  assert.deepEqual(overlayIds(), ["live-8"]);
  // A snapshot from before the clear is stale.
  assert.equal(dm.applyViewerSnapshot([S1, S2], 10), false);
  assert.deepEqual(shownIds(), []);
});

test("a new turn empties the canvas and starts the seq over", () => {
  mountViewer(9, JSON.stringify([S1, S2]), 10);
  dm.setDrawingPath("", 20);
  assert.deepEqual(shownIds(), []);
  assert.equal(dm.applyViewerSnapshot([S1], 19), false, "the earlier turn's snapshot");
  assert.equal(dm.applyViewerSnapshot([S3], 21), true);
  assert.deepEqual(shownIds(), ["s-3"]);
});

test("a Back/Forward restore draws the same instance's canvas again; another starts empty", () => {
  mountViewer(10, JSON.stringify([S1, S2]), 10);
  dm.applyViewerStroke(S3, 11);

  // The restore's render dropped the JS-drawn nodes.
  renderGamePage(root, { mount: 10, drawer: false });
  assert.deepEqual(shownIds(), []);
  dm.restoreCanvas(10);
  assert.deepEqual(shownIds(), ["s-1", "s-2", "s-3"]);

  // Another instance's restore: nothing until its resync's snapshot.
  renderGamePage(root, { mount: 11, drawer: false });
  dm.restoreCanvas(11);
  assert.deepEqual(shownIds(), []);
  assert.equal(dm.applyViewerSnapshot([S2], 5), true);
  assert.deepEqual(shownIds(), ["s-2"]);
});

test("a new page instance never shows the earlier instance's strokes", () => {
  mountViewer(12, JSON.stringify([S1, S2]), 10);
  renderGamePage(root, { mount: 13, drawer: false });
  dm.mountCanvas(13);
  assert.deepEqual(shownIds(), []);
  dm.showViewerStrokes("[]", 3);
  assert.deepEqual(shownIds(), []);
});

test("a viewer who becomes the drawer starts from the drawer's own canvas", () => {
  mountViewer(14, JSON.stringify([S1]), 10);
  // The next turn: the page re-renders for the drawer and resets.
  renderGamePage(root, { mount: 14, drawer: true });
  dm.setDrawingPath("", 12);
  assert.deepEqual(shownIds(), []);
  dm.adoptStroke(S2);
  assert.deepEqual(
    document.getElementById("game-canvas-drawer-strokes").children.map((c) => c.getAttribute("data-stroke-id")),
    ["s-2"]
  );
  assert.deepEqual(shownIds(), [], "the drawer's strokes never go in the viewers' group");
});
